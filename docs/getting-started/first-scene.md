# Understanding Scenes

Scenes in Ember are described in **`.zson`**, a custom text format. The
Ember Editor generates `.zson` files automatically as you build your scene
visually. This guide will teach you the format, explain the design decisions
behind it, and show you how scenes represent hierarchy, sprites, and velocity.

> **Editor Note:** You do not write `.zson` files by hand. The Ember Editor
> generates them as you add entities, position sprites, attach scripts, and
> set up hierarchy visually. Understanding the format helps you debug issues,
> read diffs, and appreciate what the editor is doing under the hood -- but
> the editor does the writing for you.

> **What you will accomplish:** By the end of this guide, you will understand
> every part of a `.zson` file, know why the format is designed the way it
> is, and understand how the editor represents scenes with multiple entities,
> parent-child relationships, and per-entity behavior scripts.

---

## What the Editor Does

The Ember Editor is a visual scene builder. When you use it, you never write
`.zson` by hand. Instead, you:

- **Add entities** by clicking or dragging -- the editor creates entity blocks.
- **Position and scale** using handles in the viewport -- the editor writes
  `Transform` components.
- **Attach sprites** by choosing textures and setting sizes -- the editor
  writes `Sprite` components.
- **Set up hierarchy** by dragging entities onto parents -- the editor writes
  `Parent` components.
- **Attach behaviors** by selecting scripts from a list -- the editor writes
  `Script` components.

When you save, the editor serializes the entire scene into a `.zson` file
using the canonical format described below. When you open a `.zson` file in
the editor, it reads the file and rebuilds the visual representation.

Understanding `.zson` helps you:

- **Debug** -- when something goes wrong, you can read the `.zson` file and
  see exactly what the editor produced.
- **Use version control** -- `.zson` is text, so Git diffs are readable.
- **Appreciate the design** -- the format has deliberate choices that make
  the engine fast and reliable.

---

## The `.zson` Format

A `.zson` document is a version header followed by entity blocks. Here is
the skeleton:

```
zson 1

entity <tag> {
  <Component> <value>
  <Component> { field: value, ... }
}
```

Let us understand each piece:

### The Version Header

```
zson 1
```

The first line of every `.zson` file is `zson` followed by a number. This
is the **format version**. It tells the engine "this file uses version 1
of the ZSON format."

> **Why does this matter?** Game engines evolve. Fields get added, removed,
> or renamed. Without a version number, the engine would have no way to
> know whether an old file should be loaded with old rules or new rules.
> The version lets the engine load old files correctly even after the format
> changes. Unknown fields in newer files are skipped when loading older
> versions -- this is called **forward compatibility**.

### Entity Blocks

```
entity 1 {
  Name "player"
  Transform {position: {x: 100, y: 100}, rotation: 0, scale: {x: 1, y: 1}}
  Sprite {atlas: 0, layer: 0, size: {x: 32, y: 32}, tint: [1, 1, 1, 1], blend: alpha, visible: true}
  Script {script: 1}
}
```

Each `entity` block declares one entity. The number or word after `entity`
is called the **tag**. The tag is how entities refer to each other -- for
example, a child entity uses its tag to point to its parent.

- A **numeric tag** (like `1`, `2`, `3`) is a **scene id**. These are
  stable by construction -- they never change even if you edit the file.
  They are used in saved scenes.
- A **word tag** (like `enemy`, `player`, `root`) is a **name**. These
  are used in prefabs (reusable entity templates) and overrides (patches
  to existing entities).

> **What's Happening Behind the Scenes:** When the engine parses a `.zson`
> file, it creates entities in an **Archetype ECS**. An archetype is a
> "shape" -- a specific set of components. All entities with the same
> components are stored together in memory, which makes iteration extremely
> fast. When you add or remove a component, the entity moves to a different
> archetype. This is why the engine can process thousands of entities per
> frame without slowing down.

### Components

