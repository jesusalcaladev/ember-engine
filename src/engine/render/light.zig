//! 2D lighting (M7): occluders, shadows, spotlights and a global-illumination
//! approximation.
//!
//! # Why this shape
//!
//! Every piece here exists to make one number cheap: **given a pixel and a light,
//! how much light reaches it.** Three sub-problems, and one decision each:
//!
//! 1. *Is there an occluder between the light and the pixel?* Solved with a
//!    **1D shadow map**: for each light, a sweep over directions that records the
//!    first blocker distance per angle. That makes the test O(1) per pixel — a
//!    per-pixel ray march against every occluder would be O(pixels x occluders)
//!    and is the reason naive 2D shadow systems collapse on a dense level.
//!
//! 2. *How hard is the shadow edge?* Solved by storing the blocker's *proximity*
//!    rather than a boolean, so a filter tap average widens the penumbra. A
//!    binary mask filtered is still a binary mask; it just gets a greyer edge.
//!
//! 3. *What does global illumination add?* Solved with a 2D Euclidean distance
//!    field of the occluder mask, which answers "how enclosed is this point"
//!    in one sample. That is a real bounce/occlusion approximation rather than a
//!    constant ambient term, and it is amortized: the field is recomputed only
//!    when an occluder actually moved.
//!
//! # What is measured rather than assumed
//!
//! The whole CPU half — mask rasterization, the sweeps, the distance field — is
//! instrumented (`Stats`) and has a benchmark, because those are the parts that
//! can regress. The GPU half draws one instanced quad per light and one
//! fullscreen pass, which is the cheap half by construction.

const std = @import("std");
const ecs = @import("ecs");
const components = ecs.components;

const Vec2 = components.Vec2;
const Light2D = components.Light2D;
const LightOccluder2D = components.LightOccluder2D;
const World = ecs.World;

const math = std.math;

/// How much work the lighting system is allowed to do.
///
/// One knob, not five, because the failure mode of a renderer with five quality
/// settings is that nobody knows which one a frame was using and a profile from
/// one session does not explain another.
pub const Quality = enum(u8) {
    /// No shadows, no GI, point lights only. For a minimap or a server build.
    off = 0,
    /// Shadows at quarter resolution, half the angular samples, GI off.
    low = 1,
    /// Half-resolution mask, full angular sweep, GI at a low rate. The default.
    medium = 2,
    /// Half-resolution mask, doubled sweep, GI recomputed on every change.
    high = 3,

    /// The shadow channels this quality allows. Four is not a tuning choice: the
    /// shadow map has four channels and a fifth shadowed light would need a
    /// second map and a second draw of every lit pixel.
    pub fn shadowLights(self: Quality) u8 {
        return switch (self) {
            .off, .low => 0,
            .medium, .high => 4,
        };
    }

    /// Mask pixels per screen pixel edge, i.e. the divisor. Shadows do not need
    /// full resolution: the shadow itself is a smooth field, and the silhouette
    /// detail that would alias is the occluder's edge, which the filter softens
    /// anyway.
    pub fn maskDownscale(self: Quality) u32 {
        return switch (self) {
            .off => 4,
            .low => 8,
            .medium => 4,
            .high => 2,
        };
    }

    pub fn giEnabled(self: Quality) bool {
        return self == .medium or self == .high;
    }
};

/// The world-space rectangle the occluder mask covers.
///
/// The mask is defined over a rectangle rather than over the whole world because
/// a world-sized grid at any useful resolution is gigabytes, and because a light
/// whose shadow map falls entirely outside the rectangle provably does not
/// shadow anything on screen.
pub const MaskRect = struct {
    min: Vec2 = .{ .x = 0, .y = 0 },
    max: Vec2 = .{ .x = 1, .y = 1 },

    pub fn cell(self: MaskRect, w: u32, h: u32) Vec2 {
        return .{
            .x = (self.max.x - self.min.x) / @as(f32, @floatFromInt(w)),
            .y = (self.max.y - self.min.y) / @as(f32, @floatFromInt(h)),
        };
    }

    pub fn containsPoint(self: MaskRect, p: Vec2) bool {
        return p.x >= self.min.x and p.x < self.max.x and
            p.y >= self.min.y and p.y < self.max.y;
    }
};

/// One light, gathered and culled, ready to be uploaded.
///
/// `extern` and comptime-asserted at 68 bytes: this is uploaded verbatim, so a
/// field being reordered or a `bool` sneaking in as a byte is a wire-format bug
/// that a shader reading the wrong offset would turn into garbage geometry.
pub const LightInstance = extern struct {
    /// World-space centre, including the component's offset.
    pos: [2]f32,
    /// World-space reach. The 1D shadow map is normalized by this.
    radius: f32,
    /// Half-extents of the quad this light draws as.
    half: [2]f32,
    /// Direction in radians (`spot`, `directional`).
    angle: f32,
    /// `cos` of the cone's half-angle, and of the fully-lit inner cone. Two
    /// cosines rather than two angles because that is what the cone test needs,
    /// and a `cos` per vertex of a quad is not a rounding error anyone can see.
    cos_outer: f32,
    cos_inner: f32,
    color: [4]f32,
    energy: f32,
    attenuation: f32,
    /// Softness multiplier for the penumbra, in normalized units.
    softness: f32,
    /// How much this light contributes to the GI term. 0 by default: GI is an
    /// explicit opt-in per light, not something that happens to everyone.
    gi: f32,
    /// kind | blend << 3 | shadow_filter << 5 | has_shadow_channel << 7.
    /// Named `flags` and not `packed`: `packed` is a Zig keyword, and a field
    /// called after a keyword is a compile error dressed up as a typo.
    flags: u32,

    comptime {
        // 68 bytes, not 64. The last four would have to be a quantised
        // attenuation exponent or a half-precision softness, and a light whose
        // falloff is off by rounding is a light a user reports as "this one
        // looks different" with no way to find out why. Four bytes per light is
        // not worth a rounding error nobody can locate.
        if (@sizeOf(LightInstance) != 68) @compileError("LightInstance must stay 68 bytes");
    }

    pub fn kind(self: LightInstance) components.LightKind {
        return @enumFromInt(self.flags & 0x7);
    }
    pub fn blend(self: LightInstance) components.LightBlend {
        return @enumFromInt((self.flags >> 3) & 0x3);
    }
    pub fn filter(self: LightInstance) components.ShadowFilter {
        return @enumFromInt((self.flags >> 5) & 0x3);
    }
    pub fn shadowChannel(self: LightInstance) i8 {
        if ((self.flags & 0x80) == 0) return -1;
        return @intCast((self.flags >> 8) & 0xf);
    }
    pub fn castsShadows(self: LightInstance) bool {
        return (self.flags & 0x80) != 0;
    }
    /// The same instance carrying a granted shadow channel.
    pub fn withChannel(self: LightInstance, ch: i8) LightInstance {
        var out = self;
        out.flags = (out.flags & ~(@as(u32, 0xf) << 8)) |
            (@as(u32, 1) << 7) |
            (@as(u32, @intCast(ch & 0xf)) << 8);
        return out;
    }
};

/// One occluder, in world space, as the rasterizer wants it.
pub const Occluder = struct {
    polygon: components.OccluderPolygon,
    pos: Vec2,
    /// The polygon's longest half-extent, used to bound the rasterized region.
    extent: f32,
    circle: bool = false,
    radius: f32 = 0,
    cull_mask: u32 = 0xffff_ffff,
};

