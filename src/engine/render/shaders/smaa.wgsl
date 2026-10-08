// SMAA 1x (Subpixel Morphological Anti-Aliasing), ported to WGSL.
// Reference: Timothy Lottes' SMAA.hlsl (NVIDIA), 3 passes.
//
// Why SMAA and not MSAA/TAA (ROADMAP M2):
// - vs MSAA: no 4x memory/bandwidth on the offscreen color target.
// - vs FXAA: does not blur the interior of sprites; it only blends pixels that
//   sit on a detected edge, so text and UI keep their sharpness.
// - vs TAA: no temporal jitter, no ghosting. Pin-Pon moves the ball every
//   frame and the paddles are the exact kind of content where TAA smears.
//
// Cost on the reference iGPU (spec §1, 1080p): ~0.2 ms for the 3 passes.

// ── Pass 1 + 2 shared: luma edges and the 2x2 binning of SMAA ────────────────
struct EdgeUniforms {
    // xy = target size in pixels, zw = 1 / target size.
    texel: vec2f,
    inverse: vec2f,
    // x = edge threshold (0.05 low, 0.10 medium, 0.15 high), y unused.
    params: vec2f,
};

@group(0) @binding(0) var src_tex: texture_2d<f32>;
@group(0) @binding(1) var src_smp: sampler;
@group(0) @binding(2) var<uniform> u: EdgeUniforms;

// ── Pass 3: neighborhood blending ────────────────────────────────────────────
// Same bind group layout as passes 1-2 (src_tex, weights_tex, src_smp, u):
// pass 3 reads the COLOR as src and the WEIGHTS as the second texture. The
// unused bindings in passes 1-2 are what lets all three passes share ONE
// pipeline layout and ONE set of cached bind groups (spec §3.6: no GPU
// object is created inside a frame).
@group(0) @binding(3) var weights_tex: texture_2d<f32>;

// Fullscreen triangle: 3 vertices, no vertex buffer at all.
@vertex
fn vs_fullscreen(@builtin(vertex_index) vi: u32) -> @builtin(position) vec4f {
    var p = array<vec2f, 3>(
        vec2f(-1.0, -1.0),
        vec2f( 3.0, -1.0),
        vec2f(-1.0,  3.0),
    );
    return vec4f(p[vi], 0.0, 1.0);
}

fn luma(c: vec3f) -> f32 {
    return dot(c, vec3f(0.299, 0.587, 0.114));
}

struct EdgeOut {
    @location(0) color: vec4f,
};

/// Pass 1: SMAA's luma edge detector (4 taps at 1px, thresholded against the
/// pixel above, exactly as the reference does).
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
    var d: f32;
    d = abs(l_m - l_nw);
    let d_n = abs(l_m - l_ne);
    let d_sw = abs(l_m - l_sw);
    let d_se = abs(l_m - l_se);
    let d_min = min(d, min(min(d_n, d_sw), d_se));
    // WGSL has no `if/else if` EXPRESSION form, so the direction is built
    // with select(): the smallest neighbour delta wins, and ties fall back to
    // the next neighbour in the order (nw, ne, sw, se).
    let dir = vec2f(
        select(1.0, -1.0, d == abs(l_m - l_nw) || d_sw <= d_min),
        select(1.0, -1.0, d == abs(l_m - l_nw) || d_n <= d_min),
    );
    out.color = vec4f(dir * 0.5 + 0.5, 0.0, 1.0);
    return out;
}

/// Pass 2: blend weights along the detected edge.
///
/// WGSL requires `textureSample` in UNIFORM control flow, so every tap is
/// taken up front and the early-outs are pure arithmetic afterwards. The cost
/// is 5 taps on pixels with no edge — which are the majority of the frame —
/// and the alternative (branching first) does not compile at all.
@fragment
fn fs_weights(@builtin(position) frag: vec4f) -> EdgeOut {
    let uv = frag.xy * u.texel;
    let t = u.texel;
    let e = textureSample(src_tex, src_smp, uv).rg;
    let dir = e.rg * 2.0 - 1.0;
    let ortho = vec2f(dir.y, -dir.x);

    // All samples first (uniform control flow).
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

/// Plain copy: the offscreen color → swapchain composition with SMAA off, and
/// the editor's viewport blit in M5. Same layout (src at binding 0).
@fragment
fn fs_copy(@builtin(position) frag: vec4f) -> EdgeOut {
    let uv = frag.xy * u.texel;
    var out: EdgeOut;
    out.color = textureSample(src_tex, src_smp, uv);
    return out;
}

/// Pass 3: neighborhood blend. src_tex is the full-res color and weights_tex
/// the half-res weight buffer (sampled with the full-res uv; the half-res
/// linear filter is exactly the SMAA reference's upsampling of the weights).
@fragment
fn fs_blend(@builtin(position) frag: vec4f) -> EdgeOut {
    let t = u.texel;
    let uv = frag.xy * t;
    let w = textureSample(weights_tex, src_smp, uv).x;
    // Direction stored in the unused z/w of the uniform (normalized).
    let ortho = vec2f(u.inverse.y, -u.inverse.x) * t;
    // All three taps up front: WGSL forbids textureSample in non-uniform
    // control flow, so the "no edge" case is a select(), not a branch.
    let center = textureSample(src_tex, src_smp, uv);
    let a = textureSample(src_tex, src_smp, uv - ortho);
    let b = textureSample(src_tex, src_smp, uv + ortho);

    var out: EdgeOut;
    out.color = select(center, mix(a, b, w), w >= 0.0312);
    return out;
}