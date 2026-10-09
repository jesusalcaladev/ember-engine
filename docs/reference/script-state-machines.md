# Ember Engine — Declarative State Machines

Ember Engine provides a single declarative state machine system as an ECS component. One implementation serves every case: enemy AI, player states (idle/run/jump/dash), a spawner, a UI screen, and game flow. The difference between them is the script that declares the states, not any engine-side machinery.

## Concepts

- **Machine** — a template of states and transitions. Declared by a script. One behavior declares one; many copies of that behavior share the same machine.
- **Binding** — a live instance: which machine an entity runs, its `self` table, its current state, and any pending transition.
- **State** — a named node with optional `enter`, `update`, and `exit` callbacks.
- **Transition** — a directed edge from one state to another, triggered by a named event.

## Lua API

All `sm.*` methods are called on `self` (the behavior's `self` table). They are also available as `self:sm_add_state(...)` etc. Every failure path returns `nil`/`false` rather than raising a Lua error.

### Declaring States

```lua
self:sm_add_state("idle", {
  enter = function(self) self.wait = 1.0 end,
  update = function(self, dt) self.wait = self.wait - dt end,
  exit  = function(self) log.info("leaving idle") end,
})

self:sm_add_state("chase", {
  enter = function(self) actor.emit(self, "chase_started") end,
  update = function(self, dt)
    local d = actor.distance_to(self, player)
    if d > 500 then self:sm_fire("lost_player") end
  end,
})

self:sm_add_state("attack", {
  update = function(self, dt)
    if self.cooldown == 0 then self:shoot() end
    self.cooldown = math.max(0, self.cooldown - dt)
  end,
})
```

### Wiring Transitions

```lua
self:sm_add_transition("idle", "see_player", "chase")
self:sm_add_transition("chase", "in_range", "attack")
self:sm_add_transition("chase", "lost_player", "idle")
self:sm_add_transition("attack", "out_of_ammo", "idle")
```

### Setting the Initial State

```lua
self:sm_set_initial("idle")   -- optional: the first declared state is the default
```

### Firing Events

```lua
-- From inside update or a signal handler:
if actor.distance_to(self, player) < 300 then
  self:sm_fire("see_player")   -- takes effect next tick
end
```

### Querying State

```lua
local current = self:sm_state()     -- "chase"
local in_attack = self:sm_is_in("attack")  -- true / false
```

### Immediate Jumps

```lua
-- Jump right now (from inside a callback), running exit then enter:
self:sm_set_state("attack")
```

## Callback Signatures

All state callbacks receive `self` as their first argument:

| Callback | Signature | When it runs |
|---|---|---|
| `enter` | `function(self)` | When the machine enters the state (on first tick, or after a transition / `set_state`) |
| `update` | `function(self, dt)` | Every rendered frame while the state is active |
| `exit` | `function(self)` | When the machine leaves the state (before the next `enter`) |

`enter` and `exit` run **without** `dt` — they are one-shot hooks. `update` receives the frame delta time.

## Transition Semantics

### `fire` (Deferred)

`self:sm_fire(event)` requests a transition. The transition is applied **before the next `update`**, so firing from inside a callback cannot re-enter the machine mid-traversal. The tick order is:

1. Apply any pending transition: `exit(old)` then `enter(new)`.
2. Run `update` on the (possibly new) current state.

The **last** event in a frame wins. Two events fired before the next tick cannot both be honored without a queue; the difference only shows up in a script that fires twice before a tick, which is a bug in the script either way.

### `set_state` (Immediate)

`self:sm_set_state(name)` jumps straight to a state, running `exit` on the current one and `enter` on the target **immediately** — no one-frame gap. Used from inside a callback that cannot wait for the next tick. A pending event is cleared (it belongs to the state just left).

## Tick Order (Within the Engine Frame)

The state machines advance **before** behaviors, and that order is the contract:

1. Machine tick — a state's `update` may call `sm_fire` or `sm_set_state`.
2. Behavior `update` — reads `sm.state()`, so it sees the state its machine just entered.

This means a behavior always sees the state its machine transitioned to in the same frame, rather than the one it left last frame.

## Limits

The state machine system is a fixed-capacity, allocation-free pool:

| Constant | Value | Meaning |
|---|---|---|
| `max_machines` | 64 | Maximum number of distinct machine templates |
| `max_states` | 16 | Maximum states per machine |
| `max_transitions` | 32 | Maximum transitions per machine |
| `max_bindings` | 1024 | Maximum live entity bindings (one per attached behavior) |
| `max_name_len` | 24 | Maximum length of a state name |
| `max_event_len` | 16 | Maximum length of an event name |

Growing past a cap is a **reported error** (`nil`/`false` return), never a silent truncation: a game that loses its death state because of a cap would be the worst kind of bug.

## Self-Transitions

A transition from a state to itself (`from == to`) is a no-op: `exit` does not run, `enter` does not re-run. This is intentional — a self-transition means "stay here, but react to the event."

## Full Example: Enemy AI

```lua
local M = {}

function M:start()
  self:sm_add_state("idle", {
    update = function(self, dt)
      self.wait = (self.wait or 0) - dt
      if self.wait <= 0 and actor.distance_to(self, player) < 400 then
        self:sm_fire("see_player")
      end
    end,
  })
  self:sm_add_state("chase", {
    enter = function(self) log.info(actor.get_name(self) .. " chasing") end,
    update = function(self, dt)
      local dx, dy = actor.direction_to(self, player)
      actor.move_by(self, dx * 120 * dt, dy * 120 * dt)
      if actor.distance_to(self, player) > 600 then
        self:sm_fire("lost_player")
      elseif actor.distance_to(self, player) < 60 then
        self:sm_fire("in_range")
      end
    end,
    exit = function(self) log.info(actor.get_name(self) .. " gave up") end,
  })
  self:sm_add_state("attack", {
    update = function(self, dt)
      self.cooldown = math.max(0, self.cooldown - dt)
      if self.cooldown == 0 then
        self:shoot()
        self.cooldown = 0.8
      end
    end,
  })
  self:sm_add_transition("idle", "see_player", "chase")
  self:sm_add_transition("chase", "in_range", "attack")
  self:sm_add_transition("chase", "lost_player", "idle")
  self:sm_add_transition("attack", "fled", "chase")
  self:sm_set_initial("idle")
end

function M:update(dt)
  -- Behavior-level update runs AFTER the machine tick.
  -- It can read self:sm_state() to see what the machine decided this frame.
  if self:sm_is_in("chase") then
    self.anim = "run"
  else
    self.anim = "idle"
  end
end

return M
```