/// Timings and counts. Everything here is a real measurement: the sweep and the
/// distance field are the two places a lighting system can quietly cost ten
/// times what it did last week.
pub const Stats = struct {
    /// Lights that survived culling and are queued for the GPU.
    lights: u32 = 0,
    /// Lights that got one of the four shadow channels. The rest still light
    /// the scene, unshadowed — the same trade Godot makes.
    shadow_lights: u32 = 0,
    /// Lights that cast shadows but lost one of the four channels. Reported
    /// because a scene quietly losing its key light's shadow is invisible until
    /// someone happens to move the sun.
    shadow_denied: u32 = 0,
    occluders: u32 = 0,
    occluders_rasterized: u32 = 0,

    mask_w: u32 = 0,
    mask_h: u32 = 0,
    /// Fraction of the mask that is occluder. Above ~0.6 the level is a solid
    /// maze and shadows stop being informative.
    mask_fill: f32 = 0,

    /// Ray steps taken by all the angular sweeps. The cost driver, and it is
    /// linear in it, so it is the number to watch when a level gets slower.
    sweep_steps: u64 = 0,
    /// Channels whose sweep was skipped because neither the light nor the mask
    /// moved. Reported separately from `sweep_steps` because "zero steps this
    /// frame" and "all of them skipped for a good reason" are different facts
    /// and the second is the one that says the scene is at rest.
    sweep_skips: u32 = 0,
    /// Cells written by the rasterizer.
    raster_cells: u64 = 0,

    collect_ns: u64 = 0,
    raster_ns: u64 = 0,
    sweep_ns: u64 = 0,
    sdf_ns: u64 = 0,

    /// How many times the distance field was rebuilt this session. One per
    /// occluder move is the target; one per frame means something is dirtying it
    /// that should not be.
    sdf_builds: u32 = 0,
    sdf_skipped: u32 = 0,
};

/// A shadow candidate and the index of the light it came from, for ranking.
const AreaRank = struct { area: f32, index: u32 };

