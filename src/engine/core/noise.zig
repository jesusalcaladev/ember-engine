//! Deterministic procedural noise (ROADMAP M4.5 `noise`).
//!
//! Same contract as `random.zig`: the output is a pure function of
//! `(seed, x, y)`, so a level generated on a replay regenerates identically.
//! Nothing here allocates and nothing here touches global state — the seed is
//! passed in, which is what lets two subsystems use different noise fields
//! (terrain height vs. cloud drift) without interfering.
//!
//! Three bases are provided because games need different things from noise:
//! - **value** — cheap, blocky when sampled far apart. Fine for terrain height.
//! - **perlin** — the classic gradient noise; smooth, no directional artefacts.
//!   The workhorse for procedural terrain.
//! - **simplex** — a triangular lattice with no axis-aligned bias, which is why
//!   it is the one to reach for when the noise is sampled along circles or used
//!   for isotropic warp (clouds, flow fields, wandering animals).
//!
//! `fbm` and `ridged` compose a base into something with structure at several
//! scales, which is almost always what a game wants rather than one octave.

const std = @import("std");
const rand_mod = @import("random.zig");

/// Largest octave count any caller may request. Bounds the cost of `fbm` from
/// a Lua script: without a cap, `fbm(x, y, 200)` is a frame-long stall.
pub const max_octaves = 12;

/// A 2D unit vector. A named struct rather than a `@Vector(2, f32)` so the dot
/// product is the plain `a.x*b.x + a.y*b.y` below — the vector builtin for it
/// has moved around across Zig versions, and two multiplies are free here.
const Grad = struct {
    x: f32,
    y: f32,
};

fn dotGrad(a: Grad, bx: f32, by: f32) f32 {
    return a.x * bx + a.y * by;
}

// ── Hashing ──────────────────────────────────────────────────────────────────
// A 2D integer hash, not a permutation: noise needs decorrelated values at
// neighbouring lattice points, and a gradient-style hash also wants the low bits
// to be well mixed.

/// Hashes two lattice coordinates plus a seed to `[0, 1)`.
fn hash2(seed: u64, x: i32, y: i32) f32 {
    var h = seed;
    // Widen the signed lattice coordinates through u32 first: sign-extending an
    // i32 straight into the u64 multiply would make every negative coordinate
    // differ from its positive mirror by 2^63, which is a hash, but not the
    // useful one — it wastes the whole high half on the sign.
    const ux: u64 = @as(u32, @bitCast(x));
    const uy: u64 = @as(u32, @bitCast(y));
    h ^= ux *% 0x9E3779B97F4A7C15;
    h ^= uy *% 0xC2B2AE3D27D4EB4F;
    h ^= h >> 29;
    h *%= 0xBF58476D1CE4E5B9;
    h ^= h >> 32;
    h *%= 0x94D049BB133111EB;
    h ^= h >> 29;
    // 24 bits: exactly the f32 mantissa, so the result is representable and
    // strictly below 1.0.
    return @as(f32, @floatFromInt((h >> 40) & 0xFFFFFF)) * (1.0 / 16777216.0);
}

/// Hashes a lattice point to a unit gradient (one of 8 directions). Perlin's
/// gradient set is the diagonals + axes; the 2^2 * 8 = 32 distinct values are
/// all reachable from this hash.
fn hash2_grad(seed: u64, x: i32, y: i32) Grad {
    // hash2 is in [0, 1), so the product is in [0, 8): the truncation is safe and
    // spreads the 8 gradients evenly.
    const h: u8 = @intFromFloat(hash2(seed, x, y) * 8.0);
    return switch (h) {
        0 => .{ .x = 1.0, .y = 0.0 },
        1 => .{ .x = -1.0, .y = 0.0 },
        2 => .{ .x = 0.0, .y = 1.0 },
        3 => .{ .x = 0.0, .y = -1.0 },
        4 => .{ .x = 0.7071, .y = 0.7071 },
        5 => .{ .x = -0.7071, .y = 0.7071 },
        6 => .{ .x = 0.7071, .y = -0.7071 },
        else => .{ .x = -0.7071, .y = -0.7071 },
    };
}

