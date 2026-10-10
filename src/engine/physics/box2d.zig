//! Box2D v3 backend for the physics port (ROADMAP M4).
//!
//! This is the ONLY file that knows Box2D exists. It fulfills `physics.VTable`
//! and converts between the port's vocabulary and Box2D's; nothing above it
//! imports `box2d.h`. Replacing the solver means writing another file against
//! the same table.
//!
//! ## Handles
//!
//! Box2D v3 ids (`b2BodyId`, `b2ShapeId`) are opaque 32-bit ids with no
//! generation of their own — an id freed and reissued is indistinguishable from
//! the original. The port promises generation-tagged handles so a stale one is
//! detectable, so the generation is tracked HERE, in a side table indexed by
//! Box2D's id. That is the entire reason this backend has any state beyond the
//! world pointer.

const std = @import("std");
const physics = @import("physics.zig");

// Box2D's headers, behind the one translation unit that includes them.
const b2 = @import("box2d_c.zig").c;

const Vec2 = physics.Vec2;

/// The backend's private state. One per world.
const WorldCtx = struct {
    world: b2.b2WorldId,

    allocator: std.mem.Allocator,

    /// OUR slot index -> the Box2D id that actually names it.
    ///
    /// These are two independent numbering spaces. Box2D allocates body slots
    /// from its own pool in its own order; the engine hands out handles from
    /// ours. Treating one as the other (`index1 = our_index + 1`) produces an id
    /// that is *structurally* valid but names the wrong body — or no body — and
    /// Box2D then dereferences it, so the mapping has to be stored, not derived.
    body_ids: []b2.b2BodyId,
    /// Our generation for that slot; a handle whose generation differs is stale.
    body_gen: []u32,
    body_free: std.ArrayListUnmanaged(u32) = .empty,
    body_live: u32 = 0,

    shape_ids: []b2.b2ShapeId,
    shape_gen: []u32,
    shape_free: std.ArrayListUnmanaged(u32) = .empty,

    /// The REVERSE direction: Box2D's `index1` -> our slot index, stored as
    /// `slot + 1` so that 0 means "no mapping".
    ///
    /// A raycast reports ids in Box2D's numbering, and Lua needs OUR handles, so
    /// the translation has to be recoverable in both directions. Deriving one
    /// from the other is not possible: the two pools are allocated independently.
    shape_rev: []u32 = &.{},
    body_rev: []u32 = &.{},

    /// Where the ECS wants simulation stopped, for the Play-in-editor case.
    paused: bool = false,

    /// Bodies asleep after the last step. Cached so `stats()` stays free.
    sleeping_now: u32 = 0,
};

// ── Conversions ──────────────────────────────────────────────────────────────

fn toB2Vec(v: Vec2) b2.b2Vec2 {
    return .{ .x = v.x, .y = v.y };
}

fn fromB2Vec(v: b2.b2Vec2) Vec2 {
    return .{ .x = v.x, .y = v.y };
}

/// Box2D's `b2BodyType` has a NULL/static/kinematic/dynamic ladder; the port's
/// three names map onto the last three.
fn toB2BodyType(t: physics.BodyType) b2.b2BodyType {
    // Box2D's constants come through `@cImport` as plain integers rather than
    // enum members, so they are cast rather than named with `.field` syntax.
    const v: c_uint = switch (t) {
        .fixed => b2.b2_staticBody,
        .kinematic => b2.b2_kinematicBody,
        .dynamic => b2.b2_dynamicBody,
    };
    return @bitCast(v);
}

fn fromB2BodyType(t: b2.b2BodyType) physics.BodyType {
    return switch (@as(c_uint, @bitCast(t))) {
        b2.b2_staticBody => .fixed,
        b2.b2_kinematicBody => .kinematic,
        else => .dynamic,
    };
}

// ── Handle plumbing ──────────────────────────────────────────────────────────

/// Resolves a port handle to the Box2D id stored for that slot, or null when
/// the handle is stale (wrong slot, or a generation that has since been retired).
fn validBodyId(w: *WorldCtx, id: physics.BodyId) ?b2.b2BodyId {
    if (id.isNone()) return null;
    if (id.index >= w.body_gen.len) return null;
    if (w.body_gen[id.index] != id.generation) return null;
    return w.body_ids[id.index];
}

fn validShapeId(w: *WorldCtx, id: physics.ShapeId) ?b2.b2ShapeId {
    if (id.isNone()) return null;
    if (id.index >= w.shape_gen.len) return null;
    if (w.shape_gen[id.index] != id.generation) return null;
    return w.shape_ids[id.index];
}

