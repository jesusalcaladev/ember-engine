# AnimationPlayer — component id 22

**Registry name:** `AnimationPlayer` · **id:** 22


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

---

← [Component index](README.md) · [Registry mechanics](../ecs-components.md) · [Lua API](../script-lua-api.md)
