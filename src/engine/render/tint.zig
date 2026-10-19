//! M14 — CanvasModulate: the full-screen tint.
//!
//! Godot's `CanvasModulate` is a colour laid over the whole canvas. Here it is
//! the post pass's other full-screen effect, beside the M9 fade, and it costs
//! one `vec4` of uniform and no extra draw call when it is off — the same
//! bargain the fade makes, for the same reason.
//!
//! ## What it is NOT
//!
//! It tints the finished image, so it hits the WORLD and the game UI together
//! (the UI is drawn into the scene target, before the post pass). A tint that
//! reaches only one of the two is out of scope for M14 and is noted in the
//! plan; this struct has no per-layer state because nothing yet needs it.
//!
//! ## Three modes, and off
//!
//! - `multiply` — `c * tint`: grading an ambience (dusk, night, a cave).
//! - `add`      — `c + tint`: a flash (damage, muzzle, lightning).
//! - `alpha`    — `mix(c, tint, a)`: a flat veil.
//!
//! `off` disables the effect. A zero AMOUNT also disables it — an animation
//! driving the strength down to zero must turn the pass off without also
//! having to name a mode — which is why `postActive` tests the amount, not the
//! mode.
//!
//! ## Why it lives in `render` and not in a gameplay module
//!
//! Same reason as the fade: it is PRESENTATION, a per-frame value the post
//! shader reads. The runtime owns the instance (like it owns the `Fader`) and
//! publishes it into `SceneEnvironment` every frame; a script only ever names a
//! colour and a mode through the `scene.*` bindings.

const std = @import("std");
const testing = std.testing;

/// The mix the post pass applies. The numbers are the WIRE codes: they are what
/// `backend_dawn` writes into the uniform, so they are pinned here (0 off,
/// 1 multiply, 2 add, 3 alpha) rather than left implicit in two files.
pub const Mode = enum(u8) {
    off = 0,
    multiply = 1,
    add = 2,
    alpha = 3,
};

pub const Tint = struct {
    /// rgb + strength in alpha, the same convention `fade_color` uses: the
    /// colour is separate from how much of it is applied, so a script can
    /// animate the strength without rewriting the colour.
    color: [4]f32 = .{ 1, 1, 1, 0 },
    /// `multiply` by default, so `scene.tint(r,g,b,a)` is "tint it the usual
    /// way" without a second call. `off` is only ever reached through `clear`
    /// or an explicit `setMode`.
    mode: Mode = .multiply,

    /// Applies a colour and an amount. Enables `multiply` if the effect was
    /// OFF, so the first `scene.tint` call turns it on; an explicit
    /// `scene.tint_mode` afterwards still wins. An `amount` of 0 leaves the
    /// mode alone (an animation running the strength to zero is not the same as
    /// the author turning the effect off) — the shader treats a zero amount as
    /// a no-op either way.
    pub fn set(self: *Tint, r: f32, g: f32, b: f32, a: f32) void {
        self.color = .{ r, g, b, a };
        if (self.mode == .off) self.mode = .multiply;
    }

    /// Sets the mode explicitly. Does not touch the colour, so the sequence
    /// `tint` then `tint_mode` composes the way a script reads.
    pub fn setMode(self: *Tint, mode: Mode) void {
        self.mode = mode;
    }

    /// Turns the effect off and forgets the colour. What a script does when a
    /// damage flash ends early or a scene change wants a clean slate.
    pub fn clear(self: *Tint) void {
        self.mode = .off;
        self.color = .{ 1, 1, 1, 0 };
    }

    /// The current strength, 0..1. The value a script animates against.
    pub fn amount(self: *const Tint) f32 {
        return self.color[3];
    }

    /// rgb + strength, which is exactly what `SceneEnvironment.tint_color`
    /// wants and what the uniform carries.
    pub fn rgba(self: *const Tint) [4]f32 {
        return self.color;
    }
};

// ── Tests ────────────────────────────────────────────────────────────────────

test "a tint from off turns on and defaults to multiply" {
    var t = Tint{};
    t.clear();
    try testing.expectEqual(Mode.off, t.mode);
    t.set(0.5, 0.25, 0.75, 0.4);
    try testing.expectEqual(Mode.multiply, t.mode);
    try testing.expectEqual([4]f32{ 0.5, 0.25, 0.75, 0.4 }, t.rgba());
}

test "set does not override a mode the author already chose" {
    var t = Tint{};
    t.setMode(.add);
    t.set(1, 1, 0, 0.8);
    try testing.expectEqual(Mode.add, t.mode);
    // And a colour that reaches a zero amount keeps the mode: the animation is
    // allowed to run the strength to zero without disarming the effect.
    t.set(1, 1, 0, 0);
    try testing.expectEqual(Mode.add, t.mode);
    try testing.expectEqual(@as(f32, 0), t.amount());
}

test "clear disables and forgets the colour" {
    var t = Tint{};
    t.set(0.1, 0.2, 0.3, 0.9);
    t.clear();
    try testing.expectEqual(Mode.off, t.mode);
    try testing.expectEqual(@as(f32, 0), t.amount());
    try testing.expectEqual([4]f32{ 1, 1, 1, 0 }, t.rgba());
}

test "the mode wire codes are the ones the uniform carries" {
    // These numbers cross into `backend_dawn` as `@intFromEnum`, so a reorder
    // here is a silent remap of every tinted scene. Pinned deliberately.
    try testing.expectEqual(@as(u8, 0), @intFromEnum(Mode.off));
    try testing.expectEqual(@as(u8, 1), @intFromEnum(Mode.multiply));
    try testing.expectEqual(@as(u8, 2), @intFromEnum(Mode.add));
    try testing.expectEqual(@as(u8, 3), @intFromEnum(Mode.alpha));
}
