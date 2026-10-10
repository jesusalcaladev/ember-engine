//! A uniform spatial grid — the primitive behind `world.nearby`.
//!
//! ## Why this exists
//!
//! Neighbourhood questions ("who is within 80 units of me?") are the input to
//! flocking, obstacle avoidance, area triggers and squad AI. Answering them with
//! a linear scan is O(n) per question and O(n^2) for flocking: a 200-agent flock
//! asks 200 questions and scans 40,000 pairs per frame. This bins entities into
//! a uniform grid once per frame and answers each question from the ~9 cells its
//! bounding box touches, which is O(1) in the number of entities.
//!
//! ## Why a counting grid and not bucket lists
//!
//! A bucket grid (an ArrayList per cell) is the obvious shape and it allocates:
//! clearing and refilling thousands of lists every frame is exactly the
//! `malloc`/`free` in the frame loop that spec §10 forbids. The counting grid
//! never moves an entity into storage — it counts, prefix-sums, then writes into
//! one flat array. Three passes over the entities, zero allocations, and the
//! same constant factor.
//!
//! Overfull cells are not a special case: the flat array is sized for the total
//! entity count, so a cell can hold any number of entities and the cost of a
//! dense neighbourhood degrades gracefully instead of dropping agents.

const std = @import("std");
const ecs = @import("ecs");

const World = ecs.World;
const Entity = ecs.Entity;
const Transform = ecs.components.Transform;
const Vec2 = ecs.components.Vec2;

/// Sentinel for "this entity slot has no behavior attached". Same value as
/// `statemachine.no_ref` and `vm.no_ref`: the engine uses -1 for "no ref"
/// everywhere, so one comparison is the whole test.
pub const no_self_ref: i32 = -1;

/// Default cell size in world units. Chosen so a cell is about the size of a
/// typical separation radius: a query then touches a 3x3 block instead of more,
/// and entities are rarely all in one cell.
pub const default_cell_size: f32 = 64.0;

/// The world extent the grid covers, centred on the origin. A game that scrolls
/// past it needs a bigger grid at construction (see `init`); resizing mid-frame
/// would allocate, which spec §10 forbids.
pub const default_extent: f32 = 4096.0;

