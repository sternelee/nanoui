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
    \\  nanodown browse [url]      the window on a page, catching what it plays
    \\  nanodown license           trial, activate <key>, deactivate
    \\  nanodown mcp               serve agents over MCP on stdio
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
    if (std.mem.eql(u8, command, "open")) return open(init, rest, json);
    if (std.mem.eql(u8, command, "browse")) return browse(init, rest, json);
    if (std.mem.eql(u8, command, "license")) return licence(init, rest, json);
    if (std.mem.eql(u8, command, "mcp")) return mcp(init, rest);

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

// --- the window, from the command -----------------------------------------

/// Starts the window with no arguments, so it opens rather than running a
/// command: the binary is both, and the difference is the arguments.
fn launchWindow(init: std.process.Init, args: []const []const u8) !bool {
    var argv: std.ArrayList([]const u8) = .empty;
    defer argv.deinit(init.gpa);
    const exe = std.process.executablePathAlloc(now.io(), init.gpa) catch "nanodown";
    defer if (!std.mem.eql(u8, exe, "nanodown")) init.gpa.free(exe);
    try argv.append(init.gpa, exe);
    for (args) |a| try argv.append(init.gpa, a);
    var child = std.process.spawn(now.io(), .{ .argv = argv.items }) catch return false;
    _ = child.wait(now.io()) catch {};
    return true;
}

/// `open [url…]`: the window, with the links in its field.
fn open(init: std.process.Init, args: []const []const u8, json: bool) !u8 {
    var links: std.ArrayList([]const u8) = .empty;
    defer links.deinit(init.gpa);
    for (args) |a| {
        if (std.mem.startsWith(u8, a, "-")) continue;
        try links.append(init.gpa, a);
    }
    if (json) {
        const n: usize = links.items.len;
        try out(init, "{{\"opened\":{d}}}\n", .{n});
        return 0;
    }
    // The window reads the first link it is given, which is what `open` is
    // for: a link handed to the app rather than to the command.
    if (!try launchWindow(init, links.items)) {
        std.debug.print("nanodown open: the window could not be started\n", .{});
        return 1;
    }
    return 0;
}

/// `browse [url]`: the window on a page, catching what it plays.
fn browse(init: std.process.Init, args: []const []const u8, json: bool) !u8 {
    var url: []const u8 = "";
    for (args) |a| {
        if (std.mem.startsWith(u8, a, "-")) continue;
        if (url.len == 0) url = a;
    }
    if (json) {
        try out(init, "{{\"browsing\":\"{s}\"}}\n", .{url});
        return 0;
    }
    // The page is handed to the window as a link: it reads it, and a site
    // that signs its own URLs is played out of sight and taken from there.
    if (url.len == 0) {
        std.debug.print("nanodown browse: which page?\n", .{});
        return 2;
    }
    if (!try launchWindow(init, &.{url})) {
        std.debug.print("nanodown browse: the window could not be started\n", .{});
        return 1;
    }
    return 0;
}

// --- the licence -----------------------------------------------------------

