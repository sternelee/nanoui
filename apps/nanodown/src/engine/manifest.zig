//! Manifests read for their renditions: an HLS master playlist or a DASH MPD
//! names every quality it holds, and each becomes a format the list can show
//! and `-q` can pick.
const std = @import("std");
const media = @import("../model/media.zig");
const hls = @import("hls.zig");
const dash = @import("dash.zig");
const extract = @import("extract.zig");

pub fn expandHls(gpa: std.mem.Allocator, base: []const u8, manifest_url: []const u8, out: *std.ArrayList(media.Format)) !void {
    var r = extract.fetch(gpa, manifest_url, base);
    defer r.deinit();
    if (r.status() == 0 or r.body().len == 0) return;
    var p = hls.parse(gpa, manifest_url, r.body()) catch return;
    defer p.deinit(gpa);
    // A DRM stream is offered as a format only so the refusal can be read:
    // listing it as downloadable would be a promise the engine cannot keep.
    if (p.isDrm()) return;
    if (!p.isMaster()) {
        try out.append(gpa, .{
            .id = try gpa.dupe(u8, "hls"),
            .label = try gpa.dupe(u8, "Auto"),
            .ext = try gpa.dupe(u8, "mp4"),
            .manifest = .{ .hls = try gpa.dupe(u8, manifest_url) },
            .kind = .video,
            .duration = p.duration(),
        });
        return;
    }
    for (p.variants.items) |v| {
        try out.append(gpa, .{
            .id = try gpa.dupe(u8, v.url),
            .label = try gpa.dupe(u8, v.label),
            .ext = try gpa.dupe(u8, "mp4"),
            .manifest = .{ .hls = try gpa.dupe(u8, v.url) },
            .kind = .video,
            .width = v.width,
            .height = v.height,
            .bitrate = v.bandwidth,
            .codec = try gpa.dupe(u8, v.codecs),
        });
    }
}

pub fn expandDash(gpa: std.mem.Allocator, base: []const u8, manifest_url: []const u8, out: *std.ArrayList(media.Format)) !void {
    var r = extract.fetch(gpa, manifest_url, base);
    defer r.deinit();
    if (r.status() == 0 or r.body().len == 0) return;
    var m = dash.parse(gpa, manifest_url, r.body()) catch return;
    defer m.deinit(gpa);
    for (m.reps.items) |rep| {
        try out.append(gpa, .{
            .id = try gpa.dupe(u8, rep.id),
            .label = try gpa.dupe(u8, rep.label),
            .ext = try gpa.dupe(u8, "mp4"),
            .manifest = .{ .dash = try gpa.dupe(u8, manifest_url) },
            .kind = if (rep.kind == .audio) .audio else .video,
            .width = rep.width,
            .height = rep.height,
            .bitrate = rep.bandwidth,
            .codec = try gpa.dupe(u8, rep.codecs),
            .duration = rep.seconds(),
        });
    }
}
