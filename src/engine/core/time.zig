//! Engine time: monotonic clock for measurements (never wall-clock in
//! gameplay, spec §6).
//!
//! For now: libc clock_gettime (Linux). Other targets will implement this
//! in their platform layer; the API (`monotonicNs`) does not change.

const std = @import("std");

const CLOCK_MONOTONIC: c_int = 1; // Linux

const Timespec = extern struct {
    sec: isize,
    nsec: isize,
};

extern "c" fn clock_gettime(clk_id: c_int, tp: *Timespec) c_int;

/// Monotonic nanoseconds since an arbitrary process origin.
pub fn monotonicNs() u64 {
    var ts: Timespec = undefined;
    const rc = clock_gettime(CLOCK_MONOTONIC, &ts);
    if (rc != 0) @panic("clock_gettime failed");
    return @as(u64, @intCast(ts.sec)) *% 1_000_000_000 +% @as(u64, @intCast(ts.nsec));
}

test "monotonic clock advances" {
    const a = monotonicNs();
    var spin: u64 = 0;
    for (0..100_000) |i| spin +%= i; // minimal work
    std.mem.doNotOptimizeAway(spin);
    const b = monotonicNs();
    try std.testing.expect(b >= a);
}
