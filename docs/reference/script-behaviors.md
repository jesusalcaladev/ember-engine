# Ember Engine — Behavior Lifecycle

A **behavior** is a Lua script bound to an actor. It has a fixed set of lifecycle hooks that the engine calls at specific points in the frame loop. This document describes each hook, when it runs, and how the behavior system drives them.

## Overview

The behavior system owns:
- A **LuaJIT VM** (sandboxed) — the execution environment for all behaviors.
- A **script cache** — compiled prototypes shared by all instances of a script.
- A dense **instance array** — one `Instance` per live behavior, walked flat each frame.
- A **state machine registry** and a **spatial grid** — reachable from Lua through the `sm.*` and `world.nearby` bindings.

## Lifecycle Hooks

A behavior script is a Lua chunk that returns a **prototype table** (its methods and defaults). The prototype can define any of the following methods:

| Hook | When it runs | Signature |
|---|---|---|
| `start` | Once, on the first `update` (if defined) | `function M:start()` |
| `update(dt)` | Every rendered frame | `function M:update(dt)` |
| `fixed_update(dt)` | Every fixed 60 Hz tick | `function M:fixed_update(dt)` |
| `on_signal(name)` | When a signal this actor listens to drains | `function M:on_signal(name)` |
| `on_destroy` | Once, before the actor's refs are released | `function M:on_destroy()` |

### `start`

- **When**: Called once per instance, before the first `update`. Idempotent — a hot-reload does NOT re-run `start`; state survives and `start` is for one-time setup.
- **Purpose**: Initialize `self` fields, set up state, one-time allocations.
- **Note**: `start` is resolved on demand (once per instance, not per frame), so it is not in the cached hot-path set. If the script does not define `start`, nothing happens.

```lua
function M:start()
  self.n = 0
  self.hp = 100
  self.speed = 200
end
```

### `update(dt)`

- **When**: Every rendered frame, for every live instance.
- **Purpose**: Per-frame gameplay logic — movement, animation state, input polling.
- **Parameter**: `dt` — `number` — delta time in seconds since the last frame.
- **Performance**: This is the hot path. The engine drives all instances from a single compiled Lua driver chunk (the loop lives inside LuaJIT so the tracing JIT can compile it). Per-instance work is a table read + a `pcall` — no name lookup, no string comparison, no allocation.

```lua
function M:update(dt)
  local move = input.get_axis("move_left", "move_right")
  actor.move_by(self, move * self.speed * dt, 0)
  self.anim_t = self.anim_t + dt
end
```

### `fixed_update(dt)`

- **When**: Every fixed 60 Hz tick, decoupled from the render rate.
- **Purpose**: Deterministic simulation — physics, AI decisions, anything that must produce the same result regardless of frame rate.
- **Parameter**: `dt` — `number` — the fixed timestep (1/60 s).
- **Note**: Kept separate from `update` so the runtime drives them from different points in the loop.

```lua
function M:fixed_update(dt)
  self.cooldown = math.max(0, self.cooldown - dt)
  if self.cooldown == 0 and self:can_attack() then
    self:attack()
    self.cooldown = 0.5
  end
end
```

### `on_signal(name)`

- **When**: When a signal this actor listens to drains. The runtime calls this from the signal drain so Lua handlers run in the same frame the signal fires, after the typed Zig listeners.
- **Purpose**: React to events — "hit", "died", "collected", etc.
- **Parameter**: `name` — `string` — the signal/event name.
- **Note**: The engine's signal bus is typed; `on_signal` dispatches by name string to every listener that registered for that name.

```lua
function M:on_signal(name)
  if name == "hit" then
    self.hp = self.hp - 10
    actor.emit(self, "hp_changed")
  elseif name == "died" then
    self:sm_fire("death")
  end
end
```

### `on_destroy`

- **When**: Once, before the actor's Lua refs are released. The runtime sweeps dead instances once per frame after the update passes.
- **Purpose**: Final cleanup — increment a global counter, release a resource, log a message.
- **Note**: `on_destroy` fires exactly once. A second sweep does nothing (the instance has already been removed and its refs released).

```lua
function M:on_destroy()
  destroy_count = (destroy_count or 0) + 1
  log.info(actor.get_name(self) .. " destroyed")
end
```

## The `self` Table

Every behavior instance has a `self` table that:
- **Shares a metatable** with all other instances of the same script. The metatable's `__index` points to the script's prototype table (its methods and defaults).
- **Carries its entity handle** as light userdata under the key `__entity`, stamped once at instantiation. This is how `actor.*` bindings reach the ECS with one `world.get` — no map, no scan.
- **Holds per-instance state**: any field set on `self` (e.g. `self.hp = 100`) lives on the `self` table itself, shadowing the prototype. This is what survives a hot-reload.

```lua
-- Prototype (returned by the script chunk):
--   M.speed = 200
--
-- Instance:
--   self.speed  --> 200 (via metatable __index)
--   self.speed = 50  --> 50 (own field, shadows prototype)
```

## Error Isolation

A broken script is a **logged error, not a crash**. Every lifecycle call is wrapped in `pcall`:
- If an instance's `update` raises, the error is counted, logged through `__behavior_error`, and the frame continues with the next instance.
- The driver returns the per-frame error count.
- State machines swallow and count errors the same way: one broken state must not take down the frame.

## Frame Order

The engine calls the lifecycle hooks in a fixed order each frame:

1. **State machine tick** — advance all attached machines (applies pending transitions, runs `enter`/`update`/`exit`).
2. **Spatial grid rebuild** — bin entities into the uniform grid so `world.nearby` sees current positions.
3. **`update(dt)`** — drive all instances from the Lua driver.
4. **Signal drain** — fire typed Zig listeners, then `on_signal(name)` on Lua behaviors.
5. **`fixedUpdate(dt)`** — drive all instances that define `fixed_update` (at 60 Hz).
6. **Sweep** — run `on_destroy` and remove dead instances.

This ordering means a state's `update` may call `sm_fire` or `sm_set_state`, and a behavior's `update` (running later in the same frame) sees the state its machine just entered.

## Hot-Reload Interaction

Hot-reloading a script preserves all instance state:
- The `self` tables are never touched — they keep their fields.
- The shared metatable's `__index` is repointed at the new prototype.
- `start` does NOT re-run.
- The cached method refs (`update`, `fixed_update`, `on_signal`, `on_destroy`) are re-resolved for every live instance.

For details, see [Hot Reload](script-hot-reload.md).
