# First Scene

Ember scenes are written in **`.zson`**, a canonical, bit-exact text format.
This guide covers the format, the component set, and how to build a scene
with hierarchy, sprites, and velocity.

## The `.zson` Format

A `.zson` document is a version header followed by entity blocks:

```
zson 1
entity <tag> {
  <Component> <value>
  <Component> { field: value, ... }
}
```

- **`zson 1`** -- the document version. Bump it on incompatible format changes;
  older versions keep loading (unknown fields are skipped).
- **`entity <tag>`** -- the tag is either a **number** (a scene id, stable by
  construction) or a **word** (a name, used for prefabs and overrides).
- **Components** -- one per line, in registry order. Values can be bare
  (numbers, strings, booleans) or brace-delimited structs.

### Why This Format?

- **Text, diffable, canonical.** Two identical worlds produce byte-identical
  documents: entities in slot order, components in registry order, fields in
  declaration order.
- **Floats round-trip exactly.** `{d}` formatting plus `parseFloat` inverts bit
  for bit, so the hash of a reloaded world equals the original.
- **Entity references are tags**, never volatile handles.
- **Loading is two-pass.** First pass creates all entities; second pass fills
  values. A child can reference its parent regardless of declaration order.

## The Component Set

Ember's component registry is defined in
[`src/engine/ecs/components.zig`](https://github.com/jesusalcaladev/ember-engine/blob/main/src/engine/ecs/components.zig).
The available components are:

| Component | Fields | Description |
|---|---|---|
| `Name` | `"string"` | Identity for humans; the key overrides match by. Max 32 chars. |
| `Transform` | `position`, `rotation`, `scale`, `prev_*` | Local 2D transform + previous-tick snapshot for render interpolation. |
| `Parent` | `parent: <tag>` | Hierarchy link. The parent is referenced by tag. |
| `Velocity` | `linear: {x, y}`, `angular` | Linear and angular velocity, integrated by the fixed step. |
| `Sprite` | `atlas`, `layer`, `size`, `uv`, `tint`, `order`, `blend`, `visible` | What to draw: atlas slot, layer, size, UV rect, tint, blend mode. |
| `Script` | `script: <id>` | The Lua behavior bound to this actor (a stable script cache id). |
| `StateMachine` | `machine: <id>`, `started` | A link to a Lua-defined state machine. |

### Transform Fields

```
Transform {
  position: { x: 0, y: 0 },       // world position
  rotation: 0,                     // radians, clockwise on screen
  scale: { x: 1, y: 1 },          // multiplier
  prev_position: { x: 0, y: 0 }, // previous fixed-tick snapshot
  prev_rotation: 0,
  prev_scale: { x: 1, y: 1 }
}
```

The `prev_*` fields are used by the renderer to interpolate between fixed
ticks. You normally do not set them manually -- the engine captures them at
the start of each fixed tick.

### Sprite Fields

```
Sprite {
  atlas: 0,                        // texture slot (0 = fallback white)
  layer: 0,                        // render layer (lower draws first)
  size: { x: 32, y: 32 },         // world-unit size
  uv: [0, 0, 1, 1],               // normalized atlas rect (u0, v0, u1, v1)
  tint: [1, 1, 1, 1],             // RGBA multiplier
  order: 0,                        // stable tie-break within a layer
  blend: alpha,                    // solid | alpha | additive
  visible: true                    // draw or hide without despawning
}
```

## Your First Scene

Create a file called `my_scene.zson`:

```
zson 1

entity 1 {
  Name "camera"
  Transform {position: {x: 640, y: 360}, rotation: 0, scale: {x: 1, y: 1}}
}

entity 2 {
  Name "player"
  Transform {position: {x: 100, y: 200}, rotation: 0, scale: {x: 2, y: 2}}
  Parent {parent: 1}
  Velocity {linear: {x: 5, y: 0}, angular: 0}
  Sprite {atlas: 0, layer: 0, size: {x: 32, y: 32}, tint: [1, 1, 1, 1], blend: alpha, visible: true}
}

entity 3 {
  Name "enemy"
  Transform {position: {x: 400, y: 200}, rotation: 0.5, scale: {x: 1, y: 1}}
  Parent {parent: 1}
  Velocity {linear: {x: -3, y: 2}, angular: 0.1}
  Sprite {atlas: 0, layer: 1, size: {x: 16, y: 16}, tint: [1, 0.5, 0.5, 1], blend: alpha, visible: true}
}
```

This scene has:

1. A **camera** entity at the center of a 1280x720 screen.
2. A **player** sprite (32x32, scale 2) that moves right at 5 units/sec.
3. An **enemy** sprite (16x16, reddish tint) that moves left and rotates.

Both the player and enemy are children of the camera, so they inherit its
position as a world-space offset.

## Loading a Scene

The engine loads `.zson` files via the `zson.decode` function (in Zig) or
automatically when the runtime starts with a scene file. The canonical sample
scene is at
[`samples/scene.zson`](https://github.com/jesusalcaladev/ember-engine/blob/main/samples/scene.zson),
which demonstrates 25 sprites with hierarchy and velocity.

## Prefabs and Overrides

A prefab is a `.zson` document with a **word tag** (a name). When you apply it
to a world, a new entity is created with that name. Applying the same prefab
again **patches** the existing entity by name -- only the fields present in
the document are overwritten.

### Example: Prefab Definition

```
zson 1
entity enemy {
  Name "enemy"
  Transform {position: {x: 0, y: 0}, rotation: 0, scale: {x: 1, y: 1}}
  Velocity {linear: {x: 3, y: 0}, angular: 0}
  Sprite {size: {x: 16, y: 16}, blend: alpha}
}
```

### Example: Override

```
zson 1
entity enemy {
  Transform {position: {x: 100, y: 200}}
}
```

This finds the entity named `enemy` and patches only its `Transform.position`.
All other fields (velocity, sprite, name) keep their current values.

### Scene Overrides with Scene Ids

When the editor writes an override for a saved scene, it uses **numeric tags**
(scene ids) instead of names:

```
zson 1
entity 3 {
  Transform {position: {x: 500, y: 300}}
}
```

This patches the entity with scene id 3, regardless of its name.

## Entity References

Entity references (like `Parent.parent`) are written as **tags**:

- In a **saved scene**, tags are scene ids (numbers): `Parent {parent: 1}`.
- In a **prefab**, tags are names (words): `Parent {parent: "root"}`.

The two-pass loader resolves references regardless of declaration order, so
a child can appear before its parent in the file.

## The Canonical Hash

Every `.zson` document has a canonical hash (`zson.hash`) computed from the
encoded bytes. Because the format is deterministic:

- Saving and reloading a scene produces the **same hash**.
- Two worlds with the same spawn order and values produce the **same bytes**.
- This is what makes undo/redo, Play-in-editor snapshots, and CI regression
  checks possible.

## Next Steps

- [First Script](first-script.md) -- bring your scene to life with Lua behaviors.
- [Learning Lua](../guides/learning-lua.md) -- the complete Lua guide for Ember.
