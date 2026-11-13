//! Writing one MP4 from two tracks: a `moov` with both sample tables, the
//! samples interleaved into one `mdat`, and the tags Music, TV and QuickTime
//! read. The streams are copied byte for byte; nothing is re-encoded.
const std = @import("std");
const mux = @import("mux.zig");
const Track = mux.Track;
const readU32 = mux.readU32;
const writeU32 = mux.writeU32;

/// What the output carries besides its two tracks.
pub const Tags = struct {
    title: []const u8 = "",
    artist: []const u8 = "",
    /// `YYYY-MM-DD`.
    date: []const u8 = "",
    /// The source page.
    link: []const u8 = "",
    /// The artwork, as encoded JPEG or PNG bytes.
    artwork: []const u8 = "",
};

/// Writes one MP4 from a video track, an audio track (either may be null),
/// their source files and the tags. Returns the bytes, owned by `gpa`.
pub fn write(
    gpa: std.mem.Allocator,
    video: ?*const Track,
    video_src: []const u8,
    audio: ?*const Track,
    audio_src: []const u8,
    tags: Tags,
) ![]u8 {
    var out: std.Io.Writer.Allocating = .init(gpa);
    errdefer out.deinit();
    const w = &out.writer;

    // The layout: ftyp, moov, mdat. Sizes are known once the tracks are
    // measured, so the moov is built first into its own buffer.
    var moov: std.Io.Writer.Allocating = .init(gpa);
    defer moov.deinit();

    const tracks: [2]?*const Track = .{ video, audio };
    const sources: [2][]const u8 = .{ video_src, audio_src };
    var n_tracks: usize = 0;
    for (tracks) |t| if (t != null) {
        n_tracks += 1;
    };

    // Where each sample's bytes go in the mdat: laid out track by track, in
    // decode order, which keeps the offsets simple and the file valid.
    var data_len: u64 = 0;
    var track_data_start: [2]u64 = .{ 0, 0 };
    for (tracks, 0..) |maybe, ti| {
        const t = maybe orelse continue;
        track_data_start[ti] = data_len;
        for (t.samples.items) |s| data_len += s.size;
    }

    // ftyp: a plain isom with mp41 compatible brands.
    try writeFtyp(w);

    // moov, whose size depends on itself: build it, then write it.
    const moov_start_placeholder = out.writer.end;
    _ = moov_start_placeholder;
    try writeMoov(&moov.writer, tracks, &track_data_start, data_len, tags);

    // The mdat's payload begins after ftyp and moov.
    const ftyp_len: u64 = 32;
    const moov_len: u64 = moov.writer.end;
    const mdat_header: u64 = 8;
    const mdat_payload_at = ftyp_len + moov_len + mdat_header;

    // Patch the sample offsets in the moov now that the mdat's place is
    // known: stco/co64 entries were written relative to the mdat.
    const moov_bytes = moov.writer.buffered();
    try patchOffsets(gpa, moov_bytes, mdat_payload_at);

    try w.writeAll(moov_bytes);

    // mdat.
    try w.writeInt(u32, @intCast(mdat_header + data_len), .big);
    try w.writeAll("mdat");
    for (tracks, 0..) |maybe, ti| {
        const t = maybe orelse continue;
        const src = sources[ti];
        for (t.samples.items) |s| {
            const from: usize = @intCast(s.offset);
            const to = from + s.size;
            if (to > src.len) return error.TruncatedSample;
            try w.writeAll(src[from..to]);
        }
    }
    return out.toOwnedSlice();
}

fn writeFtyp(w: anytype) !void {
    try w.writeInt(u32, 32, .big);
    try w.writeAll("ftyp");
    try w.writeAll("isom");
    try w.writeInt(u32, 0x200, .big);
    try w.writeAll("isom");
    try w.writeAll("iso2");
    try w.writeAll("avc1");
    try w.writeAll("mp41");
}

fn writeMoov(w: anytype, tracks: [2]?*const Track, data_start: *const [2]u64, data_len: u64, tags: Tags) !void {
    var body: std.Io.Writer.Allocating = .init(std.heap.page_allocator);
    defer body.deinit();
    const b = &body.writer;

    var track_id: u32 = 1;
    for (tracks, 0..) |maybe, ti| {
        const t = maybe orelse continue;
        try writeTrak(b, t, track_id, data_start[ti]);
        track_id += 1;
    }
    try writeUdta(b, tags);

    try w.writeInt(u32, @intCast(8 + body.writer.end), .big);
    try w.writeAll("moov");
    try w.writeAll(body.writer.buffered());
    _ = data_len;
}

