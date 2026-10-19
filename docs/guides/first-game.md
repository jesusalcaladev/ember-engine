# First Game: A Simple Collector

This tutorial builds a complete mini-game with the engine's own API: a player
that moves with the arrow keys, a game that moves through phases, and a HUD
score. Every function it calls **exists** — the list is the
[Lua API Reference](../reference/script-lua-api.md), and the code below is
checked against it.

The finished project lives in [`samples/first-game/`](../../samples/first-game/),
and it runs:

```bash
cd samples/first-game
../../zig-out/bin/ember --scene game.zson
```

---

## What we are building

- A **player** that moves with the arrow keys (or WASD), at the same speed in
  every direction.
- A **flow** — the game's phases — with a stack, so "paused" sits on top of
  "playing" and leaving it returns there.
- A **sequence** in the player, written as a coroutine: "one second, then half
  a second", with no frame counter anywhere.

---

## The three files

```
first-game/
├── project.config      # the project settings: the scripts, the input map
├── game.zson           # the scene: the entities and their components
└── scripts/
    ├── player.lua      # the behavior the player actor runs
    └── globals/
        └── flow.lua    # the game's phases — a GLOBAL script, with no actor
```

**How a project is put together:**

- `project.config` lists the scripts and the input actions. The `scripts`
  section has two lists: `behavior` (the scripts an actor can run) and `global`
  (the scripts that run with no actor at all).
- The `.zson` file is the scene: the entities and their components.
- A script named in `behavior` is **attached to an actor** by the scene's
  `Script {script: N}` component. `N` is the **index in the `behavior` list**,
  one-based: the first entry is script 1.

---

## Step 1: `project.config`

```ini
project "First Game"
version "0.1.0"

display {
  width 1280
  height 720
  vsync true
}

scripts {
  behavior "scripts/player.lua"
  global "scripts/globals/flow.lua"
}

input_map {
  move_left ["KEY_A", "KEY_LEFT"]
  move_right ["KEY_D", "KEY_RIGHT"]
  move_up ["KEY_W", "KEY_UP"]
  move_down ["KEY_S", "KEY_DOWN"]
  pause ["KEY_ESCAPE"]
}
```

Two things to notice:

- **`behavior` and `global` are different things.** A `behavior` runs on an
  actor; a `global` runs with **no actor at all** — it is the game manager, the
  score, the flow. A global is reached from anywhere with
  `globals.get("flow")`.
- **The input map is actions, not keys.** A script asks for `"move_left"`, not
  for `KEY_A`. Rebinding the game is editing this file, and no script changes.

---

## Step 2: the scene

```zson
zson 1

entity 1 {
  Name "player"
  Transform {position: {x: 640, y: 360}, rotation: 0, scale: {x: 1, y: 1}}
  Sprite {atlas: 0, layer: 0, size: {x: 32, y: 32}, tint: [0.2, 0.6, 1, 1], blend: alpha, visible: true}
  Script {script: 1}
}
```

- `Name` — the actor's name in the scene and in the inspector.
- `Transform` — where it is and how it is turned.
- `Sprite` — what it looks like.
- `Script {script: 1}` — **the behavior it runs**. Script 1 is the first entry
  of the project's `behavior` list: `scripts/player.lua`.

The full list of components and their fields is in the
[Component Index](../reference/components/README.md).

---

## Step 3: the player

```lua
-- scripts/player.lua
local M = {}

function M:start()
  self.speed = 300
  self.alive = true
end

function M:update(dt)
  if not self.alive then return end

  -- The input, as a signed axis per direction.
  local dir = vec2.new(
    input.get_axis("move_left", "move_right"),
    input.get_axis("move_up", "move_down"))

  -- NORMALIZE, with `vec2` — the `math` module is for SCALARS and has no
  -- vector functions. Without this, walking diagonally is 1.41 times faster
  -- than walking straight, which is the bug every 2D game has to fix once.
  if vec2.length(dir) > 0 then
    dir = vec2.normalized(dir)
  end

  -- Move. `dt` is the frame's delta, already scaled by the global time scale,
  -- so the player moves at the same speed the world does.
  actor.move_by(self, dir.x * self.speed * dt, dir.y * self.speed * dt)

  -- Clamp to the screen. `math.clamp` is the scalar one, and it is the right
  -- one here: the bounds are numbers.
  local x, y = actor.get_position(self)
  actor.set_position(self,
    math.clamp(x, 16, 1264),
    math.clamp(y, 16, 704))
end

return M
```

**The normalization, and where it lives.** `math` is the **scalar** module:
`math.clamp`, `math.lerp`, `math.sqrt`, `math.ease`. The **vector** module is
`vec2`: `vec2.new`, `vec2.length`, `vec2.normalized`, `vec2.lerp`,
`vec2.clamped`, `vec2.dist`. A diagonal normalized by hand is three lines of
arithmetic that `vec2.normalized` does in one, and it is the version that
cannot get the zero-length case wrong.

