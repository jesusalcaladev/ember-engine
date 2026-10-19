# The Editor Viewport

**Sources:** `src/tools/editor/viewport.zig`, `src/tools/editor/shell.zig`, `src/engine/ecs/camera.zig`

The viewport is the editor's window onto the scene: a camera, a grid, picking,
and the gizmo. It is the part of the editor the user looks at most, and it is
the part that had the most wrong in it.

## The region

The viewport is a RECTANGLE in the editor window, not the whole window. The
hierarchy is on the left, the inspector on the right, the console at the
bottom, and the scene is what is left over.

```zig
pub const Region = struct {
    x: f32 = 0,
    y: f32 = 0,
    w: f32 = 1,
    h: f32 = 1,

    pub fn contains(self: Region, p: Vec2) bool { ... }
};
```

The shell's layout computes it once a frame (`editor_shell.layout`), and the
viewport uses it for four things that have to agree:

| What | Where |
|---|---|
| The camera's size and where it sits in the render target | `Viewport.cameraView` → `ecs.camera.View.setTarget` |
| Where the pointer is measured from | `Viewport.localPoint`, `View.targetToWorld` |
| What the culler culls against | `main.zig`'s `render2d.ViewRect.around` |
| What the gizmo is clipped to | `Viewport.drawOverlay` |

A viewport that is not a region has a camera that frames the window: the
middle of the viewport is off-centre, the scene sits under the docks, and half
of what the camera shows is hidden.

## The two axes

The **world is y-up** (Box2D's convention, and the renderer's: a larger world
y is drawn HIGHER). The **screen is y-down** (the framebuffer's convention,
and the mouse's).

`ecs.camera.View` is the ONE place the two meet:

```zig
pub fn worldToScreen(self: View, world: Vec2) Vec2 {
    const half = self.halfExtents();
    return .{
        .x = (world.x - (self.cx - half.x)) * self.zoom,
        .y = ((self.cy + half.y) - world.y) * self.zoom,   // <- the flip
    };
}
```

It used to be the other way round: the renderer drew the world y-up while
`screenToWorld` read the screen y-down, so every click in the editor landed
mirrored across the horizontal midline of the viewport. The scene looked
right and the picking did not. The convention is pinned by tests in
`src/engine/ecs/camera.zig`, including one that checks the projection
matrix against the CPU's mapping — the matrix is what the GPU does, the
mapping is what the pointer does, and they must land on the same pixel.

## The gizmo

Three verbs, three keys, one selection:

| Mode | Key | Handles |
|---|---|---|
| **Move** | `W` | the object itself (a free move) and the two local-axis arrows |
| **Rotate** | `E` | a ring around the object, with a knob |
| **Scale** | `R` | the four corners, and the centre handle for a uniform scale |

**The arrows follow the object's own axes.** A rotated object moves along the
arrow the user is holding, and the drag is a DELTA from the grab point, so the
object keeps the point of itself that was clicked.

**The handles are drawn with ImGui's draw list**, on the BACKGROUND list, and
clipped to the region. Not with the 2D batcher: a `SpriteInstance` is a
centre and two half extents, so a selection outline that follows the
object's rotation, an arrow along a rotated axis and a rotation ring are all
impossible with it. The background list is drawn after the scene (the editor
overlay is one pass over the resolved frame) and before the windows, so the
gizmo is over the scene and under the panels — the layer it belongs to.

**Snapping.** `Ctrl` snaps a move to the grid cell that is DRAWN (so what you
snap to is exactly what you see), a rotation to 15°, and a scale to 0.1.
`Shift` makes a scale uniform.

## The HUD

A strip along the top-left of the region: the tools (Cursor / Tiles), the
gizmo modes, the grid and snap toggles, the zoom and the pointer's world
position. It is a real ImGui window, so its buttons are real buttons — and
it takes the pointer over itself, which is the point of a HUD.

It lives INSIDE the region on purpose. The old tool pill floated over the
inspector, which is where a tool has no business being.

## Frame all

The editor opens framed on the content (`Viewport.frameAll`): the zoom that
shows everything, centred on the middle of it. A viewport that opens on the
origin of a world whose content is 600 units away opens EMPTY, and an empty
viewport reads as a broken one.

A RESIZE re-frames too, while the camera is still the editor's: the
compositor resizes the window right after it opens, and a framing computed
for the old size is a framing for a window that is not there any more. The
moment the user pans or zooms, the view is THEIRS and a resize leaves it
alone (`camera_touched`).

## Picking

Only entities that have a `Sprite` are pickable, and the sprite's scaled size
is the bounding box — rendering and picking can then never disagree about
what is under the pointer. Priority is the sprite's render layer, then its
stable `order`, then slot order: what you see on top is what you pick. The
current selection's handles beat everything else within a few pixels.

## The selection is a set, and the current object is one of them

Two things, because they are two different things:

- **the SET** — what is selected. It lives in the session model
  (`model.selected()`), which has had one since M1; the editor was keeping a
  second, single-entity selection of its own, which is worse than no
  multi-select at all.
- **the CURRENT object** — the one the inspector binds to. It is the editor's
  `selection`, and it is always one of the set (or nothing).

| Gesture | What it does |
|---|---|
| Click an entity | Replaces the selection; the entity becomes current |
| Ctrl+click an entity | Adds to the selection; the entity becomes current |
| Drag on empty space | The marquee: it catches everything the box TOUCHES and replaces the selection |
| Click on empty space | Clears the selection |

The marquee clears the selection on the RELEASE, not on the press: a press
that turns into a drag must not have cleared the selection on the way, or a
drag to select four things would deselect first and reselect second, and the
undo would show it.

The box TOUCHES an entity rather than containing it — a marquee that only
caught the entities it fully swallowed would be useless on small sprites.

The gizmo edits the CURRENT object alone. A group transform (one gizmo
moving the whole selection) is the next piece, and it is not done: pretending
it is would mean dragging one object out of a selection of four and
watching the other three stay behind.

## The camera's own maths

`ecs.camera.View` also knows how to place itself inside a render target:

```zig
var v = View{ .cx = 0, .cy = 0, .zoom = 1, .viewport_w = 1000, .viewport_h = 700 };
v.setTarget(300, 100, 1600, 900);   // the view's top-left, and the target's size
```

`viewProjection()` then projects the world into the TARGET with the view's
rectangle in the right place, so the region shows exactly the camera's view
and the rest of the target (which the docks cover) shows the scene around it.
