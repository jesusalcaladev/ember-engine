//! Engine time: monotonic clock for measurements (never wall-clock in
//! gameplay, spec §6).
//!
//! Two interchangeable implementations behind ONE api (`monotonicNs`):
//!
//! - `clock_gettime(CLOCK_MONOTONIC)` — libc/vDSO, always available.
//!   ~50-60 ns per read on the dev box (1 GHz), ~20-25 ns on a 2022 laptop.
//! - `rdtscp` + invariant TSC (x86_64) — ~28 ns per read. The TSC rate does
//!   NOT follow P-states, so it is calibrated ONCE at boot against the
//!   monotonic clock and converted with a fixed-point factor (a single
//!   64x32 multiply + shift). Residual drift measured on the dev box: ~24 ppm,
//!   i.e. 0.4 us per frame at 60 fps.
//!
//! Both clocks are for MEASURING only (profiler zones, frame pacing).
//! Gameplay must never read a clock: it consumes the fixed loop's dt (§6).

const std = @import("std");
const builtin = @import("builtin");

const Timespec = extern struct {
    sec: isize,
    nsec: isize,
};

extern "c" fn clock_gettime(clk_id: c_int, tp: *Timespec) c_int;
extern "c" fn clock_nanosleep(clk_id: c_int, flags: c_int, request: *const Timespec, remain: ?*Timespec) c_int;

pub const CLOCK_MONOTONIC: c_int = 1; // Linux

/// Sleeps for `ns`, retrying on EINTR. Only for boot, tests and idle waits —
/// NEVER inside the frame loop (spec §3.4).
pub fn sleepNs(ns: u64) void {
    var req = Timespec{
        .sec = @intCast(ns / std.time.ns_per_s),
        .nsec = @intCast(ns % std.time.ns_per_s),
    };
    while (true) {
        const rc = clock_nanosleep(CLOCK_MONOTONIC, 0, &req, null);
        if (rc == 0) return;
        if (rc != 4) return; // EINTR = 4: anything else, give up
    }
}

pub const Kind = enum { monotonic, rdtscp };

/// Fixed-point precision of the TSC->ns conversion (32 fractional bits).
pub const FP_SHIFT: u6 = 32;

pub var kind: Kind = .monotonic;

/// TSC ticks per nanosecond, fixed point: (1 << FP_SHIFT) * 1e9 / tsc_hz.
pub var tsc_scale: u64 = 0;
pub var tsc_hz: u64 = 0;
pub var tsc_zero: u64 = 0;
pub var ns_zero: u64 = 0;

/// Error of the TSC clock against the monotonic clock, in ppm (from the last
/// calibration). Informational: it goes into the report's environment block.
pub var last_calibration_ppm: i64 = 0;

/// The engine's monotonic clock, in nanoseconds. Public so benchmarks can time
/// themselves with the SAME clock every other measurement in the repo uses —
/// mixing clocks would make two reported numbers incomparable.
pub fn clockGetTimeNs() u64 {
    var ts: Timespec = undefined;
    const rc = clock_gettime(CLOCK_MONOTONIC, &ts);
    if (rc != 0) @panic("clock_gettime failed");
    return @as(u64, @intCast(ts.sec)) *% 1_000_000_000 +% @as(u64, @intCast(ts.nsec));
}

/// Scale factor (fixed point) for a given TSC frequency. Pure: tested
/// without needing a TSC.
pub fn fixedScale(hz: u64) u64 {
    return @intCast((@as(u128, 1) << FP_SHIFT) * 1_000_000_000 / hz);
}

/// TSC ticks -> nanoseconds using the active scale. Pure enough to test.
pub inline fn tscToNs(ticks: u64) u64 {
    if (ticks < tsc_zero) return ns_zero;
    return ns_zero + @as(u64, @intCast((@as(u128, ticks - tsc_zero) * tsc_scale) >> FP_SHIFT));
}

