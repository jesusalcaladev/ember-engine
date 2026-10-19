//! The editing document: the thing the UI drives, and the bridge between a click
//! and a change in the world.
//!
//! ## What this is for
//!
//! A UI has to ask for things: "put the selected actor here", "delete it", "give
//! it a collider". Each of those is an EDIT, and an edit that did not go through
//! the stack is an edit that cannot be undone. This module is where a request
//! becomes a command, the command becomes an act on the stack, and the act
//! becomes a change in the world — with the selection, the dirty flag and the
//! labels for the undo menu living with them, because a UI that reconstructs
//! those from a stack is a UI that has the rules in three places.
//!
//! ## The two families of world edit
//!
//! The ECS can encode a whole world canonically (`zson`) but not one entity, so
//! an edit either knows enough to reverse itself or it does not:
//!
//! - **By cell.** A spawn records the cells of the entity it created and reverses
//!   by removing it; a component write records the old bytes and reverses by
//!   putting them back; an add records which component to remove; a remove
//!   records the bytes a typed add will need. These carry a few dozen bytes and
//!   are the overwhelming majority of edits.
//! - **By snapshot.** A despawn reverses only from a whole-world document,
//!   because what it destroyed was a row and its columns, its place in a
//!   hierarchy, and a scene id something else may point at. That is the honest
//!   price of an ECS that has no single-entity encoder, and worth naming: it is
//!   why a delete costs more than a drag.
//!
//! ## Coalescing
//!
//! Dragging a slider is one act, not one per pixel. A value edit carries a key
//! (the entity and the component it touched) and the act sharing it keeps its
//! FIRST old value — what an undo returns to — and takes the LAST new value —
//! what a redo writes. Both halves matter: keeping the last old value would make
//! undo return to the previous frame instead of to before the drag.
//!
//! ## Ownership
//!
//! The model takes the world and gives out its address, which never changes: a
//! structural edit swaps what the address HOLDS, like `play.Session` does, because
//! a view that cached the pointer must not have to invalidate it. And every payload
//! the model owns is freed with it, which the allocation-failure tests assert.

const std = @import("std");
const ecs = @import("ecs");
const zson = ecs.zson;
const components = ecs.components;
const undo_mod = @import("undo.zig");

const World = ecs.World;
const Entity = components.Entity;
const UndoStack = undo_mod.UndoStack(Model);

pub const Error = error{OutOfMemory} || undo_mod.Error;

/// Acts past this and the history is reset wholesale. A simple bound, and a
/// documented one: 4096 is deeper than any editing session reads, and the cost
/// is that the oldest act is gone rather than trimmed byte by byte.
const max_acts = 4096;

const Kind = enum { spawn, despawn, set, add, remove };

/// One component's bytes, as they were.
const Cell = struct {
    id: components.ComponentId,
    bytes: []u8,
};

/// One act's reversibility data. `cells` are the cells of the entity as the act
/// left it; `old`/`new` are component bytes for a write; `snapshot` is a
/// whole-world document for a despawn. Each is owned by the model and freed with
/// the act.
const Edit = struct {
    kind: Kind,
    entity: Entity,
    component: components.ComponentId = 0,
    /// The archetype and scene id the entity was in, so a redo rebuilds the same
    /// row rather than a similar one.
    arch: u32 = 0,
    scene: components.SceneId = 0,
    cells: []Cell = &.{},
    old: []u8 = &.{},
    new: []u8 = &.{},
    snapshot: []u8 = &.{},
    /// The inverse of an `add` and the redo of a `remove` are typed, because the
    /// ECS has no untyped add or remove.
    remove_fn: ?*const fn (*World, Entity) bool = null,
    add_fn: ?*const fn (*World, Entity, []const u8) bool = null,
    label: []const u8 = "",
    key_buf: [24]u8 = [_]u8{0} ** 24,
    key_len: u8 = 0,

    fn key(e: *const Edit) []const u8 {
        return e.key_buf[0..e.key_len];
    }
};

