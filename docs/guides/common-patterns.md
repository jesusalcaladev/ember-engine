# Common Patterns

Welcome! This guide is a patient, from-first-principles walkthrough of the patterns you'll reach for again and again when building games with Ember Engine. Each pattern follows the same rhythm:

1. **The problem** — what goes wrong without it
2. **The solution** — code that fixes it
3. **Why it works** — the reasoning, not just the recipe
4. **When to use it / when not to** — so you reach for the right tool
5. **Common mistakes** — the traps that bite everyone
6. **Try this** — small variations to experiment with

Take your time. Read the "why" sections — they're the part that turns a copy-paste snippet into something you can adapt to your own game.

---

## Pattern Selection Guide

Not sure which pattern you need? Start here. Find the mechanic you're building, then jump to that pattern.

| Game mechanic | Pattern | Section |
|---|---|---|
| Player moves with arrow keys / WASD | 8-Directional Movement | [Movement](#movement) |
| Player should feel weighty, not robotic | Smooth Acceleration | [Movement](#movement) |
| Multiple systems affect the same movement | Velocity-Based Movement | [Movement](#movement) |
| Enemies chase the player | Seek | [Steering](#steering) |
| Enemies run away when hurt | Flee | [Steering](#steering) |
| Enemies slow down as they reach a target | Arrive | [Steering](#steering) |
| Enemies lead their shots at a moving player | Pursue | [Steering](#steering) |
| Enemies mill about idly | Wander | [Steering](#steering) |
| A flock of birds or school of fish | Flocking | [Steering](#steering) |
| Enemies navigate around obstacles | Avoid Obstacles | [Steering](#steering) |
| Camera trails behind the player | Camera Follow | [Camera](#camera) |
| Camera shows more of where you're heading | Camera Lookahead | [Camera](#camera) |
| Camera stops at the edge of the world | Camera Bounds | [Camera](#camera) |
| Two characters bump into each other | Circle-Circle Collision | [Collision](#collision) |
| Platformer hitboxes | AABB Collision | [Collision](#collision) |
| Hundreds of actors checking proximity | Spatial Grid Queries | [Collision](#collision) |
| Bullets, particles, or enemies appear often | Object Pool | [Spawning](#spawning) |
| Enemies appear every few seconds | Timed Spawner | [Spawning](#spawning) |
| A power-up lasts 5 seconds | Simple Timer | [State Management](#state-management) |
| A sword swing has a 0.5s recovery | Cooldown | [State Management](#state-management) |
| An enemy has idle / chase / attack modes | State Machine | [State Management](#state-management) |
| Taking damage, firing events, UI updates | Signals | [Signals](#signals) |
| A character plays a walk cycle | Sprite Cycling | [Animation](#animation) |

---

## Movement

Movement is the first thing most people build, and it's where the engine's design philosophy shows up most clearly: **one C call per move, no allocation, no hidden costs**.

### 8-Directional Movement

#### The problem

You want the player to move with the arrow keys (or WASD). The naive approach — "if left is held, subtract from x; if right is held, add to x" — works, but it has a subtle flaw: **diagonal movement is faster**. If the player holds both right and down, they move about 1.41 times faster than holding just right. In a game, this feels wrong — players notice, even if they can't articulate why.

#### The solution

```lua
local M = {}

function M:start()
  self.speed = 300
end

function M:update(dt)
  -- Read input as a signed axis: -1, 0, or +1
  local dx = input.get_axis("move_left", "move_right")
  local dy = input.get_axis("move_up", "move_down")

  -- Normalize so diagonal is not faster
  local len = math.sqrt(dx * dx + dy * dy)
  if len > 0 then
    dx = dx / len
    dy = dy / len
  end

  -- Move: one C call, no allocation
  actor.move_by(self, dx * self.speed * dt, dy * self.speed * dt)
end

return M
```

#### Why it works

`input.get_axis` returns a value in [-1, 1]. When you press two directions at once, you get a vector like (1, 1) — which has length √2 ≈ 1.41. Without normalization, that vector scales the speed by 1.41, making diagonal movement faster.

Normalization divides the vector by its own length, producing a **unit vector** — a vector of length exactly 1 that points in the same direction. Now every direction moves at the same speed.

The `if len > 0` guard matters: if no keys are pressed, `dx` and `dy` are both 0, and dividing by zero would produce NaN. The guard skips the division entirely when there's nothing to normalize.

`actor.move_by` is the engine's preferred movement function. It reads the current position, adds the delta, and writes the result back — all in a single C call. The alternative (`get_position` + `set_position`) costs two or three calls and is measurably slower in a hot loop.

> **When to use this:** Top-down movement, twin-stick shooters, grid-free movement where the player can move in any direction.

> **When NOT to use this:** Platformers (you want gravity and jumping, not free 8-directional movement), grid-based games (you want discrete tile steps), or games where diagonal *should* be faster (some racing games).

> **Common mistakes:**
> - **Forgetting to normalize.** The bug is subtle — the game "works," but diagonal feels faster. Playtest with a stopwatch: time a diagonal crossing vs. a straight crossing.
> - **Using `actor.translate` instead of `actor.move_by`.** They behave the same, but `move_by` is one C call instead of two. In a game with hundreds of actors, the difference adds up.
> - **Not guarding against zero length.** If both `dx` and `dy` are 0, `math.sqrt(0)` is 0, and `0 / 0` is NaN. The `if len > 0` check prevents this.

> **Try this:**
> - Add a "sprint" modifier: when Shift is held, multiply `self.speed` by 1.5.
> - Add a "slow" zone: when the player is in mud, multiply `dt` by 0.5 for movement only.
> - Make the character face the movement direction: `actor.set_rotation(self, math.atan2(dy, dx))`.

---

### Smooth Acceleration

#### The problem

The 8-directional pattern above is **instantaneous** — the player moves at full speed the moment you press a key, and stops the instant you release it. This feels robotic. Real things have mass: they speed up gradually and slow down gradually. In game-feel terms, this is the difference between a character that feels like a cursor and a character that feels like a body.

#### The solution

```lua
local M = {}

function M:start()
  self.vx = 0
  self.vy = 0
  self.accel = 2000        -- how fast we reach full speed (units/s^2)
  self.max_speed = 300     -- speed cap (units/s)
  self.friction = 10       -- how fast we slow down when no input (higher = snappier stop)
end

function M:update(dt)
  local dx = input.get_axis("move_left", "move_right")
  local dy = input.get_axis("move_up", "move_down")

  -- Accelerate: add to velocity each frame
  self.vx = self.vx + dx * self.accel * dt
  self.vy = self.vy + dy * self.accel * dt

  -- Apply friction: decay velocity toward zero when no input
  self.vx = math.damp(self.vx, 0, self.friction, dt)
  self.vy = math.damp(self.vy, 0, self.friction, dt)

  -- Clamp to max speed (preserves direction, caps magnitude)
  local speed = math.sqrt(self.vx * self.vx + self.vy * self.vy)
  if speed > self.max_speed then
    local scale = self.max_speed / speed
    self.vx = self.vx * scale
    self.vy = self.vy * scale
  end

  actor.move_by(self, self.vx * dt, self.vy * dt)
end

return M
```

#### Why it works

This pattern introduces **velocity** as a persistent state variable. Instead of position being a direct function of input, position is the integral of velocity, and velocity is the integral of acceleration. This is Newtonian physics, simplified:

- **Acceleration** (`self.accel`) controls how quickly velocity builds up. A high value feels responsive; a low value feels floaty.
- **Friction** (`math.damp`) controls how quickly velocity decays when there's no input. `math.damp` is frame-rate independent — it produces the same curve whether the game runs at 30 or 144 fps.
- **The speed clamp** prevents the velocity from growing without bound. Without it, holding a direction for 10 seconds would give you 10x the intended speed.

The key insight: `math.damp(current, target, rate, dt)` is **not** a lerp. A lerp moves a fixed fraction of the remaining distance each frame, which is frame-rate dependent (faster at high fps). `math.damp` uses an exponential decay that's mathematically equivalent regardless of frame rate. This is why the engine provides it and why you should prefer it over a raw `math.lerp` for smoothing.

> **When to use this:** Character controllers where weight and momentum matter — action games, racing games, anything where the player should feel like they have mass.

> **When NOT to use this:** Puzzle games with grid movement, turn-based games, or any game where instant response is more important than feel.

> **Common mistakes:**
> - **Applying friction even when accelerating.** If you damp toward 0 while also adding acceleration, the two fight each other and the character feels sluggish. The fix: only apply friction when there's no input on that axis, or use a lower friction value.
> - **Forgetting the speed clamp.** Acceleration adds `accel * dt` every frame. After 5 seconds of holding right, `vx` would be `2000 * 5 = 10000` — ten times the intended max speed.
> - **Using `math.lerp` instead of `math.damp`.** Lerp is frame-rate dependent. At 144 fps, the character stops almost instantly; at 30 fps, they slide. `math.damp` is consistent.

> **Try this:**
> - Make the character skid: when input direction changes sharply, reduce friction temporarily so the character slides.
> - Add a dash: on Shift press, set `vx` and `vy` to a high value in the facing direction, then let friction bring them back down.
> - Tune the feel: try `accel = 5000, friction = 20` for a snappy arcade feel, or `accel = 800, friction = 3` for a heavy, tank-like feel.

---

### Velocity-Based Movement

#### The problem

The two patterns above are really two ends of a spectrum: instant response vs. smooth acceleration. But there's a third option that's often the right choice: **velocity as a first-class concept**. Instead of thinking "move by this much this frame," think "I have a velocity, and I update it based on what's happening." This is the pattern that steering behaviors (later in this guide) build on.

#### The solution

```lua
local M = {}

function M:start()
  self.vx = 0
  self.vy = 0
  self.max_speed = 300
  self.accel = 1500
end

function M:update(dt)
  -- Read desired direction
  local dx = input.get_axis("move_left", "move_right")
  local dy = input.get_axis("move_up", "move_down")

  -- Compute desired velocity
  local desired_vx = dx * self.max_speed
  local desired_vy = dy * self.max_speed

  -- Move current velocity toward desired velocity
  self.vx = math.damp(self.vx, desired_vx, 8, dt)
  self.vy = math.damp(self.vy, desired_vy, 8, dt)

  actor.move_by(self, self.vx * dt, self.vy * dt)
end

return M
```

#### Why it works

This is a refinement of smooth acceleration. Instead of applying acceleration and friction separately, we compute a **desired velocity** (what the velocity would be if we were at full speed in the input direction) and then damp the current velocity toward it.

The advantage: the same pattern works for any movement source. Player input sets the desired velocity. A knockback impulse adds to the current velocity. A current or conveyor belt adds to the desired velocity. Everything composes because velocity is the single source of truth.

The `math.damp` rate (8 in the example) controls how snappy the response is. A higher rate means the velocity converges to the desired value faster.

> **When to use this:** Any game where multiple systems might affect movement — player input, knockback, conveyor belts, ice physics, wind. If you find yourself adding more and more special cases to your movement code, this pattern is the refactor.

> **When NOT to use this:** Simple games where the 8-directional pattern is enough. Don't add complexity you don't need.

> **Common mistakes:**
> - **Damping toward the wrong target.** If you damp toward `input * max_speed` but then also apply friction, you're double-counting. Pick one model: either damp toward desired velocity, or apply acceleration + friction. Don't mix them.
> - **Forgetting that `dt` is in seconds.** If your `dt` is in milliseconds, all your tuning values will be off by 1000x.

> **Try this:**
> - Add a "boost" power-up: temporarily increase `self.max_speed` for 3 seconds.
> - Add ice: when on ice, lower the damp rate so the character slides.
> - Add knockback: when hit, add an impulse to `self.vx` and `self.vy`, then let the damp pull it back to normal.

---

## Camera

The camera is the player's window into the world. A bad camera is the number one cause of motion sickness and frustration in games. These patterns cover the three things every camera needs: following the player, showing where they're going, and not showing what's beyond the world.

### Camera Follow

#### The problem

The camera should center on the player. The naive approach — `camera.position = player.position` every frame — works, but it's **jarring**. When the player moves, the camera snaps instantly. There's no sense of weight or smoothness. It feels like a security camera, not a game camera.

#### The solution

```lua
local M = {}

function M:start()
  self.target = nil          -- set this to the player's self table
  self.lerp_speed = 5        -- higher = snappier follow
  self.offset = {x = 0, y = 0}  -- optional offset from target center
end

function M:update(dt)
  if not self.target then return end

  -- Where we want to be
  local tx, ty = actor.get_position(self.target)
  tx = tx + self.offset.x
  ty = ty + self.offset.y

  -- Where we are now
  local x, y = actor.get_position(self)

  -- Smooth toward the target
  x = math.damp(x, tx, self.lerp_speed, dt)
  y = math.damp(y, ty, self.lerp_speed, dt)

  actor.set_position(self, x, y)
end

return M
```

#### Why it works

`math.damp` is the star here. It moves the camera a fraction of the remaining distance each frame, but the fraction is **frame-rate independent** — the camera follows the same curve at any refresh rate.

The `lerp_speed` parameter controls the feel:
- **Low (1-3):** Lazy, cinematic follow. The camera lags behind the player.
- **Medium (5-8):** Standard action-game feel. Responsive but smooth.
- **High (15+):** Nearly instant. Approaches the "snap" of the naive approach.

The offset is useful for games where the camera shouldn't be exactly centered — a platformer might offset the camera upward so the player sees more of what's above them.

> **When to use this:** Any game where the camera follows a player or object. This is the default starting point for 90% of games.

> **When NOT to use this:** Games with a fixed camera (puzzle games, visual novels), or games where the camera is on a rail (some platformers).

> **Common mistakes:**
> - **Using `math.lerp` with a fixed fraction.** `x = math.lerp(x, tx, 0.1)` is frame-rate dependent — the camera follows faster at high fps. Use `math.damp` instead.
> - **Not setting `self.target`.** The `if not self.target then return end` guard prevents a crash, but the camera won't move. Make sure to assign the target in `start` or from another script.
> - **Forgetting that `get_position` returns two values.** `local x, y = actor.get_position(self)` — if you write `local x = actor.get_position(self)`, `x` gets the x-coordinate and `y` is lost.

> **Try this:**
> - Add a deadzone: the camera only moves when the player is more than 50 units from the center. This prevents jitter when the player is standing still.
> - Add screen shake: on impact, add a random offset to the camera position that decays over time.
> - Make the follow speed dynamic: faster when the player is moving fast, slower when they're moving slow.

---

### Camera Lookahead

#### The problem

A camera that centers exactly on the player shows equal amounts of what's behind and what's ahead. But players care more about what's **ahead** — where they're going, what's coming. A camera that shows more of the direction of movement lets the player react sooner and feels more natural.

#### The solution

```lua
local M = {}

function M:start()
  self.target = nil
  self.lookahead_time = 0.1  -- seconds of movement to look ahead
  self.lerp_speed = 5
end

function M:update(dt)
  if not self.target then return end

  local tx, ty = actor.get_position(self.target)

  -- Track the target's velocity manually (the engine has no get_velocity)
  local prev_x = self.prev_target_x or tx
  local prev_y = self.prev_target_y or ty
  local tvx = (tx - prev_x) / dt
  local tvy = (ty - prev_y) / dt
  self.prev_target_x = tx
  self.prev_target_y = ty

  -- Look ahead in the direction of movement
  tx = tx + tvx * self.lookahead_time
  ty = ty + tvy * self.lookahead_time

  local x, y = actor.get_position(self)
  x = math.damp(x, tx, self.lerp_speed, dt)
  y = math.damp(y, ty, self.lerp_speed, dt)

  actor.set_position(self, x, y)
end

return M
```

#### Why it works

The camera target is shifted in the direction of the target's velocity. The `lookahead_time` is a tuning constant — it controls how much the camera leads the player. A higher value means the camera shows more of what's ahead; a lower value keeps it closer to centered.

The key insight: **lookahead is proportional to speed**. When the player is standing still, `tvx` and `tvy` are 0, so the camera centers normally. When the player is moving fast, the camera shifts further ahead. This is exactly what you want — you need more lookahead at high speeds because that's when reaction time matters most.

Since the engine doesn't expose a `get_velocity` function, we track velocity manually by storing the target's previous position and computing the difference. This is a common pattern when you need velocity but the engine doesn't provide it directly.

> **When to use this:** Side-scrolling platformers, racing games, any game where the player moves primarily in one direction and needs to see what's coming.

> **When NOT to use this:** Top-down games where the player can change direction instantly (the lookahead would be constantly swinging), or games where the camera is already offset for other reasons.

> **Common mistakes:**
> - **Using a fixed offset instead of velocity-based.** A fixed offset to the right works for a game that only scrolls right, but breaks the moment the player turns around. Velocity-based lookahead adapts automatically.
> - **Too much lookahead.** If the `lookahead_time` is too high (say, 0.5), the player is constantly near the edge of the screen and can't see threats behind them. Start with 0.1 and tune up only if needed.
> - **Not handling the first frame.** On the first frame, `self.prev_target_x` is nil, so the velocity calculation would fail. The `or tx` fallback handles this.

> **Try this:**
> - Add vertical lookahead for platformers: when the player is falling, shift the camera down so they can see the landing.
> - Smooth the lookahead: instead of using raw velocity, damp the lookahead offset so it doesn't snap when the player changes direction.
> - Add a "look back" feature: when the player holds a key, shift the camera in the opposite direction to see what's behind.

---

### Camera Bounds

#### The problem

Without bounds, the camera will happily show the void beyond the edge of your world. If your level is 2000 units wide but the world is infinite, the camera will follow the player into empty space. You need to clamp the camera so it stops at the edges.

#### The solution

```lua
local M = {}

function M:start()
  self.target = nil
  self.lerp_speed = 5

  -- World boundaries (adjust to your level size)
  self.min_x = 0
  self.max_x = 2000
  self.min_y = 0
  self.max_y = 1200

  -- View size (half-width and half-height of the camera view)
  self.half_w = 640
  self.half_h = 360
end

function M:update(dt)
  if not self.target then return end

  local tx, ty = actor.get_position(self.target)

  -- Clamp the target so the camera never shows beyond the world
  tx = math.clamp(tx, self.min_x + self.half_w, self.max_x - self.half_w)
  ty = math.clamp(ty, self.min_y + self.half_h, self.max_y - self.half_h)

  local x, y = actor.get_position(self)
  x = math.damp(x, tx, self.lerp_speed, dt)
  y = math.damp(y, ty, self.lerp_speed, dt)

  actor.set_position(self, x, y)
end

return M
```

#### Why it works

The camera is clamped so that its **edges** never go past the world boundaries. The camera's center can't go below `min_x + half_w` because that would put the left edge of the view (`center - half_w`) past `min_x`.

The `half_w` and `half_h` values depend on your resolution and zoom. For a 1280x720 view, the half-extents are 640 and 360. If you zoom in or out, these change.

The clamping happens **before** the damp, so the camera smoothly approaches the boundary and stops — it doesn't snap.

> **When to use this:** Any game with a bounded world. If your world is smaller than the screen, you can skip this — just center the camera on the world.

> **When NOT to use this:** Infinite or procedurally generated worlds (you'd need to generate bounds dynamically), or games where showing the void is intentional (some horror games).

> **Common mistakes:**
> - **Forgetting the half-extents.** If you clamp the camera center to `[min_x, max_x]` without accounting for the view size, the camera will show half a screen of void at the edges.
> - **Clamping after the damp.** If you damp first and then clamp, the camera will overshoot the boundary and then snap back — visible as a "bounce" at the edge. Clamp the target, not the result.

> **Try this:**
> - Add a smooth boundary: instead of a hard clamp, use `math.smoothstep` to slow the camera as it approaches the edge.
> - Add a "camera pull" effect: when the player is near the edge, gently pull the camera back so they can see more of the level.
> - Support multiple bounds: different areas of the world have different camera limits (common in metroidvanias).

---

## Collision

Collision detection answers a deceptively simple question: "Is this thing touching that thing?" The answer depends on what shape you assume the things are.

### Circle-Circle Collision

#### The problem

You have two round objects — a player and an enemy, two boulders, a bullet and a target — and you need to know when they overlap. Circles are the simplest shape to test, and they're a good approximation for many game objects.

#### The solution

```lua
local M = {}

function M:start()
  self.radius = 16
end

function M:update(dt)
  local x, y = actor.get_position(self)
  local r = self.radius

  -- Ask the engine: "who is within r*2 of me?"
  world.nearby(self, x, y, r * 2, function(other)
    if other == self then return end

    local d = actor.distance_to(self, other)
    local min_dist = r + other.radius

    if d < min_dist and d > 0 then
      -- They overlap! Push them apart.
      local nx, ny = actor.direction_to(self, other)
      local push = (min_dist - d) * 0.5
      actor.move_by(self, -nx * push, -ny * push)
      actor.move_by(other, nx * push, ny * push)
    end
  end)
end

return M
```

#### Why it works

Two circles overlap when the distance between their centers is less than the sum of their radii. That's the entire test: `d < r1 + r2`.

`world.nearby` is the engine's spatial query — it uses a spatial grid to find candidates in O(1) time instead of checking every actor in the world. The `r * 2` radius is a conservative bound: if two circles of radius `r` overlap, their centers are at most `r + r = 2r` apart.

The push-apart logic uses `actor.direction_to` to get the unit vector from self to other, then moves each actor half the overlap distance in opposite directions. This is a simple **positional correction** — it resolves the overlap without simulating physics.

The `d > 0` guard prevents division by zero if two actors are at exactly the same position (which would make `direction_to` return NaN).

> **When to use this:** Any game with roughly circular objects — top-down games, billiards, particle systems, area-of-effect checks.

> **When NOT to use this:** Platformers (you want AABB for tile collision), games with rectangular objects (AABB is simpler and more accurate), or games where you need to know *which side* was hit (you'd need a more sophisticated test).

> **Common mistakes:**
> - **Not checking `other == self`.** `world.nearby` excludes the caller, but if you're querying from a different position, you might get yourself back. The guard is cheap insurance.
> - **Using `d * d < min_dist * min_dist` to avoid the sqrt.** This is a valid optimization — `actor.distance_squared_to` exists for this reason. But `actor.distance_to` is already a single C call, so the sqrt is cheap. Optimize only if profiling shows it matters.
> - **Pushing only one actor.** If you only push `self`, the other actor stays inside you. Push both (or push only the "lighter" one, depending on your game).

> **Try this:**
> - Add mass: heavier objects get pushed less. `local push_self = push * (other.mass / (self.mass + other.mass))`.
> - Add a collision event: when a collision is detected, emit a signal so other systems can react (sound, damage, etc.).
> - Make it a trigger: don't push apart, just detect the overlap and emit a signal. Useful for pickups, traps, and zone triggers.

---

### AABB Collision (Axis-Aligned Bounding Box)

#### The problem

Circles are simple, but most game objects are better approximated by rectangles — characters, tiles, walls, platforms. AABB (Axis-Aligned Bounding Box) collision is the standard for 2D platformers and tile-based games. "Axis-aligned" means the box isn't rotated — its sides are parallel to the x and y axes.

#### The solution

```lua
local M = {}

function M:start()
  -- Get the half-extents of the sprite
  self.hw, self.hh = actor.get_half_size(self)
end

function M:update(dt)
  local x, y = actor.get_position(self)

  world.nearby(self, x, y, math.max(self.hw, self.hh) * 2, function(other)
    if other == self then return end

    local ox, oy = actor.get_position(other)
    local ohw, ohh = actor.get_half_size(other)

    -- AABB overlap test: check both axes
    local overlap_x = (self.hw + ohw) - math.abs(x - ox)
    local overlap_y = (self.hh + ohh) - math.abs(y - oy)

    if overlap_x > 0 and overlap_y > 0 then
      -- They overlap! Resolve along the axis of least penetration.
      if overlap_x < overlap_y then
        -- Push apart horizontally
        local dir = x < ox and -1 or 1
        actor.move_by(self, dir * overlap_x, 0)
      else
        -- Push apart vertically
        local dir = y < oy and -1 or 1
        actor.move_by(self, 0, dir * overlap_y)
      end
    end
  end)
end

return M
```

#### Why it works

Two AABBs overlap if and only if they overlap on **both** axes. The overlap on each axis is the sum of the half-extents minus the distance between centers. If either overlap is negative, the boxes are separated on that axis and don't collide.

The resolution strategy — pushing along the axis of **least penetration** — is the standard approach. If the boxes overlap more horizontally than vertically, push them apart horizontally. This produces the most natural-looking resolution: a character landing on a platform gets pushed up, not sideways.

`actor.get_half_size` returns half the sprite's width and height, which is exactly what AABB collision needs. If the actor has no Sprite component, it returns (0, 0) — so this pattern works best for actors that have sprites.

> **When to use this:** Platformers, tile-based games, any game with rectangular objects and axis-aligned collision.

> **When NOT to use this:** Games with rotated objects (you'd need oriented bounding boxes or polygon collision), or games where everything is circular (circle-circle is simpler).

> **Common mistakes:**
> - **Resolving on the wrong axis.** If you always resolve horizontally, a character falling onto a platform will be pushed sideways instead of up. Always resolve along the axis of least penetration.
> - **Not accounting for sprite size.** If you hardcode `self.hw = 16` but the sprite is 64x64, the collision box won't match the visual. Use `actor.get_half_size`.
> - **Tunneling.** If an object moves fast enough, it can pass through a thin wall in one frame. The fix is continuous collision detection (raycasting) or limiting maximum speed.

> **Try this:**
> - Add a "grounded" check: if the resolution pushes the player up, set `self.grounded = true` so they can jump.
> - Add one-way platforms: only collide when the player is above the platform and moving down.
> - Add a "hit event": emit a signal when a collision is resolved so other systems can react.

---

### Spatial Grid Queries

#### The problem

You have hundreds or thousands of actors, and each one needs to check "who is near me?" A naive approach — every actor checks every other actor — is O(n^2). With 200 actors, that's 40,000 checks per frame. With 1000 actors, it's a million. The spatial grid is the engine's solution: it bins actors into cells so each query only checks the nearby cells.

#### The solution

```lua
local M = {}

function M:start()
  self.query_radius = 100
end

function M:update(dt)
  local x, y = actor.get_position(self)

  -- This is O(1) in the number of actors, thanks to the spatial grid
  world.nearby(self, x, y, self.query_radius, function(other)
    if other == self then return end

    -- Do something with each nearby actor
    local d = actor.distance_to(self, other)
    if d < self.query_radius then
      -- ...
    end
  end)
end

return M
```

#### Why it works

The engine maintains a **uniform spatial grid** — a grid of cells, each about 64 units across. Every frame, the grid is rebuilt: each actor is binned into the cell that contains its position. When you call `world.nearby`, the engine:

1. Finds the cells that overlap your query circle
2. Iterates the actors in those cells
3. Calls your visitor function for each one

The key insight: the number of actors in a small area is roughly constant, regardless of how many actors exist in the world. So the query is O(1) in the total number of actors — it only depends on the density of actors near the query point.

The grid is rebuilt once per frame, **before** any gameplay code runs. This means all queries during the frame see consistent positions — no actor is in two places at once.

> **When to use this:** Any game with many actors that need proximity checks — flocking, area-of-effect damage, aggro ranges, particle interactions.

> **When NOT to use this:** Games with fewer than ~50 actors (a linear scan is simpler and fast enough), or games where you need to query the same set of actors repeatedly (cache the result).

> **Common mistakes:**
> - **Querying too large a radius.** A radius of 1000 units will touch many cells and check many actors. Keep your query radius as small as possible for your use case.
> - **Modifying the world during iteration.** Don't spawn or destroy actors inside the `world.nearby` callback — it can corrupt the grid. Collect changes and apply them after.
> - **Assuming the grid is persistent.** The grid is rebuilt every frame. If you need persistent spatial data, store it yourself.

> **Try this:**
> - Use `actor.is_within_radius(self, other, radius)` for a simple boolean check without a sqrt.
> - Use `actor.distance_squared_to` when you're comparing against a fixed radius — it avoids the sqrt entirely.
> - Combine multiple queries: check for allies within 200 units and enemies within 400 units in the same frame.

---

## Spawning

Games create and destroy objects constantly — bullets, enemies, particles, pickups. Doing this naively (spawn a new actor every time) works, but it's wasteful. These patterns show you how to spawn efficiently.

### Object Pool

#### The problem

You're spawning bullets. Lots of bullets. Every bullet is a new actor, and when it leaves the screen, you destroy it. This seems fine, but actor creation and destruction are expensive — they allocate memory, update the ECS, and trigger GC pressure. At 60 bullets per second, you're creating and destroying 3600 actors per minute. The garbage collector will stutter, and your frame rate will suffer.

#### The solution

```lua
local M = {}

function M:start()
  self.pool = {}
  self.pool_size = 50
  self.active = {}

  -- Pre-spawn hidden actors
  for i = 1, self.pool_size do
    local obj = actor.spawn(self, "bullet")
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
  return nil  -- pool exhausted
end

function M:return_to_pool(obj)
  self.active[obj] = nil
  actor.set_visible(obj, false)
end

function M:update(dt)
  -- Example: fire a bullet every 0.2 seconds
  self.fire_timer = (self.fire_timer or 0) + dt
  if self.fire_timer >= 0.2 then
    self.fire_timer = 0
    local bullet = self:get_from_pool()
    if bullet then
      local x, y = actor.get_position(self)
      actor.set_position(bullet, x, y)
      -- set bullet velocity, etc.
    end
  end
end

return M
```

#### Why it works

The pool pre-allocates a fixed set of actors at startup. When you need a bullet, you grab one from the pool (making it visible and positioning it). When the bullet is done, you return it to the pool (hiding it). No actors are created or destroyed during gameplay — you're just recycling.

The `active` table tracks which pool objects are currently in use. This is a simple set: `self.active[obj] = true` means "in use," and `self.active[obj] = nil` means "available."

The pool size is a trade-off: too small, and you run out of objects during intense moments; too large, and you waste memory. 50 is a good starting point for bullets; you might want 200 for particles.

> **When to use this:** Bullets, particles, enemies, any object that's created and destroyed frequently in large numbers.

> **When NOT to use this:** Objects that are created once and live for a long time (the player, a boss), or games with very few spawn events (the overhead of the pool isn't worth it).

> **Common mistakes:**
> - **Not hiding pooled objects.** If you return an object to the pool but don't hide it, it'll be visible on screen at its last position. Always `set_visible(obj, false)` when returning.
> - **Forgetting to reset state.** A pooled bullet might have leftover velocity or damage from its last use. Reset all relevant state when fetching from the pool.
> - **Pool too small.** If `get_from_pool` returns nil, the game silently fails to spawn. Log a warning so you can tune the pool size.

> **Try this:**
> - Add a "grow" mechanism: if the pool is exhausted, spawn a new actor and add it to the pool (up to a maximum).
> - Add a "drain" method: return all active objects to the pool at once (useful for level transitions).
> - Use the pool for UI elements: damage numbers, popups, and other transient text.

---

### Timed Spawner

#### The problem

You want enemies to appear at regular intervals — one every 2 seconds, up to a maximum of 20 alive at once. The naive approach is to spawn an enemy every frame and check if enough time has passed. This works, but it's frame-rate dependent: at 144 fps, you're checking 144 times per second; at 30 fps, only 30 times. The spawn timing will be inconsistent.

#### The solution

```lua
local M = {}

function M:start()
  self.timer = 0
  self.interval = 2.0      -- seconds between spawns
  self.max_alive = 20      -- don't exceed this many enemies
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

function M:on_signal(name)
  if name == "enemy_died" then
    self.alive = self.alive - 1
  end
end

return M
```

#### Why it works

The timer accumulates `dt` each frame. When it reaches the interval, the timer resets and a spawn happens. This is frame-rate independent: whether the game runs at 30 or 144 fps, the timer accumulates the same total time per second.

The `max_alive` cap prevents the game from spawning infinite enemies. Without it, a long game session would eventually have thousands of actors and grind to a halt.

The `on_signal` handler decrements the alive count when an enemy dies. This is the signal system in action — the spawner doesn't need to know which enemy died, just that one did.

> **When to use this:** Wave-based spawners, enemy generators, any game where objects appear on a schedule.

> **When NOT to use this:** Games where spawn timing should be event-driven (spawn when the player reaches a trigger), or games with a fixed number of enemies placed in the editor.

> **Common mistakes:**
> - **Not resetting the timer.** If you forget `self.timer = 0`, the spawner will fire every frame after the interval is first reached.
> - **Not capping the alive count.** Without `max_alive`, a bug in the death logic (enemies that never die) will eventually crash the game.
> - **Using a frame counter instead of a timer.** `self.frame = self.frame + 1; if self.frame >= 120 then` is frame-rate dependent. At 144 fps, 120 frames is 0.83 seconds; at 30 fps, it's 4 seconds.

> **Try this:**
> - Add a difficulty curve: decrease the interval over time so enemies spawn faster as the game progresses.
> - Add a burst mode: spawn 5 enemies at once, then wait longer.
> - Add a "spawn effect": play a particle effect or sound when an enemy spawns.

---

## State Management

Games are full of things that change over time: a power-up that lasts 5 seconds, a sword swing that has a recovery period, an enemy that switches between idle, chase, and attack. These patterns give you the tools to manage that change.

### Simple Timer

#### The problem

You want something to happen after a delay — a power-up expires, a door opens, a cutscene triggers. The naive approach is to count frames: `self.frame = self.frame + 1; if self.frame >= 300 then`. But this is frame-rate dependent and hard to read. What you really want is a timer that counts down in seconds.

#### The solution

```lua
local M = {}

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

return M
```

#### Why it works

The timer accumulates `dt` (delta time in seconds) each frame. When the accumulated time reaches the duration, the timer fires and stops. The `finished` flag prevents it from firing again.

This is frame-rate independent: `dt` is the actual time elapsed since the last frame, so the timer counts real seconds, not frames.

The `on_finish` callback is a clean separation: the timer logic is generic, and the specific behavior (what happens when the timer ends) is defined by the game.

> **When to use this:** Power-up durations, delayed events, any "wait N seconds then do X" logic.

> **When NOT to use this:** Things that should happen on a specific frame (use a frame counter), or things that need to be paused (add a `self.paused` flag).

> **Common mistakes:**
> - **Not checking `self.finished`.** Without the guard, `on_finish` will fire every frame after the duration is reached.
> - **Using `dt` in milliseconds.** If your `dt` is in milliseconds, `self.elapsed` will reach 3.0 in 3 milliseconds, not 3 seconds. Make sure you know your units.
> - **Not resetting the timer.** If you want the timer to be reusable, add a `reset` method that sets `elapsed = 0` and `finished = false`.

> **Try this:**
> - Add a `reset` method so the timer can be reused.
> - Add a `pause` flag so the timer can be paused and resumed.
> - Add a progress bar: `self.progress = self.elapsed / self.duration` gives you a 0-1 value for UI.

---

### Cooldown

#### The problem

The player can attack, but you don't want them to attack every frame — that would be overpowered. You want a cooldown: after attacking, the player must wait before attacking again. This is one of the most common patterns in action games.

#### The solution

```lua
local M = {}

function M:start()
  self.cooldown = 1.0      -- seconds between uses
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

function M:use()
  -- The actual ability: spawn a bullet, play a sound, etc.
end

return M
```

#### Why it works

The cooldown is a countdown timer with a gate. `try_use` checks the gate (`self.ready`); if it's open, the ability fires and the gate closes. The timer counts down; when it reaches zero, the gate opens again.

The key design decision: `try_use` returns a boolean. This lets the caller know whether the ability fired, which is useful for UI (showing a "not ready" indicator) or for chaining abilities.

The `use` method is separate from `try_use` so the ability logic is decoupled from the cooldown logic. You can call `use` directly if you want to bypass the cooldown (for a cheat code, for example).

> **When to use this:** Attack cooldowns, ability cooldowns, dash cooldowns, any "you can do this, but not too often" mechanic.

> **When NOT to use this:** Things that should be limited by ammo or resources (use a counter instead), or things that should be always available (no cooldown needed).

> **Common mistakes:**
> - **Not resetting the timer.** If you set `self.ready = false` but forget `self.timer = self.cooldown`, the ability will never come back.
> - **Checking `self.timer <= 0` without the `ready` flag.** Without the flag, the timer will go negative and the ability will fire every frame after the cooldown ends.
> - **Putting the cooldown logic in `use`.** If `use` is called from multiple places, each caller needs to remember to check the cooldown. Put the gate in `try_use` so it's enforced in one place.

> **Try this:**
> - Add a UI indicator: expose `self.cooldown_progress = 1 - (self.timer / self.cooldown)` so the UI can show a radial cooldown.
> - Add a "cooldown reduction" stat: multiply `self.cooldown` by a factor when the ability is used.
> - Add a "cooldown reset" effect: a power-up that sets `self.ready = true` and `self.timer = 0`.

---

### State Machine

#### The problem

An enemy has three behaviors: idle (stand still), chase (run toward the player), and attack (shoot when close). You could write this as a mess of if-else statements:

```lua
if self.state == "idle" then
  if player_nearby then self.state = "chase" end
elseif self.state == "chase" then
  if player_far then self.state = "idle" end
  if player_in_range then self.state = "attack" end
elseif self.state == "attack" then
  if player_not_in_range then self.state = "chase" end
end
```

This works for three states, but it becomes unmanageable at ten states. Every new state means adding another `elseif` branch and updating every other branch's transition conditions. The state machine pattern replaces this with a declarative system.

#### The solution

```lua
local M = {}

function M:start()
  -- Declare states
  self:sm_add_state("idle", {
    update = function(self, dt)
      if actor.distance_to(self, player) < 300 then
        self:sm_fire("see_player")
      end
    end,
  })

  self:sm_add_state("chase", {
    enter = function(self) log.info("chasing!") end,
    update = function(self, dt)
      local dx, dy = actor.direction_to(self, player)
      actor.move_by(self, dx * 120 * dt, dy * 120 * dt)
      if actor.distance_to(self, player) > 600 then
        self:sm_fire("lost_player")
      elseif actor.distance_to(self, player) < 60 then
        self:sm_fire("in_range")
      end
    end,
    exit = function(self) log.info("giving up") end,
  })

  self:sm_add_state("attack", {
    update = function(self, dt)
      self.cooldown = math.max(0, self.cooldown - dt)
      if self.cooldown == 0 then
        self:shoot()
        self.cooldown = 0.8
      end
      if actor.distance_to(self, player) > 100 then
        self:sm_fire("out_of_range")
      end
    end,
  })

  -- Declare transitions
  self:sm_add_transition("idle", "see_player", "chase")
  self:sm_add_transition("chase", "in_range", "attack")
  self:sm_add_transition("chase", "lost_player", "idle")
  self:sm_add_transition("attack", "out_of_range", "chase")

  self:sm_set_initial("idle")
end

function M:update(dt)
  -- The behavior update runs AFTER the state machine tick.
  -- Use it for things that aren't state-specific: animation, UI, etc.
  if self:sm_is_in("chase") then
    self.anim = "run"
  else
    self.anim = "idle"
  end
end

return M
```

#### Why it works

The state machine separates **what each state does** (the state's `update` callback) from **when states change** (the transitions). This is a huge win for readability and maintainability:

- Adding a new state means adding one `sm_add_state` block and a few `sm_add_transition` lines. You don't touch existing states.
- Each state's logic is self-contained. The "chase" state doesn't need to know about "idle" or "attack" — it just fires events when conditions are met.
- The `enter` and `exit` callbacks let you run setup and cleanup code when a state changes (play a sound, start/stop an animation, etc.).

The `sm_fire` function requests a transition. The transition is applied **before the next update**, so the state machine is always in a consistent state when `update` runs. This prevents bugs where a state's `update` fires an event that immediately changes the state, causing the rest of the update to run in the wrong state.

The `sm_is_in` function lets the behavior-level `update` read the current state for non-state-specific logic (like animation).

> **When to use this:** Enemy AI, player states (idle/run/jump/dash), game flow (menu/playing/paused/game-over), any entity with distinct modes of behavior.

> **When NOT to use this:** Simple entities with only one or two behaviors (a coin that just spins doesn't need a state machine), or behaviors that are better expressed as continuous values (a health bar doesn't need states).

> **Common mistakes:**
> - **Firing events that don't have transitions.** If you `sm_fire("see_player")` but there's no transition from the current state for that event, nothing happens. This is silent — no error, no warning. Double-check your transition table.
> - **Putting too much logic in `enter`/`exit`.** These callbacks run once per transition. If you put per-frame logic there, it won't run every frame. Use `update` for per-frame logic.
> - **Not setting an initial state.** If you forget `sm_set_initial`, the machine starts in an empty state and nothing happens. The first declared state is the default, but being explicit is better.

> **Try this:**
> - Add a "patrol" state: the enemy walks back and forth until it sees the player.
> - Add a "hurt" state: when the enemy takes damage, it briefly flashes and becomes invulnerable.
> - Add a "dead" state: when HP reaches zero, the enemy plays a death animation and then is destroyed.

---

## Signals

Signals are the engine's event system. They let actors communicate without knowing about each other — the attacker emits "hit," and the receiver listens for "hit." This decoupling is what makes large games manageable.

### Damage System

#### The problem

You want an attack to damage an enemy. The naive approach is for the attacker to directly modify the enemy's HP: `enemy.hp = enemy.hp - 10`. This works, but it creates a tight coupling: the attacker needs a reference to the enemy, and the enemy needs to know about the attacker. In a large game, this becomes a web of dependencies that's hard to maintain.

#### The solution

```lua
-- Shared event data (module-level, out-of-band from the signal itself)
local event_data = {}

-- In the attacker:
function M:attack()
  local x, y = actor.get_position(self)
  world.nearby(self, x, y, 50, function(target)
    if target == self then return end

    -- Write the event data before emitting
    event_data.amount = self.damage
    event_data.source = self
    actor.emit(target, "damage")
  end)
end

-- In the receiver:
function M:on_signal(name)
  if name == "damage" then
    self.hp = self.hp - event_data.amount
    if self.hp <= 0 then
      actor.emit(self, "died")
      actor.destroy(self)
    end
  end
end
```

#### Why it works

The signal system is **name-based**: the attacker emits a signal named "damage," and every actor that registered a listener for "damage" receives it. The attacker doesn't need to know who's listening, and the listener doesn't need to know who's emitting.

The `event_data` table is a simple pattern for passing data alongside a signal. The engine's Lua-side `actor.emit` only takes a name (no payload), so we use a module-level table to pass the damage amount and source. The attacker writes to the table before emitting; the receiver reads from it when handling the signal.

This is a common pattern in event systems: the signal is the "what happened" (a name), and the event data is the "details" (a shared table). The key is that the data is written **before** the emit and read **during** the handler — the ordering is guaranteed because signals are drained in the same frame they're emitted.

> **When to use this:** Damage, pickups, UI updates, any event where the source and target shouldn't be directly coupled.

> **When NOT to use this:** Simple two-actor interactions where a direct reference is clearer (a player touching a coin), or high-frequency events where the overhead of the signal system matters (per-frame position updates).

> **Common mistakes:**
> - **Assuming the signal carries a payload.** The Lua-side `actor.emit(self, event)` only takes a name. If you try to pass a table as a second argument, it's ignored. Use a shared data table instead.
> - **Not checking the signal name.** `on_signal` receives every signal the actor listens to. If you only care about "damage," check `if name == "damage"` before handling it.
> - **Modifying the world during signal handling.** Don't spawn or destroy actors inside `on_signal` — it can corrupt the signal queue. Collect changes and apply them after.

> **Try this:**
> - Add a "heal" signal: the same pattern, but it increases HP instead of decreasing it.
> - Add a "damage over time" effect: emit a "damage" signal every second for 5 seconds.
> - Add a "damage flash" effect: when the "damage" signal is received, briefly tint the sprite red.

---

### Event Bus

#### The problem

You have multiple systems that need to react to the same event: when the player dies, the UI should show "Game Over," the audio system should play a sound, and the game manager should stop the timer. If the player script directly calls each system, it becomes a hub of dependencies. The event bus pattern inverts this: systems subscribe to events they care about, and the event bus dispatches events to all subscribers.

#### The solution

```lua
-- A simple event bus (module-level)
local EventBus = {}
EventBus.listeners = {}

function EventBus:on(event_name, fn)
  self.listeners[event_name] = self.listeners[event_name] or {}
  table.insert(self.listeners[event_name], fn)
end

function EventBus:emit(event_name, data)
  local handlers = self.listeners[event_name]
  if not handlers then return end
  for _, fn in ipairs(handlers) do
    fn(data)
  end
end

-- In the player script:
function M:on_signal(name)
  if name == "damage" then
    self.hp = self.hp - event_data.amount
    if self.hp <= 0 then
      EventBus:emit("player_died", { score = self.score, time = self.time })
      actor.destroy(self)
    end
  end
end

-- In the UI script:
function M:start()
  EventBus:on("player_died", function(data)
    self:show_game_over(data.score, data.time)
  end)
end

-- In the audio script:
function M:start()
  EventBus:on("player_died", function(_)
    self:play_sound("game_over")
  end)
end
```

#### Why it works

The event bus is a **publish-subscribe** system. Publishers (the player) emit events without knowing who's listening. Subscribers (the UI, audio) register callbacks for events they care about. The bus dispatches events to all subscribers.

This is different from the engine's signal system: signals are actor-to-actor (one emitter, one receiver), while the event bus is system-to-system (one emitter, many receivers). Use signals for gameplay events between actors; use the event bus for system-level events that cross architectural boundaries.

The event bus is a simple table of lists: `listeners["player_died"]` is a list of callbacks. Emitting an event iterates the list and calls each callback. This is O(n) in the number of subscribers, which is fine for most games (you rarely have more than a handful of subscribers per event).

> **When to use this:** System-level events (game over, level complete, settings changed), any event that multiple systems need to react to.

> **When NOT to use this:** Actor-to-actor communication (use the engine's signal system), or high-frequency events (the event bus allocates a table per emit, which can cause GC pressure).

> **Common mistakes:**
> - **Not unsubscribing.** If a system is destroyed but its callback stays in the bus, the bus will call a dead reference. Add an `off` method and call it in `on_destroy`.
> - **Emitting during iteration.** If a callback emits another event, you'll modify the list you're iterating. Collect the callbacks into a local table before iterating.
> - **Using the event bus for everything.** The event bus is a tool, not a religion. If two actors need to talk, use a signal. If a system needs to react to an event, use the bus.

> **Try this:**
> - Add event priorities: some subscribers should run before others (UI before audio).
> - Add a "once" method: subscribe to an event, but only fire the callback once.
> - Add event filtering: subscribers can specify a filter function so they only receive events that match certain criteria.

---

## Steering

Steering behaviors are the building blocks of game AI. Instead of pathfinding (which finds a route around obstacles), steering is reactive: each frame, the AI computes a force based on its current situation and applies it to its velocity. The result is emergent, lifelike movement.

All steering behaviors use the same accumulator pattern:

1. Create an accumulator with `steer.at(x, y)`
2. Each frame, reset it and add steering terms
3. Apply the result with `acc:apply(max_speed)`

### Seek (Chase a Target)

#### The problem

You want an enemy to chase the player. The naive approach is to move directly toward the player's current position. This works, but it's naive in a literal sense: the enemy always moves at full speed, even when it's right next to the player. It overshoots, circles back, overshoots again — looking more like a drunk bee than a predator.

#### The solution

```lua
local M = {}

function M:start()
  local x, y = actor.get_position(self)
  self.steer = steer.at(x, y)
  self.max_speed = 200
end

function M:update(dt)
  local x, y = actor.get_position(self)
  self.steer:reset(x, y)
  self.steer:seek(player.x, player.y, 1.0)
  local vx, vy = self.steer:apply(self.max_speed)
  actor.move_by(self, vx * dt, vy * dt)
end

return M
```

#### Why it works

`acc:seek(tx, ty, w)` adds a term that pulls the actor toward the target. The term is a **unit vector** pointing from the actor to the target, scaled by the weight `w`. Because it's normalized, the weight means the same thing regardless of distance — a weight of 1.0 always produces a force of the same magnitude, whether the target is 10 or 1000 units away.

`acc:apply(max_speed)` sums all the terms and clamps the result to `max_speed`. This is the final velocity for the frame.

The key insight: steering behaviors are **composable**. You can add multiple terms (seek + avoid + wander) and they'll blend together. The accumulator handles the blending; you just add terms.

> **When to use this:** Any AI that needs to move toward a target — enemies chasing the player, allies following the player, a homing missile.

> **When NOT to use this:** When the AI needs to slow down as it approaches (use arrive), or when the target is moving and you need to lead it (use pursue).

> **Common mistakes:**
> - **Not resetting the accumulator.** If you forget `self.steer:reset(x, y)`, the terms accumulate every frame and the actor accelerates without bound.
> - **Using raw position instead of velocity.** `actor.move_by(self, vx * dt, vy * dt)` — if you forget the `dt`, the actor moves `vx` units per frame instead of per second, which is frame-rate dependent.
> - **Forgetting to update the accumulator's position.** The `reset(x, y)` call updates the accumulator's internal position, which some behaviors (like wander) use. Always pass the current position.

> **Try this:**
> - Add a "give up" range: if the player is more than 500 units away, stop seeking.
> - Add a "personal space": if the enemy is too close to the player, back away (combine seek with flee).
> - Add a "prediction" factor: aim at where the player will be, not where they are (this is pursue, below).

---

### Flee (Run from a Threat)

#### The problem

You want an enemy to run away from the player when the player gets too close. This is the opposite of seek — instead of moving toward the threat, the enemy moves away.

#### The solution

```lua
local M = {}

function M:start()
  local x, y = actor.get_position(self)
  self.steer = steer.at(x, y)
  self.max_speed = 250
end

function M:update(dt)
  local x, y = actor.get_position(self)
  self.steer:reset(x, y)
  self.steer:flee(player.x, player.y, 1.0)
  local vx, vy = self.steer:apply(self.max_speed)
  actor.move_by(self, vx * dt, vy * dt)
end

return M
```

#### Why it works

`acc:flee(tx, ty, w)` is exactly `seek` with the direction reversed. It adds a term that pushes the actor away from the threat. The term is a unit vector pointing from the threat to the actor, scaled by the weight.

Flee is often combined with other behaviors. A common pattern is "flee if close, seek if far":

```lua
local d = actor.distance_to(self, player)
if d < 100 then
  self.steer:flee(player.x, player.y, 1.0)
else
  self.steer:seek(player.x, player.y, 1.0)
end
```

> **When to use this:** Enemies that run away when hurt, civilians fleeing from danger, any AI that needs to avoid a threat.

> **When NOT to use this:** When the AI should slow down as it reaches a safe distance (combine flee with arrive), or when the AI should navigate around the threat rather than running in a straight line (use avoid).

> **Common mistakes:**
> - **Fleeing forever.** Without a condition to stop fleeing, the enemy will run forever. Add a "safe distance" check.
> - **Fleeing into walls.** Flee doesn't account for obstacles. The enemy will run into a wall and get stuck. Combine flee with avoid or use pathfinding.
> - **Using flee for everything.** Flee is a blunt instrument. For nuanced behavior, combine it with other terms (seek, wander, avoid).

> **Try this:**
> - Add a "panic" state: when fleeing, the enemy moves faster but is less accurate (wanders more).
> - Add a "hide" behavior: instead of fleeing in a straight line, the enemy seeks the nearest cover point.
> - Add a "group flee" behavior: when one enemy flees, nearby enemies also flee (use `world.nearby` to spread the panic).

---

### Arrive (Seek with Braking)

#### The problem

Seek moves at full speed toward the target, even when it's right next to it. This causes the orbiting problem: the enemy overshoots, circles back, overshoots again. What you want is for the enemy to **slow down as it approaches** the target, coming to a smooth stop.

#### The solution

```lua
local M = {}

function M:start()
  local x, y = actor.get_position(self)
  self.steer = steer.at(x, y)
  self.max_speed = 200
  self.slow_radius = 80
end

function M:update(dt)
  local x, y = actor.get_position(self)
  self.steer:reset(x, y)
  self.steer:arrive(player.x, player.y, self.slow_radius, 1.0)
  local vx, vy = self.steer:apply(self.max_speed)
  actor.move_by(self, vx * dt, vy * dt)
end

return M
```

#### Why it works

`acc:arrive(tx, ty, slow_radius, w)` is seek with a twist: the weight fades from full to zero as the actor approaches the target. Far away, the weight is 1.0 (full speed). At the `slow_radius` distance, the weight starts to decrease. At the target, the weight is zero (no force).

This produces a natural deceleration curve: the actor moves fast when far, slows down as it approaches, and comes to a smooth stop at the target. No more orbiting.

The `slow_radius` controls how early the braking starts. A small radius means the actor brakes late (fast approach, sudden stop). A large radius means the actor brakes early (slow approach, gentle stop).

> **When to use this:** Any AI that needs to stop at a target — enemies reaching the player, allies reaching the player, a character walking to a clicked position.

> **When NOT to use this:** When the AI should orbit the target (use seek), or when the AI should pass through the target and continue (use seek).

> **Common mistakes:**
> - **Slow radius too small.** If the `slow_radius` is smaller than the distance the actor travels in one frame, the actor will overshoot and oscillate. Make sure `slow_radius > max_speed * dt`.
> - **Using arrive for moving targets.** Arrive assumes the target is stationary. If the target is moving, the actor will perpetually slow down and never catch up. Use pursue instead.
> - **Forgetting that arrive still uses max_speed.** The `max_speed` parameter in `acc:apply` is the cap. Arrive reduces the *force*, but the cap still applies. If `max_speed` is too low, the actor will crawl even when far away.

> **Try this:**
> - Add a "stop distance": the actor stops 20 units away from the target instead of on top of it.
> - Add a "timeout": if the actor hasn't reached the target in 5 seconds, give up and wander.
> - Combine arrive with avoid: the actor slows down as it approaches while also steering around obstacles.

---

### Pursue (Lead a Moving Target)

#### The problem

Seek aims at the target's current position. But if the target is moving, the enemy will always be behind — chasing where the player *was*, not where they *are*. This is especially problematic for projectiles or slow-moving enemies trying to catch a fast-moving player.

#### The solution

```lua
local M = {}

function M:start()
  local x, y = actor.get_position(self)
  self.steer = steer.at(x, y)
  self.max_speed = 220
end

function M:update(dt)
  local x, y = actor.get_position(self)
  self.steer:reset(x, y)
  self.steer:pursue(
    player.x, player.y,
    player.vx, player.vy,
    0.5, 1.0
  )
  local vx, vy = self.steer.apply(self.max_speed)
  actor.move_by(self, vx * dt, vy * dt)
end

return M
```

#### Why it works

`acc:pursue(tx, ty, tvx, tvy, lead, w)` aims at where the target **will be**, not where it is. It does this by adding the target's velocity (scaled by `lead`) to the target's position:

```
aim_x = tx + tvx * lead
aim_y = ty + tvy * lead
```

The `lead` parameter controls how far ahead to aim. A `lead` of 0 is pure seek (aim at current position). A `lead` of 1.0 aims at where the target will be in 1 second. Values between 0 and 1 are the sweet spot for most games — enough to lead the target, not so much that the enemy overshoots.

The key insight: pursue is purely arithmetic. It doesn't predict the target's future behavior (it assumes the target continues in a straight line at constant velocity). This makes it cheap and predictable — no state, no history, just math.

> **When to use this:** Homing missiles, enemies chasing a fast-moving player, any AI that needs to intercept a moving target.

> **When NOT to use this:** When the target moves erratically (pursue assumes constant velocity), or when the target is stationary (seek is simpler and equivalent).

> **Common mistakes:**
> - **Lead too high.** If `lead` is too high, the enemy aims far ahead of the target and misses. Start with 0.3-0.5 and tune.
> - **Not accounting for the enemy's own speed.** If the enemy is slower than the target, no amount of leading will help — the target will outrun it. Pursue helps when the enemy is faster or equally fast.
> - **Using pursue for stationary targets.** If the target isn't moving, `tvx` and `tvy` are 0, and pursue is identical to seek. Use seek for clarity.

> **Try this:**
> - Add a "lead cap": limit the lead distance so the enemy doesn't aim absurdly far ahead.
> - Add a "prediction error": add a small random offset to the aim point so the enemy isn't perfectly accurate.
> - Combine pursue with arrive: the enemy leads the target but slows down as it gets close.

---

### Wander (Deterministic)

#### The problem

You want an enemy to mill about idly when it's not chasing the player. The naive approach is to use `rand.float` to pick a random direction each frame. But this produces jittery, erratic movement — the enemy twitches randomly instead of wandering smoothly. And if you use `rand.float`, the movement isn't deterministic (it can't be replayed from a seed).

#### The solution

```lua
local M = {}

function M:start()
  local x, y = actor.get_position(self)
  self.steer = steer.at(x, y)
  self.max_speed = 100
  self.wander_radius = 120
  self.t = 0
  self.seed = 42  -- any fixed number; same seed = same wander pattern
end

function M:update(dt)
  self.t = self.t + dt
  local x, y = actor.get_position(self)
  self.steer:reset(x, y)
  local angle = noise.simplex(self.t * 0.1, self.seed) * math.pi * 2
  self.steer:wander(angle, self.wander_radius, 1.0)
  local vx, vy = self.steer.apply(self.max_speed)
  actor.move_by(self, vx * dt, vy * dt)
end

return M
```

#### Why it works

`acc:wander(angle, radius, w)` adds a term that moves the actor in the direction of `angle`. The angle comes from `noise.simplex`, which is a smooth, continuous noise function. Unlike `rand.float`, which produces independent random values each frame, simplex noise produces values that are **smoothly correlated** — nearby inputs produce nearby outputs. This means the wander angle changes gradually, producing smooth, natural-looking movement.

The `self.t * 0.1` scales the noise input so the angle changes slowly over time. A higher multiplier makes the enemy change direction more often; a lower multiplier makes it more consistent.

The `self.seed` ensures the wander pattern is deterministic. The same seed always produces the same sequence of angles, which means the enemy's wander is reproducible — critical for debugging and for games that support replays.

> **When to use this:** Idle enemies, ambient creatures (birds, fish), any AI that needs to move without a specific goal.

> **When NOT to use this:** When the AI should move toward a goal (use seek or arrive), or when the AI should move in a specific pattern (use a path or script).

> **Common mistakes:**
> - **Using `rand.float` for the angle.** This produces jittery, non-deterministic movement. Use `noise.simplex` for smooth, reproducible wander.
> - **Not scaling the noise input.** If you pass `self.t` directly to `noise.simplex`, the angle changes too fast (the enemy twitches). Scale it down (e.g., `self.t * 0.1`).
> - **Forgetting the seed.** Without a fixed seed, the wander pattern is different every run. Set `self.seed` to a fixed number.

> **Try this:**
> - Add a "wander bias": bias the wander angle toward a home position so the enemy doesn't drift too far.
> - Add a "curiosity" behavior: occasionally pick a new seed so the enemy explores a new area.
> - Combine wander with avoid: the enemy wanders but steers around obstacles.

---

### Flocking (Separate + Align + Cohere)

#### The problem

You want a flock of birds, a school of fish, or a squad of soldiers to move together as a group. Each individual should stay close to the group, move in the same direction as the group, and avoid bumping into other members. This is flocking, and it emerges from three simple rules.

#### The solution

```lua
local M = {}

function M:start()
  local x, y = actor.get_position(self)
  self.steer = steer.at(x, y)
  self.max_speed = 180
end

function M:update(dt)
  local x, y = actor.get_position(self)
  self.steer:reset(x, y)
  self.steer:separate(50, 1.0)   -- don't crowd neighbors
  self.steer:align(100, 0.5)     -- match neighbors' direction
  self.steer:cohere(100, 0.5)    -- move toward neighbors' center
  local vx, vy = self.steer.apply(self.max_speed)
  actor.move_by(self, vx * dt, vy * dt)
end

return M
```

#### Why it works

Flocking is the canonical example of **emergent behavior**: complex group behavior from three simple rules:

1. **Separation** (`acc:separate(radius, w)`): push away from neighbors that are too close. This prevents crowding.
2. **Alignment** (`acc:align(radius, w)`): match the average direction of nearby neighbors. This makes the group move in the same direction.
3. **Cohesion** (`acc:cohere(radius, w)`): move toward the average position of nearby neighbors. This keeps the group together.

Each rule is a steering term. The accumulator sums them, and the result is a velocity that balances all three. The weights control the personality of the flock:
- High separation, low cohesion: a loose, spread-out flock (like a school of fish).
- Low separation, high cohesion: a tight, dense flock (like a flock of starlings).
- High alignment: the group moves in lockstep (like a military formation).

The `separate`, `align`, and `cohere` terms use `world.nearby` internally — they query the spatial grid for neighbors within the given radius. This is O(1) per agent, so flocking scales to hundreds of agents.

> **When to use this:** Birds, fish, insects, squad AI, any group of agents that should move together.

> **When NOT to use this:** When each agent has its own individual goal (use seek/arrive), or when the group should follow a specific path (use pathfinding).

> **Common mistakes:**
> - **Weights that don't balance.** If separation is too strong, the flock disperses. If cohesion is too strong, the flock collapses to a point. Tune the weights together.
> - **Radius too small.** If the separation radius is smaller than the agent, agents will overlap. Make sure the radius is at least the agent's size.
> - **Not using `world.nearby`.** If you implement flocking with a linear scan (checking every agent), it's O(n^2) and will be slow with many agents. The engine's `separate`, `align`, and `cohere` use the spatial grid.

> **Try this:**
> - Add a "predator" behavior: when a predator is nearby, increase separation and add a flee term.
> - Add a "goal" behavior: add a seek term so the flock moves toward a destination.
> - Add "personalities": give each agent slightly different weights so the flock has variety.

---

### Avoid Obstacles

#### The problem

You want an enemy to navigate around obstacles — walls, rocks, other enemies — while still moving toward its goal. Without avoidance, the enemy will walk straight into walls and get stuck.

#### The solution

```lua
local M = {}

function M:start()
  local x, y = actor.get_position(self)
  self.steer = steer.at(x, y)
  self.max_speed = 200
end

function M:update(dt)
  local x, y = actor.get_position(self)
  self.steer:reset(x, y)
  self.steer:seek(player.x, player.y, 1.0)
  self.steer:avoid(obstacle.x, obstacle.y, 80, player.x, player.y, 1.5)
  local vx, vy = self.steer.apply(self.max_speed)
  actor.move_by(self, vx * dt, vy * dt)
end

return M
```

#### Why it works

`acc:avoid(ox, oy, radius, tx, ty, w)` steers away from an obstacle while still moving toward the target. It does this by blending two forces:
1. A force pushing away from the obstacle
2. A force pulling toward the target

The result is a curved path around the obstacle: the enemy slides around it instead of stopping or reversing.

The `radius` controls how far away the enemy starts avoiding. A larger radius means earlier avoidance (more cautious); a smaller radius means later avoidance (more direct).

The key insight: avoid is **reactive**, not predictive. It doesn't plan a path around the obstacle; it just steers away when the obstacle is close. This means it can get stuck in concave obstacles (a U-shaped wall) — for complex navigation, you'd need pathfinding.

> **When to use this:** Enemies navigating around walls, agents avoiding each other, any AI that needs to steer around obstacles in real-time.

> **When NOT to use this:** Complex mazes (use pathfinding), or when the obstacle is static and known at design time (bake the avoidance into the level design).

> **Common mistakes:**
> - **Avoid radius too small.** If the radius is smaller than the distance the enemy travels in one frame, the enemy will hit the obstacle before avoiding it. Make sure `radius > max_speed * dt`.
> - **Avoid weight too low.** If the avoid weight is much lower than the seek weight, the enemy will push through the obstacle. The avoid weight should be higher than the seek weight.
> - **Using avoid for everything.** Avoid is expensive (it needs to check for obstacles). Use it only when there are actually obstacles to avoid.

> **Try this:**
> - Add multiple obstacles: call `acc:avoid` for each nearby obstacle.
> - Add a "whisker" sensor: cast a short ray ahead and avoid whatever it hits.
> - Add a "stuck" detection: if the enemy hasn't moved in 1 second, pick a new random direction.

---

## Animation

### Sprite Cycling

#### The problem

You have a sprite sheet — a single image containing multiple frames of an animation — and you want to play it. The sprite sheet might be a horizontal strip of 4 frames, and you want to cycle through them to create a walk cycle.

#### The solution

```lua
local M = {}

function M:start()
  self.frame = 0
  self.frame_time = 0
  self.frame_duration = 0.1  -- seconds per frame
  self.frames = 4            -- number of frames in the atlas row
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

return M
```

#### Why it works

A sprite sheet is a single texture containing multiple frames. To display a specific frame, you set the **UV coordinates** — the portion of the texture that gets mapped to the sprite. For a horizontal strip of 4 frames:

- Frame 0: u from 0.0 to 0.25
- Frame 1: u from 0.25 to 0.5
- Frame 2: u from 0.5 to 0.75
- Frame 3: u from 0.75 to 1.0

The formula `u0 = frame / frames` and `u1 = (frame + 1) / frames` computes these UV coordinates. The `v` coordinates (0 and 1) cover the full height of the texture, assuming the frames are in a single row.

The `frame_time` accumulator ensures the animation plays at a consistent rate regardless of frame rate. Each frame lasts `frame_duration` seconds; when the accumulator reaches that value, the frame advances.

The modulo operator (`%`) wraps the frame back to 0 after the last frame, creating a loop.

> **When to use this:** Any sprite animation — walk cycles, idle animations, attack animations, particle effects.

> **When NOT to use this:** Skeletal animation (use a bone-based system), or animations with variable frame durations (use a frame-duration table instead of a fixed duration).

> **Common mistakes:**
> - **Not using the modulo.** Without `% self.frames`, the frame index grows without bound and the UV coordinates go past 1.0, showing nothing.
> - **Frame duration too short.** If `frame_duration` is less than the frame time, the animation plays faster than intended. At 60 fps, a `frame_duration` of 0.016 is about 1 frame per update — too fast for most animations.
> - **Assuming the frames are in a single row.** If your sprite sheet has multiple rows, you need to compute both `u` and `v` coordinates. This example assumes a single row.

> **Try this:**
> - Add a "play once" mode: stop at the last frame instead of looping.
> - Add a "reverse" mode: play the animation backward.
> - Add a "frame event": call a function when a specific frame is reached (e.g., play a sound on frame 2 of a walk cycle).

---

## Next Steps

- [Lua API Reference](../reference/script-lua-api.md) — Full function list
- [State Machines](../reference/script-state-machines.md) — Declarative state management
- [Steering Behaviors](../reference/script-lua-api.md#steer) — AI movement
- [Spatial Grid](../reference/script-spatial-grid.md) — How neighborhood queries work
- [Behavior Lifecycle](../reference/script-behaviors.md) — How scripts run each frame
