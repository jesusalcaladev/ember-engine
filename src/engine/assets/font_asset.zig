//! Font asset validation (M14): what the importer checks about a `.ttf`/`.otf`
//! before the text rasterizer ever sees it.
//!
//! ## Why this file exists rather than the rasterizer checking its own input
//!
//! `render/font.zig` is where glyphs are rasterized, and it can only rasterize
//! bytes it was handed — but it is also reachable directly (a test, an explicit
//! `ui.font_load`) without going through the importer, so the bytes it sees are
//! not guaranteed to have been validated by anybody. Splitting the job the way
//! `script_asset.validate` splits it would leave a second copy of the sfnt
//! parser to keep in step. So the structural check lives HERE, in `assets`, and
//! the rasterizer calls it: one parser, one verdict, and the asset layer is the
//! thing that decides what "a font" is.
//!
//! ## The scope line
//!
//! This answers "is this a well-formed sfnt whose tables are inside the file?",
//! not "will every glyph rasterize?". stb_truetype does **no** bounds checking:
//! `stbtt_InitFont` walks the table directory and then dereferences the tables it
//! finds, so a truncated `.ttf` — the shape a half-finished copy produces — walks
//! off the allocation and segfaults. (Demonstrated, not hypothesized: the
//! rasterizer's "a bad font is refused" test crashed the whole test binary
//! before this check existed.)
//!
//! What is guaranteed after `validate` returns:
//!
//! - the directory and **every table it declares** lie entirely inside the buffer;
//! - the tables `stbtt_InitFont` reads unconditionally are present, and the
//!   inner counts it trusts (the cmap subtable list, the hhea/hmtx lengths) are
//!   consistent with the table sizes it will index into.
//!
//! That makes `Font.init` and the metric queries safe — they are what the engine
//! calls at load time and every frame. Rasterizing a glyph whose *outline* body
//! is internally inconsistent is not defended against; that would mean
//! re-implementing stb_truetype's glyph interpreter, and a font is a
//! developer-authored project file, not network input.

const std = @import("std");

pub const FontError = error{
    /// Larger than `default_max_bytes`.
    TooLarge,
    /// Not an sfnt at all — wrong magic, or an sfnt missing the tables a
    /// rasterizable face must have.
    NotAFont,
    /// An sfnt whose declared tables run past the end of the buffer, or whose
    /// internal counts disagree with its table sizes. The classic shape of an
    /// interrupted copy.
    Truncated,
};

/// The largest font the importer accepts. Generous enough for a CJK face
/// (the largest real fonts are tens of MB), small enough that a mis-pointed
/// path is refused before it is read whole.
pub const default_max_bytes: usize = 64 * 1024 * 1024;

/// A face's sfnt version tags. `0x00010000` and `true` are TrueType outlines;
/// `OTTO` is OpenType with CFF outlines. A `ttcf` file is a collection of
/// faces, each with one of the above at its own offset.
const tag_ttf: u32 = 0x00010000;
const tag_true: u32 = 0x74727565; // 'true' — Apple's TrueType tag
const tag_otto: u32 = 0x4F54544F; // 'OTTO' — OpenType/CFF
const tag_ttcf: u32 = 0x74746366; // 'ttcf' — font collection

// Table tags this validator inspects, as big-endian u32s.
const tag_cmap: u32 = 0x636D6170;
const tag_head: u32 = 0x68656164;
const tag_hhea: u32 = 0x68686561;
const tag_hmtx: u32 = 0x686D7478;
const tag_maxp: u32 = 0x6D617870;
const tag_glyf: u32 = 0x676C7966;
const tag_loca: u32 = 0x6C6F6361;
const tag_cff: u32 = 0x43464620; // 'CFF '

/// What `validate` learned about a font, without decoding it.
pub const Validated = struct {
    /// Byte offset of the face's sfnt header: 0 for a plain font, the face
    /// offset for a `ttcf` collection. This is what `stbtt_InitFont` takes.
    fontstart: u32,
    /// Faces in the file; 1 for a plain `.ttf`/`.otf`.
    face_count: u32,
    /// True for `OTTO`/CFF outlines, false for TrueType `glyf` outlines.
    is_cff: bool,
    /// The whole file's size in bytes.
    size: usize,
};

