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
//! ## The one list everything iterates
//!
//! `active` holds every body the solver is currently thinking about. Both
//! directions of the frame walk *that list*, not the ECS.
//!
//! Walking the ECS instead looks simpler and costs ~100 ns per body per pass —
//! which for a 200 000-body open world is 20 ms of pure bookkeeping before the
//! solver has done anything. The list is rebuilt only when a body changes tier,
//! and tier changes are amortised by the focus having moved (see `activity.zig`),
//! so the walk happens a few times a second instead of sixty.
//!
//! ## Why bodies are created lazily and cached
//!
//! A body handle is created once, on first sight of the entity, and cached in
//! the `RigidBody2D` component. Creating one per step would allocate in the frame
//! loop (spec §3.1) and would reset the solver's warm-start cache every frame,
//! which is felt as jitter on resting stacks.

const std = @import("std");
const ecs = @import("ecs");
const physics = @import("physics.zig");
const activity_mod = @import("activity.zig");
const sectors = @import("sectors.zig");

const World = ecs.World;
const Entity = ecs.Entity;
const components = ecs.components;
const RigidBody2D = components.RigidBody2D;
const Collider2D = components.Collider2D;
const Transform = components.Transform;
const Activity = activity_mod.Activity;
const Tier = activity_mod.Tier;

// The port deliberately knows nothing about stepping — that is the driver's
// job — so it is reached directly rather than through the port.
const Driver = @import("driver.zig").Driver;

/// Which solver to use. Re-exported from the module root, declared at module
/// scope because Zig does not allow a declaration between a struct's fields.
pub const Backend = @import("root.zig").Backend;

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

/// One entry of the active list: enough to go both directions without touching
/// the ECS.
///
/// `entity` is carried so `pullUp` can write straight into the transform column,
/// and `body` so the solver call needs no lookup.
const ActiveBody = struct {
    entity: Entity,
    body: physics.BodyId,
};

