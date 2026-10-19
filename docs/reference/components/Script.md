# Script — component id 6

**Registry name:** `Script` · **id:** 6


**What it is:** the serializable link between an actor and the Lua behaviour attached to it. It stores a **stable script id**, never a VM reference, so a scene file can say "this actor runs player.lua" and survive a save bit-exactly.

| Field | Type | Default | Meaning |
|---|---|---|---|
| `script` | `u32` | `0` | Index into the script cache. 0 means "no script" |

**Driven by:** `script/behavior.zig` — `Behaviors.attach` adds it. The live Lua state (`self` table, cached method refs) lives in the script subsystem, keyed off this component.

**Lua:** no direct binding. It is written by the engine.

**Connects to:** the script cache and the `Behaviors` instance list.

---

---

← [Component index](README.md) · [Registry mechanics](../ecs-components.md) · [Lua API](../script-lua-api.md)
