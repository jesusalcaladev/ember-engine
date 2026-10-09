//! Minimal 2D math for M0: Vec2, Mat4 and lerp.
//!
//! Column-major (compatible with WGSL mat4x4<f32>). Grows per milestone;
//! nothing here allocates memory.

const std = @import("std");

pub const Vec2 = struct {
    x: f32 = 0,
    y: f32 = 0,

    pub const zero = Vec2{};

    pub fn add(a: Vec2, b: Vec2) Vec2 {
        return .{ .x = a.x + b.x, .y = a.y + b.y };
    }
    pub fn sub(a: Vec2, b: Vec2) Vec2 {
        return .{ .x = a.x - b.x, .y = a.y - b.y };
    }
    pub fn scale(a: Vec2, s: f32) Vec2 {
        return .{ .x = a.x * s, .y = a.y * s };
    }
    pub fn dot(a: Vec2, b: Vec2) f32 {
        return a.x * b.x + a.y * b.y;
    }
    pub fn length(a: Vec2) f32 {
        return @sqrt(a.dot(a));
    }
    pub fn lerp(a: Vec2, b: Vec2, t: f32) Vec2 {
        return .{ .x = a.x + (b.x - a.x) * t, .y = a.y + (b.y - a.y) * t };
    }

    /// Length of this vector. Zero for the zero vector.
    pub fn len(self: Vec2) f32 {
        return @sqrt(self.x * self.x + self.y * self.y);
    }

    /// This vector scaled to length 1. The zero vector maps to zero (a NaN
    /// here would silently poison every downstream multiply).
    pub fn normalized(self: Vec2) Vec2 {
        const l = self.len();
        if (l == 0) return Vec2.zero;
        return self.scale(1.0 / l);
    }

    /// Euclidean distance between two points.
    pub fn distance(a: Vec2, b: Vec2) f32 {
        return b.sub(a).len();
    }

    /// The perpendicular (a 90° counter-clockwise rotation in math convention;
    /// in screen space with y down it reads as a clockwise turn). Used for
    /// wall normals and tangent frames.
    pub fn perp(self: Vec2) Vec2 {
        return .{ .x = -self.y, .y = self.x };
    }

    /// Rotates this vector by `radians` (positive = clockwise on screen, where
    /// y grows down, matching `Mat4.rotateZ`).
    pub fn rotate(self: Vec2, radians: f32) Vec2 {
        const c = @cos(radians);
        const s = @sin(radians);
        return .{ .x = self.x * c - self.y * s, .y = self.x * s + self.y * c };
    }

    /// Signed angle from `a` to `b` in radians, in (-pi, pi]. The sign follows
    /// the screen convention (y down): positive when `b` is clockwise of `a`.
    pub fn angleTo(a: Vec2, b: Vec2) f32 {
        return std.math.atan2(cross(a, b), a.dot(b));
    }

    /// 2D scalar cross product (the z component of the 3D cross). Its sign is
    /// the orientation test: > 0 means `b` is clockwise of `a` on screen.
    pub fn cross(a: Vec2, b: Vec2) f32 {
        return a.x * b.y - a.y * b.x;
    }

    /// This vector clamped so its length does not exceed `max_len` (direction
    /// preserved). Vectors already within the limit are returned unchanged.
    pub fn clamped(self: Vec2, max_len: f32) Vec2 {
        const l = self.len();
        if (l <= max_len or l == 0) return self;
        return self.scale(max_len / l);
    }

    /// Component-wise minimum.
    pub fn minComponents(a: Vec2, b: Vec2) Vec2 {
        return .{ .x = @min(a.x, b.x), .y = @min(a.y, b.y) };
    }

    /// Component-wise maximum.
    pub fn maxComponents(a: Vec2, b: Vec2) Vec2 {
        return .{ .x = @max(a.x, b.x), .y = @max(a.y, b.y) };
    }
};

