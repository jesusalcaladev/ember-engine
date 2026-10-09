# Hierarchy System

**Source:** `src/engine/ecs/hierarchy.zig`

## Overview

The hierarchy system resolves parent chains by a flat, iterative algorithm (no
recursion). The engine stores exactly one fact per entity (`Parent.parent`);
everything else is *derived*, once per frame, in memory laid out for that:

1. Every entity with a `Transform` seeds its world transform from its local one.
2. Parent links become a CSR adjacency (children grouped by parent) built in two
   linear passes: count, prefix-sum, fill.
3. A queue walks the forest breadth-first, folding each child into its parent's
   world transform.

No recursion (a 10k-deep chain cannot blow the stack), no per-frame allocation,
no scanning: O(entities).

### Why Not Store World Transforms?

Storing a world transform per entity would be a second copy of the authoritative
state, needing a structural change (and a spike) every time a parent link changed.
Deriving keeps `.zson` documents minimal and bit-exact, and keeps hierarchy
edits free of archetype churn.

### Cycle Handling

Cycles (a parent of its own descendant) and dead parents are not errors: the
link is ignored for that pass, which is also what the debug log warns about.

## Types

### `WorldTransform`

```zig
pub const WorldTransform = struct {
	position: core_math.Vec2,
	rotation: f32 = 0,
	scale: core_math.Vec2,
	// ...
};
```

Composed transform in world space. Renderers read this, never the local one.

| Field | Type | Default | Description |
|---|---|---|---|
| `position` | `Vec2` | `(0, 0)` | World-space position. |
| `rotation` | `f32` | `0` | World-space rotation in radians. |
| `scale` | `Vec2` | `(1, 1)` | World-space scale. |

#### `WorldTransform.identity`

```zig
pub const identity = WorldTransform{
	.position = .{ .x = 0, .y = 0 },
	.rotation = 0,
	.scale = .{ .x = 1, .y = 1 },
};
```

Identity transform (used when an entity has no transform or the slot is out of
range).

## `Hierarchy` Struct

```zig
pub const Hierarchy = struct {
	enabled: bool = false,
	capacity: usize = 0,
	world: []WorldTransform = &.{},
	starts: []u32 = &.{},
	fill: []u32 = &.{},
	children: []u32 = &.{},
	queue: []u32 = &.{},
	child_stamp: []u32 = &.{},
	parent_stamp: []u32 = &.{},
	stamp_now: u32 = 0,
	last_resolved: usize = 0,
	// ...
};
```

### Fields

| Field | Type | Description |
|---|---|---|
| `enabled` | `bool` | Whether hierarchy resolution is active. |
| `capacity` | `usize` | Number of slots the arrays can index. |
| `world` | `[]WorldTransform` | Derived world transform per slot index. |
| `starts` | `[]u32` | CSR prefix sums: children of `p` live in `children[starts[p+1]..starts[p]]`. |
| `fill` | `[]u32` | Fill cursors while building the CSR (copy of `starts`). |
| `children` | `[]u32` | CSR child indices, grouped by parent. |
| `queue` | `[]u32` | Breadth-first queue over slot indices. |
| `child_stamp` | `[]u32` | Stamped "this slot is somebody's child this pass" (O(1) reset). |
| `parent_stamp` | `[]u32` | Stamped "this slot's child count is initialised this pass". |
| `stamp_now` | `u32` | Current stamp value for O(1) pass reset. |
| `last_resolved` | `usize` | Statistics for the memory report. |

## Memory Management

### `reserve`

```zig
pub fn reserve(self: *Self, allocator: std.mem.Allocator, capacity: usize) !void
```

Allocates every scratch array for `capacity` slots. Called from
`World.enableHierarchy`/`reserveEntities` — outside the frame.

| Parameter | Type | Description |
|---|---|---|
| `allocator` | `std.mem.Allocator` | Allocator for the scratch arrays. |
| `capacity` | `usize` | Number of slots to allocate for. |

### `release`

```zig
pub fn release(self: *Self, allocator: std.mem.Allocator) void
```

Frees the scratch but keeps `enabled`: that is opt-in state, not memory.

### `deinit`

```zig
pub fn deinit(self: *Self, allocator: std.mem.Allocator) void
```

Releases all scratch memory. Does not change `enabled`.

## Resolution

### `resolve`

```zig
pub fn resolve(self: *Self, world: anytype) void
```

