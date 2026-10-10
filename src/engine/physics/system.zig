//! ECS ↔ solver sync: the bridge that makes physics actually run (M4).
//!
//! Everything above this file is independent of Box2D; this is where the ECS
//! and the port meet. It does three jobs per frame, in this order, and the order
//! is the contract:
//!
//! 1. **Down, before the step.** Gameplay wrote velocity/gravity/rotation into
//!    `RigidBody2D` this frame; push it to the solver. Also snapshots the
//!    CURRENT transform as the interpolation "previous", because the solver is
//!    about to overwrite it and the renderer needs the pair.
//! 2. **Step.** Through the `Driver`, so the fixed 60 Hz rate and the one-step
//!    catch-up cap hold (spec §3.3).
//! 3. **Up, after the step.** The solver's authoritative position/rotation goes
//!    into `Transform`. Gameplay never writes position for a simulated body —
//!    it writes velocity, and the solver owns where things are.
//!
//! ## Why bodies are created lazily and cached
//!
//! A body handle is created once, on first sight of the entity, and cached in
//! the `RigidBody2D` component. Creating one per step would allocate in the frame
//! loop (spec §3.1) and would reset the solver's warm-start cache every frame,
//! which is felt as jitter on resting stacks.
//!
//! ## Why a body is dropped when its entity dies
//!
//! The solver keeps its own copy. Leaving it behind is a leak that survives every
//! level transition; the entity is swept here so a world that spawns and kills
//! thousands of bodies stays flat in memory.

const std = @import("std");
const ecs = @import("ecs");
const physics = @import("physics.zig");
// The port deliberately knows nothing about stepping — that is the driver's
// job — so it is reached directly rather than through the port.
const Driver = @import("driver.zig").Driver;
const port = @import("physics.zig");

const World = ecs.World;
const Entity = ecs.Entity;
const components = ecs.components;
const RigidBody2D = components.RigidBody2D;
const Collider2D = components.Collider2D;
const Transform = components.Transform;

/// The signal name collision events are published under.
///
/// A constant at module scope rather than a field: it is part of the engine's
/// contract with gameplay, and interning it per emit would allocate
/// (spec §3.1). Living here rather than in Lua is what makes a typo in a
/// listener a missing event instead of a silent one.
pub const contact_signal = "collision";

/// A body handle packed into a single key, for the reverse map.
///
/// The packing must match `Entity.bits` in shape: index in the low half,
/// generation in the high half. It is a key, not a handle — nothing may be
/// reconstructed from it.
pub fn bodyBits(id: physics.BodyId) u64 {
    return @as(u64, id.index) | (@as(u64, id.generation) << 32);
}

/// What a collision event carries to Lua. Small and POD so it can go through the
/// typed signal bus (spec §6 orders events by spawn order).
///
/// `self_index` is included rather than implied by the receiver, because a
/// signal is delivered to every listener and each listener needs to know WHICH
/// body the event is about.
pub const ContactEvent = extern struct {
    /// The entity this event is about — the one whose `self` is listening.
    self_index: u32,
    self_generation: u32,
    /// The other body's entity handle, so `0xFFFFFFFF` means "not an actor".
    other_index: u32,
    other_generation: u32,
    /// Impact speed in units/second, so a tap can be told from a crash.
    approach_speed: f32,
    /// True when this contact began this step (as opposed to persisting).
    began: bool,
    /// True when it ended (a foot leaving the ground).
    ended: bool,
};

pub const Error = error{WorldCreationFailed} || physics.Error;

