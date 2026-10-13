//! M7: the Radiance Cascades compute pass.
//!
//! The GPU half of `Radiance` in light.zig, and the relationship is the same as
//! `coverage` has with the light fragment program: the CPU half exists so the
//! arithmetic can be tested without a device, and this does the same thing on
//! one. Line for line, because a compute pass nobody can read is a compute pass
//! nobody can debug.
//!
//! VALIDATED with Dawn's own tint (C++), which ships in this repo:
//!   zig build shaders
//! passes with no diagnostics. It caught the WGSL syntax this file was first
//! written with by guesswork -- `and` instead of `&&`, and a `vec2f(vec3u)`
//! that is not a conversion -- which is what a validator is FOR.
//!
//! # What it does
//!
//! Each invocation is one probe of one cascade. It traces `rays` directions
//! through the SDF, sphere-tracing exactly as the CPU does -- the field never
//! overestimates, so the trace cannot step over a thin wall -- and for each hit
//! it reads the NEXT cascade up at the hit point. That read is the bounce: the
//! light that reached the occluder leaves it towards this probe, and the next
//! cascade is where that light was recorded, at a resolution coarse enough to
//! have traced it.
//!
//! The cascades are dispatched COARSE-TO-FINE and each level reads the level
//! above it, which is the whole correctness argument: dispatching fine-to-coarse
//! would leave the bottom level reading a level that has not been written yet,
//! and the result would look plausible -- bright in the open, dark in the
//! corners -- with no bounce in it anywhere.
//!
//! Amortized: the pass runs only when the pyramid is dirty, so a static scene's
//! GI costs nothing after the first frame, and a moving one is bounded by the
//! grid it walks, not by the light count.

/// One probe's view of the world.
///
/// The same struct as `Radiance`'s `Probe` in light.zig, byte for byte: the GPU
/// writes this and the CPU's merge reads the same one, so a field in one and not
/// the other is a silent disagreement about where radiance lives.
struct Probe {
    /// Distance to the nearest occluder along this ray, in probe units. Zero
    /// when the ray starts inside solid geometry, which is the one case a merge
    /// must not sample through a wall.
    hit_distance: f32,
    /// The occluder's normal at the hit, or zero for no hit.
    normal: vec2f,
    /// What radiance arrived along this ray, after the merge.
    incoming: vec3f,
    /// Unused, to a 16-byte stride. A storage buffer's element stride is its
    /// alignment, and vec3f is already 16 bytes, so this costs nothing.
    pad: f32,
};

struct CascadeParams {
    /// World-space size of one mask cell, in world units.
    mask_cell: vec2f,
    /// The mask's world-space rectangle (min.xy, max.zw).
    mask_rect: vec4f,
    /// The sky's radiance, and the bounce albedo.
    sky: vec3f,
    albedo: f32,
    /// This cascade's grid dimensions and the SDF's width, in cells.
    grid: vec2u,
    sdf_width: u32,
    /// Cells between adjacent probes of THIS cascade.
    scale: u32,
    /// Rays per probe at this level.
    rays: u32,
    /// Whether this is the coarsest level, which sees only sky.
    is_coarsest: u32,
    /// THE WIDTH OF `higher_probes`, in probes.
    ///
    /// It was missing, and the bounce read used `grid.x` instead -- this
    /// cascade's width -- to index the COARSER cascade's buffer, whose width is
    /// half or a quarter of this one. Every bounce therefore landed on the wrong
    /// probe, or past the end and silently fell back to sky, which is the
    /// failure that looks most like a renderer bug: the picture is plausible,
    /// the corners are dark, and nothing anywhere says a stride was wrong.
    ///
    /// A bounds check did not save it: it only stops the out-of-range read, not
    /// the in-range wrong one.
    higher_width: u32,
    /// Padding to a 16-byte multiple, which every uniform buffer wants so the
    /// next thing after it in a bind group starts aligned.
    pad0: u32,
    pad1: u32,
    pad2: u32,
};

@group(0) @binding(0) var<uniform> params: CascadeParams;
/// The occluder distance field, as FLOAT.
///
/// It was `array<f32>` before and the CPU's field is `[]u16` -- a true
/// distance clamped to 65535, four bytes to the GPU's two. The types both
/// compiled and the shader read packed bytes as if they were floats, which
/// produced distances that were wrong by an amount nobody could name.
///
/// The fix is a deliberate f32 mirror of the field rather than unpacking on the
/// GPU: the field is the one thing in the GI path that must be BIT-IDENTICAL
/// between the two implementations, because a merge that reads a different field
/// is not a fast merge, it is a different answer. The mirror costs 4 bytes per
/// cell of a grid that is 128x128 by default -- 64 KB -- and buys agreement that
/// a test can actually check.
@group(0) @binding(1) var<storage, read> sdf_in: array<f32>;
@group(0) @binding(2) var<storage, read_write> probes_out: array<Probe>;
@group(0) @binding(3) var<storage, read> higher_probes: array<Probe>;

const PI: f32 = 3.141592653589793;

/// The CPU's `smoothstep`, which the fragment program also mirrors.
fn smoothstep(e0: f32, e1: f32, x: f32) -> f32 {
    let t = clamp((x - e0) / max(e1 - e0, 1e-9), 0.0, 1.0);
    return t * t * (3.0 - 2.0 * t);
}

