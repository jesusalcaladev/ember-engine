//! Physics debug visualization (the editor's collision overlay).
//!
//! This does NOT draw. It COLLECTS: it walks the ECS for every live collider,
//! asks the physics world where that body actually is, and emits a colour-coded
//! quad for each one. The caller — the editor — draws them, which keeps this
//! module free of a dependency on the renderer (physics must not import render:
//! render imports physics, and that edge is one-way by construction).
//!
//! ## Why quads and not wireframes
//!
//! The renderer's only per-instance primitive is a textured quad, and a filled
//! semi-transparent quad reads better than an outline when a hundred bodies
//! overlap: the tint shows what is solid and what is a trigger at a glance.
//! A wireframe pass is a separate feature, not a missing one.
//!
//! ## Colour semantics
//!
//! One colour per body class, because the question the overlay answers is "what
//! is this thing and will it push me":
//!   * static    green    an immovable wall
//!   * kinematic cyan     moved by code, pushes dynamic bodies
//!   * dynamic    orange   moved by the solver
//!   * sensor     blue     overlaps but never pushes
//! A sensor's colour wins over its body type: a dynamic trigger is far more
//! common than a static one, and its trigger-ness is the surprising part.

const std = @import("std");
const ecs = @import("ecs");
const physics = @import("physics.zig");

const RigidBody2D = ecs.components.RigidBody2D;
const Collider2D = ecs.components.Collider2D;
const Transform = ecs.components.Transform;

/// Which classes of shape the overlay draws, as a bitmask.
///
/// A bitmask rather than a set of bools because the editor round-trips it
/// through Lua (`physics.debug_flags(mask)`) and a single integer survives that
/// round trip with no table construction per frame.
pub const DebugFlags = struct {
    pub const solid_static: u32 = 1 << 0;
    pub const solid_kinematic: u32 = 1 << 1;
    pub const solid_dynamic: u32 = 1 << 2;
    pub const sensor_shapes: u32 = 1 << 3;
    pub const one_way_shapes: u32 = 1 << 4;
    pub const tilemap_shapes: u32 = 1 << 5;
    pub const shape_aabbs: u32 = 1 << 6;
    pub const contacts: u32 = 1 << 7;
    pub const center_of_mass: u32 = 1 << 8;

    /// What the editor turns on by default: every body class, the AABBs, the
    /// contacts and the centre of mass. Everything except the two flags that
    /// are only meaningful for a tilemap scene (`tilemap_shapes`) or a level
    /// with one-way platforms (`one_way_shapes`), which a fresh scene has none
    /// of anyway but which are harmless to include.
    pub const EDITOR_DEFAULT: u32 = solid_static |
        solid_kinematic |
        solid_dynamic |
        sensor_shapes |
        one_way_shapes |
        tilemap_shapes |
        shape_aabbs |
        contacts |
        center_of_mass;
};

/// The RGBA palette, unorm8 so it drops straight into a `SpriteInstance.color`.
///
/// Alpha is deliberately low (120/255): the overlay must never hide the sprite
/// it is debugging. The two full-alpha colours (contact, com) are points and
/// dots rather than areas, so they can afford to be opaque.
pub const DebugColors = struct {
    pub const solid_static = [4]u8{ 0, 200, 0, 120 }; // green
    pub const solid_kinematic = [4]u8{ 0, 200, 200, 120 }; // cyan
    pub const solid_dynamic = [4]u8{ 255, 140, 0, 120 }; // orange
    pub const sensor = [4]u8{ 0, 100, 255, 120 }; // blue
    pub const one_way = [4]u8{ 255, 220, 0, 120 }; // yellow
    pub const tilemap_solid = [4]u8{ 0, 140, 0, 120 }; // dark green
    pub const tilemap_sensor = [4]u8{ 0, 80, 200, 120 }; // dark blue
    pub const contact = [4]u8{ 255, 0, 255, 200 }; // magenta
    pub const com = [4]u8{ 255, 0, 0, 200 }; // red
    pub const aabb = [4]u8{ 200, 200, 200, 80 }; // grey
};

/// A colour override set, so a project (or a test) can re-tint the overlay
/// without recompiling the palette. Defaults to `DebugColors`.
pub const DebugColorSet = struct {
    solid_static: [4]u8 = DebugColors.solid_static,
    solid_kinematic: [4]u8 = DebugColors.solid_kinematic,
    solid_dynamic: [4]u8 = DebugColors.solid_dynamic,
    sensor: [4]u8 = DebugColors.sensor,
    one_way: [4]u8 = DebugColors.one_way,
    tilemap_solid: [4]u8 = DebugColors.tilemap_solid,
    tilemap_sensor: [4]u8 = DebugColors.tilemap_sensor,
    contact: [4]u8 = DebugColors.contact,
    com: [4]u8 = DebugColors.com,
    aabb: [4]u8 = DebugColors.aabb,
};

