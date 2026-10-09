# Installation

This guide walks you through building Ember from source, running the test
suite, and launching the demo scene.

## Prerequisites

| Tool | Version | Notes |
|---|---|---|
| [Zig](https://ziglang.org/download/) | 0.16 | The engine, tools, and tests are all Zig |
| [Git](https://git-scm.com/) | any | Cloning the repo and Dawn |
| [Python 3](https://www.python.org/) | 3.8+ | venv for Dawn's build generator (jinja2) |
| [LuaJIT](https://luajit.org/) | 2.1 | System package: `libluajit-5.1` + headers |
| C compiler | any | GLFW is compiled from source (cc/gcc/clang) |
| X11 dev headers | -- | GLFW's X11 backend needs them |

### Installing LuaJIT

**Debian / Ubuntu:**

```bash
sudo apt install libluajit-5.1-dev
```

**Fedora:**

```bash
sudo dnf install luajit-devel
```

**Arch:**

```bash
sudo pacman -S luajit
```

The build expects headers at `/usr/include/luajit-2.1` and the linker flag
`-lluajit-5.1`. If your distro installs them elsewhere, adjust
`build.zig` lines 41-42 and 117-118.

## Step 1: Clone the Repository

```bash
git clone git@github.com:jesusalcaladev/ember-engine.git
cd ember-engine
```

## Step 2: Bootstrap Native Dependencies

```bash
bash libs/bootstrap.sh
```

This script is **idempotent** -- re-running it does not re-download what is
already present. It:

1. Downloads **cmake** and **ninja** into `.tools/` (never touches the system).
2. Creates a Python **venv** with `jinja2` (required by Dawn's build generator).
3. Shallow-clones **GLFW 3.4** into `libs/glfw/`.
4. Shallow-clones **Dawn** at the commit pinned in `libs/dawn.commit` and builds
   it as shared libraries into `libs/dawn/build/`.

The Dawn build takes **several minutes**. The script prints progress as it goes.

> **Note:** `libs/dawn.commit` is the single source of truth for the Dawn
> version. To update Dawn, change that file and re-run the bootstrap.

## Step 3: Build and Run Tests

```bash
zig build test
```

This runs the core, ECS, script, and render test suites. All tests should pass.
The script tests include the Lua API acceptance suites (they run as executables,
not `zig test`, because LuaJIT installs its own signal/longjmp handling).

## Step 4: Run the Demo

```bash
# Windowed, 50k sprites + SMAA (60 FPS vsync)
zig build run

# Exit after N frames
zig build run -- --frames 120

# Headless (null backend, for CI)
zig build run -- --headless
```

### Renderer Options

```bash
zig build run -- --sprites 50000       # scene size (canonical: 50k)
zig build run -- --smaa off            # skip the 3 AA passes
zig build run -- --max-fps 30          # Godot-style cap, 60 Hz sim untouched
zig build run -- --sort layer|ftb|btf  # batcher order (default: none = fast)
```

## Step 5: Run Benchmarks

```bash
zig build bench
```

The benchmark suite measures the acceptance criteria (100k transforms, 10k
hierarchy, save/load hash) and always builds in **ReleaseSafe** -- a Debug build
measures the compiler, not the engine. It exits non-zero if any budget is
exceeded.

```bash
# Also writes scene.zson and reloads it (bit-exact check)
zig build bench -- --scene
```

## Step 6: Profiling (Optional)

```bash
# Generate a report
zig build run -- --frames 600 --report-json report.json

# Compare against a baseline (exits 1 on >5% regression)
./zig-out/bin/ember-profile report.json --baseline baseline.json
```

## Build Artifacts

All artifacts are placed in `zig-out/bin/`:

| Artifact | Description |
|---|---|
| `ember` | The runtime executable |
| `ember-bench` | ECS benchmark suite |
| `ember-bench-script` | LuaJIT behavior benchmark suite |
| `ember-api-test` | Lua API acceptance test |
| `ember-m3-test` | M3 surface acceptance test |
| `ember-profile` | Report reader + CI regression gate |
| `ember-stubs` | LuaLS/EmmyLua stub generator |

## Troubleshooting

### `lua.h: No such file or directory`

LuaJIT headers are not at `/usr/include/luajit-2.1`. Find them:

```bash
find /usr -name "lua.h" 2>/dev/null
```

Then update the `addIncludePath` calls in `build.zig` (lines 41 and 117).

### `cannot find -lluajit-5.1`

The LuaJIT shared library is not in the linker path. On most distros,
`libluajit-5.1-dev` fixes this. If you built LuaJIT from source, add its
library path:

```bash
export LD_LIBRARY_PATH=/path/to/luajit/src:$LD_LIBRARY_PATH
```

### Dawn build fails

Make sure you have a C++ compiler, Python 3, and the X11 development headers.
On Debian/Ubuntu:

```bash
sudo apt install build-essential python3-dev \
    libx11-dev libxrandr-dev libxinerama-dev libxcursor-dev libxi-dev
```

### GLFW build fails

GLFW needs X11 headers. On Debian/Ubuntu:

```bash
sudo apt install libx11-dev libxrandr-dev libxinerama-dev libxcursor-dev libxi-dev
```
