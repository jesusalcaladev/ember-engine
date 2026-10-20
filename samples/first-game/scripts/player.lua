local M = {}
function M:start()
  self.speed = 300
  self.bits = actor.entity_bits(self)
  log.info("player: ready")
end
function M:update(dt)
  local dir = vec2.new(input.get_axis("move_left", "move_right"), 0)
  if vec2.length(dir) > 0 then dir = vec2.normalized(dir) end
  actor.set_linear_velocity(self, dir.x * self.speed, dir.y * self.speed)
end
function M:on_signal(name, payload)
  if name ~= "collision" then return end
  if payload.self ~= self.bits then return end
  log.info("player: collision began=" .. tostring(payload.began) .. " sensor=" .. tostring(payload.other_is_sensor))
end
return M
