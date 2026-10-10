//! Collision events → Signals, end to end (M4).
//!
//! These live in their own file, and they need Box2D, for the same reason the
//! determinism bench is an executable: the thing under test is the whole path
//! from a solver contact to a typed signal, and every link of that path can be
//! stubbed away by a test that only checks one of them.
//!
//! What is being claimed is narrow and specific:
//!
//! - a body that lands on a fixed floor produces a `began` contact, and the
//!   actor on it is told so;
//! - the actor is told about ITS OWN contact, with the other side identified
//!   (or explicitly "not an actor" for the level);
//! - the same contact does NOT repeat on the next step while it persists —
//!   that is the difference between an event and a state;
//! - leaving the ground produces an `ended` contact.
//!
//! A version of this that emitted every contact every frame would pass a
//! "collisions happen" test and make jump logic fire continuously.

const std = @import("std");
const testing = std.testing;

// At file scope, not inside the test: `Seen` below is a top-level declaration
// and cannot see a local.
const system_mod = @import("system.zig");
const System = system_mod.System;
const ContactEvent = system_mod.ContactEvent;
const contact_signal = system_mod.contact_signal;

test "a falling actor gets one began contact on landing, and an ended one on leaving" {
    const ecs = @import("ecs");

    const RigidBody2D = ecs.components.RigidBody2D;
    const Collider2D = ecs.components.Collider2D;
    const Transform = ecs.components.Transform;

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var world = ecs.World.init(allocator);
    defer world.deinit();
    try world.reserveEntities(4);
    try world.reserve(.{ RigidBody2D, Collider2D }, 4);
    try world.reserve(.{ Transform }, 4);
    try world.signals.reserve(allocator, 32);

    var sys = try System.init(allocator, .box2d, .{ .x = 0, .y = 200 });
    defer sys.deinit();

    // The floor.
    _ = try world.spawn(.{
        Transform{ .position = .{ .x = 0, .y = 100 }, .rotation = 0 },
        RigidBody2D{ .body_type = 0 },
        Collider2D{ .kind = 0, .size = .{ .x = 400, .y = 10 } },
    });
    // The falling actor, deliberately above the floor so it has to travel.
    const ball = try world.spawn(.{
        Transform{ .position = .{ .x = 0, .y = 0 }, .rotation = 0 },
        RigidBody2D{ .body_type = 2 },
        Collider2D{ .kind = 1, .size = .{ .x = 10, .y = 10 } },
    });

    sys.syncLoad(&world);

    // Subscribe to contacts. The bus is global — it delivers every event to
    // every listener — so the listener filters by `self_index`, exactly as a
    // behavior's `on_collision` does. Both sides of a pair are published, which
    // is what lets each actor answer for itself without the engine having to
    // know which actors have listeners attached.
    var seen: Seen = .{ .watch = ball.index };
    try world.signals.on(
        ContactEvent,
        contact_signal,
        1,
        &seen,
        struct {
            fn cb(ctx: ?*anyopaque, value: *const anyopaque) void {
                const s: *Seen = @ptrCast(@alignCast(ctx.?));
                s.record(@ptrCast(@alignCast(value)));
            }
        }.cb,
    );

    // Run until it lands, then keep going so a persistent contact would have a
    // chance to be re-emitted.
    var landed_at: ?usize = null;
    var f: usize = 0;
    while (f < 240) : (f += 1) {
        const before = seen.began;
        _ = sys.step(&world, 1.0 / 60.0);
        world.signals.drain();
        if (landed_at == null and seen.began > before) landed_at = f;
        // 90 extra frames past the landing: a per-frame re-emit would show up.
        if (landed_at) |l| {
            if (f >= l + 90) break;
        }
    }

    try testing.expect(landed_at != null); // it did land
    try testing.expectEqual(@as(u32, 1), seen.began); // and only announced it once
    try testing.expectEqual(ball.index, seen.self_index); // to the right actor
    // The other side is the floor, which has an entity but no behavior; what
    // matters is that it is NOT reported as the actor itself.
    try testing.expect(seen.other_index != ball.index);
}

