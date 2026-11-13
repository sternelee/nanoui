//! One download: its state, its bytes on disk, and the ranges already
//! fetched. Pure enough to test without a network: the byte accounting and
//! the state machine are here, the sockets are in `engine/http.zig`.
const std = @import("std");
const media = @import("media.zig");

pub const State = enum {
    /// Waiting for a slot in the queue.
    queued,
    /// Asking the site what the link is.
    probing,
    /// Bytes are moving.
    running,
    paused,
    /// Joining video and audio, or converting.
    processing,
    done,
    failed,
    /// Stopped by the user, kept for resuming.
    stopped,

    pub fn label(s: State) []const u8 {
        return switch (s) {
            .queued => "Waiting",
            .probing => "Reading the link",
            .running => "Downloading",
            .paused => "Paused",
            .processing => "Finishing",
            .done => "Done",
            .failed => "Failed",
            .stopped => "Stopped",
        };
    }

    /// Whether the download holds a queue slot.
    pub fn active(s: State) bool {
        return switch (s) {
            .probing, .running, .processing => true,
            else => false,
        };
    }

    pub fn finished(s: State) bool {
        return s == .done or s == .failed;
    }
};

/// A byte range already on disk: `[start, end)`, both absolute in the file.
pub const Range = struct {
    start: u64,
    end: u64,

    pub fn len(r: Range) u64 {
        return r.end - r.start;
    }
};

/// The ranges a download has, kept sorted and merged. This is what makes
/// resuming exact: a `.part` file plus its ranges says which bytes are real.
pub const Ranges = struct {
    gpa: std.mem.Allocator,
    items: std.ArrayList(Range) = .empty,

    pub fn init(gpa: std.mem.Allocator) Ranges {
        return .{ .gpa = gpa };
    }

    pub fn deinit(r: *Ranges) void {
        r.items.deinit(r.gpa);
    }

    /// Adds `range`, merging what it touches or overlaps.
    pub fn add(r: *Ranges, range: Range) !void {
        if (range.len() == 0) return;
        var lo = range.start;
        var hi = range.end;
        var i: usize = 0;
        while (i < r.items.items.len) {
            const it = r.items.items[i];
            // Touching counts as overlapping: [0,10) and [10,20) are [0,20).
            if (it.end >= lo and it.start <= hi) {
                lo = @min(lo, it.start);
                hi = @max(hi, it.end);
                _ = r.items.orderedRemove(i);
                i = 0;
                continue;
            }
            i += 1;
        }
        try r.items.append(r.gpa, .{ .start = lo, .end = hi });
        std.mem.sort(Range, r.items.items, {}, lessThan);
    }

    fn lessThan(_: void, a: Range, b: Range) bool {
        return a.start < b.start;
    }

    /// How many bytes are really there.
    pub fn total(r: *const Ranges) u64 {
        var n: u64 = 0;
        for (r.items.items) |it| n += it.len();
        return n;
    }

    /// Whether every byte of `[0, size)` is there.
    pub fn complete(r: *const Ranges, size: u64) bool {
        if (size == 0) return false;
        return r.items.items.len == 1 and r.items.items[0].start == 0 and r.items.items[0].end >= size;
    }

    /// The first gap at or after `from`, as a range to fetch; null when the
    /// file is whole.
    pub fn firstGap(r: *const Ranges, from: u64, size: u64) ?Range {
        var at = from;
        for (r.items.items) |it| {
            if (it.end <= at) continue;
            if (it.start > at) return .{ .start = at, .end = @min(it.start, size) };
            at = @max(at, it.end);
            if (at >= size) return null;
        }
        if (at >= size) return null;
        return .{ .start = at, .end = size };
    }

    /// The gaps left, split into `n` pieces for parallel connections.
    pub fn gaps(r: *const Ranges, size: u64, out: []Range) []Range {
        var n: usize = 0;
        var at: u64 = 0;
        while (at < size and n < out.len) {
            const g = r.firstGap(at, size) orelse break;
            out[n] = g;
            n += 1;
            at = g.end;
        }
        return out[0..n];
    }
};

