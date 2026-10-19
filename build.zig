const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // Where `bash libs/bootstrap.sh` installed Box2D: inside THIS repository's
    // `libs/`, reached with `b.path` so the build is relocatable. (It used to be
    // an absolute path into a sibling project — a time bomb that only defused
    // because that project happened to exist on the same machine.)

    // ── Feature flags ───────────────────────────────────────────────────────
    // `-Dsteering` publishes the M4.5 steering accumulator and the `world`
    // table behind `world.nearby`.
    //
    // DEFAULT OFF, and that is a deliberate statement, not a staging accident:
    // `world.nearby` measures ~16 us per call, roughly 100x what the spatial
    // grid should cost, and the cause is not yet known. Shipping it enabled
    // would put a known-wrong number inside the frame. Everything else in M4.5
    // (`rand`, `noise`, the state machine) is unaffected and always on.
    //
    // Turn it on with `-Dsteering` once `nearby` is fixed; the acceptance suite
    // exercises both configurations.
    const steering = b.option(
        bool,
        "steering",
        "Enable the M4.5 steering accumulator and world.nearby (default: off until nearby is within budget)",
    ) orelse false;
    const options = b.addOptions();
    options.addOption(bool, "steering", steering);

    // ── Core module (foundations, pure/testable) ─────────────────────────────
    const core_mod = b.createModule(.{
        .root_source_file = b.path("src/engine/core/root.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });

    // ── ECS module (data-oriented core; tested without native dependencies) ──
    // Declared before the engine because the engine imports it by module name,
    // and both compile the same sources once instead of twice.
    const ecs_mod = b.createModule(.{
        .root_source_file = b.path("src/engine/ecs/root.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    ecs_mod.addImport("core", core_mod);

    // ── Physics module (M4) ─────────────────────────────────────────────────
    // The PORT (`physics.zig`) has no native dependency and is testable on its
    // own; the Box2D backend links the static library built by
    // `libs/bootstrap.sh` and is selected at comptime through
    // `physics.createWorld(.box2d, ...)`.
    const physics_mod = b.createModule(.{
        .root_source_file = b.path("src/engine/physics/root.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    physics_mod.addImport("core", core_mod);
    // The sync system walks the ECS, so physics depends on the ECS — but not
    // the other way round: the ECS components are plain data and name no
    // solver, which is what keeps the port replaceable.
    physics_mod.addImport("ecs", ecs_mod);
    // Box2D's headers and static library, installed by `libs/bootstrap.sh`
    // into this repo's `libs/box2d/install`. `b.path` keeps the build
    // relocatable, unlike the absolute path this used to carry.
    physics_mod.addIncludePath(b.path("libs/box2d/install/include"));

    // An absolute -L as well as the library name: this version of Zig has no
    // per-library search path option, and `addLibraryPath` is module-wide.
    // ── Platform module (M0: window + input) ──────────────────────────────────
const platform_mod = b.createModule(.{
    .root_source_file = b.path("src/engine/platform/platform.zig"),
    .target = target,
    .optimize = optimize,
    .link_libc = true,
});
platform_mod.addImport("core", core_mod);

    // ── M3 asset module (images; PCM lives in the audio bank) ────────────────
    // Decoding is a native concern (stb_image), so this is its own module and
    // its own include path. Declared before `render_mod` and `script_mod`
    // because both reach the image type as a module, not as a file copy.
    const assets_mod = b.createModule(.{
        .root_source_file = b.path("src/engine/assets/root.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    assets_mod.addImport("core", core_mod);
    assets_mod.addIncludePath(b.path("libs"));
    // The one translation unit that compiles stb_image. See the file: Zig 0.16's
    // translate-c cannot lower the whole header, so the implementation is C and
    // the Zig side declares the two externs it uses.
    assets_mod.addCSourceFile(.{
        .file = b.path("src/engine/assets/stb_image_impl.c"),
        .flags = &.{ "-I", "libs" },
    });
    // M14: the one translation unit that compiles stb_truetype (glyph
    // rasterizing for the game's own UI). Same pattern, same include path; the
    // extern surface it exposes is declared by `render/font.zig`. It needs
    // libm (sqrt/floor/ceil/pow), which every consumer of `assets` links
    // through this module.
    assets_mod.addCSourceFile(.{
        .file = b.path("src/engine/assets/stb_truetype_impl.c"),
        .flags = &.{ "-I", "libs" },
    });
    assets_mod.linkSystemLibrary("m", .{});

    // ── M8 audio module ─────────────────────────────────────────────────────
    // The port (`audio.zig`), the pure maths (`mixer.zig`), voices, buses, the
    // byte-budgeted bank, the SPSC command ring, the rate-limited event ring,
    // and the two backends. Headless by construction: the null backend opens no
    // device, so the whole mixing path is exercised in `zig build test` with no
    // sound card.
    const audio_mod = b.createModule(.{
        .root_source_file = b.path("src/engine/audio/root.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    audio_mod.addImport("core", core_mod);
    audio_mod.addIncludePath(b.path("libs"));
    // The ONE translation unit that compiles miniaudio (the device and the
    // decoder). Zig 0.16's translate-c cannot lower the header, so it is C, and
    // `backend_miniaudio.zig` declares the small extern surface it exposes.
    audio_mod.addCSourceFile(.{
        .file = b.path("src/engine/audio/miniaudio_impl.c"),
        .flags = &.{ "-I", "libs" },
    });
    // miniaudio's own link requirements on Linux: the device backends use
    // dl/pthread (both in libc on any glibc this targets) and the resampler uses
    // libm.
    audio_mod.linkSystemLibrary("m", .{});

    // ── Render module (M7) ─────────────────────────────────────────────────────
    // A module rather than part of the engine boundary because `script` reaches
    // the renderer too (camera view, render stats). Its root re-exports the
    // batcher/atlas/2d/light/driver so the engine can re-export them by name
    // without a relative import that would put a file in two modules.
const render_mod = b.createModule(.{
    .root_source_file = b.path("src/engine/render/render.zig"),
    .target = target,
    .optimize = optimize,
    .link_libc = true,
});
render_mod.addImport("core", core_mod);
render_mod.addImport("ecs", ecs_mod);
render_mod.addImport("physics", physics_mod);
render_mod.addImport("platform", platform_mod);
// The atlas bridge borrows `assets.Image`, so the renderer sees the image type
// as a module rather than a second copy of the file.
render_mod.addImport("assets", assets_mod);

    // ── M3 scripting module (LuaJIT; depends on core + ecs, no Dawn) ─────────
    // Declared before the engine because the engine imports it by module name,
    // and both compile the same sources once. Headless by construction: the only
    // native dependency is LuaJIT itself (spec §9: every feature ships a test).
    const script_mod = b.createModule(.{
        .root_source_file = b.path("src/engine/script/root.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    script_mod.addImport("core", core_mod);
    script_mod.addImport("ecs", ecs_mod);
    // Physics, for the raycast/impulse bindings. Declared before `physics_mod`
    // because the import name must resolve to the same module instance the
    // runtime passes the `World` through — two instances of the same file would
    // produce two incompatible `physics.World` types.
    script_mod.addImport("physics", physics_mod);
    script_mod.addImport("render", render_mod);
    // M8: the `audio.*` bindings reach the audio system directly, exactly as the
    // `physics.*` bindings reach the solver. `audio` imports neither `script`
    // nor `ecs`, so there is no module-file conflict here.
    script_mod.addImport("audio", audio_mod);
    script_mod.addImport("assets", assets_mod);
    script_mod.addImport("platform", platform_mod);
    // Feature flags reach the code through this, not through build-time source
    // rewriting: `zig build -Dsteering` has to be the ONLY way the feature
    // changes, so a stale build can never disagree with what was asked for.
    script_mod.addOptions("options", options);

    physics_mod.addLibraryPath(b.path("libs/box2d/install/lib"));
    physics_mod.linkSystemLibrary("box2d", .{ .preferred_link_mode = .static });
    // LuaJIT 2.1 (Lua 5.1 API) from the system. The include path is where the
    // distro headers live; the linker resolves `-lluajit-5.1`. `cwd_relative`
    // because it is an absolute path outside the build root.
    script_mod.addIncludePath(.{ .cwd_relative = "/usr/include/luajit-2.1" });
    script_mod.linkSystemLibrary("luajit-5.1", .{});

    // ── Project config module (M-project) ────────────────────────────────────
    // The `project.config` system: comptime registry, runtime Config, parser,
    // key bindings. Pure Zig, no native deps, tested like core/ecs.
    const project_mod = b.createModule(.{
        .root_source_file = b.path("src/engine/project/root.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    project_mod.addImport("core", core_mod);
    // Declared above `render_mod`'s imports on purpose, so that the renderer can
    // name it: `Driver.applyLightingConfig` is the only path by which a
    // project's `lighting` section reaches the driver, and it cannot exist
    // without this. It is attached here rather than at the renderer's own
    // declaration because `project_mod` did not exist yet at that point — the
    // ordering is the constraint and the import is the consequence.
    render_mod.addImport("project", project_mod);

    // ── Editor module (M5.5: the non-UI half of the code editor) ─────────────
    // Depends on nothing but itself. A document, a cursor, a highlighter, a
    // parser and a find engine are pure Zig, which is exactly why they are
    // built and tested here rather than inside the editor UI: no Dawn, no
    // window, no ImGui. The UI half of M5.5 consumes this the way the renderer
    // consumes a batcher.
    //
    // The one exception is the API metadata, reached as its own module: the
    // engine-aware diagnostics check a call's arguments against the signature
    // every binding is documented with, and a check that hand-copied the table
    // would drift. metadata.zig imports only std, so the editor still compiles
    // and tests with no LuaJIT, no Box2D and no Dawn in sight.
    const api_meta_mod = b.createModule(.{
        .root_source_file = b.path("src/engine/script/metadata.zig"),
        .target = target,
        .optimize = optimize,
    });
    // `script` reaches the SAME module rather than importing `metadata.zig` by
    // path, and that is not a style choice — it is the only shape that compiles
    // when `script` and a second importer of the metadata share a compilation.
    //
    // Zig allows a file to belong to exactly ONE module. `metadata.zig` is the
    // root of `api_meta`, so the moment any module that also pulls in `script`
    // (the editor tool needs both) is compiled, the relative import inside
    // `script/` makes the same file belong to `script` too, and the build fails
    // with "file exists in modules 'script' and 'api_meta'". Declaring the
    // module dependency here means `script`'s three uses of the registry resolve
    // to the one owner, for every consumer, without touching any of them.
    script_mod.addImport("api_meta", api_meta_mod);

    // M5: the editing session (Play/Stop, undo/redo, the node graph, the
    // editing document). Headless like the editor core: no Lua, no window,
    // just the state and the rules, so it tests in milliseconds.
    const session_mod = b.createModule(.{
        .root_source_file = b.path("src/engine/session/root.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    session_mod.addImport("core", core_mod);
    session_mod.addImport("ecs", ecs_mod);

    // ── Engine module (public boundary: core + platform + render) ───────────
    // Declared here, ABOVE the first use: `runtime_mod` and every test target
    // import `engine`, and a Zig build script is executed top to bottom, so a
    // declaration that lands after its use is a compile error rather than a
    // declaration at all.
    const engine_mod = b.createModule(.{
        .root_source_file = b.path("src/engine/root.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });

    // ── ember runtime ───────────────────────────────────────────────────────
    const runtime_mod = b.createModule(.{
        .root_source_file = b.path("src/runtime/main.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    runtime_mod.addImport("engine", engine_mod);
    runtime_mod.addImport("core", core_mod);
    runtime_mod.addImport("project", project_mod);
    runtime_mod.addImport("audio", audio_mod);
    runtime_mod.addImport("assets", assets_mod);
    runtime_mod.addImport("render", render_mod);
    runtime_mod.addImport("platform", platform_mod);

    const editor_mod = b.createModule(.{
        .root_source_file = b.path("src/engine/editor/root.zig"),
        .target = target,
        .optimize = optimize,
    });
    editor_mod.addImport("api_meta", api_meta_mod);
    editor_mod.addImport("runtime", runtime_mod);
    editor_mod.addImport("session", session_mod);
    editor_mod.addImport("core", core_mod);
    editor_mod.addImport("ecs", ecs_mod);
    editor_mod.addImport("assets", assets_mod);
    editor_mod.addImport("physics", physics_mod);
    // NOT `render`: importing it drags `render/atlas_bridge.zig` into a module
    // where its Dawn types do not resolve — the "file exists in modules
    // 'script' and 'api_meta'" clash's sibling, and the same class of wall. The
    // editor declares its own `Vec2`/`Camera` placeholders for the two render
    // types it names, which is the same arrangement it already uses for the
    // parked TileMap physics system.
    // Separate modules: each subsystem compiles and tests on its own.
    engine_mod.addImport("core", core_mod);
    engine_mod.addImport("ecs", ecs_mod);
    engine_mod.addImport("physics", physics_mod);
    // M3: the LuaJIT scripting layer. It links LuaJIT but NOT Dawn, so the
    // scripting tests and the M3 bench run headless like the ECS ones do.
    engine_mod.addImport("script", script_mod);
    // M-project: `project.config`. The engine boundary re-exports it as
    // `engine.project`, so the import must resolve here — an engine that
    // cannot see the project module cannot honor its own root.zig.
    engine_mod.addImport("project", project_mod);
    // M8/M7: the engine boundary re-exports `render` and `platform` as MODULES
    // (see `src/engine/root.zig`), plus audio and the asset layer. A module
    // import must resolve here for the boundary's own `@import` to work.
    engine_mod.addImport("render", render_mod);
    engine_mod.addImport("platform", platform_mod);
    engine_mod.addImport("audio", audio_mod);
    engine_mod.addImport("assets", assets_mod);

    // The render module declares extern Dawn procs, so anything that links the
    // engine whole (the runtime, the render tests) needs the libraries. They are
    // declared once here instead of per-artifact.
    engine_mod.addLibraryPath(b.path("libs/dawn/build/src/dawn"));
    engine_mod.addLibraryPath(b.path("libs/dawn/build/src/dawn/native"));
    engine_mod.linkSystemLibrary("dawn_proc", .{});
    engine_mod.linkSystemLibrary("dawn_native", .{});
    engine_mod.addRPath(b.path("libs/dawn/build/src/dawn"));
    engine_mod.addRPath(b.path("libs/dawn/build/src/dawn/native"));
    engine_mod.linkSystemLibrary("X11", .{});

    // Dawn (WebGPU C API): shared libs from the bootstrap build tree.
    // Linked directly and exposed via runpath so the binary finds them at
    // runtime without LD_LIBRARY_PATH. Dawn's own build rpath resolves its
    // transitive deps (abseil, tint, ...).
    runtime_mod.addLibraryPath(b.path("libs/dawn/build/src/dawn"));
    runtime_mod.addLibraryPath(b.path("libs/dawn/build/src/dawn/native"));
    runtime_mod.linkSystemLibrary("dawn_proc", .{});
    runtime_mod.linkSystemLibrary("dawn_native", .{});
    runtime_mod.addRPath(b.path("libs/dawn/build/src/dawn"));
    runtime_mod.addRPath(b.path("libs/dawn/build/src/dawn/native"));

    // GLFW 3.4 built statically (X11 backend only in M0).
    const glfw_files = [_][]const u8{
        "context.c",        "init.c",         "input.c",
        "monitor.c",        "platform.c",     "vulkan.c",
        "window.c",         "glx_context.c",  "egl_context.c",
        "osmesa_context.c", "x11_init.c",     "x11_monitor.c",
        "x11_window.c",     "xkb_unicode.c",  "posix_module.c",
        "posix_poll.c",     "posix_thread.c", "posix_time.c",
        "linux_joystick.c", "null_init.c",    "null_joystick.c",
        "null_monitor.c",   "null_window.c",
    };
    const glfw_flags = [_][]const u8{"-D_GLFW_X11"};
    runtime_mod.addCSourceFiles(.{
        .root = b.path("libs/glfw/src"),
        .files = &glfw_files,
        .flags = &glfw_flags,
    });
    runtime_mod.addIncludePath(b.path("libs/glfw/include"));
    runtime_mod.addIncludePath(b.path("libs/glfw/src"));

    // System deps of GLFW's X11 backend.
    inline for (.{ "X11", "Xrandr", "Xcursor", "Xinerama", "Xi", "m", "dl", "pthread" }) |lib| {
        runtime_mod.linkSystemLibrary(lib, .{});
    }

    // M3: the runtime drives the LuaJIT behavior system. Declared here (like
    // Dawn) because anything that links the engine whole needs the library, and
    // it is exported so the binary finds `libluajit-5.1.so` at runtime.
    runtime_mod.addIncludePath(.{ .cwd_relative = "/usr/include/luajit-2.1" });
    runtime_mod.linkSystemLibrary("luajit-5.1", .{});

    const ember = b.addExecutable(.{
        .name = "ember",
        .root_module = runtime_mod,
    });
    b.installArtifact(ember);

    // ── M1 benchmark suite (acceptance criteria, measured) ───────────────────
    // ReleaseSafe regardless of the build flag: budgets in spec.md are about
    // what a shipped game does, and a Debug build measures the compiler.
    const bench_mod = b.createModule(.{
        .root_source_file = b.path("src/bench/main.zig"),
        .target = target,
        .optimize = .ReleaseSafe,
        .link_libc = true,
    });
    // `core`, `ecs` and `script`: headless by construction, so it never links
    // Dawn nor needs a window to measure (spec §9: every feature ships a
    // benchmark). `script` brings LuaJIT for the M3 behavior criteria.
    bench_mod.addImport("core", core_mod);
    bench_mod.addImport("ecs", ecs_mod);
    bench_mod.addImport("script", script_mod);
    bench_mod.linkSystemLibrary("luajit-5.1", .{});
    const bench = b.addExecutable(.{ .name = "ember-bench", .root_module = bench_mod });
    const bench_cmd = b.addRunArtifact(bench);
    if (b.args) |args| bench_cmd.addArgs(args);
    const bench_step = b.step("bench", "Run the M1 ECS benchmark suite");
    bench_step.dependOn(&bench_cmd.step);

    // ── M8 audio benchmark: the M8 criteria, as numbers a test can fail ─────
    // 64 simultaneous emitters, zero main-thread allocations while they play,
    // latency ≤ 20 ms and xruns == 0 — all against the null backend, so it runs
    // anywhere `zig build test` does.
    const audio_bench_mod = b.createModule(.{
        .root_source_file = b.path("src/bench/audio.zig"),
        .target = target,
        .optimize = .ReleaseSafe,
        .link_libc = true,
    });
    audio_bench_mod.addImport("core", core_mod);
    audio_bench_mod.addImport("audio", audio_mod);
    const audio_bench = b.addExecutable(.{ .name = "ember-bench-audio", .root_module = audio_bench_mod });
    const audio_bench_cmd = b.addRunArtifact(audio_bench);
    if (b.args) |args| audio_bench_cmd.addArgs(args);
    const audio_bench_step = b.step("bench-audio", "M8: 64 emitters, zero-alloc frame path, latency <= 20 ms");
    audio_bench_step.dependOn(&audio_bench_cmd.step);

    // ── M13 animation benchmark: the ROADMAP criterion, as numbers ──────────
    // Headless (core + ecs only) so the renderer can be mid-edit without
    // blocking the measurement, and ReleaseSafe so the number is the shipped
    // code's and not the safety checks'. It is part of `zig build bench` as
    // well as its own step: "the animation system costs <= 0.05 ms/frame for 100
    // clips" is a gate, not a report.
    const anim_bench_mod = b.createModule(.{
        .root_source_file = b.path("src/bench/animation.zig"),
        .target = target,
        .optimize = .ReleaseSafe,
        .link_libc = true,
    });
    anim_bench_mod.addImport("core", core_mod);
    anim_bench_mod.addImport("ecs", ecs_mod);
    const anim_bench = b.addExecutable(.{ .name = "ember-bench-animation", .root_module = anim_bench_mod });
    const anim_bench_cmd = b.addRunArtifact(anim_bench);
    if (b.args) |args| anim_bench_cmd.addArgs(args);
    const anim_bench_step = b.step("bench-animation", "M13: 100 clips, p50 <= 0.05 ms/frame, zero-alloc frame path");
    anim_bench_step.dependOn(&anim_bench_cmd.step);
    bench_step.dependOn(&anim_bench_cmd.step);

    // ── M7 lighting benchmark: the CPU half, measured ───────────────────────
    // A separate artifact from `bench` on purpose: the M1 suite must keep
    // running while the renderer is mid-edit, and the lighting bench needs the
    // engine module. It links the same headless modules and nothing else — no
    // Dawn, no window — so it runs anywhere `zig build test` does.
    // Rooted at `bench_root.zig` and not at the engine boundary, for the same
    // reason `render/test_root.zig` exists: the boundary re-exports modules that
    // are being edited, and a benchmark that cannot compile is a benchmark whose
    // last number is from whenever it last worked.
    //
    // ReleaseSafe, matching the bench module that consumes it. Inheriting the
    // build's `optimize` here means a default Debug build measures Debug code,
    // which is a timing of the compiler's safety checks rather than of the engine.
    const bench_engine_mod = b.createModule(.{
        .root_source_file = b.path("src/engine/bench_root.zig"),
        .target = target,
        .optimize = .ReleaseSafe,
        .link_libc = true,
    });
    bench_engine_mod.addImport("core", core_mod);
    bench_engine_mod.addImport("ecs", ecs_mod);
    bench_engine_mod.addImport("render", render_mod);
    bench_engine_mod.addImport("platform", platform_mod);
    bench_engine_mod.addImport("assets", assets_mod);

    const light_bench_mod = b.createModule(.{
        .root_source_file = b.path("src/bench/light.zig"),
        .target = target,
        .optimize = .ReleaseSafe,
        .link_libc = true,
    });
    light_bench_mod.addImport("core", core_mod);
    light_bench_mod.addImport("ecs", ecs_mod);
    light_bench_mod.addImport("engine", bench_engine_mod);
    // `project`, so the acceptance can ask `project.config` for the shipped
    // default rather than reconstructing it. Without it the acceptance measured
    // the tier's built-in `shadow_resolution` and kept reporting 2048 after the
    // default moved to 1024 — a benchmark of a configuration nobody ships.
    light_bench_mod.addImport("project", project_mod);
    // The engine module declares the Dawn externs, so anything linking it needs
    // the libraries — declared once on `engine_mod`, which this shares.
    light_bench_mod.addLibraryPath(b.path("libs/dawn/build/src/dawn"));
    light_bench_mod.addLibraryPath(b.path("libs/dawn/build/src/dawn/native"));
    light_bench_mod.linkSystemLibrary("dawn_proc", .{});
    light_bench_mod.linkSystemLibrary("dawn_native", .{});
    const light_bench = b.addExecutable(.{
        .name = "ember-bench-light",
        .root_module = light_bench_mod,
    });
    const light_bench_cmd = b.addRunArtifact(light_bench);
    const light_bench_step = b.step("bench-light", "Run the M7 lighting benchmark");
    light_bench_step.dependOn(&light_bench_cmd.step);

    // ── M3 benchmark suite (LuaJIT): acceptance criteria of ROADMAP M3 ──────
    // A SEPARATE artifact because it links LuaJIT: the M1 bench must stay
    // runnable while the renderer or the script layer is mid-edit. `zig build
    // bench` runs both, so there is still one command (spec §9).
    const script_bench_mod = b.createModule(.{
        .root_source_file = b.path("src/bench/script.zig"),
        .target = target,
        .optimize = .ReleaseSafe,
        .link_libc = true,
    });
    script_bench_mod.addImport("core", core_mod);
    script_bench_mod.addImport("ecs", ecs_mod);
    script_bench_mod.addImport("script", script_mod);
    const script_bench = b.addExecutable(.{ .name = "ember-bench-script", .root_module = script_bench_mod });
    const script_bench_cmd = b.addRunArtifact(script_bench);
    if (b.args) |args| script_bench_cmd.addArgs(args);
    bench_step.dependOn(&script_bench_cmd.step);

    // ── M4.5 steering benchmark (LuaJIT) ───────────────────────────────────
    // Separate artifact for the same reason as the script bench above, and a
    // separate STEP because it is a one-off measurement of a design decision
    // rather than a regression gate: it must not fail CI, just report.
    const steer_bench_mod = b.createModule(.{
        .root_source_file = b.path("src/bench/steer.zig"),
        .target = target,
        .optimize = .ReleaseSafe,
        .link_libc = true,
    });
    steer_bench_mod.addImport("core", core_mod);
    steer_bench_mod.addImport("ecs", ecs_mod);
    steer_bench_mod.addImport("script", script_mod);
    steer_bench_mod.addOptions("options", options);
    const steer_bench = b.addExecutable(.{ .name = "ember-bench-steer", .root_module = steer_bench_mod });
    const steer_bench_cmd = b.addRunArtifact(steer_bench);
    if (b.args) |args| steer_bench_cmd.addArgs(args);
    // ── M4 physics benchmark ────────────────────────────────────────────────
    // An executable, for the same reason as the others: it links Box2D and
    // measures the determinism criterion (spec §6), which needs a real solver.
    const phys_bench_mod = b.createModule(.{
        .root_source_file = b.path("src/bench/physics.zig"),
        .target = target,
        .optimize = .ReleaseSafe,
        .link_libc = true,
    });
    phys_bench_mod.addImport("core", core_mod);
    phys_bench_mod.addImport("ecs", ecs_mod);
    phys_bench_mod.addImport("physics", physics_mod);
    const phys_bench = b.addExecutable(.{ .name = "ember-bench-physics", .root_module = phys_bench_mod });
    const phys_step = b.step("bench-physics", "M4: physics determinism (2 runs -> same hash) and the 2.0 ms budget");
    phys_step.dependOn(&b.addRunArtifact(phys_bench).step);

    // The M4 milestone's own criterion (ROADMAP M4), as an executable for the
    // same reason as the physics bench: it needs a real solver.
    const plat_mod = b.createModule(.{
        .root_source_file = b.path("src/bench/platformer.zig"),
        .target = target,
        .optimize = .ReleaseSafe,
        .link_libc = true,
    });
    plat_mod.addImport("core", core_mod);
    plat_mod.addImport("ecs", ecs_mod);
    plat_mod.addImport("physics", physics_mod);
    const plat_exe = b.addExecutable(.{ .name = "ember-demo-platformer", .root_module = plat_mod });
    const plat_step = b.step("demo-platformer", "M4: the platformer demo — runs, and runs the same way twice");
    plat_step.dependOn(&b.addRunArtifact(plat_exe).step);

    // The open-world bench (M5): the acceptance test for distance-based
    // activity. An executable for the same reason as the others.
    const ow_mod = b.createModule(.{
        .root_source_file = b.path("src/bench/openworld.zig"),
        .target = target,
        .optimize = .ReleaseSafe,
        .link_libc = true,
    });
    ow_mod.addImport("core", core_mod);
    ow_mod.addImport("ecs", ecs_mod);
    ow_mod.addImport("physics", physics_mod);
    const ow_exe = b.addExecutable(.{ .name = "ember-bench-openworld", .root_module = ow_mod });
    const ow_step = b.step("bench-openworld", "M5: 200k bodies, camera walk — is the frame cost a function of what is NEAR?");
    ow_step.dependOn(&b.addRunArtifact(ow_exe).step);

    const steer_step = b.step("bench-steer", "Measure the M4.5 steering + spatial path against spec §2");
    // Refuses to run without the feature rather than reporting the disabled
    // path's numbers: a benchmark of a subsystem that is compiled out is worse
    // than no benchmark, because it looks like a result.
    if (steering) {
        steer_step.dependOn(&steer_bench_cmd.step);
    }

    const run_cmd = b.addRunArtifact(ember);
    run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| run_cmd.addArgs(args); // `zig build run -- --frames N`
    const run_step = b.step("run", "Run the ember runtime");
    run_step.dependOn(&run_cmd.step);

    // ── ember-profile (the CI gate: reads report.json, roadmap M11) ─────────
    const profile_mod = b.createModule(.{
        .root_source_file = b.path("src/tools/profile/main.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    profile_mod.addImport("engine", engine_mod);
    const profile_exe = b.addExecutable(.{
        .name = "ember-profile",
        .root_module = profile_mod,
    });
    b.installArtifact(profile_exe);
    const profile_cmd = b.addRunArtifact(profile_exe);
    if (b.args) |args| profile_cmd.addArgs(args);
    const profile_step = b.step("profile", "Print and gate a report.json from a run");
    profile_step.dependOn(&profile_cmd.step);

    // ── Tests ───────────────────────────────────────────────────────────────
    // ── WGSL validation: every shader, every build ─────────────────────────────
    //
    // Dawn ships tint (C++) and this repo vendors it, so there is no reason to
    // write shaders against a spec and hope. A WGSL file that does not compile
    // is a runtime validation failure -- a blank screen with nothing in the log
    // to explain it -- so `zig build test` runs tint over every shader below,
    // and a new file has to be added to this list to be built at all. That is
    // the guard: an unlisted shader is not silently unchecked, it is absent.
    //
    // tint and not a Rust tool: the engine is heading for console exports, and a
    // C/C++ validator is one less foreign dependency to port. It has already
    // caught bugs in this repo's own shaders -- a `vec2f(vec3u)` that is not a
    // conversion, an `and` that is not `&&`, a fragment stage reading a bare
    // `shape` instead of `in.shape` -- all of which would have been blank
    // screens with nothing in the log.
    const shaders_step = b.step("shaders", "Validate every WGSL shader with Dawn's tint");
    inline for (.{
        "src/engine/render/shaders/quad.wgsl",
        "src/engine/render/shaders/sprite.wgsl",
        "src/engine/render/shaders/smaa.wgsl",
        "src/engine/render/shaders/light.wgsl",
        "src/engine/render/shaders/post.wgsl",
    }) |rel| {
        const run = b.addSystemCommand(&.{
            b.path("libs/dawn/build/tint").getPath(b),
            b.path(rel).getPath(b),
        });
        run.expectExitCode(0);
        shaders_step.dependOn(&run.step);
    }


    const test_step = b.step("test", "Run the engine core and ECS tests");
    // Every shader is validated before the tests run: a WGSL file that does not
    // compile is a runtime validation failure, which is a blank screen with
    // nothing in the log to explain it, so this is not optional.
    test_step.dependOn(shaders_step);

    // M5.5: the editor core, before anything else in the list, because it is the
    // one that has to stay green while the UI is being designed — and because it
    // runs in milliseconds with no window, so there is no excuse for not running
    // it on every change.
    const editor_tests = b.addTest(.{ .root_module = editor_mod });
    test_step.dependOn(&b.addRunArtifact(editor_tests).step);

    const session_tests = b.addTest(.{ .root_module = session_mod });
    test_step.dependOn(&b.addRunArtifact(session_tests).step);

    const core_tests = b.addTest(.{ .root_module = core_mod });
    test_step.dependOn(&b.addRunArtifact(core_tests).step);

    const ecs_tests = b.addTest(.{ .root_module = ecs_mod });
    test_step.dependOn(&b.addRunArtifact(ecs_tests).step);

    // M-project: `project.config`. Pure Zig (core only), milliseconds, no
    // window — so it gets its OWN step as well as a seat in `test`: the
    // parser/schema loop is where most of the editing happens, and waiting on
    // Dawn's shaders to learn that a field name broke is a bad trade.
    const project_tests = b.addTest(.{ .root_module = project_mod });
    test_step.dependOn(&b.addRunArtifact(project_tests).step);
    const project_step = b.step("test-project", "Run the project.config suite (parse, validate, round-trip)");
    project_step.dependOn(&b.addRunArtifact(project_tests).step);

    // M3 scripting: the VM, the sandbox, the behavior lifecycle (actors AND the
    // globals), the bindings and the metadata gate. LuaJIT but no Dawn, so it
    // is headless and quick — its own step for the same reason `test-project`
    // is: iterating on behavior.zig should not wait on the render suite.
    const script_tests_only = b.addTest(.{ .root_module = script_mod });
    test_step.dependOn(&b.addRunArtifact(script_tests_only).step);
    const script_step = b.step("test-script", "Run the scripting suite (VM, behaviors, globals, bindings, metadata)");
    script_step.dependOn(&b.addRunArtifact(script_tests_only).step);


    const physics_tests = b.addTest(.{ .root_module = physics_mod });
    test_step.dependOn(&b.addRunArtifact(physics_tests).step);

    // M8 audio: the port, the mixer maths, the rate-limited rings, the bus
    // registry, the byte-budgeted bank and both backends. Headless — the null
    // backend opens no device — so this runs on CI with no sound card.
    const audio_tests = b.addTest(.{ .root_module = audio_mod });
    test_step.dependOn(&b.addRunArtifact(audio_tests).step);

    // M3/M9 assets: the image decoder and the LRU/budget contracts.
    const assets_tests = b.addTest(.{ .root_module = assets_mod });
    test_step.dependOn(&b.addRunArtifact(assets_tests).step);
    // The asset pipeline (M6) is pure Zig + stb_image and needs no window, no
    // LuaJIT and no Box2D, so it gets its own step the way `project` does:
    // iterating on an importer or the .pak format should not wait on the rest
    // of the engine to compile.
    const assets_step = b.step("test-assets", "Run the asset pipeline suite (import, .pak, VFS, hot reload)");
    assets_step.dependOn(&b.addRunArtifact(assets_tests).step);

    // M8 asset hot-reload: the inotify watchers. The directory watch is the
    // shape the audio bank's `reload` is driven from, so its events and its
    // (Linux-only) read path are tested rather than assumed.
    const platform_tests = b.addTest(.{ .root_module = platform_mod });
    test_step.dependOn(&b.addRunArtifact(platform_tests).step);

    // The project.config → engine glue (`project_hook.zig`): the section is
    // validated before it is half-applied, and the mixer is rebuilt only when
    // the audio section actually changed.
    const hook_tests_mod = b.createModule(.{
        .root_source_file = b.path("src/runtime/project_hook.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    hook_tests_mod.addImport("core", core_mod);
    hook_tests_mod.addImport("project", project_mod);
    hook_tests_mod.addImport("audio", audio_mod);
    const hook_tests = b.addTest(.{ .root_module = hook_tests_mod });
    test_step.dependOn(&b.addRunArtifact(hook_tests).step);

    // M3 API acceptance: an EXECUTABLE, not a `zig test`. LuaJIT installs its
    // own signal/`longjmp` handling, which does not survive Zig's test runner
    // (the identical code segfaults inside `lua_pcall` under `zig test` and
    // runs clean here) — so every live-VM check in this repo goes through an
    // artifact, exactly like the M3 bench does. Exit 0 = green.
    const api_acceptance_mod = b.createModule(.{
        .root_source_file = b.path("src/engine/script/api_acceptance_test.zig"),
        .target = target,
        .optimize = .ReleaseSafe,
        .link_libc = true,
    });
    api_acceptance_mod.addImport("core", core_mod);
    api_acceptance_mod.addImport("ecs", ecs_mod);
    api_acceptance_mod.addImport("script", script_mod);
    api_acceptance_mod.addImport("physics", physics_mod);
    // The acceptance runner drives the real audio system and the asset
    // manager, so both modules must resolve here.
    api_acceptance_mod.addImport("audio", audio_mod);
    api_acceptance_mod.addImport("assets", assets_mod);
    api_acceptance_mod.addImport("render", render_mod);
    api_acceptance_mod.addImport("platform", platform_mod);
    // `api_acceptance_test.zig` pulls `bindings.zig` in BY PATH, so that file
    // is compiled into THIS module rather than into `script_mod`. Its own
    // `@import("api_meta")` therefore resolves against this module's imports,
    // and without this line the acceptance runner fails to build with "no
    // module named 'api_meta'".
    api_acceptance_mod.addImport("api_meta", api_meta_mod);
    api_acceptance_mod.addOptions("options", options);
    const api_acceptance_exe = b.addExecutable(.{ .name = "ember-api-test", .root_module = api_acceptance_mod });
    b.installArtifact(api_acceptance_exe);
    const api_acceptance_run = b.addRunArtifact(api_acceptance_exe);
    api_acceptance_run.has_side_effects = true;
    const api_acceptance_step = b.step("test-api", "Run the Lua API acceptance suites");
    api_acceptance_step.dependOn(&api_acceptance_run.step);
    test_step.dependOn(&api_acceptance_run.step);

    // The M3 surface (actor + math + vec2 + spatial), kept as its OWN runner so
    // it never collides with the suites that grew in api_acceptance_test.zig.
    const m3_mod = b.createModule(.{
        .root_source_file = b.path("src/engine/script/m3_api_test.zig"),
        .target = target,
        .optimize = .ReleaseSafe,
        .link_libc = true,
    });
    m3_mod.addImport("core", core_mod);
    m3_mod.addImport("ecs", ecs_mod);
    m3_mod.addImport("script", script_mod);
    const m3_exe = b.addExecutable(.{ .name = "ember-m3-test", .root_module = m3_mod });
    b.installArtifact(m3_exe);
    const m3_run = b.addRunArtifact(m3_exe);
    m3_run.has_side_effects = true;
    api_acceptance_step.dependOn(&m3_run.step);
    test_step.dependOn(&m3_run.step);

    // The stubs are written by the TOOL itself (it owns the output path), so
    // the build step just runs it. CI diffs `meta/ember.lua`, which is
    // committed, so a drift between the registry and the stubs is a build
    // failure rather than a stale autocomplete.
    const stubs_mod = b.createModule(.{
        .root_source_file = b.path("src/engine/script/stubs_main.zig"),
        .target = target,
        .optimize = .ReleaseSafe,
        .link_libc = true,
    });
    stubs_mod.addImport("script", script_mod);
    stubs_mod.addImport("core", core_mod);
    const stubs_exe = b.addExecutable(.{ .name = "ember-stubs", .root_module = stubs_mod });
    const stubs_cmd = b.addRunArtifact(stubs_exe);
    stubs_cmd.has_side_effects = true;
    const stubs_step = b.step("stubs", "Generate the LuaLS/EmmyLua stubs from the binding metadata");
    stubs_step.dependOn(&stubs_cmd.step);

    // ── ember-editor (the in-engine editor) ───────────────────────────────────
    // The editor requires a window and Dawn, so it's not headless.
    const editor_ui_mod = b.createModule(.{
        .root_source_file = b.path("src/tools/editor/main.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    editor_ui_mod.addImport("engine", engine_mod);
    editor_ui_mod.addImport("core", core_mod);
    editor_ui_mod.addImport("ecs", ecs_mod);
    editor_ui_mod.addImport("physics", physics_mod);
    editor_ui_mod.addImport("script", script_mod);
    editor_ui_mod.addImport("render", render_mod);
    editor_ui_mod.addImport("platform", platform_mod);
    editor_ui_mod.addImport("audio", audio_mod);
    editor_ui_mod.addImport("assets", assets_mod);
    editor_ui_mod.addImport("session", session_mod);
    editor_ui_mod.addImport("project", project_mod);
    // Dawn libraries
    editor_ui_mod.addLibraryPath(b.path("libs/dawn/build/src/dawn"));
    editor_ui_mod.addLibraryPath(b.path("libs/dawn/build/src/dawn/native"));
    editor_ui_mod.linkSystemLibrary("dawn_proc", .{});
    editor_ui_mod.linkSystemLibrary("dawn_native", .{});
    editor_ui_mod.addRPath(b.path("libs/dawn/build/src/dawn"));
    editor_ui_mod.addRPath(b.path("libs/dawn/build/src/dawn/native"));
    // LuaJIT
    editor_ui_mod.addIncludePath(.{ .cwd_relative = "/usr/include/luajit-2.1" });
    editor_ui_mod.linkSystemLibrary("luajit-5.1", .{});
    // GLFW: the editor's root module imports `runtime`, and `runtime_mod` is
    // where GLFW's sources are compiled (see the block above). Compiling them
    // a second time here produced 375 duplicate-symbol link errors — one per
    // exported GLFW function — so only the include paths are needed, for
    // main.zig's `@cImport("glfw3.h")` to resolve.
    editor_ui_mod.addIncludePath(b.path("libs/glfw/include"));
    editor_ui_mod.addIncludePath(b.path("libs/glfw/src"));
    // System deps of GLFW's X11 backend.
    inline for (.{ "X11", "Xrandr", "Xcursor", "Xinerama", "Xi", "m", "dl", "pthread" }) |lib| {
        editor_ui_mod.linkSystemLibrary(lib, .{});
    }
    editor_ui_mod.addIncludePath(b.path("libs"));
    editor_ui_mod.linkSystemLibrary("m", .{});

    const editor_exe = b.addExecutable(.{
        .name = "ember-editor",
        .root_module = editor_ui_mod,
    });
    b.installArtifact(editor_exe);
    // `editor` BUILDS; `run-editor` runs. An editor has no natural exit, so a
    // step that both compiled and ran it could never be used from a script or
    // CI — it would hang, and a hang reads as a broken build rather than as an
    // application that is doing its job.
    const editor_step = b.step("editor", "Build and install the ember editor");
    // Depends on the INSTALL step, not just the compile step: depending on the
    // compile alone left `zig-out/bin/ember-editor` at whatever an older build
    // left there, so a "successful" build could still be a stale binary.
    editor_step.dependOn(b.getInstallStep());
    const editor_run_step = b.step("run-editor", "Run the ember editor");
    editor_run_step.dependOn(&b.addRunArtifact(editor_exe).step);

    // The editor TOOLS' own tests: the tilemap Store's chunk bookkeeping, the
    // collision-layer name table and every pure helper the panels keep. They
    // run with no window and no GPU — they test state, not pixels — and they
    // belong in `test` for the same reason the UI suite does: the editor is
    // served by the same suite every other panel is, or by none.
    const editor_tools_tests = b.addTest(.{ .root_module = editor_ui_mod });
    test_step.dependOn(&b.addRunArtifact(editor_tools_tests).step);

    // M3 scripting tests: the VM, the sandbox, hot-reload, the bindings and the
    // metadata/stub layers. They link LuaJIT but not Dawn, so they run headless.
    const script_tests = b.addTest(.{ .root_module = script_mod });
    test_step.dependOn(&b.addRunArtifact(script_tests).step);

    // Render tests (M2): the batcher, the atlas packer and the Dawn binding
    // layouts. They need the engine module (hence `core`), but NOT a window:
    // they run headless, so the only native dependency is Dawn itself.
    const render_tests = b.addTest(.{
        .root_module = engine_mod,
        // "render" covers the M2 batcher/atlas/Dawn layouts; "light" covers M7.
        // Both filters matter: a test whose name misses every filter does not
        // fail, it simply never runs, which is a green suite measuring nothing.
        .filters = &.{ "render", "light" },
    });
    test_step.dependOn(&b.addRunArtifact(render_tests).step);

    // The same tests, alone. They are the ones this milestone owns, and they run
    // in milliseconds with no window and no GPU, so there is no excuse for
    // waiting on the rest of the suite to find out whether a light still works.
    //
    // The test root lives INSIDE `src/engine/render/` on purpose — see the long
    // comment at the top of that file. Rooted outside the directory it cannot
    // see the renderer's tests at all: `render/` is its own module, and Zig
    // collects tests from the root module's own files. This step therefore builds
    // its own module rooted there, with `core`/`ecs` as module imports, which is
    // why `render_mod` is NOT an input: within this compilation the files belong
    // to the test module, and claiming them twice is the "file exists in two
    // modules" error.
    //
    // Rooted at the engine boundary instead? That boundary re-exports the project
    // config and the scripting layer, so a file being edited over there takes the
    // renderer's tests down with it, and a suite that cannot run stops being run.
    const render_test_root = "src/engine/render/test_root.zig";

    // THE GUARD. Not a style check — this exact mistake shipped, and the failure
    // mode was the worst kind available: `zig build test-light` printed
    // "1 passed", the build went green, and eighty-five tests never ran. Nobody
    // noticed for months because a suite that silently disappears and a suite
    // that passes look identical from the outside.
    //
    // It lives HERE, in the build script, rather than as a test inside
    // `test_root.zig`, because of where the mistake was. A test guarding the
    // module layout has to live in the module whose layout it guards — so when
    // the layout regresses, the guard stops being collected too, and a guard
    // that disarms in the same moment as the thing it guards is not a guard.
    // That was not a hypothesis: putting the check in `test_root.zig` and then
    // re-introducing the bug produced 85 passing tests with the tripwire nowhere
    // in the run. The check has to be somewhere the bug cannot reach, and the
    // bug was in this file.
    //
    // A comptime string compare, run once when the build script is analysed. It
    // cannot drift: the thing it reads is the very string passed to
    // `root_source_file` three lines below, so there is no second copy of the
    // path to fall out of sync.
    comptime {
        if (!std.mem.endsWith(u8, render_test_root, "render/test_root.zig")) {
            @panic("test-light's root must live inside src/engine/render/: Zig collects tests from the root module's own files only, so a root anywhere else compiles every renderer test and runs none of them");
        }
    }

    const render_test_mod = b.createModule(.{
        .root_source_file = b.path(render_test_root),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    render_test_mod.addImport("core", core_mod);
    render_test_mod.addImport("ecs", ecs_mod);
    // `assets` because `atlas_bridge` imports it, and `atlas_bridge` is in the
    // suite because it is where the automatic-occluder coverage path is actually
    // wired -- the test that proves coverage is reachable goes through a real
    // atlas upload. This is a deliberate widening of the isolation the comment
    // below describes, and it is worth naming the trade: the render suite now
    // stops compiling if `assets` stops compiling. `assets` is a plain module
    // with no host coupling, which is the line this draws; `backend_dawn` is
    // excluded because it pulls in GLFW, X11 and inotify, and those are edited
    // far more often than the renderer is.
    render_test_mod.addImport("assets", assets_mod);
    // `project`, because `lighting_driver.applyLightingConfig` takes a
    // `project.config.Lighting` and there are tests here that call it. The
    // parameter is spelled out rather than generic precisely so that the
    // compiler is the thing holding the field names honest; making it generic
    // again to avoid this import would also remove the only check that caught
    // the original `backend`/`gi_backend` mismatch.
    render_test_mod.addImport("project", project_mod);

    const render_only_tests = b.addTest(.{
        .root_module = render_test_mod,
    });
    const light_only_step = b.step("test-light", "Run only the render and lighting tests");
    light_only_step.dependOn(&b.addRunArtifact(render_only_tests).step);
    light_only_step.dependOn(shaders_step);

    // ── engine.ui (M5): the editor's UI framework ───────────────────────────
    //
    // A SEPARATE module, and that is the whole design. Dear ImGui is C++, the
    // C++ runtime is linked, and a module that carries those is a module every
    // consumer inherits: the ECS tests, the benches, the runtime, `zig build
    // test`. Compiling imgui.cpp into `engine_mod` would add seconds to every
    // build in the project and would make a headless test fail to link because
    // of a UI library.
    //
    // So `/ui` is its own root, its own tests, its own demo, and exactly two
    // importers: the editor and the component gallery. `ui/keys.zig` is the one
    // exception to "no native deps" — it reads `libs/imgui/imgui.h` in a TEST,
    // which is a file read, not a link.
    const ui_mod = b.createModule(.{
        .root_source_file = b.path("src/engine/ui/root.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
        // libc++: ImGui is C++ and its std::vector usage (the font table in the
        // shim) needs the standard library. Zig ships one for this target, so
        // this does not add a system dependency.
        .link_libcpp = true,
    });
    ui_mod.addImport("core", core_mod);
    ui_mod.addImport("platform", platform_mod);
    ui_mod.addImport("render", render_mod);

    // Dear ImGui + the WebGPU backend, as C++. `language = .cpp` per file is
    // explicit because the sources are .cpp and the module is otherwise Zig:
    // letting the extension decide is fine today and is the kind of thing that
    // silently changes when a file is renamed.
    const imgui_flags = [_][]const u8{
        "-DIMGUI_IMPL_WEBGPU_BACKEND_DAWN",
        // The docking branch's own imconfig needs docking compiled in; the
        // RUNTIME flag is set by the shim, and this is the compile-time half.
        "-DIMGUI_ENABLE_DOCKING",
    };
    const imgui_files = [_][]const u8{ "imgui.cpp", "imgui_draw.cpp", "imgui_tables.cpp", "imgui_widgets.cpp" };
    ui_mod.addCSourceFiles(.{
        .root = b.path("libs/imgui"),
        .files = &imgui_files,
        .flags = &imgui_flags,
        .language = .cpp,
    });
    const imgui_backend_files = [_][]const u8{"imgui_impl_wgpu.cpp"};
    ui_mod.addCSourceFiles(.{
        .root = b.path("libs/imgui/backends"),
        .files = &imgui_backend_files,
        .flags = &imgui_flags,
        .language = .cpp,
    });
    // The shim itself. Its directory is on the include path because it
    // includes "ember_imgui_shim.h" by name.
    ui_mod.addCSourceFiles(.{
        .root = b.path("src/engine/ui/cimgui"),
        .files = &[_][]const u8{"ember_imgui_shim.cpp"},
        .flags = &imgui_flags,
        .language = .cpp,
    });
    ui_mod.addIncludePath(b.path("libs/imgui"));
    // `imgui_impl_wgpu.h` is NOT in `libs/imgui` — it is in `backends/`, and
    // the shim includes it by its bare name. Getting this wrong is the same
    // failure every time: a header that exists, a compile that says it does not,
    // and half an hour of proving they disagree.
    ui_mod.addIncludePath(b.path("libs/imgui/backends"));
    ui_mod.addIncludePath(b.path("src/engine/ui/cimgui"));
    // Dawn's C headers. `webgpu/webgpu.h` forward-declares to `dawn/webgpu.h`,
    // which lives in the GENERATED directory the Dawn build produces. Both are
    // needed: the first is the name the WebGPU backend includes, the second is
    // what it resolves to.
    ui_mod.addIncludePath(b.path("libs/dawn/include"));
    ui_mod.addIncludePath(b.path("libs/dawn/build/gen/include"));
    // The SAME Dawn the renderer links: imgui_impl_wgpu is handed our device,
    // not given one of its own, so the two must be the same library or the
    // device pointer belongs to a different instance of the runtime.
    ui_mod.addLibraryPath(b.path("libs/dawn/build/src/dawn"));
    ui_mod.addLibraryPath(b.path("libs/dawn/build/src/dawn/native"));
    ui_mod.linkSystemLibrary("dawn_proc", .{});
    ui_mod.linkSystemLibrary("dawn_native", .{});
    ui_mod.addRPath(b.path("libs/dawn/build/src/dawn"));
    ui_mod.addRPath(b.path("libs/dawn/build/src/dawn/native"));

    // ── The editor is the ONE consumer of both ────────────────────────────
    //
    // `ui` and `editor` are separate modules on purpose (see the two comments
    // above), and the editor tool is where they meet: it holds the document and
    // the UI framework, and `src/tools/editor/code_pane.zig` is the adapter that
    // maps one onto the other. Neither module imports the other, which is what
    // keeps `ui` buildable without Dawn-heavy `runtime` and keeps the editor core
    // testable without ImGui.
    //
    // The imports land HERE rather than beside `editor_ui_mod`'s other imports
    // because a build script is executed top to bottom and `ui_mod` does not
    // exist yet a few hundred lines above: naming a declaration before it is
    // made is a compile error, not a missing import.
    editor_ui_mod.addImport("ui", ui_mod);
    editor_ui_mod.addImport("editor", editor_mod);

    // The pinned imgui.h, vendored so `ui/keys.zig` can `@embedFile` it.
    //
    // It is NOT a second copy of the library: it is the FILE THE TEST READS to
    // prove the mirror has not drifted, and `@embedFile` cannot reach outside
    // the module's own package (a rule that stops a test from depending on a
    // directory layout). Copying it here, from `libs/imgui/`, means the drift
    // test checks the pin rather than a snapshot of it.
    const pinned_imgui = b.addSystemCommand(&.{
        "cp", "libs/imgui/imgui.h", b.pathFromRoot("src/engine/ui/cimgui/pinned_imgui.h"),
    });
    // The dependency is a file, and `LazyPath` wires a step to one through
    // `addAnonymousModule`/`addDependency` — but for a plain "this must be
    // newer than that" ordering the step just has to NAME the file it reads.
    // `addSystemFile` is the way to make the build watch it.
    pinned_imgui.addFileInput(b.path("libs/imgui/imgui.h"));
    // Writing to a path the build does not otherwise know is a side effect, and
    // declaring it as one is what makes `zig build` re-run this on the NEXT
    // change of the pin instead of serving a stale copy from the cache.
    pinned_imgui.has_side_effects = true;

    // ── ui-demo: the component gallery ────────────────────────────────────
    //
    // Its own executable, for a reason that is about the OTHER agent: the
    // editor's main.zig is being written, and a UI framework whose only demo is
    // a file someone else is editing is a framework nobody can see. The gallery
    // puts every component on screen at once, so "does this look right" is one
    // command and about four seconds.
    const ui_demo_mod = b.createModule(.{
        .root_source_file = b.path("src/tools/ui_demo/main.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    ui_demo_mod.addImport("engine", engine_mod);
    ui_demo_mod.addImport("core", core_mod);
    ui_demo_mod.addImport("render", render_mod);
    ui_demo_mod.addImport("platform", platform_mod);
    ui_demo_mod.addImport("ui", ui_mod);
    // The gallery needs the same windowing and GPU the editor does, so it
    // borrows the editor's own wiring for GLFW, miniaudio and stb rather than
    // duplicating those blocks. A second copy of a 40-line GLFW file list is a
    // second place for the next GLFW bug to be fixed in one place.
    copyPlatformSources(b, ui_demo_mod);

    const ui_demo_exe = b.addExecutable(.{
        .name = "ember-ui-demo",
        .root_module = ui_demo_mod,
    });
    b.installArtifact(ui_demo_exe);
    const ui_demo_step = b.step("ui-demo", "Run the UI component gallery");
    ui_demo_step.dependOn(&b.addRunArtifact(ui_demo_exe).step);

    // ── The UI framework's own tests ──────────────────────────────────────
    //
    // Headless: no Dawn, no GLFW, no window. `ui/test_root.zig` reaches the
    // pure half (tokens, store, key mapping, clamping) and nothing that submits
    // an ImGui item, because that needs a context and a device.
    const ui_test_mod = b.createModule(.{
        .root_source_file = b.path("src/engine/ui/test_root.zig"),
        .target = target,
        .optimize = .Debug,
        .link_libc = true,
    });
    ui_test_mod.addImport("core", core_mod);
    ui_test_mod.addImport("platform", platform_mod);
    ui_test_mod.addImport("render", render_mod);
    ui_test_mod.addImport("cimgui", ui_mod);
    const ui_tests = b.addTest(.{ .root_module = ui_test_mod });
    ui_tests.step.dependOn(&pinned_imgui.step);
    const ui_test_step = b.step("test-ui", "Run the UI framework's headless tests");
    ui_test_step.dependOn(&b.addRunArtifact(ui_tests).step);
}

/// The GLFW + miniaudio + stb wiring every windowed binary needs.
///
/// A function because the editor step and the UI gallery both need it and the
/// editor's copy was written as a literal block: the second binary to need
/// windowing either duplicated the file list (and fixed the next GLFW
/// problem in one of the two) or, worse, added a file to one list and not the
/// other and got a link error nobody could explain.
fn copyPlatformSources(b: *std.Build, mod: *std.Build.Module) void {
    const glfw_files = [_][]const u8{
        "context.c",        "init.c",         "input.c",
        "monitor.c",        "platform.c",     "vulkan.c",
        "window.c",         "glx_context.c",  "egl_context.c",
        "osmesa_context.c", "x11_init.c",     "x11_monitor.c",
        "x11_window.c",     "xkb_unicode.c",  "posix_module.c",
        "posix_poll.c",     "posix_thread.c", "posix_time.c",
        "linux_joystick.c", "null_init.c",    "null_joystick.c",
        "null_monitor.c",   "null_window.c",
    };
    const glfw_flags = [_][]const u8{"-D_GLFW_X11"};
    mod.addCSourceFiles(.{
        .root = b.path("libs/glfw/src"),
        .files = &glfw_files,
        .flags = &glfw_flags,
    });
    mod.addIncludePath(b.path("libs/glfw/include"));
    mod.addIncludePath(b.path("libs/glfw/src"));
    inline for (.{ "X11", "Xrandr", "Xcursor", "Xinerama", "Xi", "m", "dl", "pthread" }) |lib| {
        mod.linkSystemLibrary(lib, .{});
    }
    mod.addIncludePath(b.path("libs"));
}
