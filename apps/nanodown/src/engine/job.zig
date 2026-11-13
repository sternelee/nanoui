//! One download's work: probe, fetch, and finish. Runs on its own thread and
//! reports through atomics, so the UI never waits on a socket.
//!
//! A single file is fetched in ranges into a `.part` beside its destination.
//! A streamed one (HLS, DASH) is fetched segment by segment, appended in
//! order. Two streams that came apart are joined by `mux_write.zig`.
const std = @import("std");
const nanoui = @import("nanoui");
const http = nanoui.http;
const media = @import("../model/media.zig");
const download = @import("../model/download.zig");
const httpz = @import("http.zig");
const hls = @import("hls.zig");
const dash = @import("dash.zig");
const mux = @import("mux.zig");
const mux_write = @import("mux_write.zig");

/// What the worker shares with the frame that draws it.
pub const Shared = struct {
    /// Bytes on disk so far.
    done: std.atomic.Value(u64) = std.atomic.Value(u64).init(0),
    /// The whole, once known.
    total: std.atomic.Value(u64) = std.atomic.Value(u64).init(0),
    /// Segments fetched, and how many there are, for a playlist that does
    /// not say its sizes. Bytes cannot tell the frame how far along such a
    /// stream is: `done` and `total` would be the same number all the way
    /// through, which reads as 100% from the first segment to the last.
    segs_done: std.atomic.Value(u32) = std.atomic.Value(u32).init(0),
    segs_total: std.atomic.Value(u32) = std.atomic.Value(u32).init(0),
    /// Set to stop: a pause, a cancel, or the app quitting.
    stop: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    /// Set when the work ended, and whether it worked.
    finished: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    ok: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    /// The stage it is in, as a small number (`Stage`).
    stage: std.atomic.Value(u8) = std.atomic.Value(u8).init(0),
    /// Why it failed, when it did.
    problem: [256]u8 = @splat(0),
    problem_len: std.atomic.Value(usize) = std.atomic.Value(usize).init(0),
    /// The file it wrote.
    path: [1024]u8 = @splat(0),
    path_len: std.atomic.Value(usize) = std.atomic.Value(usize).init(0),

    pub const Stage = enum(u8) { probing, downloading, merging, writing, done, failed };

    pub fn stageOf(s: *const Shared) Stage {
        return @enumFromInt(s.stage.load(.acquire));
    }

    pub fn fail(s: *Shared, reason: []const u8) void {
        const n = @min(reason.len, s.problem.len);
        @memcpy(s.problem[0..n], reason[0..n]);
        s.problem_len.store(n, .release);
        s.stage.store(@intFromEnum(Stage.failed), .release);
        s.ok.store(false, .release);
        s.finished.store(true, .release);
    }

    pub fn succeed(s: *Shared, path: []const u8) void {
        const n = @min(path.len, s.path.len);
        @memcpy(s.path[0..n], path[0..n]);
        s.path_len.store(n, .release);
        s.stage.store(@intFromEnum(Stage.done), .release);
        s.ok.store(true, .release);
        s.finished.store(true, .release);
    }

    pub fn why(s: *const Shared) []const u8 {
        return s.problem[0..s.problem_len.load(.acquire)];
    }

    pub fn wrote(s: *const Shared) []const u8 {
        return s.path[0..s.path_len.load(.acquire)];
    }
};

/// Everything one download needs to run.
pub const Spec = struct {
    gpa: std.mem.Allocator,
    /// The link the user gave.
    url: []const u8,
    /// The page it came from, for the Referer.
    referer: []const u8 = "",
    /// The quality chosen.
    format: media.Format,
    /// Where the result goes, without its extension.
    dest: []const u8,
    /// The container to save as: "mp4", "mkv", "mp3"…
    ext: []const u8 = "mp4",
    /// How many connections for one file.
    connections: u32 = 4,
    /// A speed limit in bytes a second; 0 for none.
    rate: u64 = 0,
    /// Tags to write into the result.
    tags: mux_write.Tags = .{},
    /// The artwork's URL, fetched and embedded when it can be.
    artwork_url: []const u8 = "",
};

