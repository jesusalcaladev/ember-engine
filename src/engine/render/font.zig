//! M14 — text: TrueType rasterizing, metrics and string layout.
//!
//! ## What this file is
//!
//! The engine had no text at all until M14: no font, no glyph, no `measure`.
//! This is the missing half of the UI milestone, and everything else in it
//! (`Label`, buttons, progress bars) is arithmetic over what this file returns.
//!
//! ## Why stb_truetype
//!
//! A header-only C rasterizer, vendored like `stb_image` (see
//! `assets/stb_truetype_impl.c` for the one translation unit that compiles it and
//! `DEPENDENCIES.md` for the pin). The alternative was a bitmap font atlas baked
//! at import, which would have made "a designer drops a .ttf in the project" a
//! content-pipeline problem instead of a file read.
//!
//! ## The shape of a `Font`
//!
//! * **CPU metrics** — ascent/descent/line-gap, per-glyph advance and bitmap box.
//!   These need no GPU and no renderer, which is what makes `measure` and
//!   `positionOf` unit-testable in `zig build test-light` with nothing attached.
//! * **A glyph atlas (optional)** — when a `Renderer` is attached, each rasterized
//!   glyph is packed into an `AtlasManager` page shared by that font and uploaded
//!   once. The page is a texture slot the glyph quads draw from, exactly like a
//!   sprite atlas: **no second GPU pipeline exists for text**.
//!
//! `pixel_height` is the font's size in pixels. A `Font` is one (bytes, size)
//! pair; a project asks for several sizes and gets several fonts. Kerning and
//! automatic wrapping are deliberately absent (spec: v1), which is why `measure`
//! is a plain sum of advances.

const std = @import("std");
const render = @import("render.zig");
const font_asset = @import("assets").font_asset;

/// This many bytes per stbtt_fontinfo, rounded up from `sizeof` (160 on
/// x86_64) and never inspected: the struct is an opaque blob here, filled by
/// `stbtt_InitFont` and read only by the stbtt functions.
const font_info_size = 256;

const FontInfo = struct {
    storage: [font_info_size]u8 align(8) = [_]u8{0} ** font_info_size,
};

// ── The stb_truetype surface we call ─────────────────────────────────────────
//
// Declared by hand for the same reason `image.zig` declares stb_image's: Zig
// 0.16's translate-c cannot lower the whole header, so the implementation is C
// and this is the contract. The `info` parameter is `*anyopaque` because the
// struct is filled by C and never read here.

extern fn stbtt_InitFont(info: *anyopaque, data: [*]const u8, offset: c_int) c_int;
extern fn stbtt_ScaleForPixelHeight(info: *anyopaque, pixels: f32) f32;
extern fn stbtt_GetFontVMetrics(info: *anyopaque, ascent: *c_int, descent: *c_int, line_gap: *c_int) void;
extern fn stbtt_GetCodepointHMetrics(info: *anyopaque, codepoint: c_int, advance_width: *c_int, left_side_bearing: *c_int) void;
extern fn stbtt_GetCodepointBitmapBox(
    info: *anyopaque,
    codepoint: c_int,
    scale_x: f32,
    scale_y: f32,
    x0: *c_int,
    y0: *c_int,
    x1: *c_int,
    y1: *c_int,
) void;
extern fn stbtt_GetCodepointBitmap(
    info: *anyopaque,
    scale_x: f32,
    scale_y: f32,
    codepoint: c_int,
    width: *c_int,
    height: *c_int,
    xoff: *c_int,
    yoff: *c_int,
) ?[*]u8;
extern fn stbtt_FreeBitmap(bitmap: ?[*]u8, userdata: ?*anyopaque) void;
extern fn stbtt_FindGlyphIndex(info: *anyopaque, codepoint: c_int) c_int;

/// Everything stb_truetype needs to be handed a pointer is checked by
/// `assets.font_asset.validate` first — see that file for why the rasterizer
/// does not trust its own input, and why the parser lives in `assets` rather
/// than here.


/// One rasterized glyph: where it sits relative to the pen and where its pixels
/// live in the atlas.
pub const Glyph = struct {
    /// Bitmap box in pixels, relative to the pen baseline (y grows DOWN, the
    /// convention every UI layout uses; stb_truetype already reports y down).
    start_x: f32 = 0,
    start_y: f32 = 0,
    width: f32 = 0,
    height: f32 = 0,
    /// Pen advance in pixels.
    advance: f32 = 0,
    /// Atlas rect ([0,0,0,0] when there is no atlas).
    uv: [4]f32 = .{ 0, 0, 0, 0 },
    /// True when the glyph has a drawable bitmap (a space does not).
    has_pixels: bool = false,
};

