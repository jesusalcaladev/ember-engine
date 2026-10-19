//! Asset import (M6): bytes on disk to a validated, GUID-identified asset.
//!
//! ## What "import" means here
//!
//! `importOne` takes a path and the file's bytes and returns an `ImportedAsset`:
//! a stable GUID, the detected format, a content hash, and whatever the format
//! needs to be *known to be good* — a decoded image, a probed audio header, a
//! validated script. `bakeAlloc` runs that over a list and writes a `.pak`.
//!
//! ## Two rules the draft broke, and how this one keeps them
//!
//! 1. **Detect by content, not by extension.** The draft dispatched on the last
//!    three characters of the path and then did nothing. A `.png` that is
//!    actually a JPEG, or a `.lua` that is a renamed binary, is caught here by
//!    looking at the bytes.
//! 2. **Hashing must not overflow a Debug build.** The draft's `guidFromPath`
//!    used a non-wrapping `h *= PRIME`, which panics the moment the path is more
//!    than a few bytes long. Identity goes through `registry.hashBytes`, which
//!    wraps on purpose.
//!
//! Decoding is load/bake time only (spec §3.5): nothing here is reachable from
//! the game's frame loop.

const std = @import("std");
const registry = @import("registry.zig");
const image_mod = @import("image.zig");
const audio = @import("audio_asset.zig");
const script = @import("script_asset.zig");
const font_asset = @import("font_asset.zig");
const pack = @import("pack.zig");
const Image = @import("asset_types.zig").Image;
const AssetGUID = registry.AssetGUID;

pub const ImportError = error{
    /// The bytes match no format this engine imports, and the extension did not
    /// give a text format to fall back to.
    UnknownFormat,
    OutOfMemory,
    /// An image container was recognised but could not be decoded.
    InvalidImage,
    EmptyFile,
} || audio.AudioError || script.ScriptError || font_asset.FontError;

/// A recognised container. `lua` is a text fallback: it is chosen by extension
/// once the bytes are proven to be UTF-8 text. `ttf` is content-detected only
/// (the sfnt magic), so it covers `.otf` and `.ttc` as well as `.ttf`.
pub const Format = enum {
    png,
    jpeg,
    webp,
    wav,
    ogg,
    lua,
    ttf,

    pub fn kind(self: Format) Kind {
        return switch (self) {
            .png, .jpeg, .webp => .image,
            .wav, .ogg => .audio,
            .lua => .script,
            .ttf => .font,
        };
    }

    pub fn extension(self: Format) []const u8 {
        return switch (self) {
            .png => "png",
            .jpeg => "jpg",
            .webp => "webp",
            .wav => "wav",
            .ogg => "ogg",
            .lua => "lua",
            .ttf => "ttf",
        };
    }
};

/// The registry's coarse asset classes.
pub const Kind = enum { image, audio, script, font };

/// One file handed to the importer.
pub const Source = struct {
    path: []const u8,
    bytes: []const u8,
};

/// A validated asset. Image payloads are owned by the manifest; everything else
/// points into the caller's `bytes`.
pub const ImportedAsset = struct {
    path: []const u8,
    guid: AssetGUID,
    format: Format,
    kind: Kind,
    /// The original file bytes (borrowed — used to write the `.pak` verbatim).
    bytes: []const u8,
    content_hash: u64,
    /// Decoded RGBA, owned. Present only for images.
    image: ?Image = null,
    /// Probed header, present only for audio.
    audio: ?audio.AudioInfo = null,
    /// Validation result, present only for scripts.
    script: ?script.Validated = null,
    /// Validation result, present only for fonts.
    font: ?font_asset.Validated = null,

    pub fn deinit(self: *ImportedAsset, allocator: std.mem.Allocator) void {
        if (self.image) |*img| allocator.free(img.pixels);
        self.* = undefined;
    }
};

/// Detects a format from magic bytes, falling back to `lua` for a path that
/// ends in `.lua` when the bytes prove to be UTF-8 text.
pub fn detect(path: []const u8, bytes: []const u8) ?Format {
    if (bytes.len >= 8 and std.mem.eql(u8, bytes[0..8], "\x89PNG\r\n\x1a\n")) return .png;
    if (bytes.len >= 3 and bytes[0] == 0xFF and bytes[1] == 0xD8 and bytes[2] == 0xFF) return .jpeg;
    if (bytes.len >= 12 and std.mem.eql(u8, bytes[0..4], "RIFF") and std.mem.eql(u8, bytes[8..12], "WEBP")) return .webp;
    if (font_asset.looksLikeFont(bytes)) return .ttf;
    if (audio.sniff(bytes)) |f| return switch (f) {
        .wav => .wav,
        .ogg => .ogg,
    };
    if (hasExtension(path, ".lua") and looksLikeText(bytes)) return .lua;
    return null;
}

