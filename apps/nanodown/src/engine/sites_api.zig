//! Site-specific readers for services whose streams sit behind a JSON API,
//! GraphQL call, or HTML-escaped attribute rather than plain `<video>` tags.
//! `sites.zig` stays under 600 lines by keeping these in a module of its own.
const std = @import("std");
const nanoui = @import("nanoui");
const media = @import("../model/media.zig");
const http = @import("http.zig");
const pg = @import("page.zig");
const extract = @import("extract.zig");

const httpz = http;
const fetch = extract.fetch;
const labelFor = extract.labelFor;
const sites = @import("sites.zig");

/// PeerTube: any instance exposes `/api/v1/videos/<uuid>` for `/w/<id>` or
/// `/videos/watch/<id>`. Gives clean HLS and MP4 files.
pub fn peertube(gpa: std.mem.Allocator, url: []const u8, body: []const u8, out: *std.ArrayList(media.Format)) !void {
    _ = body;
    const vid = peertubeId(url) orelse return;
    const scheme_end = std.mem.indexOf(u8, url, "://") orelse return;
    const host_end = std.mem.indexOfScalarPos(u8, url, scheme_end + 3, '/') orelse url.len;
    const origin = url[0..host_end];
    const api = try std.fmt.allocPrint(gpa, "{s}/api/v1/videos/{s}", .{ origin, vid });
    defer gpa.free(api);
    var r = fetch(gpa, api, url);
    defer r.deinit();
    if (r.status() != 200) return;
    if (pg.findJson(r.body(), "playlistUrl")) |raw| {
        const u = try pg.unescape(gpa, raw);
        if (std.mem.startsWith(u8, u, "http")) {
            try out.append(gpa, .{
                .id = try gpa.dupe(u8, "hls"),
                .label = try gpa.dupe(u8, "Auto"),
                .ext = try gpa.dupe(u8, "mp4"),
                .manifest = .{ .hls = u },
                .kind = .video,
            });
            return;
        }
        gpa.free(u);
    }
    if (pg.findJson(r.body(), "fileDownloadUrl")) |raw| {
        const u = try pg.unescape(gpa, raw);
        if (std.mem.startsWith(u8, u, "http")) {
            try out.append(gpa, .{
                .id = try gpa.dupe(u8, "0"),
                .label = try gpa.dupe(u8, "Original"),
                .ext = try gpa.dupe(u8, "mp4"),
                .url = u,
                .kind = .video,
            });
        } else gpa.free(u);
    }
}

fn peertubeId(url: []const u8) ?[]const u8 {
    for ([_][]const u8{ "/w/", "/videos/watch/", "/videos/embed/" }) |pat| {
        if (std.mem.indexOf(u8, url, pat)) |at| {
            const rest = url[at + pat.len ..];
            const end = std.mem.indexOfAny(u8, rest, "/?#") orelse rest.len;
            if (end > 0) return rest[0..end];
        }
    }
    return null;
}

/// YouTube video id from `/watch?v=...`, `youtu.be/...`, `/shorts/...`, `/live/...`.
pub fn youtubeId(url: []const u8) ?[]const u8 {
    if (std.mem.indexOf(u8, url, "v=")) |at| {
        const rest = url[at + 2 ..];
        const end = std.mem.indexOfAny(u8, rest, "&?#/") orelse rest.len;
        if (end >= 8) return rest[0..end];
    }
    for ([_][]const u8{ "youtu.be/", "/shorts/", "/live/", "/embed/" }) |pat| {
        if (std.mem.indexOf(u8, url, pat)) |at| {
            const rest = url[at + pat.len ..];
            const end = std.mem.indexOfAny(u8, rest, "?&#/") orelse rest.len;
            if (end >= 8) return rest[0..end];
        }
    }
    return null;
}

