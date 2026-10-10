//! The fixed-step driver: the part of M4 that is OURS, not the solver's.
//!
//! spec §3.3 and §6 make three demands of this file, and all three are about
//! time rather than about physics:
//!
//! 1. **A fixed 60 Hz step.** Gameplay only ever sees `fixed_dt`. A variable step
//!    makes replay hashes meaningless, so the accumulator is drained in whole
//!    steps and the remainder is carried, never applied as a partial step.
//! 2. **At most one catch-up step per frame.** A slow frame must not trigger a
//!    death spiral: catching up "properly" is exactly what turns one 40 ms frame
//!    into forty 16 ms frames.
//! 3. **Physics → render interpolation.** The renderer draws between two fixed
//!    steps, so simulation and display are decoupled and a 144 Hz monitor shows
//!    the same 60 Hz motion smoothly rather than juddering.
//!
//! The accumulator is also where the "spiral" guard belongs: when a frame is so
//! late that the backlog exceeds the cap, the surplus is DROPPED, not carried.
//! Carrying it would guarantee the next frame is late too.

const std = @import("std");
const physics = @import("physics.zig");

pub const Driver = struct {
    world: physics.World,

    /// Unconsumed time from previous frames, in seconds.
    accumulator: f32 = 0.0,
    /// Whole fixed steps run since the driver was created.
    steps: u64 = 0,
    /// Steps dropped because the backlog exceeded the cap.
    dropped_steps: u32 = 0,

    /// Interpolate factor into the CURRENT step, 0..1, for the renderer.
    alpha: f32 = 0.0,

    /// Cumulative simulation time in ms, for the budget report.
    step_ms: f32 = 0.0,

    pub fn init(world: physics.World) Driver {
        return .{ .world = world };
    }

    /// Advances the simulation by `frame_dt` seconds of wall time.
    ///
    /// Returns how many fixed steps ran, so a caller (or a test) can assert on
    /// it rather than inferring it from the world.
    pub fn advance(self: *Driver, frame_dt: f32) u32 {
        // A negative or absurd dt is the caller's bug, but clamping is cheaper
        // than a spiral and keeps one bad frame from poisoning every one after.
        const dt = std.math.clamp(frame_dt, 0.0, 0.25);
        self.accumulator += dt;

        var ran: u32 = 0;
        while (self.accumulator >= physics.fixed_dt) {
            if (ran >= physics.max_catch_up_steps) {
                // The backlog is too deep to work through: drop it. This is the
                // whole point of the cap — carrying the surplus guarantees the
                // next frame is late as well.
                self.accumulator = 0.0;
                self.dropped_steps += 1;
                break;
            }
            self.world.step(physics.fixed_dt);
            self.accumulator -= physics.fixed_dt;
            self.steps += 1;
            ran += 1;
        }

        // Where the renderer draws: between the step just run and the next one.
        self.alpha = self.accumulator / physics.fixed_dt;
        return ran;
    }

    /// Fails fast when a caller bypasses the driver and hands the world a
    /// variable dt — the one mistake that would silently break every replay.
    pub fn assertFixed(self: *const Driver) void {
        std.debug.assert(self.accumulator >= 0.0 and self.accumulator < physics.fixed_dt);
    }
};

// ── Tests ────────────────────────────────────────────────────────────────────

const testing = std.testing;