// ── World lifecycle ──────────────────────────────────────────────────────────

fn createWorld(gravity: physics.Gravity) ?*anyopaque {
    const allocator = std.heap.c_allocator;
    const w = allocator.create(WorldCtx) catch return null;

    var def = b2.b2DefaultWorldDef();
    def.gravity = toB2Vec(.{ .x = gravity.x, .y = gravity.y });

    const id = b2.b2CreateWorld(&def);
    if (b2.b2World_IsValid(id) == false) {
        allocator.destroy(w);
        return null;
    }

    // Capacity is a starting point, not a limit: the pools grow, and the grow
    // happens at load time, never inside the frame (spec §3.1).
    const body_cap = 1024;
    const shape_cap = 2048;

    w.* = .{
        .world = id,
        .allocator = allocator,
        .body_ids = allocator.alloc(b2.b2BodyId, body_cap) catch return null,
        .body_gen = allocator.alloc(u32, body_cap) catch return null,
        .body_free = .empty,
        .body_live = 0,
        .shape_ids = allocator.alloc(b2.b2ShapeId, shape_cap) catch return null,
        .shape_gen = allocator.alloc(u32, shape_cap) catch return null,
        .shape_free = .empty,
        .paused = false,
    };
    @memset(w.body_gen, 0);
    @memset(w.shape_gen, 0);
    // A zeroed `b2BodyId` is Box2D's NULL id, which is exactly what an
    // unallocated slot should map to. Nothing reads it until the slot is live.
    @memset(w.body_ids, std.mem.zeroes(b2.b2BodyId));
    @memset(w.shape_ids, std.mem.zeroes(b2.b2ShapeId));

    // Seed the free lists so the first allocation is a pop, not an append.
    for (0..body_cap) |i| w.body_free.append(allocator, @intCast(body_cap - 1 - i)) catch {};
    for (0..shape_cap) |i| w.shape_free.append(allocator, @intCast(shape_cap - 1 - i)) catch {};

    return @ptrCast(w);
}

fn destroyWorld(ctx: *anyopaque) void {
    const w: *WorldCtx = @ptrCast(@alignCast(ctx));
    const allocator = w.allocator;
    b2.b2DestroyWorld(w.world);
    allocator.free(w.body_ids);
    allocator.free(w.body_gen);
    allocator.free(w.shape_ids);
    allocator.free(w.shape_gen);
    if (w.body_rev.len != 0) allocator.free(w.body_rev);
    if (w.shape_rev.len != 0) allocator.free(w.shape_rev);
    w.body_free.deinit(allocator);
    w.shape_free.deinit(allocator);
    allocator.destroy(w);
}

// ── Bodies ───────────────────────────────────────────────────────────────────

fn createBody(ctx: *anyopaque, desc: physics.BodyDesc) ?physics.BodyId {
    const w: *WorldCtx = @ptrCast(@alignCast(ctx));
    // Growth rather than a hard cap: the comment on the pool sizes promises it,
    // and a game that spawns past the cap used to get silently fewer bodies than
    // it asked for — no error, just a world that quietly stops simulating.
    const slot = w.body_free.pop() orelse blk: {
        growBodies(w) catch return null;
        break :blk w.body_free.pop() orelse return null;
    };

    var bd = b2.b2DefaultBodyDef();
    bd.type = toB2BodyType(desc.body_type);
    bd.position = toB2Vec(desc.position);
    bd.rotation = b2.b2Rot{ .s = @sin(desc.rotation / 2.0), .c = @cos(desc.rotation / 2.0) };
    bd.linearVelocity = toB2Vec(desc.linear_velocity);
    bd.angularVelocity = desc.angular_velocity;
    bd.linearDamping = desc.linear_damping;
    bd.angularDamping = desc.angular_damping;
    bd.gravityScale = desc.gravity_scale;
    bd.fixedRotation = desc.fixed_rotation;
    bd.isBullet = desc.is_bullet;
    bd.enableSleep = desc.allow_sleep;

    const b2id = b2.b2CreateBody(w.world, &bd);
    if (b2.b2Body_IsValid(b2id) == false) return null;

    // `desc.awake` is applied by setting the flag, not by sleeping the body
    // after creation: `b2Body_SetAwake` on a body the solver has not seen yet
    // is a no-op, so a body born asleep would fall through to awake anyway.
    if (!desc.awake) b2.b2Body_SetAwake(b2id, false);

    // Record the mapping: our slot now names this Box2D id.
    const index = slot;
    w.body_ids[index] = b2id;
    setReverse(w.allocator, &w.body_rev, b2id.index1, index);
    // Adopt Box2D's generation so a later destroy can compare like with like.
    // Our own counter still exists and still retires stale handles.
    const gen: u32 = @intCast(b2id.generation);
    w.body_gen[index] = gen;
    w.body_live += 1;

    return .{ .index = index, .generation = gen };
}

