//! Fixed-timestep loop with accumulator (spec §3.3 and §6).
//!
//! - Simulation runs at a fixed 60 Hz, rendering is decoupled.
//! - Max 1 catch-up step per frame (no death spirals); leftover time is
//!   dropped and compensated with interpolation (`alpha()`).
//! - Pure and deterministic logic: testable without a window or a clock.

const std = @import("std");

pub const FixedLoop = struct {
    /// Fixed step in seconds (1/60 in the runtime).
    fixed_dt: f32,
    accumulator: f32 = 0,
    /// Max fixed steps per frame (spec: 1).
    max_catchup: u32 = 1,
    /// Time scale (pause = 0, slow-motion < 1).
    scale: f32 = 1,
    /// Steps the anti-death-spiral rule has dropped since boot (§3.3). The
    /// report uses it to detect that the machine cannot keep up.
    dropped_total: u64 = 0,
    dropped_this_frame: u64 = 0,

    pub fn init(fixed_dt: f32) FixedLoop {
        return .{ .fixed_dt = fixed_dt };
    }

    /// Adds real time and returns how many fixed steps must run.
    /// `real_dt` is clamped to avoid jumps after tab switches or hitches.
    pub fn addTime(self: *FixedLoop, real_dt: f32) u32 {
        const clamped = @min(real_dt, 0.1);
        self.accumulator += clamped * self.scale;
        if (self.accumulator < 0) self.accumulator = 0;

        self.dropped_this_frame = 0;
        var steps: u32 = 0;
        while (steps < self.max_catchup and self.accumulator >= self.fixed_dt) : (steps += 1) {
            self.accumulator -= self.fixed_dt;
        }
        // Leftover after exhausting catch-up: dropped (anti death-spiral).
        if (steps == self.max_catchup and self.accumulator >= self.fixed_dt) {
            const dropped: u64 = @intFromFloat(@floor(self.accumulator / self.fixed_dt));
            self.dropped_this_frame += dropped;
            self.dropped_total += dropped;
            self.accumulator = 0;
        }
        return steps;
    }

    /// Simulation->render interpolation alpha in [0, 1).
    pub fn alpha(self: *const FixedLoop) f32 {
        return @max(0, @min(1, self.accumulator / self.fixed_dt));
    }
};

test "steady 60 fps cadence: 1 step per frame" {
    var l = FixedLoop.init(1.0 / 60.0);
    try std.testing.expectEqual(@as(u32, 1), l.addTime(1.0 / 60.0 + 0.001)); // full frame
    try std.testing.expectEqual(@as(u32, 0), l.addTime(1.0 / 60.0 - 0.001)); // has not crossed yet
    try std.testing.expectEqual(@as(u32, 1), l.addTime(0.002)); // now it has
    try std.testing.expect(l.alpha() >= 0 and l.alpha() < 1);
}

test "catch-up limited to max_catchup and drops the leftover" {
    var l = FixedLoop.init(1.0 / 60.0);
    // 5 seconds stalled: even with 300 pending steps, only max_catchup run.
    try std.testing.expectEqual(@as(u32, 1), l.addTime(5.0));
    // The accumulator was dropped: the next frame is back to normal.
    try std.testing.expect(l.accumulator < l.fixed_dt);
}

test "dropped steps are counted, not silent" {
    var l = FixedLoop.init(1.0 / 60.0);
    // real_dt is clamped to 0.1 s (anti-hitch), so 5 s of stall costs
    // floor((0.1 - 1/60) / (1/60)) = 4 steps of catch-up headroom, reported
    // instead of being silently forgotten like in M0.
    _ = l.addTime(5.0);
    try std.testing.expect(l.dropped_total >= 4);
    try std.testing.expect(l.dropped_this_frame >= 4);

    // And a frame that fits drops nothing.
    const before = l.dropped_total;
    _ = l.addTime(1.0 / 60.0);
    try std.testing.expect(l.dropped_this_frame == 0);
    try std.testing.expectEqual(before, l.dropped_total);
}

test "time scale and pause" {
    var l = FixedLoop.init(1.0 / 60.0);
    l.scale = 0;
    try std.testing.expectEqual(@as(u32, 0), l.addTime(10.0));
    l.scale = 0.5;
    try std.testing.expectEqual(@as(u32, 1), l.addTime(1.0 / 30.0));
}

// ── Frame limiter (Godot-style `Engine.max_fps`) ────────────────────────────

