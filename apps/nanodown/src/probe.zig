//! Reads one link and prints what the engine made of it, for checking a site
//! by hand: `zig build probe -- <url>`. Not part of the app.
const std = @import("std");
const extract = @import("engine/extract.zig");
const job = @import("engine/job.zig");
const media = @import("model/media.zig");
const now = @import("now.zig");

pub fn main(init: std.process.Init) !void {
    const args = try init.minimal.args.toSlice(init.arena.allocator());
    if (args.len < 2) {
        std.debug.print("usage: probe <url> [--get <dir>]\n", .{});
        return;
    }
    var get_dir: []const u8 = "";
    if (args.len >= 4 and std.mem.eql(u8, args[2], "--get")) get_dir = args[3];
    const gpa = init.gpa;
    var m = extract.read(gpa, args[1], 0) catch |e| {
        std.debug.print("FAIL {s}: {s}\n", .{ args[1], @errorName(e) });
        return;
    };
    defer m.deinit(gpa);
    var buf: [4096]u8 = undefined;
    var out = std.Io.File.stdout().writer(now.io(), &buf);
    const o = &out.interface;
    try o.print("site={s} title={s} formats={d}\n", .{ m.site.title(), m.title, m.formats.len });
    if (m.author.len > 0) try o.print("author={s}\n", .{m.author});
    if (m.problem.len > 0) try o.print("problem={s}\n", .{m.problem});
    for (m.formats) |f| {
        const url = if (f.url.len > 0) f.url else if (f.manifest) |mf| switch (mf) {
            .hls => |u| u,
            .dash => |u| u,
        } else "";
        try o.print("  [{s}] {s} {s} {d}x{d} {d}kbps {s}\n", .{
            @tagName(f.kind), f.id, f.ext, f.width, f.height, f.bitrate / 1000, url,
        });
    }
    // `--get` downloads the best format, so an extractor is proved by a file
    // on disk and not only by a list of URLs.
    if (get_dir.len > 0 and m.formats.len > 0) {
        const f = m.best(.video, 0) orelse m.best(.audio, 0) orelse m.formats[0];
        var dest_buf: [1024]u8 = undefined;
        const dest = std.fmt.bufPrint(&dest_buf, "{s}/{s}", .{ get_dir, "probe-out" }) catch return;
        var shared = job.Shared{};
        job.run(.{
            .gpa = gpa,
            .url = m.url,
            .referer = m.url,
            .format = f,
            .dest = dest,
            .ext = f.ext,
            .tags = .{ .title = m.title, .artist = m.author, .date = m.date, .link = m.url },
        }, &shared);
        try o.print("get: ok={} stage={d} wrote={s} problem={s}\n", .{ shared.ok.load(.acquire), shared.stage.load(.acquire), shared.wrote(), shared.why() });
    }
    try o.flush();
}
