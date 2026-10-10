//! `engine.physics` — the physics port and its backends (ROADMAP M4).
//!
//! The public surface is `physics.World`, a thin forwarder over a `VTable`. A
//! backend (`box2d`, and later others) fills that table. The ECS components that
//! drive it — `RigidBody2D`, `Collider2D` — live in `ecs/components.zig` and
//! store opaque handles, so they do not name a solver either.
//!
//! Swapping engines is therefore: write one file implementing `physics.VTable`,
//! change one line here. Nothing in the ECS, the driver or the Lua bindings
//! moves.

const std = @import("std");

pub const physics = @import("physics.zig");

// The port's vocabulary, re-exported under short names so callers do not write
// `physics.physics.BodyType`.
pub const World = physics.World;
pub const BodyId = physics.BodyId;
pub const ShapeId = physics.ShapeId;
pub const BodyType = physics.BodyType;
pub const BodyDesc = physics.BodyDesc;
pub const Shape = physics.Shape;
pub const ShapeKind = physics.ShapeKind;
pub const Material = physics.Material;
pub const Transform = physics.Transform;
pub const Velocity = physics.Velocity;
pub const RayHit = physics.RayHit;
pub const StepStats = physics.StepStats;
pub const Gravity = physics.Gravity;
pub const VTable = physics.VTable;
pub const Vec2 = physics.Vec2;
pub const fixed_hz = physics.fixed_hz;
pub const fixed_dt = physics.fixed_dt;
pub const max_catch_up_steps = physics.max_catch_up_steps;

pub const box2d = @import("box2d.zig");
pub const driver = @import("driver.zig");

/// The fixed-step driver: owns the clock half of physics (60 Hz, one catch-up,
/// render interpolation).
pub const Driver = driver.Driver;
pub const activity = @import("activity.zig");
pub const system = @import("system.zig");

/// Distance-based activity tiers (ROADMAP M5, "open world").
pub const Activity = activity.Activity;
pub const ActivityConfig = activity.Config;
pub const Tier = activity.Tier;
pub const ActivityStats = activity.Stats;

/// The ECS-facing physics system: owns the world and syncs it both ways.
pub const System = system.System;
/// The signal collision events are published under. Re-exported so consumers
/// (the Lua layer, the demo) never have to reach past the module root for it.
pub const contact_signal = system.contact_signal;
pub const ContactEvent = system.ContactEvent;

/// Creates a world on the chosen backend.
///
/// `backend` is a comptime tag rather than a string so a typo is a compile
/// error, and so the backend's own file is only linked when it is used.
pub fn createWorld(comptime backend: Backend, gravity: Gravity) !World {
    return switch (backend) {
        .box2d => .{
            .vtable = &box2d.vtable,
            .ctx = box2d.vtable.createWorld(gravity) orelse return error.WorldCreationFailed,
            .name = box2d.backend_name,
        },
    };
}

pub const Backend = enum {
    box2d,
};

pub const Error = error{WorldCreationFailed};

test {
    std.testing.refAllDecls(@This());
    // Contacts need a real solver, so they live in their own translation unit
    // rather than behind a flag: a test that only runs when something is
    // enabled is a test nobody runs.
    _ = @import("contacts_test.zig");
    // The activity tier logic is pure decision-making with no solver in it, so
    // it is tested as such: hysteresis bugs are invisible in a benchmark,
    // because a thrashing body costs only slightly more than a still one.
    _ = @import("activity.zig");
}
