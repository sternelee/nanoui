//! What noop decides without a screen: what GitHub said, what an agent's
//! answer says, and what a run turns into. `zig build test`.
const std = @import("std");
const types = @import("types.zig");
const gh = @import("gh.zig");
const prompt = @import("prompt.zig");
const store = @import("store.zig");
const nanoui = @import("nanoui");
const ui = nanoui.ui;
const app_state = @import("app_state.zig");
const settings_view = @import("settings_view.zig");

const notifications =
    \\[
    \\  {"id":"1","unread":true,"reason":"review_requested",
    \\   "updated_at":"2026-01-02T03:04:05Z",
    \\   "subject":{"title":"Add the notch","url":"https://api.github.com/repos/a/b/pulls/7","type":"PullRequest"},
    \\   "repository":{"full_name":"a/b","html_url":"https://github.com/a/b"}},
    \\  {"id":"2","unread":true,"reason":"mention",
    \\   "updated_at":"2026-01-03T00:00:00Z",
    \\   "subject":{"title":"Crash on quit","url":"https://api.github.com/repos/a/b/issues/9","type":"Issue"},
    \\   "repository":{"full_name":"a/b","html_url":"https://github.com/a/b"}}
    \\]
;

test "notifications become items, newest first, with the page's own address" {
    const gpa = std.testing.allocator;
    const feed = try gpa.dupe(u8, notifications);
    defer gpa.free(feed);
    var reply = try gh.parse(gpa, .{ .out = feed, .code = 0, .err = "" });
    defer reply.free(gpa);
    try std.testing.expectEqual(gh.Reply.Status.ok, reply.status);
    try std.testing.expectEqual(@as(usize, 2), reply.items.len);
    // Newest first: the issue was updated later than the pull request.
    try std.testing.expectEqual(@as(u32, 9), reply.items[0].number);
    try std.testing.expectEqual(types.Kind.issue, reply.items[0].kind);
    try std.testing.expectEqual(types.Reason.mention, reply.items[0].reason);
    try std.testing.expectEqualStrings("a/b", reply.items[0].repo);
    try std.testing.expectEqualStrings("https://github.com/a/b/issues/9", reply.items[0].url);
    try std.testing.expectEqual(types.State.waiting, reply.items[0].state);
    try std.testing.expectEqual(types.Kind.pull, reply.items[1].kind);
    try std.testing.expectEqualStrings("https://github.com/a/b/pull/7", reply.items[1].url);
}

test "a signed-out gh is told apart from an empty one" {
    const gpa = std.testing.allocator;
    const said = try gpa.dupe(u8, "To get started with GitHub CLI, please run: gh auth login");
    defer gpa.free(said);
    const nothing = try gpa.dupe(u8, "");
    defer gpa.free(nothing);
    var out = try gh.parse(gpa, .{ .out = nothing, .code = 4, .err = said });
    defer out.free(gpa);
    try std.testing.expectEqual(gh.Reply.Status.needs_login, out.status);

    const brackets = try gpa.dupe(u8, "[]");
    defer gpa.free(brackets);
    var empty = try gh.parse(gpa, .{ .out = brackets, .code = 0, .err = "" });
    defer empty.free(gpa);
    try std.testing.expectEqual(gh.Reply.Status.ok, empty.status);
    try std.testing.expectEqual(@as(usize, 0), empty.items.len);
}

test "a thread whose words say 403 is still an inbox" {
    const gpa = std.testing.allocator;
    const out = try gpa.dupe(u8,
        \\[{"id":"7","reason":"subscribed","updated_at":"2026-02-01T00:00:00Z",
        \\  "subject":{"title":"rate limit 403 abuse","url":"https://api.github.com/repos/a/b/pulls/12","type":"PullRequest"},
        \\  "repository":{"full_name":"a/b","html_url":"https://github.com/a/b"}}]
    );
    defer gpa.free(out);
    const raw: gh.Raw = .{ .out = out, .code = 0, .err = "" };
    try std.testing.expectEqual(gh.Reply.Status.ok, gh.classify(raw));
    var reply = try gh.parse(gpa, raw);
    defer reply.free(gpa);
    try std.testing.expectEqual(@as(usize, 1), reply.items.len);
    try std.testing.expectEqualStrings("rate limit 403 abuse", reply.items[0].title);
}

