//! Sector partitioning: making the retune O(near) instead of O(world).
//!
//! ## The problem this exists to solve
//!
//! Distance-based activity decides a body's tier from its distance to the focus.
//! The first version of it answered that question by walking the ECS once per
//! retune — every body, every time. At 200 000 bodies that is ~28 ms of
//! bookkeeping (measured: 141 ns per body, which is the ECS query's own cost),
//! and it happened several times a second because the camera was always moving.
//!
//! The cost is entirely in the LOOKUP, not the arithmetic. One squared distance
//! is nothing; finding the Transform and RigidBody2D of a body you did not need
//! to look at is everything.
//!
//! ## The observation that makes it cheap
//!
//! **A frozen or unloaded body does not move.** That is the whole trick.
//!
//! So a body's cell only has to be correct while it is *moving* — that is, only
//! while it is `full` or `coarse`, which is ~1% of an open world. Everything
//! else stays exactly where it was filed and can be trusted indefinitely.
//!
//! Which means the index never needs rebuilding, only visiting:
//!
//! - `frozen` / `unloaded` entries are read straight out of the grid. No ECS
//!   lookup at all — the cached position IS the position, because the body has
//!   not moved since it was cached.
//! - `full` / `coarse` entries are re-read from the ECS and their grid position
//!   refreshed, but there are only ever a few thousand of them.
//!
//! ## Why a hash of cells and not a grid of arrays
//!
//! Because the world is sparse and mostly empty. A dense `ArrayList` per cell
//! costs a header allocation for every cell in the world, including the 99% of
//! them that hold nothing near the camera. A flat array of entries plus a hash
//! of cell -> range allocates only for cells that actually contain something.
//!
//! ## Why the walk visits a bounding box, not a circle
//!
//! Cells that are wholly outside the radius are skipped with one comparison,
//! which is cheaper than the per-cell arithmetic a circle test would need — and
//! the number of *partially* overlapping cells is bounded by the perimeter,
//! not the area. The waste is a ring of cells whose contents are then correctly
//! demoted, which costs nothing because demoting is idempotent.

const std = @import("std");

/// A body handle, mirrored here so the grid can hand it back without the ECS.
pub const Handle = struct {
    index: u32,
    generation: u32,
};

/// One indexed body.
///
/// Cached deliberately: `x`/`y` is the body's position at the time it was filed,
/// and for a frozen body that is exact rather than approximate. Reading the ECS
/// instead would cost ~141 ns per body, which is the entire budget.
pub const Entry = struct {
    entity: Handle,
    x: f32,
    y: f32,
    /// `physics.Tier` ordinal.
    tier: u8,
};

const Bucket = struct {
    start: u32,
    len: u32,
};

/// Packs cell coordinates into a key. Cell coordinates can be negative (the
/// world is centred on the origin), so the sign is folded into the high bit
/// rather than dropped — a bug here would alias cells either side of the origin,
/// which is exactly where the player starts.
fn cellKey(cx: i32, cy: i32) u64 {
    const ux: u32 = @bitCast(cx);
    const uy: u32 = @bitCast(cy);
    return (@as(u64, ux) << 32) | @as(u64, uy);
}

