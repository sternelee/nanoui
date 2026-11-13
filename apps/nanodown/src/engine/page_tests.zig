//! The page reader's own tests.
const std = @import("std");
const page = @import("page.zig");
const media = @import("../model/media.zig");

test "a page's metadata is read" {
    const body =
        \\<html><head>
        \\<meta property="og:title" content="Big Buck Bunny">
        \\<meta property="og:image" content="https://x.com/t.jpg">
        \\<meta property="og:video" content="/v/bbb.mp4">
        \\<title>ignored</title></head>
        \\<body><video src="clip.mp4"></video></body></html>
    ;
    try std.testing.expectEqualStrings("Big Buck Bunny", page.meta(body, "og:title").?);
    try std.testing.expectEqualStrings("https://x.com/t.jpg", page.meta(body, "og:image").?);
    try std.testing.expectEqualStrings("/v/bbb.mp4", page.meta(body, "og:video").?);
}

test "a JSON value is found by its key" {
    const json =
        \\{"a":1,"title":"Hi \"there\"","height":1080,"url":"https://x/v.mp4"}
    ;
    try std.testing.expectEqualStrings("Hi \\\"there\\\"", page.findJson(json, "title").?);
    try std.testing.expectEqualStrings("1080", page.findJson(json, "height").?);
    try std.testing.expectEqualStrings("https://x/v.mp4", page.findJson(json, "url").?);
    try std.testing.expect(page.findJson(json, "nope") == null);
}

test "a reference resolves against its page" {
    const gpa = std.testing.allocator;
    const a = try page.absolute(gpa, "https://x.com/a/b.html", "/v/1.mp4");
    defer gpa.free(a);
    try std.testing.expectEqualStrings("https://x.com/v/1.mp4", a);
    const b = try page.absolute(gpa, "https://x.com/a/b.html", "1.mp4");
    defer gpa.free(b);
    try std.testing.expectEqualStrings("https://x.com/a/1.mp4", b);
    const c = try page.absolute(gpa, "https://x.com/a/b.html", "https://y.com/z.mp4");
    defer gpa.free(c);
    try std.testing.expectEqualStrings("https://y.com/z.mp4", c);
}

test "a manifest URL is found in a page" {
    const body = "var src = \"https://cdn.x.com/hls/index.m3u8\";";
    try std.testing.expectEqualStrings("https://cdn.x.com/hls/index.m3u8", page.findAnyUrl(body, ".m3u8").?);
}
