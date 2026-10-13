//! M9 — the CPU particle system: a pool of particles driven by
//! `ParticleEmitter2D` components, integrated on the FIXED step and drawn
//! through the ordinary sprite batcher.
//!
//! ## Why the pool is SoA and not a list of structs
//!
//! The integration loop touches six floats per particle (position, velocity,
//! age, life) and the draw loop touches eight more (size, colour, atlas). In an
//! array-of-structs the integration loop streams 86-byte records to read 24
//! bytes of them — at 65k particles that is 5.6 MB of memory traffic to do 1.5
//! MB of work, and the L2 misses are what a "particles are slow" complaint is
//! actually about. Split arrays make the hot loop read exactly what it uses.
//!
//! ## The three rules everything here obeys
//!
//! 1. **Zero allocations in the frame** (spec §3.1): the pool, the slab table
//!    and the free lists are `reserve`d at load and `lock`ed. A full pool drops
//!    a spawn and counts it; a full instance buffer drops a particle and counts
//!    it. Nothing grows.
//! 2. **Determinism** (spec §6): the simulation runs on the fixed step with the
//!    fixed dt, and every emitter's randomness comes from its own xorshift
//!    seeded from the component. Same scene, same ticks, same particles.
//! 3. **The pool is a cache, not state**: what serializes is the recipe
//!    (`.zson` round-trips the component). A Play/Stop snapshot restores the
//!    EMITTER exactly; the live particles are re-derived, not restored, which is
//!    the honest contract for something that is "the visible consequence of a
//!    recipe integrated forward" and is documented on the component.
//!
//! ## Why emission is compaction-based
//!
//! Live particles occupy a contiguous `[first, first+count)` range per emitter,
//! and a death swaps the LAST live particle into the hole. No free list, no
//! per-particle orphan handling, no per-frame iteration over dead slots, and the
//! draw loop is a straight walk of a dense range. The cost is that a particle's
//! slot moves when one before it dies, which is invisible because nothing holds
//! a particle reference across frames — not Lua, not a signal, not a save file.

const std = @import("std");
const core = @import("core");
const log = core.log.scoped("particles");
const render = @import("render.zig");
const ecs = @import("ecs");

const World = ecs.World;
const Entity = ecs.Entity;
const components = ecs.components;
const Transform = components.Transform;
const Emitter = components.ParticleEmitter2D;
const two_d = @import("2d.zig");
const Renderer2D = two_d.Renderer2D;
const ViewRect = two_d.ViewRect;

pub const Options = struct {
    max_particles: u32 = 65_536,
    max_emitters: u16 = 256,
    max_per_emitter: u16 = 4096,
};

pub const Stats = struct {
    emitters: u32 = 0,
    simulated: u32 = 0,
    live: u32 = 0,
    spawned: u32 = 0,
    dropped_spawn: u32 = 0,
    slab_denied: u32 = 0,
    drawn: u32 = 0,
    culled: u32 = 0,
    sim_ns: u64 = 0,
    collect_ns: u64 = 0,
};

const Slab = struct {
    entity: Entity = Entity.invalid,
    first: u32 = 0,
    count: u32 = 0,
    capacity: u32 = 0,
    last_x: f32 = 0,
    last_y: f32 = 0,
    local: bool = false,
};

const FreeRange = struct {
    first: u32 = 0,
    len: u32 = 0,
};

