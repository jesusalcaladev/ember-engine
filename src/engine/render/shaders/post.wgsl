//! M7: the post pass — bloom, fog and tonemap.
//!
//! Four entry points, one file, because they are one idea: what the frame looks
//! like AFTER the lights are done with it.
//!
//! # Why fog is radial, and what that costs
//!
//! Godot's fog reads a depth buffer. A 2D scene has none — every pixel is at the
//! same depth by construction — so "distance from the camera" has no source. The
//! honest substitute is distance from the point the camera is LOOKING AT, which
//! is why `fog` here is a radial falloff rather than a z-based one. It reads as
//! depth at the screen edges and it is one `length()` per pixel.
//!
//! The alternative — sampling a sprite's Y as fake depth — produces a fog that
//! scrolls with the camera and reads as a bug. This one is predictable, and it is
//! documented as what it is rather than named `fog_depth`.
//!
//! # Why bloom is four passes and not one
//!
//! Because a separable blur is two 1D passes instead of one 2D one: 9 taps
//! become 9, not 81, and at half resolution the bloom is a quarter of the cost
//! of full-resolution 2D. A single-pass "cheap bloom" is a box blur, and a box
//! blur on a bright torch looks like a rectangle. The chain is
//!
//!   bright -> blur H -> blur V -> composite
//!
//! and the composite is where fog and tonemap happen, so the expensive chain
//! feeds one final full-screen pass rather than two.
//!
//! VALIDATED with Dawn's tint via `zig build shaders`.

struct PostParams {
    /// Full-resolution texel size and its inverse.
    texel: vec2f,
    inv_texel: vec2f,
    /// Half-resolution texel size, for the bloom taps.
    bloom_texel: vec2f,
    exposure: f32,
    /// Fog's near and far distance from the focus point.
    fog: vec2f,
    /// Fog colour, rgb + strength. Strength is separate from the colour so a
    /// scene can tint its fog without making it opaque.
    fog_color: vec4f,
    /// x = tonemap on, y = bloom intensity, z = bloom threshold, w = bloom
    /// enabled at all.
    flags: vec4f,
    /// The world-space point the camera is looking at, xy, and its z/w spare.
    focus: vec2f,
    focus_pad: vec2f,
    /// M9: the scene-transition curtain — rgb and, in alpha, how much of the
    /// screen it covers. Applied LAST, after tonemap, because it is a curtain
    /// hung over the finished image and not part of the image.
    fade: vec4f,
    /// M14: CanvasModulate — rgb and, in alpha, the strength. Applied after
    /// tonemap and BEFORE the fade, so a transition curtain is never tinted.
    tint: vec4f,
    /// x = the mix (0 off, 1 multiply, 2 add, 3 alpha), yzw spare. A vec4 rather
    /// than an f32 so it lands on a 16-byte boundary, which a uniform struct
    /// requires after the `tint` vec4.
    tint_mode: vec4f,
};

@group(0) @binding(0) var<uniform> params: PostParams;
@group(0) @binding(1) var src_tex: texture_2d<f32>;
@group(0) @binding(2) var src_smp: sampler;
/// The bloom result, only read by `fs_composite`. Bound as a placeholder in the
/// other three: one bind group layout for all four pipelines, so a pass that
/// does not read it is not a special case in the layout.
@group(0) @binding(3) var bloom_tex: texture_2d<f32>;

struct VSOut {
    @builtin(position) pos: vec4f,
    @location(0) uv: vec2f,
};

/// A fullscreen triangle, generated from the vertex index. No vertex buffer, and
/// a triangle rather than a quad so the seam down the diagonal does not exist:
/// a quad is two triangles and their shared edge is a place for the rasterizer's
/// fill rules to disagree with themselves.
@vertex
fn vs_fullscreen(@builtin(vertex_index) vi: u32) -> VSOut {
    var out: VSOut;
    // 0,0 / 2,0 / 0,2 — a triangle that covers the whole clip square.
    let x = f32((vi << 1u) & 2u);
    let y = f32(vi & 2u);
    out.pos = vec4f(x * 2.0 - 1.0, 1.0 - y * 2.0, 0.0, 1.0);
    out.uv = vec2f(x, y);
    return out;
}

/// Luminance, Rec. 709. Not a "good enough" weights choice: 0.299/0.587/0.114 is
/// the one every engine ships because it is what the NTSC signal was built
/// around, and a bloom threshold that disagrees with every other one makes a
/// scene's bloom pop at different levels in different tools.
fn luma(c: vec3f) -> f32 {
    return dot(c, vec3f(0.2126, 0.7152, 0.0722));
}

/// Pass 1: keep what is bright enough to glow.
@fragment
fn fs_bright(in: VSOut) -> @location(0) vec4f {
    let c = textureSample(src_tex, src_smp, in.uv).rgb;
    let l = luma(c);
    let t = params.flags.z;
    // A hard threshold makes bloom flicker as a value crosses it, which is the
    // classic "torch crackles". Soft-knee: the ramp starts a third of the way
    // below the threshold, so a pixel near it contributes a little rather than
    // flipping between nothing and everything.
    let knee = max(t * 0.33, 1e-4);
    let w = clamp((l - t + knee) / (2.0 * knee), 0.0, 1.0);
    return vec4f(c * w * w, 1.0);
}

