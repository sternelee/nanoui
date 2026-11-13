//! The capture, run from the app: a page played in a window that is never
//! shown, its player's media requests taken from it, and the formats it
//! named put in the preview.
//!
//! A site that signs its media URLs for its own player (YouTube) hands this
//! engine nothing it can fetch on its own. Playing the page is the only
//! honest way in: the player runs its own code, asks for the media, and the
//! URL it asked for is the one that works. What it asked for is only listed
//! if it can be fetched as it stands; a site that hands its player a
//! protocol rather than a URL gets a plain explanation instead.
const std = @import("std");
const nanoui = @import("nanoui");
const ui = nanoui.ui;
const capture = @import("engine/capture.zig");
const media = @import("model/media.zig");
const now = @import("now.zig");
const httpz = @import("engine/http.zig");
const App = @import("app.zig").App;

/// Plays `link` in a window that is never shown, so its own player asks for
/// the media and the signed URLs can be taken from it.
pub fn begin(a: anytype, link: []const u8, hook: *const fn (?*anyopaque) callconv(.c) void, nudge: *const fn (?*anyopaque) callconv(.c) void) void {
    if (a.preview.capture_window != null) return;
    const window = a.window orelse return;
    const app = window.app;
    for (a.captured.items) |f| a.gpa.free(f.url);
    a.captured.clearRetainingCapacity();
    if (a.captured_manifest.len > 0) {
        a.gpa.free(a.captured_manifest);
        a.captured_manifest = "";
    }
    const w = app.newWindow(.{
        .title = "nanodown: reading the page",
        .width = 900,
        .height = 620,
        .visible = false,
        .content = .{ .page = .{ .url = link, .inspectable = false } },
    }) catch return;
    a.preview.capture_window = w;
    a.preview.capturing = true;
    // The hook goes in before the player runs, then the player is asked to
    // start; both are queued on the page's own thread. The page loads at its
    // own pace, so the hook is offered again as it arrives rather than once:
    // a document that replaced the one it was put in needs it again.
    for ([_]u64{ 400, 900, 1600, 2500, 4000, 6000 }) |ms| nanoui.App.after(ms, a, hook);
    for ([_]u64{ 1800, 3500, 5500, 7500 }) |ms| nanoui.App.after(ms, a, nudge);
    a.preview.capture_until = now.secs() + 20;
}

/// Ends the capture: the window goes, and what the player named is listed.
pub fn end(a: anytype) void {
    if (a.preview.capture_window) |w| w.close();
    a.preview.capture_window = null;
    a.preview.capturing = false;
    const m = if (a.preview.item) |*it| it else return;

    // A manifest is the whole video, so it stands in for every track.
    if (a.captured_manifest.len > 0) {
        replaceFormats(a, m, &.{.{
            .id = "manifest",
            .label = "Auto",
            .ext = "mp4",
            .manifest = .{ .hls = a.captured_manifest },
        }});
        return;
    }

    // What the player asked for is only worth listing if it can be fetched
    // as it stands. A site that hands its player a protocol rather than a
    // URL (YouTube's UMP) gives nothing this engine can take, and saying so
    // is better than listing qualities that fail.
    // A URL the player asked for is not proof this engine may fetch it: a
    // site signs it for the address that asked, and a URL signed for another
    // machine answers 403 here. Each one is tried before it is offered, so
    // the list never holds a quality whose Download button would fail.
    var usable: std.ArrayList(capture.Found) = .empty;
    defer usable.deinit(a.gpa);
    for (a.captured.items) |f| {
        if (f.itag == 0) continue;
        var p = httpz.probe(a.gpa, f.url, "");
        defer p.deinit();
        if (p.status != 200 and p.status != 206) continue;
        usable.append(a.gpa, f) catch continue;
    }
    if (usable.items.len == 0) {
        if (m.problem.len == 0) {
            a.gpa.free(m.problem);
            m.problem = a.gpa.dupe(u8, "This site hands its player a stream this engine cannot take.") catch "";
        }
        return;
    }
    var fresh: std.ArrayList(media.Format) = .empty;
    capture.formats(a.gpa, usable.items, &fresh) catch {};
    replaceFormats(a, m, fresh.items);
    fresh.deinit(a.gpa);
}

