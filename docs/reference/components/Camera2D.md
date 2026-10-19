# Camera2D — component id 18

**Registry name:** `Camera2D` · **id:** 18


**What it is:** the window onto the world: what is centred, how zoomed, how shaken, and what it may not leave.

| Field | Type | Default | Meaning |
|---|---|---|---|
| `target` | `Entity` | `Entity.invalid` | The entity to follow |
| `follow_enabled` | `bool` | `true` | Whether the follow is active |
| `deadzone` | `Rect2` | `{pos:{0,0}, size:{-1,-1}}` | A deadzone around the centre. A **negative size = disabled** |
| `damping` | `f32` | `5.0` | The critically-damped spring's frequency. 0 = snap |
| `look_ahead` | `f32` | `0.0` | Seconds of the target's velocity to lead by |
| `zoom` | `f32` | `1.0` | The current zoom |
| `min_zoom` | `f32` | `0.1` | Lower clamp |
| `max_zoom` | `f32` | `10.0` | Upper clamp |
| `zoom_damping` | `f32` | `8.0` | Zoom smoothing rate |
| `trauma` | `f32` | `0.0` | Shake amount, 0..1, decaying |
| `trauma_power` | `f32` | `2.0` | The shake curve's exponent |
| `trauma_decay` | `f32` | `1.0` | Shake decay per second |
| `shake_frequency` | `f32` | `25.0` | The shake noise's frequency |
| `shake_amplitude` | `f32` | `10.0` | The shake's magnitude at full trauma |
| `limits_enabled` | `bool` | `false` | Whether the centre is clamped |
| `limits` | `Rect2` | big | The rectangle the centre may not leave |
| `enabled` | `bool` | `true` | Whether this camera is a candidate for the view |
| `_offset` | `Vec2` | `{0,0}` | **Runtime**: the current centre |
| `_velocity` | `Vec2` | `{0,0}` | **Runtime**: the spring's velocity |
| `_target_zoom` | `f32` | `1.0` | **Runtime**: the zoom it is easing toward |
| `_trauma_timer` | `f32` | `0.0` | **Runtime**: the shake clock |

**Driven by:** `ecs/camera.zig` — `update(world, dt, w, h) -> ?View`, **once per rendered frame** (not once per sub-step), with `dt = fixed_dt * steps`.

**Lua:** `camera.new(self)`, `camera.follow(self, other)`, `camera.zoom_to(self, zoom)`, `camera.shake(self, trauma)`, `camera.set_limits(self, x, y, w, h)`, `camera.set_damping(self, d)`, `camera.get_centre(self)`.

**Connects to:** the target's `Transform` and `Velocity`. Produces the `View` the renderer uses for the projection and the cull rect.

**Gotchas:**
- Only the **first enabled** camera is simulated. A second camera is inert, not merely lower priority.
- `camera.get_centre` returns `_offset` — **without** the shake.
- `camera.zoom_to` sets the *target*; the camera eases toward it.

---

## Audio and particles

---

← [Component index](README.md) · [Registry mechanics](../ecs-components.md) · [Lua API](../script-lua-api.md)
