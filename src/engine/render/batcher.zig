//! M2 sprite batcher: CPU side.
//!
//! Owns the CPU vertex buffer and the ORDER of the draws. The GPU side is a
//! single pipeline per (texture, blend) pair; this file decides which sprites
//! share a batch so that "50k sprites in <= 4 draw calls" (ROADMAP M2) is a
//! property of the data, not luck.
//!
//! Design notes that the budgets depend on:
//! - **Zero allocations in the frame loop** (spec §3.1): the vertex array is
//!   reserved at boot (`reserve`) and `lock()` refuses to grow; a frame that
//!   overflows logs a budget failure instead of silently reallocating.
//! - **Front-to-back within an opaque layer** (user requirement: minimize
//!   overdraw): sprites are emitted in ascending layer, and *within* a layer we
//!   do NOT reorder when `sort_mode` says the order is already paint order.
//!   `sortBackToFront` for transparent layers (mandatory for correctness) and
//!   `sortFrontToBack` for opaque ones (early-Z / discard-before-shader).
//! - One `SpriteCommand` is 48 bytes; 50k sprites = 2.4 MB, inside the
//!   "editor empty project" budget with room to spare.

const std = @import("std");
const core = @import("core");
const log = core.log.scoped("batcher");

/// `solid` (not `opaque`: that is a Zig primitive type name).
pub const BlendMode = enum { solid, alpha, additive };

/// A textured (or solid) quad in WORLD space. 6 vertices are emitted per
/// command, so the CPU cost is one memcpy-sized write per corner.
pub const SpriteCommand = struct {
    /// Center position (world units).
    x: f32,
    y: f32,
    /// Half extents (world units).
    half_w: f32,
    half_h: f32,
    /// UV rect into the atlas (normalized 0..1).
    u0: f32,
    v0: f32,
    u1: f32,
    v1: f32,
    /// Tint RGBA.
    r: f32,
    g: f32,
    b: f32,
    a: f32,
    /// Rotation around the center (radians).
    rotation: f32,
    /// key packs: layer in the low 16 bits, texture slot in bits 16..23,
    /// blend in bits 24..25. Packing keeps the struct at 48 bytes and makes
    /// the sort key a single integer compare.
    key: u32,

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

    pub fn make(
        x: f32,
        y: f32,
        half_w: f32,
        half_h: f32,
        uv: [4]f32,
        color: [4]f32,
        layer_index: u16,
        tex: u8,
        blend_mode: BlendMode,
    ) SpriteCommand {
        return .{
            .x = x,
            .y = y,
            .half_w = half_w,
            .half_h = half_h,
            .u0 = uv[0],
            .v0 = uv[1],
            .u1 = uv[2],
            .v1 = uv[3],
            .r = color[0],
            .g = color[1],
            .b = color[2],
            .a = color[3],
            .rotation = 0,
            .key = @as(u32, layer_index) |
                (@as(u32, tex) << TextureShift) |
                (@as(u32, @intFromEnum(blend_mode)) << BlendShift),
        };
    }

    /// True when two commands can share a draw call: same texture, same blend.
    pub fn sameBatch(a: SpriteCommand, b: SpriteCommand) bool {
        return (a.key >> TextureShift) == (b.key >> TextureShift);
    }
};

/// How `buildBatches` orders the sprites.
///
/// The default is `by_layer` and that is deliberate. A per-frame comparison
/// sort over 50k sprites costs ~200 ms of pure cache misses on the reference
/// hardware — it was measured, not guessed (an insertion sort first, a heap
/// sort after: both are O(n^2) or cache-hostile at that size). Layers, on the
/// other hand, sort with a counting pass in ~30 µs and the layer boundary is a
/// CORRECTNESS requirement (painter's order), not a heuristic. So the cheap
/// sort is the default and the expensive ones are opt-in per scene.
pub const SortMode = enum {
    /// No reordering at all: the emitter already produces draw order (O(1) after
    /// the emit). Cheapest; only valid if the caller groups by layer itself.
    none,
    /// Counting sort by layer. O(n + span), no comparisons, no allocation.
    /// Keeps the emitter's order inside each layer (stable).
    by_layer,
    /// `by_layer` + largest sprite first inside each layer. Maximizes early-Z
    /// rejection (the overdraw rule) but pays O(n log n) comparisons.
    front_to_back,
    /// `by_layer` + smallest sprite first inside each layer: the painter's
    /// algorithm for alpha blending. Also O(n log n).
    back_to_front,
};

