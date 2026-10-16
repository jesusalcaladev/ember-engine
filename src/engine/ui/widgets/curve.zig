//! `ui.widgets.curve` — the cubic-bezier easing editor.
//!
//! ## What a bezier is doing in a game engine's UI
//!
//! An easing curve is the shape of every timed thing: a panel that slides in, a
//! value that lerps, a camera that settles, a hit-flash that fades. The engine
//! stores them as four numbers (`x1, y1, x2, y2`) — the same four a CSS
//! `cubic-bezier()` takes — because that representation is small, interpolable
//! and already understood by every designer who has touched a web animation.
//!
//! The curve runs from (0,0) to (1,1): `x` is progress along the timeline, `y`
//! is progress along the value. The two control points shape it, and `y` is
//! allowed OUTSIDE 0..1 — that overshoot is how "anticipate" and "back" easings
//! work, and clamping it would quietly turn every spring-shaped curve into a
//! plain S-curve.
//!
//! ## The split that makes it testable
//!
//! As with `color.zig`: the MATH is pure (`sample`, `solveT`, `Easing.at`,
//! `Easing.velocity`, the presets) and the headless suite checks it. The canvas
//! and the draggable handles are the thin part on top, exercised by the gallery.
//! A curve whose solver returns a `t` that is off by 2% is visible as a value
//! that never quite reaches its target; a curve whose preset table is wrong is
//! visible as nothing at all.

const std = @import("std");
const cimgui = @import("../cimgui.zig");
const theme = @import("../theme.zig");
const draw = @import("../draw.zig");
const widget = @import("widget.zig");
const Context = @import("../context.zig").Context;
const Rgba = cimgui.Rgba;
const Vec2 = cimgui.Vec2;
const Rect = cimgui.Rect;

// ── The maths ────────────────────────────────────────────────────────────

/// A cubic bezier with its endpoints pinned at (0,0) and (1,1).
pub const Easing = struct {
    x1: f32 = 0.25,
    y1: f32 = 0.10,
    x2: f32 = 0.25,
    y2: f32 = 1.00,

    /// The eased value for a linear progress `x` in 0..1.
    pub fn at(self: Easing, x: f32) f32 {
        if (x <= 0.0) return 0.0;
        if (x >= 1.0) return 1.0;
        return sample(solveT(x, self.x1, self.x2), self.y1, self.y2);
    }

    /// `dy/dx` at a progress `x`: how fast the value is moving per unit of
    /// time. Used by the preview dot and by anything that wants to match a
    /// second animation's speed to the first's. Not clamped, because a curve
    /// that overshoots has a moment of NEGATIVE velocity and hiding that would
    /// make the number lie.
    pub fn velocity(self: Easing, x: f32) f32 {
        const t = solveT(std.math.clamp(x, 0.0, 1.0), self.x1, self.x2);
        const dx = sampleDeriv(t, self.x1, self.x2);
        if (@abs(dx) < 1e-6) return 0.0;
        return sampleDeriv(t, self.y1, self.y2) / dx;
    }
};

/// The one-dimensional cubic with `p0 = 0` and `p3 = 1`, expanded:
/// `3(1-t)^2 t a + 3(1-t) t^2 b + t^3`. Written out rather than in matrix form
/// because it is called once per sample and the factored form is four multiplies
/// fewer per call.
pub fn sample(t: f32, a: f32, b: f32) f32 {
    const u = 1.0 - t;
    return 3.0 * u * u * t * a + 3.0 * u * t * t * b + t * t * t;
}

/// `d/dt` of `sample`. Its zero is where the curve turns around, which is the
/// one place `solveT` cannot use it.
pub fn sampleDeriv(t: f32, a: f32, b: f32) f32 {
    const u = 1.0 - t;
    return 3.0 * a * u * (1.0 - 3.0 * t) +
        3.0 * b * t * (2.0 - 3.0 * t) +
        3.0 * t * t;
}

/// Finds the parameter `t` whose x equals `x`, i.e. inverts `sample(t, x1, x2)`.
///
/// Newton-Raphson first — it converges in three or four steps for the curves
/// people actually draw — and a bisection sweep as the guard, because Newton
/// can leave `[0,1]` on a curve with a near-flat segment, and a `t` outside
/// `[0,1]` produces values that are right at the endpoints and wildly wrong in
/// the middle. The fallback costs nothing on the 99% of samples that do not
/// need it.
pub fn solveT(x: f32, x1: f32, x2: f32) f32 {
    var t = x; // an initial guess on the diagonal, and already exact for linear
    var i: usize = 0;
    while (i < 8) : (i += 1) {
        const dx = sample(t, x1, x2) - x;
        if (@abs(dx) < 1e-6) return t;
        const d = sampleDeriv(t, x1, x2);
        if (@abs(d) < 1e-6) break;
        t -= dx / d;
    }

    var lo: f32 = 0.0;
    var hi: f32 = 1.0;
    i = 0;
    while (i < 24) : (i += 1) {
        t = (lo + hi) * 0.5;
        const dx = sample(t, x1, x2) - x;
        if (@abs(dx) < 1e-6) return t;
        if (dx < 0.0) lo = t else hi = t;
    }
    return t;
}

