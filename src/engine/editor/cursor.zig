//! Cursor and selection over a `Buffer`.
//!
//! ## Why the cursor is a separate type
//!
//! A buffer is text; a cursor is a POSITION in text plus the intent behind it.
//! Keeping them apart is what lets the same buffer be shown in two panes, and it
//! is what makes the hard part of the cursor testable without a UI: the intent.
//!
//! The intent is `preferred_column`. Pressing Down on a 3-character line and then
//! Down again onto a 10-character line must leave the caret at column 10, not back
//! at 3 — the classic bug is a cursor that "forgets" where the user was heading
//! and snaps to the end of every short line it passes. So the column is remembered
//! per movement axis and only cleared by a horizontal move.
//!
//! ## Selection is an anchor, not a second position
//!
//! `anchor` is where the selection started; `pos` is where the caret is. Extending
//! a selection moves `pos` and leaves the anchor, which is why shift+arrow behaves
//! differently from arrow without the caller knowing anything about either.
//!
//! ## Every edit goes through here
//!
//! `insert`, `backspace`, `delete`, `insertNewline` all replace the selection
//! first, because that is what every editor does: typing over a selection
//! replaces it. Doing it in one place means the caller cannot forget, and the undo
//! history stays one entry per act.

const std = @import("std");
const buffer_mod = @import("text_buffer.zig");

const Buffer = buffer_mod.Buffer;

/// A selection's extent: always ordered, so `from <= to`, and null when there is
/// no selection (anchor == caret).
pub const Selection = struct {
    from: u32,
    to: u32,

    pub fn len(self: Selection) u32 {
        return self.to - self.from;
    }

    pub fn isEmpty(self: Selection) bool {
        return self.to <= self.from;
    }
};

/// How many columns a Tab moves. The document stores whatever was typed; this is
/// only for rendering and for the width a Tab occupies when indenting.
pub const default_tab_width: u32 = 4;

