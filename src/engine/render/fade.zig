//! M9 — scene transitions: the fade.
//!
//! A scene change without a transition is a cut, and a cut in a game that has
//! been running at 60 FPS since boot reads as a crash. This is the curtain:
//! `fade_out` covers the screen, the caller swaps the scene, `fade_in` uncovers.
//!
//! ## Why it lives in `render` and not in a gameplay module
//!
//! Because a fade is PRESENTATION. It advances on real time, not on the fixed
//! step: a transition that ran on the fixed step would slow down on a machine
//! that cannot keep up and speed up on one that can, and a slow machine is
//! exactly when the player is least patient. It is the one system in the engine
//! allowed to be a function of wall-clock, and the doc comment says so out loud
//! so the next person does not "fix" it into the fixed step.
//!
//! ## What the state machine is
//!
//! Three states and two transitions, no more:
//!
//!   idle ──fadeOut──▶ fading_out ──(t = duration)──▶ idle (amount 1, finished)
//!   idle ──fadeIn───▶ fading_in ───(t = duration)──▶ idle (amount 0, finished)
//!
//! A finished transition sets `just_finished` for one frame and the runtime
//! turns that into the `scene_faded` signal, which is what lets a script swap
//! the level at the exact frame the screen is fully covered instead of polling
//! an amount every frame and hoping.
//!
//! Easing is smoothstep, not linear. A linear fade has a visible corner where
//! it starts and stops — the derivative jumps — and the smoothstep one does not,
//! which is the entire difference between "fade" and "a rectangle sliding in".

const core_math = @import("core").math;
const std = @import("std");
const testing = std.testing;

pub const State = enum(u8) {
    /// Nothing happening. `amount` remembers the last settled value so a
    /// scene loaded while covered stays covered.
    idle = 0,
    /// Covering: amount goes 0 → 1.
    fading_out = 1,
    /// Uncovering: amount goes 1 → 0.
    fading_in = 2,
};

pub const Fader = struct {
    state: State = .idle,
    /// Seconds since the current transition began.
    elapsed: f32 = 0,
    /// The transition's total length. 0 is legal and means "instantly".
    duration: f32 = 0,
    /// The curtain's colour. Black by default, because that is what a fade is.
    color: [3]f32 = .{ 0, 0, 0 },
    /// Current coverage, 0..1, already eased. What the post pass multiplies with.
    amount: f32 = 0,
    /// True for exactly one `update` after a transition settles. The runtime
    /// reads it to fire `scene_faded`; reading it without a following update
    /// keeps returning the settled value, which is what makes a missed frame a
    /// late signal and not a lost one.
    just_finished: bool = false,

    /// Begins covering the screen. A second call while already fading out
    /// RESTARTS it — an interrupted fade is a fade that changed its mind about
    /// how long it takes, not two overlapping curtains.
    pub fn fadeOut(self: *Fader, duration: f32, color: [3]f32) void {
        self.state = .fading_out;
        self.elapsed = 0;
        self.duration = @max(duration, 0);
        self.color = color;
        self.just_finished = false;
    }

    /// Begins uncovering, from whatever colour the curtain currently is. Pass no
    /// colour: fading in returns to the scene, not to a different colour.
    pub fn fadeIn(self: *Fader, duration: f32) void {
        self.state = .fading_in;
        self.elapsed = 0;
        self.duration = @max(duration, 0);
        self.just_finished = false;
    }

    /// Jumps straight to a covered screen with no animation. What a loading
    /// screen does: the player must not watch a fade play before a black frame
    /// they are going to sit on for two seconds anyway.
    pub fn snapCovered(self: *Fader, color: [3]f32) void {
        self.state = .idle;
        self.elapsed = 0;
        self.duration = 0;
        self.color = color;
        self.amount = 1;
        self.just_finished = false;
    }

    /// Jumps back to a clear screen.
    pub fn snapClear(self: *Fader) void {
        self.state = .idle;
        self.elapsed = 0;
        self.duration = 0;
        self.amount = 0;
        self.just_finished = false;
    }

    /// Advances the transition by `dt` REAL seconds.
    pub fn update(self: *Fader, dt: f32) void {
        self.just_finished = false;
        if (self.state == .idle) return;
        self.elapsed += @max(dt, 0);
        const t = if (self.duration > 0) core_math.clampf(self.elapsed / self.duration, 0, 1) else 1;
        const eased = t * t * (3.0 - 2.0 * t); // smoothstep
        switch (self.state) {
            .idle => {},
            .fading_out => self.amount = eased,
            .fading_in => self.amount = 1.0 - eased,
        }
        if (t >= 1.0) {
            self.amount = if (self.state == .fading_out) 1.0 else 0.0;
            self.state = .idle;
            self.just_finished = true;
        }
    }

    /// The curtain as rgb + amount, which is exactly what the post pass wants
    /// (`fog_color` carries its strength in alpha the same way).
    pub fn rgba(self: *const Fader) [4]f32 {
        return .{ self.color[0], self.color[1], self.color[2], self.amount };
    }

    pub fn isIdle(self: *const Fader) bool {
        return self.state == .idle;
    }
};

