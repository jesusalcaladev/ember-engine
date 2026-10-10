# Quickstart: Something Moving in 5 Minutes

Welcome! This guide will get a sprite moving on screen as quickly as possible.
By the end, you will understand how a scene file and a Lua script work
together to move a square across the screen. No prior experience with Ember
or game engines is required -- we will explain everything as we go.

> **Editor Note:** In a real workflow, the Ember Editor creates scenes and
> scripts for you. You add entities visually, attach behaviors from a list,
> and the editor generates the `.zson` and `.lua` files automatically. This
> guide walks through the process manually as a "behind the scenes" learning
> tool -- so you understand what the editor does for you.

> **What you will accomplish:** A white square gliding across a black window,
> controlled by a Lua script. You will learn the three core pieces of
> any Ember game: **scenes** (`.zson`), **scripts** (`.lua`), and **running**
> (`zig build run`).

## Prerequisites

You have already built the engine. If you have not, work through
[Installation](installation.md) first -- it walks you through every dependency
and explains what each one is for.

---

## Step 1: Behind the Scenes — The Scene File

In the editor, you would create a scene by adding an entity, positioning it,
and attaching a sprite. The editor generates the following `.zson` file for
you. Let us look at what it produces:

A scene file describes **what exists** in your world: entities, their
positions, and what they look like. Think of it as a cast list and stage
direction for your game.

```
zson 1

entity 1 {
  Name "player"
  Transform {position: {x: 100, y: 100}, rotation: 0, scale: {x: 1, y: 1}}
  Sprite {atlas: 0, layer: 0, size: {x: 32, y: 32}, tint: [1, 1, 1, 1], blend: alpha, visible: true}
  Script {script: 1}
}
```

Let us break this down piece by piece:

- **`zson 1`** -- This is a version header. It tells the engine "this file
  uses version 1 of the ZSON format." The engine checks this so it can load
  older files correctly even after the format evolves.

- **`entity 1 { ... }`** -- This declares one entity. The number `1` is its
  **scene id** -- a stable identifier the engine uses to track it. You can
  think of it like a name tag at a conference.

- **`Name "player"`** -- A human-readable label for this entity. This is not
  used for logic -- it is for you, the developer, to identify the entity in
  logs and tools.

- **`Transform { ... }`** -- This entity's position, rotation, and scale in
  2D space. `{x: 100, y: 100}` means "100 pixels right, 100 pixels down
  from the top-left corner." Rotation is in radians (0 = upright), and scale
  `{x: 1, y: 1}` means "normal size" (2 would be double, 0.5 would be half).

- **`Sprite { ... }`** -- What this entity looks like. `atlas: 0` means "use
  the first texture" (which is a built-in white square). `size: {x: 32, y: 32}`
  makes it 32 by 32 pixels. `tint: [1, 1, 1, 1]` is white with full opacity
  (RGBA). `blend: alpha` means standard transparency. `visible: true` means
  "draw this."

- **`Script {script: 1}`** -- This attaches a Lua script to the entity. The
  number `1` is a script cache id -- the engine uses it to find the right
  `.lua` file. We will write that file next.

> **What's Happening Behind the Scenes:** When the engine loads this file, it
> creates an **entity** in its **ECS** (Entity Component System). The ECS is
> just a fast way to store and process lots of objects that share the same
> kinds of data. Each component (`Transform`, `Sprite`, `Script`) is stored
> separately in memory, which makes it very fast for the engine to ask
> questions like "where are all the things that have a Sprite?"

---

## Step 2: Behind the Scenes — The Script

In the editor, you would attach a behavior to the entity and set its
properties. The editor generates the following Lua script for you. Let us
look at what it produces:

A script defines **how an entity behaves** -- what it does each frame, how it
responds to input, and so on.

```lua
local M = {}

function M:start()
  self.speed = 200
  log.info("quickstart: player started")
end

function M:update(dt)
  actor.move_by(self, self.speed * dt, 0)
end

return M
```

