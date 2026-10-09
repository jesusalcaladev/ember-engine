# Lua in Ember: The Engine API

> **Prerequisite:** This guide assumes you are comfortable with Lua fundamentals.
> If you are new to Lua, start with [Learning Lua: Language Fundamentals](learning-lua.md)
> first, then return here.

This is the Ember-specific guide. It covers how the Ember engine integrates
with Lua, the full engine API, and a complete example tying everything
together.

---

## Table of Contents

1. [How Lua Integrates with Ember](#1-how-lua-integrates-with-ember)
2. [The Ember API in Depth](#2-the-ember-api-in-depth)
3. [Complete Example: A Player Behavior](#3-complete-example-a-player-behavior)

---

## 1. How Lua Integrates with Ember

### The VM and Sandbox

Ember creates a **LuaJIT** VM with a custom allocator (tracked separately from
the engine's frame arena). The VM is **sandboxed**: dangerous globals are
removed, and only the safe subset of standard libraries is available.

**Removed globals:** `io`, `os`, `package`, `debug`, `require`, `dofile`,
`loadfile`, `load`, `loadstring`, `collectgarbage`, `newproxy`, `module`,
`rawequal`, `rawget`, `rawset`, `gcinfo`.

**Kept globals:** `assert`, `error`, `pcall`, `select`, `type`, `tostring`,
`tonumber`, `ipairs`, `pairs`, `next`, `unpack`, `setmetatable`,
`getmetatable`, `print` (redirected to the engine log).

### The Script Cache

Scripts are loaded by name and cached. The cache maps:

```
name -> { prototype_ref, metatable_ref, id }
```

- **`prototype_ref`** -- a registry ref to the script's returned table.
- **`metatable_ref`** -- a registry ref to the shared metatable
  (`{__index = prototype}`).
- **`id`** -- a stable `u32` stored in the `Script` ECS component.

### Instantiation

When a behavior is attached to an actor:

1. A fresh `self` table is created with the shared metatable.
2. The entity handle is stamped into `self.__entity` as light userdata.
3. The `self` table is refed in the Lua registry (so it survives across
   frames).
4. Lifecycle method refs (`update`, `fixed_update`, etc.) are cached.
5. A `Script` component with the stable id is added to the entity.

### The Update Loop

The engine drives behaviors in this order each frame:

1. **State machines tick** (if any are attached).
2. **Spatial grid rebuilds** (so `world.nearby` sees current positions).
3. **`update(dt)` runs** on every live instance (via a Lua-side driver loop).
4. **`fixed_update(dt)` runs** on every live instance (at 60 Hz).
5. **Signals drain** (typed Zig listeners first, then `on_signal` in Lua).
6. **Dead instances are swept** (`on_destroy` fires, refs released).

### Hot-Reloading

When a script is reloaded:

1. The source is recompiled into a **new prototype**.
2. The shared metatable's `__index` is repointed at the new prototype.
3. Every live `self` table keeps its own fields (game state).
4. Cached method refs are re-resolved.

`start` is **not** re-run. Only the methods change. This is what makes
"edit the file and reload it" work without losing state.

### Error Isolation

Every behavior call is wrapped in `pcall`. A script error is logged and
counted, but never crashes the frame:

```
[error] [behavior] behavior: attempt to index a nil value (field 'speed')
```

The broken behavior is skipped for that frame; others continue.

### Memory Management

Lua's heap is a **dedicated, tracked allocator** (not the frame arena). The
engine drives an **incremental GC step** once per frame (budgeted at 0.4 ms).
A full GC during play is forbidden. `collectgarbage` is sandboxed away so
scripts cannot force a full collection.

---

## 2. The Ember API in Depth

### `actor` -- Per-Actor Methods

All `actor` methods take `self` as the first argument. `self` is the behavior
instance's table, which carries the entity handle.

#### Transform

```lua
-- Get position (returns two numbers)
local x, y = actor.get_position(self)

-- Set position
actor.set_position(self, 100, 200)

-- Move by delta (fused read-modify-write, preferred for per-frame movement)
actor.move_by(self, dx, dy)

-- Move by delta (same as move_by, but the name is more explicit)
actor.translate(self, dx, dy)

-- Rotation (radians, clockwise on screen)
local rot = actor.get_rotation(self)
actor.set_rotation(self, math.pi)
```

**Why `move_by` over `get_position` + `set_position`?** Because `move_by` is
one C call instead of two, and it does not push return values onto the Lua
stack. Measured: a Lua-to-C binding costs ~145 ns, so three calls (get + set +
math) cost ~435 ns vs. ~145 ns for one `move_by`. For 10k actors at 60 FPS,
that is the difference between 26 ms and 8 ms of binding overhead per frame.

#### Spatial Queries

```lua
-- Distance between two actors
local d = actor.distance_to(self, other)

-- Distance to a point
local d = actor.distance_to_point(self, x, y)

-- Squared distance (no sqrt, for comparisons)
local d_sq = actor.distance_squared_to(self, other)

-- Radius test (squared on both sides, no sqrt)
local in_range = actor.is_within_radius(self, other, 100)
local point_in_range = actor.is_within_radius_of_point(self, x, y, 100)

-- Direction to another actor (unit vector, two return values)
local dx, dy = actor.direction_to(self, other)

-- Angle to another actor (radians, from +X axis, clockwise positive)
local angle = actor.angle_to(self, other)

-- Half-extents of the sprite (for click hit-testing)
local hw, hh = actor.get_half_size(self)
```

#### Signals

```lua
-- Emit a signal (listeners on the same name fire on the next drain)
actor.emit(self, "took_damage")
```

Signals are typed: the event name is the type. Listeners registered for the
same name fire in stable spawn order. The Lua side cannot see the payload
(it is empty); richer events get a typed payload from Zig emitters.

#### Name

```lua
local name = actor.get_name(self)
```

### `input` -- Action-Based Input

Gameplay reads **named actions**, not physical keys. The mapping from action
to key/gamepad lives in the engine.

```lua
-- True only on the frame the action went down (edge, no auto-repeat)
if input.is_action_pressed("jump") then
  -- jump!
end

-- True while the action is held
if input.is_action_down("move_left") then
  -- move left
end

-- Signed axis from two opposing actions: -1, 0, or +1
local dx = input.get_axis("move_left", "move_right")
local dy = input.get_axis("move_up", "move_down")
```

### `vec2` -- 2D Vector Math

Two forms: **table form** (allocates, for readability) and **scalar form**
(zero allocation, for the frame loop).

```lua
-- Table form
local v = vec2.new(100, 200)
local w = vec2.new(50, 75)

-- Scalar form (zero allocation)
local dist = vec2.dist(100, 200, 50, 75)
local dist_sq = vec2.dist_sq(v, w)           -- accepts tables too
local len = vec2.length(3, 4)
local len_sq = vec2.length_sq(3, 4)

-- Returns a table (allocates)
local n = vec2.normalized(3, 4)
local dir = vec2.direction(0, 0, 100, 100)
local lerped = vec2.lerp(v, w, 0.5)
local rotated = vec2.rotate(v, math.pi / 2)
local perp = vec2.perpendicular(v)
local reflected = vec2.reflect(v, w)
local from_angle = vec2.from_angle(math.pi / 4)

-- Scalar returns
local dot = vec2.dot(v, w)
local cross = vec2.cross(v, w)
local angle = vec2.angle(1, 0)
local angle_between = vec2.angle_between(v, w)

-- Clamp length (keeps direction, caps magnitude)
local clamped = vec2.clamp_length(v, 50)
local clamped2 = vec2.clamped(v, 50)  -- alias
```

### `math` -- Scalar Math

```lua
math.clamp(x, lo, hi)                    -- clamp x to [lo, hi]
math.min(a, b)
math.max(a, b)
math.abs(x)
math.sign(x)                             -- -1, 0, or 1
math.floor(x)
math.ceil(x)
math.round(x)                            -- round half away from zero
math.fract(x)                            -- x - floor(x)
math.sqrt(x)
math.pow(a, b)
math.sin(x)                              -- radians
math.cos(x)
math.atan2(y, x)                         -- same argument order as stock Lua
math.lerp(a, b, t)                       -- linear interpolation
math.inverse_lerp(a, b, x)               -- (x - a) / (b - a)
math.remap(x, in_lo, in_hi, out_lo, out_hi)
math.smoothstep(edge0, edge1, x)
math.step(edge, x)                       -- 0 if x < edge, 1 otherwise
math.move_toward(current, target, max_delta)
math.damp(current, target, smoothing, dt) -- frame-rate independent damping
math.wrap(x, lo, hi)                     -- wrap around
math.pingpong(x, length)                 -- 0 -> length -> 0 -> length ...
math.deg_to_rad(deg)
math.rad_to_deg(rad)
math.is_close(a, b, tolerance)           -- boolean
```

### `rand` -- Deterministic RNG

All draws come from one sequence that `rand.seed` restarts. The same seed
replays the same draws, which makes bug reports reproducible.

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

### `noise` -- Procedural Noise

```lua
noise.seed(42)                           -- default seed for subsequent calls
local v = noise.value(x, y)               -- value noise
local p = noise.perlin(x, y)              -- Perlin noise
local s = noise.simplex(x, y)             -- Simplex noise
local f = noise.fbm(x, y, 4)              -- fractal Brownian motion, 4 octaves
local r = noise.ridged(x, y, 4)           -- ridged multifractal
```

Each function also accepts an optional trailing seed argument, so you can
keep two independent fields (terrain vs. weather) without reseeding.

### `log` -- Engine Log

```lua
log.info("game started")
log.warn("low health: " .. tostring(hp))
```

### `sm` -- Declarative State Machines

```lua
function M:start()
  -- Declare states with optional enter/update/exit callbacks
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
end

function M:update(dt)
  -- Request a transition (applied before the next update)
  if input.is_action_pressed("move") then
    sm.fire("move")
  end

  -- Query the current state
  local state = sm.state(self)
  log.info("current state: " .. state)

  -- Check if in a specific state
  if sm.is_in(self, "run") then
    -- ...
  end
end
```

### `world` -- Spatial Queries

```lua
-- Call fn(other_self) for every actor within radius of (x, y)
-- The caller is excluded from results.
world.nearby(self, x, y, 100, function(other)
  local d = actor.distance_to(self, other)
  -- ...
end)
```

The visitor form (rather than returning a list) is what keeps the frame
budget: materializing an array would allocate per call.

### `steer` -- Steering Behaviors

```lua
-- Create an accumulator (one per actor, reused across frames)
local acc = steer.for(x, y)

-- Reset (optionally at a new position)
acc:reset(x, y)

-- Add steering terms (each is normalized before weighting)
acc:seek(target_x, target_y, 1.0)
acc:flee(enemy_x, enemy_y, 0.5)
acc:arrive(target_x, target_y, 50, 1.0)   -- seek that brakes
acc:pursue(tx, ty, tvx, tvy, lead, 1.0)   -- lead a moving target
acc:evade(tx, ty, tvx, tvy, lead, 1.0)
acc:wander(angle, radius, 1.0)            -- deterministic wander
acc:avoid(ox, oy, radius, tx, ty, 1.0)  -- steer around obstacle

-- Flocking (uses world.nearby, the only C call)
acc:separate(50, 1.0)                     -- push away from neighbors
acc:align(100, 0.5)                       -- match neighbor velocity
acc:cohere(100, 0.5)                      -- move toward neighbor centroid

-- Apply: normalize, cap at max_speed, return velocity
local vx, vy = acc:apply(max_speed)
actor.move_by(self, vx * dt, vy * dt)
```

---

## 3. Complete Example: A Player Behavior

Here is a complete player behavior that demonstrates the full API surface:

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

  -- Declare a simple state machine
  sm.add_state("idle", {
    enter = function() log.info("player entered idle") end,
  })
  sm.add_state("run", {
    enter = function() log.info("player entered run") end,
  })
  sm.add_state("hurt", {
    enter = function()
      self.invulnerable = 1.0
      log.info("player hurt!")
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
  -- Decay invulnerability
  if self.invulnerable > 0 then
    self.invulnerable = math.max(0, self.invulnerable - dt)
  end

  -- Read input as a signed axis
  local dx = input.get_axis("move_left", "move_right")
  local dy = input.get_axis("move_up", "move_down")

  -- Normalize diagonal movement
  local len = math.sqrt(dx * dx + dy * dy)
  if len > 0 then
    dx = dx / len
    dy = dy / len
  end

  -- Compute velocity with damping
  local target_vx = dx * self.speed
  local target_vy = dy * self.speed
  self.vx = math.damp(self.vx, target_vx, 10, dt)
  self.vy = math.damp(self.vy, target_vy, 10, dt)

  -- Move (fused read-modify-write)
  actor.move_by(self, self.vx * dt, self.vy * dt)

  -- State machine transitions
  if dx ~= 0 or dy ~= 0 then
    sm.fire("move")
  else
    sm.fire("stop")
  end

  -- Animate
  self.anim_time = self.anim_time + dt
  if self.anim_time > 0.1 then
    self.anim_time = 0
    -- Cycle animation frame here
  end

  -- Spatial query: find nearby enemies
  local x, y = actor.get_position(self)
  world.nearby(self, x, y, 150, function(other)
    local d = actor.distance_to(self, other)
    if d < 30 and self.invulnerable <= 0 then
      self.hp = self.hp - 10
      sm.fire("hurt")
      if self.hp <= 0 then
        log.info("player died!")
      end
    end
  end)
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

- **Per-instance state** (`self.hp`, `self.vx`, etc.) set in `start`.
- **Prototype defaults** (`M.speed`, `M.max_hp`) shared across instances.
- **Action-based input** with axis normalization.
- **Fused movement** via `actor.move_by`.
- **Damping** for smooth acceleration (`math.damp`).
- **State machine** with `sm.add_state`, `sm.add_transition`, `sm.fire`.
- **Spatial query** via `world.nearby`.
- **Signal handling** via `on_signal`.
- **Fixed update** for physics (decoupled from render).
- **Lifecycle** with `start`, `update`, `fixed_update`, `on_signal`,
  `on_destroy`.

---

For the autogenerated API stubs (for LuaLS/EmmyLua), see
[`meta/ember.lua`](https://github.com/jesusalcaladev/ember-engine/blob/main/meta/ember.lua).