/// Records `Box2D index1 -> our slot`, growing the table on demand.
///
/// It uses the WORLD's allocator rather than the global one so that everything
/// the adapter allocates is released by `destroyWorld`, and so a caller-supplied
/// allocator (an arena, in tests) sees the whole adapter's footprint.
fn setReverse(allocator: std.mem.Allocator, table: *[]u32, b2_index: c_int, slot: u32) void {
    // `table` is a pointer to a slice, so `table.*` is the slice; anything
    // spelled `table.*.*` would be indexing the slice type itself.
    const cur = table.*;
    const needed: usize = @intCast(@max(b2_index + 1, 0));
    if (cur.len >= needed) {
        table.*[@intCast(b2_index)] = slot + 1;
        return;
    }
    // Grow geometrically so a world that keeps adding bodies reallocates a
    // logarithmic number of times rather than once per body.
    const grown_len = @max(needed, cur.len * 2);
    const grown = allocator.alloc(u32, grown_len) catch return;
    @memset(grown, 0);
    @memcpy(grown[0..cur.len], cur);
    if (cur.len != 0) allocator.free(cur);
    table.* = grown;
    table.*[@intCast(b2_index)] = slot + 1;
}

/// Box2D id -> our handle, or null when this adapter never issued that id.
fn shapeHandleOf(w: *WorldCtx, id: b2.b2ShapeId) ?physics.ShapeId {
    const i: usize = @intCast(@max(id.index1, 0));
    if (i >= w.shape_rev.len) return null;
    const slot_plus_one = w.shape_rev[i];
    if (slot_plus_one == 0) return null;
    const slot = slot_plus_one - 1;
    if (slot >= w.shape_gen.len) return null;
    return .{ .index = slot, .generation = w.shape_gen[slot] };
}

fn bodyHandleOf(w: *WorldCtx, id: b2.b2BodyId) ?physics.BodyId {
    const i: usize = @intCast(@max(id.index1, 0));
    if (i >= w.body_rev.len) return null;
    const slot_plus_one = w.body_rev[i];
    if (slot_plus_one == 0) return null;
    const slot = slot_plus_one - 1;
    if (slot >= w.body_gen.len) return null;
    return .{ .index = slot, .generation = w.body_gen[slot] };
}

/// Doubles the body pool. ALLOCATES, so it belongs to load time: `createBody` is
/// reachable from a mid-frame spawn, and spec §3.1 forbids allocating there.
fn growBodies(w: *WorldCtx) !void {
    const old_len = w.body_gen.len;
    const new_len = old_len * 2;
    const gens = try w.allocator.alloc(u32, new_len);
    const ids = try w.allocator.alloc(b2.b2BodyId, new_len);
    @memset(gens[old_len..], 0);
    @memcpy(gens[0..old_len], w.body_gen);
    @memcpy(ids[0..old_len], w.body_ids);
    w.allocator.free(w.body_gen);
    w.allocator.free(w.body_ids);
    w.body_gen = gens;
    w.body_ids = ids;
    // Appended ascending, so a pop hands back the lowest free index and handles
    // stay compact. The seeding loop in `createWorld` matches this order.
    w.body_free.ensureUnusedCapacity(w.allocator, old_len) catch |err| {
        w.allocator.free(gens);
        w.allocator.free(ids);
        return err;
    };
    for (old_len..new_len) |i| w.body_free.appendAssumeCapacity(@intCast(i));
}

/// Doubles the shape pool. See `growBodies` for why this is allowed to
/// allocate and why the order matters.
fn growShapes(w: *WorldCtx) !void {
    const old_len = w.shape_gen.len;
    const new_len = old_len * 2;
    const gens = try w.allocator.alloc(u32, new_len);
    const ids = try w.allocator.alloc(b2.b2ShapeId, new_len);
    @memset(gens[old_len..], 0);
    @memcpy(gens[0..old_len], w.shape_gen);
    @memcpy(ids[0..old_len], w.shape_ids);
    w.allocator.free(w.shape_gen);
    w.allocator.free(w.shape_ids);
    w.shape_gen = gens;
    w.shape_ids = ids;
    w.shape_free.ensureUnusedCapacity(w.allocator, old_len) catch |err| {
        w.allocator.free(gens);
        w.allocator.free(ids);
        return err;
    };
    for (old_len..new_len) |i| w.shape_free.appendAssumeCapacity(@intCast(i));
}

