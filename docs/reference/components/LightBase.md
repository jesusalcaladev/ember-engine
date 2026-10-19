# LightBase — a shared struct, not a component

**Registry name:** `LightBase` · **not registered**


The four concrete light kinds embed this by value. It is **not** registered — it is a plain struct.

| Field | Type | Default | Meaning |
|---|---|---|---|
| `color` | `[4]f32` | `{1,1,1,1}` | Colour × `energy`. Alpha is the light's opacity |
| `energy` | `f32` | `1` | Brightness multiplier |
| `blend` | `LightBlend` | `.add` | `add` / `subtract` / `mix` |
| `cast_shadows` | `bool` | `true` | Whether it casts shadows (a budget decision: four shadow channels) |
| `shadow_filter` | `ShadowFilter` | `.pcf3` | Edge softening: `off`, `pcf1`, `pcf3`, `pcf5` |
| `shadow_filter_smooth` | `f32` | `2.0` | Tap spread, in shadow-mask texels |
| `item_cull_mask` | `u32` | `0xFFFFFFFF` | Which `Sprite.layer` values this light affects |
| `enabled` | `bool` | `true` | Whether the light is on at all |

---

---

← [Component index](README.md) · [Registry mechanics](../ecs-components.md) · [Lua API](../script-lua-api.md)
