//! Component registry — the single comptime source of truth (spec §7).
//!
//! Every component type lives here, and from this list the whole ECS derives
//! at comptime:
//! - dense `ComponentId`s (registration order, stable for the build),
//! - the archetype mask type (`Mask`),
//! - layout metadata (`stride`, alignment) used by type-erased columns.
//!
//! Rules, enforced by compile error instead of runtime surprises:
//! 1. A component is **plain data**: no pointers, no slices, no unions.
//!    It must therefore be copyable, so moving an entity between archetypes
//!    is a `memcpy` of a fixed number of bytes.
//! 2. Every field (including nested ones) has a default: those defaults are
//!    the baseline a `.zson` document starts from in "replace" mode, and the
//!    baseline an override merges into in patch mode (see `zson`).
//! 3. Types are identified by their **explicit registry name** ("Transform",
//!    not a mangled path), because the text format and the profiler logs
//!    must not depend on how the module happens to be imported.
//!
//! Registration is closed on purpose: the ECS is an internal detail and the
//! public surface is Actor + Components (spec §7). Adding a component means
//! adding one line to `entries` below.

const std = @import("std");
const core_math = @import("core").math;
const entity = @import("entity.zig");

pub const Entity = entity.Entity;
pub const SceneId = entity.SceneId;
pub const Vec2 = core_math.Vec2;

pub const ComponentId = u16;

/// Maximum number of distinct component types. Deliberate ceiling: it keeps
/// every archetype test inside 4 machine words (`Mask`), which is what makes
/// queries cost O(#archetypes) instead of O(#entities).
pub const max_components = 256;

/// Component set as a bitmask: fast superset/disjoint tests during queries.
pub const Mask = std.StaticBitSet(max_components);

/// Buffer size generous enough to hold any registered component while
/// decoding a document (130 bytes covers a 60-byte Transform with slack).
pub const max_stride = 128;

// ── Components ───────────────────────────────────────────────────────────────

/// Inline name: identity for humans, and the key `.zson` overrides match by.
/// Fixed size keeps it POD (no allocation, no lifetime, byte-copyable).
pub const Name = struct {
    bytes: [32]u8 = [_]u8{0} ** 32,
    len: u8 = 0,

    pub const max_len = 32;

    pub fn init(text: []const u8) Name {
        var name = Name{};
        name.set(text);
        return name;
    }

    pub fn set(self: *Name, text: []const u8) void {
        const len = @min(text.len, Name.max_len);
        @memcpy(self.bytes[0..len], text[0..len]);
        self.len = @intCast(len);
    }

    pub fn slice(self: *const Name) []const u8 {
        return self.bytes[0..self.len];
    }

    pub fn eql(self: *const Name, text: []const u8) bool {
        return std.mem.eql(u8, self.slice(), text);
    }
};

/// Local 2D transform plus the previous fixed-tick snapshot, so the renderer
/// can interpolate without touching simulation state (spec §3.3).
pub const Transform = struct {
    position: Vec2 = Vec2{},
    rotation: f32 = 0,
    scale: Vec2 = unit,
    prev_position: Vec2 = Vec2{},
    prev_rotation: f32 = 0,
    prev_scale: Vec2 = unit,

    /// Call at the start of a fixed tick: what is about to be overwritten
    /// must survive as "previous" for the interpolator.
    pub fn capturePrevious(self: *Transform) void {
        self.prev_position = self.position;
        self.prev_rotation = self.rotation;
        self.prev_scale = self.scale;
    }

    /// Linear interpolation between the previous and current snapshot.
    pub fn interpolated(self: *const Transform, alpha: f32) Transform {
        return .{
            .position = self.prev_position.lerp(self.position, alpha),
            .rotation = self.prev_rotation + (self.rotation - self.prev_rotation) * alpha,
            .scale = self.prev_scale.lerp(self.scale, alpha),
        };
    }
};

/// Parent link. The hierarchy itself is derived by `hierarchy` (flat, no
/// recursion); this is the only thing stored per entity.
pub const Parent = struct {
    /// Entity handle of the parent. `invalid` (or a dead parent) means "root".
    parent: Entity = Entity.invalid,
};

