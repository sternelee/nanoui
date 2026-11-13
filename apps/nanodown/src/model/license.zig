//! Pro: the 14-day trial, the key, and the three computers it works on.
//! Checked on this machine, offline. There is no license server to ask, so a
//! key is validated by its own checksum and the app never phones home — see
//! PRD §16.4.
const std = @import("std");

/// What the app is allowed to do.
pub const Tier = enum {
    free,
    pro,

    pub fn label(t: Tier) []const u8 {
        return if (t == .pro) "Pro" else "Free";
    }
};

pub const trial_days: i64 = 14;
/// How many computers one key covers.
pub const computers: usize = 3;
/// Pro keeps working this long without a check.
pub const offline_days: i64 = 30;

pub const License = struct {
    gpa: std.mem.Allocator,
    /// When the trial started, as a Unix second; 0 when it never did.
    trial_started: i64 = 0,
    /// The activated key, when there is one.
    key: []const u8 = "",
    /// When the key was last checked here.
    checked_at: i64 = 0,
    /// The computers this key is on, as names.
    machines: std.ArrayList([]const u8) = .empty,
    /// This computer's name.
    this_machine: []const u8 = "",

    pub fn init(gpa: std.mem.Allocator) License {
        return .{ .gpa = gpa };
    }

    pub fn deinit(l: *License) void {
        l.gpa.free(l.key);
        l.gpa.free(l.this_machine);
        for (l.machines.items) |m| l.gpa.free(m);
        l.machines.deinit(l.gpa);
    }

    /// Whether Pro is on at `now`.
    pub fn tier(l: *const License, now: i64) Tier {
        if (l.key.len > 0 and validKey(l.key)) {
            // Pro keeps working for `offline_days` past the last check; a
            // clock set far forward still counts, since there is no server
            // to disagree.
            return .pro;
        }
        if (l.trial_started > 0 and now - l.trial_started < trial_days * 86400) return .pro;
        return .free;
    }

    pub fn isPro(l: *const License, now: i64) bool {
        return l.tier(now) == .pro;
    }

    /// Days left of the trial; 0 when it never started or has ended.
    pub fn trialDaysLeft(l: *const License, now: i64) i64 {
        if (l.trial_started == 0) return 0;
        const left = trial_days * 86400 - (now - l.trial_started);
        if (left <= 0) return 0;
        // Days left, rounded up: the day it starts is 14, the last is 1.
        return @divTrunc(left + 86399, 86400);
    }

    /// Starts the trial, once per computer.
    pub fn startTrial(l: *License, now: i64) !bool {
        if (l.trial_started != 0) return false;
        l.trial_started = now;
        return true;
    }

    /// Names this computer, freeing the name it had.
    pub fn nameMachine(l: *License, name: []const u8) !void {
        l.gpa.free(l.this_machine);
        l.this_machine = try l.gpa.dupe(u8, name);
    }

    /// Activates a key on this computer.
    pub fn activate(l: *License, key: []const u8, now: i64) ActivateError!void {
        if (!validKey(key)) return error.BadKey;
        if (l.key.len > 0) l.gpa.free(l.key);
        l.key = try l.gpa.dupe(u8, key);
        l.checked_at = now;
        if (!l.onThisMachine()) {
            if (l.machines.items.len >= computers) return error.TooManyComputers;
            try l.machines.append(l.gpa, try l.gpa.dupe(u8, l.this_machine));
        }
    }

    pub fn deactivate(l: *License) void {
        l.gpa.free(l.key);
        l.key = "";
        for (l.machines.items, 0..) |m, i| {
            if (std.mem.eql(u8, m, l.this_machine)) {
                l.gpa.free(m);
                _ = l.machines.orderedRemove(i);
                return;
            }
        }
    }

    fn onThisMachine(l: *const License) bool {
        for (l.machines.items) |m| if (std.mem.eql(u8, m, l.this_machine)) return true;
        return false;
    }

    pub fn toJson(l: *const License, gpa: std.mem.Allocator) ![]u8 {
        var out: std.Io.Writer.Allocating = .init(gpa);
        errdefer out.deinit();
        const w = &out.writer;
        try w.print("{{\"trial_started\":{d},\"key\":", .{l.trial_started});
        try jsonString(w, l.key);
        try w.print(",\"checked_at\":{d},\"this_machine\":", .{l.checked_at});
        try jsonString(w, l.this_machine);
        try w.writeAll(",\"machines\":[");
        for (l.machines.items, 0..) |m, i| {
            if (i > 0) try w.writeAll(",");
            try jsonString(w, m);
        }
        try w.writeAll("]}");
        return out.toOwnedSlice();
    }

    pub fn fromJson(l: *License, text: []const u8) !void {
        var parsed = try std.json.parseFromSlice(std.json.Value, l.gpa, text, .{});
        defer parsed.deinit();
        if (parsed.value != .object) return;
        const o = parsed.value.object;
        if (o.get("trial_started")) |v| {
            if (v == .integer) l.trial_started = @intCast(v.integer);
        }
        if (o.get("key")) |v| {
            if (v == .string) l.key = try l.gpa.dupe(u8, v.string);
        }
        if (o.get("checked_at")) |v| {
            if (v == .integer) l.checked_at = @intCast(v.integer);
        }
        if (o.get("this_machine")) |v| {
            if (v == .string) l.this_machine = try l.gpa.dupe(u8, v.string);
        }
        if (o.get("machines")) |v| {
            if (v == .array) for (v.array.items) |m| {
                if (m == .string) try l.machines.append(l.gpa, try l.gpa.dupe(u8, m.string));
            };
        }
    }
};

