# PointLight2D — component id 14

**Registry name:** `PointLight2D` · **id:** 14


**What it is:** a lamp, a torch, a candle — a light that falls off in every direction. The light most scenes are made of.

| Field | Type | Default | Meaning |
|---|---|---|---|
| `base` | `LightBase` | `{}` | The shared light fields |
| `offset` | `Vec2` | `{0,0}` | Hotspot offset |
| `radius` | `f32` | `192` | How far it reaches. The falloff reaches exactly zero at `r` |
| `attenuation` | `f32` | `1` | Falloff exponent. Higher concentrates the light |

**Driven by:** `render/light.zig` — gathered per frame, flattened into a `LightDesc`.

**Lua:** `point.new(self, radius)`, `point.set_radius(self, r)`, plus the shared `light.set_color`, `light.set_energy`, `light.set_blend`, `light.set_shadow`, `light.set_mask`, and the getters.

**Connects to:** `Transform`, `Environment`, `Sprite.layer` via `item_cull_mask`, `LightOccluder2D`, and the **tweens** (`tween.to(self, "energy", 0, 0.5)` fades a light out).

**Gotchas:**
- The `light.*` setters write **only** the four concrete kinds, never the legacy `Light2D`.
- `light.get_radius` returns `0` for a directional or ambient light (they reach everywhere) — never nil.

---

---

← [Component index](README.md) · [Registry mechanics](../ecs-components.md) · [Lua API](../script-lua-api.md)
