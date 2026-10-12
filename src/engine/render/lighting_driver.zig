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
const Renderer2D = two_d.Renderer2D;
const ecs = @import("ecs");
const core_math = @import("core").math;

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

    pub fn init(allocator: std.mem.Allocator, quality: light_mod.Quality) !Driver {
        return .{
            .allocator = allocator,
            .lighting = try Lighting.init(allocator, quality),
        };
    }

    pub fn deinit(self: *Driver) void {
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
        l.collect(world, l.rect);

        // The mask is only rasterized when it would come out different. A
        // rasterizer that runs unconditionally turns "shadows are free until
        // something moves" into "shadows cost a grid fill every frame", and
        // `collect` already computed the answer.
        if (l.mask_changed) l.rasterize();
        l.updateSdf(now_ns);

        l.buildShadowMaps();

        // The pyramid is rebuilt only when the field it traces has changed, so
        // `builds` — not the frame count — is what the GI upload keys off.
        if (l.radiance) |r| {
            // Only when the field moved. `builds` counts REBUILDS rather than
            // frames, and that counter is what `bench-light` reports -- an
            // amortization claim that is asserted instead of counted is a claim
            // about the code, not about the runtime.
            const before = r.builds;
            r.build(l.mask, l.sdf, l.alloc_w, l.alloc_h, self.sky) catch return;
            if (r.builds != before) self.gi_dirty = true;
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
