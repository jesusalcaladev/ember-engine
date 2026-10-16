//! `ui.theme` — the design tokens, and the one function that applies them.
//!
//! ## Why this file is the difference between "an ImGui app" and an editor
//!
//! Dear ImGui's default style is a debug view of a widget library: grey
//! rectangles, 4-pixel corners, a 13px bitmap font, and a border so thin it
//! disappears on a projector. It is a fine default and a terrible product. The
//! distance between the two is not "we drew a nicer button" — it is that every
//! colour, radius, pad and type size is a NAME that the whole editor agrees on.
//! `bg`, `surface`, `border`, `accent`, `gap`, `row_h`. Change one token and
//! every button, card and panel changes with it, because none of them own a
//! number.
//!
//! ## The rules
//!
//! 1. **No literal colours outside this file.** A widget that writes
//!    `0xFF202020` is a widget that will not follow a theme change. The one
//!    exception is a colour derived from another one, in a named function here.
//! 2. **Metrics are a scale, not a set.** `space(1)`..`space(4)` and
//!    `radius_sm/md` rather than 6, 8, 10 and 12 scattered through the widgets.
//!    An editor that pads one side of one card by 3px is an editor that looks
//!    broken in a way nobody can name.
//! 3. **The palette is a copy of a real one.** These are GitHub Primer's
//!    dark "dimmed" hues, which are the colours a hundred tools already ship,
//!    so the editor looks familiar before the user has read a word of it.

const std = @import("std");
const cimgui = @import("cimgui.zig");
const Rgba = cimgui.Rgba;

// ── Colour ───────────────────────────────────────────────────────────────

/// The palette. Dark only, on purpose: this is a tool that runs for hours next
/// to a game window, and a light chrome next to a dark viewport is the highest-
/// contrast pairing a display can produce. A light theme is a second palette
/// here when it is needed, not a branch inside the widgets.
pub const Palette = struct {
    // Surfaces, darkest to lightest. Each step is a real elevation: a card on
    // a panel has to be findable without a heavy border, and the only way to
    // get that right on a dark background is to make lightness do the work.
    bg: Rgba = Rgba.hex(0x0D1117, 1.0),
    surface: Rgba = Rgba.hex(0x14181F, 1.0),
    surface_hi: Rgba = Rgba.hex(0x1B2029, 1.0),
    surface_hi2: Rgba = Rgba.hex(0x232936, 1.0),
    /// A floating thing: tooltips, dropdowns, the menu bar.
    overlay: Rgba = Rgba.hex(0x1C222C, 1.0),

    // Lines. Three weights, because "the border" is not one idea: a hairline
    // separates, a border contains, and a focus ring is neither.
    border: Rgba = Rgba.hex(0x2A313D, 1.0),
    border_strong: Rgba = Rgba.hex(0x3A4351, 1.0),
    border_focus: Rgba = Rgba.hex(0x2F81F7, 1.0),

    // Text. Four levels is the most a screen can carry without the lightest
    // becoming unreadable: normal, dim (metadata), faint (disabled), and
    // inverse (text ON an accent fill).
    text: Rgba = Rgba.hex(0xE6EDF3, 1.0),
    text_dim: Rgba = Rgba.hex(0x8B949E, 1.0),
    text_faint: Rgba = Rgba.hex(0x57606A, 1.0),
    text_on_accent: Rgba = Rgba.hex(0xFFFFFF, 1.0),

    // Accent. One hue, five states. This is the whole "brand" of the editor
    // and it is why there is a Theme struct at all: an accent is a decision,
    // and a decision belongs somewhere you can change it.
    accent: Rgba = Rgba.hex(0x2F81F7, 1.0),
    accent_hover: Rgba = Rgba.hex(0x4493F8, 1.0),
    accent_active: Rgba = Rgba.hex(0x1F6FEB, 1.0),
    accent_soft: Rgba = Rgba.hex(0x1F6FEB, 0.16),
    accent_text: Rgba = Rgba.hex(0x6CB6FF, 1.0),

    // Status. Semantic, never decorative: green means "this works", red means
    // "this does not", and an editor that uses red for a heading is a tool
    // people stop believing.
    success: Rgba = Rgba.hex(0x3FB950, 1.0),
    success_soft: Rgba = Rgba.hex(0x3FB950, 0.16),
    warning: Rgba = Rgba.hex(0xD29922, 1.0),
    warning_soft: Rgba = Rgba.hex(0xD29922, 0.16),
    danger: Rgba = Rgba.hex(0xF85149, 1.0),
    danger_hover: Rgba = Rgba.hex(0xFF6A62, 1.0),
    danger_soft: Rgba = Rgba.hex(0xF85149, 0.16),

    // The play/stop pair, which is not the same idea as success/danger: play is
    // a GO, stop is a HALT, and neither means "an error happened".
    play: Rgba = Rgba.hex(0x3FB950, 1.0),
    stop: Rgba = Rgba.hex(0xF85149, 1.0),

    shadow: Rgba = Rgba.hex(0x000000, 0.45),
    scrim: Rgba = Rgba.hex(0x000000, 0.55),
};

