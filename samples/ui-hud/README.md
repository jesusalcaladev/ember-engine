# UI HUD sample

A minimal scene that shows the M14 runtime UI: a HUD with a **label**, a
**progress bar**, a **panel** backdrop and a clickable **pause button**, all
driven from Lua — plus the rule that makes the UI safe: it consumes the pointer
without leaking it to the world.

```
samples/ui-hud/
├── scene.zson   # camera, player, and the HUD actors
├── hud.lua      # the HUD behavior (on the `hud` root actor)
└── player.lua   # a world behavior that defers to the UI over the pointer
```

## What is in the scene

| Actor | Component | Role |
|---|---|---|
| `camera` | `Transform` | the world camera |
| `player` | `Sprite` + `Script` | a blue square with `player.lua` |
| `hud` | `UiCanvas` + `Script` | the screen root with `hud.lua` |
| `hud_panel` | `UiPanel` | the HUD backdrop (`interactive: false`) |
| `hud_score` | `Label` | `Score: 0` |
| `hud_bar` | `UiProgressBar` | the 30-second countdown, with text |
| `hud_pause` | `UiButton` | `Pause`, id `1`, pinned top-right |

**One widget per actor.** Every `ui.*` setter addresses the widget on the actor
it is given, so each widget gets its own actor and is reached with
`actor.find_by_name`. Placement lives in the widget's `layout` field: the panel
and label are pinned `top_left`, the button is `top_right` with
`pivot = {x: 1, y: 0}`, so it stays in the corner at any window size.

## What it demonstrates

- **Text and bars** — `Label` and `UiProgressBar` render with the engine's
  default font; no project setup is needed. `hud.lua` rewrites the label and the
  bar every frame.
- **A clickable button** — releasing the pointer over `hud_pause` fires
  `ui_pressed` with `payload.id == 1`; the HUD toggles pause, dims the whole
  canvas with `scene.tint`, and swaps the caption.
- **Input capture, not filtering** — `input.pointer_over_ui()` is `true` while
  the cursor is over the button, so `player.lua` checks it before acting. The
  action-input API itself is unchanged; the world asks, the UI never silently
  eats the click.

## Running it

The intended workflow is the editor: open the scene, attach `hud.lua` to `hud`
and `player.lua` to `player`, and press **Play**. The files here are the ones
the editor writes, handy for copy-paste into your own project — drop the `hud`
actors and `UiCanvas` into an existing scene and attach `hud.lua` to the root.

See [Game UI](../../docs/reference/game-ui.md) for the full `ui.*` surface,
anchors, the `ui_pressed` payload and `scene.tint*`, and
[First Game](../../docs/guides/first-game.md) for the same HUD as a step in the
collector tutorial.
