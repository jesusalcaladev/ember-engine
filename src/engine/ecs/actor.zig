//! Actor: the public facade over an entity (spec §7 — "the ECS is an internal
//! detail, the public API is Actor + Components + Signals").
//!
//! What an Actor buys over a bare `Entity`:
//! - ergonomics: `actor.get(Transform)`, `actor.setName("player")`,
//!   `actor.emit("died", 0)` read like the API they are, in a codebase where
//!   everything runtime-facing must be sayable in one line.
//! - safety: `setParent` refuses cycles *before* they become an infinite
//!   chain in the resolver, and a destroyed actor is invalidated by
//!   generation, so a stale handle panics nowhere and reads nothing.
//! - identity: `sceneId` is the stable id `.zson` writes, i.e. the one that
//!   survives save/load, undo/redo and Play-in-editor snapshots.

const std = @import("std");
const world_mod = @import("world.zig");
const entity_mod = @import("entity.zig");
const components = @import("components.zig");
const signals_mod = @import("signals.zig");
const hierarchy_mod = @import("hierarchy.zig");

const World = world_mod.World;
const Entity = entity_mod.Entity;
const SceneId = entity_mod.SceneId;
const Callback = signals_mod.Callback;

/// Safety bound for parent walks: a document guaranteeing a loop-free chain
/// is not a thing, but a 4096-deep actor tree is not a thing either.
const max_parent_walk = 4096;

pub const Actor = struct {
    world: *World,
    entity: Entity,

    // ── Creation ────────────────────────────────────────────────────────────

    /// `Actor.spawn(world, .{ Transform{...}, Name.init("player") })`.
    pub fn spawn(world: *World, values: anytype) !Actor {
        return .{ .world = world, .entity = try world.spawn(values) };
    }

    /// Facade over an existing entity (e.g. from a scene file).
    pub fn from(world: *World, e: Entity) Actor {
        return .{ .world = world, .entity = e };
    }

    // ── Identity ────────────────────────────────────────────────────────────

    pub fn isValid(self: Actor) bool {
        return self.world.isAlive(self.entity);
    }

    pub fn handle(self: Actor) Entity {
        return self.entity;
    }

    pub fn sceneId(self: Actor) SceneId {
        return self.world.sceneIdOf(self.entity);
    }

    // ── Components ──────────────────────────────────────────────────────────

    pub fn add(self: Actor, value: anytype) !void {
        try self.world.add(self.entity, value);
    }

    pub fn remove(self: Actor, comptime T: type) bool {
        return self.world.remove(self.entity, T);
    }

    pub fn get(self: Actor, comptime T: type) ?*T {
        return self.world.get(self.entity, T);
    }

    pub fn has(self: Actor, comptime T: type) bool {
        return self.world.has(self.entity, T);
    }

    /// Assigns the inline name component (creating or overwriting it).
    pub fn setName(self: Actor, display_name: []const u8) !void {
        try self.world.add(self.entity, components.Name.init(display_name));
    }

    pub fn name(self: Actor) []const u8 {
        const maybe = self.get(components.Name) orelse return "";
        return maybe.slice();
    }

    // ── Moves and transforms ────────────────────────────────────────────────

    /// World-space position of this actor (hierarchy included).
    pub fn worldPosition(self: Actor) hierarchy_mod.WorldTransform {
        return self.world.hierarchy.worldOf(self.world, self.entity);
    }

    /// Parents this actor under `parent`, refusing both self-parenting and
    /// cycles (which the resolver would otherwise have to tolerate forever).
    pub fn setParent(self: Actor, parent_actor: Actor) !void {
        if (parent_actor.entity.eql(self.entity)) return error.SelfParent;
        var cursor = parent_actor;
        var steps: usize = 0;
        while (cursor.isValid()) : (steps += 1) {
            if (steps > max_parent_walk) return error.CycleTooDeep;
            if (cursor.entity.eql(self.entity)) return error.Cycle;
            const link = cursor.get(components.Parent) orelse break;
            if (link.parent.isInvalid()) break;
            if (!self.world.isAlive(link.parent)) break;
            cursor = .{ .world = self.world, .entity = link.parent };
        }
        try self.world.add(self.entity, components.Parent{ .parent = parent_actor.entity });
    }

    pub fn parent(self: Actor) ?Actor {
        const link = self.get(components.Parent) orelse return null;
        if (!self.world.isAlive(link.parent)) return null;
        return .{ .world = self.world, .entity = link.parent };
    }

    // ── Signals ─────────────────────────────────────────────────────────────

    /// Queues a typed event; listeners registered for the same payload type
    /// fire on the next `world.signals.drain()` (spec §2).
    pub fn emit(self: Actor, comptime T: type, event: []const u8, value: T) void {
        self.world.signals.emit(T, event, value);
    }

    /// Subscribes to `event`. The connection is ordered by this actor's scene
    /// id, so listener order is stable by spawn order (spec §6).
    pub fn on(self: Actor, comptime T: type, event: []const u8, ctx: ?*anyopaque, cb: Callback) !void {
        try self.world.signals.on(T, event, self.sceneId(), ctx, cb);
    }

    // ── Lifecycle ───────────────────────────────────────────────────────────

    pub fn destroy(self: Actor) bool {
        return self.world.despawn(self.entity);
    }
};