test "a look asks about the bound repo's own inbox, not the whole account's" {
    const gpa = std.testing.allocator;
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    const plain = try gh.repoArgs(arena.allocator(), "egoist/noop", false);
    try std.testing.expectEqual(@as(usize, 3), plain.len);
    try std.testing.expectEqualStrings("gh", plain[0]);
    try std.testing.expectEqualStrings("api", plain[1]);
    try std.testing.expectEqualStrings("repos/egoist/noop/notifications?per_page=50", plain[2]);
    const mine = try gh.repoArgs(arena.allocator(), "a/b", true);
    try std.testing.expectEqualStrings("repos/a/b/notifications?per_page=50&participating=true", mine[2]);
}

test "a title with quotes in it survives the trip through storage" {
    const gpa = std.testing.allocator;
    var mem: nanoui.kv.Memory = .{ .gpa = gpa };
    defer mem.deinit();
    const stores = mem.store();
    const items = [_]types.Item{.{
        .key = "1",
        .repo = "a/b",
        .number = 7,
        .kind = .pull,
        .reason = .mention,
        .title = "replies like \"1. Deny\" and a \\ backslash",
        .url = "https://github.com/a/b/pull/7",
        .updated = "2026-02-01T00:00:00Z",
        .body = "",
        .state = .waiting,
        .summary = "",
    }};
    try store.saveItems(gpa, stores, &items);
    // What was written is JSON a reader can parse, not just what noop can.
    const text = (try stores.get(gpa, "noop.items")).?;
    defer gpa.free(text);
    const parsed = try std.json.parseFromSlice(std.json.Value, gpa, text, .{});
    defer parsed.deinit();
    const back = store.loadItems(gpa, stores);
    defer {
        for (back) |*i| i.free(gpa);
        gpa.free(back);
    }
    try std.testing.expectEqual(@as(usize, 1), back.len);
    try std.testing.expectEqualStrings(items[0].title, back[0].title);
}

test "an answer is the last fenced json block with a status" {
    const gpa = std.testing.allocator;
    const said =
        \\I looked at the failing test.
        \\```json
        \\{"status":"needs_decision","summary":"Two ways to fix it.","question":"Which fix?",
        \\ "options":["A: revert the flag — 2 min","B: guard the call — 5 min"],"recommendation":"B"}
        \\```
    ;
    var r = prompt.parseResult(gpa, said) orelse return error.NoResult;
    defer r.free(gpa);
    try std.testing.expectEqual(types.Result.Status.needs_decision, r.status);
    try std.testing.expectEqualStrings("Which fix?", r.question);

    var d = try prompt.decisions(gpa, r);
    defer d.free(gpa);
    try std.testing.expectEqual(@as(usize, 2), d.options.items.len);
    // Recommended first, and lettered by the app, not the agent.
    try std.testing.expectEqualStrings("A", d.options.items[0].letter);
    try std.testing.expectEqualStrings("A", d.recommendation);
    try std.testing.expect(std.mem.indexOf(u8, d.options.items[0].text, "guard the call") != null);
}

test "more options than a notch can show are cut to two" {
    const gpa = std.testing.allocator;
    var r = types.Result{
        .status = .needs_decision,
        .question = &.{},
        .recommendation = &.{},
        .summary = &.{},
    };
    defer r.free(gpa);
    try r.options.append(gpa, try gpa.dupe(u8, "A: one"));
    try r.options.append(gpa, try gpa.dupe(u8, "B: two"));
    try r.options.append(gpa, try gpa.dupe(u8, "C: three"));
    var d = try prompt.decisions(gpa, r);
    defer d.free(gpa);
    try std.testing.expectEqual(@as(usize, 2), d.options.items.len);
}

test "a run's tail is one short line" {
    const gpa = std.testing.allocator;
    const text = "step one\nstep two\n\n  the last words\n";
    const tail = try prompt.tail(gpa, text);
    defer gpa.free(tail);
    try std.testing.expect(!std.mem.containsAtLeast(u8, tail, 1, "\n"));
    try std.testing.expect(std.mem.indexOf(u8, tail, "the last words") != null);
}

test "the prompt names the folder the agent must work in" {
    const gpa = std.testing.allocator;
    const item = types.Item{
        .key = "1",
        .repo = "a/b",
        .number = 7,
        .kind = .pull,
        .reason = .review_requested,
        .title = "Add the notch",
        .url = "https://github.com/a/b/pull/7",
        .updated = "2026-01-02T03:04:05Z",
        .body = "Please review.",
        .state = .waiting,
        .summary = &.{},
    };
    const text = try prompt.forItem(gpa, &item, "/Users/me/src/b");
    defer gpa.free(text);
    try std.testing.expect(std.mem.indexOf(u8, text, "/Users/me/src/b") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "a/b#7") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "\"status\"") != null);
}

