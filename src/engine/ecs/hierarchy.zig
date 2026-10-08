//! Hierarchy: parent chains resolved by a flat system (no recursion).
//!
//! The engine stores exactly one fact per entity (`Parent.parent`); everything
//! else is *derived*, once per frame, in memory laid out for that:
//!
//! 1. Every entity with a `Transform` seeds its world transform from its
//!    local one.
//! 2. Parent links become a CSR adjacency (children grouped by parent) built
//!    in two linear passes: count, prefix-sum, fill.
//! 3. A queue walks the forest breadth-first, folding each child into its
//!    parent's world transform. No recursion (a 10k-deep chain cannot blow the
//!    stack), no per-frame allocation, no scanning: O(entities).
//!
//! Why not store a world transform per entity: it would be a second copy of
//! the authoritative state, needing a structural change (and a spike) every
//! time a parent link changed. Deriving keeps `.zson` documents minimal and
//! bit-exact (spec §6) and keeps hierarchy edits free of archetype churn.
//!
//! Cycles (a parent of its own descendant) and dead parents are not errors:
//! the link is ignored for that pass, which is also what the debug log warns
//! about.

const std = @import("std");
const log = @import("core").log;
const core_math = @import("core").math;
const components = @import("components.zig");
const entity = @import("entity.zig");

pub const Entity = entity.Entity;

/// Composed transform in world space (renderers read this, never the local one).
pub const WorldTransform = struct {
    position: core_math.Vec2,
    rotation: f32 = 0,
    scale: core_math.Vec2,

    pub const identity = WorldTransform{
        .position = .{ .x = 0, .y = 0 },
        .rotation = 0,
        .scale = .{ .x = 1, .y = 1 },
    };
};

const scoped = log.scoped("hierarchy");

