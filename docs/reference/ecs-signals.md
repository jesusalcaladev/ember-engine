# Signals System

**Source:** `src/engine/ecs/signals.zig`

## Overview

Signals provide typed events with stable emission order, drained once per frame.

Design rules (spec sections 2 and 6):

- **Typed at both ends**: the emitter states the payload type, the listener
  subscribes to it; a mismatched subscription simply never fires. No `void**`
  soup, and the copy is a memcpy of a comptime-known size.
- **Stable order**: connections are kept sorted by the emitter's scene id (its
  spawn order), so two runs with the same spawn order fire the same listeners
  in the same order.
- **Drained once**: `emit` only queues; `drain` fires everything and resets the
  queue in O(1). Nothing fires twice, and reentrant emits from a listener queue
  for the next frame instead of exploding the stack.
- **No allocation per event**: the queue's capacity is reserved at load time
  (bounded budget); the ring is a plain array write.

## Constants

| Constant | Type | Value | Description |
|---|---|---|---|
| `max_payload` | `usize` (comptime) | 64 | Maximum payload bytes per emitted event. |
| `default_queue` | `usize` (comptime) | 1024 | Default queue capacity reserved at load time. |

## Types

### `Callback`

```zig
pub const Callback = *const fn (ctx: ?*anyopaque, value: *const anyopaque) void;
```

Erased listener shape. Listeners receive the payload by pointer and cast it to
their type once:

```zig
const damage: *const Damage = @ptrCast(@alignCast(value));
```

Typed at both ends by the `T` passed to `on`/`emit`, which is what makes a
mismatch impossible to fire instead of merely unlikely.

### Internal Types

```zig
const Connection = struct {
	order: SceneId,      // Emitter scene id (spawn order). 0 for engine-wide listeners.
	type_hash: u64,      // Wyhash of the payload type name.
	callback: Callback,
	ctx: ?*anyopaque,
};

const Signal = struct {
	name: []const u8,   // Interned, owned by the map key.
	conns: std.ArrayList(Connection),
};

const Event = struct {
	signal: u32,        // Index into the signals array.
	type_hash: u64,
	len: u32,
	payload: [max_payload]u8,
};
```

## `Signals` Struct

```zig
pub const Signals = struct {
	allocator: ?std.mem.Allocator = null,
	signals: std.ArrayList(Signal) = .empty,
	interner: std.StringHashMapUnmanaged(u32) = .{},
	events: std.ArrayList(Event) = .empty,
	locked: bool = false,
	// ...
};
```

### Fields

| Field | Type | Description |
|---|---|---|
| `allocator` | `?std.mem.Allocator` | Allocator for queues and interned names. `null` until `reserve` is called. |
| `signals` | `std.ArrayList(Signal)` | All known signal names with their connections. |
| `interner` | `std.StringHashMapUnmanaged(u32)` | Signal name to index map. |
| `events` | `std.ArrayList(Event)` | The event queue (drained once per frame). |
| `locked` | `bool` | Set by the owner (World) during the frame loop. |

## Lifecycle

### `reserve`

```zig
pub fn reserve(self: *Self, allocator: std.mem.Allocator, queue_capacity: usize) !void
```

Pre-allocates the event queue: this is the allocation that keeps per-frame emits
free. Also binds the allocator used to intern signal names and store
connections.

| Parameter | Type | Description |
|---|---|---|
| `allocator` | `std.mem.Allocator` | The allocator to use. |
| `queue_capacity` | `usize` | Event queue capacity to reserve. |

### `deinit`

```zig
pub fn deinit(self: *Self) void
```

Frees all memory: signal names, connections, and the event queue.

## Wiring

### `on`

```zig
pub fn on(
	self: *Self,
	comptime T: type,
	name: []const u8,
	order: SceneId,
	ctx: ?*anyopaque,
	cb: Callback,
) !void
```

Subscribes `cb` to `name` for payload `T`, fired among the listeners of the same
emitter in `order` (spawn order). Connect at load time: the first use of a
signal name allocates.

