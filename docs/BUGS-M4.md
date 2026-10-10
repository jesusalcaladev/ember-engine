# Bugs found while building M4 physics

These were all found by the same means: writing the acceptance bench, and then
believing its output. Each one had been invisible to the existing test suite,
because each one produced *plausible* numbers rather than wrong ones.

They are recorded because the pattern matters more than the individual fixes.

## The pattern: a passing measurement of nothing

Three of the four produced a green result. The determinism check — "2 runs with
the same inputs end with the same state hash" — passed while the solver had never
created a single shape. Two runs that both do nothing agree perfectly. A hash is
a statement about *equality*, never about *correctness*, so it cannot detect a
world that never ran.

The same shape of bug appears in the ECS cursor (`Query.next` re-yielded row 0 of
every archetype), where a body count came out one too high per archetype.

The fix in every case was the same: add an assertion about what the world should
*look like*, not just whether two runs agree. `bench-physics` now asserts that
bodies moved (where the scenario says they should), that nothing sank through the
floor, and that the backend actually holds a body and a shape per entity.

## 1. `Query.next` re-yielded the first row of every archetype

`src/engine/ecs/query.zig`

When the cursor ran past the end of an archetype, `nextBatch` rewound `self.row`
to 0 and `next` returned that row *without consuming it*. The next call then
returned row 0 again. Every archetype after the first contributed a duplicate
entity, so a single-archetype query over 5 entities yielded 6 rows.

Worse, `next()` could also return row 0 of an archetype that matched the filter
but held no rows — every entity in it despawned — handing the caller an index
past the end. In the physics bench that surfaced as an entity index of
`0xAAAAAAAA`, Zig's undefined-memory pattern, read as a lookup into a spawn
table.

Fixed by consuming the row inside the batch branch and looping, so empty
archetypes are skipped. Regression test: `src/engine/ecs/query_cursor_test.zig`,
deliberately built from three archetypes so the cursor crosses two boundaries.

## 2. The adapter mapped its own slot index onto Box2D's `index1`

`src/engine/physics/box2d.zig`

`validBodyId` reconstructed a `b2BodyId` as `index1 = our_index + 1`. Those are
two independent numbering spaces — Box2D allocates body slots from its own pool
in its own order — so the reconstructed id named the wrong body, or none. Box2D
then dereferenced it and the process segfaulted inside `b2CreatePolygonShape`.

A comment above the field (`Box2D id -> our generation`) shows the mapping was
the original design and the translation was later optimised into arithmetic.

Fixed with explicit two-way tables: `body_ids`/`shape_ids` (our slot → Box2D id)
and `body_rev`/`shape_rev` (Box2D `index1` → our slot), the reverse needed
because a raycast reports ids in Box2D's numbering while Lua expects ours.

## 3. Generation was bumped on create, retiring the handle immediately

`src/engine/physics/box2d.zig`

`createBody` did `body_gen[index] = gen + 1` and then returned a handle carrying
`gen`. The next call on that body re-validated against `body_gen[index]`, saw the
mismatch, and treated the body as gone. Every `createShape` on a fresh body
returned null, so the world ran with **2001 bodies and 0 shapes** — and still
met the 2 ms budget, because bodies with no shapes are nearly free.

Generations now belong to the solver and are adopted from it; our own counter is
bumped on *recycle*, which is what makes a stale handle detectable while a live
one keeps working.

## 4. The pools did not grow, despite the comment saying they did

`src/engine/physics/box2d.zig`

`createBody` popped from a free list seeded to 1 024 and returned null when it
ran dry. A world asking for 2 001 bodies got 1 024 — no error, just a world that
quietly stops simulating. The comment claimed "capacity is a starting point, not
a limit: the pools grow".

Both pools now double on demand. That allocates, so it belongs to load time;
`createBody` is reachable from a mid-frame spawn and spec §3.1 forbids allocating
in the frame loop.

## 5. Velocity was never read back from the solver

`src/engine/physics/system.zig`