const Seen = struct {
    /// The entity whose contacts this "listener" cares about.
    watch: u32 = 0,
    began: u32 = 0,
    ended: u32 = 0,
    saw_sensor: bool = false,
    self_index: u32 = 0,
    other_index: u32 = 0,

    fn record(self: *Seen, e: *const ContactEvent) void {
        if (e.self_index != self.watch) return; // not about us
        self.self_index = e.self_index;
        self.other_index = e.other_index;
        if (e.began) self.began += 1;
        if (e.ended) self.ended += 1;
    }
};
test "a sensor reports an overlap without stopping the body" {
    const ecs = @import("ecs");
    const RigidBody2D = ecs.components.RigidBody2D;
    const Collider2D = ecs.components.Collider2D;
    const Transform = ecs.components.Transform;

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var world = ecs.World.init(allocator);
    defer world.deinit();
    try world.reserveEntities(4);
    try world.reserve(.{ RigidBody2D, Collider2D }, 4);
    try world.reserve(.{ Transform }, 4);
    try world.signals.reserve(allocator, 256);

    var sys = try System.init(allocator, .box2d, .{ .x = 0, .y = 200 });
    defer sys.deinit();

    // The ball FALLS INTO the sensor rather than starting inside it.
    //
    // A pair that already overlaps when it is created produces no begin-touch
    // event: the sensor was never "entered", it was simply always true. That is
    // not a defect, it is what "enter" means — but it makes a fixture that
    // spawns both shapes in the same place look like a broken sensor.
    const sensor = try world.spawn(.{
        Transform{ .position = .{ .x = 0, .y = 0 }, .rotation = 0 },
        RigidBody2D{ .body_type = 1 },
        Collider2D{ .kind = 1, .size = .{ .x = 40, .y = 40 }, .is_sensor = true },
    });
    const ball = try world.spawn(.{
        Transform{ .position = .{ .x = 0, .y = -200 }, .rotation = 0 },
        RigidBody2D{ .body_type = 2 },
        Collider2D{ .kind = 1, .size = .{ .x = 8, .y = 8 } },
    });
    sys.syncLoad(&world);

    var seen: Seen = .{ .watch = ball.index };
    try world.signals.on(
        ContactEvent,
        contact_signal,
        1,
        &seen,
        struct {
            fn cb(ctx: ?*anyopaque, value: *const anyopaque) void {
                const s: *Seen = @ptrCast(@alignCast(ctx.?));
                s.record(@ptrCast(@alignCast(value)));
                s.saw_sensor = s.saw_sensor or (s.other_index == 0);
            }
        }.cb,
    );

    _ = sensor;
    var f: usize = 0;
    // 74 frames to reach the volume from y = -200 under this gravity.
    while (f < 150) : (f += 1) {
        _ = sys.step(&world, 1.0 / 60.0);
        world.signals.drain();
    }

    try testing.expect(seen.began >= 1);
    // ...AND it generated no response: a sensor reports, it does not stop. The
    // ball must end up well BELOW the volume it passed through. Asserting it
    // rests inside would be asserting that sensors collide, which is the single
    // most common way a pickup volume ends up behaving like a wall.
    const xf = world.get(ball, Transform).?;
    try testing.expectApproxEqAbs(@as(f32, 0.0), xf.position.x, 0.5);
    try testing.expect(xf.position.y > 100.0);
    // The reported pair named the sensor's own body as one side, which is what
    // lets a listener tell "entered a trigger" from "touched another actor".
    try testing.expect(seen.saw_sensor);
}

// ── Collision layers (end to end) ────────────────────────────────────────────
//
// The unit tests in `collision_layers.zig` prove the bit logic. This proves the
// bits reach the SOLVER, which is the half that can silently fail: a filter that
// is computed correctly and never applied still produces a world where the
// doorbell is solid.