pub const Model = struct {
    allocator: std.mem.Allocator,
    /// The one world the model, the UI and the runtime read. The address is
    /// stable for the session's life: a structural edit changes what it HOLDS,
    /// which is why nothing downstream may keep a component pointer across an
    /// edit.
    cell: *World,
    stack: UndoStack = .{},
    /// One entry per act, in the same order the stack holds them, so index `i`
    /// of one is index `i` of the other.
    history: std.ArrayListUnmanaged(Edit) = .empty,
    at: usize = 0,
    selection: std.ArrayListUnmanaged(Entity) = .empty,
    dirty: bool = false,

    /// Takes ownership of the world. The caller must not deinit it afterwards.
    pub fn init(allocator: std.mem.Allocator, world_in: World) !Model {
        const cell = try allocator.create(World);
        cell.* = world_in;
        return Model{ .allocator = allocator, .cell = cell };
    }

    pub fn deinit(self: *Model) void {
        for (self.history.items) |*edit| freeEdit(self.allocator, edit);
        self.history.deinit(self.allocator);
        self.selection.deinit(self.allocator);
        self.stack.deinit(self.allocator);
        self.cell.deinit();
        self.allocator.destroy(self.cell);
        self.* = undefined;
    }

    pub fn world(self: *const Model) *World {
        return self.cell;
    }

    pub fn entityCount(self: *const Model) usize {
        return self.cell.entityCount();
    }

    // ── Undo / redo ────────────────────────────────────────────────────────

    pub fn canUndo(self: *const Model) bool {
        return self.stack.canUndo();
    }

    pub fn canRedo(self: *const Model) bool {
        return self.stack.canRedo();
    }

    pub fn undoDepth(self: *const Model) usize {
        return self.stack.depth();
    }

    /// The label of the act undo would reverse, for the menu: "Undo set".
    pub fn undoLabel(self: *const Model) ?[]const u8 {
        return self.stack.undoLabel();
    }

    pub fn redoLabel(self: *const Model) ?[]const u8 {
        return self.stack.redoLabel();
    }

    pub fn undo(self: *Model) ?[]const u8 {
        if (!self.canUndo()) return null;
        // The index moves BEFORE the stack runs the revert, because the revert
        // reads the payload at the new index.
        self.at -= 1;
        const label = self.stack.undo() orelse {
            self.at += 1;
            return null;
        };
        self.dirty = true;
        // An undo can retire a handle (a despawned spawn is gone, and
        // the ECS never resurrects a generation), so the selection is
        // pruned to what is still alive rather than left holding a
        // handle that names nothing.
        self.pruneSelection();
        return label;
    }

    pub fn redo(self: *Model) ?[]const u8 {
        if (!self.canRedo()) return null;
        // Same, the other way round: the redo reads the payload at at - 1.
        self.at += 1;
        const label = self.stack.redo() orelse {
            self.at -= 1;
            return null;
        };
        self.dirty = true;
        self.pruneSelection();
        return label;
    }

    pub fn clearHistory(self: *Model) void {
        for (self.history.items) |*edit| freeEdit(self.allocator, edit);
        self.history.clearRetainingCapacity();
        self.at = 0;
        self.stack.clear(self.allocator);
    }

    // ── Selection ──────────────────────────────────────────────────────────

    pub fn selected(self: *const Model) []const Entity {
        return self.selection.items;
    }

    pub fn select(self: *Model, entity: Entity) !void {
        self.selection.clearRetainingCapacity();
        try self.selection.append(self.allocator, entity);
    }

    pub fn addSelection(self: *Model, entity: Entity) !void {
        for (self.selection.items) |e| {
            if (e.index == entity.index) return;
        }
        try self.selection.append(self.allocator, entity);
    }

    /// Replaces the whole selection with a list — the drag-select marquee.
    ///
    /// It REPLACES rather than merges, because a marquee is a statement about
    /// what is selected, not an addition to what was. The handles are checked
    /// for liveness first: a marquee that caught an entity which died in the
    /// same frame would leave a dead handle in the selection, and a dead
    /// handle in the selection is an entity nothing can act on.
    pub fn setSelection(self: *Model, entities: []const Entity) !void {
        self.selection.clearRetainingCapacity();
        for (entities) |e| {
            if (!self.cell.isAlive(e)) continue;
            var already = false;
            for (self.selection.items) |s| {
                if (s.index == e.index and s.generation == e.generation) {
                    already = true;
                    break;
                }
            }
            if (already) continue;
            try self.selection.append(self.allocator, e);
        }
    }

    /// Drops dead handles from the selection. Called after every undo
    /// and redo, because those are the only moments a handle can die
    /// without the editor asking for it.
    fn pruneSelection(self: *Model) void {
        var i: usize = 0;
        while (i < self.selection.items.len) {
            if (!self.cell.isAlive(self.selection.items[i])) {
                _ = self.selection.orderedRemove(i);
                continue;
            }
            i += 1;
        }
    }

    pub fn clearSelection(self: *Model) void {
        self.selection.clearRetainingCapacity();
    }

    // ── World edits, each one act ──────────────────────────────────────────

    /// Creates an entity from the values given, and returns its handle — which
    /// is why it is applied before the act is recorded: the caller wants the
    /// handle (to select it, to focus the viewport) and a command cannot hand one
    /// back from inside a push.
    pub fn spawn(self: *Model, values: anytype) !Entity {
        const e = try self.cell.spawn(values);
        try self.push(.{
            .kind = .spawn,
            .entity = e,
            .arch = self.cell.archIndexOf(e) orelse 0,
            .scene = self.cell.sceneIdOf(e),
            .cells = try self.captureCells(e),
            .label = "spawn",
        });
        return e;
    }

    /// Journals a row an EDITOR made outside the model's typed API — a prefab
    /// instantiation lands rows through `zson.instantiate`, which creates
    /// archetypes the typed spawn cannot spell — as a spawn act. Undo despawns
    /// the row; redo rebuilds it from the captured cells, exactly like `spawn`'s
    /// own payload. The row must already exist and hold its final components:
    /// the cells are captured as they are NOW, so anything that changes them
    /// afterwards (a name uniquification, say) has to happen BEFORE the
    /// journaling, or the redo replays the older bytes.
    pub fn journalSpawn(self: *Model, entity: Entity, label: []const u8) !void {
        if (!self.cell.isAlive(entity)) return error.NoSuchEntity;
        try self.push(.{
            .kind = .spawn,
            .entity = entity,
            .arch = self.cell.archIndexOf(entity) orelse 0,
            .scene = self.cell.sceneIdOf(entity),
            .cells = try self.captureCells(entity),
            .label = label,
        });
    }

    /// Destroys an entity. One act, and the expensive kind: the payload is a
    /// whole-world document, because what is destroyed may be a row another
    /// entity's parent field points at.
    pub fn despawn(self: *Model, entity: Entity) !void {
        const snapshot = try zson.encodeToString(self.cell, self.allocator);
        if (!self.cell.despawn(entity)) return error.NoSuchEntity;
        try self.push(.{ .kind = .despawn, .entity = entity, .snapshot = snapshot, .label = "despawn" });
    }

    /// Writes a component. One act, coalescing on the pair (entity, component):
    /// a drag is one act, and undo returns to before the drag.
    pub fn set(self: *Model, comptime T: type, entity: Entity, value: T) !void {
        const ptr = self.cell.get(entity, T) orelse return error.NoSuchComponent;
        const old = try self.allocator.dupe(u8, std.mem.asBytes(ptr));
        errdefer self.allocator.free(old);
        const new = try self.allocator.dupe(u8, std.mem.asBytes(&value));
        errdefer self.allocator.free(new);

        var edit = Edit{
            .kind = .set,
            .entity = entity,
            .component = components.componentId(T),
            .old = old,
            .new = new,
            .label = "set",
        };
        edit.key_len = @intCast((std.fmt.bufPrint(&edit.key_buf, "s.{d}.{d}", .{ entity.index, edit.component }) catch return error.BadKey).len);
        ptr.* = value;
        try self.push(edit);
    }

    /// Adds a component. One act; undoing removes exactly that
    /// component, and redoing adds it back with the value it was
    /// given — so the act carries those bytes too.
    pub fn add(self: *Model, entity: Entity, value: anytype) !void {
        const T = @TypeOf(value);
        try self.cell.add(entity, value);
        const new = try self.allocator.dupe(u8, std.mem.asBytes(&value));
        errdefer self.allocator.free(new);
        try self.push(.{
            .kind = .add,
            .entity = entity,
            .component = components.componentId(T),
            .new = new,
            .remove_fn = removeByType(T),
            .add_fn = addBytesByType(T),
            .label = "add",
        });
    }

    /// Removes a component, remembering its bytes. One act; undoing adds it back
    /// with the value it had a moment ago.
    pub fn remove(self: *Model, comptime T: type, entity: Entity) !void {
        const ptr = self.cell.get(entity, T) orelse return error.NoSuchComponent;
        const old = try self.allocator.dupe(u8, std.mem.asBytes(ptr));
        errdefer self.allocator.free(old);
        if (!self.cell.remove(entity, T)) return error.NoSuchComponent;
        try self.push(.{
            .kind = .remove,
            .entity = entity,
            .component = components.componentId(T),
            .old = old,
            .add_fn = addBytesByType(T),
            .label = "remove",
        });
    }

    // ── The stack's entry points ───────────────────────────────────────────

    /// Applies the act at `at`, which `push` has already advanced past.
    fn applyForward(self: *Model) Error!void {
        if (self.at == 0 or self.at > self.history.items.len) return;
        const edit = self.history.items[self.at - 1];
        self.runForward(edit) catch return;
    }

    /// Reverses the act at `at`, which `undo` has already moved below.
    fn applyInverse(self: *Model) Error!void {
        if (self.at >= self.history.items.len) return;
        const edit = self.history.items[self.at];
        self.runInverse(edit) catch return;
    }

    fn runForward(self: *Model, edit: Edit) Error!void {
        switch (edit.kind) {
            .spawn => try self.rebuildEntity(edit),
            .despawn => {
                if (self.cell.despawn(edit.entity)) {}
            },
            .set => try self.writeComponent(edit.entity, edit.component, edit.new),
            // Redo of an add puts the component back; redo of a remove
            // takes it away again. The two directions are mirrored in
            // runInverse, and getting one backwards is an act that
            // "undoes" itself in one step.
            .add => if (edit.add_fn) |f| {
                _ = f(self.cell, edit.entity, edit.new);
            },
            .remove => if (edit.remove_fn) |f| {
                _ = f(self.cell, edit.entity);
            },
        }
    }

    fn runInverse(self: *Model, edit: Edit) Error!void {
        switch (edit.kind) {
            .spawn => _ = self.cell.despawn(edit.entity),
            .despawn => try self.restoreSnapshot(edit.snapshot),
            .set => try self.writeComponent(edit.entity, edit.component, edit.old),
            .add => if (edit.remove_fn) |f| {
                _ = f(self.cell, edit.entity);
            },
            .remove => if (edit.add_fn) |f| {
                _ = f(self.cell, edit.entity, edit.old);
            },
        }
    }

    fn writeComponent(self: *Model, entity: Entity, component: components.ComponentId, bytes: []u8) Error!void {
        const cell = self.cell.getById(entity, component) orelse return;
        if (cell.len < bytes.len) return;
        @memcpy(cell[0..bytes.len], bytes);
        self.dirty = true;
    }

    /// Rebuilds an entity the way the payload left it: the same archetype, the
    /// same scene id, the same cells. Recreating the ROW rather than the value
    /// is what makes a redo land in the same archetype and the same slot.
    fn rebuildEntity(self: *Model, edit: Edit) Error!void {
        const row = try self.cell.createRow(edit.arch, edit.scene);
        const arch = self.cell.archetypeAt(edit.arch);
        for (edit.cells) |cell| {
            const col = arch.findColumn(cell.id) orelse continue;
            const dst = arch.columnBytes(col, row.row);
            @memcpy(dst[0..@min(dst.len, cell.bytes.len)], cell.bytes);
        }
        self.dirty = true;
    }

    /// Rebuilds the world from a document, swapping the contents of the cell so
    /// the address — the one every view has cached — keeps its meaning.
    fn restoreSnapshot(self: *Model, text: []u8) Error!void {
        if (text.len == 0) return;
        const restored = try self.allocator.create(World);
        errdefer self.allocator.destroy(restored);
        restored.* = zson.decode(self.allocator, text) catch return error.OutOfMemory;
        var old: World = self.cell.*;
        self.cell.* = restored.*;
        old.deinit();
        self.allocator.destroy(restored);
        self.dirty = true;
    }

    /// The cells of an entity, captured as they are now: what a redo has to land
    /// on. Component bytes, not component types, because a payload cannot hold a
    /// type and this one has to survive an undo and a redo.
    fn captureCells(self: *Model, entity: Entity) ![]Cell {
        const arch_index = self.cell.archIndexOf(entity) orelse return &.{};
        const arch = self.cell.archetypeAt(arch_index);
        const row = self.cell.rowOf(entity);
        var cells: std.ArrayListUnmanaged(Cell) = .empty;
        errdefer cells.deinit(self.allocator);
        for (arch.ids) |id| {
            const col = arch.findColumn(id) orelse continue;
            const bytes = try self.allocator.dupe(u8, arch.columnBytes(col, row));
            try cells.append(self.allocator, .{ .id = id, .bytes = bytes });
        }
        return cells.toOwnedSlice(self.allocator);
    }

    // ── Recording ─────────────────────────────────────────────────────────

    /// Records an already-applied edit as one act, keeping the payload list and
    /// the stack in index lockstep.
    fn push(self: *Model, edit: Edit) Error!void {
        if (self.history.items.len >= max_acts) self.clearHistory();

        // A new act discards the payloads of a redo that is about to stop
        // existing.
        var i = self.at;
        while (i < self.history.items.len) : (i += 1) freeEdit(self.allocator, &self.history.items[i]);
        self.history.shrinkRetainingCapacity(self.at);

        try self.history.append(self.allocator, edit);
        self.at += 1;
        try self.stack.pushApplied(self.allocator, .{
            .label = edit.label,
            .ctx = self,
            .applyFn = modelApplyForward,
            .revertFn = modelApplyInverse,
            .coalesceFn = modelCoalesceKey,
        });

        // The stack merged this act into the previous one. The payload it
        // kept is the one BEFORE this entry — its `old` bytes are what an
        // undo returns to, so they stay; only `new` moves over, because a
        // redo writes what the run ENDED as.
        if (self.stack.depth() < self.history.items.len) {
            const extra_i = self.history.items.len - 1;
            const kept = extra_i - 1;
            var extra = self.history.items[extra_i];
            // The kept act's `new` is superseded: only the LAST
            // value of the run is worth keeping, and every value
            // before it is garbage the moment a newer one lands.
            self.allocator.free(self.history.items[kept].new);
            self.history.items[kept].new = extra.new;
            extra.new = &.{};
            freeEdit(self.allocator, &extra);
            self.history.shrinkRetainingCapacity(extra_i);
            // The act count moves with the payload: `at`, the payload
            // list and the stack all agree on how many acts exist,
            // and an undo reads the payload at the index the stack
            // is standing on.
            self.at -= 1;
        }
    }

    /// The coalescing key of the act last pushed — the key the next one merges
    /// with. Null for everything but a value edit.
    fn coalesceKey(self: *Model) ?[]const u8 {
        if (self.at == 0 or self.at > self.history.items.len) return null;
        const top = self.history.items[self.at - 1];
        if (top.key_len == 0) return null;
        return top.key();
    }
};