/// The formats the page listed had no URL; these do.
fn replaceFormats(a: anytype, m: *media.Media, fresh: []const media.Format) void {
    for (m.formats) |f| {
        a.gpa.free(f.id);
        a.gpa.free(f.label);
        a.gpa.free(f.ext);
        a.gpa.free(f.url);
        a.gpa.free(f.codec);
    }
    if (m.formats.len > 0) a.gpa.free(m.formats);
    var out: std.ArrayList(media.Format) = .empty;
    for (fresh) |f| {
        out.append(a.gpa, .{
            .id = a.gpa.dupe(u8, f.id) catch continue,
            .label = a.gpa.dupe(u8, f.label) catch continue,
            .ext = a.gpa.dupe(u8, f.ext) catch continue,
            .url = a.gpa.dupe(u8, f.url) catch continue,
            .codec = a.gpa.dupe(u8, f.codec) catch continue,
            .manifest = if (f.manifest) |man| switch (man) {
                .hls => |u| .{ .hls = a.gpa.dupe(u8, u) catch "" },
                .dash => |u| .{ .dash = a.gpa.dupe(u8, u) catch "" },
            } else null,
            .kind = f.kind,
            .bitrate = f.bitrate,
            .width = f.width,
            .height = f.height,
            .size = f.size,
            .duration = f.duration,
        }) catch continue;
    }
    m.formats = out.toOwnedSlice(a.gpa) catch &.{};
    a.preview.picked = 0;
}

// --- the app side ---------------------------------------------------------

/// Plays `link` in a window that is never shown, so its own player asks
/// for the media and the signed URLs can be taken from it.
pub fn beginCapture(a: *App, link: []const u8, c: *ui.Context) void {
    _ = c;
    begin(a, link, hookCapture, nudgeCapture);
}

/// Ends the capture: the window goes, and what the player named is listed.
pub fn endCapture(a: *App) void {
    end(a);
}

/// The service the hidden page calls: `Capture.found(url)`.
pub const Capture = struct {
    app: *App,

    /// The player asked for a manifest: an HLS or DASH playlist that is
    /// the whole video, signed the same way.
    pub fn manifest(self: *Capture, url: []const u8) !void {
        self.app.capturedManifest(url);
    }

    pub fn found(self: *Capture, url: []const u8) !void {
        self.app.capturedUrl(url);
    }
};

/// The timers the capture runs on: the hook, the nudge, and the end.
fn hookCapture(ctx: ?*anyopaque) callconv(.c) void {
    const a: *App = @ptrCast(@alignCast(ctx));
    const w = a.preview.capture_window orelse return;
    if (w.page) |p| p.queue.eval(capture.hook);
}

fn nudgeCapture(ctx: ?*anyopaque) callconv(.c) void {
    const a: *App = @ptrCast(@alignCast(ctx));
    const w = a.preview.capture_window orelse return;
    if (w.page) |p| p.queue.eval(capture.nudge);
}

/// Called with the clock: ends a capture that has had its time.
pub fn tickCapture(a: *App) void {
    if (!a.preview.capturing) return;
    if (now.secs() < a.preview.capture_until) return;
    a.endCapture();
    if (a.window) |w| w.redrawFromAnyThread();
}

/// The player asked for a manifest: kept apart, because it is the whole
/// video rather than one of its tracks.
pub fn capturedManifest(a: *App, url: []const u8) void {
    if (a.captured_manifest.len > 0) return;
    a.captured_manifest = a.gpa.dupe(u8, url) catch "";
}

/// The player asked for `url`.
pub fn capturedUrl(a: *App, url: []const u8) void {
    for (a.captured.items) |f| if (std.mem.eql(u8, f.url, url)) return;
    // The quality is in the URL's own query: read it now, so the list can
    // be built without the page's metadata.
    var f = capture.readFound(url);
    f.url = a.gpa.dupe(u8, url) catch return;
    a.captured.append(a.gpa, f) catch {
        a.gpa.free(f.url);
        return;
    };
}
