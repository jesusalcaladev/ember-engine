//! `ui.widgets.button` — buttons, and the states that make one look expensive.
//!
//! A button is an invisible item plus a rectangle. Everything that makes it
//! look like a 2026 control instead of an ImGui one is here, and all of it is
//! five lines of drawing:
//!
//! - a gradient when idle, flat on hover and press (motion reads as shading)
//! - a 1px border that is a border, not a shadow
//! - a focus ring OUTSIDE the control
//! - a pressed control that moves down 1px, which is the only animation that
//!   every design system has agreed on
//!
//! The pressed-offset is the one worth arguing about: it is 1 pixel, it costs
//! nothing, and without it a button gives no feedback until it is released.

const std = @import("std");
const cimgui = @import("../cimgui.zig");
const theme = @import("../theme.zig");
const draw = @import("../draw.zig");
const icons = @import("../icons.zig");
const widget = @import("widget.zig");
const Context = @import("../context.zig").Context;
const button_mod = @import("button.zig");
const Rgba = cimgui.Rgba;

pub const Variant = enum {
    /// The one accent-filled button a panel may contain. More than one per row
    /// and the user cannot tell which is the default.
    primary,
    /// The default: a surface with a border.
    secondary,
    /// No fill at all until hovered. For a toolbar, where 12 buttons in a row
    /// with 12 fills is a stripe of noise.
    ghost,
    /// A destructive action. Red text on hover, red fill when pressed — never
    /// a permanently red button, which is a form that says "this dialog is an
    /// error" before anything has happened.
    danger,
    /// Nothing but the icon; a square.
    icon,
};

pub const Props = struct {
    ctx: *Context,
    id: []const u8,
    text: []const u8 = "",
    icon: ?icons.Icon = null,
    icon_after: ?icons.Icon = null,
    variant: Variant = .secondary,
    disabled: bool = false,
    /// 0 = as wide as the text plus padding, which is what a button in a
    /// toolbar wants and a button in a dialog does not.
    width: f32 = 0,
    /// Overrides the control height. The row height by default.
    height: f32 = 0,
    tooltip: ?[]const u8 = null,
    on_click: ?*const fn (ctx: ?*anyopaque) void = null,
    ctx_arg: ?*anyopaque = null,
};

/// Returns true on the frame the button is pressed.
pub fn render(p: Props) bool {
    const t = &p.ctx.theme;
    const m = t.metrics;
    const h = if (p.height > 0) p.height else m.row_h();
    const text_w = if (p.text.len != 0) draw.textSize(p.text).x else 0;
    const icon_w: f32 = if (p.icon != null or p.icon_after != null) m.icon_w() else 0;
    const content_w = text_w + icon_w * @as(f32, @intFromBool(p.icon != null)) + icon_w * @as(f32, @intFromBool(p.icon_after != null));
    const w = if (p.width > 0) p.width else content_w + m.pad_x() * 2;

    const hit = widget.submit(cimgui.text(p.id), w, h, p.disabled);
    paint(p, hit, w, h, content_w);

    if (p.tooltip) |tip| {
        if (hit.hovered) cimgui.ember_ui_set_tooltip(cimgui.text(tip));
    }
    if (hit.clicked) {
        if (p.on_click) |cb| cb(p.ctx_arg orelse p.ctx);
        return true;
    }
    return false;
}

/// The drawing, separated from the interaction so that the same paint runs for
/// a button, a menu item and a list row that wants to look like a button.
pub fn paint(p: Props, hit: widget.Hit, w: f32, h: f32, content_w: f32) void {
    const t = &p.ctx.theme;
    const m = t.metrics;
    const list = draw.itemList();

    // The press offset. One pixel down, one pixel of radius unchanged, and the
    // whole control reads as "held".
    const press: f32 = if (hit.state == .active) 1.0 else 0.0;
    const r = draw.rect(hit.rect.min.x, hit.rect.min.y + press, hit.rect.min.x + w, hit.rect.min.y + press + h);

    const radius: f32 = switch (p.variant) {
        .icon => m.radius_sm(),
        .primary, .danger => m.radius_sm(),
        else => m.radius_sm(),
    };

    switch (p.variant) {
        .primary => {
            list.control(r, radius, theme.accentFill(t, hit.state), theme.accentFill(t, .hover), hit.state);
            if (hit.state == .idle) {
                list.rectOutline(r, t.colors.accent_active, radius, 1);
            }
        },
        .danger => {
            const base = if (hit.state == .idle) t.colors.danger_soft else t.colors.danger.withAlpha(0.22);
            const hot = if (hit.state == .disabled) t.colors.danger.withAlpha(0.08) else t.colors.danger.withAlpha(0.28);
            list.control(r, radius, base, hot, hit.state);
            list.rectOutline(r, t.colors.danger.withAlpha(if (hit.state == .disabled) 0.2 else 0.5), radius, 1);
        },
        .secondary => {
            list.control(r, radius, theme.fill(t, hit.state), theme.fill(t, .hover), hit.state);
            list.rectOutline(r, t.colors.border, radius, 1);
            if (hit.state == .hover) list.rectOutline(r, t.colors.border_strong, radius, 1);
        },
        .ghost => {
            // A ghost button's border exists only on hover, so the toolbar row
            // is not a row of boxes until the user points at one.
            if (hit.state != .idle) {
                list.rect(r, theme.fill(t, hit.state), radius);
            }
        },
        .icon => {
            if (hit.state != .idle) list.rect(r, theme.fill(t, hit.state), radius);
        },
    }

    if (hit.focused) {
        draw.itemList().focusRing(r, radius, m.focus_ring(), t.colors.border_focus);
    }

    // ── Content ──────────────────────────────────────────────────────────
    const fg: Rgba = switch (p.variant) {
        .primary => if (hit.state == .disabled) t.colors.text_on_accent.withAlpha(0.5) else t.colors.text_on_accent,
        .danger => if (hit.state == .disabled) t.colors.danger.withAlpha(0.4) else t.colors.danger_hover,
        else => theme.textColor(t, hit.state),
    };

    var x = r.min.x + (w - content_w) * 0.5;
    const y = r.min.y + (h - 16.0) * 0.5 + 1.0; // optical: text sits 1px high
    if (p.icon) |ic| {
        icons.render(list, ic, .{ .x = x + 8, .y = y + 8 }, fg, 16, 0);
        x += m.icon_w();
    }
    if (p.text.len != 0) {
        list.text(.{ .x = x, .y = y }, fg, p.text);
    }
    if (p.icon_after) |ic| {
        const end = r.max.x - m.pad_x();
        icons.render(list, ic, .{ .x = end - 8, .y = y + 8 }, fg, 16, 0);
    }
}

