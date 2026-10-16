//! `ui.widgets.color` — the colour selector: swatch, popup picker, hex.
//!
//! ## Why not `ImGui::ColorEdit4`
//!
//! ImGui's colour picker is a 2008 tool. Its square and its hue bar are fine —
//! the maths is the maths — but everything around them is ImGui's own skin: a
//! `SliderFloat` row in the stock grey, a `#RRGGBB` field whose font tag is
//! whatever ImGui had loaded, and a popup with none of this editor's radii,
//! borders or spacing. Next to a `NumberField` from `input.zig` it looks like a
//! different program, which is exactly the failure `theme.zig` exists to
//! prevent.
//!
//! So the picker is rebuilt here out of the same primitives every other widget
//! uses: a colour is a value like any other, its popup is drawn with `draw`,
//! and it follows a theme change because none of these numbers is a literal.
//!
//! ## The split that makes it testable
//!
//! The MATH is a pure function of a colour and has no ImGui in it:
//! `rgbToHsv`, `hsvToRgb`, `parseHex`, `hexString`. Those are what the headless
//! suite (`zig build test-ui`) checks, because a hue that wraps the wrong way
//! or a hex that loses a channel is invisible in a screenshot until someone
//! picks red and gets orange. The drawing and the hit-testing are the thin part
//! on top and are exercised by the component gallery.
//!
//! ## The colour model, in one paragraph
//!
//! The picker edits HSV (hue 0..360, saturation and value 0..1) and stores RGB,
//! because HSV is where the handles live — a hue bar and a saturation/value
//! square ARE HSV — and RGB is what the renderer wants. The conversion happens
//! once per frame, at the edge, and `a` rides along untouched: alpha is a
//! fourth value that neither the square nor the hue bar can express, so it gets
//! its own bar and is carried through every conversion unchanged.

const std = @import("std");
const cimgui = @import("../cimgui.zig");
const theme = @import("../theme.zig");
const draw = @import("../draw.zig");
const widget = @import("widget.zig");
const input = @import("input.zig");
const Context = @import("../context.zig").Context;
const Rgba = cimgui.Rgba;
const Vec2 = cimgui.Vec2;
const Rect = cimgui.Rect;

// ── The maths ────────────────────────────────────────────────────────────

/// Hue in degrees, saturation and value in 0..1, alpha in 0..1.
///
/// Degrees rather than a 0..1 fraction because that is what a human reads off a
/// picker (`#2F81F7` is 212°, not 0.590) and because the six-segment hexagon
/// conversion is written in 60° steps.
pub const Hsv = struct {
    h: f32 = 0.0,
    s: f32 = 1.0,
    v: f32 = 1.0,
    a: f32 = 1.0,
};

pub fn clamp01(x: f32) f32 {
    return std.math.clamp(x, 0.0, 1.0);
}

/// RGB (0..1) to HSV.
///
/// The saturation is `delta / max`, NOT `delta / (1 - |2*value - 1|)`: the
/// second form is the HSL one, and using it here produces a picker whose square
/// and hue bar disagree with its own swatch for every colour with a light or
/// dark value. This is the HSV form, and it is the one ImGui's picker uses.
pub fn rgbToHsv(c: Rgba) Hsv {
    const mx = @max(c.r, @max(c.g, c.b));
    const mn = @min(c.r, @min(c.g, c.b));
    const d = mx - mn;
    var h: f32 = 0.0;
    // `d > 0` matters: for a grey the hue is undefined, and returning 0 rather
    // than NaN is what stops a greyscale swatch from resetting the hue bar to
    // the middle when the user clicks it.
    if (d > 1e-6) {
        if (mx == c.r) {
            h = (c.g - c.b) / d;
        } else if (mx == c.g) {
            h = (c.b - c.r) / d + 2.0;
        } else {
            h = (c.r - c.g) / d + 4.0;
        }
        h *= 60.0;
        if (h < 0.0) h += 360.0;
    }
    const s = if (mx <= 1e-6) 0.0 else d / mx;
    return .{ .h = h, .s = s, .v = mx, .a = c.a };
}

