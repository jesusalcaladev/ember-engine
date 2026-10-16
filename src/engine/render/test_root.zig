//! The lighting and render test root — and it lives HERE, inside `render/`,
//! rather than beside it. That placement is the whole reason it is a file.
//!
//! # Why it is not at `src/engine/render_test_root.zig`
//!
//! `zig build test-light` reported **1 test passed** for months, and the one test
//! was the root's own `test { ... }` block. Every one of the renderer's and the
//! lighting system's tests was COMPILED and never RUN.
//!
//! Two separate mistakes stacked up to do it:
//!
//! 1. `std.testing.refAllDecls` does not recurse. The tests are fields of
//!    `Lighting`, `Radiance`, `CoverageStore` and friends; `refAllDecls` on a
//!    struct of module references takes the address of each reference and stops,
//!    so nothing nested was ever analysed. `refAllDecls` is the right tool for a
//!    flat file and the wrong one for a subsystem, and the failure is silent:
//!    the suite compiles, runs, and reports success.
//!
//! 2. More fundamentally, `src/engine/render/` is a separate Zig MODULE since
//!    the boundary refactor. Zig collects tests from the files of the ROOT
//!    MODULE only. A test root that `@import`s the renderer as a module sees
//!    its code — and not one of its tests, no matter how many declarations it
//!    references. No amount of recursion from outside can fix that, because the
//!    tests are not reachable as tests from that module at all.
//!
//! The fix is placement rather than cleverness: this file is inside `render/`,
//! so `zig build test-light` builds a module rooted HERE, these files belong to
//! it, and their tests are its tests. Relative imports are correct in this file
//! and were never legal in the one that sat outside — the comment there said as
//! much, and was read as a constraint rather than as the bug it described.
//!
//! Each module below is referenced once, on purpose: a declaration nobody
//! references is a file whose tests are compiled but never run, which is how the
//! null backend's light-pass test disappeared the first time round.
//!
//! `backend_dawn` is deliberately NOT referenced. It imports the platform layer
//! — inotify, GLFW, X11 — which is edited far more often than the renderer, and
//! a subsystem's tests should not stop running because an unrelated file does not
//! compile. The Dawn path is covered by `zig build` and by the acceptance runner.
//!
//! `atlas_bridge` IS referenced, and it widens this module's dependency set by
//! one: it imports `assets`. That is a trade, and it is taken deliberately — the
//! test that proves automatic-occluder coverage is reachable has to go through a
//! real atlas upload, because the whole defect being fixed was that coverage was
//! reachable from nowhere. A test that stopped one layer short would have passed
//! while the game still cast rectangles.

const std = @import("std");
const builtin = @import("builtin");

pub const batcher = @import("batcher.zig");
pub const atlas = @import("atlas.zig");
pub const two_d = @import("2d.zig");
pub const particles = @import("particles.zig");
pub const fade = @import("fade.zig");
pub const light = @import("light.zig");
pub const lighting_driver = @import("lighting_driver.zig");
pub const backend_null = @import("backend_null.zig");
pub const atlas_bridge = @import("atlas_bridge.zig");
pub const asset_reload = @import("asset_reload.zig");

test {
    _ = batcher;
    _ = atlas;
    _ = two_d;
    _ = particles;
    _ = fade;
    _ = light;
    _ = lighting_driver;
    _ = backend_null;
    _ = atlas_bridge;
    _ = asset_reload;

    // `refAllDecls` on the root as well, deliberately. The explicit references
    // above are what pull each file's own top-level tests in; this is cheap
    // insurance that THIS file is analysed in a test build, and it costs
    // nothing when the references above have already done their job.
    std.testing.refAllDecls(@This());
}

