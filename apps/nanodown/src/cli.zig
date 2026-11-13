//! The command: `nanodown get <url>`, `info`, `formats`, `list`, `subs`,
//! `settings`, `sites`. The same binary as the window, and the same settings
//! and library, so what it downloads shows in the app.
const std = @import("std");
const nanoui = @import("nanoui");
const media = @import("model/media.zig");
const download = @import("model/download.zig");
const library = @import("model/library.zig");
const settings = @import("model/settings.zig");
const license = @import("model/license.zig");
const extract = @import("engine/extract.zig");
const job = @import("engine/job.zig");
const mux_write = @import("engine/mux_write.zig");
const subscription = @import("model/subscription.zig");
const now = @import("now.zig");

const usage =
    \\nanodown — download videos and audio from the web
    \\
    \\  nanodown get <url>…        download it
    \\    -o, --output DIR         where to save it
    \\    -a, --audio              sound only
    \\    -q, --quality Q          best, 2160, 1440, 1080, 720, 480, 360
    \\    -f, --format IDS         the site's own format ids
    \\    -c, --connections N      how many at once (default 4)
    \\  nanodown info <url>        what it is
    \\  nanodown formats <url>     every quality it comes in
    \\  nanodown list              what has been downloaded
    \\  nanodown subs              the channels and playlists followed
    \\  nanodown settings          every setting, as it stands
    \\  nanodown sites             the sites it knows
    \\  nanodown open [url…]       the window, with a link in it
    \\
    \\Every command takes --json.
    \\
;

pub fn run(init: std.process.Init, args: []const []const u8) !u8 {
    const gpa = init.gpa;
    const command = args[0];
    const rest = args[1..];
    var json = false;
    for (rest) |a| if (std.mem.eql(u8, a, "--json")) {
        json = true;
    };

    if (std.mem.eql(u8, command, "help") or std.mem.eql(u8, command, "--help")) {
        try std.Io.File.stdout().writeStreamingAll(init.io, usage);
        return 0;
    }
    if (std.mem.eql(u8, command, "sites")) return sites(init, json);
    if (std.mem.eql(u8, command, "settings")) return showSettings(init, json);
    if (std.mem.eql(u8, command, "list")) return list(init, json);
    if (std.mem.eql(u8, command, "subs")) return subs(init, json);
    if (std.mem.eql(u8, command, "info")) return info(init, rest, json);
    if (std.mem.eql(u8, command, "formats")) return formats(init, rest, json);
    if (std.mem.eql(u8, command, "get")) return get(init, rest, json);

    std.debug.print("nanodown: no such command: {s}\n\n{s}", .{ command, usage });
    _ = gpa;
    return 2;
}

fn out(init: std.process.Init, comptime fmt: []const u8, args: anytype) !void {
    var buf: [4096]u8 = undefined;
    const text = std.fmt.bufPrint(&buf, fmt, args) catch return;
    try std.Io.File.stdout().writeStreamingAll(init.io, text);
}

/// Where the app keeps its state, as the window computes it.
fn statePath(gpa: std.mem.Allocator, init: std.process.Init, name: []const u8) ![]u8 {
    const home = init.environ_map.get("HOME") orelse ".";
    return std.fmt.allocPrint(gpa, "{s}/Library/Application Support/nanodown/{s}", .{ home, name });
}

/// Reads one of the app's state files. A missing file is not an error: the
/// command reports an empty library rather than failing.
fn readState(gpa: std.mem.Allocator, init: std.process.Init, name: []const u8, limit: usize) ?[]u8 {
    const path = statePath(gpa, init, name) catch return null;
    defer gpa.free(path);
    return std.Io.Dir.cwd().readFileAlloc(now.io(), path, gpa, .limited(limit)) catch null;
}

fn sites(init: std.process.Init, json: bool) !u8 {
    const names = @typeInfo(media.Site).@"enum".field_names;
    if (json) {
        try out(init, "{{\"sites\":[", .{});
        for (names, 0..) |n, i| {
            if (i > 0) try out(init, ",", .{});
            try out(init, "\"{s}\"", .{n});
        }
        try out(init, "]}}\n", .{});
        return 0;
    }
    for (names) |n| try out(init, "{s}\n", .{n});
    return 0;
}