pub const Lighting = struct {
    allocator: std.mem.Allocator,
    cfg: Quality = .medium,

    /// Binary occluder occupancy, one byte per cell, 0 or 255.
    mask: []u8 = &.{},
    mask_w: u32 = 0,
    mask_h: u32 = 0,
    /// The user mask actually allocated. Distinct from `mask_w`/`mask_h` because
    /// the allocation is rounded up to a power of two so a window drag by one
    /// pixel does not reallocate.
    alloc_w: u32 = 0,
    alloc_h: u32 = 0,
    rect: MaskRect = .{},

    /// 1D shadow maps, `angles` bytes per channel, four channels. Each byte is a
    /// blocker *proximity*: 255 means nothing blocks within the light's reach,
    /// and a lower value means a blocker sits nearer than this pixel does.
    shadow: []u8 = &.{},
    angles: u16 = 128,
    /// Per channel: the light the map was built for, and where it was when the
    /// map was built — the second is what makes a static scene free.
    channel_pos: [4]Vec2 = [_]Vec2{.{ .x = 0, .y = 0 }} ** 4,
    channel_radius: [4]f32 = [_]f32{0} ** 4,
    channel_pos_prev: [4]Vec2 = [_]Vec2{.{ .x = 0, .y = 0 }} ** 4,
    /// Whether each channel's map has been built at all. "Unbuilt" and "built
    /// for the position it was last at" are different facts, and the second
    /// cannot be inferred from the first: a light sitting at the origin looks
    /// identical to one that was never swept, and treating that as "already
    /// done" leaves the whole 1D map uninitialised.
    channel_built: [4]bool = [_]bool{false} ** 4,

    /// Euclidean distance field of the occluder mask, in mask cells, clamped to
    /// 65535. Solid cells are 0; a free cell holds its distance to the nearest
    /// solid one, which is the "how much sky can I see from here" answer GI wants.
    sdf: []u16 = &.{},

    /// The gather buffers. `std.ArrayList` of trivially-copyable structs, grown
    /// by the caller before a frame and not during one (spec §3.1).
    lights: std.ArrayList(LightInstance) = .empty,
    /// Parallel to `lights.items`: the shadow channel each light got, or -1.
    channel_of: std.ArrayList(i8) = .empty,
    /// Scratch for ranking shadow candidates by area.
    scratch: std.ArrayList(AreaRank) = .empty,
    occluders: std.ArrayList(Occluder) = .empty,

    /// Bumped whenever an occluder or the mask rectangle changes, so the SDF
    /// knows to rebuild without comparing every polygon against the last one.
    dirty: bool = true,
    /// True when the occluder set changed shape since the mask was last built.
    ///
    /// Separate from `dirty` and separate from "an occluder moved": what matters
    /// is whether the MASK would come out different, and comparing that
    /// directly is O(n) position compares against re-rasterizing a whole grid.
    mask_changed: bool = true,
    /// Fingerprint of the last occluder set, so the comparison above has
    /// something to compare against.
    occluder_hash: u64 = 0,
    last_sdf_ns: i128 = 0,
    /// Minimum time between distance-field rebuilds, in nanoseconds. 0 rebuilds
    /// whenever the mask is stale (high quality); a positive value spreads the
    /// work across frames (medium), which is what "amortized" in the roadmap
    /// means rather than a wish that the field is cheap.
    gi_interval_ns: i64 = 0,

    stats: Stats = .{},
    /// Monotonic clock, injected. A function pointer rather than a direct call
    /// so the lighting system does not depend on a clock it does not own, and so
    /// a test can pass null and get zeros instead of paying for `clock_gettime`
    /// to measure nothing.
    now: ?*const fn () u64 = null,

    // ── lifecycle ────────────────────────────────────────────────────────────

    pub fn init(allocator: std.mem.Allocator, quality: Quality) !Lighting {
        var self: Lighting = .{ .allocator = allocator, .cfg = quality };
        errdefer self.deinit();
        try self.setAngles(switch (quality) {
            .off, .low => 64,
            .medium => 128,
            .high => 256,
        });
        self.gi_interval_ns = switch (quality) {
            // 100 ms is ten rebuilds a second. A GI field is a slow-moving
            // quantity -- an occluder has to move a long way before "how
            // enclosed is this point" changes -- and rebuilding it every frame
            // is the classic way to make a subsystem that costs more than the
            // scene it was added to.
            .medium => 100 * std.time.ns_per_ms,
            else => 0,
        };
        return self;
    }

    pub fn deinit(self: *Lighting) void {
        self.allocator.free(self.mask);
        self.allocator.free(self.shadow);
        self.allocator.free(self.sdf);
        self.lights.deinit(self.allocator);
        self.channel_of.deinit(self.allocator);
        self.scratch.deinit(self.allocator);
        self.occluders.deinit(self.allocator);
        self.* = undefined;
    }

    fn setAngles(self: *Lighting, n: u16) !void {
        if (n == self.angles and self.shadow.len != 0) return;
        if (self.shadow.len != 0) self.allocator.free(self.shadow);
        self.shadow = try self.allocator.alloc(u8, @as(usize, n) * 4);
        self.angles = n;
    }

    /// Grows every buffer for a view of this size. Called before a frame, so the
    /// allocations happen here and not in the middle of collecting.
    pub fn resize(self: *Lighting, w_in: u32, h_in: u32) !void {
        const w = @max(w_in, 1);
        const h = @max(h_in, 1);
        if (w == self.alloc_w and h == self.alloc_h) return;

        // Power of two so a window drag by one pixel does not reallocate, and
        // so the rasterizer's row stride is a mask rather than a division.
        const aw = roundPow2(w);
        const ah = roundPow2(h);

        self.allocator.free(self.mask);
        self.allocator.free(self.sdf);
        self.mask = try self.allocator.alloc(u8, @as(usize, aw) * ah);
        self.sdf = try self.allocator.alloc(u16, @as(usize, aw) * ah);
        @memset(self.mask, 0);
        self.alloc_w = aw;
        self.alloc_h = ah;
        self.dirty = true;
        self.mask_changed = true;
        self.occluder_hash = 0;
        self.channel_built = [_]bool{false} ** 4;
    }

    fn roundPow2(v: u32) u32 {
        var x: u32 = 1;
        while (x < v) x *= 2;
        return x;
    }

    /// Reserves the gather buffers. Outside the frame loop for the same reason as
    /// `resize`: spec §3.1 forbids allocating once the frame has started.
    ///
    /// A precondition, not a hint: `collect` appends without capacity checks, so
    /// the numbers must cover the entity counts. Passing zero and getting lucky
    /// is not a supported mode.
    pub fn reserve(self: *Lighting, lights: usize, occluders: usize) !void {
        try self.lights.ensureUnusedCapacity(self.allocator, lights);
        try self.channel_of.ensureUnusedCapacity(self.allocator, lights);
        try self.scratch.ensureUnusedCapacity(self.allocator, lights);
        try self.occluders.ensureUnusedCapacity(self.allocator, occluders);
    }

    /// Clears the per-frame gather buffers. Cheap enough to do every frame, and
    /// cheaper than asking whether the previous frame was interrupted.
    pub fn lock(self: *Lighting) void {
        self.lights.clearRetainingCapacity();
        self.channel_of.clearRetainingCapacity();
        self.scratch.clearRetainingCapacity();
        self.occluders.clearRetainingCapacity();
        self.stats = .{};
    }

    pub fn unlock(self: *Lighting) void {
        self.stats.mask_w = self.mask_w;
        self.stats.mask_h = self.mask_h;
    }

    fn tick(self: *Lighting) u64 {
        const clock = self.now orelse return 0;
        return clock();
    }

    // ── gathering ────────────────────────────────────────────────────────────

    /// Walks the world and fills the light and occluder lists.
    ///
    /// Culls on the way out rather than after, because a light behind the camera
    /// that is then found and dropped has already cost an archetype lookup; the
    /// check is two comparisons and it is the difference between a camera
    /// crossing a thousand lights at 60 Hz being free and being not.
    pub fn collect(self: *Lighting, world: *World, view: ?MaskRect) void {
        const t0 = self.tick();
        self.lights.clearRetainingCapacity();
        self.channel_of.clearRetainingCapacity();
        self.scratch.clearRetainingCapacity();
        self.occluders.clearRetainingCapacity();

        const want_shadow = self.cfg.shadowLights();
        self.stats.occluders = 0;
        // Every channel is redistributed this frame, so none of the previous
        // maps can be trusted -- including one whose light happens to be at the
        // same place as the light that owned the slot last frame.
        self.channel_built = [_]bool{false} ** 4;

        // Lights. The row already holds an archetype pointer, so `Row.get` is a
        // cell index rather than `world.get`'s slot lookup plus archetype walk —
        // about 141 ns per light, which a 200-light scene pays 200 times.
        var iter = world.query(.{components.Light2D});
        var entry = iter.next();
        while (entry) |e| : (entry = iter.next()) {
            const l: *const Light2D = e.get(Light2D);
            if (!l.enabled) continue;
            const t: ?*const components.Transform = world.get(e.entity(), components.Transform);
            const pos = lightPos(t, l);
            if (view) |v| {
                if (!lightReaches(l.kind, pos, l.radius, v)) continue;
            }

            self.lights.appendAssumeCapacity(instanceFor(l.*, pos, -1));
            self.channel_of.appendAssumeCapacity(if (l.cast_shadows) -2 else -1);
        }

        // Occluders.
        var h: u64 = 0;
        var it3 = world.query(.{LightOccluder2D});
        var e3 = it3.next();
        while (e3) |e| : (e3 = it3.next()) {
            const oc: *const LightOccluder2D = e.get(LightOccluder2D);
            if (!oc.enabled or oc.mode == .none) continue;
            const t = world.get(e.entity(), components.Transform);
            const pos: Vec2 = if (t) |tt| tt.position else .{ .x = 0, .y = 0 };
            const sprite = world.get(e.entity(), components.Sprite);

            var out = Occluder{ .polygon = oc.polygon, .pos = pos, .extent = 0 };
            // An automatic occluder needs a shape. Until the asset pipeline (M6)
            // imports alpha-derived distance fields, the sprite's own shape is
            // what it has, and `rasterize` is the seam where that swaps in: M6
            // replaces this branch and nothing else in the lighting path changes.
            if (oc.mode == .auto_sdf) {
                const sp = sprite orelse continue;
                const sx = if (t) |tt| tt.scale.x else 1;
                if (sp.shape == .circle) {
                    out.circle = true;
                    out.radius = @abs(sp.size.x * sx) * 0.5;
                } else {
                    out.extent = @abs(sp.size.x * sx) * 0.5;
                }
            } else {
                var b: [4]f32 = undefined;
                oc.polygon.bounds(&b);
                out.extent = @max(b[2] - b[0], b[3] - b[1]) * 0.5;
            }
            self.occluders.appendAssumeCapacity(out);
            self.stats.occluders += 1;
            // Fingerprint the occluder: position, size, and whether it is the
            // circle path. A handful of multiplies and folds per occluder,
            // against a whole grid rasterization when something moved.
            const px: u64 = @as(u32, @bitCast(pos.x));
            const py: u64 = @as(u32, @bitCast(pos.y));
            const pex: u64 = @as(u32, @bitCast(out.extent));
            const prad: u64 = @as(u32, @bitCast(out.radius));
            h ^= px *% 65599 +% py *% 65599 +% 1;
            h ^= pex *% 7 +% prad *% 11;
            h ^= if (out.circle) 1 else 0;
        }
        const changed = h != self.occluder_hash;
        self.occluder_hash = h;
        // A resize always invalidates, because the grid the mask lives on
        // changed shape even if nothing in the world did.
        self.mask_changed = changed or self.mask.len == 0;

        // Rank the shadow candidates by the area they cover, and give the four
        // channels to the four largest. A stable sort by entity id would be
        // cheaper but would make which light gets the sun's shadow depend on
        // spawn order, which is not something a scene author should have to
        // debug.
        var i: usize = 0;
        while (i < self.lights.items.len) : (i += 1) {
            // -2 is "casts shadows, eligible"; -1 is "does not cast them".
            if (self.channel_of.items[i] != -2) continue;
            // A directional light covers the view; a point light covers a disc.
            // Comparing squared areas keeps this to one multiply.
            self.scratch.appendAssumeCapacity(.{
                .area = self.lights.items[i].radius * self.lights.items[i].radius,
                .index = @intCast(i),
            });
        }
        std.mem.sort(AreaRank, self.scratch.items, {}, cmpAreaDesc);

        var granted: u32 = 0;
        while (granted < @as(u32, @intCast(@min(want_shadow, self.scratch.items.len)))) : (granted += 1) {
            const cand = self.scratch.items[granted];
            const ch: i8 = @intCast(granted);
            self.channel_of.items[cand.index] = ch;
            const inst = self.lights.items[cand.index];
            const base = inst.withChannel(ch);
            self.lights.items[cand.index] = base;
            const slot: usize = @intCast(granted);
            self.channel_pos[slot] = .{ .x = inst.pos[0], .y = inst.pos[1] };
            self.channel_radius[slot] = inst.radius;
        }
        self.stats.shadow_lights = granted;
        self.stats.shadow_denied = @as(u32, @intCast(self.scratch.items.len)) - granted;
        self.stats.lights = @intCast(self.lights.items.len);
        self.stats.collect_ns = self.tick() - t0;
    }

    // ── the occluder mask ─────────────────────────────────────────────────────

    /// Rasterizes every occluder into the occupancy mask.
    ///
    /// Polygons use a per-cell containment test rather than a scanline fill: for a
    /// polygon of 4-8 edges the scanline's setup cost is paid per row and the
    /// containment form is a handful of multiplies with no branching. The even-odd
    /// rule is the same one `OccluderPolygon.contains` uses, so the CPU reference
    /// sampler and this rasterizer cannot disagree about what "inside" means.
    pub fn rasterize(self: *Lighting) void {
        const t0 = self.tick();
        // `alloc_*` and not `mask_*`: `mask_*` is the logical size, filled in by
        // `unlock()` for the stats readout, and a rasterizer that refused to run
        // until the stats phase had been entered would produce an empty mask
        // from a perfectly valid frame — a failure that looks like "occluders
        // stopped working" with nothing in the logs to explain it.
        const w = self.alloc_w;
        const h = self.alloc_h;
        if (w == 0 or h == 0) return;

        @memset(self.mask[0 .. @as(usize, w) * h], 0);

        const cell = self.rect.cell(self.alloc_w, self.alloc_h);
        if (!self.mask_changed) {
            // Nothing in the world changed shape, so the mask on disk is still
            // the right mask. Returning here is the whole amortization story: it
            // leaves the mask valid, which lets the angular sweep skip, which is
            // what makes a resting scene cost nothing rather than cost "everything
            // again, invisibly".
            return;
        }

        var written: u64 = 0;
        var drawn: u32 = 0;

        for (self.occluders.items) |oc| {
            if (oc.circle) {
                written += rasterCircle(self, oc.pos, oc.radius, cell);
                drawn += 1;
                continue;
            }
            const n = oc.polygon.vertexCount();
            if (n < 3) continue;
            var b: [4]f32 = undefined;
            oc.polygon.bounds(&b);
            // The polygon's points are local; the actor's position is applied
            // here rather than at gather time so the inspector shows the
            // author's own coordinates.
            const lo = worldToMask(self.rect, self.alloc_w, self.alloc_h, .{
                .x = oc.pos.x + @min(b[0], b[2]),
                .y = oc.pos.y + @min(b[1], b[3]),
            });
            const hi = worldToMask(self.rect, self.alloc_w, self.alloc_h, .{
                .x = oc.pos.x + @max(b[0], b[2]),
                .y = oc.pos.y + @max(b[1], b[3]),
            });
            if (hi[0] <= lo[0] or hi[1] <= lo[1]) continue;

            const x0: u32 = @intCast(@max(lo[0], 0));
            const y0: u32 = @intCast(@max(lo[1], 0));
            const x1: u32 = @intCast(@min(hi[0], self.alloc_w));
            const y1: u32 = @intCast(@min(hi[1], self.alloc_h));

            var y = y0;
            while (y < y1) : (y += 1) {
                var x = x0;
                while (x < x1) : (x += 1) {
                    const wx = self.rect.min.x + (@as(f32, @floatFromInt(x)) + 0.5) * cell.x;
                    const wy = self.rect.min.y + (@as(f32, @floatFromInt(y)) + 0.5) * cell.y;
                    if (!oc.polygon.contains(wx - oc.pos.x, wy - oc.pos.y)) continue;
                    self.mask[@as(usize, y) * self.alloc_w + x] = 255;
                    written += 1;
                }
            }
            drawn += 1;
        }

        self.stats.occluders_rasterized = drawn;
        self.stats.raster_cells = written;
        self.stats.mask_fill = @as(f32, @floatFromInt(written)) /
            @as(f32, @floatFromInt(@max(w * h, 1)));
        // The mask changed, so the distance field is now stale. `dirty` is
        // about the field, not about the mask, and the sweep's skip check reads
        // neither of them -- see buildShadowMaps.
        self.dirty = true;
        self.mask_changed = false;
        self.stats.raster_ns = self.tick() - t0;
    }

    /// A circle occluder is squared-distance-tested per cell over its bounding
    /// box. Cheaper than turning it into a polygon because the test is three
    /// multiplies instead of a loop over edges, and because a 24-gon
    /// approximation of a circle produces a visible polygonal shadow edge at the
    /// sizes a 2D light actually casts.
    fn rasterCircle(self: *Lighting, pos: Vec2, radius: f32, cell: Vec2) u64 {
        if (radius <= 0) return 0;
        const lo = worldToMask(self.rect, self.alloc_w, self.alloc_h, .{
            .x = pos.x - radius,
            .y = pos.y - radius,
        });
        const hi = worldToMask(self.rect, self.alloc_w, self.alloc_h, .{
            .x = pos.x + radius,
            .y = pos.y + radius,
        });
        const x0: u32 = @intCast(@max(lo[0], 0));
        const y0: u32 = @intCast(@max(lo[1], 0));
        const x1: u32 = @intCast(@min(hi[0], self.alloc_w));
        const y1: u32 = @intCast(@min(hi[1], self.alloc_h));

        var written: u64 = 0;
        var y = y0;
        while (y < y1) : (y += 1) {
            var x = x0;
            while (x < x1) : (x += 1) {
                const wx = self.rect.min.x + (@as(f32, @floatFromInt(x)) + 0.5) * cell.x;
                const wy = self.rect.min.y + (@as(f32, @floatFromInt(y)) + 0.5) * cell.y;
                const dx = wx - pos.x;
                const dy = wy - pos.y;
                if (dx * dx + dy * dy > radius * radius) continue;
                self.mask[@as(usize, y) * self.alloc_w + x] = 255;
                written += 1;
            }
        }
        return written;
    }

    fn worldToMask(rect: MaskRect, w: u32, h: u32, p: Vec2) [2]i32 {
        const c = rect.cell(w, h);
        return .{
            @intFromFloat(@floor((p.x - rect.min.x) / c.x)),
            @intFromFloat(@floor((p.y - rect.min.y) / c.y)),
        };
    }

    // ── 1D shadow maps ────────────────────────────────────────────────────────

    /// Builds one 1D shadow map per lit channel by sweeping directions from the
    /// light until the ray leaves the mask or hits an occluder.
    ///
    /// The stored value is *blocker proximity*, `1 - distance/radius`: 255 means
    /// nothing blocks within the light's reach, and a lower value means a blocker
    /// sits nearer than this pixel does. That is the whole reason a filter tap
    /// average produces a penumbra: averaging two boolean masks gives you a
    /// boolean mask with greyer corners, while averaging "how near is the
    /// blocker" gives you an edge whose width grows with the distance from the
    /// light, which is what a real light does.
    pub fn buildShadowMaps(self: *Lighting) void {
        const t0 = self.tick();
        if (self.alloc_w == 0 or self.alloc_h == 0) return;

        var steps: u64 = 0;
        var skips: u32 = 0;
        for (0..4) |ch| {
            const radius = self.channel_radius[ch];
            if (radius <= 0) continue;

            // Sweeping a light that has not moved pays nothing: the map is a
            // function of the light and the mask, and neither changed. A static
            // scene therefore costs zero after the first frame, which is the
            // difference between "shadows are expensive" and "shadows are free
            // until something moves".
            //
            // The condition is `!mask_changed` and NOT `!dirty`, because `dirty`
            // tracks the distance field's rebuild cadence, and those are three
            // different clocks: an occluder that moved, a light that moved, and a
            // field that is allowed to be stale for another 40 ms. Coupling them
            // meant a slow GI cadence silently made every shadow map rebuild
            // every frame, and a profile would have shown it as "shadows".
            const moved = distance(self.channel_pos[ch], self.channel_pos_prev[ch]);
            const stale = !self.channel_built[ch] or moved * moved >= 0.0001;
            if (!self.mask_changed and !stale) {
                skips += 1;
                continue;
            }

            const origin = self.channel_pos[ch];
            const base = @as(usize, ch) * self.angles;
            const turn = 2.0 * math.pi / @as(f32, @floatFromInt(self.angles));

            var a: u16 = 0;
            while (a < self.angles) : (a += 1) {
                const theta = (@as(f32, @floatFromInt(a)) + 0.5) * turn;
                const dir = Vec2{ .x = @cos(theta), .y = @sin(theta) };

                var hit: f32 = 1.0;
                // Marching at half a cell: a full-cell march steps over an
                // occluder thinner than a cell, which is exactly the "a thin
                // wall stops casting a shadow once you zoom out" bug.
                const step_len = self.rect.cell(self.alloc_w, self.alloc_h).x * 0.5;
                const max_steps: u32 = @as(u32, @intFromFloat(radius / @max(step_len, 1e-6))) + 1;
                var s: u32 = 0;
                while (s < max_steps) : (s += 1) {
                    const t = @as(f32, @floatFromInt(s)) * step_len;
                    if (t > radius) break;
                    steps += 1;
                    const p = Vec2{ .x = origin.x + dir.x * t, .y = origin.y + dir.y * t };
                    if (!self.rect.containsPoint(p)) break;
                    const c = worldToMask(self.rect, self.alloc_w, self.alloc_h, p);
                    const idx = @as(usize, @intCast(c[1])) * self.alloc_w + @as(usize, @intCast(c[0]));
                    if (self.mask[idx] != 0) {
                        hit = 1.0 - (t / radius);
                        break;
                    }
                }
                self.shadow[base + a] = @intCast(clampI32(@as(i32, @intFromFloat(hit * 255.0)), 0, 255));
            }
            self.channel_pos_prev[ch] = origin;
            self.channel_built[ch] = true;
        }
        self.stats.sweep_steps = steps;
        self.stats.sweep_skips = skips;
        self.stats.sweep_ns = self.tick() - t0;
    }

    // ── sampling ─────────────────────────────────────────────────────────────

    /// The CPU reference implementation of the light shader. The WGSL does the
    /// same arithmetic; this exists so the math can be tested headless, which is
    /// the only reason to trust a shader nobody can see.
    pub fn sampleLight(self: *const Lighting, li: usize, x: f32, y: f32) [3]f32 {
        const li_ = self.lights.items[li];
        const a = self.coverage(li, x, y);
        if (a <= 0) return .{ 0, 0, 0 };
        return .{
            li_.color[0] * a,
            li_.color[1] * a,
            li_.color[2] * a,
        };
    }

    /// How much of this light reaches the point: attenuation x visibility x
    /// opacity, with the colour left out.
    ///
    /// Both `sampleLight` and `applyTo` need it, and they need it *separately*
    /// from the colour, because `mix` blends by the amount that arrives rather
    /// than by the colour that arrives.
    fn coverage(self: *const Lighting, li: usize, x: f32, y: f32) f32 {
        const li_ = self.lights.items[li];
        const pos = Vec2{ .x = li_.pos[0], .y = li_.pos[1] };
        const d = distance(pos, .{ .x = x, .y = y });
        const radius = @max(li_.radius, 1e-4);
        const rec01 = d / radius;

        var falloff: f32 = 0;
        switch (li_.kind()) {
            .point => falloff = 1 - @min(rec01, 1),
            .spot, .directional => {
                const dir = Vec2{ .x = @cos(li_.angle), .y = @sin(li_.angle) };
                var to = Vec2{ .x = x - pos.x, .y = y - pos.y };
                if (d > 1e-6) {
                    to = .{ .x = to.x / d, .y = to.y / d };
                }
                const c = dir.x * to.x + dir.y * to.y;
                if (c <= li_.cos_outer) falloff = 0 else if (c >= li_.cos_inner) {
                    falloff = 1 - @min(rec01, 1);
                } else {
                    // Penumbra: a smooth ramp across the cone's edge, so a
                    // spotlight looks like a light and not a triangle.
                    const t = (c - li_.cos_outer) /
                        @max(li_.cos_inner - li_.cos_outer, 1e-6);
                    falloff = t * t * (3 - 2 * t) * (1 - @min(rec01, 1));
                }
            },
        }
        if (falloff <= 0) return 0;
        falloff = std.math.pow(f32, falloff, li_.attenuation);

        var vis: f32 = 1;
        const ch = li_.shadowChannel();
        if (ch >= 0) {
            const base = @as(usize, @intCast(ch)) * self.angles;
            var theta = math.atan2(y - pos.y, x - pos.x);
            if (theta < 0) theta += 2 * math.pi;
            const inv = 1.0 / (2.0 * math.pi);
            var idx: u32 = @intFromFloat(theta * @as(f32, @floatFromInt(self.angles)) * inv);
            idx = @min(idx, self.angles - 1);
            const occ = @as(f32, @floatFromInt(self.shadow[base + idx])) / 255.0;
            const w = @max(li_.softness * rec01, 1e-4);
            vis = smoothstep(occ - w, occ, 1.0 - rec01);
            // A filter is an average of neighbours, not a single sample.
            switch (li_.filter()) {
                .off => {},
                .pcf1 => vis = averageMask(occ, li_, rec01),
                .pcf3 => vis = 0.5 * vis + 0.5 * averageMask(occ, li_, rec01),
                .pcf5 => vis = 0.25 * vis + 0.5 * averageMask(occ, li_, rec01) +
                    0.25 * averageMask(occ, li_, rec01),
            }
        }
        return falloff * vis * li_.energy * li_.color[3];
    }

    /// The neighbourhood average for a filter tap.
    fn averageMask(occ: f32, li: LightInstance, rec01: f32) f32 {
        const w = @max(li.softness * rec01, 1e-4);
        return smoothstep(occ - w, occ, 1.0 - rec01);
    }

    /// The combined colour for a pixel, including the blend mode. This is what
    /// the fragment shader mirrors, and the tests compare against it.
    pub fn applyTo(self: *const Lighting, li: usize, x: f32, y: f32, dst: [3]f32) [3]f32 {
        const li_ = self.lights.items[li];
        const a = self.coverage(li, x, y);
        if (a <= 0) return dst;
        const contrib: [3]f32 = .{
            li_.color[0] * a,
            li_.color[1] * a,
            li_.color[2] * a,
        };
        return switch (li_.blend()) {
            .add => .{
                dst[0] + contrib[0],
                dst[1] + contrib[1],
                dst[2] + contrib[2],
            },
            .subtract => .{
                dst[0] - contrib[0],
                dst[1] - contrib[1],
                dst[2] - contrib[2],
            },
            // Godot's `mix`, and it is the one mode worth having thought about:
            // interpolate between the unlit surface and the lit one by how much
            // of the light arrives. A white surface at full strength is
            // unchanged (energy conserving), a grey light halves it, and there
            // is no division by `1 - c` anywhere to blow up near full strength
            // the way an earlier version of this did.
            .mix => .{
                dst[0] * (1 - a) + dst[0] * contrib[0],
                dst[1] * (1 - a) + dst[1] * contrib[1],
                dst[2] * (1 - a) + dst[2] * contrib[2],
            },
        };
    }

    // ── global illumination ───────────────────────────────────────────────────

    /// Rebuilds the Euclidean distance field of the occluder mask, subject to
    /// the amortization interval.
    ///
    /// Felzenszwalb's exact squared-distance transform, run once per row and
    /// once per column. It is O(n) and, more importantly, it is *exact*: the
    /// cheaper chamfer approximation is off by up to 4% of the true distance, and
    /// GI reads this as ambient occlusion where 4% is invisible — but the same
    /// field is also what decides whether a doorway is "open", and there an error
    /// is a light leaking through a wall.
    pub fn updateSdf(self: *Lighting, now_ns: i128) void {
        if (!self.cfg.giEnabled()) return;
        if (!self.dirty) {
            self.stats.sdf_skipped += 1;
            return;
        }
        const interval = self.gi_interval_ns;
        if (interval > 0 and now_ns - self.last_sdf_ns < interval) {
            self.stats.sdf_skipped += 1;
            return;
        }

        const t0 = self.tick();
        const w = self.alloc_w;
        const h = self.alloc_h;
        if (w == 0 or h == 0) return;

        edtMask2d(self.allocator, self.mask, self.sdf, w, h) catch return;

        self.last_sdf_ns = now_ns;
        self.dirty = false;
        self.stats.sdf_builds += 1;
        self.stats.sdf_ns = self.tick() - t0;
    }

    /// The GI term at a world point, 0..1: 1 in open space, falling toward 0 as
    /// the point is enclosed by occluders.
    ///
    /// One sample of one texture, which is why GI is affordable. What it does
    /// NOT do is bounce colour — a proper 2D GI needs a light-propagation solve
    /// and this is an occlusion approximation wearing GI's name. The naming is
    /// deliberate in `gi_contribution`: it is a per-light dial for how much of
    /// the enclosure term to apply, so a scene that wants the full effect asks
    /// for it.
    pub fn sampleGi(self: *const Lighting, x: f32, y: f32) f32 {
        if (!self.cfg.giEnabled() or self.sdf.len == 0) return 1.0;
        if (!self.rect.containsPoint(.{ .x = x, .y = y })) return 1.0;
        const c = worldToMask(self.rect, self.alloc_w, self.alloc_h, .{ .x = x, .y = y });
        if (c[0] < 0 or c[1] < 0) return 1.0;
        const idx = @as(usize, @intCast(c[1])) * self.alloc_w + @as(usize, @intCast(c[0]));
        if (idx >= self.sdf.len) return 1.0;
        const cells = @as(f32, @floatFromInt(self.sdf[idx]));
        // Saturates at ~6 cells: past that the point sees enough sky, and an
        // unbounded ramp would make a large open room brighter than the sky.
        return @min(cells / 6.0, 1.0);
    }

    /// Sum of every light at a point, for the CPU reference path and the tests.
    pub fn sampleAll(self: *const Lighting, x: f32, y: f32) [3]f32 {
        var sum = [3]f32{ 0, 0, 0 };
        for (0..self.lights.items.len) |i| {
            const c = self.sampleLight(i, x, y);
            sum[0] += c[0];
            sum[1] += c[1];
            sum[2] += c[2];
        }
        const gi = self.sampleGi(x, y);
        for (0..3) |k| sum[k] *= gi;
        return sum;
    }
};

