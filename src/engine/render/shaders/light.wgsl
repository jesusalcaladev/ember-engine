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
// An ambient is not a point light at a large radius: its curve is FLAT across
// 80% of its reach, because the whole point of an ambient is that it does not
// dim as you walk away from it.
const KIND_AMBIENT: u32 = 3u;
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
    // The GI cascade's world-space rectangle, so a lookup can turn a world
    // position into a texel. `xy` is the min corner and `zw` the max.
    mask_rect: vec4f,
    // Sky colour and the bounce albedo, matching `CascadeParams` in
    // radiance.wgsl. The two shaders read the same numbers because they are
    // solving the same problem; a divergence here shows up as bounce light that
    // changes colour when the GI cascades are rebuilt.
    sky: vec4f,
};

@group(0) @binding(0) var<uniform> globals: Globals;

// The 1D shadow maps: one row per channel, one column per direction. Sampled
// with texelFetch rather than a sampler because the index is an ANGLE BUCKET,
// not a coordinate: a filtered sample would blend two directions and produce a
// shadow that leaks on one side and darkens the other.
@group(0) @binding(1) var shadow_map: texture_2d<f32>;

// The GI cascade: a pyramid of probe grids, each half the resolution of the one
// below. SAMPLED WITH A SAMPLER rather than texelFetch, and that is the
// opposite decision from the shadow map one line up, on purpose.
//
// A shadow map is indexed by an ANGLE BUCKET, which is not a position: a
// filtered sample blends two directions and leaks on one side while darkening
// the other. The cascade is indexed by a POSITION, a grid at `base_scale`
// spacing, so it is exactly the case filtering is for — and a probe grid
// sampled with texelFetch looks like a grid of hard squares, which is the thing
// GI must never look like.
@group(0) @binding(2) var gi_tex: texture_2d<f32>;
@group(0) @binding(3) var gi_smp: sampler;

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
    @location(10) si_shadow_ratio: f32,
    @location(11) @interpolate(flat) si_flags: u32,
    @location(12) @interpolate(flat) si_filter: u32,
    @location(13) @interpolate(flat) si_color: vec4f,
};