fn showSettings(init: std.process.Init, json: bool) !u8 {
    var values = try settings.Values.init(init.gpa);
    defer values.deinit();
    if (json) {
        try out(init, "{{", .{});
        for (settings.all, 0..) |s, i| {
            if (i > 0) try out(init, ",", .{});
            try out(init, "\"{s}\":\"{s}\"", .{ s.key, values.get(s.key) });
        }
        try out(init, "}}\n", .{});
        return 0;
    }
    var tab: settings.Setting.Tab = settings.all[0].tab;
    for (settings.all) |s| {
        if (s.tab != tab) {
            tab = s.tab;
            try out(init, "\n", .{});
        }
        try out(init, "{s: <22} {s}\n", .{ s.key, values.get(s.key) });
    }
    return 0;
}

fn list(init: std.process.Init, json: bool) !u8 {
    var lib = library.Library.init(init.gpa);
    defer lib.deinit();
    if (readState(init.gpa, init, "library.json", 8 << 20)) |text| {
        defer init.gpa.free(text);
        lib.fromJson(text) catch {};
    }
    if (json) {
        const text = try lib.toJson(init.gpa);
        defer init.gpa.free(text);
        try std.Io.File.stdout().writeStreamingAll(init.io, text);
        try std.Io.File.stdout().writeStreamingAll(init.io, "\n");
        return 0;
    }
    if (lib.items.items.len == 0) {
        try out(init, "Nothing downloaded yet\n", .{});
        return 0;
    }
    for (lib.items.items) |*d| {
        var buf: [192]u8 = undefined;
        try out(init, "{s: <9} {s: <14} {s}\n", .{ d.state.label(), d.quality, d.title });
        try out(init, "          {s}\n", .{d.statusLine(&buf)});
    }
    return 0;
}

fn subs(init: std.process.Init, json: bool) !u8 {
    var followed = subscription.Subscriptions.init(init.gpa);
    defer followed.deinit();
    if (readState(init.gpa, init, "subscriptions.json", 1 << 20)) |text| {
        defer init.gpa.free(text);
        followed.fromJson(text) catch {};
    }
    if (json) {
        const text = try followed.toJson(init.gpa);
        defer init.gpa.free(text);
        try std.Io.File.stdout().writeStreamingAll(init.io, text);
        try std.Io.File.stdout().writeStreamingAll(init.io, "\n");
        return 0;
    }
    if (followed.items.items.len == 0) {
        try out(init, "Nothing followed yet\n", .{});
        return 0;
    }
    for (followed.items.items) |*it| {
        try out(init, "{s: <12} {s: <10} {s}\n", .{ it.as.label(), it.site.title(), it.title });
    }
    return 0;
}

fn info(init: std.process.Init, args: []const []const u8, json: bool) !u8 {
    const url = firstUrl(args) orelse {
        std.debug.print("nanodown info: which link?\n", .{});
        return 2;
    };
    var m = try extract.read(init.gpa, url, 0);
    defer m.deinit(init.gpa);
    if (json) {
        try out(init, "{{\"url\":\"{s}\",\"site\":\"{s}\",\"title\":\"{s}\",\"author\":\"{s}\",\"duration\":{d:.0},\"live\":{s},\"formats\":{d}}}\n", .{
            m.url, @tagName(m.site), m.title, m.author, m.duration, if (m.live) "true" else "false", m.formats.len,
        });
        return 0;
    }
    try out(init, "{s}\n", .{m.title});
    if (m.author.len > 0) try out(init, "  by {s}\n", .{m.author});
    try out(init, "  {s}", .{m.site.title()});
    if (m.duration > 0) {
        var buf: [16]u8 = undefined;
        try out(init, " · {s}", .{download.Download.clock(m.duration, &buf)});
    }
    if (m.live) try out(init, " · live", .{});
    try out(init, "\n  {d} formats\n", .{m.formats.len});
    if (m.problem.len > 0) try out(init, "  {s}\n", .{m.problem});
    return 0;
}

