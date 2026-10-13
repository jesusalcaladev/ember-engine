// Audio asset support using miniaudio.
// Loads .wav, .ogg, .mp3 files into the sound bank format.

const std = @import("std");

// Import miniaudio functions
const ma = @cImport({
    @cInclude("miniaudio.h");
});

/// Decoded sound owned by the asset manager.
pub const DecodedSound = struct {
    frames: u32,
    channels: u16,
    sampleRate: u32,
    samples: []f32,

    pub fn isEmpty(self: *const DecodedSound) bool {
        return self.frames == 0 or self.samples.len == 0;
    }
};

/// Audio payload owned by the asset manager.
pub const AudioPayload = struct {
    sound: DecodedSound,
    path: [256]u8,
};

/// Load an audio file using miniaudio.
pub fn load(allocator: std.mem.Allocator, path: []const u8) !AudioPayload {
    var decoder: ma.ma_decoder = undefined;

    // Initialize decoder from file
    const result = ma.ma_decoder_init_file(path.ptr, null, &decoder);
    if (result != ma.MA_SUCCESS) {
        return error.FileNotFound;
    }
    defer ma.ma_decoder_uninit(&decoder);

    // Get the output format info
    const channels = decoder.outputChannels;
    const sampleRate = decoder.outputSampleRate;
    _ = decoder.outputFormat;

    // Get total length in frames
    var lengthFrames: ma.ma_uint64 = 0;
    const lengthResult = ma.ma_decoder_get_length_in_pcm_frames(&decoder, &lengthFrames);
    if (lengthResult != ma.MA_SUCCESS) {
        // Length unknown - we'll need to read all frames
        lengthFrames = 0;
    }

    // Calculate total samples needed
    const framesPerChannel: u64 = if (lengthFrames > 0) lengthFrames else 65536; // fallback buffer
    const totalSamples: usize = @intCast(framesPerChannel * channels);

    // Allocate samples buffer
    var samples: []f32 = try allocator.alloc(f32, totalSamples);
    defer if (lengthResult != ma.MA_SUCCESS) allocator.free(samples); // free on error

    // Read all frames
    var framesRead: ma.ma_uint64 = 0;
    const readResult = ma.ma_decoder_read_pcm_frames(&decoder, samples.ptr, framesPerChannel, &framesRead);

    if (readResult != ma.MA_SUCCESS and readResult != ma.MA_AT_END) {
        allocator.free(samples);
        return error.UnsupportedFormat;
    }

    const actualFrames: u32 = @intCast(framesRead);
    const actualSamples: usize = @intCast(framesRead * channels);

    // Resize to actual size if we over-allocated
    if (actualSamples < totalSamples) {
        samples = samples[0..actualSamples];
    }

    // Copy path
    const p: [256]u8 = std.mem.zeroes([256]u8);
    std.mem.copy(path, &p);

    return .{
        .sound = .{
            .frames = actualFrames,
            .channels = @intCast(channels),
            .sampleRate = @intCast(sampleRate),
            .samples = samples,
        },
        .path = p,
    };
}

pub fn fileExtension(path: []const u8) ?[]const u8 {
    var i: isize = path.len - 1;
    while (i >= 0 and path[i] != '/' and path[i] != '\\') |c| {
        if (c == '.') return path[i + 1 ..];
        i -= 1;
    }
    return null;
}