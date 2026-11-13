//! Every setting, its default, and whether it needs Pro. One table, so the
//! settings window, the CLI's `settings` command and the engine all read the
//! same names.
const std = @import("std");

/// What a setting holds.
pub const Value = union(enum) {
    flag: bool,
    number: u32,
    text: []const u8,
    choice: u8,
};

pub const Kind = enum { flag, number, text, choice };

pub const Setting = struct {
    /// The name `nanodown settings <name> <value>` uses.
    key: []const u8,
    /// What the settings window shows.
    label: []const u8,
    /// Which tab it lives on.
    tab: Tab,
    kind: Kind,
    /// Needs Pro.
    pro: bool = false,
    /// The choices, for `kind = .choice`.
    choices: []const []const u8 = &.{},
    /// The default, as text.
    default: []const u8 = "",

    pub const Tab = enum { general, formats, network, browser, command_line, license };
};

/// The whole table, in the order the docs list them.
pub const all = [_]Setting{
    // General.
    .{ .key = "language", .label = "Language", .tab = .general, .kind = .choice, .choices = &.{ "English", "简体中文", "System" }, .default = "System" },
    .{ .key = "save_to", .label = "Save downloads to", .tab = .general, .kind = .text, .default = "" },
    .{ .key = "folder_per_site", .label = "A folder for each site", .tab = .general, .kind = .flag, .pro = true, .default = "false" },
    .{ .key = "folder_per_playlist", .label = "A folder for each playlist", .tab = .general, .kind = .flag, .pro = true, .default = "false" },
    .{ .key = "file_name", .label = "File name", .tab = .general, .kind = .text, .pro = true, .default = "{title}" },
    .{ .key = "media_server", .label = "Folders for a media server", .tab = .general, .kind = .choice, .pro = true, .choices = &.{ "Off", "Plex", "Jellyfin", "Emby", "Kodi" }, .default = "Off" },
    .{ .key = "skip_existing", .label = "Skip what's already downloaded", .tab = .general, .kind = .flag, .default = "true" },
    .{ .key = "offer_clipboard", .label = "Offer copied links", .tab = .general, .kind = .flag, .default = "true" },
    .{ .key = "keep_awake", .label = "Keep the computer awake", .tab = .general, .kind = .flag, .default = "true" },
    .{ .key = "menu_bar", .label = "Show in the menu bar", .tab = .general, .kind = .flag, .default = "false" },
    .{ .key = "check_new", .label = "Check for new videos", .tab = .general, .kind = .choice, .choices = &.{ "Every hour", "Every 6 hours", "Every day", "Only when I ask" }, .default = "Every hour" },
    .{ .key = "notify", .label = "Notify me", .tab = .general, .kind = .flag, .default = "true" },
    .{ .key = "add_to_music_tv", .label = "Add to Music or TV", .tab = .general, .kind = .flag, .pro = true, .default = "false" },
    .{ .key = "remove_finished", .label = "Remove from the list", .tab = .general, .kind = .flag, .default = "false" },
    .{ .key = "updates", .label = "Updates", .tab = .general, .kind = .flag, .default = "true" },

    // Formats.
    .{ .key = "download_as", .label = "Download as", .tab = .formats, .kind = .choice, .choices = &.{ "Video", "Audio" }, .default = "Video" },
    .{ .key = "quality", .label = "Quality", .tab = .formats, .kind = .choice, .choices = &.{ "best", "2160", "1440", "1080", "720", "480", "360" }, .default = "best" },
    .{ .key = "prefer_h264", .label = "Prefer H.264 and AAC", .tab = .formats, .kind = .flag, .default = "true" },
    .{ .key = "video_format", .label = "Format", .tab = .formats, .kind = .choice, .choices = &.{ "MP4", "MKV", "MOV", "WebM" }, .default = "MP4" },
    .{ .key = "audio_format", .label = "Audio format", .tab = .formats, .kind = .choice, .choices = &.{ "M4A", "MP3", "Opus", "FLAC", "WAV" }, .default = "M4A" },
    .{ .key = "tag_files", .label = "Title, artist and artwork", .tab = .formats, .kind = .flag, .default = "true" },
    .{ .key = "save_thumbnail", .label = "Save the thumbnail", .tab = .formats, .kind = .flag, .default = "false" },
    .{ .key = "date_published", .label = "Date files when published", .tab = .formats, .kind = .flag, .default = "false" },
    .{ .key = "sponsors", .label = "Sponsors in YouTube videos", .tab = .formats, .kind = .choice, .pro = true, .choices = &.{ "Keep", "Mark as chapters", "Remove" }, .default = "Keep" },
    .{ .key = "subtitles", .label = "Subtitles", .tab = .formats, .kind = .flag, .default = "false" },
    .{ .key = "sub_langs", .label = "Subtitle languages", .tab = .formats, .kind = .text, .default = "en" },
    .{ .key = "subs_inside", .label = "Subtitles inside videos", .tab = .formats, .kind = .flag, .default = "true" },
    .{ .key = "ask_quality", .label = "Which quality", .tab = .formats, .kind = .flag, .default = "false" },
    .{ .key = "ask_items", .label = "Which items of a playlist", .tab = .formats, .kind = .flag, .default = "false" },

    // Network.
    .{ .key = "concurrent", .label = "Downloads at once", .tab = .network, .kind = .number, .default = "2" },
    .{ .key = "connections", .label = "Connections per download", .tab = .network, .kind = .number, .default = "4" },
    .{ .key = "speed_limit", .label = "Speed limit", .tab = .network, .kind = .text, .default = "" },
    .{ .key = "proxy", .label = "Proxy", .tab = .network, .kind = .text, .default = "" },

    // Browser.
    .{ .key = "browser_signins", .label = "Use the browser's sign-ins", .tab = .browser, .kind = .flag, .default = "true" },

    // Command line.
    .{ .key = "cli_installed", .label = "The nanodown command", .tab = .command_line, .kind = .flag, .default = "false" },
    .{ .key = "mcp_enabled", .label = "AI agents", .tab = .command_line, .kind = .flag, .default = "false" },
};

