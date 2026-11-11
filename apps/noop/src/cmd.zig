//! Commands run without a shell, their bytes arriving on the main thread as
//! the process writes them: argv straight to the operating system, its pipes
//! watched with `nanoui.fdwatch`, its exit watched too. Nothing polls; a
//! command that never answers is a command with no event, and a timeout is
//! the caller's `App.after`.
//!
//!     _ = cmd.start(gpa, .{
//!         .argv = &.{ "gh", "auth", "status" },
//!         .on_done = struct {
//!             fn f(_: ?*anyopaque, d: cmd.Done) void { ... }
//!         }.f,
//!     }) catch |e| { ... };
const std = @import("std");
const fdwatch = @import("nanoui").fdwatch;

pub const DataFn = *const fn (ctx: ?*anyopaque, bytes: []const u8) void;
pub const DoneFn = *const fn (ctx: ?*anyopaque, done: Done) void;

/// How a command ended. `code` is its exit status, null when it never
/// started, was canceled, or died on a signal; `out` is what it wrote,
/// owned by the callback; `err` says why it never started, else empty.
pub const Done = struct {
    out: []u8 = &.{},
    code: ?u8 = null,
    err: []const u8 = "",

    pub fn ok(d: Done) bool {
        return d.code != null and d.code.? == 0 and d.err.len == 0;
    }
};

pub const Options = struct {
    /// The program, and its arguments. A bare name is looked up in `PATH`
    /// and the usual places for a command line tool, because an app started
    /// from the Finder has a `PATH` of its own; see `find`.
    argv: []const []const u8,
    /// The command's working directory; the app's own when null.
    dir: ?[]const u8 = null,
    /// Bytes for the command's stdin, written before its watch begins, then
    /// closed. A command that reads no stdin does not miss them.
    stdin: []const u8 = "",
    /// The command's error stream folded into `out` — where a person reads
    /// it — or left on the terminal, where bytes are parsed.
    stderr_to_out: bool = true,
    /// One call per chunk, as it arrives.
    on_data: ?DataFn = null,
    on_done: DoneFn,
    ctx: ?*anyopaque = null,
};

pub const Cmd = struct {
    gpa: std.mem.Allocator,
    opts: Options,
    out: std.ArrayList(u8) = .empty,
    child: std.process.Child,
    /// The bytes of argv, and the array: both freed at the end.
    argv_bytes: []u8,
    argv: [][:0]const u8,
    /// 0: the command's output, 1: its errors, 2: its exit.
    watches: [3]?fdwatch.Watch = .{ null, null, null },
    open: u8 = 1,
    exited: bool = false,
    done: bool = false,

};

/// Processes need an `Io` made with a real allocator: the global
/// single-threaded one fails every allocation, so it can never start one.
var threaded: ?std.Io.Threaded = null;

/// What a child inherits. An `Io.Threaded` made without this hands every
/// child an empty environment: no PATH, no HOME, so `gh` found no login and
/// the agent found no toolchain.
pub var environ: std.process.Environ = .empty;

fn io(gpa: std.mem.Allocator) std.Io {
    if (threaded == null) threaded = std.Io.Threaded.init(gpa, .{ .environ = environ });
    return (&threaded.?).io();
}