// ---------------------------------------------------------------------------
// The tripwire
// ---------------------------------------------------------------------------
//
// A suite that compiles, runs, and reports success while running nothing is
// worse than a suite that fails: a failing one gets looked at, and a passing
// one gets believed. That is what happened here for months, so there are now
// two checks against it, in the two places a regression can come from.
//
// # 1. This file: a subsystem reached as a MODULE
//
// It asserts that each subsystem's type name carries NO module prefix. In a
// multi-module Zig build a type from another module prints as `modname.Type`;
// one from the root module prints bare:
//
//   light.Lighting        -> root module -> its tests ARE collected
//   render.light.Lighting -> other module -> its tests are NOT
//
// The module graph decides this, so it is checkable at COMPILE time with no
// counting and no dependence on test ordering — which matters, because the two
// obvious alternatives do not work. Both were tried:
//
// - A comptime CENSUS of test declarations. Zig 0.16 does not put them in
//   `std.meta.declarations`: that list is `@typeInfo(T).decls`, which for
//   `light.Lighting` is its seventeen functions and constants, with no `test`
//   among them. `@hasDecl(light.Lighting, "test")` is `false` too. The
//   compiler keeps tests in a table Zig code cannot reach, so a census written
//   against `decls` reports ZERO for a file with forty tests — the exact shape
//   of the bug it was meant to catch.
//
// - A RUNTIME counter, with each subsystem incrementing it from a sentinel
//   test. That works too, and it is unusable: this tripwire is the root
//   module's first test, so it runs BEFORE the sentinels it counts and reads
//   zero against a perfectly healthy suite. Making it pass means inventing an
//   ordering guarantee Zig's runner does not document.
//
// # 2. `build.zig`: the root itself moved
//
// The check above cannot catch this file being re-rooted outside `render/` —
// when it is, this file's own tests stop being collected along with everything
// else, so the guard disarms exactly when it is needed. That was demonstrated,
// not reasoned about: re-introducing the original bug produced 85 passing tests
// with this tripwire nowhere in the run. So the authoritative guard is a
// comptime string check in `build.zig`, where the mistake actually happens and
// which cannot be switched off by the thing it is watching.

/// Whether `comptime T` belongs to the ROOT module — the one Zig collects
/// tests from.
///
/// A type from another module prints as `modname.Type`. A nested type inside a
/// root-module file prints as `Container.Nested`, and a file-level one prints
/// with no dot at all. So "at most one dot" separates them: a module qualifier
/// adds a segment, and no amount of nesting inside the root module does.
///
/// Counting dots rather than comparing against the root module's NAME is
/// deliberate. That name comes from this file's path, so it changes whenever
/// this file is renamed — and a check naming it would fail on the rename, at
/// which point the tempting fix is editing the assertion instead of the layout.
/// This one survives renames, because what it cares about is the ABSENCE of a
/// prefix, not which name the prefix would have had.
fn isRootModule(comptime T: type) bool {
    return std.mem.count(u8, @typeName(T), ".") <= 1;
}

test "the renderer's tests are in this binary, not just its code" {
    // Not a test of the renderer — a test of THIS FILE. It fails if a subsystem
    // ends up reachable only as a module, which is how the null backend's
    // light-pass test disappeared the first time round.
    if (!builtin.is_test) return error.SkipZigTest;

    // One per subsystem, each naming its own file in the failure. "Somebody's
    // tests went quiet" is not an actionable bug report; "the null backend's
    // tests went quiet" is.
    comptime {
        if (!isRootModule(light.Lighting))
            @compileError("light.zig is reachable as a module, so its tests are compiled and never run");
        if (!isRootModule(lighting_driver.Driver))
            @compileError("lighting_driver.zig is reachable as a module, so its tests are compiled and never run");
        if (!isRootModule(backend_null.Backend))
            @compileError("backend_null.zig is reachable as a module, so its tests are compiled and never run");
        if (!isRootModule(batcher.Batcher))
            @compileError("batcher.zig is reachable as a module, so its tests are compiled and never run");
        if (!isRootModule(atlas.AtlasPacker))
            @compileError("atlas.zig is reachable as a module, so its tests are compiled and never run");
        if (!isRootModule(atlas_bridge.AtlasManager))
            @compileError("atlas_bridge.zig is reachable as a module, so its tests are compiled and never run");
        if (!isRootModule(asset_reload.Reloader))
            @compileError("asset_reload.zig is reachable as a module, so its tests are compiled and never run");
        if (!isRootModule(two_d.Renderer2D))
            @compileError("2d.zig is reachable as a module, so its tests are compiled and never run");
        if (!isRootModule(particles.System))
            @compileError("particles.zig is reachable as a module, so its tests are compiled and never run");
        if (!isRootModule(fade.Fader))
            @compileError("fade.zig is reachable as a module, so its tests are compiled and never run");
    }
}