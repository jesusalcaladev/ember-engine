//! Mixer maths: attenuation and panning, pure and testable (M8).
//!
//! Both functions here are pure — no device, no allocation, no state — which is
//! the whole reason they live in their own file. A panning law that is only
//! exercised on a machine with speakers is a panning law nobody checks.
//!
//! ## Why panning is constant-power and not linear
//!
//! Linear pan sends `left = 1-p`, `right = p`. At the centre that is 0.5/0.5,
//! and two channels at half amplitude sum to 0.707 of the original power — a
//! sound crossing the listener gets measurably quieter in the middle. That dip
//! is audible, and it is the most common defect in a 2D audio mixer.
//!
//! Constant-power sends `left = cos(θ)`, `right = sin(θ)` with `θ = (p+1)·π/4`,
//! so `left² + right² = 1` at every position. At the centre both are 0.707: each
//! ear gets a quieter channel but the TOTAL is unchanged, which is what "moving
//! across the listener" is supposed to sound like.
//!
//! It costs one sin and one cos per voice per buffer — at 64 voices and 480
//! frames that is not measurable. Getting it right is free.
//!
//! ## Why attenuation is squared-linear and not inverse-square
//!
//! Inverse-square is more physical and reaches zero only at infinity, so it
//! needs a cut-off anyway — and a cut-off on an inverse-square curve is a
//! DISCONTINUITY: a sound at 99% of the range is loud and at 101% it is gone.
//! That pop is the same "visible edge" problem the light component's falloff
//! solves, and it is solved the same way: a curve that reaches exactly zero at
//! `max_distance` by construction.
//!
//! Squared rather than linear because it holds its level near the listener and
//! only then falls away, which is what a 2D scene wants — a sound 10% away is
//! still essentially full volume, not 10% quieter.

const std = @import("std");

/// A quarter turn, in radians. A pan position of 0 maps to a quarter turn.
const quarter_turn: f32 = std.math.pi * 0.5;

/// Left/right gains for a pan position in [-1, 1]: -1 is fully left, 0 is
/// centred, +1 is fully right. Out-of-range input is clamped rather than
/// wrapped, because a clamped extreme is silence in one ear while a wrapped one
/// is a sound jumping to the opposite side.
pub fn panGains(pan: f32) struct { left: f32, right: f32 } {
    const p = std.math.clamp(pan, -1.0, 1.0);
    // Map [-1, 1] onto [0, π/2] so the two gains sweep cos/sin over the quarter
    // turn where both are non-negative.
    const theta = (p + 1.0) * quarter_turn * 0.5;
    // Clamped to zero from below because `cos(π/2)` is not exactly 0 in binary
    // floating point: at the hard-right extreme it evaluates to about -4e-8. A
    // gain that small is inaudible, but a NEGATIVE gain is a phase flip, and an
    // invariant that holds "except at the endpoints by 1e-8" is an invariant
    // the next person cannot rely on. Clamping costs one comparison.
    return .{
        .left = @max(0, @cos(theta)),
        .right = @max(0, @sin(theta)),
    };
}

/// The pan position for a world offset from the listener.
///
/// `spread` is how far a sound can be from the listener and still be fully to
/// one side: at `dx = ±spread` the pan is ±1, and beyond that it is clamped. A
/// spread of 0 would divide by zero, so it means "no panning at all" — the
/// honest reading of "the scene has not said how wide a head is".
pub fn panForOffset(dx: f32, spread: f32) f32 {
    if (spread <= 0) return 0;
    return std.math.clamp(dx / spread, -1.0, 1.0);
}

/// Distance attenuation in [0, 1].
///
/// `max_distance == 0` means global: full volume everywhere, never attenuated
/// and never panned. That is what music and UI sounds want, which is why the
/// zero case is a documented value rather than a degenerate input.
pub fn attenuation(dx: f32, dy: f32, max_distance: f32) f32 {
    if (max_distance <= 0) return 1.0;
    const dist = @sqrt(dx * dx + dy * dy);
    if (dist >= max_distance) return 0; // exactly zero at the edge: no pop
    const t = dist / max_distance;
    // 1 - t²: holds its level near the listener, reaches exactly 0 at the edge.
    return 1.0 - t * t;
}

