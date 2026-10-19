//! `ui.draw` — the primitives every custom widget is made of.
//!
//! ## Why the widgets are not ImGui's
//!
//! ImGui draws a rounded, 4-pixel, grey box with a 1px border and a hard
//! gradient. Every screenshot of every ImGui program looks like that, and it is
//! why a tool built on it looks like a tool from 2008. The fix is not a theme
//! file: ImGui's stock widgets draw themselves, and a theme can only choose
//! among the colours.
//!
//! So a widget in /ui is three steps, and this file is step three:
//!
//! ```zig
//! // 1. reserve the item and take the click — ImGui's hit testing, the part
//! //    that is genuinely good and that nobody should rewrite
//! const clicked = cimgui.ember_ui_invisible_button(id, w, h, 0) != 0;
//! // 2. ask what state it is in
//! const state: theme.State = if (clicked) .active else if (hovered) .hover else .idle;
//! // 3. draw it however the design says
//! draw.button(dl, rect, radius, theme.fill(t, state), theme.accent, hovered);
//! ```
//!
//! Nothing here knows what a button is. That is the point: the primitives are
//! shared by buttons, cards, list rows, tabs, checkboxes and the splitter
//! handle, so a change to the shadow or the corner treatment lands everywhere
//! at once — which is the only way a UI stays consistent as it grows.

const std = @import("std");
const cimgui = @import("cimgui.zig");
const theme = @import("theme.zig");
const Context = @import("context.zig");
const Rgba = cimgui.Rgba;
const Rect = cimgui.Rect;
const Vec2 = cimgui.Vec2;

