//! The island: what is waiting on GitHub, closed to a notch's width under
//! the menu bar and open, under the pointer or with work to show, as tall as
//! what it has to say. A row per item; a clicked row runs an agent; a run's
//! card shows its steps, its question, and the way out of it.
const std = @import("std");
const nanoui = @import("nanoui");
const ui = nanoui.ui;
const types = @import("types.zig");
const agent = @import("agent.zig");
const app_state = @import("app_state.zig");

/// The window's width, and the island's when closed: a notch's own.
pub const width: f32 = 460;
pub const closed: f32 = 224;
/// Room below the notch's row for the open island: a header, four rows.
pub const open_extra: f32 = 214;
/// How many rows the open island lists before it says how many more.
const max_rows: usize = 4;

const dark: ui.Color = .hex(0x0e0e12);
const row_hover: ui.Color = .hex(0x1c1c24);
const white: ui.Color = .hex(0xf2f2f7);
const gray: ui.Color = .hex(0xb0b0ba);
const green: ui.Color = .hex(0x4ade80);
const red: ui.Color = .hex(0xf87171);
const amber: ui.Color = .hex(0xfbbf24);
const violet: ui.Color = .hex(0xa78bfa);

pub fn view(self: *app_state.State, c: *ui.Context) void {
    // One spring grows the island and its window together, from the
    // notch's width to the panel: the capsule stays put under the pointer
    // (it is the window that grows outward around it, not the capsule
    // sliding inside a window that jumped ahead), and the window is never
    // bigger than the capsule it is drawing this frame.
    const f = ui.motion.frame(c, .{
        .target = .{ .width = closed },
        .hover = .{ .width = width },
        .transition = .{ .spring = ui.motion.Spring.visual(0.22, 0) },
    });
    const iw = f.width orelse closed;
    const isle = ui.div(c).absolute().w(iw).row().itemsCenter().clip().control().motion(f)
        .scaleAnchor(0.5, 0);
    defer isle.end();
    // Open: the pointer is on it, something is waiting, or a run is going.
    const asked = self.screen == .run or self.runs.items.len > 0 or work(self) > 0;
    const open = isle.hovered() or asked;
    const ih = ui.motion.number(c, "h", if (open) self.open_h else self.row_h, .{
        .spring = ui.motion.Spring.visual(0.22, 0),
    });
    _ = isle.h(ih);
    // The notch is cut from the screen's top edge: square along it, rounded
    // only underneath (a square piece over a same-colored capsule).
    const r: f32 = 16;
    ui.div(c).absolute().offset(0, 0).wFull().h(ih - r).bg(dark).end();
    ui.div(c).absolute().offset(0, ih - 2 * r).wFull().h(2 * r).roundedFull().bg(dark).end();

    // The window rides the island this frame, centered over the notch.
    fitWindow(self, iw, ih);

    const body = ui.div(c).column().px(14).pt(8).pb(10).gap(8).sizeFull();
    defer body.end();
    header(self, c, ih > self.row_h + 8);
    if (ih > self.row_h + 8) {
        if (self.screen == .run) run(self, c) else list(self, c);
    }
}

/// Sizes the island's window to what the island's springs draw this frame,
/// centered on the notched screen. Closed, it is only the capsule over the
/// notch's row, so what is around it keeps its clicks and its focus;
/// opening, it grows outward with the capsule rather than ahead of it, and
/// it never clips the closing capsule, because it never leaves the
/// capsule's bounds. Only the drawn island is interactive territory; a
/// transparent window is not.
fn fitWindow(self: *app_state.State, iw: f32, ih: f32) void {
    const win = self.notch orelse return;
    const want_w: f64 = @floatCast(@max(closed, iw));
    const want_h: f64 = @floatCast(@max(self.row_h, ih));
    const have = win.contentSize();
    if (have[0] == want_w and have[1] == want_h) return;
    const scr = (app_state.islandScreen() orelse return);
    win.setSize(want_w, want_h);
    win.setPosition(scr.frame.x + (scr.frame.width - want_w) / 2, scr.frame.y);
}

