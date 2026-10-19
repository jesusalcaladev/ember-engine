# Sprite — component id 4

**Registry name:** `Sprite` · **id:** 4


**What it is:** "draw this". The whole visual description of an actor: what picture, how big, what colour, in what order. Position is not here — that is `Transform`. Use `shape = .circle` or a plain white quad to prototype before the art exists.

| Field | Type | Default | Meaning |
|---|---|---|---|
| `atlas` | `u8` | `0` | Texture slot. Slot 0 is the fallback white texture, so a sprite with no atlas still draws |
| `layer` | `u16` | `0` | Render layer; lower draws first. The batcher groups equal values into one draw call |
| `size` | `Vec2` | `{1,1}` | Size in world units; `Transform.scale` multiplies it |
| `shape` | `SpriteShape` | `.quad` | `quad` (0) or `circle` (1) |
| `uv` | `[4]f32` | `{0,0,1,1}` | Atlas rect, normalized `(u0,v0,u1,v1)` |
| `tint` | `[4]f32` | `{1,1,1,1}` | RGBA multiplied with the texel |
| `order` | `i32` | `0` | Stable tie-break inside a layer |
| `blend` | `Blend` | `.alpha` | `solid` (no blending, early-Z), `alpha` (source-over), `additive` (glows) |
| `visible` | `bool` | `true` | Draw nothing without despawning |
| `coverage_index` | `i32` | `-1` | The lighting system's sprite-coverage slot, or −1 for none |

**Driven by:** `render/2d.zig` — `collectFiltered`, **per frame**. It queries `(Transform, Sprite)`, skips invisible sprites, applies residency and frustum culling, interpolates the transform, and writes a 36-byte GPU instance.

**Lua:** `sprite.rect`, `sprite.circle`, `sprite.texture`, `sprite.set_size`, `sprite.set_tint(self, r, g, b, a)`, `sprite.set_uv`, `sprite.set_atlas`, `sprite.set_image(path)`, `sprite.set_shape`, `sprite.set_blend`, `sprite.set_layer`, `sprite.set_visible`, `sprite.get_size`, `sprite.get_tint`.

**Connects to:** `Transform` (**required** — the draw query is the pair), `LightBase.item_cull_mask` (the light's mask is a bitmask of `Sprite.layer`), `LightOccluder2D` in `auto_sdf` mode (the occluder rasterizes the sprite's alpha), and the **tweens** (`tween.to(self, "tint.a", 0, 0.3)` fades a sprite out).

**Gotchas:**
- `tint` is a **4-float RGBA**, not RGB.
- `Sprite.order` is used only by the **editor's** viewport picking, not by the runtime renderer (which orders by `layer`).
- `layer` is clamped to a byte in the GPU instance, so an out-of-range layer becomes 255 — the "every light" wildcard.

---

---

← [Component index](README.md) · [Registry mechanics](../ecs-components.md) · [Lua API](../script-lua-api.md)