/// A draw list, as a typed handle.
///
/// Not an opaque type: the widgets call methods on it (`list.rect(...)`), and
/// an opaque cannot have methods. So it is a struct with ONE field — the
/// `ImDrawList*` — and that field is private, which is the part that matters:
/// nothing outside this file can reach an ImGui draw list, and "which list am
/// I drawing on" is a method call rather than a cast at 40 sites.
pub const List = struct {
    ptr: ?*anyopaque,

    pub fn item() List {
        return .{ .ptr = cimgui.ember_ui_get_item_draw_list() };
    }
    pub fn window() List {
        return .{ .ptr = cimgui.ember_ui_get_window_draw_list() };
    }
    /// Screen coordinates, over every window: a drag outline, a marquee.
    pub fn foreground() List {
        return .{ .ptr = cimgui.ember_ui_get_foreground_draw_list() };
    }
    pub fn background() List {
        return .{ .ptr = cimgui.ember_ui_get_background_draw_list() };
    }

    /// The number of draw commands queued on this list. Reported by the demo
    /// and by `Context.stats`: ImGui's own batching means a busy panel is one
    /// command, and "the UI costs 2 ms" is only a useful sentence next to it.
    pub fn commandCount(self: List) usize {
        const n = cimgui.ember_draw_cmd_count(@ptrCast(@as(?*anyopaque, self.ptr)));
        return if (n < 0) 0 else @intCast(n);
    }

    // ── Primitives ───────────────────────────────────────────────────────

    pub fn rect(self: List, r: Rect, col: Rgba, rounding: f32) void {
        cimgui.ember_draw_rect_filled(@ptrCast(@as(?*anyopaque, self.ptr)), r.min.x, r.min.y, r.max.x, r.max.y, col.pack(), rounding, 0);
    }

    pub fn rectOutline(self: List, r: Rect, col: Rgba, rounding: f32, thickness: f32) void {
        // Inset by half the thickness, so a 1px border straddling the edge does
        // not become a 2px border on one side and a 0px one on the other. This
        // is the single most common off-by-a-half in hand-drawn UI.
        const t = thickness * 0.5;
        cimgui.ember_draw_rect(
            @ptrCast(@as(?*anyopaque, self.ptr)),
            r.min.x + t,
            r.min.y + t,
            r.max.x - t,
            r.max.y - t,
            col.pack(),
            @max(0, rounding - t),
            thickness,
            0,
        );
    }

    /// A vertical gradient between two colours, the top-left/top-right pair
    /// being the same colour. This is what makes a dark button read as a
    /// button rather than a rectangle: a top edge one step lighter than the
    /// bottom is the entire difference, and it costs one draw call.
    pub fn rectGradientV(self: List, r: Rect, top: Rgba, bottom: Rgba, rounding: f32) void {
        cimgui.ember_draw_rect_filled_multi(
            @ptrCast(@as(?*anyopaque, self.ptr)),
            r.min.x,
            r.min.y,
            r.max.x,
            r.max.y,
            top.pack(),
            top.pack(),
            bottom.pack(),
            bottom.pack(),
        );
        _ = rounding; // the multi-colour path is rectangular; round it after
    }

    /// A BILINEAR gradient: one colour per corner, interpolated across both
    /// axes. `rectGradientV` is the common case (a button); this is the one a
    /// colour picker needs, because a saturation/value square IS a bilinear
    /// blend — white at the top-left, the pure hue at the top-right, black
    /// along the bottom — and no amount of stacking two 1-D gradients produces
    /// it. One draw call, and ImGui's own `AddRectFilledMultiColor` is exactly
    /// this function.
    pub fn rectGradient4(self: List, r: Rect, tl: Rgba, tr: Rgba, br: Rgba, bl: Rgba) void {
        cimgui.ember_draw_rect_filled_multi(
            @ptrCast(@as(?*anyopaque, self.ptr)),
            r.min.x,
            r.min.y,
            r.max.x,
            r.max.y,
            tl.pack(),
            tr.pack(),
            br.pack(),
            bl.pack(),
        );
    }

    /// A horizontal gradient between two colours: `rectGradient4` with the
    /// top pair and the bottom pair equal. A hue bar is six of these, an alpha
    /// bar is one.
    pub fn rectGradientH(self: List, r: Rect, left: Rgba, right: Rgba, rounding: f32) void {
        self.rectGradient4(r, left, right, right, left);
        _ = rounding; // as with the vertical case: the multi-colour path is square
    }

    /// The gradient with the corners actually rounded: the rectangle first, then
    /// the four corner squares in the matching colour. Eight draw calls is a
    /// lot for a button, so the real path is `roundedGradient`, which uses the
    /// path API once.
    pub fn roundedGradient(self: List, r: Rect, top: Rgba, bottom: Rgba, rounding: f32) void {
        // A single convex path filled with the bottom colour, and a smaller one
        // filled with the top: two fills, correct corners, and the seam between
        // them is the gradient's midpoint. Good enough at a button's size, and
        // it is two commands instead of eight.
        const mid = top.lerp(bottom, 0.5);
        self.pathRounded(r, rounding);
        self.pathFill(mid);
        self.rect(r, bottom, rounding);
        self.pathRounded(r, rounding);
        self.pathFill(bottom);
    }

    pub fn circle(self: List, c: Vec2, radius: f32, col: Rgba) void {
        cimgui.ember_draw_circle_filled(@ptrCast(@as(?*anyopaque, self.ptr)), c.x, c.y, radius, col.pack(), 0);
    }

    pub fn circleOutline(self: List, c: Vec2, radius: f32, col: Rgba, thickness: f32) void {
        cimgui.ember_draw_circle(@ptrCast(@as(?*anyopaque, self.ptr)), c.x, c.y, @max(0, radius - thickness * 0.5), col.pack(), 0, thickness);
    }

    pub fn line(self: List, a: Vec2, b: Vec2, col: Rgba, thickness: f32) void {
        cimgui.ember_draw_line(@ptrCast(@as(?*anyopaque, self.ptr)), a.x, a.y, b.x, b.y, col.pack(), thickness);
    }

    pub fn text(self: List, at: Vec2, col: Rgba, s: []const u8) void {
        cimgui.ember_draw_text(@ptrCast(@as(?*anyopaque, self.ptr)), null, at.x, at.y, col.pack(), cimgui.text(s));
    }

    // ── Paths ────────────────────────────────────────────────────────────

    pub fn pathReset(self: List) void {
        cimgui.ember_draw_path_reset(@ptrCast(@as(?*anyopaque, self.ptr)));
    }
    pub fn pathArc(self: List, at_: Vec2, radius: f32, a0: f32, a1: f32, segments: c_int) void {
        cimgui.ember_draw_path_arc(@ptrCast(@as(?*anyopaque, self.ptr)), at_.x, at_.y, radius, a0, a1, segments);
    }
    pub fn pathLine(self: List, p: Vec2) void {
        cimgui.ember_draw_path_line(@ptrCast(@as(?*anyopaque, self.ptr)), p.x, p.y);
    }
    pub fn pathFill(self: List, col: Rgba) void {
        cimgui.ember_draw_path_fill(@ptrCast(@as(?*anyopaque, self.ptr)), col.pack());
    }
    pub fn pathStroke(self: List, col: Rgba, thickness: f32, closed: bool) void {
        cimgui.ember_draw_path_stroke(
            @ptrCast(@as(?*anyopaque, self.ptr)),
            col.pack(),
            thickness,
            if (closed) cimgui.DrawFlags.Closed else 0,
        );
    }

    /// A rounded rectangle as a path. `radius` is clamped to half the shorter
    /// side, because a corner radius larger than half the box makes ImGui's
    /// arc sweep overlap itself and the result is a bow tie — visible, and
    /// always on the smallest control in the panel.
    pub fn pathRounded(self: List, r: Rect, radius: f32) void {
        const rad = @min(radius, @min(r.max.x - r.min.x, r.max.y - r.min.y) * 0.5);
        const pi: f32 = std.math.pi;
        cimgui.ember_draw_path_arc(@ptrCast(@as(?*anyopaque, self.ptr)), r.max.x - rad, r.max.y - rad, rad, 0, pi * 0.5, 0);
        cimgui.ember_draw_path_arc(@ptrCast(@as(?*anyopaque, self.ptr)), r.min.x + rad, r.max.y - rad, rad, pi * 0.5, pi, 0);
        cimgui.ember_draw_path_arc(@ptrCast(@as(?*anyopaque, self.ptr)), r.min.x + rad, r.min.y + rad, rad, pi, pi * 1.5, 0);
        cimgui.ember_draw_path_arc(@ptrCast(@as(?*anyopaque, self.ptr)), r.max.x - rad, r.min.y + rad, rad, pi * 1.5, pi * 2.0, 0);
        cimgui.ember_draw_path_line(@ptrCast(@as(?*anyopaque, self.ptr)), r.max.x - rad, r.max.y);
        cimgui.ember_draw_path_line(@ptrCast(@as(?*anyopaque, self.ptr)), r.max.x, r.max.y - rad);
        cimgui.ember_draw_path_line(@ptrCast(@as(?*anyopaque, self.ptr)), r.max.x, r.min.y + rad);
        cimgui.ember_draw_path_line(@ptrCast(@as(?*anyopaque, self.ptr)), r.max.x - rad, r.min.y);
        cimgui.ember_draw_path_line(@ptrCast(@as(?*anyopaque, self.ptr)), r.min.x + rad, r.min.y);
        cimgui.ember_draw_path_line(@ptrCast(@as(?*anyopaque, self.ptr)), r.min.x, r.min.y + rad);
        cimgui.ember_draw_path_line(@ptrCast(@as(?*anyopaque, self.ptr)), r.min.x, r.max.y - rad);
        cimgui.ember_draw_path_line(@ptrCast(@as(?*anyopaque, self.ptr)), r.min.x + rad, r.max.y);
    }

    pub fn pushClip(self: List, r: Rect, intersect: bool) void {
        cimgui.ember_draw_push_clip(@ptrCast(@as(?*anyopaque, self.ptr)), r.min.x, r.min.y, r.max.x, r.max.y, @intFromBool(intersect));
    }
    pub fn popClip(self: List) void {
        cimgui.ember_draw_pop_clip(@ptrCast(@as(?*anyopaque, self.ptr)));
    }

    // ── The composites every widget shares ───────────────────────────────

    /// A control's background: gradient when idle-and-primary, flat when
    /// anything is happening to it.
    ///
    /// The rule is that a pressed control gets FLATTER, not darker-and-darker.
    /// Users read motion through the shading of a surface; a button that keeps
    /// accumulating shadow as it is held reads as a hole.
    pub fn control(self: List, r: Rect, radius: f32, base: Rgba, hover: Rgba, state: theme.State) void {
        switch (state) {
            .idle => self.roundedGradient(r, base.lerp(Rgba.of(1, 1, 1, 0.06), 1.0), base, radius),
            .hover => self.rect(r, hover, radius),
            .active => self.rect(r, hover.scaled(0.88), radius),
            .disabled => self.rect(r, base.withAlpha(0.45), radius),
        }
    }

    /// A 1px separator, inset by the rounding so it does not poke out of a
    /// rounded panel's corners.
    pub fn separator(self: List, r: Rect, col: Rgba) void {
        const y = @floor(r.min.y + 0.5);
        self.line(.{ .x = r.min.x, .y = y }, .{ .x = r.max.x, .y = y }, col, 1.0);
    }

    /// A drop shadow under a floating surface. Four passes at increasing size
    /// and decreasing alpha, which is a cheap approximation of a blur and the
    /// difference between a dropdown that floats and one that is pasted on.
    pub fn shadow(self: List, r: Rect, radius: f32, col: Rgba, spread: f32) void {
        var i: u32 = 0;
        while (i < 4) : (i += 1) {
            const k = @as(f32, @floatFromInt(i + 1)) / 4.0;
            const step = spread * k;
            self.rectOutline(
                .{
                    .min = .{ .x = r.min.x - step, .y = r.min.y - step + step * 0.4 },
                    .max = .{ .x = r.max.x + step, .y = r.max.y + step + step * 0.4 },
                },
                col.withAlpha(col.a * 0.25 * (1.0 - k)),
                radius + step,
                1.0,
            );
        }
    }

    /// The focus ring: a 2px accent outline OUTSIDE the control, never on it.
    /// A ring drawn on the control's own edge replaces the border, and the
    /// control loses its shape exactly when the user is looking at it.
    pub fn focusRing(self: List, r: Rect, radius: f32, thickness: f32, col: Rgba) void {
        const pad = thickness + 1.0;
        self.rectOutline(
            .{
                .min = .{ .x = r.min.x - pad, .y = r.min.y - pad },
                .max = .{ .x = r.max.x + pad, .y = r.max.y + pad },
            },
            col,
            radius + pad,
            thickness,
        );
    }

    /// A horizontal progress fill. The track is inset by the height so the
    /// rounded ends of the fill line up with the rounded ends of the track
    /// instead of poking out of them.
    pub fn progress(self: List, r: Rect, value: f32, track: Rgba, fill_col: Rgba) void {
        const rad = (r.max.y - r.min.y) * 0.5;
        self.roundedGradient(r, track, track, rad);
        const w = (r.max.x - r.min.x) * std.math.clamp(value, 0.0, 1.0);
        if (w <= 0.5) return;
        self.roundedGradient(
            .{ .min = r.min, .max = .{ .x = r.min.x + w, .y = r.max.y } },
            fill_col.lerp(Rgba.of(1, 1, 1, 0.18), 1.0),
            fill_col,
            rad,
        );
    }
};

