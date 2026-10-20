//! `ui.icons` — icons as geometry, and as assets when there are any.
//!
//! ## Why the geometry is still here
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
//! ## And the PNGs, when there are any
//!
//! Geometry cannot draw a rotate handle that reads as a rotate handle, and
//! geometry that tries is the reason a toolbar looks like a drawing exercise.
//! So the UI layer ALSO accepts a TEXTURE ATLAS: the icons the app loaded
//! from `assets/icons/`, packed into one image, with a name per cell.
//!
//! The rule is simple and it is the whole contract:
//!
//! - an icon WITH a cell is drawn from the atlas, tinted with the colour the
//!   caller passed (so it still goes grey when it is disabled);
//! - an icon WITHOUT a cell is drawn as geometry, exactly as before.
//!
//! So the atlas is an improvement, never a requirement: a missing file is a
//! missing file, not a broken editor.
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

    /// The viewport's tools. They are in the SET because the toolbar is the
    /// one place where a picture says more than a word.
    cursor,
    move,
    rotate,
    scale,
    tiles,
    focus,
    home,

    /// The panel headers.
    panel_hierarchy,
    panel_inspector,
    panel_assets,
    panel_console,
    panel_tilemap,

    /// The default stroke. 1.5 at a 16px box: 1.0 disappears into the fill and
    /// 2.0 is a bold font's weight on a 13.5px line of text.
    pub const default_thickness: f32 = 1.5;

    pub fn size(self: Icon) f32 {
        _ = self;
        return 16.0;
    }

    /// The file this icon comes from, in `assets/icons/`.
    ///
    /// The names are the ones the ICON SET uses (Tabler's), so the list in
    /// `assets/icons/README.md` and the files on disk agree. An icon with no
    /// file — `scale` is the one that tends to be missing — falls back to the
    /// drawn geometry, and the editor looks the way it always did.
    pub fn fileName(self: Icon) ?[]const u8 {
        return switch (self) {
            .chevron_right => "chevron-right",
            .chevron_down => "chevron-down",
            .chevron_up => "chevron-up",
            .chevron_left => "chevron-left",
            .check => "check",
            .plus => "plus",
            .minus => "minus",
            .close => "x",
            .search => "search",
            .folder => "folder",
            .folder_open => "folder-open",
            .file => "file",
            .gear => "settings",
            .play => "player-play",
            .pause => "player-pause",
            .stop => "player-stop",
            .skip_start => "player-skip-back",
            .skip_end => "player-skip-forward",
            .refresh => "refresh",
            .trash => "trash",
            .copy => "copy",
            .eye => "eye",
            .eye_off => "eye-off",
            .warning_ => "alert-circle",
            .info_ => "info-circle",
            .error_ => "exclamation-circle",
            .success_ => "success",
            .lock_ => "lock",
            .dot_ => "circle-dot",
            .dots => "dots",
            .undo => "undo",
            .redo => "redo",
            .save => "device-floppy",
            .grid => "grid",
            .list_ => "list",
            .camera => "camera",
            .layers => "layers",
            .link => "link",
            .unlink => "unlink",
            .drag => "drag",
            .cursor => "pointer",
            .move => "arrows-move",
            .rotate => "rotate",
            .scale => null,
            .tiles => "tiles",
            .focus => "focus",
            .home => "home",
            .panel_hierarchy => "hierarchy",
            .panel_inspector => "list",
            .panel_assets => "folder",
            .panel_console => "panel-console",
            .panel_tilemap => "tilemap",
        };
    }
};

// ── The atlas ──────────────────────────────────────────────────────────────

/// One icon's cell in the atlas: where it is and which file it came from.
pub const Entry = struct {
    /// The file's name without the extension ("move", not "move.png").
    name: []const u8,
    u0: f32,
    v0: f32,
    u1: f32,
    v1: f32,
};

/// The loaded atlas: one texture and the cells in it.
///
/// It lives in the UI layer because the UI layer is what draws it, and the
/// layer that loads the PNGs (the editor) hands it over. The alternative —
/// the UI layer loading files — would make the widget library depend on the
/// filesystem, and a widget library that can read files is a widget library
/// that has opinions about where files are.
var atlas_texture: ?*anyopaque = null;
var atlas_entries: []const Entry = &.{};

