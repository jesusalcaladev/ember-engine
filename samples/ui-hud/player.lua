-- A minimal world behavior that shows the UI consuming input WITHOUT leaking
-- it to the world.
--
-- This actor walks with the move axis and "collects" on the attack action, but
-- only when the pointer is NOT over an interactive widget. `input.pointer_over_ui()`
-- is true while the cursor is over a button (or an interactive panel), and it is
-- updated before scripts run, so this is the frame's real answer. Clicking the
-- Pause button therefore never also collects.

local M = {}

function M:start()
  self.speed = 260
  self.collected = 0
end

function M:update(dt)
  local axis = input.get_axis("move_left", "move_right")
  actor.move_by(self, axis * self.speed * dt, 0)

  if input.is_action_pressed("attack") and not input.pointer_over_ui() then
    self.collected = self.collected + 1
    -- The HUD listens for `collect` and bumps its score.
    actor.emit(self, "collect")
  end
end

return M
