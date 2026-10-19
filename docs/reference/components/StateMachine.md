# StateMachine — component id 7

**Registry name:** `StateMachine` · **id:** 7


**What it is:** a handle to a finite state machine **defined in Lua** (states, transitions and their callbacks are script data, not component data). Reach for it for enemy AI, boss phases, spawner cycles, game flow — anything with named states and event-driven transitions.

| Field | Type | Default | Meaning |
|---|---|---|---|
| `machine` | `u32` | `0` | Index into the engine's state-machine registry. 0 = "none" |
| `started` | `bool` | `false` | True once the machine has been entered |

**Driven by:** `script/statemachine.zig`. The component is only the index; the registry owns the states, transitions and Lua callback refs.

**Lua:** `sm.add_state(self, name, hooks?)` (creates the machine **and** the component), `sm.add_transition(self, from, event, to)`, `sm.set_initial(self, name)`, `sm.fire(self, event)`, `sm.set_state(self, name)`, `sm.state(self)`, `sm.is_in(self, name)`.

**Connects to:** the state-machine registry and, through it, the behaviour's `self` table.

**Gotchas:**
- It is a **handle**, forced by the registry rule "plain data only" (a machine holds names and callbacks).
- There is **no global machine**: `sm.*` is per entity. A game-flow machine is a *global script* (see [Global Scripts](global-scripts.md)) or an actor with a `StateMachine`.
- A transition is applied at the **top of the next tick**, so firing from inside a callback cannot re-enter the machine.

---

---

← [Component index](README.md) · [Registry mechanics](../ecs-components.md) · [Lua API](../script-lua-api.md)
