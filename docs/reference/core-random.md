# Core Random

**Source:** `src/engine/core/random.zig`

Deterministic pseudo-random numbers. The engine's determinism contract says two runs with the same inputs must end in the same state hash. That makes the *algorithm* part of the format: if the PRNG ever changes, replays and recorded bugs stop reproducing. So the algorithm is pinned here — PCG (Melissa O'Neill 2014) — and the state is two plain integers that serialize byte-exact like every other component field.

The engine's own subsystems MUST draw from this (or from `noise`), never from `std.crypto.random`, or determinism dies silently.

---

## Rng

A seeded, serializable PRNG. Two `Rng` values with the same state produce the same sequence forever, on every platform and every target (the Web build included): every operation is integer or IEEE-754 arithmetic.

```zig
pub const Rng = struct {
    state: u64,       // PCG's 64-bit LCG state
    inc: u64,         // PCG's odd stream selector
    // ...
};
```

### Constants

| Name | Value | Description |
|------|-------|-------------|
| `Rng.default_seed` | `0x853c49e6748fea9b` | Default seed value. |

### Static Methods

#### `init`

```zig
pub fn init(seed: u64) Rng
```

**Parameters:** `seed` — the seed value.
**Returns:** A seeded `Rng`. The seed is expanded through a splitmix64 step first, so that small and sequential seeds (0, 1, 2, …) do not produce visibly correlated first draws — the classic weakness of a raw-LCG PCG. Two warm-up steps leave the correlated start state.

```zig
var rng = Rng.init(12345);
```

### Instance Methods

#### `randomState`

```zig
pub fn randomState(self: *const Rng) struct { u64, u64 }
```

**Returns:** The state pair `{state, inc}`, for the serializer.

```zig
const saved = rng.randomState();
```

#### `setState`

```zig
pub fn setState(self: *Rng, state: u64, inc: u64) void
```

**Parameters:** `state` — the LCG state; `inc` — the stream selector.
**Returns:** Nothing. Restores a state pair produced by `randomState`. Used by save/load and by rollback, which is why it is part of the public surface.

```zig
rng.setState(saved[0], saved[1]);
```

#### `nextU64`

```zig
pub fn nextU64(self: *Rng) u64
```

**Returns:** 64 random bits: two 32-bit draws, low half first.

```zig
const bits = rng.nextU64();
```

#### `nextFloat`

```zig
pub fn nextFloat(self: *Rng) f32
```

**Returns:** A uniform float in `[0, 1)`. The 24-bit mantissa is filled directly instead of computing `u32 / 2^32`: that keeps every representable float reachable, whereas the division rounds the top of the range down and biases the first bucket.

```zig
const f = rng.nextFloat(); // 0.0 <= f < 1.0
```

#### `float`

```zig
pub fn float(self: *Rng, lo: f32, hi: f32) f32
```

**Parameters:** `lo` — lower bound (inclusive); `hi` — upper bound (exclusive).
**Returns:** A uniform float in `[lo, hi)`.

```zig
const damage = rng.float(10.0, 20.0);
```

#### `int`

```zig
pub fn int(self: *Rng, lo: i32, hi: i32) i32
```

**Parameters:** `lo` — lower bound (inclusive); `hi` — upper bound (inclusive).
**Returns:** A uniform integer in `[lo, hi]`, both ends inclusive. Uses Lemire's multiply-shift with rejection, so the result is exactly uniform: the naive `lo + u32 % span` is measurably biased whenever `span` does not divide 2^32, which for small ranges (a 6-sided die) is most of them.

```zig
const roll = rng.int(1, 6); // a fair die
```

#### `chance`

```zig
pub fn chance(self: *Rng, p: f32) bool
```

**Parameters:** `p` — probability in `[0, 1]`.
**Returns:** True with probability `p`. `p <= 0` never fires, `p >= 1` always does — the clamp keeps a misconfigured weight from silently inverting.

```zig
if (rng.chance(0.3)) {
    // 30% chance
}
```

#### `sign`

```zig
pub fn sign(self: *Rng) f32
```

**Returns:** -1 or +1, 50/50. Useful for a coin flip without touching `int`.

```zig
const direction = rng.sign(); // -1.0 or 1.0
```

#### `gauss`

```zig
pub fn gauss(self: *Rng, mu: f32, sigma: f32) f32
```

**Parameters:** `mu` — mean; `sigma` — standard deviation.
**Returns:** A normal-distributed sample (Box-Muller, polar form). The `log(0)` edge is handled by resampling rather than by clamping: a clamped draw would put a spike at 0.0 in the distribution, and this is the generator people use for spread, where that spike shows up.

```zig
const spread = rng.gauss(0.0, 2.0);
```

#### `choiceIndex`

```zig
pub fn choiceIndex(self: *Rng, len: usize) ?usize
```

**Parameters:** `len` — the length of the sequence.
**Returns:** A random index in `[0, len)`, or `null` on an empty sequence, so the binding can push nil instead of guessing.

```zig
if (rng.choiceIndex(items.len)) |idx| {
    const item = items[idx];
}
```
