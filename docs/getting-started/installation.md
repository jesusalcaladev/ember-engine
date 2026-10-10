# Installation

This guide walks you through building Ember from source, running the test
suite, and launching the demo scene. It explains what each dependency is
for, what can go wrong, and how to verify that each step worked.

> **What you will accomplish:** By the end of this guide, you will have a
> working Ember engine on your machine, with all tests passing and the
> demo scene running. You will understand why each dependency is needed and
> how to fix common installation problems.

---

## Prerequisites

Before we begin, let us understand what each tool does and why Ember needs
it.

| Tool | Version | What it is for |
|---|---|---|
| [Zig](https://ziglang.org/download/) | 0.16 | The engine, tools, and tests are all written in Zig. Zig is a systems programming language that compiles to native machine code. You need the Zig toolchain to build the project. |
| [Git](https://git-scm.com/) | any | Cloning the repository and fetching Dawn (a graphics library) during the bootstrap step. |
| [Python 3](https://www.python.org/) | 3.8+ | Dawn's build generator uses a Python library called Jinja2. You need Python 3 and a venv to run the generator. |
| [LuaJIT](https://luajit.org/) | 2.1 | The Lua scripting engine. Ember embeds LuaJIT to run gameplay scripts. You need both the shared library (`libluajit-5.1`) and the development headers (`lua.h`, etc.). |
| C compiler | any | GLFW (a windowing library) is compiled from source during the bootstrap step. You need `cc`, `gcc`, or `clang`. |
| X11 dev headers | -- | GLFW's X11 backend needs these headers to communicate with the X Window System (Linux's display server). |

### Installing LuaJIT

LuaJIT is the most common source of installation problems, so let us cover
it first.

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

> **Troubleshooting: "LuaJIT headers are in a different location."**
>
> Find where they are:
>
> ```bash
> find /usr -name "lua.h" 2>/dev/null
> ```
>
> This will print the path to `lua.h`. If it is at, say,
> `/usr/include/luajit-2.1/lua.h`, then the include path is correct. If
> it is somewhere else (e.g., `/usr/local/include/luajit-2.1/lua.h`), you
> need to update the `addIncludePath` calls in `build.zig` (lines 41 and
> 117) to point to the correct directory.

---

## Step 1: Clone the Repository

```bash
git clone git@github.com:jesusalcaladev/ember-engine.git
cd ember-engine
```

This downloads the entire source code and all its submodules. The `cd`
command enters the project directory so that subsequent commands run in
the right place.

> **How to verify this step worked:** Run `ls` and you should see files
> like `build.zig`, `src/`, `libs/`, `docs/`, and `samples/`.

> **Troubleshooting: "git@github.com: Permission denied (publickey)."**
>
> This means your SSH key is not set up. You can either:
>
> 1. Set up an SSH key (follow [GitHub's guide](https://docs.github.com/en/authentication/connecting-to-github-with-ssh)).
> 2. Use HTTPS instead: `git clone https://github.com/jesusalcaladev/ember-engine.git`

---

## Step 2: Bootstrap Native Dependencies

```bash
bash libs/bootstrap.sh
```

This script is **idempotent** -- re-running it does not re-download what is
already present. It:

1. Downloads **cmake** and **ninja** into `.tools/` (never touches the
   system). These are build tools: CMake generates build files, and Ninja
   executes them quickly.

2. Creates a Python **venv** with `jinja2` (required by Dawn's build
   generator). A venv is an isolated Python environment so that Dawn's
   dependencies do not conflict with your system Python.

3. Shallow-clones **GLFW 3.4** into `libs/glfw/`. GLFW is a cross-platform
   windowing library. It creates the game window, handles keyboard and
   mouse input, and manages the OpenGL/Vulkan context.

4. Shallow-clones **Dawn** at the commit pinned in `libs/dawn.commit` and
   builds it as shared libraries into `libs/dawn/build/`. Dawn is Google's
   WebGPU implementation. It provides the GPU abstraction layer that Ember's
   renderer uses to draw sprites.

The Dawn build takes **several minutes**. The script prints progress as it
goes.

> **How to verify this step worked:** After the script finishes, check
> that the following directories exist and are not empty:
>
> ```bash
> ls .tools/       # should contain cmake and ninja
> ls libs/glfw/    # should contain GLFW source
> ls libs/dawn/    # should contain Dawn source and build
> ```
>
> You should also see shared libraries (`.so` files) in `libs/dawn/build/`.
>
> **Note:** `libs/dawn.commit` is the single source of truth for the Dawn
> version. To update Dawn, change that file and re-run the bootstrap.

> **Troubleshooting: "Dawn build fails."**
>
> Make sure you have a C++ compiler, Python 3, and the X11 development
> headers. On Debian/Ubuntu:
>
> ```bash
> sudo apt install build-essential python3-dev \
>     libx11-dev libxrandr-dev libxinerama-dev libxcursor-dev libxi-dev
> ```
>
> On Fedora:
>
> ```bash
> sudo dnf install gcc-c++ python3-devel \
>     libX11-devel libXrandr-devel libXinerama-devel libXcursor-devel libXi-devel
> ```

> **Troubleshooting: "GLFW build fails."**
>
> GLFW needs X11 headers. On Debian/Ubuntu:
>
> ```bash
> sudo apt install libx11-dev libxrandr-dev libxinerama-dev libxcursor-dev libxi-dev
> ```
>
> On Fedora:
>
> ```bash
> sudo dnf install libX11-devel libXrandr-devel libXinerama-devel libXcursor-devel libXi-devel
> ```

> **Troubleshooting: "Python venv creation fails."**
>
> Make sure Python 3 is installed and accessible as `python3`:
>
> ```bash
> python3 --version
> ```
>
> If it prints `Python 3.x.x` (where x.x is 3.8 or higher), you are good.
> If not, install Python 3 from [python.org](https://www.python.org/).

---

## Step 3: Build and Run Tests

```bash
zig build test
```

This runs the core, ECS, script, and render test suites. All tests should
pass. The script tests include the Lua API acceptance suites (they run as
executables, not `zig test`, because LuaJIT installs its own signal/longjmp
handling that conflicts with Zig's test runner).

> **How to verify this step worked:** The command should exit with code 0
> and print something like:
>
> ```
> All tests passed.
> ```
>
> If any test fails, the output will show which test failed and why. Do
> not proceed until all tests pass.

> **Troubleshooting: "Tests fail with a Lua-related error."**
>
> This usually means LuaJIT is not installed correctly. Verify:
>
> ```bash
> ls /usr/include/luajit-2.1/lua.h
> ```
>
> If this file does not exist, reinstall LuaJIT:
>
> ```bash
> sudo apt install libluajit-5.1-dev
> ```
>
> Also check that the shared library exists:
>
> ```bash
> ldconfig -p | grep luajit
> ```
>
> It should print something like `libluajit-5.1.so.2`. If not, you may need
> to set `LD_LIBRARY_PATH`:
>
> ```bash
> export LD_LIBRARY_PATH=/usr/lib/x86_64-linux-gnu:$LD_LIBRARY_PATH
> ```

---

## Step 4: Run the Demo

```bash
# Windowed, 50k sprites + SMAA (60 FPS vsync)
zig build run

# Exit after N frames
zig build run -- --frames 120

# Headless (null backend, for CI)
zig build run -- --headless
```

The demo renders 50,000 sprites with SMAA anti-aliasing at 60 FPS. It is
a stress test that demonstrates the engine's performance.

> **How to verify this step worked:** A window should open and you should
> see a field of colored squares. The window title should show the current
> FPS. If it runs at 60 FPS, the engine is working correctly.
>
> To exit, close the window or press `Ctrl+C` in the terminal.

### Renderer Options

```bash
zig build run -- --sprites 50000       # scene size (canonical: 50k)
zig build run -- --smaa off            # skip the 3 AA passes
zig build run -- --max-fps 30          # Godot-style cap, 60 Hz sim untouched
zig build run -- --sort layer|ftb|btf  # batcher order (default: none = fast)
```

- `--sprites` controls how many sprites the demo creates. Lower values are
  easier to run on slower hardware.
- `--smaa off` disables anti-aliasing. Edges will look more jagged, but
  performance will improve.
- `--max-fps` caps the frame rate. The simulation still runs at 60 Hz, but
  the renderer draws fewer frames per second.
- `--sort` controls how sprites are sorted before rendering. `layer` sorts
  by layer, `ftb` sorts front-to-back, and `btf` sorts back-to-front.

> **Troubleshooting: "The window does not open."**
>
> Make sure you have a display server running. On Linux, this means X11 or
> Wayland. If you are running over SSH, you need X11 forwarding or a virtual
> display (Xvfb).
>
> Try the headless mode to verify the engine works without a display:
>
> ```bash
> zig build run -- --headless
> ```

> **Troubleshooting: "The demo runs at a very low FPS."**
>
> Lower the sprite count:
>
> ```bash
> zig build run -- --sprites 1000
> ```
>
> If performance improves, your GPU was the bottleneck. You can also try
> `--smaa off` to reduce GPU load.

---

## Step 5: Run Benchmarks

```bash
zig build bench
```

The benchmark suite measures the acceptance criteria (100k transforms, 10k
hierarchy, save/load hash) and always builds in **ReleaseSafe** -- a Debug
build measures the compiler, not the engine. It exits non-zero if any budget
is exceeded.

```bash
# Also writes scene.zson and reloads it (bit-exact check)
zig build bench -- --scene
```

> **How to verify this step worked:** The command should exit with code 0
> and print benchmark results. If any budget is exceeded, the command exits
> with a non-zero code and prints a warning.

> **Troubleshooting: "Benchmarks fail."**
>
> Benchmarks are designed to catch performance regressions. If they fail,
> it usually means your machine is slower than the reference hardware, or
> something is running in the background. Try closing other applications
> and running again.

---

## Step 6: Profiling (Optional)

```bash
# Generate a report
zig build run -- --frames 600 --report-json report.json

# Compare against a baseline (exits non-zero on >5% regression)
./zig-out/bin/ember-profile report.json --baseline baseline.json
```

Profiling helps you find performance bottlenecks. The report contains
detailed timing data for each system (ECS, rendering, scripts, etc.).

---

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

You can run any of these directly:

```bash
./zig-out/bin/ember quickstart.zson
./zig-out/bin/ember-bench
./zig-out/bin/ember-api-test
```

---

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

---

## Next Steps

- **[Quickstart](quickstart.md)** -- Get a sprite moving in 5 minutes.
- **[Installation](installation.md)** -- You are here.
- **[First Scene](first-scene.md)** -- Learn the `.zson` format.
- **[First Script](first-script.md)** -- Learn the behavior lifecycle.

If everything is working, congratulations! You are ready to start building
with Ember. If you are stuck, check the troubleshooting sections above or
ask for help in the project's issue tracker.