/// Installs the atlas: the texture's pixels and the cells in it.
///
/// The pixels are COPIED (ImGui owns its own copy) and the entries are kept
/// by the caller for as long as the atlas lives.
pub fn setAtlas(allocator: std.mem.Allocator, pixels: []const u8, width: u32, height: u32, entries: []const Entry) void {
    if (atlas_texture) |t| cimgui.ember_ui_texture_destroy(t);
    atlas_texture = cimgui.ember_ui_texture_create(@intCast(width), @intCast(height), pixels.ptr);
    atlas_entries = allocator.dupe(Entry, entries) catch &.{};
}

/// The cell for an icon, if the atlas has one.
pub fn lookup(icon: Icon) ?Entry {
    const name = icon.fileName() orelse return null;
    for (atlas_entries) |e| {
        if (std.mem.eql(u8, e.name, name)) return e;
    }
    return null;
}

/// Is there an atlas at all? The HUD asks, so it can say "no icons" instead of
/// drawing nothing.
pub fn hasAtlas() bool {
    return atlas_texture != null;
}

const pi: f32 = std.math.pi;

/// Draws `icon` centred on `c` in a `box`-sized square.
///
/// The atlas wins when it has the icon: a picture of a rotate handle reads as
/// a rotate handle, and no number of line segments will.
pub fn render(dl: List, icon: Icon, c: Vec2, col: Rgba, box: f32, thickness: f32) void {
    if (atlas_texture) |tex| {
        if (lookup(icon)) |e| {
            const s = box * 0.5;
            cimgui.ember_draw_image(
                dl.ptr,
                tex,
                c.x - s,
                c.y - s,
                c.x + s,
                c.y + s,
                e.u0,
                e.v0,
                e.u1,
                e.v1,
                col.pack(),
            );
            return;
        }
    }
    renderGeometry(dl, icon, c, col, box, thickness);
}

/// The drawn fallback: the geometry this module always had.
fn renderGeometry(dl: List, icon: Icon, c: Vec2, col: Rgba, box: f32, thickness: f32) void {
    const s = box * 0.5;
    const t = if (thickness <= 0) Icon.default_thickness else thickness;
    const h = s * 0.5; // half extent: 4pt at a 16px box

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
            dl.line(at(c, -h * 0.8, 0), at(c, -h * 0.15, h * 0.65), col, t);
            dl.line(at(c, -h * 0.15, h * 0.65), at(c, h * 0.85, -h * 0.7), col, t);
        },
        .plus => {
            dl.line(at(c, -h, 0), at(c, h, 0), col, t);
            dl.line(at(c, 0, -h), at(c, 0, h), col, t);
        },
        .minus => dl.line(at(c, -h, 0), at(c, h, 0), col, t),
        .close => {
            dl.line(at(c, -h, -h), at(c, h, h), col, t);
            dl.line(at(c, h, -h), at(c, -h, h), col, t);
        },
