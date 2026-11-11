//! GitHub through the `gh` command line tool: the login the terminal already
//! has, and no token of noop's own. What `gh` prints is parsed here; what it
//! means about the account — signed out, rate limited, missing — is decided
//! here too, because the notch has to say so in one line.
const std = @import("std");
const json = std.json;
const types = @import("types.zig");
const cmd = @import("cmd.zig");

pub const Item = types.Item;

/// What a look at GitHub answered: items, or why there are none. `err` is a
/// fixed string; `detail` is the first line of what `gh` wrote, if that says
/// anything a person could act on.
pub const Reply = struct {
    items: []Item = &.{},
    /// `ok`, `needs_login`, `starved`, `not_installed`, `failed`.
    status: Status = .ok,
    detail: []u8 = &.{},

    pub const Status = enum { ok, needs_login, starved, not_installed, failed };

    pub fn free(r: *Reply, gpa: std.mem.Allocator) void {
        for (r.items) |*i| i.free(gpa);
        gpa.free(r.items);
        gpa.free(r.detail);
        r.* = .{};
    }
};

/// Where a command ended: its bytes, and whether it ran at all.
pub const Raw = struct {
    out: []u8,
    code: ?u8,
    err: []const u8,
};

// ---------------------------------------------------------------- commands

/// The command line of one look at the inbox. `since` is GitHub's own
/// `updated_at` cursor, empty for everything unread.
pub fn notificationsArgs(gpa: std.mem.Allocator, since: []const u8, participating_only: bool) ![][]const u8 {
    var path = std.ArrayList(u8).empty;
    defer path.deinit(gpa);
    try path.appendSlice(gpa, "notifications?per_page=50");
    if (participating_only) try path.appendSlice(gpa, "&participating=true");
    if (since.len > 0 and !std.mem.eql(u8, since, "0")) {
        try path.append(gpa, '&');
        try path.appendSlice(gpa, "since=");
        try path.appendSlice(gpa, since);
    }
    const api = try gpa.dupe(u8, path.items);
    return list(gpa, &.{ "gh", "api", api });
}

/// And one at one bound repo's own inbox: the same thread JSON the whole
/// account's inbox returns, narrowed to the repositories a workspace names.
/// Nothing is read before a workspace is bound, so this is the only look.
pub fn repoArgs(gpa: std.mem.Allocator, repo: []const u8, participating_only: bool) ![][]const u8 {
    var path = std.ArrayList(u8).empty;
    defer path.deinit(gpa);
    try path.appendSlice(gpa, "repos/");
    try path.appendSlice(gpa, repo);
    try path.appendSlice(gpa, "/notifications?per_page=50");
    if (participating_only) try path.appendSlice(gpa, "&participating=true");
    const api = try gpa.dupe(u8, path.items);
    return list(gpa, &.{ "gh", "api", api });
}

/// The command line that marks a thread read, so it leaves the inbox.
pub fn readArgs(gpa: std.mem.Allocator, key: []const u8) ![][]const u8 {
    const thread = try gpa.print("notifications/threads/{s}", .{key});
    return list(gpa, &.{ "gh", "api", "-X", "PATCH", thread, "-f", "read=true" });
}

/// The command line for the thing a notification is about: its issue, pull
/// request or comment.
pub fn subjectArgs(gpa: std.mem.Allocator, api_url: []const u8) ![][]const u8 {
    return list(gpa, &.{ "gh", "api", try gpa.dupe(u8, trimApi(api_url)) });
}

/// And for the last few comments on it, which is where a review asks for
/// something specific.
pub fn commentsArgs(gpa: std.mem.Allocator, api_url: []const u8) ![][]const u8 {
    const path = try gpa.print("{s}/comments?per_page=6&sort=updated&direction=desc", .{trimApi(api_url)});
    return list(gpa, &.{ "gh", "api", path });
}

/// The command line that asks what is left of this token's budget.
pub fn rateArgs(gpa: std.mem.Allocator) ![][]const u8 {
    return list(gpa, &.{ "gh", "api", "rate_limit" });
}

fn list(gpa: std.mem.Allocator, items: []const []const u8) ![][]const u8 {
    const out = try gpa.alloc([]const u8, items.len);
    for (items, 0..) |s, i| out[i] = s;
    return out;
}

/// `https://api.github.com/repos/o/r/issues/7` to `repos/o/r/issues/7`, the
/// form `gh api` wants.
fn trimApi(url: []const u8) []const u8 {
    const at = std.mem.indexOf(u8, url, "/repos/") orelse return url;
    return url[at + 1 ..];
}

// ------------------------------------------------------------------ parsing

