//! The miniaudio backend: a real device, on its own thread (M8).
//!
//! ## What lives here
//!
//! A `VTable` implementation over miniaudio, reached through the C shim in
//! `miniaudio_impl.c` (Zig 0.16 cannot `@cImport` the header — the same wall
//! `stb_image.h` hit). The split is the port's, unchanged: this file owns the
//! device and load-time decoding, and nothing above it — the mixer, the voices,
//! the buses, the bank — knows miniaudio exists.
//!
//! ## The numbers this backend reports, and why they are the honest ones
//!
//! - **`sample_rate` / `channels`** are what the DATA CALLBACK receives, read
//!   back from the opened device. The mixer resamples voices against that
//!   number, never against what the project asked for, because a device that
//!   negotiated something else is the normal case and a mixer that assumed
//!   otherwise would play at the wrong pitch.
//! - **`period_frames`** is the negotiated period, so `latencyMs()` is derived
//!   from the buffer the device actually runs rather than the one requested.
//! - **`xruns`** counts mixes that did not finish inside their period. It is
//!   NOT a driver underrun counter: this miniaudio reports device
//!   start/stop/reroute notifications and no underrun event, so the only
//!   observable definition of "the mix glitched" is the one taken here, and it
//!   is the same thing a caller would hear. Written down because a counter whose
//!   definition is guessed is worse than no counter.
//!
//! ## No device is not an error
//!
//! A machine with no sound card, a container, CI: `create` returns null and the
//! system falls back to the null backend (silence, and a name the boot log
//! prints). The port's rule is that the engine keeps running — a game that
//! refuses to start because a headphone jack is missing is worse than a silent
//! game.

const std = @import("std");
const core = @import("core");
const audio = @import("audio.zig");

/// The shim's device, opaque to Zig.
const CDevice = opaque {};

/// The C ABI the shim calls back on. The engine's `MixCallback` is a Zig
/// function pointer, so this adapter is what carries it across: the boundary
/// has exactly one function whose signature both sides agree on.
const CMixFn = *const fn (ctx: ?*anyopaque, out: [*]f32, frames: u32) callconv(.c) void;

extern fn ember_audio_open(
    sample_rate: u32,
    period_frames: u32,
    channels: u32,
    mix: CMixFn,
    ctx: ?*anyopaque,
) ?*CDevice;
extern fn ember_audio_close(device: ?*CDevice) void;
extern fn ember_audio_start(device: ?*CDevice) c_int;
extern fn ember_audio_stop(device: ?*CDevice) void;
extern fn ember_audio_rate(device: ?*const CDevice) u32;
extern fn ember_audio_channels(device: ?*const CDevice) u32;
extern fn ember_audio_period(device: ?*const CDevice) u32;
extern fn ember_audio_xruns(device: ?*const CDevice) u64;
extern fn ember_audio_buffers(device: ?*const CDevice) u64;
extern fn ember_audio_backend(device: ?*const CDevice) ?[*:0]const u8;
extern fn ember_audio_decode(
    path: [*:0]const u8,
    out_samples: *?[*]f32,
    out_frames: *u64,
    out_rate: *u32,
    out_channels: *u32,
) c_int;
extern fn ember_audio_free(p: ?*anyopaque) void;

/// The shim's streaming decoder, opaque to Zig.
const CStream = opaque {};
/// Mirrors `ember_stream_info` in the shim: a length HINT (0 = unknown) plus the
/// resolved native rate and channel count.
const CStreamInfo = extern struct {
    frames: u64 = 0,
    rate: u32 = 0,
    channels: u32 = 0,
};
extern fn ember_audio_stream_open(path: [*:0]const u8, out: *CStreamInfo) ?*CStream;
extern fn ember_audio_stream_read(s: ?*CStream, out: [*]f32, frames: u64) u64;
extern fn ember_audio_stream_seek(s: ?*CStream, frame: u64) c_int;
extern fn ember_audio_stream_close(s: ?*CStream) void;

/// The Zig-side half of a device: the mixer to call and the context it takes,
/// both remembered so `destroyDevice` can free them with the matching allocator.
const DeviceCtx = struct {
    desc: audio.DeviceDesc,
    mix: audio.MixCallback,
    mix_ctx: ?*anyopaque,
    device: ?*CDevice = null,
};

fn cast(ctx: ?*anyopaque) *DeviceCtx {
    return @ptrCast(@alignCast(ctx.?));
}

fn mixTrampoline(ctx: ?*anyopaque, out: [*]f32, frames: u32) callconv(.c) void {
    const c = cast(ctx);
    c.mix(c.mix_ctx, out, frames);
}

