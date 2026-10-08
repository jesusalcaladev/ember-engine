//! Renderer interface (spec §7: the engine never uses Dawn directly).
//!
//! M0 draws a quad with an MVP. M2 adds: sprite batcher, offscreen target,
//! orthographic cameras + layers, SMAA 1x post-process. The interface keeps
//! the `ptr + vtable` shape so the backend can change (null / dawn) without
//! touching the runtime.

const std = @import("std");

pub const backend_null = @import("backend_null.zig");
pub const backend_dawn = @import("backend_dawn.zig");

pub const QuadVertex = struct {
    pos: [2]f32,
    color: [4]f32,
};

/// Centered unit quad (the shader scales it with the MVP).
pub const quad_vertices = [_]QuadVertex{
    .{ .pos = .{ -0.5, -0.5 }, .color = .{ 1.0, 0.4, 0.2, 1.0 } },
    .{ .pos = .{ 0.5, -0.5 }, .color = .{ 0.2, 0.9, 0.6, 1.0 } },
    .{ .pos = .{ 0.5, 0.5 }, .color = .{ 0.3, 0.5, 1.0, 1.0 } },
    .{ .pos = .{ -0.5, 0.5 }, .color = .{ 1.0, 0.8, 0.2, 1.0 } },
};

pub const quad_indices = [_]u16{ 0, 1, 2, 0, 2, 3 };

/// Per-sprite GPU record (M2, instanced).
///
/// Why instanced and not 6 vertices per sprite: 6 vertices x 36 B x 50k =
/// 10.8 MB uploaded EVERY FRAME, which breaks spec §4 ("staging uploads
/// <= 2 MB/frame in steady state") by 5x. One instance record of 32 B keeps
/// the same scene at 1.6 MB — inside the budget — and the vertex shader
/// derives the 4 corners from `vertex_index` with a triangle-strip topology,
/// so there is no index buffer and no per-vertex expansion at all.
///
/// Field packing (the reason it is 32 and not 52): uv as 4x u16 unorm and
/// tint as 4x u8 unorm are visually lossless for 2D sprites and save 20
/// bytes per sprite = 1 MB per frame at the 50k scene.
pub const SpriteInstance = struct {
    /// World-space center.
    pos: [2]f32,
    /// Half extents in world units.
    half: [2]f32,
    /// Atlas rect (u0, v0, u1, v1) as unorm16.
    uv: [4]u16,
    /// Tint RGBA as unorm8.
    color: [4]u8,
    /// Atlas slot; consecutive instances with the same slot batch together.
    slot: u8,
    _pad: [3]u8 = .{ 0, 0, 0 },
};

comptime {
    // The backend hardcodes the stride; this assert keeps the two in sync.
    if (@sizeOf(SpriteInstance) != 32) @compileError("SpriteInstance must stay 32 bytes");
}

/// Converts a float 0..1 to unorm16 (the atlas uv packing).
/// `@min`/`@max` instead of `std.math.clamp`: this runs 4x per sprite on the
/// 50k scene and the generic clamp was measurable there.
pub fn toUnorm16(v: f32) u16 {
    const c = @max(0.0, @min(1.0, v));
    return @intFromFloat(c * 65535.0 + 0.5);
}

/// Converts a float 0..1 to unorm8 (the tint packing).
pub fn toUnorm8(v: f32) u8 {
    const c = @max(0.0, @min(1.0, v));
    return @intFromFloat(c * 255.0 + 0.5);
}

/// Maximum sprites per batch (tuned for uniform buffer size and draw call efficiency).
pub const MAX_SPRITES_PER_BATCH: usize = 4096;

/// Orthographic camera: view-projection matrix + viewport.
pub const Camera = struct {
    /// Column-major view-projection matrix (ortho).
    vp: [16]f32 = [_]f32{1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1},
    /// Viewport in pixels (for scissor / SMAA resolve).
    viewport_x: u32 = 0,
    viewport_y: u32 = 0,
    viewport_w: u32 = 0,
    viewport_h: u32 = 0,
};

