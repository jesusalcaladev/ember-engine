//! The GPU particle DRAW pass: one instanced quad per particle, straight out
//! of the storage buffer the simulation wrote.
//!
//! ## Why the vertex shader reads the buffer
//!
//! The CPU particle system pushes its particles into the sprite batcher, so
//! the CPU touches every particle every frame. That is the whole cost the GPU
//! backend exists to avoid: with 65k particles the CPU would stream 2 MB of
//! particle state per frame, build 65k sprite instances, and upload them.
//!
//! Here the particle IS the instance. The vertex shader reads it by its
//! index, and a dead particle produces a degenerate quad — four vertices in
//! the same place — which the rasteriser throws away for free.
//!
//! ## The rules are the CPU's
//!
//! The size interpolates from birth to death over the life, and the colour
//! from `color_start` to `color_end`, exactly as the CPU system's `collect`
//! does it. A particle that moves from one backend to the other has to look
//! the same.

struct Globals {
    vp: mat4x4<f32>,
    texel: vec2f,
    inverse: vec2f,
    _pad: vec2f,
};

struct Particle {
    pos: vec2f,
    vel: vec2f,
    age: f32,
    life: f32,
    size0: f32,
    size1: f32,
    rot: f32,
    rot_v: f32,
    color0: u32,
    color1: u32,
    alive: u32,
    next: u32,
    atlas: u32,
    _pad: u32,
};

@group(0) @binding(0) var<uniform> globals: Globals;
@group(0) @binding(1) var<storage, read> particles: array<Particle>;

struct VSOut {
    @builtin(position) pos: vec4f,
    @location(0) color: vec4f,
};

/// The colour packed as RGBA in a u32, unpacked to 0..1.
fn unpackColor(c: u32) -> vec4f {
    return vec4f(
        f32((c >> 24u) & 0xffu) / 255.0,
        f32((c >> 16u) & 0xffu) / 255.0,
        f32((c >> 8u) & 0xffu) / 255.0,
        f32(c & 0xffu) / 255.0,
    );
}

@vertex
fn vs_main(@builtin(vertex_index) vi: u32, @builtin(instance_index) ii: u32) -> VSOut {
    var out: VSOut;
    let p = particles[ii];
    if (p.alive == 0u) {
        // A DEAD PARTICLE: the quad collapses to a point, and the rasteriser
        // drops it. That is cheaper than a compaction pass on the GPU, and
        // it costs nothing but a few dead pixels of vertex work.
        out.pos = vec4f(0.0, 0.0, 0.0, 1.0);
        out.color = vec4f(0.0);
        return out;
    }

    // The progress through the life, 0 at birth and 1 at death.
    let t = clamp(p.age / max(p.life, 0.0001), 0.0, 1.0);
    let size = mix(p.size0, p.size1, t);
    let half = vec2f(size, size) * 0.5;

    // The corner, in the particle's own frame.
    let cx = f32(vi & 1u);
    let cy = f32((vi >> 1u) & 1u);
    let corner = vec2f(cx, cy) * 2.0 - 1.0;
    let local = corner * half;
    let c = cos(p.rot);
    let s = sin(p.rot);
    let turned = vec2f(local.x * c - local.y * s, local.x * s + local.y * c);

    out.pos = globals.vp * vec4f(p.pos + turned, 0.0, 1.0);
    // The colour, from birth to death.
    let a = unpackColor(p.color0);
    let b = unpackColor(p.color1);
    out.color = mix(a, b, t);
    return out;
}

@fragment
fn fs_main(in: VSOut) -> @location(0) vec4f {
    return in.color;
}