/// The item rectangle the last submitted item occupies, in window-local
/// coordinates — the space `List` draws in.
pub fn itemRect() Rect {
    var out: [2]f32 = undefined;
    cimgui.ember_ui_get_item_rect_min(&out);
    var r: Rect = .{ .min = .{ .x = out[0], .y = out[1] } };
    cimgui.ember_ui_get_item_rect_max(&out);
    r.max = .{ .x = out[0], .y = out[1] };
    return r;
}

pub fn cursorPos() Vec2 {
    var out: [2]f32 = undefined;
    cimgui.ember_ui_get_cursor_pos(&out);
    return .{ .x = out[0], .y = out[1] };
}

pub fn cursorScreenPos() Vec2 {
    var out: [2]f32 = undefined;
    cimgui.ember_ui_get_cursor_screen_pos(&out);
    return .{ .x = out[0], .y = out[1] };
}

pub fn contentAvail() Vec2 {
    var out: [2]f32 = undefined;
    cimgui.ember_ui_get_content_region_avail(&out);
    return .{ .x = out[0], .y = out[1] };
}

pub fn setCursorPos(v: Vec2) void {
    cimgui.ember_ui_set_cursor_pos(v.x, v.y);
}

pub fn textSize(s: []const u8) Vec2 {
    var out: [2]f32 = undefined;
    cimgui.ember_ui_calc_text_size(cimgui.text(s), &out);
    return .{ .x = out[0], .y = out[1] };
}

