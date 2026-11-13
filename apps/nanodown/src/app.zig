//! nanodown's state: the library, the settings, the licence, the preview of
//! a link, and the queue that runs downloads on their own threads.
//!
//! The frame never waits on a socket. A running download reports through its
//! `job.Shared`'s atomics, and the frame reads them; while one runs, the
//! frame asks for another so the bar moves.
const std = @import("std");
const nanoui = @import("nanoui");
const ui = nanoui.ui;
const kv = nanoui.kv;

const media = @import("model/media.zig");
const download = @import("model/download.zig");
const library = @import("model/library.zig");
const settings = @import("model/settings.zig");
const license = @import("model/license.zig");
const subscription = @import("model/subscription.zig");
const extract = @import("engine/extract.zig");
const job = @import("engine/job.zig");
const thumbs = @import("thumbs.zig");
const capture = @import("engine/capture.zig");
const capture_flow = @import("capture_flow.zig");
const read_link = @import("read_link.zig");
const store = @import("store.zig");
const now = @import("now.zig");


/// One download the app is running, and the thread doing it.
pub const Running = struct {
    id: u64,
    shared: *job.Shared,
    thread: ?std.Thread = null,
    /// What the worker reads: it outlives the thread.
    spec: *job.Spec,
    /// The last bytes counted, and the clock, for the speed.
    last_done: u64 = 0,
    last_at: i64 = 0,
};

/// What the top field holds: a link being read, or a search.
pub const Preview = struct {
    /// The link read, when one was.
    link: []const u8 = "",
    /// What it turned out to be.
    item: ?media.Media = null,
    /// The quality picked, as an index into `item.formats`.
    picked: usize = 0,
    /// Reading it now.
    reading: bool = false,
    /// The trim's start and end, in seconds; 0 is off.
    trim_from: f64 = 0,
    trim_to: f64 = 0,
    /// The format to save as, as an index into the list the settings allow.
    save_as: usize = 0,
    /// The page is being played in a hidden webview to read what its player
    /// asks for: the only way to get a signed URL from a site that signs.
    capturing: bool = false,
    /// The window playing it, and when to give up on it.
    capture_window: ?*nanoui.Window = null,
    capture_until: i64 = 0,
};