`pushDown` wrote `RigidBody2D.linear_velocity` into the solver every frame;
`pullUp` read back only position and rotation. The component therefore kept
whatever gameplay last wrote — usually zero — and re-pinned the body to it 60
times a second. Every body accelerated for exactly one step per frame and fell at
1/60 of gravity. `pushDown` was dutifully re-applying a stale value forever.

This one is worth dwelling on, because it is the failure mode the whole
ECS↔solver design exists to prevent: the solver owns *where things are*, but
who owns *how fast they are going* was never stated. The port already had
`getVelocity`; the sync simply did not call it.

The invariant now: gameplay may write velocity before a step (that is how you
apply an impulse), and the solver's post-step velocity is what survives into the
next frame. Momentum belongs to the solver, not to the component.

## 6. Bench geometry that tested nothing

`src/bench/physics.zig`

The first version put the floor 100 units below where 2 seconds of gravity could
reach, so bodies never touched it — every scenario reported 0 contacts while
passing determinism. Then, once contacts worked, "bouncing balls" still had 0
because 2 000 balls in a tall thin column put all but the bottom layer out of
range of a 2-second fall.

Fixed by anchoring every scenario to a single `floor_y`, laying the pile out on a
shared grid sized so the whole pile is within one run's fall, and reporting
contact counts alongside motion.

A resting stack is now expected to be *motionless* — it sleeps, and asleep means
no active contacts. Asserting motion there would have been asserting that the
solver is broken, so each scenario now declares what it expects to demonstrate.

## 7. Impulses were cancelled before they were integrated

`src/engine/physics/system.zig`, `src/engine/script/bindings.zig`

`pushDown` writes `RigidBody2D.linear_velocity` into the solver at the start of
every frame. A velocity or an impulse set directly on the solver between frames
was therefore overwritten before the step ran. `actor.apply_impulse` from Lua
was, in a real frame loop, a no-op that returned no error — a jump that
silently does nothing, which is the most expensive kind of bug to find because
the API is present and looks correct.

The acceptance suite had been passing. It called `apply_impulse` and read the
velocity straight back, never stepping the world in between — so it was reading
the impulse it had just applied, and would have kept passing after the impulse
was fully broken. Adding a `step` to the fixture is what turned it red.

The fix routes gameplay through the component and holds impulses in
`System.pending`, applied inside `pushDown` *after* the velocity write.

The general lesson: a test that reads state immediately after mutating it tests
the mutation, not the pipeline. Anything with a frame boundary needs a frame
crossed before it is read.

## 8. Sensor events needed the flag on every shape

`src/engine/physics/box2d.zig`

`enableSensorEvents` was set only on the sensor. Box2D's own wording is that
the flag "applies to sensors and non-sensors", and the event is produced for the
*pair*: with only the sensor marked, the visitor stayed unmarked and no
begin-touch was ever generated. Every trigger volume in every level was dead,
with no error anywhere.

Two wrong assumptions hid this. The first was that a sensor reports "inside",
when it reports *entering*: a pair created already overlapping produces no
begin-touch, so the original fixture — both shapes spawned at the same point —
would have failed even with correct flags. The second was that a sensor stops
things; it does not, which is why the fixture also had to be corrected.

## 9. Every contact became two signals, and the queue was finite

`src/engine/physics/system.zig`

Publishing both sides of every contact means a 2 000-body pile produces
thousands of events a step. That is correct behaviour and it still overflowed
the signal queue and panicked — in a benchmark that never asked for a single
collision event. `Signals.hasListeners` now gates publication, so a producer
that nobody subscribes to costs nothing.

The queue is a budget, not a leak, and finding it full during a load is the
intended way to learn the number was too small. But "too small" and "should not
have been publishing at all" are different problems, and only the first is a
number to raise.

## What this says about the rest of the engine

The existing suite is strong on *contracts* (component layout, determinism,
allocation discipline) and blind to *outcomes* (did anything actually happen).

Every bug above lived in the gap between the two. The cheapest general lesson:
a benchmark that cannot fail is a benchmark that has not been written yet, and
the same is true of a test that only checks two runs agree.