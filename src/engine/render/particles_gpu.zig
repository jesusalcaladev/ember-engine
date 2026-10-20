//! M9 (continued) — the GPU particle backend: the emitters whose particles
//! live on the GPU instead of in the CPU's pool.
//!
//! ## What this module is
//!
//! The CPU side of the GPU particle path: it finds the emitters that ask for
//! it, packs their recipe into the layout the compute shader reads, and asks
//! the backend to run the simulation and draw the result.
//!
//! ## What it is NOT
//!
//! It is not a second particle system. The RULES are the CPU system's rules
//! (see `particles.zig`): the same drag, the same gravity, the same colour
//! interpolation, the same "the particle dies when its age reaches its life".
//! The two backends differ in WHERE the particles live, not in what they do —
//! an emitter that moves from one backend to the other has to look the same,
//! and a rule written twice has to be written the same way twice.
//!
//! ## The layout is a contract
//!
//! `GpuParams` here and `struct Params` in `shaders/particle_sim.wgsl` are the
//! same bytes. The same goes for `GpuParticle` and the shader's `Particle`.
//! Both sides are laid out field for field, and the test that checks it
//! compares the two sizes, because a layout that drifts is a shader that reads
//! the wrong numbers — and it fails as a picture, not as a crash.

const std = @import("std");
const core = @import("core");
const log = core.log.scoped("particles_gpu");
const render = @import("render.zig");
const ecs = @import("ecs");

const World = ecs.World;
const components = ecs.components;
const Transform = components.Transform;
const Emitter = components.ParticleEmitter2D;

/// The particles one emitter owns on the GPU. The same number in the shader.
pub const slice_size: u32 = 256;

/// The emitters the GPU can hold. Each one owns a slice of the pool.
pub const max_emitters: u32 = 256;

/// The flags in `GpuParams.flags`.
pub const flag_playing: u32 = 1 << 0;
pub const flag_one_shot: u32 = 1 << 1;
pub const flag_local: u32 = 1 << 2;

/// The recipe, in the layout the compute shader reads.
///
/// 104 bytes, and every field is at a fixed offset: the shader reads the same
/// bytes, so a field added here has to be added THERE at the same place.
pub const GpuParams = extern struct {
    pos: [2]f32 = .{ 0, 0 },
    prev_pos: [2]f32 = .{ 0, 0 },
    angle: [2]f32 = .{ 0, 0 },
    speed: [2]f32 = .{ 0, 0 },
    life: [2]f32 = .{ 0, 0 },
    size: [2]f32 = .{ 0, 0 },
    gravity: [2]f32 = .{ 0, 0 },
    extent: [2]f32 = .{ 0, 0 },
    drag: f32 = 0,
    spin: f32 = 0,
    rate: f32 = 0,
    shape: u32 = 0,
    seed: u32 = 0,
    color0: u32 = 0,
    color1: u32 = 0,
    capacity: u32 = 0,
    flags: u32 = 0,
    _pad: u32 = 0,
};

/// One particle, in the layout the shader reads and writes.
pub const GpuParticle = extern struct {
    pos: [2]f32 = .{ 0, 0 },
    vel: [2]f32 = .{ 0, 0 },
    age: f32 = 0,
    life: f32 = 0,
    size0: f32 = 0,
    size1: f32 = 0,
    rot: f32 = 0,
    rot_v: f32 = 0,
    color0: u32 = 0,
    color1: u32 = 0,
    alive: u32 = 0,
    next: u32 = 0,
    atlas: u32 = 0,
    _pad: u32 = 0,
};

/// The per-emitter state the GPU owns: the free list and the spawn
/// accumulator. The CPU never writes it.
pub const GpuState = extern struct {
    free_head: u32 = 0,
    free_count: u32 = 0,
    spawn_accum: u32 = 0,
    fired: u32 = 0,
    _pad: u32 = 0,
};

pub const Stats = struct {
    emitters: u32 = 0,
    simulated: u32 = 0,
    /// The emitters the GPU had no slice for. The answer, not an error: the
    /// pool is a budget, and a budget that a scene can overrun is not one.
    denied: u32 = 0,
};

