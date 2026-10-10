# Open World Physics (activity tiers)

**Source:** `src/engine/physics/activity.zig` (tiers), `sectors.zig` (the index),
`System.retune` (`system.zig`)

How a world with 200 000 bodies fits in a 60 Hz budget. Nothing here makes the
solver faster: it changes *which bodies the solver is thinking about*, which is
the only axis that matters.

---

## The cost is not bodies

The cost of physics is **bodies in contact at the same time**. A sleeping body
costs nothing to step; a disabled one costs nothing at all. Measured on the M4
bench, 2 000 bodies stacked in a pile cost ~3.2 ms inside Box2D; the same 2 000
bodies spread across a level that has settled cost almost nothing.

So the question is never "how do I make the solver faster" but "which bodies
does the solver need to be thinking about right now". Everything below answers
the second question.

---

## The four tiers

| Tier | In the solver | Collision | Typical distance |
|---|---|---|---|
| `full` | yes | exact shape | near the focus |
| `coarse` | yes | one circle covering the body | mid range |
| `frozen` | **disabled** | none | far |
| `unloaded` | **disabled** | none, and the shape is freed | very far |

**Why `coarse` exists.** "Switch it off" is the wrong answer for anything the
player can still see or walk into. A crate two rooms away must still stop a
bullet and must not let the player fall through it; it just does not need its
eight-vertex polygon tested against every neighbour. One circle is the cheapest
shape that still answers "is anything there".

**Why `unloaded` exists.** Memory is not free either: past some distance the
shape is worth destroying outright and rebuilding on the way back.

The primitive underneath is `World.setEnabled`: a disabled body is not stepped
and does not appear in the broadphase, so it costs *nothing* — not "a little",
nothing. It is stronger than sleeping (which still occupies a slot and keeps its
contacts) and much cheaper than destroying and rebuilding the body.

---

## Radii, hysteresis, and why the numbers are what they are

`physics.ActivityConfig`:

| Field | Default | Meaning |
|---|---|---|
| `coarse_radius` | `600` | beyond this, downgrade to a circle proxy |
| `freeze_radius` | `2000` | beyond this, stop simulating |
| `unload_radius` | `6000` | beyond this, destroy the shape too |
| `hysteresis` | `1.25` | a boundary must be crossed by this factor before the tier changes |
| `view_margin` | `256` | how far past the view rect a body is still kept |
| `retune_distance` | `128` | how far the focus must move before tiers are recomputed |

`validate()` is called by `init`, not trusted: radii out of order produce a body
that is "unloaded" but "simulated", and a hysteresis below 1 is a body that
thrashes.

### Hysteresis

Without it, a body sitting exactly on a boundary flips tier every frame:
destroy the shape, rebuild it, freeze, unfreeze. The rebuild is far more
expensive than the simulation it was avoiding, so a naive distance test can be
*slower* than simulating everything.

The bands are asymmetric on purpose: dropping a tier early is cheap and safe,
restoring one late is what causes visible pop. So a body has to come noticeably
**closer** before it gets its detail back (`retune_radius / hysteresis`), and
noticeably **further** before it loses it (`radius * hysteresis`).

### Lazy retuning

Retuning means walking bodies, which costs about as much as simulating them.
So the tier set is recomputed only when the focus has moved
`retune_distance`, amortising the walk across many frames of small camera
motion. A game whose camera sits still pays it once. `Activity.setFocus` returns
whether a retune is now due — one comparison, safe to call every frame.

---

## View culling

The 2D answer to frustum culling for physics, and a stronger claim than 3D can
make: in 3D a body off the frustum cannot affect what you see; in 2D a body
off-screen usually cannot affect anything at all, because there is no
perspective to reveal it round a corner.

```lua
-- once per frame, from the camera
physics.set_view(camera.cx, camera.cy, camera.half_w, camera.half_h, true)
```

Deliberately **separate** from the distance radii, because the two answer
different questions: distance is about COST (a far body is cheap), the view rect
is about the CORRECTNESS of the assumption underneath (it is what lets a body be
skipped outright rather than merely simulated badly).

- The view **wins** when set; the radii remain the fallback when there is no
  camera, because a multiplayer server is authoritative over the whole world and
  must simulate all of it.