pub const Cursor = struct {
    buffer: *Buffer,
    /// Caret position, in bytes. Always on a character boundary.
    pos: u32 = 0,
    /// Selection anchor, or null for no selection.
    anchor: ?u32 = null,
    /// The column a vertical movement is trying to hold, or null when the last
    /// move was horizontal. See the module comment: this is the whole reason
    /// Down-Down-Down does not walk the caret into a corner.
    preferred_column: ?u32 = null,
    /// How many screen lines one PageUp/PageDown moves.
    page_lines: u32 = 20,

    pub fn init(buffer: *Buffer) Cursor {
        return .{ .buffer = buffer };
    }

    // ── Reading state ────────────────────────────────────────────────────────

    pub fn line(self: *const Cursor) u32 {
        return self.buffer.lineOfOffset(self.pos);
    }

    pub fn column(self: *const Cursor) u32 {
        return self.pos - self.buffer.lineStart(self.line());
    }

    /// The selected range, ordered, or null when nothing is selected.
    pub fn selection(self: *const Cursor) ?Selection {
        const a = self.anchor orelse return null;
        if (a == self.pos) return null;
        return .{
            .from = @min(a, self.pos),
            .to = @max(a, self.pos),
        };
    }

    pub fn hasSelection(self: *const Cursor) bool {
        if (self.selection()) |s| return !s.isEmpty();
        return false;
    }

    /// The selected text, valid until the next mutation.
    pub fn selectedText(self: *const Cursor) []const u8 {
        const s = self.selection() orelse return "";
        return self.buffer.textBytes()[s.from..s.to];
    }

    // ── Moving ───────────────────────────────────────────────────────────────

    /// Moves the caret to an offset, clamped and snapped to a character boundary.
    ///
    /// Snapping goes BACKWARDS when the offset lands inside a multi-byte
    /// character, not forwards: a click between the two bytes of a `ñ` means "put
    /// the caret on the `ñ`", and snapping forward would put it after the next
    /// character as well. The only way anything in this type writes `pos`
    /// directly, so a caret can never end up inside a character by construction.
    pub fn moveTo(self: *Cursor, offset: u32) void {
        const max: u32 = @intCast(self.buffer.byteLen());
        const clamped = @min(offset, max);
        self.pos = if (isContinuation(self.buffer.textBytes(), clamped))
            self.buffer.prevBoundary(clamped)
        else
            clamped;
    }

    pub fn moveLeft(self: *Cursor, extend: bool) void {
        const from = self.pos;
        self.clearPreferred();
        const target = self.buffer.prevBoundary(self.pos);
        self.moveTo(target);
        if (extend) self.startSelection(from) else self.anchor = null;
    }

    pub fn moveRight(self: *Cursor, extend: bool) void {
        const from = self.pos;
        self.clearPreferred();
        const target = self.pos + self.buffer.charLenAt(self.pos);
        self.moveTo(target);
        if (extend) self.startSelection(from) else self.anchor = null;
    }

    pub fn moveUp(self: *Cursor, extend: bool) void {
        const from = self.pos;
        const l = self.line();
        if (l == 0) {
            // At the first line, Up goes to the start of it — the only place a
            // caret can be that is not the preferred column.
            self.moveTo(self.buffer.lineStart(l));
        } else {
            const col = self.preferred_column orelse self.column();
            self.preferred_column = col;
            self.moveTo(self.buffer.offsetOfLineCol(.{ .line = l - 1, .col = col }));
        }
        if (extend) self.startSelection(from) else self.anchor = null;
    }

    pub fn moveDown(self: *Cursor, extend: bool) void {
        const from = self.pos;
        const l = self.line();
        const last = self.buffer.lineCount() - 1;
        if (l == last) {
            self.moveTo(self.buffer.lineEnd(l));
        } else {
            const col = self.preferred_column orelse self.column();
            self.preferred_column = col;
            self.moveTo(self.buffer.offsetOfLineCol(.{ .line = l + 1, .col = col }));
        }
        if (extend) self.startSelection(from) else self.anchor = null;
    }

    pub fn moveLineStart(self: *Cursor, extend: bool) void {
        const from = self.pos;
        self.clearPreferred();
        self.moveTo(self.buffer.lineStart(self.line()));
        if (extend) self.startSelection(from) else self.anchor = null;
    }

    pub fn moveLineEnd(self: *Cursor, extend: bool) void {
        const from = self.pos;
        self.clearPreferred();
        self.moveTo(self.buffer.lineEnd(self.line()));
        if (extend) self.startSelection(from) else self.anchor = null;
    }

    /// Home to the first non-blank, or to column 0 if already there. The two-stop
    /// Home every code editor has, and the reason a single "go to column 0" is
    /// not enough: code is indented, and column 0 is never where you want to be.
    pub fn moveHome(self: *Cursor, extend: bool) void {
        const from = self.pos;
        self.clearPreferred();
        const line_text = self.buffer.lineText(self.line());
        var first: u32 = 0;
        while (first < line_text.len and (line_text[first] == ' ' or line_text[first] == '\t')) : (first += 1) {}
        const start = self.buffer.lineStart(self.line());
        const target = if (self.pos == start + first) start else start + first;
        self.moveTo(target);
        if (extend) self.startSelection(from) else self.anchor = null;
    }

    pub fn movePageUp(self: *Cursor, extend: bool) void {
        self.moveVerticalBy(self.page_lines, extend, .up);
    }

    pub fn movePageDown(self: *Cursor, extend: bool) void {
        self.moveVerticalBy(self.page_lines, extend, .down);
    }

    /// Ctrl+Left / Ctrl+Right: to the start of the previous / next word.
    ///
    /// A word is a run of identifier bytes, or a run of anything else. That is the
    /// "two kinds of thing" rule, and it is why `foo.bar+baz` advances four times
    /// instead of once: punctuation and names are different destinations.
    pub fn moveWordLeft(self: *Cursor, extend: bool) void {
        const from = self.pos;
        self.clearPreferred();
        const text = self.buffer.textBytes();
        var i = self.pos;
        // Skip whatever is under the caret, then skip the next run.
        const kind = if (i > 0) classOf(text[i - 1]) else .space;
        while (i > 0 and classOf(text[i - 1]) == kind) : (i -= 1) {}
        self.moveTo(i);
        if (extend) self.startSelection(from) else self.anchor = null;
    }

    pub fn moveWordRight(self: *Cursor, extend: bool) void {
        const from = self.pos;
        self.clearPreferred();
        const text = self.buffer.textBytes();
        const n = text.len;
        var i = self.pos;
        const kind = if (i < n) classOf(text[i]) else .space;
        while (i < n and classOf(text[i]) == kind) : (i += 1) {}
        self.moveTo(i);
        if (extend) self.startSelection(from) else self.anchor = null;
    }

    pub fn selectAll(self: *Cursor) void {
        self.clearPreferred();
        self.anchor = 0;
        self.moveTo(@intCast(self.buffer.byteLen()));
    }

    pub fn clearSelection(self: *Cursor) void {
        self.anchor = null;
    }

    // ── Editing ──────────────────────────────────────────────────────────────

    /// Inserts text at the caret, replacing any selection. Returns the caret span
    /// so the caller can re-render without scanning.
    /// Inserts text, replacing any selection as ONE act.
    ///
    /// The selection case goes through `replace`, not "delete then insert",
    /// because the user did one thing: overwriting "he" with "HE" must be a single
    /// undo step. Doing it in two is the difference between undo restoring the line
    /// and undo leaving "llo world" behind.
    pub fn insert(self: *Cursor, text: []const u8) !void {
        self.buffer.breakRun();
        const span = self.replaceSelectionSpan();
        if (span) |s| {
            try self.buffer.replace(s.from, s.to, text);
            self.anchor = null;
            self.moveTo(s.from + @as(u32, @intCast(text.len)));
        } else {
            try self.buffer.insert(self.pos, text);
            self.anchor = null;
            self.moveTo(self.pos + @as(u32, @intCast(text.len)));
        }
    }

    /// Types one character, as a keypress: the run is opened first, so consecutive
    /// keystrokes coalesce into one undo step.
    pub fn typeChar(self: *Cursor, text: []const u8) !void {
        self.buffer.beginRun();
        const span = self.replaceSelectionSpan();
        if (span) |s| {
            try self.buffer.replace(s.from, s.to, text);
            self.anchor = null;
            self.moveTo(s.from + @as(u32, @intCast(text.len)));
        } else {
            try self.buffer.insert(self.pos, text);
            self.anchor = null;
            self.moveTo(self.pos + @as(u32, @intCast(text.len)));
        }
    }

    /// Backspace: deletes the selection, or the character before the caret.
    pub fn backspace(self: *Cursor) !void {
        self.buffer.breakRun();
        if (self.replaceSelectionSpan()) |s| {
            try self.buffer.delete(s.from, s.len());
            self.moveTo(s.from);
            self.anchor = null;
            return;
        }
        const target = self.buffer.prevBoundary(self.pos);
        if (target == self.pos) return; // at the start of the document
        try self.buffer.delete(target, self.pos - target);
        self.moveTo(target);
    }

    /// Delete: deletes the selection, or the character after the caret.
    pub fn delete(self: *Cursor) !void {
        self.buffer.breakRun();
        if (self.replaceSelectionSpan()) |s| {
            try self.buffer.delete(s.from, s.len());
            self.moveTo(s.from);
            self.anchor = null;
            return;
        }
        const n = self.buffer.charLenAt(self.pos);
        if (n == 0) return; // at the end of the document
        try self.buffer.delete(self.pos, n);
    }

    /// Enter: inserts a newline and indents the new line to the indentation of the
    /// line the caret was on. Auto-indent is the difference between a text editor
    /// and a code editor, and it is one line here because the indentation of the
    /// old line is already in the buffer.
    pub fn insertNewline(self: *Cursor) !void {
        self.buffer.breakRun();
        const span = self.replaceSelectionSpan();
        const from = if (span) |s| s.from else self.pos;
        const at_line = self.buffer.lineOfOffset(from);
        const line_text = self.buffer.lineText(at_line);
        var lead: usize = 0;
        while (lead < line_text.len and (line_text[lead] == ' ' or line_text[lead] == '\t')) : (lead += 1) {}
        const prefix = line_text[0..lead];

        // Bounded on purpose: an absurdly deep indent is clamped rather than
        // overflowing a stack buffer, and the caret still lands somewhere sane.
        const room = @min(prefix.len, 63);
        var buf: [64]u8 = undefined;
        buf[0] = '\n';
        @memcpy(buf[1 .. 1 + room], prefix[0..room]);
        const payload = buf[0 .. 1 + room];
        if (span) |s| {
            try self.buffer.replace(s.from, s.to, payload);
        } else {
            try self.buffer.insert(from, payload);
        }
        self.anchor = null;
        self.moveTo(from + 1 + @as(u32, @intCast(room)));
    }

    /// Tab: inserts `default_tab_width` spaces, or indents every line the
    /// selection touches (outdent removes them). A selection that spans lines is
    /// an indent gesture, not a replace — which is why the selection is NOT cleared
    /// here, so repeated Shift+Tab keeps working on the same lines.
    ///
    /// The whole affected region is rebuilt and written with ONE `replace`, so
    /// indenting twenty lines is one undo step rather than twenty. That is not a
    /// nicety: an editor where undoing an indent leaves the file half-indented is
    /// one where users stop using indent at all.
    pub fn indent(self: *Cursor, outdent: bool) !void {
        const sel = self.selection();
        if (sel == null or sel.?.isEmpty()) {
            try self.typeChar(" " ** default_tab_width);
            return;
        }
        self.buffer.breakRun();
        const s = sel.?;
        // A selection that ends at column 0 belongs to the line it STARTS on:
        // otherwise selecting three whole lines indents the fourth.
        var end_line = self.buffer.lineOfOffset(s.to);
        if (s.to > s.from and self.buffer.lineStart(end_line) == s.to) end_line -= 1;
        const start_line = self.buffer.lineOfOffset(s.from);
        const start = self.buffer.lineStart(start_line);
        const end = self.buffer.lineEnd(end_line);
        const line_count = end_line - start_line + 1;

        // Enough for the region plus four columns per line and one byte of slack.
        const capacity = (end - start) + line_count * (default_tab_width + 1) + 16;
        const buf = try self.buffer.allocator.alloc(u8, capacity);
        defer self.buffer.allocator.free(buf);
        var w: usize = 0;

        var l = start_line;
        while (l <= end_line) : (l += 1) {
            const line_text = self.buffer.lineText(l);
            if (outdent) {
                var n: usize = 0;
                while (n < line_text.len and n < default_tab_width and line_text[n] == ' ') : (n += 1) {}
                @memcpy(buf[w..][0 .. line_text.len - n], line_text[n..]);
                w += line_text.len - n;
            } else {
                @memcpy(buf[w..][0..default_tab_width], "    ");
                w += default_tab_width;
                @memcpy(buf[w..][0..line_text.len], line_text);
                w += line_text.len;
            }
            if (l < end_line) {
                buf[w] = '\n';
                w += 1;
            }
        }
        try self.buffer.replace(start, end, buf[0..w]);

        // Keep the selection covering the same lines, now shifted.
        self.anchor = start;
        self.moveTo(start + @as(u32, @intCast(w)));
    }

    // ── Internals ────────────────────────────────────────────────────────────

    fn clearPreferred(self: *Cursor) void {
        self.preferred_column = null;
    }

    /// Starts a selection if there is none, keeping the anchor where it was.
    /// Starts a selection, anchored where the caret was BEFORE this move.
    ///
    /// Taking the position before rather than after is the whole point: passing
    /// the post-move position makes the first shift+arrow a no-op selection that
    /// then grows from the wrong end, which reads as "shift+arrow selected the
    /// character I landed on, not the one I left".
    fn startSelection(self: *Cursor, from: u32) void {
        if (self.anchor == null) self.anchor = from;
    }

    /// Deletes the selection and returns where it was, or null when there was
    /// none. Every edit calls this first, which is what makes typing over a
    /// selection replace it without any caller remembering to check.
    /// The selected range WITHOUT deleting anything. The caller decides whether
    /// this is a delete, a replace, or nothing — which is what lets each edit be a
    /// single undo entry instead of two.
    fn replaceSelectionSpan(self: *Cursor) ?Selection {
        const s = self.selection() orelse return null;
        self.anchor = null;
        return s;
    }

    fn moveVerticalBy(self: *Cursor, lines: u32, extend: bool, dir: enum { up, down }) void {
        const from = self.pos;
        const l = self.line();
        const target_line = switch (dir) {
            .up => if (l > lines) l - lines else 0,
            .down => @min(l + lines, self.buffer.lineCount() - 1),
        };
        const col = self.preferred_column orelse self.column();
        self.preferred_column = col;
        self.moveTo(self.buffer.offsetOfLineCol(.{ .line = target_line, .col = col }));
        if (extend) self.startSelection(from) else self.anchor = null;
    }
};

