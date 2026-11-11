//! Settings: the workspaces that bind a repo to a folder on this machine,
//! the agent that runs there, and how often noop looks at GitHub.
const std = @import("std");
const nanoui = @import("nanoui");
const ui = nanoui.ui;
const types = @import("types.zig");
const app_state = @import("app_state.zig");

const dark: ui.Color = .hex(0x0e0e12);
const card: ui.Color = .hex(0x16161c);
const row_hover: ui.Color = .hex(0x1f1f27);
const white: ui.Color = .hex(0xf2f2f7);
const gray: ui.Color = .hex(0xb0b0ba);
const violet: ui.Color = .hex(0xa78bfa);

/// The window, made once and shown after: its view reads the app's state.
pub fn open(self: *app_state.State) void {
    if (self.settings_win) |w| {
        w.show();
        w.focus();
        return;
    }
    const w = self.app.newWindow(.{
        .title = "noop settings",
        .width = 560,
        .height = 520,
        .resizable = false,
        .content = .{ .view = .init(self, view) },
    }) catch return;
    self.settings_win = w;
    w.show();
    w.focus();
}

pub fn view(self: *app_state.State, c: *ui.Context) void {
    const page = ui.div(c).column().sizeFull().bg(dark).p(18).gap(12);
    defer page.end();
    {
        const head = ui.div(c).row().itemsCenter().gap(10).wFull();
        defer head.end();
        ui.icon(c, "bell.badge", .{ .size = 16, .color = violet });
        ui.text(c, "noop", .{ .size = 16, .weight = .bold, .color = white });
        ui.div(c).grow().end();
        if (chip(c, "Look now", .hex(0x24242c), white)) self.start();
        if (chip(c, "Close", .hex(0x24242c), gray)) {
            if (self.settings_win) |w| w.hide();
        }
    }
    ui.text(c, "Pull requests, issues and comments that want an answer arrive in the notch. Clicking one runs an agent in the folder bound to its repo.", .{
        .size = 11,
        .color = gray,
        .wrap = true,
        .max_lines = 3,
    });
    if (self.status.len > 0) {
        ui.text(c, self.status, .{ .size = 11, .color = if (self.tone == .worry) .hex(0xf87171) else gray, .wrap = true, .max_lines = 2 });
    }
    workspaces(self, c);
    look(self, c);
    repos(self, c);
}

