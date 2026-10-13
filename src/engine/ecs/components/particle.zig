//! `ParticleEmitter2D` — the particle emitter component (ROADMAP M9).
//!
//! ## Why this component holds CONFIGURATION and not particles
//!
//! A registry rule forbids it: a component is plain data with no pointers or
//! slices, and one emitter's particles are hundreds of floats that would blow
//! `max_stride` (the `.zson` decode buffer, 128 bytes) sixty times over. So the
//! emitter carries the recipe and a handle (`slab`) into the particle system's
//! pool — the same shape as `SoundEmitter2D.bank_slot` into the PCM bank and
//! `Sprite.coverage_index` into the coverage store. The pool is a CACHE the
//! system owns; the recipe is STATE that serializes.
//!
//! ## What serializes and what does not
//!
//! Everything except `slab` is authored state: it round-trips through `.zson`,
//! and a Play/Stop snapshot restores an emitter EXACTLY as it was configured.
//! The particles themselves are not state — they are the visible consequence of
//! the configuration integrated over a fixed number of ticks, and the honest way
//! to say that is the way it is written here: `slab` is the one field the system
//! owns, and it is not part of a scene.
//!
//! ## Two backends, one component
//!
//! `backend` selects the simulator: `cpu` integrates the pool on the main thread
//! and emits through the ordinary sprite batcher (one draw call per atlas run,
//! perfectly batched with the rest of the scene), `gpu` integrates it in a
//! compute pass and draws it from a storage buffer. The recipe is identical, so
//! switching is a field change — the GPU path exists for a hundred thousand
//! particles, the CPU path for a few hundred where a compute dispatch would cost
//! more than the simulation.

const core_math = @import("core").math;
const sprite_mod = @import("sprite.zig");

pub const Vec2 = core_math.Vec2;
pub const Blend = sprite_mod.Blend;

/// Where a particle is born, inside the emitter's shape.
///
/// `point` is the default because it is what a muzzle flash or a spark is, and
/// because an emitter with no extent anywhere else would otherwise default to a
/// 1x1 box — a square nobody asked for that only shows up when someone sets a
/// rate and wonders why the particles arrive in a lattice.
pub const EmitShape = enum(u8) {
    /// A single point (the emitter's transform).
    point = 0,
    /// A rectangle: `extent` is the half-width and half-height.
    box = 1,
    /// A disc: `extent.x` is the radius, uniformly sampled by area.
    disc = 2,
};

/// Which simulator integrates this emitter's particles.
pub const Backend = enum(u8) {
    /// Main-thread simulation, submitted through the sprite batcher.
    cpu = 0,
    /// Compute-shader simulation, drawn from a storage buffer.
    gpu = 1,
};

/// Whether particles live in world space or follow the emitter.
///
/// `local` costs one O(live) offset per moving emitter — the slab carries the
/// emitter's last position and the delta is applied to every live particle — and
/// it is what makes a jetpack flame or an engine trail stay attached to a moving
/// actor. `world` leaves them where they were born, which is what smoke does.
pub const Space = enum(u8) {
    world = 0,
    local = 1,
};

/// Packed colour, RGBA in one u32, 8 bits per channel.
///
/// Packed rather than two `[4]f32` pairs because the GPU instance's tint is
/// unorm8 END TO END: the round trip is lossless against what the sprite
/// pipeline actually samples, and four floats per endpoint would push this
/// component over `max_stride`. Gradients are interpolated per channel in
/// `render/particles.zig`, so the quantisation is the same one the output has.
pub fn packColor(c: [4]f32) u32 {
    const r: u32 = @intFromFloat(@min(255.0, @max(0.0, c[0] * 255.0 + 0.5)));
    const g: u32 = @intFromFloat(@min(255.0, @max(0.0, c[1] * 255.0 + 0.5)));
    const b: u32 = @intFromFloat(@min(255.0, @max(0.0, c[2] * 255.0 + 0.5)));
    const a: u32 = @intFromFloat(@min(255.0, @max(0.0, c[3] * 255.0 + 0.5)));
    return (r << 24) | (g << 16) | (b << 8) | a;
}