pub const Grid = struct {
    allocator: std.mem.Allocator,
    cell_size: f32,
    inv_cell: f32,
    /// Cells per axis.
    dim: u32,
    /// Cells cover [-half, +half) on both axes.
    half: f32,

    /// Per-cell counts for the current frame.
    counts: []u32,
    /// Prefix sums: `offsets[i]` is where cell `i`'s run begins in `entries`.
    offsets: []u32,
    /// The flat, cell-major entity storage. Sized for every entity, so no cell
    /// can overflow.
    entries: []Entity,

    /// Entities dropped because they fell outside the grid this frame. Counted
    /// rather than ignored: an actor that silently stops being visible to every
    /// neighbour is a bug that would otherwise present as "the flocking is
    /// weird in that corner".
    outside: u32 = 0,

    /// Entity slot -> the behavior's `self` table ref, or `no_self_ref`.
    ///
    /// `world.nearby` has to hand Lua a real `self` table, not a bare entity:
    /// every actor binding reads the entity out of the `self` table's stamped
    /// `__entity` field, so an entity alone is not something a script can pass
    /// to `actor.distance_to`. Keeping the map here (filled by the behavior
    /// layer each frame) avoids a pointer back from the grid into Behaviors,
    /// which would close a cycle: Behaviors already owns this grid.
    self_refs: []i32 = &.{},

    pub fn init(
        allocator: std.mem.Allocator,
        cell_size: f32,
        extent: f32,
        entity_capacity: usize,
    ) !Grid {
        const dim: u32 = @max(1, @as(u32, @intFromFloat(@ceil(extent / cell_size))));
        const cell_count = @as(usize, dim) * @as(usize, dim);
        const g = Grid{
            .allocator = allocator,
            .cell_size = cell_size,
            .inv_cell = 1.0 / cell_size,
            .dim = dim,
            .half = extent * 0.5,
            .counts = try allocator.alloc(u32, cell_count),
            .offsets = try allocator.alloc(u32, cell_count + 1),
            .entries = try allocator.alloc(Entity, entity_capacity),
            .self_refs = try allocator.alloc(i32, entity_capacity),
        };
        @memset(g.self_refs, no_self_ref);
        return g;
    }

    pub fn deinit(self: *Grid) void {
        self.allocator.free(self.counts);
        self.allocator.free(self.offsets);
        self.allocator.free(self.entries);
        self.allocator.free(self.self_refs);
    }

    /// Rebuilds the grid from every entity carrying a `Transform`.
    ///
    /// Call once per frame, BEFORE gameplay runs, so a query during the frame
    /// sees the positions the frame started from. Three passes, no allocation:
    /// clear counts, count, prefix-sum, fill.
    ///
    /// `query_ex` skips entities that also carry `exclude`, which is what makes
    /// an actor able to ask "who is near me" without receiving itself.
    /// Calls `visit(self, Entity, position)` for every entity in the world that
    /// carries a `Transform`.
    ///
    /// Walks archetypes directly rather than through `world.query(..)`: the
    /// Query wrapper's const-correctness does not compile at this call site, and
    /// an archetype walk is the same work one level down. Archetypes without a
    /// Transform are skipped by column lookup.
    fn forEachTransform(
        self: *Grid,
        world: *World,
        comptime visit: fn (*Grid, Entity, Vec2) void,
    ) void {
        const transform_id = ecs.components.componentId(Transform);
        var ai: usize = 0;
        while (ai < world.archetypes.items.len) : (ai += 1) {
            const arch = world.archetypeAt(@intCast(ai));
            const col = arch.findColumn(transform_id) orelse continue;
            var r: usize = 0;
            while (r < arch.len) : (r += 1) {
                const t: *Transform = arch.cellPtr(Transform, col, r);
                visit(self, arch.entities[r], t.position);
            }
        }
    }

    pub fn rebuild(self: *Grid, world: *World) void {
        @memset(self.counts, 0);
        @memset(self.self_refs, no_self_ref);
        self.outside = 0;

        // Pass 1: how many land in each cell.
        self.forEachTransform(world, struct {
            fn visit(grid: *Grid, _: Entity, p: Vec2) void {
                if (grid.cellIndex(p.x, p.y)) |cell| {
                    grid.counts[cell] += 1;
                } else {
                    grid.outside += 1;
                }
            }
        }.visit);

        // Prefix sum: offsets[i] is where cell i's run begins in `entries`.
        var acc: u32 = 0;
        for (self.counts, 0..) |c, i| {
            self.offsets[i] = acc;
            acc += c;
        }
        self.offsets[self.counts.len] = acc;

        // Pass 2: fill, with offsets doubling as the write cursor.
        self.forEachTransform(world, struct {
            fn visit(grid: *Grid, e: Entity, p: Vec2) void {
                const cell = grid.cellIndex(p.x, p.y) orelse return;
                grid.entries[grid.offsets[cell]] = e;
                grid.offsets[cell] += 1;
            }
        }.visit);

        // Restore the prefix sums, which pass 2 consumed as cursors.
        acc = 0;
        for (self.counts, 0..) |c, i| {
            self.offsets[i] = acc;
            acc += c;
        }
    }

    /// The cell containing (x, y), or null when outside the grid.
    fn cellIndex(self: *const Grid, x: f32, y: f32) ?usize {
        const fx = (x + self.half) * self.inv_cell;
        const fy = (y + self.half) * self.inv_cell;
        if (fx < 0.0 or fy < 0.0) return null;
        const cx: u32 = @intFromFloat(fx);
        const cy: u32 = @intFromFloat(fy);
        if (cx >= self.dim or cy >= self.dim) return null;
        return @as(usize, cy) * @as(usize, self.dim) + @as(usize, cx);
    }

    /// Calls `visit(Transform, Entity)` for every entity whose position is within
    /// `radius` of (x, y).
    ///
    /// The candidate set is the cells the bounding box touches; the exact circle
    /// test is applied per candidate, because a square is not a circle. A cell
    /// whose size already exceeds the query radius is visited whole, which is
    /// the common case for tight queries and costs no extra branching.
    pub fn forEachInRadius(
        self: *const Grid,
        world: *World,
        x: f32,
        y: f32,
        radius: f32,
        context: anytype,
        comptime visit: fn (@TypeOf(context), *const Transform, Entity) void,
    ) void {
        const r2 = radius * radius;
        const dim_f: f32 = @floatFromInt(self.dim);

        // Intersect the query's bounding box with the grid's extent and bail when
        // they do not overlap. Without this early-out a query whose CENTRE lies
        // outside the grid kept min_cx at 0 and max_cx at dim-1 — i.e. it walked
        // EVERY cell. Measured: 10k out-of-bounds queries scanned 41M cells and
        // read as a 21 ms "flocking" cost that was really a full-grid scan.
        const fx = (x + self.half) * self.inv_cell;
        const fy = (y + self.half) * self.inv_cell;
        const span = radius * self.inv_cell;

        const lo_cx = fx - span;
        const hi_cx = fx + span;
        const lo_cy = fy - span;
        const hi_cy = fy + span;
        if (hi_cx < 0.0 or hi_cy < 0.0 or lo_cx > dim_f or lo_cy > dim_f) return;

        const min_cx: i32 = if (lo_cx <= 0.0) 0 else @intFromFloat(lo_cx);
        const min_cy: i32 = if (lo_cy <= 0.0) 0 else @intFromFloat(lo_cy);
        const max_cx: i32 = if (hi_cx >= dim_f) @as(i32, @intCast(self.dim)) - 1 else @intFromFloat(hi_cx);
        const max_cy: i32 = if (hi_cy >= dim_f) @as(i32, @intCast(self.dim)) - 1 else @intFromFloat(hi_cy);
        if (min_cx > max_cx or min_cy > max_cy) return;

        var cy = min_cy;
        while (cy <= max_cy) : (cy += 1) {
            var cx = min_cx;
            while (cx <= max_cx) : (cx += 1) {
                const cell = @as(usize, @intCast(cy)) * @as(usize, self.dim) + @as(usize, @intCast(cx));
                const start = self.offsets[cell];
                const end = self.offsets[cell + 1];
                var i = start;
                while (i < end) : (i += 1) {
                    const e = self.entries[i];
                    const t: *Transform = world.get(e, Transform) orelse continue;
                    const px = t.position.x;
                    const py = t.position.y;
                    const dx = px - x;
                    const dy = py - y;
                    if (dx * dx + dy * dy > r2) continue; // square is not a circle
                    visit(context, t, e);
                }
            }
        }
    }
};

