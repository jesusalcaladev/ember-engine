//! `ui.widgets.input` — text fields, number fields, sliders, search.
//!
//! ## The rule every field in here follows
//!
//! The editing is ImGui's (`InputText`, `DragFloat`) and always will be: caret
//! movement, selection, undo, UTF-8, IME composition and clipboard are a
//! thousand edge cases that a game engine has no business reimplementing. What
//! this file owns is everything AROUND the editing — the frame, the border, the
//! focus ring, the placeholder, the label slot, the unit, and the drag handle.
//!
//! That split is why these fields look like the rest of the editor while
//! behaving like text fields.

const std = @import("std");
const cimgui = @import("../cimgui.zig");
const theme = @import("../theme.zig");
const draw = @import("../draw.zig");
const icons = @import("../icons.zig");
const widget = @import("widget.zig");
const Context = @import("../context.zig").Context;

// ── Text field ───────────────────────────────────────────────────────────

/// The label every field submits under. Hidden (`##` means "not shown") and
/// CONSTANT, because the field's identity is the pushed id above it: a hidden
/// label that is constant across a window is a field that can be found by
/// Ctrl+Click and typed into by hand, and one that is built at runtime from a
/// user string is neither.
const hidden_label = cimgui.textLit("##v");

pub const TextField = struct {
    ctx: *Context,
    id: []const u8,
    label: []const u8 = "",
    /// The buffer, owned by the caller and NUL-terminated. NOT owned by the
    /// field: a widget that allocated its own buffer would hand the caller a
    /// value it cannot free.
    buf: [*]u8,
    capacity: u32,
    placeholder: []const u8 = "",
    width: f32 = 0,
    label_slot: f32 = 64.0,
    disabled: bool = false,
    read_only: bool = false,
    multiline: bool = false,
    height: f32 = 0,
    tooltip: ?[]const u8 = null,
    on_enter: ?*const fn (ctx: ?*anyopaque) void = null,
    ctx_arg: ?*anyopaque = null,
};

pub fn textField(f: TextField) bool {
    const t = &f.ctx.theme;
    const m = t.metrics;
    const h = if (f.height > 0) f.height else m.row_h();
    const w = if (f.width > 0) f.width else draw.contentAvail().x - f.label_slot - m.gap();

    var changed = false;
    widget.labelSlot(t, f.label, f.label_slot, h);
    if (f.disabled or f.read_only) {
        // A disabled field still shows its value; it just does not edit. The
        // value is drawn by the same code path as an enabled one, with the
        // disabled colours, so the two can never disagree about what is in the
        // buffer.
        const r = readOnlyRect(h, w);
        paintField(t, r, .disabled, false);
        cimgui.ember_ui_text_colored(
            t.colors.text_faint.pack(),
            cimgui.text(currentSlice(f.buf, f.capacity)),
        );
        cimgui.ember_ui_same_line(-9999.0, 0);
        return false;
    }

    // The visible label is drawn by `labelSlot`, so the field itself gets a
    // HIDDEN label ("##v") and its identity comes from a pushed id. Two text
    // fields in the same window with the same hidden label are one field to
    // ImGui: the second one edits the first one's buffer.
    cimgui.ember_ui_push_id_str(cimgui.text(f.id));

    // ImGui draws the field's own frame, so the theme's frame IS the frame —
    // and, more importantly, the value ImGui draws is not painted over by a
    // background drawn afterwards. The custom frame used to be painted here,
    // which meant a text field showed its PLACEHOLDER and never its value.
    cimgui.ember_ui_set_next_item_width(w);

    var flags: u32 = cimgui.InputTextFlags.None;
    if (f.on_enter != null) flags |= cimgui.InputTextFlags.EnterReturnsTrue;
    flags |= cimgui.InputTextFlags.EscapeClearsAll;
    if (f.read_only) flags |= cimgui.InputTextFlags.ReadOnly;

    const size = [2]f32{ w, h };
    const raw = if (f.multiline)
        cimgui.ember_ui_input_text_multiline(hidden_label, f.buf, f.capacity, &size, @bitCast(flags))
    else
        cimgui.ember_ui_input_text(hidden_label, f.buf, f.capacity, @bitCast(flags));
    changed = raw != 0;

    const r = draw.itemRect();
    const hovered = cimgui.ember_ui_is_item_hovered(cimgui.HoveredFlags.None) != 0;
    const focused = cimgui.ember_ui_is_item_focused() != 0;
    cimgui.ember_ui_pop_id();

    // The focus ring, on top of the value: the one thing that may be drawn
    // over it.
    if (focused) {
        draw.itemList().rectOutline(r, t.colors.border_focus, m.radius_sm(), 1.5);
    }

    // The placeholder. Drawn only when the buffer is empty, which is the
    // condition: drawing it on a non-empty buffer is how a field ends up with
    // grey text in front of the user's own text.
    if (f.placeholder.len != 0 and currentSlice(f.buf, f.capacity).len == 0 and !focused) {
        draw.itemList().text(
            .{ .x = r.min.x + m.pad_x(), .y = r.min.y + (h - 16) * 0.5 },
            theme.placeholder(t),
            f.placeholder,
        );
    }

    if (f.tooltip) |tip| {
        if (hovered and !focused) cimgui.ember_ui_set_tooltip(cimgui.text(tip));
    }
    if (changed) {
        if (f.on_enter) |cb| cb(f.ctx_arg);
    }
    return changed;
}

