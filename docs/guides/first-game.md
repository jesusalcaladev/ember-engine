# First Game: A Simple Collector

This tutorial builds a complete mini-game: a player that moves with arrow keys,
collects coins, and tracks score. It combines a `.zson` scene with Lua behaviors.

## What We Are Building

- A **player** that moves with arrow keys (or WASD)
- **Coins** that spawn randomly and disappear when collected
- A **score counter** that increments on each coin
- A **game over** condition when time runs out

## Project Structure

```
my_game/
├── game.zson          # The scene
├── player.lua         # Player behavior
├── coin.lua           # Coin behavior
└── spawner.lua        # Coin spawner behavior
```

## Step 1: The Scene

Create `game.zson`:

```
zson 1

entity 1 {
  Name "camera"
  Transform {position: {x: 640, y: 360}, rotation: 0, scale: {x: 1, y: 1}}
}

entity 2 {
  Name "player"
  Transform {position: {x: 640, y: 360}, rotation: 0, scale: {x: 1, y: 1}}
  Parent {parent: 1}
  Sprite {atlas: 0, layer: 0, size: {x: 32, y: 32}, tint: [0.2, 0.6, 1, 1], blend: alpha, visible: true}
  Script {script: 1}
}

entity 3 {
  Name "spawner"
  Transform {position: {x: 0, y: 0}, rotation: 0, scale: {x: 1, y: 1}}
  Parent {parent: 1}
  Script {script: 3}
}
```

This creates:
- A **camera** at the center of a 1280x720 screen
- A **player** (blue square) with script id 1
- A **spawner** (invisible) with script id 3

## Step 2: The Player Script

Create `player.lua`:

```lua
local M = {}

function M:start()
  self.speed = 300
  self.score = 0
  self.alive = true
end

function M:update(dt)
  if not self.alive then return end

  -- Read input as a signed axis
  local dx = input.get_axis("move_left", "move_right")
  local dy = input.get_axis("move_up", "move_down")

  -- Normalize diagonal movement
  local len = math.sqrt(dx * dx + dy * dy)
  if len > 0 then
    dx = dx / len
    dy = dy / len
  end

  -- Move
  actor.move_by(self, dx * self.speed * dt, dy * self.speed * dt)

  -- Clamp to screen bounds
  local x, y = actor.get_position(self)
  x = math.clamp(x, 16, 1264)
  y = math.clamp(y, 16, 704)
  actor.set_position(self, x, y)
end

function M:on_signal(name)
  if name == "collect" then
    self.score = self.score + 1
    log.info("score: " .. self.score)
  end
end

function M:on_destroy()
  log.info("game over! final score: " .. self.score)
end

return M
```

## Step 3: The Coin Script

Create `coin.lua`:

```lua
local M = {}

function M:start()
  self.collected = false
  -- Random tint for variety
  self.tint_r = rand.float(0.5, 1)
  self.tint_g = rand.float(0.5, 1)
  self.tint_b = rand.float(0, 0.3)
end

function M:update(dt)
  if self.collected then return end

  -- Check distance to player
  local player = self.world.player_ref
  if not player then return end

  local d = actor.distance_to(self, player)
  if d < 24 then
    self.collected = true
    actor.emit(player, "collect")
    actor.destroy(self)
  end
end

return M
```

## Step 4: The Spawner Script

Create `spawner.lua`:

```lua
local M = {}

function M:start()
  self.spawn_timer = 0
  self.spawn_interval = 1.5
  self.max_coins = 10
  self.coin_count = 0
  self.time_left = 30
  self.game_over = false
end

function M:update(dt)
  if self.game_over then return end

  -- Countdown
  self.time_left = self.time_left - dt
  if self.time_left <= 0 then
    self.time_left = 0
    self.game_over = true
    log.info("time's up!")
    return
  end

  -- Spawn coins
  self.spawn_timer = self.spawn_timer + dt
  if self.spawn_timer >= self.spawn_interval and self.coin_count < self.max_coins then
    self.spawn_timer = 0
    self:spawn_coin()
  end
end

function M:spawn_coin()
  -- Find the player to set as target
  local player = self.world.player_ref
  if not player then return end

  -- Spawn at random position
  local x = rand.float(50, 1230)
  local y = rand.float(50, 670)

  -- Create coin entity
  local coin = actor.spawn(self, "coin")
  actor.set_position(coin, x, y)
  actor.add_component(coin, "Sprite", {
    atlas = 0,
    layer = 1,
    size = {x = 16, y = 16},
    tint = {1, 0.8, 0.2, 1},
    blend = "alpha",
    visible = true,
  })
  actor.add_component(coin, "Script", {script = 2})

  self.coin_count = self.coin_count + 1
end

function M:on_signal(name)
  if name == "coin_collected" then
    self.coin_count = self.coin_count - 1
  end
end

return M
```

## Step 5: Wire It Up

The scripts reference `self.world.player_ref`. This is a bridge the engine
provides. In a real game, you would set this up in the scene or via the editor.
For this tutorial, add this to `spawner.lua`'s `start`:

```lua
function M:start()
  -- ... existing code ...

  -- Find the player entity and store the reference
  -- In a real game, the editor or a bootstrap script would do this
  self.world.player_ref = actor.find_by_name(self, "player")
end
```

## Step 6: Run It

```bash
zig build run -- game.zson
```

You should see:
- A blue square (player) that moves with arrow keys
- Yellow squares (coins) that spawn randomly
- Coins disappear when you touch them
- Score increases in the log
- Game ends after 30 seconds

## What You Learned

- **Scenes**: How to define entities, components, and hierarchy in `.zson`
- **Behaviors**: The lifecycle (`start`, `update`, `on_signal`, `on_destroy`)
- **Input**: Reading action-based input with `input.get_axis`
- **Movement**: `actor.move_by` for per-frame movement
- **Spatial queries**: `actor.distance_to` for proximity checks
- **Signals**: `actor.emit` for communication between actors
- **Spawning**: `actor.spawn` and `actor.add_component` at runtime
- **Determinism**: `rand.float` for reproducible randomness

## Next Steps

- [Learning Lua](learning-lua.md) — Deepen your Lua knowledge
- [Lua API Reference](../reference/script-lua-api.md) — Every function available
- [State Machines](../reference/script-state-machines.md) — Add idle/run/jump states
- [Steering Behaviors](../reference/script-lua-api.md#steer) — Add enemy AI