fn createDevice(desc: audio.DeviceDesc, mix: audio.MixCallback, mix_ctx: ?*anyopaque) ?*anyopaque {
    const c = std.heap.c_allocator.create(DeviceCtx) catch return null;
    c.* = .{ .desc = desc, .mix = mix, .mix_ctx = mix_ctx };

    c.device = ember_audio_open(
        desc.sample_rate,
        desc.period_frames,
        desc.channels,
        mixTrampoline,
        c,
    ) orelse {
        std.heap.c_allocator.destroy(c);
        return null;
    };
    return c;
}

fn destroyDevice(ctx: ?*anyopaque) void {
    const c = cast(ctx);
    ember_audio_close(c.device);
    std.heap.c_allocator.destroy(c);
}

fn startDevice(ctx: ?*anyopaque) bool {
    return ember_audio_start(cast(ctx).device) != 0;
}

fn stopDevice(ctx: ?*anyopaque) void {
    ember_audio_stop(cast(ctx).device);
}

fn stats(ctx: ?*anyopaque) audio.Stats {
    const c = cast(ctx);
    return .{
        .period_frames = ember_audio_period(c.device),
        .sample_rate = ember_audio_rate(c.device),
        .channels = @intCast(ember_audio_channels(c.device)),
        .xruns = ember_audio_xruns(c.device),
    };
}

/// Frames the device has rendered. Only the bench and the tests read it; a real
/// device renders on its own thread, so it is a progress check, not a clock.
pub fn buffers(ctx: ?*anyopaque) u64 {
    return ember_audio_buffers(cast(ctx).device);
}

/// The longest path this backend will decode. Paths come from the file system
/// and the bank already owns its copy of them; a stack buffer keeps load-time
/// decoding allocation-free up to here, and anything longer is refused loudly
/// rather than NUL-terminated into someone else's memory.
pub const max_path_bytes = 1024;

/// A NUL-terminated copy of `path` in `buf`, or null when it does not fit.
fn cstr(path: []const u8, buf: *[max_path_bytes]u8) ?[*:0]const u8 {
    if (path.len + 1 > buf.len) return null;
    @memcpy(buf[0..path.len], path);
    buf[path.len] = 0;
    return buf[0..path.len :0];
}

/// Opens a streaming decoder. LOAD TIME: it opens the file. Reading is
/// `streamRead`, which the engine's main thread calls into a ring.
fn streamOpen(path: []const u8, out: *audio.StreamInfo) audio.StreamError!?*anyopaque {
    var path_buf: [max_path_bytes]u8 = undefined;
    const c_path = cstr(path, &path_buf) orelse return error.FileNotFound;
    var info: CStreamInfo = .{};
    const s = ember_audio_stream_open(c_path, &info) orelse return error.UnsupportedFormat;
    out.* = .{
        .frames = @intCast(@min(info.frames, std.math.maxInt(u32))),
        .channels = @intCast(@max(info.channels, 1)),
        .sample_rate = if (info.rate != 0) info.rate else 48000,
    };
    return @ptrCast(s);
}

fn streamRead(handle: ?*anyopaque, out: [*]f32, frames: u32) u32 {
    const s: ?*CStream = if (handle) |h| @ptrCast(@alignCast(h)) else return 0;
    return @intCast(ember_audio_stream_read(s, out, frames));
}

fn streamSeek(handle: ?*anyopaque, frame: u32) bool {
    const s: ?*CStream = if (handle) |h| @ptrCast(@alignCast(h)) else return false;
    return ember_audio_stream_seek(s, frame) != 0;
}

fn streamClose(handle: ?*anyopaque) void {
    if (handle) |h| ember_audio_stream_close(@ptrCast(@alignCast(h)));
}

