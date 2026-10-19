//! `ui.widgets.completion` — the autocomplete popup.
//!
//! ## Why this is generic and the editor's `complete.zig` is not enough
//!
//! `editor/lang/lua/complete.zig` answers "what could the user be typing here",
//! which needs the Lua API registry and the parse tree. This widget answers a
//! much smaller question: "draw this list, let the user move in it, tell me what
//! they picked". The two are deliberately separate, for the same module-boundary
//! reason as `code_view.zig`: `engine.ui` may not import `engine.editor`, so the
//! UI takes plain `Item`s and the editor tool maps its own suggestion type onto
//! them.
//!
//! ## Who owns the keyboard
//!
//! The CALLER. `selected` is a `*usize` the caller moves with Up/Down/PageUp/
//! PageDown; the widget only renders the highlight and reports a click. That is
//! not a cop-out — it is the only correct split in an immediate-mode UI where
//! the key events and the editing state already live in the editor tool, and it
//! means this widget has no key handling to test and no focus to steal from the
//! text field underneath.

const std = @import("std");
const cimgui = @import("../cimgui.zig");
const theme = @import("../theme.zig");
const draw = @import("../draw.zig");
const icons = @import("../icons.zig");
const Context = @import("../context.zig").Context;
const Rgba = cimgui.Rgba;
const Vec2 = cimgui.Vec2;
const Rect = cimgui.Rect;

/// What a suggestion is, for the leading glyph and the colour. A small set on
/// purpose: an icon per language construct is a legend nobody reads.
pub const Kind = enum {
    keyword,
    function_,
    variable,
    module,
    field,

    pub fn icon(self: Kind) icons.Icon {
        return switch (self) {
            .keyword => .gear,
            .function_ => .play,
            .variable => .dot_,
            .module => .folder,
            .field => .link,
        };
    }
};

pub const Item = struct {
    label: []const u8,
    /// Drawn right-aligned and dim: a signature, a type, a module name.
    detail: []const u8 = "",
    kind: Kind = .variable,
};

// ── Pure helpers ─────────────────────────────────────────────────────────

/// The slice of the list to draw, keeping `selected` in view. Returns the first
/// index and how many rows, so a 1000-suggestion list draws `max_rows` of them.
pub const Window = struct { first: usize, len: usize };

pub fn visibleWindow(count: usize, selected: usize, max_rows: usize) Window {
    if (count == 0 or max_rows == 0) return .{ .first = 0, .len = 0 };
    const rows = @min(max_rows, count);
    // Centre the selection until it would run off either end, then clamp — the
    // behaviour of every list the user has ever scrolled, and the reason the
    // highlight does not jump to the top on the first Up.
    const half = rows / 2;
    var first: usize = 0;
    first = if (selected > half) selected - half else 0;
    if (first + rows > count) first = count - rows;
    return .{ .first = first, .len = rows };
}

/// Moves `selected` by `delta`, wrapping at both ends. Wrapping (rather than
/// clamping) is what makes Down past the last item return to the first, which
/// is how a user gets back to the top of a long list without 200 keypresses.
pub fn step(selected: usize, count: usize, delta: i32) usize {
    if (count == 0) return 0;
    const n: i64 = @intCast(count);
    const s: i64 = @intCast(selected);
    var next = @mod(s + delta, n);
    if (next < 0) next += n;
    return @intCast(next);
}

// ── The popup ────────────────────────────────────────────────────────────

pub const Completion = struct {
    ctx: *Context,
    id: []const u8,
    items: []const Item,
    /// The highlighted row. The caller moves it; the widget never writes it
    /// except to keep it inside the list after the item set shrank.
    selected: *usize,
    /// Where the popup appears, in SCREEN coordinates — the caret's screen
    /// position, normally.
    anchor: Vec2,
    width: f32 = 280.0,
    row_height: f32 = 22.0,
    max_rows: usize = 8,
    /// A header line: "12 matches", a filter echo. Empty draws no header.
    header: []const u8 = "",
};