/// Reads a big-endian u16 (all sfnt fields are big-endian).
fn readU16be(bytes: []const u8, at: usize) u16 {
    return (@as(u16, bytes[at]) << 8) | bytes[at + 1];
}

/// Reads a big-endian u32.
fn readU32be(bytes: []const u8, at: usize) u32 {
    return (@as(u32, bytes[at]) << 24) |
        (@as(u32, bytes[at + 1]) << 16) |
        (@as(u32, bytes[at + 2]) << 8) |
        bytes[at + 3];
}

/// Whether a 4-byte tag can begin a face (not a collection).
fn isFaceMagic(tag: u32) bool {
    return tag == tag_ttf or tag == tag_true or tag == tag_otto;
}

/// The 4-byte magic at the start of `bytes`, or null when there are not
/// enough bytes to hold one. Used by the importer's content-based `detect`.
pub fn magicOf(bytes: []const u8) ?u32 {
    if (bytes.len < 4) return null;
    return readU32be(bytes, 0);
}

/// Whether `bytes` begins with anything this engine recognises as a font: a
/// plain face or a collection. Cheap (4 bytes) and allocation-free, so `detect`
/// can call it on every file.
pub fn looksLikeFont(bytes: []const u8) bool {
    const tag = magicOf(bytes) orelse return false;
    return isFaceMagic(tag) or tag == tag_ttcf;
}

/// One table directory record's location, both values already proven inside the
/// buffer.
const TableRef = struct { offset: u32, length: u32 };

/// The directory records this validator cares about, filled by the single scan.
const Tables = struct {
    cmap: ?TableRef = null,
    head: ?TableRef = null,
    hhea: ?TableRef = null,
    hmtx: ?TableRef = null,
    maxp: ?TableRef = null,
    glyf: ?TableRef = null,
    loca: ?TableRef = null,
    cff: ?TableRef = null,

    fn slotFor(self: *Tables, tag: u32) ?*?TableRef {
        return switch (tag) {
            tag_cmap => &self.cmap,
            tag_head => &self.head,
            tag_hhea => &self.hhea,
            tag_hmtx => &self.hmtx,
            tag_maxp => &self.maxp,
            tag_glyf => &self.glyf,
            tag_loca => &self.loca,
            tag_cff => &self.cff,
            else => null,
        };
    }
};

/// Validates a font's bytes, returning where its face starts and what kind of
/// outlines it carries. Never allocates; the caller owns `bytes`.
pub fn validate(bytes: []const u8) FontError!Validated {
    return validateMax(bytes, default_max_bytes);
}

