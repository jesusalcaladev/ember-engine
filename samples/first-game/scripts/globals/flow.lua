-- The game's FLOW: the phases the whole game moves through.
--
-- A flow is a GLOBAL state machine with a STACK of states. It is global
-- because the flow belongs to the game, not to an actor: a menu is not an
-- actor, and a game-over screen is not one either.
--
-- The stack is what makes "paused" work: it sits ON TOP of "playing", and
-- leaving it must return to "playing" — not to whatever came before it.

local M = {}

function M:start()
  -- The states. The hooks receive this global's `self`, so a phase can read
  -- the game's state directly.
  flow.add_state(self, "menu", {
    enter = function(self)
      log.info("flow: menu")
    end,
  })
  flow.add_state(self, "playing", {
    enter = function(self)
      log.info("flow: playing")
    end,
  })
  flow.add_state(self, "paused", {
    enter = function(self)
      log.info("flow: paused")
      time.pause()
    end,
    exit = function(self)
      time.resume()
    end,
  })

  -- The transitions. A transition REPLACES the whole stack: the phase
  -- changed, not the layer on top of it.
  flow.add_transition(self, "menu", "start", "playing")
  flow.add_transition(self, "playing", "game_over", "game_over")
  flow.add_state(self, "game_over", {
    enter = function(self)
      log.info("flow: game over")
    end,
  })

  flow.set_initial(self, "menu")
end

function M:update(dt)
  -- Anyone can drive the flow, from anywhere: a signal handler, an input
  -- action, a coroutine.
  if input.is_action_pressed("pause") then
    if flow.is_in(self, "paused") then
      flow.pop(self)          -- back to "playing"
    elseif flow.is_in(self, "playing") then
      flow.push(self, "paused")  -- "paused" sits ON TOP of "playing"
    end
  end
end

return M
