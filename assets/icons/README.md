# Editor icons — what to download, and where to put it

**Why this file exists:** the editor draws its icons as geometry
(`src/engine/ui/icons.zig`), which is fine for a chevron and terrible for a
gizmo. This folder is where the real icons go: you download them, drop them
in, and the engine uses them. Until then, the drawn ones are the fallback and
nothing is broken.

## The contract

| | |
|---|---|
| **Folder** | `assets/icons/` (this folder) |
| **File name** | the icon's name in kebab-case: `move.png`, `rotate.png`, `chevron-down.png` |
| **Format** | PNG with an alpha channel, 32×32 (the engine scales it down; a 32px source keeps it crisp on a HiDPI screen) |
| **Colour** | white, fully opaque — the engine tints the icon at draw time, so a coloured PNG would fight the theme |
| **Style** | a 1.5px stroke on a 24×24 grid, round caps (the same as the drawn ones) |

**No colour in the file.** A tinted icon is the only kind that works in a
theme: the accent when it is active, the dim grey when it is not.

## The list

### The viewport's tools (the ones the editor needs most)

| File | What it is | Used by |
|---|---|---|
| `cursor.png` | an arrow pointer | the Cursor tool |
| `move.png` | a four-arrow cross | the Move gizmo |
| `rotate.png` | a circular arrow | the Rotate gizmo |
| `scale.png` | a diagonal double arrow | the Scale gizmo |
| `tiles.png` | a 2×2 grid of squares | the TileMap brush |
| `focus.png` | a rectangle with corner brackets | "frame the selection" (F) |
| `home.png` | a house, or a crosshair | "reset the view" (Home) |

### The existing set (the drawn ones, if you want to replace them)

| File | What it is |
|---|---|
| `chevron-right.png` | the tree's fold arrow, pointing right |
| `chevron-down.png` | the tree's fold arrow, pointing down |
| `chevron-up.png` | the tree's fold arrow, pointing up |
| `chevron-left.png` | a back arrow |
| `check.png` | a tick |
| `plus.png` | a plus (add component) |
| `minus.png` | a minus |
| `close.png` | an X |
| `search.png` | a magnifier |
| `folder.png` | a closed folder |
| `folder-open.png` | an open folder |
| `file.png` | a document |
| `gear.png` | a cog (settings) |
| `play.png` | a triangle (Play) |
| `pause.png` | two bars (Pause) |
| `stop.png` | a square (Stop) |
| `skip-start.png` | a bar and a left triangle (Step back) |
| `skip-end.png` | a bar and a right triangle (Step) |
| `refresh.png` | a circular arrow (reload) |
| `trash.png` | a bin (delete) |
| `copy.png` | two sheets (duplicate) |
| `eye.png` | an open eye (visible) |
| `eye-off.png` | a closed eye (hidden) |
| `warning.png` | a triangle with an exclamation (the warning level) |
| `info.png` | a circle with an "i" (the info level) |
| `error.png` | a circle with an X (the error level) |
| `success.png` | a circle with a tick (the success level) |
| `lock.png` | a padlock |
| `dot.png` | a small filled circle (the unsaved marker) |
| `dots.png` | three dots (the overflow menu) |
| `undo.png` | an arrow curving left |
| `redo.png` | an arrow curving right |
| `save.png` | a floppy disk |
| `grid.png` | a grid (the grid toggle) |
| `list.png` | three lines (the list view) |
| `camera.png` | a camera (the Scene tab) |
| `layers.png` | stacked diamonds (the layers) |
| `link.png` | a chain (linked) |
| `unlink.png` | a broken chain (unlinked) |
| `drag.png` | a six-dot handle (drag) |

### The panels (the tab and dock icons)

| File | What it is |
|---|---|
| `panel-hierarchy.png` | a tree |
| `panel-inspector.png` | a slider panel |
| `panel-assets.png` | a folder grid |
| `panel-console.png` | a terminal prompt |
| `panel-tilemap.png` | a brick wall |

## How the engine will use them

The plan (it is not implemented yet — the drawn icons are the fallback):

1. `engine/ui/icons.zig` grows a loader: at boot it looks for
   `assets/icons/<name>.png` and packs the ones it finds into the same atlas
   the sprites use.
2. `ui.icons.render` draws the atlas cell when the icon has one, and the
   drawn geometry when it does not. **A missing file is never an error** — it
   is the drawn icon, and the editor looks exactly as it does today.
3. A file that is present but corrupt is a WARNING in the console, not a
   crash: a broken icon must not take the editor down.

So: download what you want, drop the files in this folder, and the editor
picks them up. Nothing has to be registered by hand.

## The priority order

If you only do a few, do these first — they are the ones the drawn geometry
cannot do justice to:

1. `cursor.png`, `move.png`, `rotate.png`, `scale.png`, `tiles.png` — the
   viewport's tools, on the toolbar you use every day.
2. `panel-hierarchy.png`, `panel-inspector.png`, `panel-assets.png`,
   `panel-console.png` — the dock headers.
3. The rest, as you feel like it.
