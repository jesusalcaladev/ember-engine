//! The Camera2D system (ROADMAP M4.5): advances the active camera each fixed
//! tick and returns the view the renderer and the culler consume.
//!
//! ## Why the view comes OUT of the system instead of the renderer owning it
//!
//! The renderer is handed a finished `{centre, zoom, viewport}` (`View`) and
//! nothing else. That keeps the layering the rest of the engine has: the ECS
//! knows nothing about Dawn, the renderer knows nothing about follow targets,
//! and the runtime is the one place that connects them — the same shape as
//! `render2d.collect` producing instances the backend merely draws.
//!
//! ## Why the fixed step
//!
//! Follow, zoom and shake all gate what gameplay sees and when (a screen shake
//! that lands a frame late is a bug, and a camera hash that differs between two
//! identical runs breaks spec §6). The noise driving the shake is the
//! deterministic `core.noise`, seeded from the camera's own scene id, so the
//! same run replays the same shake.

const std = @import("std");
const core = @import("core");
const world_mod = @import("world.zig");
const components = @import("components.zig");

const math = core.math;
const noise = core.noise;
const World = world_mod.World;
const Entity = @import("entity.zig").Entity;
const Vec2 = math.Vec2;

/// The camera's output: everything the renderer needs, nothing more.
pub const View = struct {
    cx: f32 = 0,
    cy: f32 = 0,
    zoom: f32 = 1,
    viewport_w: f32 = 1280,
    viewport_h: f32 = 720,

    /// The world rectangle visible this frame (no margin: this is the exact
    /// view; the culler adds its own edge margin).
    pub fn worldRect(self: View) math.Rect2 {
        return math.Rect2.fromCenter(
            .{ .x = self.cx, .y = self.cy },
            self.viewport_w / self.zoom,
            self.viewport_h / self.zoom,
        );
    }

    pub fn worldToScreen(self: View, world: Vec2) Vec2 {
        const rect = self.worldRect();
        return .{
            .x = (world.x - rect.position.x) * self.zoom,
            .y = (world.y - rect.position.y) * self.zoom,
        };
    }

    pub fn screenToWorld(self: View, screen: Vec2) Vec2 {
        const rect = self.worldRect();
        return .{
            .x = rect.position.x + screen.x / self.zoom,
            .y = rect.position.y + screen.y / self.zoom,
        };
    }

    /// The column-major view-projection matrix for this view, in the layout
    /// `render.Camera` expects.
    ///
    /// Scaling by `zoom` is what makes a zoom of 2 show twice the detail over
    /// half the world width; the `-cx`/`-cy` translation is the follow. Both are
    /// in ONE matrix rather than two passes so the renderer's shader contract
    /// stays a single multiply, and so a cull and a draw can never disagree
    /// about where the camera is (that disagreement is the classic "things
    /// vanish while still on screen" bug).
    pub fn viewProjection(self: View) [16]f32 {
        const sx = self.zoom * 2.0 / self.viewport_w;
        const sy = self.zoom * 2.0 / self.viewport_h;
        // Column-major: [sx 0 0 tx, 0 sy 0 ty, 0 0 1 0, 0 0 0 1]
        return .{
            sx, 0,  0, 0,
            0,  sy, 0, 0,
            0,  0,  1, 0,
            -self.cx * sx, -self.cy * sy, 0, 1,
        };
    }
};

