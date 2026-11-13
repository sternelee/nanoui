//! DASH: an MPD's periods, adaptation sets and representations, and the
//! segment template or list that says where each chunk lives. Pure parsing.
const std = @import("std");

/// One representation: a video or audio track at one quality.
pub const Representation = struct {
    id: []const u8 = "",
    /// "1080p" or "Audio".
    label: []const u8 = "",
    kind: Kind = .video,
    width: u32 = 0,
    height: u32 = 0,
    bandwidth: u32 = 0,
    codecs: []const u8 = "",
    mime: []const u8 = "",
    /// The init segment (`<Initialization>`), when the MPD names one.
    init: []const u8 = "",
    /// Where the media is: a template, or an explicit list.
    segments: std.ArrayList(Segment) = .empty,
    /// `SegmentTemplate`'s pattern, when it has one.
    template: []const u8 = "",
    /// The number the template's `$Number$` starts at.
    start_number: u64 = 1,
    /// The `timescale` the durations are in.
    timescale: u64 = 1,
    /// One segment's duration in the timescale's units.
    duration: u64 = 0,
    /// How many segments.
    count: u64 = 0,

    pub const Kind = enum { video, audio };

    pub fn deinit(r: *Representation, gpa: std.mem.Allocator) void {
        gpa.free(r.id);
        gpa.free(r.label);
        gpa.free(r.codecs);
        gpa.free(r.mime);
        gpa.free(r.init);
        gpa.free(r.template);
        for (r.segments.items) |s| gpa.free(s.url);
        r.segments.deinit(gpa);
    }

    /// Seconds of media.
    pub fn seconds(r: *const Representation) f64 {
        if (r.timescale == 0) return 0;
        return @as(f64, @floatFromInt(r.duration * r.count)) / @as(f64, @floatFromInt(r.timescale));
    }

    /// The URL of segment `i` (0-based), expanding the template.
    pub fn segmentUrl(r: *const Representation, gpa: std.mem.Allocator, i: u64) ![]const u8 {
        if (r.segments.items.len > 0) {
            if (i < r.segments.items.len) return gpa.dupe(u8, r.segments.items[i].url);
            return gpa.dupe(u8, "");
        }
        if (r.template.len == 0) return gpa.dupe(u8, "");
        const number = r.start_number + i;
        const time = number * r.duration;
        var out: std.Io.Writer.Allocating = .init(gpa);
        errdefer out.deinit();
        const w = &out.writer;
        var at: usize = 0;
        while (at < r.template.len) {
            const dollar = std.mem.indexOfScalarPos(u8, r.template, at, '$') orelse {
                try w.writeAll(r.template[at..]);
                break;
            };
            try w.writeAll(r.template[at..dollar]);
            const close = std.mem.indexOfScalarPos(u8, r.template, dollar + 1, '$') orelse {
                try w.writeAll(r.template[dollar..]);
                break;
            };
            const token = r.template[dollar + 1 .. close];
            if (std.mem.eql(u8, token, "Number")) {
                try w.print("{d}", .{number});
            } else if (std.mem.eql(u8, token, "Time")) {
                try w.print("{d}", .{time});
            } else if (std.mem.eql(u8, token, "RepresentationID")) {
                try w.writeAll(r.id);
            } else if (std.mem.eql(u8, token, "Bandwidth")) {
                try w.print("{d}", .{r.bandwidth});
            } else {
                // An unknown token is left as it was.
                try w.writeAll(r.template[dollar .. close + 1]);
            }
            at = close + 1;
        }
        return out.toOwnedSlice();
    }
};

pub const Segment = struct {
    url: []const u8 = "",
    duration: f64 = 0,
};

pub const Manifest = struct {
    /// The whole thing, in seconds.
    duration: f64 = 0,
    /// Video first, best first, then audio.
    reps: std.ArrayList(Representation) = .empty,

    pub fn deinit(m: *Manifest, gpa: std.mem.Allocator) void {
        for (m.reps.items) |*r| r.deinit(gpa);
        m.reps.deinit(gpa);
    }

    /// The best video at or under `max_height`, and the best audio.
    pub fn pick(m: *const Manifest, max_height: u32) struct { video: ?usize, audio: ?usize } {
        var v: ?usize = null;
        var a: ?usize = null;
        for (m.reps.items, 0..) |r, i| {
            switch (r.kind) {
                .video => {
                    if (max_height > 0 and r.height > max_height) continue;
                    if (v == null or r.height > m.reps.items[v.?].height) v = i;
                },
                .audio => {
                    if (a == null or r.bandwidth > m.reps.items[a.?].bandwidth) a = i;
                },
            }
        }
        return .{ .video = v, .audio = a };
    }
};