Resolves every parent chain in the world. Flat, iterative, allocation-free.
Expects the scratch to be reserved (see `World.enableHierarchy`).

The `world` parameter is duck-typed to avoid a dependency cycle with `world.zig`.

**Algorithm:**

1. **Pass reset**: bump `stamp_now` for O(1) invalidation of previous pass
   stamps.
2. **Seed locals**: for every entity with `Transform`, copy local transform to
   `world[index]`.
3. **Count children**: query `Parent+Transform`, count children per parent, mark
   children with `child_stamp`.
4. **Prefix sums**: descending prefix sum over `starts[]` to build CSR
   boundaries.
5. **Fill CSR**: second pass over `Parent+Transform` populates `children[]`
   using `fill[]` cursors.
6. **Find roots**: entities with `Transform` not stamped as children go into the
   BFS queue.
7. **BFS fold**: walk the queue breadth-first, composing each child's world
   transform from its parent's finished world transform via `fold()`.

### `at`

```zig
pub fn at(self: *const Self, index: usize) WorldTransform
```

World transform of a slot index.

| Parameter | Type | Description |
|---|---|---|
| `index` | `usize` | Slot index. |

**Returns:** The `WorldTransform` at that slot, or `identity` if out of range.

### `worldOf`

```zig
pub fn worldOf(self: *const Self, world: anytype, e: Entity) WorldTransform
```

World transform of a live entity (what the renderer asks for).

| Parameter | Type | Description |
|---|---|---|
| `world` | `anytype` | The world (duck-typed). |
| `e` | `Entity` | The entity handle. |

**Returns:** The composed `WorldTransform`, or `identity` if the entity is not
alive.

## Transform Composition

### `fold`

```zig
pub fn fold(parent: WorldTransform, child: WorldTransform) WorldTransform
```

Composes a parent world transform with a child world-so-far (still local on the
first visit) transform. 2D equivalent of `parent_local * child_local`.

| Parameter | Type | Description |
|---|---|---|
| `parent` | `WorldTransform` | Parent's composed world transform. |
| `child` | `WorldTransform` | Child's transform (local on first visit, or already partially composed). |

**Returns:** The composed world transform.

**Math:**
- Rotation: `parent.rotation + child.rotation`
- Scale: component-wise product
- Position: rotate child's offset by parent's rotation, scale by parent's
  scale, then add parent's position

## CSR Layout

The hierarchy uses a Compressed Sparse Row (CSR) adjacency for children:

```
starts[p]       = exclusive end of children of p
starts[p+1]     = first child index of p
children[starts[p+1]..starts[p]] = children of p
starts[capacity] = 0 (zero sentinel)
```

This layout makes the BFS walk trivial: for any parent, its children are a
contiguous slice.

## Usage Examples

```zig
const std = @import("std");
const world_mod = @import("world.zig");
const components = @import("components.zig");
const entity_mod = @import("entity.zig");

const Entity = entity_mod.Entity;

var world = world_mod.World.init(allocator);
defer world.deinit();
try world.enableHierarchy();

// Build a simple tree
const root = try world.spawn(.{
	components.Transform{ .position = .{ .x = 10, .y = 0 } },
});
const child = try world.spawn(.{
	components.Transform{ .position = .{ .x = 0, .y = 5 } },
});
const leaf = try world.spawn(.{
	components.Transform{ .position = .{ .x = 1, .y = 0 } },
});

try world.add(child, components.Parent{ .parent = root });
try world.add(leaf, components.Parent{ .parent = child });

// Resolve the hierarchy (once per frame)
world.hierarchy.resolve(&world);

// Read world transforms
const root_world = world.hierarchy.at(root.index);
const child_world = world.hierarchy.at(child.index);
const leaf_world = world.hierarchy.at(leaf.index);

// root: (10, 0)
// child: (10, 5) = root + child_local
// leaf: (11, 5) = child_world + leaf_local

// Cycle and dead parent: ignored with a debug warning, not an error.
```

## Performance Characteristics

| Operation | Complexity |
|---|---|
| Resolve all | O(entities) |
| `at()` | O(1) |
| `worldOf()` | O(1) |
| Cycle detection | O(entities) (entities not visited in BFS) |
| Memory | 7 arrays of `capacity` elements |

## Debugging

If `last_resolved < transform_count` after `resolve()`, some entities were never
reached — indicating a cycle or orphaned parent chain. The system logs:

```
hierarchy: cycle or orphaned parent in N of M entities
```