/// HSV to RGB (0..1). The six-segment form: `c` is the chroma, `x` the second
/// largest component, `m` the value minus the chroma. Alpha is passed through.
pub fn hsvToRgb(hsv: Hsv) Rgba {
    var h = @mod(hsv.h, 360.0);
    if (h < 0.0) h += 360.0;
    const s = clamp01(hsv.s);
    const v = clamp01(hsv.v);
    const c = v * s;
    const hp = h / 60.0;
    const x = c * (1.0 - @abs(@mod(hp, 2.0) - 1.0));
    const seg: u32 = @intFromFloat(@mod(@floor(hp), 6.0));
    var r: f32 = 0.0;
    var g: f32 = 0.0;
    var b: f32 = 0.0;
    switch (seg) {
        0 => {
            r = c;
            g = x;
        },
        1 => {
            r = x;
            g = c;
        },
        2 => {
            g = c;
            b = x;
        },
        3 => {
            g = x;
            b = c;
        },
        4 => {
            r = x;
            b = c;
        },
        else => {
            r = c;
            b = x;
        },
    }
    const m = v - c;
    return .{ .r = r + m, .g = g + m, .b = b + m, .a = clamp01(hsv.a) };
}

/// `#RRGGBB`, `#RRGGBBAA`, or the same without the `#`. Returns null for
/// anything else, including a short input — a caller that gets null shows an
/// error and keeps the last good colour, which is the only sane thing to do
/// while a user is halfway through typing.
pub fn parseHex(text: []const u8) ?Rgba {
    var s = std.mem.trim(u8, text, " \t");
    if (s.len > 0 and s[0] == '#') s = s[1..];
    if (s.len != 6 and s.len != 8) return null;
    const r = std.fmt.parseInt(u8, s[0..2], 16) catch return null;
    const g = std.fmt.parseInt(u8, s[2..4], 16) catch return null;
    const b = std.fmt.parseInt(u8, s[4..6], 16) catch return null;
    var a: u8 = 255;
    if (s.len == 8) a = std.fmt.parseInt(u8, s[6..8], 16) catch return null;
    return fromBytes(r, g, b, a);
}

/// The canonical `#RRGGBB` / `#RRGGBBAA` for a colour, written into `buf`.
/// Returns an empty slice if `buf` is too small — never a truncated colour,
/// because a hex that is one character short is read as a different hex.
pub fn hexString(c: Rgba, buf: []u8, with_alpha: bool) []const u8 {
    const r = toByte(c.r);
    const g = toByte(c.g);
    const b = toByte(c.b);
    const a = toByte(c.a);
    if (with_alpha) {
        return std.fmt.bufPrint(buf, "#{X:0>2}{X:0>2}{X:0>2}{X:0>2}", .{ r, g, b, a }) catch "";
    }
    return std.fmt.bufPrint(buf, "#{X:0>2}{X:0>2}{X:0>2}", .{ r, g, b }) catch "";
}

pub fn toByte(v: f32) u8 {
    const x = @round(clamp01(v) * 255.0);
    return @intFromFloat(x);
}

pub fn fromBytes(r: u8, g: u8, b: u8, a: u8) Rgba {
    return .{
        .r = @as(f32, @floatFromInt(r)) / 255.0,
        .g = @as(f32, @floatFromInt(g)) / 255.0,
        .b = @as(f32, @floatFromInt(b)) / 255.0,
        .a = @as(f32, @floatFromInt(a)) / 255.0,
    };
}

// ── Drawing helpers ──────────────────────────────────────────────────────

/// The transparency checkerboard. Drawn UNDER a colour whose alpha is less than
/// one, because "50% red" over a flat surface is indistinguishable from "pink",
/// and the only way to show that a colour is transparent is to show what is
/// behind it.
fn checker(list: draw.List, r: Rect, light: Rgba, dark: Rgba, cell: f32) void {
    const w = draw.width(r);
    const h = draw.height(r);
    if (cell <= 0.0) return;
    var y: f32 = 0.0;
    var row: usize = 0;
    while (y < h) : ({
        y += cell;
        row += 1;
    }) {
        var x: f32 = 0.0;
        var col_i: usize = 0;
        while (x < w) : ({
            x += cell;
            col_i += 1;
        }) {
            const c = if ((row + col_i) % 2 == 0) light else dark;
            const x0 = r.min.x + x;
            const y0 = r.min.y + y;
            list.rect(
                draw.rect(x0, y0, @min(x0 + cell, r.max.x), @min(y0 + cell, r.max.y)),
                c,
                0,
            );
        }
    }
}

