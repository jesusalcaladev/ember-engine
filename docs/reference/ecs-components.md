# Component Registry

**Source:** `src/engine/ecs/components.zig`

## Overview

The component registry is the single comptime source of truth for the ECS. Every
component type is declared in one place (`component_list`), and from that list the
entire ECS derives at comptime:

- Dense `ComponentId`s (registration order, stable for the build)
- The archetype mask type (`Mask`)
- Layout metadata (`stride`, alignment) used by type-erased columns

### Registration Rules

Enforced by compile error, not runtime surprises:

1. **Plain data only**: no pointers, no slices, no unions. Components must be
   copyable so moving an entity between archetypes is a `memcpy` of a fixed
   number of bytes.
2. **Every field has a default**: those defaults are the baseline a `.zson`
   document starts from in "replace" mode, and the baseline an override merges
   into in patch mode.
3. **Explicit registry name**: types are identified by their string name
   ("Transform"), not a mangled path, so the text format and profiler logs are
   independent of module import structure.

Registration is closed on purpose: the ECS is an internal detail and the public
surface is Actor + Components. Adding a component means adding one line to
`component_list`.

## Core Types

### `ComponentId`

```zig
pub const ComponentId = u16;
```

Dense identifier for a component type, assigned in registration order.

### `Mask`

```zig
pub const Mask = std.StaticBitSet(max_components);
```

Component set as a bitmask for fast superset/disjoint tests during queries.

### Constants

| Constant | Type | Description |
|---|---|---|
| `max_components` | `u16` (comptime) | Maximum distinct component types (256). Keeps archetype tests in 4 words. |
| `max_stride` | `u32` (comptime) | Buffer size for decoding any component (128 bytes). |

## Registered Components (10 total)

> Sizes in this document are measured with `@sizeOf` under the current layout and
> pinned by `src/engine/ecs/components_test.zig`, which fails if one of them
> changes. The first version of that test asserted hand-computed sizes and was
> wrong twice over — `Parent` is 8, not 16 (both u32 fields pack into one
> `Entity`), and `RigidBody2D` is 52, not the 56 you get adding the fields up.
> Field reordering by hand is exactly what makes a table like this lie.

### 1. `Name`

```zig
pub const Name = struct {
	bytes: [32]u8 = [_]u8{0} ** 32,
	len: u8 = 0,
	// ...
};
```

Inline name: identity for humans, and the key `.zson` overrides match by. Fixed
size keeps it POD (no allocation, no lifetime, byte-copyable).

| Field | Type | Default | Description |
|---|---|---|---|
| `bytes` | `[32]u8` | all zero | Inline storage for the name. |
| `len` | `u8` | 0 | Current length of the name. |

#### Methods

| Method | Signature | Description |
|---|---|---|
| `init` | `fn(text: []const u8) Name` | Construct from a string. |
| `set` | `fn(self: *Name, text: []const u8) void` | Overwrite (truncates to 32 bytes). |
| `slice` | `fn(self: *const Name) []const u8` | Get the name as a byte slice. |
| `eql` | `fn(self: *const Name, text: []const u8) bool` | Compare against a string. |

### 2. `Transform`

```zig
pub const Transform = struct {
	position: Vec2 = Vec2{},
	rotation: f32 = 0,
	scale: Vec2 = unit,
	prev_position: Vec2 = Vec2{},
	prev_rotation: f32 = 0,
	prev_scale: Vec2 = unit,
	// ...
};
```

Local 2D transform plus the previous fixed-tick snapshot, so the renderer can
interpolate without touching simulation state.

| Field | Type | Default | Description |
|---|---|---|---|
| `position` | `Vec2` | `(0, 0)` | Local position. |
| `rotation` | `f32` | `0` | Rotation in radians. |
| `scale` | `Vec2` | `(1, 1)` | Scale factor. |
| `prev_position` | `Vec2` | `(0, 0)` | Previous tick's position (for interpolation). |
| `prev_rotation` | `f32` | `0` | Previous tick's rotation. |
| `prev_scale` | `Vec2` | `(1, 1)` | Previous tick's scale. |

#### Methods

| Method | Signature | Description |
|---|---|---|
| `capturePrevious` | `fn(self: *Transform) void` | Call at the start of a fixed tick: saves current state as "previous" for the interpolator. |
| `interpolated` | `fn(self: *const Transform, alpha: f32) Transform` | Linear interpolation between previous and current snapshot. |

