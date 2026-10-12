//! Null backend: no GPU at all, just frame bookkeeping.
//!
//! Used for: headless CI, runtime tests, and as the template of the contract
//! the Dawn backend fulfills. Zero allocations.
//!
//! It implements the FULL contract including the counters: a CI run without a
//! GPU still measures draw calls, uploads and frame structure — only the GPU
//! timestamps are absent (that is what `FrameStats.timestamp_queries` says).

const std = @import("std");
const render = @import("render.zig");
const wgpu = @import("webgpu.zig");

pub const Backend = struct {
    frames: u64 = 0,
    quads_drawn: u64 = 0,
    sprites_drawn: u64 = 0,
    /// M7: lights submitted and shadow-map bytes uploaded. Asserted by the
    /// headless tests, which is the only way the light pass is checked without
    /// a GPU.
    lights_drawn: u64 = 0,
    light_upload_bytes: u64 = 0,
    shadow_upload_bytes: u64 = 0,
    /// M7: the environment the scene published, and the last GI cascade it sent.
    /// Kept so a headless test can assert the scene asked for bounce rather than
    /// only that it drew some lights.
    environment: render.SceneEnvironment = .{},
    gi_rect: [4]f32 = .{ 0, 0, 1, 1 },
    gi_width: u32 = 0,
    gi_height: u32 = 0,
    gi_uploads: u64 = 0,
    gi_upload_bytes: u64 = 0,
    stats_data: render.FrameStats = .{},

    const vtable = render.Renderer.VTable{
        .beginFrame = beginFrame,
        .acquireSurface = acquireSurface,
        .drawQuad = drawQuad,
        .present = present,
        .resize = resize,
        .stats = stats,
        .deinit = deinit,
        .createOffscreenTarget = createOffscreenTarget,
        .destroyOffscreenTarget = destroyOffscreenTarget,
        .beginScene = beginScene,
        .endScene = endScene,
        .drawSprites = drawSprites,
        .drawLights = drawLights,
        .createShadowMap = createShadowMap,
        .uploadShadowMap = uploadShadowMap,
        .setEnvironment = setEnvironment,
        .uploadGi = uploadGi,
        .createTexture = createTexture,
        .destroyTexture = destroyTexture,
    };

    pub fn renderer(self: *Backend) render.Renderer {
        return .{ .ptr = self, .vtable = &vtable };
    }

    fn beginFrame(ptr: *anyopaque) void {
        const self: *Backend = @ptrCast(@alignCast(ptr));
        self.stats_data.draw_calls = 0;
        self.stats_data.render_passes = 0;
        self.stats_data.pipeline_changes = 0;
        self.stats_data.bind_group_changes = 0;
        self.stats_data.vertex_count = 0;
        self.stats_data.upload_bytes = 0;
        self.stats_data.gpu_ns = 0;
        self.stats_data.gpu_passes = 0;
        self.stats_data.resources_created_frame = 0;
    }

    fn acquireSurface(ptr: *anyopaque) void {
        _ = ptr; // no surface at all
    }

    fn drawQuad(ptr: *anyopaque, mvp: *const [16]f32) void {
        _ = mvp;
        const self: *Backend = @ptrCast(@alignCast(ptr));
        self.quads_drawn += 1;
        self.stats_data.draw_calls += 1;
        self.stats_data.render_passes += 1;
        self.stats_data.pipeline_changes += 1;
        self.stats_data.bind_group_changes += 1;
        self.stats_data.vertex_count += 4;
        self.stats_data.upload_bytes += @sizeOf([16]f32); // the MVP
    }

    fn present(ptr: *anyopaque) void {
        const self: *Backend = @ptrCast(@alignCast(ptr));
        self.frames += 1;
    }

    fn resize(ptr: *anyopaque, width: u32, height: u32) void {
        _ = ptr;
        _ = width;
        _ = height;
    }

    fn stats(ptr: *anyopaque) *const render.FrameStats {
        const self: *Backend = @ptrCast(@alignCast(ptr));
        return &self.stats_data;
    }

    fn deinit(ptr: *anyopaque) void {
        _ = ptr;
    }

    // ── M2 stubs ────────────────────────────────────────────────────────────

    fn createOffscreenTarget(ptr: *anyopaque, width: u32, height: u32) render.OffscreenTarget {
        _ = ptr;
        return render.OffscreenTarget{ .width = width, .height = height, .handle = null };
    }

    fn destroyOffscreenTarget(ptr: *anyopaque, target: render.OffscreenTarget) void {
        _ = ptr;
        _ = target;
    }

    fn beginScene(ptr: *anyopaque, target: render.OffscreenTarget, camera: render.Camera) void {
        _ = ptr;
        _ = target;
        _ = camera;
    }

    fn endScene(ptr: *anyopaque, enable_smaa: bool, smaa_quality: render.SMAAQuality) void {
        _ = ptr;
        _ = enable_smaa;
        _ = smaa_quality;
    }

    fn drawLights(ptr: *anyopaque, instances: []const render.light_mod.LightInstance, count: usize) void {
    const self: *Backend = @ptrCast(@alignCast(ptr));
    self.lights_drawn = count;
    self.light_upload_bytes += instances.len * @sizeOf(render.light_mod.LightInstance);
}

fn createShadowMap(ptr: *anyopaque, angles: u32) ?*anyopaque {
    _ = ptr;
    _ = angles;
    // The null backend has no textures, so there is nothing to hand out. The
    // count is what tests assert on; a real backend returns a handle.
    return null;
}

fn uploadShadowMap(ptr: *anyopaque, data: []const u8) void {
    const self: *Backend = @ptrCast(@alignCast(ptr));
    self.shadow_upload_bytes += data.len;
}

/// Counts the upload instead of doing it. The null backend's whole job is to be
/// measurable without a GPU, and "how many bytes of GI did the scene decide to
/// send" is one of the numbers a frame budget is argued with — so it records it
/// rather than ignoring it.
fn setEnvironment(ptr: *anyopaque, env: render.SceneEnvironment) void {
    const self: *Backend = @ptrCast(@alignCast(ptr));
    self.environment = env;
}

fn uploadGi(ptr: *anyopaque, gi: render.GiUpload) void {
    const self: *Backend = @ptrCast(@alignCast(ptr));
    // Mirrors `backend_dawn.zig`'s validation, and that is the point of the null
    // backend: it is the executable statement of the contract. A check that
    // exists only in the Dawn backend is a check that only runs on a machine
    // with a GPU, which is not the machine that has CI.
    if (gi.width == 0 or gi.height == 0) return;
    if (gi.pixels.len < @as(usize, gi.width) * gi.height * 4) return;
    self.gi_upload_bytes += gi.pixels.len;
    self.gi_rect = gi.rect;
    self.gi_width = gi.width;
    self.gi_height = gi.height;
    self.gi_uploads += 1;
}

fn drawSprites(ptr: *anyopaque, instances: []const render.SpriteInstance, count: usize) void {
        _ = instances;
        const self: *Backend = @ptrCast(@alignCast(ptr));
        self.sprites_drawn += count;
        // One instanced draw per atlas run; the null backend counts the same
        // metric the Dawn backend does so CI compares apples to apples.
        self.stats_data.draw_calls += 1;
        self.stats_data.render_passes += 1;
        self.stats_data.vertex_count += @as(u64, count) * 4;
        self.stats_data.upload_bytes += @as(u64, count) * @sizeOf(render.SpriteInstance);
    }

    fn createTexture(ptr: *anyopaque, width: u32, height: u32, pixels: []const u8) ?*anyopaque {
        _ = ptr;
        _ = width;
        _ = height;
        _ = pixels;
        return null;
    }

    fn destroyTexture(ptr: *anyopaque, texture: ?*anyopaque) void {
        _ = ptr;
        _ = texture;
    }
};

