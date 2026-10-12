//! M7: the lighting driver — the piece that makes lights actually appear.
//!
//! # Why this file exists
//!
//! `light.zig` has always been able to gather lights, sweep shadow maps and
//! build a GI field, and `2d.zig` has always been able to submit them. Nothing
//! owned both: the runtime never constructed a `Lighting`, never called
//! `collect`, and never called `submitLights`. A scene with a PointLight2D in it
//! rendered exactly as bright as a scene without one, and every individual
//! component of the system was green.
//!
//! That is the failure mode this file exists to prevent, not to fix: a system
//! whose parts are each correct and which is never assembled is a system that
//! does nothing, and no unit test of the parts can say so.
//!
//! # The order, and why it is this order
//!
//! ```
//!   reserve -> collect -> rasterize -> updateSdf -> buildShadowMaps -> submit
//! ```
//!
//! Every step is an input to a later one, and the two that allocate
//! (`reserve`, `resize`) are first, because spec §3.1 forbids allocating once a
//! frame has started. `collect` before `rasterize` because the occluder set is
//! what the mask is made of; `updateSdf` after `rasterize` because the distance
//! field is the mask's transform and there is nothing to transform until the
//! mask exists; `buildShadowMaps` last because it needs both the mask and the
//! light channels `collect` granted.
//!
//! # What is amortized and what is not
//!
//! `updateSdf` rebuilds the distance field on its own cadence and the GI pyramid
//! only when the field changed, so `giDirty` is usually false and the upload is
//! usually skipped. The shadow maps sweep per channel and skip any channel whose
//! light has not moved and whose mask has not changed. Both are measured in
//! `Stats`, and `bench-light` reports them rather than asserting them.

const std = @import("std");
const light_mod = @import("light.zig");
const render_mod = @import("render.zig");
const two_d = @import("2d.zig");
const atlas_bridge = @import("atlas_bridge.zig");
const Renderer2D = two_d.Renderer2D;
const ecs = @import("ecs");
const core = @import("core");
const core_math = core.math;

/// The clock the lighting system times itself against.
///
/// The system takes a plain function pointer rather than calling a clock it does
/// not own, so a test can pass null and get zeros instead of paying for
/// `clock_gettime` to measure nothing. The DRIVER is the thing that knows this is
/// a real frame loop, so it installs the real clock here: without it
/// `stats.collect_ns` and `stats.sweep_ns` are zero in the runtime and in every
/// benchmark that goes through the driver, which is a measurement of nothing
/// wearing a number. `Lighting` used directly (the unit tests, the raw
/// `measure` benchmark) still overrides it themselves.
fn driverNow() u64 {
    return core.time.monotonicNs();
}

const Lighting = light_mod.Lighting;
const Radiance = light_mod.Radiance;
const MaskRect = light_mod.MaskRect;

/// How far the mask reaches beyond the viewport, in world units. See
/// `Driver.viewFor` for why it is not zero.
const mask_margin: f32 = 64;