/// The stack's apply and revert are at file scope: the stack stores `*Model`,
/// and a pointer to a method on it would need a `**Model` to go through `self`.
fn modelApplyForward(self: *Model) Error!void {
    return Model.applyForward(self);
}

fn modelApplyInverse(self: *Model) Error!void {
    return Model.applyInverse(self);
}

/// The stack's coalesce key, at file scope for the same reason as the two above.
fn modelCoalesceKey(self: *Model) ?[]const u8 {
    return Model.coalesceKey(self);
}

/// A monomorphised, untyped `World.remove`, so a payload can hold one without
/// holding a type.
fn removeByType(comptime T: type) *const fn (*World, Entity) bool {
    return &struct {
        fn f(w: *World, e: Entity) bool {
            return w.remove(e, T);
        }
    }.f;
}

/// A monomorphised untyped add: the bytes, plus the type to interpret them as.
fn addBytesByType(comptime T: type) *const fn (*World, Entity, []const u8) bool {
    return &struct {
        fn f(w: *World, e: Entity, bytes: []const u8) bool {
            if (bytes.len != @sizeOf(T)) return false;
            var value: T = undefined;
            @memcpy(std.mem.asBytes(&value), bytes);
            w.add(e, value) catch return false;
            return true;
        }
    }.f;
}

