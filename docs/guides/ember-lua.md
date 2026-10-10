# Lua in Ember: The Engine API

> **Prerequisite:** This guide assumes you are comfortable with Lua fundamentals.
> If you are new to Lua, start with [Learning Lua: Language Fundamentals](learning-lua.md)
> first, then return here.

This guide is your companion to building gameplay with Ember's Lua API. We will
take our time. Every section explains not just *what* to call, but *why* the API
is shaped the way it is — because understanding the design decisions will help you
write better code and debug faster when something goes wrong.

---

## Table of Contents

1. [How Lua Fits into Ember's Architecture](#1-how-lua-fits-into-embers-architecture)
2. [The Behavior Lifecycle](#2-the-behavior-lifecycle)
3. [The API Modules](#3-the-api-modules)
   - [actor — Talking to Your Transform](#actor--talking-to-your-transform)
   - [input — Reading Player Intent](#input--reading-player-intent)
   - [vec2 — Vector Math](#vec2--vector-math)
   - [math — Scalar Math](#math--scalar-math)
   - [rand — Deterministic Randomness](#rand--deterministic-randomness)
   - [noise — Procedural Terrain and Texture](#noise--procedural-terrain-and-texture)
   - [sm — State Machines](#sm--state-machines)
   - [world — Spatial Queries](#world--spatial-queries)
   - [steer — Steering Behaviors](#steer--steering-behaviors)
4. [Bringing It All Together](#4-bringing-it-all-together)

---

## 1. How Lua Fits into Ember's Architecture

Before we write a single line of gameplay code, let's understand the world your
code lives in. Ember is a Zig engine. The renderer, the ECS, the physics — all
of that is fast, native code. Lua is the *scripting* layer: where you, the game
author, describe what actors do and how they respond to the player.

Think of it this way:

```
┌─────────────────────────────────────────────────────────┐
│                      Your Game                          │
│                                                         │
│   ┌─────────┐   ┌──────────┐   ┌──────────────────┐    │
│   │  input  │   │   rand   │   │      steer       │    │
│   └────┬────┘   └────┬─────┘   └────────┬─────────┘    │
│        │              │                  │              │
│   ┌────▼──────────────▼──────────────────▼──────────┐   │
│   │              LuaJIT VM (sandboxed)              │   │
│   │                                                 │   │
│   │   actor · vec2 · math · world · sm · noise     │   │
│   └────────────────────┬────────────────────────────┘   │
│                        │                                │
│   ┌────────────────────▼────────────────────────────┐   │
│ │              Ember Engine (Zig)                   │   │
│   │   ECS · Renderer · Platform · Signals           │   │
│   └─────────────────────────────────────────────────┘   │
└─────────────────────────────────────────────────────────┘
```

Your Lua scripts never touch the GPU, the filesystem, or the window. They call
into the engine through a small, safe API. The engine calls your scripts at the
right moments each frame. This two-way street is the whole architecture.

### The Sandbox

Ember runs your scripts inside a **sandboxed LuaJIT VM**. When the VM starts,
it removes every global that could reach outside the engine:

**Removed (dangerous):**
`io`, `os`, `package`, `debug`, `require`, `dofile`, `loadfile`, `load`,
`loadstring`, `collectgarbage`, `newproxy`, `module`, `rawequal`, `rawget`,
`rawset`, `gcinfo`

**Kept (safe):**
`assert`, `error`, `pcall`, `select`, `type`, `tostring`, `tonumber`, `ipairs`,
`pairs`, `next`, `unpack`, `setmetatable`, `getmetatable`, and `print`
(redirected to the engine log so your messages show up in the console).

This means a buggy script can crash *itself*, but never the game. A script that
tries to `require("os")` gets `nil` back — the global simply does not exist.

### The Script Cache

When you load a script, Ember compiles it into a **prototype table** — a table
containing the methods and default values your script returns. The engine
caches this prototype by name. When a behavior is attached to an actor, Ember
creates a fresh `self` table for that instance, sets its metatable's `__index`
to point at the prototype, and stamps the entity handle into it.

This indirection is the key to hot-reloading (more on that in a moment). All
instances of the same script share one prototype. Each instance has its own
`self` table for its own state.

### Hot-Reloading: Edit and Continue

This is one of Ember's most beloved features. When you edit a script and the
engine reloads it:

1. The source is recompiled into a **new** prototype.
2. The shared metatable's `__index` is repointed at the new prototype.
3. Every live `self` table keeps its own fields — your game state.
4. Cached method references are re-resolved.

The crucial detail: **`start` is not re-run.** Only the methods change. Your
`self.hp`, `self.vx`, and all other instance fields survive untouched. This is
why you can edit behavior code during play and see the change take effect
immediately without losing progress.

### Error Isolation

Every behavior call is wrapped in `pcall`. If your script raises an error, the
engine logs it and moves on:

```
[error] [behavior] behavior: attempt to index a nil value (field 'speed')
```

The broken behavior is skipped for that frame. Other behaviors continue. A
typo in one script never crashes the game or freezes the frame.

### Memory: A Dedicated Heap

Lua's heap is a **dedicated, tracked allocator** — separate from the engine's
frame arena. The engine drives an **incremental GC step** once per frame
(budgeted at 0.4 ms). A full GC during play is forbidden, and
`collectgarbage` is sandboxed away so scripts cannot force one.

What this means for you: you can allocate tables in Lua (they are cheap),
but you should still be mindful. The frame loop wants to be allocation-light.
We will come back to this throughout the guide.

---

## 2. The Behavior Lifecycle

Every behavior attached to an actor goes through the same lifecycle, driven
by the engine. Here is the order of operations within a single frame:

```
Frame Start
     │
     ▼
┌─────────────────────────┐
│ 1. State machines tick  │  sm.fire() requests are applied, state update() runs
└───────────┬─────────────┘
            │
            ▼
┌─────────────────────────┐
│ 2. Spatial grid rebuild │  world.nearby will see THIS frame's positions
└───────────┬─────────────┘
            │
            ▼
┌─────────────────────────┐
│ 3. update(dt) runs      │  Every live behavior, in a Lua-side driver loop
└───────────┬─────────────┘
            │
            ▼
┌─────────────────────────┐
│ 4. fixed_update(dt) runs│  At 60 Hz, regardless of render rate
└───────────┬─────────────┘
            │
            ▼
┌─────────────────────────┐
│ 5. Signals drain         │  Typed Zig listeners first, then on_signal in Lua
└───────────┬─────────────┘
            │
            ▼
┌─────────────────────────┐
│ 6. Dead instances swept  │  on_destroy fires, Lua refs released
└───────────┬─────────────┘
            │
            ▼
       Frame End
```

Let me walk through each step and explain *why* it happens in this order.

**Step 1 — State machines first.** A behavior's `update` might call `sm.state()`
or `sm.is_in()`. If the state machine has not ticked yet this frame, those
queries return stale information. By ticking machines *before* behaviors, a
behavior always sees the state its machine entered this frame — not the state
it left last frame.

**Step 2 — Grid rebuild.** A state machine might have moved actors. If
`world.nearby` ran before the rebuild, it would see last frame's positions.
Rebuilding after machines tick means queries see the current frame's layout.

**Step 3 — `update(dt)`.** This is where most gameplay code lives. `dt` is the
frame delta in seconds (e.g., `0.0167` at 60 FPS). It varies with frame rate.

**Step 4 — `fixed_update(dt)`.** This runs at a fixed 60 Hz regardless of the
render rate. It is for physics, collision resolution, and anything that needs
deterministic, frame-rate-independent simulation. The `dt` here is always `1/60`.

**Step 5 — Signals drain.** When `actor.emit(self, "took_damage")` was called
during `update`, the signal is queued. Now it drains: first any Zig-side
listeners (for engine-internal responses), then your `on_signal(name)` in Lua.

**Step 6 — Sweep.** If an entity was destroyed this frame, its behavior's
`on_destroy` fires once, and the Lua references are released. This cleanup
keeps the instance array dense and the frame allocation-free.

### Writing a Lifecycle Method

Every method is optional. Define only what you need:

```lua
local M = {}

function M:start()
  -- Called once, before the first update. Initialize per-instance state here.
  self.hp = 100
  self.speed = 200
end

function M:update(dt)
  -- Called every rendered frame. dt varies with frame rate.
  -- Read input, move the actor, check for hits.
end

function M:fixed_update(dt)
  -- Called at a fixed 60 Hz. dt is always 1/60.
  -- Physics, collision resolution, deterministic simulation.
end

function M:on_signal(name)
  -- Called when a signal this actor emitted drains.
  -- The event name is a string; branch on it.
end

function M:on_destroy()
  -- Called once, when the entity is about to be removed.
  -- Clean up external references, spawn a death effect, etc.
end

return M
```

A note on `self`: it is a table unique to this actor instance. Fields you set
in `start` (like `self.hp`) live on `self`. Methods and defaults come from
the prototype table `M` through the metatable's `__index`. This means you
can have 100 enemies all sharing the same `update` code but each with
different `self.hp` values.

---

## 3. The API Modules

Now we get to the heart of the guide. Each subsection covers one API module.
For each, we will discuss: what problem it solves, when to reach for it,
common patterns, mistakes to avoid, a complete runnable example, and a
"Try This" exercise.

---

### `actor` — Talking to Your Transform

**What problem it solves:** Your Lua behavior needs to read and write the
actor's position, rotation, and spatial relationships. The `actor` module is
the bridge between your script and the ECS Transform component.

**When to use it:** Every frame, for movement. For spatial queries between
actors (distance, direction). For click hit-testing via `get_half_size`.

#### Transforming the Actor

```lua
-- Read the current position (returns two numbers)
local x, y = actor.get_position(self)

-- Set the position absolutely
actor.set_position(self, 100, 200)

-- Move by a delta (relative to current position)
actor.move_by(self, dx, dy)

-- Move by a delta (same as move_by, but the name is more explicit)
actor.translate(self, dx, dy)

-- Rotation (radians, clockwise on screen)
local rot = actor.get_rotation(self)
actor.set_rotation(self, math.pi)
```

#### Why `move_by` Instead of `get_position` + `set_position`?

This is a deliberate performance design. Let me explain the reasoning.

A Lua-to-C binding call costs approximately 145 nanoseconds. That might sound
negligible, but it adds up fast:

- `get_position` + `set_position` = 2 C calls = ~290 ns
- Plus the Lua math to compute the new position = 1 more call = ~435 ns total
- `move_by(dx, dy)` = 1 C call = ~145 ns

For 10,000 actors at 60 FPS, that is the difference between 26 ms and 8 ms
of binding overhead per frame. Against a 2 ms budget for all behavior updates,
`move_by` is not just preferable — it is necessary.

There is a second reason: `get_position` pushes two return values onto the Lua
stack. `move_by` pushes nothing. Fewer stack operations means less work for
LuaJIT's tracing JIT to compile away.

**The rule of thumb:** If you are moving an actor every frame, use `move_by`.
If you need to read the position for a one-time calculation (e.g., a click
handler), `get_position` is fine.

#### Spatial Queries Between Actors

```lua
-- Distance to another actor (one C call, not three)
local d = actor.distance_to(self, other)

-- Distance to a bare point (a click, a waypoint)
local d = actor.distance_to_point(self, x, y)

-- Squared distance (no square root — for comparisons and sorting)
local d_sq = actor.distance_squared_to(self, other)

-- Radius test (squared on both sides, no sqrt at all)
local in_range = actor.is_within_radius(self, other, 100)
local point_in_range = actor.is_within_radius_of_point(self, x, y, 100)

-- Direction to another actor (unit vector, two return values)
local dx, dy = actor.direction_to(self, other)

-- Angle to another actor (radians, from +X axis, clockwise positive)
local angle = actor.angle_to(self, other)

-- Half-extents of the sprite (for click hit-testing)
local hw, hh = actor.get_half_size(self)
```

**Why these exist instead of doing it in Lua:** You could write:

```lua
local ax, ay = actor.get_position(self)
local bx, by = actor.get_position(other)
local d = vec2.dist(ax, ay, bx, by)
```

That works, but it costs 3 C calls (two `get_position` and one `vec2.dist`).
`actor.distance_to(self, other)` does the same thing in 1 C call, with the
two `world.get` lookups happening back-to-back on data that is already hot
in cache. For a flocking system with hundreds of agents each querying every
neighbour, this difference is enormous.

#### Signals

```lua
-- Emit a signal (listeners on the same name fire on the next drain)
actor.emit(self, "took_damage")
```

Signals are typed: the event name is the type. Listeners registered for the
same name fire in stable spawn order. The Lua side cannot see a payload (it
is empty); richer events get a typed payload from Zig emitters. This keeps
the Lua binding zero-allocation.

#### Complete Example: A Patrolling Guard

```lua
local M = {}

M.speed = 60
M.patrol_radius = 200
M.patrol_center_x = 400
M.patrol_center_y = 300
M.angle = 0

function M:start()
  self.x = self.patrol_center_x
  self.y = self.patrol_center_y
  self.angle = 0
  actor.set_position(self, self.x, self.y)
end

function M:update(dt)
  -- Advance the patrol angle
  self.angle = self.angle + dt * 0.8

  -- Compute target position on the patrol circle
  local target_x = self.patrol_center_x + math.cos(self.angle) * self.patrol_radius
  local target_y = self.patrol_center_y + math.sin(self.angle) * self.patrol_radius

  -- Compute direction to the target
  local dx = target_x - self.x
  local dy = target_y - self.y
  local dist = math.sqrt(dx * dx + dy * dy)

  if dist > 1 then
    -- Normalize and move
    local nx = dx / dist
    local ny = dy / dist
    actor.move_by(self, nx * self.speed * dt, ny * self.speed * dt)
  end

  -- Update our cached position (since move_by does not return anything)
  self.x, self.y = actor.get_position(self)
end

return M
```

**Key patterns in this example:**
- `move_by` for the actual movement (1 C call per frame)
- `get_position` only once at the end to update cached state (not per frame)
- `math.cos` / `math.sin` for circular patrol (scalar math, zero C calls)
- Normalization by hand (no vec2 allocation in the hot path)

#### Mistakes to Avoid

1. **Using `get_position` + `set_position` for per-frame movement.** As
   explained above, this costs 2x the binding calls. Use `move_by`.

2. **Assuming `move_by` returns the new position.** It does not. It is a
   void operation. If you need the position afterward, call `get_position`.

3. **Forgetting that `direction_to` returns a unit vector.** If you want to
   move toward something, you still need to multiply by speed and dt
   yourself.

4. **Using `distance_to` when you only need a comparison.** If you are
   comparing against a radius, use `is_within_radius` or compare
   `distance_squared_to` against `radius * radius`. Avoiding the square root
   is both faster and more precise.

#### Try This

1. Modify the patrol example to make the guard pause for one second at each
   quarter of the circle (0, π/2, π, 3π/2). Use `math.is_close` to check if
   the angle is near a pause point.

2. Add a second guard that patrols the same circle in the opposite
   direction. Give each its own `self.angle` and `self.speed`.

3. Use `actor.distance_to` to make the guard stop and "look at" the other
   guard when they are within 50 units. (You will need to use
   `actor.set_rotation` with `actor.angle_to`.)

---

### `input` — Reading Player Intent

**What problem it solves:** Your behavior needs to respond to what the
player is doing — pressing keys, clicking the mouse, moving a gamepad stick.
But you should never read physical keys directly. Instead, you read *named
actions* like "jump" or "move_left".

**When to use it:** At the top of `update`, to read the player's intent for
this frame. To detect edge-triggered events (just pressed) vs. held state.

#### Why Actions and Not Keys?

Imagine you wrote:

```lua
-- BAD: reading a physical key
if input.key_pressed("space") then
  -- jump
end
```

Now the player wants to remap jump to the "A" button on their gamepad. Or
they are on a laptop where the spacebar is broken. Or you want to support
both keyboard and gamepad. With direct key reads, you would need to change
every script.

With action-based input:

```lua
-- GOOD: reading a named action
if input.is_action_pressed("jump") then
  -- jump
end
```

The mapping from "jump" to a physical key/button lives in the engine's
input configuration, not in your scripts. Rebinding a control is a data
change, not a code change. The same script runs unchanged on keyboard,
gamepad, or touch.

#### The Three Functions

```lua
-- True ONLY on the frame the action went down (edge, no auto-repeat)
if input.is_action_pressed("jump") then
  -- This fires once per press, not every frame while held
end

-- True while the action is held (every frame)
if input.is_action_down("move_left") then
  -- This fires every frame the key is held
end

-- Signed axis from two opposing actions: -1, 0, or +1
local dx = input.get_axis("move_left", "move_right")
local dy = input.get_axis("move_up", "move_down")
```

**`is_action_pressed` vs `is_action_down`:** Think of a jump. You want the
character to jump once per press, not 60 times per second while the key is
held. Use `is_action_pressed` for discrete events (jump, shoot, interact).
Use `is_action_down` for continuous states (moving, aiming, sprinting).

**`get_axis`:** This is a convenience that combines two opposing actions into
a single signed value. Hold "move_left" and you get -1. Hold "move_right"
and you get +1. Hold both (a contradiction) and you get 0. Hold neither and
you get 0. This is the standard pattern for 2D movement.

#### Complete Example: Reading Input for Movement

```lua
local M = {}

M.speed = 200

function M:start()
  self.vx = 0
  self.vy = 0
end

function M:update(dt)
  -- Read the player's intent as signed axes
  local dx = input.get_axis("move_left", "move_right")
  local dy = input.get_axis("move_up", "move_down")

  -- Normalize diagonal movement so you don't move faster diagonally
  local len = math.sqrt(dx * dx + dy * dy)
  if len > 0 then
    dx = dx / len
    dy = dy / len
  end

  -- Compute target velocity
  local target_vx = dx * self.speed
  local target_vy = dy * self.speed

  -- Smoothly approach the target (frame-rate independent damping)
  self.vx = math.damp(self.vx, target_vx, 10, dt)
  self.vy = math.damp(self.vy, target_vy, 10, dt)

  -- Apply movement
  actor.move_by(self, self.vx * dt, self.vy * dt)

  -- Jump on the frame the action goes down
  if input.is_action_pressed("jump") then
    -- Apply jump impulse here
    log.info("Jump!")
  end
end

return M
```

**Key patterns:**
- `get_axis` for 2D movement (returns -1, 0, or +1)
- Normalization by hand (the scalar form, zero allocation)
- `math.damp` for smooth acceleration (frame-rate independent)
- `is_action_pressed` for the jump (edge-triggered, fires once)
- `actor.move_by` for the actual movement (1 C call)

#### Mistakes to Avoid

1. **Using `is_action_pressed` for movement.** It only fires on the frame
   the key goes down. Movement should use `is_action_down` or `get_axis`.

2. **Forgetting to normalize diagonal movement.** Without normalization,
   moving diagonally gives you `sqrt(2) * speed` — about 41% faster than
   moving in a straight line. Always normalize the input vector.

3. **Reading input in `fixed_update`.** Input is sampled once per frame.
   Reading it in `fixed_update` (which may run 0, 1, or multiple times per
   frame) will give inconsistent results. Read input in `update`, store the
   result on `self`, and consume it in `fixed_update` if needed.

#### Try This

1. Add a "sprint" action that doubles `self.speed` when held. Use
   `is_action_down("sprint")`.

2. Make the character face the direction they are moving. Use
   `actor.set_rotation` with `math.atan2(self.vy, self.vx)`.

3. Add a "dash" action that gives a burst of speed in the current movement
   direction, with a one-second cooldown. Use `is_action_pressed` and a
   `self.dash_cooldown` timer that decays with `dt`.

---

### `vec2` — Vector Math

**What problem it solves:** Games are full of 2D vectors — positions,
velocities, directions, offsets. The `vec2` module provides fast vector
operations. But there is a twist: there are *two forms* of every function,
and understanding when to use each is critical.

**When to use it:** Any time you need to compute with 2D vectors —
distances, directions, projections, reflections. Use the scalar form in
per-frame code. Use the table form for one-time calculations and storing
state.

#### The Two Forms

```lua
-- Table form: allocates a table, great for readability and stored state
local v = vec2.new(100, 200)       -- {x = 100, y = 200}
local w = vec2.new(50, 75)         -- {x = 50, y = 75}

-- Scalar form: takes and returns numbers, ZERO allocation
local dist = vec2.dist(100, 200, 50, 75)      -- four numbers
local dist_sq = vec2.dist_sq(v, w)             -- or two tables, it accepts both!
local len = vec2.length(3, 4)                 -- two numbers
local len_sq = vec2.length_sq(v)              -- or a table

-- Functions that return a table (they allocate — use sparingly in hot loops)
local n = vec2.normalized(3, 4)
local dir = vec2.direction(0, 0, 100, 100)
local lerped = vec2.lerp(v, w, 0.5)
local rotated = vec2.rotate(v, math.pi / 2)
local perp = vec2.perpendicular(v)
local reflected = vec2.reflect(v, w)
local from_angle = vec2.from_angle(math.pi / 4)

-- Functions that return a scalar (zero allocation, safe for hot loops)
local dot = vec2.dot(v, w)
local cross = vec2.cross(v, w)
local angle = vec2.angle(1, 0)
local angle_between = vec2.angle_between(v, w)

-- Clamp length (keeps direction, caps magnitude)
local clamped = vec2.clamp_length(v, 50)
local clamped2 = vec2.clamped(v, 50)  -- alias, same behavior
```

**Why two forms?** The scalar form exists because table allocation is not
free. Every `vec2.new` or `vec2.normalized` call allocates a new table in
Lua's heap. In a flocking system with 500 agents, that is 500 allocations
per frame just for vector temporaries. The scalar form (`vec2.dist(x1, y1,
x2, y2)`) takes and returns plain numbers — no tables, no allocation, no
GC pressure.

The table form exists because `local target = vec2.new(click_x, click_y)`
is much more readable than `local target_x, target_y = click_x, click_y`.

**The rule of thumb:** In `update` and `fixed_update`, prefer the scalar
form. In `start` or in a one-time setup function, use the table form for
clarity.

#### Complete Example: A Homing Missile

```lua
local M = {}

M.turn_rate = 3.0     -- radians per second
M.speed = 300
M.target = nil        -- will hold the target actor's self table

function M:start()
  self.target = nil
end

function M:set_target(target_self)
  self.target = target_self
end

function M:update(dt)
  if self.target == nil then return end

  -- Get positions (2 C calls, but only when we need to turn)
  local sx, sy = actor.get_position(self)
  local tx, ty = actor.get_position(self.target)

  -- Compute desired direction (scalar form, zero allocation)
  local dx = tx - sx
  local dy = ty - sy
  local dist = vec2.dist(sx, sy, tx, ty)

  -- If we are close enough, we hit
  if dist < 10 then
    log.info("Target hit!")
    return
  end

  -- Current heading from rotation
  local current_angle = actor.get_rotation(self)

  -- Desired heading to target
  local desired_angle = math.atan2(dy, dx)

  -- Turn toward the target at a limited rate
  local angle_diff = desired_angle - current_angle
  -- Normalize to [-pi, pi]
  while angle_diff > math.pi do angle_diff = angle_diff - math.pi * 2 end
  while angle_diff < -math.pi do angle_diff = angle_diff + math.pi * 2 end

  local max_turn = self.turn_rate * dt
  if angle_diff > max_turn then angle_diff = max_turn end
  if angle_diff < -max_turn then angle_diff = -max_turn end

  local new_angle = current_angle + angle_diff
  actor.set_rotation(self, new_angle)

  -- Move forward in the direction we face
  local vx = math.cos(new_angle) * self.speed
  local vy = math.sin(new_angle) * self.speed
  actor.move_by(self, vx * dt, vy * dt)
end

return M
```

**Key patterns:**
- `vec2.dist` for the distance check (scalar form, zero allocation)
- `math.atan2(dy, dx)` for the desired heading
- Manual angle normalization to [-pi, π] (because `atan2` returns [-π, π]
  but accumulated rotation can drift outside that range)
- `actor.move_by` for movement (1 C call)
- `actor.get_rotation` / `actor.set_rotation` to steer the heading

#### Mistakes to Avoid

1. **Using `vec2.new` inside `update`.** Every call allocates a table. Over
   a frame with thousands of actors, that is thousands of allocations. Use
   the scalar form (`vec2.dist(x1, y1, x2, y2)`) instead.

2. **Forgetting that `vec2.normalized(0, 0)` returns `(0, 0)`, not NaN.**
   This is by design — a NaN direction would silently poison every
   downstream multiply. The zero vector maps to zero, which is safe.

3. **Using `vec2.length` when you only need a comparison.** If you are
   comparing a distance against a radius, use `vec2.length_sq` (or
   `vec2.dist_sq`) and compare against `radius * radius`. No square root
   means faster and more precise.

4. **Using `vec2.clamped` vs `vec2.clamp_length` — they are the same.**
   `clamped` is the Godot spelling. `clamp_length` is the explicit spelling.
   Pick one and be consistent.

#### Try This

1. Add a "proximity fuse" to the missile: if the target is within 50 units,
   explode even if we have not hit it yet. Use `vec2.dist_sq` and compare
   against `50 * 50`.

2. Add a smoke trail: every 0.1 seconds, emit a signal or spawn a particle
   at the missile's position. Use a `self.timer` field that accumulates `dt`.

3. Make the missile lose track of the target if it gets more than 500 units
   away. When `self.target` is cleared, the missile should fly straight.

---

### `math` — Scalar Math

**What problem it solves:** Gameplay code is full of scalar math — clamping
health to [0, 100], smoothly interpolating a fade, wrapping an angle. The
`math` module provides a curated set of scalar functions that are total on
their domain (no NaN surprises) and allocation-free.

**When to use it:** Every frame, for every numeric computation that is not
vector math. Clamping, interpolation, thresholds, damping.

#### The Full Set

```lua
math.clamp(x, lo, hi)                    -- clamp x to [lo, hi]
math.min(a, b)
math.max(a, b)
math.abs(x)
math.sign(x)                             -- -1, 0, or 1 (zero maps to 0!)
math.floor(x)
math.ceil(x)
math.round(x)                            -- round half away from zero
math.fract(x)                            -- x - floor(x), always in [0, 1)
math.sqrt(x)
math.pow(a, b)
math.sin(x)                              -- radians
math.cos(x)                              -- radians
math.atan2(y, x)                         -- same argument order as stock Lua
math.lerp(a, b, t)                       -- linear interpolation
math.inverse_lerp(a, b, x)               -- (x - a) / (b - a)
math.remap(x, in_lo, in_hi, out_lo, out_hi)
math.smoothstep(edge0, edge1, x)         -- Hermite ease
math.step(edge, x)                       -- 0 if x < edge, 1 otherwise
math.move_toward(current, target, max_delta)  -- never overshoots
math.damp(current, target, smoothing, dt)     -- frame-rate independent damping
math.wrap(x, lo, hi)                     -- wrap around [lo, hi)
math.pingpong(x, length)                 -- 0 -> length -> 0 -> length ...
math.deg_to_rad(deg)
math.rad_to_deg(rad)
math.is_close(a, b, tolerance)           -- boolean: |a - b| <= tolerance
```

#### Why `math.round` and Not Banker's Rounding?

In standard Lua 5.4, `math.round` uses banker's rounding (round half to even).
This is a surprise for game developers who expect `round(0.5) == 1` and
`round(1.5) == 2`. Banker's rounding gives `round(0.5) == 0` and
`round(1.5) == 2`, which is "correct" for statistics but wrong for games.

Ember's `math.round` rounds half away from zero: `round(0.5) == 1`,
`round(-0.5) == -1`, `round(1.5) == 2`, `round(-1.5) == -2`. This is the
behavior game developers expect.

#### Why `math.damp` and Not Raw `lerp`?

This is one of the most important functions in the module. Here is the
problem it solves.

You want to smoothly move a value toward a target. The naive approach:

```lua
-- BAD: frame-rate dependent!
self.x = math.lerp(self.x, target_x, 0.1)
```

The problem: `lerp` with a fixed factor is *frame-rate dependent*. At
60 FPS, you apply the lerp 60 times per second. At 30 FPS, you apply it
30 times per second. The result converges at different rates, and at low
frame rates it can even oscillate or overshoot.

`math.damp` fixes this:

```lua
-- GOOD: frame-rate independent
self.x = math.damp(self.x, target_x, 10, dt)
```

The third argument is a *rate* (roughly, the time constant in seconds —
larger is slower). The fourth argument is `dt`. Internally, `damp` uses an
exponential curve that is mathematically guaranteed to be frame-rate
independent. The same `rate` and the same total elapsed time will produce
the same result regardless of how many frames elapsed.

**The rule of thumb:** Any time you would write `self.x = lerp(self.x,
target, k)` in `update`, replace it with `self.x = math.damp(self.x,
target, rate, dt)`. Your acceleration, fades, and smoothing will feel the
same at any frame rate.

#### Complete Example: Health Bar with Smooth Fade

```lua
local M = {}

function M:start()
  self.max_hp = 100
  self.hp = self.max_hp
  self.displayed_hp = self.max_hp  -- what the bar shows (smoothed)
  self.flash_timer = 0             -- red flash on damage
end

function M:update(dt)
  -- Smoothly approach the real HP value
  self.displayed_hp = math.damp(self.displayed_hp, self.hp, 8, dt)

  -- Decay the damage flash
  if self.flash_timer > 0 then
    self.flash_timer = math.max(0, self.flash_timer - dt)
  end

  -- Clamp HP to valid range (defensive)
  self.hp = math.clamp(self.hp, 0, self.max_hp)
end

function M:take_damage(amount)
  self.hp = self.hp - amount
  self.flash_timer = 0.3
  if self.hp <= 0 then
    self.hp = 0
    log.info("Player died!")
  end
end

function M:on_signal(name)
  if name == "heal" then
    self.hp = math.min(self.max_hp, self.hp + 20)
  end
end

return M
```

**Key patterns:**
- `math.damp` for the smooth health bar (frame-rate independent)
- `math.clamp` to keep HP in range (defensive programming)
- `math.max` to decay the flash timer
- `math.min` to cap healing at max HP

#### Mistakes to Avoid

1. **Using raw `lerp` for smoothing in `update`.** As explained above, this
   is frame-rate dependent. Use `math.damp` instead.

2. **Forgetting that `math.sign(0)` returns 0, not 1.** This is intentional
   and matches mathematical convention. Do not write `if math.sign(x) == 1`
   to test "positive or zero" — it will fail for zero. Use `x >= 0` instead.

3. **Using `math.fract` on negative numbers and being surprised.** `fract`
   is floor-based, so `fract(-3.25)` is `0.75`, not `-0.25`. This is the
   correct mathematical definition (the fractional part is always in [0, 1)),
   but it catches people who expect `-0.25`.

4. **Using `math.is_close` with a tolerance of 0.** Floating-point equality
   is fragile. Always use a small tolerance: `math.is_close(a, b, 0.001)`.

#### Try This

1. Add a "stamina" bar that drains when sprinting and regenerates when idle.
   Use `math.damp` for smooth drain and `math.clamp` to keep it in [0, max].

2. Use `math.remap` to map HP (0 to 100) to a bar fill (0 to 1). Then use
   `math.lerp` to smoothly animate the bar width.

3. Use `math.pingpong` to make a UI element bob up and down continuously.
   The element's y offset should be `math.pingpong(time, 10)` where `time`
   accumulates `dt`.

---

### `rand` — Deterministic Randomness

**What problem it solves:** Games need random numbers — dice rolls, spawn
positions, loot tables, AI decisions. But "random" in a game must be
*deterministic*: the same seed must produce the same sequence every time.
This is what makes bug reports reproducible ("here is the seed, here is the
replay") and what enables save/load of the full game state.

**When to use it:** Any time you need a random number in gameplay. Loot
drops, spawn positions, AI decisions, procedural generation (with noise),
critical hits.

#### Why Deterministic?

Imagine a player reports "the boss sometimes one-shots me, sometimes
doesn't." If your randomness is truly random, you can never reproduce the
bug. But if the RNG is seeded and deterministic, you can ask the player for
their seed, replay the exact same sequence, and see exactly what happened.

Ember's RNG is a PCG (Permuted Congruential Generator) — a modern,
well-regarded PRNG that is fast, has excellent statistical properties, and
serializes to two `u64` values (the state and the stream selector). This
means the save system can store the exact RNG state and restore it
perfectly.

#### The API

```lua
rand.seed(12345)                         -- restart the sequence
local f = rand.float(0, 1)                -- uniform float in [0, 1)
local i = rand.int(1, 6)                  -- dice roll, both ends inclusive
local b = rand.chance(0.3)                -- true with 30% probability
local g = rand.gauss(0, 1)                -- normal distribution
local s = rand.sign()                     -- -1 or +1
local elem = rand.choice({10, 20, 30})    -- pick from array
rand.shuffle(deck)                        -- Fisher-Yates, in place
```

**`rand.float(lo, hi)`** returns a uniform float in `[lo, hi)` — the lower
bound is inclusive, the upper bound is exclusive. This is the standard
half-open interval.

**`rand.int(lo, hi)`** returns a uniform integer in `[lo, hi]` — *both*
ends are inclusive. This is what you want for dice rolls (`rand.int(1, 6)`)
and array indexing (`rand.int(1, #array)`).

**`rand.chance(p)`** returns `true` with probability `p`. `p <= 0` never
fires, `p >= 1` always does. This is clamped so a misconfigured weight
cannot silently invert.

**`rand.gauss(mu, sigma)`** returns a sample from a normal (Gaussian)
distribution with mean `mu` and standard deviation `sigma`. Most values
land near `mu`; extreme values are rare. Use this for spread patterns,
accuracy checks, and anything where you want a bell curve.

#### Complete Example: Loot Table

```lua
local M = {}

function M:start()
  -- Seed the RNG so this behavior's draws are reproducible
  rand.seed(42)
end

function M:roll_loot()
  -- Roll for rarity: 60% common, 30% rare, 9% epic, 1% legendary
  local roll = rand.float(0, 1)

  local rarity
  if roll < 0.60 then
    rarity = "common"
  elseif roll < 0.90 then
    rarity = "rare"
  elseif roll < 0.99 then
    rarity = "epic"
  else
    rarity = "legendary"
  end

  -- Roll for the specific item within that rarity
  local items = {
    common = {"Rusty Dagger", "Cloth Armor", "Health Potion"},
    rare = {"Steel Sword", "Chain Mail", "Mana Potion"},
    epic = {"Enchanted Blade", "Plate Armor", "Elixir"},
    legendary = {"Excalibur", "Dragon Scale", "Philosopher's Stone"},
  }

  local pool = items[rarity]
  local item = rand.choice(pool)

  log.info("Rolled " .. rarity .. ": " .. item)
  return item
end

function M:roll_damage(base_damage, variance)
  -- Damage is base +/- a Gaussian-distributed variance
  local spread = rand.gauss(0, variance)
  local damage = math.max(1, math.floor(base_damage + spread))
  return damage
end

return M
```

**Key patterns:**
- `rand.seed` at the start to make the sequence reproducible
- `rand.float(0, 1)` with cumulative probability thresholds for weighted
  selection
- `rand.choice` to pick uniformly from a table
- `rand.gauss` for bell-curve variance
- `math.max(1, ...)` to ensure damage is at least 1 (clamping the result)

#### Mistakes to Avoid

1. **Calling `rand.seed` every frame.** This resets the sequence, so every
   frame gets the same "random" number. Call `rand.seed` once in `start`,
   or when you explicitly want to restart the sequence.

2. **Using `rand.int(1, 6)` for array indexing and forgetting that Lua arrays
   are 1-based.** `rand.int` is inclusive on both ends, so `rand.int(1, 6)`
   can return 1 or 6. This is correct for dice rolls. For array indexing,
   use `rand.int(1, #array)`.

3. **Using `rand.float(0, 1)` and comparing with `==`.** The probability of
   hitting an exact float is essentially zero. Use `<` for threshold checks.

4. **Expecting `rand.gauss` to be bounded.** It is not — it can return any
   value, though extreme values are rare. Clamp the result if you need a
   bounded range.

#### Try This

1. Add a "critical hit" system: 10% chance to double damage. Use
   `rand.chance(0.1)`.

2. Make a "mystery box" that gives a random amount of gold between 10 and
   100, but with a Gaussian distribution centered on 50 (so you usually
   get around 50, not uniformly between 10 and 100). Use `rand.gauss(50, 15)`
   and `math.clamp` to [10, 100].

3. Build a deck of 52 cards, shuffle it with `rand.shuffle`, and deal 5
   cards. Print them with `log.info`.

---

### `noise` — Procedural Terrain and Texture

**What problem it solves:** You want to generate terrain, clouds, or
texture patterns procedurally — without hand-crafting every pixel. Noise
functions give you smooth, natural-looking variation that is deterministic
(same seed + same coordinates = same output).

**When to use it:** Procedural terrain heightmaps, cloud patterns, wander
behaviors for AI, texture variation, any time you need "natural-looking
randomness" that is smooth and continuous.

#### Why Three Bases?

Not all noise is the same. Ember provides three bases, each with different
characteristics:

- **`noise.value`** — The cheapest. Value noise interpolates between random
  values at grid points. It has a faint square lattice when sampled far
  apart. Fine for terrain height when you want something cheap.

- **`noise.perlin`** — The classic gradient noise. Smooth, no directional
  artifacts. The workhorse for procedural terrain. This is the default for
  `fbm` and `ridged`.

- **`noise.simplex`** — Uses a triangular lattice instead of a square grid.
  This removes axis-aligned bias, making it isotropic (looks the same in all
  directions). The right choice for clouds, flow fields, and animal wander —
  anywhere the noise is sampled along circles or used for rotation.

#### The API

```lua
noise.seed(42)                           -- default seed for subsequent calls
local v = noise.value(x, y)               -- value noise, [-1, 1]
local p = noise.perlin(x, y)              -- Perlin noise, [-1, 1]
local s = noise.simplex(x, y)             -- Simplex noise, [-1, 1]
local f = noise.fbm(x, y, 4)              -- fractal Brownian motion, 4 octaves
local r = noise.ridged(x, y, 4)           -- ridged multifractal
```

**`noise.fbm`** (fractal Brownian motion) sums multiple octaves of a base
noise — each octave is twice the frequency and half the amplitude of the
previous. This creates natural-looking terrain with large hills and small
bumps. The result is normalized to stay in [-1, 1].

**`noise.ridged`** applies `1 - |noise|` and squares it. This folds the
noise at zero crossings, creating sharp ridges — perfect for mountain
silhouettes and coastlines. The result is in [0, 1].

Every function also accepts an optional trailing seed argument:

```lua
-- Two independent noise fields (terrain vs. clouds) without reseeding
local terrain = noise.perlin(x, y, 1234)
local clouds = noise.simplex(x, y, 5678)
```

#### Complete Example: Procedural Terrain Heightmap

```lua
local M = {}

function M:start()
  -- Seed the noise for reproducible terrain
  noise.seed(42)
end

function M:height_at(x, y)
  -- Base terrain: large rolling hills
  local hills = noise.fbm(x * 0.005, y * 0.005, 4, "perlin")

  -- Mountains: ridged noise for sharp peaks
  local mountains = noise.ridged(x * 0.002, y * 0.002, 5, "perlin")

  -- Flatten the mountains so they do not dominate
  local mountain_mask = noise.fbm(x * 0.001 + 1000, y * 0.001 + 1000, 2, "value")
  mountain_mask = math.smoothstep(0.2, 0.6, mountain_mask)

  -- Blend: mostly hills, with mountains where the mask is high
  local height = hills * (1 - mountain_mask) + mountains * mountain_mask

  -- Remap from [-1, 1] to [0, 100] for a usable height value
  return math.remap(height, -1, 1, 0, 100)
end

function M:is_water(x, y)
  return self:height_at(x, y) < 30
end

function M:is_mountain(x, y)
  return self:height_at(x, y) > 70
end

return M
```

**Key patterns:**
- `noise.fbm` for multi-octave terrain (large features + small detail)
- `noise.ridged` for mountain peaks (sharp ridges)
- A low-frequency mask to blend between biomes
- `math.smoothstep` to soften the mask transition
- `math.remap` to convert from [-1, 1] to a usable range

#### Mistakes to Avoid

1. **Using `noise.value` for terrain visible up close.** Value noise shows
   a faint square lattice when sampled far apart. Use `noise.perlin` or
   `noise.simplex` for terrain the player walks on.

2. **Expecting `noise.fbm` to be in [-1, 1] without normalization.** It is
   normalized by total amplitude, so it stays in [-1, 1] by design. But
   if you mix it with other terms, the result can leave that range. Use
   `math.clamp` or `math.remap` when you need a guaranteed range.

3. **Using too many octaves.** Each octave doubles the frequency and halves
   the amplitude. After 8-12 octaves, the detail is below the pixel level
   and just adds noise. Ember clamps to 12 octaves maximum. 4-6 is usually
   the sweet spot.

4. **Forgetting that noise is a pure function of (seed, x, y).** It has no
   internal state. The same call always returns the same value. This is
   what makes it deterministic — and also means you must vary `x` and `y`
   to get different values.

#### Try This

1. Add a "temperature" noise field that varies with latitude (y coordinate).
   Use it to make the poles cold and the equator hot.

2. Use `noise.simplex` to make a wander angle for an AI agent. The angle
   should smoothly change over time: `self.angle = noise.simplex(time * 0.1, 0) * math.pi`.

3. Combine `noise.fbm` for terrain with `noise.ridged` for rivers. Rivers
   should appear where the ridged noise is near zero (valleys between
   ridges).

---

### `sm` — State Machines

**What problem it solves:** Game entities have distinct behavioral states —
a player is "idle", "running", "jumping", or "attacking". An enemy is
"patrolling", "chasing", "attacking", or "fleeing". Managing these states
with boolean flags and nested `if` statements becomes a tangled mess fast.
A state machine gives you a declarative way to define states and the
transitions between them.

**When to use it:** Any entity with more than two behavioral modes. Player
controllers, enemy AI, UI screens, game flow (menu, playing, paused, game
over), spawners, cutscene sequences.

#### The Concept

A state machine is:

- A set of **states** (by name): "idle", "run", "jump"
- A set of **transitions**: "idle" + event "move" -> "run"
- A **current state**: which one is active right now

Each state has optional lifecycle callbacks:

- `enter`: runs once when entering the state
- `update`: runs every frame while in the state
- `exit`: runs once when leaving the state

#### The API

```lua
-- Declare a state with optional hooks
sm.add_state("idle", {
  enter = function() log.info("entering idle") end,
  update = function(dt) -- idle behavior end,
  exit = function() log.info("leaving idle") end,
})

sm.add_state("run", {
  update = function(dt) -- run behavior end,
})

-- Declare transitions: from -> event -> to
sm.add_transition("idle", "move", "run")
sm.add_transition("run", "stop", "idle")

-- Set the initial state
sm.set_initial("idle")

-- Fire an event (transition is applied before the next update)
sm.fire("move")

-- Query the current state
local state = sm.state(self)

-- Check if in a specific state
if sm.is_in(self, "run") then
  -- ...
end
```

#### Why `fire` Is Deferred

When you call `sm.fire("move")`, the transition does not happen
immediately. It is *queued* and applied at the start of the next tick,
before `update` runs. This is a deliberate design choice.

Imagine if `fire` were immediate and a state's `update` callback fired an
event. If `update` for "run" fires the "stop" event, an immediate `fire`
would call `exit("run")` and `enter("idle")` *inside* the `update` call
for "run". After the transition, the rest of "run"'s `update` would
continue executing — but the machine is now in "idle". This is a
re-entrancy bug that is extremely hard to debug.

By deferring the transition, `sm.fire` is safe to call from anywhere:
from `update`, from `enter`, from `exit`, from `on_signal`. The transition
is always applied at a clean boundary.

#### Complete Example: Player State Machine

```lua
local M = {}

function M:start()
  -- Declare states
  sm.add_state("idle", {
    enter = function()
      log.info("player entered idle")
    end,
    update = function(dt)
      -- Check for movement input
      local dx = input.get_axis("move_left", "move_right")
      local dy = input.get_axis("move_up", "move_down")
      if dx ~= 0 or dy ~= 0 then
        sm.fire("move")
      end
    end,
  })

  sm.add_state("run", {
    enter = function()
      log.info("player entered run")
    end,
    update = function(dt)
      -- Move the actor
      local dx = input.get_axis("move_left", "move_right")
      local dy = input.get_axis("move_up", "move_down")
      local len = math.sqrt(dx * dx + dy * dy)
      if len > 0 then
        actor.move_by(self, (dx / len) * self.speed * dt, (dy / len) * self.speed * dt)
      end

      -- Check for stop
      if dx == 0 and dy == 0 then
        sm.fire("stop")
      end

      -- Check for jump
      if input.is_action_pressed("jump") then
        sm.fire("jump")
      end
    end,
  })

  sm.add_state("jump", {
    enter = function()
      log.info("player jumped")
      -- Apply jump velocity
    end,
    update = function(dt)
      -- Simple gravity
      self.vy = self.vy + 800 * dt
      actor.move_by(self, 0, self.vy * dt)

      -- Land when back on the ground
      local _, y = actor.get_position(self)
      if y >= 0 then
        sm.fire("land")
      end
    end,
  })

  -- Declare transitions
  sm.add_transition("idle", "move", "run")
  sm.add_transition("run", "stop", "idle")
  sm.add_transition("run", "jump", "jump")
  sm.add_transition("jump", "land", "idle")

  -- Set initial state
  sm.set_initial("idle")
end

function M:update(dt)
  -- The state machine ticks before this, so sm.state() is current
  local state = sm.state(self)
  if state == "" then return end  -- machine has not started yet

  -- You can also do behavior that runs in ALL states
  self.anim_time = (self.anim_time or 0) + dt
end

return M
```

**Key patterns:**
- `sm.add_state` with `enter`, `update`, `exit` callbacks
- `sm.add_transition` to wire states together
- `sm.fire` to request transitions (safe to call from anywhere)
- `sm.state(self)` to query the current state
- `sm.is_in(self, "name")` for conditionals

#### Mistakes to Avoid

1. **Calling `sm.fire` and expecting the transition immediately.** It is
   deferred. If you need an immediate transition (e.g., from `on_signal`),
   use `sm.set_state(self, "name")` instead.

2. **Declaring the same state twice.** The engine rejects duplicate state
   names. If you need to re-declare (e.g., during hot-reload), the old
   state is kept.

3. **Firing an event that has no transition.** If no transition matches
   the event, nothing happens. This is silent — check your transition
   table if a state change is not firing.

4. **Putting gameplay code in `enter` that should be in `update`.**
   `enter` runs once. `update` runs every frame. If something should
   happen continuously, it goes in `update`.

#### Try This

1. Add an "attack" state that can be entered from "idle" or "run". It
   should play an animation and return to the previous state when done.
   (Hint: you will need to store the previous state on `self`.)

2. Add a "dash" state that gives a burst of speed in the current movement
   direction, then returns to "run" or "idle".

3. Add a "dead" state that cannot be exited. When HP reaches 0, fire "die".
   The "dead" state should have no outgoing transitions.

---

### `world` — Spatial Queries

**What problem it solves:** "Who is near me?" is the most common spatial
question in games. Flocking, area-of-effect attacks, trigger volumes,
proximity checks, squad AI — they all need to answer this question.
`world.nearby` answers it efficiently using a spatial grid.

**When to use it:** Any time you need to find actors within a radius of a
point. Flocking behaviors, AoE damage, trigger zones, nearest-enemy queries.

#### Why a Visitor Instead of a List?

You might expect `world.nearby` to return a list of actors:

```lua
-- NOT how it works:
local nearby = world.nearby(self, x, y, 100)  -- returns a list?
for _, other in ipairs(nearby) do
  -- ...
end
```

It does not work that way. Instead, you pass a function (a "visitor") and
the engine calls it for each actor in range:

```lua
-- The actual API:
world.nearby(self, x, y, 100, function(other, ox, oy)
  -- `other` is the nearby actor's self table
  -- `ox, oy` are that actor's world position
  local d = actor.distance_to(self, other)
  -- ...
end)
```

**Why?** Because materializing a list allocates. If 500 agents each call
`world.nearby` every frame, that is 500 table allocations per frame. The
visitor form processes each neighbour inline and allocates nothing.

#### Why a Grid?

A naive "who is near me" checks every actor in the world — O(n) per
question, O(n^2) for a flock. With 200 agents, that is 40,000 pair checks
per frame. A spatial grid bins actors into cells once per frame, so each
query only checks the ~9 cells the query radius touches — roughly O(1) in
the number of actors.

The grid is rebuilt once per frame, *before* behaviors run, so queries see
current positions. And it uses a counting-sort approach (not bucket lists)
so the rebuild allocates nothing.

#### Complete Example: Area-of-Effect Explosion

```lua
local M = {}

M.explosion_radius = 150
M.explosion_damage = 50

function M:explode()
  local x, y = actor.get_position(self)

  -- Find all actors within the blast radius
  world.nearby(self, x, y, self.explosion_radius, function(other, ox, oy)
    -- Falloff: full damage at center, zero at edge
    local dx = ox - x
    local dy = oy - y
    local dist = math.sqrt(dx * dx + dy * dy)
    local falloff = 1.0 - (dist / self.explosion_radius)

    -- Apply damage (you would call a take_damage method here)
    log.info("Hit actor at distance " .. tostring(dist) .. " for " .. tostring(self.explosion_damage * falloff))

    -- You can also emit a signal on the other actor
    -- actor.emit(other, "took_damage")
  end)

  -- Remove the explosion actor
  -- actor.emit(self, "destroy_me")
end

return M
```

**Key patterns:**
- `world.nearby(self, x, y, radius, visitor_fn)` — the visitor form
- The visitor receives `(other_self, other_x, other_y)` — the position
  comes with the actor, so you do not need a separate `actor.get_position`
  call (which would cost a C binding per neighbour)
- Falloff based on distance from center
- No list allocation

#### Mistakes to Avoid

1. **Calling `actor.get_position(other)` inside the visitor.** The visitor
   already receives the position as `ox, oy`. Use those. Calling
   `actor.get_position` would cost a C binding per neighbour — measured as
   the single largest cost in a flocking frame.

2. **Expecting `world.nearby` to include the caller.** It does not. The
   actor that calls `world.nearby` is always excluded from the results.

3. **Using `world.nearby` with a radius larger than the grid.** The grid
   has a finite extent (default 4096 units). Actors outside the grid are
   counted but not queryable. If your game world is larger, you need a
   bigger grid (configured at startup).

4. **Modifying the world inside the visitor.** If you destroy actors or
   move them significantly inside the visitor, the grid is now stale for
   the rest of the iteration. Queue your modifications and apply them
   after the visitor returns.

#### Try This

1. Add a "chain lightning" effect: when an actor is hit, it strikes the
   nearest actor within 100 units, which strikes the nearest within 100
   units, and so on, up to 5 jumps. Use `world.nearby` at each step.

2. Make a "fear aura" that pushes nearby actors away. Inside the visitor,
   compute the direction away from the aura center and apply a small
   `actor.move_by` to the other actor.

3. Add a "healing zone" that heals all actors within radius by 10 HP per
   second. Accumulate `dt` on `self` and apply healing proportional to
   `dt`.

---

### `steer` — Steering Behaviors

**What problem it solves:** Autonomous agents — enemies, NPCs, animals,
crowds — need to move in believable ways. They seek targets, flee threats,
avoid obstacles, flock together, and wander. Steering behaviors are the
standard solution: each behavior contributes a "force" vector, and the
forces are combined into a final velocity.

**When to use it:** Any autonomous agent. Enemy AI, NPC movement, crowd
simulation, animal behavior, any agent that moves itself based on its
environment.

#### The Accumulator Pattern

Steering uses an **accumulator**: you create one per actor, add steering
terms each frame, and then call `apply` to get the final velocity. The
accumulator is reused across frames — zero allocation after the first.

```lua
-- Create an accumulator (one per actor, reused across frames)
local acc = steer.at(x, y)

-- Each frame: reset, add terms, apply
acc:reset(x, y)
acc:seek(target_x, target_y, 1.0)
acc:flee(enemy_x, enemy_y, 0.5)
acc:arrive(target_x, target_y, 50, 1.0)   -- seek that brakes
acc:pursue(tx, ty, tvx, tvy, lead, 1.0)   -- lead a moving target
acc:evade(tx, ty, tvx, tvy, lead, 1.0)   -- flee a moving target
acc:wander(angle, radius, 1.0)            -- deterministic wander
acc:avoid(ox, oy, radius, tx, ty, 1.0)  -- steer around obstacle

-- Flocking (uses world.nearby, the only C call)
acc:separate(50, 1.0)                     -- push away from neighbors
acc:align(100, 0.5)                       -- match neighbor velocity
acc:cohere(100, 0.5)                      -- move toward neighbor centroid

-- Or all three in one neighbour pass (1 C call instead of 3):
acc:flock(100, 1.0, 0.5, 0.5)            -- separate, align, cohere

-- Apply: normalize, cap at max_speed, return velocity, reset accumulator
local vx, vy = acc:apply(max_speed)
actor.move_by(self, vx * dt, vy * dt)
```

#### Why Normalized Before Weighted

This is the single most important design principle in the steering module.
Every term is **normalized before it is weighted**:

- A target 500 units away contributes a unit vector * weight
- An obstacle 3 units away contributes a unit vector * weight

Both weights mean the same thing regardless of distance. Without this,
weights are distance-dependent and every behavior needs per-distance tuning
nobody can reason about. A weight of 1.0 means "this term contributes a
full-strength force in its direction" — whether the target is 5 units or
500 units away.

#### Why Pure Lua (Almost)

The classic Reynolds API is one C function per behavior — `seek`, `flee`,
`separate`, and so on. The problem: a Lua-to-C binding costs ~145 ns. A
flock with 6 steering calls per agent at 10k agents costs 8.7 ms — over
budget by 4x.

Ember's solution is a single accumulator written in **pure Lua**. Terms are
methods on a Lua table. `apply` does the normalize-and-clamp once. The
whole thing costs zero C bindings — except `world.nearby` (used by the
flocking terms), which crosses into C only when a behavior actually asks
for neighbours.

#### Complete Example: A Flocking Agent

```lua
local M = {}

function M:start()
  -- One accumulator per actor, reused across frames
  local x, y = actor.get_position(self)
  self.steer = steer.at(x, y)
  self.max_speed = 80
  self.max_force = 200
  self.wander_angle = rand.float(0, math.pi * 2)
end

function M:update(dt)
  local x, y = actor.get_position(self)
  local acc = self.steer

  -- Reset the accumulator
  acc:reset(x, y)

  -- Wander: deterministic, noise-driven heading
  self.wander_angle = self.wander_angle + rand.float(-1, 1) * dt * 3
  acc:wander(self.wander_angle, 80, 0.3)

  -- Flock: separate, align, cohere (one neighbour pass)
  acc:flock(60, 1.0, 0.5, 0.3)

  -- Apply: get velocity capped at max_speed
  local vx, vy = acc:apply(self.max_speed)
  actor.move_by(self, vx * dt, vy * dt)

  -- Face the direction of movement
  if vx ~= 0 or vy ~= 0 then
    actor.set_rotation(self, math.atan2(vy, vx))
  end
end

return M
```

**Key patterns:**
- `steer.at(x, y)` once in `start` (one allocation per actor, never freed)
- `acc:reset(x, y)` each frame to zero the force accumulator
- `acc:wander(angle, radius, weight)` for autonomous movement
- `acc:flock(radius, sep_w, align_w, cohere_w)` for group behavior (one
  `world.nearby` call instead of three)
- `acc:apply(max_speed)` to get the final velocity and reset
- `actor.move_by` for the actual movement (1 C call)

#### Mistakes to Avoid

1. **Creating a new accumulator every frame.** `steer.at` allocates a table.
   Create it once in `start` and store it on `self.steer`.

2. **Forgetting to call `acc:reset` each frame.** The accumulator sums
   forces. If you do not reset, forces accumulate frame over frame and
   the actor spins out of control.

3. **Using raw `acc:separate`, `acc:align`, `acc:cohere` when you need
   all three.** Each of those does its own `world.nearby` call. Use
   `acc:flock(radius, sep_w, align_w, cohere_w)` instead — it does all
   three in one neighbour pass.

4. **Expecting `acc:apply` to return a position.** It returns a *velocity*
   (capped at `max_speed`). You still need to multiply by `dt` and pass
   it to `actor.move_by`.

5. **Using steering for the player.** Steering is for *autonomous* agents.
   The player's movement should be driven by `input` directly.

#### Try This

1. Add a "predator" that the flock flees from. In `update`, check the
   distance to the predator and call `acc:flee(px, py, weight)` with a
   weight that increases as the predator gets closer.

2. Add obstacle avoidance: for each obstacle within a lookahead distance,
   call `acc:avoid(ox, oy, radius, target_x, target_y, weight)`. The
   actor should slide around the obstacle rather than reversing.

3. Add a "target" that the flock seeks. Use `acc:arrive(tx, ty,
   slow_radius, weight)` so the agents slow down as they approach instead
   of orbiting.

---

## 4. Bringing It All Together

Now let's build something that uses every module. This is a complete
player behavior that demonstrates how the modules work together:

```lua
local M = {}

-- Prototype defaults (shared across all instances)
M.speed = 200
M.max_hp = 100

function M:start()
  -- Per-instance state
  self.hp = self.max_hp
  self.vx = 0
  self.vy = 0
  self.invulnerable = 0
  self.anim_time = 0

  -- Create a steering accumulator for autonomous behaviors
  local x, y = actor.get_position(self)
  self.steer = steer.at(x, y)

  -- Declare a state machine
  sm.add_state("idle", {
    enter = function() log.info("player entered idle") end,
    update = function(dt)
      local dx = input.get_axis("move_left", "move_right")
      local dy = input.get_axis("move_up", "move_down")
      if dx ~= 0 or dy ~= 0 then
        sm.fire("move")
      end
    end,
  })

  sm.add_state("run", {
    enter = function() log.info("player entered run") end,
    update = function(dt)
      local dx = input.get_axis("move_left", "move_right")
      local dy = input.get_axis("move_up", "move_down")
      local len = math.sqrt(dx * dx + dy * dy)
      if len > 0 then
        -- Smooth acceleration
        local target_vx = (dx / len) * self.speed
        local target_vy = (dy / len) * self.speed
        self.vx = math.damp(self.vx, target_vx, 10, dt)
        self.vy = math.damp(self.vy, target_vy, 10, dt)
        actor.move_by(self, self.vx * dt, self.vy * dt)
      end

      if dx == 0 and dy == 0 then
        sm.fire("stop")
      end

      -- Check for nearby enemies
      local x, y = actor.get_position(self)
      world.nearby(self, x, y, 150, function(other, ox, oy)
        local d = math.sqrt((ox - x) * (ox - x) + (oy - y) * (oy - y))
        if d < 30 and self.invulnerable <= 0 then
          self.hp = self.hp - 10
          sm.fire("hurt")
          if self.hp <= 0 then
            log.info("player died!")
          end
        end
      end)
    end,
  })

  sm.add_state("hurt", {
    enter = function()
      self.invulnerable = 1.0
      log.info("player hurt!")
    end,
    update = function(dt)
      -- Brief invulnerability, then return
      self.invulnerable = self.invulnerable - dt
      if self.invulnerable <= 0 then
        sm.fire("recover")
      end
    end,
  })

  sm.add_transition("idle", "move", "run")
  sm.add_transition("run", "stop", "idle")
  sm.add_transition("idle", "hurt", "hurt")
  sm.add_transition("run", "hurt", "hurt")
  sm.add_transition("hurt", "recover", "idle")
  sm.set_initial("idle")
end

function M:update(dt)
  -- Decay invulnerability (runs in all states)
  if self.invulnerable > 0 then
    self.invulnerable = math.max(0, self.invulnerable - dt)
  end

  -- Animate
  self.anim_time = self.anim_time + dt
  if self.anim_time > 0.1 then
    self.anim_time = 0
    -- Cycle animation frame here
  end
end

function M:fixed_update(dt)
  -- Fixed 60 Hz tick: physics, collision resolution, etc.
  -- This runs at a fixed rate regardless of frame rate.
end

function M:on_signal(name)
  if name == "heal" then
    self.hp = math.min(self.max_hp, self.hp + 20)
    log.info("healed! hp=" .. tostring(self.hp))
  end
end

function M:on_destroy()
  log.info("player destroyed with " .. tostring(self.hp) .. " hp")
end

return M
```

### What This Example Demonstrates

- **Per-instance state** (`self.hp`, `self.vx`) set in `start`.
- **Prototype defaults** (`M.speed`, `M.max_hp`) shared across instances.
- **Action-based input** via `input.get_axis` and `input.is_action_pressed`.
- **Fused movement** via `actor.move_by` (1 C call per frame).
- **Damping** for smooth acceleration (`math.damp`).
- **State machine** with `sm.add_state`, `sm.add_transition`, `sm.fire`,
  and `sm.state`.
- **Spatial query** via `world.nearby` (visitor form, zero allocation).
- **Signal handling** via `on_signal`.
- **Steering accumulator** created in `start` (one allocation per actor).
- **Fixed update** for physics (decoupled from render).
- **Lifecycle** with `start`, `update`, `fixed_update`, `on_signal`,
  `on_destroy`.

### How the Modules Connect

Here is a map of how the modules work together:

```
input ──> update reads player intent
              │
              ▼
         actor.move_by (movement)
              │
              ▼
         world.nearby (spatial queries)
              │
              ▼
         steer (autonomous behaviors)
              │
              ▼
         sm (state machine decides what to do)
              │
              ▼
         rand (loot, damage variance)
              │
              ▼
         noise (procedural terrain, wander)
              │
              ▼
         vec2 / math (the math that ties it all together)
```

Every module has a job. The art of game scripting is combining them well.
The constraints — zero allocation in the frame loop, deterministic
randomness, normalized steering, action-based input — are not arbitrary.
They are the lessons learned from building games that run smoothly and
reproducibly. Keep them in mind, and your code will be fast, debuggable,
and a joy to work with.

---

For the autogenerated API stubs (for LuaLS/EmmyLua), see
[`meta/ember.lua`](https://github.com/jesusalcaladev/ember-engine/blob/main/meta/ember.lua).
