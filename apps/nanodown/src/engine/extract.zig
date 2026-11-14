//! Turning a link into a `Media`: fetch the page, read what it says about its
//! video, and list the qualities. The site's own patterns first, then the
//! page's metadata, then its markup.
const std = @import("std");
const nanoui = @import("nanoui");
const http = nanoui.http;
const media = @import("../model/media.zig");
const hls = @import("hls.zig");
const dash = @import("dash.zig");
const httpz = @import("http.zig");
const pg = @import("page.zig");
const manifest = @import("manifest.zig");
const sites = @import("sites.zig");

/// Reads a link. Never fails: a link it cannot read comes back with
/// The name a bare link suggests, without the extension that says how it is
/// packaged rather than what it is: `clip.m3u8` is a video called `clip`.
fn titleFromUrl(url: []const u8) []const u8 {
    const name = httpz.nameFromUrl(url);
    const dot = std.mem.lastIndexOfScalar(u8, name, '.') orelse return name;
    return if (dot == 0) name else name[0..dot];
}

/// `problem` set, which is what the preview shows.
pub fn read(gpa: std.mem.Allocator, url: []const u8, max_height: u32) !media.Media {
    // Every string in a `Media` is the caller's to free: it owns its own.
    var m: media.Media = .{ .url = try gpa.dupe(u8, url), .site = media.Site.ofUrl(url) };
    errdefer m.deinit(gpa);
    const host = pg.hostOf(url);

    // A link straight to a playlist is the whole video: no page to read.
    // A master playlist is read for its renditions, so the list holds real
    // qualities rather than one "Auto" that cannot honour a `-q`.
    if (isPlaylist(url)) {
        m.title = try gpa.dupe(u8, titleFromUrl(url));
        var listed: std.ArrayList(media.Format) = .empty;
        defer listed.deinit(gpa);
        if (std.mem.indexOf(u8, url, ".m3u8") != null) {
            try manifest.expandHls(gpa, url, url, .video, &listed);
        } else {
            try manifest.expandDash(gpa, url, url, &listed);
        }
        // A playlist that would not answer keeps the plain entry, so the
        // download still has something to try and can say what went wrong.
        if (listed.items.len == 0) {
            try listed.append(gpa, .{
                .id = try gpa.dupe(u8, "hls"),
                .label = try gpa.dupe(u8, "Auto"),
                .ext = try gpa.dupe(u8, "mp4"),
                .manifest = .{ .hls = try gpa.dupe(u8, url) },
                .kind = .video,
            });
        }
        std.mem.sort(media.Format, listed.items, {}, better);
        m.formats = try listed.toOwnedSlice(gpa);
        return m;
    }

    // A link straight to a media file needs no page.
    if (pg.looksLikeFile(url)) {
        m.title = try gpa.dupe(u8, titleFromUrl(url));
        const formats = try gpa.alloc(media.Format, 1);
        formats[0] = .{
            .id = try gpa.dupe(u8, "0"),
            .label = try gpa.dupe(u8, "Original"),
            .ext = try gpa.dupe(u8, pg.extOf(url)),
            .url = try gpa.dupe(u8, url),
            .kind = pg.kindOf(url),
        };
        m.formats = formats;
        var p = httpz.probe(gpa, url, "");
        defer p.deinit();
        if (p.size > 0) formats[0].size = p.size;
        if (p.problem.len > 0) m.problem = try gpa.dupe(u8, p.problem);
        return m;
    }

    // The page itself.
    var page = fetch(gpa, url, "");
    if (page.status() == 0 or page.body().len == 0) {
        const why = if (page.err().len > 0) page.err() else "the page did not answer";
        m.problem = try gpa.dupe(u8, why);
        return m;
    }
    defer page.deinit();

    // What the page says about itself.
    m.title = try gpa.dupe(u8, pg.meta(page.body(), "og:title") orelse pg.meta(page.body(), "twitter:title") orelse pg.titleTag(page.body()) orelse httpz.nameFromUrl(url));
    m.author = try gpa.dupe(u8, pg.meta(page.body(), "og:site_name") orelse "");
    m.description = try gpa.dupe(u8, pg.meta(page.body(), "og:description") orelse "");
    const thumb_ref = pg.meta(page.body(), "og:image") orelse pg.meta(page.body(), "twitter:image") orelse "";
    const thumb_abs = try pg.absolute(gpa, url, thumb_ref);
    defer gpa.free(thumb_abs);
    m.thumb = try gpa.dupe(u8, thumb_abs);
    if (pg.meta(page.body(), "og:video:duration")) |d| m.duration = std.fmt.parseFloat(f64, d) catch 0;
    if (pg.meta(page.body(), "article:published_time")) |d| {
        if (d.len >= 10) m.date = try gpa.dupe(u8, d[0..10]);
    }

    // The site's own patterns, which know more than the metadata does.
    var formats: std.ArrayList(media.Format) = .empty;
    defer formats.deinit(gpa);
    sites.siteFormats(gpa, host, url, page.body(), &formats) catch |e| switch (e) {
        error.Drm => {
            m.problem = try gpa.dupe(u8, "DRM-protected, so its samples cannot be decrypted");
            return m;
        },
        else => return e,
    };

    // Then whatever the markup plays.
    if (formats.items.len == 0) try markupFormats(gpa, url, page.body(), &formats);

    // A manifest is read for its qualities, so the list is real ones.
    var expanded: std.ArrayList(media.Format) = .empty;
    defer expanded.deinit(gpa);
    for (formats.items) |f| {
        if (f.manifest) |man| {
            switch (man) {
                .hls => |u| try manifest.expandHls(gpa, url, u, f.kind, &expanded),
                .dash => |u| try manifest.expandDash(gpa, url, u, &expanded),
            }
            // The manifest's own format is replaced by what it held.
            gpa.free(f.id);
            gpa.free(f.label);
            gpa.free(f.ext);
            gpa.free(f.url);
            gpa.free(f.codec);
            switch (man) {
                .hls => |u| gpa.free(u),
                .dash => |u| gpa.free(u),
            }
            continue;
        }
        try expanded.append(gpa, f);
    }
    // Best first, audio last.
    std.mem.sort(media.Format, expanded.items, {}, better);
    m.formats = try expanded.toOwnedSlice(gpa);

    if (m.formats.len == 0) {
        m.problem = try gpa.dupe(u8, "no video on this page that nanodown can read");
    }
    _ = max_height;
    return m;
}

