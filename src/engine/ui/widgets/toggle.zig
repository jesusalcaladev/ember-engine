//! `ui.widgets.toggle` — checkbox, switch, segmented control.
//!
//! Three controls for three different questions, which is the reason they are
//! not one control with a style flag:
//!
//! - **Checkbox**: "is this on?" in a list of options. Small, quiet.
//! - **Switch**: "is this running?" where running has an immediate effect —
//!   physics debug, a light, god mode. It says "this is live now".
//! - **Segmented**: one of N mutually exclusive options. Always shows all of
//!   them, because the point is to see the alternatives.

const std = @import("std");
const cimgui = @import("../cimgui.zig");
const theme = @import("../theme.zig");
const draw = @import("../draw.zig");
const icons = @import("../icons.zig");
const widget = @import("widget.zig");
const Context = @import("../context.zig").Context;

// ── Checkbox ─────────────────────────────────────────────────────────────

pub const Checkbox = struct {
    ctx: *Context,
    id: []const u8,
    label: []const u8,
    value: *bool,
    disabled: bool = false,
    /// Draws the label to the right of the box (the default) or under it.
    label_after: bool = true,
    tooltip: ?[]const u8 = null,
};

/// Returns true on the frame it toggles.
pub fn checkbox(c: Checkbox) bool {
    const t = &c.ctx.theme;
    const m = t.metrics;
    const box: f32 = 16.0;
    const gap = m.gap();
    const label_w: f32 = if (c.label.len != 0) draw.textSize(c.label).x else 0;
    const total = box + (if (label_w > 0) gap + label_w else 0);

    const hit = widget.submit(cimgui.text(c.id), total, box, c.disabled);
    const list = draw.itemList();
    const r = hit.rect;
    const st: theme.State = hit.state;

    // The box itself. 16x16 with a 4px radius: square enough to read as a
    // box, round enough not to look like a 1998 control.
    const br = draw.rect(r.min.x, r.min.y, r.min.x + box, r.min.y + box);
    const on = c.value.*;
    if (on) {
        list.roundedGradient(br, t.colors.accent_hover, t.colors.accent, m.radius_sm());
        // The tick is drawn rather than borrowed from the font, so it takes the
        // exact accent colour and sits on the exact 16px box at any DPI.
        list.line(
            .{ .x = br.min.x + 4, .y = br.min.y + 8.5 },
            .{ .x = br.min.x + 7, .y = br.min.y + 11.5 },
            t.colors.text_on_accent,
            1.8,
        );
        list.line(
            .{ .x = br.min.x + 7, .y = br.min.y + 11.5 },
            .{ .x = br.min.x + 12, .y = br.min.y + 5 },
            t.colors.text_on_accent,
            1.8,
        );
    } else {
        const fillc = switch (st) {
            .hover => t.colors.surface_hi2,
            .active => t.colors.surface_hi2,
            else => t.colors.surface_hi,
        };
        list.rect(br, fillc, m.radius_sm());
        list.rectOutline(br, if (st == .idle) t.colors.border_strong else t.colors.accent, m.radius_sm(), 1);
    }
    if (hit.focused) list.focusRing(br, m.radius_sm(), m.focus_ring(), t.colors.border_focus);

    if (c.label.len != 0) {
        list.text(
            .{ .x = br.max.x + gap, .y = r.min.y + 1 },
            theme.textColor(t, st),
            c.label,
        );
    }
    if (c.tooltip) |tip| {
        if (hit.hovered) cimgui.ember_ui_set_tooltip(cimgui.text(tip));
    }
    if (hit.clicked) {
        c.value.* = !c.value.*;
        return true;
    }
    return false;
}

// ── Switch ───────────────────────────────────────────────────────────────

pub const Switch = struct {
    ctx: *Context,
    id: []const u8,
    label: []const u8 = "",
    value: *bool,
    disabled: bool = false,
    tooltip: ?[]const u8 = null,
};

/// The switch's whole width when it has no label: 34x18. The proportions are
/// 1.9:1, which is the ratio every iOS/Android/desktop switch agrees on, and
/// agreeing is why users reach for it without reading.
pub const switch_w: f32 = 34.0;
pub const switch_h: f32 = 18.0;

pub fn switch_(s: Switch) bool {
    const t = &s.ctx.theme;
    const m = t.metrics;
    const gap = m.gap();
    const label_w: f32 = if (s.label.len != 0) draw.textSize(s.label).x else 0;
    const total = switch_w + (if (label_w > 0) gap + label_w else 0);

    const hit = widget.submit(cimgui.text(s.id), total, switch_h, s.disabled);
    const list = draw.itemList();
    const r = draw.rect(hit.rect.min.x, hit.rect.min.y, hit.rect.min.x + switch_w, hit.rect.min.y + switch_h);
    const on = s.value.*;
    const st: theme.State = hit.state;

    // The track. Off is a surface with a border; on is the accent. No
    // intermediate colour, because a track that is "sort of on" is a state the
    // user has to interpret.
    if (on) {
        list.roundedGradient(r, t.colors.accent_hover, t.colors.accent, switch_h * 0.5);
    } else {
        list.rect(r, switch (st) {
            .hover => t.colors.surface_hi2,
            else => t.colors.surface_hi,
        }, switch_h * 0.5);
        list.rectOutline(r, if (st == .idle) t.colors.border_strong else t.colors.accent, switch_h * 0.5, 1);
    }

    // The knob: 14px in an 18px track, so 2px of air on each side. It moves to
    // the very edge (not one pixel short) — a knob that stops short reads as a
    // control that is stuck.
    const knob_r: f32 = 14.0;
    const kx = if (on) r.max.x - knob_r - 1 else r.min.x + 1;
    const kc = draw.center(.{ .min = .{ .x = kx, .y = r.min.y + 1 }, .max = .{ .x = kx + knob_r, .y = r.max.y - 1 } });
    list.circle(kc, knob_r * 0.5, if (on) cimgui.Rgba.of(1, 1, 1, 0.95) else t.colors.text_dim);
    if (!on and st == .hover) list.circleOutline(kc, knob_r * 0.5 + 0.5, t.colors.border_strong, 1);

    if (s.label.len != 0) {
        list.text(.{ .x = r.max.x + gap, .y = hit.rect.min.y + 1 }, theme.textColor(t, st), s.label);
    }
    if (s.tooltip) |tip| {
        if (hit.hovered) cimgui.ember_ui_set_tooltip(cimgui.text(tip));
    }
    if (hit.clicked) {
        s.value.* = !s.value.*;
        return true;
    }
    return false;
}