/// Asks YouTube's Innertube iOS player for direct stream URLs using the
/// API key embedded in the watch page. Returns the raw JSON response body
/// (owned by `gpa`) when it holds usable URLs.
pub fn youtubePlayer(gpa: std.mem.Allocator, url: []const u8, body: []const u8) ?[]u8 {
    const vid = youtubeId(url) orelse return null;
    const key = pg.findJson(body, "INNERTUBE_API_KEY") orelse return null;
    var endpoint_buf: [256]u8 = undefined;
    const endpoint = std.fmt.bufPrint(&endpoint_buf, "https://www.youtube.com/youtubei/v1/player?key={s}", .{key}) catch return null;
    var req_buf: [256]u8 = undefined;
    const req_body = std.fmt.bufPrint(&req_buf, "{{\"videoId\":\"{s}\",\"context\":{{\"client\":{{\"clientName\":\"IOS\",\"clientVersion\":\"20.10.4\"}}}}}}", .{vid}) catch return null;
    const headers = [_]nanoui.http.Header{
        .{ .name = "Content-Type", .value = "application/json" },
        .{ .name = "User-Agent", .value = "com.google.ios.youtube/20.10.4 (iPhone16,2; U; CPU iOS 18_3_2 like Mac OS X;)" },
    };
    var r = httpz.send(gpa, .{ .url = endpoint, .method = "POST", .headers = &headers, .body = req_body, .timeout = 20 });
    defer r.deinit();
    if (r.status() != 200 or r.body().len == 0) return null;
    if (std.mem.indexOf(u8, r.body(), "\"streamingData\"") == null) return null;
    return gpa.dupe(u8, r.body()) catch null;
}

/// Facebook: `browser_native_hd_url` and `browser_native_sd_url` carry direct
/// MP4 URLs in the HTML when fetched with a desktop Chrome user-agent.
pub fn facebook(gpa: std.mem.Allocator, body: []const u8, out: *std.ArrayList(media.Format)) !void {
    const entries = [_]struct { key: []const u8, label: []const u8, height: u32 }{
        .{ .key = "browser_native_hd_url", .label = "HD", .height = 720 },
        .{ .key = "browser_native_sd_url", .label = "SD", .height = 360 },
        .{ .key = "playable_url_quality_hd", .label = "HD", .height = 720 },
        .{ .key = "playable_url", .label = "SD", .height = 360 },
    };
    for (entries) |e| {
        const raw = pg.findJson(body, e.key) orelse continue;
        const u = try pg.unescape(gpa, raw);
        errdefer gpa.free(u);
        if (!std.mem.startsWith(u8, u, "http")) {
            gpa.free(u);
            continue;
        }
        try out.append(gpa, .{
            .id = try gpa.dupe(u8, e.key),
            .label = try gpa.dupe(u8, e.label),
            .ext = try gpa.dupe(u8, "mp4"),
            .url = u,
            .height = e.height,
            .kind = .video,
        });
    }
}