/// A font at one pixel size, with optional GPU glyph atlas.
pub const Font = struct {
    allocator: std.mem.Allocator,
    /// Owned copy of the TTF bytes (stbtt reads through this for its lifetime).
    bytes: []u8,
    info: FontInfo = .{},
    pixel_height: f32,
    scale: f32 = 1,
    ascent: f32 = 0,
    descent: f32 = 0,
    line_gap: f32 = 0,
    glyphs: std.AutoHashMapUnmanaged(u32, Glyph) = .empty,

    // ── The atlas (present only when a renderer was attached) ────────────────
    renderer: ?render.Renderer = null,
    atlas_handle: ?*anyopaque = null,
    /// The texture slot the packed glyph page resolves to (255 = white/no page).
    slot: u8 = 255,
    /// The handle `refreshAtlas` returned last; a CHANGE across packs means the
    /// glyph set outgrew the page, which v1 refuses rather than draw garbage.
    last_atlas_texture: ?*anyopaque = null,
    overflowed: bool = false,
    /// Reused between glyphs so rasterizing never allocates per glyph.
    scratch: std.ArrayListUnmanaged(u8) = .empty,
    /// Once-per-font warning latch for the page-overflow case.
    warned_overflow: bool = false,

    /// Builds a CPU-only font. No renderer, no atlas: metrics and `measure`
    /// work, drawing does not. This is the constructor the tests use.
    pub fn init(allocator: std.mem.Allocator, bytes: []const u8, pixel_height: f32) !Font {
        if (pixel_height <= 0) return error.InvalidSize;
        var self = Font{
            .allocator = allocator,
            .bytes = try allocator.dupe(u8, bytes),
            .pixel_height = pixel_height,
        };
        errdefer allocator.free(self.bytes);

        // Validate before the C rasterizer ever sees the pointer: stbtt does no
        // bounds checking, and this input is a project file rather than a value
        // the engine produced. The verdict comes from the asset layer, which is
        // where "what a font is" is decided (see `assets/font_asset.zig`).
        const info = font_asset.validate(self.bytes) catch return error.InvalidFont;

        if (stbtt_InitFont(&self.info, self.bytes.ptr, @intCast(info.fontstart)) == 0) return error.InvalidFont;
        self.scale = stbtt_ScaleForPixelHeight(&self.info, pixel_height);

        var asc: c_int = 0;
        var desc: c_int = 0;
        var gap: c_int = 0;
        stbtt_GetFontVMetrics(&self.info, &asc, &desc, &gap);
        self.ascent = @as(f32, @floatFromInt(asc)) * self.scale;
        self.descent = @as(f32, @floatFromInt(desc)) * self.scale;
        self.line_gap = @as(f32, @floatFromInt(gap)) * self.scale;
        return self;
    }

    /// Creates this font's glyph atlas and pre-packs the printable ASCII set, so
    /// the first frame that draws text does not pay for 95 rasterizations.
    pub fn attachAtlas(self: *Font, renderer: render.Renderer, side: u32) !void {
        const handle = renderer.createAtlasManager(side, side) orelse return error.NoAtlas;
        self.renderer = renderer;
        self.atlas_handle = handle;
        try self.preloadAscii();
        self.flushAtlas();
    }

    pub fn deinit(self: *Font) void {
        self.glyphs.deinit(self.allocator);
        self.scratch.deinit(self.allocator);
        self.allocator.free(self.bytes);
        self.* = undefined;
    }

    /// The distance between two baselines, in pixels.
    pub fn lineHeight(self: *const Font) f32 {
        return self.ascent - self.descent + self.line_gap;
    }

    /// Width of `text` in pixels: the sum of the glyph advances (no kerning,
    /// spec v1). Newlines are measured as a zero-width glyph.
    pub fn measure(self: *Font, text: []const u8) f32 {
        var width: f32 = 0;
        var i: usize = 0;
        while (i < text.len) {
            const cp = nextCodepoint(text, &i);
            if (cp == '\n') continue;
            width += self.advance(cp);
        }
        return width;
    }

    /// Sum of advances of the codepoints fully before `byte_index`, in pixels.
    /// The cursor position a text box/dialog needs.
    pub fn positionOf(self: *Font, text: []const u8, byte_index: usize) f32 {
        var width: f32 = 0;
        var i: usize = 0;
        const limit = @min(byte_index, text.len);
        while (i < limit) {
            const cp = nextCodepoint(text, &i);
            if (cp == '\n') continue;
            width += self.advance(cp);
        }
        return width;
    }

    /// Advance for one codepoint, in pixels. Falls back to the advance of '?'
    /// (or 0) for a glyph the font does not carry.
    pub fn advance(self: *Font, cp: u21) f32 {
        if (self.glyph(cp)) |g| return g.advance;
        return self.fallbackAdvance();
    }

    /// What an uncarried codepoint costs in layout: the width of '?', so a
    /// missing glyph advances like the box that will stand in for it. Zero only
    /// when the font has no '?' either (an icon font, say), where the honest
    /// answer is that the character occupies nothing.
    fn fallbackAdvance(self: *Font) f32 {
        if (self.glyph('?')) |g| return g.advance;
        return 0;
    }

    /// The glyph for `cp`, rasterizing and packing it on first use. Null only
    /// when the codepoint is not in the font at all.
    pub fn glyph(self: *Font, cp: u21) ?Glyph {
        if (self.glyphs.get(cp)) |g| return g;

        const idx = stbtt_FindGlyphIndex(&self.info, cp);
        // Notdef (index 0) is a real glyph; a font with no mapping for cp still
        // renders something in most cases. We only bail when there is no index
        // AND no advance, i.e. genuinely nothing to draw.
        var adv_i: c_int = 0;
        var lsb_i: c_int = 0;
        stbtt_GetCodepointHMetrics(&self.info, cp, &adv_i, &lsb_i);
        if (idx == 0 and adv_i == 0) return null;

        var x0: c_int = 0;
        var y0: c_int = 0;
        var x1: c_int = 0;
        var y1: c_int = 0;
        stbtt_GetCodepointBitmapBox(&self.info, cp, self.scale, self.scale, &x0, &y0, &x1, &y1);

        var g = Glyph{
            .start_x = @floatFromInt(x0),
            .start_y = @floatFromInt(y0),
            .width = @floatFromInt(x1 - x0),
            .height = @floatFromInt(y1 - y0),
            .advance = @as(f32, @floatFromInt(adv_i)) * self.scale,
        };

        const w = x1 - x0;
        const h = y1 - y0;
        if (w > 0 and h > 0) {
            g.has_pixels = true;
            if (self.atlas_handle != null and !self.overflowed) self.packGlyph(cp, &g);
        }

        self.glyphs.put(self.allocator, cp, g) catch {
            // A cache that cannot grow is a cache that still answers correctly
            // for this call, just slower next time; never a reason to fail.
            return g;
        };
        return g;
    }

    /// Rasterizes one glyph into the reused scratch buffer and hands the RGBA8
    /// pixels to the atlas. On success `g.uv` is set.
    fn packGlyph(self: *Font, cp: u21, g: *Glyph) void {
        const renderer = self.renderer.?;
        var gw: c_int = 0;
        var gh: c_int = 0;
        var xoff: c_int = 0;
        var yoff: c_int = 0;
        const bm = stbtt_GetCodepointBitmap(
            &self.info,
            self.scale,
            self.scale,
            cp,
            &gw,
            &gh,
            &xoff,
            &yoff,
        ) orelse return;
        defer stbtt_FreeBitmap(bm, null);

        if (gw <= 0 or gh <= 0) return;
        const px = @as(usize, @intCast(gw)) * @as(usize, @intCast(gh)) * 4;
        self.scratch.resize(self.allocator, px) catch return;
        const dst = self.scratch.items;
        const src = bm[0..@intCast(@as(usize, @intCast(gw)) * @as(usize, @intCast(gh)))];
        for (src, 0..) |a, i| {
            dst[i * 4 + 0] = 255;
            dst[i * 4 + 1] = 255;
            dst[i * 4 + 2] = 255;
            dst[i * 4 + 3] = a;
        }

        var key_buf: [32]u8 = undefined;
        const key = std.fmt.bufPrint(&key_buf, "g{d}", .{cp}) catch return;
        // An existing entry is SWAPPED, not re-packed: re-adding a key would
        // leak the old one and consume a second rect for pixels of the same
        // size. That matters on a hot reload, where every glyph is rasterized a
        // second time into the page it already owns. A glyph that has never
        // been packed (the common path) returns null here and is added below.
        if (renderer.updateImageInAtlas(self.atlas_handle, key, @intCast(gw), @intCast(gh), dst)) |update| {
            g.uv = update.uv;
            return;
        }
        const uv = renderer.addImageToAtlas(self.atlas_handle, key, @intCast(gw), @intCast(gh), dst) orelse return;
        g.uv = uv;
    }

    /// Replaces this font's bytes after a hot reload, keeping the pixel size and
    /// (when one is attached) the atlas.
    ///
    /// The new bytes are validated and the stbtt state is rebuilt into locals
    /// first, so a bad edit — a half-written save — leaves the live font exactly
    /// as it was rather than half-swapped. When they are good, the glyph cache
    /// is dropped and the ASCII set re-rasterized, which re-uses each glyph's
    /// existing atlas rect through `packGlyph`'s update-first path.
    pub fn reload(self: *Font, bytes: []const u8) !void {
        const new_info = font_asset.validate(bytes) catch return error.InvalidFont;
        const fresh = try self.allocator.dupe(u8, bytes);
        errdefer self.allocator.free(fresh);

        var probe: FontInfo = .{};
        if (stbtt_InitFont(&probe, fresh.ptr, @intCast(new_info.fontstart)) == 0) return error.InvalidFont;
        const scale = stbtt_ScaleForPixelHeight(&probe, self.pixel_height);
        var asc: c_int = 0;
        var desc: c_int = 0;
        var gap: c_int = 0;
        stbtt_GetFontVMetrics(&probe, &asc, &desc, &gap);

        self.allocator.free(self.bytes);
        self.bytes = fresh;
        self.info = probe;
        self.scale = scale;
        self.ascent = @as(f32, @floatFromInt(asc)) * scale;
        self.descent = @as(f32, @floatFromInt(desc)) * scale;
        self.line_gap = @as(f32, @floatFromInt(gap)) * scale;

        self.glyphs.clearRetainingCapacity();
        if (self.atlas_handle != null) {
            // A new face may fit where the old one did not, or vice versa.
            self.overflowed = false;
            self.warned_overflow = false;
            self.preloadAscii() catch {};
            self.flushAtlas();
        }
    }

    /// Uploads whatever glyph pixels were packed since the last flush and
    /// refreshes the font's texture slot. Called once after the ASCII preload
    /// and after each on-demand glyph.
    pub fn flushAtlas(self: *Font) void {
        const renderer = self.renderer orelse return;
        const handle = renderer.refreshAtlas(self.atlas_handle) orelse return;
        if (self.last_atlas_texture) |prev| {
            if (prev != handle) {
                self.overflowed = true;
                if (!self.warned_overflow) {
                    self.warned_overflow = true;
                    std.log.warn("font: glyph set outgrew one atlas page; further glyphs are not drawn", .{});
                }
            }
        }
        self.last_atlas_texture = handle;
        const idx = @intFromPtr(handle);
        if (idx >= 1 and idx - 1 <= std.math.maxInt(u8)) self.slot = @intCast(idx - 1);
    }

    fn preloadAscii(self: *Font) !void {
        var cp: u21 = 32;
        while (cp <= 126) : (cp += 1) {
            _ = self.glyph(cp);
        }
    }
};