/// Starts a command and returns at once; `on_done` answers later, on the
/// main thread. `error.CommandNotFound` when the program is not installed.
pub fn start(gpa: std.mem.Allocator, opts: Options) !*Cmd {
    if (opts.argv.len == 0 or opts.argv[0].len == 0) return error.EmptyArgv;

    // Every argument ends in a zero. One allocation holds them all, so the
    // pointers into it stay valid while the array is filled.
    var total: usize = 0;
    for (opts.argv) |a| total += a.len + 1;
    const owned_bytes = try gpa.alloc(u8, total);
    errdefer gpa.free(owned_bytes);
    const owned_argv = try gpa.alloc([:0]const u8, opts.argv.len);
    errdefer gpa.free(owned_argv);
    var at: usize = 0;
    for (opts.argv, 0..) |a, i| {
        @memcpy(owned_bytes[at..][0..a.len], a);
        owned_bytes[at + a.len] = 0;
        owned_argv[i] = owned_bytes[at..][0..a.len :0];
        at += a.len + 1;
    }

    // A bare program name is looked up first: the system's spawn takes
    // argv[0] as the file to run, and does not search PATH itself.
    var program: ?[:0]u8 = null;
    defer if (program) |p| gpa.free(p);
    if (std.mem.indexOfScalar(u8, opts.argv[0], '/') == null) {
        const found = find(gpa, opts.argv[0]) orelse return error.CommandNotFound;
        defer gpa.free(found);
        const p = try gpa.allocSentinel(u8, found.len, 0);
        @memcpy(p, found);
        program = p;
        owned_argv[0] = p;
    }

    const child = std.process.spawn(io(gpa), .{
        .argv = owned_argv,
        .cwd = if (opts.dir) |d| .{ .path = d } else .inherit,
        .stdin = if (opts.stdin.len > 0) .pipe else .ignore,
        .stdout = .pipe,
        .stderr = if (opts.stderr_to_out) .pipe else .inherit,
    }) catch |e| {
        // The errdefers above free both allocations on the way out.
        return switch (e) {
            error.FileNotFound => error.CommandNotFound,
            else => e,
        };
    };
    const self = try gpa.create(Cmd);
    self.* = .{
        .gpa = gpa,
        .opts = opts,
        .child = child,
        .argv_bytes = owned_bytes,
        .argv = owned_argv,
    };
    // An error stream the caller never sees is a stream never watched.
    self.open = if (opts.stderr_to_out) 2 else 1;

    if (opts.stdin.len > 0) {
        if (child.stdin) |f| {
            f.writeStreamingAll(io(self.gpa), opts.stdin) catch {};
            f.close(io(self.gpa));
        }
    }
    watch(self, 0, child.stdout) catch return fail(self, "its output could not be watched");
    if (opts.stderr_to_out) {
        if (child.stderr) |f| watch(self, 1, f) catch return fail(self, "its errors could not be watched");
    }
    if (child.id) |pid| watchExit(self, pid) catch {};
    return self;
}

fn fail(self: *Cmd, why: []const u8) error{ CouldNotWatch, OutOfMemory } {
    finish(self, .{ .out = &.{}, .err = why });
    return error.CouldNotWatch;
}

fn watch(self: *Cmd, slot: usize, maybe: ?std.Io.File) !void {
    const f = maybe orelse return;
    const handler: fdwatch.Handler = switch (slot) {
        0 => onOutput,
        1 => onError,
        else => unreachable,
    };
    self.watches[slot] = try fdwatch.readable(f.handle, self, handler);
}

fn watchExit(self: *Cmd, pid: std.posix.pid_t) !void {
    self.watches[2] = try fdwatch.exited(pid, self, onExit);
}

fn onOutput(ctx: ?*anyopaque) callconv(.c) void {
    read(@ptrCast(@alignCast(ctx)), 0);
}

fn onError(ctx: ?*anyopaque) callconv(.c) void {
    read(@ptrCast(@alignCast(ctx)), 1);
}

fn onExit(ctx: ?*anyopaque) callconv(.c) void {
    const self: *Cmd = @ptrCast(@alignCast(ctx));
    self.exited = true;
    if (self.watches[2]) |w| w.cancel();
    self.watches[2] = null;
    maybeFinish(self);
}

/// One chunk of one stream: what is there, and no more — the descriptor is
/// a blocking one, and the next event says there is more still to read.
fn read(self: *Cmd, slot: usize) void {
    const f = switch (slot) {
        0 => self.child.stdout,
        1 => self.child.stderr,
        else => return,
    } orelse return closed(self, slot);
    var buf: [16 * 1024]u8 = undefined;
    const n = std.posix.read(f.handle, &buf) catch 0;
    if (n == 0) return closed(self, slot);
    self.out.appendSlice(self.gpa, buf[0..n]) catch return closed(self, slot);
    if (self.opts.on_data) |cb| cb(self.opts.ctx, buf[0..n]);
}

