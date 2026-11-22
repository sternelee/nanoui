//! Each site keeps its media somewhere particular. These read what the page
//! already holds; nothing is signed or decrypted, and a stream that needs a
//! signature the page does not carry is left for `read` to report.
const std = @import("std");
const media = @import("../model/media.zig");
const http = @import("http.zig");
const pg = @import("page.zig");
const hls = @import("hls.zig");
const extract = @import("extract.zig");
const api = @import("sites_api.zig");

const httpz = http;
const fetch = extract.fetch;
const labelFor = extract.labelFor;

/// Each site keeps its media somewhere particular. These read what the page
/// already holds; nothing is signed or decrypted.
pub fn siteFormats(gpa: std.mem.Allocator, host: []const u8, url: []const u8, body: []const u8, out: *std.ArrayList(media.Format)) !void {
    const site = media.Site.ofHost(host);
    switch (site) {
        .youtube => try youtube(gpa, url, body, out),
        .bilibili => try bilibili(gpa, url, body, out),
        .vimeo => vimeo(gpa, url, body, out) catch |e| switch (e) {
            error.Drm => return error.Drm,
            else => return e,
        },
        .soundcloud => try soundcloud(gpa, url, body, out),
        .dailymotion => try api.dailymotion(gpa, url, out),
        .bandcamp => try bandcamp(gpa, body, out),
        .facebook => try api.facebook(gpa, body, out),
        .x => try api.xPost(gpa, url, out),
        .mixcloud => try api.mixcloud(gpa, url, out),
        .streamable => try api.streamable(gpa, url, out),
        .twitch => {
            try api.twitch(gpa, url, out);
            if (out.items.len == 0) try streaming(gpa, url, body, out);
        },
        .kick => {
            try api.kick(gpa, url, out);
            if (out.items.len == 0) try streaming(gpa, url, body, out);
        },
        .peertube => try api.peertube(gpa, url, body, out),
        else => {
            if (std.mem.indexOf(u8, body, "PeerTube") != null or std.mem.indexOf(u8, body, "/videos/embed/") != null) {
                try api.peertube(gpa, url, body, out);
            }
        },
    }
}

/// YouTube: ask the Innertube iOS player first (it returns direct URLs and
/// an HLS master without a PO token), then fall back to the page's own
/// `streamingData` if it already has direct URLs.
fn youtube(gpa: std.mem.Allocator, url: []const u8, body: []const u8, out: *std.ArrayList(media.Format)) !void {
    var owned_json: ?[]u8 = null;
    defer if (owned_json) |j| gpa.free(j);
    const src = blk: {
        if (api.youtubePlayer(gpa, url, body)) |j| {
            owned_json = j;
            break :blk j;
        }
        break :blk body;
    };
    if (std.mem.indexOf(u8, src, "\"streamingData\"")) |_| {
        try readStreamingData(gpa, src, out);
    }
    // Skip HLS-only manifest variants when a direct MP4+audio stream exists at the
    // same resolution — wait: `hlsManifestUrl` hasn't been expanded yet here, so
    // only skip adding `hlsManifestUrl` when adaptive/progressive video already
    // yielded direct MP4 URLs.
    var have_video = false;
    for (out.items) |f| {
        if (f.kind == .video and f.url.len > 0) {
            have_video = true;
            break;
        }
    }
    if (!have_video) {
        if (pg.findJson(src, "hlsManifestUrl")) |u| {
            const clean = try pg.unescape(gpa, u);
            errdefer gpa.free(clean);
            if (std.mem.startsWith(u8, clean, "http")) {
                try out.append(gpa, .{ .id = try gpa.dupe(u8, "hls"), .label = try gpa.dupe(u8, "Auto"), .ext = try gpa.dupe(u8, "mp4"), .manifest = .{ .hls = clean }, .kind = .video });
            } else gpa.free(clean);
        }
    }
    pairBestAudio(gpa, out);
    // Keep only formats that already carry a playable URL/manifest.
    var has_direct = false;
    for (out.items) |f| {
        if (f.url.len > 0 or f.manifest != null) {
            has_direct = true;
            break;
        }
    }
    if (has_direct) {
        var i: usize = 0;
        while (i < out.items.len) {
            const f = out.items[i];
            if (f.url.len == 0 and f.manifest == null) {
                const rem = out.orderedRemove(i);
                gpa.free(rem.id);
                gpa.free(rem.label);
                gpa.free(rem.ext);
                gpa.free(rem.url);
                gpa.free(rem.audio_url);
                gpa.free(rem.codec);
                continue;
            }
            i += 1;
        }
    }
}

