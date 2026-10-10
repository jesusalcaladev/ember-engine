# Understanding Behaviors

Ember uses **LuaJIT** (Lua 5.1) for gameplay scripting. A **behavior** is a
Lua script bound to an actor (an ECS entity). The Ember Editor generates
behavior scripts automatically as you attach logic to entities. This guide
covers the behavior lifecycle, the `self` table, the engine API, and how
hot-reloading works.

> **Editor Note:** You do not write behavior scripts by hand. The Ember
> Editor generates the Lua code as you attach behaviors to entities, define
> state machines, and configure properties visually. Understanding the
> generated Lua helps you debug issues, customize behaviors beyond what the
> editor offers, and appreciate the architecture -- but the editor does the
> writing for you.

> **What you will accomplish:** By the end of this guide, you will understand
> the full behavior lifecycle (from `start` to `on_destroy`), know exactly
> how the `self` table connects your script to the engine, be able to use
> the engine API to read input and move entities, and understand how
> hot-reloading lets you iterate without restarting the game.

---

## What the Editor Does

The Ember Editor lets you attach behaviors to entities visually. When you
do, the editor generates the Lua script that implements the behavior:

- **Attach a behavior** by selecting an entity and choosing a script --
  the editor creates a `.lua` file and adds a `Script` component to the
  entity.
- **Define properties** in the inspector -- the editor writes them as
  fields on the `self` table in `start()`.
- **Set up state machines** visually -- the editor generates the `sm.*`
  calls in your script.
- **Edit Lua directly** when you need more control -- the editor
  hot-reloads your changes instantly.

The editor manages the script cache, so you never need to worry about
script ids or registration. When you save, the editor writes the `.lua`
file and updates the scene's `Script` component to reference it.

Understanding the generated Lua helps you:

- **Debug** -- when a behavior misbehaves, you can read the Lua and see
  exactly what the editor produced.
- **Customize** -- you can hand-edit the Lua for logic that goes beyond
  the editor's visual tools.
- **Learn** -- the generated code is clean and idiomatic, making it a
  great reference for Ember scripting patterns.

---

## The Behavior Lifecycle

A behavior is a Lua chunk that returns a **prototype table**. The engine
calls lifecycle methods on each instance's `self` table at specific points
in the entity's life.

Here is the full lifecycle, frame by frame:

```
Frame 1 (first frame):
  start()          -- called once, before the first update
  update(dt)       -- called every rendered frame

Frame 2:
  update(dt)

Frame 3:
  update(dt)

  ... (repeat until entity is destroyed)

Last frame:
  update(dt)
  on_destroy()     -- called before the actor is removed
```

If the entity is configured to receive signals, `on_signal(name)` is
called when a signal fires. If the entity uses fixed timestep physics,
`fixed_update(dt)` is called at a fixed 60 Hz rate.

| Method | When it runs | Signature |
|---|---|---|
| `start` | Once, before the first `update` | `function M:start()` |
| `update` | Every rendered frame | `function M:update(dt)` |
| `fixed_update` | Every fixed 60 Hz tick | `function M:fixed_update(dt)` |
| `on_signal` | When a signal this actor listens to drains | `function M:on_signal(name)` |
| `on_destroy` | Before the actor is removed | `function M:on_destroy()` |

All methods are **optional**. A script that defines only `update` works
fine. The engine checks whether each method exists before calling it.

> **What's Happening Behind the Scenes:** The engine does not call `start`,
> `update`, and so on by looking up strings in a table. Instead, it checks
> whether the prototype table has a field named `start`, `update`, etc.
> If the field exists and is a function, the engine calls it. If not, the
> engine skips it. This is called **duck typing** -- "if it walks like a
> duck and quacks like a duck, it is a duck." In Ember, "if the script
> has an `update` function, it gets updated."

---

## Your First Behavior

Let us look at a typical behavior script. In the editor, you would create
this by attaching a behavior to an entity and defining its properties --
the editor generates the following Lua for you:

```lua
local M = {}

function M:start()
  -- Called once when the actor spawns.
  self.speed = 200          -- pixels per second
  self.n = 0                -- per-instance state
  log.info("player started")
end

function M:update(dt)
  -- Called every rendered frame. dt is in seconds.
  self.n = self.n + 1

  -- Read input (action-based, not raw keys)
  local dx = input.get_axis("move_left", "move_right")
  local dy = input.get_axis("move_up", "move_down")

  -- Move the actor (fused read-modify-write, zero allocation)
  actor.move_by(self, dx * self.speed * dt, dy * self.speed * dt)
end

function M:on_signal(name)
  -- Called when a signal fires.
  log.warn("player received signal: " .. name)
end

function M:on_destroy()
  log.info("player destroyed after " .. tostring(self.n) .. " frames")
end

return M
```

Let us walk through the key concepts:

### The Prototype Table

`local M = {}` creates an empty table. We add methods to it
(`function M:start()`, etc.) and return it at the end. This table is the
**prototype** -- a template that all instances of this script share.

### The `self` Table

Every entity that uses this script gets its own `self` table. The `self`
table is where you store per-instance data (`self.speed`, `self.n`). The
engine creates `self` tables automatically -- you never create them
yourself.

### The Colon Shorthand

`function M:update(dt)` is exactly the same as
`function M.update(self, dt)`. The colon is syntactic sugar that adds
`self` as the first parameter. This is why every method you define must
have `self` as its first parameter (explicitly or implicitly via the
colon).

### The `dt` Parameter

`dt` is "delta time" -- the number of seconds since the last frame. At 60
FPS, `dt` is about 0.016. At 30 FPS, `dt` is about 0.033. Using `dt` makes
your game run at the same speed regardless of frame rate. If you moved by
a fixed amount each frame, the game would run twice as fast at 120 FPS
compared to 60 FPS.

---

## The `self` Table

The `self` table is the heart of every Ember script. It is worth understanding
exactly how it works.

### Instance State vs. Prototype

Every behavior instance has a `self` table that:

- **Carries per-instance state.** Fields you set (`self.speed`, `self.n`)
  live on the instance and survive hot-reloads.
- **Resolves methods through a shared prototype.** The script's returned
  table is the prototype; `self` has a metatable whose `__index` points
  at it. Method lookup goes through the metatable, so all instances of
  the same script share one prototype.
- **Holds the entity handle.** The engine stamps `self.__entity` as light
  userData, so `actor.*` bindings reach the ECS entity in O(1) with no map.

Here is what this looks like in practice:

```lua
local M = {}

M.speed = 100              -- prototype default (shared)

function M:start()
  self.speed = 200         -- instance override (per-actor)
  self.n = 0               -- instance state
end

function M:update(dt)
  -- self.speed reads the instance value (200) if set,
  -- otherwise the prototype default (100).
  actor.move_by(self, self.speed * dt, 0)
end

return M
```

If you set `self.speed` on one instance, it does not affect other
instances. The prototype default is only used when the instance has not set
its own field.

> **What's Happening Behind the Scenes:** When you write `self.speed = 200`
> inside `start`, Lua sets the `speed` field on the `self` table (the
> instance). When you later read `self.speed` in `update`, Lua first looks
> in the `self` table. If it finds `speed` there, it uses that value. If
> not, it follows the metatable's `__index` to the prototype table `M` and
> looks there. This is called **prototype-based inheritance** -- the same
> mechanism used in JavaScript.
>
> The key insight is that **reading** is dynamic (always goes through the
> metatable chain) but **writing** is always on the instance. So
> `self.speed = 200` shadows the prototype default for that one instance
> without affecting the prototype or any other instance.
>
> The `self.__entity` field is set by the engine as **light userData** --
> a raw C pointer with no metatable. This is the fastest possible way to
> reference an ECS entity from Lua: no hash table lookup, no string
> comparison, just a direct pointer dereference. When you call
> `actor.move_by(self, ...)`, the engine reads `self.__entity` and knows
> exactly which entity to move.

---

## The Engine API