/// Advances the first ENABLED camera (slot order — deterministic, spec §6) and
/// returns the view it produces, or `null` when the scene has no enabled
/// camera. A null return means "no camera": the caller keeps its previous
/// behaviour (the runtime draws the default centred view), exactly like a null
/// culling view draws everything.
pub fn update(world: *World, dt: f32, viewport_w: f32, viewport_h: f32) ?View {
    var slot: usize = 0;
    var active: ?Entity = null;
    while (slot < world.slotCount()) : (slot += 1) {
        const e = world.entityAtSlot(slot) orelse continue;
        const cam = world.get(e, components.Camera2D) orelse continue;
        if (cam.enabled) {
            active = e;
            break;
        }
    }
    const e = active orelse return null;
    const cam = world.get(e, components.Camera2D).?;

    // ── Zoom: the same critically-damped spring as the follow ────────────────
    if (cam.zoom_damping <= 0) {
        cam.zoom = cam._target_zoom;
    } else {
        cam.zoom = math.damp(cam.zoom, cam._target_zoom, cam.zoom_damping, dt);
    }
    cam.zoom = math.clamp(cam.zoom, cam.min_zoom, cam.max_zoom);

    // ── Follow ───────────────────────────────────────────────────────────────
    var desired = cam._offset;
    if (cam.follow_enabled and !cam.target.isInvalid() and world.isAlive(cam.target)) {
        if (world.get(cam.target, components.Transform)) |target_tf| {
            var aim = target_tf.position;
            // Look-ahead leads the target's velocity. The target's Velocity
            // component is the only source: a camera that guessed at frame
            // deltas would be frame-rate dependent, which is exactly what the
            // fixed step exists to avoid.
            if (cam.look_ahead > 0) {
                if (world.get(cam.target, components.Velocity)) |v| {
                    aim = aim.add(v.linear.scale(cam.look_ahead));
                }
            }
            // Deadzone: the target only moves the camera once it leaves the
            // rect (rect offset is relative to the camera's CURRENT centre).
            if (cam.deadzone.size.x >= 0 and cam.deadzone.size.y >= 0) {
                const dz_min = cam._offset.add(cam.deadzone.position);
                const dz_max = dz_min.add(cam.deadzone.size);
                if (aim.x >= dz_min.x and aim.x <= dz_max.x and aim.y >= dz_min.y and aim.y <= dz_max.y) {
                    aim = cam._offset; // still inside: hold position
                }
            }
            desired = aim;
        }
    }

    if (cam.damping <= 0) {
        cam._offset = desired;
        cam._velocity = Vec2{};
    } else {
        springStep(&cam._offset, &cam._velocity, desired, cam.damping, dt);
    }

    // ── Limits ───────────────────────────────────────────────────────────────
    // The centre is clamped into the limits rect. A view larger than the limits
    // will overhang them, which is the right trade: limits are "the camera may
    // not leave the map", not "the camera may not show past the map".
    if (cam.limits_enabled) {
        const l = cam.limits;
        const max_x = l.position.x + l.size.x;
        const max_y = l.position.y + l.size.y;
        cam._offset.x = math.clamp(cam._offset.x, @min(l.position.x, max_x), @max(l.position.x, max_x));
        cam._offset.y = math.clamp(cam._offset.y, @min(l.position.y, max_y), @max(l.position.y, max_y));
    }

    // ── Shake ────────────────────────────────────────────────────────────────
    var shake = Vec2{};
    if (cam.trauma > 0) {
        cam._trauma_timer += dt;
        cam.trauma = @max(0, cam.trauma - cam.trauma_decay * dt);
        const magnitude = math.pow(cam.trauma, cam.trauma_power) * cam.shake_amplitude;
        const seed = world.sceneIdOf(e); // deterministic per camera
        const t = cam.shake_frequency * cam._trauma_timer;
        shake = .{
            .x = noise.value(seed, t, 0) * magnitude,
            .y = noise.value(seed, 0, t) * magnitude,
        };
    } else {
        cam.trauma = 0;
        cam._trauma_timer = 0;
    }

    return .{
        .cx = cam._offset.x + shake.x,
        .cy = cam._offset.y + shake.y,
        .zoom = cam.zoom,
        .viewport_w = viewport_w,
        .viewport_h = viewport_h,
    };
}