// ── Metrics ──────────────────────────────────────────────────────────────

/// Sizes, in logical pixels.
///
/// The numbers are the argument: 4/8/12/16 rather than 5/9/13/17. A scale
/// with irregular steps is a scale where two widgets never line up, and
/// "the paddings are all slightly different" is invisible per-widget and
/// glaring in a screenshot.
pub const Metrics = struct {
    /// The spacing scale. `space(1)` is a gap inside a control, `space(4)` is
    /// the margin around a whole panel.
    unit: f32 = 4.0,

    /// `space(n)` — a multiple of the unit.
    pub fn space(self: Metrics, n: f32) f32 {
        return self.unit * n;
    }
    /// Inside a button or a field.
    pub fn pad_x(self: Metrics) f32 {
        return self.space(2.5);
    }
    pub fn pad_y(self: Metrics) f32 {
        return self.space(1.5);
    }
    /// Between two controls in a group.
    pub fn gap(self: Metrics) f32 {
        return self.space(1.5);
    }
    /// Between two groups.
    pub fn section_gap(self: Metrics) f32 {
        return self.space(3);
    }
    /// Around the content of a panel.
    pub fn panel_pad(self: Metrics) f32 {
        return self.space(3.5);
    }
    /// Around the content of a window.
    pub fn window_pad(self: Metrics) f32 {
        return self.space(3);
    }

    // Corners. Three sizes and no more: small for controls, medium for cards
    // and popups, large for the only thing on screen that is a window.
    //
    // They are constants, and they are still methods: a panel reaches
    // `metrics.radius_sm()`, so the number scales with the theme in one place
    // and a widget never has to import a constant from the palette to know
    // how round it is.
    pub fn radius_sm(_: Metrics) f32 {
        return 5.0;
    }
    pub fn radius_md(_: Metrics) f32 {
        return 8.0;
    }
    pub fn radius_lg(_: Metrics) f32 {
        return 10.0;
    }

    /// The height of a control: 28 is 4 pixels taller than a native menu item,
    /// which is the difference between "a web button" and "a tool".
    pub fn row_h(_: Metrics) f32 {
        return 28.0;
    }
    pub fn row_h_sm(_: Metrics) f32 {
        return 22.0;
    }
    pub fn row_h_lg(_: Metrics) f32 {
        return 34.0;
    }
    /// An icon-only control: a square, so `IconButton` does not have to guess.
    pub fn icon_btn(_: Metrics) f32 {
        return 28.0;
    }
    /// The horizontal slot one icon takes: half a control's height. A button
    /// with an icon and a label is its text plus ONE of these, not the
    /// difference between two fonts.
    pub fn icon_w(self: Metrics) f32 {
        return self.row_h() * 0.5;
    }
    pub fn hairline(_: Metrics) f32 {
        return 1.0;
    }
    pub fn border(_: Metrics) f32 {
        return 1.0;
    }
    /// The focus ring is 2px and 1px out from the control, not 1px on it.
    pub fn focus_ring(_: Metrics) f32 {
        return 2.0;
    }
    pub fn scrollbar(_: Metrics) f32 {
        return 10.0;
    }
    pub fn scrollbar_rounding(_: Metrics) f32 {
        return 5.0;
    }
    /// How far a drag moves a pixel of value, in pixels of movement.
    pub fn drag_sensitivity(_: Metrics) f32 {
        return 0.25;
    }
};