fn freeEdit(allocator: std.mem.Allocator, edit: *Edit) void {
    allocator.free(edit.old);
    allocator.free(edit.new);
    allocator.free(edit.snapshot);
    for (edit.cells) |*cell| allocator.free(cell.bytes);
    allocator.free(edit.cells);
    edit.* = undefined;
}

// ─── Tests ───────────────────────────────────────────────────────────────────

const testing = std.testing;

fn testWorld(a: std.mem.Allocator) !World {
    var world = World.init(a);
    errdefer world.deinit();
    try world.enableHierarchy();
    _ = try world.spawn(.{components.Transform{ .position = .{ .x = 1.5, .y = -2.25 } }});
    // The player carries what the tests drag around: a Transform to
    // set, and a name to find it by after an undo rebuilt it.
    _ = try world.spawn(.{
        components.Transform{ .position = .{ .x = 1.5, .y = -2.25 } },
        components.Name.init("player"),
    });
    return world;
}

fn testModel() !Model {
    return Model.init(testing.allocator, try testWorld(testing.allocator));
}

test "a spawn is one act, and undo removes it" {
    var m = try testModel();
    defer m.deinit();
    const before = m.entityCount();
    const e = try m.spawn(.{components.Name.init("boss")});
    try testing.expectEqual(before + 1, m.entityCount());
    try testing.expectEqualStrings("spawn", m.undoLabel().?);
    _ = m.undo();
    try testing.expectEqual(before, m.entityCount());
    _ = m.redo();
    try testing.expectEqual(before + 1, m.entityCount());
    // The ECS bumps a slot's generation on every despawn and never
    // resurrects one, so a redone spawn is a NEW handle carrying the
    // same components: it is found by what it is, not by the handle
    // the caller held.
    try testing.expect(!m.world().isAlive(e));
    const boss = m.world().findByName("boss") orelse return error.NoBoss;
    try testing.expect(m.world().isAlive(boss));
}