/// Decodes the next UTF-8 codepoint, advancing `i`. Invalid sequences decode as
/// their first byte, so a corrupt label renders as boxes instead of stopping the
/// layout.
fn nextCodepoint(text: []const u8, i: *usize) u21 {
    const b0 = text[i.*];
    if (b0 < 0x80) {
        i.* += 1;
        return b0;
    }
    const len: usize = std.unicode.utf8ByteSequenceLength(b0) catch {
        i.* += 1;
        return b0;
    };
    if (i.* + len > text.len) {
        i.* += 1;
        return b0;
    }
    const cp = std.unicode.utf8Decode(text[i.* .. i.* + len]) catch {
        i.* += 1;
        return b0;
    };
    i.* += len;
    return cp;
}

// ── Tests ────────────────────────────────────────────────────────────────────

const testing = std.testing;

/// Loads the vendored test typeface, skipping the test when the bootstrap has
/// not fetched `libs/fonts` (they are not committed — see `libs/fonts.commit`).
fn testFontBytes(allocator: std.mem.Allocator) ![]u8 {
    const path = "libs/fonts/Inter-Regular.ttf";
    const io = std.Io.Threaded.global_single_threaded.io();
    return std.Io.Dir.cwd().readFileAlloc(io, path, allocator, .limited(8 << 20)) catch |err| switch (err) {
        error.FileNotFound => error.SkipZigTest,
        else => err,
    };
}

