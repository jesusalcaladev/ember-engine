//! Audio asset decoding (M6): WAV to PCM, and a structural probe for OGG.
//!
//! ## Why this does not touch `audio`
//!
//! The audio engine's bank (`engine.audio.Bank`) owns decoded PCM and is the
//! one place it lives (spec §5: one owner per sound's bytes). This module does
//! NOT own any PCM — it *decodes a file's bytes into a caller-owned buffer* so
//! the importer can inspect it at bake time (sample rate, channels, frames) and
//! the runtime can hand the PCM to the bank. That keeps `assets` free of a
//! dependency on `audio`, which the module graph needs: `audio` is built above
//! `assets`, and a cycle would not compile — the draft's `@import("audio")`
//! here was a latent build break, not a working bridge.
//!
//! ## What is real and what is delegated
//!
//! - **WAV**: parsed here, in full, for the two formats games actually import
//!   (8-bit unsigned and 16-bit signed PCM), including chunk walking so a WAV
//!   with a `LIST`/`fact` chunk before `data` still decodes. That chunk walk is
//!   the fix for the draft, which assumed `data` began at byte 44.
//! - **OGG**: *probed*, not decoded. The Vorbis identification header is parsed
//!   for channel count and sample rate (so the importer can report them), but
//!   the samples come from miniaudio at load time, which is the only decoder
//!   this engine links. `decodeOgg` is deliberately absent rather than stubbed.

const std = @import("std");

pub const AudioError = error{
    OutOfMemory,
    /// Not RIFF/WAVE (or not an Ogg stream) at all.
    NotAudio,
    /// A recognised container this module cannot turn into PCM (e.g. a WAV with
    /// a codec other than PCM, or an Ogg that is not Vorbis).
    UnsupportedFormat,
    /// A header claims more bytes than the file contains, or a chunk runs past
    /// the end.
    Truncated,
    /// The Vorbis header parsed, but there is no identifiable packet to read.
    InvalidOgg,
};

pub const Format = enum { wav, ogg };

/// What the importer records about an audio file without decoding it to PCM.
pub const AudioInfo = struct {
    format: Format,
    sample_rate: u32,
    channels: u16,
    frame_count: usize,

    pub fn durationSeconds(self: AudioInfo) f32 {
        if (self.sample_rate == 0) return 0;
        return @as(f32, @floatFromInt(self.frame_count)) / @as(f32, @floatFromInt(self.sample_rate));
    }
};

/// Interleaved i16 samples, `frame_count * channels` long. Owned by the caller.
pub const DecodedAudio = struct {
    pcm: []i16,
    sample_rate: u32,
    channels: u16,
    frame_count: usize,

    pub fn deinit(self: *DecodedAudio, allocator: std.mem.Allocator) void {
        allocator.free(self.pcm);
        self.* = undefined;
    }
};

/// True when the bytes begin with a RIFF/WAVE or an OggS container marker.
pub fn sniff(bytes: []const u8) ?Format {
    if (bytes.len >= 12 and std.mem.eql(u8, bytes[0..4], "RIFF") and std.mem.eql(u8, bytes[8..12], "WAVE")) {
        return .wav;
    }
    if (bytes.len >= 4 and std.mem.eql(u8, bytes[0..4], "OggS")) return .ogg;
    return null;
}

/// Reports format, channels, sample rate and frame count without keeping PCM.
/// For WAV this decodes and discards; for OGG it reads the Vorbis header.
pub fn probe(allocator: std.mem.Allocator, bytes: []const u8) AudioError!AudioInfo {
    const format = sniff(bytes) orelse return error.NotAudio;
    switch (format) {
        .wav => {
            var decoded = try decodeWavAlloc(allocator, bytes);
            defer decoded.deinit(allocator);
            return .{
                .format = .wav,
                .sample_rate = decoded.sample_rate,
                .channels = decoded.channels,
                .frame_count = decoded.frame_count,
            };
        },
        .ogg => return probeOgg(bytes),
    }
}