/// Clock read for the START of a measurement: `lfence; rdtsc` drains the
/// pipeline so the timestamp is not taken early.
inline fn readStart() u64 {
    if (builtin.cpu.arch != .x86_64) return 0;
    var lo: u32 = undefined;
    var hi: u32 = undefined;
    asm volatile ("lfence\n\trdtsc"
        : [lo] "={eax}" (lo),
          [hi] "={edx}" (hi),
        :
        : .{});
    return (@as(u64, hi) << 32) | lo;
}

/// Clock read for the END of a measurement: `rdtscp` waits for all previous
/// instructions to retire (the cheapest serializing read).
inline fn readEnd() u64 {
    if (builtin.cpu.arch != .x86_64) return 0;
    var lo: u32 = undefined;
    var hi: u32 = undefined;
    var aux: u32 = undefined; // IA32_TSC_AUX: unused, but rdtscp always writes it
    asm volatile ("rdtscp"
        : [lo] "={eax}" (lo),
          [hi] "={edx}" (hi),
          [aux] "={ecx}" (aux),
    );
    return (@as(u64, hi) << 32) | lo;
}

inline fn cpuidLeaf(leaf: u32) struct { eax: u32, ebx: u32, ecx: u32, edx: u32 } {
    if (builtin.cpu.arch != .x86_64) return .{ .eax = 0, .ebx = 0, .ecx = 0, .edx = 0 };
    var eax: u32 = undefined;
    var ebx: u32 = undefined;
    var ecx: u32 = undefined;
    var edx: u32 = undefined;
    asm volatile ("cpuid"
        : [eax] "={eax}" (eax),
          [ebx] "={ebx}" (ebx),
          [ecx] "={ecx}" (ecx),
          [edx] "={edx}" (edx),
        : [leaf] "{eax}" (leaf),
    );
    return .{ .eax = eax, .ebx = ebx, .ecx = ecx, .edx = edx };
}

/// true if the CPU reports an invariant TSC (leaf 0x80000007, EDX bit 8) AND
/// the REMDSCP instruction (leaf 0x80000001, EDX bit 27).
fn tscUsable() bool {
    if (builtin.cpu.arch != .x86_64) return false;
    const max_ext = cpuidLeaf(0x80000000).eax;
    if (max_ext < 0x80000007) return false;
    const power = cpuidLeaf(0x80000007);
    const has_invariant = (power.edx & (1 << 8)) != 0;
    const ext = cpuidLeaf(0x80000001);
    const has_rdtscp = (ext.edx & (1 << 27)) != 0;
    return has_invariant and has_rdtscp;
}

pub const Calibration = struct {
    tsc_hz: u64 = 0,
    error_ppm: i64 = 0,
    ok: bool = false,
};

/// Measures the TSC frequency against the monotonic clock over `window_ns`.
/// Pure measurement: no state is modified.
pub fn calibrate(window_ns: u64) Calibration {
    var out: Calibration = .{};
    if (builtin.cpu.arch != .x86_64) return out;
    const ns0 = clockGetTimeNs();
    const t0 = readStart();
    var guard: usize = 0;
    while (clockGetTimeNs() - ns0 < window_ns) {
        guard +%= 1;
        std.mem.doNotOptimizeAway(guard); // do not let the loop be removed
    }
    const t1 = readEnd();
    const ns1 = clockGetTimeNs();

    const tsc_delta = t1 - t0;
    const ns_delta = ns1 - ns0;
    if (tsc_delta < 1000 or ns_delta < 1000) return out;

    out.tsc_hz = tsc_delta * 1_000_000_000 / ns_delta;
    out.ok = out.tsc_hz > 1_000_000 and out.tsc_hz < 100_000_000_000;

    // Sanity check of the fixed-point conversion: compare a known-length
    // window seen through the TSC with the monotonic clock.
    if (!out.ok) return out;
    const scale = fixedScale(out.tsc_hz);
    const a_t = readStart();
    const a_ns = clockGetTimeNs();
    var spin: usize = 0;
    while (clockGetTimeNs() - a_ns < 1_000_000) spin +%= 1; // ~1 ms
    const b_ns = clockGetTimeNs();
    const b_t = readEnd();
    std.mem.doNotOptimizeAway(spin);
    const tsc_ns: u64 = @intCast((@as(u128, b_t - a_t) * scale) >> FP_SHIFT);
    const real_ns = b_ns - a_ns;
    if (real_ns == 0) return out;
    const drift_ppm: i128 = @divTrunc(@as(i128, @intCast(tsc_ns)) * 1_000_000, @as(i128, @intCast(real_ns)));
    out.error_ppm = @intCast(drift_ppm - 1_000_000);
    return out;
}