pub const Driver = struct {
    allocator: std.mem.Allocator,
    lighting: Lighting,
    /// The world-space rectangle the mask covers, in units. One unit is one
    /// texel, so this is also what makes the mask resolution a quality dial:
    /// halving `scale` doubles the texels along each axis.
    scale: f32 = 1,

    /// The sky radiance the GI cascades measure against. Zero means "no sky",
    /// which makes an enclosed room genuinely dark rather than dimly lit by a
    /// default nobody asked for.
    sky: [3]f32 = .{ 0, 0, 0 },

    /// Bumped by `resize` so the caller's `reserve` can happen before a frame.
    needs_resize: bool = false,

    /// Whether the GI grid changed since the last submission. Read (never
    /// cleared) by `frame`, so a caller driving the steps by hand still gets an
    /// accurate answer.
    gi_dirty: bool = false,

    /// The sprite coverage the automatic occluders rasterize from.
    ///
    /// OWNED by the driver and not borrowed, for the same reason the engine owns
    /// its other long-lived subsystems: a loader that registers a mask and then
    /// goes away must not take the pointer with it.
    ///
    /// Named `masks` and not `coverage` because a struct cannot have a field and
    /// a method of the same name -- the accessor below is `coverage()`.
    masks: light_mod.CoverageStore = undefined,

    /// The shadow map's angle count as the BACKEND last sized it. Kept here so a
    /// quality change can tell `submitLights` to re-create rather than relying on
    /// the backend's cache to notice on its own.
    shadow_angles: u32 = 0,

    /// The scene this driver last saw.
    ///
    /// Borrowed, and only between an `update` and the next one — the same
    /// lifetime the engine's other subsystems hold, and deliberately NOT the
    /// pattern `masks` uses. `masks` is data the driver produced and must own;
    /// this is a pointer to somebody else's world, and pretending otherwise
    /// would invite a call after that world was destroyed.
    ///
    /// It exists for `registerCoverageForPage`, which the atlas calls when a page
    /// uploads and which therefore cannot be handed a world by the caller. Set
    /// by `update`, so it is null only in the window between `init` and the
    /// first frame — and an upload landing there is a no-op, because there is no
    /// scene to register coverage against yet.
    world: ?*ecs.World = null,

    pub fn init(allocator: std.mem.Allocator, tier: light_mod.Quality) !Driver {
        var l = try Lighting.init(allocator, tier);
        errdefer l.deinit();
        // The clock, installed here rather than left to every caller. Two owners
        // existed before this line and both forgot: `Lighting.now` defaults to
        // null, and a null clock makes every internal timer read 0. The system
        // then reports "0 ns to collect, 0 ns to sweep" from inside a real frame
        // loop, which is worse than not reporting the split at all.
        l.now = driverNow;
        return .{
            .allocator = allocator,
            .lighting = l,
            .masks = light_mod.CoverageStore.init(allocator),
        };
    }

    pub fn deinit(self: *Driver) void {
        // The store first: `lighting` holds a pointer into it, and freeing the
        // owner first leaves a dangling pointer in a struct that is about to be
        // overwritten anyway -- harmless today and a use-after-free the day
        // someone reads it in a debugger.
        self.masks.deinit();
        self.lighting.coverage_store = null;
        self.lighting.deinit();
        self.* = undefined;
    }

    /// Sizes the mask for a view, and reports whether the caller must `reserve`.
    ///
    /// Split from `reserve` because the count of lights and occluders comes from
    /// the world, and a driver that counted them would need a second query pass
    /// every frame for a number that only matters when something is added.
    pub fn resize(self: *Driver, view: MaskRect) !void {
        const w: u32 = @intFromFloat(@max(1, (view.max.x - view.min.x) / self.scale));
        const h: u32 = @intFromFloat(@max(1, (view.max.y - view.min.y) / self.scale));
        const changed = w != self.lighting.alloc_w or h != self.lighting.alloc_h;
        if (changed) try self.lighting.resize(w, h);
        self.lighting.rect = view;
        self.needs_resize = changed;
    }

    /// Registers coverage for every non-opaque sprite rect in an atlas page, and
    /// writes the resulting index into every actor using one.
    ///
    /// ## Call this once per atlas page, after upload
    ///
    /// This is the loader's whole job for M7's automatic occluders. Before it, an
    /// automatic `LightOccluder2D` cast its sprite's rectangle; after it, the
    /// same scene casts the sprite's silhouette, and nothing in the scene file
    /// changed. That is what "zero dev action" means here.
    ///
    /// The store is owned by the driver, so an owner outliving a reload cannot
    /// dangle. A caller with its own store can set `lighting.coverage_store`
    /// directly instead.
    ///
    /// Not frame work -- it allocates and walks every sprite. A loader call.
    pub fn registerAtlasCoverage(
        self: *Driver,
        world: *ecs.World,
        pixels: []const u8,
        page_w: u32,
        page_h: u32,
    ) !light_mod.CoverageReport {
        self.lighting.coverage_store = &self.masks;
        return light_mod.registerAtlasCoverage(&self.masks, world, pixels, page_w, page_h, .{});
    }

    /// Adapts this driver to `atlas_bridge`'s page-uploaded hook.
    ///
    /// The half of the wiring that is easy to leave out. `registerAtlasCoverage`
    /// above is a correct, tested, benchmarked function that nothing called, so
    /// every automatic occluder in every real build cast its sprite's rectangle
    /// and `coverage_used` never left zero. This is the piece that makes the
    /// upload path call it: `uploadAtlas` owns the moment a page's pixels become
    /// authoritative and knows nothing about sprites, so the knowledge crosses
    /// over as a function pointer rather than as a dependency.
    ///
    /// Install it with `atlas_mgr.onPageUploaded(driver, Driver.registerCoverageForPage)`.
    /// The `ctx` is the driver; the `world` comes from `self.world`, which
    /// `init` installs, so the caller does not have to hand the scene in twice.
    ///
    /// Errors are swallowed on purpose, and that deserves an explanation: the hook
    /// runs inside `uploadAtlas`, which has no way to report "the lighting system
    /// was short on memory" to whoever asked for the atlas. Failing the upload
    /// would turn a shadow that is the wrong SHAPE into a frame that does not
    /// draw. So the page uploads, and the reason is counted where it can be seen
    /// — `coverage_dropped` is the number to watch, and a scene where it climbs
    /// is a scene with rectangle shadows and no explanation for them.
    pub fn registerCoverageForPage(
        ctx: *anyopaque,
        pixels: []const u8,
        page_w: u32,
        page_h: u32,
    ) anyerror!void {
        const self: *Driver = @ptrCast(@alignCast(ctx));
        const world = self.world orelse return;
        _ = self.registerAtlasCoverage(world, pixels, page_w, page_h) catch {
            self.lighting.stats.coverage_dropped += 1;
            return;
        };
    }

    /// The coverage store this driver owns. Public so a tool can inspect what a
    /// page registered, and so an editor can tell an author why a sprite's shadow
    /// is a rectangle: it registered nothing, because the sprite is opaque and for
    /// an opaque sprite a rectangle IS the silhouette.
    pub fn coverage(self: *const Driver) *const light_mod.CoverageStore {
        return &self.masks;
    }

    /// Changes the quality tier. Delegates, and reports whether it took.
    ///
    /// The editor's quality dropdown's whole job, so it lives here rather than
    /// being four things a caller has to do in the right order.
    pub fn setQuality(self: *Driver, tier: light_mod.Quality) bool {
        const ok = self.lighting.setQuality(tier) catch return false;
        // The shadow map's width follows the tier, so the texture has to be
        // rebuilt. `createShadowMap` is the thing that knows, and it caches on
        // the angle count — so this is a call, not a flag.
        self.shadow_angles = self.lighting.angles;
        return ok;
    }

    pub fn quality(self: *const Driver) light_mod.Quality {
        return self.lighting.quality();
    }

    /// The world-space rectangle the mask covers, from the camera's view and the
    /// framebuffer's size.
    ///
    /// PADDED by `mask_margin`, and that padding is the whole reason this is a
    /// function rather than the viewport passed straight through: the mask is
    /// also where the shadow SWEEPS start, and a light just off the left edge of
    /// the screen casts a shadow onto the visible part. A mask that stopped at
    /// the viewport would silently drop those shadows — and silently is how it
    /// would be found, by a user whose torches cast shadows that fade out a few
    /// pixels past the edge of the window.
    ///
    /// The margin matches the sprite culler's, for the same reason, and reusing
    /// the number is better than having two that agree by accident.
    pub fn viewFor(view: ?ecs.camera.View, fb_w: u32, fb_h: u32) MaskRect {
        const w: f32 = @floatFromInt(@max(1, fb_w));
        const h: f32 = @floatFromInt(@max(1, fb_h));
        const v = view orelse return .{
            // The identity camera shows `w x h` world units centred on the
            // origin, so that is the mask for a scene with no camera at all.
            .min = .{ .x = -w * 0.5 - mask_margin, .y = -h * 0.5 - mask_margin },
            .max = .{ .x = w * 0.5 + mask_margin, .y = h * 0.5 + mask_margin },
        };
        const hw = v.viewport_w / v.zoom * 0.5 + mask_margin;
        const hh = v.viewport_h / v.zoom * 0.5 + mask_margin;
        return .{
            .min = .{ .x = v.cx - hw, .y = v.cy - hh },
            .max = .{ .x = v.cx + hw, .y = v.cy + hh },
        };
    }

    /// One frame of lighting, up to but not including submission.
    ///
    /// Split from `submit` so a caller can inspect `Stats` or encode the GI field
    /// between the two, and so a test can drive the CPU half with no renderer at
    /// all.
    pub fn update(self: *Driver, world: *ecs.World, now_ns: i128) void {
        const l = &self.lighting;
        // Remembered for `registerCoverageForPage`, which the atlas calls without
        // a world. Recorded first so that a hook firing during this same update
        // sees the scene it is being asked about.
        self.world = world;
        l.collect(world, l.rect);

        // The mask is only rasterized when it would come out different. A
        // rasterizer that runs unconditionally turns "shadows are free until
        // something moves" into "shadows cost a grid fill every frame", and
        // `collect` already computed the answer.
        if (l.mask_changed) l.rasterize();
        l.buildShadowMaps();

        // The pyramid is a function of the distance field, so it is rebuilt on
        // the frames the FIELD was rebuilt and on no others. `updateSdf` answers
        // that question; before it returned the answer the driver called `build`
        // unconditionally, which meant a resting scene rebuilt a 262,144-ray
        // pyramid 60 times a second to arrive at the same numbers. The comment
        // here used to say "only when the field moved" over code that moved
        // every frame, which is the kind of claim that is worth more removed
        // than kept.
        const field_rebuilt = l.updateSdf(now_ns);
        if (field_rebuilt) {
            if (l.radiance) |r| {
                const before = r.builds;
                // `NotPrepared` is counted, not swallowed: it means the pyramid
                // was never sized for this mask, and silently skipping the bounce
                // light would look exactly like GI that is simply too dark to
                // notice.
                r.build(l.mask, l.sdf, l.alloc_w, l.alloc_h, self.sky) catch |err| switch (err) {
                    error.NotPrepared => l.stats.gi_not_prepared += 1,
                    else => return,
                };
                if (r.builds != before) self.gi_dirty = true;
            }
        } else {
            l.stats.gi_skipped += 1;
        }
    }

    /// Whether the GI grid changed since the last submission, and the `GiUpload`
    /// that carries it.
    ///
    /// `giDirty` is CONSUMED by `submit`: a caller that uploads and then asks
    /// again gets `false`, because the question is "has the GPU got it" and
    /// after the upload the answer is yes. A sticky flag would re-upload the
    /// same grid every frame and quietly undo the amortization.
    pub fn giUpload(self: *Driver) render_mod.GiUpload {
        return .{
            .rect = .{
                self.lighting.rect.min.x,
                self.lighting.rect.min.y,
                self.lighting.rect.max.x,
                self.lighting.rect.max.y,
            },
            .width = self.lighting.alloc_w,
            .height = self.lighting.alloc_h,
            .pixels = self.lighting.gi_pixels,
        };
    }

    /// The `LightFrame` for `Renderer2D.submitLights`, consuming `gi_dirty`.
    pub fn frame(self: *Driver, env: render_mod.SceneEnvironment) Renderer2D.LightFrame {
        const l = &self.lighting;
        return .{
            .lights = l.lights.items,
            .shadow = l.shadow,
            .angles = l.angles,
            .env = .{
                .ambient = env.ambient,
                .sky = self.sky,
                .albedo = env.albedo,
            },
            .gi = self.giUpload(),
            .gi_dirty = self.gi_dirty,
        };
    }

    /// Updates and submits in one call — the path the runtime uses.
    pub fn render(
        self: *Driver,
        world: *ecs.World,
        r: *two_d.Renderer2D,
        backend: render_mod.Renderer,
        env: render_mod.SceneEnvironment,
        now_ns: i128,
    ) usize {
        self.update(world, now_ns);
        const n = r.submitLights(backend, self.frame(env));
        self.gi_dirty = false;
        return n;
    }

    /// The world's `Environment` as the renderer's plain form.
    ///
    /// A free function rather than a method because the Environment is a
    /// COMPONENT and the driver holds no world between frames.
    pub fn environmentOf(world: *ecs.World, fallback: ecs.components.Environment) render_mod.SceneEnvironment {
        var it = world.query(.{ecs.components.Environment});
        const e = it.next() orelse return toScene(&fallback);
        return toScene(e.get(ecs.components.Environment));
    }

    fn toScene(env: *const ecs.components.Environment) render_mod.SceneEnvironment {
        return .{
            .ambient = env.ambient(),
            .sky = env.sky(),
            .albedo = env.gi_albedo,
        };
    }
};

