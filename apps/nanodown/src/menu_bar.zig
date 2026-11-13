//! The Mac's menu bar: the app's own File and Downloads menus over the
//! framework's roles, so ⌘⇧V downloads what was copied and ⌘⌥P pauses
//! everything.
const nanoui = @import("nanoui");
const App = @import("app.zig").App;

const MenuItem = nanoui.MenuItem;

fn downloadCopied(a: *App, _: *nanoui.menu.Item) void {
    const text = nanoui.clipboard.readText(a.gpa) catch return;
    defer if (text) |t| a.gpa.free(t);
    const link = text orelse return;
    a.field.set(link);
    if (a.window) |w| w.focus();
    a.redraw();
}

fn openBrowser(a: *App, _: *nanoui.menu.Item) void {
    _ = a;
    _ = nanoui.shell.openUrl("https://github.com/sternelee/nanoui");
}

fn pauseAll(a: *App, _: *nanoui.menu.Item) void {
    a.lib.pauseAll();
    a.redraw();
}

fn resumeAll(a: *App, _: *nanoui.menu.Item) void {
    a.lib.resumeAll();
    a.redraw();
}

fn clearFinished(a: *App, _: *nanoui.menu.Item) void {
    _ = a.lib.clearFinished();
    a.save();
    a.redraw();
}

fn openFolder(a: *App, _: *nanoui.menu.Item) void {
    _ = nanoui.shell.openPath(a.folder);
}

fn settings(a: *App, _: *nanoui.menu.Item) void {
    a.show_settings = true;
    a.redraw();
}

pub fn install(app: *nanoui.App, a: *App) !void {
    const file = [_]MenuItem{
        .{ .label = "Download Copied Link", .accelerator = "CmdOrCtrl+Shift+V", .click = .of(a, downloadCopied) },
        .{ .label = "Open the Browser", .accelerator = "CmdOrCtrl+B", .click = .of(a, openBrowser) },
        .{ .is_separator = true },
        .{ .label = "Open the Downloads Folder", .accelerator = "CmdOrCtrl+Shift+O", .click = .of(a, openFolder) },
        .{ .is_separator = true },
        .{ .label = "Settings…", .accelerator = "CmdOrCtrl+,", .click = .of(a, settings) },
    };
    const downloads = [_]MenuItem{
        .{ .label = "Pause All", .accelerator = "CmdOrCtrl+Alt+P", .click = .of(a, pauseAll) },
        .{ .label = "Resume All", .accelerator = "CmdOrCtrl+Alt+R", .click = .of(a, resumeAll) },
        .{ .is_separator = true },
        .{ .label = "Clear Finished", .accelerator = "CmdOrCtrl+Shift+K", .click = .of(a, clearFinished) },
    };
    const window = [_]MenuItem{ .{ .role = .minimize }, .{ .role = .zoom }, .{ .is_separator = true }, .{ .role = .front } };
    try app.setMenu(&.{
        .{ .role = .app_menu },
        .{ .label = "File", .submenu = &file },
        .{ .role = .edit_menu },
        .{ .label = "Downloads", .submenu = &downloads },
        .{ .role = .view_menu },
        .{ .label = "Window", .submenu = &window },
    });
}
