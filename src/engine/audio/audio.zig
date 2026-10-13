//! Audio port — the backend-agnostic contract (ROADMAP M8).
//!
//! Same shape as `physics/physics.zig` and `render/render.zig`: a `VTable` a
//! backend fulfills, plus the vocabulary both sides speak. A backend implements
//! this table and nothing above it moves.
//!
//! ## Why the port, when the roadmap just says "miniaudio"
//!
//! Because spec §7 names Windows, Linux AND Web as v1 targets, and §8 says Web
//! runs with no threads by default. miniaudio starts its own device thread —
//! there is no such thing on the Web without SharedArrayBuffer. Building M8
//! directly against miniaudio would therefore build a path that M10 has to
//! throw away. The port makes that a second file instead of an audit.
//!
//! ## The dividing line, stated exactly
//!
//! The backend owns exactly two things:
//!   1. **the device** — its thread, its clock, its sample format, and the
//!      conversion from our f32 mix to whatever the hardware wants;
//!   2. **decoding** — a file in, PCM out, at load time only.
//!
//! Everything else is engine-side and pure: the voice pool, the mixer maths, the
//! buses, the decoded-sound cache, the command ring. That split is what makes
//! the interesting half testable with no sound card at all — `null.zig` opens no
//! device and synthesises its sounds, so the whole mixing path is exercised
//! headlessly and deterministically.
//!
//! The backend never owns the mixer. It is handed a callback (`MixCallback`)
//! that calls back into engine code, so the maths a shader and a speaker both
//! depend on lives in exactly one place.

const std = @import("std");

/// A live voice handle: index plus generation, so a recycled slot is never
/// mistaken for the voice that used to live there. The same scheme
/// `physics.BodyId` and `ecs.Entity` use, for the same reason.
pub const VoiceId = struct {
    index: u32 = invalid_index,
    generation: u32 = 0,

    pub const invalid_index = std.math.maxInt(u32);
    pub const none = VoiceId{};

    pub fn isNone(self: VoiceId) bool {
        return self.index == invalid_index;
    }
};

/// A decoded sound, ready to mix. Interleaved f32, at `sample_rate`.
///
/// `samples` is BORROWED: the bank owns the allocation, and this struct is the
/// loan it hands the mixer. Keeping ownership out of the loan is what lets a
/// voice be a plain struct that gets copied around (registry rule 1) while the
/// kilobytes stay in one place with a byte budget on them (§5).
pub const Pcm = struct {
    /// TOTAL frames in the source, not the length of `samples`. For a resident
    /// sound the two are equal; for a stream `samples` is one prefetched
    /// WINDOW of a much longer sound, so the mixer still knows where the sound
    /// ends.
    frames: u32 = 0,
    channels: u16 = 1,
    sample_rate: u32 = 44100,
    /// Interleaved f32 in [-1, 1], borrowed from the bank.
    samples: []const f32 = &.{},
    /// Absolute source frame that `samples[0]` corresponds to. 0 for a fully
    /// resident sound; for a stream it is where the current window starts.
    base_frame: u32 = 0,
    /// True when `samples` is a window of a longer sound rather than the whole
    /// thing. Readers must tolerate a cursor outside the window (it means the
    /// prefetch fell behind) instead of treating it as the end of the sound.
    streaming: bool = false,

    /// Frames actually covered by `samples`. The resident case equals `frames`;
    /// the stream case is smaller and is what bounds a window read.
    pub fn windowFrames(self: Pcm) u32 {
        if (self.channels == 0) return 0;
        return @intCast(self.samples.len / self.channels);
    }

    pub fn isEmpty(self: Pcm) bool {
        return self.frames == 0 or self.samples.len == 0;
    }
};

/// What the backend reports about itself. Reachable from Lua as `audio.stats()`
/// for the same reason `physics.stats()` exists: a device that silently starts
/// dropping buffers does not crash, it crackles, and the counters are the only
/// way to notice before it becomes a stutter.
pub const Stats = struct {
    /// Voices the engine currently has playing.
    voices_active: u32 = 0,
    /// Peak simultaneous voices since boot: the number the M8 criterion is
    /// about (64), as opposed to the instantaneous one.
    voices_peak: u32 = 0,
    /// Buffer underruns reported by the device. Must be 0; anything else means
    /// the mix did not finish inside its period and the audio glitched.
    xruns: u64 = 0,
    /// Commands dropped because the queue was full. A budget, not a spill (§3.1):
    /// a full queue drops and reports rather than allocating in the frame.
    commands_dropped: u64 = 0,
    period_frames: u32 = 0,
    sample_rate: u32 = 0,
    channels: u16 = 0,

    /// Output latency in ms, derived from the period rather than measured:
    /// `period_frames / sample_rate` is what the device actually holds, and
    /// measuring it end to end would need a loopback this engine does not have.
    /// The M8 criterion is ≤ 20 ms and this is the honest number for it.
    pub fn latencyMs(self: Stats) f32 {
        if (self.sample_rate == 0) return 0;
        return @as(f32, @floatFromInt(self.period_frames)) /
            @as(f32, @floatFromInt(self.sample_rate)) * 1000.0;
    }
};