pub const Preset = enum {
    linear,
    ease,
    ease_in,
    ease_out,
    ease_in_out,
    /// Overshoots past 1 and settles back — the "back" easing. The one preset
    /// that proves `y` is not clamped.
    back,
    /// Anticipates below 0 before going up.
    anticipate,

    pub fn name(self: Preset) []const u8 {
        return switch (self) {
            .linear => "Linear",
            .ease => "Ease",
            .ease_in => "Ease In",
            .ease_out => "Ease Out",
            .ease_in_out => "Ease In Out",
            .back => "Back",
            .anticipate => "Anticipate",
        };
    }

    pub fn easing(self: Preset) Easing {
        return switch (self) {
            .linear => .{ .x1 = 0.0, .y1 = 0.0, .x2 = 1.0, .y2 = 1.0 },
            .ease => .{ .x1 = 0.25, .y1 = 0.10, .x2 = 0.25, .y2 = 1.00 },
            .ease_in => .{ .x1 = 0.42, .y1 = 0.00, .x2 = 1.00, .y2 = 1.00 },
            .ease_out => .{ .x1 = 0.00, .y1 = 0.00, .x2 = 0.58, .y2 = 1.00 },
            .ease_in_out => .{ .x1 = 0.42, .y1 = 0.00, .x2 = 0.58, .y2 = 1.00 },
            .back => .{ .x1 = 0.34, .y1 = 1.56, .x2 = 0.64, .y2 = 1.00 },
            .anticipate => .{ .x1 = 0.36, .y1 = -0.30, .x2 = 0.66, .y2 = 1.00 },
        };
    }
};

// ── Drawing helpers ──────────────────────────────────────────────────────

/// How far the control points may be dragged OUTSIDE the unit square, in y.
/// 0.5 is enough for the deepest back/anticipate curve anyone ships, and a
/// bound keeps a handle from being dragged into the panel above.
const y_limit: f32 = 0.6;

fn toCanvas(r: Rect, pad: f32, p: Vec2) Vec2 {
    const w = draw.width(r) - pad * 2.0;
    const h = draw.height(r) - pad * 2.0;
    return .{
        .x = r.min.x + pad + p.x * w,
        .y = r.min.y + pad + (1.0 - p.y) * h,
    };
}

fn fromCanvas(r: Rect, pad: f32, p: Vec2) Vec2 {
    const w = @max(draw.width(r) - pad * 2.0, 1.0);
    const h = @max(draw.height(r) - pad * 2.0, 1.0);
    return .{
        .x = (p.x - (r.min.x + pad)) / w,
        .y = 1.0 - (p.y - (r.min.y + pad)) / h,
    };
}

fn screenDelta(s: Vec2, local: Vec2) Vec2 {
    return .{ .x = s.x - local.x, .y = s.y - local.y };
}

fn relMouse(ctx: *Context, r: Rect, delta: Vec2) Vec2 {
    const mouse = ctx.window.input.mouse;
    return .{
        .x = mouse.x - (r.min.x + delta.x),
        .y = mouse.y - (r.min.y + delta.y),
    };
}

// ── The widget ───────────────────────────────────────────────────────────

pub const CurveField = struct {
    ctx: *Context,
    id: []const u8,
    label: []const u8 = "",
    /// The four numbers. Owned by the caller, like every other field's value.
    easing: *Easing,
    /// The canvas is square; this is its side in pixels.
    size: f32 = 172.0,
    label_slot: f32 = 64.0,
    disabled: bool = false,
    /// A progress 0..1 to draw a moving dot at, or negative for none. The dot
    /// is what turns a picture of a curve into a picture of a curve being
    /// FOLLOWED, which is how a user tells an `ease` from an `ease_in_out`
    /// without reading the numbers.
    preview: f32 = -1.0,
    on_change: ?*const fn (ctx: ?*anyopaque) void = null,
    ctx_arg: ?*anyopaque = null,
};