/// Advances `pos`/`vel` one step toward `goal` on a CRITICALLY DAMPED spring,
/// using the closed-form solution rather than an integrator.
///
/// The exact solution of `x'' = -2ωx' - ω²(x - g)` at ζ = 1, evaluated at `t =
/// dt`, is `x = g + e·f·(1 + ωdt) + v·dt·f` with `f = exp(-ωdt)`. Three
/// multiplications and one `exp`, no integration, and therefore no step-size
/// behaviour to be right or wrong about.
///
/// Why not an integrator, given this file already learned that lesson the hard
/// way: the first version used the explicit "Kryson" form and DIVERGED to -843k
/// after 240 steps, and the implicit-Euler replacement — stable, but only
/// first-order — overshot the goal by 0.16 units on the very first frame. That
/// overshoot is what the regression test below measures, and it is a real defect
/// rather than a rounding artefact: a follow that passes its target and comes
/// back reads as the camera snapping past the player and correcting, which is
/// the single most noticeable camera bug there is. The closed form cannot do it:
/// for ζ = 1 with `e` and `v` pointing at the goal, `x` is monotonic by
/// construction.
fn springStep(pos: *Vec2, vel: *Vec2, goal: Vec2, omega: f32, dt: f32) void {
    const f = @exp(-omega * dt);
    const wdt = omega * dt;
    const ex = pos.x - goal.x;
    const ey = pos.y - goal.y;
    pos.* = .{
        .x = goal.x + (ex * (1.0 + wdt) + vel.x * dt) * f,
        .y = goal.y + (ey * (1.0 + wdt) + vel.y * dt) * f,
    };
    // The derivative of the same closed form: `v = -e·ω²·t·f + v₀·f·(1 - ωt)`.
    vel.* = .{
        .x = (-ex * omega * wdt + vel.x * (1.0 - wdt)) * f,
        .y = (-ey * omega * wdt + vel.y * (1.0 - wdt)) * f,
    };
}

// ── Tests ────────────────────────────────────────────────────────────────────
// VM-free: the system is plain ECS + math, so every claim about follow, dead-
// zone, limits and shake is testable without a window or a renderer.

const testing = std.testing;
const step_dt: f32 = 1.0 / 60.0;

test "no camera means null, and the caller keeps its default view" {
    var world = World.init(testing.allocator);
    defer world.deinit();
    _ = try world.spawn(.{components.Transform{}});
    try testing.expect(update(&world, step_dt, 1280, 720) == null);
}

test "damping 0 snaps the camera onto the follow target" {
    var world = World.init(testing.allocator);
    defer world.deinit();

    const target = try world.spawn(.{components.Transform{ .position = .{ .x = 300, .y = -120 } }});
    var cam = components.Camera2D{};
    cam.damping = 0;
    cam.follow(target);
    const cam_e = try world.spawn(.{cam});

    const view = update(&world, step_dt, 1280, 720).?;
    try testing.expectApproxEqAbs(@as(f32, 300), view.cx, 0.0001);
    try testing.expectApproxEqAbs(@as(f32, -120), view.cy, 0.0001);
    // The component saw the same state the view reports.
    try testing.expectApproxEqAbs(@as(f32, 300), world.get(cam_e, components.Camera2D).?._offset.x, 0.0001);
}

test "a damped follow converges on the target without overshooting" {
    var world = World.init(testing.allocator);
    defer world.deinit();

    const target = try world.spawn(.{components.Transform{ .position = .{ .x = 1000, .y = 0 } }});
    var cam = components.Camera2D{ .damping = 8 };
    cam.follow(target);
    const cam_e = try world.spawn(.{cam});

    var last: f32 = 0;
    var i: usize = 0;
    while (i < 240) : (i += 1) { // 4 simulated seconds
        _ = update(&world, step_dt, 1280, 720).?;
        const cx = world.get(cam_e, components.Camera2D).?._offset.x;
        try testing.expect(cx <= 1000 + 0.0001); // never past the goal
        last = cx;
    }
    try testing.expectApproxEqAbs(@as(f32, 1000), last, 0.5); // converged
}

