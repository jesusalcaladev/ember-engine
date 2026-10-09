# Shaders

**Sources:** `src/engine/render/shaders/*.wgsl`, `src/engine/render/backend_dawn.zig`

The engine uses three WGSL shader modules, all embedded at compile time via `@embedFile`:

```zig
const quad_wgsl = @embedFile("shaders/quad.wgsl");
const sprite_wgsl = @embedFile("shaders/sprite.wgsl");
const smaa_wgsl = @embedFile("shaders/smaa.wgsl");
```

## Pipeline overview

The Dawn backend creates all GPU objects (pipelines, buffers, textures, bind groups) at boot or on resize only — never inside a frame (spec §3.6). The frame loop only calls `writeBuffer` + record + submit.

The M2 frame pipeline, in order:

1. **Scene pass** → offscreen color target. Sprites arrive already sorted by the CPU batcher; one instanced draw per (texture, blend) pair.
2. **SMAA** (optional, 3 passes) → swapchain. Edge and weight passes use half-resolution scratch targets.
3. **Present** → swapchain.

---

## Quad shader (`quad.wgsl`)

The M0 legacy shader: draws a single quad with an MVP transform. Kept for compatibility; M2 code uses the sprite shader.

```wgsl
struct Uniforms {
    mvp: mat4x4<f32>,
}

@group(0) @binding(0) var<uniform> uniforms: Uniforms;

struct VSOut {
    @builtin(position) pos: vec4f,
    @location(0) color: vec4f,
}

@vertex
fn vs_main(@location(0) pos: vec2f, @location(1) color: vec4f) -> VSOut {
    var out: VSOut;
    out.pos = uniforms.mvp * vec4f(pos, 0.0, 1.0);
    out.color = color;
    return out;
}

@fragment
fn fs_main(in: VSOut) -> @location(0) vec4f {
    return in.color;
}
```

The vertex buffer is a centered unit quad (4 vertices, 6 indices). The shader scales it with the MVP.

---

## Sprite shader (`sprite.wgsl`)

The M2 instanced sprite shader. One 32-byte record per sprite; the four quad corners are derived from `vertex_index` with a triangle-strip topology — no index buffer, no CPU-side vertex expansion.

### Globals uniform

```wgsl
struct Globals {
    vp: mat4x4<f32>,       // column-major view-projection
    texel: vec2f,          // xy = texture size in pixels
    inverse: vec2f,        // zw = 1 / texture size
    _pad: vec2f,
};

@group(0) @binding(0) var<uniform> globals: Globals;
@group(0) @binding(1) var atlas_tex: texture_2d<f32>;
@group(0) @binding(2) var atlas_smp: sampler;
```

### Instance layout

```wgsl
struct Instance {
    @location(0) pos: vec2f,      // world center
    @location(1) half: vec2f,     // half extents
    @location(2) uv: vec4f,       // (u0, v0, u1, v1) unorm16
    @location(3) color: vec4f,    // rgba unorm8
    @location(4) slot: u32,       // atlas slot (drives batching)
};
```

### Vertex shader

The four corners come from `@builtin(vertex_index)`: (0,0), (1,0), (0,1), (1,1) as a triangle strip:

```wgsl
@vertex
fn vs_main(@builtin(vertex_index) vi: u32, inst: Instance) -> VSOut {
    let cx = f32(vi & 1u);
    let cy = f32((vi >> 1u) & 1u);
    let corner = vec2f(cx, cy) * 2.0 - 1.0; // -1..1

    var out: VSOut;
    out.pos = globals.vp * vec4f(inst.pos + corner * inst.half, 0.0, 1.0);
    out.uv = mix(inst.uv.xy, inst.uv.zw, vec2f(cx, cy));
    out.color = inst.color;
    return out;
}
```

### Fragment shader (textured)

Clamps half a texel inside the sprite rect to prevent bilinear filtering from bleeding neighbouring sprites in a packed atlas:

```wgsl
@fragment
fn fs_main(in: VSOut) -> @location(0) vec4f {
    let inset = min(
        0.5,
        min(
            min(in.uv.x, 1.0 - in.uv.x) * globals.texel.x,
            min(in.uv.y, 1.0 - in.uv.y) * globals.texel.y,
        ),
    );
    let uv = clamp(
        in.uv + vec2f(inset) * sign(in.uv - vec2f(0.5)),
        vec2f(0.0),
        vec2f(1.0),
    );
    return in.color * textureSample(atlas_tex, atlas_smp, uv);
}
```

### Fragment shader (solid)

Untextured variant for materials without an atlas:

```wgsl
@fragment
fn fs_main_solid(in: VSOut) -> @location(0) vec4f {
    return in.color;
}
```

### Blend variants

The Dawn backend creates three pipeline variants from this shader:

| Pipeline | Fragment entry | Blend state |
|---|---|---|
| `sprite.textured` | `fs_main` | SrcAlpha / OneMinusSrcAlpha |
| `sprite.solid` | `fs_main_solid` | None (opaque) |
| `sprite.additive` | `fs_main` | SrcAlpha / One |