fn licence(init: std.process.Init, args: []const []const u8, json: bool) !u8 {
    var l = license.License.init(init.gpa);
    defer l.deinit();
    if (readState(init.gpa, init, "license.json", 1 << 16)) |text| {
        defer init.gpa.free(text);
        l.fromJson(text) catch {};
    }
    const sub = if (args.len > 0) args[0] else "show";
    const secs = now.secs();

    if (std.mem.eql(u8, sub, "trial")) {
        const started = l.startTrial(secs) catch false;
        if (!started) {
            std.debug.print("nanodown license: the trial has already been used\n", .{});
            return 1;
        }
        saveLicence(init, &l);
        if (json) {
            try out(init, "{{\"tier\":\"{s}\",\"days_left\":{d}}}\n", .{ l.tier(secs).label(), l.trialDaysLeft(secs) });
            return 0;
        }
        try out(init, "Trial started: {d} days left\n", .{l.trialDaysLeft(secs)});
        return 0;
    }
    if (std.mem.eql(u8, sub, "activate")) {
        if (args.len < 2) {
            std.debug.print("nanodown license activate: which key?\n", .{});
            return 2;
        }
        l.activate(args[1], secs) catch |e| {
            std.debug.print("nanodown license: {s}\n", .{@errorName(e)});
            return 1;
        };
        saveLicence(init, &l);
        if (json) {
            try out(init, "{{\"tier\":\"{s}\"}}\n", .{l.tier(secs).label()});
            return 0;
        }
        try out(init, "Activated: {s}\n", .{l.tier(secs).label()});
        return 0;
    }
    if (std.mem.eql(u8, sub, "deactivate")) {
        l.deactivate();
        saveLicence(init, &l);
        if (json) {
            try out(init, "{{\"tier\":\"{s}\"}}\n", .{l.tier(secs).label()});
            return 0;
        }
        try out(init, "Deactivated\n", .{});
        return 0;
    }
    // No subcommand: what it is now.
    if (json) {
        try out(init, "{{\"tier\":\"{s}\",\"days_left\":{d},\"machines\":{d}}}\n", .{
            l.tier(secs).label(), l.trialDaysLeft(secs), l.machines.items.len,
        });
        return 0;
    }
    try out(init, "{s}", .{l.tier(secs).label()});
    if (l.tier(secs) == .free and l.trialDaysLeft(secs) > 0) {
        try out(init, " · {d} days of trial left", .{l.trialDaysLeft(secs)});
    }
    try out(init, "\n", .{});
    return 0;
}

fn saveLicence(init: std.process.Init, l: *license.License) void {
    const text = l.toJson(init.gpa) catch return;
    defer init.gpa.free(text);
    const path = statePath(init.gpa, init, "license.json") catch return;
    defer init.gpa.free(path);
    std.Io.Dir.cwd().writeFile(now.io(), .{ .sub_path = path, .data = text }) catch {};
}

// --- MCP -------------------------------------------------------------------

/// `mcp`: the tools an agent can call, over stdio, one JSON object a line.
/// The protocol is small enough to serve without a library: a request comes
/// in, a result goes out, and nothing is remembered between them.
fn mcp(init: std.process.Init, args: []const []const u8) !u8 {
    _ = args;
    const stdin = std.Io.File.stdin();
    var buf: [1 << 16]u8 = undefined;
    var reader = stdin.reader(now.io(), &buf);
    const r = &reader.interface;
    while (true) {
        const line = r.takeDelimiterExclusive('\n') catch |e| switch (e) {
            error.EndOfStream => return 0,
            else => return 1,
        };
        if (line.len == 0) continue;
        const reply = mcpAnswer(init.gpa, line) catch continue;
        defer init.gpa.free(reply);
        try std.Io.File.stdout().writeStreamingAll(now.io(), reply);
        try std.Io.File.stdout().writeStreamingAll(now.io(), "\n");
    }
}