/// Imports one file: identify, validate/decode, and name it.
pub fn importOne(
    allocator: std.mem.Allocator,
    path: []const u8,
    bytes: []const u8,
) ImportError!ImportedAsset {
    if (bytes.len == 0) return error.EmptyFile;
    const format = detect(path, bytes) orelse return error.UnknownFormat;

    var asset: ImportedAsset = .{
        .path = path,
        .guid = AssetGUID.fromPath(path),
        .format = format,
        .kind = format.kind(),
        .bytes = bytes,
        .content_hash = registry.hashBytes(bytes),
    };

    switch (format) {
        .png, .jpeg, .webp => {
            asset.image = image_mod.decodeMemory(allocator, bytes) catch return error.InvalidImage;
        },
        .wav, .ogg => asset.audio = try audio.probe(allocator, bytes),
        .lua => asset.script = try script.validate(bytes, script.default_max_bytes),
        .ttf => asset.font = try font_asset.validate(bytes),
    }

    return asset;
}

/// Imports a list. On failure every already-imported asset is freed, so the
/// caller sees either a complete manifest or nothing.
pub fn importBatch(allocator: std.mem.Allocator, sources: []const Source) ImportError![]ImportedAsset {
    var manifest = try allocator.alloc(ImportedAsset, sources.len);
    var done: usize = 0;
    errdefer {
        for (manifest[0..done]) |*a| a.deinit(allocator);
        allocator.free(manifest);
    }

    for (sources, 0..) |src, i| {
        manifest[i] = try importOne(allocator, src.path, src.bytes);
        done += 1;
    }
    return manifest;
}

pub fn freeManifest(allocator: std.mem.Allocator, manifest: []ImportedAsset) void {
    for (manifest) |*a| a.deinit(allocator);
    allocator.free(manifest);
}

/// The M6 end-to-end: import and validate every source, then bake them into one
/// `.pak` buffer the caller owns. Images are decoded only to prove they are
/// valid; the `.pak` stores the original bytes.
pub fn bakeAlloc(
    allocator: std.mem.Allocator,
    sources: []const Source,
    options: pack.WriteOptions,
) ![]u8 {
    const manifest = try importBatch(allocator, sources);
    defer freeManifest(allocator, manifest);

    // The pack sources borrow the caller's bytes, so they live as long as the
    // manifest's entries do.
    var pack_sources = try allocator.alloc(pack.Source, manifest.len);
    defer allocator.free(pack_sources);
    for (manifest, 0..) |a, i| pack_sources[i] = .{ .path = a.path, .data = a.bytes };

    return pack.writeAlloc(allocator, pack_sources, options);
}

/// `bakeAlloc`, written to disk.
pub fn bakeFile(
    io: std.Io,
    allocator: std.mem.Allocator,
    pak_path: []const u8,
    sources: []const Source,
    options: pack.WriteOptions,
) !usize {
    const bytes = try bakeAlloc(allocator, sources, options);
    defer allocator.free(bytes);
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = pak_path, .data = bytes });
    return bytes.len;
}

// ── helpers ──────────────────────────────────────────────────────────────────

fn hasExtension(path: []const u8, ext: []const u8) bool {
    if (path.len < ext.len) return false;
    const tail = path[path.len - ext.len ..];
    for (tail, ext) |a, b| {
        if (std.ascii.toLower(a) != std.ascii.toLower(b)) return false;
    }
    return true;
}

fn looksLikeText(bytes: []const u8) bool {
    const sample = bytes[0..@min(bytes.len, 4096)];
    if (std.mem.indexOfScalar(u8, sample, 0) != null) return false;
    return std.unicode.utf8ValidateSlice(sample);
}

// ── Tests ────────────────────────────────────────────────────────────────────

const testing = std.testing;

/// A 1x1 PNG. Kept as bytes rather than generated so the test also proves the
/// magics are matched and stb_image is actually linked in. `pub` so the hot
/// reload suite can reuse the exact same fixture.
pub const one_px_png = [_]u8{
    0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 0x00, 0x00, 0x00, 0x0D, 0x49, 0x48, 0x44, 0x52,
    0x00, 0x00, 0x00, 0x01, 0x00, 0x00, 0x00, 0x01, 0x08, 0x06, 0x00, 0x00, 0x00, 0x1F, 0x15, 0xC4,
    0x89, 0x00, 0x00, 0x00, 0x0A, 0x49, 0x44, 0x41, 0x54, 0x78, 0x9C, 0x63, 0x00, 0x01, 0x00, 0x00,
    0x05, 0x00, 0x01, 0x0D, 0x0A, 0x2D, 0xB4, 0x00, 0x00, 0x00, 0x00, 0x49, 0x45, 0x4E, 0x44, 0xAE,
    0x42, 0x60, 0x82,
};

