# Game UI: text, HUD and menus at runtime

Ember's **game UI** is the runtime half of M14: the widgets a *game* draws —
a HUD, a pause menu, a dialogue box — as opposed to the editor's ImGui panels,
which are editor-only and cannot be reused in a shipped game.

The whole surface is three plain ideas:

1. **Components.** A widget is an ECS component (`Label`, `UiButton`,
   `UiPanel`, `UiProgressBar`) on an actor, plus one `UiCanvas` per scene.
   Placement is a *field* of every widget (`UiLayout`), so a widget and where it
   sits are one entity and one scene-file entry.
2. **The `ui.*` Lua module.** Setters on `self` (like `sprite.*`) and a handful
   of queries (`measure`, `rect`, `hovered`, `pressed`).
3. **A signal.** A completed click fires `ui_pressed`.

There is **no node tree in Lua**. The public surface is Actor + Components,
the ECS stays internal, and a script touches its widget's fields through a
binding — exactly the shape every other component API uses.

> **Editor Note:** you normally create these components in the inspector and the
> editor writes the `.zson`. This page is the reference for what it produces.

---

## A complete HUD behavior

The rule that shapes every HUD: **one widget per actor.** Each `ui.*` setter
targets the widget on `self` (a button's `set_colors`, a bar's `set_value`, a
label's `set_align`), so two widgets on one actor cannot both be addressed. Give
each widget its own actor and keep the references.

```lua
local M = {}

function M:start()
  self.score = 0
  self.health = 1.0

  -- The screen root. One UiCanvas per scene; the first one wins.
  actor.add_component(self, "UiCanvas")

  -- One actor per widget. `find_by_name` is how a script addresses them.
  self.score_actor = actor.find_by_name(self, "hud_score")
  self.bar_actor   = actor.find_by_name(self, "hud_bar")

  -- A backdrop on its own actor. `interactive = false` so the HUD does not
  -- swallow clicks meant for the world.
  local panel = actor.find_by_name(self, "hud_panel")
  ui.set_color(panel, 0.05, 0.06, 0.09, 0.75)
  ui.set_border(panel, 1, 1, 1, 0.15, 1)

  ui.set_text(self.score_actor, "Score: 0")
  ui.set_value(self.bar_actor, 1.0)
  ui.set_show_text(self.bar_actor, true)

  -- The pause button's caption and id are set on ITS actor.
  local pause = actor.find_by_name(self, "hud_pause")
  ui.set_text(pause, "Pause")
end

function M:update(dt)
  ui.set_text(self.score_actor, "Score: " .. self.score)
  self.health = math.max(self.health - dt * 0.05, 0)
  ui.set_value(self.bar_actor, self.health)
  ui.set_text(self.bar_actor, string.format("%d%%", math.floor(self.health * 100)))
end

function M:on_signal(name, payload)
  if name == "ui_pressed" and payload.id == 1 then
    self:pause()
  end
end

function M:pause()
  -- dim the whole canvas (world + UI) while paused
  scene.tint(0.35, 0.35, 0.5, 0.6)
  scene.tint_mode("multiply")
  log.info("paused")
end

return M
```

The actors themselves are plain `.zson` entities — one widget component each.
Placement is the widget's `layout` field, and `UiCanvas` is the screen root:

```
entity 1 { Name "hud"       UiCanvas {virtual_w: 1280, virtual_h: 720, scale_mode: fit} }

entity 2 {
  Name "hud_panel"
  UiPanel {
    layout: {anchor: top_left, offset: {x: 16, y: 16}, size: {x: 260, y: 104}, interactive: false}
    color: [0.05, 0.06, 0.09, 0.75]
    border_color: [1, 1, 1, 0.15]
    border_width: 1
  }
}

entity 3 {
  Name "hud_score"
  Label {
    layout: {anchor: top_left, offset: {x: 32, y: 28}, size: {x: 220, y: 28}}
    text: "Score: 0"
    alignment: left
  }
}

entity 4 {
  Name "hud_bar"
  UiProgressBar {
    layout: {anchor: top_left, offset: {x: 32, y: 68}, size: {x: 220, y: 18}}
    value: 1
    show_text: true
  }
}

entity 5 {
  Name "hud_pause"
  UiButton {
    layout: {anchor: top_right, offset: {x: -24, y: 24}, size: {x: 96, y: 36}, pivot: {x: 1, y: 0}}
    text: "Pause"
    id: 1
  }
}
```

The enum fields are bare tags (`fit`, `top_left`, `left`), the nested `layout`
is a struct, and a hand-written block may omit any field — the decoder patches,
so absent fields keep their defaults. This is exactly the scene in
[`samples/ui-hud/scene.zson`](https://github.com/jesusalcaladev/ember-engine/blob/main/samples/ui-hud/scene.zson).

> `find_by_name` returns an actor handle you can store in a `self` field and
> pass to any `ui.*` setter — the same handle pattern `actor.*` uses everywhere.

---

## Components

All five are POD, byte-copyable, serialized to `.zson`, and editable in the
inspector. Every field has a default, so `actor.add_component(self, "Label")`
alone is a valid white 100×30 label at the top-left.

| Component | What it draws | Notable fields |
|---|---|---|
| `UiCanvas` | nothing — the screen root | `virtual_w`, `virtual_h`, `scale_mode`, `layer_base` |
| `Label` | a run of text | `text`, `font`, `color`, `alignment` |
| `UiButton` | a box + caption, 3 states | `text`, `id`, `enabled`, `color_normal/hover/pressed`, `text_color` |
| `UiPanel` | a filled box, optional border | `color`, `border_color`, `border_width` |
| `UiProgressBar` | a 0..1 bar, optional text | `value`, `bg_color`, `fill_color`, `show_text`, `text` |

Every widget also carries a **`UiLayout`** field with the same shape:

| Field | Meaning |
|---|---|
| `anchor` | one of the twelve presets below (default `top_left`) |
| `offset` | `{x, y}` displacement from the anchor point, in canvas pixels |
| `size` | `{x, y}` widget size in canvas pixels |
| `pivot` | `{x, y}`: `0,0` puts the top-left on the anchor, `0.5,0.5` centres it |
| `margin` | `[top, right, bottom, left]` insets, used only by the stretch presets |
| `order` | tie-break for paint order and hit-testing; higher wins |
| `visible` | whether it is drawn |
| `interactive` | whether it blocks world input and can be hovered/clicked |

`Label.text` and `UiButton.text` are **inline** (128 bytes) and truncate
silently past that, exactly like `Name`. A dialogue longer than a sentence wants
a text asset, which v1 does not have.

### `UiCanvas`

One per scene; the **first** one in entity-slot order wins. It maps the virtual
resolution onto the framebuffer:

- `scale_mode = "pixel"` — 1:1 with the framebuffer. Use for an exact HUD.
- `scale_mode = "fit"` — uniform scale with letterbox (the default).
- `scale_mode = "stretch"` — independent x/y, fills any window, distorts.

The canvas maps onto the **offscreen render target**, not the window, so a game
played inside the editor's viewport lays out to the viewport and not to the
editor window.

---

## Anchors

Twelve presets, Godot-style. The stretch presets ignore `size` and use `margin`.

```
 top_left    top_center    top_right
 middle_left    center    middle_right
 bottom_left bottom_center bottom_right

 stretch_h   -- full width, size.y tall, pinned to the anchor's vertical edge
 stretch_v   -- full height, size.x wide, pinned to the anchor's horizontal edge
 full_rect   -- the whole canvas, inset by margin
```

`stretch_h`/`stretch_v`/`full_rect` are how a HUD keeps its bars pinned to the
screen edges at any resolution without a single branch in the script.

---

## The `ui.*` module

### Layout setters

| Binding | Effect |
|---|---|
| `ui.set_anchor(self, name)` | one of the twelve preset names |
| `ui.set_offset(self, x, y)` | displacement from the anchor |
| `ui.set_size(self, w, h)` | widget size (ignored by stretch/full_rect on the filled axis) |
| `ui.set_pivot(self, x, y)` | `0.5, 0.5` centres the widget on its anchor |
| `ui.set_margin(self, top, right, bottom, left)` | stretch insets |
| `ui.set_order(self, order)` | paint + hit-test tie-break |
| `ui.set_visible(self, visible)` | draw or not |
| `ui.set_interactive(self, interactive)` | block world input / be clickable |

### Appearance setters

| Binding | Effect |
|---|---|
| `ui.set_text(self, text)` | label / button caption / bar text |
| `ui.set_font(self, id)` | `0` = the engine default, else an id from `ui.font_load` |
| `ui.set_color(self, r, g, b, a)` | the widget's primary colour |
| `ui.set_colors(self, normal, hover, pressed, text)` | a **button's** four colours, each a `{r,g,b,a}` table; a nil table leaves that colour alone |
| `ui.set_border(self, r, g, b, a, width)` | a **panel's** outline; zero width or alpha draws none |
| `ui.set_show_text(self, show)` | a **progress bar** draws its `text` |
| `ui.set_value(self, value)` | a bar's fill, clamped to `0..1` |
| `ui.set_align(self, align)` | a label's `"left"`, `"center"` or `"right"` |
| `ui.set_enabled(self, enabled)` | a button's enabled flag; a disabled button neither hovers nor fires |

### Queries and fonts

| Binding | Returns |
|---|---|
| `ui.measure(self, text)` | `w, h` — the pixel size `text` would occupy in this widget's font |
| `ui.rect(self)` | `x, y, w, h` — the screen rect resolved **last frame** (0,0 before the first layout) |
| `ui.hovered(self)` | true while the pointer is over this widget |
| `ui.pressed(self)` | true while this button is held down |
| `ui.font_load(path, px)` | a font id (cached by path + size); `0` when the file could not be read |

The engine loads **one default font** at boot if one is present, so text works
with no project setup. `ui.font_load` is a **load-time** call — call it in
`start`, not every frame; it reads a file, and the frame loop does no I/O.

```lua
function M:start()
  self.big = ui.font_load("assets/fonts/Inter-Bold.ttf", 32)
  actor.add_component(self, "Label", { text = "GAME OVER", font = self.big })
end
```

---

## Input: the UI consumes, it never leaks

Two rules, both enforced by the system, not by convention:

1. **Only interactive widgets capture the pointer.** `UiButton` and `UiPanel`
   participate in hit-testing, and only while `layout.interactive` is true and
   the widget is `visible`/`enabled`. A `Label` or `UiProgressBar` is
   decoration: a HUD score label must not swallow the click meant for the world
   under it. (Godot draws the same distinction with `mouse_filter`.)
2. **The capture is a query, not a filter.** The action-input API is unchanged.
   A world script asks `input.pointer_over_ui()` and gates its own input:

```lua
if input.is_action_pressed("fire") and not input.pointer_over_ui() then
  self:shoot()
end
```

`input.pointer_over_ui()` is true while the pointer is over an interactive
widget (a button or an interactive panel). It is updated every frame, before
scripts run, so a behavior sees the frame's real answer.

When two widgets overlap, the one with the higher `order` wins; equal orders
fall back to entity-slot order (stable, spec §6).

---

## The `ui_pressed` signal

A button fires when a **press and its release land on the same button** — the
"pressed in A, released in B" case does not fire, which is the classic
accidental-double-click bug this exists to prevent.

The signal reaches every Lua `on_signal` handler as a payload table:

```lua
function M:on_signal(name, payload)
  if name == "ui_pressed" then
    -- payload.id     = the button's `id` field
    -- payload.entity = the button actor's handle bits
    log.info("button " .. payload.id .. " pressed")
  end
end
```

`id` is the widget's authored `id` field, so a single HUD script can respond to
many buttons. Zig listeners get the same press on the typed bus as
`ecs.ui_system.UiEvent { id, entity }`.

---

## CanvasModulate: the full-screen tint

`scene.tint*` lays a colour over the **whole canvas — world and UI together**.
It is a post pass, so it costs one uniform and zero extra draw calls when off.
It is the right tool for a dusk grade, a damage flash or a pause veil.

```lua
scene.tint(r, g, b, a)        -- apply a colour; `a` is the strength 0..1 (0 = off)
scene.tint_mode(name)         -- "multiply" (default) | "add" | "alpha" | "off"
scene.tint_clear()            -- disable and forget the colour
scene.tint_amount()           -- current strength, for animating a flash back down
```

- **multiply** — grade an ambience: `scene.tint(0.6, 0.5, 0.75, 0.8)`.
- **add** — a flash: `scene.tint(1, 0.2, 0.2, 0.7); scene.tint_mode("add")`.
- **alpha** — a flat veil: `scene.tint(0, 0, 0, 0.5); scene.tint_mode("alpha")`.

`scene.tint` defaults to `multiply` when the tint was off, so the common case
is one call. A tint that reaches only the world or only the UI is **out of
scope for v1**: the pass runs over the composited frame.

---

## Budget and limits (v1)

- **Draw calls.** Glyphs and widget quads share the existing sprite atlas and
  batcher; the whole HUD is a handful of instanced draws, not one per widget.
  The M14 criterion is 200 labels in **one** draw call.
- **No allocation in the frame loop.** The UI system reserves a fixed budget of
  `256` widgets per frame; the tail clips and is counted, it never grows.
- **ASCII v1.** The printable ASCII range is preloaded; non-ASCII codepoints
  rasterize on demand from the same cache. There is no kerning and no automatic
  word wrap.
- **Text is inline.** `Label`/`UiButton`/`UiProgressBar` text is 128 bytes,
  truncated silently.

### Not in this milestone

Containers (`HBoxContainer`, `VBoxContainer`, `GridContainer`,
`MarginContainer`), `TextureRect`/`TextureButton`/nine-slice frames,
`ScrollContainer`/`TabContainer`/tooltips, keyboard/gamepad focus navigation,
rich text and wrapping, world-space UI and per-layer tint. The layout is already
a plain rect, so a container above it is additive work.

---

## See also

- [First Game](first-game.md) — the collector tutorial extended with this HUD
- [Script Behaviors](../reference/script-behaviors.md) — `on_signal` and the lifecycle
- [Rendering](../reference/render-pipeline.md) — the batcher and atlas the UI rides on
- [Lua API Reference](../reference/script-lua-api.md) — every binding, with examples
- [`samples/ui-hud/`](https://github.com/jesusalcaladev/ember-engine/tree/main/samples/ui-hud) — a copy-paste HUD sample