pub const System = struct {
    allocator: std.mem.Allocator,
    options: Options = .{},

    px: []f32 = &.{},
    py: []f32 = &.{},
    vx: []f32 = &.{},
    vy: []f32 = &.{},
    ax: []f32 = &.{},
    ay: []f32 = &.{},
    drag: []f32 = &.{},
    age: []f32 = &.{},
    life: []f32 = &.{},
    size0: []f32 = &.{},
    size1: []f32 = &.{},
    rot: []f32 = &.{},
    rot_v: []f32 = &.{},
    color0: [][4]f32 = &.{},
    color1: [][4]f32 = &.{},
    atlas: []u8 = &.{},
    emitter: []u16 = &.{},
    pool_capacity: u32 = 0,
    pool_used: u32 = 0,

    slabs: []Slab = &.{},
    free_ranges: []FreeRange = &.{},
    free_range_count: usize = 0,
    free_slabs: []u16 = &.{},
    free_slab_count: usize = 0,

    locked: bool = false,
    stats: Stats = .{},

    /// The fixed step the particles integrate with, in seconds. Set once at
    /// load (the runtime's fixed_dt) so the render-time extrapolation and the
    /// emission accumulator agree on what a tick is.
    fixed_dt: f32 = 1.0 / 60.0,
    /// Mutable world reference for the `burst` method, updated each fixed tick.
    /// The `burst` public API needs the world to read the emitter/transform, and
    /// we cannot capture the runtime's mutable `world` in a hook closure. So the
    /// runtime sets this once per tick in `fixedUpdate`, and `burst` reads it.
    world: ?*World = null,

    pub fn init(allocator: std.mem.Allocator) System {
        return .{ .allocator = allocator };
    }

    /// Frees every array the pool owns. Safe to call twice (slices go empty).
    pub fn deinit(self: *System) void {
        const a = self.allocator;
        const names = [_][]const u8{
            "px",  "py",  "vx",  "vy",  "ax",   "ay",     "drag", "age",
            "life", "size0", "size1", "rot", "rot_v", "color0", "color1",
            "atlas", "emitter", "slabs", "free_ranges", "free_slabs",
        };
        inline for (names) |name| {
            const slice = @field(self, name);
            if (slice.len > 0) a.free(slice);
            @field(self, name) = &.{};
        }
        self.pool_capacity = 0;
        self.pool_used = 0;
    }

    pub fn setFixedDt(self: *System, dt: f32) void {
        self.fixed_dt = dt;
    }

    pub fn reserve(self: *System, opts: Options) !void {
        const a = self.allocator;
        self.options = opts;
        const n = opts.max_particles;
        self.px = try a.alloc(f32, n);
        self.py = try a.alloc(f32, n);
        self.vx = try a.alloc(f32, n);
        self.vy = try a.alloc(f32, n);
        self.ax = try a.alloc(f32, n);
        self.ay = try a.alloc(f32, n);
        self.drag = try a.alloc(f32, n);
        self.age = try a.alloc(f32, n);
        self.life = try a.alloc(f32, n);
        self.size0 = try a.alloc(f32, n);
        self.size1 = try a.alloc(f32, n);
        self.rot = try a.alloc(f32, n);
        self.rot_v = try a.alloc(f32, n);
        self.color0 = try a.alloc([4]f32, n);
        self.color1 = try a.alloc([4]f32, n);
        self.atlas = try a.alloc(u8, n);
        self.emitter = try a.alloc(u16, n);
        self.pool_capacity = n;
        self.slabs = try a.alloc(Slab, opts.max_emitters);
        self.free_ranges = try a.alloc(FreeRange, opts.max_emitters);
        self.free_slabs = try a.alloc(u16, opts.max_emitters);
        for (0..opts.max_emitters) |i| {
            self.slabs[i] = .{};
            self.free_slabs[i] = @intCast(opts.max_emitters - 1 - i);
        }
        self.free_slab_count = opts.max_emitters;
        self.free_range_count = 0;
    }

    pub fn lock(self: *System) void {
        self.locked = true;
    }

    pub fn beginFrame(self: *System) void {
        self.stats.drawn = 0;
        self.stats.culled = 0;
        self.stats.collect_ns = 0;
    }

    pub fn getStats(self: *const System) Stats {
        return self.stats;
    }

    // ── The fixed step ───────────────────────────────────────────────────────

    pub fn fixedUpdate(self: *System, world: *World, dt: f32) void {
        self.world = world; // capture for burst()
        const start = core.time.monotonicNs();
        defer self.stats.sim_ns = core.time.monotonicNs() - start;

        self.stats.emitters = 0;
        self.stats.simulated = 0;
        self.stats.spawned = 0;
        self.stats.dropped_spawn = 0;
        self.stats.slab_denied = 0;
        self.stats.live = 0;

        var q = world.query(.{ Transform, Emitter });
        while (q.nextBatch()) |batch| {
            const transforms = batch.slice(Transform);
            const emitters = batch.slice(Emitter);
            const n = batch.len();
            var i: usize = 0;
            while (i < n) : (i += 1) {
                const em = &emitters[i];
                self.stats.emitters += 1;
                if (em.backend != .cpu) continue;
                const entity = batch.entityAt(i);
                const t = &transforms[i];

                // Bind (or rebind after a stale handle). One query pass covers
                // both jobs because the entity and the transform are right here.
                if (!self.bind(em, entity, t)) continue;
                const slab = &self.slabs[em.slab];
                self.stats.simulated += 1;

                if (slab.local) {
                    const dx = t.position.x - slab.last_x;
                    const dy = t.position.y - slab.last_y;
                    if (dx != 0 or dy != 0) {
                        var k: u32 = 0;
                        while (k < slab.count) : (k += 1) {
                            const p = slab.first + k;
                            self.px[p] += dx;
                            self.py[p] += dy;
                        }
                    }
                    slab.last_x = t.position.x;
                    slab.last_y = t.position.y;
                }

                if (em.one_shot and !em.started_once) {
                    // A one-shot emitter fires its whole slab the instant it is
                    // bound — a spawner that detonates when the scene loads —
                    // and then stops. `started_once` is what makes it fire ONCE:
                    // a script that clears the particles and sets `playing`
                    // again gets a cycling emitter, not a second detonation.
                    em.started_once = true;
                    em.playing = false;
                    var k: u32 = 0;
                    while (k < em.capacity and slab.count < slab.capacity) : (k += 1) self.spawnOne(em, slab, t);
                }

                self.stats.spawned += self.emitTick(em, slab, t);
                self.integrate(slab, dt);
                em.live = @intCast(slab.count);
                self.stats.live += slab.count;
            }
        }
        self.reclaimDead(world);
    }

    /// Ensures `em` has a live slab for `entity`, claiming or re-claiming one.
    /// Returns false when the pool has no room for this emitter, which is an
    /// answer and not an error: the caller skips it and `stats.slab_denied`
    /// says why, exactly like the batcher's overflow rather than an allocation
    /// the frame is not allowed to make.
    ///
    /// Called from `fixedUpdate` (per entity) and from `burst` (per Lua call):
    /// a script that bursts an emitter before its first tick must get the same
    /// behaviour as one that waits for the loop, or the first explosion of
    /// every cutscene would be invisible.
    fn bind(self: *System, em: *Emitter, entity: Entity, t: *const Transform) bool {
        if (em.slab < self.slabs.len) {
            const slab = &self.slabs[em.slab];
            if (!slab.entity.isInvalid() and slab.entity.eql(entity)) return true;
            // Stale: the component travelled to a new entity (a prefab
            // instantiation copies the handle) or the slab was reclaimed.
            self.releaseSlab(em.slab);
        } else if (em.slab != components.no_particle_slab) {
            return false;
        }
        em.slab = self.claim(em, entity, t);
        return em.slab < self.slabs.len;
    }

    fn claim(self: *System, em: *Emitter, entity: Entity, t: *const Transform) u16 {
        if (em.slab < self.slabs.len) return em.slab;
        if (self.free_slab_count == 0) {
            self.stats.slab_denied += 1;
            return components.no_particle_slab;
        }
        const slab_index = self.free_slabs[0];
        self.free_slab_count -= 1;
        std.mem.copyForwards(u16, self.free_slabs[0..self.free_slab_count], self.free_slabs[1 .. self.free_slab_count + 1]);

        const want: u32 = @min(em.capacity, self.options.max_per_emitter);
        var best: usize = std.math.maxInt(usize);
        var i: usize = 0;
        while (i < self.free_range_count) : (i += 1) {
            if (self.free_ranges[i].len >= want) {
                if (best == std.math.maxInt(usize) or self.free_ranges[i].len < self.free_ranges[best].len) best = i;
            }
        }
        var first: u32 = undefined;
        if (best != std.math.maxInt(usize)) {
            first = self.free_ranges[best].first;
            const extra = self.free_ranges[best].len - want;
            if (extra > 0) {
                self.free_ranges[best].first = first + want;
                self.free_ranges[best].len = extra;
            } else {
                self.removeFreeRange(best);
            }
        } else if (self.pool_used + want <= self.pool_capacity) {
            first = self.pool_used;
            self.pool_used += want;
        } else {
            self.free_slabs[self.free_slab_count] = slab_index;
            self.free_slab_count += 1;
            self.stats.slab_denied += 1;
            return components.no_particle_slab;
        }

        if (em.seed == 0) em.seed = 0x9e3779b9; // 0 is xorshift's fixed point
        self.slabs[slab_index] = .{
            .entity = entity,
            .first = first,
            .count = 0,
            .capacity = want,
            .last_x = t.position.x,
            .last_y = t.position.y,
            .local = em.space == .local,
        };
        return slab_index;
    }

    fn releaseSlab(self: *System, slab_index: u16) void {
        const slab = &self.slabs[slab_index];
        if (slab.entity.isInvalid()) return;
        slab.entity = Entity.invalid;
        slab.count = 0;
        self.pushFreeRange(.{ .first = slab.first, .len = slab.capacity });
        self.free_slabs[self.free_slab_count] = slab_index;
        self.free_slab_count += 1;
    }

    fn pushFreeRange(self: *System, range: FreeRange) void {
        var i: usize = 0;
        while (i < self.free_range_count) : (i += 1) {
            const r = self.free_ranges[i];
            if (r.first + r.len == range.first) {
                self.free_ranges[i].len += range.len;
                return;
            }
            if (range.first + range.len == r.first) {
                self.free_ranges[i].first = range.first;
                self.free_ranges[i].len += range.len;
                return;
            }
        }
        if (self.free_range_count < self.free_ranges.len) {
            self.free_ranges[self.free_range_count] = range;
            self.free_range_count += 1;
        }
    }

    fn removeFreeRange(self: *System, index: usize) void {
        self.free_range_count -= 1;
        self.free_ranges[index] = self.free_ranges[self.free_range_count];
    }

    fn reclaimDead(self: *System, world: *World) void {
        var i: u16 = 0;
        while (i < self.slabs.len) : (i += 1) {
            const slab = &self.slabs[i];
            if (slab.entity.isInvalid()) continue;
            const slot = world.entityAtSlot(slab.entity.index) orelse {
                self.releaseSlab(i);
                continue;
            };
            if (!slot.eql(slab.entity) or !world.has(slot, Emitter)) self.releaseSlab(i);
        }
    }

    // ── Emission ─────────────────────────────────────────────────────────────

    fn emitTick(self: *System, em: *Emitter, slab: *Slab, t: *const Transform) u32 {
        if (!em.playing or slab.count >= slab.capacity) return 0;
        if (em.one_shot) em.playing = false;
        em.accumulator += em.rate * self.fixed_dt;
        var spawned: u32 = 0;
        while (em.accumulator >= 1.0) {
            em.accumulator -= 1.0;
            if (slab.count >= slab.capacity) {
                self.stats.dropped_spawn += 1;
                em.accumulator = 0;
                break;
            }
            self.spawnOne(em, slab, t);
            spawned += 1;
        }
        return spawned;
    }

    fn spawnOne(self: *System, em: *Emitter, slab: *Slab, t: *const Transform) void {
        const p = slab.first + slab.count;
        var ex: f32 = 0;
        var ey: f32 = 0;
        switch (em.shape) {
            .point => {},
            .box => {
                ex = (randUnit(em) * 2 - 1) * em.extent.x;
                ey = (randUnit(em) * 2 - 1) * em.extent.y;
            },
            .disc => {
                const r = em.extent.x * @sqrt(randUnit(em));
                const a = randUnit(em) * std.math.pi * 2;
                ex = @cos(a) * r;
                ey = @sin(a) * r;
            },
        }
        const ang = em.angle.x + randUnit(em) * (em.angle.y - em.angle.x);
        const speed = em.speed.x + randUnit(em) * (em.speed.y - em.speed.x);
        self.px[p] = t.position.x + ex;
        self.py[p] = t.position.y + ey;
        self.vx[p] = @cos(ang) * speed;
        self.vy[p] = @sin(ang) * speed;
        self.ax[p] = em.gravity.x;
        self.ay[p] = em.gravity.y;
        self.drag[p] = em.drag;
        self.age[p] = 0;
        self.life[p] = em.life.x + randUnit(em) * (em.life.y - em.life.x);
        self.size0[p] = em.size.x;
        self.size1[p] = em.size.y;
        self.rot[p] = 0;
        self.rot_v[p] = em.spin;
        self.color0[p] = components.unpackParticleColor(em.color_start);
        self.color1[p] = components.unpackParticleColor(em.color_end);
        self.atlas[p] = em.atlas;
        self.emitter[p] = em.slab;
        slab.count += 1;
    }

    /// Emits `count` particles immediately, up to the slab's room. The Lua
    /// `particles.burst` path: an explosion is authored the instant it happens.
    /// Returns how many were emitted.
    pub fn burst(self: *System, e: Entity, count: u32) u32 {
        const world = self.world orelse return 0;
        const em = world.get(e, Emitter) orelse return 0;
        const t = world.get(e, Transform) orelse return 0;
        if (em.backend != .cpu) return 0;
        // Claim on demand: `particles.burst` from a script's `start()` runs
        // before the emitter's first tick, and a Lua API that silently does
        // nothing until the loop catches up is a Lua API nobody trusts.
        if (!self.bind(em, e, t)) return 0;
        if (em.one_shot) em.started_once = true;
        const slab = &self.slabs[em.slab];
        var spawned: u32 = 0;
        while (spawned < count and slab.count < slab.capacity) : (spawned += 1) self.spawnOne(em, slab, t);
        em.live = @intCast(slab.count);
        self.stats.spawned += spawned;
        self.stats.live += slab.count;
        return spawned;
    }

    /// Kills every particle of one entity's slab, or of all of them when
    /// `e` is null. The recipe survives: `particles.clear` is a reset, not a
    /// removal.
    pub fn clear(self: *System, e: ?Entity) void {
        var i: u16 = 0;
        while (i < self.slabs.len) : (i += 1) {
            const slab = &self.slabs[i];
            if (slab.entity.isInvalid()) continue;
            if (e) |target| {
                if (!slab.entity.eql(target)) continue;
            }
            slab.count = 0;
        }
    }

    // ── Integration ──────────────────────────────────────────────────────────

    fn integrate(self: *System, slab: *Slab, dt: f32) void {
        var k: u32 = 0;
        while (k < slab.count) {
            const p = slab.first + k;
            var v = self.vx[p];
            var w = self.vy[p];
            const d = self.drag[p];
            if (d != 0) {
                const decay = @exp(-d * dt);
                v *= decay;
                w *= decay;
            }
            v += self.ax[p] * dt;
            w += self.ay[p] * dt;
            self.vx[p] = v;
            self.vy[p] = w;
            self.px[p] += v * dt;
            self.py[p] += w * dt;
            self.age[p] += dt;
            if (self.age[p] >= self.life[p]) {
                self.killAt(slab, k);
                continue;
            }
            self.rot[p] += self.rot_v[p] * dt;
            k += 1;
        }
    }

    fn killAt(self: *System, slab: *Slab, k: u32) void {
        const last = slab.first + slab.count - 1;
        const p = slab.first + k;
        if (p != last) {
            self.px[p] = self.px[last];
            self.py[p] = self.py[last];
            self.vx[p] = self.vx[last];
            self.vy[p] = self.vy[last];
            self.ax[p] = self.ax[last];
            self.ay[p] = self.ay[last];
            self.drag[p] = self.drag[last];
            self.age[p] = self.age[last];
            self.life[p] = self.life[last];
            self.size0[p] = self.size0[last];
            self.size1[p] = self.size1[last];
            self.rot[p] = self.rot[last];
            self.rot_v[p] = self.rot_v[last];
            self.color0[p] = self.color0[last];
            self.color1[p] = self.color1[last];
            self.atlas[p] = self.atlas[last];
            self.emitter[p] = self.emitter[last];
        }
        slab.count -= 1;
    }

    // ── The draw path ────────────────────────────────────────────────────────

    pub fn collect(
        self: *System,
        r2d: *Renderer2D,
        world: *World,
        alpha: f32,
        view: ?ViewRect,
    ) void {
        const start = core.time.monotonicNs();
        defer self.stats.collect_ns = core.time.monotonicNs() - start;

        var i: u16 = 0;
        while (i < self.slabs.len) : (i += 1) {
            const slab = &self.slabs[i];
            if (slab.entity.isInvalid() or slab.count == 0) continue;
            const em = world.get(slab.entity, Emitter) orelse continue;
            const t = world.get(slab.entity, Transform) orelse continue;
            var ox: f32 = 0;
            var oy: f32 = 0;
            if (slab.local) {
                ox = t.position.x - slab.last_x;
                oy = t.position.y - slab.last_y;
            }
            const layer: u8 = @intCast(@min(em.layer, 255));

            var k: u32 = 0;
            while (k < slab.count) : (k += 1) {
                const p = slab.first + k;
                const age = self.age[p];
                const life = self.life[p];
                const tfrac = if (life > 0) std.math.clamp(age / life, 0, 1) else 1;
                const x = self.px[p] + ox + self.vx[p] * alpha * self.fixed_dt;
                const y = self.py[p] + oy + self.vy[p] * alpha * self.fixed_dt;
                const half = (self.size0[p] + (self.size1[p] - self.size0[p]) * tfrac) * 0.5;
                if (view) |v| {
                    if (!v.sees(x, y, half, half)) {
                        self.stats.culled += 1;
                        continue;
                    }
                }
                const c0 = self.color0[p];
                const c1 = self.color1[p];
                var inst = render.SpriteInstance{
                    .pos = .{ x, y },
                    .half = .{ half, half },
                    .uv = .{
                        render.toUnorm16(em.uv[0]),
                        render.toUnorm16(em.uv[1]),
                        render.toUnorm16(em.uv[2]),
                        render.toUnorm16(em.uv[3]),
                    },
                    .color = .{
                        render.toUnorm8(c0[0] + (c1[0] - c0[0]) * tfrac),
                        render.toUnorm8(c0[1] + (c1[1] - c0[1]) * tfrac),
                        render.toUnorm8(c0[2] + (c1[2] - c0[2]) * tfrac),
                        render.toUnorm8(c0[3] + (c1[3] - c0[3]) * tfrac),
                    },
                    .slot = self.atlas[p],
                    .shape = 0,
                    .layer = layer,
                };
                if (self.rot_v[p] != 0) rotateUv(&inst, self.rot[p]);
                if (r2d.pushInstance(inst)) self.stats.drawn += 1 else self.stats.culled += 1;
            }
        }
    }
};

