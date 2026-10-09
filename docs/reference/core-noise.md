# Core Noise

**Source:** `src/engine/core/noise.zig`

Deterministic procedural noise. Same contract as `random.zig`: the output is a pure function of `(seed, x, y)`, so a level generated on a replay regenerates identically. Nothing here allocates and nothing here touches global state — the seed is passed in, which is what lets two subsystems use different noise fields (terrain height vs. cloud drift) without interfering.

Three bases are provided because games need different things from noise:

- **value** — cheap, blocky when sampled far apart. Fine for terrain height.
- **perlin** — the classic gradient noise; smooth, no directional artefacts. The workhorse for procedural terrain.
- **simplex** — a triangular lattice with no axis-aligned bias, which is why it is the one to reach for when the noise is sampled along circles or used for isotropic warp (clouds, flow fields, wandering animals).

`fbm` and `ridged` compose a base into something with structure at several scales, which is almost always what a game wants rather than one octave.

---

## Constants

| Name | Value | Description |
|------|-------|-------------|
| `max_octaves` | `12` | Largest octave count any caller may request. Bounds the cost of `fbm` from a Lua script: without a cap, `fbm(x, y, 200)` is a frame-long stall. |

---

## Noise Functions

### `value`

```zig
pub fn value(seed: u64, x: f32, y: f32) f32
```

**Parameters:** `seed` — the noise seed; `x`, `y` — sample coordinates.
**Returns:** 2D value noise in `[-1, 1]`. Smooth, but with a faint square lattice when sampled sparsely — see the module header for when to pick simplex instead.

```zig
const n = value(42, 3.5, 2.5); // -1.0 <= n <= 1.0
```

### `perlin`

```zig
pub fn perlin(seed: u64, x: f32, y: f32) f32
```

**Parameters:** `seed` — the noise seed; `x`, `y` — sample coordinates.
**Returns:** 2D gradient (Perlin) noise in `[-1, 1]`. No lattice artefacts, which is why it is the default for terrain.

```zig
const n = perlin(42, 3.5, 2.5); // -1.0 <= n <= 1.0
```

### `simplex`

```zig
pub fn simplex(seed: u64, x: f32, y: f32) f32
```

**Parameters:** `seed` — the noise seed; `x`, `y` — sample coordinates.
**Returns:** 2D simplex noise in `[-1, 1]`. The triangular lattice removes the axis bias of a square grid, so it stays isotropic when sampled along circles — the reason to use it over perlin for flow fields, clouds and animal wander.

```zig
const n = simplex(42, 3.5, 2.5); // -1.0 <= n <= 1.0
```

---

## Basis Enum

```zig
pub const Basis = enum { value, perlin, simplex };
```

Which base `fbm` and `ridged` sum. Kept as an enum so the Lua side passes a name, not a number that can silently mean something else later.

### `Basis.eval`

```zig
fn eval(self: Basis, seed: u64, x: f32, y: f32) f32
```

**Parameters:** `seed` — the noise seed; `x`, `y` — sample coordinates.
**Returns:** The corresponding noise function applied to the inputs.

```zig
const n = Basis.perlin.eval(42, 1.0, 2.0);
```

---

## Fractal Brownian Motion

### `fbm`

```zig
pub fn fbm(seed: u64, x: f32, y: f32, octaves: u8, basis: Basis) f32
```

**Parameters:** `seed` — the noise seed; `x`, `y` — sample coordinates; `octaves` — number of noise layers (capped at `max_octaves`); `basis` — which noise function to compose.
**Returns:** Fractal Brownian motion: `octaves` of the base noise, each at double the frequency and `gain` the amplitude. Returns roughly `[-1, 1]`. Defaults are the usual terrain pair (each octave twice as fine, half as strong).

```zig
const height = fbm(42, x, y, 5, .perlin);
```

### `fbmTuned`

```zig
pub fn fbmTuned(
    seed: u64,
    x: f32,
    y: f32,
    octaves: u8,
    basis: Basis,
    lacunarity: f32,
    gain: f32,
) f32
```

**Parameters:** `seed` — the noise seed; `x`, `y` — sample coordinates; `octaves` — number of noise layers (capped at `max_octaves`); `basis` — which noise function to compose; `lacunarity` — frequency multiplier per octave (clamped to `[1.0, 4.0]`); `gain` — amplitude multiplier per octave (clamped to `[0.0, 1.0]`).
**Returns:** `fbm` with explicit lacunarity and gain. Clamped to sane ranges: the sum of octaves grows with `octaves`, so an unbounded version would leave `[-1, 1]` and blow up on the 9th call from a script. Normalizing by the total amplitude keeps the result in `[-1, 1]` whatever `octaves` is.

```zig
const height = fbmTuned(42, x, y, 6, .simplex, 2.0, 0.5);
```

---

## Ridged Multifractal

### `ridged`

```zig
pub fn ridged(seed: u64, x: f32, y: f32, octaves: u8, basis: Basis) f32
```

**Parameters:** `seed` — the noise seed; `x`, `y` — sample coordinates; `octaves` — number of noise layers (capped at `max_octaves`); `basis` — which noise function to compose.
**Returns:** Ridged multifractal: `1 - |noise|`, squared. The absolute value folds the noise so the zero crossings become ridges, which is what makes mountain silhouettes and coastlines out of the same function. Result is in `[0, 1]`.

```zig
const mountain = ridged(42, x, y, 4, .perlin);
```
