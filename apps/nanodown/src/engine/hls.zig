//! HLS: a master playlist's variants, a media playlist's segments, and a
//! live playlist that keeps growing. Pure parsing; the fetching is
//! `engine/http.zig`'s.
const std = @import("std");

/// One variant a master playlist offers.
pub const Variant = struct {
    /// The media playlist's URL, resolved against the master's.
    url: []const u8 = "",
    /// "1080p", from `RESOLUTION` or `BANDWIDTH`.
    label: []const u8 = "",
    width: u32 = 0,
    height: u32 = 0,
    bandwidth: u32 = 0,
    codecs: []const u8 = "",
};

/// One segment of a media playlist.
pub const Segment = struct {
    url: []const u8 = "",
    /// Seconds.
    duration: f64 = 0,
    /// A byte range within the resource, when the playlist gives one.
    range: ?[2]u64 = null,
};

pub const Playlist = struct {
    /// The variants, when this is a master playlist.
    variants: std.ArrayList(Variant) = .empty,
    /// The segments, when this is a media playlist.
    segments: std.ArrayList(Segment) = .empty,
    /// The encryption key's URL, when the segments are encrypted.
    key: []const u8 = "",
    /// The key's method, as `#EXT-X-KEY` gives it: `AES-128` is one this
    /// engine could decrypt, `SAMPLE-AES` is DRM and is not.
    key_method: []const u8 = "",
    /// A live playlist: it has no `#EXT-X-ENDLIST`.
    live: bool = false,
    /// The target duration, in seconds.
    target: f64 = 0,
    /// The map's URL (`#EXT-X-MAP`): the init segment an fMP4 needs.
    init: []const u8 = "",

    pub fn deinit(p: *Playlist, gpa: std.mem.Allocator) void {
        for (p.variants.items) |v| {
            gpa.free(v.url);
            gpa.free(v.label);
            gpa.free(v.codecs);
        }
        p.variants.deinit(gpa);
        for (p.segments.items) |s| gpa.free(s.url);
        p.segments.deinit(gpa);
        if (p.key.len > 0) gpa.free(p.key);
        if (p.key_method.len > 0) gpa.free(p.key_method);
        gpa.free(p.init);
    }

    pub fn isMaster(p: *const Playlist) bool {
        return p.variants.items.len > 0;
    }

    /// Its segments are MPEG-TS, not fMP4: the file it makes is a `.ts`.
    /// The stream is DRM: its samples are encrypted with a key this engine
    /// has no way to ask for, so nothing it fetches would play.
    pub fn isDrm(p: *const Playlist) bool {
        if (p.key_method.len == 0) return false;
        // `AES-128` with a plain key URL is a stream anyone may decrypt;
        // `SAMPLE-AES` and its `skd://` are a licence server's.
        if (std.mem.eql(u8, p.key_method, "AES-128")) return false;
        if (std.mem.eql(u8, p.key_method, "NONE")) return false;
        return true;
    }

    /// A playlist with an init segment (`#EXT-X-MAP`) is fMP4, and one whose
    /// segments end in `.ts` is not.
    pub fn isTs(p: *const Playlist) bool {
        if (p.init.len > 0) return false;
        for (p.segments.items) |s| {
            const path = if (std.mem.indexOfScalar(u8, s.url, '?')) |q| s.url[0..q] else s.url;
            if (std.mem.endsWith(u8, path, ".ts")) return true;
        }
        return false;
    }

    /// The total of the segments' durations.
    pub fn duration(p: *const Playlist) f64 {
        var t: f64 = 0;
        for (p.segments.items) |s| t += s.duration;
        return t;
    }
};