/// `validate` with an explicit size cap, so the cap itself is testable without
/// allocating 64 MB.
pub fn validateMax(bytes: []const u8, max_bytes: usize) FontError!Validated {
    if (bytes.len > max_bytes) return error.TooLarge;
    if (bytes.len < 12) return error.NotAFont;

    const magic = readU32be(bytes, 0);
    var fontstart: u32 = 0;
    var face_count: u32 = 1;
    if (magic == tag_ttcf) {
        // Header: 'ttcf', version, numFonts, then numFonts offset array.
        if (bytes.len < 16) return error.Truncated;
        face_count = readU32be(bytes, 8);
        if (face_count == 0) return error.NotAFont;
        fontstart = readU32be(bytes, 12);
        if (fontstart + 12 > bytes.len) return error.Truncated;
    } else if (!isFaceMagic(magic)) {
        return error.NotAFont;
    }

    // The face's own version tag must be one we can rasterize.
    const face_magic = readU32be(bytes, fontstart);
    if (!isFaceMagic(face_magic)) return error.NotAFont;

    var tables = Tables{};
    try scanDirectory(bytes, fontstart, &tables);

    // Required for any rasterizable face (the same set `stbtt_InitFont`
    // insists on, plus `maxp`, which we require so the glyph count is known
    // rather than defaulting to 0xffff and indexing past `hmtx`/`loca`).
    const cmap = tables.cmap orelse return error.NotAFont;
    const head = tables.head orelse return error.NotAFont;
    const hhea = tables.hhea orelse return error.NotAFont;
    const hmtx = tables.hmtx orelse return error.NotAFont;
    const maxp = tables.maxp orelse return error.NotAFont;

    // cmap: `stbtt_InitFont` loops over the subtable list without checking the
    // count against the table size, so that count has to be honest.
    if (cmap.length < 4) return error.Truncated;
    const cmap_subtables = readU16be(bytes, cmap.offset + 2);
    if (4 + 8 * @as(u64, cmap_subtables) > cmap.length) return error.Truncated;

    // head: read up to +52 (indexToLocFormat at +50).
    if (head.length < 54) return error.Truncated;
    // hhea: read up to +36 (numberOfHMetrics at +34).
    if (hhea.length < 36) return error.Truncated;
    // maxp: read +4 (numGlyphs).
    if (maxp.length < 6) return error.Truncated;

    const num_glyphs = readU16be(bytes, maxp.offset + 4);
    const long_metrics = readU16be(bytes, hhea.offset + 34);
    if (long_metrics == 0) return error.Truncated;
    // The widest hmtx access stbtt makes: the long-metric table plus the
    // two-byte left-side-bearing array for the glyphs past it.
    var hmtx_needed: u64 = 4 * @as(u64, long_metrics);
    if (num_glyphs > long_metrics) hmtx_needed += 2 * (@as(u64, num_glyphs) - long_metrics);
    if (hmtx.length < hmtx_needed) return error.Truncated;

    const is_cff = tables.cff != null;
    if (!is_cff) {
        // TrueType needs outlines and their offsets.
        _ = tables.glyf orelse return error.NotAFont;
        const loca = tables.loca orelse return error.NotAFont;
        const loc_format = readU16be(bytes, head.offset + 50);
        const entry: u64 = if (loc_format != 0) 4 else 2;
        if (loca.length < (@as(u64, num_glyphs) + 1) * entry) return error.Truncated;
    }

    return .{
        .fontstart = fontstart,
        .face_count = face_count,
        .is_cff = is_cff,
        .size = bytes.len,
    };
}

/// Walks the table directory, proving every record lies inside `bytes` and
/// recording the ones this validator inspects.
fn scanDirectory(bytes: []const u8, fontstart: u32, tables: *Tables) FontError!void {
    const start: usize = fontstart;
    if (start + 12 > bytes.len) return error.Truncated;
    const num_tables = readU16be(bytes, start + 4);
    if (num_tables == 0) return error.NotAFont;
    const dir_end = start + 12 + @as(usize, num_tables) * 16;
    if (dir_end > bytes.len) return error.Truncated;

    var i: usize = 0;
    while (i < num_tables) : (i += 1) {
        const record = start + 12 + i * 16;
        const tag = readU32be(bytes, record);
        const offset = readU32be(bytes, record + 8);
        const length = readU32be(bytes, record + 12);
        // Widened so a hostile offset+length pair cannot wrap past the check.
        if (@as(u64, offset) + @as(u64, length) > bytes.len) return error.Truncated;
        if (tables.slotFor(tag)) |slot| slot.* = .{ .offset = offset, .length = length };
    }
}

// ── Tests ────────────────────────────────────────────────────────────────────

const testing = std.testing;

/// Builds a minimal, structurally valid table directory in `buf`: one table
/// (`tag`, `body_len`) at offset 28, followed by `body_len` zero bytes. The
/// returned slice covers only the bytes actually written, so a caller cannot
/// accidentally hand `validate` a slice longer than `buf`. Enough for the
/// directory walk, not a rasterizable face — the real-font test covers that.
fn syntheticFace(buf: []u8, tag: u32, body_len: u32) []u8 {
    @memset(buf, 0);
    std.mem.writeInt(u32, buf[0..4], 0x00010000, .big);
    std.mem.writeInt(u16, buf[4..6], 1, .big);
    std.mem.writeInt(u32, buf[12..16], tag, .big);
    std.mem.writeInt(u32, buf[20..24], 28, .big); // offset
    std.mem.writeInt(u32, buf[24..28], body_len, .big);
    return buf[0 .. 28 + body_len];
}

