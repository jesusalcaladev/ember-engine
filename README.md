# Ember Engine

**Ember** is a proprietary 2D game engine by **Daara Studios**, written in Zig
with a Dawn (WebGPU) renderer, Box2D v3 physics and LuaJIT scripting.
Repository: `git@github.com:jesusalcaladev/ember-engine.git`.

> Proprietary software — see [LICENSE](LICENSE). Copyright (c) 2026 Daara Studios.

## Status

Milestone **M2 — 2D Renderer** is closed on top of M1 and M0 (see
[ROADMAP.md](ROADMAP.md) for the full plan):

- **Instanced sprites**: 32 bytes per sprite (pos, half-extents, atlas uv as
  unorm16x4, tint as unorm8x4, texture slot), quad corners derived from
  `vertex_index` in a triangle-strip pipeline. 50k sprites = **1.6 MB/frame**
  (spec §4 ceiling: 2 MB) in **1 draw call**.
- **Always offscreen**: the game renders into an offscreen color+depth target and
  composes to the swapchain, which is what Play-in-editor needs (spec §7).
- **SMAA 1x**: subpixel morphological anti-aliasing in 3 passes, the first two at
  half resolution. No texture blur (unlike FXAA), no ghosting (unlike TAA).
- **Atlas packer**: deterministic shelf packing + alpha decontamination.
- **Frame limiter**: Godot-style `max_fps` (30 or 60) with the 60 Hz simulation
  untouched; vsync cannot do this, the game target owns the cap.

Measured on the canonical scene (50k sprites, 1280x720, ReleaseSafe):

| Criterion | Budget | Measured |
|---|---|---|
| Draw calls | ≤ 4 | **4** |
| Render CPU (encode 50k sprites) | ≤ 1.5 ms | **0.54 ms p50** |
| Staging upload / frame | ≤ 2 MB | **1.6 MB** |
| GPU objects created in frame | 0 | **0** |
| Allocations in the frame loop | 0 | **0** |
| Frame time @ 60 FPS | 16.6 ms | **16.66 ms p50** |

Milestone **M1 — ECS Core + Actors**:

- **ECS with SoA archetypes**: one table per component set, typed iteration in
  batches (systems) or rows (facades), generation-checked handles (no
  use-after-free), swap-remove so structural changes never scan.
- **Hierarchy**: `Parent` links resolved by a flat, recursive-free system in
  O(n) with a CSR children layout and a BFS queue.
- **Actor facade** + **typed signals** (stable order by spawn, drained once per
  frame) as the public API; the ECS stays an internal detail (spec §7).
- **`.zson`**: canonical, bit-exact text format with prefab/overrides
  (`zig build bench -- --scene` writes and reloads a real scene).
- **Frame discipline**: world growth is locked during the frame; everything a
  frame can touch must be reserved at load time (spec §3.1).

Milestone **M0 — Foundations**: fixed-timestep loop, window + input (GLFW
3.4/X11), Dawn backend with an animated quad at 60 FPS (vsync), frame arena,
zero-allocation frame loop, logging and a CPU profiler with percentiles.

**Profiling & regression gate** (see [PROFILING.md](PROFILING.md)): the frame
is split into zones (work vs vsync wait), GPU timestamps are read back
without blocking, every run emits a verdict against `spec.md`, and
`ember-profile` fails CI when any metric regresses more than 5% (ROADMAP M11).

## Stack

- **Zig 0.16** — engine, tools, zero GC.
- **Dawn (WebGPU)** — graphics backend (pinned commit, wrapped in `render/`).
- **GLFW 3.4** — window/input (platform layer).
- **Box2D v3** + **LuaJIT** + **miniaudio** + **Dear ImGui/ImGuizmo** — planned
  for later milestones.

## Building

```bash
# 1. Native deps (cmake/ninja/venv + GLFW + Dawn; idempotent, several minutes)
bash libs/bootstrap.sh

# 2. Tests (core + ECS + render: 89 tests)
zig build test

# 3. Run the demo
zig build run                  # windowed, 50k sprites + SMAA (60 FPS vsync)
zig build run -- --frames 120  # exit after N frames
zig build run -- --headless    # no window (null backend, for CI)

# Renderer options
zig build run -- --sprites 50000   # scene size (canonical: 50k)
zig build run -- --smaa off        # skip the 3 AA passes
zig build run -- --max-fps 30      # Godot-style cap, 60 Hz sim untouched
zig build run -- --sort layer|ftb|btf   # batcher order (default: none = fast)

# 4. Benchmarks: the M1 acceptance criteria, measured against spec.md
zig build bench                # 100k transforms, 10k hierarchy, save/load hash
zig build bench -- --scene    # writes scene.zson and reloads it (bit-exact)

# 5. Profiling: report + spec.md verdicts + CI regression gate (M11)
zig build run -- --frames 600 --report-json report.json
./zig-out/bin/ember-profile report.json --baseline baseline.json  # exit 1 on >5%
```

`zig build bench` always builds in ReleaseSafe: a Debug build measures the
compiler, not the engine. It exits non-zero if any budget is exceeded.

## Layout

```
src/engine/core/      foundations: math, arena, tracker, profiler, loop, log
src/engine/ecs/       ECS: archetypes, queries, hierarchy, signals, actor, .zson
src/engine/platform/  window + input (GLFW bindings)
src/engine/render/    renderer interface + Dawn/null backends + WebGPU bindings
src/runtime/          the ember runtime (M0 executable)
src/bench/            benchmark suite: the acceptance criteria, measured
src/tools/            ember-profile: the report reader + CI regression gate
libs/                 native dependency bootstrap (not committed)
ROADMAP.md            milestones and acceptance criteria
PROFILING.md          how to measure, report and gate performance
spec.md               performance contract (budgets are law)
```

## Third-party dependencies

See [DEPENDENCIES.md](DEPENDENCIES.md).
