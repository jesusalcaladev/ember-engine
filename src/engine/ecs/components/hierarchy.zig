//! `Parent` and `Velocity` — the two small simulation components (M1, split
//! out of components.zig).

const entity = @import("../entity.zig");

pub const Entity = entity.Entity;
const core_math = @import("core").math;

pub const Vec2 = core_math.Vec2;

/// Parent link. The hierarchy itself is derived by `hierarchy` (flat, no
/// recursion); this is the only thing stored per entity.
pub const Parent = struct {
    /// Entity handle of the parent. `invalid` (or a dead parent) means "root".
    parent: Entity = Entity.invalid,
};

/// Linear and angular velocity: plain data the fixed step integrates into
/// `Transform`. Kept separate so a kinematic actor can move without a
/// transform and a transform can move without one.
pub const Velocity = struct {
    linear: Vec2 = Vec2{},
    /// Radians per second, positive clockwise (screen space y grows down).
    angular: f32 = 0,
};

// ── Tests ────────────────────────────────────────────────────────────────────

const std = @import("std");
const testing = std.testing;

test "small component sizes stay pinned" {
    // `Parent` is 8 because both u32 fields pack into one `Entity`.
    try testing.expectEqual(@as(usize, 8), @sizeOf(Parent));
    try testing.expectEqual(@as(usize, 12), @sizeOf(Velocity));
}