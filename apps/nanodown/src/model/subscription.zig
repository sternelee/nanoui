//! Channels and playlists followed: what to check, when it was last
//! checked, and what it found. Pure.
const std = @import("std");
const media = @import("media.zig");

/// How often subscriptions are checked.
pub const Cadence = enum {
    hourly,
    six_hours,
    daily,
    manual,

    pub fn label(c: Cadence) []const u8 {
        return switch (c) {
            .hourly => "Every hour",
            .six_hours => "Every 6 hours",
            .daily => "Every day",
            .manual => "Only when I ask",
        };
    }

    /// Seconds between checks; 0 for manual.
    pub fn seconds(c: Cadence) i64 {
        return switch (c) {
            .hourly => 3600,
            .six_hours => 6 * 3600,
            .daily => 24 * 3600,
            .manual => 0,
        };
    }

    pub fn ofIndex(i: u8) Cadence {
        return switch (i) {
            0 => .hourly,
            1 => .six_hours,
            2 => .daily,
            else => .manual,
        };
    }

    pub fn index(c: Cadence) u8 {
        return switch (c) {
            .hourly => 0,
            .six_hours => 1,
            .daily => 2,
            .manual => 3,
        };
    }
};

/// What a subscription downloads its new videos as.
pub const As = enum {
    video,
    audio,

    pub fn label(a: As) []const u8 {
        return if (a == .video) "Videos" else "Audio Only";
    }
};

pub const Subscription = struct {
    id: u64 = 0,
    /// The channel's or playlist's page.
    url: []const u8 = "",
    /// Its name, as the site gives it.
    title: []const u8 = "",
    site: media.Site = .generic,
    /// When it was last checked, as a Unix second; 0 for never.
    checked_at: i64 = 0,
    /// How many new videos the last check found.
    found: u32 = 0,
    /// What its new videos download as.
    as: As = .video,
    /// The ids already downloaded, so a check only takes new ones.
    seen: std.ArrayList([]const u8) = .empty,

    pub fn deinit(s: *Subscription, gpa: std.mem.Allocator) void {
        gpa.free(s.url);
        gpa.free(s.title);
        for (s.seen.items) |id| gpa.free(id);
        s.seen.deinit(gpa);
    }

    /// Whether `id` was already taken.
    pub fn has(s: *const Subscription, id: []const u8) bool {
        for (s.seen.items) |seen| if (std.mem.eql(u8, seen, id)) return true;
        return false;
    }

    /// Remembers `id`, so the next check skips it.
    pub fn mark(s: *Subscription, gpa: std.mem.Allocator, id: []const u8) !void {
        if (s.has(id)) return;
        try s.seen.append(gpa, try gpa.dupe(u8, id));
    }

    /// Whether it is due, given `now`.
    pub fn due(s: *const Subscription, now: i64, cadence: Cadence) bool {
        const every = cadence.seconds();
        if (every == 0) return false;
        return now - s.checked_at >= every;
    }
};

pub const Subscriptions = struct {
    gpa: std.mem.Allocator,
    items: std.ArrayList(Subscription) = .empty,
    next_id: u64 = 1,

    pub fn init(gpa: std.mem.Allocator) Subscriptions {
        return .{ .gpa = gpa };
    }

    pub fn deinit(s: *Subscriptions) void {
        for (s.items.items) |*it| it.deinit(s.gpa);
        s.items.deinit(s.gpa);
    }

    pub fn add(s: *Subscriptions, url: []const u8, title: []const u8, site: media.Site) !*Subscription {
        for (s.items.items) |*it| if (std.mem.eql(u8, it.url, url)) return it;
        const sub: Subscription = .{
            .id = s.next_id,
            .url = try s.gpa.dupe(u8, url),
            .title = try s.gpa.dupe(u8, title),
            .site = site,
        };
        s.next_id += 1;
        try s.items.append(s.gpa, sub);
        return &s.items.items[s.items.items.len - 1];
    }

    pub fn byId(s: *Subscriptions, id: u64) ?*Subscription {
        for (s.items.items) |*it| if (it.id == id) return it;
        return null;
    }

    pub fn remove(s: *Subscriptions, id: u64) void {
        for (s.items.items, 0..) |*it, i| if (it.id == id) {
            it.deinit(s.gpa);
            _ = s.items.orderedRemove(i);
            return;
        };
    }

    /// The subscriptions due at `now`, as indexes.
    pub fn due(s: *const Subscriptions, now: i64, cadence: Cadence, out: []usize) []usize {
        var n: usize = 0;
        for (s.items.items, 0..) |*it, i| {
            if (n == out.len) break;
            if (it.due(now, cadence)) {
                out[n] = i;
                n += 1;
            }
        }
        return out[0..n];
    }

    pub fn toJson(s: *const Subscriptions, gpa: std.mem.Allocator) ![]u8 {
        var out: std.Io.Writer.Allocating = .init(gpa);
        errdefer out.deinit();
        const w = &out.writer;
        try w.writeAll("{\"next_id\":");
        try w.print("{d}", .{s.next_id});
        try w.writeAll(",\"items\":[");
        for (s.items.items, 0..) |it, i| {
            if (i > 0) try w.writeAll(",");
            try w.writeAll("{\"id\":");
            try w.print("{d}", .{it.id});
            try w.writeAll(",\"url\":");
            try jsonString(w, it.url);
            try w.writeAll(",\"title\":");
            try jsonString(w, it.title);
            try w.writeAll(",\"site\":");
            try jsonString(w, @tagName(it.site));
            try w.print(",\"checked_at\":{d},\"found\":{d}", .{ it.checked_at, it.found });
            try w.writeAll(",\"as\":");
            try jsonString(w, @tagName(it.as));
            try w.writeAll(",\"seen\":[");
            for (it.seen.items, 0..) |id, j| {
                if (j > 0) try w.writeAll(",");
                try jsonString(w, id);
            }
            try w.writeAll("]}");
        }
        try w.writeAll("]}");
        return out.toOwnedSlice();
    }

    pub fn fromJson(s: *Subscriptions, text: []const u8) !void {
        var parsed = try std.json.parseFromSlice(std.json.Value, s.gpa, text, .{});
        defer parsed.deinit();
        if (parsed.value != .object) return;
        if (parsed.value.object.get("next_id")) |v| {
            if (v == .integer) s.next_id = @intCast(@max(1, v.integer));
        }
        const items = parsed.value.object.get("items") orelse return;
        if (items != .array) return;
        for (items.array.items) |it| {
            if (it != .object) continue;
            const o = it.object;
            var sub: Subscription = .{
                .url = try s.gpa.dupe(u8, str(o.get("url"))),
                .title = try s.gpa.dupe(u8, str(o.get("title"))),
                .site = siteOf(str(o.get("site"))),
            };
            if (o.get("id")) |v| {
                if (v == .integer) sub.id = @intCast(@max(0, v.integer));
            }
            if (o.get("checked_at")) |v| {
                if (v == .integer) sub.checked_at = @intCast(v.integer);
            }
            if (o.get("found")) |v| {
                if (v == .integer) sub.found = @intCast(@max(0, v.integer));
            }
            if (std.mem.eql(u8, str(o.get("as")), "audio")) sub.as = .audio;
            if (o.get("seen")) |v| {
                if (v == .array) for (v.array.items) |id| {
                    if (id == .string) try sub.seen.append(s.gpa, try s.gpa.dupe(u8, id.string));
                };
            }
            if (sub.id == 0) {
                sub.id = s.next_id;
                s.next_id += 1;
            } else if (sub.id >= s.next_id) s.next_id = sub.id + 1;
            try s.items.append(s.gpa, sub);
        }
    }
};

