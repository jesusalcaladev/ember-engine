# Core Math

**Source:** `src/engine/core/math.zig`

Minimal 2D math for the engine: `Vec2`, `Mat4`, `Rect2`, and a daily-use set of scalar math functions. Column-major matrices (compatible with WGSL `mat4x4<f32>`). Nothing here allocates memory.

All functions are branch-light, allocation-free, and total on their domain — gameplay code leans on them every frame, so a NaN or a spike here is a bug, not an edge case.

---

## Vec2

A 2D vector with `x` and `y` components (both `f32`, defaulting to `0`).

```zig
pub const Vec2 = struct {
    x: f32 = 0,
    y: f32 = 0,
    // ...
};
```

### Constants

| Name | Value | Description |
|------|-------|-------------|
| `Vec2.zero` | `.{ .x = 0, .y = 0 }` | The zero vector. |

### Static Methods

#### `add`

```zig
pub fn add(a: Vec2, b: Vec2) Vec2
```

**Parameters:** `a`, `b` — two vectors.
**Returns:** Component-wise sum `a + b`.

```zig
const result = Vec2.add(.{ .x = 1, .y = 2 }, .{ .x = 3, .y = 4 });
// result = .{ .x = 4, .y = 6 }
```

#### `sub`

```zig
pub fn sub(a: Vec2, b: Vec2) Vec2
```

**Parameters:** `a`, `b` — two vectors.
**Returns:** Component-wise difference `a - b`.

```zig
const result = Vec2.sub(.{ .x = 5, .y = 7 }, .{ .x = 2, .y = 3 });
// result = .{ .x = 3, .y = 4 }
```

#### `scale`

```zig
pub fn scale(a: Vec2, s: f32) Vec2
```

**Parameters:** `a` — the vector; `s` — the scalar multiplier.
**Returns:** The vector multiplied component-wise by `s`.

```zig
const result = Vec2.scale(.{ .x = 3, .y = 4 }, 2.0);
// result = .{ .x = 6, .y = 8 }
```

#### `dot`

```zig
pub fn dot(a: Vec2, b: Vec2) f32
```

**Parameters:** `a`, `b` — two vectors.
**Returns:** The dot product `a.x*b.x + a.y*b.y`.

```zig
const d = Vec2.dot(.{ .x = 1, .y = 0 }, .{ .x = 0, .y = 1 });
// d = 0.0 (perpendicular vectors)
```

#### `length`

```zig
pub fn length(a: Vec2) f32
```

**Parameters:** `a` — the vector.
**Returns:** Euclidean length `sqrt(a.x² + a.y²)`.

```zig
const l = Vec2.length(.{ .x = 3, .y = 4 });
// l = 5.0
```

#### `lerp`

```zig
pub fn lerp(a: Vec2, b: Vec2, t: f32) Vec2
```

**Parameters:** `a` — start vector; `b` — end vector; `t` — interpolation factor (0 = a, 1 = b).
**Returns:** Linear interpolation between `a` and `b`.

```zig
const mid = Vec2.lerp(.{ .x = 0, .y = 0 }, .{ .x = 10, .y = 20 }, 0.5);
// mid = .{ .x = 5, .y = 10 }
```

### Instance Methods

#### `len`

```zig
pub fn len(self: Vec2) f32
```

**Returns:** Length of this vector. Zero for the zero vector.

```zig
const v = Vec2{ .x = 3, .y = 4 };
const l = v.len(); // 5.0
```

#### `normalized`

```zig
pub fn normalized(self: Vec2) Vec2
```

**Returns:** This vector scaled to length 1. The zero vector maps to zero (a NaN here would silently poison every downstream multiply).

```zig
const n = (Vec2{ .x = 3, .y = 4 }).normalized();
// n ≈ .{ .x = 0.6, .y = 0.8 }
```

#### `distance`

```zig
pub fn distance(a: Vec2, b: Vec2) f32
```

**Parameters:** `a`, `b` — two points.
**Returns:** Euclidean distance between them.

```zig
const d = Vec2.distance(.{ .x = 0, .y = 0 }, .{ .x = 3, .y = 4 });
// d = 5.0
```

#### `perp`

```zig
pub fn perp(self: Vec2) Vec2
```