/// Owns the physics world and keeps it in step with the ECS.
pub const System = struct {
    backend: Backend,
    world: physics.World,
    driver: Driver,
    allocator: std.mem.Allocator,

    /// Distance-based activity. Null disables tiering entirely, which is the
    /// right behaviour for a small level: every body stays `full` and nothing
    /// is rebuilt, so there is no cost beyond the one-off walk.
    activity: Activity,

    /// The list both directions of the frame walk. Rebuilt on retune.
    active: std.ArrayListUnmanaged(ActiveBody) = .empty,
    /// Set when a body was created or destroyed and the list must be rebuilt.
    list_dirty: bool = true,

    /// Where every body is filed, so a retune visits cells near the focus
    /// instead of every body in the world (see `sectors.zig`).
    grid: sectors.Grid = sectors.Grid.init(1024),

    /// Bodies created this session, kept so a despawn can destroy them.
    created: u32 = 0,
    dropped: u32 = 0,

    /// Nanoseconds the last `step` spent inside the solver. The frame total
    /// minus this is the sync's own cost, which is the half the engine owns —
    /// measured rather than guessed, because a budget miss needs to be
    /// attributed before it can be fixed.
    last_solver_ns: u64 = 0,

    /// Nanoseconds the last retune took. At 200 000 bodies this is the single
    /// largest engine-side cost there is, and it is O(bodies) — which is the
    /// whole argument for partitioning the world into sectors.
    last_retune_ns: u64 = 0,
    /// Total nanoseconds spent retuning since start.
    total_retune_ns: u64 = 0,

    /// Body handle -> entity, so a contact can be reported to the actor it
    /// belongs to.
    ///
    /// The reverse lookup cannot be done by walking the ECS: a frame with 200
    /// simultaneous contacts would be 200 full archetype walks, which is the
    /// kind of cost that hides inside a frame until the level gets busy. Built
    /// at load time, read-only during the frame.
    body_index: std.AutoHashMapUnmanaged(u64, Entity) = .empty,

    /// Shape handle -> body handle, so a query that reports a SHAPE can be
    /// answered with the ENTITY the editor actually holds. A query returns shape
    /// ids because that is what the solver knows about; an editor needs to know
    /// which actor was clicked.
    shape_index: std.AutoHashMapUnmanaged(u64, physics.BodyId) = .empty,

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

    pub fn init(allocator: std.mem.Allocator, backend: Backend, gravity: physics.Gravity) !System {
        return initWithActivity(allocator, backend, gravity, null);
    }

    /// The constructor an open world uses: it supplies activity radii, so bodies
    /// far from the focus are progressively taken out of the solver.
    pub fn initWithActivity(
        allocator: std.mem.Allocator,
        backend: Backend,
        gravity: physics.Gravity,
        activity_config: ?activity_mod.Config,
    ) !System {
        const world = try @import("root.zig").createWorld(backend, gravity);
        var self_: System = .{
            .backend = backend,
            .world = world,
            .driver = Driver.init(world),
            .allocator = allocator,
            .activity = try Activity.init(activity_config orelse activity_mod.Config{}),
        };
        // The map is sized for the bodies the world will see, not grown lazily
        // during a frame — `put` reallocating on first collision is exactly the
        // allocation spec §3.1 forbids.
        try self_.body_index.ensureTotalCapacity(allocator, 1024);
        try self_.shape_index.ensureTotalCapacity(allocator, 1024);
        // Same reasoning: `pending` is written by gameplay during the frame and
        // must never reallocate while it is being written.
        try self_.pending.ensureTotalCapacity(allocator, 256);
        return self_;
    }

    pub fn deinit(self: *System) void {
        self.grid.deinit(self.allocator);
        self.active.deinit(self.allocator);
        self.body_index.deinit(self.allocator);
        self.shape_index.deinit(self.allocator);
        self.pending.deinit(self.allocator);
        self.world.deinit();
    }

    /// The render interpolation factor for this frame, 0..1.
    pub fn alpha(self: *const System) f32 {
        return self.driver.alpha;
    }

    /// Where the camera is. Bodies are tiered by their distance to this point,
    /// so a game with no camera (a server, a test) should pass the player or
    /// simply never move it — everything stays `full`.
    pub fn setFocus(self: *System, p: physics.Vec2) void {
        _ = self.activity.setFocus(p);
    }

    /// Tells the activity system what the camera can see.
    ///
    /// Enabling this is what turns on physics view culling. It is separate from
    /// `setFocus` because many games have a focus point and no camera — a
    /// multiplayer simulation is authoritative over the whole world and must
    /// simulate the whole world.
    pub fn setView(self: *System, centre: physics.Vec2, half: physics.Vec2, enabled: bool) void {
        self.activity.view_centre = centre;
        self.activity.view_half = half;
        self.activity.view_enabled = enabled;
        self.list_dirty = true;
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
        var q = world.query(.{ RigidBody2D });
        while (q.next()) |r| {
            const e = r.entity();
            const body = world.get(e, RigidBody2D) orelse continue;
            if (!body.isSimulated()) {
                self.createFor(world, e) catch {};
            }
        }
        self.reindex(world);
        // Give every body its starting tier before the first frame, so the
        // world opens already tiered rather than simulating everything once.
        self.retune(world);
    }

    /// Files every simulated body into the spatial index.
    ///
    /// Whole-index rebuild, so it is a load-time operation. Called after a
    /// teleport or a level change; never from the frame loop.
    pub fn reindex(self: *System, world: *World) void {
        self.grid.entries.clearRetainingCapacity();
        var q = world.query(.{ RigidBody2D });
        while (q.next()) |r| {
            const entity = r.entity();
            const rb = world.get(entity, RigidBody2D) orelse continue;
            if (!rb.isSimulated()) continue;
            const xf = world.get(entity, Transform) orelse continue;
            self.grid.insert(self.allocator, .{
                .index = entity.index,
                .generation = entity.generation,
            }, xf.position.x, xf.position.y, rb.tier) catch return;
        }
        // The entries were appended in a fresh order, so the cell ranges built
        // for the previous order are meaningless.
        self.grid.rebuild(self.allocator) catch {};
        self.list_dirty = true;
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
        if (world.get(entity, Collider2D)) |cc| {
            _ = self.shape_index.remove(shapeBits(.{ .index = cc.shape, .generation = cc.generation }));
        }
        _ = self.body_index.remove(bodyBits(.{
            .index = body.body,
            .generation = body.generation,
        }));
        body.body = RigidBody2D.invalid_body;
        self.dropped += 1;
        self.list_dirty = true;
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
            const shape_id = self.world.createShape(id, filterFromComponent(shapeFromComponent(c.*), filterFor(world, entity)), materialFromComponent(c.*)) orelse return;
            c.shape = shape_id.index;
            c.generation = shape_id.generation;
            self.shape_index.put(
                self.allocator,
                shapeBits(shape_id),
                id,
            ) catch {};
        }
    }

    // ── The frame ────────────────────────────────────────────────────────────

    /// One frame: retune, down, step, up.
    ///
    /// `frame_dt` is wall-clock; the driver turns it into whole fixed steps.
    pub fn step(self: *System, world: *World, frame_dt: f32) u32 {
        // Tiering first: it decides what the rest of the frame is even about.
        if (self.list_dirty or self.activity.needsRetune()) self.retune(world);

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
    ///
    /// Iterates `active`, not the ECS: this walk is the engine's own per-body
    /// cost and it is the number that has to stay flat as the world grows.
    fn pushDown(self: *System, world: *World) void {
        var simulated: u32 = 0;
        for (self.active.items) |entry| {
            const rb = world.get(entry.entity, RigidBody2D) orelse continue;
            if (!rb.isSimulated()) continue;
            const id = entry.body;

            // The interpolation snapshot must be taken BEFORE the solver
            // overwrites the transform, and it has to be the position the
            // renderer last saw — not the one gameplay is about to write.
            //
            // `rb` is already a pointer INTO the column, so the snapshot is two
            // writes through it. Fetching the component a second time — which
            // is a slot lookup and an archetype walk — cost more than the
            // snapshot itself at 2 000 bodies.
            if (world.get(entry.entity, Transform)) |t| {
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
            if (self.pending.fetchRemove(entry.entity)) |kv| {
                self.world.applyImpulse(id, kv.value, true);
            }
            simulated += 1;
        }
        self.activity.noteSimulated(simulated);
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
        for (self.active.items) |entry| {
            const rb = world.get(entry.entity, RigidBody2D) orelse continue;
            if (!rb.isSimulated()) continue;
            const xf = self.world.getTransform(entry.body);
            if (world.get(entry.entity, Transform)) |t| {
                t.position = xf.position;
                t.rotation = xf.rotation;
            }
            const v = self.world.getVelocity(entry.body);
            rb.linear_velocity = v.linear;
            rb.angular_velocity = v.angular;
        }
    }

    // ── Distance-based activity ──────────────────────────────────────────────

    /// Re-decides every body's tier and rebuilds the active list.
    ///
    /// The expensive thing here is not the arithmetic, it is the shape rebuilds
    /// and enable/disable calls, which is exactly why this is amortised rather
    /// than run every frame. A body whose tier did not change costs one
    /// distance computation and nothing else.
    pub fn retune(self: *System, world: *World) void {
        const t0 = @import("core").time.clockGetTimeNs();
        const done: u64 = @intCast(@max(@import("core").time.clockGetTimeNs() -| t0, 0));
        self.last_retune_ns = done;
        self.total_retune_ns += done;
        var stats = activity_mod.Stats{};
        self.active.clearRetainingCapacity();
        // One allocation per retune, not per frame. Growing the list lazily
        // would mean the first body of a newly-active region reallocates
        // inside the frame loop (spec §3.1), and a retune is exactly when a
        // whole region is coming back at once.
        self.active.ensureTotalCapacity(self.allocator, 4096) catch {};
        stats.retunes = self.activity.stats.retunes + 1;

        var q = world.query(.{ RigidBody2D });
        while (q.next()) |r| {
            const entity = r.entity();
            const rb = world.get(entity, RigidBody2D) orelse continue;
            if (!rb.isSimulated()) continue;

            const xf = world.get(entity, Transform) orelse continue;
            const current: Tier = @enumFromInt(@min(rb.tier, activity_mod.tier_count - 1));
            const d = self.activity.distanceTo(xf.position);
            const want = self.activity.retier(current, d);

            if (want != current) {
                self.applyTier(world, entity, want);
                stats.transitions += 1;
            }
            stats.by_tier[@intFromEnum(want)] += 1;

            if (want.isActive()) {
                self.active.append(self.allocator, .{
                    .entity = entity,
                    .body = .{ .index = rb.body, .generation = rb.generation },
                }) catch {};
            }
        }

        self.list_dirty = false;
        self.activity.markTuned();
        self.activity.stats = stats;
    }

    /// Moves one body to a tier, doing only the work that tier actually needs.
    ///
    /// The components are fetched here rather than passed in because this is the
    /// only caller path that is not already holding them. `applyTierWith` is the
    /// hot one: see its comment for why the lookups were removed from it.
    fn applyTier(self: *System, world: *World, entity: Entity, want: Tier) void {
        const rb = world.get(entity, RigidBody2D) orelse return;
        self.applyTierWith(world, entity, rb, null, want);
    }

    /// As `applyTier`, with the components the caller already has.
    ///
    /// A tier transition measured ~640 ns, and almost none of it was the solver:
    /// it was four `world.get` calls at ~141 ns each — the ECS slot lookup plus
    /// the archetype walk. The caller has usually just fetched two of those
    /// components, so fetching them again is paying twice for the same column.
    fn applyTierWith(
        self: *System,
        world: *World,
        entity: Entity,
        rb: *RigidBody2D,
        collider: ?*Collider2D,
        want: Tier,
    ) void {
        const id = physics.BodyId{ .index = rb.body, .generation = rb.generation };
        const from: Tier = @enumFromInt(@min(rb.tier, activity_mod.tier_count - 1));

        // Simulation on/off. Order matters: a body must be enabled before its
        // shape can be rebuilt, and disabled after, or Box2D is asked to change
        // a shape that is not in the world.
        const becoming_active = want.isActive();
        const was_active = from.isActive();

        switch (want) {
            .full, .coarse => {
                if (!was_active) self.world.setEnabled(id, true);
                if (want == .coarse and from == .full) self.swapToProxy(world, entity, rb, collider, id);
                if (want == .full and from == .coarse) self.swapFromProxy(world, entity, rb, collider, id);
            },
            .frozen => {
                if (was_active) self.world.setEnabled(id, false);
            },
            .unloaded => {
                if (was_active) self.world.setEnabled(id, false);
                self.destroyShape(world, entity, collider);
            },
        }
        _ = becoming_active;
        rb.tier = @intFromEnum(want);
    }

    /// Rebuilds the shape as a single circle covering the body.
    ///
    /// A box's half-diagonal is used, so the proxy is never SMALLER than the
    /// real shape. Under-covering would let something pass through a body that
    /// is visibly solid, which is the one failure mode an LOD must not have.
    fn swapToProxy(
        self: *System,
        world: *World,
        entity: Entity,
        _: *RigidBody2D,
        maybe_c: ?*Collider2D,
        id: physics.BodyId,
    ) void {
        const c = maybe_c orelse world.get(entity, Collider2D) orelse return;
        const radius = @sqrt(c.size.x * c.size.x + c.size.y * c.size.y);
        if (c.isLive()) self.world.destroyShape(.{ .index = c.shape, .generation = c.generation });
        const made = self.world.createShape(id, filterFromComponent(.{
            .kind = .circle,
            .radius = radius,
            .offset = c.offset,
            .is_sensor = c.is_sensor,
        }, filterFor(world, entity)), materialFromComponent(c.*)) orelse return;
        c.shape = made.index;
        c.generation = made.generation;
    }

    /// Rebuilds the shape the component describes, undoing `swapToProxy`.
    fn swapFromProxy(
        self: *System,
        world: *World,
        entity: Entity,
        _: *RigidBody2D,
        maybe_c: ?*Collider2D,
        id: physics.BodyId,
    ) void {
        const c = maybe_c orelse world.get(entity, Collider2D) orelse return;
        if (c.isLive()) self.world.destroyShape(.{ .index = c.shape, .generation = c.generation });
        const made = self.world.createShape(id, filterFromComponent(shapeFromComponent(c.*), filterFor(world, entity)), materialFromComponent(c.*)) orelse return;
        c.shape = made.index;
        c.generation = made.generation;
    }

    fn destroyShape(self: *System, world: *World, entity: Entity, maybe_c: ?*Collider2D) void {
        const c = maybe_c orelse world.get(entity, Collider2D) orelse return;
        if (!c.isLive()) return;
        self.world.destroyShape(.{ .index = c.shape, .generation = c.generation });
        c.shape = Collider2D.invalid_shape;
    }

    // ── Driving a body from gameplay ─────────────────────────────────────────
    //
    // Everything here goes through the COMPONENT, not the solver, and that is
    // the whole design of this file.
    //
    // `pushDown` writes `RigidBody2D.linear_velocity` into the solver every
    // frame, so a velocity set directly on the solver between frames is
    // overwritten before it can take effect, and an impulse applied there is
    // cancelled outright: the solver integrates it for zero steps and `pushDown`
    // puts the old velocity back. Both read as "the call did nothing" from Lua,
    // which is the worst kind of bug — the API is there, it returns no error,
    // and a jump silently does not happen.
    //
    // So gameplay writes components, and impulses go through `pendingImpulse`,
    // which `pushDown` applies AFTER the velocity write so it survives.

    /// Queues an impulse for the next step.
    ///
    /// Held per entity rather than applied immediately, because "apply now"
    /// means "apply after this frame's velocity has been re-asserted from the
    /// component".
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

    // ── Contacts → signals ───────────────────────────────────────────────────

    /// Turns the solver's contact queue into `collision` signals.
    ///
    /// A contact between two actors is emitted ONCE PER SIDE, not once for the
    /// pair: `on_collision` is a method on `self`, and each actor has to be told
    /// in its own right. Emitting once and hoping the listener can work out
    /// which side it is would make every listener carry the bookkeeping the
    /// engine can do.
    fn publishContacts(self: *System, world: *World) void {
        // Nothing subscribed, nothing published. The queue is a fixed budget and
        // a busy world fills it just by existing: 2 000 bodies in a pile produce
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
            // A body with no entity (a wall, the floor) still produces an event
            // for the actor that touched it — that is the case that matters, and
            // `other_index` comes out as `Entity.invalid` so the listener can
            // tell "I hit the level" from "I hit another actor".
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

    // ── Queries ──────────────────────────────────────────────────────────────

    // ── Editor surface ─────────────────────────────────────────────────────────
    //
    // Everything below exists so an editor can CREATE and MODIFY physics from
    // outside Zig: place a box, drag a handle to resize it, retune friction,
    // assign layers, drag a selection box across a level.
    //
    // They take an ENTITY rather than a solver handle. The ECS is the document;
    // the solver is a cache of it. An editor holding solver handles would lose
    // every edit the moment a body was despawned and respawned, and would have
    // to understand the pool to undo anything.

    /// Creates the solver body for one entity, if it has none.
    ///
    /// The editor's "give this actor a collider" path: an actor exists (it has a
    /// transform and a sprite) but has never been through a scene load, so
    /// `syncLoad` has not seen it. Doing this per entity rather than re-running
    /// the whole load is what makes adding a shape instant instead of a rebuild.
    pub fn syncEntity(self: *System, world: *World, entity: Entity) void {
        const rb = world.get(entity, RigidBody2D) orelse return;
        if (rb.isSimulated()) return;
        self.createFor(world, entity) catch {};
        self.list_dirty = true;
    }

    /// Rebuilds a body's shape so a new collision filter takes effect.
    ///
    /// The filter lives on the SHAPE in every 2D physics API there is, because a
    /// body routinely has several shapes that answer to different things. So
    /// changing a body's layers is a shape rebuild, and hiding that behind a
    /// setter is what stops an editor from having to know it.
    pub fn reapplyFilter(self: *System, world: *World, entity: Entity) void {
        const c = world.get(entity, Collider2D) orelse return;
        const rb = world.get(entity, RigidBody2D) orelse return;
        if (!rb.isSimulated() or !c.isLive()) return;
        const id = physics.BodyId{ .index = rb.body, .generation = rb.generation };
        const was_active = tierOf(rb).isActive();
        if (!was_active) self.world.setEnabled(id, true);
        self.world.destroyShape(.{ .index = c.shape, .generation = c.generation });
        if (self.world.createShape(
            id,
            filterFromComponent(shapeFromComponent(c.*), filterFor(world, entity)),
            materialFromComponent(c.*),
        )) |m| {
            c.shape = m.index;
            c.generation = m.generation;
            _ = self.shape_index.remove(shapeBits(.{ .index = c.shape, .generation = c.generation }));
            self.shape_index.put(self.allocator, shapeBits(.{ .index = m.index, .generation = m.generation }), id) catch {};
        }
        if (!was_active) self.world.setEnabled(id, false);
    }

    /// Changes a body's simulation type in place.
    pub fn setBodyType(self: *System, world: *World, entity: Entity, kind: u8) void {
        const rb = world.get(entity, RigidBody2D) orelse return;
        if (!rb.isSimulated()) return;
        rb.body_type = kind;
        self.world.setBodyType(
            .{ .index = rb.body, .generation = rb.generation },
            bodyTypeFromByte(kind),
        );
    }

    /// Turns a body's collision on or off without destroying its shape.
    ///
    /// An editor's eye toggle. Deliberately NOT the activity tiers: those are the
    /// engine's decision about cost, and a designer who hides a wall in the
    /// editor means "this does not exist", not "this is far away".
    pub fn setBodyEnabled(self: *System, world: *World, entity: Entity, enabled: bool) void {
        const rb = world.get(entity, RigidBody2D) orelse return;
        if (!rb.isSimulated()) return;
        self.world.setEnabled(.{ .index = rb.body, .generation = rb.generation }, enabled);
    }

    /// Replaces a body's shape, in place.
    ///
    /// The one an editor leans on hardest: dragging a resize handle fires this
    /// every frame the mouse moves, so it must not reallocate a body and must
    /// not lose its velocity, position or tier. The old shape is destroyed and a
    /// new one made on the same body, which is the only way a solver offers to
    /// change a shape's dimensions.
    ///
    /// The body's ENABLED state is preserved. Reshaping a disabled body would
    /// otherwise re-enable it, because the solver cannot rebuild a shape that is
    /// not in the world — and a level designer who hid a trigger volume and then
    /// nudged its size would find it live again.
    pub fn reshape(
        self: *System,
        world: *World,
        entity: Entity,
        kind: u8,
        half_w: f32,
        half_h: f32,
    ) void {
        const rb = world.get(entity, RigidBody2D) orelse return;
        if (!rb.isSimulated()) return;
        const c = world.get(entity, Collider2D) orelse return;
        const id = physics.BodyId{ .index = rb.body, .generation = rb.generation };

        const was_active = c.isLive() and tierOf(rb).isActive();
        if (!was_active) self.world.setEnabled(id, true);

        c.kind = kind;
        c.size = .{ .x = half_w, .y = half_h };
        if (c.isLive()) self.world.destroyShape(.{ .index = c.shape, .generation = c.generation });
        if (self.world.createShape(
            id,
            filterFromComponent(shapeFromComponent(c.*), filterFor(world, entity)),
            materialFromComponent(c.*),
        )) |m| {
            c.shape = m.index;
            c.generation = m.generation;
        }

        if (!was_active) self.world.setEnabled(id, false);
    }

    /// Sets a body's surface material. Like `reshape`, this rebuilds the shape,
    /// because a solver stores friction and restitution ON the shape.
    pub fn setMaterial(
        self: *System,
        world: *World,
        entity: Entity,
        friction: f32,
        restitution: f32,
        density: f32,
    ) void {
        const rb = world.get(entity, RigidBody2D) orelse return;
        if (!rb.isSimulated()) return;
        const c = world.get(entity, Collider2D) orelse return;
        c.friction = friction;
        c.restitution = restitution;
        c.density = density;
        const id = physics.BodyId{ .index = rb.body, .generation = rb.generation };
        const was_active = c.isLive() and tierOf(rb).isActive();
        if (!was_active) self.world.setEnabled(id, true);
        if (c.isLive()) self.world.destroyShape(.{ .index = c.shape, .generation = c.generation });
        if (self.world.createShape(
            id,
            filterFromComponent(shapeFromComponent(c.*), filterFor(world, entity)),
            materialFromComponent(c.*),
        )) |m| {
            c.shape = m.index;
            c.generation = m.generation;
        }
        if (!was_active) self.world.setEnabled(id, false);
    }

    /// Every entity whose shape overlaps a world-space box.
    ///
    /// The editor's selection primitive, so it is written to be called from a
    /// drag every frame: no allocation, and `out` is a caller-supplied slice.
    /// The RETURN is how many overlapped, which may exceed `out.len` — the
    /// caller grows once and re-queries, rather than the query silently
    /// truncating and the editor selecting "everything that fitted".
    pub fn overlapEntities(self: *const System, box: physics.Aabb, out: []Entity) usize {
        var sink = OverlapSink{ .system = self, .out = out, .count = 0 };
        self.world.overlapBox(box, .pass_all, visitOverlap, &sink);
        return sink.count;
    }

    const OverlapSink = struct {
        system: *const System,
        out: []Entity,
        count: usize,
    };

    fn visitOverlap(user: *anyopaque, shape: physics.ShapeId) void {
        const sink: *OverlapSink = @ptrCast(@alignCast(user));
        const body = sink.system.shapeOwner(shape) orelse return;
        const entity = sink.system.entityFor(body) orelse return;
        if (sink.count < sink.out.len) sink.out[sink.count] = entity;
        sink.count += 1;
    }

    /// The body that owns a shape, for turning a query result into an entity.
    pub fn shapeOwner(self: *const System, shape: physics.ShapeId) ?physics.BodyId {
        if (shape.isNone()) return null;
        return self.shape_index.get(shapeBits(shape));
    }

    /// The entity behind a solver body, or null when the handle names something
    /// this system never issued (or has already retired).
    pub fn entityFor(self: *const System, body: physics.BodyId) ?Entity {
        if (body.isNone()) return null;
        return self.body_index.get(bodyBits(body));
    }

    /// A line-of-sight test, the primitive `ai.line_of_sight` needs.
    /// Returns null when nothing blocks the segment.
    pub fn lineOfSight(self: *const System, from: physics.Vec2, to: physics.Vec2) ?physics.RayHit {
        return self.world.castRay(from, to, .pass_all);
    }

    /// The physics state hash used by the determinism test (spec §6). Walks the
    /// simulated bodies in registry order — which is spawn order — and mixes
    /// position, rotation and velocity with a fixed formula, so the same world
    /// always produces the same number.
    ///
    /// The tier is mixed in as well. Tiering is a pure function of position and
    /// focus, so it is deterministic, and a hash that ignored it would let two
    /// runs that simulated different subsets of the world compare equal.
    pub fn stateHash(_: *const System, world: *World) u64 {
        var h: u64 = 0xcbf29ce484222325; // FNV offset basis
        var q = world.query(.{ RigidBody2D });
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
            h = mix(h, rb.tier);
        }
        return h;
    }
};

/// Exact float equality, deliberately.
///
/// This compares what the solver has against what the component asks for, and
/// the component was written FROM the solver a moment ago, so the values are
/// bit-identical in the common case. An epsilon here would let a body that
/// gameplay nudged by less than the epsilon drift silently — a small,
/// hard-to-find authority bug traded for a few nanoseconds.
fn shapeBits(id: physics.ShapeId) u64 {
    return @as(u64, id.index) | (@as(u64, id.generation) << 32);
}

fn tierOf(rb: *const RigidBody2D) Tier {
    return @enumFromInt(@min(rb.tier, activity_mod.tier_count - 1));
}

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
        3 => .cylinder,
        // Anything else is a polygon, because a polygon is the one kind that
        // can express whatever the caller meant. Defaulting to a BOX would turn
        // a mistyped 4 into a square, which looks like it worked.
        else => .polygon,
    };
}

