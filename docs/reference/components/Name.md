# Name — component id 0

**Registry name:** `Name` · **id:** 0


**What it is:** a short label baked into the actor, so a designer, a debugger and the scene file can refer to it. It is the key `.zson` overrides match by, and the name the inspector shows.

| Field | Type | Default | Meaning |
|---|---|---|---|
| `bytes` | `[32]u8` | zeroed | The name, inline, NUL-padded |
| `len` | `u8` | `0` | How many bytes are valid |

**Driven by:** nothing — passive data. Written by the `.zson` decoder and by `Actor.setName`.

**Lua:** `actor.get_name(self)`. There is **no** `actor.set_name`: a name comes from a scene file or from Zig.

**Connects to:** the `.zson` override mechanism and the editor.

**Gotcha:** names longer than 32 bytes are **truncated silently**; a duplicate name in a document is uniquified at load.

---

---

← [Component index](README.md) · [Registry mechanics](../ecs-components.md) · [Lua API](../script-lua-api.md)