/// Parses a playlist, resolving its relative URLs against `base`.
pub fn parse(gpa: std.mem.Allocator, base: []const u8, text: []const u8) !Playlist {
    var p: Playlist = .{};
    errdefer p.deinit(gpa);
    p.key = try gpa.dupe(u8, "");
    p.init = try gpa.dupe(u8, "");

    var pending_duration: f64 = 0;
    var pending_range: ?[2]u64 = null;
    var pending_variant: ?Variant = null;
    var saw_end = false;

    var lines = std.mem.splitScalar(u8, text, '\n');
    while (lines.next()) |raw| {
        const line = std.mem.trim(u8, raw, " \t\r");
        if (line.len == 0) continue;
        if (std.mem.startsWith(u8, line, "#EXT-X-STREAM-INF:")) {
            pending_variant = try parseStreamInf(gpa, line["#EXT-X-STREAM-INF:".len..]);
            continue;
        }
        if (std.mem.startsWith(u8, line, "#EXTINF:")) {
            const v = line["#EXTINF:".len..];
            const comma = std.mem.indexOfScalar(u8, v, ',') orelse v.len;
            pending_duration = std.fmt.parseFloat(f64, std.mem.trim(u8, v[0..comma], " ")) catch 0;
            continue;
        }
        if (std.mem.startsWith(u8, line, "#EXT-X-BYTERANGE:")) {
            pending_range = parseByteRange(line["#EXT-X-BYTERANGE:".len..]);
            continue;
        }
        if (std.mem.startsWith(u8, line, "#EXT-X-KEY:")) {
            const attrs = line["#EXT-X-KEY:".len..];
            if (std.mem.indexOf(u8, attrs, "METHOD=")) |at| {
                const rest = attrs[at + "METHOD=".len ..];
                const end_at = std.mem.indexOfScalar(u8, rest, ',') orelse rest.len;
                const val = std.mem.trim(u8, rest[0..end_at], " \"");
                if (p.key_method.len > 0) gpa.free(p.key_method);
                p.key_method = try gpa.dupe(u8, val);
            }
            if (std.mem.indexOf(u8, attrs, "URI=\"")) |at| {
                const rest = attrs[at + 5 ..];
                const close = std.mem.indexOfScalar(u8, rest, '"') orelse rest.len;
                if (p.key.len > 0) gpa.free(p.key);
                const abs = try resolve(gpa, base, rest[0..close]);
                defer gpa.free(abs);
                p.key = try gpa.dupe(u8, abs);
            }
            continue;
        }
        if (std.mem.startsWith(u8, line, "#EXT-X-MAP:")) {
            if (std.mem.indexOf(u8, line, "URI=\"") ) |at| {
                const rest = line[at + 5 ..];
                const close = std.mem.indexOfScalar(u8, rest, '"') orelse rest.len;
                gpa.free(p.init);
                const abs = try resolve(gpa, base, rest[0..close]);
                defer gpa.free(abs);
                p.init = try gpa.dupe(u8, abs);
            }
            continue;
        }
        if (std.mem.startsWith(u8, line, "#EXT-X-TARGETDURATION:")) {
            p.target = std.fmt.parseFloat(f64, line["#EXT-X-TARGETDURATION:".len..]) catch 0;
            continue;
        }
        if (std.mem.eql(u8, line, "#EXT-X-ENDLIST")) {
            saw_end = true;
            continue;
        }
        if (line[0] == '#') continue;

        // A line that isn't a tag is a URL: a variant's or a segment's.
        const url = try resolve(gpa, base, line);
        defer gpa.free(url);
        if (pending_variant) |*v| {
            gpa.free(v.url);
            v.url = try gpa.dupe(u8, url);
            try p.variants.append(gpa, v.*);
            pending_variant = null;
        } else {
            try p.segments.append(gpa, .{
                .url = try gpa.dupe(u8, url),
                .duration = pending_duration,
                .range = pending_range,
            });
            pending_duration = 0;
            pending_range = null;
        }
    }
    if (pending_variant) |v| {
        gpa.free(v.url);
        gpa.free(v.label);
        gpa.free(v.codecs);
    }
    p.live = p.segments.items.len > 0 and !saw_end;
    return p;
}

