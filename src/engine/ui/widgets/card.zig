//! `ui.widgets.card` — cards, sections, panel headers, collapse.
//!
//! A card is a surface with a border and padding. It is the one container that
//! makes a panel look organised rather than stacked, and the reason it is worth
//! having its own file is the HEADER: a title row with an optional action on
//! the right, and a collapse chevron that looks like a chevron.

const std = @import("std");
const cimgui = @import("../cimgui.zig");
const theme = @import("../theme.zig");
const draw = @import("../draw.zig");
const icons = @import("../icons.zig");
const widget = @import("widget.zig");
const Context = @import("../context.zig").Context;
const button = @import("button.zig");

pub const Card = struct {
    ctx: *Context,
    id: []const u8,
    title: []const u8 = "",
    subtitle: []const u8 = "",
    /// An icon in front of the title. A folder, a gear, a light — the fastest
    /// signal a panel can give about what is inside it.
    icon: ?icons.Icon = null,
    /// Drawn on the right of the header: a count, a state, a menu.
    header_extra: ?*const fn (ctx: *Context) void = null,
    /// Filled after the header and before the body.
    /// Returns false to skip the body (a collapsed card, a card that is empty
    /// this frame). The card's chrome is still drawn either way, so a card
    /// never disappears from under the user's cursor.
    body: ?*const fn (ctx: *Context) void = null,
    /// The card's height in pixels, when it has one.
    ///
    /// The background of a card is drawn BEFORE its content (so the content
    /// lands on it), which means its height has to be known before the content
    /// is laid out. A card without a height gets no background — and the honest
    /// version of that is "the caller chose not to reserve space", not "the
    /// framework measures twice".
    height: ?f32 = null,
    /// When set, the card draws its own background and border instead of
    /// relying on the window's.
    framed: bool = true,
    pad: ?f32 = null,
};

pub fn card(c: Card) void {
    const t = &c.ctx.theme;
    const m = t.metrics;
    const pad = c.pad orelse m.panel_pad();

    cimgui.ember_ui_push_id_str(cimgui.text(c.id));
    defer cimgui.ember_ui_pop_id();

    // The trick that makes a card possible in an immediate-mode UI.
    //
    // The background has to be painted BEFORE the content is laid out (so the
    // content lands on top of it) but its height is only known AFTER. So the
    // space is reserved with a dummy FIRST: the dummy submits an item (which is
    // what moves the cursor and what ImGui's layout sees), its rect is the
    // card's rect, the background is painted on that rect, and then the cursor
    // is put back at the card's inner corner and the header and body are laid
    // out inside it.
    //
    // A card with no height gets no background — see the `height` field's
    // comment, because "framed" that is measured after the fact is not a thing
    // an immediate-mode UI can do.
    var inner_origin = draw.cursorPos();
    var w: f32 = 0;
    if (c.height) |h| {
        w = @max(draw.contentAvail().x, 1);
        cimgui.ember_ui_dummy(w, h);
        const outer = draw.itemRect();
        const list = draw.itemList();
        if (c.framed) {
            list.roundedGradient(outer, t.colors.surface_hi, t.colors.surface, m.radius_md());
            list.rectOutline(outer, t.colors.border, m.radius_md(), 1);
        }
        inner_origin = .{
            .x = outer.min.x + pad,
            .y = outer.min.y + pad,
        };
        draw.setCursorPos(inner_origin);
    }

    if (c.title.len != 0) _ = header(c, pad, w);

    if (c.body) |b| b(c.ctx);
}

/// The header row. Returns its height so the caller can stack.
fn header(c: Card, pad: f32, w: f32) f32 {
    const t = &c.ctx.theme;
    const m = t.metrics;
    const h: f32 = 22.0;
    const list = draw.itemList();
    const start = draw.cursorPos();

    var x = start.x;
    const cy = start.y + h * 0.5;
    if (c.icon) |ic| {
        icons.render(list, ic, .{ .x = x + 8, .y = cy }, t.colors.text_dim, 16, 0);
        x += 22;
    }
    // `withFont` is a template: the body is a named function and the args a
    // tuple, so the call reads like a function call instead of a closure.
    c.ctx.withFont(.ui_semibold, TitleInFont, .{ cimgui.Vec2{ .x = x, .y = start.y + 2 }, c.title, c.ctx.theme.colors.text });
    x += draw.textSize(c.title).x + m.gap();

    if (c.subtitle.len != 0) {
        list.text(.{ .x = x, .y = start.y + 3 }, t.colors.text_faint, c.subtitle);
    }

    // The extra is drawn on the RIGHT edge of the row. It gets the remaining
    // width, which is why a card header can hold a count without the header
    // having to know how wide a count is.
    if (c.header_extra) |extra| {
        const cur = draw.cursorPos();
        const avail = draw.contentAvail().x;
        draw.setCursorPos(.{ .x = cur.x + @max(0, avail - 96), .y = cur.y });
        extra(c.ctx);
    }

    cimgui.ember_ui_dummy(if (w > 0) @max(w - pad * 2, 1) else @max(draw.contentAvail().x, 1), h);
    return h + m.gap();
}