fn closed(self: *Cmd, slot: usize) void {
    if (self.watches[slot]) |w| w.cancel();
    self.watches[slot] = null;
    if (self.open > 0) self.open -= 1;
    maybeFinish(self);
}

/// Both streams at their end, and the process gone: the last thing read is
/// already in `out`, so the wait only collects the status.
fn maybeFinish(self: *Cmd) void {
    if (self.done or self.open > 0 or !self.exited) return;
    const term = self.child.wait(io(self.gpa)) catch null;
    const code: ?u8 = if (term) |t| switch (t) {
        .exited => |n| n,
        else => null,
    } else null;
    finish(self, .{
        .out = self.out.toOwnedSlice(self.gpa) catch &.{},
        .code = code,
    });
}

fn finish(self: *Cmd, d: Done) void {
    if (self.done) return;
    self.done = true;
    for (&self.watches) |*w| {
        if (w.*) |source| {
            source.cancel();
            w.* = null;
        }
    }
    const cb = self.opts.on_done;
    const ctx = self.opts.ctx;
    self.gpa.free(self.argv);
    self.gpa.free(self.argv_bytes);
    cb(ctx, d);
    self.gpa.destroy(self);
}

/// Where a command line tool lives, besides `PATH`: the places Homebrew,
/// bun, cargo and a user's own bin install to. An app started from the
/// Finder or Dock gets a `PATH` of four system directories, which is how a
/// installed `gh` goes missing.
const home_dirs = [_][]const u8{
    "/opt/homebrew/bin",
    "/usr/local/bin",
    ".local/bin", // relative to the home directory
    ".bun/bin",
    ".cargo/bin",
};

/// The full path of `name`, or null where it is not installed. `argv` then
/// starts with what this returns, so the parent's `PATH` stops mattering.
pub fn find(gpa: std.mem.Allocator, name: []const u8) ?[]u8 {
    if (std.fs.path.dirname(name) != null) { // written as a path already
        if (!good(gpa, name)) return null;
        return gpa.dupe(u8, name) catch null;
    }
    var buf: [4096]u8 = undefined;
    const home: []const u8 = if (std.c.getenv("HOME")) |h| std.mem.span(h) else "/";
    var dirs = std.mem.splitScalar(u8, if (std.c.getenv("PATH")) |p| std.mem.span(p) else "", ':');
    while (dirs.next()) |d| {
        if (d.len == 0) continue;
        const p = std.fmt.bufPrint(&buf, "{s}/{s}", .{ d, name }) catch continue;
        if (good(gpa, p)) return gpa.dupe(u8, p) catch null;
    }
    for (home_dirs) |d| {
        const dir = if (d[0] == '.') std.fmt.bufPrint(&buf, "{s}/{s}", .{ home, d }) catch continue else d;
        const p = std.fmt.bufPrint(&buf, "{s}/{s}", .{ dir, name }) catch continue;
        if (good(gpa, p)) return gpa.dupe(u8, p) catch null;
    }
    return null;
}

fn good(gpa: std.mem.Allocator, path: []const u8) bool {
    const file = std.Io.Dir.cwd().statFile(io(gpa), path, .{}) catch return false;
    return file.kind == .file;
}

/// Frees a command nobody is waiting for any more: its watches go, then the
/// process, and `on_done` is never called. The app's way out while a `gh`
/// poll is still in flight.
pub fn discard(self: *Cmd) void {
    if (self.done) return;
    self.done = true;
    for (&self.watches) |*w| {
        if (w.*) |source| {
            source.cancel();
            w.* = null;
        }
    }
    self.child.kill(io(self.gpa));
    self.out.deinit(self.gpa);
    self.gpa.free(self.argv);
    self.gpa.free(self.argv_bytes);
    self.gpa.destroy(self);
}

/// Stops a command that is taking too long: its watches go first, then the
/// process, and `on_done` hears a null code and what was read so far.
pub fn cancel(self: *Cmd) void {
    if (self.done) return;
    self.child.kill(io(self.gpa));
    finish(self, .{
        .out = self.out.toOwnedSlice(self.gpa) catch &.{},
        .code = null,
        .err = "canceled",
    });
}
