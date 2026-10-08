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

    // ── Engine module (public boundary: core + platform + render) ───────────
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

    const ember = b.addExecutable(.{
        .name = "ember",
        .root_module = runtime_mod,
    });
    b.installArtifact(ember);

    const run_cmd = b.addRunArtifact(ember);
    run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| run_cmd.addArgs(args); // `zig build run -- --frames N`
    const run_step = b.step("run", "Run the ember runtime");
    run_step.dependOn(&run_cmd.step);

    // ── Tests ───────────────────────────────────────────────────────────────
    const core_tests = b.addTest(.{ .root_module = core_mod });
    const run_core_tests = b.addRunArtifact(core_tests);
    const test_step = b.step("test", "Run the engine core tests");
    test_step.dependOn(&run_core_tests.step);
}
