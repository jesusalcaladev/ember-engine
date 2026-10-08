# ember

`ember` is a proprietary 2D game engine by **Daara Studios**, written in Zig
with a Dawn (WebGPU) renderer, Box2D v3 physics and LuaJIT scripting.

> Proprietary software — see [LICENSE](LICENSE). Copyright (c) 2026 Daara Studios.

## Status

Milestone **M0 — Foundations** (see [ROADMAP.md](ROADMAP.md)):

- Fixed-timestep game loop (60 Hz) with accumulator + decoupled rendering.
- Window + input via GLFW 3.4 (X11).
- Dawn (WebGPU) backend rendering an animated quad at 60 FPS (vsync).
- Frame arena (O(1) reset), zero-allocation frame-loop invariant, logging and
  a CPU profiler with p50/p99/p99.9 percentiles.

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

# 2. Tests
zig build test

# 3. Run the demo
zig build run                  # windowed, animated quad (60 FPS vsync)
zig build run -- --frames 120  # exit after N frames
zig build run -- --headless    # no window (null backend, for CI)
```

The verification numbers for M0 (frame times p50/p99, zero-allocation assert)
are printed on exit.

## Layout

```
src/engine/core/      foundations: math, arena, tracker, profiler, loop, log
src/engine/platform/  window + input (GLFW bindings)
src/engine/render/    renderer interface + Dawn/null backends + WebGPU bindings
src/runtime/          the ember runtime (M0 executable)
libs/                 native dependency bootstrap (not committed)
ROADMAP.md            milestones and acceptance criteria
spec.md               performance contract (budgets are law)
```

## Third-party dependencies

See [DEPENDENCIES.md](DEPENDENCIES.md).
