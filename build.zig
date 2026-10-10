const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // Where `bash libs/bootstrap.sh` installed Box2D. Absolute because the
    // library lives outside the build root; the same convention LuaJIT's
    // headers already use in this file.
    const box2d_prefix = "/home/jesusalcala/Projects/z-engine/libs/box2d/install";

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
    // Box2D's headers, mirroring how LuaJIT's are reached: an absolute path
    // outside the build root, so `cwd_relative`.
    physics_mod.addIncludePath(.{ .cwd_relative = box2d_prefix ++ "/include" });

    // An absolute -L as well as the library name: this version of Zig has no
    // per-library search path option, and `addLibraryPath` is module-wide.
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
    // Feature flags reach the code through this, not through build-time source
    // rewriting: `zig build -Dsteering` has to be the ONLY way the feature
    // changes, so a stale build can never disagree with what was asked for.
    script_mod.addOptions("options", options);

    physics_mod.addLibraryPath(.{ .cwd_relative = box2d_prefix ++ "/lib" });
    physics_mod.linkSystemLibrary("box2d", .{ .preferred_link_mode = .static });
    // LuaJIT 2.1 (Lua 5.1 API) from the system. The include path is where the
    // distro headers live; the linker resolves `-lluajit-5.1`. `cwd_relative`
    // because it is an absolute path outside the build root.
    script_mod.addIncludePath(.{ .cwd_relative = "/usr/include/luajit-2.1" });
    script_mod.linkSystemLibrary("luajit-5.1", .{});

    // ── Editor module (M5.5: the non-UI half of the code editor) ─────────────
    // Depends on nothing. A document, a cursor, a highlighter and a find engine
    // are pure Zig, which is exactly why they are built and tested here rather
    // than inside the editor UI: no Dawn, no window, no ImGui. The UI half of
    // M5.5 consumes this the way the renderer consumes a batcher.
    const editor_mod = b.createModule(.{
        .root_source_file = b.path("src/engine/editor/root.zig"),
        .target = target,
        .optimize = optimize,
    });

    // ── Engine module (public boundary: core + platform + render) ───────────
    const engine_mod = b.createModule(.{
        .root_source_file = b.path("src/engine/root.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    // Separate modules: each subsystem compiles and tests on its own.
    engine_mod.addImport("core", core_mod);
    engine_mod.addImport("ecs", ecs_mod);
    engine_mod.addImport("physics", physics_mod);
    // M3: the LuaJIT scripting layer. It links LuaJIT but NOT Dawn, so the
    // scripting tests and the M3 bench run headless like the ECS ones do.
    engine_mod.addImport("script", script_mod);

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

    // ── ember runtime ───────────────────────────────────────────────────────
    const runtime_mod = b.createModule(.{
        .root_source_file = b.path("src/runtime/main.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    runtime_mod.addImport("engine", engine_mod);

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
    const test_step = b.step("test", "Run the engine core and ECS tests");

    // M5.5: the editor core, before anything else in the list, because it is the
    // one that has to stay green while the UI is being designed — and because it
    // runs in milliseconds with no window, so there is no excuse for not running
    // it on every change.
    const editor_tests = b.addTest(.{ .root_module = editor_mod });
    test_step.dependOn(&b.addRunArtifact(editor_tests).step);

    const core_tests = b.addTest(.{ .root_module = core_mod });
    test_step.dependOn(&b.addRunArtifact(core_tests).step);

    const ecs_tests = b.addTest(.{ .root_module = ecs_mod });
    test_step.dependOn(&b.addRunArtifact(ecs_tests).step);

    const physics_tests = b.addTest(.{ .root_module = physics_mod });
    test_step.dependOn(&b.addRunArtifact(physics_tests).step);

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

    // M3 scripting tests: the VM, the sandbox, hot-reload, the bindings and the
    // metadata/stub layers. They link LuaJIT but not Dawn, so they run headless.
    const script_tests = b.addTest(.{ .root_module = script_mod });
    test_step.dependOn(&b.addRunArtifact(script_tests).step);

    // Render tests (M2): the batcher, the atlas packer and the Dawn binding
    // layouts. They need the engine module (hence `core`), but NOT a window:
    // they run headless, so the only native dependency is Dawn itself.
    const render_tests = b.addTest(.{
        .root_module = engine_mod,
        .filters = &.{"render"},
    });
    test_step.dependOn(&b.addRunArtifact(render_tests).step);
}