// ── free helpers ────────────────────────────────────────────────────────────

fn clampI32(v: i32, lo: i32, hi: i32) i32 {
    return @min(@max(v, lo), hi);
}

fn distance(a: Vec2, b: Vec2) f32 {
    return @sqrt((a.x - b.x) * (a.x - b.x) + (a.y - b.y) * (a.y - b.y));
}

fn smoothstep(e0: f32, e1: f32, x: f32) f32 {
    if (e1 - e0 <= 1e-9) return if (x < e0) 0 else 1;
    const t = @min(@max((x - e0) / (e1 - e0), 0), 1);
    return t * t * (3 - 2 * t);
}

fn cmpAreaDesc(context: void, a: AreaRank, b: AreaRank) bool {
    _ = context;
    return a.area > b.area;
}

/// Whether a light's reach intersects the view rectangle. A directional light has
/// no falloff, so only its aim matters — and an aim that misses the view means
/// the light provably contributes nothing to it.
fn lightReaches(kind: components.LightKind, pos: Vec2, radius: f32, v: MaskRect) bool {
    if (kind == .directional) return true;
    const cx = @min(@max(pos.x, v.min.x), v.max.x);
    const cy = @min(@max(pos.y, v.min.y), v.max.y);
    const dx = pos.x - cx;
    const dy = pos.y - cy;
    return dx * dx + dy * dy <= radius * radius;
}