/// One axis-aligned quad to draw, in world units. `half` are half-extents.
pub const DebugQuad = struct {
    pos: [2]f32,
    half: [2]f32,
    color: [4]u8,
};

/// What the last `collect` produced, so the editor can show counts.
pub const Stats = struct {
    bodies_drawn: u32 = 0,
    sensors_drawn: u32 = 0,
    overflowed: u32 = 0,
};

pub const PhysicsDebugRenderer = struct {
    allocator: std.mem.Allocator,
    /// Reused across frames: `collect` keeps the capacity, so a frame with the
    /// same or fewer bodies allocates nothing.
    quads: std.ArrayListUnmanaged(DebugQuad) = .empty,
    /// Whether the overlay is drawn at all. The flags say WHAT to draw; this
    /// says WHETHER to draw anything, and it is what a script toggles.
    enabled: bool = true,
    flags: u32 = DebugFlags.EDITOR_DEFAULT,
    colors: DebugColorSet = .{},
    stats: Stats = .{},

    pub fn init(allocator: std.mem.Allocator) PhysicsDebugRenderer {
        return .{ .allocator = allocator };
    }

    pub fn deinit(self: *PhysicsDebugRenderer) void {
        self.quads.deinit(self.allocator);
        self.quads = .empty;
        self.stats = .{};
    }

    /// Reserves room for `n` quads before the frame, the way every other render
    /// path does (spec §3.1: the frame loop itself does not allocate).
    pub fn reserve(self: *PhysicsDebugRenderer, n: usize) !void {
        try self.quads.ensureTotalCapacity(self.allocator, n);
    }

    pub fn clear(self: *PhysicsDebugRenderer) void {
        self.quads.clearRetainingCapacity();
        self.stats = .{};
    }
    pub fn quadSlice(self: *const PhysicsDebugRenderer) []const DebugQuad {
        return self.quads.items;
    }

    /// Walks the ECS, reads each body's live transform from the world, and
    /// fills `quads`. Idempotent: the previous frame's quads are discarded but
    /// the allocation is kept.
    ///
    /// `physics_world` is the port handle (`physics.World`) — the same value
    /// `physics.System` owns — NOT the `System` itself, so this compiles with
    /// no dependency on `system.zig`.
    pub fn collect(self: *PhysicsDebugRenderer, world: *ecs.World, physics_world: physics.World) void {
        self.clear();
        if (!self.enabled) return;

        var q = world.query(.{ RigidBody2D, Collider2D });
        while (q.nextBatch()) |batch| {
            const rbs = batch.slice(RigidBody2D);
            const cols = batch.slice(Collider2D);
            const n = batch.len();
            var i: usize = 0;
            while (i < n) : (i += 1) {
                const rb = rbs[i];
                if (!rb.isSimulated()) continue;
                const col = cols[i];
                if (!col.isLive()) continue;

                // The body's live transform, not the component's: `Transform`
                // is written by `pullUp` AFTER the step, so mid-frame it lags
                // by one step and a moving body's overlay would ghost.
                const body_id = physics.BodyId{ .index = rb.body, .generation = rb.generation };
                const xf = physics_world.getTransform(body_id);

                const color = self.colorFor(rb, col);
                const half = halfFor(col);

                self.quads.append(self.allocator, .{
                    .pos = .{ xf.position.x + col.offset.x, xf.position.y + col.offset.y },
                    .half = half,
                    .color = color,
                }) catch {
                    self.stats.overflowed += 1;
                    continue;
                };

                self.stats.bodies_drawn += 1;
                if (col.is_sensor) self.stats.sensors_drawn += 1;
            }
        }
    }

    /// The colour for one collider. A sensor always wins over its body type.
    fn colorFor(self: *const PhysicsDebugRenderer, rb: RigidBody2D, col: Collider2D) [4]u8 {
        if (col.is_sensor) return self.colors.sensor;
        return switch (rb.body_type) {
            0 => self.colors.solid_static,
            1 => self.colors.solid_kinematic,
            else => self.colors.solid_dynamic,
        };
    }

    fn halfFor(col: Collider2D) [2]f32 {
        // A circle stores its radius in `size.x`; the second half-extent is the
        // same so the quad that filters around it is a square inscribed in the
        // circle, which is what a box-shaped debug quad can honestly show.
        return switch (col.kind) {
            1 => .{ col.size.x, col.size.x },
            else => .{ col.size.x, col.size.y },
        };
    }
};

// ── Tests ────────────────────────────────────────────────────────────────────

const testing = std.testing;
const system_mod = @import("system.zig");
const System = system_mod.System;

