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

### M2 — 2D Renderer
**Goal**: massive, cheap sprites, and the base for Play-in-editor.

- WebGPU pipelines; batcher: 1 draw call per material/atlas; atlas packer.
- Orthographic cameras + layers + sorting; simple materials.
- **ALWAYS render to an offscreen target** (editor requirement); compose to the swapchain.
- Minimal post-processing (blit + gamma).

**Criteria**: 50k sprites in ≤ 4 draw calls @ 60 FPS; GPU frame ≤ 4 ms on the reference iGPU; assert of zero buffer/pipeline creations per frame.

### M3 — LuaJIT Scripting
**Goal**: gameplay exists and is enjoyable.

- Embed LuaJIT; behaviors with a `start / update / fixed_update / on_signal / on_destroy` lifecycle.
- Script hot-reload < 100 ms **without losing state** (migrate the `self` table).
- Sandbox for the editor (library whitelist); action-based Input API for Lua.
- Signals: `emit`/`on`, stable order by spawn; drained once per frame.
- Zero-allocation-per-call bindings; refs cached in the behavior's state.
- **Complete `math` module** (daily game use): scalar `clamp`/`clampf`, `min`, `max`, `abs`, `sign`, `floor/ceil/round`, `fract`, `sqrt`, `pow`, `sin/cos/atan2`, `lerp`, `inverse_lerp`, `remap`, `smoothstep`, `step`, `move_toward`, `damp`, `wrap`, `pingpong`, `deg_to_rad`/`rad_to_deg`, `is_close`; full `Vec2` (`normalized`, `distance`, `perp`, `rotate`, `angle_to`, `cross`, `clamped`); `Rect2` (`contains`, `intersects`, `intersection`, `grow`, `center`, `union`). Extends `core/math.zig` with tests; nothing allocates.
- **Binding metadata registry via comptime doc-comments in Zig**: signature, parameters (type + default), return value, description, example. Single source of truth for autocomplete, in-editor help and stubs. No metadata → the binding does not merge.

**Criteria**: the blueprint's `player.lua` runs unchanged; hot-reload while the game runs; 10k behavior updates ≤ 2 ms; incremental GC step ≤ 0.4 ms/frame; every API exposed to Lua has metadata + example; complete `math` with unit tests.

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
- Memory report (top consumers, high-water marks per allocator) + automated 8 h soak test.
- Spike detector: p50/p99/p99.9 reported on every run.

**Criteria**: CI fails if a PR breaks a budget; reports generated automatically.

### M12 — Final product v1.0
- Frozen Lua API + semver; online docs: static site generated from the comptime metadata (docs.godotengine.org style); 3 game samples (platformer, top-down, shmup); project template; determinism tests in CI.

**Criteria**: the 3 samples run on the 3 targets within budget; stable, documented API.

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