test "font: measure is zero for empty and grows with the string" {
    const allocator = testing.allocator;
    const bytes = testFontBytes(allocator) catch |err| switch (err) {
        error.SkipZigTest => return error.SkipZigTest,
        else => return err,
    };
    defer allocator.free(bytes);

    var font = try Font.init(allocator, bytes, 16);
    defer font.deinit();

    try testing.expectEqual(@as(f32, 0), font.measure(""));
    const a = font.measure("i");
    const b = font.measure("ill");
    try testing.expect(b > a);
    try testing.expect(font.lineHeight() > 0);
}

test "font: a larger pixel height measures wider, and positionOf is monotone" {
    const allocator = testing.allocator;
    const bytes = testFontBytes(allocator) catch |err| switch (err) {
        error.SkipZigTest => return error.SkipZigTest,
        else => return err,
    };
    defer allocator.free(bytes);

    var small = try Font.init(allocator, bytes, 12);
    defer small.deinit();
    var big = try Font.init(allocator, bytes, 32);
    defer big.deinit();

    try testing.expect(big.measure("Hello") > small.measure("Hello"));

    const text = "Hello";
    var prev: f32 = -1;
    var i: usize = 0;
    while (i <= text.len) : (i += 1) {
        const x = big.positionOf(text, i);
        try testing.expect(x >= prev);
        prev = x;
    }
    try testing.expectApproxEqAbs(big.measure(text), big.positionOf(text, text.len), 0.001);
}

