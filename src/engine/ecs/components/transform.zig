//! `Transform` — local 2D transform plus the previous fixed-tick snapshot
//! (M1, split out of components.zig).

const core_math = @import("core").math;

pub const Vec2 = core_math.Vec2;

/// Unit vector, the default scale/size every sized component starts from.
pub const unit = Vec2{ .x = 1, .y = 1 };

/// Local 2D transform plus the previous fixed-tick snapshot, so the renderer
/// can interpolate without touching simulation state (spec §3.3).
pub const Transform = struct {
    position: Vec2 = Vec2{},
    rotation: f32 = 0,
    scale: Vec2 = unit,
    prev_position: Vec2 = Vec2{},
    prev_rotation: f32 = 0,
    prev_scale: Vec2 = unit,

    /// Call at the start of a fixed tick: what is about to be overwritten
    /// must survive as "previous" for the interpolator.
    pub fn capturePrevious(self: *Transform) void {
        self.prev_position = self.position;
        self.prev_rotation = self.rotation;
        self.prev_scale = self.scale;
    }

    /// Linear interpolation between the previous and current snapshot.
    pub fn interpolated(self: *const Transform, alpha: f32) Transform {
        return .{
            .position = self.prev_position.lerp(self.position, alpha),
            .rotation = self.prev_rotation + (self.rotation - self.prev_rotation) * alpha,
            .scale = self.prev_scale.lerp(self.scale, alpha),
        };
    }
};

// ── Tests ────────────────────────────────────────────────────────────────────

const std = @import("std");
const testing = std.testing;

test "Transform is 40 bytes (auto layout interleaves the prev_* snapshot)" {
    try testing.expectEqual(@as(usize, 40), @sizeOf(Transform));
}

test "Transform interpolation goes from prev to current (spec §3.3)" {
    var now = Transform{
        .position = .{ .x = 0, .y = 0 },
        .rotation = 0,
        .scale = unit,
    };
    now.prev_position = now.position;
    now.prev_rotation = now.rotation;
    now.prev_scale = now.scale;

    // One fixed tick later (the simulation wrote the current fields).
    now.position = .{ .x = 10, .y = 20 };
    now.rotation = 2;

    const mid = now.interpolated(0.5);
    try testing.expectApproxEqAbs(@as(f32, 5), mid.position.x, 0.0001);
    try testing.expectApproxEqAbs(@as(f32, 10), mid.position.y, 0.0001);
    try testing.expectApproxEqAbs(@as(f32, 1), mid.rotation, 0.0001);
    try testing.expectApproxEqAbs(@as(f32, 1), mid.scale.x, 0.0001);

    // capturePrevious is what makes "prev" mean "the last simulated tick".
    now.capturePrevious();
    try testing.expectApproxEqAbs(@as(f32, 10), now.prev_position.x, 0.0001);
    try testing.expectApproxEqAbs(@as(f32, 2), now.prev_rotation, 0.0001);
}

test "a fresh Transform interpolates to its spawn position, not to the origin" {
    // Without seeding prev_* from the live fields, `interpolated(0)` returns
    // the (0,0) default and every actor visibly slides in from the top-left
    // corner on the first frame. The world seeds it at spawn time.
    const spawned = Transform{
        .position = .{ .x = 120, .y = -45 },
        .rotation = 1.5,
        .scale = .{ .x = 3, .y = 4 },
    };
    var seeded = spawned;
    seeded.capturePrevious();

    const at_zero = seeded.interpolated(0);
    try testing.expectApproxEqAbs(@as(f32, 120), at_zero.position.x, 0.0001);
    try testing.expectApproxEqAbs(@as(f32, -45), at_zero.position.y, 0.0001);
    try testing.expectApproxEqAbs(@as(f32, 1.5), at_zero.rotation, 0.0001);
    try testing.expectApproxEqAbs(@as(f32, 3), at_zero.scale.x, 0.0001);

    const at_one = seeded.interpolated(1);
    try testing.expectApproxEqAbs(@as(f32, 120), at_one.position.x, 0.0001);
}