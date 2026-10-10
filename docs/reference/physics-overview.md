# Physics

**Source:** `src/engine/physics/` (`physics.zig` the port, `box2d.zig` the backend,
`driver.zig` the fixed step, `system.zig` the ECS bridge, `activity.zig` +
`sectors.zig` open-world tiering)

Box2D v3, behind a port that owns the vocabulary. The ECS never sees a solver
handle, Lua never sees one either, and swapping the backend is one file plus one
line.

---

## The shape of the subsystem

```
Lua bindings ──► physics.System ──► Driver (60 Hz) ──► World (VTable) ──► Box2D
                       │                                                    ▲
                       └── active list ──► ECS components (RigidBody2D …) ────┘
```

Four layers, and each one is only allowed to know about the one below it:

| Layer | Owns | File |
|---|---|---|
| Port | the vocabulary: shapes, bodies, materials, filters, `VTable` | `physics.zig` |
| Backend | Box2D. The only file that includes a Box2D header | `box2d.zig` |
| Driver | the clock: 60 Hz accumulator, one catch-up step, interpolation alpha | `driver.zig` |
| System | the ECS ↔ solver bridge, contact events, activity tiers | `system.zig` |

`createWorld(.box2d, gravity)` is the whole installation step. A second backend
means one file implementing `VTable` and one line in `root.zig`.

---

## Fixed step, not frame time

spec §6 defines determinism against a fixed rate, so the port states it as a
constant rather than a default:

| Constant | Value | Meaning |
|---|---|---|
| `fixed_hz` | `60.0` | The simulation rate. Not tunable — a change invalidates every recorded replay. |
| `fixed_dt` | `1/60` | What `step` is always called with. Never a variable dt. |
| `max_catch_up_steps` | `1` | The most fixed steps one frame may run. |

A slow frame therefore drops simulation rather than accumulating it. This is the
same choice Godot makes (`max_physics_steps_per_frame`) and for the same reason:
a frame that runs three catch-up steps makes the next frame later, which runs
five, and the spiral is indistinguishable from a hang.

The `Driver` owns the accumulator and hands back `alpha`, the fraction of a step
the renderer is between — which is what `RigidBody2D.prev_position` exists for.

```zig
var driver = physics.Driver.init(world);
const steps = driver.advance(frame_dt);   // 0, 1 -- never more
// render with driver alpha between prev_* and the live transform
```

---

## Bodies and shapes

### `BodyType`

Three kinds, one component — `RigidBody2D.body_type`, not three component types.
That is deliberate: a door switching from fixed to kinematic at runtime must not
move the entity between archetypes (spec §3.1 forbids structural changes that
spike a frame).

| Variant | Value | Moves by |
|---|---|---|
| `fixed` | 0 | never — walls, terrain |
| `kinematic` | 1 | the game writing its transform — moving platforms |
| `dynamic` | 2 | forces and collisions — the things that fall |

### Handles

`BodyId` and `ShapeId` are `{ index: u32, generation: u32 }`, the same
generation-tagging scheme as `Entity`. A recycled slot is not mistaken for the
body that used to live there. `BodyId.none` / `ShapeId.none` are the invalid
sentinel (`index == maxInt(u32)`).

The component stores the handle; the solver's own state stays on the physics side.
A `.zson` file therefore never contains a `b2Body*`, which is what makes save
files backend-independent.

### Shapes

`Shape` is plain data so it can live in a component (registry rule 1: no slices).

| `ShapeKind` | Value | Uses | Notes |
|---|---|---|---|
| `box` | 0 | `half_extents` | width/2, height/2 |
| `circle` | 1 | `radius` | |
| `capsule` | 2 | `radius.x`, `radius.y` | x = radius, y = half-height between cap centres |
| `cylinder` | 3 | `half_extents` | FLAT ends, unlike a capsule. Built as a regular octagon by `cylinderHull`. |
| `polygon` | 4 | `polygon[8]`, `polygon_count` | max 8 vertices |