**Returns:** The perpendicular (a 90° counter-clockwise rotation in math convention; in screen space with y down it reads as a clockwise turn). Used for wall normals and tangent frames.

```zig
const p = (Vec2{ .x = 1, .y = 0 }).perp();
// p = .{ .x = 0, .y = 1 }
```

#### `rotate`

```zig
pub fn rotate(self: Vec2, radians: f32) Vec2
```

**Parameters:** `radians` — angle to rotate (positive = clockwise on screen, where y grows down, matching `Mat4.rotateZ`).
**Returns:** The rotated vector.

```zig
const r = (Vec2{ .x = 1, .y = 0 }).rotate(std.math.pi / 2.0);
// r ≈ .{ .x = 0, .y = 1 }
```

#### `angleTo`

```zig
pub fn angleTo(a: Vec2, b: Vec2) f32
```

**Parameters:** `a` — the reference vector; `b` — the target vector.
**Returns:** Signed angle from `a` to `b` in radians, in `(-pi, pi]`. The sign follows the screen convention (y down): positive when `b` is clockwise of `a`.

```zig
const angle = Vec2.angleTo(.{ .x = 1, .y = 0 }, .{ .x = 0, .y = 1 });
// angle ≈ pi / 2.0 (quarter turn clockwise on screen)
```

#### `cross`

```zig
pub fn cross(a: Vec2, b: Vec2) f32
```

**Parameters:** `a`, `b` — two vectors.
**Returns:** 2D scalar cross product (the z component of the 3D cross). Its sign is the orientation test: > 0 means `b` is clockwise of `a` on screen.

```zig
const c = Vec2.cross(.{ .x = 1, .y = 0 }, .{ .x = 0, .y = 1 });
// c = 1.0
```

#### `clamped`

```zig
pub fn clamped(self: Vec2, max_len: f32) Vec2
```

**Parameters:** `max_len` — maximum allowed length.
**Returns:** This vector clamped so its length does not exceed `max_len` (direction preserved). Vectors already within the limit are returned unchanged.

```zig
const v = (Vec2{ .x = 3, .y = 4 }).clamped(2.5);
// v.len() = 2.5, direction unchanged
```

#### `minComponents`

```zig
pub fn minComponents(a: Vec2, b: Vec2) Vec2
```

**Parameters:** `a`, `b` — two vectors.
**Returns:** Component-wise minimum.

```zig
const m = Vec2.minComponents(.{ .x = 3, .y = 8 }, .{ .x = 5, .y = 2 });
// m = .{ .x = 3, .y = 2 }
```

#### `maxComponents`

```zig
pub fn maxComponents(a: Vec2, b: Vec2) Vec2
```

**Parameters:** `a`, `b` — two vectors.
**Returns:** Component-wise maximum.

```zig
const m = Vec2.maxComponents(.{ .x = 3, .y = 8 }, .{ .x = 5, .y = 2 });
// m = .{ .x = 5, .y = 8 }
```

---

## Scalar Math

### Constants

| Name | Value | Description |
|------|-------|-------------|
| `pi` | `std.math.pi` | π ≈ 3.14159… |
| `tau` | `2.0 * pi` | τ = 2π ≈ 6.28318… |

### `lerpF`

```zig
pub fn lerpF(a: f32, b: f32, t: f32) f32
```

**Parameters:** `a` — start value; `b` — end value; `t` — interpolation factor.
**Returns:** Linear interpolation `a + (b - a) * t`.

```zig
const v = lerpF(2.0, 10.0, 0.5); // 6.0
```

### `clamp`

```zig
pub fn clamp(v: anytype, lo: @TypeOf(v), hi: @TypeOf(v)) @TypeOf(v)
```

**Parameters:** `v` — the value; `lo` — lower bound; `hi` — upper bound.
**Returns:** `v` clamped to `[lo, hi]`. Works for any orderable scalar.

```zig
const c = clamp(@as(i32, 15), 0, 10); // 10
```

### `clampf`

```zig
pub fn clampf(v: f32, lo: f32, hi: f32) f32
```

**Parameters:** `v` — the value; `lo` — lower bound; `hi` — upper bound.
**Returns:** `v` clamped to `[lo, hi]`. The Lua-facing name; `clamp` is the generic one.

```zig
const c = clampf(-3.0, 0.0, 10.0); // 0.0
```

### `min` / `max`

