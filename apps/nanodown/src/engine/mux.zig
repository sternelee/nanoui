//! An MP4's boxes: reading a track's sample table out of a file, so two
//! streams can be joined without re-encoding. Writing is `mux_write.zig`.
const std = @import("std");

/// A box: its type and its payload.
pub const Box = struct {
    kind: [4]u8,
    /// Where the payload starts in the file, and how long it is.
    start: usize,
    len: usize,

    /// The type, by value: a pointer into the parameter would dangle.
    pub fn name(b: Box) [4]u8 {
        return b.kind;
    }
};

/// Reads the boxes at `at` in `bytes`, calling `visit` for each.
pub fn walk(bytes: []const u8, at: usize, end: usize, ctx: anytype, comptime visit: fn (@TypeOf(ctx), Box) bool) void {
    var i = at;
    while (i + 8 <= end) {
        const size = readU32(bytes, i);
        const kind: [4]u8 = bytes[i + 4 .. i + 8][0..4].*;
        var len: usize = size;
        var header: usize = 8;
        if (size == 1) {
            // A 64-bit size follows the type.
            if (i + 16 > end) return;
            len = @intCast(readU64(bytes, i + 8));
            header = 16;
        } else if (size == 0) {
            len = end - i;
        }
        if (len < header or i + len > end) return;
        if (!visit(ctx, .{ .kind = kind, .start = i + header, .len = len - header })) return;
        i += len;
    }
}

/// The `mdat` payloads of a file, in order.
pub const Mdat = struct { start: usize, len: usize };

/// What the muxer needs from one input: its track's samples and the codec.
pub const Track = struct {
    kind: Kind,
    /// The codec's own configuration: `avcC`, `hvcC`, `esds`, `mp4a`'s.
    /// Copied into the output's `stsd` as it is.
    sample_entry: []const u8 = "",
    /// The handler's name: "VideoHandler", "SoundHandler".
    handler: []const u8 = "",
    /// The media's timescale (ticks a second).
    timescale: u32 = 1000,
    /// Each sample: its offset in the source, its size, and when it decodes.
    samples: std.ArrayList(Sample) = .empty,
    /// The `mdat` payloads, so offsets can be rebased.
    mdats: std.ArrayList(Mdat) = .empty,
    /// The track's width and height, for video.
    width: u16 = 0,
    height: u16 = 0,
    /// The audio's channels and sample rate.
    channels: u16 = 0,
    sample_rate: u32 = 0,

    pub const Kind = enum { video, audio };

    pub fn deinit(t: *Track, gpa: std.mem.Allocator) void {
        gpa.free(t.sample_entry);
        gpa.free(t.handler);
        t.samples.deinit(gpa);
        t.mdats.deinit(gpa);
    }

    /// Seconds the track runs.
    pub fn seconds(t: *const Track) f64 {
        if (t.samples.items.len == 0 or t.timescale == 0) return 0;
        const last = t.samples.items[t.samples.items.len - 1];
        return @as(f64, @floatFromInt(last.dts + last.duration)) / @as(f64, @floatFromInt(t.timescale));
    }
};

pub const Sample = struct {
    /// Where the bytes are in the source file.
    offset: u64,
    size: u32,
    /// Decode time, in the track's timescale.
    dts: u64,
    duration: u32,
    /// Composition offset, for B-frames.
    cts: i32 = 0,
    /// A sync sample: a keyframe.
    key: bool = false,
};