/// xorshift32, one draw per call. The state lives in the COMPONENT so a Play
/// snapshot restores the sequence, not just the parameters (spec §6): two runs
/// from the same scene must spawn the same particles.
fn randUnit(em: *Emitter) f32 {
    var x = em.seed;
    x ^= x << 13;
    x ^= x >> 17;
    x ^= x << 5;
    em.seed = x;
    return @as(f32, @floatFromInt(x >> 8)) * (1.0 / 16777216.0);
}

/// Rotates a quad's UV rect around its centre by `angle` radians, in place.
fn rotateUv(inst: *render.SpriteInstance, angle: f32) void {
    const ua: f32 = @as(f32, @floatFromInt(inst.uv[0])) / 65535.0;
    const va: f32 = @as(f32, @floatFromInt(inst.uv[1])) / 65535.0;
    const ub: f32 = @as(f32, @floatFromInt(inst.uv[2])) / 65535.0;
    const vb: f32 = @as(f32, @floatFromInt(inst.uv[3])) / 65535.0;
    const cu = (ua + ub) * 0.5;
    const cv = (va + vb) * 0.5;
    const hu = (ub - ua) * 0.5;
    const hv = (vb - va) * 0.5;
    const s = @sin(angle);
    const c = @cos(angle);
    const ru = hu * c - hv * s;
    const rv = hu * s + hv * c;
    const su = hv * c + hu * s;
    const sv = hv * s - hu * c;
    inst.uv = .{
        render.toUnorm16(cu + su - ru),
        render.toUnorm16(cv + sv - rv),
        render.toUnorm16(cu + su + ru),
        render.toUnorm16(cv + sv + rv),
    };
}