fn str(v: ?std.json.Value) []const u8 {
    const val = v orelse return "";
    return if (val == .string) val.string else "";
}

fn siteOf(name: []const u8) media.Site {
    const info = @typeInfo(media.Site).@"enum";
    inline for (info.field_names, info.field_values) |fname, fvalue| {
        if (std.mem.eql(u8, name, fname)) return @enumFromInt(fvalue);
    }
    return .generic;
}

fn jsonString(w: anytype, s: []const u8) !void {
    try w.writeByte('"');
    for (s) |ch| switch (ch) {
        '"' => try w.writeAll("\\\""),
        '\\' => try w.writeAll("\\\\"),
        '\n' => try w.writeAll("\\n"),
        else => {
            if (ch < 0x20) try w.print("\\u{x:0>4}", .{ch}) else try w.writeByte(ch);
        },
    };
    try w.writeByte('"');
}

test "a subscription is added once" {
    var s = Subscriptions.init(std.testing.allocator);
    defer s.deinit();
    const a = try s.add("https://youtube.com/@x", "X", .youtube);
    const b = try s.add("https://youtube.com/@x", "X", .youtube);
    try std.testing.expectEqual(a.id, b.id);
    try std.testing.expectEqual(@as(usize, 1), s.items.items.len);
}

test "a subscription is due on its cadence" {
    var s = Subscriptions.init(std.testing.allocator);
    defer s.deinit();
    const sub = try s.add("https://youtube.com/@x", "X", .youtube);
    sub.checked_at = 1000;
    try std.testing.expect(!sub.due(1000 + 3599, .hourly));
    try std.testing.expect(sub.due(1000 + 3600, .hourly));
    try std.testing.expect(!sub.due(1000 + 3600, .six_hours));
    try std.testing.expect(!sub.due(1000 + 999999, .manual));
}

test "seen ids are remembered once" {
    var s = Subscriptions.init(std.testing.allocator);
    defer s.deinit();
    const sub = try s.add("https://youtube.com/@x", "X", .youtube);
    try sub.mark(std.testing.allocator, "abc");
    try sub.mark(std.testing.allocator, "abc");
    try std.testing.expectEqual(@as(usize, 1), sub.seen.items.len);
    try std.testing.expect(sub.has("abc"));
    try std.testing.expect(!sub.has("def"));
}

test "subscriptions round-trip through JSON" {
    var s = Subscriptions.init(std.testing.allocator);
    defer s.deinit();
    const sub = try s.add("https://youtube.com/@x", "Channel X", .youtube);
    sub.checked_at = 42;
    sub.found = 3;
    sub.as = .audio;
    try sub.mark(std.testing.allocator, "v1");
    const json = try s.toJson(std.testing.allocator);
    defer std.testing.allocator.free(json);

    var back = Subscriptions.init(std.testing.allocator);
    defer back.deinit();
    try back.fromJson(json);
    try std.testing.expectEqual(@as(usize, 1), back.items.items.len);
    try std.testing.expectEqualStrings("Channel X", back.items.items[0].title);
    try std.testing.expectEqual(@as(i64, 42), back.items.items[0].checked_at);
    try std.testing.expectEqual(As.audio, back.items.items[0].as);
    try std.testing.expect(back.items.items[0].has("v1"));
}
