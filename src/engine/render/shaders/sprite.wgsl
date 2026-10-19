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
    @location(5) shape: u32,      // 0 = quad, 1 = circle
    /// Which light layer this sprite is on. Travels as its own attribute so the
    /// fragment stage can hand it to the LAYER TARGET without a varying — a
    /// per-pixel-varying integer would be flat, and flat on a sprite that spans
    /// the screen is fine, but it costs an interpolator for one byte.
    @location(6) layer: u32,
    /// The rotation about the sprite's centre, in radians.
    ///
    /// The corners are derived here, so this is where the rotation belongs: a
    /// quad's corners are a centre plus two half extents, and a turned quad
    /// needs a third number. It used to be missing, and the transform's
    /// rotation was carried by the ECS, read by the physics and written by the
    /// editor's gizmo — and thrown away on the way to the screen.
    @location(7) rot: f32,
};

struct VSOut {
    @builtin(position) pos: vec4f,
    @location(0) uv: vec2f,
    @location(1) color: vec4f,
    @location(2) local: vec2f,    // -1..1 across the quad, for the mask
    // `flat`, and not decoration: WGSL requires it on every integral output, and
    // tint rejects the file without it. It is also correct — the shape is a
    // property of the sprite, not of the pixel.
    @location(3) @interpolate(flat) shape: u32, // which mask to apply
    @location(4) @interpolate(flat) layer: u32, // which light layer this is
};

/// Triangle-strip corners from the vertex index: (0,0) (1,0) (0,1) (1,1).
/// No vertex buffer is bound at all.
@vertex
fn vs_main(@builtin(vertex_index) vi: u32, inst: Instance) -> VSOut {
    let cx = f32(vi & 1u);
    let cy = f32((vi >> 1u) & 1u);
    let corner = vec2f(cx, cy) * 2.0 - 1.0; // -1..1

    var out: VSOut;
    // The corner in the sprite's own frame, turned by the instance's rotation.
    // The local coordinate the fragment stage masks with is the UNROTATED
    // one: a circle is a circle whichever way it points.
    let local = corner * inst.half;
    let c = cos(inst.rot);
    let s = sin(inst.rot);
    let turned = vec2f(local.x * c - local.y * s, local.x * s + local.y * c);
    out.pos = globals.vp * vec4f(inst.pos + turned, 0.0, 1.0);
    out.uv = mix(inst.uv.xy, inst.uv.zw, vec2f(cx, cy));
    out.color = inst.color;
    // Carried so the fragment stage can mask the quad without recomputing where
    // it is. One vec2 per vertex, and it is what makes `sprite.circle` a real
    // circle rather than a square pretending to be one.
    out.local = corner;
    out.shape = inst.shape;
    out.layer = inst.layer;
    return out;
}

/// The sprite's colour, and its light layer.
///
/// ## Why the layer is an output and not a uniform
///
/// `LightBase.item_cull_mask` says "this light affects these sprite layers". The
/// light pass is a quad drawn over the whole scene, so it cannot know which
/// sprite is under each pixel — it only knows the pixel. Something has to record
/// "which layer is here", and recording it as the sprite pass writes is the
/// cheapest place there is: one extra byte per pixel, no extra pass, no readback.
///
/// ## Why the second target REPLACES rather than blends
///
/// The layer is not a colour to accumulate; it is which sprite is ON TOP. The
/// scene already resolved that with the painter's algorithm, so the last sprite
/// to write a pixel is the one a user sees, and that is the one whose layer the
/// light pass should consult. Blending two layers would produce a number that is
/// neither.
///
/// @location(1) has NO blend state in the pipeline, which is what makes it a
/// replace. The colour target keeps its alpha blend.
struct FragOut {
    @location(0) color: vec4f,
    @location(1) layer: f32,
};

@fragment
fn fs_main(in: VSOut) -> FragOut {
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

    // SHAPE MASK. A circle is the quad with the corners knocked off, tested on
    // the LOCAL coordinate rather than the sampled one -- sampling would make the
    // shape depend on which atlas region happened to be bound, so the same
    // sprite would be round or square depending on its texture.
    //
    // The radius is 1.0 in local space, so the test is a plain length. The
    // discard rather than an alpha ramp: a faded edge on a prototype circle
    // looks like a bug, and `discard` costs nothing here because the sprite is
    // already blended.
    if (in.shape == 1u) {
        if (dot(in.local, in.local) > 1.0) {
            discard;
        }
    }

    var out: FragOut;
    out.color = in.color * textureSample(atlas_tex, atlas_smp, uv);
    // The layer, normalized: the target is R8Unorm, so the light pass multiplies
    // by 255 to get the number back. Unorm rather than an integer format
    // because R8Unorm is renderable everywhere an R8Uint is, and one conversion
    // in one place is cheaper than a format that some drivers refuse.
    out.layer = f32(in.layer) / 255.0;
    return out;
}

/// Untextured variant (a material without atlas): solid tint per instance.
@fragment
/// The untextured variant, and it returns the SAME two outputs as `fs_main`.
///
/// It used to return a bare `@location(0) vec4f`, which is wrong in a way only a
/// real GPU notices: the sprite pass has TWO colour attachments, and a fragment
/// stage that writes only the first leaves the second untouched while its write
/// mask says otherwise. Dawn rejects that at pipeline creation, so every solid
/// sprite in every windowed run failed to build its pipeline.
///
/// And the layer genuinely has to be written here. A solid sprite still occupies
/// a light layer, and it still occludes the ones behind it -- leaving this
/// variant out of the layer target would make every untextured sprite invisible
/// to `item_cull_mask`, which reads as "lights do not reach solid geometry"
/// rather than as the bug it is.
fn fs_main_solid(in: VSOut) -> FragOut {
    return FragOut(in.color, f32(in.layer));
}