/// Per-frame render metrics. The runtime copies them into the profiler's
/// counters so the report and the trace can check them against spec.md:
/// draw calls (§4), uploads (§4), GPU timestamps (§4) and — the important
/// one — GPU objects created DURING the frame (§3.6 forbids them).
pub const FrameStats = struct {
    draw_calls: u64 = 0,
    render_passes: u64 = 0,
    pipeline_changes: u64 = 0,
    bind_group_changes: u64 = 0,
    vertex_count: u64 = 0,
    /// Bytes staged to the GPU this frame (spec §4: <= 2 MB/frame).
    upload_bytes: u64 = 0,
    /// GPU frame time from timestamp queries, 0 when unavailable.
    gpu_ns: u64 = 0,
    gpu_passes: u32 = 0,
    /// GPU objects created since boot.
    resources_created_total: u64 = 0,
    /// GPU objects created in the CURRENT frame (must be 0: spec §3.6).
    resources_created_frame: u64 = 0,
    present_mode: c_uint = 1, // PresentMode_Fifo by default
    timestamp_queries: bool = false,
    /// Diagnostic counters of the timestamp readback pipeline.
    timestamp_maps: u64 = 0,
    timestamp_reads: u64 = 0,
    timestamp_bad: u64 = 0,
    timestamp_ranges: u64 = 0,
};

/// Offscreen render target (M2: game always renders here; editor composes).
pub const OffscreenTarget = struct {
    width: u32,
    height: u32,
    /// Opaque handle for the backend; null when there is no GPU object (the
    /// null backend has none, and a failed creation reports null too).
    handle: ?*anyopaque = null,
};

/// SMAA quality presets.
pub const SMAAQuality = enum { Low, Medium, High };