/// Decodes 8- or 16-bit PCM WAV into interleaved i16.
pub fn decodeWavAlloc(allocator: std.mem.Allocator, bytes: []const u8) AudioError!DecodedAudio {
    if (bytes.len < 12 or !std.mem.eql(u8, bytes[0..4], "RIFF") or !std.mem.eql(u8, bytes[8..12], "WAVE")) {
        return error.NotAudio;
    }

    var fmt: ?WavFormat = null;
    var data: ?[]const u8 = null;

    // Walk the chunk list. Each chunk is [id 4][size u32][payload][pad to even].
    var pos: usize = 12;
    while (pos + 8 <= bytes.len) {
        const id = bytes[pos..][0..4];
        const size = std.mem.readInt(u32, bytes[pos + 4 ..][0..4], .little);
        const body_start = pos + 8;
        const body_end = body_start + size;
        if (body_end > bytes.len) return error.Truncated; // padded byte is optional at EOF

        if (std.mem.eql(u8, id, "fmt ")) {
            fmt = try parseWavFormat(bytes[body_start..body_end]);
        } else if (std.mem.eql(u8, id, "data")) {
            data = bytes[body_start..body_end];
            // `data` is what we came for; stop once both chunks are seen.
            if (fmt != null) break;
        }

        pos = body_end + (size & 1); // chunks are word-aligned
    }

    const f = fmt orelse return error.Truncated;
    const samples = data orelse return error.Truncated;
    if (f.channels == 0) return error.UnsupportedFormat;

    const bytes_per_sample = f.bits_per_sample / 8;
    if (bytes_per_sample == 0) return error.UnsupportedFormat;
    const frame_bytes = bytes_per_sample * f.channels;
    const frame_count = samples.len / frame_bytes;
    const sample_count = frame_count * f.channels;

    const pcm = try allocator.alloc(i16, sample_count);
    errdefer allocator.free(pcm);

    switch (f.bits_per_sample) {
        8 => {
            // 8-bit WAV is unsigned, centred at 128.
            for (pcm, 0..) |*out, i| {
                out.* = (@as(i16, samples[i]) - 128) << 8;
            }
        },
        16 => {
            for (pcm, 0..) |*out, i| {
                out.* = std.mem.readInt(i16, samples[i * 2 ..][0..2], .little);
            }
        },
        else => return error.UnsupportedFormat,
    }

    return .{
        .pcm = pcm,
        .sample_rate = f.sample_rate,
        .channels = f.channels,
        .frame_count = frame_count,
    };
}

const WavFormat = struct {
    channels: u16,
    sample_rate: u32,
    bits_per_sample: u16,
};

fn parseWavFormat(body: []const u8) AudioError!WavFormat {
    if (body.len < 16) return error.Truncated;
    const audio_format = std.mem.readInt(u16, body[0..2], .little);
    // 0xFFFE is WAVE_FORMAT_EXTENSIBLE; its sub-format lives in the extension.
    // We accept it only when the extension names PCM (1).
    if (audio_format == 0xFFFE) {
        if (body.len < 40) return error.Truncated;
        const sub = std.mem.readInt(u16, body[24..26], .little);
        if (sub != 1) return error.UnsupportedFormat;
    } else if (audio_format != 1) {
        return error.UnsupportedFormat;
    }
    return .{
        .channels = std.mem.readInt(u16, body[2..4], .little),
        .sample_rate = std.mem.readInt(u32, body[4..8], .little),
        .bits_per_sample = std.mem.readInt(u16, body[14..16], .little),
    };
}

/// Reads the Vorbis identification header out of an Ogg page. OGG decoding
/// itself is miniaudio's job; this only answers "is this Ogg Vorbis, and how
/// many channels at what rate".
fn probeOgg(bytes: []const u8) AudioError!AudioInfo {
    // Page header: "OggS"(4) version(1) flags(1) granule(8) serial(4)
    // seq(4) crc(4) segments(1) then the segment table, then packet data.
    if (bytes.len < 27 + 1 + 7) return error.InvalidOgg;
    if (!std.mem.eql(u8, bytes[0..4], "OggS")) return error.NotAudio;
    if (bytes[4] != 0) return error.UnsupportedFormat;

    const segment_count = bytes[26];
    const table_start = 27;
    if (table_start + segment_count > bytes.len) return error.Truncated;
    const packet_start = table_start + segment_count;
    // Lacing values sum to the first packet's length.
    var packet_len: usize = 0;
    for (bytes[table_start .. table_start + segment_count]) |lacing| packet_len += lacing;
    if (packet_start + packet_len > bytes.len) return error.Truncated;

    const packet = bytes[packet_start .. packet_start + packet_len];
    // Identification packet: 0x01 "vorbis" version(4) channels(1) rate(4) ...
    if (packet.len < 30) return error.InvalidOgg;
    if (packet[0] != 0x01 or !std.mem.eql(u8, packet[1..7], "vorbis")) {
        return error.UnsupportedFormat;
    }
    const channels = packet[11];
    const sample_rate = std.mem.readInt(u32, packet[12..16], .little);
    if (channels == 0 or sample_rate == 0) return error.InvalidOgg;

    return .{
        .format = .ogg,
        .sample_rate = sample_rate,
        .channels = channels,
        // Vorbis has no frame count until it is decoded; 0 means "unknown",
        // not "empty".
        .frame_count = 0,
    };
}

// ── Tests ────────────────────────────────────────────────────────────────────

const testing = std.testing;