/// X / Twitter: activates a guest token on `api.x.com` and queries
/// `TweetResultByRestId` for every MP4 and HLS variant, falling back to
/// `cdn.syndication.twimg.com` if needed.
pub fn xPost(gpa: std.mem.Allocator, url: []const u8, out: *std.ArrayList(media.Format)) !void {
    const tid = xStatusId(url) orelse return;
    const bearer = "Bearer AAAAAAAAAAAAAAAAAAAAANRILgAAAAAAnNwIzUejRCOuH5E6I8xnZz4puTs%3D1Zv7ttfk8LF81IUq16cHjhLTvJu4FA33AGWWjCpTnA";
    const gt_headers = [_]nanoui.http.Header{
        .{ .name = "Authorization", .value = bearer },
        httpz.user_agent,
    };
    var gt_resp = httpz.send(gpa, .{ .url = "https://api.x.com/1.1/guest/activate.json", .method = "POST", .headers = &gt_headers, .body = "", .timeout = 15 });
    defer gt_resp.deinit();
    if (gt_resp.status() == 200) {
        if (pg.findJson(gt_resp.body(), "guest_token")) |gt| {
            var u_buf: [2048]u8 = undefined;
            const gql = std.fmt.bufPrint(
                &u_buf,
                "https://api.x.com/graphql/0hWvDhmW8YQ-S_ib3azIrw/TweetResultByRestId?variables=%7B%22tweetId%22%3A%22{s}%22%2C%22withCommunity%22%3Afalse%2C%22includePromotedContent%22%3Afalse%2C%22withVoice%22%3Afalse%7D&features=%7B%22creator_subscriptions_tweet_preview_api_enabled%22%3Atrue%2C%22communities_web_enable_tweet_community_results_fetch%22%3Atrue%2C%22c9s_tweet_anatomy_moderator_badge_enabled%22%3Atrue%2C%22articles_preview_enabled%22%3Atrue%2C%22responsive_web_edit_tweet_api_enabled%22%3Atrue%2C%22graphql_is_translatable_rweb_tweet_is_translatable_enabled%22%3Atrue%2C%22view_counts_everywhere_api_enabled%22%3Atrue%2C%22longform_notetweets_consumption_enabled%22%3Atrue%2C%22responsive_web_twitter_article_tweet_consumption_enabled%22%3Atrue%2C%22tweet_awards_web_tipping_enabled%22%3Afalse%2C%22creator_subscriptions_quote_tweet_preview_api_enabled%22%3Afalse%2C%22freedom_of_speech_not_reach_fetch_enabled%22%3Atrue%2C%22standardized_nudges_misinfo%22%3Atrue%2C%22tweet_with_visibility_results_prefer_gql_limited_actions_policy_enabled%22%3Atrue%2C%22rweb_video_timestamps_enabled%22%3Atrue%2C%22longform_notetweets_rich_text_read_enabled%22%3Atrue%2C%22longform_notetweets_inline_media_enabled%22%3Atrue%2C%22responsive_web_enhance_cards_enabled%22%3Afalse%7D",
                .{tid},
            ) catch "";
            if (gql.len > 0) {
                const headers = [_]nanoui.http.Header{
                    .{ .name = "Authorization", .value = bearer },
                    .{ .name = "x-guest-token", .value = gt },
                    httpz.user_agent,
                };
                var res = httpz.send(gpa, .{ .url = gql, .headers = &headers, .timeout = 15 });
                defer res.deinit();
                if (res.status() == 200) try collectXVariants(gpa, res.body(), out);
            }
        }
    }
    if (out.items.len == 0) {
        var s_buf: [160]u8 = undefined;
        const syn = std.fmt.bufPrint(&s_buf, "https://cdn.syndication.twimg.com/tweet-result?id={s}&token=42", .{tid}) catch return;
        var sr = fetch(gpa, syn, url);
        defer sr.deinit();
        if (sr.status() == 200) try collectXVariants(gpa, sr.body(), out);
    }
}

fn collectXVariants(gpa: std.mem.Allocator, body: []const u8, out: *std.ArrayList(media.Format)) !void {
    var i: usize = 0;
    while (std.mem.indexOfPos(u8, body, i, "https://video.twimg.com/")) |at| {
        var end = at;
        while (end < body.len and body[end] != '"' and body[end] != '\\' and body[end] != ' ') : (end += 1) {}
        const u = body[at..end];
        i = end;
        if (std.mem.indexOf(u8, u, ".mp4") == null and std.mem.indexOf(u8, u, ".m3u8") == null) continue;
        // Deduplicate by URL.
        var dup = false;
        for (out.items) |f| {
            const have = if (f.manifest) |mf| switch (mf) {
                .hls => |h| h,
                .dash => |d| d,
            } else f.url;
            if (std.mem.eql(u8, have, u)) {
                dup = true;
                break;
            }
        }
        if (dup) continue;
        const is_hls = std.mem.indexOf(u8, u, ".m3u8") != null;
        const h = heightFromDims(u);
        if (is_hls) {
            try out.append(gpa, .{
                .id = try gpa.dupe(u8, "hls"),
                .label = try gpa.dupe(u8, "Auto"),
                .ext = try gpa.dupe(u8, "mp4"),
                .manifest = .{ .hls = try gpa.dupe(u8, u) },
                .kind = .video,
            });
        } else {
            var lbuf: [16]u8 = undefined;
            const lbl = if (h > 0) (std.fmt.bufPrint(&lbuf, "{d}p", .{h}) catch "MP4") else "MP4";
            try out.append(gpa, .{
                .id = try gpa.dupe(u8, lbl),
                .label = try gpa.dupe(u8, lbl),
                .ext = try gpa.dupe(u8, "mp4"),
                .url = try gpa.dupe(u8, u),
                .height = h,
                .kind = .video,
            });
        }
    }
}

