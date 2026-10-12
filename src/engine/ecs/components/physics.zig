//! Physics components — `RigidBody2D`, `Collider2D` and `CollisionLayers`
//! (ROADMAP M4, split out of components.zig).

const std = @import("std");
const core_math = @import("core").math;

pub const Vec2 = core_math.Vec2;

/// A rigid body in the physics world (ROADMAP M4).
///
/// The three body kinds Godot calls StaticBody2D / AnimatableBody2D /
/// RigidBody2D are ONE component with a `body_type`, not three components. That
/// is the difference that matters: an actor switching from fixed to kinematic at
/// runtime — a door opening, a platform starting to move, a character mounting
/// one — does not change archetype, so it does not trigger a row move, a
/// structural change, or a spike (spec §3.1).
///
/// It is a HANDLE, forced by registry rule 1: a body id from the physics backend
/// is not plain data, so the component stores the port's generation-tagged id
/// and the solver's own state stays on the physics side. Swapping the backend
/// changes nothing here.
///
/// `prev_*` are the fixed-step snapshots the renderer interpolates between, the
/// same trick `Transform` uses: the solver must not be asked to interpolate, and
/// gameplay must not see a half-step position.
pub const RigidBody2D = struct {
    /// Port body handle; `invalid` means "not in a physics world".
    body: u32 = invalid_body,
    generation: u32 = 0,

    /// 0 fixed, 1 kinematic, 2 dynamic — mirrors `physics.BodyType` and is
    /// stored as a small integer because components are byte-compared by the
    /// archetype mover.
    body_type: u8 = 2,

    /// Linear velocity in units/second, kept in the component as well as in the
    /// solver: gameplay reads and writes it every frame without a physics call.
    linear_velocity: Vec2 = .{},
    /// Radians per second, positive clockwise on screen.
    angular_velocity: f32 = 0.0,

    linear_damping: f32 = 0.0,
    angular_damping: f32 = 0.0,
    gravity_scale: f32 = 1.0,
    /// Locked rotation. The default for anything that must not tip over.
    fixed_rotation: bool = false,
    allow_sleep: bool = true,
    is_bullet: bool = false,

    /// The snapshot from the previous fixed step, for render interpolation.
    prev_position: Vec2 = .{},
    prev_rotation: f32 = 0.0,

    /// How much physics this body is getting, as a `physics.Tier` ordinal.
    /// 0 = full.
    ///
    /// Stored here rather than in a side table because it is part of the body's
    /// state: it must survive save/load, and the determinism hash covers it, so
    /// two runs that tier differently cannot pass.
    tier: u8 = 0,

    pub const invalid_body = std.math.maxInt(u32);

    pub fn isSimulated(self: RigidBody2D) bool {
        return self.body != invalid_body;
    }
};

/// A collision shape attached to a body (ROADMAP M4).
///
/// Separate from `RigidBody2D` so one body can carry several — a character's
/// torso, head and feet, a platform's surface and its trigger — each with its
/// own material. It also means the (much larger) shape description lives in the
/// physics backend, and the component stays small enough that a hundred shapes
/// do not matter.
pub const Collider2D = struct {
    /// Port shape handle; `invalid` means "not in a physics world".
    shape: u32 = std.math.maxInt(u32),
    generation: u32 = 0,

    /// 0 box, 1 circle, 2 capsule, 3 cylinder, 4 polygon — mirrors `physics.ShapeKind`.
    kind: u8 = 0,

    /// Half-extents (box), or x = radius / y = cap offset (capsule).
    size: Vec2 = .{ .x = 0.5, .y = 0.5 },
    offset: Vec2 = .{},

    density: f32 = 1.0,
    friction: f32 = 0.3,
    restitution: f32 = 0.0,
    /// Reports overlaps without generating a contact response.
    is_sensor: bool = false,

    pub const invalid_shape = std.math.maxInt(u32);

    pub fn isLive(self: Collider2D) bool {
        return self.shape != invalid_shape;
    }
};

/// Named collision layers, as bitmasks (Godot-style `collision_layer` /
/// `collision_mask`, configured by name in project settings).
///
/// Separate from `Collider2D` because it is a property of the BODY, not of one
/// shape: a character on the `player` layer should hit the `enemy` layer with
/// all of its parts. The shape carries the shape-specific exceptions.
pub const CollisionLayers = struct {
    /// Which layer(s) this body is on. A body may be on several at once — a
    /// player that is both `player` and `hurtable`, say — which is what bits are
    /// for.
    layer: u16 = everything,
    /// Which layer(s) this body is willing to interact with.
    mask: u16 = everything,

    pub const everything: u16 = std.math.maxInt(u16);

    pub const inert = CollisionLayers{};

    /// The pair test, once, so nothing re-implements it and gets the symmetry
    /// wrong. See `collision_layers.zig` for why it is symmetric.
    pub fn collides(self: CollisionLayers, other: CollisionLayers) bool {
        if (self.layer == 0 or other.layer == 0) return false;
        return (self.layer & other.mask) != 0 and (other.layer & self.mask) != 0;
    }

    pub fn eql(self: CollisionLayers, other: CollisionLayers) bool {
        return self.layer == other.layer and self.mask == other.mask;
    }
};

// ── Tests ────────────────────────────────────────────────────────────────────

const testing = std.testing;

test "the physics components stay handles plus plain data" {
    // Handles first (they are the hot lookup), then the plain-data fields.
    // `RigidBody2D`: 2 handles + body_type + 2 Vec2 + 4 f32 + 3 bools + tier.
    try testing.expectEqual(@as(usize, 52), @sizeOf(RigidBody2D));
    // `Collider2D`: 2 handles + kind + 2 Vec2 + 3 f32 + a sensor flag.
    try testing.expectEqual(@as(usize, 40), @sizeOf(Collider2D));
    // Two bitmasks. Deliberately tiny: it rides along on every colliding body.
    try testing.expectEqual(@as(usize, 4), @sizeOf(CollisionLayers));
}

test "physics defaults are the ones gameplay expects" {
    const rb = RigidBody2D{};
    try testing.expect(rb.linear_velocity.x == 0);
    try testing.expect(rb.gravity_scale == 1.0); // default gravity, not none
    try testing.expect(rb.allow_sleep); // sleeping is the default, not an opt-in
    try testing.expectEqual(@as(u8, 0), rb.tier); // full simulation

    const col = Collider2D{};
    try testing.expectEqual(@as(u8, 0), col.kind); // box
    try testing.expect(!col.is_sensor); // solid unless asked
}