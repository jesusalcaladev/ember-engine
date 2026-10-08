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

    pub fn init(fixed_dt: f32) FixedLoop {
        return .{ .fixed_dt = fixed_dt };
    }

    /// Adds real time and returns how many fixed steps must run.
    /// `real_dt` is clamped to avoid jumps after tab switches or hitches.
    pub fn addTime(self: *FixedLoop, real_dt: f32) u32 {
        const clamped = @min(real_dt, 0.1);
        self.accumulator += clamped * self.scale;
        if (self.accumulator < 0) self.accumulator = 0;

        var steps: u32 = 0;
        while (steps < self.max_catchup and self.accumulator >= self.fixed_dt) : (steps += 1) {
            self.accumulator -= self.fixed_dt;
        }
        // Leftover after exhausting catch-up: dropped (anti death-spiral).
        if (steps == self.max_catchup and self.accumulator >= self.fixed_dt) {
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

test "time scale and pause" {
    var l = FixedLoop.init(1.0 / 60.0);
    l.scale = 0;
    try std.testing.expectEqual(@as(u32, 0), l.addTime(10.0));
    l.scale = 0.5;
    try std.testing.expectEqual(@as(u32, 1), l.addTime(1.0 / 30.0));
}
