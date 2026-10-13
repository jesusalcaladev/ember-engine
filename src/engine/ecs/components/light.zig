//! 2D lighting components (M7, split out of components.zig).
//!
//! Godot's Light2D model, because it is the one an editor author already has in
//! their head: a light is an entity with a Transform and a Light2D, and what it
//! touches is decided by two bitmasks. The field names are deliberately the same
//! as Godot's (`shadow_filter`, `item_cull_mask`, ...) so a scene ported from
//! Godot means what it says here.

const std = @import("std");
const core_math = @import("core").math;

pub const Vec2 = core_math.Vec2;

/// What shape of light this is. The three cover every practical 2D case, and
/// each has a different falloff:
///  - `point` falls off with distance in every direction.
///  - `spot` is a point light confined to a cone, with a penumbra on its edge.
///  - `directional` has no position in the falloff at all: everything is lit
///    equally and `angle` is the direction the light travels. Used for sun and
///    moonlight, where a point light would make the far side of the map dark.
/// The four light kinds, and this is the WIRE FORM, not the component list: a
/// scene has four components (`PointLight2D`, `SpotLight2D`,
/// `DirectionalLight2D`, `AmbientLight2D`) but the renderer gathers them into one
/// instance stream, and the kind is how it tells them apart without a second
/// buffer per shape.
pub const LightKind = enum(u8) {
    point = 0,
    spot = 1,
    directional = 2,
    /// Ambient: no position in the falloff, because there is none. The shader
    /// treats it as a constant over the light's radius.
    ambient = 3,
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
/// Everything a light has in common, whatever its shape.
///
/// ## Why this is a struct and not four copies of ten fields
///
/// Godot has four light types and they share almost all of their properties —
/// colour, energy, blending, shadows, GI — because those are properties of BEING
/// a light, not of being a point. Zig has no inheritance, and writing ten fields
/// four times means a fix to the shadow filter lands in four places, three of
/// which the author forgot. So this is the shared part and each of the four
/// embeds it by value. The ECS still registers four distinct component types,
/// because that is what an inspector and a scene file need.
///
/// The wire form (`LightInstance` in render/light.zig) is a separate struct
/// again, and it is the only one a shader ever sees. That is deliberate: the
/// components are authored data with a documented shape, and the instance is
/// a 68-byte upload whose layout is asserted at comptime.
pub const LightBase = struct {
    /// Colour, multiplied by `energy`. Alpha is the light's opacity, so a light
    /// fades out by its alpha rather than by a separate fade field.
    color: [4]f32 = .{ 1, 1, 1, 1 },
    /// Brightness multiplier. 1 is neutral; the editor's slider goes higher
    /// because a torch in a dark room needs it.
    energy: f32 = 1,
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

    /// The four `ShadowFilter` steps after `off`, as filter radii in texels.
    pub const filter_radii = [_]f32{ 0, 0, 1, 2 };
};

/// A point light: a lamp, a torch, a candle. Falls off in every direction.
///
/// Godot's `PointLight2D`. It is the one most scenes are made of, so its
/// defaults are the ones a scene gets by just adding the component.
pub const PointLight2D = struct {
    base: LightBase = .{},
    /// Offset from the Transform, in the Transform's own frame — the hotspot can
    /// sit at the top of a light's sprite rather than at its origin.
    offset: Vec2 = .{ .x = 0, .y = 0 },
    /// How far the light reaches. The falloff is `1 - d/r` raised to
    /// `attenuation`, which is linear at the centre and reaches exactly zero at
    /// `r` with no discontinuity — the difference between a lantern and a lamp
    /// with a visible edge on the floor.
    radius: f32 = 192,
    /// Falloff exponent. 1 is the default above; higher concentrates the light
    /// into the middle of its radius.
    attenuation: f32 = 1,
};

/// A spotlight: a cone, with a soft edge. Godot's `SpotLight2D`.
///
/// The interesting part is `penumbra`, and it is a fraction of the cone rather
/// than an angle, because a designer thinks "the last fifth of the beam is soft"
/// and not "the edge fades over 4.1 degrees".
pub const SpotLight2D = struct {
    base: LightBase = .{},
    offset: Vec2 = .{ .x = 0, .y = 0 },
    /// How far the beam reaches.
    radius: f32 = 192,
    /// Direction the cone points, radians.
    angle: f32 = 0,
    /// Full opening in radians. The cone is centred on `angle`, so it spans
    /// `angle ± cone_angle / 2`.
    cone_angle: f32 = 0.7853981634, // 45 degrees
    /// The fraction of the cone given over to a soft edge, 0..1. 0.2 means full
    /// strength to 80% of the cone and a fade over the last 20%. This is what
    /// makes a spotlight look like a spotlight rather than a triangle.
    penumbra: f32 = 0.2,
    attenuation: f32 = 1,

    /// The cone's half-angle, clamped so a zero-width cone does not become a
    /// full circle and a negative one does not invert.
    pub fn halfCone(self: SpotLight2D) f32 {
        return @min(@abs(self.cone_angle) * 0.5, std.math.pi);
    }
};

/// A directional light: the sun. No falloff at all.
///
/// Godot's `DirectionalLight2D`, and the part worth explaining is why it EXISTS
/// when a point light with a huge radius seems to cover the same case: a point
/// light at 4000 units is dark at the far end of the screen because its falloff
/// is measured from where it IS, and a sun is not anywhere.
pub const DirectionalLight2D = struct {
    base: LightBase = .{},
    /// Direction the light travels, radians. 0 is to the right.
    angle: f32 = 0,
    /// 0..1, how high above the scene the light sits. 0 is a light grazing the
    /// floor with infinitely long shadows; 1 is overhead with none. It scales
    /// shadow LENGTH, which is the only reason a 2D scene needs a z coordinate.
    ///
    /// Stated in Godot's units rather than in world units on purpose: it is a
    /// scene author's dial, and "a third of the way up" is what they mean.
    height: f32 = 0.5,
    /// How far the light reaches in world units. 0 is unbounded.
    max_distance: f32 = 0,
};

/// Ambient light: the world's own. Godot's `AmbientLight2D`.
///
/// Present as its own type rather than folded into `Environment` because a
/// scene often wants TWO ambients — a sky colour and a ground bounce, or a warm
/// one and a cold one — and one number cannot hold both.
pub const AmbientLight2D = struct {
    base: LightBase = .{},
    /// Whether this ambient applies to the whole scene. False restricts it to
    /// `max_distance` around the actor, which is how a lantern's pool of warm air
    /// differs from the night around it.
    global: bool = true,
    /// Only when `global == false`: the reach of the local ambient, in the same
    /// units a point light's `radius` is.
    max_distance: f32 = 128,

    /// Whether this ambient is the scene-wide kind.
    pub fn appliesEverywhere(self: AmbientLight2D) bool {
        return self.global;
    }
};

/// The M2 light: ONE component holding every kind, discriminated by `kind`.
///
/// Still registered, and still id 11, which is the reason it cannot be deleted:
/// a dense id IS the `.zson` encoding, so removing this type would renumber
/// every component after it and turn every committed scene into a scene about
/// different components.
///
/// M7 added the four concrete kinds above, which carry the same fields through
/// `LightBase` and are what new scenes should use — they need no discriminant
/// to be valid, and they make the common case (`PointLight2D`) the thing you
/// actually name. `Light2D` stays as the legacy shape the renderer gathers.
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

    /// The four `ShadowFilter` steps after `off`, as filter radii in texels.
    pub const filter_radii = [_]f32{ 0, 0, 1, 2 };

    /// The cone's half-angle, clamped so a zero-width cone does not become a
    /// full circle and a negative one does not invert.
    pub fn halfCone(self: Light2D) f32 {
        return @min(@abs(self.cone_angle) * 0.5, std.math.pi);
    }
};