/// One voice's contribution for one output frame: the level and the two pan
/// gains, already multiplied together. The mixer's inner loop reads these
/// instead of recomputing per sample, because a voice's position does not
/// change inside a buffer.
pub const VoiceGains = struct {
    level: f32 = 0,
    left: f32 = 0,
    right: f32 = 0,

    pub fn isSilent(self: VoiceGains) bool {
        return self.level <= 0;
    }
};

/// Everything the mixer needs to place one voice, gathered so the per-sample
/// loop never reaches back into the world.
pub const Placement = struct {
    /// World position of the sound.
    x: f32 = 0,
    y: f32 = 0,
    /// Listener position, usually the camera.
    listener_x: f32 = 0,
    listener_y: f32 = 0,
    /// How far an offset reaches full hard-pan. 0 disables panning.
    spread: f32 = 400,
    /// 0 = global (no attenuation, no panning).
    max_distance: f32 = 0,
    /// Which way the listener faces, in radians. The pan axis is the listener's
    /// RIGHT vector, so turning the listener turns the stereo field with it: a
    /// sound to the world-east pans hard right when the ears face +x (rot 0) and
    /// arrives centred once the ears face +y. Rotation 0 keeps the pre-rotation
    /// behaviour exactly (right = +x), so an existing scene pans as it always did.
    listener_rot: f32 = 0,

    pub fn gains(self: Placement, volume: f32, bus_gain: f32) VoiceGains {
        const dx = self.x - self.listener_x;
        const dy = self.y - self.listener_y;
        const att = attenuation(dx, dy, self.max_distance);
        const level = volume * att * bus_gain;
        if (level <= 0) return .{};

        // The pan is the offset projected onto the listener's right vector
        // `(cos rot, sin rot)`. At rot 0 that is just `dx`, which is what every
        // existing scene assumes.
        const local_x = dx * @cos(self.listener_rot) + dy * @sin(self.listener_rot);
        const g = panGains(panForOffset(local_x, self.spread));
        return .{ .level = level, .left = g.left, .right = g.right };
    }
};

/// How many SOURCE frames one OUTPUT frame advances.
///
/// A sound decoded at 44.1 kHz played on a 48 kHz device must be resampled or
/// it comes out at the wrong pitch — high by 48/44.1, which is a semitone and a
/// half and is immediately obvious. Linear interpolation is not a perfect
/// resampler (it softens the very top a little) but it adds no aliasing and no
/// latency, and at these rates nobody hears the difference.
pub fn resampleStep(source_rate: u32, output_rate: u32, pitch: f32) f32 {
    if (output_rate == 0) return 0;
    if (pitch <= 0) return 0; // a zero or negative pitch is a degenerate request
    const src = @as(f32, @floatFromInt(source_rate));
    const out = @as(f32, @floatFromInt(output_rate));
    return (src / out) * pitch;
}

/// Reads one source frame at a fractional position, interpolating.
///
/// `cursor` is in source frames. Past the end it HOLDS the final frame rather
/// than wrapping, because a voice that has run out is stopped by the caller and
/// wrapping would restart the sound as a click.
pub fn sampleAt(pcm: anytype, cursor: f32, channel: u16) f32 {
    if (pcm.frames == 0) return 0;
    // A stream Pcm carries only a WINDOW of a longer sound, addressed by an
    // absolute `base_frame`; a resident Pcm is the whole sound at frame 0. The
    // two paths are kept apart so the resident one is byte-for-byte what it
    // always was — including holding the last frame past the end.
    if (pcm.streaming) return sampleStream(pcm, cursor, channel);

    const channels = pcm.channels;
    const frame: usize = @intFromFloat(@max(0, cursor));
    if (frame >= pcm.frames) {
        const last = (pcm.frames - 1) * channels + channel;
        return if (last < pcm.samples.len) pcm.samples[last] else 0;
    }
    const frac = cursor - @as(f32, @floatFromInt(frame));
    const base = frame * channels + channel;
    const cur = if (base < pcm.samples.len) pcm.samples[base] else 0;
    if (frac <= 0 or frame + 1 >= pcm.frames) return cur;
    const next = if (base + channels < pcm.samples.len) pcm.samples[base + channels] else 0;
    return cur + (next - cur) * frac;
}