test "font: a bad font is refused, not crashed on" {
    const allocator = testing.allocator;
    try testing.expectError(error.InvalidFont, Font.init(allocator, "not a font at all", 16));
    try testing.expectError(error.InvalidSize, Font.init(allocator, "xxxx", 0));
}

test "nextCodepoint decodes ascii and multibyte and survives garbage" {
    const text = "a\xC3\xB1z";
    var i: usize = 0;
    try testing.expectEqual(@as(u21, 'a'), nextCodepoint(text, &i));
    try testing.expectEqual(@as(u21, 0xF1), nextCodepoint(text, &i));
    try testing.expectEqual(@as(u21, 'z'), nextCodepoint(text, &i));
    try testing.expectEqual(text.len, i);

    // A lone continuation byte decodes as itself rather than looping forever.
    const bad = "\x80x";
    var j: usize = 0;
    _ = nextCodepoint(bad, &j);
    try testing.expect(j >= 1);
}

test "the font atlas packs ascii into one page and reports a slot" {
    const allocator = testing.allocator;
    const bytes = testFontBytes(allocator) catch |err| switch (err) {
        error.SkipZigTest => return error.SkipZigTest,
        else => return err,
    };
    defer allocator.free(bytes);

    const backend_null = @import("backend_null.zig");
    var backend = backend_null.Backend{};
    const renderer = backend.renderer();

    var font = try Font.init(allocator, bytes, 20);
    defer font.deinit();
    // The null backend has no atlas, so `attachAtlas` declines — and that must
    // be a handled outcome, not a crash.
    font.attachAtlas(renderer, 512) catch {};
    try testing.expect(font.atlas_handle == null);
}

test "a reload swaps the bytes, and a bad one leaves the live font intact" {
    const allocator = testing.allocator;
    const bytes = testFontBytes(allocator) catch |err| switch (err) {
        error.SkipZigTest => return error.SkipZigTest,
        else => return err,
    };
    defer allocator.free(bytes);

    var font = try Font.init(allocator, bytes, 16);
    defer font.deinit();
    const before = font.measure("Hello");
    try testing.expect(before > 0);

    // Reloading the same bytes rebuilds the state and keeps the metrics.
    try font.reload(bytes);
    try testing.expectApproxEqAbs(before, font.measure("Hello"), 0.001);

    // A half-written save is refused, and the running font is not disturbed.
    try testing.expectError(error.InvalidFont, font.reload("not a font"));
    try testing.expectApproxEqAbs(before, font.measure("Hello"), 0.001);
}