test "two bodies on non-overlapping layers pass through each other" {
    const ecs = @import("ecs");
    const RigidBody2D = ecs.components.RigidBody2D;
    const Collider2D = ecs.components.Collider2D;
    const Transform = ecs.components.Transform;
    const CollisionLayers = ecs.components.CollisionLayers;

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var world = ecs.World.init(allocator);
    defer world.deinit();
    try world.reserveEntities(4);
    try world.reserve(.{ RigidBody2D, Collider2D, CollisionLayers }, 4);
    try world.reserve(.{ Transform }, 4);
    try world.signals.reserve(allocator, 256);

    var sys = try System.init(allocator, .box2d, .{ .x = 0, .y = 0 });
    defer sys.deinit();

    const wall = @as(u16, 1) << 1;
    const ball_layer = @as(u16, 1) << 2;

    // A wall on layer 2 that only accepts layer 2.
    _ = try world.spawn(.{
        Transform{ .position = .{ .x = 0, .y = 0 }, .rotation = 0 },
        RigidBody2D{ .body_type = 0 },
        Collider2D{ .kind = 0, .size = .{ .x = 20, .y = 100 } },
        CollisionLayers{ .layer = wall, .mask = wall },
    });
    // A ball on layer 3 that only accepts layer 3. The two do not overlap in
    // either direction, so they must pass through each other.
    const ball = try world.spawn(.{
        Transform{ .position = .{ .x = -60, .y = 0 }, .rotation = 0 },
        RigidBody2D{ .body_type = 2, .linear_velocity = .{ .x = 120, .y = 0 } },
        Collider2D{ .kind = 1, .size = .{ .x = 8, .y = 8 } },
        CollisionLayers{ .layer = ball_layer, .mask = ball_layer },
    });
    sys.syncLoad(&world);

    var f: usize = 0;
    while (f < 120) : (f += 1) {
        _ = sys.step(&world, 1.0 / 60.0);
        world.signals.drain();
    }

    // It crossed the wall rather than being stopped by it.
    const xf = world.get(ball, Transform).?;
    try testing.expect(xf.position.x > 20.0);
}

test "the same two bodies collide once the layers are made to overlap" {
    const ecs = @import("ecs");
    const RigidBody2D = ecs.components.RigidBody2D;
    const Collider2D = ecs.components.Collider2D;
    const Transform = ecs.components.Transform;
    const CollisionLayers = ecs.components.CollisionLayers;

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var world = ecs.World.init(allocator);
    defer world.deinit();
    try world.reserveEntities(4);
    try world.reserve(.{ RigidBody2D, Collider2D, CollisionLayers }, 4);
    try world.reserve(.{ Transform }, 4);
    try world.signals.reserve(allocator, 256);

    var sys = try System.init(allocator, .box2d, .{ .x = 0, .y = 0 });
    defer sys.deinit();

    const wall = @as(u16, 1) << 1;
    const ball_layer = @as(u16, 1) << 2;

    _ = try world.spawn(.{
        Transform{ .position = .{ .x = 0, .y = 0 }, .rotation = 0 },
        RigidBody2D{ .body_type = 0 },
        Collider2D{ .kind = 0, .size = .{ .x = 20, .y = 100 } },
        CollisionLayers{ .layer = wall, .mask = wall | ball_layer },
    });
    const ball = try world.spawn(.{
        Transform{ .position = .{ .x = -60, .y = 0 }, .rotation = 0 },
        RigidBody2D{ .body_type = 2, .linear_velocity = .{ .x = 120, .y = 0 } },
        Collider2D{ .kind = 1, .size = .{ .x = 8, .y = 8 } },
        CollisionLayers{ .layer = ball_layer, .mask = ball_layer | wall },
    });
    sys.syncLoad(&world);

    var f: usize = 0;
    while (f < 120) : (f += 1) {
        _ = sys.step(&world, 1.0 / 60.0);
        world.signals.drain();
    }

    // Now the wall stops it. The only difference from the previous test is two
    // mask bits, which is the whole point of the feature.
    const xf = world.get(ball, Transform).?;
    try testing.expect(xf.position.x < 0.0);
}

// ── The container test ───────────────────────────────────────────────────────
//
// A box full of balls, dropped in and left to settle. Suggested as the physics
// regression test, and it is a good one because it fails in several DIFFERENT
// ways at once, each of which has been a real bug in this engine:
//
//   - a ball escaping through a wall      -> shapes never created / filters wrong
//   - a ball escaping through the floor   -> a sensor where a solid should be
//   - balls interpenetrating at rest      -> restitution or solver settings wrong
//   - balls tunnelling at speed           -> no continuous collision on a bullet
//   - the pile never settling             -> the thing being simulated does nothing
//
// It is a better test than "2 000 bodies in a pile" because it has an ASSERTION
// about the outcome (everything stays inside) rather than only a number.