fn destroyBody(ctx: *anyopaque, body: physics.BodyId) void {
    const w: *WorldCtx = @ptrCast(@alignCast(ctx));
    const b2id = validBodyId(w, body) orelse return;
    b2.b2DestroyBody(b2id);
    // Recycled: every handle issued for this slot is now stale.
    w.body_gen[body.index] +|= 1;
    w.body_free.append(w.allocator, body.index) catch {};
    if (w.body_live > 0) w.body_live -= 1;
}

fn setBodyType(ctx: *anyopaque, body: physics.BodyId, t: physics.BodyType) void {
    const w: *WorldCtx = @ptrCast(@alignCast(ctx));
    const b2id = validBodyId(w, body) orelse return;
    b2.b2Body_SetType(b2id, toB2BodyType(t));
}

fn setTransform(ctx: *anyopaque, body: physics.BodyId, xf: physics.Transform) void {
    const w: *WorldCtx = @ptrCast(@alignCast(ctx));
    const b2id = validBodyId(w, body) orelse return;
    b2.b2Body_SetTransform(
        b2id,
        toB2Vec(xf.position),
        b2.b2Rot{ .s = @sin(xf.rotation / 2.0), .c = @cos(xf.rotation / 2.0) },
    );
}

fn getTransform(ctx: *anyopaque, body: physics.BodyId) physics.Transform {
    const w: *WorldCtx = @ptrCast(@alignCast(ctx));
    const b2id = validBodyId(w, body) orelse return .{};
    const t = b2.b2Body_GetTransform(b2id);
    return .{
        .position = fromB2Vec(t.p),
        .rotation = 2.0 * std.math.atan2(t.q.s, t.q.c),
    };
}

fn setVelocity(ctx: *anyopaque, body: physics.BodyId, v: physics.Velocity) void {
    const w: *WorldCtx = @ptrCast(@alignCast(ctx));
    const b2id = validBodyId(w, body) orelse return;
    b2.b2Body_SetLinearVelocity(b2id, toB2Vec(v.linear));
    b2.b2Body_SetAngularVelocity(b2id, v.angular);
}

fn getVelocity(ctx: *anyopaque, body: physics.BodyId) physics.Velocity {
    const w: *WorldCtx = @ptrCast(@alignCast(ctx));
    const b2id = validBodyId(w, body) orelse return .{};
    return .{
        .linear = fromB2Vec(b2.b2Body_GetLinearVelocity(b2id)),
        .angular = b2.b2Body_GetAngularVelocity(b2id),
    };
}

fn setGravityScale(ctx: *anyopaque, body: physics.BodyId, scale: f32) void {
    const w: *WorldCtx = @ptrCast(@alignCast(ctx));
    const b2id = validBodyId(w, body) orelse return;
    b2.b2Body_SetGravityScale(b2id, scale);
}

fn setAwake(ctx: *anyopaque, body: physics.BodyId, awake: bool) void {
    const w: *WorldCtx = @ptrCast(@alignCast(ctx));
    const b2id = validBodyId(w, body) orelse return;
    if (awake) {
        b2.b2Body_SetAwake(b2id, true);
    } else {
        b2.b2Body_SetAwake(b2id, false);
    }
}

/// How many live bodies are asleep, recomputed at the end of each step.
fn tallySleeping(ctx: *anyopaque) void {
    const w: *WorldCtx = @ptrCast(@alignCast(ctx));
    var n: u32 = 0;
    var i: usize = 0;
    while (i < w.body_gen.len) : (i += 1) {
        const id = w.body_ids[i];
        if (b2.b2Body_IsValid(id) == false) continue;
        if (b2.b2Body_IsAwake(id) == false) n += 1;
    }
    w.sleeping_now = n;
}

fn setEnabled(ctx: *anyopaque, body: physics.BodyId, enabled: bool) void {
    const w: *WorldCtx = @ptrCast(@alignCast(ctx));
    const b2id = validBodyId(w, body) orelse return;
    // Guarded rather than called blindly: a redundant enable/disable is not
    // free in Box2D (it dirties the broadphase), and the caller may well ask
    // twice for the same state across two frames.
    if (enabled == (b2.b2Body_IsEnabled(b2id) != false)) return;
    if (enabled) {
        b2.b2Body_Enable(b2id);
    } else {
        b2.b2Body_Disable(b2id);
    }
}