pub const Renderer = struct {
    ptr: *anyopaque,
    vtable: *const VTable,

    pub const VTable = struct {
        /// Starts a frame: resets the counters and (on Dawn) publishes the GPU
        /// timestamps resolved two frames ago.
        beginFrame: *const fn (ptr: *anyopaque) void,
        /// Acquires the surface texture. Must be called once per frame, before
        /// any draw calls. With a Fifo present mode this is where the frame blocks
        /// waiting for the display: it is deliberately a separate call so the
        /// profiler can time the wait apart from the encoding cost.
        acquireSurface: *const fn (ptr: *anyopaque) void,
        /// M0 legacy: draws a quad with an MVP transform (column-major 4x4).
        /// Kept for compatibility; M2 code should use drawSprites.
        drawQuad: *const fn (ptr: *anyopaque, mvp: *const [16]f32) void,
        /// Presents the frame (swapchain on dawn; no-op on null).
        present: *const fn (ptr: *anyopaque) void,
        /// The framebuffer changed size.
        resize: *const fn (ptr: *anyopaque, width: u32, height: u32) void,
        /// Frame metrics (stable pointer to the backend's own struct).
        stats: *const fn (ptr: *anyopaque) *const FrameStats,
        /// Releases backend resources.
        deinit: *const fn (ptr: *anyopaque) void,

        // ── M2 extensions ──────────────────────────────────────────────────
        /// Creates the offscreen target the game renders to (editor requirement).
        /// Called once at boot or on resize.
        createOffscreenTarget: *const fn (ptr: *anyopaque, width: u32, height: u32) OffscreenTarget,
        /// Destroys an offscreen target.
        destroyOffscreenTarget: *const fn (ptr: *anyopaque, target: OffscreenTarget) void,
        /// Begins the scene pass: binds the offscreen target, clears, sets camera.
        beginScene: *const fn (ptr: *anyopaque, target: OffscreenTarget, camera: Camera) void,
        /// Ends the scene pass and (optionally) runs SMAA resolve into the
        /// offscreen target's color attachment.
        endScene: *const fn (ptr: *anyopaque, enable_smaa: bool, smaa_quality: SMAAQuality) void,
        /// Submits a batch of sprites, already ordered by the CPU batcher. The
        /// backend issues one instanced draw per (slot, blend) run.
        drawSprites: *const fn (ptr: *anyopaque, instances: []const SpriteInstance, count: usize) void,
        /// Creates a texture from RGBA8 pixels (atlas upload). Returns an opaque
        /// handle the backend understands in drawSprites (via the vertex's texture index).
        createTexture: *const fn (ptr: *anyopaque, width: u32, height: u32, pixels: []const u8) ?*anyopaque,
        /// Destroys a texture created by createTexture.
        destroyTexture: *const fn (ptr: *anyopaque, texture: ?*anyopaque) void,
    };

    pub fn beginFrame(self: Renderer) void {
        self.vtable.beginFrame(self.ptr);
    }
    pub fn acquireSurface(self: Renderer) void {
        self.vtable.acquireSurface(self.ptr);
    }
    pub fn drawQuad(self: Renderer, mvp: *const [16]f32) void {
        self.vtable.drawQuad(self.ptr, mvp);
    }
    pub fn present(self: Renderer) void {
        self.vtable.present(self.ptr);
    }
    pub fn resize(self: Renderer, width: u32, height: u32) void {
        self.vtable.resize(self.ptr, width, height);
    }
    pub fn stats(self: Renderer) *const FrameStats {
        return self.vtable.stats(self.ptr);
    }
    pub fn deinit(self: Renderer) void {
        self.vtable.deinit(self.ptr);
    }

    // ── M2 helpers ────────────────────────────────────────────────────────
    pub fn createOffscreenTarget(self: Renderer, width: u32, height: u32) OffscreenTarget {
        return self.vtable.createOffscreenTarget(self.ptr, width, height);
    }
    pub fn destroyOffscreenTarget(self: Renderer, target: OffscreenTarget) void {
        self.vtable.destroyOffscreenTarget(self.ptr, target);
    }
    pub fn beginScene(self: Renderer, target: OffscreenTarget, camera: Camera) void {
        self.vtable.beginScene(self.ptr, target, camera);
    }
    pub fn endScene(self: Renderer, enable_smaa: bool, smaa_quality: SMAAQuality) void {
        self.vtable.endScene(self.ptr, enable_smaa, smaa_quality);
    }
    pub fn drawSprites(self: Renderer, instances: []const SpriteInstance, count: usize) void {
        self.vtable.drawSprites(self.ptr, instances, count);
    }
    pub fn createTexture(self: Renderer, width: u32, height: u32, pixels: []const u8) ?*anyopaque {
        return self.vtable.createTexture(self.ptr, width, height, pixels);
    }
    pub fn destroyTexture(self: Renderer, texture: ?*anyopaque) void {
        self.vtable.destroyTexture(self.ptr, texture);
    }
};

/// Creates an orthographic camera covering `width` x `height` pixels.
pub fn makeCamera(width: f32, height: f32) Camera {
    // Ortho: left=-w/2, right=w/2, bottom=-h/2, top=h/2, near=-1, far=1
    const left = -width * 0.5;
    const right = width * 0.5;
    const bottom = -height * 0.5;
    const top = height * 0.5;
    const near = -1.0;
    const far = 1.0;

    // Column-major mat4: [sx 0 0 tx, 0 sy 0 ty, 0 0 sz tz, 0 0 0 1]
    const sx = 2.0 / (right - left);
    const sy = 2.0 / (top - bottom);
    const sz = -2.0 / (far - near);
    const tx = -(right + left) / (right - left);
    const ty = -(top + bottom) / (top - bottom);
    const tz = -(far + near) / (far - near);

    return Camera{
        .vp = .{
            sx, 0, 0, 0,
            0, sy, 0, 0,
            0, 0, sz, 0,
            tx, ty, tz, 1,
        },
        .viewport_w = @intFromFloat(width),
        .viewport_h = @intFromFloat(height),
    };
}