/// Quintic fade, the same curve Perlin used: `6t^5 - 15t^4 + 10t^3`. Its first
/// AND second derivatives vanish at 0 and 1, so the noise has no visible grid
/// creases where the interpolation switches — the linear fade (value noise)
/// shows a faint lattice.
fn fade(t: f32) f32 {
    return t * t * t * (t * (t * 6.0 - 15.0) + 10.0);
}

fn lerp(a: f32, b: f32, t: f32) f32 {
    return a + (b - a) * t;
}

/// 2D value noise in `[-1, 1]`. Smooth, but with a faint square lattice when
/// sampled sparsely — see the file header for when to pick simplex instead.
pub fn value(seed: u64, x: f32, y: f32) f32 {
    const xi = @floor(x);
    const yi = @floor(y);
    const xf = x - xi;
    const yf = y - yi;
    const ix: i32 = @intFromFloat(xi);
    const iy: i32 = @intFromFloat(yi);

    const v00 = hash2(seed, ix, iy);
    const v10 = hash2(seed, ix + 1, iy);
    const v01 = hash2(seed, ix, iy + 1);
    const v11 = hash2(seed, ix + 1, iy + 1);

    const u = fade(xf);
    const v = fade(yf);
    const top = lerp(v00, v10, u);
    const bottom = lerp(v01, v11, u);
    // -1..1 from a 0..1 hash.
    return lerp(top, bottom, v) * 2.0 - 1.0;
}

/// 2D gradient (Perlin) noise in `[-1, 1]`. No lattice artefacts, which is why
/// it is the default for terrain.
pub fn perlin(seed: u64, x: f32, y: f32) f32 {
    const xi = @floor(x);
    const yi = @floor(y);
    const xf = x - xi;
    const yf = y - yi;
    const ix: i32 = @intFromFloat(xi);
    const iy: i32 = @intFromFloat(yi);

    const g00 = hash2_grad(seed, ix, iy);
    const g10 = hash2_grad(seed, ix + 1, iy);
    const g01 = hash2_grad(seed, ix, iy + 1);
    const g11 = hash2_grad(seed, ix + 1, iy + 1);

    const d00: f32 = dotGrad(g00, xf, yf);
    const d10: f32 = dotGrad(g10, xf - 1.0, yf);
    const d01: f32 = dotGrad(g01, xf, yf - 1.0);
    const d11: f32 = dotGrad(g11, xf - 1.0, yf - 1.0);

    const u = fade(xf);
    const v = fade(yf);
    // Perlin's gradients are unit length, so the raw sum is already in
    // roughly [-1, 1] for the unit cell; the 0.7 factor restores that after the
    // quintic weighting. Clamped so the documented range is a guarantee.
    const n = lerp(lerp(d00, d10, u), lerp(d01, d11, u), v) * 1.4;
    return std.math.clamp(n, -1.0, 1.0);
}

/// The 2D simplex skew factors (Gustavson's).
const skew: f32 = 0.5 * (@as(f32, @sqrt(3.0)) - 1.0);
const unskew: f32 = (3.0 - @as(f32, @sqrt(3.0))) / 6.0;

/// 2D simplex noise in `[-1, 1]`. The triangular lattice removes the axis bias
/// of a square grid, so it stays isotropic when sampled along circles — the
/// reason to use it over perlin for flow fields, clouds and animal wander.
pub fn simplex(seed: u64, x: f32, y: f32) f32 {
    // Skew the input space into the simplex lattice.
    const s = (x + y) * skew;
    const xi = @floor(x + s);
    const yi = @floor(y + s);
    const t = (xi + yi) * unskew;
    const x0 = x - (xi - t);
    const y0 = y - (yi - t);

    // Which of the two triangles of the cell are we in? `i1`/`j1` select the
    // MIDDLE corner, and they MUST swap with the triangle: hardcoding the
    // (x0 > y0) offsets would sample two of the three corners off their lattice
    // points for the entire other half of the plane, which shows up as noise
    // wildly out of range rather than as an obviously wrong shape.
    const i: i32 = @intFromFloat(xi);
    const j: i32 = @intFromFloat(yi);
    const step_i: i32 = if (x0 > y0) 1 else 0;
    const step_j: i32 = if (x0 > y0) 0 else 1;

    const x1 = x0 - @as(f32, @floatFromInt(step_i)) + unskew;
    const y1 = y0 - @as(f32, @floatFromInt(step_j)) + unskew;
    const x2 = x0 - 1.0 + 2.0 * unskew;
    const y2 = y0 - 1.0 + 2.0 * unskew;

    // The offsets are ABSOLUTE (x0/y0, x1/y1, x2/y2), not relative to the origin
    // corner. That distinction is the whole ballgame: at a cell boundary the
    // old cell's middle corner and the new cell's origin corner are the SAME
    // lattice point, and only the absolute form gives them the same offset — so
    // a relative form leaves a full-amplitude step in the field at every cell
    // edge (measured: a 1.0 discontinuity, i.e. the whole output range).
    const n0: f32 = corner(seed, i, j, x0, y0);
    const n1: f32 = corner(seed, i + step_i, j + step_j, x1, y1);
    const n2: f32 = corner(seed, i + 1, j + 1, x2, y2);

    // 70 is the canonical simplex scale factor for unit-length gradients. The
    // clamp is not cosmetic: with a hash-selected gradient set the extreme
    // corners can reach slightly past 1.0, and every caller is promised
    // [-1, 1] (fbm, ridged and the Lua binding all rely on it).
    return std.math.clamp(70.0 * (n0 + n1 + n2), -1.0, 1.0);
}