Let us walk through each part:

- **`local M = {}`** -- This creates an empty table (Lua's version of an
  object or dictionary). We will fill it with methods. At the end, we
  `return M` so the engine can find them.

- **`function M:start()`** -- This defines a method called `start` on the `M`
  table. The engine calls `start` exactly once, when the entity first appears
  in the world. This is where you set up initial values.

- **`self.speed = 200`** -- Here, `self` refers to *this specific entity's
  instance*. Setting `self.speed` means "this entity moves at 200 pixels per
  second." Each entity that uses this script gets its own `self` table, so
  changing one entity's speed does not affect another.

- **`log.info("quickstart: player started")`** -- This prints a message to
  the engine log. You will see it appear when the game starts. It is a
  debugging tool -- like a `console.log` in JavaScript or a `print` in Python.

- **`function M:update(dt)`** -- The colon (`:`) is Lua shorthand. Writing
  `function M:update(dt)` is exactly the same as writing
  `function M.update(self, dt)`. The first argument is always `self` -- the
  entity this script is attached to. `dt` is "delta time": the number of
  seconds since the last frame (e.g., 0.016 for 60 FPS).

- **`actor.move_by(self, self.speed * dt, 0)`** -- This moves the entity.
  `self.speed * dt` converts "200 pixels per second" into "how far should we
  move this frame." At 60 FPS, `dt` is about 0.016, so the sprite moves about
  3.3 pixels per frame. The `0` means "do not move vertically."

> **What's Happening Behind the Scenes:** The engine does not call `start` and
> `update` directly by name. Instead, it looks up the script's returned table
> (`M`), finds methods named `start` and `update`, and calls them on a
> per-instance `self` table. The `self` table has a hidden link back to the
> entity in the ECS, so when you call `actor.move_by(self, ...)`, the engine
> knows exactly which entity to move -- no lookups, no ambiguity.

---

## Step 3: Run It

In the editor, you would press Play and the engine would load your scene
automatically. From the command line, you can achieve the same result.
Open your terminal, make sure you are in the project directory, and run:

```bash
zig build run -- quickstart.zson
```

Here is what this command does, piece by piece:

- **`zig build`** -- This tells Zig (the programming language the engine is
  written in) to compile the project if needed, then run the requested step.
- **`run`** -- This tells Zig to execute the `run` build step, which launches
  the engine.
- **`--`** -- This separates Zig arguments from engine arguments. Everything
  after `--` is passed to the engine itself.
- **`quickstart.zson`** -- This is the scene file the engine should load.

A window should open. You will see a black screen with a white square
starting near the top-left corner. The square glides steadily to the right.
Congratulations -- you have just made your first Ember game!

> **Troubleshooting: "I get a black screen and nothing moves."**
>
> First, check the terminal output. Do you see `quickstart: player started`?
> If not, the script may not have loaded. Make sure `player.lua` is in the
> same directory as `quickstart.zson`, and that the file is named exactly
> `player.lua` (all lowercase).
>
> If you see the log message but the square does not move, check that
> `actor.move_by` is spelled correctly and that `self.speed` was set in
> `start`.

> **Troubleshooting: "I get an error about 'script 1'."**
>
> The `Script {script: 1}` line tells the engine to look up script id 1. If
> you have not registered your Lua file with id 1, the engine will complain.
> In the quickstart, the engine maps `player.lua` to id 1 automatically by
> convention. If you rename the file, the mapping breaks.

---

## What Just Happened?

Let us trace through the entire sequence so you understand the full picture:

1. **The engine started** and read `quickstart.zson`. It created one entity
   with a `Transform`, a `Sprite`, and a `Script` component.

2. **The engine loaded `player.lua`**, stored the returned table `M` as a
   prototype, and created a fresh `self` table for this entity instance. The
   `self` table has a hidden metatable pointing to `M`, so method calls like
   `M:start` are found automatically.

