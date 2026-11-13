//! Prototype: a hidden webview plays a YouTube page and reports the media
//! URLs the player itself asks for. The download stays Zig's job; this only
//! borrows the page's own signature.
const std = @import("std");
const nanoui = @import("nanoui");

/// The page's side: hook fetch and XHR before the player runs, and post every
/// googlevideo request back to Zig.
const hook =
    \\(() => {
    \\  if (window.__ndHooked) return;
    \\  window.__ndHooked = 1;
    \\  const seen = new Set();
    \\  const report = (u) => {
    \\    if (!u || !String(u).includes('googlevideo.com/videoplayback')) return;
    \\    if (seen.has(u)) return;
    \\    seen.add(u);
    \\    try { window.nanoui.call('Probe.found', String(u)); } catch (e) {}
    \\  };
    \\  const of = window.fetch;
    \\  window.fetch = function (input, init) {
    \\    try { report(typeof input === 'string' ? input : (input && input.url)); } catch (e) {}
    \\    return of.apply(this, arguments);
    \\  };
    \\  const oo = XMLHttpRequest.prototype.open;
    \\  XMLHttpRequest.prototype.open = function (m, u) {
    \\    try { report(u); } catch (e) {}
    \\    return oo.apply(this, arguments);
    \\  };
    \\  const d = Object.getOwnPropertyDescriptor(HTMLMediaElement.prototype, 'src');
    \\  if (d && d.set) {
    \\    Object.defineProperty(HTMLMediaElement.prototype, 'src', {
    \\      set(v) { try { report(v); } catch (e) {} return d.set.call(this, v); },
    \\      get() { return d.get.call(this); },
    \\    });
    \\  }
    \\})();
;

const Probe = struct {
    count: usize = 0,
    urls: std.ArrayList([]const u8) = .empty,
    gpa: std.mem.Allocator,

    pub fn found(self: *Probe, url: []const u8) !void {
        self.count += 1;
        std.debug.print("FOUND {d}: {s}\n", .{ self.count, url[0..@min(url.len, 200)] });
        try self.urls.append(self.gpa, try self.gpa.dupe(u8, url));
    }
};

var g_window: ?*nanoui.Window = null;
var g_probe: ?*Probe = null;

pub fn main(init: std.process.Init) !void {
    const args = try init.minimal.args.toSlice(init.arena.allocator());
    const target = if (args.len > 1) args[1] else "https://www.youtube.com/watch?v=aqz-KE-bpKQ";

    const app = try nanoui.App.create(init, .{ .name = "proto" });
    defer app.destroy();

    var probe: Probe = .{ .gpa = app.gpa };
    defer probe.urls.deinit(app.gpa);
    try app.bind(&probe);
    g_probe = &probe;

    const window = try app.newWindow(.{
        .title = "proto",
        .width = 900,
        .height = 620,
        .visible = false,
        .content = .{ .page = .{ .url = target, .inspectable = false } },
    });
    g_window = window;

    nanoui.App.after(1500, app, inject);
    nanoui.App.after(4000, app, check);
    nanoui.App.after(14000, app, report);
    try app.run();
}

fn inject(ctx: ?*anyopaque) callconv(.c) void {
    _ = ctx;
    const w = g_window orelse return;
    if (w.page) |p| p.queue.eval(hook);
}

fn check(ctx: ?*anyopaque) callconv(.c) void {
    _ = ctx;
    const w = g_window orelse return;
    if (w.page) |p| p.queue.eval(
        \\(() => { try { window.nanoui.call('Probe.found', 'DIAG url=' + location.href + ' hooked=' + (window.__ndHooked||0) + ' fetch=' + (window.fetch.toString().slice(0,40))); } catch (e) {} })();
    );
}

fn report(ctx: ?*anyopaque) callconv(.c) void {
    const app: *nanoui.App = @ptrCast(@alignCast(ctx));
    if (g_probe) |p| std.debug.print("--- total {d}\n", .{p.count});
    app.quit();
}
