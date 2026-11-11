//! The look at GitHub: `gh` asked once, its answer read, the notifications
//! merged into the model. The next look is scheduled from here, never polled.
const std = @import("std");
const nanoui = @import("nanoui");
const types = @import("types.zig");
const gh = @import("gh.zig");
const cmd = @import("cmd.zig");
const store = @import("store.zig");
const app_state = @import("app_state.zig");

const State = app_state.State;

/// One look walks the bound repos, one `gh` call each: what a workspace
/// names is what is asked about. Until one is bound nothing is read at all.
pub fn look(self: *State) void {
    if (self.looking) return;
    queueRepos(self);
    if (self.look_repos.items.len == 0) {
        self.setStatus("bind a workspace first: Workspaces, in the settings panel", .quiet);
        prune(self);
        self.refresh();
        schedule(self);
        return;
    }
    const gh_path = cmd.find(self.gpa, "gh") orelse {
        endLook(self, "the gh command is missing: brew install gh", .worry);
        return;
    };
    self.gpa.free(gh_path);
    ask(self);
}

/// The repos this look asks about, deduplicated: two workspaces on one repo
/// are one inbox.
fn queueRepos(self: *State) void {
    clearQueue(self);
    for (self.settings.workspaces.items) |w| {
        if (w.repo.len == 0) continue;
        var known = false;
        for (self.look_repos.items) |r| {
            if (std.mem.eql(u8, r, w.repo)) known = true;
        }
        if (known) continue;
        const copy = self.gpa.dupe(u8, w.repo) catch break;
        self.look_repos.append(self.gpa, copy) catch {
            self.gpa.free(copy);
            break;
        };
    }
    self.look_at = 0;
}

/// Frees the queue: a look that ends early leaves nothing behind.
pub fn clearQueue(self: *State) void {
    for (self.look_repos.items) |repo| self.gpa.free(repo);
    self.look_repos.shrinkRetainingCapacity(0);
    self.look_at = 0;
}

/// The `gh` call for the repo the look stands at.
fn ask(self: *State) void {
    const repo = self.look_repos.items[self.look_at];
    var arena: std.heap.ArenaAllocator = .init(self.gpa);
    defer arena.deinit();
    const argv = gh.repoArgs(arena.allocator(), repo, self.settings.participating_only) catch {
        advance(self);
        return;
    };
    self.poll = cmd.start(self.gpa, .{ .argv = argv, .on_done = pollDone, .ctx = self }) catch |e| {
        endLook(self, switch (e) {
            error.CommandNotFound => "the gh command is missing: brew install gh",
            else => "gh could not start",
        }, .worry);
        return;
    };
    self.looking = true;
}

/// One repo answered: the next one is asked, or the look is over.
fn advance(self: *State) void {
    self.look_at += 1;
    if (self.look_at < self.look_repos.items.len) {
        ask(self);
        self.refresh();
        return;
    }
    endLook(self, self.status, self.tone);
}

/// Ends the look here: the queue is freed, and the next look is scheduled.
fn endLook(self: *State, what: []const u8, tone: app_state.Tone) void {
    clearQueue(self);
    self.setStatus(what, tone);
    self.refresh();
    schedule(self);
}

fn pollDone(ctx: ?*anyopaque, done: cmd.Done) void {
    const self: *State = @ptrCast(@alignCast(ctx.?));
    defer self.gpa.free(done.out);
    self.poll = null;
    self.looking = false;
    const raw: gh.Raw = .{ .out = done.out, .code = done.code, .err = done.err };
    switch (gh.classify(raw)) {
        .ok => {
            var reply = gh.parse(self.gpa, raw) catch |e| {
                // gh said something that is not the inbox: say what, rather
                // than only that it did not parse. The reason comes along:
                // what GitHub sent is often fine and something else failed.
                const said = gh.firstLine(self.gpa, raw.out) catch "";
                defer self.gpa.free(said);
                var text: [200]u8 = undefined;
                const why = @errorName(e);
                self.setStatus(if (said.len == 0)
                    std.fmt.bufPrint(&text, "GitHub's answer did not read as JSON ({s})", .{why}) catch "GitHub's answer did not read as JSON"
                else
                    std.fmt.bufPrint(&text, "gh said: {s} ({s})", .{ said[0..@min(said.len, 120)], why }) catch "GitHub's answer did not read as JSON", .worry);
                advance(self);
                return;
            };
            defer reply.free(self.gpa);
            if (reply.items.len == 0 and self.items.items.len == 0) {
                self.setStatus("nothing is waiting on you", .quiet);
            } else if (self.status.len > 0 and self.tone != .worry) {
                self.setStatus("", .quiet);
            }
            merge(self, reply.items);
            self.save();
        },
        .needs_login => self.setStatus("gh is signed out: run `gh auth login`", .worry),
        .starved => self.setStatus("GitHub is rate limiting: looking again soon", .worry),
        .not_installed => self.setStatus("the gh command is missing: brew install gh", .worry),
        .failed => {
            // Words when gh had any, so the notch never shows the empty
            // "gh said:" that a colour code alone used to leave behind.
            const said = gh.firstLine(self.gpa, raw.out) catch "";
            defer self.gpa.free(said);
            if (said.len == 0) {
                self.setStatus("gh failed without saying why: check the repo is one you can see", .worry);
            } else {
                var text: [200]u8 = undefined;
                self.setStatus(std.fmt.bufPrint(&text, "gh failed: {s}", .{said[0..@min(said.len, 150)]}) catch "gh failed", .worry);
            }
        },
    }
    advance(self);
}

