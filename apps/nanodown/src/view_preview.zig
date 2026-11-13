//! The preview: what a link turned out to be. The cover, the title, the
//! qualities it comes in with their sizes, what to save it as, a trim, and
//! the button that starts it.
const std = @import("std");
const nanoui = @import("nanoui");
const ui = nanoui.ui;
const theme = @import("theme.zig");
const App = @import("app.zig").App;
const media = @import("model/media.zig");
const download = @import("model/download.zig");

pub fn draw(a: *App, c: *ui.Context, p: *const theme.Palette) void {
    const m = &(a.preview.item orelse return);
    // The same column as the field, the tabs and the rows: a preview running
    // to the window's edge while the list stops at the island reads as two
    // layouts stacked.
    const card = ui.div(c).wFull().row().itemsCenter().justifyCenter().px(theme.metrics.gutter).pb(12);
    defer card.end();
    const inner = ui.div(c).row().itemsCenter().gap(14).p(12).rounded(theme.metrics.radius).bg(p.raised).border(p.rule).borderW(1).w(@min(theme.metrics.island, c.size.w - theme.metrics.gutter * 2));
    defer inner.end();

    cover(a, c, p, m);
    // The controls are shorter than the cover, so they sit centred against
    // it rather than at the top with dead space under them.
    const right = ui.div(c).column().grow().gap(8).justifyCenter();
    defer right.end();

    heading(a, c, p, m);
    if (m.problem.len > 0) {
        problem(a, c, p, m);
        return;
    }
    qualities(a, c, p, m);
    saveAs(a, c, p, m);
    trim(a, c, p, m);
    extras(a, c, p, m);
}

fn cover(a: *App, c: *ui.Context, p: *const theme.Palette, m: *const media.Media) void {
    const w: f32 = 176;
    const h: f32 = 99;
    const box = ui.div(c).w(w).h(h).rounded(theme.metrics.thumb_radius).bg(p.well).clip();
    defer box.end();
    if (a.thumbs.get(m.thumb)) |bytes| {
        _ = ui.image(c, .{
            .key = m.thumb,
            .bytes = bytes,
            .box = .{ .w = w, .h = h },
            .radius = theme.metrics.thumb_radius,
            .scale = 1,
        });
    } else {
        const mark = ui.div(c).absolute().offset(0, 0).size(w, h).itemsCenter().justifyCenter();
        defer mark.end();
        ui.icon(c, "play.rectangle", .{ .size = 24, .color = p.faint });
    }
    if (m.live) {
        const badge = ui.div(c).absolute().offset(6, 6).px(6).py(2).rounded(4).bg(p.bad);
        defer badge.end();
        ui.text(c, "LIVE", .{ .size = 9, .weight = .bold, .color = p.on_accent });
    }
}

fn heading(a: *App, c: *ui.Context, p: *const theme.Palette, m: *const media.Media) void {
    _ = a;
    const row = ui.div(c).row().itemsStart().gap(8);
    defer row.end();
    const col = ui.div(c).column().grow().gap(2);
    defer col.end();
    ui.text(c, if (m.title.len > 0) m.title else "Untitled", .{ .size = 15, .weight = .semibold, .color = p.ink, .truncate = .ellipsis, .max_lines = 2, .wrap = true });
    // The line is built in the frame's arena: the text is laid out after
    // this view returns, so a stack buffer would be gone by then.
    var meta: std.ArrayList(u8) = .empty;
    // The site, then the author when it is not the site's own name, then
    // the date: "Vimeo · 2013-05-08", not "Vimeo · Vimeo". A link that is
    // just a file has no site to name: "the web" is a placeholder, not
    // something worth a line.
    const site_name = if (m.site == .generic) "" else m.site.title();
    const parts = [_][]const u8{ site_name, m.author, m.date };
    for (parts) |b| {
        if (b.len == 0) continue;
        if (std.mem.eql(u8, b, site_name) and meta.items.len > 0) continue;
        if (meta.items.len > 0) meta.appendSlice(c.alloc(), " · ") catch {};
        meta.appendSlice(c.alloc(), b) catch {};
    }
    if (m.duration > 0) {
        var buf: [16]u8 = undefined;
        const clock = c.alloc().dupe(u8, download.Download.clock(m.duration, &buf)) catch "";
        if (meta.items.len > 0) meta.appendSlice(c.alloc(), " · ") catch {};
        meta.appendSlice(c.alloc(), clock) catch {};
    }
    if (meta.items.len > 0) ui.text(c, meta.items, .{ .size = 11, .color = p.dim, .tabular = true });
}