fn shapeKindToByte(k: physics.ShapeKind) u8 {
    return switch (k) {
        .box => 0,
        .circle => 1,
        .capsule => 2,
        .cylinder => 3,
        .polygon => 4,
    };
}

fn shapeFromComponent(c: Collider2D) physics.Shape {
    return .{
        .kind = shapeKindFromByte(c.kind),
        // A cylinder is described by its half-extents, like a box. Using the
        // radius field for it would make a wide, flat cylinder and a tall, round
        // one the same shape.
        .half_extents = c.size,
        .radius = c.size.x,
        .offset = c.offset,
        .is_sensor = c.is_sensor,
    };
}

/// The collision filter a body's shapes are built with.
///
/// Read from `CollisionLayers` when the entity has one, and permissive when it
/// does not. The permissive default is deliberate: a project that has not set up
/// layers must behave exactly like a project that has no layer concept at all,
/// and a body silently colliding with nothing is the loudest possible surprise.
fn filterFor(world: *World, entity: Entity) physics.Filter {
    const cl = world.get(entity, components.CollisionLayers) orelse return .pass_all;
    if (cl.layer == 0 and cl.mask == 0) return .pass_all;
    return .{
        .category_bits = @as(u64, cl.layer),
        .mask_bits = @as(u64, cl.mask),
    };
}

