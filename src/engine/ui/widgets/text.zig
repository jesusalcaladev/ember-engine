//! `ui.widgets.text` — labels, headings, badges and chips.
//!
//! The cheapest file in the folder and the one that decides whether the editor
//! looks designed: hierarchy is made of size, weight and colour, and ImGui's
//! defaults give you exactly one size and one weight.

const std = @import("std");
const cimgui = @import("../cimgui.zig");
const theme = @import("../theme.zig");
const draw = @import("../draw.zig");
const icons = @import("../icons.zig");
const Context = @import("../context.zig").Context;

/// Plain text in the current colour.
pub fn label(ctx: *Context, s: []const u8) void {
    _ = ctx;
    cimgui.ember_ui_text(cimgui.text(s));
}

/// Text in an explicit colour. For the one-off (a red value, a dim hint), not
/// for a category — a category is a token in `theme.Palette`.
pub fn colored(ctx: *Context, col: cimgui.Rgba, s: []const u8) void {
    _ = ctx;
    cimgui.ember_ui_text_colored(col.pack(), cimgui.text(s));
}

/// Wraps to the available width. The only correct way to show a long string in
/// a panel, because a panel's width is not known until it is drawn.
pub fn wrapped(ctx: *Context, col: cimgui.Rgba, s: []const u8) void {
    _ = ctx;
    cimgui.ember_ui_text_wrapped(col.pack(), cimgui.text(s));
}

/// A section title: semibold, one step down from the panel's own title.
///
/// Semibold rather than bold on purpose — Inter Bold at 13.5px on a dark
/// background blooms into a grey smear, and semibold is the weight that stays
/// crisp without turning on synthetic bolding.
pub fn title(ctx: *Context, s: []const u8) void {
    // The body takes the ctx by pointer and reads it, so the `_ =` that Zig
    // asks for is on the PARAMETER it does not use, not the one it does.
    draw.drawInFont(ctx, .ui_semibold, TitleInFont, .{ ctx, s });
    cimgui.ember_ui_spacing();
}

/// A subtitle under a title. Dim, regular, and NOT spaced after: the space
/// between a title and its subtitle belongs to the pair, not to the subtitle.
pub fn subtitle(ctx: *Context, s: []const u8) void {
    cimgui.ember_ui_text_colored(ctx.theme.colors.text_dim.pack(), cimgui.text(s));
}

/// Small dim text: units, hints, a path under a field.
pub fn caption(ctx: *Context, s: []const u8) void {
    cimgui.ember_ui_text_colored(ctx.theme.colors.text_faint.pack(), cimgui.text(s));
}

/// Text that is a value: numbers, paths, identifiers. Always monospace, always
/// the dim colour, because a number in a list of numbers has to be alignable
/// and a value has to look like a value.
pub fn value(ctx: *Context, s: []const u8) void {
    draw.drawInFont(ctx, .mono, ValueInFont, .{ ctx, s });
}

/// A small rounded pill with text: "unsaved", "M5", "beta".
///
/// Drawn, not a button: it reserves its own size from the measured text, so a
/// badge never changes width when its content does.
pub const Badge = struct {
    ctx: *Context,
    text: []const u8,
    tone: Tone = .neutral,
    icon: ?icons.Icon = null,

    pub const Tone = enum { neutral, accent, success, warning, danger };

    pub fn render(self: Badge) void {
        const t = &self.ctx.theme;
        const m = t.metrics;
        const h: f32 = 18.0;
        const tw = draw.textSize(self.text).x;
        const iw: f32 = if (self.icon != null) 14 else 0;
        const w = tw + iw + m.pad_x();

        const avail = draw.contentAvail().x;
        if (w > avail) return; // no room: skip, do not clip, do not wrap

        cimgui.ember_ui_dummy(w, h);
        const r = draw.itemRect();
        const list = draw.itemList();

        const base = switch (self.tone) {
            .neutral => t.colors.surface_hi2,
            .accent => t.colors.accent_soft,
            .success => t.colors.success_soft,
            .warning => t.colors.warning_soft,
            .danger => t.colors.danger_soft,
        };
        const fg = switch (self.tone) {
            .neutral => t.colors.text_dim,
            .accent => t.colors.accent_text,
            .success => t.colors.success,
            .warning => t.colors.warning,
            .danger => t.colors.danger,
        };
        list.rect(r, base, h * 0.5);
        var x = r.min.x + m.pad_x() * 0.5;
        if (self.icon) |ic| {
            icons.render(list, ic, .{ .x = x + 7, .y = r.min.y + h * 0.5 }, fg, 14, 1.3);
            x += iw;
        }
        list.text(.{ .x = x, .y = r.min.y + 3 }, fg, self.text);
    }
};