/// A link that is itself a stream's playlist, not a page about one.
fn isPlaylist(url: []const u8) bool {
    const path = if (std.mem.indexOfScalar(u8, url, '?')) |q| url[0..q] else url;
    return std.mem.endsWith(u8, path, ".m3u8") or std.mem.endsWith(u8, path, ".mpd");
}

fn better(_: void, a: media.Format, b: media.Format) bool {
    if (a.kind != b.kind) return @intFromEnum(a.kind) < @intFromEnum(b.kind);
    if (a.height != b.height) return a.height > b.height;
    return a.bitrate > b.bitrate;
}

pub fn fetch(gpa: std.mem.Allocator, url: []const u8, referer: []const u8) http.OwnedResponse {
    var headers = [_]http.Header{
        httpz.user_agent,
        .{ .name = "Accept", .value = "text/html,application/xhtml+xml,*/*" },
        .{ .name = "Accept-Language", .value = "en-US,en;q=0.9" },
    };
    var n: usize = 2;
    if (referer.len > 0) {
        headers[2] = .{ .name = "Referer", .value = referer };
        n = 3;
    }
    return httpz.send(gpa, .{ .url = url, .headers = headers[0..n], .timeout = 25 });
}

// --- what the markup plays ------------------------------------------------

/// Any page: `og:video`, a `<video>`'s source, a JSON-LD `contentUrl`, or a
/// manifest URL sitting in a script.
fn markupFormats(gpa: std.mem.Allocator, base: []const u8, body: []const u8, out: *std.ArrayList(media.Format)) !void {
    // A manifest first: it holds every quality.
    if (pg.findAnyUrl(body, ".m3u8")) |u| {
        try out.append(gpa, .{ .id = try gpa.dupe(u8, "hls"), .label = try gpa.dupe(u8, "Auto"), .ext = try gpa.dupe(u8, "mp4"), .manifest = .{ .hls = try pg.absolute(gpa, base, u) }, .kind = .video });
    }
    if (pg.findAnyUrl(body, ".mpd")) |u| {
        try out.append(gpa, .{ .id = try gpa.dupe(u8, "dash"), .label = try gpa.dupe(u8, "Auto"), .ext = try gpa.dupe(u8, "mp4"), .manifest = .{ .dash = try pg.absolute(gpa, base, u) }, .kind = .video });
    }

    // A plain file: `og:video`, then `<video src>`, then `<source src>`.
    if (pg.meta(body, "og:video:url") orelse pg.meta(body, "og:video:secure_url") orelse pg.meta(body, "og:video")) |u| {
        try addFile(gpa, base, u, .video, out);
    }
    if (pg.meta(body, "og:audio") orelse pg.meta(body, "og:audio:url")) |u| {
        try addFile(gpa, base, u, .audio, out);
    }
    var at: usize = 0;
    while (std.mem.indexOfPos(u8, body, at, "<video")) |v| {
        const close = std.mem.indexOfScalarPos(u8, body, v, '>') orelse break;
        const tag = body[v..close];
        if (pg.attrIn(tag, "src")) |u| try addFile(gpa, base, u, .video, out);
        at = close;
    }
    at = 0;
    while (std.mem.indexOfPos(u8, body, at, "<source")) |v| {
        const close = std.mem.indexOfScalarPos(u8, body, v, '>') orelse break;
        const tag = body[v..close];
        if (pg.attrIn(tag, "src")) |u| try addFile(gpa, base, u, .video, out);
        at = close;
    }
    // JSON-LD.
    if (pg.findJson(body, "contentUrl")) |u| {
        if (std.mem.startsWith(u8, u, "http")) try addFile(gpa, base, u, .video, out);
    }
}