/// One simplex corner contribution: distance attenuation, 0 at the lattice
/// point and ~0 at radius 1.
fn corner(seed: u64, i: i32, j: i32, dx: f32, dy: f32) f32 {
    const falloff = 0.5 - dx * dx - dy * dy;
    if (falloff < 0.0) return 0.0;
    // falloff^4, not falloff^2. This is the detail that makes the canonical
    // scale factor of 70 correct: with only a square the raw sum runs ~5x too
    // hot, the clamp does the rest, and the field comes out BIMODAL (measured:
    // 40% of samples pinned at each end, almost none in the middle) instead of
    // bell-shaped around zero.
    const squared = falloff * falloff;
    return squared * squared * dotGrad(hash2_grad(seed, i, j), dx, dy);
}

/// Which base `fbm` and `ridged` sum. Kept as an enum so the Lua side passes a
/// name, not a number that can silently mean something else later.
pub const Basis = enum {
    value,
    perlin,
    simplex,

    fn eval(self: Basis, seed: u64, x: f32, y: f32) f32 {
        return switch (self) {
            .value => value(seed, x, y),
            .perlin => perlin(seed, x, y),
            .simplex => simplex(seed, x, y),
        };
    }
};

/// Fractal Brownian motion: `octaves` of the base noise, each at double the
/// frequency and `gain` the amplitude. Returns roughly `[-1, 1]`.
///
/// Defaults are the usual terrain pair (each octave twice as fine, half as
/// strong); `lacunarity`/`gain` are exposed because a game with a specific look
/// in mind should not have to reimplement the sum to get it.
pub fn fbm(seed: u64, x: f32, y: f32, octaves: u8, basis: Basis) f32 {
    return fbmTuned(seed, x, y, octaves, basis, 2.0, 0.5);
}

/// `fbm` with explicit lacunarity and gain. Clamped to 8 octaves and to sane
/// multiplier ranges: the sum of octaves grows with `octaves`, so an unbounded
/// version would leave `[-1, 1]` and blow up on the 9th call from a script.
pub fn fbmTuned(
    seed: u64,
    x: f32,
    y: f32,
    octaves: u8,
    basis: Basis,
    lacunarity: f32,
    gain: f32,
) f32 {
    const n_octaves: usize = @min(octaves, max_octaves);
    const lac = std.math.clamp(lacunarity, 1.0, 4.0);
    const g = std.math.clamp(gain, 0.0, 1.0);

    var sum: f32 = 0.0;
    var amplitude: f32 = 1.0;
    // Normalising by the total amplitude keeps the result in [-1, 1] whatever
    // `octaves` is; without it, 8 octaves would saturate well before the cap.
    var norm: f32 = 0.0;
    var fx = x;
    var fy = y;

    for (0..n_octaves) |_| {
        sum += amplitude * basis.eval(seed, fx, fy);
        norm += amplitude;
        amplitude *= g;
        // Each octave's frequency is multiplied by `lacunarity`, so it must also
        // be rotated slightly. Rotating decorrelates the octaves: without it,
        // features line up along the axes and the result looks like stripes.
        const next_x = fx * lac * 0.8 - fy * lac * 0.6;
        const next_y = fx * lac * 0.6 + fy * lac * 0.8;
        fx = next_x;
        fy = next_y;
    }

    if (norm == 0.0) return 0.0;
    return std.math.clamp(sum / norm, -1.0, 1.0);
}

