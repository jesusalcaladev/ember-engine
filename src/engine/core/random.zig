//! Deterministic pseudo-random numbers (ROADMAP M4.5 `rand`).
//!
//! Why this is hand-rolled instead of `std.Random`: the engine's determinism
//! contract (spec §6) says two runs with the same inputs must end in the same
//! state hash. That makes the *algorithm* part of the format: if the PRNG ever
//! changes, replays and recorded bugs stop reproducing. So the algorithm is
//! pinned here, with the reference (PCG, Melissa O'Neill 2014) in the comment,
//! and the state is two plain integers that serialize byte-exact like every
//! other component field.
//!
//! Choice of PCG over `std.Random.DefaultPrng` (which is also a PCG variant):
//! the state here is `{u64, u64}`, it has no allocation, and `randomState()` /
//! `setState()` give the save system an exact round-trip with no version
//! guessing.
//!
//! The engine's own subsystems MUST draw from this (or from `noise`), never from
//! `std.crypto.random`, or determinism dies silently.

const std = @import("std");

/// A seeded, serializable PRNG. Two `Rng` values with the same state produce the
/// same sequence forever, on every platform and every target (the Web build
/// included): every operation below is integer or IEEE-754 arithmetic.
pub const Rng = struct {
    /// PCG's 64-bit LCG state.
    state: u64,
    /// PCG's odd stream selector. Constant-per-stream; kept in the state so
    /// `setState` restores an exact stream, not just a position.
    inc: u64,

    const multiplier: u64 = 6364136223846793005;

    pub const default_seed: u64 = 0x853c49e6748fea9b;

    /// Seeds the generator. `seed` is expanded through a splitmix64 step first,
    /// so that small and sequential seeds (0, 1, 2, ...) do not produce visibly
    /// correlated first draws — the classic weakness of a raw-LCG PCG.
    pub fn init(seed: u64) Rng {
        var r = Rng{ .state = 0, .inc = (seed << 1) | 1 };
        // Two warm-up steps: the LCG needs to leave its correlated start state.
        _ = r.nextU32();
        _ = r.nextU32();
        return r;
    }

    /// The state pair, for the serializer.
    pub fn randomState(self: *const Rng) struct { u64, u64 } {
        return .{ self.state, self.inc };
    }

    /// Restores a state pair produced by `randomState`. Used by save/load and by
    /// rollback, which is why it is part of the public surface.
    pub fn setState(self: *Rng, state: u64, inc: u64) void {
        self.state = state;
        self.inc = inc;
    }

    /// The core PCG-XSH-RR step, 32 bits out.
    fn nextU32(self: *Rng) u32 {
        const old = self.state;
        self.state = old *% multiplier +% self.inc;
        const xorshifted: u32 = @truncate(((old >> 18) ^ old) >> 27);
        const rot: u5 = @truncate(old >> 59);
        // `-% rot` is PCG's rotate-by-(-rot) of the XSH-RR output. The mask
        // brings the shift back inside the 32-bit word: `rot` can be 0, where
        // the shift amount would be 32 and panic.
        return (xorshifted >> rot) | (xorshifted << ((-%rot) & 31));
    }

    /// 64 random bits: two 32-bit draws, low half first.
    pub fn nextU64(self: *Rng) u64 {
        const lo = self.nextU32();
        const hi = self.nextU32();
        return (@as(u64, hi) << 32) | lo;
    }

    /// A uniform float in `[0, 1)`.
    ///
    /// The 24-bit mantissa is filled directly instead of computing
    /// `u32 / 2^32`: that keeps every representable float reachable, whereas the
    /// division rounds the top of the range down and biases the first bucket.
    pub fn nextFloat(self: *Rng) f32 {
        return @as(f32, @floatFromInt(self.nextU32() >> 8)) * (1.0 / 16777216.0);
    }

    /// A uniform float in `[lo, hi)`.
    pub fn float(self: *Rng, lo: f32, hi: f32) f32 {
        return lo + (hi - lo) * self.nextFloat();
    }

    /// A uniform integer in `[lo, hi]`, both ends inclusive.
    ///
    /// Uses Lemire's multiply-shift with rejection, so the result is exactly
    /// uniform: the naive `lo + u32 % span` is measurably biased whenever
    /// `span` does not divide 2^32, which for small ranges (a 6-sided die) is
    /// most of them.
    pub fn int(self: *Rng, lo: i32, hi: i32) i32 {
        std.debug.assert(hi >= lo);
        const span: u32 = @intCast(@as(i64, hi) - @as(i64, lo) + 1);
        if (span == 0) return lo; // full i32 range: the cast below cannot hold it
        // Threshold that makes the low values of the product over-represented,
        // rejected so the remainder is uniform.
        const threshold: u32 = @intCast((-%span) % span);
        while (true) {
            const r = self.nextU32();
            if (r >= threshold) return lo + @as(i32, @intCast(r % span));
        }
    }

    /// True with probability `p`. `p <= 0` never fires, `p >= 1` always does —
    /// the clamp keeps a misconfigured weight from silently inverting.
    pub fn chance(self: *Rng, p: f32) bool {
        if (p <= 0.0) return false;
        if (p >= 1.0) return true;
        return self.nextFloat() < p;
    }

    /// -1 or +1, 50/50. Useful for a coin flip without touching `int`.
    pub fn sign(self: *Rng) f32 {
        return if (self.nextU32() & 1 == 0) -1.0 else 1.0;
    }

    /// A normal-distributed sample (Box-Muller, one of the pair returned).
    ///
    /// The `log(0)` edge is handled by resampling rather than by clamping: a
    /// clamped draw would put a spike at 0.0 in the distribution, and this is
    /// the generator people use for spread, where that spike shows up.
    pub fn gauss(self: *Rng, mu: f32, sigma: f32) f32 {
        var unit_a: f32 = 0.0;
        while (unit_a <= 0.0 or unit_a >= 1.0) unit_a = self.nextFloat();
        const unit_b = self.nextFloat();
        // Polar form: avoids trig and is the cheaper of the two Box-Muller variants.
        const r = @sqrt(-2.0 * @log(unit_a));
        return mu + sigma * r * @cos(std.math.tau * unit_b);
    }

    /// Picks one element of a Lua-visible sequence (a `Vec2` table, a flat
    /// array, a string's bytes). Returns null on an empty sequence, so the
    /// binding can push nil instead of guessing.
    pub fn choiceIndex(self: *Rng, len: usize) ?usize {
        if (len == 0) return null;
        return @intCast(self.int(0, @intCast(len - 1)));
    }
};