/// Parses an MPD. `base` resolves the relative URLs it holds.
pub fn parse(gpa: std.mem.Allocator, base: []const u8, xml: []const u8) !Manifest {
    var m: Manifest = .{};
    errdefer m.deinit(gpa);

    if (attr(xml, "mediaPresentationDuration")) |d| m.duration = isoSeconds(d);

    // Each `<AdaptationSet>` holds representations of one kind.
    var sets = std.mem.splitSequence(u8, xml, "<AdaptationSet");
    _ = sets.next(); // before the first set
    while (sets.next()) |set| {
        const set_kind: Representation.Kind = if (std.mem.indexOf(u8, set, "audio") != null and std.mem.indexOf(u8, set, "video") == null) .audio else .video;
        const set_template = blockAttr(set, "SegmentTemplate", "media");
        const set_timescale = blockAttr(set, "SegmentTemplate", "timescale");
        const set_duration = blockAttr(set, "SegmentTemplate", "duration");
        const set_start = blockAttr(set, "SegmentTemplate", "startNumber");
        const set_init = blockAttr(set, "SegmentTemplate", "initialization");
        const set_base = blockAttr(set, "BaseURL", null);

        var reps = std.mem.splitSequence(u8, set, "<Representation");
        _ = reps.next();
        while (reps.next()) |rep| {
            var r: Representation = .{
                .id = try gpa.dupe(u8, attr(rep, "id") orelse ""),
                .label = try gpa.dupe(u8, ""),
                .codecs = try gpa.dupe(u8, attr(rep, "codecs") orelse ""),
                .mime = try gpa.dupe(u8, attr(rep, "mimeType") orelse ""),
                .init = try gpa.dupe(u8, ""),
                .template = try gpa.dupe(u8, ""),
                .kind = set_kind,
            };
            if (attr(rep, "width")) |w| r.width = std.fmt.parseInt(u32, w, 10) catch 0;
            if (attr(rep, "height")) |h| r.height = std.fmt.parseInt(u32, h, 10) catch 0;
            if (attr(rep, "bandwidth")) |b| r.bandwidth = std.fmt.parseInt(u32, b, 10) catch 0;
            if (std.mem.indexOf(u8, r.mime, "audio") != null) r.kind = .audio;

            // The representation's own template wins over the set's.
            const tmpl = blockAttr(rep, "SegmentTemplate", "media") orelse set_template;
            const ts = blockAttr(rep, "SegmentTemplate", "timescale") orelse set_timescale;
            const dur = blockAttr(rep, "SegmentTemplate", "duration") orelse set_duration;
            const start = blockAttr(rep, "SegmentTemplate", "startNumber") orelse set_start;
            const init_ref = blockAttr(rep, "SegmentTemplate", "initialization") orelse set_init;
            const rep_base = blockAttr(rep, "BaseURL", null) orelse set_base;

            if (ts) |v| r.timescale = std.fmt.parseInt(u64, v, 10) catch 1;
            if (dur) |v| r.duration = std.fmt.parseInt(u64, v, 10) catch 0;
            if (start) |v| r.start_number = std.fmt.parseInt(u64, v, 10) catch 1;
            if (tmpl) |v| {
                gpa.free(r.template);
                r.template = try gpa.dupe(u8, v);
            }
            if (init_ref) |v| {
                gpa.free(r.init);
                const abs = try expand(gpa, v, &r);
                defer gpa.free(abs);
                r.init = try gpa.dupe(u8, abs);
            } else if (rep_base) |v| {
                gpa.free(r.init);
                const abs = try join(gpa, base, v);
                defer gpa.free(abs);
                r.init = try gpa.dupe(u8, abs);
            }
            // How many segments: the period's duration over one's.
            if (r.duration > 0 and r.timescale > 0 and m.duration > 0) {
                const per = @as(f64, @floatFromInt(r.duration)) / @as(f64, @floatFromInt(r.timescale));
                r.count = @intFromFloat(@ceil(m.duration / per));
            }

            // A `<SegmentList>` names each one.
            if (std.mem.indexOf(u8, rep, "<SegmentList") != null) {
                var urls = std.mem.splitSequence(u8, rep, "<SegmentURL");
                _ = urls.next();
                while (urls.next()) |su| {
                    const media = attr(su, "media") orelse continue;
                    try r.segments.append(gpa, .{ .url = try join(gpa, base, media) });
                }
            }

            if (r.height > 0) {
                gpa.free(r.label);
                var buf: [16]u8 = undefined;
                r.label = try gpa.dupe(u8, std.fmt.bufPrint(&buf, "{d}p", .{r.height}) catch "");
            } else if (r.kind == .audio) {
                gpa.free(r.label);
                r.label = try gpa.dupe(u8, "Audio");
            }
            try m.reps.append(gpa, r);
        }
    }
    // Best video first, then audio by bandwidth.
    std.mem.sort(Representation, m.reps.items, {}, better);
    return m;
}

