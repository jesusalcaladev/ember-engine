//! Component layout regression tests (found while documenting the registry).
//!
//! ## Why sizes are asserted, not assumed
//!
//! A component is a column in an SoA archetype, so its size is multiplied by the
//! entity count: `RigidBody2D` growing from 52 to 64 bytes is 8 bytes times every
//! body in the world, and it happens silently. Nothing in the compiler complains
//! — the code still works, it just costs memory (spec §5) and cache lines.
//!
//! So the size of every component is pinned here the same way a benchmark pins a
//! budget. A field added to a component fails a test with the number, rather than
//! showing up as a scene that uses 15% more memory and nobody knowing why.
//!
//! These are the Debug auto-layout sizes the ECS actually allocates, which is why
//! they are measured and not derived: field reordering by hand is exactly the kind
//! of "optimization" that makes the table lie. The first run of this file asserted
//! hand-computed sizes for `RigidBody2D` (56) and `Parent` (16) and was wrong on
//! both — the ECS packs both u32 fields of `Parent` into one 8-byte `Entity`, and
//! Zig's auto-layout finds a tighter arrangement for the body than reading the
//! fields suggests.

const std = @import("std");
const ecs = @import("root.zig");

const c = ecs.components;

const testing = std.testing;

test "the physics components stay handles plus plain data" {
    // Handles first (they are the hot lookup), then the plain-data fields.
    // `RigidBody2D`: 2 handles + body_type + 2 Vec2 + 4 f32 + 3 bools + tier.
    try testing.expectEqual(@as(usize, 52), @sizeOf(c.RigidBody2D));
    // `Collider2D`: 2 handles + kind + 2 Vec2 + 3 f32 + a sensor flag.
    try testing.expectEqual(@as(usize, 40), @sizeOf(c.Collider2D));
    // Two bitmasks. Deliberately tiny: it rides along on every colliding body.
    try testing.expectEqual(@as(usize, 4), @sizeOf(c.CollisionLayers));
}

test "the existing component sizes are unchanged" {
    // Pinned from the reference documentation (docs/reference/ecs-components.md);
    // a mismatch means a field was added somewhere without the table following.
    // `Parent` is 8 because both u32 fields pack into one `Entity`: the doc's
    // "16" was the same hand-computation mistake this test was written to catch.
    try testing.expectEqual(@as(usize, 33), @sizeOf(c.Name));
    try testing.expectEqual(@as(usize, 40), @sizeOf(c.Transform));
    try testing.expectEqual(@as(usize, 8), @sizeOf(c.Parent));
    try testing.expectEqual(@as(usize, 12), @sizeOf(c.Velocity));
    try testing.expectEqual(@as(usize, 52), @sizeOf(c.Sprite));
    try testing.expectEqual(@as(usize, 4), @sizeOf(c.Script));
    try testing.expectEqual(@as(usize, 8), @sizeOf(c.StateMachine));
}

test "a component field is never left uninitialized" {
    // Rule 2 of the registry: every field has a default, because a `.zson`
    // baseline and a patch override are both built from them. A struct with an
    // undefined field would compile here and break save/load.
    const rb = c.RigidBody2D{};
    try testing.expect(rb.linear_velocity.x == 0);
    try testing.expect(rb.gravity_scale == 1.0); // default gravity, not none
    try testing.expect(rb.allow_sleep); // sleeping is the default, not an opt-in
    try testing.expectEqual(@as(u8, 0), rb.tier); // full simulation

    const col = c.Collider2D{};
    try testing.expectEqual(@as(u8, 0), col.kind); // box
    try testing.expect(!col.is_sensor); // solid unless asked
}