/// One download's whole state.
pub const Download = struct {
    gpa: std.mem.Allocator,
    /// Its id: stable across runs, so the library can find it again.
    id: u64 = 0,
    /// The page it came from: what the library matches on.
    url: []const u8 = "",
    /// The file itself: one URL, or the manifest when it is streamed.
    media: []const u8 = "",
    title: []const u8 = "",
    site: media.Site = .generic,
    author: []const u8 = "",
    /// The chosen quality's label, as "1080p" or "Audio".
    quality: []const u8 = "",
    /// The container it will be saved as.
    ext: []const u8 = "mp4",
    /// Where it goes.
    path: []const u8 = "",
    /// The picture, for the row.
    thumb: []const u8 = "",
    /// Seconds.
    duration: f64 = 0,
    /// The day it was published.
    date: []const u8 = "",
    state: State = .queued,
    /// Bytes on disk, and the whole.
    done_bytes: u64 = 0,
    /// For a stream measured in segments rather than bytes.
    segs_done: u32 = 0,
    segs_total: u32 = 0,
    total_bytes: u64 = 0,
    /// Bytes a second, as last measured.
    speed: f64 = 0,
    /// Seconds left, as last estimated; -1 when unknown.
    eta: f64 = -1,
    /// Why it failed.
    problem: []const u8 = "",
    /// When it finished, as a Unix second; 0 while it hasn't.
    finished_at: i64 = 0,
    /// A live stream: it records until stopped.
    live: bool = false,
    /// What it is doing while `processing`: "Merging", "Converting".
    stage: []const u8 = "",

    /// Frees the strings this download owns. The library keeps its own
    /// copies, so this is only for one built to be handed over.
    pub fn deinit(d: *Download, gpa: std.mem.Allocator) void {
        gpa.free(d.url);
        gpa.free(d.media);
        gpa.free(d.title);
        gpa.free(d.author);
        gpa.free(d.quality);
        gpa.free(d.ext);
        gpa.free(d.path);
        gpa.free(d.thumb);
        gpa.free(d.date);
        gpa.free(d.problem);
        gpa.free(d.stage);
    }

    pub fn fraction(d: *const Download) f32 {
        // A streamed download whose playlist does not say its sizes is
        // measured in segments. Bytes would not do: `done` and `total` grow
        // together there, so the bar sat at 100% from the first segment to
        // the last, which is worse than no bar at all.
        if (d.segs_total > 0) {
            const f = @as(f64, @floatFromInt(@min(d.segs_done, d.segs_total))) / @as(f64, @floatFromInt(d.segs_total));
            return @floatCast(std.math.clamp(f, 0, 1));
        }
        if (d.total_bytes == 0) return 0;
        const f = @as(f64, @floatFromInt(d.done_bytes)) / @as(f64, @floatFromInt(d.total_bytes));
        return @floatCast(std.math.clamp(f, 0, 1));
    }

    /// Whether the row shows a bar rather than a size.
    pub fn inFlight(d: *const Download) bool {
        return switch (d.state) {
            .probing, .running, .paused, .processing, .queued => true,
            else => false,
        };
    }

    /// The line under the title: "67% · 1.1 GB of 1.6 GB · 6s left".
    pub fn statusLine(d: *const Download, buf: []u8) []const u8 {
        // Each size gets its own bytes: formatting two into one buffer would
        // have the second overwrite the first.
        var a: [24]u8 = undefined;
        var b: [24]u8 = undefined;
        return switch (d.state) {
            .queued => "Waiting its turn",
            .probing => "Reading the link",
            .paused => blk: {
                // A stream measured in segments says so here too: its bytes
                // are equal on both sides, which reads as "done", and a
                // paused row that looks finished is the worst of both.
                if (d.segs_total > 0) {
                    break :blk std.fmt.bufPrint(buf, "Paused · {d} of {d} parts · {s}", .{
                        @min(d.segs_done, d.segs_total),
                        d.segs_total,
                        size(d.done_bytes, &a),
                    }) catch "Paused";
                }
                break :blk std.fmt.bufPrint(buf, "Paused · {s} of {s}", .{ size(d.done_bytes, &a), size(d.total_bytes, &b) }) catch "Paused";
            },
            .processing => if (d.stage.len > 0) d.stage else "Finishing",
            // The state and the reason on one line: two lines said the same
            // thing twice and made a failed row taller than its neighbours.
            .failed => blk: {
                const why = if (d.problem.len > 0) d.problem else "no reason was recorded";
                break :blk std.fmt.bufPrint(buf, "Failed · {s}", .{why}) catch "Failed";
            },
            .stopped => "Stopped",
            // Where it came from and what it is, with the size: a finished
            // row says everything on one line under the title.
            .done => blk: {
                // A link that is only a file has no site to name: "the web"
                // is a placeholder, and a finished row should not carry one.
                if (d.site == .generic) {
                    break :blk std.fmt.bufPrint(buf, "{s} · {s}", .{ size(d.total_bytes, &a), d.quality }) catch size(d.total_bytes, buf);
                }
                break :blk std.fmt.bufPrint(buf, "{s} · {s} · {s}", .{ size(d.total_bytes, &a), d.site.title(), d.quality }) catch size(d.total_bytes, buf);
            },
            .running => blk: {
                var tail: [48]u8 = undefined;
                const pct = @as(u32, @intFromFloat(d.fraction() * 100));
                // A stream measured in segments says how many it has done:
                // "12 of 40" is the same fact the bar draws, in words.
                if (d.segs_total > 0) {
                    break :blk std.fmt.bufPrint(buf, "{d}% · {d} of {d} parts · {s}", .{
                        pct,
                        @min(d.segs_done, d.segs_total),
                        d.segs_total,
                        size(d.done_bytes, &a),
                    }) catch "Downloading";
                }
                // No estimate yet is not an estimate of "…": the line ends
                // after the sizes rather than trailing a placeholder.
                if (d.eta < 0) {
                    break :blk std.fmt.bufPrint(buf, "{d}% · {s} of {s}", .{ pct, size(d.done_bytes, &a), size(d.total_bytes, &b) }) catch "Downloading";
                }
                break :blk std.fmt.bufPrint(buf, "{d}% · {s} of {s} · {s}", .{
                    pct,
                    size(d.done_bytes, &a),
                    size(d.total_bytes, &b),
                    etaText(d.eta, &tail),
                }) catch "Downloading";
            },
        };
    }

    /// "1.6 GB", "412 MB", "8.3 KB". Writes into the caller's buffer: a
    /// shared static one would be a data race the moment a worker thread and
    /// the view both format a size in the same frame.
    pub fn size(bytes: u64, buf: []u8) []const u8 {
        const f: f64 = @floatFromInt(bytes);
        if (bytes >= 1 << 30) return std.fmt.bufPrint(buf, "{d:.1} GB", .{f / (1 << 30)}) catch "?";
        if (bytes >= 1 << 20) return std.fmt.bufPrint(buf, "{d:.0} MB", .{f / (1 << 20)}) catch "?";
        if (bytes >= 1 << 10) return std.fmt.bufPrint(buf, "{d:.1} KB", .{f / (1 << 10)}) catch "?";
        return std.fmt.bufPrint(buf, "{d} B", .{bytes}) catch "?";
    }

    /// "6s left", "1m 20s left", "1h 4m left".
    pub fn etaText(seconds: f64, buf: []u8) []const u8 {
        const s: u64 = @intFromFloat(@max(0, seconds));
        if (s < 60) return std.fmt.bufPrint(buf, "{d}s left", .{s}) catch "?";
        if (s < 3600) return std.fmt.bufPrint(buf, "{d}m {d}s left", .{ s / 60, s % 60 }) catch "?";
        return std.fmt.bufPrint(buf, "{d}h {d}m left", .{ s / 3600, (s % 3600) / 60 }) catch "?";
    }

    /// "1:34", "10:34", "1:02:03".
    pub fn clock(seconds: f64, buf: []u8) []const u8 {
        const s: u64 = @intFromFloat(@max(0, seconds));
        if (s < 3600) return std.fmt.bufPrint(buf, "{d}:{d:0>2}", .{ s / 60, s % 60 }) catch "?";
        return std.fmt.bufPrint(buf, "{d}:{d:0>2}:{d:0>2}", .{ s / 3600, (s % 3600) / 60, s % 60 }) catch "?";
    }

    /// A speed: "6.0 MB/s".
    pub fn speedText(bytes_per_s: f64, buf: []u8) []const u8 {
        const f = bytes_per_s;
        if (f >= 1 << 20) return std.fmt.bufPrint(buf, "{d:.1} MB/s", .{f / (1 << 20)}) catch "?";
        if (f >= 1 << 10) return std.fmt.bufPrint(buf, "{d:.0} KB/s", .{f / (1 << 10)}) catch "?";
        return std.fmt.bufPrint(buf, "{d:.0} B/s", .{f}) catch "?";
    }
};

