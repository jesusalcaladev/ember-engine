# Ember Engine — Architecture Overview

Ember is a proprietary 2D game engine by **Daara Studios**, written in Zig with a
Dawn (WebGPU) renderer, Box2D v3 physics and LuaJIT scripting. This document
describes the engine's hybrid Actor+ECS architecture, its design philosophy,
and how the layers connect.

---

## Design Philosophy

The engine is built on a few core principles:

1. **The ECS is an internal detail.** The public API is **Actor + Components +
   Signals** (spec §7). Gameplay code never touches archetypes, slots, or rows —
   it speaks in actors, components, and events. The ECS is the storage engine
   underneath; the actor is the ergonomic facade on top.

2. **Everything runtime-facing must be sayable in one line.**
   `actor.get(Transform)`, `actor.setName("player")`, `actor.emit("died", 0)` —
   the API reads like the concept it represents. This is a deliberate ergonomic
   choice: a codebase where every operation is a single expressive line is
   easier to audit, test, and script against.

3. **Zero-allocation frame loops.** The frame must not allocate. All transient
   memory comes from a frame arena; all persistent structures (ECS archetypes,
   signal queues, hierarchy scratch) are reserved at load time and locked during
   the frame. A growth attempt while locked is a panic, not a silent spike.

4. **Determinism is a contract, not a hope.** Same binary + same inputs → same
   final state, verified by a hash test in CI. This drives everything from the
   fixed-timestep loop to the PRNG to the serialization format.

5. **Bit-exact serialization.** `.zson` documents are canonical: identical
   worlds produce byte-identical documents, and floats round-trip every bit.
   This is what makes save/load, undo/redo, and Play-in-editor snapshots safe.

---

## Layer Diagram

```
┌─────────────────────────────────────────────────────────────────────┐
│                        GAMEPLAY / RUNTIME                          │
│   LuaJIT behaviors  ·  Actor facade  ·  Signals  ·  .zson scenes    │
├─────────────────────────────────────────────────────────────────────┤
│                    engine  (public boundary)                        │
│   core  ·  ecs  ·  platform  ·  render  ·  batcher  ·  script       │
├──────────────────────────┬──────────────────────────────────────────┤
│         core             │              ecs                          │
│  math, arena, tracker    │  World (slots + archetypes)              │
│  profiler, loop, log     │  Actor facade                            │
│                          │  Components, Queries, Hierarchy           │
│                          │  Signals, .zson                           │
├──────────────────────────┴──────────────────────────────────────────┤
│              platform (GLFW)  ·  render (Dawn / null)                │
└─────────────────────────────────────────────────────────────────────┘
```

The `engine` module (`src/engine/root.zig`) is the single public boundary.
The runtime and the editor import it by name and only see what is re-exported:

```zig
pub const core = @import("core");
pub const ecs = @import("ecs");
pub const platform = @import("platform/platform.zig");
pub const render = @import("render/render.zig");
pub const batcher = @import("render/batcher.zig");
pub const atlas = @import("render/atlas.zig");
pub const render2d = @import("render/2d.zig");
pub const script = @import("script");
```

Dawn and GLFW stay hidden behind `platform`/`render` (spec §7). `core` and
`ecs` are separate build modules so each can be compiled and tested on its own.

---

## The World: Slots + Archetypes

`World` (`src/engine/ecs/world.zig`) is the heart of the ECS. It uses a
**slots + archetypes** design:

```
World
├── slots: []Slot              ← identity + location
│   └── Slot { generation, scene_id, archetype, row, occupied }
├── free_slots: []u32          ← recycled slot indices
├── archetypes: []Archetype    ← one table per component set
│   └── Archetype { mask, ids, columns, entities }
├── hierarchy: Hierarchy        ← parent-chain scratch (opt-in)
├── signals: Signals            ← typed events, drained once per frame
└── alloc_locked: bool          ← frame discipline guard
```

### Slots

Each slot holds identity (generation, scene id) and location (archetype index,
row). An `Entity` handle is only `{index, generation}`. When an entity is
despawned, its slot's generation is bumped — every outstanding copy of that
handle fails the generation test. **Use-after-free is impossible by construction.**

### Archetypes

An archetype is a table for one exact component set. Archetypes are found by
mask equality (linear scan: a world has tens of archetypes, each test is a
handful of word comparisons) — no hash map, no allocation, deterministic
discovery order.

Adding or removing a component moves the entity to its new archetype:
the row is copied, the source row is swap-removed (O(1), no scan), and the
entity that moved into the hole has its row index fixed up.

### Identity: Entity vs SceneId

There are two identity concepts:

| Concept | Type | Lifetime | Written to `.zson`? |
|---|---|---|---|
| `Entity` | `{index: u32, generation: u32}` | Volatile — dies with the slot | No |
| `SceneId` | `u64` | Stable — survives save/load | Yes |

`SceneId` is the identity that matters across frames, undo/redo, and
Play-in-editor snapshots. `.zson` documents reference entities by scene id
(or by name for prefabs), never by volatile handle.