/// Linear and angular velocity: plain data the fixed step integrates into
/// `Transform`. Kept separate so a kinematic actor can move without a
/// transform and a transform can move without one.
pub const Velocity = struct {
    linear: Vec2 = Vec2{},
    /// Radians per second, positive clockwise (screen space y grows down).
    angular: f32 = 0,
};

/// How a sprite is composited. Plain enum, so the ECS stores it as 1 byte and
/// `.zson` writes the name.
pub const Blend = enum(u8) {
    /// No blending: the fragment overwrites the target. Cheapest, and the only
    /// correct choice for solid geometry (it can also use early-Z).
    /// Named `solid`, not `opaque`: that is a Zig primitive type name.
    solid = 0,
    /// Standard source-over: the painter's algorithm for sprites.
    alpha = 1,
    /// Source + destination: lights and glows (M7).
    additive = 2,
};

/// A user-authored shader, bound to a sprite.
///
/// ## Why this is a COMPONENT and not a setting on the sprite
///
/// Because two sprites that look different usually want the SAME shader with
/// different uniforms -- a shared "dissolve" used by six characters, a scanline
/// used by every UI panel. Making it a field on the sprite would put the shader
/// id on thousands of entities and make "change every dissolve" a scene-wide
/// rewrite. As a component, one entity holds the material and the sprites point
/// at it.
///
/// ## Why an unknown shader falls back instead of failing
///
/// A scene that references a shader the build does not have must still render.
/// The fallback is the stock sprite shader, so a missing material shows up as
/// "that one thing looks wrong" rather than "the screen is black". That is the
/// same reasoning as a missing texture falling back to white.
pub const ShaderMaterial = struct {
    /// Which shader, by index into the runtime's shader table. 0 is the stock
    /// sprite shader, so the default material is the default look.
    shader: u16 = 0,
    /// Four floats. Enough for a colour tint, a dissolve threshold, a time; not
    /// enough to be a general-purpose uniform block, and that is deliberate --
    /// a wider block needs a std140 layout and the whole thing becomes a shader
    /// system instead of a hook.
    params: [4]f32 = .{ 0, 0, 0, 0 },
    /// The entity whose material this is, for the inspector to follow. 0 means
    /// "this entity IS the material".
    owner_scene: SceneId = 0,

    pub const stock_shader: u16 = 0;
};

/// How a sprite's quad is masked.
///
/// Godot can draw a rectangle, a circle, a line and a polygon with no texture at
/// all, and that is what makes "grey boxes" a legitimate first step rather than a
/// placeholder you have to go back and replace. `quad` and `circle` are the two
/// that carry a prototype; both cost one quad and one comparison in the shader.
pub const SpriteShape = enum(u8) {
    quad = 0,
    circle = 1,
};

// ── 2D lighting (M7) ──────────────────────────────────────────────────────────
//
// Godot's Light2D model, because it is the one an editor author already has in
// their head: a light is an entity with a Transform and a Light2D, and what it
// touches is decided by two bitmasks. The field names are deliberately the same
// as Godot's (`shadow_filter`, `range_item_cull_mask`, ...) so a scene ported
// from Godot means what it says here.

/// What shape of light this is. The three cover every practical 2D case, and
/// each has a different falloff:
///  - `point` falls off with distance in every direction.
///  - `spot` is a point light confined to a cone, with a penumbra on its edge.
///  - `directional` has no position in the falloff at all: everything is lit
///    equally and `angle` is the direction the light travels. Used for sun and
///    moonlight, where a point light would make the far side of the map dark.
pub const LightKind = enum(u8) {
    point = 0,
    spot = 1,
    directional = 2,
};

/// How a light combines with what is already there. Godot's three modes, with
/// Godot's meanings.
pub const LightBlend = enum(u8) {
    /// Light * x + destination. The default for a torch.
    add = 0,
    /// Light x - destination. For shadow-casting key lights where the shadow
    /// should read as darkness rather than as the absence of light.
    subtract = 1,
    /// Light x (destination x light) / (1 - light). The only one of the three
    /// that is energy-conserving, so a white surface under it stays white
    /// instead of blowing out — which is what you want for an overcast sky.
    mix = 2,
};