---

## SMAA shader (`smaa.wgsl`)

SMAA 1x (Subpixel Morphological Anti-Aliasing), ported to WGSL. Reference: Timothy Lottes' SMAA.hlsl (NVIDIA), 3 passes.

### Why SMAA

- **vs MSAA**: no 4× memory/bandwidth on the offscreen color target.
- **vs FXAA**: does not blur the interior of sprites; only blends pixels on detected edges, so text and UI keep their sharpness.
- **vs TAA**: no temporal jitter, no ghosting.

Cost on the reference iGPU (1080p): ~0.2 ms for the 3 passes.

### Uniforms

```wgsl
struct EdgeUniforms {
    texel: vec2f,    // xy = target size in pixels, zw = 1 / target size
    inverse: vec2f,
    params: vec2f,   // x = edge threshold (0.05 low, 0.10 medium, 0.15 high)
};

@group(0) @binding(0) var src_tex: texture_2d<f32>;
@group(0) @binding(1) var src_smp: sampler;
@group(0) @binding(2) var<uniform> u: EdgeUniforms;
@group(0) @binding(3) var weights_tex: texture_2d<f32>;
```

All three passes share ONE bind group layout. Unused bindings in passes 1–2 are what lets all three passes share one pipeline layout and one set of cached bind groups (spec §3.6: no GPU object is created inside a frame).

### Fullscreen triangle

```wgsl
@vertex
fn vs_fullscreen(@builtin(vertex_index) vi: u32) -> @builtin(position) vec4f {
    var p = array<vec2f, 3>(
        vec2f(-1.0, -1.0),
        vec2f( 3.0, -1.0),
        vec2f(-1.0,  3.0),
    );
    return vec4f(p[vi], 0.0, 1.0);
}
```

### Pass 1: Edge detection (`fs_edge`)

SMAA's luma edge detector — 4 taps at 1px, thresholded against the pixel above:

```wgsl
@fragment
fn fs_edge(@builtin(position) frag: vec4f) -> EdgeOut {
    let uv = frag.xy * u.texel;
    let t = u.texel;
    let l_nw = luma(textureSample(src_tex, src_smp, uv + vec2f(-t.x, -t.y)).rgb);
    let l_ne = luma(textureSample(src_tex, src_smp, uv + vec2f( t.x, -t.y)).rgb);
    let l_sw = luma(textureSample(src_tex, src_smp, uv + vec2f(-t.x,  t.y)).rgb);
    let l_se = luma(textureSample(src_tex, src_smp, uv + vec2f( t.x,  t.y)).rgb);
    let l_m  = luma(textureSample(src_tex, src_smp, uv).rgb);
    let l_min = min(l_m, min(min(l_nw, l_ne), min(l_sw, l_se)));
    let l_max = max(l_m, max(max(l_nw, l_ne), max(l_sw, l_se)));
    var out: EdgeOut;
    if (l_max - l_min < max(0.0312, l_max * 0.125)) {
        out.color = vec4f(0.0);
        return out;
    }
    // Direction detection (smallest neighbour delta wins)
    var d: f32;
    d = abs(l_m - l_nw);
    let d_n = abs(l_m - l_ne);
    let d_sw = abs(l_m - l_sw);
    let d_se = abs(l_m - l_se);
    let d_min = min(d, min(min(d_n, d_sw), d_se));
    let dir = vec2f(
        select(1.0, -1.0, d == abs(l_m - l_nw) || d_sw <= d_min),
        select(1.0, -1.0, d == abs(l_m - l_nw) || d_n <= d_min),
    );
    out.color = vec4f(dir * 0.5 + 0.5, 0.0, 1.0);
    return out;
}
```

### Pass 2: Blend weights (`fs_weights`)

Computes blend weights along the detected edge. WGSL requires `textureSample` in uniform control flow, so every tap is taken up front:

```wgsl
@fragment
fn fs_weights(@builtin(position) frag: vec4f) -> EdgeOut {
    let uv = frag.xy * u.texel;
    let t = u.texel;
    let e = textureSample(src_tex, src_smp, uv).rg;
    let dir = e.rg * 2.0 - 1.0;
    let ortho = vec2f(dir.y, -dir.x);

    let l_n = luma(textureSample(src_tex, src_smp, uv - ortho * t).rgb);
    let l_s = luma(textureSample(src_tex, src_smp, uv + ortho * t).rgb);
    let l_w = luma(textureSample(src_tex, src_smp, uv + dir * t).rgb);
    let l_e = luma(textureSample(src_tex, src_smp, uv - dir * t).rgb);
    let l_m = luma(textureSample(src_tex, src_smp, uv).rgb);

    let l_min = min(l_m, min(min(l_n, l_s), min(l_w, l_e)));
    let l_max = max(l_m, max(max(l_n, l_s), max(l_w, l_e)));
    let contrast = l_max - l_min;
    let has_edge = dot(dir, dir) >= 0.25 && contrast >= max(0.0312, l_max * 0.125);

    var d: f32;
    let d_n = abs(l_m - l_n);
    let d_s = abs(l_m - l_s);
    let d_w = abs(l_m - l_w);
    let d_e = abs(l_m - l_e);
    d = select(d, d_n, d_n < d);
    d = select(d, d_s, d_s < d);
    d = select(d, d_w, d_w < d);
    d = select(d, d_e, d_e < d);
    let w = select(0.0, 0.5 - 0.5 * clamp(d / u.params.x, 0.0, 1.0), has_edge);

    var out: EdgeOut;
    out.color = vec4f(w, w, w, 1.0);
    return out;
}
```