// ── Tests ────────────────────────────────────────────────────────────────────

const testing = std.testing;

fn testSystem(a: std.mem.Allocator, opts: Options) !System {
    var sys = System.init(a);
    try sys.reserve(opts);
    sys.lock();
    return sys;
}

/// The slab an entity's emitter currently owns. Tests resolve the slab this
/// way rather than assuming slab 0: the free list pops from the top, so the
/// FIRST claim is the LAST slab index and a test hardcoding 0 would pass only
/// by accident on a fresh system.
fn slabOf(sys: *System, world: *World, e: Entity) *Slab {
    const index = world.get(e, Emitter).?.slab;
    return &sys.slabs[index];
}

fn testWorldWithEmitter(a: std.mem.Allocator, em: Emitter) !struct { world: World, entity: Entity } {
    var world = World.init(a);
    try world.reserveEntities(16);
    try world.reserve(.{ Transform, Emitter }, 16);
    const e = try world.spawn(.{ Transform{ .position = .{ .x = 0, .y = 0 } }, em });
    return .{ .world = world, .entity = e };
}

test "an emitter claims a slab and spawns on the first tick" {
    const a = testing.allocator;
    var sys = try testSystem(a, .{ .max_particles = 1024, .max_emitters = 8 });
    defer sys.deinit();
    var w = try testWorldWithEmitter(a, Emitter{ .rate = 10, .capacity = 32 });
    defer w.world.deinit();

    // 60 ticks is one second: a rate of 10/s must have emitted about ten, and
    // the accumulator's fraction must be carried rather than dropped (a rate
    // of 10 at 60 Hz is one particle every 6 ticks, not two and then eight
    // ticks of nothing).
    var i: usize = 0;
    while (i < 60) : (i += 1) sys.fixedUpdate(&w.world, 1.0 / 60.0);
    const slab = slabOf(&sys, &w.world, w.entity);
    try testing.expect(!slab.entity.isInvalid());
    try testing.expect(slab.count >= 9 and slab.count <= 11);
    try testing.expectEqual(@as(u16, 32), slab.capacity);
    try testing.expectEqual(slab.count, w.world.get(w.entity, Emitter).?.live);
}

