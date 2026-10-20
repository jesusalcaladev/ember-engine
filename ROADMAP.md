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

**Instanced, 36-byte instances (measured, not assumed)**: 6 vertices x 36 B x 50k sprites = 10.8 MB uploaded per frame, which breaks spec §4 ("staging uploads <= 2 MB/frame") 5x. One 36-byte instance record (pos, half, uv as unorm16x4, tint as unorm8x4, slot, shape, layer, rotation) with the 4 quad corners derived from `vertex_index` in a triangle-strip pipeline keeps the same scene at **1.72 MB**, with no index buffer and no CPU vertex expansion. The record was 32 bytes until M5.8: the four extra ones are the sprite's ROTATION, which the renderer had been throwing away — a body could turn in the physics and stay square on the screen.

**Batching: why the default does not sort.** A per-frame comparison sort of 50k sprites costs ~200 ms of pure cache misses (measured: insertion sort first, heap sort after), against ~30 µs for a counting sort by layer and ~0 for the fast path. So: the emitter writes instances directly when the scene is already layer-monotonic (the normal case — painter's order IS layer order); `by_layer` uses the O(n) counting sort; `front_to_back` / `back_to_front` are opt-in per scene and are documented as costing O(n log n).

**Status: closed.** `zig build bench` measures the ECS criteria; `zig build test` covers the batcher, the atlas packer and the Dawn binding layouts (89 tests); the runtime prints the M2 acceptance numbers on exit:

| Criterion (spec §2/§4) | Budget | Measured (this machine, 1280x720) |
|---|---|---|
| 50k sprites in draw calls | ≤ 4 | **4** (1 scene + 3 SMAA passes) |
| Render CPU, encoding 50k sprites | ≤ 1.5 ms | **0.54 ms p50** (headless), 1.22 ms p50 windowed |
| Staging upload per frame | ≤ 2 MB | **1.72 MB** (36 B/instance — the rotation is four of them) |
| GPU objects created in frame | 0 | **0** |
| Allocations in the frame loop | 0 | **0** (arena high-water 0 B) |
| Frame time @ 60 FPS | 16.6 ms | **16.66 ms p50** (vsync-locked, p99 17.7 ms) |
| SMAA cost on GPU | ≤ 0.3 ms | measured in the per-pass timestamps |

### M3 — LuaJIT Scripting
**Goal**: gameplay exists and is enjoyable.

- Embed LuaJIT; behaviors with a `start / update / fixed_update / on_signal / on_destroy` lifecycle. **DONE**.
- **Global scripts** (Lua with no actor — managers, game flow, score, spawner) declared in `project.config` under `scripts { global "..." }`, mounted in file order, one global per script, and reachable from any script through `globals.get(name)` / `globals.exists(name)`. They run BEFORE the actors each frame, so a manager's decision is visible to every behavior that same frame. **DONE** (see `docs/reference/global-scripts.md`).
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
  - `StateMachine` component, handle-based (`u32` into an engine registry, like `Script`), because components must stay plain data (spec §7, `components/registry.zig` rules).
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

**Status: done.** `rand`, `noise`, the state machine, `Camera2D`, the `Timer` and the camera/timer Lua bindings ship, with metadata and stubs generated from the same registry (the "no metadata → the binding does not merge" gate covers all of them).

| Piece | State |
|---|---|
| `rand` (seed/float/range/int/chance/sign/gauss/choice/shuffle) | **done** — `core/random.zig`, deterministic PCG whose state is two plain integers, so save/load round-trips exactly |
| `noise` (seed/value/perlin/simplex/fbm/ridged) | **done** — `core/noise.zig`, stateless per call so terrain and weather can use different fields |
| State machine component (`sm.*`) | **done** — `script/statemachine.zig` + the `StateMachine` component (a `u32` handle, forced by the plain-data rule) |
| `Camera2D` | **done** — `ecs/components/camera.zig` (the component) + `ecs/camera.zig` (the fixed-step system) + the `camera.*` bindings, and the runtime now feeds its `View` into BOTH the culler and the draw camera |
| The hierarchical state machine | **done** — a state can have CHILDREN, which makes it COMPOUND: entering it enters the child's initial state, and the live state becomes a PATH ("moving/walk"). `sm.add_child_state` declares one, `sm.path` reads it, and `sm.is_in` asks the PATH — so "is the actor running?" is true while it is in "moving/walk". A transition is looked up from the deepest active state UP to the root, so a child handles the events it knows and its parent still handles the ones its children ignore. Sixteen flat states become three. |
| A* navigation | **done** — a uniform navigation grid rastered from the level's colliders, and an A* over it: `ai.pathfind(x1, y1, x2, y2)` returns the waypoints (the cells' centres, so a walker stays on walkable ground), `ai.is_walkable`, `ai.rebuild` and `ai.cell_size`. A sensor is walkable — a trigger is something you walk THROUGH. The search's scratch is allocated when the grid is BUILT, because a search happens inside a frame and the frame does not allocate. The path is SMOOTHED (a waypoint is dropped whenever a straight line can skip it, so the agent walks a line and not a staircase), and an UNREACHABLE goal gives the path to the closest reachable cell instead of nothing: the difference between "no way" and "the way is around there" is the difference between an agent that gives up and an agent that tries. |
| The scene load took the world with it | **done** — a scene load REPLACES the world, and everything wired to the old one went with it: the signal queue's capacity (back to zero, so the first event PANICKED the process), the collision bridge's subscription (so the events had nowhere to arrive), the entity slots, the spawn archetypes, the solver's bodies and the navigation grid. The world now has **RELOAD HOOKS**: a subsystem registers one at boot and never has to think about scene loads again, and the runtime's single hook re-establishes the lot. |
| Saving a game | **done** — `save.save(slot, opts)` saves **what the developer wants**: `opts.only` names the actors to save and `opts.exclude` the ones to leave out, and with neither every actor is saved. `save.load`, `save.list`, `save.delete` and `save.exists` complete it. The format is the same bit-exact `.zson` the editor uses, so a save and a scene are the same kind of document. |
| Encrypted saves | **done** — `opts.password` encrypts the file with **AES-256-GCM**, the key derived by **PBKDF2-HMAC-SHA256** (100 000 rounds) from the password and a random per-file salt, and the slot name authenticated as the associated data so a file cannot be moved between slots. A save with no password is written in the clear and says so in its header. A wrong password and a tampered file are the SAME failure on purpose: GCM cannot tell them apart and must not. |
| The steering was behind a flag | **done** — `world.nearby` measured ~16 us per call, ~100x what a spatial grid should cost, and the cause was NOT the query: the grid was rebuilt from EVERY sprite in the world, twice per frame, and a radius query then walked those cells. The grid now holds the BEHAVIOURS' actors (the ones that can be neighbours), and the steering is **on by default** — the flag stays for the record. |
| The runtime's physics produced no contacts | **done** — the cause was not the physics at all: the scene load REBUILDS the world (`zson.replace`), and it took two things with it. The **signal queue's capacity went back to zero**, so the first contact PANICKED the process ("the event queue is full (0 events)"), and the **collision bridge's subscription went with the old world**, so the contacts had nowhere to arrive. Both are re-established AFTER the scene load, next to the entity slots and the spawn archetypes — the whole class of bug in one place, because a world that is replaced takes everything wired to it with it. The editor loads scenes too and had the same hole. The reproduction is `behavior.test.a scene loaded into the world produces contacts`, and it runs the runtime's exact path. |
| The actor's life from a script | **done** — `actor.spawn(x, y, { name, script })` creates an actor (the behavior's `start` runs on the same frame), `actor.find_by_name(name)` finds one, and `actor.destroy(actor)` removes it. The `on_destroy` hook runs FIRST, with the actor still alive, so a handler that reads its position sees the truth; then the solver body goes, then the entity. |
| The runtime has a physics system | **done** — the runtime had none, so the `physics.*` bindings were inert in a game and the collision signal had nothing to publish. It now creates the solver world, syncs the scene's bodies, steps it in the fixed window, and moves the activity FOCUS with the camera (a focus that never moves tiers the whole world by its distance to the origin). |
| The area (Godot's `Area2D`) | **done, differently** — there is no `Area2D` component: an area is a `Collider2D` with `is_sensor = true`, and the contact signal says which it is. The engine added `other_is_sensor` to the contact event (a sensor reports its overlaps through the same queue as a solid body, so a script could not tell a trigger from a wall) and the collision signal now reaches Lua at all, with the two actors' handles in the payload. `physics.overlap_rect` takes an optional LAYER mask, so a trigger can ask about the one kind of actor it cares about. |
| `Timer` | **done** — `ecs/components/timer.zig` + `ecs/timer.zig` (fixed step, callbacks as signals) + the `timer.*` bindings, and since the M4.5 follow-up: `restart`, `set_duration`, `get_duration`, `get_elapsed`, `get_loops`, `set_kind`, a per-timer `time_scale`, `is_finished`, `is_paused`, and `get_dropped` (the cycles the catch-up cap refused, counted instead of dropped in silence). |
| The runtime loads a scene and attaches its behaviors | **done** — `--scene game.zson` loads a `.zson` into the world (`zson.replace`, in place, so every subsystem keeps its pointer) and attaches the behavior of every entity that carries a `Script` component. The `scripts { behavior "..." }` list's ORDER is the id: `Script {script: 1}` is the first entry. This is what makes a project a project. |
| Time scale + the `time.*` clock | **done** — `core/loop.zig` (`GameTime`): ONE owner of the global scale (0 = paused, 0.5 = slow motion, 2 = double speed) and the clock the scripts read (`time.delta`, `time.elapsed`, `time.scale`, `time.pause`…). The simulation, the scripts and the bindings all read the same clock, so a script can never move at a different speed than the world it is in. |
| Tweens (`tween.to`, `chain`, `kill`, `time_scale`) | **done** — `script/tween.zig` (the pool) + the `tween.*` bindings. A tween drives a COMPONENT of an actor (the real `Transform`, the real `Sprite.tint`), so the renderer draws the result. 28 easing curves in `core/math.zig` (`math.ease`), shared with the tweens. |
| Coroutines (`async`/`await`, `wait(seconds)`) | **done** — `self:async(fn)` + `self:wait(seconds)`, injected by the engine into every behavior's and global's `self`. The resume loop runs on the FIXED step, so a wait is a measure of GAME time: it slows with the global scale and replays identically. A coroutine that raises is logged, not fatal. |
| `Flow` (the global machine with a state stack) | **done** — `script/statemachine.zig` grows a `Flow`: the game's phases (menu → playing → paused → game over) as a GLOBAL machine, because the flow belongs to the game and not to an actor. The STACK is what makes "paused" work — it sits on top of "playing" and leaving it returns there. The `flow.*` bindings take the owning global's `self`. |
| AI steering + `line_of_sight` + `pathfind` | steering is **written and tested** but still behind `-Dsteering` (off), because `world.nearby` measures ~16 µs per call — about 100x the spatial grid's budget — and the cause is unknown. Shipping it on would put a known-wrong number inside the frame. `line_of_sight` and `pathfind` still need the M4 physics queries and remain open. |

Two things the M4.5 close found and fixed rather than papered over:

- **The registry's dense ids are load-bearing.** `Light2D` was id 11 before M7 added four concrete light kinds, and the ids every committed `.zson` file rests on cannot move — so the new kinds were APPENDED at 14..17 and `Camera2D`/`Timer` at 18/19. The test pins the whole seam now, not just the last two.
- **A camera spring that overshoots is a visible bug, not a rounding artefact.** The implicit-Euler integration passed its goal by 0.16 units on the first frame — the camera snapping past the player and correcting. `ecs/camera.zig` now uses the closed-form critically-damped solution (ζ = 1), which is monotonic by construction: `x = g + e·f·(1 + ωdt) + v·dt·f`.

### M5 — Base Editor + Integrated Play-in-editor
**Goal**: the Unity moment. Play and edit in the same window.

- ImGui shell (docking) with a **central workspace tab bar** (the Godot `2D → Script` pattern, designed in M5.7): scene viewport, actor hierarchy, component inspector, console, asset browser.
- **Play/Stop**: bit-exact snapshot on entry (infra already exists since M1) → game systems run inside the viewport → Stop restores the exact state.
- Editing during Play allowed with explicit rules (what persists and what does not).
- ImGuizmo for transforms; undo/redo on top of serialization; crash-safe autosave.

**Criteria**: Play runs inside the same window and UI; Stop restores an identical hash; editor overlay cost ≤ 2 ms extra; editing a component during Play reflects instantly.

**Status: in progress — the Play/Stop criterion is now real, not a promise.**

- **Play/Stop with the bit-exact snapshot is wired into the editor**
  (`src/tools/editor/editor_state.zig`, over the headless machine of
  `session/play.zig`). Entering Play captures a zson document of the world and
  hashes it; Stop restores that document IN PLACE through the same
  `zson.replace` the Open path uses — so no cached `*World` moves — clears the
  play-time undo journal (acts naming played-world entities would edit
  entities that no longer exist), and verifies the hash, reporting the result to
  the console rather than asserting on it. What Stop restores is the world AND
  the editor state that belongs to it: the selection comes back and the dirty
  flag returns to what it was when Play began.
- Begin/Stop are queued acts applied in `preFrame`, outside the frame's
  allocation guard — encode and decode allocate, and a click inside the frame
  records an intent, the same rule every other editor act follows.
- Behaviors survive the transaction by the rules of the swap: Stop's world
  replace kills every instance the played world held and the per-frame
  `sweepDestroyed` dispatches their `on_destroy`; a fresh Play warms
  `Behaviors.startAll` (idempotent) after the snapshot is taken, so everything
  `start` does is gameplay — part of what Stop throws away.

Still open for M5: crash-safe autosave, the written rules for editing during
Play, and a measured overlay-cost number against the ≤ 2 ms budget.

### M5.5 — Code editor + integrated documentation (Godot-style)
**Goal**: comfortable Lua writing inside the engine and the whole API one Ctrl+Click away.

- In-engine ImGui editor as the **`Script` workspace** (M5.7): file tabs inside the workspace, Lua syntax highlight, find/replace, parse-error markers.
- Autocomplete + contextual signatures + tooltips from the binding metadata (M3).
- **Ctrl+Click → Help panel**: description, typed parameters, return value and example of the function (like Godot's documentation).
- Browsable Help panel: index of the whole API + search.
- **LuaLS/EmmyLua stub generation** (`.luarc` + `meta/`) from the same metadata → autocomplete and hover in VS Code/Neovim/Zed.
- (LSP server with real go-to-def → post-1.0, see Post-1.0.)

**Criteria**: whole API navigable with Ctrl+Click from the in-engine editor; autocomplete popup < 10 ms; the editor stays within its budget (≤ 2 ms, spec §2); stubs are generated in CI and the build fails if they drift from the metadata.

### M5.7 — Editor workspaces: one editor, one tab bar
**Goal**: ONE editor, ONE window — a Godot-style top tab bar (`2D → Script → …`) switches the central view. The Sprite Editor, the Curve Editor, the Graphics Compositor and every other specialized editor this engine will ever need get a **slot in that bar**, never a window of their own.

The shell is shared and permanent; workspaces are pluggable and cheap.

**The rules — this is what keeps it clean:**

- **One central tab bar, top of the window.** Switching tabs swaps **only the central widget**. Hierarchy, inspector, console, asset browser and profiler are docks that stay put across every workspace — Godot's `2D/Script/AssetLib` and Unity's `Scene/Game`, minus the 3D we do not have.
- **Editor state is not workspace state.** Selection, open scene, undo stack and the running Play session belong to the editor: `2D → Script → 2D` comes back to the same selection, same camera, same undo history. Dropping them on a switch is how an editor starts feeling cheap.
- **A workspace is a row, not a type**: name, icon, shortcut, build/teardown of one central widget. Adding the Sprite Editor later must not touch the shell — if it does, the model is wrong.
- **Play is global, not a tab.** Play/Pause/Stop is one toolbar over everything; the game renders to the offscreen target (M2) and composes into the `2D` viewport, exactly as M5 requires.
- **Cost**: a tab switch does zero scene work (no reload, no re-instantiation), and the editor never exceeds its ≤ 2 ms overlay budget with any workspace open (spec §2).

**v1.0 is exactly two tabs** — the long-tail list below exists to say *no* until its subsystem does:

| Tab | Central view | Lands with |
|---|---|---|
| **2D** — the Scene Editor | viewport: pan/zoom, click- and drag-select, ImGuizmo move/rotate/scale, handles over `physics.reshape` / `occluder.set_polygon` | M5 |
| **Script** | in-engine Lua editor: file tabs, syntax highlight, autocomplete, Ctrl+Click → help | M5.5 |

Docks shared by both tabs: actor hierarchy, component inspector, console, asset browser, profiler + the Play/Pause/Stop toolbar.

**Still missing before that v1 editor is honest** (from [docs/EDITOR-SURFACE.md](docs/EDITOR-SURFACE.md)):

- [x] **Selection model** — multi-select + a current object the inspector binds to (`physics.contains_point` picks; nothing holds the state). **Done**: the session model has held a selection SET since M1 and the editor was not using it; the editor now keeps the CURRENT object (the one the inspector binds to) and the model holds the set, and the viewport's marquee fills it. The gizmo still edits the current object alone — the group transform is the next piece.
- [x] **Undo/redo** — an engine-side command journal on top of bit-exact serialization (M1). The single biggest gap. **Done**: `session/model.zig` journals every act; the editor drives it and never keeps a second stack.
- [ ] **Project file + file dialogs** — open/save `.zson`, no ad-hoc paths.
- [x] **Flat prefab authoring** — create from selection, instantiate, overrides visible and revertable. Storage exists since M1; the UI does not. **Done**: see below.
- [x] **Save/load UI + crash-safe autosave** (M5 bullet, still open). **Done**: see below.
- [x] **Hot reload** of scenes and assets while a tab is open (M6). **Done**: see below.

#### The viewport, done properly (M5.8)

The 2D tab is the editor's centre, and it was the one part of the shell that
was drawn rather than designed: the camera framed the WINDOW instead of the
viewport, the pointer was measured in the wrong axis, the gizmo was three
axis-aligned quads, and every dock wore ImGui's title bar on top of the
editor's own header. Four bugs, all of them visible, and all of them in the
same place — the part of the editor the user looks at most.
**The viewport is a REGION, and the camera is the region's camera.** The
hierarchy is on the left, the inspector on the right, the console at the
bottom, and the scene is what is left over. So the camera shows that
rectangle (`ecs.camera.View` grew an origin and a target size), the pointer is
measured from its top-left, the culler culls against it, and the middle of
the viewport is the middle of the camera's view. Before this the camera
centred on the window: the middle of the viewport was off-centre, the scene sat
under the docks, and half of what the camera showed was hidden.

**The world is y-up and the screen is y-down, and the pointer now agrees with
the renderer.** `ecs.camera.View` is the one place the two meet, and it used
to meet them the WRONG WAY UP: the renderer drew the world y-up (Box2D's
convention) while `screenToWorld` read the screen y-down, so every click in
the editor landed mirrored across the horizontal midline of the viewport. The
scene looked right and the picking did not, which is the worst kind of bug:
the two halves of the engine agreed on the picture and disagreed on the
pointer. The convention is now pinned by tests, in `ecs/camera.zig` and
`render/ui_draw.zig`.

**The gizmo is a gizmo.** Move (the object itself, plus the two local-axis
arrows), rotate (a ring with a knob) and scale (four corners, plus a centre
handle for a uniform scale), on the keyboard (W/E/R) and in a HUD that lives
INSIDE the region. The handles are drawn with ImGui's draw list, not with the
2D batcher: the batcher's quads do not rotate, so a selection outline that
follows the object's rotation, an arrow along a rotated axis and a rotation
ring are all impossible with it. The gizmo is drawn on the BACKGROUND list —
over the scene, under the panels — which is the layer it belongs to.

**A rotation you can see.** `Transform.rotation` had been carried by the ECS,
read by the physics and written by the gizmo, and thrown away on the way to
the screen: the sprite instance had no rotation field, so a body could turn
and its sprite stayed square. The instance is 36 bytes now (was 32), the
vertex shader turns the corners, and the 50k scene uploads 1.72 MB against
the 2 MB ceiling. The `SpriteInstance` struct is `extern` and its field
offsets are asserted at compile time, because the backend's vertex layout
names those offsets — and they were off by one, which is how a sprite on
layer 1 drew as a circle and `light.set_mask` matched nothing.

**Every ImGui flag was off by one bit.** `WindowFlags.NoTitleBar` was
ImGui's `NoResize`, `AlwaysAutoResize` was `NoBackground`, and the whole
table was shifted, so every dock in the editor grew ImGui's own title bar on
top of the editor's designed header and the menu bar never appeared. The
table is now pinned to the pinned `imgui.h`, and the docks spell out the
flags they want (a dock that lists a thousand entities has to scroll, and
`NoDecoration` takes the scrollbar with it).

What is still open, and is next: **multi-select and the drag-select
marquee** (the marquee is here; the GROUP transform — one gizmo moving the
whole selection — is not), and the handles over `physics.reshape` /
`occluder.set_polygon` that the 2D tab promises.

#### The fields, the grid and the frame cost (M5.8, second pass)

The second pass was the user's complaints, and every one of them turned out
to be a real bug rather than a taste:

**The inspector's fields showed no values.** The field's background was
painted AFTER the widget drew its text, so the background covered the number:
every field in the editor showed its unit ("px", "rad") and nothing else, and
the text fields showed their placeholder and never their content. ImGui draws
the frame AND the text, so the frame is ImGui's now and the theme styles it;
the only thing drawn on top is the focus ring.

**A field's label slot is an ABSOLUTE offset** from the line's start, which
is what a table needs and what a row inside a row cannot use: the "X" of an
X/Y pair jumped back to the column it never left and drew its box on top of
the row's own label — which is why "Position" read as "Po". There is a
relative label slot now, and the X/Y labels use it.

**The grid only ever doubled its cell**, so zooming in left three lonely
lines with very thick strokes between them. It adapts in both directions now,
and the axes are one pixel wide like every other line.

**The scene never reached the screen with the SMAA off.** The no-SMAA path
wrote its texel uniform into the EDGE uniform instead of the BLEND one — the
buffer the copy pass actually binds. With the SMAA on, the blend uniform had
been written by the SMAA's own passes, so the copy happened to read a valid
texel size and the frame appeared. With the SMAA off — which is what the
editor wants — nothing ever wrote it, the copy read zeros, and the editor had
a perfectly good viewport and nothing in it. The editor's SMAA is off by
default now: the scene being edited is flat 2D art, and three full-screen
passes are the most expensive thing in the frame on a weak GPU.

**The frame cost is on the status bar**: the frame's own milliseconds AND the
GPU's. A frame that is 40 ms long with 5 ms of CPU in it is a frame that is
WAITING, and the two look identical on a status bar that shows only one.

#### The icons (M5.8, third pass)

The editor's icons were drawn as geometry — a few line segments and an arc
each. That is exact at any DPI and free, and it is also why a rotate handle
does not look like a rotate handle.

So the icons are FILES now: `assets/icons/` holds a PNG per icon, the editor
packs them into one atlas at boot and hands it to the UI layer, which draws
the cell when it has one and the geometry when it does not. A missing file is
never an error — it is the drawn icon, and the editor looks the way it always
did.

Three things the loader does to each file, and each of them is the difference
between "an icon" and "a picture of an icon":

- **the transparent margin is cropped**, so the icon fills its box instead of
  sitting in the middle of one;
- **the ink is scaled to a 64px cell** with a box filter, so a 2px stroke does
  not alias into a dotted line;
- **the colour becomes white**, because an icon is a MASK: the theme tints it,
  and a black PNG multiplied by a blue tint is black.

The toolbar is icon buttons now (a row of pictures, not a row of words), and
the dock headers carry their icon.

#### Autosave, hot reload and flat prefabs

**Autosave is a recovery file, not a save.** The editor writes the world to
`<scene>.autosave` every 60 seconds while the document is dirty, and the write
goes through a temporary name and a rename — so a crash mid-write leaves the
PREVIOUS recovery file whole rather than a half-written one. At boot, a
recovery file newer than the scene is reported in the console, and File →
Recover takes it. The recovered document is marked unsaved: recovering is not
saving, and the user decides when the work becomes the file.

The interval is a field rather than a constant, so a preference can move it
into `project.config` without touching the frame loop. The timer runs on the
frame loop's clock and the WRITE is a queued act: encoding a world allocates
megabytes, and a frame may not (spec §3.1).

**Hot reload watches the file, not the buffer.** The scene file is watched
while it is open, and a change made outside the editor (a merge, a generator,
a second instance) is noticed. The editor does NOT reload on the spot: a
reload replaces the world, and the user may have unsaved work. The change is
recorded, the console says so, and File → Reload takes it. The editor's own
save is told apart from somebody else's by the mtime it recorded when it
saved.

**Flat prefabs are `.zson` files, and the overrides live in a sidecar.**

- A prefab is a **document**, written by `zson.encodeToStringEntities` — the
  same grammar as a scene, so there is no second format and no second parser
  to keep in sync with the component registry.
- **Create from selection** writes the selected entity AND its children to
  `prefabs/<name>.zson`. The children come along because a prefab of a
  "turret" that leaves the barrel behind is not what anyone means.
- **Instantiate** spawns the document at fresh identities
  (`zson.instantiateInto`), with the names made unique in the world
  (`enemy`, `enemy_2`) so two instances coexist. The instance is recorded in
  a **sidecar** — `<scene>.overrides`, a text file beside the scene.
- **The sidecar is where the overrides live**, and that is a decision worth
  stating: the overrides are per-COMPONENT, and a component cannot hold that
  without a registry entry — and the registry is append-only, so a
  `SpriteOverrides` component would be a permanent, load-bearing addition to
  the engine's data model to serve a purely editorial feature. The world is
  the SCENE; what the game loads must not carry editor bookkeeping. The
  sidecar is written by the editor only, and losing it loses the ability to
  revert — never the scene.
- **Revert to Prefab** writes the prefab's value back over the overridden
  component, through the same encoder and decoder a `.zson` file goes
  through. A revert that restored a merely-parsable value would be a lie, so
  the round trip is the contract and it is tested.

**The long tail** — one workspace per subsystem, in subsystem order, none before v1.0 and none before the thing it edits exists:

| Tab | What it edits | Gated on |
|---|---|---|
| **Sprite Editor** | pivot, atlas region, occluder polygon, blend mode | M6 import + M7 occluders |
| **Mixer** | bus tree, per-bus volume, sends | M8 buses (already in the runtime) |
| **Particles** | GPU emitter params, curves, live preview | M9 |
| **Animation** | `AnimationClip` tracks, keyframes, `AnimationTree` graph | M13 |
| **Curve Editor** | easing/key curves shared by animation, camera and light params | a serialized `Curve` asset; first consumer M13 |
| **UI Editor** | `Canvas`/`Control` anchors, containers, focus order | M14 |
| **TileMap Editor** | brush/erase, per-tile properties, autotiling + collision paint | M15 data format |
| **Timeline / Dialogue** | cutscene tracks (anim, audio, camera, signal), branch graph | M16 |
| **l10n** | translation tables, missing-key report | M17 |
| **Material / Shader** | node graph → WGSL, uniform editing | M18 (see Backlog) |
| **Input map** | actions, devices, runtime rebinding | M19 (see Backlog) |
| **Graphics Compositor** | node graph of render/post-FX passes over the M2 offscreen target | a render graph that exposes its passes (post-1.0) |
| **Nested Prefabs** | nested tree, override diff, apply/revert | flat prefabs proven in real projects first (post-1.0) |

**Criteria**: `2D ↔ Script` preserves selection, camera and undo history; a throwaway workspace registers as a single row with no shell change; the editor holds ≤ 2 ms (spec §2) with any workspace open; the "still missing" list is fully checked before v1.0 is called done.

### M6 — Asset pipeline
- Importers: PNG (→ atlas), WAV/OGG (→ audio), `.lua` (scripts), with stable GUIDs.
- Asset hot-reload < 250 ms; caches with byte-budget + eviction (spec §5).
- Virtual filesystem + pack file (`.pak`) for exports.

**Criteria**: editing an external PNG → visible in-game < 250 ms; the export loads only from the pack, no real filesystem.

**Status: closed.** `zig build test-assets` (36 tests, no window/GPU/Lua/Box2D)
covers content-sniffing importers for PNG/JPEG/WebP, WAV and Lua (OGG is probed;
its samples are decoded by miniaudio at load), the `.pak` writer+reader with
per-entry deflate, the VFS over `.pak` and filesystem, and event-driven hot
reload (mtime + content hash, decode, typed event). The render-side wiring that
makes a reload VISIBLE is `render/asset_reload.zig`, exercised end-to-end — a
real PNG edit on disk → decode → atlas page → texture write — by
`zig build test-light`.

- **Importers detect by bytes, not extension**, and hash with a wrapping FNV, so
  a Debug build no longer aborts on a path longer than a few bytes.
- **`.pak` has one encoder and one decoder** — variable-length paths, per-entry
  deflate through `std.compress.flate` (Zig ships no zstd compressor), and total
  validation at open. The draft's three mutually inconsistent encodings are gone.
- **Hot reload is driven by the directory watcher** (`reloadPath`); `scanAll` is
  the O(watched) fallback, never a per-frame call.
- **The reload reaches the GPU in place**: `render/asset_reload` re-blits a
  same-size edit over the sprite's own rect and re-uploads the page into the
  EXISTING texture, so a sprite's slot and UVs survive the edit; a resize repacks
  and reports `repositioned`. The runtime polls `assets/sprites` next to the audio
  watcher (outside the frame), and `sprite.set_image` registers each path as it
  packs it — which also fixes that binding's per-call atlas leak and its
  asset-slot-for-texture-slot mix-up.

Docs: [asset-pipeline](docs/reference/asset-pipeline.md).

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

**Status: closed.** `zig build test` (538 tests, the inotify directory watcher
included) covers the port, the mixer maths, the generation-checked voice pool,
the byte-budgeted bank, both backends, the command/event rings and the bus
registry; `zig build bench-audio` measures the criteria below; `zig build
test-api` drives `audio.*` and `sound.*` from real Lua against a real system;
the runtime wires the mixer, its signal bridge and the asset hot-reload.

Measured (`zig build bench-audio`, null backend, 64 emitters, 480-frame period at
48 kHz):

| Criterion | Budget | Measured |
|---|---|---|
| Simultaneous emitters | 64 | **64** (`voices_peak`) |
| Output latency | ≤ 20 ms | **10.0 ms** (480 frames @ 48 kHz) |
| `play()` on the main thread | one ring push, no allocation | **0.15 µs/voice**, 0 allocations |
| Mix per buffer | inside the 10 ms period | **1.12 ms** |
| xruns | 0 | **0** |
| Commands dropped | 0 | **0** |

The two threads never share mutable state: the main thread reserves pool slots
and pushes commands, the device thread fills a reserved slot and advances it —
which is what makes the frame path a fixed number of ring pushes with no
allocation, and what `bench-audio` proves with a counting allocator.

Notes on what shipped beyond the criteria:
- **Bank slot 0 is the "nothing loaded" sentinel** and the bank never hands it
  out, so `SoundEmitter2D.bank_slot = 0` is unambiguously "no sound".
- **A streaming slot refuses a hot-reload** (`error.StreamNotReloadable`): its
  PCM is a window into a refill ring, so re-decoding it would free an interior
  pointer.
- **`Audio.mixNsPerBuffer()`** exists because overruns are a symptom and the
  mix cost is the cause; the run report prints it.
- Audio never feeds the simulation (spec §6): no gameplay rule may branch on
  `is_playing`.

Docs: [audio-system](docs/reference/audio-system.md),
[audio-buses](docs/reference/audio-buses.md),
[audio-emitters](docs/reference/audio-emitters.md),
[audio-config](docs/reference/audio-config.md).

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

### M13 — Animation system (data-driven, component-based)
**Goal**: characters and objects move believably. Today the engine cannot animate anything; this is the largest missing subsystem.

- **`AnimationClip`** — asset (GUID in the M6 registry): fixed set of tracks that animate component fields over time. Cada clip tiene un ID handle (`u32`) y un conjunto definido de `track_ids` que saben qué field animan y cómo.
  - **Value track**: anima cualquier field `f32` o `v2` de cualquier componente (Transform.position, Sprite.tint, Light2D.energy, etc.). Es el track "general" que hace el sistema válido para cualquier component.
  - **Sprite track**: anima los `uv` de un sprite sheet frame a frame. Usa el GUID del sprite atlas asociado.
  - **Method track**: dispara un evento `call_lua` en un keyframe concreto (para footsteps, VFX, sounds). El evento lleva el `script_id` y el nombre de la función; el runtime Lua lo maneja.
  - **Flags por clip** (bitfield u8): `loop` (bit 0), `ping_pong` (bit 1), `root_motion` (bit 2). Estos flags son leídos por el sistema de reproducción y no hay código por pieza por clip.

- **`AnimationPlayer` component** — componente plain-data (`components.zig`): hold the state actual de reproducción de un clip por entity.
  - `clip_id: u32` — handle GUID al clip AnimationClip que se está reproduciendo (0 = nada).
  - `time: f32` — tiempo actual dentro del clip (0 → length).
  - `speed: f32` — multiplicador de tiempo (1.0 = normal, >0 = forward, <0 = reverse).
  - `flags: u8` — flags del clip (loop, ping_pong, root_motion) combinados con `|`.
  - `blend_factor: f32` — para crossfade suave al cambiar de clip (0 = nada, 1 = cambio instantáneo).
  - `state: u32` — state machine simple interna (0=idle, 1=run, 2=jump, etc.). Solo usado por el sistema de reproducción, no por designers.

- **`AnimationTree` system** — system fijo que procesa todas las entities con `AnimationPlayer` cada frame. **No hay nodes visuales.** El system hace esto por cada entity:
  1. **Leer config**: toma `clip_id`, `time`, `speed`, `flags`, `blend_factor` y `state` del componente `AnimationPlayer`.
  2. **Actualizar tiempo**: `time += speed * delta_time`. Aplica `loop`, `ping_pong` y boundary checking usando solo los flags del clip (sin código por clip).
  3. **Root motion** (si `root_motion` flag está set): el system lee los `Δposition` y `Δrotation` pre-calculados del clip en el keyframe actual y los **agrega al Transform component entity después de integrar la física Box2D M4**. Eso permite que el personaje siga su camino de animación aunque la física lo empuje. El clip tiene los datos de root motion "baked" — no hay cálculo runtime.
  4. **Emitting signals**: Si `time` llega al `end` del clip → emite signal `animation_finished` (drenado una vez por frame como todas las signals M3). Si `blend_factor` > 0 → crossfade al clip siguiente durante `blend_factor * length` frames (interpolación lineal de `time`, sin pop).
  5. **State machine**: el `state u32` del player cambia por signals (`animation_finished`) o por escritura directa desde Lua (`anim.state = 2`). Es un state machine simple, no un árbol complejo.

- **Integración con root-motion**: Cuando un clip tiene el flag `root_motion` set, el sistema `AnimationTree` aplica automáticamente el desplazamiento del clip al `Transform` entity cada frame. El desplazamiento viene "baked" en los keyframes del clip (el herramientas de autoría lo establece), así no hay cálculo costoso en tiempo de ejecución. Esto permite platformers precisos, personajes que caminan por caminos definidos en la animación, etc., y se integra transparente con el sistema de física M4.

### Criteria
- Clip importado de sprite sheet reproduce y hace loop sin pop.
- `anim.set_param` (usando metadata registry) modifica playback al frame siguiente.
- Root motion mueve actor determinísticamente cuando clip tiene flag `root_motion`.
- Hot-reload clip mantiene posición de playback (time actual se preserva).
- `animation_finished` signal se drena una vez por frame.
- Sistema cuesta ≤ 0.05 ms/frame para 100 clips simultaneously.
- Zero allocations por frame en el loop principal.

### Dependency actualizada
Ahora **M13 depende solo de**:
1. **M6 Asset pipeline** — clips son assets con GUID → ya completado.
2. **M3 Lua bindings + metadata registry** — para `set_param` y signals → ya completado.
3. **M4 Physics** — para root motion integration → ya completado.

**Por esto, M13 puede entregarse inmediatamente después de M6 sin esperar M14 o M15.** El roadmap lo tiene en posición M13 pero su implementation es liviana y no tiene bloqueos nuevos.

### M14 — Text rendering + Game UI
**Goal**: a game can show text and a HUD. **There is no font or text rendering anywhere in the engine today** — this milestone starts with it, and that is a hidden dependency for M17 too.

- **Text pipeline first**: font atlas + glyph rasterization (bitmap font and/or SDF from a TTF), glyph metrics, kerning-free layout for v1, batching on the existing sprite pipeline.
- **UI scene graph**: `Canvas` (layer/screen) + `Control` nodes — `Label`, `Panel`, `Button`, `TextureRect`, `ProgressBar`, `MarginContainer`, anchors (Godot's anchor model).
- **UI events**: hover, press, release, focus navigation; UI never leaks input into the game.
- **HUD**: bars, counters, combo popups; anchored to any screen size.
- Closes the "the editor has ImGui but the game has no UI" gap.

**Criteria**: a HUD with a health bar and score renders at 3 resolutions with correct anchoring; 200 labels in 1 draw call; a button fires a Lua callback.

**Status: runtime delivered — text rendering + the game UI are wired end to end.**

- **Text pipeline**: `stb_truetype` vendored; `render/font.zig` rasterizes glyphs on demand into the existing atlas, with metrics and `measure`/`positionOf`. Glyphs batch through the sprite pipeline, so no new GPU pass exists.
- **UI components**: `UiCanvas`, `Label`, `UiButton`, `UiPanel`, `UiProgressBar` (`ecs/components/ui.zig`), all POD, serialized to `.zson` (inline text encodes as a quoted string) and editable in the inspector.
- **The system** (`ecs/ui_system.zig`): canvas resolution (`pixel`/`fit`/`stretch`), Godot-style anchors, per-frame layout into each widget's `resolved` rect, hit-testing that only `UiButton`/`UiPanel` participate in, and the `ui_pressed` signal.
- **Lua surface**: the `ui.*` module (setters + `measure`/`rect`/`hovered`/`pressed`/`font_load`), `input.pointer_over_ui()`, and `scene.tint*` for CanvasModulate.
- **No input leak**: the world asks `input.pointer_over_ui()`; the action-input API is unchanged.

See [Game UI](docs/reference/game-ui.md) and [`samples/ui-hud/`](samples/ui-hud/). Deferred (unchanged from the plan): containers, focus navigation, rich text, and per-layer tint.

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

## M5 — Open world

**Goal**: a world far larger than one screen, at 60 Hz.

The cost of physics is not bodies, it is **bodies in contact at the same time**.
A sleeping body costs nothing to step; a disabled one costs nothing at all. Every
item below attacks that number rather than "make the solver faster".

- [x] **Sleeping, and not waking it by accident.** Box2D wakes a body when its
      velocity is written, so the sync only calls `setVelocity`/`setGravityScale`
      when the value actually changed. Measured: a settled 2 000-body scene went
      from 16.0 ms to 3.5 ms purely by not doing work the world had already told
      us it did not need. `StepStats.sleeping` reports awake vs asleep.
- [x] **Distance-based activity** (`physics/activity.zig`). Four tiers by
      distance to a focus point — `full` / `coarse` (one-circle proxy, sized to
      the half-diagonal so it is never smaller than the real shape) / `frozen`
      (disabled: out of the simulation *and* the broadphase) / `unloaded`
      (disabled, shape freed). Hysteresis on every boundary, because a body
      resting on a radius would otherwise flip tier per frame and pay a shape
      rebuild for it. Lazy retuning: the tier set is recomputed only when the
      focus moves far enough to matter.
- [x] **Sector partitioning** (`physics/sectors.zig`). A retune visits the cells
      near the focus instead of every body: 21 901 of 200 000 at 8x the map size.
      The index needs no rebuilding during play because a frozen body does not
      move, and every body that *does* move is in the active list, which is
      walked unconditionally.
- [x] **Bounded steps per frame.** Already in `Driver`: one catch-up step, the
      rest dropped, so a slow frame cannot start a spiral where catching up
      makes the next one slower. Godot's `max_physics_steps_per_frame`.
- [x] **Collision filtering / layers** (`ecs/collision_layers.zig`). 16 named
      bits, configured by name at load, symmetric pair test
      (`A.layer & B.mask` **and** `B.layer & A.mask`). Applies to shapes AND to
      raycasts, so a trigger volume on a non-colliding layer does not block
      sight. A body with no `CollisionLayers` is permissive, so a project that
      does not use layers behaves exactly like one that has no layer concept.
- [x] **Physics tuning as project settings** (`collision_layers.Tuning`):
      sleep thresholds, `time_before_sleep`, solver iterations, max steps per
      frame — validated at load, because a sleep threshold of zero looks exactly
      like "the sleeping code does not work".
- [x] **Broadphase, exposed.** Box2D keeps a dynamic AABB tree over the moving
      shapes and a second over the static ones, and only pairs the tree says are
      close ever become contacts. That is the whole reason 2 000 bodies do not
      cost 2 000 squared. `StepStats` now carries `broadphase_pairs`,
      `tree_height`, `static_tree_height`, `solver_bytes` and a derived
      `pairsPerBody()`, all reachable from Lua as `physics.stats()`.
      Exposed because a broadphase that stops rejecting pairs does not crash —
      it just gets slower, and the counters are the only way to notice before it
      becomes a stutter. Two acceptance checks drive it from Lua.
- [x] **The `cylinder` primitive.** The four the editor needs; there were three.
- [ ] **Physics on a separate thread.** Godot's
      `physics/2d/run_on_separate_thread`. Real, but it trades the deterministic
      fixed-step contract for multicore, and spec §6 is worth more here. Revisit
      if a project profile proves the single thread is the limit.

**Criterion**: `zig build bench-openworld` — 200 000 bodies, camera walking a
circuit that crosses every tier boundary in both directions. Deterministic, and
the frame cost is a function of what is NEAR rather than what EXISTS.

**Status**: the tiering works and is verified — 2 024 of 200 000 bodies
simulated (1.01%), 5-9x faster than the same world untiered, two camera walks
with the same hash. **The budget check still fails at 200k**, and the bench says
where the remaining time goes rather than hiding it: 8.5 ms of walk against 14.4
ms of tier *transitions*, 22 517 of them at ~640 ns each. Promotion rebuilds a
shape (destroy + create) and toggles the body; that is the next thing to make
cheap, and it is the last item before this milestone closes.

---

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
