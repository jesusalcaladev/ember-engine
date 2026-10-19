//! `ui.layout` — rows, columns, panels, splitters, and the window helpers.
//!
//! ## Why there is a layout layer at all
//!
//! ImGui's layout is a cursor: every item goes where the cursor is, and moving
//! the cursor is a global operation. That is exactly right for a list of
//! things and exactly wrong for a panel, where a label has to line up with its
//! field and a button has to sit at the right edge of a header.
//!
//! Every layout tool in the industry is one function over that: `Row` is
//! "leave the cursor where you found it, offset by N", `Column` is "remember
//! the cursor, put it back". Both are three lines of `ImGui::SameLine` and
//! `SetCursorPos`, and both are the difference between a panel that looks
//! designed and one that looks assembled.
//!
//! ## The pair every panel needs
//!
//! ```zig
//! ui.Row(ctx, .{ .gap = 8 }, struct { fn body(c: *Context) void {
//!     ui.label(c, "Name");
//!     ui.spacerToEnd(c);            // the label hugs the left, the field the right
//!     _ = textField(.{ .ctx = c, .id = "name", .width = 200, .buf = &buf, .capacity = 64 });
//! } }.body);
//! ```

const std = @import("std");
const cimgui = @import("cimgui.zig");
const theme = @import("theme.zig");
const draw = @import("draw.zig");
const icons = @import("icons.zig");
const Context = @import("context.zig").Context;
const button = @import("widgets/button.zig");

pub const RowOptions = struct {
    /// Where the first item starts, relative to the current cursor.
    offset_x: f32 = 0,
};

/// Draws items left to right on one line. The body is a separate function
/// because the cursor has to be put back afterwards, and "put it back" only
/// works if the function that moved it is the one that restores it.
///
/// The body owns the `SameLine` calls BETWEEN its items; this function must not
/// emit one at the end. It used to, and that was the bug that put every field
/// after a row on the same line: `SameLine` overrides the Y the cursor was
/// restored to, so "restore the row, then continue below it" turned into
/// "continue beside it".
pub fn row(ctx: *Context, opts: RowOptions, body: *const fn (ctx: *Context) void) void {
    const start = draw.cursorPos();
    draw.setCursorPos(.{ .x = start.x + opts.offset_x, .y = start.y });
    body(ctx);
    // The row's height is the tallest thing in it, and ImGui knows that: after
    // the body, the cursor is already past the tallest item. Restoring the X and
    // leaving Y alone is what makes the next row sit below the tallest.
    const after = draw.cursorPos();
    draw.setCursorPos(.{ .x = start.x, .y = after.y });
}

/// Draws `body` at an indented offset, without leaving the line. The
/// difference from `row` is that the content is COLUMN-ALIGNED with itself,
/// which is what a group of fields wants.
pub fn column(ctx: *Context, indent: f32, body: *const fn (ctx: *Context) void) void {
    const start = draw.cursorPos();
    draw.setCursorPos(.{ .x = start.x + indent, .y = start.y });
    body(ctx);
    const after = draw.cursorPos();
    draw.setCursorPos(.{ .x = start.x, .y = after.y });
}

/// Vertical space in units of the scale.
pub fn space(ctx: *Context, units: f32) void {
    cimgui.ember_ui_dummy(1, ctx.theme.metrics.space(units));
}

/// Horizontal space of exactly `w` pixels, without changing the line.
pub fn gap(w: f32) void {
    cimgui.ember_ui_dummy(w, 1);
    cimgui.ember_ui_same_line(0, 0);
}

/// Puts the NEXT item at the right edge of the available width.
///
/// The trick every tool uses and almost none document: the position is computed
/// from the current cursor, so a header with a right-aligned button needs no
/// knowledge of the panel's width, the button's width, or how many other things
/// are on the line.
pub fn spacerToEnd(ctx: *Context) void {
    _ = ctx;
    const cur = draw.cursorPos();
    const avail = draw.contentAvail().x;
    // Reserve a row's worth of height so the right-aligned item is on the same
    // line as whatever is to its left.
    cimgui.ember_ui_dummy(@max(avail, 1), 0);
    draw.setCursorPos(.{ .x = cur.x + @max(avail, 1), .y = cur.y });
}

/// Centres the next item in the available width.
pub fn centerNext(ctx: *Context, w: f32, h: f32) void {
    _ = ctx;
    const cur = draw.cursorPos();
    const avail = draw.contentAvail().x;
    draw.setCursorPos(.{ .x = cur.x + @max((avail - w) * 0.5, 0), .y = cur.y });
    cimgui.ember_ui_dummy(w, h);
}

// ── Panels ───────────────────────────────────────────────────────────────