/// What a subject is: what an agent would have to change.
pub fn kindOf(subject_type: []const u8, reason: types.Reason) types.Kind {
    if (reason == .ci_activity) return .checks;
    if (std.mem.eql(u8, subject_type, "PullRequest")) {
        return if (reason == .comment or reason == .mention) .comment else .pull;
    }
    if (std.mem.eql(u8, subject_type, "CommitComment")) return .comment;
    return if (reason == .comment) .comment else .issue;
}

pub fn reasonOf(text: []const u8) types.Reason {
    const table = [_]struct { r: types.Reason, t: []const u8 }{
        .{ .r = .assigned, .t = "assigned" },
        .{ .r = .author, .t = "author" },
        .{ .r = .comment, .t = "comment" },
        .{ .r = .ci_activity, .t = "ci_activity" },
        .{ .r = .mention, .t = "mention" },
        .{ .r = .review_requested, .t = "review_requested" },
        .{ .r = .subscription, .t = "subscription" },
    };
    for (table) |e| if (std.mem.eql(u8, e.t, text)) return e.r;
    return .other;
}

/// The number at the end of an API url: `…/issues/123` to 123.
pub fn numberOf(url: []const u8) ?u32 {
    const tail = std.mem.trimEnd(u8, url, "/");
    const slash = std.mem.lastIndexOfScalar(u8, tail, '/') orelse return null;
    var sum: u32 = 0;
    for (tail[slash + 1 ..]) |ch| {
        if (ch < '0' or ch > '9') return null;
        sum = sum * 10 + (ch - '0');
    }
    return if (sum == 0) null else sum;
}

/// The page to open for a thread's subject: GitHub answers `/issues/N` for a
/// pull request too, but the pull page is what a person means.
pub fn htmlUrl(gpa: std.mem.Allocator, repo_html: []const u8, api_url: []const u8, subject_type: []const u8) ![]u8 {
    const leaf = if (std.mem.eql(u8, subject_type, "PullRequest")) "pull" else "issues";
    const n = numberOf(api_url) orelse return gpa.dupe(u8, repo_html);
    return gpa.print("{s}/{s}/{d}", .{ repo_html, leaf, n });
}

const ThreadSubject = struct {
    title: ?[]const u8 = null,
    url: ?[]const u8 = null,
    type: ?[]const u8 = null,
};

const ThreadRepo = struct {
    full_name: ?[]const u8 = null,
    html_url: ?[]const u8 = null,
};

const Thread = struct {
    id: ?[]const u8 = null,
    reason: ?[]const u8 = null,
    updated_at: ?[]const u8 = null,
    subject: ?ThreadSubject = null,
    repository: ?ThreadRepo = null,
};

/// `gh api notifications` into items, newest first, each still `waiting`.
/// Anything unparsable is a `gh` message, not a list: `parse` reports the
/// status it deserves.
pub fn parse(gpa: std.mem.Allocator, raw: Raw) !Reply {
    var r: Reply = .{ .status = classify(raw) };
    if (r.status != .ok) {
        r.detail = firstLine(gpa, raw.out) catch "";
        return r;
    }
    const threads = jsonSlice(gpa, raw.out) catch {
        r.status = .failed;
        r.detail = firstLine(gpa, raw.out) catch "";
        return r;
    };
    defer gpa.free(threads);
    const parsed = try json.parseFromSlice([]Thread, gpa, threads, .{
        .ignore_unknown_fields = true,
        .duplicate_field_behavior = .use_last,
    });
    defer parsed.deinit();

    var out = std.ArrayList(Item).empty;
    errdefer out.deinit(gpa);
    for (parsed.value) |t| {
        // GitHub nulls a subject's url for the thread kinds it has no page
        // for, so every field is read as absent until it is there.
        const subject: ThreadSubject = t.subject orelse ThreadSubject{};
        const repo: ThreadRepo = t.repository orelse ThreadRepo{};
        const title = subject.title orelse "";
        const url = subject.url orelse "";
        const subject_type = subject.type orelse "";
        const repo_name = repo.full_name orelse "";
        const repo_html = repo.html_url orelse "";
        const reason = reasonOf(t.reason orelse "");
        const kind = kindOf(subject_type, reason);
        try out.append(gpa, .{
            .key = try gpa.dupe(u8, t.id orelse "0"),
            .repo = try gpa.dupe(u8, repo_name),
            .number = numberOf(url) orelse 0,
            .kind = kind,
            .reason = reason,
            .title = try gpa.dupe(u8, title),
            .url = try htmlUrl(gpa, repo_html, url, subject_type),
            .updated = try gpa.dupe(u8, t.updated_at orelse ""),
        });
    }
    sortNewest(out.items);
    r.items = try out.toOwnedSlice(gpa);
    return r;
}

