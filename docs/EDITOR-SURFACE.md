# The editor surface this engine must expose

For whoever is building the editor. This is a list of what Ember already has,
what it deliberately does not have, and what it will need — so the editor is
not built against a wishlist.

## The shape of the API

Everything the editor does goes through **Lua bindings**, not through a
separate editor API. That is deliberate: one surface, tested by the same
acceptance suite that tests gameplay, and the editor gets the metadata
registry (`meta/ember.lua`) generated for it for free.

Three layers, and knowing which one to reach for saves a lot of time:

| Layer | What it is | Use it for |
|---|---|---|
| `actor.add_component` / `has_component` / `remove_component` | generic, by name | anything you have not thought of yet |
| typed setters (`sprite.set_size`, `sprite.get_tint`, …) | one per field | the inspector's field list |
| `meta/ember.lua` | generated from `metadata.zig` | discovering what exists |

**Do not build a `set_field(name, value)`.** It is a stringly-typed lookup in
the frame loop and it gives an editor no way to know what a component
contains. The typed layer exists for exactly that reason, and it is generated
from the same place the docs come from.

## What exists today

### Actors and components
```lua
actor.add_component(self, "Sprite")          -> false if already there or unknown
actor.has_component(self, "Sprite")          -> boolean
actor.remove_component(self, "Sprite")       -> refuses on Transform
```
Unknown component names return `false` rather than failing loudly — but that
is a **bug in your tool**, and worth surfacing in the inspector's console.

### Sprites — including Godot-style primitives, so grey boxes are a real first step
```lua
sprite.rect(self, w, h, r, g, b, a)          -- no texture needed
sprite.circle(self, diameter, r, g, b, a)    -- a real circle, masked in the shader
sprite.texture(self, w, h, slot, u0,v0,u1,v1)
sprite.set_size / set_tint / set_uv / set_atlas / set_shape / set_blend
sprite.set_layer(self, n)                    -- draw order, lower first
sprite.set_visible(self, bool)               -- the eye toggle
sprite.get_size(self) -> w, h
sprite.get_tint(self) -> r, g, b, a
```
A prototype drawn with `sprite.rect` and one drawn with real art are **the same
object afterwards**. `sprite.texture` is a separate function rather than a flag
so a scene full of `sprite.rect` calls has an obvious list to replace.

### Shader materials
```lua
material.new(self, shader)                   -- 0 is the stock sprite shader
material.set_params(self, p0, p1, p2, p3)    -- four floats, deliberately
material.get_params(self) -> p0, p1, p2, p3
material.get_shader(self) -> number
```
Four floats is the whole uniform surface. That is a **hook**, not a shader
system: a wider block needs a std140 layout and turns this into a different
project. An unknown shader index **falls back** to the stock sprite shader — a
scene referencing a shader the build lacks must still render, the same way a
missing texture falls back to white.

### Physics — place, resize, retune, select
```lua
physics.create_shape(self, kind, hw, hh)     -- 0 box 1 circle 2 capsule 3 cylinder
physics.reshape(self, kind, hw, hh)          -- drag-resize, safe 60x/second
physics.set_material(self, friction, restitution, density)
physics.set_sensor(self, bool)               -- trigger volume
physics.set_layers(self, layer, mask)        -- bitmasks
physics.set_body_type(self, kind)            -- 0 fixed 1 kinematic 2 dynamic
physics.set_body_enabled(self, bool)         -- the eye toggle
physics.overlap_rect(cx, cy, hw, hh) -> n, actors...   -- drag-select
physics.contains_point(x, y) -> actor                    -- click-select
physics.cast_ray(x1,y1,x2,y2) -> hit, t, px, py, nx, ny
physics.line_of_sight(x1,y1,x2,y2) -> boolean
physics.set_view(cx, cy, hw, hh) / physics.set_focus(x, y)
physics.stats() -> table
```
All of these take an **entity**, not a solver handle — the ECS is the
document, the solver is a cache of it.

`overlap_rect` is **approximate**: Box2D's overlap query returns geometry with
no identity, so selection is a grid of rays. Fine for a drag; not a pixel-exact
test.

### Render
```lua
render.set_view(cx, cy, half_w, half_h)     -- turns on frustum culling
render.stats() -> entities, instances, culled, hidden
render.set_resident(slot, loaded)           -- atlas streaming
render.all_resident()                       -- the default
```
`culled` and `hidden` are reported **separately and that is the point**: a
hidden sprite is a decision somebody made, a culled one is the engine saving
you work. A scene where `culled` is zero is paying to draw a world nobody sees.

## What is NOT there yet

Build against this list as things to request, not things to use.

| Missing | Why it matters for the editor |
|---|---|
| **UI widgets** (button, panel, label, text input) | There is no UI layer at all. M14 (Text+UI) is unstarted. An editor drawn with sprites and no input handling is not an editor. |
| **Viewport / camera control** | `render.set_view` sets the view, but there is no camera object, no zoom, no pan, no viewport stacking. |
| **Undo / redo** | Nothing. This is the single biggest gap for anything that edits a scene, and it is engine work: it needs a command journal or a scene-diff, not editor-local state. |
| **Asset / project management** | No project file, no asset database, no import step, no hot reload of assets on disk. |
| **Prefab / scene instantiation** | `SceneId` exists on the ECS side; there is no binding to instantiate one from another. |
| **File dialogs / paths** | None. The editor will need an IO binding that does not exist. |
| **Docking / panels / tabs** | No UI, so no answer, and the generic component API is the only lever. |
| **Selection state** | There is `physics.overlap_rect` for picking, but no engine-side selection model, no multi-select, no a "current object" the inspector binds to. |
| **Gizmos / handles** | No. `physics.reshape` is the primitive they would drive, but drawing and hitting them is editor work. |
| **Rich text** | M14. `sprite.texture` is the only text you can draw today. |

## Things that will bite you

- **`physics.reshape` and `set_material` rebuild the shape.** That is the only
  way a solver offers to change a shape's dimensions. They preserve the body's
  enabled state, because the solver cannot rebuild a shape that is not in the
  world.
- **`actor.remove_component` refuses `Transform`.** An actor with no transform
  has no position, and everything else assumes it exists.
- **LuaJIT has no `for` as a variable name** and the engine's `math` global
  shadows the stdlib one (and has no `pi`). Both have already cost time.
- **Anything called per frame must not allocate** (spec §3.1). The overlap query
  uses a fixed scratch buffer for this reason and can return more results than
  fit — check the count, grow, re-query.
- **The build needs `libs/bootstrap.sh` to have run** (Box2D, LuaJIT, Dawn). A
  missing one shows up as a missing file at compile time, not as a helpful
  message.

## How to check your work

```sh
zig build test          # 230 tests; 6 crash in LuaJIT under Zig's runner
zig build test-api      # the acceptance suite: 14 checks driving the real API
zig build stubs         # regenerates meta/ember.lua after adding metadata
```

The acceptance suite (`src/engine/script/api_acceptance_test.zig`) is where
every binding is exercised against a real VM and a real physics world. A new
binding that is not in `registered_names` and `metadata.bindings` does not
compile, which is the gate that keeps this file true.