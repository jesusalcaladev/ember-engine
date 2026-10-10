//! The shared engine context every Lua binding reaches through its upvalue.
//!
//! It exists so the C functions in `bindings.zig` stay allocation-free and
//! global-free: each is registered as a 1-upvalue closure over a pointer to
//! this struct, so `ctxOf(L)` is one userdata read — no map, no global fetch,
//! no per-call allocation (spec §3.1, ROADMAP M3 "zero-allocation-per-call").
//!
//! What it holds and why:
//! - `world`: the ECS the Actor facade talks to. Lua never sees the ECS type;
//!   it only ever passes the entity handle stamped into its `self` table.
//! - `input`: the action-based input snapshot for this frame. The runtime fills
//!   it once per frame from the platform layer; bindings only read it.
//! - `signals`: the typed signal bus, so `actor.emit` queues into the same
//!   stable-order, drained-once system the rest of the engine uses (spec §6).
//!
//! The `script` module imports the ECS only through the narrow types it needs
//! (World, Entity, components), keeping the Lua boundary from leaking ECS
//! internals into gameplay.

const std = @import("std");
const ecs = @import("ecs");
const input_mod = @import("input.zig");
const core_random = @import("core").random;
const statemachine = @import("statemachine.zig");
const spatial = @import("spatial.zig");
const physics_mod = @import("physics");

pub const World = ecs.World;
pub const Actor = ecs.Actor;
pub const Entity = ecs.Entity;
pub const components = ecs.components;
pub const Vec2 = components.Vec2;
pub const Transform = components.Transform;

/// Re-export the action-based input snapshot (filled by the runtime per frame).
pub const Input = input_mod.Input;

/// The physics world the bindings query (ROADMAP M4).
///
/// This is the PORT's `World` — a vtable plus an opaque context — and not the
/// `System` that owns it. Two consequences worth stating, because they are the
/// reason the port exists at all:
///
/// - The Lua layer never learns which solver is behind the questions. Swapping
///   Box2D for another engine changes `physics_mod.createWorld`, and this file
///   does not move.
/// - The bindings can ask the world things (raycasts) without owning the clock.
///   Stepping belongs to the `Driver`, which the runtime drives; a script that
///   could step the world itself could break the fixed-60 Hz contract that
///   determinism rests on.
pub const PhysicsWorld = physics_mod.World;

/// The ECS-facing physics system, which is what Lua actually talks to.
///
/// Not the raw `World`: the port's `World` is the solver's door, and going
/// through it directly is how an impulse gets silently cancelled (`pushDown`
/// re-asserts the component's velocity every frame, wiping anything set on the
/// solver between frames). The `System` is the layer that knows about the
/// frame, and gameplay needs the frame's semantics.
pub const PhysicsSystem = physics_mod.System;

/// What the camera can see, for render culling. Mirrors `render.ViewRect` but is
/// declared here so the script module does not have to import the renderer.
pub const RenderViewRect = struct {
    min_x: f32 = 0,
    min_y: f32 = 0,
    max_x: f32 = 0,
    max_y: f32 = 0,
};

/// The counters `render.stats()` reports.
pub const RenderStats = struct {
    entities: u32 = 0,
    instances: u32 = 0,
    culled: u32 = 0,
    hidden: u32 = 0,
};

/// The shared engine state shared by all Lua bindings. One per runtime; tests build
/// their own. It borrows `world` (does not own it): the runtime owns the World
/// and the Vm, and this struct is the bridge between them for script calls.
pub const Context = struct {
    world: *World,
    input: *const Input,
    /// The one PRNG every Lua `rand.*` call draws from (ROADMAP M4.5). It lives
    /// here rather than in a module global so that two runtimes (the editor and
    /// a test, say) never share a sequence, and so `save/load` has exactly one
    /// place to snapshot it for determinism (spec §6).
    rng: core_random.Rng,
    /// The default seed for the `noise.*` functions. Per-call, not per-Context:
    /// two subsystems wanting different noise fields pass their own seed, so
    /// terrain height does not move when the cloud layer is re-seeded.
    noise_seed: u64,
    /// The state-machine registry (ROADMAP M4.5). Null when the runtime has no
    /// machine support wired (a headless tool, a test): the `sm.*` bindings then
    /// report failure instead of reaching through a null pointer.
    machines: ?*statemachine.Registry = null,
    /// The spatial grid behind `world.nearby` (ROADMAP M4.5). Null for the same
    /// reason as `machines`; `nearby` then reports zero neighbours rather than
    /// scanning the world linearly, so a missing grid fails safe instead of
    /// silently turning an O(n^2) query into a correct-but-slow one.
    spatial: ?*spatial.Grid = null,
    /// The physics world, or null when the runtime has none (a headless tool, a
    /// test, an editor previewing a scene without physics). Null rather than a
    /// dummy world on purpose: a dummy would answer "nothing in the way" to a
    /// line-of-sight test, and a guard the AI reads as "clear shot" is worse
    /// than a hard failure. The bindings report the failure instead.
    physics: ?*PhysicsSystem = null,

    /// The camera's view for RENDER culling, which is a different rectangle from
    /// the physics one on purpose: the renderer asks "can I see it", physics asks
    /// "can it affect anything", and those are not the same question. A sprite
    /// just off-screen is not worth drawing and IS worth simulating if something
    /// can still walk into it.
    render_view: RenderViewRect = .{},
    render_view_enabled: bool = false,
    /// Which atlas slots currently hold a resident texture. All set by default:
    /// a machine with no streaming wants no skipping, and a mask of zeroes would
    /// render nothing at all and look like a bug rather than a policy.
    render_resident: [4]u64 = .{ 1, 1, 1, 1 },
    /// The last frame's render stats, so `render.stats()` is a read rather than
    /// a cross-module call from a binding.
    render_stats: RenderStats = .{},

    pub fn init(world: *World, input: *const Input) Context {
        return .{
            .world = world,
            .input = input,
            // A fixed default, NOT the clock: a run that starts from an
            // unseedable generator cannot be reproduced, which would break the
            // determinism contract from the first frame.
            .rng = core_random.Rng.init(core_random.Rng.default_seed),
            .noise_seed = 0,
        };
    }

    /// The Actor facade over a handle, for a binding that resolved an entity
    /// from a `self` table. Cheap: a struct of two words.
    pub fn actor(self: *const Context, e: Entity) Actor {
        return Actor.from(self.world, e);
    }
};