fn better(_: void, a: Representation, b: Representation) bool {
    if (a.kind != b.kind) return a.kind == .video;
    if (a.kind == .video) return a.height > b.height;
    return a.bandwidth > b.bandwidth;
}

/// The value of `name="..."` in a tag's own text.
fn attr(tag: []const u8, name: []const u8) ?[]const u8 {
    var buf: [64]u8 = undefined;
    const needle = std.fmt.bufPrint(&buf, "{s}=\"", .{name}) catch return null;
    const at = std.mem.indexOf(u8, tag, needle) orelse return null;
    const from = at + needle.len;
    const close = std.mem.indexOfScalarPos(u8, tag, from, '"') orelse return null;
    return tag[from..close];
}

/// The value of `name` inside the first `<block ...>` of `text`.
fn blockAttr(text: []const u8, block: []const u8, name: ?[]const u8) ?[]const u8 {
    var buf: [64]u8 = undefined;
    const open = std.fmt.bufPrint(&buf, "<{s}", .{block}) catch return null;
    const at = std.mem.indexOf(u8, text, open) orelse return null;
    const close = std.mem.indexOfScalarPos(u8, text, at, '>') orelse return null;
    const tag = text[at..close];
    return if (name) |n| attr(tag, n) else attr(tag, "BaseURL");
}

/// Expands `$Number$` and friends in an initialization pattern.
fn expand(gpa: std.mem.Allocator, pattern: []const u8, r: *const Representation) ![]const u8 {
    var out: std.Io.Writer.Allocating = .init(gpa);
    errdefer out.deinit();
    const w = &out.writer;
    var at: usize = 0;
    while (at < pattern.len) {
        const dollar = std.mem.indexOfScalarPos(u8, pattern, at, '$') orelse {
            try w.writeAll(pattern[at..]);
            break;
        };
        try w.writeAll(pattern[at..dollar]);
        const close = std.mem.indexOfScalarPos(u8, pattern, dollar + 1, '$') orelse {
            try w.writeAll(pattern[dollar..]);
            break;
        };
        const token = pattern[dollar + 1 .. close];
        if (std.mem.eql(u8, token, "RepresentationID")) {
            try w.writeAll(r.id);
        } else if (std.mem.eql(u8, token, "Bandwidth")) {
            try w.print("{d}", .{r.bandwidth});
        } else {
            try w.writeAll(pattern[dollar .. close + 1]);
        }
        at = close + 1;
    }
    return out.toOwnedSlice();
}

fn join(gpa: std.mem.Allocator, base: []const u8, ref: []const u8) ![]const u8 {
    if (std.mem.startsWith(u8, ref, "http://") or std.mem.startsWith(u8, ref, "https://")) return gpa.dupe(u8, ref);
    if (ref.len > 0 and ref[0] == '/') {
        const scheme_end = std.mem.indexOf(u8, base, "://") orelse return gpa.dupe(u8, ref);
        const path_start = std.mem.indexOfScalarPos(u8, base, scheme_end + 3, '/') orelse base.len;
        return std.fmt.allocPrint(gpa, "{s}{s}", .{ base[0..path_start], ref });
    }
    const slash = std.mem.lastIndexOfScalar(u8, base, '/') orelse return gpa.dupe(u8, ref);
    return std.fmt.allocPrint(gpa, "{s}/{s}", .{ base[0..slash], ref });
}