/// Newest first: the notch shows what came last at the top.
fn sortNewest(items: []Item) void {
    std.mem.sort(Item, items, {}, (struct {
        fn later(_: void, a: Item, b: Item) bool {
            return std.mem.order(u8, a.updated, b.updated) == .gt;
        }
    }).later);
}

/// What `gh`'s end means for the notch: signed out and rate limited are said
/// in a line, everything else is a failure with its first line as the detail.
pub fn classify(raw: Raw) Reply.Status {
    if (raw.err.len > 0 and std.mem.indexOf(u8, raw.err, "not found") != null) return .not_installed;
    // Only what `gh` says, never the answer itself: an inbox is hundreds of
    // kilobytes of other people's words, and one of them saying "403" or
    // "rate limit" is not GitHub saying it.
    const said = if (looksJson(raw.out)) raw.err else if (raw.out.len > 0) raw.out else raw.err;
    const zero = raw.code == null or raw.code.? == 0;
    const hits = [_]struct { s: Reply.Status, t: []const u8 }{
        .{ .s = .needs_login, .t = "gh auth login" },
        .{ .s = .needs_login, .t = "not logged in" },
        .{ .s = .needs_login, .t = "authentication failed" },
        .{ .s = .needs_login, .t = "requires authentication" },
        .{ .s = .starved, .t = "rate limit" },
        .{ .s = .starved, .t = "secondary rate" },
        .{ .s = .starved, .t = "HTTP 403" },
        .{ .s = .starved, .t = "abuse" },
    };
    for (hits) |h| if (std.mem.indexOf(u8, said, h.t) != null) return h.s;
    if (zero and raw.err.len == 0) return .ok;
    return .failed;
}

/// Whether a command's output is a JSON answer rather than a complaint: the
/// first sign, a warning line before it aside, is a `[` or a `{`.
fn looksJson(out: []const u8) bool {
    for (out) |ch| switch (ch) {
        ' ', '\t', '\r', '\n' => {},
        '[', '{' => return true,
        else => return false,
    };
    return false;
}

/// The first thing a command said that reads as words: its first line once
/// colour and other control sequences are gone, skipping lines that only
/// carried those. A person reads the one line; a `\x1b[1;37m[m` is not it.
pub fn firstLine(gpa: std.mem.Allocator, text: []u8) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);
    var lines = std.mem.splitScalar(u8, text, '\n');
    while (lines.next()) |raw| {
        out.clearRetainingCapacity();
        try plain(gpa, &out, raw);
        const line = std.mem.trim(u8, out.items, " \t\r");
        if (line.len > 0) return gpa.dupe(u8, line);
    }
    return gpa.dupe(u8, "");
}

/// `raw` without its escape sequences. A `CSIm` that lost its `\x1b` on the
/// way is dropped too: a colour is never a word.
fn plain(gpa: std.mem.Allocator, out: *std.ArrayList(u8), raw: []const u8) !void {
    var i: usize = 0;
    while (i < raw.len) {
        const ch = raw[i];
        if (ch == '\x1b' and i + 1 < raw.len) {
            i += 2;
            if (raw[i - 1] == '[') {
                // CSI: parameters, then one final byte in `@`..`~`.
                while (i < raw.len and (raw[i] < 0x40 or raw[i] > 0x7e)) : (i += 1) {}
                if (i < raw.len) i += 1;
            } else if (raw[i - 1] == ']') {
                // OSC: until a bell, or the `\x1b\\` that ends it.
                while (i < raw.len and raw[i] != 0x07) : (i += 1) {}
                if (i < raw.len) i += 1;
            }
            continue;
        }
        if (ch == '[' and isSgr(raw[i..])) {
            i += sgrLen(raw[i..]);
            continue;
        }
        if (ch != '\r' and ch != 0x07) try out.append(gpa, ch);
        i += 1;
    }
}

/// Whether `s` opens a `[3;1m`-shaped colour run: digits and `;` inside, a
/// letter after, and nothing a word would have.
fn isSgr(s: []const u8) bool {
    return sgrLen(s) > 0;
}

fn sgrLen(s: []const u8) usize {
    var i: usize = 1;
    while (i < s.len and (std.ascii.isDigit(s[i]) or s[i] == ';' or s[i] == ':' or s[i] == '?')) : (i += 1) {}
    if (i == 1 or i >= s.len) return 0;
    return switch (s[i]) {
        'm', 'K', 'H', 'J' => i + 1,
        else => 0,
    };
}

