-- A COIN: the behavior a spawned actor runs.
--
-- It does almost nothing on purpose: the point of the sample is the LIFE of
-- an actor — it is created at runtime, it finds its place, and it is removed
-- again — not what it draws.

local M = {}

function M:start()
  self.age = 0
  log.info("coin: born")
end

function M:update(dt)
  self.age = self.age + dt
  -- A coin that lived for ten seconds is collected.
  if self.age > 10 then
    log.info("coin: collected")
    actor.destroy(self)
  end
end

function M:on_destroy()
  log.info("coin: gone")
end

return M