/// The class of a byte for word movement: names, punctuation, and everything
/// else. Two classes, not three, because that is all the distinction a reader
/// makes when they press Ctrl+Left.
const ByteClass = enum { ident, punct, space };

fn classOf(ch: u8) ByteClass {
    if (ch == ' ' or ch == '\t' or ch == '\r' or ch == '\n') return .space;
    if (std.ascii.isAlphanumeric(ch) or ch == '_') return .ident;
    return .punct;
}

/// True when the byte at `offset` continues a UTF-8 sequence. A free function so
/// the buffer does not have to expose its text just for this question.
fn isContinuation(text: []const u8, offset: u32) bool {
    if (offset >= text.len) return false;
    return (text[offset] & 0xC0) == 0x80;
}

// ── Tests ────────────────────────────────────────────────────────────────────

const testing = std.testing;

// NOTE for anyone adding a test here: the buffer and the cursor must BOTH live in
// the test's own scope. An earlier version of this file had a helper that returned
// the buffer by value while the cursor held a pointer into the helper's stack
// frame -- it compiled, and every assertion after the first was reading freed
// memory. `Cursor.init(&b)` takes the address of the caller's buffer, so the
// caller owns it.

test "movement stays on character boundaries" {
    var b = Buffer.init(testing.allocator);
    defer b.deinit();
    try b.load("a\u{f1}b");
    var c = Cursor.init(&b);

    c.moveTo(2); // inside the 'ñ'
    try testing.expectEqual(@as(u32, 1), c.pos); // snapped to the START of it
    c.moveRight(false);
    try testing.expectEqual(@as(u32, 3), c.pos); // past the whole character
    c.moveLeft(false);
    try testing.expectEqual(@as(u32, 1), c.pos);
}

