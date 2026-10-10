//! A regression test for the query cursor: `next()` must visit every row of
//! every matching archetype exactly once.
//!
//! ## The bug this exists for
//!
//! `Query.next` had a batch-boundary defect. When the cursor ran past the end of
//! an archetype it advanced to the next one and returned its row 0 — but only
//! after `nextBatch` had already zeroed `self.row`, and the returned `Row`
//! carried `row = 0` without the cursor being marked as consumed. The result was
//! that the first row of every archetype after the first was returned TWICE, and
//! the second return happened after the cursor had moved on, so the same entity
//! appeared under two different positions in the iteration.
//!
//! That is not a cosmetic bug. A system that counts bodies gets the wrong count;
//! a system that writes to `r.get(T)` applies an update twice; and a system that
//! builds a snapshot keyed by entity gets whichever copy landed last. The M4
//! physics sync walks exactly this kind of query, which is how it surfaced: the
//! determinism bench read garbage entity indices out of a spawn table.
//!
//! ## Why three archetypes
//!
//! One archetype cannot expose a batch-boundary bug, and two might not either
//! depending on which one is empty. Three deliberately non-empty archetypes of
//! differing shape make the cursor cross two boundaries.

const std = @import("std");
const ecs = @import("root.zig");

const components = ecs.components;
const Transform = components.Transform;
const RigidBody2D = components.RigidBody2D;
const Collider2D = components.Collider2D;

test "a query visits every matching row exactly once, across archetypes" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var world = ecs.World.init(allocator);
    defer world.deinit();

    // Three distinct archetypes, all carrying Transform:
    //   {T} x3, {T, RigidBody2D} x3, {T, Collider2D} x3
    var i: usize = 0;
    while (i < 3) : (i += 1) {
        _ = try world.spawn(.{Transform{ .position = .{ .x = @floatFromInt(i), .y = 0 } }});
    }
    while (i < 6) : (i += 1) {
        _ = try world.spawn(.{
            Transform{ .position = .{ .x = @floatFromInt(i), .y = 0 } },
            RigidBody2D{ .body_type = 2 },
        });
    }
    while (i < 9) : (i += 1) {
        _ = try world.spawn(.{
            Transform{ .position = .{ .x = @floatFromInt(i), .y = 0 } },
            Collider2D{ .kind = 0 },
        });
    }

    const expected: usize = 9;
    var seen = [_]bool{false} ** 16;
    var count: usize = 0;

    var q = world.query(.{Transform});
    while (q.next()) |r| {
        const e = r.entity();
        // A repeated row would trip this before the duplicate check, which is
        // the point: the corruption showed up as out-of-range indices first.
        try std.testing.expect(e.index < seen.len);
        try std.testing.expect(!seen[e.index]);
        seen[e.index] = true;
        count += 1;
    }

    try std.testing.expectEqual(expected, count);
}

test "a query over one archetype yields exactly its row count" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var world = ecs.World.init(allocator);
    defer world.deinit();

    var i: usize = 0;
    while (i < 5) : (i += 1) {
        _ = try world.spawn(.{Transform{ .position = .{ .x = @floatFromInt(i), .y = 0 } }});
    }

    var count: usize = 0;
    var q = world.query(.{Transform});
    while (q.next()) |_| count += 1;
    try std.testing.expectEqual(@as(usize, 5), count);
}

test "a query matching nothing terminates instead of looping" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var world = ecs.World.init(allocator);
    defer world.deinit();

    _ = try world.spawn(.{Transform{ .position = .{ .x = 0, .y = 0 } }});

    // No entity carries RigidBody2D, so every archetype is filtered out. A
    // cursor that mishandles "no batch found" either spins forever or returns
    // one phantom row.
    var count: usize = 0;
    var q = world.query(.{RigidBody2D});
    while (q.next()) |_| count += 1;
    try std.testing.expectEqual(@as(usize, 0), count);
}
