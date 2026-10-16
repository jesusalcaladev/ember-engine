//! `ui.widgets.select` — the dropdown.
//!
//! A select is ImGui's `BeginCombo` + `Selectable` pair with a drawn frame and a
//! drawn chevron. That sounds like a thin wrapper, and it is: what it does NOT
//! do is reimplement the popup, because the popup is ImGui's best piece — a
//! positioned, clipped, keyboard-navigable, click-outside-to-close list, and
//! writing one is a week of work that buys nothing.
//!
//! What the wrapper adds is the part that makes it match the rest of the editor:
//! the frame, the hover and focus states, the chevron, the selected row's fill,
//! and the height. Those four are why a dropdown next to a button stops looking
//! like two different programs.

const std = @import("std");
const cimgui = @import("../cimgui.zig");
const theme = @import("../theme.zig");
const draw = @import("../draw.zig");
const icons = @import("../icons.zig");
const widget = @import("widget.zig");
const Context = @import("../context.zig").Context;

pub const Option = struct {
    value: usize,
    label: []const u8,
    icon: ?icons.Icon = null,
    /// Drawn right-aligned in the row: a version, a hotkey, a count.
    hint: []const u8 = "",
    disabled: bool = false,
};

pub const Select = struct {
    ctx: *Context,
    id: []const u8,
    label: []const u8 = "",
    options: []const Option,
    selected: *usize,
    width: f32 = 0,
    label_slot: f32 = 64.0,
    disabled: bool = false,
    /// The row height of the dropdown. 26 is enough for a 13.5px label with
    /// room to click; 32 is for a list of files where the icons are the point.
    row_height: f32 = 26.0,
    tooltip: ?[]const u8 = null,
    on_change: ?*const fn (ctx: ?*anyopaque, value: usize) void = null,
    ctx_arg: ?*anyopaque = null,
};