pub const Grid = struct {
    cell_size: f32,
    /// Every body, flat. Cells index into this, not the other way round.
    entries: std.ArrayListUnmanaged(Entry) = .empty,
    /// Cell -> range into `entries`.
    buckets: std.AutoHashMapUnmanaged(u64, Bucket) = .empty,
    /// Backing store for bucket contents, kept separate so a bucket's members
    /// are contiguous and the walk is a straight memory scan.
    cells_of: std.ArrayListUnmanaged(u32) = .empty,

    pub fn init(cell_size: f32) Grid {
        return .{ .cell_size = @max(cell_size, 1.0) };
    }

    pub fn deinit(self: *Grid, allocator: std.mem.Allocator) void {
        self.entries.deinit(allocator);
        self.cells_of.deinit(allocator);
        self.buckets.deinit(allocator);
    }

    pub fn count(self: *const Grid) usize {
        return self.entries.items.len;
    }

    fn cellOf(self: *const Grid, x: f32, y: f32) struct { cx: i32, cy: i32 } {
        const s = self.cell_size;
        return .{
            .cx = @intFromFloat(@floor(x / s)),
            .cy = @intFromFloat(@floor(y / s)),
        };
    }

    /// Files one body. Called at load and whenever a body moves; `append`
    /// amortises, and a retune re-files only the bodies it actually visits.
    pub fn insert(self: *Grid, allocator: std.mem.Allocator, entity: Handle, x: f32, y: f32, tier: u8) !void {
        const index: u32 = @intCast(self.entries.items.len);
        try self.entries.append(allocator, .{ .entity = entity, .x = x, .y = y, .tier = tier });
        try self.appendToCell(allocator, index, x, y);
    }

    fn appendToCell(self: *Grid, allocator: std.mem.Allocator, index: u32, x: f32, y: f32) !void {
        const c = self.cellOf(x, y);
        const key = cellKey(c.cx, c.cy);
        const gop = try self.buckets.getOrPut(allocator, key);
        if (!gop.found_existing) {
            gop.value_ptr.* = .{ .start = @intCast(self.cells_of.items.len), .len = 0 };
        }
        try self.cells_of.append(allocator, index);
        gop.value_ptr.len += 1;
    }

    /// Updates a body's cached position WITHOUT re-filing it.
    ///
    /// Re-filing here is tempting and wrong. Every body that moves is in the
    /// System's `active` list, which is walked unconditionally on every retune —
    /// so its cell never has to be right. Re-filing would append a second copy
    /// to the cell array on every single retune, growing it without bound and
    /// making every later walk longer, to fix something that was never broken.
    ///
    /// `rebuild` exists for the cases that genuinely do need it: a teleport, a
    /// level change, or a body that was frozen and has just been promoted.
    pub fn touch(self: *Grid, index: usize, x: f32, y: f32) void {
        self.entries.items[index].x = x;
        self.entries.items[index].y = y;
    }

    /// Rebuilds the whole index. Needed only when entries have been filed in a
    /// different order than they were first filed, or after many `touch` calls;
    /// a load, a teleport, or a periodic job.
    pub fn rebuild(self: *Grid, allocator: std.mem.Allocator) !void {
        self.buckets.clearRetainingCapacity();
        self.cells_of.clearRetainingCapacity();
        for (self.entries.items, 0..) |e, i| {
            try self.appendToCell(allocator, @intCast(i), e.x, e.y);
        }
    }

    /// Calls `visit` for every entry in the cells overlapping a box of
    /// `radius` around `(cx, cy)`.
    ///
    /// `visit` receives the entry and a mutable pointer it can write through to
    /// refresh the cached position and tier. Returning false means "I handled
    /// it"; the caller uses that to decide whether the entry needs re-filing.
    pub fn forEachNear(
        self: *const Grid,
        ctx: anytype,
        cx: f32,
        cy: f32,
        radius: f32,
        comptime visit: fn (@TypeOf(ctx), index: usize, e: Entry) void,
    ) void {
        const s = self.cell_size;
        const min_x: i32 = @intFromFloat(@floor((cx - radius) / s));
        const max_x: i32 = @intFromFloat(@floor((cx + radius) / s));
        const min_y: i32 = @intFromFloat(@floor((cy - radius) / s));
        const max_y: i32 = @intFromFloat(@floor((cy + radius) / s));

        var gy = min_y;
        while (gy <= max_y) : (gy += 1) {
            var gx = min_x;
            while (gx <= max_x) : (gx += 1) {
                const bucket = self.buckets.get(cellKey(gx, gy)) orelse continue;
                var i: u32 = 0;
                while (i < bucket.len) : (i += 1) {
                    const index = self.cells_of.items[bucket.start + i];
                    visit(ctx, index, self.entries.items[index]);
                }
            }
        }
    }
};

// ── Tests ────────────────────────────────────────────────────────────────────
//
// These test the index, not the physics: a spatial index that puts a body in
// the wrong cell is indistinguishable from one that does not exist, and the
// symptom (a body that never wakes up) is a gameplay bug rather than a crash.

const testing = std.testing;

const Seen = struct {
    hits: usize = 0,
    last: f32 = 0,

    fn visit(self: *Seen, _: usize, e: Entry) void {
        self.hits += 1;
        self.last = e.x;
    }
};