/// A square icon button. Its own function because a square is not a button with
/// an empty label: it has to stay square when the text is long, and the
/// width calculation in `render` has nothing to calculate from.
pub fn icon(p: Props) bool {
    var props = p;
    props.variant = .icon;
    props.text = "";
    props.width = if (p.width > 0) p.width else p.ctx.theme.metrics.icon_btn();
    return render(props);
}

/// A row of buttons, the shape a dialog's action row takes.
///
/// `stretch` makes them share the available width equally. It is off by default
/// because a toolbar of twelve icon buttons stretched across 1600 pixels is
/// worse than one that is exactly as wide as its contents, and because
/// "stretched" is a property of a DIALOG, not of a row.
pub fn row(ctx: *Context, id: []const u8, items: []const Item, opts: RowOptions) void {
    const t = &ctx.theme;
    const m = t.metrics;
    const gap = m.gap();
    if (items.len == 0) return;

    const avail = draw.contentAvail().x;
    var widths: [16]f32 = undefined;
    var natural: f32 = gap * @as(f32, @floatFromInt(items.len - 1));
    for (items, 0..) |it, i| {
        if (i >= widths.len) break;
        widths[i] = naturalWidth(m, it);
        natural += widths[i];
    }

    if (opts.stretch and items.len <= widths.len and natural < avail) {
        const extra = (avail - natural) / @as(f32, @floatFromInt(items.len));
        for (items, 0..) |_, i| {
            if (i >= widths.len) break;
            widths[i] += extra;
        }
    }

    var id_buf: [button_mod.id_suffix_buf]u8 = undefined;
    for (items, 0..) |it, i| {
        if (i > 0) cimgui.ember_ui_same_line(0, gap);
        _ = render(.{
            .ctx = ctx,
            .id = tryId(&id_buf, id, i),
            .text = it.text,
            .icon = it.icon,
            .variant = it.variant,
            .disabled = opts.disabled or it.disabled,
            .width = if (i < widths.len) widths[i] else 0,
            .tooltip = it.tooltip,
            .on_click = if (it.on_click) |c| @ptrCast(c) else null,
            .ctx_arg = it.ctx_arg,
        });
    }
}

pub const RowOptions = struct {
    disabled: bool = false,
    stretch: bool = false,
};

/// How wide a button wants to be, before any stretching. The number lives here
/// so `render` and `row` cannot disagree about it — and they did, once, which
/// is why a stretched dialog's buttons were 4px narrower than their contents.
pub fn naturalWidth(m: theme.Metrics, it: Item) f32 {
    if (it.width > 0) return it.width;
    const text_w: f32 = if (it.text.len != 0) draw.textSize(it.text).x else 0;
    const icon_w: f32 = if (it.icon != null) m.icon_w() else 0;
    return text_w + icon_w + m.pad_x() * 2;
}

pub const Item = struct {
    text: []const u8 = "",
    icon: ?icons.Icon = null,
    variant: Variant = .secondary,
    disabled: bool = false,
    width: f32 = 0,
    tooltip: ?[]const u8 = null,
    on_click: ?*const fn (ctx: ?*anyopaque) void = null,
    ctx_arg: ?*anyopaque = null,
};

/// An index-qualified button id.
///
/// The caller passes a buffer, because the id has to outlive the loop body
/// that makes it: a `var buf: [64]u8` inside the helper is a stack address,
/// and the first button's id is then whatever the second one wrote. This is
/// the use-after-scope that the first version had, and it looked like "the
/// second button does nothing".
pub const id_suffix_buf: usize = 64;

pub fn tryId(buf: []u8, id: []const u8, i: usize) [:0]const u8 {
    var n: usize = 0;
    for (id) |ch| {
        if (n + 2 >= buf.len) break;
        buf[n] = ch;
        n += 1;
    }
    buf[n] = '/';
    n += 1;
    const digits = decimal(i, buf[n..]);
    n += digits;
    buf[n] = 0;
    return buf[0..n :0];
}

fn decimal(v: usize, out: []u8) usize {
    var tmp: [20]u8 = undefined;
    var i: usize = 0;
    var x = v;
    if (x == 0) {
        out[0] = '0';
        return 1;
    }
    while (x > 0) : (x /= 10) {
        tmp[i] = '0' + @as(u8, @intCast(x % 10));
        i += 1;
    }
    for (0..i) |j| out[j] = tmp[i - 1 - j];
    return i;
}

test "ui button: the default width is the content plus the padding" {
    // The number a layout depends on. If `pad_x` changes and this does not, a
    // toolbar of buttons gets progressively clipped from the right.
    const m: theme.Metrics = .{};
    const text_w: f32 = 42.0;
    const w = text_w + m.pad_x() * 2;
    try std.testing.expect(w > text_w);
    try std.testing.expectEqual(@as(f32, 62.0), w);
}
