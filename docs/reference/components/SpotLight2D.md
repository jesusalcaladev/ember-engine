# SpotLight2D — component id 15

**Registry name:** `SpotLight2D` · **id:** 15


**What it is:** a cone of light with a soft edge. The `penumbra` is a *fraction of the cone* rather than an angle, because a designer thinks "the last fifth of the beam is soft".

| Field | Type | Default | Meaning |
|---|---|---|---|
| `base` | `LightBase` | `{}` | The shared light fields |
| `offset` | `Vec2` | `{0,0}` | Hotspot offset |
| `radius` | `f32` | `192` | How far the beam reaches |
| `angle` | `f32` | `0` | The direction the cone points, radians |
| `cone_angle` | `f32` | `0.785` | The full opening in radians |
| `penumbra` | `f32` | `0.2` | The fraction of the cone given over to a soft edge |
| `attenuation` | `f32` | `1` | Falloff exponent |

**Driven by:** `render/light.zig`.

**Lua:** `spot.new(self, radius)`, `spot.set_radius`, `spot.set_cone(self, degrees, penumbra)`, `spot.set_angle(self, radians)`.

**Gotcha:** `spot.set_cone` takes **degrees**; the component stores **radians**.

---

---

← [Component index](README.md) · [Registry mechanics](../ecs-components.md) · [Lua API](../script-lua-api.md)