/// Gives every adaptive video format (separate stream, no muxed audio) the
/// best M4A audio URL from the same list so `job.run` muxes them into one MP4.
fn pairBestAudio(gpa: std.mem.Allocator, out: *std.ArrayList(media.Format)) void {
    var best_audio: ?media.Format = null;
    for (out.items) |f| {
        if (f.kind != .audio or f.url.len == 0) continue;
        if (best_audio == null or (std.mem.eql(u8, f.ext, "m4a") and !std.mem.eql(u8, best_audio.?.ext, "m4a")) or (std.mem.eql(u8, f.ext, best_audio.?.ext) and f.bitrate > best_audio.?.bitrate)) {
            best_audio = f;
        }
    }
    const au = best_audio orelse return;
    for (out.items) |*f| {
        if (f.kind != .video or f.url.len == 0 or f.audio_url.len > 0) continue;
        if (!std.mem.eql(u8, f.ext, "mp4")) continue;
        // Progressive itags (18, 22, 37, 38) already carry audio.
        if (std.mem.eql(u8, f.id, "18") or std.mem.eql(u8, f.id, "22")) continue;
        f.audio_url = gpa.dupe(u8, au.url) catch continue;
    }
}

/// Reads `formats` and `adaptiveFormats` out of a player response. The
/// array's objects nest (an `initRange` is one too), so they are walked by
/// depth rather than split on `},{`. Innertube pretty-prints `"formats": [`,
/// so whitespace between `:` and `[` is skipped.
fn readStreamingData(gpa: std.mem.Allocator, body: []const u8, out: *std.ArrayList(media.Format)) !void {
    for ([_][]const u8{ "\"formats\":", "\"adaptiveFormats\":" }) |key| {
        const at = std.mem.indexOf(u8, body, key) orelse continue;
        var i = at + key.len;
        while (i < body.len and (body[i] == ' ' or body[i] == '\t' or body[i] == '\n' or body[i] == '\r')) : (i += 1) {}
        if (i >= body.len or body[i] != '[') continue;
        i += 1;
        while (i < body.len) {
            // The next object at this level, or the end of the array.
            while (i < body.len and body[i] != '{' and body[i] != ']') : (i += 1) {}
            if (i >= body.len or body[i] == ']') break;
            const start = i;
            var depth: usize = 0;
            var in_str = false;
            while (i < body.len) : (i += 1) {
                if (in_str) {
                    if (body[i] == '\\') {
                        i += 1;
                        continue;
                    }
                    if (body[i] == '"') in_str = false;
                    continue;
                }
                switch (body[i]) {
                    '"' => in_str = true,
                    '{' => depth += 1,
                    '}' => {
                        depth -= 1;
                        if (depth == 0) {
                            i += 1;
                            break;
                        }
                    },
                    else => {},
                }
            }
            const obj = body[start..@min(i, body.len)];
            try readFormat(gpa, obj, out);
        }
    }
}