| Parameter | Type | Description |
|---|---|---|
| `T` | `type` | Payload type (comptime). |
| `name` | `[]const u8` | Signal name. |
| `order` | `SceneId` | Emitter scene id (spawn order). |
| `ctx` | `?*anyopaque` | User context pointer. |
| `cb` | `Callback` | Listener function pointer. |

**Panics:** If called while `locked` (during the frame loop).

### `off`

```zig
pub fn off(self: *Self, order: SceneId) void
```

Drops every connection registered under `order` (an entity went away).

| Parameter | Type | Description |
|---|---|---|
| `order` | `SceneId` | The scene id whose connections should be removed. |

## Emitting

### `emit`

```zig
pub fn emit(self: *Self, comptime T: type, name: []const u8, value: T) void
```

Queues an event for the next `drain`. Zero allocation, zero dispatch.

| Parameter | Type | Description |
|---|---|---|
| `T` | `type` | Payload type (comptime). Must be <= `max_payload` (64 bytes). |
| `name` | `[]const u8` | Signal name. |
| `value` | `T` | Payload value (memcpy'd into the queue). |

**Panics:**
- If no allocator is set (`reserve` not called first).
- If the signal name is new and the system is `locked` (frame loop active).
- If the event queue is full (it is a budget, not a leak).

## Draining

### `drain`

```zig
pub fn drain(self: *Self) void
```

Fires every queued event, in emission order, and clears the queue in O(1).

Events are dispatched by iterating the signal's connections and skipping any
whose `type_hash` does not match the event's payload type. This allows multiple
typed channels to share the same signal name.

## Statistics

### `queuedEvents`

```zig
pub fn queuedEvents(self: *const Self) usize
```

Number of events currently in the queue (waiting for the next `drain`).

### `connectionCount`

```zig
pub fn connectionCount(self: *const Self) usize
```

Total number of connections across all signals.

### `signalCount`

```zig
pub fn signalCount(self: *const Self) usize
```

Number of distinct signal names.

## Usage Examples

```zig
const std = @import("std");
const signals_mod = @import("signals.zig");

const Damage = struct { amount: u32 };

var damage_total: u32 = 0;

fn onDamaged(ctx: ?*anyopaque, value: *const anyopaque) void {
	const damage: *const Damage = @ptrCast(@alignCast(value));
	const total: *u32 = @ptrCast(@alignCast(ctx.?));
	total.* += damage.amount;
}

var signals = signals_mod.Signals{};
const allocator = std.heap.page_allocator;
try signals.reserve(allocator, 1024);
defer signals.deinit();

// Subscribe (load time, before the frame loop)
try signals.on(Damage, "damaged", 1, &damage_total, onDamaged);

// Emit during the frame (zero allocation)
signals.emit(Damage, "damaged", .{ .amount = 5 });
signals.emit(Damage, "damaged", .{ .amount = 7 });

// Nothing fires until drain
std.debug.assert(signals.queuedEvents() == 2);
std.debug.assert(damage_total == 0);

// Drain fires all queued events
signals.drain();
std.debug.assert(damage_total == 12);
std.debug.assert(signals.queuedEvents() == 0);

// Draining twice does not fire again
signals.drain();
std.debug.assert(damage_total == 12);
```

## Type Safety

The system enforces type safety at both ends:

```zig
try signals.on(Damage, "same_name", 1, &sink, onDamaged);
signals.emit(u8, "same_name", 1); // Different payload type: never fires
signals.drain();
// sink is unchanged: the u8 event was not delivered to the Damage listener
```

## Order Stability

Connections are sorted by `order` (scene id = spawn order) at subscription
time. Two runs with the same spawn order fire the same listeners in the same
order:

```zig
// Subscribe in reverse order
try signals.on(u32, "hit", 30, &ctx30, cb);
try signals.on(u32, "hit", 10, &ctx10, cb);
try signals.on(u32, "hit", 20, &ctx20, cb);

// Fires in scene-id order: 10, 20, 30
signals.emit(u32, "hit", 42);
signals.drain();
```