fn parseStreamInf(gpa: std.mem.Allocator, attrs: []const u8) !Variant {
    var v: Variant = .{ .url = try gpa.dupe(u8, ""), .label = try gpa.dupe(u8, ""), .codecs = try gpa.dupe(u8, "") };
    var it = std.mem.splitScalar(u8, attrs, ',');
    while (it.next()) |pair| {
        const eq = std.mem.indexOfScalar(u8, pair, '=') orelse continue;
        const k = std.mem.trim(u8, pair[0..eq], " ");
        const val = std.mem.trim(u8, pair[eq + 1 ..], " \"");
        if (std.mem.eql(u8, k, "RESOLUTION")) {
            if (std.mem.indexOfScalar(u8, val, 'x')) |x| {
                v.width = std.fmt.parseInt(u32, val[0..x], 10) catch 0;
                v.height = std.fmt.parseInt(u32, val[x + 1 ..], 10) catch 0;
            }
        } else if (std.mem.eql(u8, k, "BANDWIDTH")) {
            v.bandwidth = std.fmt.parseInt(u32, val, 10) catch 0;
        } else if (std.mem.eql(u8, k, "CODECS")) {
            gpa.free(v.codecs);
            v.codecs = try gpa.dupe(u8, val);
        }
    }
    if (v.height > 0) {
        gpa.free(v.label);
        var buf: [16]u8 = undefined;
        v.label = try gpa.dupe(u8, std.fmt.bufPrint(&buf, "{d}p", .{v.height}) catch "");
    } else if (v.bandwidth > 0) {
        gpa.free(v.label);
        var buf: [16]u8 = undefined;
        v.label = try gpa.dupe(u8, std.fmt.bufPrint(&buf, "{d}k", .{v.bandwidth / 1000}) catch "");
    }
    return v;
}

fn parseByteRange(s: []const u8) ?[2]u64 {
    const dash = std.mem.indexOfScalar(u8, s, '@') orelse return null;
    const len = std.fmt.parseInt(u64, std.mem.trim(u8, s[0..dash], " "), 10) catch return null;
    const start = std.fmt.parseInt(u64, std.mem.trim(u8, s[dash + 1 ..], " "), 10) catch return null;
    return .{ start, start + len };
}

/// A relative URL against its base: absolute stays, `/x` takes the origin,
/// `x` replaces the last segment.
pub fn resolve(gpa: std.mem.Allocator, base: []const u8, ref: []const u8) ![]const u8 {
    if (std.mem.startsWith(u8, ref, "http://") or std.mem.startsWith(u8, ref, "https://")) return gpa.dupe(u8, ref);
    const scheme_end = std.mem.indexOf(u8, base, "://") orelse return gpa.dupe(u8, ref);
    const host_start = scheme_end + 3;
    const path_start = std.mem.indexOfScalarPos(u8, base, host_start, '/') orelse base.len;
    const origin = base[0..path_start];
    if (ref.len > 0 and ref[0] == '/') return std.fmt.allocPrint(gpa, "{s}{s}", .{ origin, ref });
    // Relative: up to the last slash of the base's path.
    const slash = std.mem.lastIndexOfScalar(u8, base, '/') orelse return std.fmt.allocPrint(gpa, "{s}/{s}", .{ origin, ref });
    if (slash < host_start) return std.fmt.allocPrint(gpa, "{s}/{s}", .{ origin, ref });
    return std.fmt.allocPrint(gpa, "{s}/{s}", .{ base[0..slash], ref });
}

test "a master playlist's variants" {
    const text =
        \\#EXTM3U
        \\#EXT-X-STREAM-INF:BANDWIDTH=5000000,RESOLUTION=1920x1080,CODECS="avc1.640028,mp4a.40.2"
        \\1080/index.m3u8
        \\#EXT-X-STREAM-INF:BANDWIDTH=2500000,RESOLUTION=1280x720
        \\720/index.m3u8
    ;
    var p = try parse(std.testing.allocator, "https://cdn.example.com/hls/master.m3u8", text);
    defer p.deinit(std.testing.allocator);
    try std.testing.expect(p.isMaster());
    try std.testing.expectEqual(@as(usize, 2), p.variants.items.len);
    try std.testing.expectEqualStrings("1080p", p.variants.items[0].label);
    try std.testing.expectEqual(@as(u32, 1080), p.variants.items[0].height);
    try std.testing.expectEqualStrings("https://cdn.example.com/hls/1080/index.m3u8", p.variants.items[0].url);
}

test "a media playlist's segments and duration" {
    const text =
        \\#EXTM3U
        \\#EXT-X-TARGETDURATION:6
        \\#EXTINF:6.0,
        \\seg0.ts
        \\#EXTINF:6.0,
        \\seg1.ts
        \\#EXTINF:4.5,
        \\seg2.ts
        \\#EXT-X-ENDLIST
    ;
    var p = try parse(std.testing.allocator, "https://cdn.example.com/a/b.m3u8", text);
    defer p.deinit(std.testing.allocator);
    try std.testing.expect(!p.isMaster());
    try std.testing.expectEqual(@as(usize, 3), p.segments.items.len);
    try std.testing.expectApproxEqAbs(@as(f64, 16.5), p.duration(), 0.01);
    try std.testing.expectEqualStrings("https://cdn.example.com/a/seg0.ts", p.segments.items[0].url);
    try std.testing.expect(!p.live);
}

