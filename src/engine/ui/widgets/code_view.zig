//! `ui.widgets.code_view` — a syntax-highlighted code view with a gutter.
//!
//! ## Why this widget takes text, not a document
//!
//! The editor's document model lives in `src/engine/editor/` (`Buffer`,
//! `Cursor`, the Lua lexer). This widget is in `engine.ui`, and `ui` may not
//! import `editor`: `build.zig` gives the UI module `core`, `platform` and
//! `render` and nothing else, because `editor` drags in `runtime` — Dawn, GLFW,
//! LuaJIT — and a module that carries those is a module every UI consumer
//! inherits. That boundary is deliberate and worth more than the convenience of
//! one import.
//!
//! So the widget is a pure function of plain data the editor already has:
//!
//! - `text` — the whole document, one buffer;
//! - `line_starts` — the byte offset of each line, which is exactly the
//!   editor's own `Buffer.line_starts`; passing it means the widget never scans
//!   the document to find a line, and it reuses an index that already exists;
//! - `tokens` — coloured runs covering the text, which is exactly what
//!   `editor.lexer.tokenize` emits. The editor maps its `Kind` onto this
//!   widget's `Kind` in a nine-arm switch; the vocabulary is duplicated on
//!   purpose, because each module owns its own and neither grows a dependency
//!   on the other.
//!
//! That is the same shape as every other widget here: state and layout in, draw
//! out, nothing captured.
//!
//! ## What is a pure function here, and why it is tested
//!
//! Everything that decides WHERE something lands (`computeLineStarts`,
//! `lineOfOffset`, `lineTextEnd`, `columnAt`, `clampScroll`) is a free function
//! over bytes, with no ImGui in it, and the headless suite checks it. Off-by-one
//! in any of them is visible as a caret half a line off, which is the kind of
//! bug that is trivial to write and miserable to find on screen.
//!
//! ## The known simplification
//!
//! Columns are counted in BYTES, not glyphs, so a line containing non-ASCII text
//! before a `\t` computes the tab stop one or two columns off. Monospaced ASCII
//! source — the overwhelming majority of what this draws — is exact, and a
//! grapheme-correct column is a `unicode` pass this widget does not need yet.
//! The limitation is stated here rather than discovered later.

const std = @import("std");
const cimgui = @import("../cimgui.zig");
const theme = @import("../theme.zig");
const draw = @import("../draw.zig");
const widget = @import("widget.zig");
const Context = @import("../context.zig").Context;
const Rgba = cimgui.Rgba;
const Vec2 = cimgui.Vec2;
const Rect = cimgui.Rect;

// ── Tokens ───────────────────────────────────────────────────────────────

/// The classes a highlighted run can have. A mirror of the editor's
/// `lexer.Kind`, kept in the UI's own vocabulary so the two modules never
/// import each other.
pub const Kind = enum {
    /// Whitespace and anything unclassified.
    plain,
    comment,
    string,
    number,
    keyword,
    /// An engine global: `actor`, `self`, `math`.
    global,
    /// A member after `.` or `:`.
    field,
    operator,
    /// A byte that cannot start a token. Drawn in an error colour, which is how
    /// a stray byte inside a string becomes visible instead of invisible.
    invalid,
};

/// A coloured run. `len` is bytes and never splits a UTF-8 sequence.
pub const Token = struct {
    start: u32,
    len: u32,
    kind: Kind = .plain,

    pub fn end(self: Token) u32 {
        return self.start + self.len;
    }
};

/// The colour of each class, derived from the theme's tokens rather than
/// written as literals — so a theme change moves the code colours too, which is
/// the rule the whole framework rests on.
pub const Palette = struct {
    plain: Rgba,
    comment: Rgba,
    string: Rgba,
    number: Rgba,
    keyword: Rgba,
    global: Rgba,
    field: Rgba,
    operator: Rgba,
    invalid: Rgba,

    pub fn of(self: Palette, k: Kind) Rgba {
        return switch (k) {
            .plain => self.plain,
            .comment => self.comment,
            .string => self.string,
            .number => self.number,
            .keyword => self.keyword,
            .global => self.global,
            .field => self.field,
            .operator => self.operator,
            .invalid => self.invalid,
        };
    }
};

