//! claude and codex, run as commands: the argv each one wants, its stream
//! read as it arrives, and the answer at the end. The two agree on nothing
//! but lines of JSON, so each shape is taken on its own terms and a line
//! that means nothing is only text.
const std = @import("std");
const json = std.json;
const types = @import("types.zig");
const cmd = @import("cmd.zig");
const prompt = @import("prompt.zig");

pub const Step = struct {
    n: u32,
    text: []u8,
};

/// What a run has done, as the notch shows it while it works.
pub const Progress = struct {
    /// The last `keep` steps, oldest first.
    steps: std.ArrayList(Step) = .empty,
    /// What is running now, empty between tools.
    now: []u8 = &.{},
    /// The model the CLI named in its own first line.
    model: []u8 = &.{},
    /// The session to continue, where the CLI offered one.
    session: []u8 = &.{},
    /// Every step there has been, past what is kept.
    count: u32 = 0,
    /// What the agent wrote, with its result block still inside.
    text: std.ArrayList(u8) = .empty,

    pub const keep = 24;

    fn step(p: *Progress, gpa: std.mem.Allocator, line: []const u8) !void {
        if (line.len == 0) return;
        p.count += 1;
        if (p.steps.items.len >= keep) gpa.free(p.steps.orderedRemove(0).text);
        const one = if (std.mem.indexOfScalar(u8, line, '\n')) |n| line[0..n] else line;
        try p.steps.append(gpa, .{ .n = p.count, .text = try gpa.dupe(u8, if (one.len > 120) one[0..120] else one) });
        const last = p.steps.items[p.steps.items.len - 1].text;
        set(&p.now, gpa, last);
    }

    fn write(p: *Progress, gpa: std.mem.Allocator, s: []const u8) void {
        p.text.appendSlice(gpa, s) catch return;
    }

    pub fn free(p: *Progress, gpa: std.mem.Allocator) void {
        for (p.steps.items) |s| gpa.free(s.text);
        p.steps.deinit(gpa);
        p.text.deinit(gpa);
        for ([_]*[]u8{ &p.now, &p.model, &p.session }) |s| {
            gpa.free(s.*);
            s.* = &.{};
        }
        p.* = .{};
    }
};

fn set(dest: *[]u8, gpa: std.mem.Allocator, s: []const u8) void {
    const next = gpa.dupe(u8, s) catch return;
    if (dest.len != 0) gpa.free(dest.*);
    dest.* = next;
}

/// Where a run ended. `out` and `result` belong to whoever is told.
pub const End = struct {
    /// The agent's own last block, when it wrote one in that shape.
    result: ?types.Result = null,
    /// Its exit status; null when it never started, or was stopped.
    code: ?u8 = null,
    /// A fixed line about a command that never ran: not installed, and so
    /// on. Empty otherwise.
    note: []const u8 = "",
    /// Everything it wrote.
    out: []u8 = &.{},
};

pub const Run = struct {
    gpa: std.mem.Allocator,
    agent: types.Agent,
    /// The item this is about: its notification key.
    key: []u8,
    dir: []u8,
    progress: Progress = .{},
    proc: ?*cmd.Cmd = null,
    /// The line being read, up to its newline.
    pending: std.ArrayList(u8) = .empty,
    on_progress: ?ProgressFn = null,
    on_end: EndFn,
    ctx: ?*anyopaque = null,
    /// A run reports once: further bytes change nothing.
    reported: bool = false,
    /// What the command wrote, kept until the person told has taken it.
    end_owned: []u8 = &.{},

    pub const ProgressFn = *const fn (ctx: ?*anyopaque, run: *Run) void;
    pub const EndFn = *const fn (ctx: ?*anyopaque, run: *Run, end: End) void;
};

pub const Options = struct {
    agent: types.Agent,
    key: []const u8,
    dir: []const u8,
    prompt: []const u8,
    /// The CLI's model; empty for its own default.
    model: []const u8 = "",
    /// The session to continue. codex resumes by id too, differently.
    session: []const u8 = "",
    /// Edits and commands run without the CLI asking permission.
    unattended: bool = true,
    on_progress: ?Run.ProgressFn = null,
    on_end: Run.EndFn,
    ctx: ?*anyopaque = null,
};

// ------------------------------------------------------------------ argv

/// The command line of a run, on an allocator that may be an arena: `start`
/// copies what it needs, so this is freed straight after. Kept apart so a
/// test can read exactly what an agent is told to do.
/// Appends owned copies: every element in what `args` returns is the
/// caller's to free, however it got there.
fn add(a: std.mem.Allocator, out: *std.ArrayList([]const u8), items: []const []const u8) !void {
    for (items) |s| try out.append(a, try a.dupe(u8, s));
}

