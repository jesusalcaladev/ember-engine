//! `Timer` — the gameplay timer component (ROADMAP M4.5, redesigned).
//!
//! The rule that shaped this file: a component is PLAIN DATA (registry rule 1),
//! so there are no function pointers here — the first draft of this component
//! had `?*const fn` callbacks and could never have been registered. Callbacks
//! are SIGNALS (`tick_signal`, `done_signal`), which is also what the roadmap
//! asks for ("callback → signal") and what lets both Zig listeners on the world
//! bus and Lua `on_signal` handlers receive them.
//!
//! The tick lives in `ecs/timer.zig`; it runs on the FIXED step so a timer is
//! deterministic (spec §6).

const name_mod = @import("name.zig");

pub const Name = name_mod.Name;

/// What kind of timer this is. The three cover every practical gameplay case:
///  - `once`: fires `done_signal` once after `duration`, then `finished`.
///  - `loop`: fires `done_signal` every `duration`, `loop_count` times
///    (0 = forever) — respawn waves, status refreshes.
///  - `during`: like `loop`, but ALSO fires `tick_signal` every tick, so a
///    "telegraph for 0.5 s" or an exposure bar can redraw without a second
///    clock. The tick's progress is `elapsed / duration`.
pub const TimerType = enum(u8) {
    once = 0,
    loop = 1,
    during = 2,
};

pub const Timer = struct {
    /// Seconds per cycle.
    duration: f32 = 1.0,
    /// Seconds accumulated in the current cycle.
    elapsed: f32 = 0.0,
    kind: TimerType = .once,
    /// Total cycles for `loop`/`during`; 0 = infinite.
    loop_count: u32 = 0,
    /// Cycles completed so far.
    current_loop: u32 = 0,
    paused: bool = false,
    /// Set when a `once` fired, or a `loop`/`during` exhausted `loop_count`.
    /// Stopped timers keep their component so the inspector can show them; the
    /// tick skips anything finished.
    finished: bool = false,
    /// The timer's OWN speed. 1 is normal, 0.5 is half as fast, 0 stops it.
    ///
    /// It multiplies with the GLOBAL scale (`time.scale`): a slow-motion game
    /// slows every timer, and a timer that is slower than the game is slower
    /// still. A buff that lasts 10 seconds of game time lasts 20 in a
    /// half-speed game, and 5 in a double-speed one.
    time_scale: f32 = 1.0,
    /// The cycles this timer COULD NOT run, because one tick asked for more
    /// than `max_cycles_per_tick`.
    ///
    /// Zero in a healthy game. A number that grows says the timer is running
    /// slower than it was asked to, which is otherwise invisible: the timer
    /// still fires, just late, and "late" is the kind of bug nobody reports
    /// until it is a firefight.
    dropped_cycles: u32 = 0,
    /// Signal fired every tick while `kind == .during`. Empty = none.
    tick_signal: Name = .{},
    /// Signal fired when a cycle completes. Empty = none.
    done_signal: Name = .{},

    /// Resets the cycle without changing any configuration.
    pub fn restart(self: *Timer) void {
        self.elapsed = 0;
        self.current_loop = 0;
        self.finished = false;
    }

    /// Progress of the current cycle, 0..1.
    pub fn progress(self: *const Timer) f32 {
        if (self.duration <= 0) return 1;
        return core_math.clampf(self.elapsed / self.duration, 0, 1);
    }
};

const core_math = @import("core").math;

// ── Tests ────────────────────────────────────────────────────────────────────

const std = @import("std");
const testing = std.testing;

test "Timer is plain data and fits the decoder stride" {
    const t = Timer{};
    try testing.expectEqual(TimerType.once, t.kind);
    try testing.expect(!t.paused);
    try testing.expect(!t.finished);
    try testing.expectEqual(@as(usize, 0), t.done_signal.len);
    // `max_stride` is the `.zson` decode buffer; the bound is enforced in the
    // registry at comptime and pinned here next to the type it protects.
    try testing.expect(@sizeOf(Timer) <= 128);
}

test "restart clears the cycle but keeps the configuration" {
    var t = Timer{ .duration = 2.5, .kind = .loop, .loop_count = 3 };
    t.elapsed = 2.4;
    t.current_loop = 2;
    t.finished = true;
    t.restart();
    try testing.expectEqual(@as(f32, 0), t.elapsed);
    try testing.expectEqual(@as(u32, 0), t.current_loop);
    try testing.expect(!t.finished);
    try testing.expectEqual(@as(f32, 2.5), t.duration);
    try testing.expectEqual(@as(u32, 3), t.loop_count);
}

test "progress is clamped and total-duration safe" {
    var t = Timer{ .duration = 2.0 };
    t.elapsed = 0.5;
    try testing.expectApproxEqAbs(@as(f32, 0.25), t.progress(), 0.0001);
    t.elapsed = 9;
    try testing.expectApproxEqAbs(@as(f32, 1.0), t.progress(), 0.0001);
    t.duration = 0;
    try testing.expectApproxEqAbs(@as(f32, 1.0), t.progress(), 0.0001); // no division by zero
}