/// Returns true when the curve changed this frame.
pub fn field(f: CurveField) bool {
    const t = &f.ctx.theme;
    const m = t.metrics;
    const pad: f32 = 12.0;

    widget.labelSlot(t, f.label, f.label_slot, f.size);
    cimgui.ember_ui_push_id_str(cimgui.text(f.id));

    const c0 = draw.cursorPos();
    const s0 = draw.cursorScreenPos();
    const hit = widget.submit(cimgui.text("curve"), f.size + m.gap() * 2.0, f.size + m.gap() * 2.0, f.disabled);
    const r = draw.itemRect();
    const delta = screenDelta(s0, c0);
    const list = draw.List.item();

    var changed = false;
    if (hit.active and !f.disabled) {
        const rel = relMouse(f.ctx, r, delta);
        const unit = fromCanvas(r, pad, rel);
        // Which handle: the nearer one. Locking to the nearer at the moment the
        // drag starts is enough — the user grabbed a specific dot, and it stays
        // the nearer one while they move it.
        const p1 = Vec2{ .x = f.easing.x1, .y = f.easing.y1 };
        const p2 = Vec2{ .x = f.easing.x2, .y = f.easing.y2 };
        const d1 = dist2(unit, p1);
        const d2 = dist2(unit, p2);
        const nx = std.math.clamp(unit.x, 0.0, 1.0);
        const ny = std.math.clamp(unit.y, -y_limit, 1.0 + y_limit);
        if (d1 <= d2) {
            if (f.easing.x1 != nx or f.easing.y1 != ny) {
                f.easing.x1 = nx;
                f.easing.y1 = ny;
                changed = true;
            }
        } else {
            if (f.easing.x2 != nx or f.easing.y2 != ny) {
                f.easing.x2 = nx;
                f.easing.y2 = ny;
                changed = true;
            }
        }
    }

    // ── Paint ────────────────────────────────────────────────────────────
    list.rect(r, theme.fill(t, hit.state), m.radius_sm());
    // A one-pixel grid at quarter steps, so a handle can be placed by eye and
    // not only by the number readout below it.
    var g: f32 = 0.25;
    while (g < 1.0) : (g += 0.25) {
        const a = toCanvas(r, pad, .{ .x = g, .y = 0.0 });
        const b = toCanvas(r, pad, .{ .x = g, .y = 1.0 });
        list.line(a, b, t.colors.border, 1.0);
        const c = toCanvas(r, pad, .{ .x = 0.0, .y = g });
        const d = toCanvas(r, pad, .{ .x = 1.0, .y = g });
        list.line(c, d, t.colors.border, 1.0);
    }

    const origin = toCanvas(r, pad, .{ .x = 0.0, .y = 0.0 });
    const top = toCanvas(r, pad, .{ .x = 1.0, .y = 1.0 });
    // The diagonal is linear easing. Every other curve is judged against it, so
    // drawing it is what lets a user see the shape rather than the pixels.
    list.line(origin, top, t.colors.border_strong, 1.0);

    // The control-point legs, from each endpoint to its handle.
    const h1 = toCanvas(r, pad, .{ .x = f.easing.x1, .y = f.easing.y1 });
    const h2 = toCanvas(r, pad, .{ .x = f.easing.x2, .y = f.easing.y2 });
    list.line(origin, h1, t.colors.accent.withAlpha(0.5), 1.0);
    list.line(top, h2, t.colors.accent.withAlpha(0.5), 1.0);

    // The curve itself. 48 segments is past the point where the human eye can
    // see the polyline at this size, and it is one path, so it is one draw
    // command rather than 48.
    drawCurve(list, f.easing.*, r, pad, t.colors.accent, 2.0);

    if (f.preview >= 0.0) {
        const py = f.easing.at(clamp01(f.preview));
        const dot = toCanvas(r, pad, .{ .x = clamp01(f.preview), .y = py });
        list.circle(dot, 3.5, t.colors.text);
        // The horizontal projection: where the value is, on the value axis.
        const left = toCanvas(r, pad, .{ .x = 0.0, .y = py });
        list.line(left, dot, t.colors.text_faint, 1.0);
    }

    list.circle(h1, 5.0, t.colors.accent);
    list.circle(h2, 5.0, t.colors.accent);
    list.circleOutline(h1, 6.5, t.colors.text, 1.5);
    list.circleOutline(h2, 6.5, t.colors.text, 1.5);

    list.rectOutline(
        r,
        if (hit.focused) t.colors.border_focus else if (hit.hovered) t.colors.border_strong else t.colors.border,
        m.radius_sm(),
        1.0,
    );

    cimgui.ember_ui_pop_id();
    if (changed) {
        if (f.on_change) |cb| cb(f.ctx_arg);
    }
    return changed;
}

fn drawCurve(list: draw.List, e: Easing, r: Rect, pad: f32, col: Rgba, thickness: f32) void {
    const segments: usize = 48;
    var prev = toCanvas(r, pad, .{ .x = 0.0, .y = 0.0 });
    var i: usize = 1;
    while (i <= segments) : (i += 1) {
        const x: f32 = @as(f32, @floatFromInt(i)) / @as(f32, @floatFromInt(segments));
        const p = toCanvas(r, pad, .{ .x = x, .y = e.at(x) });
        list.line(prev, p, col, thickness);
        prev = p;
    }
}