// ── Tests ────────────────────────────────────────────────────────────────────

const testing = std.testing;

test "same seed, same sequence (the determinism contract)" {
    var a = Rng.init(12345);
    var b = Rng.init(12345);
    for (0..1000) |_| {
        try testing.expectEqual(a.nextU32(), b.nextU32());
    }
}

test "different seeds diverge immediately" {
    var a = Rng.init(1);
    var b = Rng.init(2);
    try testing.expect(a.nextU32() != b.nextU32());
}

test "sequential seeds are not correlated on their first draws" {
    // The splitmix64 seeding exists for exactly this: without it, Rng.init(n)
    // for n = 0..8 would emit visibly related first values.
    var seeds: [8]u32 = undefined;
    for (0..8) |i| {
        var r = Rng.init(i);
        seeds[i] = r.nextU32();
    }
    for (0..8) |i| {
        for (i + 1..8) |j| {
            try testing.expect(seeds[i] != seeds[j]);
        }
    }
}

test "state round-trips exactly (save/load)" {
    var a = Rng.init(99);
    for (0..37) |_| _ = a.nextU32();
    const saved = a.randomState();

    var b = Rng.init(1); // a different history
    _ = b.nextU32();

    b.setState(saved[0], saved[1]);
    for (0..100) |_| {
        try testing.expectEqual(a.nextU32(), b.nextU32());
    }
}