/// One sample from a stream window, in absolute cursor space.
///
/// A cursor outside the prefetched window means the main thread has not fed the
/// ring far enough yet (or has not been called at all, in a test): the honest
/// answer is silence, not the last frame and not a wrap. The `full decode` the
/// bank does for short sounds is unaffected — this is only the streaming path.
fn sampleStream(pcm: anytype, cursor: f32, channel: u16) f32 {
    const channels = pcm.channels;
    const window: u32 = pcm.windowFrames();
    if (window == 0) return 0;
    const rel = cursor - @as(f32, @floatFromInt(pcm.base_frame));
    if (rel < 0) return 0; // before the window: not prefetched yet
    if (rel >= @as(f32, @floatFromInt(window))) return 0; // past the window: underrun

    const frame: usize = @intFromFloat(rel);
    const frac = rel - @as(f32, @floatFromInt(frame));
    const base = frame * channels + channel;
    const cur = if (base < pcm.samples.len) pcm.samples[base] else 0;
    if (frac <= 0 or frame + 1 >= window) return cur;
    const next = if (base + channels < pcm.samples.len) pcm.samples[base + channels] else 0;
    return cur + (next - cur) * frac;
}

// ── Tests ────────────────────────────────────────────────────────────────────

const testing = std.testing;
const Pcm = @import("audio.zig").Pcm;

test "panning is constant power: left^2 + right^2 is 1 at every position" {
    // The whole reason this is not linear. A linear law reads 0.5/0.5 in the
    // middle, which is 0.707 of the power — an audible dip as a sound crosses
    // the listener.
    var p: f32 = -1;
    while (p <= 1.0001) : (p += 0.1) {
        const g = panGains(p);
        const power = g.left * g.left + g.right * g.right;
        try testing.expectApproxEqAbs(@as(f32, 1), power, 0.001);
        // Both gains non-negative across the sweep: a negative gain would be a
        // phase-flipped channel.
        try testing.expect(g.left >= 0 and g.right >= 0);
    }
}

test "hard left and hard right are silent in the opposite ear" {
    const l = panGains(-1);
    try testing.expectApproxEqAbs(@as(f32, 1), l.left, 0.001);
    try testing.expectApproxEqAbs(@as(f32, 0), l.right, 0.001);

    const r = panGains(1);
    try testing.expectApproxEqAbs(@as(f32, 0), r.left, 0.001);
    try testing.expectApproxEqAbs(@as(f32, 1), r.right, 0.001);
}

test "out-of-range pan clamps instead of wrapping" {
    // Clamping is silence in one ear; wrapping would put a far-left sound in
    // the right ear — a sound jumping across the head.
    const far_left = panGains(-50);
    try testing.expectApproxEqAbs(@as(f32, 1), far_left.left, 0.001);
    const far_right = panGains(50);
    try testing.expectApproxEqAbs(@as(f32, 1), far_right.right, 0.001);
}

test "a zero spread disables panning entirely" {
    try testing.expectEqual(@as(f32, 0), panForOffset(5000, 0));
    try testing.expectEqual(@as(f32, 0), panForOffset(5000, -1));
}

test "attenuation is monotonic, zero at the edge, and NaN-free at the listener" {
    // Monotonic: closer is never quieter.
    var prev: f32 = 2;
    var d: f32 = 0;
    while (d <= 400) : (d += 20) {
        const g = attenuation(d, 0, 400);
        try testing.expect(g <= prev + 0.0001);
        try testing.expect(g >= 0 and g <= 1);
        prev = g;
    }
    // Exactly zero at the edge: the curve MEETS zero rather than cutting off,
    // which is what makes it click-free.
    try testing.expectEqual(@as(f32, 0), attenuation(400, 0, 400));
    try testing.expectEqual(@as(f32, 0), attenuation(99999, 0, 400));
    // Full volume at the listener, with no NaN from a zero distance.
    try testing.expectEqual(@as(f32, 1), attenuation(0, 0, 400));
}

test "max_distance 0 means global: never attenuated" {
    try testing.expectEqual(@as(f32, 1), attenuation(0, 0, 0));
    try testing.expectEqual(@as(f32, 1), attenuation(100000, 100000, 0));
}

test "a muted bus silences a voice, and so does being out of range" {
    const place = Placement{ .x = 100, .y = 0, .listener_x = 0, .spread = 200, .max_distance = 400 };
    try testing.expect(!place.gains(1.0, 1.0).isSilent());
    // Bus gain is the last multiply, so zero there silences everything without
    // the voice needing to know why.
    try testing.expect(place.gains(1.0, 0).isSilent());
    // And so does distance, independently of the bus.
    const far = Placement{ .x = 5000, .y = 0, .spread = 200, .max_distance = 400 };
    try testing.expect(far.gains(1.0, 1.0).isSilent());
}