/// The grab handle on the square / a bar: a dark disc with a light ring inside
/// it, so it stays visible on white, on black, and on every hue between. One
/// ring would disappear against its own colour; two never do.
fn handle(list: draw.List, c: Vec2, col: Rgba, radius: f32) void {
    list.circleOutline(c, radius, Rgba.of(0, 0, 0, 0.75), 3.0);
    list.circleOutline(c, radius, col, 1.6);
}

fn screenDelta(s: Vec2, local: Vec2) Vec2 {
    return .{ .x = s.x - local.x, .y = s.y - local.y };
}

/// The mouse position relative to an item's top-left corner, in the item's own
/// pixels.
///
/// The item rect is window-LOCAL and the mouse is in window coordinates, so the
/// rect is first lifted into screen space by the offset between the cursor's
/// screen and local positions at submit time. Without that offset every drag is
/// wrong by the panel's scroll, which is the kind of bug that only shows up
/// after someone has scrolled a docked panel.
fn relMouse(ctx: *Context, r: Rect, delta: Vec2) Vec2 {
    const mouse = ctx.window.input.mouse;
    return .{
        .x = mouse.x - (r.min.x + delta.x),
        .y = mouse.y - (r.min.y + delta.y),
    };
}

// ── The swatch ───────────────────────────────────────────────────────────

/// Paints a colour swatch into `r`: the checkerboard, the colour over it, an
/// alpha bar on the left when the colour is not opaque, and the border.
pub fn paintSwatch(list: draw.List, t: *theme.Theme, r: Rect, col: Rgba, hovered: bool) void {
    const m = t.metrics;
    const rad = m.radius_sm();
    checker(list, r, t.colors.surface_hi, t.colors.surface_hi2, 6.0);
    list.rect(r, col, rad);
    // A transparent colour gets a small solid strip of itself on the left, so
    // the swatch says WHICH colour it is at full opacity, not just that there
    // is something translucent here.
    if (col.a < 0.999) {
        const strip = draw.rect(r.min.x, r.min.y, r.min.x + rad, r.max.y);
        list.rect(strip, col.withAlpha(1.0), rad);
    }
    list.rectOutline(
        r,
        if (hovered) t.colors.border_strong else t.colors.border,
        rad,
        1.0,
    );
}

// ── The field ────────────────────────────────────────────────────────────

pub const ColorField = struct {
    ctx: *Context,
    id: []const u8,
    label: []const u8 = "",
    /// The colour. Owned by the caller: a widget that allocated its own would
    /// hand back a value nobody can free, exactly like `input.textField`.
    value: *Rgba,
    /// Show the alpha bar and the A field. Off for a colour that cannot be
    /// translucent, which is the honest way to say "this one is not".
    show_alpha: bool = true,
    label_slot: f32 = 64.0,
    /// The width of the swatch itself. A colour field is a swatch with a label,
    /// not a full-width control: a 300px swatch is a rectangle nobody needs.
    swatch_w: f32 = 52.0,
    disabled: bool = false,
    tooltip: ?[]const u8 = null,
    /// When set, the popup shows an EDITABLE hex field using this caller-owned
    /// buffer (`textField`'s contract). When null the hex is shown read-only:
    /// a picker that cannot type an exact hex is still a picker, and demanding
    /// a buffer from every call site is a worse default than showing one.
    hex_buf: ?[]u8 = null,
    hex_capacity: u32 = 0,
    on_change: ?*const fn (ctx: ?*anyopaque) void = null,
    ctx_arg: ?*anyopaque = null,
};

