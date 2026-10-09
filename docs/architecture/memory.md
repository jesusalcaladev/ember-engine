# Ember Engine — Memory Architecture

Ember's memory architecture is built around one non-negotiable rule
(spec §3.1): **zero allocations in the frame loop**. This document describes
the three cooperating mechanisms that enforce it — the frame arena, the
tracked allocator, and the world's allocation lock — and how they fit
together.

---

## The Three Layers

```
┌─────────────────────────────────────────────────────────────┐
│                     FRAME LOOP                               │
│                                                             │
│   All transient memory ──► FrameArena (bump, O(1) reset)   │
│   All persistent memory ──► TrackedAllocator (panics in-frame)│
│   All ECS growth ──► World.lockAllocs() (panics while locked)│
│                                                             │
└─────────────────────────────────────────────────────────────┘
         │                              │
         ▼                              ▼
┌─────────────────┐            ┌─────────────────────┐
│   FrameArena    │            │  TrackedAllocator   │
│  (per-frame)    │            │  (boot + load time) │
│                 │            │                     │
│  offset = 0     │            │  in_frame flag      │
│  on beginFrame  │            │  live_bytes counter │
│                 │            │  peak_live_bytes    │
└─────────────────┘            └─────────────────────┘
```

---

## 1. FrameArena — Per-Frame Transient Memory

**File:** `src/engine/core/arena.zig`

The frame arena is a bump allocator with a fixed capacity (8 MB by default in
the runtime). All of a frame's transient memory comes from here.

### Properties

| Property | Behavior |
|---|---|
| **Reset** | O(1): `offset = 0` on `beginFrame()` |
| **Capacity** | Fixed at init; bounded memory |
| **Overflow** | Panic with a clear message (frame memory is a budget) |
| **High-water** | Exact per-frame peak, for the memory report (spec §5) |
| **Free** | No-op: the frame reset frees everything |

```zig
pub const FrameArena = struct {
    buf: []u8,
    offset: usize = 0,
    high_water: usize = 0,
    frames_used: u64 = 0,

    pub fn beginFrame(self: *FrameArena) void {
        self.offset = 0;              // O(1) reset
    }

    pub fn endFrame(self: *FrameArena) void {
        if (self.offset > self.high_water) self.high_water = self.offset;
        self.frames_used += 1;
    }

    fn bumpAlloc(ctx: *anyopaque, len: usize, alignment: std.mem.Alignment, ret_addr: usize) ?[*]u8 {
        const self: *FrameArena = @ptrCast(@alignCast(ctx));
        const start = alignForward(self.offset, alignment);
        const end = start + len;
        if (end > self.buf.len) {
            std.debug.panic(
                "frame arena full: {d}/{d} bytes (raise the capacity; frame memory is a budget)",
                .{ end, self.buf.len },
            );
        }
        self.offset = end;
        return self.buf.ptr + start;
    }
};
```

### Alignment

The arena honors Zig's alignment model. `alignForward` rounds the offset up
to the requested alignment:

```zig
fn alignForward(offset: usize, alignment: std.mem.Alignment) usize {
    const a = alignment.toByteUnits();
    return (offset + a - 1) & ~(a - 1);
}
```

### Resize / Remap

`resize` and `remap` only succeed for the **last** allocation (the bump
pattern) — shrinking in place is always valid, extending only works if the
allocation is at the tip of the bump:

```zig
fn bumpResize(ctx: *anyopaque, memory: []u8, alignment: std.mem.Alignment, new_len: usize, ret_addr: usize) bool {
    const self: *FrameArena = @ptrCast(@alignCast(ctx));
    if (new_len <= memory.len) return true;  // shrink: always valid
    const start = @intFromPtr(memory.ptr) - @intFromPtr(self.buf.ptr);
    if (start + memory.len == self.offset and start + new_len <= self.buf.len) {
        self.offset = start + new_len;      // extend the bump
        return true;
    }
    return false;
}
```

### Usage in the Runtime

```zig
// Boot time (main.zig):
var frame_arena = try core.arena.FrameArena.init(boot_alloc, 8 * 1024 * 1024);

// Per frame:
frame_arena.beginFrame();   // O(1) reset — everything from last frame is gone
// ... allocate freely ...
frame_arena.endFrame();     // update high-water
```

---

## 2. TrackedAllocator — Boot + Load-Time Allocations

**File:** `src/engine/core/tracker.zig`

The tracked allocator wraps a child allocator and counts every alloc/free.
While `in_frame` is true, **any allocation through it panics** — all
transient memory must come from the frame arena.

```zig
pub const TrackedAllocator = struct {
    child: std.mem.Allocator,
    count_allocs: u64 = 0,
    count_frees: u64 = 0,
    live_bytes: i64 = 0,
    peak_live_bytes: usize = 0,
    in_frame: bool = false,

    fn allocFn(ctx: *anyopaque, len: usize, alignment: std.mem.Alignment, ret_addr: usize) ?[*]u8 {
        const self: *TrackedAllocator = @ptrCast(@alignCast(ctx));
        if (self.in_frame) {
            std.debug.panic("allocation of {} bytes outside the frame arena during the frame", .{len});
        }
        const mem = self.child.rawAlloc(len, alignment, ret_addr) orelse return null;
        self.count_allocs += 1;
        self.live_bytes += @intCast(len);
        return mem;
    }
};
```

### Frame discipline

```zig
pub fn beginFrame(self: *TrackedAllocator) void {
    self.in_frame = true;
}

pub fn endFrame(self: *TrackedAllocator) void {
    self.in_frame = false;
    if (self.live_bytes > 0) {
        const live: usize = @intCast(self.live_bytes);
        if (live > self.peak_live_bytes) self.peak_live_bytes = live;
    }
}
```

