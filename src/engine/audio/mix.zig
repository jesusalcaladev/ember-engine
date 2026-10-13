//! The mix loop: the per-sample work `mixer.zig` deliberately does not contain.
//!
//! `mixer.zig` is pure placement maths — where a voice sits, how loud, how it
//! pans. This file is the render: walk the voices, advance each cursor, sum into
//! the output, apply master gain, and soft-clip so 64 summed emitters distort
//! gracefully instead of wrapping.
//!
//! ## Why it is a separate, pure function
//!
//! The loop runs on the device thread inside `Audio.mixCallback`, but it is
//! written as a free function over plain slices so the null backend (and every
//! test) can call it directly, with no device and no thread, and get the same
//! answer. That is what makes "64 emitters" a number a test can check.
//!
//! ## What it does NOT do
//!
//! It does not allocate, it does not lock, and it does not call back into
//! gameplay. When a voice ends it is marked inactive and reported through the
//! `FinishSink`, which the caller turns into an event; the main thread is what
//! eventually raises the signal (spec §7, §10).

const std = @import("std");
const audio = @import("audio.zig");
const voice_mod = @import("voice.zig");
const bank_mod = @import("bank.zig");
const mixer = @import("mixer.zig");

const Voice = voice_mod.Voice;
const Bank = bank_mod.Bank;

/// Where a finished voice goes. A sink rather than a returned list: the caller
/// (the system) turns it into an event immediately, and a list would have to be
/// sized for the worst case.
pub const FinishSink = struct {
    ctx: *anyopaque,
    onFinish: *const fn (ctx: *anyopaque, v: *const Voice) void,
};

/// How the mix is placed. Plain data so it is cheap to build per buffer.
pub const Params = struct {
    /// Output rate, which the resampler is measured against (never a request).
    output_rate: u32,
    channels: u16,
    listener_x: f32,
    listener_y: f32,
    /// Which way the ears face (radians). Rotates the pan axis (`mixer.zig`).
    listener_rot: f32 = 0,
    /// Per-bus effective gain, already folded: mute, solo and any send have
    /// been applied by the caller, so this loop is one multiply per voice.
    bus_gain: []const f32,
    master_gain: f32 = 1,
};

/// Renders `frames` frames of interleaved f32 into `out`.
///
/// `out` must have room for `frames * params.channels` samples.
pub fn render(
    voices: []Voice,
    bank: *Bank,
    params: Params,
    out: [*]f32,
    frames: u32,
    sink: FinishSink,
) void {
    const channels = @max(1, params.channels);
    const out_len: usize = @as(usize, frames) * channels;
    @memset(out[0..out_len], 0);

    for (voices) |*v| {
        if (!v.active) continue;
        const pcm = bank.peek(v.bank_slot) orelse {
            // The bank evicted this sound out from under a live voice. End it
            // rather than mixing silence forever.
            v.active = false;
            sink.onFinish(sink.ctx, v);
            continue;
        };

        const gain = if (v.bus < params.bus_gain.len) params.bus_gain[v.bus] else 1.0;
        const place = mixer.Placement{
            .x = v.x,
            .y = v.y,
            .listener_x = params.listener_x,
            .listener_y = params.listener_y,
            .spread = v.spread,
            .max_distance = v.max_distance,
            .listener_rot = params.listener_rot,
        };
        const gains = place.gains(v.base_volume, gain);
        // The steal policy reads this on the NEXT allocate, so it must be the
        // level the voice is actually playing at.
        v.level = gains.level;
        if (gains.isSilent()) continue;

        const step = mixer.resampleStep(pcm.sample_rate, params.output_rate, v.pitch);
        if (step <= 0) {
            v.active = false;
            sink.onFinish(sink.ctx, v);
            continue;
        }

        const source_len: f32 = @floatFromInt(pcm.frames);
        var cursor = v.cursor;
        var f: u32 = 0;
        while (f < frames) : (f += 1) {
            const s = mixer.sampleAt(pcm, cursor, 0) * gains.level;
            const idx: usize = @as(usize, f) * channels;
            out[idx] += s * gains.left;
            if (channels > 1) {
                // Mono sources pan; a stereo source's right channel is read
                // when the file has one, otherwise the same sample feeds both.
                const right_ch: u16 = if (pcm.channels > 1) 1 else 0;
                const r = mixer.sampleAt(pcm, cursor, right_ch) * gains.level;
                out[idx + 1] += r * gains.right;
            }
            cursor += step;
        }
        v.cursor = cursor;
        // A streaming sound tells the bank how far the device has read, so the
        // main thread knows how far the prefetch window can slide. An atomic
        // store on the device thread; a plain no-op for a resident sound.
        if (pcm.streaming) bank.noteStreamCursor(v.bank_slot, cursor);

        if (cursor >= source_len) {
            if (v.loop) {
                v.cursor = @mod(cursor, source_len);
            } else {
                v.active = false;
                v.cursor = source_len;
                sink.onFinish(sink.ctx, v);
            }
        }
    }

    // Master gain, then a soft clip. Hard clipping a 64-voice sum is a buzz;
    // tanh compresses the peaks instead, so an over-loud frame is quiet-
    // distorted rather than wrapped.
    if (params.master_gain == 1.0) {
        for (out[0..out_len]) |*o| o.* = softClip(o.*);
    } else {
        for (out[0..out_len]) |*o| o.* = softClip(o.* * params.master_gain);
    }
}

/// A symmetric, monotone soft clipper. `tanh` is the shape; near zero it is
/// nearly linear (so normal levels are untouched), and it saturates at ±1.
pub fn softClip(x: f32) f32 {
    return std.math.tanh(x);
}

// ── Tests ────────────────────────────────────────────────────────────────────

