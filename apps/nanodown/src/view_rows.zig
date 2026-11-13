//! One row of the library: the picture, the title, what it is doing, and the
//! buttons that act on it. The bar takes the picture's own color as it fills.
const std = @import("std");
const nanoui = @import("nanoui");
const ui = nanoui.ui;
const kit = nanoui.kit;
const theme = @import("theme.zig");
const App = @import("app.zig").App;
const download = @import("model/download.zig");
const thumbs = @import("thumbs.zig");

pub fn draw(a: *App, c: *ui.Context, p: *const theme.Palette, d: *download.Download, index: usize) void {
    ui.key(c, c.print("row-{d}", .{d.id}));
    const picked = a.lib.selected != null and a.lib.selected.? == index;
    var row = ui.div(c).wFull().h(theme.metrics.row_h).row().itemsCenter().gap(12).px(10).rounded(theme.metrics.radius).control();
    row = if (picked) row.bg(p.well).border(p.rule).borderW(1) else row.hover(p.well);
    const it = row.interaction();
    defer row.end();
    if (it.clicked) {
        a.lib.selected = if (picked) null else index;
        c.changed = true;
    }
    if (it.secondary_clicked) {
        a.lib.selected = index;
        c.changed = true;
    }

    picture(a, c, p, d);
    details(a, c, p, d);
    actions(a, c, p, d, it.hovered or picked);
}

/// The picture, with the progress over its lower edge.
fn picture(a: *App, c: *ui.Context, p: *const theme.Palette, d: *download.Download) void {
    // The well needs an edge: on a hovered row the row's own background is
    // the same colour, and a picture with nothing in it disappears.
    const box = ui.div(c).w(theme.metrics.thumb_w).h(theme.metrics.thumb_h).rounded(theme.metrics.thumb_radius).bg(p.well).border(p.rule).borderW(1).clip();
    defer box.end();
    const bytes = a.thumbs.get(d.thumb);
    if (bytes) |b| {
        _ = ui.image(c, .{
            .key = d.thumb,
            .bytes = b,
            .box = .{ .w = theme.metrics.thumb_w, .h = theme.metrics.thumb_h },
            .radius = theme.metrics.thumb_radius,
            .part = .{ 0, 0, 1, 1 },
            .scale = 1,
        });
    } else {
        // No picture yet: the site's mark, faint.
        const mark = ui.div(c).absolute().offset(0, 0).size(theme.metrics.thumb_w, theme.metrics.thumb_h).itemsCenter().justifyCenter();
        defer mark.end();
        ui.icon(c, iconFor(d), .{ .size = 20, .color = p.faint });
    }
    // No bar over the picture: the row draws one under the title, and two
    // bars for one download read as two downloads. The picture's own foot
    // also sat where a border would, so it looked like an edge rather than
    // progress.
    // A live stream wears its mark while it is being recorded. `live` says
    // what the download is, not that it is running: a failed recording with
    // a LIVE badge over it claims something that is not happening.
    if (d.live and (d.state == .running or d.state == .queued or d.state == .probing)) {
        const badge = ui.div(c).absolute().offset(6, 6).row().itemsCenter().gap(4).px(6).py(2).rounded(4).bg(p.bad);
        defer badge.end();
        ui.text(c, "LIVE", .{ .size = 9, .weight = .bold, .color = p.on_accent });
    }
    // How long it is, in the corner.
    if (d.duration > 0 and !d.live) {
        var buf: [16]u8 = undefined;
        const clock = tryDup(c, download.Download.clock(d.duration, &buf));
        const tag = ui.div(c).absolute().offset(theme.metrics.thumb_w - 40, theme.metrics.thumb_h - 20).px(4).py(1).rounded(3).bg(.{ .r = 0, .g = 0, .b = 0, .a = 0.66 });
        defer tag.end();
        ui.text(c, clock, .{ .size = 9, .color = .white, .tabular = true });
    }
}

/// The text is laid out after the view returns, so a line formatted into a
/// stack buffer has to be copied into the frame's arena first.
fn tryDup(c: *ui.Context, text: []const u8) []const u8 {
    return c.alloc().dupe(u8, text) catch text;
}

