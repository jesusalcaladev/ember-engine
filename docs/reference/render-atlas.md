# Atlas Packer

**Source:** `src/engine/render/atlas.zig`

The atlas packer is a shelf (row) bin-packing algorithm used by the editor asset pipeline. It is built because the sprite batcher's 4-draw-call criterion is only meaningful with an atlas: sprites from different source images must land in one texture.

## Algorithm

Bottom-left shelf packing:

- O(n) insertion
- ~70–80% fill on typical sprite sheets
- Deterministic (no randomness)
- Trivial to reason about

For the engine's scale (a few hundred sprites per atlas) it is measurably faster than MaxRects and produces zero fragmentation spikes at load time.

## Entry

```zig
pub const Entry = struct {
    x: u32,       // position in the atlas (pixels)
    y: u32,
    w: u32,       // size in the atlas (pixels)
    h: u32,
    src_w: u32,   // original sprite size (equals w/h unless trimmed)
    src_h: u32,
    trim_x: u32, // trim offset (pixels trimmed off the left/top of the source)
    trim_y: u32,
};
```

## AtlasPacker

```zig
pub const AtlasPacker = struct {
    width: u32,
    height: u32,
    padding: u32,
    allow_growth: bool,

    // Shelf state
    shelf_x: u32 = 0,
    shelf_y: u32 = 0,
    shelf_h: u32 = 0,
    // Multi-page state
    page: u32 = 0,
    pages_written: u32 = 0,

    pub fn init(width: u32, height: u32, padding: u32, allow_growth: bool) AtlasPacker {
        return .{ .width = width, .height = height, .padding = padding, .allow_growth = allow_growth };
    }
    // ...
};
```

### Insert

Reserves a rect. Returns `null` when it does not fit (caller either starts a new page or bakes a bigger atlas):

```zig
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
```

### UV rect

Returns the normalized UV rect of an entry for the batcher:

```zig
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
```

### Fill ratio

Diagnostics for the editor:

```zig
pub fn fillRatio(self: *AtlasPacker) f32 {
    if (self.width == 0 or self.height == 0) return 0;
    const used = self.shelf_y + self.shelf_h;
    const total = @as(f32, @floatFromInt(self.width)) *
        @as(f32, @floatFromInt(@min(used, self.height)));
    return total / @as(f32, @floatFromInt(self.width * self.height));
}
```

## Padding

2 px between sprites by default. The sprite shader additionally clamps the UV half-texel inside the rect, so bilinear filtering never samples a neighbour.

## Sky-blue decontamination

Sprites with hard alpha suffer from the classic blue halo when a cut-out PNG is filtered. `decontaminateAlpha` recolours the RGB of fully-transparent texels towards the average of their opaque neighbours (Blender-style). It operates in place on an RGBA8 buffer:

```zig
pub fn decontaminateAlpha(pixels: []u8, width: u32, height: u32) void {
    const W = @as(i32, @intCast(width));
    const H = @as(i32, @intCast(height));

    var y: i32 = 0;
    while (y < H) : (y += 1) {
        var x: i32 = 0;
        while (x < W) : (x += 1) {
            const idx = @as(usize, @intCast(y * W + x)) * 4;
            if (pixels[idx + 3] != 0) continue;

            // Average the opaque neighbours
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
```

## Usage

```zig
var packer = AtlasPacker.init(2048, 2048, 2, false);

// Insert sprites
while (sprites) |sprite| {
    if (packer.insert(sprite.width, sprite.height)) |entry| {
        // Copy sprite pixels into the atlas at (entry.x, entry.y)
        // Store UV rect for the batcher:
        const uv = AtlasPacker.uv(entry, 2048, 2048);
    } else {
        // Atlas full: bake what we have, start a new page or a bigger atlas
    }
}

// Optional: decontaminate before upload
decontaminateAlpha(atlas_pixels, 2048, 2048);
```
