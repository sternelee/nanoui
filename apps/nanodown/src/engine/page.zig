//! Reading a page's own text: the metadata it declares, the JSON it
//! carries, and the references it makes resolved against its URL.
const std = @import("std");
const media = @import("../model/media.zig");

// --- reading a page's text ------------------------------------------------

/// A `<meta property="..." content="...">` value, or one by `name=`.
pub fn meta(body: []const u8, key: []const u8) ?[]const u8 {
    var at: usize = 0;
    while (std.mem.indexOfPos(u8, body, at, "<meta")) |m| {
        const close = std.mem.indexOfScalarPos(u8, body, m, '>') orelse return null;
        const tag = body[m..close];
        at = close;
        const name = attrIn(tag, "property") orelse attrIn(tag, "name") orelse continue;
        if (!std.mem.eql(u8, name, key)) continue;
        return attrIn(tag, "content");
    }
    return null;
}

pub fn titleTag(body: []const u8) ?[]const u8 {
    const open = std.mem.indexOf(u8, body, "<title") orelse return null;
    const from = std.mem.indexOfScalarPos(u8, body, open, '>') orelse return null;
    const close = std.mem.indexOf(u8, body, "</title>") orelse return null;
    if (close <= from) return null;
    const t = std.mem.trim(u8, body[from + 1 .. close], " \t\r\n");
    return if (t.len > 0) t else null;
}

pub fn attrIn(tag: []const u8, name: []const u8) ?[]const u8 {
    var buf: [64]u8 = undefined;
    var needle = std.fmt.bufPrint(&buf, "{s}=\"", .{name}) catch return null;
    var at = std.mem.indexOf(u8, tag, needle);
    if (at == null) {
        needle = std.fmt.bufPrint(&buf, "{s}='", .{name}) catch return null;
        at = std.mem.indexOf(u8, tag, needle);
    }
    const from = (at orelse return null) + needle.len;
    const quote: u8 = if (needle[needle.len - 1] == '"') '"' else '\'';
    const close = std.mem.indexOfScalarPos(u8, tag, from, quote) orelse return null;
    return tag[from..close];
}

/// The value of `"key":"..."` or `"key":123` in a JSON blob.
pub fn findJson(body: []const u8, key: []const u8) ?[]const u8 {
    var buf: [64]u8 = undefined;
    const needle = std.fmt.bufPrint(&buf, "\"{s}\":", .{key}) catch return null;
    var at: usize = 0;
    while (std.mem.indexOfPos(u8, body, at, needle)) |i| {
        var j = i + needle.len;
        while (j < body.len and (body[j] == ' ' or body[j] == '\t')) j += 1;
        if (j >= body.len) return null;
        if (body[j] == '"') {
            const from = j + 1;
            var k = from;
            while (k < body.len) : (k += 1) {
                if (body[k] == '\\') {
                    k += 1;
                    continue;
                }
                if (body[k] == '"') break;
            }
            if (k >= body.len) return null;
            return body[from..k];
        }
        // A number or a bare word.
        var k = j;
        while (k < body.len and (std.ascii.isDigit(body[k]) or body[k] == '-' or body[k] == '.' or body[k] == 'e')) k += 1;
        if (k > j) return body[j..k];
        at = i + needle.len;
    }
    return null;
}

/// The `{...}` starting at `at`, braces balanced.
pub fn sliceObject(body: []const u8, at: usize) ?[]const u8 {
    var depth: usize = 0;
    var i = at;
    var in_string = false;
    while (i < body.len) : (i += 1) {
        const ch = body[i];
        if (in_string) {
            if (ch == '\\') {
                i += 1;
                continue;
            }
            if (ch == '"') in_string = false;
            continue;
        }
        switch (ch) {
            '"' => in_string = true,
            '{' => depth += 1,
            '}' => {
                depth -= 1;
                if (depth == 0) return body[at .. i + 1];
            },
            else => {},
        }
    }
    return null;
}

/// The first URL in the page that ends with `suffix`.
pub fn findAnyUrl(body: []const u8, suffix: []const u8) ?[]const u8 {
    var at: usize = 0;
    while (std.mem.indexOfPos(u8, body, at, suffix)) |i| {
        // Walk back to the start of the URL.
        var start = i;
        while (start > 0) : (start -= 1) {
            const ch = body[start - 1];
            if (ch == '"' or ch == '\'' or ch == ' ' or ch == '(' or ch == '=' or ch == '\n' or ch == '\t') break;
        }
        const url = body[start..i + suffix.len];
        if (std.mem.startsWith(u8, url, "http") or std.mem.startsWith(u8, url, "/")) return url;
        at = i + suffix.len;
    }
    return null;
}

