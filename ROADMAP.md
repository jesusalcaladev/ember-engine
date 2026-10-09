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

- v3 C API wrapper: `RigidBody2D`, `Collider2D`, sensors; sync into the ECS transforms.
- Mandatory physics→render interpolation; max 1 catch-up step per frame.
- Raycasts and queries exposed to Lua; collision events → Signals.

**Criteria**: platformer demo (player + moving platforms + sensors); determinism: 2 runs with the same inputs end with the same state hash; physics ≤ 2 ms with 2k bodies.

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
