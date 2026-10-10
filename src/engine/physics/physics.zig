//! Physics port — the backend-agnostic contract (ROADMAP M4).
//!
//! This file is the same shape as `render/render.zig`: a `VTable` that a backend
//! fulfills, plus thin forwarding methods. That is deliberate, not decoration —
//! it is what makes the engine replaceable. Box2D today, PhysX or a custom
//! solver later: a backend implements this table, and nothing above it (the ECS
//! components, the fixed-step driver, the Lua bindings) changes. Swapping
//! engines is writing one file, not auditing the engine.
//!
//! ## Why the world is opaque
//!
//! Every handle here (`BodyId`, `ShapeId`) is engine-local. No caller stores a
//! `b2Body*`, and nothing above this file can: a Box2D world pointer would leak
//! the backend into the ECS, into save files and into the public API, which is
//! exactly the coupling `render.zig` exists to prevent.
//!
//! ## The values that DO cross the boundary
//!
//! Plain scalars and two-vectors, all trivially serializable. Save/load
//! (spec §6) writes these, never a vendor handle.

const std = @import("std");
const core_math = @import("core").math;

pub const Vec2 = core_math.Vec2;

/// spec §6: physics runs at a fixed 60 Hz. Not a default — the constant the
/// determinism contract is defined against.
pub const fixed_hz: f32 = 60.0;
pub const fixed_dt: f32 = 1.0 / fixed_hz;

/// spec §3.3: at most one catch-up step per frame. A slow frame must never
/// trigger a death spiral of accumulated simulation.
pub const max_catch_up_steps: u32 = 1;

/// How a body moves. Named after the concept, not after Box2D's typedef, so a
/// different backend maps onto it without the vocabulary leaking.
pub const BodyType = enum {
    /// Never moves. Walls, terrain, static platforms.
    fixed,
    /// Moved by the game, not by forces. Players on rails, moving platforms.
    kinematic,
    /// Moved by forces and collisions. The things that fall.
    dynamic,

    pub fn isMovable(self: BodyType) bool {
        return self != .fixed;
    }
};

/// An opaque body handle. `index` locates it in the backend; `generation`
/// invalidates stale handles so a recycled slot is not mistaken for the body
/// that used to live there (the same scheme the ECS uses for `Entity`).
pub const BodyId = struct {
    index: u32 = invalid_index,
    generation: u32 = 0,

    pub const invalid_index = std.math.maxInt(u32);
    pub const none = BodyId{};

    pub fn isNone(self: BodyId) bool {
        return self.index == invalid_index;
    }
};

pub const ShapeId = struct {
    index: u32 = invalid_index,
    generation: u32 = 0,

    pub const invalid_index = std.math.maxInt(u32);
    pub const none = ShapeId{};

    pub fn isNone(self: ShapeId) bool {
        return self.index == invalid_index;
    }
};

/// The shapes M4 supports. A polygon is carried as a fixed-size vertex buffer
/// so the struct stays plain data (no slices) and can live in a component.
pub const max_polygon_vertices = 8;

pub const ShapeKind = enum {
    box,
    circle,
    capsule,
    polygon,
};

pub const Shape = struct {
    kind: ShapeKind = .box,
    /// Half-extents for `box` (width/2, height/2).
    half_extents: Vec2 = .{ .x = 0.5, .y = 0.5 },
    /// Radius for `circle`; x also used as the radius for `capsule`, y as the
    /// half-height between the cap centres.
    radius: f32 = 0.5,
    /// Local offset from the body's transform. Lets one body carry several
    /// shapes in different places (a character's head and torso).
    offset: Vec2 = .{},
    /// Polygon vertices, local space, only for `kind == .polygon`.
    polygon: [max_polygon_vertices]Vec2 = @splat(Vec2{}),
    polygon_count: u8 = 0,
    /// True for a sensor: reports overlaps but generates no contact response.
    is_sensor: bool = false,
};