// ── Segmented control ────────────────────────────────────────────────────

pub const Segment = struct {
    id: []const u8,
    label: []const u8,
    icon: ?icons.Icon = null,
};

pub const Segmented = struct {
    ctx: *Context,
    id: []const u8,
    segments: []const Segment,
    /// The index of the selected segment. A pointer because this is a control
    /// that changes state, and every ImGui widget that changes state takes a
    /// pointer — a value would be a snapshot of the selection, taken before
    /// the click that changed it.
    selected: *usize,
    disabled: bool = false,
    height: f32 = 0,
};

pub fn segmented(s: Segmented) void {
    const t = &s.ctx.theme;
    const m = t.metrics;
    const h = if (s.height > 0) s.height else m.row_h();
    const radius = m.radius_sm();

    // One background for the whole control, and one raised "pill" over the
    // selected segment. Drawing a fill per segment looks like three buttons;
    // this looks like one control with three positions, which is what it is.
    const widths: f32 = blk: {
        var w: f32 = 0;
        for (s.segments) |seg| {
            const tw: f32 = if (seg.label.len != 0) draw.textSize(seg.label).x else 0;
            const iw: f32 = if (seg.icon != null) 20 else 0;
            w += tw + iw + m.pad_x() * 2;
        }
        break :blk w;
    };

    const outer = widget.submitFull(cimgui.text(s.id), h, s.disabled);
    const list = draw.itemList();
    const r = draw.rect(outer.rect.min.x, outer.rect.min.y, outer.rect.min.x + @min(widths, outer.rect.max.x - outer.rect.min.x), outer.rect.min.y + h);
    list.rect(r, t.colors.surface, radius);
    list.rectOutline(r, t.colors.border, radius, 1);

    var x = r.min.x;
    const inner_pad: f32 = 2.0;
    for (s.segments, 0..) |seg, i| {
        const tw: f32 = if (seg.label.len != 0) draw.textSize(seg.label).x else 0;
        const iw: f32 = if (seg.icon != null) 20 else 0;
        const w = tw + iw + m.pad_x() * 2;
        const seg_rect = draw.rect(x, r.min.y, x + w, r.max.y);
        if (i == s.selected.*) {
            // The pill is INSET by the control's padding, so the selection does
            // not touch the border and the control keeps its shape.
            const pill = draw.inset(seg_rect, inner_pad);
            list.roundedGradient(pill, t.colors.surface_hi2, t.colors.surface_hi, radius);
            list.rectOutline(pill, t.colors.border_strong, radius, 1);
        }
        const fg = if (i == s.selected.*) t.colors.text else t.colors.text_dim;
        var tx = seg_rect.min.x + m.pad_x();
        if (seg.icon) |ic| {
            icons.render(list, ic, .{ .x = tx + 8, .y = seg_rect.min.y + h * 0.5 }, fg, 16, 0);
            tx += 20;
        }
        if (seg.label.len != 0) {
            list.text(.{ .x = tx, .y = seg_rect.min.y + (h - 16) * 0.5 }, fg, seg.label);
        }
        // The hit test is per segment rather than one for the control: ImGui's
        // hit testing is per item, and one item means the whole control is
        // clickable and only the first segment ever changes the selection.
        if (!s.disabled) {
            cimgui.ember_ui_push_id_int(@intCast(i));
            if (cimgui.ember_ui_invisible_button("seg", seg_rect.max.x - seg_rect.min.x, h, 0) != 0) {
                s.selected.* = i;
            }
            cimgui.ember_ui_pop_id();
        }
        x += w;
    }
}

test "ui toggle: the switch has the proportions users reach for" {
    // 1.9:1. Not a taste question: it is the ratio of the control in every
    // tool the user has ever used, and deviating from it by more than a few
    // percent is what makes a switch feel "off" without being wrong.
    const ratio = switch_w / switch_h;
    try std.testing.expect(@abs(ratio - 1.9) < 0.05);
}

test "ui toggle: the knob leaves air on both sides" {
    // 14 in 18: a knob that fills its track reads as a slider, and a slider
    // that toggles is a control nobody has seen before.
    const knob: f32 = 14.0;
    try std.testing.expectEqual(@as(f32, 4.0), switch_h - knob);
    try std.testing.expect(knob < switch_h);
}