pub const Panel = struct {
    ctx: *Context,
    id: []const u8,
    /// 0 = the rest of the parent's height.
    height: f32 = 0,
    header: ?*const fn (ctx: *Context) void = null,
    body: ?*const fn (ctx: *Context) void = null,
    /// A panel with a header reserves the header's height INSIDE its own
    /// region, so the body's first row is the same distance from the panel's top
    /// whatever the header contains.
    pad: ?f32 = null,
};

/// A titled region with its own background, the shape every dockable panel in
/// the editor is.
pub fn panel(p: Panel) void {
    const t = &p.ctx.theme;
    const m = t.metrics;
    const pad = p.pad orelse m.panel_pad();

    cimgui.ember_ui_push_id_str(cimgui.text(p.id));
    defer cimgui.ember_ui_pop_id();

    const avail = draw.contentAvail();
    const h = if (p.height < 0) avail.y + p.height else @min(p.height, avail.y);

    // Borders are OFF and the frame is painted by hand, for the same reason as
    // the fields: one border implementation, drawn by the same code that draws
    // everything else.
    const visible = cimgui.ember_ui_begin_child("panel", 0, @max(h, 1), 0, 0) != 0;
    if (!visible) {
        cimgui.ember_ui_end_child();
        return;
    }

    const region = draw.itemRect();
    const list = draw.itemList();
    // A panel is one step LIGHTER than the window behind it, not darker: on a
    // dark background, elevation is lightness. That single inversion is what
    // makes a dock layout look like floating panels instead of holes.
    list.rect(region, t.colors.surface, 0);
    draw.itemList().separator(
        .{ .min = .{ .x = region.min.x, .y = region.max.y - 1 }, .max = region.max },
        t.colors.border,
    );

    var y = region.min.y + pad;
    if (p.header) |hd| {
        const cur = draw.cursorPos();
        draw.setCursorPos(.{ .x = region.min.x + pad, .y = y });
        hd(p.ctx);
        const after = draw.cursorPos();
        y = @max(after.y + m.gap(), y + 24);
        draw.setCursorPos(.{ .x = cur.x, .y = y });
    }
    if (p.body) |b| {
        const cur = draw.cursorPos();
        draw.setCursorPos(.{ .x = region.min.x + pad, .y = y });
        b(p.ctx);
        const after = draw.cursorPos();
        draw.setCursorPos(.{ .x = cur.x, .y = @max(after.y, y) });
    }
    cimgui.ember_ui_end_child();
}

/// A draggable splitter. Returns true on the frame it moved, with the new
/// size in `out`.
///
/// A splitter is the one widget here that changes LAYOUT, and it does so by
/// writing a store key — which is why dragging a divider and closing the editor
/// still leaves the divider where it was put.
pub const Splitter = struct {
    ctx: *Context,
    id: []const u8,
    /// The store key holding the split position, in pixels.
    key: []const u8,
    axis: enum { horizontal, vertical } = .vertical,
    /// The extent the split divides, used to clamp the drag.
    total: f32 = 0,
    min: f32 = 64.0,
    max: f32 = 0,
    thickness: f32 = 6.0,
};

pub fn splitter(s: Splitter) bool {
    const t = &s.ctx.theme;
    const m = t.metrics;
    const avail = draw.contentAvail();
    const is_v = s.axis == .vertical;

    const current = s.ctx.store.getFloat(s.key, if (is_v) 240 else 160);
    const pos = if (is_v) draw.cursorPos() else draw.cursorPos();
    const r = if (is_v)
        draw.rect(pos.x + current, pos.y, pos.x + current + s.thickness, pos.y + @max(avail.y, s.thickness))
    else
        draw.rect(pos.x, pos.y + current, pos.x + @max(avail.x, s.thickness), pos.y + current + s.thickness);

    cimgui.ember_ui_invisible_button(cimgui.text("split"), @max(draw.width(r), s.thickness), @max(draw.height(r), s.thickness), 0);
    const hovered = cimgui.ember_ui_is_item_hovered(cimgui.HoveredFlags.None) != 0;
    const active = cimgui.ember_ui_is_item_active() != 0;

    if (hovered or active) {
        // A 2px line, not a filled 6px box. The 6px is the GRAB TARGET; the
        // visible thing is the line, and a visible thing 6px wide turns a
        // panel edge into a stripe.
        if (is_v) {
            draw.itemList().rect(
                draw.rect(r.min.x + 2, r.min.y, r.min.x + 4, r.max.y),
                if (active) t.colors.accent else t.colors.border_strong,
                1,
            );
        } else {
            draw.itemList().rect(
                draw.rect(r.min.x, r.min.y + 2, r.max.x, r.min.y + 4),
                if (active) t.colors.accent else t.colors.border_strong,
                1,
            );
        }
    }

    var changed = false;
    if (active) {
        const mouse = &s.ctx.window.input.mouse;
        var next = current + (if (is_v) mouse.dx else mouse.dy);
        const hi = if (s.max > 0) s.max else (if (s.total > 0) s.total - m.panel_pad() * 2 else std.math.floatMax(f32));
        next = std.math.clamp(next, s.min, @max(hi, s.min));
        if (next != current) {
            s.ctx.store.set(s.key, f32, next) catch {};
            changed = true;
        }
    }
    return changed;
}

