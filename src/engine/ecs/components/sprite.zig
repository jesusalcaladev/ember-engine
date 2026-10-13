//! Sprite components — `Blend`, `SpriteShape` and `Sprite` (M2, split out of
//! components.zig).

const core_math = @import("core").math;
const transform_mod = @import("transform.zig");

pub const Vec2 = core_math.Vec2;
const unit = transform_mod.unit;

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

    /// M7: index into the lighting system's coverage store, or -1 for none.
    ///
    /// An INDEX and not a pointer because the component registry forbids
    /// pointers and slices in components — they are plain data, for the SoA
    /// tables and for the `.zson` encoding, and a `[]const u8` in a component is
    /// both. The pixels therefore live in a store that lighting owns and the
    /// asset pipeline fills, and the component carries only the number.
    ///
    /// ## What it is for
    ///
    /// An automatic `LightOccluder2D` promises that adding a sprite makes it
    /// occlude, with no author action. The rectangle fails that promise: a
    /// character's silhouette is not its bounding box, and the difference is a
    /// rectangle of shadow hanging in the air beside it. With this set, the
    /// occluder is the sprite's actual shape and `alpha_threshold` decides where
    /// its edge is drawn.
    ///
    /// ## Why it lives on the Sprite and not on the occluder
    ///
    /// Because it is a property of the ASSET, not of any one occluder. Two actors
    /// sharing a texture share the coverage, and an occluder carrying its own copy
    /// would be a copy per occluder of data that does not change.
    ///
    /// ## Who fills it in
    ///
    /// M6 (the asset pipeline) registers the coverage and sets this index. Until
    /// then it is -1 and automatic occluders fall back to their rectangle — the
    /// current behaviour, unchanged, and the reason -1 is not a regression.
    coverage_index: i32 = -1,
};

// ── Tests ────────────────────────────────────────────────────────────────────

const std = @import("std");
const testing = std.testing;

test "Sprite is POD with sane defaults (the .zson baseline)" {
    const s = Sprite{};
    try testing.expectEqual(@as(u8, 0), s.atlas);
    try testing.expectEqual(@as(u16, 0), s.layer);
    try testing.expectEqual(@as(f32, 1), s.size.x);
    try testing.expectEqual(@as(f32, 1), s.uv[2]);
    try testing.expectEqual(Blend.alpha, s.blend);
    try testing.expect(s.visible);
    // Kept small on purpose: the 50k canonical scene multiplies this by 50000,
    // so 56 B/sprite is 2.8 MB of column data (spec §5 allows it, but it is
    // pure cache pressure in the render walk).
    //
    // 56 and not the 52 this used to pin: M7 added `coverage_index` (an i32
    // index into the lighting coverage store), and the pinned size was not
    // updated with it. The field is real data, so the number moves and the
    // comment follows it rather than the field being packed away to keep a
    // stale constant.
    try testing.expectEqual(@as(usize, 56), @sizeOf(Sprite));
}