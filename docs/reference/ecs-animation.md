# Animation clips (M13)

The animation system is **data-driven and component-based**: a script asks an
actor to play a *clip*, a clip is an asset, and a system walks every actor with
an `AnimationPlayer` once per fixed tick. There are no nodes, no graph, and no
per-clip code — the clip's own flags decide how it behaves.

- **`AnimationClip`** — the asset. A fixed set of *value*, *sprite* and *method*
  tracks plus a duration and a flags byte.
- **`AnimationPlayer`** — the component. One per actor, holding `clip_id`,
  `time`, `speed`, `flags`, `blend_factor` and `state`. Plain data: it serializes
  into `.zson` like every other component.
- **The system** — `ecs.animation.System`. Advances every player, samples the
  tracks, crossfades, fires events. Zero allocations.

## Clips are assets: the id is a GUID

A clip's handle is derived from its **path**, with the same FNV-1a the M6 asset
registry uses (`assets.registry.AssetGUID.fromPath`):

```zig
pub fn clipIdForPath(path: []const u8) u32   // ecs/animation.zig
```

Two consequences that everything else rests on:

- **Stable across sessions.** A scene or a script that only knows the path
  computes the same handle the loader produced, with no table in common. That is
  what makes `clip_id` a GUID rather than a per-session counter.
- **Hot reload keeps the id.** Re-loading the same path swaps the decoded clip in
  under its EXISTING id, so every `AnimationPlayer` pointing at it keeps its
  `time` — no restart, no pop.

`0` is the "nothing playing" sentinel (`AnimationPlayer.clip_id == 0` is idle),
so a hash that lands on it is bumped to `1`.

Clips are registered as M6 assets (`AssetType.clip`), whose `handle` is exactly
this clip id, so the registry and the animation system name the same asset with
the same number.

### Preloading a project's clips

At boot the runtime decodes every `.anim` in the project's animation directory
(`assets/animations`, the same convention `assets/audio` follows):

```zig
const report = try anim_system.preloadDir("assets/animations");
// report.loaded, report.failed
```

Files only, no recursion: one directory is a level's library, and a nested tree
is a decision a project should make explicitly. A `.anim` that fails to decode is
**counted**, not fatal — one broken clip must not blank the rest of the project's
animation — and a missing directory is reported and then ignored, so a project
with no animations yet still boots.

## The `.anim` file format

Line-oriented text: diffable, and small enough to hand-write. `#` starts a
comment, blank lines are ignored, and each line starts with a keyword. Counts keep
every line unambiguous.

```
clip 1                                        # header, version 1 (required)
duration 1.0                                  # seconds
flags loop ping_pong                          # any of: loop ping_pong root_motion
root_motion 10.0 0.0 0.0                      # dx dy dr, units per SECOND
value transform_x 2 0.0 0.0 1.0 10.0          # target, key count, then t/value pairs
sprite 2 0.0 0.0 0.0 1.0 1.0 1.0 0.0 0.0 1.0 1.0   # count, then t u0 v0 u1 v1
method 0.5 footstep                           # time, signal name
call_lua 0.5 3 on_footstep                    # time, script id, Lua method name
```

| Line | Meaning |
| --- | --- |
| `clip <version>` | The header. Version 1 is the only one that exists; an unknown version is a decode error. Required. |
| `duration <seconds>` | Clip length. Drives looping and `animation_finished`. |
| `flags <name>...` | `loop`, `ping_pong`, `root_motion`. Read by the player and combined with `\|`. |
| `root_motion <dx> <dy> <dr>` | Baked displacement per second. Applied by a pass that runs AFTER physics. |
| `value <target> <count> <t> <v>...` | A scalar track. |
| `sprite <count> <t> <u0> <v0> <u1> <v1>...` | Sprite-sheet UVs, frame by frame. |
| `method <t> <name>` | Fires the SIGNAL `<name>` at `t`. |
| `call_lua <t> <script_id> <fn>` | Calls the Lua method `fn` on `script_id`'s live instances at `t`. |

### Value targets

`value` animates a component field by name, so one track type covers every
component:

| Target | Component field |
| --- | --- |
| `transform_x`, `transform_y`, `transform_rotation` | `Transform.position.x/y`, `.rotation` |
| `sprite_uv_x`, `sprite_uv_y` | `Sprite.uv[0]`, `.uv[1]` |
| `sprite_tint` | `Sprite.tint` RGB (brightness; alpha is kept) |
| `light_energy` | `Light2D.energy` |
| `camera_zoom` | `Camera2D.zoom` |

An unknown target is a **decode error** (`error.UnknownTarget`), not a silent
no-op: a typo in a clip name should fail at load, where someone is watching,
rather than animate nothing at runtime. A target whose component the actor does
not have is a no-op, like a missing property.

### The method track

Two kinds of event, both fired against the segment of the clock actually
traversed this frame — so a loop wrap or a reverse pass cannot swallow one, and
an event exactly on the current frame fires once, not twice.

- **`method <t> <name>`** fires the signal `<name>`. Both typed Zig listeners and
  Lua `on_signal(name)` handlers in the current frame see it.
- **`call_lua <t> <script_id> <fn>`** calls the Lua method `fn` on every live
  instance of that script, and **does not** also fire a signal: the two dispatch
  paths would otherwise double-deliver the same footstep. A script that does not
  define the method is skipped rather than treated as an error, so one shared
  `run` clip works for characters only some of which handle a footstep.

`script_id` is a real id, **including 0** — scripts are numbered from zero, which
is why the event stores an optional target rather than treating `0` as "fire a
signal".

On a loop, the events are re-armed each cycle, so a walk cycle produces a
footstep every pass.

## Playback contract

Per actor, once per fixed tick:

1. **Read** `clip_id`, `time`, `speed`, `flags`, `blend_factor`, `state`.
2. **Advance** `time += speed * dt`, applying `loop`, `ping_pong` and boundary
   checks from the clip's flags alone. A non-looping clip that reaches its end
   stops at the boundary, sets `state = 3` and fires `animation_finished`.
3. **Sample** the value tracks, then the sprite frames. A crossfade (a non-zero
   `next_clip_id` with `blend_duration`) weights the current clip against the
   next one for *every* target, not just position, and advances both clocks.
4. **Fire** the method events for the segment traversed.
5. **Queue**: a finished clip pulls the next id from the four-slot queue, or
   finishes.

Root motion is deliberately **not** applied here.

### Root motion runs after physics

```
update(...)          -- advance clocks, sample tracks, fire events
<physics / gameplay> -- the solver and Lua write Transform
applyRootMotion(...) -- add the clip's baked displacement
```

That order is the contract: a displacement applied before the solver would be
overwritten by it. A runtime calls `applyRootMotion` once per fixed tick, after
everything that can move an actor.

## The Lua surface

```lua
local run = anim.load("assets/animations/run.anim")  -- id (GUID of the path)

function M:start()
  anim.play(self, run)          -- start the clip
end

function M:update(dt)
  anim.set_param(self, "speed", 1.5)   -- speed | time | clip | blend | state
end
```

`anim.load(path)` decodes and registers a clip and returns its handle; calling it
again re-decodes the file under the SAME id (hot reload). `anim.play`,
`anim.stop`, `anim.queue`, `anim.state` and `anim.length` are the rest of the
surface; `anim.set_param` sets one playback parameter by name, and an unknown
name is ignored so a typo cannot break a frame.

## Notes for the engine, measured

- **Zero allocations on the frame path.** The player walk is flat, the tracks are
  pre-decoded slices, and nothing grows a map or a string while a clip plays.
- **100 clips cost ~0.023 ms/frame** (p50) on the dev box, against a ROADMAP
  budget of 0.05 ms — see `zig build bench-animation`, which reports p50/p99 and
  fails if the frame path allocates:

  ```
  == M13 animation (100 clips, 240 frames, 16 warm-up) ==
    update + root motion   p50 0.0233 ms   p99 0.0303 ms   worst 0.0332 ms
    budget (ROADMAP M13)   p50 <= 0.050 ms                        OK
    clips resident         100
    method events fired    560 over 240 frames
    allocations in frame    0
  ```