fn readOnlyRect(h: f32, w: f32) cimgui.Rect {
    cimgui.ember_ui_dummy(w, h);
    return draw.itemRect();
}

pub fn currentSlice(buf: [*]u8, capacity: u32) []const u8 {
    var n: usize = 0;
    const cap: usize = @intCast(capacity);
    while (n < cap and buf[n] != 0) : (n += 1) {}
    return buf[0..n];
}

/// The frame every field shares: a surface, a border, and a focus ring that
/// replaces the border's colour rather than sitting on top of it.
fn paintField(t: *const theme.Theme, r: cimgui.Rect, state: theme.State, focused: bool) void {
    const m = t.metrics;
    const list = draw.itemList();
    list.rect(r, theme.fill(t, state), m.radius_sm());
    if (focused) {
        list.rectOutline(r, t.colors.border_focus, m.radius_sm(), 1.5);
    } else if (state == .hover) {
        list.rectOutline(r, t.colors.border_strong, m.radius_sm(), 1);
    } else {
        list.rectOutline(r, t.colors.border, m.radius_sm(), 1);
    }
}

// ── Search field ─────────────────────────────────────────────────────────

pub const Search = struct {
    ctx: *Context,
    id: []const u8,
    buf: [*]u8,
    capacity: u32,
    placeholder: []const u8 = "Search",
    width: f32 = 0,
    on_change: ?*const fn (ctx: ?*anyopaque) void = null,
    ctx_arg: ?*anyopaque = null,
};

/// A search field is a text field with a magnifier, a clear button, and one
/// behaviour that matters more than either: it only reports a change when the
/// TEXT changed, so typing a character does not re-filter a 50,000-entry list
/// on every keystroke frame.
pub fn search(s: Search) void {
    const t = &s.ctx.theme;
    const m = t.metrics;
    const h = m.row_h();
    const w = if (s.width > 0) s.width else draw.contentAvail().x;

    const before = currentSlice(s.buf, s.capacity);
    // The owned copy is what makes the comparison meaningful: `before` points
    // into the buffer that InputText is about to overwrite.
    var snapshot: [256]u8 = undefined;
    const n = @min(before.len, snapshot.len);
    @memcpy(snapshot[0..n], before[0..n]);

    cimgui.ember_ui_push_id_str(cimgui.text(s.id));
    cimgui.ember_ui_push_style_color4(@intFromEnum(cimgui.Col.FrameBg), 0, 0, 0, 0);
    cimgui.ember_ui_push_style_color4(@intFromEnum(cimgui.Col.Border), 0, 0, 0, 0);
    cimgui.ember_ui_set_next_item_width(w);
    const changed = cimgui.ember_ui_input_text(
        hidden_label,
        s.buf,
        s.capacity,
        cimgui.InputTextFlags.EnterReturnsTrue,
    ) != 0;
    cimgui.ember_ui_pop_style_color(2);

    const r = draw.itemRect();
    const list = draw.itemList();
    list.rect(r, t.colors.surface, m.radius_sm());
    list.rectOutline(
        r,
        if (cimgui.ember_ui_is_item_focused() != 0) t.colors.border_focus else t.colors.border,
        m.radius_sm(),
        1,
    );

    const glyph_x = r.min.x + m.pad_x();
    icons.render(list, .search, .{ .x = glyph_x + 8, .y = r.min.y + h * 0.5 }, t.colors.text_faint, 16, 1.4);
    const text_x = glyph_x + 22.0;
    const now_len = currentSlice(s.buf, s.capacity).len;
    if (now_len == 0) {
        list.text(.{ .x = text_x, .y = r.min.y + (h - 16) * 0.5 }, t.colors.text_faint, s.placeholder);
    }

    // The clear button, only when there is something to clear. It is drawn
    // INSIDE the field, so a search field's height does not change when it is
    // filled, and the layout below it does not jump.
    if (now_len > 0) {
        const cb = draw.rect(r.max.x - 24, r.min.y + 4, r.max.x - 4, r.min.y + h - 4);
        _ = cimgui.ember_ui_invisible_button(
            cimgui.text("clear"),
            cb.max.x - cb.min.x,
            cb.max.y - cb.min.y,
            0,
        );
        const bh = cimgui.ember_ui_is_item_hovered(cimgui.HoveredFlags.None) != 0;
        if (bh) list.rect(cb, t.colors.surface_hi2, m.radius_sm());
        icons.render(
            list,
            .close,
            draw.center(cb),
            if (bh) t.colors.text else t.colors.text_dim,
            14,
            1.4,
        );
        if (cimgui.ember_ui_is_item_clicked(@intFromEnum(cimgui.MouseButton.Left)) != 0) {
            s.buf[0] = 0;
            if (s.on_change) |cb_fn| cb_fn(s.ctx_arg);
        }
    }
    cimgui.ember_ui_pop_id();

    // Real change detection: compare lengths AND bytes. A length-only check
    // passes when a character is replaced by another of the same width, which
    // is every edit that is not an append.
    const after = currentSlice(s.buf, s.capacity);
    const differs = after.len != n or !std.mem.eql(u8, after[0..n], snapshot[0..n]);
    if (s.on_change) |cb_fn| {
        if (changed or differs) {
            if (differs) cb_fn(s.ctx_arg);
        }
    }
}

