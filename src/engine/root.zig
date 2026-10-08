//! `engine` — the engine's public boundary.
//!
//! The runtime and the editor import this module by name and only see what
//! is re-exported here. Dawn/GLFW stay hidden behind platform/render (spec §7).
//!
//! `core` and `ecs` are separate build *modules* so each one can be compiled
//! (and tested) on its own: `zig build test` runs them without linking Dawn.

pub const core = @import("core");
pub const ecs = @import("ecs");
pub const platform = @import("platform/platform.zig");
pub const render = @import("render/render.zig");

test {
    @import("std").testing.refAllDecls(@This());
}
