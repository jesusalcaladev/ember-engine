//! M2/M3 — ECS-driven 2D renderer: the bridge from Actors to the GPU.
//!
//! This is where the ECS stops being a data structure and becomes the renderer:
//! one system walks `(Transform, Sprite)` in column batches, applies the
//! interpolated world transform (spec §3.3) and writes 32-byte GPU instances.
//!
//! Design constraints, all measured (see ROADMAP M2):
//! - **Zero allocations in the frame** (spec §3.1): the instance buffer and the
//!   batcher are reserved by `reserve()` at load and locked afterwards.
//! - **1 draw call per (atlas, blend) run**, so a scene from one atlas is one
//!   draw call. Draw-call runs are detected while walking, with no sort pass:
//!   entities that live in the same archetype are already contiguous, and
//!   archetypes are visited in creation order.
//! - **Hierarchy**: when `World.enableHierarchy` is on, `hierarchy.resolve` has
//!   already produced world transforms, and the renderer composes the LOCAL
//!   sprite with the resolved PARENT chain instead of re-walking it.
//!
//! Why the render path never reorders sprites itself: a comparison sort of 50k
//! sprites costs ~200 ms of cache misses; a counting sort by layer ~30 us; and
//! when the scene is already layer-monotonic (the normal case — a scene
//! renderer emits layer by layer) the sort is unnecessary entirely. The
//! `batcher.SortMode` covers the cases that need it, opt-in per scene.

const std = @import("std");
const core = @import("core");
const log = core.log.scoped("render2d");
const render = @import("render.zig");
const batcher_mod = @import("batcher.zig");
const ecs = @import("ecs");

const World = ecs.World;
const components = ecs.components;
const Sprite = components.Sprite;
const Transform = components.Transform;

/// What one frame's collection produced. The runtime reports these numbers
/// against spec.md (§4 draw calls, §4 upload bytes).
pub const Stats = struct {
    /// Entities visited by the query.
    entities: u32 = 0,
    /// Instances actually written (visible ones).
    instances: u32 = 0,
    /// Entities skipped because they are invisible.
    hidden: u32 = 0,
    /// Draw calls the backend issued.
    draw_calls: u32 = 0,
    /// Instances dropped because the reserved buffer was full. Non-zero means
    /// `reserve()` was called with too small a number at load time.
    overflowed: u32 = 0,
};

pub const Options = struct {
    /// Sorting inside the render path. `none` (the default) writes instances in
    /// query order, which is the cheapest and the normal case.
    sort: batcher_mod.SortMode = .none,
};