/// Returns true when the colour changed this frame.
pub fn field(f: ColorField) bool {
    const t = &f.ctx.theme;
    const m = t.metrics;
    const h = m.row_h();
    const w = f.swatch_w;

    widget.labelSlot(t, f.label, f.label_slot, h);
    cimgui.ember_ui_push_id_str(cimgui.text(f.id));

    const hit = widget.submit(cimgui.text("swatch"), w, h, f.disabled);
    paintSwatch(draw.List.item(), t, hit.rect, f.value.*, hit.hovered);
    if (hit.hovered) {
        if (f.tooltip) |tip| cimgui.ember_ui_set_tooltip(cimgui.text(tip));
    }
    if (hit.clicked) {
        _ = cimgui.ember_ui_open_popup(cimgui.text("##picker"));
    }

    var changed = false;
    if (cimgui.ember_ui_begin_popup(cimgui.text("##picker"), 0) != 0) {
        changed = pickerBody(f);
        cimgui.ember_ui_end_popup();
    }
    cimgui.ember_ui_pop_id();

    if (changed) {
        if (f.on_change) |cb| cb(f.ctx_arg);
    }
    return changed;
}

// ── The picker (popup body) ──────────────────────────────────────────────

const square_w: f32 = 236.0;
const square_h: f32 = 130.0;
const bar_h: f32 = 16.0;

