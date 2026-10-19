# Ember Engine — Lua API Reference

This document is the complete reference of every Lua binding the Ember Engine exposes. Each function is documented with its signature, parameters, return value, description, and a runnable Lua example. The API is grouped into **modules**, which are global tables available to every script.

## Modules

| Module | Purpose |
|---|---|
| [`actor`](#actor) | Per-actor transform, rotation, name, signals, and spatial queries between actors |
| [`input`](#input) | Action-based input queries (pressed, down, axis) |
| [`log`](#log) | The whitelisted logging sink (`info`, `warn`) |
| [`globals`](#globals) | The mounted global scripts — the Lua singleton surface (`get`, `exists`) |
| [`time`](#time) | The game clock and the global time scale (slow motion, pause) |
| [`timer`](#timer) | The gameplay clock: "in N seconds, fire this signal" |
| [`tween`](#tween) | A value that travels to another value over time |
| [`math`](#math) | Scalar math: clamping, interpolation, easing, rounding, trigonometry |
| [`vec2`](#vec2) | 2D vector math: distance, length, normalization, dot/cross, rotation |
| [`rand`](#rand) | Deterministic random numbers (floats, ints, chance, gauss, shuffle, choice) |
| [`noise`](#noise) | Procedural noise (value, Perlin, simplex, fBm, ridged) |
| [`sm`](#sm) | Declarative state machines (states, transitions, enter/update/exit) |
| [`physics`](#physics) | Rigid-body queries: raycasts, line of sight, solver counters, activity tiers |
| [`audio`](#audio) | The mixer: play_file, play_stream, buses, solo/sends, stats |
| [`sound`](#sound) | This actor's `SoundEmitter2D`: play, stop, volume/pitch, radius, is_playing, describe |
| [`world`](#world) | World-level queries (neighborhood search) |
| [`steer`](#steer) | Steering behaviors: seek, flee, arrive, pursue, evade, wander, avoid, flock |

The API is **unit-agnostic**: positions and distances are in world units (pixels by default, or whatever scale the game chooses).

---

## `actor`

All `actor` methods take `self` as their first argument — the behavior's `self` table, which carries the entity handle. `self` can also be another actor's `self` table when passing an "other" actor.

> Rigid-body methods — `actor.set_linear_velocity`, `actor.get_linear_velocity`,
> `actor.apply_impulse`, `actor.is_awake` — are documented with the rest of the
> physics surface, under [`physics`](#physics), because the rule they share
> ("write the component, never the solver") only makes sense next to each other.

### `actor.get_position(self)`

| | |
|---|---|
| **Signature** | `actor.get_position(self) -> number, number` |
| **Parameters** | `self` — `Actor` — the behavior's `self` table |
| **Returns** | `x` — `number` — x in world units |
| | `y` — `number` — y in world units |
| **Description** | Returns the world-space position of this actor as `x, y`. Reads the live simulation position (not the render-interpolated one). For mutating movement, prefer [`actor.move_by`](#actormove_by): `get_position` pushes two return values, and each push is another Lua C-API call the JIT cannot compile away. Returns `(0, 0)` if the actor has no Transform. |

```lua
local x, y = actor.get_position(self)
log.info("player at " .. x .. ", " .. y)
```

### `actor.set_position(self, x, y)`

| | |
|---|---|
| **Signature** | `actor.set_position(self, x, y)` |
| **Parameters** | `self` — `Actor` |
| | `x` — `number` — new x position |
| | `y` — `number` — new y position |
| **Returns** | *(nothing)* |
| **Description** | Sets the world-space position of this actor, replacing the current position. |

```lua
actor.set_position(self, 100, 200)
```

### `actor.translate(self, dx, dy)`

| | |
|---|---|
| **Signature** | `actor.translate(self, dx, dy)` |
| **Parameters** | `self` — `Actor` |
| | `dx` — `number` — horizontal delta to add |
| | `dy` — `number` — vertical delta to add |
| **Returns** | *(nothing)* |
| **Description** | Moves the actor by a delta, relative to its current position. Equivalent to `get_position` + `set_position` but done in a single read-modify-write call. |

```lua
-- move right by 5 units this frame
actor.translate(self, 5, 0)
```

### `actor.move_by(self, dx, dy)`

| | |
|---|---|
| **Signature** | `actor.move_by(self, dx, dy)` |
| **Parameters** | `self` — `Actor` |
| | `dx` — `number` — horizontal delta to add |
| | `dy` — `number` — vertical delta to add |
| **Returns** | *(nothing)* |
| **Description** | Read-modify-write move: adds a delta to the actor's position in **one** C call. This is the preferred way to move an actor in a hot loop — a naive `translate` (or the `get_position`/`set_position` pair) costs two or three Lua→C calls, while `move_by` costs one. |

```lua
-- the fast way to move: one Lua->C call instead of two
actor.move_by(self, math.cos(self.heading) * 120 * dt, math.sin(self.heading) * 120 * dt)
```

### `actor.get_rotation(self)`

| | |
|---|---|
| **Signature** | `actor.get_rotation(self) -> number` |
| **Parameters** | `self` — `Actor` |
| **Returns** | `number` — angle in radians (clockwise on screen); 0 if no Transform |
| **Description** | Returns the rotation of this actor in radians. |

```lua
local angle = actor.get_rotation(self)
log.info("heading: " .. math.round(math.rad_to_deg(angle)) .. "°")
```

### `actor.set_rotation(self, radians)`

| | |
|---|---|
| **Signature** | `actor.set_rotation(self, radians)` |
| **Parameters** | `self` — `Actor` |
| | `radians` — `number` — angle in radians (positive = clockwise on screen) |
| **Returns** | *(nothing)* |
| **Description** | Sets the rotation of this actor, in radians. |

```lua
actor.set_rotation(self, math.deg_to_rad(90))
```

### `actor.get_name(self)`

| | |
|---|---|
| **Signature** | `actor.get_name(self) -> string` |
| **Parameters** | `self` — `Actor` |
| **Returns** | `string` — the actor's name, or empty string if it has no Name component |
| **Description** | Returns the Name component of this actor. |

```lua
log.info("hello from " .. actor.get_name(self))
```

### `actor.emit(self, event)`

| | |
|---|---|
| **Signature** | `actor.emit(self, event)` |
| **Parameters** | `self` — `Actor` |
| | `event` — `string` — signal name, matched by listeners on the same name |
| **Returns** | *(nothing)* |
| **Description** | Queues a signal on this actor with a zero-sized payload: the event name is the type. Listeners registered for the same name fire on the next `world.signals.drain()`, in stable spawn order. The Lua side cannot see the payload (it is empty); richer events get a typed payload from Zig emitters. |

```lua
actor.emit(self, "hit")   -- a listener's on_signal("hit") fires next drain
```

### `actor.get_half_size(self)`

| | |
|---|---|
| **Signature** | `actor.get_half_size(self) -> number, number` |
| **Parameters** | `self` — `Actor` |
| **Returns** | `half_width` — `number` — half the sprite's width (0 if no Sprite component) |
| | `half_height` — `number` — half the sprite's height (0 if no Sprite component) |
| **Description** | Returns half the sprite's extent, so "is the click on me" is `|x - cx| <= hw and |y - cy| <= hh` with no Rect2 needed. |

```lua
local hw, hh = actor.get_half_size(self)
-- a point test with no rect needed:
local inside = math.abs(click_x - self.px) <= hw
```

### `actor.distance_to(self, other)`

| | |
|---|---|
| **Signature** | `actor.distance_to(self, other) -> number` |
| **Parameters** | `self` — `Actor` |
| | `other` — `Actor` — any other behavior's `self` table |
| **Returns** | `number` — distance in world units (pixels by default) |
| **Description** | Returns the world-space distance between this actor and another. This is a single C call (the two `world.get` lookups happen back-to-back on data that is already hot), unlike the Lua spelling `local ax, ay = self:get_position()` + `vec2.dist(ax, ay, bx, by)` which costs 3 calls. |

```lua
local d = actor.distance_to(self, other)
if d < 50 then log.info("too close!") end
```

### `actor.distance_to_point(self, x, y)`

| | |
|---|---|
| **Signature** | `actor.distance_to_point(self, x, y) -> number` |
| **Parameters** | `self` — `Actor` |
| | `x` — `number` — point x |
| | `y` — `number` — point y |
| **Returns** | `number` — distance in world units |
| **Description** | Distance from this actor to a bare point (a click, a spawn marker, a waypoint). |

```lua
local d = actor.distance_to_point(self, 640, 360)
log.info("dist to center: " .. math.round(d))
```

### `actor.distance_squared_to(self, other)`

| | |
|---|---|
| **Signature** | `actor.distance_squared_to(self, other) -> number` |
| **Parameters** | `self` — `Actor` |
| | `other` — `Actor` |
| **Returns** | `number` — distance squared; compare against `radius*radius` |
| **Description** | Returns the squared distance between this actor and another. The comparison form: sorting or testing against a radius by squaring the radius avoids one `sqrt`. Prefer this in a loop over many candidates. |

```lua
-- "is it within 100 units?" without a sqrt
if actor.distance_squared_to(self, other) <= 100 * 100 then end
```

### `actor.is_within_radius(self, other, radius)`

| | |
|---|---|
| **Signature** | `actor.is_within_radius(self, other, radius) -> boolean` |
| **Parameters** | `self` — `Actor` |
| | `other` — `Actor` |
| | `radius` — `number` — radius in world units |
| **Returns** | `boolean` — true if within radius, false otherwise |
| **Description** | Returns true when the other actor is within `radius` world units of this one. Squared on both sides so there is no sqrt at all. |

```lua
if actor.is_within_radius(self, other, 200) then
  log.info("close!")
end
```

### `actor.is_within_radius_of_point(self, x, y, radius)`

| | |
|---|---|
| **Signature** | `actor.is_within_radius_of_point(self, x, y, radius) -> boolean` |
| **Parameters** | `self` — `Actor` |
| | `x` — `number` — point x |
| | `y` — `number` — point y |
| | `radius` — `number` — radius in world units |
| **Returns** | `boolean` — true if the point is within radius |
| **Description** | Returns true when a bare point is within `radius` of this actor. |

```lua
-- was this actor clicked?
if actor.is_within_radius_of_point(self, mouse_x, mouse_y, 64) then
  actor.emit(self, "clicked")
end
```

### `actor.direction_to(self, other)`

| | |
|---|---|
| **Signature** | `actor.direction_to(self, other) -> number, number` |
| **Parameters** | `self` — `Actor` |
| | `other` — `Actor` |
| **Returns** | `dx` — `number` — x component in [-1, 1]; 0 when actors coincide |
| | `dy` — `number` — y component in [-1, 1]; 0 when actors coincide |
| **Description** | Returns the unit vector pointing from this actor to the other, as two numbers (zero allocation). The zero vector maps to zero, never NaN. |

```lua
local dx, dy = actor.direction_to(self, other)
actor.move_by(self, dx * 60 * dt, dy * 60 * dt)
```

### `actor.angle_to(self, other)`

| | |
|---|---|
| **Signature** | `actor.angle_to(self, other) -> number` |
| **Parameters** | `self` — `Actor` |
| | `other` — `Actor` |
| **Returns** | `number` — angle in radians, relative to +X; positive is clockwise |
| **Description** | Returns the signed angle from this actor's +X axis to the other actor, in radians. |

```lua
actor.set_rotation(self, actor.angle_to(self, other))  -- face the player
```

---

## `input`

Action-based input queries. Input actions are named strings defined by the game.

### `input.is_action_pressed(name)`

| | |
|---|---|
| **Signature** | `input.is_action_pressed(name) -> boolean` |
| **Parameters** | `name` — `string` — input action name (e.g. `"jump"`) |
| **Returns** | `boolean` — true on the frame the action was pressed |
| **Description** | Returns true on the frame an action went down (the transition from up to down). For held state, use [`input.is_action_down`](#inputis_action_down). |

```lua
if input.is_action_pressed("jump") then self.can_jump = true end
```

### `input.is_action_down(name)`

| | |
|---|---|
| **Signature** | `input.is_action_down(name) -> boolean` |
| **Parameters** | `name` — `string` — input action name (e.g. `"move_right"`) |
| **Returns** | `boolean` — true while the action is held |
| **Description** | Returns true while an action is held down. |

```lua
if input.is_action_down("move_right") then actor.move_by(self, 200 * dt, 0) end
```

### `input.get_axis(negative, positive)`

| | |
|---|---|
| **Signature** | `input.get_axis(negative, positive) -> number` |
| **Parameters** | `negative` — `string` — action for the negative direction (e.g. `"move_left"`) |
| | `positive` — `string` — action for the positive direction (e.g. `"move_right"`) |
| **Returns** | `number` — axis value in [-1, 1] |
| **Description** | Returns an axis value in [-1, 1] computed from two opposing actions. `-1` when only the negative action is held, `+1` when only the positive, `0` when neither or both. |

```lua
local move = input.get_axis("move_left", "move_right")
```

---

## `log`

The whitelisted logging sink. Only `info` and `warn` levels are available to Lua scripts.

### `log.info(message)`

| | |
|---|---|
| **Signature** | `log.info(message)` |
| **Parameters** | `message` — `string` — message to log |
| **Returns** | *(nothing)* |
| **Description** | Logs an informational line to the engine log at info level. Strings are concatenated with `..`. |

```lua
log.info("hp: " .. self.hp)
```

### `log.warn(message)`

| | |
|---|---|
| **Signature** | `log.warn(message)` |
| **Parameters** | `message` — `string` — warning message |
| **Returns** | *(nothing)* |
| **Description** | Logs a warning line to the engine log at warn level. |

```lua
log.warn("out of ammo")
```

## `globals`

The mounted **global scripts** — Lua behavior scripts with no actor: the game manager, the score, the spawner, the flow. Declared in `project.config` under `scripts { global "..." }`; each mounts under its file's basename (see [Global Scripts](global-scripts.md)). One instance per script, resolved by name — the Lua side of the singleton rule.

> A global's `self` carries **no entity handle**, so `actor.*` called on a
> global's table fails the same way a dead self's does. A global talks to the
> world (`world.*`, `input.*`, `scene.*`, `audio.*`), and reaches the actors
> that talk to *it*.

### `globals.get(name)`

| | |
|---|---|
| **Signature** | `globals.get(name) -> Actor` |
| **Parameters** | `name` — `string` — the global script's cache name (e.g. `"game"`) |
| **Returns** | `Actor` — the global's `self` table — call its methods (`game:pause()`) or read/write its fields; nil when no global by that name is mounted |
| **Description** | Returns the mounted global script's `self` table, or `nil`. Method calls and field writes go straight through it, so a behavior can read the score, bump it, or invoke the manager's flow methods in the same frame. |

```lua
local game = globals.get("game")
if game then game.score = game.score + 100 end
```

### `globals.exists(name)`

| | |
|---|---|
| **Signature** | `globals.exists(name) -> boolean` |
| **Parameters** | `name` — `string` — the global script's cache name (e.g. `"flow"`) |
| **Returns** | `boolean` — true while the global is mounted (a detached global returns false the moment it is gone) |
| **Description** | True when a global script with this name is mounted. Answers "can I call this", not "does the file exist" — `globals.get` on an unknown name is `nil`, so most scripts only ever need `get`. |

```lua
if globals.exists("flow") then globals.get("flow"):resume() end
```

---

## `time`

The **game clock** — the time gameplay sees — and the engine's **one time dial**.

Every number here comes from the same clock the simulation runs on, so a script can never see a delta that disagrees with the world it is moving in.

> The scale is **global**. It slows the *simulation* — physics, timers, animation, particles — and the `dt` the scripts are handed. It does **not** stop the frame loop: a pause menu has to keep reading the input and keep drawing, and a paused game that freezes its own UI is a worse pause. Presentation (a scene fade) runs on real time.

### `time.delta()`

| | |
|---|---|
| **Signature** | `time.delta() -> number` |
| **Returns** | `number` — seconds; `0` while the game is paused |
| **Description** | The last frame's delta, scaled by the global time scale. It is the same number the simulation advanced by, so `self.x = self.x + v * time.delta()` moves at the speed the world moves. |

```lua
self.x = self.x + 100 * time.delta()
```

### `time.unscaled_delta()`

| | |
|---|---|
| **Signature** | `time.unscaled_delta() -> number` |
| **Returns** | `number` — seconds of wall clock |
| **Description** | The last frame's **real** delta, unaffected by the time scale. A UI that has to keep moving while the game is paused (a loading spinner) reads this one. |

```lua
spinner.rotation = spinner.rotation + 3 * time.unscaled_delta()
```

### `time.elapsed()`

| | |
|---|---|
| **Signature** | `time.elapsed() -> number` |
| **Returns** | `number` — seconds of game time |
| **Description** | Scaled game time since boot. It slows down with the game, so it counts **play** time, not wall-clock time. |

```lua
if time.elapsed() > 60 then globals.get("game").over = true end
```

### `time.unscaled_elapsed()`

| | |
|---|---|
| **Signature** | `time.unscaled_elapsed() -> number` |
| **Returns** | `number` — seconds of wall clock |
| **Description** | Real time since boot, unaffected by the time scale. |

```lua
local load = time.unscaled_elapsed() - started_at
```

### `time.frame()`

| | |
|---|---|
| **Signature** | `time.frame() -> number` |
| **Returns** | `number` — frames since boot |
| **Description** | The frame counter, incremented once per frame. |

```lua
if time.frame() % 30 == 0 then actor.emit(self, "tick") end
```

### `time.physics_delta()`

| | |
|---|---|
| **Signature** | `time.physics_delta() -> number` |
| **Returns** | `number` — the fixed step in seconds (1/60) |
| **Description** | The fixed simulation step — the step the **solver** uses, not the frame's delta. Integrate against this when the answer must not depend on the frame rate. |

```lua
self.hp = self.hp - 10 * time.physics_delta()
```

### `time.scale()`

| | |
|---|---|
| **Signature** | `time.scale() -> number` |
| **Returns** | `number` — the global scale |
| **Description** | The global time scale. `1` is normal, `0.5` is slow motion, `0` is paused. |

```lua
time.set_scale(0.5)   -- slow motion
time.set_scale(1.0)   -- back to normal
```

### `time.set_scale(s)`

| | |
|---|---|
| **Signature** | `time.set_scale(s)` |
| **Parameters** | `s` — `number` — `0` pauses, `0.5` is slow motion, `2` is double speed |
| **Description** | Sets the global time scale. It slows the simulation and the delta the scripts are handed. Clamped to `[0, 100]`: a **negative** scale would run the world backwards, which nothing supports. A `NaN` is ignored rather than applied. |

```lua
time.set_scale(0.25)   -- a dramatic slow-motion moment
```

### `time.pause()`

| | |
|---|---|
| **Signature** | `time.pause()` |
| **Description** | Pauses the simulation. The scale goes to `0` and the scale in force is remembered, so `time.resume()` restores it — slow motion stays slow motion. The frame loop keeps running: the UI and the input keep working. |

```lua
time.pause()
globals.get("game").state = "paused"
```

### `time.resume()`

| | |
|---|---|
| **Signature** | `time.resume()` |
| **Description** | Unpauses the simulation, restoring the scale that was in force before the pause. A no-op when the game is not paused: a scale set by hand while paused is not stomped by a `resume` the game did not need. |

```lua
time.resume()
```

### `time.is_paused()`

| | |
|---|---|
| **Signature** | `time.is_paused() -> boolean` |
| **Returns** | `boolean` — true while the scale is `0` |
| **Description** | True while the game is paused. |

```lua
if time.is_paused() then sprite.set_visible(self, false) end
```

---

## `timer`

The gameplay clock. It fires **named signals** instead of calling back, so the same timer works for a Lua `on_signal` handler and for a Zig listener, and it survives a save.

See [Tweens and Timers](tween-and-timer.md) for the whole picture.

### `timer.new(self, seconds, kind)`

| | |
|---|---|
| **Signature** | `timer.new(self, seconds, kind)` |
| **Parameters** | `self` — `Actor`; `seconds` — `number` — the cycle length; `kind` — `number` — `0` once, `1` loop, `2` during |
| **Description** | Creates the `Timer` component (or reuses the one the actor already has) and returns it. A `during` timer also fires its tick signal every tick, so a telegraph bar can redraw without a second clock. |

```lua
timer.new(self, 2.0, 1)          -- every 2 seconds, forever
timer.set_signals(self, "", "wave_spawned")
```

### `timer.set_signals(self, on_tick, on_done)`

| | |
|---|---|
| **Signature** | `timer.set_signals(self, on_tick, on_done)` |
| **Parameters** | `self` — `Actor`; `on_tick` — `string` — fired every tick while the kind is `during`; `on_done` — `string` — fired when a cycle completes |
| **Description** | The signal **names** this timer fires. An empty name fires nothing. The handler is `on_signal(name)` on the behaviour. |

```lua
function M:on_signal(name)
  if name == "wave_spawned" then self.spawn_wave() end
end
```

### `timer.start(self, loops)`

| | |
|---|---|
| **Signature** | `timer.start(self, loops)` |
| **Parameters** | `self` — `Actor`; `loops` — `number` — how many cycles; `0` means forever |
| **Description** | Puts the timer back to zero and sets how many cycles it runs. It does not unpause a timer that already finished — use `timer.restart` for that. |

### `timer.stop(self)`

| | |
|---|---|
| **Signature** | `timer.stop(self)` |
| **Description** | Pauses the timer **keeping** its elapsed time, so starting it again resumes where it was. |

### `timer.kill(self)`

| | |
|---|---|
| **Signature** | `timer.kill(self)` |
| **Description** | Finishes the timer for good. The done signal does **not** fire. |

### `timer.restart(self)`

| | |
|---|---|
| **Signature** | `timer.restart(self)` |
| **Description** | Back to zero, running again, with the configuration intact: the duration, the kind, the loop count and the signals all survive. |

### `timer.progress(self)`

| | |
|---|---|
| **Signature** | `timer.progress(self) -> number` |
| **Returns** | `number` — `0` at the start of the cycle, `1` at the end |
| **Description** | How far through the current cycle it is — what a cooldown bar draws. |

```lua
ui.set_value(self.bar, timer.progress(self))
```

### `timer.set_duration(self, seconds)` · `timer.get_duration(self)`

| | |
|---|---|
| **Signature** | `timer.set_duration(self, seconds)` / `timer.get_duration(self) -> number` |
| **Description** | The length of one cycle. |

### `timer.get_elapsed(self)`

| | |
|---|---|
| **Signature** | `timer.get_elapsed(self) -> number` |
| **Returns** | `number` — seconds into the current cycle |
| **Description** | How far into the cycle it is. The remaining time is `get_duration - get_elapsed`. |

### `timer.get_loops(self)`

| | |
|---|---|
| **Signature** | `timer.get_loops(self) -> count, current` |
| **Returns** | `number` — the total cycle count (`0` = forever); `number` — the cycles completed |
| **Description** | How many cycles it will run and how many it has run. |

### `timer.set_kind(self, kind)`

| | |
|---|---|
| **Signature** | `timer.set_kind(self, kind)` |
| **Parameters** | `self` — `Actor`; `kind` — `number` — `0` once, `1` loop, `2` during |
| **Description** | Changes the kind **without** restarting: the elapsed time and the cycle counter stay where they were. |

### `timer.set_time_scale(self, scale)`

| | |
|---|---|
| **Signature** | `timer.set_time_scale(self, scale)` |
| **Parameters** | `self` — `Actor`; `scale` — `number` — `0` stops the timer, `0.5` halves it, `2` doubles it |
| **Description** | This timer's **own** speed. It multiplies with the global scale (`time.scale`): a slow-motion game slows every timer, and a timer slower than the game is slower still. |

### `timer.is_finished(self)` · `timer.is_paused(self)`

| | |
|---|---|
| **Signature** | `timer.is_finished(self) -> boolean` / `timer.is_paused(self) -> boolean` |
| **Description** | Whether the timer has done its job, and whether it is stopped. |

### `timer.get_dropped(self)`

| | |
|---|---|
| **Signature** | `timer.get_dropped(self) -> number` |
| **Returns** | `number` — the cycles the timer could not run |
| **Description** | The engine runs at most 16 cycles of one timer per tick, and the ones it refuses are **counted** instead of dropped in silence. Zero in a healthy game; a number that grows says the timer is running **late**. |

```lua
if timer.get_dropped(self) > 0 then print("the timer is running late") end
```

---

## `tween`

A value that **travels** to another value over time — the answer to "slide the panel in", "fade the sprite out" and "punch the player back", without a frame counter in the script.

A tween drives a **component** of an actor, so the renderer draws the result. See [Tweens and Timers](tween-and-timer.md) for the full guide.

### `tween.to(self, property, value, duration, opts)`

| | |
|---|---|
| **Signature** | `tween.to(self, property, value, duration, opts) -> number` |
| **Parameters** | `self` — `Actor`; `property` — `string` — the component field to drive; `value` — `any` — the target; `duration` — `number` — seconds; `opts` — `table` — optional |
| **Returns** | `number` — the tween handle, or `0` when it could not be created |
| **Description** | Starts a tween and returns its handle. The property is a component field, optionally with a sub-field: `"position"`, `"position.x"`, `"rotation"`, `"scale"`, `"tint"`, `"tint.a"`, `"color"`, `"energy"`, `"radius"`, `"value"`, `"duration"`. The value's shape comes from the property: a vector for `"position"`, a colour for `"tint"`, a number for the rest. `opts` may carry `easing`, `delay`, `repeat`, `yoyo`, `hold` and `on_complete`. |

```lua
tween.to(self, "position.x", 200, 0.5, { easing = "out_back" })
tween.to(self, "tint.a", 0, 0.3, { on_complete = function(self) actor.set_visible(self, false) end })
```

### `tween.chain(parent, child)`

| | |
|---|---|
| **Signature** | `tween.chain(parent, child) -> boolean` |
| **Parameters** | `parent` — `number` — the handle that runs first; `child` — `number` — the handle that waits |
| **Returns** | `boolean` — true when the chain was made |
| **Description** | The child tween starts when the parent finishes. The child is parked and reset to its start value, so create it with `hold = true` (or chain it before it runs) to avoid a visible jump. |

```lua
local move = tween.to(self, "position.x", 100, 1.0)
local fade = tween.to(self, "tint.a", 0, 0.5, { hold = true })
tween.chain(move, fade)
```

### `tween.start(handle)`

| | |
|---|---|
| **Signature** | `tween.start(handle) -> boolean` |
| **Description** | Releases a parked tween: it starts now. |

### `tween.kill(handle)`

| | |
|---|---|
| **Signature** | `tween.kill(handle) -> boolean` |
| **Description** | Stops the tween where it is. The property keeps the value it had, and the completion callback does **not** run: a killed tween was cancelled, not finished. |

### `tween.kill_entity(self)`

| | |
|---|---|
| **Signature** | `tween.kill_entity(self) -> number` |
| **Returns** | `number` — how many tweens were stopped |
| **Description** | Stops every tween driving this actor. The thing to call when the actor is despawned. |

### `tween.kill_all()`

| | |
|---|---|
| **Signature** | `tween.kill_all() -> number` |
| **Description** | Stops every tween in the game. The thing to call when the level changes. |

### `tween.is_alive(handle)`

| | |
|---|---|
| **Signature** | `tween.is_alive(handle) -> boolean` |
| **Description** | True while the tween is running. False once it finished, was killed, or never existed. |

### `tween.count()`

| | |
|---|---|
| **Signature** | `tween.count() -> number` |
| **Description** | How many tweens are running right now. |

### `tween.time_scale()` · `tween.set_time_scale(s)`

| | |
|---|---|
| **Signature** | `tween.time_scale() -> number` / `tween.set_time_scale(s)` |
| **Description** | The **tween** speed: it moves the **animations**, not the world. The world's speed is `time.scale`. A slow-motion game wants the world slowed and the tweens slowed with it. |

### `tween.properties()`

| | |
|---|---|
| **Signature** | `tween.properties() -> table` |
| **Returns** | `table` — the list of tweenable property names |
| **Description** | Every property a tween can drive, so a script can discover what exists without the documentation being the only source. |

```lua
for _, name in ipairs(tween.properties()) do print(name) end
```

---

## `math`

The scalar math set. These are thin wrappers over the engine's `core.math` — no allocation, no branches that can trap, and every function is total on its domain. Registered from Zig (rather than shadowing LuaJIT's own `math`) so semantics are fixed across the LuaJIT and Lua 5.4 backends.

### `math.clamp(v, lo, hi)`

| | |
|---|---|
| **Signature** | `math.clamp(v, lo, hi) -> number` |
| **Parameters** | `v` — `number` — value to clamp |
| | `lo` — `number` — minimum allowed value |
| | `hi` — `number` — maximum allowed value |
| **Returns** | `number` — `v` constrained to `[lo, hi]` |
| **Description** | Clamps `v` into the range `[lo, hi]`. |

```lua
self.hp = math.clamp(self.hp - damage, 0, self.max_hp)
```

### `math.min(a, b)`

| | |
|---|---|
| **Signature** | `math.min(a, b) -> number` |
| **Parameters** | `a` — `number` |
| | `b` — `number` |
| **Returns** | `number` — the lesser of `a` and `b` |
| **Description** | The smaller of two numbers. |

```lua
local steps = math.min(self.queue_len, 4)
```

### `math.max(a, b)`

| | |
|---|---|
| **Signature** | `math.max(a, b) -> number` |
| **Parameters** | `a` — `number` |
| | `b` — `number` |
| **Returns** | `number` — the greater of `a` and `b` |
| **Description** | The larger of two numbers. |

```lua
local scale = math.max(1, self.level * 0.5)
```

### `math.abs(v)`

| | |
|---|---|
| **Signature** | `math.abs(v) -> number` |
| **Parameters** | `v` — `number` — any number; the sign is discarded |
| **Returns** | `number` — `v` without its sign |
| **Description** | Absolute value: the distance from zero, always >= 0. |

```lua
local overshoot = math.abs(self.best - self.time)
```

### `math.sign(v)`

| | |
|---|---|
| **Signature** | `math.sign(v) -> number` |
| **Parameters** | `v` — `number` |
| **Returns** | `number` — -1, 0 or +1 (zero maps to 0, not +1) |
| **Description** | The sign of `v`: -1, 0 or +1. |

```lua
actor.move_by(self, math.sign(self.vx) * 10, 0)
```

### `math.floor(v)`

| | |
|---|---|
| **Signature** | `math.floor(v) -> number` |
| **Parameters** | `v` — `number` |
| **Returns** | `integer` — the integral float floor of `v` |
| **Description** | Largest integer not greater than `v`. |

```lua
self.row = math.floor(self.index / self.cols)
```

### `math.ceil(v)`

| | |
|---|---|
| **Signature** | `math.ceil(v) -> number` |
| **Parameters** | `v` — `number` |
| **Returns** | `integer` — the integral float ceil of `v` |
| **Description** | Smallest integer not less than `v`. |

```lua
local pages = math.ceil(self.items / self.per_page)
```

### `math.round(v)`

| | |
|---|---|
| **Signature** | `math.round(v) -> number` |
| **Parameters** | `v` — `number` — any finite number |
| **Returns** | `integer` — nearest integral float; .5 rounds away from zero |
| **Description** | Nearest integer, halves away from zero (not banker's rounding). |

```lua
log.info("score: " .. math.round(self.score))
```

### `math.fract(v)`

| | |
|---|---|
| **Signature** | `math.fract(v) -> number` |
| **Parameters** | `v` — `number` — any number; the integer part is discarded |
| **Returns** | `number` — fractional part in [0, 1) regardless of sign |
| **Description** | Fractional part of `v`, always in [0, 1). |

```lua
local pulse = math.fract(self.t)   -- 0..1 sawtooth
```

### `math.sqrt(v)`

| | |
|---|---|
| **Signature** | `math.sqrt(v) -> number` |
| **Parameters** | `v` — `number` — non-negative value |
| **Returns** | `number` — the non-negative square root |
| **Description** | Square root. |

```lua
local speed = math.sqrt(self.vx * self.vx + self.vy * self.vy)
```

### `math.pow(base, exp)`

| | |
|---|---|
| **Signature** | `math.pow(base, exp) -> number` |
| **Parameters** | `base` — `number` — the base |
| | `exp` — `number` — the exponent |
| **Returns** | `number` — `base^exp` |
| **Description** | Raises `base` to the power `exp`. |

```lua
local damage = 10 * math.pow(2, self.combo)
```

### `math.sin(radians)`

| | |
|---|---|
| **Signature** | `math.sin(radians) -> number` |
| **Parameters** | `radians` — `number` — angle in radians |
| **Returns** | `number` — sine of the angle, in [-1, 1] |
| **Description** | Sine of an angle in radians. |

```lua
local bob = math.sin(self.t * 2) * 8
```

### `math.cos(radians)`

| | |
|---|---|
| **Signature** | `math.cos(radians) -> number` |
| **Parameters** | `radians` — `number` — angle in radians |
| **Returns** | `number` — cosine of the angle, in [-1, 1] |
| **Description** | Cosine of an angle in radians. |

```lua
local phase = math.cos(self.t * 2)
```

### `math.atan2(y, x)`

| | |
|---|---|
| **Signature** | `math.atan2(y, x) -> number` |
| **Parameters** | `y` — `number` — y component |
| | `x` — `number` — x component |
| **Returns** | `number` — angle in radians, in (-pi, pi] |
| **Description** | Two-argument arctangent: the angle of the point (x, y). Same argument order as stock Lua. |

```lua
local heading = math.atan2(dy, dx)
```

### `math.lerp(a, b, t)`

| | |
|---|---|
| **Signature** | `math.lerp(a, b, t) -> number` |
| **Parameters** | `a` — `number` — value at t=0 |
| | `b` — `number` — value at t=1 |
| | `t` — `number` — blend factor, usually 0..1 |
| **Returns** | `number` — `a*(1-t) + b*t` |
| **Description** | Linear blend: `a` at t=0, `b` at t=1. |

```lua
self.charge = math.lerp(self.charge, 1, 0.1)
```

### `math.inverse_lerp(a, b, v)`

| | |
|---|---|
| **Signature** | `math.inverse_lerp(a, b, v) -> number` |
| **Parameters** | `a` — `number` — start of the range |
| | `b` — `number` — end of the range |
| | `v` — `number` — value to locate within the range |
| **Returns** | `number` — 0 at `a`, 1 at `b`; may go outside 0..1 |
| **Description** | Where `v` falls between `a` and `b`, as a 0..1 fraction (can leave the range). |

```lua
local progress = math.inverse_lerp(self.from_x, self.to_x, self.x)
```

### `math.remap(v, in_lo, in_hi, out_lo, out_hi)`

| | |
|---|---|
| **Signature** | `math.remap(v, in_lo, in_hi, out_lo, out_hi) -> number` |
| **Parameters** | `v` — `number` — value to remap |
| | `in_lo` — `number` — input range minimum |
| | `in_hi` — `number` — input range maximum |
| | `out_lo` — `number` — output range minimum |
| | `out_hi` — `number` — output range maximum |
| **Returns** | `number` — `v` mapped to the output range |
| **Description** | Maps `v` from one range to another. |

```lua
-- health 0..100 -> a bar's 0..200 pixel width
self.bar_w = math.remap(self.hp, 0, 100, 0, 200)
```

### `math.smoothstep(edge0, edge1, v)`

| | |
|---|---|
| **Signature** | `math.smoothstep(edge0, edge1, v) -> number` |
| **Parameters** | `edge0` — `number` — lower edge of the transition |
| | `edge1` — `number` — upper edge of the transition |
| | `v` — `number` — value to evaluate |
| **Returns** | `number` — smooth 0..1 blend based on where `v` sits |
| **Description** | Hermite ease: 0 below `edge0`, 1 above `edge1`, smooth between. |

```lua
local glow = math.smoothstep(100, 400, self.dist)
```

### `math.step(edge, v)`

| | |
|---|---|
| **Signature** | `math.step(edge, v) -> number` |
| **Parameters** | `edge` — `number` — threshold value |
| | `v` — `number` — value to test |
| **Returns** | `number` — 0 if `v < edge`, 1 otherwise |
| **Description** | Hard threshold: 0 below `edge`, 1 at or above it. |

```lua
self.lit = math.step(0.5, self.darkness)
```

### `math.move_toward(current, target, max_delta)`

| | |
|---|---|
| **Signature** | `math.move_toward(current, target, max_delta) -> number` |
| **Parameters** | `current` — `number` — starting value |
| | `target` — `number` — value to move toward |
| | `max_delta` — `number` — maximum step per frame |
| **Returns** | `number` — `current` moved toward `target`, clamped to `max_delta` |
| **Description** | Moves `current` toward `target` by at most `max_delta` (never overshoots). |

```lua
self.x = math.move_toward(self.x, self.target_x, 200 * dt)
```

### `math.damp(a, b, rate, dt)`

| | |
|---|---|
| **Signature** | `math.damp(a, b, rate, dt) -> number` |
| **Parameters** | `a` — `number` — current value |
| | `b` — `number` — target value |
| | `rate` — `number` — time constant; larger is slower |
| | `dt` — `number` — delta time in seconds |
| **Returns** | `number` — smoothed value between `a` and `b` |
| **Description** | Frame-rate independent smoothing toward `b`; prefer it over a raw `lerp`. |

```lua
self.x = math.damp(self.x, self.target_x, 8, dt)
```

### `math.wrap(v, lo, hi)`

| | |
|---|---|
| **Signature** | `math.wrap(v, lo, hi) -> number` |
| **Parameters** | `v` — `number` — value to wrap |
| | `lo` — `number` — lower bound (inclusive) |
| | `hi` — `number` — upper bound (exclusive) |
| **Returns** | `number` — `v` wrapped into `[lo, hi)` |
| **Description** | Wraps `v` into `[lo, hi)` (a modulo with a live floor). |

```lua
self.lap = self.lap + 1
self.t = math.wrap(self.t, 0, 1)
```

### `math.pingpong(v, length)`

| | |
|---|---|
| **Signature** | `math.pingpong(v, length) -> number` |
| **Parameters** | `v` — `number` — time or phase value |
| | `length` — `number` — maximum value before bouncing back |
| **Returns** | `number` — triangle wave between 0 and `length` |
| **Description** | Triangle wave bouncing between 0 and `length` (period `2*length`). |

```lua
local sway = math.pingpong(self.t, 40)   -- 0..40..0..40
```

### `math.deg_to_rad(degrees)`

| | |
|---|---|
| **Signature** | `math.deg_to_rad(degrees) -> number` |
| **Parameters** | `degrees` — `number` — angle in degrees |
| **Returns** | `number` — the same angle in radians |
| **Description** | Degrees to radians. |

```lua
actor.set_rotation(self, math.deg_to_rad(45))
```

### `math.rad_to_deg(radians)`

| | |
|---|---|
| **Signature** | `math.rad_to_deg(radians) -> number` |
| **Parameters** | `radians` — `number` — angle in radians |
| **Returns** | `number` — the same angle in degrees |
| **Description** | Radians to degrees. |

```lua
log.info("heading: " .. math.rad_to_deg(actor.get_rotation(self)))
```

### `math.is_close(a, b, tolerance)`

| | |
|---|---|
| **Signature** | `math.is_close(a, b, tolerance) -> boolean` |
| **Parameters** | `a` — `number` — first value |
| | `b` — `number` — second value |
| | `tolerance` — `number` — maximum acceptable difference |
| **Returns** | `boolean` — true when `|a-b| <= tolerance` |
| **Description** | The one predicate in the set that is not a transform: returns true when `a` and `b` differ by at most `tolerance`. |

```lua
if math.is_close(self.x, self.target_x, 0.01) then self.x = self.target_x end
```

### `math.ease(name, t)`

| | |
|---|---|
| **Signature** | `math.ease(name, t) -> number` |
| **Parameters** | `name` — `string` — the curve; `t` — `number` — `0` at the start, `1` at the end |
| **Returns** | `number` — the eased value, or `nil` for an unknown curve |
| **Description** | An easing curve: the **shape** of a movement over time. The same curves the tween uses, so a value eased by hand and a value eased by a tween look the same. The names are `"linear"` and then `in_*`, `out_*` and `in_out_*` of `quad`, `cubic`, `quart`, `sine`, `expo`, `circ`, `back`, `elastic`, `bounce`. |

```lua
local p = math.ease("out_back", 0.5)   -- past the halfway mark
```

### `math.easings()`

| | |
|---|---|
| **Signature** | `math.easings() -> table` |
| **Returns** | `table` — the list of easing names |
| **Description** | Every easing name, so a script can discover what exists without the documentation being the only source. |

```lua
for _, name in ipairs(math.easings()) do print(name) end
```

---

## `vec2`

2D vector math. Two shapes, on purpose:
- **`vec2.new(x, y)`** returns a **table** with `x`/`y` fields — ergonomic for state. Allocates in Lua's heap only when the game explicitly asks for one, never inside a hot loop by accident.
- **All others** take/return **numbers**, so a per-frame computation does zero Lua allocation and one C call.

Many functions accept either a Vec2 table or bare `x, y` numbers, in any combination.

### `vec2.new(x, y)`

| | |
|---|---|
| **Signature** | `vec2.new(x, y) -> Vec2` |
| **Parameters** | `x` — `number` — x component (default 0) |
| | `y` — `number` — y component (default 0) |
| **Returns** | `Vec2` — a table with `x` and `y` fields |
| **Description** | Builds a vector table. Allocates: use it for state, not inside a hot loop. |

```lua
self.target = vec2.new(100, 200)
```

### `vec2.to_vec(x, y)`

| | |
|---|---|
| **Signature** | `vec2.to_vec(x, y) -> Vec2` |
| **Parameters** | `x` — `number` — x component |
| | `y` — `number` — y component |
| **Returns** | `Vec2` — a table with `x` and `y` fields |
| **Description** | The width-explicit constructor: identical to `vec2.new`, spelled for clarity. |

```lua
local forward = vec2.to_vec(math.cos(a), math.sin(a))
```

### `vec2.dist(ax, ay, bx, by)`

| | |
|---|---|
| **Signature** | `vec2.dist(ax, ay, bx, by) -> number` |
| **Parameters** | `ax`, `ay` — `number` — first point (or a Vec2 table as `ax` and `ay`) |
| | `bx`, `by` — `number` — second point (or a Vec2 table) |
| **Returns** | `number` — distance |
| **Description** | Distance between two points. Accepts either four numbers or two Vec2 tables: `vec2.dist(self.x, self.y, other_x, other_y)` or `vec2.dist(self.pos, other.pos)`. |

```lua
local d = vec2.dist(self.x, self.y, other_x, other_y)
-- or, with tables:
local d2 = vec2.dist(self.pos, other.pos)
```

### `vec2.dist_sq(ax, ay, bx, by)`

| | |
|---|---|
| **Signature** | `vec2.dist_sq(ax, ay, bx, by) -> number` |
| **Parameters** | Same as [`vec2.dist`](#vec2dist) |
| **Returns** | `number` — distance squared |
| **Description** | Squared distance: the comparison form, no square root. Accepts the same dual signature as `vec2.dist`. |

```lua
if vec2.dist_sq(self.x, self.y, px, py) <= r * r then end
```

### `vec2.length(v)`

| | |
|---|---|
| **Signature** | `vec2.length(v) -> number` |
| **Parameters** | `v` — `Vec2` — a Vec2 table, or `x, y` as two numbers |
| **Returns** | `number` — length; 0 for the zero vector |
| **Description** | Length of a vector. |

```lua
local speed = vec2.length(self.vel)
```

### `vec2.length_sq(v)`

| | |
|---|---|
| **Signature** | `vec2.length_sq(v) -> number` |
| **Parameters** | `v` — `Vec2` — a Vec2 table |
| **Returns** | `number` — length squared |
| **Description** | Squared length: the comparison form, no square root. |

```lua
if vec2.length_sq(self.vel) > self.max_speed * self.max_speed then end
```

### `vec2.normalized(v)`

| | |
|---|---|
| **Signature** | `vec2.normalized(v) -> Vec2` |
| **Parameters** | `v` — `Vec2` — a Vec2 table |
| **Returns** | `Vec2` — a unit vector (length 1); zero maps to zero |
| **Description** | The vector scaled to length 1. The zero vector maps to zero (never NaN). |

```lua
local dir = vec2.normalized(vec2.new(dx, dy))
```

### `vec2.direction(ax, ay, bx, by)`

| | |
|---|---|
| **Signature** | `vec2.direction(ax, ay, bx, by) -> Vec2` |
| **Parameters** | `ax`, `ay` — `number` — origin point (or a Vec2 table) |
| | `bx`, `by` — `number` — target point (or a Vec2 table) |
| **Returns** | `Vec2` — a unit vector; (0,0) when the points coincide |
| **Description** | Unit vector pointing from one point to another. The zero vector maps to zero rather than NaN. Accepts the same dual signature as `vec2.dist`. |

```lua
local to_ball = vec2.direction(self.x, self.y, ball_x, ball_y)
```

### `vec2.lerp(a, b, t)`

| | |
|---|---|
| **Signature** | `vec2.lerp(a, b, t) -> Vec2` |
| **Parameters** | `a` — `Vec2` — value at t=0 |
| | `b` — `Vec2` — value at t=1 |
| | `t` — `number` — blend factor, usually 0..1 |
| **Returns** | `Vec2` — the blended vector |
| **Description** | Blends two vectors: `a` at t=0, `b` at t=1. |

```lua
self.pos = vec2.lerp(self.pos, self.target, 0.1)
```

### `vec2.dot(a, b)`

| | |
|---|---|
| **Signature** | `vec2.dot(a, b) -> number` |
| **Parameters** | `a` — `Vec2` — first vector |
| | `b` — `Vec2` — second vector |
| **Returns** | `number` — the dot product |
| **Description** | Dot product: how much two vectors point the same way. |

```lua
if vec2.dot(self.dir, vec2.normalized(to_player)) > 0.9 then end  -- in the cone
```

### `vec2.cross(a, b)`

| | |
|---|---|
| **Signature** | `vec2.cross(a, b) -> number` |
| **Parameters** | `a` — `Vec2` — first vector |
| | `b` — `Vec2` — second vector |
| **Returns** | `number` — the scalar cross (z of the 3D cross); positive when `b` is clockwise from `a` |
| **Description** | 2D cross product; the sign is the orientation test between the vectors. |

```lua
local side = vec2.cross(self.dir, to_player)   -- + or -
```

### `vec2.angle(v)`

| | |
|---|---|
| **Signature** | `vec2.angle(v) -> number` |
| **Parameters** | `v` — `Vec2` — a Vec2 table |
| **Returns** | `number` — angle in radians |
| **Description** | Angle of a single vector in radians, relative to +X. Computed as `atan2(y, x)` so it is defined for every vector including the zero one. |

```lua
local heading = vec2.angle(self.vel)
```

### `vec2.angle_between(a, b)`

| | |
|---|---|
| **Signature** | `vec2.angle_between(a, b) -> number` |
| **Parameters** | `a` — `Vec2` — first vector |
| | `b` — `Vec2` — second vector |
| **Returns** | `number` — signed angle in (-pi, pi]; positive is clockwise |
| **Description** | Signed angle from `a` to `b` in radians. |

```lua
local turn = vec2.angle_between(self.dir, to_target)
```

### `vec2.rotate(v, radians)`

| | |
|---|---|
| **Signature** | `vec2.rotate(v, radians) -> Vec2` |
| **Parameters** | `v` — `Vec2` — vector to rotate |
| | `radians` — `number` — rotation angle in radians (positive = clockwise) |
| **Returns** | `Vec2` — the rotated vector |
| **Description** | Rotates a vector by an angle. |

```lua
local aim = vec2.rotate(vec2.new(1, 0), math.deg_to_rad(30))
```

### `vec2.perpendicular(v)`

| | |
|---|---|
| **Signature** | `vec2.perpendicular(v) -> Vec2` |
| **Parameters** | `v` — `Vec2` — a Vec2 table |
| **Returns** | `Vec2` — the perpendicular vector (90-degree clockwise rotation) |
| **Description** | The 90-degree rotation of a vector: a wall normal from a direction. |

```lua
local normal = vec2.perpendicular(vec2.normalized(self.edge))
```

### `vec2.clamp_length(v, max_len)`

| | |
|---|---|
| **Signature** | `vec2.clamp_length(v, max_len) -> Vec2` |
| **Parameters** | `v` — `Vec2` — vector to clamp |
| | `max_len` — `number` — maximum length |
| **Returns** | `Vec2` — the capped vector |
| **Description** | Caps the **length** of a vector (direction preserved). |

```lua
self.vel = vec2.clamp_length(self.vel, self.max_speed)
```

### `vec2.clamped(v, max_len)`

| | |
|---|---|
| **Signature** | `vec2.clamped(v, max_len) -> Vec2` |
| **Parameters** | `v` — `Vec2` — vector to clamp |
| | `max_len` — `number` — maximum length |
| **Returns** | `Vec2` — the capped vector |
| **Description** | Godot's spelling of `clamp_length`; identical behaviour. |

```lua
self.push = vec2.clamped(self.push, 5)
```

### `vec2.reflect(d, n)`

| | |
|---|---|
| **Signature** | `vec2.reflect(d, n) -> Vec2` |
| **Parameters** | `d` — `Vec2` — incoming direction |
| | `n` — `Vec2` — unit normal of the surface |
| **Returns** | `Vec2` — the reflected direction |
| **Description** | Bounce: mirrors an incoming direction around a unit normal. The classic wall/paddle bounce; the normal is assumed normalized. |

```lua
-- the ball off a wall (normal points at the ball)
self.vel = vec2.reflect(self.vel, vec2.new(1, 0))
```

### `vec2.from_angle(radians)`

| | |
|---|---|
| **Signature** | `vec2.from_angle(radians) -> Vec2` |
| **Parameters** | `radians` — `number` — angle in radians |
| **Returns** | `Vec2` — a unit vector pointing at the given angle |
| **Description** | Unit vector at an angle (Godot's `Vector2.from_angle`). |

```lua
local muzzle = vec2.from_angle(actor.get_rotation(self))
```

---

## `rand`

Deterministic random numbers. All draws come from one shared sequence stored in the engine context, restarted by [`rand.seed`](#randseed). The same seed replays the same draws, which is what makes a bug report reproducible.

### `rand.seed(n)`

| | |
|---|---|
| **Signature** | `rand.seed(n)` |
| **Parameters** | `n` — `integer` — seed value; any integer (negative values are fully supported) |
| **Returns** | *(nothing)* |
| **Description** | Restarts the random sequence so the same seed replays the same draws. Deterministic by construction. |

```lua
rand.seed(1234)          -- from here on, everything is reproducible
local d1 = rand.float(0, 100)
rand.seed(1234)
local d2 = rand.float(0, 100)   -- d1 == d2, every time
```

### `rand.float(lo, hi)`

| | |
|---|---|
| **Signature** | `rand.float(lo, hi) -> number` |
| **Parameters** | `lo` — `number` — inclusive lower bound |
| | `hi` — `number` — exclusive upper bound |
| **Returns** | `number` — a random number in `[lo, hi)` |
| **Description** | A uniform float in `[lo, hi)`. Both bounds are required. |

```lua
local jitter = rand.float(-10, 10)   -- spread an object a little
```

### `rand.range(lo, hi)`

| | |
|---|---|
| **Signature** | `rand.range(lo, hi) -> number` |
| **Parameters** | `lo` — `number` — inclusive lower bound |
| | `hi` — `number` — exclusive upper bound |
| **Returns** | `number` — a random number in `[lo, hi)` |
| **Description** | The Godot/Unity spelling of `rand.float`; identical behaviour. |

```lua
local damage = rand.range(8, 14)   -- 8..13.99
```

### `rand.int(lo, hi)`

| | |
|---|---|
| **Signature** | `rand.int(lo, hi) -> integer` |
| **Parameters** | `lo` — `integer` — inclusive lower bound |
| | `hi` — `integer` — inclusive upper bound |
| **Returns** | `integer` — a random integer in `[lo, hi]`, both ends inclusive |
| **Description** | A uniform integer in `[lo, hi]`. If `lo > hi` the bounds are swapped automatically (a forgiving error recovery). |

```lua
local roll = rand.int(1, 6)   -- a d6; 1 and 6 are both reachable
```

### `rand.chance(p)`

| | |
|---|---|
| **Signature** | `rand.chance(p) -> boolean` |
| **Parameters** | `p` — `number` — probability, 0..1 |
| **Returns** | `boolean` — true about `p` of the time |
| **Description** | True with probability `p`. `p <= 0` never fires, `p >= 1` always does. |

```lua
if rand.chance(0.25) then   -- a 25% critical hit
  self.damage = self.damage * 2
end
```

### `rand.sign()`

| | |
|---|---|
| **Signature** | `rand.sign() -> number` |
| **Parameters** | *(none)* |
| **Returns** | `number` — -1 or +1 |
| **Description** | Returns -1 or +1 with equal probability. |

```lua
actor.move_by(self, rand.sign() * 100 * dt, 0)   -- coin-flip drift
```

### `rand.gauss(mu, sigma)`

| | |
|---|---|
| **Signature** | `rand.gauss(mu, sigma) -> number` |
| **Parameters** | `mu` — `number` — mean (centre of the bell) |
| | `sigma` — `number` — standard deviation (spread) |
| **Returns** | `number` — a sample from N(mu, sigma^2) |
| **Description** | A normal-distributed sample; most values land near `mu`. |

```lua
-- enemy accuracy: mostly on target, occasionally off by a lot
local spread = rand.gauss(0.0, 3.0)
```

### `rand.choice(table)`

| | |
|---|---|
| **Signature** | `rand.choice(table) -> any` |
| **Parameters** | `table` — `any` — array-like Lua table |
| **Returns** | `any` — one element of the table, or nil if empty |
| **Description** | Picks one element of an array table at random. Pushed by reference (the element itself), not copied. |

```lua
local drops = { "coin", "gem", "potion" }
local drop = rand.choice(drops)
```

### `rand.shuffle(table)`

| | |
|---|---|
| **Signature** | `rand.shuffle(table) -> table` |
| **Parameters** | `table` — `any` — array-like Lua table |
| **Returns** | `any` — the same table, shuffled |
| **Description** | Shuffles an array table in place (Fisher-Yates, walking high to low for unbiasedness) and returns the same table so it can chain. |

```lua
local deck = rand.shuffle({ 1, 2, 3, 4, 5 })
local top = deck[1]
```

---

## `noise`

Procedural noise. Stateless per call: the seed is an argument (or set once by [`noise.seed`](#noiseseed)), so terrain and weather can use different fields concurrently.

### `noise.seed(n)`

| | |
|---|---|
| **Signature** | `noise.seed(n)` |
| **Parameters** | `n` — `integer` — seed value |
| **Returns** | *(nothing)* |
| **Description** | Sets the default seed every later `noise.*` call uses unless it passes one explicitly. The same seed regenerates the same world every run. |

```lua
noise.seed(7)   -- the same seed regenerates the same world every run
```

### `noise.value(x, y)`

| | |
|---|---|
| **Signature** | `noise.value(x, y) -> number` |
| **Parameters** | `x` — `number` — sample x |
| | `y` — `number` — sample y |
| **Returns** | `number` — noise sample in [-1, 1] |
| **Description** | 2D value noise. Cheap; shows a faint grid when sampled far apart. |

```lua
local h = noise.value(px * 0.05, py * 0.05)   -- terrain height
```

### `noise.perlin(x, y)`

| | |
|---|---|
| **Signature** | `noise.perlin(x, y) -> number` |
| **Parameters** | `x` — `number` — sample x |
| | `y` — `number` — sample y |
| **Returns** | `number` — noise sample in [-1, 1] |
| **Description** | 2D Perlin gradient noise. The smooth default for terrain. |

```lua
local h = noise.perlin(px * 0.02, py * 0.02)
```

### `noise.simplex(x, y)`

| | |
|---|---|
| **Signature** | `noise.simplex(x, y) -> number` |
| **Parameters** | `x` — `number` — sample x |
| | `y` — `number` — sample y |
| **Returns** | `number` — noise sample in [-1, 1] |
| **Description** | 2D simplex noise. No axis bias, so it stays even along circles. |

```lua
-- a wander angle that stays isotropic instead of biasing along the axes
self.heading = noise.simplex(self.t * 0.1, self.seed) * math.pi * 2
```

### `noise.fbm(x, y, octaves, basis)`

| | |
|---|---|
| **Signature** | `noise.fbm(x, y, octaves, basis) -> number` |
| **Parameters** | `x` — `number` — sample x |
| | `y` — `number` — sample y |
| | `octaves` — `integer` — how many layers; clamped to 12 (default 4) |
| | `basis` — `string` — `"value"`, `"perlin"` or `"simplex"` (default `"perlin"`) |
| **Returns** | `number` — combined noise in [-1, 1] |
| **Description** | Fractal Brownian motion: several octaves of a base noise, each finer and weaker. |

```lua
-- rolling hills: detail at several scales, not one
local h = noise.fbm(px * 0.01, py * 0.01, 5)
```

### `noise.ridged(x, y, octaves, basis)`

| | |
|---|---|
| **Signature** | `noise.ridged(x, y, octaves, basis) -> number` |
| **Parameters** | Same as [`noise.fbm`](#noisefbm) |
| **Returns** | `number` — ridge height in [0, 1] |
| **Description** | Ridged multifractal: sharp crests where the noise crosses zero. |

```lua
-- mountain silhouettes instead of rolling noise
local ridge = noise.ridged(px * 0.01, py * 0.01, 6)
```

---

## `sm`

Declarative state machines. One mechanism, every case: the same seven calls declare an enemy's AI, the player's own states (idle/run/jump/dash), a spawner, a UI screen, and the game flow — only the declaring script differs.

All `sm` methods are called on `self` (the behavior's `self` table). Every failure path returns `nil`/`false` rather than raising a Lua error — a mis-declared transition degrades to a machine that never leaves its initial state, which is visible and debuggable, instead of a frame-killing error.

### `sm.add_state(self, name, hooks)`

| | |
|---|---|
| **Signature** | `self:sm_add_state(name, hooks) -> boolean` |
| **Parameters** | `self` — `Actor` |
| | `name` — `string` — state name, unique within the machine |
| | `hooks` — `table` — (default `{}`) table with optional `enter`, `update`, `exit` functions |
| **Returns** | `boolean` — true when the state was declared |
| **Description** | Declares a state and its optional `enter`/`update`/`exit` callbacks, creating this actor's machine on first use. The machine is created lazily: a script that declares zero states has no business owning one. |

```lua
self:sm_add_state("idle", {
  enter = function(self) self.wait = 1.0 end,
  update = function(self, dt) self.wait = self.wait - dt end,
  exit  = function(self) log.info("leaving idle") end,
})
```

### `sm.add_transition(self, from, event, to)`

| | |
|---|---|
| **Signature** | `self:sm_add_transition(from, event, to)` |
| **Parameters** | `self` — `Actor` |
| | `from` — `string` — state the transition starts in |
| | `event` — `string` — event name that triggers it |
| | `to` — `string` — state to enter |
| **Returns** | *(nothing)* |
| **Description** | Declares a transition: when `event` is fired while in `from`, the machine moves to `to`. |

```lua
self:sm_add_transition("idle", "see_player", "chase")
self:sm_add_transition("chase", "in_range", "attack")
```

### `sm.set_initial(self, name)`

| | |
|---|---|
| **Signature** | `self:sm_set_initial(name)` |
| **Parameters** | `self` — `Actor` |
| | `name` — `string` — state to start in |
| **Returns** | *(nothing)* |
| **Description** | Sets the state entered when the machine starts. Optional: the first declared state is the default. |

```lua
self:sm_set_initial("idle")   -- optional: the first declared state is the default
```

### `sm.fire(self, event)`

| | |
|---|---|
| **Signature** | `self:sm_fire(event)` |
| **Parameters** | `self` — `Actor` |
| | `event` — `string` — event name |
| **Returns** | *(nothing)* |
| **Description** | Requests a transition. The transition is applied before the next `update`, so firing from inside a callback cannot re-enter the machine mid-traversal. The last event in a frame wins. |

```lua
if actor.distance_to(self, player) < 300 then
  self:sm_fire("see_player")   -- takes effect next tick
end
```

### `sm.set_state(self, name)`

| | |
|---|---|
| **Signature** | `self:sm_set_state(name)` |
| **Parameters** | `self` — `Actor` |
| | `name` — `string` — state to enter now |
| **Returns** | *(nothing)* |
| **Description** | Jumps to a state immediately, running `exit` on the current one and `enter` on the target. Used when a script calls from inside a callback and cannot wait for the next tick. |

```lua
self:sm_set_state("attack")   -- from inside a callback: no one-frame gap
```

### `sm.state(self)`

| | |
|---|---|
| **Signature** | `self:sm_state() -> string` |
| **Parameters** | `self` — `Actor` |
| **Returns** | `string` — the current state name; empty before the first tick |
| **Description** | Returns the active state's name. |

```lua
log.info("enemy is: " .. self:sm_state())
```

### `sm.is_in(self, name)`

| | |
|---|---|
| **Signature** | `self:sm_is_in(name) -> boolean` |
| **Parameters** | `self` — `Actor` |
| | `name` — `string` — state name to test |
| **Returns** | `boolean` — true when the active state is `name` |
| **Description** | Returns true when the machine is currently in the named state. |

```lua
if self:sm_is_in("attack") then self.hitbox_on = true end
```

---

## `physics`

World-level queries against the physics simulation (Box2D behind the engine's
port). The rule that matters most is **gameplay writes the component, never the
solver** — see [`actor.set_linear_velocity`](#actorset_linear_velocityself-vx-vy)
and [`actor.apply_impulse`](#actorapply_impulseself-ix-iy).

### `physics.cast_ray(x1, y1, x2, y2)`

| | |
|---|---|
| **Signature** | `physics.cast_ray(x1, y1, x2, y2) -> boolean, number, number, number, number, number` |
| **Parameters** | `x1`, `y1` — `number` — segment start |
| | `x2`, `y2` — `number` — segment end |
| **Returns** | `boolean` — false when nothing blocks the segment |
| | `number` — how far along the segment the hit is, 0 at the start and 1 at the end |
| | `number`, `number` — hit point x, y |
| | `number`, `number` — surface normal x, y (points away from the surface) |
| **Description** | Casts a segment and reports what it hit, honouring the same [collision layers](ecs-collision-layers.md) the solver does — so a trigger volume on a non-colliding layer does not block the ray. Consumes nothing and allocates nothing. |

```lua
-- place a bullet impact where the shot lands
local hit, t, px, py, nx, ny = physics.cast_ray(self.px, self.py, tx, ty)
if hit then
  effects.spawn("impact", px, py)
  self.reflect = math.atan2(ny, nx)
end
```

### `physics.line_of_sight(x1, y1, x2, y2)`

| | |
|---|---|
| **Signature** | `physics.line_of_sight(x1, y1, x2, y2) -> boolean` |
| **Parameters** | `x1`, `y1`, `x2`, `y2` — `number` — the segment to test |
| **Returns** | `boolean` — true when nothing solid blocks the segment |
| **Description** | The cheap form of the question a turret, a guard or a camera AI asks every frame. Obeys the querying context's layers, so a sensor does not block sight. |

```lua
-- a turret that only fires what it can see
if physics.line_of_sight(self.px, self.py, player.px, player.py) then
  self.target_visible = true
end
```

### `physics.stats()`

| | |
|---|---|
| **Signature** | `physics.stats() -> table` |
| **Returns** | `table` — `pairs`, `pairs_per_body`, `tree_height`, `static_tree_height`, `solver_bytes`, `bodies`, `shapes`, `contacts`, `islands`, `sleeping`, `simulated`, `active_fraction`, `transitions` |
| **Description** | The difference between "physics is slow" and "physics is slow because 1 900 of your bodies are awake and in contact". Everything in it is a measurement, so it is safe to poll every frame from a debug overlay — it allocates one small table, which is why it is not something to call from a hot gameplay path by accident. |

```lua
-- "why is this scene slow? start here."
local s = physics.stats()
if s.pairs_per_body > 8 then
  -- the broadphase is no longer rejecting pairs: something is awake that
  -- should not be. Look at sleeping and simulated.
  log.info("pairs/body " .. s.pairs_per_body .. ", sleeping " .. s.sleeping)
end
```

### `physics.set_view(cx, cy, half_w, half_h, enabled)`

| | |
|---|---|
| **Signature** | `physics.set_view(cx, cy, half_w, half_h, enabled)` |
| **Parameters** | `cx`, `cy` — `number` — view centre in world units |
| | `half_w`, `half_h` — `number` — half the view size, plus a margin |
| | `enabled` — `boolean` — false to fall back to distance tiers alone |
| **Description** | Tells the engine what the camera can see, which is what turns on physics view culling. A body off-screen costs nothing to simulate, and in 2D nothing can reveal it round a corner. Pass `false` for a server or a headless run, which has no camera and must simulate the whole world. |

```lua
-- once a frame, from the camera
physics.set_view(camera.cx, camera.cy, camera.half_w, camera.half_h, true)
```

### `physics.set_focus(x, y)`

| | |
|---|---|
| **Signature** | `physics.set_focus(x, y)` |
| **Parameters** | `x`, `y` — `number` — the focus point in world units |
| **Description** | Where the player is. Bodies are tiered by their distance to this point: exact shape near it, a circle proxy in the mid range, disabled beyond that. See [open world physics](physics-open-world.md). |

```lua
physics.set_focus(player.px, player.py)
```

### `actor.set_linear_velocity(self, vx, vy)`

| | |
|---|---|
| **Signature** | `actor.set_linear_velocity(self, vx, vy)` |
| **Parameters** | `self` — `Actor` |
| | `vx`, `vy` — `number` — velocity in units/second |
| **Returns** | *(nothing)* |
| **Description** | Sets the velocity outright and leaves the angular velocity alone. Written into the component, which the engine pushes into the solver every step — this is the way to move a body, whether it is a conveyor belt or a knockback. |

```lua
-- a conveyor belt, or a knockback
actor.set_linear_velocity(self, 0, -120)
```

### `actor.get_linear_velocity(self)`

| | |
|---|---|
| **Signature** | `actor.get_linear_velocity(self) -> number, number` |
| **Parameters** | `self` — `Actor` |
| **Returns** | `number`, `number` — velocity x and y in units/second |
| **Description** | The velocity the solver has for this actor. Because the engine writes the component's value down and reads the solver's back up each step, this is the authoritative momentum — not whatever gameplay last wrote. |

```lua
local vx, vy = actor.get_linear_velocity(self)
self.speed = math.sqrt(vx * vx + vy * vy)
```

### `actor.apply_impulse(self, ix, iy)`

| | |
|---|---|
| **Signature** | `actor.apply_impulse(self, ix, iy)` |
| **Parameters** | `self` — `Actor` |
| | `ix`, `iy` — `number` — impulse (mass × units/second) |
| **Returns** | *(nothing)* |
| **Description** | An instantaneous push at the centre of mass, which is the "jump" primitive: applied at the centre it cannot spin the body, so a jump goes where you aimed it. Wakes a sleeping actor, so a body asleep on a ledge can still jump. |

```lua
if input.is_action_pressed("jump") and self.on_floor then
  actor.apply_impulse(self, 0, -self.jump_impulse)
end
```

### `actor.is_awake(self)`

| | |
|---|---|
| **Signature** | `actor.is_awake(self) -> boolean` |
| **Parameters** | `self` — `Actor` |
| **Returns** | `boolean` — true while the body is still moving |
| **Description** | False once the body has stopped moving and the solver may put it to sleep. A sleeping body costs nothing to step, which is what makes a settled level affordable — the counter is `physics.stats().sleeping`. |

```lua
-- an actor asleep on a ledge must still be able to jump
if input.is_action_pressed("jump") and not actor.is_awake(self) then
  actor.apply_impulse(self, 0, -self.jump_impulse)
end
```

---

## `world`

World-level queries that are not about a single actor.

### `world.nearby(self, x, y, radius, fn)`

| | |
|---|---|
| **Signature** | `world.nearby(self, x, y, radius, fn)` |
| **Parameters** | `self` — `Actor` — the asking actor (excluded from results) |
| | `x` — `number` — centre x in world units |
| | `y` — `number` — centre y in world units |
| | `radius` — `number` — search radius in world units |
| | `fn` — `function` — visitor function called as `fn(other_self)`; must be a function (the binding returns early otherwise) |
| **Returns** | *(nothing)* |
| **Description** | Calls `fn(other_self)` for every actor whose position is within `radius` of `(x, y)`, excluding the caller. The visitor form (rather than returning a list) keeps the engine allocation-free: materializing an array would allocate per call. The spatial grid behind this is O(1) in the number of entities per query. |

```lua
-- "who is close enough to push me?"
world.nearby(self, self.px, self.py, 80, function(other)
  self.push = self.push + (other.px - self.px) * 0.01
end)
```

---

## `steer`

Steering behaviors using an accumulator pattern. Create one accumulator per actor with [`steer.at`](#steerat), add steering terms each frame, then call [`acc:apply`](#accapply) to get the final velocity.

**Key design principle:** every term is **normalized before it is weighted**. A target 500 units away and an obstacle 3 units away both contribute a unit vector scaled by their weight, so weights mean the same thing regardless of distance.

Only `world.nearby` (used by the flocking terms) crosses into C — everything else is pure Lua.

### `steer.at(x, y)`

| | |
|---|---|
| **Signature** | `steer.at(x, y) -> Accumulator` |
| **Parameters** | `x` — `number` — initial x position |
| | `y` — `number` — initial y position |
| **Returns** | `Accumulator` — a new steering accumulator |
| **Description** | Creates a new steering accumulator bound to a position. One per actor, reused across frames — zero allocation after the first. Named `at`, not `for` (`for` is a Lua keyword). |

```lua
local acc = steer.at(self.x, self.y)
```

### `acc:reset(x, y)`

| | |
|---|---|
| **Signature** | `acc:reset(x, y)` |
| **Parameters** | `x` — `number` — (optional) new x position |
| | `y` — `number` — (optional) new y position |
| **Returns** | `self` |
| **Description** | Resets the accumulator to zero force. Optionally updates the position. Call this at the start of each frame before adding terms. |

```lua
acc:reset(x, y)   -- reset and reposition
acc:reset()        -- reset in place
```

### `acc:seek(tx, ty, w)`

| | |
|---|---|
| **Signature** | `acc:seek(tx, ty, w)` |
| **Parameters** | `tx` — `number` — target x |
| | `ty` — `number` — target y |
| | `w` — `number` — (default 1) weight |
| **Returns** | `self` |
| **Description** | Adds a term that pulls the actor toward the target. |

```lua
acc:seek(target_x, target_y, 1.0)
```

### `acc:flee(tx, ty, w)`

| | |
|---|---|
| **Signature** | `acc:flee(tx, ty, w)` |
| **Parameters** | `tx` — `number` — threat x |
| | `ty` — `number` — threat y |
| | `w` — `number` — (default 1) weight |
| **Returns** | `self` |
| **Description** | Adds a term that pushes the actor away from the threat. |

```lua
acc:flee(enemy_x, enemy_y, 0.5)
```

### `acc:arrive(tx, ty, slow_radius, w)`

| | |
|---|---|
| **Signature** | `acc:arrive(tx, ty, slow_radius, w)` |
| **Parameters** | `tx` — `number` — target x |
| | `ty` — `number` — target y |
| | `slow_radius` — `number` — distance at which braking begins |
| | `w` — `number` — (default 1) weight |
| **Returns** | `self` |
| **Description** | Seek that brakes: full weight far away, fading to zero at the target so the actor decelerates instead of orbiting. |

```lua
acc:arrive(target_x, target_y, 50, 1.0)
```

### `acc:pursue(tx, ty, tvx, tvy, lead, w)`

| | |
|---|---|
| **Signature** | `acc:pursue(tx, ty, tvx, tvy, lead, w)` |
| **Parameters** | `tx` — `number` — target x |
| | `ty` — `number` — target y |
| | `tvx` — `number` — target velocity x |
| | `tvy` — `number` — target velocity y |
| | `lead` — `number` — prediction factor (0 = no lead, 1 = full lead) |
| | `w` — `number` — (default 1) weight |
| **Returns** | `self` |
| **Description** | Leads a moving target: aims where it will be, not where it is. Purely arithmetic on the target's velocity — no prediction model, no state. |

```lua
acc:pursue(player.x, player.y, player.vx, player.vy, 0.5, 1.0)
```

### `acc:evade(tx, ty, tvx, tvy, lead, w)`

| | |
|---|---|
| **Signature** | `acc:evade(tx, ty, tvx, tvy, lead, w)` |
| **Parameters** | `tx` — `number` — threat x |
| | `ty` — `number` — threat y |
| | `tvx` — `number` — threat velocity x |
| | `tvy` — `number` — threat velocity y |
| | `lead` — `number` — prediction factor |
| | `w` — `number` — (default 1) weight |
| **Returns** | `self` |
| **Description** | Flees from a moving threat, predicting its future position. |

```lua
acc:evade(bullet.x, bullet.y, bullet.vx, bullet.vy, 0.3, 1.0)
```

### `acc:wander(angle, radius, w)`

| | |
|---|---|
| **Signature** | `acc:wander(angle, radius, w)` |
| **Parameters** | `angle` — `number` — wander angle (from noise or other deterministic source) |
| | `radius` — `number` — wander circle radius |
| | `w` — `number` — (default 1) weight |
| **Returns** | `self` |
| **Description** | Deterministic wander: the heading comes from the caller (normally noise, which is seeded and reproducible), never from a clock or hidden random draw. |

```lua
local angle = noise.simplex(self.t * 0.1, self.seed) * math.pi * 2
acc:wander(angle, 100, 0.5)
```

### `acc:avoid(ox, oy, radius, tx, ty, w)`

| | |
|---|---|
| **Signature** | `acc:avoid(ox, oy, radius, tx, ty, w)` |
| **Parameters** | `ox` — `number` — obstacle x |
| | `oy` — `number` — obstacle y |
| | `radius` — `number` — avoidance radius |
| | `tx` — `number` — target x (for blending back toward path) |
| | `ty` — `number` — target y |
| | `w` — `number` — (default 1) weight |
| **Returns** | `self` |
| **Description** | Steers away from an obstacle without leaving the path: blends away from the obstacle but toward the target, so the actor slides around rather than reversing. |

```lua
acc:avoid(obstacle.x, obstacle.y, 80, target_x, target_y, 1.0)
```

### `acc:separate(radius, w)`

| | |
|---|---|
| **Signature** | `acc:separate(radius, w)` |
| **Parameters** | `radius` — `number` — separation radius |
| | `w` — `number` — (default 1) weight |
| **Returns** | `self` |
| **Description** | Pushes away from neighbors within `radius`. Uses `world.nearby` — the only C call in the steering module. |

```lua
acc:separate(50, 1.0)
```

### `acc:align(radius, w)`

| | |
|---|---|
| **Signature** | `acc:align(radius, w)` |
| **Parameters** | `radius` — `number` — alignment radius |
| | `w` — `number` — (default 1) weight |
| **Returns** | `self` |
| **Description** | Matches the average direction of neighbors within `radius`. Uses `world.nearby`. |

```lua
acc:align(100, 0.5)
```

### `acc:cohere(radius, w)`

| | |
|---|---|
| **Signature** | `acc:cohere(radius, w)` |
| **Parameters** | `radius` — `number` — cohesion radius |
| | `w` — `number` — (default 1) weight |
| **Returns** | `self` |
| **Description** | Moves toward the centroid of neighbors within `radius`. Uses `world.nearby`. |

```lua
acc:cohere(100, 0.5)
```

### `acc:apply(max_speed)`

| | |
|---|---|
| **Signature** | `acc:apply(max_speed) -> number, number` |
| **Parameters** | `max_speed` — `number` — maximum speed cap |
| **Returns** | `vx` — `number` — velocity x component |
| | `vy` — `number` — velocity y component |
| **Description** | Normalizes the accumulated force, caps it at `max_speed`, resets the accumulator, and returns the velocity. The accumulator is ready for the next frame. |

```lua
local vx, vy = acc:apply(self.max_speed)
actor.move_by(self, vx * dt, vy * dt)
```

---

## `audio`

The mixer. Every call reaches the one `Audio` the runtime owns through the
binding context — the same way `physics.*` reaches the solver — so the editor
and a test can each own one. With no system wired (a headless tool, a game with
`audio.enabled = false`) a call reports failure rather than reaching through
null: `play_file` returns nil, `is_playing` returns false, `stats()` returns an
empty table.

A **voice handle** is returned by the play functions and accepted by stop and the
live controls. It travels as light userdata, so keep it in a variable and never
arithmetic on it. A STALE handle is a no-op, never an error: the sound it named
is genuinely gone.

The full contract — the two threads, the bank's byte budget, the steal policy,
what may decode and when — is in [audio-system](../reference/audio-system.md).
Buses, solo and sends are in [audio-buses](../reference/audio-buses.md).

### `audio.play_file(path, opts?)`

| | |
|---|---|
| **Signature** | `audio.play_file(path, opts?) -> voice\|nil` |
| **Parameters** | `path` — `string` — sound file relative to the project root |
| | `opts` — `table` — `{ bus, bus_name, volume, pitch, max_distance, spread, loop, priority }`, all optional |
| **Returns** | a voice handle, or nil when it could not load |
| **Description** | Plays a sound at the LISTENER (non-positional: UI clicks, music, auditions). It may decode, so it is load-time/preview — gameplay should play a resolved slot (see `sound.play` and `SoundEmitter2D`). |

```lua
local boom = audio.play_file("assets/audio/boom.wav", { bus_name = "sfx", volume = 0.8 })
if boom then log.info("boom is playing") end
```

### `audio.play_stream(path, opts?)`

| | |
|---|---|
| **Signature** | `audio.play_stream(path, opts?) -> voice\|nil` |
| **Parameters** | `path` — `string` — sound file relative to the project root |
| | `opts` — `table` — same fields as `audio.play_file` |
| **Returns** | a voice handle, or nil when it could not open |
| **Description** | Like `play_file`, but STREAMED: only a small window is ever resident and the frame loop keeps it fed. This is the path for long music; `play_file` decodes the whole sound and is charged to the bank's byte budget in one go. |

```lua
local music = audio.play_stream("assets/music/theme.ogg", { loop = true, bus_name = "music" })
```

### `audio.stop(voice)`

| | |
|---|---|
| **Signature** | `audio.stop(voice)` |
| **Parameters** | `voice` — a handle from a play function |
| **Returns** | *(nothing)* |
| **Description** | Stops one playing sound. A stale handle is a no-op. |

```lua
audio.stop(boom)
```

### `audio.stop_all()`

| | |
|---|---|
| **Signature** | `audio.stop_all()` |
| **Returns** | *(nothing)* |
| **Description** | Stops every playing sound. The Play/Stop hook: leaves the mixer silent and exact, so a re-simulated frame re-triggers its own sounds instead of inheriting the old ones. |

```lua
audio.stop_all()
```

### `audio.set_volume(voice, volume)`

| | |
|---|---|
| **Signature** | `audio.set_volume(voice, volume)` |
| **Parameters** | `voice` — a handle |
| | `volume` — `number` — 1 is full; above 1 is allowed and soft-clipped |
| **Returns** | *(nothing)* |
| **Description** | Changes a playing sound's own volume, BEFORE bus gain. |

```lua
audio.set_volume(boom, 0.5)
```

### `audio.set_pitch(voice, pitch)`

| | |
|---|---|
| **Signature** | `audio.set_pitch(voice, pitch)` |
| **Parameters** | `voice` — a handle |
| | `pitch` — `number` — the resample ratio; 1 is original, 2 is an octave up |
| **Returns** | *(nothing)* |
| **Description** | Changes a playing sound's pitch. 0.8 is the usual "lower and slower". |

```lua
audio.set_pitch(boom, 0.8)
```

### `audio.is_playing(voice)`

| | |
|---|---|
| **Signature** | `audio.is_playing(voice) -> boolean` |
| **Parameters** | `voice` — a handle |
| **Returns** | `boolean` — true while the sound is audible |
| **Description** | Whether a voice is still playing. False for a stale handle and false when the system is absent. |

```lua
if not audio.is_playing(boom) then log.info("done") end
```

### `audio.set_master_volume(gain)`

| | |
|---|---|
| **Signature** | `audio.set_master_volume(gain)` |
| **Parameters** | `gain` — `number` — 1 is full |
| **Returns** | *(nothing)* |
| **Description** | Sets the master volume (bus 0). Applies to everything. |

```lua
audio.set_master_volume(0.6)
```

### `audio.set_listener(x, y, rotation?)`

| | |
|---|---|
| **Signature** | `audio.set_listener(x, y, rotation?)` |
| **Parameters** | `x` — `number` — ear position x |
| | `y` — `number` — ear position y |
| | `rotation` — `number` — radians; 0 (default) faces +x |
| **Returns** | *(nothing)* |
| **Description** | Where the ears are and which way they face. The rotation turns the stereo field: a sound to the world-east pans right when the ears face +x. The runtime sets this from the camera every frame, so a script only needs it to override. |

```lua
local px, py = actor.get_position(self)
audio.set_listener(px, py, 0)
```

### `audio.solo_bus(bus, solo)`

| | |
|---|---|
| **Signature** | `audio.solo_bus(bus, solo)` |
| **Parameters** | `bus` — bus name or id |
| | `solo` — `boolean` |
| **Returns** | *(nothing)* |
| **Description** | Solos or unsolos a bus. While any bus is soloed, every other bus except master is silent. Master is never a solo target — it is where the soloed signal ends up. |

```lua
audio.solo_bus("music", true)   -- listen to the music alone
audio.solo_bus("music", false)
```

### `audio.set_bus_send(bus, target, amount)`

| | |
|---|---|
| **Signature** | `audio.set_bus_send(bus, target, amount)` |
| **Parameters** | `bus` — source bus name or id |
| | `target` — destination bus name or id, or nil to clear |
| | `amount` — `number` — fraction of the source signal, 0..4 |
| **Returns** | *(nothing)* |
| **Description** | Routes part of a bus into another bus's gain path: a reverb or duck aux. One level only — a send of a send is not followed, which is what keeps the frame cost a fixed two passes over 16 buses. |

```lua
audio.set_bus_send("sfx", "reverb", 0.25)
audio.set_bus_send("sfx", nil)       -- clear it
```

### `audio.bus_gain(bus)`

| | |
|---|---|
| **Signature** | `audio.bus_gain(bus) -> number` |
| **Parameters** | `bus` — bus name (`"music"`) or id (number) |
| **Returns** | `number` — 0 when muted, otherwise the gain |
| **Description** | A bus's current gain. A name that resolves to nothing reads as 1 (full), which is what a project with no audio section wants. |

```lua
log.info("music is at " .. audio.bus_gain("music"))
```

### `audio.set_bus_volume(bus, gain)`

| | |
|---|---|
| **Signature** | `audio.set_bus_volume(bus, gain)` |
| **Parameters** | `bus` — bus name or id |
| | `gain` — `number` — 1 is full, clamped 0..10 |
| **Returns** | *(nothing)* |
| **Description** | Sets a bus gain. What a mixer panel's slider writes. The device applies it at the next buffer, so dragging a slider does not click. |

```lua
audio.set_bus_volume("music", 0.4)
```

### `audio.mute_bus(bus, muted)`

| | |
|---|---|
| **Signature** | `audio.mute_bus(bus, muted)` |
| **Parameters** | `bus` — bus name or id |
| | `muted` — `boolean` |
| **Returns** | *(nothing)* |
| **Description** | Mutes or unmutes a bus. Muted voices keep PLAYING and are simply silent, so unmuting resumes them instead of restarting them. Mute wins over solo. |

```lua
audio.mute_bus("sfx", true)
```

### `audio.buses()`

| | |
|---|---|
| **Signature** | `audio.buses() -> table` |
| **Returns** | an array of bus records, in bus order |
| **Description** | Every named bus as `{ name, id, gain, muted, solo, send_to, send_amount }`. This is what the mixer panel iterates, and why it needs no hard-coded channel list. |

```lua
for _, bus in ipairs(audio.buses()) do panel:add(bus.name, bus.gain) end
```

### `audio.stats()`

| | |
|---|---|
| **Signature** | `audio.stats() -> table` |
| **Returns** | a table of counters |
| **Description** | The engine's own numbers: `voices_active`, `voices_peak`, `xruns`, `commands_dropped`, `latency_ms`, `period_frames`, `sample_rate`, `channels`, `bank_bytes`, `bank_budget`. Everything is a measurement, so polling it every frame from a debug overlay is safe. |

```lua
local s = audio.stats()
if s.xruns > 0 then log.warn("audio is glitching: " .. s.xruns) end
```

---

## `sound`

This actor's `SoundEmitter2D`. Where `audio.*` is about sounds, `sound.*` is
about the EMITTER: the component says what the actor sounds like (a bank slot, a
bus, a gain, a radius) and survives a save and a hot-reload, while these bindings
are the verbs that turn it into a voice at the actor's transform.

The component, the placement rules and the asset hot-reload are in
[audio-emitters](../reference/audio-emitters.md).

### `sound.play(self, path?, opts?)`

| | |
|---|---|
| **Signature** | `sound.play(self, path?, opts?) -> voice\|nil` |
| **Parameters** | `self` — `Actor` |
| | `path` — `string` — optional: the sound file to load (may decode). Omit it to play the emitter's already-resolved slot, which is the frame-safe form |
| | `opts` — `table` — `{ bus, bus_name, volume, pitch, loop, max_distance, spread, priority }`; an ABSENT field keeps the component's value |
| **Returns** | a voice handle, or nil when there was nothing to play |
| **Description** | Plays this actor's emitter at its transform, so panning and attenuation follow the actor's position relative to the listener. Creates the emitter component if the actor does not have one. |

```lua
function M:start()
  BOOM = sound.play(self, "assets/audio/boom.wav", { volume = 0.8, max_distance = 600 })
end

function M:update(dt)
  -- frame-safe: no decode, one command push
  if not sound.is_playing(self) then sound.play(self) end
end
```

### `sound.stop(self)`

| | |
|---|---|
| **Signature** | `sound.stop(self)` |
| **Parameters** | `self` — `Actor` |
| **Returns** | *(nothing)* |
| **Description** | Stops the voice this emitter started. A no-op when the sound already ended, which is the normal case: the end travels on the `sound_finished` signal, not back into the component. |

```lua
sound.stop(self)
```

### `sound.set_volume(self, volume)`

| | |
|---|---|
| **Signature** | `sound.set_volume(self, volume)` |
| **Parameters** | `self` — `Actor` |
| | `volume` — `number` — 1 is full |
| **Returns** | *(nothing)* |
| **Description** | Sets the emitter's gain and applies it to the voice already playing. The component is the truth an inspector reads; the change is audible now. |

```lua
sound.set_volume(self, 0.5)
```

### `sound.set_pitch(self, pitch)`

| | |
|---|---|
| **Signature** | `sound.set_pitch(self, pitch)` |
| **Parameters** | `self` — `Actor` |
| | `pitch` — `number` — 1 is original |
| **Returns** | *(nothing)* |
| **Description** | Sets the emitter's resample ratio and applies it to the running voice. |

```lua
sound.set_pitch(self, 0.8)
```

### `sound.set_loop(self, on)`

| | |
|---|---|
| **Signature** | `sound.set_loop(self, on)` |
| **Parameters** | `self` — `Actor` |
| | `on` — `boolean` |
| **Returns** | *(nothing)* |
| **Description** | Makes the emitter loop (music, ambience). Takes effect on the NEXT play: a running voice keeps the flag it started with, because changing it mid-voice is a click at the loop point. Said out loud so a setter that appears to do nothing is not reported as a bug. |

```lua
sound.set_loop(self, true)
sound.play(self, "assets/audio/cave.ogg")
```

### `sound.set_radius(self, max_distance)`

| | |
|---|---|
| **Signature** | `sound.set_radius(self, max_distance)` |
| **Parameters** | `self` — `Actor` |
| | `max_distance` — `number` — world units; **0 is GLOBAL** (never attenuated, never panned) |
| **Returns** | *(nothing)* |
| **Description** | How far this sound carries. Next play, not the running one: placement is computed when the voice starts. |

```lua
sound.set_radius(self, 900)   -- audible across half the arena
```

### `sound.set_spread(self, units)`

| | |
|---|---|
| **Signature** | `sound.set_spread(self, units)` |
| **Parameters** | `self` — `Actor` |
| | `units` — `number` — world units to full hard-pan |
| **Returns** | *(nothing)* |
| **Description** | How far off-centre the sound reaches hard left/right. Next play, like the radius it belongs with. |

```lua
sound.set_spread(self, 400)
```

### `sound.is_playing(self)`

| | |
|---|---|
| **Signature** | `sound.is_playing(self) -> boolean` |
| **Parameters** | `self` — `Actor` |
| **Returns** | `boolean` — true while this emitter's voice is audible |
| **Description** | Asks the SYSTEM rather than the component, and clears a stale handle when the two disagree. |

```lua
if not sound.is_playing(self) then sound.play(self) end
```

### `sound.describe(self)`

| | |
|---|---|
| **Signature** | `sound.describe(self) -> table` |
| **Parameters** | `self` — `Actor` |
| **Returns** | a table of the emitter's fields, or an EMPTY table when the actor has no emitter |
| **Description** | Every readable field: `bank_slot`, `path` (the name behind the slot, from the bank), `bus`, `volume`, `pitch`, `loop`, `max_distance`, `spread`, `autoplay`, `playing`, `tick`. This is what an inspector draws, which is why it returns a table instead of one getter per field — a field list in two places drifts. |

```lua
local d = sound.describe(self)
log.info(d.path .. " on bus " .. d.bus .. " at " .. d.volume)
```