test "a slider drag is one act, and undo returns to before it" {
    var m = try testModel();
    defer m.deinit();
    const player = m.world().entityAtSlot(1).?;

    try m.set(components.Transform, player, components.Transform{ .position = .{ .x = 2, .y = 0 } });
    try m.set(components.Transform, player, components.Transform{ .position = .{ .x = 3, .y = 0 } });
    try m.set(components.Transform, player, components.Transform{ .position = .{ .x = 4, .y = 0 } });

    try testing.expectEqual(@as(usize, 1), m.undoDepth());
    try testing.expectEqual(@as(f32, 4), m.world().get(player, components.Transform).?.position.x);

    // Undo returns to before the drag, not to the frame before the last pixel.
    _ = m.undo();
    try testing.expectEqual(@as(f32, 1.5), m.world().get(player, components.Transform).?.position.x);
    _ = m.redo();
    try testing.expectEqual(@as(f32, 4), m.world().get(player, components.Transform).?.position.x);
}

test "a despawn restores the exact world, hierarchy included" {
    var m = try testModel();
    defer m.deinit();
    const block = m.world().entityAtSlot(0).?;
    _ = try m.spawn(.{
        components.Transform{ .position = .{ .x = 3, .y = 4 } },
        components.Parent{ .parent = block },
    });
    const before = zson.hash(m.world());

    try m.despawn(block);
    try testing.expect(m.world().entityCount() != 3);
    _ = m.undo();

    // The child's parent pointer and the destroyed row are both back: this is
    // the criterion, and the reason the payload is a whole document.
    try testing.expectEqual(before, zson.hash(m.world()));
}

