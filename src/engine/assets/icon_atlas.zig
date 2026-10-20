//! The icon atlas: the PNGs in `assets/icons/`, packed into ONE image.
//!
//! ## Why an atlas and not a texture per icon
//!
//! Fifty-four icons are fifty-four textures, fifty-four bind groups and
//! fifty-four chances for the driver to do something surprising. One atlas is
//! one texture, one bind group and one draw call's worth of state — and the
//! editor's icons are drawn with the UI's draw list, which wants a texture it
//! can sample, not a pile of them.
//!
//! ## What the loader does to each file
//!
//! Three things, and each of them is the difference between "an icon" and "a
//! picture of an icon":
//!
//! 1. **The transparent margin is cropped.** An icon set ships every glyph in
//!    a square canvas with the drawing in the middle, so a 240px file with a
//!    2px stroke is mostly emptiness. Cropping to the ink is what makes the
//!    icon FILL its box instead of sitting in the middle of one.
//! 2. **The ink is scaled to a fixed cell.** Every icon ends up the same size
//!    on the screen, whatever the source was. The scale is a box filter: a
//!    2px stroke point-sampled into a 64px cell is a dotted line.
//! 3. **The colour becomes white.** An icon is a MASK: the theme tints it
//!    (the accent when it is active, the dim grey when it is disabled). A
//!    black PNG multiplied by a blue tint is black, so the RGB is replaced by
//!    white and the ALPHA — where the anti-aliasing lives — is kept.
//!
//! ## A missing file is not an error
//!
//! The atlas is optional: an icon without a cell is drawn as geometry by the
//! UI layer, exactly as it always was. A file that cannot be decoded is
//! counted and reported, never a crash: a broken icon must not take the
//! editor down.

const std = @import("std");
const image_asset = @import("image.zig");
const asset_types = @import("asset_types.zig");

/// The cell size, in pixels. 64 is four times a 16px icon, which is what a
/// HiDPI screen needs and what the source files (240px) can carry.
pub const cell_size: u32 = 64;

/// One icon's cell: where it is, and which file it came from.
pub const Entry = struct {
    /// The file's name without the extension ("move", not "move.png").
    name: []const u8,
    u0: f32,
    v0: f32,
    u1: f32,
    v1: f32,
};

/// The loaded atlas.
pub const Atlas = struct {
    allocator: std.mem.Allocator,
    /// The atlas's pixels, RGBA8.
    pixels: []u8,
    width: u32,
    height: u32,
    /// The cells, one per icon.
    entries: []Entry,
    /// How many files were found but could not be used.
    failed: usize = 0,

    pub fn deinit(self: *Atlas) void {
        for (self.entries) |e| self.allocator.free(e.name);
        self.allocator.free(self.pixels);
        self.allocator.free(self.entries);
    }

    /// The cell for a name, if the atlas has one.
    pub fn find(self: *const Atlas, name: []const u8) ?Entry {
        for (self.entries) |e| {
            if (std.mem.eql(u8, e.name, name)) return e;
        }
        return null;
    }
};

