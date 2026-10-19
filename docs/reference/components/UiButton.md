# UiButton — component id 25

**Registry name:** `UiButton` · **id:** 25


**What it is:** a clickable box with a caption.

| Field | Type | Default | Meaning |
|---|---|---|---|
| `layout` | `UiLayout` | `{}` | Placement and order |
| `text` | `InlineText` | empty | The caption |
| `font` | `u32` | `0` | The font id |
| `id` | `u32` | `0` | Returned in the `ui_pressed` signal |
| `enabled` | `bool` | `true` | A disabled button is inert |
| `color_normal` | `[4]f32` | dark | The idle fill |
| `color_hover` | `[4]f32` | lighter | The fill under the pointer |
| `color_pressed` | `[4]f32` | darkest | The fill while held |
| `text_color` | `[4]f32` | near-white | The caption colour |
| `state` | `UiButtonState` | `.normal` | **Runtime**: normal, hover, pressed |

**Driven by:** `ecs/ui_system.zig` — per frame; the press/release edges fire `ui_pressed` on the world bus and into Lua's `on_signal("ui_pressed", { id, entity })`.

**Lua:** `ui.set_text`, `ui.set_font`, `ui.set_enabled`, `ui.set_colors(self, normal, hover, pressed, text)`, `ui.set_color`, the layout setters, `ui.hovered`, `ui.pressed`.

**Gotchas:**
- `ui.set_color` on a button writes **`text_color`**, not the background.
- A press in A and a release in B does **not** fire.

---

---

← [Component index](README.md) · [Registry mechanics](../ecs-components.md) · [Lua API](../script-lua-api.md)