pub const App = struct {
    gpa: std.mem.Allocator,
    lib: library.Library,
    values: settings.Values,
    licence: license.License,
    subs: subscription.Subscriptions,
    /// The top field's text.
    field: ui.TextBuffer = .{},
    search: ui.TextBuffer = .{},
    /// One buffer per text setting, kept across frames. Rebuilding them from
    /// the values every frame would put the caret back at the start and drop
    /// whatever was typed between the value being stored and the next frame.
    settings_text: [settings.text_fields.len]ui.TextBuffer = @splat(.{}),
    /// Whether each of those has been filled from its value yet.
    settings_text_filled: [settings.text_fields.len]bool = @splat(false),
    /// The licence key being typed. Not a setting: it belongs to the licence,
    /// and it needs a buffer of its own rather than sharing one.
    key_field: ui.TextBuffer = .{},
    preview: Preview = .{},
    /// The downloads running now.
    running: std.ArrayList(Running) = .empty,
    /// Where downloads go.
    folder: []const u8 = "",
    /// The window, once there is one.
    window: ?*nanoui.Window = null,
    /// The tab chosen, as `library.Filter`.
    tab: usize = 0,
    /// The row the pointer is over, for its hover.
    hovered: ?usize = null,
    /// The library file was there and parsed. A save is only allowed to
    /// replace it when this is true.
    lib_read: bool = false,
    /// The link being read, and the thread reading it.
    reader: read_link.Reader = .{ .gpa = undefined },
    reader_thread: ?std.Thread = null,
    /// A row asked to go, removed once the frame that asked is drawn. The
    /// list is walked with indices worked out before it starts, so taking an
    /// item out mid-walk left the rest of them pointing past the end.
    doomed: ?u64 = null,
    /// A message under the field, and when it goes.
    toast: []const u8 = "",
    toast_until: i64 = 0,
    /// The settings sheet, and the tab it opens on.
    show_settings: bool = false,
    settings_tab: usize = 0,
    /// The clipboard's link, when it changed and is worth offering.
    clipboard_link: []const u8 = "",
    /// The app is quitting with downloads running: ask first.
    ask_quit: bool = false,
    /// The frame's clock, for the animations.
    now: i64 = 0,
    /// The pictures the rows and the preview show.
    thumbs: thumbs.Cache,
    /// What the hidden player has asked for, this capture.
    captured: std.ArrayList(capture.Found) = .empty,
    /// The manifest it asked for, when it asked for one: the whole video.
    captured_manifest: []const u8 = "",

    pub fn init(gpa: std.mem.Allocator, home_dir: []const u8) !App {
        store.home = home_dir;
        var a: App = .{
            .gpa = gpa,
            .lib = library.Library.init(gpa),
            .values = try settings.Values.init(gpa),
            .licence = license.License.init(gpa),
            .subs = subscription.Subscriptions.init(gpa),
            .thumbs = thumbs.Cache.init(gpa),
            .reader = .{ .gpa = gpa },
        };
        a.folder = try gpa.dupe(u8, a.values.get("save_to"));
        if (a.folder.len == 0) {
            a.folder = try store.defaultFolder(gpa);
        }
        a.load();
        return a;
    }

    pub fn deinit(a: *App) void {
        // Every thread is stopped and joined: nothing writes after this.
        for (a.running.items) |r| {
            r.shared.stop.store(true, .release);
            if (r.thread) |t| t.join();
            a.gpa.destroy(r.shared);
            a.freeSpec(r.spec);
        }
        a.running.deinit(a.gpa);
        // A link still being read: its thread has to finish before what it
        // reads goes, or it writes into freed memory on the way out.
        read_link.shutdown(a);
        a.lib.deinit();
        a.values.deinit();
        a.licence.deinit();
        a.subs.deinit();
        a.thumbs.deinit();
        a.field.deinit();
        a.search.deinit();
        a.gpa.free(a.folder);
        if (a.preview.link.len > 0) a.gpa.free(a.preview.link);
        if (a.preview.item) |*m| m.deinit(a.gpa);
        if (a.clipboard_link.len > 0) a.gpa.free(a.clipboard_link);
    }

    /// Whether the licence unlocks the Pro features.
    pub fn pro(a: *const App) bool {
        return a.licence.isPro(now.secs());
    }

    pub fn saveFolder(a: *const App) []const u8 {
        return a.folder;
    }

    // --- persistence ------------------------------------------------------

    /// Reads the library and the settings back from disk.
    pub fn load(a: *App) void {
        a.lib_read = store.loadOne(a.gpa, "library.json", 8 << 20, &a.lib);
        _ = store.loadOne(a.gpa, "settings.json", 1 << 20, &a.values);
        _ = store.loadOne(a.gpa, "license.json", 1 << 20, &a.licence);
    }

    /// Writes the library, the settings and the licence back.
    pub fn save(a: *App) void {
        // A library that was there but would not parse is not an empty one:
        // writing over it would turn a bad read into lost downloads. The
        // file is kept aside by `store.loadOne`, and left alone here.
        if (a.lib_read) {
            store.saveOne(a.gpa, "library.json", a.lib.toJson(a.gpa) catch return);
        }
        store.saveOne(a.gpa, "settings.json", a.values.toJson(a.gpa) catch return);
        store.saveOne(a.gpa, "license.json", a.licence.toJson(a.gpa) catch return);
    }

    // --- the field --------------------------------------------------------

    /// Reads a link into the preview, on its own thread.
    pub fn readLink(a: *App, link: []const u8, c: *ui.Context) void {
        read_link.begin(a, link, c);
    }

    /// Picks up a link that finished being read.
    pub fn takeRead(a: *App, c: *ui.Context) void {
        read_link.take(a, c);
    }

    /// Reads what the field holds: a link, or a search.
    pub fn submit(a: *App, c: *ui.Context) void {
        const text = std.mem.trim(u8, a.field.text(), " \t\r\n");
        if (text.len == 0) return;
        if (store.looksLikeLink(text)) {
            a.readLink(text, c);
        } else {
            a.search.set(text);
            a.lib.query = a.search.text();
            c.changed = true;
        }
    }

    // --- the capture ------------------------------------------------------
    // The capture's own state lives here; its running is in capture_flow.zig.

    /// Plays `link` in a window that is never shown, so its own player asks
    /// for the media and the signed URLs can be taken from it.
    pub fn beginCapture(a: *App, link: []const u8, c: *ui.Context) void {
        capture_flow.beginCapture(a, link, c);
    }

    /// Ends the capture: the window goes, and what the player named is listed.
    pub fn endCapture(a: *App) void {
        capture_flow.end(a);
    }

    /// Called with the clock: ends a capture that has had its time.
    pub fn tickCapture(a: *App) void {
        capture_flow.tickCapture(a);
    }

    /// The player asked for a manifest: kept apart, because it is the whole
    /// video rather than one of its tracks.
    pub fn capturedManifest(a: *App, url: []const u8) void {
        capture_flow.capturedManifest(a, url);
    }

    /// The player asked for `url`.
    pub fn capturedUrl(a: *App, url: []const u8) void {
        capture_flow.capturedUrl(a, url);
    }

    pub fn clearPreview(a: *App) void {
        if (a.preview.link.len > 0) a.gpa.free(a.preview.link);
        a.preview.link = "";
        if (a.preview.item) |*m| m.deinit(a.gpa);
        a.preview.item = null;
        a.preview.picked = 0;
        a.preview.trim_from = 0;
        a.preview.trim_to = 0;
    }

    /// The format the preview has chosen, if it has one.
    pub fn chosen(a: *const App) ?media.Format {
        const m = a.preview.item orelse return null;
        if (a.preview.picked >= m.formats.len) return if (m.formats.len > 0) m.formats[0] else null;
        return m.formats[a.preview.picked];
    }

    // --- downloading ------------------------------------------------------

    /// Starts the preview's download, or queues it.
    pub fn start(a: *App, c: *ui.Context) void {
        const m = a.preview.item orelse return;
        const f = a.chosen() orelse {
            a.say("Nothing to download on that page", c);
            return;
        };
        const audio_only = std.mem.eql(u8, a.values.get("download_as"), "Audio");
        const ext = store.lower(a.gpa, if (audio_only) a.values.get("audio_format") else a.values.get("video_format")) catch return;
        defer a.gpa.free(ext);

        var d: download.Download = .{
            .gpa = a.gpa,
            .url = a.gpa.dupe(u8, m.url) catch return,
            .media = a.gpa.dupe(u8, if (f.url.len > 0) f.url else if (f.manifest) |man| switch (man) {
                .hls => |u| u,
                .dash => |u| u,
            } else "") catch return,
            .title = a.gpa.dupe(u8, if (m.title.len > 0) m.title else "Untitled") catch return,
            .site = m.site,
            .author = a.gpa.dupe(u8, m.author) catch return,
            .quality = a.gpa.dupe(u8, f.label) catch return,
            .ext = a.gpa.dupe(u8, ext) catch return,
            .path = "",
            .thumb = a.gpa.dupe(u8, m.thumb) catch return,
            .duration = m.duration,
            .date = a.gpa.dupe(u8, m.date) catch return,
            .state = .queued,
            .total_bytes = f.size,
            .live = m.live,
            // Owned like the rest: `deinit` frees every string it holds.
            .problem = a.gpa.dupe(u8, "") catch return,
            .stage = a.gpa.dupe(u8, "") catch return,
        };
        const dest = a.destFor(d.title);
        defer a.gpa.free(dest);
        d.path = a.gpa.dupe(u8, dest) catch return;

        // Already there? The setting says whether to ask again.
        if (a.values.flag("skip_existing") and a.lib.byUrl(m.url) != null) {
            d.deinit(a.gpa);
            a.say("Already in the library", c);
            return;
        }
        // The library keeps its own copies of every string.
        const added = a.lib.add(d) catch {
            d.deinit(a.gpa);
            return;
        };
        d.deinit(a.gpa);
        a.clearPreview();
        a.field.clear();
        a.pump(c);
        _ = added;
        c.changed = true;
    }

    /// Where a download goes: the folder, and its name.
    fn destFor(a: *App, title: []const u8) []const u8 {
        const safe = store.sanitize(a.gpa, title) catch return a.gpa.dupe(u8, "download") catch "";
        defer a.gpa.free(safe);
        return std.fmt.allocPrint(a.gpa, "{s}/{s}", .{ a.folder, safe }) catch a.gpa.dupe(u8, "download") catch "";
    }

    /// Starts as many queued downloads as the settings allow.
    pub fn pump(a: *App, c: *ui.Context) void {
        const limit = @max(1, a.values.number("concurrent"));
        while (a.running.items.len < limit) {
            const next = a.lib.nextQueued() orelse break;
            a.launch(next, c) catch {
                next.state = .failed;
                next.problem = a.gpa.dupe(u8, "could not start") catch "";
                break;
            };
        }
    }

    fn launch(a: *App, d: *download.Download, c: *ui.Context) !void {
        // The format the preview chose, rebuilt from what the row kept: its
        // own URL when it is one file, its manifest when it is streamed.
        const streamed = std.mem.endsWith(u8, d.media, ".m3u8") or std.mem.endsWith(u8, d.media, ".mpd");
        const f = media.Format{
            .id = a.gpa.dupe(u8, d.quality) catch "",
            .label = a.gpa.dupe(u8, d.quality) catch "",
            .ext = a.gpa.dupe(u8, d.ext) catch "",
            .url = a.gpa.dupe(u8, if (streamed) "" else d.media) catch "",
            .manifest = if (streamed) (if (std.mem.endsWith(u8, d.media, ".m3u8"))
                media.Manifest{ .hls = a.gpa.dupe(u8, d.media) catch "" }
            else
                media.Manifest{ .dash = a.gpa.dupe(u8, d.media) catch "" }) else null,
            .kind = if (std.mem.eql(u8, d.quality, "Audio")) .audio else .video,
            .size = d.total_bytes,
        };
        const spec = try a.gpa.create(job.Spec);
        spec.* = .{
            .gpa = a.gpa,
            .url = d.media,
            .referer = d.url,
            .format = f,
            .dest = d.path,
            .ext = d.ext,
            .connections = a.values.number("connections"),
            .tags = .{
                .title = d.title,
                .artist = d.author,
                .date = d.date,
                .link = d.url,
            },
            .artwork_url = d.thumb,
        };
        const shared = try a.gpa.create(job.Shared);
        shared.* = .{};
        d.state = .probing;
        try a.running.append(a.gpa, .{
            .id = d.id,
            .shared = shared,
            .spec = spec,
            .last_at = now.ms(),
        });
        const last = &a.running.items[a.running.items.len - 1];
        last.thread = std.Thread.spawn(.{}, worker, .{ spec, shared }) catch null;
        if (last.thread == null) {
            // No thread to be had: run it here, which blocks the frame once.
            job.run(spec.*, shared);
        }
        c.changed = true;
    }

    fn worker(spec: *job.Spec, shared: *job.Shared) void {
        job.run(spec.*, shared);
    }

    /// Frees a job's spec: the format's strings were copied for it.
    fn freeSpec(a: *App, spec: *job.Spec) void {
        a.gpa.free(spec.format.id);
        a.gpa.free(spec.format.label);
        a.gpa.free(spec.format.ext);
        a.gpa.free(spec.format.url);
        if (spec.format.manifest) |m| switch (m) {
            .hls => |u| a.gpa.free(u),
            .dash => |u| a.gpa.free(u),
        };
        a.gpa.destroy(spec);
    }

    /// Reads what the running downloads report, and finishes the ones that
    /// are done. Called once a frame.
    pub fn poll(a: *App, c: *ui.Context) void {
        var i: usize = 0;
        var busy = false;
        while (i < a.running.items.len) {
            const r = &a.running.items[i];
            const d = a.lib.byId(r.id) orelse {
                r.shared.stop.store(true, .release);
                if (r.thread) |t| t.join();
                a.gpa.destroy(r.shared);
                a.freeSpec(r.spec);
                _ = a.running.orderedRemove(i);
                continue;
            };
            const done = r.shared.done.load(.acquire);
            const total = r.shared.total.load(.acquire);
            d.done_bytes = done;
            if (total > 0) d.total_bytes = total;
            // A stream the playlist gives no sizes for is measured in
            // segments: its bytes say nothing about how far along it is.
            d.segs_done = r.shared.segs_done.load(.acquire);
            d.segs_total = r.shared.segs_total.load(.acquire);

            // The speed, from the last two looks.
            const at = now.ms();
            const dt = at - r.last_at;
            if (dt >= 400) {
                const moved = done -| r.last_done;
                d.speed = @as(f64, @floatFromInt(moved)) * 1000.0 / @as(f64, @floatFromInt(dt));
                d.eta = if (d.speed > 1024 and d.total_bytes > done) @as(f64, @floatFromInt(d.total_bytes - done)) / d.speed else -1;
                r.last_done = done;
                r.last_at = at;
            }

            switch (r.shared.stageOf()) {
                .probing => d.state = .probing,
                .downloading => d.state = .running,
                .merging, .writing => {
                    d.state = .processing;
                    d.stage = "Finishing";
                },
                .done => {
                    d.state = .done;
                    d.done_bytes = if (d.total_bytes > 0) d.total_bytes else done;
                    d.speed = 0;
                    d.eta = -1;
                    d.finished_at = now.secs();
                    if (r.shared.wrote().len > 0) {
                        a.gpa.free(d.path);
                        d.path = a.gpa.dupe(u8, r.shared.wrote()) catch "";
                    }
                    a.finish(r, i);
                    a.save();
                    continue;
                },
                .failed => {
                    const why = r.shared.why();
                    if (std.mem.eql(u8, why, "stopped")) {
                        d.state = .paused;
                    } else {
                        d.state = .failed;
                        a.gpa.free(d.problem);
                        // A failed row with no reason is a row that cannot be
                        // acted on: when the worker did not say why, say that
                        // rather than leaving the line blank.
                        d.problem = a.gpa.dupe(u8, if (why.len > 0) why else "the download stopped without saying why") catch "";
                    }
                    a.finish(r, i);
                    a.save();
                    continue;
                },
            }
            busy = true;
            i += 1;
        }
        if (busy) c.animationFrame();
        // A finished one frees a slot.
        a.pump(c);
    }

    fn finish(a: *App, r: *Running, i: usize) void {
        if (r.thread) |t| t.join();
        a.gpa.destroy(r.shared);
        a.freeSpec(r.spec);
        _ = a.running.orderedRemove(i);
    }

    /// Pauses a download: its thread stops at the next chunk.
    pub fn pause(a: *App, id: u64, c: *ui.Context) void {
        for (a.running.items) |*r| {
            if (r.id != id) continue;
            r.shared.stop.store(true, .release);
            return;
        }
        if (a.lib.byId(id)) |d| {
            if (d.state == .queued) d.state = .paused;
        }
        c.changed = true;
    }

    /// Resumes a download: it goes back in the queue.
    pub fn unpause(a: *App, id: u64, c: *ui.Context) void {
        if (a.lib.byId(id)) |d| {
            if (d.state == .paused or d.state == .stopped or d.state == .failed) {
                d.state = .queued;
                a.gpa.free(d.problem);
                d.problem = a.gpa.dupe(u8, "") catch "";
                a.pump(c);
            }
        }
        c.changed = true;
    }

    /// Removes a download from the library, stopping it first.
    pub fn remove(a: *App, id: u64, c: *ui.Context) void {
        // Not now: the view is still drawing the rows this one belongs to.
        a.doomed = id;
        c.changed = true;
    }

    /// Takes out the row `remove` asked for, once the frame is done with it.
    pub fn reap(a: *App) void {
        const id = a.doomed orelse return;
        a.doomed = null;
        // A download still running has a thread writing into `shared` and
        // reading `spec`. Taking its row out and freeing those under it is
        // a use-after-free: stop it, wait for the thread, and only then let
        // the row and what it owned go.
        var i: usize = 0;
        while (i < a.running.items.len) {
            const r = &a.running.items[i];
            if (r.id != id) {
                i += 1;
                continue;
            }
            r.shared.stop.store(true, .release);
            if (r.thread) |t| t.join();
            a.gpa.destroy(r.shared);
            a.freeSpec(r.spec);
            _ = a.running.orderedRemove(i);
            break;
        }
        a.lib.remove(id);
        a.save();
    }

    /// A message under the field for a few seconds.
    pub fn say(a: *App, text: []const u8, c: *ui.Context) void {
        a.toast = text;
        a.toast_until = now.ms() + 3200;
        c.changed = true;
    }

    /// Asks for a frame, from anywhere (a menu item, a worker's thread).
    pub fn redraw(a: *App) void {
        if (a.window) |w| w.redrawFromAnyThread();
    }

    pub fn toastLive(a: *const App) bool {
        return a.toast.len > 0 and now.ms() < a.toast_until;
    }
};