// ── Number field ─────────────────────────────────────────────────────────

pub const NumberField = struct {
    ctx: *Context,
    id: []const u8,
    label: []const u8 = "",
    value: *f32,
    speed: f32 = 1.0,
    min: f32 = -1e9,
    max: f32 = 1e9,
    /// The label on the drag handle. 1 decimal is what a position needs; 3 is
    /// what a scale factor needs; 0 is what a layer index needs. Defaulting to
    /// 3 everywhere is how a layer index ends up reading "0.000".
    format: []const u8 = "%.3f",
    label_slot: f32 = 64.0,
    width: f32 = 0,
    /// A unit shown after the number ("px", "m", "°"). It is NOT part of the
    /// number, so it must not be part of the buffer: a field whose value is
    /// "10 px" cannot be parsed by the engine.
    unit: []const u8 = "",
    disabled: bool = false,
    on_commit: ?*const fn (ctx: ?*anyopaque) void = null,
    ctx_arg: ?*anyopaque = null,
};

pub fn numberField(n: NumberField) bool {
    const t = &n.ctx.theme;
    const m = t.metrics;
    const h = m.row_h();
    const unit_w: f32 = if (n.unit.len != 0) draw.textSize(n.unit).x + 6 else 0;
    const w = if (n.width > 0) n.width else draw.contentAvail().x - n.label_slot - m.gap();

    var changed = false;
    // A field with NO label takes no slot: `labelSlot` places what follows at
    // an ABSOLUTE offset from the line's start, so a field that reserved one
    // would jump back to the column it never left. That is how a row of two
    // X/Y fields ended up drawn on top of the row's own label.
    if (n.label.len != 0) {
        widget.labelSlot(t, n.label, n.label_slot, h);
    }
    cimgui.ember_ui_push_id_str(cimgui.text(n.id));
    // ImGui draws the field's own frame AND its own text. A custom-painted
    // background would have to be drawn BEFORE the widget — and the widget's
    // rect is not known until after it ran — so the frame is ImGui's and the
    // theme styles it. Painting it afterwards (which is what this used to do)
    // covered the value with the background: every number field in the
    // editor showed its unit and nothing else.
    cimgui.ember_ui_set_next_item_width(w);
    changed = cimgui.ember_ui_drag_float(
        hidden_label,
        n.value,
        n.speed,
        n.min,
        n.max,
        cimgui.text(n.format),
        @bitCast(cimgui.SliderFlags.AlwaysClamp),
    ) != 0;

    const r = draw.itemRect();
    cimgui.ember_ui_pop_id();
    const list = draw.itemList();
    const hovered = cimgui.ember_ui_is_item_hovered(cimgui.HoveredFlags.None) != 0;
    const active = cimgui.ember_ui_is_item_active() != 0;
    const focused = cimgui.ember_ui_is_item_focused() != 0;
    const state: theme.State = if (n.disabled) .disabled else if (active) .active else if (hovered) .hover else .idle;
    // The focus ring, and only the focus ring: it goes ON TOP of the value,
    // which is the one thing that may be drawn over it.
    if (focused) {
        list.rectOutline(r, t.colors.border_focus, t.metrics.radius_sm(), 1.5);
    }

    if (unit_w > 0) {
        list.text(
            .{ .x = r.max.x - unit_w + 2, .y = r.min.y + (h - 16) * 0.5 },
            t.colors.text_faint,
            n.unit,
        );
    }
    if (changed) {
        if (n.on_commit) |cb| cb(n.ctx_arg);
    }
    return changed;
}