pub const Hierarchy = struct {
    /// Scratch is only allocated once opted in (load time).
    enabled: bool = false,
    /// Slots the arrays can index.
    capacity: usize = 0,
    /// Derived world transform per slot index.
    world: []WorldTransform = &.{},
    /// Children CSR: children of `p` live in `children[starts[p+1]..starts[p]]`
    /// (descending prefix sums, `starts[capacity]` is the zero sentinel).
    starts: []u32 = &.{},
    /// Fill cursors while building the CSR (copy of `starts`).
    fill: []u32 = &.{},
    children: []u32 = &.{},
    /// Breadth-first queue over slot indices.
    queue: []u32 = &.{},
    /// Stamped "this slot is somebody's child this pass" (O(1) reset).
    child_stamp: []u32 = &.{},
    /// Stamped "this slot's child count is initialised this pass".
    parent_stamp: []u32 = &.{},
    stamp_now: u32 = 0,
    /// Statistics for the memory report (spec §5).
    last_resolved: usize = 0,

    const Self = @This();

    /// Allocates every scratch array for `capacity` slots. Called from
    /// `World.enableHierarchy`/`reserveEntities`, i.e. outside the frame.
    pub fn reserve(self: *Self, allocator: std.mem.Allocator, capacity: usize) !void {
        if (capacity <= self.capacity) return;
        const n = capacity + 1; // room for the descending-prefix sentinel
        const world = try allocator.alignedAlloc(WorldTransform, .of(WorldTransform), capacity);
        errdefer allocator.free(world);
        const starts = try allocator.alloc(u32, n);
        errdefer allocator.free(starts);
        const fill = try allocator.alloc(u32, n);
        errdefer allocator.free(fill);
        const children = try allocator.alloc(u32, n);
        errdefer allocator.free(children);
        const queue = try allocator.alloc(u32, n);
        errdefer allocator.free(queue);
        const child_stamp = try allocator.alloc(u32, n);
        errdefer allocator.free(child_stamp);
        const parent_stamp = try allocator.alloc(u32, n);
        errdefer allocator.free(parent_stamp);

        self.release(allocator);
        self.world = world;
        self.starts = starts;
        self.fill = fill;
        self.children = children;
        self.queue = queue;
        self.child_stamp = child_stamp;
        self.parent_stamp = parent_stamp;
        self.capacity = capacity;
        @memset(child_stamp, 0);
        @memset(parent_stamp, 0);
        self.stamp_now = 0;
    }

    /// Frees the scratch but keeps `enabled`: that is opt-in state, not memory.
    pub fn release(self: *Self, allocator: std.mem.Allocator) void {
        if (self.capacity > 0) {
            allocator.free(self.world);
            allocator.free(self.starts);
            allocator.free(self.fill);
            allocator.free(self.children);
            allocator.free(self.queue);
            allocator.free(self.child_stamp);
            allocator.free(self.parent_stamp);
        }
        self.capacity = 0;
        self.world = &.{};
        self.starts = &.{};
        self.fill = &.{};
        self.children = &.{};
        self.queue = &.{};
        self.child_stamp = &.{};
        self.parent_stamp = &.{};
    }

    pub fn deinit(self: *Self, allocator: std.mem.Allocator) void {
        self.release(allocator);
    }

    // ── Resolution ──────────────────────────────────────────────────────────

    /// Resolves every parent chain in the world. Flat, iterative, allocation
    /// free; expects the scratch to be reserved (see `World.enableHierarchy`).
    /// `world` is duck-typed to avoid a dependency cycle with `world.zig`.
    pub fn resolve(self: *Self, world: anytype) void {
        std.debug.assert(self.enabled);
        if (self.capacity == 0) return;

        // O(1) pass reset: bumping the stamp invalidates every previous one.
        self.stamp_now += 1;
        if (self.stamp_now == 0) {
            @memset(self.parent_stamp, 0);
            self.stamp_now = 1;
        }

        var transform_count: usize = 0;
        var q = world.query(.{components.Transform});
        while (q.nextBatch()) |batch| {
            const locals = batch.slice(components.Transform);
            const entities = batch.entitySlice();
            transform_count += locals.len;
            for (entities, locals) |e, local| self.world[e.index] = .{
                .position = local.position,
                .rotation = local.rotation,
                .scale = local.scale,
            };
        }

        // Count children per parent and mark the children with this stamp.
        var edge_count: usize = 0;
        var parents = world.query(.{components.Parent, components.Transform});
        while (parents.nextBatch()) |batch| {
            const parent_components = batch.slice(components.Parent);
            const entities = batch.entitySlice();
            for (entities, parent_components) |e, link| {
                if (!world.isAlive(link.parent) or link.parent.eql(e)) continue;
                if (world.get(link.parent, components.Transform) == null) continue;
                const p = link.parent.index;
                self.child_stamp[e.index] = self.stamp_now; // e is somebody's child
                if (self.parent_stamp[p] != self.stamp_now) {
                    self.parent_stamp[p] = self.stamp_now;
                    self.starts[p] = 0;
                }
                self.starts[p] += 1; // children of p
                edge_count += 1;
            }
        }

        // Descending prefix sums: starts[p] becomes the exclusive end and
        // starts[p+1] the first child, which makes the queue walk below trivial.
        const used = @min(world.slotCount(), self.starts.len - 1);
        self.starts[used] = 0;
        var p: usize = used;
        while (p > 0) {
            p -= 1;
            const count = if (self.parent_stamp[p] == self.stamp_now) self.starts[p] else 0;
            self.starts[p] = count + self.starts[p + 1];
        }
        @memcpy(self.fill[0..used], self.starts[0..used]);

        // Fill the CSR. Order within a parent is reversed, which is stable and
        // irrelevant to the result: a child only depends on its parent.
        var edges = world.query(.{components.Parent, components.Transform});
        while (edges.nextBatch()) |batch| {
            const parent_components = batch.slice(components.Parent);
            const entities = batch.entitySlice();
            for (entities, parent_components) |e, link| {
                if (!world.isAlive(link.parent) or link.parent.eql(e)) continue;
                const parent = link.parent.index;
                self.fill[parent] -= 1;
                self.children[self.fill[parent]] = e.index;
            }
        }

        // Roots: entities with a transform that are not stamped as children.
        var tail: usize = 0;
        var transforms = world.query(.{components.Transform});
        while (transforms.nextBatch()) |batch| {
            const entities = batch.entitySlice();
            for (entities) |e| {
                if (self.child_stamp[e.index] != self.stamp_now) {
                    self.queue[tail] = e.index;
                    tail += 1;
                }
            }
        }

        // Breadth-first fold: visited in ascending depth, so each child sees
        // its parent's finished world transform.
        var head: usize = 0;
        while (head < tail) {
            const parent = self.queue[head];
            head += 1;
            const first = self.starts[parent + 1];
            const last = self.starts[parent];
            for (self.children[first..last]) |child| {
                self.world[child] = fold(self.world[parent], self.world[child]);
                self.queue[tail] = child;
                tail += 1;
            }
        }

        self.last_resolved = tail;
        if (tail < transform_count) {
            // Some entity never became reachable: a cycle in its chain.
            scoped.debug("cycle or orphaned parent in {d} of {d} entities", .{ transform_count - tail, transform_count });
        }
    }

    /// World transform of a slot index (`WorldTransform.identity` if the
    /// entity has none or the slot is out of range).
    pub fn at(self: *const Self, index: usize) WorldTransform {
        if (index >= self.world.len) return WorldTransform.identity;
        return self.world[index];
    }

    /// World transform of a live entity (what the renderer asks for).
    pub fn worldOf(self: *const Self, world: anytype, e: Entity) WorldTransform {
        if (!world.isAlive(e)) return WorldTransform.identity;
        return self.at(e.index);
    }
};

/// Composes a parent world transform with a child world-so-far (still local
/// on the first visit) transform: 2D equivalent of parent_local * child_local.
pub fn fold(parent: WorldTransform, child: WorldTransform) WorldTransform {
    const c = @cos(parent.rotation);
    const s = @sin(parent.rotation);
    const lx = child.position.x * parent.scale.x;
    const ly = child.position.y * parent.scale.y;
    return .{
        .position = .{ .x = parent.position.x + lx * c - ly * s, .y = parent.position.y + lx * s + ly * c },
        .rotation = parent.rotation + child.rotation,
        .scale = .{ .x = parent.scale.x * child.scale.x, .y = parent.scale.y * child.scale.y },
    };
}

test "fold composes translation, rotation and scale" {
    const parent = WorldTransform{
        .position = .{ .x = 10, .y = 20 },
        .rotation = @as(f32, std.math.pi) / 2.0, // 90 degrees
        .scale = .{ .x = 2, .y = 2 },
    };
    const child = WorldTransform{
        .position = .{ .x = 1, .y = 0 },
        .rotation = 0,
        .scale = .{ .x = 1, .y = 1 },
    };
    const composed = fold(parent, child);
    // A unit on +x rotated +90 degrees (y down) lands on +y.
    try std.testing.expectApproxEqAbs(@as(f32, 10), composed.position.x, 0.001);
    try std.testing.expectApproxEqAbs(@as(f32, 22), composed.position.y, 0.001);
    try std.testing.expectApproxEqAbs(@as(f32, 2), composed.scale.x, 0.001);
}
