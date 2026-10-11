//! M7: the light pass.
//!
//! One instanced quad per light. Everything a pixel needs — where the light is,
//! how far it reaches, how wide its cone is, how soft its shadow is — arrives in
//! the instance, and the only texture lookup is the 1D shadow map the CPU built.
//!
//! # Why a quad per light and not a fullscreen loop
//!
//! A fullscreen fragment loop over twenty lights reads every light of the scene
//! for every pixel of every frame, whether or not the light reaches that pixel.
//! A quad per light is bounded by the lit area, and it discards nothing: the
//! falloff reaches exactly zero at the quad's edge, which is why the quad can be
//! exactly the light's radius.
//!
//! # The three blend modes are three pipelines, not a branch
//!
//! `add` and `subtract` are different blend factors, and `mix` is a lerp that
//! only the fixed-function blend stage can express: the fragment program cannot
//! read the destination it is writing. So the three modes are three pipelines
//! sharing one vertex layout and one fragment program, and the mode is part of
//! the instance's flags — which is also how the CPU reference selects it.
//!
//! # This mirrors `light.zig`'s `coverage`
//!
//! Line for line, function for function. The CPU half is the reference because
//! it can be tested headless, which is the only reason to trust a shader nobody
//! can read. If the two ever disagree, the CPU is right and the shader has a bug.

struct LightIn {
    /// Byte 0: world centre.
    @location(0) pos: vec2f,
    /// Byte 8: reach (used), extent (unused).
    @location(1) radius_extent: vec2f,
    /// Byte 16: quad half extents.
    @location(2) half: vec2f,
    /// Byte 24: direction in radians, cos of the outer cone.
    @location(3) angle_cos: vec2f,
    /// Byte 32: cos of the inner cone, energy.
    @location(4) cos_inner_energy: vec2f,
    /// Byte 40: rgb + opacity.
    @location(5) color: vec4f,
    /// Byte 48: attenuation exponent, shadow softness.
    @location(6) atten_soft: vec2f,
    /// Byte 56: gi contribution, packed flags.
    @location(7) gi_flags: vec2f,
};

// flags: kind & 7 | blend << 3 | filter << 5 | has_shadow << 7 | channel << 8
const KIND_MASK: u32 = 7u;
const KIND_POINT: u32 = 0u;
const KIND_SPOT: u32 = 1u;
const KIND_DIRECTIONAL: u32 = 2u;
const HAS_SHADOW_SHIFT: u32 = 7u;
const CHANNEL_SHIFT: u32 = 8u;
const CHANNEL_MASK: u32 = 15u;

struct Globals {
    vp: mat4x4f,
    // Screen size in pixels and the inverse.
    screen: vec2f,
    inv_screen: vec2f,
    // Ambient colour and the global light energy: the Environment (M7).
    ambient: vec4f,
};

@group(0) @binding(0) var<uniform> globals: Globals;

// The 1D shadow maps: one row per channel, one column per direction. Sampled
// with texelFetch rather than a sampler because the index is an ANGLE BUCKET,
// not a coordinate: a filtered sample would blend two directions and produce a
// shadow that leaks on one side and darkens the other.
@group(0) @binding(1) var shadow_map: texture_2d<f32>;

struct VSOut {
    @builtin(position) clip: vec4f,
    @location(0) light_pos: vec2f,
    @location(1) world: vec2f,
    // Every per-instance scalar travels as its own location so nothing is
    // interpolated: a `u32` that survived a varying would be garbage.
    @location(2) si_radius: f32,
    @location(3) si_energy: f32,
    @location(4) si_atten: f32,
    @location(5) si_softness: f32,
    @location(6) si_cos_outer: f32,
    @location(7) si_cos_inner: f32,
    @location(8) si_angle: f32,
    @location(9) si_gi: f32,
    @location(10) @interpolate(flat) si_flags: u32,
    @location(11) @interpolate(flat) si_color: vec4f,
};