/// Owns the physics world and keeps it in step with the ECS.
pub const System = struct {
    backend: @import("root.zig").Backend,
    world: physics.World,
    driver: Driver,
    allocator: std.mem.Allocator,

    /// Bodies created this session, kept so a despawn can destroy them.
    created: u32 = 0,
    dropped: u32 = 0,

    /// Nanoseconds the last `step` spent inside the solver. The frame total
    /// minus this is the sync's own cost, which is the half the engine owns —
    /// measured rather than guessed, because a budget miss needs to be
    /// attributed before it can be fixed.
    last_solver_ns: u64 = 0,

    /// Body handle -> entity, so a contact can be reported to the actor it
    /// belongs to.
    ///
    /// The reverse lookup cannot be done by walking the ECS: a frame with 200
    /// simultaneous contacts would be 200 full archetype walks, which is the
    /// kind of cost that hides inside a frame until the level gets busy. Built
    /// at load time, read-only during the frame.
    body_index: std.AutoHashMapUnmanaged(u64, Entity) = .empty,

    /// Impulses queued by gameplay for the next step, keyed by entity. Cleared
    /// at the end of every `pushDown`, so an impulse lasts exactly one frame —
    /// a queued impulse that survived would apply again every frame and turn a
    /// jump into an elevator.
    pending: std.AutoHashMapUnmanaged(Entity, physics.Vec2) = .empty,

    /// Contact events published since this System was created. A number a
    /// profiler can watch: a frame that quietly emits thousands of collisions
    /// means bodies are interpenetrating, which is a level bug the collision
    /// system would otherwise hide.
    contacts_emitted: u32 = 0,

    pub fn init(allocator: std.mem.Allocator, backend: @import("root.zig").Backend, gravity: physics.Gravity) !System {
        const world = try @import("root.zig").createWorld(backend, gravity);
        var self_: System = .{
            .backend = backend,
            .world = world,
            .driver = Driver.init(world),
            .allocator = allocator,
        };
        // The map is sized for the bodies the world will see, not grown lazily
        // during a frame — `put` reallocating on first collision is exactly the
        // allocation spec §3.1 forbids.
        try self_.body_index.ensureTotalCapacity(allocator, 1024);
        // Same reasoning: `pending` is written by gameplay during the frame and
        // must never reallocate while it is being written.
        try self_.pending.ensureTotalCapacity(allocator, 256);
        return self_;
    }

    pub fn deinit(self: *System) void {
        self.body_index.deinit(self.allocator);
        self.pending.deinit(self.allocator);
        self.world.deinit();
    }

    /// The render interpolation factor for this frame, 0..1.
    pub fn alpha(self: *const System) f32 {
        return self.driver.alpha;
    }

    // ── Load / unload ───────────────────────────────────────────────────────

    /// Creates the solver body for every entity carrying a `RigidBody2D` that
    /// does not have one yet, plus a shape for every `Collider2D` on it.
    ///
    /// Called after a scene loads, not per frame: this allocates, and spec §3.1
    /// forbids that inside the frame.
    pub fn syncLoad(self: *System, world: *World) void {
        // The query is held in a `var` and stepped from it: the cursor is
        // mutable state, and `world.query(..).next()` on a temporary does not
        // compile.
        var q = world.query(.{RigidBody2D});
        while (q.next()) |r| {
            const e = r.entity();
            const body = world.get(e, RigidBody2D) orelse continue;
            if (!body.isSimulated()) {
                self.createFor(world, e) catch {};
            }
        }
    }

    /// Destroys the solver body for an entity and clears its handle. Called from
    /// the entity sweep so a dead actor does not leave a body behind.
    pub fn removeEntity(self: *System, world: *World, entity: Entity) void {
        const body = world.get(entity, RigidBody2D) orelse return;
        if (!body.isSimulated()) return;
        // `world.get` returns `?*T`, so the capture IS the column pointer:
        // writing through it is how the cleared handle reaches the ECS.
        if (world.get(entity, Collider2D)) |c| {
            if (c.isLive()) {
                self.world.destroyShape(.{ .index = c.shape, .generation = c.generation });
                c.shape = Collider2D.invalid_shape;
            }
        }
        self.world.destroyBody(.{ .index = body.body, .generation = body.generation });
        _ = self.body_index.remove(bodyBits(.{
            .index = body.body,
            .generation = body.generation,
        }));
        body.body = RigidBody2D.invalid_body;
        self.dropped += 1;
    }

    /// The one place a body is actually created, so body+shape always agree.
    fn createFor(self: *System, world: *World, entity: Entity) !void {
        const rb = world.get(entity, RigidBody2D) orelse return;
        const xf = world.get(entity, Transform);
        const desc = physics.BodyDesc{
            .body_type = bodyTypeFromByte(rb.body_type),
            .position = if (xf) |t| t.position else .{},
            .rotation = if (xf) |t| t.rotation else 0.0,
            .linear_damping = rb.linear_damping,
            .angular_damping = rb.angular_damping,
            .gravity_scale = rb.gravity_scale,
            .fixed_rotation = rb.fixed_rotation,
            .allow_sleep = rb.allow_sleep,
            .is_bullet = rb.is_bullet,
        };
        const id = self.world.createBody(desc) orelse return error.WorldCreationFailed;
        const bits = bodyBits(id);
        rb.body = id.index;
        rb.generation = id.generation;
        // Reverse lookup for collision events. `catch {}` is right here: losing
        // one entry costs a single actor its contact callbacks, and failing the
        // whole load over it would be a worse trade.
        self.body_index.put(self.allocator, bits, entity) catch {};
        self.created += 1;

        // A body with no shape still simulates (it falls, it is just not
        // solid); that is a legitimate thing to want, so it is not an error.
        if (world.get(entity, Collider2D)) |c| {
            if (c.isLive()) return; // already has a shape
            const shape_id = self.world.createShape(id, shapeFromComponent(c.*), materialFromComponent(c.*)) orelse return;
            c.shape = shape_id.index;
            c.generation = shape_id.generation;
        }
    }

    // ── The frame ────────────────────────────────────────────────────────────

    /// One frame: down, step, up.
    ///
    /// `frame_dt` is wall-clock; the driver turns it into whole fixed steps.
    pub fn step(self: *System, world: *World, frame_dt: f32) u32 {
        self.pushDown(world);
        const t0 = @import("core").time.clockGetTimeNs();
        const ran = self.driver.advance(frame_dt);
        self.last_solver_ns = @intCast(@max(@import("core").time.clockGetTimeNs() -| t0, 0));
        if (ran > 0) {
            self.pullUp(world);
            self.publishContacts(world);
        }
        return ran;
    }

    /// ECS → solver. Runs every frame even when no step happened, because
    /// gameplay wrote velocity this frame and the next step must see it.
    fn pushDown(self: *System, world: *World) void {
        var q = world.query(.{RigidBody2D});
        while (q.next()) |r| {
            const entity = r.entity();
            const rb = world.get(entity, RigidBody2D) orelse continue;
            if (!rb.isSimulated()) continue;
            const id = physics.BodyId{ .index = rb.body, .generation = rb.generation };

            // The interpolation snapshot must be taken BEFORE the solver
            // overwrites the transform, and it has to be the position the
            // renderer last saw — not the one gameplay is about to write.
            //
            // `rb` is already a pointer INTO the column, so the snapshot is two
            // writes through it. Fetching the component a second time — which
            // is a slot lookup and an archetype walk — cost more than the
            // snapshot itself at 2 000 bodies.
            if (world.get(entity, Transform)) |t| {
                rb.prev_position = t.position;
                rb.prev_rotation = t.rotation;
            }

            // Only write when it actually differs.
            //
            // This is the single most important optimisation in the sync.
            // Box2D wakes a sleeping body when its velocity is set, so pushing
            // an unchanged value every frame means nothing is ever allowed to
            // sleep: a 2 000-body pile that should have gone to sleep after a
            // second instead re-solves 2 000 contacts forever, and the cost is
            // indistinguishable from a world that is genuinely busy.
            //
            // One cheap read to avoid an expensive solve.
            const current = self.world.getVelocity(id);
            if (!sameVelocity(current.linear, rb.linear_velocity) or
                current.angular != rb.angular_velocity)
            {
                self.world.setVelocity(id, .{
                    .linear = rb.linear_velocity,
                    .angular = rb.angular_velocity,
                });
            }

            // Same rule as velocity, for the same reason: setting gravity on a
            // sleeping body wakes it, so an unconditional call once per frame
            // is enough to stop anything in the world from ever sleeping.
            if (self.world.getGravityScale(id) != rb.gravity_scale) {
                self.world.setGravityScale(id, rb.gravity_scale);
            }

            // AFTER the velocity write, or it is cancelled by it. See the
            // section comment above: an impulse applied outside `step` has no
            // effect at all.
            if (self.pending.fetchRemove(entity)) |kv| {
                self.world.applyImpulse(id, kv.value, true);
            }
        }
    }

    /// Solver → ECS. Only after a step, so a frame that ran no step does not
    /// overwrite a transform with an unchanged solver value (which would reset
    /// the interpolation pair and make a still body look like it stuttered).
    ///
    /// Velocity comes back too, and that is load-bearing rather than cosmetic.
    /// `pushDown` writes the component's velocity into the solver every frame,
    /// so without reading it back the component keeps whatever gameplay last
    /// wrote — usually zero — and re-pins the body to that value 60 times a
    /// second. Every body would then accelerate for exactly one step per frame
    /// and fall at 1/60 of gravity, while still hashing deterministically. The
    /// round trip is what makes the solver, not the component, the owner of
    /// momentum.
    fn pullUp(self: *System, world: *World) void {
        var q = world.query(.{RigidBody2D});
        while (q.next()) |r| {
            const rb = world.get(r.entity(), RigidBody2D) orelse continue;
            if (!rb.isSimulated()) continue;
            const id = physics.BodyId{ .index = rb.body, .generation = rb.generation };
            const xf = self.world.getTransform(id);
            if (world.get(r.entity(), Transform)) |t| {
                t.position = xf.position;
                t.rotation = xf.rotation;
            }
            const v = self.world.getVelocity(id);
            rb.linear_velocity = v.linear;
            rb.angular_velocity = v.angular;
        }
    }

    // ── Driving a body from gameplay ─────────────────────────────────────────────
//
// Everything here goes through the COMPONENT, not the solver, and that is the
// whole design of this file.
//
// `pushDown` writes `RigidBody2D.linear_velocity` into the solver every frame,
// so a velocity set directly on the solver between frames is overwritten before
// it can take effect, and an impulse applied there is cancelled outright: the
// solver integrates it for zero steps and `pushDown` puts the old velocity
// back. Both read as "the call did nothing" from Lua, which is the worst kind
// of bug — the API is there, it returns no error, and a jump silently does not
// happen.
//
// So gameplay writes components, and impulses go through `pending_impulse`,
// which `pushDown` applies AFTER the velocity write so it survives.

/// Queues an impulse for the next step.
///
/// Held per entity rather than applied immediately, because "apply now" means
/// "apply after this frame's velocity has been re-asserted from the component".
pub fn pendingImpulse(self: *System, entity: Entity, impulse: physics.Vec2) void {
    self.pending.put(self.allocator, @bitCast(entity), impulse) catch {};
}

/// Sets velocity through the component, which is what actually takes effect.
pub fn setLinearVelocity(_: *System, world: *World, entity: Entity, v: physics.Vec2) void {
    const rb = world.get(entity, RigidBody2D) orelse return;
    if (!rb.isSimulated()) return;
    rb.linear_velocity = v;
}

/// The velocity the SOLVER has, which is authoritative after a step.
pub fn linearVelocity(self: *const System, world: *World, entity: Entity) ?physics.Vec2 {
    const body = self.bodyFor(world, entity) orelse return null;
    return self.world.getVelocity(body).linear;
}

/// The solver handle for an entity, or null when it is not simulated.
pub fn bodyFor(self: *const System, world: *World, entity: Entity) ?physics.BodyId {
    _ = self;
    const rb = world.get(entity, RigidBody2D) orelse return null;
    if (!rb.isSimulated()) return null;
    return .{ .index = rb.body, .generation = rb.generation };
}

// ── Contacts → signals ──────────────────────────────────────────────────────

/// Turns the solver's contact queue into `collision` signals.
///
/// A contact between two actors is emitted ONCE PER SIDE, not once for the
/// pair: `on_collision` is a method on `self`, and each actor has to be told in
/// its own right. Emitting once and hoping the listener can work out which side
/// it is would make every listener carry the bookkeeping the engine can do.
fn publishContacts(self: *System, world: *World) void {
    // Nothing subscribed, nothing published. The queue is a fixed budget and a
    // busy world fills it just by existing: 2 000 bodies in a pile produce
    // thousands of contacts a step, and turning each into an event that every
    // listener will discard is how a game that never asked for collisions
    // panics inside one.
    if (!world.signals.hasListeners(contact_signal)) return;
    var sink = ContactSink{ .system = self, .world = world, .emitted = 0 };
    self.world.pollContacts(visitContact, &sink);
    self.contacts_emitted += sink.emitted;
}

const ContactSink = struct {
    system: *System,
    world: *World,
    emitted: u32,

    /// Emits one side of a contact pair.
    fn side(self: *ContactSink, c: physics.Contact, self_body: physics.BodyId, other_body: physics.BodyId) void {
        const entity = self.system.entityFor(self_body) orelse return;
        const other = self.system.entityFor(other_body);
        // A body with no entity (a wall, the floor) still produces an event for
        // the actor that touched it — that is the case that matters, and
        // `other_index` comes out as `Entity.invalid` so the listener can tell
        // "I hit the level" from "I hit another actor".
        self.world.signals.emit(ContactEvent, contact_signal, .{
            .self_index = entity.index,
            .self_generation = entity.generation,
            .other_index = if (other) |o| o.index else Entity.invalid.index,
            .other_generation = if (other) |o| o.generation else 0,
            .approach_speed = c.approach_speed,
            .began = c.began,
            .ended = c.ended,
        });
        self.emitted += 1;
    }
};

fn visitContact(user: *anyopaque, c: physics.Contact) void {
    const sink: *ContactSink = @ptrCast(@alignCast(user));
    sink.side(c, c.a, c.b);
    sink.side(c, c.b, c.a);
}

// ── Queries ─────────────────────────────────────────────────────────────

    /// The entity behind a solver body, or null when the handle names something
    /// this system never issued (or has already retired).
    pub fn entityFor(self: *const System, body: physics.BodyId) ?Entity {
        if (body.isNone()) return null;
        return self.body_index.get(bodyBits(body));
    }

    /// A line-of-sight test, the primitive `ai.line_of_sight` needs.
    /// Returns null when nothing blocks the segment.
    pub fn lineOfSight(self: *const System, from: physics.Vec2, to: physics.Vec2) ?physics.RayHit {
        return self.world.castRay(from, to, .fixed);
    }

    /// The physics state hash used by the determinism test (spec §6). Walks the
    /// simulated bodies in registry order — which is spawn order — and mixes
    /// position, rotation and velocity with a fixed formula, so the same world
    /// always produces the same number.
    pub fn stateHash(_: *const System, world: *World) u64 {
        var h: u64 = 0xcbf29ce484222325; // FNV offset basis
        var q = world.query(.{RigidBody2D});
        while (q.next()) |r| {
            const rb = world.get(r.entity(), RigidBody2D) orelse continue;
            const xf = world.get(r.entity(), Transform);
            // Bit patterns, not floats: 0.1 + 0.2 != 0.3 must not be smoothed
            // over by a hash that rounds.
            h = mix(h, @as(u64, @as(u32, @bitCast(if (xf) |t| t.position.x else 0.0))));
            h = mix(h, @as(u64, @as(u32, @bitCast(if (xf) |t| t.position.y else 0.0))));
            h = mix(h, @as(u64, @as(u32, @bitCast(if (xf) |t| t.rotation else 0.0))));
            h = mix(h, @as(u64, @as(u32, @bitCast(rb.linear_velocity.x))));
            h = mix(h, @as(u64, @as(u32, @bitCast(rb.linear_velocity.y))));
            h = mix(h, @as(u64, @as(u32, @bitCast(rb.angular_velocity))));
        }
        return h;
    }
};

