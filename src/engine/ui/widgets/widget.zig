//! `ui.widgets.widget` — the three things every custom widget needs first.
//!
//! Submitting an item, finding out what state it is in, and drawing it. A
//! widget that reinvents any of these three is where the framework starts to
//! fork, so they live here and the widgets are what is left over.

const std = @import("std");
const cimgui = @import("../cimgui.zig");
const theme = @import("../theme.zig");
const draw = @import("../draw.zig");
const Rect = cimgui.Rect;

/// What a control is doing RIGHT NOW, which is the only input its drawing
/// needs. Four states, no more: "disabled because the mouse is already
/// dragging something else" is a state ImGui has and a design does not, and
/// collapsing it is why a custom widget can be four cases instead of twenty.
pub const State = theme.State;

/// The result of submitting a control: the rect, the state, and whether it was
/// activated. One struct, because a widget that forgets to ask for one of the
/// three is a widget with a bug that only appears on hover, or only on click,
/// or only at one DPI.
pub const Hit = struct {
    rect: Rect = .{},
    state: State = .idle,
    /// The click edge. ImGui's `IsItemClicked` is NOT the same as "a button
    /// fired", which is why this comes from the button call itself.
    clicked: bool = false,
    hovered: bool = false,
    active: bool = false,
    focused: bool = false,
};

/// Submits an invisible item of the given size at the cursor and reports its
/// state. The id must be STABLE across frames — a label, or a path — because
/// ImGui uses it to remember hover/active/focus between frames, and an id that
/// changes every frame is a control that can never be held down.
pub fn submit(id: [*:0]const u8, w: f32, h: f32, disabled: bool) Hit {
    // A DISABLED control is still submitted, always. It still occupies space,
    // still has a rect, and still needs one: returning early is how a row of
    // five buttons ends up with three of them on top of each other. What
    // "disabled" changes is that the answers below ignore the mouse.
    _ = cimgui.ember_ui_invisible_button(id, w, h, 0);
    const hovered = !disabled and cimgui.ember_ui_is_item_hovered(cimgui.HoveredFlags.None) != 0;
    const active = !disabled and cimgui.ember_ui_is_item_active() != 0;
    const focused = cimgui.ember_ui_is_item_focused() != 0;
    return .{
        .rect = draw.itemRect(),
        .state = if (disabled) .disabled else if (active) .active else if (hovered) .hover else .idle,
        .clicked = if (disabled) false else cimgui.ember_ui_is_item_clicked(@intFromEnum(cimgui.MouseButton.Left)) != 0,
        .hovered = hovered,
        .active = active,
        .focused = focused,
    };
}

/// Submits an item that fills the remaining width.
pub fn submitFull(id: [*:0]const u8, h: f32, disabled: bool) Hit {
    const avail = draw.contentAvail();
    return submit(id, @max(avail.x, 1), h, disabled);
}

/// Reserves horizontal space without drawing or interacting, for a row that
/// wants the button on the right.
pub fn spacer(w: f32, h: f32) void {
    cimgui.ember_ui_dummy(w, h);
}

/// A label that occupies a FIXED-WIDE slot, so a column of fields lines up
/// whether or not their labels are the same length.
///
/// The fixed width is the whole point. Text of whatever length followed by
/// `SetCursorPosX` would left-align the fields, and a settings panel whose
/// inputs are ragged is a settings panel nobody believes was designed.
///
/// A label longer than the slot is DRAWN at the slot and clipped by ImGui's
/// text width — the alternative, widening the slot per label, is the raggedness
/// coming back through the other door.
pub fn labelSlot(t: *const theme.Theme, label: []const u8, slot_w: f32, h: f32) void {
    if (label.len != 0) {
        cimgui.ember_ui_text_colored(t.colors.text_dim.pack(), cimgui.text(label));
    } else {
        // An EMPTY label still reserves its slot. A row with a blank label and
        // a row with "Opacity:" are both real, and a column that only lines up
        // when every label is present is not a column.
        cimgui.ember_ui_dummy(slot_w * 0.5, h);
    }
    // `SameLine(slot_w)` places whatever comes next at exactly
    // (this item's left edge + slot_w), whatever the label was. That one call
    // is the entire column alignment.
    cimgui.ember_ui_same_line(slot_w, t.metrics.gap());
}

/// A label in a fixed-width slot, RELATIVE to where the cursor is.
///
/// `labelSlot` is absolute: it places what follows at `slot_w` from the LINE's
/// start, which is what a table wants and what a row inside a row cannot use.
/// The second label of a row (the "X" of an X/Y pair) would jump back to the
/// column it never left — and, in the inspector, land on top of the row's own
/// label.
///
/// The slot is still FIXED, so the things after it line up: the label is
/// padded to the slot's width, and what follows starts at the same x every
/// time.
pub fn labelSlotRelative(t: *const theme.Theme, label: []const u8, slot_w: f32, h: f32) void {
    if (label.len != 0) {
        cimgui.ember_ui_text_colored(t.colors.text_dim.pack(), cimgui.text(label));
        // Stay on this line, right after the text.
        cimgui.ember_ui_same_line(0, 0);
        const pad = slot_w - draw.textSize(label).x;
        if (pad > 0) cimgui.ember_ui_dummy(pad, h);
    } else {
        cimgui.ember_ui_dummy(slot_w, h);
    }
    cimgui.ember_ui_same_line(0, t.metrics.gap());
}

/// Draws a text item with an explicit colour, without the push/pop ceremony at
/// every call site. `TextUnformatted` has no colour overload in 1.92 and
/// `TextColored` takes a FORMAT string, which turns a `%` in a user-visible
/// label into a crash.
pub fn coloredText(col: cimgui.Rgba, s: []const u8) void {
    cimgui.ember_ui_text_colored(col.pack(), cimgui.text(s));
}
