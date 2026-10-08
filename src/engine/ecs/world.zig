//! World: slots + archetypes + the structural operations on top of them.
//!
//! Design (M1):
//! - **Slots** hold identity (generation, scene id) and location (archetype,
//!   row). Handles are only `{index, generation}`, so any stale handle fails
//!   the generation test: use-after-free is impossible by construction.
//! - **Archetypes** are found by mask equality (linear scan: a world has tens
//!   of archetypes and each test is 4 word comparisons) — no hash map, no
//!   allocation, deterministic discovery order.
//! - **Growth** (slots, free list, rows, archetypes) is the only allocation.
//!   The runtime locks the world inside the frame (`lockAllocs`) so a missing
//!   `reserve` at load time fails loudly instead of becoming a spike
//!   (spec §3.1: the frame allocates nothing but the frame arena).
//! - Structural changes never scan: swap-remove + O(1) slot fix-up.

const std = @import("std");
const components = @import("components.zig");
const archetype_mod = @import("archetype.zig");
const entity = @import("entity.zig");
const hierarchy_mod = @import("hierarchy.zig");
const signals_mod = @import("signals.zig");
const query_mod = @import("query.zig");

const Archetype = archetype_mod.Archetype;
const Entity = entity.Entity;
const SceneId = entity.SceneId;
const ComponentId = components.ComponentId;
const Mask = components.Mask;

/// One live entity. `row`/`archetype` are only meaningful while `occupied`.
const Slot = struct {
    generation: u32 = 0,
    scene_id: SceneId = 0,
    archetype: u32 = 0,
    row: u32 = 0,
    occupied: bool = false,
};

/// Archetype keys built on the stack when adding/removing one component.
/// Anything wider than this (2 dozen components on one entity, which the
/// engine never does) takes the heap and needs the growth guard.
const stack_ids = 32;

/// A row created at load time; `zson` decoding fills the components itself.
pub const Row = struct {
    entity: Entity,
    row: usize,
};