### 3. `Parent`

```zig
pub const Parent = struct {
	parent: Entity = Entity.invalid,
};
```

Parent link. The hierarchy itself is derived by `hierarchy` (flat, no
recursion); this is the only thing stored per entity.

| Field | Type | Default | Description |
|---|---|---|---|
| `parent` | `Entity` | `invalid` | Entity handle of the parent. `invalid`/dead means "root". |

### 4. `Velocity`

```zig
pub const Velocity = struct {
	linear: Vec2 = Vec2{},
	angular: f32 = 0,
};
```

Linear and angular velocity: plain data the fixed step integrates into
`Transform`. Kept separate so a kinematic actor can move without a transform and
a transform can move without one.

| Field | Type | Default | Description |
|---|---|---|---|
| `linear` | `Vec2` | `(0, 0)` | Linear velocity in world units per second. |
| `angular` | `f32` | `0` | Angular velocity in rad/s (positive clockwise, y down). |

### 5. `Sprite`

```zig
pub const Sprite = struct {
	atlas: u8 = 0,
	layer: u16 = 0,
	size: Vec2 = unit,
	uv: [4]f32 = .{ 0, 0, 1, 1 },
	tint: [4]f32 = .{ 1, 1, 1, 1 },
	order: i32 = 0,
	blend: Blend = .alpha,
	visible: bool = true,
};
```

What to draw for an entity, and how. This is the whole render surface of an
actor: position comes from `Transform`, the appearance from here. Everything is
plain data with defaults, which is what lets `.zson` describe a sprite prefab and
lets the editor override a single field.