### Pass 3: Neighborhood blend (`fs_blend`)

Blends along the edge direction using the precomputed weights:

```wgsl
@fragment
fn fs_blend(@builtin(position) frag: vec4f) -> EdgeOut {
    let t = u.texel;
    let uv = frag.xy * t;
    let w = textureSample(weights_tex, src_smp, uv).x;
    let ortho = vec2f(u.inverse.y, -u.inverse.x) * t;
    let center = textureSample(src_tex, src_smp, uv);
    let a = textureSample(src_tex, src_smp, uv - ortho);
    let b = textureSample(src_tex, src_smp, uv + ortho);

    var out: EdgeOut;
    out.color = select(center, mix(a, b, w), w >= 0.0312);
    return out;
}
```

### Copy pass (`fs_copy`)

Plain copy for the offscreen → swapchain composition when SMAA is off, and the editor's viewport blit:

```wgsl
@fragment
fn fs_copy(@builtin(position) frag: vec4f) -> EdgeOut {
    let uv = frag.xy * u.texel;
    var out: EdgeOut;
    out.color = textureSample(src_tex, src_smp, uv);
    return out;
}
```

---

## Dawn backend integration

### Shader creation

Shaders are compiled at boot via `wgpuDeviceCreateShaderModule`:

```zig
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
```

### Sprite pipeline instance layout

The instance buffer is a single 32-byte record per sprite, stepping per instance:

```zig
const sprite_instance_attrs = [_]wgpu.VertexAttribute{
    .{ .format = wgpu.VertexFormat_Float32x2, .offset = 0,  .shaderLocation = 0 },  // pos
    .{ .format = wgpu.VertexFormat_Float32x2, .offset = 8,  .shaderLocation = 1 },  // half
    .{ .format = wgpu.VertexFormat_Unorm16x4, .offset = 16, .shaderLocation = 2 },  // uv
    .{ .format = wgpu.VertexFormat_Unorm8x4,  .offset = 24, .shaderLocation = 3 },  // color
    .{ .format = wgpu.VertexFormat_Uint32,     .offset = 28, .shaderLocation = 4 },  // slot
};
const sprite_vlayout = wgpu.VertexBufferLayout{
    .stepMode = wgpu.VertexStepMode_Instance,
    .arrayStride = SpriteInstanceBytes,  // 32
    .attributeCount = 5,
    .attributes = &sprite_instance_attrs,
};
```

### SMAA pipeline creation

SMAA passes use the fullscreen triangle (no vertex buffer):

```zig
fn createRenderPipeline(
    device: wgpu.WGPUDevice,
    layout: wgpu.WGPUPipelineLayout,
    module: wgpu.WGPUShaderModule,
    label: [:0]const u8,
    entry_point: [:0]const u8,
    targets: []const wgpu.ColorTargetState,
) !wgpu.WGPURenderPipeline {
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
```

### SMAA quality thresholds

```zig
const threshold: f32 = switch (self.smaa_quality) {
    .Low => 0.05,
    .Medium => 0.10,
    .High => 0.15,
};
```

### Offscreen target

The offscreen target holds color, depth/stencil, and two half-resolution SMAA scratch textures. All bind groups are created once with the target, never inside a frame:

```zig
const Offscreen = struct {
    width: u32,
    height: u32,
    color: wgpu.WGPUTexture,
    color_view: wgpu.WGPUTextureView,
    depth: wgpu.WGPUTexture,
    depth_view: wgpu.WGPUTextureView,
    edge: wgpu.WGPUTexture,       // half-res SMAA edge output
    edge_view: wgpu.WGPUTextureView,
    weights: wgpu.WGPUTexture,    // half-res SMAA weights output
    weights_view: wgpu.WGPUTextureView,
    smaa_edge_bind: wgpu.WGPUBindGroup,
    smaa_weights_bind: wgpu.WGPUBindGroup,
    smaa_blend_bind: wgpu.WGPUBindGroup,
};
```

### GPU timestamps

Per-pass GPU timestamps are chained into every render pass, resolved and read back with 2 frames of latency and a non-blocking map poll. The readback uses 6 slots to avoid racing the GPU:

```zig
const SLOTS = 6;
const GPU_TIMESTAMP_SLOTS: u32 = 12;  // 2 timestamps x 5 instrumented passes
const GPU_TIMESTAMP_PERIOD_NS: f64 = 1.0;
```

Instrumented passes: scene, smaa_edge, smaa_weights, smaa_blend, present-composite.