pub const World = struct {
    allocator: std.mem.Allocator,
    slots: std.ArrayList(Slot) = .empty,
    free_slots: std.ArrayList(u32) = .empty,
    archetypes: std.ArrayList(Archetype) = .empty,
    /// Monotonic scene identity. Starts at 1: 0 means "none" (see `Parent`).
    scene_id_next: SceneId = 1,
    /// Parent-chain resolution scratch (opt-in: `enableHierarchy`).
    hierarchy: hierarchy_mod.Hierarchy = .{},
    /// Typed events, stable order by spawn, drained once per frame.
    signals: signals_mod.Signals = .{},
    /// When locked, any growth panics: the frame loop must not allocate.
    alloc_locked: bool = false,

    const Self = @This();

    pub fn init(allocator: std.mem.Allocator) World {
        var world = World{ .allocator = allocator };
        world.signals.allocator = allocator;
        return world;
    }

    pub fn deinit(self: *Self) void {
        const alloc = self.allocator;
        for (self.archetypes.items) |*arch| arch.deinit(alloc);
        self.archetypes.deinit(alloc);
        self.slots.deinit(alloc);
        self.free_slots.deinit(alloc);
        self.hierarchy.deinit(alloc);
        self.signals.deinit();
        self.* = undefined;
    }

    // ── Identity ────────────────────────────────────────────────────────────

    pub fn entityCount(self: *const Self) usize {
        return if (self.slots.items.len < self.free_slots.items.len)
            0
        else
            self.slots.items.len - self.free_slots.items.len;
    }

    pub fn isAlive(self: *const Self, e: Entity) bool {
        if (e.isInvalid() or e.index >= self.slots.items.len) return false;
        const slot = &self.slots.items[e.index];
        return slot.occupied and slot.generation == e.generation;
    }

    pub fn sceneIdOf(self: *const Self, e: Entity) SceneId {
        return if (self.isAlive(e)) self.slots.items[e.index].scene_id else 0;
    }

    /// Entity for a scene id (linear scan: only used while loading, never in
    /// the frame loop).
    pub fn findBySceneId(self: *const Self, id: SceneId) ?Entity {
        if (id == 0) return null;
        for (self.slots.items, 0..) |slot, i| {
            if (slot.occupied and slot.scene_id == id) {
                return .{ .index = @intCast(i), .generation = slot.generation };
            }
        }
        return null;
    }

    /// Index of the archetype holding a live entity (internal: `zson`).
    pub fn archIndexOf(self: *const Self, e: Entity) ?u32 {
        if (!self.isAlive(e)) return null;
        return self.slots.items[e.index].archetype;
    }

    /// Alive entity occupying slot `index`, or `null` (internal: `zson`,
    /// which walks slots in index order to write canonical documents).
    pub fn entityAtSlot(self: *const Self, index: usize) ?Entity {
        if (index >= self.slots.items.len) return null;
        const slot = self.slots.items[index];
        if (!slot.occupied) return null;
        return .{ .index = @intCast(index), .generation = slot.generation };
    }

    /// Row of a live entity inside its archetype (internal: `zson`).
    pub fn rowOf(self: *Self, e: Entity) usize {
        return self.slots.items[e.index].row;
    }

    /// Raw component bytes of a live entity, or `null` if it lacks it
    /// (internal: `zson`, which patches values in place).
    pub fn getById(self: *Self, e: Entity, id: ComponentId) ?[]u8 {
        if (!self.isAlive(e)) return null;
        const slot = self.slots.items[e.index];
        const arch = &self.archetypes.items[slot.archetype];
        const col = arch.findColumn(id) orelse return null;
        return arch.columnBytes(col, slot.row);
    }

    /// First alive entity carrying this name (linear: `zson` apply and tools,
    /// never the frame loop).
    pub fn findByName(self: *Self, name: []const u8) ?Entity {
        var slot: usize = 0;
        while (slot < self.slots.items.len) : (slot += 1) {
            const e = self.entityAtSlot(slot) orelse continue;
            const maybe = self.get(e, components.Name) orelse continue;
            if (maybe.eql(name)) return e;
        }
        return null;
    }

    // ── Frame discipline (spec §3.1) ────────────────────────────────────────

    pub fn lockAllocs(self: *Self) void {
        self.alloc_locked = true;
        self.signals.locked = true;
    }

    pub fn unlockAllocs(self: *Self) void {
        self.alloc_locked = false;
        self.signals.locked = false;
    }

    /// Slots in existence (dead ones included): indices of the hierarchy
    /// scratch arrays must cover this.
    pub fn slotCount(self: *const Self) usize {
        return self.slots.items.len;
    }

    /// Pre-allocates the signal event queue: a bounded per-frame budget
    /// (spec §3.1). Call once, at load time.
    pub fn reserveSignals(self: *Self, queue_capacity: usize) !void {
        try self.signals.reserve(self.allocator, queue_capacity);
    }

    /// A growth attempt while the world is locked: the frame is not allowed to
    /// allocate, and the fix is always the same — reserve at load time.
    fn guard(self: *const Self, comptime what: []const u8) void {
        if (self.alloc_locked) {
            std.debug.panic(
                "world: {s} during the frame loop. Pre-allocate with World.reserve/reserveEntities before the loop (spec §3.1)",
                .{what},
            );
        }
    }

    /// Pre-allocates identity + free-list capacity so loading a scene of `n`
    /// entities (and spawning them later) never grows them.
    pub fn reserveEntities(self: *Self, n: usize) !void {
        if (n > self.slots.capacity) {
            try self.slots.ensureTotalCapacity(self.allocator, n);
        }
        if (n > self.free_slots.capacity) {
            try self.free_slots.ensureTotalCapacity(self.allocator, n);
        }
        if (self.hierarchy.enabled and n > self.hierarchy.capacity) {
            self.guard("growing the hierarchy scratch");
            try self.hierarchy.reserve(self.allocator, n);
        }
    }

    /// Pre-grows the archetype for `with` (a tuple of types) to hold `n` rows.
    pub fn reserve(self: *Self, comptime with: anytype, n: usize) !void {
        const key = keyOfTypes(typesOfTuple(with));
        const index = try self.findOrCreateArchetype(key);
        var arch = &self.archetypes.items[index];
        if (n > arch.capacity()) {
            self.guard("growing an archetype");
            try arch.ensureCapacity(self.allocator, n);
        }
    }

    /// Opts the flat parent-chain resolver on and allocates its scratch now,
    /// so resolving during a frame never allocates.
    pub fn enableHierarchy(self: *Self) !void {
        if (self.hierarchy.enabled) return;
        self.hierarchy.enabled = true;
        const wanted = @max(self.slots.capacity, self.slots.items.len);
        if (wanted > self.hierarchy.capacity) {
            self.guard("growing the hierarchy scratch");
            try self.hierarchy.reserve(self.allocator, wanted);
        }
    }

    // ── Spawning / component changes ────────────────────────────────────────

    /// Creates an entity with exactly the components in `values` (a tuple of
    /// component values): `world.spawn(.{ Transform{...}, Parent{...} })`.
    pub fn spawn(self: *Self, values: anytype) !Entity {
        const key = comptime keyOfValueTypes(@TypeOf(values));
        const arch_index = try self.findOrCreateArchetype(key);
        const e = try self.allocSlot(arch_index);
        const row = try self.pushRow(arch_index, e);
        self.slots.items[e.index].row = @intCast(row);
        self.fillRow(arch_index, row, values);
        return e;
    }

    /// Entity with no components at all (useful as a grouping node).
    pub fn spawnEmpty(self: *Self) !Entity {
        const key = comptime keyOfValueTypes(@TypeOf(struct {}));
        const arch_index = try self.findOrCreateArchetype(key);
        const e = try self.allocSlot(arch_index);
        const row = try self.pushRow(arch_index, e);
        self.slots.items[e.index].row = @intCast(row);
        return e;
    }

    /// Adds (or overwrites) one component, moving the entity to its new
    /// archetype if the set changes: everything else is copied verbatim.
    pub fn add(self: *Self, e: Entity, value: anytype) !void {
        const T = @TypeOf(value);
        const id = comptime components.componentId(T);
        if (!self.isAlive(e)) return error.DeadEntity;

        const src_index = self.slots.items[e.index].archetype;
        var src = &self.archetypes.items[src_index];
        if (src.has(id)) {
            // Already in place: plain overwrite, no structural change at all.
            const col = src.findColumn(id).?;
            const row = self.slots.items[e.index].row;
            src.cellPtr(T, col, row).* = value;
            return;
        }

        const dst_mask = src.mask.unionWith(single(id));
        const heap_key = src.ids.len + 1 > stack_ids;
        var stack_buf: [stack_ids]ComponentId = undefined;
        const dst_ids = if (!heap_key)
            mergeIds(stack_buf[0 .. src.ids.len + 1], src.ids, id)
        else blk: {
            self.guard("building a wide archetype key");
            const heap = self.allocator.alloc(ComponentId, src.ids.len + 1) catch
                std.debug.panic("world: cannot build an archetype key", .{});
            break :blk mergeIds(heap, src.ids, id);
        };
        defer if (heap_key) self.allocator.free(dst_ids);

        const dst_index = try self.findOrCreateArchetype(.{ .mask = dst_mask, .ids = dst_ids });
        self.moveRow(e, dst_index);

        // The moved row carries the default baseline for `id`: set the value.
        var dst = &self.archetypes.items[dst_index];
        const col = dst.findColumn(id).?;
        dst.cellPtr(T, col, self.slots.items[e.index].row).* = value;
    }

    /// Removes one component. Returns false when the entity never had it.
    pub fn remove(self: *Self, e: Entity, comptime T: type) bool {
        const id = comptime components.componentId(T);
        if (!self.isAlive(e)) return false;

        const src_index = self.slots.items[e.index].archetype;
        const src = &self.archetypes.items[src_index];
        if (!src.has(id)) return false;

        const dst_mask = src.mask.differenceWith(single(id));
        const heap_key = src.ids.len > stack_ids;
        var stack_buf: [stack_ids]ComponentId = undefined;
        const dst_ids = if (!heap_key)
            withoutId(stack_buf[0..src.ids.len], src.ids, id)
        else blk: {
            self.guard("building a wide archetype key");
            const heap = self.allocator.alloc(ComponentId, src.ids.len) catch
                std.debug.panic("world: cannot build an archetype key", .{});
            break :blk withoutId(heap, src.ids, id);
        };
        defer if (heap_key) self.allocator.free(dst_ids);

        const dst_index = self.findOrCreateArchetype(.{ .mask = dst_mask, .ids = dst_ids }) catch
            std.debug.panic("world: cannot create an archetype while removing a component", .{});
        self.moveRow(e, dst_index);
        return true;
    }

    /// Typed pointer into an archetype column, or `null` when the component is
    /// absent. The whole cost of an ECS read: a slot read, a binary search
    /// over a handful of ids, a pointer.
    ///
    /// The pointer is valid until this entity's component set changes (adding
    /// or removing a component moves the row, which may reallocate columns).
    /// Systems that stale the pointer is a bug; `world.spawn` inside a query
    /// can also reallocate the archetype list, so structural changes go after
    /// the iteration, never inside it.
    pub fn get(self: *Self, e: Entity, comptime T: type) ?*T {
        if (!self.isAlive(e)) return null;
        const slot = self.slots.items[e.index];
        const arch = &self.archetypes.items[slot.archetype];
        const col = arch.findColumn(comptime components.componentId(T)) orelse return null;
        return arch.cellPtr(T, col, slot.row);
    }

    pub fn has(self: *Self, e: Entity, comptime T: type) bool {
        return self.get(e, T) != null;
    }

    // ── Queries ─────────────────────────────────────────────────────────────

    /// Iterates every entity that has all of `with` (a tuple of component
    /// types): `while (world.query(.{Transform, Velocity}).nextBatch()) |b|`.
    pub fn query(self: *Self, comptime with: anytype) query_mod.Query(Self, with, .{}) {
        return .{ .world = self };
    }

    /// Same, minus every entity that has any of `without`.
    pub fn queryEx(self: *Self, comptime with: anytype, comptime without: anytype) query_mod.Query(Self, with, without) {
        return .{ .world = self };
    }

    pub fn despawn(self: *Self, e: Entity) bool {
        if (!self.isAlive(e)) return false;
        const slot = &self.slots.items[e.index];
        var arch = &self.archetypes.items[slot.archetype];
        const row = slot.row;
        const scene_id = slot.scene_id;
        arch.swapRemoveRow(row);
        if (arch.len > row) {
            // The entity that moved into the hole still points at the old row.
            const moved = arch.entities[row];
            self.slots.items[moved.index].row = @intCast(row);
        }
        slot.generation += 1; // invalidate every outstanding copy of `e`
        slot.occupied = false;
        slot.archetype = 0;
        slot.row = 0;
        self.signals.off(scene_id); // its listeners must not fire anymore
        if (self.free_slots.items.len == self.free_slots.capacity) {
            self.guard("recycling a slot");
        }
        self.free_slots.append(self.allocator, e.index) catch {
            std.debug.panic("world: cannot recycle a slot", .{});
        };
        return true;
    }

    // ── Load-time internals (used by `zson`) ────────────────────────────────

    /// A row in `arch_index` owning `scene_id`, components left undefined for
    /// the decoder to fill.
    pub fn createRow(self: *Self, arch_index: u32, scene_id: SceneId) !Row {
        const e = try self.createSlot(arch_index, scene_id);
        const row = try self.pushRow(arch_index, e);
        self.slots.items[e.index].row = @intCast(row);
        return .{ .entity = e, .row = row };
    }

    /// Archetype access by index, for decoders that fill rows directly.
    pub fn archetypeAt(self: *Self, index: u32) *Archetype {
        return &self.archetypes.items[index];
    }

    fn createSlot(self: *Self, arch_index: u32, scene_id: SceneId) !Entity {
        const e = try self.allocSlot(arch_index);
        if (scene_id != 0) {
            // 0 means "fresh id": used by prefabs, which get new identities.
            self.slots.items[e.index].scene_id = scene_id;
            if (scene_id >= self.scene_id_next) self.scene_id_next = scene_id + 1;
        }
        return e;
    }

    // ── Internals ───────────────────────────────────────────────────────────

    fn allocSlot(self: *Self, arch_index: u32) !Entity {
        var index: u32 = undefined;
        if (self.free_slots.pop()) |reused| {
            index = reused;
            self.slots.items[index].generation += 1; // stale handles stay dead
        } else {
            if (self.slots.items.len == self.slots.capacity) {
                self.guard("allocating entity slots");
            }
            try self.slots.append(self.allocator, .{});
            index = @intCast(self.slots.items.len - 1);
            if (self.hierarchy.enabled and self.slots.items.len > self.hierarchy.capacity) {
                self.guard("growing the hierarchy scratch");
                try self.hierarchy.reserve(self.allocator, self.slots.items.len);
            }
        }
        const slot = &self.slots.items[index];
        slot.archetype = arch_index;
        slot.occupied = true;
        slot.scene_id = self.scene_id_next;
        self.scene_id_next += 1;
        return .{ .index = index, .generation = slot.generation };
    }

    /// Appends a row; the guard only covers capacity growth, so spawning from
    /// a reserved pool works fine while locked.
    fn pushRow(self: *Self, arch_index: u32, e: Entity) !usize {
        var arch = &self.archetypes.items[arch_index];
        if (arch.len == arch.capacity()) {
            self.guard("growing an archetype");
        }
        return arch.pushRow(self.allocator, e);
    }

    /// Moves a live entity's row into an existing archetype, fixing up both
    /// the source (swap-remove) and the entity moved into the hole.
    fn moveRow(self: *Self, e: Entity, dst_index: u32) void {
        const slot = self.slots.items[e.index];
        var src = &self.archetypes.items[slot.archetype];
        var dst = &self.archetypes.items[dst_index];

        if (dst.len == dst.capacity()) {
            self.guard("growing an archetype");
        }
        const row = dst.pushRow(self.allocator, e) catch |err| {
            std.debug.panic("world: moving an entity between archetypes failed: {s}", .{@errorName(err)});
        };
        for (dst.columns) |*dst_col| {
            const stride = dst_col.stride;
            const dst_bytes = dst_col.data[row * stride ..][0..stride];
            if (src.findColumn(dst_col.id)) |src_col| {
                const src_bytes = src.columns[src_col].data[slot.row * stride ..][0..stride];
                @memcpy(dst_bytes, src_bytes);
            } else {
                // Component that only exists on the destination: baseline.
                components.writeDefault(dst_col.id, dst_bytes);
            }
        }
        src.swapRemoveRow(slot.row);
        if (src.len > slot.row) {
            const moved = src.entities[slot.row];
            self.slots.items[moved.index].row = @intCast(slot.row);
        }
        self.slots.items[e.index].archetype = dst_index;
        self.slots.items[e.index].row = @intCast(row);
    }

    /// Writes every value of a spawn tuple into the columns of a fresh row.
    fn fillRow(self: *Self, arch_index: u32, row: usize, values: anytype) void {
        const arch = &self.archetypes.items[arch_index];
        inline for (values) |value| {
            const T = @TypeOf(value);
            const id = comptime components.componentId(T);
            // The archetype was derived from this very tuple: it must have it.
            const col = arch.findColumn(id).?;
            arch.cellPtr(T, col, row).* = value;
            // A component that interpolates needs its "previous" snapshot
            // seeded from the live value, or the very first frame renders the
            // entity at the ORIGIN and it slides in from there (the previous
            // snapshot of a fresh Transform is (0,0,0,1) by default).
            if (comptime hasPreviousState(T)) {
                arch.cellPtr(T, col, row).capturePrevious();
            }
        }
    }

    /// True for components whose `prev_*` snapshot must be seeded on creation.
    /// Kept as an explicit list rather than duck typing so adding a component
    /// with a different convention is a deliberate, reviewable line.
    fn hasPreviousState(comptime T: type) bool {
        return T == components.Transform;
    }

    /// Archetype for a key, creating it if this is the first time the world
    /// sees that component set. `ids` must be sorted.
    pub fn findOrCreateArchetype(self: *Self, key: anytype) !u32 {
        for (self.archetypes.items, 0..) |*arch, i| {
            if (arch.mask.eql(key.mask)) return @intCast(i);
        }
        self.guard("creating an archetype");
        const index: u32 = @intCast(self.archetypes.items.len);
        try self.archetypes.append(self.allocator, try Archetype.init(self.allocator, key.ids[0..]));
        return index;
    }};