/// One entry of `formats` or `adaptiveFormats`.
fn readFormat(gpa: std.mem.Allocator, obj: []const u8, out: *std.ArrayList(media.Format)) !void {
    // A stream the site signs has no `url` here: it is listed with its
    // quality and size, and fetching it is the player's job, not this
    // reader's. It stays in the list so the preview tells the truth.
    // `url` may hold JSON `\u0026` escapes when read straight from Innertube or page JSON.
    const raw_direct = pg.findJson(obj, "url") orelse "";
    const direct = if (std.mem.startsWith(u8, raw_direct, "http")) try pg.unescape(gpa, raw_direct) else try gpa.dupe(u8, "");
    var f: media.Format = .{
        .id = try gpa.dupe(u8, pg.findJson(obj, "itag") orelse "0"),
        .url = direct,
        .ext = try gpa.dupe(u8, "mp4"),
        .codec = try gpa.dupe(u8, pg.findJson(obj, "codecs") orelse ""),
    };
    // The mime is "video/mp4; codecs=\"avc1.640028\"": extract both container and codec.
    if (pg.findJson(obj, "mimeType")) |mime| {
        const slash = std.mem.indexOfScalar(u8, mime, '/') orelse 0;
        const semi = std.mem.indexOfScalar(u8, mime, ';') orelse mime.len;
        if (semi > slash + 1) {
            gpa.free(f.ext);
            f.ext = try gpa.dupe(u8, mime[slash + 1 .. semi]);
        }
        if (f.codec.len == 0) {
            if (std.mem.indexOf(u8, mime, "codecs=")) |ci| {
                gpa.free(f.codec);
                f.codec = try gpa.dupe(u8, mime[ci + 7 ..]);
            }
        }
        f.kind = if (std.mem.startsWith(u8, mime, "audio/")) .audio else .video;
    }
    if (pg.findJson(obj, "bitrate")) |b| f.bitrate = std.fmt.parseInt(u32, b, 10) catch 0;
    if (pg.findJson(obj, "width")) |w| f.width = std.fmt.parseInt(u32, w, 10) catch 0;
    if (pg.findJson(obj, "height")) |h| f.height = std.fmt.parseInt(u32, h, 10) catch 0;
    if (pg.findJson(obj, "contentLength")) |c| f.size = std.fmt.parseInt(u64, c, 10) catch 0;
    // Only keep MP4/M4A/MOV adaptive tracks or progressive formats cleanly muxable
    // into MP4; AV1/VP9 codecs still work if MP4, or user picks H.264 by default.
    // Prefer H.264 (`avc1`) over AV1 (`av01`) at equal resolution in `better`.
    if (f.kind == .video and f.height == 0) {
        gpa.free(f.id);
        gpa.free(f.url);
        gpa.free(f.ext);
        gpa.free(f.codec);
        return;
    }
    f.label = try labelFor(gpa, f);
    try out.append(gpa, f);
}

/// Bilibili: reads `window.__playinfo__` when present, or asks Bilibili's
/// public `view` + `playurl` API when the page omitted it. DASH video formats
/// are paired with the best audio track so `job.run` muxes them into one MP4.
fn bilibili(gpa: std.mem.Allocator, url: []const u8, body: []const u8, out: *std.ArrayList(media.Format)) !void {
    var owned_json: ?[]u8 = null;
    defer if (owned_json) |j| gpa.free(j);
    const json = blk: {
        if (std.mem.indexOf(u8, body, "__playinfo__")) |at| {
            if (std.mem.indexOfScalarPos(u8, body, at, '{')) |brace| {
                if (pg.sliceObject(body, brace)) |j| break :blk j;
            }
        }
        if (bilibiliApi(gpa, url)) |j| {
            owned_json = j;
            break :blk j;
        }
        return;
    };

    // `dash.video[]` and `dash.audio[]`.
    for ([_]struct { key: []const u8, kind: media.Format.Kind }{
        .{ .key = "\"video\":[", .kind = .video },
        .{ .key = "\"audio\":[", .kind = .audio },
    }) |want| {
        const list_at = std.mem.indexOf(u8, json, want.key) orelse continue;
        var i = list_at + want.key.len;
        var depth: usize = 1;
        const start = i;
        while (i < json.len and depth > 0) : (i += 1) {
            switch (json[i]) {
                '[' => depth += 1,
                ']' => depth -= 1,
                else => {},
            }
        }
        var objects = std.mem.splitSequence(u8, json[start..i], "},{");
        while (objects.next()) |obj| {
            const raw_direct = pg.findJson(obj, "baseUrl") orelse pg.findJson(obj, "base_url") orelse continue;
            const direct = try pg.unescape(gpa, raw_direct);
            var f: media.Format = .{
                .id = try gpa.dupe(u8, pg.findJson(obj, "id") orelse "0"),
                .url = direct,
                .ext = try gpa.dupe(u8, if (want.kind == .video) "mp4" else "m4a"),
                .kind = want.kind,
                .codec = try gpa.dupe(u8, pg.findJson(obj, "codecs") orelse ""),
            };
            if (pg.findJson(obj, "bandwidth")) |b| f.bitrate = std.fmt.parseInt(u32, b, 10) catch 0;
            if (pg.findJson(obj, "width")) |w| f.width = std.fmt.parseInt(u32, w, 10) catch 0;
            if (pg.findJson(obj, "height")) |h| f.height = std.fmt.parseInt(u32, h, 10) catch 0;
            f.label = try labelFor(gpa, f);
            try out.append(gpa, f);
        }
    }
    pairBestAudio(gpa, out);
    // `durl` is a progressive file, split into parts; fallback to fnval=1 when DASH is absent.
    if (out.items.len == 0) {
        if (std.mem.indexOf(u8, json, "\"durl\":[")) |d| {
            var i = d;
            while (std.mem.indexOfPos(u8, json, i, "\"url\":\"")) |u_at| {
                const from = u_at + 7;
                const close = std.mem.indexOfScalarPos(u8, json, from, '"') orelse break;
                try out.append(gpa, .{
                    .id = try gpa.dupe(u8, "0"),
                    .label = try gpa.dupe(u8, "Original"),
                    .ext = try gpa.dupe(u8, "mp4"),
                    .url = try pg.unescape(gpa, json[from..close]),
                    .kind = .video,
                });
                i = close;
            }
        }
    }
}

