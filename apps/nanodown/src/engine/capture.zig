//! The page's own player, borrowed. Some sites (YouTube above all) no longer
//! put a media URL in the page: the player asks for one after solving a
//! challenge that only its own JavaScript can solve, and the answer is a
//! signed URL that expires. Rather than reimplement that, this runs the page
//! in a webview that is never shown, hooks the requests the player makes, and
//! hands the signed URLs back. The download itself is still Zig's: the URL
//! goes to `engine/http.zig` like any other.
//!
//! This is what a downloader's own browser does, and it is the only honest way to
//! read a site that signs its media: no signature is forged here, the site's
//! own player produces it.
const std = @import("std");
const nanoui = @import("nanoui");
const media = @import("../model/media.zig");

/// The hook, run in the page before its player starts. Every request the
/// player makes for media is reported once, with the quality the URL carries.
pub const hook =
    \\(() => {
    \\  if (window.__ndCapture) return;
    \\  window.__ndCapture = 1;
    \\  const seen = new Set();
    \\  const report = (u) => {
    \\    u = String(u || '');
    \\    if (!u.includes('googlevideo.com')) return;
    \\    if (u.includes('/api/manifest/')) {
    \\      if (seen.has(u)) return;
    \\      seen.add(u);
    \\      try { window.nanoui.call('Capture.manifest', u); } catch (e) {}
    \\      return;
    \\    }
    \\    if (seen.has(u)) return;
    \\    seen.add(u);
    \\    try { window.nanoui.call('Capture.found', u); } catch (e) {}
    \\  };
    \\  const of = window.fetch;
    \\  window.fetch = function (input) {
    \\    try { report(typeof input === 'string' ? input : (input && input.url)); } catch (e) {}
    \\    return of.apply(this, arguments);
    \\  };
    \\  const oo = XMLHttpRequest.prototype.open;
    \\  XMLHttpRequest.prototype.open = function (m, u) {
    \\    try { report(u); } catch (e) {}
    \\    return oo.apply(this, arguments);
    \\  };
    \\  const d = Object.getOwnPropertyDescriptor(HTMLMediaElement.prototype, 'src');
    \\  if (d && d.set) {
    \\    Object.defineProperty(HTMLMediaElement.prototype, 'src', {
    \\      set(v) { try { report(v); } catch (e) {} return d.set.call(this, v); },
    \\      get() { return d.get.call(this); },
    \\    });
    \\  }
    \\})();
;

/// Asks the player to load the qualities it can, so more than the one it
/// starts with is reported. Run after the hook.
pub const nudge =
    \\(() => {
    \\  try {
    \\    const v = document.querySelector('video');
    \\    if (v) { v.muted = true; v.play && v.play().catch(() => {}); }
    \\  } catch (e) {}
    \\})();
;

/// One URL the player asked for.
pub const Found = struct {
    url: []const u8,
    /// The `itag` the URL carries, or 0.
    itag: u32 = 0,
    /// `mime=video%2Fmp4` as the URL spells it, or "".
    mime: []const u8 = "",
};

/// Reads `itag` and `mime` out of a signed URL's query.
pub fn readFound(url: []const u8) Found {
    var f: Found = .{ .url = url };
    if (queryValue(url, "itag")) |v| f.itag = std.fmt.parseInt(u32, v, 10) catch 0;
    if (queryValue(url, "mime")) |v| f.mime = v;
    return f;
}

/// The value of `key` in `url`'s query, still percent-encoded.
pub fn queryValue(url: []const u8, key: []const u8) ?[]const u8 {
    const q = std.mem.indexOfScalar(u8, url, '?') orelse return null;
    var it = std.mem.splitScalar(u8, url[q + 1 ..], '&');
    while (it.next()) |pair| {
        const eq = std.mem.indexOfScalar(u8, pair, '=') orelse continue;
        if (std.mem.eql(u8, pair[0..eq], key)) return pair[eq + 1 ..];
    }
    return null;
}