/// Surface response. Kept separate from `Shape` because two shapes on the same
/// body routinely want different materials (a bouncy ball, a grippy foot).
pub const Material = struct {
    density: f32 = 1.0,
    friction: f32 = 0.3,
    restitution: f32 = 0.0,
};

pub const Gravity = struct {
    x: f32 = 0.0,
    /// +Y is DOWN in this engine's world space (screen coordinates), so
    /// "down" is positive. Stating it here rather than assuming it is what
    /// keeps the next backend from guessing wrong.
    y: f32 = 9.8,
};

pub const BodyDesc = struct {
    body_type: BodyType = .dynamic,
    position: Vec2 = .{},
    rotation: f32 = 0.0,
    /// Velocity in units/second.
    linear_velocity: Vec2 = .{},
    /// Angular velocity in radians/second, positive clockwise on screen.
    angular_velocity: f32 = 0.0,
    linear_damping: f32 = 0.0,
    angular_damping: f32 = 0.0,
    /// Multiplies world gravity for this body. 0 is "unaffected" — how a
    /// flying enemy or a hovering platform is expressed, without the game
    /// having to fight the gravity vector each frame.
    gravity_scale: f32 = 1.0,
    /// A dynamic body with rotation locked: the default for a character or a
    /// platform that must not tip over. Cheaper than pinning the angular
    /// velocity every frame, and it does not fight the solver.
    fixed_rotation: bool = false,
    /// Starts asleep, so a scene of settled bodies costs nothing until touched.
    is_bullet: bool = false,
    allow_sleep: bool = true,
    awake: bool = true,
};

/// What a body looks like after a step. The ECS writes this into `Transform`.
pub const Transform = struct {
    position: Vec2 = .{},
    rotation: f32 = 0.0,
};

pub const Velocity = struct {
    linear: Vec2 = .{},
    angular: f32 = 0.0,
};

/// A ray hit, in the port's own vocabulary (no `b2CastResult` crosses).
pub const RayHit = struct {
    /// 0..1 along the ray, where 0 is `p1`.
    fraction: f32 = 0,
    point: Vec2 = .{},
    normal: Vec2 = .{},
    body: BodyId = .none,
    shape: ShapeId = .none,
};

/// Per-step counters, mirroring `render.FrameStats`: a CI run without a GPU (or
/// without a real solver) still measures the frame structure.
pub const StepStats = struct {
    bodies: u32 = 0,
    shapes: u32 = 0,
    contacts: u32 = 0,
    islands: u32 = 0,
    /// Bodies the solver has put to sleep.
    ///
    /// This is the number that decides whether an open world is affordable. A
    /// sleeping body costs nothing to step, so the cost of a scene is its
    /// AWAKE bodies, not its total. Watching this catch up to `bodies` is how
    /// you know a settled level has actually stopped costing money.
    sleeping: u32 = 0,
    /// Simulation time spent inside `step`, measured by the driver.
    step_ms: f32 = 0,
};

/// The contract. One row per capability; a backend that cannot do something
/// must say so in its own file rather than silently no-op.
/// One contact transition, in the port's vocabulary.
///
/// `began` distinguishes a touch starting from one persisting, which is the
/// difference between "a foot touched the ground" (an event) and "a foot is on
/// the ground" (a state). Collapsing the two is how jump logic ends up firing
/// every frame.
pub const Contact = struct {
    a: BodyId,
    b: BodyId,
    began: bool,
    ended: bool,
    /// Closing speed in units/second at the moment of the transition, so a
    /// landing can be told from a brush against a wall.
    approach_speed: f32,
};

