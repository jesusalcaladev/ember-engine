//! M14 UI runtime components — the plain-data half of the game's own UI.
//!
//! ## Why components and not a node tree
//!
//! The editor's UI is ImGui and stays in the editor. A game needs HUD text,
//! buttons and bars that survive serialization, are editable in the inspector,
//! and are addressable from Lua by the actor that owns them — which is exactly
//! what an ECS component already is (spec §7: the public surface is Actor +
//! Components, and the ECS is internal).
//!
//! ## Layout is a FIELD, not a component
//!
//! Every widget carries a `UiLayout`, so a widget and its placement are one
//! entity and one `.zson` entry. The alternative — a separate `UiLayout`
//! component — would make every widget two entities and every `ui.set_anchor`
//! a two-component lookup, for no gain: nothing shares a layout.
//!
//! ## Runtime state lives here too, deliberately
//!
//! `UiLayout.resolved` (the rect this frame produced) and `UiButton.state` are
//! written by the UI system, not by a script. They are the same kind of field as
//! `Sprite.coverage_index`: a number the runtime fills and a reader reads. That
//! keeps `ui.rect(self)` a component read instead of a second layout pass, and
//! it is why they are documented as runtime fields rather than authored ones.

const core_math = @import("core").math;
pub const Vec2 = core_math.Vec2;
pub const Rect2 = core_math.Rect2;

/// Inline text: a label's string, fixed size and byte-copyable like `Name`.
///
/// Longer than `Name` (32) because a label is a sentence and a name is a word,
/// but still inline: a `[]const u8` in a component would be a pointer, which the
/// registry forbids, and an allocation would be frame-loop work. Truncation at
/// `max_len` is silent and documented (the same contract `Name` has).
pub const InlineText = struct {
    bytes: [max_len]u8 = [_]u8{0} ** max_len,
    len: u8 = 0,

    pub const max_len = 128;

    pub fn init(text: []const u8) InlineText {
        var t = InlineText{};
        t.set(text);
        return t;
    }

    pub fn set(self: *InlineText, text: []const u8) void {
        const n = @min(text.len, max_len);
        @memcpy(self.bytes[0..n], text[0..n]);
        self.len = @intCast(n);
    }

    pub fn slice(self: *const InlineText) []const u8 {
        return self.bytes[0..self.len];
    }

    pub fn eql(self: *const InlineText, text: []const u8) bool {
        return std.mem.eql(u8, self.slice(), text);
    }
};

/// Where a widget is placed on the canvas, Godot-style: an anchor preset, an
/// offset from it, and a size. The three stretch presets ignore `size` and use
/// `margin` instead.
pub const UiAnchor = enum(u8) {
    top_left = 0,
    top_center = 1,
    top_right = 2,
    middle_left = 3,
    center = 4,
    middle_right = 5,
    bottom_left = 6,
    bottom_center = 7,
    bottom_right = 8,
    /// Full width, `size.y` tall, pinned to the anchor's vertical edge.
    stretch_h = 9,
    /// Full height, `size.x` wide, pinned to the anchor's horizontal edge.
    stretch_v = 10,
    /// The whole canvas, inset by `margin`.
    full_rect = 11,
};

/// Placement plus order. Not a registered component on its own: it is a field
/// of every widget (see the file header).
pub const UiLayout = struct {
    anchor: UiAnchor = .top_left,
    /// Displacement from the resolved anchor point, in canvas pixels.
    offset: Vec2 = .{ .x = 0, .y = 0 },
    /// Widget size in canvas pixels. Ignored by `full_rect` and by the axis a
    /// stretch preset fills.
    size: Vec2 = .{ .x = 100, .y = 30 },
    /// 0,0 anchors the widget's top-left at the anchor; 0.5,0.5 centres it.
    pivot: Vec2 = .{ .x = 0, .y = 0 },
    /// top, right, bottom, left insets, used only by the stretch presets.
    margin: [4]f32 = .{ 0, 0, 0, 0 },
    /// Stable tie-break for paint order and hit-testing: higher draws later and
    /// wins a click. Equal orders fall back to entity slot order (spec §6).
    order: i32 = 0,
    visible: bool = true,
    /// Whether this widget blocks world input and can be hovered/clicked.
    interactive: bool = true,

    /// RUNTIME: the screen-pixel rect the UI system resolved this frame.
    /// Written by `ui_system`, read by `ui_draw` and `ui.rect(self)`.
    resolved: Rect2 = .{},
};

/// The screen root. One per scene (the first one wins). Its `scale_mode` is how
/// virtual resolution maps to the framebuffer; its `layer_base` keeps UI above
/// the world in the light-mask layer space.
pub const UiScaleMode = enum(u8) {
    /// 1:1 with the framebuffer — exact pixels, for a HUD.
    pixel = 0,
    /// Uniform scale plus letterbox — a game sized to one aspect ratio.
    fit = 1,
    /// Independent x/y scale — fills any window, distorting.
    stretch = 2,
};

pub const UiCanvas = struct {
    virtual_w: f32 = 1280,
    virtual_h: f32 = 720,
    scale_mode: UiScaleMode = .fit,
    /// The render/light layer UI instances carry (`layer_base + order`).
    ///
    /// 255 — the wildcard the light pass treats as "every light" — is the right
    /// default for an unlit HUD: text and panels must not go dark when a masked
    /// light sweeps the world. It is a `u16` to match `Sprite.layer`, but only
    /// the low byte reaches the GPU (`SpriteInstance.layer` is the byte the R8
    /// layer target holds), so `ui_draw` clamps into 0..255. Draw order ABOVE
    /// the world comes from the UI being emitted after it, not from this value.
    layer_base: u16 = 255,
};