/// The line across the notch: what wants attention, and what is going on.
fn header(self: *app_state.State, c: *ui.Context, open: bool) void {
    const line = ui.div(c).row().itemsCenter().gap(8).wFull().h(18);
    defer line.end();
    const shown = if (self.screen == .run) self.shownItem() else top(self);
    const n = work(self);
    if (shown) |it| {
        ui.icon(c, it.kind.symbol(), .{ .size = 12, .color = color(it.state) });
        ui.text(c, it.title, .{
            .size = 12,
            .weight = .semibold,
            .color = white,
            .truncate = .ellipsis,
        });
        ui.div(c).grow().end();
        if (!open and n > 0) {
            ui.textf(c, .{ .size = 11, .color = gray }, "{d} waiting", .{n});
        }
    } else {
        ui.icon(c, "bell.slash", .{ .size = 12, .color = gray });
        ui.text(c, "noop", .{ .size = 12, .weight = .semibold, .color = white });
        ui.div(c).grow().end();
        // Closed with nothing to say: how the poll went, one line.
        if (self.status.len > 0) ui.text(c, self.status, .{ .size = 11, .color = toneColor(self.tone), .truncate = .ellipsis });
    }
    // The way into the settings: a menu bar app has no menus of its own, so
    // the gear rides in the notch itself. Only while the notch is open: the
    // pointer's own hover is what opens it, and that same hover slides the
    // gear to the island's new right edge, so a gear shown while closed
    // would move out from under the click aimed at it.
    if (open) {
        const gear = ui.div(c).row().itemsCenter().justifyCenter().w(18).h(18).rounded(6).control().hover(row_hover);
        defer gear.end();
        ui.icon(c, "gearshape", .{ .size = 11, .color = gray });
        if (gear.clicked()) self.openSettings();
    }
}

/// One row per item waiting, and how many are left over.
fn list(self: *app_state.State, c: *ui.Context) void {
    var wanted: ?usize = null;
    var seen: usize = 0;
    for (self.items.items, 0..) |*it, i| {
        if (!it.state.shown()) continue;
        if (seen == max_rows) break;
        seen += 1;
        if (row(self, c, it)) wanted = i;
    }
    if (seen == 0) {
        ui.text(c, "Nothing waiting. Pull requests, issues and mentions land here.", .{
            .size = 11,
            .color = gray,
            .wrap = true,
            .max_lines = 2,
        });
    } else if (seen == max_rows and work(self) > max_rows) {
        const more = ui.div(c).row().itemsCenter().px(8).h(20).rounded(8).control().hover(row_hover);
        defer more.end();
        ui.text(c, "and more — open noop to see all", .{ .size = 11, .color = gray, .truncate = .ellipsis });
        if (more.clicked()) self.openSettings();
    }
    if (wanted) |i| self.click(i);
}

/// A row: the kind, the title, its repo and number; a click runs an agent.
fn row(self: *app_state.State, c: *ui.Context, it: *types.Item) bool {
    _ = self;
    ui.key(c, it.key);
    const d = ui.div(c).row().itemsCenter().gap(8).wFull().h(32).px(8).rounded(9).control().hover(row_hover);
    defer d.end();
    ui.icon(c, it.kind.symbol(), .{ .size = 12, .color = color(it.state) });
    ui.text(c, it.title, .{ .size = 12, .color = white, .truncate = .ellipsis });
    ui.div(c).grow().end();
    ui.textf(c, .{ .size = 10, .color = gray, .truncate = .ellipsis }, "{s}#{d}", .{ last(it.repo), it.number });
    return d.clicked();
}

/// The item's run: its steps as they land, its question when it asks one,
/// and the way to stop it.
fn run(self: *app_state.State, c: *ui.Context) void {
    const index = self.shown;
    const it = &self.items.items[index];
    var action: ?Action = null;
    defer if (action) |a| act(self, index, a);
    {
        const line = ui.div(c).row().itemsCenter().gap(6).wFull();
        defer line.end();
        ui.text(c, it.title, .{ .size = 11, .weight = .semibold, .color = white, .truncate = .ellipsis });
        ui.div(c).grow().end();
        ui.icon(c, "folder", .{ .size = 10, .color = gray });
        ui.text(c, if (self.workspace(it.repo)) |w| w.path else "no workspace — pick a folder in Settings", .{
            .size = 10,
            .color = gray,
            .truncate = .middle,
        });
    }
    if (self.runOf(it.key)) |r| {
        progress(self, c, r, &action);
    } else if (it.decision) |d| {
        decision(self, c, d, &action);
    } else {
        const tone: ui.Color = if (it.state == .failed) red else gray;
        ui.text(c, if (it.summary.len > 0) it.summary else self.status, .{
            .size = 11,
            .color = tone,
            .wrap = true,
            .max_lines = 3,
        });
    }
}