/// Resolves a reference against a page's URL.
pub fn absolute(gpa: std.mem.Allocator, base: []const u8, ref: []const u8) ![]const u8 {
    if (ref.len == 0) return gpa.dupe(u8, "");
    if (std.mem.startsWith(u8, ref, "http://") or std.mem.startsWith(u8, ref, "https://")) return gpa.dupe(u8, ref);
    if (std.mem.startsWith(u8, ref, "//")) return std.fmt.allocPrint(gpa, "https:{s}", .{ref});
    const scheme_end = std.mem.indexOf(u8, base, "://") orelse return gpa.dupe(u8, ref);
    const path_start = std.mem.indexOfScalarPos(u8, base, scheme_end + 3, '/') orelse base.len;
    if (ref[0] == '/') return std.fmt.allocPrint(gpa, "{s}{s}", .{ base[0..path_start], ref });
    const slash = std.mem.lastIndexOfScalar(u8, base, '/') orelse return gpa.dupe(u8, ref);
    return std.fmt.allocPrint(gpa, "{s}/{s}", .{ base[0..slash], ref });
}

pub fn hostOf(url: []const u8) []const u8 {
    const start = (std.mem.indexOf(u8, url, "://") orelse return url) + 3;
    const rest = url[start..];
    const end = std.mem.indexOfAny(u8, rest, "/?#") orelse rest.len;
    return rest[0..end];
}

pub fn looksLikeFile(url: []const u8) bool {
    const no_query = if (std.mem.indexOfScalar(u8, url, '?')) |q| url[0..q] else url;
    const dot = std.mem.lastIndexOfScalar(u8, no_query, '.') orelse return false;
    const ext = no_query[dot + 1 ..];
    for ([_][]const u8{ "mp4", "m4a", "mp3", "webm", "mov", "mkv", "flac", "wav", "opus", "ogg", "m4v", "avi" }) |e| {
        if (std.ascii.eqlIgnoreCase(ext, e)) return true;
    }
    return false;
}

pub fn extOf(url: []const u8) []const u8 {
    const no_query = if (std.mem.indexOfScalar(u8, url, '?')) |q| url[0..q] else url;
    const dot = std.mem.lastIndexOfScalar(u8, no_query, '.') orelse return "mp4";
    const ext = no_query[dot + 1 ..];
    if (ext.len > 5) return "mp4";
    return ext;
}

pub fn kindOf(url: []const u8) media.Format.Kind {
    const ext = extOf(url);
    for ([_][]const u8{ "mp3", "m4a", "flac", "wav", "opus", "ogg" }) |e| {
        if (std.ascii.eqlIgnoreCase(ext, e)) return .audio;
    }
    return .video;
}

/// A JSON string's escapes undone: `\u0026` and `\/` in a URL a page wrote
/// as JSON, so it can be requested as it stands.
pub fn unescape(gpa: std.mem.Allocator, s: []const u8) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);
    var i: usize = 0;
    while (i < s.len) {
        const ch = s[i];
        if (ch != '\\' or i + 1 >= s.len) {
            try out.append(gpa, ch);
            i += 1;
            continue;
        }
        const next = s[i + 1];
        if (next == 'u' and i + 5 < s.len) {
            const hex = s[i + 2 .. i + 6];
            const code = std.fmt.parseInt(u21, hex, 16) catch {
                try out.append(gpa, ch);
                i += 1;
                continue;
            };
            var buf: [4]u8 = undefined;
            const n = std.unicode.utf8Encode(code, &buf) catch {
                try out.append(gpa, ch);
                i += 1;
                continue;
            };
            try out.appendSlice(gpa, buf[0..n]);
            i += 6;
            continue;
        }
        try out.append(gpa, switch (next) {
            'n' => '\n',
            't' => '\t',
            'r' => '\r',
            'b' => 8,
            'f' => 12,
            else => next,
        });
        i += 2;
    }
    return out.toOwnedSlice(gpa);
}