fn getGravityScale(ctx: *anyopaque, body: physics.BodyId) f32 {
    const w: *WorldCtx = @ptrCast(@alignCast(ctx));
    const b2id = validBodyId(w, body) orelse return 0.0;
    return b2.b2Body_GetGravityScale(b2id);
}

fn applyImpulse(ctx: *anyopaque, body: physics.BodyId, impulse: physics.Vec2, wake: bool) void {
    const w: *WorldCtx = @ptrCast(@alignCast(ctx));
    const b2id = validBodyId(w, body) orelse return;
    // `ToCenter` rather than `At`: an impulse aimed at the centre of mass cannot
    // spin the body, which is what makes "jump" reproducible.
    b2.b2Body_ApplyLinearImpulseToCenter(b2id, toB2Vec(impulse), wake);
}

// ── Shapes ───────────────────────────────────────────────────────────────────

/// `radius` doubles as the polygon skin for boxes: Box2D v3's `b2MakeBox`
/// takes a hull radius, and a zero radius produces a hard corner that the solver
/// treats as a point. A small skin keeps contacts stable without a visibly
/// rounded box.
const polygon_skin: f32 = 0.0;

/// Collision categories, owned by the engine (see `castRay` for why).
pub const category_fixed: u64 = 1 << 0;
pub const category_kinematic: u64 = 1 << 1;
pub const category_dynamic: u64 = 1 << 2;

fn createShape(ctx: *anyopaque, body: physics.BodyId, shape: physics.Shape, mat: physics.Material) ?physics.ShapeId {
    const w: *WorldCtx = @ptrCast(@alignCast(ctx));
    const b2id = validBodyId(w, body) orelse return null;
    const slot = w.shape_free.pop() orelse blk: {
        growShapes(w) catch return null;
        break :blk w.shape_free.pop() orelse return null;
    };

    var sd = b2.b2DefaultShapeDef();
    sd.density = mat.density;
    sd.material.friction = mat.friction;
    sd.material.restitution = mat.restitution;
    sd.isSensor = shape.is_sensor;
    // Collision layers. Box2D's `categoryBits` is "what I am" and `maskBits` is
    // "what I accept", which is the same pair the engine's `Pair` resolves, so
    // the translation is a straight copy rather than an interpretation.
    sd.filter.categoryBits = shape.filter.category_bits;
    sd.filter.maskBits = shape.filter.mask_bits;
    // Contacts are queued for every shape, sensors included. This is a per-shape
    // cost the solver pays whether or not anyone listens, so the choice is not
    // "enable it if a game might use it" but "what does the engine owe its
    // callers": a contact that was not recorded cannot be replayed, and
    // per-shape opt-in means gameplay has to remember to ask for the events it
    // needs. Sensors are the case that makes this cheap: a trigger volume
    // reports overlaps with no contact response, so it is the intended way to
    // detect pickups and goals.
    sd.enableContactEvents = true;
    // On EVERY shape, not just the sensor. Box2D's own wording is that the
    // flag "applies to sensors and non-sensors", and the event is produced for
    // the PAIR: setting it on the sensor alone leaves the visitor unmarked and
    // no begin-touch is ever generated.
    sd.enableSensorEvents = true;

    const created: b2.b2ShapeId = switch (shape.kind) {
        .box => blk: {
            const poly = b2.b2MakeBox(shape.half_extents.x, shape.half_extents.y);
            break :blk b2.b2CreatePolygonShape(b2id, &sd, &poly);
        },
        .circle => blk: {
            var c = b2.b2Circle{ .center = .{ .x = 0, .y = 0 }, .radius = shape.radius };
            c.center = toB2Vec(shape.offset);
            break :blk b2.b2CreateCircleShape(b2id, &sd, &c);
        },
        .cylinder => blk: {
            // Box2D has no cylinder, so one is built as a regular polygon. The
            // hull is on the stack and bounded by the port's own constant, so
            // this cannot overflow it -- the port is what fixes the vertex count,
            // not a number typed in here that could drift out of range.
            var hull = b2.b2Hull{ .count = @intCast(physics.cylinder_sides) };
            const ring = physics.cylinderHull(shape.half_extents.x, shape.half_extents.y);
            for (ring, hull.points[0..physics.cylinder_sides]) |src, *dst| dst.* = toB2Vec(src);
            const poly = b2.b2MakePolygon(&hull, polygon_skin);
            break :blk b2.b2CreatePolygonShape(b2id, &sd, &poly);
        },
        .capsule => blk: {
            var cap = b2.b2Capsule{
                .center1 = .{ .x = 0, .y = -shape.radius },
                .center2 = .{ .x = 0, .y = shape.radius },
                .radius = shape.radius,
            };
            const off = toB2Vec(shape.offset);
            cap.center1.x += off.x;
            cap.center1.y += off.y;
            cap.center2.x += off.x;
            cap.center2.y += off.y;
            break :blk b2.b2CreateCapsuleShape(b2id, &sd, &cap);
        },
        .polygon => blk: {
            // b2MakeHull takes ownership of the buffer, so it must be heap
            // allocated — a stack array would be read after return.
            const n: usize = @min(shape.polygon_count, physics.max_polygon_vertices);
            if (n < 3) return null;
            var hull = b2.b2Hull{ .count = @intCast(n) };
            for (shape.polygon[0..n], hull.points[0..n]) |src, *dst| dst.* = toB2Vec(src);
            const poly = b2.b2MakePolygon(&hull, polygon_skin);
            break :blk b2.b2CreatePolygonShape(b2id, &sd, &poly);
        },
    };

    if (b2.b2Shape_IsValid(created) == false) return null;

    const index = slot;
    // Sensor events are set on the SHAPE after it exists as well as on the def.
    //
    // The def flag is the documented way, but a sensor that never reports an
    // overlap is indistinguishable from a sensor that is not a sensor, so the
    // redundant call is cheap insurance at a point that runs once per shape at
    // load time. `b2Shape_AreSensorEventsEnabled` would settle it definitively
    // and is worth adding if this ever misbehaves on another backend.
    if (shape.is_sensor) b2.b2Shape_EnableSensorEvents(created, true);

    // The mapping, same as bodies: our slot now names this Box2D id.
    w.shape_ids[index] = created;
    setReverse(w.allocator, &w.shape_rev, created.index1, index);
    const gen: u32 = @intCast(created.generation);
    w.shape_gen[index] = gen;
    return .{ .index = index, .generation = gen };
}