// ── Archetype keys ──────────────────────────────────────────────────────────

/// Key from a tuple of component *values* (their values are runtime, only the
/// types are inspected): `spawn(.{ Transform{...} })`.
fn keyOfValueTypes(comptime Tuple: type) KeyOf(fieldCount(Tuple)) {
    return keyOfTypes(comptime typesOfFields(Tuple));
}

fn keyOfTypes(comptime types: []const type) KeyOf(types.len) {
    comptime {
        for (types, 0..) |_, i| {
            for (types, 0..) |_, j| {
                if (i != j and components.componentId(types[i]) == components.componentId(types[j])) {
                    @compileError("duplicate component in the same add/spawn list");
                }
            }
        }
    }
    var ids: [types.len]ComponentId = undefined;
    inline for (types, &ids) |T, *slot| slot.* = components.componentId(T);    std.mem.sort(ComponentId, &ids, {}, std.sort.asc(ComponentId));
    var mask = Mask.initEmpty();
    for (ids) |id| mask.set(id);
    return .{ .mask = mask, .ids = ids };
}

fn KeyOf(comptime n: usize) type {
    return struct { mask: Mask, ids: [n]ComponentId };
}

fn fieldCount(comptime Tuple: type) usize {
    return @typeInfo(Tuple).@"struct".fields.len;
}