/// Creates a camera with custom view-projection (for editor viewport, etc.).
pub fn makeCameraCustom(vp: [16]f32, vp_x: u32, vp_y: u32, vp_w: u32, vp_h: u32) Camera {
    return Camera{
        .vp = vp,
        .viewport_x = vp_x,
        .viewport_y = vp_y,
        .viewport_w = vp_w,
        .viewport_h = vp_h,
    };
}

// Layout guard for the hand-written Dawn bindings.
//
// Three separate validation failures came from struct layouts that LOOKED
// right in Zig but did not match `webgpu.h` byte for byte: a missing
// `hasDynamicOffset`, `format` declared after `sampleCount`, and an invented
// `sampler_count` that shifted the array stride. These sizes are what the C
// header produces; if a binding ever changes, this fails at compile time
// instead of at 60 FPS on someone else's GPU.
test "dawn binding layouts match the C header" {
    const wgpu = @import("webgpu.zig");
    // WGPUBindGroupLayoutEntry, flattened: 8+4(pad)+8+4(pad) = 32, then
    // buffer (24) + sampler (16) + texture (24) + storageTexture (24) = 120.
    try std.testing.expectEqual(@as(usize, 120), @sizeOf(wgpu.BindGroupLayoutEntry));
    // WGPUBufferBindingLayout { ptr, u32, bool, pad, u64 }.
    try std.testing.expectEqual(@as(usize, 24), @sizeOf(struct {
        next: ?*anyopaque,
        ty: c_uint,
        dyn: wgpu.Bool,
        min: u64,
    }));
    // WGPUBindGroupEntry { ptr, u32, pad, buffer ptr, u64, u64, sampler, view }.
    try std.testing.expectEqual(@as(usize, 56), @sizeOf(wgpu.BindGroupEntry));
    // WGPUTexelCopyBufferLayout has NO nextInChain: 8 + 4 + 4.
    try std.testing.expectEqual(@as(usize, 16), @sizeOf(wgpu.TexelCopyBufferLayout));
    // WGPUBlendState has NO nextInChain either: 2 x BlendComponent (12) = 24.
    try std.testing.expectEqual(@as(usize, 24), @sizeOf(wgpu.BlendState));
}

test "quad has 4 vertices and valid indices" {
    try std.testing.expectEqual(@as(usize, 4), quad_vertices.len);
    for (quad_indices) |i| try std.testing.expect(i < quad_vertices.len);
}

test "sprite instance is 32 bytes (the 50k scene stays inside the 2 MB upload budget)" {
    try std.testing.expectEqual(@as(usize, 32), @sizeOf(SpriteInstance));
    try std.testing.expectEqual(@as(usize, 4), @alignOf(SpriteInstance));
    // spec §4: <= 2 MB/frame of staging uploads.
    try std.testing.expect(@as(usize, 32) * 50_000 <= 2 * 1024 * 1024);
}

test "unorm packing round-trips within its resolution" {
    try std.testing.expectEqual(@as(u16, 0), toUnorm16(0.0));
    try std.testing.expectEqual(@as(u16, 65535), toUnorm16(1.0));
    // Midpoint survives within 1/65535 (visually lossless).
    const mid = toUnorm16(0.5);
    try std.testing.expect(@abs(@as(f32, @floatFromInt(mid)) / 65535.0 - 0.5) < 0.001);
    try std.testing.expectEqual(@as(u8, 255), toUnorm8(1.0));
    try std.testing.expectEqual(@as(u8, 0), toUnorm8(0.0));
}

test "camera ortho matrix is correct" {
    const cam = makeCamera(800.0, 600.0);
    // Test that (0,0) maps to center of NDC
    const x = cam.vp[0] * 0.0 + cam.vp[4] * 0.0 + cam.vp[8] * 0.0 + cam.vp[12];
    const y = cam.vp[1] * 0.0 + cam.vp[5] * 0.0 + cam.vp[9] * 0.0 + cam.vp[13];
    try std.testing.expectApproxEqAbs(0.0, x, 0.0001);
    try std.testing.expectApproxEqAbs(0.0, y, 0.0001);
}