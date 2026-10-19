-- The PLAYER: the behavior the scene's player actor runs.
--
-- A behavior is a Lua table with the lifecycle hooks: `start`, `update`,
-- `fixed_update`, `on_signal`, `on_destroy`. `self` is this actor's table, and
-- it carries the entity handle every `actor.*` call needs.

local M = {}

function M:start()
  self.speed = 300
  self.alive = true
  log.info("player: ready")
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

-- A COROUTINE: a sequence, without a frame counter.
--
-- `self:async` starts the function as a coroutine, and `self:wait` pauses it
-- for a number of GAME seconds. The engine resumes it on the fixed step, so
-- the wait slows down with the global time scale and replays identically.
function M:start_sequence()
  self:async(function(self)
    log.info("player: the sequence begins")
    self:wait(1.0)
    log.info("player: one second later")
    self:wait(0.5)
    log.info("player: and another half")
  end)
end

return M
