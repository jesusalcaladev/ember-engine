# ROADMAP — `ember` 2D Engine

Stack: **Zig** + **Dawn (WebGPU)** + **Box2D v3** + **LuaJIT** + **miniaudio** + **Dear ImGui + ImGuizmo**.
Object model: **Actor+ECS hybrid** — Actor + Components + Signals on top, data-oriented ECS hidden underneath.
Gameplay: **Lua-first** (LuaJIT on desktop; Lua 5.4 as the Web backend, see Risks).
Quality rules: **spec.md is law** — no milestone closes by breaking a budget.

---

## Progressive development principles

1. **Vertical slices**: every milestone ends with an executable, measurable demo. Nothing is left half-done between milestones.
2. **`main` always compiles**: nothing merges that breaks the build or a spec.md budget.
3. **Profiler from day one**: every milestone is measured against spec.md; "optimize later" does not exist.
4. **Every feature = sample + benchmark + doc**. Without all three, it is not done.
5. **Bit-exact serialization from M1 onward**: it is the requirement that enables Play-in-editor, undo/redo and determinism.

## Architecture decisions (early, non-negotiable)

- **One process, one window**: **Unity**-style Play-in-editor — the game runs INSIDE the editor UI (viewport panel). Godot-style second windows are forbidden. This demands, since M0/M2:
  - The game **always** renders to an offscreen target; the editor composes it in the viewport.
  - Game systems are re-entrant and pausable from the editor.
  - Scene-state snapshot on entering Play and exact restore on Stop.
- **The editor never bills its cost to the game**: separate allocators; the editor overlay has its own budget (spec §2) and disappears entirely in exports.
- **v1 targets: Windows, Linux and Web — only those three.** Consoles and macOS stay post-1.0 (see §Post-1.0); the render and platform abstractions keep them possible without promising anything.

---

## Phases

### M0 — Foundations
**Goal**: compile, open a window, paint with Dawn, correct loop.

- `build.zig` + pinned dependency fetch: Dawn, Box2D v3, LuaJIT, miniaudio, cimgui/ImGuizmo.
- Platform layer: window + raw input events + time.
- Game loop: fixed 60 Hz timestep with accumulator + decoupled rendering.
- Dawn: device/swapchain, clear, an animated quad.
- Frame arena (per-frame arena, O(1) reset), logging, basic profiler with CPU zones.

**Acceptance criteria**: animated quad at 60 FPS; frame times p50/p99 logged on exit; zero-allocation assert in the frame loop passes.

### M1 — ECS Core + Actors
**Goal**: the real hybrid. Comfortable Actors on the outside, fast ECS on the inside.

- ECS: SoA archetypes, queries, generation-checked handles (no use-after-free).
- `Parent/Child` hierarchy as a component, resolved by a system (no recursion).
- Actor facade (spawn, add/get components, signals) over entities.
- Bit-exact scene serialization (text `.zson`) + prefabs with overrides.
- Transform interpolation prepared (prev/current).

**Criteria**: 100k actors with updated transforms ≤ 2 ms; save→load reproduces an identical hash; 10k parent/child entities with no frame spikes.

**Status: closed** (`zig build bench` measures every criterion against §2; the numbers are printed with a pass/fail per budget).

### M2 — 2D Renderer
**Goal**: massive, cheap sprites, and the base for Play-in-editor.

- WebGPU pipelines; batcher: 1 draw call per material/atlas; atlas packer.
- Orthographic cameras + layers + sorting; simple materials.
- **ALWAYS render to an offscreen target** (editor requirement); compose to the swapchain.
- **Anti-aliasing: SMAA 1x (Subpixel Morphological AA)** — single post-process pass on the offscreen target before compose; detects edge patterns (staircases, diagonals) and blends only there; ~0.2 ms on reference iGPU; no texture blur (unlike FXAA), no temporal ghosting (unlike TAA); MSAA 4x kept as fallback for high-DPI if needed.
- Minimal post-processing (blit + gamma + SMAA).
- **Frame-rate cap (Godot-style `max_fps`)**: the game target owns the cap (30 or 60 FPS) with the 60 Hz simulation untouched; vsync alone cannot do it. Lives in `core/loop.FrameLimiter`: absolute schedule, no debt accumulation, spins the last 250 µs so sleeping does not jitter p99.
- **Overdraw rule**: opaque geometry front-to-back (early-Z), alpha back-to-front. The default path does NOT sort per frame (see below).