fn decode(allocator: std.mem.Allocator, path: []const u8, out: *audio.Pcm) audio.DecodeError!void {
    var path_buf: [max_path_bytes]u8 = undefined;
    const c_path = cstr(path, &path_buf) orelse return error.FileNotFound;

    var c_samples: ?[*]f32 = null;
    var frames: u64 = 0;
    var rate: u32 = 0;
    var channels: u32 = 0;
    const rc = ember_audio_decode(c_path, &c_samples, &frames, &rate, &channels);
    switch (rc) {
        0 => {},
        1 => return error.FileNotFound,
        2 => return error.UnsupportedFormat,
        else => return error.OutOfMemory,
    }
    // The buffer belongs to the C side's allocator; it is released here on
    // EVERY path, including the ones below that fail.
    defer ember_audio_free(@ptrCast(c_samples));

    if (frames == 0 or channels == 0 or c_samples == null) {
        out.* = .{}; // an empty file is a valid sound: it plays for zero frames
        return;
    }

    // Copied into the caller's allocator, because ownership has to match the
    // free: the bank frees with the allocator it was built with, not with
    // malloc. One copy at load time, never in the frame.
    const count: usize = @intCast(frames * channels);
    const samples = try allocator.alloc(f32, count);
    @memcpy(samples, c_samples.?[0..count]);

    out.* = .{
        .frames = @intCast(frames),
        .channels = @intCast(channels),
        .sample_rate = rate,
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
    // No `pump`: a real device owns its own clock, and rendering on demand is
    // exactly the thing that would make the engine's timing a lie.
    .pump = null,
};

/// The backend name miniaudio is actually using (alsa, pulseaudio, coreaudio,
/// ...), for the boot log line. Static storage owned by miniaudio.
fn backendName(ctx: ?*anyopaque) []const u8 {
    const name = ember_audio_backend(cast(ctx).device);
    return if (name) |n| std.mem.span(n) else "miniaudio";
}

/// Opens a real device. Null when there is none, or when the driver refuses:
/// the caller falls back to silence and says which backend answered, which is
/// the difference between a silent game and a mystery.
pub fn create(desc: audio.DeviceDesc, mix: audio.MixCallback, mix_ctx: ?*anyopaque) ?audio.Device {
    const ctx = createDevice(desc, mix, mix_ctx) orelse return null;
    return .{
        .vtable = &vtable,
        .ctx = ctx,
        .name = backendName(ctx),
    };
}

// ── Tests ────────────────────────────────────────────────────────────────────

const testing = std.testing;

fn noopMix(_: ?*anyopaque, out: [*]f32, frames: u32) void {
    for (0..frames) |i| out[i] = 0;
}

/// A 16-bit PCM WAV with `frames` mono samples of `value`, written by hand:
/// the decode path is the one thing here that reads a real file, and this is
/// how it gets one without committing an asset to the repository.
fn writeTestWav(path: []const u8, frames: u32, rate: u32, value: i16) !void {
    const channels: u16 = 1;
    const bytes_per_sample: u32 = 2;
    const data_bytes = frames * channels * bytes_per_sample;

    var header: [44]u8 = undefined;
    var w: usize = 0;
    const put = struct {
        fn bytes(buf: []u8, at: *usize, src: []const u8) void {
            @memcpy(buf[at.* .. at.* + src.len], src);
            at.* += src.len;
        }
        fn u32le(buf: []u8, at: *usize, v: u32) void {
            std.mem.writeInt(u32, buf[at.*..][0..4], v, .little);
            at.* += 4;
        }
        fn u16le(buf: []u8, at: *usize, v: u16) void {
            std.mem.writeInt(u16, buf[at.*..][0..2], v, .little);
            at.* += 2;
        }
    };
    put.bytes(&header, &w, "RIFF");
    put.u32le(&header, &w, 36 + data_bytes);
    put.bytes(&header, &w, "WAVE");
    put.bytes(&header, &w, "fmt ");
    put.u32le(&header, &w, 16);
    put.u16le(&header, &w, 1); // PCM
    put.u16le(&header, &w, channels);
    put.u32le(&header, &w, rate);
    put.u32le(&header, &w, rate * channels * bytes_per_sample); // byte rate
    put.u16le(&header, &w, @intCast(channels * bytes_per_sample)); // block align
    put.u16le(&header, &w, 16); // bits per sample
    put.bytes(&header, &w, "data");
    put.u32le(&header, &w, data_bytes);

    var body = std.ArrayList(u8).empty;
    defer body.deinit(testing.allocator);
    try body.appendSlice(testing.allocator, &header);
    var i: u32 = 0;
    while (i < frames) : (i += 1) {
        var sample: [2]u8 = undefined;
        std.mem.writeInt(i16, &sample, value, .little);
        try body.appendSlice(testing.allocator, &sample);
    }

    const io = std.Io.Threaded.global_single_threaded.io();
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = path, .data = body.items });
}