/// Builds a minimal but valid PCM WAV with the requested format.
fn makeWav(
    buf: []u8,
    sample_rate: u32,
    channels: u16,
    bits: u16,
    frames: usize,
    extra_chunk: bool,
) usize {
    const frame_bytes = @as(usize, bits / 8) * channels;
    const data_len = frame_bytes * frames;
    var pos: usize = 0;

    const put = struct {
        fn bytes(dst: []u8, at: *usize, src: []const u8) void {
            @memcpy(dst[at.* .. at.* + src.len], src);
            at.* += src.len;
        }
        fn u32le(dst: []u8, at: *usize, v: u32) void {
            std.mem.writeInt(u32, dst[at.* .. at.* + 4][0..4], v, .little);
            at.* += 4;
        }
        fn u16le(dst: []u8, at: *usize, v: u16) void {
            std.mem.writeInt(u16, dst[at.* .. at.* + 2][0..2], v, .little);
            at.* += 2;
        }
    };

    put.bytes(buf, &pos, "RIFF");
    put.u32le(buf, &pos, @intCast(36 + data_len));
    put.bytes(buf, &pos, "WAVE");

    if (extra_chunk) {
        // A junk chunk BEFORE fmt/data, to prove the walk skips it.
        put.bytes(buf, &pos, "JUNK");
        put.u32le(buf, &pos, 2);
        put.bytes(buf, &pos, "..");
    }

    put.bytes(buf, &pos, "fmt ");
    put.u32le(buf, &pos, 16);
    put.u16le(buf, &pos, 1); // PCM
    put.u16le(buf, &pos, channels);
    put.u32le(buf, &pos, sample_rate);
    put.u32le(buf, &pos, @intCast(sample_rate * frame_bytes));
    put.u16le(buf, &pos, @intCast(frame_bytes));
    put.u16le(buf, &pos, bits);

    put.bytes(buf, &pos, "data");
    put.u32le(buf, &pos, @intCast(data_len));
    return pos; // total header length; caller fills the payload after
}

test "a 16-bit stereo WAV decodes to the right frame count" {
    var buf: [4096]u8 = undefined;
    const header = makeWav(&buf, 44100, 2, 16, 100, false);
    // Fill 100 frames of known samples.
    var i: usize = 0;
    while (i < 100 * 2) : (i += 1) {
        std.mem.writeInt(i16, buf[header + i * 2 ..][0..2], @intCast(i), .little);
    }

    var decoded = try decodeWavAlloc(testing.allocator, buf[0 .. header + 100 * 2 * 2]);
    defer decoded.deinit(testing.allocator);

    try testing.expectEqual(@as(u32, 44100), decoded.sample_rate);
    try testing.expectEqual(@as(u16, 2), decoded.channels);
    try testing.expectEqual(@as(usize, 100), decoded.frame_count);
    try testing.expectEqual(@as(i16, 0), decoded.pcm[0]);
    try testing.expectEqual(@as(i16, 199), decoded.pcm[199]);
}

test "a JUNK chunk before fmt does not throw the decode off" {
    var buf: [4096]u8 = undefined;
    const header = makeWav(&buf, 22050, 1, 16, 8, true);
    const decoded = try decodeWavAlloc(testing.allocator, buf[0 .. header + 8 * 2]);
    defer testing.allocator.free(decoded.pcm);
    try testing.expectEqual(@as(usize, 8), decoded.frame_count);
    try testing.expectEqual(@as(u32, 22050), decoded.sample_rate);
}

test "an 8-bit WAV is centred at 128" {
    var buf: [512]u8 = undefined;
    const header = makeWav(&buf, 8000, 1, 8, 4, false);
    buf[header + 0] = 128; // silence
    buf[header + 1] = 255; // full positive
    buf[header + 2] = 0; // full negative
    buf[header + 3] = 128;
    const decoded = try decodeWavAlloc(testing.allocator, buf[0 .. header + 4]);
    defer testing.allocator.free(decoded.pcm);
    try testing.expectEqual(@as(i16, 0), decoded.pcm[0]);
    try testing.expectEqual(@as(i16, 127 << 8), decoded.pcm[1]);
    try testing.expectEqual(@as(i16, -128 << 8), decoded.pcm[2]);
}

test "non-audio bytes are refused, and probe reports the container" {
    try testing.expect(sniff("not audio at all") == null);
    try testing.expectError(error.NotAudio, probe(testing.allocator, "hello there, not a sound"));

    var buf: [512]u8 = undefined;
    const header = makeWav(&buf, 48000, 2, 16, 32, false);
    const info = try probe(testing.allocator, buf[0 .. header + 32 * 2 * 2]);
    try testing.expectEqual(Format.wav, info.format);
    try testing.expectEqual(@as(u32, 48000), info.sample_rate);
    try testing.expectEqual(@as(u16, 2), info.channels);
    try testing.expect(info.durationSeconds() >= 0);
}

test "a truncated WAV is an error, not a partial decode" {
    var buf: [1024]u8 = undefined;
    const header = makeWav(&buf, 44100, 1, 16, 50, false);
    // Cut the payload in half: the data chunk's declared size now runs past EOF.
    try testing.expectError(error.Truncated, decodeWavAlloc(testing.allocator, buf[0 .. header + 10]));
}