The `peak_live_bytes` is recorded when the frame closes — this is the
high-water mark the memory report prints (spec §5).

### Usage in the Runtime

```zig
// Boot time:
var tracker = core.tracker.TrackedAllocator{ .child = std.heap.c_allocator };
const boot_alloc = tracker.allocator();

// Per frame (inside the forbidden zone):
tracker.beginFrame();   // from here on: no allocations outside the arena
// ... frame work ...
tracker.endFrame();
```

The runtime uses `boot_alloc` for everything that outlives a single frame:
the window, the renderer, the ECS world, the LuaJIT VM, the frame arena's
backing buffer.

---

## 3. World Lock — ECS Growth Guard

**File:** `src/engine/ecs/world.zig`

The world has its own allocation lock, separate from the tracker. When
`alloc_locked` is true, any attempt to grow slots, free slots, archetypes,
or hierarchy scratch **panics**:

```zig
pub fn lockAllocs(self: *Self) void {
    self.alloc_locked = true;
    self.signals.locked = true;
}

fn guard(self: *const Self, comptime what: []const u8) void {
    if (self.alloc_locked) {
        std.debug.panic(
            "world: {s} during the frame loop. Pre-allocate with World.reserve/reserveEntities before the loop (spec §3.1)",
            .{what},
        );
    }
}
```

### Pre-allocation at Load Time

The world provides explicit reservation methods so loading a scene of `n`
entities never grows anything during the frame:

```zig
// Reserve identity + free-list capacity:
try world.reserveEntities(n);

// Pre-grow the archetype for a component set to hold n rows:
try world.reserve(.{ components.Transform, components.Velocity }, n);

// Opt in to the hierarchy and allocate its scratch now:
try world.enableHierarchy();

// Bound the signal event queue:
try world.reserveSignals(queue_capacity);
```

Once reserved, spawning from the locked world works fine — the guard only
covers *capacity growth*:

```zig
test "reserve then spawn: no allocation while locked (spec §3.1)" {
    // ... reserveEntities(16), reserve(..., 16), lockAllocs() ...
    // Spawning 16 entities while locked: works (no growth).
    // Despawning them all: recycles the pool (not grows it).
    // Spawning again: reuses the recycled slots, still without growth.
}
```

---

## How the Three Layers Cooperate

```
BOOT TIME
──────────
  tracker = TrackedAllocator{ child: c_allocator }
  boot_alloc = tracker.allocator()

  frame_arena = FrameArena.init(boot_alloc, 8 MB)
  world = World.init(boot_alloc)
  world.reserveEntities(N)
  world.reserve(.{Transform, Sprite}, N)
  world.enableHierarchy()
  world.reserveSignals(1024)

FRAME LOOP (the "forbidden zone")
─────────────────────────────────
  tracker.beginFrame()        ← tracked allocator: panic on any alloc
  frame_arena.beginFrame()    ← O(1) bump reset
  world.lockAllocs()          ← world: panic on any growth

  ... input, simulation, render ...
  ... all transient allocs from frame_arena.allocator() ...
  ... all persistent allocs already reserved ...

  world.unlockAllocs()
  frame_arena.endFrame()      ← record high-water
  tracker.endFrame()          ← record peak_live_bytes
```

The layers are independent but complementary:

- The **frame arena** makes transient allocation cheap and reset free.
- The **tracked allocator** makes persistent allocation visible and
  forbidden during the frame.
- The **world lock** makes ECS growth impossible during the frame.

Together they make "zero allocations in the frame loop" an **enforced
invariant**, not a convention. The enforcement is cheap: three boolean
flags checked at allocator entry.

---

## The Memory Report (spec §5)

Every run prints a memory summary at exit:

```
  mem: live {live} bytes, peak {peak} bytes, arena high-water {hw} bytes ({used} in use)
  proc: rss {rss} MiB (peak {peak_rss} MiB), {n} threads, cpu total {cpu}%, main {main}%
```

| Metric | Source | Meaning |
|---|---|---|
| `live_bytes` | TrackedAllocator | Bytes currently allocated outside the arena |
| `peak_live_bytes` | TrackedAllocator | High-water of live bytes, recorded at each `endFrame` |
| `arena_high_water` | FrameArena | Peak bytes used in any single frame |
| `arena_used_bytes` | FrameArena | Bytes used in the current frame |
| `rss_bytes` | Sampler (background thread) | Resident set size from `/proc/self/stat` |

### RAM Budgets (spec §5)

| Profile | RSS limit |
|---|---|
| Exported game, empty project | ≤ 48 MB |
| Exported game, full demo | ≤ 128 MB |
| Editor, empty project | ≤ 512 MB |
| Editor, full demo | ≤ 1.2 GB |

Rules:
- **Every cache has a byte-budget + eviction** and shows up in the memory report.
- 8 h soak test: memory drift ≤ 2%.
- Allocators tagged per subsystem; high-water marks visible in the report.
- Growth > 5% between consecutive frames is logged in debug (never silent).

---

## The Zero-Allocation Guarantee in Practice

The canonical scene (50k sprites, 1280×720, ReleaseSafe) measures:

| Criterion | Budget | Measured |
|---|---|---|
| Allocations in the frame loop | 0 | **0** |
| GPU objects created in frame | 0 | **0** |
| Staging upload / frame | ≤ 2 MB | 1.6 MB |

The frame arena's 8 MB capacity is the ceiling for all transient frame
memory; the tracked allocator's `in_frame` panic is the backstop for
anything that tries to allocate outside it. The world's `lockAllocs` is the
backstop for ECS structural growth. Three flags, one invariant.