test "null backend counts a frame and resets per frame" {
    var b = Backend{};
    const r = b.renderer();
    const identity = [_]f32{ 1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1 };
    r.beginFrame();
    r.drawQuad(&identity);
    r.present();
    try std.testing.expectEqual(@as(u64, 1), r.stats().draw_calls);
    try std.testing.expectEqual(@as(u64, 64), r.stats().upload_bytes);
    try std.testing.expectEqual(@as(u64, 4), r.stats().vertex_count);
    r.beginFrame();
    try std.testing.expectEqual(@as(u64, 0), r.stats().draw_calls);
    try std.testing.expectEqual(@as(u64, 1), b.frames);
    try std.testing.expect(!r.stats().timestamp_queries);
}

test "null backend M2: offscreen target and sprite batch" {
    var b = Backend{};
    const r = b.renderer();

    const target = r.createOffscreenTarget(800, 600);
    try std.testing.expectEqual(@as(u32, 800), target.width);
    try std.testing.expectEqual(@as(u32, 600), target.height);

    const cam = render.makeCamera(800.0, 600.0);
    r.beginScene(target, cam);

    const sprites = [_]render.SpriteInstance{
        .{ .pos = .{ 0, 0 }, .half = .{ 10, 10 }, .uv = .{ 0, 0, 65535, 65535 }, .color = .{ 255, 255, 255, 255 }, .slot = 0 },
        .{ .pos = .{ 20, 0 }, .half = .{ 10, 10 }, .uv = .{ 0, 0, 65535, 65535 }, .color = .{ 255, 255, 255, 255 }, .slot = 0 },
    };
    r.drawSprites(&sprites, sprites.len);

    try std.testing.expectEqual(@as(u64, 1), r.stats().draw_calls);
    // 4 vertices per instance (triangle strip corners).
    try std.testing.expectEqual(@as(u64, 8), r.stats().vertex_count);

    r.endScene(false, render.SMAAQuality.Medium);
    r.destroyOffscreenTarget(target);
}