/// A backend that does nothing, for testing the DRIVER's time handling without
/// a solver. Mirrors `render/backend_null.zig`: the point is that the contract is
/// exercisable headless.
const null_backend = struct {
    var steps: u32 = 0;
    var last_dt: f32 = 0.0;

    fn createWorld(g: physics.Gravity) ?*anyopaque {
        _ = g;
        steps = 0;
        last_dt = 0.0;
        return @ptrFromInt(1);
    }
    fn destroyWorld(ctx: *anyopaque) void {
        _ = ctx;
    }
    fn noopBody(ctx: *anyopaque, d: physics.BodyDesc) ?physics.BodyId {
        _ = ctx;
        _ = d;
        return .none;
    }
    // Each vtable slot has its own signature, so the shared no-ops are
    // declared per arity rather than through one variadic shape Zig lacks.
    fn nop0(ctx: *anyopaque) void {
        _ = ctx;
    }
    fn nopBodyId(ctx: *anyopaque, id: physics.BodyId) void {
        _ = ctx;
        _ = id;
    }
    fn nopShapeId(ctx: *anyopaque, id: physics.ShapeId) void {
        _ = ctx;
        _ = id;
    }
    fn nopBodyType(ctx: *anyopaque, id: physics.BodyId, t: physics.BodyType) void {
        _ = ctx;
        _ = id;
        _ = t;
    }
    fn nopXformSet(ctx: *anyopaque, id: physics.BodyId, xf: physics.Transform) void {
        _ = ctx;
        _ = id;
        _ = xf;
    }
    fn nopVelSet(ctx: *anyopaque, id: physics.BodyId, v: physics.Velocity) void {
        _ = ctx;
        _ = id;
        _ = v;
    }
    fn nopScale(ctx: *anyopaque, id: physics.BodyId, scale: f32) void {
        _ = ctx;
        _ = id;
        _ = scale;
    }
    fn nopAwake(ctx: *anyopaque, id: physics.BodyId, awake: bool) void {
        _ = ctx;
        _ = id;
        _ = awake;
    }
    fn nopShape(
        ctx: *anyopaque,
        body: physics.BodyId,
        shape: physics.Shape,
        mat: physics.Material,
    ) ?physics.ShapeId {
        _ = ctx;
        _ = body;
        _ = shape;
        _ = mat;
        return .none;
    }
    fn nopBody(ctx: *anyopaque, d: physics.BodyDesc) ?physics.BodyId {
        _ = ctx;
        _ = d;
        return .none;
    }
    fn nopXform(ctx: *anyopaque, id: physics.BodyId) physics.Transform {
        _ = ctx;
        _ = id;
        return .{};
    }
    fn nopVel(ctx: *anyopaque, id: physics.BodyId) physics.Velocity {
        _ = ctx;
        _ = id;
        return .{};
    }
    fn nopRay(
        ctx: *anyopaque,
        p1: physics.Vec2,
        p2: physics.Vec2,
        filter: physics.BodyType,
    ) ?physics.RayHit {
        _ = ctx;
        _ = p1;
        _ = p2;
        _ = filter;
        return null;
    }
    fn nopStats(ctx: *anyopaque) physics.StepStats {
        _ = ctx;
        return .{};
    }
    fn noopStep(ctx: *anyopaque, dt: f32) void {
        _ = ctx;
        steps += 1;
        last_dt = dt;
    }
    fn nopImpulse(ctx: *anyopaque, body: physics.BodyId, impulse: physics.Vec2, wake: bool) void {
        _ = ctx;
        _ = body;
        _ = impulse;
        _ = wake;
    }
    fn nopPollContacts(
        ctx: *anyopaque,
        visit: *const fn (user: *anyopaque, c: physics.Contact) void,
        user: *anyopaque,
    ) void {
        _ = ctx;
        _ = visit;
        _ = user;
    }
fn nopGetGravityScale(ctx: *anyopaque, body: physics.BodyId) f32 {
        _ = ctx;
        _ = body;
        return 1.0;
    }
fn nopSetEnabled(ctx: *anyopaque, body: physics.BodyId, enabled: bool) void {
        _ = ctx;
        _ = body;
        _ = enabled;
    }
    const vtable = physics.VTable{
        .createWorld = createWorld,
        .destroyWorld = destroyWorld,
        .createBody = nopBody,
        .destroyBody = nopBodyId,
        .setBodyType = nopBodyType,
        .setTransform = nopXformSet,
        .getTransform = nopXform,
        .setVelocity = nopVelSet,
        .getVelocity = nopVel,
        .setGravityScale = nopScale,
        .getGravityScale = nopGetGravityScale,
        .setAwake = nopAwake,
        .setEnabled = nopSetEnabled,
        .applyImpulse = nopImpulse,
        .createShape = nopShape,
        .destroyShape = nopShapeId,
        .step = noopStep,
        .castRay = nopRay,
        .stats = nopStats,
        .pollContacts = nopPollContacts,
    };
};

fn testDriver() Driver {
    return Driver.init(.{
        .vtable = &null_backend.vtable,
        .ctx = @ptrFromInt(1),
        .name = "null",
    });
}

test "one 60 Hz frame runs exactly one step" {
    var d = testDriver();
    try testing.expectEqual(@as(u32, 1), d.advance(1.0 / 60.0));
    try testing.expectApproxEqAbs(physics.fixed_dt, null_backend.last_dt, 1e-9);
}

test "a frame shorter than the step runs nothing and carries the remainder" {
    var d = testDriver();
    const before = null_backend.steps;
    try testing.expectEqual(@as(u32, 0), d.advance(physics.fixed_dt / 2.0));
    try testing.expectEqual(before, null_backend.steps);
    // Half a step carried, not discarded and not applied.
    try testing.expectApproxEqAbs(physics.fixed_dt / 2.0, d.accumulator, 1e-9);
    try testing.expectApproxEqAbs(@as(f32, 0.5), d.alpha, 1e-6);
}

test "accumulated partial steps eventually run one whole step" {
    var d = testDriver();
    const before = null_backend.steps;
    _ = d.advance(physics.fixed_dt / 4.0);
    _ = d.advance(physics.fixed_dt / 4.0);
    _ = d.advance(physics.fixed_dt / 4.0);
    _ = d.advance(physics.fixed_dt / 4.0);
    try testing.expectEqual(before + 1, null_backend.steps);
}

test "a very slow frame runs at most one step, never a spiral" {
    // 250 ms is a quarter second: sixteen fixed steps' worth. Running them all
    // is precisely the death spiral spec §3.3 forbids.
    var d = testDriver();
    const before = null_backend.steps;
    try testing.expectEqual(@as(u32, 1), d.advance(0.25));
    try testing.expectEqual(before + 1, null_backend.steps);
    // The surplus is dropped, not carried into the next frame.
    try testing.expectEqual(@as(f32, 0.0), d.accumulator);
    try testing.expect(d.dropped_steps > 0);
}

test "a negative frame time is clamped, not accumulated backwards" {
    var d = testDriver();
    const before = null_backend.steps;
    try testing.expectEqual(@as(u32, 0), d.advance(-1.0));
    try testing.expect(d.accumulator >= 0.0);
    try testing.expectEqual(before, null_backend.steps);
}

test "the sequence of steps is identical for identical frame times" {
    // The determinism contract (spec §6) at the driver's level: same frames in,
    // same steps out. Nothing here depends on a solver, so this is the part
    // that must hold no matter which backend is plugged in.
    const frames = [_]f32{ 0.016, 0.017, 0.016, 0.033, 0.008, 0.016, 0.016 };

    var a = testDriver();
    var b = testDriver();
    for (frames) |f| _ = a.advance(f);

    null_backend.steps = 0;
    for (frames) |f| _ = b.advance(f);

    try testing.expectEqual(a.steps, b.steps);
    try testing.expectApproxEqAbs(a.accumulator, b.accumulator, 1e-9);
}