/// Degrees to radians, exported because the driver's public surface talks in
/// angles everywhere else and a caller should not have to remember which.
pub fn deg(d: f32) f32 {
    return core_math.degToRad(d);
}

// ── the end-to-end check ─────────────────────────────────────────────────────
//
// Every other lighting test drives one piece: the collector, the sweep, the
// sampler, the backend's counters. This one drives the WHOLE THING — real
// components into a real world, through the real driver, into the real
// renderer, landing on the null backend's counters.
//
// It exists because of a specific failure that already happened: every part of
// the lighting system was green, and no scene was ever lit, because nothing
// owned a `Lighting` and nothing called `submitLights`. A subsystem whose parts
// each pass and which is never assembled needs a test that assembles it, and
// the only honest version of that test counts what came out the far end.

const testing = std.testing;
const components = ecs.components;

/// A world with one of each light kind, one occluder, and an Environment.
fn litWorld(world: *ecs.World, l: *Lighting) !void {
    try l.resize(64, 64);
    try l.reserve(8, 8);
    l.rect = .{ .min = .{ .x = 0, .y = 0 }, .max = .{ .x = 64, .y = 64 } };

    _ = try world.spawn(.{
        components.Transform{ .position = .{ .x = 16, .y = 32 } },
        components.PointLight2D{ .radius = 40 },
    });
    _ = try world.spawn(.{
        components.Transform{ .position = .{ .x = 48, .y = 16 } },
        components.SpotLight2D{ .radius = 48, .cone_angle = 1.2 },
    });
    _ = try world.spawn(.{components.DirectionalLight2D{ .height = 0.5 }});
    _ = try world.spawn(.{components.AmbientLight2D{}});

    // A wall at x = 30..32, so the point light's shadow map has something to
    // find. Without an occluder the sweep has nothing to sweep and the test
    // would pass on a scene that can never cast a shadow.
    var poly = components.OccluderPolygon{};
    poly.count = 4;
    poly.points = .{ 30, 0, 32, 0, 32, 64, 30, 64, 0, 0, 0, 0, 0, 0, 0, 0 };
    _ = try world.spawn(.{
        components.Transform{ .position = .{ .x = 0, .y = 0 } },
        components.LightOccluder2D{
            .mode = .manual,
            .polygon = poly,
        },
    });
    _ = try world.spawn(.{components.Environment{ .ambient_energy = 2.0 }});
}