fn heightFromDims(u: []const u8) u32 {
    var it = std.mem.splitScalar(u8, u, '/');
    while (it.next()) |seg| {
        const x = std.mem.indexOfScalar(u8, seg, 'x') orelse continue;
        const w = std.fmt.parseInt(u32, seg[0..x], 10) catch continue;
        const h = std.fmt.parseInt(u32, seg[x + 1 ..], 10) catch continue;
        if (w >= 100 and h >= 100) return h;
    }
    return 0;
}

pub fn xStatusId(url: []const u8) ?[]const u8 {
    const at = std.mem.indexOf(u8, url, "/status/") orelse return null;
    const rest = url[at + 8 ..];
    var end: usize = 0;
    while (end < rest.len and std.ascii.isDigit(rest[end])) : (end += 1) {}
    return if (end > 0) rest[0..end] else null;
}

/// Mixcloud: GraphQL `cloudcastLookup` hands back `streamInfo.hlsUrl` XORed
/// with Mixcloud's static key; decoding it yields the `.m3u8` master playlist.
pub fn mixcloud(gpa: std.mem.Allocator, url: []const u8, out: *std.ArrayList(media.Format)) !void {
    const pair = mixcloudPath(url) orelse return;
    const q = try std.fmt.allocPrint(
        gpa,
        "{{\"query\":\"query {{ cloudcastLookup(lookup: {{username: \\\"{s}\\\", slug: \\\"{s}\\\"}}) {{ name streamInfo {{ hlsUrl url }} }} }}\"}}",
        .{ pair.user, pair.slug },
    );
    defer gpa.free(q);
    const headers = [_]nanoui.http.Header{
        .{ .name = "Content-Type", .value = "application/json" },
        httpz.user_agent,
    };
    var r = httpz.send(gpa, .{ .url = "https://app.mixcloud.com/graphql", .method = "POST", .headers = &headers, .body = q, .timeout = 15 });
    defer r.deinit();
    if (r.status() != 200) return;
    const enc = pg.findJson(r.body(), "hlsUrl") orelse return;
    const dec = decodeMixcloud(gpa, enc) catch return;
    if (!std.mem.startsWith(u8, dec, "http")) {
        gpa.free(dec);
        return;
    }
    try out.append(gpa, .{
        .id = try gpa.dupe(u8, "hls"),
        .label = try gpa.dupe(u8, "Audio"),
        .ext = try gpa.dupe(u8, "mp4"),
        .manifest = .{ .hls = dec },
        .kind = .audio,
    });
}

fn mixcloudPath(url: []const u8) ?struct { user: []const u8, slug: []const u8 } {
    const host_at = std.mem.indexOf(u8, url, "mixcloud.com/") orelse return null;
    const rest = url[host_at + "mixcloud.com/".len ..];
    const s1 = std.mem.indexOfScalar(u8, rest, '/') orelse return null;
    const user = rest[0..s1];
    const after = rest[s1 + 1 ..];
    const end = std.mem.indexOfAny(u8, after, "/?#") orelse after.len;
    const slug = after[0..end];
    if (user.len == 0 or slug.len == 0) return null;
    return .{ .user = user, .slug = slug };
}

pub fn decodeMixcloud(gpa: std.mem.Allocator, enc: []const u8) ![]u8 {
    const n = try std.base64.standard.Decoder.calcSizeForSlice(enc);
    const buf = try gpa.alloc(u8, n);
    errdefer gpa.free(buf);
    try std.base64.standard.Decoder.decode(buf, enc);
    const key = "IFYOUWANTTHEARTISTSTOGETPAIDDONOTDOWNLOADFROMMIXCLOUD";
    for (buf, 0..) |*b, i| b.* ^= key[i % key.len];
    return buf;
}

