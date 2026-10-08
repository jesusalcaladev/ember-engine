//! Archetypes: one table per distinct component set, stored struct-of-arrays.
//!
//! Why archetypes (M1): entities that share a component set share memory
//! layout, so a system that reads `(Transform, Velocity)` touches one dense
//! pair of arrays with no indirection, no per-entity branching and zero
//! allocations (spec §2 budget: 100k transform updates in ≤ 2 ms).
//!
//! Storage facts that matter for performance:
//! - Columns are type-erased byte slices indexed by `stride` (the aligned
//!   size of the component). The query layer turns them back into `[]T`, so
//!   hot loops are plain Zig loops over slices — vectorizable.
//! - Rows are append-only; removal is swap-remove (O(1)) which fixes up the
//!   moved entity's slot in O(1) — never a scan, never a spike (spec §3).
//! - The only allocation is capacity growth. The runtime locks it during the
//!   frame (see `World`), so the frame loop stays allocation-free.

const std = @import("std");
const components = @import("components.zig");
const entity = @import("entity.zig");

pub const Entity = entity.Entity;
pub const ComponentId = components.ComponentId;
pub const Mask = components.Mask;

pub const Column = struct {
    id: ComponentId,
    /// Bytes per row: `@sizeOf(component)` (contiguous, so casts are aligned).
    stride: u32,
    align_pow: u8,
    /// Capacity in bytes (`len == archetype.capacity * stride`), not row count.
    data: []u8,

    pub fn alignment(self: *const Column) std.mem.Alignment {
        return std.mem.Alignment.fromByteUnits(@as(usize, 1) << @intCast(self.align_pow));
    }
};

pub const Archetype = struct {
    /// Sorted ascending (registry order). Also the archetype key, owned here.
    ids: []ComponentId,
    /// `ids` as a bitmask: query tests are word comparisons.
    mask: Mask,
    /// Row -> entity handle (parallel to every column).
    entities: []Entity,
    columns: []Column,
    /// Rows in use. `capacity` is `entities.len`.
    len: usize,

    pub fn init(allocator: std.mem.Allocator, ids: []const ComponentId) !Archetype {
        const owned_ids = try allocator.alloc(ComponentId, ids.len);
        @memcpy(owned_ids, ids);
        var mask = Mask.initEmpty();
        for (owned_ids) |id| mask.set(id);

        const columns = try allocator.alloc(Column, ids.len);
        for (ids, columns) |id, *column| {
            column.* = .{
                .id = id,
                .stride = components.strideOf(id),
                .align_pow = components.alignOfPow(id),
                .data = &.{},
            };
        }
        return .{
            .ids = owned_ids,
            .mask = mask,
            .entities = &.{},
            .columns = columns,
            .len = 0,
        };
    }

    pub fn deinit(self: *Archetype, allocator: std.mem.Allocator) void {
        for (self.columns) |column| {
            if (column.data.len > 0) allocator.rawFree(column.data, column.alignment(), @returnAddress());
        }
        allocator.free(self.columns);
        allocator.free(self.ids);
        if (self.entities.len > 0) allocator.free(self.entities);
        self.* = undefined;
    }

    pub fn capacity(self: *const Archetype) usize {
        return self.entities.len;
    }

    /// Index of `id`'s column (ids are sorted, so binary search) or `null`.
    pub fn findColumn(self: *const Archetype, id: ComponentId) ?usize {
        var lo: usize = 0;
        var hi: usize = self.ids.len;
        while (lo < hi) {
            const mid = lo + (hi - lo) / 2;
            if (self.ids[mid] == id) return mid;
            if (self.ids[mid] < id) lo = mid + 1 else hi = mid;
        }
        return null;
    }

    pub fn has(self: *const Archetype, id: ComponentId) bool {
        return self.findColumn(id) != null;
    }

    /// Does the archetype contain all of `required` and none of `excluded`?
    /// An empty `required` matches every archetype: a query with no types is
    /// "every entity" by convention.
    pub fn matches(self: *const Archetype, required: Mask, excluded: Mask) bool {
        return self.mask.supersetOf(required) and self.mask.intersectWith(excluded).count() == 0;
    }

    /// Grows capacity to at least `n`, never shrinks, preserving row data.
    /// Growth is geometric (1.5x): appending a row is amortized O(1), so
    /// loading a scene never degrades into a realloc per entity. `reserve(n)`
    /// on an empty archetype still allocates exactly `n`.
    pub fn ensureCapacity(self: *Archetype, allocator: std.mem.Allocator, n: usize) !void {
        const current = self.capacity();
        if (n <= current) return;
        const wanted = @max(n, current + current / 2 + 1);
        const new_entities = try allocator.alloc(Entity, wanted);
        @memcpy(new_entities[0..self.len], self.entities[0..self.len]);
        if (self.entities.len > 0) allocator.free(self.entities);
        self.entities = new_entities;
        for (self.columns) |*column| {
            const new_bytes = wanted * column.stride;
            // Runtime alignment: the allocator API takes comptime alignment
            // and columns are type-erased on purpose. rawAlloc/rawFree are the
            // public route for "this slice needs that alignment".
            const raw = allocator.rawAlloc(new_bytes, column.alignment(), @returnAddress()) orelse
                return error.OutOfMemory;
            const buf = raw[0..new_bytes];
            const old_bytes = self.len * column.stride;
            if (old_bytes > 0) @memcpy(buf[0..old_bytes], column.data[0..old_bytes]);
            if (column.data.len > 0) allocator.rawFree(column.data, column.alignment(), @returnAddress());
            column.data = buf;
        }
    }

    /// Appends a row for `e`; component bytes are undefined and the caller
    /// must fill them (or the caller asked for the default baseline).
    pub fn pushRow(self: *Archetype, allocator: std.mem.Allocator, e: Entity) !usize {
        try self.ensureCapacity(allocator, self.len + 1);
        const row = self.len;
        self.entities[row] = e;
        self.len = row + 1;
        return row;
    }

    /// O(1) removal: the last row moves into `row`; its handle is left at
    /// `entities[row]` so the caller can fix that entity's slot.
    pub fn swapRemoveRow(self: *Archetype, row: usize) void {
        std.debug.assert(row < self.len);
        const last = self.len - 1;
        if (row != last) {
            const moved = self.entities[last];
            for (self.columns) |*column| {
                const stride = column.stride;
                const dst = column.data.ptr + row * stride;
                const src = column.data.ptr + last * stride;
                @memcpy(dst[0..stride], src[0..stride]);
            }
            self.entities[row] = moved;
        }
        self.len = last;
    }

    /// Typed pointer to one cell: the bridge from bytes to Zig types.
    pub fn cellPtr(self: *const Archetype, comptime T: type, col: usize, row: usize) *T {
        const start = self.columns[col].data.ptr + row * self.columns[col].stride;
        const ptr: [*]T = @ptrCast(@alignCast(start));
        return &ptr[0];
    }

    /// Typed view of a whole column (all rows): what systems iterate over.
    pub fn columnSlice(self: *const Archetype, comptime T: type, col: usize) []T {
        const ptr: [*]T = @ptrCast(@alignCast(self.columns[col].data.ptr));
        return ptr[0..self.len];
    }

    /// Raw bytes of one cell (used by serializers, which know the concrete
    /// component type through the registry).
    pub fn columnBytes(self: *const Archetype, col: usize, row: usize) []u8 {
        const stride = self.columns[col].stride;
        return self.columns[col].data[row * stride ..][0..stride];
    }
};