fn problem(a: *App, c: *ui.Context, p: *const theme.Palette, m: *const media.Media) void {
    const box = ui.div(c).wFull().row().itemsStart().gap(8).p(10).rounded(8).bg(p.well);
    defer box.end();
    ui.icon(c, "exclamationmark.triangle", .{ .size = 13, .color = p.bad });
    const col = ui.div(c).column().grow().gap(3);
    defer col.end();
    ui.text(c, m.problem, .{ .size = 12, .color = p.ink, .wrap = true });
    ui.text(c, "Its player was run here to see what it asks for, and what it asked for answers this engine with a refusal. A site that signs a stream for the machine that asked cannot be taken from another.", .{ .size = 11, .color = p.faint, .wrap = true });
    if (ui.button(c, "Dismiss", .{ .variant = .ghost, .size = 11 }).clicked) {
        a.clearPreview();
        c.changed = true;
    }
}

/// The qualities, as a row of chips: the one chosen is filled.
fn qualities(a: *App, c: *ui.Context, p: *const theme.Palette, m: *const media.Media) void {
    const label = ui.div(c).row().itemsCenter().gap(6);
    defer label.end();
    ui.text(c, "Quality", .{ .size = 11, .color = p.faint });
    const row = ui.div(c).row().itemsCenter().gap(5).wFull();
    defer row.end();
    var shown: usize = 0;
    for (m.formats, 0..) |f, i| {
        if (shown >= 8) break;
        shown += 1;
        const on = a.preview.picked == i;
        var chip = ui.div(c).row().itemsCenter().gap(5).px(9).h(24).rounded(6).control();
        chip = if (on) chip.bg(p.accent) else chip.bg(p.well).hover(p.rule);
        const it = chip.interaction();
        defer chip.end();
        ui.text(c, f.label, .{ .size = 11, .weight = if (on) .medium else .regular, .color = if (on) p.on_accent else p.dim });
        if (f.size > 0) {
            var sbuf: [24]u8 = undefined;
            ui.text(c, download.Download.size(f.size, &sbuf), .{ .size = 10, .color = if (on) p.on_accent.alpha(0.8) else p.faint, .tabular = true });
        }
        if (it.clicked and !on) {
            a.preview.picked = i;
            c.changed = true;
        }
    }
}