/// Runs one download. Blocks; call it on a thread.
pub fn run(spec: Spec, shared: *Shared) void {
    defer if (!shared.finished.load(.acquire)) shared.fail("stopped");
    shared.stage.store(@intFromEnum(Shared.Stage.probing), .release);

    const gpa = spec.gpa;
    const ext = if (spec.ext.len > 0) spec.ext else spec.format.ext;

    // A streamed format is fetched segment by segment.
    if (spec.format.manifest) |m| {
        switch (m) {
            .hls => |u| return runHls(spec, shared, u, ext),
            .dash => |u| return runDash(spec, shared, u, ext),
        }
    }

    // One file: probe it, then fetch what is missing.
    var p = httpz.probe(gpa, spec.format.url, spec.referer);
    defer p.deinit();
    if (p.problem.len > 0 and p.size == 0) return shared.fail(p.problem);
    const total = if (spec.format.size > 0) spec.format.size else p.size;
    shared.total.store(total, .release);
    shared.stage.store(@intFromEnum(Shared.Stage.downloading), .release);

    const part = std.fmt.allocPrint(gpa, "{s}.part", .{spec.dest}) catch return shared.fail("out of memory");
    defer gpa.free(part);
    var part_file = openPart(part) orelse return shared.fail("could not open the file to write");
    defer part_file.close();

    var ranges = download.Ranges.init(gpa);
    defer ranges.deinit();
    // What a previous run already fetched is still real.
    if (total > 0) ranges.add(.{ .start = 0, .end = @min(part_file.file.length(httpz.io()) catch 0, total) }) catch {};

    const outcome = httpz.fetchRanges(gpa, spec.format.url, spec.referer, &part_file.file, &ranges, 0, total, spec.connections, spec.rate, &shared.done, &shared.stop) catch {
        return shared.fail("the download could not start");
    };
    if (!outcome.ok) return shared.fail(if (outcome.problem.len > 0) outcome.problem else "the download stopped early");

    // The bytes are all there: give them their name.
    shared.stage.store(@intFromEnum(Shared.Stage.writing), .release);
    finishFile(gpa, spec, part, ext, shared) catch return shared.fail("could not finish the file");
}

/// A single file that needs no muxing: renamed, or converted.
fn finishFile(gpa: std.mem.Allocator, spec: Spec, part: []const u8, ext: []const u8, shared: *Shared) !void {
    // A name that already ends in the extension keeps it: a file named
    // `clip.mp4` does not become `clip.mp4.mp4`.
    const final = if (std.mem.endsWith(u8, spec.dest, ext))
        try gpa.dupe(u8, spec.dest)
    else
        try std.fmt.allocPrint(gpa, "{s}.{s}", .{ spec.dest, ext });
    defer gpa.free(final);
    // Tags go into an MP4 that has none; anything else is copied as it is.
    if (std.mem.eql(u8, ext, "mp4") or std.mem.eql(u8, ext, "m4a")) {
        if (tagInPlace(gpa, part, spec.tags)) |_| {} else |_| {}
    }
    const cwd = std.Io.Dir.cwd();
    cwd.rename(part, cwd, final, httpz.io()) catch {
        // A rename across filesystems fails: copy instead.
        try copyFile(gpa, part, final);
        cwd.deleteFile(httpz.io(), part) catch {};
    };
    shared.succeed(final);
}

/// Writes the tags into an MP4 that is already whole, by rebuilding its
/// `moov` around the same samples. Best effort: a file it cannot read is
/// left as it is.
fn tagInPlace(gpa: std.mem.Allocator, path: []const u8, tags: mux_write.Tags) !void {
    if (tags.title.len == 0 and tags.artist.len == 0 and tags.artwork.len == 0) return;
    const bytes = try std.Io.Dir.cwd().readFileAlloc(httpz.io(), path, gpa, .limited(4 << 30));
    defer gpa.free(bytes);
    // A fragmented MP4 (an fMP4 stream, its samples in `moof`/`mdat` pairs
    // after the `moov`) is not the one-`moov`-one-`mdat` shape the muxer
    // rebuilds: its samples would be read as none, and the file written out
    // as an empty one. The tags are worth less than the video, so a
    // fragmented file keeps its bytes and goes without them.
    if (hasFragments(bytes)) return;
    var video = mux.readTrack(gpa, bytes, .video) catch return;
    defer video.deinit(gpa);
    const out = try mux_write.write(gpa, &video, bytes, null, "", tags);
    defer gpa.free(out);
    try std.Io.Dir.cwd().writeFile(httpz.io(), .{ .sub_path = path, .data = out });
}