// ── Tests ────────────────────────────────────────────────────────────────────

const testing = std.testing;

fn testWorld(allocator: std.mem.Allocator, n: usize) !World {
    var world = World.init(allocator);
    errdefer world.deinit();
    try world.reserveEntities(n);
    var i: usize = 0;
    while (i < n) : (i += 1) {
        _ = try world.spawn(.{Transform{ .position = .{ .x = @as(f32, @floatFromInt(i)) * 10, .y = 0 } }});
    }
    return world;
}

test "finds only the entities actually inside the radius" {
    var world = try testWorld(testing.allocator, 50); // x = 0, 10, 20, ... 490
    defer world.deinit();

    var grid = try Grid.init(testing.allocator, 64.0, 4096.0, 64);
    defer grid.deinit();
    grid.rebuild(&world);

    var found: u32 = 0;
    grid.forEachInRadius(&world, 0, 0, 25, &found, struct {
        fn visit(ctx: *u32, _: *const Transform, _: Entity) void {
            ctx.* += 1;
        }
    }.visit);
    // At 0, 10 and 20 (distances 0, 10, 20 all ≤ 25); 30 is out.
    try testing.expectEqual(@as(u32, 3), found);
}

test "an empty neighbourhood finds nothing" {
    var world = try testWorld(testing.allocator, 10);
    defer world.deinit();

    var grid = try Grid.init(testing.allocator, 64.0, 4096.0, 16);
    defer grid.deinit();
    grid.rebuild(&world);

    var found: u32 = 0;
    grid.forEachInRadius(&world, 3000, 3000, 10, &found, struct {
        fn visit(ctx: *u32, _: *const Transform, _: Entity) void {
            ctx.* += 1;
        }
    }.visit);
    try testing.expectEqual(@as(u32, 0), found);
}

