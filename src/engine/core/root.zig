//! `engine.core` — engine foundations (no native dependencies).
//!
//! Everything here is purely testable and follows spec.md:
//! zero allocations in the frame loop (arena), free logging, fixed timestep.

pub const log = @import("log.zig");
pub const time = @import("time.zig");
pub const arena = @import("arena.zig");
pub const tracker = @import("tracker.zig");
pub const profiler = @import("profiler.zig");
pub const loop = @import("loop.zig");
pub const math = @import("math.zig");

test {
    @import("std").testing.refAllDecls(@This());
}