/// Reads one MP4's track: its `moov`'s sample table and its `mdat`s.
pub fn readTrack(gpa: std.mem.Allocator, bytes: []const u8, want: Track.Kind) !Track {
    var t: Track = .{
        .kind = want,
        .sample_entry = try gpa.dupe(u8, ""),
        .handler = try gpa.dupe(u8, if (want == .video) "VideoHandler" else "SoundHandler"),
    };
    errdefer t.deinit(gpa);

    const Ctx = struct {
        gpa: std.mem.Allocator,
        t: *Track,
        want: Track.Kind,
        found: bool = false,
        mdats: *std.ArrayList(Mdat),
    };
    var ctx: Ctx = .{ .gpa = gpa, .t = &t, .want = want, .mdats = &t.mdats };

    // The top level: find `moov` and every `mdat`.
    var i: usize = 0;
    while (i + 8 <= bytes.len) {
        const size = readU32(bytes, i);
        const kind: [4]u8 = bytes[i + 4 .. i + 8][0..4].*;
        var len: usize = size;
        var header: usize = 8;
        if (size == 1) {
            if (i + 16 > bytes.len) break;
            len = @intCast(readU64(bytes, i + 8));
            header = 16;
        } else if (size == 0) len = bytes.len - i;
        if (len < header or i + len > bytes.len) break;
        if (std.mem.eql(u8, &kind, "moov")) {
            readMoov(&ctx, bytes, i + header, i + len);
        } else if (std.mem.eql(u8, &kind, "mdat")) {
            try t.mdats.append(gpa, .{ .start = i + header, .len = len - header });
        }
        i += len;
    }
    if (!ctx.found) return error.NoSuchTrack;
    return t;
}

fn readMoov(ctx: anytype, bytes: []const u8, at: usize, end: usize) void {
    var i = at;
    while (i + 8 <= end) {
        const size = readU32(bytes, i);
        const kind: [4]u8 = bytes[i + 4 .. i + 8][0..4].*;
        if (size < 8 or i + size > end) return;
        if (std.mem.eql(u8, &kind, "trak")) readTrak(ctx, bytes, i + 8, i + size);
        i += size;
    }
}

fn readTrak(ctx: anytype, bytes: []const u8, at: usize, end: usize) void {
    // The handler says which kind this track is; only the wanted one is read.
    var kind: Track.Kind = .video;
    var i = at;
    while (i + 8 <= end) {
        const size = readU32(bytes, i);
        const b: [4]u8 = bytes[i + 4 .. i + 8][0..4].*;
        if (size < 8 or i + size > end) return;
        if (std.mem.eql(u8, &b, "mdia")) {
            var j = i + 8;
            while (j + 8 <= i + size) {
                const s2 = readU32(bytes, j);
                const b2: [4]u8 = bytes[j + 4 .. j + 8][0..4].*;
                if (s2 < 8 or j + s2 > i + size) break;
                if (std.mem.eql(u8, &b2, "hdlr")) {
                    // version+flags(4) pre_defined(4) handler_type(4)
                    const h = bytes[j + 8 + 8 .. j + 8 + 12];
                    kind = if (std.mem.eql(u8, h, "soun")) .audio else .video;
                }
                j += s2;
            }
        }
        i += size;
    }
    if (kind != ctx.want) return;
    ctx.found = true;
    ctx.t.kind = kind;

    i = at;
    while (i + 8 <= end) {
        const size = readU32(bytes, i);
        const b: [4]u8 = bytes[i + 4 .. i + 8][0..4].*;
        if (size < 8 or i + size > end) return;
        if (std.mem.eql(u8, &b, "mdia")) readMdia(ctx, bytes, i + 8, i + size);
        i += size;
    }
}

fn readMdia(ctx: anytype, bytes: []const u8, at: usize, end: usize) void {
    var i = at;
    while (i + 8 <= end) {
        const size = readU32(bytes, i);
        const b: [4]u8 = bytes[i + 4 .. i + 8][0..4].*;
        if (size < 8 or i + size > end) return;
        if (std.mem.eql(u8, &b, "mdhd")) {
            // version(1) flags(3) [creation, modification, timescale, duration]
            const version = bytes[i + 8];
            if (version == 1) {
                ctx.t.timescale = readU32(bytes, i + 8 + 4 + 16);
            } else {
                ctx.t.timescale = readU32(bytes, i + 8 + 4 + 8);
            }
            if (ctx.t.timescale == 0) ctx.t.timescale = 1000;
        } else if (std.mem.eql(u8, &b, "minf")) {
            var j = i + 8;
            while (j + 8 <= i + size) {
                const s2 = readU32(bytes, j);
                const b2: [4]u8 = bytes[j + 4 .. j + 8][0..4].*;
                if (s2 < 8 or j + s2 > i + size) break;
                if (std.mem.eql(u8, &b2, "stbl")) readStbl(ctx, bytes, j + 8, j + s2);
                j += s2;
            }
        }
        i += size;
    }
}