test "add and remove are one act each, and reverse each other" {
    var m = try testModel();
    defer m.deinit();
    const player = m.world().entityAtSlot(1).?;

    try m.add(player, components.Velocity{ .linear = .{ .x = 5, .y = 6 } });
    try testing.expect(m.world().has(player, components.Velocity));
    try testing.expectEqual(@as(f32, 5), m.world().get(player, components.Velocity).?.linear.x);

    _ = m.undo();
    try testing.expect(!m.world().has(player, components.Velocity));
    _ = m.redo();
    try testing.expect(m.world().has(player, components.Velocity));
    try testing.expectEqual(@as(f32, 5), m.world().get(player, components.Velocity).?.linear.x);

    // Removing keeps the bytes, so an undo brings the same value back.
    try m.remove(components.Velocity, player);
    try testing.expect(!m.world().has(player, components.Velocity));
    _ = m.undo();
    try testing.expect(m.world().has(player, components.Velocity));
    try testing.expectEqual(@as(f32, 5), m.world().get(player, components.Velocity).?.linear.x);
}

test "the undo menu has a label, and the selection is the model's" {
    var m = try testModel();
    defer m.deinit();
    const player = m.world().entityAtSlot(1).?;
    try testing.expect(m.undoLabel() == null);

    try m.set(components.Transform, player, components.Transform{ .position = .{ .x = 9, .y = 9 } });
    try testing.expectEqualStrings("set", m.undoLabel().?);

    try m.select(player);
    try testing.expectEqual(@as(usize, 1), m.selected().len);
    try testing.expectEqual(@as(u32, 1), m.selected()[0].index);
    m.clearSelection();
    try testing.expectEqual(@as(usize, 0), m.selected().len);
}