/// Component types of a *comptime* tuple whose items are the types themselves
/// (`.{ Transform, Velocity }`), which is what `reserve` takes.
fn typesOfTuple(comptime tuple: anytype) []const type {
    comptime {
        const len = @typeInfo(@TypeOf(tuple)).@"struct".fields.len;
        var types: [len]type = undefined;
        for (tuple, &types) |item, *slot| {
            slot.* = if (@TypeOf(item) == type) item else @TypeOf(item);
        }
        const final = types;
        return &final;
    }
}

/// Component types of a tuple struct, i.e. `struct { Transform, Name }`.
fn typesOfFields(comptime Tuple: type) []const type {
    comptime {
        const info = @typeInfo(Tuple).@"struct";
        var types: [info.fields.len]type = undefined;
        for (info.fields, &types) |field, *slot| slot.* = field.type;
        const final = types;
        return &final;
    }
}

fn single(id: ComponentId) Mask {
    var mask = Mask.initEmpty();
    mask.set(id);
    return mask;
}

/// Merges `src` and `id` into a sorted `buf` of at least `src.ids.len + 1`.
/// Sorted merge: `buf` must hold at least `src.len + 1` ids.
fn mergeIds(buf: []ComponentId, src: []const ComponentId, id: ComponentId) []const ComponentId {
    std.debug.assert(buf.len >= src.len + 1);
    var i: usize = 0;
    var inserted = false;
    while (i + @intFromBool(inserted) < buf.len) {
        const slot = &buf[i + @intFromBool(inserted)];
        if (!inserted and (i >= src.len or id < src[i])) {
            slot.* = id;
            inserted = true;
        } else {
            slot.* = src[i];
            i += 1;
        }
    }
    return buf[0 .. src.len + 1];
}