fn pickerBody(f: ColorField) bool {
    const t = &f.ctx.theme;
    const m = t.metrics;

    var hsv = rgbToHsv(f.value.*);
    var visual_changed = false;

    // ── Saturation / Value square ────────────────────────────────────────
    // x is saturation, y is value INVERSED (value grows upward, the cursor
    // grows down). The invert is the whole ergonomics of the control, and it is
    // why this is not just two sliders.
    {
        const c0 = draw.cursorPos();
        const s0 = draw.cursorScreenPos();
        _ = cimgui.ember_ui_invisible_button(cimgui.text("##sv"), square_w, square_h, 0);
        const r = draw.itemRect();
        const delta = screenDelta(s0, c0);
        const hovered = cimgui.ember_ui_is_item_hovered(@bitCast(cimgui.HoveredFlags.None)) != 0;
        const active = cimgui.ember_ui_is_item_active() != 0;
        if (active) {
            const rel = relMouse(f.ctx, r, delta);
            hsv.s = clamp01(rel.x / draw.width(r));
            hsv.v = 1.0 - clamp01(rel.y / draw.height(r));
            visual_changed = true;
        }
        const list = draw.List.item();
        const pure = hsvToRgb(.{ .h = hsv.h, .s = 1.0, .v = 1.0 });
        // White top-left, the pure hue top-right, black along the bottom: the
        // bilinear form IS the square, which is why it is one draw call.
        list.rectGradient4(r, Rgba.of(1, 1, 1, 1), pure, Rgba.of(0, 0, 0, 1), Rgba.of(0, 0, 0, 1));
        list.rectOutline(r, t.colors.border, m.radius_sm(), 1.0);
        if (active or hovered) {
            handle(
                list,
                .{
                    .x = r.min.x + hsv.s * draw.width(r),
                    .y = r.min.y + (1.0 - hsv.v) * draw.height(r),
                },
                hsvToRgb(.{ .h = hsv.h, .s = hsv.s, .v = hsv.v }),
                6.0,
            );
        }
    }

    // ── Hue bar ──────────────────────────────────────────────────────────
    {
        const c0 = draw.cursorPos();
        const s0 = draw.cursorScreenPos();
        _ = cimgui.ember_ui_invisible_button(cimgui.text("##hue"), square_w, bar_h, 0);
        const r = draw.itemRect();
        const delta = screenDelta(s0, c0);
        const hovered = cimgui.ember_ui_is_item_hovered(@bitCast(cimgui.HoveredFlags.None)) != 0;
        const active = cimgui.ember_ui_is_item_active() != 0;
        if (active) {
            const rel = relMouse(f.ctx, r, delta);
            hsv.h = clamp01(rel.x / draw.width(r)) * 360.0;
            visual_changed = true;
        }
        const list = draw.List.item();
        // Six segments, because 360° divides into six 60° steps and each step is
        // a straight interpolation between two pure hues. One gradient would
        // need a shader; six 1-D gradients are six draw calls and exactly the
        // same picture.
        var i: usize = 0;
        while (i < 6) : (i += 1) {
            const fi: f32 = @floatFromInt(i);
            const x0 = r.min.x + draw.width(r) * (fi / 6.0);
            // +1px overlap: two adjacent gradients that meet exactly leave a
            // one-pixel seam where the antialiasing does not line up.
            const x1 = r.min.x + draw.width(r) * ((fi + 1.0) / 6.0) + 1.0;
            list.rectGradientH(
                draw.rect(x0, r.min.y, x1, r.max.y),
                hsvToRgb(.{ .h = fi * 60.0, .s = 1.0, .v = 1.0 }),
                hsvToRgb(.{ .h = (fi + 1.0) * 60.0, .s = 1.0, .v = 1.0 }),
                0,
            );
        }
        list.rectOutline(r, t.colors.border, m.radius_sm(), 1.0);
        if (active or hovered) {
            const hx = r.min.x + (hsv.h / 360.0) * draw.width(r);
            list.rect(draw.rect(hx - 1.5, r.min.y, hx + 1.5, r.max.y), t.colors.text, 1.0);
        }
    }

    // ── Alpha bar ────────────────────────────────────────────────────────
    if (f.show_alpha) {
        const c0 = draw.cursorPos();
        const s0 = draw.cursorScreenPos();
        _ = cimgui.ember_ui_invisible_button(cimgui.text("##alpha"), square_w, bar_h, 0);
        const r = draw.itemRect();
        const delta = screenDelta(s0, c0);
        const hovered = cimgui.ember_ui_is_item_hovered(@bitCast(cimgui.HoveredFlags.None)) != 0;
        const active = cimgui.ember_ui_is_item_active() != 0;
        if (active) {
            const rel = relMouse(f.ctx, r, delta);
            hsv.a = clamp01(rel.x / draw.width(r));
            visual_changed = true;
        }
        const list = draw.List.item();
        const solid = hsvToRgb(.{ .h = hsv.h, .s = hsv.s, .v = hsv.v });
        checker(list, r, t.colors.surface_hi, t.colors.surface_hi2, 6.0);
        list.rectGradientH(r, solid.withAlpha(0.0), solid.withAlpha(1.0), 0);
        list.rectOutline(r, t.colors.border, m.radius_sm(), 1.0);
        if (active or hovered) {
            const ax = r.min.x + hsv.a * draw.width(r);
            list.rect(draw.rect(ax - 1.5, r.min.y, ax + 1.5, r.max.y), t.colors.text, 1.0);
        }
    }

    const cur = hsvToRgb(hsv);
    var changed = visual_changed;
    if (visual_changed) f.value.* = cur;

    // ── Hex ──────────────────────────────────────────────────────────────
    cimgui.ember_ui_spacing();
    {
        var hexbuf: [12]u8 = undefined;
        const canonical = hexString(cur, &hexbuf, f.show_alpha);
        if (f.hex_buf) |buf| {
            // The buffer is seeded from the colour only when the visual
            // controls moved it. Seeding every frame would fight the user's
            // cursor: every keystroke would be replaced by the canonical form
            // of the last committed value.
            if (visual_changed and f.hex_capacity > 0) {
                const n = @min(canonical.len, f.hex_capacity - 1);
                @memcpy(buf[0..n], canonical[0..n]);
                buf[n] = 0;
            }
            _ = input.textField(.{
                .ctx = f.ctx,
                .id = "hex",
                .buf = buf.ptr,
                .capacity = f.hex_capacity,
                .placeholder = if (f.show_alpha) "#RRGGBBAA" else "#RRGGBB",
                .label = "Hex",
                .label_slot = 34.0,
                .width = square_w - 34.0 - m.gap(),
            });
            const typed = input.currentSlice(buf.ptr, f.hex_capacity);
            if (parseHex(typed)) |parsed| {
                const next = Rgba{
                    .r = parsed.r,
                    .g = parsed.g,
                    .b = parsed.b,
                    .a = if (f.show_alpha) parsed.a else f.value.*.a,
                };
                if (!rgbaEql(next, f.value.*)) {
                    f.value.* = next;
                    changed = true;
                }
            }
        } else {
            const w = @max(draw.contentAvail().x, 1);
            cimgui.ember_ui_dummy(w, m.row_h());
            const r = draw.itemRect();
            draw.List.item().text(
                .{ .x = r.min.x + m.pad_x(), .y = r.min.y + (m.row_h() - 16) * 0.5 },
                t.colors.text_dim,
                canonical,
            );
        }
    }

    // ── R / G / B (/ A) ──────────────────────────────────────────────────
    cimgui.ember_ui_spacing();
    {
        const gap = m.gap();
        const fields: f32 = if (f.show_alpha) 4.0 else 3.0;
        const cw = (square_w - gap * (fields - 1.0)) / fields;

        var rf: f32 = @floatFromInt(toByte(cur.r));
        var gf: f32 = @floatFromInt(toByte(cur.g));
        var bf: f32 = @floatFromInt(toByte(cur.b));
        var af: f32 = @floatFromInt(toByte(cur.a));

        var num_changed = false;
        num_changed = numField(f, "r", "R", &rf, cw) or num_changed;
        cimgui.ember_ui_same_line(0, gap);
        num_changed = numField(f, "g", "G", &gf, cw) or num_changed;
        cimgui.ember_ui_same_line(0, gap);
        num_changed = numField(f, "b", "B", &bf, cw) or num_changed;
        if (f.show_alpha) {
            cimgui.ember_ui_same_line(0, gap);
            num_changed = numField(f, "a", "A", &af, cw) or num_changed;
        }

        if (num_changed) {
            const next = fromBytes(
                @intFromFloat(rf),
                @intFromFloat(gf),
                @intFromFloat(bf),
                if (f.show_alpha) @intFromFloat(af) else toByte(cur.a),
            );
            if (!rgbaEql(next, f.value.*)) {
                f.value.* = next;
                changed = true;
            }
        }
    }

    return changed;
}