test "collect emits one quad per live collider with the body's live position" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var world = ecs.World.init(allocator);
    defer world.deinit();
    try world.reserveEntities(4);
    try world.reserve(.{ RigidBody2D, Collider2D }, 4);
    try world.reserve(.{ Transform }, 4);

    var sys = try System.init(allocator, .box2d, .{ .x = 0, .y = 200 });
    defer sys.deinit();

    // Spawn BEFORE load so `syncLoad` builds a body for it. The body starts at
    // (5,3) — the component's value — and is moved to (42,-7) below to prove
    // collect reads the WORLD's transform, not the component's.
    const e = try world.spawn(.{
        Transform{ .position = .{ .x = 5, .y = 3 }, .rotation = 0 },
        RigidBody2D{ .body_type = 2 },
        Collider2D{ .size = .{ .x = 0.5, .y = 0.25 } },
    });
    sys.syncLoad(&world);

    const rb = world.get(e, RigidBody2D).?;
    const body_id = physics.BodyId{ .index = rb.body, .generation = rb.generation };
    sys.world.setTransform(body_id, .{ .position = .{ .x = 42, .y = -7 }, .rotation = 0 });

    var dbg = PhysicsDebugRenderer.init(allocator);
    defer dbg.deinit();
    dbg.collect(&world, sys.world);

    try testing.expectEqual(@as(usize, 1), dbg.quadSlice().len);
    const q0 = dbg.quadSlice()[0];
    // The body's live position (42,-7), NOT the component's stale (5,3).
    try testing.expectEqual(@as(f32, 42), q0.pos[0]);
    try testing.expectEqual(@as(f32, -7), q0.pos[1]);
    try testing.expectEqual(@as(f32, 0.5), q0.half[0]);
    try testing.expectEqual(@as(f32, 0.25), q0.half[1]);
    // Dynamic, non-sensor => orange.
    try testing.expectEqualSlices(u8, &DebugColors.solid_dynamic, &q0.color);
}

test "a sensor is blue regardless of its body type" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var world = ecs.World.init(allocator);
    defer world.deinit();
    try world.reserveEntities(4);
    try world.reserve(.{ RigidBody2D, Collider2D }, 4);
    try world.reserve(.{ Transform }, 4);

    var sys = try System.init(allocator, .box2d, .{ .x = 0, .y = 200 });
    defer sys.deinit();

    _ = try world.spawn(.{
        Transform{},
        RigidBody2D{ .body_type = 2 },
        Collider2D{ .is_sensor = true },
    });
    sys.syncLoad(&world);

    var dbg = PhysicsDebugRenderer.init(allocator);
    defer dbg.deinit();
    dbg.collect(&world, sys.world);

    try testing.expectEqual(@as(usize, 1), dbg.quadSlice().len);
    try testing.expectEqualSlices(u8, &DebugColors.sensor, &dbg.quadSlice()[0].color);
    try testing.expectEqual(@as(u32, 1), dbg.stats.sensors_drawn);
}

test "a circle collider is drawn as a square of its radius, static in green" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var world = ecs.World.init(allocator);
    defer world.deinit();
    try world.reserveEntities(4);
    try world.reserve(.{ RigidBody2D, Collider2D }, 4);
    try world.reserve(.{ Transform }, 4);

    var sys = try System.init(allocator, .box2d, .{ .x = 0, .y = 200 });
    defer sys.deinit();

    _ = try world.spawn(.{
        Transform{},
        RigidBody2D{ .body_type = 0 },
        Collider2D{ .kind = 1, .size = .{ .x = 2.0, .y = 0 } },
    });
    sys.syncLoad(&world);

    var dbg = PhysicsDebugRenderer.init(allocator);
    defer dbg.deinit();
    dbg.collect(&world, sys.world);

    const q0 = dbg.quadSlice()[0];
    try testing.expectEqual(@as(f32, 2.0), q0.half[0]);
    try testing.expectEqual(@as(f32, 2.0), q0.half[1]);
    // Fixed, non-sensor => green.
    try testing.expectEqualSlices(u8, &DebugColors.solid_static, &q0.color);
}

test "collect reuses its buffer so the second frame's capacity is unchanged" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var world = ecs.World.init(allocator);
    defer world.deinit();
    try world.reserveEntities(4);
    try world.reserve(.{ RigidBody2D, Collider2D }, 4);
    try world.reserve(.{ Transform }, 4);

    var sys = try System.init(allocator, .box2d, .{ .x = 0, .y = 200 });
    defer sys.deinit();

    _ = try world.spawn(.{
        Transform{},
        RigidBody2D{ .body_type = 2 },
        Collider2D{},
    });
    sys.syncLoad(&world);

    var dbg = PhysicsDebugRenderer.init(allocator);
    defer dbg.deinit();
    try dbg.reserve(16);

    dbg.collect(&world, sys.world);
    try testing.expectEqual(@as(usize, 1), dbg.quadSlice().len);
    const cap_after_first = dbg.quads.capacity;

    // A second frame with the same scene must not grow the buffer.
    dbg.collect(&world, sys.world);
    try testing.expectEqual(@as(usize, 1), dbg.quadSlice().len);
    try testing.expectEqual(cap_after_first, dbg.quads.capacity);
}

