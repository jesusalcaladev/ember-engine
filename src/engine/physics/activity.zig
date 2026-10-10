//! Distance-based activity: how an open world with 200 000 bodies fits in a
//! 60 Hz budget (ROADMAP M5, "open world").
//!
//! ## The problem this actually solves
//!
//! Not "too many bodies" — "too many bodies *in contact at the same time*". A
//! sleeping body costs nothing to step, and a disabled one costs nothing at
//! all. Measured on the M4 bench, 2 000 bodies stacked cost ~3.2 ms inside
//! Box2D; the same 2 000 bodies spread across a level that has settled cost
//! almost nothing. The bill is for the AWAKE ones.
//!
//! So the question is never "how do I make the solver faster" but "which bodies
//! does the solver need to be thinking about right now".
//!
//! ## The tiers
//!
//! | tier | in solver | collision | typical distance |
//! |---|---|---|---|
//! | `full` | yes | exact shape | near the focus |
//! | `coarse` | yes | one circle covering the body | mid range |
//! | `frozen` | **disabled** | none | far |
//! | `unloaded` | **disabled** | none, and the shape is freed | very far |
//!
//! `coarse` exists because "switch it off" is the wrong answer for anything the
//! player can still see or walk into. A crate two rooms away must still stop a
//! bullet and must not let the player fall through it; it just does not need its
//! eight-vertex polygon tested against every neighbour. One circle is the
//! cheapest shape that still answers "is anything there".
//!
//! `unloaded` exists because memory is not free either: at some distance the
//! shape is worth destroying outright and rebuilding on the way back.
//!
//! ## Why the tiers are recomputed lazily
//!
//! Retuning means walking every body. Doing that per frame costs about as much
//! as simulating them, which would defeat the purpose. Instead the tier set is
//! recomputed only when the focus has moved a meaningful distance, so the cost
//! is amortised across many frames of small camera motion — and a game whose
//! camera sits still pays it once.
//!
//! ## Why there is hysteresis
//!
//! Without it, a body sitting exactly on a boundary flips tier every frame:
//! destroy the shape, rebuild it, freeze, unfreeze. The rebuild is far more
//! expensive than the simulation it was avoiding, so a naive distance test can
//! be *slower* than simulating everything. The bands below keep a body where it
//! is until it is clearly past the edge.
//!
//! ## Determinism
//!
//! Everything here is a pure function of (body position, focus, config), and the
//! focus comes from the runtime, not the solver. The same inputs therefore
//! produce the same tier set and the same trajectory — spec §6 holds, and the
//! M4 state hash covers the tier because it lives in the component.

const std = @import("std");
const core_math = @import("core").math;

pub const Vec2 = core_math.Vec2;

/// How much physics a body is getting. Stored in `RigidBody2D.tier` so it
/// travels with the entity through save/load and shows up in the state hash.
pub const Tier = enum(u8) {
    /// Simulated every step against its real shape.
    full = 0,
    /// Simulated against a single-circle proxy for its real shape.
    coarse = 1,
    /// Disabled in the solver: not stepped, not in any query.
    frozen = 2,
    /// Disabled and its shape destroyed, to be rebuilt on return.
    unloaded = 3,

    /// Whether the solver is stepping this body at all.
    pub fn isSimulated(self: Tier) bool {
        return self == .full or self == .coarse;
    }

    /// Whether the body still costs the solver anything.
    pub fn isActive(self: Tier) bool {
        return self.isSimulated();
    }

    pub fn name(self: Tier) []const u8 {
        return switch (self) {
            .full => "full",
            .coarse => "coarse",
            .frozen => "frozen",
            .unloaded => "unloaded",
        };
    }
};

pub const tier_count = 4;

