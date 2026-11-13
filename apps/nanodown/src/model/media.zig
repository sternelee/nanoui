//! What a link is: its site, its title, its picture, and the qualities it
//! comes in. Pure: no IO, no UI, testable everywhere.
const std = @import("std");

/// A site the app reads itself. `generic` is every other page.
pub const Site = enum {
    youtube,
    bilibili,
    vimeo,
    twitch,
    kick,
    peertube,
    instagram,
    facebook,
    x,
    threads,
    bluesky,
    tiktok,
    reddit,
    tumblr,
    pinterest,
    imgur,
    dailymotion,
    rumble,
    odysee,
    vk,
    douyin,
    xiaohongshu,
    weibo,
    kuaishou,
    loom,
    ted,
    archive,
    streamable,
    soundcloud,
    mixcloud,
    bandcamp,
    generic,

    /// The name the window shows: "YouTube", "SoundCloud", "Vimeo".
    pub fn title(s: Site) []const u8 {
        return switch (s) {
            .youtube => "YouTube",
            .bilibili => "Bilibili",
            .vimeo => "Vimeo",
            .twitch => "Twitch",
            .kick => "Kick",
            .peertube => "PeerTube",
            .instagram => "Instagram",
            .facebook => "Facebook",
            .x => "X",
            .threads => "Threads",
            .bluesky => "Bluesky",
            .tiktok => "TikTok",
            .reddit => "Reddit",
            .tumblr => "Tumblr",
            .pinterest => "Pinterest",
            .imgur => "Imgur",
            .dailymotion => "Dailymotion",
            .rumble => "Rumble",
            .odysee => "Odysee",
            .vk => "VK",
            .douyin => "Douyin",
            .xiaohongshu => "Xiaohongshu",
            .weibo => "Weibo",
            .kuaishou => "Kuaishou",
            .loom => "Loom",
            .ted => "TED",
            .archive => "Internet Archive",
            .streamable => "Streamable",
            .soundcloud => "SoundCloud",
            .mixcloud => "Mixcloud",
            .bandcamp => "Bandcamp",
            .generic => "the web",
        };
    }

    /// The folder name a per-site layout uses.
    pub fn folder(s: Site) []const u8 {
        return switch (s) {
            .generic => "Web",
            else => s.title(),
        };
    }

    /// The site a host belongs to, by its suffix. `null` is a page no
    /// extractor knows, which the generic path still reads.
    /// The site a whole URL belongs to.
    pub fn ofUrl(url: []const u8) Site {
        const start = (std.mem.indexOf(u8, url, "://") orelse return .generic) + 3;
        const rest = url[start..];
        const end = std.mem.indexOfAny(u8, rest, "/?#") orelse rest.len;
        return ofHost(rest[0..end]);
    }

    pub fn ofHost(host: []const u8) Site {
        const table = [_]struct { []const u8, Site }{
            .{ "youtube.com", .youtube },     .{ "youtu.be", .youtube },
            .{ "bilibili.com", .bilibili },   .{ "b23.tv", .bilibili },
            .{ "vimeo.com", .vimeo },         .{ "twitch.tv", .twitch },
            .{ "kick.com", .kick },           .{ "peertube", .peertube },
            .{ "instagram.com", .instagram }, .{ "facebook.com", .facebook },
            .{ "fb.watch", .facebook },       .{ "x.com", .x },
            .{ "twitter.com", .x },           .{ "threads.net", .threads },
            .{ "bsky.app", .bluesky },        .{ "tiktok.com", .tiktok },
            .{ "reddit.com", .reddit },       .{ "redd.it", .reddit },
            .{ "tumblr.com", .tumblr },       .{ "pinterest.", .pinterest },
            .{ "imgur.com", .imgur },         .{ "dailymotion.com", .dailymotion },
            .{ "dai.ly", .dailymotion },      .{ "rumble.com", .rumble },
            .{ "odysee.com", .odysee },       .{ "vk.com", .vk },
            .{ "douyin.com", .douyin },       .{ "xiaohongshu.com", .xiaohongshu },
            .{ "xhslink.com", .xiaohongshu }, .{ "weibo.com", .weibo },
            .{ "weibo.cn", .weibo },          .{ "kuaishou.com", .kuaishou },
            .{ "loom.com", .loom },           .{ "ted.com", .ted },
            .{ "archive.org", .archive },     .{ "streamable.com", .streamable },
            .{ "soundcloud.com", .soundcloud }, .{ "mixcloud.com", .mixcloud },
            .{ "bandcamp.com", .bandcamp },
        };
        for (table) |e| {
            if (std.mem.indexOf(u8, host, e[0]) != null) return e[1];
        }
        return .generic;
    }
};

/// What one quality is: its label, its size, and how to fetch it.
pub const Format = struct {
    /// The id the site gives it, as YouTube's `137`. Empty for a plain file.
    id: []const u8 = "",
    /// "2160p", "1080p", "Audio".
    label: []const u8 = "",
    /// The container the site serves: "mp4", "webm", "m4a".
    ext: []const u8 = "mp4",
    /// Bytes, when the site says.
    size: u64 = 0,
    /// Video, or sound alone.
    kind: Kind = .video,
    /// The URL to fetch, when the format is one file.
    url: []const u8 = "",
    /// The manifest, when the format is many segments.
    manifest: ?Manifest = null,
    /// Bits a second, for ordering.
    bitrate: u32 = 0,
    /// The codec, as "avc1.640028": what the muxer must know to join.
    codec: []const u8 = "",
    /// Width and height in pixels, when known.
    width: u32 = 0,
    height: u32 = 0,
    /// Seconds, when a manifest says.
    duration: f64 = 0,

    pub const Kind = enum { video, audio, image };

    /// Whether this is better than `other` at the same kind.
    pub fn better(f: Format, other: Format) bool {
        if (f.kind != other.kind) return f.kind == .video;
        if (f.height != other.height) return f.height > other.height;
        return f.bitrate > other.bitrate;
    }
};