/// Streamable: `api.streamable.com/videos/<code>` returns clean MP4 files.
pub fn streamable(gpa: std.mem.Allocator, url: []const u8, out: *std.ArrayList(media.Format)) !void {
    const code = streamableId(url) orelse return;
    var u_buf: [160]u8 = undefined;
    const api = std.fmt.bufPrint(&u_buf, "https://api.streamable.com/videos/{s}", .{code}) catch return;
    var r = fetch(gpa, api, url);
    defer r.deinit();
    if (r.status() != 200) return;
    var i: usize = 0;
    while (std.mem.indexOfPos(u8, r.body(), i, "\"url\":\"http")) |at| {
        const from = at + 7;
        const close = std.mem.indexOfScalarPos(u8, r.body(), from, '"') orelse break;
        i = close;
        const raw = r.body()[from..close];
        if (std.mem.indexOf(u8, raw, ".mp4") == null) continue;
        const u = try pg.unescape(gpa, raw);
        errdefer gpa.free(u);
        const h_ctx = r.body()[if (at > 200) at - 200 else 0 .. at];
        const h: u32 = if (pg.findJson(h_ctx, "height")) |hv| std.fmt.parseInt(u32, hv, 10) catch 0 else 0;
        var f: media.Format = .{
            .id = try std.fmt.allocPrint(gpa, "{d}", .{out.items.len}),
            .ext = try gpa.dupe(u8, "mp4"),
            .url = u,
            .height = h,
            .kind = .video,
        };
        f.label = try labelFor(gpa, f);
        try out.append(gpa, f);
    }
}

fn streamableId(url: []const u8) ?[]const u8 {
    const at = std.mem.indexOf(u8, url, "streamable.com/") orelse return null;
    var rest = url[at + "streamable.com/".len ..];
    if (std.mem.startsWith(u8, rest, "e/")) rest = rest[2..];
    if (std.mem.startsWith(u8, rest, "m/")) rest = rest[2..];
    const end = std.mem.indexOfAny(u8, rest, "/?#") orelse rest.len;
    return if (end > 0) rest[0..end] else null;
}