pub const VTable = struct {
    const Self = @This();

    createWorld: *const fn (gravity: Gravity) ?*anyopaque,
    destroyWorld: *const fn (ctx: *anyopaque) void,

    createBody: *const fn (ctx: *anyopaque, desc: BodyDesc) ?BodyId,
    destroyBody: *const fn (ctx: *anyopaque, body: BodyId) void,
    setBodyType: *const fn (ctx: *anyopaque, body: BodyId, t: BodyType) void,
    setTransform: *const fn (ctx: *anyopaque, body: BodyId, xf: Transform) void,
    getTransform: *const fn (ctx: *anyopaque, body: BodyId) Transform,
    setVelocity: *const fn (ctx: *anyopaque, body: BodyId, v: Velocity) void,
    getVelocity: *const fn (ctx: *anyopaque, body: BodyId) Velocity,
    setGravityScale: *const fn (ctx: *anyopaque, body: BodyId, scale: f32) void,
    getGravityScale: *const fn (ctx: *anyopaque, body: BodyId) f32,
    setAwake: *const fn (ctx: *anyopaque, body: BodyId, awake: bool) void,
    /// Takes a body out of the simulation AND out of every spatial query.
    ///
    /// This is the single primitive the whole activity system rests on: a
    /// disabled body is not stepped and does not appear in the broadphase, so
    /// it costs nothing at all — not "a little", nothing. It is stronger than
    /// sleeping (which still occupies a slot and keeps its contacts) and much
    /// cheaper than destroying and rebuilding the body.
    setEnabled: *const fn (ctx: *anyopaque, body: BodyId, enabled: bool) void,
    /// An instantaneous change in momentum, applied at the body's centre of mass
    /// so it cannot spin the body — `applyImpulse` at the centre is the "jump"
    /// primitive, and a point impulse belongs in a separate call because the two
    /// answer different questions and conflating them makes jumps unpredictable.
    applyImpulse: *const fn (ctx: *anyopaque, body: BodyId, impulse: Vec2, wake: bool) void,

    createShape: *const fn (ctx: *anyopaque, body: BodyId, shape: Shape, mat: Material) ?ShapeId,
    destroyShape: *const fn (ctx: *anyopaque, shape: ShapeId) void,

    /// One fixed step. Never called with a variable dt (spec §6): the driver
    /// owns the accumulator and this only ever sees `fixed_dt`.
    step: *const fn (ctx: *anyopaque, dt: f32) void,

    castRay: *const fn (ctx: *anyopaque, p1: Vec2, p2: Vec2, filter: BodyType) ?RayHit,

    stats: *const fn (ctx: *anyopaque) StepStats,

    /// Drains the contacts queued since the last step.
    ///
    /// A VISITOR rather than a returned slice: the queue lives in the solver's
    /// memory and the engine must not copy or free it, and a callback keeps the
    /// borrow honest — there is no way for a caller to hold the pointer past the
    /// next step without the type system complaining.
    ///
    /// Draining is destructive, which is the point: a contact that began last
    /// step and still holds must not be reported again this step.
    pollContacts: *const fn (
        ctx: *anyopaque,
        visit: *const fn (user: *anyopaque, c: Contact) void,
        user: *anyopaque,
    ) void,
};

/// Reported alongside errors so a bug report says "box2d", not "physics".
pub const BackendName = []const u8;