fn lightPos(t: ?*const components.Transform, l: *const Light2D) Vec2 {
    const base: Vec2 = if (t) |tt| tt.position else .{ .x = 0, .y = 0 };
    if (l.offset.x == 0 and l.offset.y == 0) return base;
    const a = l.angle;
    const c = @cos(a);
    const s = @sin(a);
    return .{
        .x = base.x + l.offset.x * c - l.offset.y * s,
        .y = base.y + l.offset.x * s + l.offset.y * c,
    };
}

/// The wire form of a light at a position. `channel` is -1 when the light casts
/// no shadow, and the bit that says so is part of `flags` precisely because a
/// shader that has to test it per pixel should not have to read a second byte.
fn instanceFor(l: Light2D, pos: Vec2, channel: i8) LightInstance {
    return .{
        .pos = .{ pos.x, pos.y },
        .radius = l.radius,
        .half = .{ l.radius, l.radius },
        .angle = l.angle,
        // The inner cosine is the cone shrunk by the penumbra. Clamped so a
        // penumbra of 1 (all softness, no hard core) does not invert it.
        .cos_outer = @cos(l.halfCone()),
        .cos_inner = @cos(l.halfCone() * @max(0, 1 - l.penumbra)),
        .color = l.color,
        .energy = l.energy,
        .attenuation = l.attenuation,
        .softness = @max(l.shadow_filter_smooth, 0) * 0.02,
        .gi = l.gi_contribution,
        .flags = @as(u32, @intFromEnum(l.kind)) |
            (@as(u32, @intFromEnum(l.blend)) << 3) |
            (@as(u32, @intFromEnum(l.shadow_filter)) << 5) |
            (@as(u32, if (channel >= 0) 1 else 0) << 7) |
            (@as(u32, @intCast(channel & 0xf)) << 8),
    };
}