test "vertical movement remembers the column across short lines" {
    // The bug this exists for: Down, Down, Down on a buffer with a short middle
    // line used to leave the caret at the END of the short line instead of where
    // the user was heading.
    var b = Buffer.init(testing.allocator);
    defer b.deinit();
    try b.load("abcdefgh\nxy\nabcdefgh\n");
    var c = Cursor.init(&b);

    c.moveTo(4); // line 0, column 4
    c.moveDown(false);
    c.moveDown(false);
    try testing.expectEqual(@as(u32, 2), c.line());
    try testing.expectEqual(@as(u32, 4), c.column());

    // A horizontal move clears the memory, so Home then Down goes to column 0.
    c.moveHome(false);
    c.moveDown(false);
    try testing.expectEqual(@as(u32, 0), c.column());
}

test "a column past the end of a short line is kept, not clamped" {
    var b = Buffer.init(testing.allocator);
    defer b.deinit();
    try b.load("abcdef\nxy\nabcdef\n");
    var c = Cursor.init(&b);

    c.moveTo(5); // line 0, last column
    c.moveDown(false); // lands at the end of "xy", column 2
    try testing.expectEqual(@as(u32, 2), c.column());
    c.moveDown(false); // and comes back out to column 5 on the long line
    try testing.expectEqual(@as(u32, 5), c.column());
}