/// Loads every PNG in `dir_path` and packs them into one atlas.
///
/// An empty directory (or one that does not exist) is not an error: the caller
/// simply has no atlas, and the UI layer draws its icons as geometry.
pub fn load(allocator: std.mem.Allocator, dir_path: []const u8) !Atlas {
    const io = std.Io.Threaded.global_single_threaded.io();
    var dir = std.Io.Dir.cwd().openDir(io, dir_path, .{ .iterate = true }) catch {
        return .{
            .allocator = allocator,
            .pixels = &.{},
            .width = 0,
            .height = 0,
            .entries = &.{},
        };
    };
    defer dir.close(io);

    var names: std.ArrayListUnmanaged([]const u8) = .empty;
    defer {
        for (names.items) |n| allocator.free(n);
        names.deinit(allocator);
    }

    var it = dir.iterate();
    while (it.next(io) catch null) |entry| {
        if (entry.kind != .file) continue;
        if (!std.mem.endsWith(u8, entry.name, ".png")) continue;
        try names.append(allocator, try allocator.dupe(u8, entry.name));
    }
    // Sorted, so the atlas is the same every run: an atlas that reshuffles
    // itself between runs makes "the icon moved" a mystery.
    std.mem.sort([]const u8, names.items, {}, struct {
        fn lessThan(_: void, a: []const u8, b: []const u8) bool {
            return std.mem.lessThan(u8, a, b);
        }
    }.lessThan);

    if (names.items.len == 0) {
        return .{
            .allocator = allocator,
            .pixels = &.{},
            .width = 0,
            .height = 0,
            .entries = &.{},
        };
    }

    const count: f32 = @floatFromInt(names.items.len);
    const cols: u32 = @intFromFloat(@ceil(@sqrt(count)));
    const rows: u32 = @intFromFloat(@ceil(count / @as(f32, @floatFromInt(cols))));
    const width = cols * cell_size;
    const height = rows * cell_size;

    const pixels = try allocator.alloc(u8, @intCast(width * height * 4));
    errdefer allocator.free(pixels);
    @memset(pixels, 0);

    var entries: std.ArrayListUnmanaged(Entry) = .empty;
    errdefer entries.deinit(allocator);

    var failed: usize = 0;
    for (names.items, 0..) |name, i| {
        const stem = name[0 .. name.len - 4]; // without ".png"
        const path = try std.fs.path.join(allocator, &.{ dir_path, name });
        defer allocator.free(path);

        const image = image_asset.decode(allocator, path) catch {
            failed += 1;
            continue;
        };
        defer allocator.free(image.pixels);

        const col: u32 = @intCast(i % cols);
        const row: u32 = @intCast(i / cols);
        const ox = col * cell_size;
        const oy = row * cell_size;

        blit(pixels, width, image, ox, oy) catch {
            failed += 1;
            continue;
        };

        // The name is COPIED: the file names are freed when this function
        // returns, and an entry whose name points into freed memory is a
        // lookup that fails at random — which is exactly what it did.
        try entries.append(allocator, .{
            .name = try allocator.dupe(u8, stem),
            .u0 = @as(f32, @floatFromInt(ox)) / @as(f32, @floatFromInt(width)),
            .v0 = @as(f32, @floatFromInt(oy)) / @as(f32, @floatFromInt(height)),
            .u1 = @as(f32, @floatFromInt(ox + cell_size)) / @as(f32, @floatFromInt(width)),
            .v1 = @as(f32, @floatFromInt(oy + cell_size)) / @as(f32, @floatFromInt(height)),
        });
    }

    return .{
        .allocator = allocator,
        .pixels = pixels,
        .width = width,
        .height = height,
        .entries = try entries.toOwnedSlice(allocator),
        .failed = failed,
    };
}

/// Puts one image into the atlas: cropped to its ink, scaled to the cell,
/// and turned into a white mask.
fn blit(pixels: []u8, atlas_w: u32, image: asset_types.Image, ox: u32, oy: u32) !void {
    const src = image.pixels;
    const sw = image.width;
    const sh = image.height;
    if (sw == 0 or sh == 0) return error.EmptyImage;

    // The ink's bounding box: the pixels that are not fully transparent.
    var min_x: u32 = sw;
    var min_y: u32 = sh;
    var max_x: u32 = 0;
    var max_y: u32 = 0;
    var found = false;
    for (0..sh) |y| {
        const yu: u32 = @intCast(y);
        for (0..sw) |x| {
            const a = src[(y * sw + x) * 4 + 3];
            if (a < 8) continue;
            found = true;
            const xu: u32 = @intCast(x);
            min_x = @min(min_x, xu);
            min_y = @min(min_y, yu);
            max_x = @max(max_x, xu);
            max_y = @max(max_y, yu);
        }
    }
    if (!found) return error.EmptyImage;

    const ink_w = max_x - min_x + 1;
    const ink_h = max_y - min_y + 1;
    // The icon fills the cell, with a little air around it so the stroke
    // does not touch the cell's edge.
    const pad: u32 = 2;
    const inner = cell_size - pad * 2;
    // The scale that fits the ink into the cell, preserving the aspect.
    const scale = @min(
        @as(f32, @floatFromInt(inner)) / @as(f32, @floatFromInt(ink_w)),
        @as(f32, @floatFromInt(inner)) / @as(f32, @floatFromInt(ink_h)),
    );
    const draw_w: u32 = @max(1, @as(u32, @intFromFloat(@as(f32, @floatFromInt(ink_w)) * scale)));
    const draw_h: u32 = @max(1, @as(u32, @intFromFloat(@as(f32, @floatFromInt(ink_h)) * scale)));
    const off_x = ox + (cell_size - draw_w) / 2;
    const off_y = oy + (cell_size - draw_h) / 2;

    // A box filter: the source is 240px and the cell is 64, so every
    // destination pixel is the average of a source block.
    for (0..draw_h) |dy| {
        const dyu: u32 = @intCast(dy);
        const y0 = min_y + dyu * ink_h / draw_h;
        const y1 = @min(min_y + (dyu + 1) * ink_h / draw_h, min_y + ink_h);
        for (0..draw_w) |dx| {
            const dxu: u32 = @intCast(dx);
            const x0 = min_x + dxu * ink_w / draw_w;
            const x1 = @min(min_x + (dxu + 1) * ink_w / draw_w, min_x + ink_w);

            var r: u32 = 0;
            var g: u32 = 0;
            var b: u32 = 0;
            var a: u32 = 0;
            var n: u32 = 0;
            var yy = y0;
            while (yy < y1) : (yy += 1) {
                var xx = x0;
                while (xx < x1) : (xx += 1) {
                    const i = (yy * sw + xx) * 4;
                    r += src[i];
                    g += src[i + 1];
                    b += src[i + 2];
                    a += src[i + 3];
                    n += 1;
                }
            }
            if (n == 0) continue;
            const o = ((off_y + dy) * atlas_w + (off_x + dx)) * 4;
            // The colour becomes white: the icon is a MASK, and the theme
            // tints it. The alpha — where the anti-aliasing lives — is kept.
            pixels[o] = 255;
            pixels[o + 1] = 255;
            pixels[o + 2] = 255;
            pixels[o + 3] = @intCast(a / n);
        }
    }
}