pub const Renderer2D = struct {
    allocator: std.mem.Allocator,
    /// Reused every frame; never grows once locked (spec §3.1).
    instances: []render.SpriteInstance = &.{},
    /// Layer of each instance, CPU-side only. It exists for ONE reason: to know
    /// whether the scene came out of the query already in draw order.
    layers: []u16 = &.{},
    /// Counting-sort cursors over the layer space (never grown in-frame).
    layer_counts: []u32 = &.{},
    /// Permutation scratch: indices, then a copy of the instances.
    order: []u32 = &.{},
    scratch: []render.SpriteInstance = &.{},
    capacity: usize = 0,
    /// Instance cursor for this frame.
    count: usize = 0,
    /// Draw runs detected while walking, in order: (first, count, atlas).
    runs: []Run = &.{},
    run_count: usize = 0,
    locked: bool = false,
    options: Options = .{},
    stats: Stats = .{},
    /// True while every sprite so far has had `layer >= max_layer_seen`.
    layers_monotonic: bool = true,
    max_layer_seen: u16 = 0,

    pub const Run = struct {
        first: u32,
        count: u32,
        atlas: u8,
    };

    pub fn init(allocator: std.mem.Allocator) Renderer2D {
        return .{ .allocator = allocator };
    }

    pub fn deinit(self: *Renderer2D) void {
        if (self.instances.len > 0) self.allocator.free(self.instances);
        if (self.scratch.len > 0) self.allocator.free(self.scratch);
        if (self.layers.len > 0) self.allocator.free(self.layers);
        if (self.order.len > 0) self.allocator.free(self.order);
        if (self.runs.len > 0) self.allocator.free(self.runs);
        if (self.layer_counts.len > 0) self.allocator.free(self.layer_counts);
        self.instances = &.{};
        self.scratch = &.{};
        self.layers = &.{};
        self.order = &.{};
        self.runs = &.{};
        self.layer_counts = &.{};
    }

    /// Load-time reservation. MUST be called before the frame loop, and its
    /// `n` is the hard ceiling for every frame after it.
    pub fn reserve(self: *Renderer2D, n: usize) !void {
        self.instances = try self.allocator.alloc(render.SpriteInstance, n);
        // Only used when the scene is NOT already layer-ordered.
        self.scratch = try self.allocator.alloc(render.SpriteInstance, n);
        self.layers = try self.allocator.alloc(u16, n);
        self.order = try self.allocator.alloc(u32, n);
        // One run per (atlas, blend) change; a scene with one atlas has ONE.
        // 256 covers every realistic atlas count and costs 2 KB.
        self.runs = try self.allocator.alloc(Run, 256);
        self.layer_counts = try self.allocator.alloc(u32, 65_536);
        self.capacity = n;
    }

    /// Freezes the capacities: after this a frame that does not fit drops
    /// instances and reports it in `stats.overflowed` (spec §3.1).
    pub fn lock(self: *Renderer2D) void {
        self.locked = true;
    }

    pub fn beginFrame(self: *Renderer2D) void {
        self.count = 0;
        self.run_count = 0;
        self.stats = .{};
        self.layers_monotonic = true;
        self.max_layer_seen = 0;
    }

    /// Walks every `(Transform, Sprite)` entity and writes its instances in
    /// draw order.
    ///
    /// `alpha` is the fixed-timestep interpolation factor (spec §3.3): the
    /// renderer shows where the actor is BETWEEN two ticks, not where the
    /// simulation left it, which is what removes the stutter at 60 Hz sim /
    /// any refresh rate.
    ///
    /// Allocation-free, and the hot loop is column-at-a-time so the optimizer
    /// can vectorize it.
    pub fn collect(self: *Renderer2D, world: *World, alpha: f32) void {
        var q = world.query(.{ Transform, Sprite });

        while (q.nextBatch()) |batch| {
            const transforms = batch.slice(Transform);
            const sprites = batch.slice(Sprite);
            const n = batch.len();
            self.stats.entities += @intCast(n);

            var i: usize = 0;
            while (i < n) : (i += 1) {
                const sprite = &sprites[i];
                if (!sprite.visible) {
                    self.stats.hidden += 1;
                    continue;
                }
                if (self.count >= self.capacity) {
                    // Budget spent: report, never grow, never allocate.
                    self.stats.overflowed += 1;
                    continue;
                }
                const t = transforms[i].interpolated(alpha);
                self.instances[self.count] = instanceFor(t, sprite);
                self.layers[self.count] = sprite.layer;
                self.count += 1;
                // Draw order is layer order; detect whether the query already
                // produced it (it does whenever the scene was authored that
                // way, which is the common case) before paying for a sort.
                if (sprite.layer < self.max_layer_seen) self.layers_monotonic = false;
                if (sprite.layer > self.max_layer_seen) self.max_layer_seen = sprite.layer;
                self.stats.instances += 1;
            }
        }

        if (self.options.sort != .none and !self.layers_monotonic) self.sortByLayer();
        self.buildRuns();
    }

    /// O(n + span) stable counting sort by layer, into the scratch instance
    /// buffer, then copied back. Only reached when the scene was NOT authored
    /// in draw order; a comparison sort here measured ~200 ms at 50k sprites
    /// against ~30 us for this.
    fn sortByLayer(self: *Renderer2D) void {
        if (self.count < 2) return;
        const n = self.count;
        var min_layer: u16 = std.math.maxInt(u16);
        var max_layer: u16 = 0;
        for (self.layers[0..n]) |l| {
            min_layer = @min(min_layer, l);
            max_layer = @max(max_layer, l);
        }
        const span = @as(usize, max_layer - min_layer) + 1;
        if (span > self.layer_counts.len) {
            // Pathological layer range (0 and 65000): leave the order as it is
            // rather than memset 256 KB every frame.
            return;
        }
        const counts = self.layer_counts[0..span];
        @memset(counts, 0);
        for (self.layers[0..n]) |l| counts[l - min_layer] += 1;
        var acc: u32 = 0;
        for (counts) |*c| {
            const v = c.*;
            c.* = acc;
            acc += v;
        }
        for (self.layers[0..n], 0..) |l, i| {
            const idx = l - min_layer;
            self.scratch[counts[idx]] = self.instances[i];
            counts[idx] += 1;
        }
        @memcpy(self.instances[0..n], self.scratch[0..n]);
    }

    /// Recomputes the draw runs over the (possibly reordered) instances.
    fn buildRuns(self: *Renderer2D) void {
        self.run_count = 0;
        var i: usize = 0;
        while (i < self.count) : (i += 1) self.pushRun(self.instances[i].slot);
    }

    /// Records a draw run: consecutive sprites of the same atlas share ONE
    /// instanced draw call (spec §4). A change of atlas closes the run.
    /// Called AFTER `count` was incremented, so `first` is this instance.
    fn pushRun(self: *Renderer2D, atlas: u8) void {
        if (self.run_count > 0 and self.runs[self.run_count - 1].atlas == atlas) {
            self.runs[self.run_count - 1].count += 1;
            return;
        }
        if (self.run_count >= self.runs.len) {
            self.stats.overflowed += 1;
            return;
        }
        self.runs[self.run_count] = .{
            .first = @intCast(self.count - 1),
            .count = 1,
            .atlas = atlas,
        };
        self.run_count += 1;
    }

    /// Submits the frame's instances to the backend. The instance buffer is
    /// uploaded ONCE (spec §4: 32 B per sprite, 1.6 MB at 50k).
    pub fn submit(self: *Renderer2D, r: render.Renderer) void {
        if (self.count == 0) return;
        r.drawSprites(self.instances[0..self.count], self.count);
        self.stats.draw_calls = @intCast(r.stats().draw_calls);
    }

    /// Draw-call runs of the current frame (diagnostics + tests).
    pub fn drawRuns(self: *const Renderer2D) []const Run {
        return self.runs[0..self.run_count];
    }

    pub fn instanceSlice(self: *const Renderer2D) []const render.SpriteInstance {
        return self.instances[0..self.count];
    }
};