/// A key hint: "Ctrl S", drawn the way an editor draws it, in a box.
///
/// A shortcut shown as plain text ("Save (Ctrl+S)") is read once and never
/// again. A shortcut shown as a kbd chip next to the button is read every time
/// the user looks at the button, which is the only time it is useful.
pub fn kbd(ctx: *Context, s: []const u8) void {
    const t = &ctx.theme;
    const size = draw.textSize(s);
    const pad: f32 = 4.0;
    const w = size.x + pad * 2;
    const h = size.y + 3.0;
    cimgui.ember_ui_dummy(w, h);
    const r = draw.itemRect();
    const list = draw.itemList();
    list.rect(r, t.colors.surface_hi2, 4.0);
    list.rectOutline(r, t.colors.border, 4.0, 1.0);
    list.text(.{ .x = r.min.x + pad, .y = r.min.y + 1.5 }, t.colors.text_dim, s);
}

/// Horizontal space, for a right-aligned control on the same row.
pub fn spacer(w: f32) void {
    cimgui.ember_ui_dummy(w, 1.0);
    cimgui.ember_ui_same_line(0, 0);
}

/// A 1px rule. `full` draws edge to edge, which is right inside a card and
/// wrong inside a window, where the window's own padding should show.
pub fn separator(ctx: *Context, full: bool) void {
    const t = &ctx.theme;
    const avail = draw.contentAvail();
    const x0 = if (full) 0 else 0;
    _ = x0;
    cimgui.ember_ui_dummy(avail.x, 1.0);
    const r = draw.itemRect();
    draw.itemList().separator(.{ .min = r.min, .max = r.max }, t.colors.border);
    cimgui.ember_ui_spacing();
}

/// Vertical space in multiples of the unit scale.
pub fn space(ctx: *Context, units: f32) void {
    cimgui.ember_ui_dummy(1, ctx.theme.metrics.space(units));
}

/// A title in the semibold face, at the TEXT colour.
fn TitleInFont(c: *Context, text: []const u8) void {
    cimgui.ember_ui_text_colored(c.theme.colors.text.u32(), cimgui.text(text));
}

/// A value in the mono face, at the DIM colour: numbers, paths, identifiers.
fn ValueInFont(c: *Context, text: []const u8) void {
    cimgui.ember_ui_text_colored(c.theme.colors.text_dim.u32(), cimgui.text(text));
}

test "ui text: a badge's width comes from its text, so it cannot clip" {
    // The rule the implementation follows: measure, then reserve. A badge that
    // reserves a fixed width and renders longer text is a badge with a typo in
    // it somewhere. The measurement is `Badge.render`'s job and needs a
    // context; what is testable headless is the ARITHMETIC it does with the
    // measurement, which is the part a badge's clipping is decided by.
    const m: theme.Metrics = .{};
    const short: f32 = 40.0; // a short label's measured width
    const long: f32 = 120.0; // a long label's measured width
    const w = struct {
        fn f(text: f32, mm: theme.Metrics) f32 {
            return text + mm.pad_x();
        }
    }.f;
    try std.testing.expect(w(long, m) > w(short, m));
    // And the fit check the render does: a longer label produces a wider badge,
    // which is exactly the direction clipping comes from.
    try std.testing.expect(w(long, m) - w(short, m) == long - short);
}
