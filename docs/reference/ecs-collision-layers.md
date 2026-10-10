# Collision Layers

**Source:** `src/engine/ecs/collision_layers.zig`, component
`ecs.components.CollisionLayers`

Sixteen named layers, Godot-style `collision_layer` / `collision_mask`,
configured by name in project settings and applied to *shapes and raycasts
alike*.

---

## The component

```zig
pub const CollisionLayers = struct {
    layer: u16 = everything,   // which layer(s) this body is ON
    mask: u16 = everything,    // which layer(s) it is WILLING to interact with
};
```

Two bitmasks, four bytes. A body may be on several layers at once — a player that
is both `player` and `hurtable` — which is what bits are for.

Separate from `Collider2D` because it is a property of the **body**, not of one
shape: a character on the `player` layer should hit the `enemy` layer with all of
its parts. The shape carries shape-specific exceptions.

### The pair test

```zig
// collision_layers.zig — Pair.collides
if (self.a_layer == nothing or self.b_layer == nothing) return false;
return (self.a_layer & self.b_mask) != 0 and (self.b_layer & self.a_mask) != 0;
```

**Symmetric on purpose.** A pair either agrees to interact or does not, which is
what makes a layer a *category* rather than a query. With a one-way
`A.mask & B.layer` test, a projectile would pass through a wall that is trying to
stop it — A is willing to hit B, B is not willing to hit A, and they do not
interact. There is a test for that exact failure.

Declared once, so nothing re-implements it and gets the symmetry wrong.

---

## The registry

Layers are named once at load and then read-only:

```zig
var layers = ecs.Layers.fromNames(&.{ "default", "player", "enemy", "ground", "pickup" });
const player_bit = layers.bit("player").?;              // 1 << 1
const hits = layers.maskFromNames("enemy pickup", &unknown_count);
```

| Function | Purpose |
|---|---|
| `fromNames(names)` | builds from a settings list, in bit order |
| `set(index, name)` | names one layer |
| `name(index)` / `indexOf(name)` | both directions |
| `bit(name)` | name → `1 << index`. **Null for an unknown name**, so a typo becomes a nil the caller must handle rather than layer 0, which would silently collide with everything |
| `maskFromNames("a b c", &unknown)` | space-separated list → mask; unknown names are counted so a typo is reportable |
| `describe(writer)` | one line per named bit — the fastest way to find "why is my doorbell solid" |

`layer_count = 16`: the same width as Godot, and one `u16` that fits in a
component next to its mask without padding.

### The default is "no layers"

A body with no `CollisionLayers` is permissive — it collides with everything, and
everything collides with it. A project that never touches layers behaves exactly
like a project that has no layer concept, and the cost of caring is one line:
put the bodies on the same layer with every mask set to `everything`.

---

## Raycasts obey the same layers

This is the part that is easy to get wrong. `castRay` takes a `Filter`
(`category_bits`, `mask_bits`), not a body type, and `System.lineOfSight` builds
that filter from the **querying** entity's layers:

```zig
// Pair: the query's own category and mask
pub fn queryCategory(self: Pair) u64 { return self.a_layer; }
pub fn queryMask(self: Pair) u64 { return self.a_mask; }
```

So a trigger volume placed on a layer the player does not see does not block
line of sight, and a pickup sensor does not block a turret's shot. Testing
line-of-sight against a preset that ignores layers is the single most confusing
thing a 2D game can ship.

---

## Tuning

`ecs.PhysicsTuning` (`collision_layers.Tuning`) — the engine-side physics knobs
that belong in project settings rather than in code:

| Field | Default | Meaning |
|---|---|---|
| `sleep_threshold_linear` | `8.0` | below this speed (units/s) a body is a sleep candidate |
| `sleep_threshold_angular` | `8.0` | below this angular speed (rad/s) likewise |
| `time_before_sleep` | `0.5` | seconds of stillness before a candidate actually sleeps |
| `solver_iterations` | `4` | per step. Fewer is faster and stacks settle worse |
| `max_physics_steps_per_frame` | `1` | the most fixed steps one frame may run |

Every one of these is validated at load, not trusted: a sleep threshold of zero
means nothing ever sleeps, which looks exactly like "the sleeping code does not
work", and zero solver iterations is a scene that never settles.

---

## A worked example

Three layers, one project:

```zig
const layers = ecs.Layers.fromNames(&.{ "default", "player", "enemy", "ground", "pickup" });

// the player: on `player`, hits ground and enemies, triggers pickups
const player = ecs.components.CollisionLayers{
    .layer = layers.bit("player").?,
    .mask = layers.maskFromNames("ground enemy pickup", null),
};

// a pickup: a sensor on `pickup`. It does not block sight because the
// player's mask includes it but its own mask is empty.
const pickup = ecs.components.CollisionLayers{
    .layer = layers.bit("pickup").?,
    .mask = nothing,
};
```

A turret asking `physics.line_of_sight` from an `enemy` whose mask is
`"ground"` sees through the pickup, the player and every other enemy — because
the filter is built from the turret's own layer and mask, exactly like a
collision.

See [physics overview](physics-overview.md) for the port underneath, and
[open world](physics-open-world.md) for what the solver decides not to think
about at all.
