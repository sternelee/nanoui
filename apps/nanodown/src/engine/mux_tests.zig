//! The muxer's tests, and the tiny MP4 they read.
const std = @import("std");
const mux = @import("mux.zig");
const mux_write = @import("mux_write.zig");

test "an ISO box is read" {
    const bytes = [_]u8{ 0, 0, 0, 16, 'f', 't', 'y', 'p', 'i', 's', 'o', 'm', 0, 0, 0, 0 };
    var seen: usize = 0;
    const Ctx = struct {
        fn visit(n: *usize, b: mux.Box) bool {
            if (std.mem.eql(u8, &b.name(), "ftyp")) n.* += 1;
            return true;
        }
    };
    mux.walk(&bytes, 0, bytes.len, &seen, Ctx.visit);
    try std.testing.expectEqual(@as(usize, 1), seen);
}

test "a track is read from a small MP4" {
    // A minimal file: ftyp, moov/trak/mdia/hdlr(vide)/minf/stbl with one
    // sample, and an mdat holding it.
    const gpa = std.testing.allocator;
    const file = try buildTinyMp4(gpa);
    defer gpa.free(file);
    var t = try mux.readTrack(gpa, file, .video);
    defer t.deinit(gpa);
    try std.testing.expectEqual(@as(usize, 1), t.samples.items.len);
    try std.testing.expectEqual(@as(u32, 4), t.samples.items[0].size);
    try std.testing.expectEqual(@as(u32, 1000), t.timescale);
    try std.testing.expectEqual(@as(usize, 1), t.mdats.items.len);
}

// A minimal fMP4 fragment test.