/// Gives every H.264/MP4 video format the best audio track so `job.run` muxes them.
/// Wait: `formats` also keeps standalone audio entries for "Download as Audio".
/// Note: in `bilibili` JSON, `mimeType` / `codecs` sits inside each object.
// Note: Bilibili `fnval=16` is DASH fMP4 (`avc1`/`hev1`/`av01`).
// Also ensure `youtube` `readFormat` reads `codecs` even when `mimeType` has `"video/mp4; codecs=\"avc1.640028\""`.

fn bilibiliApi(gpa: std.mem.Allocator, url: []const u8) ?[]u8 {
    const bvid = bilibiliBv(url) orelse return null;
    var view_buf: [160]u8 = undefined;
    const view_url = std.fmt.bufPrint(&view_buf, "https://api.bilibili.com/x/web-interface/view?bvid={s}", .{bvid}) catch return null;
    var vr = fetch(gpa, view_url, url);
    defer vr.deinit();
    if (vr.status() != 200) return null;
    const cid = pg.findJson(vr.body(), "cid") orelse return null;
    var play_buf: [256]u8 = undefined;
    const play_url = std.fmt.bufPrint(&play_buf, "https://api.bilibili.com/x/player/playurl?bvid={s}&cid={s}&qn=80&fnval=16", .{ bvid, cid }) catch return null;
    var pr = fetch(gpa, play_url, url);
    defer pr.deinit();
    if (pr.status() != 200 or pr.body().len == 0) return null;
    return gpa.dupe(u8, pr.body()) catch null;
}

fn bilibiliBv(url: []const u8) ?[]const u8 {
    const at = std.mem.indexOf(u8, url, "BV") orelse return null;
    const rest = url[at..];
    var end: usize = 0;
    while (end < rest.len and std.ascii.isAlphanumeric(rest[end])) : (end += 1) {}
    return if (end >= 12) rest[0..end] else null;
}