/// Sorted `src` minus `id`: `buf` must hold at least `src.len` ids.
fn withoutId(buf: []ComponentId, src: []const ComponentId, id: ComponentId) []const ComponentId {
    std.debug.assert(buf.len >= src.len);
    var n: usize = 0;
    for (src) |item| {
        if (item == id) continue;
        buf[n] = item;
        n += 1;
    }
    return buf[0..n];
}

// ── Tests ───────────────────────────────────────────────────────────────────

test "spawn, read, has, despawn" {
    var world = World.init(std.testing.allocator);
    defer world.deinit();

    const e = try world.spawn(.{
        components.Name.init("player"),
        components.Transform{ .position = .{ .x = 4, .y = 8 } },
        components.Velocity{ .linear = .{ .x = 1, .y = 0 } },
    });
    try std.testing.expect(world.isAlive(e));
    try std.testing.expectEqual(@as(usize, 1), world.entityCount());

    const tr = world.get(e, components.Transform).?;
    try std.testing.expectApproxEqAbs(@as(f32, 4), tr.position.x, 0.0001);
    try std.testing.expect(world.has(e, components.Velocity));
    try std.testing.expect(!world.has(e, components.Parent));
    try std.testing.expectEqual(@as(u32, 0), world.archIndexOf(e).?); // first archetype

    try std.testing.expect(world.despawn(e));
    try std.testing.expect(!world.isAlive(e));
    try std.testing.expectEqual(@as(usize, 0), world.entityCount());
    try std.testing.expect(world.get(e, components.Transform) == null);

    // Reusing the slot invalidates the old generation.
    const e2 = try world.spawn(.{components.Name.init("enemy")});
    try std.testing.expect(e2.index == e.index);
    try std.testing.expect(e2.generation != e.generation);
    try std.testing.expect(world.despawn(e2));
}

