//! The library: every download the app has made or is making, and the
//! filter and search over it. Persisted as JSON beside the settings.
const std = @import("std");
const download = @import("download.zig");
const media = @import("media.zig");

pub const Download = download.Download;

/// The tabs above the list.
pub const Filter = enum {
    all,
    videos,
    audio,
    failed,
    subscriptions,

    pub fn title(f: Filter) []const u8 {
        return switch (f) {
            .all => "All",
            .videos => "Videos",
            .audio => "Audio",
            .failed => "Failed",
            .subscriptions => "Subscriptions",
        };
    }

    /// The tab `⌘1`–`⌘4` picks.
    pub fn ofIndex(i: usize) Filter {
        return switch (i) {
            0 => .all,
            1 => .videos,
            2 => .audio,
            3 => .failed,
            else => .subscriptions,
        };
    }
};

pub const Library = struct {
    gpa: std.mem.Allocator,
    items: std.ArrayList(Download) = .empty,
    next_id: u64 = 1,
    /// What the field's text filters by, when it isn't a link.
    query: []const u8 = "",
    filter: Filter = .all,
    /// The row the user picked.
    selected: ?usize = null,

    pub fn init(gpa: std.mem.Allocator) Library {
        return .{ .gpa = gpa };
    }

    pub fn deinit(l: *Library) void {
        for (l.items.items) |d| {
            l.gpa.free(d.url);
            l.gpa.free(d.media);
            l.gpa.free(d.title);
            l.gpa.free(d.author);
            l.gpa.free(d.quality);
            l.gpa.free(d.ext);
            l.gpa.free(d.path);
            l.gpa.free(d.thumb);
            l.gpa.free(d.date);
            l.gpa.free(d.problem);
            l.gpa.free(d.stage);
        }
        l.items.deinit(l.gpa);
    }

    /// Adds a download, taking copies of its strings.
    pub fn add(l: *Library, d: Download) !*Download {
        var copy = d;
        copy.id = l.next_id;
        l.next_id += 1;
        copy.url = try l.gpa.dupe(u8, d.url);
        copy.media = try l.gpa.dupe(u8, d.media);
        copy.title = try l.gpa.dupe(u8, d.title);
        copy.author = try l.gpa.dupe(u8, d.author);
        copy.quality = try l.gpa.dupe(u8, d.quality);
        copy.ext = try l.gpa.dupe(u8, d.ext);
        copy.path = try l.gpa.dupe(u8, d.path);
        copy.thumb = try l.gpa.dupe(u8, d.thumb);
        copy.date = try l.gpa.dupe(u8, d.date);
        copy.problem = try l.gpa.dupe(u8, d.problem);
        copy.stage = try l.gpa.dupe(u8, d.stage);
        copy.gpa = l.gpa;
        try l.items.append(l.gpa, copy);
        return &l.items.items[l.items.items.len - 1];
    }

    /// The download with this id.
    pub fn byId(l: *Library, id: u64) ?*Download {
        for (l.items.items) |*d| if (d.id == id) return d;
        return null;
    }

    /// The download whose source page is `url`, when there is one.
    pub fn byUrl(l: *Library, url: []const u8) ?*Download {
        for (l.items.items) |*d| if (std.mem.eql(u8, d.url, url)) return d;
        return null;
    }

    /// Takes one off the list; the file stays.
    pub fn remove(l: *Library, id: u64) void {
        for (l.items.items, 0..) |d, i| if (d.id == id) {
            l.gpa.free(d.url);
            l.gpa.free(d.media);
            l.gpa.free(d.title);
            l.gpa.free(d.author);
            l.gpa.free(d.quality);
            l.gpa.free(d.ext);
            l.gpa.free(d.path);
            l.gpa.free(d.thumb);
            l.gpa.free(d.date);
            l.gpa.free(d.problem);
            l.gpa.free(d.stage);
            _ = l.items.orderedRemove(i);
            if (l.selected) |s| {
                if (s == i) l.selected = null else if (s > i) l.selected = s - 1;
            }
            return;
        };
    }

    /// Empties the list of finished downloads; the files stay.
    pub fn clearFinished(l: *Library) usize {
        var n: usize = 0;
        var i: usize = 0;
        while (i < l.items.items.len) {
            if (l.items.items[i].state.finished()) {
                const id = l.items.items[i].id;
                l.remove(id);
                n += 1;
                continue;
            }
            i += 1;
        }
        l.selected = null;
        return n;
    }

    /// Whether a download passes the filter and the query.
    pub fn passes(l: *const Library, d: *const Download) bool {
        const by_tab = switch (l.filter) {
            .all => true,
            .videos => std.mem.eql(u8, d.quality, "Audio") == false and d.state != .failed,
            .audio => std.mem.eql(u8, d.quality, "Audio"),
            .failed => d.state == .failed,
            .subscriptions => false, // that tab lists subscriptions, not downloads
        };
        if (!by_tab) return false;
        if (l.query.len == 0) return true;
        return containsIgnoreCase(d.title, l.query) or containsIgnoreCase(d.author, l.query);
    }

    /// The rows to draw, in order: what is downloading, then the rest.
    pub fn rows(l: *const Library, out: []usize) []usize {
        var n: usize = 0;
        // In flight first, in queue order.
        for (l.items.items, 0..) |*d, i| {
            if (!d.inFlight() or !l.passes(d)) continue;
            if (n == out.len) break;
            out[n] = i;
            n += 1;
        }
        // Then what finished, newest first.
        var i = l.items.items.len;
        while (i > 0) {
            i -= 1;
            const d = &l.items.items[i];
            if (d.inFlight() or !l.passes(d)) continue;
            if (n == out.len) break;
            out[n] = i;
            n += 1;
        }
        return out[0..n];
    }

    /// How many downloads are running.
    pub fn running(l: *const Library) usize {
        var n: usize = 0;
        for (l.items.items) |*d| if (d.state.active()) {
            n += 1;
        };
        return n;
    }

    /// How many are waiting for a slot.
    pub fn queued(l: *const Library) usize {
        var n: usize = 0;
        for (l.items.items) |*d| if (d.state == .queued) {
            n += 1;
        };
        return n;
    }

    /// The first queued download, for the queue to start.
    pub fn nextQueued(l: *Library) ?*Download {
        for (l.items.items) |*d| if (d.state == .queued) return d;
        return null;
    }

    /// Moves a download to the front of the queue.
    pub fn moveNext(l: *Library, id: u64) void {
        for (l.items.items, 0..) |d, i| if (d.id == id) {
            if (i == 0) return;
            const it = l.items.orderedRemove(i);
            l.items.insert(l.gpa, 0, it) catch {};
            return;
        };
    }

    /// Pauses everything running.
    pub fn pauseAll(l: *Library) void {
        for (l.items.items) |*d| if (d.state == .running or d.state == .probing) {
            d.state = .paused;
        };
    }

    /// Resumes everything paused.
    pub fn resumeAll(l: *Library) void {
        for (l.items.items) |*d| if (d.state == .paused or d.state == .stopped) {
            d.state = .queued;
        };
    }

    /// The library as JSON, for `library.json`.
    pub fn toJson(l: *const Library, gpa: std.mem.Allocator) ![]u8 {
        var out: std.Io.Writer.Allocating = .init(gpa);
        errdefer out.deinit();
        const w = &out.writer;
        try w.writeAll("{\"next_id\":");
        try w.print("{d}", .{l.next_id});
        try w.writeAll(",\"items\":[");
        for (l.items.items, 0..) |d, i| {
            if (i > 0) try w.writeAll(",");
            try w.writeAll("{\"id\":");
            try w.print("{d}", .{d.id});
            try w.writeAll(",\"url\":");
            try jsonString(w, d.url);
            try w.writeAll(",\"media\":");
            try jsonString(w, d.media);
            try w.writeAll(",\"title\":");
            try jsonString(w, d.title);
            try w.writeAll(",\"site\":");
            try jsonString(w, @tagName(d.site));
            try w.writeAll(",\"author\":");
            try jsonString(w, d.author);
            try w.writeAll(",\"quality\":");
            try jsonString(w, d.quality);
            try w.writeAll(",\"ext\":");
            try jsonString(w, d.ext);
            try w.writeAll(",\"path\":");
            try jsonString(w, d.path);
            try w.writeAll(",\"thumb\":");
            try jsonString(w, d.thumb);
            try w.print(",\"duration\":{d}", .{d.duration});
            try w.writeAll(",\"date\":");
            try jsonString(w, d.date);
            try w.writeAll(",\"state\":");
            try jsonString(w, @tagName(d.state));
            try w.print(",\"done_bytes\":{d},\"total_bytes\":{d},\"segs_done\":{d},\"segs_total\":{d}", .{ d.done_bytes, d.total_bytes, d.segs_done, d.segs_total });
            try w.print(",\"finished_at\":{d}", .{d.finished_at});
            try w.writeAll(",\"live\":");
            try w.writeAll(if (d.live) "true" else "false");
            // Why it failed is the only thing that makes a failed row useful
            // after a restart, so it is written with the rest.
            try w.writeAll(",\"problem\":");
            try jsonString(w, d.problem);
            try w.writeAll("}");
        }
        try w.writeAll("]}");
        return out.toOwnedSlice();
    }

    /// Reads `library.json` back. A malformed file leaves an empty library
    /// rather than failing the launch.
    pub fn fromJson(l: *Library, text: []const u8) !void {
        // A file that will not parse is an error, not an empty library.
        // Swallowed here, it read as "nothing saved yet", and the next save
        // wrote the empty one over the file: a truncated write lost every
        // download in it.
        var parsed = try std.json.parseFromSlice(std.json.Value, l.gpa, text, .{});
        defer parsed.deinit();
        const root = parsed.value;
        if (root != .object) return;
        if (root.object.get("next_id")) |v| {
            if (v == .integer) l.next_id = @intCast(@max(1, v.integer));
        }
        const items = root.object.get("items") orelse return;
        if (items != .array) return;
        for (items.array.items) |it| {
            if (it != .object) continue;
            const o = it.object;
            var d: Download = .{ .gpa = l.gpa };
            d.url = try l.gpa.dupe(u8, str(o.get("url")));
            d.media = try l.gpa.dupe(u8, str(o.get("media")));
            d.title = try l.gpa.dupe(u8, str(o.get("title")));
            d.site = siteOf(str(o.get("site")));
            d.author = try l.gpa.dupe(u8, str(o.get("author")));
            d.quality = try l.gpa.dupe(u8, str(o.get("quality")));
            d.ext = try l.gpa.dupe(u8, str(o.get("ext")));
            d.path = try l.gpa.dupe(u8, str(o.get("path")));
            d.thumb = try l.gpa.dupe(u8, str(o.get("thumb")));
            d.date = try l.gpa.dupe(u8, str(o.get("date")));
            d.problem = try l.gpa.dupe(u8, str(o.get("problem")));
            d.stage = try l.gpa.dupe(u8, "");
            if (o.get("duration")) |v| {
                if (v == .float) d.duration = v.float;
                if (v == .integer) d.duration = @floatFromInt(v.integer);
            }
            d.state = stateOf(str(o.get("state")));
            if (o.get("done_bytes")) |v| {
                if (v == .integer) d.done_bytes = @intCast(@max(0, v.integer));
            }
            if (o.get("total_bytes")) |v| {
                if (v == .integer) d.total_bytes = @intCast(@max(0, v.integer));
            }
            if (o.get("segs_done")) |v| {
                if (v == .integer) d.segs_done = @intCast(@max(0, v.integer));
            }
            if (o.get("segs_total")) |v| {
                if (v == .integer) d.segs_total = @intCast(@max(0, v.integer));
            }
            if (o.get("finished_at")) |v| {
                if (v == .integer) d.finished_at = @intCast(v.integer);
            }
            if (o.get("live")) |v| d.live = v == .bool and v.bool;
            const id = if (o.get("id")) |v| (if (v == .integer) @as(u64, @intCast(v.integer)) else 0) else 0;
            try l.items.append(l.gpa, d);
            if (id != 0) {
                l.items.items[l.items.items.len - 1].id = id;
                if (id >= l.next_id) l.next_id = id + 1;
            } else {
                l.items.items[l.items.items.len - 1].id = l.next_id;
                l.next_id += 1;
            }
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

fn stateOf(name: []const u8) download.State {
    const info = @typeInfo(download.State).@"enum";
    inline for (info.field_names, info.field_values) |fname, fvalue| {
        if (std.mem.eql(u8, name, fname)) return @enumFromInt(fvalue);
    }
    return .queued;
}

fn jsonString(w: anytype, s: []const u8) !void {
    try w.writeByte('"');
    for (s) |ch| switch (ch) {
        '"' => try w.writeAll("\\\""),
        '\\' => try w.writeAll("\\\\"),
        '\n' => try w.writeAll("\\n"),
        '\r' => try w.writeAll("\\r"),
        '\t' => try w.writeAll("\\t"),
        else => {
            if (ch < 0x20) try w.print("\\u{x:0>4}", .{ch}) else try w.writeByte(ch);
        },
    };
    try w.writeByte('"');
}

fn containsIgnoreCase(hay: []const u8, needle: []const u8) bool {
    if (needle.len == 0) return true;
    if (needle.len > hay.len) return false;
    var i: usize = 0;
    while (i + needle.len <= hay.len) : (i += 1) {
        if (std.ascii.eqlIgnoreCase(hay[i .. i + needle.len], needle)) return true;
    }
    return false;
}

test "a download is added with its own id" {
    var l = Library.init(std.testing.allocator);
    defer l.deinit();
    const a = try l.add(.{ .gpa = std.testing.allocator, .url = "https://a", .title = "A" });
    const b = try l.add(.{ .gpa = std.testing.allocator, .url = "https://b", .title = "B" });
    try std.testing.expectEqual(@as(u64, 1), a.id);
    try std.testing.expectEqual(@as(u64, 2), b.id);
    try std.testing.expectEqualStrings("A", l.byId(1).?.title);
}

test "the filter picks the tab" {
    var l = Library.init(std.testing.allocator);
    defer l.deinit();
    _ = try l.add(.{ .gpa = std.testing.allocator, .url = "a", .title = "Video one", .quality = "1080p" });
    _ = try l.add(.{ .gpa = std.testing.allocator, .url = "b", .title = "Song", .quality = "Audio" });
    l.filter = .videos;
    var out: [8]usize = undefined;
    try std.testing.expectEqual(@as(usize, 1), l.rows(&out).len);
    l.filter = .audio;
    try std.testing.expectEqual(@as(usize, 1), l.rows(&out).len);
    l.filter = .all;
    try std.testing.expectEqual(@as(usize, 2), l.rows(&out).len);
}

test "the query searches titles and authors" {
    var l = Library.init(std.testing.allocator);
    defer l.deinit();
    _ = try l.add(.{ .gpa = std.testing.allocator, .url = "a", .title = "Big Buck Bunny", .author = "Blender" });
    l.query = "bunny";
    var out: [8]usize = undefined;
    try std.testing.expectEqual(@as(usize, 1), l.rows(&out).len);
    l.query = "blender";
    try std.testing.expectEqual(@as(usize, 1), l.rows(&out).len);
    l.query = "nothing";
    try std.testing.expectEqual(@as(usize, 0), l.rows(&out).len);
}

test "the library round-trips through JSON" {
    var l = Library.init(std.testing.allocator);
    defer l.deinit();
    _ = try l.add(.{ .gpa = std.testing.allocator, .url = "https://vimeo.com/1", .title = "A \"quoted\" title", .site = .vimeo, .quality = "1080p", .total_bytes = 100, .done_bytes = 40 });
    const json = try l.toJson(std.testing.allocator);
    defer std.testing.allocator.free(json);

    var back = Library.init(std.testing.allocator);
    defer back.deinit();
    try back.fromJson(json);
    try std.testing.expectEqual(@as(usize, 1), back.items.items.len);
    try std.testing.expectEqualStrings("A \"quoted\" title", back.items.items[0].title);
    try std.testing.expectEqual(media.Site.vimeo, back.items.items[0].site);
    try std.testing.expectEqual(@as(u64, 100), back.items.items[0].total_bytes);
}

test "clearing finished leaves the running ones" {
    var l = Library.init(std.testing.allocator);
    defer l.deinit();
    _ = try l.add(.{ .gpa = std.testing.allocator, .url = "a", .title = "A", .state = .done });
    _ = try l.add(.{ .gpa = std.testing.allocator, .url = "b", .title = "B", .state = .running });
    try std.testing.expectEqual(@as(usize, 1), l.clearFinished());
    try std.testing.expectEqual(@as(usize, 1), l.items.items.len);
    try std.testing.expectEqualStrings("B", l.items.items[0].title);
}

test "a failure's reason survives a save and a load" {
    const gpa = std.testing.allocator;
    var lib = Library.init(gpa);
    defer lib.deinit();
    const d = try lib.add(.{
        .gpa = gpa,
        .url = "https://x.com/a",
        .title = "A",
        .site = .vimeo,
        .author = "someone",
        .quality = "1080p",
        .ext = "mp4",
        .path = "/tmp/a.mp4",
        .date = "2026-11-13",
        .state = .failed,
        .problem = "this stream is DRM-protected",
    });
    _ = d;
    const text = try lib.toJson(gpa);
    defer gpa.free(text);
    var back = Library.init(gpa);
    defer back.deinit();
    try back.fromJson(text);
    try std.testing.expectEqual(@as(usize, 1), back.items.items.len);
    // Without this the row says "Failed" and nothing else after a restart.
    try std.testing.expectEqualStrings("this stream is DRM-protected", back.items.items[0].problem);
}