// ── Tests ───────────────────────────────────────────────────────────────────

const testing = std.testing;

test "a missing icon folder is not an error" {
    var atlas = try load(testing.allocator, "assets/there-is-no-such-folder");
    defer atlas.deinit();
    try testing.expectEqual(@as(usize, 0), atlas.entries.len);
    try testing.expectEqual(@as(u32, 0), atlas.width);
}

test "the icon atlas packs what it finds, and every cell is inside it" {
    var atlas = try load(testing.allocator, "assets/icons");
    defer atlas.deinit();

    // The editor's icons are files in that folder: without them the toolbar
    // falls back to geometry, which works, but the folder is the point.
    try testing.expect(atlas.entries.len > 0);
    try testing.expectEqual(@as(usize, 0), atlas.failed);

    for (atlas.entries) |e| {
        try testing.expect(e.u0 >= 0.0 and e.u1 <= 1.0);
        try testing.expect(e.v0 >= 0.0 and e.v1 <= 1.0);
        try testing.expect(e.u1 > e.u0);
        try testing.expect(e.v1 > e.v0);
        try testing.expect(e.name.len > 0);
    }

    // The cells do not overlap: two icons sharing a pixel is one icon drawn
    // twice, and it looks like a smudge.
    for (atlas.entries, 0..) |a, i| {
        for (atlas.entries, 0..) |b, j| {
            if (i == j) continue;
            const overlap = a.u0 < b.u1 and b.u0 < a.u1 and a.v0 < b.v1 and b.v0 < a.v1;
            try testing.expect(!overlap);
        }
    }
}

test "every icon in the atlas has INK in its cell" {
    // The one that matters: an icon whose cell is empty draws nothing at all,
    // and a toolbar with a hole in it looks broken.
    var atlas = try load(testing.allocator, "assets/icons");
    defer atlas.deinit();

    for (atlas.entries) |e| {
        const x0: u32 = @intFromFloat(e.u0 * @as(f32, @floatFromInt(atlas.width)));
        const y0: u32 = @intFromFloat(e.v0 * @as(f32, @floatFromInt(atlas.height)));
        const x1: u32 = @intFromFloat(e.u1 * @as(f32, @floatFromInt(atlas.width)));
        const y1: u32 = @intFromFloat(e.v1 * @as(f32, @floatFromInt(atlas.height)));

        var ink: u32 = 0;
        var y = y0;
        while (y < y1) : (y += 1) {
            var x = x0;
            while (x < x1) : (x += 1) {
                if (atlas.pixels[(y * atlas.width + x) * 4 + 3] > 8) ink += 1;
            }
        }
        if (ink == 0) {
            std.debug.print("icon '{s}' has an EMPTY cell\\n", .{e.name});
        }
        try testing.expect(ink > 0);
    }
}
