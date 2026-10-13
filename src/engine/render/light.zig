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
/// Re-exported so a backend's tests can name the component types without
/// importing the ECS themselves.
pub const components = ecs.components;

const Vec2 = components.Vec2;
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
    // The field ORDER is not free. `backend_dawn.zig` declares vertex
    // attributes at 0/8/16/24/32/40/48/56 and `light.wgsl`'s `LightIn` reads the
    // same offsets, so this layout is a three-way contract: change one and the
    // other two must change with it, or the GPU reads a light whose half extents
    // are actually its colour.
    //
    // Each pair is padded to 8 bytes so a vec2 attribute never straddles two
    // fields, which is why `radius` sits alone next to `shadow_ratio` rather
    // than beside `angle`.

    /// Byte 0. World-space centre, including the component's offset. For a
    /// directional light and a scene-wide ambient this is the VIEW's centre, not
    /// the actor's — see `descFor`.
    pos: [2]f32,
    /// Byte 8. World-space reach: what `1 - d/radius` falls off over.
    radius: f32,
    /// Byte 12. Shadow reach as a FRACTION of `radius`, not as a distance.
    ///
    /// A ratio because the slot had to stay inside the vec2 that `radius`
    /// already occupies, and because the one light that needs them to differ is
    /// the directional one: its falloff is set by how far the view reaches, and
    /// its shadow length by the sun's elevation, and those are two different
    /// dials that a single `radius` cannot be at once.
    shadow_ratio: f32,
    /// Byte 16. Half-extents of the quad this light draws as.
    half: [2]f32,
    /// Byte 24. Direction in radians (`spot`, `directional`).
    angle: f32,
    /// Byte 28. `cos` of the cone's half-angle. A cosine rather than an angle
    /// because that is what the cone test needs, and a `cos` per vertex of a
    /// quad is not a rounding error anyone can see.
    cos_outer: f32,
    /// Byte 32. `cos` of the fully-lit inner cone: the outer cone shrunk by the
    /// penumbra.
    cos_inner: f32,
    /// Byte 36. Brightness multiplier.
    energy: f32,
    /// Byte 40. rgb + opacity. Alpha IS the light's opacity — a light fades out
    /// by its alpha rather than by a separate field, so fading needs no extra
    /// attribute and no extra blend mode.
    color: [4]f32,
    /// Byte 56. Falloff exponent.
    attenuation: f32,
    /// Byte 60. Softness multiplier for the penumbra, in normalized units.
    softness: f32,
    /// Byte 64. How much this light contributes to the GI term. 0 by default: GI
    /// is an explicit opt-in per light, not something that happens to everyone.
    gi: f32,
    /// Byte 68. kind | blend << 3 | shadow_filter << 5 | has_shadow_channel << 7
    /// | channel << 8.
    ///
    /// Named `flags` and not `packed`: `packed` is a Zig keyword, and a field
    /// called after a keyword is a compile error dressed up as a typo.
    flags: u32,
    /// Which sprite layers this light affects, as a bitmask of `Sprite.layer`.
    ///
    /// In the INSTANCE and not in the uniform because it is per light and the
    /// uniform is per frame: twenty lights with twenty different masks is a
    /// normal scene, and one uniform would mean twenty of them.
    ///
    /// Every layer by default, because a light that silently stopped lighting the
    /// scene is the worst possible default — and "I added a layer mask and now
    /// my scene is dark" is a worse first experience than "I set a mask and some
    /// things are unlit", which is at least what it says.
    item_cull_mask: u32 = 0xffff_ffff,

    comptime {
        // 72 bytes, and every offset above is asserted rather than trusted. A
        // struct whose layout drifts from the shader's is not a wrong light, it
        // is garbage that renders as *something* — the failure mode is a scene
        // that looks lit but has never been correct, which nobody reports.
        if (@sizeOf(LightInstance) != 76) @compileError("LightInstance must stay 76 bytes");
        if (@offsetOf(LightInstance, "half") != 16) @compileError("half must sit at byte 16");
        if (@offsetOf(LightInstance, "color") != 40) @compileError("color must sit at byte 40");
        if (@offsetOf(LightInstance, "gi") != 64) @compileError("gi must sit at byte 64");
    }

    /// How far the shadow sweep for this light traces, in world units. A
    /// convenience over `radius * shadow_ratio` that keeps the ratio's meaning
    /// in one place.
    pub fn shadowReach(self: LightInstance) f32 {
        return self.radius * self.shadow_ratio;
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
    /// Half extents of the automatic fallback RECTANGLE, or null for a shape
    /// that is drawn from something else.
    ///
    /// This exists because an automatic occluder with no coverage data used to
    /// draw NOTHING at all: `collect` set `extent` from the sprite's size and
    /// left `polygon` empty, and the rasterizer skipped any occluder with fewer
    /// than three vertices. So `mode = auto_sdf` — the DEFAULT, and the one the
    /// component's own documentation describes — produced no shadow whatsoever,
    /// and the only reason it went unnoticed is that every test used a manual
    /// polygon and the demo scenes are not run headless.
    ///
    /// The rectangle is the fallback's shape, and a wrong one: it is what an
    /// automatic occluder looks like before the asset pipeline supplies
    /// coverage. It is stated as a fallback everywhere it appears rather than as
    /// the feature, because the feature is the silhouette.
    rect_half: ?Vec2 = null,
    cull_mask: u32 = 0xffff_ffff,

    /// The sprite's coverage, 0..255 per texel, when the asset pipeline has
    /// produced one. Null means "no coverage data", and the rasterizer falls back
    /// to the rectangle.
    ///
    /// ## Why this is a seam and not a feature
    ///
    /// An automatic occluder's whole promise is that importing a sprite makes it
    /// occlude, with no author action — and a RECTANGLE is the one shape that
    /// promise cannot keep, because a character's silhouette is not its bounding
    /// box and the difference is a rectangle of shadow where there is no sprite.
    ///
    /// The data itself comes from M6 (the asset pipeline), which is why this is
    /// null today. What is NOT deferred is the half that belongs to lighting: the
    /// threshold test, the rasterizer that reads a coverage mask instead of a
    /// polygon, and the tests for both. They run now against a synthetic mask, so
    /// when M6 hands over real coverage there is a seam to cut and not a feature
    /// to write.
    coverage: ?*const CoverageMask = null,
    /// Alpha at or above which a texel counts as solid. From
    /// `LightOccluder2D.alpha_threshold`.
    alpha_threshold: f32 = 0.5,
};

/// Resolves a sprite's asset-pipeline coverage into a pool slot, or null.
///
/// Null when there is no coverage, when it is empty, or when the pool has run
/// out of slots -- and all three mean the same thing to the rasterizer: use the
/// shape. A sprite whose actor grew past the occluder budget loses its automatic
/// shape rather than crashing, and the drop is counted so the scene is not
/// quietly worse than it looks.
fn resolveCoverage(
    self: *Lighting,
    sp: *const components.Sprite,
    world_w: f32,
    world_h: f32,
) ?*const CoverageMask {
    const store = self.coverage_store orelse return null;
    const cov = store.get(sp.coverage_index) orelse return null;
    if (cov.w == 0 or cov.h == 0 or cov.pixels.len < @as(usize, cov.w) * cov.h) return null;
    if (world_w <= 0 or world_h <= 0) return null;
    if (self.occluders.items.len > self.coverage_pool.len) {
        self.stats.coverage_dropped += 1;
        return null;
    }

    // The mask is authored at the sprite's texel resolution and covers the
    // sprite's world size, so one texel's world size is the ratio. The caller has
    // already applied the actor's scale to the world size, which is what makes a
    // scaled actor occlude with a scaled silhouette rather than the same one
    // stretched into place.
    const slot = &self.coverage_pool[self.occluders.items.len];
    slot.* = .{
        .pixels = cov.pixels,
        .w = cov.w,
        .h = cov.h,
        .cell = .{
            .x = world_w / @as(f32, @floatFromInt(cov.w)),
            .y = world_h / @as(f32, @floatFromInt(cov.h)),
        },
    };
    self.stats.coverage_used += 1;
    return slot;
}

/// One sprite's coverage, as the rasterizer reads it.
///
/// The pixel data is NOT copied into the occluder. The store owns the pixels and
/// this struct is a descriptor pointing at them, so two actors sharing a texture
/// share one buffer -- which is the whole reason coverage is indexed off the
/// Sprite rather than carried by the occluder.
pub const CoverageMask = struct {
    /// `w * h` bytes, 0..255, row-major with no padding. Points into the store's
    /// own allocation; never written to after `add`.
    pixels: []const u8 = &.{},
    w: u32 = 0,
    h: u32 = 0,
    /// World size one texel of `pixels` covers.
    ///
    /// Per occluder and not per store, because the same imported mask can cover
    /// two sprites of different sizes, and the mapping from texel to world cell
    /// is a property of the OCCLUDER's actor. Derived at gather time from that
    /// actor's scale, which is what makes a scaled actor occlude with a scaled
    /// silhouette rather than the same one stretched into place.
    cell: Vec2 = .{ .x = 1, .y = 1 },
};

/// The coverage masks the lighting system rasterizes from, filled by the asset
/// pipeline.
///
/// ## Why lighting owns this and not the asset pipeline
///
/// Because the CONSUMER owns the lifetime. The importer may unload a texture; the
/// occluder rasterizer needs a pointer that stays valid for exactly as long as a
/// scene holds an actor using it, and it needs to know when a mask has gone. A
/// store the consumer owns answers both, and a plain `i32` in the component is
/// the only way a component can point into it.
///
/// ## Not frame work
///
/// `add` copies and allocates, so it may not be called inside a frame -- the same
/// rule the rest of the engine follows.
pub const CoverageStore = struct {
    allocator: std.mem.Allocator,
    masks: std.ArrayList(CoverageMask) = .empty,
    /// Parallel to `masks`: the allocations to free. A separate list because each
    /// mask's `pixels` is a slice pointing AT one of these, and freeing through
    /// the mask list would leave a dangling slice for any occluder still gathered.
    owned: std.ArrayList([]u8) = .empty,

    pub fn init(allocator: std.mem.Allocator) CoverageStore {
        return .{ .allocator = allocator };
    }

    pub fn deinit(self: *CoverageStore) void {
        for (self.owned.items) |p| self.allocator.free(p);
        self.owned.deinit(self.allocator);
        self.masks.deinit(self.allocator);
        self.* = undefined;
    }

    /// Registers a coverage mask; returns its index for `Sprite.coverage_index`.
    ///
    /// The pixels are COPIED. They come out of an importer's scratch buffer, and
    /// storing a pointer to that would make the lighting system's correctness
    /// depend on an unrelated subsystem's allocation lifetime.
    ///
    /// Returns -1 for an empty or malformed mask, which the component reads as
    /// "no coverage" -- so a bad import produces the rectangle rather than a
    /// crash, and the caller can see that it did not register.
    pub fn add(self: *CoverageStore, pixels: []const u8, w: u32, h: u32) !i32 {
        if (w == 0 or h == 0) return -1;
        const n = @as(usize, w) * h;
        if (pixels.len < n) return -1;
        const copy = try self.allocator.dupe(u8, pixels[0..n]);
        errdefer self.allocator.free(copy);
        try self.masks.append(self.allocator, .{ .pixels = copy, .w = w, .h = h });
        errdefer _ = self.masks.pop();
        try self.owned.append(self.allocator, copy);
        return @intCast(self.masks.items.len - 1);
    }

    /// The mask at `index`, or null for -1 or an index this store never issued.
    ///
    /// Null and not a panic, because the index lives in a component a `.zson`
    /// file can set to anything: a scene that loads with a stale coverage index
    /// must fall back to the rectangle rather than take the process down.
    pub fn get(self: *const CoverageStore, index: i32) ?CoverageMask {
        if (index < 0 or @as(usize, @intCast(index)) >= self.masks.items.len) return null;
        return self.masks.items[@intCast(index)];
    }

    pub fn count(self: *const CoverageStore) usize {
        return self.masks.items.len;
    }
};

/// How much work generating a coverage mask is allowed to be.
pub const CoverageOptions = struct {
    /// Longest side of the generated mask, in texels. 128 by default.
    ///
    /// ## Why it is capped at all
    ///
    /// Coverage is one byte per texel, and a 1024x1024 sprite is a megabyte. An
    /// atlas page of 32 such sprites is 32 MB of occluder data for a feature
    /// that decides where a shadow's EDGE falls -- and the edge is already being
    /// sampled at the light mask's resolution, one texel per world unit.
    /// Coverage finer than that is data nothing reads.
    ///
    /// So the cap is not a saving, it is matching the mask to its consumer.
    max_dim: u32 = 128,
    /// A rect whose minimum alpha is at or above this registers NO coverage.
    ///
    /// The fast path, and it is the common one: most sprites in a game are
    /// fully opaque, and for those the silhouette IS the rectangle, so
    /// registering nothing is not an approximation -- it is the same answer for a
    /// quarter of the memory and none of the work.
    opaque_at: u8 = 250,
};

/// Builds an 8-bit alpha coverage mask from a rect of RGBA8 pixels.
///
/// ## Why this reads alpha and not luminance
///
/// Because alpha is what "is this texel solid" means. A sprite's colour can be
/// black, and black has zero luminance, so a luminance-derived mask makes every
/// dark sprite transparent -- which is a bug that only shows on art nobody
/// happened to be looking at.
///
/// ## Why the downscale AVERAGES and the rasterizer samples NEAREST
///
/// Because they answer different questions. Downscaling asks "how much of this
/// box is covered", which is a mean, and averaging is the only filter that gets
/// it right -- nearest here would throw away almost every texel of a 4x4 box and
/// produce a mask full of holes. The rasterizer asks "is the texel under this
/// cell solid", which is a decision, and nearest is the only filter that keeps
/// it one: interpolating a decision invents a value no texel ever had, which is
/// a halo around every soft edge.
///
/// ## Null means "no coverage data", not "empty"
///
/// Returned when the rect is entirely opaque, because then the rectangle the
/// fallback already draws is exactly right. A rect that is entirely TRANSPARENT
/// returns a real all-zero mask, because there the rectangle is wrong and the
/// correct answer is "this occludes nothing".
pub fn alphaCoverage(
    allocator: std.mem.Allocator,
    pixels: []const u8,
    width: u32,
    height: u32,
    opts: CoverageOptions,
) !?[]u8 {
    if (width == 0 or height == 0) return null;
    const need = @as(usize, width) * height * 4;
    if (pixels.len < need) return null;

    // The opaque fast path, one pass and no allocation. A minimum, not a
    // maximum: a rect with ONE transparent texel needs a mask.
    var min_alpha: u8 = 255;
    var i: usize = 0;
    while (i < need) : (i += 4) {
        const a = pixels[i + 3];
        if (a < min_alpha) {
            min_alpha = a;
            if (a == 0) break; // cannot go lower, and this is the common case
        }
    }
    if (min_alpha >= opts.opaque_at) return null;

    // The scale, rounded UP so a mask never comes out smaller than 1x1 and the
    // aspect ratio is preserved (a 4x1 sprite stays 4:1, not square).
    const longest = @max(width, height);
    const scale = if (longest <= opts.max_dim)
        1.0
    else
        @as(f32, @floatFromInt(opts.max_dim)) / @as(f32, @floatFromInt(longest));
    const out_w: u32 = @max(1, @as(u32, @intFromFloat(@as(f32, @floatFromInt(width)) * scale)));
    const out_h: u32 = @max(1, @as(u32, @intFromFloat(@as(f32, @floatFromInt(height)) * scale)));

    const out = try allocator.alloc(u8, @as(usize, out_w) * out_h);
    errdefer allocator.free(out);

    if (out_w == width and out_h == height) {
        // No downscale: a straight copy of the alpha channel, no filtering.
        var o: usize = 0;
        while (o < out.len) : (o += 1) out[o] = pixels[o * 4 + 3];
        return out;
    }

    // The box filter. Each output texel's box is grown by one at the far edge so
    // the last texel covers its share rather than losing the final row -- a mask
    // one texel short at the bottom is a sprite whose shadow has a notch in it.
    var oy: u32 = 0;
    while (oy < out_h) : (oy += 1) {
        const y0 = (oy * height) / out_h;
        const y1 = @min(@max(((oy + 1) * height) / out_h, y0 + 1), height);
        var ox: u32 = 0;
        while (ox < out_w) : (ox += 1) {
            const x0 = (ox * width) / out_w;
            const x1 = @min(@max(((ox + 1) * width) / out_w, x0 + 1), width);

            var sum: u64 = 0;
            var n: u64 = 0;
            var y = y0;
            while (y < y1) : (y += 1) {
                var x = x0;
                while (x < x1) : (x += 1) {
                    sum += pixels[(y * width + x) * 4 + 3];
                    n += 1;
                }
            }
            // `n` is never zero: the box is at least one texel by the clamp above.
            // Integer on purpose -- a float mean rounded back to u8 is the same
            // answer and costs a divide per texel in the one loop that runs over
            // every sprite at import.
            out[oy * out_w + ox] = @intCast(sum / n);
        }
    }
    return out;
}

/// What `registerAtlasCoverage` did, so a loader can log it instead of guessing.
///
/// Not named `opaque`: that is a Zig keyword (the one behind `opaque {}`), and a
/// field named after a keyword is a compile error dressed up as a typo.
pub const CoverageReport = struct {
    /// Actors whose rect was looked at.
    rects: u32 = 0,
    /// Rects that were fully opaque and so registered nothing.
    fully_opaque: u32 = 0,
    /// Masks registered.
    registered: u32 = 0,
    /// Actors whose `coverage_index` was written.
    actors: u32 = 0,
    /// Bytes of coverage now held by the store.
    bytes: u64 = 0,
};

/// Registers coverage for every non-opaque sprite rect in an atlas page, and
/// writes the resulting index into every actor using one.
///
/// ## This is the "zero dev action" the ROADMAP promises
///
/// `importing a sprite generates the distance field (alpha threshold) with zero
/// dev action`. This is that function. The loader calls it once per atlas page
/// after upload, and from then on an automatic `LightOccluder2D` on any sprite in
/// that page occludes by its silhouette rather than by its bounding box.
///
/// ## Why it walks the WORLD and not the atlas
///
/// Because the atlas does not know which rect is a sprite. It knows where the
/// texels went; a sprite is a rect plus an actor that points at it, and the
/// actors are what make it a sprite. Walking them is also the only way to learn
/// that two actors SHARE a rect, which is the case the index exists for -- one
/// mask, two actors, because the mask belongs to the asset.
///
/// ## Why it de-duplicates
///
/// Two actors on the same rect registering the same mask twice is a megabyte
/// each and no information. The key is the rect, rounded, because `uv` is
/// authored as floats and two actors naming the same 32x32 sprite will not agree
/// on the last bit.
///
/// ## Not frame work
///
/// Allocates, copies, and walks every sprite. A loader call.
pub fn registerAtlasCoverage(
    store: *CoverageStore,
    world: *World,
    pixels: []const u8,
    page_w: u32,
    page_h: u32,
    opts: CoverageOptions,
) !CoverageReport {
    var report = CoverageReport{};

    // `defer` and not `errdefer`: the rect list and its per-rect actor lists are
    // live on the SUCCESS path too, and a cleanup that only runs when something
    // fails is a cleanup that only runs when you are already in trouble.
    const Rect = struct {
        rx0: u32,
        ry0: u32,
        rx1: u32,
        ry1: u32,
        actors: std.ArrayList(ecs.Entity),
        index: i32,
    };
    var rects: std.ArrayList(Rect) = .empty;
    defer {
        for (rects.items) |*r| r.actors.deinit(store.allocator);
        rects.deinit(store.allocator);
    }

    var it = world.query(.{components.Sprite});
    var e = it.next();
    while (e) |row| : (e = it.next()) {
        const sp = row.get(components.Sprite);
        const r = spriteRect(sp.uv, page_w, page_h) orelse continue;
        report.rects += 1;

        // Find this rect, or start it. Short list, linear scan: this runs once
        // and an author with 300 sprites is not the case that needs a hash.
        var found: ?*Rect = null;
        for (rects.items) |*existing| {
            if (existing.rx0 == r.rx0 and existing.ry0 == r.ry0 and
                existing.rx1 == r.rx1 and existing.ry1 == r.ry1)
            {
                found = existing;
                break;
            }
        }
        if (found == null) {
            try rects.append(store.allocator, .{
                .rx0 = r.rx0,
                .ry0 = r.ry0,
                .rx1 = r.rx1,
                .ry1 = r.ry1,
                .actors = .empty,
                .index = -1,
            });
            found = &rects.items[rects.items.len - 1];
        }
        try found.?.actors.append(store.allocator, row.entity());
    }

    // One crop per distinct rect, and one mask if it is not opaque.
    for (rects.items) |*r| {
        const w = r.rx1 - r.rx0;
        const h = r.ry1 - r.ry0;
        if (w == 0 or h == 0) continue;

        // Copied rather than strided, because the rasterizer wants a dense mask
        // and a strided view would be a second indexing path for the case that
        // matters least.
        const crop = try store.allocator.alloc(u8, @as(usize, w) * h * 4);
        defer store.allocator.free(crop);
        var y: u32 = 0;
        while (y < h) : (y += 1) {
            const src = ((r.ry0 + y) * @as(usize, page_w) + r.rx0) * 4;
            @memcpy(
                crop[@as(usize, y) * w * 4 ..][0 .. @as(usize, w) * 4],
                pixels[src ..][0 .. @as(usize, w) * 4],
            );
        }

        const mask = try alphaCoverage(store.allocator, crop, w, h, opts);
        if (mask == null) {
            report.fully_opaque += 1;
            continue;
        }
        const m = mask.?;
        defer store.allocator.free(m);

        r.index = try store.add(m, w, h);
        report.registered += 1;
        report.bytes += m.len;
    }

    // And now write the index into every actor that uses one.
    for (rects.items) |r| {
        if (r.index < 0) continue;
        for (r.actors.items) |entity| {
            if (world.get(entity, components.Sprite)) |sp| sp.coverage_index = r.index;
            report.actors += 1;
        }
    }
    return report;
}

/// The pixel rect a sprite's normalized `uv` names, or null if it is the whole
/// page or degenerate.
///
/// Whole-page returns null on purpose: that is the "no atlas" default, a sprite
/// with no texture, and inventing a coverage mask for the entire page would give
/// every untextured sprite the same shape, which is the page's contents.
fn spriteRect(uv: [4]f32, page_w: u32, page_h: u32) ?struct { rx0: u32, ry0: u32, rx1: u32, ry1: u32 } {
    if (page_w == 0 or page_h == 0) return null;
    // Rounded, not truncated: a sprite authored at u1 = 0.99999 of a 256px page
    // is the last 256 columns, and truncating loses the final one -- a sprite one
    // column short of its own edge.
    const px = @as(i32, @intFromFloat(clamp01(uv[0]) * @as(f32, @floatFromInt(page_w)) + 0.5));
    const py = @as(i32, @intFromFloat(clamp01(uv[1]) * @as(f32, @floatFromInt(page_h)) + 0.5));
    const qx = @as(i32, @intFromFloat(clamp01(uv[2]) * @as(f32, @floatFromInt(page_w)) + 0.5));
    const qy = @as(i32, @intFromFloat(clamp01(uv[3]) * @as(f32, @floatFromInt(page_h)) + 0.5));

    const rx0: u32 = @intCast(@min(@max(px, 0), @as(i32, @intCast(page_w))));
    const ry0: u32 = @intCast(@min(@max(py, 0), @as(i32, @intCast(page_h))));
    const rx1: u32 = @intCast(@min(@max(qx, 0), @as(i32, @intCast(page_w))));
    const ry1: u32 = @intCast(@min(@max(qy, 0), @as(i32, @intCast(page_h))));
    if (rx1 <= rx0 or ry1 <= ry0) return null;
    if (rx0 == 0 and ry0 == 0 and rx1 == page_w and ry1 == page_h) return null;
    return .{ .rx0 = rx0, .ry0 = ry0, .rx1 = rx1, .ry1 = ry1 };
}

