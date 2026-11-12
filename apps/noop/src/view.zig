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

/// The corner radius of the island's shape: the notch's own, so the
/// island reads as extruded from the screen rather than laid on it.
const shape_r: f32 = 16;

pub fn view(self: *app_state.State, c: *ui.Context) void {
    // The open island's window never changes size: the springs grow the
    // island inside its fixed canvas. A window resized while its layer
    // presents is a live resize the whole animation through — the layer's
    // last drawable is older than its bounds, and the strip it doesn't
    // cover flashes. So the panel is its own window, shown and hidden,
    // never resized; the capsule under it is another, and at rest the two
    // draw the same pixels in the same place.
    const open = self.islandOpen();
    // One frame for both of the island's sizes. `initial` is what a fresh
    // motion state starts from — the panel's first frame must be exactly
    // the capsule the capsule window is already drawing, or the handoff
    // itself is the flash. Width is the pointer's (hover), height is the
    // island's state (hover, a run, or something waiting).
    const f = ui.motion.frame(c, .{
        .target = .{ .width = closed, .height = if (open) self.open_h else self.row_h },
        .hover = .{ .width = width },
        .initial = .{ .width = closed, .height = self.row_h },
        .transition = .{ .spring = ui.motion.Spring.visual(0.3, 0.22) },
    });
    const iw = f.width orelse closed;
    const ih = f.height orelse self.row_h;
    // The island's shape is its own background: one rounded rectangle, the
    // top corners' arcs leaving the screen's top edge as a smooth curve
    // where the menu bar shows through, the bottom's as the capsule's.
    // Drawn as a child would double the corners.
    const isle = ui.div(c).absolute().offset((c.size.w - iw) / 2, 0).row().itemsCenter().clip().control().motion(f)
        .scaleAnchor(0.5, 0)
        .rounded(shape_r)
        .bg(dark);
    defer isle.end();
    // Open: the pointer is on it, something is waiting, or a run is going.
    self.hover_panel = isle.hovered();
    // Resting (near enough: springs settle asymptotically) and closed:
    // the moment the panel window can leave the screen.
    const settled = (@abs(iw - closed) < 0.5 or @abs(iw - width) < 0.5) and
        (@abs(ih - self.row_h) < 0.5 or @abs(ih - self.open_h) < 0.5);
    self.panel_rests = !open and settled;
    const body = ui.div(c).column().px(14).pt(8).pb(10).gap(8).sizeFull();
    defer body.end();
    header(self, c, ih > self.row_h + 8);
    if (ih > self.row_h + 8) {
        if (self.screen == .run) run(self, c) else list(self, c);
    }
    // Last, having drawn this frame: whether the panel window should be
    // on screen at all.
    self.syncPanel();
}

/// The closed capsule's own window: the notch's row, nothing more. It
/// never changes size, so it never shows a drawable of the wrong shape,
/// and being exactly the capsule, nothing around the notch loses its
/// clicks. Its hover is what opens the panel; the panel's is what keeps
/// it open, and at rest the two draw the same pixels in the same place,
/// so the handoff in either direction is nothing to see.
pub fn capsule(self: *app_state.State, c: *ui.Context) void {
    // The same shape the panel draws at rest, pixel for pixel: one rounded
    // rectangle, the top corners leaving a smooth curve where the island
    // meets the screen's top edge.
    const root = ui.div(c).absolute().wFull().hFull().row().itemsCenter().clip().control().rounded(shape_r).bg(dark);
    defer root.end();
    self.hover_capsule = root.hovered();
    const pad = ui.div(c).column().px(14).pt(8).sizeFull();
    defer pad.end();
    header(self, c, false);
    self.syncPanel();
}

/// The line across the notch: what wants attention, and what is going on.
fn header(self: *app_state.State, c: *ui.Context, open: bool) void {
    const line = ui.div(c).row().itemsCenter().gap(8).wFull().h(18);
    defer line.end();
    const shown = if (self.screen == .run) self.shownItem() else top(self);
    const n = self.waiting();
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
