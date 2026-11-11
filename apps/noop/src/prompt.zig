//! What an agent is told, and what it is asked to answer with. The prompt
//! fits noop's shape: one item, one directory, and a last line of JSON that
//! the notch can read as it is.
const std = @import("std");
const json = std.json;
const types = @import("types.zig");

/// The contract, kept in one place so the tests and the prompts agree.
const contract =
    \\
    \\End your reply with exactly one fenced block, and nothing after it:
    \\```json
    \\{"status":"done","summary":"what you did, and where it lives now: the branch, the commit, or the pull request number"}
    \\```
    \\or, when only the owner can say:
    \\```json
    \\{"status":"needs_decision","summary":"what you finished before stopping","question":"what to decide, under 30 characters","options":["A: what you recommend — what it costs","B: the alternative — what it costs"],"recommendation":"A"}
    \\```
    \\or, when it truly did not work:
    \\```json
    \\{"status":"failed","summary":"the shortest sentence the owner can act on"}
    \\```
;

const rules =
    \\Write for someone reading this at a coffee, not for a report:
    \\- never surface a raw error, a stack trace, or a test fixture's data.
    \\- if the change belongs in another repository, say so in one line and stop.
    \\- when something only the owner can answer stands in the way, do
    \\  everything else that does not depend on it, then ask.
    \\- do not sit waiting on CI: report what you have and let the owner look.
;

/// The header an agent reads first: where it is, what it is to do, and what
/// the item says.
fn identity(gpa: std.mem.Allocator, dir: []const u8, item: *const types.Item) ![]u8 {
    var out: std.Io.Writer.Allocating = .init(gpa);
    errdefer out.deinit();
    const w = &out.writer;
    try w.print(
        \\noop: one agent, working alone in {s} on {s}.
        \\
        \\Handle this one thing from GitHub, through the repository's own tools
        \\(git for the work, `gh` for what GitHub itself needs): read it, change
        \\it, test it, and open a pull request or leave a comment when this
        \\repository's contributing guide asks for that. Its own AGENTS.md and
        \\CONTRIBUTING.md say how things are done here — read them first.
        \\
        \\# {s}#{d}: {s}
        \\  {s}
        \\
        \\
    , .{ dir, item.repo, item.repo, item.number, item.title, item.url });
    if (item.body.len > 0) try w.writeAll(item.body);
    try w.writeAll("\n" ++ rules ++ contract);
    return out.toOwnedSlice();
}

/// The prompt for an item, with what was fetched about it already in
/// `item.body`.
pub fn forItem(gpa: std.mem.Allocator, item: *const types.Item, dir: []const u8) ![]u8 {
    return identity(gpa, dir, item);
}

/// The same agent, one turn later: what the owner tapped.
pub fn forAnswer(
    gpa: std.mem.Allocator,
    item: *const types.Item,
    dir: []const u8,
    question: []const u8,
    answer: []const u8,
    previous: []const u8,
) ![]u8 {
    const head = try identity(gpa, dir, item);
    defer gpa.free(head);
    var out: std.Io.Writer.Allocating = .init(gpa);
    errdefer out.deinit();
    const w = &out.writer;
    try w.writeAll(head);
    try w.print(
        "The owner answered the question you asked.\n\n" ++
            "# Your question\n{s}\n\n" ++
            "# Their answer\n{s}\n\n" ++
            "# What you had done by then\n{s}\n\n" ++
            "Pick up from there and finish the job.\n",
        .{ question, answer, previous },
    );
    return out.toOwnedSlice();
}

/// What an agent ended with: the last fenced JSON block with a status in it.
/// Null when it never got that far, which the caller reports as a failure
/// with the agent's own tail as the summary.
pub fn parseResult(gpa: std.mem.Allocator, text: []const u8) ?types.Result {
    var found: ?types.Result = null;
    var at: usize = 0;
    while (std.mem.indexOf(u8, text[at..], "```json")) |rel| {
        const open = at + rel + 7;
        const close = std.mem.indexOf(u8, text[open..], "```") orelse break;
        const body = std.mem.trim(u8, text[open .. open + close], " \r\n");
        at = open + close;
        const r = jsonResult(gpa, body) catch continue;
        if (r) |one| {
            if (found) |*prev| prev.free(gpa);
            found = one;
        }
    }
    return found;
}

const Parsed = struct {
    status: []const u8 = "",
    summary: ?[]const u8 = null,
    question: ?[]const u8 = null,
    options: ?[]const []const u8 = null,
    recommendation: ?[]const u8 = null,
};

fn jsonResult(gpa: std.mem.Allocator, body: []const u8) !?types.Result {
    const parsed = try json.parseFromSlice(Parsed, gpa, body, .{ .ignore_unknown_fields = true });
    defer parsed.deinit();
    const p = parsed.value;
    if (p.status.len == 0) return null;
    var r: types.Result = .{};
    errdefer r.free(gpa);
    r.summary = try gpa.dupe(u8, p.summary orelse "");
    r.question = try gpa.dupe(u8, p.question orelse "");
    r.recommendation = try gpa.dupe(u8, p.recommendation orelse "");
    r.status = if (std.mem.eql(u8, p.status, "done"))
        .done
    else if (std.mem.eql(u8, p.status, "needs_decision"))
        .needs_decision
    else
        .failed;
    if (p.options) |list| {
        for (list) |o| {
            // "A: do it now — it lands today": the letter is the tap, the
            // rest is what a person reads.
            const colon = std.mem.indexOfScalar(u8, o, ':');
            const text = if (colon) |c| std.mem.trim(u8, o[c + 1 ..], " ") else o;
            try r.options.append(gpa, try gpa.dupe(u8, text));
        }
    }
    return r;
}

/// The lettered options a decision card shows: `A`, `B`, at most two, the
/// recommendation named first among them.
pub fn decisions(gpa: std.mem.Allocator, r: types.Result) !types.Decision {
    var d: types.Decision = .{ .question = try gpa.dupe(u8, r.question) };
    errdefer d.free(gpa);
    const letters = [_][]const u8{ "A", "B" };
    // The recommended one first: a notch reads top to bottom.
    var order = [2]usize{ 0, 1 };
    for (r.options.items, 0..) |o, i| {
        if (i >= 2) break;
        const named = std.mem.eql(u8, r.recommendation, letters[i]) or
            (r.recommendation.len > 0 and std.mem.indexOf(u8, o, r.recommendation) != null);
        if (named and i == 1) order = .{ 1, 0 };
    }
    var n: usize = 0;
    for (order) |i| {
        if (i >= r.options.items.len or n >= 2) continue;
        try d.options.append(gpa, .{ .letter = letters[n], .text = try gpa.dupe(u8, r.options.items[i]) });
        n += 1;
    }
    const recommended = r.recommendation.len > 0 and order[0] == 1;
    if (d.options.items.len == 0) {
        try d.options.append(gpa, .{ .letter = "A", .text = try gpa.dupe(u8, r.summary) });
    }
    d.recommendation = try gpa.dupe(u8, if (recommended) "A" else r.recommendation);
    if (r.question.len == 0) {
        gpa.free(d.question);
        d.question = try gpa.dupe(u8, "How should this go?");
    }
    return d;
}

/// The line shown when an agent gave nothing back: its last few hundred
/// bytes, folded onto one line.
pub fn tail(gpa: std.mem.Allocator, text: []const u8) ![]u8 {
    const start = if (text.len > 400) text.len - 400 else 0;
    const trimmed = std.mem.trim(u8, text[start..], " \r\n");
    return std.mem.replaceOwned(u8, gpa, trimmed, "\n", " ");
}