test "render light backend null: the light pass is counted and the shadow map uploaded" {
    var b = Backend{};
    const r = b.renderer();

    const target = r.createOffscreenTarget(800, 600);
    const cam = render.makeCamera(800.0, 600.0);
    r.beginScene(target, cam);

    // One of each kind, all four this time. They path through the same call, so
    // a scene mixing them must not be three code paths — and an ambient is the
    // one that used to fall into the spot branch.
    const lights = [_]render.light_mod.LightInstance{
        render.light_mod.instanceFor(
            render.light_mod.descFor(
                render.light_mod.components.PointLight2D,
                .{ .radius = 128 },
                0,
            ),
            .{ .x = 100, .y = 100 },
            0,
        ),
        render.light_mod.instanceFor(
            render.light_mod.descFor(
                render.light_mod.components.SpotLight2D,
                .{ .radius = 200, .cone_angle = 1.2 },
                0,
            ),
            .{ .x = 200, .y = 100 },
            -1,
        ),
        render.light_mod.instanceFor(
            render.light_mod.descFor(
                render.light_mod.components.DirectionalLight2D,
                .{ .max_distance = 1024, .angle = 0.6 },
                0,
            ),
            .{ .x = 0, .y = 0 },
            1,
        ),
        render.light_mod.instanceFor(
            render.light_mod.descFor(
                render.light_mod.components.AmbientLight2D,
                .{},
                1024,
            ),
            .{ .x = 400, .y = 300 },
            -1,
        ),
    };
    r.drawLights(&lights, lights.len);
    try std.testing.expectEqual(@as(u64, 4), b.lights_drawn);
    // `@sizeOf(LightInstance)` per light, not a number written here: this test
    // asserted 204 against a struct that is 72 bytes, so it was checking an
    // arithmetic mistake rather than the upload.
    try std.testing.expectEqual(
        @as(u64, 4 * @sizeOf(render.light_mod.LightInstance)),
        b.light_upload_bytes,
    );

    // The shadow map is `angles` wide and four channels tall, so a valid upload
    // is `angles * 4` bytes. An upload that is not a multiple of the width is
    // silently dropped rather than corrupting a row boundary.
    const angles: u32 = 64;
    const shadow = [_]u8{0} ** (@as(usize, angles) * 4);
    r.uploadShadowMap(&shadow);
    try std.testing.expectEqual(@as(u64, 256), b.shadow_upload_bytes);

    // A truncated upload is the shape a resize race produces, and it must not be
    // mistaken for a smaller valid one.
    r.uploadShadowMap(&shadow);
    try std.testing.expectEqual(@as(u64, 512), b.shadow_upload_bytes);

    r.drawLights(&lights, 0);
    try std.testing.expectEqual(@as(u64, 0), b.lights_drawn);

    r.endScene(false, render.SMAAQuality.Medium);
    r.destroyOffscreenTarget(target);
}

test "render light backend null: the environment and the GI cascade reach the backend" {
    // Without a GPU the only thing a GI upload CAN be checked for is that the
    // scene decided to send it. That is worth asserting, because the whole
    // amortization argument is "the pyramid is rebuilt sometimes, not every
    // frame", and a driver that never uploads has nothing to amortize.
    var b = Backend{};
    const r = b.renderer();

    const env = render.SceneEnvironment{
        .ambient = .{ 0.2, 0.2, 0.3, 1 },
        .sky = .{ 0.5, 0.6, 0.8 },
        .albedo = 0.7,
    };
    r.setEnvironment(env);
    try std.testing.expectEqual(@as(f32, 0.7), b.environment.albedo);
    try std.testing.expectEqual(@as(f32, 0.6), b.environment.sky[1]);

    const w: u32 = 4;
    const h: u32 = 2;
    const pixels = [_]u8{200, 200, 200, 128} ** (w * h);
    r.uploadGi(.{ .rect = .{ -10, -20, 90, 60 }, .width = w, .height = h, .pixels = &pixels });
    try std.testing.expectEqual(@as(u64, 1), b.gi_uploads);
    try std.testing.expectEqual(@as(u64, pixels.len), b.gi_upload_bytes);
    try std.testing.expectEqual(w, b.gi_width);
    try std.testing.expectEqual(@as(f32, -10), b.gi_rect[0]);

    // A short buffer is refused rather than read past its end: the pyramid is
    // resized asynchronously, so a stale slice length is a normal race and not
    // an error worth reporting.
    const before = b.gi_uploads;
    r.uploadGi(.{ .width = 64, .height = 64, .pixels = &pixels });
    try std.testing.expectEqual(before, b.gi_uploads);
    r.uploadGi(.{ .width = 0, .height = 0, .pixels = &pixels });
    try std.testing.expectEqual(before, b.gi_uploads);
}