/// The colour a packed u32 stands for, 0..1 per channel.
pub fn unpackColor(raw: u32) [4]f32 {
    const s = 1.0 / 255.0;
    return .{
        @as(f32, @floatFromInt(raw >> 24)) * s,
        @as(f32, @floatFromInt((raw >> 16) & 0xFF)) * s,
        @as(f32, @floatFromInt((raw >> 8) & 0xFF)) * s,
        @as(f32, @floatFromInt(raw & 0xFF)) * s,
    };
}

/// `slab` value that means "no pool claimed yet". 0xFFFF and not 0: slab 0 is a
/// real slab, and a component whose default pointed at it would make an emitter
/// that never spawned anything share the first emitter's pool.
pub const no_slab: u16 = 0xFFFF;

pub const ParticleEmitter2D = struct {
    // ── emission ────────────────────────────────────────────────────────────
    /// Particles per second while `playing`. Fractional: the accumulator keeps
    /// the remainder, so a rate of 2.5 emits one every other frame at 60 Hz
    /// instead of two and then none.
    rate: f32 = 20.0,
    /// Hard cap on live particles for THIS emitter. The system's slab is sized
    /// from it at claim time, and exceeding it drops spawns (counted, reported).
    capacity: u16 = 128,
    /// Emit `capacity` particles once and then stop (`playing` goes false), the
    /// `particles.burst` path: one explosion, not a fountain.
    one_shot: bool = false,
    /// System-owned: the one-shot has already fired. A script that clears the
    /// particles and sets `playing` again therefore gets a CONTINUING emitter
    /// rather than a second detonation, which is the difference between "reset
    /// the explosion" and "explode twice".
    started_once: bool = false,
    /// Per-emitter playing flag. The scene-file default is `true` so an emitter
    /// declared in `.zson` runs without a script telling it to.
    playing: bool = true,

    // ── placement, placement, placement: the small integers ─────────────────
    /// Where inside the shape a particle is born.
    shape: EmitShape = .point,
    /// Which simulator owns this emitter's particles.
    backend: Backend = .cpu,
    /// World space or follow-the-emitter.
    space: Space = .world,
    /// Which atlas page the particles sample. Drives draw batching on both
    /// backends: same page, same draw call as the sprites (CPU) or a
    /// per-page draw (GPU).
    atlas: u8 = 0,
    /// How a particle composites over the scene. Same set as a sprite.
    blend: Blend = .alpha,

    // ── state the system writes, the recipe does not ────────────────────────
    /// Live particle count, mirrored from the slab so a scene file and the
    /// inspector can read it without reaching into the system.
    live: u16 = 0,
    /// Index into the system's slab table, or `no_slab`. Owned by the system.
    slab: u16 = no_slab,
    /// Fractional particle carried across ticks (a rate of 7 at 60 Hz is one
    /// particle per 8.57 ticks; dropping the fraction drifts the rate low).
    accumulator: f32 = 0,
    /// Per-emitter PRNG state. Lives in the component so a Play/Stop snapshot
    /// restores the SEQUENCE, not just the parameters: two runs from the same
    /// scene must spawn the same particles (spec §6).
    seed: u32 = 0x9e3779b9,

    // ── spawn geometry ──────────────────────────────────────────────────────
    /// Box half extents, or the disc radius in `.x`.
    extent: Vec2 = .{ .x = 0, .y = 0 },
    /// Emission direction range, radians. Full circle is the default; a cone is
    /// `{-spread, spread}`.
    angle: Vec2 = .{ .x = 0, .y = std.math.pi * 2 },

    // ── initial velocity ────────────────────────────────────────────────────
    /// Min and max speed at spawn, uniform in between.
    speed: Vec2 = .{ .x = 40, .y = 40 },

    // ── integration ─────────────────────────────────────────────────────────
    /// Constant acceleration, world units/s². `{0, -400}` is earth gravity.
    gravity: Vec2 = .{ .x = 0, .y = 0 },
    /// Velocity damping per second, 0 = none. Applied as `v *= exp(-drag*dt)`
    /// so it is frame-rate independent rather than `v *= (1 - drag)`.
    drag: f32 = 0,

    // ── lifetime ────────────────────────────────────────────────────────────
    /// Min and max seconds a particle lives, uniform in between.
    life: Vec2 = .{ .x = 0.5, .y = 1.0 },

    // ── appearance over life ─────────────────────────────────────────────────
    /// Size at birth and at death, interpolated by age. Equal values are a
    /// constant-sized particle; a falling pair is a spark shrinking to nothing.
    size: Vec2 = .{ .x = 8, .y = 8 },
    /// Rotation velocity at spawn, rad/s.
    spin: f32 = 0,
    /// Colour at birth (the flame's white-hot core).
    color_start: u32 = packColor(.{ 1, 1, 1, 1 }),
    /// Colour at death. The default fades alpha out at constant colour, which is
    /// what most effects want and what leaves no visible colour pop.
    color_end: u32 = packColor(.{ 1, 1, 1, 0 }),

    // ── look ────────────────────────────────────────────────────────────────
    /// Render layer. Particles default to 10, ABOVE the default sprite layer 0:
    /// a particle that renders behind the thing that emitted it reads as a bug
    /// rather than as a design choice, and there is no reason a default should
    /// need a script to look right.
    layer: u16 = 10,

    /// Atlas rect of the particle's image, normalized `(u0, v0, u1, v1)`.
    uv: [4]f32 = .{ 0, 0, 1, 1 },
};