test "an fMP4 track's fragments (moov + mvex + moof/traf/trun) are read" {
    const gpa = std.testing.allocator;
    // Minimal fMP4: ftyp + moov(trak(mdia(mdhd, hdlr(vide), minf(stbl(stsd)))) + mvex(trex)) + moof(mfhd + traf(tfhd, tfdt, trun)) + mdat
    var out: std.Io.Writer.Allocating = .init(gpa);
    defer out.deinit();
    const w = &out.writer;
    try w.writeInt(u32, 16, .big);
    try w.writeAll("ftypisom");
    try w.writeInt(u32, 0, .big);

    var stsd: std.Io.Writer.Allocating = .init(gpa);
    defer stsd.deinit();
    try stsd.writer.writeInt(u32, 32, .big);
    try stsd.writer.writeAll("stsd");
    try stsd.writer.writeInt(u32, 0, .big);
    try stsd.writer.writeInt(u32, 1, .big);
    try stsd.writer.writeInt(u32, 16, .big);
    try stsd.writer.writeAll("avc1");
    try stsd.writer.writeInt(u32, 0, .big);
    try stsd.writer.writeInt(u32, 0, .big);

    var stbl: std.Io.Writer.Allocating = .init(gpa);
    defer stbl.deinit();
    try stbl.writer.writeInt(u32, @intCast(8 + stsd.writer.end), .big);
    try stbl.writer.writeAll("stbl");
    try stbl.writer.writeAll(stsd.writer.buffered());

    var minf: std.Io.Writer.Allocating = .init(gpa);
    defer minf.deinit();
    try minf.writer.writeInt(u32, @intCast(8 + stbl.writer.end), .big);
    try minf.writer.writeAll("minf");
    try minf.writer.writeAll(stbl.writer.buffered());

    var mdia: std.Io.Writer.Allocating = .init(gpa);
    defer mdia.deinit();
    try mdia.writer.writeInt(u32, 32, .big);
    try mdia.writer.writeAll("mdhd");
    try mdia.writer.writeInt(u32, 0, .big);
    try mdia.writer.writeInt(u32, 0, .big);
    try mdia.writer.writeInt(u32, 0, .big);
    try mdia.writer.writeInt(u32, 1000, .big);
    try mdia.writer.writeInt(u32, 1000, .big);
    try mdia.writer.writeInt(u32, 0, .big);
    try mdia.writer.writeInt(u32, 24, .big);
    try mdia.writer.writeAll("hdlr");
    try mdia.writer.writeInt(u32, 0, .big);
    try mdia.writer.writeInt(u32, 0, .big);
    try mdia.writer.writeAll("vide");
    try mdia.writer.writeInt(u32, 0, .big);
    try mdia.writer.writeInt(u32, @intCast(8 + minf.writer.end), .big);
    try mdia.writer.writeAll("minf");
    try mdia.writer.writeAll(minf.writer.buffered());

    var trak: std.Io.Writer.Allocating = .init(gpa);
    defer trak.deinit();
    try trak.writer.writeInt(u32, @intCast(8 + mdia.writer.end), .big);
    try trak.writer.writeAll("trak");
    try trak.writer.writeAll(mdia.writer.buffered());

    var moov: std.Io.Writer.Allocating = .init(gpa);
    defer moov.deinit();
    try moov.writer.writeInt(u32, @intCast(8 + trak.writer.end), .big);
    try moov.writer.writeAll("moov");
    try moov.writer.writeAll(trak.writer.buffered());
    try w.writeAll(moov.writer.buffered());

    // Build moof: tfhd(default-base-is-moof 0x020000) + trun(data-offset 0x01 + dur 0x100 + size 0x200)
    // Header sizes: moof(8) + traf(8) + tfhd(16) + trun(20 + 8 = 28) = 60 bytes; mdat header = 8 -> data_offset = 68.
    try w.writeInt(u32, 60, .big);
    try w.writeAll("moof");
    try w.writeInt(u32, 52, .big);
    try w.writeAll("traf");
    try w.writeInt(u32, 16, .big);
    try w.writeAll("tfhd");
    try w.writeInt(u32, 0x00020000, .big);
    try w.writeInt(u32, 1, .big);
    try w.writeInt(u32, 28, .big);
    try w.writeAll("trun");
    try w.writeInt(u32, 0x00000301, .big);
    try w.writeInt(u32, 1, .big);
    try w.writeInt(u32, 68, .big); // data_offset
    try w.writeInt(u32, 500, .big); // duration
    try w.writeInt(u32, 4, .big); // size
    try w.writeInt(u32, 12, .big);
    try w.writeAll("mdat");
    try w.writeAll("DATA");

    const bytes = try out.toOwnedSlice();
    defer gpa.free(bytes);
    var t = try mux.readTrack(gpa, bytes, .video);
    defer t.deinit(gpa);
    try std.testing.expectEqual(@as(usize, 1), t.samples.items.len);
    try std.testing.expectEqual(@as(u32, 4), t.samples.items[0].size);
    try std.testing.expectEqual(@as(u32, 500), t.samples.items[0].duration);
}
pub fn buildTinyMp4(gpa: std.mem.Allocator) ![]u8 {
    var out: std.Io.Writer.Allocating = .init(gpa);
    errdefer out.deinit();
    const w = &out.writer;

    // ftyp
    try w.writeInt(u32, 16, .big);
    try w.writeAll("ftypisom");
    try w.writeInt(u32, 0, .big);

    // stbl: stsd, stts, stsc, stsz, stco.
    var stbl: std.Io.Writer.Allocating = .init(gpa);
    defer stbl.deinit();
    const s = &stbl.writer;
    try s.writeInt(u32, 32, .big); // stsd: 8 + 4 + 4 + 16
    try s.writeAll("stsd");
    try s.writeInt(u32, 0, .big);
    try s.writeInt(u32, 1, .big);
    try s.writeInt(u32, 16, .big);
    try s.writeAll("avc1");
    try s.writeInt(u32, 0, .big);
    try s.writeInt(u32, 0, .big);
    try s.writeInt(u32, 24, .big); // stts: one sample, 1000 ticks
    try s.writeAll("stts");
    try s.writeInt(u32, 0, .big);
    try s.writeInt(u32, 1, .big);
    try s.writeInt(u32, 1, .big);
    try s.writeInt(u32, 1000, .big);
    try s.writeInt(u32, 28, .big); // stsc
    try s.writeAll("stsc");
    try s.writeInt(u32, 0, .big);
    try s.writeInt(u32, 1, .big);
    try s.writeInt(u32, 1, .big);
    try s.writeInt(u32, 1, .big);
    try s.writeInt(u32, 1, .big);
    try s.writeInt(u32, 24, .big); // stsz: one sample of 4 bytes
    try s.writeAll("stsz");
    try s.writeInt(u32, 0, .big);
    try s.writeInt(u32, 0, .big);
    try s.writeInt(u32, 1, .big);
    try s.writeInt(u32, 4, .big);
    try s.writeInt(u32, 20, .big); // stco: one chunk at 0
    try s.writeAll("stco");
    try s.writeInt(u32, 0, .big);
    try s.writeInt(u32, 1, .big);
    try s.writeInt(u32, 0, .big);

    const stbl_box = try wrap(gpa, "stbl", &.{stbl.writer.buffered()});
    defer gpa.free(stbl_box);
    const minf = try wrap(gpa, "minf", &.{stbl_box});
    defer gpa.free(minf);

    var mdhd: std.Io.Writer.Allocating = .init(gpa);
    defer mdhd.deinit();
    try mdhd.writer.writeInt(u32, 0, .big);
    try mdhd.writer.writeInt(u32, 0, .big);
    try mdhd.writer.writeInt(u32, 0, .big);
    try mdhd.writer.writeInt(u32, 1000, .big);
    try mdhd.writer.writeInt(u32, 1000, .big);
    try mdhd.writer.writeInt(u32, 0, .big);
    const mdhd_box = try wrap(gpa, "mdhd", &.{mdhd.writer.buffered()});
    defer gpa.free(mdhd_box);

    var hdlr: std.Io.Writer.Allocating = .init(gpa);
    defer hdlr.deinit();
    try hdlr.writer.writeInt(u32, 0, .big);
    try hdlr.writer.writeInt(u32, 0, .big);
    try hdlr.writer.writeAll("vide");
    try hdlr.writer.writeInt(u32, 0, .big);
    try hdlr.writer.writeInt(u32, 0, .big);
    try hdlr.writer.writeInt(u32, 0, .big);
    try hdlr.writer.writeInt(u32, 0, .big);
    const hdlr_box = try wrap(gpa, "hdlr", &.{hdlr.writer.buffered()});
    defer gpa.free(hdlr_box);

    const mdia = try wrap(gpa, "mdia", &.{ mdhd_box, hdlr_box, minf });
    defer gpa.free(mdia);
    const trak = try wrap(gpa, "trak", &.{mdia});
    defer gpa.free(trak);
    const moov = try wrap(gpa, "moov", &.{trak});
    defer gpa.free(moov);

    try w.writeAll(moov);

    // mdat: four bytes
    try w.writeInt(u32, 12, .big);
    try w.writeAll("mdat");
    try w.writeAll("data");
    return out.toOwnedSlice();
}

/// A box around already-built payloads.
fn wrap(gpa: std.mem.Allocator, kind: *const [4]u8, parts: []const []const u8) ![]u8 {
    var total: usize = 8;
    for (parts) |p| total += p.len;
    const out = try gpa.alloc(u8, total);
    std.mem.writeInt(u32, out[0..4], @intCast(total), .big);
    @memcpy(out[4..8], kind);
    var at: usize = 8;
    for (parts) |p| {
        @memcpy(out[at..][0..p.len], p);
        at += p.len;
    }
    return out;
}