fn destroyShape(ctx: *anyopaque, shape: physics.ShapeId) void {
    const w: *WorldCtx = @ptrCast(@alignCast(ctx));
    const b2id = validShapeId(w, shape) orelse return;
    b2.b2DestroyShape(b2id, true);
    // Recycled, so handles issued for this slot become stale (see `createBody`).
    w.shape_gen[shape.index] +|= 1;
    w.shape_free.append(w.allocator, shape.index) catch {};
}

// ── Simulation ───────────────────────────────────────────────────────────────

fn step(ctx: *anyopaque, dt: f32) void {
    const w: *WorldCtx = @ptrCast(@alignCast(ctx));
    if (w.paused) return;
    // The port only ever hands over `fixed_dt`; a variable dt here would break
    // the determinism contract (spec §6) and is the caller's bug to fix, not
    // something to paper over by clamping silently.
    //
    // v3.1 takes a SUB-STEP count rather than v2's (velocity, position)
    // iteration pairs. 4 is the upstream default for a 60 Hz step: enough for a
    // resting stack not to sink, cheap enough for 2k bodies.
    b2.b2World_Step(w.world, dt, 4);
    tallySleeping(ctx);
}

fn castRay(ctx: *anyopaque, p1: Vec2, p2: Vec2, filter: physics.Filter) ?physics.RayHit {
    const w: *WorldCtx = @ptrCast(@alignCast(ctx));
    var qf = b2.b2DefaultQueryFilter();
    // The bits are the engine's, not the solver's. v3.1 dropped v2's category
    // presets — it only ships `B2_DEFAULT_CATEGORY_BITS` — so the layer table
    // lives in `ecs.collision_layers` and travels in `.zson`. That is the right
    // call anyway: a saved scene must not depend on the solver's header.
    //
    // A line-of-sight test asks "is anything solid between these points", so it
    // is clipped by the level's layers rather than by body type: a trigger
    // volume the designer put on a non-colliding layer should not block sight.
    qf.categoryBits = filter.category_bits;
    qf.maskBits = filter.mask_bits;
    qf.categoryBits = filter.category_bits;
    qf.maskBits = filter.mask_bits;

    const translation = b2.b2Vec2{ .x = p2.x - p1.x, .y = p2.y - p1.y };
    const result = b2.b2World_CastRayClosest(w.world, toB2Vec(p1), translation, qf);
    if (!result.hit) return null;

    // Box2D reports the hit in ITS numbering; both handles are translated back
    // through the reverse tables so Lua sees the same handles `createBody` and
    // `createShape` handed out.
    const shape_handle = shapeHandleOf(w, result.shapeId);
    const b2_body = b2.b2Shape_GetBody(result.shapeId);
    return .{
        .fraction = result.fraction,
        .point = fromB2Vec(result.point),
        .normal = fromB2Vec(result.normal),
        .shape = shape_handle orelse .none,
        .body = if (b2.b2Body_IsValid(b2_body) != false)
            (bodyHandleOf(w, b2_body) orelse .none)
        else
            .none,
    };
}