/// Whether the file's samples live in `moof` boxes rather than one `mdat`.
fn hasFragments(bytes: []const u8) bool {
    var i: usize = 0;
    while (i + 8 <= bytes.len) {
        const size = mux.readU32(bytes, i);
        const kind: [4]u8 = bytes[i + 4 .. i + 8][0..4].*;
        if (std.mem.eql(u8, &kind, "moof")) return true;
        const len: usize = if (size == 1) blk: {
            if (i + 16 > bytes.len) break;
            break :blk @intCast(mux.readU64(bytes, i + 8));
        } else if (size == 0) bytes.len - i else size;
        if (len < 8) break;
        i += len;
    }
    return false;
}

fn copyFile(gpa: std.mem.Allocator, from: []const u8, to: []const u8) !void {
    const bytes = try std.Io.Dir.cwd().readFileAlloc(httpz.io(), from, gpa, .limited(4 << 30));
    defer gpa.free(bytes);
    try std.Io.Dir.cwd().writeFile(httpz.io(), .{ .sub_path = to, .data = bytes });
}

/// A `.part` file that closes once: the bytes are flushed before a rename,
/// and the deferred close that follows finds nothing left to do.
const Part = struct {
    file: std.Io.File,
    /// Where the next byte goes. Written positionally, so a part left by an
    /// earlier run is added to rather than written over.
    pos: u64 = 0,
    open: bool = true,

    fn close(p: *Part) void {
        if (!p.open) return;
        p.file.close(httpz.io());
        p.open = false;
    }

    fn write(p: *Part, bytes: []const u8) !void {
        try p.file.writePositionalAll(httpz.io(), bytes, p.pos);
        p.pos += bytes.len;
    }
};

/// The `.part` file, open for appending: a file left by an earlier run keeps
/// what it had, and the new bytes go after it.
fn openPart(path: []const u8) ?Part {
    const dir = std.Io.Dir.cwd();
    const f = if (dir.openFile(httpz.io(), path, .{ .mode = .read_write })) |got| got else |_| {
        return .{ .file = dir.createFile(httpz.io(), path, .{ .read = true, .truncate = false }) catch return null };
    };
    return .{ .file = f, .pos = f.length(httpz.io()) catch 0 };
}

// --- streamed -------------------------------------------------------------

