//! Audio Asset Handling — decoded PCM lives in audio.Bank, not AssetManager.
//! This module bridges the VFS/Registry with the audio backend.

const std = @import("std");
const Audio = @import("audio");
const VFS = @import("vfs.zig").VFS;
const AssetRegistry = @import("registry.zig").AssetRegistry;

pub const AudioError = error{
    FileNotFound,
    UnsupportedFormat,
    DecodeFailed,
    OutOfMemory,
};

/// Audio asset metadata (stored in registry, payload in audio.Bank).
pub const AudioAsset = struct {
    sample_rate: u32,
    channels: u16,
    frame_count: usize,
    duration_sec: f32,
    /// Handle into audio.Bank (voice_id / stream_id).
    bank_handle: u32,
};

/// Load audio from VFS into audio.Bank.
pub fn loadAudio(
    vfs: *VFS,
    audio_bank: *Audio.Bank,
    path: []const u8,
) AudioError!AudioAsset {
    const ext = fileExtension(path) orelse return AudioError.UnsupportedFormat;
    if (!isAudioExtension(ext)) return AudioError.UnsupportedFormat;

    const data = try vfs.readFile(path);
    defer vfs.allocator.free(data);

    // Decode based on format
    const decoded = if (std.mem.eql(u8, ext, "wav") or std.mem.eql(u8, ext, "WAV"))
        try decodeWAV(data)
    else if (std.mem.eql(u8, ext, "ogg") or std.mem.eql(u8, ext, "OGG"))
        try decodeOGG(data)
    else
        return AudioError.UnsupportedFormat;

    // Add to audio bank
    const handle = try audio_bank.addSound(decoded.pcm, decoded.sample_rate, decoded.channels);

    return AudioAsset{
        .sample_rate = decoded.sample_rate,
        .channels = decoded.channels,
        .frame_count = decoded.frame_count,
        .duration_sec = @as(f32, @floatFromInt(decoded.frame_count)) / @as(f32, decoded.sample_rate),
        .bank_handle = handle,
    };
}

const WAVHeader = packed struct {
    riff: [4]u8,
    file_size: u32,
    wave: [4]u8,
    fmt: [4]u8,
    fmt_size: u32,
    audio_format: u16,
    num_channels: u16,
    sample_rate: u32,
    byte_rate: u32,
    block_align: u16,
    bits_per_sample: u16,
};

const DecodedAudio = struct {
    pcm: []i16,
    sample_rate: u32,
    channels: u16,
    frame_count: usize,
};

fn decodeWAV(data: []u8) AudioError!DecodedAudio {
    if (data.len < @sizeOf(WAVHeader)) return AudioError.DecodeFailed;
    const header = std.mem.readStruct(WAVHeader, data, .little);
    if (!std.mem.eql(u8, &header.riff, "RIFF") or !std.mem.eql(u8, &header.wave, "WAVE")) {
        return AudioError.DecodeFailed;
    }
    if (header.audio_format != 1) return AudioError.DecodeFailed; // PCM only

    const pcm_data = data[@sizeOf(WAVHeader)..];
    const frame_count = pcm_data.len / (@as(usize, header.num_channels) * 2);
    var pcm = try std.heap.page_allocator.alloc(i16, frame_count * @as(usize, header.num_channels));
    // Convert u8 bytes to i16 samples (little-endian)
    for (pcm_data, 0..) |byte, i| {
        if (i % 2 == 0) {
            const sample = @as(i16, @intCast(byte)) | (@as(i16, @intCast(pcm_data[i + 1])) << 8);
            pcm[i / 2] = sample;
        }
    }

    return DecodedAudio{
        .pcm = pcm,
        .sample_rate = header.sample_rate,
        .channels = header.num_channels,
        .frame_count = frame_count,
    };
}

fn decodeOGG(_: []u8) AudioError!DecodedAudio {
    // OGG decoding via miniaudio (stub - real impl calls miniaudio_decode)
    return AudioError.DecodeFailed;
}

fn isAudioExtension(ext: []const u8) bool {
    return std.mem.eql(u8, ext, "wav") or std.mem.eql(u8, ext, "WAV") or
           std.mem.eql(u8, ext, "ogg") or std.mem.eql(u8, ext, "OGG");
}

fn fileExtension(path: []const u8) ?[]const u8 {
    var i: isize = @as(isize, @intCast(path.len)) - 1;
    while (i >= 0) : (i -= 1) {
        const c = path[@intCast(i)];
        if (c == '.') return path[@as(usize, @intCast(i)) + 1 ..];
        if (c == '/' or c == '\\') break;
    }
    return null;
}