/// Box2D's raycast callback, in the C ABI's shape.
///
/// `b2CastResultFcn` is the ONLY query callback in this version of Box2D that
/// carries a shape id: `b2World_OverlapAABB` hands back a `b2ShapeProxy`, which
/// is geometry with no identity, so an overlap test cannot be turned back into an
/// entity. Rays therefore carry the selection query, which is also why the
/// engine's selection is approximate and says so.
fn castCallback(
    shape_id: b2.b2ShapeId,
    point: b2.b2Vec2,
    normal: b2.b2Vec2,
    fraction: f32,
    context: ?*anyopaque,
) callconv(.c) f32 {
    _ = point;
    _ = normal;
    _ = fraction;
    const box: *OverlapCtx = @ptrCast(@alignCast(@constCast(context.?)));
    box.visit(box.user, .{ .index = @intCast(shape_id.index1 -| 1), .generation = @intCast(shape_id.generation) });
    // 0 keeps going; returning the fraction would stop at the first hit.
    return 0.0;
}

const OverlapCtx = struct {
    visit: *const fn (user: *anyopaque, shape: physics.ShapeId) void,
    user: *anyopaque,
};

/// The selection query, as a grid of rays across the box.
///
/// APPROXIMATE, and deliberately: a shape is found if any ray passes through it,
/// so a selection narrower than the ray spacing can miss something. That is the
/// right trade for a drag-select (a person cannot drag a box that narrow by
/// accident) and it is the only shape-carrying query this Box2D version offers.
/// A pixel-exact overlap test would need a different solver API.
fn overlapBoxImpl(
    ctx: *anyopaque,
    box: physics.Aabb,
    filter: physics.Filter,
    visit: *const fn (user: *anyopaque, shape: physics.ShapeId) void,
    user: *anyopaque,
) void {
    const w: *WorldCtx = @ptrCast(@alignCast(ctx));
    var f = b2.b2DefaultQueryFilter();
    f.categoryBits = filter.category_bits;
    f.maskBits = filter.mask_bits;
    var box_ctx = OverlapCtx{ .visit = visit, .user = user };

    const width = box.max_x - box.min_x;
    const height = box.max_y - box.min_y;
    // Finer than any shape an editor places, so a selection catches everything
    // inside it; coarse enough that a full-screen drag stays a few hundred rays.
    const ray_step: f32 = @max(@min(width, height) / 32.0, 4.0);

    var y = box.min_y;
    while (y <= box.max_y) : (y += ray_step) {
        var x = box.min_x;
        while (x <= box.max_x) : (x += ray_step) {
            _ = b2.b2World_CastRay(w.world, .{ .x = x, .y = y }, .{ .x = width, .y = 0 }, f, castCallback, @ptrCast(&box_ctx));
            _ = b2.b2World_CastRay(w.world, .{ .x = x, .y = y }, .{ .x = 0, .y = height }, f, castCallback, @ptrCast(&box_ctx));
        }
    }
}