/// Test double: payload for the signals example below.
const Damage = struct { amount: u32 };

var damage_taken: u32 = 0;

fn onDamaged(ctx: ?*anyopaque, value: *const anyopaque) void {
    const damage: *const Damage = @ptrCast(@alignCast(value));
    const total: *u32 = @ptrCast(@alignCast(ctx.?));
    total.* += damage.amount;
}

test "actor facade: spawn, components, name, destroy" {
    var world = World.init(std.testing.allocator);
    defer world.deinit();
    try world.reserveSignals(8);

    const player = try Actor.spawn(&world, .{components.Transform{ .position = .{ .x = 3, .y = 4 } }});
    try player.setName("player");
    try std.testing.expectEqualStrings("player", player.name());
    try std.testing.expect(player.isValid());
    try std.testing.expectEqual(@as(f32, 3), player.get(components.Transform).?.position.x);
    try std.testing.expect(player.has(components.Transform));

    try std.testing.expect(player.destroy());
    try std.testing.expect(!player.isValid());
    try std.testing.expectEqual(@as([]const u8, ""), player.name());
}

test "actor facade: parenting and cycle refusal" {
    var world = World.init(std.testing.allocator);
    defer world.deinit();
    try world.enableHierarchy();

    const root = try Actor.spawn(&world, .{components.Transform{ .position = .{ .x = 10, .y = 0 } }});
    try root.setName("root");
    const child = try Actor.spawn(&world, .{components.Transform{ .position = .{ .x = 0, .y = 5 } }});
    try child.setName("child");

    try child.setParent(root);
    try std.testing.expectEqualStrings("root", child.parent().?.name());

    // Parenting the root under its own descendant must be refused.
    try std.testing.expectError(error.Cycle, root.setParent(child));
    // So must self-parenting.
    try std.testing.expectError(error.SelfParent, root.setParent(root));

    // The world transform of the child is the parent's composed in. 
    world.hierarchy.resolve(&world);
    const composed = child.worldPosition();
    try std.testing.expectApproxEqAbs(@as(f32, 10), composed.position.x, 0.0001);
    try std.testing.expectApproxEqAbs(@as(f32, 5), composed.position.y, 0.0001);
}

test "actor facade: signals fire and die with the actor" {
    var world = World.init(std.testing.allocator);
    defer world.deinit();
    try world.reserveSignals(8);

    damage_taken = 0;
    const enemy = try Actor.spawn(&world, .{components.Name.init("enemy")});
    try enemy.on(Damage, "damaged", &damage_taken, onDamaged);

    enemy.emit(Damage, "damaged", .{ .amount = 4 });
    enemy.emit(Damage, "damaged", .{ .amount = 6 });
    world.signals.drain();
    try std.testing.expectEqual(@as(u32, 10), damage_taken);

    // Once the actor is gone, its listeners are gone with it.
    _ = enemy.destroy();
    enemy.emit(Damage, "damaged", .{ .amount = 1 });
    world.signals.drain();
    try std.testing.expectEqual(@as(u32, 10), damage_taken);
}
