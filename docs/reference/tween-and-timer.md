# Tweens and Timers

**Source:** `src/engine/script/tween.zig` (the tween pool) · `src/engine/ecs/components/timer.zig` + `src/engine/ecs/timer.zig` (the timer) · `src/engine/core/loop.zig` (the clock and the global time scale)

The three tools that answer "…and then what happens?" — the three questions a game asks constantly:

| Question | Tool |
|---|---|
| "In 3 seconds, do X." | **Timer** — a signal at a known time |
| "Move this from here to there over half a second." | **Tween** — a value that travels |
| "Run the whole game at half speed." | **Time scale** — the clock every one of them reads |

They are one system in three pieces, and the reason they are one system is the point of this document: **a script can never move at a different speed than the world it is in**, because there is only one clock, one scale and one simulation step.

---

## Table of contents

- [The clock (`time.*`)](#the-clock-time)
- [The Timer](#the-timer)
- [The Tween](#the-tween)
  - [The properties](#the-properties)
  - [The options](#the-options)
  - [The easing curves](#the-easing-curves)
  - [Chaining](#chaining)
  - [Killing](#killing)
- [How the three fit together](#how-the-three-fit-together)
- [Recipes](#recipes)

---

## The clock (`time.*`)

The clock gameplay reads, and the engine's one time dial. Every number comes from the same `GameTime` the simulation runs on.

| Function | What it is |
|---|---|
| `time.delta()` | The last frame's delta, **scaled**. The same number the simulation advanced by |
| `time.unscaled_delta()` | The last frame's **real** delta. A spinner that must keep moving while the game is paused |
| `time.elapsed()` | Scaled game time since boot. It counts **play** time |
| `time.unscaled_elapsed()` | Real time since boot |
| `time.frame()` | The frame counter |
| `time.physics_delta()` | The fixed step (1/60 s) — the step the solver uses |
| `time.scale()` | The global time scale |
| `time.set_scale(s)` | Sets it. Clamped to `[0, 100]`; a negative scale would run the world backwards |
| `time.pause()` / `time.resume()` | Pause, and unpause restoring the scale that was in force |
| `time.is_paused()` | Whether the game is paused |

### What the scale touches — and what it does not

**It touches the simulation.** Physics, timers, animation, particles and the tweens all run slower. The fixed step stays 1/60 s: a slow-motion game runs the **same** simulation, less often, not a different one.

**It touches the `dt` the scripts are handed.** `self.x = self.x + v * dt` keeps up with the world, because `dt` is the scaled number.

**It does not stop the frame loop.** A paused game still gets its `update` calls, with `dt == 0`, so a pause menu keeps reading the input and keeps drawing. What pauses is the simulation.

**It does not touch presentation.** A scene fade runs on real time: a fade that took 0.5 s of game time would take 5 s of real time in slow motion, which is nobody's idea of a fade.

**It does not touch audio.** A sound plays at its own rate, like in every other engine.

### The two pauses, and why they are different

- `time.pause()` pauses the **simulation**. Everything freezes; the UI keeps working.
- `timer.stop(self)` pauses **one timer**. Everything else keeps running.

A cooldown that must not tick while the game is paused is a `timer` with its own `time_scale`; a cooldown that must tick in game time is the default. The global scale multiplies both.

---

## The Timer

A gameplay clock that fires **named signals** instead of calling back. Because the callback is a name, the same timer works for a Zig listener and for a Lua `on_signal` handler, and it survives a save (a `.zson` file stores `Timer { ... }`).

```lua
local M = {}

function M:start()
  self.cooldown = timer.new(self, 2.0, 1)      -- 2 seconds, looping
  timer.set_signals(self, "", "cooldown_done")
end

function M:on_signal(name)
  if name == "cooldown_done" then
    self.ready = true
  end
end

function M:can_fire()
  return self.ready and not timer.is_finished(self.cooldown_timer)
end

return M
```

### The three kinds

| Kind | Value | What it does |
|---|---|---|
| `0` — `once` | `timer.new(self, 1.5, 0)` | Fires `done_signal` once after `duration`, then finishes |
| `1` — `loop` | `timer.new(self, 1.5, 1)` | Fires `done_signal` every `duration`, `loop_count` times (0 = forever) |
| `2` — `during` | `timer.new(self, 1.5, 2)` | Like `loop`, but ALSO fires `tick_signal` every tick — a telegraph bar redrawing without a second clock |

### The full surface

| Function | What it does |
|---|---|
| `timer.new(self, seconds, kind)` | Creates the component. Kind 0 once, 1 loop, 2 during |
| `timer.set_signals(self, on_tick, on_done)` | The signal names. An empty name fires nothing |
| `timer.start(self, loops)` | Resets to zero and sets how many cycles to run (0 = forever) |
| `timer.stop(self)` | Pauses, **keeping** the elapsed time. Starting again resumes where it was |
| `timer.kill(self)` | Finishes it for good. The signal does not fire |
| `timer.restart(self)` | Back to zero, running again, with the configuration intact |
| `timer.progress(self)` | 0..1 through the current cycle — what a cooldown bar draws |
| `timer.set_duration(self, s)` / `timer.get_duration(self)` | The cycle length |
| `timer.get_elapsed(self)` | How far into the cycle it is |
| `timer.get_loops(self)` | The total cycle count and the cycles done |
| `timer.set_kind(self, kind)` | 0 once, 1 loop, 2 during. Does **not** restart the timer |
| `timer.set_time_scale(self, s)` | **This timer's own speed** |
| `timer.is_finished(self)` / `timer.is_paused(self)` | The two states |
| `timer.get_dropped(self)` | The cycles it could not run — see below |

### Three things that surprise people

1. **There is no `autostart` field.** A timer in the world ticks from the moment it exists, so a timer declared in a scene file runs with no script at all. A timer that should *not* start has `paused = true`.
2. **`duration <= 0` fires once and finishes.** A timer that fires every tick with no duration is a busy loop with a signal attached.
3. **`get_dropped` is a health check.** The engine runs at most 16 cycles of one timer per tick, and the cycles it refuses are **counted**. Zero in a healthy game; a number that grows says the timer is running **late** — which is otherwise invisible, because the timer still fires, just late.

---

## The Tween

A value that **travels** to another value over time. The answer to "slide the panel in", "fade the sprite out" and "punch the player back", without a frame counter in the script.

```lua
local M = {}

function M:start()
  -- Slide to x = 200 over half a second, with a little overshoot.
  tween.to(self, "position.x", 200, 0.5, { easing = "out_back" })
end

return M
```

A tween drives a **component** of an actor — the real `Transform`, the real `Sprite.tint` — so the renderer draws the result. It is not a number in a Lua table that happens to look like a position.

> **A tween needs an actor.** It drives a component of one, so it is started from a behaviour (which has an entity). A **global script** has no entity and therefore cannot start one: `tween.to` returns `0` there. The game manager starts the tween *through* the actor that owns it.

Every tween returns a **handle**: a small integer that identifies it until it finishes. The handle is what `tween.kill` and `tween.chain` take.

### The properties

A property is a component field, optionally with a sub-field.

| Property | Component | Value shape |
|---|---|---|
| `"position"`, `"position.x"`, `"position.y"` | `Transform` | `{x, y}` or a number |
| `"rotation"` | `Transform` | a number |
| `"scale"`, `"scale.x"`, `"scale.y"` | `Transform` | `{x, y}` or a number |
| `"tint"`, `"tint.r"`, `"tint.g"`, `"tint.b"`, `"tint.a"` | `Sprite` | `{r, g, b, a}` or a number |
| `"color"`, `"color.r"`, … | `Label` / `UiPanel` | `{r, g, b, a}` or a number |
| `"energy"` | the lights | a number |
| `"radius"` | the point and spot lights | a number |
| `"value"` | `UiProgressBar` | a number, 0..1 |
| `"duration"` | `Timer` | a number, seconds |

`tween.properties()` returns the list at runtime, so a script can discover what exists.

**The shape comes from the property, not from the argument.** `"position"` is a vector, `"tint"` is a colour, `"rotation"` is a number. A number given for a vector is a uniform one (`{x = 5, y = 5}`), which is what a designer means by "scale it by five".

**A tween of one part leaves the rest alone** — and leaves it at its *current* value, not the value it had when the tween started. Two tweens on the same actor (one on x, one on y) do not fight.

### The options

`opts` is optional:

| Option | Default | What it does |
|---|---|---|
| `easing` | `"linear"` | The curve. An unknown name is ignored (the tween runs linear) |
| `delay` | `0` | Seconds to wait before it starts |
| `repeat` | `0` | **Extra** cycles: 0 runs once, 2 runs three times, −1 runs forever |
| `yoyo` | `false` | Each run goes out **and back**. A yoyo is ONE run that takes twice the time |
| `hold` | `false` | The tween is created **parked**: it starts when it is released or when the tween it is chained to finishes |
| `on_complete` | — | A Lua function, called with the actor's `self` when the tween ends |

```lua
tween.to(self, "position.x", 200, 0.5, {
  easing = "out_back",
  delay = 0.2,
  on_complete = function(self) print("arrived") end,
})
```

### The easing curves

`"linear"`, and then `in_*`, `out_*` and `in_out_*` of: `quad`, `cubic`, `quart`, `sine`, `expo`, `circ`, `back`, `elastic`, `bounce`. Twenty-eight curves in all.

- **`out_*`** starts fast and settles — the natural "it arrived" curve.
- **`in_*`** starts slow and accelerates — the natural "it is being flung" curve.
- **`in_out_*`** does both — the natural "it accelerates and then stops" curve.
- **`out_back`** overshoots its target and comes back. A little cartoon, and exactly right for a UI pop.
- **`out_elastic`** oscillates. **`out_bounce`** falls and bounces.

Every curve starts at exactly 0 and ends at exactly 1 — the endpoints are forced, because a curve that lands a hundredth short leaves the property permanently off.

`math.ease(name, t)` gives you the same curve as a number, and `math.easings()` lists them.

### Chaining

A sequence: the second tween starts when the first finishes.

```lua
local move = tween.to(self, "position.x", 200, 1.0)
local fade = tween.to(self, "tint.a", 0, 0.5, { hold = true })
tween.chain(move, fade)
```

The child is **parked and reset** to its start value, so create it with `hold = true` (or chain it before it runs) to avoid a visible jump. The child starts on the frame **after** the parent finishes — the tail of the parent's frame belongs to the parent.

### Killing

```lua
tween.kill(handle)        -- one tween, where it is
tween.kill_entity(self)   -- every tween on this actor
tween.kill_all()          -- every tween in the game
```

A killed tween leaves the property **where it was** and does **not** run the completion callback: a cancelled thing has not finished.

### The rest of the surface

| Function | What it does |
|---|---|
| `tween.start(handle)` | Releases a parked tween |
| `tween.is_alive(handle)` | Whether it is still running |
| `tween.count()` | How many are running |
| `tween.time_scale()` / `tween.set_time_scale(s)` | The **tween** speed: it moves the animations, not the world |

> `tween.set_time_scale` and `time.set_scale` are different dials. The first moves the **animations** (a title screen's logo spinning); the second moves the **world** (slow motion). A slow-motion game wants both: the world's speed from `time.set_scale`, and nothing at all from the tween scale.

---

## How the three fit together

```
time.set_scale(0.5)          the WORLD slows to half speed
   │
   ├─▶ the fixed step runs half as often      → physics, animation, particles
   ├─▶ the timers get half the time           → a 2 s cooldown takes 2 s of game time
   ├─▶ the tweens get half the time           → a 0.5 s tween takes 0.5 s of game time
   └─▶ the scripts get half the delta         → `self.x = self.x + v * dt` keeps up
```

The order inside the fixed step is a **contract**:

1. `world.captureTransforms()` — the interpolation snapshot, first.
2. The timers fire their signals.
3. The animations advance.
4. **The tweens move their properties.**
5. **The scripts run** — so a script reads the tweened value in the same tick it was written, and a script that writes the property itself has the last word.
6. The particles simulate.
7. The root motion is applied — last, so a solver does not overwrite the clip.

---

## Recipes

### A cooldown bar

```lua
function M:start()
  self.bar = ui.set_value(self.ui_bar, 0)
  timer.new(self, 3.0, 2)                      -- during
  timer.set_signals(self, "cooldown_tick", "")
end

function M:on_signal(name)
  if name == "cooldown_tick" then
    ui.set_value(self.ui_bar, timer.progress(self))
  end
end
```

### A slide-in panel

```lua
tween.to(self, "offset.x", -400, 0.4, { easing = "out_cubic" })
tween.to(self, "color.a", 1, 0.3, { delay = 0.1 })
```

### Hit-stop: the world freezes for 50 ms

```lua
time.set_scale(0)          -- the simulation stops; the frame loop does not
-- ... 50 ms later, from a timer or a tween:
time.set_scale(1)
```

### A slow-motion death blow

```lua
time.set_scale(0.25)
tween.set_time_scale(0.25)   -- the tweens slow down too
-- ... and back:
time.set_scale(1)
tween.set_time_scale(1)
```

### A punch: move, then return

```lua
tween.to(self, "position.x", self.base_x - 20, 0.06, { easing = "out_quad" })
  -- and a yoyo for the return:
tween.to(self, "position.x", self.base_x, 0.12, { delay = 0.06, yoyo = true })
```

### A sequence of three things

```lua
local a = tween.to(self, "position.x", 100, 0.4)
local b = tween.to(self, "position.x", 200, 0.4, { hold = true })
local c = tween.to(self, "position.x", 300, 0.4, { hold = true })
tween.chain(a, b)
tween.chain(b, c)
```

---

## See also

- [Lua API Reference](script-lua-api.md#tween) — every `tween.*` and `timer.*` binding.
- [Component Catalog](component-catalog.md#timer--id-19) — the `Timer` component's fields.
- [Core Loop](core-loop.md) — the clock and the fixed step.
