# UiProgressBar — component id 27

**Registry name:** `UiProgressBar` · **id:** 27


**What it is:** a 0..1 bar — health, mana, a reload timer.

| Field | Type | Default | Meaning |
|---|---|---|---|
| `layout` | `UiLayout` | `{}` | Placement and order |
| `value` | `f32` | `0` | The fill, 0..1 |
| `bg_color` | `[4]f32` | dark | The background |
| `fill_color` | `[4]f32` | green | The filled part |
| `show_text` | `bool` | `false` | Whether it draws its text |
| `text` | `InlineText` | empty | The optional text |
| `font` | `u32` | `0` | The font id |

**Driven by:** `ecs/ui_system.zig` + `render/ui_draw.zig`.

**Lua:** `ui.set_value(self, v)` (clamped 0..1), `ui.set_show_text`, `ui.set_text`, `ui.set_font`, `ui.set_color` (writes `fill_color`), the layout setters.

**Connects to:** `Timer` — `timer.progress(self)` feeds `ui.set_value`, and a **tween** can drive the value (`tween.to(self, "value", 1, 1.0)`).

---

## Parked: `TileMapLayer`

The type exists (`components/tilemap.zig`) but is **not registered**: the registry entry and the Lua module are both commented out ("M15 PARKED"). The editor's tilemap workspace can still use the type.

| Field | Type | Default | Meaning |
|---|---|---|---|
| `tileset_guid` | `AssetGUID` | `.{ .value = 0 }` | The palette it draws from |
| `layer` | `u16` | `0` | The render layer |
| `z_offset` | `f32` | `0.0` | A parallax offset inside the layer |
| `physics_enabled` | `bool` | `false` | Whether it collides |
| `tile_size_override` | `f32` | `0.0` | 0 = use the TileSet default |
| `default_flip_x` | `bool` | `false` | The default flip for new tiles |
| `default_flip_y` | `bool` | `false` | The default flip for new tiles |
| `_reserved` | `[3]u8` | zeroed | Reserved |

---

---

← [Component index](README.md) · [Registry mechanics](../ecs-components.md) · [Lua API](../script-lua-api.md)
