# UiPanel — component id 26

**Registry name:** `UiPanel` · **id:** 26


**What it is:** a filled box — a HUD backdrop, a menu background, a divider.

| Field | Type | Default | Meaning |
|---|---|---|---|
| `layout` | `UiLayout` | `{}` | Placement and order |
| `color` | `[4]f32` | `{0.08,0.09,0.12,0.85}` | The fill |
| `border_color` | `[4]f32` | transparent | The border colour |
| `border_width` | `f32` | `0` | The border thickness, drawn as **four thin quads** |

**Driven by:** `ecs/ui_system.zig` + `render/ui_draw.zig`.

**Lua:** `ui.set_color`, `ui.set_border(self, r, g, b, a, width)`, the layout setters.

**Gotcha:** a panel with `interactive = true` **swallows world clicks** over its rect.

---

---

← [Component index](README.md) · [Registry mechanics](../ecs-components.md) · [Lua API](../script-lua-api.md)