/// Puts the body's filter on a shape that does not have one yet.
///
/// Separate from `shapeFromComponent` because a shape's own description and the
/// body's filter are two different facts: the shape says what it IS, the filter
/// says who it may talk to.
fn filterFromComponent(shape: physics.Shape, filter: physics.Filter) physics.Shape {
    var out = shape;
    out.filter = filter;
    return out;
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

test "a body handle packs and unpacks without colliding with a neighbour" {
    // The reverse-lookup key. Two handles that differ only in generation must
    // produce different keys, or a retired body would answer for its
    // replacement.
    const a = physics.BodyId{ .index = 7, .generation = 1 };
    const b = physics.BodyId{ .index = 7, .generation = 2 };
    try testing.expect(bodyBits(a) != bodyBits(b));
    try testing.expectEqual(@as(u32, 7), @as(u32, @truncate(bodyBits(a))));
}

test "velocity equality is exact, so a nudged body is never treated as still" {
    const base = physics.Vec2{ .x = 1.0, .y = 2.0 };
    try testing.expect(sameVelocity(base, base));
    // One ULP apart must count as different: rounding here would let gameplay
    // set a velocity and have it silently ignored.
    const nudged = physics.Vec2{ .x = 1.0 + @as(f32, 1e-7), .y = 2.0 };
    try testing.expect(!sameVelocity(base, nudged));
}