//! Dawn (WebGPU) backend — the real renderer (M0).
//!
//! Isolation (spec §7): only this file touches webgpu.zig. The frame loop
//! calls drawQuad/present/resize; zero allocations outside the frame arena.
//! Rendering always goes through the surface (the offscreen target arrives
//! in M2 with the editor compositor; the surface is M0's final destination).

const std = @import("std");
const render = @import("render.zig");
const wgpu = @import("webgpu.zig");
const platform = @import("../platform/platform.zig");
const log = @import("../core/log.zig").scoped("render");

const quad_wgsl = @embedFile("shaders/quad.wgsl");

// Dawn ships the C API as a dispatch table (libdawn_proc) whose default
// procs are null stubs; the real implementation lives in libdawn_native.
// At boot we point the table at native's procs — the same thing Dawn's own
// samples do with `dawnProcSetProcs(&dawn::native::GetProcs())`.
// GetProcs() is a one-liner over the autogen table, so we bind the autogen
// symbol directly (Itanium mangling of `dawn::native::GetProcsAutogen()`).
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

pub const Backend = struct {
    allocator: std.mem.Allocator,
    instance: wgpu.WGPUInstance,
    adapter: wgpu.WGPUAdapter,
    device: wgpu.WGPUDevice,
    queue: wgpu.WGPUQueue,
    surface: wgpu.WGPUSurface,
    format: c_uint,

    shader: wgpu.WGPUShaderModule,
    bgl: wgpu.WGPUBindGroupLayout,
    layout: wgpu.WGPUPipelineLayout,
    pipeline: wgpu.WGPURenderPipeline,
    bind_group: wgpu.WGPUBindGroup,
    uniform_buf: wgpu.WGPUBuffer,
    vertex_buf: wgpu.WGPUBuffer,
    index_buf: wgpu.WGPUBuffer,

    width: u32,
    height: u32,

    /// True between a successful surface acquire and the matching present.
    acquired: bool = false,
    frames: u64 = 0,
    quads_drawn: u64 = 0,

    /// 64 bytes of MVP + alignment headroom (min uniform binding size).
    const UniformSize: u64 = 256;

    const vtable = render.Renderer.VTable{
        .drawQuad = drawQuad,
        .present = present,
        .resize = resize,
        .deinit = deinit,
    };

    pub fn renderer(self: *Backend) render.Renderer {
        return .{ .ptr = self, .vtable = &vtable };
    }

    pub fn create(
        allocator: std.mem.Allocator,
        native: platform.NativeHandle,
        width: u32,
        height: u32,
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

        // Device: same async request + WaitAny pattern.
        var device_ctx = DeviceCtx{};
        const device_future = wgpu.wgpuAdapterRequestDevice(adapter, &.{
            .label = wgpu.StringView.from("ember"),
            .uncaptured_callback = deviceErrorCallback,
        }, .{
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

        const queue = wgpu.wgpuDeviceGetQueue(device) orelse return error.QueueCreationFailed;

        // Surface format: the first one the capabilities report.
        var caps = wgpu.SurfaceCapabilities{};
        if (wgpu.wgpuSurfaceGetCapabilities(surface, adapter, &caps) != wgpu.Status_Success or
            caps.formatCount == 0 or caps.formats == null)
        {
            return error.SurfaceCapabilitiesFailed;
        }
        const format = caps.formats.?[0];
        wgpu.wgpuSurfaceCapabilitiesFreeMembers(caps);
        log.info("dawn backend ready — surface format: 0x{x}", .{format});

        // Static buffers (created once at boot; spec §3.6).
        const vertex_buf = wgpu.wgpuDeviceCreateBuffer(device, &.{
            .usage = wgpu.BufferUsage_Vertex | wgpu.BufferUsage_CopyDst,
            .size = @sizeOf(@TypeOf(render.quad_vertices)),
        }) orelse return error.BufferCreationFailed;
        wgpu.wgpuQueueWriteBuffer(queue, vertex_buf, 0, &render.quad_vertices, @sizeOf(@TypeOf(render.quad_vertices)));

        const index_buf = wgpu.wgpuDeviceCreateBuffer(device, &.{
            .usage = wgpu.BufferUsage_Index | wgpu.BufferUsage_CopyDst,
            .size = @sizeOf(@TypeOf(render.quad_indices)),
        }) orelse return error.BufferCreationFailed;
        wgpu.wgpuQueueWriteBuffer(queue, index_buf, 0, &render.quad_indices, @sizeOf(@TypeOf(render.quad_indices)));

        const uniform_buf = wgpu.wgpuDeviceCreateBuffer(device, &.{
            .usage = wgpu.BufferUsage_Uniform | wgpu.BufferUsage_CopyDst,
            .size = UniformSize,
        }) orelse return error.BufferCreationFailed;

        var wgsl_src = wgpu.ShaderSourceWGSL{
            .chain = .{ .sType = wgpu.SType_ShaderSourceWGSL },
            .code = wgpu.StringView.from(quad_wgsl),
        };
        var shader_desc = wgpu.ShaderModuleDescriptor{
            .nextInChain = @ptrCast(&wgsl_src),
            .label = wgpu.StringView.from("quad.wgsl"),
        };
        const shader = wgpu.wgpuDeviceCreateShaderModule(device, &shader_desc) orelse return error.ShaderCompilationFailed;

        // Layout: binding 0 = mat4 uniform (64 bytes) visible to vertex+fragment.
        const bgl_entry = wgpu.BindGroupLayoutEntry{
            .binding = 0,
            .visibility = wgpu.ShaderStage_Vertex | wgpu.ShaderStage_Fragment,
            .buffer_type = wgpu.BufferBindingType_Uniform,
            .buffer_minBindingSize = 64,
        };
        const bgl = wgpu.wgpuDeviceCreateBindGroupLayout(device, &.{
            .entryCount = 1,
            .entries = @ptrCast(&bgl_entry),
        }) orelse return error.BindGroupLayoutFailed;

        const layout = wgpu.wgpuDeviceCreatePipelineLayout(device, &.{
            .bindGroupLayoutCount = 1,
            .bindGroupLayouts = @ptrCast(&bgl),
        }) orelse return error.PipelineLayoutFailed;

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
            .module = shader,
            .entryPoint = wgpu.StringView.from("fs_main"),
            .targetCount = 1,
            .targets = &targets,
        };
        const pipeline = wgpu.wgpuDeviceCreateRenderPipeline(device, &.{
            .layout = layout,
            .vertex_module = shader,
            .vertex_entryPoint = wgpu.StringView.from("vs_main"),
            .vertex_bufferCount = 1,
            .vertex_buffers = @ptrCast(&vertex_layout),
            .fragment = &fragment,
        }) orelse return error.PipelineCreationFailed;

        const bind_entry = wgpu.BindGroupEntry{
            .binding = 0,
            .buffer = uniform_buf,
            .offset = 0,
            .size = 64,
        };
        const bind_group = wgpu.wgpuDeviceCreateBindGroup(device, &.{
            .layout = bgl,
            .entryCount = 1,
            .entries = @ptrCast(&bind_entry),
        }) orelse return error.BindGroupFailed;

        const self = try allocator.create(Backend);
        self.* = .{
            .allocator = allocator,
            .instance = instance,
            .adapter = adapter,
            .device = device,
            .queue = queue,
            .surface = surface,
            .format = format,
            .shader = shader,
            .bgl = bgl,
            .layout = layout,
            .pipeline = pipeline,
            .bind_group = bind_group,
            .uniform_buf = uniform_buf,
            .vertex_buf = vertex_buf,
            .index_buf = index_buf,
            .width = width,
            .height = height,
        };
        self.configureSurface();
        return self;
    }

    fn configureSurface(self: *Backend) void {
        wgpu.wgpuSurfaceConfigure(self.surface, &.{
            .device = self.device,
            .format = self.format,
            .usage = wgpu.TextureUsage_RenderAttachment,
            .width = self.width,
            .height = self.height,
        });
    }

    /// Acquire the surface texture, reconfiguring once on outdated/lost.
    fn acquireTexture(self: *Backend) ?wgpu.WGPUTexture {
        var surf_tex: wgpu.SurfaceTexture = undefined;
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

    fn drawQuad(ptr: *anyopaque, mvp: *const [16]f32) void {
        const self: *Backend = @ptrCast(@alignCast(ptr));
        self.quads_drawn += 1;

        // MVP upload (fixed 64 bytes, boot-sized buffer; spec §3.6).
        wgpu.wgpuQueueWriteBuffer(self.queue, self.uniform_buf, 0, mvp, 64);

        const texture = self.acquireTexture() orelse return; // minimized window: skip frame
        const view = wgpu.wgpuTextureCreateView(texture, null) orelse {
            wgpu.wgpuTextureRelease(texture);
            return;
        };

        // Encode: clear + draw the quad. No allocations: everything is
        // created and released inside this function (spec §3.1).
        const encoder = wgpu.wgpuDeviceCreateCommandEncoder(self.device, null) orelse {
            wgpu.wgpuTextureViewRelease(view);
            wgpu.wgpuTextureRelease(texture);
            return;
        };
        const color_attachment = wgpu.RenderPassColorAttachment{
            .view = view,
            .loadOp = wgpu.LoadOp_Clear,
            .storeOp = wgpu.StoreOp_Store,
            .clearValue = .{ .r = 0.06, .g = 0.07, .b = 0.10, .a = 1.0 },
        };
        const pass = wgpu.wgpuCommandEncoderBeginRenderPass(encoder, &.{
            .colorAttachmentCount = 1,
            .colorAttachments = @ptrCast(&color_attachment),
        }) orelse {
            wgpu.wgpuCommandEncoderRelease(encoder);
            wgpu.wgpuTextureViewRelease(view);
            wgpu.wgpuTextureRelease(texture);
            return;
        };
        wgpu.wgpuRenderPassEncoderSetPipeline(pass, self.pipeline);
        wgpu.wgpuRenderPassEncoderSetBindGroup(pass, 0, self.bind_group, 0, null);
        wgpu.wgpuRenderPassEncoderSetVertexBuffer(pass, 0, self.vertex_buf, 0, @sizeOf(@TypeOf(render.quad_vertices)));
        wgpu.wgpuRenderPassEncoderSetIndexBuffer(pass, self.index_buf, wgpu.IndexFormat_Uint16, 0, @sizeOf(@TypeOf(render.quad_indices)));
        wgpu.wgpuRenderPassEncoderDrawIndexed(pass, 6, 1, 0, 0, 0);
        wgpu.wgpuRenderPassEncoderEnd(pass);
        wgpu.wgpuRenderPassEncoderRelease(pass);

        const cmd = wgpu.wgpuCommandEncoderFinish(encoder, null) orelse {
            wgpu.wgpuCommandEncoderRelease(encoder);
            wgpu.wgpuTextureViewRelease(view);
            wgpu.wgpuTextureRelease(texture);
            return;
        };
        wgpu.wgpuQueueSubmit(self.queue, 1, @ptrCast(&cmd));
        wgpu.wgpuCommandBufferRelease(cmd);
        wgpu.wgpuCommandEncoderRelease(encoder);
        wgpu.wgpuTextureViewRelease(view);
        wgpu.wgpuTextureRelease(texture);
        self.acquired = true;
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
        self.width = @max(1, width);
        self.height = @max(1, height);
        self.configureSurface();
    }

    fn deinit(ptr: *anyopaque) void {
        const self: *Backend = @ptrCast(@alignCast(ptr));
        wgpu.wgpuSurfaceUnconfigure(self.surface);
        wgpu.wgpuBindGroupRelease(self.bind_group);
        wgpu.wgpuRenderPipelineRelease(self.pipeline);
        wgpu.wgpuPipelineLayoutRelease(self.layout);
        wgpu.wgpuBindGroupLayoutRelease(self.bgl);
        wgpu.wgpuShaderModuleRelease(self.shader);
        wgpu.wgpuBufferRelease(self.uniform_buf);
        wgpu.wgpuBufferRelease(self.vertex_buf);
        wgpu.wgpuBufferRelease(self.index_buf);
        wgpu.wgpuSurfaceRelease(self.surface);
        wgpu.wgpuQueueRelease(self.queue);
        wgpu.wgpuDeviceRelease(self.device);
        wgpu.wgpuAdapterRelease(self.adapter);
        wgpu.wgpuInstanceRelease(self.instance);
        const allocator = self.allocator;
        allocator.destroy(self);
    }
};