pub fn select(s: Select) bool {
    const t = &s.ctx.theme;
    const m = t.metrics;
    const h = m.row_h();
    const w = if (s.width > 0) s.width else draw.contentAvail().x - s.label_slot - m.gap();
    if (s.label.len != 0) widget.labelSlot(t, s.label, s.label_slot, h);

    if (s.options.len == 0) {
        cimgui.ember_ui_dummy(w, h);
        const r = draw.itemRect();
        draw.itemList().rect(r, t.colors.surface_hi.withAlpha(0.4), m.radius_sm());
        draw.itemList().rectOutline(r, t.colors.border, m.radius_sm(), 1);
        draw.itemList().text(
            .{ .x = r.min.x + m.pad_x(), .y = r.min.y + (h - 16) * 0.5 },
            t.colors.text_faint,
            "—",
        );
        return false;
    }

    const current = clampIndex(s.options, s.selected.*);
    const preview = s.options[current].label;

    cimgui.ember_ui_push_id_str(cimgui.text(s.id));
    cimgui.ember_ui_push_style_color4(@intFromEnum(cimgui.Col.FrameBg), 0, 0, 0, 0);
    cimgui.ember_ui_push_style_color4(@intFromEnum(cimgui.Col.Border), 0, 0, 0, 0);
    cimgui.ember_ui_set_next_item_width(w);

    var changed = false;
    if (cimgui.ember_ui_begin_combo(field_label, cimgui.text(preview), 0) != 0) {
        const list = draw.itemList();
        // The dropdown's own background. ImGui draws the popup window behind
        // this list, so the fill here is the list's rows; the popup's own
        // WindowBg is what shows at the padding.
        for (s.options) |opt| {
            const sel = opt.value == s.selected.*;
            const list_w = @max(draw.contentAvail().x, 1);
            _ = cimgui.ember_ui_invisible_button("opt", list_w, s.row_height, 0);
            const r = draw.itemRect();
            const hovered = cimgui.ember_ui_is_item_hovered(cimgui.HoveredFlags.None) != 0;
            if (sel or hovered) {
                list.rect(r, if (sel) t.colors.accent_soft else t.colors.surface_hi2, m.radius_sm());
            }
            var x = r.min.x + m.pad_x();
            if (opt.icon) |ic| {
                icons.render(list, ic, .{ .x = x + 8, .y = r.min.y + s.row_height * 0.5 }, t.colors.text_dim, 16, 0);
                x += 20;
            }
            if (opt.hint.len > 0) {
                const size = draw.textSize(opt.hint);
                list.text(
                    .{ .x = r.max.x - size.x - m.pad_x(), .y = r.min.y + (s.row_height - 16) * 0.5 },
                    t.colors.text_faint,
                    opt.hint,
                );
            }
            list.text(
                .{ .x = x, .y = r.min.y + (s.row_height - 16) * 0.5 },
                if (opt.disabled) t.colors.text_faint else if (sel) t.colors.text else t.colors.text_dim,
                opt.label,
            );
            if (cimgui.ember_ui_is_item_clicked(@intFromEnum(cimgui.MouseButton.Left)) != 0 and !opt.disabled) {
                if (s.selected.* != opt.value) {
                    s.selected.* = opt.value;
                    changed = true;
                    if (s.on_change) |cb| cb(s.ctx_arg, opt.value);
                }
                cimgui.ember_ui_end_combo();
                break;
            }
        }
        cimgui.ember_ui_end_combo();
    }
    cimgui.ember_ui_pop_style_color(2);

    // The field's own frame, drawn after the combo is submitted. The combo's
    // rect is the field's rect, so the frame lands exactly on it.
    const r = draw.itemRect();
    const hovered = cimgui.ember_ui_is_item_hovered(cimgui.HoveredFlags.None) != 0;
    const open = cimgui.ember_ui_is_popup_open(field_label, 0) != 0;
    const list = draw.itemList();
    const state: theme.State = if (s.disabled) .disabled else if (open) .active else if (hovered) .hover else .idle;
    list.rect(r, theme.fill(t, state), m.radius_sm());
    list.rectOutline(
        r,
        if (open) t.colors.border_focus else if (hovered) t.colors.border_strong else t.colors.border,
        m.radius_sm(),
        1,
    );
    list.text(
        .{ .x = r.min.x + m.pad_x(), .y = r.min.y + (h - 16) * 0.5 },
        if (s.disabled) t.colors.text_faint else t.colors.text,
        preview,
    );
    // The chevron points DOWN when open and RIGHT when closed. A chevron that
    // does not change is a chevron the user has to learn; one that does is
    // self-explanatory.
    icons.render(
        list,
        if (open) .chevron_down else .chevron_right,
        .{ .x = r.max.x - 16, .y = r.min.y + h * 0.5 },
        t.colors.text_faint,
        16,
        0,
    );

    if (s.tooltip) |tip| {
        if (hovered) cimgui.ember_ui_set_tooltip(cimgui.text(tip));
    }
    cimgui.ember_ui_pop_id();
    return changed;
}

const field_label = cimgui.textLit("##sel");

/// The index of the option whose `value` matches, or 0.
///
/// A select whose selection is not IN its options is a state a caller can
/// create by shrinking the list (a scene unloaded, a filter applied, an asset
/// deleted). Indexing with it is an out-of-bounds read; clamping is the only
/// safe answer, and it is also the only one that does not crash the editor at
/// the moment the user is doing something else.
fn clampIndex(options: []const Option, value: usize) usize {
    if (options.len == 0) return 0;
    for (options, 0..) |o, i| {
        if (o.value == value) return i;
    }
    return 0;
}

test "ui select: a selection that is not in the list clamps to the first" {
    // The scene-unloaded case, as an invariant rather than as a crash.
    const opts = [_]Option{ .{ .value = 3, .label = "a" }, .{ .value = 7, .label = "b" } };
    try std.testing.expectEqual(@as(usize, 1), clampIndex(&opts, 7));
    try std.testing.expectEqual(@as(usize, 0), clampIndex(&opts, 99));
    try std.testing.expectEqual(@as(usize, 0), clampIndex(&opts, 0));
}

test "ui select: an empty list clamps to index 0, which the caller never reads" {
    // `render` checks `options.len == 0` and draws a placeholder field BEFORE
    // calling `clampIndex`, so the clamp's result is never used to index. The
    // function still returns 0 rather than panicking, because a helper that
    // can panic is a helper that will be called from the one place that
    // forgot the check.
    const empty: []const Option = &[_]Option{};
    try std.testing.expectEqual(@as(usize, 0), clampIndex(empty, 3));
}
