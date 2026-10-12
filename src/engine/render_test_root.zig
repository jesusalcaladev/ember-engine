//! The render subsystem's own test root.
//!
//! # Why this file exists
//!
//! `src/engine/root.zig` is the engine's public boundary and it grows: it now
//! re-exports the project config, the editor surface, the scripting layer and
//! the asset pipeline. Its test block is `refAllDecls(@This())`, so a module
//! that is mid-edit somewhere else in that list takes the RENDER tests down
//! with it — and a render suite that cannot run while someone works on an
//! unrelated file is a render suite that stops being run.
//!
//! This root exists so `zig build test-light` compiles only what the renderer
//! needs: the batcher, the atlas, the 2D collector, the lighting system and
//! both backends. It is a narrower dependency set, not a second copy of the
//! tests — the same files, analyzed from a root that does not drag in the rest
//! of the engine.
//!
//! The M2/M3/M7 test filters still apply, so `test-render` runs the renderer,
//! the lights and the backends and nothing else.

const std = @import("std");

pub const render = @import("render/render.zig");
pub const batcher = @import("render/batcher.zig");
pub const atlas = @import("render/atlas.zig");
pub const two_d = @import("render/2d.zig");
pub const light = @import("render/light.zig");
pub const backend_null = @import("render/backend_null.zig");
pub const backend_dawn = @import("render/backend_dawn.zig");
pub const lighting_driver = @import("render/lighting_driver.zig");

test {
    // `refAllDecls` on THIS is what pulls each file's own tests into the
    // binary. `render.zig` re-exports `backend_null`, and a declaration nobody
    // references is a file whose tests are compiled but never run — which is
    // exactly what happened to the null backend's light-pass test.
    std.testing.refAllDecls(@This());
}