/// Loads the vendored test typeface, skipping the test when the bootstrap has
/// not fetched `libs/fonts` (they are not committed — see `libs/fonts.commit`).
fn testFontBytes(allocator: std.mem.Allocator) ![]u8 {
    const io = std.Io.Threaded.global_single_threaded.io();
    return std.Io.Dir.cwd().readFileAlloc(io, "libs/fonts/Inter-Regular.ttf", allocator, .limited(8 << 20)) catch |err| switch (err) {
        error.FileNotFound => error.SkipZigTest,
        else => err,
    };
}

test "magic detection follows the bytes, not the extension" {
    try testing.expect(looksLikeFont(&[_]u8{ 0x00, 0x01, 0x00, 0x00 }));
    try testing.expect(looksLikeFont("true...."));
    try testing.expect(looksLikeFont("OTTO...."));
    try testing.expect(looksLikeFont("ttcf...."));
    try testing.expect(!looksLikeFont("not a font"));
    try testing.expect(!looksLikeFont(&[_]u8{ 0x89, 'P', 'N', 'G' }));
    try testing.expect(magicOf("ab") == null);
}

test "a real .ttf validates, reports its face offset and outline kind" {
    const allocator = testing.allocator;
    const bytes = testFontBytes(allocator) catch |err| switch (err) {
        error.SkipZigTest => return error.SkipZigTest,
        else => return err,
    };
    defer allocator.free(bytes);

    const info = try validate(bytes);
    try testing.expectEqual(@as(u32, 0), info.fontstart);
    try testing.expectEqual(@as(u32, 1), info.face_count);
    try testing.expect(!info.is_cff); // Inter is a TrueType face.
    try testing.expectEqual(bytes.len, info.size);
}

test "a truncated font is refused, not read past" {
    const allocator = testing.allocator;
    const bytes = testFontBytes(allocator) catch |err| switch (err) {
        error.SkipZigTest => return error.SkipZigTest,
        else => return err,
    };
    defer allocator.free(bytes);

    // Half a face cannot contain all of its tables, so a truncated copy is
    // caught before any table is dereferenced — which is the whole point.
    try testing.expectError(error.Truncated, validate(bytes[0 .. bytes.len / 2]));
    try testing.expectError(error.Truncated, validate(bytes[0..64]));
    try testing.expectError(error.NotAFont, validate(bytes[0..4]));
    try testing.expectError(error.NotAFont, validate(""));
}

test "non-fonts and lies are refused" {
    try testing.expectError(error.NotAFont, validate("not a font at all"));
    // OTTO with a garbage table count: rejected as truncated, never walked.
    try testing.expectError(error.Truncated, validate("OTTO" ++ "x" ** 40));

    // An sfnt whose directory claims more tables than the file holds.
    var big_dir: [64]u8 = [_]u8{0} ** 64;
    std.mem.writeInt(u32, big_dir[0..4], 0x00010000, .big);
    std.mem.writeInt(u16, big_dir[4..6], 100, .big);
    try testing.expectError(error.Truncated, validate(&big_dir));

    // A single-table face whose one table claims to run past the end.
    var buf: [64]u8 = undefined;
    _ = syntheticFace(&buf, tag_cmap, 4);
    std.mem.writeInt(u32, buf[24..28], 4096, .big); // lie about the length
    try testing.expectError(error.Truncated, validate(&buf));

    // A structurally sound directory that carries none of the required tables.
    var okbuf: [64]u8 = undefined;
    const okface = syntheticFace(&okbuf, tag_cmap, 4);
    try testing.expectError(error.NotAFont, validate(okface));
}

test "an oversize file is refused before it is walked" {
    const tiny = [_]u8{ 0, 1, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0 };
    try testing.expectError(error.TooLarge, validateMax(&tiny, 4));
}
