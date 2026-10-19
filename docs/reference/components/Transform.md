# Transform — component id 1

**Registry name:** `Transform` · **id:** 1


**What it is:** where an actor is and how it is oriented. Almost every visual component draws relative to it, so this is the one component nearly every actor has.

| Field | Type | Default | Meaning |
|---|---|---|---|
| `position` | `Vec2` | `{0,0}` | Local position (world position once the parent chain is resolved) |
| `rotation` | `f32` | `0` | Radians, positive clockwise (screen y grows down) |
| `scale` | `Vec2` | `{1,1}` | Multiplies `Sprite.size` |
| `prev_position` | `Vec2` | `{0,0}` | The position at the previous fixed tick |
| `prev_rotation` | `f32` | `0` | The rotation at the previous fixed tick |
| `prev_scale` | `Vec2` | `{1,1}` | The scale at the previous fixed tick |

**Driven by:** gameplay, physics, animation root motion and scripts. **Read per frame** by the renderer, which blends `prev → current` with the interpolation factor.

**Lua:** `actor.get_position`, `actor.set_position`, `actor.translate`, `actor.move_by`, `actor.get_rotation`, `actor.set_rotation`, `actor.set_transform(self, x, y, rot?, scale?)`, `actor.get_all`.

**Connects to:** `Sprite` (position + scale → pixels), `Camera2D` (the follow target's transform is what the camera chases), `RigidBody2D` (the solver writes it back), `Parent` (the hierarchy resolver folds local transforms), the lights (position + rotation place them), `ParticleEmitter2D` (the spawn point), `AnimationPlayer` (value tracks and root motion write it), and the **tweens** (`tween.to(self, "position.x", ...)`).

**Gotchas:**
- `prev_*` is **not** writable from Lua, on purpose: `actor.set_transform` deliberately leaves it alone so a teleport interpolates across one tick instead of smearing.
- `prev_*` is captured by `world.captureTransforms()` at the **start of every fixed step**. Without that call the renderer blends from the spawn position and every moving actor drags a line back to where it was born.

---

---

← [Component index](README.md) · [Registry mechanics](../ecs-components.md) · [Lua API](../script-lua-api.md)