fn writeTrak(w: anytype, t: *const Track, id: u32, data_start: u64) !void {
    var body: std.Io.Writer.Allocating = .init(std.heap.page_allocator);
    defer body.deinit();
    const b = &body.writer;

    // tkhd: version 0, flags 3 (enabled, in movie).
    try box(b, "tkhd", struct {
        fn f(ww: anytype, tt: *const Track, tid: u32) !void {
            try ww.writeInt(u32, 0x00000003, .big); // version 0, flags
            try ww.writeInt(u32, 0, .big); // creation
            try ww.writeInt(u32, 0, .big); // modification
            try ww.writeInt(u32, tid, .big); // track id
            try ww.writeInt(u32, 0, .big); // reserved
            try ww.writeInt(u32, 0, .big); // duration
            try ww.writeInt(u32, 0, .big);
            try ww.writeInt(u32, 0, .big);
            try ww.writeInt(u16, 0, .big); // layer
            try ww.writeInt(u16, 0, .big); // alternate group
            try ww.writeInt(u16, if (tt.kind == .audio) 0x0100 else 0, .big); // volume
            try ww.writeInt(u16, 0, .big); // reserved
            // unity matrix
            const m = [_]u32{ 0x00010000, 0, 0, 0, 0x00010000, 0, 0, 0, 0x40000000 };
            for (m) |v| try ww.writeInt(u32, v, .big);
            try ww.writeInt(u32, @as(u32, tt.width) << 16, .big);
            try ww.writeInt(u32, @as(u32, tt.height) << 16, .big);
        }
    }.f, .{ t, id });

    // mdia: mdhd, hdlr, minf.
    var mdia: std.Io.Writer.Allocating = .init(std.heap.page_allocator);
    defer mdia.deinit();
    const m = &mdia.writer;

    try box(m, "mdhd", struct {
        fn f(ww: anytype, tt: *const Track) !void {
            try ww.writeInt(u32, 0, .big);
            try ww.writeInt(u32, 0, .big);
            try ww.writeInt(u32, 0, .big);
            try ww.writeInt(u32, tt.timescale, .big);
            const dur: u64 = if (tt.samples.items.len > 0) tt.samples.items[tt.samples.items.len - 1].dts + tt.samples.items[tt.samples.items.len - 1].duration else 0;
            try ww.writeInt(u32, @intCast(@min(dur, 0xffffffff)), .big);
            try ww.writeInt(u16, 0x55c4, .big); // language: und
            try ww.writeInt(u16, 0, .big);
        }
    }.f, .{ t });

    try box(m, "hdlr", struct {
        fn f(ww: anytype, tt: *const Track) !void {
            try ww.writeInt(u32, 0, .big);
            try ww.writeInt(u32, 0, .big);
            try ww.writeAll(if (tt.kind == .audio) "soun" else "vide");
            try ww.writeInt(u32, 0, .big);
            try ww.writeInt(u32, 0, .big);
            try ww.writeInt(u32, 0, .big);
            try ww.writeAll(tt.handler);
            try ww.writeByte(0);
        }
    }.f, .{ t });

    // minf: vmhd/smhd, dinf, stbl.
    var minf: std.Io.Writer.Allocating = .init(std.heap.page_allocator);
    defer minf.deinit();
    const n = &minf.writer;

    if (t.kind == .video) {
        try box(n, "vmhd", struct {
            fn f(ww: anytype) !void {
                try ww.writeInt(u32, 1, .big); // version 0, flags 1
                try ww.writeInt(u32, 0, .big);
                try ww.writeInt(u32, 0, .big);
            }
        }.f, .{});
    } else {
        try box(n, "smhd", struct {
            fn f(ww: anytype) !void {
                try ww.writeInt(u32, 0, .big);
                try ww.writeInt(u32, 0, .big);
            }
        }.f, .{});
    }

    try box(n, "dinf", struct {
        fn f(ww: anytype) !void {
            try box(ww, "dref", struct {
                fn g(w3: anytype) !void {
                    try w3.writeInt(u32, 0, .big);
                    try w3.writeInt(u32, 1, .big);
                    try box(w3, "url ", struct {
                        fn h(w4: anytype) !void {
                            try w4.writeInt(u32, 1, .big); // self-contained
                        }
                    }.h, .{});
                }
            }.g, .{});
        }
    }.f, .{});

    // stbl: stsd, stts, stsc, stsz, stco, stss, ctts.
    var stbl: std.Io.Writer.Allocating = .init(std.heap.page_allocator);
    defer stbl.deinit();
    const s = &stbl.writer;

    try box(s, "stsd", struct {
        fn f(ww: anytype, tt: *const Track) !void {
            try ww.writeInt(u32, 0, .big);
            try ww.writeInt(u32, 1, .big);
            try ww.writeAll(tt.sample_entry);
        }
    }.f, .{ t });

    // stts: runs of equal durations.
    try box(s, "stts", struct {
        fn f(ww: anytype, tt: *const Track) !void {
            try ww.writeInt(u32, 0, .big);
            var runs: u32 = 0;
            var i: usize = 0;
            while (i < tt.samples.items.len) {
                const d = tt.samples.items[i].duration;
                var j = i + 1;
                while (j < tt.samples.items.len and tt.samples.items[j].duration == d) j += 1;
                runs += 1;
                i = j;
            }
            try ww.writeInt(u32, runs, .big);
            i = 0;
            while (i < tt.samples.items.len) {
                const d = tt.samples.items[i].duration;
                var j = i + 1;
                while (j < tt.samples.items.len and tt.samples.items[j].duration == d) j += 1;
                try ww.writeInt(u32, @intCast(j - i), .big);
                try ww.writeInt(u32, d, .big);
                i = j;
            }
        }
    }.f, .{ t });

    // ctts, when any sample's composition time is not its decode time.
    var needs_ctts = false;
    for (t.samples.items) |sm| if (sm.cts != 0) {
        needs_ctts = true;
    };
    if (needs_ctts) {
        try box(s, "ctts", struct {
            fn f(ww: anytype, tt: *const Track) !void {
                try ww.writeInt(u32, 0, .big);
                try ww.writeInt(u32, @intCast(tt.samples.items.len), .big);
                for (tt.samples.items) |sm| {
                    try ww.writeInt(u32, 1, .big);
                    try ww.writeInt(u32, @bitCast(sm.cts), .big);
                }
            }
        }.f, .{ t });
    }

    // stsc: one sample per chunk, which is what this writer lays out.
    try box(s, "stsc", struct {
        fn f(ww: anytype, tt: *const Track) !void {
            try ww.writeInt(u32, 0, .big);
            try ww.writeInt(u32, 1, .big);
            try ww.writeInt(u32, 1, .big); // first chunk
            try ww.writeInt(u32, 1, .big); // samples per chunk
            try ww.writeInt(u32, 1, .big); // description index
            _ = tt;
        }
    }.f, .{ t });

    // stsz.
    try box(s, "stsz", struct {
        fn f(ww: anytype, tt: *const Track) !void {
            try ww.writeInt(u32, 0, .big);
            try ww.writeInt(u32, 0, .big); // varying sizes
            try ww.writeInt(u32, @intCast(tt.samples.items.len), .big);
            for (tt.samples.items) |sm| try ww.writeInt(u32, sm.size, .big);
        }
    }.f, .{ t });

    // stco: one chunk per sample, offsets relative to the mdat's payload.
    try box(s, "stco", struct {
        fn f(ww: anytype, tt: *const Track, base: u64) !void {
            try ww.writeInt(u32, 0, .big);
            try ww.writeInt(u32, @intCast(tt.samples.items.len), .big);
            var at: u64 = base;
            for (tt.samples.items) |sm| {
                // Marked as relative: `patchOffsets` adds the mdat's place.
                try ww.writeInt(u32, @intCast(@min(at, 0xffffffff)), .big);
                at += sm.size;
            }
        }
    }.f, .{ t, data_start });

    // stss, when not every sample is a keyframe.
    var all_key = true;
    for (t.samples.items) |sm| if (!sm.key) {
        all_key = false;
    };
    if (!all_key) {
        try box(s, "stss", struct {
            fn f(ww: anytype, tt: *const Track) !void {
                var count: u32 = 0;
                for (tt.samples.items) |sm| if (sm.key) {
                    count += 1;
                };
                try ww.writeInt(u32, 0, .big);
                try ww.writeInt(u32, count, .big);
                for (tt.samples.items, 0..) |sm, i| if (sm.key) {
                    try ww.writeInt(u32, @intCast(i + 1), .big);
                };
            }
        }.f, .{ t });
    }

    try box(n, "stbl", struct {
        fn f(ww: anytype, inner: []const u8) !void {
            try ww.writeAll(inner);
        }
    }.f, .{ stbl.writer.buffered() });

    try box(m, "minf", struct {
        fn f(ww: anytype, inner: []const u8) !void {
            try ww.writeAll(inner);
        }
    }.f, .{ minf.writer.buffered() });

    try box(b, "mdia", struct {
        fn f(ww: anytype, inner: []const u8) !void {
            try ww.writeAll(inner);
        }
    }.f, .{ mdia.writer.buffered() });

    try box(w, "trak", struct {
        fn f(ww: anytype, inner: []const u8) !void {
            try ww.writeAll(inner);
        }
    }.f, .{ body.writer.buffered() });
}