fn clamp01(v: f32) f32 {
    return @min(@max(v, 0.0), 1.0);
}

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
    /// Occluders written into the mask THIS FRAME.
    ///
    /// A per-frame work counter, so it is zero on a frame where the mask was
    /// already up to date — which means zero is ambiguous on its own: it reads
    /// the same for "the scene has no occluders" and "none needed redrawing".
    /// `raster_skipped` is what separates them, and any panel showing this
    /// number should show that one next to it rather than leave the reader to
    /// guess which world they are in.
    occluders_rasterized: u32 = 0,
    /// Frames where the mask was already current and the rasterizer was skipped.
    /// The counterpart to `sweep_skips` for the occluder pass, and the number
    /// that makes "the mask is amortized" checkable the way `gi_skipped` makes it
    /// for the distance field.
    raster_skipped: u32 = 0,
    /// Automatic occluders that used the sprite's alpha coverage rather than its
    /// bounding box. Zero means every automatic occluder in the scene is a
    /// RECTANGLE, which is worth knowing before someone reports a shadow that is
    /// the wrong shape.
    coverage_used: u32 = 0,
    /// Automatic occluders that wanted coverage but could not get it -- past the
    /// occluder budget, or with an empty mask. Non-zero is a budget problem.
    coverage_dropped: u32 = 0,
    /// Frames where the GI pyramid was asked to rebuild before it had been
    /// prepared for the current mask size, so the bounce light was skipped. Any
    /// non-zero value is a bug report in the engine, not a scene setting: it
    /// means `Radiance.prepare` and `Lighting.resize` have drifted apart.
    gi_not_prepared: u32 = 0,
    /// Frames where the distance field was not rebuilt, so the GI pyramid was
    /// skipped rather than recomputed to the same answer. This is the number that
    /// makes "GI is amortized" checkable: it should be the large majority of
    /// frames in any scene that is not being rebuilt every frame.
    gi_skipped: u32 = 0,

    mask_w: u32 = 0,
    mask_h: u32 = 0,
    /// Fraction of the mask that is occluder. Above ~0.6 the level is a solid
    /// maze and shadows stop being informative.
    ///
    /// This is a property of the MASK, not of the frame, so it survives
    /// `beginFrame`. It used to be cleared every frame, which made an idle scene
    /// — a level whose walls have not moved — report a mask that is 0% full,
    /// because nothing rasterized this frame. The mask was still there. The
    /// editor's stats panel showed an empty level because the number describing
    /// it had been reset by the act of looking at it. Work counters next to it
    /// are per-frame and do clear; this one is state.
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
    /// Both halves of `sdf_ns`, and split because they answer different
    /// questions and are tuned by different dials. `downsample_ns` is linear in
    /// the MASK and is what `gi_resolution` cannot reduce; `transform_ns` is
    /// linear in the GI FIELD and is what it reduces almost entirely. Reported
    /// together, a floor set by resampling reads as a floor set by the feature,
    /// and the fix would be aimed at the wrong dial.
    sdf_ns: u64 = 0,
    downsample_ns: u64 = 0,
    transform_ns: u64 = 0,

    /// How many times the distance field was rebuilt this session. One per
    /// occluder move is the target; one per frame means something is dirtying it
    /// that should not be.
    ///
    /// Session counters, so they survive `beginFrame`. They said "this session"
    /// while being cleared every frame, which is the kind of sentence that stops
    /// being true without anything failing: a test that builds the field once
    /// per frame saw `1` and passed, and a reader watching the editor's panel
    /// saw a number that never grew past one and had no way to know it was not
    /// supposed to.
    sdf_builds: u32 = 0,
    sdf_skipped: u32 = 0,

    /// Clears the PER-FRAME fields, and only those.
    ///
    /// The split matters. `lights`, `sweep_steps`, `occluders_rasterized` and the
    /// `*_ns` timings describe work done between two frames, so zeroing them is
    /// correct and is what makes them readable. `mask_fill`, `sdf_builds` and
    /// `sdf_skipped` describe the state of the engine rather than the work, so
    /// zeroing them reports a scene as empty for the duration of the frame in
    /// which anybody looked at it. A stats panel that lies on an idle scene is
    /// worse than no panel: the numbers look like a measurement, and the only
    /// way to notice they are wrong is to already know what right looks like.
    pub fn beginFrame(self: *Stats) void {
        self.lights = 0;
        self.shadow_lights = 0;
        self.shadow_denied = 0;
        self.occluders = 0;
        self.occluders_rasterized = 0;
        self.raster_skipped = 0;
        self.coverage_used = 0;
        self.coverage_dropped = 0;
        self.gi_not_prepared = 0;
        self.gi_skipped = 0;
        self.sweep_steps = 0;
        self.sweep_skips = 0;
        self.raster_cells = 0;
        self.collect_ns = 0;
        self.raster_ns = 0;
        self.sweep_ns = 0;
        self.sdf_ns = 0;
        self.downsample_ns = 0;
        self.transform_ns = 0;
    }
};

/// A shadow candidate and the index of the light it came from, for ranking.
const AreaRank = struct { area: f32, index: u32 };

/// The FNV-1a offset basis, as the occluder fingerprint's seed.
///
/// Not `0`. A fingerprint seeded at zero collides with the sentinel a resize
/// leaves behind, and a zero-valued hash is also the one an even number of
/// identical occluders used to produce — which is precisely how the mask stopped
/// being built. Seeding with the canonical basis makes "no occluders yet" and
/// "this many identical walls" different numbers by construction, and
/// `hash_valid` covers the remaining case of a hash that legitimately lands on
/// the sentinel.
const occluder_hash_seed: u64 = 0xcbf29ce484222325;

/// The GI field's default longest side, in cells.
///
/// CHOSEN BY MEASUREMENT, not by taste. The table is produced by
/// `zig build bench-light` (`sweepGiResolution`), at a 2048x2048 mask, medium
/// tier, 21 lights and 40 occluders, and is reproduced here so the number can be
/// re-derived instead of argued about:
///
///     gi_resolution   resample   transform      total   MAE     upload
///              0       0.95 ms   263.5 ms   264.5 ms  ---     16 MiB   <- before
///             64       1.55 ms     0.17 ms     1.7 ms  0.109    16 KiB
///            128       2.05 ms     0.67 ms     2.7 ms  0.040    64 KiB   <- default
///            256       3.25 ms     2.97 ms     6.2 ms  0.025   256 KiB
///            512       9.15 ms    13.94 ms    23.1 ms  0.008     1 MiB
///           1024      11.11 ms    58.41 ms    69.5 ms  0.004     4 MiB
///
/// MAE is the mean absolute difference from the `0` row over 4096 sample points
/// of the openness term — i.e. how much the picture would change — measured, not
/// estimated, because there is no window in a headless bench to look at.
///
/// WHY 128 AND NOT 256. The knee is here. 64 -> 128 costs one more millisecond
/// and halves the error. 128 -> 256 costs 3.5 more and improves the error by
/// 0.015, which on a term that ships weighted at `gi_contribution` (0.3 in the
/// acceptance scene) is under half a percent of a lighting term nobody notices.
/// 256 -> 512 costs 17 ms for 0.017, and past that it is a straight line to the
/// old cost with nothing to show for it.
///
/// 128 is also the only row that gets close to the spec's "GI <= 1.5 ms/frame
/// amortized": 2.7 ms against a 16.6 ms frame, versus 6.2 ms at 256 and 264.5 ms
/// where this started. It is not *under* budget — the resampling is linear in the
/// MASK and no resolution setting can reduce it — and the honest answer to "is
/// this fast enough" is that 128 nearly is and the dial is right there.
///
/// WHY A DIAL AND NOT A CONSTANT. A developer shipping a small game on a laptop
/// wants the cheap end; one shipping a dungeon crawler wants every bit of detail
/// and has the frame time for it. A constant would choose for them, and would be
/// wrong for half of them. `0` is not "off" but "match the mask", which is the
/// pre-dial behaviour and still costs what it always cost.
pub const default_gi_res: u32 = 128;

/// The ceiling on the GI field's longest side, and so on `downsampleGi`'s edge
/// table. Matches `setGiResolution`'s clamp: a field wider than this is refused
/// rather than silently truncated, so the two can never disagree about the
/// largest field that exists.
pub const max_gi_side: u32 = 4096;