/// HLS: read the playlist, fetch each segment in order, append.
fn runHls(spec: Spec, shared: *Shared, manifest_url: []const u8, ext: []const u8) void {
    const gpa = spec.gpa;
    var r = fetchText(gpa, manifest_url, spec.referer) orelse return shared.fail("the playlist did not load");
    defer r.deinit();
    var p = hls.parse(gpa, manifest_url, r.body()) catch return shared.fail("the playlist could not be read");
    defer p.deinit(gpa);

    // A master playlist: take the variant that matches the chosen quality.
    var media_url = manifest_url;
    var owned_media: ?[]const u8 = null;
    defer if (owned_media) |o| gpa.free(o);
    if (p.isMaster()) {
        var best: ?hls.Variant = null;
        for (p.variants.items) |v| {
            if (spec.format.height > 0 and v.height > spec.format.height) continue;
            if (best == null or v.height > best.?.height) best = v;
        }
        if (best) |v| {
            owned_media = gpa.dupe(u8, v.url) catch return shared.fail("out of memory");
            media_url = owned_media.?;
            var r2 = fetchText(gpa, media_url, manifest_url) orelse return shared.fail("the stream's playlist did not load");
            defer r2.deinit();
            p.deinit(gpa);
            p = hls.parse(gpa, media_url, r2.body()) catch return shared.fail("the stream's playlist could not be read");
        }
    }
    if (p.isDrm()) return shared.fail("DRM-protected, so its samples cannot be decrypted");
    if (p.segments.items.len == 0) return shared.fail("the stream has no segments");

    shared.stage.store(@intFromEnum(Shared.Stage.downloading), .release);
    const part = std.fmt.allocPrint(gpa, "{s}.part", .{spec.dest}) catch return shared.fail("out of memory");
    defer gpa.free(part);
    var part_file = openPart(part) orelse return shared.fail("could not open the file to write");
    defer part_file.close();

    // The init segment an fMP4 needs comes first.
    if (p.init.len > 0) {
        if (fetchText(gpa, p.init, media_url)) |got| {
            var init = got;
            defer init.deinit();
            part_file.write(init.body()) catch return shared.fail("could not write the file");
            _ = shared.done.fetchAdd(init.body().len, .monotonic);
        }
    }

    // The whole is the sum of what the segments say they are.
    var total: u64 = 0;
    for (p.segments.items) |s| {
        if (s.range) |rr| total += rr[1] - rr[0] + 1;
    }
    if (total > 0) {
        shared.total.store(total, .release);
    } else {
        // No sizes in the playlist: the count of segments is the progress
        // there is, and it is a real one.
        shared.segs_total.store(@intCast(p.segments.items.len), .release);
    }

    for (p.segments.items) |seg| {
        if (shared.stop.load(.acquire)) return shared.fail("stopped");
        var headers = [_]http.Header{
            httpz.user_agent,
            .{ .name = "Accept", .value = "*/*" },
            .{ .name = "Range", .value = "" },
        };
        var n: usize = 2;
        var range_buf: [48]u8 = undefined;
        if (seg.range) |rr| {
            headers[2] = .{ .name = "Range", .value = std.fmt.bufPrint(&range_buf, "bytes={d}-{d}", .{ rr[0], rr[1] }) catch "*/*" };
            n = 3;
        }
        var resp = httpz.send(gpa, .{ .url = seg.url, .headers = headers[0..n], .timeout = 30 });
        defer resp.deinit();
        if (resp.status() != 200 and resp.status() != 206) return shared.fail("a segment did not arrive");
        part_file.write(resp.body()) catch return shared.fail("could not write the file");
        _ = shared.done.fetchAdd(resp.body().len, .monotonic);
        // A playlist that does not say its sizes: the total grows with it,
        // and the segment count is what says how far along it is.
        if (total == 0) {
            _ = shared.total.fetchAdd(resp.body().len, .monotonic);
            _ = shared.segs_done.fetchAdd(1, .monotonic);
        }
    }

    shared.stage.store(@intFromEnum(Shared.Stage.writing), .release);
    // Closed before it is renamed: a rename of a file still open can carry
    // only what the file has flushed, and the tail would be lost.
    part_file.close();
    // A playlist of MPEG-TS segments is one TS file, whatever the settings
    // asked for: naming it `.mp4` would be a lie a player has to guess at.
    const real = if (p.isTs()) "ts" else ext;
    finishFile(gpa, spec, part, real, shared) catch shared.fail("could not finish the file");
}

/// DASH: read the MPD, fetch the init and then each segment.
fn runDash(spec: Spec, shared: *Shared, manifest_url: []const u8, ext: []const u8) void {
    const gpa = spec.gpa;
    var r = fetchText(gpa, manifest_url, spec.referer) orelse return shared.fail("the manifest did not load");
    defer r.deinit();
    var m = dash.parse(gpa, manifest_url, r.body()) catch return shared.fail("the manifest could not be read");
    defer m.deinit(gpa);

    // The representation the chosen quality names.
    var rep: ?*const dash.Representation = null;
    for (m.reps.items) |*cand| {
        if (cand.kind != .video) continue;
        if (spec.format.height > 0 and cand.height > spec.format.height) continue;
        if (rep == null or cand.height > rep.?.height) rep = cand;
    }
    if (rep == null) return shared.fail("the manifest has no video at that quality");
    const v = rep.?;
    if (v.count == 0) return shared.fail("the manifest names no segments");
    shared.segs_total.store(@intCast(v.count), .release);

    shared.stage.store(@intFromEnum(Shared.Stage.downloading), .release);
    const part = std.fmt.allocPrint(gpa, "{s}.part", .{spec.dest}) catch return shared.fail("out of memory");
    defer gpa.free(part);
    var part_file = openPart(part) orelse return shared.fail("could not open the file to write");
    defer part_file.close();

    if (v.init.len > 0) {
        if (fetchText(gpa, v.init, manifest_url)) |got| {
            var init = got;
            defer init.deinit();
            part_file.write(init.body()) catch return shared.fail("could not write the file");
        }
    }
    var i: u64 = 0;
    while (i < v.count) : (i += 1) {
        if (shared.stop.load(.acquire)) return shared.fail("stopped");
        const seg_url = v.segmentUrl(gpa, i) catch return shared.fail("out of memory");
        defer gpa.free(seg_url);
        if (seg_url.len == 0) continue;
        var resp = fetchText(gpa, seg_url, manifest_url) orelse return shared.fail("a segment did not arrive");
        defer resp.deinit();
        part_file.write(resp.body()) catch return shared.fail("could not write the file");
        _ = shared.done.fetchAdd(resp.body().len, .monotonic);
        // A DASH manifest names how many segments there are, not how big
        // they are: the count is the progress, and the bytes are the size.
        _ = shared.segs_done.fetchAdd(1, .monotonic);
        _ = shared.total.fetchAdd(resp.body().len, .monotonic);
    }

    shared.stage.store(@intFromEnum(Shared.Stage.writing), .release);
    finishFile(gpa, spec, part, ext, shared) catch shared.fail("could not finish the file");
}