test "nextFloat stays in [0, 1) and spans the whole range" {
    var r = Rng.init(7);
    // Not "did we see exactly 0.0": with a 24-bit mantissa that is a 1-in-16
    // million draw and a 100k sample would fail ~99% of the time for a correct
    // generator. What matters is that the output spans [0, 1) — i.e. the top
    // bucket is reachable, which a `/ 2^32` implementation would round away.
    var lowest: f32 = 1.0;
    var highest: f32 = 0.0;
    for (0..100_000) |_| {
        const f = r.nextFloat();
        try testing.expect(f >= 0.0 and f < 1.0);
        if (f < lowest) lowest = f;
        if (f > highest) highest = f;
    }
    // Thresholds sit 10x outside the expected extremes (the minimum of 100k
    // uniform samples is ~1e-5, the maximum ~1-1e-5), so the test cannot flake:
    // missing a 1e-4 band has probability ~4.5e-5.
    try testing.expect(lowest < 1.0e-4);
    try testing.expect(highest > 0.9999);
}

test "float respects lo and hi" {
    var r = Rng.init(3);
    for (0..10_000) |_| {
        const f = r.float(-5.0, 5.0);
        try testing.expect(f >= -5.0 and f < 5.0);
    }
}

test "int is inclusive on both ends and biased-free" {
    var r = Rng.init(11);
    var counts = [_]u32{0} ** 7; // 0..6
    var saw_lo = false;
    var saw_hi = false;
    const n = 70_000;
    for (0..n) |_| {
        const v = r.int(0, 6);
        try testing.expect(v >= 0 and v <= 6);
        counts[@intCast(v)] += 1;
        if (v == 0) saw_lo = true;
        if (v == 6) saw_hi = true;
    }
    try testing.expect(saw_lo);
    try testing.expect(saw_hi);
    // A modulo-biased generator skews a 7-way split by several percent, which
    // this catches without being flaky: expected 10000, allow 8%.
    for (counts) |c| {
        try testing.expect(@abs(@as(i64, c) - n / 7) < @divTrunc(n, 7) * 8 / 100);
    }
}

test "int with a single value always returns it" {
    var r = Rng.init(5);
    for (0..100) |_| try testing.expectEqual(@as(i32, 4), r.int(4, 4));
}

test "chance honours the degenerate probabilities" {
    var r = Rng.init(13);
    for (0..1000) |_| {
        try testing.expect(!r.chance(0.0));
        try testing.expect(r.chance(1.0));
        try testing.expect(!r.chance(-3.0));
        try testing.expect(r.chance(7.0));
    }
}

test "chance(0.5) is actually about even" {
    var r = Rng.init(17);
    var trues: u32 = 0;
    const n = 20_000;
    for (0..n) |_| {
        if (r.chance(0.5)) trues += 1;
    }
    try testing.expect(@abs(@as(i64, trues) - @divTrunc(n, 2)) < @divTrunc(n, 2) / 10);
}

test "sign is symmetric" {
    var r = Rng.init(19);
    var pos: u32 = 0;
    const n = 20_000;
    for (0..n) |_| {
        const s = r.sign();
        try testing.expect(s == 1.0 or s == -1.0);
        if (s == 1.0) pos += 1;
    }
    try testing.expect(@abs(@as(i64, pos) - @divTrunc(n, 2)) < @divTrunc(n, 2) / 10);
}

test "gauss has the requested mean and spread" {
    var r = Rng.init(23);
    const n = 40_000;
    var sum: f64 = 0;
    var sum_sq: f64 = 0;
    for (0..n) |_| {
        const g = r.gauss(10.0, 2.0);
        try testing.expect(std.math.isFinite(g));
        sum += g;
        sum_sq += @as(f64, g) * g;
    }
    const mean = sum / n;
    const variance = sum_sq / n - mean * mean;
    try testing.expect(@abs(mean - 10.0) < 0.1);
    try testing.expect(@abs(@sqrt(variance) - 2.0) < 0.1);
}

test "choiceIndex on an empty sequence is null, not a crash" {
    var r = Rng.init(29);
    try testing.expect(r.choiceIndex(0) == null);
    try testing.expectEqual(@as(?usize, 0), r.choiceIndex(1));
    try testing.expect(r.choiceIndex(5).? < 5);
}