pub fn palette(t: *theme.Theme) Palette {
    const c = t.colors;
    return .{
        .plain = c.text,
        .comment = c.text_faint,
        .string = c.success,
        .number = c.warning,
        .keyword = c.accent_text,
        .global = c.accent,
        .field = c.text_dim,
        .operator = c.text_dim,
        .invalid = c.danger,
    };
}

// ── Pure layout ──────────────────────────────────────────────────────────

/// Fills `out` with the byte offset of each line start and returns how many
/// there are. Line 0 starts at 0 and every `\n` starts the next one, which is
/// the definition the editor's `Buffer` maintains; this is the same rule for a
/// caller that has text and no `Buffer` (the `.zson` viewer, a log pane).
///
/// Returns the count, not an error: a buffer too small is filled to capacity
/// and reported, and the caller decides whether that is a problem.
pub fn computeLineStarts(text: []const u8, out: []u32) usize {
    if (out.len == 0) return 0;
    out[0] = 0;
    var n: usize = 1;
    for (text, 0..) |ch, i| {
        if (ch == '\n' and n < out.len) {
            out[n] = @intCast(i + 1);
            n += 1;
        }
    }
    return n;
}

/// The line containing `offset`. Binary search, so a caret near the end of a
/// big file is a dozen comparisons rather than a scan.
pub fn lineOfOffset(line_starts: []const u32, offset: u32) u32 {
    if (line_starts.len == 0) return 0;
    var lo: usize = 0;
    var hi: usize = line_starts.len;
    while (lo < hi) {
        const mid = lo + (hi - lo) / 2;
        if (line_starts[mid] <= offset) lo = mid + 1 else hi = mid;
    }
    return @intCast(if (lo == 0) 0 else lo - 1);
}

/// The byte offset of a line's end WITHOUT its newline — what the renderer and
/// the highlighter both want. A trailing `\r` (a CRLF file) is dropped too, or
/// every line of a Windows file grows an invisible column.
pub fn lineTextEnd(text: []const u8, line_starts: []const u32, line: u32) u32 {
    const idx: usize = @intCast(@min(line, @as(u32, @intCast(line_starts.len)) - 1));
    var end: usize = if (idx + 1 < line_starts.len) line_starts[idx + 1] else text.len;
    if (end > 0 and end <= text.len and text[end - 1] == '\n') end -= 1;
    if (end > 0 and end <= text.len and text[end - 1] == '\r') end -= 1;
    return @intCast(end);
}

/// The display column of a byte offset on its line, expanding tabs to the next
/// multiple of `tab_width`. Bytes, not glyphs — see the module comment.
pub fn columnAt(text: []const u8, line_start: u32, offset: u32, tab_width: u32) u32 {
    const tw = if (tab_width == 0) 1 else tab_width;
    var col: u32 = 0;
    var i: u32 = line_start;
    const stop = @min(offset, @as(u32, @intCast(text.len)));
    while (i < stop) : (i += 1) {
        if (text[i] == '\t') {
            col = ((col / tw) + 1) * tw;
        } else {
            col += 1;
        }
    }
    return col;
}

/// Clamps a scroll position to a whole number of lines in `[0, line_count-1]`,
/// so the view never scrolls past its own content and the caller's `*f32` stays
/// a value the widget can render. `visible` is how many lines fit.
pub fn clampScroll(scroll: f32, line_count: u32, visible: f32) f32 {
    if (line_count == 0) return 0.0;
    const max_top = @max(@as(f32, @floatFromInt(line_count)) - @max(visible, 1.0), 0.0);
    return std.math.clamp(scroll, 0.0, max_top);
}

// ── Drawing helpers ──────────────────────────────────────────────────────

