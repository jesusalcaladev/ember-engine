# ZSON Serialization

**Source:** `src/engine/ecs/zson.zig`

## Overview

`.zson` is a bit-exact text format for scene serialization, and the foundation
for prefabs with overrides and a canonical state hash.

### Grammar

One document = one scene or one prefab:

```
zson 1
entity 3 {                       // tag: scene id (saved scenes) or a name (prefabs)
  Name "player"                  // components in registry order, one per line
  Transform { position: { x: 0, y: 0 }, rotation: 0, scale: { x: 1, y: 1 } }
  Parent { parent: 1 }           // entity references by tag
}
```

### Design Rationale

- **Text, diffable, canonical.** Two identical worlds (same spawn order, same
  values) produce byte-identical documents: entities in slot order, components in
  registry order, fields in declaration order. That is what makes the hash test,
  undo/redo, and Play-in-editor snapshots possible.
- **Floats round-trip exactly.** `{d}` formatting plus `parseFloat` inverts bit
  for bit, so the hash of a reloaded world equals the original one.
- **Entity references are tags**, never volatile handles: a scene writes scene
  ids (stable by construction), a prefab writes human names.
- **Loading is two-pass.** First pass: structure (tags, component identities).
  Second pass: values, by which point every referenced entity already exists. A
  child may therefore reference its parent regardless of the order the file
  happens to use.

### Prefabs and Overrides

Prefabs and overrides are the same decoder in a different mode: decoding a
component patches the value it already has, so a document that omits a field
keeps the target's value. `zson.apply` instantiates or patches by `Name`, which
is how a scene overrides one field of one prefab instance without duplicating
the rest.

## Errors

```zig
pub const Error = error{
	Malformed,           // Syntax error in the document
	UnknownComponent,    // Component name not in the registry (skipped with warning)
	UnknownField,        // Field name not in the component struct
	DuplicateTag,        // Duplicate entity tag
	UnsupportedValue,    // Value type not encodable
};
```

## Constants

| Constant | Type | Value | Description |
|---|---|---|---|
| `version` | `u32` | 1 | Document version. Bump on incompatible format changes. |

## Encoding

### `encode`

```zig
pub fn encode(world: *World, w: *Writer) !void
```

Writes the canonical text form of a whole world to the given writer.

| Parameter | Type | Description |
|---|---|---|
| `world` | `*World` | The world to encode. |
| `w` | `*Writer` | Output writer. |

### `encodeToString`

```zig
pub fn encodeToString(world: *World, allocator: Allocator) ![]u8
```

Convenience: the document as freshly allocated bytes.

| Parameter | Type | Description |
|---|---|---|
| `world` | `*World` | The world to encode. |
| `allocator` | `Allocator` | Allocator for the output buffer. |

**Returns:** The encoded document as a byte slice (caller frees).

### `hash`

```zig
pub fn hash(world: *World) u64
```

Canonical hash of the world state. Equals the hash of the reloaded world by
construction: identical bytes in, identical bytes out, and nothing volatile is
ever encoded.

Hashes without materializing the document: the writer drains into the hasher as
it goes.

**Returns:** A `u64` hash value.

## Decoding

### `decode`

```zig
pub fn decode(allocator: Allocator, text: []const u8) !World
```

Loads a full document into a fresh world: slots and archetypes are rebuilt and
scene ids are exactly the ones written in the text.

| Parameter | Type | Description |
|---|---|---|
| `allocator` | `Allocator` | Allocator for the new world. |
| `text` | `[]const u8` | The document text. |

**Returns:** A new `World` with the loaded entities.

**Errors:** `Error.Malformed`, `Error.DanglingReference`, etc.

### `apply`

```zig
pub fn apply(world: *World, text: []const u8) !void
```

Applies a prefab document, or a scene override, onto an existing world:

- Entities are matched by their `Name`. A name that does not exist yet is
  spawned, so the same document both instantiates and patches.
- A component the target already has is *patched*: only the fields present in
  the document are overwritten, the rest keep their current values.
- A component the target lacks is added with the document's fields over the
  registry defaults.

| Parameter | Type | Description |
|---|---|---|
| `world` | `*World` | The world to patch. |
| `text` | `[]const u8` | The prefab or override document. |

