# The tilemap

A tile layer is an actor that carries a `TileMapLayer` component and a grid of
tiles. The grid is the LEVEL: the floor, the walls, the platforms.

```lua
tilemap.set_tile(self, 3, 5, 12)          -- one tile
tilemap.fill_rect(self, 0, 10, 40, 12, 3) -- a floor
tilemap.set_physics_enabled(self, true)    -- and it is solid
```

## Where the tiles live

**Not in the component.** A grid does not fit in a fixed-size record, and a
pointer does not fit in a column (the registry forbids both). So:

| | |
|---|---|
| The component (`TileMapLayer`) | the RECIPE: the tile set, the render layer, the measurements, the path of the data |
| The tile store (the ECS layer) | the TILES: the chunks, the grid, the dirty bits |

The store is the **one copy**: the renderer, the physics and the script layer
read the same tiles. A copy in each of them is three copies that drift.

## The pieces

| | |
|---|---|
| The component | `src/engine/ecs/components/tilemap.zig` — the measurements (the tile size ✓, the atlas page ✓, the tiles per row ✓) and the data's path ✓ |
| The store | `src/engine/ecs/tilemap.zig` — the chunks (16x16 tiles ✓), the chunk map ✓, the free list ✓, the per-tile dirty bits ✓ and the per-chunk VERSION ✓ |
| The renderer | `src/engine/render/tilemap.zig` — the chunks to instances ✓, one draw call per (atlas, layer) ✓ |
| The colliders | `src/engine/physics/tilemap.zig` — one static body per chunk ✓, one box shape per solid tile ✓ |
| The data | `src/engine/assets/tilemap_data.zig` — the `.tilemap` decoder ✓ |

## The level file

The tiles are not in the scene ✓ — the scene says WHICH map a layer is ✓ (a
path ✓) and the map's data is an asset ✓ (a `.tilemap` file ✓):

```
tilemap 1
tileset asset_0123456789abcdef
tile 0 0 1
tile 1 0 2 flipx
```

**Text and not binary** ✓: a level is a thing people edit ✓, diff ✓ and
argue about ✓, and a file that cannot be read without the engine is a file
nobody can fix ✓.

## The colliders

One **static body per chunk** ✓, with one box shape per solid tile ✓. A body
per tile would be 256 bodies per chunk ✓ and the solver's broadphase would see
256 times more ✓.

Only the chunks that changed are rebuilt ✓ — the chunk's VERSION says whether
anything changed ✓, and the dirty BITS say which tile changed ✓ (the
renderer's question ✓). Two consumers cannot share one set of dirty bits ✓:
whoever cleared them last would starve the other ✓.

A rebuild drops the body and makes a new one ✓: a body carries its shapes ✓
and a shape cannot be resized ✓.

## What is not there yet

- **The tile set's DATA is not read yet.** The assets' `TileSet` decode is
  still parked ✓, so the tiles are SOLID BOXES ✓: there are no per-tile
  shapes ✓, no one-way platforms ✓ and no autotiling ✓ yet.
- **The editor's panel paints its own store**, not the world's ✗ — so what
  the editor paints is not what the game plays ✗. That is the next piece ✓.
- **The tiles do not save with a `save.save`** ✗: a save is the world ✓, and
  the tiles are in the store ✓, not in the world ✗.