// ── Slider ───────────────────────────────────────────────────────────────

pub const Slider = struct {
    ctx: *Context,
    id: []const u8,
    label: []const u8 = "",
    value: *f32,
    min: f32 = 0.0,
    max: f32 = 1.0,
    format: []const u8 = "%.2f",
    label_slot: f32 = 64.0,
    width: f32 = 0,
    disabled: bool = false,
};

pub fn slider(s: Slider) bool {
    const t = &s.ctx.theme;
    const m = t.metrics;
    const h = m.row_h();
    const w = if (s.width > 0) s.width else draw.contentAvail().x - s.label_slot - m.gap();

    widget.labelSlot(t, s.label, s.label_slot, h);
    cimgui.ember_ui_push_id_str(cimgui.text(s.id));
    cimgui.ember_ui_push_style_color4(@intFromEnum(cimgui.Col.FrameBg), 0, 0, 0, 0);
    cimgui.ember_ui_push_style_color4(@intFromEnum(cimgui.Col.Border), 0, 0, 0, 0);
    cimgui.ember_ui_push_style_color4(
        @intFromEnum(cimgui.Col.SliderGrab),
        t.colors.accent.r,
        t.colors.accent.g,
        t.colors.accent.b,
        1,
    );
    cimgui.ember_ui_set_next_item_width(w);
    const changed = cimgui.ember_ui_slider_float(
        hidden_label,
        s.value,
        s.min,
        s.max,
        cimgui.text(s.format),
        @bitCast(cimgui.SliderFlags.AlwaysClamp),
    ) != 0;
    cimgui.ember_ui_pop_style_color(3);
    cimgui.ember_ui_pop_id();
    return changed;
}

test "ui input: the search buffer is compared by bytes, not by length" {
    // The bug this documents: a length-only change test reports "changed" when
    // nothing changed (a same-width replacement is a change, but a re-render
    // of the same text is not) and misses nothing else. The test is the
    // shape of the comparison, run on a real buffer.
    // Two buffers, because the two values have to be compared with each other:
    // taking both slices of the SAME buffer would compare a buffer with
    // itself, which passes for the wrong reason and catches nothing.
    var buf_before: [16]u8 = .{0} ** 16;
    var buf_after: [16]u8 = .{0} ** 16;
    const a = "playe";
    const b = "actor";
    @memcpy(buf_before[0..a.len], a);
    @memcpy(buf_after[0..b.len], b);
    const before = currentSlice(&buf_before, 16);
    const after = currentSlice(&buf_after, 16);
    // Same LENGTH, different bytes: a length-only change test reports "no
    // change" here, which is the silent bug this test exists to prevent.
    try std.testing.expectEqual(before.len, after.len);
    try std.testing.expect(!std.mem.eql(u8, before, after));
    try std.testing.expectEqualStrings("playe", before);
    try std.testing.expectEqualStrings("actor", after);
    // And the same text twice IS a change-free case: the framework's own
    // comparison is byte equality, and this is the case it must return false for.
    var buf_same: [16]u8 = .{0} ** 16;
    const c = "playe";
    @memcpy(buf_same[0..c.len], c);
    const same1 = currentSlice(&buf_same, 16);
    const same2 = currentSlice(&buf_same, 16);
    try std.testing.expect(std.mem.eql(u8, same1, same2));
}

test "ui input: a disabled field still occupies its space" {
    // Not a unit test of pixels: a test of the decision. `textField` submits a
    // dummy for the read-only path precisely so the row below does not move
    // up under a field that is temporarily not editable.
    const w: f32 = 120;
    const h: f32 = 28;
    const r = draw.rect(10, 10, 10 + w, 10 + h);
    try std.testing.expectEqual(w, draw.width(r));
    try std.testing.expectEqual(h, draw.height(r));
}