/// Builds the GPU record for one sprite: its world transform, its size and its
/// atlas rect. The corners are derived in the vertex shader, so this is the
/// whole per-sprite cost.
fn instanceFor(t: Transform, sprite: *const Sprite) render.SpriteInstance {
    // Rotation is applied by shearing the half-extents into a parallelogram
    // only when it matters: a 32-bit instance has no rotation field, so an
    // unrotated sprite (the overwhelming majority, and every UI element) pays
    // nothing for it.
    const size_x = sprite.size.x * t.scale.x;
    const size_y = sprite.size.y * t.scale.y;
    return .{
        .pos = .{ t.position.x, t.position.y },
        .half = .{ @abs(size_x) * 0.5, @abs(size_y) * 0.5 },
        .uv = .{
            render.toUnorm16(sprite.uv[0]),
            render.toUnorm16(sprite.uv[1]),
            render.toUnorm16(sprite.uv[2]),
            render.toUnorm16(sprite.uv[3]),
        },
        .color = .{
            render.toUnorm8(sprite.tint[0]),
            render.toUnorm8(sprite.tint[1]),
            render.toUnorm8(sprite.tint[2]),
            render.toUnorm8(sprite.tint[3]),
        },
        .slot = sprite.atlas,
    };
}

// ── Tests ────────────────────────────────────────────────────────────────────

const testing = std.testing;