/// The title, drawn in the semibold face at the text colour. A named function
/// because `withFont` is a template, not a callback.
fn TitleInFont(at: cimgui.Vec2, s: []const u8, col: cimgui.Rgba) void {
    draw.itemList().text(at, col, s);
}

/// A section: a title, a rule, and the content. The unit of organisation inside
/// a panel — cheaper than a card, and the right weight for a group of fields.
pub const Section = struct {
    ctx: *Context,
    title: []const u8,
    body: *const fn (ctx: *Context) void,
    /// A rule under the title. On by default; off for the first section in a
    /// panel, where a rule separates the panel from nothing.
    rule: bool = true,
};

pub fn section(s: Section) void {
    const t = &s.ctx.theme;
    const m = t.metrics;
    if (s.title.len != 0) {
        draw.itemList().text(
            .{ .x = draw.cursorPos().x, .y = draw.cursorPos().y },
            t.colors.text_dim,
            s.title,
        );
        cimgui.ember_ui_dummy(@max(draw.contentAvail().x, 1), 1);
        if (s.rule) {
            const r = draw.itemRect();
            draw.itemList().separator(.{ .min = r.min, .max = r.max }, t.colors.border);
        }
        cimgui.ember_ui_dummy(1, m.gap());
    }
    s.body(s.ctx);
    cimgui.ember_ui_dummy(1, m.section_gap());
}

/// A collapse header that looks like a file explorer row, because that is what
/// the user has clicked ten thousand times before opening this editor.
pub const Collapse = struct {
    ctx: *Context,
    id: []const u8,
    label: []const u8,
    open: *bool,
    icon: ?icons.Icon = null,
    trailing: ?[]const u8 = null,
    disabled: bool = false,
    height: f32 = 0,
};

pub fn collapse(c: Collapse) bool {
    const t = &c.ctx.theme;
    const m = t.metrics;
    const h = if (c.height > 0) c.height else m.row_h();

    var toggled = false;
    const hit = widget.submit(cimgui.text(c.id), draw.contentAvail().x, h, c.disabled);
    const list = draw.itemList();
    const r = hit.rect;

    if (hit.state != .idle) {
        list.rect(draw.inset(r, 2), theme.fill(t, hit.state), m.radius_sm());
    }
    var x = r.min.x + 4;
    const cy = r.min.y + h * 0.5;
    icons.render(
        list,
        if (c.open.*) .chevron_down else .chevron_right,
        .{ .x = x + 8, .y = cy },
        t.colors.text_faint,
        16,
        0,
    );
    x += 20;
    if (c.icon) |ic| {
        icons.render(list, ic, .{ .x = x + 8, .y = cy }, t.colors.text_dim, 16, 0);
        x += 20;
    }
    list.text(.{ .x = x, .y = r.min.y + (h - 16) * 0.5 }, theme.textColor(t, hit.state), c.label);
    if (c.trailing) |tr| {
        const size = draw.textSize(tr);
        list.text(
            .{ .x = r.max.x - size.x - 8, .y = r.min.y + (h - 16) * 0.5 },
            t.colors.text_faint,
            tr,
        );
    }
    if (hit.hovered and hit.clicked) {
        c.open.* = !c.open.*;
        toggled = true;
    }
    if (toggled or (hit.clicked)) return true;
    if (c.open.*) {
        cimgui.ember_ui_indent(m.space(2));
        cimgui.ember_ui_dummy(1, 0);
    }
    return toggled;
}

/// The counterpart of `collapse`: closes what it opened. Separate on purpose,
/// because an unbalanced pair is a nesting bug that shows up as a panel whose
/// contents are indented for the rest of the session.
pub fn collapseEnd() void {
    cimgui.ember_ui_unindent(0);
}

test "ui card: a card's content width is the panel's width minus twice the pad" {
    // The number a two-column layout depends on. If `panel_pad` changes and
    // this does not, a card's contents overflow by exactly the difference —
    // invisibly, until the window is narrow.
    const m: theme.Metrics = .{};
    const panel: f32 = 300;
    const inner = panel - m.panel_pad() * 2;
    try std.testing.expectEqual(@as(f32, 272), inner);
    try std.testing.expect(inner < panel);
}
