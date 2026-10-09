# Sprite Batcher

**Source:** `src/engine/render/batcher.zig`

The sprite batcher is the CPU-side owner of draw order and batching. It decides which sprites share a draw call so that "50k sprites in ≤ 4 draw calls" is a property of the data, not luck.

## Design principles

- **Zero allocations in the frame loop** (spec §3.1): the command array is reserved at boot (`reserve`) and `lock()` refuses to grow; a frame that overflows logs a budget failure instead of silently reallocating.
- **Front-to-back within an opaque layer** (minimize overdraw): sprites are emitted in ascending layer, and within a layer the order is preserved when `sort_mode` says the order is already paint order.
- **One `SpriteCommand` is 48 bytes**; 50k sprites = 2.4 MB, inside the editor budget.

## Blend modes

```zig
pub const BlendMode = enum { solid, alpha, additive };
```

## SpriteCommand

A textured (or solid) quad in world space. The `key` field packs layer, texture slot, and blend mode into a single `u32` for fast comparison:

```zig
pub const SpriteCommand = struct {
    x: f32,          // center position (world units)
    y: f32,
    half_w: f32,     // half extents (world units)
    half_h: f32,
    u0: f32,         // UV rect into the atlas (normalized 0..1)
    v0: f32,
    u1: f32,
    v1: f32,
    r: f32,          // tint RGBA
    g: f32,
    b: f32,
    a: f32,
    rotation: f32,   // rotation around the center (radians)
    key: u32,        // packed: layer (bits 0-15), texture (bits 16-23), blend (bits 24-25)

    pub const LayerShift = 0;
    pub const TextureShift = 16;
    pub const BlendShift = 24;

    pub fn layer(self: SpriteCommand) u16 {
        return @truncate(self.key >> LayerShift);
    }
    pub fn textureSlot(self: SpriteCommand) u8 {
        return @truncate(self.key >> TextureShift);
    }
    pub fn blend(self: SpriteCommand) BlendMode {
        return @enumFromInt(@as(u2, @truncate(self.key >> BlendShift)));
    }
};
```

### Key packing

```zig
pub fn make(
    x: f32, y: f32,
    half_w: f32, half_h: f32,
    uv: [4]f32,
    color: [4]f32,
    layer_index: u16,
    tex: u8,
    blend_mode: BlendMode,
) SpriteCommand {
    return .{
        .x = x, .y = y,
        .half_w = half_w, .half_h = half_h,
        .u0 = uv[0], .v0 = uv[1], .u1 = uv[2], .v1 = uv[3],
        .r = color[0], .g = color[1], .b = color[2], .a = color[3],
        .rotation = 0,
        .key = @as(u32, layer_index) |
            (@as(u32, tex) << TextureShift) |
            (@as(u32, @intFromEnum(blend_mode)) << BlendShift),
    };
}
```

### Batch compatibility

Two commands can share a draw call when they have the same texture and blend mode:

```zig
pub fn sameBatch(a: SpriteCommand, b: SpriteCommand) bool {
    return (a.key >> TextureShift) == (b.key >> TextureShift);
}
```

## SortMode

```zig
pub const SortMode = enum {
    /// No reordering: the emitter already produces draw order (O(1)).
    none,
    /// Counting sort by layer. O(n + span), no comparisons, no allocation.
    /// Keeps the emitter's order inside each layer (stable).
    by_layer,
    /// by_layer + largest sprite first inside each layer. Maximizes early-Z
    /// rejection (overdraw rule) but pays O(n log n) comparisons.
    front_to_back,
    /// by_layer + smallest sprite first inside each layer: the painter's
    /// algorithm for alpha blending. Also O(n log n).
    back_to_front,
};
```

