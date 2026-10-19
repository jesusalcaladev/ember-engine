# Label — component id 24

**Registry name:** `Label` · **id:** 24


**What it is:** a run of text on the screen — scores, captions, dialogue.

| Field | Type | Default | Meaning |
|---|---|---|---|
| `layout` | `UiLayout` | `{}` | Placement, order, and the runtime `resolved` rect |
| `font` | `u32` | `0` | 0 is the engine default; any other id comes from `ui.font_load` |
| `text` | `InlineText` | empty | The string, inline, max 128 bytes |
| `color` | `[4]f32` | `{1,1,1,1}` | The text colour |
| `alignment` | `TextAlign` | `.left` | `left`, `center`, `right` |

**`UiLayout`** (a field, not a component — by design):

| Field | Type | Default | Meaning |
|---|---|---|---|
| `anchor` | `UiAnchor` | `.top_left` | One of twelve presets: `top_left`…`bottom_right`, `stretch_h`, `stretch_v`, `full_rect` |
| `offset` | `Vec2` | `{0,0}` | The displacement from the resolved anchor point |
| `size` | `Vec2` | `{100,30}` | The widget's size in canvas pixels |
| `pivot` | `Vec2` | `{0,0}` | `0,0` anchors the top-left; `0.5,0.5` centres it |
| `margin` | `[4]f32` | `{0,0,0,0}` | top, right, bottom, left insets, for the stretch presets |
| `order` | `i32` | `0` | The paint order and the hit-test order |
| `visible` | `bool` | `true` | Whether it is drawn |
| `interactive` | `bool` | `true` | Whether it blocks world input |
| `resolved` | `Rect2` | empty | **Runtime**: the screen-pixel rect resolved this frame |

**Driven by:** `ecs/ui_system.zig` — `update` **per frame**: gather, resolve the layout, sort by `(order, kind)`, hit-test, and fire `ui_pressed`.

**Lua:** `ui.set_text`, `ui.set_font`, `ui.set_color(self, r, g, b, a)`, `ui.set_align`, the layout setters, `ui.rect(self)`, `ui.hovered(self)`, `ui.pressed(self)`, `ui.measure(self, text)`, `ui.font_load(path, px)`.

**Connects to:** `UiCanvas`, its `UiLayout`, the font system, and the **tweens** (`tween.to(self, "color.a", 0, 0.3)` fades a label out).

**Gotchas:**
- The field is `alignment`, not `align` (`align` is a Zig keyword); the Lua setter is still `ui.set_align`.
- `InlineText` truncates at **128 bytes, silently**.
- A `Label` never captures the pointer.

---

---

← [Component index](README.md) · [Registry mechanics](../ecs-components.md) · [Lua API](../script-lua-api.md)
