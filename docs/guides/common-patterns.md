# Common Patterns

Ready-to-use code patterns for common game mechanics.

## Movement

### 8-Directional Movement

```lua
function M:update(dt)
  local dx = input.get_axis("move_left", "move_right")
  local dy = input.get_axis("move_up", "move_down")

  -- Normalize so diagonal is not faster
  local len = math.sqrt(dx * dx + dy * dy)
  if len > 0 then
    dx = dx / len
    dy = dy / len
  end

  actor.move_by(self, dx * self.speed * dt, dy * self.speed * dt)
end
```

### Smooth Acceleration

```lua
function M:start()
  self.vx = 0
  self.vy = 0
  self.accel = 2000
  self.max_speed = 300
  self.friction = 10
end

function M:update(dt)
  local dx = input.get_axis("move_left", "move_right")
  local dy = input.get_axis("move_up", "move_down")

  -- Accelerate
  self.vx = self.vx + dx * self.accel * dt
  self.vy = self.vy + dy * self.accel * dt

  -- Apply friction
  self.vx = math.damp(self.vx, 0, self.friction, dt)
  self.vy = math.damp(self.vy, 0, self.friction, dt)

  -- Clamp to max speed
  local speed = math.sqrt(self.vx * self.vx + self.vy * self.vy)
  if speed > self.max_speed then
    local scale = self.max_speed / speed
    self.vx = self.vx * scale
    self.vy = self.vy * scale
  end

  actor.move_by(self, self.vx * dt, self.vy * dt)
end
```

## Camera

### Follow a Target

```lua
function M:start()
  self.target = nil
  self.lerp_speed = 5
  self.offset = {x = 0, y = 0}
end

function M:update(dt)
  if not self.target then return end

  local tx, ty = actor.get_position(self.target)
  tx = tx + self.offset.x
  ty = ty + self.offset.y

  local x, y = actor.get_position(self)
  x = math.damp(x, tx, self.lerp_speed, dt)
  y = math.damp(y, ty, self.lerp_speed, dt)

  actor.set_position(self, x, y)
end
```

### Camera with Lookahead

```lua
function M:start()
  self.target = nil
  self.lookahead = 50
end

function M:update(dt)
  if not self.target then return end

  local tx, ty = actor.get_position(self.target)
  local tvx, tvy = actor.get_velocity(self.target)

  -- Look ahead in the direction of movement
  tx = tx + tvx * 0.1
  ty = ty + tvy * 0.1

  local x, y = actor.get_position(self)
  x = math.damp(x, tx, 5, dt)
  y = math.damp(y, ty, 5, dt)

  actor.set_position(self, x, y)
end
```

## Collision

### Circle-Circle Collision

```lua
function M:update(dt)
  local x, y = actor.get_position(self)
  local r = self.radius

  world.nearby(self, x, y, r * 2, function(other)
    if other == self then return end

    local ox, oy = actor.get_position(other)
    local d = actor.distance_to(self, other)
    local min_dist = r + other.radius

    if d < min_dist and d > 0 then
      -- Push apart
      local nx, ny = actor.direction_to(self, other)
      local push = (min_dist - d) * 0.5
      actor.move_by(self, -nx * push, -ny * push)
      actor.move_by(other, nx * push, ny * push)
    end
  end)
end
```

### Keep Actor in Bounds

```lua
function M:start()
  self.hw, self.hh = actor.get_half_size(self)
  self.min_x = self.hw
  self.max_x = 1280 - self.hw
  self.min_y = self.hh
  self.max_y = 720 - self.hh
end

function M:update(dt)
  local x, y = actor.get_position(self)
  x = math.clamp(x, self.min_x, self.max_x)
  y = math.clamp(y, self.min_y, self.max_y)
  actor.set_position(self, x, y)
end
```

## Spawning

### Object Pool

```lua
function M:start()
  self.pool = {}
  self.pool_size = 50
  self.active = {}

  -- Pre-spawn hidden actors
  for i = 1, self.pool_size do
    local obj = actor.spawn(self, "pooled_obj")
    actor.set_position(obj, 0, 0)
    actor.set_visible(obj, false)
    table.insert(self.pool, obj)
  end
end

function M:get_from_pool()
  for _, obj in ipairs(self.pool) do
    if not self.active[obj] then
      self.active[obj] = true
      actor.set_visible(obj, true)
      return obj
    end
  end
  return nil
end

function M:return_to_pool(obj)
  self.active[obj] = nil
  actor.set_visible(obj, false)
end
```

### Timed Spawner

```lua
function M:start()
  self.timer = 0
  self.interval = 2.0
  self.max_alive = 20
  self.alive = 0
end

function M:update(dt)
  self.timer = self.timer + dt
  if self.timer >= self.interval and self.alive < self.max_alive then
    self.timer = 0
    self:spawn()
  end
end

function M:spawn()
  local obj = actor.spawn(self, "enemy")
  local x = rand.float(0, 1280)
  actor.set_position(obj, x, -50)
  self.alive = self.alive + 1
end
```

## State Management

### Simple Timer

```lua
function M:start()
  self.duration = 3.0
  self.elapsed = 0
  self.finished = false
end

function M:update(dt)
  if self.finished then return end

  self.elapsed = self.elapsed + dt
  if self.elapsed >= self.duration then
    self.finished = true
    self:on_finish()
  end
end

function M:on_finish()
  log.info("timer finished!")
end
```

### Cooldown

```lua
function M:start()
  self.cooldown = 1.0
  self.timer = 0
  self.ready = true
end

function M:update(dt)
  if not self.ready then
    self.timer = self.timer - dt
    if self.timer <= 0 then
      self.ready = true
    end
  end
end

function M:try_use()
  if not self.ready then return false end

  self:use()
  self.ready = false
  self.timer = self.cooldown
  return true
end
```

## Signals

### Damage System

```lua
-- In the damage dealer:
function M:attack()
  world.nearby(self, x, y, 50, function(target)
    actor.emit(target, "damage", {amount = 10, source = self})
  end)
end

-- In the damage receiver:
function M:on_signal(name, payload)
  if name == "damage" then
    self.hp = self.hp - payload.amount
    if self.hp <= 0 then
      actor.emit(self, "died")
      actor.destroy(self)
    end
  end
end
```

## Animation (Sprite Cycling)

```lua
function M:start()
  self.frame = 0
  self.frame_time = 0
  self.frame_duration = 0.1
  self.frames = 4  -- number of frames in the atlas row
end

function M:update(dt)
  self.frame_time = self.frame_time + dt
  if self.frame_time >= self.frame_duration then
    self.frame_time = 0
    self.frame = (self.frame + 1) % self.frames
    -- Update UV rect to show the current frame
    local u0 = self.frame / self.frames
    local u1 = (self.frame + 1) / self.frames
    actor.set_sprite_uv(self, u0, 0, u1, 1)
  end
end
```

## Next Steps

- [Lua API Reference](../reference/script-lua-api.md) — Full function list
- [State Machines](../reference/script-state-machines.md) — Declarative state management
- [Steering Behaviors](../reference/script-lua-api.md#steer) — AI movement