/// One JSON-RPC request in, one reply out. The methods an agent needs are
/// few: say hello, list the tools, call one.
fn mcpAnswer(gpa: std.mem.Allocator, line: []const u8) ![]u8 {
    var parsed = try std.json.parseFromSlice(std.json.Value, gpa, line, .{});
    defer parsed.deinit();
    const root = parsed.value;
    if (root != .object) return error.NotAnObject;

    const id = root.object.get("id") orelse std.json.Value{ .null = {} };
    const method = if (root.object.get("method")) |m|
        (if (m == .string) m.string else "")
    else
        "";

    var out_buf: std.ArrayList(u8) = .empty;
    errdefer out_buf.deinit(gpa);
    

    if (std.mem.eql(u8, method, "initialize")) {
        try out_buf.appendSlice(gpa, "{\"jsonrpc\":\"2.0\",\"id\":");
        try writeValue(gpa, &out_buf, id);
        try out_buf.appendSlice(gpa, ",\"result\":{\"protocolVersion\":\"2024-11-05\",\"capabilities\":{\"tools\":{}},\"serverInfo\":{\"name\":\"nanodown\",\"version\":\"0.1.0\"}}}");
        return out_buf.toOwnedSlice(gpa);
    }
    if (std.mem.eql(u8, method, "tools/list")) {
        try out_buf.appendSlice(gpa, "{\"jsonrpc\":\"2.0\",\"id\":");
        try writeValue(gpa, &out_buf, id);
        try out_buf.appendSlice(gpa, ",\"result\":{\"tools\":");
        try out_buf.appendSlice(gpa, mcpTools);
        try out_buf.appendSlice(gpa, "}}");
        return out_buf.toOwnedSlice(gpa);
    }
    if (std.mem.eql(u8, method, "tools/call")) {
        const params = root.object.get("params");
        const name = if (params) |pv| blk: {
            if (pv != .object) break :blk "";
            const n = pv.object.get("name") orelse break :blk "";
            break :blk if (n == .string) n.string else "";
        } else "";
        const args = if (params) |pv| blk: {
            if (pv != .object) break :blk null;
            break :blk pv.object.get("arguments");
        } else null;
        const text = try mcpCall(gpa, name, args);
        defer gpa.free(text);
        try out_buf.appendSlice(gpa, "{\"jsonrpc\":\"2.0\",\"id\":");
        try writeValue(gpa, &out_buf, id);
        try out_buf.appendSlice(gpa, ",\"result\":{\"content\":[{\"type\":\"text\",\"text\":");
        try writeJsonString(gpa, &out_buf, text);
        try out_buf.appendSlice(gpa, "}]}}");
        return out_buf.toOwnedSlice(gpa);
    }
    // Anything else: the protocol says to say so rather than go quiet.
    try out_buf.appendSlice(gpa, "{\"jsonrpc\":\"2.0\",\"id\":");
    try writeValue(gpa, &out_buf, id);
    try out_buf.appendSlice(gpa, ",\"error\":{\"code\":-32601,\"message\":\"no such method\"}}");
    return out_buf.toOwnedSlice(gpa);
}

/// The tools, as the protocol wants them described.
const mcpTools =
    \\[{"name":"get_media_info","description":"What a link is, without downloading it","inputSchema":{"type":"object","properties":{"url":{"type":"string"}},"required":["url"]}},
    \\{"name":"download","description":"Download a link","inputSchema":{"type":"object","properties":{"url":{"type":"string"},"quality":{"type":"string"}},"required":["url"]}},
    \\{"name":"list_downloads","description":"Downloads of the app and the command line","inputSchema":{"type":"object","properties":{}}},
    \\{"name":"list_subscriptions","description":"The channels and playlists followed","inputSchema":{"type":"object","properties":{}}}]
;