Inside an entity block, each line is a **component**. A component is a
named bundle of data. Ember has a fixed set of components (defined in
`src/engine/ecs/components.zig`), and each one has specific fields.

Component values can be:

- **Bare values** -- numbers (`0`, `3.14`), strings (`"player"`), or
  booleans (`true`, `false`).
- **Brace-delimited structs** -- grouped fields like
  `{x: 100, y: 100}`.
- **Bracket-delimited arrays** -- lists like `[1, 1, 1, 1]`.

---

## The Design of `.zson`: Why Text? Why Canonical? Why Two-Pass?

The `.zson` format was designed with three goals in mind. Each goal shaped
the format in a specific way. Let us explore each one.

### Why Text?

You might wonder: why not use a binary format? Binary would be faster to
load and smaller on disk. The answer is **human readability and
debuggability**.

> **What's Happening Behind the Scenes:** When you are debugging a scene,
> you need to be able to open the file and see what is in it. A binary
> format would require special tools just to view the contents. With a
> text format, you can open any `.zson` file in any text editor and
> immediately understand the scene. This saves hours of development time.
>
> Text also means **diff-friendly**. When you use Git (a version control
> system), changes to `.zson` files show up as clear, line-by-line diffs.
> Merge conflicts are readable and resolvable. With binary files, Git can
> only tell you "these files differ" -- you would have no idea what
> changed.
>
> The tradeoff is that text files are larger and slower to parse than
> binary. But for scene files, which are typically small (kilobytes, not
> megabytes), this tradeoff is well worth it. The engine parses `.zson`
> files in microseconds -- the performance cost is negligible.

### Why Canonical?

A **canonical** format means that there is exactly one correct way to
write any given scene. Two files that describe the same world will be
**byte-for-byte identical**.

The format achieves canonical form through three rules:

1. **Entities appear in slot order** -- the order they were created.
2. **Components appear in registry order** -- a fixed order defined by the
   engine, not the order you write them.
3. **Fields appear in declaration order** -- the order the fields are
   defined in the component struct.

> **Why is this important?** Canonical form enables **deterministic
> hashing**. The engine can compute a hash of any `.zson` file, and two
> files that describe the same world will have the same hash. This powers
> three critical features:
>
> - **Undo/Redo** -- The engine can hash the world before and after an
>   edit. If the hash is the same, nothing changed. If it differs, the
>   engine knows exactly what to undo.
> - **Play-in-Editor Snapshots** -- When you press Play in the editor,
>   the engine saves the current world state. When you stop, it restores
>   that state by reloading the hashed snapshot. No data is lost.
> - **CI Regression Checks** -- Automated tests can hash a scene before
>   and after a test run. If the hash changes unexpectedly, the test
>   fails, alerting developers to unintended side effects.
>
> Without canonical form, none of these features would be reliable. A
> non-canonical format might produce different bytes for the same world
> (e.g., if entity order were unpredictable), making hashes useless.

### Why Two-Pass Loading?

When the engine loads a `.zson` file, it does not simply read entities
one by one and fill in their data. Instead, it uses a **two-pass** approach:

- **Pass 1: Create all entities.** The engine reads the file and creates
  every entity with its tag, but does not fill in component values yet.
- **Pass 2: Fill in values.** The engine goes through the file again and
  fills in each entity's components.

> **Why two passes?** Consider a parent-child relationship:
>
> ```
> entity 1 {
>   Name "player"
>   Parent {parent: 2}
> }
>
> entity 2 {
>   Name "camera"
> }
> ```
>
> Here, entity 1 references entity 2 as its parent. But entity 2 has not
> been created yet when the engine reads entity 1! With a single pass, the
> engine would fail because the reference is dangling.
>
> With two passes, the engine first creates entities 1 and 2 (knowing their
> tags), then in the second pass fills in the `Parent {parent: 2}` reference.
> By the second pass, entity 2 exists, so the reference resolves correctly.
>
> This means **declaration order does not matter**. A child can appear
> before its parent in the file, and everything still works.

### Floats Round-Trip Exactly