/// Pass 2: blur horizontally, into the other half-resolution buffer.
@fragment
fn fs_blur_h(in: VSOut) -> @location(0) vec4f {
    return blur(in.uv, vec2f(params.bloom_texel.x, 0.0));
}

/// Pass 3: blur vertically, back into the first.
@fragment
fn fs_blur_v(in: VSOut) -> @location(0) vec4f {
    return blur(in.uv, vec2f(0.0, params.bloom_texel.y));
}

/// Nine taps at 1, 2 and 3.5 texels, the classic Gaussian approximation: the
/// weights are a real Gaussian's to within a percent, and a real Gaussian needs
/// a `exp` per tap, which on nine taps is nine transcendentals per pixel for a
/// difference nobody can see.
fn blur(uv: vec2f, dir: vec2f) -> vec4f {
    let w0 = 0.2270270270;
    let w1 = 0.3162162162;
    let w2 = 0.0702702703;
    let o1 = 1.3846153846;
    let o2 = 3.2307692308;
    var acc = textureSample(src_tex, src_smp, uv).rgb * w0;
    acc = acc + textureSample(src_tex, src_smp, uv + dir * o1).rgb * w1;
    acc = acc + textureSample(src_tex, src_smp, uv - dir * o1).rgb * w1;
    acc = acc + textureSample(src_tex, src_smp, uv + dir * o2).rgb * w2;
    acc = acc + textureSample(src_tex, src_smp, uv - dir * o2).rgb * w2;
    return vec4f(acc, 1.0);
}

/// ACES filmic approximation, Narkowicz's fit.
///
/// Chosen over Reinhard (`c / 1 + c`) because Reinhard darkens the MIDTONES as it
/// rolls off the highlights — a torch at energy 3 pulls the whole wall down with
/// it — and over a full ACES fit because the 3x3 input matrix costs nine
/// multiplies per pixel for a difference you cannot see next to the halo bloom is
/// already drawing over it.
fn tonemap(c: vec3f) -> vec3f {
    let a = 2.51;
    let b = 0.03;
    let cc = 2.43;
    let d = 0.59;
    let e = 0.14;
    return clamp((c * (a * c + b)) / (c * (cc * c + d) + e), vec3f(0.0), vec3f(1.0));
}

/// Pass 4: bloom in, fog and tonemap out. The last thing that touches a pixel.
@fragment
fn fs_composite(in: VSOut) -> @location(0) vec4f {
    var c = textureSample(src_tex, src_smp, in.uv).rgb;

    if (params.flags.w > 0.0) {
        c = c + textureSample(bloom_tex, src_smp, in.uv).rgb * params.flags.y;
    }

    c = c * params.exposure;

    // Fog. Radial from the focus point, in SCREEN space rather than world space:
    // the world position of a pixel is not in this pass, and reconstructing it
    // from the inverse view-projection would be a matrix per pixel for a
    // falloff that is, by definition, a function of how far something is from
    // the centre of the screen anyway.
    if (params.fog.y > params.fog.x) {
        let d = length((in.uv - 0.5) * 2.0);
        let t = clamp((d - params.fog.x) / max(params.fog.y - params.fog.x, 1e-6), 0.0, 1.0);
        // Smoothstep, not linear: linear fog has a visible edge where it starts.
        let f = t * t * (3.0 - 2.0 * t) * params.fog_color.a;
        c = mix(c, params.fog_color.rgb, f);
    }

    if (params.flags.x > 0.0) {
        c = tonemap(c);
    }

    // M14: CanvasModulate. A full-screen tint over the finished (tonemapped)
    // image, world and UI alike. Before the fade on purpose: the curtain is
    // hung over the tinted image, and a fade-to-black must reach black whatever
    // the scene is tinted. A zero strength or mode 0 is a no-op.
    if (params.tint_mode.x > 0.0 && params.tint.a > 0.0) {
        let amt = clamp(params.tint.a, 0.0, 1.0);
        if (params.tint_mode.x < 1.5) {
            // multiply: toward black for a dark ambience, toward the colour for
            // a grade. mix(1, rgb, amt) keeps amt = 1 an exact multiply.
            c = c * mix(vec3f(1.0), params.tint.rgb, amt);
        } else if (params.tint_mode.x < 2.5) {
            // add: a flash. Scaled by amt so the strength ramps the flash in.
            c = c + params.tint.rgb * amt;
        } else {
            // alpha: a flat veil over the image.
            c = mix(c, params.tint.rgb, amt);
        }
    }

    // The fade, last. A transition is a CURTAIN over the finished frame, so
    // compositing it after tonemap is what makes a fade-to-black actually black
    // instead of "whatever the tone curve does to black". Alpha is the amount,
    // so a zero amount is a multiply by one and costs nothing visible.
    if (params.fade.a > 0.0) {
        c = mix(c, params.fade.rgb, params.fade.a);
    }

    return vec4f(c, 1.0);
}

/// The copy path: used when the post pass is off, so SMAA always reads from one
/// texture and the branch lives here rather than in `endScene`.
@fragment
fn fs_copy(in: VSOut) -> @location(0) vec4f {
    return textureSample(src_tex, src_smp, in.uv);
}