test "particles die at the end of their life and the slab shrinks" {
    const a = testing.allocator;
    var sys = try testSystem(a, .{ .max_particles = 256, .max_emitters = 4 });
    defer sys.deinit();
    var w = try testWorldWithEmitter(a, Emitter{
        .rate = 0, // not emitting: this test is about DEATH, not about churn
        .capacity = 64,
        .life = .{ .x = 0.1, .y = 0.1 },
    });
    defer w.world.deinit();

    // The system needs the world to read the emitter config for burst().
    // In a real run, fixedUpdate sets this each tick; in tests we set it manually.
    sys.world = &w.world;
    _ = sys.burst(w.entity, 24);
    try testing.expectEqual(@as(u32, 24), slabOf(&sys, &w.world, w.entity).count);
    // 0.1 s of life = 6 ticks each; 12 ticks is enough for all 24 to die.
    var i: usize = 0;
    while (i < 12) : (i += 1) sys.fixedUpdate(&w.world, 1.0 / 60.0);
    try testing.expectEqual(@as(u32, 0), slabOf(&sys, &w.world, w.entity).count);
    try testing.expectEqual(@as(u32, 0), sys.stats.live);
}

test "a rate that is not a whole particle per tick is carried, not truncated" {
    const a = testing.allocator;
    var sys = try testSystem(a, .{ .max_particles = 256, .max_emitters = 4 });
    defer sys.deinit();
    var w = try testWorldWithEmitter(a, Emitter{
        .rate = 2.5,
        .capacity = 64,
        .life = .{ .x = 60, .y = 60 }, // nothing dies during the test
    });
    defer w.world.deinit();

    var i: usize = 0;
    while (i < 120) : (i += 1) sys.fixedUpdate(&w.world, 1.0 / 60.0);
    // Two seconds at 2.5/s is 5, exactly. Truncating the accumulator per tick
    // would give 2 (one every other tick at 1/60 s).
    try testing.expectEqual(@as(u32, 5), slabOf(&sys, &w.world, w.entity).count);
}