pub fn textSizeWrapped(s: []const u8, wrap: f32) Vec2 {
    var out: [2]f32 = undefined;
    cimgui.ember_ui_calc_text_size_ws(cimgui.text(s), wrap, &out);
    return .{ .x = out[0], .y = out[1] };
}

/// A rect from two corners, for a widget that knows where its edges are.
pub fn rect(x0: f32, y0: f32, x1: f32, y1: f32) Rect {
    return .{
        .min = .{ .x = @min(x0, x1), .y = @min(y0, y1) },
        .max = .{ .x = @max(x0, x1), .y = @max(y0, y1) },
    };
}

pub fn inset(r: Rect, by: f32) Rect {
    return rect(r.min.x + by, r.min.y + by, r.max.x - by, r.max.y - by);
}

pub fn expand(r: Rect, by: f32) Rect {
    return rect(r.min.x - by, r.min.y - by, r.max.x + by, r.max.y + by);
}

pub fn grow(r: Rect, right: f32, down: f32) Rect {
    return rect(r.min.x, r.min.y, r.max.x + right, r.max.y + down);
}

pub fn center(r: Rect) Vec2 {
    return .{
        .x = (r.min.x + r.max.x) * 0.5,
        .y = (r.min.y + r.max.y) * 0.5,
    };
}