/// Twitch: live streams, VODs (`/videos/<id>`), and clips via public GraphQL + Usher.
pub fn twitch(gpa: std.mem.Allocator, url: []const u8, out: *std.ArrayList(media.Format)) !void {
    const cid = "kimne78kx3ncx6brgo4mv6wki5h1ko";
    const headers = [_]nanoui.http.Header{
        .{ .name = "Client-ID", .value = cid },
        .{ .name = "Content-Type", .value = "application/json" },
        httpz.user_agent,
    };
    if (std.mem.indexOf(u8, url, "/clip/") != null or std.mem.indexOf(u8, url, "clips.twitch.tv/") != null) {
        const slug = lastSegment(url) orelse return;
        const q = try std.fmt.allocPrint(
            gpa,
            "{{\"operationName\":\"VideoAccessToken_Clip\",\"variables\":{{\"slug\":\"{s}\"}},\"query\":\"query VideoAccessToken_Clip($slug: ID!) {{ clip(slug: $slug) {{ playbackAccessToken(params: {{platform: \\\"web\\\", playerBackend: \\\"mediaplayer\\\", playerType: \\\"site\\\"}}) {{ signature value }} videoQualities {{ quality sourceURL }} }} }}\"}}",
            .{slug},
        );
        defer gpa.free(q);
        var r = httpz.send(gpa, .{ .url = "https://gql.twitch.tv/gql", .method = "POST", .headers = &headers, .body = q, .timeout = 15 });
        defer r.deinit();
        if (r.status() != 200) return;
        const sig = pg.findJson(r.body(), "signature") orelse return;
        const val = pg.findJson(r.body(), "value") orelse return;
        const val_unesc = try pg.unescape(gpa, val);
        defer gpa.free(val_unesc);
        const enc_val = try urlEncode(gpa, val_unesc);
        defer gpa.free(enc_val);
        var i: usize = 0;
        while (std.mem.indexOfPos(u8, r.body(), i, "\"sourceURL\":\"")) |at| {
            const from = at + "\"sourceURL\":\"".len;
            const close = std.mem.indexOfScalarPos(u8, r.body(), from, '"') orelse break;
            i = close;
            const base = r.body()[from..close];
            const full = try std.fmt.allocPrint(gpa, "{s}?sig={s}&token={s}", .{ base, sig, enc_val });
            const h_ctx = r.body()[if (at > 80) at - 80 else 0 .. at];
            const h: u32 = if (pg.findJson(h_ctx, "quality")) |qv| std.fmt.parseInt(u32, qv, 10) catch 0 else 0;
            var f: media.Format = .{
                .id = try std.fmt.allocPrint(gpa, "{d}", .{out.items.len}),
                .ext = try gpa.dupe(u8, "mp4"),
                .url = full,
                .height = h,
                .kind = .video,
            };
            f.label = try labelFor(gpa, f);
            try out.append(gpa, f);
        }
        return;
    }

    const vod_id = if (std.mem.indexOf(u8, url, "/videos/")) |at| segmentAt(url[at + 8 ..]) else null;
    const login = if (vod_id == null) twitchLogin(url) else null;
    if (vod_id == null and login == null) return;

    const q = if (vod_id) |vid|
        try std.fmt.allocPrint(gpa, "{{\"variables\":{{\"vodID\":\"{s}\"}},\"query\":\"query($vodID: ID!) {{ videoPlaybackAccessToken(id: $vodID, params: {{platform: \\\"web\\\", playerBackend: \\\"mediaplayer\\\", playerType: \\\"site\\\"}}) {{ value signature }} }}\"}}", .{vid})
    else
        try std.fmt.allocPrint(gpa, "{{\"variables\":{{\"login\":\"{s}\"}},\"query\":\"query($login: String!) {{ streamPlaybackAccessToken(channelName: $login, params: {{platform: \\\"web\\\", playerBackend: \\\"mediaplayer\\\", playerType: \\\"site\\\"}}) {{ value signature }} }}\"}}", .{login.?});
    defer gpa.free(q);

    var r = httpz.send(gpa, .{ .url = "https://gql.twitch.tv/gql", .method = "POST", .headers = &headers, .body = q, .timeout = 15 });
    defer r.deinit();
    if (r.status() != 200) return;
    const sig = pg.findJson(r.body(), "signature") orelse return;
    const val = pg.findJson(r.body(), "value") orelse return;
    const val_unesc = try pg.unescape(gpa, val);
    defer gpa.free(val_unesc);
    const enc_val = try urlEncode(gpa, val_unesc);
    defer gpa.free(enc_val);

    const usher = if (vod_id) |vid|
        try std.fmt.allocPrint(gpa, "https://usher.ttvnw.net/vod/{s}.m3u8?allow_source=true&sig={s}&token={s}", .{ vid, sig, enc_val })
    else
        try std.fmt.allocPrint(gpa, "https://usher.ttvnw.net/api/channel/hls/{s}.m3u8?allow_source=true&sig={s}&token={s}", .{ login.?, sig, enc_val });
    try out.append(gpa, .{
        .id = try gpa.dupe(u8, "hls"),
        .label = try gpa.dupe(u8, if (vod_id != null) "Auto" else "Live"),
        .ext = try gpa.dupe(u8, "mp4"),
        .manifest = .{ .hls = usher },
        .kind = .video,
    });
}

