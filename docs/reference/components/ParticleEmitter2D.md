# ParticleEmitter2D — component id 21

**Registry name:** `ParticleEmitter2D` · **id:** 21


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

---

← [Component index](README.md) · [Registry mechanics](../ecs-components.md) · [Lua API](../script-lua-api.md)