/// How a shadow's edge is softened.
///
/// This is a filter over the light mask, not a ray count: a hard shadow is one
/// tap, and each step adds a tap at a wider radius and averages. `off` exists
/// because a scene with thousands of tiny shadows is faster with them disabled
/// and the difference has to be reachable from the editor's inspector, not
/// compiled out.
pub const ShadowFilter = enum(u8) {
    off = 0,
    pcf1 = 1,
    pcf3 = 2,
    pcf5 = 3,
};

/// A closed or open polygon, used by `LightOccluder2D`.
///
/// Inline storage rather than a slice: an occluder is small (a wall is four
/// points, a rock is six) and a component that can hold a pointer needs
/// ownership rules, a free list and a serialization story. The cap is checked at
/// load for the same reason the collision shape's is.
pub const OccluderPolygon = struct {
    /// Vertices, x/y pairs. Ignored past `count`.
    points: [max_occluder_points * 2]f32 = [_]f32{0} ** (max_occluder_points * 2),
    /// How many vertices are real.
    count: u8 = 0,
    /// A closed polygon casts a shadow and contains; an open one (a fence, a
    /// window frame) casts along its edges only.
    closed: bool = true,

    pub const max_points = 8;

    pub fn vertexCount(self: OccluderPolygon) usize {
        return @min(self.count, max_points);
    }

    /// Signed area: positive when wound counter-clockwise in a y-up space.
    ///
    /// The occluder rasterizer needs to know the winding to fill the inside, and
    /// an editor that lets a user drag points around freely will produce both.
    /// Normalizing here means one code path downstream instead of a check at
    /// every use.
    pub fn signedArea(self: OccluderPolygon) f32 {
        var sum: f32 = 0;
        const n = self.vertexCount();
        if (n < 3) return 0;
        var i: usize = 0;
        while (i < n) : (i += 1) {
            const j = (i + 1) % n;
            sum += self.points[i * 2] * self.points[j * 2 + 1] -
                self.points[j * 2] * self.points[i * 2 + 1];
        }
        return sum * 0.5;
    }

    /// Whether the winding is already the one the rasterizer wants.
    pub fn isCounterClockwise(self: OccluderPolygon) bool {
        return self.signedArea() >= 0;
    }

    /// Axis-aligned bounds, so the rasterizer only visits the polygon's cells
    /// instead of the whole mask. Recomputed per frame while a point is being
    /// dragged; four comparisons is cheaper than a full-polygon pass over a
    /// bounding box that is usually much larger than the shape.
    pub fn bounds(self: OccluderPolygon, out: *[4]f32) void {
        const n = self.vertexCount();
        if (n == 0) {
            out.* = .{ 0, 0, 0, 0 };
            return;
        }
        var min_x = self.points[0];
        var min_y = self.points[1];
        var max_x = min_x;
        var max_y = min_y;
        var i: usize = 1;
        while (i < n) : (i += 1) {
            const x = self.points[i * 2];
            const y = self.points[i * 2 + 1];
            min_x = @min(min_x, x);
            min_y = @min(min_y, y);
            max_x = @max(max_x, x);
            max_y = @max(max_y, y);
        }
        out.* = .{ min_x, min_y, max_x, max_y };
    }

    /// Whether a world-space point is inside, by even-odd crossing test.
    ///
    /// Even-odd rather than winding because it is winding-agnostic: an editor
    /// that hands us a backwards polygon still occludes the right pixels, and a
    /// light that leaks because the art came in mirrored is not a bug a user
    /// can see the cause of.
    pub fn contains(self: OccluderPolygon, x: f32, y: f32) bool {
        const n = self.vertexCount();
        if (n < 3) return false;
        var inside = false;
        var j = n - 1;
        var i: usize = 0;
        while (i < n) : ({
            j = i;
            i += 1;
        }) {
            const xi = self.points[i * 2];
            const yi = self.points[i * 2 + 1];
            const xj = self.points[j * 2];
            const yj = self.points[j * 2 + 1];
            if ((yi > y) != (yj > y)) {
                const t = (y - yi) / (yj - yi);
                if (x < xi + t * (xj - xi)) inside = !inside;
            }
        }
        return inside;
    }
};

pub const max_occluder_points = OccluderPolygon.max_points;