/// What the agent is doing: its steps, the newest last, and the buttons.
fn progress(self: *app_state.State, c: *ui.Context, r: *agent.Run, action: *?Action) void {
    _ = self;
    const box = ui.div(c).column().gap(3).wFull().h(96).clip();
    defer box.end();
    const steps = r.progress.steps.items;
    const from = if (steps.len > 4) steps.len - 4 else 0;
    for (steps[from..]) |s| {
        const line = ui.div(c).row().itemsCenter().gap(6).wFull();
        defer line.end();
        ui.icon(c, "circle.fill", .{ .size = 4, .color = violet });
        ui.text(c, s.text, .{ .size = 10, .color = gray, .truncate = .ellipsis });
    }
    if (r.progress.now.len > 0) {
        const line = ui.div(c).row().itemsCenter().gap(6).wFull();
        defer line.end();
        ui.icon(c, "ellipsis", .{ .size = 10, .color = amber });
        ui.text(c, r.progress.now, .{ .size = 10, .color = amber, .truncate = .ellipsis });
    }
    {
        const buttons = ui.div(c).row().itemsCenter().gap(6).wFull().h(24);
        defer buttons.end();
        if (chip(c, "Stop", .hex(0x2c2c33), white)) action.* = .stop;
        ui.div(c).grow().end();
        ui.text(c, "running", .{ .size = 10, .color = amber });
    }
}

/// The question a run asks: its options, one tap each, and the way back.
fn decision(self: *app_state.State, c: *ui.Context, d: types.Decision, action: *?Action) void {
    _ = self;
    ui.text(c, d.question, .{ .size = 11, .color = white, .wrap = true, .max_lines = 2 });
    for (d.options.items) |o| {
        ui.key(c, o.letter);
        if (chip(c, o.text, .hex(0x24242c), if (std.mem.eql(u8, o.letter, d.recommendation)) white else gray)) {
            action.* = .{ .answer = o.letter };
        }
    }
    {
        const buttons = ui.div(c).row().itemsCenter().gap(6).wFull();
        defer buttons.end();
        if (chip(c, "Later", .hex(0x1c1c24), gray)) action.* = .later;
        ui.div(c).grow().end();
        if (chip(c, "Dismiss", .hex(0x1c1c24), gray)) action.* = .dismiss;
    }
}

const Action = union(enum) {
    stop,
    later,
    dismiss,
    answer: []const u8,
};

fn act(self: *app_state.State, index: usize, a: Action) void {
    switch (a) {
        .stop => self.cancelShown(),
        .later => self.back(),
        .dismiss => self.dismiss(index),
        .answer => |letter| self.answer(index, letter),
    }
}

/// A button in the island: its label, a background, and whether it was hit.
fn chip(c: *ui.Context, label: []const u8, bg: ui.Color, fg: ui.Color) bool {
    const d = ui.div(c).row().itemsCenter().px(10).h(22).rounded(7).bg(bg).control().hover(.hex(0x2c2c36));
    defer d.end();
    ui.text(c, label, .{ .size = 10, .weight = .semibold, .color = fg, .truncate = .ellipsis });
    return d.clicked();
}

/// The first item that wants a tap: the island's face when closed.
fn top(self: *app_state.State) ?*types.Item {
    for (self.items.items) |*it| {
        if (it.state.shown()) return it;
    }
    return null;
}

/// How many items are waiting for a tap.
fn work(self: *app_state.State) usize {
    var n: usize = 0;
    for (self.items.items) |it| {
        if (it.state.shown()) n += 1;
    }
    return n;
}

fn color(state: types.State) ui.Color {
    return switch (state) {
        .waiting => violet,
        .running => amber,
        .needs_decision => amber,
        .done => green,
        .failed => red,
        .dismissed => gray,
    };
}

fn toneColor(tone: app_state.Tone) ui.Color {
    return switch (tone) {
        .quiet => gray,
        .busy => amber,
        .worry => red,
    };
}

/// The repo's name, not its owner's: "nanoui" from "sternelee/nanoui".
fn last(repo: []const u8) []const u8 {
    if (std.mem.lastIndexOfScalar(u8, repo, '/')) |i| return repo[i + 1 ..];
    return repo;
}