Floating-point numbers (like `3.14159`) are tricky in computing. Different
systems can represent them slightly differently, which means a value
written as `0.1` might reload as `0.10000000000000001`.

`.zson` solves this with a `{d}` formatting specifier combined with a
matching `parseFloat` on load. The result is **bit-exact round-tripping**:
a float written to a file and read back will be the exact same bits in
memory. This is essential for the canonical hash -- if floats changed
even slightly on reload, the hash would differ, and undo/redo would break.

---

## The Component Set

Ember's component registry is defined in
[`src/engine/ecs/components.zig`](https://github.com/jesusalcaladev/ember-engine/blob/main/src/engine/ecs/components.zig).
This file is the single source of truth for what components exist and what
fields they have. The available components are:

| Component | Fields | Description |
|---|---|---|
| `Name` | `"string"` | Identity for humans; the key overrides match by. Max 32 chars. |
| `Transform` | `position`, `rotation`, `scale`, `prev_*` | Local 2D transform + previous-tick snapshot for render interpolation. |
| `Parent` | `parent: <tag>` | Hierarchy link. The parent is referenced by tag. |
| `Velocity` | `linear: {x, y}`, `angular` | Linear and angular velocity, integrated by the fixed step. |
| `Sprite` | `atlas`, `layer`, `size`, `uv`, `tint`, `order`, `blend`, `visible` | What to draw: atlas slot, layer, size, UV rect, tint, blend mode. |
| `Script` | `script: <id>` | The Lua behavior bound to this actor (a stable script cache id). |
| `StateMachine` | `machine: <id>`, `started` | A link to a Lua-defined state machine. |

Let us look at the most important ones in detail.

### Transform Fields

```
Transform {
  position: { x: 0, y: 0 },         -- world position
  rotation: 0,                       -- radians, clockwise on screen
  scale: { x: 1, y: 1 },            -- multiplier
  prev_position: { x: 0, y: 0 },   -- previous fixed-tick snapshot
  prev_rotation: 0,
  prev_scale: { x: 1, y: 1 }
}
```

The `prev_*` fields are **previous-tick snapshots**. Here is why they
exist:

> **What's Happening Behind the Scenes:** The engine updates game logic at
> a fixed rate (60 times per second), but your monitor may refresh at a
> different rate (e.g., 144 Hz). Without interpolation, the sprite would
> appear to stutter because the simulation updates at 60 Hz while the
> display refreshes at 144 Hz.
>
> To fix this, the renderer **interpolates** between the previous tick's
> position and the current tick's position. For example, if a sprite was
> at x=100 last tick and x=103 this tick, and the display refreshes halfway
> between ticks, the renderer draws it at x=101.5.
>
> The `prev_*` fields store where the entity was at the start of the
> current fixed tick. The engine captures them automatically -- you
> normally do not set them manually.

### Sprite Fields

```
Sprite {
  atlas: 0,                          -- texture slot (0 = fallback white)
  layer: 0,                          -- render layer (lower draws first)
  size: { x: 32, y: 32 },           -- world-unit size
  uv: [0, 0, 1, 1],                 -- normalized atlas rect (u0, v0, u1, v1)
  tint: [1, 1, 1, 1],               -- RGBA multiplier
  order: 0,                          -- stable tie-break within a layer
  blend: alpha,                      -- solid | alpha | additive
  visible: true                      -- draw or hide without despawning
}
```

- **`atlas`** -- A texture slot. Slot 0 is always a built-in white square,
  which is perfect for testing. Higher slots reference textures you load
  at runtime.
- **`layer`** -- The render layer. Lower numbers draw first (behind), higher
  numbers draw last (in front). This is like z-index in CSS.
- **`uv`** -- A sub-rectangle of the atlas texture, in normalized
  coordinates (0 to 1). `[0, 0, 1, 1]` means "use the entire texture."
  If you have a sprite sheet (multiple sprites in one image), you would
  use a smaller rect like `[0, 0, 0.25, 0.25]` for the top-left quarter.
- **`tint`** -- A color multiplier. `[1, 1, 1, 1]` is white (no change).
  `[1, 0, 0, 1]` would make the sprite red. `[1, 1, 1, 0.5]` would make
  it semi-transparent.
- **`blend`** -- How the sprite blends with what is behind it:
  - `solid` -- No transparency; overwrites everything.
  - `alpha` -- Standard transparency (most common).
  - `additive` -- Adds color to what is behind (good for glows, fire,
    lasers).

---

## Your First Scene

Let us look at a real scene. In the Ember Editor, you would create this scene
by adding entities, positioning them, and attaching sprites -- the editor
generates the following `.zson` for you:

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

This scene has three entities:

1. **A camera** at position (640, 360) -- the center of a 1280x720
   screen. The camera does not have a Sprite or Script; it is just an
   anchor point. Children of the camera use its position as a world-space
   offset.

2. **A player** sprite (32x32, scaled 2x so it appears 64x64). It has a
   `Velocity` component with `linear: {x: 5, y: 0}`, meaning it moves
   right at 5 units per second. The engine's fixed step integrates this
   velocity automatically -- you do not need to write a script for basic
   movement.

3. **An enemy** sprite (16x16, reddish tint `[1, 0.5, 0.5, 1]`). It
   moves left and down (`{x: -3, y: 2}`) and rotates at 0.1 radians per
   second (`angular: 0.1`).

Both the player and enemy are **children** of the camera via the
`Parent {parent: 1}` component. This means their positions are relative
to the camera. If the camera moves to (700, 400), the player moves to
(160, 240) -- maintaining the same offset.

> **What's Happening Behind the Scenes:** When the engine processes a
> parent-child relationship, it computes the child's **world position** by
> combining the parent's world position with the child's local position.
> This is called a **transform hierarchy**. The engine traverses the
> hierarchy each frame, updating children before parents, so that world
> positions are always correct. This is the same technique used in Unity,
> Unreal, and Godot.

---

## Loading a Scene

The engine loads `.zson` files via the `zson.decode` function (in Zig) or
automatically when the runtime starts with a scene file. In the editor, this
happens automatically when you open a scene or press Play. From the command
line:

```bash
zig build run -- my_scene.zson
```

The engine calls `zson.decode`, which reads the file, creates all entities
and components, resolves parent references, and returns a fully populated
world. The engine then enters its game loop, calling `update` on every
script and rendering every sprite.

The canonical sample scene is at
[`samples/scene.zson`](https://github.com/jesusalcaladev/ember-engine/blob/main/samples/scene.zson),
which demonstrates 25 sprites with hierarchy and velocity. You can use it
as a reference for more complex scenes.

---

## Prefabs and Overrides

A **prefab** is a reusable entity template. It is a `.zson` document with a
**word tag** (a name) instead of a numeric scene id.

### Prefab Definition

```
zson 1
entity enemy {
  Name "enemy"
  Transform {position: {x: 0, y: 0}, rotation: 0, scale: {x: 1, y: 1}}
  Velocity {linear: {x: 3, y: 0}, angular: 0}
  Sprite {size: {x: 16, y: 16}, blend: alpha}
}
```

This defines a reusable "enemy" template. When you apply this prefab to a
world, a new entity is created with the name `enemy`.

### Override

```
zson 1
entity enemy {
  Transform {position: {x: 100, y: 200}}
}
```

When you apply this override, the engine finds the entity named `enemy`
and **patches** it -- only the fields present in the document are
overwritten. All other fields (velocity, sprite, name) keep their current
values. This is incredibly powerful: you can create a base enemy prefab,
then override just the position for each individual enemy in a scene.

### Scene Overrides with Scene Ids

When the editor writes an override for a saved scene, it uses **numeric
tags** (scene ids) instead of names:

```
zson 1
entity 3 {
  Transform {position: {x: 500, y: 300}}
}
```

This patches the entity with scene id 3, regardless of its name. This is
more robust than name-based overrides because names can change, but scene
ids are stable.

> **Troubleshooting: "My override is not applying."**
>
> Make sure the tag in your override matches an existing entity. If you
> use a word tag (prefab style), the engine looks for an entity with that
> **Name** component. If you use a numeric tag, the engine looks for an
> entity with that **scene id**. Mixing these up is a common mistake.

---

## Entity References

Entity references (like `Parent.parent`) are written as **tags**:

- In a **saved scene**, tags are scene ids (numbers): `Parent {parent: 1}`.
- In a **prefab**, tags are names (words): `Parent {parent: "root"}`.

The two-pass loader resolves references regardless of declaration order,
so a child can appear before its parent in the file. This is why the
two-pass approach matters -- it decouples "what exists" from "how things
are connected."

---

## The Canonical Hash

Every `.zson` document has a canonical hash (`zson.hash`) computed from
the encoded bytes. Because the format is deterministic:

- Saving and reloading a scene produces the **same hash**.
- Two worlds with the same spawn order and values produce the **same bytes**.
- This is what makes undo/redo, Play-in-editor snapshots, and CI regression
  checks possible.

> **What's Happening Behind the Scenes:** The hash is computed by encoding
> the world state back into canonical `.zson` bytes and then hashing those
> bytes. Because the encoding is deterministic (entities in slot order,
> components in registry order, fields in declaration order), the hash is
> stable. If you change any value -- even a single float -- the hash
> changes. This lets the engine detect any change, no matter how small.

---

## Try These Exercises

### Exercise 1: Add a Background

Add a large sprite behind everything. Give it a lower layer (so it draws
first) and a neutral color:

```
entity 4 {
  Name "background"
  Sprite {atlas: 0, layer: -1, size: {x: 1280, y: 720}, tint: [0.2, 0.2, 0.3, 1], blend: alpha, visible: true}
}
```

Run the scene. You should see a dark blue background behind the sprites.

> **What you learned:** Layer -1 draws behind layer 0. The sprite is large
> (1280x720) and tinted dark blue.

### Exercise 2: Make the Enemy Orbit the Player

Change the enemy's velocity to make it circle the player. You will need to
use a script for this. In the editor, you would attach a behavior to the
enemy entity and the editor would generate this Lua for you:

```lua
local M = {}

function M:start()
  self.center = 1  -- scene id of the player
  self.radius = 100
  self.angle = 0
  self.speed = 2  -- radians per second
end

function M:update(dt)
  self.angle = self.angle + self.speed * dt
  local px, py = actor.get_position_by_tag(self, self.center)
  local x = px + math.cos(self.angle) * self.radius
  local y = py + math.sin(self.angle) * self.radius
  actor.set_position(self, x, y)
end

return M
```

Attach it to the enemy in your scene file by adding `Script {script: 2}`.
You will need to register this script as id 2.

> **What you learned:** You can compute positions mathematically and set
> them directly. Trigonometry (`math.cos`, `math.sin`) lets you create
> circular motion.

### Exercise 3: Reproduce the Two-Pass Loader

In the editor, create a scene where the child appears before the parent.
The editor generates the following `.zson`:

```
zson 1

entity 1 {
  Name "child"
  Parent {parent: 2}
}

entity 2 {
  Name "parent"
}
```

Run this scene. It should load without errors, proving that the two-pass
loader resolves references regardless of order.

> **What you learned:** The engine creates all entities first, then fills
> in references. Declaration order does not matter.

---

## Next Steps

- **[Understanding Behaviors](first-script.md)** -- Bring your scene to life
  with Lua behaviors. Learn the behavior lifecycle, the `self` table, and the
  full engine API.
- **[Learning Lua](../guides/learning-lua.md)** -- Master Lua from zero,
  including all the concepts used in Ember scripts.

You now understand the `.zson` format at a deep level -- not just the
syntax, but the design decisions behind it. This foundation will serve you
well as you use the editor to build more complex scenes.
