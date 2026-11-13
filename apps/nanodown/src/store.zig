//! Where the app keeps what it knows: the library, the settings and the
//! licence, as JSON under the user's Application Support, and the small
//! string work a file name needs.
const std = @import("std");
const now = @import("now.zig");

/// The home folder, as the process was told it.
pub var home: []const u8 = ".";

/// The path a state file lives at.
pub fn statePath(gpa: std.mem.Allocator, name: []const u8) ![]const u8 {
    return std.fmt.allocPrint(gpa, "{s}/Library/Application Support/nanodown/{s}", .{ home, name });
}

/// Writes `text` at `path`, making the folder it lives in first.
pub fn saveState(gpa: std.mem.Allocator, path: []const u8, text: []const u8) void {
    _ = gpa;
    if (std.mem.lastIndexOfScalar(u8, path, '/')) |slash| {
        std.Io.Dir.cwd().createDirPath(now.io(), path[0..slash]) catch {};
    }
    std.Io.Dir.cwd().writeFile(now.io(), .{ .sub_path = path, .data = text }) catch {};
}

/// Reads one state file into `target`, by its own `fromJson`. True when the
/// file was there and parsed: a caller that writes the state back has to know
/// the difference between "nothing saved yet" and "what was saved could not
/// be read", or the first save after a bad read wipes the file.
pub fn loadOne(gpa: std.mem.Allocator, name: []const u8, limit: usize, target: anytype) bool {
    const path = statePath(gpa, name) catch return true;
    defer gpa.free(path);
    // No file yet is a first run, and the state this one builds is the whole
    // of it: writing it back is right. A file that is there and will not
    // parse is the case worth guarding.
    const text = std.Io.Dir.cwd().readFileAlloc(now.io(), path, gpa, .limited(limit)) catch return true;
    defer gpa.free(text);
    target.fromJson(text) catch {
        // Unreadable, and about to be replaced by whatever this run knows:
        // keep the bytes aside so the downloads in it are not gone for good.
        keepAside(gpa, path, text);
        return false;
    };
    return true;
}

/// Copies a state file that would not parse next to itself, so a later save
/// does not destroy what it held.
fn keepAside(gpa: std.mem.Allocator, path: []const u8, text: []const u8) void {
    const aside = std.fmt.allocPrint(gpa, "{s}.unreadable", .{path}) catch return;
    defer gpa.free(aside);
    std.Io.Dir.cwd().writeFile(now.io(), .{ .sub_path = aside, .data = text }) catch {};
}

/// Writes one state file from `text`, which it frees.
pub fn saveOne(gpa: std.mem.Allocator, name: []const u8, text: []const u8) void {
    defer gpa.free(text);
    const path = statePath(gpa, name) catch return;
    defer gpa.free(path);
    saveState(gpa, path, text);
}

/// The folder downloads go to when nothing else was chosen.
pub fn defaultFolder(gpa: std.mem.Allocator) ![]const u8 {
    return std.fmt.allocPrint(gpa, "{s}/Downloads", .{home});
}

/// A file name a filesystem will take.
pub fn sanitize(gpa: std.mem.Allocator, title: []const u8) ![]const u8 {
    var out: std.Io.Writer.Allocating = .init(gpa);
    defer out.deinit();
    const w = &out.writer;
    for (title) |ch| {
        const bad = ch == '/' or ch == '\\' or ch == ':' or ch == '*' or ch == '?' or ch == '"' or ch == '<' or ch == '>' or ch == '|' or ch < 0x20;
        try w.writeByte(if (bad) '-' else ch);
    }
    const s = std.mem.trim(u8, out.writer.buffered(), " .");
    if (s.len == 0) return gpa.dupe(u8, "download");
    if (s.len > 120) return gpa.dupe(u8, s[0..120]);
    return gpa.dupe(u8, s);
}

/// A setting's choice in lower case, for a file's extension: "MP4" is
/// `mp4` on disk.
pub fn lower(gpa: std.mem.Allocator, s: []const u8) ![]const u8 {
    const out = try gpa.dupe(u8, s);
    for (out) |*ch| ch.* = std.ascii.toLower(ch.*);
    return out;
}

/// A link, rather than something to search for.
pub fn looksLikeLink(text: []const u8) bool {
    if (std.mem.startsWith(u8, text, "http://") or std.mem.startsWith(u8, text, "https://")) return true;
    return std.mem.indexOf(u8, text, ".") != null and std.mem.indexOfScalar(u8, text, ' ') == null;
}

test "a title becomes a file name" {
    const gpa = std.testing.allocator;
    const a = try sanitize(gpa, "Big Buck Bunny: Part 1/2");
    defer gpa.free(a);
    try std.testing.expectEqualStrings("Big Buck Bunny- Part 1-2", a);
    const b = try sanitize(gpa, "   ");
    defer gpa.free(b);
    try std.testing.expectEqualStrings("download", b);
}

test "a link is told from a search" {
    try std.testing.expect(looksLikeLink("https://youtube.com/watch?v=1"));
    try std.testing.expect(looksLikeLink("youtube.com/watch"));
    try std.testing.expect(!looksLikeLink("big buck bunny"));
}

test "a library that will not parse is kept, not overwritten" {
    // A truncated save has to come back as an error. Swallowed, it read as
    // "nothing saved yet" and the next save wrote an empty library over it,
    // which is how a bad write turned into lost downloads.
    const gpa = std.testing.allocator;
    var lib = @import("model/library.zig").Library.init(gpa);
    defer lib.deinit();
    try std.testing.expectError(error.UnexpectedEndOfInput, lib.fromJson("{\"next_id\":9,\"items\":[{\"id\":1,"));
    // A whole one still parses, so the guard is not simply always an error.
    try lib.fromJson("{\"next_id\":9,\"items\":[]}");
    try std.testing.expectEqual(@as(u64, 9), lib.next_id);
}