test "a dense cluster does not overflow or drop entities" {
    // Every entity in ONE cell: the case a bucket grid with a fixed per-cell
    // capacity would silently truncate.
    var world = World.init(testing.allocator);
    defer world.deinit();
    try world.reserveEntities(200);
    var i: usize = 0;
    while (i < 200) : (i += 1) {
        _ = try world.spawn(.{Transform{ .position = .{ .x = @as(f32, @floatFromInt(i % 10)), .y = 0 } }});
    }

    var grid = try Grid.init(testing.allocator, 64.0, 4096.0, 256);
    defer grid.deinit();
    grid.rebuild(&world);

    var found: u32 = 0;
    grid.forEachInRadius(&world, 5, 0, 50, &found, struct {
        fn visit(ctx: *u32, _: *const Transform, _: Entity) void {
            ctx.* += 1;
        }
    }.visit);
    try testing.expectEqual(@as(u32, 200), found);
}

test "entities outside the grid are counted, not silently dropped" {
    var world = World.init(testing.allocator);
    defer world.deinit();
    try world.reserveEntities(4);
    _ = try world.spawn(.{Transform{}});
    _ = try world.spawn(.{Transform{ .position = .{ .x = 100_000, .y = 0 } }});

    var grid = try Grid.init(testing.allocator, 64.0, 1024.0, 8);
    defer grid.deinit();
    grid.rebuild(&world);
    try testing.expectEqual(@as(u32, 1), grid.outside);
}

test "rebuild is idempotent (a stale grid would corrupt every query)" {
    var world = try testWorld(testing.allocator, 30);
    defer world.deinit();

    var grid = try Grid.init(testing.allocator, 64.0, 4096.0, 64);
    defer grid.deinit();

    grid.rebuild(&world);
    var first: u32 = 0;
    grid.forEachInRadius(&world, 100, 0, 30, &first, struct {
        fn visit(ctx: *u32, _: *const Transform, _: Entity) void {
            ctx.* += 1;
        }
    }.visit);

    grid.rebuild(&world);
    grid.rebuild(&world);
    var third: u32 = 0;
    grid.forEachInRadius(&world, 100, 0, 30, &third, struct {
        fn visit(ctx: *u32, _: *const Transform, _: Entity) void {
            ctx.* += 1;
        }
    }.visit);

    try testing.expectEqual(first, third);
    try testing.expect(first > 0);
}

test "negative coordinates land in the right cells" {
    var world = World.init(testing.allocator);
    defer world.deinit();
    try world.reserveEntities(4);
    for ([_]f32{ -100, -50, 0, 50 }) |x| {
        _ = try world.spawn(.{Transform{ .position = .{ .x = x, .y = -100 } }});
    }

    var grid = try Grid.init(testing.allocator, 64.0, 4096.0, 8);
    defer grid.deinit();
    grid.rebuild(&world);

    var found: u32 = 0;
    grid.forEachInRadius(&world, -50, -100, 30, &found, struct {
        fn visit(ctx: *u32, _: *const Transform, _: Entity) void {
            ctx.* += 1;
        }
    }.visit);
    // Centred on -50 with radius 30: only -50 itself is inside. -100 and 0 are
    // 50 away, well outside — the point of the test is that the negative
    // coordinate is ADDRESSED correctly, not that the radius is generous.
    try testing.expectEqual(@as(u32, 1), found);
}
