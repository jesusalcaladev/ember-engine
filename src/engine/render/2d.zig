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
    /// Entities skipped because the texture they sample is not resident.
    ///
    /// Separate from `culled` because it means something different and needs a
    /// different response: a frustum-culled sprite will come back when the
    /// camera moves, a sprite whose atlas page was evicted will come back when
    /// the page is. Streaming systems that conflate the two produce "the
    /// background vanished and we do not know why".
    not_resident: u32 = 0,
    /// Entities skipped because they are outside the camera.
    ///
    /// Reported separately from `hidden` on purpose: a hidden sprite is a
    /// DECISION somebody made, and a culled one is the engine saving you work.
    /// A scene where `culled` is zero is a scene paying to draw a world nobody
    /// can see, which is the thing this whole mechanism exists to stop.
    culled: u32 = 0,
};

/// The camera's view, in world units.
///
/// In 2D a frustum is a rectangle, which makes culling exactly a rectangle test
/// against a sprite's bounds — no matrix, no plane extraction. That is the one
/// place 2D is genuinely simpler than 3D rather than merely different.
pub const ViewRect = struct {
    min_x: f32,
    min_y: f32,
    max_x: f32,
    max_y: f32,

    /// The camera's view, expanded so a sprite just off the edge is still drawn.
    ///
    /// The margin is not decoration. Without it a sprite walking right is culled
    /// on the frame before it is on screen, and at 60 Hz that is a visible pop
    /// at the edge of the display.
    pub fn around(cx: f32, cy: f32, half_w: f32, half_h: f32, margin: f32) ViewRect {
        return .{
            .min_x = cx - half_w - margin,
            .min_y = cy - half_h - margin,
            .max_x = cx + half_w + margin,
            .max_y = cy + half_h + margin,
        };
    }

    /// Whether a sprite centred here with these half-extents can be seen.
    ///
    /// The cheap reject is half the test: a sprite whose CENTRE is outside the
    /// view cannot possibly touch it, and that is four comparisons before any
    /// size is considered. The full test then only runs for sprites near the
    /// edge, which is a handful.
    pub fn sees(self: ViewRect, x: f32, y: f32, half_w: f32, half_h: f32) bool {
        if (x + half_w < self.min_x or x - half_w > self.max_x) return false;
        if (y + half_h < self.min_y or y - half_h > self.max_y) return false;
        return true;
    }
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
        self.collectInView(world, alpha, null);
    }

    /// Collects only what the camera can see.
    ///
    /// `view` is null when there is no camera — a tool, a test, a server drawing
    /// a minimap of something that is not on screen. Then everything is drawn,
    /// because culling against a zero-sized view would make the world invisible
    /// and report success.
    pub fn collectInView(self: *Renderer2D, world: *World, alpha: f32, view: ?ViewRect) void {
        self.collectFiltered(world, alpha, view, null);
    }

    /// Collects with an extra test: which atlas slots currently hold a resident
    /// texture.
    ///
    /// `resident` is a 256-bit mask indexed by the sprite's atlas slot, because
    /// that is the whole set of things a streaming system knows about — a page
    /// is loaded or it is not. Null means "everything is resident", which is
    /// what a machine with no streaming wants and what a headless test gets.
    ///
    /// The reason this belongs HERE and not in the batcher: the batcher sees
    /// instances, which have already been written, and by then the work of
    /// transforming an entity into an instance has been paid. Culling a sprite
    /// nobody can see should cost nothing at all.
    pub fn collectFiltered(
        self: *Renderer2D,
        world: *World,
        alpha: f32,
        view: ?ViewRect,
        resident: ?*const [4]u64,
    ) void {
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
                // Texture residency. Checked before the frustum because it is
                // one mask lookup, and before the capacity check because a
                // sprite whose page is gone must not occupy instance budget.
                if (resident) |mask| {
                    const word = sprite.atlas >> 6;
                    const bit: u6 = @intCast(sprite.atlas & 63);
                    if ((mask[word] & (@as(u64, 1) << bit)) == 0) {
                        self.stats.not_resident += 1;
                        continue;
                    }
                }
                // Frustum cull. Done before the capacity check and before the
                // interpolation work, because a culled sprite should cost four
                // comparisons and nothing else -- it must never reach the point
                // where the renderer considers writing it.
                if (view) |v| {
                    // Exactly the quad `instanceFor` will build: the Transform's
                    // scale multiplies the sprite's size, and the quad is centred
                    // on the transform. Culling anything else would either pop
                    // sprites at the edge or cull things that are on screen.
                    const t = &transforms[i];
                    const half_w = @abs(sprite.size.x * t.scale.x) * 0.5;
                    const half_h = @abs(sprite.size.y * t.scale.y) * 0.5;
                    if (!v.sees(t.position.x, t.position.y, half_w, half_h)) {
                        self.stats.culled += 1;
                        continue;
                    }
                }
                if (self.count >= self.capacity) {
                    // Budget spent: report, never grow, never allocate.
                    self.stats.overflowed += 1;
                    continue;
                }
                const t = transforms[i].interpolated(alpha);
                self.instances[self.count] = instanceFor(t, sprite);
                // The shape rides in the instance's former padding byte; see
                // SpriteInstance for why it is not a field of its own.
                self.instances[self.count].shape = @intFromEnum(sprite.shape);
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
        .shape = @intFromEnum(sprite.shape),
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

// ── Frustum culling ───────────────────────────────────────────────────────────
//
// Culling that is never checked is culling that does not exist. These prove it
// removes work AND does not remove things that should be drawn — the second half
// is the one that matters, because a culler that is too aggressive produces an
// empty screen and still "passes" a test that only counts.

test "a sprite off the view is culled and a sprite on it is not" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var world = World.init(allocator);
    defer world.deinit();

    // One far away, one in the middle of the view.
    _ = try world.spawn(.{ Transform{ .position = .{ .x = 10_000, .y = 0 } }, components.Sprite{} });
    _ = try world.spawn(.{ Transform{ .position = .{ .x = 0, .y = 0 } }, components.Sprite{} });

    var r = Renderer2D.init(allocator);
    defer r.deinit();
    try r.reserve(16);

    const view = ViewRect.around(0, 0, 100, 100, 0);
    r.collectInView(&world, 0.0, view);

    try testing.expectEqual(@as(u32, 1), r.stats.instances);
    try testing.expectEqual(@as(u32, 1), r.stats.culled);
    try testing.expectEqual(@as(u32, 2), r.stats.entities);
}