fn readStbl(ctx: anytype, bytes: []const u8, at: usize, end: usize) void {
    var stsd_at: usize = 0;
    var stsd_end: usize = 0;
    var stts: []const u8 = &.{};
    var stsc: []const u8 = &.{};
    var stsz: []const u8 = &.{};
    var stco: []const u8 = &.{};
    var co64: []const u8 = &.{};
    var ctts: []const u8 = &.{};
    var stss: []const u8 = &.{};

    var i = at;
    while (i + 8 <= end) {
        const size = readU32(bytes, i);
        const b: [4]u8 = bytes[i + 4 .. i + 8][0..4].*;
        if (size < 8 or i + size > end) return;
        const payload = bytes[i + 8 .. i + size];
        if (std.mem.eql(u8, &b, "stsd")) {
            stsd_at = i + 8;
            stsd_end = i + size;
        } else if (std.mem.eql(u8, &b, "stts")) stts = payload else if (std.mem.eql(u8, &b, "stsc")) stsc = payload else if (std.mem.eql(u8, &b, "stsz")) stsz = payload else if (std.mem.eql(u8, &b, "stco")) stco = payload else if (std.mem.eql(u8, &b, "co64")) co64 = payload else if (std.mem.eql(u8, &b, "ctts")) ctts = payload else if (std.mem.eql(u8, &b, "stss")) stss = payload;
        i += size;
    }

    // The sample entry: the first box inside stsd, after version+count.
    if (stsd_at != 0 and stsd_at + 16 <= stsd_end) {
        const entry_size = readU32(bytes, stsd_at + 8);
        const entry_start = stsd_at + 8;
        if (entry_size >= 8 and entry_start + entry_size <= stsd_end) {
            const entry = bytes[entry_start..][0..entry_size];
            ctx.gpa.free(ctx.t.sample_entry);
            ctx.t.sample_entry = ctx.gpa.dupe(u8, entry) catch "";
            // width/height sit at a fixed offset in a visual entry; channels
            // and rate in a sound one.
            if (ctx.t.kind == .video and entry.len >= 36 + 8) {
                ctx.t.width = readU16(entry, 32);
                ctx.t.height = readU16(entry, 34);
            } else if (ctx.t.kind == .audio and entry.len >= 28 + 8) {
                ctx.t.channels = readU16(entry, 24);
                ctx.t.sample_rate = readU16(entry, 32);
            }
        }
    }

    // Sizes: a constant, or one per sample.
    var sizes: std.ArrayList(u32) = .empty;
    defer sizes.deinit(ctx.gpa);
    var constant: u32 = 0;
    if (stsz.len >= 12) {
        constant = readU32(stsz, 4);
        const count = readU32(stsz, 8);
        if (constant == 0) {
            var n: usize = 0;
            while (n < count and 12 + (n + 1) * 4 <= stsz.len) : (n += 1) {
                sizes.append(ctx.gpa, readU32(stsz, 12 + n * 4)) catch break;
            }
        }
    }

    // Chunk offsets.
    var offsets: std.ArrayList(u64) = .empty;
    defer offsets.deinit(ctx.gpa);
    if (stco.len >= 8) {
        const count = readU32(stco, 4);
        var n: usize = 0;
        while (n < count and 8 + (n + 1) * 4 <= stco.len) : (n += 1) {
            offsets.append(ctx.gpa, readU32(stco, 8 + n * 4)) catch break;
        }
    } else if (co64.len >= 8) {
        const count = readU32(co64, 4);
        var n: usize = 0;
        while (n < count and 8 + (n + 1) * 8 <= co64.len) : (n += 1) {
            offsets.append(ctx.gpa, readU64(co64, 8 + n * 8)) catch break;
        }
    }

    // Which samples are in which chunk.
    const Stsc = struct { first_chunk: u32, per_chunk: u32 };
    var stsc_items: std.ArrayList(Stsc) = .empty;
    defer stsc_items.deinit(ctx.gpa);
    if (stsc.len >= 8) {
        const count = readU32(stsc, 4);
        var n: usize = 0;
        while (n < count and 8 + (n + 1) * 12 <= stsc.len) : (n += 1) {
            stsc_items.append(ctx.gpa, .{
                .first_chunk = readU32(stsc, 8 + n * 12),
                .per_chunk = readU32(stsc, 8 + n * 12 + 4),
            }) catch break;
        }
    }

    // Walk the chunks: each sample's offset is the chunk's plus the sizes
    // before it in that chunk.
    var sample_index: usize = 0;
    for (offsets.items, 0..) |chunk_at, chunk_i| {
        const chunk_number: u32 = @intCast(chunk_i + 1);
        var per: u32 = 1;
        for (stsc_items.items) |e| {
            if (e.first_chunk <= chunk_number) per = e.per_chunk else break;
        }
        var at_in_chunk: u64 = chunk_at;
        var k: u32 = 0;
        while (k < per) : (k += 1) {
            const size = if (constant != 0) constant else if (sample_index < sizes.items.len) sizes.items[sample_index] else break;
            const offset = at_in_chunk;
            at_in_chunk += size;
            ctx.t.samples.append(ctx.gpa, .{ .offset = offset, .size = size, .dts = 0, .duration = 0 }) catch return;
            sample_index += 1;
        }
    }

    // Decode times.
    var dts: u64 = 0;
    var s: usize = 0;
    if (stts.len >= 8) {
        const count = readU32(stts, 4);
        var n: usize = 0;
        while (n < count and 8 + (n + 1) * 8 <= stts.len) : (n += 1) {
            const run = readU32(stts, 8 + n * 8);
            const delta = readU32(stts, 8 + n * 8 + 4);
            var r: u32 = 0;
            while (r < run and s < ctx.t.samples.items.len) : (r += 1) {
                ctx.t.samples.items[s].dts = dts;
                ctx.t.samples.items[s].duration = delta;
                dts += delta;
                s += 1;
            }
        }
    }
    // A missing duration: the last one, or one tick.
    for (ctx.t.samples.items) |*sm| if (sm.duration == 0) {
        sm.duration = 1;
    };

    // Composition offsets.
    if (ctts.len >= 8) {
        const count = readU32(ctts, 4);
        var n: usize = 0;
        var idx: usize = 0;
        while (n < count and 8 + (n + 1) * 8 <= ctts.len) : (n += 1) {
            const run = readU32(ctts, 8 + n * 8);
            const off: i32 = @bitCast(readU32(ctts, 8 + n * 8 + 4));
            var r: u32 = 0;
            while (r < run and idx < ctx.t.samples.items.len) : (r += 1) {
                ctx.t.samples.items[idx].cts = off;
                idx += 1;
            }
        }
    }

    // Keyframes: every sample when there is no `stss`.
    if (stss.len >= 8) {
        const count = readU32(stss, 4);
        var n: usize = 0;
        while (n < count and 8 + (n + 1) * 4 <= stss.len) : (n += 1) {
            const one = readU32(stss, 8 + n * 4);
            if (one >= 1 and one <= ctx.t.samples.items.len) ctx.t.samples.items[one - 1].key = true;
        }
    } else {
        for (ctx.t.samples.items) |*sm| sm.key = true;
    }
}

pub fn readU16(b: []const u8, at: usize) u16 {
    if (at + 2 > b.len) return 0;
    return std.mem.readInt(u16, b[at..][0..2], .big);
}

pub fn readU32(b: []const u8, at: usize) u32 {
    if (at + 4 > b.len) return 0;
    return std.mem.readInt(u32, b[at..][0..4], .big);
}

pub fn readU64(b: []const u8, at: usize) u64 {
    if (at + 8 > b.len) return 0;
    return std.mem.readInt(u64, b[at..][0..8], .big);
}

pub fn writeU32(b: []u8, at: usize, v: u32) void {
    if (at + 4 > b.len) return;
    std.mem.writeInt(u32, b[at..][0..4], v, .big);
}