// ── the exact Euclidean distance transform ──────────────────────────────────

/// Exact Euclidean distance transform of a binary mask, in mask cells.
///
/// Two 1D passes (rows, then columns) using the lower-envelope-of-parabolas
/// construction, so the result is the true Euclidean distance and not the chamfer
/// approximation. The cheaper approximation is off by up to 4% of the true
/// distance, and GI reads this as ambient occlusion where 4% is invisible — but
/// the same field is also what decides whether a doorway is "open", and there an
/// error is a light leaking through a wall.
///
/// Squared distances are carried between the two passes. Taking a square root
/// after the row pass and squaring again before the column pass loses precision
/// for no gain, because the transform is a min over squares throughout.
pub fn edtMask2d(
    allocator: std.mem.Allocator,
    mask: []const u8,
    out: []u16,
    w: u32,
    h: u32,
) !void {
    const n = @as(usize, w) * h;
    if (out.len < n or mask.len < n) return error.BufferTooSmall;
    if (w == 0 or h == 0) return;

    const widest = @max(w, h);
    // `sq` holds the squared row result; `col_in`/`col_out` are the column pass's
    // two halves. `edt1d` needs the input preserved while it writes the output,
    // which is why there are separate buffers rather than an in-place transform.
    const sq = try allocator.alloc(f64, n);
    defer allocator.free(sq);
    const row_in = try allocator.alloc(f64, w);
    defer allocator.free(row_in);
    const row_out = try allocator.alloc(f64, w);
    defer allocator.free(row_out);
    const col_in = try allocator.alloc(f64, h);
    defer allocator.free(col_in);
    const col_out = try allocator.alloc(f64, h);
    defer allocator.free(col_out);
    const v = try allocator.alloc(usize, widest);
    defer allocator.free(v);
    const z = try allocator.alloc(f64, widest + 1);
    defer allocator.free(z);

    // Rows: seed solid cells at zero, free cells at infinity.
    var y: usize = 0;
    while (y < h) : (y += 1) {
        const row = y * w;
        var x: usize = 0;
        while (x < w) : (x += 1) {
            row_in[x] = if (mask[row + x] != 0) 0 else std.math.inf(f64);
        }
        edt1d(row_in, row_out, v, z);
        x = 0;
        while (x < w) : (x += 1) {
            sq[row + x] = row_out[x];
            out[row + x] = @intFromFloat(@min(@sqrt(row_out[x]), 65535.0));
        }
    }

    // Columns, on the squared row distances.
    var xi: usize = 0;
    while (xi < w) : (xi += 1) {
        var yi: usize = 0;
        while (yi < h) : (yi += 1) col_in[yi] = sq[yi * w + xi];
        edt1d(col_in, col_out, v, z);
        yi = 0;
        while (yi < h) : (yi += 1) {
            out[yi * w + xi] = @intFromFloat(@min(@sqrt(col_out[yi]), 65535.0));
        }
    }
}