**Why the cylinder is an octagon, and why it starts at −90°.** Box2D has no
cylinder, so the port defines one as a regular polygon — in the port, not in the
adapter, so a different backend gets the same shape and a saved scene means the
same thing everywhere. It starts at −90° so the polygon has a flat top and
bottom: a cylinder rotated by half a step has a vertex at the top, and a barrel
stacked on another barrel then balances on that vertex and rolls. Eight sides is
the point where it reads as round at gameplay scale; more buys accuracy nobody
can see and costs a contact test on every touching body.

`Shape.is_sensor` reports overlaps with no contact response — the trigger
volume, the score zone, the pickup radius.

`Shape.offset` lets one body carry several shapes in different places: a
character's head, torso and feet are three shapes on one body, each with its own
material.

### `Material`

| Field | Default | |
|---|---|---|
| `density` | `1.0` | mass per unit area for dynamic bodies |
| `friction` | `0.3` | |
| `restitution` | `0.0` | 0 = dead stop, 1 = perfectly bouncy |

Separate from `Shape` because two shapes on the same body routinely want
different surfaces — a bouncy ball and a grippy foot.

### Gravity

`Gravity{ .x = 0, .y = 9.8 }`. +Y is DOWN in this engine's world space (screen
coordinates), so "down" is positive. It is stated here rather than assumed
because a backend that guesses wrong silently launches every body off the top of
the screen.

---

## The sync contract

This is the part a caller has to know, because both failure modes are silent.

**Gameplay writes the component, never the solver.** `System.step` re-asserts
`RigidBody2D.linear_velocity` into the solver every frame, so a velocity or
impulse set directly on the solver between frames is overwritten before it is
integrated. An impulse goes through `System.pendingImpulse(entity, impulse)`,
which applies it *after* the velocity write.

`pushDown` → step → `pullUp`, in that order, and the order is the contract:

1. **`pushDown`** (every frame, even without a step — gameplay wrote velocity
   this frame and the next step must see it):
   - snapshots the current `Transform` into `RigidBody2D.prev_*` for
     interpolation, *before* the solver overwrites it;
   - writes `linear_velocity` / `angular_velocity` / `gravity_scale` **only when
     they differ**. Box2D wakes a body when its velocity is set, so pushing an
     unchanged value every frame means nothing ever sleeps: a 2 000-body pile
     that should settle instead re-solves 2 000 contacts forever. This one
     comparison took a settled 2 000-body scene from 16.0 ms to 3.5 ms;
   - applies queued impulses **after** the velocity write, or the velocity write
     cancels them.
2. **`driver.advance`** — whole fixed steps only.
3. **`pullUp`** — the solver's authoritative position into `Transform`, and its
   velocity back into `RigidBody2D`. Reading velocity back is load-bearing, not
   cosmetic: without it the component keeps whatever gameplay last wrote
   (usually zero) and re-pins the body to it 60 times a second, so every body
   accelerates for exactly one step per frame and falls at 1/60 of gravity —
   while still hashing deterministically. The round trip is what makes the
   solver, not the component, the owner of momentum.

Both directions walk the `active` list, not the ECS. Walking the ECS costs
~100 ns per body per pass, which at 200 000 bodies is 20 ms of bookkeeping
before the solver has done anything.

### From Lua

```lua
-- correct: write the component
actor.set_linear_velocity(self, 0, -120)
actor.apply_impulse(self, 0, -self.jump_impulse)

-- correct: read the component
local vx, vy = actor.get_linear_velocity(self)
```

`actor.is_awake(self)` is true while the solver is still thinking about the body.
A body asleep on a ledge can still jump: `apply_impulse` wakes it.

---

## Queries

