# RigidBody2D — component id 8

**Registry name:** `RigidBody2D` · **id:** 8


**What it is:** "this actor is a physical object". It covers Godot's three body kinds (static / kinematic / dynamic) as one component with a `body_type` byte, so switching a door from fixed to kinematic at runtime does not change the archetype.

| Field | Type | Default | Meaning |
|---|---|---|---|
| `body` | `u32` | `invalid_body` | The solver's body handle. Invalid = "not in a physics world" |
| `generation` | `u32` | `0` | The handle's generation tag |
| `body_type` | `u8` | `2` | 0 fixed, 1 kinematic, 2 dynamic |
| `linear_velocity` | `Vec2` | `{0,0}` | Kept in the component as well as in the solver, so gameplay reads and writes it without a physics call |
| `angular_velocity` | `f32` | `0.0` | Radians per second |
| `linear_damping` | `f32` | `0.0` | Passed to the solver |
| `angular_damping` | `f32` | `0.0` | Passed to the solver |
| `gravity_scale` | `f32` | `1.0` | Gravity multiplier. 1.0 = normal gravity, not "no gravity" |
| `fixed_rotation` | `bool` | `false` | Lock rotation |
| `allow_sleep` | `bool` | `true` | Sleeping is allowed by default |
| `is_bullet` | `bool` | `false` | Continuous collision, for fast bodies |
| `prev_position` | `Vec2` | `{0,0}` | The position at the previous step, for interpolation |
| `prev_rotation` | `f32` | `0.0` | The rotation at the previous step |
| `tier` | `u8` | `0` | How much physics this body gets. 0 = full. Stored on the component so it survives save/load |

**Driven by:** `physics/system.zig` — `step`, whose order *is* the contract: **pushDown** (ECS → solver: the transform is snapshotted into `prev_*`, velocity is written **only if it changed**, otherwise nothing ever sleeps) → **step** (fixed 60 Hz) → **pullUp** (the solver's authoritative position into `Transform`) → **publishContacts** (the `collision` signal, one event per side).

**Lua:** `actor.set_linear_velocity(self, vx, vy)`, `actor.get_linear_velocity(self)`, `actor.apply_impulse(self, ix, iy)`, `actor.is_awake(self)`, `physics.set_body_type(self, kind)`, `physics.set_body_enabled(self, on)`, `physics.create_shape(self, kind, hw, hh)`, `physics.set_layers(self, layer, mask)`.

**Connects to:** `Transform` (the solver writes it), `Collider2D` (the shape is created with the body), `CollisionLayers` (the body's filter).

**Gotchas:**
- The component is a **handle**: the solver's own state (mass, contacts, sleeping) lives on the physics side.
- `pushDown` re-asserts the component's velocity every frame, so a velocity set directly on the solver between frames is discarded. That is why `actor.set_linear_velocity` goes through the component.
- A body with no `Collider2D` still simulates (it falls, it is just not solid).

---

---

← [Component index](README.md) · [Registry mechanics](../ecs-components.md) · [Lua API](../script-lua-api.md)