test "home goes to the first non-blank, and then to column zero" {
    var b = Buffer.init(testing.allocator);
    defer b.deinit();
    try b.load("    indented\n");
    var c = Cursor.init(&b);

    c.moveTo(8);
    c.moveHome(false);
    try testing.expectEqual(@as(u32, 4), c.pos); // past the four spaces
    c.moveHome(false);
    try testing.expectEqual(@as(u32, 0), c.pos); // and again, to column 0
}

test "shift plus an arrow extends, and a plain arrow clears" {
    var b = Buffer.init(testing.allocator);
    defer b.deinit();
    try b.load("hello world");
    var c = Cursor.init(&b);

    c.moveTo(0);
    c.moveRight(true);
    c.moveRight(true);
    const sel = c.selection().?;
    try testing.expectEqual(@as(u32, 0), sel.from);
    try testing.expectEqual(@as(u32, 2), sel.to);
    try testing.expectEqualStrings("he", c.selectedText());

    c.moveRight(false);
    try testing.expect(!c.hasSelection());
    try testing.expectEqual(@as(u32, 3), c.pos);
}

test "selecting right to left reports the range ordered" {
    var b = Buffer.init(testing.allocator);
    defer b.deinit();
    try b.load("abcdef");
    var c = Cursor.init(&b);

    c.moveTo(5);
    c.moveLeft(true);
    c.moveLeft(true);
    const sel = c.selection().?;
    try testing.expectEqual(@as(u32, 3), sel.from);
    try testing.expectEqual(@as(u32, 5), sel.to);
    try testing.expectEqualStrings("de", c.selectedText());
}