/// How a light occluder gets its shape. The automatic path is the one that
/// makes lighting usable without authoring: importing a wall sprite produces its
/// distance field from the texture's alpha and nobody has to draw a polygon.
pub const OccluderMode = enum(u8) {
    /// Derive the occluder from the sprite's own alpha at an alpha threshold.
    /// Zero authoring, and the reason `occluder.mode` exists at all.
    auto_sdf = 0,
    /// Use `polygon`. Exact, and cheaper than the SDF for a simple shape, which
    /// is why "none" in Godot's inspector means exactly this.
    manual = 1,
    /// Cast no shadow at all. The optimization escape hatch: a sprite that
    /// looks like it occludes but should not (a fog card, a UI panel) says so
    /// here rather than being deleted and re-added without the component.
    none = 2,
};

/// A light. Position and rotation come from the `Transform`, as with every other
/// visual component — a light is an actor, so it can be parented, moved by a
/// script, and dragged in the editor with no special case.
pub const Light2D = struct {
    kind: LightKind = .point,
    /// Colour, multiplied by `energy`. Alpha is used as the light's opacity:
    /// fading a light out is `tint[3]`, not a separate fade field.
    color: [4]f32 = .{ 1, 1, 1, 1 },
    /// Brightness multiplier. 1 is neutral; the editor's slider goes higher
    /// because a torch in a dark room needs it.
    energy: f32 = 1,
    /// Offset from the Transform, in the Transform's own frame. Godot has this
    /// so a light's hotspot can sit at the top of its sprite rather than at the
    /// sprite's origin, without rotating the sprite.
    offset: Vec2 = .{ .x = 0, .y = 0 },
    /// How far the light reaches, in world units. The falloff is `1 - d/r`
    /// squared, which is linear at the centre and reaches exactly zero at `r`
    /// with no discontinuity — the difference between a lantern and a lamp that
    /// has a visible edge on the floor.
    radius: f32 = 128,
    /// `spot`: direction the cone points, radians. `directional`: direction the
    /// light travels, radians. Unused by `point`.
    angle: f32 = 0,
    /// `spot` only: the full opening in radians. The cone is centred on
    /// `angle`, so it spans `angle ± cone_angle / 2`.
    cone_angle: f32 = 0.7853981634, // 45 degrees
    /// `spot` only: the fraction of the cone given over to a soft edge, 0..1.
    /// 0.2 means the light reaches full strength at 80% of the cone and fades
    /// over the last 20%. This is what makes a spotlight look like a spotlight
    /// rather than a triangle.
    penumbra: f32 = 0.2,
    /// Falloff exponent. 1 is the default above; higher concentrates the light
    /// into the middle of its radius.
    attenuation: f32 = 1,
    blend: LightBlend = .add,
    /// Whether this light casts shadows. A fill light does not need to, and
    /// there are only four shadow channels, so this is a budget decision that
    /// belongs to the data rather than to a global quality setting.
    cast_shadows: bool = true,
    /// Edge softening. `off` is a hard edge and the cheapest.
    shadow_filter: ShadowFilter = .pcf3,
    /// How far the filter's taps are spread, in shadow-mask texels. Raising it
    /// widens the penumbra of a hard shadow without re-authoring the light.
    shadow_filter_smooth: f32 = 2,
    /// Which sprite layers this light affects — the `Sprite.layer` values, as a
    /// bitmask. A light on layer 2 only lights UI on layer 2, which is how a
    /// scene gets a lamp that does not brighten its own interface.
    item_cull_mask: u32 = 0xffff_ffff,
    /// Shadow receive is per-SPRITE, not per-light, because one sprite standing
    /// in two lights must be shadowed by both. It is the `shadow_filter` /
    /// `shadow_filter_smooth` pair on the receiving side, and this mask here
    /// only decides whether the sprite is lit at all.
    enabled: bool = true,
    /// Global ambient this light contributes when GI is on, 0..1. Zero by
    /// default: GI is an explicit opt-in per light, because a scene that did not
    /// ask for bounce should not have it.
    gi_contribution: f32 = 0,

    /// The four `ShadowFilter` steps after `off`, as filter radii in texels.
    pub const filter_radii = [_]f32{ 0, 0, 1, 2 };

    /// The cone's half-angle, clamped so a zero-width cone does not become a
    /// full circle and a negative one does not invert.
    pub fn halfCone(self: Light2D) f32 {
        return @min(@abs(self.cone_angle) * 0.5, std.math.pi);
    }
};