// ── Type ─────────────────────────────────────────────────────────────────

pub const Typography = struct {
    pub const Face = enum {
        /// Inter: the UI face. Baked at each size on demand (ImGui 1.92), so
        /// one load covers 11px captions and 22px titles.
        ui,
        /// JetBrains Mono: every number, path, identifier and log line. Tabular
        /// by construction, which is why a value column does not jitter while
        /// you drag it.
        mono,
    };
};

// ── Theme ────────────────────────────────────────────────────────────────

pub const Theme = struct {
    colors: Palette = .{},
    metrics: Metrics = .{},
    /// Base UI size. 13.5 rather than 13 or 14: it is the size at which
    /// Inter's x-height still reads at 96 DPI, and the editor is read, not
    /// glanced at.
    font_size: f32 = 13.5,
    mono_size: f32 = 12.0,
    caption_size: f32 = 11.0,
    title_size: f32 = 16.0,

    /// The one global, for screenshots and for the "I need to look at the
    /// console while a modal is up" case. Not a Theme variant: a variant
    /// invites a second set of numbers.
    alpha: f32 = 1.0,

    /// Writes every token into ImGui's style.
    ///
    /// One function, called once at boot and again whenever the theme changes.
    /// The reason it is not "each widget sets its own colours" is the reason
    /// this file exists: a style that is applied in one place is one a person
    /// can reason about, and a style applied in thirty places is thirty
    /// chances to forget the hover state.
    pub fn apply(self: Theme) void {
        const c = &self.colors;
        const m = self.metrics;

        cimgui.ember_ui_style_set_alpha(self.alpha);
        cimgui.ember_ui_style_set_font_size(self.font_size);

        cimgui.ember_ui_style_set_WindowPadding(m.window_pad(), m.window_pad());
        cimgui.ember_ui_style_set_WindowRounding(m.radius_lg());
        cimgui.ember_ui_style_set_WindowBorderSize(m.border());

        cimgui.ember_ui_style_set_ChildRounding(m.radius_md());
        cimgui.ember_ui_style_set_ChildBorderSize(m.border());

        cimgui.ember_ui_style_set_PopupRounding(m.radius_md());
        cimgui.ember_ui_style_set_PopupBorderSize(m.border());

        cimgui.ember_ui_style_set_FramePadding(m.pad_x(), m.pad_y());
        cimgui.ember_ui_style_set_FrameRounding(m.radius_sm());
        // Frames carry no border of their own: the widget code draws one, so
        // that hover and focus can change its colour. Two borders on one
        // control is one too many, and ImGui's is the one nobody wants.
        cimgui.ember_ui_style_set_FrameBorderSize(0);

        cimgui.ember_ui_style_set_ItemSpacing(m.gap(), m.gap());
        cimgui.ember_ui_style_set_ItemInnerSpacing(m.gap(), m.gap());
        cimgui.ember_ui_style_set_CellPadding(m.gap(), m.gap());
        cimgui.ember_ui_style_set_IndentSpacing(m.space(2));

        cimgui.ember_ui_style_set_ScrollbarSize(m.scrollbar());
        cimgui.ember_ui_style_set_GrabMinSize(m.row_h_sm());
        cimgui.ember_ui_style_set_GrabRounding(m.radius_sm());
        cimgui.ember_ui_style_set_TabRounding(m.radius_sm());
        cimgui.ember_ui_style_set_TabBorderSize(0);

        setColor(.Text, c.text);
        setColor(.TextDisabled, c.text_faint);
        setColor(.WindowBg, c.bg);
        setColor(.ChildBg, c.surface);
        setColor(.PopupBg, c.overlay);
        setColor(.Border, c.border);
        setColor(.BorderShadow, c.shadow.withAlpha(0.0));
        setColor(.FrameBg, c.surface_hi);
        setColor(.FrameBgHovered, c.surface_hi2);
        setColor(.FrameBgActive, c.surface_hi2);
        setColor(.TitleBg, c.surface);
        setColor(.TitleBgActive, c.surface);
        setColor(.TitleBgCollapsed, c.surface);
        setColor(.MenuBarBg, c.surface);
        setColor(.ScrollbarBg, c.bg.withAlpha(0.0));
        setColor(.ScrollbarGrab, c.border_strong);
        setColor(.ScrollbarGrabHovered, c.text_faint);
        setColor(.ScrollbarGrabActive, c.text_dim);
        setColor(.CheckMark, c.accent_text);
        setColor(.SliderGrab, c.accent);
        setColor(.SliderGrabActive, c.accent_hover);
        setColor(.Button, c.surface_hi);
        setColor(.ButtonHovered, c.surface_hi2);
        setColor(.ButtonActive, c.surface_hi2);
        setColor(.Header, c.surface_hi.withAlpha(0.0));
        setColor(.HeaderHovered, c.surface_hi);
        setColor(.HeaderActive, c.surface_hi2);
        setColor(.Separator, c.border);
        setColor(.SeparatorHovered, c.border_strong);
        setColor(.SeparatorActive, c.accent);
        setColor(.ResizeGrip, c.border.withAlpha(0.0));
        setColor(.ResizeGripHovered, c.border_strong);
        setColor(.ResizeGripActive, c.accent);
        setColor(.Tab, c.surface);
        setColor(.TabHovered, c.surface_hi);
        setColor(.TabSelected, c.surface_hi2);
        setColor(.TabSelectedOverline, c.accent);
        setColor(.DockingPreview, c.accent.withAlpha(0.35));
        setColor(.DockingEmptyBg, c.bg);
        setColor(.PlotLines, c.accent);
        setColor(.PlotLinesHovered, c.accent_hover);
        setColor(.PlotHistogram, c.accent);
        setColor(.PlotHistogramHovered, c.accent_hover);
        setColor(.TableHeaderBg, c.surface_hi);
        setColor(.TableBorderStrong, c.border_strong);
        setColor(.TableBorderLight, c.border);
        setColor(.TableRowBg, c.surface.withAlpha(0.0));
        setColor(.TableRowBgAlt, c.surface_hi.withAlpha(0.35));
        setColor(.TextSelectedBg, c.accent.withAlpha(0.35));
        setColor(.DragDropTarget, c.accent_soft);
        setColor(.NavHighlight, c.accent);
        setColor(.NavWindowingHighlight, c.accent);
        setColor(.NavWindowingDimBg, c.scrim.withAlpha(0.60));
        setColor(.ModalWindowDimBg, c.scrim);
    }

    fn setColor(idx: cimgui.Col, col: Rgba) void {
        cimgui.ember_ui_style_set_color(
            @intFromEnum(idx),
            col.r,
            col.g,
            col.b,
            col.a * currentAlpha(),
        );
    }
};