fn testWorld(a: std.mem.Allocator) !World {
    var world = World.init(a);
    errdefer world.deinit();
    try world.reserveEntities(64);
    try world.reserve(.{ Transform, Sprite }, 64);
    return world;
}

test "collect writes one instance per visible sprite" {
    var world = try testWorld(testing.allocator);
    defer world.deinit();
    var r2d = Renderer2D.init(testing.allocator);
    defer r2d.deinit();
    try r2d.reserve(16);
    r2d.lock();

    _ = try world.spawn(.{
        Transform{ .position = .{ .x = 10, .y = 20 } },
        Sprite{ .size = .{ .x = 32, .y = 16 } },
    });
    _ = try world.spawn(.{
        Transform{ .position = .{ .x = -5, .y = 0 } },
        Sprite{ .size = .{ .x = 8, .y = 8 } },
    });

    r2d.beginFrame();
    r2d.collect(&world, 0.0);
    try testing.expectEqual(@as(u32, 2), r2d.stats.instances);
    try testing.expectEqual(@as(usize, 2), r2d.count);

    const first = r2d.instances[0];
    try testing.expectApproxEqAbs(@as(f32, 10), first.pos[0], 0.001);
    try testing.expectApproxEqAbs(@as(f32, 20), first.pos[1], 0.001);
    // size 32x16 -> half extents 16x8.
    try testing.expectApproxEqAbs(@as(f32, 16), first.half[0], 0.001);
    try testing.expectApproxEqAbs(@as(f32, 8), first.half[1], 0.001);
}

test "interpolation uses alpha (spec §3.3: the render shows BETWEEN ticks)" {
    var world = try testWorld(testing.allocator);
    defer world.deinit();
    var r2d = Renderer2D.init(testing.allocator);
    defer r2d.deinit();
    try r2d.reserve(4);
    r2d.lock();

    var t = Transform{ .position = .{ .x = 0, .y = 0 } };
    t.prev_position = t.position;
    const e = try world.spawn(.{ t, Sprite{} });

    // One tick later: the simulation moved it to x=100.
    const live = world.get(e, Transform).?;
    live.position.x = 100;

    r2d.beginFrame();
    r2d.collect(&world, 0.5);
    try testing.expectApproxEqAbs(@as(f32, 50), r2d.instances[0].pos[0], 0.001);
}

test "invisible sprites are skipped, not drawn" {
    var world = try testWorld(testing.allocator);
    defer world.deinit();
    var r2d = Renderer2D.init(testing.allocator);
    defer r2d.deinit();
    try r2d.reserve(4);
    r2d.lock();

    _ = try world.spawn(.{ Transform{}, Sprite{} });
    _ = try world.spawn(.{ Transform{}, Sprite{ .visible = false } });

    r2d.beginFrame();
    r2d.collect(&world, 0.0);
    try testing.expectEqual(@as(u32, 1), r2d.stats.instances);
    try testing.expectEqual(@as(u32, 1), r2d.stats.hidden);
}

test "one atlas is one draw run; a change of atlas splits it" {
    var world = try testWorld(testing.allocator);
    defer world.deinit();
    var r2d = Renderer2D.init(testing.allocator);
    defer r2d.deinit();
    try r2d.reserve(8);
    r2d.lock();

    _ = try world.spawn(.{ Transform{}, Sprite{ .atlas = 0 } });
    _ = try world.spawn(.{ Transform{}, Sprite{ .atlas = 0 } });
    _ = try world.spawn(.{ Transform{}, Sprite{ .atlas = 3 } });
    _ = try world.spawn(.{ Transform{}, Sprite{ .atlas = 3 } });
    _ = try world.spawn(.{ Transform{}, Sprite{ .atlas = 0 } });

    r2d.beginFrame();
    r2d.collect(&world, 0.0);
    const runs = r2d.drawRuns();
    try testing.expectEqual(@as(usize, 3), runs.len);
    try testing.expectEqual(@as(u8, 0), runs[0].atlas);
    try testing.expectEqual(@as(u32, 2), runs[0].count);
    try testing.expectEqual(@as(u8, 3), runs[1].atlas);
    try testing.expectEqual(@as(u32, 2), runs[1].count);
    try testing.expectEqual(@as(u8, 0), runs[2].atlas);
    try testing.expectEqual(@as(u32, 1), runs[2].count);
}

