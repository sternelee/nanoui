//! Ranged GETs over nanoui's HTTP: several connections per file, a `.part`
//! file that is the truth, and a resume that picks up at the first gap.
//!
//! `nanoui.http.send` is synchronous and safe off the main thread, so each
//! connection is a `std.Thread` writing its own region of the same file.
const std = @import("std");
const nanoui = @import("nanoui");
const http = nanoui.http;
const download = @import("../model/download.zig");

pub const Ranges = download.Ranges;
pub const Range = download.Range;

/// What a HEAD or a ranged GET learned about a file.
pub const Probe = struct {
    /// Bytes, or 0 when the server won't say.
    size: u64 = 0,
    /// The server honours `Range`.
    ranges: bool = false,
    /// Its content type, as "video/mp4". Owned: the response it came from
    /// is gone by the time a caller reads it.
    mime: []const u8 = "",
    /// The name it suggests, from `Content-Disposition` or the path. Owned.
    name: []const u8 = "",
    /// Where the redirects led. Owned.
    url: []const u8 = "",
    status: u16 = 0,
    problem: []const u8 = "",
    /// The allocator the strings above came from, so they can go back.
    gpa: std.mem.Allocator = undefined,

    pub fn deinit(p: *Probe) void {
        if (p.mime.len > 0) p.gpa.free(p.mime);
        if (p.name.len > 0) p.gpa.free(p.name);
        if (p.url.len > 0) p.gpa.free(p.url);
        if (p.problem.len > 0) p.gpa.free(p.problem);
        p.* = .{};
    }
};

/// The Io file work runs on: one global, as the platform backends use.
pub fn io() std.Io {
    return std.Io.Threaded.global_single_threaded.io();
}

/// A request with its URL's dot segments resolved first. A CDN's playlist
/// address is often written relative to a path it never took (`.../sub/x/../../../avf/y`),
/// and NSURLSession sends that as it stands, which the CDN refuses; the
/// resolved path is what a browser asks for.
pub fn send(gpa: std.mem.Allocator, req: http.Request) http.OwnedResponse {
    const settled = settle(gpa, req.url) catch return http.send(gpa, req);
    defer gpa.free(settled);
    var r2 = req;
    r2.url = settled;
    return http.send(gpa, r2);
}

/// `url` with `..` and `.` path segments resolved, its query untouched.
fn settle(gpa: std.mem.Allocator, url: []const u8) ![]u8 {
    const scheme_end = std.mem.indexOf(u8, url, "://") orelse return error.NotAbsolute;
    const after = url[scheme_end + 3 ..];
    const path_at = std.mem.indexOfScalar(u8, after, '/') orelse return error.NoPath;
    const origin = url[0 .. scheme_end + 3 + path_at];
    const rest = after[path_at..];
    const q = std.mem.indexOfAny(u8, rest, "?#") orelse rest.len;
    const path = rest[0..q];
    const tail = rest[q..];
    if (std.mem.indexOf(u8, path, "..") == null and std.mem.indexOf(u8, path, "./") == null) return error.AlreadySettled;

    var segs: std.ArrayList([]const u8) = .empty;
    defer segs.deinit(gpa);
    var it = std.mem.splitScalar(u8, path, '/');
    while (it.next()) |seg| {
        if (seg.len == 0 or std.mem.eql(u8, seg, ".")) continue;
        if (std.mem.eql(u8, seg, "..")) {
            if (segs.items.len > 0) _ = segs.pop();
            continue;
        }
        try segs.append(gpa, seg);
    }
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);
    try out.appendSlice(gpa, origin);
    if (segs.items.len == 0) try out.append(gpa, '/');
    for (segs.items) |seg| {
        try out.append(gpa, '/');
        try out.appendSlice(gpa, seg);
    }
    try out.appendSlice(gpa, tail);
    return out.toOwnedSlice(gpa);
}