/// The alpha currently pushed onto ImGui's style stack, so `setColor` scales
/// with it. A modal that dims the window behind it should dim the COLOURS
/// too, and the only way is for the theme's writes to multiply by whatever
/// alpha the caller pushed.
fn currentAlpha() f32 {
    // ImGui exposes the effective style; the shim does not hand it out as a
    // struct, and reading a single float out of it through `style_col` would be
    // reaching into ImGuiCol_Text's alpha — which is a colour, not the style's
    // alpha, and would be wrong in exactly the case this exists for. So the
    // alpha is tracked HERE, which is the only place in /ui that pushes it.
    return pushed_alpha;
}

var pushed_alpha: f32 = 1.0;

/// Pushes the style alpha and remembers it, so `setColor` scales. Pairs with
/// `popAlpha`.
pub fn pushAlpha(a: f32) void {
    pushed_alpha = a;
    cimgui.ember_ui_push_style_var_f(@intFromEnum(cimgui.StyleVar.Alpha), a);
}

pub fn popAlpha() void {
    pushed_alpha = 1.0;
    cimgui.ember_ui_pop_style_var(1);
}

// ── Derived colours ──────────────────────────────────────────────────────
//
// Named functions, not fields: a colour that is a FUNCTION of the palette is
// something that follows a theme change automatically, and a colour that is a
// field can drift out of sync with the field it was derived from. The hover
/// state of a card is exactly that case.

