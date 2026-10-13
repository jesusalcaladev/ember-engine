//! The null audio backend: no device, no thread, deterministic PCM (M8).
//!
//! ## Why this exists, and why it is first-class
//!
//! The M8 criterion (64 simultaneous emitters, ≤ 20 ms, no main-thread spikes)
//! has to be measurable on a CI box with no sound card, and the mixing maths has
//! to be exercisable without one too. This backend opens nothing, starts no
//! thread, and is driven explicitly by `pump(frames)` — so a test advances the
//! exact same mixer the real device runs, one buffer at a time, and gets the
//! same answer every time.
//!
//! `decode` synthesises PCM for any path rather than reading a file, so the
//! bank, the voices and the bindings all have something to play with no assets
//! on disk. A path may carry a size: `<anything>:<frames>` gives that many mono
//! frames of a 440 Hz tone; anything else is a fixed short tone. The tone (not
//! silence) is deliberate: a silent buffer passes a panning test while proving
//! nothing.

const std = @import("std");
const audio = @import("audio.zig");

/// Frames synthesised for a path with no explicit size, and the tone's pitch.
pub const default_frames: u32 = 240;
pub const tone_hz: f32 = 440.0;
pub const tone_rate: u32 = 48000;

/// One null device. Owned by the backend; `createDevice` allocates it and
/// `destroyDevice` frees it, because the port hands back only an opaque context.
const DeviceCtx = struct {
    desc: audio.DeviceDesc,
    mix: audio.MixCallback,
    mix_ctx: ?*anyopaque,
    started: bool = false,
    /// Buffers rendered since boot. The bench reads it to prove the pump ran.
    buffers: u64 = 0,
    frames_rendered: u64 = 0,
};

fn cast(ctx: ?*anyopaque) *DeviceCtx {
    return @ptrCast(@alignCast(ctx.?));
}

fn createDevice(desc: audio.DeviceDesc, mix: audio.MixCallback, mix_ctx: ?*anyopaque) ?*anyopaque {
    const c = std.heap.c_allocator.create(DeviceCtx) catch return null;
    c.* = .{ .desc = desc, .mix = mix, .mix_ctx = mix_ctx };
    return c;
}

fn destroyDevice(ctx: ?*anyopaque) void {
    std.heap.c_allocator.destroy(cast(ctx));
}

fn startDevice(ctx: ?*anyopaque) bool {
    cast(ctx).started = true;
    return true;
}

fn stopDevice(ctx: ?*anyopaque) void {
    cast(ctx).started = false;
}

fn stats(ctx: ?*anyopaque) audio.Stats {
    const c = cast(ctx);
    return .{
        .period_frames = c.desc.period_frames,
        .sample_rate = c.desc.sample_rate,
        .channels = c.desc.channels,
        // A backend with no device cannot underrun: there is no clock to miss.
        .xruns = 0,
    };
}

/// Renders `frames` frames by calling the mixer directly. Chunked so the
/// scratch buffer stays on the stack whatever size the caller asks for.
fn pump(ctx: ?*anyopaque, frames: u32) void {
    const c = cast(ctx);
    const ch: u32 = @max(1, c.desc.channels);
    const scratch_frames: u32 = 4096 / ch;
    var scratch: [4096]f32 = undefined;
    var remaining = frames;
    while (remaining > 0) {
        const n = @min(remaining, scratch_frames);
        c.mix(c.mix_ctx, &scratch, n);
        remaining -= n;
        c.frames_rendered += n;
        c.buffers += 1;
    }
}

/// Frame count encoded in a path: `<anything>:<frames>`, else `default_frames`.
/// One parser for both the whole-file and the streaming paths, so a test can
/// ask for the same length either way.
fn framesOf(path: []const u8) u32 {
    if (std.mem.lastIndexOfScalar(u8, path, ':')) |colon| {
        return std.fmt.parseInt(u32, path[colon + 1 ..], 10) catch default_frames;
    }
    return default_frames;
}

/// A null STREAM: the tone is synthesised read by read instead of decoded into
/// one buffer, which is what makes "streaming a huge sound does not allocate
/// the huge sound" a property a test can check on a machine with no disk.
const StreamCtx = struct {
    frames: u32,
    channels: u16,
    rate: u32,
    cursor: u32 = 0,
};

fn streamOpen(path: []const u8, out: *audio.StreamInfo) audio.StreamError!?*anyopaque {
    const c = std.heap.c_allocator.create(StreamCtx) catch return error.OutOfMemory;
    c.* = .{ .frames = framesOf(path), .channels = 1, .rate = tone_rate };
    out.* = .{ .frames = c.frames, .channels = c.channels, .sample_rate = c.rate };
    return c;
}

fn streamRead(handle: ?*anyopaque, out: [*]f32, frames: u32) u32 {
    const c: *StreamCtx = @ptrCast(@alignCast(handle.?));
    if (c.cursor >= c.frames) return 0;
    const n = @min(frames, c.frames - c.cursor);
    const step = 2.0 * std.math.pi * tone_hz / @as(f32, @floatFromInt(c.rate));
    var i: u32 = 0;
    while (i < n) : (i += 1) {
        out[i] = 0.5 * @sin(step * @as(f32, @floatFromInt(c.cursor + i)));
    }
    c.cursor += n;
    return n;
}