fn vimeo(gpa: std.mem.Allocator, url: []const u8, body: []const u8, out: *std.ArrayList(media.Format)) !void {
    // The page is a shell: what it plays comes from the player's config,
    // which names an HLS playlist per CDN. `progressive` is empty now.
    if (std.mem.indexOf(u8, body, "\"progressive\":[") != null and std.mem.indexOf(u8, body, "\"url\":\"http") != null) {
        var i: usize = 0;
        while (std.mem.indexOfPos(u8, body, i, "\"url\":\"")) |u_at| {
            const from = u_at + 7;
            const close = std.mem.indexOfScalarPos(u8, body, from, '"') orelse break;
            const link = body[from..close];
            i = close;
            if (!std.mem.startsWith(u8, link, "http")) continue;
            var f: media.Format = .{ .id = try gpa.dupe(u8, "0"), .url = try gpa.dupe(u8, link), .ext = try gpa.dupe(u8, "mp4"), .kind = .video };
            if (pg.findJson(body[from..@min(from + 400, body.len)], "height")) |h| f.height = std.fmt.parseInt(u32, h, 10) catch 0;
            f.label = try labelFor(gpa, f);
            try out.append(gpa, f);
        }
        if (out.items.len > 0) return;
    }
    const id = vimeoId(url) orelse return;
    var buf: [128]u8 = undefined;
    const cfg_url = std.fmt.bufPrint(&buf, "https://player.vimeo.com/video/{s}/config", .{id}) catch return;
    var r = fetch(gpa, cfg_url, "https://vimeo.com/");
    defer r.deinit();
    if (r.status() != 200) return;
    // The default CDN's playlist carries every rendition.
    const at = std.mem.indexOf(u8, r.body(), "\"hls\":{") orelse return;
    const files = r.body()[at..];
    const u_at = std.mem.indexOf(u8, files, "\"url\":\"") orelse return;
    const from = u_at + 7;
    const close = std.mem.indexOfScalarPos(u8, files, from, '"') orelse return;
    const link = files[from..close];
    if (!std.mem.startsWith(u8, link, "http")) return;
    const hls_url = try pg.unescape(gpa, link);
    defer gpa.free(hls_url);
    // Vimeo's master names no key; the media playlist under it does, and it
    // is DRM. Read it here so the refusal comes before a download, not after.
    var probe = fetch(gpa, hls_url, "https://player.vimeo.com/");
    defer probe.deinit();
    if (probe.status() == 200) {
        var mp = hls.parse(gpa, hls_url, probe.body()) catch return;
        defer mp.deinit(gpa);
        if (mp.isMaster()) {
            for (mp.variants.items) |v| {
                var sub = fetch(gpa, v.url, hls_url);
                defer sub.deinit();
                if (sub.status() != 200) continue;
                var mpl = hls.parse(gpa, v.url, sub.body()) catch break;
                defer mpl.deinit(gpa);
                if (mpl.isDrm()) return error.Drm;
                break;
            }
        } else if (mp.isDrm()) return error.Drm;
    }
    try out.append(gpa, .{
        .id = try gpa.dupe(u8, "hls"),
        .label = try gpa.dupe(u8, "Auto"),
        .ext = try gpa.dupe(u8, "mp4"),
        .manifest = .{ .hls = try gpa.dupe(u8, hls_url) },
        .kind = .video,
    });
}

/// The number in a Vimeo address: `vimeo.com/76979871`, `vimeo.com/name/76979871`.
fn vimeoId(url: []const u8) ?[]const u8 {
    var i = url.len;
    while (i > 0) {
        i -= 1;
        if (url[i] == '/') break;
    }
    const tail = url[i + 1 ..];
    const q = std.mem.indexOfAny(u8, tail, "?#") orelse tail.len;
    const id = tail[0..q];
    if (id.len == 0) return null;
    for (id) |ch| if (!std.ascii.isDigit(ch)) return null;
    return id;
}

/// The whole JSON string value that holds `needle`, from its opening quote to
/// its closing one. `findAnyUrl` stops at the marker, which is right for a
/// file name and wrong for an endpoint whose path continues past it.
fn jsonStringAt(body: []const u8, needle: []const u8) ?[]const u8 {
    const at = std.mem.indexOf(u8, body, needle) orelse return null;
    var start = at;
    while (start > 0) : (start -= 1) {
        if (body[start - 1] == '"') break;
    }
    if (start == 0) return null;
    var end = at;
    while (end < body.len) : (end += 1) {
        if (body[end] == '"') break;
    }
    if (end >= body.len) return null;
    return body[start..end];
}