/// The fill behind a control in a given state. This is the one function every
/// button, field, tab and row in /ui calls, which is why they all respond to
/// the theme in one place.
pub const State = enum { idle, hover, active, disabled };

pub fn fill(t: *const Theme, state: State) Rgba {
    const c = t.colors;
    return switch (state) {
        .idle => c.surface_hi,
        .hover => c.surface_hi2,
        .active => c.surface_hi2.scaled(0.92),
        .disabled => c.surface_hi.withAlpha(0.5),
    };
}

pub fn accentFill(t: *const Theme, state: State) Rgba {
    const c = t.colors;
    return switch (state) {
        .idle => c.accent,
        .hover => c.accent_hover,
        .active => c.accent_active,
        .disabled => c.accent.withAlpha(0.4),
    };
}

pub fn textColor(t: *const Theme, state: State) Rgba {
    const c = t.colors;
    return switch (state) {
        .idle => c.text,
        .hover => c.text,
        .active => c.text,
        .disabled => c.text_faint,
    };
}

/// The label colour for a text field's placeholder.
pub fn placeholder(t: *const Theme) Rgba {
    return t.colors.text_faint;
}

// ── Tests ────────────────────────────────────────────────────────────────

const testing = std.testing;

test "ui theme: the packing survives a round trip through the byte helper" {
    // The whole palette passes through `Rgba.hex` on the way in and
    // `Rgba.u32` on the way to ImGui, and a mistake in either is invisible in
    // a screenshot until you notice every colour is slightly wrong.
    const c: Palette = .{};
    try testing.expectEqual(@as(u32, 0xFF), c.text.pack() >> 24); // alpha
    // 0xE6EDF3 is a light grey; in ImGui's 0xAABBGGRR the RED byte is last.
    try testing.expectEqual(@as(u32, 0xE6), c.text.pack() & 0xFF);
    try testing.expectEqual(@as(u32, 0xED), (c.text.pack() >> 8) & 0xFF);
    try testing.expectEqual(@as(u32, 0xF3), (c.text.pack() >> 16) & 0xFF);
}

test "ui theme: alpha in the palette multiplies into the packed form" {
    const soft = Rgba.hex(0x2F81F7, 0.16);
    try testing.expectEqual(@as(u32, 0x29), soft.pack() >> 24);
}

test "ui theme: the spacing scale is a scale" {
    const m: Metrics = .{};
    // The invariant, not a number: every derived gap is a multiple of the
    // unit (0.5 and 1.5 rather than 7 and 11), which is what makes two widgets
    // line up instead of nearly-line-up.
    try testing.expectEqual(m.unit * 2, m.gap() / 0.75);
    try testing.expectEqual(m.unit * 3.5, m.panel_pad());
    try testing.expectEqual(@as(f32, @trunc(m.gap() / (m.unit * 0.5))), m.gap() / (m.unit * 0.5));
    try testing.expectEqual(@as(f32, @trunc(m.radius_md())), m.radius_md());
    try testing.expectEqual(@as(f32, @trunc(m.radius_lg())), m.radius_lg());
}

test "ui theme: every control fits the same heights" {
    // A row of controls where the buttons are 28 and the fields are 26 is the
    // single most common way an editor looks amateur, and it is invisible in
    // code review.
    const m: Metrics = .{};
    try testing.expectEqual(m.row_h(), m.icon_btn());
    // A field's height is its padding plus its content: pad_y*2 + the line.
    // `<=` on purpose: 6+6+16 == 28 is EXACTLY the row, and a control whose
    // content does not fit its own row is the visual bug the claim is about.
    const text_h: f32 = 16.0;
    try testing.expect(m.pad_y() * 2 + text_h <= m.row_h());
}