/// Kick: live channels via `/api/v2/channels/<slug>` and VODs via `/api/v1/video/<uuid>`.
pub fn kick(gpa: std.mem.Allocator, url: []const u8, out: *std.ArrayList(media.Format)) !void {
    if (std.mem.indexOf(u8, url, "/videos/") orelse std.mem.indexOf(u8, url, "/video/")) |_| {
        const uuid = lastSegment(url) orelse return;
        const api = try std.fmt.allocPrint(gpa, "https://kick.com/api/v1/video/{s}", .{uuid});
        defer gpa.free(api);
        var r = fetch(gpa, api, url);
        defer r.deinit();
        if (r.status() == 200) {
            if (pg.findJson(r.body(), "source")) |raw| {
                const u = try pg.unescape(gpa, raw);
                if (std.mem.startsWith(u8, u, "http")) {
                    try out.append(gpa, .{ .id = try gpa.dupe(u8, "hls"), .label = try gpa.dupe(u8, "Auto"), .ext = try gpa.dupe(u8, "mp4"), .manifest = .{ .hls = u }, .kind = .video });
                    return;
                }
                gpa.free(u);
            }
        }
    }
    const ch = kickChannel(url) orelse return;
    const api = try std.fmt.allocPrint(gpa, "https://kick.com/api/v2/channels/{s}", .{ch});
    defer gpa.free(api);
    var r = fetch(gpa, api, url);
    defer r.deinit();
    if (r.status() != 200) return;
    if (pg.findJson(r.body(), "playback_url")) |raw| {
        const u = try pg.unescape(gpa, raw);
        if (std.mem.startsWith(u8, u, "http")) {
            try out.append(gpa, .{ .id = try gpa.dupe(u8, "hls"), .label = try gpa.dupe(u8, "Live"), .ext = try gpa.dupe(u8, "mp4"), .manifest = .{ .hls = u }, .kind = .video });
            return;
        }
        gpa.free(u);
    }
}

fn segmentAt(s: []const u8) ?[]const u8 {
    const end = std.mem.indexOfAny(u8, s, "/?#") orelse s.len;
    return if (end > 0) s[0..end] else null;
}

fn lastSegment(url: []const u8) ?[]const u8 {
    const no_q = if (std.mem.indexOfAny(u8, url, "?#")) |q| url[0..q] else url;
    const trimmed = std.mem.trimEnd(u8, no_q, "/");
    const slash = std.mem.lastIndexOfScalar(u8, trimmed, '/') orelse return null;
    const seg = trimmed[slash + 1 ..];
    return if (seg.len > 0) seg else null;
}

fn twitchLogin(url: []const u8) ?[]const u8 {
    const at = std.mem.indexOf(u8, url, "twitch.tv/") orelse return null;
    const rest = url[at + "twitch.tv/".len ..];
    const seg = segmentAt(rest) orelse return null;
    if (std.mem.eql(u8, seg, "videos") or std.mem.eql(u8, seg, "directory")) return null;
    return seg;
}

fn kickChannel(url: []const u8) ?[]const u8 {
    const at = std.mem.indexOf(u8, url, "kick.com/") orelse return null;
    return segmentAt(url[at + "kick.com/".len ..]);
}

fn urlEncode(gpa: std.mem.Allocator, s: []const u8) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);
    for (s) |ch| {
        if (std.ascii.isAlphanumeric(ch) or ch == '-' or ch == '_' or ch == '.' or ch == '~') {
            try out.append(gpa, ch);
        } else {
            try out.print(gpa, "%{X:0>2}", .{ch});
        }
    }
    return out.toOwnedSlice(gpa);
}