/// Something that blocks light.
///
/// Present on an entity as a component, like Godot's `LightOccluder2D`, so the
/// same actor can be a wall, a prop and a light source — and so the editor can
/// show and toggle it without a second selection concept.
pub const LightOccluder2D = struct {
    mode: OccluderMode = .auto_sdf,
    /// Used when `mode == .manual`, and ALSO used by `auto_sdf` as the tight
    /// bound the automatic shape is fitted inside — an automatic occluder that
    /// ignored the actor's size would still shadow the whole sprite's rect.
    polygon: OccluderPolygon = .{},
    /// Alpha at which `auto_sdf` decides a texel is solid. 0.5 is the default
    /// because it is what a human means by "the shape", and it is the one knob
    /// that fixes most "my sprite has a fringe of shadow" reports.
    alpha_threshold: f32 = 0.5,
    /// Which lights this occluder blocks, by light index within the scene.
    /// 0 means "all", which is what a wall wants; a one-way occluder (a pane of
    /// glass that blocks the sun but not the lamps) sets it.
    cull_mask: u32 = 0xffff_ffff,
    enabled: bool = true,
};

/// What to draw for an entity, and how. This is the whole render surface of an
/// actor: position comes from `Transform`, the appearance from here.
///
/// Everything is plain data with defaults, which is what lets `.zson` describe
/// a sprite prefab and lets the editor override a single field (patch mode).
pub const Sprite = struct {
    /// Atlas slot (index into the renderer's texture table). Slot 0 is the
    /// fallback white texture, so a sprite with no atlas still draws.
    atlas: u8 = 0,
    /// Render layer. Lower draws first (painter's order); the renderer sorts by
    /// it and the batcher groups equal values into one draw call.
    layer: u16 = 0,
    /// Size in world units (the Transform's scale multiplies this).
    size: Vec2 = unit,
    /// How the quad is masked. `quad` is the default so an existing sprite is
    /// unchanged, and so a prototype drawn with `sprite.circle` and then given
    /// real art is one line, not a rewrite.
    shape: SpriteShape = .quad,
    /// Atlas rect, normalized: (u0, v0, u1, v1).
    uv: [4]f32 = .{ 0, 0, 1, 1 },
    /// Tint, multiplied with the texel.
    tint: [4]f32 = .{ 1, 1, 1, 1 },
    /// Stable tie-break inside a layer, so the order is deterministic (spec §6).
    order: i32 = 0,
    blend: Blend = .alpha,
    /// Draw nothing for this entity without despawning it (editor gizmos, cut
    /// scenes). Cheaper and safer than a structural change during the frame.
    visible: bool = true,
};

const unit = Vec2{ .x = 1, .y = 1 };

/// The Lua behavior bound to an actor (M3). This is the serializable link: it
/// stores a *script id* (a stable index into the engine's script cache), never a
/// VM reference — a Lua registry ref is meaningless across save/load, so `.zson`
/// writes the id and the runtime re-binds it to the live script on load. That is
/// what keeps scene serialization bit-exact (spec §6) while still letting a
/// scene say "this actor runs player.lua".
///
/// The behavior's Lua state (the `self` table and its cached method refs) lives
/// in the `script` subsystem, keyed off this component; the ECS only owns the
/// stable id, exactly as the ECS is an internal detail and the public API is
/// Actor + Components + Signals (spec §7).
pub const Script = struct {
    /// Index into the script cache. 0 means "no script" (the default), so ids
    /// start at 1 — the same convention `SceneId` uses.
    script: u32 = 0,
};

/// A link to a state machine defined by Lua (ROADMAP M4.5).
///
/// The same component serves every case — an enemy's AI, the player's own
/// states, a spawner, a UI screen, the game flow — because the states and their
/// transitions are script data, not component data.
///
/// It is a HANDLE, not the machine itself, and that is forced by rule 1 above:
/// a machine holds names and Lua callbacks, which are pointers and slices, so it
/// cannot live in a component. The engine owns the machines in a side registry
/// (`script/statemachine.zig`) and the component stores the index, exactly as
/// `Script` stores a script id. Two consequences worth knowing:
///
/// - **The handle is what serializes.** A `.zson` file saves `machine = 3`, not a
///   Lua closure, so save/load stays bit-exact (spec §6). The transitions are
///   rebuilt from the script when the behavior attaches.
/// - **0 means "no machine"**, matching `Script`'s convention, so an entity that
///   has never opted in costs one branch in every tick.
pub const StateMachine = struct {
    /// Index into the engine's state-machine registry; 0 is "none".
    machine: u32 = 0,

    /// True once the machine has been entered, so the first tick runs `enter` on
    /// the starting state exactly once instead of every frame until something
    /// transitions it away and back.
    started: bool = false,
};