/// The world's global lighting. Godot's `Environment`, and it answers the
/// question a scene asks when there is no light touching it: what does "dark"
/// mean here?
///
/// One of these per world, not per actor, because ambient light is a property
/// of the world — a dungeon and a meadow differ in what their shadows are made
/// of, and putting that on each actor would make "change the mood" a scene-wide
/// edit for a value that is one number.
pub const Environment = struct {
    /// The colour the ambient term tints everything by, before any light.
    ambient_color: [4]f32 = .{ 0.09, 0.10, 0.14, 1 },
    /// Global light level, a multiplier on `ambient_color`. 0 is a world with only
    /// dynamic light, which is what a lighting showcase wants and what a
    /// night-time scene should set deliberately rather than by deleting every
    /// torch.
    ambient_energy: f32 = 1.0,
    /// The colour a pixel with no light and no ambient resolves to: the clear.
    /// Separate from `ambient_color` because one is what the world does to what
    /// it lights and the other is what nothing lights at all.
    clear_color: [4]f32 = .{ 0.02, 0.02, 0.03, 1 },
    /// How much bloom is added, 0..1. ZERO disables the chain ENTIRELY — the
    /// four passes are skipped, not run with a zero multiplier — because a scene
    /// that has never enabled bloom should not be paying for a half-resolution
    /// blur every frame.
    ///
    /// This is why there are TWO bloom numbers rather than one. A single
    /// "bloom" dial has to be both "how bright must a pixel be" and "how much
    /// glow", and those are not the same quantity: a slider that does both means
    /// setting one of them changes the other, which is not a dial, it is a
    /// coupling nobody asked for.
    bloom_intensity: f32 = 0.0,
    /// Luminance above which a pixel contributes to the bloom, 0..1.
    bloom_threshold: f32 = 1.0,
    /// Screen-space tonemap, off by default. On for HDR scenes, where a light
    /// at energy 3 otherwise clips to white and a colour ramp nobody chose.
    tonemap: bool = false,
    /// Fog's near and far in world units, 0 disabling it. A fog over a
    /// distance is the cheapest depth cue a 2D game has, and it is a property of
    /// the world rather than of any one light.
    fog: [2]f32 = .{ 0, 0 },
    fog_color: [4]f32 = .{ 0.5, 0.5, 0.55, 1 },

    /// Whether fog reaches the given distance.
    pub fn foggy(self: Environment) bool {
        return self.fog[1] > self.fog[0];
    }

    /// The ambient colour as a single colour, energy applied.
    pub fn ambient(self: Environment) [4]f32 {
        return .{
            self.ambient_color[0] * self.ambient_energy,
            self.ambient_color[1] * self.ambient_energy,
            self.ambient_color[2] * self.ambient_energy,
            self.ambient_color[3],
        };
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

// ── Tests ────────────────────────────────────────────────────────────────────

const testing = std.testing;

test "the four light kinds carry the defaults an unauthored scene needs" {
    // Each kind is its own component, so a scene gets its defaults by adding
    // the one it meant. Four separate assertions rather than one table, because
    // a failure should say WHICH light is wrong.
    const p = PointLight2D{};
    try testing.expect(p.base.cast_shadows);
    try testing.expectEqual(@as(f32, 1), p.base.energy);
    try testing.expectEqual(@as(f32, 192), p.radius);

    const s = SpotLight2D{};
    // Half of a 45-degree cone: pi/4 full, so pi/8 half.
    try testing.expectApproxEqAbs(@as(f32, std.math.pi / 8.0), s.halfCone(), 0.0001);
    try testing.expect(s.penumbra > 0 and s.penumbra < 1);

    const dir = DirectionalLight2D{};
    try testing.expectEqual(@as(f32, 0), dir.angle); // travels right
    try testing.expect(dir.max_distance == 0); // unbounded
    try testing.expectApproxEqAbs(@as(f32, 0.5), dir.height, 0.0001);

    const amb = AmbientLight2D{};
    try testing.expect(amb.appliesEverywhere()); // scene-wide by default

    const env = Environment{};
    try testing.expect(!env.foggy()); // fog off by default
    try testing.expectApproxEqAbs(@as(f32, 0.09), env.ambient()[0], 0.0001);

    const occ = LightOccluder2D{};
    try testing.expectEqual(OccluderMode.auto_sdf, occ.mode);
    try testing.expect(occ.enabled);
}

test "OccluderPolygon: area, bounds and even-odd containment" {
    // A 10x10 square at the origin, wound counter-clockwise in y-up.
    var poly = OccluderPolygon{};
    poly.count = 4;
    const verts = [_]f32{ 0, 0, 10, 0, 10, 10, 0, 10 };
    @memcpy(poly.points[0..verts.len], &verts);
    try testing.expectApproxEqAbs(@as(f32, 100), poly.signedArea(), 0.0001);
    var bounds: [4]f32 = undefined;
    poly.bounds(&bounds);
    try testing.expectEqual([4]f32{ 0, 0, 10, 10 }, bounds);
    try testing.expect(poly.contains(5, 5));
    try testing.expect(!poly.contains(15, 5));
}