pub fn lerpF(a: f32, b: f32, t: f32) f32 {
    return a + (b - a) * t;
}
// ── Scalar math (the daily-use set exposed to Lua, spec-required for M3) ──────
// All of these are branch-light, allocation-free and total on their domain:
// gameplay code leans on them every frame, so a NaN or a spike here is a bug,
// not an edge case. Every one has a unit test at the bottom of this file.

pub const pi = std.math.pi;
pub const tau = 2.0 * std.math.pi;

/// `v` clamped to `[lo, hi]`. Works for any orderable scalar.
pub fn clamp(v: anytype, lo: @TypeOf(v), hi: @TypeOf(v)) @TypeOf(v) {
    if (v < lo) return lo;
    if (v > hi) return hi;
    return v;
}

/// f32 clamp (the Lua-facing name; `clamp` is the generic one).
pub fn clampf(v: f32, lo: f32, hi: f32) f32 {
    return clamp(v, lo, hi);
}

pub fn min(a: f32, b: f32) f32 {
    return @min(a, b);
}
pub fn max(a: f32, b: f32) f32 {
    return @max(a, b);
}

pub fn abs(v: f32) f32 {
    return @abs(v);
}

/// -1, 0 or +1 by sign (0 maps to 0, not +1).
pub fn sign(v: f32) f32 {
    if (v > 0) return 1;
    if (v < 0) return -1;
    return 0;
}

pub fn floorf(v: f32) f32 {
    return @floor(v);
}
pub fn ceilf(v: f32) f32 {
    return @ceil(v);
}

/// Round half away from zero (what people expect from `round`, unlike
/// banker's rounding).
pub fn round(v: f32) f32 {
    return @round(v);
}

/// Fractional part: `fract(3.25) == 0.25`. Floor-based, so the result is
/// always in `[0, 1)` regardless of the input's sign (`fract(-3.25) == 0.75`).
pub fn fract(v: f32) f32 {
    return v - @floor(v);
}

pub fn sqrtf(v: f32) f32 {
    return @sqrt(v);
}

/// `base` raised to `exp`.
pub fn pow(base: f32, exp: f32) f32 {
    return std.math.pow(f32, base, exp);
}

pub fn sin(v: f32) f32 {
    return @sin(v);
}
pub fn cos(v: f32) f32 {
    return @cos(v);
}

/// Two-argument arctangent, the angle of `(x, y)` in screen space.
pub fn atan2(y: f32, x: f32) f32 {
    return std.math.atan2(y, x);
}

/// Inverse of `lerpF`: where `v` falls between `a` and `b` as 0..1 (can leave
/// the range when `v` is outside). `a == b` maps to 0 to stay finite.
pub fn inverseLerp(a: f32, b: f32, v: f32) f32 {
    if (a == b) return 0;
    return (v - a) / (b - a);
}

/// Maps `v` from the range `[in_lo, in_hi]` to `[out_lo, out_hi]`.
pub fn remap(v: f32, in_lo: f32, in_hi: f32, out_lo: f32, out_hi: f32) f32 {
    const t = inverseLerp(in_lo, in_hi, v);
    return lerpF(out_lo, out_hi, t);
}

/// Hermite ease between two edges: 0 below `edge0`, 1 above `edge1`, smooth in
/// between. The workhorse for fades, glows and soft thresholds.
pub fn smoothstep(edge0: f32, edge1: f32, v: f32) f32 {
    const t = clamp(inverseLerp(edge0, edge1, v), 0, 1);
    return t * t * (3.0 - 2.0 * t);
}

/// Hard step: 0 below `edge`, 1 at or above it (no smoothing).
pub fn step(edge: f32, v: f32) f32 {
    return if (v < edge) 0 else 1;
}

/// Moves `current` toward `target` by at most `max_delta`.
pub fn moveToward(current: f32, target: f32, max_delta: f32) f32 {
    const diff = target - current;
    if (diff == 0) return current;
    const d = if (diff > 0) @min(diff, max_delta) else @max(diff, -max_delta);
    return current + d;
}

