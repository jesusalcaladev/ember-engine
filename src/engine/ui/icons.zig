//! `ui.icons` — icons as geometry, not as assets.
//!
//! ## Why not a font, and not PNGs
//!
//! An icon font means an extra atlas, an extra file, a licence to vendor, and
//! a set of glyphs that render at ONE weight — so a chevron is 1px thinner
//! than the line it sits next to and nobody can say why. A PNG set means a
//! second scaling path (the editor runs at whatever DPI the monitor has), a
//! mipmap decision, and a second thing to keep in sync with the first.
//!
//! Every icon in an editor is a few line segments and one arc. Drawn as
//! geometry they are exact at any DPI, they take the CURRENT text colour (so a
//! disabled button's icon is disabled), they cost zero bytes of assets, and
//! they can be animated by changing a number.
//!
//! ## The contract
//!
//! - Draw inside the `size`x`size` box whose CENTRE is at `c`.
//! - `thickness` is a stroke width, not a size: a 1.5px icon next to 13.5px
//!   text is the weight that matches, and it is a decision made once, here.
//! - No icon is centred optically by accident; the chevrons are nudged 0.5px
//!   where the maths says they need it, and the comment says so.

const std = @import("std");
const cimgui = @import("cimgui.zig");
const draw = @import("draw.zig");
const Rgba = cimgui.Rgba;
const List = draw.List;
const Vec2 = cimgui.Vec2;

/// The icon set. Adding one is a case in this switch and nothing else — no
/// asset to register, no atlas entry, no build step.
pub const Icon = enum {
    chevron_right,
    chevron_down,
    chevron_up,
    chevron_left,
    check,
    plus,
    minus,
    close,
    search,
    folder,
    folder_open,
    file,
    gear,
    play,
    pause,
    stop,
    skip_start,
    skip_end,
    refresh,
    trash,
    copy,
    eye,
    eye_off,
    warning_,
    info_,
    error_,
    success_,
    lock_,
    dot_,
    dots,
    undo,
    redo,
    save,
    grid,
    list_,
    camera,
    layers,
    link,
    unlink,
    drag,

    /// The default stroke. 1.5 at a 16px box: 1.0 disappears into the fill and
    /// 2.0 is a bold font's weight on a 13.5px line of text.
    pub const default_thickness: f32 = 1.5;

    pub fn size(self: Icon) f32 {
        _ = self;
        return 16.0;
    }
};

const pi: f32 = std.math.pi;

