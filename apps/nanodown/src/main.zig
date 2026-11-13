//! nanodown: a link in, a file out. The window is the app; the same binary
//! is the command, as nanodown's is: with arguments it runs them, without it
//! opens the window.
const std = @import("std");
const builtin = @import("builtin");
const nanoui = @import("nanoui");
const ui = nanoui.ui;
const App = @import("app.zig").App;
const capture_flow = @import("capture_flow.zig");
const theme = @import("theme.zig");
const cli = @import("cli.zig");

pub const std_options: std.Options = .{ .log_level = .warn };

pub fn main(init: std.process.Init) !void {
    const args = try init.minimal.args.toSlice(init.arena.allocator());
    // Arguments, and no window: the command. `--help` is a command too, not
    // a flag on a window that was never asked for.
    if (args.len > 1 and (!isFlag(args[1]) or isHelp(args[1]))) {
        const code = try cli.run(init, args[1..]);
        if (code != 0) std.process.exit(code);
        return;
    }

    const app = try nanoui.App.create(init, .{ .name = "nanodown" });
    defer app.destroy();
    var state = try App.init(app.gpa, init.environ_map.get("HOME") orelse ".");
    defer state.deinit();

    // The hidden page that reads a signing site's own player reports what it
    // asks for through this service.
    var capture_service: capture_flow.Capture = .{ .app = &state };
    try app.bind(&capture_service);

    if (builtin.os.tag == .macos) try @import("menu_bar.zig").install(app, &state);

    const window = try app.newWindow(.{
        .title = "nanodown",
        .width = 860,
        .height = 640,
        .min_width = 620,
        .min_height = 420,
        .title_bar = .hidden,
        .traffic_lights = .{ .x = 20, .y = theme.metrics.lights_center },
        .content = .{ .view = .init(&state, @import("view.zig").view) },
    });
    state.window = window;

    // A link on the command line, with the window: read it at once.
    for (args[1..]) |arg| {
        if (isFlag(arg)) continue;
        state.field.set(arg);
        break;
    }
    try app.run();
    state.window = null;
}

fn isFlag(arg: []const u8) bool {
    return std.mem.startsWith(u8, arg, "-");
}

fn isHelp(arg: []const u8) bool {
    return std.mem.eql(u8, arg, "--help") or std.mem.eql(u8, arg, "-h");
}