pub fn args(
    a: std.mem.Allocator,
    agent: types.Agent,
    model: []const u8,
    session: []const u8,
    unattended: bool,
) ![][]const u8 {
    var out = std.ArrayList([]const u8).empty;
    switch (agent) {
        .claude => {
            try add(a, &out, &.{ "claude", "-p", "--output-format", "stream-json", "--verbose" });
            try add(a, &out, &.{
                "--permission-mode", if (unattended) "bypassPermissions" else "default",
            });
            if (model.len > 0) {
                try add(a, &out, &.{ "--model", model });
            }
            // No "Generated with" footer, no co-author line: the commit is
            // the owner's, not noop's.
            try out.append(a, try jsonSettings(a));
            if (session.len > 0) {
                try add(a, &out, &.{ "--resume", session });
            }
        },
        .codex => {
            if (session.len > 0) {
                // `codex exec resume <id>`, before the options.
                try add(a, &out, &.{ "codex", "exec", "resume", session });
            } else {
                try add(a, &out, &.{ "codex", "exec" });
            }
            try add(a, &out, &.{ "--skip-git-repo-check", "--json" });
            try add(a, &out, &.{ "--sandbox", if (unattended) "workspace-write" else "read-only" });
            if (unattended) {
                try out.append(a, try a.dupe(u8, "-c"));
                try out.append(a, try pair(a, "approval_policy", "\"never\""));
                try out.append(a, try a.dupe(u8, "-c"));
                try out.append(a, try pair(a, "sandbox_workspace_write.network_access", "true"));
            }
            if (model.len > 0) try add(a, &out, &.{ "-m", model });
        },
    }
    // The prompt is written to stdin; "-" is where the CLI looks for it.
    try out.append(a, try a.dupe(u8, "-"));
    return out.toOwnedSlice(a);
}

/// `key=value`: one argument for codex, where claude takes two.
fn pair(a: std.mem.Allocator, key: []const u8, value: []const u8) ![]const u8 {
    var buf: std.Io.Writer.Allocating = .init(a);
    errdefer buf.deinit();
    try buf.writer.print("{s}={s}", .{ key, value });
    return buf.toOwnedSlice();
}

fn jsonSettings(a: std.mem.Allocator) ![]const u8 {
    return a.dupe(u8,
        \\{"attribution":{"commit":"","pr":""},"includeCoAuthoredBy":false}
    );
}

/// Starts a run, or answers null with the reason the tool could not begin.
pub fn start(gpa: std.mem.Allocator, o: Options) ?*Run {
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const argv = args(arena.allocator(), o.agent, o.model, o.session, o.unattended) catch return null;

    const self = gpa.create(Run) catch return null;
    self.* = .{
        .gpa = gpa,
        .agent = o.agent,
        .key = gpa.dupe(u8, o.key) catch {
            gpa.destroy(self);
            return null;
        },
        .dir = gpa.dupe(u8, o.dir) catch {
            gpa.destroy(self);
            return null;
        },
        .on_progress = o.on_progress,
        .on_end = o.on_end,
        .ctx = o.ctx,
    };
    const spawned = cmd.start(gpa, .{
        .argv = argv,
        .dir = o.dir,
        .stdin = o.prompt,
        // An agent's own errors are part of its stream: they are the tail a
        // person reads when there is no result to parse.
        .stderr_to_out = true,
        .on_data = onData,
        .on_done = onDone,
        .ctx = self,
    }) catch |e| {
        const why: []const u8 = if (e == error.CommandNotFound) switch (o.agent) {
            .claude => "claude is not installed: install it and sign in",
            .codex => "codex is not installed: install it and sign in",
        } else if (e == error.CouldNotWatch) "its output could not be watched" else "it could not be started";
        finish(self,null, why);
        return null;
    };
    self.proc = spawned;
    return self;
}

/// Stops a run: its command goes first, and `on_end` hears a null code.
pub fn cancel(self: *Run) void {
    if (self.proc) |p| cmd.cancel(p);
}

pub fn dispose(self: *Run) void {
    if (self.end_owned.len > 0) self.gpa.free(self.end_owned);
    self.progress.free(self.gpa);
    self.pending.deinit(self.gpa);
    if (self.proc) |p| cmd.cancel(p);
    self.gpa.free(self.key);
    self.gpa.free(self.dir);
    self.gpa.destroy(self);
}

// ----------------------------------------------------------------- stream

fn onData(ctx: ?*anyopaque, bytes: []const u8) void {
    const self: *Run = @ptrCast(@alignCast(ctx));
    if (self.reported) return;
    for (bytes) |ch| {
        if (ch == '\r') continue;
        if (ch != '\n') {
            self.pending.append(self.gpa, ch) catch continue;
            continue;
        }
        feed(self,self.pending.items);
        self.pending.clearRetainingCapacity();
    }
    // A final line with no newline at all still counts.
    if (self.pending.items.len > 0 and self.pending.items[self.pending.items.len - 1] == '}') {
        const rest = self.gpa.dupe(u8, self.pending.items) catch return;
        defer self.gpa.free(rest);
        self.pending.clearRetainingCapacity();
        feed(self,rest);
    }
}