/// A rigid body in the physics world (ROADMAP M4).
///
/// The three body kinds Godot calls StaticBody2D / AnimatableBody2D /
/// RigidBody2D are ONE component with a `body_type`, not three components. That
/// is the difference that matters: an actor switching from fixed to kinematic at
/// runtime — a door opening, a platform starting to move, a character mounting
/// one — does not change archetype, so it does not trigger a row move, a
/// structural change, or a spike (spec §3.1).
///
/// It is a HANDLE, forced by rule 1 above: a body id from the physics backend is
/// not plain data, so the component stores the port's generation-tagged id and
/// the solver's own state stays on the physics side. Swapping the backend
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

// ── Registry ─────────────────────────────────────────────────────────────────

/// One entry per component type. Order defines the dense ids, so it is also
/// the canonical order `.zson` writes components in: identical files for
/// identical worlds (spec §6).
pub const Entry = struct {
    name: []const u8,
    type: type,
    /// Layout of one element inside an archetype column.
    stride: u32,
    align_pow: u8,
};

// Stride/alignment are derived from the type: writing them by hand is exactly
// how a silent column misalignment bug starts.
fn layoutOf(comptime T: type) struct { u32, u8 } {
    return .{ @sizeOf(T), @as(u8, @ctz(@as(usize, @alignOf(T)))) };
}

pub const entries: [component_list.len]Entry = blk: {
    var out: [component_list.len]Entry = undefined;
    for (component_list, &out) |spec, *entry| {
        const stride, const align_pow = layoutOf(spec.type);
        entry.* = .{ .name = spec.name, .type = spec.type, .stride = stride, .align_pow = align_pow };
    }
    break :blk out;
};

/// The registry as declared: name + type. Layout metadata is derived above.
const component_list = [_]struct { name: []const u8, type: type }{
    .{ .name = "Name", .type = Name },
    .{ .name = "Transform", .type = Transform },
    .{ .name = "Parent", .type = Parent },
    .{ .name = "Velocity", .type = Velocity },
    .{ .name = "Sprite", .type = Sprite },
    .{ .name = "ShaderMaterial", .type = ShaderMaterial },
    .{ .name = "Script", .type = Script },
    .{ .name = "StateMachine", .type = StateMachine },
    .{ .name = "RigidBody2D", .type = RigidBody2D },
    .{ .name = "Collider2D", .type = Collider2D },
    .{ .name = "CollisionLayers", .type = CollisionLayers },
    .{ .name = "Light2D", .type = Light2D },
    .{ .name = "LightOccluder2D", .type = LightOccluder2D },
};

comptime {
    if (entries.len > max_components)
        @compileError("component registry exceeds max_components (" ++ std.fmt.comptimePrint("{d}", .{max_components}) ++ ")");
    for (entries) |entry| assertComponentRules(entry.type);
}

/// Rules 1 and 2 of this file, as compile errors next to the offending type.
fn assertComponentRules(comptime T: type) void {
    if (@typeInfo(T) != .@"struct")
        @compileError("component must be a struct: " ++ @typeName(T));
    assertPlainData(T, T);
    assertDefaultable(T);
}

fn assertPlainData(comptime T: type, comptime origin: type) void {
    switch (@typeInfo(T)) {
        .bool, .int, .float => {},
        .@"enum" => {},
        .optional => |o| assertPlainData(o.child, origin),
        .array => |a| assertPlainData(a.child, origin),
        .@"struct" => |s| inline for (s.fields) |f| assertPlainData(f.type, origin),
        else => @compileError("component " ++ @typeName(origin) ++ ": field type " ++ @typeName(T) ++ " is not plain data (no pointers, slices or unions allowed)"),
    }
}