pub const World = struct {
    vtable: *const VTable,
    ctx: *anyopaque,
    name: BackendName = "unknown",

    pub fn step(self: World, dt: f32) void {
        self.vtable.step(self.ctx, dt);
    }
    pub fn stats(self: World) StepStats {
        return self.vtable.stats(self.ctx);
    }
    pub fn castRay(self: World, p1: Vec2, p2: Vec2, filter: BodyType) ?RayHit {
        return self.vtable.castRay(self.ctx, p1, p2, filter);
    }
    pub fn createBody(self: World, desc: BodyDesc) ?BodyId {
        return self.vtable.createBody(self.ctx, desc);
    }
    pub fn destroyBody(self: World, body: BodyId) void {
        self.vtable.destroyBody(self.ctx, body);
    }
    pub fn setBodyType(self: World, body: BodyId, t: BodyType) void {
        self.vtable.setBodyType(self.ctx, body, t);
    }
    pub fn setTransform(self: World, body: BodyId, xf: Transform) void {
        self.vtable.setTransform(self.ctx, body, xf);
    }
    pub fn getTransform(self: World, body: BodyId) Transform {
        return self.vtable.getTransform(self.ctx, body);
    }
    pub fn setVelocity(self: World, body: BodyId, v: Velocity) void {
        self.vtable.setVelocity(self.ctx, body, v);
    }
    pub fn getVelocity(self: World, body: BodyId) Velocity {
        return self.vtable.getVelocity(self.ctx, body);
    }
    pub fn setGravityScale(self: World, body: BodyId, scale: f32) void {
        self.vtable.setGravityScale(self.ctx, body, scale);
    }
    pub fn getGravityScale(self: World, body: BodyId) f32 {
        return self.vtable.getGravityScale(self.ctx, body);
    }
    pub fn setAwake(self: World, body: BodyId, awake: bool) void {
        self.vtable.setAwake(self.ctx, body, awake);
    }
    /// Enable/disable participation in the simulation.
    pub fn setEnabled(self: World, body: BodyId, enabled: bool) void {
        self.vtable.setEnabled(self.ctx, body, enabled);
    }
    /// Impulse at the centre of mass. `wake` is a separate argument because the
    /// two questions are separate: "make it move" and "make it move EVEN IF it
    /// is asleep" are different requests, and a sleeping body is usually an
    /// optimization the caller does not know about.
    pub fn applyImpulse(self: World, body: BodyId, impulse: Vec2, wake: bool) void {
        self.vtable.applyImpulse(self.ctx, body, impulse, wake);
    }
    /// Drains the contacts queued by the last `step`.
    pub fn pollContacts(
        self: World,
        visit: *const fn (user: *anyopaque, c: Contact) void,
        user: *anyopaque,
    ) void {
        self.vtable.pollContacts(self.ctx, visit, user);
    }
    pub fn createShape(self: World, body: BodyId, shape: Shape, mat: Material) ?ShapeId {
        return self.vtable.createShape(self.ctx, body, shape, mat);
    }
    pub fn destroyShape(self: World, shape: ShapeId) void {
        self.vtable.destroyShape(self.ctx, shape);
    }
    pub fn deinit(self: World) void {
        self.vtable.destroyWorld(self.ctx);
    }
};

// ── Tests ────────────────────────────────────────────────────────────────────

const testing = std.testing;

test "handles round-trip and report their emptiness" {
    const none = BodyId{};
    try testing.expect(none.isNone());

    const real = BodyId{ .index = 7, .generation = 3 };
    try testing.expect(!real.isNone());
    try testing.expectEqual(@as(u32, 7), real.index);
    try testing.expectEqual(@as(u32, 3), real.generation);

    try testing.expect(ShapeId.none.isNone());
    try testing.expect(BodyType.dynamic.isMovable());
    try testing.expect(BodyType.kinematic.isMovable());
    try testing.expect(!BodyType.fixed.isMovable());
}

test "the fixed step is the one the determinism contract names" {
    // 60 Hz exactly: spec §6 defines determinism against this, and a change
    // here invalidates every recorded replay.
    try testing.expectEqual(@as(f32, 60.0), fixed_hz);
    try testing.expectApproxEqAbs(fixed_dt, 1.0 / 60.0, 1e-9);
    try testing.expectEqual(@as(u32, 1), max_catch_up_steps);
}

test "the default shape and material are sane" {
    const s = Shape{};
    try testing.expectEqual(ShapeKind.box, s.kind);
    try testing.expect(!s.is_sensor);
    try testing.expectEqual(@as(u8, 0), s.polygon_count);

    const m = Material{};
    try testing.expect(m.density > 0.0);
    try testing.expect(m.friction >= 0.0);
    try testing.expectEqual(@as(f32, 0.0), m.restitution);
}

test "gravity defaults to screen-space down" {
    // +Y grows downward here, so "down" is positive. A backend that assumes the
    // opposite silently launches every body off the top of the screen.
    const g = Gravity{};
    try testing.expectEqual(@as(f32, 0.0), g.x);
    try testing.expect(g.y > 0.0);
}