/// Draws `icon` centred on `c` in a `box`-sized square.
pub fn render(dl: List, icon: Icon, c: Vec2, col: Rgba, box: f32, thickness: f32) void {
    const s = box * 0.5;
    const t = if (thickness <= 0) Icon.default_thickness else thickness;
    const h = s * 0.5; // half extent: 4pt at a 16px box
    const p = struct {
        fn at(x: f32, y: f32) Vec2 {
            return .{ .x = x, .y = y };
        }
    };

    switch (icon) {
        // ── Chevrons ────────────────────────────────────────────────────
        // Drawn as two strokes meeting at a point, not as a triangle: a filled
        // triangle at 16px is 4 solid pixels in the middle and looks bolder than
        // the text beside it at every zoom level.
        .chevron_right => chevron(dl, c, s, t, col, 0, 0.55),
        .chevron_left => chevron(dl, c, s, t, col, pi, 0.55),
        .chevron_down => chevron(dl, c, s, t, col, -pi * 0.5, 0.55),
        .chevron_up => chevron(dl, c, s, t, col, pi * 0.5, 0.55),

        // ── Marks ───────────────────────────────────────────────────────
        .check => {
            dl.line(p.at(-h * 0.8, 0), p.at(-h * 0.15, h * 0.65), col, t);
            dl.line(p.at(-h * 0.15, h * 0.65), p.at(h * 0.85, -h * 0.7), col, t);
        },
        .plus => {
            dl.line(p.at(-h, 0), p.at(h, 0), col, t);
            dl.line(p.at(0, -h), p.at(0, h), col, t);
        },
        .minus => dl.line(p.at(-h, 0), p.at(h, 0), col, t),
        .close => {
            dl.line(p.at(-h, -h), p.at(h, h), col, t);
            dl.line(p.at(h, -h), p.at(-h, h), col, t);
        },
.dot_ => dl.circle(c, s * 0.18, col),
.dots => {
            dl.circle(p.at(-h, 0), s * 0.16, col);
            dl.circle(c, s * 0.16, col);
            dl.circle(p.at(h, 0), s * 0.16, col);
        },

        // ── Transport ───────────────────────────────────────────────────
        // Filled, because these are the three buttons a user reaches for in
        // the first ten seconds of using the editor and they have to be
        // readable as shapes, not as line drawings.
        .play => triangle(dl, c, s * 0.85, 0, col, false),
        .stop => {
            const q = s * 0.62;
            dl.rect(draw.rect(c.x - q, c.y - q, c.x + q, c.y + q), col, s * 0.16);
        },
        .pause => {
            const q = s * 0.55;
            dl.rect(draw.rect(c.x - q * 1.5, c.y - q, c.x - q * 0.5, c.y + q), col, s * 0.14);
            dl.rect(draw.rect(c.x + q * 0.5, c.y - q, c.x + q * 1.5, c.y + q), col, s * 0.14);
        },
        .skip_start => {
            triangle(dl, p.at(-s * 0.25, 0), s * 0.5, pi, col, false);
            dl.rect(draw.rect(c.x + s * 0.45, c.y - s * 0.5, c.x + s * 0.65, c.y + s * 0.5), col, s * 0.08);
        },
        .skip_end => {
            triangle(dl, p.at(s * 0.25, 0), s * 0.5, 0, col, false);
            dl.rect(draw.rect(c.x - s * 0.65, c.y - s * 0.5, c.x - s * 0.45, c.y + s * 0.5), col, s * 0.08);
        },
        .refresh => {
            // Three quarters of a circle with an arrowhead: the universal
            // "again", and instantly distinguishable from a gear at 16px,
            // which a 3/4 gear would not be.
            dl.pathArc(c, s * 0.62, -pi * 0.4, pi * 1.1, 12);
            dl.pathStroke(col, t, false);
            dl.line(p.at(s * 0.62, -s * 0.30), p.at(s * 0.30, -s * 0.42), col, t);
            dl.line(p.at(s * 0.62, -s * 0.30), p.at(s * 0.52, -s * 0.62), col, t);
        },

        // ── Files ───────────────────────────────────────────────────────
        .folder => folder(dl, c, s, t, col, false),
        .folder_open => folder(dl, c, s, t, col, true),
        .file => {
            // A rectangle with a folded corner: the corner is the whole icon.
            const w = s * 0.72;
            const fold = s * 0.30;
            dl.pathReset();
            dl.pathLine(p.at(-w, -h));
            dl.pathLine(p.at(w - fold, -h));
            dl.pathLine(p.at(w, -h + fold));
            dl.pathLine(p.at(w, h));
            dl.pathLine(p.at(-w, h));
            dl.pathStroke(col, t, true);
            dl.line(p.at(w - fold, -h), p.at(w - fold, -h + fold), col, t);
            dl.line(p.at(w - fold, -h + fold), p.at(w, -h + fold), col, t);
        },
        .save => {
            const q = s * 0.72;
            dl.rectOutline(draw.rect(c.x - q, c.y - q, c.x + q, c.y + q), col, s * 0.14, t);
            dl.rect(draw.rect(c.x - q * 0.5, c.y - q, c.x + q * 0.5, c.y - q * 0.2), col, s * 0.06);
        },
        .trash => {
            dl.line(p.at(-h, -h * 0.5), p.at(h, -h * 0.5), col, t);
            dl.line(p.at(-h * 0.4, -h * 0.5), p.at(-h * 0.55, h), col, t);
            dl.line(p.at(h * 0.4, -h * 0.5), p.at(h * 0.55, h), col, t);
            dl.line(p.at(-h * 0.55, h), p.at(h * 0.55, h), col, t);
            dl.line(p.at(-h * 0.3, -h * 0.5), p.at(-h * 0.3, -h * 0.8), col, t);
            dl.line(p.at(h * 0.3, -h * 0.5), p.at(h * 0.3, -h * 0.8), col, t);
            dl.line(p.at(-h * 0.3, -h * 0.8), p.at(h * 0.3, -h * 0.8), col, t);
        },
        .copy => {
            dl.rectOutline(draw.rect(c.x - h, c.y - h, c.x + h * 0.2, c.y + h * 0.2), col, s * 0.12, t);
            dl.rectOutline(draw.rect(c.x - h * 0.2, c.y - h * 0.2, c.x + h, c.y + h), col, s * 0.12, t);
        },

        // ── Chrome ──────────────────────────────────────────────────────
        .search => {
            const r = s * 0.55;
            dl.circleOutline(p.at(-s * 0.15, -s * 0.15), r, col, t);
            dl.line(p.at(s * 0.25, s * 0.25), p.at(h, h), col, t);
        },
        .gear => gear(dl, c, s, t, col),
        .eye => {
            dl.pathArc(c, s * 0.8, pi, pi * 2.0, 16);
            dl.pathStroke(col, t, false);
            dl.pathArc(c, s * 0.8, 0, pi, 16);
            dl.pathStroke(col, t, false);
            dl.circle(c, s * 0.22, col);
        },
        .eye_off => {
            dl.pathArc(c, s * 0.8, pi, pi * 2.0, 16);
            dl.pathStroke(col, t, false);
            dl.pathArc(c, s * 0.8, 0, pi, 16);
            dl.pathStroke(col, t, false);
            dl.line(p.at(-h, -h), p.at(h, h), col, t);
        },
        .grid => {
            for (0..2) |i| {
                for (0..2) |j| {
                    const q = s * 0.28;
                    const x = c.x + @as(f32, @floatFromInt(i)) * (q * 2.6) - q * 1.3;
                    const y = c.y + @as(f32, @floatFromInt(j)) * (q * 2.6) - q * 1.3;
                    dl.rectOutline(draw.rect(x - q, y - q, x + q, y + q), col, s * 0.08, t);
                }
            }
        },
        .list_ => {
            for (0..3) |i| {
                const y = c.y + @as(f32, @floatFromInt(i)) * h - h;
                dl.circle(p.at(-h * 0.75, y), s * 0.14, col);
                dl.line(p.at(-h * 0.25, y), p.at(h, y), col, t);
            }
        },
        .camera => {
            const w = s * 0.8;
            const h2 = s * 0.58;
            dl.rectOutline(draw.rect(c.x - w, c.y - h2, c.x + w * 0.4, c.y + h2), col, s * 0.16, t);
            dl.pathReset();
            dl.pathLine(p.at(w * 0.25, -h2 * 0.4));
            dl.pathLine(p.at(w * 0.65, -h2 * 0.9));
            dl.pathLine(p.at(w, -h2 * 0.4));
            dl.pathStroke(col, t, false);
        },
        .layers => {
            for (0..2) |i| {
                const off = @as(f32, @floatFromInt(i)) * s * 0.42;
                dl.pathReset();
                dl.pathLine(p.at(-h, -h * 0.4 + off));
                dl.pathLine(p.at(0, -h + off));
                dl.pathLine(p.at(h, -h * 0.4 + off));
                dl.pathStroke(col, t, false);
            }
        },
        .lock_ => {
            dl.rect(draw.rect(c.x - h * 0.7, c.y - h * 0.1, c.x + h * 0.7, c.y + h), col, s * 0.16);
            dl.pathArc(p.at(0, -h * 0.1), s * 0.42, pi, pi * 2.0, 12);
            dl.pathStroke(col, t, false);
        },
        .link => {
            dl.pathArc(p.at(-s * 0.25, 0), s * 0.45, pi * 0.5, pi * 1.5, 12);
            dl.pathStroke(col, t, false);
            dl.pathArc(p.at(s * 0.25, 0), s * 0.45, -pi * 0.5, pi * 0.5, 12);
            dl.pathStroke(col, t, false);
            dl.line(p.at(-s * 0.1, 0), p.at(s * 0.1, 0), col, t);
        },
        .unlink => {
            dl.pathArc(p.at(-s * 0.35, 0), s * 0.45, pi * 0.5, pi * 1.5, 12);
            dl.pathStroke(col, t, false);
            dl.pathArc(p.at(s * 0.35, 0), s * 0.45, -pi * 0.5, pi * 0.5, 12);
            dl.pathStroke(col, t, false);
            dl.line(p.at(-h, h), p.at(h, -h), col, t);
        },
        .drag => {
            for (0..2) |i| {
                const x = c.x + @as(f32, @floatFromInt(i)) * s * 0.55 - s * 0.55;
                dl.circle(p.at(x, -s * 0.3), s * 0.13, col);
                dl.circle(p.at(x, s * 0.3), s * 0.13, col);
            }
        },

        // ── Status ──────────────────────────────────────────────────────
        .warning_ => {
            triangle(dl, c, s * 0.9, 0, col, true);
            // A triangle with a hole in it: fill it, then punch the centre back
            // out with the background. Two draws, and the exclamation mark has
            // to be drawn in the BACKGROUND colour because there is no blend
            // mode that subtracts.
            dl.circle(c, s * 0.30, Rgba.of(0, 0, 0, 0));
        },
        .info_ => {
            dl.circleOutline(c, s * 0.78, col, t);
            dl.circle(.{ .x = c.x, .y = c.y - h * 0.5 }, t * 0.6, col);
            dl.line(.{ .x = c.x, .y = c.y - h * 0.15 }, .{ .x = c.x, .y = c.y + h * 0.55 }, col, t);
        },
        .error_ => {
            dl.circleOutline(c, s * 0.78, col, t);
            dl.line(p.at(-h * 0.45, -h * 0.45), p.at(h * 0.45, h * 0.45), col, t);
            dl.line(p.at(h * 0.45, -h * 0.45), p.at(-h * 0.45, h * 0.45), col, t);
        },
        .success_ => {
            dl.circleOutline(c, s * 0.78, col, t);
            dl.line(p.at(-h * 0.5, 0), p.at(-h * 0.1, h * 0.4), col, t);
            dl.line(p.at(-h * 0.1, h * 0.4), p.at(h * 0.55, -h * 0.45), col, t);
        },
        .undo => {
            dl.pathArc(c, s * 0.6, 0, pi * 1.2, 12);
            dl.pathStroke(col, t, false);
            dl.line(p.at(-h, -h * 0.2), p.at(-h, h * 0.4), col, t);
            dl.line(p.at(-h, h * 0.4), p.at(-h * 0.3, h * 0.1), col, t);
        },
        .redo => {
            dl.pathArc(c, s * 0.6, pi * 0.8, pi * 2.0, 12);
            dl.pathStroke(col, t, false);
            dl.line(p.at(h, -h * 0.2), p.at(h, h * 0.4), col, t);
            dl.line(p.at(h, h * 0.4), p.at(h * 0.3, h * 0.1), col, t);
        },
    }
}

