# Core Loop

**Source:** `src/engine/core/loop.zig`

The fixed-timestep loop and the **game clock**.

Two structures with two jobs, on purpose:

| Type | Job |
|---|---|
| `GameTime` | The clock gameplay reads, and the engine's **one** global time scale. |
| `FixedLoop` | The accumulator that turns a delta into a number of simulation steps. |

The split matters because the two answer different questions. The clock knows what time it is and how fast the game is running; the accumulator knows how many 1/60 steps the world owes. Splitting them is what lets the scale have exactly **one** owner, so the simulation, the scripts and the `time.*` Lua bindings cannot disagree about how fast the game is running.

> This is NOT [`core/time.zig`](core-time.md). That file is the **measurement** clock (a monotonic counter for profiler zones and frame pacing) and it says out loud that "gameplay must never read a clock". `GameTime` is the opposite: it is the clock gameplay reads, and it is deliberately scaled.

---

## GameTime

```zig
pub const GameTime = struct {
    fixed_dt: f32 = 1.0 / 60.0,
    scale: f32 = 1.0,
    scale_before_pause: f32 = 1.0,
    elapsed: f32 = 0.0,
    unscaled_elapsed: f32 = 0.0,
    delta: f32 = 0.0,
    unscaled_delta: f32 = 0.0,
    frame: u64 = 0,

    pub const max_scale: f32 = 100.0;

    pub fn init(fixed_dt: f32) GameTime;
    pub fn beginFrame(self: *GameTime, real_dt: f32) f32;
    pub fn setScale(self: *GameTime, s: f32) void;
    pub fn pause(self: *GameTime) void;
    pub fn unpause(self: *GameTime) void;
    pub fn isPaused(self: *const GameTime) bool;
    pub fn physicsDelta(self: *const GameTime) f32;
};
```

### Fields

| Name | Type | Description |
|------|------|-------------|
| `fixed_dt` | `f32` | The fixed simulation step (1/60). Also the physics step. |
| `scale` | `f32` | The global time scale. `1` normal, `0` paused, `0.5` slow motion, `2` double speed. |
| `scale_before_pause` | `f32` | The scale to restore on `unpause`, so a pause does not silently turn slow motion back into normal speed. |
| `elapsed` | `f32` | Scaled game seconds since boot — what a gameplay timer counts. |
| `unscaled_elapsed` | `f32` | Real seconds since boot — what a loading screen counts. |
| `delta` | `f32` | The last frame's **scaled** delta — the number the simulation advanced by. |
| `unscaled_delta` | `f32` | The last frame's **real** delta. |
| `frame` | `u64` | Frames since boot. |

### `beginFrame(real_dt)`

**Parameters:** `real_dt` — the real seconds since the last frame.
**Returns:** the **scaled** delta the simulation must advance by.

Clamps the real delta, applies the scale, advances both clocks and the frame counter, and returns the delta the caller must use:

```zig
const dt = game_time.beginFrame(real_dt);
const steps = loop.addTime(dt);
behaviors.update(dt);
```

The **hitch clamp** is applied to REAL time and **before** the scale, so a one-second stall after a tab switch advances the game by 0.1 s at *any* scale: a hitch is a hitch, and letting the scale multiply it would turn a 1 s freeze into a 2 s freeze at double speed.

### `setScale(s)`

Clamped to `[0, max_scale]`. A negative scale would run the simulation backwards, which nothing supports; an unbounded one would let a single frame advance the world by minutes. A `NaN` is **ignored** rather than clamped, because clamping propagates a `NaN` and a `NaN` scale would silently freeze the game forever.

### `pause()` / `unpause()` / `isPaused()`

`pause` remembers the scale in force and sets the scale to `0`. `unpause` (named `unpause` and not `resume` because `resume` is a Zig keyword) restores it. `isPaused` reports whether the scale is `0`.

`unpause` is a **no-op when the game is not paused**: the scale it restores is the one remembered at the last `pause`, and a game that was running — or one whose scale was set by hand while paused — would have that remembered value stomped by an `unpause` it did not need. The explicit choice wins.

> A paused game still gets its `update(dt)` calls, with `dt == 0`. That is deliberate: the pause menu has to keep reading the input and keep drawing. What pauses is the **simulation** — no fixed step runs, so physics, timers, animation and particles freeze.

---

## FixedLoop

```zig
pub const FixedLoop = struct {
    fixed_dt: f32,
    accumulator: f32 = 0,
    max_catchup: u32 = 1,
    dropped_total: u64 = 0,
    dropped_this_frame: u64 = 0,

    pub fn init(fixed_dt: f32) FixedLoop;
    pub fn addTime(self: *FixedLoop, scaled_dt: f32) u32;
    pub fn alpha(self: *const FixedLoop) f32;
};
```

### `addTime(scaled_dt)`

**Parameters:** `scaled_dt` — the delta, already clamped and scaled by `GameTime.beginFrame`.
**Returns:** how many fixed steps must run.

The loop applies **neither** the clamp nor the scale: the simulation and the scripts must advance by the same number, and two places applying the scale is two places to get it wrong. The hitch clamp belongs to the clock for the same reason.

Leftover time beyond `max_catchup` is dropped and counted in `dropped_total` (the anti-death-spiral rule, spec §3.3) — the report uses it to detect a machine that cannot keep up.

### `alpha()`

The simulation-to-render interpolation factor in `[0, 1)`: how far the world is between the last step and the next one.

---

## Constants

| Name | Value | Description |
|------|-------|-------------|
| `max_hitch_dt` | `0.1` | The largest real delta one frame may contribute, in seconds. |

---

## See also

- [`core-time.md`](core-time.md) — the measurement clock (profiler, frame pacing).
- [`script-lua-api.md`](script-lua-api.md#time) — the `time.*` Lua surface.