/// Dailymotion: the page holds no media URL. The video's id is in its path,
/// and the player's metadata endpoint answers with the manifests it would play.
pub fn dailymotion(gpa: std.mem.Allocator, url: []const u8, out: *std.ArrayList(media.Format)) !void {
    const id = dailymotionId(url) orelse return;
    var buf: [256]u8 = undefined;
    const meta_url = std.fmt.bufPrint(&buf, "https://www.dailymotion.com/player/metadata/video/{s}", .{id}) catch return;
    var r = fetch(gpa, meta_url, url);
    defer r.deinit();
    if (r.status() != 200) return;
    const at = std.mem.indexOf(u8, r.body(), "\"qualities\"") orelse return;
    const tail = r.body()[at..];
    var i: usize = 0;
    while (std.mem.indexOfPos(u8, tail, i, "\"url\"")) |u_at| {
        i = u_at + 5;
        const raw = pg.findJson(tail[u_at..], "url") orelse continue;
        const unescaped = try pg.unescape(gpa, raw);
        defer gpa.free(unescaped);
        const u = try sites.undouble(gpa, unescaped);
        defer gpa.free(u);
        if (!std.mem.startsWith(u8, u, "http")) continue;
        if (std.mem.indexOf(u8, u, ".m3u8") == null and std.mem.indexOf(u8, u, ".mp4") == null) continue;
        const clean = if (std.mem.indexOfScalar(u8, u, '#')) |h| u[0..h] else u;
        if (sites.alreadyListed(out, clean)) continue;
        const is_hls = std.mem.indexOf(u8, u, ".m3u8") != null;
        const label = if (is_hls) "Auto" else "Original";
        const id_s = if (is_hls) "hls" else "mp4";
        if (is_hls) {
            try out.append(gpa, .{ .id = try gpa.dupe(u8, id_s), .label = try gpa.dupe(u8, label), .ext = try gpa.dupe(u8, "mp4"), .manifest = .{ .hls = try gpa.dupe(u8, clean) }, .kind = .video });
        } else {
            try out.append(gpa, .{ .id = try gpa.dupe(u8, id_s), .label = try gpa.dupe(u8, label), .ext = try gpa.dupe(u8, "mp4"), .url = try gpa.dupe(u8, clean), .kind = .video });
        }
    }
}

pub fn dailymotionId(url: []const u8) ?[]const u8 {
    if (std.mem.indexOf(u8, url, "/video/")) |at| {
        const rest = url[at + 7 ..];
        var end: usize = 0;
        while (end < rest.len and rest[end] != '/' and rest[end] != '?' and rest[end] != '_') : (end += 1) {}
        if (end > 0) return rest[0..end];
    }
    if (std.mem.indexOf(u8, url, "/embed/video/")) |at| {
        const rest = url[at + 13 ..];
        var end: usize = 0;
        while (end < rest.len and rest[end] != '/' and rest[end] != '?' and rest[end] != '_') : (end += 1) {}
        if (end > 0) return rest[0..end];
    }
    return null;
}

test "a dailymotion link's id is read from its path" {
    try std.testing.expectEqualStrings("xbwk6ta", dailymotionId("https://www.dailymotion.com/video/xbwk6ta").?);
    try std.testing.expectEqualStrings("xbwk6ta", dailymotionId("https://www.dailymotion.com/video/xbwk6ta_title").?);
    try std.testing.expectEqualStrings("xbwk6ta", dailymotionId("https://www.dailymotion.com/embed/video/xbwk6ta").?);
    try std.testing.expect(dailymotionId("https://www.dailymotion.com/") == null);
}

test "mixcloud xor key decodes an hls url" {
    const enc = "ITItPyZtbmE1OyxrLDssKj87JjBhJCo5fzIsJzE9K2A8KDx4YilgJ2t2fXdiKSphJWEtZSV6a216NGNsd203LGglY21+MmVnZn5zIWR8JGYia39hd3sgLG4oYS1xJXV/e3gsfXV6dSwxaS13YHg0ZnV8ZWAsdWxjbXsYeH05eyZrISItOiEwYCchMCE3eSN/Onk=";
    const dec = try decodeMixcloud(std.testing.allocator, enc);
    defer std.testing.allocator.free(dec);
    try std.testing.expect(std.mem.startsWith(u8, dec, "https://aod.mixcloud.com/secure/hls/"));
    try std.testing.expect(std.mem.endsWith(u8, dec, ".m3u8"));
}

test "youtube and x ids are parsed from standard links" {
    try std.testing.expectEqualStrings("dQw4w9WgXcQ", youtubeId("https://www.youtube.com/watch?v=dQw4w9WgXcQ&t=5s").?);
    try std.testing.expectEqualStrings("dQw4w9WgXcQ", youtubeId("https://youtu.be/dQw4w9WgXcQ?si=1").?);
    try std.testing.expectEqualStrings("2120912865658077388", xStatusId("https://x.com/handsher_NGU/status/2120912865658077388").?);
}