fn formats(init: std.process.Init, args: []const []const u8, json: bool) !u8 {
    const url = firstUrl(args) orelse {
        std.debug.print("nanodown formats: which link?\n", .{});
        return 2;
    };
    var m = try extract.read(init.gpa, url, 0);
    defer m.deinit(init.gpa);
    if (json) {
        try out(init, "[", .{});
        for (m.formats, 0..) |f, i| {
            if (i > 0) try out(init, ",", .{});
            try out(init, "{{\"id\":\"{s}\",\"label\":\"{s}\",\"ext\":\"{s}\",\"size\":{d},\"kind\":\"{s}\",\"codec\":\"{s}\",\"height\":{d}}}", .{
                f.id, f.label, f.ext, f.size, @tagName(f.kind), f.codec, f.height,
            });
        }
        try out(init, "]\n", .{});
        return 0;
    }
    for (m.formats) |f| {
        const size = if (f.size > 0) download.Download.size(f.size, "") else "—";
        try out(init, "{s: <10} {s: <8} {s: <10} {s}\n", .{ f.id, f.label, f.ext, size });
    }
    return 0;
}

fn get(init: std.process.Init, args: []const []const u8, json: bool) !u8 {
    var folder: []const u8 = "";
    var audio = false;
    var quality: u32 = 0;
    var connections: u32 = 4;
    var url: []const u8 = "";
    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        const a = args[i];
        if (std.mem.eql(u8, a, "-o") or std.mem.eql(u8, a, "--output")) {
            i += 1;
            if (i < args.len) folder = args[i];
        } else if (std.mem.eql(u8, a, "-a") or std.mem.eql(u8, a, "--audio")) {
            audio = true;
        } else if (std.mem.eql(u8, a, "-q") or std.mem.eql(u8, a, "--quality")) {
            i += 1;
            if (i < args.len) {
                if (media.Quality.parse(args[i])) |q| quality = q.height;
            }
        } else if (std.mem.eql(u8, a, "-c") or std.mem.eql(u8, a, "--connections")) {
            i += 1;
            if (i < args.len) connections = std.fmt.parseInt(u32, args[i], 10) catch 4;
        } else if (std.mem.startsWith(u8, a, "-")) {
            continue;
        } else if (url.len == 0) {
            url = a;
        }
    }
    if (url.len == 0) {
        std.debug.print("nanodown get: which link?\n", .{});
        return 2;
    }
    if (folder.len == 0) {
        const home = init.environ_map.get("HOME") orelse ".";
        folder = try std.fmt.allocPrint(init.gpa, "{s}/Downloads", .{home});
    }

    var m = try extract.read(init.gpa, url, quality);
    defer m.deinit(init.gpa);
    if (m.problem.len > 0) {
        std.debug.print("nanodown: {s}\n", .{m.problem});
        return 1;
    }
    const kind: media.Format.Kind = if (audio) .audio else .video;
    const f = m.best(kind, quality) orelse {
        std.debug.print("nanodown: no {s} on that page\n", .{@tagName(kind)});
        return 1;
    };
    // A format with neither a URL nor a manifest is one the site signs for
    // its own player: this engine cannot fetch it, and says so.
    if (f.url.len == 0 and f.manifest == null) {
        std.debug.print("nanodown: {s} signs this stream for its own player; nanodown cannot fetch it\n", .{m.site.title()});
        return 1;
    }

    const ext = if (audio) "m4a" else "mp4";
    const dest = try std.fmt.allocPrint(init.gpa, "{s}/{s}", .{ folder, if (m.title.len > 0) m.title else "download" });
    defer init.gpa.free(dest);

    var shared: job.Shared = .{};
    job.run(.{
        .gpa = init.gpa,
        .url = m.url,
        .referer = m.url,
        .format = f,
        .dest = dest,
        .ext = ext,
        .connections = connections,
        .tags = .{ .title = m.title, .artist = m.author, .link = m.url },
        .artwork_url = m.thumb,
    }, &shared);

    if (shared.stageOf() == .failed) {
        std.debug.print("nanodown: {s}\n", .{shared.why()});
        return 1;
    }
    if (json) {
        try out(init, "{{\"ok\":true,\"path\":\"{s}\",\"bytes\":{d}}}\n", .{ shared.wrote(), shared.done.load(.acquire) });
    } else {
        try out(init, "{s}\n", .{shared.wrote()});
    }
    return 0;
}

fn firstUrl(args: []const []const u8) ?[]const u8 {
    for (args) |a| {
        if (std.mem.startsWith(u8, a, "-")) continue;
        return a;
    }
    return null;
}


test "the usage names every command the app answers" {
    for ([_][]const u8{ "get", "info", "formats", "list", "subs", "settings", "sites", "open" }) |name| {
        try std.testing.expect(std.mem.indexOf(u8, usage, name) != null);
    }
}
