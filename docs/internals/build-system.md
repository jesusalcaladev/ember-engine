# Build System

Ember uses the [Zig](https://ziglang.org/) build system (`build.zig`) with a
bootstrap script (`libs/bootstrap.sh`) that fetches and builds all native
dependencies. Nothing in `libs/` is committed to the repository — everything
is obtained by running the bootstrap.

## Quick Start

```bash
# 1. Fetch and build native dependencies (Dawn, GLFW, cmake, ninja, jinja2)
bash libs/bootstrap.sh

# 2. Build the engine, runtime, benchmarks, and tools
zig build

# 3. Run the engine
zig build run -- --frames 600

# 4. Run all tests (core, ECS, script, render, API acceptance)
zig build test

# 5. Run benchmarks
zig build bench
```

## Build Artifacts

`zig build` produces the following executables in `zig-out/bin/`:

| Artifact | Source | Description |
|---|---|---|
| `ember` | `src/runtime/main.zig` | The game runtime (window, input, render, scripting) |
| `ember-bench` | `src/bench/main.zig` | M1 ECS benchmark suite (headless) |
| `ember-bench-script` | `src/bench/script.zig` | M3 LuaJIT benchmark suite (headless) |
| `ember-profile` | `src/tools/profile/main.zig` | CI regression gate — reads `report.json` |
| `ember-api-test` | `src/engine/script/api_acceptance_test.zig` | Lua API acceptance suite |
| `ember-m3-test` | `src/engine/script/m3_api_test.zig` | M3 surface acceptance (actor, math, vec2, spatial) |
| `ember-stubs` | `src/engine/script/stubs_main.zig` | LuaLS/EmmyLua stub generator |

## Build Steps

| Step | Command | What it does |
|---|---|---|
| `bench` | `zig build bench` | Runs both M1 and M3 benchmark suites |
| `run` | `zig build run` | Runs the `ember` runtime |
| `test` | `zig build test` | Runs core, ECS, script, render, and API acceptance tests |
| `test-api` | `zig build test-api` | Runs only the Lua API acceptance suites |
| `stubs` | `zig build stubs` | Regenerates LuaLS/EmmyLua stubs from binding metadata |
| `profile` | `zig build profile` | Runs `ember-profile` on a `report.json` |

All steps accept extra arguments after `--`, e.g. `zig build run -- --frames 600`.

## Module Architecture

The build defines a layered module graph. Each layer compiles and tests
independently, and higher layers import lower ones by module name:

```
core  (src/engine/core/root.zig)     — foundations, pure/testable
  ↑
ecs   (src/engine/ecs/root.zig)      — data-oriented ECS core
  ↑
script (src/engine/script/root.zig)  — LuaJIT scripting (headless, no Dawn)
  ↑
engine (src/engine/root.zig)         — public boundary: core + platform + render
  ↑
runtime (src/runtime/main.zig)       — the ember executable
```

Key design decisions:

- **Headless by construction**: `core`, `ecs`, and `script` never link Dawn or
  GLFW. This means the ECS benchmarks, script tests, and API acceptance suites
  run on a headless CI container without a window or GPU.
- **Single compilation**: Modules are declared once and imported by name, so
  the same source files compile once rather than being duplicated per artifact.
- **Benchmarks are separate artifacts**: The M1 bench (`ember-bench`) links only
  `core` + `ecs`; the M3 bench (`ember-bench-script`) additionally links
  LuaJIT. This means a renderer being edited does not stop the M1 numbers
  from being measured. `zig build bench` runs both.

## Native Dependencies

### GLFW 3.4

- **Source**: shallow clone of the `3.4` tag from GitHub
- **Destination**: `libs/glfw/`
- **Build**: compiled from C source files directly by Zig (no separate build step)
- **Backend**: X11 only (`-D_GLFW_X11`)
- **System libraries**: `X11`, `Xrandr`, `Xcursor`, `Xinerama`, `Xi`, `m`, `dl`, `pthread`

### Dawn (WebGPU)

- **Source**: shallow clone of the commit pinned in `libs/dawn.commit`
  (currently `e5e4a685c9cc53473a458995c4ba5c8f68cec21a`)
- **Destination**: `libs/dawn/` (source + build), `libs/dawn/install/` (installed)
- **Build**: CMake + Ninja, Release, shared libraries
- **Backends**: Vulkan, Null (no desktop GL, no OpenGL ES)
- **Dawn's own dependencies** (abseil, tint, etc.) are fetched automatically
  by Dawn's build system (`DAWN_FETCH_DEPENDENCIES=ON`)

### LuaJIT 2.1

- **Source**: system package (e.g. `libluajit-5.1-dev` on Debian/Ubuntu)
- **Include path**: `/usr/include/luajit-2.1`
- **Library**: `-lluajit-5.1`
- **Used by**: `script` module, `runtime`, `ember-bench-script`, API acceptance tests

## Bootstrap Script

`libs/bootstrap.sh` is idempotent — re-running it does not re-download what is
already present. It performs the following steps:

1. **cmake** — downloads the latest official binary into `.tools/cmake/`
2. **ninja** — downloads the latest official binary into `.tools/`
3. **jinja2** — creates a venv in `.tools/venv/` (required by Dawn's code generator)
4. **GLFW** — shallow clone of the `3.4` tag into `libs/glfw/`
5. **Dawn** — clones the pinned commit, configures with CMake, builds with
   Ninja, and installs into `libs/dawn/install/`

The Dawn build takes several minutes. All tools are local to `.tools/` — the
bootstrap never touches the system.

### Dawn CMake Configuration

| Flag | Value | Purpose |
|---|---|---|
| `CMAKE_BUILD_TYPE` | `Release` | Optimized build |
| `BUILD_SHARED_LIBS` | `ON` | Shared libraries (linked at runtime via rpath) |
| `DAWN_BUILD_MONOLITHIC_LIBRARY` | `OFF` | Separate `dawn_proc` and `dawn_native` libs |
| `DAWN_FETCH_DEPENDENCIES` | `ON` | Fetch abseil, tint, etc. |
| `DAWN_BUILD_EXAMPLES` | `OFF` | Skip examples |
| `DAWN_BUILD_TESTS` | `OFF` | Skip tests |
| `DAWN_ENABLE_DESKTOP_GL` | `OFF` | No desktop GL backend |
| `DAWN_ENABLE_OPENGLES` | `OFF` | No OpenGL ES backend |
| `DAWN_ENABLE_VULKAN` | `ON` | Vulkan backend |
| `DAWN_ENABLE_NULL` | `ON` | Null backend (headless/CI) |
| `DAWN_USE_X11` | `ON` | X11 window system integration |

## Runtime Library Resolution

Dawn and LuaJIT are linked as shared libraries. The build sets rpath entries
pointing into `libs/dawn/build/src/dawn/` and `libs/dawn/build/src/dawn/native/`
so the binaries find them at runtime without `LD_LIBRARY_PATH`. Dawn's own
build rpath resolves its transitive dependencies (abseil, tint, etc.).

## .gitignore

The following are never committed:

- `.zig-cache/`, `zig-out/` — Zig build cache and output
- `.tools/` — local cmake, ninja, venv
- `libs/dawn/`, `libs/glfw/` — fetched dependencies
- `*.log` — log files
- `/scene.zson` — benchmark scratch output (the shipped sample lives in `samples/scene.zson`)