test "archetype: grow, push, swap-remove keeps data intact" {
    const alloc = std.testing.allocator;
    var arch = try Archetype.init(alloc, &.{ 1, 3 }); // Transform + Velocity
    defer arch.deinit(alloc);

    try std.testing.expectEqual(@as(?usize, 0), arch.findColumn(1));
    try std.testing.expectEqual(@as(?usize, 1), arch.findColumn(3));
    try std.testing.expectEqual(@as(?usize, null), arch.findColumn(0));
    try std.testing.expect(arch.has(@as(components.ComponentId, 3)));

    // Three rows, two columns.
    var i: usize = 0;
    while (i < 3) : (i += 1) {
        const row = try arch.pushRow(alloc, .{ .index = @intCast(i), .generation = 7 });
        arch.cellPtr(components.Velocity, 1, row).* = .{
            .linear = .{ .x = @floatFromInt(i), .y = 0 },
            .angular = @floatFromInt(i),
        };
    }

    var velocities = arch.columnSlice(components.Velocity, 1);
    try std.testing.expectEqual(@as(usize, 3), velocities.len);
    try std.testing.expectApproxEqAbs(@as(f32, 2), velocities[2].linear.x, 0.0001);

    // Removing the middle row moves the last one into place: no holes.
    arch.swapRemoveRow(1);
    try std.testing.expectEqual(@as(usize, 2), arch.len);
    velocities = arch.columnSlice(components.Velocity, 1);
    try std.testing.expectApproxEqAbs(@as(f32, 2), velocities[1].linear.x, 0.0001);
    try std.testing.expectEqual(@as(u32, 2), arch.entities[1].index);
}

test "archetype: capacity growth preserves all rows" {
    const alloc = std.testing.allocator;
    var arch = try Archetype.init(alloc, &.{1});
    defer arch.deinit(alloc);

    const rows: usize = 200;
    var i: usize = 0;
    while (i < rows) : (i += 1) {
        const row = try arch.pushRow(alloc, .{ .index = @intCast(i), .generation = 1 });
        arch.cellPtr(components.Transform, 0, row).position.x = @floatFromInt(i);
    }
    try std.testing.expect(arch.capacity() >= rows);
    const column = arch.columnSlice(components.Transform, 0);
    try std.testing.expectEqual(@as(usize, rows), column.len);
    for (column, 0..) |t, idx| {
        try std.testing.expectApproxEqAbs(@as(f32, @floatFromInt(idx)), t.position.x, 0.0001);
    }
}

test "archetype: mask matching with exclusions" {
    const alloc = std.testing.allocator;
    var arch = try Archetype.init(alloc, &.{ 0, 1 }); // Name + Transform
    defer arch.deinit(alloc);

    var required = Mask.initEmpty();
    required.set(0);
    // Contains Name: matches.
    try std.testing.expect(arch.matches(required, Mask.initEmpty()));
    // An empty requirement matches every archetype ("all entities").
    try std.testing.expect(arch.matches(Mask.initEmpty(), Mask.initEmpty()));
    // A required id that is absent: no match.
    var parent_required = Mask.initEmpty();
    parent_required.set(2);
    try std.testing.expect(!arch.matches(parent_required, Mask.initEmpty()));
    // An excluded id that is present: no match.
    var transform_excluded = Mask.initEmpty();
    transform_excluded.set(1);
    try std.testing.expect(!arch.matches(required, transform_excluded));
}