/// The progress under a row. The track is as wide as the row, so the fill is
/// read off the track's own laid-out width rather than a pixel count that
/// stops matching it the moment the window is wider than the number assumed.
/// A paused bar is grey: an orange one reads as still running.
fn progressBar(c: *ui.Context, p: *const theme.Palette, d: *const download.Download) void {
    const track = ui.div(c).wFull().h(3).rounded(2).bg(p.well).clip();
    defer track.end();
    const w = (track.interaction().rect orelse ui.Rect{ .x = 0, .y = 0, .w = 0, .h = 0 }).w;
    const f = d.fraction();
    if (w <= 0 or f <= 0) return;
    _ = c.leaf(.{
        .width = .{ .px = w * @min(f, 1) },
        .height = .fill,
        .radius = 1.5,
        .background = barColor(p, d),
    }, .none, null);
}

fn barColor(p: *const theme.Palette, d: *const download.Download) ui.Color {
    return switch (d.state) {
        .done => p.good,
        .failed => p.bad,
        // A paused bar is a soft grey: in the accent it would read as a
        // download still moving, and in `dim` it reads as a hard rule drawn
        // across the row rather than a bar that is part-filled.
        .paused, .stopped => p.faint,
        else => p.accent,
    };
}

fn iconFor(d: *const download.Download) []const u8 {
    if (std.mem.eql(u8, d.quality, "Audio")) return "music.note";
    if (d.live) return "dot.radiowaves.left.and.right";
    return "play.rectangle";
}

/// The title, the line under it, and the bar while it runs.
fn details(a: *App, c: *ui.Context, p: *const theme.Palette, d: *download.Download) void {
    _ = a;
    const col = ui.div(c).column().grow().gap(3).justifyCenter();
    defer col.end();
    ui.text(c, d.title, .{ .size = 13, .weight = .medium, .color = p.ink, .truncate = .ellipsis, .max_lines = 1 });
    var buf: [192]u8 = undefined;
    const line = tryDup(c, d.statusLine(&buf));
    const tint: ui.Color = if (d.state == .failed) p.bad else p.dim;
    // One line, cut if it must be. A reason that wraps makes the row taller
    // than its neighbours, and a list of uneven rows is worse than a reason
    // whose second half is one hover away.
    ui.text(c, line, .{ .size = 11, .color = tint, .tabular = true, .truncate = .ellipsis });
    if (d.inFlight() and d.state != .queued) {
        progressBar(c, p, d);
    } else {
        // Every row is the same height: a row with no bar would otherwise
        // sit shorter than its neighbours and the list would look ragged.
        const pad = ui.div(c).h(3);
        defer pad.end();
    }
}

/// What the row offers: pause or resume, and the menu.
fn actions(a: *App, c: *ui.Context, p: *const theme.Palette, d: *download.Download, shown: bool) void {
    _ = p;
    const row = ui.div(c).row().itemsCenter().gap(4);
    defer row.end();
    switch (d.state) {
        .running, .probing => {
            if (ui.button(c, "", .{ .variant = .ghost, .size = 12, .icon = "pause.fill" }).clicked) {
                a.pause(d.id, c);
            }
        },
        .paused => {
            if (ui.button(c, "", .{ .variant = .ghost, .size = 12, .icon = "play.fill" }).clicked) {
                a.unpause(d.id, c);
            }
        },
        // A stopped or failed one is started again, not played: the play
        // triangle promised a video that is not there.
        .stopped, .failed => {
            if (ui.button(c, "", .{ .variant = .ghost, .size = 12, .icon = "arrow.clockwise" }).clicked) {
                a.unpause(d.id, c);
            }
        },
        .done => {
            if (ui.button(c, "", .{ .variant = .ghost, .size = 12, .icon = "folder" }).clicked) {
                nanoui.shell.showInFolder(d.path);
            }
        },
        else => {},
    }
    // Removing is not what a row is for: it shows on the row the pointer is
    // on, or the one picked, rather than on all of them at once.
    if (shown) {
        if (ui.button(c, "", .{ .variant = .ghost, .size = 12, .icon = "xmark" }).clicked) {
            a.remove(d.id, c);
        }
    } else {
        // The space is held either way, so the row does not shift under the
        // pointer when the button appears.
        const gap = ui.div(c).w(22);
        defer gap.end();
    }
}