test "decode reads a real WAV at its native rate, with the samples intact" {
    const alloc = testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var buf: [256]u8 = undefined;
    const path = try std.fmt.bufPrint(&buf, ".zig-cache/tmp/{s}/tone.wav", .{tmp.sub_path});
    try writeTestWav(path, 800, 48000, 16384); // 16384/32768 = 0.5

    var pcm = audio.Pcm{};
    try decode(alloc, path, &pcm);
    defer alloc.free(pcm.samples);

    try testing.expectEqual(@as(u32, 800), pcm.frames);
    try testing.expectEqual(@as(u16, 1), pcm.channels);
    try testing.expectEqual(@as(u32, 48000), pcm.sample_rate);
    try testing.expectApproxEqAbs(@as(f32, 0.5), pcm.samples[10], 0.001);
    // The LAST frame too: a decoder that read one buffer's worth and stopped
    // would pass a check on frame 0 and fail this one.
    try testing.expectApproxEqAbs(@as(f32, 0.5), pcm.samples[799], 0.001);
}

test "a real WAV streams in chunks, with the whole file never resident" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var buf: [256]u8 = undefined;
    const path = try std.fmt.bufPrint(&buf, ".zig-cache/tmp/{s}/long.wav", .{tmp.sub_path});
    const total: u32 = 5000;
    try writeTestWav(path, total, 48000, 16384); // 16384/32768 = 0.5

    var info = audio.StreamInfo{};
    const h = (try streamOpen(path, &info)).?;
    defer streamClose(h);
    try testing.expectEqual(@as(u16, 1), info.channels);
    try testing.expectEqual(@as(u32, 48000), info.sample_rate);
    // A WAV carries its length in the header, so the stream can report it.
    try testing.expectEqual(total, info.frames);

    // Read in odd-sized chunks: the concatenation must be the whole tone, and
    // the read must really be chunked (many reads), not one big slurp.
    var got_total: u32 = 0;
    var reads: u32 = 0;
    var chunk: [333]f32 = undefined;
    while (true) {
        const n = streamRead(h, &chunk, chunk.len);
        if (n == 0) break;
        for (chunk[0..n]) |s| try testing.expectApproxEqAbs(@as(f32, 0.5), s, 0.001);
        got_total += n;
        reads += 1;
    }
    try testing.expectEqual(total, got_total);
    try testing.expect(reads >= 15);

    // Seek to the middle and read: still the tone, from the right place.
    try testing.expect(streamSeek(h, 2000));
    var one: [4]f32 = undefined;
    const n2 = streamRead(h, &one, 4);
    try testing.expectEqual(@as(u32, 4), n2);
    try testing.expectApproxEqAbs(@as(f32, 0.5), one[0], 0.001);
}

test "decode tells a missing file apart from a file that is not audio" {
    const alloc = testing.allocator;
    var pcm = audio.Pcm{};
    try testing.expectError(error.FileNotFound, decode(alloc, "definitely-not-here.wav", &pcm));

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var buf: [256]u8 = undefined;
    const path = try std.fmt.bufPrint(&buf, ".zig-cache/tmp/{s}/junk.wav", .{tmp.sub_path});
    const io = std.Io.Threaded.global_single_threaded.io();
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = path, .data = "this is not a sound\x00\x00\x00\x00" });
    try testing.expectError(error.UnsupportedFormat, decode(alloc, path, &pcm));
}

test "a path too long for the stack buffer is refused, not truncated" {
    const long = "x" ** (max_path_bytes + 1);
    var pcm = audio.Pcm{};
    try testing.expectError(error.FileNotFound, decode(testing.allocator, long, &pcm));
}

test "the real device opens, or says it could not — and never crashes either way" {
    // Headless CI has no sound card. That is a documented outcome (silence plus
    // a name in the log), not a reason to skip: the test asserts what it can on
    // a machine that has one, and says so on a machine that does not.
    const d = create(.{ .sample_rate = 48000, .period_frames = 480, .channels = 2 }, noopMix, null) orelse return;
    defer d.deinit();

    try testing.expect(d.name.len > 0);
    try testing.expect(d.start());
    // Let the device thread hand us at least one buffer, so the period below is
    // the MEASURED callback size rather than the one we asked for. `core.time`
    // is the repo's clock (std.Thread.sleep does not exist in this Zig), and it
    // is test-only: nothing in the runtime path of this file waits for anything.
    core.time.sleepNs(50 * std.time.ns_per_ms);

    const s = d.stats();
    try testing.expect(s.sample_rate > 0);
    try testing.expect(s.channels >= 1);
    try testing.expect(s.period_frames > 0);
    // The M8 criterion, against the device that actually opened: the period is
    // the size of the buffers it handed us, not the one we asked for.
    try testing.expect(s.latencyMs() <= 20.0);
    // And the device thread is really running the mixer: mixes happened, and
    // none of them ran past its period.
    try testing.expect(ember_audio_buffers(cast(d.ctx).device) > 0);
    try testing.expectEqual(@as(u64, 0), s.xruns);
    d.stop();
}
