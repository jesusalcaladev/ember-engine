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
const sprite_wgsl = @embedFile("shaders/sprite.wgsl");
const smaa_wgsl = @embedFile("shaders/smaa.wgsl");

// Dawn ships the C API as a dispatch table (libdawn_proc) whose default
// procs are null stubs; the real implementation lives in libdawn_native.
const DawnProcTable = opaque {};
extern fn dawnProcSetProcs(procs: *const DawnProcTable) void;
extern fn @"_ZN4dawn6native15GetProcsAutogenEv"() *const DawnProcTable;

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
    depth: wgpu.WGPUTexture = undefined,
    depth_view: wgpu.WGPUTextureView = undefined,
    /// SMAA pass 1 output (edge directions), half resolution.
    edge: wgpu.WGPUTexture = undefined,
    edge_view: wgpu.WGPUTextureView = undefined,
    /// SMAA pass 2 output (blend weights), half resolution.
    weights: wgpu.WGPUTexture = undefined,
    weights_view: wgpu.WGPUTextureView = undefined,
    /// Bind groups that reference the views (recreated with the target).
    smaa_edge_bind: wgpu.WGPUBindGroup = undefined,
    smaa_weights_bind: wgpu.WGPUBindGroup = undefined,
    smaa_blend_bind: wgpu.WGPUBindGroup = undefined,
};

pub const Backend = struct {
    allocator: std.mem.Allocator,
    instance: wgpu.WGPUInstance,
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
    /// Globals uniform: mat4 (64) + texel (8) + inverse (8) + pad(8) = 88 → 96.
    const SpriteUniformBytes: u64 = 96;
    /// SMAA `EdgeUniforms`: 2 x vec2f = 24 bytes.
    const SmaaUniformBytes: u64 = 24;

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
        };
        const sprite_vlayout = wgpu.VertexBufferLayout{
            .stepMode = wgpu.VertexStepMode_Instance,
            .arrayStride = SpriteInstanceBytes,
            .attributeCount = 5,
            .attributes = &sprite_instance_attrs,
        };

        // Alpha blend state (src alpha, one-minus-src alpha).
        var blend = wgpu.BlendState{
            .color = .{ .operation = wgpu.BlendOperation_Add, .srcFactor = wgpu.BlendFactor_SrcAlpha, .dstFactor = wgpu.BlendFactor_OneMinusSrcAlpha },
            .alpha = .{ .operation = wgpu.BlendOperation_Add, .srcFactor = wgpu.BlendFactor_One, .dstFactor = wgpu.BlendFactor_OneMinusSrcAlpha },
        };
        const alpha_target = [_]wgpu.ColorTargetState{.{ .format = format, .blend = @ptrCast(&blend) }};
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
        const solid_target = [_]wgpu.ColorTargetState{.{ .format = format }};
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

        // Additive (lights in M7): src alpha + one.
        blend = wgpu.BlendState{
            .color = .{ .operation = wgpu.BlendOperation_Add, .srcFactor = wgpu.BlendFactor_SrcAlpha, .dstFactor = wgpu.BlendFactor_One },
            .alpha = .{ .operation = wgpu.BlendOperation_Add, .srcFactor = wgpu.BlendFactor_One, .dstFactor = wgpu.BlendFactor_One },
        };
        const additive_target = [_]wgpu.ColorTargetState{.{ .format = format, .blend = @ptrCast(&blend) }};
        const sprite_fragment_additive = wgpu.FragmentState{
            .module = sprite_shader,
            .entryPoint = wgpu.StringView.from("fs_main"),
            .targetCount = 1,
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
        wgpu.wgpuTextureViewRelease(o.color_view);
        wgpu.wgpuTextureRelease(o.color);
        wgpu.wgpuTextureViewRelease(o.depth_view);
        wgpu.wgpuTextureRelease(o.depth);
        wgpu.wgpuTextureViewRelease(o.edge_view);
        wgpu.wgpuTextureRelease(o.edge);
        wgpu.wgpuTextureViewRelease(o.weights_view);
        wgpu.wgpuTextureRelease(o.weights);
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

        if (enable_smaa and self.smaa_enabled) {
            self.runSmaa(encoder, o, surface_view, &texture);
        } else {
            // Direct blit: scene color → swapchain.
            self.blitColor(encoder, o.color_view, surface_view, &texture);
        }

        const cmd = wgpu.wgpuCommandEncoderFinish(encoder, null) orelse return;
        defer wgpu.wgpuCommandBufferRelease(cmd);
        wgpu.wgpuQueueSubmit(self.queue, 1, @ptrCast(&cmd));
        self.acquired = true;
        self.submitTimestampResolve();
    }

    /// Runs the 3 SMAA passes. Edge and weights go to the half-res scratch
    /// targets; the neighborhood blend writes the swapchain.
    fn runSmaa(self: *Backend, encoder: wgpu.WGPUCommandEncoder, o: *Offscreen, dst_view: wgpu.WGPUTextureView, dst_texture: *const wgpu.WGPUTexture) void {
        _ = dst_texture;
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
        self.smaaPass(encoder, self.smaa_pipeline_edge, o.smaa_edge_bind, o.edge_view, 0);
        // Pass 2: blend weights (edge → weights).
        self.smaaPass(encoder, self.smaa_pipeline_weights, o.smaa_weights_bind, o.weights_view, 1);
        // Pass 3: neighborhood blend (color + weights → swapchain).
        self.smaaPass(encoder, self.smaa_pipeline_blend, o.smaa_blend_bind, dst_view, 2);
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

        _ = src_view;
        // The blend bind group already binds the offscreen color at slot 0.
        self.smaaPass(encoder, self.smaa_pipeline_copy, o.smaa_blend_bind, dst_view, 0);
    }

    // ── M2: sprite batch submission ────────────────────────────────────────

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
        var pass_desc = wgpu.RenderPassDescriptor{
            .colorAttachmentCount = 1,
            .colorAttachments = @ptrCast(&color_attachment),
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