/// Draws one run of text, expanding `\t` to the next tab stop, and returns the
/// x it ended at. Tabs are drawn as an ADVANCE, not as spaces: a mono font
/// renders the same picture for a fraction of the bytes, and a long indent does
/// not become a 300-space substring.
fn drawRun(
    list: draw.List,
    x_start: f32,
    y: f32,
    advance: f32,
    color: Rgba,
    text: []const u8,
    start_col: u32,
    tab_width: u32,
) void {
    const tw: u32 = if (tab_width == 0) 1 else tab_width;
    var x = x_start;
    var col = start_col;
    var seg: usize = 0;
    var k: usize = 0;
    while (k < text.len) : (k += 1) {
        if (text[k] != '\t') continue;
        if (k > seg) list.text(.{ .x = x, .y = y }, color, text[seg..k]);
        const next = ((col / tw) + 1) * tw;
        x += @as(f32, @floatFromInt(next - col)) * advance;
        col = next;
        seg = k + 1;
    }
    if (seg < text.len) list.text(.{ .x = x, .y = y }, color, text[seg..]);
}

fn drawLineNumber(list: draw.List, r: Rect, x_right: f32, y: f32, line: u32, col: Rgba) void {
    var buf: [16]u8 = undefined;
    const s = std.fmt.bufPrint(&buf, "{d}", .{line + 1}) catch return;
    const size = draw.textSize(s);
    list.text(.{ .x = x_right - size.x, .y = y }, col, s);
    _ = r;
}

// ── The view ─────────────────────────────────────────────────────────────

pub const Selection = struct { from: u32, to: u32 };

pub const CodeView = struct {
    ctx: *Context,
    id: []const u8,
    /// The whole document. Not owned.
    text: []const u8,
    /// Byte offset of every line start — the caller's line index.
    line_starts: []const u32,
    /// Coloured runs covering `text`, sorted and non-overlapping. Empty draws
    /// the text in the plain colour, which is what a caller with no lexer wants.
    tokens: []const Token = &.{},
    /// Top visible line, fractional, owned by the caller. The widget clamps and
    /// mouse-scrolls it in place, so a pane remembers where it was.
    scroll: *f32,
    /// Caret position in bytes, or null for a read-only view with no caret.
    caret: ?u32 = null,
    selection: ?Selection = null,
    tab_width: u32 = 4,
    gutter_width: f32 = 52.0,
    show_gutter: bool = true,
    /// 0 fills the available width / height.
    width: f32 = 0,
    height: f32 = 0,
    /// A caret with nothing to edit behind it is a read-only viewer; it still
    /// draws the caret so a find result can point at a byte.
    background: ?Rgba = null,
};