@vertex
fn vs_main(vi: u32, in: LightIn) -> VSOut {
    // The four corners of a triangle strip, in the light's own rectangle. No
    // vertex buffer beyond the instance stream, which is the same trick the
    // sprite shader uses.
    let cx = f32(vi & 1u);
    let cy = f32((vi >> 1u) & 1u);
    let corner = vec2f(cx, cy) * 2.0 - 1.0;
    let flags = bitcast<u32>(in.gi_flags.y);

    var out: VSOut;
    out.clip = globals.vp * vec4f(in.pos + corner * in.half, 0.0, 1.0);
    out.light_pos = in.pos;
    out.world = in.pos + corner * in.half;
    out.si_radius = in.radius_extent.x;
    out.si_energy = in.cos_inner_energy.y;
    out.si_atten = in.atten_soft.x;
    out.si_softness = in.atten_soft.y;
    out.si_cos_outer = in.angle_cos.y;
    out.si_cos_inner = in.cos_inner_energy.x;
    out.si_angle = in.angle_cos.x;
    out.si_gi = in.gi_flags.x;
    out.si_flags = flags;
    out.si_color = in.color;
    return out;
}

@fragment
fn fs_main(in: VSOut) -> @location(0) vec4f {
    let kind = in.si_flags & KIND_MASK;
    let color = in.si_color;

    let to_pixel = in.world - in.light_pos;
    let dist = length(to_pixel);
    let radius = max(in.si_radius, 1e-4);
    let rec01 = dist / radius;

    var falloff: f32 = 0.0;
    if (kind == KIND_POINT) {
        falloff = 1.0 - min(rec01, 1.0);
    } else {
        // A spot or a directional light: how much the direction to the pixel
        // agrees with the light's own direction. ONE `dot` of two unit-ish
        // vectors, and it is the whole cone test.
        let light_dir = vec2f(cos(in.si_angle), sin(in.si_angle));
        let pixel_dir = to_pixel / max(dist, 1e-6);
        let c = dot(light_dir, pixel_dir);
        if (c <= in.si_cos_outer) {
            // Behind the cone, or past its outer edge: nothing.
            falloff = 0.0;
        } else if (c >= in.si_cos_inner) {
            falloff = 1.0 - min(rec01, 1.0);
        } else {
            // The penumbra: a smooth ramp across the cone's edge, so a spotlight
            // looks like a light and not a triangle. Mirrors `coverage`.
            let t = (c - in.si_cos_outer) / max(in.si_cos_inner - in.si_cos_outer, 1e-6);
            falloff = t * t * (3.0 - 2.0 * t) * (1.0 - min(rec01, 1.0));
        }
    }
    if (falloff <= 0.0) {
        return vec4f(0.0);
    }
    falloff = pow(max(falloff, 0.0), max(in.si_atten, 0.0));

    // SHADOWS. The 1D shadow map is indexed by the pixel's ANGLE from the
    // light, in the light's own row — one texel fetch for the whole test.
    //
    // The value is blocker PROXIMITY (`1 - distance/radius`), so the pixel is lit
    // when it is nearer the light than the blocker is. Averaging those values
    // over filter taps widens the penumbra; averaging two boolean masks would
    // give you a boolean mask with greyer corners.
    var vis: f32 = 1.0;
    if ((in.si_flags & (1u << HAS_SHADOW_SHIFT)) != 0u) {
        let channel: u32 = (in.si_flags >> CHANNEL_SHIFT) & CHANNEL_MASK;
        var theta = atan2(to_pixel.y, to_pixel.x);
        if (theta < 0.0) {
            theta = theta + 6.283185307179586;
        }
        let angles = f32(textureDimensions(shadow_map).x);
        var idx = u32(theta / 6.283185307179586 * angles);
        idx = min(idx, u32(angles) - 1u);
        let occ = textureLoad(shadow_map, vec2u(idx, channel), 0).r;

        let width = max(in.si_softness * rec01, 1e-4);
        vis = smoothstep(occ - width, occ, 1.0 - rec01);
    }

    // GI is NOT sampled here. The enclosure term lives in the CPU's distance
    // field, and reading it in a fragment program means uploading that field as
    // a texture and binding it — a piece of work that is deliberately not in
    // this commit, which is why `si_gi` is carried but unused. A light whose GI
    // is meant to darken an enclosed room therefore lights that room at full
    // strength on the GPU while the CPU reference says otherwise, and the CPU
    // reference is the one that is tested. This is a real gap and it is stated
    // rather than papered over with a constant that looks like an answer.
    let rgb = color.rgb * falloff * vis;
    let alpha = color.a;
    return vec4f(rgb, rgb);
}

/// A smoothstep, mirroring `light.zig`'s.
fn smoothstep(e0: f32, e1: f32, x: f32) -> f32 {
    let t = clamp((x - e0) / max(e1 - e0, 1e-9), 0.0, 1.0);
    return t * t * (3.0 - 2.0 * t);
}