const testing = std.testing;
const Pcm = audio.Pcm;

const Harness = struct {
    var finished: usize = 0;
    fn onFinish(_: *anyopaque, _: *const Voice) void {
        finished += 1;
    }
    fn sink() FinishSink {
        finished = 0;
        return .{ .ctx = undefined, .onFinish = onFinish };
    }
};

/// A bank with one slot holding `frames` of a constant 1.0 (mono, 48 kHz), so
/// the render's output is a direct read of the gains.
fn makeBank(alloc: std.mem.Allocator, frames: u32) !Bank {
    var b = try Bank.init(alloc, 2, 1 << 20);
    const samples = try alloc.alloc(f32, frames);
    @memset(samples, 1.0);
    // Install directly: the bank's public load path needs a device, and this
    // test is about the render, not the loader.
    b.slots[0].pcm = .{ .frames = frames, .channels = 1, .sample_rate = 48000, .samples = samples };
    b.slots[0].path = try alloc.dupe(u8, "unit");
    b.bytes_used += frames * @sizeOf(f32);
    return b;
}

test "a centred voice sums into both channels at constant power" {
    const alloc = testing.allocator;
    var bank = try makeBank(alloc, 64);
    defer bank.deinit();

    var voices = [_]Voice{.{ .active = true, .bank_slot = 0, .base_volume = 1, .max_distance = 0 }};
    var out: [128]f32 = undefined;
    render(&voices, &bank, .{ .output_rate = 48000, .channels = 2, .bus_gain = &.{1}, .listener_x = 0, .listener_y = 0 }, &out, 64, Harness.sink());

    // Constant power at centre: 0.707 per channel, so ~0.778 after tanh(0.707).
    try testing.expectApproxEqAbs(softClip(0.7071), out[0], 0.01);
    try testing.expectApproxEqAbs(softClip(0.7071), out[1], 0.01);
    // The voice is 64 frames long and we asked for exactly 64: it ends.
    try testing.expect(!voices[0].active);
    try testing.expectEqual(@as(usize, 1), Harness.finished);
}

test "a hard-left voice is silent in the right ear, and attenuation is real" {
    const alloc = testing.allocator;
    var bank = try makeBank(alloc, 64);
    defer bank.deinit();

    // max_distance > 0 makes it positional; spread 100 at dx=-100 is hard left.
    var voices = [_]Voice{.{
        .active = true,
        .bank_slot = 0,
        .base_volume = 1,
        .x = -100,
        .y = 0,
        .spread = 100,
        .max_distance = 400,
    }};
    var out: [128]f32 = undefined;
    render(&voices, &bank, .{ .output_rate = 48000, .channels = 2, .bus_gain = &.{1}, .listener_x = 0, .listener_y = 0 }, &out, 64, Harness.sink());
    try testing.expect(out[0] > 0.01); // left has signal
    try testing.expectApproxEqAbs(@as(f32, 0), out[1], 0.0001); // right is silent
}

test "a muted bus silences a voice without stopping it" {
    const alloc = testing.allocator;
    var bank = try makeBank(alloc, 64);
    defer bank.deinit();

    var voices = [_]Voice{.{ .active = true, .bank_slot = 0, .base_volume = 1, .bus = 3, .max_distance = 0 }};
    var out: [128]f32 = undefined;
    render(&voices, &bank, .{ .output_rate = 48000, .channels = 2, .bus_gain = &.{ 1, 1, 1, 0 }, .listener_x = 0, .listener_y = 0 }, &out, 64, Harness.sink());
    try testing.expectApproxEqAbs(@as(f32, 0), out[0], 0.0001);
    // A muted voice keeps playing: the bus is the duck, not a stop.
    try testing.expect(voices[0].active);
}

test "a looping voice wraps its cursor instead of finishing" {
    const alloc = testing.allocator;
    var bank = try makeBank(alloc, 16);
    defer bank.deinit();

    var voices = [_]Voice{.{ .active = true, .bank_slot = 0, .base_volume = 1, .loop = true, .max_distance = 0 }};
    // 100 frames x 2 channels = 200 samples: the buffer must be at least that,
    // or the render writes past the end of the test's frame.
    var out: [256]f32 = undefined;
    render(&voices, &bank, .{ .output_rate = 48000, .channels = 2, .bus_gain = &.{1}, .listener_x = 0, .listener_y = 0 }, &out, 100, Harness.sink());
    try testing.expect(voices[0].active);
    try testing.expectEqual(@as(usize, 0), Harness.finished);
    try testing.expect(voices[0].cursor < 16.0);
}

test "an evicted sound ends its voice rather than mixing silence forever" {
    const alloc = testing.allocator;
    var bank = try Bank.init(alloc, 2, 1 << 20);
    defer bank.deinit();

    // Voice points at a slot with nothing in it.
    var voices = [_]Voice{.{ .active = true, .bank_slot = 1, .base_volume = 1 }};
    var out: [8]f32 = undefined;
    render(&voices, &bank, .{ .output_rate = 48000, .channels = 2, .bus_gain = &.{1}, .listener_x = 0, .listener_y = 0 }, &out, 4, Harness.sink());
    try testing.expect(!voices[0].active);
    try testing.expectEqual(@as(usize, 1), Harness.finished);
}

test "soft clip is monotone, symmetric, and bounded" {
    try testing.expectApproxEqAbs(@as(f32, 0), softClip(0), 0.0001);
    try testing.expectApproxEqAbs(softClip(0.5), -softClip(-0.5), 0.0001);
    try testing.expect(softClip(1e9) < 1.0000001);
    try testing.expect(softClip(0.1) < 0.1); // gently compressed even small
    try testing.expect(softClip(0.1) > 0.09);
}