3. **The engine called `start`** on the `self` table. This set
   `self.speed = 200` and printed the log message.

4. **Every frame**, the engine called `update(dt)` on the `self` table. Each
   call moved the sprite right by `200 * dt` pixels.

5. **The renderer** drew the sprite at its new position, and the cycle
   repeated -- 60 times per second.

The entire pipeline from "scene file" to "sprite on screen" is just these
five steps. Every Ember game, no matter how complex, is built from the same
building blocks: entities described in `.zson`, behaviors written in `.lua`,
and the engine tying them together frame after frame. The editor automates
the creation of these files, but understanding them gives you full control.

---

## Try These Exercises

Each modification below teaches a new concept. Make one change at a time and
run the game to see the effect.

### Exercise 1: Move Diagonally

Change the `update` function to move both horizontally and vertically:

```lua
function M:update(dt)
  actor.move_by(self, self.speed * dt, self.speed * dt)
end
```

The second argument is now `self.speed * dt` instead of `0`, so the sprite
moves down as well as right. You should see a diagonal path.

> **What you learned:** The `actor.move_by` function takes `(self, dx, dy)`.
> Changing either argument changes the direction of movement.

### Exercise 2: Bounce Off Screen Edges

Replace the entire script with this version:

```lua
local M = {}

function M:start()
  self.speed = 200
  self.min_x = 0
  self.max_x = 1280
end

function M:update(dt)
  local x, y = actor.get_position(self)
  local nx = x + self.speed * dt
  if nx > self.max_x or nx < self.min_x then
    self.speed = -self.speed
    nx = x + self.speed * dt
  end
  actor.set_position(self, nx, y)
end

return M
```

This introduces several new ideas:

- **`actor.get_position(self)`** -- Reads the entity's current position,
  returning `x` and `y`.
- **`if ... then ... end`** -- A conditional. If the new x position would
  go past the right edge (1280) or the left edge (0), we flip the speed
  (making it negative) so the sprite reverses direction.
- **`actor.set_position(self, nx, y)`** -- Directly sets the entity's
  position. Unlike `move_by`, this is an absolute set, not a relative move.

> **What you learned:** You can read state, make decisions based on it, and
> write state back. This is the core loop of almost all game logic.

### Exercise 3: Respond to Keyboard Input

Replace the `update` function with this version:

```lua
function M:update(dt)
  local dx = input.get_axis("move_left", "move_right")
  local dy = input.get_axis("move_up", "move_down")
  actor.move_by(self, dx * self.speed * dt, dy * self.speed * dt)
end
```

Now the sprite responds to the arrow keys (or WASD, depending on your key
bindings). Hold Right to move right, Left to move left, and so on.

- **`input.get_axis(negative, positive)`** -- Returns -1 if the "negative"
  action is held, +1 if the "positive" action is held, and 0 if neither (or
  both) are held. This is called an **axis** because it represents a
  one-dimensional range of input.

> **What you learned:** Ember uses **action-based input** instead of raw
> key codes. This means you can rebind keys, support gamepads, and change
> controls without touching your Lua code.

---

## Next Steps

You have just learned the absolute fundamentals. Here is where to go next:

- **[Understanding Scenes](first-scene.md)** -- Learn the full `.zson` format: entity
  hierarchies, velocity, cameras, and the design decisions behind the format.
- **[Understanding Behaviors](first-script.md)** -- Dive deeper into the behavior
  lifecycle, the `self` table, and the full engine API.
- **[First Game](../guides/first-game.md)** -- Build a complete mini-game
  from scratch.
- **[Learning Lua](../guides/learning-lua.md)** -- Master Lua from zero,
  including all the concepts used in Ember scripts.

Take your time with each guide. Game development is a marathon, not a sprint.
The fact that you got something moving on screen means you are already on
your way!