/// What a captured `itag` is, as far as it can be told from the number alone.
/// The player's own list is the authority; this only names the common ones so
/// a capture with no page metadata still reads sensibly.
pub fn labelOf(itag: u32) ?struct { label: []const u8, kind: media.Format.Kind, ext: []const u8 } {
    return switch (itag) {
        18 => .{ .label = "360p", .kind = .video, .ext = "mp4" },
        22 => .{ .label = "720p", .kind = .video, .ext = "mp4" },
        37 => .{ .label = "1080p", .kind = .video, .ext = "mp4" },
        38 => .{ .label = "2160p", .kind = .video, .ext = "mp4" },
        43 => .{ .label = "360p", .kind = .video, .ext = "webm" },
        44 => .{ .label = "480p", .kind = .video, .ext = "webm" },
        45 => .{ .label = "720p", .kind = .video, .ext = "webm" },
        46 => .{ .label = "1080p", .kind = .video, .ext = "webm" },
        139 => .{ .label = "Audio", .kind = .audio, .ext = "m4a" },
        140 => .{ .label = "Audio", .kind = .audio, .ext = "m4a" },
        141 => .{ .label = "Audio", .kind = .audio, .ext = "m4a" },
        251 => .{ .label = "Audio", .kind = .audio, .ext = "webm" },
        else => null,
    };
}

/// Turns what the player asked for into formats the preview can list. A
/// progressive capture (itag 18, 22) is one file with both streams; an
/// adaptive one is video or audio alone, which the muxer joins.
pub fn formats(gpa: std.mem.Allocator, found: []const Found, out: *std.ArrayList(media.Format)) !void {
    for (found) |f| {
        const known = labelOf(f.itag);
        const audio = if (known) |k| k.kind == .audio else std.mem.indexOf(u8, f.mime, "audio") != null;
        const ext = if (known) |k| k.ext else if (std.mem.indexOf(u8, f.mime, "webm") != null) "webm" else "mp4";
        // A URL without an itag is the ABR endpoint, which serves nothing
        // without the player's own protocol: skip it rather than offer it.
        if (f.itag == 0) continue;
        try out.append(gpa, .{
            .id = try std.fmt.allocPrint(gpa, "{d}", .{f.itag}),
            .label = try gpa.dupe(u8, if (known) |k| k.label else try std.fmt.allocPrint(gpa, "itag {d}", .{f.itag})),
            .ext = try gpa.dupe(u8, ext),
            .url = try gpa.dupe(u8, f.url),
            .codec = try gpa.dupe(u8, ""),
            .kind = if (audio) .audio else .video,
        });
    }
}

// --- the tests ------------------------------------------------------------

const testing = std.testing;

/// Frees what `formats` made.
fn freeFormats(out: *std.ArrayList(media.Format)) void {
    for (out.items) |f| {
        testing.allocator.free(f.id);
        testing.allocator.free(f.label);
        testing.allocator.free(f.ext);
        testing.allocator.free(f.url);
        testing.allocator.free(f.codec);
    }
    out.deinit(testing.allocator);
}

test "a signed url's itag and mime are read" {
    const url = "https://rr2---sn-x.googlevideo.com/videoplayback?expire=1&itag=18&mime=video%2Fmp4&dur=10";
    const f = readFound(url);
    try testing.expectEqual(@as(u32, 18), f.itag);
    try testing.expectEqualStrings("video%2Fmp4", f.mime);
}

test "a url without an itag reads as 0" {
    const f = readFound("https://rr2---sn-x.googlevideo.com/videoplayback?expire=1");
    try testing.expectEqual(@as(u32, 0), f.itag);
}

test "a progressive capture becomes one video format" {
    var out: std.ArrayList(media.Format) = .empty;
    defer freeFormats(&out);
    try formats(testing.allocator, &.{readFound("https://x/videoplayback?itag=18&mime=video%2Fmp4")}, &out);
    try testing.expectEqual(@as(usize, 1), out.items.len);
    try testing.expectEqualStrings("360p", out.items[0].label);
    try testing.expectEqual(media.Format.Kind.video, out.items[0].kind);
}

test "an audio capture is audio" {
    var out: std.ArrayList(media.Format) = .empty;
    defer freeFormats(&out);
    try formats(testing.allocator, &.{readFound("https://x/videoplayback?itag=140&mime=audio%2Fmp4")}, &out);
    try testing.expectEqual(media.Format.Kind.audio, out.items[0].kind);
    try testing.expectEqualStrings("m4a", out.items[0].ext);
}

test "the abr endpoint is not offered" {
    var out: std.ArrayList(media.Format) = .empty;
    defer freeFormats(&out);
    try formats(testing.allocator, &.{readFound("https://x/videoplayback?expire=1")}, &out);
    try testing.expectEqual(@as(usize, 0), out.items.len);
}
