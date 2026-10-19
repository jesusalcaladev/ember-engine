# SoundEmitter2D — component id 20

**Registry name:** `SoundEmitter2D` · **id:** 20


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

---

← [Component index](README.md) · [Registry mechanics](../ecs-components.md) · [Lua API](../script-lua-api.md)
