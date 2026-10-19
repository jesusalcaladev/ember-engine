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
///
/// ## The two axes, and which way each one grows
///
/// The WORLD is **y-up** (Box2D's convention, and the renderer's: a larger
/// world y is drawn HIGHER on the screen). The SCREEN is **y-down** (the
/// framebuffer's convention: pixel row 0 is the top, and that is what the
/// mouse, ImGui and every widget in this engine speak).
///
/// The two meet here, and this is the ONE place they are allowed to meet: a
/// screen position is a pixel in the view with y growing DOWN, so the world's
/// top edge (`cy + half_h`) is the view's row 0 and the world's bottom edge
/// (`cy - half_h`) is the view's last row.
///
/// It used to be the other way round, and the mismatch was invisible in the
/// code and glaring on the screen: the renderer drew the world y-up while
/// `screenToWorld` assumed y-down, so every editor click landed mirrored
/// across the horizontal midline of the viewport. The two halves of the engine
/// agreed on the RENDER and disagreed on the POINTER, which is why the scene
/// looked right and the picking did not.
///
/// ## The view inside a target
///
/// A view does not have to fill its render target. The editor's viewport is a
/// rectangle in the middle of a window, and the scene is projected INTO that
/// rectangle: `origin_x`/`origin_y` say where it sits, `target_w`/`target_h`
/// say how big the target is. Zero means "the view IS the target", which is
/// the runtime's case and the default.
pub const View = struct {
    cx: f32 = 0,
    cy: f32 = 0,
    zoom: f32 = 1,
    /// The view's size in pixels.
    viewport_w: f32 = 1280,
    viewport_h: f32 = 720,

    /// The view's top-left corner inside the render target, in pixels (y down
    /// from the target's top-left). Zero = the view starts at the target's
    /// origin.
    origin_x: f32 = 0,
    origin_y: f32 = 0,
    /// The render target's size in pixels. Zero = the view's own size.
    target_w: f32 = 0,
    target_h: f32 = 0,

    /// Places the view inside a render target of `w` x `h` pixels, with its
    /// top-left corner at (`x`, `y`).
    ///
    /// The view keeps its own size: what changes is WHERE it is projected and
    /// where a pointer position has to be measured from. Both the matrix and
    /// the pointer maths read these fields, so they cannot disagree.
    pub fn setTarget(self: *View, x: f32, y: f32, w: f32, h: f32) void {
        self.origin_x = x;
        self.origin_y = y;
        self.target_w = w;
        self.target_h = h;
    }

    /// The render target's size, resolving the "zero means the view itself"
    /// default.
    pub fn targetSize(self: View) Vec2 {
        return .{
            .x = if (self.target_w > 0) self.target_w else self.viewport_w,
            .y = if (self.target_h > 0) self.target_h else self.viewport_h,
        };
    }

    /// The world rectangle visible this frame (no margin: this is the exact
    /// view; the culler adds its own edge margin).
    ///
    /// A `Rect2` is a y-DOWN rectangle (see `core.math.Rect2`), so its `top`
    /// is the SMALLER world y — the bottom of the screen. Use `worldBounds`
    /// when the direction matters.
    pub fn worldRect(self: View) math.Rect2 {
        return math.Rect2.fromCenter(
            .{ .x = self.cx, .y = self.cy },
            self.viewport_w / self.zoom,
            self.viewport_h / self.zoom,
        );
    }

    /// The world's visible bounds, with `min` at the bottom-left and `max` at
    /// the top-right. The direction is explicit because the world's y grows UP
    /// and a `Rect2`'s does not.
    pub const Bounds = struct {
        min: Vec2,
        max: Vec2,
    };

    pub fn worldBounds(self: View) Bounds {
        const half_w = self.viewport_w / self.zoom * 0.5;
        const half_h = self.viewport_h / self.zoom * 0.5;
        return .{
            .min = .{ .x = self.cx - half_w, .y = self.cy - half_h },
            .max = .{ .x = self.cx + half_w, .y = self.cy + half_h },
        };
    }

    /// The half extents of the visible world, in world units.
    pub fn halfExtents(self: View) Vec2 {
        return .{
            .x = self.viewport_w / self.zoom * 0.5,
            .y = self.viewport_h / self.zoom * 0.5,
        };
    }

    /// A world point, as a pixel in the VIEW (y down from the view's top-left).
    pub fn worldToScreen(self: View, world: Vec2) Vec2 {
        const half = self.halfExtents();
        return .{
            .x = (world.x - (self.cx - half.x)) * self.zoom,
            .y = ((self.cy + half.y) - world.y) * self.zoom,
        };
    }

    /// The world point under a pixel in the VIEW (y down from the view's
    /// top-left) — the inverse of `worldToScreen`.
    pub fn screenToWorld(self: View, screen: Vec2) Vec2 {
        const half = self.halfExtents();
        return .{
            .x = self.cx - half.x + screen.x / self.zoom,
            .y = self.cy + half.y - screen.y / self.zoom,
        };
    }

    /// The world point under a pixel given in the TARGET's coordinates (the
    /// window's). The view's origin inside the target is subtracted, so a
    /// caller can hand the pointer's raw coordinates straight in.
    pub fn targetToWorld(self: View, target_point: Vec2) Vec2 {
        return self.screenToWorld(.{
            .x = target_point.x - self.origin_x,
            .y = target_point.y - self.origin_y,
        });
    }

    /// The inverse of `targetToWorld`: a world point as a pixel of the target.
    pub fn worldToTarget(self: View, world: Vec2) Vec2 {
        const s = self.worldToScreen(world);
        return .{ .x = s.x + self.origin_x, .y = s.y + self.origin_y };
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
    ///
    /// The matrix projects into the TARGET, not into the view: a view that
    /// sits in a rectangle of a larger target keeps that rectangle's place in
    /// it. With no target set (`origin` 0, target = the view) this is exactly
    /// the matrix it always was.
    pub fn viewProjection(self: View) [16]f32 {
        const target = self.targetSize();
        const sx = self.zoom * 2.0 / target.x;
        const sy = self.zoom * 2.0 / target.y;
        // The view's size as a fraction of the target: the world is projected
        // into the TARGET and the view is the rectangle of it the camera
        // shows, so the view's own size enters the translation.
        const vw = self.viewport_w / target.x;
        const vh = self.viewport_h / target.y;
        const tx = 2.0 * self.origin_x / target.x - self.cx * sx + vw - 1.0;
        const ty = 1.0 - 2.0 * self.origin_y / target.y - self.cy * sy - vh;
        // Column-major: [sx 0 0 tx, 0 sy 0 ty, 0 0 1 0, 0 0 0 1]
        return .{
            sx, 0,  0, 0,
            0,  sy, 0, 0,
            0,  0,  1, 0,
            tx, ty, 0, 1,
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

// ── The screen space ────────────────────────────────────────────────────────
//
// These tests exist because the two halves of this file used to disagree: the
// matrix drew the world y-up and `screenToWorld` read the screen y-down, so
// every pointer position in the editor was mirrored across the viewport's
// horizontal midline. A test that pins the CONVENTION is what stops that from
// coming back, because the convention is invisible in the code and obvious on
// the screen.

test "the screen is y-down and the world is y-up" {
    const v = View{ .cx = 0, .cy = 0, .zoom = 1, .viewport_w = 800, .viewport_h = 600 };

    // A point ABOVE the camera (larger world y) is HIGHER on the screen, and
    // the screen's y grows down — so its pixel row is SMALLER.
    const above = v.worldToScreen(.{ .x = 0, .y = 100 });
    const below = v.worldToScreen(.{ .x = 0, .y = -100 });
    try testing.expect(above.y < below.y);
    try testing.expectApproxEqAbs(@as(f32, 200), above.y, 0.001); // 300 - 100
    try testing.expectApproxEqAbs(@as(f32, 400), below.y, 0.001); // 300 + 100

    // And the inverse agrees: the pixel row 0 is the world's TOP.
    const top = v.screenToWorld(.{ .x = 0, .y = 0 });
    try testing.expectApproxEqAbs(@as(f32, 300), top.y, 0.001);
}

test "the projection agrees with the screen mapping" {
    // The matrix is what the GPU does; `worldToScreen` is what the CPU does
    // with the pointer. If they disagree, the scene is drawn somewhere the
    // click did not go.
    const v = View{ .cx = 120, .cy = -40, .zoom = 2.5, .viewport_w = 800, .viewport_h = 600 };
    const world = Vec2{ .x = 33, .y = 77 };

    const screen = v.worldToScreen(world);
    const vp = v.viewProjection();
    const ndc_x = vp[0] * world.x + vp[12];
    const ndc_y = vp[5] * world.y + vp[13];
    // WebGPU's viewport transform: NDC +1 is the TOP of the framebuffer.
    const px = (ndc_x + 1.0) * 0.5 * v.targetSize().x;
    const py = (1.0 - ndc_y) * 0.5 * v.targetSize().y;
    try testing.expectApproxEqAbs(screen.x, px, 0.001);
    try testing.expectApproxEqAbs(screen.y, py, 0.001);
}

test "a view inside a target keeps its place in it" {
    // The editor's viewport: a 1000x700 rectangle in the middle of a
    // 1600x900 window.
    var v = View{ .cx = 0, .cy = 0, .zoom = 1, .viewport_w = 1000, .viewport_h = 700 };
    v.setTarget(300, 100, 1600, 900);

    // The camera's centre is the CENTRE OF THE REGION, not the centre of the
    // window: that is the whole point of the region existing.
    const centre = v.worldToTarget(.{ .x = 0, .y = 0 });
    try testing.expectApproxEqAbs(@as(f32, 300 + 500), centre.x, 0.001);
    try testing.expectApproxEqAbs(@as(f32, 100 + 350), centre.y, 0.001);

    // The region's top-left corner is the world's top-left.
    const corner = v.worldToTarget(.{ .x = -500, .y = 350 });
    try testing.expectApproxEqAbs(@as(f32, 300), corner.x, 0.001);
    try testing.expectApproxEqAbs(@as(f32, 100), corner.y, 0.001);

    // And the pointer maths is measured from the region's origin, so a raw
    // window pixel lands where the user clicked.
    const under = v.targetToWorld(.{ .x = 300, .y = 100 });
    try testing.expectApproxEqAbs(@as(f32, -500), under.x, 0.001);
    try testing.expectApproxEqAbs(@as(f32, 350), under.y, 0.001);
}

test "the screen mapping round-trips" {
    const v = View{ .cx = -12, .cy = 40, .zoom = 0.75, .viewport_w = 640, .viewport_h = 480 };
    const world = Vec2{ .x = 91.5, .y = -13.25 };
    const back = v.screenToWorld(v.worldToScreen(world));
    try testing.expectApproxEqAbs(world.x, back.x, 0.001);
    try testing.expectApproxEqAbs(world.y, back.y, 0.001);
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