/// How to open the device. Plain data, so it is comparable and printable.
pub const DeviceDesc = struct {
    /// Requested output rate. The backend may negotiate; what it actually got
    /// comes back in `Stats`, and the mixer resamples against THAT, never
    /// against this.
    sample_rate: u32 = 48000,
    /// Frames per callback. Smaller is lower latency and more callback
    /// frequency, which means more chances to miss the deadline.
    period_frames: u32 = 480,
    /// 1 = mono, 2 = stereo. Stereo is the default because panning is the whole
    /// point of a 2D positional emitter.
    channels: u16 = 2,
};

/// The engine's mix entry point, handed to the backend at device creation.
///
/// Called from the device thread with `frames` frames to fill, interleaved f32.
/// It must not allocate, must not lock for long, and must not touch the
/// filesystem (spec §3.7 and §10). Everything it reads was prepared on the main
/// thread before it runs.
pub const MixCallback = *const fn (ctx: ?*anyopaque, out: [*]f32, frames: u32) void;

/// What a backend must provide.
///
/// Deliberately small. A table that grew to cover every feature of a device
/// would be a table only one backend could fill, which is the same coupling the
/// port exists to prevent.
pub const VTable = struct {
    /// Opens the device (or, for the null backend, does nothing) and wires
    /// `mix` as the render callback. Returns an opaque context, or null on
    /// failure — a machine with no audio device must degrade to silence and say
    /// so, not take the process down.
    createDevice: *const fn (desc: DeviceDesc, mix: MixCallback, mix_ctx: ?*anyopaque) ?*anyopaque,
    destroyDevice: *const fn (ctx: ?*anyopaque) void,
    /// Starts the callback. False when the device could not be started; the
    /// caller keeps running silent rather than exiting.
    startDevice: *const fn (ctx: ?*anyopaque) bool,
    stopDevice: *const fn (ctx: ?*anyopaque) void,
    stats: *const fn (ctx: ?*anyopaque) Stats,

    /// File in, PCM out. LOAD TIME ONLY: this is allowed to allocate and to do
    /// blocking I/O, because it is never called from the frame or from the
    /// device thread. That is the entire reason decoding is not done lazily on
    /// first play — `ma_sound_init_from_file` reads the file on first playback,
    /// which would be synchronous I/O inside the frame (§3.4 forbids it).
    decode: *const fn (
        allocator: std.mem.Allocator,
        path: []const u8,
        out_pcm: *Pcm,
    ) DecodeError!void,

    /// Opens a STREAMING decoder: a file read in chunks instead of decoded
    /// into one buffer. Opening touches the filesystem, so it is LOAD TIME
    /// only; the reads go through `streamRead`, which the MAIN thread calls
    /// ahead of the mixer (never the device thread — spec §3.4, §10).
    streamOpen: ?*const fn (path: []const u8, out: *StreamInfo) StreamError!?*anyopaque = null,
    /// Reads up to `frames` frames into `out` (interleaved f32, `channels`
    /// wide) and returns how many it produced. 0 = end of the source. Called
    /// only from the main thread, into a ring the device thread never touches
    /// while it is being filled.
    streamRead: ?*const fn (handle: ?*anyopaque, out: [*]f32, frames: u32) u32 = null,
    /// Repositions a stream to an absolute frame. False when the source cannot
    /// seek (then a loop restarts from 0 by reopening, which the bank does).
    streamSeek: ?*const fn (handle: ?*anyopaque, frame: u32) bool = null,
    streamClose: ?*const fn (handle: ?*anyopaque) void = null,

    /// Headless backends render by being driven explicitly instead of by a
    /// thread. The bench calls this; a real backend leaves it null.
    pump: ?*const fn (ctx: ?*anyopaque, frames: u32) void = null,
};

pub const DecodeError = error{
    /// The file does not exist, or cannot be opened.
    FileNotFound,
    /// The bytes are not a format this backend understands.
    UnsupportedFormat,
    /// Out of memory while allocating the PCM buffer.
    OutOfMemory,
};

/// What an opened stream reports about itself. `frames` is 0 when the length
/// cannot be known ahead of time (a live source); the mixer then treats the
/// sound as unbounded and relies on end-of-read instead of length.
pub const StreamInfo = struct {
    frames: u32 = 0,
    channels: u16 = 1,
    sample_rate: u32 = 44100,
};