test "rotating the listener turns the stereo field with it" {
    // Facing +x (rot 0): a sound to the world-east is hard right.
    const p = Placement{ .x = 100, .y = 0, .spread = 100, .max_distance = 0, .listener_rot = 0 };
    const facing_x = p.gains(1, 1);
    try testing.expectApproxEqAbs(@as(f32, 1), facing_x.right, 0.001);
    try testing.expectApproxEqAbs(@as(f32, 0), facing_x.left, 0.001);

    // A quarter turn to face +y makes the right vector +y, so the same
    // world-east sound is now straight ahead: both ears get it equally.
    var q = p;
    q.listener_rot = std.math.pi * 0.5;
    const facing_y = q.gains(1, 1);
    try testing.expectApproxEqAbs(facing_y.left, facing_y.right, 0.001);
    try testing.expectApproxEqAbs(@as(f32, 0.7071), facing_y.left, 0.001);
}

test "resampling compensates the rate ratio, and pitch scales it" {
    // A 44.1k source on a 48k device advances less than one source frame per
    // output frame, so it plays at its original pitch.
    const step = resampleStep(44100, 48000, 1.0);
    try testing.expectApproxEqAbs(44100.0 / 48000.0, step, 0.0001);
    try testing.expect(step < 1.0);
    // Same rate at pitch 2 is twice as fast: an octave up.
    try testing.expectApproxEqAbs(@as(f32, 2.0), resampleStep(48000, 48000, 2.0), 0.0001);
    // A degenerate rate or pitch must not divide by zero.
    try testing.expectEqual(@as(f32, 0), resampleStep(44100, 0, 1.0));
    try testing.expectEqual(@as(f32, 0), resampleStep(44100, 48000, 0));
}

test "sampleAt interpolates between frames and holds the last one" {
    // 4 mono frames: 0, 1, 0, -1.
    const data = [_]f32{ 0, 1, 0, -1 };
    const pcm = Pcm{ .frames = 4, .channels = 1, .sample_rate = 48000, .samples = &data };

    try testing.expectEqual(@as(f32, 0), sampleAt(pcm, 0, 0));
    try testing.expectEqual(@as(f32, 1), sampleAt(pcm, 1, 0));
    try testing.expectApproxEqAbs(@as(f32, 0.5), sampleAt(pcm, 0.5, 0), 0.0001);
    // Past the end: held, not wrapped (a wrap would restart the sound as a click).
    try testing.expectEqual(@as(f32, -1), sampleAt(pcm, 99, 0));
    // An empty sound reads as silence rather than indexing out of bounds.
    try testing.expectEqual(@as(f32, 0), sampleAt(Pcm{}, 0, 0));
}

test "a stream window is read in absolute frame space" {
    // A 1000-frame stream whose window holds frames 10..14 (4 frames, mono).
    const win = [_]f32{ 10, 11, 12, 13 };
    const pcm = Pcm{ .frames = 1000, .channels = 1, .sample_rate = 48000, .samples = &win, .base_frame = 10, .streaming = true };

    // Inside the window: the sample at the absolute cursor.
    try testing.expectEqual(@as(f32, 10), sampleAt(pcm, 10, 0));
    try testing.expectEqual(@as(f32, 13), sampleAt(pcm, 13, 0));
    try testing.expectApproxEqAbs(@as(f32, 11.5), sampleAt(pcm, 11.5, 0), 0.0001);

    // Before the window (not prefetched yet) and past it (underrun) are both
    // SILENCE — a stream must not hold or wrap, which would be a click.
    try testing.expectEqual(@as(f32, 0), sampleAt(pcm, 0, 0));
    try testing.expectEqual(@as(f32, 0), sampleAt(pcm, 14, 0));
    try testing.expectEqual(@as(f32, 0), sampleAt(pcm, 999, 0));
}

test "interleaved stereo reads the right channel" {
    // L/R interleaved: L ramps 0, 0.5, 1; R is the negation.
    const data = [_]f32{ 0, 0, 0.5, -0.5, 1, -1 };
    const pcm = Pcm{ .frames = 3, .channels = 2, .sample_rate = 48000, .samples = &data };
    try testing.expectApproxEqAbs(@as(f32, 0.5), sampleAt(pcm, 1, 0), 0.0001);
    try testing.expectApproxEqAbs(@as(f32, -0.5), sampleAt(pcm, 1, 1), 0.0001);
}