| Field | Type | Default | Description |
|---|---|---|---|
| `atlas` | `u8` | `0` | Atlas slot (index into renderer's texture table). Slot 0 is the fallback white texture. |
| `layer` | `u16` | `0` | Render layer. Lower draws first (painter's order). |
| `size` | `Vec2` | `(1, 1)` | Size in world units (Transform's scale multiplies this). |
| `uv` | `[4]f32` | `(0, 0, 1, 1)` | Atlas rect, normalized: (u0, v0, u1, v1). |
| `tint` | `[4]f32` | `(1, 1, 1, 1)` | Tint, multiplied with the texel. |
| `order` | `i32` | `0` | Stable tie-break inside a layer for deterministic ordering. |
| `blend` | `Blend` | `.alpha` | How the sprite is composited. |
| `visible` | `bool` | `true` | Draw nothing for this entity without despawning it. |

#### `Blend` Enum

```zig
pub const Blend = enum(u8) {
	solid = 0,
	alpha = 1,
	additive = 2,
};
```

| Variant | Value | Description |
|---|---|---|
| `solid` | 0 | No blending: fragment overwrites target. Cheapest; only correct choice for solid geometry. |
| `alpha` | 1 | Standard source-over: painter's algorithm for sprites. |
| `additive` | 2 | Source + destination: lights and glows. |

### 6. `Script`

```zig
pub const Script = struct {
	script: u32 = 0,
};
```

The Lua behavior bound to an actor. This is the serializable link: it stores a
*script id* (a stable index into the engine's script cache), never a VM
reference. A Lua registry ref is meaningless across save/load, so `.zson` writes
the id and the runtime re-binds it to the live script on load.

| Field | Type | Default | Description |
|---|---|---|---|
| `script` | `u32` | `0` | Index into the script cache. 0 means "no script" (ids start at 1). |

### 7. `StateMachine`

```zig
pub const StateMachine = struct {
	machine: u32 = 0,
	started: bool = false,
};
```

A link to a state machine defined by Lua. The same component serves every case
(enemy AI, player states, spawners, UI screens, game flow) because the states and
their transitions are script data, not component data.

It is a HANDLE, not the machine itself (a machine holds names and Lua callbacks
which are pointers/slices). The engine owns machines in a side registry and the
component stores the index.

| Field | Type | Default | Description |
|---|---|---|---|
| `machine` | `u32` | `0` | Index into the engine's state-machine registry; 0 is "none". |
| `started` | `bool` | `false` | True once the machine has been entered, so the first tick runs `enter` exactly once. |

### 8. `RigidBody2D`

```zig
pub const RigidBody2D = struct {
	body: u32 = invalid_body,
	generation: u32 = 0,
	body_type: u8 = 2,
	linear_velocity: Vec2 = .{},
	angular_velocity: f32 = 0.0,
	linear_damping: f32 = 0.0,
	angular_damping: f32 = 0.0,
	gravity_scale: f32 = 1.0,
	fixed_rotation: bool = false,
	allow_sleep: bool = true,
	is_bullet: bool = false,
	prev_position: Vec2 = .{},
	prev_rotation: f32 = 0.0,
	tier: u8 = 0,
};
```

A rigid body in the physics world. `body_type` is **one** component with three
kinds (fixed / kinematic / dynamic), not three components: an actor switching
from fixed to kinematic at runtime — a door opening, a platform starting to move —
does not change archetype, so it does not trigger a row move or a spike
(spec §3.1).

The field order is the contract: handles first because they are the hot lookup,
then the plain data. Full documentation in
[physics overview](physics-overview.md).

| Field | Type | Default | Description |
|---|---|---|---|
| `body` | `u32` | `invalid_body` | Port body handle; index into the backend. |
| `generation` | `u32` | `0` | Handle generation: a recycled slot is not mistaken for the body that used to live there. |
| `body_type` | `u8` | `2` | 0 fixed, 1 kinematic, 2 dynamic — mirrors `physics.BodyType`. |
| `linear_velocity` | `Vec2` | `(0, 0)` | Units/second. Gameplay writes this; the solver owns it after the step. |
| `angular_velocity` | `f32` | `0` | Radians/second, positive clockwise (screen space y grows down). |
| `linear_damping` | `f32` | `0` | |
| `angular_damping` | `f32` | `0` | |
| `gravity_scale` | `f32` | `1.0` | Multiplies world gravity. 0 is "unaffected". |
| `fixed_rotation` | `bool` | `false` | Locked rotation — the default for anything that must not tip over. |
| `allow_sleep` | `bool` | `true` | Sleeping is the default, not an opt-in. |
| `is_bullet` | `bool` | `false` | Continuous collision for fast small bodies. |
| `prev_position` | `Vec2` | `(0, 0)` | Previous fixed step, for render interpolation. |
| `prev_rotation` | `f32` | `0` | Previous fixed step rotation. |
| `tier` | `u8` | `0` | Activity tier ordinal (0 = full). Part of the body's state, so it covers the determinism hash. |

#### Methods

| Method | Signature | Description |
|---|---|---|
| `isSimulated` | `fn(self: RigidBody2D) bool` | False when the body is not in a physics world. |

### 9. `Collider2D`

```zig
pub const Collider2D = struct {
	shape: u32 = maxInt(u32),
	generation: u32 = 0,
	kind: u8 = 0,
	size: Vec2 = .{ .x = 0.5, .y = 0.5 },
	offset: Vec2 = .{},
	density: f32 = 1.0,
	friction: f32 = 0.3,
	restitution: f32 = 0.0,
	is_sensor: bool = false,
};
```

A collision shape attached to a body. Separate from `RigidBody2D` so one body can
carry several — a character's torso, head and feet, a platform's surface and its
trigger — each with its own material.

| Field | Type | Default | Description |
|---|---|---|---|
| `shape` | `u32` | `invalid_shape` | Port shape handle. |
| `generation` | `u32` | `0` | Handle generation. |
| `kind` | `u8` | `0` | 0 box, 1 circle, 2 capsule, 3 cylinder, 4 polygon — mirrors `physics.ShapeKind`. |
| `size` | `Vec2` | `(0.5, 0.5)` | Half-extents (box), or x = radius / y = cap offset (capsule). |
| `offset` | `Vec2` | `(0, 0)` | Local offset from the body transform. |
| `density` | `f32` | `1.0` | Mass per unit area for dynamic bodies. |
| `friction` | `f32` | `0.3` | |
| `restitution` | `f32` | `0.0` | 0 = dead stop, 1 = perfectly bouncy. |
| `is_sensor` | `bool` | `false` | Reports overlaps, generates no contact response. |

#### Methods

| Method | Signature | Description |
|---|---|---|
| `isLive` | `fn(self: Collider2D) bool` | False when the shape is not in a physics world. |

### 10. `CollisionLayers`

```zig
pub const CollisionLayers = struct {
	layer: u16 = everything,
	mask: u16 = everything,
};
```

Which layer(s) this body is on, and which it is willing to interact with. Two
bitmasks, four bytes, sixteen named layers. A property of the body, not of one
shape: a character on the `player` layer hits the `enemy` layer with all of its
parts.

| Field | Type | Default | Description |
|---|---|---|---|
| `layer` | `u16` | `everything` | The layer bit(s) this body is on. |
| `mask` | `u16` | `everything` | The layer bit(s) it is willing to interact with. |

The pair test (`A.layer & B.mask` **and** `B.layer & A.mask`) is symmetric and
applies to raycasts as well as collisions. Full documentation in
[collision layers](ecs-collision-layers.md).

#### Constants

| Constant | Value | Description |
|---|---|---|
| `everything` | `maxInt(u16)` | All sixteen bits — the permissive default. |
| `inert` | `CollisionLayers{}` | The zero-effort default: every bit set in both fields, so it collides with everything. Same value as a component that was never written. |

#### Methods

| Method | Signature | Description |
|---|---|---|
| `collides` | `fn(self: CollisionLayers, other: CollisionLayers) bool` | The symmetric pair test. |
| `eql` | `fn(self: CollisionLayers, other: CollisionLayers) bool` | Byte-equal comparison, used by the archetype byte-compare. |

## Registry Lookup Functions

### `componentId`

```zig
pub fn componentId(comptime T: type) ComponentId
```

Returns the dense id of a component type. Unknown type = compile error at the
call site.

### `strideOf`

```zig
pub fn strideOf(id: ComponentId) u32
```

Size in bytes of one element in an archetype column.

### `alignOfPow`

```zig
pub fn alignOfPow(id: ComponentId) u8
```

Component alignment as a power of two (column buffers are allocated with it).

### `nameOf`

```zig
pub fn nameOf(id: ComponentId) []const u8
```

Registry name of a component (e.g. `"Transform"`).

### `alignmentOf`

```zig
pub fn alignmentOf(id: ComponentId) std.mem.Alignment
```

Component alignment as a `std.mem.Alignment`.

### `idOfName`

```zig
pub fn idOfName(name: []const u8) ?ComponentId
```

Id for a registry name, or `null` if that name is not a component of this build
(e.g. a document written by a newer version).

### `writeDefault`

```zig
pub fn writeDefault(id: ComponentId, dst: []u8) void
```

Writes the default value of a component as raw bytes: the "replace" baseline for
`.zson` documents that omit a field.

## Usage Examples

```zig
const components = @import("components.zig");

// Constructing components
const name = components.Name.init("player");
const transform = components.Transform{
	.position = .{ .x = 100, .y = 200 },
	.rotation = 0.5,
	.scale = .{ .x = 2, .y = 2 },
};
const sprite = components.Sprite{
	.atlas = 3,
	.layer = 1,
	.blend = components.Blend.additive,
	.tint = .{ 1, 0.5, 0.5, 1 },
};

// Comptime id lookup
const id = components.componentId(components.Transform); // always 1
const name_str = components.nameOf(id); // "Transform"

// Name comparison
std.debug.assert(name.eql("player"));
std.debug.assert(name.slice().len <= components.Name.max_len);

// A dynamic body with a box collider and named layers
const ball = components.RigidBody2D{ .body_type = 2, .fixed_rotation = true };
const collider = components.Collider2D{ .kind = 1, .size = .{ .x = 0.5, .y = 0.5 }, .restitution = 0.8 };
const layers = ecs.Layers.fromNames(&.{ "default", "player", "ball", "wall" });
const filter = components.CollisionLayers{
	.layer = layers.bit("ball").?,
	.mask = layers.maskFromNames("wall player", null),
};
```

## Component Sizes

| Component | Size (bytes) | Notes |
|---|---|---|
| `Name` | 33 | 32 inline + len byte. |
| `Transform` | 40 | Auto-layout interleaves prev_* snapshot with live fields. |
| `Parent` | 8 | Both u32 fields pack into one `Entity`. |
| `Velocity` | 12 | Vec2 + f32. |
| `Sprite` | 52 | Kept small on purpose: 50k sprites = 2.6 MB of column data. |
| `Script` | 4 | Single u32. |
| `StateMachine` | 8 | u32 + bool. |
| `RigidBody2D` | 52 | 2 handles + 13 plain-data fields. Grows with the world: 200k bodies = 10.4 MB. |
| `Collider2D` | 40 | 2 handles + kind + 2 Vec2 + 3 f32 + a flag. |
| `CollisionLayers` | 4 | Two `u16` bitmasks. |
