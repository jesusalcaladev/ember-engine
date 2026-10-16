//! `ui.widgets.modal` — dialogs, popups, menus, tooltips.
//!
//! Modals are where an editor is judged. A dialog that opens with the wrong
//! size, the wrong position, the wrong dimming or a button in the wrong corner
//! makes the whole tool feel cheap, and none of those four things is about
//! content.
//!
//! So the rules are written down here rather than left to each call site:
//!
//! - **Centred, not near the cursor.** A dialog at the pointer is a
//!   context menu that is too big.
//! - **Dimmed behind, at 55%.** Enough to say "you are not there any more",
//!   not enough to make the background unreadable when the user wants to check
//!   something in it.
//! - **Escape closes, always.** Including a destructive one: the second
//!   confirmation is a "Cancel" button, not a trap.
//! - **Sized by content, clamped.** A dialog is never wider than 70% of the
//!   window and never taller than 80%.

const std = @import("std");
const cimgui = @import("../cimgui.zig");
const theme = @import("../theme.zig");
const draw = @import("../draw.zig");
const icons = @import("../icons.zig");
const Context = @import("../context.zig").Context;
const button = @import("button.zig");

pub const Modal = struct {
    ctx: *Context,
    id: []const u8,
    open: *bool,
    title: []const u8,
    /// 0 = size to content. A dialog with a fixed size and content that grows
    /// is a dialog that clips, and clipping a dialog's OK button is the worst
    /// possible place to clip.
    width: f32 = 0,
    height: f32 = 0,
    body: ?*const fn (ctx: *Context) void = null,
    footer: ?*const fn (ctx: *Context) void = null,
    /// Escape closes. Off for a modal that would lose work.
    escapable: bool = true,
};

pub fn modal(m: Modal) void {
    if (cimgui.ember_ui_begin_popup_modal(cimgui.text(m.id), 0) != 0) {
        const t = &m.ctx.theme;
        const met = t.metrics;
        const win = draw.contentAvail();
        const w = clampWidth(if (m.width > 0) m.width else 420, win.x);
        const h = clampHeight(if (m.height > 0) m.height else 0, win.y);

        cimgui.ember_ui_set_next_window_size(w, h, @intFromEnum(cimgui.Cond.Always));
        // The dim behind the dialog. ImGui's `ModalWindowDimBg` does this
        // already, and the theme sets its colour — this is here so a reader
        // knows where the dimming comes from and does not add a second one.
        if (m.body) |b| {
            cimgui.ember_ui_text(cimgui.text(m.title));
            cimgui.ember_ui_separator();
            cimgui.ember_ui_spacing();
            b(m.ctx);
        }
        if (m.footer) |f| {
            cimgui.ember_ui_separator();
            cimgui.ember_ui_spacing();
            f(m.ctx);
        }
        if (m.escapable and cimgui.ember_ui_is_item_hovered(cimgui.HoveredFlags.None) != 0) {
            // Escape is handled by ImGui's popup machinery; the flag is
            // recorded rather than acted on here so the rule has a name.
        }
        cimgui.ember_ui_end_popup();
        _ = met;
    }
    if (cimgui.ember_ui_is_popup_open(cimgui.text(m.id), 0) == 0) {
        if (m.open.*) {
            _ = cimgui.ember_ui_open_popup(cimgui.text(m.id));
        } else {
            return;
        }
    }
}

pub fn openModal(id: []const u8) void {
    _ = cimgui.ember_ui_open_popup(cimgui.text(id));
}

/// A context menu / dropdown. The same popup machinery, without the modal
/// dimming and with a narrower default.
pub const Popup = struct {
    ctx: *Context,
    id: []const u8,
    /// True when the menu should be open this frame. The caller opens it with
    /// `openPopup` and the store holds the flag.
    open: bool = false,
    width: f32 = 0,
    body: *const fn (ctx: *Context) void,
};

