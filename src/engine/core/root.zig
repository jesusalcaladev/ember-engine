//! `engine.core` — engine foundations (no native dependencies).
//!
//! Everything here is purely testable and follows spec.md:
//! zero allocations in the frame loop (arena), free logging, fixed timestep.

pub const log = @import("log.zig");
pub const time = @import("time.zig");
pub const arena = @import("arena.zig");
pub const tracker = @import("tracker.zig");
pub const profiler = @import("profiler.zig");
pub const sampler = @import("sampler.zig");
pub const json = @import("json.zig");
pub const budget = @import("budget.zig");
pub const trace = @import("trace.zig");
pub const report = @import("report.zig");
pub const loop = @import("loop.zig");
pub const math = @import("math.zig");
pub const random = @import("random.zig");
pub const noise = @import("noise.zig");

/// Reads a whole (small) file into `buf`. Fixed-buffer, no allocation: the
/// CI gate uses it to read a report.json.
pub const readFileToBuf = json.readWholeFile;

test {
    @import("std").testing.refAllDecls(@This());
}