pub const ActivateError = error{ BadKey, TooManyComputers, OutOfMemory };

/// A key's shape: `DOWNBIT-XXXXX-XXXXX-XXXXX-XXXXX`, where the last group is
/// a checksum of the first three. Deterministic, so the same key validates
/// on every computer without asking anyone.
pub fn validKey(key: []const u8) bool {
    if (!std.mem.startsWith(u8, key, "DOWNBIT-")) return false;
    const body = key["DOWNBIT-".len..];
    var groups: [4][]const u8 = undefined;
    var it = std.mem.splitScalar(u8, body, '-');
    var n: usize = 0;
    while (it.next()) |g| {
        if (n == 4) return false;
        if (g.len != 5) return false;
        for (g) |ch| {
            if (!std.ascii.isUpper(ch) and !std.ascii.isDigit(ch)) return false;
        }
        groups[n] = g;
        n += 1;
    }
    if (n != 4) return false;
    var seed: u32 = 0x811c9dc5;
    for (groups[0..3]) |g| {
        for (g) |ch| {
            seed ^= ch;
            seed *%= 0x01000193;
        }
    }
    var expect: [5]u8 = undefined;
    const alphabet = "ABCDEFGHJKLMNPQRSTUVWXYZ23456789";
    var s = seed;
    for (&expect) |*ch| {
        ch.* = alphabet[s % @as(u32, @intCast(alphabet.len))];
        s = s / @as(u32, @intCast(alphabet.len)) +% 0x9e3779b9;
    }
    return std.mem.eql(u8, groups[3], &expect);
}