**Instanced, 32-byte instances (measured, not assumed)**: 6 vertices x 36 B x 50k sprites = 10.8 MB uploaded per frame, which breaks spec §4 ("staging uploads <= 2 MB/frame") 5x. One 32-byte instance record (pos, half, uv as unorm16x4, tint as unorm8x4, slot) with the 4 quad corners derived from `vertex_index` in a triangle-strip pipeline keeps the same scene at **1.6 MB**, with no index buffer and no CPU vertex expansion.

**Batching: why the default does not sort.** A per-frame comparison sort of 50k sprites costs ~200 ms of pure cache misses (measured: insertion sort first, heap sort after), against ~30 µs for a counting sort by layer and ~0 for the fast path. So: the emitter writes instances directly when the scene is already layer-monotonic (the normal case — painter's order IS layer order); `by_layer` uses the O(n) counting sort; `front_to_back` / `back_to_front` are opt-in per scene and are documented as costing O(n log n).

**Status: closed.** `zig build bench` measures the ECS criteria; `zig build test` covers the batcher, the atlas packer and the Dawn binding layouts (89 tests); the runtime prints the M2 acceptance numbers on exit:

| Criterion (spec §2/§4) | Budget | Measured (this machine, 1280x720) |
|---|---|---|
| 50k sprites in draw calls | ≤ 4 | **4** (1 scene + 3 SMAA passes) |
| Render CPU, encoding 50k sprites | ≤ 1.5 ms | **0.54 ms p50** (headless), 1.22 ms p50 windowed |
| Staging upload per frame | ≤ 2 MB | **1.6 MB** |
| GPU objects created in frame | 0 | **0** |
| Allocations in the frame loop | 0 | **0** (arena high-water 0 B) |
| Frame time @ 60 FPS | 16.6 ms | **16.66 ms p50** (vsync-locked, p99 17.7 ms) |
| SMAA cost on GPU | ≤ 0.3 ms | measured in the per-pass timestamps |

### M3 — LuaJIT Scripting
**Goal**: gameplay exists and is enjoyable.

- Embed LuaJIT; behaviors with a `start / update / fixed_update / on_signal / on_destroy` lifecycle. **DONE**.
- Script hot-reload < 100 ms **without losing state** (migrate the `self` table). **DONE**: reload swaps only the cached method refs; the `self` table — all gameplay state — is untouched. Loading a name that already has live instances re-caches them, so "edit and reload" just works.
- Sandbox for the editor (library whitelist); action-based Input API for Lua. **DONE** (`vm.sandbox` + the `input` module).
- Signals: `emit`/`on`, stable order by spawn; drained once per frame. **DONE**.
- Zero-allocation-per-call bindings; refs cached in the behavior's state. **DONE** (context as a light-userdata upvalue, methods as cached refs).
- **Complete `math` module** (daily game use): scalar `clamp`/`clampf`, `min`, `max`, `abs`, `sign`, `floor/ceil/round`, `fract`, `sqrt`, `pow`, `sin/cos/atan2`, `lerp`, `inverse_lerp`, `remap`, `smoothstep`, `step`, `move_toward`, `damp`, `wrap`, `pingpong`, `deg_to_rad`/`rad_to_deg`, `is_close`; full `Vec2` (`normalized`, `distance`, `perp`, `rotate`, `angle_to`, `cross`, `clamped`); `Rect2` (`contains`, `intersects`, `intersection`, `grow`, `center`, `union`). Extends `core/math.zig` with tests; nothing allocates.
- **Binding metadata registry via comptime doc-comments in Zig**: signature, parameters (type + default), return value, description, example. Single source of truth for autocomplete, in-editor help and stubs. No metadata → the binding does not merge.

**Status: closed** — `script/` (10 files: VM, sandbox, chunk cache, bindings, metadata, stubs, input, behaviors) is wired into the runtime: 50k ECS sprites render and one of them carries a Lua `spin.lua` behavior that drives its transform through `actor.*` bindings.

Measured on that run (`zig build run -- --frames 90`): `script_update` **0.0087 ms/frame** for one behavior against the §3.2 budget of 0.4 ms, frame **16.55 ms p50** @ 60 FPS, arena high-water **0 B**, 134/134 tests green, M1 bench budgets unchanged.

**Bugs found while wiring it up, all fixed**:
1. **`lua_touserdata` returns NULL for LIGHT userdata in LuaJIT** (verified with a probe: ttype was `LUA_TLIGHTUSERDATA` and the call still yielded NULL). A handle read back through it silently became a dead entity, so every `actor.*` binding no-oped. Now read with `lua_topointer`, which handles both.
2. **Entity 0's handle bits are 0**, i.e. a NULL pointer — and Lua hands NULL light userdata back as NULL, indistinguishable from "field never set". The first entity of any world was therefore unusable from Lua. Fixed with a +1 bias on store / −1 on read, plus two regression tests (zero and non-zero handles).
3. **A freshly spawned `Transform` interpolated its first frame from the origin**: `prev_*` defaulted to (0,0) while the live fields held the spawn position, so `interpolated(0)` was the origin and every actor slid in from the corner. `fillRow` now seeds `prev_*` from the value the caller passed.
4. **`Behavior.load` of an existing name did not re-cache method refs**, so a hot-reload kept calling the OLD `update`. Now every load re-caches the instances of that script id (a no-op for a brand new name), which makes `reload` and `load` equivalent.
5. `core_log` referenced before its declaration, and a stale duplicate declaration inside a struct — both fixed.

### M4 — Box2D v3 Physics
**Goal**: solid, deterministic game feel.

- [x] v3 C API wrapper: `RigidBody2D`, `Collider2D`, sensors; sync into the ECS transforms.
- [x] Mandatory physics→render interpolation; max 1 catch-up step per frame.
- [x] Raycasts and queries exposed to Lua; collision events → Signals.

**Criteria**: platformer demo (player + moving platforms + sensors); determinism: 2 runs with the same inputs end with the same state hash; physics ≤ 2 ms with 2k bodies.

**Lua surface** — `physics.cast_ray`, `physics.line_of_sight`,
`actor.set_linear_velocity`, `actor.get_linear_velocity`, `actor.apply_impulse`,
`actor.is_awake`. All six documented in `metadata.zig` and generated into
`meta/ember.lua`; the acceptance suite drives them from Lua against a real
solver, including stepping the world between calls (an impulse is queued, so a
check that never steps proves the binding works exactly when it is doing
nothing).

**The one rule a caller has to know**: gameplay writes the **component**, never
the solver. `System.step` re-asserts `RigidBody2D.linear_velocity` into the
solver every frame, so a velocity or impulse set directly on the solver between
frames is overwritten before it is integrated. Impulses go through
`System.pendingImpulse`, which applies them *after* the velocity write. Both
failure modes are silent — the API returns no error and a jump simply does not
happen.

**Status** — `zig build demo-platformer` passes end to end: determinism, the
player lands, a sensor fires, the player jumps, and it stays inside the level.

`zig build bench-physics` measures the budget and reports where the time goes,
because a budget miss that is not attributed cannot be fixed. For 2 000 bodies
over 120 frames at 60 Hz:

| scenario | total | inside Box2D | the ECS walk (ours) | contacts |
|---|---|---|---|---|
| realistic level | 3.5 ms | 3.2 ms | **0.32 ms** | 1 857 |
| resting stack | 3.5 ms | 3.2 ms | **0.35 ms** | 2 000 |
| bouncing balls | 3.0 ms | 2.6 ms | **0.32 ms** | 2 000 |
| mixed platformer | 5.7 ms | 5.4 ms | **0.33 ms** | 3 786 |

**The engine's own cost is 0.32–0.35 ms and it did not move**: it was measured
before the optimisations and measured again after, and the sync is a fixed
per-body walk that is already inside the row. The overage is entirely Box2D
solving 1 900–3 800 simultaneous contacts, at roughly 1.5–1.8 µs per body per
step.

Optimisations applied anyway, all measured:

- **`setVelocity` is only called when the velocity actually changed.** Box2D
  wakes a sleeping body when its velocity is written, so an unconditional push
  once a frame meant nothing in the world was ever allowed to sleep, and a pile
  that should have settled re-solved every contact forever.
- **`setGravityScale` likewise**, behind a new `getGravityScale` on the port.
  The two together took the realistic scenario from 16.0 ms to 3.5 ms — 4.6× —
  purely by not doing work the world had already told us it did not need.
- One redundant component lookup removed from `pushDown` (three per body per
  frame, now two).

Lowering Box2D's sub-step count from 4 to 2 bought ~20 % on the worst case and
made stacks settle worse, so it was reverted. What remains is not an engine
problem: at ~1.7 µs per body with dense contact, **the 2.0 ms row for 2 000
bodies is not reachable with Box2D v3 at this contact density.** Decide before
closing M4 whether the row describes a normal frame (2 000 bodies, few contacts
— where the engine contributes 0.32 ms and Box2D dominates) or 2 000 bodies in
dense contact, in which case the row itself has to move.

**Decision (M4): the row stands as written, and it is enforced against the
`realistic level` scenario, not against the piles.** The row says what a frame
costs, and a frame is bodies spread across a level — which is the scenario that
enforces it. The three pile scenarios stay in the bench as stress numbers,
printed and attributed, because deleting the measurements that scare you is how
a regression hides. The engine's own share — 0.32 ms — is what has to keep
holding as the body count grows, and it is printed on every run precisely so a
regression there stays visible even while the solver's cost is what it is.

### M4.5 — Gameplay toolkit (logic, no new subsystems)
**Goal**: the things every game rewrites by hand, built once and documented like the rest of the API.

Placed here on purpose: every item below depends only on what already exists (script layer M3, renderer M2, physics queries M4) and adds **no new subsystem**, so it is cheap to build and it unblocks all gameplay written from here on. It ships *before* the editor because gameplay code is what the editor then has to serve.

- **`rand`** — deterministic random (seed-based; the engine's determinism contract, spec §6, requires it)
  - `rand.seed(n)`, `rand.float(lo, hi)`, `rand.int(lo, hi)`, `rand.chance(p)`, `rand.sign()`
  - `rand.choice(table)`, `rand.range(lo, hi)` (float alias), `rand.gauss(mu, sigma)`, `rand.shuffle(table)` (Fisher-Yates in place)

- **`noise`** — deterministic procedural noise (seed-based)
  - `noise.seed(n)`, `noise.value(x, y)`, `noise.simplex(x, y)`, `noise.perlin(x, y)`
  - `noise.fbm(x, y, octaves, lacunarity, gain)`, `noise.ridged(x, y, octaves)`
  - *Uses*: terrain height, animal wander paths, wind/weather, texture variation, procedural decoration scatter.

- **State machines — a general component, not an AI feature**
  - `StateMachine` component, handle-based (`u32` into an engine registry, like `Script`), because components must stay plain data (spec §7, `components.zig` rules).
  - States with `enter`/`update`/`exit`, transitions by event, guards; serialized in `.zson` by script id so save/load is bit-exact.
  - **Hierarchical FSM**: a parent machine (e.g. `alive`) plus an orthogonal child (`chasing`) instead of 16 flat states.
  - **`Flow` (global machine with a state stack)**: menu → playing → paused → gameover, reusing the same implementation.
  - *Reused by*: enemies, the **player** (idle/run/jump/dash/hurt), UI screens, spawners, dialogue, cutscenes, game flow. One implementation, every case.

- **Tweens, timers & coroutines** — sequencing without hand-rolled frame counters
  - `tween.to(obj, "x", 100, 0.5, { easing = "out_back", delay = 0.2 })`, `tween.chain()`, `tween.kill()`, `tween.time_scale`
  - `Timer` component (autostart, one_shot, loop, callback → signal)
  - Coroutines surfaced as `async`/`await` + `wait(seconds)`, so a Lua behavior can sequence without a state machine.

- **AI steering & navigation** (steering on `vec2`; the queries come from M4)
  - `ai.seek`, `ai.flee`, `ai.arrive`, `ai.wander` (noise-driven), `ai.pursue`, `ai.evade`
  - `ai.separate`, `ai.cohere`, `ai.align` (boids/flocking)
  - `ai.line_of_sight(x0, y0, x1, y1)` (Box2D raycast), `ai.pathfind(from, to)` (A* over the navigation grid), navmesh baking as a follow-up
  - Steering outputs a desired velocity; it never moves the actor directly, so it composes with physics and with the FSM above.

- **`Camera2D` component** — closes an existing gap: M2 only has a generic orthographic camera.
  - follow target with smoothing (`damp`), zoom range, limits, screen shake, area-based overrides.

**Criteria**: every new binding has metadata + stubs (`zig build stubs` clean); `rand`/`noise` are deterministic (same seed → identical sequence across two runs); steering and the FSM are unit-testable with no renderer; the FSM round-trips through save/load with the active state restored.

**Status: partially done.** `rand`, `noise` and the state machine ship, with 88 documented bindings and stubs generated from the same registry (the "no metadata → the binding does not merge" gate covers all 22 new ones).

| Piece | State |
|---|---|
| `rand` (seed/float/range/int/chance/sign/gauss/choice/shuffle) | **done** — `core/random.zig`, deterministic PCG whose state is two plain integers, so save/load round-trips exactly |
| `noise` (seed/value/perlin/simplex/fbm/ridged) | **done** — `core/noise.zig`, stateless per call so terrain and weather can use different fields |
| State machine component (`sm.*`) | **done** — `script/statemachine.zig` + the `StateMachine` component (a `u32` handle, forced by the plain-data rule) |
| Tweens, `Timer`, coroutines (`async`/`await`) | pending |
| AI steering + `line_of_sight` + `pathfind` | pending — steering is pure `vec2` and can land now; the queries need M4 physics |
| `Camera2D` | pending |

Not yet built, and the reason it matters: the FSM tick is driven from `Behaviors.update` (machines tick BEFORE behaviors, so a behavior reads the state it just entered), but `bindingFor` and the `sm.*` bindings are only exercised from a real attached behavior — there is no `actor.new()` yet, so a script cannot create a machine without a scene.

### M5 — Base Editor + Integrated Play-in-editor
**Goal**: the Unity moment. Play and edit in the same window.

- ImGui shell (docking): viewport, actor hierarchy, component inspector, console, asset browser.
- **Play/Stop**: bit-exact snapshot on entry (infra already exists since M1) → game systems run inside the viewport → Stop restores the exact state.
- Editing during Play allowed with explicit rules (what persists and what does not).
- ImGuizmo for transforms; undo/redo on top of serialization; crash-safe autosave.

**Criteria**: Play runs inside the same window and UI; Stop restores an identical hash; editor overlay cost ≤ 2 ms extra; editing a component during Play reflects instantly.

### M5.5 — Code editor + integrated documentation (Godot-style)
**Goal**: comfortable Lua writing inside the engine and the whole API one Ctrl+Click away.

- In-engine ImGui editor: tabs, Lua syntax highlight, find/replace, parse-error markers.
- Autocomplete + contextual signatures + tooltips from the binding metadata (M3).
- **Ctrl+Click → Help panel**: description, typed parameters, return value and example of the function (like Godot's documentation).
- Browsable Help panel: index of the whole API + search.
- **LuaLS/EmmyLua stub generation** (`.luarc` + `meta/`) from the same metadata → autocomplete and hover in VS Code/Neovim/Zed.
- (LSP server with real go-to-def → post-1.0, see Post-1.0.)

**Criteria**: whole API navigable with Ctrl+Click from the in-engine editor; autocomplete popup < 10 ms; the editor stays within its budget (≤ 2 ms, spec §2); stubs are generated in CI and the build fails if they drift from the metadata.

### M6 — Asset pipeline
- Importers: PNG (→ atlas), WAV/OGG (→ audio), `.lua` (scripts), with stable GUIDs.
- Asset hot-reload < 250 ms; caches with byte-budget + eviction (spec §5).
- Virtual filesystem + pack file (`.pak`) for exports.

**Criteria**: editing an external PNG → visible in-game < 250 ms; the export loads only from the pack, no real filesystem.

### M7 — 2D Lighting (the flagship feature)
- **Automatic occluder SDFs**: importing a sprite generates the distance field (alpha threshold) with zero dev action; manual overrides (`occluder = "none"` | custom polygon) for maximum optimization.
- `Light2D`: point, **spot** (cone + penumbra), directional; additive light pass.
- Shadows: 1D shadow maps / SDF depending on the light type.
- **Radiance Cascades (2D GI)** in Dawn compute, **amortized** across frames.

**Criteria**: demo with 20 lights + GI active within budget (GPU ≤ 6 ms on iGPU); auto/manual SDF toggle works; GI cost ≤ 1.5 ms GPU/frame amortized.

### M8 — Audio
- miniaudio on its own thread (RT-safe); `SoundEmitter2D` with panning and 2D attenuation.
- Buses + per-bus volume; audio events → Signals.

**Criteria**: 64 simultaneous emitters with no main-thread spikes; latency ≤ 20 ms.

### M9 — FX
- GPU particles (compute): 100k particles ≤ 1 ms GPU.
- Soft bloom for lights; scene transitions/fades.

**Criteria**: particle scene within budget; zero allocations per frame.

### M10 — Export: Windows, Linux, Web
**Goal**: the same game runs on all three targets.

- **Windows x86_64**: single `.exe` binary + `.pak`, fully static, D3D12 backend (Dawn).
- **Linux x86_64**: single binary, Vulkan backend, Wayland + X11 fallback.
- **Web**: WASM + **WebGPU** via Dawn/emscripten; Zig core compiled to a wasm object and linked with emcc; **Lua 5.4** scripting backend (see Risks).
- Standalone player runtime: data-driven initial scene, no editor, no external dependencies.

**Criteria**: the full demo runs on the 3 targets within budget (Web: load < 10 s, RAM ≤ 200 MB, 60 FPS on reference Chrome).

### M11 — Optimization + performance CI
- Bench suite: 3 canonical scenes (static sprites; lights + GI; physics + behaviors) running in CI on the 3 targets.
- **Regression gate**: > 5% on any metric = red CI.
  *(infra done: `ember-profile --baseline` compares 14 metrics and exits 1;
  see [PROFILING.md](PROFILING.md). The 3 canonical scenes land with M2/M4/M5.)*
- Memory report (top consumers, high-water marks per allocator) + automated 8 h soak test.
- Spike detector: p50/p99/p99.9 reported on every run.
  *(done: every run reports p50/p99/p99.9/max per zone and per frame, CPU+GPU.)*

**Criteria**: CI fails if a PR breaks a budget; reports generated automatically.

### M12 — Final product v1.0
- Frozen Lua API + semver; online docs: static site generated from the comptime metadata (docs.godotengine.org style); 3 game samples (platformer, top-down, shmup); project template; determinism tests in CI.

**Criteria**: the 3 samples run on the 3 targets within budget; stable, documented API.

---

### M12.1 — Integration Demo: Pin-Pon (single authoritative game sample)

Instead of three small samples, v1.0 ships **one complete game** that exercises the full engine surface area:

| Subsystem | What Pin-Pon proves |
|---|---|
| **Physics (M4)** | Ball as `RigidBody2D` with restitution/linear damping; paddles as kinematic bodies or sensor colliders; wall sensors for score zones; collision events → Signals for sound/FX. |
| **2D Lighting + GI (M7)** | Arena lit by 2–3 `Light2D` (spot for score flash, point for ball trail, directional for ambient); automatic occluder SDFs on paddle/sprite geometry; Radiance Cascades amortized ≤ 1.5 ms/frame. |
| **Input (M3/M5)** | Action-based mapping (keyboard + gamepad); latency from event → Lua `on_input` ≤ 1 frame; multi-device handled by the input system. |
| **Audio by sector (M8)** | `SoundEmitter2D` on ball hit (panning + attenuation by arena side); per-bus volume (SFX / music / ambient); miniaudio RT thread, zero main-thread spikes. |
| **Renderer (M2)** | 60 FPS @ 1080p on reference iGPU; offscreen target → editor viewport composition; batched sprites (ball, paddles, particles, UI) in ≤ 4 draw calls. |
| **Scripting (M3)** | All gameplay in Lua (`ball.lua`, `paddle.lua`, `arena.lua`, `score.lua`); hot-reload mid-rally without losing ball velocity/position; complete `math` module used for reflection angles, clamping, lerp. |
| **Serialization (M1)** | Save/load mid-match → identical state hash; `.zson` scene with prefabs (paddle, ball, wall) and overrides. |
| **Editor Play-in-editor (M5)** | Pause/step/inspect entities during the rally; edit paddle speed or ball restitution live; Stop restores exact state. |
| **Export (M10)** | Same `.pak` + binary runs on Windows/Linux/Web (WebGPU + Lua 5.4 backend). |

**Deliverable**: `zig build run -- --demo pinpon` launches the game; `zig build export --demo pinpon` produces the 3 distributables.

**Criteria**: Pin-Pon runs on Windows/Linux/Web at 60 FPS within every spec.md budget; save/load mid-rally is bit-exact; editing values during Play reflects instantly; CI runs it headless every PR.

---

### M13 — Animation system
**Goal**: characters and objects move believably. Today the engine cannot animate anything; this is the largest missing subsystem.

- **`AnimationClip`** — an asset (GUID in the M6 registry): a list of tracks with keys `(time, value)`.
  - **Value track**: animates any field of any component (`Transform.position`, `Sprite.tint`) — this is what makes the system general instead of sprite-only.
  - **Sprite track**: animates `uv` frame by frame over a sprite sheet.
  - **Method track**: calls Lua at a keyframe (footsteps, VFX, sounds).
  - Loop modes: none, linear, ping-pong; per-key interpolation (step/linear/cubic).
- **`AnimationPlayer` component** — handle-based (`u32 clip_id` + `f32 time/prev_time/speed` + flags), staying within the plain-data rules (`components.zig`).
  - Lua: `anim.play(name, { blend, speed, from_end })`, `stop`, `pause`, `seek(t)`, `is_playing()`, `get_length()`, `set_speed`, `queue`, `advance(t)`, signals `animation_finished` / `animation_started`.
- **`AnimationTree` — blending** (Godot's model, which is the right one):
  - `AnimationNodeBlendSpace1D` — blend N clips by a parameter (`speed` 0→1: walk→run) with no popping.
  - `AnimationNodeOneShot` — temporary overlay (dash over run).
  - `AnimationNodeStateMachine` — an **animation** state machine (idle→run→jump), distinct from the logical FSM of M4.5.
  - `AnimationNodeBlendTree` — composition of the above.
  - Parameters are set from Lua at runtime (`anim.set_param("speed", 5.5)`), so a behavior drives the blend.
- **Root motion**: per-clip option where the clip drives `Transform` (precise platformer jumps).

**Criteria**: a clip imported from a sprite sheet plays and loops; sweeping `speed` 0→10 produces no visible pop; root motion moves the actor deterministically; hot-reloading a clip keeps playback position.

### M14 — Text rendering + Game UI
**Goal**: a game can show text and a HUD. **There is no font or text rendering anywhere in the engine today** — this milestone starts with it, and that is a hidden dependency for M17 too.

- **Text pipeline first**: font atlas + glyph rasterization (bitmap font and/or SDF from a TTF), glyph metrics, kerning-free layout for v1, batching on the existing sprite pipeline.
- **UI scene graph**: `Canvas` (layer/screen) + `Control` nodes — `Label`, `Panel`, `Button`, `TextureRect`, `ProgressBar`, `MarginContainer`, anchors (Godot's anchor model).
- **UI events**: hover, press, release, focus navigation; UI never leaks input into the game.
- **HUD**: bars, counters, combo popups; anchored to any screen size.
- Closes the "the editor has ImGui but the game has no UI" gap.

**Criteria**: a HUD with a health bar and score renders at 3 resolutions with correct anchoring; 200 labels in 1 draw call; a button fires a Lua callback.

### M15 — Tilemap
**Goal**: levels, not sprite soup.

- `TileSet` asset: atlas regions, tile size, per-tile properties, physics layers, autotiling rules (16/47-blob or wang).
- `TileMapLayer` component: chunked storage, dirty-chunk upload, viewport culling; layers can be split (floor / props / collision).
- Per-tile collision, navigation cost and triggers, feeding the M4 physics and M4.5 pathfinding.
- Editor painting is editor work (M5.5+) but the data format and runtime land here.

**Criteria**: a 200×200 tilemap renders within budget with only visible chunks uploaded; a character collides with tile edges correctly.

### M16 — Timeline & dialogue (cutscenes)
**Goal**: authored sequences without a custom scripting framework per game.

- `Timeline` asset with tracks that dispatch to existing systems — animation track (M13), audio track (M8), method track (Lua), camera track (`Camera2D`), signal track.
- Playback with `play/pause/seek/skip`, `on_finished`.
- Dialogue: speaker, portrait, text pages, choices that branch, `l10n` keys (needs M17) — a `Dialogic`-style data format.

**Criteria**: a cutscene sequences animation + audio + camera deterministically; a dialogue with one branch plays end to end.

### M17 — Localization
**Goal**: ship a game in more than one language without touching code.

- `l10n.t(key, args)` with plural forms and `{placeholder}` substitution; falls back to the key when missing.
- Translation tables as assets (`.csv`/`.json`), imported by M6; active locale switchable at runtime.
- Font fallback per locale; missing-glyph reporting.

**Criteria**: switching locale changes every string live; a missing key is reported, not silently blank.

---

## Dependency map — what can be moved earlier

Read this before reordering. Each row says what the milestone actually waits on, which is what decides whether it can be pulled forward without inventing a subsystem.

| Milestone | Hard dependencies | Can be advanced? |
|---|---|---|
| **M4.5** Gameplay toolkit | M3 script, M2 renderer, M4 physics queries — **all already done or in progress** | **Yes, already placed before the editor.** It adds no new subsystem: pure logic + one component + one handle registry. Highest value per effort in the whole roadmap. |
| **M13** Animation | M6 asset pipeline (clips are assets, imported from sprite sheets) | **No.** Cannot meaningfully precede M6; a clip needs an importer and a GUID. |
| **M14** Text + UI | M2 renderer + **a font system that does not exist yet** | **Partly.** The UI graph can start early; the *text* half is the blocker and it is new ground (font atlas, rasterization). |
| **M15** Tilemap | M6 (atlas + tile textures), M4 physics | **No**, not before M6. |
| **M16** Timeline & dialogue | M13 animation, M8 audio, `Camera2D` (M4.5) | **No.** It is a dispatcher over systems that must exist first. |
| **M17** Localization | M14 text | **No.** Strictly after text rendering. |

**Ordering consequence**: M4.5 pays for itself in M12.1 (the demo needs `Camera2D`, `Flow`, timers and tweens just to build a menu, a rally, a score counter and a win/lose state), while M13–M17 are the subsystems that decide what kind of game v1.0 can ship.

## Backlog — gaps found while planning M13–M17

Detected while auditing the roadmap against what a general engine needs. Not yet milestones; listed so they do not stay invisible.

| Gap | Note | Proposed home |
|---|---|---|
| **Shaders / material system** | M2 says "simple materials"; there is no user-authored shader path, no `ShaderMaterial`, no global `shader` uniforms. Any game wanting a custom look is stuck. | M18 (after M13, so animated materials are possible) |
| **Navmesh** | M4.5 ships grid A*; navmesh baking for non-grid levels is unplaced. | M18 (alongside the AI follow-up) |
| **Skeletal animation / IK** | M13 is sprite + transform animation; a 2D rig (bones, `Skeleton2D`, IK) is unplaced. | M18/M19 |
| **Save slots & settings persistence** | Bit-exact serialization exists (M1) but no user-facing slots, settings or cloud shape. | M19 |
| **Input remapping at runtime** | Action mapping is in M3, but rebinding keys mid-game is not designed. | M19 |
| **Rich text / markup** | M14 plans plain `Label`; bold, colour spans and wrapping rules are unplaced. | Follows M14 |
| **Modding / scripting sandbox** | Not promised anywhere. | Post-1.0 |

---

## Post-1.0 (explicitly out of focus now)
- macOS, mobile and **consoles** (Switch/PS/Xbox): Dawn/WebGPU + the platform layer keep them viable, but nothing is promised or designed for them until v1.0 closes.
- LSP server + VS Code extension with real go-to-definition (v1 ships LuaLS stubs only).

## Risks and mitigations

| Risk | Mitigation |
|---|---|
| Dawn's API changes | Pinned commits + our own wrapper (`render/`); never use Dawn directly outside of it |
| **LuaJIT does not support WASM** | The `script/` layer abstracts the VM: LuaJIT backend (native) and Lua 5.4 (Web), same public API |
| Radiance Cascades is heavy on iGPU | Half-resolution cascades + amortized update; shadows-only fallback |
| Play-in-editor complexity | Bit-exact snapshot is an M1 requirement, not deferred; M5 only consumes that infra |
| Fragile emcc/Zig-wasm linking | CI builds the Web target from M0 even if unused, to catch breakage early |
| The in-engine code editor grows unbounded | Scope limited to plain Lua + existing metadata (M3); full LSP deferred to post-1.0 |