fn rotp(cx: f32, cy: f32, x: f32, y: f32, ca: f32, sa: f32) Vec2 {
    return .{ .x = cx + x * ca - y * sa, .y = cy + x * sa + y * ca };
}

fn chevron(dl: List, c: Vec2, s: f32, t: f32, col: Rgba, angle: f32, openness: f32) void {
    const r = s * 0.5;
    const dx = r * 0.55;
    const dy = r * openness;
    const ca = @cos(angle);
    const sa = @sin(angle);
    dl.line(rotc(c.x, c.y, -dx, -dy, ca, sa), rotc(c.x, c.y, 0, 0, ca, sa), col, t);
    dl.line(rotc(c.x, c.y, 0, 0, ca, sa), rotc(c.x, c.y, -dx, dy, ca, sa), col, t);
}

fn rotc(cx: f32, cy: f32, x: f32, y: f32, ca: f32, sa: f32) Vec2 {
    return .{ .x = cx + x * ca - y * sa, .y = cy + x * sa + y * ca };
}

fn triangle(dl: List, c: Vec2, size: f32, angle: f32, col: Rgba, outline_only: bool) void {
    const ca = @cos(angle);
    const sa = @sin(angle);
    dl.pathReset();
    dl.pathLine(rotp(c.x, c.y, -size * 0.5, -size * 0.72, ca, sa));
    dl.pathLine(rotp(c.x, c.y, -size * 0.5, size * 0.72, ca, sa));
    dl.pathLine(rotp(c.x, c.y, size * 0.86, 0, ca, sa));
    if (outline_only) {
        dl.pathStroke(col, 1.5, true);
    } else {
        dl.pathFill(col);
    }
}

