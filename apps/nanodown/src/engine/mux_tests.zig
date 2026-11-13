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

/// A one-sample video MP4, for the test above.
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