test "render light driver: a scene with four lights reaches the backend, lit" {
    var d = try Driver.init(testing.allocator, .high);
    defer d.deinit();
    var world = ecs.World.init(testing.allocator);
    defer world.deinit();
    try litWorld(&world, &d.lighting);

    var r2d = two_d.Renderer2D.init(testing.allocator);
    defer r2d.deinit();
    var nb = render_mod.backend_null.Backend{};
    const backend = nb.renderer();

    const target = backend.createOffscreenTarget(128, 128);
    defer backend.destroyOffscreenTarget(target);
    backend.beginScene(target, render_mod.makeCamera(128.0, 128.0));

    const drawn = d.render(&world, &r2d, backend, Driver.environmentOf(&world, .{}), 1000);

    // Four components in, four lights out. The number is the whole assertion:
    // it can only be right if the collector read four DIFFERENT component types
    // and each one produced a distinct kind.
    try testing.expectEqual(@as(usize, 4), drawn);
    try testing.expectEqual(@as(u64, 4), nb.lights_drawn);

    // The shadow map was uploaded, and the occluder made it non-empty. A
    // zero-length upload would mean the map never reached the GPU.
    try testing.expect(nb.shadow_upload_bytes > 0);

    // The Environment reached the backend with its energy applied: the default
    // ambient is 0.09 and the test set energy 2, so 0.18 is the only correct
    // answer and a default-valued 0.09 would mean the uniform is not being
    // written from the component at all.
    try testing.expectApproxEqAbs(@as(f32, 0.09 * 2.0), nb.environment.ambient[0], 0.001);

    // And the lights are not all the same shape: one ambient, one directional,
    // two point-ish. An ambient that reached this point as a spot light would
    // still be four instances, so the count alone cannot catch that.
    var kinds = [_]bool{false} ** 4;
    for (d.lighting.lights.items) |inst| kinds[@intFromEnum(inst.kind())] = true;
    try testing.expect(kinds[0] and kinds[1] and kinds[2] and kinds[3]);

    backend.endScene(false, render_mod.SMAAQuality.Medium);
}