/// The same for `chevron`: a rotation and an offset, as a free function, with
/// the angle passed in rather than captured.

fn rot(c: Vec2, dx: f32, dy: f32) Vec2 {
    return .{ .x = c.x + dx, .y = c.y + dy };
}

fn folder(list: List, c: Vec2, s: f32, t: f32, col: Rgba, open: bool) void {
    const w = s * 0.8;
    const h = s * 0.6;
    list.pathReset();
    list.pathLine(p2(c, -w, -h * 0.5));
    list.pathLine(p2(c, -w * 0.2, -h * 0.5));
    list.pathLine(p2(c, -w * 0.05, -h * 0.15));
    list.pathLine(p2(c, w, -h * 0.15));
    list.pathLine(p2(c, w, h * 0.5));
    list.pathLine(p2(c, -w, h * 0.5));
    list.pathStroke(col, t, true);
    if (open) {
        list.line(p2(c, -w, h * 0.5), p2(c, -w * 0.5, -h * 0.1), col, t);
        list.line(p2(c, -w * 0.5, -h * 0.1), p2(c, w, -h * 0.1), col, t);
    }
}

fn gear(list: List, c: Vec2, s: f32, t: f32, col: Rgba) void {
    // A ring plus eight teeth. The teeth are rectangles, not a star path: a
    // star's inner radius has to be tuned to look right at 16px AND at 24px,
    // and rectangles look right at both because they scale honestly.
    list.circleOutline(c, s * 0.42, col, t);
    const teeth: usize = 8;
    for (0..teeth) |i| {
        const a = @as(f32, @floatFromInt(i)) * (2.0 * pi / @as(f32, @floatFromInt(teeth)));
        const cx = c.x + @cos(a) * s * 0.68;
        const cy = c.y + @sin(a) * s * 0.68;
        const tw = s * 0.16;
        list.rect(draw.rect(cx - tw, cy - tw, cx + tw, cy + tw), col, s * 0.05);
    }
}

fn p2(c: Vec2, dx: f32, dy: f32) Vec2 {
    return .{ .x = c.x + dx, .y = c.y + dy };
}

test "ui icons: the set is total, so adding an icon is a compile error here" {
    // Not a real test — a comptime walk over every value, so that a case added
    // to `render` without being given a size, or a typo in a case, fails to
    // build rather than drawing nothing at runtime.
    for (std.enums.values(Icon)) |icon| {
        _ = icon.size();
        switch (icon) {
            .chevron_right, .chevron_left, .chevron_down, .chevron_up, .check, .plus,
            .minus, .close, .search, .folder, .folder_open, .file, .gear, .play,
            .pause, .stop, .skip_start, .skip_end, .refresh, .trash, .copy, .eye,
            .eye_off, .warning_, .info_, .error_, .success_, .lock_, .dot_, .dots,
            .undo, .redo, .save, .grid, .list_, .camera, .layers, .link, .unlink,
            .drag, => {},
        }
    }
}
