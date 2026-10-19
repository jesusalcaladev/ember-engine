# Component Index

**Source:** `src/engine/ecs/components/` (one file per component) · `src/engine/ecs/components/registry.zig` (the registry)

Every component the engine has, **one page each**: what it is for, every field, which system drives it, which Lua bindings touch it, what it connects to, and the gotchas.

This is the engine's own reference. If you are looking for how to *build* something, see the [guides](../../guides/) instead.

---

## The registry in one table

| id | Component | What it is for | File |
|---|---|---|---|
| 0 | [`Name`](Name.md) | The actor's name in the scene file and the inspector | `name.zig` |
| 1 | [`Transform`](Transform.md) | Where it is and how it is turned | `transform.zig` |
| 2 | [`Parent`](Parent.md) | Who it hangs off | `hierarchy.zig` |
| 3 | [`Velocity`](Velocity.md) | Drift, for a body that does not collide | `hierarchy.zig` |
| 4 | [`Sprite`](Sprite.md) | What it looks like | `sprite.zig` |
| 5 | [`ShaderMaterial`](ShaderMaterial.md) | A shared custom-shader hook (**no consumer yet**) | `material.zig` |
| 6 | [`Script`](Script.md) | The Lua behaviour attached to it | `script.zig` |
| 7 | [`StateMachine`](StateMachine.md) | A handle to a Lua-defined state machine | `script.zig` |
| 8 | [`RigidBody2D`](RigidBody2D.md) | "This is a physical object" | `physics.zig` |
| 9 | [`Collider2D`](Collider2D.md) | The shape it collides with | `physics.zig` |
| 10 | [`CollisionLayers`](CollisionLayers.md) | Which groups it talks to | `physics.zig` |
| 11 | [`Light2D`](Light2D.md) | The legacy all-in-one light | `light.zig` |
| 12 | [`LightOccluder2D`](LightOccluder2D.md) | "This blocks light" | `light.zig` |
| 13 | [`Environment`](Environment.md) | The world's light level and post mood | `light.zig` |
| 14 | [`PointLight2D`](PointLight2D.md) | A lamp | `light.zig` |
| 15 | [`SpotLight2D`](SpotLight2D.md) | A cone of light | `light.zig` |
| 16 | [`DirectionalLight2D`](DirectionalLight2D.md) | The sun | `light.zig` |
| 17 | [`AmbientLight2D`](AmbientLight2D.md) | Light from everywhere | `light.zig` |
| 18 | [`Camera2D`](Camera2D.md) | The window onto the world | `camera.zig` |
| 19 | [`Timer`](Timer.md) | "In N seconds, fire this signal" | `timer.zig` |
| 20 | [`SoundEmitter2D`](SoundEmitter2D.md) | A sound that belongs to a place | `sound_emitter.zig` |
| 21 | [`ParticleEmitter2D`](ParticleEmitter2D.md) | The recipe for a particle effect | `particle.zig` |
| 22 | [`AnimationPlayer`](AnimationPlayer.md) | Clip playback state | `animation.zig` |
| 23 | [`UiCanvas`](UiCanvas.md) | The virtual resolution of the HUD | `ui.zig` |
| 24 | [`Label`](Label.md) | A run of text | `ui.zig` |
| 25 | [`UiButton`](UiButton.md) | A clickable box | `ui.zig` |
| 26 | [`UiPanel`](UiPanel.md) | A filled box | `ui.zig` |
| 27 | [`UiProgressBar`](UiProgressBar.md) | A 0..1 bar | `ui.zig` |
| — | [`TileMapLayer`](TileMapLayer.md) | **Parked**: not registered | `tilemap.zig` |
| — | [`LightBase`](LightBase.md) | A shared struct, not a component | `light.zig` |

> **The dense id is the on-disk format.** A `.zson` file stores `Timer { ... }`, and the id is what the decoder looks up. Adding a component means APPENDING a line to the registry — never inserting, which would renumber every committed scene.


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

---

## See also

- [Component Registry](../ecs-components.md) — how components are registered, the rules, and the archetype storage.
- [Tweens and Timers](../tween-and-timer.md) — the sequencing toolkit.
- [Lua API Reference](../script-lua-api.md) — every binding.
- [Architecture Overview](../../architecture/overview.md) — the layers.