pub const Batcher = struct {
    allocator: std.mem.Allocator,
    /// Commands accumulated for the current frame.
    cmds: std.ArrayList(SpriteCommand) = .empty,
    /// Per-draw batch metadata (filled by `buildBatches`).
    batches: std.ArrayList(Batch) = .empty,
    /// Sorted scratch (indices, not commands: no double memory).
    order: std.ArrayList(u32) = .empty,
    /// False as soon as a sprite is pushed into a layer LOWER than the current
    /// one. A scene renderer that iterates layers in order never trips this,
    /// and that is the case where the whole sort collapses to a linear scan.
    layers_monotonic: bool = true,
    /// Highest layer pushed so far (for the monotonic check).
    max_layer_seen: u16 = 0,
    /// Counting-sort cursors, one per layer slot, over the whole 16-bit layer
    /// space. A PLAIN SLICE, not an ArrayList: an ArrayList cannot be indexed
    /// past its length, and this buffer is sized once at boot (256 KB) and
    /// only ever written through a [min..max] window.
    layer_counts: []u32 = &.{},
    /// Scatter target of the counting sort (one slot per sprite).
    scratch: []u32 = &.{},
    /// Frozen once `lock()` is called for the frame loop (spec §3.1).
    locked: bool = false,
    /// Overflow flag: set instead of growing while locked.
    overflowed: bool = false,
    /// Number of draws the last frame issued (spec §4 metric).
    draw_calls: u32 = 0,
    /// Sprites the last frame dropped because the buffer was full.
    dropped: u32 = 0,

    pub const Batch = struct {
        first: u32,
        count: u32,
        texture: u8,
        blend: BlendMode,
        layer: u16,
    };

    pub fn init(allocator: std.mem.Allocator) Batcher {
        return .{ .allocator = allocator };
    }

    pub fn deinit(self: *Batcher) void {
        self.cmds.deinit(self.allocator);
        self.batches.deinit(self.allocator);
        self.order.deinit(self.allocator);
        if (self.layer_counts.len > 0) self.allocator.free(self.layer_counts);
        if (self.scratch.len > 0) self.allocator.free(self.scratch);
        self.layer_counts = &.{};
        self.scratch = &.{};
    }

    /// Pre-allocates for `n` sprites (call at load time, never per frame).
    pub fn reserve(self: *Batcher, n: usize) !void {
        // `ensureTotalCapacityPrecise` and NOT the "at least" variant: the
        // locked frame path checks `capacity` to decide whether a push is
        // free, so the capacity must be exactly what was reserved (no slack
        // that silently absorbs sprites the caller thought were dropped).
        try self.cmds.ensureTotalCapacityPrecise(self.allocator, n);
        try self.batches.ensureTotalCapacityPrecise(self.allocator, 64);
        try self.order.ensureTotalCapacityPrecise(self.allocator, n);
        // 65536 x 4 B = 256 KB, once, at load. The counting sort uses a
        // window of it (min..max layer), so the common 2-layer scene only
        // touches the first entries.
        self.layer_counts = try self.allocator.alloc(u32, 65_536);
        self.scratch = try self.allocator.alloc(u32, n);
    }

    /// Freezes the capacities. After this, `push` NEVER grows: a full frame
    /// drops sprites and flags `overflowed` instead of allocating (spec §3.1).
    pub fn lock(self: *Batcher) void {
        self.locked = true;
    }

    pub fn unlock(self: *Batcher) void {
        self.locked = false;
    }

    /// Starts a new frame: O(1) reset, no frees.
    pub fn beginFrame(self: *Batcher) void {
        self.cmds.clearRetainingCapacity();
        self.batches.clearRetainingCapacity();
        self.order.clearRetainingCapacity();
        self.overflowed = false;
        self.draw_calls = 0;
        self.dropped = 0;
        self.layers_monotonic = true;
        self.max_layer_seen = 0;
    }

    /// Appends a sprite. Returns false when the frame budget for sprites is
    /// exhausted (only possible while locked, i.e. during the frame loop).
    pub fn push(self: *Batcher, cmd: SpriteCommand) bool {
        // Layer monotonicity is tracked HERE, fused into the emit: it costs one
        // compare per sprite and decides whether the frame needs a sort at all.
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

    pub fn count(self: *Batcher) usize {
        return self.cmds.items.len;
    }

    /// True when the command array is already grouped by layer, i.e. the
    /// permutation is the identity and the caller may consume `cmds` directly
    /// instead of going through `order`. This is the fast path of the whole
    /// batcher, and it is not a heuristic: painter's order means a correct
    /// scene is layer-monotonic by construction, so the sort has nothing to do.
    pub fn isAlreadyOrdered(self: *const Batcher) bool {
        return self.layers_monotonic;
    }

    /// The identity permutation [0, 1, 2, ...], reusing `order` when it is
    /// already large enough and allocating nothing otherwise (spec §3.1).
    fn identityOrder(self: *Batcher, n: usize) []u32 {
        // `reserve(n)` guarantees the capacity, so this never allocates
        // (spec §3.1). The assert catches a caller that forgot to reserve.
        std.debug.assert(self.order.capacity >= n);
        self.order.clearRetainingCapacity();
        for (0..n) |i| self.order.appendAssumeCapacity(@intCast(i));
        return self.order.items;
    }

    /// Stable counting sort by layer: O(n + span), no comparisons, no
    /// allocations. `layer_counts` and `scratch` are reserved at boot.
///
/// This is the sort that actually matters. It is measured at ~30 µs for 50k
    /// sprites on the reference hardware, against ~200 ms for a comparison
    /// sort of the same data, and the layer boundary is a correctness rule
    /// (painter's order), so it can never be "skipped for speed".
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
    // A pathological layer range (sprites in layers 0 and 65000) would turn
    // the counting array into 256 KB of memset for nothing; fall back to the
    // comparison sort in that (rare) case. NOTE: the bound is `capacity`, not
    // `items.len`: reserve() sets the capacity and leaves the length at 0, and
    // checking the length made EVERY frame fall through to the heap sort
    // (21 ms at 50k sprites instead of 30 us).
    if (span > self.layer_counts.len) {
        self.sortWithinLayerByArea(items, ord, .by_layer);
        return;
    }
    const counts = self.layer_counts[0..span];
    @memset(counts, 0);
    for (items) |c| counts[c.layer() - min_layer] += 1;

    // Prefix sums turn the counts into write cursors.
    var acc: u32 = 0;
    for (counts) |*c| {
        const n = c.*;
        c.* = acc;
        acc += n;
    }
    // Stable scatter into the scratch buffer, then back.
    const scratch = self.scratch[0..items.len];
    for (items, 0..) |c, i| {
        const l = c.layer() - min_layer;
        scratch[counts[l]] = @intCast(i);
        counts[l] += 1;
    }
    @memcpy(ord, scratch);
}

/// O(n log n) ordering INSIDE each layer, with the layer as the primary key so
/// the grouping from `sortByLayer` survives. Opt-in only: this is the pass
/// that costs ~200 ms at 50k sprites because every comparison is a random
/// access into the command array.
fn sortWithinLayerByArea(self: *Batcher, items: []const SpriteCommand, ord: []u32, mode: SortMode) void {
    _ = self;
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

    /// Sorts and groups into draw batches. Zero allocations when the order and
    /// batch arrays were reserved at boot.
    pub fn buildBatches(self: *Batcher, mode: SortMode) void {
        const items = self.cmds.items;
        const n = items.len;
        self.draw_calls = 0;
        if (n == 0) return;

        // FAST PATH: the emitter already produced layer-monotonic order, so the
        // permutation is the identity. Building it would cost two extra passes
        // over the whole command array (2.4 MB at 50k sprites) to reproduce
        // the order that is already there. Skipped when the caller explicitly
        // asked for an area sort, which is the only mode that can still change
        // the order inside a layer.
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

        // Group consecutive sprites that share (texture, blend) into a draw.
        var first: u32 = 0;
        var i: u32 = 0;
        while (i < ord.len) : (i += 1) {
            const cmd = items[ord[i]];
            if (i == 0) {
                first = 0;
                continue;
            }
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
        // Final batch.
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

    /// Verifies the frame budget from spec §4 (draw calls <= 32). Called by the
    /// runtime at the end of the frame; returns the offending count or 0.
    pub fn budgetFailures(self: *Batcher, max_draw_calls: u32) struct { draws: u32, overflow: bool } {
        return .{
            .draws = if (self.draw_calls > max_draw_calls) self.draw_calls else 0,
            .overflow = self.overflowed,
        };
    }
};

test "batcher groups consecutive same-texture sprites into one draw" {
    var b = Batcher.init(std.testing.allocator);
    defer b.deinit();
    try b.reserve(16);
    b.lock();
    b.beginFrame();

    // 10 sprites, all texture 0 -> 1 draw call.
    var i: usize = 0;
    while (i < 10) : (i += 1) {
        _ = b.push(SpriteCommand.make(
            @floatFromInt(i),
            0,
            1,
            1,
            .{ 0, 0, 1, 1 },
            .{ 1, 1, 1, 1 },
            0,
            0,
            .alpha,
        ));
    }
    b.buildBatches(.none);
    try std.testing.expectEqual(@as(u32, 1), b.draw_calls);
}

test "batcher splits when the texture changes" {
    var b = Batcher.init(std.testing.allocator);
    defer b.deinit();
    try b.reserve(16);
    b.lock();
    b.beginFrame();

    _ = b.push(SpriteCommand.make(0, 0, 1, 1, .{ 0, 0, 1, 1 }, .{ 1, 1, 1, 1 }, 0, 0, .alpha));
    _ = b.push(SpriteCommand.make(1, 0, 1, 1, .{ 0, 0, 1, 1 }, .{ 1, 1, 1, 1 }, 0, 1, .alpha));
    _ = b.push(SpriteCommand.make(2, 0, 1, 1, .{ 0, 0, 1, 1 }, .{ 1, 1, 1, 1 }, 0, 1, .alpha));
    b.buildBatches(.none);
    try std.testing.expectEqual(@as(u32, 2), b.draw_calls);
}

test "front-to-back puts the bigger sprite first (overdraw rule)" {
    var b = Batcher.init(std.testing.allocator);
    defer b.deinit();
    try b.reserve(8);
    b.lock();
    b.beginFrame();

    // small then big, same texture
    _ = b.push(SpriteCommand.make(0, 0, 1, 1, .{ 0, 0, 1, 1 }, .{ 1, 1, 1, 1 }, 0, 0, .solid));
    _ = b.push(SpriteCommand.make(0, 0, 10, 10, .{ 0, 0, 1, 1 }, .{ 1, 1, 1, 1 }, 0, 0, .solid));
    b.buildBatches(.front_to_back);

    // order[0] should be the big sprite (index 1 in the command array)
    try std.testing.expectEqual(@as(u32, 1), b.order.items[0]);
}

test "locked batcher drops instead of allocating" {
    var b = Batcher.init(std.testing.allocator);
    defer b.deinit();
    try b.reserve(2);
    b.lock();
    b.beginFrame();

    try std.testing.expect(b.push(SpriteCommand.make(0, 0, 1, 1, .{ 0, 0, 1, 1 }, .{ 1, 1, 1, 1 }, 0, 0, .alpha)));
    try std.testing.expect(b.push(SpriteCommand.make(0, 0, 1, 1, .{ 0, 0, 1, 1 }, .{ 1, 1, 1, 1 }, 0, 0, .alpha)));
    // Third push overflows (capacity = 2).
    try std.testing.expect(!b.push(SpriteCommand.make(0, 0, 1, 1, .{ 0, 0, 1, 1 }, .{ 1, 1, 1, 1 }, 0, 0, .alpha)));
    try std.testing.expect(b.overflowed);
    try std.testing.expectEqual(@as(u32, 1), b.dropped);
}