@vertex
fn vs_main(@builtin(vertex_index) vi: u32, in: LightIn) -> VSOut {
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
    out.si_shadow_ratio = in.radius_extent.y;
    out.si_energy = in.cos_inner_energy.y;
    out.si_atten = in.atten_soft.x;
    out.si_softness = in.atten_soft.y;
    out.si_cos_outer = in.angle_cos.y;
    out.si_cos_inner = in.cos_inner_energy.x;
    out.si_angle = in.angle_cos.x;
    out.si_gi = in.gi_flags.x;
    out.si_flags = flags;
    out.si_filter = (flags >> 5) & 3u;
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
    if (kind == KIND_AMBIENT) {
        // Flat, then a soft edge over the last fifth of the reach. A scene-wide
        // ambient is sized by the CPU so that `rec01` never exceeds 0.8 on
        // screen, which lands entirely in the flat part.
        falloff = 1.0 - smoothstep(0.8, 1.0, rec01);
    } else if (kind == KIND_POINT) {
        falloff = 1.0 - min(rec01, 1.0);
    } else {
        // A spot or a directional light: how much the direction to the pixel
        // agrees with the light's own direction. ONE `dot` of two unit-ish
        // vectors, and it is the whole cone test. A directional light carries
        // both cosines as 1, so this costs a multiply and rejects nothing —
        // which is the right price for "has no cone".
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
    // The value is blocker PROXIMITY (`1 - distance/reach`), so the pixel is lit
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
        let n_angles = u32(textureDimensions(shadow_map).x);
        let turn = 6.283185307179586 / f32(n_angles);
        let idx = min(u32(theta / turn), n_angles - 1u);

        // Normalized by the SHADOW reach, not by the light's radius. The map
        // holds `1 - t/reach` because the sweep traced that far, and the
        // directional light's reach is its shadow length rather than its
        // falloff — so the two sides of the comparison have to be in the same
        // units or the shadow is silently the wrong length.
        let ratio = max(in.si_shadow_ratio, 1e-4);
        let here = 1.0 - min(rec01 / ratio, 1.0);
        let w = max(in.si_softness * rec01, 1e-4);

        let o0 = textureLoad(shadow_map, vec2u(idx, channel), 0).r;
        vis = smoothstep(o0 - w, o0, here);

        // The filter is an average of NEIGHBOURS, which is what makes a shadow
        // edge soft rather than blocky. Weights sum to 1 and the centre tap
        // always counts, so `off` and the highest filter cannot differ in
        // brightness — only in how hard the edge is.
        if (in.si_filter != 0u) {
            let om = smoothstep(o0 - w, o0, here);
            let op = textureLoad(shadow_map, vec2u((idx + n_angles - 1u) % n_angles, channel), 0).r;
            let on = textureLoad(shadow_map, vec2u((idx + 1u) % n_angles, channel), 0).r;
            let vp = smoothstep(op - w, op, here);
            let vn = smoothstep(on - w, on, here);
            if (in.si_filter == 1u) {
                vis = om;
            } else if (in.si_filter == 2u) {
                vis = 0.5 * vis + 0.5 * om;
            } else {
                vis = 0.25 * vis + 0.5 * om + 0.25 * vp * vn;
            }
        }
    }

    // GI. The cascade's alpha channel is the ENCLOSURE term — how much of the
    // hemisphere this point can see — and `si_gi` is how much of it this light
    // is allowed to apply.
    //
    // `si_gi` defaults to zero, and that default is the whole design: a scene
    // that never asked for bounce must not get it, even though the texture is
    // bound and the sampler is bound and the code is right here. A GI term that
    // arrives unasked for darkens every enclosed room in every project that
    // added the subsystem, and the report is always "my lights look wrong" with
    // no way to point at the cause.
    var gi: f32 = 1.0;
    if (in.si_gi > 0.0) {
        let size = vec2f(textureDimensions(gi_tex));
        let span = max(globals.mask_rect.zw - globals.mask_rect.xy, vec2f(1e-4));
        // Outside the cascade's rectangle there is no enclosure data, and the
        // honest answer for "how enclosed is somewhere we never measured" is
        // zero: unenclosed. Guessing anything else makes the border of a
        // measured region pop, which is worse than having no GI there.
        let uv = (in.world - globals.mask_rect.xy) / span;
        if (uv.x >= 0.0 && uv.x <= 1.0 && uv.y >= 0.0 && uv.y <= 1.0) {
            // `textureSampleLevel`, not `textureSample`: the branch is keyed on
            // a per-instance value, so it is not uniform control flow and the
            // implicit-derivative form is illegal here. Level 0 is not a
            // downgrade — the cascade is a probe grid with no mip chain, so
            // there is no other level to take and the derivative would only
            // have picked 0 anyway.
            gi = 1.0 - in.si_gi * (1.0 - textureSampleLevel(gi_tex, gi_smp, uv, 0.0).a);
        } else {
            gi = 1.0 - in.si_gi;
        }
    }

    // `energy` and the colour's alpha BOTH scale what arrives. Alpha is the
    // light's opacity, which is why fading a light needs no extra attribute and
    // no extra blend mode — and why `mix` can lerp by the amount that arrives
    // rather than by the colour.
    let a = falloff * vis * in.si_energy * color.a * gi;
    return vec4f(color.rgb * a, a);
}

/// A smoothstep, mirroring `light.zig`'s.
fn smoothstep(e0: f32, e1: f32, x: f32) -> f32 {
    let t = clamp((x - e0) / max(e1 - e0, 1e-9), 0.0, 1.0);
    return t * t * (3.0 - 2.0 * t);
}