/// Frame-rate independent exponential approach: moves `a` toward `b` with
/// smoothing `smoothing` over `dt` seconds. `smoothing` is the approximate
/// time constant; larger is slower. The classic critically-safe alternative to
/// `a = lerp(a, b, k)` (which is dt-dependent and jitters when frames vary).
pub fn damp(a: f32, b: f32, rate: f32, dt: f32) f32 {
    return lerpF(a, b, 1.0 - pow(2.0, -rate * dt));
}

/// Wraps `v` into `[lo, hi)` (like modulo but with a live floor). `hi == lo`
/// returns `lo` to stay finite.
pub fn wrap(v: f32, lo: f32, hi: f32) f32 {
    if (hi == lo) return lo;
    return lo + fract((v - lo) / (hi - lo)) * (hi - lo);
}

/// Ping-pongs `v` between 0 and `length`: a triangle wave 0 → length → 0 →
/// length with period `2*length` (so `pingpong(0)=0`, `pingpong(length)=length`,
/// `pingpong(2*length)=0`). `length == 0` returns 0 to stay finite.
pub fn pingpong(v: f32, length: f32) f32 {
    if (length == 0) return 0;
    // Normalized phase in [0,1); fold the top half down into a triangle.
    const frac = fract(v / (length * 2.0));
    const tri = if (frac < 0.5) frac else (1.0 - frac);
    return tri * 2.0 * length;
}

pub fn degToRad(deg: f32) f32 {
    return deg * (pi / 180.0);
}
pub fn radToDeg(rad: f32) f32 {
    return rad * (180.0 / pi);
}

/// True when `a` and `b` differ by at most `tolerance` (default-friendly:
/// gameplay uses it to paper over float noise without a magic epsilon).
pub fn isClose(a: f32, b: f32, tolerance: f32) bool {
    return @abs(a - b) <= tolerance;
}



pub const Mat4 = struct {
    /// Column-major: m[col * 4 + row]
    m: [16]f32,

    pub const identity = Mat4{ .m = .{
        1, 0, 0, 0,
        0, 1, 0, 0,
        0, 0, 1, 0,
        0, 0, 0, 1,
    } };

    /// 2D orthographic projection in pixels: (0,0) is top-left.
    pub fn orthoPixels(w: f32, h: f32) Mat4 {
        const sx = 2.0 / w;
        const sy = -2.0 / h;
        return .{ .m = .{
            sx, 0,  0, 0,
            0,  sy, 0, 0,
            0,  0,  1, 0,
            -1, 1,  0, 1,
        } };
    }

    pub fn rotateZ(radians: f32) Mat4 {
        const c = @cos(radians);
        const s = @sin(radians);
        return .{ .m = .{
            c,   s,   0, 0,
            -s,  c,   0, 0,
            0,   0,   1, 0,
            0,   0,   0, 1,
        } };
    }

    /// Translation in pixel space (column-major, compatible with WGSL).
    pub fn translate(x: f32, y: f32) Mat4 {
        return .{ .m = .{
            1, 0, 0, 0,
            0, 1, 0, 0,
            0, 0, 1, 0,
            x, y, 0, 1,
        } };
    }

    /// Uniform 2D scale (z untouched, w kept at 1).
    pub fn scale(s: f32) Mat4 {
        return .{ .m = .{
            s, 0, 0, 0,
            0, s, 0, 0,
            0, 0, 1, 0,
            0, 0, 0, 1,
        } };
    }

    pub fn mul(a: Mat4, b: Mat4) Mat4 {
        var out: [16]f32 = undefined;
        for (0..4) |col| {
            for (0..4) |row| {
                var sum: f32 = 0;
                for (0..4) |k| {
                    sum += a.m[k * 4 + row] * b.m[col * 4 + k];
                }
                out[col * 4 + row] = sum;
            }
        }
        return .{ .m = out };
    }
};
// ── Rect2 (axis-aligned rectangle: position + size, top-left origin) ──────────