// ── Tests ────────────────────────────────────────────────────────────────────

test "a fade out covers the screen and settles at 1" {
    var f = Fader{};
    f.fadeOut(1.0, .{ 0, 0, 0 });
    try testing.expectEqual(State.fading_out, f.state);
    f.update(0.5);
    // Halfway through a smoothstep is 0.5: the curve is symmetric, which is the
    // one property a fade-out/in pair needs to read as one motion.
    try testing.expectApproxEqAbs(@as(f32, 0.5), f.amount, 0.001);
    f.update(0.5);
    try testing.expect(f.isIdle());
    try testing.expectEqual(@as(f32, 1.0), f.amount);
    // The signal frame: exactly one.
    try testing.expect(f.just_finished);
    f.update(0.016);
    try testing.expect(!f.just_finished);
}

test "a fade in uncovers from the curtain colour" {
    var f = Fader{};
    f.snapCovered(.{ 0, 0, 0 });
    f.fadeIn(0.5);
    f.update(0.25);
    try testing.expectApproxEqAbs(@as(f32, 0.5), f.amount, 0.001);
    f.update(0.25);
    try testing.expect(f.isIdle());
    try testing.expectEqual(@as(f32, 0.0), f.amount);
    try testing.expect(f.just_finished);
}

test "a zero-duration fade snaps instead of dividing by zero" {
    var f = Fader{};
    f.fadeOut(0, .{ 1, 1, 1 });
    f.update(0.016);
    try testing.expect(f.isIdle());
    try testing.expectEqual(@as(f32, 1.0), f.amount);
    try testing.expect(f.just_finished);
}

test "an idle fader never fires just_finished" {
    var f = Fader{};
    var i: usize = 0;
    while (i < 10) : (i += 1) f.update(1.0 / 60.0);
    try testing.expect(!f.just_finished);
    try testing.expectEqual(@as(f32, 0.0), f.amount);
}

test "an interrupted fade restarts rather than overlapping" {
    var f = Fader{};
    f.fadeOut(10.0, .{ 0, 0, 0 });
    f.update(0.1);
    // A second, shorter fade-out replaces the first from zero.
    f.fadeOut(0.2, .{ 1, 0, 0 });
    try testing.expectEqual(@as(f32, 0), f.elapsed);
    f.update(0.05);
    // A quarter through the NEW fade: not the old one's progress (which would
    // be 0.025% — indistinguishable from nothing — and not the SUM of two
    // curtains, which would be the bug this test exists to catch).
    try testing.expect(f.amount > 0.1 and f.amount < 0.4);
}

test "a negative dt cannot run a transition backwards" {
    var f = Fader{};
    f.fadeOut(1.0, .{ 0, 0, 0 });
    f.update(0.5);
    const mid = f.amount;
    f.update(-10.0);
    try testing.expectEqual(mid, f.amount);
}

test "rgba carries the amount in alpha (the post pass's contract)" {
    var f = Fader{};
    f.snapCovered(.{ 0.25, 0.5, 0.75 });
    try testing.expectEqual([4]f32{ 0.25, 0.5, 0.75, 1.0 }, f.rgba());
    f.snapClear();
    try testing.expectEqual([4]f32{ 0.25, 0.5, 0.75, 0.0 }, f.rgba());
}
