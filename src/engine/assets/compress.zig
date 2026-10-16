//! Per-entry compression for the `.pak` container (M6).
//!
//! ## Why deflate and not zstd
//!
//! `pack.zig` originally advertised zstd, but nothing vendored a zstd
//! *compressor* — only Zig's standard library ships codecs, and it ships
//! `flate` (deflate, in a raw/gzip/zlib container) as its only compressor.
//! Rather than link a second C dependency for a container that is written at
//! export time and read once at load, the `.pak` uses raw deflate. The method
//! is recorded per entry, so a future build that wants zstd adds a method
//! without touching the format's layout.
//!
//! Compression is an EXPORT concern, not a frame-path one (spec §3.5): it runs
//! at bake time and the bytes it produces are what the loader reads. It never
//! runs inside the game loop.

const std = @import("std");
const flate = std.compress.flate;

/// How an entry's payload is stored. The numeric values are the on-disk
/// encoding, so they are frozen.
pub const Method = enum(u8) {
    /// Payload is the raw bytes. `raw_size == stored_size`.
    store = 0,
    /// Payload is a raw deflate stream (no zlib/gzip wrapper). Inflate with
    /// `inflateAlloc` and the entry's `raw_size`.
    deflate = 1,
};

/// Effort dial. Named after the knobs people actually reach for, not the
/// library's, so the .pak writer can take one without leaking `flate.Options`.
pub const Level = enum {
    fastest,
    default,
    best,

    fn options(self: Level) flate.Compress.Options {
        return switch (self) {
            .fastest => .fastest,
            .default => .default,
            .best => .best,
        };
    }
};

/// An upper bound on the deflate output for `input_len` bytes.
///
/// Deflate's worst case is a stored block: 5 bytes of header per 65535-byte
/// block plus the input, plus one final empty block (the `raw` container adds
/// none). This over-reserves rather than under-reserves; the writer uses it to
/// size a single output buffer and then trims to the real length.
pub fn bound(input_len: usize) usize {
    const blocks = input_len / 0xFFFF + 1;
    return input_len + blocks * 5 + 5;
}

/// Compresses `input` into a fresh buffer the caller owns.
pub fn deflateAlloc(allocator: std.mem.Allocator, input: []const u8, level: Level) ![]u8 {
    // An empty input has a well-defined 2-byte empty deflate stream, but
    // `Compress.init` asserts an output buffer > 8 bytes, and the container
    // writer stores empty payloads uncompressed anyway. Say so here rather
    // than special-casing it in two places.
    if (input.len == 0) return allocator.alloc(u8, 0);

    var out: std.Io.Writer.Allocating = try .initCapacity(allocator, bound(input.len));
    defer out.deinit();

    // Deflate needs a 64 KiB history window; `Compress` documents that it is
    // passed in (rather than embedded) so a caller can reuse one across
    // entries. A per-call allocation is fine at bake time.
    const window = try allocator.alloc(u8, flate.max_window_len);
    defer allocator.free(window);

    var c = try flate.Compress.init(&out.writer, window, .raw, level.options());
    try c.writer.writeAll(input);
    try c.finish();
    try out.writer.flush();
    return out.toOwnedSlice();
}

/// Decompresses a raw deflate stream of `raw_size` bytes. The size is required
/// and must be exact: deflate carries no length, and a wrong size is a corrupt
/// entry, not a recoverable one.
///
/// Every decoder failure — a bad code, a truncated stream, a checksum-free
/// stream that ends early — collapses to `error.CorruptStream`. Callers do not
/// need flate's error set, and a `.pak` reader that branched on the difference
/// would be reading a distinction the format does not make.
pub fn inflateAlloc(allocator: std.mem.Allocator, input: []const u8, raw_size: usize) ![]u8 {
    if (raw_size == 0) return allocator.alloc(u8, 0);

    var in: std.Io.Reader = .fixed(input);
    const window = try allocator.alloc(u8, flate.max_window_len);
    defer allocator.free(window);

    var d = flate.Decompress.init(&in, .raw, window);
    const out = try allocator.alloc(u8, raw_size);
    errdefer allocator.free(out);
    // `readSliceAll` reads EXACTLY the buffer length or fails, which is the
    // check we want: a truncated stream must not produce a half-filled image.
    d.reader.readSliceAll(out) catch return error.CorruptStream;
    return out;
}

// ── Tests ────────────────────────────────────────────────────────────────────

const testing = std.testing;

test "deflate round-trips arbitrary bytes at every level" {
    var prng = std.Random.DefaultPrng.init(0xC0FFEE);
    const rand = prng.random();

    // A high-entropy block proves the codec is lossless on data it cannot
    // compress; a repetitive one proves it actually shrinks.
    var entropy: [4096]u8 = undefined;
    rand.bytes(&entropy);
    const repetitive = "the quick brown fox jumps over the lazy dog\n" ** 64;

    for ([_]Level{ .fastest, .default, .best }) |level| {
        for ([_][]const u8{ &entropy, repetitive }) |source| {
            const compressed = try deflateAlloc(testing.allocator, source, level);
            defer testing.allocator.free(compressed);

            const back = try inflateAlloc(testing.allocator, compressed, source.len);
            defer testing.allocator.free(back);
            try testing.expectEqualSlices(u8, source, back);
        }
    }
}

test "deflate shrinks repetitive data and empty input stays empty" {
    const repetitive = "ab" ** 512;
    const compressed = try deflateAlloc(testing.allocator, repetitive, .default);
    defer testing.allocator.free(compressed);
    try testing.expect(compressed.len < repetitive.len);

    const empty = try deflateAlloc(testing.allocator, "", .default);
    defer testing.allocator.free(empty);
    try testing.expectEqual(@as(usize, 0), empty.len);

    const back = try inflateAlloc(testing.allocator, empty, 0);
    defer testing.allocator.free(back);
    try testing.expectEqual(@as(usize, 0), back.len);
}

test "inflate of a truncated stream is an error, not a short buffer" {
    const source = "0123456789" ** 100;
    const compressed = try deflateAlloc(testing.allocator, source, .default);
    defer testing.allocator.free(compressed);
    // Asking for the right size against half a stream must fail rather than
    // hand back a buffer with uninitialised tail bytes.
    const half = compressed[0 .. compressed.len / 2];
    try testing.expectError(error.CorruptStream, inflateAlloc(testing.allocator, half, source.len));
}