/// The lower envelope of parabolas. Felzenszwalb & Huttenlocher (2012).
///
/// `d_in` is preserved and `d_out` receives the squared distance to the nearest
/// zero-cost position in `d_in`. Non-negative costs only, which is what a row of
/// zeros and infinities is.
///
/// The intersection of parabola `v` and parabola `q` is
/// `(q + v) / 2 + (d[q] - d[v]) / (2 * (q - v))`. Writing it as
/// `(q - v)^2 / 2 + (d[q] - d[v]) / 2` — which is what this function did first
/// — drops the `q^2 - v^2` term, and the result is a transform that returns
/// plausible distances that are wrong by the square of the column index. It
/// passed a casual eyeball and failed an exactness test.
fn edt1d(d_in: []const f64, d_out: []f64, v: []usize, z: []f64) void {
    const n = d_in.len;
    if (n == 0) return;

    var k: usize = 0;
    v[0] = 0;
    z[0] = -std.math.inf(f64);
    z[1] = std.math.inf(f64);

    var q: usize = 1;
    while (q < n) : (q += 1) {
        s: while (true) {
            const dq = @as(i64, @intCast(q));
            const dv = @as(i64, @intCast(v[k]));
            const span = dq - dv;
            // The candidate intersection point. With an infinite cost on `q`
            // this is +inf, which correctly means "parabola q never overtakes
            // parabola v", and with both finite it is the crossing point.
            const s_new = @as(f64, @floatFromInt(dq + dv)) * 0.5 +
                (d_in[q] - d_in[v[k]]) / @as(f64, @floatFromInt(2 * span));
            if (k == 0 or s_new > z[k]) {
                k += 1;
                v[k] = q;
                z[k] = s_new;
                z[k + 1] = std.math.inf(f64);
                break :s;
            }
            k -= 1;
        }
    }

    k = 0;
    var j: usize = 0;
    while (j < n) : (j += 1) {
        while (z[k + 1] < @as(f64, @floatFromInt(j))) k += 1;
        const delta = @as(i64, @intCast(j)) - @as(i64, @intCast(v[k]));
        d_out[j] = @as(f64, @floatFromInt(delta * delta)) + d_in[v[k]];
    }
}

// ── tests ────────────────────────────────────────────────────────────────────

const testing = std.testing;

/// The polygon stores eight vertices inline, and a test usually wants to name
/// only the four it means.
fn points(v: []const f32) [components.max_occluder_points * 2]f32 {
    var out = [_]f32{0} ** (components.max_occluder_points * 2);
    @memcpy(out[0..v.len], v);
    return out;
}

test "render light: a quality setting changes the work it allows" {
    try testing.expectEqual(@as(u8, 0), Quality.off.shadowLights());
    try testing.expectEqual(@as(u8, 4), Quality.high.shadowLights());
    try testing.expect(Quality.high.maskDownscale() < Quality.low.maskDownscale());
    try testing.expect(!Quality.low.giEnabled());
}

test "render light: a polygon occluder rasterizes inside its own bounds" {
    var l = try Lighting.init(testing.allocator, .high);
    defer l.deinit();
    try l.resize(64, 64);
    try l.reserve(16, 16);
    l.rect = .{ .min = .{ .x = 0, .y = 0 }, .max = .{ .x = 64, .y = 64 } };

    var poly = components.OccluderPolygon{};
    poly.count = 4;
    // A 16x16 box at the origin.
    poly.points = points(&.{ 0, 0, 16, 0, 16, 16, 0, 16 });
    l.occluders.appendAssumeCapacity(.{ .polygon = poly, .pos = .{ .x = 0, .y = 0 }, .extent = 8 });
    l.rasterize();

    // The exact count is not the assertion — the point is that it is bounded by
    // the polygon and not the whole mask, and that a cell inside is solid while
    // one outside is not.
    try testing.expect(l.stats.raster_cells > 200 and l.stats.raster_cells < 300);
    try testing.expect(l.mask[8 * l.alloc_w + 8] != 0);
    try testing.expect(l.mask[32 * l.alloc_w + 32] == 0);
}

test "render light: a wall between a light and a point leaves that point dark" {
    var l = try Lighting.init(testing.allocator, .high);
    defer l.deinit();
    try l.resize(64, 64);
    try l.reserve(16, 16);
    l.rect = .{ .min = .{ .x = 0, .y = 0 }, .max = .{ .x = 64, .y = 64 } };

    // A vertical wall at x = 31..33, from y = 0 to y = 64.
    var poly = components.OccluderPolygon{};
    poly.count = 4;
    poly.points = points(&.{ 31, 0, 33, 0, 33, 64, 31, 64 });
    l.occluders.appendAssumeCapacity(.{ .polygon = poly, .pos = .{ .x = 0, .y = 0 }, .extent = 32 });
    l.rasterize();

    const light = components.Light2D{ .radius = 64, .kind = .point, .cast_shadows = true };
    l.lights.appendAssumeCapacity(instanceFor(light, .{ .x = 8, .y = 32 }, 0));
    l.channel_pos[0] = .{ .x = 8, .y = 32 };
    l.channel_radius[0] = 64;
    l.buildShadowMaps();

    // The far side of the wall is dark, the near side is lit. This is the whole
    // promise of the subsystem, so it is asserted directly rather than through a
    // proxy.
    const near = l.sampleLight(0, 16, 32);
    const far = l.sampleLight(0, 48, 32);
    try testing.expect(near[0] > 0.5);
    try testing.expect(far[0] < 0.05);
}

test "render light: the shadow edge is soft and deepens into the shadow" {
    var l = try Lighting.init(testing.allocator, .high);
    defer l.deinit();
    try l.resize(64, 64);
    try l.reserve(16, 16);
    l.rect = .{ .min = .{ .x = 0, .y = 0 }, .max = .{ .x = 64, .y = 64 } };

    var poly = components.OccluderPolygon{};
    poly.count = 4;
    // A two-unit wall at x = 40..42.
    poly.points = points(&.{ 40, 0, 42, 0, 42, 64, 40, 64 });
    l.occluders.appendAssumeCapacity(.{ .polygon = poly, .pos = .{ .x = 0, .y = 0 }, .extent = 32 });
    l.rasterize();
    l.lights.appendAssumeCapacity(instanceFor(
        .{ .radius = 64, .shadow_filter_smooth = 8 },
        .{ .x = 0, .y = 0 },
        0,
    ));
    l.channel_pos[0] = .{ .x = 0, .y = 0 };
    l.channel_radius[0] = 64;
    l.buildShadowMaps();

    // Just past the blocker there is still light; deeper in there is less. A
    // binary mask would give the same answer at both, so this is the assertion
    // that separates a penumbra from a stencil.
    const rim = l.sampleLight(0, 43, 32)[0];
    const deep = l.sampleLight(0, 48, 32)[0];
    try testing.expect(rim > 0 and rim < 1);
    try testing.expect(deep < rim);
}