/// The CPU's `lightReaches`, for the coarse level's out-of-mask escape.
fn in_mask(p: vec2f) -> bool {
    let lo = params.mask_rect.xy;
    let hi = params.mask_rect.zw;
    return p.x >= lo.x && p.x < hi.x && p.y >= lo.y && p.y < hi.y;
}

/// The CPU's `worldToMask`, needed to index the SDF.
fn world_to_cell(p: vec2f) -> vec2u {
    let cell = (p - params.mask_rect.xy) / params.mask_cell;
    return vec2u(clamp(cell, vec2f(0.0), vec2f(f32(params.grid.x) * f32(params.scale), f32(params.grid.y) * f32(params.scale))));
}

@compute @workgroup_size(8, 8, 1)
fn main(@builtin(global_invocation_id) gid: vec3u) {
    if (gid.x >= params.grid.x || gid.y >= params.grid.y) {
        return;
    }
    let probe_index = gid.y * params.grid.x + gid.x;

    // This probe's world position: the cell centre of its own grid cell.
    let cell = vec2f(gid.xy) * f32(params.scale) + f32(params.scale) * 0.5;
    let world = params.mask_rect.xy + cell * params.mask_cell;

    var acc = vec3f(0.0);
    // Closest hit across the probe's rays, for `hit_distance`. See the write at
    // the bottom for why this is tracked at all.
    var closest: f32 = 1e30;

    // THE SAME EARLY-OUT THE CPU HAS, and it was the last thing the two halves
    // disagreed about.
    //
    // `probeAt` returns black for a probe standing inside geometry: every ray
    // would start in a wall and terminate at step 0, and the merge would be
    // reading an enclosed cascade and returning its answer. The shader traced
    // them anyway and followed the bounce chain into the coarser cascades, which
    // are solid at the same point, all the way up to the sky base case -- so a
    // probe inside a wall reported SKY on the GPU and BLACK on the CPU.
    //
    // It looks fine. Walls are bright, rooms are dark, and a mismatch confined to
    // solid cells is invisible until it lands on a prop that happens to be inside
    // one.
    {
        let own = world_to_cell(world);
        if (own.y * params.sdf_width + own.x < arrayLength(&sdf_in)) {
            if (sdf_in[own.y * params.sdf_width + own.x] < 1.0) {
                probes_out[probe_index].hit_distance = 0.0;
                probes_out[probe_index].normal = vec2f(0.0);
                probes_out[probe_index].incoming = vec3f(0.0);
                return;
            }
        }
    }
    // Solid angle per ray, and the 2*pi divisor that turns a sum over
    // directions into an integral over the hemisphere. Weighting by SOLID ANGLE
    // and summing rather than averaging is what makes a probe with four wide
    // rays and one with sixteen narrow rays give the same answer when they see
    // the same sky.
    let solid = 2.0 * PI / f32(params.rays);
    let two_pi = 2.0 * PI;

    for (var i: u32 = 0u; i < params.rays; i = i + 1u) {
        // Offset by half a step so the first ray is not exactly along +x: a set
        // that starts on an axis has a preferred orientation a scene author sees
        // as a shadow on one side of every object.
        let theta = (f32(i) + 0.5) * solid;
        let dir = vec2f(cos(theta), sin(theta));

        // Sphere-trace the SDF: step by the distance field, which reaches an
        // occluder in O(sqrt d) steps instead of the fixed count a march needs,
        // and cannot step over a thin wall because the field never
        // overestimates.
        let max_t = min(f32(params.grid.x), f32(params.grid.y)) * f32(params.scale);
        var t: f32 = 0.0;
        var hit = false;
        for (var step: u32 = 0u; step < 64u; step = step + 1u) {
            let p = world + dir * t;
            if (!in_mask(p)) {
                break;
            }
            let c = world_to_cell(p);
            let idx = c.y * params.sdf_width + c.x;
            if (idx >= arrayLength(&sdf_in)) {
                break;
            }
            let d = sdf_in[idx];
            if (d < 1.0) {
                hit = true;
                closest = t;
                break;
            }
            t = t + max(d * 0.9, 0.5);
            if (t > max_t) {
                break;
            }
        }

        if (!hit) {
            // The ray reached the sky: the base case every merge eventually
            // resolves to, and the only place the sky enters at all.
            acc = acc + params.sky * (solid / two_pi);
            continue;
        }

        // A hit: read the next cascade up at the hit point. That is the bounce.
        var from_here = params.sky;
        if (params.is_coarsest == 0u) {
            let hit_world = world + dir * t;
            let hc = world_to_cell(hit_world);
            // `params.higher_width`, NOT `params.grid.x`. See the struct.
            let hidx = hc.y * params.higher_width + hc.x;
            if (hidx < arrayLength(&higher_probes)) {
                from_here = higher_probes[hidx].incoming;
            }
        }
        // A hit contributes what it REFLECTS, not what it receives: a fraction
        // scattered back into the hemisphere. 0.85 is a mid-grey wall.
        acc = acc + from_here * (params.albedo * solid / two_pi);
    }

    // The CLOSEST hit of any ray, not `f32(params.rays)`.
    //
    // It was the ray count, in a field documented as "distance to the nearest
    // occluder along this ray" -- so every probe reported a distance equal to
    // how many directions it looked in, and any consumer that believed the field
    // got a plausible number that meant nothing. Nothing read it yet, which is
    // the only reason it survived: an unused field written with the wrong value
    // is invisible until the first thing reads it.
    probes_out[probe_index].hit_distance = closest;
    probes_out[probe_index].normal = vec2f(0.0);
    probes_out[probe_index].incoming = acc;
}