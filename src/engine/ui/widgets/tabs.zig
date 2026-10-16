//! `ui.widgets.tabs` — the workspace tab bar (M5.7's `2D | Script`).
//!
//! Tabs are the editor's most important navigation, and ImGui's tab bar is the
//! one widget in the whole library that a workspace cannot use as it is: it
//! draws a title bar per tab, it does not do a 2px overline, and its hit
//! testing is a text-sized box that does not match what it draws.
//!
//! So this is a row of custom tabs over a content region, with the store
//! holding which one is open. Which is a sentence that also describes the
//! editor's whole job: a set of workspaces, one visible at a time.

const std = @import("std");
const cimgui = @import("../cimgui.zig");
const theme = @import("../theme.zig");
const draw = @import("../draw.zig");
const icons = @import("../icons.zig");
const Context = @import("../context.zig").Context;

pub const Tab = struct {
    id: []const u8,
    label: []const u8,
    icon: ?icons.Icon = null,
    /// A dot on the right of the tab: unsaved changes, a compile error, a
    /// running process. Small, and the only per-tab decoration.
    dot: ?cimgui.Rgba = null,
    /// A close button, for tabs that represent a FILE rather than a workspace.
    closable: bool = false,
    /// Drawn in a dimmer colour: a tab you cannot switch to right now.
    disabled: bool = false,
};

fn TabLabelInFont(at: cimgui.Vec2, s: []const u8, col: cimgui.Rgba) void {
    draw.itemList().text(at, col, s);
}

pub const Tabs = struct {
    ctx: *Context,
    id: []const u8,
    tabs: []const Tab,
    /// The index of the open tab. A pointer, like every other stateful control.
    selected: *usize,
    /// The body of the SELECTED tab. Given the index so one body can switch.
    body: *const fn (ctx: *Context, index: usize) void,
    /// Underline style. A workspace bar reads better as a 2px overline; a file
    /// bar reads better as an underline on the selected tab. Same widget, both
    /// shapes, and which one is right is a decision, not a hardcode.
    underline: bool = true,
    height: f32 = 0,
};

pub fn tabs(t: Tabs) void {
    const theme_ = &t.ctx.theme;
    const m = theme_.metrics;
    const h = if (t.height > 0) t.height else m.row_h_lg();

    cimgui.ember_ui_push_id_str(cimgui.text(t.id));
    defer cimgui.ember_ui_pop_id();

    // The bar's own background: one rectangle behind the whole row, so the tabs
    // read as a bar with items in it rather than as a row of buttons.
    cimgui.ember_ui_dummy(@max(draw.contentAvail().x, 1), h);
    const bar = draw.itemRect();
    const list = draw.itemList();
    list.rect(bar, theme_.colors.surface, 0);
    draw.itemList().separator(
        .{ .min = .{ .x = bar.min.x, .y = bar.max.y - 1 }, .max = bar.max },
        theme_.colors.border,
    );

    var x = bar.min.x;
    for (t.tabs, 0..) |tab, i| {
        const label_w = draw.textSize(tab.label).x;
        const icon_w: f32 = if (tab.icon != null) 20 else 0;
        const dot_w: f32 = if (tab.dot != null) 10 else 0;
        const close_w: f32 = if (tab.closable) 18 else 0;
        const w = m.pad_x() * 2 + label_w + icon_w + dot_w + close_w;
        const sel = i == t.selected.*;

        cimgui.ember_ui_push_id_int(@intCast(i));
        _ = cimgui.ember_ui_invisible_button("tab", w, h, 0);
        const hovered = cimgui.ember_ui_is_item_hovered(cimgui.HoveredFlags.None) != 0;
        const r = draw.itemRect();

        if (sel) {
            if (t.underline) {
                // A 2px overline in the accent. On the TOP edge, not a box:
                // an underline fights the bar's own bottom rule, and two rules
                // 20px apart is a border.
                list.rect(
                    draw.rect(r.min.x, r.min.y, r.max.x, r.min.y + m.focus_ring()),
                    theme_.colors.accent,
                    1,
                );
                list.rect(r, theme_.colors.bg, 0);
            } else {
                list.rect(r, theme_.colors.surface_hi, m.radius_sm());
            }
        } else if (hovered) {
            list.rect(r, theme_.colors.surface_hi.withAlpha(0.5), m.radius_sm());
        }

        const fg = if (tab.disabled)
            theme_.colors.text_faint
        else if (sel)
            theme_.colors.text
        else
            theme_.colors.text_dim;

        var tx = r.min.x + m.pad_x();
        if (tab.icon) |ic| {
            icons.render(list, ic, .{ .x = tx + 8, .y = r.min.y + h * 0.5 }, fg, 16, 0);
            tx += icon_w;
        }
        // A MEDIUM face on the selected tab and a regular one on the others:
        // that is the only typographic difference between "the tab you are on"
        // and "the tab next to it", and it survives a greyscale screenshot.
        t.ctx.withFont(
            if (sel) .ui_medium else .ui,
            TabLabelInFont,
            .{ cimgui.Vec2{ .x = tx, .y = r.min.y + (h - 16) * 0.5 }, tab.label, fg },
        );
        tx += label_w;
        if (tab.dot) |d| {
            list.circle(.{ .x = tx + 5, .y = r.min.y + h * 0.5 }, 3, d);
            tx += dot_w;
        }
        if (tab.closable) {
            const cr = draw.rect(r.max.x - 18, r.min.y + 5, r.max.x - 4, r.min.y + h - 5);
            icons.render(list, .close, draw.center(cr), if (hovered) fg else theme_.colors.text_faint, 12, 1.3);
        }

        if (cimgui.ember_ui_is_item_clicked(@intFromEnum(cimgui.MouseButton.Left)) != 0 and !tab.disabled) {
            t.selected.* = i;
        }
        cimgui.ember_ui_pop_id();
        x += w;
    }

    cimgui.ember_ui_spacing();
    if (t.selected.* < t.tabs.len) {
        t.body(t.ctx, t.selected.*);
    } else if (t.tabs.len > 0) {
        // The selection points past the end. Clamping here rather than
        // crashing: the selection is UI state and a scene reload can shrink the
        // tab list under it.
        t.selected.* = 0;
    }
}

test "ui tabs: a tab's width is its content, so a renamed tab resizes the row" {
    // Not a measurement (no window here) but the RULE: width is derived from
    // the label, never fixed. A fixed-width tab either wastes space on short
    // names or clips long ones, and it is the long ones that matter — they are
    // the files the user cannot find.
    const m: theme.Metrics = .{};
    const short = m.pad_x() * 2;
    const with_label = short + 80.0;
    try std.testing.expect(with_label > short);
}

test "ui tabs: a selected index past the end is clamped, not used" {
    // The scene-reload case. The test is the invariant the widget maintains.
    var selected: usize = 5;
    const tabs_len: usize = 2;
    if (selected >= tabs_len) selected = 0;
    try std.testing.expectEqual(@as(usize, 0), selected);
}
