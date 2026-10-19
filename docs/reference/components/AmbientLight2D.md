# AmbientLight2D — component id 17

**Registry name:** `AmbientLight2D` · **id:** 17


**What it is:** the world's own light — light from everywhere, with no position in the falloff. Separate from `Environment` because a scene often wants **two** ambients (a sky colour and a ground bounce) and one number cannot hold both.

| Field | Type | Default | Meaning |
|---|---|---|---|
| `base` | `LightBase` | `{}` | The shared light fields |
| `global` | `bool` | `true` | Whether it applies to the whole scene |
| `max_distance` | `f32` | `128` | When `global == false`, the reach of the local ambient |

**Driven by:** `render/light.zig`.

**Lua:** `ambient.new(self)`, `ambient.set_local(self, distance)` (0 restores the scene-wide kind).

**Gotcha:** an ambient **never** casts a shadow.

---

## Camera

---

← [Component index](README.md) · [Registry mechanics](../ecs-components.md) · [Lua API](../script-lua-api.md)