pub fn view(v: CodeView) void {
    const t = &v.ctx.theme;
    const m = t.metrics;
    const w = if (v.width > 0) v.width else draw.contentAvail().x;
    const h = if (v.height > 0) v.height else draw.contentAvail().y;

    cimgui.ember_ui_push_id_str(cimgui.text(v.id));
    defer cimgui.ember_ui_pop_id();

    const hit = widget.submit(cimgui.text("##code"), w, h, false);
    const r = hit.rect;
    const list = draw.List.item();
    const pal = palette(t);

    list.rect(r, v.background orelse t.colors.bg, m.radius_sm());

    // The mono face, pushed for the whole body. The push/pop pair is guarded by
    // a bool so a build with no mono font loaded still gets its pop count right.
    var font_pushed = false;
    if (v.ctx.font_mono >= 0) {
        _ = cimgui.ember_ui_push_font(v.ctx.font_mono);
        font_pushed = true;
    }
    defer if (font_pushed) cimgui.ember_ui_pop_font();

    const measured = cimgui.ember_ui_text_line_height();
    const line_h: f32 = if (measured > 1.0) measured else 14.0;
    const advance: f32 = @max(draw.textSize("0").x, 1.0);
    const visible: f32 = @max(h / line_h, 1.0);
    const line_count: u32 = @intCast(v.line_starts.len);

    if (hit.hovered) {
        const wheel = v.ctx.window.input.mouse.wheel_y;
        if (wheel != 0.0) v.scroll.* = clampScroll(v.scroll.* - wheel * 3.0, line_count, visible);
    }
    v.scroll.* = clampScroll(v.scroll.*, line_count, visible);

    const gutter: f32 = if (v.show_gutter) v.gutter_width else 0.0;
    const text_x0 = r.min.x + gutter + 8.0;

    list.pushClip(r, true);
    defer list.popClip();

    const first_f = @floor(v.scroll.*);
    const first: u32 = @intFromFloat(@max(first_f, 0.0));
    const span_lines: u32 = @as(u32, @intFromFloat(visible)) + 2;
    var i: u32 = first;
    const last: u32 = @min(first + span_lines, line_count);

    // The token cursor walks ONCE across the visible window instead of being
    // restarted per line: tokens are sorted, so a single advancing index is the
    // whole search, and a frame costs one pass over what is on screen.
    var ti: usize = 0;
    if (v.tokens.len > 0 and first < line_count) {
        const first_offset = v.line_starts[first];
        while (ti < v.tokens.len and v.tokens[ti].end() <= first_offset) : (ti += 1) {}
    }

    while (i < last) : (i += 1) {
        const y = r.min.y + (@as(f32, @floatFromInt(i)) - v.scroll.*) * line_h;
        if (y + line_h < r.min.y or y > r.max.y) continue;
        const ls = v.line_starts[i];
        const le = lineTextEnd(v.text, v.line_starts, i);

        // The current line, behind the text: the one guide that makes a long
        // function readable at 3am.
        if (v.caret) |caret| {
            if (lineOfOffset(v.line_starts, caret) == i) {
                list.rect(
                    draw.rect(r.min.x, y, r.max.x, y + line_h),
                    t.colors.surface_hi.withAlpha(0.5),
                    0,
                );
            }
        }

        // Selection on this line, drawn under the text.
        if (v.selection) |sel| {
            const s_from = @min(sel.from, sel.to);
            const s_to = @max(sel.from, sel.to);
            if (s_to > ls and s_from < le) {
                const a = @max(s_from, ls);
                const b = @min(s_to, le);
                const xa = text_x0 + @as(f32, @floatFromInt(columnAt(v.text, ls, a, v.tab_width))) * advance;
                const xb = text_x0 + @as(f32, @floatFromInt(columnAt(v.text, ls, b, v.tab_width))) * advance;
                list.rect(draw.rect(xa, y, xb, y + line_h), t.colors.accent.withAlpha(0.22), 0);
            }
        }

        if (v.show_gutter) {
            drawLineNumber(list, r, r.min.x + gutter - 6.0, y, i, t.colors.text_faint);
        }

        // The line's text, token by token. A token that starts before the line
        // is clipped to it, which is how a multi-line comment or long string
        // stays one run in the token list and still colours each line.
        var seg_start = ls;
        while (ti < v.tokens.len and v.tokens[ti].start < le) {
            const tok = v.tokens[ti];
            if (tok.end() <= ls) {
                ti += 1;
                continue;
            }
            const a = @max(tok.start, ls);
            const b = @min(tok.end(), le);
            if (a > seg_start) {
                // A gap in the token list is not a colour the editor chose, so
                // it is drawn plain rather than left blank.
                drawRun(list, text_x0 + @as(f32, @floatFromInt(columnAt(v.text, ls, seg_start, v.tab_width))) * advance, y, advance, pal.plain, v.text[seg_start..a], columnAt(v.text, ls, seg_start, v.tab_width), v.tab_width);
            }
            drawRun(list, text_x0 + @as(f32, @floatFromInt(columnAt(v.text, ls, a, v.tab_width))) * advance, y, advance, pal.of(tok.kind), v.text[a..b], columnAt(v.text, ls, a, v.tab_width), v.tab_width);
            seg_start = b;
            if (tok.end() > le) break;
            ti += 1;
        }
        if (seg_start < le) {
            drawRun(list, text_x0 + @as(f32, @floatFromInt(columnAt(v.text, ls, seg_start, v.tab_width))) * advance, y, advance, pal.plain, v.text[seg_start..le], columnAt(v.text, ls, seg_start, v.tab_width), v.tab_width);
        }
    }

    // The caret, drawn last so it is never under a selection.
    if (v.caret) |caret| {
        const cl = lineOfOffset(v.line_starts, caret);
        const cy = r.min.y + (@as(f32, @floatFromInt(cl)) - v.scroll.*) * line_h;
        if (cy + line_h >= r.min.y and cy <= r.max.y) {
            const ls = v.line_starts[cl];
            const cx = text_x0 + @as(f32, @floatFromInt(columnAt(v.text, ls, caret, v.tab_width))) * advance;
            list.rect(draw.rect(cx, cy, cx + 1.5, cy + line_h), t.colors.accent, 0);
        }
    }

    list.rectOutline(
        r,
        if (hit.focused) t.colors.border_focus else if (hit.hovered) t.colors.border_strong else t.colors.border,
        m.radius_sm(),
        1.0,
    );
}

