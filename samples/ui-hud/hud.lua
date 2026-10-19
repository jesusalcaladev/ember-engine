-- The HUD behavior, attached to the `hud` root actor (the one with `UiCanvas`).
--
-- It owns the score, the countdown, and the pause button. Two rules shape it:
--
--   1. One widget per actor. Every `ui.*` setter addresses the widget on the
--      actor it is given, so the score `Label`, the `UiProgressBar` and the
--      pause `UiButton` each live on their own actor and are reached by name.
--   2. The UI never filters world input. The button captures the pointer on its
--      own (see `player.lua`, which asks `input.pointer_over_ui()` before it
--      acts); this script only reacts to the `ui_pressed` signal.

local M = {}

function M:start()
  self.score = 0
  self.time_left = 30
  self.paused = false

  -- Address the widgets by name (each has exactly one widget component).
  self.score_actor = actor.find_by_name(self, "hud_score")
  self.bar_actor   = actor.find_by_name(self, "hud_bar")
  self.pause_actor = actor.find_by_name(self, "hud_pause")

  -- The engine loads one default font at boot, so text works with no setup.
  -- A project font would be a load-time call:
  --
  --   self.font = ui.font_load("assets/fonts/Inter-Bold.ttf", 20)
  --   ui.set_font(self.score_actor, self.font)
end

function M:update(dt)
  if not self.paused then
    self.time_left = math.max(self.time_left - dt, 0)
  end

  ui.set_text(self.score_actor, "Score: " .. self.score)
  ui.set_value(self.bar_actor, self.time_left / 30)
  ui.set_text(self.bar_actor, string.format("%ds", math.ceil(self.time_left)))
end

function M:on_signal(name, payload)
  if name == "collect" then
    self.score = self.score + 1
  elseif name == "ui_pressed" and payload.id == 1 then
    self:pause()
  end
end

-- Toggling pause dims the whole canvas — world and UI together — with the
-- full-screen tint. `scene.tint` defaults to multiply, so one call is enough.
function M:pause()
  self.paused = not self.paused
  if self.paused then
    ui.set_text(self.pause_actor, "Resume")
    scene.tint(0.35, 0.35, 0.5, 0.6)
    scene.tint_mode("multiply")
  else
    ui.set_text(self.pause_actor, "Pause")
    scene.tint_clear()
  end
end

return M