fn addFile(gpa: std.mem.Allocator, base: []const u8, ref: []const u8, kind: media.Format.Kind, out: *std.ArrayList(media.Format)) !void {
    if (ref.len == 0) return;
    const abs = try pg.absolute(gpa, base, ref);
    for (out.items) |f| if (std.mem.eql(u8, f.url, abs)) return;
    try out.append(gpa, .{
        .id = try gpa.dupe(u8, "0"),
        .label = try gpa.dupe(u8, if (kind == .audio) "Audio" else "Original"),
        .ext = try gpa.dupe(u8, pg.extOf(abs)),
        .url = abs,
        .kind = kind,
    });
}

// --- manifests ------------------------------------------------------------

pub fn labelFor(gpa: std.mem.Allocator, f: media.Format) ![]const u8 {
    if (f.kind == .audio) return gpa.dupe(u8, "Audio");
    if (f.height > 0) return std.fmt.allocPrint(gpa, "{d}p", .{f.height});
    return gpa.dupe(u8, "Original");
}

test "a page's metadata is read" {
    const body =
        \\<html><head>
        \\<meta property="og:title" content="Big Buck Bunny">
        \\<meta property="og:image" content="https://x.com/t.jpg">
        \\<meta property="og:video" content="/v/bbb.mp4">
        \\<title>ignored</title></head>
        \\<body><video src="clip.mp4"></video></body></html>
    ;
    try std.testing.expectEqualStrings("Big Buck Bunny", pg.meta(body, "og:title").?);
    try std.testing.expectEqualStrings("https://x.com/t.jpg", pg.meta(body, "og:image").?);
    try std.testing.expectEqualStrings("/v/bbb.mp4", pg.meta(body, "og:video").?);
}

test "a JSON value is found by its key" {
    const json =
        \\{"a":1,"title":"Hi \"there\"","height":1080,"url":"https://x/v.mp4"}
    ;
    try std.testing.expectEqualStrings("Hi \\\"there\\\"", pg.findJson(json, "title").?);
    try std.testing.expectEqualStrings("1080", pg.findJson(json, "height").?);
    try std.testing.expectEqualStrings("https://x/v.mp4", pg.findJson(json, "url").?);
    try std.testing.expect(pg.findJson(json, "nope") == null);
}

test "a reference resolves against its page" {
    const gpa = std.testing.allocator;
    const a = try pg.absolute(gpa, "https://x.com/a/b.html", "/v/1.mp4");
    defer gpa.free(a);
    try std.testing.expectEqualStrings("https://x.com/v/1.mp4", a);
    const b = try pg.absolute(gpa, "https://x.com/a/b.html", "1.mp4");
    defer gpa.free(b);
    try std.testing.expectEqualStrings("https://x.com/a/1.mp4", b);
    const c = try pg.absolute(gpa, "https://x.com/a/b.html", "https://y.com/z.mp4");
    defer gpa.free(c);
    try std.testing.expectEqualStrings("https://y.com/z.mp4", c);
}

test "a manifest URL is found in a page" {
    const body = "var src = \"https://cdn.x.com/hls/index.m3u8\";";
    try std.testing.expectEqualStrings("https://cdn.x.com/hls/index.m3u8", pg.findAnyUrl(body, ".m3u8").?);
}

test "a bare playlist link is told from a page" {
    // A master playlist is the whole video, and its renditions are read from
    // it: the list must hold real qualities, not one "Auto" that cannot
    // honour a `-q`.
    try std.testing.expect(isPlaylist("https://cdn.x.com/hls/master.m3u8"));
    try std.testing.expect(isPlaylist("https://cdn.x.com/hls/master.m3u8?token=a"));
    try std.testing.expect(isPlaylist("https://cdn.x.com/dash/manifest.mpd"));
    try std.testing.expect(!isPlaylist("https://www.youtube.com/watch?v=abc"));
    try std.testing.expect(!isPlaylist("https://vimeo.com/76979871"));
    try std.testing.expect(!isPlaylist("https://cdn.x.com/clip.mp4"));
}

test "a bare link's title drops the packaging, not the name" {
    try std.testing.expectEqualStrings("master", titleFromUrl("https://cdn.x.com/hls/master.m3u8"));
    try std.testing.expectEqualStrings("clip", titleFromUrl("https://cdn.x.com/clip.mp4"));
    try std.testing.expectEqualStrings("clip", titleFromUrl("https://cdn.x.com/clip.mp4?token=a"));
    // A name with no extension is its own title.
    try std.testing.expectEqualStrings("stream", titleFromUrl("https://cdn.x.com/stream"));
    // A dotfile is not an extension.
    try std.testing.expectEqualStrings(".hidden", titleFromUrl("https://cdn.x.com/.hidden"));
}

