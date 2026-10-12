//! Dawn (WebGPU) backend — the real renderer (M0 + M2).
//!
//! Isolation (spec §7): only this file touches webgpu.zig.
//!
//! M2 pipeline, in this exact order (see `present`):
//! 1. **Scene pass** → offscreen color target (spec §7: the game ALWAYS renders
//!    to an offscreen target; the editor composites it into the viewport).
//!    Sprites arrive already sorted by the CPU batcher, so this is one pass
//!    with 1 draw call per (texture, blend) pair.
//! 2. **SMAA** (optional, 3 passes on the offscreen color) → same target's
//!    second color attachment... no: SMAA resolves into the swapchain. The
//!    edge and weight passes use two half-resolution scratch targets so the
//!    post cost is ~0.2 ms on the reference iGPU instead of 3 full-res passes.
//! 3. **Present** → swapchain.
//!
//! Every GPU object (pipelines, buffers, textures, bind groups) is created at
//! BOOT or on RESIZE only — never inside a frame (spec §3.6). The frame loop
//! only calls writeBuffer + record + submit.
//!
//! Profiling (spec §4): per-pass GPU timestamps chained into every render pass,
//! resolved and read back with 2 frames of latency and a non-blocking map poll.

const std = @import("std");
const render = @import("render.zig");
const wgpu = @import("webgpu.zig");
const platform = @import("../platform/platform.zig");
const log = @import("core").log.scoped("render");

const quad_wgsl = @embedFile("shaders/quad.wgsl");
const light_wgsl = @embedFile("shaders/light.wgsl");
const sprite_wgsl = @embedFile("shaders/sprite.wgsl");
const smaa_wgsl = @embedFile("shaders/smaa.wgsl");
const post_wgsl = @embedFile("shaders/post.wgsl");

// Dawn ships the C API as a dispatch table (libdawn_proc) whose default
// procs are null stubs; the real implementation lives in libdawn_native.
const DawnProcTable = opaque {};
extern fn dawnProcSetProcs(procs: *const DawnProcTable) void;
extern fn _ZN4dawn6native15GetProcsAutogenEv() *const DawnProcTable;

fn initProcTable() void {
    dawnProcSetProcs(_ZN4dawn6native15GetProcsAutogenEv());
}

/// Context for the requestAdapter callback (boot, single-threaded).
const AdapterCtx = struct {
    adapter: ?wgpu.WGPUAdapter = null,
};

fn adapterCallback(
    status: c_uint,
    adapter: ?wgpu.WGPUAdapter,
    message: wgpu.StringView,
    userdata1: ?*anyopaque,
    userdata2: ?*anyopaque,
) callconv(.c) void {
    _ = userdata2;
    const ctx: *AdapterCtx = @ptrCast(@alignCast(userdata1.?));
    if (status == wgpu.RequestAdapterStatus_Success) {
        ctx.adapter = adapter;
    } else {
        const msg: []const u8 = if (message.data) |p| p[0..message.length] else "no detail";
        log.err("requestAdapter failed (status {d}): {s}", .{ status, msg });
    }
}

/// Context for the requestDevice callback (boot, single-threaded).
const DeviceCtx = struct {
    device: ?wgpu.WGPUDevice = null,
};

fn deviceCallback(
    status: c_uint,
    device: ?wgpu.WGPUDevice,
    message: wgpu.StringView,
    userdata1: ?*anyopaque,
    userdata2: ?*anyopaque,
) callconv(.c) void {
    _ = userdata2;
    const ctx: *DeviceCtx = @ptrCast(@alignCast(userdata1.?));
    if (status == wgpu.RequestDeviceStatus_Success) {
        ctx.device = device;
    } else {
        const msg: []const u8 = if (message.data) |p| p[0..message.length] else "no detail";
        log.err("requestDevice failed (status {d}): {s}", .{ status, msg });
    }
}

/// Uncaptured GPU errors are logged, never swallowed.
fn deviceErrorCallback(
    device: ?wgpu.WGPUDevice,
    error_type: c_uint,
    message: wgpu.StringView,
    userdata1: ?*anyopaque,
    userdata2: ?*anyopaque,
) callconv(.c) void {
    _ = device;
    _ = userdata1;
    _ = userdata2;
    const msg: []const u8 = if (message.data) |p| p[0..message.length] else "no detail";
    log.err("WebGPU error (type {d}): {s}", .{ error_type, msg });
}

/// The map callback only reports failures: the frames themselves are polled
/// with WaitAny(0) from beginFrame, so the frame never blocks on the GPU.
fn mapCallback(
    status: c_uint,
    message: wgpu.StringView,
    ud1: ?*anyopaque,
    ud2: ?*anyopaque,
) callconv(.c) void {
    _ = ud1;
    _ = ud2;
    if (status != wgpu.MapAsyncStatus_Success) {
        const msg: []const u8 = if (message.data) |p| p[0..message.length] else "no detail";
        log.warn("timestamp readback map failed (status {d}): {s}", .{ status, msg });
    }
}

pub const Options = struct {
    /// true = Fifo (vsync). false = Immediate/Mailbox when the surface
    /// supports it: required to measure unthrottled CPU cost.
    vsync: bool = true,
    /// Enable SMAA 1x post-process (ROADMAP M2: default on).
    smaa: bool = true,
    /// SMAA quality (thresholds only; the passes are the same 3).
    smaa_quality: render.SMAAQuality = .Medium,
    /// Max sprites per frame; sizes the batch vertex buffer at boot.
    max_sprites: u32 = 65536,
    /// Max lights per frame; sizes the M7 instance buffer at boot.
    max_lights: u32 = 4096,
};

/// Readback slots. The resolve of frame N is READ at frame N+2 (map issued)
/// and the data GENERALLY lands on N+3, so a slot is busy for ~3 frames while
/// it is reused every SLOTS frames. With SLOTS=3 the reuse always raced the
/// drain and every third resolve was skipped (stale GPU times); 6 gives the
/// map round-trip room. Costs 12 tiny buffers.
const SLOTS = 6;
/// 2 timestamps per instrumented pass. M2 instruments: scene, smaa_edge,
/// smaa_weights, smaa_blend, present-composite = 5 passes → 10 slots.
const GPU_TIMESTAMP_SLOTS: u32 = 12;
/// Nanoseconds per TSC-style tick for the query results. On Vulkan the
/// timestamp period is a device property; 1.0 ns is what desktop GPUs report
/// and is what Dawn's backends use. If a device reported something else, the
/// numbers would be uniformly scaled — the comparison across frames holds.
const GPU_TIMESTAMP_PERIOD_NS: f64 = 1.0;

const ReadbackState = enum { idle, mapping, ready };

const Slot = struct {
    resolve_buf: wgpu.WGPUBuffer = undefined,
    readback_buf: wgpu.WGPUBuffer = undefined,
    future: wgpu.Future = .{},
    state: ReadbackState = .idle,
    frame_index: u64 = 0,
    used: bool = false,
};

/// A texture uploaded from CPU pixels (an atlas). Created at load time only.
const AtlasTexture = struct {
    texture: wgpu.WGPUTexture,
    view: wgpu.WGPUTextureView,
    bind_group: wgpu.WGPUBindGroup,
    width: u32,
    height: u32,
};

/// The offscreen target: color + depth/stencil, plus the half-res SMAA scratch.
const Offscreen = struct {
    width: u32,
    height: u32,
    // Filled in createOffscreenTarget; `undefined` here is only a placeholder
    // for the allocator (nothing may read the struct before that function
    // finishes, or it reads garbage).
    color: wgpu.WGPUTexture = undefined,
    color_view: wgpu.WGPUTextureView = undefined,
    /// Which sprite layer each pixel is on, written by the sprite pass as a
    /// second colour attachment and read by the light pass for `item_cull_mask`.
    ///
    /// R8Unorm, not an integer format: R8Unorm is renderable on every backend
    /// that can render to R8 at all, and the one `* 255` on the read side is
    /// cheaper than a format some drivers refuse.
    layer: wgpu.WGPUTexture = undefined,
    layer_view: wgpu.WGPUTextureView = undefined,
    depth: wgpu.WGPUTexture = undefined,
    depth_view: wgpu.WGPUTextureView = undefined,
    /// SMAA pass 1 output (edge directions), half resolution.
    edge: wgpu.WGPUTexture = undefined,
    edge_view: wgpu.WGPUTextureView = undefined,
    /// SMAA pass 2 output (blend weights), half resolution.
    weights: wgpu.WGPUTexture = undefined,
    weights_view: wgpu.WGPUTextureView = undefined,
    /// The post pass's output, full resolution.
    ///
    /// A separate texture rather than an in-place pass because a post pass reads
    /// the frame it is modifying, and reading and writing one texture in a
    /// single pass is undefined rather than merely slow. When the post pass is
    /// off this is never written, and SMAA reads `color` instead.
    post: wgpu.WGPUTexture = undefined,
    post_view: wgpu.WGPUTextureView = undefined,
    /// Bloom's two half-resolution ping-pong buffers.
    bloom_a: wgpu.WGPUTexture = undefined,
    bloom_a_view: wgpu.WGPUTextureView = undefined,
    bloom_b: wgpu.WGPUTexture = undefined,
    bloom_b_view: wgpu.WGPUTextureView = undefined,
    /// Bind groups that reference the views (recreated with the target).
    smaa_edge_bind: wgpu.WGPUBindGroup = undefined,
    smaa_weights_bind: wgpu.WGPUBindGroup = undefined,
    smaa_blend_bind: wgpu.WGPUBindGroup = undefined,
    /// M7: one per post pipeline. All five share a bind group LAYOUT but bind
    /// different textures, so a pass that does not read `bloom_tex` still has to
    /// name something for it.
    post_bright_bind: wgpu.WGPUBindGroup = undefined,
    post_blur_h_bind: wgpu.WGPUBindGroup = undefined,
    post_blur_v_bind: wgpu.WGPUBindGroup = undefined,
    post_composite_bind: wgpu.WGPUBindGroup = undefined,
    /// SMAA's groups rebuilt against the POST output, created on first use and
    /// released with the rest. Null until a frame actually needs them.
    smaa_post_edge_bind: ?wgpu.WGPUBindGroup = null,
    smaa_post_blend_bind: ?wgpu.WGPUBindGroup = null,
};

