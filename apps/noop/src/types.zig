//! What noop knows about: the items that want attention, the workspaces that
//! bind a repo to a directory on this machine, and what an agent answered.
//! Strings are owned by the app's allocator; `free` gives them back.
const std = @import("std");

/// The CLI an agent runs on.
pub const Agent = enum { claude, codex };

/// What an item is: what an agent would have to change.
pub const Kind = enum {
    /// A pull request asked for review, or with failing checks.
    pull,
    /// An issue assigned or mentioned.
    issue,
    /// A comment that mentions the owner, on a PR or an issue.
    comment,
    /// CI on the owner's own pull request.
    checks,

    pub fn symbol(k: Kind) []const u8 {
        return switch (k) {
            .pull => "arrow.triangle.pull",
            .issue => "circle.dashed.inset.filled",
            .comment => "bubble.left",
            .checks => "xmark.seal",
        };
    }

    pub fn text(k: Kind) []const u8 {
        return switch (k) {
            .pull => "pull request",
            .issue => "issue",
            .comment => "comment",
            .checks => "checks",
        };
    }
};

/// Why GitHub sent it, its own word where there is one.
pub const Reason = enum {
    assigned,
    author,
    comment,
    ci_activity,
    mention,
    review_requested,
    subscription,
    other,

    pub fn text(r: Reason) []const u8 {
        return switch (r) {
            .assigned => "assigned",
            .author => "yours",
            .comment => "commented",
            .ci_activity => "CI",
            .mention => "mentioned",
            .review_requested => "review asked",
            .subscription => "watching",
            .other => "new",
        };
    }
};

/// Where an item is. `waiting` is the inbox; the rest is what an agent did.
pub const State = enum {
    waiting,
    running,
    needs_decision,
    done,
    failed,
    dismissed,

    pub fn text(s: State) []const u8 {
        return switch (s) {
            .waiting => "",
            .running => "working",
            .needs_decision => "your call",
            .done => "done",
            .failed => "failed",
            .dismissed => "dismissed",
        };
    }

    /// Whether the notch shows it: the inbox, what's running, and what is
    /// waiting on a decision. Results stay out of the notch until asked.
    pub fn shown(s: State) bool {
        return switch (s) {
            .waiting, .running, .needs_decision => true,
            .done, .failed, .dismissed => false,
        };
    }
};

/// One thing that wants attention: a notification from GitHub.
pub const Item = struct {
    /// The notification's id: the dedupe key, and what `gh api` marks read.
    key: []const u8,
    /// `owner/name`.
    repo: []const u8,
    number: u32 = 0,
    kind: Kind = .issue,
    reason: Reason = .other,
    title: []const u8,
    /// The page to open.
    url: []const u8,
    /// GitHub's `updated_at`, as a cursor between two looks.
    updated: []const u8,
    /// What it says: the body and the last comments, fetched when an agent
    /// is asked to handle it.
    body: []const u8 = &.{},
    state: State = .waiting,
    /// What the agent answered, while `state` is `.needs_decision`.
    decision: ?Decision = null,
    /// Its summary, when the agent finished (`.done` / `.failed`).
    summary: []const u8 = &.{},

    pub fn free(i: *Item, gpa: std.mem.Allocator) void {
        for ([_]*[]const u8{ &i.key, &i.repo, &i.title, &i.url, &i.updated, &i.body, &i.summary }) |s| gpa.free(s.*);
        if (i.decision) |*d| d.free(gpa);
        i.decision = null;
    }
};

/// A repo bound to a directory: where an agent works on that repo's items.
pub const Workspace = struct {
    /// `owner/name`.
    repo: []u8,
    /// An absolute path, the agent's working directory.
    path: []u8,
    agent: Agent = .claude,
    /// Empty: the CLI's own default.
    model: []u8 = &.{},

    pub fn free(w: *Workspace, gpa: std.mem.Allocator) void {
        gpa.free(w.repo);
        gpa.free(w.path);
        gpa.free(w.model);
    }
};

/// One answer on offer, `A` / `B`, with what it means.
pub const Option = struct {
    letter: []const u8,
    text: []u8,
};

/// What an agent asks back: one short question, at most two taps to answer.
pub const Decision = struct {
    question: []u8,
    options: std.ArrayList(Option) = .empty,
    recommendation: []u8 = &.{},

    pub fn free(d: *Decision, gpa: std.mem.Allocator) void {
        gpa.free(d.question);
        for (d.options.items) |*o| gpa.free(o.text);
        d.options.deinit(gpa);
        gpa.free(d.recommendation);
    }
};

/// The result an agent ends its reply with, after a ```json fence.
pub const Result = struct {
    /// `noop`'s contract, kept small: what happened, and what it would like.
    status: Status = .failed,
    summary: []u8 = &.{},
    question: []u8 = &.{},
    options: std.ArrayList([]u8) = .empty,
    recommendation: []u8 = &.{},

    pub const Status = enum { done, needs_decision, failed };

    pub fn free(r: *Result, gpa: std.mem.Allocator) void {
        gpa.free(r.summary);
        gpa.free(r.question);
        for (r.options.items) |o| gpa.free(o);
        r.options.deinit(gpa);
        gpa.free(r.recommendation);
    }
};

/// What the owner decided to watch, and how.
pub const Settings = struct {
    workspaces: std.ArrayList(Workspace) = .empty,
    /// Minutes between two looks at GitHub; thirty seconds is the floor.
    every: u32 = 60,
    /// Only the notifications that name the owner (mentions, reviews,
    /// assignments), not every watched repo's traffic.
    participating_only: bool = false,
    /// The agent edits and runs without asking the CLI's own permissions:
    /// claude's `bypassPermissions`, codex's `workspace-write` sandbox.
    unattended: bool = false,

    pub fn free(s: *Settings, gpa: std.mem.Allocator) void {
        for (s.workspaces.items) |*w| w.free(gpa);
        s.workspaces.deinit(gpa);
    }

    /// The workspace bound to `repo`, by `owner/name`.
    pub fn find(s: *const Settings, repo: []const u8) ?usize {
        for (s.workspaces.items, 0..) |*w, i| if (std.mem.eql(u8, w.repo, repo)) return i;
        return null;
    }

};

/// The `owner/name` a person meant, or null when what they typed is not
/// one: a pasted page URL and a trailing `.git` are read for what they
/// name, and `into` holds the answer (nothing points into `text`).
pub fn repoFrom(into: []u8, text: []const u8) ?[]const u8 {
        var s = std.mem.trim(u8, text, " \t\r\n");
        for ([_][]const u8{ "https://github.com/", "http://github.com/", "github.com/" }) |prefix| {
            if (std.mem.startsWith(u8, s, prefix)) {
                s = s[prefix.len..];
                break;
            }
        }
        if (std.mem.indexOfScalar(u8, s, '?')) |q| s = s[0..q];
        if (std.mem.endsWith(u8, s, ".git")) s = s[0 .. s.len - 4];
        s = std.mem.trimEnd(u8, s, "/");
        const slash = std.mem.indexOfScalar(u8, s, '/') orelse return null;
        if (slash == 0 or slash + 1 == s.len) return null;
        if (std.mem.indexOfScalarPos(u8, s, slash + 1, '/') != null) return null;
        for (s) |ch| {
            const ok = std.ascii.isAlphanumeric(ch) or ch == '-' or ch == '_' or ch == '.' or ch == '/';
            if (!ok) return null;
        }
        if (s.len > into.len) return null;
        @memcpy(into[0..s.len], s);
        return into[0..s.len];
}