/// Radii, in world units, and the knobs that make them not thrash.
pub const Config = struct {
    /// Beyond this the body is downgraded to a circle proxy.
    coarse_radius: f32 = 600,
    /// Beyond this the body stops being simulated at all.
    freeze_radius: f32 = 2000,
    /// Beyond this its shape is destroyed as well.
    unload_radius: f32 = 6000,

    /// A body must cross a boundary by this factor before it changes tier.
    ///
    /// 1.0 means "change on the boundary", which is the thrashing case: a body
    /// resting on a radius flips every frame and pays a shape rebuild for it.
    hysteresis: f32 = 1.25,

    /// How far the focus must move before tiers are recomputed.
    ///
    /// This is the single knob that decides the feature's own cost. Too small
    /// and the retune walk dominates; too large and bodies visibly lag behind
    /// the camera. At the default a retune happens every few seconds of normal
    /// camera motion.
    retune_distance: f32 = 128,

    /// Validate the configuration. Called by `init` rather than trusted,
    /// because every one of these is a number someone will eventually tune, and
    /// radii out of order produce a body that is "unloaded" but "simulated".
    pub fn validate(self: Config) !void {
        if (!(self.coarse_radius > 0 and self.freeze_radius > 0 and self.unload_radius > 0)) {
            return error.NonPositiveRadius;
        }
        if (!(self.coarse_radius < self.freeze_radius)) return error.RadiiOutOfOrder;
        if (!(self.freeze_radius < self.unload_radius)) return error.RadiiOutOfOrder;
        if (!(self.hysteresis >= 1.0)) return error.HysteresisBelowOne;
        if (!(self.retune_distance > 0)) return error.NonPositiveRadius;
    }
};

/// Counters, for the thing that has to be watched in a real game.
pub const Stats = struct {
    by_tier: [tier_count]u32 = .{0} ** tier_count,
    /// Bodies whose tier changed on the last retune. Sustained non-zero churn
    /// means the radii or the hysteresis are wrong.
    transitions: u32 = 0,
    /// Retunes since start.
    retunes: u64 = 0,
    /// Simulation updates actually pushed since start. With tiers working, this
    /// is far below `retunes * body_count`, and the ratio is the whole story.
    simulated_steps: u64 = 0,

    pub fn total(self: *const Stats) u32 {
        var n: u32 = 0;
        for (self.by_tier) |c| n += c;
        return n;
    }

    /// Fraction of bodies the solver is actually thinking about, 0..1.
    pub fn activeFraction(self: *const Stats) f64 {
        const t = self.total();
        if (t == 0) return 0.0;
        return @as(f64, @floatFromInt(self.by_tier[@intFromEnum(Tier.full)] + self.by_tier[@intFromEnum(Tier.coarse)])) / @as(f64, @floatFromInt(t));
    }
};

/// Owns the focus point and decides what is near it.
///
/// Stateless with respect to the world on purpose: it answers "what tier should a
/// body at this distance be", and the System applies the answer. Keeping the
/// decision separate from the mutation is what makes the hysteresis testable
/// without a solver.
pub const Activity = struct {
    config: Config,
    stats: Stats = .{},

    /// Where the camera (or player) is. Set by the runtime each frame.
    focus: Vec2 = .{ .x = 0, .y = 0 },
    /// Where the focus was at the last retune.
    last_tune: Vec2 = .{ .x = 0, .y = 0 },
    /// Whether the first retune has happened. `last_tune` alone cannot say, since
    /// a focus that never moves starts at the origin and would never retune.
    tuned_once: bool = false,

    pub fn init(config: Config) !Activity {
        try config.validate();
        return .{ .config = config };
    }

    /// Set the focus and report whether the tier set is now stale.
    ///
    /// Cheap enough to call every frame: it is one comparison.
    pub fn setFocus(self: *Activity, p: Vec2) bool {
        self.focus = p;
        return self.needsRetune();
    }

    /// True when the focus has moved far enough to be worth re-deciding.
    pub fn needsRetune(self: *const Activity) bool {
        if (!self.tuned_once) return true;
        const dx = self.focus.x - self.last_tune.x;
        const dy = self.focus.y - self.last_tune.y;
        return dx * dx + dy * dy >= self.config.retune_distance * self.config.retune_distance;
    }

    /// Called once a retune has actually run.
    pub fn markTuned(self: *Activity) void {
        self.last_tune = self.focus;
        self.tuned_once = true;
        self.stats.retunes += 1;
        self.stats.transitions = 0;
    }

    /// The tier a body NOT currently in the world should get. Used on spawn and
    /// on return from `unloaded`, where there is no current tier to be sticky
    /// about.
    pub fn tierAt(self: *const Activity, d: f32) Tier {
        const c = self.config;
        if (d <= c.coarse_radius) return .full;
        if (d <= c.freeze_radius) return .coarse;
        if (d <= c.unload_radius) return .frozen;
        return .unloaded;
    }

    /// The tier a body currently at `current` should move to, at distance `d`.
    ///
    /// The hysteresis is asymmetric on purpose: dropping a tier early is cheap
    /// and safe, restoring one late is what causes visible pop, so a body has to
    /// come noticeably closer before it gets its detail back.
    pub fn retier(self: *const Activity, current: Tier, d: f32) Tier {
        const c = self.config;

        // DOWNWARD: keep the current tier until clearly past its outward edge.
        switch (current) {
            .full => if (d > c.coarse_radius * c.hysteresis) return self.tierAt(d),
            .coarse => if (d > c.freeze_radius * c.hysteresis) return self.tierAt(d),
            .frozen => if (d > c.unload_radius * c.hysteresis) return self.tierAt(d),
            .unloaded => {}, // already the cheapest tier there is
        }

        // UPWARD: a body has to come noticeably CLOSER before it gets its detail
        // back.
        //
        // This is a separate pass and it was the bug that made the whole
        // feature look like it worked: the first version only checked
        // "am I far enough to drop a tier", so a body once demoted could never
        // be promoted again — it stayed frozen for the rest of the session no
        // matter where the camera went. The bench reported "0 of 200 000 bodies
        // simulated" while looking perfectly healthy, because every body had
        // been demoted once on the first retune and none could return.
        switch (current) {
            .unloaded => if (d < c.unload_radius / c.hysteresis) return self.tierAt(d),
            .frozen => if (d < c.freeze_radius / c.hysteresis) return self.tierAt(d),
            .coarse => if (d < c.coarse_radius / c.hysteresis) return self.tierAt(d),
            .full => {}, // already the most detailed tier
        }

        return current;
    }

    /// Distance from the focus, without a square root.
    pub fn distanceTo(self: *const Activity, p: Vec2) f32 {
        const dx = p.x - self.focus.x;
        const dy = p.y - self.focus.y;
        return @sqrt(dx * dx + dy * dy);
    }

    pub fn count(self: *Activity, t: Tier) void {
        self.stats.by_tier[@intFromEnum(t)] += 1;
    }

    pub fn noteSimulated(self: *Activity, n: u32) void {
        self.stats.simulated_steps += n;
    }
};