/// `PT1H2M3.5S` as seconds.
pub fn isoSeconds(s: []const u8) f64 {
    var t: f64 = 0;
    var num: f64 = 0;
    var seen_dot = false;
    var frac: f64 = 0.1;
    for (s) |ch| {
        switch (ch) {
            '0'...'9' => {
                if (seen_dot) {
                    num += @as(f64, @floatFromInt(ch - '0')) * frac;
                    frac /= 10;
                } else num = num * 10 + @as(f64, @floatFromInt(ch - '0'));
            },
            '.' => seen_dot = true,
            'H' => {
                t += num * 3600;
                num = 0;
                seen_dot = false;
                frac = 0.1;
            },
            'M' => {
                t += num * 60;
                num = 0;
                seen_dot = false;
                frac = 0.1;
            },
            'S' => {
                t += num;
                num = 0;
                seen_dot = false;
                frac = 0.1;
            },
            else => {},
        }
    }
    return t;
}

test "an MPD's representations are read and ordered" {
    const xml =
        \\<?xml version="1.0"?>
        \\<MPD mediaPresentationDuration="PT1M30S">
        \\  <Period>
        \\    <AdaptationSet mimeType="video/mp4">
        \\      <SegmentTemplate media="v/$RepresentationID$/$Number$.m4s" initialization="v/$RepresentationID$/init.mp4" timescale="1000" duration="4000" startNumber="1"/>
        \\      <Representation id="v720" width="1280" height="720" bandwidth="2000000" codecs="avc1.4d401f"/>
        \\      <Representation id="v1080" width="1920" height="1080" bandwidth="5000000" codecs="avc1.640028"/>
        \\    </AdaptationSet>
        \\    <AdaptationSet mimeType="audio/mp4">
        \\      <SegmentTemplate media="a/$RepresentationID$/$Number$.m4s" timescale="1000" duration="4000"/>
        \\      <Representation id="a1" bandwidth="128000" codecs="mp4a.40.2"/>
        \\    </AdaptationSet>
        \\  </Period>
        \\</MPD>
    ;
    var m = try parse(std.testing.allocator, "https://cdn.example.com/movie/manifest.mpd", xml);
    defer m.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 3), m.reps.items.len);
    try std.testing.expectEqualStrings("1080p", m.reps.items[0].label);
    try std.testing.expectEqual(@as(u32, 1080), m.reps.items[0].height);
    try std.testing.expectApproxEqAbs(@as(f64, 90), m.duration, 0.01);
    const pick = m.pick(720);
    try std.testing.expectEqual(@as(u32, 720), m.reps.items[pick.video.?].height);
    try std.testing.expectEqual(Representation.Kind.audio, m.reps.items[pick.audio.?].kind);
}

test "a segment template expands" {
    const xml =
        \\<MPD mediaPresentationDuration="PT8S">
        \\  <Period>
        \\    <AdaptationSet mimeType="video/mp4">
        \\      <SegmentTemplate media="v/$RepresentationID$/$Number$.m4s" timescale="1000" duration="4000" startNumber="5"/>
        \\      <Representation id="v1" width="1920" height="1080" bandwidth="1000"/>
        \\    </AdaptationSet>
        \\  </Period>
        \\</MPD>
    ;
    var m = try parse(std.testing.allocator, "https://x.com/a/m.mpd", xml);
    defer m.deinit(std.testing.allocator);
    const r = &m.reps.items[0];
    try std.testing.expectEqual(@as(u64, 2), r.count);
    const first = try r.segmentUrl(std.testing.allocator, 0);
    defer std.testing.allocator.free(first);
    try std.testing.expectEqualStrings("v/v1/5.m4s", first);
    const second = try r.segmentUrl(std.testing.allocator, 1);
    defer std.testing.allocator.free(second);
    try std.testing.expectEqualStrings("v/v1/6.m4s", second);
}

test "an ISO duration is seconds" {
    try std.testing.expectApproxEqAbs(@as(f64, 3723.5), isoSeconds("PT1H2M3.5S"), 0.01);
    try std.testing.expectApproxEqAbs(@as(f64, 90), isoSeconds("PT1M30S"), 0.01);
    try std.testing.expectApproxEqAbs(@as(f64, 0), isoSeconds(""), 0.01);
}