test "render light driver: GI is uploaded once per rebuild, not once per frame" {
    // The amortization claim, measured. A static scene's GI must cost one upload
    // and then nothing, and the number that proves it is the backend's upload
    // counter -- not a comment about amortization.
    var d = try Driver.init(testing.allocator, .high);
    defer d.deinit();
    var world = ecs.World.init(testing.allocator);
    defer world.deinit();
    try litWorld(&world, &d.lighting);
    d.sky = .{ 0.4, 0.45, 0.6 };

    var r2d = two_d.Renderer2D.init(testing.allocator);
    defer r2d.deinit();
    var nb = render_mod.backend_null.Backend{};
    const backend = nb.renderer();
    const target = backend.createOffscreenTarget(128, 128);
    defer backend.destroyOffscreenTarget(target);
    backend.beginScene(target, render_mod.makeCamera(128.0, 128.0));
    const env = Driver.environmentOf(&world, .{});

    // Ten frames of a scene where nothing moves.
    var f: i128 = 0;
    while (f < 10) : (f += 1 * std.time.ns_per_ms) {
        _ = d.render(&world, &r2d, backend, env, f);
    }
    try testing.expectEqual(@as(u64, 1), nb.gi_uploads);

    // Now move an occluder. That changes the mask, so the field and the pyramid
    // are genuinely different and exactly one more upload is owed.
    // Both components are in the query, so both are reachable from the row: a
    // `Row.get` for a type the query did not name is a compile error, which is
    // the trait that makes moving an occluder a two-line change instead of a
    // second lookup.
    var it = world.query(.{ components.LightOccluder2D, components.Transform });
    const row = it.next().?;
    row.get(components.LightOccluder2D).polygon.points[0] += 8;
    row.get(components.Transform).position.x += 8;
    d.lighting.dirty = true;
    d.lighting.mask_changed = true;
    _ = d.render(&world, &r2d, backend, env, 20 * std.time.ns_per_ms);
    try testing.expectEqual(@as(u64, 2), nb.gi_uploads);
    try testing.expect(nb.gi_upload_bytes > 0);

    backend.endScene(false, render_mod.SMAAQuality.Medium);
}

test "render light driver: encodeGi writes the enclosure term into alpha" {
    // The upload's contract, checked on the bytes. Alpha is the enclosure term
    // and RGB is radiance; a buffer with the right length and the wrong channel
    // is a scene that renders and is subtly wrong.
    var d = try Driver.init(testing.allocator, .high);
    defer d.deinit();
    try d.lighting.resize(64, 64);
    // `reserve` is a precondition, not a hint: the gather buffers append without
    // a capacity check because allocating mid-frame is forbidden. Getting this
    // wrong is a panic in the middle of the first occluder rather than an error
    // at a call site, which is why it is spelled out here.
    try d.lighting.reserve(4, 4);
    d.lighting.rect = .{ .min = .{ .x = 0, .y = 0 }, .max = .{ .x = 64, .y = 64 } };

    var poly = components.OccluderPolygon{};
    poly.count = 4;
    // A solid block in the middle: the cells inside it are enclosed and their
    // alpha must be near zero, while the open corners must be near 255.
    poly.points = .{ 24, 24, 40, 24, 40, 40, 24, 40, 0, 0, 0, 0, 0, 0, 0, 0 };
    d.lighting.occluders.appendAssumeCapacity(.{ .polygon = poly, .pos = .{ .x = 0, .y = 0 }, .extent = 8 });
    d.lighting.rasterize();
    try light_mod.edtMask2d(testing.allocator, d.lighting.mask, d.lighting.sdf, 64, 64);

    try testing.expect(d.lighting.encodeGi(d.lighting.gi_pixels));

    // (2, 2) is open corner; (32, 32) is inside the block.
    const open = d.lighting.gi_pixels[(2 * 64 + 2) * 4 + 3];
    const boxed = d.lighting.gi_pixels[(32 * 64 + 32) * 4 + 3];
    try testing.expect(open > 200);
    try testing.expect(boxed < open);

    // The size the driver hands the backend is the mask's, not the cascade's:
    // the shader indexes this grid by world position, and a pyramid-sized grid
    // would put every lookup in the wrong place.
    const up = d.giUpload();
    try testing.expectEqual(d.lighting.alloc_w, up.width);
    try testing.expectEqual(@as(usize, @as(usize, d.lighting.alloc_w) * d.lighting.alloc_h * 4), up.pixels.len);
}

