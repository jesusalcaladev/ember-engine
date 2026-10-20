# Collider2D — component id 9

**Registry name:** `Collider2D` · **id:** 9


**What it is:** the shape that gives a body something to collide *with* — a box, circle, capsule, cylinder or polygon.

| Field | Type | Default | Meaning |
|---|---|---|---|
| `shape` | `u32` | `invalid_shape` | The solver's shape handle |
| `generation` | `u32` | `0` | The handle's generation tag |
| `kind` | `u8` | `0` | 0 box, 1 circle, 2 capsule, 3 cylinder, 4 polygon |
| `size` | `Vec2` | `{0.5,0.5}` | **Half**-extents (box), or x = radius / y = cap offset (capsule) |
| `offset` | `Vec2` | `{0,0}` | Shape offset from the body origin |
| `density` | `f32` | `1.0` | Density → mass |
| `friction` | `f32` | `0.3` | Friction |
| `restitution` | `f32` | `0.0` | Bounciness |
| `is_sensor` | `bool` | `false` | Reports overlaps **without** a contact response (a trigger) |

**Driven by:** `physics/system.zig` — the shape is created with the body and rebuilt in place by `reshape` / `reapplyFilter` / `setMaterial` / `setSensor` (the filter lives on the *shape*, so changing layers is a shape rebuild).

**Lua:** `physics.create_shape(self, kind, hw, hh)`, `physics.reshape`, `physics.set_material(self, friction, restitution, density)`, `physics.set_sensor(self, on)`.

**Connects to:** **requires `RigidBody2D`** — a shape is only ever created for an entity that has a body. Also `CollisionLayers` and `Transform`.

**The sensor IS the area.** There is no `Area2D` component: an area is a
`Collider2D` with `is_sensor = true`, and the contact signal says which it is
through `other_is_sensor`. A sensor reports its overlaps through the same
contact queue as a solid body and stops nothing — which is exactly what an
area does. See [Areas](../physics-overview.md#areas-the-engines-answer-to-gods-area2d).

**Gotchas:**
- A `Collider2D` without a `RigidBody2D` is **inert**.
- `size` is **half**-extents: a box of `{0.5, 0.5}` is 1×1 world units.
- `is_sensor = true` is the engine's **Area2D**: it reports overlaps through the `collision` signal without stopping anything.

---

---

← [Component index](README.md) · [Registry mechanics](../ecs-components.md) · [Lua API](../script-lua-api.md)