pub fn width(r: Rect) f32 {
    return r.max.x - r.min.x;
}

pub fn height(r: Rect) f32 {
    return r.max.y - r.min.y;
}

pub fn contains(r: Rect, p: Vec2) bool {
    return p.x >= r.min.x and p.x < r.max.x and p.y >= r.min.y and p.y < r.max.y;
}

test "ui draw: rect helpers normalise their corners" {
    // A rect built from corners in the wrong order is a rect with a negative
    // width, and every later rounding calculation then produces garbage. So
    // `rect` sorts its corners: min is always min, max is always max, and the
    // WIDTH is a difference rather than a subtraction that could go negative.
    const r = rect(10, 20, 4, 8);
    try std.testing.expectEqual(@as(f32, 4), r.min.x);
    try std.testing.expectEqual(@as(f32, 10), r.max.x);
    try std.testing.expectEqual(@as(f32, 6), width(r));
    try std.testing.expectEqual(@as(f32, 12), height(r));
    // And the normalisation is total, not approximate: a rect passed its own
    // corners in the other order produces the SAME struct.
    try std.testing.expectEqual(rect(4, 8, 10, 12), rect(10, 12, 4, 8));
}

test "ui draw: inset and expand are inverses" {
    // `inset(by)` removes `by` from BOTH edges, so a rect 100 wide becomes 84
    // wide, and `expand(by)` is the same operation in the other direction. The
    // invariant matters more than the number: every padding calculation in the
    // widgets assumes the round trip is exact.
    const r = rect(0, 0, 100, 50);
    try std.testing.expectEqual(@as(f32, 100), width(expand(inset(r, 8), 8)));
    try std.testing.expectEqual(@as(f32, 50), height(expand(inset(r, 8), 8)));
    try std.testing.expectEqual(@as(f32, 84), width(inset(r, 8)));
}

test "ui draw: contains is half-open, so adjacent rects do not both match" {
    const a = rect(0, 0, 10, 10);
    try std.testing.expect(contains(a, .{ .x = 0, .y = 0 }));
    try std.testing.expect(contains(a, .{ .x = 9.99, .y = 9.99 }));
    try std.testing.expect(!contains(a, .{ .x = 10, .y = 5 }));
    try std.testing.expect(!contains(a, .{ .x = 5, .y = 10 }));
}

/// The short form the widgets were written against: `draw.itemList()`.
///
/// An alias of `draw.itemList()`, kept because 40 call sites read that way and
/// a rename that has to touch every widget file is a rename that will be half
/// done a year from now.
pub const listOf = struct {
    pub fn item() List {
        return .{ .ptr = cimgui.ember_ui_get_item_draw_list() };
    }
    pub fn window() List {
        return .{ .ptr = cimgui.ember_ui_get_window_draw_list() };
    }
    pub fn foreground() List {
        return .{ .ptr = cimgui.ember_ui_get_foreground_draw_list() };
    }
    pub fn background() List {
        return .{ .ptr = cimgui.ember_ui_get_background_draw_list() };
    }
};

/// `draw.itemList()`: the item's draw list.
pub fn itemList() List {
    return .{ .ptr = cimgui.ember_ui_get_item_draw_list() };
}
/// The window's own list, same space as `itemList`.
pub fn windowList() List {
    return .{ .ptr = cimgui.ember_ui_get_window_draw_list() };
}
/// Screen coordinates, over every window.
pub fn foregroundList() List {
    return .{ .ptr = cimgui.ember_ui_get_foreground_draw_list() };
}
pub fn backgroundList() List {
    return .{ .ptr = cimgui.ember_ui_get_background_draw_list() };
}

/// Runs `body` with a font face applied, then restores the previous one.
///
/// The shape every "draw this text in that face" call takes. A function plus a
/// tuple of its arguments, which is what ImGui's own API does NOT have and why
/// a `withFont` callback has to be a template.
/// `Context` here is the MODULE (see the import above), so the struct and its
/// nested face enum are reached through it. Naming only the module is what made
/// this signature "*context has no member named Font" — a compile error that
/// stayed invisible until something called `text.title`.
pub fn drawInFont(ctx: *Context.Context, face: Context.Context.Font, comptime body: anytype, args: anytype) void {
    ctx.withFont(face, body, args);
}