test "render light driver: the mask covers the viewport AND the margin around it" {
    // The margin is the assertion. A mask that stops at the viewport edge drops
    // the shadow of any light just outside it, and a light just outside the
    // screen is most of them — which is how a scene ends up with shadows that
    // fade out a few pixels before the window does.
    const w: u32 = 800;
    const h: u32 = 600;

    const identity = Driver.viewFor(null, w, h);
    // No camera: the identity view is `w x h` centred on the origin.
    try testing.expectApproxEqAbs(@as(f32, -400 - 64), identity.min.x, 0.001);
    try testing.expectApproxEqAbs(@as(f32, 400 + 64), identity.max.x, 0.001);
    try testing.expectApproxEqAbs(@as(f32, -300 - 64), identity.min.y, 0.001);
    try testing.expectApproxEqAbs(@as(f32, 300 + 64), identity.max.y, 0.001);

    // And it is CENTRED, because an off-centre mask would put the shadow sweeps
    // in the wrong place relative to the sprites they fall on.
    try testing.expectApproxEqAbs(
        (identity.min.x + identity.max.x) * 0.5,
        0,
        0.001,
    );

    // A zoomed-out camera widens the rect by 1/zoom and keeps the margin
    // ABSOLUTE, not proportional: the margin exists for lights just off screen,
    // and how far off screen is a world distance rather than a screen fraction.
    const wide = Driver.viewFor(.{
        .cx = 0,
        .cy = 0,
        .zoom = 0.5,
        .viewport_w = w,
        .viewport_h = h,
    }, w, h);
    try testing.expectApproxEqAbs(@as(f32, 800 + 64), wide.max.x, 0.001);
    try testing.expectApproxEqAbs(@as(f32, -800 - 64), wide.min.x, 0.001);

    // A camera off the origin moves the rect with it.
    const panned = Driver.viewFor(.{
        .cx = 1000,
        .cy = -500,
        .zoom = 1,
        .viewport_w = w,
        .viewport_h = h,
    }, w, h);
    try testing.expectApproxEqAbs(@as(f32, 1000 + 400 + 64), panned.max.x, 0.001);
    try testing.expectApproxEqAbs(@as(f32, -500 - 300 - 64), panned.min.y, 0.001);
}

test "render light driver: setQuality reconfigures what it claims to, not just a field" {
    // Three of the four tiers change something ALREADY ALLOCATED — the angle
    // count, the GI interval, the channel invalidation — and writing `cfg` alone
    // would leave the buffers sized for the old tier while every read went to the
    // new one. So this asserts the things that actually moved.
    var d = try Driver.init(testing.allocator, .high);
    defer d.deinit();

    try testing.expectEqual(light_mod.Quality.high, d.quality());
    const high_angles = d.lighting.angles;
    try testing.expectEqual(@as(u8, 4), d.lighting.cfg.shadowLights());
    try testing.expect(d.lighting.gi_interval_ns == 0);

    try testing.expect(d.setQuality(.low));
    try testing.expectEqual(light_mod.Quality.low, d.quality());
    try testing.expect(d.lighting.angles < high_angles);
    try testing.expect(d.lighting.cfg.shadowLights() < 4);
    // And the backend is told, because the shadow map's WIDTH has to follow.
    try testing.expectEqual(@as(u32, d.lighting.angles), d.shadow_angles);

    // Down, then back up, which is what a user does to a slider.
    try testing.expect(d.setQuality(.high));
    try testing.expectEqual(light_mod.Quality.high, d.quality());
    try testing.expectEqual(high_angles, d.lighting.angles);
}

test "render light driver: a GI tier is declined by a driver that has no pyramid" {
    // The one honest "no". The pyramid is a STARTUP budget decision: a driver
    // created with `.off` has none, and building one here would allocate inside
    // what the caller believes is a settings change. Answering no is better than
    // allocating something the frame was never sized for.
    var d = try Driver.init(testing.allocator, .off);
    defer d.deinit();

    try testing.expect(d.lighting.radiance == null);
    try testing.expectEqual(light_mod.Quality.off, d.quality());

    // Down is always available — there is nothing to allocate.
    try testing.expect(d.setQuality(.off));
    // Up to a GI tier is not.
    try testing.expect(!d.setQuality(.medium));
    try testing.expectEqual(light_mod.Quality.off, d.quality());
}

test "render light driver: a quality change invalidates every shadow channel" {
    // The maps were swept for the OLD angle count. Leaving them marked built
    // would mean the first frame at the new tier sweeps nothing and every light
    // casts a shadow sampled from a map of the wrong width.
    var d = try Driver.init(testing.allocator, .high);
    defer d.deinit();
    try d.lighting.resize(64, 64);
    try d.lighting.reserve(8, 8);
    d.lighting.rect = .{ .min = .{ .x = 0, .y = 0 }, .max = .{ .x = 64, .y = 64 } };

    var world = ecs.World.init(testing.allocator);
    defer world.deinit();
    var i: usize = 0;
    while (i < 4) : (i += 1) {
        _ = try world.spawn(.{
            components.Transform{ .position = .{ .x = @as(f32, @floatFromInt(i)) * 16 + 8, .y = 32 } },
            components.PointLight2D{ .radius = 24, .base = .{ .cast_shadows = true } },
        });
    }
    d.lighting.collect(&world, d.lighting.rect);
    d.lighting.rasterize();
    d.lighting.buildShadowMaps();
    try testing.expectEqual(@as(u32, 4), d.lighting.stats.shadow_lights);
    // Built, so every channel is marked built.
    for (d.lighting.channel_built) |b| try testing.expect(b);

    try testing.expect(d.setQuality(.low));
    // And now none of them are.
    for (d.lighting.channel_built) |b| try testing.expect(!b);
}