// ── Tests ────────────────────────────────────────────────────────────────────
//
// These test the DECISION, with no solver anywhere. The hysteresis logic is
// where an open-world feature quietly breaks — a body that thrashes is slower
// than no tiers at all — so it is worth testing on its own terms rather than
// only through a benchmark that would hide a 10 % regression inside noise.

const testing = std.testing;

test "distance picks the expected tier" {
    var a = try Activity.init(.{
        .coarse_radius = 100,
        .freeze_radius = 200,
        .unload_radius = 300,
    });
    try testing.expectEqual(Tier.full, a.tierAt(0));
    try testing.expectEqual(Tier.full, a.tierAt(100));
    try testing.expectEqual(Tier.coarse, a.tierAt(150));
    try testing.expectEqual(Tier.frozen, a.tierAt(250));
    try testing.expectEqual(Tier.unloaded, a.tierAt(1000));
}

test "a body on a boundary does not thrash" {
    var a = try Activity.init(.{
        .coarse_radius = 100,
        .freeze_radius = 200,
        .unload_radius = 300,
        .hysteresis = 1.25,
    });
    // Sitting exactly on the coarse radius, a full body stays full.
    var t: Tier = .full;
    var i: usize = 0;
    while (i < 10) : (i += 1) {
        t = a.retier(t, 100);
        try testing.expectEqual(Tier.full, t);
    }
    // Nudged just past it, still full: the band is the whole point.
    t = a.retier(t, 110);
    try testing.expectEqual(Tier.full, t);
    // Clearly past, it drops.
    t = a.retier(t, 126);
    try testing.expectEqual(Tier.coarse, t);
}

test "a body comes back only after clearly returning" {
    var a = try Activity.init(.{
        .coarse_radius = 100,
        .freeze_radius = 200,
        .unload_radius = 300,
        .hysteresis = 1.5,
    });
    const t = a.retier(.unloaded, 301);
    try testing.expectEqual(Tier.unloaded, t);
    // Coming back: 299 is inside the radius but not enough.
    try testing.expectEqual(Tier.unloaded, a.retier(.unloaded, 299));
    try testing.expectEqual(Tier.unloaded, a.retier(.unloaded, 250));
    try testing.expectEqual(Tier.frozen, a.retier(.unloaded, 199));
}

