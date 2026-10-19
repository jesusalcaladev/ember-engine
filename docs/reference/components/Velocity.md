# Velocity — component id 3

**Registry name:** `Velocity` · **id:** 3


**What it is:** linear and angular speed for an actor that moves **without** colliding. Reach for it when something should drift, scroll or spin and must not push anything.

| Field | Type | Default | Meaning |
|---|---|---|---|
| `linear` | `Vec2` | `{0,0}` | Units per second |
| `angular` | `f32` | `0` | Radians per second |

**Driven by:** **no engine system**. The camera reads it for look-ahead; the benchmark integrates it by hand.

**Lua:** **no bindings.** `actor.set_linear_velocity` goes through the **physics** system, not this component.

**Connects to:** `Camera2D.look_ahead`.

**Gotcha:** adding a `Velocity` to a scene file does **nothing** on its own. Use `RigidBody2D` for anything that must actually move.

---

## Rendering

---

← [Component index](README.md) · [Registry mechanics](../ecs-components.md) · [Lua API](../script-lua-api.md)
