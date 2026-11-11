const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const nanoui = b.dependency("nanoui", .{ .target = target, .optimize = optimize }).module("nanoui");

    const mod = module(b, nanoui, "src/main.zig", target, optimize);
    const exe = b.addExecutable(.{ .name = "noop", .root_module = mod });
    b.installArtifact(exe);
    const run = b.addRunArtifact(exe);
    run.addPassthruArgs();
    b.step("run", "Run noop's notch").dependOn(&run.step);

    const tests = module(b, nanoui, "src/tests.zig", target, optimize);
    const test_step = b.addTest(.{ .root_module = tests });
    b.step("test", "Run noop's tests").dependOn(&b.addRunArtifact(test_step).step);
    // The tests as a program, for another machine (Linux in a container).
    b.step("test-bin", "Install the tests as zig-out/bin/noop-tests").dependOn(
        &b.addInstallArtifact(test_step, .{ .dest_sub_path = "noop-tests" }).step,
    );
}

fn module(
    b: *std.Build,
    nanoui: *std.Build.Module,
    root: []const u8,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
) *std.Build.Module {
    return b.createModule(.{
        .root_source_file = b.path(root),
        .target = target,
        .optimize = optimize,
        .imports = &.{.{ .name = "nanoui", .module = nanoui }},
    });
}