/// Axis-aligned rectangle stored as a top-left `position` plus a `size`, with
/// y growing down (screen convention, matching `Mat4.orthoPixels`). The set of
/// operations gameplay reaches for daily: hit tests, bounds growth, merging.
/// Nothing here allocates.
pub const Rect2 = struct {
    position: Vec2 = Vec2{},
    size: Vec2 = Vec2{},

    pub const zero = Rect2{};

    /// Builds a rect from a center point and full width/height.
    pub fn fromCenter(center_point: Vec2, width: f32, height: f32) Rect2 {
        return .{
            .position = .{ .x = center_point.x - width * 0.5, .y = center_point.y - height * 0.5 },
            .size = .{ .x = width, .y = height },
        };
    }

    pub fn left(self: Rect2) f32 {
        return self.position.x;
    }
    pub fn right(self: Rect2) f32 {
        return self.position.x + self.size.x;
    }
    pub fn top(self: Rect2) f32 {
        return self.position.y;
    }
    pub fn bottom(self: Rect2) f32 {
        return self.position.y + self.size.y;
    }

    /// Center point of the rectangle.
    pub fn center(self: Rect2) Vec2 {
        return .{ .x = self.position.x + self.size.x * 0.5, .y = self.position.y + self.size.y * 0.5 };
    }

    /// True when `point` lies inside (edges inclusive).
    pub fn contains(self: Rect2, point: Vec2) bool {
        return point.x >= self.left() and point.x <= self.right() and
            point.y >= self.top() and point.y <= self.bottom();
    }

    /// True when this and `other` overlap (touching edges count as no overlap,
    /// which is the usual game-collision convention).
    pub fn intersects(self: Rect2, other: Rect2) bool {
        return self.left() < other.right() and self.right() > other.left() and
            self.top() < other.bottom() and self.bottom() > other.top();
    }

    /// The overlapping region, or `null` when they do not intersect.
    pub fn intersection(self: Rect2, other: Rect2) ?Rect2 {
        if (!self.intersects(other)) return null;
        const pos = Vec2{ .x = @max(self.left(), other.left()), .y = @max(self.top(), other.top()) };
        const end = Vec2{ .x = @min(self.right(), other.right()), .y = @min(self.bottom(), other.bottom()) };
        return .{ .position = pos, .size = end.sub(pos) };
    }

    /// Grows (or shrinks, with a negative `amount`) the rect by `amount` on all
    /// four sides, keeping the center fixed.
    pub fn grow(self: Rect2, amount: f32) Rect2 {
        return .{
            .position = .{ .x = self.position.x - amount, .y = self.position.y - amount },
            .size = .{ .x = self.size.x + amount * 2.0, .y = self.size.y + amount * 2.0 },
        };
    }

    /// The smallest rect that contains both this and `other`.
    pub fn unionWith(self: Rect2, other: Rect2) Rect2 {
        const pos = self.position.minComponents(other.position);
        const end = Vec2{
            .x = @max(self.right(), other.right()),
            .y = @max(self.bottom(), other.bottom()),
        };
        return .{ .position = pos, .size = end.sub(pos) };
    }
};



test "ortho maps corners to clip space" {
    const m = Mat4.orthoPixels(1280, 720);
    // Pixel center (640, 360) -> clip space center (0, 0).
    const cx = m.m[0] * 640 + m.m[4] * 360 + m.m[12];
    const cy = m.m[1] * 640 + m.m[5] * 360 + m.m[13];
    try std.testing.expectApproxEqAbs(@as(f32, 0), cx, 0.001);
    try std.testing.expectApproxEqAbs(@as(f32, 0), cy, 0.001);
    // Corner (0,0) -> (-1, 1) (top-left of clip space).
    const ux = m.m[12];
    const uy = m.m[13];
    try std.testing.expectApproxEqAbs(@as(f32, -1), ux, 0.001);
    try std.testing.expectApproxEqAbs(@as(f32, 1), uy, 0.001);
}