The default is `by_layer`. A per-frame comparison sort over 50k sprites costs ~200 ms of pure cache misses; a counting sort by layer costs ~30 µs. The layer boundary is a correctness requirement (painter's order), not a heuristic.

## Batcher

```zig
pub const Batcher = struct {
    allocator: std.mem.Allocator,
    cmds: std.ArrayList(SpriteCommand) = .empty,
    batches: std.ArrayList(Batch) = .empty,
    order: std.ArrayList(u32) = .empty,
    layers_monotonic: bool = true,
    max_layer_seen: u16 = 0,
    layer_counts: []u32 = &.{},   // 65536 x 4 B = 256 KB, reserved at boot
    scratch: []u32 = &.{},        // scatter target for counting sort
    locked: bool = false,
    overflowed: bool = false,
    draw_calls: u32 = 0,
    dropped: u32 = 0,

    pub const Batch = struct {
        first: u32,
        count: u32,
        texture: u8,
        blend: BlendMode,
        layer: u16,
    };
    // ...
};
```

### Lifecycle

```zig
pub fn init(allocator: std.mem.Allocator) Batcher
pub fn reserve(self: *Batcher, n: usize) !void   // pre-allocate for n sprites
pub fn lock(self: *Batcher) void                // freeze capacities
pub fn unlock(self: *Batcher) void
pub fn beginFrame(self: *Batcher) void          // O(1) reset, no frees
pub fn push(self: *Batcher, cmd: SpriteCommand) bool  // false when budget exhausted
pub fn buildBatches(self: *Batcher, mode: SortMode) void
pub fn deinit(self: *Batcher) void
```

### Reserve

Uses `ensureTotalCapacityPrecise` (not the "at least" variant) so the locked frame path can check `capacity` exactly:

```zig
pub fn reserve(self: *Batcher, n: usize) !void {
    try self.cmds.ensureTotalCapacityPrecise(self.allocator, n);
    try self.batches.ensureTotalCapacityPrecise(self.allocator, 64);
    try self.order.ensureTotalCapacityPrecise(self.allocator, n);
    self.layer_counts = try self.allocator.alloc(u32, 65_536);
    self.scratch = try self.allocator.alloc(u32, n);
}
```

### Push

Tracks layer monotonicity (fused into the emit — one compare per sprite) and drops sprites when locked and full:

```zig
pub fn push(self: *Batcher, cmd: SpriteCommand) bool {
    const l = cmd.layer();
    if (l < self.max_layer_seen) self.layers_monotonic = false;
    if (l > self.max_layer_seen) self.max_layer_seen = l;

    if (self.cmds.items.len >= self.cmds.capacity) {
        if (self.locked) {
            self.overflowed = true;
            self.dropped += 1;
            return false;
        }
        self.cmds.append(self.allocator, cmd) catch {
            self.overflowed = true;
            return false;
        };
        return true;
    }
    self.cmds.appendAssumeCapacity(cmd);
    return true;
}
```

### Build batches

`buildBatches` sorts (if needed) and groups consecutive sprites that share (texture, blend) into a draw call:

```zig
pub fn buildBatches(self: *Batcher, mode: SortMode) void {
    const items = self.cmds.items;
    const n = items.len;
    self.draw_calls = 0;
    if (n == 0) return;

    // FAST PATH: already layer-monotonic → identity permutation
    const need_sort = switch (mode) {
        .none => false,
        .by_layer => !self.layers_monotonic,
        .front_to_back, .back_to_front => true,
    };

    const ord: []u32 = if (need_sort) blk: {
        self.order.clearRetainingCapacity();
        for (0..n) |i| self.order.appendAssumeCapacity(@intCast(i));
        const o = self.order.items;
        switch (mode) {
            .by_layer => self.sortByLayer(items, o),
            else => {
                self.sortByLayer(items, o);
                self.sortWithinLayerByArea(items, o, mode);
            },
        }
        break :blk o;
    } else self.identityOrder(n);

    // Group consecutive same-(texture, blend) sprites into draws
    var first: u32 = 0;
    var i: u32 = 0;
    while (i < ord.len) : (i += 1) {
        const cmd = items[ord[i]];
        if (i == 0) { first = 0; continue; }
        const prev = items[ord[i - 1]];
        if (!SpriteCommand.sameBatch(cmd, prev)) {
            self.batches.appendAssumeCapacity(.{
                .first = first,
                .count = i - first,
                .texture = prev.textureSlot(),
                .blend = prev.blend(),
                .layer = prev.layer(),
            });
            self.draw_calls += 1;
            first = i;
        }
    }
    // Final batch
    const last = items[ord[ord.len - 1]];
    self.batches.appendAssumeCapacity(.{
        .first = first,
        .count = @as(u32, @intCast(ord.len)) - first,
        .texture = last.textureSlot(),
        .blend = last.blend(),
        .layer = last.layer(),
    });
    self.draw_calls += 1;
}
```

## Sorting algorithms

### Counting sort by layer (the default)

O(n + span), stable, no comparisons, no allocations. Measured at ~30 µs for 50k sprites:

```zig
fn sortByLayer(self: *Batcher, items: []const SpriteCommand, ord: []u32) void {
    if (items.len < 2) return;
    var min_layer: u16 = std.math.maxInt(u16);
    var max_layer: u16 = 0;
    for (items) |c| {
        const l = c.layer();
        min_layer = @min(min_layer, l);
        max_layer = @max(max_layer, l);
    }
    const span: usize = @as(usize, max_layer - min_layer) + 1;
    if (span > self.layer_counts.len) {
        self.sortWithinLayerByArea(items, ord, .by_layer);
        return;
    }
    const counts = self.layer_counts[0..span];
    @memset(counts, 0);
    for (items) |c| counts[c.layer() - min_layer] += 1;

    // Prefix sums → write cursors
    var acc: u32 = 0;
    for (counts) |*c| { const n = c.*; c.* = acc; acc += n; }

    // Stable scatter
    const scratch = self.scratch[0..items.len];
    for (items, 0..) |c, i| {
        const l = c.layer() - min_layer;
        scratch[counts[l]] = @intCast(i);
        counts[l] += 1;
    }
    @memcpy(ord, scratch);
}
```

### Within-layer area sort (opt-in)

O(n log n) heap sort inside each layer, with layer as the primary key. Used for `front_to_back` (early-Z) and `back_to_front` (painter's algorithm):

```zig
fn sortWithinLayerByArea(self: *Batcher, items: []const SpriteCommand, ord: []u32, mode: SortMode) void {
    if (ord.len < 2) return;
    const Ctx = struct {
        items: []const SpriteCommand,
        mode: SortMode,

        fn lessThan(ctx: @This(), ia: u32, ib: u32) bool {
            const a = ctx.items[ia];
            const b = ctx.items[ib];
            const la = a.layer();
            const lb = b.layer();
            if (la != lb) return la < lb;
            if (ctx.mode == .by_layer) return false;
            const aa = a.half_w * a.half_h;
            const bb = b.half_w * b.half_h;
            return if (ctx.mode == .front_to_back) aa > bb else aa < bb;
        }
        fn swap(ctx: @This(), ia: u32, ib: u32) void {
            std.mem.swap(u32, &ctx.items[ia], &ctx.items[ib]);
        }
    };
    std.sort.heap(u32, ord, Ctx{ .items = items, .mode = mode }, Ctx.lessThan);
}
```

## Budget check

```zig
pub fn budgetFailures(self: *Batcher, max_draw_calls: u32) struct { draws: u32, overflow: bool } {
    return .{
        .draws = if (self.draw_calls > max_draw_calls) self.draw_calls else 0,
        .overflow = self.overflowed,
    };
}
```

## Frame loop integration

```zig
// At load:
var batcher = Batcher.init(allocator);
try batcher.reserve(65536);
batcher.lock();

// Each frame:
batcher.beginFrame();
for (sprites) |s| {
    _ = batcher.push(SpriteCommand.make(
        s.x, s.y, s.half_w, s.half_h,
        s.uv, s.color, s.layer, s.texture, s.blend,
    ));
}
batcher.buildBatches(.by_layer);
// batcher.batches now holds the draw calls for the backend
```