test "ranges merge what touches" {
    var r = Ranges.init(std.testing.allocator);
    defer r.deinit();
    try r.add(.{ .start = 0, .end = 10 });
    try r.add(.{ .start = 10, .end = 20 });
    try std.testing.expectEqual(@as(usize, 1), r.items.items.len);
    try std.testing.expectEqual(@as(u64, 20), r.total());
}

test "ranges keep a gap apart" {
    var r = Ranges.init(std.testing.allocator);
    defer r.deinit();
    try r.add(.{ .start = 0, .end = 10 });
    try r.add(.{ .start = 20, .end = 30 });
    try std.testing.expectEqual(@as(usize, 2), r.items.items.len);
    try std.testing.expectEqual(@as(u64, 20), r.total());
    const gap = r.firstGap(0, 30).?;
    try std.testing.expectEqual(@as(u64, 10), gap.start);
    try std.testing.expectEqual(@as(u64, 20), gap.end);
}

test "a whole file has no gap" {
    var r = Ranges.init(std.testing.allocator);
    defer r.deinit();
    try r.add(.{ .start = 0, .end = 100 });
    try std.testing.expect(r.complete(100));
    try std.testing.expect(r.firstGap(0, 100) == null);
}

test "gaps split for parallel connections" {
    var r = Ranges.init(std.testing.allocator);
    defer r.deinit();
    try r.add(.{ .start = 0, .end = 10 });
    try r.add(.{ .start = 20, .end = 30 });
    var out: [4]Range = undefined;
    const g = r.gaps(40, &out);
    try std.testing.expectEqual(@as(usize, 2), g.len);
    try std.testing.expectEqual(@as(u64, 10), g[0].start);
    try std.testing.expectEqual(@as(u64, 30), g[1].start);
    try std.testing.expectEqual(@as(u64, 40), g[1].end);
}