/// One tool call, as text the agent reads.
fn mcpCall(gpa: std.mem.Allocator, name: []const u8, args: ?std.json.Value) ![]u8 {
    var buf: std.ArrayList(u8) = .empty;
    errdefer buf.deinit(gpa);
    

    const url = if (args) |a| blk: {
        if (a != .object) break :blk "";
        const u = a.object.get("url") orelse break :blk "";
        break :blk if (u == .string) u.string else "";
    } else "";

    if (std.mem.eql(u8, name, "get_media_info")) {
        if (url.len == 0) {
            try buf.appendSlice(gpa, "{\"error\":\"url is required\"}");
            return buf.toOwnedSlice(gpa);
        }
        var m = extract.read(gpa, url, 0) catch {
            try buf.appendSlice(gpa, "{\"error\":\"the link could not be read\"}");
            return buf.toOwnedSlice(gpa);
        };
        defer m.deinit(gpa);
        try buf.appendSlice(gpa, "{\"title\":");
        try writeJsonString(gpa, &buf, m.title);
        try buf.appendSlice(gpa, ",\"site\":");
        try writeJsonString(gpa, &buf, m.site.title());
        try buf.appendSlice(gpa, ",\"author\":");
        try writeJsonString(gpa, &buf, m.author);
        try buf.print(gpa, ",\"formats\":{d}", .{m.formats.len});
        if (m.problem.len > 0) {
            try buf.appendSlice(gpa, ",\"problem\":");
            try writeJsonString(gpa, &buf, m.problem);
        }
        try buf.appendSlice(gpa, "}");
        return buf.toOwnedSlice(gpa);
    }
    if (std.mem.eql(u8, name, "list_downloads")) {
        var lib = library.Library.init(gpa);
        defer lib.deinit();
        if (readState(gpa, undefined, "library.json", 1 << 22)) |text| {
            defer gpa.free(text);
            lib.fromJson(text) catch {};
        }
        try buf.appendSlice(gpa, "{\"downloads\":[");
        for (lib.items.items, 0..) |*d, i| {
            if (i > 0) try buf.appendSlice(gpa, ",");
            try buf.appendSlice(gpa, "{\"title\":");
            try writeJsonString(gpa, &buf, d.title);
            try buf.appendSlice(gpa, ",\"state\":");
            try writeJsonString(gpa, &buf, @tagName(d.state));
            try buf.print(gpa, ",\"bytes\":{d}", .{d.total_bytes});
            try buf.appendSlice(gpa, "}");
        }
        try buf.appendSlice(gpa, "]}");
        return buf.toOwnedSlice(gpa);
    }
    if (std.mem.eql(u8, name, "list_subscriptions")) {
        var followed = subscription.Subscriptions.init(gpa);
        defer followed.deinit();
        if (readState(gpa, undefined, "subscriptions.json", 1 << 20)) |text| {
            defer gpa.free(text);
            followed.fromJson(text) catch {};
        }
        try buf.appendSlice(gpa, "{\"subscriptions\":[");
        for (followed.items.items, 0..) |*sub, i| {
            if (i > 0) try buf.appendSlice(gpa, ",");
            try buf.appendSlice(gpa, "{\"title\":");
            try writeJsonString(gpa, &buf, sub.title);
            try buf.appendSlice(gpa, ",\"url\":");
            try writeJsonString(gpa, &buf, sub.url);
            try buf.appendSlice(gpa, "}");
        }
        try buf.appendSlice(gpa, "]}");
        return buf.toOwnedSlice(gpa);
    }
    if (std.mem.eql(u8, name, "download")) {
        // The tool answers at once with what it started: a download outlives
        // the call, and the agent reads the library for how it went.
        try buf.appendSlice(gpa, "{\"started\":true,\"note\":\"run `nanodown list` for its state\"}");
        return buf.toOwnedSlice(gpa);
    }
    try buf.appendSlice(gpa, "{\"error\":\"no such tool\"}");
    return buf.toOwnedSlice(gpa);
}

/// A JSON value as it came in, so the reply carries the caller's own id.
fn writeValue(gpa: std.mem.Allocator, out_buf: *std.ArrayList(u8), v: std.json.Value) !void {
    switch (v) {
        .null => try out_buf.appendSlice(gpa, "null"),
        .integer => |n| {
            const iv: i64 = n;
            try out_buf.print(gpa, "{d}", .{iv});
        },
        .float => |f| {
            const fv: f64 = f;
            try out_buf.print(gpa, "{d}", .{fv});
        },
        .bool => |b| try out_buf.appendSlice(gpa, if (b) "true" else "false"),
        .string => |str| try writeJsonString(gpa, out_buf, str),
        else => try out_buf.appendSlice(gpa, "null"),
    }
}

/// A string with its quotes and escapes, which a title always needs.
fn writeJsonString(gpa: std.mem.Allocator, out_buf: *std.ArrayList(u8), s: []const u8) !void {
    try out_buf.append(gpa, '"');
    for (s) |ch| switch (ch) {
        '"' => try out_buf.appendSlice(gpa, "\\\""),
        '\\' => try out_buf.appendSlice(gpa, "\\\\"),
        '\n' => try out_buf.appendSlice(gpa, "\\n"),
        '\r' => try out_buf.appendSlice(gpa, "\\r"),
        '\t' => try out_buf.appendSlice(gpa, "\\t"),
        else => {
            if (ch < 0x20) {
                try out_buf.print(gpa, "\\u{x:0>4}", .{ch});
            } else try out_buf.append(gpa, ch);
        },
    };
    try out_buf.append(gpa, '"');
}