/// Exact float equality, deliberately.
///
/// This compares what the solver has against what the component asks for, and
/// the component was written FROM the solver a moment ago, so the values are
// bit-identical in the common case. An epsilon here would let a body that
// gameplay nudged by less than the epsilon drift silently — a small,
/// hard-to-find authority bug traded for a few nanoseconds.
fn sameVelocity(a: physics.Vec2, b: physics.Vec2) bool {
    return a.x == b.x and a.y == b.y;
}

fn mix(h: u64, v: u64) u64 {
    return (h ^ v) *% 0x100000001b3; // FNV prime
}

// ── Component ↔ port vocabulary ──────────────────────────────────────────────
//
// One place for both directions, so a new component field cannot be added to one
// side and forgotten on the other — which would silently drop a setting.

fn bodyTypeFromByte(b: u8) physics.BodyType {
    return switch (b) {
        0 => .fixed,
        1 => .kinematic,
        else => .dynamic,
    };
}

fn bodyTypeToByte(t: physics.BodyType) u8 {
    return switch (t) {
        .fixed => 0,
        .kinematic => 1,
        .dynamic => 2,
    };
}

fn shapeKindFromByte(b: u8) physics.ShapeKind {
    return switch (b) {
        0 => .box,
        1 => .circle,
        2 => .capsule,
        else => .polygon,
    };
}

