# Ember Engine — Determinism

Determinism is a **contract** in Ember, not a hope (spec §6):

> Same binary + same inputs → same final state (hash test in CI).

This document describes the four pillars that make it real: the fixed-
timestep loop, the deterministic PRNG, bit-exact serialization, and stable
signal order.

---

## Overview

```
┌─────────────────────────────────────────────────────────────────┐
│                    DETERMINISM CONTRACT                          │
│                                                                 │
│  Fixed timestep  ──►  Simulation rate is constant (60 Hz)      │
│  Deterministic PRNG ──►  Same seed → same sequence, everywhere  │
│  Bit-exact serialization ──►  Same world → same bytes → same hash│
│  Stable signal order ──►  Same spawn order → same listener order│
│                                                                 │
│  Verified by: hash test in CI, save/load round-trip tests       │
└─────────────────────────────────────────────────────────────────┘
```

---

## 1. Fixed Timestep

**File:** `src/engine/core/loop.zig`

The simulation runs at a fixed 60 Hz, decoupled from rendering. Real time
is accumulated and consumed in fixed steps:

```zig
pub const FixedLoop = struct {
    fixed_dt: f32,          // 1/60 in the runtime
    accumulator: f32 = 0,
    max_catchup: u32 = 1,  // anti-death-spiral (spec §3.3)
    scale: f32 = 1,         // time scale (pause = 0, slow-mo < 1)
    dropped_total: u64 = 0,
    dropped_this_frame: u64 = 0,

    pub fn addTime(self: *FixedLoop, real_dt: f32) u32 {
        const clamped = @min(real_dt, 0.1);  // anti-hitch clamp
        self.accumulator += clamped * self.scale;
        if (self.accumulator < 0) self.accumulator = 0;

        var steps: u32 = 0;
        while (steps < self.max_catchup and self.accumulator >= self.fixed_dt) : (steps += 1) {
            self.accumulator -= self.fixed_dt;
        }
        // Leftover after exhausting catch-up: dropped (anti death-spiral).
        if (steps == self.max_catchup and self.accumulator >= self.fixed_dt) {
            const dropped: u64 = @intFromFloat(@floor(self.accumulator / self.fixed_dt));
            self.dropped_this_frame += dropped;
            self.dropped_total += dropped;
            self.accumulator = 0;
        }
        return steps;
    }

    /// Simulation→render interpolation alpha in [0, 1).
    pub fn alpha(self: *const FixedLoop) f32 {
        return @max(0, @min(1, self.accumulator / self.fixed_dt));
    }
};
```

### Why fixed timestep matters for determinism

- The simulation **always** advances in `1/60` increments, regardless of
  frame rate. A machine that renders at 58 FPS and one that renders at 62
  FPS produce the same simulation state.
- `real_dt` is clamped to 0.1 s so a tab-switch or hitch does not produce
  a giant accumulator that tries to catch up all at once.
- **Max 1 catch-up step per frame** (spec §3.3): even if 300 steps are
  pending, only 1 runs. The rest are **dropped and counted** — the report
  uses `dropped_total` to detect that the machine cannot keep up. No death
  spirals.
- Leftover time is not silently forgotten: it is either carried into the
  next frame (as the accumulator) or explicitly dropped and accounted for.

### Interpolation

Rendering decouples from simulation via `alpha()`:

```zig
// In the runtime:
r2d.collect(&world, loop.alpha());  // interpolate between previous and current
```

The renderer interpolates between the previous and current transforms using
`alpha`, so motion is smooth even when the simulation tick and the frame
rate are not in sync.

---

## 2. Deterministic PRNG

**File:** `src/engine/core/random.zig`

The engine's PRNG is **hand-rolled** instead of using `std.Random`, because
the determinism contract makes the *algorithm* part of the format: if the
PRNG ever changes, replays and recorded bugs stop reproducing.

### Why PCG, and why hand-rolled

```
std.Random.DefaultPrng is also a PCG variant, but:
  • state here is {u64, u64} — two plain integers
  • no allocation
  • randomState() / setState() give the save system an exact round-trip
    with no version guessing
```