fn workspaces(self: *app_state.State, c: *ui.Context) void {
    heading(c, "Workspaces");
    var act: ?Action = null;
    var typed: [120]u8 = undefined;
    var typed_len: usize = 0;
    defer if (act) |a| run(self, a);
    if (self.settings.workspaces.items.len == 0) {
        ui.text(c, "No repo is bound yet: type one below, and its folder tells the agent where to work.", .{
            .size = 11,
            .color = gray,
            .wrap = true,
            .max_lines = 2,
        });
    }
    for (self.settings.workspaces.items, 0..) |*w, i| {
        ui.keyInt(c, i);
        const row = ui.div(c).column().gap(4).wFull().p(10).rounded(10).bg(card);
        defer row.end();
        {
            const one = ui.div(c).row().itemsCenter().gap(8).wFull();
            defer one.end();
            ui.icon(c, "folder", .{ .size = 12, .color = gray });
            ui.text(c, w.repo, .{ .size = 12, .weight = .semibold, .color = white, .truncate = .ellipsis });
            ui.div(c).grow().end();
            // The agent, and its model, one tap between them.
            if (chip(c, "claude", if (w.agent == .claude) .hex(0x3b2f63) else .hex(0x1c1c24), if (w.agent == .claude) white else gray)) act = .{ .agent = .{ i, .claude } };
            if (chip(c, "codex", if (w.agent == .codex) .hex(0x3b2f63) else .hex(0x1c1c24), if (w.agent == .codex) white else gray)) act = .{ .agent = .{ i, .codex } };
        }
        {
            const one = ui.div(c).row().itemsCenter().gap(8).wFull();
            defer one.end();
            ui.text(c, if (w.path.len > 0) w.path else "no folder", .{ .size = 11, .color = if (w.path.len > 0) gray else .hex(0xf87171), .truncate = .middle });
            ui.div(c).grow().end();
            if (chip(c, "Choose folder…", .hex(0x24242c), white)) act = .{ .bind = i };
            if (chip(c, "Forget", .hex(0x1c1c24), gray)) act = .{ .forget = i };
        }
    }
    // The next repo, typed as `owner/name`: its folder is asked for at once.
    // Nothing is read from GitHub until a workspace names a repo. The button
    // sits after the field, where a form's answers are: on the right.
    {
        const one = ui.div(c).row().itemsCenter().gap(8).wFull().h(28);
        defer one.end();
        const field = ui.textField(c, &self.repo_text, .{
            .placeholder = "owner/name",
            .size = 12,
            .mono = true,
        });
        ui.div(c).grow().end();
        var wanted = field.submitted;
        if (chip(c, "Add", .hex(0x2a2340), violet)) wanted = true;
        if (!wanted) return;
        const name = std.mem.trim(u8, self.repo_text.text(), " \t\r\n");
        if (name.len == 0) {
            self.setStatus("type the repo as owner/name, like egoist/noop", .worry);
            return;
        }
        if (name.len > typed.len) {
            self.setStatus("that is longer than a repo name", .worry);
            return;
        }
        const at = @min(name.len, typed.len);
        @memcpy(typed[0..at], name[0..at]);
        typed_len = at;
        act = .{ .name = typed[0..typed_len] };
    }
}

/// How often to look, and what counts as wanting attention.
fn look(self: *app_state.State, c: *ui.Context) void {
    heading(c, "Looking");
    var act: ?Action = null;
    defer if (act) |a| run(self, a);
    {
        const row = ui.div(c).row().itemsCenter().gap(10).wFull().h(28);
        defer row.end();
        ui.text(c, "Every", .{ .size = 12, .color = white });
        ui.div(c).grow().end();
        if (chip(c, "−", .hex(0x24242c), white)) act = .shorter;
        ui.textf(c, .{ .size = 12, .color = gray }, "{d} min", .{self.settings.every});
        if (chip(c, "+", .hex(0x24242c), white)) act = .longer;
    }
    ui.textf(c, .{ .size = 11, .color = gray }, "GitHub is checked every {d} min", .{self.settings.every});
    toggle(self, c, "Only notifications that mention me", self.settings.participating_only, .participating, &act);
    toggle(self, c, "Run agents without asking for permissions", self.settings.unattended, .unattended, &act);
}

fn toggle(self: *app_state.State, c: *ui.Context, label: []const u8, on: bool, what: Action, act: *?Action) void {
    _ = self;
    const row = ui.div(c).row().itemsCenter().gap(8).wFull().h(26).control().hover(row_hover);
    defer row.end();
    ui.icon(c, if (on) "checkmark.square.fill" else "square", .{ .size = 13, .color = if (on) violet else gray });
    ui.text(c, label, .{ .size = 12, .color = white, .truncate = .ellipsis });
    ui.div(c).grow().end();
    if (row.clicked()) act.* = what;
}