/// The GPU particle system: the CPU's side of it.
pub const System = struct {
    allocator: std.mem.Allocator,
    /// The renderer, for the backend calls. Null when there is no GPU (a
    /// headless tool, a test), and then the system does nothing.
    renderer: ?render.Renderer = null,
    /// The packed recipes, one per emitter slice.
    params: std.ArrayListUnmanaged(GpuParams) = .empty,
    /// The emitters' previous positions, for the LOCAL space's delta.
    prev_pos: std.ArrayListUnmanaged([2]f32) = .empty,
    /// Which entity owns each slice. The slot in the component (`slab`) is
    /// the index, and the entity is what says whether the slot is still ours.
    owners: std.ArrayListUnmanaged(ecs.Entity) = .empty,
    stats: Stats = .{},

    pub fn init(allocator: std.mem.Allocator) System {
        return .{ .allocator = allocator };
    }

    pub fn deinit(self: *System) void {
        self.params.deinit(self.allocator);
        self.prev_pos.deinit(self.allocator);
        self.owners.deinit(self.allocator);
    }

    /// Reserves the room the system needs, before the frame loop starts.
    pub fn reserve(self: *System) !void {
        try self.params.ensureTotalCapacity(self.allocator, max_emitters);
        try self.prev_pos.ensureTotalCapacity(self.allocator, max_emitters);
        try self.owners.ensureTotalCapacity(self.allocator, max_emitters);
    }

    /// Whether the system can do anything at all.
    pub fn enabled(self: *const System) bool {
        return self.renderer != null;
    }

    /// Advances the GPU emitters by `dt`.
    ///
    /// The recipe is packed and uploaded, and the backend runs the simulation.
    /// The particles themselves never come back to the CPU: that is the whole
    /// point of the backend.
    pub fn fixedUpdate(self: *System, world: *World, dt: f32) void {
        self.stats = .{};
        const renderer = self.renderer orelse return;

        var q = world.query(.{ Transform, Emitter });
        while (q.nextBatch()) |batch| {
            const transforms = batch.slice(Transform);
            const emitters = batch.slice(Emitter);
            const n = batch.len();
            var i: usize = 0;
            while (i < n) : (i += 1) {
                const em = &emitters[i];
                if (em.backend != .gpu) continue;
                self.stats.emitters += 1;
                const entity = batch.entityAt(i);
                const t = &transforms[i];

                const slot = self.slotFor(entity, em) orelse {
                    self.stats.denied += 1;
                    continue;
                };
                self.stats.simulated += 1;
                self.pack(slot, em, t);
            }
        }

        // The dead owners: a slot whose entity is gone is given back, so a
        // scene that spawns and kills emitters does not run out of slices.
        self.sweep(world);

        if (self.params.items.len == 0) return;
        // The WHOLE array goes up, not just the active ones: the shader
        // indexes the recipes by the emitter's SLOT, and a hole in the middle
        // is a zeroed recipe (no rate, not playing) that costs nothing.
        const bytes = std.mem.sliceAsBytes(self.params.items);
        renderer.gpuParticlesSimulate(dt, bytes, @intCast(self.params.items.len));
    }

    /// Draws the GPU particles. The backend's own pass, over the same
    /// attachments the sprites use.
    pub fn draw(self: *System) void {
        const renderer = self.renderer orelse return;
        renderer.gpuParticlesDraw();
    }

    /// Gives back the slots whose entity is gone.
    ///
    /// A slice is a scarce thing — there are 256 of them — and an emitter
    /// that dies without giving its slice back would leak one every time.
    fn sweep(self: *System, world: *World) void {
        var i: usize = 0;
        while (i < self.owners.items.len) : (i += 1) {
            const owner = self.owners.items[i];
            if (owner.isInvalid()) continue;
            if (world.isAlive(owner)) continue;
            self.owners.items[i] = ecs.Entity.invalid;
        }
    }

    /// The slot an emitter owns, claiming one if it is new.
    fn slotFor(self: *System, entity: ecs.Entity, em: *Emitter) ?usize {
        // The component's own slot: the same field the CPU system uses, and
        // only one backend ever owns an emitter, so they never collide.
        if (em.slab != components.no_particle_slab and em.slab < self.owners.items.len) {
            if (self.owners.items[em.slab].eql(entity)) return em.slab;
            // Stale: the component travelled to a new entity (a prefab
            // instantiation copies the handle), so the slot is released.
            self.release(em.slab);
        }
        // A FREE slot (one whose owner died) comes before a new one: the
        // slices are the scarce thing, and a scene that spawns and kills
        // emitters would run out of them otherwise.
        var i: usize = 0;
        while (i < self.owners.items.len) : (i += 1) {
            if (!self.owners.items[i].isInvalid()) continue;
            self.owners.items[i] = entity;
            em.slab = @intCast(i);
            return i;
        }
        if (self.owners.items.len >= max_emitters) return null;
        const slot = self.owners.items.len;
        self.owners.append(self.allocator, entity) catch return null;
        self.params.append(self.allocator, GpuParams{}) catch return null;
        self.prev_pos.append(self.allocator, .{ 0, 0 }) catch return null;
        em.slab = @intCast(slot);
        return slot;
    }

    /// Gives a slot back.
    fn release(self: *System, slot: usize) void {
        if (slot >= self.owners.items.len) return;
        self.owners.items[slot] = ecs.Entity.invalid;
    }

    /// Packs an emitter's recipe into the slot's parameters.
    fn pack(self: *System, slot: usize, em: *Emitter, t: *const Transform) void {
        var p = GpuParams{};
        p.pos = .{ t.position.x, t.position.y };
        p.prev_pos = self.prev_pos.items[slot];
        p.angle = .{ em.angle.x, em.angle.y };
        p.speed = .{ em.speed.x, em.speed.y };
        p.life = .{ em.life.x, em.life.y };
        p.size = .{ em.size.x, em.size.y };
        p.gravity = .{ em.gravity.x, em.gravity.y };
        p.extent = .{ em.extent.x, em.extent.y };
        p.drag = em.drag;
        p.spin = em.spin;
        p.rate = em.rate;
        p.shape = @intFromEnum(em.shape);
        p.seed = em.seed;
        p.color0 = em.color_start;
        p.color1 = em.color_end;
        // The capacity is the emitter's own cap, and the slice is the hard
        // ceiling: an emitter that asks for more than the slice has gets the
        // slice, because the slice is what the pool has.
        p.capacity = @min(@as(u32, em.capacity), slice_size);
        p.flags = 0;
        if (em.playing) p.flags |= flag_playing;
        if (em.one_shot) p.flags |= flag_one_shot;
        if (em.space == .local) p.flags |= flag_local;
        self.params.items[slot] = p;
        // The position for the NEXT tick: the local space's delta is the
        // distance the emitter moved since the last one.
        self.prev_pos.items[slot] = .{ t.position.x, t.position.y };
    }
};

