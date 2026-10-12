//! `ShaderMaterial` — the user-authored-shader hook component (M2, split out
//! of components.zig).

const entity = @import("../entity.zig");

pub const SceneId = entity.SceneId;

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