/// The repos noop has seen that have no workspace yet: one tap each.
fn repos(self: *app_state.State, c: *ui.Context) void {
    var fresh: usize = 0;
    for (self.items.items) |it| {
        if (self.settings.find(it.repo) == null) fresh += 1;
    }
    if (fresh == 0) return;
    heading(c, "Repos noop has seen");
    var act: ?Action = null;
    defer if (act) |a| run(self, a);
    var seen: std.ArrayList([]const u8) = .empty;
    defer seen.deinit(self.gpa);
    for (self.items.items) |it| {
        var known = false;
        for (seen.items) |r| {
            if (std.mem.eql(u8, r, it.repo)) known = true;
        }
        if (known) continue;
        seen.append(self.gpa, it.repo) catch return;
        if (self.settings.find(it.repo) != null) continue;
        const row = ui.div(c).row().itemsCenter().gap(8).wFull().h(28).control().hover(row_hover);
        defer row.end();
        ui.icon(c, "arrow.triangle.branch", .{ .size = 12, .color = gray });
        ui.text(c, it.repo, .{ .size = 12, .color = white, .truncate = .ellipsis });
        ui.div(c).grow().end();
        if (chip(c, "Bind folder…", .hex(0x24242c), white)) act = .{ .add = it.repo };
    }
}

fn heading(c: *ui.Context, text: []const u8) void {
    ui.text(c, text, .{ .size = 11, .weight = .semibold, .color = gray });
}

fn chip(c: *ui.Context, label: []const u8, bg: ui.Color, fg: ui.Color) bool {
    const d = ui.div(c).row().itemsCenter().px(9).h(22).rounded(7).bg(bg).control().hover(.hex(0x2c2c36));
    defer d.end();
    ui.text(c, label, .{ .size = 10, .weight = .semibold, .color = fg, .truncate = .ellipsis });
    return d.clicked();
}

const Action = union(enum) {
    agent: struct { usize, types.Agent },
    bind: usize,
    forget: usize,
    shorter,
    longer,
    participating,
    unattended,
    add: []const u8,
    /// A repo just typed into the panel, `owner/name`.
    name: []const u8,
};

fn run(self: *app_state.State, a: Action) void {
    switch (a) {
        .agent => |v| {
            const at = v[0];
            if (at >= self.settings.workspaces.items.len) return;
            self.settings.workspaces.items[at].agent = v[1];
            self.save();
            self.refresh();
        },
        .bind => |at| pick(self, at, null),
        .add => |repo| pick(self, null, repo),
        // What was typed is read as `owner/name` before anything is bound, so
        // a pasted URL works and a folder named after nothing never does.
        .name => |raw| {
            const repo = types.repoFrom(&self.repo_clean, raw) orelse {
                self.setStatus("that is not a repo: type it as owner/name, like egoist/noop", .worry);
                return;
            };
            pick(self, null, repo);
        },
        .forget => |at| self.forgetWorkspace(at),
        .shorter => bump(self, false),
        .longer => bump(self, true),
        .participating => {
            self.settings.participating_only = !self.settings.participating_only;
            self.save();
            self.refresh();
        },
        .unattended => {
            self.settings.unattended = !self.settings.unattended;
            self.save();
            self.refresh();
        },
    }
}

/// Every look is at least half a minute apart, and at most a quarter hour.
/// The row beneath the buttons says what the number means, so the change
/// shows right where it was made.
fn bump(self: *app_state.State, up: bool) void {
    const step: u32 = 30;
    self.settings.every = if (up)
        @min(900, self.settings.every + step)
    else
        @max(30, self.settings.every - step);
    self.save();
    self.refresh();
}

/// The folder picker: a workspace's folder, or a repo's first one.
fn pick(self: *app_state.State, at: ?usize, repo: ?[]const u8) void {
    const paths = nanoui.dialog.open(self.gpa, .{
        .title = "Where should noop work?",
        .button = "Bind",
        .message = "The agent runs here, in this repo's checkout.",
        .files = false,
        .directories = true,
    }) catch null;
    const found = paths orelse return;
    defer nanoui.dialog.freePaths(self.gpa, found);
    if (found.len == 0) return;
    if (at) |i| {
        self.bind(i, found[0]);
    } else if (repo) |r| {
        // The field empties only once a workspace took the repo: a canceled
        // folder dialog keeps what was typed.
        if (self.addWorkspace(r, found[0])) self.repo_text.clear();
    }
}