/// Whether a workspace names this repo: only those have a place to work in.
fn bound(self: *State, repo: []const u8) bool {
    return self.settings.find(repo) != null;
}

/// Everything the model remembers is from a bound repo: unbinding one takes
/// its notifications with it.
pub fn prune(self: *State) void {
    var kept: std.ArrayList(types.Item) = .empty;
    for (self.items.items) |*it| {
        if (bound(self, it.repo)) {
            kept.append(self.gpa, it.*) catch {
                it.free(self.gpa);
                continue;
            };
        } else {
            it.free(self.gpa);
        }
    }
    self.items.deinit(self.gpa);
    self.items = kept;
    if (self.shown >= self.items.items.len) {
        self.shown = if (self.items.items.len > 0) self.items.items.len - 1 else 0;
    }
    // What left the notch leaves storage too, so it is not back on relaunch.
    self.save();
}

/// The next look, `settings.every` minutes from now, as the panel shows
/// the setting. Never faster than half a minute, whatever a file says.
pub fn schedule(self: *State) void {
    if (self.armed) return;
    self.armed = true;
    const secs: u64 = @max(30, @as(u64, self.settings.every) * 60);
    nanoui.App.after(secs * std.time.ms_per_s, self, looked);
}

fn looked(ctx: ?*anyopaque) callconv(.c) void {
    const self: *State = @ptrCast(@alignCast(ctx.?));
    self.armed = false;
    look(self);
}

fn merge(self: *State, incoming: []const types.Item) void {
    const gpa = self.gpa;
    var next: std.ArrayList(types.Item) = .empty;
    next.ensureTotalCapacity(gpa, incoming.len + self.items.items.len) catch return;
    for (incoming) |src| {
        if (!bound(self, src.repo)) continue;
        if (findIn(next.items, src.key) != null) continue;
        var item = copyItem(gpa, src) catch continue;
        if (self.find(src.key)) |old| takeWork(&item, old);
        next.appendAssumeCapacity(item);
    }
    // Work in flight stays listed even when GitHub stops naming it.
    for (self.items.items) |*old| {
        if (old.state == .waiting) continue;
        if (!bound(self, old.repo)) continue;
        if (findIn(next.items, old.key) != null) continue;
        var item = copyItem(gpa, old.*) catch continue;
        takeWork(&item, old);
        next.appendAssumeCapacity(item);
    }
    trim(self, &next);
    for (self.items.items) |*old| old.free(gpa);
    self.items.deinit(gpa);
    self.items = next;
    if (self.shown >= self.items.items.len) {
        self.shown = if (self.items.items.len > 0) self.items.items.len - 1 else 0;
    }
}

/// `store.kept` items is what is remembered: the oldest waiting ones go.
fn trim(self: *State, next: *std.ArrayList(types.Item)) void {
    while (next.items.len > store.kept) {
        var victim: ?usize = null;
        var i = next.items.len;
        while (i > 0) {
            i -= 1;
            if (next.items[i].state == .waiting) {
                victim = i;
                break;
            }
        }
        const at = victim orelse next.items.len - 1;
        next.items[at].free(self.gpa);
        _ = next.orderedRemove(at);
    }
}

/// The api path of the thing a notification is about: pull requests and
/// issues share the issues endpoint, which is where comments live too.
pub fn apiPath(gpa: std.mem.Allocator, item: *const types.Item) ![]u8 {
    return gpa.print("repos/{s}/issues/{d}", .{ item.repo, item.number });
}

fn findIn(items: []const types.Item, key: []const u8) ?usize {
    for (items, 0..) |it, i| {
        if (std.mem.eql(u8, it.key, key)) return i;
    }
    return null;
}

/// A copy without what the work adds: body, summary and the question.
fn copyItem(gpa: std.mem.Allocator, src: types.Item) !types.Item {
    var it: types.Item = .{
        .key = &.{},
        .repo = &.{},
        .title = &.{},
        .url = &.{},
        .updated = &.{},
        .body = &.{},
        .summary = &.{},
    };
    errdefer it.free(gpa);
    it.key = try gpa.dupe(u8, src.key);
    it.repo = try gpa.dupe(u8, src.repo);
    it.title = try gpa.dupe(u8, src.title);
    it.url = try gpa.dupe(u8, src.url);
    it.updated = try gpa.dupe(u8, src.updated);
    it.number = src.number;
    it.kind = src.kind;
    it.reason = src.reason;
    it.state = src.state;
    return it;
}

/// What the old item knew that the new one does not: moved, not copied.
fn takeWork(dest: *types.Item, from: *types.Item) void {
    dest.state = from.state;
    dest.body = from.body;
    from.body = &.{};
    dest.summary = from.summary;
    from.summary = &.{};
    dest.decision = from.decision;
    from.decision = null;
}