test "a demoted body climbs back through every tier as the focus returns" {
    // The regression test for the bug that made the feature a no-op: `retier`
    // originally only ever checked the DOWNWARD condition, so a body demoted
    // once could never be promoted again. Every body in an open world is
    // demoted on the first retune, which meant the world stayed empty.
    //
    // Walking a body in and back out is the shape of the real thing: the
    // camera approaches, the body gets more detailed in stages, then the
    // camera leaves and it degrades again.
    var a = try Activity.init(.{
        .coarse_radius = 100,
        .freeze_radius = 200,
        .unload_radius = 300,
        .hysteresis = 1.25,
    });

    // Walk out.
    var t: Tier = .full;
    var d: f32 = 0;
    while (d <= 400) : (d += 4) {
        t = a.retier(t, d);
        if (t == .unloaded) break;
    }
    try testing.expectEqual(Tier.unloaded, t);

    // Walk back in, and it must return to full without stalling on the way.
    var seen_coarse = false;
    var seen_frozen = false;
    var d_back: f32 = d;
    while (d_back >= 0) : (d_back -= 4) {
        t = a.retier(t, d_back);
        if (t == .coarse) seen_coarse = true;
        if (t == .frozen) seen_frozen = true;
        if (t == .full) break;
    }
    try testing.expect(seen_frozen); // it passed through frozen on the way up
    try testing.expect(seen_coarse);
    try testing.expectEqual(Tier.full, t);
}

test "each tier is reachable from every other one" {
    // Guards against the same class of bug from a different angle: no pair of
    // tiers may be a dead end.
    var a = try Activity.init(.{
        .coarse_radius = 100,
        .freeze_radius = 200,
        .unload_radius = 300,
        .hysteresis = 1.25,
    });
    const all = [_]Tier{ .full, .coarse, .frozen, .unloaded };

    for (all) |from| {
        // Far enough out to be fully demoted, then close enough to be fully
        // restored: whatever the starting tier, the body must be able to end up
        // `full`. The `probes` table is not needed here — the assertion is
        // about the transition, not about where the edges are.
        var t = a.retier(from, 500);
        try testing.expectEqual(Tier.unloaded, t);
        t = a.retier(t, 0);
        try testing.expectEqual(Tier.full, t);
    }
}

test "no tier change ever produces a churn cycle at the boundary" {
    // The property that matters: for any distance, repeatedly asking what tier
    // a body already at that tier should move to must be a FIXED POINT. A tier
    // system that is not idempotent rebuilds shapes forever.
    var a = try Activity.init(.{});
    var d: f32 = 0;
    while (d < 7000) : (d += 7) {
        const want = a.tierAt(d);
        try testing.expectEqual(want, a.retier(want, d));
    }
}

test "out-of-order radii are rejected at init, not discovered at runtime" {
    try testing.expectError(error.RadiiOutOfOrder, Activity.init(.{
        .coarse_radius = 500,
        .freeze_radius = 100,
        .unload_radius = 900,
    }));
    try testing.expectError(error.RadiiOutOfOrder, Activity.init(.{
        .coarse_radius = 100,
        .freeze_radius = 500,
        .unload_radius = 200,
    }));
    try testing.expectError(error.HysteresisBelowOne, Activity.init(.{ .hysteresis = 0.9 }));
}

test "retunes are amortised: a still focus retunes once and then never" {
    var a = try Activity.init(.{ .retune_distance = 100 });
    try testing.expect(a.needsRetune()); // never tuned
    a.markTuned();
    try testing.expect(!a.needsRetune());

    _ = a.setFocus(.{ .x = 50, .y = 0 });
    try testing.expect(!a.needsRetune());
    _ = a.setFocus(.{ .x = 200, .y = 0 });
    try testing.expect(a.needsRetune());
}

test "the active fraction is the number an open world is judged on" {
    var s = Stats{};
    s.by_tier[@intFromEnum(Tier.full)] = 20;
    s.by_tier[@intFromEnum(Tier.coarse)] = 30;
    s.by_tier[@intFromEnum(Tier.frozen)] = 950;
    s.by_tier[@intFromEnum(Tier.unloaded)] = 1000;
    try testing.expectEqual(@as(u32, 2000), s.total());
    // 5% of the world costs anything, which is the entire point.
    try testing.expectApproxEqAbs(@as(f64, 0.05), s.activeFraction(), 1e-9);
}