The algorithm is pinned: **PCG-XSH-RR** (Melissa O'Neill, 2014), with the
reference in the comment. Every operation is integer or IEEE-754
arithmetic, so two `Rng` values with the same state produce the same
sequence forever, on every platform and every target (the Web build
included).

```zig
pub const Rng = struct {
    state: u64,   // PCG's 64-bit LCG state
    inc: u64,     // PCG's odd stream selector (constant per stream)

    const multiplier: u64 = 6364136223846793005;
    pub const default_seed: u64 = 0x853c49e6748fea9b;

    fn nextU32(self: *Rng) u32 {
        const old = self.state;
        self.state = old *% multiplier +% self.inc;
        const xorshifted: u32 = @truncate(((old >> 18) ^ old) >> 27);
        const rot: u5 = @truncate(old >> 59);
        return (xorshifted >> rot) | (xorshifted << ((-% rot) & 31));
    }
};
```

### Seeding

Seeds are expanded through a splitmix64 step first, so small and
sequential seeds (0, 1, 2, ...) do not produce visibly correlated first
draws — the classic weakness of a raw-LCG PCG. Two warm-up steps leave the
correlated start state:

```zig
pub fn init(seed: u64) Rng {
    var r = Rng{ .state = 0, .inc = (seed << 1) | 1 };
    _ = r.nextU32();  // warm-up
    _ = r.nextU32();  // warm-up
    return r;
}
```

### Serializable state

The state pair serializes byte-exact like every other component field:

```zig
pub fn randomState(self: *const Rng) struct { u64, u64 } {
    return .{ self.state, self.inc };
}

pub fn setState(self: *Rng, state: u64, inc: u64) void {
    self.state = state;
    self.inc = inc;
}
```

This is what gives save/load and rollback an exact round-trip.

### Distribution functions

| Function | Purpose |
|---|---|
| `nextFloat()` | Uniform `[0, 1)` — 24-bit mantissa filled directly (no division bias) |
| `float(lo, hi)` | Uniform `[lo, hi)` |
| `int(lo, hi)` | Uniform `[lo, hi]` — Lemire's multiply-shift with rejection (no modulo bias) |
| `chance(p)` | True with probability `p` |
| `sign()` | -1 or +1, 50/50 |
| `gauss(mu, sigma)` | Normal-distributed (Box-Muller, polar form) |
| `choiceIndex(len)` | Random element index, or null on empty |

The engine's own subsystems **must** draw from this (or from `noise`),
never from `std.crypto.random`, or determinism dies silently.

---

## 3. Bit-Exact Serialization (.zson)

**File:** `src/engine/ecs/zson.zig`

`.zson` is a canonical, bit-exact text format. The grammar:

```
zson 1
entity 3 {                       // tag: scene id (saved scenes) or a name (prefabs)
  Name "player"                  // components in registry order, one per line
  Transform { position: { x: 0, y: 0 }, rotation: 0, scale: { x: 1, y: 1 } }
  Parent { parent: 1 }           // entity references by tag
}
```

### Why the format looks like this

- **Text, diffable, canonical.** Two identical worlds (same spawn order,
  same values) produce byte-identical documents: entities in slot order,
  components in registry order, fields in declaration order. That is what
  makes the hash test, undo/redo and Play-in-editor snapshots possible
  (spec §6: "Play→Stop snapshot is bit-exact").

- **Floats round-trip exactly.** `{d}` formatting plus `parseFloat` inverts
  bit for bit (there is a test), so the hash of a reloaded world equals the
  original one.

- **Entity references are tags**, never volatile handles: a scene writes
  scene ids (stable by construction), a prefab writes human names.

- **Loading is two-pass.** First pass: structure (tags, component
  identities). Second pass: values, by which point every referenced entity
  already exists. A child may therefore reference its parent regardless of
  the order the file happens to use.

### Canonical hash

The world state hashes without materializing the document — the writer
drains into the hasher as it goes:

```zig
pub fn hash(world: *World) u64 {
    var scratch: [256]u8 = undefined;
    var hasher: Writer.Hashing(std.hash.Wyhash) = .initHasher(std.hash.Wyhash.init(0), &scratch);
    encode(world, &hasher.writer) catch unreachable;
    hasher.writer.flush() catch unreachable;
    return hasher.hasher.final();
}
```

### Fast float parsing

`parseDecimalFloat` is a fast path for the decimal numbers a `.zson`
document actually contains. When the mantissa is exactly representable and
the exponent is small, the value is `mantissa / 10^k` (or `* 10^k`), and
IEEE division — correctly rounded on the *exact* quotient — gives the same
float the decimal stands for. Measured: ~200 ns → ~10 ns, which is most of
a load time.

Anything the fast path does not fully understand (exponent notation, too
many digits, hex) returns `null` and the caller uses the standard parser:
exactness is never traded for speed.

### Prefabs and overrides

Prefabs and overrides are the same decoder in a different mode: decoding a
component patches the value it already has, so a document that omits a field
keeps the target's value. `zson.apply` instantiates or patches by `Name`:

```zig
// Instantiating: a new entity, identity assigned, defaults filled.
try apply(&world, prefab);

// Override: only the fields present in the document change.
try apply(&world, override_text);  // e.g. just Transform.position
```

---

## 4. Stable Signal Order

**File:** `src/engine/ecs/signals.zig`

Signals are typed events with stable emission order, drained once per frame.
The determinism-relevant rule (spec §6): connections are kept sorted by the
emitter's scene id (its spawn order), so two runs with the same spawn order
fire the same listeners in the same order — that is what makes the state
hash stable.

```zig
pub fn on(
    self: *Self,
    comptime T: type,
    name: []const u8,
    order: SceneId,          // emitter scene id (spawn order)
    ctx: ?*anyopaque,
    cb: Callback,
) !void {
    // ...
    const conn = Connection{ .order = order, .type_hash = typeHash(T), ... };
    // Keep sorted by order so drain order is deterministic by spawn.
    var at = signal.conns.items.len;
    while (at > 0 and signal.conns.items[at - 1].order > conn.order) : (at -= 1) {}
    try signal.conns.insert(allocator, at, conn);
}
```

### Other signal guarantees

- **Typed at both ends**: the emitter states the payload type, the listener
  subscribes to it; a mismatched subscription simply never fires.
- **Drained once**: `emit` only queues; `drain` fires everything and resets
  the queue in O(1). Nothing fires twice, and reentrant emits from a listener
  queue for the next frame instead of exploding the stack.
- **No allocation per event**: the queue's capacity is reserved at load time
  (bounded, a budget like the frame arena), and the ring is a plain array
  write. Connecting a *new* signal name inside the frame is the only
  allocator entry and it panics while locked.

---

## The Hash Test in CI

The determinism contract is verified by tests that run in CI:

1. **Save/load round-trip**: encode a world, decode it, compare hashes.
   ```zig
   test "save and load reproduce an identical hash (spec §6)" {
       // ... spawn entities, encode, decode ...
       try std.testing.expectEqual(hash(&world), hash(&reloaded));
   }
   ```

2. **Float bit-exactness**: format a float, parse it back, compare bits.
   ```zig
   test "float formatting round-trips bit for bit" {
       // ... for values like 0.1, 1/3, 1e-30, 3.4e38 ...
       try std.testing.expectEqual(bits_in, bits_out);
   }
   ```

3. **PRNG determinism**: same seed, same sequence; state round-trips.
   ```zig
   test "same seed, same sequence (the determinism contract)" {
       var a = Rng.init(12345);
       var b = Rng.init(12345);
       for (0..1000) |_| try testing.expectEqual(a.nextU32(), b.nextU32());
   }
   ```

4. **Signal order**: connections fire in spawn order regardless of
   subscription order.
   ```zig
   test "connections fire in emitter spawn order (spec §6)" {
       // Connected in reverse order of their emitter spawn order.
       // ... drain ...
       // Fires in spawn order: 10, 20, 30.
   }
   ```

5. **Reference resolution**: entity references resolve regardless of
   declaration order (two-pass loading).

---

## Determinism Rules of Thumb

| Rule | Enforced by |
|---|---|
| Simulation at fixed 60 Hz, max 1 catch-up step | `FixedLoop` |
| `real_dt` clamped to 0.1 s | `FixedLoop.addTime` |
| Gameplay only uses `engine.time`, never wall-clock | `core/time.zig` |
| Same seed → same sequence, every platform | `Rng` (PCG-XSH-RR, pinned) |
| RNG state serializes byte-exact | `randomState()` / `setState()` |
| Same world → same bytes → same hash | `.zson` canonical encoding |
| Floats round-trip every bit | `{d}` format + `parseDecimalFloat` |
| Stable signal order by spawn | `Signals.on` sorts by scene id |
| Play→Stop snapshot is bit-exact | `.zson` hash test in CI |

---

## The Determinism Loop

```
   ┌──────────────┐     ┌──────────────┐     ┌──────────────┐
   │  FixedLoop   │────►│  Simulation  │────►│  World state │
   │  60 Hz tick  │     │  (ECS + Lua) │     │  (archetypes)│
   └──────────────┘     └──────────────┘     └──────┬───────┘
                                                     │
   ┌──────────────┐     ┌──────────────┐              │
   │  Rng         │────►│  Randomness  │              │
   │  (seeded)    │     │  (uniform)   │              │
   └──────────────┘     └──────────────┘              │
                                                     ▼
   ┌──────────────┐     ┌──────────────┐     ┌──────────────┐
   │  Signals     │────►│  Listeners   │     │  .zson       │
   │  (spawned    │     │  (fire in    │     │  (canonical  │
   │   order)     │     │   spawn ord) │     │   hash)      │
   └──────────────┘     └──────────────┘     └──────────────┘
```

Every arrow in this diagram is deterministic: the simulation tick is fixed,
the PRNG is seeded, the signal order is by spawn, and the serialization is
canonical. The result is a world where "same inputs" always means "same
outputs" — the property that makes replays, rollbacks, and Play-in-editor
safe.