/// The bytes of a JSON answer inside what a command wrote: a stray warning
/// line before it, a trailing newline after it, both ignored.
pub fn jsonSlice(gpa: std.mem.Allocator, text: []u8) ![]const u8 {
    // The document ends where its brackets balance, not at the last bracket
    // anywhere: `gh` folds its stderr into the stream, so a notice after
    // the body ("A new release of gh is available ... [x]") would otherwise
    // be swallowed into the answer and break the parse.
    const open = std.mem.indexOfAny(u8, text, "[{") orelse return error.NotJson;
    var depth: usize = 0;
    var in_string = false;
    var at = open;
    while (at < text.len) : (at += 1) {
        const ch = text[at];
        if (in_string) {
            if (ch == '\\') {
                at += 1;
            } else if (ch == '"') {
                in_string = false;
            }
            continue;
        }
        switch (ch) {
            '"' => in_string = true,
            '[', '{' => depth += 1,
            ']', '}' => {
                depth -= 1;
                if (depth == 0) return gpa.dupe(u8, text[open .. at + 1]);
            },
            else => {},
        }
    }
    return error.NotJson;
}

/// The body of an issue or a pull request, and who wrote the last comments.
pub const Details = struct {
    title: []u8 = &.{},
    body: []u8 = &.{},
    /// `base…head`, what a pull request would change.
    refs: []u8 = &.{},
    state: []u8 = &.{},
    comments: []u8 = &.{},
};

const Subject = struct {
    title: []const u8 = "",
    body: ?[]const u8 = null,
    state: []const u8 = "",
    draft: bool = false,
    base: ?struct { ref: []const u8 = "" } = null,
    head: ?struct { ref: []const u8 = "" } = null,
};

const Comment = struct {
    body: ?[]const u8 = null,
    user: ?struct { login: []const u8 = "" } = null,
};

/// The body of a `gh api repos/.../issues/7`, and of its comments.
pub fn parseDetails(gpa: std.mem.Allocator, one: Raw, comments: Raw) !Details {
    var d: Details = .{};
    d.title = try gpa.dupe(u8, "");
    d.body = try gpa.dupe(u8, "");
    d.refs = try gpa.dupe(u8, "");
    d.state = try gpa.dupe(u8, "");
    d.comments = try gpa.dupe(u8, "");
    if (one.code != null and one.code.? == 0) {
        const sliced = jsonSlice(gpa, one.out) catch null;
        defer if (sliced) |sl| gpa.free(sl);
        const text = sliced orelse one.out;
        const parsed = try json.parseFromSlice(Subject, gpa, text, .{
            .ignore_unknown_fields = true,
        });
        defer parsed.deinit();
        const s = parsed.value;
        d.title = try gpa.dupe(u8, s.title);
        d.body = try gpa.dupe(u8, s.body orelse "");
        d.state = try gpa.dupe(u8, s.state);
        if (s.head) |h| {
            const base = if (s.base) |b| b.ref else "";
            gpa.free(d.refs);
            d.refs = try gpa.print("{s} → {s}{s}", .{ base, h.ref, if (s.draft) " (draft)" else "" });
        }
    }
    if (comments.code != null and comments.code.? == 0) {
        const sliced = jsonSlice(gpa, comments.out) catch null;
        defer if (sliced) |sl| gpa.free(sl);
        const text = sliced orelse comments.out;
        const hold = json.parseFromSlice([]Comment, gpa, text, .{ .ignore_unknown_fields = true }) catch null;
        defer if (hold) |h| h.deinit();
        const cs: []const Comment = if (hold) |h| h.value else &.{};
        var out = std.ArrayList(u8).empty;
        for (cs) |c| {
            const who = if (c.user) |u| u.login else "?";
            const body = std.mem.trim(u8, c.body orelse "", " \r\n");
            if (body.len == 0) continue;
            try out.appendSlice(gpa, who);
            try out.appendSlice(gpa, ": ");
            try out.appendSlice(gpa, if (body.len > 1200) body[0..1200] else body);
            try out.append(gpa, '\n');
        }
        d.comments = try out.toOwnedSlice(gpa);
    }
    return d;
}

/// Everything an agent needs to know about an item, for its prompt.
pub fn detailsBody(gpa: std.mem.Allocator, d: Details) ![]u8 {
    var out: std.Io.Writer.Allocating = .init(gpa);
    errdefer out.deinit();
    if (d.refs.len > 0) try out.writer.print("Branches: {s}\n\n", .{d.refs});
    if (d.body.len > 0) {
        const body = if (d.body.len > 6000) d.body[0..6000] else d.body;
        try out.writer.print("Its body:\n{s}\n\n", .{body});
    }
    if (d.comments.len > 0) try out.writer.print("Last comments:\n{s}\n", .{d.comments});
    return out.toOwnedSlice();
}