/// One channel: a 0..255 drag field with a one-letter label. `numberField`
/// clamps for us, so a user who types 300 gets 255 rather than an out-of-range
/// colour that `toByte` would then silently rein in.
fn numField(f: ColorField, id: []const u8, label: []const u8, value: *f32, width: f32) bool {
    return input.numberField(.{
        .ctx = f.ctx,
        .id = id,
        .label = label,
        .value = value,
        .min = 0.0,
        .max = 255.0,
        .speed = 0.5,
        .format = "%.0f",
        .label_slot = 16.0,
        .width = width - 16.0,
    });
}

fn rgbaEql(a: Rgba, b: Rgba) bool {
    // A tolerance, not `==`: the two sides have been through different
    // round trips (one through HSV, one through a byte), and comparing them
    // exactly reports a change on every frame of a still picker.
    const eps: f32 = 1.0 / 512.0;
    return @abs(a.r - b.r) < eps and @abs(a.g - b.g) < eps and
        @abs(a.b - b.b) < eps and @abs(a.a - b.a) < eps;
}

// ── Tests ────────────────────────────────────────────────────────────────

const testing = std.testing;

test "ui color: a hue of 0 and a hue of 360 are the same colour" {
    // The wrap is the bug every hand-written picker has once: the hue bar's
    // right edge and its left edge must be the same red, or clicking the far
    // right of the bar jumps the marker to the far left.
    const a = hsvToRgb(.{ .h = 0.0, .s = 1.0, .v = 1.0 });
    const b = hsvToRgb(.{ .h = 360.0, .s = 1.0, .v = 1.0 });
    const c = hsvToRgb(.{ .h = -10.0, .s = 1.0, .v = 1.0 });
    try testing.expectApproxEqAbs(a.r, b.r, 1e-5);
    try testing.expectApproxEqAbs(a.g, b.g, 1e-5);
    try testing.expectApproxEqAbs(a.b, b.b, 1e-5);
    // -10 is 350: red with a little blue, not red with none.
    try testing.expect(c.b > a.b + 0.1);
}