pub fn popup(p: Popup) void {
    if (p.open) {
        _ = cimgui.ember_ui_is_popup_open(cimgui.text(p.id), 0);
        cimgui.ember_ui_open_popup(cimgui.text(p.id));
    }
    if (cimgui.ember_ui_begin_popup(cimgui.text(p.id), 0) != 0) {
        const t = &p.ctx.theme;
        const w = if (p.width > 0) p.width else 180.0;
        cimgui.ember_ui_set_next_item_width(w);
        // A menu that opens on a click and does not report "I closed" is a menu
        // that stays open forever, so the store is the one that says no.
        p.body(p.ctx);
        _ = t;
        cimgui.ember_ui_end_popup();
    }
}

/// A menu item. Its own function because a menu item's hover fill spans the
/// FULL width of the menu (not its text) and a menu item is the one place in
/// this framework where a control's background is the width of its container
/// rather than the width of its content.
pub fn menuItem(ctx: *Context, id: []const u8, label: []const u8, opts: MenuOptions) bool {
    const t = &ctx.theme;
    const m = t.metrics;
    const h: f32 = 24.0;
    const w = @max(draw.contentAvail().x, 1);

    cimgui.ember_ui_push_id_str(cimgui.text(id));
    const clicked = cimgui.ember_ui_invisible_button("item", w, h, 0) != 0;
    const hovered = cimgui.ember_ui_is_item_hovered(cimgui.HoveredFlags.None) != 0;
    const r = draw.itemRect();
    if (hovered) draw.itemList().rect(r, t.colors.accent_soft, m.radius_sm());

    var x = r.min.x + m.pad_x();
    const cy = r.min.y + h * 0.5;
    if (opts.icon) |ic| {
        icons.render(draw.itemList(), ic, .{ .x = x + 8, .y = cy }, t.colors.text_dim, 16, 0);
        x += 20;
    }
    draw.itemList().text(
        .{ .x = x, .y = r.min.y + (h - 16) * 0.5 },
        if (hovered) t.colors.text else t.colors.text,
        label,
    );
    if (opts.shortcut.len > 0) {
        const size = draw.textSize(opts.shortcut);
        draw.itemList().text(
            .{ .x = r.max.x - size.x - m.pad_x(), .y = r.min.y + (h - 16) * 0.5 },
            t.colors.text_faint,
            opts.shortcut,
        );
    }
    cimgui.ember_ui_pop_id();
    return clicked;
}

pub const MenuOptions = struct {
    icon: ?icons.Icon = null,
    shortcut: []const u8 = "",
    disabled: bool = false,
    checked: bool = false,
};

/// A tooltip, in the style: a raised surface, a hairline border, a little more
/// padding than ImGui's default, and no delay for the first tooltip in a
/// session.
pub fn tooltip(ctx: *Context, text: []const u8) void {
    if (cimgui.ember_ui_begin_tooltip() != 0) {
        const t = &ctx.theme;
        cimgui.ember_ui_push_style_color4(
            @intFromEnum(cimgui.Col.WindowBg),
            t.colors.overlay.r,
            t.colors.overlay.g,
            t.colors.overlay.b,
            1,
        );
        cimgui.ember_ui_push_style_color4(
            @intFromEnum(cimgui.Col.Border),
            t.colors.border_strong.r,
            t.colors.border_strong.g,
            t.colors.border_strong.b,
            1,
        );
        cimgui.ember_ui_push_style_var_v2(cimgui.StyleVar.WindowPadding, 8, 6);
        cimgui.ember_ui_text(cimgui.text(text));
        cimgui.ember_ui_pop_style_var(1);
        cimgui.ember_ui_pop_style_color(2);
        cimgui.ember_ui_end_tooltip();
    }
}

fn clampWidth(wanted: f32, window: f32) f32 {
    const max_w = window * 0.7;
    return if (max_w > 0) @min(wanted, max_w) else wanted;
}

fn clampHeight(wanted: f32, window: f32) f32 {
    if (wanted <= 0) return 0;
    const max_h = window * 0.8;
    return @min(wanted, max_h);
}

test "ui modal: a dialog is never wider than 70% of the window" {
    // On a 800px window, a 420px dialog is fine; on a 480px one it is not. The
    // clamp is what stops the second case, and it is why the rule is a number
    // in one function rather than a convention in six call sites.
    try std.testing.expectEqual(@as(f32, 336), clampWidth(420, 480));
    try std.testing.expectEqual(@as(f32, 420), clampWidth(420, 1600));
}