---

## The Actor Facade

`Actor` (`src/engine/ecs/actor.zig`) is the public API over an entity. It
wraps a `*World` and an `Entity` and provides:

### What an Actor buys over a bare Entity

- **Ergonomics** — one-line operations:
  ```zig
  const player = try Actor.spawn(&world, .{
      Transform{ .position = .{ .x = 3, .y = 4 } },
      Name.init("player"),
  });
  try player.setName("player");
  player.emit(Damage, "damaged", .{ .amount = 4 });
  ```

- **Safety** — `setParent` refuses cycles *before* they become an infinite
  chain in the resolver, and a destroyed actor is invalidated by generation:
  ```zig
  pub fn setParent(self: Actor, parent_actor: Actor) !void {
      if (parent_actor.entity.eql(self.entity)) return error.SelfParent;
      // Walk up to max_parent_walk (4096) looking for a cycle...
      // ...then add the Parent component.
  }
  ```

- **Identity** — `sceneId()` is the stable id `.zson` writes:
  ```zig
  pub fn sceneId(self: Actor) SceneId {
      return self.world.sceneIdOf(self.entity);
  }
  ```

### Components

Components are plain Zig structs stored in archetype columns (SoA). The actor
facade delegates to the world:

```zig
pub fn get(self: Actor, comptime T: type) ?*T {
    return self.world.get(self.entity, T);
}
pub fn add(self: Actor, value: anytype) !void {
    try self.world.add(self.entity, value);
}
pub fn remove(self: Actor, comptime T: type) bool {
    return self.world.remove(self.entity, T);
}
```

The pointer returned by `get` is valid until this entity's component set
changes (adding/removing a component moves the row, which may reallocate
columns). Systems that stale the pointer is a bug.

### Signals

Signals are typed events with stable emission order, drained once per frame:

```zig
// Subscribe (load time):
try player.on(Damage, "damaged", &ctx, onDamaged);

// Emit (zero allocation, zero dispatch):
player.emit(Damage, "damaged", .{ .amount = 4 });

// Once per frame:
world.signals.drain();
```

Connections are kept sorted by the emitter's scene id (spawn order), so two
runs with the same spawn order fire the same listeners in the same order —
that is what makes the state hash stable.

---

## The Frame Loop

The runtime (`src/runtime/main.zig`) shows how the layers connect in practice:

```
Frame
│
├─ 1. Frame limiter (Godot-style max_fps)
│      limiter.wait(now_ns) → sleep the remainder
│
├─ 2. Resize handling (OUTSIDE the forbidden zone)
│      Creating GPU objects / allocating is forbidden in-frame (§3.6)
│
├─ 3. BEGIN FORBIDDEN ZONE
│      tracker.beginFrame()     ← no allocations outside the arena
│      frame_arena.beginFrame() ← O(1) reset
│      prof.beginFrame(...)     ← start measuring
│
├─ 4. Input                        zone("input")
├─ 5. Fixed-timestep simulation    zone("fixed_update")
│      loop.addTime(real_dt) → N steps
│      behaviors.fixedUpdate(fixed_dt)  × N
├─ 6. Script update + GC step      zone("script_update")
├─ 7. ECS → GPU instances          zone("batch")
│      r2d.collect(&world, loop.alpha())
├─ 8. Render                       zone("render")
│      renderer.beginFrame() → acquire → encode → present
│
└─ 9. END FORBIDDEN ZONE
       prof.endFrame()
       tracker.endFrame()
```

The pipeline (spec §7):

```
ECS sim (60 Hz, interpolated) → render2d system → offscreen target → SMAA 1x → swapchain
```

The game **always** renders to an offscreen target; the editor composes it
into the viewport panel. One process, one window — Godot-style play in a
separate window is forbidden by design.

---

## Module Map

| Module | Responsibility |
|---|---|
| `core/` | Foundations: math, arena, tracker, profiler, loop, log, time |
| `ecs/` | Archetypes, queries, hierarchy, signals, actor, `.zson` |
| `platform/` | Window + input (GLFW bindings) |
| `render/` | Renderer interface + Dawn/null backends + WebGPU bindings |
| `script/` | LuaJIT scripting layer (behaviors, bindings, metadata) |
| `runtime/` | The `ember` executable (the game target) |
| `bench/` | Benchmark suite: the acceptance criteria, measured |
| `tools/` | `ember-profile`: the report reader + CI regression gate |

---

## Key Invariants (spec §7)

- **One process, one window.** The game always renders to an offscreen target;
  the editor composes.
- **Lua never touches GPU/window/filesystem directly** — only the engine API.
- **The ECS is an internal detail**; the public API is Actor + Components +
  Signals and can only grow with semver.
- **Every subsystem owns its (tagged) allocator**; the editor uses its own.
- **v1 targets**: Windows x86_64 (DD12), Linux x86_64 (Vulkan), Web (WebGPU).
