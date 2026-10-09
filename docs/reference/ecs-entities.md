# Entity Handles

**Source:** `src/engine/ecs/entity.zig`

## Overview

Entity handles are 64-bit values that pair a 32-bit **index** (locating a slot in
the world) with a 32-bit **generation** (proving the slot still belongs to the
handle's owner). This design eliminates use-after-free entirely: every time a slot
is freed, its generation is bumped, so an old handle can never alias a new
occupant.

Key properties:

- Handles are **values**: copyable, hashable, usable as map keys.
- Scene identity (stable across save/load) is the separate `SceneId` — handles are
  volatile by design.
- The generation counter ensures **no use-after-free, ever**.

## Types

### `Entity`

```zig
pub const Entity = extern struct {
	index: u32 = 0,
	generation: u32 = 0,
	// ...
};
```

A 64-bit handle packing the slot index (low 32 bits) and generation (high 32 bits).

#### Fields

| Field | Type | Description |
|---|---|---|
| `index` | `u32` | Slot index in the world's entity array. |
| `generation` | `u32` | Generation counter; incremented each time the slot is recycled. |

### `SceneId`

```zig
pub const SceneId = u64;
```

Stable scene identity of a slot. Survives save/load because `.zson` writes the
id, not the volatile handle. `0` means "none" (no parent, no prefab origin); ids
start at 1.

## Constants

### `Entity.invalid`

```zig
pub const invalid: Entity = .{ .index = std.math.maxInt(u32), .generation = 0 };
```

Sentinel for "no entity" (parent-less, missing target, etc.). The maximum index
can never be a live slot because slots are appended, never sparse, and the
allocator is far from 4 billion entity ids.

## Methods

### `isInvalid`

```zig
pub fn isInvalid(self: Entity) bool
```

Returns `true` if this handle is the `invalid` sentinel.

| Parameter | Type | Description |
|---|---|---|
| `self` | `Entity` | The handle to check. |

**Returns:** `true` if `self.index == invalid.index`.

### `eql`

```zig
pub fn eql(self: Entity, other: Entity) bool
```

Structural equality: both index and generation must match.

| Parameter | Type | Description |
|---|---|---|
| `self` | `Entity` | First handle. |
| `other` | `Entity` | Second handle. |

**Returns:** `true` if both handles refer to the same slot owned by the same
generation.

### `bits`

```zig
pub fn bits(self: Entity) u64
```

Packs the handle into a single `u64` key suitable for hash maps and slot
dictionaries.

| Parameter | Type | Description |
|---|---|---|
| `self` | `Entity` | The handle to pack. |

**Returns:** `u64` with `index` in the low 32 bits and `generation` in the high
32 bits.

### `hash`

```zig
pub fn hash(self: Entity) u64
```

Wyhash of the packed bits, for use in hash-based containers.

| Parameter | Type | Description |
|---|---|---|
| `self` | `Entity` | The handle to hash. |

**Returns:** A `u64` hash value with good bucket spread for sequential handles.

## Usage Examples

```zig
const std = @import("std");
const entity = @import("entity.zig");

// The invalid sentinel
const nothing = entity.Entity.invalid;
std.debug.assert(nothing.isInvalid());

// Comparing handles
const a = entity.Entity{ .index = 1, .generation = 2 };
const b = entity.Entity{ .index = 1, .generation = 2 };
const c = entity.Entity{ .index = 1, .generation = 3 };
std.debug.assert(a.eql(b));
std.debug.assert(!a.eql(c)); // different generation

// Using as a hash map key
var map = std.AutoHashMap(entity.Entity, u32).init(allocator);
try map.put(a, 42);
std.debug.assert(map.get(a).? == 42);
```

## Design Notes

- **No use-after-free**: When an entity is despawned, the slot's generation is
  incremented. Any stale handle carrying the old generation will fail equality
  checks and validity tests — it can never accidentally reference the new
  occupant.
- **Handles are volatile**: They are process-local indices. For persistence, use
  `SceneId` which the world maintains per slot and which `.zson` serializes.
- **Hash quality**: The `hash()` method uses Wyhash over the packed bits,
  providing good distribution even for sequential entity indices (verified by
  test: 32 sequential handles spread across 8 buckets with no empty bucket).
