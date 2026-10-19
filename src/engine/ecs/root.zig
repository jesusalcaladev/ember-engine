//! `engine.ecs` — data-oriented core underneath the public Actor API (spec §7:
//! the ECS is an internal detail, the API is Actor + Components + Signals).
//!
//! Layer map:
//! - `entity`: 64-bit handles with generation (no use-after-free).
//! - `components`: the facade over `components/` (ids, layout, plain-data rules).
//! - `archetype`: SoA tables; rows move with `memcpy`.
//! - `world`: slots, archetype index, spawn/add/remove/get, growth locking.
//! - `query`: typed iteration, batch-first (systems) and per-entity (actors).
//! - `hierarchy`: flat (no recursion) parent-chain resolution.
//! - `zson`: bit-exact text format + prefab overrides.
//! - `signals`: typed events, stable order by spawn, drained once per frame.
//! - `timer`: the fixed-step Timer system (M4.5).
//! - `camera`: the fixed-step Camera2D system (M4.5).
//! - `actor`: the facade the runtime and Lua bindings talk to.

pub const entity = @import("entity.zig");
pub const components = @import("components.zig");
pub const archetype = @import("archetype.zig");
pub const world = @import("world.zig");
pub const query = @import("query.zig");
pub const hierarchy = @import("hierarchy.zig");
pub const zson = @import("zson.zig");
pub const signals = @import("signals.zig");
pub const collision_layers = @import("collision_layers.zig");
pub const timer = @import("timer.zig");
pub const camera = @import("camera.zig");
pub const animation = @import("animation.zig");
pub const actor = @import("actor.zig");
/// M14: the game-UI system (canvas, layout, hit-testing, button signals).
pub const ui_system = @import("ui_system.zig");

// Short names for what the runtime and the actor code import constantly.
pub const World = world.World;
pub const Actor = actor.Actor;
pub const Entity = entity.Entity;
pub const SceneId = entity.SceneId;
pub const WorldTransform = hierarchy.WorldTransform;
pub const Layers = collision_layers.Registry;
pub const PhysicsTuning = collision_layers.Tuning;

test {
    @import("std").testing.refAllDecls(@This());
    // The cursor regression suite lives in its own file: it is about the
    // contract BETWEEN `query` and `world`, not about either one's internals,
    // and keeping it separate makes that boundary the thing under test.
    _ = @import("query_cursor_test.zig");
    _ = @import("collision_layers.zig");
    _ = @import("components_test.zig");
    // M4.5 systems: reachable only through this root, so name them here to
    // keep their tests in the suite.
    _ = @import("timer.zig");
    _ = @import("camera.zig");
    _ = @import("animation.zig");
    _ = @import("ui_system.zig");
}
