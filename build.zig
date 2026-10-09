const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

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
    // LuaJIT 2.1 (Lua 5.1 API) from the system. The include path is where the
    // distro headers live; the linker resolves `-lluajit-5.1`. `cwd_relative`
    // because it is an absolute path outside the build root.
    script_mod.addIncludePath(.{ .cwd_relative = "/usr/include/luajit-2.1" });
    script_mod.linkSystemLibrary("luajit-5.1", .{});

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
        "context.c",        "init.c",          "input.c",
        "monitor.c",        "platform.c",      "vulkan.c",
        "window.c",         "glx_context.c",   "egl_context.c",
        "osmesa_context.c", "x11_init.c",      "x11_monitor.c",
        "x11_window.c",     "xkb_unicode.c",   "posix_module.c",
        "posix_poll.c",     "posix_thread.c",  "posix_time.c",
        "linux_joystick.c", "null_init.c",     "null_joystick.c",
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

    const core_tests = b.addTest(.{ .root_module = core_mod });
    test_step.dependOn(&b.addRunArtifact(core_tests).step);

    const ecs_tests = b.addTest(.{ .root_module = ecs_mod });
    test_step.dependOn(&b.addRunArtifact(ecs_tests).step);

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
    const t1 = b.createModule(.{ .root_source_file = b.path("src/engine/script/t1_tmp.zig"), .target = target, .optimize = .ReleaseSafe, .link_libc = true });
    t1.addImport("core", core_mod);
    t1.addImport("ecs", ecs_mod);
    t1.addImport("script", script_mod);
    t1.addImport("core", core_mod);
    b.installArtifact(b.addExecutable(.{ .name = "t1", .root_module = t1 }));
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