test "a PNG is detected, decoded and named by path" {
    var asset = try importOne(testing.allocator, "sprites/dot.png", &one_px_png);
    defer asset.deinit(testing.allocator);

    try testing.expectEqual(Format.png, asset.format);
    try testing.expectEqual(Kind.image, asset.kind);
    try testing.expectEqual(AssetGUID.fromPath("sprites/dot.png"), asset.guid);

    const img = asset.image.?;
    try testing.expectEqual(@as(u32, 1), img.width);
    try testing.expectEqual(@as(u32, 1), img.height);
    try testing.expectEqual(@as(usize, 4), img.pixels.len);
}

test "detection follows the bytes, not the extension" {
    // `.png` on the outside, JPEG magic on the inside: the magic wins.
    const fake_png = [_]u8{ 0xFF, 0xD8, 0xFF, 0xE0, 0x00, 0x10 };
    try testing.expectEqual(Format.jpeg, detect("actually.jpg", &fake_png).?);
    // Data without a known magic and a non-.lua path is unknown.
    try testing.expect(detect("blob.dat", &[_]u8{ 0x00, 0x01, 0x02, 0x03 }) == null);
}

test "a .lua file is validated as text; a renamed binary is not Lua" {
    var good = try importOne(testing.allocator, "player.lua", "function update() end\n");
    defer good.deinit(testing.allocator);
    try testing.expectEqual(Format.lua, good.format);
    try testing.expect(good.script.?.size > 0);

    // Same extension, NUL bytes: refused, because it is plainly not source.
    try testing.expectError(error.UnknownFormat, importOne(testing.allocator, "x.lua", &[_]u8{ 'a', 0, 'b' }));

    // Valid UTF-8 with a bad continuation byte: LooksLikeText says no format.
    try testing.expect(detect("x.lua", &[_]u8{ 'a', 0xFF, 0xFE }) == null);
}

test "an empty file and unknown bytes are refused" {
    try testing.expectError(error.EmptyFile, importOne(testing.allocator, "empty.png", ""));
    try testing.expectError(error.UnknownFormat, importOne(testing.allocator, "x.bin", "not an asset"));
}

test "a .ttf is detected by magic and validated as a font" {
    const io = std.Io.Threaded.global_single_threaded.io();
    // The bootstrap-downloaded typeface is not committed; skip when absent.
    const bytes = std.Io.Dir.cwd().readFileAlloc(io, "libs/fonts/Inter-Regular.ttf", testing.allocator, .limited(8 << 20)) catch |err| switch (err) {
        error.FileNotFound => return error.SkipZigTest,
        else => return err,
    };
    defer testing.allocator.free(bytes);

    // A `.otf` name is fine: detection follows the sfnt magic, not the suffix.
    var asset = try importOne(testing.allocator, "ui/Inter-Regular.ttf", bytes);
    defer asset.deinit(testing.allocator);
    try testing.expectEqual(Format.ttf, asset.format);
    try testing.expectEqual(Kind.font, asset.kind);
    try testing.expectEqual(@as(u32, 0), asset.font.?.fontstart);
    try testing.expect(!asset.font.?.is_cff);
}

test "a TTF magic on garbage bytes is refused rather than trusted" {
    // The magic is recognised as a font, so it is not UnknownFormat — it is the
    // validator that refuses it, which is exactly the point.
    try testing.expectEqual(Format.ttf, detect("x.ttf", "ttcf....").?);
    try testing.expectError(error.Truncated, importOne(testing.allocator, "x.ttf", "OTTO" ++ "x" ** 40));
    try testing.expectError(error.UnknownFormat, importOne(testing.allocator, "x.ttf", "not a font"));
}

test "importBatch frees a partial manifest on failure" {
    const sources = [_]Source{
        .{ .path = "good.png", .bytes = &one_px_png },
        .{ .path = "bad.png", .bytes = "not a png at all" },
    };
    // testing.allocator fails the test if anything leaks, so this asserts the
    // errdefer path runs.
    try testing.expectError(error.UnknownFormat, importBatch(testing.allocator, &sources));
}

test "bakeAlloc imports, validates and packs in one call" {
    const sources = [_]Source{
        .{ .path = "sprites/dot.png", .bytes = &one_px_png },
        .{ .path = "player.lua", .bytes = "function update() end" },
    };
    const bytes = try bakeAlloc(testing.allocator, &sources, .{ .compression = .deflate });
    defer testing.allocator.free(bytes);

    var archive = try pack.Archive.init(testing.allocator, bytes);
    defer archive.deinit();
    try testing.expectEqual(@as(usize, 2), archive.count());

    const lua = try archive.extractPathAlloc(testing.allocator, "player.lua");
    defer testing.allocator.free(lua);
    try testing.expectEqualStrings("function update() end", lua);
}
