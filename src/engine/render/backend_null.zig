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