//! Entity handles: index + generation packed in 64 bits.
//!
//! - `index` locates a slot; `generation` proves the slot still belongs to
//!   the handle's owner. Every free bumps the generation, so an old handle
//!   can never alias a new occupant: **no use-after-free, ever** (M1).
//! - Handles are values: copyable, hashable, and usable as map keys.
//! - Scene identity ("this entity is the same after save/load") is the
//!   `SceneId`, which the world keeps per slot: handles are volatile by
//!   design, scene ids are not (see `zson`).

const std = @import("std");

pub const Entity = extern struct {
    index: u32 = 0,
    generation: u32 = 0,

    /// Sentinel for "no entity" (parent-less, missing target, ...). The
    /// maximum index can never be a live slot: slots are appended, never
    /// sparse, and the allocator is far from 4G entity ids.
    pub const invalid: Entity = .{ .index = std.math.maxInt(u32), .generation = 0 };

    pub fn isInvalid(self: Entity) bool {
        return self.index == invalid.index;
    }

    pub fn eql(self: Entity, other: Entity) bool {
        return self.index == other.index and self.generation == other.generation;
    }

    /// Bits as a `u64` key (hash maps, slots dictionaries).
    pub fn bits(self: Entity) u64 {
        return @as(u64, self.index) | (@as(u64, self.generation) << 32);
    }

    pub fn hash(self: Entity) u64 {
        return std.hash.Wyhash.hash(0, std.mem.asBytes(&self.bits()));
    }
};

/// Stable scene identity of a slot (M1): survives save/load because `.zson`
/// writes the id, not the volatile handle. `0` means "none" (no parent, no
/// prefab origin), so ids start at 1.
pub const SceneId = u64;

test "invalid sentinel and equality" {
    try std.testing.expect(Entity.invalid.isInvalid());
    const zero = Entity{ .index = 0, .generation = 0 };
    try std.testing.expect(!zero.isInvalid());
    const a = Entity{ .index = 1, .generation = 2 };
    const b = Entity{ .index = 1, .generation = 2 };
    const c = Entity{ .index = 1, .generation = 3 };
    try std.testing.expect(a.eql(b));
    try std.testing.expect(!a.eql(c));
}

test "hash bucket spread for sequential handles" {
    var buckets = [_]u8{0} ** 8;
    var i: u32 = 0;
    while (i < 32) : (i += 1) {
        const e = Entity{ .index = i, .generation = 1 };
        buckets[e.hash() % 8] += 1;
    }
    // A decent hash spreads 32 handles over 8 buckets without emptying one.
    for (buckets) |b| try std.testing.expect(b > 0);
}
