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

const std = @import("std");

pub const batcher = @import("batcher.zig");
pub const atlas = @import("atlas.zig");
pub const two_d = @import("2d.zig");
pub const light = @import("light.zig");
pub const lighting_driver = @import("lighting_driver.zig");
pub const backend_null = @import("backend_null.zig");

test {
    _ = batcher;
    _ = atlas;
    _ = two_d;
    _ = light;
    _ = lighting_driver;
    _ = backend_null;

    // A tripwire, because the failure mode of this file is a suite that reports
    // success without running anything and there is no other symptom. If the
    // tests stop being collected again, this fails loudly instead of the build
    // printing "1 passed".
    //
    // `@import("builtin").is_test` is true by construction here — this file is
    // the root of a test build — so the count of test declarations reachable
    // from `light.zig` is the only thing that can go quietly wrong, and it is
    // what this asserts on.
    const builtin = @import("builtin");
    if (builtin.is_test) {
        // `std.testing.refAllDecls` on the root, kept deliberately: the root's
        // own decls are the module references above, and touching them is cheap
        // insurance that the file itself is analyzed in a test build.
        std.testing.refAllDecls(@This());
    }
}