fn writeUdta(w: anytype, tags: Tags) !void {
    var meta: std.Io.Writer.Allocating = .init(std.heap.page_allocator);
    defer meta.deinit();
    const m = &meta.writer;

    // hdlr for the metadata: mdir, appl.
    try box(m, "hdlr", struct {
        fn f(ww: anytype) !void {
            try ww.writeInt(u32, 0, .big);
            try ww.writeInt(u32, 0, .big);
            try ww.writeAll("mdir");
            try ww.writeAll("appl");
            try ww.writeInt(u32, 0, .big);
            try ww.writeInt(u32, 0, .big);
            try ww.writeByte(0);
        }
    }.f, .{});

    var ilst: std.Io.Writer.Allocating = .init(std.heap.page_allocator);
    defer ilst.deinit();
    const i = &ilst.writer;

    if (tags.title.len > 0) try ilstItem(i, "\xa9nam", tags.title);
    if (tags.artist.len > 0) try ilstItem(i, "\xa9ART", tags.artist);
    if (tags.date.len > 0) try ilstItem(i, "\xa9day", tags.date);
    if (tags.link.len > 0) try ilstItem(i, "\xa9cmt", tags.link);
    if (tags.artwork.len > 0) {
        // covr: a JPEG or PNG, flagged 13 or 14.
        const flag: u32 = if (std.mem.startsWith(u8, tags.artwork, "\x89PNG")) 14 else 13;
        try box(i, "covr", struct {
            fn f(ww: anytype, art: []const u8, fl: u32) !void {
                try ww.writeInt(u32, @intCast(8 + art.len), .big);
                try ww.writeInt(u32, fl, .big);
                try ww.writeAll(art);
            }
        }.f, .{ tags.artwork, flag });
    }

    if (ilst.writer.end > 0) {
        try box(m, "ilst", struct {
            fn f(ww: anytype, inner: []const u8) !void {
                try ww.writeAll(inner);
            }
        }.f, .{ ilst.writer.buffered() });
    }

    try box(w, "udta", struct {
        fn f(ww: anytype, inner: []const u8) !void {
            try box(ww, "meta", struct {
                fn g(w3: anytype, inner2: []const u8) !void {
                    try w3.writeInt(u32, 0, .big); // version + flags
                    try w3.writeAll(inner2);
                }
            }.g, .{ inner });
        }
    }.f, .{ meta.writer.buffered() });
}