test "render light driver: the driver's own store makes an occluder's silhouette, end to end" {
    // The whole ROADMAP promise in one test: a page goes in, a sprite with a hole
    // comes out occluding by its silhouette, and the author's scene file is never
    // touched. Everything else in the lighting system is downstream of this.
    var d = try Driver.init(testing.allocator, .high);
    defer d.deinit();
    try d.lighting.resize(32, 32);
    try d.lighting.reserve(8, 8);
    d.lighting.rect = .{ .min = .{ .x = 0, .y = 0 }, .max = .{ .x = 32, .y = 32 } };

    const w: u32 = 32;
    var page: [w * w * 4]u8 = undefined;
    for (0..w) |y| {
        for (0..w) |x| {
            page[(y * w + x) * 4 + 3] = if (x >= 12 and x < 20 and y >= 12 and y < 20) 0 else 255;
        }
    }

    var world = ecs.World.init(testing.allocator);
    defer world.deinit();
    _ = try world.spawn(.{
        components.Transform{ .position = .{ .x = 16, .y = 16 } },
        // uv naming a sub-rect rather than the whole page: the whole page is the
        // "no texture" default and registers nothing.
        components.Sprite{
            .size = .{ .x = 32, .y = 32 },
            .uv = .{ 0.0625, 0.0625, 0.9375, 0.9375 },
        },
        components.LightOccluder2D{ .mode = .auto_sdf, .alpha_threshold = 0.5 },
    });

    const report = try d.registerAtlasCoverage(&world, &page, w, w);
    try testing.expectEqual(@as(u32, 1), report.rects);
    try testing.expectEqual(@as(u32, 1), report.registered);
    try testing.expectEqual(@as(u32, 0), report.fully_opaque);
    try testing.expectEqual(@as(usize, 1), d.coverage().count());

    d.update(&world, 0);

    // The hole. With the rectangle fallback this cell would be 255, and the shadow
    // would be a solid block over a gap the viewer can see through.
    try testing.expectEqual(@as(u8, 0), d.lighting.mask[16 * 32 + 16]);
    // And the sprite's corners, which are solid.
    try testing.expectEqual(@as(u8, 255), d.lighting.mask[1 * 32 + 1]);
    try testing.expectEqual(@as(u8, 255), d.lighting.mask[30 * 32 + 30]);

    // The field was rebuilt once, from the corrected mask. That is the SDF the
    // ROADMAP asks for, and it needed no new representation: the exact EDT over a
    // correct mask IS the distance field of the silhouette, and it is already
    // amortized behind the mask's own dirty flag. `dirty` is false here, not
    // true: `update` rasterizes and then immediately transforms.
    try testing.expectEqual(@as(u32, 1), d.lighting.stats.sdf_builds);
    try testing.expect(!d.lighting.dirty);
}

test "render light driver: a whole-page sprite is the no-atlas default and registers nothing" {
    // `uv = (0,0,1,1)` is what a sprite with no atlas texture carries. Making a
    // coverage mask of the ENTIRE page would give every untextured sprite the
    // page's contents -- so it is declined, and the rectangle fallback is right.
    var d = try Driver.init(testing.allocator, .high);
    defer d.deinit();

    var blank: [16 * 16 * 4]u8 = undefined;
    @memset(&blank, 0);

    var world = ecs.World.init(testing.allocator);
    defer world.deinit();
    _ = try world.spawn(.{
        components.Transform{},
        components.Sprite{ .size = .{ .x = 16, .y = 16 } },
        components.LightOccluder2D{ .mode = .auto_sdf },
    });

    const report = try d.registerAtlasCoverage(&world, &blank, 16, 16);
    try testing.expectEqual(@as(u32, 0), report.rects);
    try testing.expectEqual(@as(u32, 0), report.registered);
    try testing.expectEqual(@as(usize, 0), d.coverage().count());
}

test "render light driver: the store outlives a reload, because the driver owns it" {
    // A loader that registers a mask and then goes away must not take the pointer
    // with it. The driver owns it, so this is an assertion about ownership rather
    // than about arithmetic.
    var d = try Driver.init(testing.allocator, .high);
    defer d.deinit();
    try d.lighting.resize(16, 16);
    try d.lighting.reserve(8, 8);
    d.lighting.rect = .{ .min = .{ .x = 0, .y = 0 }, .max = .{ .x = 16, .y = 16 } };

    var page: [16 * 16 * 4]u8 = undefined;
    for (0..16) |y| {
        for (0..16) |x| {
            page[(y * 16 + x) * 4 + 3] = if (x < 8 and y < 8) 0 else 255;
        }
    }
    var world = ecs.World.init(testing.allocator);
    defer world.deinit();
    _ = try world.spawn(.{
        components.Transform{ .position = .{ .x = 8, .y = 8 } },
        components.Sprite{ .size = .{ .x = 16, .y = 16 }, .uv = .{ 0, 0, 0.5, 0.5 } },
        components.LightOccluder2D{ .mode = .auto_sdf },
    });

    {
        // A nested scope standing in for a loader that comes and goes.
        _ = try d.registerAtlasCoverage(&world, &page, 16, 16);
    }
    // Still registered, and the lookup still resolves through `collect`.
    try testing.expectEqual(@as(usize, 1), d.coverage().count());
    d.update(&world, 0);
    try testing.expectEqual(@as(u32, 1), d.lighting.stats.coverage_used);
    try testing.expect(d.lighting.coverage_store != null);
}

