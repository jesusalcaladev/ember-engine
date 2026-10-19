# CollisionLayers — component id 10

**Registry name:** `CollisionLayers` · **id:** 10


**What it is:** which named collision groups a body belongs to, and which groups it is willing to talk to. It is a property of the *body*, not of a shape.

| Field | Type | Default | Meaning |
|---|---|---|---|
| `layer` | `u16` | `0xFFFF` | Which layer(s) this body is on |
| `mask` | `u16` | `0xFFFF` | Which layer(s) it will interact with |

**Driven by:** `physics/system.zig` — **no `CollisionLayers` means "collide with everything"**, deliberately.

**Lua:** `physics.set_layers(self, layer_mask, collide_mask)` — bitmasks, not names; the binding cannot resolve names because it has no project layer table.

**Connects to:** `Collider2D` (the filter is baked into the shape) and `RigidBody2D`.

**Gotcha:** the rule is **symmetric**: one direction is not enough. A projectile on a layer the wall does not mask will pass through.

---

## Lighting

---

← [Component index](README.md) · [Registry mechanics](../ecs-components.md) · [Lua API](../script-lua-api.md)