```zig
pub fn min(a: f32, b: f32) f32
pub fn max(a: f32, b: f32) f32
```

**Returns:** The smaller / larger of the two values.

```zig
const lo = min(3.0, 7.0); // 3.0
const hi = max(3.0, 7.0); // 7.0
```

### `abs`

```zig
pub fn abs(v: f32) f32
```

**Returns:** Absolute value of `v`.

```zig
const a = abs(-3.5); // 3.5
```

### `sign`

```zig
pub fn sign(v: f32) f32
```

**Returns:** -1, 0, or +1 by sign (0 maps to 0, not +1).

```zig
const s = sign(-0.1); // -1.0
```

### `floorf` / `ceilf`

```zig
pub fn floorf(v: f32) f32
pub fn ceilf(v: f32) f32
```

**Returns:** Floor / ceiling of `v`.

```zig
const f = floorf(3.9); // 3.0
const c = ceilf(3.1);  // 4.0
```

### `round`

```zig
pub fn round(v: f32) f32
```

**Returns:** `v` rounded half away from zero (what people expect from `round`, unlike banker's rounding).

```zig
const r = round(3.5);  // 4.0
const r2 = round(-3.5); // -4.0
```

### `fract`

```zig
pub fn fract(v: f32) f32
```

**Returns:** Fractional part: `fract(3.25) == 0.25`. Floor-based, so the result is always in `[0, 1)` regardless of the input's sign (`fract(-3.25) == 0.75`).

```zig
const f = fract(3.25); // 0.25
```

### `sqrtf`

```zig
pub fn sqrtf(v: f32) f32
```

**Returns:** Square root of `v`.

```zig
const s = sqrtf(9.0); // 3.0
```

### `pow`

```zig
pub fn pow(base: f32, exp: f32) f32
```

**Returns:** `base` raised to `exp`.

```zig
const p = pow(2.0, 3.0); // 8.0
```

### `sin` / `cos`

```zig
pub fn sin(v: f32) f32
pub fn cos(v: f32) f32
```

**Returns:** Sine / cosine of `v` (radians).

```zig
const s = sin(0.0); // 0.0
const c = cos(0.0); // 1.0
```

### `atan2`

```zig
pub fn atan2(y: f32, x: f32) f32
```

**Returns:** Two-argument arctangent, the angle of `(x, y)` in screen space.

```zig
const a = atan2(1.0, 0.0); // pi / 2.0
```

### `inverseLerp`

```zig
pub fn inverseLerp(a: f32, b: f32, v: f32) f32
```

**Parameters:** `a` — range start; `b` — range end; `v` — the value.
**Returns:** Where `v` falls between `a` and `b` as 0..1 (can leave the range when `v` is outside). `a == b` maps to 0 to stay finite.

```zig
const t = inverseLerp(0.0, 10.0, 5.0); // 0.5
```

### `remap`

```zig
pub fn remap(v: f32, in_lo: f32, in_hi: f32, out_lo: f32, out_hi: f32) f32
```

**Parameters:** `v` — the value; `in_lo`, `in_hi` — input range; `out_lo`, `out_hi` — output range.
**Returns:** `v` mapped from `[in_lo, in_hi]` to `[out_lo, out_hi]`.

```zig
const bar = remap(25.0, 0.0, 100.0, 0.0, 1.0); // 0.25
```

### `smoothstep`

```zig
pub fn smoothstep(edge0: f32, edge1: f32, v: f32) f32
```

**Parameters:** `edge0` — lower edge; `edge1` — upper edge; `v` — the value.
**Returns:** Hermite ease between two edges: 0 below `edge0`, 1 above `edge1`, smooth in between. The workhorse for fades, glows and soft thresholds.

```zig
const s = smoothstep(0.0, 1.0, 0.5); // 0.5
```

### `step`

```zig
pub fn step(edge: f32, v: f32) f32
```

**Parameters:** `edge` — the threshold; `v` — the value.
**Returns:** Hard step: 0 below `edge`, 1 at or above it (no smoothing).

```zig
const s = step(0.5, 0.4); // 0.0
const s2 = step(0.5, 0.5); // 1.0
```

### `moveToward`

```zig
pub fn moveToward(current: f32, target: f32, max_delta: f32) f32
```

**Parameters:** `current` — starting value; `target` — goal; `max_delta` — maximum step size.
**Returns:** `current` moved toward `target` by at most `max_delta`. Never overshoots.

```zig
const v = moveToward(0.0, 10.0, 3.0); // 3.0
const v2 = moveToward(8.0, 10.0, 5.0); // 10.0 (clamps at target)
```

### `damp`

```zig
pub fn damp(a: f32, b: f32, rate: f32, dt: f32) f32
```

**Parameters:** `a` — current value; `b` — target; `rate` — approximate time constant (larger = slower); `dt` — elapsed seconds.
**Returns:** Frame-rate independent exponential approach: moves `a` toward `b` with smoothing `rate` over `dt` seconds. The classic critically-safe alternative to `a = lerp(a, b, k)` (which is dt-dependent and jitters when frames vary).

```zig
const v = damp(0.0, 1.0, 5.0, 1.0 / 60.0);
```

### `wrap`

```zig
pub fn wrap(v: f32, lo: f32, hi: f32) f32
```

**Parameters:** `v` — the value; `lo` — range start (inclusive); `hi` — range end (exclusive).
**Returns:** `v` wrapped into `[lo, hi)` (like modulo but with a live floor). `hi == lo` returns `lo` to stay finite.

```zig
const w = wrap(12.0, 0.0, 10.0); // 2.0
const w2 = wrap(-2.0, 0.0, 10.0); // 8.0
```

### `pingpong`

```zig
pub fn pingpong(v: f32, length: f32) f32
```

**Parameters:** `v` — the value; `length` — the ping-pong extent.
**Returns:** Ping-pongs `v` between 0 and `length`: a triangle wave 0 → length → 0 → length with period `2*length`. `length == 0` returns 0 to stay finite.

```zig
const p = pingpong(5.0, 10.0);  // 5.0
const p2 = pingpong(10.0, 10.0); // 10.0
const p3 = pingpong(20.0, 10.0); // 0.0 (back at the start)
```

### `degToRad` / `radToDeg`

```zig
pub fn degToRad(deg: f32) f32
pub fn radToDeg(rad: f32) f32
```

**Returns:** Degrees → radians / radians → degrees.

```zig
const r = degToRad(180.0); // pi
const d = radToDeg(pi);    // 180.0
```

### `isClose`

```zig
pub fn isClose(a: f32, b: f32, tolerance: f32) bool
```

**Parameters:** `a`, `b` — values to compare; `tolerance` — maximum allowed difference.
**Returns:** True when `a` and `b` differ by at most `tolerance`. Gameplay uses it to paper over float noise without a magic epsilon.

```zig
const ok = isClose(1.0, 1.0 + 0.0001, 0.001); // true
```

---

## Mat4

A 4×4 matrix stored column-major (`m[col * 4 + row]`), compatible with WGSL `mat4x4<f32>`.

```zig
pub const Mat4 = struct {
    m: [16]f32,
    // ...
};
```

### Constants

| Name | Value | Description |
|------|-------|-------------|
| `Mat4.identity` | Identity matrix | The 4×4 identity. |

### Static Methods

#### `orthoPixels`

```zig
pub fn orthoPixels(w: f32, h: f32) Mat4
```

**Parameters:** `w` — viewport width in pixels; `h` — viewport height in pixels.
**Returns:** 2D orthographic projection in pixels: (0,0) is top-left.

```zig
const proj = Mat4.orthoPixels(1280, 720);
// Pixel (640, 360) → clip space (0, 0)
// Pixel (0, 0)     → clip space (-1, 1)
```

#### `rotateZ`

```zig
pub fn rotateZ(radians: f32) Mat4
```

**Parameters:** `radians` — rotation angle (positive = clockwise on screen).
**Returns:** A 2D rotation matrix around the Z axis.

```zig
const rot = Mat4.rotateZ(std.math.pi / 2.0);
```

#### `translate`

```zig
pub fn translate(x: f32, y: f32) Mat4
```

**Parameters:** `x`, `y` — translation in pixel space.
**Returns:** A 2D translation matrix (column-major, compatible with WGSL).

```zig
const t = Mat4.translate(100.0, 50.0);
```

#### `scale`

```zig
pub fn scale(s: f32) Mat4
```

**Parameters:** `s` — uniform scale factor.
**Returns:** A uniform 2D scale matrix (z untouched, w kept at 1).

```zig
const sc = Mat4.scale(2.0);
```

#### `mul`

```zig
pub fn mul(a: Mat4, b: Mat4) Mat4
```

**Parameters:** `a`, `b` — matrices to multiply.
**Returns:** The matrix product `a * b`.

```zig
const m = Mat4.mul(Mat4.translate(10, 20), Mat4.scale(2.0));
```

---

## Rect2

An axis-aligned rectangle stored as a top-left `position` plus a `size`, with y growing down (screen convention, matching `Mat4.orthoPixels`). The set of operations gameplay reaches for daily: hit tests, bounds growth, merging. Nothing here allocates.

```zig
pub const Rect2 = struct {
    position: Vec2 = Vec2{},
    size: Vec2 = Vec2{},
    // ...
};
```

### Constants

| Name | Value | Description |
|------|-------|-------------|
| `Rect2.zero` | `.{ .position = .{}, .size = .{} }` | A zero-size rect at the origin. |

### Static Methods

#### `fromCenter`

```zig
pub fn fromCenter(center_point: Vec2, width: f32, height: f32) Rect2
```

**Parameters:** `center_point` — the center of the rect; `width`, `height` — full width and height.
**Returns:** A rect centered on `center_point` with the given dimensions.

```zig
const r = Rect2.fromCenter(.{ .x = 100, .y = 100 }, 40, 20);
// r.position = .{ .x = 80, .y = 90 }
// r.size = .{ .x = 40, .y = 20 }
```

### Instance Methods

#### `left` / `right` / `top` / `bottom`

```zig
pub fn left(self: Rect2) f32
pub fn right(self: Rect2) f32
pub fn top(self: Rect2) f32
pub fn bottom(self: Rect2) f32
```

**Returns:** The corresponding edge coordinate.

```zig
const r = Rect2{ .position = .{ .x = 10, .y = 20 }, .size = .{ .x = 100, .y = 50 } };
// r.left() = 10, r.right() = 110, r.top() = 20, r.bottom() = 70
```

#### `center`

```zig
pub fn center(self: Rect2) Vec2
```

**Returns:** Center point of the rectangle.

```zig
const c = r.center(); // .{ .x = 60, .y = 45 }
```

#### `contains`

```zig
pub fn contains(self: Rect2, point: Vec2) bool
```

**Parameters:** `point` — the point to test.
**Returns:** True when `point` lies inside (edges inclusive).

```zig
const inside = r.contains(.{ .x = 50, .y = 40 }); // true
```

#### `intersects`

```zig
pub fn intersects(self: Rect2, other: Rect2) bool
```

**Parameters:** `other` — the other rectangle.
**Returns:** True when this and `other` overlap (touching edges count as no overlap, which is the usual game-collision convention).

```zig
const a = Rect2{ .position = .{ .x = 0, .y = 0 }, .size = .{ .x = 10, .y = 10 } };
const b = Rect2{ .position = .{ .x = 5, .y = 5 }, .size = .{ .x = 10, .y = 10 } };
const hit = a.intersects(b); // true
```

#### `intersection`

```zig
pub fn intersection(self: Rect2, other: Rect2) ?Rect2
```

**Parameters:** `other` — the other rectangle.
**Returns:** The overlapping region, or `null` when they do not intersect.

```zig
const inter = a.intersection(b).?;
// inter.position = .{ .x = 5, .y = 5 }, inter.size = .{ .x = 5, .y = 5 }
```

#### `grow`

```zig
pub fn grow(self: Rect2, amount: f32) Rect2
```

**Parameters:** `amount` — pixels to add on each side (negative shrinks).
**Returns:** The rect grown (or shrunk) by `amount` on all four sides, keeping the center fixed.

```zig
const g = a.grow(2.0);
// g.position = .{ .x = -2, .y = -2 }, g.size = .{ .x = 14, .y = 14 }
```

#### `unionWith`

```zig
pub fn unionWith(self: Rect2, other: Rect2) Rect2
```

**Parameters:** `other` — the other rectangle.
**Returns:** The smallest rect that contains both this and `other`.

```zig
const u = a.unionWith(b);
// u.position = .{ .x = 0, .y = 0 }, u.size = .{ .x = 15, .y = 15 }
```
