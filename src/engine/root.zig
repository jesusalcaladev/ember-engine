//! `engine` — the engine's public boundary.
//!
//! The runtime and the editor import this module by name and only see what
//! is re-exported here. Dawn/GLFW stay hidden behind platform/render (spec §7).

pub const core = @import("core/root.zig");
pub const platform = @import("platform/platform.zig");
pub const render = @import("render/render.zig");

test {
    @import("std").testing.refAllDecls(@This());
}