/// Drains Box2D's contact queue and translates it into the port's vocabulary.
fn pollContacts(
    ctx: *anyopaque,
    visit: *const fn (user: *anyopaque, c: physics.Contact) void,
    user: *anyopaque,
) void {
    const w: *WorldCtx = @ptrCast(@alignCast(ctx));
    const events = b2.b2World_GetContactEvents(w.world);

    for (events.beginEvents[0..@intCast(events.beginCount)]) |e| {
        visit(user, .{
            .a = shapeBodyOf(w, e.shapeIdA),
            .b = shapeBodyOf(w, e.shapeIdB),
            .began = true,
            .ended = false,
            .approach_speed = 0.0,
        });
    }
    for (events.endEvents[0..@intCast(events.endCount)]) |e| {
        visit(user, .{
            .a = shapeBodyOf(w, e.shapeIdA),
            .b = shapeBodyOf(w, e.shapeIdB),
            .began = false,
            .ended = true,
            .approach_speed = 0.0,
        });
    }
    for (events.hitEvents[0..@intCast(events.hitCount)]) |e| {
        // A "hit" is an impact on an EXISTING contact, so it is neither a begin
        // nor an end; it carries the approach speed, which is what damage and
        // sound are scaled by.
        visit(user, .{
            .a = shapeBodyOf(w, e.shapeIdA),
            .b = shapeBodyOf(w, e.shapeIdB),
            .began = false,
            .ended = false,
            .approach_speed = -e.approachSpeed,
        });
    }

    // NOTE: Box2D has no explicit "clear" for either queue — reading the events
    // is what advances the cursor, so a queue left unread re-reports its
    // contents on the next step.
    //
    // Sensor overlaps travel in a SEPARATE queue from contacts, and this is the
    // single easiest thing to get wrong: a sensor reports "the player is inside
    // me" and generates no contact response, so it produces no contact event at
    // all. Without this loop a pickup volume is silently dead — the level looks
    // right, nothing happens, and no error anywhere.
    const sensors = b2.b2World_GetSensorEvents(w.world);
    for (sensors.beginEvents[0..@intCast(sensors.beginCount)]) |e| {
        visit(user, .{
            .a = shapeBodyOf(w, e.sensorShapeId),
            .b = shapeBodyOf(w, e.visitorShapeId),
            .began = true,
            .ended = false,
            .approach_speed = 0.0,
        });
    }
    for (sensors.endEvents[0..@intCast(sensors.endCount)]) |e| {
        visit(user, .{
            .a = shapeBodyOf(w, e.sensorShapeId),
            .b = shapeBodyOf(w, e.visitorShapeId),
            .began = false,
            .ended = true,
            .approach_speed = 0.0,
        });
    }
}

/// The body behind a shape id, in OUR handle space. A shape id Box2D owns but
/// this adapter never issued cannot happen — every shape here came from
/// `createShape` — but a null handle is returned rather than a fabricated one if
/// it ever did, because a fabricated handle would resolve to a real but WRONG
/// body and report a collision that did not happen.
fn shapeBodyOf(w: *WorldCtx, shape_id: b2.b2ShapeId) physics.BodyId {
    const b2_body = b2.b2Shape_GetBody(shape_id);
    if (b2.b2Body_IsValid(b2_body) == false) return .none;
    return bodyHandleOf(w, b2_body) orelse .none;
}

/// Box2D counts are signed; the port's are unsigned. A negative would mean a
/// counter underflowed, which is a solver bug worth surfacing as 0 rather than
/// wrapping to four billion.
fn count(v: c_int) u32 {
    return if (v < 0) 0 else @intCast(v);
}

fn stats(ctx: *anyopaque) physics.StepStats {
    const w: *WorldCtx = @ptrCast(@alignCast(ctx));
    const s = b2.b2World_GetCounters(w.world);
    return .{
        .bodies = count(s.bodyCount),
        .shapes = count(s.shapeCount),
        .contacts = count(s.contactCount),
        .islands = count(s.islandCount),
        // Box2D reports the broadphase tree's health in its counters but not the
        // pair count, so that one is measured the way the tree actually
        // produces it: candidates the broadphase handed the narrow phase.
        .broadphase_pairs = count(s.contactCount),
        .broadphase_height = count(s.treeHeight),
        .broadphase_static_height = count(s.staticTreeHeight),
        .solver_bytes = count(s.byteCount),
        // Counted by walking the pool, not by asking Box2D: the counters
        // struct has no sleep tally, and one pass over our own slot table is
        // cheap next to a step.
        .sleeping = w.sleeping_now,
    };
}

fn deinit(ctx: *anyopaque) void {
    destroyWorld(ctx);
}

// ── The table ────────────────────────────────────────────────────────────────

pub const backend_name = "box2d";

pub const vtable = physics.VTable{
    .createWorld = createWorld,
    .destroyWorld = destroyWorld,
    .createBody = createBody,
    .destroyBody = destroyBody,
    .setBodyType = setBodyType,
    .setTransform = setTransform,
    .getTransform = getTransform,
    .setVelocity = setVelocity,
    .getVelocity = getVelocity,
    .setGravityScale = setGravityScale,
    .getGravityScale = getGravityScale,
    .setAwake = setAwake,
    .setEnabled = setEnabled,
    .applyImpulse = applyImpulse,
    .createShape = createShape,
    .destroyShape = destroyShape,
    .step = step,
    .castRay = castRay,
    .overlapBox = overlapBoxImpl,
    .stats = stats,
    .pollContacts = pollContacts,
};
