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

pub const World = ecs.World;
pub const Actor = ecs.Actor;
pub const Entity = ecs.Entity;
pub const components = ecs.components;
pub const Vec2 = components.Vec2;
pub const Transform = components.Transform;

/// Re-export the action-based input snapshot (filled by the runtime per frame).
pub const Input = input_mod.Input;

/// The engine state shared by all Lua bindings. One per runtime; tests build
/// their own. It borrows `world` (does not own it): the runtime owns the World
/// and the Vm, and this struct is the bridge between them for script calls.
pub const Context = struct {
    world: *World,
    input: *const Input,

    pub fn init(world: *World, input: *const Input) Context {
        return .{ .world = world, .input = input };
    }

    /// The Actor facade over a handle, for a binding that resolved an entity
    /// from a `self` table. Cheap: a struct of two words.
    pub fn actor(self: *const Context, e: Entity) Actor {
        return Actor.from(self.world, e);
    }
};
