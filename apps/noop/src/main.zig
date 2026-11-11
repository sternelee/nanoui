//! This app's window on the screen: the island in the menu bar's row, as
//! tall as the notch and as wide as what it has to say.
const std = @import("std");
const nanoui = @import("nanoui");
const app_state = @import("app_state.zig");
const view = @import("view.zig");
const settings_view = @import("settings_view.zig");
const cmd = @import("cmd.zig");

pub fn main(init: std.process.Init) !void {
    // Children (`gh`, the agents) inherit this environment; without it they
    // start with none at all: no PATH, no HOME, no `~/.config/gh`.
    cmd.environ = init.minimal.environ;
    const app = try nanoui.App.create(init, .{
        .name = "noop",
        // A menu bar app: no Dock icon, no menus of its own.
        .activation = .accessory,
        // The island closing is not the app quitting; ⌘Q is.
        .quit_on_last_window_closed = false,
    });
    defer app.destroy();
    const scr = nanoui.screens.mainScreen() orelse return error.NoScreen;
    var state = app_state.State.init(init.gpa, app);
    defer state.deinit();
    state.opener = settings_view.open;
    // The notch's own row where there is one, the menu bar's otherwise, and
    // room below it for the island to open into.
    state.row_h = @floatCast(@max(32, scr.menuBarHeight()));
    state.open_h = state.row_h + view.open_extra;
    state.notch = try app.newWindow(.{
        .title = "noop",
        .width = view.width,
        .height = state.open_h,
        .x = (scr.frame.width - view.width) / 2,
        .y = 0,
        .resizable = false,
        .decorations = false,
        .kind = .panel,
        .non_activating = true,
        .all_spaces = true,
        .skip_taskbar = true,
        .level = .island,
        .transparent = true,
        .content = .{ .view = .init(&state, view.view) },
    });
    state.start();
    try app.run();
}