/// Where a format's bytes come from, when they are not one file.
pub const Manifest = union(enum) {
    hls: []const u8,
    dash: []const u8,
};

/// A playlist's or a channel's item, before it is fetched.
pub const Item = struct {
    id: []const u8 = "",
    title: []const u8 = "",
    url: []const u8 = "",
    /// Seconds.
    duration: f64 = 0,
    /// Its picture.
    thumb: []const u8 = "",
};

/// What a link is.
pub const Media = struct {
    url: []const u8 = "",
    site: Site = .generic,
    title: []const u8 = "",
    author: []const u8 = "",
    /// The page's own description, when it has one.
    description: []const u8 = "",
    /// The picture, as a URL.
    thumb: []const u8 = "",
    /// Seconds; 0 when unknown.
    duration: f64 = 0,
    /// The day it was published, as `YYYY-MM-DD`; empty when unknown.
    date: []const u8 = "",
    /// Every quality it comes in, best first.
    formats: []const Format = &.{},
    /// Its items, when it is a playlist or a channel.
    items: []const Item = &.{},
    /// A live stream: it records until stopped.
    live: bool = false,
    /// Why nothing could be read, when nothing could.
    problem: []const u8 = "",

    pub fn isPlaylist(m: Media) bool {
        return m.items.len > 0;
    }

    /// The best format of `kind` at or under `max_height` (0: any).
    pub fn best(m: Media, kind: Format.Kind, max_height: u32) ?Format {
        var found: ?Format = null;
        for (m.formats) |f| {
            if (f.kind != kind) continue;
            if (max_height > 0 and f.height > max_height) continue;
            if (found == null or f.better(found.?)) found = f;
        }
        return found;
    }

    /// Frees everything `read` made.
    pub fn deinit(m: *Media, gpa: std.mem.Allocator) void {
        gpa.free(m.url);
        gpa.free(m.title);
        gpa.free(m.author);
        gpa.free(m.description);
        gpa.free(m.thumb);
        gpa.free(m.date);
        gpa.free(m.problem);
        for (m.formats) |f| {
            gpa.free(f.id);
            gpa.free(f.label);
            gpa.free(f.ext);
            gpa.free(f.url);
            gpa.free(f.codec);
            if (f.manifest) |man| switch (man) {
                .hls => |u| gpa.free(u),
                .dash => |u| gpa.free(u),
            };
        }
        gpa.free(m.formats);
        for (m.items) |it| {
            gpa.free(it.id);
            gpa.free(it.title);
            gpa.free(it.url);
            gpa.free(it.thumb);
        }
        gpa.free(m.items);
    }

    /// The format with this id, as `get -f 137`.
    pub fn byId(m: Media, id: []const u8) ?Format {
        for (m.formats) |f| if (std.mem.eql(u8, f.id, id)) return f;
        return null;
    }
};

/// A quality as the CLI names it: `best`, `2160`, `1080`, `720`…
pub const Quality = struct {
    /// 0 is `best`.
    height: u32 = 0,

    pub fn parse(s: []const u8) ?Quality {
        if (s.len == 0 or std.mem.eql(u8, s, "best")) return .{};
        const h = std.fmt.parseInt(u32, s, 10) catch return null;
        return .{ .height = h };
    }

    pub fn label(q: Quality) []const u8 {
        return if (q.height == 0) "best" else "";
    }
};

test "a host maps to its site" {
    try std.testing.expectEqual(Site.youtube, Site.ofHost("www.youtube.com"));
    try std.testing.expectEqual(Site.youtube, Site.ofHost("youtu.be"));
    try std.testing.expectEqual(Site.bilibili, Site.ofHost("www.bilibili.com"));
    try std.testing.expectEqual(Site.generic, Site.ofHost("example.com"));
    try std.testing.expectEqual(Site.soundcloud, Site.ofHost("soundcloud.com"));
}

test "the best format respects the ceiling" {
    const formats = [_]Format{
        .{ .label = "2160p", .height = 2160, .kind = .video },
        .{ .label = "1080p", .height = 1080, .kind = .video },
        .{ .label = "720p", .height = 720, .kind = .video },
        .{ .label = "Audio", .kind = .audio },
    };
    const m: Media = .{ .formats = &formats };
    try std.testing.expectEqual(@as(u32, 2160), m.best(.video, 0).?.height);
    try std.testing.expectEqual(@as(u32, 1080), m.best(.video, 1080).?.height);
    try std.testing.expectEqual(@as(u32, 720), m.best(.video, 900).?.height);
    try std.testing.expectEqual(Format.Kind.audio, m.best(.audio, 0).?.kind);
}

test "a quality parses as the CLI writes it" {
    try std.testing.expectEqual(@as(u32, 0), Quality.parse("best").?.height);
    try std.testing.expectEqual(@as(u32, 720), Quality.parse("720").?.height);
    try std.testing.expect(Quality.parse("good") == null);
}