/// Ridged multifractal: `1 - |noise|`, squared. The absolute value folds the
/// noise so the zero crossings become ridges, which is what makes mountain
/// silhouettes and coastlines out of the same function.
pub fn ridged(seed: u64, x: f32, y: f32, octaves: u8, basis: Basis) f32 {
    const n_octaves: usize = @min(octaves, max_octaves);
    var sum: f32 = 0.0;
    var amplitude: f32 = 1.0;
    var norm: f32 = 0.0;
    var fx = x;
    var fy = y;

    for (0..n_octaves) |_| {
        const n = 1.0 - @abs(basis.eval(seed, fx, fy));
        // Squaring sharpens the ridge and deepens the valleys.
        sum += amplitude * n * n;
        norm += amplitude;
        amplitude *= 0.5;
        const next_x = fx * 2.0 * 0.8 - fy * 2.0 * 0.6;
        const next_y = fx * 2.0 * 0.6 + fy * 2.0 * 0.8;
        fx = next_x;
        fy = next_y;
    }

    if (norm == 0.0) return 0.0;
    return std.math.clamp(sum / norm, 0.0, 1.0);
}

// ── Tests ────────────────────────────────────────────────────────────────────

const testing = std.testing;

test "every basis stays inside its documented range" {
    var r = rand_mod.Rng.init(4242);
    for (0..20_000) |_| {
        const x = r.float(-100.0, 100.0);
        const y = r.float(-100.0, 100.0);
        for ([_]Basis{ .value, .perlin, .simplex }) |b| {
            const n = b.eval(7, x, y);
            try testing.expect(std.math.isFinite(n));
            try testing.expect(n >= -1.0 and n <= 1.0);
        }
    }
}

test "noise is a pure function of seed and position" {
    for ([_]Basis{ .value, .perlin, .simplex }) |b| {
        const a = b.eval(31, 12.5, -7.25);
        const c = b.eval(31, 12.5, -7.25);
        try testing.expectEqual(a, c);
    }
}

test "different seeds give different fields" {
    try testing.expect(perlin(1, 3.5, 2.5) != perlin(2, 3.5, 2.5));
    try testing.expect(value(1, 3.5, 2.5) != value(2, 3.5, 2.5));
    try testing.expect(simplex(1, 3.5, 2.5) != simplex(2, 3.5, 2.5));
}

test "noise is continuous: nearby samples are nearby values" {
    // A jumpy field would mean a broken hash or a missing fade; this is the
    // property that makes terrain from noise look like terrain.
    for ([_]Basis{ .value, .perlin, .simplex }) |b| {
        var max_jump: f32 = 0.0;
        var x: f32 = -20.0;
        while (x < 20.0) : (x += 0.01) {
            const a = b.eval(5, x, 3.0);
            const c = b.eval(5, x + 0.01, 3.0);
            const jump = @abs(a - c);
            if (jump > max_jump) max_jump = jump;
        }
        // 0.01 of a unit cell across any smooth field: a tiny step.
        try testing.expect(max_jump < 0.05);
    }
}

test "the value distribution is centred, not pinned at the rails" {
    // A range assertion cannot catch a mis-scaled basis: a field that is 80%
    // saturated at +/-1 is technically "in range" and completely unusable, and
    // it is exactly what a wrong corner falloff exponent produces. This checks
    // the SHAPE — for every basis, the middle of the range must actually be
    // where samples live.
    // A range assertion cannot catch a mis-scaled basis: a field that is 80%
    // saturated at +/-1 is technically "in range" and completely unusable, and
    // it is exactly what a wrong corner falloff exponent produces. This checks
    // the SHAPE — for every basis, the middle of the range must actually be
    // where samples live.
    inline for (.{ Basis.value, Basis.perlin, Basis.simplex }) |b| {
        var in_middle: u32 = 0;
        var total: u32 = 0;
        var x: f32 = -40.0;
        while (x < 40.0) : (x += 0.05) {
            var y: f32 = -40.0;
            while (y < 40.0) : (y += 0.05) {
                const n = b.eval(5, x, y);
                total += 1;
                if (n > -0.5 and n < 0.5) in_middle += 1;
            }
        }
        const middle_fraction = @as(f64, @floatFromInt(in_middle)) / @as(f64, @floatFromInt(total));
        // A bell-shaped field spends ~68% of its samples in the central half of
        // the range; a bimodal/saturated one spends nearly none there.
        try testing.expect(middle_fraction > 0.5);
    }
}