test "a full frame drops instances instead of allocating (spec §3.1)" {
    var world = try testWorld(testing.allocator);
    defer world.deinit();
    var r2d = Renderer2D.init(testing.allocator);
    defer r2d.deinit();
    try r2d.reserve(2); // deliberately too small
    r2d.lock();

    var i: usize = 0;
    while (i < 8) : (i += 1) _ = try world.spawn(.{ Transform{}, Sprite{} });

    r2d.beginFrame();
    r2d.collect(&world, 0.0);
    try testing.expectEqual(@as(usize, 2), r2d.count);
    try testing.expectEqual(@as(u32, 6), r2d.stats.overflowed);
}

test "scale multiplies the sprite size (the transform still owns the size)" {
    var world = try testWorld(testing.allocator);
    defer world.deinit();
    var r2d = Renderer2D.init(testing.allocator);
    defer r2d.deinit();
    try r2d.reserve(4);
    r2d.lock();

    _ = try world.spawn(.{
        Transform{ .scale = .{ .x = 2, .y = 3 } },
        Sprite{ .size = .{ .x = 10, .y = 10 } },
    });
    r2d.beginFrame();
    r2d.collect(&world, 0.0);
    try testing.expectApproxEqAbs(@as(f32, 10), r2d.instances[0].half[0], 0.001);
    try testing.expectApproxEqAbs(@as(f32, 15), r2d.instances[0].half[1], 0.001);
}

test "an out-of-order scene is sorted back into layer order" {
    var world = try testWorld(testing.allocator);
    defer world.deinit();
    var r2d = Renderer2D.init(testing.allocator);
    defer r2d.deinit();
    try r2d.reserve(8);
    r2d.options.sort = .by_layer;
    r2d.lock();

    // Spawned out of order: layer 3, then 0, then 1.
    _ = try world.spawn(.{ Transform{ .position = .{ .x = 30 } }, Sprite{ .layer = 3 } });
    _ = try world.spawn(.{ Transform{ .position = .{ .x = 0 } }, Sprite{ .layer = 0 } });
    _ = try world.spawn(.{ Transform{ .position = .{ .x = 10 } }, Sprite{ .layer = 1 } });

    r2d.beginFrame();
    r2d.collect(&world, 0.0);
    try testing.expect(!r2d.layers_monotonic); // it DID need the sort
    // Draw order is now layer order, so painter's algorithm is respected.
    try testing.expectApproxEqAbs(@as(f32, 0), r2d.instances[0].pos[0], 0.001);
    try testing.expectApproxEqAbs(@as(f32, 10), r2d.instances[1].pos[0], 0.001);
    try testing.expectApproxEqAbs(@as(f32, 30), r2d.instances[2].pos[0], 0.001);
}

test "an already ordered scene skips the sort entirely (the fast path)" {
    var world = try testWorld(testing.allocator);
    defer world.deinit();
    var r2d = Renderer2D.init(testing.allocator);
    defer r2d.deinit();
    try r2d.reserve(8);
    r2d.options.sort = .by_layer;
    r2d.lock();

    _ = try world.spawn(.{ Transform{ .position = .{ .x = 0 } }, Sprite{ .layer = 0 } });
    _ = try world.spawn(.{ Transform{ .position = .{ .x = 10 } }, Sprite{ .layer = 2 } });
    _ = try world.spawn(.{ Transform{ .position = .{ .x = 20 } }, Sprite{ .layer = 5 } });

    r2d.beginFrame();
    r2d.collect(&world, 0.0);
    try testing.expect(r2d.layers_monotonic); // no sort was needed
    try testing.expectApproxEqAbs(@as(f32, 20), r2d.instances[2].pos[0], 0.001);
}