/// Selects and activates the measurement clock. `prefer_tsc = false` (or a
/// machine without an invariant TSC) silently falls back to monotonic.
pub fn init(prefer_tsc: bool) Calibration {
    kind = .monotonic;
    tsc_hz = 0;
    tsc_scale = 0;
    if (!prefer_tsc or !tscUsable()) return .{ .ok = false };

    const cal = calibrate(20_000_000); // 20 ms, once at boot
    if (!cal.ok) return .{ .ok = false };
    tsc_hz = cal.tsc_hz;
    tsc_scale = fixedScale(cal.tsc_hz);
    tsc_zero = readStart();
    ns_zero = clockGetTimeNs();
    kind = .rdtscp;
    return cal;
}

/// Monotonic nanoseconds since an arbitrary process origin. This is THE read
/// used by the profiler: one branch + one clock access.
pub inline fn monotonicNs() u64 {
    return switch (kind) {
        .monotonic => clockGetTimeNs(),
        .rdtscp => tscToNs(readEnd()),
    };
}

/// Timestamp for a zone's START (pipeline-draining read).
pub inline fn startNs() u64 {
    return switch (kind) {
        .monotonic => clockGetTimeNs(),
        .rdtscp => tscToNs(readStart()),
    };
}

test "monotonic clock advances" {
    const a = monotonicNs();
    var spin: u64 = 0;
    for (0..100_000) |i| spin +%= i;
    std.mem.doNotOptimizeAway(spin);
    const b = monotonicNs();
    try std.testing.expect(b >= a);
}

test "fixed-point conversion: 1 GHz -> 1 ns per tick" {
    // Restore/preserve the global so the test is order-independent.
    const saved_scale = tsc_scale;
    const saved_zero = tsc_zero;
    const saved_ns = ns_zero;
    defer {
        tsc_scale = saved_scale;
        tsc_zero = saved_zero;
        ns_zero = saved_ns;
    }

    tsc_scale = fixedScale(1_000_000_000);
    tsc_zero = 0;
    ns_zero = 0;
    try std.testing.expectEqual(@as(u64, 1), tscToNs(1));
    try std.testing.expectEqual(@as(u64, 1_000_000), tscToNs(1_000_000));
    try std.testing.expectEqual(@as(u64, 1000), tscToNs(1000));

    // A non-round frequency keeps sub-ns precision inside 0.5%.
    tsc_scale = fixedScale(1_896_000_000);
    tsc_zero = 0;
    ns_zero = 0;
    try std.testing.expectApproxEqAbs(@as(f64, 1_000_000), @as(f64, @floatFromInt(tscToNs(1_896_000))), 1.0);
}

test "calibration is consistent and monotonic once activated" {
    const saved_kind = kind;
    const cal = init(true); // activate whatever this machine supports
    defer kind = saved_kind;

    try std.testing.expect(kind == .monotonic or kind == .rdtscp);
    if (!cal.ok) return; // no invariant TSC: nothing else to assert

    const t0 = monotonicNs();
    var spin: u64 = 0;
    var n: u64 = 0;
    const t_target = t0 + 10_000_000; // 10 ms of busy work
    while (monotonicNs() < t_target) : (n += 1) spin +%= n;
    const t1 = monotonicNs();
    std.mem.doNotOptimizeAway(spin);
    try std.testing.expect(t1 > t0);
    try std.testing.expect((t1 - t0) >= 9_000_000); // 1 ms tolerance
}