`vec2.new` returns a **table** with `x` and `y` fields. The other `vec2`
functions take and return **numbers**, so a per-frame computation does zero
Lua allocation and one C call.

---

## Step 4: the flow

The game's phases — menu, playing, paused, game over — belong to the **game**,
not to an actor. That is what a **global script** is for, and what the `flow`
module is for.

```lua
-- scripts/globals/flow.lua
local M = {}

function M:start()
  -- The states. The hooks receive this global's `self`, so a phase can read
  -- the game's state directly.
  flow.add_state(self, "menu", {
    enter = function(self)
      log.info("flow: menu")
    end,
  })
  flow.add_state(self, "playing", {
    enter = function(self)
      log.info("flow: playing")
    end,
  })
  flow.add_state(self, "paused", {
    enter = function(self)
      time.pause()
    end,
    exit = function(self)
      time.resume()
    end,
  })

  -- The transitions. A transition REPLACES the whole stack: the phase
  -- changed, not the layer on top of it.
  flow.add_transition(self, "menu", "start", "playing")

  flow.set_initial(self, "menu")
end

function M:update(dt)
  if input.is_action_pressed("pause") then
    if flow.is_in(self, "paused") then
      flow.pop(self)             -- back to "playing"
    elseif flow.is_in(self, "playing") then
      flow.push(self, "paused")   -- "paused" sits ON TOP of "playing"
    end
  end
end

return M
```

**The stack is the point.** A flat state machine cannot express "paused",
because leaving "paused" has to return to "playing" and not to whatever came
before it. `flow.push` puts a state on top and keeps the one below;
`flow.pop` takes the top off. A **transition** is different: it replaces the
whole stack, because the game's phase changed.

Any script can read the flow — `flow.state(self)` and `flow.is_in(self, ...)`
answer "which phase are we in" from anywhere.

---

## Step 5: a sequence, without a frame counter

```lua
function M:start_sequence()
  self:async(function(self)
    log.info("player: the sequence begins")
    self:wait(1.0)
    log.info("player: one second later")
    self:wait(0.5)
    log.info("player: and another half")
  end)
end
```

`self:async` starts the function as a **coroutine**, and `self:wait` pauses it
for a number of **game** seconds. The engine resumes it on the fixed step, so:

- the wait is measured in game time — it slows down with the global time scale
  and replays identically;
- there is no frame counter, no `self.t` to add up, and no "did the timer
  finish" branch.

A coroutine that raises an error is **logged**, and the frame survives it —
exactly like a behavior that raises one.

---

## Step 6: run it

```bash
cd samples/first-game
../../zig-out/bin/ember --scene game.zson
```

You should see a blue square in the middle of the screen that moves with the
arrow keys, and the log should show the flow entering `menu`.

---

## What you learned

- **The project**: `project.config` declares the scripts and the input map;
  the `.zson` is the scene.
- **Behaviors**: the lifecycle (`start`, `update`, `fixed_update`, `on_signal`,
  `on_destroy`) and the `self` table that carries the actor's handle.
- **Global scripts**: the game manager, the score, the flow — code with no
  actor, reached with `globals.get("name")`.
- **The flow**: a global state machine with a stack of states.
- **Coroutines**: `self:async(fn)` and `self:wait(seconds)` — a sequence
  without a frame counter.
- **Input**: actions, not keys (`input.get_axis`, `input.is_action_pressed`).
- **Movement**: `actor.move_by`, and the `vec2` normalization that keeps a
  diagonal from being faster.
- **The clock**: `time.pause()`, `time.set_scale(0.5)` — the world and the
  animations, slowed down.

---

## What the engine cannot do yet

The gaps are listed here so the tutorial does not pretend. Each one is a
missing API, not a missing idea:

| You want | Today | The gap |
|---|---|---|
| Spawn an actor from a script | — | there is no `actor.spawn`. Declare the actors in the scene |
| Remove an actor | `actor.remove_component(self, "Sprite")` | there is no `actor.destroy`. Removing the `Sprite` hides it |
| Find an actor by name | — | there is no `actor.find_by_name`. Publish the reference from a global script instead |
| Give an actor a new component with values | `actor.add_component(self, "Sprite")` | the component gets its **defaults**; there is no per-field setter from Lua |
| Read a component's fields | `actor.get_all(self)` | a table of everything the actor carries |

---

## Next steps

- [Tweens and Timers](../reference/tween-and-timer.md) — animating a value over time
- [Component Index](../reference/components/README.md) — every component, one page each
- [Global Scripts](../reference/global-scripts.md) — the manager pattern in depth
- [Lua API Reference](../reference/script-lua-api.md) — every function that exists
- [Core Loop](../reference/core-loop.md) — the fixed step and the time scale