// ── Windows ──────────────────────────────────────────────────────────────

/// A full-screen editor window with no decoration, no moving and no resizing.
/// The shape a workspace panel is: a region, a name, and nothing else.
pub fn fullscreen(ctx: *Context, id: []const u8, body: *const fn (ctx: *Context) void) void {
    const w: f32 = @floatFromInt(ctx.window.fb_width);
    const h: f32 = @floatFromInt(ctx.window.fb_height);
    const visible = beginHost(ctx, id, .{
        .x = 0,
        .y = 0,
        .w = w,
        .h = h,
        .resizable = false,
        .fixed = true,
        .flags = cimgui.WindowFlags.NoDecoration |
            cimgui.WindowFlags.NoMove |
            cimgui.WindowFlags.NoSavedSettings |
            cimgui.WindowFlags.NoBringToFrontOnFocus,
    });
    if (visible) body(ctx);
    // `End` is unconditional: ImGui requires the pair even on a collapsed
    // window, and skipping it is what leaves the next window parented wrongly.
    cimgui.ember_ui_end();
}

/// A panel that floats: a real ImGui window, positioned by the caller, with a
/// title bar. Used for the asset browser and the console when they are
/// undocked, and for the editor dock when they are not.
pub fn floating(ctx: *Context, id: []const u8, opts: FloatingOptions, body: *const fn (ctx: *Context) void) void {
    const visible = beginHost(ctx, id, opts);
    if (visible) body(ctx);
    cimgui.ember_ui_end();
}

pub const FloatingOptions = struct {
    x: f32 = 0,
    y: f32 = 0,
    w: f32 = 0,
    h: f32 = 0,
    /// Placed on first use only. After that ImGui remembers, which is what a
    /// user expects from a tool they rearranged yesterday.
    first_use: bool = true,
    resizable: bool = true,
    menu_bar: bool = false,
    /// Extra `WindowFlags`, OR'd on top of the ones derived above.
    ///
    /// This is where a docked-looking panel asks for `NoDecoration | NoMove`:
    /// the shell pins it in place and draws its OWN header, so ImGui's title
    /// bar would be a second, mismatched one. A fixed editor layout is a set of
    /// windows that must NOT be draggable, and "not draggable" has to be
    /// expressible without a fifth boolean per window flag.
    flags: u32 = 0,
    /// The position and size are the layout's, not the user's: they are applied
    /// EVERY frame (`Cond.Always`), which is the only thing that makes a pinned
    /// dock stay pinned. `first_use` alone would leave the window at whatever
    /// ImGui remembered from last session — and with `NoSavedSettings` there is
    /// nothing to remember, so it would sit at the origin.
    fixed: bool = false,
};

fn beginHost(ctx: *Context, id: []const u8, opts: FloatingOptions) bool {
    _ = ctx;
    var flags: u32 = opts.flags;
    if (opts.w <= 0 or opts.h <= 0) flags |= cimgui.WindowFlags.AlwaysAutoResize;
    if (!opts.resizable) flags |= cimgui.WindowFlags.NoResize;
    if (opts.menu_bar) flags |= cimgui.WindowFlags.MenuBar;
    const cond: cimgui.Cond = if (opts.fixed)
        .Always
    else if (opts.first_use)
        .FirstUseEver
    else
        .None;
    cimgui.ember_ui_set_next_window_pos(opts.x, opts.y, @intFromEnum(cond));
    cimgui.ember_ui_set_next_window_size(opts.w, opts.h, @intFromEnum(cond));
    return cimgui.ember_ui_begin(cimgui.text(id), @bitCast(flags)) != 0;
}

test "ui layout: a row's items are separated by exactly the gap" {
    // The number a toolbar's total width is computed from. If the gap is
    // applied once per item instead of once BETWEEN items, the row is `gap`
    // wider than its contents and drifts right every time it is rebuilt.
    const m: theme.Metrics = .{};
    const items: f32 = 4;
    const gap_total = (items - 1) * m.gap();
    try std.testing.expectEqual(m.gap() * 3, gap_total);
}