/// SoundCloud: the track page carries a hydration blob holding a client id
/// and the track's transcodings. Each transcoding is an endpoint that hands
/// out the real stream once the client id is on it, so the page is read for
/// both and the endpoint is asked. The presets name the qualities, and two of
/// them can resolve to one stream, which is listed once.
fn soundcloud(gpa: std.mem.Allocator, url: []const u8, body: []const u8, out: *std.ArrayList(media.Format)) !void {
    // `apiClient` is an object, not a string, so `findJson` cannot read it:
    // the client id is the `id` inside it.
    const cli_at = std.mem.indexOf(u8, body, "\"apiClient\"") orelse return;
    const cid = pg.findJson(body[cli_at..], "id") orelse return;

    var i: usize = 0;
    while (std.mem.indexOfPos(u8, body, i, "\"preset\"")) |at| {
        i = at + 8;
        const preset = pg.findJson(body[i..], "preset") orelse continue;
        const proto = pg.findJson(body[i..], "protocol") orelse continue;
        const is_hls = std.mem.eql(u8, proto, "hls");
        if (!is_hls and !std.mem.eql(u8, proto, "progressive")) continue;
        // The endpoint sits before the preset in the same object, and its path
        // runs past `/stream/`, so the whole string is read rather than a
        // prefix of it.
        const from = if (at > 400) at - 400 else 0;
        const endpoint = jsonStringAt(body[from..at], "/stream/") orelse continue;
        const full = try std.fmt.allocPrint(gpa, "{s}?client_id={s}", .{ endpoint, cid });
        defer gpa.free(full);
        var resp = fetch(gpa, full, url);
        defer resp.deinit();
        if (resp.status() != 200) continue;
        const real = pg.findJson(resp.body(), "url") orelse continue;
        if (!std.mem.startsWith(u8, real, "http")) continue;
        if (alreadyListed(out, real)) continue;

        const ext = if (is_hls) "mp4" else if (std.mem.indexOf(u8, real, ".mp3") != null) "mp3" else "m4a";
        const label = try gpa.dupe(u8, preset);
        errdefer gpa.free(label);
        const id = try gpa.dupe(u8, preset);
        errdefer gpa.free(id);
        if (is_hls) {
            try out.append(gpa, .{ .id = id, .label = label, .ext = try gpa.dupe(u8, ext), .manifest = .{ .hls = try gpa.dupe(u8, real) }, .kind = .audio });
        } else {
            try out.append(gpa, .{ .id = id, .label = label, .ext = try gpa.dupe(u8, ext), .url = try gpa.dupe(u8, real), .kind = .audio });
        }
    }
}

/// Whether a stream is already in the list, by the URL it would be fetched
/// from. SoundCloud's presets overlap.
pub fn alreadyListed(out: *const std.ArrayList(media.Format), url: []const u8) bool {
    for (out.items) |f| {
        const have = if (f.manifest) |mf| switch (mf) {
            .hls => |h| h,
            .dash => |d| d,
        } else f.url;
        if (std.mem.eql(u8, have, url)) return true;
    }
    return false;
}

/// Bandcamp: the page carries its release as `data-tralbum`, an attribute
/// holding JSON with its HTML entities escaped. Each track in it names a
/// `mp3-128` stream on bcbits, which is the file the player streams.
fn bandcamp(gpa: std.mem.Allocator, body: []const u8, out: *std.ArrayList(media.Format)) !void {
    const at = std.mem.indexOf(u8, body, "data-tralbum=") orelse return;
    const tail = body[at..];
    var i: usize = 0;
    while (std.mem.indexOfPos(u8, tail, i, "mp3-128")) |m| {
        i = m + 7;
        // The value follows the key: `"mp3-128":"https://…"`, with its quotes
        // written as `&quot;`.
        const after = m + 7;
        const chunk = tail[after..@min(after + 400, tail.len)];
        const raw = firstEscapedUrl(chunk) orelse continue;
        const unescaped = try pg.unescape(gpa, raw);
        defer gpa.free(unescaped);
        // The attribute is HTML, so its `&amp;` is an ampersand in the URL.
        const u = try undouble(gpa, unescaped);
        defer gpa.free(u);
        if (!std.mem.startsWith(u8, u, "http")) continue;
        if (alreadyListed(out, u)) continue;
        const label = try std.fmt.allocPrint(gpa, "MP3 {d}", .{out.items.len + 1});
        errdefer gpa.free(label);
        try out.append(gpa, .{
            .id = try std.fmt.allocPrint(gpa, "{d}", .{out.items.len}),
            .label = label,
            .ext = try gpa.dupe(u8, "mp3"),
            .url = try gpa.dupe(u8, u),
            .kind = .audio,
        });
    }
}

