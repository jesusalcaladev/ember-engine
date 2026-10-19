# Light2D — component id 11

**Registry name:** `Light2D` · **id:** 11


**What it is:** the original single light component holding *every* kind, discriminated by `kind`. New scenes should use the four concrete kinds; `Light2D` stays because its **id is the `.zson` encoding** — deleting it would renumber every component after it.

| Field | Type | Default | Meaning |
|---|---|---|---|
| `kind` | `LightKind` | `.point` | point (0), spot (1), directional (2), ambient (3) |
| `color` | `[4]f32` | `{1,1,1,1}` | Colour × `energy` |
| `energy` | `f32` | `1` | Brightness multiplier |
| `offset` | `Vec2` | `{0,0}` | Hotspot offset, in the Transform's own frame |
| `radius` | `f32` | `128` | How far the light reaches |
| `angle` | `f32` | `0` | Spot: cone direction. Directional: travel direction |
| `cone_angle` | `f32` | `0.785` | Spot: full opening in radians (45°) |
| `penumbra` | `f32` | `0.2` | Spot: fraction of the cone given over to a soft edge |
| `attenuation` | `f32` | `1` | Falloff exponent |
| `blend` | `LightBlend` | `.add` | How it combines with the frame |
| `cast_shadows` | `bool` | `true` | Whether it casts shadows |
| `shadow_filter` | `ShadowFilter` | `.pcf3` | Edge softening |
| `shadow_filter_smooth` | `f32` | `2.0` | Tap spread |
| `item_cull_mask` | `u32` | `0xFFFFFFFF` | Which `Sprite.layer` values it affects |
| `enabled` | `bool` | `true` | Whether it is on |

**Driven by:** `render/light.zig` — `Lighting.collect`, **per frame**, through the same generic gather as the four kinds.

**Lua:** **not writable.** `light.*` writes only the four concrete kinds; `light.kind_of(self)` reports `"legacy"` for this one.

**Connects to:** `Transform`, `Environment`, `Sprite.layer`, `LightOccluder2D`.

**Gotcha:** a legacy `Light2D` **and** a `PointLight2D` on the same actor light the scene twice.

---

---

← [Component index](README.md) · [Registry mechanics](../ecs-components.md) · [Lua API](../script-lua-api.md)