fn onDone(ctx: ?*anyopaque, d: cmd.Done) void {
    const self: *Run = @ptrCast(@alignCast(ctx));
    if (self.reported) {
        self.gpa.free(d.out);
        return;
    }
    self.end_owned = d.out;
    finish(self,d.code, d.err);
}

/// One line of the stream: claude's, codex's, or plain text.
fn feed(self: *Run, line: []const u8) void {
    const gpa = self.gpa;
    if (line.len == 0) return;
    const value = json.parseFromSliceLeaky(json.Value, gpa, line, .{}) catch {
        self.progress.write(gpa, line);
        self.progress.write(gpa, "\n");
        return tell(self);
    };
    const obj = switch (value) {
        .object => |o| o,
        else => return tell(self),
    };
    const kind = text(obj, "type") orelse "";
    if (std.mem.eql(u8, kind, "system")) {
        if (text(obj, "model")) |m| set(&self.progress.model, gpa, m);
        if (text(obj, "session_id")) |s| set(&self.progress.session, gpa, s);
    } else if (std.mem.eql(u8, kind, "assistant")) {
        contents(self, obj);
    } else if (std.mem.eql(u8, kind, "user")) {
        // A tool answered: whatever ran is over.
        set(&self.progress.now, gpa, "");
    } else if (std.mem.eql(u8, kind, "result")) {
        if (text(obj, "result")) |r| {
            self.progress.write(gpa, r);
            self.progress.write(gpa, "\n");
        }
    } else if (std.mem.eql(u8, kind, "item.started") or std.mem.eql(u8, kind, "item.completed")) {
        item(self, obj, std.mem.eql(u8, kind, "item.started"));
    }
    tell(self);
}

/// claude's `message.content`: tools as steps, text as the answer.
fn contents(self: *Run, obj: std.json.ObjectMap) void {
    const gpa = self.gpa;
    const message = field(obj, "message") orelse return;
    const content = switch (message) {
        .object => |m| switch (m.get("content") orelse return) {
            .array => |a| a.items,
            else => return,
        },
        else => return,
    };
    for (content) |part| {
        const p = switch (part) {
            .object => |o| o,
            else => continue,
        };
        const what = text(p, "type") orelse "";
        if (std.mem.eql(u8, what, "tool_use")) {
            self.progress.step(gpa, toolText(field(p, "input"))) catch return;
        } else if (std.mem.eql(u8, what, "text")) {
            if (text(p, "text")) |t| {
                self.progress.write(gpa, t);
                self.progress.write(gpa, "\n");
            }
        }
    }
}

/// codex's `item`: a command run, files changed, or the agent's message.
fn item(self: *Run, obj: std.json.ObjectMap, started: bool) void {
    const gpa = self.gpa;
    const it = switch (field(obj, "item") orelse return) {
        .object => |o| o,
        else => return,
    };
    const what = text(it, "type") orelse return;
    if (std.mem.eql(u8, what, "agent_message")) {
        if (!started) {
            if (text(it, "text")) |t| {
                self.progress.write(gpa, t);
                self.progress.write(gpa, "\n");
            }
        }
        return;
    }
    if (!started) return;
    if (std.mem.eql(u8, what, "command_execution")) {
        self.progress.step(gpa, text(it, "command") orelse "") catch return;
    } else if (std.mem.eql(u8, what, "file_change")) {
        self.progress.step(gpa, "edits files") catch return;
    } else if (std.mem.eql(u8, what, "web_search")) {
        self.progress.step(gpa, text(it, "query") orelse "searches the web") catch return;
    } else {
        self.progress.step(gpa, what) catch return;
    }
}

/// The line a tool is doing: its own description if it wrote one, else the
/// first of its arguments.
fn toolText(input: ?json.Value) []const u8 {
    const keys = [_][]const u8{ "description", "command", "file_path", "path", "pattern", "url", "query", "prompt" };
    if (input) |v| {
        const obj = switch (v) {
            .object => |o| o,
            else => null,
        };
        if (obj) |o| {
            for (keys) |k| {
                if (text(o, k)) |s| return s;
            }
        }
    }
    return "working";
}

fn tell(self: *Run) void {
    if (self.on_progress) |cb| cb(self.ctx, self);
}

fn finish(self: *Run, code: ?u8, why: []const u8) void {
    const gpa = self.gpa;
    self.reported = true;
    var end: End = .{
        .code = code,
        .note = why,
        .out = self.end_owned,
    };
    end.result = prompt.parseResult(gpa, self.progress.text.items);
    if (end.result == null and end.note.len == 0 and code != null and code.? != 0) {
        end.note = "the agent stopped without an answer";
    }
    self.on_end(self.ctx, self, end);
}

fn field(obj: std.json.ObjectMap, name: []const u8) ?json.Value {
    const v = obj.get(name) orelse return null;
    return if (v == .null) null else v;
}

fn text(obj: std.json.ObjectMap, name: []const u8) ?[]const u8 {
    const v = field(obj, name) orelse return null;
    return switch (v) {
        .string => |s| s,
        else => null,
    };
}
