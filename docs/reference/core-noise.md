# Core Noise

**Source:** `src/engine/core/noise.zig`

Deterministic procedural noise. Same contract as `random.zig`: the output is a pure function of `(seed, x, y)`, so a level generated on a replay regenerates identically. Nothing here allocates and nothing here touches global state — the seed is passed in, which is what lets two subsystems use different noise fields (terrain height vs. cloud drift) without interfering.

Three bases are provided because games need different things from noise:

- **value** — cheap, blocky when sampled far apart. Fine for terrain height.
- **perlin** — the classic gradient noise; smooth, no directional artefacts. The workhorse for procedural terrain.
- **simplex** — a triangular lattice with no axis-aligned bias, which is why it is the one to reach for when the noise is sampled along circles or used for isotropic warp (clouds, flow fields, wandering animals).

`fbm` and `ridged` compose a base into something with structure at several scales, which is almost always what a game wants rather than one octave.

---

## Quick Reference

| Function | Range | Use When |
|---|---|---|
| `value(seed, x, y)` | `[-1, 1]` | Cheap terrain, blocky is fine |
| `perlin(seed, x, y)` | `[-1, 1]` | Smooth terrain, default choice |
| `simplex(seed, x, y)` | `[-1, 1]` | Isotropic, clouds, flow fields, wander |
| `fbm(seed, x, y, octaves, basis)` | `[-1, 1]` | Multi-scale detail (hills + bumps) |
| `fbmTuned(seed, x, y, octaves, basis, lac, gain)` | `[-1, 1]` | Custom lacunarity/gain for specific look |
| `ridged(seed, x, y, octaves, basis)` | `[0, 1]` | Mountains, coastlines, sharp ridges |

**Max octaves:** `12` (capped for all fractal functions)

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

---

## Practical Examples

### Terrain Height Map

```lua
local seed = 42

function M:update(dt)
  -- Generate terrain heights for a tile at (tile_x, tile_y)
  local tile_x, tile_y = self.x // 32, self.y // 32
  local h = noise.fbm(seed, tile_x * 0.1, tile_y * 0.1, 5, noise.Basis.perlin)
  -- h is in [-1, 1]; map to [0, 1] for a height value
  local height = (h + 1) * 0.5
end
```

### Cloud Drift (Isotropic)

```lua
function M:update(dt)
  -- Simplex has no axis bias, so clouds look natural drifting in any direction
  local c = noise.simplex(seed, self.x * 0.01 + self.time * 0.1, self.y * 0.01)
  local opacity = (c + 1) * 0.5
end
```

### Animal Wander (Deterministic)

```lua
function M:start()
  self.wander_seed = 1234
  self.wander_angle = 0
end

function M:update(dt)
  -- Use noise to drive a smooth, deterministic wander angle
  self.wander_angle = noise.fbm(self.wander_seed, self.x * 0.05, self.y * 0.05, 3, noise.Basis.simplex) * math.pi
  local vx = math.cos(self.wander_angle) * self.speed * dt
  local vy = math.sin(self.wander_angle) * self.speed * dt
  actor.move_by(self, vx, vy)
end
```

### Mountain Range (Ridged)

```lua
function M:generate_chunk(chunk_x)
  for dy = 0, 31 do
    for dx = 0, 31 do
      local wx = (chunk_x * 32 + dx) * 0.02
      local wy = dy * 0.02
      local ridge = noise.ridged(seed, wx, wy, 4, noise.Basis.perlin)
      -- ridge is in [0, 1]; higher values = mountain peaks
      if ridge > 0.6 then
        -- Place a mountain tile
      end
    end
  end
end
```

---

## Lua Binding

From Lua, use the `noise` global table:

```lua
noise.seed(42)                           -- default seed for subsequent calls
local v = noise.value(x, y)              -- value noise
local p = noise.perlin(x, y)             -- Perlin noise
local s = noise.simplex(x, y)            -- simplex noise
local f = noise.fbm(x, y, 4)             -- fractal Brownian motion, 4 octaves
local r = noise.ridged(x, y, 4)          -- ridged multifractal
```

Each function also accepts an optional trailing seed argument, so you can
keep two independent fields (terrain vs. weather) without reseeding:

```lua
local terrain = noise.perlin(x, y, 42)   -- seed 42 for terrain
local clouds = noise.simplex(x, y, 99)    -- seed 99 for clouds
```

---

## Performance Notes

- All functions are **allocation-free** and **deterministic**.
- The seed is passed in, not stored — no global state.
- `fbm` and `ridged` are capped at 12 octaves to prevent frame-long stalls.
- `value` is the cheapest; `simplex` is the most expensive. Choose accordingly.
- `fbmTuned` clamps lacunarity to `[1.0, 4.0]` and gain to `[0.0, 1.0]` — out-of-range values are clamped, not propagated.