test "add and remove move the entity between archetypes" {
    var world = World.init(std.testing.allocator);
    defer world.deinit();

    const e = try world.spawn(.{components.Transform{ .position = .{ .x = 1, .y = 2 } }});
    try world.add(e, components.Velocity{ .linear = .{ .x = 7, .y = 0 } });
    try std.testing.expect(world.has(e, components.Velocity));
    try std.testing.expect(world.has(e, components.Transform));

    // Data survived the move.
    try std.testing.expectApproxEqAbs(@as(f32, 1), world.get(e, components.Transform).?.position.x, 0.0001);
    try std.testing.expectApproxEqAbs(@as(f32, 7), world.get(e, components.Velocity).?.linear.x, 0.0001);

    // The old archetype (Transform only) is now empty.
    for (world.archetypes.items) |arch| {
        if (arch.ids.len == 1 and arch.ids[0] == 1) try std.testing.expectEqual(@as(usize, 0), arch.len);
    }

    try std.testing.expect(world.remove(e, components.Velocity));
    try std.testing.expect(!world.has(e, components.Velocity));
    try std.testing.expect(world.has(e, components.Transform));
    try std.testing.expect(!world.remove(e, components.Velocity)); // already gone
}

test "swap-remove despawn fixes the row of the entity that moved" {
    var world = World.init(std.testing.allocator);
    defer world.deinit();

    const a = try world.spawn(.{components.Name.init("a")});
    const b = try world.spawn(.{components.Name.init("b")});
    const c = try world.spawn(.{components.Name.init("c")});
    try std.testing.expect(world.despawn(a)); // the last row moves into slot 0
    try std.testing.expectEqualStrings("b", world.get(b, components.Name).?.slice());
    try std.testing.expectEqualStrings("c", world.get(c, components.Name).?.slice());
    try std.testing.expectEqual(@as(usize, 2), world.entityCount());

    // Adding a component after the shuffle must not corrupt them either.
    try world.add(b, components.Velocity{ .linear = .{ .x = 5, .y = 5 } });
    try std.testing.expectApproxEqAbs(@as(f32, 5), world.get(b, components.Velocity).?.linear.x, 0.0001);
    try std.testing.expect(!world.has(c, components.Velocity));
    try std.testing.expectEqualStrings("c", world.get(c, components.Name).?.slice());
}