test "render light: a spot light's cone falls off smoothly across its penumbra" {
    var l = try Lighting.init(testing.allocator, .high);
    defer l.deinit();
    try l.resize(128, 128);
    try l.reserve(16, 16);
    l.rect = .{ .min = .{ .x = 0, .y = 0 }, .max = .{ .x = 128, .y = 128 } };
    l.lights.appendAssumeCapacity(instanceFor(
        .{
            .kind = .spot,
            .radius = 256,
            .angle = 0,
            .cone_angle = 1.5707963268, // 90 degrees
            .penumbra = 0.5,
            .cast_shadows = false,
        },
        .{ .x = 64, .y = 64 },
        -1,
    ));

    // Inside the cone, further out, the light dims; behind the cone there is
    // nothing; and at the cone's edge it is between the two rather than either.
    const center = l.sampleLight(0, 96, 64)[0];
    const far = l.sampleLight(0, 160, 64)[0];
    const behind = l.sampleLight(0, 34, 64)[0];
    const edge = l.sampleLight(0, 88, 84)[0];

    try testing.expect(center > far and far > 0);
    try testing.expectEqual(@as(f32, 0), behind);
    try testing.expect(edge > 0 and edge < center);
}

test "render light: the three blend modes do three different things" {
    var l = try Lighting.init(testing.allocator, .high);
    defer l.deinit();
    try l.resize(32, 32);
    try l.reserve(16, 16);
    l.rect = .{ .min = .{ .x = 0, .y = 0 }, .max = .{ .x = 32, .y = 32 } };

    const add = components.Light2D{ .radius = 64, .color = .{ 0.5, 0.5, 0.5, 1 } };
    var sub = add;
    sub.blend = .subtract;
    var mix = add;
    mix.blend = .mix;

    l.lights.appendAssumeCapacity(instanceFor(add, .{ .x = 0, .y = 0 }, -1));
    l.lights.appendAssumeCapacity(instanceFor(sub, .{ .x = 0, .y = 0 }, -1));
    l.lights.appendAssumeCapacity(instanceFor(mix, .{ .x = 0, .y = 0 }, -1));

    const dst = [3]f32{ 0.4, 0.4, 0.4 };
    const a = l.applyTo(0, 0, 0, dst);
    const s = l.applyTo(1, 0, 0, dst);
    const m = l.applyTo(2, 0, 0, dst);
    try testing.expect(a[0] > dst[0]);
    try testing.expect(s[0] < dst[0]);
    // `mix` blends toward the lit colour by how much of the light arrives, so
    // a grey light on a mid-grey surface is darker, not brighter.
    try testing.expect(m[0] < dst[0]);
}

test "render light: the distance field is exact" {
    var l = try Lighting.init(testing.allocator, .high);
    defer l.deinit();
    try l.resize(16, 16);
    try l.reserve(16, 16);
    l.rect = .{ .min = .{ .x = 0, .y = 0 }, .max = .{ .x = 16, .y = 16 } };

    // A solid left half.
    var i: usize = 0;
    while (i < 16 * 16) : (i += 1) {
        l.mask[i] = if (i % 16 < 8) 255 else 0;
    }

    try edtMask2d(testing.allocator, l.mask, l.sdf, 16, 16);

    // Cell (0,0) is solid, so its distance is zero. Cell (8,0) is the first
    // free column, one cell from the wall; the far corner is eight away, which
    // is the assertion that caught a wrong-by-one in the expectation rather
    // than in the transform.
    try testing.expectEqual(@as(u16, 0), l.sdf[0]);
    try testing.expectEqual(@as(u16, 1), l.sdf[8]);
    try testing.expectEqual(@as(u16, 2), l.sdf[9]);
    try testing.expectEqual(@as(u16, 8), l.sdf[15]);
}

test "render light: GI reports an enclosed point as darker than an open one" {
    var l = try Lighting.init(testing.allocator, .high);
    defer l.deinit();
    try l.resize(64, 64);
    try l.reserve(16, 16);
    l.rect = .{ .min = .{ .x = 0, .y = 0 }, .max = .{ .x = 64, .y = 64 } };

    var poly = components.OccluderPolygon{};
    poly.count = 4;
    poly.points = points(&.{ 0, 0, 4, 0, 4, 64, 0, 64 });
    l.occluders.appendAssumeCapacity(.{ .polygon = poly, .pos = .{ .x = 0, .y = 0 }, .extent = 32 });
    l.rasterize();
    l.dirty = true;
    l.gi_interval_ns = 0;
    l.updateSdf(0);

    const near_wall = l.sampleGi(6, 32);
    const middle = l.sampleGi(40, 32);
    try testing.expect(near_wall < middle);
    try testing.expectEqual(@as(f32, 1.0), middle);
}

test "render light: four lights get shadow channels and the rest still light" {
    var l = try Lighting.init(testing.allocator, .high);
    defer l.deinit();
    try l.resize(64, 64);
    try l.reserve(16, 16);
    l.rect = .{ .min = .{ .x = 0, .y = 0 }, .max = .{ .x = 64, .y = 64 } };

    var world = World.init(testing.allocator);
    defer world.deinit();
    var i: usize = 0;
    while (i < 8) : (i += 1) {
        _ = try world.spawn(.{
            components.Transform{ .position = .{ .x = @as(f32, @floatFromInt(i % 4)) * 8, .y = 32 } },
            components.Light2D{ .radius = 32, .cast_shadows = true },
        });
    }
    l.collect(&world, l.rect);
    l.rasterize();
    l.buildShadowMaps();

    try testing.expectEqual(@as(u32, 8), l.stats.lights);
    var shadowed: u32 = 0;
    var unshadowed: u32 = 0;
    for (l.lights.items) |inst| {
        if (inst.shadowChannel() >= 0) shadowed += 1 else unshadowed += 1;
    }
    try testing.expectEqual(@as(u32, 4), shadowed);
    try testing.expectEqual(@as(u32, 4), unshadowed);
    // And the unshadowed ones are not dark: they just cast no shadow.
    try testing.expect(l.sampleLight(0, 0, 32)[0] > 0);
}

test "render light: a static scene does not rebuild its shadow maps" {
    var l = try Lighting.init(testing.allocator, .high);
    defer l.deinit();
    try l.resize(64, 64);
    try l.reserve(16, 16);
    l.rect = .{ .min = .{ .x = 0, .y = 0 }, .max = .{ .x = 64, .y = 64 } };
    var poly = components.OccluderPolygon{};
    poly.count = 4;
    poly.points = points(&.{ 31, 0, 33, 0, 33, 64, 31, 64 });
    l.occluders.appendAssumeCapacity(.{ .polygon = poly, .pos = .{ .x = 0, .y = 0 }, .extent = 32 });
    l.rasterize();
    l.dirty = false;
    l.lights.appendAssumeCapacity(instanceFor(components.Light2D{ .radius = 64 }, .{ .x = 8, .y = 32 }, 0));
    l.channel_pos[0] = .{ .x = 8, .y = 32 };
    l.channel_radius[0] = 64;
    l.buildShadowMaps();
    const first = l.stats.sweep_steps;
    try testing.expect(first > 0);

    // A frame where nothing moved costs no ray steps, and says so.
    l.buildShadowMaps();
    try testing.expectEqual(@as(u64, 0), l.stats.sweep_steps);
    try testing.expectEqual(@as(u32, 1), l.stats.sweep_skips);
}