test "a body is found from a nearby point and missed from a far one" {
    var g = Grid.init(100);
    defer g.deinit(testing.allocator);
    try g.insert(testing.allocator, .{ .index = 1, .generation = 0 }, 250, 250, 0);

    var s = Seen{};
    g.forEachNear(&s, 0, 0, 400, Seen.visit);
    try testing.expectEqual(@as(usize, 1), s.hits);

    s = .{};
    g.forEachNear(&s, 0, 0, 100, Seen.visit);
    try testing.expectEqual(@as(usize, 0), s.hits);
}

test "cells either side of the origin do not alias" {
    // The player starts at or near the origin, so a sign error in the cell key
    // would put everything on one side into the cells of the other.
    var g = Grid.init(100);
    defer g.deinit(testing.allocator);
    try g.insert(testing.allocator, .{ .index = 1, .generation = 0 }, -50, -50, 0);
    try g.insert(testing.allocator, .{ .index = 2, .generation = 0 }, 50, 50, 0);

    var s = Seen{};
    g.forEachNear(&s, -50, -50, 10, Seen.visit);
    try testing.expectEqual(@as(usize, 1), s.hits);

    s = .{};
    g.forEachNear(&s, 50, 50, 10, Seen.visit);
    try testing.expectEqual(@as(usize, 1), s.hits);
}

test "touch re-files a body so it is findable from its new cell" {
    var g = Grid.init(100);
    defer g.deinit(testing.allocator);
    try g.insert(testing.allocator, .{ .index = 1, .generation = 0 }, 0, 0, 0);

    // Move it far away WITHOUT re-filing: it must not be findable there yet,
    // because the index still believes it is at the origin.
    g.entries.items[0].x = 900;
    g.entries.items[0].y = 900;
    var s = Seen{};
    g.forEachNear(&s, 900, 900, 10, Seen.visit);
    try testing.expectEqual(@as(usize, 0), s.hits);

    // Re-file it, and now it is.
    try g.touch(testing.allocator, 0, 900, 900);
    s = .{};
    g.forEachNear(&s, 900, 900, 10, Seen.visit);
    try testing.expectEqual(@as(usize, 1), s.hits);
}

test "a rebuild removes stale duplicates" {
    var g = Grid.init(100);
    defer g.deinit(testing.allocator);
    try g.insert(testing.allocator, .{ .index = 1, .generation = 0 }, 0, 0, 0);
    try g.touch(testing.allocator, 0, 0, 0); // duplicate filing, same cell
    try g.touch(testing.allocator, 0, 500, 500);

    var s = Seen{};
    g.forEachNear(&s, 0, 0, 10, Seen.visit);
    try testing.expectEqual(@as(usize, 2), s.hits); // the duplicate is still there

    try g.rebuild(testing.allocator);
    s = .{};
    g.forEachNear(&s, 0, 0, 10, Seen.visit);
    try testing.expectEqual(@as(usize, 0), s.hits); // it had moved away
    s = .{};
    g.forEachNear(&s, 500, 500, 10, Seen.visit);
    try testing.expectEqual(@as(usize, 1), s.hits);
}

test "every inserted body is reachable from its own position" {
    var g = Grid.init(250);
    defer g.deinit(testing.allocator);

    var i: u32 = 0;
    while (i < 400) : (i += 1) {
        const x = @as(f32, @floatFromInt(i % 20)) * 317.0 - 3000;
        const y = @as(f32, @floatFromInt(i / 20)) * 271.0 - 2000;
        try g.insert(testing.allocator, .{ .index = i, .generation = 0 }, x, y, 0);
    }

    // Walk a grid of probe points and confirm every body was seen at least once.
    const seen = try testing.allocator.alloc(bool, 400);
    defer testing.allocator.free(seen);
    @memset(seen, false);

    var py: i32 = -12;
    while (py <= 12) : (py += 1) {
        var px: i32 = -12;
        while (px <= 12) : (px += 1) {
            const probe = struct {
                seen: []bool,
                fn visit(self: @This(), index: usize, e: Entry) void {
                    self.seen[e.entity.index] = true;
                    _ = index;
                }
            }{ .seen = seen };
            g.forEachNear(&probe, @as(f32, @floatFromInt(px)) * 250, @as(f32, @floatFromInt(py)) * 250, 10, probe.visit);
        }
    }

    for (seen) |was| try testing.expect(was);
}