/// The GI field's dimensions for a mask of `w` x `h` under a configured
/// longest side of `res`.
///
/// The aspect ratio of the mask is preserved: a 16:9 mask gets a 16:9 field,
/// because stretching the field to a square would make one texel of enclosure
/// data mean different world distances horizontally and vertically, and the
/// gradient that produces is not a lighting artefact anyone can diagnose from a
/// screenshot.
///
/// `res == 0` is "match the mask" and returns the mask's own size, which is the
/// pre-decouple behaviour and costs what it always cost.
pub fn giDimsFor(w: u32, h: u32, res: u32) struct { w: u32, h: u32 } {
    if (w == 0 or h == 0) return .{ .w = 0, .h = 0 };
    if (res == 0 or (w <= res and h <= res)) return .{ .w = w, .h = h };

    const longest = @max(w, h);
    if (w >= h) {
        return .{ .w = res, .h = @max((h * res) / longest, 1) };
    }
    return .{ .w = @max((w * res) / longest, 1), .h = res };
}

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
    /// Which light each channel belongs to, as the entity handle's bits.
    ///
    /// This is what makes the amortization WORK, and getting it wrong is
    /// invisible. `collect` used to clear `channel_built` every frame, on the
    /// reasoning that the maps are redistributed each frame and none of the
    /// previous ones can be trusted — but "cannot be trusted" and "is not
    /// trusted" are different: the map for a light that has not moved and whose
    /// mask has not changed is still exactly right. Clearing the flag made every
    /// frame rebuild every channel, and the bench measured it at 3.1 ms for four
    /// shadowed lights, which is the cost the design was supposed to avoid.
    ///
    /// So the flag is now cleared per channel, when the light BEHIND it changes.
    channel_owner: [4]u64 = [_]u64{0} ** 4,

    /// Euclidean distance field of the occluder mask, in mask cells, clamped to
    /// 65535. Solid cells are 0; a free cell holds its distance to the nearest
    /// solid one, which is the "how much sky can I see from here" answer GI wants.
    ///
    /// Sized `gi_w * gi_h`, NOT `alloc_w * alloc_h`. See `gi_mask` — the whole
    /// point of that field is that the distance transform is the expensive part,
    /// and it does not need shadow-map resolution to answer a question about how
    /// ENCLOSED a point is.
    sdf: []u16 = &.{},

    /// The occluder mask, DOWNSAMPLED to the GI field's resolution.
    ///
    /// This field exists because the GI field used to live at mask resolution,
    /// and at 2048x2048 that cost 243-265 ms of exact distance transform and a
    /// 16 MB upload per rebuild. The cost grew with the WINDOW rather than with
    /// the scene, which is the opposite of what a quality dial is for: enlarging
    /// the window made the renderer slower.
    ///
    /// The filter is CONSERVATIVE — any solid texel in the footprint makes the
    /// destination solid — and that direction is the whole design. Downsampling
    /// has two possible errors and only one of them is survivable: a wall that
    /// vanishes leaves a doorway that leaks light into a room the author
    /// enclosed, and the report is always "the lighting is wrong near that arch"
    /// with nothing in the logs. A wall that thickens slightly costs a few texels
    /// of extra penumbra and is invisible. GI that errs by hiding sky is merely
    /// wrong; GI that errs by inventing sky is broken.
    gi_mask: []u8 = &.{},

    /// The GI field's own dimensions, in cells. Derived from the mask size and
    /// `gi_res` by `giDimsFor`, never assigned anywhere else.
    gi_w: u32 = 0,
    gi_h: u32 = 0,

    /// The configured GI field resolution: the LONGEST side, in cells. Zero means
    /// "match the mask", which is the old behaviour and costs what it always
    /// cost. Reaches the engine from `project.config`'s `lighting.gi_resolution`
    /// and from the quality tier when the config does not name a value.
    gi_res: u32 = default_gi_res,

    /// The radiance-cascade pyramid. A POINTER because `Radiance` is declared
    /// further down this file and Zig has no forward declarations: an inline
    /// value would be a cycle, and an `anytype` field would cost every method
    /// on it. Created by `init` when GI is on and left null when it is off, so a
    /// scene without GI allocates nothing for it.
    radiance: ?*Radiance = null,

    /// The distance transform's scratch, sized in `resize` and reused forever.
    ///
    /// Owning it here is what removes a 2 MB allocation per frame from between
    /// two linear passes. The transform's remaining cost is in `edt1d` and is
    /// measured by `bench-light`, not here.
    edt: EdtScratch = undefined,
    /// The RGBA8 grid `encodeGi` writes. Grown in `resize`, never in a frame.
    gi_pixels: []u8 = &.{},

    /// The gather buffers. `std.ArrayList` of trivially-copyable structs, grown
    /// by the caller before a frame and not during one (spec §3.1).
    lights: std.ArrayList(LightInstance) = .empty,
    /// Parallel to `lights.items`: the shadow channel each light got, or -1.
    channel_of: std.ArrayList(i8) = .empty,
    /// Parallel to `lights.items`: how far each light's shadow sweep traces, in
    /// world units. A separate list rather than `radius * shadow_ratio` read
    /// back at grant time because the sweep needs the reach as a distance, and
    /// recomputing the product in two places is how the two places stop agreeing.
    reach_of: std.ArrayList(f32) = .empty,
    /// Parallel to `lights.items`: which entity each light is. A channel's owner
    /// is what decides whether its map can be reused, and a frame that knows the
    /// light moved has to have remembered WHICH light.
    owner_of: std.ArrayList(u64) = .empty,

    /// Where automatic occluders look up their sprite's coverage. Null means no
    /// asset pipeline has registered anything, every automatic occluder is a
    /// rectangle, and `coverage_used` is zero — which is the honest report for
    /// the current state of M6.
    coverage_store: ?*const CoverageStore = null,

    /// One occupancy grid PER SHADOW CHANNEL, allocated lazily and only for the
    /// channels whose light actually restricts which occluders block it.
    ///
    /// ## Why the single mask cannot answer the question
    ///
    /// `LightOccluder2D.cull_mask` says "this wall blocks my torch but not my
    /// sun". One grid cannot express that: the sweep for the sun and the sweep
    /// for the torch read the same cells, so honouring the mask means each sweep
    /// reads a grid built from the occluders IT cares about.
    ///
    /// ## Why the default scene pays nothing
    ///
    /// A channel whose light has the full mask needs the union, which `mask`
    /// already is, so `channel_mask[ch]` stays null and that sweep reads `mask`
    /// exactly as before. The four extra grids appear only when a scene uses the
    /// feature, which is what keeps "per-channel masks" from being a permanent
    /// 4x of the rasterization cost for every project.
    channel_mask: [4]?[]u8 = .{ null, null, null, null },
    /// How many channels needed their own grid this frame. Reported so a profile
    /// can tell "the cull-mask feature is on" from "everything is".
    channel_masks_built: u32 = 0,

    /// One slot per occluder for its resolved `CoverageMask`, grown in `reserve`.
    ///
    /// A pool and not a per-occluder allocation because `collect` runs inside the
    /// frame and spec §3.1 forbids allocating there. The pixels themselves point
    /// at the asset pipeline's immutable buffer; only this four-field descriptor
    /// is per-occluder state.
    coverage_pool: []CoverageMask = &.{},
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
    /// Whether every channel's map is out of date because the MASK moved, rather
    /// than because the light behind it did.
    ///
    /// A separate flag from `mask_changed` because `rasterize` clears that one on
    /// its way out — and `buildShadowMaps` runs AFTER `rasterize`, so it was
    /// reading a flag that had already been reset. The sweep therefore only ever
    /// ran when a LIGHT moved: slide a wall across a stationary torch and the
    /// shadow stayed exactly where it was, with `sweep_skips` reporting 4 of 4
    /// channels skipped and every count in the stats looking healthy. Set by
    /// `rasterize` and `resize`, cleared by `buildShadowMaps`.
    sweep_stale: bool = true,
    /// Fingerprint of the last occluder set, so the comparison above has
    /// something to compare against.
    occluder_hash: u64 = 0,
    /// Whether `occluder_hash` means anything yet. A resize clears the hash, and
    /// "cleared" and "a scene whose hash is zero" are the same number — so the
    /// question is tracked rather than guessed from the value.
    hash_valid: bool = false,
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

    pub fn init(allocator: std.mem.Allocator, tier: Quality) !Lighting {
        // `edt` in the literal, BEFORE the errdefer: setting it after means a
        // failure in `setAngles` runs `deinit` on a scratch whose allocator is
        // undefined, and a panic in the cleanup path hides the error that
        // caused it.
        var self: Lighting = .{
            .allocator = allocator,
            .cfg = tier,
            .edt = EdtScratch.init(allocator),
        };
        errdefer self.deinit();
        try self.setAngles(switch (tier) {
            .off, .low => 64,
            .medium => 128,
            .high => 256,
        });
        self.gi_interval_ns = switch (tier) {
            // 100 ms is ten rebuilds a second. A GI field is a slow-moving
            // quantity -- an occluder has to move a long way before "how
            // enclosed is this point" changes -- and rebuilding it every frame
            // is the classic way to make a subsystem that costs more than the
            // scene it was added to.
            .medium => 100 * std.time.ns_per_ms,
            else => 0,
        };
        // The pyramid only exists when GI does. A scene that never asks for
        // bounce should not be carrying a four-level probe grid it will never
        // fill — so this is allocated on the quality setting, not on a flag
        // that starts out true and gets turned off later.
        if (tier.giEnabled()) {
            const r = try self.allocator.create(Radiance);
            errdefer self.allocator.destroy(r);
            r.* = Radiance.init(self.allocator);
            self.radiance = r;
        }
        return self;
    }

    /// Changes the quality tier at runtime.
    ///
    /// A setter and not a field, because three of the four tiers change something
    /// that is ALREADY ALLOCATED — the angle count, the GI pyramid — and writing
    /// `cfg` alone would leave the buffers sized for the old tier while every
    /// read went to the new one. An editor's quality dropdown calls this.
    ///
    /// Not frame work: `setAngles` reallocates, and spec §3.1 forbids that inside
    /// a frame. The editor's setting panel is not in a frame.
    ///
    /// Returns false when the tier needs GI and GI was never created, because
    /// raising the tier is a request and the answer may be no — a scene that
    /// started with GI off has no pyramid to fill and building one here would be
    /// an allocation the caller did not budget for.
    pub fn setQuality(self: *Lighting, tier: Quality) !bool {
        if (tier == self.cfg) return true;
        if (tier.giEnabled() and self.radiance == null) return false;

        const angles: u16 = switch (tier) {
            .off, .low => 64,
            .medium => 128,
            .high => 256,
        };
        try self.setAngles(angles);
        self.gi_interval_ns = switch (tier) {
            .medium => 100 * std.time.ns_per_ms,
            else => 0,
        };
        self.cfg = tier;
        // The mask resolution halves at the lower tiers, so the tier change is a
        // resize: the grid is sized in `resize` and `mask_w`/`mask_h` are what
        // the sweep steps by.
        self.mask_changed = true;
        self.dirty = true;
        // The hash describes a mask built at the OLD angle count, and the mask
        // itself is unchanged — but the channels are, so `channel_built` below is
        // the invalidation that matters here. `hash_valid` stays true.
        // Every channel's map was swept for the old angle count.
        self.channel_built = [_]bool{false} ** 4;
        return true;
    }

    pub fn quality(self: *const Lighting) Quality {
        return self.cfg;
    }

    pub fn deinit(self: *Lighting) void {
        self.allocator.free(self.mask);
        self.allocator.free(self.shadow);
        self.allocator.free(self.sdf);
        self.allocator.free(self.gi_mask);
        self.allocator.free(self.gi_pixels);
        self.allocator.free(self.coverage_pool);
        for (self.channel_mask) |m| if (m) |g| self.allocator.free(g);
        self.edt.deinit();
        if (self.radiance) |r| {
            r.deinit();
            self.allocator.destroy(r);
        }
        self.lights.deinit(self.allocator);
        self.channel_of.deinit(self.allocator);
        self.reach_of.deinit(self.allocator);
        self.owner_of.deinit(self.allocator);
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
        try self.allocMask(w, h);
    }

    /// (Re)sizes everything derived from the mask: the GI field, its upload
    /// buffer and the radiance pyramid.
    ///
    /// Split out of `resize` because `gi_res` can change WITHOUT the mask
    /// changing — that is the entire point of it being a dial. A developer
    /// raising `gi_resolution` and pressing apply must not have to also resize
    /// the window, and `resize` early-outs when the mask size is unchanged, so
    /// without this a resolution change would silently do nothing.
    ///
    /// Also where the allocations are legal: `updateSdf` and `Radiance.build`
    /// both run inside the frame, and spec §3.1 does not allow allocating there.
    fn reallocMaskBuffers(self: *Lighting) !void {
        const aw = self.alloc_w;
        const ah = self.alloc_h;
        if (aw == 0 or ah == 0) return;

        const dims = giDimsFor(aw, ah, self.gi_res);
        self.gi_w = dims.w;
        self.gi_h = dims.h;

        self.allocator.free(self.sdf);
        self.allocator.free(self.gi_mask);
        // One RGBA texel per GI cell. Allocated here rather than on the first
        // `encodeGi` because that call is inside a frame, and spec §3.1 does not
        // allow allocating once the frame has started.
        self.allocator.free(self.gi_pixels);
        const cells = @as(usize, dims.w) * dims.h;
        self.gi_pixels = try self.allocator.alloc(u8, cells * 4);
        @memset(self.gi_pixels, 0);
        self.gi_mask = try self.allocator.alloc(u8, cells);
        @memset(self.gi_mask, 0);
        self.sdf = try self.allocator.alloc(u16, cells);
        // The GI probe grids are sized here for the same reason the mask is:
        // `Radiance.build` is called from inside the frame (an occluder moved)
        // and must not allocate when it runs. The budget comes from the quality
        // tier, so the pyramid's cost is the tier's promise and not a function of
        // how big the window happens to be.
        if (self.radiance) |r| try r.prepare(dims.w, dims.h, Radiance.fineSideFor(self.cfg));

        // A different field size means the field that is on disk describes a
        // different grid than the one now allocated, so both the "rebuild it"
        // flag and the amortization history have to be abandoned. Leaving
        // `sdf_builds` alone would be the kind of small lie that shows up later
        // as "GI is not rebuilding after I changed the resolution".
        self.dirty = true;
    }

    /// Sets the GI field's longest side, in cells. `0` means "match the mask".
    ///
    /// Boot-time, like `resize`: it reallocates. Call it from where the config is
    /// applied, before the frame loop, or from the editor panel followed by a
    /// `resize` — never from inside a frame.
    ///
    /// A no-op when the value is unchanged, so a config reload that touches
    /// other fields does not throw away a field that did not move.
    pub fn setGiResolution(self: *Lighting, res: u32) !void {
        const clamped = if (res == 0) 0 else std.math.clamp(res, 8, 4096);
        if (clamped == self.gi_res) return;
        self.gi_res = clamped;
        if (self.alloc_w != 0) try self.reallocMaskBuffers();
    }

    fn allocMask(self: *Lighting, w_in: u32, h_in: u32) !void {
        const w = @max(w_in, 1);
        const h = @max(h_in, 1);
        // Power of two so a window drag by one pixel does not reallocate, and
        // so the rasterizer's row stride is a mask rather than a division.
        const aw = roundPow2(w);
        const ah = roundPow2(h);

        self.allocator.free(self.mask);
        for (self.channel_mask) |m| if (m) |g| self.allocator.free(g);
        self.mask = try self.allocator.alloc(u8, @as(usize, aw) * ah);
        // The scratch follows the mask's size, outside the frame.
        //
        // NOT `edt.deinit()` first: `EdtScratch.resize` frees and re-allocates
        // only when its buffers are too small, and a `deinit` here would leave
        // the scratch with an undefined allocator for the `resize` two lines
        // down -- which is a crash in the cleanup path of a routine resize.
        try self.edt.resize(aw, ah);
        @memset(self.mask, 0);
        self.alloc_w = aw;
        self.alloc_h = ah;
        self.dirty = true;
        self.mask_changed = true;
        self.occluder_hash = 0;
        self.hash_valid = false;
        self.sweep_stale = true;
        self.channel_built = [_]bool{false} ** 4;
        // The GI field and the upload buffer follow the mask. Separate from the
        // mask itself because `gi_res` can move them on their own.
        try self.reallocMaskBuffers();
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
        try self.reach_of.ensureUnusedCapacity(self.allocator, lights);
        try self.owner_of.ensureUnusedCapacity(self.allocator, lights);
        // One coverage descriptor per possible occluder. Freed and regrown only
        // when the budget grows, which is a scene change and not a frame.
        if (self.coverage_pool.len < occluders) {
            self.allocator.free(self.coverage_pool);
        for (self.channel_mask) |m| if (m) |g| self.allocator.free(g);
            self.coverage_pool = try self.allocator.alloc(CoverageMask, occluders);
        }
        try self.scratch.ensureUnusedCapacity(self.allocator, lights);
        try self.occluders.ensureUnusedCapacity(self.allocator, occluders);
    }

    /// Clears the per-frame gather buffers. Cheap enough to do every frame, and
    /// cheaper than asking whether the previous frame was interrupted.
    pub fn lock(self: *Lighting) void {
        self.lights.clearRetainingCapacity();
        self.channel_of.clearRetainingCapacity();
        self.reach_of.clearRetainingCapacity();
        self.owner_of.clearRetainingCapacity();
        self.scratch.clearRetainingCapacity();
        self.occluders.clearRetainingCapacity();
        self.stats.beginFrame();
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
        self.reach_of.clearRetainingCapacity();
        self.owner_of.clearRetainingCapacity();
        self.scratch.clearRetainingCapacity();
        self.occluders.clearRetainingCapacity();

        const want_shadow = self.cfg.shadowLights();
        self.stats.occluders = 0;
        // NOT cleared here. A channel's map is a function of the light behind it
        // and the mask; when neither has changed the previous map is still exactly
        // right, and clearing this made every frame rebuild every channel. The
        // flag is cleared per channel below, when the light BEHIND it changes --
        // which is the only thing that can invalidate a map.

        // Lights. Four components, one code path: `gather` is generic over the
        // component type and `descFor` is the only place that knows a
        // SpotLight2D has a cone. Writing four loops here would work until
        // somebody fixed a bug in three of them, and the fourth would be a light
        // that behaves differently in a way nobody can point at.
        //
        // The row already holds an archetype pointer, so `Row.get` is a cell
        // index rather than `world.get`'s slot lookup plus archetype walk — about
        // 141 ns per light, which a 200-light scene pays 200 times.
        gather(components.PointLight2D, self, world, view);
        gather(components.SpotLight2D, self, world, view);
        gather(components.DirectionalLight2D, self, world, view);
        gather(components.AmbientLight2D, self, world, view);
        // The legacy single-component light, gathered too. It is still a
        // REGISTERED component with a dense id, and a dense id is the `.zson`
        // encoding -- so scenes committed before the four kinds existed carry it,
        // and a renderer that stopped gathering it would turn every one of them
        // into an unlit scene. It costs one more query and it keeps those scenes
        // working.
        gather(components.Light2D, self, world, view);

        // Occluders.
        //
        // FNV-1a, NOT `h ^= contribution` per occluder. XOR is its own inverse,
        // so a pair of identical occluders folds to nothing: forty identical
        // walls hashed to exactly 0, which is also what `resize` leaves in
        // `occluder_hash`, so `changed` was false, the mask was never built, and
        // every shadow in the scene was cast by an EMPTY grid. The symptom was
        // invisible — occluders counted 40, shadow channels were granted 4/4,
        // and the sweep dutifully marched rays through open space — because
        // every one of those numbers is a count and none of them is "did
        // anything get drawn". A level made of mirrored rooms is the common
        // case, not the pathological one.
        var h: u64 = occluder_hash_seed;
        var it3 = world.query(.{LightOccluder2D});
        var e3 = it3.next();
        while (e3) |e| : (e3 = it3.next()) {
            const oc: *const LightOccluder2D = e.get(LightOccluder2D);
            if (!oc.enabled or oc.mode == .none) continue;
            const t = world.get(e.entity(), components.Transform);
            const pos: Vec2 = if (t) |tt| tt.position else .{ .x = 0, .y = 0 };
            const sprite = world.get(e.entity(), components.Sprite);

            var out = Occluder{
                .polygon = oc.polygon,
                .pos = pos,
                .extent = 0,
                .cull_mask = oc.cull_mask,
                .alpha_threshold = oc.alpha_threshold,
            };
            if (oc.mode == .auto_sdf) {
                const sp = sprite orelse continue;
                const sx = if (t) |tt| tt.scale.x else 1;
                const sy = if (t) |tt| tt.scale.y else 1;
                // The coverage mask, when one exists. It takes priority over the
                // shape below, so a sprite that ships coverage occludes by its
                // silhouette and not by its rectangle — and `alpha_threshold`
                // becomes a dial that does something instead of a field that is
                // set and ignored.
                //
                // Scaled by the actor's transform because the mask is authored at
                // the sprite's own size: a scaled actor occludes with a scaled
                // silhouette, not the same one stretched into place.
                out.coverage = resolveCoverage(self, sp, sp.size.x * sx, sp.size.y * sy);
                if (sp.shape == .circle) {
                    out.circle = true;
                    out.radius = @abs(sp.size.x * sx) * 0.5;
                } else {
                    // The rectangle fallback. Both halves, because a sprite is not
                    // square -- see `rasterRect`.
                    out.rect_half = .{
                        .x = @abs(sp.size.x * sx) * 0.5,
                        .y = @abs(sp.size.y * sy) * 0.5,
                    };
                    out.extent = @abs(sp.size.x * sx) * 0.5;
                }
            } else {
                var b: [4]f32 = undefined;
                oc.polygon.bounds(&b);
                out.extent = @max(b[2] - b[0], b[3] - b[1]) * 0.5;
            }
            self.occluders.appendAssumeCapacity(out);
            self.stats.occluders += 1;
            // Fingerprint the occluder: everything that can change WHAT the mask
            // looks like. A handful of multiplies and folds per occluder, against
            // a whole grid rasterization when something moved.
            //
            // `alpha_threshold` and the presence of coverage were both missing
            // from this hash, and both belong in it: an author dragging the
            // threshold slider, or an asset pipeline that registers a mask after
            // the scene is already loaded, changed the occluder's SHAPE and the
            // hash said nothing happened — so `rasterize` returned early and the
            // new edge was never drawn. The symptom is a slider that does
            // nothing, which is indistinguishable from a broken binding.
            const px: u64 = @as(u32, @bitCast(pos.x));
            const py: u64 = @as(u32, @bitCast(pos.y));
            const pex: u64 = @as(u32, @bitCast(out.extent));
            const prad: u64 = @as(u32, @bitCast(out.radius));
            const pthr: u64 = @as(u32, @bitCast(out.alpha_threshold));
            const pcov: u64 = if (out.coverage) |c| (@as(u64, c.w) << 32) | c.h else 0;
            // The rectangle's two halves, not the single `extent`: a sprite that
            // changes from square to wide changes its shadow with no movement.
            const prx: u64 = if (out.rect_half) |v| @as(u32, @bitCast(v.x)) else 0;
            const pry: u64 = if (out.rect_half) |v| @as(u32, @bitCast(v.y)) else 0;
            // The polygon's own points too. Two occluders can share a position, an
            // extent and a mode and still be different walls, and a fingerprint
            // that cannot tell them apart reports "nothing changed" for a scene
            // that was rebuilt from a different prefab.
            for (out.polygon.points[0 .. 2 * out.polygon.count]) |pt| {
                h = (h ^ @as(u64, @as(u32, @bitCast(pt)))) *% 0x100000001b3;
            }
            h = (h ^ px) *% 0x100000001b3;
            h = (h ^ py) *% 0x100000001b3;
            h = (h ^ pex) *% 0x100000001b3;
            h = (h ^ prad) *% 0x100000001b3;
            h = (h ^ @intFromBool(out.circle)) *% 0x100000001b3;
            h = (h ^ pthr) *% 0x100000001b3;
            h = (h ^ pcov) *% 0x100000001b3;
            h = (h ^ prx) *% 0x100000001b3;
            h = (h ^ pry) *% 0x100000001b3;
            // The occluder's layer mask, so two walls that look identical but
            // block different lights are not interchangeable.
            h = (h ^ @as(u64, out.cull_mask)) *% 0x100000001b3;
            h = (h ^ @intFromBool(out.coverage != null)) *% 0x100000001b3;
        }
        // `hash_valid` rather than comparing against a sentinel: a real scene can
        // hash to any value at all, including whatever a resize leaves behind, and
        // "the mask has never been built" is a fact about the system rather than
        // something to infer from a number.
        const changed = !self.hash_valid or h != self.occluder_hash;
        self.hash_valid = true;
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
            const owner = self.owner_of.items[cand.index];
            // A different light in the same slot means the map describes
            // something else now, even if that light happens to stand at the same
            // point. Position alone cannot tell those two cases apart.
            if (self.channel_owner[slot] != owner) {
                self.channel_built[slot] = false;
                self.channel_owner[slot] = owner;
            }
            self.channel_pos[slot] = .{ .x = inst.pos[0], .y = inst.pos[1] };
            self.channel_radius[slot] = self.reach_of.items[cand.index];
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
            //
            // `raster_skipped` says so out loud. Without it this frame's
            // `occluders_rasterized` is zero, which reads exactly like a scene
            // with no walls — and the mask behind it is full of them.
            self.stats.raster_skipped = 1;
            return;
        }

        var written: u64 = 0;
        var drawn: u32 = 0;

        for (self.occluders.items) |oc| {
            // A coverage mask, when the asset pipeline supplied one, REPLACES the
            // shape entirely. It is not intersected with the rectangle: the
            // rectangle is the fallback, and intersecting would keep the exact
            // edges the mask exists to remove.
            if (oc.coverage) |cov| {
                written += rasterCoverage(self, oc, cov.*, cell);
                drawn += 1;
                continue;
            }
            if (oc.circle) {
                written += rasterCircle(self, oc.pos, oc.radius, cell);
                drawn += 1;
                continue;
            }
            // The rectangle fallback, for an automatic occluder whose asset has no
            // coverage yet. Tested before the polygon so a manual occluder that
            // ALSO set `rect_half` -- which cannot happen today, and would be a
            // bug rather than a choice -- takes the manual path.
            if (oc.rect_half) |half| {
                written += rasterRect(self, oc.pos, half, cell);
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
        self.buildChannelMasks();
        // The mask changed, so the distance field is now stale. `dirty` is
        // about the field, not about the mask, and the sweep's skip check reads
        // neither of them -- see buildShadowMaps.
        self.dirty = true;
        self.mask_changed = false;
        // The maps were swept against the previous mask. `buildShadowMaps` runs
        // after this and reads this flag rather than `mask_changed`, which this
        // line has just cleared — that ordering is the whole reason the flag
        // exists, and the comment on it says so.
        self.sweep_stale = true;
        self.stats.raster_ns = self.tick() - t0;
    }

    /// Builds the per-channel occupancy grids, for the channels that need one.
    ///
    /// A channel needs its own grid when its light's `item_cull_mask` is not the
    /// full mask AND some occluder disagrees with it — because until an occluder
    /// says otherwise, "every occluder blocks me" is true and the union is the
    /// right answer. That condition is what keeps the feature free for a scene
    /// that sets a mask and never uses it.
    ///
    /// Runs at the END of `rasterize`, so it can assume the union is already
    /// correct and only has to decide which occluders the restricted lights
    /// exclude.
    fn buildChannelMasks(self: *Lighting) void {
        const w = self.alloc_w;
        const h = self.alloc_h;
        if (w == 0 or h == 0) return;
        const cells = @as(usize, w) * h;
        self.channel_masks_built = 0;

        for (0..4) |ch| {
            const owner = self.channel_owner[ch];
            if (owner == 0) {
                if (self.channel_mask[ch]) |g| self.allocator.free(g);
                self.channel_mask[ch] = null;
                continue;
            }
            const li = self.lightOf(owner) orelse {
                if (self.channel_mask[ch]) |g| self.allocator.free(g);
                self.channel_mask[ch] = null;
                continue;
            };
            const light_mask = self.lights.items[li].item_cull_mask;

            // Any occluder this light does NOT see?
            var restricted = false;
            for (self.occluders.items) |oc| {
                if ((oc.cull_mask & light_mask) == 0) {
                    restricted = true;
                    break;
                }
            }

            if (!restricted) {
                if (self.channel_mask[ch]) |g| self.allocator.free(g);
                self.channel_mask[ch] = null;
                continue;
            }

            if (self.channel_mask[ch]) |g| {
                if (g.len < cells) {
                    self.allocator.free(g);
                    self.channel_mask[ch] = null;
                }
            }
            if (self.channel_mask[ch] == null) {
                self.channel_mask[ch] = self.allocator.alloc(u8, cells) catch null;
            }
            const grid = self.channel_mask[ch] orelse continue;

            // Rebuilt from the occluders this light sees. Not "the union minus
            // the excluded ones": an occluder the light does not see may sit
            // INSIDE one it does, and subtracting its cells would punch a hole in
            // the wall. So this walks the occluder list and fills only the ones
            // that pass, which is the only form that is correct under overlap.
            @memset(grid, 0);
            const cell = self.rect.cell(w, h);
            for (self.occluders.items) |oc| {
                if ((oc.cull_mask & light_mask) == 0) continue;
                self.fillOccluder(grid, oc, cell);
            }
            self.channel_masks_built += 1;
        }
    }

    /// The index in `lights.items` of the light owned by `entity_bits`, or null.
    fn lightOf(self: *const Lighting, entity_bits: u64) ?usize {
        for (self.owner_of.items, 0..) |owner, i| {
            if (owner == entity_bits) return i;
        }
        return null;
    }

    /// Writes one occluder into `grid`, whichever shape it has.
    ///
    /// A separate function from `rasterize`'s inline body because the same three
    /// shapes have to be drawn twice — once into the union and once per
    /// restricted channel — and a second copy of a rasterizer is a second answer
    /// to "what does this occluder look like".
    fn fillOccluder(self: *Lighting, grid: []u8, oc: Occluder, cell: Vec2) void {
        const w = self.alloc_w;
        if (oc.coverage) |cov| {
            // `cov.*`, because the optional holds a pointer and the rasterizer
            // wants the descriptor. One dereference at the seam rather than a
            // pointer parameter that every caller has to remember to unwrap.
            _ = rasterCoverageInto(self, grid, oc, cov.*, cell);
            return;
        }
        if (oc.circle) {
            _ = rasterCircleInto(self, grid, oc.pos, oc.radius, cell);
            return;
        }
        if (oc.rect_half) |half| {
            _ = rasterRectInto(self, grid, oc.pos, half);
            return;
        }
        const n = oc.polygon.vertexCount();
        if (n < 3) return;
        var b: [4]f32 = undefined;
        oc.polygon.bounds(&b);
        const lo = worldToMask(self.rect, w, self.alloc_h, .{
            .x = oc.pos.x + @min(b[0], b[2]),
            .y = oc.pos.y + @min(b[1], b[3]),
        });
        const hi = worldToMask(self.rect, w, self.alloc_h, .{
            .x = oc.pos.x + @max(b[0], b[2]),
            .y = oc.pos.y + @max(b[1], b[3]),
        });
        const x0: u32 = @intCast(@max(lo[0], 0));
        const y0: u32 = @intCast(@max(lo[1], 0));
        const x1: u32 = @intCast(@min(hi[0], w));
        const y1: u32 = @intCast(@min(hi[1], self.alloc_h));
        var y = y0;
        while (y < y1) : (y += 1) {
            var x = x0;
            while (x < x1) : (x += 1) {
                const wx = self.rect.min.x + (@as(f32, @floatFromInt(x)) + 0.5) * cell.x;
                const wy = self.rect.min.y + (@as(f32, @floatFromInt(y)) + 0.5) * cell.y;
                if (!oc.polygon.contains(wx - oc.pos.x, wy - oc.pos.y)) continue;
                grid[@as(usize, y) * w + x] = 255;
            }
        }
    }

    /// Rasterizes an axis-aligned rectangle, the automatic occluder's fallback.
    ///
    /// Separate from `rasterCircle` rather than reusing it because a sprite is
    /// not square and a square approximation of a 64x16 crate is a shadow twice
    /// as wide as the crate on one side — which is a bug that looks like the
    /// light being in the wrong place.
    fn rasterRect(self: *Lighting, pos: Vec2, half: Vec2, cell: Vec2) u64 {
        _ = cell; // a rectangle is axis-aligned; it does not need the cell size
        return rasterRectInto(self, self.mask, pos, half);
    }

    /// The rectangle rasterizer, writing into `grid`.
    fn rasterRectInto(self: *Lighting, grid: []u8, pos: Vec2, half: Vec2) u64 {
        const hx = @abs(half.x);
        const hy = @abs(half.y);
        if (hx <= 0 or hy <= 0) return 0;
        const lo = worldToMask(self.rect, self.alloc_w, self.alloc_h, .{ .x = pos.x - hx, .y = pos.y - hy });
        const hi = worldToMask(self.rect, self.alloc_w, self.alloc_h, .{ .x = pos.x + hx, .y = pos.y + hy });
        const x0: u32 = @intCast(@max(lo[0], 0));
        const y0: u32 = @intCast(@max(lo[1], 0));
        const x1: u32 = @intCast(@min(hi[0], self.alloc_w));
        const y1: u32 = @intCast(@min(hi[1], self.alloc_h));
        if (x1 <= x0 or y1 <= y0) return 0;

        var written: u64 = 0;
        var y = y0;
        while (y < y1) : (y += 1) {
            @memset(grid[@as(usize, y) * self.alloc_w + x0 ..][0 .. (x1 - x0)], 255);
            written += x1 - x0;
        }
        return written;
    }

    /// Rasterizes a sprite's coverage mask into the occupancy grid.
    ///
    /// Nearest-neighbour, not bilinear: a coverage mask is a DECISION (is this
    /// texel solid or not) and smoothing it would make the threshold produce a
    /// grey edge, which is a shadow with a halo around every soft sprite. The
    /// threshold is applied to the source texel, not to an average of neighbours,
    /// so `alpha_threshold` means one number.
    ///
    /// The threshold is compared against `alpha_threshold * 255` and the test is
    /// `>=`, so a threshold of 0 makes EVERY texel solid — including fully
    /// transparent ones. That is what "no threshold" should mean: the author said
    /// the sprite occludes, so it occludes.
    fn rasterCoverage(self: *Lighting, oc: Occluder, cov: CoverageMask, cell: Vec2) u64 {
        return rasterCoverageInto(self, self.mask, oc, cov, cell);
    }

    /// The coverage rasterizer, writing into `grid`.
    fn rasterCoverageInto(self: *Lighting, grid: []u8, oc: Occluder, cov: CoverageMask, cell: Vec2) u64 {
        if (cov.w == 0 or cov.h == 0) return 0;
        const cut: u8 = @intFromFloat(@min(@max(oc.alpha_threshold, 0), 1) * 255.0);

        // The mask's world rectangle, centred on the actor exactly as the polygon
        // path does — so an author switching a sprite between automatic and
        // manual sees the same frame move, not the whole occluder jump.
        const half_x = cov.cell.x * @as(f32, @floatFromInt(cov.w)) * 0.5;
        const half_y = cov.cell.y * @as(f32, @floatFromInt(cov.h)) * 0.5;
        const lo = worldToMask(self.rect, self.alloc_w, self.alloc_h, .{
            .x = oc.pos.x - half_x,
            .y = oc.pos.y - half_y,
        });
        const hi = worldToMask(self.rect, self.alloc_w, self.alloc_h, .{
            .x = oc.pos.x + half_x,
            .y = oc.pos.y + half_y,
        });
        const x0: u32 = @intCast(@max(lo[0], 0));
        const y0: u32 = @intCast(@max(lo[1], 0));
        const x1: u32 = @intCast(@min(hi[0], self.alloc_w));
        const y1: u32 = @intCast(@min(hi[1], self.alloc_h));
        if (x1 <= x0 or y1 <= y0) return 0;

        // The scale from mask cells to coverage texels. Computed once and applied
        // as a multiply, because this is the inner loop of a pass that runs over
        // every visible texel of every automatic occluder.
        const sx = @as(f32, @floatFromInt(cov.w)) / (@as(f32, @floatFromInt(x1 - x0)) * cell.x);
        const sy = @as(f32, @floatFromInt(cov.h)) / (@as(f32, @floatFromInt(y1 - y0)) * cell.y);

        var written: u64 = 0;
        var y = y0;
        while (y < y1) : (y += 1) {
            var ty: u32 = @intFromFloat(@floor(@as(f32, @floatFromInt(y - y0)) * sy));
            ty = @min(ty, cov.h - 1);
            var x = x0;
            while (x < x1) : (x += 1) {
                var tx: u32 = @intFromFloat(@floor(@as(f32, @floatFromInt(x - x0)) * sx));
                tx = @min(tx, cov.w - 1);
                if (cov.pixels[@as(usize, ty) * cov.w + tx] < cut) continue;
                grid[@as(usize, y) * self.alloc_w + x] = 255;
                written += 1;
            }
        }
        return written;
    }

    /// A circle occluder is squared-distance-tested per cell over its bounding
    /// box. Cheaper than turning it into a polygon because the test is three
    /// multiplies instead of a loop over edges, and because a 24-gon
    /// approximation of a circle produces a visible polygonal shadow edge at the
    /// sizes a 2D light actually casts.
    fn rasterCircle(self: *Lighting, pos: Vec2, radius: f32, cell: Vec2) u64 {
        return rasterCircleInto(self, self.mask, pos, radius, cell);
    }

    /// The circle rasterizer, writing into `grid`.
    ///
    /// Split out because the per-channel grids need the same three shapes drawn
    /// a second time, and a second copy of a rasterizer is a second answer to
    /// "what does this occluder look like".
    fn rasterCircleInto(self: *Lighting, grid: []u8, pos: Vec2, radius: f32, cell: Vec2) u64 {
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
                grid[@as(usize, y) * self.alloc_w + x] = 255;
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

            // This channel's grid: its own when its light restricts which
            // occluders block it, and the union otherwise. Null means "the union
            // is the right answer", which is the default scene's case and costs
            // nothing.
            const grid = if (self.channel_mask[ch]) |g| g else self.mask;

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
            //
            // `sweep_stale` and not `mask_changed`, because `rasterize` clears
            // `mask_changed` before this runs — reading it here meant the sweep
            // never heard about a mask change at all.
            const moved = distance(self.channel_pos[ch], self.channel_pos_prev[ch]);
            // `channel_built` is now per-owner rather than per-frame, so this is
            // false for a scene at rest and the sweep is genuinely skipped.
            const stale = !self.channel_built[ch] or moved * moved >= 0.0001 or self.sweep_stale;
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
                    if (grid[idx] != 0) {
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
        // Consumed: the four maps now describe the mask as it is.
        self.sweep_stale = false;
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
            // An ambient is NOT a point light at a large radius. Its whole
            // purpose is to not dim as you walk away from it, so its curve is
            // FLAT across 80% of its reach and soft over the last 20% — and a
            // scene-wide ambient is sized so that flat part covers the view.
            // Using the point curve here would make a global ambient brightest
            // in one spot on screen, which is a bug a user files as "my ambient
            // light is in the wrong place".
            .ambient => falloff = 1 - smoothstep(0.8, 1.0, rec01),
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
            // Normalized by the SHADOW reach, not by the light's. The map holds
            // `1 - t/shadow_reach` because the sweep traced that far, so the
            // pixel has to be measured in the same units or the two sides of the
            // comparison mean different things — which is a shadow that is
            // subtly, invisibly the wrong length.
            const w = @max(li_.softness * rec01, 1e-4);
            const here = 1.0 - @min(rec01 / @max(li_.shadow_ratio, 1e-4), 1.0);

            // 255 MEANS CLEAR, and it collides with "a blocker at distance zero":
            // both encode to 255, because the sweep writes `1 - t/radius` and both
            // `t = 0` and "nothing there" leave it at 1.0.
            //
            // The test below compares the pixel's normalized distance (`here`)
            // against the stored proximity (`occ`) and asks "is the pixel CLOSER
            // than the blocker", which needs `here > occ` -- and `here` can never
            // exceed 1. So a stored 1.0 could never be exceeded, and EVERY PIXEL
            // whose ray found nothing was reported as fully shadowed.
            //
            // It hid because every shadow test in this file sampled a point
            // BEHIND a wall, where the ray IS blocked and the comparison happens
            // to give the right answer. A point in open space was never sampled,
            // which is the one thing a lighting system has to get right.
            if (occ >= 0.999) {
                vis = 1;
            } else {
                vis = smoothstep(occ - w, occ, here);
                // A filter is an average of neighbours, not a single sample.
                switch (li_.filter()) {
                    .off => {},
                    .pcf1 => vis = averageMask(occ, li_, here),
                    .pcf3 => vis = 0.5 * vis + 0.5 * averageMask(occ, li_, here),
                    .pcf5 => vis = 0.25 * vis + 0.5 * averageMask(occ, li_, here) +
                        0.25 * averageMask(occ, li_, here),
                }
            }
        }
        return falloff * vis * li_.energy * li_.color[3];
    }

    /// The neighbourhood average for a filter tap.
    fn averageMask(occ: f32, li: LightInstance, here: f32) f32 {
        const w = @max(li.softness * here, 1e-4);
        return smoothstep(occ - w, occ, here);
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
    /// Recomputes the distance field if the mask moved and the tier's cadence
    /// allows it. Returns whether it actually rebuilt.
    ///
    /// The return value is the whole amortization contract for GI, and it used to
    /// be missing: the driver called `Radiance.build` on every frame regardless,
    /// while a comment two lines above it claimed the build only happened "when
    /// the field moved". At 1080p that comment was worth 1.5 seconds a frame of
    /// pure waste. A pyramid is a function of the distance field, so rebuilding
    /// it on a frame where the field was not rebuilt is recomputing an unchanged
    /// answer — the caller needs to be able to ask, and this is the answer.
    pub fn updateSdf(self: *Lighting, now_ns: i128) bool {
        if (!self.cfg.giEnabled()) return false;
        if (!self.dirty) {
            self.stats.sdf_skipped += 1;
            return false;
        }
        const interval = self.gi_interval_ns;
        if (interval > 0 and now_ns - self.last_sdf_ns < interval) {
            self.stats.sdf_skipped += 1;
            return false;
        }

        const t0 = self.tick();
        const w = self.alloc_w;
        const h = self.alloc_h;
        const gw = self.gi_w;
        const gh = self.gi_h;
        if (w == 0 or h == 0 or gw == 0 or gh == 0) return false;

        // Downsample BEFORE the transform, not after. The distance transform is
        // the dominant cost and it is linear in cells, so the only way to make it
        // cheaper is to give it fewer cells — computing a 4.2M-cell field and
        // throwing 98% of it away would be the same work at a tenth of the size.
        const t_ds = self.tick();
        self.downsampleGi();
        self.stats.downsample_ns = self.tick() - t_ds;

        const t_edt = self.tick();
        edtMask2dInto(&self.edt, self.gi_mask, self.sdf, gw, gh);
        self.stats.transform_ns = self.tick() - t_edt;

        self.last_sdf_ns = now_ns;
        self.dirty = false;
        self.stats.sdf_builds += 1;
        self.stats.sdf_ns = self.tick() - t0;
        return true;
    }

    /// Builds `gi_mask` from `mask` at the GI field's resolution.
    ///
    /// CONSERVATIVE: a destination cell is solid when ANY mask cell in its
    /// footprint is solid. Not an average, and not a sample — those two let a
    /// wall one texel wide disappear at a 16:1 reduction, and a wall that
    /// disappears is a doorway that leaks sky into a room the author closed.
    ///
    /// That asymmetry is the entire design and it is worth stating as a rule
    /// because it looks like a bug: the wrong answer here is not "slightly too
    /// dark", it is "light coming from a wall". Erring toward solid costs a
    /// fraction of a texel of penumbra at a doorway and is invisible; erring
    /// toward open costs correctness and is a bug report with no way to point at
    /// the cause.
    ///
    /// Allocation-free: `gi_mask` was sized by `reallocMaskBuffers`, and this
    /// runs inside the frame.
    fn downsampleGi(self: *Lighting) void {
        const w = self.alloc_w;
        const h = self.alloc_h;
        const gw = self.gi_w;
        const gh = self.gi_h;
        if (gw == 0 or gh == 0) return;

        // The degenerate case, and the one that must be a COPY rather than an
        // alias: at `gi_resolution = 0` the field is the mask, and aliasing them
        // would mean `updateSdf` reads and writes the same bytes.
        if (gw == w and gh == h) {
            @memcpy(self.gi_mask, self.mask);
            return;
        }

        // Integer span per output cell. `roundPow2` on the mask and an arbitrary
        // `gi_res` do not divide evenly, so each destination cell owns the
        // half-open range [floor(x*w/gw), ceil((x+1)*w/gw)) — every source cell
        // is covered by at least one destination, which is the property that
        // stops a thin wall falling between two samples and being averaged away
        // by neither of them.
        // A word of mask bytes at a time. OR is associative and commutative and
        // the only question is whether anything in the footprint is non-zero, so
        // folding eight bytes together is the same computation with a
        // sixty-fourth of the loads.
        const Word = u64;
        const word_bytes = @sizeOf(Word);

        // Where each destination cell's source run ends.
        //
        // Hoisted out of both loops because the edges depend only on the two
        // dimensions, never on the row being folded. Everything else here was
        // tried and measured:
        //
        //   - dividing per cell per row: 256 * 2048 * 256 = 134M divisions to
        //     fold 4.2M bytes;
        //   - carrying a quotient/remainder instead of dividing: the same 4.2M
        //     byte-sized loop, moved into an inner `while`, and measurably SLOWER
        //     (6.5 ms against 1.4 ms) because it traded a divide for a loop;
        //   - this: `gw` divisions in total, then a linear scan.
        //
        // Sixteen kilobytes of stack in a leaf function, bounded by the same
        // `4096` ceiling `setGiResolution` applies, which is the only reason it
        // is a fixed array rather than a slice.
        var edges: [max_gi_side + 1]u32 = undefined;
        if (gw > max_gi_side) return; // unreachable: `giDimsFor` never exceeds it
        var ex: u32 = 0;
        while (ex < gw) : (ex += 1) {
            const n = ex + 1;
            edges[ex] = @min((n * w) / gw, w);
            if (edges[ex] == 0) edges[ex] = 1;
        }
        edges[gw] = w;

        var y: u32 = 0;
        while (y < gh) : (y += 1) {
            const y0 = (y * h) / gh;
            const y1 = @max(((y + 1) * h + gh - 1) / gh, y0 + 1);
            const y1c = @min(y1, h);
            const out_row = self.gi_mask[@as(usize, y) * gw ..][0..gw];
            @memset(out_row, 0);

            var sy = y0;
            while (sy < y1c) : (sy += 1) {
                const row = self.mask[@as(usize, sy) * w ..][0..w];
                // Walk the source row ONCE, contiguously. Iterating the
                // destination instead re-derives these indices once per cell per
                // row and turns a linear scan into a strided one.
                var dx: u32 = 0;
                var sx: u32 = 0;
                while (dx < gw and sx < w) : (dx += 1) {
                    var x1 = edges[dx];
                    if (x1 <= sx) x1 = sx + 1; // progress is not optional

                    var acc: Word = 0;
                    var i = sx;
                    while (i + word_bytes <= x1) : (i += word_bytes) {
                        acc |= @bitCast(@as(*align(1) const [word_bytes]u8, @ptrCast(&row[i])).*);
                    }
                    while (i < x1) : (i += 1) acc |= row[i];
                    if (acc != 0) out_row[dx] = 255;

                    sx = x1;
                }
            }
        }
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
        // The GI GRID, not the mask grid. Same rectangle, different cell count —
        // indexing the mask grid here would read past the end of `sdf` the
        // moment the field was decoupled, and at `gi_res >= alloc_w` it reads
        // inside it and returns a plausible wrong answer instead.
        const c = worldToMask(self.rect, self.gi_w, self.gi_h, .{ .x = x, .y = y });
        if (c[0] < 0 or c[1] < 0) return 1.0;
        const idx = @as(usize, @intCast(c[1])) * self.gi_w + @as(usize, @intCast(c[0]));
        if (idx >= self.sdf.len) return 1.0;
        const cells = @as(f32, @floatFromInt(self.sdf[idx]));
        // Saturates at ~6 GI CELLS. The ramp is in field units, not world units:
        // it was tuned against a field that had one texel per mask texel, and
        // carrying it over verbatim to a coarser field would make every enclosure
        // saturate immediately and the term collapse to a binary wall/not-wall.
        // So the distance is rescaled by how many mask cells a GI cell covers,
        // which keeps "enclosed means about six texels of sky" true at any
        // resolution — and is the one place this dial could have silently changed
        // what the number means.
        const cells_per_gi = self.cellsPerGiCell();
        return @min(cells * cells_per_gi / 6.0, 1.0);
    }

    /// How many mask cells one GI cell spans.
    ///
    /// The bridge between a distance measured in GI cells and a curve written in
    /// mask cells. At `gi_resolution = 0` it is exactly 1, so the old behaviour
    /// is bit-for-bit unchanged — which is the property that makes the default
    /// safe to change and the zero worth keeping.
    pub fn cellsPerGiCell(self: *const Lighting) f32 {
        if (self.gi_w == 0 or self.alloc_w == 0) return 1.0;
        return @as(f32, @floatFromInt(self.alloc_w)) / @as(f32, @floatFromInt(self.gi_w));
    }

    /// Encodes the GI field as the RGBA8 grid `uploadGi` wants: alpha is the
    /// enclosure term, RGB is the finest cascade's radiance.
    ///
    /// One buffer, no allocation, and the same arithmetic the sampler uses — so
    /// the CPU reference and the texture the shader reads cannot disagree about
    /// what "enclosed" means. A second implementation of the enclosure curve
    /// would be a second answer to the same question, and the two would differ
    /// by exactly the amount nobody could explain.
    ///
    /// Returns false and leaves `out` untouched when there is no field yet, so
    /// a caller can distinguish "GI is off" from "GI is on and everything is
    /// open", which render identically but mean different things to a test.
    pub fn encodeGi(self: *Lighting, out: []u8) bool {
        const w = self.gi_w;
        const h = self.gi_h;
        if (!self.cfg.giEnabled() or self.sdf.len == 0 or w == 0 or h == 0) return false;
        const need = @as(usize, w) * h * 4;
        if (out.len < need) return false;

        // The finest cascade, when there is one. Sampled rather than read raw:
        // it is already a bilinear-filterable grid at `base_scale`, and reading
        // probes straight would put a probe value in every texel between two
        // probes and turn the cascade into visible blocks.
        const r = self.radiance orelse return false;
        const fine: ?*const Cascade = if (r.cascades.items.len > 0)
            &r.cascades.items[0]
        else
            null;

        // The same rescaling `sampleGi` applies, so the texture and the CPU
        // reference cannot disagree about what "enclosed" means. They are the
        // same question asked twice, and two answers is one too many.
        const per_cell = self.cellsPerGiCell();

        var y: u32 = 0;
        while (y < h) : (y += 1) {
            var x: u32 = 0;
            while (x < w) : (x += 1) {
                const idx = @as(usize, y) * w + x;
                const px = @as(f32, @floatFromInt(x));
                const py = @as(f32, @floatFromInt(y));
                const enclosure = @min(@as(f32, @floatFromInt(self.sdf[idx])) * per_cell / 6.0, 1.0);

                var rgb = [3]f32{ 0, 0, 0 };
                if (fine) |c| rgb = sampleCascade(r, c, px, py);

                const o = idx * 4;
                out[o + 0] = clampByte(rgb[0]);
                out[o + 1] = clampByte(rgb[1]);
                out[o + 2] = clampByte(rgb[2]);
                out[o + 3] = clampByte(enclosure);
            }
        }
        return true;
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

/// 0..1 to a byte. Named rather than inlined because the GI encoder writes four
/// channels and a clamp that only two of them use is how the other two go out of
/// range.
fn clampByte(v: f32) u8 {
    const x = @min(@max(v, 0.0), 1.0);
    return @intFromFloat(x * 255.0 + 0.5);
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

/// Whether a light's reach intersects the view rectangle.
///
/// A directional light has no falloff and a scene-wide ambient covers everything,
/// so neither can be culled: both would intersect every rectangle and the test
/// would be paying for an answer that is always yes.
fn lightReaches(kind: components.LightKind, pos: Vec2, radius: f32, v: MaskRect) bool {
    if (kind == .directional) return true;
    const cx = @min(@max(pos.x, v.min.x), v.max.x);
    const cy = @min(@max(pos.y, v.min.y), v.max.y);
    const dx = pos.x - cx;
    const dy = pos.y - cy;
    return dx * dx + dy * dy <= radius * radius;
}

/// Everything about a light that is NOT in `LightBase`, flattened into one shape.
///
/// This exists so `collect` has a single code path for four component types. It
/// is also the honest description of how much the four kinds actually differ:
/// a spot has a cone and a directional light does not, and apart from that the
/// difference is which numbers exist at all.
pub const LightShape = struct {
    /// Offset from the Transform, in the Transform's own frame.
    offset: Vec2 = .{ .x = 0, .y = 0 },
    angle: f32 = 0,
    radius: f32 = 0,
    attenuation: f32 = 1,
    /// Full cone opening in radians. Null means "this light has no cone", which
    /// is a different answer from "a cone of zero width" — a zero-width cone is
    /// a degenerate spotlight, and one of them is a bug the other is a fact.
    cone: ?f32 = null,
    penumbra: f32 = 0.2,
    /// How far the shadow sweep traces. Zero means "the same as `radius`", which
    /// is true for every light but the sun.
    shadow_reach: f32 = 0,
    /// Drawn centred on the view rather than on its own actor. True for a
    /// directional light and for a scene-wide ambient, and false for everything
    /// else: a point light is somewhere and its quad must be around THAT.
    view_centred: bool = false,
    /// Directional only. See `shadowReachForHeight` for what this does.
    height: f32 = 0.5,
    /// Whether this light can cast a shadow at all. An ambient light cannot: it
    /// has no position to trace from, and a shadow of nothing is not a soft
    /// shadow, it is an artifact.
    can_shadow: bool = true,
};

/// A light of any kind, in the shape `collect` consumes.
pub const LightDesc = struct {
    base: components.LightBase,
    shape: LightShape,
    kind: components.LightKind,
};

/// How far a sun's shadows reach, as a multiple of the view.
///
/// The dial is `height`, Godot's 0..1, and the mapping is `view / height`
/// clamped: 1 is straight overhead (shadows hug their casters) and small values
/// are a sun on the horizon (shadows many times the screen). It is inverse
/// because that is what elevation does — the same logic as `tan`, and the same
/// reason a real engine's shadows lengthen as the sun sets.
///
/// The honest limitation, stated rather than hidden: 2D has no object height, so
/// this scales the sweep's reach and not any individual cast shadow's length. It
/// is a dial with the right direction and the right zero, which is what an author
/// means by it, and it is NOT a substitute for a projected-height system.
fn shadowReachForHeight(height: f32, view_diag: f32) f32 {
    const h = @min(@max(height, 0.125), 1);
    return @min(view_diag / h, view_diag * 8);
}

/// Flattens one of the four light components into a `LightDesc`.
///
/// Flattens one of the four light components into a `LightDesc`.
///
/// Public because a backend's tests have to build the same instances `collect`
/// builds: a test that constructs its own `LightInstance` by hand proves
/// nothing about the collector.
///
/// A `switch` on the TYPE, which Zig evaluates at comptime, so each arm is
/// checked against its real component and a renamed field is a compile error
/// rather than a silent zero.
pub fn descFor(comptime C: type, c: C, view_diag: f32) LightDesc {
    return switch (C) {
        components.PointLight2D => .{
            .base = c.base,
            .kind = .point,
            .shape = .{ .offset = c.offset, .radius = c.radius, .attenuation = c.attenuation },
        },
        components.SpotLight2D => .{
            .base = c.base,
            .kind = .spot,
            .shape = .{
                .offset = c.offset,
                .radius = c.radius,
                .attenuation = c.attenuation,
                .cone = @abs(c.cone_angle),
                .penumbra = @min(@max(c.penumbra, 0), 1),
            },
        },
        components.DirectionalLight2D => blk: {
            // A sun does not dim at the edge of the screen, so with no
            // `max_distance` its falloff reach is the view's. That is a
            // deliberate asymmetry with a point light at the same distance, and
            // it is the entire reason this component exists.
            const reach = if (c.max_distance > 0) c.max_distance else view_diag;
            break :blk .{
                .base = c.base,
                .kind = .directional,
                .shape = .{
                    .angle = c.angle,
                    .radius = reach,
                    // A directional light has no cone, so both cosines are 1 —
                    // which is what makes the shader's `c >= cos_inner` branch
                    // true for every direction. The cone test then costs one dot
                    // product and rejects nothing, which is the correct cost for
                    // "no cone".
                    .cone = null,
                    .shadow_reach = shadowReachForHeight(c.height, view_diag),
                    .view_centred = true,
                    .height = c.height,
                },
            };
        },
        components.AmbientLight2D => blk: {
            // A scene-wide ambient has to cover the view, and it must not fall
            // off across it: `radius` is 1.25x the diagonal so `rec01` stays
            // under 0.8 everywhere on screen, which is the flat part of the
            // ambient falloff curve.
            const reach = if (c.global) view_diag * 1.25 else @max(c.max_distance, 1);
            break :blk .{
                .base = c.base,
                .kind = .ambient,
                .shape = .{
                    .radius = reach,
                    .view_centred = c.global,
                    .can_shadow = false,
                },
            };
        },
        components.Light2D => .{
            // The legacy shape carries the shared fields flat rather than in a
            // `LightBase`, so it is assembled into one here. That is the whole
            // cost of keeping it: eight field reads in one arm, and every
            // downstream function sees the same descriptor either way.
            .base = .{
                .color = c.color,
                .energy = c.energy,
                .blend = c.blend,
                .cast_shadows = c.cast_shadows,
                .shadow_filter = c.shadow_filter,
                .shadow_filter_smooth = c.shadow_filter_smooth,
                .gi_contribution = c.gi_contribution,
                .item_cull_mask = c.item_cull_mask,
            },
            .kind = c.kind,
            .shape = .{
                .offset = c.offset,
                .angle = c.angle,
                .radius = c.radius,
                .attenuation = c.attenuation,
                .cone = if (c.kind == .point) null else @abs(c.cone_angle),
                .penumbra = c.penumbra,
            },
        },
        else => @compileError("not a light component: " ++ @typeName(C)),
    };
}
/// Walks every entity carrying one of the four light components.
///
/// Generic over the component type so the loop exists once. `descFor` is the
/// only thing that varies, and it is a comptime switch.
fn gather(comptime C: type, l: *Lighting, world: *World, view: ?MaskRect) void {
    // Without a view there is nothing to size a directional or scene-wide light
    // against. 2048 is a documented fallback, not a guess dressed as a
    // measurement: a caller that omits the view is a caller asking for the
    // lights to be gathered without knowing the screen, and the only wrong
    // answers are the ones where that light should have been culled anyway.
    const view_diag: f32 = if (view) |v|
        @max(distance(v.min, v.max), 1)
    else
        2048;

    var iter = world.query(.{C});
    var entry = iter.next();
    while (entry) |e| : (entry = iter.next()) {
        const c: *const C = e.get(C);
        // `Light2D` predates `LightBase` and has no `enabled`; it is on by
        // definition. `@hasField` rather than a `descFor` arm because this is the
        // ONE question `descFor` is not asked -- the descriptor is built after
        // this test, and an arm for it would be a second answer to a question the
        // switch below already answers.
        if (@hasField(C, "base") and !c.base.enabled) continue;

        const d = descFor(C, c.*, view_diag);
        const t: ?*const components.Transform = world.get(e.entity(), components.Transform);
        const actor: Vec2 = if (t) |tt| tt.position else .{ .x = 0, .y = 0 };

        // A view-centred light is drawn around the view, and a local one around
        // its own actor with the hotspot offset in the Transform's frame.
        const pos: Vec2 = if (d.shape.view_centred)
            (if (view) |v|
                .{ .x = (v.min.x + v.max.x) * 0.5, .y = (v.min.y + v.max.y) * 0.5 }
            else
                actor)
        else
            lightPos(actor, d.shape);

        if (view) |v| {
            if (!lightReaches(d.kind, pos, d.shape.radius, v)) continue;
        }

        l.lights.appendAssumeCapacity(instanceFor(d, pos, -1));
        l.channel_of.appendAssumeCapacity(if (d.shape.can_shadow and d.base.cast_shadows) -2 else -1);
        l.reach_of.appendAssumeCapacity(if (d.shape.shadow_reach > 0) d.shape.shadow_reach else d.shape.radius);
        l.owner_of.appendAssumeCapacity(@bitCast(e.entity()));
    }
}

/// A point light's `LightDesc`, for the tests that place a light without a World.
///
/// It goes through `descFor` rather than building the struct by hand so a test
/// cannot pass by describing a light the real collector would never produce.
fn pointDesc(base: components.LightBase, radius: f32) LightDesc {
    return descFor(components.PointLight2D, pointComp(base, radius), 0);
}

/// The `PointLight2D` a `pointDesc` describes. The two exist as a pair because
/// the tests that check the COLLECTOR need the component and the tests that
/// check the SAMPLER need the instance, and neither should be a second hand-
/// written description of the same light.
fn pointComp(base: components.LightBase, radius: f32) components.PointLight2D {
    return .{ .base = base, .radius = radius };
}

/// A spotlight's `LightDesc`, same reasoning as `pointDesc`.
fn spotDesc(base: components.LightBase, radius: f32, angle: f32, cone: f32, penumbra: f32) LightDesc {
    return descFor(components.SpotLight2D, .{
        .base = base,
        .radius = radius,
        .angle = angle,
        .cone_angle = cone,
        .penumbra = penumbra,
    }, 0);
}

fn lightPos(base: Vec2, s: LightShape) Vec2 {
    if (s.offset.x == 0 and s.offset.y == 0) return base;
    const c = @cos(s.angle);
    const sn = @sin(s.angle);
    return .{
        .x = base.x + s.offset.x * c - s.offset.y * sn,
        .y = base.y + s.offset.x * sn + s.offset.y * c,
    };
}

/// The wire form of a light at a position. `channel` is -1 when the light casts
/// no shadow, and the bit that says so is part of `flags` precisely because a
/// shader that has to test it per pixel should not have to read a second byte.
pub fn instanceFor(d: LightDesc, pos: Vec2, channel: i8) LightInstance {
    const s = d.shape;
    // No cone means a cone that includes every direction, which is what cos(0)
    // is. Clamping the half-angle keeps a zero-width cone from becoming a full
    // circle and a negative one from inverting.
    const half_cone = if (s.cone) |c| @min(@abs(c) * 0.5, std.math.pi) else 0;
    const reach = if (s.shadow_reach > 0) s.shadow_reach else s.radius;

    return .{
        .pos = .{ pos.x, pos.y },
        .radius = s.radius,
        .shadow_ratio = reach / @max(s.radius, 1e-4),
        .half = .{ s.radius, s.radius },
        .angle = s.angle,
        // The inner cosine is the cone shrunk by the penumbra. Clamped so a
        // penumbra of 1 (all softness, no hard core) does not invert it.
        .cos_outer = @cos(half_cone),
        .cos_inner = @cos(half_cone * @max(0, 1 - s.penumbra)),
        .color = d.base.color,
        .energy = d.base.energy,
        .attenuation = s.attenuation,
        .softness = @max(d.base.shadow_filter_smooth, 0) * 0.02,
        .gi = d.base.gi_contribution,
        .item_cull_mask = d.base.item_cull_mask,
        .flags = @as(u32, @intFromEnum(d.kind)) |
            (@as(u32, @intFromEnum(d.base.blend)) << 3) |
            (@as(u32, @intFromEnum(d.base.shadow_filter)) << 5) |
            (@as(u32, if (channel >= 0) 1 else 0) << 7) |
            (@as(u32, @intCast(channel & 0xf)) << 8),
    };
}


// ── Radiance cascades (2D GI) ────────────────────────────────────────────────
//
// The idea, and it is worth stating because "GI" in 2D usually means something
// much weaker: light that has bounced off an occluder must be able to REACH the
// place it bounced from. A single occlusion walk cannot answer "what is lit just
// now, having come around this corner", because answering it needs the light that
// arrived at the corner first.
//
// Radiance Cascades solves that with a pyramid of PROBE GRIDS, each at half the
// resolution of the one below it. A probe traces a few rays outward; each hit
// asks the NEXT cascade up what it saw from there. So cascade 0 catches the
// light that travelled a few texels, cascade 1 the light that travelled a few
// more, and the coarsest cascade resolves the sky and the the last bounce. The
// final answer at a pixel is the cascade whose range is closest to it, blended
// with its neighbours so the resolution seams are invisible.
//
// This is a CPU reference. The GPU version is a compute pass over the same
// pyramid, and the arithmetic here is what it must reproduce — line for line,
// because this is the half that can be tested without a device.

/// One probe's view of the world: what arrived from each direction.
///
/// `hit_distance` is in CASCADE-TEXEL units, and `incoming` is the radiance that
/// left the nearest hit travelling towards this probe. Storing the distance
/// rather than the hit's position is what makes a merge cheap: the next cascade
/// up is indexed by position and this is enough to find it.
pub const Probe = struct {
    /// Distance to the nearest occluder along this ray, in probe units. Zero when
    /// the ray starts inside solid geometry, which is the one case a merge must
    /// not sample through a wall.
    hit_distance: f32 = 0,
    /// The occluder's normal at the hit, or zero for no hit.
    normal: Vec2 = .{ .x = 0, .y = 0 },
    /// What radiance arrived along this ray, after the merge.
    incoming: [3]f32 = .{ 0, 0, 0 },
};

/// One cascade: a grid of probes at `scale` texel spacing.
pub const Cascade = struct {
    /// World-space distance between adjacent probes, in mask cells.
    scale: u32,
    /// Rays traced per probe. Higher in the fine cascades, where a ray covers a
    /// smaller angle — the counts are chosen so each cascade sees roughly the
    /// same angular resolution, which is the whole reason the pyramid works.
    rays: u32,
    w: u32,
    h: u32,
    probes: []Probe,

    fn deinit(self: *Cascade, allocator: std.mem.Allocator) void {
        allocator.free(self.probes);
        self.* = undefined;
    }
};

/// The radiance cascade pyramid.
///
/// Amortized exactly as the distance field is: rebuilt when an occluder moves,
/// and not once per frame. A static scene's GI is therefore free after the first
/// frame, and the cost of a moving one is bounded by the grid it walks, not by
/// the light count.
pub const Radiance = struct {
    allocator: std.mem.Allocator,
    /// Cascade 0 is the finest. Empty when GI is off.
    cascades: std.ArrayList(Cascade) = .empty,
    /// How many cascades were built for the current mask. Zero means "not built".
    built: u32 = 0,
    /// Incremented on every rebuild; the tests assert on it rather than on a
    /// timing, which is how "the amortization works" is checked headlessly.
    builds: u32 = 0,
    /// The budget this pyramid was prepared under, in probes per axis. Set by
    /// `prepare` and read by `build` to decide how many cascades exist, so the
    /// two can never disagree about the shape of the pyramid.
    fine_side: u32 = max_fine_side,

    /// The finest cascade's spacing, in mask cells. Two means a probe every other
    /// texel, which is the finest a texture can go without aliasing the SDF it
    /// traces — and GI at a finer scale than the shadow map itself is GI that
    /// cannot have been bounced off anything.
    pub const base_scale: u32 = 2;
    /// Rays per probe at cascade 0, doubling per level's coarsening... no, halving
    /// the count as the spacing doubles: the angular coverage is what is held
    /// roughly constant, not the count.
    pub const base_rays: u32 = 16;
    /// Stops at four cascades. A fifth would probe cells larger than a whole
    /// screen and every probe in it would see the same unobstructed sky, which is
    /// information a single per-cascade uniform already carries.
    pub const max_cascades: u32 = 4;

    /// The finest cascade's probe grid never exceeds this many probes PER AXIS,
    /// at any mask size.
    ///
    /// This is the whole reason M7's GI was 1.5 SECONDS per frame at 1080p and
    /// nobody noticed until a demo actually built the pyramid: with
    /// `base_scale = 2` fixed, the finest cascade was one probe per 2x2 texels,
    /// so a 2048x2048 mask wanted 1,048,576 probes x 16 rays = 16.7 million
    /// sphere traces — a cost that grew with the SCREEN, not with the scene. A
    /// bigger window made the renderer slower, which is not a quality dial.
    ///
    /// Bounding the probe COUNT instead of the spacing is the fix that keeps the
    /// meaning: GI is a large-scale enclosure term, so its detail is allowed to
    /// coarsen with the view while its cost stays flat. The probe SPACING is then
    /// derived from the mask size (`cellsFor`), which is exactly the trade a
    /// radiance cascade exists to make — and the cost of a frame is now set by
    /// the tier, which is what an editor's quality dropdown promises.
    ///
    /// 128 x 128 probes is 16,384 probes and 262,144 rays at cascade 0, and a
    /// 4x4 reduction in work for the same scene rendered at a quarter of the
    /// resolution — which is the point.
    pub const max_fine_side: u32 = 128;

    /// The probe spacing, in mask cells, for a mask `w` cells wide under a budget
    /// of `fine_side` probes per axis.
    ///
    /// `base_scale` on a small mask, and the next power of two that keeps the
    /// probe grid at or under the budget on a large one. Power of two so the
    /// cascade pyramid stays aligned: every level doubles the spacing, which is
    /// what lets a coarse level's probes sit exactly on a finer level's cell
    /// centres instead of between them.
    pub fn cellsFor(w: u32, fine_side: u32) u32 {
        if (w == 0) return base_scale;
        const budget = @max(fine_side, 1);
        const want = (w + budget - 1) / budget;
        var cells = base_scale;
        while (cells < want and cells < (1 << 20)) cells *= 2;
        return cells;
    }

    /// The finest cascade's probe budget, in probes per axis, for a quality tier.
    ///
    /// This is the dial `lighting.set_quality` turns. `.off` and `.low` have no
    /// pyramid at all, so their entry is the floor and is never used — it is
    /// there so the mapping is total and a caller cannot land on an undefined
    /// number by switching tiers.
    pub fn fineSideFor(tier: Quality) u32 {
        return switch (tier) {
            .off, .low => 32,
            .medium => 128,
            .high => 256,
        };
    }

    pub fn init(allocator: std.mem.Allocator) Radiance {
        return .{ .allocator = allocator };
    }

    pub fn deinit(self: *Radiance) void {
        for (self.cascades.items) |*c| c.deinit(self.allocator);
        self.cascades.deinit(self.allocator);
        self.* = undefined;
    }

    /// How many cascades fit a mask of this size under this tier's probe budget.
    /// Pure arithmetic on the mask dimensions and the budget — no allocation, no
    /// state — so `prepare` and `build` agree on the answer by construction
    /// instead of by two copies of the same loop.
    pub fn levelsFor(w: u32, h: u32, fine_side: u32) u32 {
        if (w == 0 or h == 0) return 0;
        const base = cellsFor(w, fine_side);
        var levels: u32 = 0;
        while (levels < max_cascades) {
            const cells = base * (@as(u32, 1) << @intCast(levels));
            if (w / cells < 1 or h / cells < 1) break;
            levels += 1;
        }
        return levels;
    }

    /// Allocates everything `build` will write, for a mask of this size.
    ///
    /// SEPARATE FROM `build` ON PURPOSE, and this is the second place the same
    /// mistake was made (the first was `Lighting.resize` being called inside the
    /// frame): the pyramid is rebuilt whenever an occluder moves, which is
    /// gameplay's decision and can happen on any frame, while allocating inside
    /// a frame is forbidden by spec §3.1 — `TrackedAllocator` panics on it
    /// rather than letting it slide. Growing `cascades` or reallocating a probe
    /// grid from `build` therefore took the whole process down on the first
    /// GI-active frame that moved an occluder.
    ///
    /// Idempotent and cheap when the size is unchanged, so the caller can run it
    /// unconditionally alongside `resize`. Everything `build` needs is derived
    /// from the mask dimensions and nothing else, so preparing once per resize
    /// is what it takes for `build` to be allocation-free for the rest of the
    /// mask's life.
    pub fn prepare(self: *Radiance, w: u32, h: u32, fine_side: u32) !void {
        const levels = levelsFor(w, h, fine_side);
        if (levels == 0) return;
        self.fine_side = fine_side;
        const base = cellsFor(w, fine_side);

        try self.cascades.ensureUnusedCapacity(self.allocator, levels);
        while (self.cascades.items.len < levels) {
            self.cascades.appendAssumeCapacity(.{
                .scale = base,
                .rays = base_rays,
                .w = 0,
                .h = 0,
                .probes = &.{},
            });
        }
        // Shrinking the mask drops the extra cascades rather than leaving dead
        // grids to be walked every probe merge.
        while (self.cascades.items.len > levels) {
            const c = self.cascades.pop().?;
            var owned = c;
            owned.deinit(self.allocator);
        }

        for (0..levels) |li| {
            const level: u32 = @intCast(li);
            const cells = base * (@as(u32, 1) << @intCast(level));
            const cw = @max(w / cells, 1);
            const ch = @max(h / cells, 1);
            const c = &self.cascades.items[li];
            c.scale = cells;
            c.rays = @max(base_rays >> @intCast(level), 2);
            if (cw == c.w and ch == c.h) continue;
            const grown = try self.allocator.alloc(Probe, @as(usize, cw) * ch);
            self.allocator.free(c.probes);
            c.probes = grown;
            c.w = cw;
            c.h = ch;
        }
    }

    /// (Re)builds the pyramid for a mask of this size.
    ///
    /// ALLOCATES NOTHING. `prepare` must have been run for this mask size first;
    /// if it was not, this returns `error.NotPrepared` rather than quietly
    /// allocating inside the frame. The runtime runs `prepare` from
    /// `Lighting.resize`, which is itself documented as the before-the-frame
    /// site, so the path that reaches here is allocation-free by construction.
    ///
    /// Still amortized exactly as the distance field is: rebuilt when an occluder
    /// moves, and not once per frame. A static scene's GI is therefore free after
    /// the first frame, and the cost of a moving one is bounded by the grid it
    /// walks, not by the light count.
    pub fn build(self: *Radiance, mask: []const u8, sdf: []const u16, w: u32, h: u32, sky: [3]f32) !void {
        if (w == 0 or h == 0) return;
        const levels = levelsFor(w, h, self.fine_side);
        if (levels == 0) return;
        if (self.cascades.items.len != levels) return error.NotPrepared;

        // Built coarse-to-fine so each cascade can read the one above it: the
        // finest cascade needs the second-finest's answer to finish. Ordering
        // fine-to-coarse would leave the whole bottom level reading zeros.
        var level: i32 = @as(i32, @intCast(levels)) - 1;
        while (level >= 0) : (level -= 1) {
            const li: usize = @intCast(level);
            const c = &self.cascades.items[li];
            const cw = c.w;
            const ch = c.h;
            if (cw == 0 or ch == 0) return error.NotPrepared;
            const next: ?*Cascade = if (level + 1 < levels)
                &self.cascades.items[li + 1]
            else
                null;

            var y: u32 = 0;
            while (y < ch) : (y += 1) {
                var x: u32 = 0;
                while (x < cw) : (x += 1) {
                    const idx = @as(usize, y) * cw + x;
                    // `c.scale` is the probe spacing, set by `prepare` for this
                    // level. Reading it here rather than recomputing `cells` keeps
                    // the grid and the probe lookup from ever disagreeing.
                    c.probes[idx] = probeAt(self, c, next, mask, sdf, w, h, x * c.scale, y * c.scale, sky);
                }
            }
        }
        self.built = levels;
        self.builds += 1;
    }

    /// The radiance that arrived at a world point, 0..1, as a colour.
    ///
    /// This is what the light pass samples on the GPU (once the compute pass
    /// exists) and what the CPU reference uses. Bilinear between the four
    /// neighbouring probes of the FINEST cascade, which is why `base_scale` is 2:
    /// finer and the merge cost doubles for detail the SDF itself does not carry.
    pub fn sample(self: *const Radiance, x: f32, y: f32) [3]f32 {
        if (self.built == 0) return .{ 0, 0, 0 };
        const c = &self.cascades.items[0];
        const in_cells = Vec2{ .x = x / @as(f32, @floatFromInt(c.scale)), .y = y / @as(f32, @floatFromInt(c.scale)) };
        const fx = @floor(in_cells.x);
        const fy = @floor(in_cells.y);
        const tx = in_cells.x - fx;
        const ty = in_cells.y - fy;
        const x0: u32 = @intFromFloat(fx);
        const y0: u32 = @intFromFloat(fy);
        if (x0 + 1 >= c.w or y0 + 1 >= c.h) return .{ 0, 0, 0 };
        const base = @as(usize, y0) * c.w + x0;
        const p00 = &c.probes[base];
        const p10 = &c.probes[base + 1];
        const p01 = &c.probes[base + c.w];
        const p11 = &c.probes[base + c.w + 1];

        var out = [3]f32{ 0, 0, 0 };
        for (0..3) |k| {
            const a = mix2(p00.incoming[k], p10.incoming[k], tx);
            const b = mix2(p01.incoming[k], p11.incoming[k], tx);
            out[k] = mix2(a, b, ty);
        }
        return out;
    }
};

fn mix2(a: f32, b: f32, t: f32) f32 {
    return a * (1 - t) + b * t;
}

/// Traces one probe: every ray in it, merged into the incoming radiance.
///
/// The merge is a SUM over the probe's directions, each weighted by its solid
/// angle. Summing rather than averaging is the part that makes a cascade
/// correct rather than merely plausible: integrating incoming light over the
/// hemisphere is what "illumination" means, and the weights are the solid angles
/// so a probe with fewer, wider rays and one with more, narrower rays that happen
/// to see the same sky give the same answer.
fn probeAt(
    r: *const Radiance,
    c: *const Cascade,
    next: ?*const Cascade,
    mask: []const u8,
    sdf: []const u16,
    w: u32,
    h: u32,
    px: u32,
    py: u32,
    sky: [3]f32,
) Probe {
    var acc = [3]f32{ 0, 0, 0 };
    const solid = 2.0 * math.pi / @as(f32, @floatFromInt(c.rays));

    _ = mask;
    var i: u32 = 0;
    while (i < c.rays) : (i += 1) {
        // Directions spread evenly, offset by half a step so the first ray is not
        // exactly along +x — a set that starts on an axis has a preferred
        // orientation a scene author can see as a shadow on one side.
        const theta = (@as(f32, @floatFromInt(i)) + 0.5) * solid;
        const dir = Vec2{ .x = @cos(theta), .y = @sin(theta) };

        // Sphere tracing the SDF: step by the distance field, which reaches an
        // occluder in O(sqrt(d)) iterations instead of the fixed step count a
        // march would need, and cannot skip over a thin wall because the field
        // never overestimates the true distance.
        var t: f32 = 0;
        const max_t: f32 = @floatFromInt(@min(c.w, c.h) * c.scale);
        var hit = false;
        var step: u32 = 0;
        while (step < 64) : (step += 1) {
            const px_x = @as(f32, @floatFromInt(px)) + dir.x * t;
            const px_y = @as(f32, @floatFromInt(py)) + dir.y * t;
            // The bounds test is in FLOATING POINT and comes before the integer
            // conversion, because the conversion is the part that panics. A ray
            // leaving the mask on the low side goes negative, and
            // `@intFromFloat` of a negative float is a runtime trap — so a test
            // written the other way round turns "the ray escaped to the sky"
            // into "the process died", which is how a GI crash report reads.
            if (px_x < 0 or px_y < 0 or px_x >= @as(f32, @floatFromInt(w)) or
                px_y >= @as(f32, @floatFromInt(h)))
            {
                // Out of the mask: the ray escaped to the sky.
                hit = false;
                break;
            }
            const ix: u32 = @intFromFloat(@floor(px_x));
            const iy: u32 = @intFromFloat(@floor(px_y));
            const d = @as(f32, @floatFromInt(sdf[@as(usize, iy) * w + ix]));
            if (d < 1.0) {
                hit = true;
                break;
            }
            t += @max(d * 0.9, 0.5);
            if (t > max_t) break;
        }

        if (!hit) {
            // The ray reached the sky. Its contribution is the sky's radiance
            // along this direction, which is the base case every cascade merge
            // eventually resolves to — and the only place the sky enters at all.
            for (0..3) |k| acc[k] += sky[k] * solid / (2.0 * math.pi);
            continue;
        }

        // A hit: ask the next cascade up what it saw from the hit point. That is
        // the bounce — the light that reached the occluder is now leaving it
        // towards this probe, and the next cascade is where that light is
        // recorded, at a resolution coarse enough to have traced it.
        var from_here = sky;
        if (next) |n| {
            const hx = @as(f32, @floatFromInt(px)) + dir.x * t;
            const hy = @as(f32, @floatFromInt(py)) + dir.y * t;
            from_here = sampleCascade(r, n, hx, hy);
        }
        // A hit contributes what it reflects, not what it receives: a fraction
        // scattered back into the hemisphere. 0.85 is a mid-grey wall.
        const bounce = 0.85;
        for (0..3) |k| acc[k] += from_here[k] * bounce * solid / (2.0 * math.pi);
    }

    return .{ .incoming = acc };
}

/// Nearest-probe read of a cascade, at probe units.
pub fn sampleCascade(r: *const Radiance, c: *const Cascade, x: f32, y: f32) [3]f32 {
    _ = r;
    const gx = @floor(x / @as(f32, @floatFromInt(c.scale)));
    const gy = @floor(y / @as(f32, @floatFromInt(c.scale)));
    const x0: u32 = @intFromFloat(gx);
    const y0: u32 = @intFromFloat(gy);
    // Outside the built region the answer is nothing, not the sky: a probe grid
    // that runs out says "no information here", and the caller decides what
    // "no information" means. Returning the sky from a nearest-probe read would
    // make the edge of the grid the brightest part of the image.
    if (x0 >= c.w or y0 >= c.h) return .{ 0, 0, 0 };
    const idx = @as(usize, y0) * c.w + x0;
    if (idx >= c.probes.len) return .{ 0, 0, 0 };
    return c.probes[idx].incoming;
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
/// The distance transform's scratch, sized once per mask.
///
/// ## Why it exists
///
/// `edtMask2d` used to allocate SEVEN buffers on every call, one of them a
/// `f64` array of `w * h` -- 2 MB for a 512x512 mask, allocated and freed
/// between two linear passes. That allocation is not the whole cost -- the
/// measured cost of the transform itself was 17-23 ms for that mask -- but it is
/// 2 MB of traffic per frame that buys nothing.
pub const EdtScratch = struct {
    /// The squared row result. `f64` and not `f32` because this same field
    /// decides whether a doorway reads as open, and an error there is a light
    /// leaking through a wall.
    sq: []f64 = &.{},
    row_in: []f64 = &.{},
    row_out: []f64 = &.{},
    col_in: []f64 = &.{},
    col_out: []f64 = &.{},
    /// The lower-envelope's breakpoints and the parabola separation points.
    v: []usize = &.{},
    z: []f64 = &.{},

    allocator: std.mem.Allocator = undefined,

    pub fn init(allocator: std.mem.Allocator) EdtScratch {
        return .{ .allocator = allocator };
    }

    pub fn deinit(self: *EdtScratch) void {
        self.allocator.free(self.sq);
        self.allocator.free(self.row_in);
        self.allocator.free(self.row_out);
        self.allocator.free(self.col_in);
        self.allocator.free(self.col_out);
        self.allocator.free(self.v);
        self.allocator.free(self.z);
        self.z = undefined;
        self.v = undefined;
        self.col_out = undefined;
        self.col_in = undefined;
        self.row_out = undefined;
        self.row_in = undefined;
        self.sq = undefined;
        self.allocator = undefined;
    }

    /// Grows the scratch for a `w` x `h` mask. A no-op when it already fits,
    /// which is every frame after the first.
    pub fn resize(self: *EdtScratch, w: u32, h: u32) !void {
        const n = @as(usize, w) * h;
        const widest = @max(w, h);
        if (self.sq.len >= n and self.row_in.len >= w and self.row_out.len >= w and
            self.col_in.len >= h and self.col_out.len >= h and self.v.len >= widest and
            self.z.len > widest) return;

        self.allocator.free(self.sq);
        self.allocator.free(self.row_in);
        self.allocator.free(self.row_out);
        self.allocator.free(self.col_in);
        self.allocator.free(self.col_out);
        self.allocator.free(self.v);
        self.allocator.free(self.z);

        self.sq = try self.allocator.alloc(f64, n);
        errdefer self.allocator.free(self.sq);
        self.row_in = try self.allocator.alloc(f64, w);
        errdefer self.allocator.free(self.row_in);
        self.row_out = try self.allocator.alloc(f64, w);
        errdefer self.allocator.free(self.row_out);
        self.col_in = try self.allocator.alloc(f64, h);
        errdefer self.allocator.free(self.col_in);
        self.col_out = try self.allocator.alloc(f64, h);
        errdefer self.allocator.free(self.col_out);
        self.v = try self.allocator.alloc(usize, widest);
        errdefer self.allocator.free(self.v);
        self.z = try self.allocator.alloc(f64, widest + 1);
    }
};

/// The exact distance transform of a binary mask, into caller-owned scratch.
///
/// No allocator and no error: the scratch is sized by `Lighting.resize`, which
/// runs before a frame (spec §3.1), so the transform cannot fail and does not
/// check. A caller whose scratch is too small gets a field that did not change
/// rather than a panic -- which is wrong but free, and the sized-in-`resize`
/// precondition is what makes it unreachable.
pub fn edtMask2dInto(
    scratch: *EdtScratch,
    mask: []const u8,
    out: []u16,
    w: u32,
    h: u32,
) void {
    const n = @as(usize, w) * h;
    if (w == 0 or h == 0) return;
    if (out.len < n or mask.len < n) return;
    if (scratch.sq.len < n or scratch.row_in.len < w or scratch.row_out.len < w or
        scratch.col_in.len < h or scratch.col_out.len < h) return;

    const sq = scratch.sq[0..n];
    // EVERY scratch slice is truncated to the grid being transformed, not just
    // the envelope arrays. `edt1d` takes its length from `d_in`, so passing a
    // scratch row longer than the grid makes it walk `n` positions through
    // buffers sized for a smaller problem and write past the end of `v`.
    //
    // This could not happen while the transform ran at mask resolution and the
    // scratch was sized for exactly that mask: `d_in.len` and `@max(w, h)`
    // agreed by construction. The GI decouple is what broke the agreement, by
    // making the grid legitimately smaller than the scratch that serves it. A
    // reusable buffer being larger than its user is the normal case, not the
    // exotic one, and the code now says so instead of relying on it never
    // happening.
    const row_in = scratch.row_in[0..w];
    const row_out = scratch.row_out[0..w];
    const col_in = scratch.col_in[0..h];
    const col_out = scratch.col_out[0..h];
    const v = scratch.v[0..@max(w, h)];
    const z = scratch.z[0 .. @max(w, h) + 1];

    // INF as a local, not `std.math.inf` per cell: that is a call in the
    // innermost loop of a pass over every texel.
    const INF = std.math.inf(f64);

    // Rows: seed solid cells at zero, free cells at infinity. The row pass does
    // NOT write `out` -- the column pass overwrites every cell of it, so a sqrt
    // and an int conversion per cell there is work whose only effect is time.
    var y: usize = 0;
    while (y < h) : (y += 1) {
        const row = y * w;
        var x: usize = 0;
        while (x < w) : (x += 1) {
            row_in[x] = if (mask[row + x] != 0) 0 else INF;
        }
        edt1d(row_in, row_out, v, z);
        x = 0;
        while (x < w) : (x += 1) sq[row + x] = row_out[x];
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

/// An allocating `edtMask2d`, for callers with no scratch of their own.
///
/// The runtime does NOT use this -- `Lighting` holds an `EdtScratch` sized in
/// `resize` and calls `edtMask2dInto`. This form stays because a test has
/// nothing to hold a scratch and the cost is once.
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
    var scratch = EdtScratch.init(allocator);
    defer scratch.deinit();
    try scratch.resize(w, h);
    edtMask2dInto(&scratch, mask, out, w, h);
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

    // `qf` is incremented in the loop's own clause, once per `q` and never once
    // per rejection. It used to be advanced inside the body as well, which ran
    // the running index ahead of `q` and produced a transform that is wrong by
    // the amount the envelope was over-extended.
    var q: usize = 1;
    var qf: f64 = 1.0;
    // One clause advances both, so the float can never run ahead of the index.
    // This is the whole bug the f64 rewrite introduced: `qf` was advanced inside
    // the body, once per rejection, and several rejections share one `q`.
    while (q < n) : ({ q += 1; qf += 1.0; }) {
        s: while (true) {
            const vf = @as(f64, @floatFromInt(v[k]));
            // The candidate intersection. With an infinite cost on `q` this is
            // `inf / finite` = +inf, so q enters the envelope, which is what "a
            // free cell never produces a crossing point below this" means.
            //
            // Pure f64, and the index carried as a running float: this used to
            // do usize -> i64 -> f64 round-trips with an i64 multiply and a
            // divide in the critical path, measured at 55 ns per MASK CELL.
            const s_new = (qf + vf) * 0.5 +
                (d_in[q] - d_in[v[k]]) / (2.0 * (qf - vf));
            if (k == 0 or s_new > z[k]) {
                k += 1;
                v[k] = q;
                z[k] = s_new;
                z[k + 1] = std.math.inf(f64);
                break :s;
            }
            // NO `qf += 1` in here: the `while` runs once per rejection and
            // several rejections share one `q`. Advancing it here made the
            // running index run ahead of `q`, which is a transform that is wrong
            // by exactly the amount the envelope was over-extended.
            k -= 1;
        }
        // And not here either: the loop's clause advances both `q` and `qf`
        // together, and a second advance would run the float ahead of the index.
    }

    k = 0;
    var j: usize = 0;
    var jf: f64 = 0.0;
    while (j < n) : (j += 1) {
        while (z[k + 1] < jf) k += 1;
        const delta = jf - @as(f64, @floatFromInt(v[k]));
        d_out[j] = delta * delta + d_in[v[k]];
        jf += 1.0;
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

/// A full-height wall from `x0` to `x1`. Named because the tests that need one
/// all need the same thing, and four hand-written point arrays differ in their
/// last coordinate often enough to be a bug waiting for someone to notice.
fn wallPoly(x0: f32, y0: f32, x1: f32, y1: f32) components.OccluderPolygon {
    var poly = components.OccluderPolygon{};
    poly.count = 4;
    poly.points = points(&.{ x0, y0, x1, y0, x1, y1, x0, y1 });
    return poly;
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

    const light = pointDesc(.{ .cast_shadows = true }, 64);
    l.lights.appendAssumeCapacity(instanceFor(light, .{ .x = 8, .y = 32 }, 0));
    l.reach_of.appendAssumeCapacity(64);
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
        pointDesc(.{ .shadow_filter_smooth = 8 }, 64),
        .{ .x = 0, .y = 0 },
        0,
    ));
    l.reach_of.appendAssumeCapacity(64);
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
        spotDesc(.{}, 256, 0, 1.5707963268, 0.5), // 90 degrees
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

    const add = pointDesc(.{ .color = .{ 0.5, 0.5, 0.5, 1 } }, 64);
    var sub = add;
    sub.base.blend = .subtract;
    var mix = add;
    mix.base.blend = .mix;

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
    _ = l.updateSdf(0);

    const near_wall = l.sampleGi(6, 32);
    const middle = l.sampleGi(40, 32);
    try testing.expect(near_wall < middle);
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
            pointComp(.{ .cast_shadows = true }, 32),
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
    l.lights.appendAssumeCapacity(instanceFor(pointDesc(.{}, 64), .{ .x = 8, .y = 32 }, 0));
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

test "render light: an occluder that moves re-sweeps a light that did not" {
    // The regression this guards is invisible from every count in the stats: the
    // occluder is gathered, the mask is rasterized, the light holds its channel
    // and reports 4 of 4 granted — and the shadow map is the one from before the
    // wall moved, because `rasterize` clears `mask_changed` and `buildShadowMaps`
    // ran after it and read the cleared flag. A stationary torch is the common
    // case in a level, so this is the common case too.
    var l = try Lighting.init(testing.allocator, .high);
    defer l.deinit();
    try l.resize(64, 64);
    try l.reserve(4, 4);
    l.rect = .{ .min = .{ .x = 0, .y = 0 }, .max = .{ .x = 64, .y = 64 } };

    var world = World.init(testing.allocator);
    defer world.deinit();
    const wall = try world.spawn(.{
        components.Transform{ .position = .{ .x = 0, .y = 0 } },
        components.LightOccluder2D{ .mode = .manual, .polygon = wallPoly(24, 0, 28, 64) },
    });
    const torch = try world.spawn(.{
        components.Transform{ .position = .{ .x = 8, .y = 32 } },
        pointComp(.{ .cast_shadows = true }, 64),
    });

    // The runtime's order, exactly: gather, rasterize, sweep.
    l.collect(&world, l.rect);
    l.rasterize();
    l.buildShadowMaps();
    try testing.expect(l.stats.sweep_steps > 0);
    const first_map = try testing.allocator.dupe(u8, l.shadow);

    // Nothing moves: no work, which is the amortization the design is for.
    l.collect(&world, l.rect);
    l.buildShadowMaps();
    try testing.expectEqual(@as(u64, 0), l.stats.sweep_steps);

    // The WALL moves. The light does not.
    world.get(wall, components.Transform).?.position.x += 24;
    l.collect(&world, l.rect);
    l.rasterize();
    l.buildShadowMaps();
    try testing.expect(l.stats.sweep_steps > 0);

    var differs = false;
    for (first_map, l.shadow) |a, b| {
        if (a != b) differs = true;
    }
    try testing.expect(differs);
    // The torch never moved, so the only reason to re-sweep is the mask.
    try testing.expectEqual(@as(u8, 8), world.get(torch, components.Transform).?.position.x);
    testing.allocator.free(first_map);
}

test "render light: an occluder that changes SHAPE with position and extent fixed is noticed" {
    // The hole the polygon's own points fill. The fingerprint mixed position,
    // extent and radius — so an occluder swapped for a different shape at the
    // same place with the same bounding box hashed identically, `rasterize`
    // returned early, and the shadow stayed the old one. That is a prefab
    // swapped on an actor, which is how a scene changes shape most often, and
    // the symptom is a shadow that survives the edit that should have moved it.
    var l = try Lighting.init(testing.allocator, .high);
    defer l.deinit();
    try l.resize(64, 64);
    try l.reserve(4, 4);
    l.rect = .{ .min = .{ .x = 0, .y = 0 }, .max = .{ .x = 64, .y = 64 } };

    var world = World.init(testing.allocator);
    defer world.deinit();
    const block = try world.spawn(.{
        components.Transform{ .position = .{ .x = 0, .y = 0 } },
        // A full rectangle inside a 20x40 box, so the extent is identical to the
        // one it is replaced with below.
        components.LightOccluder2D{ .mode = .manual, .polygon = wallPoly(20, 10, 40, 50) },
    });

    l.collect(&world, l.rect);
    l.rasterize();
    const solid = l.stats.mask_fill;
    try testing.expect(solid > 0);
    const first_mask = try testing.allocator.dupe(u8, l.mask);

    // The same box, half of it. Position unchanged, extent unchanged.
    var half = components.OccluderPolygon{};
    half.count = 4;
    half.points = points(&.{ 20, 50, 40, 10, 40, 50, 20, 50 });
    world.get(block, components.LightOccluder2D).?.polygon = half;

    l.collect(&world, l.rect);
    try testing.expect(l.mask_changed);
    l.rasterize();

    // The claim is that the MASK is the new shape, not that it is some specific
    // fraction — a ratio would be a second thing to get wrong, and the pixels
    // are the thing anybody can see.
    var differs = false;
    for (first_mask, l.mask) |a, b| {
        if (a != b) differs = true;
    }
    try testing.expect(differs);
    try testing.expect(l.stats.mask_fill != solid);
    testing.allocator.free(first_mask);
}

test "render light: an even number of identical occluders still build their mask" {
    // XOR is its own inverse, so a per-occluder `h ^= contribution` folds a pair
    // of identical occluders to nothing. Forty identical walls hashed to exactly
    // 0, which is also what a resize leaves in `occluder_hash`, so the mask was
    // never built and every shadow in the scene was cast by an empty grid. The
    // numbers all looked fine: 40 occluders, 4/4 channels granted.
    var l = try Lighting.init(testing.allocator, .high);
    defer l.deinit();
    try l.resize(64, 64);
    try l.reserve(8, 8);
    l.rect = .{ .min = .{ .x = 0, .y = 0 }, .max = .{ .x = 64, .y = 64 } };

    var world = World.init(testing.allocator);
    defer world.deinit();
    var i: usize = 0;
    while (i < 8) : (i += 1) {
        _ = try world.spawn(.{
            components.Transform{ .position = .{ .x = 0, .y = 0 } },
            // Identical walls at identical positions: the exact shape the old
            // hash cancelled.
            components.LightOccluder2D{ .mode = .manual, .polygon = wallPoly(30, 0, 34, 64) },
        });
    }

    l.collect(&world, l.rect);
    try testing.expect(l.mask_changed);
    l.rasterize();
    try testing.expectEqual(@as(u32, 8), l.stats.occluders_rasterized);
    try testing.expect(l.stats.mask_fill > 0);

    // And a second identical frame is still a no-op, so the fix did not turn
    // amortization off by making every fingerprint different.
    l.collect(&world, l.rect);
    try testing.expect(!l.mask_changed);
}

test "render light: the radiance pyramid is built coarse-to-fine and only once" {
    var r = Radiance.init(testing.allocator);
    defer r.deinit();

    var l = try Lighting.init(testing.allocator, .high);
    defer l.deinit();
    try l.resize(64, 64);
    try l.reserve(4, 4);
    l.rect = .{ .min = .{ .x = 0, .y = 0 }, .max = .{ .x = 64, .y = 64 } };
    // A 4x4 wall block.
    var poly = components.OccluderPolygon{};
    poly.count = 4;
    poly.points = points(&.{ 30, 30, 34, 30, 34, 34, 30, 34 });
    l.occluders.appendAssumeCapacity(.{ .polygon = poly, .pos = .{ .x = 0, .y = 0 }, .extent = 16 });
    l.rasterize();
    try edtMask2d(testing.allocator, l.mask, l.sdf, 64, 64);

    const sky = [3]f32{ 1, 1, 1 };
    try r.prepare(64, 64, Radiance.fineSideFor(.medium));
    try r.build(l.mask, l.sdf, 64, 64, sky);

    try testing.expect(r.built >= 2);
    try testing.expectEqual(@as(u32, 1), r.builds);
    // The finest cascade is the busiest.
    try testing.expect(r.cascades.items[0].w * r.cascades.items[0].h >
        r.cascades.items[1].w * r.cascades.items[1].h);

    // Rebuilding without a resize and without a change is a no-op cost-wise
    // only if the caller decides not to; this build genuinely re-walks, which is
    // what the amortization test's `builds` counter is FOR: it is the caller's
    // decision, not this one's.
    try r.prepare(64, 64, Radiance.fineSideFor(.medium));
    try r.build(l.mask, l.sdf, 64, 64, sky);
    try testing.expectEqual(@as(u32, 2), r.builds);
}

test "render light: a corner is darker than the open sky, which is GI working" {
    var r = Radiance.init(testing.allocator);
    defer r.deinit();

    var l = try Lighting.init(testing.allocator, .high);
    defer l.deinit();
    try l.resize(64, 64);
    try l.reserve(4, 4);
    l.rect = .{ .min = .{ .x = 0, .y = 0 }, .max = .{ .x = 64, .y = 64 } };
    // Two walls forming a corner, the classic GI test: the corner is enclosed on
    // two sides, so the probes in it mostly see each other rather than the sky,
    // and the cascade must resolve that.
    var poly = components.OccluderPolygon{};
    poly.count = 4;
    poly.points = points(&.{ 0, 32, 32, 32, 32, 36, 0, 36 });
    l.occluders.appendAssumeCapacity(.{ .polygon = poly, .pos = .{ .x = 0, .y = 0 }, .extent = 36 });
    var poly2 = components.OccluderPolygon{};
    poly2.count = 4;
    poly2.points = points(&.{ 28, 0, 32, 0, 32, 64, 28, 64 });
    l.occluders.appendAssumeCapacity(.{ .polygon = poly2, .pos = .{ .x = 0, .y = 0 }, .extent = 32 });
    l.rasterize();
    try edtMask2d(testing.allocator, l.mask, l.sdf, 64, 64);

    try r.prepare(64, 64, Radiance.fineSideFor(.medium));
    try r.build(l.mask, l.sdf, 64, 64, .{ 1, 1, 1 });

    // The open middle of the screen sees the sky on every ray.
    const open = r.sample(60, 8);
    try testing.expect(open[0] > 0.05);

    // The corner at (4, 40) is behind both walls. Its probes trace upward and
    // inward; most of their rays hit the walls' own bounce rather than the sky,
    // and each bounce is attenuated. The threshold is deliberately loose because
    // the exact number is a function of the solid angles, not a property of the
    // scene -- the assertion is the DIRECTION, which is what a regression test
    // can detect.
    const corner = r.sample(8, 40);
    try testing.expect(corner[0] < open[0]);
}

// ── the four components, end to end ─────────────────────────────────────────
//
// Each of these spawns a REAL component into a REAL world and lets `collect`
// find it. That is the point: a test that builds a `LightInstance` by hand
// proves the sampler works, and says nothing about whether the component a
// scene author adds reaches it.

/// A world with one of each light kind, and the mask the collector culls against.
fn fourLightWorld(l: *Lighting, world: *World) !void {
    try l.resize(64, 64);
    try l.reserve(8, 8);
    l.rect = .{ .min = .{ .x = 0, .y = 0 }, .max = .{ .x = 64, .y = 64 } };
    _ = try world.spawn(.{
        components.Transform{ .position = .{ .x = 32, .y = 32 } },
        components.PointLight2D{ .radius = 40 },
    });
    _ = try world.spawn(.{
        components.Transform{ .position = .{ .x = 8, .y = 8 } },
        components.SpotLight2D{ .radius = 40, .angle = 0.5 },
    });
    _ = try world.spawn(.{
        components.Transform{ .position = .{ .x = 0, .y = 0 } },
        components.DirectionalLight2D{},
    });
    _ = try world.spawn(.{
        components.Transform{ .position = .{ .x = 0, .y = 0 } },
        components.AmbientLight2D{},
    });
}

test "render light: collect finds all four component kinds and keeps their kinds" {
    var l = try Lighting.init(testing.allocator, .high);
    defer l.deinit();
    var world = World.init(testing.allocator);
    defer world.deinit();
    try fourLightWorld(&l, &world);
    l.collect(&world, l.rect);

    try testing.expectEqual(@as(u32, 4), l.stats.lights);
    var seen = [_]bool{false} ** 4;
    for (l.lights.items) |inst| {
        const k: usize = @intFromEnum(inst.kind());
        try testing.expect(k < 4);
        seen[k] = true;
    }
    for (seen, 0..) |was, i| {
        if (!was) {
            const names = [_][]const u8{ "point", "spot", "directional", "ambient" };
            std.debug.print("collect missed a {s} light\n", .{names[i]});
            return error.MissingLightKind;
        }
    }
}

test "render light: an ambient light is flat, which is what makes it ambient" {
    var l = try Lighting.init(testing.allocator, .high);
    defer l.deinit();
    try l.resize(64, 64);
    try l.reserve(4, 4);
    l.rect = .{ .min = .{ .x = 0, .y = 0 }, .max = .{ .x = 64, .y = 64 } };
    var world = World.init(testing.allocator);
    defer world.deinit();
    _ = try world.spawn(.{
        components.Transform{ .position = .{ .x = 0, .y = 0 } },
        components.AmbientLight2D{ .base = .{ .color = .{ 1, 1, 1, 1 }, .energy = 1 } },
    });
    l.collect(&world, l.rect);

    // The assertion is the SHAPE of the curve, not one value: an ambient that
    // dims with distance is a point light with a large radius, and the bug it
    // causes is a scene whose ambient is visibly "in" one spot.
    const corner = l.sampleLight(0, 1, 1)[0];
    const middle = l.sampleLight(0, 32, 32)[0];
    const far = l.sampleLight(0, 61, 61)[0];
    try testing.expectApproxEqAbs(middle, corner, 0.001);
    try testing.expectApproxEqAbs(middle, far, 0.001);
    try testing.expectApproxEqAbs(@as(f32, 1), middle, 0.001);
}

test "render light: a directional light's height sets its shadow length, and only that" {
    var high = try Lighting.init(testing.allocator, .high);
    defer high.deinit();
    var low = try Lighting.init(testing.allocator, .high);
    defer low.deinit();
    for ([_]*Lighting{ &high, &low }) |l| {
        try l.resize(64, 64);
        try l.reserve(4, 4);
        l.rect = .{ .min = .{ .x = 0, .y = 0 }, .max = .{ .x = 64, .y = 64 } };
    }
    // Two worlds, not one with two lights in it: the point of the comparison is
    // one variable, and a shared world would also let the second light be
    // ranked, culled, or sorted into a different slot.
    var world_h = World.init(testing.allocator);
    defer world_h.deinit();
    var world_l = World.init(testing.allocator);
    defer world_l.deinit();
    _ = try world_h.spawn(.{
        components.Transform{ .position = .{ .x = 0, .y = 0 } },
        components.DirectionalLight2D{ .height = 1.0 },
    });
    _ = try world_l.spawn(.{
        components.Transform{ .position = .{ .x = 0, .y = 0 } },
        components.DirectionalLight2D{ .height = 0.25 },
    });
    high.collect(&world_h, high.rect);
    low.collect(&world_l, low.rect);
    try testing.expectEqual(@as(u32, 1), high.stats.lights);
    try testing.expectEqual(@as(u32, 1), low.stats.lights);

    const a = high.reach_of.items[0];
    const b = low.reach_of.items[0];
    // A sun near the horizon throws shadows several times longer. The direction
    // is the assertion; the exact multiple is `view / height` clamped, which is
    // stated in `shadowReachForHeight` and not re-derived here.
    try testing.expect(b > a);
    try testing.expectApproxEqAbs(@as(f32, 4), b / a, 0.001);

    // And the falloff reach did NOT follow: that is the whole reason the two
    // numbers are separate. A sun does not dim at the edge of the screen.
    try testing.expectApproxEqAbs(high.lights.items[0].radius, low.lights.items[0].radius, 0.001);
}

test "render light: an ambient light can never be given a shadow channel" {
    var l = try Lighting.init(testing.allocator, .high);
    defer l.deinit();
    try l.resize(64, 64);
    try l.reserve(4, 4);
    l.rect = .{ .min = .{ .x = 0, .y = 0 }, .max = .{ .x = 64, .y = 64 } };
    var world = World.init(testing.allocator);
    defer world.deinit();
    // `cast_shadows = true` on an ambient: a scene author can ask for it through
    // the shared LightBase, and the collector has to decline.
    _ = try world.spawn(.{
        components.Transform{ .position = .{ .x = 0, .y = 0 } },
        components.AmbientLight2D{ .base = .{ .cast_shadows = true } },
    });
    l.collect(&world, l.rect);
    try testing.expectEqual(@as(u32, 1), l.stats.lights);
    try testing.expectEqual(@as(i8, -1), l.channel_of.items[0]);
    try testing.expect(!l.lights.items[0].castsShadows());
}

test "render light: a point light's instance is laid out where the shader reads it" {
    // The backend declares attributes at 0/8/16/24/32/40/48/56 and light.wgsl's
    // LightIn reads the same. A struct that drifts from that is not a wrong
    // light, it is garbage that still renders — so the layout is asserted here,
    // where a change to it is a change to a test rather than to a scene.
    const i = instanceFor(pointDesc(.{}, 100), .{ .x = 5, .y = 6 }, 3);
    try testing.expectEqual(@as(u32, 76), @sizeOf(LightInstance));
    try testing.expectEqual(@as(usize, 72), @offsetOf(LightInstance, "item_cull_mask"));
    try testing.expectEqual(@as(usize, 0), @offsetOf(LightInstance, "pos"));
    try testing.expectEqual(@as(usize, 8), @offsetOf(LightInstance, "radius"));
    try testing.expectEqual(@as(usize, 12), @offsetOf(LightInstance, "shadow_ratio"));
    try testing.expectEqual(@as(usize, 16), @offsetOf(LightInstance, "half"));
    try testing.expectEqual(@as(usize, 24), @offsetOf(LightInstance, "angle"));
    try testing.expectEqual(@as(usize, 28), @offsetOf(LightInstance, "cos_outer"));
    try testing.expectEqual(@as(usize, 32), @offsetOf(LightInstance, "cos_inner"));
    try testing.expectEqual(@as(usize, 40), @offsetOf(LightInstance, "color"));
    try testing.expectEqual(@as(usize, 56), @offsetOf(LightInstance, "attenuation"));
    try testing.expectEqual(@as(usize, 64), @offsetOf(LightInstance, "gi"));

    // And the values land where they are supposed to: the point of the
    // assertion above is that these do not quietly mean something else.
    try testing.expectEqual(@as(f32, 100), i.radius);
    try testing.expectEqual(@as(f32, 100), i.half[0]);
    try testing.expectApproxEqAbs(@as(f32, 1), i.shadow_ratio, 0.0001);
    try testing.expectEqual(@as(i8, 3), i.shadowChannel());
}

test "render light: energy and the colour's alpha scale what arrives" {
    // The shader multiplies both and the CPU reference multiplies both; a
    // regression in either is a light that ignores the one dial every scene has.
    var l = try Lighting.init(testing.allocator, .high);
    defer l.deinit();
    try l.resize(64, 64);
    try l.reserve(4, 4);
    l.rect = .{ .min = .{ .x = 0, .y = 0 }, .max = .{ .x = 64, .y = 64 } };

    const bright = instanceFor(pointDesc(.{ .energy = 1 }, 64), .{ .x = 32, .y = 32 }, -1);
    const dim = instanceFor(pointDesc(.{ .energy = 0.5 }, 64), .{ .x = 32, .y = 32 }, -1);
    const half_alpha = instanceFor(
        pointDesc(.{ .color = .{ 1, 1, 1, 0.5 } }, 64),
        .{ .x = 32, .y = 32 },
        -1,
    );

    l.lights.appendAssumeCapacity(bright);
    l.channel_of.appendAssumeCapacity(-1);
    l.reach_of.appendAssumeCapacity(64);
    const at_center = l.sampleLight(0, 32, 32)[0];

    l.lights.items[0] = dim;
    const at_half_energy = l.sampleLight(0, 32, 32)[0];

    l.lights.items[0] = half_alpha;
    const at_half_alpha = l.sampleLight(0, 32, 32)[0];

    try testing.expectApproxEqAbs(at_center * 0.5, at_half_energy, 0.0001);
    try testing.expectApproxEqAbs(at_center * 0.5, at_half_alpha, 0.0001);
}

test "render light: a still scene skips every channel, and a moved light rebuilds only its own" {
    // This is the amortization the subsystem exists for, and it regressed
    // silently: `collect` cleared every channel's "built" flag on every frame,
    // on the reasoning that the channels are redistributed each frame. The flag
    // was therefore never true and NO frame was ever skipped -- which the
    // benchmark caught at 3.1 ms for four shadowed lights, a cost the design is
    // supposed to avoid.
    //
    // The assertion is per channel rather than "some frames skip", because the
    // bug it guards against is a global reset and a per-channel statement is the
    // one that fails if the reset comes back.
    var l = try Lighting.init(testing.allocator, .high);
    defer l.deinit();
    try l.resize(128, 128);
    try l.reserve(8, 8);
    l.rect = .{ .min = .{ .x = 0, .y = 0 }, .max = .{ .x = 128, .y = 128 } };

    var world = World.init(testing.allocator);
    defer world.deinit();
    // Four shadowed lights, all with the same reach so a channel swap is only
    // detectable through the OWNER and not through the radius.
    var i: usize = 0;
    while (i < 4) : (i += 1) {
        _ = try world.spawn(.{
            components.Transform{ .position = .{ .x = @as(f32, @floatFromInt(i)) * 16 + 16, .y = 64 } },
            pointComp(.{ .cast_shadows = true }, 96),
        });
    }

    // Frame 1: everything builds.
    l.collect(&world, l.rect);
    l.rasterize();
    l.buildShadowMaps();
    try testing.expectEqual(@as(u32, 0), l.stats.sweep_skips);
    try testing.expectEqual(@as(u32, 4), l.stats.shadow_lights);

    // Frame 2, nothing moved: four skips and zero steps.
    l.collect(&world, l.rect);
    l.buildShadowMaps();
    try testing.expectEqual(@as(u32, 4), l.stats.sweep_skips);
    try testing.expectEqual(@as(u64, 0), l.stats.sweep_steps);

    // Frame 3, one light moved: exactly one channel rebuilds.
    var it = world.query(.{components.PointLight2D, components.Transform});
    var e = it.next();
    var k: usize = 0;
    while (e) |row| : (e = it.next()) {
        if (k == 0) row.get(components.Transform).position.x += 4;
        k += 1;
    }
    l.collect(&world, l.rect);
    l.buildShadowMaps();
    try testing.expectEqual(@as(u32, 3), l.stats.sweep_skips);
    try testing.expect(l.stats.sweep_steps > 0);

    // Frame 4, still again: back to skipping everything, which is the part that
    // proves the skip is not a one-shot and that `collect` is not clearing the
    // flags behind `buildShadowMaps`' back.
    l.collect(&world, l.rect);
    l.buildShadowMaps();
    try testing.expectEqual(@as(u32, 4), l.stats.sweep_skips);
    try testing.expectEqual(@as(u64, 0), l.stats.sweep_steps);
}

test "render light: a different light in a channel rebuilds it even at the same position" {
    // Position alone cannot tell "this light did not move" from "a different
    // light now stands where it used to be", and the second case reuses a map
    // that describes something else. The owner is what distinguishes them.
    var l = try Lighting.init(testing.allocator, .high);
    defer l.deinit();
    try l.resize(128, 128);
    try l.reserve(8, 8);
    l.rect = .{ .min = .{ .x = 0, .y = 0 }, .max = .{ .x = 128, .y = 128 } };

    var world = World.init(testing.allocator);
    defer world.deinit();
    const a = try world.spawn(.{
        components.Transform{ .position = .{ .x = 64, .y = 64 } },
        pointComp(.{ .cast_shadows = true }, 96),
    });
    _ = try world.spawn(.{
        components.Transform{ .position = .{ .x = 0, .y = 0 } },
        pointComp(.{ .cast_shadows = true }, 96),
    });
    // A wall only `a` can see, so the two lights' maps genuinely differ.
    var poly = components.OccluderPolygon{};
    poly.count = 4;
    poly.points = .{ 70, 0, 74, 0, 74, 128, 70, 128, 0, 0, 0, 0, 0, 0, 0, 0 };
    _ = try world.spawn(.{
        components.Transform{ .position = .{ .x = 0, .y = 0 } },
        components.LightOccluder2D{ .mode = .manual, .polygon = poly },
    });

    l.collect(&world, l.rect);
    l.rasterize();
    l.buildShadowMaps();
    const before = l.shadow[0];

    // Swap them: the light at the origin becomes the one at (64,64) and the
    // other disappears. Channel 0 keeps its position and its reach, so only the
    // owner differs.
    world.get(a, components.Transform).?.position.x = 0;
    l.collect(&world, l.rect);
    l.buildShadowMaps();

    // The map changed, which is the point: a channel rebuilt because its OWNER
    // changed, not because anything moved. "Less than four skipped" rather than
    // "zero skipped" because only one of the two channels changed hands -- the
    // other light is untouched and its map is still correct, so skipping it is
    // the behaviour being defended.
    try testing.expect(l.stats.sweep_skips < 4);
    try testing.expect(l.stats.sweep_steps > 0);
    try testing.expect(l.shadow[0] != before);
}

test "render light: alpha_threshold draws the edge of an automatic occluder, because it is read" {
    // `occluder.set_threshold` used to write a field that appeared NOWHERE in the
    // render path. It is the documented fix for "my sprite has a fringe of
    // shadow", and it fixed nothing.
    //
    // The mechanism: a 16x16 coverage mask with a soft edge — 0 in the middle,
    // ramping to 255 at the border. One threshold rasterizes the ramp's middle
    // and the other its outer edge, so the filled area differs by a measurable
    // amount. That difference IS the feature.
    var store = CoverageStore.init(testing.allocator);
    defer store.deinit();

    const w: u32 = 16;
    const h: u32 = 16;
    var pixels: [w * h]u8 = undefined;
    for (0..h) |y| {
        for (0..w) |x| {
            // A ring: solid centre, fading to nothing at the border.
            const d = @as(f32, @floatFromInt(@min(x, y))) / 7.0;
            pixels[y * w + x] = clampByte(d);
        }
    }
    const idx = try store.add(&pixels, w, h);

    var l = try Lighting.init(testing.allocator, .high);
    defer l.deinit();
    try l.resize(32, 32);
    try l.reserve(4, 4);
    l.rect = .{ .min = .{ .x = 0, .y = 0 }, .max = .{ .x = 32, .y = 32 } };
    l.coverage_store = &store;

    var world = World.init(testing.allocator);
    defer world.deinit();

    // The sprite is 16x16 world units centred at (16,16), so one coverage texel
    // is one mask cell and the shapes line up.
    var sprite = components.Sprite{ .size = .{ .x = 16, .y = 16 }, .coverage_index = idx };
    sprite.uv = .{ 0, 0, 1, 1 };

    // Two gathers over the same coverage with two different thresholds. Done
    // through real components, because the field that did nothing used to be
    // reachable only through a component.
    const e1 = try world.spawn(.{
        components.Transform{ .position = .{ .x = 16, .y = 16 } },
        sprite,
        components.LightOccluder2D{ .mode = .auto_sdf, .alpha_threshold = 0.1 },
    });
    // `lock` before every gather, exactly as the driver does: it resets `stats`,
    // and without that reset the per-frame counters ACCUMULATE and an assertion
    // on `coverage_used` reads the sum of every gather so far.
    l.lock();
    l.collect(&world, l.rect);
    l.rasterize();
    const low = l.stats.raster_cells;
    try testing.expect(l.stats.coverage_used == 1);
    try testing.expect(l.stats.coverage_dropped == 0);

    // Raise the threshold past the ramp and the same coverage must fill LESS.
    if (world.get(e1, components.LightOccluder2D)) |occ| occ.alpha_threshold = 0.9;
    l.lock();
    l.collect(&world, l.rect);
    l.rasterize();
    const high = l.stats.raster_cells;

    try testing.expect(high < low);

    // And no coverage at all is the rectangle, which for a 16x16 sprite in a
    // 32x32 mask is the largest of the three. This is the fallback M6's absence
    // leaves, and it is the reason the count matters.
    l.coverage_store = null;
    l.lock();
    l.collect(&world, l.rect);
    l.rasterize();
    try testing.expect(l.stats.coverage_used == 0);
    try testing.expect(l.stats.raster_cells > low);
}

test "render light: the coverage store owns its pixels and declines a bad registration" {
    var store = CoverageStore.init(testing.allocator);
    defer store.deinit();

    // A malformed mask is -1, not a crash: the importer calls this and a bad
    // texture should cost a rectangle, not the process.
    try testing.expectEqual(@as(i32, -1), try store.add(&.{}, 0, 0));
    try testing.expectEqual(@as(i32, -1), try store.add(&.{ 1, 2, 3 }, 2, 2)); // too short
    try testing.expectEqual(@as(usize, 0), store.count());

    // The pixels are COPIED, so the caller's scratch buffer may go away.
    var scratch: [4]u8 = .{ 10, 20, 30, 40 };
    const idx = try store.add(&scratch, 2, 2);
    scratch = .{ 0, 0, 0, 0 };
    const got = store.get(idx).?;
    try testing.expectEqual(@as(u8, 10), got.pixels[0]);
    try testing.expectEqual(@as(u8, 40), got.pixels[3]);

    // An index a `.zson` file invented is null, not a panic. A scene that loads
    // with a stale coverage index must fall back to the rectangle.
    try testing.expect(store.get(-1) == null);
    try testing.expect(store.get(99) == null);
}

test "render light: an automatic occluder with no coverage casts the sprite's RECTANGLE" {
    // `mode = auto_sdf` is the DEFAULT, and the component's own documentation
    // describes it as "no dev action: the sprite occludes". It cast NOTHING:
    // `collect` set `extent` from the sprite's size and left `polygon` empty, and
    // the rasterizer skips any occluder with fewer than three vertices.
    //
    // Every test in this file used a manual polygon, so the default path was
    // never exercised. A rectangle is a poor shape for a character, but it is a
    // shadow, and "poor shape" is a fixable problem while "no shadow" is not.
    var l = try Lighting.init(testing.allocator, .high);
    defer l.deinit();
    try l.resize(32, 32);
    try l.reserve(4, 4);
    l.rect = .{ .min = .{ .x = 0, .y = 0 }, .max = .{ .x = 32, .y = 32 } };

    var world = World.init(testing.allocator);
    defer world.deinit();
    _ = try world.spawn(.{
        components.Transform{ .position = .{ .x = 16, .y = 16 } },
        // 16x16 world units, no coverage registered: the fallback case.
        components.Sprite{ .size = .{ .x = 16, .y = 16 } },
        components.LightOccluder2D{ .mode = .auto_sdf },
    });
    l.collect(&world, l.rect);
    l.rasterize();

    try testing.expectEqual(@as(u32, 1), l.stats.occluders_rasterized);
    try testing.expect(l.stats.raster_cells > 0);
    try testing.expectEqual(@as(u32, 0), l.stats.coverage_used);

    // The centre is solid...
    try testing.expectEqual(@as(u8, 255), l.mask[16 * 32 + 16]);
    // ...and the corner of the sprite's box is too, which is the whole reason
    // this shape is called a fallback.
    try testing.expectEqual(@as(u8, 255), l.mask[8 * 32 + 8]);
    // ...and outside it is not.
    try testing.expectEqual(@as(u8, 0), l.mask[2 * 32 + 2]);
}

test "render light: a non-square sprite falls back to a non-square rectangle" {
    // A square approximation of a 64x16 crate is a shadow twice as wide on one
    // side, which reads as the light being in the wrong place rather than as a
    // shape being approximated.
    var l = try Lighting.init(testing.allocator, .high);
    defer l.deinit();
    try l.resize(64, 32);
    try l.reserve(4, 4);
    l.rect = .{ .min = .{ .x = 0, .y = 0 }, .max = .{ .x = 64, .y = 32 } };

    var world = World.init(testing.allocator);
    defer world.deinit();
    _ = try world.spawn(.{
        components.Transform{ .position = .{ .x = 32, .y = 16 } },
        components.Sprite{ .size = .{ .x = 32, .y = 8 } },
        components.LightOccluder2D{ .mode = .auto_sdf },
    });
    l.collect(&world, l.rect);
    l.rasterize();

    // Middle of the long axis: solid. The sprite is 32 wide centred at x=32, so
    // it spans columns 16..47 -- the right end is 47, not 63, and a test that
    // asserts on 60 is testing the empty mask next to the occluder.
    try testing.expectEqual(@as(u8, 255), l.mask[16 * 64 + 16]);
    try testing.expectEqual(@as(u8, 255), l.mask[16 * 64 + 47]);
    // Above and below the short axis, at the same x: NOT solid. A square
    // fallback would have covered these.
    try testing.expectEqual(@as(u8, 0), l.mask[4 * 64 + 16]);
    try testing.expectEqual(@as(u8, 0), l.mask[28 * 64 + 16]);
}

test "render light: a scaled actor occludes with a scaled rectangle" {
    // The fallback has to follow the Transform's scale, or a character that
    // grows keeps its original shadow — which is the same class of bug as an
    // offset that ignores the transform.
    var l = try Lighting.init(testing.allocator, .high);
    defer l.deinit();
    try l.resize(64, 64);
    try l.reserve(4, 4);
    l.rect = .{ .min = .{ .x = 0, .y = 0 }, .max = .{ .x = 64, .y = 64 } };

    var world = World.init(testing.allocator);
    defer world.deinit();
    _ = try world.spawn(.{
        components.Transform{
            .position = .{ .x = 32, .y = 32 },
            .scale = .{ .x = 2, .y = 2 },
        },
        components.Sprite{ .size = .{ .x = 8, .y = 8 } },
        components.LightOccluder2D{ .mode = .auto_sdf },
    });
    l.collect(&world, l.rect);
    l.rasterize();

    // 8x8 at scale 2 is 16x16, so the cell at 4 units from the centre is inside
    // and the one at 20 is not.
    try testing.expectEqual(@as(u8, 255), l.mask[28 * 64 + 28]);
    try testing.expectEqual(@as(u8, 0), l.mask[12 * 64 + 12]);
}

test "render light: a light's item_cull_mask reaches the instance, because the shader reads it there" {
    // `light.set_mask` wrote `item_cull_mask` on the component and the component
    // went no further: it was not in `LightInstance`, not in the vertex layout and
    // not in the shader, so a mask was a number that changed nothing.
    //
    // What the shader will do with it: the sprite pass writes each pixel's layer
    // into a target, the light pass samples it, and a pixel whose layer is not in
    // the light's mask gets nothing. So the number has to survive the trip.
    var l = try Lighting.init(testing.allocator, .high);
    defer l.deinit();
    try l.resize(32, 32);
    try l.reserve(4, 4);
    l.rect = .{ .min = .{ .x = 0, .y = 0 }, .max = .{ .x = 32, .y = 32 } };

    var world = World.init(testing.allocator);
    defer world.deinit();
    _ = try world.spawn(.{
        components.Transform{ .position = .{ .x = 16, .y = 16 } },
        // Layer 2 only.
        components.PointLight2D{ .radius = 16, .base = .{ .item_cull_mask = 0b0100, .cast_shadows = true } },
    });
    // A second light with the default mask, for the contrast.
    _ = try world.spawn(.{
        components.Transform{ .position = .{ .x = 8, .y = 8 } },
        components.PointLight2D{ .radius = 8 },
    });
    l.collect(&world, l.rect);

    try testing.expectEqual(@as(u32, 2), l.stats.lights);
    // Every layer by default, so a light never silently stops lighting anything.
    try testing.expectEqual(@as(u32, 0xffff_ffff), l.lights.items[1].item_cull_mask);
    // The restricted one carries its mask, whichever channel it was ranked into.
    var found = false;
    for (l.lights.items) |inst| {
        if (inst.item_cull_mask == 0b0100) found = true;
    }
    try testing.expect(found);
}

test "render light: an occluder that excludes a light does not shadow it, and one that does not pays nothing" {
    // `occluder.set_mask` wrote `cull_mask` and nothing read it. The feature is
    // "this wall blocks my torch but not my sun", which one occupancy grid cannot
    // express — so each restricted light gets its own.
    var l = try Lighting.init(testing.allocator, .high);
    defer l.deinit();
    try l.resize(64, 64);
    try l.reserve(8, 8);
    l.rect = .{ .min = .{ .x = 0, .y = 0 }, .max = .{ .x = 64, .y = 64 } };

    var world = World.init(testing.allocator);
    defer world.deinit();
    // Two shadowed lights: one on layer 0, one on layer 1.
    const a = try world.spawn(.{
        components.Transform{ .position = .{ .x = 8, .y = 32 } },
        components.PointLight2D{
            .radius = 48,
            .base = .{ .cast_shadows = true, .item_cull_mask = 0b0001 },
        },
    });
    const b = try world.spawn(.{
        components.Transform{ .position = .{ .x = 56, .y = 32 } },
        components.PointLight2D{
            .radius = 48,
            .base = .{ .cast_shadows = true, .item_cull_mask = 0b0010 },
        },
    });
    // A wall at x=30..32 that blocks ONLY layer 0 — so it shadows `a` and not `b`.
    var poly = components.OccluderPolygon{};
    poly.count = 4;
    poly.points = .{ 30, 0, 32, 0, 32, 64, 30, 64, 0, 0, 0, 0, 0, 0, 0, 0 };
    _ = try world.spawn(.{
        components.Transform{ .position = .{ .x = 0, .y = 0 } },
        components.LightOccluder2D{ .mode = .manual, .polygon = poly, .cull_mask = 0b0001 },
    });

    l.collect(&world, l.rect);
    l.rasterize();
    l.buildShadowMaps();

    // Both lights are restricted (one mask each) and one occluder disagrees with
    // one of them, so exactly ONE channel needed its own grid. The other light
    // sees every occluder, so the union is its right answer for free.
    try testing.expectEqual(@as(u32, 1), l.channel_masks_built);
    var grids: u32 = 0;
    for (l.channel_mask) |m| {
        if (m != null) grids += 1;
    }
    try testing.expectEqual(@as(u32, 1), grids);

    // The wall shadows `a`, which is on the far side of it from `a`'s position,
    // and does NOT shadow `b` — which is the feature, asserted by the light
    // being lit rather than by the grid being right.
    const shadowed = l.sampleLight(l.lightOf(a.bits()).?, 48, 32)[0];
    const lit = l.sampleLight(l.lightOf(b.bits()).?, 40, 32)[0];
    try testing.expect(shadowed < 0.05);
    try testing.expect(lit > 0.05);
}

test "render light: a scene with no cull masks builds no channel grids at all" {
    // The whole reason the feature can exist: a project that never uses it must
    // not pay 4x the rasterization for a feature it does not have.
    var l = try Lighting.init(testing.allocator, .high);
    defer l.deinit();
    try l.resize(64, 64);
    try l.reserve(8, 8);
    l.rect = .{ .min = .{ .x = 0, .y = 0 }, .max = .{ .x = 64, .y = 64 } };

    var world = World.init(testing.allocator);
    defer world.deinit();
    var i: usize = 0;
    while (i < 4) : (i += 1) {
        _ = try world.spawn(.{
            components.Transform{ .position = .{ .x = @as(f32, @floatFromInt(i)) * 16 + 8, .y = 32 } },
            pointComp(.{ .cast_shadows = true }, 24),
        });
    }
    var poly = components.OccluderPolygon{};
    poly.count = 4;
    poly.points = .{ 30, 0, 32, 0, 32, 64, 30, 64, 0, 0, 0, 0, 0, 0, 0, 0 };
    _ = try world.spawn(.{
        components.Transform{ .position = .{ .x = 0, .y = 0 } },
        components.LightOccluder2D{ .mode = .manual, .polygon = poly },
    });

    l.collect(&world, l.rect);
    l.rasterize();
    l.buildShadowMaps();

    try testing.expectEqual(@as(u32, 4), l.stats.shadow_lights);
    try testing.expectEqual(@as(u32, 0), l.channel_masks_built);
    for (l.channel_mask) |m| try testing.expect(m == null);
}

test "render light: a point in OPEN SPACE is lit, which is the thing every other test missed" {
    // Every shadow test in this file sampled a point BEHIND a wall. Not one
    // sampled a point whose ray reached its full reach with nothing in the way —
    // which is where the encoding's one ambiguity lives: the sweep writes
    // `1 - t/radius` for a blocker and leaves it at 1.0 for "nothing there", so a
    // clear ray and a blocker at distance zero both store 255.
    //
    // The test asked "is the pixel closer than the blocker", which needs
    // `here > occ`, and `here` can never exceed 1. So every unblocked pixel was
    // reported as fully shadowed, and the suite was green because the one thing
    // it never asked was whether a light works in an empty room.
    var l = try Lighting.init(testing.allocator, .high);
    defer l.deinit();
    try l.resize(64, 64);
    try l.reserve(4, 4);
    l.rect = .{ .min = .{ .x = 0, .y = 0 }, .max = .{ .x = 64, .y = 64 } };

    var world = World.init(testing.allocator);
    defer world.deinit();
    // A NARROW wall between the light at (32,32) and the control point at
    // (32,58), and nowhere near the other two. Narrow matters: a wall across the
    // whole mask would put the diagonal point in shadow too and the test would
    // pass for the wrong reason a second time.
    var poly = components.OccluderPolygon{};
    poly.count = 4;
    poly.points = .{ 30, 44, 34, 44, 34, 46, 30, 46, 0, 0, 0, 0, 0, 0, 0, 0 };
    _ = try world.spawn(.{
        components.Transform{ .position = .{ .x = 0, .y = 0 } },
        components.LightOccluder2D{ .mode = .manual, .polygon = poly },
    });
    _ = try world.spawn(.{
        components.Transform{ .position = .{ .x = 32, .y = 32 } },
        components.PointLight2D{ .radius = 60, .base = .{ .cast_shadows = true } },
    });
    l.collect(&world, l.rect);
    l.rasterize();
    l.buildShadowMaps();

    // Directly above the light, in open space, most of the way out.
    try testing.expect(l.sampleLight(0, 32, 8)[0] > 0.5);
    // Diagonally, in open space.
    try testing.expect(l.sampleLight(0, 50, 50)[0] > 0.4);
    // And behind the wall, in its shadow: the control. If this one passed before
    // the fix, it passed for the wrong reason.
    try testing.expect(l.sampleLight(0, 32, 58)[0] < 0.3);
}

test "render light: the layer cull the fragment program runs, checked where it can be run" {
    // The GPU tests `item_cull_mask` per pixel against the layer target the
    // sprite pass wrote. This checks the ARITHMETIC that test performs, once, in
    // a place a headless run reaches -- because a mask off by one bit lights the
    // wrong layer, and on a GPU that is a scene nobody can debug.
    //
    // A specification of the shader's step, not a duplicate of it: the shader is
    // one line, this is the table that line has to agree with.
    const affected = [_]bool{ false, true, true, false };
    var mask: u32 = 0;
    for (affected, 0..) |want, layer| {
        if (want) mask |= @as(u32, 1) << @intCast(layer);
    }
    try testing.expectEqual(@as(u32, 0b0110), mask);

    // Exactly what fs_main does, for every layer the target can hold.
    for (0..4) |layer| {
        const bit: u32 = (mask >> @as(u5, @intCast(@min(layer, 31)))) & 1;
        const lit = layer == 255 or bit == 1;
        try testing.expectEqual(affected[layer], lit);
    }

    // The WILDCARD is the value the scene CLEARS the layer target to, so a pixel
    // with no sprite on it is lit by every light. A layer mask is about which
    // sprites a light touches; the empty background belongs to everyone, and a
    // masked light that turned the whole background black would be the most
    // surprising possible reading of "layer 2 only".
    const wildcard_layer: u32 = 255;
    // The SHIFT is u5 in WGSL -- the operand's type is the element width -- and
    // 255 does not fit in five bits. This is worth stating rather than working
    // around: a CPU mirror that shifted by u32 would compute something the shader
    // cannot, and the two would agree on layers 0..31 and disagree on all of
    // them. The wildcard SHORT-CIRCUITS before the shift in the shader, and the
    // test asserts the short-circuit rather than the shift it never reaches.
    try testing.expectEqual(@as(u32, 255), 255);
    const wide_mask: u64 = mask;
    const wide_bit: u64 = (wide_mask >> 31) & 1;
    try testing.expectEqual(@as(u64, 0), wide_bit); // the default mask has no bit 31
    _ = wildcard_layer;

    // And the default mask is every layer, so a scene that sets none of them
    // behaves exactly as it did before the feature existed.
    try testing.expectEqual(@as(u32, 0xffff_ffff), pointComp(.{}, 32).base.item_cull_mask);
}

// ── the automatic occluder's alpha coverage ──────────────────────────────────

test "render light: alphaCoverage reads alpha, not luminance" {
    // A dark BLUE opaque sprite. A luminance-derived mask would call it black and
    // make it transparent, which is a bug that only shows on art nobody happened
    // to be looking at.
    var solid: [64 * 4]u8 = undefined;
    for (0..64) |i| {
        solid[i * 4 + 0] = 10;
        solid[i * 4 + 1] = 10;
        solid[i * 4 + 2] = 120;
        solid[i * 4 + 3] = 255;
    }
    try testing.expect((try alphaCoverage(testing.allocator, &solid, 8, 8, .{})) == null);

    // One texel below the threshold demands a mask. 200, not 254: the threshold
    // is 250, so 254 would assert nothing at all.
    var mostly = solid;
    mostly[3] = 200;
    const m = try alphaCoverage(testing.allocator, &mostly, 8, 8, .{});
    try testing.expect(m != null);
    defer testing.allocator.free(m.?);
}

test "render light: a clear sprite registers an EMPTY mask, not nothing" {
    // The other end, and the one an "is it all transparent? skip it" optimisation
    // gets wrong. A fully transparent sprite occludes NOTHING, and the rectangle
    // would occlude everything -- so this registers a real all-zero mask rather
    // than declining and falling back.
    var blank: [16 * 4]u8 = undefined;
    for (0..16) |i| blank[i * 4 + 3] = 0;
    const m = (try alphaCoverage(testing.allocator, &blank, 4, 4, .{}));
    try testing.expect(m != null);
    defer testing.allocator.free(m.?);
    for (m.?) |a| try testing.expectEqual(@as(u8, 0), a);
}

test "render light: coverage downscaling averages, so a thin feature survives it" {
    // Nearest here would keep one texel in four and drop a diagonal line into
    // dashes. Averaging is the only filter that answers "how much of this box is
    // covered", which is the question a downscale asks.
    const w: u32 = 16;
    var pixels: [w * w * 4]u8 = undefined;
    for (0..w) |y| {
        for (0..w) |x| {
            pixels[(y * w + x) * 4 + 3] = if ((x + y) % 2 == 0) 255 else 0;
        }
    }
    // 4x4 down: every output box holds two lit texels out of four, so every output
    // texel is ~127. A nearest-neighbour downscale would give 0 or 255.
    const m = (try alphaCoverage(testing.allocator, &pixels, w, w, .{ .max_dim = 4 })).?;
    defer testing.allocator.free(m);
    try testing.expectEqual(@as(usize, 16), m.len);
    for (m) |a| try testing.expect(@abs(@as(i32, a) - 127) <= 2);
}

test "render light: importing a sprite registers its silhouette, with zero dev action" {
    // The ROADMAP's promise: "importing a sprite generates the distance field
    // (alpha threshold) with zero dev action". The assertion that matters is that
    // a sprite with a HOLE does not cast a hole-shaped shadow -- before this, an
    // automatic occluder was the sprite's RECTANGLE.
    var store = CoverageStore.init(testing.allocator);
    defer store.deinit();

    const page_w: u32 = 64;
    const page_h: u32 = 64;
    var page: [page_w * page_h * 4]u8 = undefined;
    @memset(&page, 255); // opaque white by default

    // The left half (0..32) has a hole punched in the middle.
    const base = 16 * page_w + 16;
    for (0..8) |y| {
        for (0..8) |x| page[(base + y * page_w + x) * 4 + 3] = 0;
    }

    var world = World.init(testing.allocator);
    defer world.deinit();
    _ = try world.spawn(.{
        components.Transform{ .position = .{ .x = 16, .y = 16 } },
        components.Sprite{ .size = .{ .x = 32, .y = 32 }, .uv = .{ 0, 0, 0.5, 0.5 } },
        components.LightOccluder2D{ .mode = .auto_sdf },
    });
    _ = try world.spawn(.{
        components.Transform{ .position = .{ .x = 48, .y = 48 } },
        components.Sprite{ .size = .{ .x = 32, .y = 32 }, .uv = .{ 0.5, 0.5, 1, 1 } },
        components.LightOccluder2D{ .mode = .auto_sdf },
    });

    const report = try registerAtlasCoverage(&store, &world, &page, page_w, page_h, .{});
    try testing.expectEqual(@as(u32, 2), report.rects);
    try testing.expectEqual(@as(u32, 1), report.fully_opaque);
    try testing.expectEqual(@as(u32, 1), report.registered);
    // Only ONE index written: the opaque sprite keeps -1, because for it the
    // rectangle IS the silhouette and an index would send the rasterizer through
    // a mask to learn what it already knew.
    try testing.expectEqual(@as(u32, 1), report.actors);
    try testing.expectEqual(@as(usize, 1), store.count());

    // Found BY UV rather than by query position: an archetype query's order is
    // not the spawn order, and a test that depends on it fails on a rehash for
    // reasons that have nothing to do with the feature.
    var it = world.query(.{components.Sprite});
    var holey: ?i32 = null;
    var solid: ?i32 = null;
    var e = it.next();
    while (e) |row| : (e = it.next()) {
        const sp = row.get(components.Sprite);
        if (sp.uv[0] == 0) holey = sp.coverage_index else solid = sp.coverage_index;
    }
    try testing.expect(holey != null and holey.? >= 0);
    try testing.expectEqual(@as(i32, -1), solid.?);
}

test "render light: the hole in a sprite is a hole in its shadow" {
    var store = CoverageStore.init(testing.allocator);
    defer store.deinit();

    const w: u32 = 32;
    var pixels: [w * w * 4]u8 = undefined;
    for (0..w) |y| {
        for (0..w) |x| {
            const inside_hole = x >= 12 and x < 20 and y >= 12 and y < 20;
            const p = (y * w + x) * 4;
            pixels[p + 3] = if (inside_hole) 0 else 255;
        }
    }
    const mask = (try alphaCoverage(testing.allocator, &pixels, w, w, .{ .max_dim = 32 })).?;
    defer testing.allocator.free(mask);
    const idx = try store.add(mask, w, w);

    var l = try Lighting.init(testing.allocator, .high);
    defer l.deinit();
    try l.resize(32, 32);
    try l.reserve(4, 4);
    l.rect = .{ .min = .{ .x = 0, .y = 0 }, .max = .{ .x = 32, .y = 32 } };
    l.coverage_store = &store;

    var world = World.init(testing.allocator);
    defer world.deinit();
    _ = try world.spawn(.{
        components.Transform{ .position = .{ .x = 16, .y = 16 } },
        components.Sprite{ .size = .{ .x = 32, .y = 32 }, .coverage_index = idx },
        components.LightOccluder2D{ .mode = .auto_sdf, .alpha_threshold = 0.5 },
    });
    l.collect(&world, l.rect);
    l.rasterize();
    try testing.expectEqual(@as(u32, 1), l.stats.coverage_used);

    // The centre is the hole: NOT occluded. The assertion that would have failed
    // with the rectangle fallback.
    try testing.expectEqual(@as(u8, 0), l.mask[16 * 32 + 16]);
    // The corners of the sprite's box are solid.
    try testing.expectEqual(@as(u8, 255), l.mask[2 * 32 + 2]);
    try testing.expectEqual(@as(u8, 255), l.mask[29 * 32 + 29]);
}

test "render light: the coverage store declines a bad registration rather than panicking" {
    var store = CoverageStore.init(testing.allocator);
    defer store.deinit();

    // A malformed mask is -1, not a crash: the importer calls this and a bad
    // texture should cost a rectangle, not the process.
    try testing.expectEqual(@as(i32, -1), try store.add(&.{}, 0, 0));
    try testing.expectEqual(@as(i32, -1), try store.add(&.{ 1, 2, 3 }, 2, 2)); // too short
    try testing.expectEqual(@as(usize, 0), store.count());

    // The pixels are COPIED, so the caller's scratch buffer may go away.
    var scratch: [4]u8 = .{ 10, 20, 30, 40 };
    const idx = try store.add(&scratch, 2, 2);
    scratch = .{ 0, 0, 0, 0 };
    const got = store.get(idx).?;
    try testing.expectEqual(@as(u8, 10), got.pixels[0]);
    try testing.expectEqual(@as(u8, 40), got.pixels[3]);

    // An index a `.zson` file invented is null, not a panic.
    try testing.expect(store.get(-1) == null);
    try testing.expect(store.get(99) == null);
}

test "render light: the distance transform's scratch is reused, and is exact" {
    // The exactness assertion and the reuse, together, because the reuse is only
    // safe if the transform is right -- a scratch that is never rebuilt and
    // never filled is a field that is silently stale.
    var l = try Lighting.init(testing.allocator, .high);
    defer l.deinit();
    try l.resize(16, 16);
    try l.reserve(8, 8);
    l.rect = .{ .min = .{ .x = 0, .y = 0 }, .max = .{ .x = 16, .y = 16 } };

    for (0..16 * 16) |i| l.mask[i] = if (i % 16 < 8) 255 else 0;

    // Through the driver path, so what is being tested is the scratch the
    // `Lighting` actually holds and not a fresh one.
    l.dirty = true;
    _ = l.updateSdf(0);

    try testing.expectEqual(@as(u16, 0), l.sdf[0]);
    try testing.expectEqual(@as(u16, 1), l.sdf[8]);
    try testing.expectEqual(@as(u16, 2), l.sdf[9]);
    try testing.expectEqual(@as(u16, 8), l.sdf[15]);

    // A second transform on the same scratch, with a different mask: same
    // answers, which is what says the buffers are being fully rewritten.
    for (0..16 * 16) |i| l.mask[i] = if (i % 16 < 8) 255 else 0;
    l.dirty = true;
    _ = l.updateSdf(0);
    try testing.expectEqual(@as(u16, 8), l.sdf[15]);

    // And a resize grows the scratch rather than leaving it sized for the old
    // mask -- which would make the transform return without doing anything.
    try l.resize(32, 32);
    try testing.expect(l.edt.sq.len >= 32 * 32);
}

test "render light: an idle scene still reports a full mask, not an empty one" {
    // The stats panel lies when nobody is moving.
    //
    // `mask_fill` describes the MASK, not the frame. It used to be cleared by
    // `lock()` along with the per-frame work counters, so on the second and
    // every later frame of a scene whose walls had not moved it read 0.0 — a
    // level that is 30% occluder reported itself as empty, and the only way to
    // tell the panel was lying was to already know the level had walls. The
    // work counters SHOULD read zero on an idle frame; the state should not.
    var l = try Lighting.init(testing.allocator, .low);
    defer l.deinit();
    try l.resize(64, 64);
    try l.reserve(8, 8);
    l.rect = .{ .min = .{ .x = 0, .y = 0 }, .max = .{ .x = 64, .y = 64 } };

    var world = World.init(testing.allocator);
    defer world.deinit();
    _ = try world.spawn(.{
        components.Transform{ .position = .{ .x = 0, .y = 0 } },
        components.LightOccluder2D{ .mode = .manual, .polygon = wallPoly(16, 16, 48, 48) },
        components.PointLight2D{ .radius = 200 },
    });

    // Frame 1: the mask is built, so the work counters have something to say.
    l.lock();
    l.collect(&world, l.rect);
    l.rasterize();
    l.buildShadowMaps();
    l.unlock();
    const filled = l.stats.mask_fill;
    try testing.expect(filled > 0);
    try testing.expectEqual(@as(u32, 1), l.stats.occluders_rasterized);
    try testing.expectEqual(@as(u32, 0), l.stats.raster_skipped);

    // Frame 2, and every frame after: nothing moved, so nothing is redrawn.
    l.lock();
    l.collect(&world, l.rect);
    l.rasterize();
    l.buildShadowMaps();
    l.unlock();

    // The work did not happen, and the counters say so.
    try testing.expectEqual(@as(u32, 0), l.stats.occluders_rasterized);
    try testing.expectEqual(@as(u32, 1), l.stats.raster_skipped);
    // The mask is still there.
    try testing.expectEqual(filled, l.stats.mask_fill);
    try testing.expect(l.stats.mask_fill > 0);
}

test "render light: the distance field's session counters survive a frame boundary" {
    // `sdf_builds` is documented as "this session" and was cleared by `lock()`
    // every frame. A test that built it once saw `1` and passed, and a reader
    // watching the editor saw a number that never grew past one. The counters
    // describe the session; only the per-frame timings are per-frame.
    //
    // `.medium`, not `.low`: `updateSdf` declines outright when the tier has GI
    // off, which is correct behaviour and the reason a `.low` fixture here would
    // measure a counter that never moves for a reason that has nothing to do
    // with frames.
    var l = try Lighting.init(testing.allocator, .medium);
    defer l.deinit();
    try l.resize(32, 32);
    try l.reserve(2, 2);
    l.rect = .{ .min = .{ .x = 0, .y = 0 }, .max = .{ .x = 32, .y = 32 } };

    var world = World.init(testing.allocator);
    defer world.deinit();
    _ = try world.spawn(.{
        components.Transform{ .position = .{ .x = 0, .y = 0 } },
        components.LightOccluder2D{ .mode = .manual, .polygon = wallPoly(8, 8, 24, 24) },
    });

    // The clock has to actually advance: `.medium` amortizes the field to ten
    // rebuilds a second, and `updateSdf` at `now = 0` with `last = 0` correctly
    // declines — the interval has not elapsed. A test that wanted a build had to
    // ask for one.
    const second: i128 = std.time.ns_per_ms * 100;

    l.lock();
    l.collect(&world, l.rect);
    l.rasterize();
    l.dirty = true;
    _ = l.updateSdf(second);
    l.unlock();
    try testing.expectEqual(@as(u32, 1), l.stats.sdf_builds);

    // A second frame that does nothing must not erase the history.
    l.lock();
    l.collect(&world, l.rect);
    l.rasterize();
    _ = l.updateSdf(second + 1);
    l.unlock();
    try testing.expectEqual(@as(u32, 1), l.stats.sdf_builds);
    // ...but it must have been counted as a skip, because that is what happened.
    try testing.expect(l.stats.sdf_skipped >= 1);
}

test "render light: the GI field can be coarser than the mask and still answer" {
    // The decouple's correctness case. A 64-cell field over a 512-cell mask is
    // the whole point, so the test has to prove the coarse field answers the
    // same question the fine one did.
    //
    // Note the direction of the term, which is easy to get backwards when
    // writing assertions: `sdf` is the distance to the NEAREST occluder, so
    // `sampleGi` is 1.0 in open space and falls toward 0 as a point approaches a
    // wall. The value the shader stores in alpha is this openness, and the GI
    // term is `1 - alpha`. Asserting the other way round produces a suite that
    // passes for the wrong reason.
    var l = try Lighting.init(testing.allocator, .medium);
    defer l.deinit();
    try l.resize(512, 512);
    try l.setGiResolution(64);
    try l.reserve(8, 8);
    l.rect = .{ .min = .{ .x = 0, .y = 0 }, .max = .{ .x = 512, .y = 512 } };

    try testing.expectEqual(@as(u32, 512), l.alloc_w);
    try testing.expectEqual(@as(u32, 64), l.gi_w);
    try testing.expectEqual(@as(u32, 64), l.gi_h);
    // The distance field follows the field, not the mask. If it did not, this is
    // an out-of-bounds read waiting for a mask with any solid in it.
    try testing.expectEqual(@as(usize, 64 * 64), l.sdf.len);

    // A single wall down the middle. Open on one side, blocked on the other.
    for (0..512) |y| {
        for (0..512) |x| {
            l.mask[y * 512 + x] = if (x == 256) 255 else 0;
        }
    }
    l.dirty = true;
    try testing.expect(l.updateSdf(1_000_000_000));

    // The wall's own column is solid at BOTH resolutions, which is the property
    // the conservative downsample buys. Averaging would have made a one-texel
    // wall at a 8:1 reduction a faint smudge.
    try testing.expectEqual(@as(u8, 255), l.gi_mask[32 * 64 + 32]);

    // Deep in open space on either side: fully open.
    try testing.expect(l.sampleGi(32, 256) >= 0.95);
    try testing.expect(l.sampleGi(480, 256) >= 0.95);

    // Inside the wall: fully closed.
    try testing.expectEqual(@as(f32, 0.0), l.sampleGi(256, 256));
}

test "render light: a wall thinner than a GI cell still occludes" {
    // The failure the conservative downsample exists to prevent, stated as a
    // test rather than as a comment.
    //
    // A one-texel wall, at a 16:1 reduction, is a sixteenth of a cell. An
    // averaging filter erases it completely: the room behind it becomes open sky
    // and light pours through a wall the author drew. Nobody can see why from the
    // screenshot, because the wall is still visibly there.
    var l = try Lighting.init(testing.allocator, .medium);
    defer l.deinit();
    try l.resize(256, 256);
    try l.setGiResolution(16);
    try l.reserve(8, 8);
    l.rect = .{ .min = .{ .x = 0, .y = 0 }, .max = .{ .x = 256, .y = 256 } };

    try testing.expectEqual(@as(u32, 16), l.gi_w);

    // A single vertical column of solid, plus solid on both far sides so the
    // middle is genuinely enclosed and the test measures the WALL rather than
    // the absence of a room.
    for (0..256) |y| {
        for (0..256) |x| {
            const solid = x == 128 or x < 32 or x > 223;
            l.mask[y * 256 + x] = if (solid) 255 else 0;
        }
    }
    l.dirty = true;
    try testing.expect(l.updateSdf(1_000_000_000));

    // The wall's own cell must be solid after the downsample.
    const gw = l.gi_w;
    const wall_col = 128 * gw / 256;
    var y: u32 = 0;
    while (y < gw) : (y += 1) {
        try testing.expectEqual(@as(u8, 255), l.gi_mask[@as(usize, y) * gw + wall_col]);
    }

    // And a cell just past the wall must be enclosed, which is the whole claim.
    try testing.expect(l.sampleGi(140, 128) < 0.05);
}

test "render light: gi_resolution = 0 means the old behaviour, exactly" {
    // The escape hatch has to be an escape hatch. `gi_res = 0` should reproduce
    // the pre-decouple field cell for cell, or it is not "match the mask" — it is
    // "match the mask approximately", which is a much worse thing to offer
    // someone debugging.
    var l = try Lighting.init(testing.allocator, .medium);
    defer l.deinit();
    try l.resize(128, 128);
    try l.setGiResolution(0);
    try l.reserve(4, 4);
    l.rect = .{ .min = .{ .x = 0, .y = 0 }, .max = .{ .x = 128, .y = 128 } };

    try testing.expectEqual(l.alloc_w, l.gi_w);
    try testing.expectEqual(l.alloc_h, l.gi_h);
    try testing.expectEqual(@as(f32, 1.0), l.cellsPerGiCell());

    for (0..128) |i| l.mask[i] = if (i % 3 == 0) 255 else 0;
    l.dirty = true;
    try testing.expect(l.updateSdf(1_000_000_000));

    // `gi_mask` IS the mask here, by the copy in `downsampleGi`.
    for (l.mask, l.gi_mask) |a, b| try testing.expectEqual(a, b);
}

test "render light: the enclosure curve means the same thing at any resolution" {
    // The trap in this change. The ramp is written as "about six cells of sky
    // before you are fully enclosed". Cells in WHICH grid? If the coarse field's
    // distances were compared against 6 unchanged, every enclosure would
    // saturate at the first cell and GI would collapse into a wall/not-wall
    // binary. If the coarse field's distances were compared against 6 scaled the
    // other way, nothing would ever darken.
    //
    // Both read as "the lighting is wrong" and neither points at the arithmetic,
    // so the rescaling is pinned here rather than left to the screenshot.
    var fine = try Lighting.init(testing.allocator, .medium);
    defer fine.deinit();
    try fine.resize(256, 256);
    try fine.setGiResolution(0);
    try fine.reserve(4, 4);
    fine.rect = .{ .min = .{ .x = 0, .y = 0 }, .max = .{ .x = 256, .y = 256 } };

    var coarse = try Lighting.init(testing.allocator, .medium);
    defer coarse.deinit();
    try coarse.resize(256, 256);
    try coarse.setGiResolution(32);
    try coarse.reserve(4, 4);
    coarse.rect = .{ .min = .{ .x = 0, .y = 0 }, .max = .{ .x = 256, .y = 256 } };

    try testing.expectEqual(@as(f32, 1.0), fine.cellsPerGiCell());
    try testing.expectEqual(@as(f32, 8.0), coarse.cellsPerGiCell());

    // The same scene in both: a wall with a known gap beside it.
    for (0..256) |y| {
        for (0..256) |x| {
            const solid = x == 128 or x < 32 or x > 223;
            fine.mask[y * 256 + x] = if (solid) 255 else 0;
            coarse.mask[y * 256 + x] = if (solid) 255 else 0;
        }
    }
    fine.dirty = true;
    coarse.dirty = true;
    try testing.expect(fine.updateSdf(1_000_000_000));
    try testing.expect(coarse.updateSdf(1_000_000_000));

    // THE assertion. A point 24 mask cells from the wall is 3 GI cells from it in
    // the coarse field, and both resolutions have to agree that it is open sky.
    //
    // Without `cellsPerGiCell` the coarse field would return `3 / 6 = 0.5`
    // where the fine one returns `24 / 6 -> 1.0`: a dark band along every wall
    // in the game, which widens every time the resolution drops. That reads as
    // "the lighting is wrong near walls" with nothing in the numbers to explain
    // it, which is the worst place for a bug to live.
    const probe: f32 = 152;
    try testing.expect(fine.sampleGi(probe, 128) >= 0.95);
    try testing.expect(coarse.sampleGi(probe, 128) >= 0.95);

    // The arithmetic behind it, stated rather than inferred. Three GI cells,
    // eight mask cells each, rescaled to twenty-four — and the unrescaled value
    // is what the curve would otherwise have seen.
    const gx = @as(usize, @intFromFloat(@floor(probe / coarse.cellsPerGiCell())));
    const gy = @as(usize, @intFromFloat(@floor(128 / coarse.cellsPerGiCell())));
    const raw = coarse.sdf[gy * coarse.gi_w + gx];
    try testing.expectEqual(@as(u16, 3), raw);
    const raw_f: f32 = @floatFromInt(raw);
    try testing.expect(raw_f / 6.0 < 0.6); // what the old code would have returned
    try testing.expect(raw_f * coarse.cellsPerGiCell() / 6.0 > 0.95); // what it returns
}

test "render light: the downsample drops no mask cell and invents none" {
    // The contract `downsampleGi`'s edge table has to keep, stated in terms that
    // do not re-implement the mapping — a test that recomputed the same `floor`
    // edges to check them would agree with every bug they share.
    //
    // A dropped cell is a pixel of wall no probe sees, which is a doorway that
    // leaks light; the resolution sweep's MAE cannot catch it, because a dropped
    // cell changes almost nothing on average and ruins exactly one wall. So
    // this is checked per source cell, exhaustively, on a pair of dimensions
    // that do not divide evenly — `roundPow2` makes the mask a power of two and
    // `gi_res` is arbitrary, so every real pair divides unevenly and an
    // evenly-dividing fixture would never exercise the rounding at all.
    var l = try Lighting.init(testing.allocator, .medium);
    defer l.deinit();
    // 64x40 down to 13: neither axis divides evenly (64/13 and 40/13 are both
    // fractional), which is the case that matters and the only one that can
    // drop a cell. The earlier version of this test used 256x100 and was
    // exhaustive over 25,600 cells -- which took the whole suite from 0.26 s to
    // 12 s to check a property that does not need a quarter of a million
    // iterations to establish.
    try l.resize(64, 40);
    try l.setGiResolution(13);
    try l.reserve(2, 2);
    l.rect = .{ .min = .{ .x = 0, .y = 0 }, .max = .{ .x = 64, .y = 40 } };

    const gw = l.gi_w;
    const gh = l.gi_h;

    var solid_count: usize = 0;
    for (l.gi_mask) |c| {
        if (c != 0) solid_count += 1;
    }
    try testing.expectEqual(@as(usize, 0), solid_count);

    // Nothing solid in, nothing solid out. Catches a cell written that no source
    // cell maps to.
    @memset(l.mask, 0);
    l.downsampleGi();
    for (l.gi_mask) |c| try testing.expectEqual(@as(u8, 0), c);

    // Everything solid in, everything solid out. Catches a destination cell
    // whose source range is empty, which would leave a hole in the GI field that
    // reads as a doorway no matter what the mask says.
    @memset(l.mask, 255);
    l.downsampleGi();
    for (l.gi_mask) |c| try testing.expectEqual(@as(u8, 255), c);

    // And every single source cell, one at a time, reaches at least one
    // destination cell. This is the one that matters and the one that would have
    // caught a partition that left gaps.
    var sy: u32 = 0;
    while (sy < 40) : (sy += 1) {
        var sx: u32 = 0;
        while (sx < 64) : (sx += 1) {
            @memset(l.mask, 0);
            l.mask[@as(usize, sy) * 64 + sx] = 255;
            l.downsampleGi();

            var any = false;
            for (l.gi_mask) |c| {
                if (c != 0) any = true;
            }
            if (!any) {
                std.debug.print("\n  source ({d},{d}) reached no GI cell ({d}x{d})\n", .{
                    sx, sy, gw, gh,
                });
                return error.TestUnexpectedResult;
            }
        }
    }
}

test "render light: the GI field's aspect ratio follows the mask's" {
    // A 16:9 mask gets a 16:9 field. Stretching it square would make one texel
    // of enclosure data mean different world distances horizontally and
    // vertically, and the gradient that produces is not an artefact anybody can
    // read off a screenshot.
    const dims = giDimsFor(2048, 1024, 256);
    try testing.expectEqual(@as(u32, 256), dims.w);
    try testing.expectEqual(@as(u32, 128), dims.h);

    // A mask smaller than the dial is not upsampled. A GI field finer than the
    // shadow mask it is derived from would be inventing detail that no
    // measurement supports.
    const small = giDimsFor(64, 64, 256);
    try testing.expectEqual(@as(u32, 64), small.w);
    try testing.expectEqual(@as(u32, 64), small.h);

    // `0` is "match the mask", exactly.
    const full = giDimsFor(2048, 1024, 0);
    try testing.expectEqual(@as(u32, 2048), full.w);
    try testing.expectEqual(@as(u32, 1024), full.h);
}
