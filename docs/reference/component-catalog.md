# Component Catalog

**Source:** `src/engine/ecs/components/` (one file per component) + `src/engine/ecs/components/registry.zig` (the registry)

Every component the engine has, what it is for, which system drives it, which Lua bindings touch it, and — the part that matters most — **what it connects to**.

Read this file when you are about to ask "which component do I need for this?" and the answer is not obvious. The [Component Registry](ecs-components.md) document explains *how* components are registered; this one explains *what they are*.

---

## Table of contents

- [How to read an entry](#how-to-read-an-entry)
- [The registry in one table](#the-registry-in-one-table)
- [Identity and simulation](#identity-and-simulation)
  - [Name](#name--id-0)
  - [Transform](#transform--id-1)
  - [Parent](#parent--id-2)
  - [Velocity](#velocity--id-3)
- [Rendering](#rendering)
  - [Sprite](#sprite--id-4)
  - [ShaderMaterial](#shadermaterial--id-5)
- [Behaviour and timing](#behaviour-and-timing)
  - [Script](#script--id-6)
  - [StateMachine](#statemachine--id-7)
  - [Timer](#timer--id-19)
  - [AnimationPlayer](#animationplayer--id-22)
- [Physics](#physics)
  - [RigidBody2D](#rigidbody2d--id-8)
  - [Collider2D](#collider2d--id-9)
  - [CollisionLayers](#collisionlayers--id-10)
- [Lighting](#lighting)
  - [LightBase (shared, not a component)](#lightbase-shared-not-a-component)
  - [Light2D (legacy)](#light2d-legacy--id-11)
  - [LightOccluder2D](#lightoccluder2d--id-12)
  - [Environment](#environment--id-13)
  - [PointLight2D](#pointlight2d--id-14)
  - [SpotLight2D](#spotlight2d--id-15)
  - [DirectionalLight2D](#directionallight2d--id-16)
  - [AmbientLight2D](#ambientlight2d--id-17)
- [Camera](#camera)
  - [Camera2D](#camera2d--id-18)
- [Audio and particles](#audio-and-particles)
  - [SoundEmitter2D](#soundemitter2d--id-20)
  - [ParticleEmitter2D](#particleemitter2d--id-21)
- [Game UI](#game-ui)
  - [UiCanvas](#uicanvas--id-23)
  - [Label](#label--id-24)
  - [UiButton](#uibutton--id-25)
  - [UiPanel](#uipanel--id-26)
  - [UiProgressBar](#uiprogressbar--id-27)
- [Parked: TileMapLayer](#parked-tilemaplayer)
- [The wiring: who reads whom](#the-wiring-who-reads-whom)
- [The frame, in order](#the-frame-in-order)
- [Gotcha index](#gotcha-index)

---

## How to read an entry

Each component gets:

1. **What it is** — in gameplay terms, not a restatement of the fields.
2. **Fields** — name, type, default, and what the field *means*.
3. **The system that drives it** — and when in the frame it runs.
4. **The Lua bindings** — what a script can do with it.
5. **What it connects to** — the other components it reads or requires.
6. **Gotchas** — the things that bite.

**The Lua calling convention**: every module function takes `self` as argument 1. `sprite.set_size(self, 40, 24)`, `actor.set_position(self, 10, 20)`. A `self` is the behavior's table, and it carries the entity handle.

---

## The registry in one table

| id | Registry name | Zig type | File | What it is for |
|---|---|---|---|---|
| 0 | `Name` | `Name` | `name.zig` | The actor's name in the scene file and the inspector |
| 1 | `Transform` | `Transform` | `transform.zig` | Where it is and how it is turned |
| 2 | `Parent` | `Parent` | `hierarchy.zig` | Who it hangs off |
| 3 | `Velocity` | `Velocity` | `hierarchy.zig` | Drift, for a body that does not collide |
| 4 | `Sprite` | `Sprite` | `sprite.zig` | What it looks like |
| 5 | `ShaderMaterial` | `ShaderMaterial` | `material.zig` | A shared custom-shader hook (**no consumer yet**) |
| 6 | `Script` | `Script` | `script.zig` | The Lua behaviour attached to it |
| 7 | `StateMachine` | `StateMachine` | `script.zig` | A handle to a Lua-defined state machine |
| 8 | `RigidBody2D` | `RigidBody2D` | `physics.zig` | "This is a physical object" |
| 9 | `Collider2D` | `Collider2D` | `physics.zig` | The shape it collides with |
| 10 | `CollisionLayers` | `CollisionLayers` | `physics.zig` | Which groups it talks to |
| 11 | `Light2D` | `Light2D` | `light.zig` | The legacy all-in-one light |
| 12 | `LightOccluder2D` | `LightOccluder2D` | `light.zig` | "This blocks light" |
| 13 | `Environment` | `Environment` | `light.zig` | The world's light level and post mood |
| 14 | `PointLight2D` | `PointLight2D` | `light.zig` | A lamp |
| 15 | `SpotLight2D` | `SpotLight2D` | `light.zig` | A cone of light |
| 16 | `DirectionalLight2D` | `DirectionalLight2D` | `light.zig` | The sun |
| 17 | `AmbientLight2D` | `AmbientLight2D` | `light.zig` | Light from everywhere |
| 18 | `Camera2D` | `Camera2D` | `camera.zig` | The window onto the world |
| 19 | `Timer` | `Timer` | `timer.zig` | "In N seconds, fire this signal" |
| 20 | `SoundEmitter2D` | `SoundEmitter2D` | `sound_emitter.zig` | A sound that belongs to a place |
| 21 | `ParticleEmitter2D` | `ParticleEmitter2D` | `particle.zig` | The recipe for a particle effect |
| 22 | `AnimationPlayer` | `AnimationPlayer` | `animation.zig` | Clip playback state |
| 23 | `UiCanvas` | `UiCanvas` | `ui.zig` | The virtual resolution of the HUD |
| 24 | `Label` | `Label` | `ui.zig` | A run of text |
| 25 | `UiButton` | `UiButton` | `ui.zig` | A clickable box |
| 26 | `UiPanel` | `UiPanel` | `ui.zig` | A filled box |
| 27 | `UiProgressBar` | `UiProgressBar` | `ui.zig` | A 0..1 bar |
| — | `TileMapLayer` | — | `tilemap.zig` | **Parked**: not registered |

> **The dense id is the on-disk format.** A `.zson` file stores `Timer { ... }`, and the id is what the decoder looks up. Adding a component means APPENDING a line to the registry — never inserting, which would renumber every committed scene.

---

## Identity and simulation

### `Name` — id 0

**What it is:** a short label baked into the actor, so a designer, a debugger and the scene file can refer to it. It is the key `.zson` overrides match by, and the name the inspector shows.

| Field | Type | Default | Meaning |
|---|---|---|---|
| `bytes` | `[32]u8` | zeroed | The name, inline, NUL-padded |
| `len` | `u8` | `0` | How many bytes are valid |

**Driven by:** nothing — passive data. Written by the `.zson` decoder and by `Actor.setName`.

**Lua:** `actor.get_name(self)`. There is **no** `actor.set_name`: a name comes from a scene file or from Zig.

**Connects to:** the `.zson` override mechanism and the editor.

**Gotcha:** names longer than 32 bytes are **truncated silently**; a duplicate name in a document is uniquified at load.

---

### `Transform` — id 1

**What it is:** where an actor is and how it is oriented. Almost every visual component draws relative to it, so this is the one component nearly every actor has.

| Field | Type | Default | Meaning |
|---|---|---|---|
| `position` | `Vec2` | `{0,0}` | Local position (world position once the parent chain is resolved) |
| `rotation` | `f32` | `0` | Radians, positive clockwise (screen y grows down) |
| `scale` | `Vec2` | `{1,1}` | Multiplies `Sprite.size` |
| `prev_position` | `Vec2` | `{0,0}` | The position at the previous fixed tick |
| `prev_rotation` | `f32` | `0` | The rotation at the previous fixed tick |
| `prev_scale` | `Vec2` | `{1,1}` | The scale at the previous fixed tick |

**Driven by:** gameplay, physics, animation root motion and scripts. **Read per frame** by the renderer, which blends `prev → current` with the interpolation factor.

**Lua:** `actor.get_position`, `actor.set_position`, `actor.translate`, `actor.move_by`, `actor.get_rotation`, `actor.set_rotation`, `actor.set_transform(self, x, y, rot?, scale?)`, `actor.get_all`.

**Connects to:** `Sprite` (position + scale → pixels), `Camera2D` (the follow target's transform is what the camera chases), `RigidBody2D` (the solver writes it back), `Parent` (the hierarchy resolver folds local transforms), the lights (position + rotation place them), `ParticleEmitter2D` (the spawn point), `AnimationPlayer` (value tracks and root motion write it), and the **tweens** (`tween.to(self, "position.x", ...)`).

**Gotchas:**
- `prev_*` is **not** writable from Lua, on purpose: `actor.set_transform` deliberately leaves it alone so a teleport interpolates across one tick instead of smearing.
- `prev_*` is captured by `world.captureTransforms()` at the **start of every fixed step**. Without that call the renderer blends from the spawn position and every moving actor drags a line back to where it was born.

---

### `Parent` — id 2

**What it is:** one link saying "this actor hangs off that one". It is the only thing stored per entity about hierarchy; the world transform of the chain is derived, never stored, so re-parenting never costs a structural change.

| Field | Type | Default | Meaning |
|---|---|---|---|
| `parent` | `Entity` | `Entity.invalid` | The parent. Invalid (or dead) means "root". |

**Driven by:** `ecs/hierarchy.zig` — a flat, iterative, allocation-free breadth-first pass that seeds each entity's world transform from its local one and folds each child into its parent.

**Lua:** **no bindings.** Parenting is a Zig-only operation today (`Actor.setParent`), which refuses self-parenting and cycles.

**Connects to:** `Transform` (the resolver needs both).

**Gotcha:** the resolver is opt-in (`World.enableHierarchy()`), and the shipped runtime's frame loop does not call it — the renderer composes from the *local* transform.

---

### `Velocity` — id 3

**What it is:** linear and angular speed for an actor that moves **without** colliding. Reach for it when something should drift, scroll or spin and must not push anything.

| Field | Type | Default | Meaning |
|---|---|---|---|
| `linear` | `Vec2` | `{0,0}` | Units per second |
| `angular` | `f32` | `0` | Radians per second |

**Driven by:** **no engine system**. The camera reads it for look-ahead; the benchmark integrates it by hand.

**Lua:** **no bindings.** `actor.set_linear_velocity` goes through the **physics** system, not this component.

**Connects to:** `Camera2D.look_ahead`.

**Gotcha:** adding a `Velocity` to a scene file does **nothing** on its own. Use `RigidBody2D` for anything that must actually move.

---

## Rendering

### `Sprite` — id 4

**What it is:** "draw this". The whole visual description of an actor: what picture, how big, what colour, in what order. Position is not here — that is `Transform`. Use `shape = .circle` or a plain white quad to prototype before the art exists.

| Field | Type | Default | Meaning |
|---|---|---|---|
| `atlas` | `u8` | `0` | Texture slot. Slot 0 is the fallback white texture, so a sprite with no atlas still draws |
| `layer` | `u16` | `0` | Render layer; lower draws first. The batcher groups equal values into one draw call |
| `size` | `Vec2` | `{1,1}` | Size in world units; `Transform.scale` multiplies it |
| `shape` | `SpriteShape` | `.quad` | `quad` (0) or `circle` (1) |
| `uv` | `[4]f32` | `{0,0,1,1}` | Atlas rect, normalized `(u0,v0,u1,v1)` |
| `tint` | `[4]f32` | `{1,1,1,1}` | RGBA multiplied with the texel |
| `order` | `i32` | `0` | Stable tie-break inside a layer |
| `blend` | `Blend` | `.alpha` | `solid` (no blending, early-Z), `alpha` (source-over), `additive` (glows) |
| `visible` | `bool` | `true` | Draw nothing without despawning |
| `coverage_index` | `i32` | `-1` | The lighting system's sprite-coverage slot, or −1 for none |

**Driven by:** `render/2d.zig` — `collectFiltered`, **per frame**. It queries `(Transform, Sprite)`, skips invisible sprites, applies residency and frustum culling, interpolates the transform, and writes a 32-byte GPU instance.

**Lua:** `sprite.rect`, `sprite.circle`, `sprite.texture`, `sprite.set_size`, `sprite.set_tint(self, r, g, b, a)`, `sprite.set_uv`, `sprite.set_atlas`, `sprite.set_image(path)`, `sprite.set_shape`, `sprite.set_blend`, `sprite.set_layer`, `sprite.set_visible`, `sprite.get_size`, `sprite.get_tint`.

**Connects to:** `Transform` (**required** — the draw query is the pair), `LightBase.item_cull_mask` (the light's mask is a bitmask of `Sprite.layer`), `LightOccluder2D` in `auto_sdf` mode (the occluder rasterizes the sprite's alpha), and the **tweens** (`tween.to(self, "tint.a", 0, 0.3)` fades a sprite out).

**Gotchas:**
- `tint` is a **4-float RGBA**, not RGB.
- `Sprite.order` is used only by the **editor's** viewport picking, not by the runtime renderer (which orders by `layer`).
- `layer` is clamped to a byte in the GPU instance, so an out-of-range layer becomes 255 — the "every light" wildcard.

---

### `ShaderMaterial` — id 5

**What it is:** a hook for a user-authored shader, held on its own entity so many sprites can share one material.

| Field | Type | Default | Meaning |
|---|---|---|---|
| `shader` | `u16` | `0` | Index into the runtime's shader table. 0 is the stock sprite shader |
| `params` | `[4]f32` | `{0,0,0,0}` | Four floats: a colour, a dissolve threshold, a time… |
| `owner_scene` | `SceneId` | `0` | The entity whose material this is, for the inspector |

**Driven by:** **nothing.** No renderer, batcher or shader-selection code reads it.

**Lua:** `material.new(self, shader)`, `material.set_params(self, p0..p3)`, `material.get_params(self)`, `material.get_shader(self)`.

**Connects to:** nothing yet.

**Gotcha:** the component is a **hook with no consumer**. Setting a non-zero shader has no verified effect anywhere.

---

## Behaviour and timing

### `Script` — id 6

**What it is:** the serializable link between an actor and the Lua behaviour attached to it. It stores a **stable script id**, never a VM reference, so a scene file can say "this actor runs player.lua" and survive a save bit-exactly.

| Field | Type | Default | Meaning |
|---|---|---|---|
| `script` | `u32` | `0` | Index into the script cache. 0 means "no script" |

**Driven by:** `script/behavior.zig` — `Behaviors.attach` adds it. The live Lua state (`self` table, cached method refs) lives in the script subsystem, keyed off this component.

**Lua:** no direct binding. It is written by the engine.

**Connects to:** the script cache and the `Behaviors` instance list.

---

### `StateMachine` — id 7

**What it is:** a handle to a finite state machine **defined in Lua** (states, transitions and their callbacks are script data, not component data). Reach for it for enemy AI, boss phases, spawner cycles, game flow — anything with named states and event-driven transitions.

| Field | Type | Default | Meaning |
|---|---|---|---|
| `machine` | `u32` | `0` | Index into the engine's state-machine registry. 0 = "none" |
| `started` | `bool` | `false` | True once the machine has been entered |

**Driven by:** `script/statemachine.zig`. The component is only the index; the registry owns the states, transitions and Lua callback refs.

**Lua:** `sm.add_state(self, name, hooks?)` (creates the machine **and** the component), `sm.add_transition(self, from, event, to)`, `sm.set_initial(self, name)`, `sm.fire(self, event)`, `sm.set_state(self, name)`, `sm.state(self)`, `sm.is_in(self, name)`.

**Connects to:** the state-machine registry and, through it, the behaviour's `self` table.

**Gotchas:**
- It is a **handle**, forced by the registry rule "plain data only" (a machine holds names and callbacks).
- There is **no global machine**: `sm.*` is per entity. A game-flow machine is a *global script* (see [Global Scripts](global-scripts.md)) or an actor with a `StateMachine`.
- A transition is applied at the **top of the next tick**, so firing from inside a callback cannot re-enter the machine.

---

### `Timer` — id 19

**What it is:** a gameplay clock that fires **named signals** instead of calling back. Reach for it whenever you would write "in 3 seconds, do X": cooldowns, respawn waves, a telegraph that must finish, a status that refreshes.

| Field | Type | Default | Meaning |
|---|---|---|---|
| `duration` | `f32` | `1.0` | Seconds per cycle |
| `elapsed` | `f32` | `0.0` | Seconds accumulated in the current cycle |
| `kind` | `TimerType` | `.once` | `once` (0), `loop` (1), `during` (2) |
| `loop_count` | `u32` | `0` | Total cycles for `loop`/`during`; 0 = forever |
| `current_loop` | `u32` | `0` | Cycles completed so far |
| `paused` | `bool` | `false` | A paused timer is skipped by the tick and keeps its elapsed time |
| `finished` | `bool` | `false` | Set when a `once` fired, or a `loop` exhausted `loop_count` |
| `time_scale` | `f32` | `1.0` | **This timer's own speed** |
| `dropped_cycles` | `u32` | `0` | The cycles it could not run, and why |
| `tick_signal` | `Name` | empty | Fired **every tick** while `kind == .during` |
| `done_signal` | `Name` | empty | Fired when a cycle completes |

`TimerType`: `once` fires `done_signal` once after `duration`; `loop` fires it every `duration`, `loop_count` times; `during` is `loop` plus a `tick_signal` every tick, so a telegraph bar can redraw without a second clock.

**Driven by:** `ecs/timer.zig` — `tick(world, dt, bridge)`, **on the FIXED step**, *before* the behaviours run, so a script's `fixed_update` sees exactly the signals its own timers fired this tick.

**Lua:** `timer.new(self, seconds, kind)`, `timer.set_signals(self, on_tick, on_done)`, `timer.start(self, loops)`, `timer.stop(self)`, `timer.kill(self)`, `timer.progress(self)`, `timer.restart(self)`, `timer.set_duration(self, s)`, `timer.get_duration(self)`, `timer.get_elapsed(self)`, `timer.get_loops(self)`, `timer.set_kind(self, kind)`, `timer.set_time_scale(self, s)`, `timer.is_finished(self)`, `timer.is_paused(self)`, `timer.get_dropped(self)`.

**Connects to:** the world signal bus (typed Zig listeners get a `TimerEvent`) and the `SignalBridge` (Lua `on_signal` handlers). It also feeds the **tweens**: `tween.to(self, "duration", 2.0, 0.5)` can stretch a timer.

**Gotchas:**
- **There is no `autostart` field.** A timer in the world ticks from the moment it exists — a timer declared in a scene file runs with no script at all. A timer that should NOT start has `paused = true`.
- `duration <= 0` is degenerate: it fires `done_signal` **once** and finishes.
- For `.during`, the tick signal fires **before** the completion signal in the same tick, by contract.
- `timer.start` resets `elapsed`/`current_loop`/`finished` and sets `loop_count`; it does not "unpause" a `once` timer that already fired without `timer.restart`.
- The bus emit is gated on `hasListeners`, so a signal nobody subscribed to does not enqueue.
- `dropped_cycles` counts the cycles the catch-up cap refused. It is zero in a healthy game; a number that grows says the timer is running **late**.

---

### `AnimationPlayer` — id 22

**What it is:** pure playback state for a `.anim` clip: which clip is playing, how far in, how fast, and what is queued behind it.

| Field | Type | Default | Meaning |
|---|---|---|---|
| `clip_id` | `u32` | `0` | The playing clip. 0 = nothing playing |
| `next_clip_id` | `u32` | `0` | The clip being crossfaded to |
| `time` | `f32` | `0.0` | Playback position, seconds |
| `next_time` | `f32` | `0.0` | Playback position in the next clip during a crossfade |
| `speed` | `f32` | `1.0` | Playback rate. 0 means paused; negative reverses |
| `flags` | `u8` | `0` | Copied from the clip every tick: loop (1), ping-pong (2), root motion (4) |
| `blend_factor` | `f32` | `0.0` | Crossfade weight field |
| `blend_remaining` | `f32` | `0.0` | Seconds of crossfade left |
| `blend_duration` | `f32` | `0.0` | Total crossfade length; 0 = hard cut |
| `state` | `u32` | `0` | 0 idle, 1 playing, 2 paused, 3 finished |
| `queued_count` | `u8` | `0` | How many clips are queued (max 4) |
| `queued_0..3` | `u32` | `0` | The queued clip ids, in order |

**Driven by:** `ecs/animation.zig` — `update` on the FIXED step, and `applyRootMotion` **last** in the fixed step (after gameplay, so a solver does not overwrite the clip's baked displacement). Value tracks write into `Transform`, `Sprite`, the lights' `energy` and `Camera2D.zoom`; a track whose target component the entity lacks is a no-op.

**Lua:** `anim.new(self)`, `anim.play(self, clip_id, blend?)`, `anim.stop`, `anim.pause`, `anim.resume`, `anim.seek`, `anim.set_speed`, `anim.queue`, `anim.state`, `anim.time`, `anim.length`, `anim.is_playing`, `anim.set_param`, `anim.load(path)`.

**Connects to:** `Transform`, `Sprite`, `Light2D`, `Camera2D`.

**Gotchas:**
- `anim.pause` sets `speed = 0` and `anim.resume` restores `1.0` — **not** the previous speed.
- `flags` is overwritten from the clip every tick, so writing it directly is pointless.

---

## Physics

### `RigidBody2D` — id 8

**What it is:** "this actor is a physical object". It covers Godot's three body kinds (static / kinematic / dynamic) as one component with a `body_type` byte, so switching a door from fixed to kinematic at runtime does not change the archetype.

| Field | Type | Default | Meaning |
|---|---|---|---|
| `body` | `u32` | `invalid_body` | The solver's body handle. Invalid = "not in a physics world" |
| `generation` | `u32` | `0` | The handle's generation tag |
| `body_type` | `u8` | `2` | 0 fixed, 1 kinematic, 2 dynamic |
| `linear_velocity` | `Vec2` | `{0,0}` | Kept in the component as well as in the solver, so gameplay reads and writes it without a physics call |
| `angular_velocity` | `f32` | `0.0` | Radians per second |
| `linear_damping` | `f32` | `0.0` | Passed to the solver |
| `angular_damping` | `f32` | `0.0` | Passed to the solver |
| `gravity_scale` | `f32` | `1.0` | Gravity multiplier. 1.0 = normal gravity, not "no gravity" |
| `fixed_rotation` | `bool` | `false` | Lock rotation |
| `allow_sleep` | `bool` | `true` | Sleeping is allowed by default |
| `is_bullet` | `bool` | `false` | Continuous collision, for fast bodies |
| `prev_position` | `Vec2` | `{0,0}` | The position at the previous step, for interpolation |
| `prev_rotation` | `f32` | `0.0` | The rotation at the previous step |
| `tier` | `u8` | `0` | How much physics this body gets. 0 = full. Stored on the component so it survives save/load |

**Driven by:** `physics/system.zig` — `step`, whose order *is* the contract: **pushDown** (ECS → solver: the transform is snapshotted into `prev_*`, velocity is written **only if it changed**, otherwise nothing ever sleeps) → **step** (fixed 60 Hz) → **pullUp** (the solver's authoritative position into `Transform`) → **publishContacts** (the `collision` signal, one event per side).

**Lua:** `actor.set_linear_velocity(self, vx, vy)`, `actor.get_linear_velocity(self)`, `actor.apply_impulse(self, ix, iy)`, `actor.is_awake(self)`, `physics.set_body_type(self, kind)`, `physics.set_body_enabled(self, on)`, `physics.create_shape(self, kind, hw, hh)`, `physics.set_layers(self, layer, mask)`.

**Connects to:** `Transform` (the solver writes it), `Collider2D` (the shape is created with the body), `CollisionLayers` (the body's filter).

**Gotchas:**
- The component is a **handle**: the solver's own state (mass, contacts, sleeping) lives on the physics side.
- `pushDown` re-asserts the component's velocity every frame, so a velocity set directly on the solver between frames is discarded. That is why `actor.set_linear_velocity` goes through the component.
- A body with no `Collider2D` still simulates (it falls, it is just not solid).

---

### `Collider2D` — id 9

**What it is:** the shape that gives a body something to collide *with* — a box, circle, capsule, cylinder or polygon.

| Field | Type | Default | Meaning |
|---|---|---|---|
| `shape` | `u32` | `invalid_shape` | The solver's shape handle |
| `generation` | `u32` | `0` | The handle's generation tag |
| `kind` | `u8` | `0` | 0 box, 1 circle, 2 capsule, 3 cylinder, 4 polygon |
| `size` | `Vec2` | `{0.5,0.5}` | **Half**-extents (box), or x = radius / y = cap offset (capsule) |
| `offset` | `Vec2` | `{0,0}` | Shape offset from the body origin |
| `density` | `f32` | `1.0` | Density → mass |
| `friction` | `f32` | `0.3` | Friction |
| `restitution` | `f32` | `0.0` | Bounciness |
| `is_sensor` | `bool` | `false` | Reports overlaps **without** a contact response (a trigger) |

**Driven by:** `physics/system.zig` — the shape is created with the body and rebuilt in place by `reshape` / `reapplyFilter` / `setMaterial` / `setSensor` (the filter lives on the *shape*, so changing layers is a shape rebuild).

**Lua:** `physics.create_shape(self, kind, hw, hh)`, `physics.reshape`, `physics.set_material(self, friction, restitution, density)`, `physics.set_sensor(self, on)`.

**Connects to:** **requires `RigidBody2D`** — a shape is only ever created for an entity that has a body. Also `CollisionLayers` and `Transform`.

**Gotchas:**
- A `Collider2D` without a `RigidBody2D` is **inert**.
- `size` is **half**-extents: a box of `{0.5, 0.5}` is 1×1 world units.
- `is_sensor = true` is the engine's **Area2D**: it reports overlaps through the `collision` signal without stopping anything.

---

### `CollisionLayers` — id 10

**What it is:** which named collision groups a body belongs to, and which groups it is willing to talk to. It is a property of the *body*, not of a shape.

| Field | Type | Default | Meaning |
|---|---|---|---|
| `layer` | `u16` | `0xFFFF` | Which layer(s) this body is on |
| `mask` | `u16` | `0xFFFF` | Which layer(s) it will interact with |

**Driven by:** `physics/system.zig` — **no `CollisionLayers` means "collide with everything"**, deliberately.

**Lua:** `physics.set_layers(self, layer_mask, collide_mask)` — bitmasks, not names; the binding cannot resolve names because it has no project layer table.

**Connects to:** `Collider2D` (the filter is baked into the shape) and `RigidBody2D`.

**Gotcha:** the rule is **symmetric**: one direction is not enough. A projectile on a layer the wall does not mask will pass through.

---

## Lighting

### `LightBase` (shared, not a component)

The four concrete light kinds embed this by value. It is **not** registered — it is a plain struct.

| Field | Type | Default | Meaning |
|---|---|---|---|
| `color` | `[4]f32` | `{1,1,1,1}` | Colour × `energy`. Alpha is the light's opacity |
| `energy` | `f32` | `1` | Brightness multiplier |
| `blend` | `LightBlend` | `.add` | `add` / `subtract` / `mix` |
| `cast_shadows` | `bool` | `true` | Whether it casts shadows (a budget decision: four shadow channels) |
| `shadow_filter` | `ShadowFilter` | `.pcf3` | Edge softening: `off`, `pcf1`, `pcf3`, `pcf5` |
| `shadow_filter_smooth` | `f32` | `2.0` | Tap spread, in shadow-mask texels |
| `item_cull_mask` | `u32` | `0xFFFFFFFF` | Which `Sprite.layer` values this light affects |
| `enabled` | `bool` | `true` | Whether the light is on at all |

---

### `Light2D` (legacy) — id 11

**What it is:** the original single light component holding *every* kind, discriminated by `kind`. New scenes should use the four concrete kinds; `Light2D` stays because its **id is the `.zson` encoding** — deleting it would renumber every component after it.

| Field | Type | Default | Meaning |
|---|---|---|---|
| `kind` | `LightKind` | `.point` | point (0), spot (1), directional (2), ambient (3) |
| `color` | `[4]f32` | `{1,1,1,1}` | Colour × `energy` |
| `energy` | `f32` | `1` | Brightness multiplier |
| `offset` | `Vec2` | `{0,0}` | Hotspot offset, in the Transform's own frame |
| `radius` | `f32` | `128` | How far the light reaches |
| `angle` | `f32` | `0` | Spot: cone direction. Directional: travel direction |
| `cone_angle` | `f32` | `0.785` | Spot: full opening in radians (45°) |
| `penumbra` | `f32` | `0.2` | Spot: fraction of the cone given over to a soft edge |
| `attenuation` | `f32` | `1` | Falloff exponent |
| `blend` | `LightBlend` | `.add` | How it combines with the frame |
| `cast_shadows` | `bool` | `true` | Whether it casts shadows |
| `shadow_filter` | `ShadowFilter` | `.pcf3` | Edge softening |
| `shadow_filter_smooth` | `f32` | `2.0` | Tap spread |
| `item_cull_mask` | `u32` | `0xFFFFFFFF` | Which `Sprite.layer` values it affects |
| `enabled` | `bool` | `true` | Whether it is on |

**Driven by:** `render/light.zig` — `Lighting.collect`, **per frame**, through the same generic gather as the four kinds.

**Lua:** **not writable.** `light.*` writes only the four concrete kinds; `light.kind_of(self)` reports `"legacy"` for this one.

**Connects to:** `Transform`, `Environment`, `Sprite.layer`, `LightOccluder2D`.

**Gotcha:** a legacy `Light2D` **and** a `PointLight2D` on the same actor light the scene twice.

---

### `LightOccluder2D` — id 12

**What it is:** "this actor blocks light". It is how a wall casts a shadow and how a character silhouette stops a torch.

| Field | Type | Default | Meaning |
|---|---|---|---|
| `mode` | `OccluderMode` | `.auto_sdf` | `auto_sdf` (derive the shape from the sprite's alpha), `manual` (use `polygon`), `none` (cast nothing) |
| `polygon` | `OccluderPolygon` | empty | Used when `mode == .manual` |
| `alpha_threshold` | `f32` | `0.5` | The alpha at which `auto_sdf` decides a texel is solid |
| `cull_mask` | `u32` | `0xFFFFFFFF` | Which lights this occluder blocks, by light index. 0 = all |
| `enabled` | `bool` | `true` | Whether it participates |

**Driven by:** `render/light.zig` — gathered per frame; the set is fingerprinted and the mask is only re-rasterized when the fingerprint changes.

**Lua:** `occluder.new(self, mode)`, `occluder.set_mode`, `occluder.set_threshold`, `occluder.set_mask`, `occluder.set_polygon(self, {x0, y0, ...})`, plus the getters.

**Connects to:** **requires `Sprite`** in `auto_sdf` mode. Also `Transform` and the lights' shadow channels.

**Gotchas:**
- `auto_sdf` **skips the entity entirely** if it has no `Sprite`.
- The automatic shape falls back to the sprite's **rectangle** without a coverage mask.
- `mode = .none` is the escape hatch: "looks like it occludes but must not".

---

### `Environment` — id 13

**What it is:** the world's own light level: what "dark" means here, and the post-process mood. It is **one per world, not per actor**.

| Field | Type | Default | Meaning |
|---|---|---|---|
| `ambient_color` | `[4]f32` | `{0.09,0.10,0.14,1}` | The colour the ambient term tints everything by |
| `ambient_energy` | `f32` | `1.0` | Global light level, a multiplier on the colour |
| `clear_color` | `[4]f32` | `{0.02,0.02,0.03,1}` | What a pixel with no light resolves to |
| `bloom_intensity` | `f32` | `0.0` | How much bloom is added. **Zero disables the whole chain** |
| `bloom_threshold` | `f32` | `1.0` | Luminance above which a pixel contributes to the bloom |
| `tonemap` | `bool` | `false` | Screen-space tonemap |
| `fog` | `[2]f32` | `{0,0}` | Fog near and far in world units. 0 disables it |
| `fog_color` | `[4]f32` | `{0.5,0.5,0.55,1}` | The fog colour |

**Driven by:** `render/lighting_driver.zig` — the **first** `Environment` in the world, read **every frame** (a script can change it mid-run).

**Lua:** `environment.new(self)`, `environment.set_ambient(self, r, g, b, energy)`, `environment.set_clear`, `environment.set_bloom(self, intensity, threshold)`, `environment.set_tonemap`, `environment.set_fog(self, near, far)`, plus the getters.

**Connects to:** the lighting driver (ambient) and the post chain (bloom, tonemap, fog).

**Gotcha:** only `ambient` is mapped into the renderer's `SceneEnvironment` by `toScene`; the rest are read by the post pass.

---

### `PointLight2D` — id 14

**What it is:** a lamp, a torch, a candle — a light that falls off in every direction. The light most scenes are made of.

| Field | Type | Default | Meaning |
|---|---|---|---|
| `base` | `LightBase` | `{}` | The shared light fields |
| `offset` | `Vec2` | `{0,0}` | Hotspot offset |
| `radius` | `f32` | `192` | How far it reaches. The falloff reaches exactly zero at `r` |
| `attenuation` | `f32` | `1` | Falloff exponent. Higher concentrates the light |

**Driven by:** `render/light.zig` — gathered per frame, flattened into a `LightDesc`.

**Lua:** `point.new(self, radius)`, `point.set_radius(self, r)`, plus the shared `light.set_color`, `light.set_energy`, `light.set_blend`, `light.set_shadow`, `light.set_mask`, and the getters.

**Connects to:** `Transform`, `Environment`, `Sprite.layer` via `item_cull_mask`, `LightOccluder2D`, and the **tweens** (`tween.to(self, "energy", 0, 0.5)` fades a light out).

**Gotchas:**
- The `light.*` setters write **only** the four concrete kinds, never the legacy `Light2D`.
- `light.get_radius` returns `0` for a directional or ambient light (they reach everywhere) — never nil.

---

### `SpotLight2D` — id 15

**What it is:** a cone of light with a soft edge. The `penumbra` is a *fraction of the cone* rather than an angle, because a designer thinks "the last fifth of the beam is soft".

| Field | Type | Default | Meaning |
|---|---|---|---|
| `base` | `LightBase` | `{}` | The shared light fields |
| `offset` | `Vec2` | `{0,0}` | Hotspot offset |
| `radius` | `f32` | `192` | How far the beam reaches |
| `angle` | `f32` | `0` | The direction the cone points, radians |
| `cone_angle` | `f32` | `0.785` | The full opening in radians |
| `penumbra` | `f32` | `0.2` | The fraction of the cone given over to a soft edge |
| `attenuation` | `f32` | `1` | Falloff exponent |

**Driven by:** `render/light.zig`.

**Lua:** `spot.new(self, radius)`, `spot.set_radius`, `spot.set_cone(self, degrees, penumbra)`, `spot.set_angle(self, radians)`.

**Gotcha:** `spot.set_cone` takes **degrees**; the component stores **radians**.

---

### `DirectionalLight2D` — id 16

**What it is:** the sun. No falloff: everything is lit equally and `angle` is the direction the light *travels*. It exists because a point light with a huge radius is dark at the far end of the screen — a sun is not anywhere.

| Field | Type | Default | Meaning |
|---|---|---|---|
| `base` | `LightBase` | `{}` | The shared light fields |
| `angle` | `f32` | `0` | The direction the light **travels**, radians. 0 is to the right |
| `height` | `f32` | `0.5` | 0..1, how high above the scene it sits. It scales shadow **length** |
| `max_distance` | `f32` | `0` | How far it reaches. 0 = unbounded |

**Driven by:** `render/light.zig`.

**Lua:** `directional.new(self)`, `directional.set_angle(self, radians)`, `directional.set_height(self, h)`.

**Gotcha:** `angle` is the direction of **travel**, not the direction it points — a sun at 0 shines right, so shadows fall left.

---

### `AmbientLight2D` — id 17

**What it is:** the world's own light — light from everywhere, with no position in the falloff. Separate from `Environment` because a scene often wants **two** ambients (a sky colour and a ground bounce) and one number cannot hold both.

| Field | Type | Default | Meaning |
|---|---|---|---|
| `base` | `LightBase` | `{}` | The shared light fields |
| `global` | `bool` | `true` | Whether it applies to the whole scene |
| `max_distance` | `f32` | `128` | When `global == false`, the reach of the local ambient |

**Driven by:** `render/light.zig`.

**Lua:** `ambient.new(self)`, `ambient.set_local(self, distance)` (0 restores the scene-wide kind).

**Gotcha:** an ambient **never** casts a shadow.

---

## Camera

### `Camera2D` — id 18

**What it is:** the window onto the world: what is centred, how zoomed, how shaken, and what it may not leave.

| Field | Type | Default | Meaning |
|---|---|---|---|
| `target` | `Entity` | `Entity.invalid` | The entity to follow |
| `follow_enabled` | `bool` | `true` | Whether the follow is active |
| `deadzone` | `Rect2` | `{pos:{0,0}, size:{-1,-1}}` | A deadzone around the centre. A **negative size = disabled** |
| `damping` | `f32` | `5.0` | The critically-damped spring's frequency. 0 = snap |
| `look_ahead` | `f32` | `0.0` | Seconds of the target's velocity to lead by |
| `zoom` | `f32` | `1.0` | The current zoom |
| `min_zoom` | `f32` | `0.1` | Lower clamp |
| `max_zoom` | `f32` | `10.0` | Upper clamp |
| `zoom_damping` | `f32` | `8.0` | Zoom smoothing rate |
| `trauma` | `f32` | `0.0` | Shake amount, 0..1, decaying |
| `trauma_power` | `f32` | `2.0` | The shake curve's exponent |
| `trauma_decay` | `f32` | `1.0` | Shake decay per second |
| `shake_frequency` | `f32` | `25.0` | The shake noise's frequency |
| `shake_amplitude` | `f32` | `10.0` | The shake's magnitude at full trauma |
| `limits_enabled` | `bool` | `false` | Whether the centre is clamped |
| `limits` | `Rect2` | big | The rectangle the centre may not leave |
| `enabled` | `bool` | `true` | Whether this camera is a candidate for the view |
| `_offset` | `Vec2` | `{0,0}` | **Runtime**: the current centre |
| `_velocity` | `Vec2` | `{0,0}` | **Runtime**: the spring's velocity |
| `_target_zoom` | `f32` | `1.0` | **Runtime**: the zoom it is easing toward |
| `_trauma_timer` | `f32` | `0.0` | **Runtime**: the shake clock |

**Driven by:** `ecs/camera.zig` — `update(world, dt, w, h) -> ?View`, **once per rendered frame** (not once per sub-step), with `dt = fixed_dt * steps`.

**Lua:** `camera.new(self)`, `camera.follow(self, other)`, `camera.zoom_to(self, zoom)`, `camera.shake(self, trauma)`, `camera.set_limits(self, x, y, w, h)`, `camera.set_damping(self, d)`, `camera.get_centre(self)`.

**Connects to:** the target's `Transform` and `Velocity`. Produces the `View` the renderer uses for the projection and the cull rect.

**Gotchas:**
- Only the **first enabled** camera is simulated. A second camera is inert, not merely lower priority.
- `camera.get_centre` returns `_offset` — **without** the shake.
- `camera.zoom_to` sets the *target*; the camera eases toward it.

---

## Audio and particles

### `SoundEmitter2D` — id 20

**What it is:** the scene-side description of a sound that belongs to a place: a footstep, a door, an engine.

| Field | Type | Default | Meaning |
|---|---|---|---|
| `bank_slot` | `u16` | `0` | The bank slot of the decoded sound. 0 = nothing loaded |
| `bus` | `u8` | `0` | The audio bus it feeds. 0 = master |
| `volume` | `f32` | `1.0` | The emitter's gain, before the bus gain |
| `pitch` | `f32` | `1.0` | The resample ratio. 1 is the file's own pitch |
| `loop` | `bool` | `false` | Whether playback loops |
| `max_distance` | `f32` | `0.0` | The distance at which it is inaudible. **0 means global** |
| `spread` | `f32` | `400.0` | The distance at which panning reaches a hard left/right |
| `autoplay` | `bool` | `false` | "Start when the frame loop first sees the emitter" |
| `playing` | `VoiceRef` | none | The voice it started, so a despawn can stop it |
| `tick` | `u64` | `0` | The tick the current voice started at |

**Driven by:** `audio/system.zig` — the emitter is the *description*; the audio system turns a `play` into a voice.

**Lua:** `sound.play(self, path?, opts?)`, `sound.stop(self)`, `sound.set_volume`, `sound.set_pitch`, `sound.set_loop`, `sound.set_radius`, `sound.set_spread`, `sound.is_playing(self)`, `sound.describe(self)`.

**Connects to:** the audio system and the entity's `Transform` (where the sound is placed).

**Gotchas:**
- **`autoplay` is never acted upon** — the field exists and is read back, but no engine code starts playback from it.
- `sound.set_loop` and `sound.set_radius` are **next-play only**.

---

### `ParticleEmitter2D` — id 21

**What it is:** the **recipe** for a particle effect. The particles themselves live in a pool owned by the system; the component holds the recipe and a handle into that pool.

| Field | Type | Default | Meaning |
|---|---|---|---|
| `rate` | `f32` | `20.0` | Particles per second |
| `capacity` | `u16` | `128` | The hard cap on live particles |
| `one_shot` | `bool` | `false` | Emit `capacity` particles once and stop |
| `started_once` | `bool` | `false` | **System**: the one-shot has already fired |
| `playing` | `bool` | `true` | Whether it is emitting. A scene-file emitter runs with no script |
| `shape` | `EmitShape` | `.point` | Where a particle is born: point, box, disc |
| `backend` | `Backend` | `.cpu` | CPU (main thread) or GPU (compute) |
| `space` | `Space` | `.world` | Whether particles stay put or follow the emitter |
| `atlas` | `u8` | `0` | Which atlas page they sample |
| `blend` | `Blend` | `.alpha` | How they composite |
| `live` | `u16` | `0` | The live particle count |
| `slab` | `u16` | `no_slab` | The system's pool slot |
| `accumulator` | `f32` | `0.0` | The fractional particle carried across ticks |
| `seed` | `u32` | `0x9e3779b9` | The per-emitter PRNG state, so a snapshot restores the *sequence* |
| `extent` | `Vec2` | `{0,0}` | The box half-extents, or the disc radius |
| `angle` | `Vec2` | `{0, 2π}` | The emission direction range |
| `speed` | `Vec2` | `{40,40}` | Min and max spawn speed |
| `gravity` | `Vec2` | `{0,0}` | Constant acceleration |
| `drag` | `f32` | `0` | Velocity damping per second |
| `life` | `Vec2` | `{0.5,1.0}` | Min and max seconds a particle lives |
| `size` | `Vec2` | `{8,8}` | The size at birth and at death |
| `spin` | `f32` | `0` | The rotation velocity at spawn |
| `color_start` | `u32` | white | The colour at birth, packed RGBA8 |
| `color_end` | `u32` | transparent | The colour at death |
| `layer` | `u16` | `10` | The render layer. **10, not 0** |
| `uv` | `[4]f32` | `{0,0,1,1}` | The particle image's atlas rect |

**Driven by:** `render/particles.zig` — `fixedUpdate` on the FIXED step (after the behaviours), and `collect` per frame into the **same instance list** as the sprites.

**Lua:** `particles.burst(self, count)`, `particles.stats()`.

**Gotchas:**
- The configuration fields are **not settable from Lua**: there is no `particle.*` module and no generic field setter.
- `layer` defaults to **10**, so a particle behind the thing that emitted it reads as a bug.

---

## Game UI

### `UiCanvas` — id 23

**What it is:** the screen root of the game's UI: the virtual resolution the interface is authored in, and how it maps onto the framebuffer.

| Field | Type | Default | Meaning |
|---|---|---|---|
| `virtual_w` | `f32` | `1280` | The virtual (logical) width |
| `virtual_h` | `f32` | `720` | The virtual (logical) height |
| `scale_mode` | `UiScaleMode` | `.fit` | `pixel` (1:1), `fit` (uniform + letterbox), `stretch` (fills and distorts) |
| `layer_base` | `u16` | `255` | The layer the UI draws on. 255 is the "every light" wildcard, so an unlit HUD never goes dark |

**Driven by:** `ecs/ui_system.zig` — `resolveCanvas` **per frame**, taking the **first** canvas in slot order.

**Lua:** **not settable** (there is no binding for the fields).

**Connects to:** every widget's layout, and `render/ui_draw.zig`.

**Gotchas:** only the first canvas wins. `layer_base` is a `u16` but only the low byte reaches the GPU.

---

### `Label` — id 24

**What it is:** a run of text on the screen — scores, captions, dialogue.

| Field | Type | Default | Meaning |
|---|---|---|---|
| `layout` | `UiLayout` | `{}` | Placement, order, and the runtime `resolved` rect |
| `font` | `u32` | `0` | 0 is the engine default; any other id comes from `ui.font_load` |
| `text` | `InlineText` | empty | The string, inline, max 128 bytes |
| `color` | `[4]f32` | `{1,1,1,1}` | The text colour |
| `alignment` | `TextAlign` | `.left` | `left`, `center`, `right` |

**`UiLayout`** (a field, not a component — by design):

| Field | Type | Default | Meaning |
|---|---|---|---|
| `anchor` | `UiAnchor` | `.top_left` | One of twelve presets: `top_left`…`bottom_right`, `stretch_h`, `stretch_v`, `full_rect` |
| `offset` | `Vec2` | `{0,0}` | The displacement from the resolved anchor point |
| `size` | `Vec2` | `{100,30}` | The widget's size in canvas pixels |
| `pivot` | `Vec2` | `{0,0}` | `0,0` anchors the top-left; `0.5,0.5` centres it |
| `margin` | `[4]f32` | `{0,0,0,0}` | top, right, bottom, left insets, for the stretch presets |
| `order` | `i32` | `0` | The paint order and the hit-test order |
| `visible` | `bool` | `true` | Whether it is drawn |
| `interactive` | `bool` | `true` | Whether it blocks world input |
| `resolved` | `Rect2` | empty | **Runtime**: the screen-pixel rect resolved this frame |

**Driven by:** `ecs/ui_system.zig` — `update` **per frame**: gather, resolve the layout, sort by `(order, kind)`, hit-test, and fire `ui_pressed`.

**Lua:** `ui.set_text`, `ui.set_font`, `ui.set_color(self, r, g, b, a)`, `ui.set_align`, the layout setters, `ui.rect(self)`, `ui.hovered(self)`, `ui.pressed(self)`, `ui.measure(self, text)`, `ui.font_load(path, px)`.

**Connects to:** `UiCanvas`, its `UiLayout`, the font system, and the **tweens** (`tween.to(self, "color.a", 0, 0.3)` fades a label out).

**Gotchas:**
- The field is `alignment`, not `align` (`align` is a Zig keyword); the Lua setter is still `ui.set_align`.
- `InlineText` truncates at **128 bytes, silently**.
- A `Label` never captures the pointer.

---

### `UiButton` — id 25

**What it is:** a clickable box with a caption.

| Field | Type | Default | Meaning |
|---|---|---|---|
| `layout` | `UiLayout` | `{}` | Placement and order |
| `text` | `InlineText` | empty | The caption |
| `font` | `u32` | `0` | The font id |
| `id` | `u32` | `0` | Returned in the `ui_pressed` signal |
| `enabled` | `bool` | `true` | A disabled button is inert |
| `color_normal` | `[4]f32` | dark | The idle fill |
| `color_hover` | `[4]f32` | lighter | The fill under the pointer |
| `color_pressed` | `[4]f32` | darkest | The fill while held |
| `text_color` | `[4]f32` | near-white | The caption colour |
| `state` | `UiButtonState` | `.normal` | **Runtime**: normal, hover, pressed |

**Driven by:** `ecs/ui_system.zig` — per frame; the press/release edges fire `ui_pressed` on the world bus and into Lua's `on_signal("ui_pressed", { id, entity })`.

**Lua:** `ui.set_text`, `ui.set_font`, `ui.set_enabled`, `ui.set_colors(self, normal, hover, pressed, text)`, `ui.set_color`, the layout setters, `ui.hovered`, `ui.pressed`.

**Gotchas:**
- `ui.set_color` on a button writes **`text_color`**, not the background.
- A press in A and a release in B does **not** fire.

---

### `UiPanel` — id 26

**What it is:** a filled box — a HUD backdrop, a menu background, a divider.

| Field | Type | Default | Meaning |
|---|---|---|---|
| `layout` | `UiLayout` | `{}` | Placement and order |
| `color` | `[4]f32` | `{0.08,0.09,0.12,0.85}` | The fill |
| `border_color` | `[4]f32` | transparent | The border colour |
| `border_width` | `f32` | `0` | The border thickness, drawn as **four thin quads** |

**Driven by:** `ecs/ui_system.zig` + `render/ui_draw.zig`.

**Lua:** `ui.set_color`, `ui.set_border(self, r, g, b, a, width)`, the layout setters.

**Gotcha:** a panel with `interactive = true` **swallows world clicks** over its rect.

---

### `UiProgressBar` — id 27

**What it is:** a 0..1 bar — health, mana, a reload timer.

| Field | Type | Default | Meaning |
|---|---|---|---|
| `layout` | `UiLayout` | `{}` | Placement and order |
| `value` | `f32` | `0` | The fill, 0..1 |
| `bg_color` | `[4]f32` | dark | The background |
| `fill_color` | `[4]f32` | green | The filled part |
| `show_text` | `bool` | `false` | Whether it draws its text |
| `text` | `InlineText` | empty | The optional text |
| `font` | `u32` | `0` | The font id |

**Driven by:** `ecs/ui_system.zig` + `render/ui_draw.zig`.

**Lua:** `ui.set_value(self, v)` (clamped 0..1), `ui.set_show_text`, `ui.set_text`, `ui.set_font`, `ui.set_color` (writes `fill_color`), the layout setters.

**Connects to:** `Timer` — `timer.progress(self)` feeds `ui.set_value`, and a **tween** can drive the value (`tween.to(self, "value", 1, 1.0)`).

---

## Parked: `TileMapLayer`

The type exists (`components/tilemap.zig`) but is **not registered**: the registry entry and the Lua module are both commented out ("M15 PARKED"). The editor's tilemap workspace can still use the type.

| Field | Type | Default | Meaning |
|---|---|---|---|
| `tileset_guid` | `AssetGUID` | `.{ .value = 0 }` | The palette it draws from |
| `layer` | `u16` | `0` | The render layer |
| `z_offset` | `f32` | `0.0` | A parallax offset inside the layer |
| `physics_enabled` | `bool` | `false` | Whether it collides |
| `tile_size_override` | `f32` | `0.0` | 0 = use the TileSet default |
| `default_flip_x` | `bool` | `false` | The default flip for new tiles |
| `default_flip_y` | `bool` | `false` | The default flip for new tiles |
| `_reserved` | `[3]u8` | zeroed | Reserved |

---

## The wiring: who reads whom

| From | Reads / requires | Why |
|---|---|---|
| `Sprite` | `Transform` | **Required.** The draw query is the pair `(Transform, Sprite)` |
| `LightOccluder2D` | `Transform`, `Sprite` | **Required in `auto_sdf`**: the shape comes from the sprite's alpha |
| The four lights | `Transform` | Position and rotation place the light |
| `Camera2D` | the target's `Transform` and `Velocity` | What it follows, and what it leads |
| `RigidBody2D` | `Transform` | The solver writes it; the physics snapshots it into `prev_*` |
| `Collider2D` | `RigidBody2D` | **Required.** A shape is only created with a body |
| `CollisionLayers` | `RigidBody2D` + `Collider2D` | The filter is baked into the shape |
| `Parent` | `Transform` | The resolver needs both |
| `Timer` | the signal bus + the bridge | Its callback is a **name**, not a pointer |
| `ParticleEmitter2D` | `Transform` | The spawn point |
| `AnimationPlayer` | `Transform`, `Sprite`, the lights, `Camera2D` | The value tracks; a missing target is a no-op |
| `Environment` | — | Read by the lighting driver, the first one in the world |
| `Script` | the script cache | The behaviour behind it |
| `StateMachine` | the state-machine registry | The machine behind it |
| The UI widgets | `UiCanvas` + their own `UiLayout` | Where they are drawn |
| `SoundEmitter2D` | the entity's `Transform` | Where the sound is placed |
| `ShaderMaterial` | — | **No consumer** |

### The three rules that explain most of it

1. **A component never holds a callback.** The registry forbids pointers and slices. So a thing that needs to call back holds a **name** (`Timer.done_signal`) or a **handle** (`StateMachine.machine`, `Script.script`) — and the engine resolves it.
2. **A component is plain data and the ECS is the document.** Everything the renderer draws, the solver simulates or the scene file saves is a component field. Anything transient (a tween, a state machine's live state) lives in an engine registry with a handle.
3. **A system owns a component's behaviour.** The component says *what*; the system says *when*. `Timer` says how long; `ecs/timer.zig` says when it fires. That split is why a timer can be written by a scene file and still fire at the right moment in the frame.

---

## The frame, in order

The runtime's frame (`src/runtime/main.zig`):

1. **Input** — the action snapshot for this frame.
2. **Mixer** — the audio frame boundary.
3. **The fixed-step window**, once per 1/60 s step:
   1. `world.captureTransforms()` — the interpolation snapshot, **first**.
   2. `ecs.timer.tick` — the timers fire their signals.
   3. `anim_system.update` — the animation clips advance.
   4. `behaviors.tickTweens` — the tweens move their properties.
   5. `behaviors.fixedUpdate` — the Lua gameplay runs.
   6. `particles.fixedUpdate` — the particles simulate.
   7. `anim_system.applyRootMotion` — **last**, so a solver does not overwrite the clip.
4. **The camera**, once per rendered frame.
5. `behaviors.update` — the per-frame Lua update.
6. **The signal drain** — the audio events first, then the typed bus.
7. **Collect** — the particles, then the sprites, then the UI.
8. **Render** — the sprites, the lighting, the post chain.
9. **Present**.

The order inside the fixed step is a **contract**, not an accident: a script that reads a tweened property in `fixed_update` sees the value the tween just wrote, and a script that writes the property itself has the last word in that tick.

---

## Gotcha index

1. The `TileMapLayer` "id 23" comment is **stale**: the UI took ids 23–27, so it would be appended at 28.
2. `Timer` has **no `autostart` field** — a timer ticks from the moment it exists.
3. `Sprite.tint` is a **4-float RGBA**, not RGB.
4. `Sprite.order` is used only by the **editor's** picking, not by the runtime renderer.
5. `Light2D` is a generic component that dispatches on `kind`; the `light.*` setters never write it.
6. `Light2D` cannot be deleted: its id is part of the `.zson` encoding.
7. `Environment`'s `clear_color`, `bloom_*`, `tonemap` and `fog` are not mapped by `toScene` (only `ambient` is).
8. `ShaderMaterial` has **no consumer**.
9. `SoundEmitter2D.autoplay` is **never acted on**.
10. `Velocity` is **not integrated** by any engine system.
11. The hierarchy resolver is not called by the shipped frame loops.
12. The runtime has **no physics system**: every `physics.*` binding is inert there (the editor has one).
13. `Collider2D` without a `RigidBody2D` is **inert**.
14. `LightOccluder2D` in `auto_sdf` **skips the entity** without a `Sprite`.
15. `sprite.layer` is clamped to a byte in the GPU instance.
16. `UiCanvas`'s fields are not settable from Lua, and only the first canvas is used.
17. `ParticleEmitter2D`'s configuration is not settable from Lua.
18. `InlineText` and `Name` **truncate silently** (128 and 32 bytes).
19. `UiLayout` is a **field, not a component**.
20. `AnimationPlayer.flags` is overwritten from the clip every tick.
21. `anim.pause` sets `speed = 0`; `anim.resume` restores `1.0`, not the previous speed.
22. `sound.set_loop` / `sound.set_radius` are **next-play only**.
23. `light.get_radius` returns `0` for directional and ambient lights.
24. `spot.set_cone` takes **degrees**; the component stores **radians**.
25. `ParticleEmitter2D.layer` defaults to **10**.
26. `CollisionLayers` defaults to "collide with everything", and the rule is **symmetric**.
27. Only the **first enabled** camera is simulated.
28. `Camera2D.get_centre` returns `_offset` **without** the shake.
29. `RigidBody2D` defaults: dynamic, `gravity_scale = 1.0`, `allow_sleep = true`.
30. A `UiButton` and a `UiPanel` on the same entity: the button wins.
31. `Transform.prev_*` is captured by `world.captureTransforms()` at the start of the fixed step — without it, everything renders interpolated from the spawn point.

---

## See also

- [Component Registry](ecs-components.md) — how components are registered, the rules, and the archetype storage.
- [Tweens and Timers](tween-and-timer.md) — the sequencing toolkit.
- [Lua API Reference](script-lua-api.md) — every binding.
- [Architecture Overview](../architecture/overview.md) — the layers.
