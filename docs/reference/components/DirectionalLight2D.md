# DirectionalLight2D — component id 16

**Registry name:** `DirectionalLight2D` · **id:** 16


**What it is:** the sun. No falloff: everything is lit equally and `angle` is the direction the light *travels*. It exists because a point light with a huge radius is dark at the far end of the screen — a sun is not anywhere.

| Field | Type | Default | Meaning |
|---|---|---|---|
| `base` | `LightBase` | `{}` | The shared light fields |
| `angle` | `f32` | `0` | The direction the light **travels**, radians. 0 is to the right |
| `height` | `f32` | `0.5` | 0..1, how high above the scene it sits. It scales shadow **length** |
| `max_distance` | `f32` | `0` | How far it reaches. 0 = unbounded |

**Driven by:** `render/light.zig`.

**Lua:** `directional.new(self)`, `directional.set_angle(self, radians)`, `directional.set_height(self, h)`.

**Gotcha:** `angle` is the direction of **travel**, not the direction it points — a sun at 0 shines right, so shadows fall left.

---

---

← [Component index](README.md) · [Registry mechanics](../ecs-components.md) · [Lua API](../script-lua-api.md)