fn shapeKindToByte(k: physics.ShapeKind) u8 {
    return switch (k) {
        .box => 0,
        .circle => 1,
        .capsule => 2,
        .polygon => 3,
    };
}

fn shapeFromComponent(c: Collider2D) physics.Shape {
    return .{
        .kind = shapeKindFromByte(c.kind),
        .half_extents = c.size,
        .radius = c.size.x,
        .offset = c.offset,
        .is_sensor = c.is_sensor,
    };
}

fn materialFromComponent(c: Collider2D) physics.Material {
    return .{ .density = c.density, .friction = c.friction, .restitution = c.restitution };
}

// ── Tests ────────────────────────────────────────────────────────────────────
//
// Pure conversions only: everything that needs a real solver is exercised by the
// determinism bench, which links Box2D and runs outside the test runner.

const testing = std.testing;

test "body types round-trip through their byte encoding" {
    for ([_]physics.BodyType{ .fixed, .kinematic, .dynamic }) |t| {
        const b = bodyTypeToByte(t);
        try testing.expectEqual(t, bodyTypeFromByte(b));
    }
}

test "shape kinds round-trip through their byte encoding" {
    for ([_]physics.ShapeKind{ .box, .circle, .capsule, .polygon }) |k| {
        const b = shapeKindToByte(k);
        try testing.expectEqual(k, shapeKindFromByte(b));
    }
}

