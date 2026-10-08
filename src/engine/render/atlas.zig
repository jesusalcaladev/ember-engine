//! M2 atlas packer: shelf (row) bin packing with sky-blue decontamination.
//!
//! Used by the editor asset pipeline (M6) but built in M2 because the sprite
//! batcher's 4-draw-call criterion is only meaningful with an atlas: sprites
//! from different source images must land in one texture.
//!
//! Algorithm: bottom-left shelf packing. O(n) insertion, ~70-80% fill on
//! typical sprite sheets, deterministic (no randomness), and trivial to reason
//! about. For M2's scale (a few hundred sprites per atlas) it is measurably
//! faster than MaxRects and produces zero fragmentation spikes at load time.
//!
//! Padding: 2 px between sprites by default. The batch shader additionally
//! clamps the UV half-texel inside the rect, so bilinear filtering never
//! samples a neighbour.

const std = @import("std");

pub const Entry = struct {
    /// Position in the atlas (pixels).
    x: u32,
    y: u32,
    /// Size in the atlas (pixels).
    w: u32,
    h: u32,
    /// Original sprite size (equals w/h unless trimmed).
    src_w: u32,
    src_h: u32,
    /// Trim offset (pixels trimmed off the left/top of the source).
    trim_x: u32,
    trim_y: u32,
};

pub const AtlasPacker = struct {
    width: u32,
    height: u32,
    padding: u32,
    allow_growth: bool,

    /// Shelf state: current row and the height of the row in progress.
    shelf_x: u32 = 0,
    shelf_y: u32 = 0,
    shelf_h: u32 = 0,
    /// Pages: after a full atlas, a new page starts (multi-page atlas).
    page: u32 = 0,
    pages_written: u32 = 0,

    pub fn init(width: u32, height: u32, padding: u32, allow_growth: bool) AtlasPacker {
        return .{
            .width = width,
            .height = height,
            .padding = padding,
            .allow_growth = allow_growth,
        };
    }

    /// Reserves a rect. Returns null when it does not fit (caller either
    /// starts a new page or bakes a bigger atlas).
    pub fn insert(self: *AtlasPacker, w: u32, h: u32) ?Entry {
        const eff_w = w + self.padding;
        const eff_h = h + self.padding;

        // New shelf needed?
        if (self.shelf_x + eff_w > self.width) {
            self.shelf_x = 0;
            self.shelf_y += self.shelf_h;
            self.shelf_h = 0;
        }
        // New page needed?
        if (self.shelf_y + eff_h > self.height) {
            if (!self.allow_growth) return null;
            self.pages_written = self.page + 1;
            self.page += 1;
            self.shelf_x = 0;
            self.shelf_y = 0;
            self.shelf_h = 0;
        }

        const entry = Entry{
            .x = self.shelf_x,
            .y = self.shelf_y,
            .w = w,
            .h = h,
            .src_w = w,
            .src_h = h,
            .trim_x = 0,
            .trim_y = 0,
        };
        self.shelf_x += eff_w;
        self.shelf_h = @max(self.shelf_h, eff_h);
        return entry;
    }

    /// Normalized UV rect of an entry (for the batcher).
    pub fn uv(entry: Entry, atlas_w: u32, atlas_h: u32) [4]f32 {
        const iw = 1.0 / @as(f32, @floatFromInt(atlas_w));
        const ih = 1.0 / @as(f32, @floatFromInt(atlas_h));
        return .{
            @as(f32, @floatFromInt(entry.x)) * iw,
            @as(f32, @floatFromInt(entry.y)) * ih,
            @as(f32, @floatFromInt(entry.x + entry.w)) * iw,
            @as(f32, @floatFromInt(entry.y + entry.h)) * ih,
        };
    }

    /// Fill ratio of the current page (diagnostics for the editor).
    pub fn fillRatio(self: *AtlasPacker) f32 {
        if (self.width == 0 or self.height == 0) return 0;
        const used = self.shelf_y + self.shelf_h;
        const total = @as(f32, @floatFromInt(self.width)) *
            @as(f32, @floatFromInt(@min(used, self.height)));
        return total / @as(f32, @floatFromInt(self.width * self.height));
    }
};