/// The keys of the settings that take a typed value, in the order the app
/// keeps a buffer for each.
pub const text_fields: []const []const u8 = blk: {
    var n: usize = 0;
    for (all) |s| {
        if (s.kind == .text) n += 1;
    }
    var out: [n][]const u8 = undefined;
    var at: usize = 0;
    for (all) |s| {
        if (s.kind == .text) {
            out[at] = s.key;
            at += 1;
        }
    }
    const fixed = out;
    break :blk &fixed;
};

/// The setting with this key.
pub fn find(key: []const u8) ?Setting {
    for (all) |s| if (std.mem.eql(u8, s.key, key)) return s;
    return null;
}

/// The free and Pro ceilings of a numeric setting.
pub fn ceiling(key: []const u8, pro: bool) u32 {
    if (std.mem.eql(u8, key, "concurrent")) return if (pro) 8 else 2;
    if (std.mem.eql(u8, key, "connections")) return if (pro) 16 else 4;
    return 0;
}

/// Every setting's value, as text, with the defaults filled in.
pub const Values = struct {
    gpa: std.mem.Allocator,
    map: std.StringHashMap([]const u8),

    pub fn init(gpa: std.mem.Allocator) !Values {
        var v: Values = .{ .gpa = gpa, .map = std.StringHashMap([]const u8).init(gpa) };
        for (all) |s| {
            const key = try gpa.dupe(u8, s.key);
            errdefer gpa.free(key);
            try v.map.put(key, try gpa.dupe(u8, s.default));
        }
        return v;
    }

    pub fn deinit(v: *Values) void {
        var it = v.map.iterator();
        while (it.next()) |e| {
            v.gpa.free(e.key_ptr.*);
            v.gpa.free(e.value_ptr.*);
        }
        v.map.deinit();
    }

    pub fn get(v: *const Values, key: []const u8) []const u8 {
        return v.map.get(key) orelse "";
    }

    pub fn set(v: *Values, key: []const u8, value: []const u8) !void {
        // The key is owned by the map once and never replaced: `getOrPut`
        // with a borrowed key would leave the map holding the caller's slice.
        if (v.map.getEntry(key)) |e| {
            v.gpa.free(e.value_ptr.*);
            e.value_ptr.* = try v.gpa.dupe(u8, value);
            return;
        }
        const owned_key = try v.gpa.dupe(u8, key);
        errdefer v.gpa.free(owned_key);
        try v.map.put(owned_key, try v.gpa.dupe(u8, value));
    }

    pub fn flag(v: *const Values, key: []const u8) bool {
        return std.mem.eql(u8, v.get(key), "true");
    }

    pub fn number(v: *const Values, key: []const u8) u32 {
        return std.fmt.parseInt(u32, v.get(key), 10) catch 0;
    }

    /// Every value, as JSON: a flat object of key to text.
    pub fn toJson(v: *const Values, gpa: std.mem.Allocator) ![]const u8 {
        var out: std.Io.Writer.Allocating = .init(gpa);
        errdefer out.deinit();
        const w = &out.writer;
        try w.writeAll("{");
        var first = true;
        for (all) |s| {
            if (!first) try w.writeAll(",");
            first = false;
            try w.print("\"{s}\":\"{s}\"", .{ s.key, v.get(s.key) });
        }
        try w.writeAll("}");
        return out.toOwnedSlice();
    }

    /// Reads what `toJson` wrote. A key it does not know is left out.
    pub fn fromJson(v: *Values, text: []const u8) !void {
        var i: usize = 0;
        while (indexOf(text, i, "\"")) |open| {
            const close = indexOf(text, open + 1, "\"") orelse return;
            const key = text[open + 1 .. close];
            const colon = indexOf(text, close + 1, ":") orelse return;
            const vopen = indexOf(text, colon + 1, "\"") orelse return;
            const vclose = indexOf(text, vopen + 1, "\"") orelse return;
            const value = text[vopen + 1 .. vclose];
            if (find(key) != null) try v.set(key, value);
            i = vclose + 1;
        }
    }

    /// The choice's index, for a `select`.
    pub fn choice(v: *const Values, key: []const u8) u8 {
        const s = find(key) orelse return 0;
        for (s.choices, 0..) |c, i| if (std.mem.eql(u8, c, v.get(key))) return @intCast(i);
        return 0;
    }
};