test "typing replaces the selection and clears it" {
    var b = Buffer.init(testing.allocator);
    defer b.deinit();
    try b.load("hello world");
    var c = Cursor.init(&b);

    c.moveTo(0);
    c.moveRight(true);
    c.moveRight(true);
    try c.insert("HE");
    try testing.expectEqualStrings("HEllo world", b.textBytes());
    try testing.expect(!c.hasSelection());
    try testing.expectEqual(@as(u32, 2), c.pos);
}

test "typing over a selection is one undo step" {
    var b = Buffer.init(testing.allocator);
    defer b.deinit();
    try b.load("hello world");
    var c = Cursor.init(&b);

    c.moveTo(0);
    c.moveRight(true);
    c.moveRight(true);
    try c.insert("HE");
    _ = b.undo().?;
    try testing.expectEqualStrings("hello world", b.textBytes());
}

test "backspace deletes the selection, else the character before" {
    var b = Buffer.init(testing.allocator);
    defer b.deinit();
    try b.load("abc");
    var c = Cursor.init(&b);

    c.moveTo(1);
    try c.backspace();
    try testing.expectEqualStrings("bc", b.textBytes());
    try testing.expectEqual(@as(u32, 0), c.pos);

    // With a selection it takes the whole selection, and leaves the caret where
    // the selection started rather than where the caret was.
    c.moveTo(2);
    c.moveLeft(true);
    c.moveLeft(true);
    try c.backspace();
    try testing.expectEqualStrings("", b.textBytes());
    try testing.expectEqual(@as(u32, 0), c.pos);
}

test "backspace at the start of the document does nothing" {
    var b = Buffer.init(testing.allocator);
    defer b.deinit();
    try b.load("abc");
    var c = Cursor.init(&b);

    c.moveTo(0);
    try c.backspace();
    try testing.expectEqualStrings("abc", b.textBytes());
}

test "delete removes the selection, else the character after" {
    var b = Buffer.init(testing.allocator);
    defer b.deinit();
    try b.load("abc");
    var c = Cursor.init(&b);

    c.moveTo(0);
    try c.delete();
    try testing.expectEqualStrings("bc", b.textBytes());
}