- `view_margin` (256) is not decoration: without it a player walking right
  culls everything to their right — including the ground they are about to step
  on — and the ground vanishes one frame before it is needed.

---

## Determinism

Everything here is a pure function of (body position, focus, config), and the
focus comes from the runtime, not the solver. The same inputs produce the same
tier set and the same trajectory, so spec §6 holds.

The tier is stored in `RigidBody2D.tier` (a `u8` ordinal) rather than in a side
table, so it travels through save/load and the state hash covers it: two runs
that tier differently cannot pass.

The classic way to break this silently is a `retier` that only ever checks the
DOWNWARD condition — a body demoted once can never be promoted again. The bench
then reports "0 of 200 000 bodies simulated" while looking perfectly healthy,
because every body was demoted on the first retune and none could return. There
is a dedicated regression test for exactly that (`activity.zig`, "a demoted body
climbs back through every tier as the focus returns"), plus a property test
asserting that no tier change produces a churn cycle at a boundary.

---

## The sector index

`physics/sectors.zig` is what makes a retune O(near) instead of O(world).

The observation it rests on: **a frozen or unloaded body does not move.** So a
body's cell only has to be correct while it is *moving* — that is, only while it
is `full` or `coarse`, which is ~1% of an open world. Everything else stays
exactly where it was filed and can be trusted indefinitely.

| Part | Shape |
|---|---|
| `entries` | one flat `Entry{ entity, x, y, tier }` per body, cached position |
| `buckets` | cell key → contiguous range into `cells_of` |
| `cells_of` | the membership array, one scan per query |

A hash of cells rather than a grid of `ArrayList`s, because the world is sparse
and mostly empty: a dense grid costs a header allocation for every cell in the
world, including the 99% that hold nothing near the camera. This one allocates
only for cells that actually contain something.

`forEachNear` visits a **bounding box** of cells, not a circle: cells wholly
outside the radius are skipped with one comparison, and the number of partially
overlapping cells is bounded by the perimeter rather than the area. The waste is
a ring of cells whose contents are then correctly demoted, which costs nothing,
because demoting is idempotent.

`touch(index, x, y)` updates a cached position without re-filing it. Re-filing is
tempting and wrong: every body that moves is in the System's `active` list, which
is walked unconditionally on every retune, so its cell never has to be exact.
Re-filing would append a second copy to the cell array on every retune, growing
it without bound, to fix something that was never broken. `rebuild` exists for
the cases that genuinely need it: a load, a teleport, a level change.

> **Status:** the index exists and is tested. The remaining work is moving
> `System.retune`'s walk from the ECS query onto it, and making a tier
> *promotion* cheap (it currently destroys and recreates the shape, ~640 ns per
> transition). See the ROADMAP's M5 entry for the live numbers — the bench
> reports where the time goes rather than hiding it.

---

## Live counters

`physics.stats()` and `Activity.Stats`:

| Field | Meaning |
|---|---|
| `by_tier[4]` | bodies per tier |
| `transitions` | tier changes on the last retune. Sustained non-zero churn means the radii or the hysteresis are wrong |
| `retunes` | retunes since start |
| `simulated_steps` | simulation updates pushed. Far below `retunes × body_count` when tiering works — the ratio is the whole story |
| `simulated`, `active_fraction` | how much of the world the solver is thinking about |

`active_fraction` is the number an open world is judged on. Measured: **2 024 of
200 000 bodies simulated (1.01%)**, 5–9× faster than the same world untiered, and
two camera walks with the same state hash.

---

## Setting it up from a game

```lua
-- where the player is: bodies tier off this
physics.set_focus(player.px, player.py)

-- what the camera sees: lets bodies be skipped outright
physics.set_view(camera.cx, camera.cy, camera.half_w, camera.half_h, true)

-- a debug overlay, safe to poll every frame
local s = physics.stats()
if s.active_fraction > 0.2 then
  log.info("physics: " .. s.simulated .. " of " .. s.bodies .. " simulated")
end
```

`zig build bench-openworld` runs the acceptance scenario: 200 000 bodies, a
camera walking a circuit that crosses every tier boundary in both directions,
deterministic, with the frame cost a function of what is NEAR rather than what
EXISTS.