pub const Backend = struct {
    allocator: std.mem.Allocator,
    instance: wgpu.WGPUInstance,
        // M7: the light pass's own resources. One pipeline per blend mode, one
        // instance buffer, one uniform buffer, one shadow-map texture, one bind
        // group. All of them created here and re-used, so spec §3.6 holds.
        light_pipeline_add: wgpu.WGPURenderPipeline = undefined,
        light_pipeline_sub: wgpu.WGPURenderPipeline = undefined,
        light_pipeline_mix: wgpu.WGPURenderPipeline = undefined,
        light_instance_buf: wgpu.WGPUBuffer = undefined,
        light_uniform_buf: wgpu.WGPUBuffer = undefined,
        /// Null until `createShadowMap` has run; a shadow map is created once
        /// and re-uploaded, never per frame (spec §3.6).
        light_shadow_texture: ?wgpu.WGPUTexture = null,
        light_shadow_view: ?wgpu.WGPUTextureView = null,
        light_bind_group: wgpu.WGPUBindGroup = undefined,
        /// The shadow map's width in angle buckets; zero until it is created.
        light_shadow_angles: u32 = 0,
        /// How many shadow-map textures this backend has actually built.
        ///
        /// A counter and not a comment, because "it is created once" is exactly
        /// the kind of claim that was false for a long time and looked fine: the
        /// function was called every frame and created a texture every frame,
        /// right underneath a comment saying it did not. Spec §3.6 says nothing
        /// may be created inside a frame, so the number is the check.
        shadow_map_creations: u64 = 0,
        /// The GI cascade. Starts as the 1x1 opaque-black placeholder created at
        /// boot, and is REPLACED when the pyramid's dimensions change -- which is
        /// why the bind group is rebuilt alongside it and not once at boot.
        light_gi_texture: wgpu.WGPUTexture = undefined,
        light_gi_view: wgpu.WGPUTextureView = undefined,
        light_gi_sampler: wgpu.WGPUSampler = undefined,
        light_gi_bgl: wgpu.WGPUBindGroupLayout = undefined,
        /// M7: the post pass's resources. Five pipelines off one module, one
        /// bind group LAYOUT, and four bind groups that live on the Offscreen
        /// because they name its textures.
        post_bgl: wgpu.WGPUBindGroupLayout = undefined,
        post_pipeline_bright: wgpu.WGPURenderPipeline = undefined,
        post_pipeline_blur_h: wgpu.WGPURenderPipeline = undefined,
        post_pipeline_blur_v: wgpu.WGPURenderPipeline = undefined,
        post_pipeline_composite: wgpu.WGPURenderPipeline = undefined,
        post_pipeline_copy: wgpu.WGPURenderPipeline = undefined,
        post_uniform_buf: wgpu.WGPUBuffer = undefined,
        /// How many post passes the last frame ran. Zero for a scene that has not
        /// enabled anything, and the number a profile is read against: four for
        /// bloom, one for fog or tonemap alone.
        post_passes: u32 = 0,
        light_gi_w: u32 = 1,
        light_gi_h: u32 = 1,
        /// The offscreen target's LAYER view, which is what `item_cull_mask` is
        /// tested against. Null until a target exists, so the boot bind group
        /// carries a 1x1 placeholder instead — a bind group that names a view
        /// that does not exist yet is not a thing you can build.
        light_layer_view: ?wgpu.WGPUTextureView = null,
        /// The cascade's world-space rectangle, republished into the uniform on
        /// every upload because it moves with the camera.
        gi_rect: [4]f32 = .{ 0, 0, 1, 1 },
        environment: render.SceneEnvironment = .{},
        /// Which light the last drawLights call actually drew. Reported through
        /// FrameStats so a scene with no lights can be told apart from a pass
        /// that was never called.
        lights_drawn: u32 = 0,
        light_instance_capacity: u32 = 0,

    adapter: wgpu.WGPUAdapter,
    device: wgpu.WGPUDevice,
    queue: wgpu.WGPUQueue,
    surface: wgpu.WGPUSurface,
    format: c_uint,

    // ── M0 legacy quad pipeline (kept: the runtime's fallback path) ────────
    quad_shader: wgpu.WGPUShaderModule,
    quad_bgl: wgpu.WGPUBindGroupLayout,
    quad_layout: wgpu.WGPUPipelineLayout,
    quad_pipeline: wgpu.WGPURenderPipeline,
    quad_bind_group: wgpu.WGPUBindGroup,
    quad_uniform_buf: wgpu.WGPUBuffer,
    quad_vertex_buf: wgpu.WGPUBuffer,
    quad_index_buf: wgpu.WGPUBuffer,

    // ── M2 sprite pipeline ─────────────────────────────────────────────────
    sprite_shader: wgpu.WGPUShaderModule,
    sprite_bgl: wgpu.WGPUBindGroupLayout,
    sprite_layout: wgpu.WGPUPipelineLayout,
    /// Textured + solid variants, and the alpha/additive blend variants.
    sprite_pipeline_textured: wgpu.WGPURenderPipeline,
    sprite_pipeline_solid: wgpu.WGPURenderPipeline,
    sprite_pipeline_additive: wgpu.WGPURenderPipeline,
    sprite_uniform_buf: wgpu.WGPUBuffer,
    /// Dynamic instance buffer: max_sprites x 32 bytes, written once per
    /// frame. 65536 sprites = 2 MB, the ceiling of spec §4.
    sprite_instance_buf: wgpu.WGPUBuffer,
    sprite_instance_capacity: u32,
    sampler: wgpu.WGPUSampler,
    /// Fallback 1x1 white texture so a sprite with no atlas still draws.
    white_tex: wgpu.WGPUTexture,
    white_view: wgpu.WGPUTextureView,
    white_bind_group: wgpu.WGPUBindGroup,
    /// Uploaded atlases, indexed by the sprite's texture slot.
    atlases: std.ArrayList(?AtlasTexture) = .empty,
    atlas_allocator: std.mem.Allocator,

    // ── M2 SMAA pipelines ──────────────────────────────────────────────────
    smaa_shader: wgpu.WGPUShaderModule,
    smaa_bgl: wgpu.WGPUBindGroupLayout,
    smaa_layout: wgpu.WGPUPipelineLayout,
    smaa_pipeline_edge: wgpu.WGPURenderPipeline,
    smaa_pipeline_weights: wgpu.WGPURenderPipeline,
    smaa_pipeline_blend: wgpu.WGPURenderPipeline,
    /// Plain copy (composition when SMAA is off / editor viewport blit).
    smaa_pipeline_copy: wgpu.WGPURenderPipeline,
    smaa_uniform_buf: wgpu.WGPUBuffer,
    /// params uniform for pass 3 (texel + edge direction).
    smaa_blend_uniform_buf: wgpu.WGPUBuffer,

    // ── Frame state ────────────────────────────────────────────────────────
    width: u32,
    height: u32,
    offscreen: ?*Offscreen = null,
    /// Set by `resize`: the current target no longer matches the surface.
    offscreen_stale: bool = false,
    smaa_quality: render.SMAAQuality = .Medium,
    smaa_enabled: bool = true,

    /// True between a successful surface acquire and the matching present.
    acquired: bool = false,
    /// Texture acquired for the current frame (released after the view).
    surface_texture: ?wgpu.WGPUTexture = null,
    surface_acquires: u64 = 0,
    frames: u64 = 0,
    quads_drawn: u64 = 0,
    sprites_drawn: u64 = 0,
    present_mode: c_uint = wgpu.PresentMode_Fifo,
    /// Scene pass state (beginScene → drawSprites → endScene).
    scene_active: bool = false,
    scene_camera: render.Camera = .{},
    scene_target: ?*Offscreen = null,

    // ── GPU timestamps ──────────────────────────────────────────────────────
    timestamps: bool = false,
    query_set: ?wgpu.WGPUQuerySet = null,
    slots: [SLOTS]Slot = [_]Slot{.{}} ** SLOTS,
    /// GPU ns of the frame measured 2 frames ago (0 = nothing yet).
    gpu_ns_last: u64 = 0,
    gpu_pass_count: u32 = 0,
    /// Timestamp index cursor within the frame (2 per instrumented pass).
    ts_cursor: u32 = 0,

    stats_data: render.FrameStats = .{},

    /// 64 bytes of MVP + alignment headroom (min uniform binding size).
    const UniformSize: u64 = 256;
    /// 2 u64 timestamps per instrumented pass.
    const TimestampBytes: u64 = GPU_TIMESTAMP_SLOTS * @sizeOf(u64);
    /// Instance record: pos(8) + half(8) + uv4xu16(8) + color4xu8(4) + slot(1)
    /// + pad(3) = 32 bytes, exactly @sizeOf(render.SpriteInstance).
    const SpriteInstanceBytes: u32 = 32;
    /// `Globals` in light.wgsl: mat4(64) + vec2 + vec2 + vec4(16) + vec4(16)
    /// + vec4(16) = 128. The last two are the GI cascade's rectangle and the
    /// sky; both are here rather than in the instance because they are the
    /// same for every light in the frame, and per-instance means per-vertex.
    const LightUniformBytes: u64 = 128;
    /// `LightInstance` in light.zig: pos(8) + radius + shadow_ratio(8) +
    /// half(8) + angle + cos_outer + cos_inner + energy(16) + color(16) +
    /// attenuation + softness + gi + flags(16) = 72.
    ///
    /// Derived from the struct rather than written down again. The two used to
    /// be separate numbers and they DISAGREED: the struct was 68 bytes and the
    /// shader read offsets laid out for 72, so every light reached the GPU with
    /// its half extents where its colour goes. One definition cannot drift.
    const LightInstanceBytes: u64 = @sizeOf(render.light_mod.LightInstance);
    /// Globals uniform: mat4 (64) + texel (8) + inverse (8) + pad(8) = 88 → 96.
    const SpriteUniformBytes: u64 = 96;
    /// SMAA `EdgeUniforms`: 2 x vec2f = 24 bytes.
    const SmaaUniformBytes: u64 = 24;
    /// `PostParams`: texel(8) + inv(8) + bloom_texel(8) + exposure(4) +
    /// fog(8) + fog_color(16) + flags(16) + focus(8) + pad(8) = 96 bytes.
    const PostUniformBytes: u64 = 96;

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

    pub fn create(
        allocator: std.mem.Allocator,
        native: platform.NativeHandle,
        width: u32,
        height: u32,
        options: Options,
    ) !*Backend {
        initProcTable();

        // TimedWaitAny enables wgpuInstanceWaitAny(timeoutNS > 0), which the
        // synchronous boot below relies on.
        const instance_features = [_]c_uint{wgpu.InstanceFeatureName_TimedWaitAny};
        const instance = wgpu.wgpuCreateInstance(&.{
            .requiredFeatureCount = instance_features.len,
            .requiredFeatures = @ptrCast(&instance_features),
        }) orelse return error.InstanceCreationFailed;

        // Surface from the platform handle (the chain structs live on the
        // stack during the call, as the C API requires).
        var xlib: wgpu.SurfaceSourceXlibWindow = undefined;
        var wayland: wgpu.SurfaceSourceWaylandSurface = undefined;
        var surf_desc = wgpu.SurfaceDescriptor{};
        switch (native) {
            .x11 => |h| {
                xlib = .{
                    .chain = .{ .sType = wgpu.SType_SurfaceSourceXlibWindow },
                    .display = h.display,
                    .window = h.window,
                };
                surf_desc.nextInChain = @ptrCast(&xlib.chain);
            },
            .wayland => |h| {
                wayland = .{
                    .chain = .{ .sType = wgpu.SType_SurfaceSourceWaylandSurface },
                    .display = h.display,
                    .surface = h.surface,
                };
                surf_desc.nextInChain = @ptrCast(&wayland.chain);
            },
        }
        const surface = wgpu.wgpuInstanceCreateSurface(instance, &surf_desc) orelse return error.SurfaceCreationFailed;

        // Adapter: async request + WaitAny (boot is single-threaded).
        var adapter_ctx = AdapterCtx{};
        const adapter_future = wgpu.wgpuInstanceRequestAdapter(instance, &.{
            .compatibleSurface = surface,
        }, .{
            .mode = wgpu.CallbackMode_WaitAnyOnly,
            .callback = adapterCallback,
            .userdata1 = &adapter_ctx,
        });
        var adapter_wait = [_]wgpu.FutureWaitInfo{.{ .future = adapter_future }};
        const adapter_status = wgpu.wgpuInstanceWaitAny(instance, 1, &adapter_wait, 5 * std.time.ns_per_s);
        if (adapter_status != wgpu.WaitStatus_Success or adapter_ctx.adapter == null) {
            return error.AdapterRequestFailed;
        }
        const adapter = adapter_ctx.adapter.?;

        // Device: same async request + WaitAny pattern. The TimestampQuery
        // feature is requested only if the adapter has it (§4: mandatory in
        // debug, and the report says when it is missing).
        const want_timestamps = wgpu.wgpuAdapterHasFeature(adapter, wgpu.FeatureName_TimestampQuery) != 0;
        var device_ctx = DeviceCtx{};
        const ts_features = [_]c_uint{wgpu.FeatureName_TimestampQuery};
        const device_desc = wgpu.DeviceDescriptor{
            .label = wgpu.StringView.from("ember"),
            .requiredFeatureCount = if (want_timestamps) 1 else 0,
            .requiredFeatures = if (want_timestamps) @ptrCast(&ts_features) else null,
            .uncaptured_callback = deviceErrorCallback,
        };
        const device_future = wgpu.wgpuAdapterRequestDevice(adapter, &device_desc, .{
            .mode = wgpu.CallbackMode_WaitAnyOnly,
            .callback = deviceCallback,
            .userdata1 = &device_ctx,
        });
        var device_wait = [_]wgpu.FutureWaitInfo{.{ .future = device_future }};
        const device_status = wgpu.wgpuInstanceWaitAny(instance, 1, &device_wait, 5 * std.time.ns_per_s);
        if (device_status != wgpu.WaitStatus_Success or device_ctx.device == null) {
            return error.DeviceRequestFailed;
        }
        const device = device_ctx.device.?;
        const timestamps = want_timestamps and wgpu.wgpuDeviceHasFeature(device, wgpu.FeatureName_TimestampQuery) != 0;

        const queue = wgpu.wgpuDeviceGetQueue(device) orelse return error.QueueCreationFailed;

        // Surface format: the first one the capabilities report.
        var caps = wgpu.SurfaceCapabilities{};
        if (wgpu.wgpuSurfaceGetCapabilities(surface, adapter, &caps) != wgpu.Status_Success or
            caps.formatCount == 0 or caps.formats == null)
        {
            return error.SurfaceCapabilitiesFailed;
        }
        const format = caps.formats.?[0];
        // Present modes must be read BEFORE FreeMembers releases the array.
        var present_mode: c_uint = wgpu.PresentMode_Fifo;
        var have_immediate = false;
        var have_mailbox = false;
        if (caps.presentModes) |modes| {
            if (caps.presentModeCount > 0) {
                have_immediate = containsMode(modes[0..caps.presentModeCount], wgpu.PresentMode_Immediate);
                have_mailbox = containsMode(modes[0..caps.presentModeCount], wgpu.PresentMode_Mailbox);
            }
        }
        wgpu.wgpuSurfaceCapabilitiesFreeMembers(caps);
        if (!options.vsync) {
            // Prefer Immediate (no vsync); Mailbox is the next best thing.
            if (have_immediate) {
                present_mode = wgpu.PresentMode_Immediate;
            } else if (have_mailbox) {
                present_mode = wgpu.PresentMode_Mailbox;
            } else {
                log.warn("vsync off requested, but the surface only supports Fifo", .{});
            }
        }
        log.info("dawn backend ready — surface format: 0x{x}, present mode: {d}, timestamps: {}, smaa {s}", .{
            format,
            present_mode,
            timestamps,
            if (options.smaa) "on" else "off",
        });

        var resources_created: u64 = 0;

        // ── M0 quad resources (static buffers; spec §3.6) ───────────────────
        const vertex_buf = wgpu.wgpuDeviceCreateBuffer(device, &.{
            .usage = wgpu.BufferUsage_Vertex | wgpu.BufferUsage_CopyDst,
            .size = @sizeOf(@TypeOf(render.quad_vertices)),
        }) orelse return error.BufferCreationFailed;
        resources_created += 1;
        wgpu.wgpuQueueWriteBuffer(queue, vertex_buf, 0, &render.quad_vertices, @sizeOf(@TypeOf(render.quad_vertices)));

        const index_buf = wgpu.wgpuDeviceCreateBuffer(device, &.{
            .usage = wgpu.BufferUsage_Index | wgpu.BufferUsage_CopyDst,
            .size = @sizeOf(@TypeOf(render.quad_indices)),
        }) orelse return error.BufferCreationFailed;
        resources_created += 1;
        wgpu.wgpuQueueWriteBuffer(queue, index_buf, 0, &render.quad_indices, @sizeOf(@TypeOf(render.quad_indices)));

        const uniform_buf = wgpu.wgpuDeviceCreateBuffer(device, &.{
            .usage = wgpu.BufferUsage_Uniform | wgpu.BufferUsage_CopyDst,
            .size = UniformSize,
        }) orelse return error.BufferCreationFailed;
        resources_created += 1;

        const quad_shader = try createShader(device, quad_wgsl, "quad.wgsl");
        resources_created += 1;

        const quad_bgl = try createBindGroupLayout(device, &[_]wgpu.BindGroupLayoutEntry{.{
            .binding = 0,
            .visibility = wgpu.ShaderStage_Vertex | wgpu.ShaderStage_Fragment,
            .buffer_type = wgpu.BufferBindingType_Uniform,
            .buffer_minBindingSize = 64,
        }}, "quad.bgl");
        resources_created += 1;

        const quad_layout = try createPipelineLayout(device, &[_]wgpu.WGPUBindGroupLayout{quad_bgl}, "quad.layout");
        resources_created += 1;

        const vertex_attrs = [_]wgpu.VertexAttribute{
            .{ .format = wgpu.VertexFormat_Float32x2, .offset = 0, .shaderLocation = 0 },
            .{ .format = wgpu.VertexFormat_Float32x4, .offset = 8, .shaderLocation = 1 },
        };
        const vertex_layout = wgpu.VertexBufferLayout{
            .stepMode = wgpu.VertexStepMode_Vertex,
            .arrayStride = 24,
            .attributeCount = 2,
            .attributes = &vertex_attrs,
        };
        const targets = [_]wgpu.ColorTargetState{.{ .format = format }};
        const fragment = wgpu.FragmentState{
            .module = quad_shader,
            .entryPoint = wgpu.StringView.from("fs_main"),
            .targetCount = 1,
            .targets = &targets,
        };
        const quad_pipeline = wgpu.wgpuDeviceCreateRenderPipeline(device, &.{
            .layout = quad_layout,
            .vertex_module = quad_shader,
            .vertex_entryPoint = wgpu.StringView.from("vs_main"),
            .vertex_bufferCount = 1,
            .vertex_buffers = @ptrCast(&vertex_layout),
            .fragment = &fragment,
        }) orelse return error.PipelineCreationFailed;
        resources_created += 1;

        const quad_bind_group = try createBindGroup(device, quad_bgl, &[_]wgpu.BindGroupEntry{.{
            .binding = 0,
            .buffer = uniform_buf,
            .offset = 0,
            .size = 64,
        }}, "quad.bg");
        resources_created += 1;

        // ── M2 sprite resources ─────────────────────────────────────────────
        const sprite_shader = try createShader(device, sprite_wgsl, "sprite.wgsl");
        resources_created += 1;

        // Bind group layout: 0 = globals uniform, 1 = atlas texture, 2 = sampler.
        const sprite_bgl = try createBindGroupLayout(device, &[_]wgpu.BindGroupLayoutEntry{
            .{
                .binding = 0,
                .visibility = wgpu.ShaderStage_Vertex | wgpu.ShaderStage_Fragment,
                .buffer_type = wgpu.BufferBindingType_Uniform,
                // Must equal the shader's `Globals` size (mat4 + 4 x vec2 = 96),
                // not the 64 bytes of the mat4 alone: Dawn validates the whole
                // struct against this number.
                .buffer_minBindingSize = SpriteUniformBytes,
            },
            .{
                .binding = 1,
                .visibility = wgpu.ShaderStage_Fragment,
                .buffer_type = 0, // BindingNotUsed: this entry is a texture
                .texture_sampleType = wgpu.TextureSampleType_Float,
                .texture_viewDimension = wgpu.TextureViewDimension_2D,
            },
            .{
                .binding = 2,
                .visibility = wgpu.ShaderStage_Fragment,
                .buffer_type = 0, // BindingNotUsed: this entry is a sampler
                .sampler_type = wgpu.SamplerBindingType_Filtering,
            },
        }, "sprite.bgl");
        resources_created += 1;

        const sprite_layout = try createPipelineLayout(device, &[_]wgpu.WGPUBindGroupLayout{sprite_bgl}, "sprite.layout");
        resources_created += 1;

        const sprite_uniform_buf = wgpu.wgpuDeviceCreateBuffer(device, &.{
            .usage = wgpu.BufferUsage_Uniform | wgpu.BufferUsage_CopyDst,
            .size = SpriteUniformBytes,
        }) orelse return error.BufferCreationFailed;
        resources_created += 1;

        // Dynamic instance buffer: 32 bytes per sprite, sized at boot.
        const sprite_instance_buf = wgpu.wgpuDeviceCreateBuffer(device, &.{
            .label = wgpu.StringView.from("sprite.instances"),
            .usage = wgpu.BufferUsage_Vertex | wgpu.BufferUsage_CopyDst,
            .size = @as(u64, options.max_sprites) * SpriteInstanceBytes,
        }) orelse return error.BufferCreationFailed;
        resources_created += 1;

        // Filtering sampler (atlas textures are RGBA8, filterable).
        const sampler = wgpu.wgpuDeviceCreateSampler(device, &.{
            .magFilter = wgpu.FilterMode_Linear,
            .minFilter = wgpu.FilterMode_Linear,
            .addressModeU = wgpu.AddressMode_ClampToEdge,
            .addressModeV = wgpu.AddressMode_ClampToEdge,
        }) orelse return error.SamplerCreationFailed;
        resources_created += 1;

        // 1x1 white fallback texture (solid sprites draw without an atlas).
        const white_tex = wgpu.wgpuDeviceCreateTexture(device, &.{
            .usage = wgpu.TextureUsage_TextureBinding | wgpu.TextureUsage_CopyDst,
            .dimension = wgpu.TextureDimension_2D,
            .size = .{ .width = 1, .height = 1 },
            .format = wgpu.TextureFormat_RGBA8Unorm,
        }) orelse return error.TextureCreationFailed;
        resources_created += 1;
        const white_view = wgpu.wgpuTextureCreateView(white_tex, null) orelse return error.TextureViewCreationFailed;
        resources_created += 1;
        {
            const white_pixel = [_]u8{ 255, 255, 255, 255 };
            const dst = wgpu.TexelCopyTextureInfo{ .texture = white_tex };
            const layout = wgpu.TexelCopyBufferLayout{ .bytesPerRow = 4, .rowsPerImage = 1 };
            const size = wgpu.Extent3D{ .width = 1, .height = 1 };
            wgpu.wgpuQueueWriteTexture(queue, &dst, &white_pixel, 4, &layout, &size);
        }
        const white_bind_group = try createBindGroup(device, sprite_bgl, &[_]wgpu.BindGroupEntry{
            .{ .binding = 0, .buffer = sprite_uniform_buf, .offset = 0, .size = SpriteUniformBytes },
            .{ .binding = 1, .textureView = white_view },
            .{ .binding = 2, .sampler = @ptrCast(sampler) },
        }, "sprite.white");
        resources_created += 1;

        // Pipelines: textured (alpha blend), solid (no texture), additive.
        // Instance layout: one 32-byte record per sprite, stepping per INSTANCE.
        // The 4 quad corners come from @builtin(vertex_index), so this is the
        // only vertex buffer in the pipeline.
        const sprite_instance_attrs = [_]wgpu.VertexAttribute{
            .{ .format = wgpu.VertexFormat_Float32x2, .offset = 0, .shaderLocation = 0 },
            .{ .format = wgpu.VertexFormat_Float32x2, .offset = 8, .shaderLocation = 1 },
            .{ .format = wgpu.VertexFormat_Unorm16x4, .offset = 16, .shaderLocation = 2 },
            .{ .format = wgpu.VertexFormat_Unorm8x4, .offset = 24, .shaderLocation = 3 },
            .{ .format = wgpu.VertexFormat_Uint32, .offset = 28, .shaderLocation = 4 },
            // The light layer, in the byte `SpriteInstance` used to pad. One
            // attribute for one byte rather than folding it into the u32 above,
            // because slot and shape already share that word and a third field
            // there would mean a shift at every vertex.
            .{ .format = wgpu.VertexFormat_Uint8, .offset = 30, .shaderLocation = 5 },
        };
        const sprite_vlayout = wgpu.VertexBufferLayout{
            .stepMode = wgpu.VertexStepMode_Instance,
            .arrayStride = SpriteInstanceBytes,
            .attributeCount = 6,
            .attributes = &sprite_instance_attrs,
        };

        // Alpha blend state (src alpha, one-minus-src alpha).
        var blend = wgpu.BlendState{
            .color = .{ .operation = wgpu.BlendOperation_Add, .srcFactor = wgpu.BlendFactor_SrcAlpha, .dstFactor = wgpu.BlendFactor_OneMinusSrcAlpha },
            .alpha = .{ .operation = wgpu.BlendOperation_Add, .srcFactor = wgpu.BlendFactor_One, .dstFactor = wgpu.BlendFactor_OneMinusSrcAlpha },
        };
        // Two targets. The colour one blends; the layer one does NOT, which is
        // what makes it a replace -- and a replace is right, because the layer is
        // not an accumulation. It is which sprite is ON TOP, and the scene
        // already resolved that with the painter's algorithm. Blending two
        // layers would produce a number that is neither.
        const alpha_target = [_]wgpu.ColorTargetState{
            .{ .format = format, .blend = @ptrCast(&blend) },
            .{ .format = wgpu.TextureFormat_R8Unorm },
        };
        const sprite_fragment_textured = wgpu.FragmentState{
            .module = sprite_shader,
            .entryPoint = wgpu.StringView.from("fs_main"),
            .targetCount = 1,
            .targets = &alpha_target,
        };
        const sprite_pipeline_textured = wgpu.wgpuDeviceCreateRenderPipeline(device, &.{
            .label = wgpu.StringView.from("sprite.textured"),
            .layout = sprite_layout,
            .primitive_topology = wgpu.PrimitiveTopology_TriangleStrip,
            .vertex_module = sprite_shader,
            .vertex_entryPoint = wgpu.StringView.from("vs_main"),
            .vertex_bufferCount = 1,
            .vertex_buffers = @ptrCast(&sprite_vlayout),
            .fragment = &sprite_fragment_textured,
        }) orelse return error.PipelineCreationFailed;
        resources_created += 1;

        // Solid (untextured) variant: no alpha blend needed, writes opaque.
        const solid_target = [_]wgpu.ColorTargetState{
            .{ .format = format },
            .{ .format = wgpu.TextureFormat_R8Unorm },
        };
        const sprite_fragment_solid = wgpu.FragmentState{
            .module = sprite_shader,
            .entryPoint = wgpu.StringView.from("fs_main_solid"),
            .targetCount = 1,
            .targets = &solid_target,
        };
        const sprite_pipeline_solid = wgpu.wgpuDeviceCreateRenderPipeline(device, &.{
            .label = wgpu.StringView.from("sprite.solid"),
            .layout = sprite_layout,
            .primitive_topology = wgpu.PrimitiveTopology_TriangleStrip,
            .vertex_module = sprite_shader,
            .vertex_entryPoint = wgpu.StringView.from("vs_main"),
            .vertex_bufferCount = 1,
            .vertex_buffers = @ptrCast(&sprite_vlayout),
            .fragment = &sprite_fragment_solid,
        }) orelse return error.PipelineCreationFailed;
        resources_created += 1;


        // ── M7: the light pass ───────────────────────────────────────────────
        // One instanced quad per light, one pipeline per blend mode. The three
        // modes are three pipelines because `mix` is a lerp only the
        // fixed-function blend stage can express: a fragment program cannot read
        // the destination it is writing.
        const light_shader_mod = try createShader(device, light_wgsl, "light.shader");
        resources_created += 1;

        const light_bgl = try createBindGroupLayout(device, &[_]wgpu.BindGroupLayoutEntry{
            .{
                .binding = 0,
                .visibility = wgpu.ShaderStage_Vertex | wgpu.ShaderStage_Fragment,
                .buffer_type = wgpu.BufferBindingType_Uniform,
                // mat4 + 4 x vec2 + vec4 = 112 bytes, matching `Globals`.
                .buffer_minBindingSize = LightUniformBytes,
            },
            .{
                .binding = 1,
                .visibility = wgpu.ShaderStage_Fragment,
                .buffer_type = 0,
                .texture_sampleType = wgpu.TextureSampleType_Float,
                .texture_viewDimension = wgpu.TextureViewDimension_2D,
            },
            // The GI cascade and its sampler. Bound from boot with a 1x1 black
            // placeholder, because a pipeline layout that names a binding the
            // bind group does not supply is a VALIDATION ERROR at draw time --
            // and the first draw of a scene is exactly when nobody is reading
            // validation output. A bound black cascade with `gi_contribution` at
            // zero is not wrong: it is the same answer, arrived at honestly.
            .{
                .binding = 2,
                .visibility = wgpu.ShaderStage_Fragment,
                .buffer_type = 0,
                .texture_sampleType = wgpu.TextureSampleType_Float,
                .texture_viewDimension = wgpu.TextureViewDimension_2D,
            },
            .{
                .binding = 3,
                .visibility = wgpu.ShaderStage_Fragment,
                .buffer_type = 0, // BindingNotUsed: this entry is a sampler
                // `sampler_type`, and not a nested sampler descriptor: a layout
                // entry names the sampler it will accept, and the sampler
                // OBJECT itself belongs in the bind group. Putting the object
                // here is a compile error, which is the good outcome.
                .sampler_type = wgpu.SamplerBindingType_Filtering,
            },
            // The sprite-layer target, for `item_cull_mask`. A 1x1 placeholder at
            // boot for the same reason the GI cascade has one: the bind group is
            // built at startup and a binding it does not supply is a validation
            // error on the first draw of the scene.
            .{
                .binding = 4,
                .visibility = wgpu.ShaderStage_Fragment,
                .buffer_type = 0, // BindingNotUsed: this entry is a texture
                .texture_sampleType = wgpu.TextureSampleType_Float,
                .texture_viewDimension = wgpu.TextureViewDimension_2D,
            },
        }, "light.bgl");
        resources_created += 1;

        const light_layout = try createPipelineLayout(device, &[_]wgpu.WGPUBindGroupLayout{light_bgl}, "light.layout");
        resources_created += 1;

        const light_uniform_buf = wgpu.wgpuDeviceCreateBuffer(device, &.{
            .label = wgpu.StringView.from("light.uniform"),
            .usage = wgpu.BufferUsage_Uniform | wgpu.BufferUsage_CopyDst,
            .size = LightUniformBytes,
        }) orelse return error.BufferCreationFailed;
        resources_created += 1;

        const light_instance_buf = wgpu.wgpuDeviceCreateBuffer(device, &.{
            .label = wgpu.StringView.from("light.instances"),
            .usage = wgpu.BufferUsage_Vertex | wgpu.BufferUsage_CopyDst,
            .size = @as(u64, options.max_lights) * LightInstanceBytes,
        }) orelse return error.BufferCreationFailed;
        resources_created += 1;

        // The 11 attributes map exactly onto LightInstance's field offsets. The
        // two flat u32/vec4 entries are interpolate(flat) in the shader: a
        // blend mode that went through a varying would be garbage.
        const light_attrs = [_]wgpu.VertexAttribute{
            .{ .format = wgpu.VertexFormat_Float32x2, .offset = 0, .shaderLocation = 0 },
            .{ .format = wgpu.VertexFormat_Float32x2, .offset = 8, .shaderLocation = 1 },
            .{ .format = wgpu.VertexFormat_Float32x2, .offset = 16, .shaderLocation = 2 },
            .{ .format = wgpu.VertexFormat_Float32x2, .offset = 24, .shaderLocation = 3 },
            .{ .format = wgpu.VertexFormat_Float32x2, .offset = 32, .shaderLocation = 4 },
            .{ .format = wgpu.VertexFormat_Float32x4, .offset = 40, .shaderLocation = 5 },
            .{ .format = wgpu.VertexFormat_Float32x2, .offset = 48, .shaderLocation = 6 },
            .{ .format = wgpu.VertexFormat_Float32x2, .offset = 56, .shaderLocation = 7 },
            // The sprite-layer mask, its own u32 at byte 64. A ninth attribute and
            // four more bytes per light, which is what a per-light 32-bit mask
            // costs; folding it into `flags` would mean dropping to u16 layers,
            // and layers are a scene author's numbering.
            .{ .format = wgpu.VertexFormat_Uint32, .offset = 64, .shaderLocation = 8 },
        };
        const light_vlayout = wgpu.VertexBufferLayout{
            .stepMode = wgpu.VertexStepMode_Instance,
            .arrayStride = LightInstanceBytes,
            .attributeCount = 9,
            .attributes = &light_attrs,
        };

        // add: src (already scaled by the light) + dst.
        var l_blend = wgpu.BlendState{
            .color = .{ .operation = wgpu.BlendOperation_Add, .srcFactor = wgpu.BlendFactor_One, .dstFactor = wgpu.BlendFactor_One },
            .alpha = .{ .operation = wgpu.BlendOperation_Add, .srcFactor = wgpu.BlendFactor_One, .dstFactor = wgpu.BlendFactor_One },
        };
        var target = [_]wgpu.ColorTargetState{.{ .format = format, .blend = @ptrCast(&l_blend) }};
        const l_frag = wgpu.FragmentState{
            .module = light_shader_mod,
            .entryPoint = wgpu.StringView.from("fs_main"),
            .targetCount = 1,
            .targets = &target,
        };
        const light_pipeline_add = wgpu.wgpuDeviceCreateRenderPipeline(device, &.{
            .label = wgpu.StringView.from("light.add"),
            .layout = light_layout,
            .primitive_topology = wgpu.PrimitiveTopology_TriangleStrip,
            .vertex_module = light_shader_mod,
            .vertex_entryPoint = wgpu.StringView.from("vs_main"),
            .vertex_bufferCount = 1,
            .vertex_buffers = @ptrCast(&light_vlayout),
            .fragment = &l_frag,
        }) orelse return error.PipelineCreationFailed;
        resources_created += 1;

        // subtract: dst - src. The light takes away.
        l_blend = wgpu.BlendState{
            .color = .{ .operation = wgpu.BlendOperation_ReverseSubtract, .srcFactor = wgpu.BlendFactor_One, .dstFactor = wgpu.BlendFactor_One },
            .alpha = .{ .operation = wgpu.BlendOperation_Add, .srcFactor = wgpu.BlendFactor_One, .dstFactor = wgpu.BlendFactor_One },
        };
        target = [_]wgpu.ColorTargetState{.{ .format = format, .blend = @ptrCast(&l_blend) }};
        const l_frag_sub = wgpu.FragmentState{
            .module = light_shader_mod,
            .entryPoint = wgpu.StringView.from("fs_main"),
            .targetCount = 1,
            .targets = &target,
        };
        const light_pipeline_sub = wgpu.wgpuDeviceCreateRenderPipeline(device, &.{
            .label = wgpu.StringView.from("light.subtract"),
            .layout = light_layout,
            .primitive_topology = wgpu.PrimitiveTopology_TriangleStrip,
            .vertex_module = light_shader_mod,
            .vertex_entryPoint = wgpu.StringView.from("vs_main"),
            .vertex_bufferCount = 1,
            .vertex_buffers = @ptrCast(&light_vlayout),
            .fragment = &l_frag_sub,
        }) orelse return error.PipelineCreationFailed;
        resources_created += 1;

        // mix: a lerp. Standard alpha blending expresses it exactly, with the
        // fragment program writing the fully-lit colour and alpha carrying the
        // amount of light that arrived.
        l_blend = wgpu.BlendState{
            .color = .{ .operation = wgpu.BlendOperation_Add, .srcFactor = wgpu.BlendFactor_SrcAlpha, .dstFactor = wgpu.BlendFactor_OneMinusSrcAlpha },
            .alpha = .{ .operation = wgpu.BlendOperation_Add, .srcFactor = wgpu.BlendFactor_One, .dstFactor = wgpu.BlendFactor_OneMinusSrcAlpha },
        };
        target = [_]wgpu.ColorTargetState{.{ .format = format, .blend = @ptrCast(&l_blend) }};
        const l_frag_mix = wgpu.FragmentState{
            .module = light_shader_mod,
            .entryPoint = wgpu.StringView.from("fs_main"),
            .targetCount = 1,
            .targets = &target,
        };
        const light_pipeline_mix = wgpu.wgpuDeviceCreateRenderPipeline(device, &.{
            .label = wgpu.StringView.from("light.mix"),
            .layout = light_layout,
            .primitive_topology = wgpu.PrimitiveTopology_TriangleStrip,
            .vertex_module = light_shader_mod,
            .vertex_entryPoint = wgpu.StringView.from("vs_main"),
            .vertex_bufferCount = 1,
            .vertex_buffers = @ptrCast(&light_vlayout),
            .fragment = &l_frag_mix,
        }) orelse return error.PipelineCreationFailed;
        resources_created += 1;

        // The shadow map: `angles` columns by four rows. Created here, uploaded
        // every frame by `uploadShadowMap`, so nothing GPU-shaped happens inside
        // a frame (spec §3.6).
        const light_shadow_texture = wgpu.wgpuDeviceCreateTexture(device, &.{
            .label = wgpu.StringView.from("light.shadow"),
            .usage = wgpu.TextureUsage_TextureBinding | wgpu.TextureUsage_CopyDst,
            .dimension = wgpu.TextureDimension_2D,
            .size = .{ .width = 128, .height = 4, .depthOrArrayLayers = 1 },
            .format = wgpu.TextureFormat_R8Unorm,
            .mipLevelCount = 1,
            .sampleCount = 1,
        }) orelse return error.TextureCreationFailed;
        resources_created += 1;
        const light_shadow_view = wgpu.wgpuTextureCreateView(light_shadow_texture, null) orelse return error.TextureViewCreationFailed;
        resources_created += 1;

        // The GI cascade placeholder: ONE texel, fully transparent. Alpha is the
        // enclosure term, so a transparent cascade reads as "sees nothing of the
        // sky" and the shader's `1 - si_gi * (1 - alpha)` would darken
        // everything. It has to be OPAQUE black, not transparent black: the
        // alpha channel is the data, and an unwritten one is not a neutral.
        const light_gi_texture = wgpu.wgpuDeviceCreateTexture(device, &.{
            .label = wgpu.StringView.from("light.gi"),
            .usage = wgpu.TextureUsage_TextureBinding | wgpu.TextureUsage_CopyDst,
            .dimension = wgpu.TextureDimension_2D,
            .size = .{ .width = 1, .height = 1, .depthOrArrayLayers = 1 },
            .format = wgpu.TextureFormat_RGBA8Unorm,
            .mipLevelCount = 1,
            .sampleCount = 1,
        }) orelse return error.TextureCreationFailed;
        resources_created += 1;
        const light_gi_view = wgpu.wgpuTextureCreateView(light_gi_texture, null) orelse return error.TextureViewCreationFailed;
        resources_created += 1;
        {
            const opaque_black = [_]u8{ 0, 0, 0, 255 };
            wgpu.wgpuQueueWriteTexture(
                queue,
                &.{
                    .texture = light_gi_texture,
                    .mipLevel = 0,
                    .origin = .{ .x = 0, .y = 0, .z = 0 },
                    .aspect = wgpu.TextureAspect_All,
                },
                &opaque_black,
                opaque_black.len,
                &.{ .bytesPerRow = 4, .rowsPerImage = 1 },
                &.{ .width = 1, .height = 1, .depthOrArrayLayers = 1 },
            );
        }
        // The layer placeholder: one texel at the WILDCARD value, so a light
        // that samples it before a target exists sees "lit by everything", which
        // is the same answer it would give on the empty background.
        const light_layer_placeholder = wgpu.wgpuDeviceCreateTexture(device, &.{
            .label = wgpu.StringView.from("light.layer.placeholder"),
            .usage = wgpu.TextureUsage_TextureBinding | wgpu.TextureUsage_CopyDst,
            .dimension = wgpu.TextureDimension_2D,
            .size = .{ .width = 1, .height = 1, .depthOrArrayLayers = 1 },
            .format = wgpu.TextureFormat_R8Unorm,
            .mipLevelCount = 1,
            .sampleCount = 1,
        }) orelse return error.TextureCreationFailed;
        resources_created += 1;
        const light_layer_placeholder_view = wgpu.wgpuTextureCreateView(light_layer_placeholder, null) orelse return error.TextureViewCreationFailed;
        resources_created += 1;
        {
            const wildcard = [_]u8{ 255 };
            wgpu.wgpuQueueWriteTexture(
                queue,
                &.{
                    .texture = light_layer_placeholder,
                    .mipLevel = 0,
                    .origin = .{ .x = 0, .y = 0, .z = 0 },
                    .aspect = wgpu.TextureAspect_All,
                },
                &wildcard,
                wildcard.len,
                &.{ .bytesPerRow = 4, .rowsPerImage = 1 },
                &.{ .width = 1, .height = 1, .depthOrArrayLayers = 1 },
            );
        }

        const light_gi_sampler = wgpu.wgpuDeviceCreateSampler(device, &.{
            .label = wgpu.StringView.from("light.gi.smp"),
            // CLAMP, not repeat: the cascade is a rectangle of the world and a
            // point outside it has no enclosure data, which the shader says so
            // explicitly. Wrapping would smear the opposite edge's occluders in
            // and darken the border of the measured region.
            .magFilter = wgpu.FilterMode_Linear,
            .minFilter = wgpu.FilterMode_Linear,
            // CLAMP, not repeat: the cascade is a rectangle of the world and a
            // point outside it has no enclosure data, which the shader says so
            // explicitly. Wrapping would smear the opposite edge's occluders in
            // and darken the border of the measured region.
            .addressModeU = wgpu.AddressMode_ClampToEdge,
            .addressModeV = wgpu.AddressMode_ClampToEdge,
            .addressModeW = wgpu.AddressMode_ClampToEdge,
        }) orelse return error.SamplerCreationFailed;
        resources_created += 1;

        const light_bind_group = wgpu.wgpuDeviceCreateBindGroup(device, &.{
            .label = wgpu.StringView.from("light.bind"),
            .layout = light_bgl,
            .entryCount = 5,
            .entries = &[_]wgpu.BindGroupEntry{
                .{ .binding = 0, .buffer = light_uniform_buf, .offset = 0, .size = LightUniformBytes },
                .{ .binding = 1, .textureView = light_shadow_view },
                .{ .binding = 2, .textureView = light_gi_view },
                .{ .binding = 3, .sampler = light_gi_sampler },
                .{ .binding = 4, .textureView = light_layer_placeholder_view },
            },
        }) orelse return error.BindGroupCreationFailed;
        resources_created += 1;

        // Additive (lights in M7): src alpha + one.
        blend = wgpu.BlendState{
            .color = .{ .operation = wgpu.BlendOperation_Add, .srcFactor = wgpu.BlendFactor_SrcAlpha, .dstFactor = wgpu.BlendFactor_One },
            .alpha = .{ .operation = wgpu.BlendOperation_Add, .srcFactor = wgpu.BlendFactor_One, .dstFactor = wgpu.BlendFactor_One },
        };
        // A SPRITE pipeline, so it needs the layer target too — the same second,
        // unblended output as the other two sprite pipelines. An additive sprite
        // (a glow, a flare) still occludes the layer below it, so replacing is
        // right: the light pass must light whatever the user SEES on top.
        const additive_target = [_]wgpu.ColorTargetState{
            .{ .format = format, .blend = @ptrCast(&blend) },
            .{ .format = wgpu.TextureFormat_R8Unorm },
        };
        const sprite_fragment_additive = wgpu.FragmentState{
            .module = sprite_shader,
            .entryPoint = wgpu.StringView.from("fs_main"),
            .targetCount = 2,
            .targets = &additive_target,
        };
        const sprite_pipeline_additive = wgpu.wgpuDeviceCreateRenderPipeline(device, &.{
            .label = wgpu.StringView.from("sprite.additive"),
            .layout = sprite_layout,
            .primitive_topology = wgpu.PrimitiveTopology_TriangleStrip,
            .vertex_module = sprite_shader,
            .vertex_entryPoint = wgpu.StringView.from("vs_main"),
            .vertex_bufferCount = 1,
            .vertex_buffers = @ptrCast(&sprite_vlayout),
            .fragment = &sprite_fragment_additive,
        }) orelse return error.PipelineCreationFailed;
        resources_created += 1;

        // ── M2 SMAA resources ───────────────────────────────────────────────
        const smaa_shader = try createShader(device, smaa_wgsl, "smaa.wgsl");
        resources_created += 1;

        // SMAA bind group layout: 0 = src texture, 1 = sampler, 2 = uniform,
        // 3 = weights texture. All three passes share ONE layout so the three
        // bind groups are created once with the offscreen target and NEVER
        // inside a frame (spec §3.6). Unused bindings are legal in WGSL.
        const smaa_bgl = try createBindGroupLayout(device, &[_]wgpu.BindGroupLayoutEntry{
            .{
                .binding = 0,
                .visibility = wgpu.ShaderStage_Fragment,
                .buffer_type = 0, // BindingNotUsed: this entry is a texture
                .texture_sampleType = wgpu.TextureSampleType_Float,
                .texture_viewDimension = wgpu.TextureViewDimension_2D,
            },
            .{
                .binding = 1,
                .visibility = wgpu.ShaderStage_Fragment,
                .sampler_type = wgpu.SamplerBindingType_Filtering,
            },
            .{
                .binding = 2,
                .visibility = wgpu.ShaderStage_Fragment,
                .buffer_type = wgpu.BufferBindingType_Uniform,
                // `EdgeUniforms` is 2 x vec2f = 24 bytes, NOT the 16 of a bare
                // vec4: Dawn validates the shader's struct against this.
                .buffer_minBindingSize = SmaaUniformBytes,
            },
            .{
                .binding = 3,
                .visibility = wgpu.ShaderStage_Fragment,
                .buffer_type = 0, // BindingNotUsed: this entry is a texture
                .texture_sampleType = wgpu.TextureSampleType_Float,
                .texture_viewDimension = wgpu.TextureViewDimension_2D,
            },
        }, "smaa.bgl");
        resources_created += 1;

        // ── M7: the post pass ─────────────────────────────────────────────────
        //
        // ONE bind group layout for all four pipelines, matching post.wgsl's
        // single `@group(0)` block. The alternative — a layout per pipeline — is
        // four layouts and four chances to bind a view that is also a render
        // attachment, which is the mistake that actually breaks.
        const post_bgl = try createBindGroupLayout(device, &[_]wgpu.BindGroupLayoutEntry{
            .{
                .binding = 0,
                .visibility = wgpu.ShaderStage_Fragment,
                .buffer_type = wgpu.BufferBindingType_Uniform,
                .buffer_minBindingSize = PostUniformBytes,
            },
            .{
                .binding = 1,
                .visibility = wgpu.ShaderStage_Fragment,
                .buffer_type = 0,
                .texture_sampleType = wgpu.TextureSampleType_Float,
                .texture_viewDimension = wgpu.TextureViewDimension_2D,
            },
            .{
                .binding = 2,
                .visibility = wgpu.ShaderStage_Fragment,
                .sampler_type = wgpu.SamplerBindingType_Filtering,
            },
            .{
                .binding = 3,
                .visibility = wgpu.ShaderStage_Fragment,
                .buffer_type = 0,
                .texture_sampleType = wgpu.TextureSampleType_Float,
                .texture_viewDimension = wgpu.TextureViewDimension_2D,
            },
        }, "post.bgl");
        resources_created += 1;

        const post_layout = try createPipelineLayout(device, &[_]wgpu.WGPUBindGroupLayout{post_bgl}, "post.layout");
        resources_created += 1;

        const post_uniform_buf = wgpu.wgpuDeviceCreateBuffer(device, &.{
            .label = wgpu.StringView.from("post.uniforms"),
            .usage = wgpu.BufferUsage_Uniform | wgpu.BufferUsage_CopyDst,
            .size = PostUniformBytes,
        }) orelse return error.BufferCreationFailed;
        resources_created += 1;

        const post_shader = try createShader(device, post_wgsl, "post.wgsl");
        resources_created += 1;

        // Five pipelines off ONE module: bright, blur H, blur V, composite, and
        // the copy used when post is off. No vertex buffers at all — the
        // fullscreen triangle comes from the vertex index, so `vertex_bufferCount`
        // is zero and there is nothing to bind.
        var post_pipelines: [5]wgpu.WGPURenderPipeline = undefined;
        // `[:0]const u8`, not `[]const u8`: `StringView.from` takes a sentinel-
        // terminated string because the C API needs the length AND the pointer,
        // and a slice without one cannot be converted. Naming the type
        // explicitly is the difference between "it compiled in Debug" and "it
        // compiled", since a literal array infers the sentinel for you and a
        // slice of one does not.
        const post_entries = [_][:0]const u8{
            "fs_bright",
            "fs_blur_h",
            "fs_blur_v",
            "fs_composite",
            "fs_copy",
        };
        const post_labels = [_][:0]const u8{
            "post.bright",
            "post.blur.h",
            "post.blur.v",
            "post.composite",
            "post.copy",
        };
        for (post_entries, 0..) |entry, i| {
            post_pipelines[i] = wgpu.wgpuDeviceCreateRenderPipeline(device, &.{
                .label = wgpu.StringView.from(post_labels[i]),
                .layout = post_layout,
                .primitive_topology = wgpu.PrimitiveTopology_TriangleList,
                .vertex_module = post_shader,
                .vertex_entryPoint = wgpu.StringView.from("vs_fullscreen"),
                .vertex_bufferCount = 0,
                // Named explicitly rather than defaulted: this struct has no
                // field defaults, so "no vertex buffers" is a value someone has
                // to say. Leaving it out is a compile error, which is better
                // than a pipeline that silently reads a stale buffer list.
                .vertex_buffers = null,
                .fragment = &wgpu.FragmentState{
                    .module = post_shader,
                    .entryPoint = wgpu.StringView.from(entry),
                    .targetCount = 1,
                    .targets = &[_]wgpu.ColorTargetState{.{ .format = format }},
                },
            }) orelse return error.PipelineCreationFailed;
            resources_created += 1;
        }

        const smaa_layout = try createPipelineLayout(device, &[_]wgpu.WGPUBindGroupLayout{smaa_bgl}, "smaa.layout");
        resources_created += 1;

        const smaa_uniform_buf = wgpu.wgpuDeviceCreateBuffer(device, &.{
            .label = wgpu.StringView.from("smaa.uniforms"),
            .usage = wgpu.BufferUsage_Uniform | wgpu.BufferUsage_CopyDst,
            .size = SmaaUniformBytes,
        }) orelse return error.BufferCreationFailed;
        resources_created += 1;
        const smaa_blend_uniform_buf = wgpu.wgpuDeviceCreateBuffer(device, &.{
            .label = wgpu.StringView.from("smaa.blend.uniforms"),
            .usage = wgpu.BufferUsage_Uniform | wgpu.BufferUsage_CopyDst,
            .size = SmaaUniformBytes,
        }) orelse return error.BufferCreationFailed;
        resources_created += 1;

        // SMAA passes run on the surface format (they blend into it or the
        // scratch targets share it). The edge/weight targets use the same
        // format so a single pipeline works for all three passes.
        const smaa_targets = [_]wgpu.ColorTargetState{.{ .format = format }};
        const smaa_pipeline_edge = try createRenderPipeline(device, smaa_layout, smaa_shader, "smaa.edge", "fs_edge", &smaa_targets);
        resources_created += 1;
        const smaa_pipeline_weights = try createRenderPipeline(device, smaa_layout, smaa_shader, "smaa.weights", "fs_weights", &smaa_targets);
        resources_created += 1;
        const smaa_pipeline_blend = try createRenderPipeline(device, smaa_layout, smaa_shader, "smaa.blend", "fs_blend", &smaa_targets);
        resources_created += 1;
        // Offscreen → swapchain composition when SMAA is off, and the editor's
        // viewport blit in M5. Same layout and the same bind group as the
        // blend pass (src at binding 0), so no extra GPU object at frame time.
        const smaa_pipeline_copy = try createRenderPipeline(device, smaa_layout, smaa_shader, "smaa.copy", "fs_copy", &smaa_targets);
        resources_created += 1;

        // ── Assemble ────────────────────────────────────────────────────────
        const self = try allocator.create(Backend);
        var slots = [_]Slot{.{}} ** SLOTS;
        var query_set_made: ?wgpu.WGPUQuerySet = null;
        if (timestamps) blk: {
            const query_set = wgpu.wgpuDeviceCreateQuerySet(device, &.{
                .type = wgpu.QueryType_Timestamp,
                .count = GPU_TIMESTAMP_SLOTS,
            }) orelse {
                log.warn("timestamp-query enabled but wgpuDeviceCreateQuerySet returned null: GPU times will be missing", .{});
                break :blk;
            };
            var i: usize = 0;
            while (i < SLOTS) : (i += 1) {
                slots[i].resolve_buf = wgpu.wgpuDeviceCreateBuffer(device, &.{
                    .usage = wgpu.BufferUsage_QueryResolve | wgpu.BufferUsage_CopySrc,
                    .size = TimestampBytes,
                }) orelse return error.BufferCreationFailed;
                slots[i].readback_buf = wgpu.wgpuDeviceCreateBuffer(device, &.{
                    .usage = wgpu.BufferUsage_MapRead | wgpu.BufferUsage_CopyDst,
                    .size = TimestampBytes,
                }) orelse return error.BufferCreationFailed;
                resources_created += 2;
            }
            query_set_made = query_set;
        }
        // NOTE: nothing here may write to `self` before `self.* = .{...}`
        // below: the struct literal would overwrite it.
        self.* = .{
            .allocator = allocator,
            .instance = instance,
            .adapter = adapter,
            .device = device,
            .queue = queue,
            .surface = surface,
            .format = format,
            .quad_shader = quad_shader,
            .quad_bgl = quad_bgl,
            .quad_layout = quad_layout,
            .quad_pipeline = quad_pipeline,
            .quad_bind_group = quad_bind_group,
            .quad_uniform_buf = uniform_buf,
            .quad_vertex_buf = vertex_buf,
            .quad_index_buf = index_buf,
            .sprite_shader = sprite_shader,
            .sprite_bgl = sprite_bgl,
            .sprite_layout = sprite_layout,
            .sprite_pipeline_textured = sprite_pipeline_textured,
            .light_pipeline_add = light_pipeline_add,
            .light_pipeline_sub = light_pipeline_sub,
            .light_pipeline_mix = light_pipeline_mix,
            .light_instance_buf = light_instance_buf,
            .light_uniform_buf = light_uniform_buf,
            .light_shadow_texture = light_shadow_texture,
            .light_shadow_view = light_shadow_view,
            .light_bind_group = light_bind_group,
            .light_gi_texture = light_gi_texture,
            .light_gi_view = light_gi_view,
            .light_gi_sampler = light_gi_sampler,
            .light_gi_bgl = light_bgl,
            .light_instance_capacity = options.max_lights,
            .sprite_pipeline_solid = sprite_pipeline_solid,
            .sprite_pipeline_additive = sprite_pipeline_additive,
            .sprite_uniform_buf = sprite_uniform_buf,
            .sprite_instance_buf = sprite_instance_buf,
            .sprite_instance_capacity = options.max_sprites,
            .sampler = sampler,
            .white_tex = white_tex,
            .white_view = white_view,
            .white_bind_group = white_bind_group,
            .atlases = .empty,
            .atlas_allocator = allocator,
            .smaa_shader = smaa_shader,
            .smaa_bgl = smaa_bgl,
            .post_bgl = post_bgl,
            .post_pipeline_bright = post_pipelines[0],
            .post_pipeline_blur_h = post_pipelines[1],
            .post_pipeline_blur_v = post_pipelines[2],
            .post_pipeline_composite = post_pipelines[3],
            .post_pipeline_copy = post_pipelines[4],
            .post_uniform_buf = post_uniform_buf,
            .smaa_layout = smaa_layout,
            .smaa_pipeline_edge = smaa_pipeline_edge,
            .smaa_pipeline_weights = smaa_pipeline_weights,
            .smaa_pipeline_blend = smaa_pipeline_blend,
            .smaa_pipeline_copy = smaa_pipeline_copy,
            .smaa_uniform_buf = smaa_uniform_buf,
            .smaa_blend_uniform_buf = smaa_blend_uniform_buf,
            .width = width,
            .height = height,
            .smaa_quality = options.smaa_quality,
            .smaa_enabled = options.smaa,
            .present_mode = present_mode,
            .timestamps = timestamps and query_set_made != null,
            .query_set = query_set_made,
            .slots = slots,
            .stats_data = .{
                .resources_created_total = resources_created,
                .present_mode = present_mode,
                .timestamp_queries = timestamps and query_set_made != null,
            },
        };
        self.configureSurface();
        if (!timestamps) {
            log.warn("timestamp queries unavailable: GPU time will not be measured (spec §4)", .{});
        } else if (query_set_made == null) {
            log.warn("timestamp-query enabled but the query set could not be created", .{});
        }
        return self;
    }

    fn createShader(device: wgpu.WGPUDevice, source: []const u8, label: [:0]const u8) !wgpu.WGPUShaderModule {
        var wgsl_src = wgpu.ShaderSourceWGSL{
            .chain = .{ .sType = wgpu.SType_ShaderSourceWGSL },
            .code = wgpu.StringView.slice(source),
        };
        var shader_desc = wgpu.ShaderModuleDescriptor{
            .nextInChain = @ptrCast(&wgsl_src),
            .label = wgpu.StringView.from(label),
        };
        return wgpu.wgpuDeviceCreateShaderModule(device, &shader_desc) orelse error.ShaderCompilationFailed;
    }

    fn createBindGroupLayout(
        device: wgpu.WGPUDevice,
        entries: []const wgpu.BindGroupLayoutEntry,
        label: [:0]const u8,
    ) !wgpu.WGPUBindGroupLayout {
        return wgpu.wgpuDeviceCreateBindGroupLayout(device, &.{
            .label = wgpu.StringView.from(label),
            .entryCount = entries.len,
            .entries = @ptrCast(entries.ptr),
        }) orelse error.BindGroupLayoutFailed;
    }

    fn createPipelineLayout(
        device: wgpu.WGPUDevice,
        layouts: []const wgpu.WGPUBindGroupLayout,
        label: [:0]const u8,
    ) !wgpu.WGPUPipelineLayout {
        return wgpu.wgpuDeviceCreatePipelineLayout(device, &.{
            .label = wgpu.StringView.from(label),
            .bindGroupLayoutCount = layouts.len,
            .bindGroupLayouts = @ptrCast(layouts.ptr),
        }) orelse error.PipelineLayoutFailed;
    }

    fn createBindGroup(
        device: wgpu.WGPUDevice,
        layout: wgpu.WGPUBindGroupLayout,
        entries: []const wgpu.BindGroupEntry,
        label: [:0]const u8,
    ) !wgpu.WGPUBindGroup {
        return wgpu.wgpuDeviceCreateBindGroup(device, &.{
            .label = wgpu.StringView.from(label),
            .layout = layout,
            .entryCount = entries.len,
            .entries = @ptrCast(entries.ptr),
        }) orelse error.BindGroupGroupFailed;
    }

    fn createRenderPipeline(
        device: wgpu.WGPUDevice,
        layout: wgpu.WGPUPipelineLayout,
        module: wgpu.WGPUShaderModule,
        label: [:0]const u8,
        entry_point: [:0]const u8,
        targets: []const wgpu.ColorTargetState,
    ) !wgpu.WGPURenderPipeline {
        // SMAA passes use the fullscreen triangle: NO vertex buffer.
        const fragment = wgpu.FragmentState{
            .module = module,
            .entryPoint = wgpu.StringView.from(entry_point),
            .targetCount = 1,
            .targets = @ptrCast(targets.ptr),
        };
        return wgpu.wgpuDeviceCreateRenderPipeline(device, &.{
            .label = wgpu.StringView.from(label),
            .layout = layout,
            .vertex_module = module,
            .vertex_entryPoint = wgpu.StringView.from("vs_fullscreen"),
            .vertex_bufferCount = 0,
            .vertex_buffers = null,
            .fragment = &fragment,
        }) orelse error.PipelineCreationFailed;
    }

    fn configureSurface(self: *Backend) void {
        wgpu.wgpuSurfaceConfigure(self.surface, &.{
            .device = self.device,
            .format = self.format,
            .usage = wgpu.TextureUsage_RenderAttachment,
            .width = self.width,
            .height = self.height,
            .presentMode = self.present_mode,
        });
    }

    /// Acquires the surface texture, reconfiguring once on outdated/lost.
    fn acquireTexture(self: *Backend) ?wgpu.WGPUTexture {
        var surf_tex = wgpu.SurfaceTexture{};
        wgpu.wgpuSurfaceGetCurrentTexture(self.surface, &surf_tex);
        const status = surf_tex.status;
        if (status == wgpu.SurfaceGetCurrentTextureStatus_Outdated or
            status == wgpu.SurfaceGetCurrentTextureStatus_Lost)
        {
            self.configureSurface();
            wgpu.wgpuSurfaceGetCurrentTexture(self.surface, &surf_tex);
        }
        const ok_status = surf_tex.status == wgpu.SurfaceGetCurrentTextureStatus_SuccessOptimal or
            surf_tex.status == wgpu.SurfaceGetCurrentTextureStatus_SuccessSuboptimal;
        if (!ok_status or surf_tex.texture == null) return null;
        return surf_tex.texture;
    }

    // ── GPU timestamps: resolve, copy and non-blocking readback ─────────────

    /// Advances every readback slot: map (non-blocking), poll, read. Polling
    /// only the "expected" slot was the bug that kept every map pending
    /// forever: each slot must be advanced every frame, not once.
    fn pumpTimestamps(self: *Backend) void {
        if (!self.timestamps) return;
        for (&self.slots) |*slot| {
            if (!slot.used) continue;
            // Give the GPU at least 2 frames to have flushed the copy.
            if (self.frames < slot.frame_index + 2) continue;
            switch (slot.state) {
                .idle => {
                    slot.future = wgpu.wgpuBufferMapAsync(
                        slot.readback_buf,
                        wgpu.MapMode_Read,
                        0,
                        TimestampBytes,
                        .{
                            .mode = wgpu.CallbackMode_WaitAnyOnly,
                            .callback = mapCallback,
                        },
                    );
                    slot.state = .mapping;
                    self.stats_data.timestamp_maps = self.stats_data.timestamp_maps + 1;
                },
                .mapping => {
                    var wait = [_]wgpu.FutureWaitInfo{.{ .future = slot.future }};
                    if (wgpu.wgpuInstanceWaitAny(self.instance, 1, &wait, 0) == wgpu.WaitStatus_Success) {
                        slot.state = .ready;
                    }
                },
                .ready => {
                    // Read map -> ConstMappedRange: GetMappedRange is the
                    // writable variant and returns null here.
                    const range = wgpu.wgpuBufferGetConstMappedRange(slot.readback_buf, 0, TimestampBytes);
                    self.stats_data.timestamp_ranges = self.stats_data.timestamp_ranges + 1;
                    if (range == null) {
                        // Never leave a buffer mapped: re-mapping it next frame
                        // is a validation error.
                        wgpu.wgpuBufferUnmap(slot.readback_buf);
                        self.stats_data.timestamp_bad = self.stats_data.timestamp_bad + 1;
                        slot.state = .idle;
                        continue;
                    }
                    const samples: [*]const u64 = @ptrCast(@alignCast(range.?));
                    const begin = samples[0];
                    const end = samples[1];
                    if (end > begin) {
                        const ns: u64 = @intFromFloat(@as(f64, @floatFromInt(end - begin)) * GPU_TIMESTAMP_PERIOD_NS);
                        self.gpu_ns_last = ns;
                        self.gpu_pass_count = 1;
                        self.stats_data.timestamp_reads = self.stats_data.timestamp_reads + 1;
                    } else {
                        self.stats_data.timestamp_bad = self.stats_data.timestamp_bad + 1;
                    }
                    wgpu.wgpuBufferUnmap(slot.readback_buf);
                    slot.state = .idle;
                },
            }
        }
        self.stats_data.gpu_ns = self.gpu_ns_last;
        self.stats_data.gpu_passes = self.gpu_pass_count;
    }

    /// Submits the resolve+copy of the PREVIOUS frame's timestamps. Called
    /// after the main command buffer of the frame, so the query results are
    /// already written by the time this runs.
    fn submitTimestampResolve(self: *Backend) void {
        if (!self.timestamps) return;
        const qs = self.query_set orelse return;
        const idx = self.frames % SLOTS;
        const slot = &self.slots[idx];
        if (slot.state != .idle) return; // not drained yet: skip, lose one sample

        const encoder = wgpu.wgpuDeviceCreateCommandEncoder(self.device, null) orelse return;
        defer wgpu.wgpuCommandEncoderRelease(encoder);
        slot.used = true;
        slot.frame_index = self.frames;
        wgpu.wgpuCommandEncoderResolveQuerySet(encoder, qs, 0, GPU_TIMESTAMP_SLOTS, slot.resolve_buf, 0);
        wgpu.wgpuCommandEncoderCopyBufferToBuffer(
            encoder,
            slot.resolve_buf,
            0,
            slot.readback_buf,
            0,
            TimestampBytes,
        );
        const cmd = wgpu.wgpuCommandEncoderFinish(encoder, null) orelse return;
        defer wgpu.wgpuCommandBufferRelease(cmd);
        wgpu.wgpuQueueSubmit(self.queue, 1, @ptrCast(&cmd));
        slot.frame_index = self.frames;
    }

    fn beginFrame(ptr: *anyopaque) void {
        const self: *Backend = @ptrCast(@alignCast(ptr));
        self.pumpTimestamps();
        self.stats_data.draw_calls = 0;
        self.stats_data.render_passes = 0;
        self.stats_data.pipeline_changes = 0;
        self.stats_data.bind_group_changes = 0;
        self.stats_data.vertex_count = 0;
        self.stats_data.upload_bytes = 0;
        self.stats_data.gpu_ns = self.gpu_ns_last;
        self.stats_data.gpu_passes = self.gpu_pass_count;
        self.stats_data.resources_created_frame = 0;
        self.scene_active = false;
        self.ts_cursor = 0;
    }

    /// Acquires the surface texture and keeps it until the present. This is
    /// where Fifo present mode blocks waiting for the display.
    fn acquireSurface(ptr: *anyopaque) void {
        const self: *Backend = @ptrCast(@alignCast(ptr));
        // Release the PREVIOUS frame's texture only now: Dawn's swapchain
        // does not keep a reference, and releasing it inside the same frame
        // lets a pending submit use a destroyed texture.
        if (self.surface_texture) |prev| wgpu.wgpuTextureRelease(prev);
        self.surface_acquires += 1;
        self.surface_texture = self.acquireTexture();
    }

    fn drawQuad(ptr: *anyopaque, mvp: *const [16]f32) void {
        const self: *Backend = @ptrCast(@alignCast(ptr));
        self.quads_drawn += 1;
        self.stats_data.draw_calls += 1;

        // MVP upload (fixed 64 bytes, boot-sized buffer; spec §3.6).
        wgpu.wgpuQueueWriteBuffer(self.queue, self.quad_uniform_buf, 0, mvp, 64);
        self.stats_data.upload_bytes += 64;

        // The frame must own exactly ONE acquire. Calling GetCurrentTexture
        // twice in a frame invalidates the first texture.
        const texture = self.surface_texture orelse return;
        const view = wgpu.wgpuTextureCreateView(texture, null) orelse return;
        defer wgpu.wgpuTextureViewRelease(view);

        // Encode: clear + draw the quad. No allocations: everything is
        // created and released inside this function (spec §3.1).
        const encoder = wgpu.wgpuDeviceCreateCommandEncoder(self.device, null) orelse return;
        defer wgpu.wgpuCommandEncoderRelease(encoder);
        const color_attachment = wgpu.RenderPassColorAttachment{
            .view = view,
            .loadOp = wgpu.LoadOp_Clear,
            .storeOp = wgpu.StoreOp_Store,
            .clearValue = .{ .r = 0.06, .g = 0.07, .b = 0.10, .a = 1.0 },
        };
        var timestamp_writes = self.timestampWrites();
        var pass_desc = wgpu.RenderPassDescriptor{
            .colorAttachmentCount = 1,
            .colorAttachments = @ptrCast(&color_attachment),
        };
        if (timestamp_writes) |*tw| pass_desc.timestampWrites = tw;
        const pass = wgpu.wgpuCommandEncoderBeginRenderPass(encoder, &pass_desc) orelse return;
        defer wgpu.wgpuRenderPassEncoderRelease(pass);
        self.stats_data.render_passes += 1;
        wgpu.wgpuRenderPassEncoderSetPipeline(pass, self.quad_pipeline);
        self.stats_data.pipeline_changes += 1;
        wgpu.wgpuRenderPassEncoderSetBindGroup(pass, 0, self.quad_bind_group, 0, null);
        self.stats_data.bind_group_changes += 1;
        wgpu.wgpuRenderPassEncoderSetVertexBuffer(pass, 0, self.quad_vertex_buf, 0, @sizeOf(@TypeOf(render.quad_vertices)));
        wgpu.wgpuRenderPassEncoderSetIndexBuffer(pass, self.quad_index_buf, wgpu.IndexFormat_Uint16, 0, @sizeOf(@TypeOf(render.quad_indices)));
        wgpu.wgpuRenderPassEncoderDrawIndexed(pass, 6, 1, 0, 0, 0);
        wgpu.wgpuRenderPassEncoderEnd(pass);

        const cmd = wgpu.wgpuCommandEncoderFinish(encoder, null) orelse return;
        defer wgpu.wgpuCommandBufferRelease(cmd);
        wgpu.wgpuQueueSubmit(self.queue, 1, @ptrCast(&cmd));
        self.acquired = true;
        self.submitTimestampResolve();
    }

    /// Builds a PassTimestampWrites for the NEXT instrumented pass, advancing
    /// the query-set cursor by 2. Returns null when timestamps are off or the
    /// cursor would overflow the query set.
    fn timestampWrites(self: *Backend) ?wgpu.PassTimestampWrites {
        if (!self.timestamps) return null;
        const qs = self.query_set orelse return null;
        if (self.ts_cursor + 2 > GPU_TIMESTAMP_SLOTS) return null;
        self.ts_cursor += 2;
        return .{
            .nextInChain = null,
            .querySet = qs,
            .beginningOfPassWriteIndex = self.ts_cursor - 2,
            .endOfPassWriteIndex = self.ts_cursor - 1,
        };
    }

    fn present(ptr: *anyopaque) void {
        const self: *Backend = @ptrCast(@alignCast(ptr));
        if (self.acquired) {
            _ = wgpu.wgpuSurfacePresent(self.surface);
            self.acquired = false;
        }
        self.frames += 1;
    }

    fn resize(ptr: *anyopaque, width: u32, height: u32) void {
        const self: *Backend = @ptrCast(@alignCast(ptr));
        const w = @max(1, width);
        const h = @max(1, height);
        if (w == self.width and h == self.height) return;
        self.width = w;
        self.height = h;
        self.configureSurface();
        // The offscreen target does not survive a resize. It is NOT recreated
        // here: `createOffscreenTarget` is the single owner and it replaces
        // the previous target. Doing both (as an earlier version did) meant
        // two destroys and a use-after-free on the GPU objects.
        self.offscreen_stale = self.offscreen != null;
    }

    fn stats(ptr: *anyopaque) *const render.FrameStats {
        const self: *Backend = @ptrCast(@alignCast(ptr));
        return &self.stats_data;
    }

    // ── M2: offscreen target ───────────────────────────────────────────────

    fn destroyOffscreen(self: *Backend, o: *Offscreen) void {
        wgpu.wgpuBindGroupRelease(o.smaa_edge_bind);
        wgpu.wgpuBindGroupRelease(o.smaa_weights_bind);
        wgpu.wgpuBindGroupRelease(o.smaa_blend_bind);
        wgpu.wgpuBindGroupRelease(o.post_bright_bind);
        wgpu.wgpuBindGroupRelease(o.post_blur_h_bind);
        wgpu.wgpuBindGroupRelease(o.post_blur_v_bind);
        wgpu.wgpuBindGroupRelease(o.post_composite_bind);
        if (o.smaa_post_edge_bind) |b| wgpu.wgpuBindGroupRelease(b);
        if (o.smaa_post_blend_bind) |b| wgpu.wgpuBindGroupRelease(b);
        wgpu.wgpuTextureViewRelease(o.color_view);
        wgpu.wgpuTextureRelease(o.color);
        wgpu.wgpuTextureViewRelease(o.layer_view);
        wgpu.wgpuTextureRelease(o.layer);
        wgpu.wgpuTextureViewRelease(o.depth_view);
        wgpu.wgpuTextureRelease(o.depth);
        wgpu.wgpuTextureViewRelease(o.edge_view);
        wgpu.wgpuTextureRelease(o.edge);
        wgpu.wgpuTextureViewRelease(o.weights_view);
        wgpu.wgpuTextureRelease(o.weights);
        wgpu.wgpuTextureViewRelease(o.post_view);
        wgpu.wgpuTextureRelease(o.post);
        wgpu.wgpuTextureViewRelease(o.bloom_a_view);
        wgpu.wgpuTextureRelease(o.bloom_a);
        wgpu.wgpuTextureViewRelease(o.bloom_b_view);
        wgpu.wgpuTextureRelease(o.bloom_b);
        self.allocator.destroy(o);
    }

    fn createOffscreenTarget(ptr: *anyopaque, width: u32, height: u32) render.OffscreenTarget {
        const self: *Backend = @ptrCast(@alignCast(ptr));
        const w = @max(1, width);
        const h = @max(1, height);
        const no_target = render.OffscreenTarget{ .width = w, .height = h };

        // Single owner: creating a target replaces the previous one. Without
        // this, a resize leaked the whole color+depth+2 scratch set.
        if (self.offscreen) |old| {
            self.destroyOffscreen(old);
            self.offscreen = null;
        }

        const o = self.allocator.create(Offscreen) catch {
            log.err("offscreen target allocation failed ({}x{})", .{ w, h });
            return no_target;
        };
        o.width = w;
        o.height = h;

        // Color: render target + sampled by SMAA.
        o.color = wgpu.wgpuDeviceCreateTexture(self.device, &.{
            .label = wgpu.StringView.from("offscreen.color"),
            .usage = wgpu.TextureUsage_RenderAttachment | wgpu.TextureUsage_TextureBinding,
            .dimension = wgpu.TextureDimension_2D,
            .size = .{ .width = w, .height = h },
            .format = self.format,
        }) orelse {
            log.err("offscreen color texture creation failed ({}x{})", .{ w, h });
            self.allocator.destroy(o);
            return no_target;
        };
        o.color_view = wgpu.wgpuTextureCreateView(o.color, null).?;
        o.layer = wgpu.wgpuDeviceCreateTexture(self.device, &.{
            .label = wgpu.StringView.from("offscreen.layer"),
            .usage = wgpu.TextureUsage_RenderAttachment | wgpu.TextureUsage_TextureBinding,
            .dimension = wgpu.TextureDimension_2D,
            .size = .{ .width = w, .height = h },
            .format = wgpu.TextureFormat_R8Unorm,
        }) orelse {
            log.err("offscreen layer texture creation failed ({}x{})", .{ w, h });
            self.destroyOffscreen(o);
            return no_target;
        };
        o.layer_view = wgpu.wgpuTextureCreateView(o.layer, null).?;

        // Depth/stencil: the editor's gizmos and M7's 2D shadows need it, and
        // it lets the scene pass do early-Z (overdraw rule).
        o.depth = wgpu.wgpuDeviceCreateTexture(self.device, &.{
            .label = wgpu.StringView.from("offscreen.depth"),
            .usage = wgpu.TextureUsage_RenderAttachment,
            .dimension = wgpu.TextureDimension_2D,
            .size = .{ .width = w, .height = h },
            .format = wgpu.TextureFormat_Depth24PlusStencil8,
        }) orelse {
            wgpu.wgpuTextureViewRelease(o.color_view);
            wgpu.wgpuTextureRelease(o.color);
            self.allocator.destroy(o);
            return no_target;
        };
        o.depth_view = wgpu.wgpuTextureCreateView(o.depth, null).?;

        // SMAA scratch at half resolution: the edge detector and the weight
        // pass do not need full res (SMAA's own reference runs them at half).
        const hw = @max(1, w / 2);
        const hh = @max(1, h / 2);
        o.edge = wgpu.wgpuDeviceCreateTexture(self.device, &.{
            .label = wgpu.StringView.from("smaa.edge"),
            .usage = wgpu.TextureUsage_RenderAttachment | wgpu.TextureUsage_TextureBinding,
            .dimension = wgpu.TextureDimension_2D,
            .size = .{ .width = hw, .height = hh },
            .format = self.format,
        }).?;
        o.edge_view = wgpu.wgpuTextureCreateView(o.edge, null).?;
        o.weights = wgpu.wgpuDeviceCreateTexture(self.device, &.{
            .label = wgpu.StringView.from("smaa.weights"),
            .usage = wgpu.TextureUsage_RenderAttachment | wgpu.TextureUsage_TextureBinding,
            .dimension = wgpu.TextureDimension_2D,
            .size = .{ .width = hw, .height = hh },
            .format = self.format,
        }).?;
        o.weights_view = wgpu.wgpuTextureCreateView(o.weights, null).?;

        // ── M7: the post pass's targets ───────────────────────────────────
        //
        // `post` is full resolution; the two bloom buffers are HALF. Half is
        // not a saving, it is the point: bloom is a low-frequency effect, and
        // running it at a quarter of the pixels is indistinguishable once the
        // composite blurs it back up. It is also what makes the four-pass chain
        // affordable at all -- a full-resolution separable blur is five times
        // the bandwidth of this one.
        o.post = wgpu.wgpuDeviceCreateTexture(self.device, &.{
            .label = wgpu.StringView.from("offscreen.post"),
            .usage = wgpu.TextureUsage_RenderAttachment | wgpu.TextureUsage_TextureBinding,
            .dimension = wgpu.TextureDimension_2D,
            .size = .{ .width = w, .height = h },
            .format = self.format,
        }) orelse {
            self.destroyOffscreen(o);
            return no_target;
        };
        o.post_view = wgpu.wgpuTextureCreateView(o.post, null).?;

        const bw = @max(1, w / 2);
        const bh = @max(1, h / 2);
        inline for (.{ "a", "b" }) |which| {
            const tex = wgpu.wgpuDeviceCreateTexture(self.device, &.{
                .label = if (comptime std.mem.eql(u8, which, "a"))
                    wgpu.StringView.from("offscreen.bloom.a")
                else
                    wgpu.StringView.from("offscreen.bloom.b"),
                .usage = wgpu.TextureUsage_RenderAttachment | wgpu.TextureUsage_TextureBinding,
                .dimension = wgpu.TextureDimension_2D,
                .size = .{ .width = bw, .height = bh },
                .format = self.format,
            }) orelse {
                self.destroyOffscreen(o);
                return no_target;
            };
            const view = wgpu.wgpuTextureCreateView(tex, null).?;
            if (comptime std.mem.eql(u8, which, "a")) {
                o.bloom_a = tex;
                o.bloom_a_view = view;
            } else {
                o.bloom_b = tex;
                o.bloom_b_view = view;
            }
        }

        // The four post bind groups. Every one binds the SAME layout, and each
        // names a `bloom_tex` even where the shader does not read it -- a layout
        // that made that slot conditional would need four layouts and four
        // pipelines' worth of state for no benefit.
        //
        // The rule each one obeys: never bind a view that is also the pass's
        // render attachment. Getting that wrong is not a validation error on
        // every backend, it is undefined behaviour and a frame of garbage.
        o.post_bright_bind = createBindGroup(self.device, self.post_bgl, &[_]wgpu.BindGroupEntry{
            .{ .binding = 0, .buffer = self.post_uniform_buf, .offset = 0, .size = PostUniformBytes },
            .{ .binding = 1, .textureView = o.color_view },
            .{ .binding = 2, .sampler = @ptrCast(self.sampler) },
            .{ .binding = 3, .textureView = o.bloom_a_view },
        }, "post.bright.bg") catch {
            self.destroyOffscreen(o);
            return no_target;
        };
        o.post_blur_h_bind = createBindGroup(self.device, self.post_bgl, &[_]wgpu.BindGroupEntry{
            .{ .binding = 0, .buffer = self.post_uniform_buf, .offset = 0, .size = PostUniformBytes },
            .{ .binding = 1, .textureView = o.bloom_a_view },
            .{ .binding = 2, .sampler = @ptrCast(self.sampler) },
            .{ .binding = 3, .textureView = o.bloom_b_view },
        }, "post.blur.h.bg") catch {
            self.destroyOffscreen(o);
            return no_target;
        };
        o.post_blur_v_bind = createBindGroup(self.device, self.post_bgl, &[_]wgpu.BindGroupEntry{
            .{ .binding = 0, .buffer = self.post_uniform_buf, .offset = 0, .size = PostUniformBytes },
            .{ .binding = 1, .textureView = o.bloom_b_view },
            .{ .binding = 2, .sampler = @ptrCast(self.sampler) },
            .{ .binding = 3, .textureView = o.bloom_a_view },
        }, "post.blur.v.bg") catch {
            self.destroyOffscreen(o);
            return no_target;
        };
        o.post_composite_bind = createBindGroup(self.device, self.post_bgl, &[_]wgpu.BindGroupEntry{
            .{ .binding = 0, .buffer = self.post_uniform_buf, .offset = 0, .size = PostUniformBytes },
            .{ .binding = 1, .textureView = o.color_view },
            .{ .binding = 2, .sampler = @ptrCast(self.sampler) },
            .{ .binding = 3, .textureView = o.bloom_a_view },
        }, "post.composite.bg") catch {
            self.destroyOffscreen(o);
            return no_target;
        };

        // Bind groups for the three SMAA passes. Same layout shape for all
        // three; only the views differ. Created once with the target, never
        // inside a frame (spec §3.6).
        o.smaa_edge_bind = createBindGroup(self.device, self.smaa_bgl, &[_]wgpu.BindGroupEntry{
            .{ .binding = 0, .textureView = o.color_view },
            .{ .binding = 1, .sampler = @ptrCast(self.sampler) },
            .{ .binding = 2, .buffer = self.smaa_uniform_buf, .offset = 0, .size = SmaaUniformBytes },
            .{ .binding = 3, .textureView = o.weights_view },
        }, "smaa.edge.bg") catch {
            self.destroyOffscreen(o);
            return no_target;
        };
        // Pass 2 binds the EDGE view at slot 3, not the weights: this pass WRITES
        // the weights target, and a texture cannot be both a render attachment
        // and a sampled binding in the same pass. The slot is unused by the
        // shader anyway (pass 2 reads only `src_tex`).
        o.smaa_weights_bind = createBindGroup(self.device, self.smaa_bgl, &[_]wgpu.BindGroupEntry{
            .{ .binding = 0, .textureView = o.edge_view },
            .{ .binding = 1, .sampler = @ptrCast(self.sampler) },
            .{ .binding = 2, .buffer = self.smaa_uniform_buf, .offset = 0, .size = SmaaUniformBytes },
            .{ .binding = 3, .textureView = o.edge_view },
        }, "smaa.weights.bg") catch {
            self.destroyOffscreen(o);
            return no_target;
        };
        o.smaa_blend_bind = createBindGroup(self.device, self.smaa_bgl, &[_]wgpu.BindGroupEntry{
            .{ .binding = 0, .textureView = o.color_view },
            .{ .binding = 1, .sampler = @ptrCast(self.sampler) },
            .{ .binding = 2, .buffer = self.smaa_blend_uniform_buf, .offset = 0, .size = SmaaUniformBytes },
            .{ .binding = 3, .textureView = o.weights_view },
        }, "smaa.blend.bg") catch {
            self.destroyOffscreen(o);
            return no_target;
        };

        self.offscreen = o;
        self.stats_data.resources_created_total += 12;
        return render.OffscreenTarget{ .width = w, .height = h, .handle = o };
    }

    /// Releases an offscreen target. Idempotent and ownership-checked: destroying
    /// a stale handle is a no-op instead of a double free.
    fn destroyOffscreenTarget(ptr: *anyopaque, target: render.OffscreenTarget) void {
        const self: *Backend = @ptrCast(@alignCast(ptr));
        const o: *Offscreen = @ptrCast(@alignCast(target.handle orelse return));
        if (self.offscreen != o) return; // not ours (or already gone)
        self.destroyOffscreen(o);
        self.offscreen = null;
    }

    fn beginScene(ptr: *anyopaque, target: render.OffscreenTarget, camera: render.Camera) void {
        const self: *Backend = @ptrCast(@alignCast(ptr));
        const o: *Offscreen = @ptrCast(@alignCast(target.handle orelse return));
        self.scene_target = o;
        self.scene_camera = camera;
        self.scene_active = true;

        // Publish the layer view and rebuild the light bind group if it moved.
        // Done HERE rather than in `createOffscreenTarget` because the light
        // bind group is built before any target exists, and rebuilding it on a
        // target swap is the only moment the view it names can change.
        if (self.light_layer_view == null or !sameView(self.light_layer_view, o.layer_view)) {
            self.light_layer_view = o.layer_view;
            self.rebuildLightBindGroup() catch {};
        }

        // Upload the camera + texel size once (fixed 96 bytes; spec §3.6).
        // Layout matches `Globals` in sprite.wgsl: mat4 (64 B) + 4 x f32 (16 B).
        // The array is uploaded as raw f32 — no repacking, no memcpy games.
        var globals: [24]f32 = undefined;
        @memcpy(globals[0..16], &camera.vp);
        const w: f32 = @floatFromInt(@max(1, o.width));
        const h: f32 = @floatFromInt(@max(1, o.height));
        globals[16] = w;
        globals[17] = h;
        globals[18] = 1.0 / w;
        globals[19] = 1.0 / h;
        globals[20] = 0;
        globals[21] = 0;
        wgpu.wgpuQueueWriteBuffer(self.queue, self.sprite_uniform_buf, 0, &globals, SpriteUniformBytes);
        self.stats_data.upload_bytes += SpriteUniformBytes;

        // The light pass's own uniform, which used to never be written at all.
        //
        // That is worth stating plainly: `beginScene` filled the sprite uniform
        // and stopped, so every light pass read a `Globals` buffer that had
        // never been written since boot. Its `vp` was whatever the allocator
        // handed over, which for a uniform buffer is zeros -- and a zero
        // view-projection puts every light quad outside clip space, so the pass
        // drew nothing, drew everything, or drew noise, depending on the frame.
        //
        // It is a separate buffer rather than a longer shared one because the
        // two `Globals` structs are different (the light one carries the GI
        // rectangle and the sky), and a combined buffer would need an offset
        // that is one more number to keep correct.
        self.writeLightUniform(camera.vp, o.width, o.height);
        self.writePostUniform(o.width, o.height);
    }

    /// Writes `PostParams`. 96 bytes, fixed, every `beginScene`.
    ///
    /// The texel sizes live here rather than in the pipelines because the four
    /// passes disagree about what a texel IS — the bloom taps are half
    /// resolution — and baking either one into the shader would be a constant
    /// that is right for three passes and wrong for one.
    fn writePostUniform(self: *Backend, w: u32, h: u32) void {
        const fw: f32 = @floatFromInt(@max(1, w));
        const fh: f32 = @floatFromInt(@max(1, h));
        const bw: f32 = @floatFromInt(@max(1, w / 2));
        const bh: f32 = @floatFromInt(@max(1, h / 2));
        const env = self.environment;
        // 24 floats = 96 bytes, matching `PostParams` field for field.
        var p: [24]f32 = undefined;
        p[0] = 1.0 / fw;
        p[1] = 1.0 / fh;
        p[2] = fw;
        p[3] = fh;
        p[4] = 1.0 / bw;
        p[5] = 1.0 / bh;
        p[6] = 1.0;
        p[7] = env.fog[0];
        p[8] = env.fog[1];
        p[9] = env.fog_color[0];
        p[10] = env.fog_color[1];
        p[11] = env.fog_color[2];
        p[12] = env.fog_color[3];
        p[13] = @intFromBool(env.tonemap);
        p[14] = env.bloom_intensity;
        p[15] = env.bloom_threshold;
        // The bloom chain's own on/off, which is NOT the same question as
        // whether bloom is configured. An Environment can carry a threshold and
        // an intensity and still not want the four passes run, and the flag is
        // what keeps a scene that never enabled bloom off paying for them.
        p[16] = @intFromBool(env.bloom_intensity > 0);
        p[17] = 0;
        p[18] = 0;
        p[19] = 0;
        p[20] = 0;
        p[21] = 0;
        p[22] = 0;
        p[23] = 0;
        wgpu.wgpuQueueWriteBuffer(self.queue, self.post_uniform_buf, 0, &p, PostUniformBytes);
        self.stats_data.upload_bytes += PostUniformBytes;
    }

    /// Whether the post pass has anything to do this frame.
    ///
    /// One predicate for four pipelines. A scene with no fog, no tonemap and no
    /// bloom must not pay for a full-screen copy, and that is the whole reason
    /// this returns a bool instead of the pass running and testing three flags
    /// per pixel.
    fn postActive(self: *const Backend) bool {
        const e = self.environment;
        return e.tonemap or e.bloom_intensity > 0 or e.fog[1] > e.fog[0];
    }

    /// Writes the light pass's `Globals`. 128 bytes, fixed, every `beginScene`.
    fn writeLightUniform(self: *Backend, vp: [16]f32, w: u32, h: u32) void {
        const fw: f32 = @floatFromInt(@max(1, w));
        const fh: f32 = @floatFromInt(@max(1, h));
        // 16 mat4 + 4 screen + 4 ambient + 4 mask_rect + 4 sky = 32 floats.
        var g: [32]f32 = undefined;
        @memcpy(g[0..16], &vp);
        g[16] = fw;
        g[17] = fh;
        g[18] = 1.0 / fw;
        g[19] = 1.0 / fh;
        const env = self.environment;
        g[20] = env.ambient[0];
        g[21] = env.ambient[1];
        g[22] = env.ambient[2];
        g[23] = env.ambient[3];
        @memcpy(g[24..28], &self.gi_rect);
        g[28] = env.sky[0];
        g[29] = env.sky[1];
        g[30] = env.sky[2];
        g[31] = env.albedo;
        wgpu.wgpuQueueWriteBuffer(self.queue, self.light_uniform_buf, 0, &g, LightUniformBytes);
        self.stats_data.upload_bytes += LightUniformBytes;
    }

    fn endScene(ptr: *anyopaque, enable_smaa: bool, smaa_quality: render.SMAAQuality) void {
        const self: *Backend = @ptrCast(@alignCast(ptr));
        const o = self.scene_target orelse return;
        self.smaa_quality = smaa_quality;

        const texture = self.surface_texture orelse return;
        const surface_view = wgpu.wgpuTextureCreateView(texture, null) orelse return;
        defer wgpu.wgpuTextureViewRelease(surface_view);

        const encoder = wgpu.wgpuDeviceCreateCommandEncoder(self.device, null) orelse return;
        defer wgpu.wgpuCommandEncoderRelease(encoder);

        // Post BEFORE the resolve, not after it. Antialiasing then runs on the
        // final image rather than on an image that is about to be bloomed and
        // fogged, which is the only order in which the edge filter sees the
        // edges the viewer actually sees.
        //
        // And it decides what SMAA reads: with post on, the composite's output
        // is the frame, not `color`. Getting that backwards is not a crash —
        // it is bloom and fog that render perfectly and are then thrown away
        // by a resolve that copied the pre-post image to the screen.
        const source_view = if (self.postActive())
            (self.runPost(encoder, o) orelse o.color_view)
        else
            o.color_view;

        if (enable_smaa and self.smaa_enabled) {
            self.runSmaa(encoder, o, surface_view, &texture, source_view);
        } else {
            // Direct blit: the frame → swapchain.
            self.blitColor(encoder, source_view, surface_view, &texture);
        }
        const cmd = wgpu.wgpuCommandEncoderFinish(encoder, null) orelse return;
        defer wgpu.wgpuCommandBufferRelease(cmd);
        wgpu.wgpuQueueSubmit(self.queue, 1, @ptrCast(&cmd));
        self.acquired = true;
        self.submitTimestampResolve();
    }

    /// Runs the 3 SMAA passes. Edge and weights go to the half-res scratch
    /// targets; the neighborhood blend writes the swapchain.
    fn runSmaa(self: *Backend, encoder: wgpu.WGPUCommandEncoder, o: *Offscreen, dst_view: wgpu.WGPUTextureView, dst_texture: *const wgpu.WGPUTexture, src_view: wgpu.WGPUTextureView) void {
        _ = dst_texture;
        // The source may be the post pass's output rather than the raw scene.
        // `smaa_edge_bind` and `smaa_blend_bind` name `o.color_view` at slot 0,
        // so a run against the post output needs its own groups -- see
        // `smaaBindFor`, which picks between them by view identity.
        const edge_bind = self.smaaBindFor(o, o.smaa_edge_bind, o.color_view, src_view);
        const blend_bind = self.smaaBindFor(o, o.smaa_blend_bind, o.color_view, src_view);
        const threshold: f32 = switch (self.smaa_quality) {
            .Low => 0.05,
            .Medium => 0.10,
            .High => 0.15,
        };
        const hw = @max(1, o.width / 2);
        const hh = @max(1, o.height / 2);

        // Uniform for passes 1 and 2: half-res texel (xy) + threshold (z).
        // Sized to SmaaUniformBytes: uploading 24 bytes from a 16-byte array
        // reads 8 bytes past it (the corruption that crashed the first run).
        const half: [6]f32 = .{
            1.0 / @as(f32, @floatFromInt(hw)),
            1.0 / @as(f32, @floatFromInt(hh)),
            threshold,
            0,
            0,
            0,
        };
        wgpu.wgpuQueueWriteBuffer(self.queue, self.smaa_uniform_buf, 0, &half, SmaaUniformBytes);
        // Pass 3 uniform: FULL-res texel (xy) + edge direction (zw). The edge
        // direction must be full-res: the blend pass reads the color target at
        // full resolution (the weights come from the half-res scratch).
        const p: [6]f32 = .{
            1.0 / @as(f32, @floatFromInt(o.width)),
            1.0 / @as(f32, @floatFromInt(o.height)),
            0.0,
            1.0,
            0,
            0,
        };
        wgpu.wgpuQueueWriteBuffer(self.queue, self.smaa_blend_uniform_buf, 0, &p, SmaaUniformBytes);

        // Pass 1: edge detection (full-res src → half-res edge).
        self.smaaPass(encoder, self.smaa_pipeline_edge, edge_bind, o.edge_view, 0);
        // Pass 2: blend weights (edge → weights).
        self.smaaPass(encoder, self.smaa_pipeline_weights, o.smaa_weights_bind, o.weights_view, 1);
        // Pass 3: neighborhood blend (color + weights → swapchain).
        self.smaaPass(encoder, self.smaa_pipeline_blend, blend_bind, dst_view, 2);
    }

    /// The bind group a SMAA pass should use for `src_view`.
    ///
    /// The two groups created with the target both name `o.color_view` at slot
    /// 0, so they are correct and complete only for the raw scene. After the
    /// post pass the frame lives in `o.post_view`, and reusing those groups
    /// would antialias an image the viewer never sees.
    ///
    /// Cached rather than created per frame: the choice depends only on which
    /// view the post pass produced, which is once per frame at most, and a
    /// `createBindGroup` inside a frame violates spec §3.6.
    fn smaaBindFor(
        self: *Backend,
        o: *Offscreen,
        scene_bind: wgpu.WGPUBindGroup,
        scene_view: wgpu.WGPUTextureView,
        src_view: wgpu.WGPUTextureView,
    ) wgpu.WGPUBindGroup {
        if (src_view == scene_view) return scene_bind;
        const uniform = if (o.smaa_blend_bind == scene_bind)
            self.smaa_blend_uniform_buf
        else
            self.smaa_uniform_buf;
        const cached = if (o.smaa_blend_bind == scene_bind) &o.smaa_post_blend_bind else &o.smaa_post_edge_bind;
        if (cached.*) |existing| return existing;
        const made = createBindGroup(self.device, self.smaa_bgl, &[_]wgpu.BindGroupEntry{
            .{ .binding = 0, .textureView = src_view },
            .{ .binding = 1, .sampler = @ptrCast(self.sampler) },
            .{ .binding = 2, .buffer = uniform, .offset = 0, .size = SmaaUniformBytes },
            .{ .binding = 3, .textureView = o.weights_view },
        }, "smaa.post.bg") catch return scene_bind;
        cached.* = made;
        return made;
    }

    /// M7: the post chain. `color -> bloom_a -> bloom_b -> bloom_a -> post`.
    ///
    /// Returns the view holding the finished frame, or null on failure — in
    /// which case `endScene` falls back to the raw scene, so a post pass that
    /// cannot run degrades to "no post" rather than to a black screen.
    ///
    /// The chain's order is not arbitrary: bloom is a LOW-frequency effect, so
    /// blurring before compositing is both cheaper and better-looking than
    /// blurring after. Compositing first would also need a second full-res blur.
    fn runPost(self: *Backend, encoder: wgpu.WGPUCommandEncoder, o: *Offscreen) ?wgpu.WGPUTextureView {
        const bloom_on = self.environment.bloom_intensity > 0;
        // One attachment, reused for each pass in the chain. Declared once
        // rather than per pass because the chain is a loop over the SAME
        // attachment with a different view, and four of them would be four
        // structs where one is meant.
        var attachment = wgpu.RenderPassColorAttachment{
            .view = undefined,
            .loadOp = wgpu.LoadOp_Clear,
            .storeOp = wgpu.StoreOp_Store,
            .clearValue = .{ .r = 0.0, .g = 0.0, .b = 0.0, .a = 1.0 },
        };

        // One named type, not two anonymous ones: Zig gives the two arms of an
        // `if` expression DIFFERENT anonymous types, and a `[_]T` of each is
        // not a `[_]T`. Naming it once is the whole fix.
        const Run = struct {
            pipeline: wgpu.WGPURenderPipeline,
            bind: wgpu.WGPUBindGroup,
            view: wgpu.WGPUTextureView,
        };
        const runs: []const Run = if (bloom_on)
            &.{
                .{ .pipeline = self.post_pipeline_bright, .bind = o.post_bright_bind, .view = o.bloom_a_view },
                .{ .pipeline = self.post_pipeline_blur_h, .bind = o.post_blur_h_bind, .view = o.bloom_b_view },
                .{ .pipeline = self.post_pipeline_blur_v, .bind = o.post_blur_v_bind, .view = o.bloom_a_view },
                .{ .pipeline = self.post_pipeline_composite, .bind = o.post_composite_bind, .view = o.post_view },
            }
        else
            &.{
                // Fog and tonemap alone: one pass, no bloom, no half-res round
                // trip. This is the common case and it costs one full-screen
                // read and one write.
                .{ .pipeline = self.post_pipeline_composite, .bind = o.post_composite_bind, .view = o.post_view },
            };

        // The chain is a VARIABLE number of passes, and `timestampWrites()`
        // hands out two slots per call -- it was written for the one-pass case.
        // Reserving the whole chain's slots up front is what keeps pass N's
        // indices from colliding with pass N+1's.
        const qs = if (self.timestamps) self.query_set else null;
        const timed = qs != null and self.ts_cursor + @as(u32, @intCast(runs.len)) * 2 <= GPU_TIMESTAMP_SLOTS;
        const ts_base = self.ts_cursor;
        if (timed) self.ts_cursor += @as(u32, @intCast(runs.len)) * 2;

        for (runs, 0..) |run, n| {
            attachment.view = run.view;
            var desc = wgpu.RenderPassDescriptor{
                .colorAttachmentCount = 1,
                .colorAttachments = @ptrCast(&attachment),
            };
            if (timed) {
                var tw = wgpu.PassTimestampWrites{
                    .nextInChain = null,
                    .querySet = qs.?,
                    .beginningOfPassWriteIndex = ts_base + @as(u32, @intCast(n)) * 2,
                    .endOfPassWriteIndex = ts_base + @as(u32, @intCast(n)) * 2 + 1,
                };
                desc.timestampWrites = &tw;
            }
            const pass = wgpu.wgpuCommandEncoderBeginRenderPass(encoder, &desc) orelse return null;
            wgpu.wgpuRenderPassEncoderSetPipeline(pass, run.pipeline);
            wgpu.wgpuRenderPassEncoderSetBindGroup(pass, 0, run.bind, 0, null);
            // Three vertices, not four: the fullscreen triangle. `fs_main` in the
            // sprite shader draws 4 for the same shape because it is a strip
            // there, and this is a list.
            wgpu.wgpuRenderPassEncoderDraw(pass, 3, 1, 0, 0);
            wgpu.wgpuRenderPassEncoderEnd(pass);
            // Released HERE and not with a `defer`: a defer inside a loop runs
            // at the end of the FUNCTION, so four passes would stay open for the
            // whole chain. That is a resource leak the driver tolerates until it
            // does not.
            wgpu.wgpuRenderPassEncoderRelease(pass);
            self.stats_data.render_passes += 1;
            self.stats_data.draw_calls += 1;
        }
        self.post_passes += @intCast(runs.len);
        self.stats_data.post_passes = self.post_passes;
        return o.post_view;
    }

    fn smaaPass(
        self: *Backend,
        encoder: wgpu.WGPUCommandEncoder,
        pipeline: wgpu.WGPURenderPipeline,
        bind_group: wgpu.WGPUBindGroup,
        target_view: wgpu.WGPUTextureView,
        which: u32,
    ) void {
        var timestamp_writes = self.timestampWrites();
        const color_attachment = wgpu.RenderPassColorAttachment{
            .view = target_view,
            .loadOp = wgpu.LoadOp_Clear,
            .storeOp = wgpu.StoreOp_Store,
            .clearValue = .{ .r = 0, .g = 0, .b = 0, .a = 1 },
        };
        var pass_desc = wgpu.RenderPassDescriptor{
            .colorAttachmentCount = 1,
            .colorAttachments = @ptrCast(&color_attachment),
        };
        if (timestamp_writes) |*tw| pass_desc.timestampWrites = tw;
        const pass = wgpu.wgpuCommandEncoderBeginRenderPass(encoder, &pass_desc) orelse return;
        defer wgpu.wgpuRenderPassEncoderRelease(pass);
        self.stats_data.render_passes += 1;
        wgpu.wgpuRenderPassEncoderSetPipeline(pass, pipeline);
        self.stats_data.pipeline_changes += 1;
        wgpu.wgpuRenderPassEncoderSetBindGroup(pass, 0, bind_group, 0, null);
        self.stats_data.bind_group_changes += 1;
        // Fullscreen triangle: 3 vertices.
        wgpu.wgpuRenderPassEncoderDraw(pass, 3, 1, 0, 0);
        self.stats_data.draw_calls += 1;
        wgpu.wgpuRenderPassEncoderEnd(pass);
        _ = which;
    }

    /// Direct scene-color → destination composition (SMAA off). One fullscreen
    /// triangle sampling the offscreen color: this is the pass the editor
    /// viewport reuses in M5 to composite the game into the editor UI.
    fn blitColor(self: *Backend, encoder: wgpu.WGPUCommandEncoder, src_view: wgpu.WGPUTextureView, dst_view: wgpu.WGPUTextureView, dst_texture: *const wgpu.WGPUTexture) void {
        _ = dst_texture;
        const o = self.offscreen orelse return;
        // texel must be the FULL-RES size of the color target: fs_copy indexes
        // the src texture with full-res uvs.
        const t: [6]f32 = .{
            1.0 / @as(f32, @floatFromInt(@max(1, o.width))),
            1.0 / @as(f32, @floatFromInt(@max(1, o.height))),
            0,
            1,
            0,
            0,
        };
        wgpu.wgpuQueueWriteBuffer(self.queue, self.smaa_uniform_buf, 0, &t, SmaaUniformBytes);

        // The blit reads whichever view the post pass produced. Binding the raw
        // scene unconditionally is the bug that makes bloom and fog render
        // correctly into a texture nobody ever looks at.
        const blend_bind = self.smaaBindFor(o, o.smaa_blend_bind, o.color_view, src_view);
        self.smaaPass(encoder, self.smaa_pipeline_copy, blend_bind, dst_view, 0);
    }

    // ── M2: sprite batch submission ────────────────────────────────────────

    // ── M7: the light pass ─────────────────────────────────────────────────────

    /// The light pass: ONE instanced quad per light, additively into the scene
    /// target.
    ///
    /// A light is drawn on the target the sprite pass drew on, with the LOAD op
    /// left as Clear because the sprite pass already submitted its own encoder
    /// for this surface — WebGPU serializes submits on the same queue, so the
    /// ordering is the ordering of the submit calls, and `endScene` composites
    /// afterwards. A light drawn before the sprites would be overwritten by the
    /// sprite pass's Clear, which is why the caller runs `drawLights` second.
    fn drawLights(ptr: *anyopaque, instances: []const render.light_mod.LightInstance, count: usize) void {
        const self: *Backend = @ptrCast(@alignCast(ptr));
        if (count == 0 or !self.scene_active) {
            self.lights_drawn = 0;
            return;
        }
        const o = self.scene_target orelse return;
        if (instances.len < count or count > self.light_instance_capacity) {
            log.warn("light batch of {d} exceeds the boot capacity of {d} — clipped", .{
                count, self.light_instance_capacity,
            });
            return;
        }

        self.lights_drawn = @intCast(count);

        // 68 B per light. Uploading all `count`, not the whole buffer: the rest
        // of the buffer is a capacity, and a frame that uploaded all of it would
        // commit stale lights and pay the bandwidth for them.
        const bytes = @as(usize, count) * LightInstanceBytes;
        wgpu.wgpuQueueWriteBuffer(self.queue, self.light_instance_buf, 0, instances.ptr, bytes);
        self.stats_data.upload_bytes += bytes;

        const encoder = wgpu.wgpuDeviceCreateCommandEncoder(self.device, null) orelse return;
        defer wgpu.wgpuCommandEncoderRelease(encoder);

        var timestamp_writes = self.timestampWrites();
        const color_attachment = wgpu.RenderPassColorAttachment{
            .view = o.color_view,
            // Load, not Clear: the sprites are already in the target and the
            // light pass adds to them. Clearing here would erase the scene.
            .loadOp = wgpu.LoadOp_Load,
            .storeOp = wgpu.StoreOp_Store,
            .clearValue = .{ .r = 0.0, .g = 0.0, .b = 0.0, .a = 1.0 },
        };
        var pass_desc = wgpu.RenderPassDescriptor{
            .colorAttachmentCount = 1,
            .colorAttachments = @ptrCast(&color_attachment),
        };
        if (timestamp_writes) |*tw| pass_desc.timestampWrites = tw;
        const pass = wgpu.wgpuCommandEncoderBeginRenderPass(encoder, &pass_desc) orelse return;
        defer wgpu.wgpuRenderPassEncoderRelease(pass);
        self.stats_data.render_passes += 1;
        self.stats_data.draw_calls += 1;

        // Group by blend mode, so a scene of mixed lights is three draws at
        // most and not one per light. The CPU gathers them already grouped,
        // because `collect` walks the query in order, so this is a scan not a
        // sort.
        var i: usize = 0;
        while (i < count) {
            const mode = instances[i].blend();
            var j = i + 1;
            while (j < count and instances[j].blend() == mode) : (j += 1) {}
            const pipeline = switch (mode) {
                .add => self.light_pipeline_add,
                .subtract => self.light_pipeline_sub,
                .mix => self.light_pipeline_mix,
            };
            wgpu.wgpuRenderPassEncoderSetPipeline(pass, pipeline);
            wgpu.wgpuRenderPassEncoderSetBindGroup(pass, 0, self.light_bind_group, 0, null);
            wgpu.wgpuRenderPassEncoderSetVertexBuffer(pass, 0, self.light_instance_buf, (@as(u64, @intCast(i)) * LightInstanceBytes), bytes - @as(usize, i) * LightInstanceBytes);
            // Four corners, one per instance. No index buffer.
            wgpu.wgpuRenderPassEncoderDraw(pass, 4, @intCast(j - i), 0, 0);
            i = j;
        }

        wgpu.wgpuRenderPassEncoderEnd(pass);
        const cmd = wgpu.wgpuCommandEncoderFinish(encoder, null) orelse return;
        defer wgpu.wgpuCommandBufferRelease(cmd);
        wgpu.wgpuQueueSubmit(self.queue, 1, @ptrCast(&cmd));
    }

    /// The shadow map, ONCE. `submitLights` calls this every frame, so the whole
    /// function is a cache lookup in the steady state.
    ///
    /// It used to destroy and recreate the texture on every call, immediately
    /// above a comment saying it reuses it. Two consequences, and the second is
    /// the one that matters:
    ///
    ///   - a `createTexture` + a `release` per frame, which spec §3.6 forbids
    ///     and which stalls the driver;
    ///   - the new VIEW was never stored in `light_shadow_texture` and the
    ///     light pass's BIND GROUP was never rebuilt, so it kept pointing at the
    ///     view that had just been released. From the second frame on, every
    ///     shadow lookup read freed memory.
    ///
    /// A use-after-free that only shows up once the scene has shadows in it, and
    /// a null texture field that made `destroyOffscreen`'s cleanup a no-op.
    fn createShadowMap(ptr: *anyopaque, angles: u32) ?*anyopaque {
        const self: *Backend = @ptrCast(@alignCast(ptr));
        if (angles == 0 or angles > 1024) return null;

        // The steady state. One branch, no GPU object, no bind group.
        if (self.light_shadow_angles == angles) {
            if (self.light_shadow_texture) |t| return @ptrCast(t);
            return null;
        }

        // Changing the ANGLE COUNT genuinely needs a new texture, a new view and
        // a new bind group — the bind group holds the view, so replacing the view
        // without replacing the group is what made the old code read freed
        // memory. This is the only path that creates anything, and a quality
        // change is what reaches it.
        if (self.light_shadow_texture) |t| wgpu.wgpuTextureRelease(t);
        if (self.light_shadow_view) |v| wgpu.wgpuTextureViewRelease(v);
        self.light_shadow_texture = null;
        self.light_shadow_view = null;

        const created = wgpu.wgpuDeviceCreateTexture(self.device, &.{
            .label = wgpu.StringView.from("light.shadow"),
            .usage = wgpu.TextureUsage_TextureBinding | wgpu.TextureUsage_CopyDst,
            .dimension = wgpu.TextureDimension_2D,
            .size = .{ .width = angles, .height = 4, .depthOrArrayLayers = 1 },
            .format = wgpu.TextureFormat_R8Unorm,
            .mipLevelCount = 1,
            .sampleCount = 1,
        }) orelse return null;
        const view = wgpu.wgpuTextureCreateView(created, null) orelse {
            wgpu.wgpuTextureRelease(created);
            return null;
        };

        self.light_shadow_texture = created;
        self.light_shadow_view = view;
        self.light_shadow_angles = angles;
        self.shadow_map_creations += 1;
        self.rebuildLightBindGroup() catch return null;
        return @ptrCast(created);
    }

    /// Whether two texture views are the same object.
    ///
    /// Pointer equality on the opaque handle, which is all Dawn gives us. It
    /// answers the only question the caller has — "did the target change?" — and
    /// a target that changes every frame would rebuild the bind group every
    /// frame, which is exactly what the shadow map's cache exists to prevent.
    fn sameView(a: ?wgpu.WGPUTextureView, b: ?wgpu.WGPUTextureView) bool {
        if (a == null or b == null) return false;
        return @intFromPtr(a.?) == @intFromPtr(b.?);
    }

    /// Rebuilds the light pass's bind group from the CURRENT shadow and GI views.
    ///
    /// One function, because both views can change and getting the pairing wrong
    /// in either direction is the same bug: a bind group naming a released view
    /// (a use-after-free) or one naming the 1x1 GI placeholder forever (GI that
    /// silently never arrives).
    fn rebuildLightBindGroup(self: *Backend) !void {
        const shadow = self.light_shadow_view orelse return error.NoShadowMap;
        const layer = self.light_layer_view orelse return error.NoLayerTarget;
        wgpu.wgpuBindGroupRelease(self.light_bind_group);
        self.light_bind_group = try createBindGroup(self.device, self.light_gi_bgl, &[_]wgpu.BindGroupEntry{
            .{ .binding = 0, .buffer = self.light_uniform_buf, .offset = 0, .size = LightUniformBytes },
            .{ .binding = 1, .textureView = shadow },
            .{ .binding = 2, .textureView = self.light_gi_view },
            .{ .binding = 3, .sampler = self.light_gi_sampler },
            .{ .binding = 4, .textureView = layer },
        }, "light.bind");
    }

    /// The four 1D shadow maps, as rows of `angles` bytes each. One write per
    /// frame, at most `4 * angles` — 512 bytes at the default, which is nothing.
    fn uploadShadowMap(ptr: *anyopaque, data: []const u8) void {
        const self: *Backend = @ptrCast(@alignCast(ptr));
        const texture = self.light_shadow_texture orelse return;
        if (data.len == 0) return;
        const cols = self.light_shadow_angles;
        const rows = data.len / @as(usize, cols);
        if (rows == 0 or rows > 4 or data.len % @as(usize, cols) != 0) return;
        const dst = wgpu.TexelCopyTextureInfo{ .texture = texture };
        const layout = wgpu.TexelCopyBufferLayout{
            .bytesPerRow = cols,
            // Four rows, one per shadow channel. R8 is one byte per pixel, so
            // the row stride is the angle count and the alignment floor does
            // not apply at this size.
            .rowsPerImage = @intCast(rows),
        };
        const size = wgpu.Extent3D{ .width = cols, .height = @intCast(rows) };
        wgpu.wgpuQueueWriteTexture(self.queue, &dst, data.ptr, data.len, &layout, &size);
    }

    fn setEnvironment(ptr: *anyopaque, env: render.SceneEnvironment) void {
        const self: *Backend = @ptrCast(@alignCast(ptr));
        self.environment = env;
        // The uniform is written in `beginScene`, which is once per frame and
        // not once per environment. Writing it here too would be a second
        // 128-byte upload for a value that usually did not change.
    }

    /// M7: the GI cascade upload.
    ///
    /// Reallocates the texture only when the pyramid's dimensions change, which
    /// is on a resize and not per frame -- so the steady state is one
    /// `writeTexture` of a grid the CPU already rebuilt. Reallocating every
    /// time would also invalidate the bind group, which is why the two are done
    /// together here instead of at two call sites.
    fn uploadGi(ptr: *anyopaque, gi: render.GiUpload) void {
        const self: *Backend = @ptrCast(@alignCast(ptr));
        if (gi.width == 0 or gi.height == 0) return;
        const need = @as(usize, gi.width) * gi.height * 4;
        if (gi.pixels.len < need) return;

        self.gi_rect = gi.rect;

        if (gi.width != self.light_gi_w or gi.height != self.light_gi_h) {
            wgpu.wgpuTextureViewRelease(self.light_gi_view);
            wgpu.wgpuTextureRelease(self.light_gi_texture);
            self.light_gi_w = gi.width;
            self.light_gi_h = gi.height;

            self.light_gi_texture = wgpu.wgpuDeviceCreateTexture(self.device, &.{
                .label = wgpu.StringView.from("light.gi"),
                .usage = wgpu.TextureUsage_TextureBinding | wgpu.TextureUsage_CopyDst,
                .dimension = wgpu.TextureDimension_2D,
                .size = .{
                    .width = gi.width,
                    .height = gi.height,
                    .depthOrArrayLayers = 1,
                },
                .format = wgpu.TextureFormat_RGBA8Unorm,
                .mipLevelCount = 1,
                .sampleCount = 1,
            }) orelse return;
            self.light_gi_view =
                wgpu.wgpuTextureCreateView(self.light_gi_texture, null) orelse return;

            // The bind group holds a texture view, so a new view means a new
            // bind group — and the shadow map may not exist yet on the very
            // first frame, which is why this is a helper that can decline rather
            // than a call site that reads as unconditional.
            //
            // Forgetting this is not a crash: the old group keeps the 1x1
            // placeholder and the scene renders with GI silently disabled, which
            // is the hardest version of this bug to report.
            self.rebuildLightBindGroup() catch {};
        }

        const dst = wgpu.TexelCopyTextureInfo{ .texture = self.light_gi_texture };
        // 256 is `bytesPerRow`'s alignment floor, so the row is padded and the
        // padding has to be SKIPPED -- `writeTexture` takes the stride, not a
        // tightly packed buffer. Getting this wrong shifts every row by a few
        // bytes and the cascade becomes diagonal noise.
        const stride = gi.width * 4;
        var padded = (stride + 255) & ~@as(usize, 255);
        var scratch: ?[]u8 = null;
        defer if (scratch) |s| self.allocator.free(s);
        var src = gi.pixels;
        if (padded != stride) {
            // A padded copy for the 256-byte row alignment. On failure the
            // upload is DROPPED, not retried and not fatal: a frame with no GI
            // upload is a frame that keeps the previous cascade, and a scene
            // that cannot allocate is a scene that should still render.
            scratch = self.allocator.alloc(u8, padded * gi.height) catch null;
            if (scratch) |buf| {
                var y: usize = 0;
                while (y < gi.height) : (y += 1) {
                    const row = buf[y * padded ..][0..stride];
                    @memcpy(row, gi.pixels[y * stride ..][0..stride]);
                    @memset(buf[y * padded + stride ..][0 .. padded - stride], 0);
                }
                src = buf;
            } else {
                // Out of memory: upload the tightly packed rows anyway and let
                // the driver reject the stride. A wrong GI frame is better than
                // no frame, and this only happens when the allocation failed.
                padded = stride;
            }
        }
        const layout = wgpu.TexelCopyBufferLayout{
            .bytesPerRow = @intCast(padded),
            .rowsPerImage = gi.height,
        };
        const size = wgpu.Extent3D{ .width = gi.width, .height = gi.height };
        wgpu.wgpuQueueWriteTexture(
            self.queue,
            &dst,
            src.ptr,
            padded * gi.height,
            &layout,
            &size,
        );
        self.stats_data.upload_bytes += need;
    }

    fn drawSprites(ptr: *anyopaque, instances: []const render.SpriteInstance, count: usize) void {
        const self: *Backend = @ptrCast(@alignCast(ptr));
        if (count == 0 or !self.scene_active) return;
        const o = self.scene_target orelse return;

        self.sprites_drawn += count;

        // Upload the instance slice once per frame (32 B per sprite: 50k
        // sprites = 1.6 MB, inside the spec §4 ceiling of 2 MB).
        if (count > self.sprite_instance_capacity) {
            log.warn("sprite batch of {d} exceeds the boot capacity of {d} — clipped", .{
                count, self.sprite_instance_capacity,
            });
            return;
        }
        const bytes = @as(usize, count) * SpriteInstanceBytes;
        wgpu.wgpuQueueWriteBuffer(self.queue, self.sprite_instance_buf, 0, instances.ptr, bytes);
        self.stats_data.upload_bytes += bytes;

        const encoder = wgpu.wgpuDeviceCreateCommandEncoder(self.device, null) orelse return;
        defer wgpu.wgpuCommandEncoderRelease(encoder);

        var timestamp_writes = self.timestampWrites();
        const color_attachment = wgpu.RenderPassColorAttachment{
            .view = o.color_view,
            .loadOp = wgpu.LoadOp_Clear,
            .storeOp = wgpu.StoreOp_Store,
            .clearValue = .{ .r = 0.06, .g = 0.07, .b = 0.10, .a = 1.0 },
        };
        // The layer target, cleared to the WILDCARD. Every pixel with no sprite
        // on it therefore reads as "lit by every light", which is what a layer
        // mask means: it is about which SPRITES a light touches, and the empty
        // background belongs to everyone. Clearing to layer 0 instead would mean
        // a masked light left the whole background black.
        const layer_attachment = wgpu.RenderPassColorAttachment{
            .view = o.layer_view,
            .loadOp = wgpu.LoadOp_Clear,
            .storeOp = wgpu.StoreOp_Store,
            .clearValue = .{ .r = 1.0, .g = 0.0, .b = 0.0, .a = 1.0 },
        };
        const attachments = [_]wgpu.RenderPassColorAttachment{ color_attachment, layer_attachment };
        var pass_desc = wgpu.RenderPassDescriptor{
            .colorAttachmentCount = 2,
            .colorAttachments = @ptrCast(&attachments),
        };
        if (timestamp_writes) |*tw| pass_desc.timestampWrites = tw;
        const pass = wgpu.wgpuCommandEncoderBeginRenderPass(encoder, &pass_desc) orelse return;
        defer wgpu.wgpuRenderPassEncoderRelease(pass);
        self.stats_data.render_passes += 1;

        // Group by atlas slot: consecutive instances with the same slot are
        // ONE instanced draw (the CPU batcher already ordered them this way,
        // so this is a single linear scan).
        var i: u32 = 0;
        var current: ?u8 = null;
        var run_start: u32 = 0;
        while (i < count) : (i += 1) {
            const slot = instances[i].slot;
            if (current == null) {
                current = slot;
                run_start = i;
            } else if (slot != current.?) {
                self.emitInstancedDraw(pass, run_start, i - run_start, current.?);
                run_start = i;
                current = slot;
            }
        }
        if (current) |slot| self.emitInstancedDraw(pass, run_start, @as(u32, @intCast(count)) - run_start, slot);

        wgpu.wgpuRenderPassEncoderEnd(pass);
        const cmd = wgpu.wgpuCommandEncoderFinish(encoder, null) orelse return;
        defer wgpu.wgpuCommandBufferRelease(cmd);
        wgpu.wgpuQueueSubmit(self.queue, 1, @ptrCast(&cmd));
    }

    /// One instanced draw: 4 corners (triangle strip) x `n` instances.
    fn emitInstancedDraw(self: *Backend, pass: wgpu.WGPURenderPassEncoder, first: u32, n: u32, slot: u8) void {
        if (n == 0) return;
        const atlas = if (slot < self.atlases.items.len) self.atlases.items[slot] else null;
        const bind_group = if (atlas) |a| a.bind_group else self.white_bind_group;

        wgpu.wgpuRenderPassEncoderSetPipeline(pass, self.sprite_pipeline_textured);
        self.stats_data.pipeline_changes += 1;
        wgpu.wgpuRenderPassEncoderSetBindGroup(pass, 0, bind_group, 0, null);
        self.stats_data.bind_group_changes += 1;
        wgpu.wgpuRenderPassEncoderSetVertexBuffer(
            pass,
            0,
            self.sprite_instance_buf,
            @as(u64, first) * SpriteInstanceBytes,
            @as(u64, n) * SpriteInstanceBytes,
        );
        // 4 vertices per quad as a triangle strip, n instances of it.
        wgpu.wgpuRenderPassEncoderDraw(pass, 4, n, 0, 0);
        self.stats_data.draw_calls += 1;
        self.stats_data.vertex_count += @as(u64, n) * 4;
    }

    // ── M2: texture creation ───────────────────────────────────────────────

    fn createTexture(ptr: *anyopaque, width: u32, height: u32, pixels: []const u8) ?*anyopaque {
        const self: *Backend = @ptrCast(@alignCast(ptr));
        const w = @max(1, width);
        const h = @max(1, height);

        const texture = wgpu.wgpuDeviceCreateTexture(self.device, &.{
            .label = wgpu.StringView.from("atlas"),
            .usage = wgpu.TextureUsage_TextureBinding | wgpu.TextureUsage_CopyDst,
            .dimension = wgpu.TextureDimension_2D,
            .size = .{ .width = w, .height = h },
            .format = wgpu.TextureFormat_RGBA8Unorm,
        }) orelse return null;
        const view = wgpu.wgpuTextureCreateView(texture, null) orelse {
            wgpu.wgpuTextureRelease(texture);
            return null;
        };

        // Upload the RGBA8 pixels.
        {
            const dst = wgpu.TexelCopyTextureInfo{ .texture = texture };
            const layout = wgpu.TexelCopyBufferLayout{
                .bytesPerRow = w * 4,
                .rowsPerImage = h,
            };
            const size = wgpu.Extent3D{ .width = w, .height = h };
            const data_len = @min(pixels.len, @as(usize, w) * @as(usize, h) * 4);
            wgpu.wgpuQueueWriteTexture(self.queue, &dst, pixels.ptr, data_len, &layout, &size);
        }

        const bind_group = createBindGroup(self.device, self.sprite_bgl, &[_]wgpu.BindGroupEntry{
            .{ .binding = 0, .buffer = self.sprite_uniform_buf, .offset = 0, .size = SpriteUniformBytes },
            .{ .binding = 1, .textureView = view },
            .{ .binding = 2, .sampler = @ptrCast(self.sampler) },
        }, "atlas.bg") catch {
            wgpu.wgpuTextureViewRelease(view);
            wgpu.wgpuTextureRelease(texture);
            return null;
        };

        // Store in the atlas table (append with the boot allocator).
        const idx = self.atlases.items.len;
        self.atlases.append(self.atlas_allocator, .{
            .texture = texture,
            .view = view,
            .bind_group = bind_group,
            .width = w,
            .height = h,
        }) catch {
            wgpu.wgpuBindGroupRelease(bind_group);
            wgpu.wgpuTextureViewRelease(view);
            wgpu.wgpuTextureRelease(texture);
            return null;
        };

        self.stats_data.resources_created_total += 3;
        return @ptrFromInt(idx + 1); // +1: 0 = "no texture"
    }

    fn destroyTexture(ptr: *anyopaque, texture: ?*anyopaque) void {
        const self: *Backend = @ptrCast(@alignCast(ptr));
        const raw = @intFromPtr(texture orelse return);
        if (raw == 0) return;
        const idx = raw - 1;
        if (idx >= self.atlases.items.len) return;
        const a = &self.atlases.items[idx].?;
        wgpu.wgpuBindGroupRelease(a.bind_group);
        wgpu.wgpuTextureViewRelease(a.view);
        wgpu.wgpuTextureRelease(a.texture);
        self.atlases.items[idx] = null;
    }

    fn deinit(ptr: *anyopaque) void {
        const self: *Backend = @ptrCast(@alignCast(ptr));
        if (self.timestamps) {
            // Drain the maps still in flight BEFORE releasing the instance.
            for (&self.slots) |*slot| {
                if (slot.state != .mapping) continue;
                var wait = [_]wgpu.FutureWaitInfo{.{ .future = slot.future }};
                if (wgpu.wgpuInstanceWaitAny(self.instance, 1, &wait, std.time.ns_per_s) == wgpu.WaitStatus_Success) {
                    slot.state = .ready;
                }
            }
            if (self.query_set) |qs| wgpu.wgpuQuerySetRelease(qs);
            for (&self.slots) |*slot| {
                if (slot.state == .ready) wgpu.wgpuBufferUnmap(slot.readback_buf);
                wgpu.wgpuBufferRelease(slot.resolve_buf);
                wgpu.wgpuBufferRelease(slot.readback_buf);
            }
        }
        // Release atlases.
        for (self.atlases.items) |maybe| {
            if (maybe) |a| {
                wgpu.wgpuBindGroupRelease(a.bind_group);
                wgpu.wgpuTextureViewRelease(a.view);
                wgpu.wgpuTextureRelease(a.texture);
            }
        }
        self.atlases.deinit(self.atlas_allocator);
        if (self.offscreen) |o| self.destroyOffscreen(o);

        if (self.surface_texture) |t| wgpu.wgpuTextureRelease(t);
        wgpu.wgpuSurfaceUnconfigure(self.surface);
        wgpu.wgpuBindGroupRelease(self.quad_bind_group);
        wgpu.wgpuRenderPipelineRelease(self.quad_pipeline);
        wgpu.wgpuPipelineLayoutRelease(self.quad_layout);
        wgpu.wgpuBindGroupLayoutRelease(self.quad_bgl);
        wgpu.wgpuShaderModuleRelease(self.quad_shader);
        wgpu.wgpuBufferRelease(self.quad_uniform_buf);
        wgpu.wgpuBufferRelease(self.quad_vertex_buf);
        wgpu.wgpuBufferRelease(self.quad_index_buf);
        // M2 sprites
        wgpu.wgpuBindGroupRelease(self.white_bind_group);
        wgpu.wgpuTextureViewRelease(self.white_view);
        wgpu.wgpuTextureRelease(self.white_tex);
        wgpu.wgpuRenderPipelineRelease(self.sprite_pipeline_textured);
        wgpu.wgpuRenderPipelineRelease(self.sprite_pipeline_solid);
        wgpu.wgpuRenderPipelineRelease(self.sprite_pipeline_additive);
        wgpu.wgpuPipelineLayoutRelease(self.sprite_layout);
        wgpu.wgpuBindGroupLayoutRelease(self.sprite_bgl);
        wgpu.wgpuShaderModuleRelease(self.sprite_shader);
        wgpu.wgpuBufferRelease(self.sprite_uniform_buf);
        wgpu.wgpuBufferRelease(self.sprite_instance_buf);
        wgpu.wgpuSamplerRelease(self.sampler);
        // M2 SMAA
        wgpu.wgpuRenderPipelineRelease(self.smaa_pipeline_edge);
        wgpu.wgpuRenderPipelineRelease(self.smaa_pipeline_weights);
        wgpu.wgpuRenderPipelineRelease(self.smaa_pipeline_blend);
        wgpu.wgpuRenderPipelineRelease(self.smaa_pipeline_copy);
        wgpu.wgpuPipelineLayoutRelease(self.smaa_layout);
        wgpu.wgpuBindGroupLayoutRelease(self.smaa_bgl);
        wgpu.wgpuShaderModuleRelease(self.smaa_shader);
        wgpu.wgpuBufferRelease(self.smaa_uniform_buf);
        wgpu.wgpuBufferRelease(self.smaa_blend_uniform_buf);
        wgpu.wgpuSurfaceRelease(self.surface);
        wgpu.wgpuQueueRelease(self.queue);
        wgpu.wgpuDeviceRelease(self.device);
        wgpu.wgpuAdapterRelease(self.adapter);
        wgpu.wgpuInstanceRelease(self.instance);
        const allocator = self.allocator;
        allocator.destroy(self);
    }
};

fn containsMode(modes: []const c_uint, want: c_uint) bool {
    for (modes) |m| {
        if (m == want) return true;
    }
    return false;
}