fn streamSeek(handle: ?*anyopaque, frame: u32) bool {
    const c: *StreamCtx = @ptrCast(@alignCast(handle.?));
    c.cursor = @min(frame, c.frames);
    return true;
}

fn streamClose(handle: ?*anyopaque) void {
    const c: *StreamCtx = @ptrCast(@alignCast(handle.?));
    std.heap.c_allocator.destroy(c);
}

fn decode(allocator: std.mem.Allocator, path: []const u8, out: *audio.Pcm) audio.DecodeError!void {
    const frames: u32 = framesOf(path);
    if (frames == 0) {
        out.* = .{};
        return;
    }
    const samples = allocator.alloc(f32, frames) catch return error.OutOfMemory;
    const step = 2.0 * std.math.pi * tone_hz / @as(f32, @floatFromInt(tone_rate));
    for (samples, 0..) |*s, i| {
        s.* = 0.5 * @sin(step * @as(f32, @floatFromInt(i)));
    }
    out.* = .{
        .frames = frames,
        .channels = 1,
        .sample_rate = tone_rate,
        .samples = samples,
    };
}

pub const vtable = audio.VTable{
    .createDevice = createDevice,
    .destroyDevice = destroyDevice,
    .startDevice = startDevice,
    .stopDevice = stopDevice,
    .stats = stats,
    .decode = decode,
    .streamOpen = streamOpen,
    .streamRead = streamRead,
    .streamSeek = streamSeek,
    .streamClose = streamClose,
    .pump = pump,
};

/// Opens a null device. The only way to fail is the small context allocation,
/// which is reported as null rather than as an `undefined` pointer.
pub fn create(desc: audio.DeviceDesc, mix: audio.MixCallback, mix_ctx: ?*anyopaque) ?audio.Device {
    const ctx = createDevice(desc, mix, mix_ctx) orelse return null;
    return .{
        .vtable = &vtable,
        .ctx = ctx,
        .name = "null",
    };
}

// ── Tests ────────────────────────────────────────────────────────────────────

const testing = std.testing;

test "the null device reports zero xruns and the requested period" {
    const d = create(.{ .sample_rate = 48000, .period_frames = 480, .channels = 2 }, noopMix, null).?;
    defer d.deinit();
    try testing.expectEqualStrings("null", d.name);
    try testing.expect(d.start());
    const s = d.stats();
    try testing.expectEqual(@as(u32, 480), s.period_frames);
    try testing.expectEqual(@as(u64, 0), s.xruns);
    try testing.expect(s.latencyMs() <= 20.0);
}

test "decode synthesises a sized tone and rejects nothing" {
    const alloc = testing.allocator;
    var pcm = audio.Pcm{};
    try decode(alloc, "boom:100", &pcm);
    defer alloc.free(pcm.samples);
    try testing.expectEqual(@as(u32, 100), pcm.frames);
    try testing.expectEqual(@as(u16, 1), pcm.channels);
    // A named file with no size still yields a playable short tone.
    var pcm2 = audio.Pcm{};
    try decode(alloc, "click.wav", &pcm2);
    defer alloc.free(pcm2.samples);
    try testing.expectEqual(default_frames, pcm2.frames);
}

test "a null stream synthesises the tone read by read, and ends" {
    var info = audio.StreamInfo{};
    const h = (try streamOpen("music:1000", &info)).?;
    defer streamClose(h);
    try testing.expectEqual(@as(u32, 1000), info.frames);
    try testing.expectEqual(@as(u16, 1), info.channels);

    // Read the whole thing in odd-sized chunks: the concatenation must be the
    // tone, and the read must report end-of-source rather than looping.
    var got_total: u32 = 0;
    var buf: [7]f32 = undefined;
    while (true) {
        const n = streamRead(h, &buf, buf.len);
        if (n == 0) break;
        try testing.expect(n <= buf.len);
        got_total += n;
    }
    try testing.expectEqual(@as(u32, 1000), got_total);

    // Seek back and confirm the first sample matches a fresh stream's.
    try testing.expect(streamSeek(h, 0));
    var a: [1]f32 = undefined;
    _ = streamRead(h, &a, 1);
    try testing.expectApproxEqAbs(@as(f32, 0), a[0], 0.0001);
}

test "pump drives the mixer for the exact number of frames asked for" {
    const S = struct {
        var total: u32 = 0;
        var last_channels: u32 = 0;
        fn mix(_: ?*anyopaque, out: [*]f32, frames: u32) void {
            total += frames;
            last_channels = frames;
            for (0..frames) |i| out[i] = 0;
        }
    };
    S.total = 0;
    const d = create(.{ .period_frames = 480, .channels = 2 }, S.mix, null).?;
    defer d.deinit();
    _ = d.start();
    d.pump(1000);
    try testing.expectEqual(@as(u32, 1000), S.total);
}

fn noopMix(_: ?*anyopaque, out: [*]f32, frames: u32) void {
    for (0..frames) |i| out[i] = 0;
}
