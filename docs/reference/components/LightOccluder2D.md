# LightOccluder2D — component id 12

**Registry name:** `LightOccluder2D` · **id:** 12


**What it is:** "this actor blocks light". It is how a wall casts a shadow and how a character silhouette stops a torch.

| Field | Type | Default | Meaning |
|---|---|---|---|
| `mode` | `OccluderMode` | `.auto_sdf` | `auto_sdf` (derive the shape from the sprite's alpha), `manual` (use `polygon`), `none` (cast nothing) |
| `polygon` | `OccluderPolygon` | empty | Used when `mode == .manual` |
| `alpha_threshold` | `f32` | `0.5` | The alpha at which `auto_sdf` decides a texel is solid |
| `cull_mask` | `u32` | `0xFFFFFFFF` | Which lights this occluder blocks, by light index. 0 = all |
| `enabled` | `bool` | `true` | Whether it participates |

**Driven by:** `render/light.zig` — gathered per frame; the set is fingerprinted and the mask is only re-rasterized when the fingerprint changes.

**Lua:** `occluder.new(self, mode)`, `occluder.set_mode`, `occluder.set_threshold`, `occluder.set_mask`, `occluder.set_polygon(self, {x0, y0, ...})`, plus the getters.

**Connects to:** **requires `Sprite`** in `auto_sdf` mode. Also `Transform` and the lights' shadow channels.

**Gotchas:**
- `auto_sdf` **skips the entity entirely** if it has no `Sprite`.
- The automatic shape falls back to the sprite's **rectangle** without a coverage mask.
- `mode = .none` is the escape hatch: "looks like it occludes but must not".

---

---

← [Component index](README.md) · [Registry mechanics](../ecs-components.md) · [Lua API](../script-lua-api.md)