/// Horizontal alignment of a label inside its resolved rect.
pub const TextAlign = enum(u8) { left = 0, center = 1, right = 2 };

/// A run of text. `font` is 0 for the engine default or an id from
/// `ui.font_load`.
pub const Label = struct {
    layout: UiLayout = .{},
    font: u32 = 0,
    text: InlineText = .{},
    color: [4]f32 = .{ 1, 1, 1, 1 },
    /// Named `alignment`, not `align`: `align` is a Zig keyword. The Lua setter
    /// is still `ui.set_align`, which reads better than `set_alignment`.
    alignment: TextAlign = .left,
};

/// A button's runtime interaction state, written by the UI system.
pub const UiButtonState = enum(u8) { normal = 0, hover = 1, pressed = 2 };

/// A clickable box with a label. Emits the `ui_pressed` signal (carrying `id`)
/// when a press and its release land on the same button.
pub const UiButton = struct {
    layout: UiLayout = .{},
    text: InlineText = .{},
    font: u32 = 0,
    /// Returned in the `ui_pressed` signal so a script knows which button.
    id: u32 = 0,
    enabled: bool = true,
    color_normal: [4]f32 = .{ 0.30, 0.32, 0.38, 1 },
    color_hover: [4]f32 = .{ 0.40, 0.43, 0.52, 1 },
    color_pressed: [4]f32 = .{ 0.22, 0.24, 0.30, 1 },
    text_color: [4]f32 = .{ 0.95, 0.96, 1, 1 },

    /// RUNTIME: interaction state, written by the UI system each frame.
    state: UiButtonState = .normal,
};

/// A filled box: a HUD backdrop, a menu background, a divider. An optional
/// border is drawn as four thin quads (no nine-slice in v1).
pub const UiPanel = struct {
    layout: UiLayout = .{},
    color: [4]f32 = .{ 0.08, 0.09, 0.12, 0.85 },
    border_color: [4]f32 = .{ 0, 0, 0, 0 },
    border_width: f32 = 0,
};

/// A 0..1 bar. `value` drives the fill width; `text` is drawn optionally.
pub const UiProgressBar = struct {
    layout: UiLayout = .{},
    value: f32 = 0,
    bg_color: [4]f32 = .{ 0.15, 0.15, 0.18, 1 },
    fill_color: [4]f32 = .{ 0.30, 0.72, 0.38, 1 },
    show_text: bool = false,
    text: InlineText = .{},
    font: u32 = 0,
};

// ── Tests ────────────────────────────────────────────────────────────────────

const std = @import("std");
const testing = std.testing;

test "InlineText sets, slices and truncates at max_len" {
    var t = InlineText{};
    t.set("Hello");
    try testing.expectEqualStrings("Hello", t.slice());
    try testing.expect(t.eql("Hello"));
    try testing.expect(!t.eql("Hell"));

    const long = [_]u8{'a'} ** (InlineText.max_len + 40);
    t.set(&long);
    try testing.expectEqual(@as(u8, InlineText.max_len), t.len);
    try testing.expectEqual(InlineText.max_len, t.slice().len);
}

test "the layout defaults are a placed 100x30 box" {
    const l = UiLayout{};
    try testing.expectEqual(UiAnchor.top_left, l.anchor);
    try testing.expectEqual(@as(f32, 100), l.size.x);
    try testing.expectEqual(@as(f32, 30), l.size.y);
    try testing.expect(l.visible);
    try testing.expect(l.interactive);
    // The runtime rect starts empty and is filled by the system.
    try testing.expectEqual(@as(f32, 0), l.resolved.size.x);
}

test "widget components are POD with the expected defaults" {
    const label = Label{};
    try testing.expectEqual(@as(u32, 0), label.font);
    try testing.expectEqual(TextAlign.left, label.alignment);
    try testing.expectEqualStrings("", label.text.slice());

    const button = UiButton{};
    try testing.expect(button.enabled);
    try testing.expectEqual(UiButtonState.normal, button.state);
    try testing.expectEqual(@as(u32, 0), button.id);

    const bar = UiProgressBar{};
    try testing.expectEqual(@as(f32, 0), bar.value);
    try testing.expect(!bar.show_text);

    const canvas = UiCanvas{};
    try testing.expectEqual(UiScaleMode.fit, canvas.scale_mode);
    try testing.expectEqual(@as(u16, 255), canvas.layer_base);

    const panel = UiPanel{};
    try testing.expectEqual(@as(f32, 0), panel.border_width);
}

test "the widget strides are pinned so an accidental growth is caught" {
    // These are archetype column widths; the numbers matter to the memory
    // budget the same way `Sprite`'s 56 does, and a silent change should fail
    // here rather than show up as cache pressure later.
    try testing.expectEqual(@as(usize, 1), @sizeOf(TextAlign));
    try testing.expectEqual(@as(usize, 1), @sizeOf(UiButtonState));
    try testing.expectEqual(@as(usize, 1), @sizeOf(UiAnchor));
    // InlineText is 128 bytes plus its length byte.
    try testing.expectEqual(@as(usize, InlineText.max_len + 1), @sizeOf(InlineText));
    // Every widget must stay inside the `.zson` decode buffer.
    const ecs = @import("../components.zig");
    try testing.expect(@sizeOf(Label) <= ecs.max_stride);
    try testing.expect(@sizeOf(UiButton) <= ecs.max_stride);
    try testing.expect(@sizeOf(UiPanel) <= ecs.max_stride);
    try testing.expect(@sizeOf(UiProgressBar) <= ecs.max_stride);
    try testing.expect(@sizeOf(UiCanvas) <= ecs.max_stride);
}