test "a playlist without an endlist is live" {
    const text =
        \\#EXTM3U
        \\#EXTINF:6.0,
        \\a.ts
    ;
    var p = try parse(std.testing.allocator, "https://x.com/l.m3u8", text);
    defer p.deinit(std.testing.allocator);
    try std.testing.expect(p.live);
}

test "a byte range is read" {
    const text =
        \\#EXTM3U
        \\#EXT-X-BYTERANGE:1000@2000
        \\#EXTINF:6.0,
        \\all.ts
        \\#EXT-X-ENDLIST
    ;
    var p = try parse(std.testing.allocator, "https://x.com/l.m3u8", text);
    defer p.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(u64, 2000), p.segments.items[0].range.?[0]);
    try std.testing.expectEqual(@as(u64, 3000), p.segments.items[0].range.?[1]);
}

test "a key and an init map are resolved" {
    const text =
        \\#EXTM3U
        \\#EXT-X-KEY:METHOD=AES-128,URI="key.bin"
        \\#EXT-X-MAP:URI="init.mp4"
        \\#EXTINF:6.0,
        \\s.mp4
        \\#EXT-X-ENDLIST
    ;
    var p = try parse(std.testing.allocator, "https://x.com/a/l.m3u8", text);
    defer p.deinit(std.testing.allocator);
    try std.testing.expectEqualStrings("https://x.com/a/key.bin", p.key);
    try std.testing.expectEqualStrings("https://x.com/a/init.mp4", p.init);
}

test "relative URLs resolve three ways" {
    const gpa = std.testing.allocator;
    const a = try resolve(gpa, "https://x.com/a/b/c.m3u8", "d.ts");
    defer gpa.free(a);
    try std.testing.expectEqualStrings("https://x.com/a/b/d.ts", a);
    const b = try resolve(gpa, "https://x.com/a/b/c.m3u8", "/root.ts");
    defer gpa.free(b);
    try std.testing.expectEqualStrings("https://x.com/root.ts", b);
    const c = try resolve(gpa, "https://x.com/a/b/c.m3u8", "https://y.com/z.ts");
    defer gpa.free(c);
    try std.testing.expectEqualStrings("https://y.com/z.ts", c);
}

test "a DRM stream is told from a plain one" {
    const gpa = std.testing.allocator;
    // Vimeo's shape: the master has no key, the media playlist under it does.
    const drm =
        \\#EXTM3U
        \\#EXT-X-KEY:METHOD=SAMPLE-AES,URI="skd://drm",KEYFORMAT="com.apple.streamingkeydelivery"
        \\#EXT-X-MAP:URI="init.mp4"
        \\#EXTINF:6.0,
        \\s.m4s
        \\#EXT-X-ENDLIST
    ;
    var p = try parse(gpa, "https://x.com/a/l.m3u8", drm);
    defer p.deinit(gpa);
    try std.testing.expectEqualStrings("SAMPLE-AES", p.key_method);
    try std.testing.expect(p.isDrm());

    // AES-128 with a plain key URL is a stream anyone may decrypt.
    const plain =
        \\#EXTM3U
        \\#EXT-X-KEY:METHOD=AES-128,URI="key.bin"
        \\#EXTINF:6.0,
        \\s.ts
        \\#EXT-X-ENDLIST
    ;
    var q = try parse(gpa, "https://x.com/a/l.m3u8", plain);
    defer q.deinit(gpa);
    try std.testing.expectEqualStrings("AES-128", q.key_method);
    try std.testing.expect(!q.isDrm());

    const none =
        \\#EXTM3U
        \\#EXTINF:6.0,
        \\s.ts
        \\#EXT-X-ENDLIST
    ;
    var r = try parse(gpa, "https://x.com/a/l.m3u8", none);
    defer r.deinit(gpa);
    try std.testing.expect(!r.isDrm());
}
