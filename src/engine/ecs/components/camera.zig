//! `Camera2D` — the 2D camera component (ROADMAP M4.5).
//!
//! Unity-level 2D camera: follow with damping, zoom with min/max and smoothing,
//! trauma-based screen shake, world limits, deadzone and look-ahead. Plain data
//! (registry rule 1); `ecs/camera.zig` is the system that ADVANCES it each fixed
//! tick, and `script/bindings.zig`'s `camera.*` table is what Lua drives it with.
//!
//! Note on `Rect2`: the engine's `Rect2` is position (top-left) + size. A
//! negative size means "disabled" for the two optional rects (deadzone, and
//! limits when `limits_enabled` is false), so the default encodes "off" without
//! an extra flag.

const entity = @import("../entity.zig");
const core_math = @import("core").math;

pub const Entity = entity.Entity;
pub const Vec2 = core_math.Vec2;
const math = core_math;

pub const Camera2D = struct {
    /// Entity to follow. invalid = no target.
    target: Entity = Entity.invalid,
    /// Whether to follow the target.
    follow_enabled: bool = true,
    /// Deadzone around the camera CENTRE, in world units: `.position` is the
    /// offset of the rect's top-left from the centre and `.size` its extent.
    /// The target only moves the camera once it leaves this rect. Negative
    /// size = disabled (the default).
    deadzone: math.Rect2 = math.Rect2{ .position = .{ .x = 0, .y = 0 }, .size = .{ .x = -1, .y = -1 } },
    /// Follow damping: the critically-damped spring's natural frequency. Higher
    /// = snappier; 0 = snap to the target with no smoothing.
    damping: f32 = 5.0,
    /// Look-ahead factor (seconds of target velocity to lead by, 0..1-ish).
    /// Anticipates where the target is going so a runner is not glued to the
    /// frame edge.
    look_ahead: f32 = 0.0,

    // Zoom
    zoom: f32 = 1.0,
    min_zoom: f32 = 0.1,
    max_zoom: f32 = 10.0,
    /// Zoom smoothing rate (same critically-damped spring as `damping`).
    zoom_damping: f32 = 8.0,

    // Screen shake (trauma-based, like UE4's camera shake)
    trauma: f32 = 0.0,
    /// Shake magnitude scales with `trauma ^ trauma_power`, so a small trauma
    /// is a nudge and a full one is violent, on one slider.
    trauma_power: f32 = 2.0,
    trauma_decay: f32 = 1.0,
    shake_frequency: f32 = 25.0,
    shake_amplitude: f32 = 10.0,

    // World limits
    limits_enabled: bool = false,
    limits: math.Rect2 = math.Rect2{ .position = .{ .x = -10000, .y = -10000 }, .size = .{ .x = 20000, .y = 20000 } },

    /// Whether this camera is a candidate for the ACTIVE view. The camera
    /// system picks the first enabled camera in slot order — deterministic
    /// (spec §6), and "which camera is on" is an editor/runtime toggle, not a
    /// scene-data race.
    enabled: bool = true,

    // Internal state, advanced by `ecs/camera.zig` each fixed tick.
    _offset: Vec2 = .{ .x = 0, .y = 0 },
    _velocity: Vec2 = .{ .x = 0, .y = 0 },
    _target_zoom: f32 = 1.0,
    _trauma_timer: f32 = 0.0,

    pub fn follow(self: *Camera2D, target: Entity) void {
        self.target = target;
        self.follow_enabled = true;
    }

    pub fn unfollow(self: *Camera2D) void {
        self.follow_enabled = false;
    }

    pub fn add_trauma(self: *Camera2D, amount: f32) void {
        self.trauma = math.min(self.trauma + amount, 1.0);
    }

    pub fn set_zoom(self: *Camera2D, zoom: f32) void {
        self._target_zoom = math.clamp(zoom, self.min_zoom, self.max_zoom);
        self.zoom = self._target_zoom;
    }

    /// Requests a zoom; the camera system eases toward it at `zoom_damping`.
    pub fn zoom_to(self: *Camera2D, zoom: f32) void {
        self._target_zoom = math.clamp(zoom, self.min_zoom, self.max_zoom);
    }

    pub fn set_limits(self: *Camera2D, limits: math.Rect2, enabled: bool) void {
        self.limits = limits;
        self.limits_enabled = enabled;
    }

    pub fn set_deadzone(self: *Camera2D, deadzone: math.Rect2) void {
        self.deadzone = deadzone;
    }

    pub fn set_look_ahead(self: *Camera2D, factor: f32) void {
        self.look_ahead = math.clamp(factor, 0.0, 1.0);
    }

    /// The world rectangle this camera shows for a given viewport size.
    pub fn get_world_rect(self: *const Camera2D, viewport: Vec2) math.Rect2 {
        // `fromCenter` takes the FULL width/height; at zoom z a viewport of w
        // pixels covers w/z world units.
        return math.Rect2.fromCenter(
            self._offset,
            viewport.x / self.zoom,
            viewport.y / self.zoom,
        );
    }

    /// Pixel (viewport top-left) -> world.
    pub fn screen_to_world(self: *const Camera2D, screen: Vec2, viewport: Vec2) Vec2 {
        const rect = self.get_world_rect(viewport);
        return .{
            .x = rect.position.x + screen.x / self.zoom,
            .y = rect.position.y + screen.y / self.zoom,
        };
    }

    /// World -> pixel (viewport top-left).
    pub fn world_to_screen(self: *const Camera2D, world: Vec2, viewport: Vec2) Vec2 {
        const rect = self.get_world_rect(viewport);
        return .{
            .x = (world.x - rect.position.x) * self.zoom,
            .y = (world.y - rect.position.y) * self.zoom,
        };
    }
};

// ── Tests ────────────────────────────────────────────────────────────────────

const std = @import("std");
const testing = std.testing;

test "Camera2D stays under the decoder stride and its primitives hold" {
    // `max_stride` is the decode buffer; a camera that outgrew it would corrupt
    // `.zson` loads silently, so the bound is a test rather than a comment.
    try testing.expect(@sizeOf(Camera2D) <= 128);

    var cam = Camera2D{};
    cam.set_zoom(4.0);
    try testing.expectEqual(@as(f32, 4.0), cam.zoom);
    cam.zoom_to(100.0);
    // zoom_to only sets the TARGET; the clamp is against max_zoom.
    try testing.expectEqual(@as(f32, 10.0), cam._target_zoom);

    cam.add_trauma(0.7);
    cam.add_trauma(0.7);
    try testing.expectEqual(@as(f32, 1.0), cam.trauma); // capped at 1

    // Pixel<->world round trip at zoom 4 over a 1280x720 viewport.
    cam.set_zoom(4.0);
    cam._offset = .{ .x = 100, .y = 50 };
    const viewport = Vec2{ .x = 1280, .y = 720 };
    // The viewport CENTRE always maps to the camera centre — the round trip is
    // about that invariant as much as about the arithmetic.
    const world = cam.screen_to_world(.{ .x = 640, .y = 360 }, viewport);
    try testing.expectApproxEqAbs(@as(f32, 100), world.x, 0.0001);
    try testing.expectApproxEqAbs(@as(f32, 50), world.y, 0.0001);
    const back = cam.world_to_screen(world, viewport);
    try testing.expectApproxEqAbs(@as(f32, 640), back.x, 0.0001);
    try testing.expectApproxEqAbs(@as(f32, 360), back.y, 0.0001);
}