test "a download's fraction and clock" {
    var d: Download = .{ .gpa = std.testing.allocator, .done_bytes = 1, .total_bytes = 4 };
    try std.testing.expectApproxEqAbs(@as(f32, 0.25), d.fraction(), 0.001);
    var buf: [24]u8 = undefined;
    try std.testing.expectEqualStrings("10:34", Download.clock(634, &buf));
    try std.testing.expectEqualStrings("1:02:03", Download.clock(3723, &buf));
    try std.testing.expectEqualStrings("1.6 GB", Download.size(1717986918, &buf));
}

test "a streamed download is measured in segments, not in bytes" {
    // A playlist that gives no sizes has done and total growing together:
    // read as bytes, the bar sat at 100% from the first segment to the last.
    var d: Download = .{ .gpa = std.testing.allocator, .done_bytes = 900, .total_bytes = 900, .segs_done = 3, .segs_total = 12 };
    try std.testing.expectApproxEqAbs(@as(f32, 0.25), d.fraction(), 0.001);
    d.segs_done = 12;
    try std.testing.expectApproxEqAbs(@as(f32, 1.0), d.fraction(), 0.001);
    // Bytes still measure a plain file, which has no segment count.
    d.segs_total = 0;
    d.done_bytes = 1;
    d.total_bytes = 4;
    try std.testing.expectApproxEqAbs(@as(f32, 0.25), d.fraction(), 0.001);
}