test "a burst fills the slab once and one_shot stops the emitter" {
    const a = testing.allocator;
    var sys = try testSystem(a, .{ .max_particles = 256, .max_emitters = 4 });
    defer sys.deinit();
    var w = try testWorldWithEmitter(a, Emitter{
        .rate = 0,
        .capacity = 16,
        .one_shot = true,
    });
    defer w.world.deinit();

    // The one_shot path fills the slab at claim time and stops.
    sys.fixedUpdate(&w.world, 1.0 / 60.0);
    try testing.expectEqual(@as(u32, 16), slabOf(&sys, &w.world, w.entity).count);
    try testing.expect(!w.world.get(w.entity, Emitter).?.playing);

    // Later ticks add nothing: it stopped.
    const before = slabOf(&sys, &w.world, w.entity).count;
    sys.fixedUpdate(&w.world, 1.0 / 60.0);
    try testing.expectEqual(before, slabOf(&sys, &w.world, w.entity).count);
}

test "capacity is a hard cap: excess spawns are dropped and counted" {
    const a = testing.allocator;
    var sys = try testSystem(a, .{ .max_particles = 1024, .max_emitters = 4, .max_per_emitter = 64 });
    defer sys.deinit();
    var w = try testWorldWithEmitter(a, Emitter{ .rate = 1000, .capacity = 8 });
    defer w.world.deinit();

    sys.fixedUpdate(&w.world, 1.0 / 60.0);
    try testing.expectEqual(@as(u32, 8), slabOf(&sys, &w.world, w.entity).count);
    try testing.expect(sys.stats.dropped_spawn > 0);
}