| Function | Returns | Notes |
|---|---|---|
| `physics.cast_ray(x1, y1, x2, y2)` | `hit, t, px, py, nx, ny` | `t` is 0..1 along the segment; the normal points away from the surface |
| `physics.line_of_sight(x1, y1, x2, y2)` | `boolean` | true when nothing solid blocks the segment |
| `System.lineOfSight(from, to)` | `?RayHit` | the Zig form, used by AI |

Both take a `Filter`, not a body type. A line-of-sight test is a *query* and has
to obey the same collision layers the solver does: testing against a preset that
ignores layers means a trigger volume on a non-colliding layer still blocks
sight, which is the single most confusing thing a 2D game can ship. See
[collision layers](ecs-collision-layers.md).

---

## Contacts → signals

The solver's contact queue is drained once per step and published as the typed
signal `"collision"` (`physics.contact_signal`), carrying `ContactEvent`:

| Field | Meaning |
|---|---|
| `self_index`, `self_generation` | the entity the event is about |
| `other_index`, `other_generation` | the other body; `0xFFFFFFFF` = not an actor |
| `approach_speed` | impact speed in units/second, so a tap differs from a crash |
| `began` | true when the contact started this step |
| `ended` | true when it stopped (a foot leaving the ground) |

`began` is the whole point of the distinction: "a foot touched the ground" is an
event, "a foot is on the ground" is a state, and collapsing the two is how jump
logic ends up firing every frame. Signals are ordered by spawn and drained once
per frame (spec §6).

```lua
function on_signal(self, name, event)
  if name == "collision" then
    if event.began and event.approach_speed > 200 then
      effects.spawn("dust", self.px, self.py)
    end
  end
end
```

---

## Measurement

`zig build bench-physics` measures the budget and attributes where the time
goes, because a budget miss that is not attributed cannot be fixed. For 2 000
bodies over 120 frames at 60 Hz:

| scenario | total | inside Box2D | the ECS walk (ours) | contacts |
|---|---|---|---|---|
| realistic level | 3.5 ms | 3.2 ms | **0.32 ms** | 1 857 |
| resting stack | 3.5 ms | 3.2 ms | **0.35 ms** | 2 000 |
| bouncing balls | 3.0 ms | 2.6 ms | **0.32 ms** | 2 000 |
| mixed platformer | 5.7 ms | 5.4 ms | **0.33 ms** | 3 786 |

The engine's own cost is 0.32–0.35 ms and it did not move between the before and
after measurements: the sync is a fixed per-body walk that is already inside the
row. The overage is entirely Box2D solving 1 900–3 800 simultaneous contacts.

`physics.stats()` reports the same numbers live:

| Key | What it tells you |
|---|---|
| `pairs`, `pairs_per_body` | broadphase health. `pairs_per_body` below ~4 means the tree is doing its job; approaching the body count means it is not |
| `tree_height`, `static_tree_height` | flat is good, logarithmic is expected |
| `bodies`, `shapes`, `contacts`, `islands` | what the solver is holding |
| `sleeping` | the number that decides whether an open world is affordable |
| `solver_bytes` | whether a large level fits in memory at all |
| `simulated`, `active_fraction` | what the activity system decided |

The broadphase counters are exposed because a broadphase can fail *silently* and
still look fine — a tree that stopped rejecting pairs would not crash, it would
just get slower, and the only way to notice is to watch the numbers.

---

## What is not here yet

- **Broadphase exposure.** Box2D has one (SAP over a dynamic tree); the work is
  proving it is used, which is what the `stats` counters above are for.
- **Physics on a separate thread.** Real, but it trades the deterministic
  fixed-step contract for multicore, and spec §6 is worth more. Revisit if a
  project profile proves the single thread is the limit.
- **`.zson` for physics components.** `RigidBody2D` / `Collider2D` hold backend
  handles, which are runtime state by design; scenes are built from Zig today.
  The state that *is* serialized — `Transform`, and the `tier` ordinal — covers
  the determinism hash.

See [open world physics](physics-open-world.md) for the tiering that decides
which of this subsystem's bodies the solver thinks about at all.