test "a GPU emitter's recipe is packed for the shader" {
    var world = ecs.World.init(std.testing.allocator);
    defer world.deinit();

    _ = try world.spawn(.{
        Transform{ .position = .{ .x = 10, .y = 20 } },
        Emitter{
            .backend = .gpu,
            .rate = 12.5,
            .life = .{ .x = 0.25, .y = 0.75 },
            .size = .{ .x = 4, .y = 8 },
            .gravity = .{ .x = 0, .y = -400 },
            .drag = 0.5,
            .spin = 1.5,
            .capacity = 64,
            .playing = true,
        },
    });

    // The null backend: the system asks it to simulate, and it counts what it
    // was given. The GPU path's CPU side is what is under test here.
    var backend = @import("backend_null.zig").Backend{};
    var sys = System.init(std.testing.allocator);
    defer sys.deinit();
    try sys.reserve();
    sys.renderer = backend.renderer();

    sys.fixedUpdate(&world, 1.0 / 60.0);
    try std.testing.expectEqual(@as(u32, 1), sys.stats.emitters);
    try std.testing.expectEqual(@as(u32, 1), sys.stats.simulated);
    try std.testing.expectEqual(@as(u32, 1), backend.gpu_particle_emitters);

    // The recipe, in the layout the shader reads.
    const p = sys.params.items[0];
    try std.testing.expectEqual(@as(f32, 10), p.pos[0]);
    try std.testing.expectEqual(@as(f32, 20), p.pos[1]);
    try std.testing.expectEqual(@as(f32, 12.5), p.rate);
    try std.testing.expectEqual(@as(f32, 0.25), p.life[0]);
    try std.testing.expectEqual(@as(f32, 0.75), p.life[1]);
    try std.testing.expectEqual(@as(f32, 4), p.size[0]);
    try std.testing.expectEqual(@as(f32, -400), p.gravity[1]);
    try std.testing.expectEqual(@as(f32, 0.5), p.drag);
    try std.testing.expectEqual(@as(f32, 1.5), p.spin);
    try std.testing.expectEqual(@as(u32, 64), p.capacity);
    try std.testing.expect(p.flags & flag_playing != 0);
    try std.testing.expect(p.flags & flag_one_shot == 0);

    // A CPU emitter is NOT the GPU system's business.
    _ = try world.spawn(.{ Transform{}, Emitter{ .backend = .cpu } });
    sys.fixedUpdate(&world, 1.0 / 60.0);
    try std.testing.expectEqual(@as(u32, 1), sys.stats.emitters);
    try std.testing.expectEqual(@as(u32, 1), sys.stats.simulated);
}

// ── The contract between the two sides ─────────────────────────────────────

test "the GPU particle layout is the same on both sides" {
    // The shader's `struct Params` is 104 bytes (the WGSL rounds the struct up
    // to its alignment, 8), `struct Particle` is 64 and `struct State` is 20.
    // If either drifts, the shader reads the wrong numbers and the failure is
    // a PICTURE, not a crash — which is exactly the kind of bug that ships.
    try std.testing.expectEqual(@as(usize, 104), @sizeOf(GpuParams));
    try std.testing.expectEqual(@as(usize, 64), @sizeOf(GpuParticle));
    try std.testing.expectEqual(@as(usize, 20), @sizeOf(GpuState));
}
