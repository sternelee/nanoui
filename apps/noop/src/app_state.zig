//! noop's model: the notifications the island shows, the work behind them,
//! and the `gh` calls in between. One instance, owned by `main`.
const std = @import("std");
const nanoui = @import("nanoui");
const types = @import("types.zig");
const gh = @import("gh.zig");
const prompt = @import("prompt.zig");
const agent = @import("agent.zig");
const cmd = @import("cmd.zig");
const store = @import("store.zig");
const ingest = @import("ingest.zig");
const ui = nanoui.ui;

/// Which of the island's two screens is up.
pub const Screen = enum { list, run };

/// How the one line under the header reads.
pub const Tone = enum { quiet, busy, worry };

/// A question the owner tapped an answer to, kept until the agent is up.
pub const Answer = struct {
    key: []u8,
    question: []u8,
    letter: []u8,
    previous: []u8,

    fn free(self: *Answer, gpa: std.mem.Allocator) void {
        for ([_]*[]u8{ &self.key, &self.question, &self.letter, &self.previous }) |s| {
            gpa.free(s.*);
            s.* = &.{};
        }
    }
};

pub const State = struct {
    gpa: std.mem.Allocator,
    app: *nanoui.App,
    kv: nanoui.kv.Store,

    settings: types.Settings = .{},
    items: std.ArrayList(types.Item) = .empty,
    /// The agent runs alive now: at most one per item.
    runs: std.ArrayList(*agent.Run) = .empty,

    screen: Screen = .list,
    /// The item the run screen shows: an index into `items`.
    shown: usize = 0,
    /// The answer the owner gave last, until the next run starts.
    answering: ?Answer = null,

    notch: ?*nanoui.Window = null,
    settings_win: ?*nanoui.Window = null,
    /// Set by `main`: its settings module owns building that window.
    opener: ?*const fn (self: *State) void = null,

    /// The look at GitHub in flight, and whether one is.
    poll: ?*cmd.Cmd = null,
    looking: bool = false,
    /// The bound repos one look walks through, in order, and how far it got.
    /// Owned here: `ingest` fills and empties it, this frees it at teardown.
    look_repos: std.ArrayList([]u8) = .empty,
    look_at: usize = 0,
    /// The look after this one is already sheduled.
    armed: bool = false,

    /// The repo being typed into the settings panel, `owner/name`.
    repo_text: ui.TextBuffer = .{},
    /// Where that text is read into its one true form, by `types.repoFrom`.
    repo_clean: [120]u8 = undefined,

    /// Reading one notification's body and comments, if in flight.
    detail: ?*cmd.Cmd = null,
    /// What it is reading: the key, and the subject's JSON as it arrives.
    pending_key: []u8 = &.{},
    pending_subject: []u8 = &.{},

    /// The one line under the island's header, and how it reads.
    status: []u8 = &.{},
    tone: Tone = .quiet,

    /// The notch's own row height, and how tall the island stands open.
    /// Set by `main`, from the screen it is drawn on.
    row_h: f32 = 38,
    open_h: f32 = 252,

    // ------------------------------------------------------------ lifetime

    pub fn init(gpa: std.mem.Allocator, app: *nanoui.App) State {
        const kv = nanoui.kv.standard();
        var s: State = .{ .gpa = gpa, .app = app, .kv = kv };
        s.settings = store.loadSettings(gpa, kv);
        const stored = store.loadItems(gpa, kv);
        defer gpa.free(stored);
        for (stored, 0..) |it, i| {
            s.items.append(gpa, it) catch {
                for (stored[i..]) |*rest| rest.free(gpa);
                break;
            };
        }
        return s;
    }

    pub fn deinit(self: *State) void {
        // The processes are told to stop; their `Run`s are freed with the
        // process, since their end callbacks will never be answered now.
        for (self.runs.items) |run| agent.cancel(run);
        // A `gh` poll still in flight answers no one now: it is dropped, not
        // canceled, so its callback cannot schedule another look.
        if (self.poll) |p| {
            cmd.discard(p);
            self.poll = null;
        }
        for (self.look_repos.items) |repo| self.gpa.free(repo);
        self.look_repos.deinit(self.gpa);
        self.repo_text.deinit();
        self.runs.deinit(self.gpa);
        for (self.items.items) |*it| it.free(self.gpa);
        self.items.deinit(self.gpa);
        self.settings.free(self.gpa);
        if (self.answering) |*a| a.free(self.gpa);
        self.gpa.free(self.pending_key);
        self.gpa.free(self.pending_subject);
        self.gpa.free(self.status);
    }

    /// The island is up: look at GitHub once, then every so often.
    pub fn start(self: *State) void {
        ingest.look(self);
    }

    pub fn indexOf(self: *State, key: []const u8) ?usize {
        for (self.items.items, 0..) |it, i| {
            if (std.mem.eql(u8, it.key, key)) return i;
        }
        return null;
    }

    pub fn find(self: *State, key: []const u8) ?*types.Item {
        const at = self.indexOf(key) orelse return null;
        return &self.items.items[at];
    }

    pub fn workspace(self: *State, repo: []const u8) ?*types.Workspace {
        const at = self.settings.find(repo) orelse return null;
        return &self.settings.workspaces.items[at];
    }

    pub fn runOf(self: *State, key: []const u8) ?*agent.Run {
        for (self.runs.items) |run| {
            if (std.mem.eql(u8, run.key, key)) return run;
        }
        return null;
    }

    pub fn shownItem(self: *State) ?*types.Item {
        if (self.shown >= self.items.items.len) return null;
        return &self.items.items[self.shown];
    }

    pub fn setStatus(self: *State, text: []const u8, tone: Tone) void {
        const next = self.gpa.dupe(u8, text) catch return;
        self.gpa.free(self.status);
        self.status = next;
        self.tone = tone;
    }

    pub fn refresh(self: *State) void {
        if (self.notch) |w| w.redraw();
        if (self.settings_win) |w| w.redraw();
    }

    pub fn save(self: *State) void {
        store.saveSettings(self.gpa, self.kv, &self.settings) catch {};
        store.saveItems(self.gpa, self.kv, self.items.items) catch {};
    }

    pub fn openSettings(self: *State) void {
        if (self.opener) |f| f(self);
        self.refresh();
    }

    pub fn back(self: *State) void {
        self.screen = .list;
        self.refresh();
    }

    // ------------------------------------------------------------ one item

    pub fn click(self: *State, index: usize) void {
        if (index >= self.items.items.len) return;
        self.shown = index;
        if (self.items.items[index].state == .waiting) {
            self.work(index);
            return;
        }
        self.screen = .run;
        self.refresh();
    }

    /// The owner said yes: read what the request says, then start an agent on it.
    pub fn work(self: *State, index: usize) void {
        if (index >= self.items.items.len) return;
        if (self.detail != null) return;
        const item = &self.items.items[index];
        if (item.state != .waiting) return;
        self.shown = index;
        if (self.workspace(item.repo) == null) {
            self.setStatus("no folder is bound to this repo yet: bind one first", .worry);
            self.screen = .run;
            self.openSettings();
            return;
        }
        self.fetch(item);
    }

    fn fetch(self: *State, item: *const types.Item) void {
        self.gpa.free(self.pending_key);
        self.pending_key = self.gpa.dupe(u8, item.key) catch &.{};
        var arena: std.heap.ArenaAllocator = .init(self.gpa);
        defer arena.deinit();
        const path = ingest.apiPath(arena.allocator(), item) catch return;
        const argv = gh.subjectArgs(arena.allocator(), path) catch return;
        self.setStatus("reading the request…", .busy);
        self.detail = cmd.start(self.gpa, .{ .argv = argv, .on_done = subjectDone, .ctx = self }) catch {
            self.setStatus("gh could not read the request", .worry);
            self.detail = null;
            self.refresh();
            return;
        };
        self.refresh();
    }

    fn subjectDone(ctx: ?*anyopaque, done: cmd.Done) void {
        const self: *State = @ptrCast(@alignCast(ctx.?));
        self.detail = null;
        defer self.gpa.free(done.out);
        const item = self.find(self.pending_key) orelse return;
        self.gpa.free(self.pending_subject);
        self.pending_subject = self.gpa.dupe(u8, done.out) catch &.{};
        var arena: std.heap.ArenaAllocator = .init(self.gpa);
        defer arena.deinit();
        const path = ingest.apiPath(arena.allocator(), item) catch return;
        const argv = gh.commentsArgs(arena.allocator(), path) catch return;
        self.detail = cmd.start(self.gpa, .{ .argv = argv, .on_done = commentsDone, .ctx = self }) catch {
            self.setStatus("gh could not read the comments", .worry);
            self.detail = null;
            self.refresh();
            return;
        };
    }

    fn commentsDone(ctx: ?*anyopaque, done: cmd.Done) void {
        const self: *State = @ptrCast(@alignCast(ctx.?));
        self.detail = null;
        defer self.gpa.free(done.out);
        defer {
            self.gpa.free(self.pending_subject);
            self.pending_subject = &.{};
            self.gpa.free(self.pending_key);
            self.pending_key = &.{};
        }
        const at = self.indexOf(self.pending_key) orelse return;
        const item = &self.items.items[at];
        if (item.state != .waiting) return;
        var arena: std.heap.ArenaAllocator = .init(self.gpa);
        defer arena.deinit();
        const a = arena.allocator();
        const one: gh.Raw = .{ .out = self.pending_subject, .code = 0, .err = "" };
        const many: gh.Raw = .{ .out = done.out, .code = done.code, .err = done.err };
        const d = gh.parseDetails(a, one, many) catch {
            self.setStatus("the request did not read as JSON", .worry);
            self.refresh();
            return;
        };
        const body = gh.detailsBody(a, d) catch self.pending_subject;
        self.gpa.free(item.body);
        item.body = self.gpa.dupe(u8, body) catch &.{};
        self.launch(at);
    }

    fn launch(self: *State, index: usize) void {
        const item = &self.items.items[index];
        const w = self.workspace(item.repo) orelse return;
        const text = prompt.forItem(self.gpa, item, w.path) catch return;
        defer self.gpa.free(text);
        self.spawn(index, text, "");
    }

    fn spawn(self: *State, index: usize, text: []const u8, session: []const u8) void {
        const item = &self.items.items[index];
        const w = self.workspace(item.repo) orelse return;
        const run = agent.start(self.gpa, .{
            .agent = w.agent,
            .key = item.key,
            .dir = w.path,
            .prompt = text,
            .model = w.model,
            .session = session,
            .unattended = self.settings.unattended,
            .on_progress = progressed,
            .on_end = ended,
            .ctx = self,
        }) orelse {
            self.setStatus("the agent could not start: is it installed?", .worry);
            self.refresh();
            return;
        };
        self.runs.append(self.gpa, run) catch {
            agent.cancel(run);
            agent.dispose(run);
            return;
        };
        item.state = .running;
        self.shown = index;
        self.screen = .run;
        self.setStatus("", .quiet);
        self.markRead(item.key);
        self.save();
        self.refresh();
    }

    /// The thread is read, so it leaves the inbox; a failure only means the
    /// next look shows it again.
    fn markRead(self: *State, key: []const u8) void {
        var arena: std.heap.ArenaAllocator = .init(self.gpa);
        defer arena.deinit();
        const argv = gh.readArgs(arena.allocator(), key) catch return;
        _ = cmd.start(self.gpa, .{ .argv = argv, .on_done = ignored, .ctx = null }) catch return;
    }

    fn ignored(ctx: ?*anyopaque, done: cmd.Done) void {
        _ = ctx;
        _ = done;
    }

    fn progressed(ctx: ?*anyopaque, run: *agent.Run) void {
        _ = run;
        const self: *State = @ptrCast(@alignCast(ctx.?));
        self.refresh();
    }

    fn ended(ctx: ?*anyopaque, run: *agent.Run, end: agent.End) void {
        const self: *State = @ptrCast(@alignCast(ctx.?));
        if (self.find(run.key)) |item| {
            if (end.result) |result| {
                self.settle(item, result);
                var spent = result;
                spent.free(self.gpa);
            } else if (end.note.len > 0 and std.mem.eql(u8, end.note, "canceled")) {
                item.state = .waiting;
                self.setStatus("stopped: nothing was changed by hand", .quiet);
            } else {
                item.state = .failed;
                const tail = prompt.tail(self.gpa, end.out) catch &.{};
                defer self.gpa.free(tail);
                self.setSummary(item, tail);
                self.setStatus("the agent stopped without an answer", .worry);
            }
        }
        self.drop(run);
        self.save();
        self.refresh();
    }

    fn settle(self: *State, item: *types.Item, result: types.Result) void {
        switch (result.status) {
            .done => {
                item.state = .done;
                self.setSummary(item, result.summary);
                self.clearDecision(item);
                self.setStatus("", .quiet);
            },
            .failed => {
                item.state = .failed;
                self.setSummary(item, if (result.summary.len > 0) result.summary else "the agent failed");
                self.clearDecision(item);
                self.setStatus("the agent could not finish", .worry);
            },
            .needs_decision => {
                item.state = .needs_decision;
                self.setSummary(item, result.summary);
                self.clearDecision(item);
                item.decision = prompt.decisions(self.gpa, result) catch null;
                self.setStatus("the agent needs you", .busy);
            },
        }
    }

    fn setSummary(self: *State, item: *types.Item, text: []const u8) void {
        const next = self.gpa.dupe(u8, text) catch return;
        self.gpa.free(item.summary);
        item.summary = next;
    }

    fn clearDecision(self: *State, item: *types.Item) void {
        if (item.decision) |*old| old.free(self.gpa);
        item.decision = null;
    }

    fn drop(self: *State, run: *agent.Run) void {
        for (self.runs.items, 0..) |r, i| {
            if (r == run) {
                _ = self.runs.orderedRemove(i);
                break;
            }
        }
        agent.dispose(run);
    }

    /// The owner tapped one of the two answers the agent offered.
    pub fn answer(self: *State, index: usize, letter: []const u8) void {
        if (index >= self.items.items.len) return;
        const item = &self.items.items[index];
        const d = item.decision orelse return;
        var choice: []const u8 = "";
        for (d.options.items) |o| {
            if (std.mem.eql(u8, o.letter, letter)) choice = o.text;
        }
        if (choice.len == 0) return;
        const w = self.workspace(item.repo) orelse return;
        const text = prompt.forAnswer(self.gpa, item, w.path, d.question, choice, item.summary) catch return;
        defer self.gpa.free(text);
        if (self.answering) |*a| a.free(self.gpa);
        self.answering = .{
            .key = self.gpa.dupe(u8, item.key) catch &.{},
            .question = self.gpa.dupe(u8, d.question) catch &.{},
            .letter = self.gpa.dupe(u8, letter) catch &.{},
            .previous = self.gpa.dupe(u8, item.summary) catch &.{},
        };
        self.clearDecision(item);
        self.spawn(index, text, "");
    }

    pub fn cancelShown(self: *State) void {
        const item = self.shownItem() orelse return;
        if (self.runOf(item.key)) |run| {
            agent.cancel(run);
            self.setStatus("stopping…", .busy);
        } else {
            item.state = .waiting;
            self.clearDecision(item);
            self.setStatus("", .quiet);
        }
        self.save();
        self.refresh();
    }

    /// Forgotten until GitHub names it again.
    pub fn dismiss(self: *State, index: usize) void {
        if (index >= self.items.items.len) return;
        if (self.runOf(self.items.items[index].key)) |run| agent.cancel(run);
        self.items.items[index].free(self.gpa);
        _ = self.items.orderedRemove(index);
        if (self.shown >= self.items.items.len) {
            self.shown = if (self.items.items.len > 0) self.items.items.len - 1 else 0;
        }
        self.screen = .list;
        self.save();
        self.refresh();
    }

    /// The owner picked a folder for one of the workspaces.
    pub fn bind(self: *State, at: usize, path: []const u8) void {
        if (at >= self.settings.workspaces.items.len) return;
        const next = self.gpa.dupe(u8, path) catch return;
        const w = &self.settings.workspaces.items[at];
        self.gpa.free(w.path);
        w.path = next;
        self.save();
        ingest.look(self);
        self.refresh();
    }

    pub fn addWorkspace(self: *State, repo: []const u8, path: []const u8) bool {
        const ws = types.Workspace{
            .repo = self.gpa.dupe(u8, repo) catch return false,
            .path = self.gpa.dupe(u8, path) catch return false,
        };
        self.settings.workspaces.append(self.gpa, ws) catch return false;
        self.save();
        // A new workspace is a new inbox: it is read at once, not next time.
        ingest.look(self);
        self.refresh();
        return true;
    }

    pub fn forgetWorkspace(self: *State, at: usize) void {
        if (at >= self.settings.workspaces.items.len) return;
        var gone = self.settings.workspaces.orderedRemove(at);
        gone.free(self.gpa);
        self.save();
        // Its notifications go with it: no workspace, no place to work.
        ingest.prune(self);
        self.refresh();
    }
};