test "the agent's argv puts the prompt on stdin, and its flags on the CLI" {
    const gpa = std.testing.allocator;
    const claude = try @import("agent.zig").args(gpa, .claude, "sonnet", "", false);
    defer free(gpa, claude);
    try std.testing.expect(std.mem.eql(u8, claude[claude.len - 1], "-"));
    try std.testing.expect(index(claude, "--output-format") != null);
    try std.testing.expect(index(claude, "--permission-mode") != null);

    const codex = try @import("agent.zig").args(gpa, .codex, "", "abc", true);
    defer free(gpa, codex);
    try std.testing.expect(std.mem.eql(u8, codex[0], "codex"));
    try std.testing.expect(index(codex, "resume") != null);
    try std.testing.expect(index(codex, "--sandbox") != null);
}

fn index(argv: []const []const u8, want: []const u8) ?usize {
    for (argv, 0..) |a, i| {
        if (std.mem.eql(u8, a, want)) return i;
    }
    return null;
}

fn free(gpa: std.mem.Allocator, argv: []const []const u8) void {
    for (argv) |a| gpa.free(a);
    gpa.free(argv);
}

test "a repo is read from what people paste, and anything else is refused" {
    var buf: [120]u8 = undefined;
    const cases = [_]struct { in: []const u8, want: ?[]const u8 }{
        .{ .in = "egoist/noop", .want = "egoist/noop" },
        .{ .in = "  egoist/noop\n", .want = "egoist/noop" },
        .{ .in = "https://github.com/egoist/noop", .want = "egoist/noop" },
        .{ .in = "https://github.com/egoist/noop/tree/main", .want = null },
        .{ .in = "github.com/egoist/noop.git", .want = "egoist/noop" },
        .{ .in = "https://github.com/egoist/noop?tab=readme", .want = "egoist/noop" },
        .{ .in = "https://github.com/egoist/noop/", .want = "egoist/noop" },
        .{ .in = "/Users/sternelee/www/github/search", .want = null },
        .{ .in = "egoist", .want = null },
        .{ .in = "egoist/", .want = null },
        .{ .in = "/noop", .want = null },
        .{ .in = "", .want = null },
    };
    for (cases) |case| {
        const got = types.repoFrom(&buf, case.in);
        if (case.want) |want| {
            try std.testing.expectEqualStrings(want, got orelse "?");
        } else {
            try std.testing.expect(got == null);
        }
    }
}

test "an inbox with nothing in it reads as an empty inbox" {
    const gpa = std.testing.allocator;
    const out = try gpa.dupe(u8, "[]");
    defer gpa.free(out);
    var reply = try gh.parse(gpa, .{ .out = out, .code = 0, .err = "" });
    defer reply.free(gpa);
    try std.testing.expectEqual(gh.Reply.Status.ok, reply.status);
    try std.testing.expectEqual(@as(usize, 0), reply.items.len);
}

test "chatter after the inbox does not break the read" {
    const gpa = std.testing.allocator;
    const out = try gpa.dupe(u8,
        \\[]
        \\A new release of gh is available: 2.0.0 → 2.1.0
        \\https://github.com/cli/cli/releases/tag/v2.1.0 [note] {}
    );
    defer gpa.free(out);
    var reply = try gh.parse(gpa, .{ .out = out, .code = 0, .err = "" });
    defer reply.free(gpa);
    try std.testing.expectEqual(gh.Reply.Status.ok, reply.status);
    try std.testing.expectEqual(@as(usize, 0), reply.items.len);
}

test "a warning before the inbox does not break the read" {
    const gpa = std.testing.allocator;
    const out = try gpa.dupe(u8, "gh: notice something\\n[]");
    defer gpa.free(out);
    var reply = try gh.parse(gpa, .{ .out = out, .code = 0, .err = "" });
    defer reply.free(gpa);
    try std.testing.expectEqual(gh.Reply.Status.ok, reply.status);
    try std.testing.expectEqual(@as(usize, 0), reply.items.len);
}

test "the every-row buttons move the interval" {
    const gpa = std.testing.allocator;
    var mem: nanoui.kv.Memory = .{ .gpa = gpa };
    defer mem.deinit();
    var state: app_state.State = .{
        .gpa = gpa,
        .app = undefined,
        .kv = mem.store(),
    };
    defer state.deinit();
    var t: ui.Tester = undefined;
    try t.init(gpa, .init(&state, settings_view.view), .{});
    defer t.deinit();
    try t.clickText("+");
    try std.testing.expectEqual(@as(u32, 90), state.settings.every);
    try t.clickText("+");
    try std.testing.expectEqual(@as(u32, 120), state.settings.every);
    try t.clickText("−");
    try std.testing.expectEqual(@as(u32, 90), state.settings.every);
}