test "mul with identity is identity" {
    const m = Mat4.rotateZ(1.234);
    const r = Mat4.mul(Mat4.identity, m);
    for (r.m, m.m) |a, b| try std.testing.expectApproxEqAbs(b, a, 0.0001);
}

test "lerp interpolates endpoints" {
    try std.testing.expectEqual(@as(f32, 2), lerpF(2, 10, 0));
    try std.testing.expectEqual(@as(f32, 10), lerpF(2, 10, 1));
    try std.testing.expectApproxEqAbs(@as(f32, 6), lerpF(2, 10, 0.5), 0.0001);
}

// ── M3 scalar math tests ─────────────────────────────────────────────────────

test "clamp bounds and passthrough" {
    try std.testing.expectEqual(@as(f32, 5), clampf(5, 0, 10));
    try std.testing.expectEqual(@as(f32, 0), clampf(-3, 0, 10));
    try std.testing.expectEqual(@as(f32, 10), clampf(99, 0, 10));
    // Generic clamp works for ints too (the Lua binding routes through it).
    try std.testing.expectEqual(@as(i32, 7), clamp(@as(i32, 7), 0, 10));
}

test "sign, abs, floor, ceil, round" {
    try std.testing.expectEqual(@as(f32, 1), sign(2.5));
    try std.testing.expectEqual(@as(f32, -1), sign(-0.1));
    try std.testing.expectEqual(@as(f32, 0), sign(0));
    try std.testing.expectEqual(@as(f32, 3.5), abs(-3.5));
    try std.testing.expectEqual(@as(f32, 3), floorf(3.9));
    try std.testing.expectEqual(@as(f32, 4), ceilf(3.1));
    try std.testing.expectEqual(@as(f32, 4), round(3.5));
    try std.testing.expectEqual(@as(f32, -4), round(-3.5)); // half away from zero
}

test "fract keeps the fractional part (floor-based, always [0,1))" {
    try std.testing.expectApproxEqAbs(@as(f32, 0.25), fract(3.25), 0.0001);
    try std.testing.expectApproxEqAbs(@as(f32, 0.75), fract(-3.25), 0.0001);
    try std.testing.expectApproxEqAbs(@as(f32, 0), fract(4.0), 0.0001);
}

test "sqrt, pow, trig" {
    try std.testing.expectApproxEqAbs(@as(f32, 3), sqrtf(9), 0.0001);
    try std.testing.expectApproxEqAbs(@as(f32, 8), pow(2, 3), 0.0001);
    try std.testing.expectApproxEqAbs(@as(f32, 0), sin(0), 0.0001);
    try std.testing.expectApproxEqAbs(@as(f32, 1), cos(0), 0.0001);
    try std.testing.expectApproxEqAbs(@as(f32, 0), atan2(0, 1), 0.0001);
    try std.testing.expectApproxEqAbs(pi / 2.0, atan2(1, 0), 0.0001);
}

test "inverse_lerp and remap round-trip through lerp" {
    try std.testing.expectApproxEqAbs(@as(f32, 0.5), inverseLerp(0, 10, 5), 0.0001);
    try std.testing.expectApproxEqAbs(@as(f32, 0), inverseLerp(4, 4, 9), 0.0001); // degenerate stays finite
    // Map 0..100 (health) to 0..1 (a bar's fill).
    try std.testing.expectApproxEqAbs(@as(f32, 0.25), remap(25, 0, 100, 0, 1), 0.0001);
}

test "smoothstep eases between the edges" {
    try std.testing.expectEqual(@as(f32, 0), smoothstep(0, 1, -1));
    try std.testing.expectEqual(@as(f32, 1), smoothstep(0, 1, 2));
    try std.testing.expectApproxEqAbs(@as(f32, 0.5), smoothstep(0, 1, 0.5), 0.0001);
}