// ── Tests ────────────────────────────────────────────────────────────────────

const std = @import("std");
const testing = std.testing;

test "ParticleEmitter2D is plain data with sane defaults" {
    const e = ParticleEmitter2D{};
    try testing.expectEqual(@as(f32, 20), e.rate);
    try testing.expectEqual(@as(u16, 128), e.capacity);
    try testing.expect(e.playing);
    try testing.expect(!e.one_shot);
    try testing.expectEqual(EmitShape.point, e.shape);
    try testing.expectEqual(no_slab, e.slab);
    try testing.expectEqual(@as(u16, 10), e.layer);
    // A full circle is the default direction, not a cone nobody set.
    try testing.expect(e.angle.y >= std.math.pi * 2 - 0.001);
}

test "the component fits the .zson decode stride" {
    // `max_stride` is the registry's decode buffer; the bound is enforced there
    // at comptime and pinned here next to the type it protects. 108 and not the
    // 112 the field list suggests: the four bools and the three small enums
    // pack into padding the u32 fields already force, so the component is
    // exactly the size of its real data. The pin exists so a field that DOES
    // push it over 128 fails HERE, named, instead of failing in the registry
    // with a message about a file.
    try testing.expect(@sizeOf(ParticleEmitter2D) <= 128);
    try testing.expectEqual(@as(usize, 108), @sizeOf(ParticleEmitter2D));
}

test "packed colours round-trip within the resolution the GPU reads" {
    const cases = [_][4]f32{
        .{ 0, 0, 0, 0 },
        .{ 1, 1, 1, 1 },
        .{ 0.5, 0.25, 0.75, 1.0 },
    };
    for (cases) |c| {
        const back = unpackColor(packColor(c));
        for (c, back) |want, got| try testing.expectApproxEqAbs(want, got, 1.0 / 255.0);
    }
    // The two defaults the component ships: white at full alpha fading to
    // white at zero. A colour FADE, not a colour change.
    try testing.expectEqual([4]f32{ 1, 1, 1, 1 }, unpackColor((ParticleEmitter2D{}).color_start));
    try testing.expectEqual([4]f32{ 1, 1, 1, 0 }, unpackColor((ParticleEmitter2D{}) .color_end));
}