test "scene ids are unique and released on despawn" {
    var world = World.init(std.testing.allocator);
    defer world.deinit();

    const e = try world.spawn(.{components.Name.init("x")});
    const id = world.sceneIdOf(e);
    try std.testing.expect(e.eql(world.findBySceneId(id).?));
    _ = try world.spawn(.{components.Name.init("y")});
    try std.testing.expect(world.despawn(e));
    try std.testing.expect(world.findBySceneId(id) == null);

    // A new entity must never reuse a scene id: that is what keeps them stable.
    const e2 = try world.spawn(.{components.Name.init("z")});
    try std.testing.expect(world.sceneIdOf(e2) != id);
}

test "reserve then spawn: no allocation while locked (spec §3.1)" {
    var world = World.init(std.testing.allocator);
    defer world.deinit();

    try world.reserveEntities(16);
    try world.reserve(.{ components.Transform, components.Velocity }, 16);
    world.lockAllocs();

    var spawned: [16]Entity = undefined;
    var i: usize = 0;
    while (i < spawned.len) : (i += 1) {
        spawned[i] = try world.spawn(.{
            components.Transform{ .position = .{ .x = @floatFromInt(i), .y = 0 } },
            components.Velocity{ .linear = .{ .x = 1, .y = 1 } },
        });
        // Reads through the reserved pool also work while locked.
        try std.testing.expectApproxEqAbs(
            @as(f32, @floatFromInt(i)),
            world.get(spawned[i], components.Transform).?.position.x,
            0.0001,
        );
    }

    // Despawning them all recycles the pool (not grows it).
    for (spawned) |e| try std.testing.expect(world.despawn(e));
    try std.testing.expectEqual(@as(usize, 16), world.free_slots.items.len);

    // Spawning again reuses the recycled slots, still without growth.
    i = 0;
    while (i < spawned.len) : (i += 1) {
        spawned[i] = try world.spawn(.{
            components.Transform{ .position = .{ .x = @floatFromInt(i), .y = 0 } },
            components.Velocity{ .linear = .{ .x = 1, .y = 1 } },
        });
    }
    world.unlockAllocs();
    try std.testing.expectEqual(@as(usize, 16), world.entityCount());
}

test "add/remove across a wide archetype key uses the heap" {
    var world = World.init(std.testing.allocator);
    defer world.deinit();

    // Deep chain of adds to outgrow the stack key buffer.
    const e = try world.spawn(.{components.Transform{}});
    const types = [_]type{ components.Velocity, components.Parent, components.Name };
    inline for (types) |T| {
        switch (T) {
            components.Velocity => try world.add(e, components.Velocity{}),
            components.Parent => try world.add(e, components.Parent{}),
            components.Name => try world.add(e, components.Name.init("wide")),
            else => unreachable,
        }
    }
    try std.testing.expect(world.has(e, components.Name));
    try std.testing.expect(world.has(e, components.Parent));
    try std.testing.expect(world.has(e, components.Velocity));
    try std.testing.expect(world.has(e, components.Transform));
}