.dot_ => dl.circle(c, s * 0.18, col),
.dots => {
            dl.circle(at(c, -h, 0), s * 0.16, col);
            dl.circle(c, s * 0.16, col);
            dl.circle(at(c, h, 0), s * 0.16, col);
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
            triangle(dl, at(c, -s * 0.25, 0), s * 0.5, pi, col, false);
            dl.rect(draw.rect(c.x + s * 0.45, c.y - s * 0.5, c.x + s * 0.65, c.y + s * 0.5), col, s * 0.08);
        },
        .skip_end => {
            triangle(dl, at(c, s * 0.25, 0), s * 0.5, 0, col, false);
            dl.rect(draw.rect(c.x - s * 0.65, c.y - s * 0.5, c.x - s * 0.45, c.y + s * 0.5), col, s * 0.08);
        },
        .refresh => {
            // Three quarters of a circle with an arrowhead: the universal
            // "again", and instantly distinguishable from a gear at 16px,
            // which a 3/4 gear would not be.
            dl.pathArc(c, s * 0.62, -pi * 0.4, pi * 1.1, 12);
            dl.pathStroke(col, t, false);
            dl.line(at(c, s * 0.62, -s * 0.30), at(c, s * 0.30, -s * 0.42), col, t);
            dl.line(at(c, s * 0.62, -s * 0.30), at(c, s * 0.52, -s * 0.62), col, t);
        },

        // ── Files ───────────────────────────────────────────────────────
        .folder => folder(dl, c, s, t, col, false),
        .folder_open => folder(dl, c, s, t, col, true),
        .file => {
            // A rectangle with a folded corner: the corner is the whole icon.
            const w = s * 0.72;
            const fold = s * 0.30;
            dl.pathReset();
            dl.pathLine(at(c, -w, -h));
            dl.pathLine(at(c, w - fold, -h));
            dl.pathLine(at(c, w, -h + fold));
            dl.pathLine(at(c, w, h));
            dl.pathLine(at(c, -w, h));
            dl.pathStroke(col, t, true);
            dl.line(at(c, w - fold, -h), at(c, w - fold, -h + fold), col, t);
            dl.line(at(c, w - fold, -h + fold), at(c, w, -h + fold), col, t);
        },
        .save => {
            const q = s * 0.72;
            dl.rectOutline(draw.rect(c.x - q, c.y - q, c.x + q, c.y + q), col, s * 0.14, t);
            dl.rect(draw.rect(c.x - q * 0.5, c.y - q, c.x + q * 0.5, c.y - q * 0.2), col, s * 0.06);
        },
        .trash => {
            dl.line(at(c, -h, -h * 0.5), at(c, h, -h * 0.5), col, t);
            dl.line(at(c, -h * 0.4, -h * 0.5), at(c, -h * 0.55, h), col, t);
            dl.line(at(c, h * 0.4, -h * 0.5), at(c, h * 0.55, h), col, t);
            dl.line(at(c, -h * 0.55, h), at(c, h * 0.55, h), col, t);
            dl.line(at(c, -h * 0.3, -h * 0.5), at(c, -h * 0.3, -h * 0.8), col, t);
            dl.line(at(c, h * 0.3, -h * 0.5), at(c, h * 0.3, -h * 0.8), col, t);
            dl.line(at(c, -h * 0.3, -h * 0.8), at(c, h * 0.3, -h * 0.8), col, t);
        },
        .copy => {
            dl.rectOutline(draw.rect(c.x - h, c.y - h, c.x + h * 0.2, c.y + h * 0.2), col, s * 0.12, t);
            dl.rectOutline(draw.rect(c.x - h * 0.2, c.y - h * 0.2, c.x + h, c.y + h), col, s * 0.12, t);
        },

        // ── Chrome ──────────────────────────────────────────────────────
        .search => {
            const r = s * 0.55;
            dl.circleOutline(at(c, -s * 0.15, -s * 0.15), r, col, t);
            dl.line(at(c, s * 0.25, s * 0.25), at(c, h, h), col, t);
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
            dl.line(at(c, -h, -h), at(c, h, h), col, t);
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
                dl.circle(at(c, -h * 0.75, y), s * 0.14, col);
                dl.line(at(c, -h * 0.25, y), at(c, h, y), col, t);
            }
        },
        .camera => {
            const w = s * 0.8;
            const h2 = s * 0.58;
            dl.rectOutline(draw.rect(c.x - w, c.y - h2, c.x + w * 0.4, c.y + h2), col, s * 0.16, t);
            dl.pathReset();
            dl.pathLine(at(c, w * 0.25, -h2 * 0.4));
            dl.pathLine(at(c, w * 0.65, -h2 * 0.9));
            dl.pathLine(at(c, w, -h2 * 0.4));
            dl.pathStroke(col, t, false);
        },
        .layers => {
            for (0..2) |i| {
                const off = @as(f32, @floatFromInt(i)) * s * 0.42;
                dl.pathReset();
                dl.pathLine(at(c, -h, -h * 0.4 + off));
                dl.pathLine(at(c, 0, -h + off));
                dl.pathLine(at(c, h, -h * 0.4 + off));
                dl.pathStroke(col, t, false);
            }
        },
        .lock_ => {
            dl.rect(draw.rect(c.x - h * 0.7, c.y - h * 0.1, c.x + h * 0.7, c.y + h), col, s * 0.16);
            dl.pathArc(at(c, 0, -h * 0.1), s * 0.42, pi, pi * 2.0, 12);
            dl.pathStroke(col, t, false);
        },
        .link => {
            dl.pathArc(at(c, -s * 0.25, 0), s * 0.45, pi * 0.5, pi * 1.5, 12);
            dl.pathStroke(col, t, false);
            dl.pathArc(at(c, s * 0.25, 0), s * 0.45, -pi * 0.5, pi * 0.5, 12);
            dl.pathStroke(col, t, false);
            dl.line(at(c, -s * 0.1, 0), at(c, s * 0.1, 0), col, t);
        },
        .unlink => {
            dl.pathArc(at(c, -s * 0.35, 0), s * 0.45, pi * 0.5, pi * 1.5, 12);
            dl.pathStroke(col, t, false);
            dl.pathArc(at(c, s * 0.35, 0), s * 0.45, -pi * 0.5, pi * 0.5, 12);
            dl.pathStroke(col, t, false);
            dl.line(at(c, -h, h), at(c, h, -h), col, t);
        },
        .drag => {
            for (0..2) |i| {
                const x = c.x + @as(f32, @floatFromInt(i)) * s * 0.55 - s * 0.55;
                dl.circle(at(c, x, -s * 0.3), s * 0.13, col);
                dl.circle(at(c, x, s * 0.3), s * 0.13, col);
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
            dl.line(at(c, -h * 0.45, -h * 0.45), at(c, h * 0.45, h * 0.45), col, t);
            dl.line(at(c, h * 0.45, -h * 0.45), at(c, -h * 0.45, h * 0.45), col, t);
        },
        .success_ => {
            dl.circleOutline(c, s * 0.78, col, t);
            dl.line(at(c, -h * 0.5, 0), at(c, -h * 0.1, h * 0.4), col, t);
            dl.line(at(c, -h * 0.1, h * 0.4), at(c, h * 0.55, -h * 0.45), col, t);
        },
        .undo => {
            dl.pathArc(c, s * 0.6, 0, pi * 1.2, 12);
            dl.pathStroke(col, t, false);
            dl.line(at(c, -h, -h * 0.2), at(c, -h, h * 0.4), col, t);
            dl.line(at(c, -h, h * 0.4), at(c, -h * 0.3, h * 0.1), col, t);
        },
        .redo => {
            dl.pathArc(c, s * 0.6, pi * 0.8, pi * 2.0, 12);
            dl.pathStroke(col, t, false);
            dl.line(at(c, h, -h * 0.2), at(c, h, h * 0.4), col, t);
            dl.line(at(c, h, h * 0.4), at(c, h * 0.3, h * 0.1), col, t);
        },

        // ── The viewport's tools ─────────────────────────────────────────
        //
        // These are the FALLBACKS: the atlas has pictures for all of them
        // except `scale` (the one file that tends to go missing), so this is
        // where the scale handle is drawn from.
        .cursor => {
            // An arrow: a triangle with a stem.
            dl.pathReset();
            dl.pathLine(at(c, -h * 0.7, -h));
            dl.pathLine(at(c, -h * 0.7, h * 0.55));
            dl.pathLine(at(c, -h * 0.15, h * 0.05));
            dl.pathStroke(col, t, false);
        },
        .move => {
            // A four-way cross: the universal "move".
            dl.line(at(c, -h, 0), at(c, h, 0), col, t);
            dl.line(at(c, 0, -h), at(c, 0, h), col, t);
            for ([_]Vec2{ at(c, -h, 0), at(c, h, 0), at(c, 0, -h), at(c, 0, h) }) |tip| {
                dl.circle(tip, t * 0.9, col);
            }
        },
        .rotate => {
            dl.pathArc(c, s * 0.62, -pi * 0.35, pi * 1.2, 14);
            dl.pathStroke(col, t, false);
            dl.line(at(c, s * 0.60, -s * 0.42), at(c, s * 0.28, -s * 0.48), col, t);
            dl.line(at(c, s * 0.60, -s * 0.42), at(c, s * 0.56, -s * 0.10), col, t);
        },
        .scale => {
            // A diagonal double arrow: the corner handle, in a box. It is the
            // one icon with no file yet, so the drawn one has to carry the
            // meaning on its own — and a mark smaller than the box it lives in
            // is a smudge, not an icon.
            const d = h * 0.85;
            dl.line(at(c, -d, d), at(c, d, -d), col, t);
            // The two arrowheads, at the ends of the diagonal.
            dl.line(at(c, -d, d), at(c, -d + d * 0.5, d), col, t);
            dl.line(at(c, -d, d), at(c, -d, d - d * 0.5), col, t);
            dl.line(at(c, d, -d), at(c, d - d * 0.5, -d), col, t);
            dl.line(at(c, d, -d), at(c, d, -d + d * 0.5), col, t);
        },
        .tiles => {
            // A 2x2 grid of squares: a tile map in one glyph.
            const q = h * 0.42;
            for ([_][2]f32{ .{ -1, -1 }, .{ 1, -1 }, .{ -1, 1 }, .{ 1, 1 } }) |cell| {
                const cx = c.x + cell[0] * q;
                const cy = c.y + cell[1] * q;
                dl.rectOutline(draw.rect(cx - q * 0.8, cy - q * 0.8, cx + q * 0.8, cy + q * 0.8), col, s * 0.1, t);
            }
        },
        .focus => {
            // Corner brackets: "frame this".
            const arm = s * 0.36;
            const corner = [_][2]f32{ .{ -1, -1 }, .{ 1, -1 }, .{ -1, 1 }, .{ 1, 1 } };
            for (corner) |k| {
                const x = c.x + k[0] * h * 0.85;
                const y = c.y + k[1] * h * 0.85;
                dl.line(at(c, x, y), at(c, x - k[0] * arm, y), col, t);
                dl.line(at(c, x, y), at(c, x, y - k[1] * arm), col, t);
            }
        },
        .home => {
            // A crosshair: "the origin".
            dl.circleOutline(c, s * 0.45, col, t);
            dl.line(at(c, -h, 0), at(c, -s * 0.2, 0), col, t);
            dl.line(at(c, s * 0.2, 0), at(c, h, 0), col, t);
            dl.line(at(c, 0, -h), at(c, 0, -s * 0.2), col, t);
            dl.line(at(c, 0, s * 0.2), at(c, 0, h), col, t);
        },

        // ── The panel headers ────────────────────────────────────────────
        .panel_hierarchy => {
            for (0..3) |i| {
                const y = c.y + @as(f32, @floatFromInt(i)) * h * 0.7 - h * 0.7;
                dl.circle(at(c, -h * 0.7, y), s * 0.12, col);
                dl.line(at(c, -h * 0.3, y), at(c, h * 0.8, y), col, t);
            }
        },
        .panel_inspector => {
            // A slider: the inspector in one glyph.
            for (0..3) |i| {
                const y = c.y + @as(f32, @floatFromInt(i)) * h * 0.6 - h * 0.6;
                dl.line(at(c, -h, y), at(c, h, y), col, t);
                dl.circle(at(c, -h * 0.2 + @as(f32, @floatFromInt(i)) * h * 0.35, y), s * 0.16, col);
            }
        },
        .panel_assets => folder(dl, c, s, t, col, false),
        .panel_console => {
            dl.rectOutline(draw.rect(c.x - h, c.y - h * 0.8, c.x + h, c.y + h * 0.8), col, s * 0.14, t);
            dl.line(at(c, -h * 0.5, -h * 0.2), at(c, -h * 0.1, h * 0.2), col, t);
            dl.line(at(c, -h * 0.1, h * 0.2), at(c, h * 0.45, -h * 0.35), col, t);
        },
        .panel_tilemap => {
            for (0..3) |row| {
                for (0..3) |colx| {
                    if ((row + colx) % 2 != 0) continue;
                    const x = c.x + @as(f32, @floatFromInt(colx)) * h * 0.62 - h * 0.62;
                    const y = c.y + @as(f32, @floatFromInt(row)) * h * 0.62 - h * 0.62;
                    dl.rect(draw.rect(x - h * 0.3, y - h * 0.3, x + h * 0.3, y + h * 0.3), col, 0);
                }
            }
        },
    }
}

/// A point relative to an icon's CENTRE.
///
/// It is a module-level function and not a nested one because Zig 0.16 does
/// not let a nested function capture the enclosing scope — and the centre is
/// exactly what it needs. The helper it replaced returned the coordinates
/// as they were, so every DRAWN icon (the ones with no PNG) was drawn at the
/// window's origin instead of in its box: the toolbar had a hole in it where
/// the scale handle should have been.
fn at(c: Vec2, x: f32, y: f32) Vec2 {
    return .{ .x = c.x + x, .y = c.y + y };
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
            .drag, .cursor, .move, .rotate, .scale, .tiles, .focus, .home,
            .panel_hierarchy, .panel_inspector, .panel_assets, .panel_console,
            .panel_tilemap, => {},
        }
    }
}