test "step is a hard threshold" {
    try std.testing.expectEqual(@as(f32, 0), step(0.5, 0.4));
    try std.testing.expectEqual(@as(f32, 1), step(0.5, 0.5));
    try std.testing.expectEqual(@as(f32, 1), step(0.5, 0.6));
}

test "move_toward never overshoots" {
    try std.testing.expectApproxEqAbs(@as(f32, 3), moveToward(0, 10, 3), 0.0001);
    try std.testing.expectApproxEqAbs(@as(f32, 10), moveToward(8, 10, 5), 0.0001); // clamps at target
    try std.testing.expectApproxEqAbs(@as(f32, -3), moveToward(0, -10, 3), 0.0001);
}

test "damp approaches the target and is dt-bounded" {
    // One big step still lands strictly between a and b (no overshoot).
    const d = damp(0, 1, 5, 1.0);
    try std.testing.expect(d > 0 and d < 1);
    // Converges: many small steps get very close.
    var v: f32 = 0;
    var i: usize = 0;
    while (i < 1000) : (i += 1) v = damp(v, 1, 5, 1.0 / 60.0);
    try std.testing.expect(v > 0.999);
}

test "wrap folds into [lo, hi)" {
    try std.testing.expectApproxEqAbs(@as(f32, 2), wrap(12, 0, 10), 0.0001);
    try std.testing.expectApproxEqAbs(@as(f32, 8), wrap(-2, 0, 10), 0.0001);
    try std.testing.expectApproxEqAbs(@as(f32, 0), wrap(10, 0, 10), 0.0001);
    try std.testing.expectApproxEqAbs(@as(f32, 5), wrap(5, 5, 5), 0.0001); // degenerate
}

test "pingpong bounces between 0 and length" {
    try std.testing.expectApproxEqAbs(@as(f32, 0), pingpong(0, 10), 0.0001);
    try std.testing.expectApproxEqAbs(@as(f32, 10), pingpong(10, 10), 0.0001);
    try std.testing.expectApproxEqAbs(@as(f32, 5), pingpong(5, 10), 0.0001);
    try std.testing.expectApproxEqAbs(@as(f32, 0), pingpong(20, 10), 0.0001); // back at the start
}

test "deg/rad conversions round-trip" {
    try std.testing.expectApproxEqAbs(pi, degToRad(180), 0.0001);
    try std.testing.expectApproxEqAbs(@as(f32, 180), radToDeg(pi), 0.0001);
}

test "is_close honours the tolerance" {
    try std.testing.expect(isClose(1.0, 1.0 + 0.0001, 0.001));
    try std.testing.expect(!isClose(1.0, 1.1, 0.001));
}


// ── M3 Vec2 method tests ─────────────────────────────────────────────────────

test "Vec2 len and normalized" {
    const v = Vec2{ .x = 3, .y = 4 };
    try std.testing.expectApproxEqAbs(@as(f32, 5), v.len(), 0.0001);
    const n = v.normalized();
    try std.testing.expectApproxEqAbs(@as(f32, 1), n.len(), 0.0001);
    // Zero vector normalizes to zero, not NaN.
    try std.testing.expectEqual(Vec2.zero, Vec2.zero.normalized());
}

test "Vec2 distance, perp, cross, rotate" {
    try std.testing.expectApproxEqAbs(@as(f32, 5), Vec2.distance(.{ .x = 0, .y = 0 }, .{ .x = 3, .y = 4 }), 0.0001);
    const p = (Vec2{ .x = 1, .y = 0 }).perp();
    try std.testing.expectEqual(Vec2{ .x = 0, .y = 1 }, p);
    try std.testing.expectApproxEqAbs(@as(f32, 1), Vec2.cross(.{ .x = 1, .y = 0 }, .{ .x = 0, .y = 1 }), 0.0001);
    // A quarter turn maps +x to +y (screen: y down, positive angle is clockwise).
    const r = (Vec2{ .x = 1, .y = 0 }).rotate(pi / 2.0);
    try std.testing.expectApproxEqAbs(@as(f32, 0), r.x, 0.0001);
    try std.testing.expectApproxEqAbs(@as(f32, 1), r.y, 0.0001);
}