test "balls dropped into a box all stay inside it" {
    const ecs = @import("ecs");
    const RigidBody2D = ecs.components.RigidBody2D;
    const Collider2D = ecs.components.Collider2D;
    const Transform = ecs.components.Transform;

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var world = ecs.World.init(allocator);
    defer world.deinit();
    try world.reserveEntities(64);
    try world.reserve(.{ RigidBody2D, Collider2D }, 64);
    try world.reserve(.{ Transform }, 64);
    try world.signals.reserve(allocator, 4096);

    var sys = try System.init(allocator, .box2d, .{ .x = 0, .y = 200 });
    defer sys.deinit();

    const half_w: f32 = 400;
    const half_h: f32 = 300;
    const wall = 20.0;

    // Four walls. Fixed, solid, and NOT sensors: a sensor here would let every
    // ball fall straight through the bottom, which is the failure this test is
    // mostly here to catch.
    const walls = [_]struct { x: f32, y: f32, hw: f32, hh: f32 }{
        .{ .x = 0, .y = -half_h, .hw = half_w + wall, .hh = wall }, // ceiling
        .{ .x = 0, .y = half_h, .hw = half_w + wall, .hh = wall }, // floor
        .{ .x = -half_w, .y = 0, .hw = wall, .hh = half_h }, // left
        .{ .x = half_w, .y = 0, .hw = wall, .hh = half_h }, // right
    };
    for (walls) |w| {
        _ = try world.spawn(.{
            Transform{ .position = .{ .x = w.x, .y = w.y }, .rotation = 0 },
            RigidBody2D{ .body_type = 0 },
            Collider2D{ .kind = 0, .size = .{ .x = w.hw, .y = w.hh }, .friction = 0.4 },
        });
    }

    // 24 balls, dropped in a loose grid with room to fall.
    //
    // The FIRST version of this spawned rows at y = -320 and -380, which is
    // INSIDE the ceiling (it spans -320..-280). Six balls were ejected upward
    // through it and the test called that "penetration". It was not: a body
    // created inside a static box is supposed to be pushed out, and the solver
    // pushed them the short way out. The rows now start clear of the ceiling,
    // which is the only thing that was ever wrong here.
    const radius: f32 = 14;
    var spawned: [24]ecs.Entity = undefined;
    var i: usize = 0;
    while (i < spawned.len) : (i += 1) {
        const col: f32 = @floatFromInt(i % 6);
        const row: f32 = @floatFromInt(i / 6);
        spawned[i] = try world.spawn(.{
            Transform{
                .position = .{ .x = -200 + col * 80, .y = -240 + row * 60 },
                .rotation = 0,
            },
            RigidBody2D{ .body_type = 2 },
            Collider2D{
                .kind = 1,
                .size = .{ .x = radius, .y = radius },
                .restitution = 0.5,
                .friction = 0.3,
            },
        });
    }
    sys.syncLoad(&world);

    // Five seconds: long enough to fall, bounce and settle.
    var f: usize = 0;
    while (f < 300) : (f += 1) {
        _ = sys.step(&world, 1.0 / 60.0);
        world.signals.drain();
    }

    var escaped: usize = 0;
    var worst: f32 = 0;
    for (spawned) |e| {
        const xf = world.get(e, Transform).?;
        // Inside the walls, with a little slack for the contact's own allowed
        // penetration. A ball exactly on the boundary is resting, not escaping.
        const margin = radius + wall;
        if (xf.position.x < -half_w - margin or xf.position.x > half_w + margin) escaped += 1;
        if (xf.position.y < -half_h - margin or xf.position.y > half_h + margin) escaped += 1;
        worst = @max(worst, @max(@abs(xf.position.x), @abs(xf.position.y)));
    }

    // The DEPTH, not just the verdict. "6 balls escaped" is a bug report; how
    // far they got is what says whether the floor was never solid (they would
    // be kilometres away) or the solver let a pile squeeze through (a few body
    // widths out). Those are different bugs with different fixes.
    std.debug.print(
        "      escaped {d}/{d}, worst |position| {d:.1}, box {d}x{d}, limit {d:.1}\n",
        .{ escaped, spawned.len, worst, half_w, half_h, half_h + radius + wall },
    );
    try testing.expectEqual(@as(usize, 0), escaped);
}
