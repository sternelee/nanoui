//! Thumbnails: a picture fetched once, kept as its bytes, drawn by key. The
//! fetch runs on its own thread, so a row shows its picture a moment after
//! it appears rather than holding the frame.
const std = @import("std");
const nanoui = @import("nanoui");
const http = nanoui.http;
const httpz = @import("engine/http.zig");

pub const Picture = struct {
    url: []const u8,
    /// The encoded bytes, once they arrived.
    bytes: []const u8 = "",
    /// It did not arrive, or it is not a picture.
    failed: bool = false,
    /// The thread that is fetching it, while it runs.
    thread: ?std.Thread = null,
    /// The bytes are ready to be drawn.
    ready: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
};

pub const Cache = struct {
    gpa: std.mem.Allocator,
    items: std.ArrayList(Picture) = .empty,
    /// How many pictures are kept: the newest are the ones on screen.
    limit: usize = 240,

    pub fn init(gpa: std.mem.Allocator) Cache {
        return .{ .gpa = gpa };
    }

    pub fn deinit(c: *Cache) void {
        for (c.items.items) |*p| {
            if (p.thread) |t| t.join();
            c.gpa.free(p.url);
            if (p.bytes.len > 0) c.gpa.free(p.bytes);
        }
        c.items.deinit(c.gpa);
    }

    /// The picture for a URL, fetching it the first time it is asked for.
    /// Null until it is ready.
    pub fn get(c: *Cache, url: []const u8) ?[]const u8 {
        if (url.len == 0) return null;
        for (c.items.items) |*p| {
            if (!std.mem.eql(u8, p.url, url)) continue;
            if (p.ready.load(.acquire)) return if (p.failed) null else p.bytes;
            return null;
        }
        c.start(url) catch return null;
        return null;
    }

    fn start(c: *Cache, url: []const u8) !void {
        if (c.items.items.len >= c.limit) c.evictOldest();
        const owned = try c.gpa.dupe(u8, url);
        errdefer c.gpa.free(owned);
        try c.items.append(c.gpa, .{ .url = owned });
        const p = &c.items.items[c.items.items.len - 1];
        p.thread = std.Thread.spawn(.{}, fetch, .{ c.gpa, p }) catch null;
        if (p.thread == null) {
            // No thread: fetch it here, once.
            fetch(c.gpa, p);
        }
    }

    fn evictOldest(c: *Cache) void {
        // The first one not on a thread any more.
        for (c.items.items, 0..) |*p, i| {
            if (p.thread) |t| {
                if (!p.ready.load(.acquire)) continue;
                t.join();
                p.thread = null;
            }
            c.gpa.free(p.url);
            if (p.bytes.len > 0) c.gpa.free(p.bytes);
            _ = c.items.orderedRemove(i);
            return;
        }
    }

    fn fetch(gpa: std.mem.Allocator, p: *Picture) void {
        var r = httpz.send(gpa, .{
            .url = p.url,
            .headers = &.{
                .{ .name = "User-Agent", .value = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7)" },
                .{ .name = "Accept", .value = "image/*" },
            },
            .timeout = 20,
        });
        defer r.deinit();
        const body = r.body();
        if (r.status() != 200 or body.len == 0 or !isPicture(body)) {
            p.failed = true;
            p.ready.store(true, .release);
            return;
        }
        p.bytes = gpa.dupe(u8, body) catch {
            p.failed = true;
            p.ready.store(true, .release);
            return;
        };
        p.ready.store(true, .release);
    }
};

/// Whether the bytes start like a picture nanoui can decode.
pub fn isPicture(b: []const u8) bool {
    if (b.len < 8) return false;
    if (b[0] == 0xff and b[1] == 0xd8) return true; // JPEG
    if (std.mem.startsWith(u8, b, "\x89PNG")) return true;
    if (std.mem.startsWith(u8, b, "GIF8")) return true;
    if (std.mem.startsWith(u8, b, "RIFF") and b.len > 12 and std.mem.startsWith(u8, b[8..], "WEBP")) return true;
    return false;
}

test "a picture is told from a page" {
    try std.testing.expect(isPicture(&[_]u8{ 0xff, 0xd8, 0xff, 0xe0, 0, 0, 0, 0 }));
    try std.testing.expect(isPicture("\x89PNG\r\n\x1a\n...."));
    try std.testing.expect(!isPicture("<html><body>no</body></html>"));
    try std.testing.expect(!isPicture(""));
}

test "the cache answers null before the bytes arrive" {
    var c = Cache.init(std.testing.allocator);
    defer c.deinit();
    try std.testing.expect(c.get("") == null);
}