fn assertDefaultable(comptime T: type) void {
    switch (@typeInfo(T)) {
        .@"struct" => |s| inline for (s.fields) |f| {
            if (f.default_value_ptr == null)
                @compileError("component " ++ @typeName(T) ++ ": field '" ++ f.name ++ "' has no default; defaults are the .zson baseline");
            assertDefaultable(f.type);
        },
        .array => |a| assertDefaultable(a.child),
        .optional => |o| assertDefaultable(o.child),
        else => {},
    }
}

/// Dense id of a component type. Unknown type = compile error at the call
/// site, which is the point: components must be registered, not discovered.
pub fn componentId(comptime T: type) ComponentId {
    inline for (entries, 0..) |entry, i| {
        if (entry.type == T) return @as(ComponentId, @intCast(i));
    }
    @compileError("component type not registered: " ++ @typeName(T) ++ " (add it to the entries list in components.zig)");
}

pub fn strideOf(id: ComponentId) u32 {
    return strides[id];
}

/// Component alignment as a power of two (column buffers are allocated with it).
pub fn alignOfPow(id: ComponentId) u8 {
    return align_pows[id];
}

/// Comptime-only list: `Entry` holds a type, so it can never be indexed at
/// runtime. The runtime-indexable projections below are what the storage and
/// the serializers use.
pub fn nameOf(id: ComponentId) []const u8 {
    return names[id];
}

pub fn alignmentOf(id: ComponentId) std.mem.Alignment {
    return std.mem.Alignment.fromByteUnits(@as(usize, 1) << @intCast(align_pows[id]));
}

const names: [entries.len][]const u8 = blk: {
    var out: [entries.len][]const u8 = undefined;
    for (entries, &out) |entry, *slot| slot.* = entry.name;
    break :blk out;
};

const strides: [entries.len]u32 = blk: {
    var out: [entries.len]u32 = undefined;
    for (entries, &out) |entry, *slot| slot.* = entry.stride;
    break :blk out;
};

const align_pows: [entries.len]u8 = blk: {
    var out: [entries.len]u8 = undefined;
    for (entries, &out) |entry, *slot| slot.* = entry.align_pow;
    break :blk out;
};

/// Comptime map "registry name -> id" for `.zson` decoding.
const name_to_id = blk: {
    var kvs: [entries.len]struct { []const u8, ComponentId } = undefined;
    for (entries, 0..) |entry, i| kvs[i] = .{ entry.name, @as(ComponentId, @intCast(i)) };
    break :blk std.StaticStringMap(ComponentId).initComptime(&kvs);
};

/// Id for a registry name, or `null` if that name is not a component of this
/// build (e.g. a document written by a newer version).
pub fn idOfName(name: []const u8) ?ComponentId {
    return name_to_id.get(name);
}

/// Default value of a component, as raw bytes: the "replace" baseline for
/// `.zson` documents that omit a field (decoders pass values in as bytes, so
/// the dispatch from a runtime id to a type has to happen here).
pub fn writeDefault(id: ComponentId, dst: []u8) void {
    inline for (entries, 0..) |entry, i| {
        if (id == i) {
            const value = entry.type{};
            std.mem.copyForwards(u8, dst[0..entry.stride], std.mem.asBytes(&value));
            return;
        }
    }
    std.debug.panic("components: id {d} is not in the registry", .{id});
}

test "registry is dense, unique and self-consistent" {
    inline for (entries, 0..) |entry, i| {
        const id: ComponentId = @intCast(i);
        try std.testing.expectEqualStrings(entry.name, nameOf(id));
        try std.testing.expectEqual(id, componentId(entry.type));
        try std.testing.expectEqual(id, idOfName(entry.name).?);
        try std.testing.expectEqual(entry.stride, strideOf(id));
    }
}

test "component ids resolved at comptime" {
    try std.testing.expectEqual(@as(ComponentId, 0), componentId(Name));
    try std.testing.expectEqual(@as(ComponentId, 1), componentId(Transform));
    try std.testing.expectEqual(@as(ComponentId, 2), componentId(Parent));
    try std.testing.expectEqual(@as(ComponentId, 3), componentId(Velocity));
    try std.testing.expectEqual(@as(ComponentId, 4), componentId(Sprite));
    try std.testing.expectEqual(@as(?ComponentId, null), idOfName("Nope"));
}