test "render light driver: the atlas upload hook is what makes coverage reachable" {
    // The gap this closes, stated as a test.
    //
    // `registerAtlasCoverage` was correct, tested and benchmarked, and called
    // from nowhere in the engine. Automatic occluders therefore cast rectangles
    // in every real build, `coverage_used` was a permanent zero, and nothing
    // reported it: the ROADMAP line "alpha threshold, zero dev action" was true
    // of the unit test above it and false of the game.
    //
    // The unit test directly above proves the driver can do it when asked. This
    // one proves something is actually ASKING — that the atlas's upload path
    // reaches the driver on its own, which is the difference between a feature
    // that works and a feature that can work.
    //
    // Both halves are real: a real `AtlasManager`, a real page with a real hole
    // in it, and the real `uploadAtlas`. Only the GPU call is stubbed, because
    // that is the one thing a headless test cannot have.
    var d = try Driver.init(testing.allocator, .high);
    defer d.deinit();
    try d.lighting.resize(32, 32);
    try d.lighting.reserve(8, 8);
    d.lighting.rect = .{ .min = .{ .x = 0, .y = 0 }, .max = .{ .x = 32, .y = 32 } };

    // The page is BIGGER than the sprite, on purpose. `spriteRect` skips a rect
    // that covers its whole page -- a full-page sprite's coverage would be the
    // page, so cropping it would be copying a megabyte to learn nothing. A
    // fixture where the sprite fills the page therefore registers nothing, and
    // for a reason that has nothing to do with the hook: a test shaped like that
    // would pass or fail for the wrong reason.
    const page_side: u32 = 64;
    const spr: u32 = 32;
    var mgr = try atlas_bridge.AtlasManager.init(testing.allocator, page_side, page_side, 0);
    defer mgr.deinit(testing.allocator);

    var world = ecs.World.init(testing.allocator);
    defer world.deinit();

    // One sprite with a hole punched in the middle. A fully opaque sprite's
    // rectangle IS its silhouette, so a fixture with no hole would pass with
    // coverage disabled and prove nothing at all.
    var pixels: [spr * spr * 4]u8 = undefined;
    for (0..spr) |y| {
        for (0..spr) |x| {
            const inside = x >= 12 and x < 20 and y >= 12 and y < 20;
            const off = (y * spr + x) * 4;
            pixels[off + 0] = 255;
            pixels[off + 1] = 255;
            pixels[off + 2] = 255;
            pixels[off + 3] = if (inside) 0 else 255;
        }
    }

    const sprite_e = try world.spawn(.{
        components.Transform{ .position = .{ .x = 16, .y = 16 } },
        components.Sprite{ .uv = .{ 0, 0, 1, 1 }, .layer = 0 },
        components.LightOccluder2D{ .mode = .auto_sdf },
        components.PointLight2D{ .radius = 64 },
    });

    // The wiring. Nothing else in the engine does this, which is the point.
    // `Image` is `assets`', re-exported by `atlas_bridge` -- the same type the
    // asset pipeline hands the atlas, which is the point of the seam existing at
    // all rather than being a test-only path.
    const Image = atlas_bridge.Image;
    const image = Image{
        .width = spr,
        .height = spr,
        .channels = 4,
        .pixels = &pixels,
    };
    _ = try mgr.addImage(testing.allocator, "sprite.png", image);

    // The sprite's rect comes from the atlas rather than being assumed, so the
    // test cannot pass because the two happened to agree.
    const placed = mgr.entries.get("sprite.png").?;
    world.get(sprite_e, components.Sprite).?.uv = placed.uv;

    mgr.onPageUploaded(&d, Driver.registerCoverageForPage);

    // One frame before the upload, which is the order the engine is in: the
    // driver learns the world on its first `update`, and atlas pages upload
    // afterwards. Without this the hook no-ops -- which is correct, and is the
    // subject of the test below -- and this test would fail for a reason that has
    // nothing to do with the wiring it is checking.
    d.update(&world, 0);

    const Upload = struct {
        fn create(_: *anyopaque, _: u32, _: u32, _: []const u8) ?*anyopaque {
            // A non-null handle, because `uploadAtlas` treats null as failure and
            // would return before the hook -- which would make this test pass for
            // the wrong reason, and quietly.
            return @ptrFromInt(0x1000);
        }
    };
    _ = try atlas_bridge.uploadAtlas(@ptrFromInt(0x2000), &mgr, Upload.create);

    // The hook ran, and it ran on the driver's own store.
    try testing.expectEqual(@as(usize, 1), d.coverage().count());

    // And the silhouette reaches the occluder, which is the part the ROADMAP
    // actually promises.
    d.update(&world, 0);
    try testing.expectEqual(@as(u32, 1), d.lighting.stats.coverage_used);
}

test "render light driver: a coverage hook with no world is a no-op, not a crash" {
    // The hook's `ctx` is installed before the driver has a world, because that
    // is the order the engine uses: the atlas manager is built with the renderer,
    // and the driver is handed the scene a moment later. An upload landing in that
    // window must not dereference a null world — and must not count a drop either,
    // since nothing failed; there was simply no scene yet to register against.
    var d = try Driver.init(testing.allocator, .high);
    defer d.deinit();

    try testing.expect(d.world == null);
    try Driver.registerCoverageForPage(&d, &[_]u8{ 255, 255, 255, 255 }, 1, 1);
    try testing.expectEqual(@as(usize, 0), d.coverage().count());
    try testing.expectEqual(@as(u32, 0), d.lighting.stats.coverage_dropped);
}