/// `&amp;` written as it is in an HTML attribute, turned back into `&`.
pub fn undouble(gpa: std.mem.Allocator, s: []const u8) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);
    var i: usize = 0;
    while (i < s.len) {
        if (std.mem.startsWith(u8, s[i..], "&amp;")) {
            try out.append(gpa, '&');
            i += 5;
            continue;
        }
        try out.append(gpa, s[i]);
        i += 1;
    }
    return out.toOwnedSlice(gpa);
}

/// The first `&quot;http…&quot;` value in a chunk: Bandcamp writes the URL
/// just after the `mp3-128` key that names its format.
fn firstEscapedUrl(chunk: []const u8) ?[]const u8 {
    const open = "&quot;http";
    const at = std.mem.indexOf(u8, chunk, open) orelse return null;
    const from = at + 6;
    const end = std.mem.indexOfPos(u8, chunk, from, "&quot;") orelse return null;
    return chunk[from..end];
}

fn streaming(gpa: std.mem.Allocator, url: []const u8, body: []const u8, out: *std.ArrayList(media.Format)) !void {
    // A live channel's HLS manifest is named in the page.
    if (pg.findJson(body, "hls_url") orelse pg.findJson(body, "hlsUrl") orelse pg.findJson(body, "playbackUrl")) |u| {
        if (std.mem.startsWith(u8, u, "http")) {
            try out.append(gpa, .{ .id = try gpa.dupe(u8, "hls"), .label = try gpa.dupe(u8, "Live"), .ext = try gpa.dupe(u8, "mp4"), .manifest = .{ .hls = try gpa.dupe(u8, u) }, .kind = .video });
            return;
        }
    }
    if (std.mem.indexOf(u8, body, ".m3u8")) |_| {
        if (pg.findAnyUrl(body, ".m3u8")) |u| {
            try out.append(gpa, .{ .id = try gpa.dupe(u8, "hls"), .label = try gpa.dupe(u8, "Live"), .ext = try gpa.dupe(u8, "mp4"), .manifest = .{ .hls = try gpa.dupe(u8, u) }, .kind = .video });
        }
    }
    _ = url;
}

test "a soundcloud page's client id is read from its hydration blob" {
    // `apiClient` is an object, so its `id` is the client id, not its value.
    const body = "{\"hydratable\":\"apiClient\",\"data\":{\"id\":\"QhVE\",\"isExpiring\":true}}";
    const at = std.mem.indexOf(u8, body, "\"apiClient\"").?;
    try std.testing.expectEqualStrings("QhVE", pg.findJson(body[at..], "id").?);
}


test "a bandcamp track's mp3 is read from its escaped tralbum" {
    // The attribute is HTML, so its quotes are `&quot;` and its ampersands
    // `&amp;`, and the URL follows the `mp3-128` key.
    const body = "<div data-tralbum=\"{&quot;file&quot;:{&quot;mp3-128&quot;:&quot;https://t4.bcbits.com/stream/a/mp3-128/1?p=0&amp;ts=9&quot;}}\">";
    var out: std.ArrayList(media.Format) = .empty;
    defer {
        for (out.items) |f| {
            std.testing.allocator.free(f.id);
            std.testing.allocator.free(f.label);
            std.testing.allocator.free(f.ext);
            std.testing.allocator.free(f.url);
        }
        out.deinit(std.testing.allocator);
    }
    try bandcamp(std.testing.allocator, body, &out);
    try std.testing.expectEqual(@as(usize, 1), out.items.len);
    try std.testing.expectEqualStrings("https://t4.bcbits.com/stream/a/mp3-128/1?p=0&ts=9", out.items[0].url);
    try std.testing.expectEqual(media.Format.Kind.audio, out.items[0].kind);
}


test "a stream already listed is not listed twice" {
    var out: std.ArrayList(media.Format) = .empty;
    defer out.deinit(std.testing.allocator);
    try out.append(std.testing.allocator, .{ .url = "https://x/a.mp3" });
    try std.testing.expect(alreadyListed(&out, "https://x/a.mp3"));
    try std.testing.expect(!alreadyListed(&out, "https://x/b.mp3"));
}