test "Sprite is POD with sane defaults (the .zson baseline)" {
    const s = Sprite{};
    try std.testing.expectEqual(@as(u8, 0), s.atlas);
    try std.testing.expectEqual(@as(u16, 0), s.layer);
    try std.testing.expectEqual(@as(f32, 1), s.size.x);
    try std.testing.expectEqual(@as(f32, 1), s.uv[2]);
    try std.testing.expectEqual(Blend.alpha, s.blend);
    try std.testing.expect(s.visible);
    // Kept small on purpose: the 50k canonical scene multiplies this by 50000,
    // so 52 B/sprite is 2.6 MB of column data (spec §5 allows it, but it is
    // pure cache pressure in the render walk).
    try std.testing.expectEqual(@as(usize, 52), @sizeOf(Sprite));
}

test "component sizes are what they must be" {
    // Name: 33 bytes (32 inline + len).
    try std.testing.expectEqual(@as(usize, 33), @sizeOf(Name));
    // Transform: auto layout interleaves the prev_* snapshot with the live
    // fields (12 bytes per position/rotation pair, 16 for the two scales).
    try std.testing.expectEqual(@as(usize, 40), @sizeOf(Transform));
}

test "Transform interpolation goes from prev to current (spec §3.3)" {
    var now = Transform{
        .position = .{ .x = 0, .y = 0 },
        .rotation = 0,
        .scale = unit,
    };
    now.prev_position = now.position;
    now.prev_rotation = now.rotation;
    now.prev_scale = now.scale;

    // One fixed tick later (the simulation wrote the current fields).
    now.position = .{ .x = 10, .y = 20 };
    now.rotation = 2;

    const mid = now.interpolated(0.5);
    try std.testing.expectApproxEqAbs(@as(f32, 5), mid.position.x, 0.0001);
    try std.testing.expectApproxEqAbs(@as(f32, 10), mid.position.y, 0.0001);
    try std.testing.expectApproxEqAbs(@as(f32, 1), mid.rotation, 0.0001);
    try std.testing.expectApproxEqAbs(@as(f32, 1), mid.scale.x, 0.0001);

    // capturePrevious is what makes "prev" mean "the last simulated tick".
    now.capturePrevious();
    try std.testing.expectApproxEqAbs(@as(f32, 10), now.prev_position.x, 0.0001);
    try std.testing.expectApproxEqAbs(@as(f32, 2), now.prev_rotation, 0.0001);
}

test "Name: init, set, truncation to max_len" {
    const short = Name.init("quad");
    try std.testing.expectEqualStrings("quad", short.slice());
    const long = Name.init(&[_]u8{'a'} ** 64);
    try std.testing.expectEqual(Name.max_len, long.len);
    try std.testing.expect(long.eql(&[_]u8{'a'} ** 32));
}

test "default baseline bytes match a default value" {
    var buf: [@sizeOf(Transform)]u8 align(@alignOf(Transform)) = undefined;
    writeDefault(componentId(Transform), &buf);
    const restored: *const Transform = @ptrCast(&buf);
    try std.testing.expectApproxEqAbs(@as(f32, 1), restored.scale.x, 0.0001);
}

test "a fresh Transform interpolates to its spawn position, not to the origin" {
    // Without seeding prev_* from the live fields, `interpolated(0)` returns
    // the (0,0) default and every actor visibly slides in from the top-left
    // corner on the first frame. The world seeds it at spawn time.
    const spawned = Transform{
        .position = .{ .x = 120, .y = -45 },
        .rotation = 1.5,
        .scale = .{ .x = 3, .y = 4 },
    };
    var seeded = spawned;
    seeded.capturePrevious();

    const at_zero = seeded.interpolated(0);
    try std.testing.expectApproxEqAbs(@as(f32, 120), at_zero.position.x, 0.0001);
    try std.testing.expectApproxEqAbs(@as(f32, -45), at_zero.position.y, 0.0001);
    try std.testing.expectApproxEqAbs(@as(f32, 1.5), at_zero.rotation, 0.0001);
    try std.testing.expectApproxEqAbs(@as(f32, 3), at_zero.scale.x, 0.0001);

    const at_one = seeded.interpolated(1);
    try std.testing.expectApproxEqAbs(@as(f32, 120), at_one.position.x, 0.0001);
}