test "noise actually varies (is not a constant field)" {
    var r = rand_mod.Rng.init(8);
    var min_v: f32 = 1.0;
    var max_v: f32 = -1.0;
    for (0..5_000) |_| {
        const n = perlin(3, r.float(-50, 50), r.float(-50, 50));
        if (n < min_v) min_v = n;
        if (n > max_v) max_v = n;
    }
    try testing.expect(max_v - min_v > 0.5);
}

test "fbm stays in range and is capped at max_octaves" {
    const huge: u8 = 255;
    for ([_]Basis{ .value, .perlin, .simplex }) |b| {
        for ([_]u8{ 0, 1, 4, 12, huge }) |oct| {
            const n = fbm(9, 3.25, -1.5, oct, b);
            try testing.expect(std.math.isFinite(n));
            try testing.expect(n >= -1.0 and n <= 1.0);
        }
    }
}

test "fbm is deterministic" {
    try testing.expectEqual(fbm(2, 1.5, 2.5, 5, .perlin), fbm(2, 1.5, 2.5, 5, .perlin));
}

test "fbm tuning out of range is clamped, not propagated" {
    // A script passing nonsense must not produce NaN or a runaway sum.
    for ([_]f32{ -5.0, 0.0, 100.0 }) |lac| {
        for ([_]f32{ -2.0, 2.0, 50.0 }) |g| {
            const n = fbmTuned(4, 1.0, 1.0, 8, .perlin, lac, g);
            try testing.expect(std.math.isFinite(n));
            try testing.expect(n >= -1.0 and n <= 1.0);
        }
    }
}

test "more octaves add high-frequency detail" {
    // NOT the sum of |values|: `fbm` normalizes by the total amplitude on
    // purpose, so six octaves are deliberately QUIETER than one — comparing
    // amplitudes would fail on correct code. Total variation per unit distance
    // is the honest measure: finer octaves make the field wiggle more between
    // nearby samples.
    //
    // The step MUST be finer than the highest octave's wavelength (1/32 of a
    // cell) or the measurement aliases: at step 0.05 the ratio measured 0.94
    // (fewer, not more) on correct code. At 0.002 it is 1.12. Deterministic
    // seed and coordinates, so the margin does not need to be generous.
    const step: f32 = 0.002;
    var one: f64 = 0.0;
    var six: f64 = 0.0;
    var x: f32 = -30.0;
    while (x < 30.0) : (x += step) {
        one += @abs(fbm(6, x + step, 3.0, 1, .perlin) - fbm(6, x, 3.0, 1, .perlin));
        six += @abs(fbm(6, x + step, 3.0, 6, .perlin) - fbm(6, x, 3.0, 6, .perlin));
    }
    try testing.expect(six > one);
}

test "ridged is in 0..1 and peaks where noise crosses zero" {
    var r = rand_mod.Rng.init(88);
    var saw_low = false;
    var saw_high = false;
    for (0..5_000) |_| {
        const x = r.float(-40, 40);
        const y = r.float(-40, 40);
        const v = ridged(3, x, y, 4, .perlin);
        try testing.expect(v >= 0.0 and v <= 1.0);
        if (v < 0.2) saw_low = true;
        if (v > 0.8) saw_high = true;
    }
    try testing.expect(saw_low);
    try testing.expect(saw_high);
}

test "negative coordinates work (the classic floor-division bug)" {
    // A lattice that only works for x >= 0 is the single most common noise
    // defect; these are exactly the coordinates where @intFromFloat truncation
    // would go wrong.
    for ([_]f32{ -0.5, -1.0, -1.5, -99.25, -1000.5 }) |v| {
        for ([_]Basis{ .value, .perlin, .simplex }) |b| {
            const n = b.eval(1, v, v);
            try testing.expect(std.math.isFinite(n));
            try testing.expect(n >= -1.0 and n <= 1.0);
        }
    }
}