fn indexOf(text: []const u8, from: usize, needle: []const u8) ?usize {
    if (from >= text.len) return null;
    const at = std.mem.indexOfPos(u8, text, from, needle) orelse return null;
    return at;
}

test "values come back as they went out" {
    const gpa = std.testing.allocator;
    var v = try Values.init(gpa);
    defer v.deinit();
    try v.set("quality", "1080");
    try v.set("save_to", "/tmp/x");
    const text = try v.toJson(gpa);
    defer gpa.free(text);
    var back = try Values.init(gpa);
    defer back.deinit();
    try back.fromJson(text);
    try std.testing.expectEqualStrings("1080", back.get("quality"));
    try std.testing.expectEqualStrings("/tmp/x", back.get("save_to"));
    try std.testing.expectEqualStrings("Video", back.get("download_as"));
}

test "every setting is findable by its key" {
    for (all) |s| {
        try std.testing.expect(find(s.key) != null);
    }
    try std.testing.expect(find("nope") == null);
}

test "values start at their defaults and change" {
    var v = try Values.init(std.testing.allocator);
    defer v.deinit();
    try std.testing.expectEqualStrings("best", v.get("quality"));
    try std.testing.expect(v.flag("skip_existing"));
    try v.set("quality", "720");
    try std.testing.expectEqualStrings("720", v.get("quality"));
    try std.testing.expectEqual(@as(u32, 720), v.number("quality"));
}

test "the ceilings are the free and Pro ones" {
    try std.testing.expectEqual(@as(u32, 2), ceiling("concurrent", false));
    try std.testing.expectEqual(@as(u32, 8), ceiling("concurrent", true));
    try std.testing.expectEqual(@as(u32, 4), ceiling("connections", false));
    try std.testing.expectEqual(@as(u32, 16), ceiling("connections", true));
}
