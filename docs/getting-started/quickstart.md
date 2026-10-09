# Quickstart: Something Moving in 5 Minutes

This guide gets a sprite moving on screen as fast as possible. No prior
experience with Ember required.

## Prerequisites

You have built the engine. If not, see [Installation](installation.md).

## Step 1: Create a Scene

Create a file called `quickstart.zson`:

```
zson 1

entity 1 {
  Name "player"
  Transform {position: {x: 100, y: 100}, rotation: 0, scale: {x: 1, y: 1}}
  Sprite {atlas: 0, layer: 0, size: {x: 32, y: 32}, tint: [1, 1, 1, 1], blend: alpha, visible: true}
  Script {script: 1}
}
```

This creates one entity with:
- A **name** ("player")
- A **transform** (position at 100, 100)
- A **sprite** (32x32 white square)
- A **script** (id 1 — we will write this next)

## Step 2: Create a Script

Create a file called `player.lua`:

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

This script:
- Sets a speed of 200 pixels per second in `start`
- Moves the actor right every frame in `update`

## Step 3: Run It

```bash
zig build run -- quickstart.zson
```

You should see a white square moving to the right across a black screen.

## What Just Happened?

1. The engine loaded `quickstart.zson` and created one entity with a sprite.
2. The engine loaded `player.lua` and bound it to that entity.
3. Every frame, the engine called `M:update(dt)` on the script.
4. `actor.move_by(self, self.speed * dt, 0)` moved the sprite right.

## Try These Modifications

**Make it move diagonally:**

```lua
function M:update(dt)
  actor.move_by(self, self.speed * dt, self.speed * dt)
end
```

**Make it bounce off the screen edges:**

```lua
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
```

**Make it respond to input:**

```lua
function M:update(dt)
  local dx = input.get_axis("move_left", "move_right")
  local dy = input.get_axis("move_up", "move_down")
  actor.move_by(self, dx * self.speed * dt, dy * self.speed * dt)
end
```

## Next Steps

- [First Scene](first-scene.md) — Learn the full `.zson` format
- [First Script](first-script.md) — Learn the behavior lifecycle
- [First Game](../guides/first-game.md) — Build a complete mini-game
- [Learning Lua](../guides/learning-lua.md) — Master Lua from zero
