const std = @import("std");
pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const nanoui = b.dependency("nanoui", .{ .target = target, .optimize = optimize }).module("nanoui");
    const exe = b.addExecutable(.{ .name = "proto", .root_module = b.createModule(.{
        .root_source_file = b.path("main.zig"), .target = target, .optimize = optimize,
    }) });
    exe.root_module.addImport("nanoui", nanoui);
    b.installArtifact(exe);
}
