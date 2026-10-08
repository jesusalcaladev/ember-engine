# ember

`ember` is a proprietary 2D game engine by **Daara Studios**, written in Zig
with a Dawn (WebGPU) renderer, Box2D v3 physics and LuaJIT scripting.

> Proprietary software — see [LICENSE](LICENSE). Copyright (c) 2026 Daara Studios.

## Status

Milestone **M1 — ECS Core + Actors** is closed on top of M0 (see
[ROADMAP.md](ROADMAP.md) for the full plan):

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

# 2. Tests (core + ECS: archetypes, queries, hierarchy, signals, .zson)
zig build test

# 3. Run the demo
zig build run                  # windowed, animated quad (60 FPS vsync)
zig build run -- --frames 120  # exit after N frames
zig build run -- --headless    # no window (null backend, for CI)

# 4. Benchmarks: the M1 acceptance criteria, measured against spec.md
zig build bench                # 100k transforms, 10k hierarchy, save/load hash
zig build bench -- --scene    # writes scene.zson and reloads it (bit-exact)
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
libs/                 native dependency bootstrap (not committed)
ROADMAP.md            milestones and acceptance criteria
spec.md               performance contract (budgets are law)
```

## Third-party dependencies

See [DEPENDENCIES.md](DEPENDENCIES.md).