test "a despawned emitter's slab is reclaimed and its range reused" {
    const a = testing.allocator;
    var sys = try testSystem(a, .{ .max_particles = 1024, .max_emitters = 4 });
    defer sys.deinit();
    var w = try testWorldWithEmitter(a, Emitter{ .rate = 30, .capacity = 32 });
    defer w.world.deinit();

    sys.fixedUpdate(&w.world, 1.0 / 60.0);
    const w0_slab = w.world.get(w.entity, Emitter).?.slab;
    const used_before = sys.pool_used;
    _ = w.world.despawn(w.entity);
    sys.fixedUpdate(&w.world, 1.0 / 60.0);
    try testing.expect(sys.slabs[w0_slab].entity.isInvalid());
    // The range went back to the free list, so the next claim reuses it rather
    // than growing the bump cursor.
    var w2 = try testWorldWithEmitter(a, Emitter{ .rate = 30, .capacity = 32 });
    defer w2.world.deinit();
    sys.fixedUpdate(&w2.world, 1.0 / 60.0);
    try testing.expectEqual(used_before, sys.pool_used);
    try testing.expectEqual(@as(u32, 0), slabOf(&sys, &w2.world, w2.entity).first);
}

test "the same seed spawns the same particles (determinism, spec §6)" {
    const a = testing.allocator;
    var results: [2][]f32 = undefined;
    for (0..2) |run| {
        var sys = try testSystem(a, .{ .max_particles = 1024, .max_emitters = 4 });
        defer sys.deinit();
        var w = try testWorldWithEmitter(a, Emitter{
            .rate = 25,
            .capacity = 24,
            .seed = 12345,
            .life = .{ .x = 5, .y = 5 },
            .speed = .{ .x = 10, .y = 90 },
            .angle = .{ .x = 0, .y = std.math.pi },
        });
        defer w.world.deinit();
        var i: usize = 0;
        while (i < 10) : (i += 1) sys.fixedUpdate(&w.world, 1.0 / 60.0);
        const n = slabOf(&sys, &w.world, w.entity).count;
        const copy = try a.alloc(f32, n);
        @memcpy(copy, sys.px[0..n]);
        results[run] = copy;
    }
    defer a.free(results[0]);
    defer a.free(results[1]);
    try testing.expectEqualSlices(f32, results[0], results[1]);
}

test "collect writes one instance per live particle and culls off-view ones" {
    const a = testing.allocator;
    var sys = try testSystem(a, .{ .max_particles = 1024, .max_emitters = 4 });
    defer sys.deinit();
    var w = try testWorldWithEmitter(a, Emitter{
        .rate = 0,
        .capacity = 32,
        .life = .{ .x = 5, .y = 5 },
        .size = .{ .x = 4, .y = 4 },
        .layer = 10,
    });
    defer w.world.deinit();
    // A burst and NO tick: the particles are at age 0, so the draw is the
    // emitter's `color_start` exactly. Ticking first would interpolate and the
    // test would be asserting a number that depends on the life random.
    sys.world = &w.world;
    _ = sys.burst(w.entity, 10);

    var r2d = Renderer2D.init(a);
    defer r2d.deinit();
    try r2d.reserve(64);
    r2d.lock();
    r2d.beginFrame();
    const slab = slabOf(&sys, &w.world, w.entity);
    sys.collect(&r2d, &w.world, 0.0, null);
    try testing.expectEqual(slab.count, @as(u32, @intCast(r2d.count)));
    try testing.expectEqual(@as(u32, 10), r2d.instances[0].layer);
    // The colour starts white at full alpha.
    try testing.expectEqual(@as(u8, 255), r2d.instances[0].color[3]);

    // Off-view: every particle culled, nothing drawn, and it is COUNTED rather
    // than silently dropped.
    r2d.beginFrame();
    sys.collect(&r2d, &w.world, 0.0, ViewRect.around(10_000, 10_000, 10, 10, 0));
    try testing.expectEqual(@as(usize, 0), r2d.count);
    try testing.expectEqual(slab.count, sys.stats.culled);
}

