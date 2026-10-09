# Actor Facade

**Source:** `src/engine/ecs/actor.zig`

## Overview

Actor is the public facade over an entity. It provides ergonomics, safety, and
identity on top of a bare `Entity` handle.

What an Actor buys over a bare `Entity`:

- **Ergonomics**: `actor.get(Transform)`, `actor.setName("player")`,
  `actor.emit("died", 0)` read like the API they are.
- **Safety**: `setParent` refuses cycles before they become an infinite chain; a
  destroyed actor is invalidated by generation, so a stale handle panics nowhere
  and reads nothing.
- **Identity**: `sceneId` is the stable id `.zson` writes, surviving save/load,
  undo/redo, and Play-in-editor snapshots.

### Safety Bound

```zig
const max_parent_walk = 4096;
```

Safety bound for parent walks: a document guaranteeing a loop-free chain is not
a thing, but a 4096-deep actor tree is not a thing either.

## Type Definition

```zig
pub const Actor = struct {
	world: *World,
	entity: Entity,
	// ...
};
```

## Creation

### `spawn`

```zig
pub fn spawn(world: *World, values: anytype) !Actor
```

Spawns a new entity with the given components.

| Parameter | Type | Description |
|---|---|---|
| `world` | `*World` | The world to spawn into. |
| `values` | `anytype` | Tuple of component values to attach. |

**Returns:** A new `Actor` handle.

**Errors:** Returns the world's spawn error on failure.

### `from`

```zig
pub fn from(world: *World, e: Entity) Actor
```

Wraps an existing entity handle (e.g. from a scene file) in an Actor facade.

| Parameter | Type | Description |
|---|---|---|
| `world` | `*World` | The world the entity belongs to. |
| `e` | `Entity` | The entity handle to wrap. |

**Returns:** An `Actor` facade.

## Identity

### `isValid`

```zig
pub fn isValid(self: Actor) bool
```

Checks whether the underlying entity is still alive.

**Returns:** `true` if the entity exists and its generation matches.

### `handle`

```zig
pub fn handle(self: Actor) Entity
```

Returns the underlying entity handle.

**Returns:** The `Entity` value.

### `sceneId`

```zig
pub fn sceneId(self: Actor) SceneId
```

Returns the stable scene identity of this actor (survives save/load).

**Returns:** The `SceneId` value.

## Component Operations

### `add`

```zig
pub fn add(self: Actor, value: anytype) !void
```

Adds or overwrites a component on this actor.

| Parameter | Type | Description |
|---|---|---|
| `value` | `anytype` | Component value to add. |

### `remove`

```zig
pub fn remove(self: Actor, comptime T: type) bool
```

Removes a component from this actor.

| Parameter | Type | Description |
|---|---|---|
| `T` | `type` | Component type to remove (comptime). |

**Returns:** `true` if the component was present and removed.

### `get`

```zig
pub fn get(self: Actor, comptime T: type) ?*T
```

Gets a mutable pointer to a component.

| Parameter | Type | Description |
|---|---|---|
| `T` | `type` | Component type to fetch (comptime). |

**Returns:** Pointer to the component, or `null` if not present.

### `has`

```zig
pub fn has(self: Actor, comptime T: type) bool
```

Checks if the actor has a given component.

| Parameter | Type | Description |
|---|---|---|
| `T` | `type` | Component type to check (comptime). |

**Returns:** `true` if the component is present.

### `setName`

```zig
pub fn setName(self: Actor, display_name: []const u8) !void
```

Assigns the inline name component (creating or overwriting it).

| Parameter | Type | Description |
|---|---|---|
| `display_name` | `[]const u8` | The display name (up to 32 bytes). |

### `name`

```zig
pub fn name(self: Actor) []const u8
```

Gets the actor's display name.

**Returns:** The name as a byte slice, or `""` if no `Name` component is set.

## Transforms and Hierarchy

### `worldPosition`

```zig
pub fn worldPosition(self: Actor) hierarchy_mod.WorldTransform
```

World-space position of this actor, hierarchy included.

**Returns:** The composed `WorldTransform` in world space.

### `setParent`

```zig
pub fn setParent(self: Actor, parent_actor: Actor) !void
```

Parents this actor under `parent_actor`, refusing both self-parenting and cycles.

| Parameter | Type | Description |
|---|---|---|
| `parent_actor` | `Actor` | The new parent actor. |

**Errors:**
- `error.SelfParent` — if `parent_actor` is the same entity.
- `error.Cycle` — if `parent_actor` is a descendant of this actor.
- `error.CycleTooDeep` — if the walk exceeds `max_parent_walk` (4096).

### `parent`

```zig
pub fn parent(self: Actor) ?Actor
```

Gets the parent actor, if any.

**Returns:** The parent `Actor`, or `null` if root or parent is dead.

## Signals

### `emit`

```zig
pub fn emit(self: Actor, comptime T: type, event: []const u8, value: T) void
```

Queues a typed event; listeners registered for the same payload type fire on the
next `world.signals.drain()`.

| Parameter | Type | Description |
|---|---|---|
| `T` | `type` | Payload type (comptime). |
| `event` | `[]const u8` | Signal name. |
| `value` | `T` | Payload value. |

### `on`

```zig
pub fn on(
	self: Actor,
	comptime T: type,
	event: []const u8,
	ctx: ?*anyopaque,
	cb: Callback,
) !void
```

Subscribes to `event`. The connection is ordered by this actor's scene id, so
listener order is stable by spawn order.

| Parameter | Type | Description |
|---|---|---|
| `T` | `type` | Payload type (comptime). |
| `event` | `[]const u8` | Signal name. |
| `ctx` | `?*anyopaque` | User context pointer passed to the callback. |
| `cb` | `Callback` | Listener function pointer. |

## Lifecycle

### `destroy`

```zig
pub fn destroy(self: Actor) bool
```

Despawns the entity and invalidates the handle. Listeners registered by this
actor are also removed.

**Returns:** `true` if the entity was alive and destroyed.

## Usage Examples

```zig
const std = @import("std");
const world_mod = @import("world.zig");
const components = @import("components.zig");
const Actor = @import("actor.zig").Actor;

var world = world_mod.World.init(allocator);
defer world.deinit();

// Spawn with components
const player = try Actor.spawn(&world, .{
	components.Transform{ .position = .{ .x = 3, .y = 4 } },
});
try player.setName("player");

// Read components
const transform = player.get(components.Transform).?;
std.debug.assert(transform.position.x == 3);

// Parenting
const root = try Actor.spawn(&world, .{components.Transform{}});
try player.setParent(root);

// Cycle refusal
try std.testing.expectError(error.Cycle, root.setParent(player));

// Signals
const Damage = struct { amount: u32 };
var total: u32 = 0;
try player.on(Damage, "damaged", &total, struct {
	fn cb(ctx: ?*anyopaque, value: *const anyopaque) void {
		const d: *const Damage = @ptrCast(@alignCast(value));
		(@ptrCast(@alignCast(ctx.?))).*.amount += d.amount;
	}
}.cb);

player.emit(Damage, "damaged", .{ .amount = 42 });
world.signals.drain();
std.debug.assert(total == 42);

// Destroy
std.debug.assert(player.destroy());
std.debug.assert(!player.isValid());
```

## Error Handling

| Error | When |
|---|---|
| `error.SelfParent` | `setParent` called with the same entity. |
| `error.Cycle` | `setParent` would create a parent cycle. |
| `error.CycleTooDeep` | Parent walk exceeds 4096 steps (corrupt or extremely deep chain). |