test "ui color: rgb -> hsv -> rgb is a round trip" {
    // The invariant the picker depends on: opening it and closing it without
    // touching anything must not shift the colour.
    const samples = [_]Rgba{
        .{ .r = 0.18, .g = 0.51, .b = 0.97, .a = 1.0 },
        .{ .r = 1.0, .g = 1.0, .b = 1.0, .a = 1.0 },
        .{ .r = 0.0, .g = 0.0, .b = 0.0, .a = 0.5 },
        .{ .r = 0.5, .g = 0.5, .b = 0.5, .a = 0.25 },
        .{ .r = 0.9, .g = 0.1, .b = 0.4, .a = 0.75 },
    };
    for (samples) |c| {
        const back = hsvToRgb(rgbToHsv(c));
        try testing.expectApproxEqAbs(c.r, back.r, 1e-4);
        try testing.expectApproxEqAbs(c.g, back.g, 1e-4);
        try testing.expectApproxEqAbs(c.b, back.b, 1e-4);
        // Alpha is not part of the conversion, and passing it through unchanged
        // is the whole reason a translucent colour survives a hue drag.
        try testing.expectApproxEqAbs(c.a, back.a, 1e-6);
    }
}

test "ui color: the primary hues land in the six segments" {
    // A table of the six corners, because an off-by-one in the segment switch
    // is a plausible bug and this is the cheapest way to make it impossible.
    const red = hsvToRgb(.{ .h = 0, .s = 1, .v = 1 });
    try testing.expect(red.r > 0.99 and red.g < 0.01 and red.b < 0.01);
    const green = hsvToRgb(.{ .h = 120, .s = 1, .v = 1 });
    try testing.expect(green.g > 0.99 and green.r < 0.01 and green.b < 0.01);
    const blue = hsvToRgb(.{ .h = 240, .s = 1, .v = 1 });
    try testing.expect(blue.b > 0.99 and blue.r < 0.01 and blue.g < 0.01);
    const yellow = hsvToRgb(.{ .h = 60, .s = 1, .v = 1 });
    try testing.expect(yellow.r > 0.99 and yellow.g > 0.99 and yellow.b < 0.01);
}

test "ui color: a grey has no hue and does not become NaN" {
    // `rgbToHsv` on a grey divides by a zero delta anywhere a naive
    // implementation would. A NaN hue then poisons every later conversion, so
    // the picker stays broken until the window is reopened.
    const h = rgbToHsv(.{ .r = 0.42, .g = 0.42, .b = 0.42, .a = 1.0 });
    try testing.expectEqual(@as(f32, 0.0), h.h);
    try testing.expectEqual(@as(f32, 0.0), h.s);
    try testing.expectApproxEqAbs(@as(f32, 0.42), h.v, 1e-5);
}

test "ui color: hex round trips through the byte helper" {
    var buf: [12]u8 = undefined;
    const c = Rgba.hex(0x2F81F7, 1.0);
    const s = hexString(c, &buf, false);
    try testing.expectEqualStrings("#2F81F7", s);
    const back = parseHex(s) orelse return error.TestUnexpectedResult;
    try testing.expectApproxEqAbs(c.r, back.r, 1e-2);
    try testing.expectApproxEqAbs(c.g, back.g, 1e-2);
    try testing.expectApproxEqAbs(c.b, back.b, 1e-2);
}

test "ui color: hex parsing accepts what a user types and rejects what it must" {
    try testing.expect(parseHex("2F81F7") != null);
    try testing.expect(parseHex("#2f81f7") != null);
    try testing.expect(parseHex("  #2F81F7  ") != null);
    try testing.expect(parseHex("#2F81F7FF") != null);
    // The rejects: too short, too long, and a non-hex digit. A field that
    // accepted any of these would either crash or invent a colour.
    try testing.expect(parseHex("#2F81F") == null);
    try testing.expect(parseHex("#2F81F7A") == null);
    try testing.expect(parseHex("#ZZZZZZ") == null);
    try testing.expect(parseHex("") == null);
    // The 8-digit form keeps its alpha: dropping it is a silent loss of the
    // one channel the hex field is the only way to type.
    const a = parseHex("#2F81F780") orelse return error.TestUnexpectedResult;
    try testing.expectApproxEqAbs(@as(f32, 128.0 / 255.0), a.a, 1e-3);
}

test "ui color: a too-small hex buffer yields nothing, not half a colour" {
    var tiny: [4]u8 = undefined;
    const s = hexString(Rgba.hex(0x2F81F7, 1.0), &tiny, false);
    try testing.expectEqual(@as(usize, 0), s.len);
}