pub const StreamError = error{
    FileNotFound,
    UnsupportedFormat,
    OutOfMemory,
};

/// The audio device, as the engine sees it: a context, a table, and a name.
///
/// `name` is what a log line prints, and it is the only way to tell from the
/// outside which backend answered — the same role `physics.World.name` plays.
pub const Device = struct {
    vtable: *const VTable,
    ctx: ?*anyopaque,
    name: []const u8,

    pub fn stats(self: Device) Stats {
        return self.vtable.stats(self.ctx);
    }

    pub fn start(self: Device) bool {
        return self.vtable.startDevice(self.ctx);
    }

    pub fn stop(self: Device) void {
        self.vtable.stopDevice(self.ctx);
    }

    /// Headless only: advance the mix by `frames` without a thread. Null for a
    /// real backend, where the device thread does this on its own schedule.
    pub fn pump(self: Device, frames: u32) void {
        if (self.vtable.pump) |p| p(self.ctx, frames);
    }

    pub fn deinit(self: Device) void {
        self.vtable.destroyDevice(self.ctx);
    }

    pub fn decode(
        self: Device,
        allocator: std.mem.Allocator,
        path: []const u8,
        out_pcm: *Pcm,
    ) DecodeError!void {
        return self.vtable.decode(allocator, path, out_pcm);
    }

    /// Opens a streaming decoder. `UnsupportedFormat` when the backend has no
    /// streaming support at all (the fake test backend), so the caller can fall
    /// back to a full decode instead of failing.
    pub fn streamOpen(self: Device, path: []const u8, out: *StreamInfo) StreamError!?*anyopaque {
        const f = self.vtable.streamOpen orelse return error.UnsupportedFormat;
        return f(path, out);
    }

    pub fn streamRead(self: Device, handle: ?*anyopaque, out: [*]f32, frames: u32) u32 {
        const f = self.vtable.streamRead orelse return 0;
        return f(handle, out, frames);
    }

    pub fn streamSeek(self: Device, handle: ?*anyopaque, frame: u32) bool {
        const f = self.vtable.streamSeek orelse return false;
        return f(handle, frame);
    }

    pub fn streamClose(self: Device, handle: ?*anyopaque) void {
        if (self.vtable.streamClose) |f| f(handle);
    }
};

// ── Tests ────────────────────────────────────────────────────────────────────

const testing = std.testing;

test "voice handles report their emptiness and survive a stale index" {
    try testing.expect(VoiceId.none.isNone());

    const real = VoiceId{ .index = 7, .generation = 3 };
    try testing.expect(!real.isNone());
    // The generation is what makes a recycled slot distinguishable; a handle
    // that only carried an index would silently address whoever moved in.
    try testing.expect(real.generation != VoiceId.none.generation);
}

test "latency is derived from the period, and says so when there is no device" {
    const silent = Stats{};
    try testing.expectEqual(@as(f32, 0), silent.latencyMs());

    // 480 frames at 48 kHz is 10 ms — inside the M8 criterion of 20 ms.
    const live = Stats{ .period_frames = 480, .sample_rate = 48000 };
    try testing.expectApproxEqAbs(@as(f32, 10.0), live.latencyMs(), 0.01);

    // The criterion, as a number a test can fail against.
    try testing.expect(live.latencyMs() <= 20.0);
}

test "a default device description is stereo at 48 kHz inside the latency budget" {
    const d = DeviceDesc{};
    try testing.expectEqual(@as(u16, 2), d.channels);
    const s = Stats{ .period_frames = d.period_frames, .sample_rate = d.sample_rate };
    try testing.expect(s.latencyMs() <= 20.0);
}

test "Pcm is empty exactly when it has nothing to mix" {
    try testing.expect((Pcm{}).isEmpty());
    const silence = [_]f32{0} ** 8;
    try testing.expect(!(Pcm{ .frames = 4, .channels = 2, .samples = &silence }).isEmpty());
}

test "a resident Pcm window covers the whole sound; a stream window does not" {
    const data = [_]f32{0} ** 8;
    const resident = Pcm{ .frames = 4, .channels = 2, .samples = &data };
    try testing.expectEqual(@as(u32, 4), resident.windowFrames());
    try testing.expect(!resident.streaming);

    // A window of 2 frames out of a 1000-frame sound, starting at frame 500.
    const win = Pcm{ .frames = 1000, .channels = 2, .samples = &data, .base_frame = 500, .streaming = true };
    try testing.expectEqual(@as(u32, 4), win.windowFrames());
    try testing.expectEqual(@as(u32, 1000), win.frames);
    try testing.expect(win.streaming);
}