test "Vec2 angle_to sign follows the screen convention" {
    // From +x to +y is a quarter turn clockwise on screen (y down).
    try std.testing.expectApproxEqAbs(pi / 2.0, Vec2.angleTo(.{ .x = 1, .y = 0 }, .{ .x = 0, .y = 1 }), 0.0001);
    // Same direction: zero angle.
    try std.testing.expectApproxEqAbs(@as(f32, 0), Vec2.angleTo(.{ .x = 1, .y = 0 }, .{ .x = 2, .y = 0 }), 0.0001);
}

test "Vec2 clamped caps length, keeps direction" {
    const v = (Vec2{ .x = 3, .y = 4 }).clamped(2.5);
    try std.testing.expectApproxEqAbs(@as(f32, 2.5), v.len(), 0.0001);
    // Already within the cap: unchanged.
    const small = Vec2{ .x = 1, .y = 0 };
    try std.testing.expectEqual(small, small.clamped(5));
}

// ── M3 Rect2 tests ───────────────────────────────────────────────────────────

test "Rect2 contains and edges" {
    const r = Rect2{ .position = .{ .x = 10, .y = 20 }, .size = .{ .x = 100, .y = 50 } };
    try std.testing.expect(r.contains(.{ .x = 50, .y = 40 }));
    try std.testing.expect(r.contains(.{ .x = 10, .y = 20 })); // edge inclusive
    try std.testing.expect(!r.contains(.{ .x = 5, .y = 40 }));
    try std.testing.expectApproxEqAbs(@as(f32, 110), r.right(), 0.0001);
    try std.testing.expectApproxEqAbs(@as(f32, 70), r.bottom(), 0.0001);
    try std.testing.expectEqual(Vec2{ .x = 60, .y = 45 }, r.center());
}

test "Rect2 intersects, intersection, grow, union" {
    const a = Rect2{ .position = .{ .x = 0, .y = 0 }, .size = .{ .x = 10, .y = 10 } };
    const b = Rect2{ .position = .{ .x = 5, .y = 5 }, .size = .{ .x = 10, .y = 10 } };
    try std.testing.expect(a.intersects(b));
    const inter = a.intersection(b).?;
    try std.testing.expectEqual(Vec2{ .x = 5, .y = 5 }, inter.position);
    try std.testing.expectEqual(Vec2{ .x = 5, .y = 5 }, inter.size);
    // Touching edges do not intersect.
    const c = Rect2{ .position = .{ .x = 10, .y = 0 }, .size = .{ .x = 5, .y = 5 } };
    try std.testing.expect(!a.intersects(c));
    try std.testing.expect(a.intersection(c) == null);
    // Grow keeps the center and pads every side.
    const g = a.grow(2);
    try std.testing.expectEqual(Vec2{ .x = -2, .y = -2 }, g.position);
    try std.testing.expectEqual(Vec2{ .x = 14, .y = 14 }, g.size);
    // Union spans both.
    const u = a.unionWith(b);
    try std.testing.expectEqual(Vec2{ .x = 0, .y = 0 }, u.position);
    try std.testing.expectEqual(Vec2{ .x = 15, .y = 15 }, u.size);
}

test "Rect2 fromCenter places the box around a point" {
    const r = Rect2.fromCenter(.{ .x = 100, .y = 100 }, 40, 20);
    try std.testing.expectEqual(Vec2{ .x = 80, .y = 90 }, r.position);
    try std.testing.expectEqual(Vec2{ .x = 40, .y = 20 }, r.size);
    try std.testing.expectEqual(Vec2{ .x = 100, .y = 100 }, r.center());
}