/// Caps the frame RATE, not the frame work.
///
/// Why the engine needs it even with vsync on (user requirement, Pin-Pon):
/// a Pin-Pon build targets **30 FPS** to halve the GPU cost of the light + GI
/// pass (M7) on the reference iGPU while keeping the fixed 60 Hz simulation
/// (spec §6). Vsync alone cannot do that: it only offers the display refresh.
/// So the game target owns the cap and the editor can set it per project, the
/// same way Godot's `application/run/max_fps` does.
///
/// Ordering (matters, this is the subtle part):
/// 1. `max_fps == 0` → unlimited (the profiler's default: an uncapped run is
///    the only way to measure the real cost of a frame).
/// 2. `use_vsync` → the presentation surface already paces us; sleeping here
///    would only add jitter. The limiter still runs when `use_vsync` is false
///    (headless CI, benchmarking, or a borderless window).
/// 3. Sleep for the remaining time, but spin the last 250 µs: `sleep()` has
///    ~1 ms granularity on Linux, which at 60 FPS is a 6 % pacing error, and
///    the resulting stutter shows up as p99 jitter in the report.
pub const FrameLimiter = struct {
    /// Sub-millisecond tail is spun instead of slept (see note above).
    const spin_tail_ns: u64 = 250_000;

    max_fps: u32 = 0,
    use_vsync: bool = true,
    /// Timestamp of the previous frame's start. 0 is a legal value, so the
    /// "first frame" case needs its own flag instead of a sentinel.
    last_frame_ns: u64 = 0,
    started: bool = false,
    /// Frames where we actually slept (diagnostics for the report).
    slept_frames: u64 = 0,
    /// Total ns spent inside `wait` (frame pacing cost).
    total_wait_ns: u64 = 0,

    pub fn init(max_fps: u32, use_vsync: bool) FrameLimiter {
        return .{ .max_fps = max_fps, .use_vsync = use_vsync };
    }

    pub const Decision = struct {
        /// ns to sleep before the next frame may start.
        wait_ns: u64,
        /// true when the limiter is idle (uncapped or vsync-paced).
        unlimited: bool,
    };

    /// Call at the top of the frame. `now_ns` must come from `time.monotonicNs`
    /// so the limiter shares the clock the profiler uses.
    pub fn wait(self: *FrameLimiter, now_ns: u64) Decision {
        if (self.max_fps == 0 or self.use_vsync) {
            self.last_frame_ns = now_ns;
            self.started = true;
            return .{ .wait_ns = 0, .unlimited = true };
        }
        if (!self.started) {
            self.last_frame_ns = now_ns;
            self.started = true;
            return .{ .wait_ns = 0, .unlimited = false };
        }
        const period = @divTrunc(std.time.ns_per_s, self.max_fps);
        const elapsed = now_ns -% self.last_frame_ns;
        if (elapsed >= period) {
            // Behind schedule: never accumulate debt, or one hitch turns into
            // a visible freeze (the classic "spiral of the sleeping limiter").
            self.last_frame_ns = now_ns;
            return .{ .wait_ns = 0, .unlimited = false };
        }
        // Advance by exactly one period (not by `now`): the schedule is
        // absolute, so the frame jitter does not accumulate over time.
        self.last_frame_ns += period;
        return .{ .wait_ns = period - elapsed, .unlimited = false };
    }

    /// Performs the wait (separated from `wait` so tests stay pure and the
    /// runtime can profile the two halves).
    pub fn sleep(self: *FrameLimiter, ns: u64) void {
        if (ns == 0) return;
        // `time.monotonicNs` (not std.time): the engine's clock is the TSC when
        // it calibrates, and it is the SAME clock the profiler measures with.
        const time = @import("time.zig");
        const start = time.monotonicNs();
        if (ns > spin_tail_ns) {
            // clock_nanosleep through `time.sleepNs`: `std.Thread.sleep` is not
            // part of the 0.16 API surface and this one is what the rest of
            // the engine already uses.
            time.sleepNs(ns - spin_tail_ns);
        }
        // Spin the tail: a sleep overshoots by up to a millisecond.
        while (time.monotonicNs() -% start < ns) {
            std.atomic.spinLoopHint();
        }
        self.slept_frames += 1;
        self.total_wait_ns += ns;
    }

    /// Effective FPS the limiter reports for the run (0 = uncapped).
    pub fn effectiveFps(self: *const FrameLimiter) u32 {
        if (self.max_fps == 0 or self.use_vsync) return 0;
        return self.max_fps;
    }
};

test "frame limiter is inert when uncapped" {
    var f = FrameLimiter.init(0, false);
    const d = f.wait(1_000);
    try std.testing.expect(d.unlimited);
    try std.testing.expectEqual(@as(u64, 0), d.wait_ns);
}

test "frame limiter yields to vsync (the surface paces us)" {
    var f = FrameLimiter.init(30, true);
    const d = f.wait(1_000_000);
    try std.testing.expect(d.unlimited);
    try std.testing.expectEqual(@as(u32, 0), f.effectiveFps());
}

test "30 fps cap: a fast frame waits, a slow one does not" {
    var f = FrameLimiter.init(30, false); // 33.33 ms period
    const period = @divTrunc(std.time.ns_per_s, 30);

    _ = f.wait(0); // first frame: nothing to wait yet
    // A frame that took 1 ms must wait period - 1 ms.
    const d1 = f.wait(1_000_000);
    try std.testing.expectEqual(period - 1_000_000, d1.wait_ns);
    // The schedule advanced by exactly one period (not by `now`), so the next
    // frame starts at t=0+period. A frame that took 10 ms after that is still
    // fast and waits the remainder.
    const d2 = f.wait(period + 10_000_000);
    try std.testing.expectEqual(period - 10_000_000, d2.wait_ns);
    // A frame that overran the period never accumulates debt: no wait at all.
    const d3 = f.wait(2 * period + period); // t = 3*period, last = 2*period
    try std.testing.expectEqual(@as(u64, 0), d3.wait_ns);
}

test "limiter does not build up debt after a hitch" {
    var f = FrameLimiter.init(60, false);
    const period = @divTrunc(std.time.ns_per_s, 60);
    _ = f.wait(0);
    // 10-second stall, then a fast frame: the next wait is a full period, not
    // 10 seconds worth (that would be a freeze, not a limiter).
    _ = f.wait(10 * std.time.ns_per_s);
    const d = f.wait(10 * std.time.ns_per_s + 1_000_000);
    try std.testing.expect(d.wait_ns <= period);
}
