//! M2 sprite shader — INSTANCED (one 32-byte record per sprite).
//!
//! Why instanced: 6 vertices x 36 B x 50k sprites = 10.8 MB uploaded every
//! frame, which breaks spec §4 ("staging uploads <= 2 MB/frame") by 5x. One
//! 32-byte instance record keeps the 50k scene at 1.6 MB and the four quad
//! corners are derived from `vertex_index` with a triangle-strip topology —
//! no index buffer, no CPU-side vertex expansion.
//!
//! Draw-call budget: one instanced draw per (atlas slot, blend) run, so a
//! scene built from one atlas is 1 draw call (spec §4 allows 32).

struct Globals {
    // Column-major view-projection. Uploaded once per scene pass.
    vp: mat4x4<f32>,
    // xy = texture size in pixels, zw = 1 / texture size.
    texel: vec2f,
    inverse: vec2f,
    _pad: vec2f,
};

@group(0) @binding(0) var<uniform> globals: Globals;
@group(0) @binding(1) var atlas_tex: texture_2d<f32>;
@group(0) @binding(2) var atlas_smp: sampler;

/// One sprite: 32 bytes. Matches render.SpriteInstance field for field.
struct Instance {
    @location(0) pos: vec2f,      // world center
    @location(1) half: vec2f,     // half extents
    @location(2) uv: vec4f,       // (u0, v0, u1, v1) unorm16
    @location(3) color: vec4f,    // rgba unorm8
    @location(4) slot: u32,       // atlas slot (unused here; drives batching)
};

struct VSOut {
    @builtin(position) pos: vec4f,
    @location(0) uv: vec2f,
    @location(1) color: vec4f,
};

/// Triangle-strip corners from the vertex index: (0,0) (1,0) (0,1) (1,1).
/// No vertex buffer is bound at all.
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

@fragment
fn fs_main(in: VSOut) -> @location(0) vec4f {
    // Clamp half a texel inside the sprite rect: without it the bilinear
    // filter of a packed atlas bleeds the neighbouring sprite (the classic
    // transparent fringe).
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

/// Untextured variant (a material without atlas): solid tint per instance.
@fragment
fn fs_main_solid(in: VSOut) -> @location(0) vec4f {
    return in.color;
}