test "no camera draws everything" {
    // A tool, a test, a minimap of somewhere else on screen: culling against a
    // zero-sized view would make the world invisible and report success.
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var world = World.init(allocator);
    defer world.deinit();
    var i: usize = 0;
    while (i < 5) : (i += 1) {
        _ = try world.spawn(.{ Transform{ .position = .{ .x = @as(f32, @floatFromInt(i)) * 9999, .y = 0 } }, components.Sprite{} });
    }

    var r = Renderer2D.init(allocator);
    defer r.deinit();
    try r.reserve(16);
    r.collect(&world, 0.0);
    try testing.expectEqual(@as(u32, 5), r.stats.instances);
    try testing.expectEqual(@as(u32, 0), r.stats.culled);
}

test "the margin keeps a sprite that is about to enter the view" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var world = World.init(allocator);
    defer world.deinit();

    // Just past the right edge: not visible, but about to be.
    _ = try world.spawn(.{ Transform{ .position = .{ .x = 110, .y = 0 } }, components.Sprite{} });

    var r = Renderer2D.init(allocator);
    defer r.deinit();
    try r.reserve(16);

    r.collectInView(&world, 0.0, ViewRect.around(0, 0, 100, 100, 0));
    try testing.expectEqual(@as(u32, 0), r.stats.instances);

    r.stats = .{};
    r.collectInView(&world, 0.0, ViewRect.around(0, 0, 100, 100, 32));
    try testing.expectEqual(@as(u32, 1), r.stats.instances);
}

test "a scaled sprite is culled by its scaled size, not its base one" {
    // The bounds the culler uses must be the quad the renderer actually builds.
    // Testing it against the unscaled size is how a giant background gets culled
    // while covering the whole screen.
    const tight = ViewRect{ .min_x = -10, .min_y = -10, .max_x = 10, .max_y = 10 };

    // A sprite much LARGER than the view, centred on it, is VISIBLE. Culling it
    // would blank the screen for a background that covers everything, which is
    // the classic way a frustum test gets its inequality backwards.
    try testing.expect(tight.sees(0, 0, 100, 100));

    try testing.expect(tight.sees(0, 0, 5, 5)); // small, centred
    try testing.expect(tight.sees(8, 0, 5, 5)); // hanging off the right edge
    try testing.expect(tight.sees(-9, 0, 5, 5)); // hanging off the left

    // Only a sprite whose bounds MISS the view entirely is culled. The margin
    // matters here: without it, the two above would pop at the screen edge.
    try testing.expect(!tight.sees(20, 0, 5, 5));
    try testing.expect(!tight.sees(0, 30, 5, 5));
}

test "a sprite on an evicted atlas page is skipped, not drawn" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var world = World.init(allocator);
    defer world.deinit();

    // One sprite on page 0 (resident) and one on page 100 (evicted).
    _ = try world.spawn(.{
        Transform{ .position = .{ .x = 0, .y = 0 } },
        components.Sprite{ .atlas = 0 },
    });
    _ = try world.spawn(.{
        Transform{ .position = .{ .x = 10, .y = 0 } },
        components.Sprite{ .atlas = 100 },
    });

    var r = Renderer2D.init(allocator);
    defer r.deinit();
    try r.reserve(16);

    // Everything resident: both draw.
    r.collectFiltered(&world, 0.0, null, null);
    try testing.expectEqual(@as(u32, 2), r.stats.instances);
    try testing.expectEqual(@as(u32, 0), r.stats.not_resident);

    // Page 100 evicted. It is reported SEPARATELY from a frustum cull, because
    // the two recover differently: one clears when the camera moves, the other
    // when the page is read back in.
    r.stats = .{};
    var mask = [4]u64{ 1, 1, 1, 1 };
    mask[100 >> 6] &= ~(@as(u64, 1) << @as(u6, @intCast(100 & 63)));
    r.collectFiltered(&world, 0.0, null, &mask);

    try testing.expectEqual(@as(u32, 1), r.stats.instances);
    try testing.expectEqual(@as(u32, 1), r.stats.not_resident);
    try testing.expectEqual(@as(u32, 0), r.stats.culled);
}