fn dist2(a: Vec2, b: Vec2) f32 {
    const dx = a.x - b.x;
    const dy = a.y - b.y;
    return dx * dx + dy * dy;
}

fn clamp01(x: f32) f32 {
    return std.math.clamp(x, 0.0, 1.0);
}

/// The four numbers as the string a project file or a tooltip shows them.
pub fn format(e: Easing, buf: []u8) []const u8 {
    return std.fmt.bufPrint(buf, "({d:.2}, {d:.2}, {d:.2}, {d:.2})", .{ e.x1, e.y1, e.x2, e.y2 }) catch "";
}

// ── Tests ────────────────────────────────────────────────────────────────

const testing = std.testing;

test "ui curve: the endpoints are exact for every preset" {
    // `at` short-circuits 0 and 1 for exactly this reason: a solver that lands
    // at 0.999 at the end of an animation is a sprite that never quite reaches
    // its destination, and the bug is invisible until it is a comparison.
    const presets = [_]Preset{ .linear, .ease, .ease_in, .ease_out, .ease_in_out, .back, .anticipate };
    for (presets) |p| {
        const e = p.easing();
        try testing.expectEqual(@as(f32, 0.0), e.at(0.0));
        try testing.expectEqual(@as(f32, 1.0), e.at(1.0));
    }
}

test "ui curve: linear easing is the identity" {
    const e = Preset.linear.easing();
    var x: f32 = 0.0;
    while (x <= 1.0) : (x += 0.1) {
        try testing.expectApproxEqAbs(x, e.at(x), 1e-4);
    }
    // And its velocity is exactly one everywhere: the number a caller scaling
    // one animation to another divides by.
    try testing.expectApproxEqAbs(@as(f32, 1.0), e.velocity(0.3), 1e-3);
    try testing.expectApproxEqAbs(@as(f32, 1.0), e.velocity(0.7), 1e-3);
}

test "ui curve: a symmetric easing passes through its midpoint" {
    // Ease-in-out is symmetric about (0.5, 0.5), and a solver that is off by a
    // few percent at the midpoint turns a clean transition into a visible hitch.
    const e = Preset.ease_in_out.easing();
    try testing.expectApproxEqAbs(@as(f32, 0.5), e.at(0.5), 2e-3);
}

test "ui curve: easing is monotone in x for the non-overshooting presets" {
    // `at` must not go backwards: a value that moves backward mid-animation is
    // the classic hand-written-solver bug, and this is the cheapest guard.
    const presets = [_]Preset{ .linear, .ease, .ease_in, .ease_out, .ease_in_out };
    for (presets) |p| {
        const e = p.easing();
        var prev = e.at(0.0);
        var i: usize = 1;
        while (i <= 100) : (i += 1) {
            const x = @as(f32, @floatFromInt(i)) / 100.0;
            const now = e.at(x);
            try testing.expect(now >= prev - 1e-4);
            prev = now;
        }
    }
}

test "ui curve: the back preset actually overshoots" {
    // The reason `y` is not clamped. If someone adds a clamp to `at`, this is
    // the test that fails rather than a designer's animation quietly changing.
    const e = Preset.back.easing();
    var peak: f32 = 0.0;
    var i: usize = 0;
    while (i <= 100) : (i += 1) {
        peak = @max(peak, e.at(@as(f32, @floatFromInt(i)) / 100.0));
    }
    try testing.expect(peak > 1.0 + 0.02);
    // And it comes back to exactly 1 at the end, as any easing must.
    try testing.expectEqual(@as(f32, 1.0), e.at(1.0));
}

test "ui curve: anticipate dips below zero before it rises" {
    const e = Preset.anticipate.easing();
    var min: f32 = 1.0;
    var i: usize = 0;
    while (i <= 100) : (i += 1) {
        min = @min(min, e.at(@as(f32, @floatFromInt(i)) / 100.0));
    }
    try testing.expect(min < -0.02);
}

test "ui curve: the solver inverts its own sample" {
    // The property that matters: for every x, the t `solveT` returns reproduces
    // that x through `sample`. Testing `at` alone would pass on a solver that
    // is wrong in the same way twice.
    const xs = [_]f32{ 0.05, 0.2, 0.5, 0.75, 0.9, 0.99 };
    for (xs) |x| {
        const t = solveT(x, 0.42, 0.58);
        try testing.expectApproxEqAbs(x, sample(t, 0.42, 0.58), 1e-4);
    }
}

test "ui curve: formatting is the CSS four-tuple" {
    var buf: [64]u8 = undefined;
    const s = format(Preset.ease.easing(), &buf);
    try testing.expectEqualStrings("(0.25, 0.10, 0.25, 1.00)", s);
}