## Entity References

Documents reference entities by tag, never by volatile handle:

- **Numeric tags** are scene ids (saved scenes). `Parent { parent: 2 }` means
  "the entity whose scene id is 2".
- **Word tags** are names (prefabs). `Parent { parent: hero }` means "the entity
  named 'hero'".

Resolution order in `Tags.resolve()`:

1. If the tag is numeric: look up the scene-id index (O(1) hash map), fall back
   to a linear world scan.
2. If the tag is a word: look up the document-local tag map.
3. If neither resolves: `error.DanglingReference`.

## Two-Pass Loading

### Pass 1: Structure

Every entity is created before any reference is resolved. The archetype for each
record is determined by its sorted component ids, and the entity is assigned the
scene id from the tag (if numeric).

### Pass 2: Values

Component values are decoded with the tag map complete. For each component block:

- **Decode mode**: `writeDefault()` fills the column with defaults, then the
  document's fields overwrite them. Absent fields keep defaults.
- **Patch mode** (in `apply`): the existing component value is patched in
  place; absent fields keep their current values.

## Float Round-Trip

Floats are formatted with `{d}` and parsed with a fast path
(`parseDecimalFloat`) that is bit-exact for decimal-representable values:

- The mantissa must be exactly representable in the float type.
- The exponent must be small enough that `10^k` is exact.
- IEEE division is correctly rounded on the exact quotient, giving the same
  float the decimal stands for.

Anything the fast path does not fully understand (exponent notation, too many
digits, hex) falls back to `std.fmt.parseFloat` — exactness is never traded for
speed.

## Usage Examples

### Save and Load

```zig
const std = @import("std");
const zson = @import("zson.zig");
const components = @import("components.zig");

var world = world_mod.World.init(allocator);
defer world.deinit();

const player = try world.spawn(.{
	components.Name.init("player"),
	components.Transform{
		.position = .{ .x = 12.5, .y = -3.25 },
		.rotation = 0.5,
	},
});

// Save
const text = try zson.encodeToString(&world, allocator);
defer allocator.free(text);

// Load
var loaded = try zson.decode(allocator, text);
defer loaded.deinit();

// Hash stability
std.debug.assert(zson.hash(&world) == zson.hash(&loaded));
```

### Prefab Instantiation and Override

```zig
const prefab =
	\\zson 1
	\\entity enemy {
	\\  Name "enemy"
	\\  Transform { position: { x: 0, y: 0 }, rotation: 0, scale: { x: 1, y: 1 } }
	\\  Velocity { linear: { x: 3, y: 0 }, angular: 0 }
	\\}
;

var world = world_mod.World.init(allocator);
defer world.deinit();

// Instantiate
try zson.apply(&world, prefab);
const enemy = world.findByName("enemy").?;

// Override a single field
const override_text =
	\\zson 1
	\\entity enemy {
	\\  Transform { position: { x: 100, y: 200 } }
	\\}
;
try zson.apply(&world, override_text);

// Only position changed; rotation, scale, Name, Velocity untouched
const transform = world.get(enemy, components.Transform).?;
std.debug.assert(transform.position.x == 100);
std.debug.assert(transform.position.y == 200);
std.debug.assert(transform.rotation == 0); // untouched
```

### Canonical Hash for Testing

```zig
// The hash of a reloaded world equals the original.
// This is the property that makes undo/redo and Play-in-editor snapshots
// bit-exact.
const hash_before = zson.hash(&world);
const text = try zson.encodeToString(&world, allocator);
var reloaded = try zson.decode(allocator, text);
std.debug.assert(zson.hash(&reloaded) == hash_before);
```

## Performance Notes

- **Scene-id index**: A hash map (`SceneIndex`) provides O(1) lookup for entity
  references, avoiding O(n^2) loading for scenes with many references.
- **Fast float parsing**: ~200 ns to ~10 ns per float, which is most of load
  time for value-heavy scenes.
- **Two-pass loading**: Separating structure from values allows forward
  references (a child referencing a parent declared later in the file).
- **Stack buffer**: Component decoding uses a stack buffer of `max_stride` (128
  bytes) for the "replace" baseline, avoiding allocation during load.