// ── Tests ────────────────────────────────────────────────────────────────

const testing = std.testing;

test "ui code view: the line index is the newline rule" {
    var out: [16]u32 = undefined;
    const n = computeLineStarts("one\ntwo\n\nthree", &out);
    try testing.expectEqual(@as(usize, 4), n);
    try testing.expectEqual(@as(u32, 0), out[0]);
    try testing.expectEqual(@as(u32, 4), out[1]);
    try testing.expectEqual(@as(u32, 8), out[2]);
    try testing.expectEqual(@as(u32, 9), out[3]);
}

test "ui code view: an empty document still has one line" {
    // The invariant that keeps a caret at EOF on a line to sit on. A `[]u32`
    // with zero entries is a document with nowhere to put the cursor.
    var out: [4]u32 = undefined;
    try testing.expectEqual(@as(usize, 1), computeLineStarts("", &out));
    try testing.expectEqual(@as(u32, 0), out[0]);
}

test "ui code view: a line's text excludes the newline and a CRLF's carriage return" {
    const text = "one\ntwo\r\nthree";
    var out: [8]u32 = undefined;
    const n = computeLineStarts(text, &out);
    try testing.expectEqual(@as(usize, 3), n);
    const starts = out[0..n];
    try testing.expectEqualStrings("one", text[starts[0]..lineTextEnd(text, starts, 0)]);
    try testing.expectEqualStrings("two", text[starts[1]..lineTextEnd(text, starts, 1)]);
    try testing.expectEqualStrings("three", text[starts[2]..lineTextEnd(text, starts, 2)]);
}

test "ui code view: lineOfOffset is exact at every boundary" {
    const text = "aa\nbbb\nc";
    var out: [8]u32 = undefined;
    const n = computeLineStarts(text, &out);
    const starts = out[0..n];
    try testing.expectEqual(@as(u32, 0), lineOfOffset(starts, 0));
    try testing.expectEqual(@as(u32, 0), lineOfOffset(starts, 2)); // the newline itself
    try testing.expectEqual(@as(u32, 1), lineOfOffset(starts, 3)); // first byte of line 1
    try testing.expectEqual(@as(u32, 1), lineOfOffset(starts, 6));
    try testing.expectEqual(@as(u32, 2), lineOfOffset(starts, 7));
    // Past the end clamps to the last line rather than reading off it.
    try testing.expectEqual(@as(u32, 2), lineOfOffset(starts, 99));
}

test "ui code view: columns expand tabs to tab stops" {
    // "a\tb": 'b' is at column 4 with a 4-wide tab, not at column 2. Getting
    // this wrong is a caret that drifts one column per indent level.
    const text = "a\tb";
    try testing.expectEqual(@as(u32, 1), columnAt(text, 0, 1, 4));
    try testing.expectEqual(@as(u32, 4), columnAt(text, 0, 2, 4));
    // A tab from a stop is a whole stop, not one column.
    try testing.expectEqual(@as(u32, 8), columnAt("a\t\tb", 0, 3, 4));
    // A tab at column 0 with a 2-wide tab is 2, not 4.
    try testing.expectEqual(@as(u32, 2), columnAt("\tb", 0, 1, 2));
}

test "ui code view: scroll clamps to the last whole screen" {
    // 10 lines, 4 visible: the top may be 6, and it must never be 9 — a view
    // that scrolls past its content shows a blank pane with the caret off-screen.
    try testing.expectEqual(@as(f32, 6.0), clampScroll(99.0, 10, 4.0));
    try testing.expectEqual(@as(f32, 0.0), clampScroll(-5.0, 10, 4.0));
    try testing.expectEqual(@as(f32, 0.0), clampScroll(3.0, 3, 4.0));
    // Fewer lines than fit: no scrolling at all.
    try testing.expectEqual(@as(f32, 0.0), clampScroll(2.0, 2, 10.0));
}