test "a multi-byte character is deleted whole" {
    var b = Buffer.init(testing.allocator);
    defer b.deinit();
    try b.load("a\u{f1}b");
    var c = Cursor.init(&b);

    c.moveTo(1);
    try c.delete();
    try testing.expectEqualStrings("ab", b.textBytes());
}

test "newline auto-indents to the line the caret was on" {
    var b = Buffer.init(testing.allocator);
    defer b.deinit();
    try b.load("    return 1");
    var c = Cursor.init(&b);

    c.moveLineEnd(false); // end of the line
    try c.insertNewline();
    try testing.expectEqualStrings("    return 1\n    ", b.textBytes());
    // The caret is on the NEW line (1), four columns in.
    try testing.expectEqual(@as(u32, 1), c.line());
    try testing.expectEqual(@as(u32, 4), c.column());
}

test "tab indents every line a selection touches, and keeps the selection" {
    var b = Buffer.init(testing.allocator);
    defer b.deinit();
    try b.load("a\nb\nc\n");
    var c = Cursor.init(&b);

    // Select from the start of line 1 to the end of line 2.
    c.anchor = b.lineStart(1);
    c.moveTo(b.lineEnd(2));
    try c.indent(false);
    try testing.expectEqualStrings("a\n    b\n    c\n", b.textBytes());
    // The selection still covers the same lines, so Shift+Tab keeps working.
    try testing.expect(c.hasSelection());

    try c.indent(true);
    try testing.expectEqualStrings("a\nb\nc\n", b.textBytes());
}

test "a selection ending at column zero does not indent the next line" {
    var b = Buffer.init(testing.allocator);
    defer b.deinit();
    try b.load("a\nb\n");
    var c = Cursor.init(&b);

    c.anchor = 0;
    c.moveTo(2); // the start of line 1, column 0
    try c.indent(false);
    // Only line 0 was selected: "a" is indented, "b" is not.
    try testing.expectEqualStrings("    a\nb\n", b.textBytes());
}

test "word movement treats names and punctuation as different destinations" {
    var b = Buffer.init(testing.allocator);
    defer b.deinit();
    try b.load("foo.bar + baz");
    var c = Cursor.init(&b);

    c.moveTo(0);
    var stops: u32 = 0;
    while (c.pos < b.byteLen()) : (stops += 1) {
        c.moveWordRight(false);
        if (stops > 20) break; // a runaway would spin forever otherwise
    }
    // foo | . | bar |   | + |   | baz -- seven stops: the two spaces are stops
    // too, which is what makes "Ctrl+Right, Ctrl+Right" walk out of a gap rather
    // than jumping over it.
    try testing.expectEqual(@as(u32, 7), stops);
}

test "page movement moves by page_lines and clamps at the edges" {
    var b = Buffer.init(testing.allocator);
    defer b.deinit();
    try b.load("1\n2\n3\n4\n5\n6\n7\n8\n");
    var c = Cursor.init(&b);

    c.page_lines = 3;
    c.movePageDown(false);
    try testing.expectEqual(@as(u32, 3), c.line());
    c.movePageDown(false);
    try testing.expectEqual(@as(u32, 6), c.line());
    c.movePageDown(false);
    // The file ends with a newline, so it has nine lines and line 8 is the last.
    try testing.expectEqual(@as(u32, 8), c.line());
    c.movePageUp(false);
    try testing.expectEqual(@as(u32, 5), c.line());
    c.movePageUp(false);
    c.movePageUp(false);
    try testing.expectEqual(@as(u32, 0), c.line()); // clamped at the top
}

test "select all selects the whole document" {
    var b = Buffer.init(testing.allocator);
    defer b.deinit();
    try b.load("line one\nline two\n");
    var c = Cursor.init(&b);

    c.selectAll();
    const sel = c.selection().?;
    try testing.expectEqual(@as(u32, 0), sel.from);
    try testing.expectEqual(@as(u32, @intCast(b.byteLen())), sel.to);
}