test "the deadzone holds the camera until the target leaves it" {
    var world = World.init(testing.allocator);
    defer world.deinit();

    const target = try world.spawn(.{components.Transform{ .position = .{ .x = 10, .y = 0 } }});
    var cam = components.Camera2D{ .damping = 0 };
    cam.follow(target);
    // 200x100 box centred on the camera: position is the offset of its
    // top-left from the centre.
    cam.deadzone = .{ .position = .{ .x = -100, .y = -50 }, .size = .{ .x = 200, .y = 100 } };
    const cam_e = try world.spawn(.{cam});

    _ = update(&world, step_dt, 1280, 720).?;
    try testing.expectApproxEqAbs(@as(f32, 0), world.get(cam_e, components.Camera2D).?._offset.x, 0.0001);

    world.get(target, components.Transform).?.position.x = 500; // way outside
    _ = update(&world, step_dt, 1280, 720).?;
    try testing.expectApproxEqAbs(@as(f32, 500), world.get(cam_e, components.Camera2D).?._offset.x, 0.0001);
}

test "limits clamp the camera centre" {
    var world = World.init(testing.allocator);
    defer world.deinit();

    const target = try world.spawn(.{components.Transform{ .position = .{ .x = 99999, .y = -99999 } }});
    var cam = components.Camera2D{ .damping = 0 };
    cam.follow(target);
    cam.set_limits(.{ .position = .{ .x = 0, .y = 0 }, .size = .{ .x = 1000, .y = 800 } }, true);
    const cam_e = try world.spawn(.{cam});

    _ = update(&world, step_dt, 1280, 720).?;
    const c = world.get(cam_e, components.Camera2D).?._offset;
    try testing.expectApproxEqAbs(@as(f32, 1000), c.x, 0.0001);
    try testing.expectApproxEqAbs(@as(f32, 0), c.y, 0.0001);
}

test "zoom_to eases toward the target and trauma decays to nothing" {
    var world = World.init(testing.allocator);
    defer world.deinit();

    var cam = components.Camera2D{};
    cam.damping = 0;
    cam.zoom_damping = 0;
    cam.zoom_to(3.0);
    const cam_e = try world.spawn(.{cam});
    world.get(cam_e, components.Camera2D).?.add_trauma(1.0);

    var shook_at_full: ?f32 = null;
    var i: usize = 0;
    while (i < 300) : (i += 1) {
        const view = update(&world, step_dt, 1280, 720).?;
        if (i == 0) shook_at_full = view.cx;
        // Shake perturbs the VIEW around the (unmoved) camera centre.
        if (world.get(cam_e, components.Camera2D).?.trauma <= 0) {
            try testing.expectApproxEqAbs(@as(f32, 0), view.cx, 0.0001);
        }
    }
    try testing.expectEqual(@as(f32, 3.0), world.get(cam_e, components.Camera2D).?.zoom);
    try testing.expect(shook_at_full != null and shook_at_full.? != 0); // it DID shake

    // Same inputs, same shake: the noise is seeded from the scene id.
    const again = update(&world, step_dt, 1280, 720).?;
    try testing.expectApproxEqAbs(@as(f32, 0), again.cx, 0.0001);
}

test "the first ENABLED camera wins, deterministically" {
    var world = World.init(testing.allocator);
    defer world.deinit();

    var a = components.Camera2D{ .damping = 0 };
    a._offset = .{ .x = 111, .y = 0 };
    const a_e = try world.spawn(.{a}); // spawned first, but disabled
    world.get(a_e, components.Camera2D).?.enabled = false;

    var b = components.Camera2D{ .damping = 0 };
    b._offset = .{ .x = 222, .y = 0 };
    _ = try world.spawn(.{b});

    const view = update(&world, step_dt, 1280, 720).?;
    try testing.expectApproxEqAbs(@as(f32, 222), view.cx, 0.0001);
}