test "the instance budget drops particles instead of allocating (spec §3.1)" {
    const a = testing.allocator;
    var sys = try testSystem(a, .{ .max_particles = 1024, .max_emitters = 4 });
    defer sys.deinit();
    var w = try testWorldWithEmitter(a, Emitter{ .rate = 0, .capacity = 32, .life = .{ .x = 5, .y = 5 } });
    defer w.world.deinit();
    sys.world = &w.world;
    _ = sys.burst(w.entity, 8); // 8 live, room for 4

    var r2d = Renderer2D.init(a);
    defer r2d.deinit();
    try r2d.reserve(4); // deliberately too small
    r2d.lock();
    r2d.beginFrame();
    sys.collect(&r2d, &w.world, 0.0, null);
    try testing.expectEqual(@as(usize, 4), r2d.count);
    try testing.expectEqual(@as(u32, 4), sys.stats.culled);
}

test "local-space particles follow the emitter's movement" {
    const a = testing.allocator;
    var sys = try testSystem(a, .{ .max_particles = 1024, .max_emitters = 4 });
    defer sys.deinit();
    var w = try testWorldWithEmitter(a, Emitter{
        .rate = 60,
        .capacity = 16,
        .life = .{ .x = 5, .y = 5 },
        .space = .local,
        .speed = .{ .x = 0, .y = 0 },
    });
    defer w.world.deinit();
    sys.fixedUpdate(&w.world, 1.0 / 60.0);
    const x_before = sys.px[slabOf(&sys, &w.world, w.entity).first];

    // The actor teleports; the slab must teleport with it.
    w.world.get(w.entity, Transform).?.position.x += 100;
    sys.fixedUpdate(&w.world, 1.0 / 60.0);
    try testing.expectApproxEqAbs(@as(f32, x_before + 100), sys.px[slabOf(&sys, &w.world, w.entity).first], 0.001);
}

test "a pool with no room denies the slab and reports it" {
    const a = testing.allocator;
    var sys = try testSystem(a, .{ .max_particles = 64, .max_emitters = 4 });
    defer sys.deinit();
    // 64 particles of pool, one emitter taking all of it.
    var w = try testWorldWithEmitter(a, Emitter{ .rate = 10, .capacity = 64 });
    defer w.world.deinit();
    sys.fixedUpdate(&w.world, 1.0 / 60.0);

    // A second emitter has nothing left.
    const e2 = try w.world.spawn(.{ Transform{}, Emitter{ .rate = 10, .capacity = 64 } });
    sys.fixedUpdate(&w.world, 1.0 / 60.0);
    try testing.expectEqual(components.no_particle_slab, w.world.get(e2, Emitter).?.slab);
    try testing.expect(sys.stats.slab_denied > 0);
}

test "gravity and drag integrate deterministically" {
    const a = testing.allocator;
    var sys = try testSystem(a, .{ .max_particles = 64, .max_emitters = 2 });
    defer sys.deinit();
    var w = try testWorldWithEmitter(a, Emitter{
        .rate = 0,
        .capacity = 1,
        .gravity = .{ .x = 0, .y = -100 },
        .speed = .{ .x = 0, .y = 0 },
    });
    defer w.world.deinit();
    sys.world = &w.world;
    _ = sys.burst(w.entity, 1);
    const slab = slabOf(&sys, &w.world, w.entity);
    const p0 = slab.first;
    // t = 1/60: v = -100/60, y = 0 + v*dt (semi-implicit Euler applies gravity
    // before the move).
    sys.integrate(slab, 1.0 / 60.0);
    try testing.expectApproxEqAbs(@as(f32, -100.0 / 60.0), sys.vy[p0], 0.0001);
    try testing.expectApproxEqAbs(@as(f32, -(100.0 / 60.0) * (1.0 / 60.0)), sys.py[p0], 0.0001);
}

test "burst emits immediately and clear() empties without touching the recipe" {
    const a = testing.allocator;
    var sys = try testSystem(a, .{ .max_particles = 256, .max_emitters = 4 });
    defer sys.deinit();
    var w = try testWorldWithEmitter(a, Emitter{ .rate = 0, .capacity = 32 });
    defer w.world.deinit();
    sys.world = &w.world;

    try testing.expectEqual(@as(u32, 5), sys.burst(w.entity, 5));
    try testing.expectEqual(@as(u32, 5), slabOf(&sys, &w.world, w.entity).count);
    sys.clear(w.entity);
    try testing.expectEqual(@as(u32, 0), slabOf(&sys, &w.world, w.entity).count);
    // The recipe survives untouched.
    const em = w.world.get(w.entity, Emitter).?;
    try testing.expectEqual(@as(u16, 32), em.capacity);
    try testing.expect(em.playing);
}

