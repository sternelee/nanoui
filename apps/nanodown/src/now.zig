//! The clock, in the two units the app asks for: Unix seconds for a licence
//! and a finished download, milliseconds for a speed and a toast.
const std = @import("std");

pub fn io() std.Io {
    return std.Io.Threaded.global_single_threaded.io();
}

/// Unix seconds.
pub fn secs() i64 {
    return @intCast(@divTrunc(std.Io.Clock.real.now(io()).nanoseconds, std.time.ns_per_s));
}

/// Milliseconds on the monotonic clock: only differences mean anything.
pub fn ms() i64 {
    return @intCast(@divTrunc(std.Io.Clock.awake.now(io()).nanoseconds, std.time.ns_per_ms));
}

/// Sleeps, for a worker holding a pace.
pub fn sleepMs(n: u64) void {
    std.Io.sleep(io(), std.Io.Duration.fromMilliseconds(@intCast(n)), .awake) catch {};
}

test "the clock reads forward" {
    const a = ms();
    const b = secs();
    try std.testing.expect(a > 0);
    try std.testing.expect(b > 1_600_000_000);
}