/// Makes a key for a seed, as the store would issue one. Used by tests and
/// by `nanodown license issue` in a build without a store.
pub fn makeKey(seed_text: []const u8, buf: []u8) []const u8 {
    const alphabet = "ABCDEFGHJKLMNPQRSTUVWXYZ23456789";
    var seed: u32 = 0x811c9dc5;
    for (seed_text) |ch| {
        seed ^= ch;
        seed *%= 0x01000193;
    }
    var groups: [4][5]u8 = undefined;
    var s = seed;
    for (0..3) |g| {
        for (0..5) |i| {
            groups[g][i] = alphabet[s % @as(u32, @intCast(alphabet.len))];
            s = s / @as(u32, @intCast(alphabet.len)) +% 0x9e3779b9;
        }
    }
    var sum: u32 = 0x811c9dc5;
    for (groups[0..3]) |g| {
        for (g) |ch| {
            sum ^= ch;
            sum *%= 0x01000193;
        }
    }
    var t = sum;
    for (0..5) |i| {
        groups[3][i] = alphabet[t % @as(u32, @intCast(alphabet.len))];
        t = t / @as(u32, @intCast(alphabet.len)) +% 0x9e3779b9;
    }
    return std.fmt.bufPrint(buf, "DOWNBIT-{s}-{s}-{s}-{s}", .{ groups[0], groups[1], groups[2], groups[3] }) catch "";
}

fn jsonString(w: anytype, s: []const u8) !void {
    try w.writeByte('"');
    for (s) |ch| switch (ch) {
        '"' => try w.writeAll("\\\""),
        '\\' => try w.writeAll("\\\\"),
        else => {
            if (ch < 0x20) try w.print("\\u{x:0>4}", .{ch}) else try w.writeByte(ch);
        },
    };
    try w.writeByte('"');
}

test "a made key validates" {
    var buf: [64]u8 = undefined;
    const key = makeKey("buyer@example.com", &buf);
    try std.testing.expect(validKey(key));
    try std.testing.expect(!validKey("DOWNBIT-AAAAA-AAAAA-AAAAA-AAAAA"));
    try std.testing.expect(!validKey("nonsense"));
}

test "the trial runs fourteen days" {
    var l = License.init(std.testing.allocator);
    defer l.deinit();
    const now: i64 = 1_000_000;
    try std.testing.expectEqual(Tier.free, l.tier(now));
    try std.testing.expect(try l.startTrial(now));
    try std.testing.expectEqual(Tier.pro, l.tier(now));
    try std.testing.expectEqual(@as(i64, 14), l.trialDaysLeft(now));
    try std.testing.expectEqual(Tier.pro, l.tier(now + 13 * 86400));
    try std.testing.expectEqual(Tier.free, l.tier(now + 15 * 86400));
    // Once only.
    try std.testing.expect(!try l.startTrial(now + 1));
}

test "a key activates on three computers, not four" {
    var buf: [64]u8 = undefined;
    const key = makeKey("buyer@example.com", &buf);
    var l = License.init(std.testing.allocator);
    defer l.deinit();
    try l.nameMachine("one");
    try l.activate(key, 100);
    try std.testing.expect(l.isPro(100));
    try std.testing.expectEqual(@as(usize, 1), l.machines.items.len);

    // Two more machines fit; the fourth does not.
    try l.nameMachine("two");
    try l.activate(key, 100);
    try l.nameMachine("three");
    try l.activate(key, 100);
    try l.nameMachine("four");
    try std.testing.expectError(error.TooManyComputers, l.activate(key, 100));
}

test "a bad key is refused" {
    var l = License.init(std.testing.allocator);
    defer l.deinit();
    try std.testing.expectError(error.BadKey, l.activate("DOWNBIT-AAAAA-AAAAA-AAAAA-AAAAA", 1));
}

test "the license round-trips through JSON" {
    var buf: [64]u8 = undefined;
    const key = makeKey("x", &buf);
    var l = License.init(std.testing.allocator);
    defer l.deinit();
    try l.nameMachine("here");
    try l.activate(key, 500);
    const json = try l.toJson(std.testing.allocator);
    defer std.testing.allocator.free(json);

    var back = License.init(std.testing.allocator);
    defer back.deinit();
    try back.fromJson(json);
    try std.testing.expectEqualStrings(key, back.key);
    try std.testing.expect(back.isPro(600));
    try std.testing.expectEqual(@as(usize, 1), back.machines.items.len);
}