/// Draws the popup and returns the index the user clicked, or null. Every frame
/// the caller has suggestions, it calls this; the widget opens and closes its
/// own window, so there is no state to leak.
pub fn popup(c: Completion) ?usize {
    if (c.items.len == 0) return null;

    const t = &c.ctx.theme;
    const m = t.metrics;

    // The selection can point past a list that shrank under it (the user typed
    // one more character and half the matches vanished). Clamping here is the
    // widget's only write to `selected`, and it is the one that prevents an
    // out-of-bounds highlight.
    if (c.selected.* >= c.items.len) c.selected.* = c.items.len - 1;

    const win = visibleWindow(c.items.len, c.selected.*, c.max_rows);
    const header_h: f32 = if (c.header.len != 0) c.row_height else 0.0;
    const body_h: f32 = @as(f32, @floatFromInt(win.len)) * c.row_height;
    const h = header_h + body_h + m.gap() * 2.0;

    const flags: u32 = cimgui.WindowFlags.NoTitleBar |
        cimgui.WindowFlags.NoResize |
        cimgui.WindowFlags.NoCollapse |
        cimgui.WindowFlags.NoScrollbar |
        cimgui.WindowFlags.NoSavedSettings |
        cimgui.WindowFlags.NoFocusOnAppearing |
        cimgui.WindowFlags.NoNav |
        cimgui.WindowFlags.NoMove;

    cimgui.ember_ui_set_next_window_pos(c.anchor.x, c.anchor.y, @intFromEnum(cimgui.Cond.Always));
    cimgui.ember_ui_set_next_window_size(c.width, h, @intFromEnum(cimgui.Cond.Always));

    if (cimgui.ember_ui_begin(cimgui.text(c.id), @bitCast(flags)) == 0) {
        cimgui.ember_ui_end();
        return null;
    }
    defer cimgui.ember_ui_end();

    const origin = draw.cursorPos();
    const list = draw.List.item();
    // The window's own background is drawn by hand first, so the popup matches
    // the rest of the editor rather than ImGui's stock window chrome.
    const bg = draw.rect(origin.x, origin.y, origin.x + c.width, origin.y + h);
    list.shadow(bg, m.radius_md(), t.colors.shadow, 8.0);
    list.rect(bg, t.colors.overlay, m.radius_md());
    list.rectOutline(bg, t.colors.border_strong, m.radius_md(), 1.0);

    var accepted: ?usize = null;
    var y = origin.y + m.gap();

    if (c.header.len != 0) {
        list.text(
            .{ .x = origin.x + m.pad_x(), .y = y + (c.row_height - 16) * 0.5 },
            t.colors.text_faint,
            c.header,
        );
        y += c.row_height;
    }

    var i: usize = win.first;
    const end = win.first + win.len;
    while (i < end) : (i += 1) {
        const item = c.items[i];
        const sel = i == c.selected.*;
        draw.setCursorPos(.{ .x = origin.x + m.gap(), .y = y });
        _ = cimgui.ember_ui_invisible_button(cimgui.text("##row"), c.width - m.gap() * 2.0, c.row_height, 0);
        const hovered = cimgui.ember_ui_is_item_hovered(@bitCast(cimgui.HoveredFlags.None)) != 0;
        const r = draw.itemRect();

        if (sel or hovered) {
            list.rect(r, if (sel) t.colors.accent_soft else t.colors.surface_hi2, m.radius_sm());
        }
        var x = r.min.x + m.pad_x();
        icons.render(list, item.kind.icon(), .{ .x = x + 7, .y = r.min.y + c.row_height * 0.5 }, t.colors.text_dim, 14, 0);
        x += 20;
        list.text(
            .{ .x = x, .y = r.min.y + (c.row_height - 16) * 0.5 },
            if (sel) t.colors.text else t.colors.text_dim,
            item.label,
        );
        if (item.detail.len != 0) {
            const size = draw.textSize(item.detail);
            list.text(
                .{ .x = r.max.x - size.x - m.pad_x(), .y = r.min.y + (c.row_height - 16) * 0.5 },
                t.colors.text_faint,
                item.detail,
            );
        }
        if (hovered and cimgui.ember_ui_is_item_clicked(@intFromEnum(cimgui.MouseButton.Left)) != 0) {
            c.selected.* = i;
            accepted = i;
        }
        y += c.row_height;
    }
    return accepted;
}

// ── Tests ────────────────────────────────────────────────────────────────

const testing = std.testing;

test "ui completion: a short list shows entirely and does not scroll" {
    const w = visibleWindow(3, 1, 8);
    try testing.expectEqual(@as(usize, 0), w.first);
    try testing.expectEqual(@as(usize, 3), w.len);
}

test "ui completion: the selection stays inside the window at both ends" {
    // 100 items, 8 rows, selection at 0: the window starts at 0.
    const top = visibleWindow(100, 0, 8);
    try testing.expectEqual(@as(usize, 0), top.first);
    // At 50: centred, and the selection is inside [first, first+len).
    const mid = visibleWindow(100, 50, 8);
    try testing.expect(mid.first <= 50 and 50 < mid.first + mid.len);
    // At the last: the window is the final screenful, not past the end.
    const bot = visibleWindow(100, 99, 8);
    try testing.expectEqual(@as(usize, 92), bot.first);
    try testing.expect(bot.first + bot.len <= 100);
}

test "ui completion: an empty list has an empty window" {
    const w = visibleWindow(0, 0, 8);
    try testing.expectEqual(@as(usize, 0), w.len);
}

test "ui completion: stepping wraps at both ends" {
    // The property a user relies on: Down from the last row is the first row,
    // and Up from the first is the last. Wrapping, not clamping.
    try testing.expectEqual(@as(usize, 0), step(4, 5, 1));
    try testing.expectEqual(@as(usize, 4), step(0, 5, -1));
    try testing.expectEqual(@as(usize, 2), step(1, 5, 1));
    // An empty list never indexes: it stays at 0.
    try testing.expectEqual(@as(usize, 0), step(3, 0, 1));
}