fn fetchText(gpa: std.mem.Allocator, url: []const u8, referer: []const u8) ?http.OwnedResponse {
    var headers = [_]http.Header{
        httpz.user_agent,
        .{ .name = "Accept", .value = "*/*" },
        .{ .name = "Referer", .value = "" },
    };
    var n: usize = 2;
    if (referer.len > 0) {
        headers[2] = .{ .name = "Referer", .value = referer };
        n = 3;
    }
    var r = httpz.send(gpa, .{ .url = url, .headers = headers[0..n], .timeout = 30 });
    if (r.status() != 200 and r.status() != 206) {
        r.deinit();
        return null;
    }
    return r;
}

// --- joining two streams --------------------------------------------------

/// Joins a video file and an audio file into one MP4 at `dest`. The two
/// sources are left alone; the result is new.
pub fn join(gpa: std.mem.Allocator, video_path: []const u8, audio_path: []const u8, dest: []const u8, tags: mux_write.Tags) !void {
    const video = try std.Io.Dir.cwd().readFileAlloc(httpz.io(), video_path, gpa, .limited(4 << 30));
    defer gpa.free(video);
    const audio = try std.Io.Dir.cwd().readFileAlloc(httpz.io(), audio_path, gpa, .limited(1 << 30));
    defer gpa.free(audio);

    var vt = try mux.readTrack(gpa, video, .video);
    defer vt.deinit(gpa);
    var at = try mux.readTrack(gpa, audio, .audio);
    defer at.deinit(gpa);

    const out = try mux_write.write(gpa, &vt, video, &at, audio, tags);
    defer gpa.free(out);
    try std.Io.Dir.cwd().writeFile(httpz.io(), .{ .sub_path = dest, .data = out });
}

test "a shared's stage reads back" {
    var s: Shared = .{};
    try std.testing.expectEqual(Shared.Stage.probing, s.stageOf());
    s.stage.store(@intFromEnum(Shared.Stage.merging), .release);
    try std.testing.expectEqual(Shared.Stage.merging, s.stageOf());
    s.fail("no network");
    try std.testing.expectEqualStrings("no network", s.why());
    try std.testing.expect(s.finished.load(.acquire));
    try std.testing.expect(!s.ok.load(.acquire));
}

test "a shared records the file it wrote" {
    var s: Shared = .{};
    s.succeed("/tmp/a.mp4");
    try std.testing.expectEqualStrings("/tmp/a.mp4", s.wrote());
    try std.testing.expect(s.ok.load(.acquire));
}

test "a fragmented MP4 is told from a plain one" {
    // ftyp, then moof: the shape an fMP4 stream has.
    const frag = [_]u8{ 0, 0, 0, 16, 'f', 't', 'y', 'p', 'i', 's', 'o', 'm', 0, 0, 0, 0, 0, 0, 0, 8, 'm', 'o', 'o', 'f' };
    try std.testing.expect(hasFragments(&frag));
    // ftyp, moov, mdat: one track, its samples in the one mdat.
    const plain = [_]u8{ 0, 0, 0, 16, 'f', 't', 'y', 'p', 'i', 's', 'o', 'm', 0, 0, 0, 0, 0, 0, 0, 8, 'm', 'o', 'o', 'v', 0, 0, 0, 8, 'm', 'd', 'a', 't' };
    try std.testing.expect(!hasFragments(&plain));
    try std.testing.expect(!hasFragments(""));
}