/// The browser's own user agent: sites serve a plain client differently.
pub const user_agent = http.Header{ .name = "User-Agent", .value = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.0 Safari/605.1.15" };

/// Asks what a URL is, with a HEAD, falling back to a one-byte ranged GET
/// when the server refuses HEAD.
pub fn probe(gpa: std.mem.Allocator, url: []const u8, referer: []const u8) Probe {
    var headers: [3]http.Header = undefined;
    var n: usize = 0;
    headers[n] = user_agent;
    n += 1;
    if (referer.len > 0) {
        headers[n] = .{ .name = "Referer", .value = referer };
        n += 1;
    }
    headers[n] = .{ .name = "Accept", .value = "*/*" };
    n += 1;

    var r = send(gpa, .{ .url = url, .method = "HEAD", .headers = headers[0..n], .timeout = 20 });
    defer r.deinit();

    var out: Probe = .{ .status = r.status(), .gpa = gpa };
    out.url = gpa.dupe(u8, url) catch "";
    if (r.status() == 405 or r.status() == 501 or r.status() == 0) {
        // HEAD refused: a one-byte GET tells the same, and proves ranges.
        var extra: [4]http.Header = undefined;
        @memcpy(extra[0..n], headers[0..n]);
        extra[n] = .{ .name = "Range", .value = "bytes=0-0" };
        var r2 = send(gpa, .{ .url = url, .headers = extra[0 .. n + 1], .timeout = 20 });
        defer r2.deinit();
        out.status = r2.status();
        if (r2.status() == 206) {
            out.ranges = true;
            if (r2.header("content-range")) |cr| out.size = totalOf(cr);
        } else if (r2.status() == 200) {
            if (r2.header("content-length")) |cl| out.size = std.fmt.parseInt(u64, cl, 10) catch 0;
        }
        if (r2.err().len > 0) out.problem = gpa.dupe(u8, r2.err()) catch "";
        if (r2.header("content-type")) |ct| out.mime = gpa.dupe(u8, ct) catch "";
        if (nameOf(r2)) |nm| out.name = gpa.dupe(u8, nm) catch "";
        return out;
    }

    if (r.status() != 200 and r.status() != 206) {
        const why = if (r.err().len > 0) r.err() else "the server said no";
        out.problem = gpa.dupe(u8, why) catch "";
        return out;
    }
    if (r.header("content-length")) |cl| out.size = std.fmt.parseInt(u64, cl, 10) catch 0;
    out.ranges = r.header("accept-ranges") != null and std.mem.eql(u8, r.header("accept-ranges").?, "bytes");
    if (r.header("content-type")) |ct| out.mime = gpa.dupe(u8, ct) catch "";
    if (nameOf(r)) |nm| out.name = gpa.dupe(u8, nm) catch "";
    return out;
}

/// The total in `Content-Range: bytes 0-0/12345`.
fn totalOf(content_range: []const u8) u64 {
    const slash = std.mem.lastIndexOfScalar(u8, content_range, '/') orelse return 0;
    const tail = content_range[slash + 1 ..];
    if (std.mem.eql(u8, tail, "*")) return 0;
    return std.fmt.parseInt(u64, std.mem.trim(u8, tail, " \r\n"), 10) catch 0;
}

/// The name a URL's last segment suggests, without its query.
pub fn nameFromUrl(url: []const u8) []const u8 {
    const no_query = if (std.mem.indexOfScalar(u8, url, '?')) |q| url[0..q] else url;
    const slash = std.mem.lastIndexOfScalar(u8, no_query, '/') orelse return "file";
    const tail = no_query[slash + 1 ..];
    return if (tail.len == 0) "file" else tail;
}

fn nameOf(r: http.OwnedResponse) ?[]const u8 {
    if (r.header("content-disposition")) |cd| {
        if (std.mem.indexOf(u8, cd, "filename=")) |at| {
            var v = cd[at + "filename=".len ..];
            if (std.mem.indexOfScalar(u8, v, ';')) |semi| v = v[0..semi];
            return std.mem.trim(u8, v, " \"'");
        }
    }
    // The last path segment, without its query.
    const no_query = if (std.mem.indexOfScalar(u8, r.url(), '?')) |q| r.url()[0..q] else r.url();
    const slash = std.mem.lastIndexOfScalar(u8, no_query, '/') orelse return null;
    const tail = no_query[slash + 1 ..];
    return if (tail.len == 0) null else tail;
}

/// One connection's work: fetch `[start, end)` of `url` into `file` at the
/// same offsets, and add the range to `ranges` as it lands.
pub const Job = struct {
    gpa: std.mem.Allocator,
    url: []const u8,
    referer: []const u8,
    file: *std.Io.File,
    start: u64,
    end: u64,
    /// Bytes fetched so far, and the file's total: read by the UI.
    done: *std.atomic.Value(u64),
    /// Set when the job failed, and why.
    failed: *std.atomic.Value(bool),
    problem: []u8,
    problem_len: *std.atomic.Value(usize),
    /// A speed limit for this job, in bytes a second; 0 for none.
    rate: u64 = 0,
    /// Set to stop early (a pause or a cancel).
    stop: *std.atomic.Value(bool),

    /// Runs on its own thread.
    pub fn run(j: *Job, ranges: *Ranges, ranges_lock: *std.Io.Mutex) void {
        defer if (j.failed.load(.acquire)) j.fail("stopped");

        var at = j.start;
        // A chunk per request: big enough to be efficient, small enough that
        // a pause is felt quickly.
        const chunk: u64 = 1 << 20;
        while (at < j.end) {
            if (j.stop.load(.acquire)) return;
            const hi = @min(at + chunk - 1, j.end - 1);
            var buf: [64]u8 = undefined;
            const range = std.fmt.bufPrint(&buf, "bytes={d}-{d}", .{ at, hi }) catch return;
            var headers = [_]http.Header{
                user_agent,
                .{ .name = "Range", .value = range },
                .{ .name = "Accept", .value = "*/*" },
            };
            var n: usize = 2;
            if (j.referer.len > 0) {
                headers[2] = .{ .name = "Referer", .value = j.referer };
                n = 3;
            }
            const began = @import("../now.zig").ms();
            var r = http.send(j.gpa, .{ .url = j.url, .headers = headers[0..n], .timeout = 30 });
            defer r.deinit();
            if (r.status() != 206 and r.status() != 200) {
                j.fail(if (r.err().len > 0) r.err() else "the server stopped answering");
                return;
            }
            const body = r.body();
            if (body.len == 0) {
                j.fail("the server sent nothing");
                return;
            }
            // A 200 means the server ignored Range: this job owns the whole
            // file, so it writes from 0 and the others stand down.
            const write_at: u64 = if (r.status() == 200) 0 else at;
            j.file.writePositionalAll(io(), body, write_at) catch {
                j.fail("could not write the file");
                return;
            };
            {
                ranges_lock.lockUncancelable(io());
                defer ranges_lock.unlock(io());
                ranges.add(.{ .start = write_at, .end = write_at + body.len }) catch {};
            }
            _ = j.done.fetchAdd(body.len, .monotonic);
            at = write_at + body.len;
            if (r.status() == 200) {
                // The whole file came in one answer.
                j.end = at;
                return;
            }
            // Hold the pace the limit asks for.
            if (j.rate > 0) {
                const want_ms = @as(i64, @intCast((body.len * 1000) / j.rate));
                const took = @import("../now.zig").ms() - began;
                if (want_ms > took) @import("../now.zig").sleepMs(@intCast(want_ms - took));
            }
        }
    }

    fn fail(j: *Job, why: []const u8) void {
        const n = @min(why.len, j.problem.len);
        @memcpy(j.problem[0..n], why[0..n]);
        j.problem_len.store(n, .release);
        j.failed.store(true, .release);
    }
};

/// Fetches `url`'s `[start, end)` into `file` on `threads` connections at
/// once, blocking until all are done. Returns whether every byte landed.
pub fn fetchRanges(
    gpa: std.mem.Allocator,
    url: []const u8,
    referer: []const u8,
    file: *std.Io.File,
    ranges: *Ranges,
    start: u64,
    end: u64,
    threads: u32,
    rate: u64,
    progress: *std.atomic.Value(u64),
    stop: *std.atomic.Value(bool),
) !Outcome {
    const n = @max(1, @min(threads, 16));
    // Split what is missing into `n` pieces.
    var pieces: [16]Range = undefined;
    const missing = splitMissing(ranges, start, end, &pieces, n);
    if (missing.len == 0) return .{ .ok = true, .done = progress.load(.acquire) };

    var failed = std.atomic.Value(bool).init(false);
    var problem: [256]u8 = undefined;
    var problem_len = std.atomic.Value(usize).init(0);
    var lock: std.Io.Mutex = .init;

    var jobs: [16]Job = undefined;
    var handles: [16]std.Thread = undefined;
    var started: usize = 0;
    for (missing, 0..) |piece, i| {
        jobs[i] = .{
            .gpa = gpa,
            .url = url,
            .referer = referer,
            .file = file,
            .start = piece.start,
            .end = piece.end,
            .done = progress,
            .failed = &failed,
            .problem = &problem,
            .problem_len = &problem_len,
            .rate = rate,
            .stop = stop,
        };
        handles[i] = std.Thread.spawn(.{}, worker, .{ &jobs[i], ranges, &lock }) catch {
            // No thread: do it here.
            jobs[i].run(ranges, &lock);
            continue;
        };
        started += 1;
    }
    for (handles[0..started]) |h| h.join();

    if (failed.load(.acquire)) {
        const len = problem_len.load(.acquire);
        return .{ .ok = false, .done = progress.load(.acquire), .problem = problem[0..len] };
    }
    return .{ .ok = ranges.complete(end), .done = progress.load(.acquire) };
}

fn worker(j: *Job, ranges: *Ranges, lock: *std.Io.Mutex) void {
    j.run(ranges, lock);
}

pub const Outcome = struct {
    ok: bool,
    done: u64,
    problem: []const u8 = "",
};

/// The missing bytes of `[start, end)`, cut into at most `n` pieces of
/// roughly equal size, so the connections finish together.
pub fn splitMissing(ranges: *const Ranges, start: u64, end: u64, out: []Range, n: u32) []Range {
    var gaps: [64]Range = undefined;
    var count: usize = 0;
    var at = start;
    while (at < end and count < gaps.len) {
        const g = ranges.firstGap(at, end) orelse break;
        gaps[count] = g;
        count += 1;
        at = g.end;
    }
    if (count == 0) return out[0..0];
    if (n <= 1 or count >= n) return copyInto(gaps[0..count], out);

    // Fewer gaps than connections: cut the biggest ones.
    var total: u64 = 0;
    for (gaps[0..count]) |g| total += g.len();
    const target = @max(1, total / n);
    var written: usize = 0;
    for (gaps[0..count]) |g| {
        if (written == out.len) break;
        var from = g.start;
        while (from < g.end and written < out.len) {
            const to = @min(from + target, g.end);
            out[written] = .{ .start = from, .end = to };
            written += 1;
            from = to;
        }
    }
    return out[0..written];
}

fn copyInto(src: []const Range, out: []Range) []Range {
    const n = @min(src.len, out.len);
    @memcpy(out[0..n], src[0..n]);
    return out[0..n];
}

test "a missing range is split into equal pieces" {
    var r = Ranges.init(std.testing.allocator);
    defer r.deinit();
    var out: [8]Range = undefined;
    const pieces = splitMissing(&r, 0, 1000, &out, 4);
    try std.testing.expectEqual(@as(usize, 4), pieces.len);
    try std.testing.expectEqual(@as(u64, 0), pieces[0].start);
    try std.testing.expectEqual(@as(u64, 1000), pieces[3].end);
    for (pieces) |p| try std.testing.expectEqual(@as(u64, 250), p.len());
}

test "what is already there is not fetched again" {
    var r = Ranges.init(std.testing.allocator);
    defer r.deinit();
    try r.add(.{ .start = 0, .end = 500 });
    var out: [8]Range = undefined;
    const pieces = splitMissing(&r, 0, 1000, &out, 4);
    try std.testing.expectEqual(@as(u64, 500), pieces[0].start);
    try std.testing.expectEqual(@as(u64, 1000), pieces[pieces.len - 1].end);
    var total: u64 = 0;
    for (pieces) |p| total += p.len();
    try std.testing.expectEqual(@as(u64, 500), total);
}

test "a complete file has nothing to fetch" {
    var r = Ranges.init(std.testing.allocator);
    defer r.deinit();
    try r.add(.{ .start = 0, .end = 1000 });
    var out: [8]Range = undefined;
    try std.testing.expectEqual(@as(usize, 0), splitMissing(&r, 0, 1000, &out, 4).len);
}

test "content-range gives the total" {
    try std.testing.expectEqual(@as(u64, 12345), totalOf("bytes 0-0/12345"));
    try std.testing.expectEqual(@as(u64, 0), totalOf("bytes 0-0/*"));
    try std.testing.expectEqual(@as(u64, 0), totalOf("nonsense"));
}