test "a new act discards the redo" {
    var m = try testModel();
    defer m.deinit();
    const player = m.world().entityAtSlot(1).?;
    try m.set(components.Transform, player, components.Transform{ .position = .{ .x = 1, .y = 0 } });
    _ = m.undo();
    try testing.expect(m.canRedo());
    _ = try m.spawn(.{components.Name.init("late")});
    try testing.expect(!m.canRedo());
}

test "a spawn is undone and redone into the same archetype" {
    // The payload records the archetype and the scene id, so a redo rebuilds the
    // row rather than creating a similar-looking one: the same components, in the
    // same order, in the same archetype.
    var m = try testModel();
    defer m.deinit();
    const arch = try m.spawn(.{
        components.Name.init("runner"),
        components.Transform{ .position = .{ .x = 7, .y = 8 } },
        components.Velocity{ .linear = .{ .x = 1, .y = 2 } },
    });
    const where = m.world().archIndexOf(arch).?;
    _ = m.undo();
    try testing.expect(!m.world().isAlive(arch));
    _ = m.redo();
    const runner = m.world().findByName("runner") orelse return error.NoRunner;
    // Same archetype as the spawn left it, and the same values in it.
    try testing.expectEqual(where, m.world().archIndexOf(runner).?);
    try testing.expectEqual(@as(f32, 7), m.world().get(runner, components.Transform).?.position.x);
    try testing.expectEqual(@as(f32, 1), m.world().get(runner, components.Velocity).?.linear.x);
}

test "nothing leaks when history is cleared with payloads in it" {
    var m = try testModel();
    defer m.deinit();
    const player = m.world().entityAtSlot(1).?;
    try m.set(components.Transform, player, components.Transform{ .position = .{ .x = 1, .y = 1 } });
    _ = try m.spawn(.{components.Name.init("a")});
    _ = try m.spawn(.{components.Name.init("b")});
    try m.add(player, components.Velocity{ .linear = .{ .x = 0, .y = 0 } });
    // Bytes in cells, in writes, in snapshots: all of them are the model's, and
    // all of them go with it.
    m.clearHistory();
    try testing.expectEqual(@as(usize, 0), m.undoDepth());
}
