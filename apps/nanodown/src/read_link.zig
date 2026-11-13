//! Reading a link into the preview, off the main thread.
//!
//! A page takes a network round trip. Doing that inside the frame that was
//! meant to show it being read froze the window, so the field's icon never
//! had a turn to turn: the magnifier stayed a magnifier through the whole
//! wait. The reading happens here instead, and the frame picks up the result
//! when it lands.
const std = @import("std");
const nanoui = @import("nanoui");
const ui = nanoui.ui;
const media = @import("model/media.zig");
const extract = @import("engine/extract.zig");
const App = @import("app.zig").App;

/// A link being read, on a thread of its own.
pub const Reader = struct {
    gpa: std.mem.Allocator,
    link: []const u8 = "",
    max_height: u32 = 0,
    /// What it found, once it has.
    result: ?media.Media = null,
    finished: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
};

/// Starts reading `link`. Returns at once: the answer arrives through
/// `take`.
pub fn begin(a: *App, link: []const u8, c: *ui.Context) void {
    a.clearPreview();
    a.preview.link = a.gpa.dupe(u8, link) catch return;
    a.preview.reading = true;
    a.preview.picked = 0;
    a.toast = "";
    a.reader = .{
        .link = a.gpa.dupe(u8, link) catch return,
        .max_height = a.values.number("quality"),
        .gpa = a.gpa,
    };
    a.reader_thread = std.Thread.spawn(.{}, work, .{&a.reader}) catch {
        // No thread to be had: read it here, and the icon simply does not
        // get its turn. A frozen frame beats no preview at all.
        a.reader.result = extract.read(a.gpa, link, a.values.number("quality")) catch null;
        a.reader.finished.store(true, .release);
        take(a, c);
        return;
    };
    c.changed = true;
    c.requestFrameFromAnyThread();
}

/// The thread's body: one link, one result.
fn work(r: *Reader) void {
    r.result = extract.read(r.gpa, r.link, r.max_height) catch null;
    r.finished.store(true, .release);
}

/// Picks up what the thread found, once it has. Called once a frame.
pub fn take(a: *App, c: *ui.Context) void {
    if (!a.reader.finished.load(.acquire)) return;
    if (a.reader_thread) |t| {
        t.join();
        a.reader_thread = null;
    }
    a.reader.finished.store(false, .release);
    a.preview.item = a.reader.result;
    a.reader.result = null;
    a.preview.reading = false;
    a.gpa.free(a.reader.link);
    a.reader.link = "";
    // The page listed what it has but handed out no URL for any of it: it
    // signs them in its player. Play it out of sight and take what it asks
    // for.
    if (a.preview.item) |*m| {
        if (m.formats.len > 0 and !anyFetchable(m)) a.beginCapture(a.preview.link, c);
    }
    c.changed = true;
    c.requestFrameFromAnyThread();
}

/// Waits for a reading thread and frees what it was given: the app is going
/// away, and a thread still reading would write into memory that is gone.
pub fn shutdown(a: *App) void {
    if (a.reader_thread) |t| {
        t.join();
        a.reader_thread = null;
    }
    if (a.reader.result) |*m| m.deinit(a.gpa);
    a.reader.result = null;
    if (a.reader.link.len > 0) a.gpa.free(a.reader.link);
    a.reader.link = "";
}

/// Whether any listed format can be fetched as it stands.
pub fn anyFetchable(m: *const media.Media) bool {
    for (m.formats) |f| {
        if (f.url.len > 0 or f.manifest != null) return true;
    }
    return false;
}