/// What it saves as: the formats the settings allow, and the Pro ones marked.
fn saveAs(a: *App, c: *ui.Context, p: *const theme.Palette, m: *const media.Media) void {
    const row = ui.div(c).row().itemsCenter().gap(8).wFull();
    defer row.end();
    ui.text(c, "Save as", .{ .size = 11, .color = p.faint });
    const audio = std.mem.eql(u8, a.values.get("download_as"), "Audio");
    const list: []const []const u8 = if (audio)
        &.{ "M4A", "MP3", "Opus", "FLAC", "WAV" }
    else
        &.{ "MP4", "MKV", "MOV", "WebM" };
    const current = if (audio) a.values.get("audio_format") else a.values.get("video_format");
    for (list, 0..) |name, i| {
        const on = std.mem.eql(u8, name, current);
        // The first of each list is free; the rest are Pro.
        const locked = i > 0 and !a.pro();
        // A chosen chip is filled, the same as a chosen quality: one
        // language for "this is the one" rather than two.
        var chip = ui.div(c).row().itemsCenter().gap(4).px(9).h(24).rounded(6).control();
        chip = if (on) chip.bg(p.accent) else chip.bg(p.well).hover(p.rule);
        const it = chip.interaction();
        defer chip.end();
        ui.text(c, name, .{ .size = 11, .weight = if (on) .medium else .regular, .color = if (on) p.on_accent else if (locked) p.faint else p.dim });
        if (locked) ui.icon(c, "lock", .{ .size = 10, .color = if (on) p.on_accent.alpha(0.7) else p.faint });
        if (it.clicked and !on) {
            if (locked) {
                a.say("That format is Pro", c);
            } else {
                a.values.set(if (audio) "audio_format" else "video_format", name) catch {};
                c.changed = true;
            }
        }
    }
    // The one filled thing in the card, at the end of the row it belongs to:
    // on a line of its own it read as a leftover rather than the next step.
    ui.spacer(c);
    const f = a.chosen();
    if (ui.button(c, if (m.live) "Record" else "Download", .{ .variant = .primary, .size = 12, .disabled = f == null }).clicked) {
        a.start(c);
    }
}

/// The trim: two timecodes, and how much of the file that leaves.
fn trim(a: *App, c: *ui.Context, p: *const theme.Palette, m: *const media.Media) void {
    if (m.duration <= 0) return;
    const row = ui.div(c).row().itemsCenter().gap(8);
    defer row.end();
    ui.text(c, "Trim", .{ .size = 11, .color = p.faint });
    var from_buf: [16]u8 = undefined;
    var to_buf: [16]u8 = undefined;
    const from = if (a.preview.trim_from > 0) download.Download.clock(a.preview.trim_from, &from_buf) else "start";
    const to = if (a.preview.trim_to > 0) download.Download.clock(a.preview.trim_to, &to_buf) else "end";
    ui.text(c, c.print("{s} – {s}", .{ from, to }), .{ .size = 11, .color = p.dim, .tabular = true });
    if (a.preview.trim_from > 0 or a.preview.trim_to > 0) {
        if (ui.button(c, "", .{ .variant = .ghost, .size = 11, .icon = "xmark" }).clicked) {
            a.preview.trim_from = 0;
            a.preview.trim_to = 0;
            c.changed = true;
        }
        const kept = (if (a.preview.trim_to > 0) a.preview.trim_to else m.duration) - a.preview.trim_from;
        ui.text(c, c.print("{s} kept", .{download.Download.clock(kept, &from_buf)}), .{ .size = 10, .color = p.accent, .tabular = true });
    } else {
        ui.text(c, "cuts at a keyframe, no re-encoding", .{ .size = 10, .color = p.faint });
    }
}

/// The line under the card's controls: what it will cost in bytes, and what
/// else can be done with it.
fn extras(a: *App, c: *ui.Context, p: *const theme.Palette, m: *const media.Media) void {
    const row = ui.div(c).row().itemsCenter().gap(8).wFull();
    defer row.end();
    if (a.chosen()) |fmt| {
        var sbuf: [24]u8 = undefined;
        const size = if (fmt.size > 0) download.Download.size(fmt.size, &sbuf) else "";
        if (size.len > 0) {
            ui.text(c, c.print("{s} · {s}", .{ fmt.label, size }), .{ .size = 11, .color = p.faint, .tabular = true });
        }
    }
    ui.spacer(c);
    if (m.isPlaylist()) {
        ui.text(c, c.print("{d} items", .{m.items.len}), .{ .size = 11, .color = p.dim, .tabular = true });
        if (ui.button(c, "Download all", .{ .variant = .secondary, .size = 11 }).clicked) {
            a.say("A playlist's items go in one after another", c);
        }
    }
    if (m.site != .generic) {
        if (ui.button(c, "Subscribe", .{ .variant = .ghost, .size = 11 }).clicked) {
            _ = a.subs.add(m.url, m.title, m.site) catch null;
            a.say("Following it: new videos show under Subscriptions", c);
        }
    }
}