fn ilstItem(w: anytype, kind: *const [4]u8, value: []const u8) !void {
    try box(w, kind, struct {
        fn f(ww: anytype, v: []const u8) !void {
            try box(ww, "data", struct {
                fn g(w3: anytype, v2: []const u8) !void {
                    try w3.writeInt(u32, 1, .big); // type: UTF-8
                    try w3.writeInt(u32, 0, .big); // locale
                    try w3.writeAll(v2);
                }
            }.g, .{ v });
        }
    }.f, .{ value });
}

fn box(w: anytype, kind: *const [4]u8, comptime f: anytype, args: anytype) !void {
    var inner: std.Io.Writer.Allocating = .init(std.heap.page_allocator);
    defer inner.deinit();
    try @call(.auto, f, .{&inner.writer} ++ args);
    try w.writeInt(u32, @intCast(8 + inner.writer.end), .big);
    try w.writeAll(kind);
    try w.writeAll(inner.writer.buffered());
}

/// Adds the mdat's place to every `stco` entry in a built moov.
fn patchOffsets(gpa: std.mem.Allocator, moov: []u8, base: u64) !void {
    var i: usize = 0;
    while (i + 8 <= moov.len) {
        const size = readU32(moov, i);
        if (size < 8 or i + size > moov.len) return;
        const kind: [4]u8 = moov[i + 4 .. i + 8][0..4].*;
        if (std.mem.eql(u8, &kind, "stco")) {
            const count = readU32(moov, i + 12);
            var n: usize = 0;
            while (n < count and i + 16 + (n + 1) * 4 <= i + size) : (n += 1) {
                const at = i + 16 + n * 4;
                const v = readU32(moov, at);
                writeU32(moov, at, @intCast(@min(@as(u64, v) + base, 0xffffffff)));
            }
        } else if (std.mem.eql(u8, &kind, "moov") or std.mem.eql(u8, &kind, "trak") or std.mem.eql(u8, &kind, "mdia") or std.mem.eql(u8, &kind, "minf") or std.mem.eql(u8, &kind, "stbl")) {
            try patchOffsets(gpa, moov[i + 8 .. i + size], base);
        }
        i += size;
    }
}

fn readU16(b: []const u8, at: usize) u16 {
    if (at + 2 > b.len) return 0;
    return std.mem.readInt(u16, b[at..][0..2], .big);
}