test "an unknown body type byte degrades to dynamic, not to fixed" {
    // Dynamic is the safe default: a mistyped fixed body would silently become
    // immovable and nothing would move.
    try testing.expectEqual(physics.BodyType.dynamic, bodyTypeFromByte(200));
}

test "a collider becomes a port shape with its offset and sensor flag" {
    const c = Collider2D{
        .kind = 1, // circle
        .size = .{ .x = 4.0, .y = 4.0 },
        .offset = .{ .x = 0.0, .y = -2.0 },
        .is_sensor = true,
    };
    const s = shapeFromComponent(c);
    try testing.expectEqual(physics.ShapeKind.circle, s.kind);
    try testing.expectApproxEqAbs(@as(f32, 4.0), s.radius, 1e-9);
    try testing.expectApproxEqAbs(@as(f32, -2.0), s.offset.y, 1e-9);
    try testing.expect(s.is_sensor);

    const m = materialFromComponent(c);
    try testing.expectApproxEqAbs(@as(f32, 0.3), m.friction, 1e-9);
}

test "a fresh body component is not simulated" {
    const rb = RigidBody2D{};
    try testing.expect(!rb.isSimulated());
    // Defaults match the port's, so a default body behaves the same whichever
    // side authored it.
    try testing.expectEqual(@as(u8, 2), rb.body_type);
    try testing.expectApproxEqAbs(@as(f32, 1.0), rb.gravity_scale, 1e-9);
}

test "the components stay inside the archetype stride limit" {
    // The ECS copies a component with a fixed-size memcpy bounded by
    // `max_stride`; a component that outgrows it would corrupt the next column.
    try testing.expect(@sizeOf(RigidBody2D) <= components.max_stride);
    try testing.expect(@sizeOf(Collider2D) <= components.max_stride);
}