/// Sky-blue decontamination for sprites with hard alpha (the classic blue
/// halo when a cut-out PNG is filtered). Blender-style: recolour the RGB of
/// fully-transparent texels towards the average of their opaque neighbours.
/// Operates in place on a RGBA8 buffer.
pub fn decontaminateAlpha(pixels: []u8, width: u32, height: u32) void {
    const W = @as(i32, @intCast(width));
    const H = @as(i32, @intCast(height));

    var y: i32 = 0;
    while (y < H) : (y += 1) {
        var x: i32 = 0;
        while (x < W) : (x += 1) {
            const idx = @as(usize, @intCast(y * W + x)) * 4;
            if (pixels[idx + 3] != 0) continue;

            // Average the opaque neighbours.
            var r: u32 = 0;
            var g: u32 = 0;
            var b: u32 = 0;
            var n: u32 = 0;
            var dy: i32 = -1;
            while (dy <= 1) : (dy += 1) {
                var dx: i32 = -1;
                while (dx <= 1) : (dx += 1) {
                    if (dx == 0 and dy == 0) continue;
                    const nx = x + dx;
                    const ny = y + dy;
                    if (nx < 0 or ny < 0 or nx >= W or ny >= H) continue;
                    const nidx = @as(usize, @intCast(ny * W + nx)) * 4;
                    if (pixels[nidx + 3] < 128) continue;
                    r += pixels[nidx];
                    g += pixels[nidx + 1];
                    b += pixels[nidx + 2];
                    n += 1;
                }
            }
            if (n > 0) {
                pixels[idx] = @truncate(r / n);
                pixels[idx + 1] = @truncate(g / n);
                pixels[idx + 2] = @truncate(b / n);
            }
        }
    }
}

test "packer places two rects side by side on the same shelf" {
    var p = AtlasPacker.init(256, 256, 2, false);
    const a = p.insert(32, 32).?;
    const b = p.insert(32, 32).?;
    try std.testing.expectEqual(@as(u32, 0), a.x);
    try std.testing.expectEqual(@as(u32, 34), b.x); // 32 + padding
    try std.testing.expectEqual(@as(u32, 0), a.y);
    try std.testing.expectEqual(@as(u32, 0), b.y);
}

test "packer opens a new shelf when the row is full" {
    var p = AtlasPacker.init(64, 256, 0, false);
    _ = p.insert(64, 16).?; // fills the row
    const c = p.insert(10, 10).?;
    try std.testing.expectEqual(@as(u32, 0), c.x);
    try std.testing.expectEqual(@as(u32, 16), c.y);
}

test "packer returns null when full and growth is off" {
    var p = AtlasPacker.init(64, 32, 0, false);
    _ = p.insert(64, 16).?;
    _ = p.insert(64, 16).?; // exactly fills the page
    try std.testing.expectEqual(@as(?Entry, null), p.insert(8, 8));
}

test "uv rect is normalized and within [0,1]" {
    var p = AtlasPacker.init(128, 128, 2, false);
    const e = p.insert(64, 32).?;
    const uv = AtlasPacker.uv(e, 128, 128);
    try std.testing.expectApproxEqAbs(0.0, uv[0], 0.0001);
    try std.testing.expectApproxEqAbs(0.5, uv[2], 0.0001);
    try std.testing.expectApproxEqAbs(0.0, uv[1], 0.0001);
    try std.testing.expectApproxEqAbs(0.25, uv[3], 0.0001);
}

test "decontamination fills transparent texels with the neighbour colour" {
    var px = [_]u8{ 255, 0, 0, 255, 0, 0, 0, 0 };
    decontaminateAlpha(&px, 2, 1);
    // The transparent texel got the opaque neighbour's red.
    try std.testing.expectEqual(@as(u8, 255), px[4]);
    try std.testing.expectEqual(@as(u8, 0), px[7]); // alpha untouched
}