Ember exposes a curated set of global tables. The full API reference is in
[`meta/ember.lua`](https://github.com/jesusalcaladev/ember-engine/blob/main/meta/ember.lua)
(autogenerated from the binding metadata -- do not edit by hand).

### `actor` -- Transform and Spatial Queries

All `actor` methods take `self` as the first argument:

```lua
-- Position
local x, y = actor.get_position(self)
actor.set_position(self, 100, 200)
actor.move_by(self, 10, 5)       -- fused read-modify-write (preferred)
actor.translate(self, 10, 5)     -- same, but two calls in the naive path

-- Rotation
local rot = actor.get_rotation(self)
actor.set_rotation(self, math.pi)

-- Name
local name = actor.get_name(self)

-- Signals
actor.emit(self, "took_damage")  -- queue a signal; listeners fire next drain

-- Spatial queries (take another actor's self table)
local dist = actor.distance_to(self, other)
local dist_sq = actor.distance_squared_to(self, other)
local in_range = actor.is_within_radius(self, other, 100)
local dx, dy = actor.direction_to(self, other)
local angle = actor.angle_to(self, other)

-- Sprite half-extents
local hw, hh = actor.get_half_size(self)
```

> **What's Happening Behind the Scenes:** `actor.move_by` is called
> "fused read-modify-write" because it reads the current position, adds
> the delta, and writes the new position in a single C call. This is
> faster than calling `get_position`, adding, and then `set_position`
> separately (which would be three C calls). In the hot path (every frame,
> every entity), these micro-optimizations add up.

### `input` -- Action-Based Input

Gameplay reads **named actions**, not physical keys. The mapping from
action to key/gamepad lives in the engine, so rebinding never touches
Lua.

```lua
-- Edge detection (true only on the frame the action went down)
if input.is_action_pressed("jump") then
  -- jump!
end

-- Held state (true while the action is held)
if input.is_action_down("move_left") then
  -- move left
end

-- Signed axis from two opposing actions: -1, 0, or +1
local dx = input.get_axis("move_left", "move_right")
local dy = input.get_axis("move_up", "move_down")
```

> **What's Happening Behind the Scenes:** When you press a key, the
> engine receives a raw key event (e.g., "Spacebar down"). It then looks
> up which actions are mapped to that key (e.g., "jump" and "confirm").
> It updates the state of those actions. When your Lua script calls
> `input.is_action_pressed("jump")`, it reads the action state, not the
> raw key. This indirection is what allows you to rebind keys, support
> gamepads, and have different control schemes without changing a single
> line of Lua.

### `vec2` -- 2D Vector Math

Two forms: a **table form** for readability and a **scalar form** for the
frame loop (zero allocation):

```lua
-- Table form (allocates a table)
local v = vec2.new(100, 200)
local w = vec2.new(50, 75)

-- Scalar form (zero allocation, one C call)
local dist = vec2.dist(100, 200, 50, 75)
local dist_sq = vec2.dist_sq(v, w)           -- accepts tables too
local len = vec2.length(3, 4)
local nx, ny = vec2.normalized(3, 4)        -- returns a table
local dot = vec2.dot(v, w)
local angle = vec2.angle_between(v, w)
```

> **What's Happening Behind the Scenes:** Lua's garbage collector has to
> clean up tables that are no longer referenced. In a game running at 60
> FPS, allocating hundreds of small tables per frame creates significant
> GC pressure. The scalar form (`vec2.dist(x1, y1, x2, y2)`) avoids
> allocation entirely by taking and returning numbers. Use the scalar form
> in `update` and the table form in `start` or other one-time code.

### `math` -- Scalar Math

```lua
math.clamp(x, lo, hi)
math.lerp(a, b, t)
math.inverse_lerp(a, b, x)
math.remap(x, in_lo, in_hi, out_lo, out_hi)
math.smoothstep(edge0, edge1, x)
math.move_toward(current, target, max_delta)
math.damp(current, target, smoothing, dt)
math.deg_to_rad(deg)
math.rad_to_deg(rad)
math.is_close(a, b, tolerance)
```

### `rand` -- Deterministic RNG

```lua
rand.seed(12345)          -- restart the sequence (deterministic)
local f = rand.float(0, 1)
local i = rand.int(1, 6)  -- dice roll, both ends inclusive
local b = rand.chance(0.3) -- true with 30% probability
local g = rand.gauss(0, 1) -- normal distribution
local s = rand.sign()      -- -1 or +1
local elem = rand.choice({10, 20, 30})  -- pick from array
rand.shuffle(deck)         -- Fisher-Yates, in place
```

> **What's Happening Behind the Scenes:** The RNG is deterministic --
> given the same seed, it produces the same sequence of numbers. This is
> essential for replays, debugging, and multiplayer. If you seed the RNG
> with a fixed value, you can reproduce the exact same game every time.

### `noise` -- Procedural Noise

```lua
noise.seed(42)            -- default seed for subsequent calls
local v = noise.value(x, y)
local p = noise.perlin(x, y)
local s = noise.simplex(x, y)
local f = noise.fbm(x, y, 4)           -- fractal Brownian motion, 4 octaves
local r = noise.ridged(x, y, 4)        -- ridged multifractal
```

### `log` -- Engine Log

```lua
log.info("game started")
log.warn("low health: " .. tostring(hp))
```

> **What's Happening Behind the Scenes:** `log.info` and `log.warn>`
> write to the engine's log file and console output. They are not the
> same as Lua's built-in `print` -- they include timestamps, log levels,
> and script identifiers. In the editor, they appear in the output panel.
> In a release build, they can be redirected to a file.

### `sm` -- Declarative State Machines

```lua
function M:start()
  sm.add_state("idle", {
    enter = function() log.info("entering idle") end,
    update = function(dt) -- idle behavior end,
    exit = function() log.info("leaving idle") end,
  })
  sm.add_state("run", { ... })
  sm.add_transition("idle", "move", "run")
  sm.add_transition("run", "stop", "idle")
  sm.set_initial("idle")
end

function M:update(dt)
  if input.is_action_pressed("move") then
    sm.fire("move")       -- request a transition
  end
  log.info("current state: " .. sm.state(self))
end
```

### `world` -- Spatial Queries

```lua
-- Call fn(other_self) for every actor within radius of (x, y)
world.nearby(self, x, y, 100, function(other)
  local d = actor.distance_to(self, other)
  -- ...
end)
```

### `steer` -- Steering Behaviors

```lua
local acc = steer.at(x, y)
acc:seek(target_x, target_y, 1.0)
acc:flee(enemy_x, enemy_y, 0.5)
acc:arrive(target_x, target_y, 50, 1.0)
acc:pursue(tx, ty, tvx, tvy, lead, 1.0)
acc:evade(tx, ty, tvx, tvy, lead, 1.0)
acc:wander(angle, radius, 1.0)
acc:avoid(ox, oy, radius, tx, ty, 1.0)
acc:separate(50, 1.0)
acc:align(100, 0.5)
acc:cohere(100, 0.5)
local vx, vy = acc:apply(max_speed)
actor.move_by(self, vx * dt, vy * dt)
```

---

## Hot-Reloading

Edit a Lua file and reload it at runtime (the editor does this
automatically). Here is exactly what happens, step by step:

1. **You save the file.** The editor detects the file change and notifies
   the engine.

2. **The engine recompiles the script.** It reads the new file content and
   compiles it into a Lua bytecode chunk. This chunk is a fresh, independent
   piece of code -- it has no connection to the old version.

3. **The engine creates a new prototype table.** It executes the compiled
   chunk, which returns a new table `M` with your updated methods. This
   new table is the **new prototype**.

4. **The engine repoints the shared metatable's `__index`.** All live
   `self` tables share a common metatable whose `__index` field points to
   the prototype. The engine updates `__index` to point to the new
   prototype table. Now, when a `self` table looks up a method (e.g.,
   `self.update`), it finds the new version through the metatable chain.

5. **Every live `self` table keeps its own fields.** The `self` tables
   are not recreated. They still have all the per-instance state you set
   (`self.speed`, `self.n`, etc.). The only thing that changes is where
   method lookups resolve.

6. **`start` is not re-run.** The engine does not call `start` again on
   reload. Only the methods change. This means your initialization code
   runs once, but your updated `update` (or other methods) take effect
   immediately.

> **What's Happening Behind the Scenes:** This design is what makes
> hot-reload seamless. Because all instances share a single metatable,
> updating the prototype affects every instance at once -- you do not
> need to manually update each entity. And because `self` tables are
> untouched, your game state (positions, health, score, etc.) is
> preserved across reloads.
>
> The tradeoff is that `start` is not re-run. If your `start` method
> sets up critical initialization that depends on the new code, you need
> to handle that manually (e.g., by checking a version flag).

---

## Error Handling

A script error is **never a crash**. The engine wraps every behavior call
in `pcall` (protected call) and logs the error:

```
[error] [behavior] behavior: attempt to index a nil value (field 'speed')
```

The broken behavior is skipped for that frame; other behaviors continue
running.

> **Troubleshooting: "My script stopped working after an edit."**
>
> Check the engine log for error messages. The most common errors are:
>
> - **"attempt to index a nil value"** -- You are trying to access a field
>   on a nil value. For example, `self.speed` is nil because `start` was
>   not called or did not set it. Add a check: `if self.speed then ... end`.
> - **"attempt to call a nil value"** -- You are trying to call a function
>   that does not exist. Check for typos in function names.
> - **"bad argument"** -- You passed the wrong type or number of arguments
>   to a function. Check the function signature in the API reference.

---

## The Sandbox

Lua scripts run in a **sandboxed** environment. The following globals are
removed:

- `io`, `os`, `package`, `debug` -- filesystem and process access.
- `require`, `dofile`, `loadfile`, `load`, `loadstring` -- dynamic code
  loading.
- `collectgarbage` -- the engine drives the GC step.
- `newproxy`, `module`, `rawequal`, `rawget`, `rawset`, `gcinfo`.

Kept: `assert`, `error`, `pcall`, `select`, `type`, `tostring`,
`tonumber`, `ipairs`, `pairs`, `next`, `unpack`, `setmetatable`,
`getmetatable`, `print` (redirected to the engine log).

> **Why is this important?** Sandboxing prevents scripts from doing
> dangerous things like reading files, executing system commands, or
> loading arbitrary code. This is essential for modding support -- if
> users can write scripts, you do not want them to be able to delete files
> on the player's computer.

---

## Try These Exercises

### Exercise 1: Log the Frame Counter

Add a frame counter to your script and log it every 60 frames:

```lua
function M:update(dt)
  self.n = self.n + 1
  if self.n % 60 == 0 then
    log.info("frame " .. tostring(self.n))
  end
end
```

Run the game and watch the log. You should see a message every second
(60 frames at 60 FPS).

> **What you learned:** The modulo operator (`%`) gives the remainder of
> division. `self.n % 60 == 0` is true every 60 frames.

### Exercise 2: Read Position and Log It

Add position logging to your `update`:

```lua
function M:update(dt)
  local x, y = actor.get_position(self)
  log.info("position: " .. tostring(x) .. ", " .. tostring(y))
  actor.move_by(self, self.speed * dt, 0)
end
```

Run the game. You should see the x position increasing each frame.

> **What you learned:** You can read the entity's current position at any
> time using `actor.get_position(self)`.

### Exercise 3: Create a Custom Signal

Emit a custom signal and listen for it:

```lua
function M:start()
  self.speed = 200
  actor.listen(self, "bounced")  -- start listening for "bounced"
end

function M:update(dt)
  local x, y = actor.get_position(self)
  local nx = x + self.speed * dt
  if nx > 1280 then
    actor.emit(self, "bounced")  -- emit the signal
    self.speed = -self.speed
    nx = x + self.speed * dt
  end
  actor.set_position(self, nx, y)
end

function M:on_signal(name)
  if name == "bounced" then
    log.warn("I bounced!")
  end
end
```

Run the game. When the sprite reaches the right edge, it should reverse
direction and log "I bounced!".

> **What you learned:** Signals are a way for entities to communicate
> without direct references. You can emit a signal with `actor.emit` and
> listen for it with `actor.listen`. The `on_signal` method is called when
> a signal fires.

### Exercise 4: Modify a Script While the Game is Running

1. Start the game with a simple movement script.
2. While the game is running, edit the script to change the speed or add
   a print statement.
3. Save the file. The engine should hot-reload the script without
   restarting.

> **What you learned:** Hot-reloading preserves game state. The sprite
> continues from its current position with the new behavior applied.

---

## Next Steps

- **[Learning Lua](../guides/learning-lua.md)** -- the complete Lua guide
  for Ember, from basic syntax to advanced patterns.
- **[Understanding Scenes](first-scene.md)** -- if you have not already,
  learn how scenes represent entities, components, and hierarchy.

You now have a solid understanding of how Ember scripts work -- from the
lifecycle to the `self` table to the engine API. You are ready to start
building real game logic!
