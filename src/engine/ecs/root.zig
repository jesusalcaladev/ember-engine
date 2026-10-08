//! `engine.ecs` — data-oriented core underneath the public Actor API (spec §7:
//! the ECS is an internal detail, the API is Actor + Components + Signals).
//!
//! Layer map:
//! - `entity`: 64-bit handles with generation (no use-after-free).
//! - `components`: the registry (ids, layout, plain-data rules).
//! - `archetype`: SoA tables; rows move with `memcpy`.
//! - `world`: slots, archetype index, spawn/add/remove/get, growth locking.
//! - `query`: typed iteration, batch-first (systems) and per-entity (actors).
//! - `hierarchy`: flat (no recursion) parent-chain resolution.
//! - `zson`: bit-exact text format + prefab overrides.
//! - `signals`: typed events, stable order by spawn, drained once per frame.
//! - `actor`: the facade the runtime and Lua bindings talk to.

pub const entity = @import("entity.zig");
pub const components = @import("components.zig");
pub const archetype = @import("archetype.zig");
pub const world = @import("world.zig");
pub const query = @import("query.zig");
pub const hierarchy = @import("hierarchy.zig");
pub const zson = @import("zson.zig");
pub const signals = @import("signals.zig");
pub const actor = @import("actor.zig");

// Short names for what the runtime and the actor code import constantly.
pub const World = world.World;
pub const Actor = actor.Actor;
pub const Entity = entity.Entity;
pub const SceneId = entity.SceneId;
pub const WorldTransform = hierarchy.WorldTransform;

test {
    @import("std").testing.refAllDecls(@This());
}
