# Typed Queries

**Source:** `src/engine/ecs/query.zig`

## Overview

Queries provide typed iteration over archetypes, batch-first. Two access shapes
share the same code path:

- **`nextBatch()`** — one archetype at a time as `[]T` columns: the shape a
  system wants (renderer, physics sync), because the loop body is a plain Zig
  loop over slices the optimizer can vectorize.
- **`next()`** — one entity row at a time: the shape a facade wants
  (`Actor.get`-style logic inside a system).

Cost per iteration step: one mask test (4 word comparisons) and, once per
archetype, the column indices — never per entity. Asking for a component an
entity does not have is impossible by construction.

> **Important:** Batches borrow the world's tables. Spawning, despawning, or
> adding a component (which may create an archetype) invalidates them. Do
> structural work first, or buffer handles in the frame arena and apply after
> the loop.

## Type Definition

```zig
pub fn Query(comptime WorldT: type, comptime with: anytype, comptime without: anytype) type
```

Comptime generic that produces a query type for the given world type, required
component tuple, and excluded component tuple.

| Parameter | Type | Description |
|---|---|---|
| `WorldT` | `type` | The world type to query. |
| `with` | `anytype` | Tuple of required component types. |
| `without` | `anytype` | Tuple of excluded component types. |

## Query Struct Fields

| Field | Type | Description |
|---|---|---|
| `world` | `*WorldT` | The world being queried. |
| `required` | `Mask` | Comptime constant: bitmask of required components. |
| `excluded` | `Mask` | Comptime constant: bitmask of excluded components. |
| `arch_index` | `usize` | Next archetype to consider. |
| `current` | `?*Archetype` | Current archetype cursor. |
| `row` | `usize` | Current row within the archetype. |
| `cols` | `[with_count]u16` | Column index of each requested type inside `current`. |

## Batch Iteration

### `Batch` (returned by `nextBatch`)

```zig
pub const Batch = struct {
	arch: *const Archetype,
	cols: [with_count]u16,
	// ...
};
```

One archetype worth of rows. Valid until the underlying tables grow.

| Method | Signature | Description |
|---|---|---|
| `len` | `fn(self: Batch) usize` | Number of entities in this archetype. |
| `slice` | `fn(self: Batch, comptime T: type) []T` | Typed column for `T`: a dense slice, no per-element checks. |
| `entitySlice` | `fn(self: Batch) []Entity` | Entities of this archetype, parallel to every column. |
| `entityAt` | `fn(self: Batch, row: usize) Entity` | Entity at a specific row index. |

### `nextBatch`

```zig
pub fn nextBatch(self: *Self) ?Batch
```

Advances to the next matching archetype.

**Returns:** A `Batch` for the next matching archetype, or `null` when all
matching archetypes have been visited.

## Per-Entity Iteration

### `Row` (returned by `next`)

```zig
pub const Row = struct {
	arch: *const Archetype,
	cols: [with_count]u16,
	row: usize,
	// ...
};
```

One entity row within an archetype.

| Method | Signature | Description |
|---|---|---|
| `entity` | `fn(self: *const Row) Entity` | The entity handle at this row. |
| `get` | `fn(self: *const Row, comptime T: type) *T` | Typed pointer to a component column cell. |

### `next`

```zig
pub fn next(self: *Self) ?Row
```

One entity row at a time; systems that can should use `nextBatch` instead.

**Returns:** A `Row` for the next matching entity, or `null` when iteration is
complete.

## Usage Examples

### Batch-first (recommended for systems)

```zig
const std = @import("std");
const world_mod = @import("world.zig");
const components = @import("components.zig");
const Query = @import("query.zig").Query;

var world = world_mod.World.init(allocator);
defer world.deinit();

// ... spawn entities ...

var q = world.query(.{ components.Transform, components.Sprite });
while (q.nextBatch()) |batch| {
	const transforms = batch.slice(components.Transform);
	const sprites = batch.slice(components.Sprite);
	const entities = batch.entitySlice();

	for (transforms, sprites, entities) |*tr, spr, e| {
		// Plain Zig loop over slices: vectorizable, cache-friendly.
		_ = tr;
		_ = spr;
		_ = e;
	}
}
```

### With exclusion filter

```zig
// All entities with Transform but WITHOUT Velocity
var q = world.query(.{ components.Transform }, .{ components.Velocity });
while (q.nextBatch()) |batch| {
	const transforms = batch.slice(components.Transform);
	for (transforms) |*tr| {
		// Only kinematic or static entities here.
		_ = tr;
	}
}
```

### Per-entity (facade-style)

```zig
var q = world.query(.{ components.Transform, components.Sprite });
while (q.next()) |row| {
	const e = row.entity();
	const transform = row.get(components.Transform);
	const sprite = row.get(components.Sprite);
	// Process one entity at a time.
	_ = e;
	_ = transform;
	_ = sprite;
}
```

## Performance Characteristics

| Operation | Cost |
|---|---|
| Archetype mask test | 4 word comparisons (O(1)) |
| Column index lookup | Once per archetype (not per entity) |
| Batch slice access | Direct pointer, no bounds check |
| Row `get()` | Pointer arithmetic, no branch |

## Implementation Notes

- **Comptime masks**: `required` and `excluded` are comptime constants per call
  site, so the mask test is inlined and branch-predicted.
- **Column indices**: Resolved once per archetype in `nextBatch()`, stored in
  `cols[]` for the duration of that batch.
- **No per-entity checks**: The archetype guarantees every entity has exactly
  the requested components, so there are no per-element branches.
- **Invalidation**: The `arch_index` cursor means a query can be resumed after
  structural changes, but previously returned batches are invalidated.
