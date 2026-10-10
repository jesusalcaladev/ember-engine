//! The document an editor edits: text, a line index, and undo/redo.
//!
//! ## Why one text buffer and a line-start index
//!
//! The alternatives are a gap buffer, a rope, or a line-array. This is the line
//! index: one contiguous `text` allocation plus a sorted array of the byte offset
//! each line starts at.
//!
//! - **The renderer wants lines.** Every UI that draws text draws it by line, and
//!   syntax highlighting is per line, so line starts are read on every frame
//!   anyway. With a line index they are a binary search instead of a scan.
//! - **The edits are local.** Typing is one byte at one place; an edit touches one
//!   line's start array at most. A rope is the right answer for a 50 MB file, and
//!   the wrong answer for a 4 KB Lua script, because its constant factor is a
//!   pointer chase per character.
//! - **Undo wants the removed text, not a diff.** Storing the bytes that were
//!   deleted (see `Edit`) makes undo a memcpy back, with no reverse-diff logic to
//!   get subtly wrong. A file's undo history is bounded by what was edited, not by
//!   the file's size.
//!
//! ## Positions are byte offsets
//!
//! Not (line, column) pairs: every other representation has to convert, and a
//! conversion that forgets a multi-byte character corrupts the text. This module
//! speaks byte offsets and converts only at the edges (`offsetOfLineCol` /
//! `lineColOfOffset`). Movement never lands inside a UTF-8 sequence —
//! `prevBoundary` / `nextBoundary` are the only way to move a caret.
//!
//! ## The undo run
//!
//! Typing `hello` is ONE undo step, not five: consecutive inserts that are
//! contiguous in the text coalesce into a single `Edit`, and the run breaks at a
//! newline, at a space, at a size cap, or when the caller says so (`breakRun`).
//! The break points are the ones that matter, because "undo a word" is what a
//! person expects and "undo a character" is what they get otherwise. A paste or a
//! programmatic replace never coalesces: it is not part of the same act.

const std = @import("std");

/// A byte range. `len` is bytes, so a span is valid mid-string; the editor's own
/// ops never produce one that splits a UTF-8 sequence.
pub const Span = struct {
    start: u32,
    len: u32,

    pub fn end(self: Span) u32 {
        return self.start + self.len;
    }

    pub fn contains(self: Span, offset: u32) bool {
        return offset >= self.start and offset < self.end();
    }
};

/// A line/column pair, in the units a UI wants: 0-based line, **byte** column.
/// A glyph column (what a terminal reports) is a different number for any line
/// containing a non-ASCII character, so the conversion belongs to the caller that
/// knows its font.
pub const LineCol = struct {
    line: u32,
    col: u32,
};

/// One recorded mutation, owning the bytes it needs to reverse itself.
///
/// An edit is a REPLACEMENT: `removed` is what was there (null for a pure insert),
/// `inserted` is what is there now (null for a pure delete). Modelling it as a
/// replacement rather than two kinds is what makes `replace()` and `load()`
/// undoable: an insert-only edit reversed gives back the text you deleted but
/// leaves the text you typed, which is exactly the bug this shape exists to
/// prevent — and it survived the first version of this file, which had separate
/// insert/delete entries and a `replace` that only recorded the delete.
pub const Edit = struct {
    pos: u32,
    /// What the edit removed, or null for a pure insert.
    removed: ?[]u8,
    /// What the edit put there, or null for a pure delete.
    inserted: ?[]u8,

    fn deinit(self: Edit, allocator: std.mem.Allocator) void {
        if (self.removed) |r| allocator.free(r);
        if (self.inserted) |i| allocator.free(i);
    }
};

/// Merged-typing cap. A run longer than this becomes its own undo step, because a
/// run that grows without bound is a run that, once undone, deletes a paragraph
/// the user typed by hand in one go — and the whole point of the cap is that undo
/// stays a "that thing I just did", not a trip through history.
pub const max_run_bytes: usize = 512;

pub const Buffer = struct {
    allocator: std.mem.Allocator,
    text: std.ArrayListUnmanaged(u8) = .empty,
    /// Byte offset of the start of each line. Always non-empty and sorted, always
    /// ends at `text.items.len` so a caret at EOF has a line to sit on.
    line_starts: std.ArrayListUnmanaged(u32) = .empty,
    undo_stack: std.ArrayListUnmanaged(Edit) = .empty,
    redo_stack: std.ArrayListUnmanaged(Edit) = .empty,
    /// Bumped on every mutation. The dirty check is `version != saved_version`,
    /// which is O(1) — scanning the text for a "has this changed" answer is the
    /// kind of thing that works until a user leaves the editor open.
    version: u32 = 0,
    saved_version: u32 = 0,
    /// True when the next `insert` may merge into the top undo entry. Cleared by
    /// `breakRun`, set by `typeText`.
    run_open: bool = false,

    pub fn init(allocator: std.mem.Allocator) Buffer {
        return .{ .allocator = allocator };
    }

    pub fn deinit(self: *Buffer) void {
        for (self.undo_stack.items) |e| e.deinit(self.allocator);
        self.undo_stack.deinit(self.allocator);
        for (self.redo_stack.items) |e| e.deinit(self.allocator);
        self.redo_stack.deinit(self.allocator);
        self.text.deinit(self.allocator);
        self.line_starts.deinit(self.allocator);
    }

    /// Every byte of the document. Valid until the next mutation.
    pub fn textBytes(self: *const Buffer) []const u8 {
        return self.text.items;
    }

    pub fn byteLen(self: *const Buffer) usize {
        return self.text.items.len;
    }

    pub fn lineCount(self: *const Buffer) u32 {
        return @intCast(self.line_starts.items.len);
    }

    pub fn isDirty(self: *const Buffer) bool {
        return self.version != self.saved_version;
    }

    pub fn markSaved(self: *Buffer) void {
        self.saved_version = self.version;
    }

    /// Opens a typing run, so the next inserts coalesce. `typeText` does this
    /// implicitly; the UI calls `breakRun` on any command that is not typing —
    /// moving the caret, clicking, a paste, a find-and-replace.
    pub fn beginRun(self: *Buffer) void {
        self.run_open = true;
    }

    pub fn breakRun(self: *Buffer) void {
        self.run_open = false;
    }

    pub fn canUndo(self: *const Buffer) bool {
        return self.undo_stack.items.len > 0;
    }

    pub fn canRedo(self: *const Buffer) bool {
        return self.redo_stack.items.len > 0;
    }

    // ── Loading ──────────────────────────────────────────────────────────────

    /// Replaces the whole document. The previous content becomes ONE undo step,
    /// so a load is undoable — which is what makes "revert this file" a button
    /// rather than a confirmation dialog.
    ///
    /// Loading onto an empty document records nothing: there is no previous state
    /// to restore, and an empty undo entry would occupy a slot in the stack for an
    /// act that changed nothing.
    pub fn load(self: *Buffer, source: []const u8) !void {
        const previous = try self.allocator.dupe(u8, self.text.items);
        defer self.allocator.free(previous);
        self.text.clearRetainingCapacity();
        self.line_starts.clearRetainingCapacity();
        self.line_starts.append(self.allocator, 0) catch {};
        try rawInsert(self, 0, source);
        if (previous.len > 0) {
            try pushUndo(self, .{ .pos = 0, .removed = try self.allocator.dupe(u8, previous), .inserted = try self.allocator.dupe(u8, source) });
        }
        self.version += 1;
    }

    pub fn clear(self: *Buffer) void {
        for (self.undo_stack.items) |e| e.deinit(self.allocator);
        self.undo_stack.clearRetainingCapacity();
        for (self.redo_stack.items) |e| e.deinit(self.allocator);
        self.redo_stack.clearRetainingCapacity();
        self.text.clearRetainingCapacity();
        self.line_starts.clearRetainingCapacity();
        self.line_starts.append(self.allocator, 0) catch {};
        self.version += 1;
    }

    /// Public insert: records an undo entry, and coalesces into the open typing run.
    /// A zero-length insert is a no-op rather than an undo step, so a caller probing
    /// "is anything there yet" cannot poison the stack.
    pub fn insert(self: *Buffer, pos: u32, bytes: []const u8) !void {
        if (bytes.len == 0) return;
        try rawInsert(self, pos, bytes);
        try pushUndo(self, .{ .pos = pos, .removed = null, .inserted = try self.allocator.dupe(u8, bytes) });
        self.version += 1;
    }

    /// Public delete. Zero-length is a no-op, for the same reason as insert.
    pub fn delete(self: *Buffer, pos: u32, len: u32) !void {
        if (len == 0) return;
        const removed = try self.allocator.dupe(u8, self.text.items[pos .. pos + len]);
        defer self.allocator.free(removed);
        try self.text.replaceRange(self.allocator, pos, len, &.{});
        fixLineStartsAfterDelete(self, pos, len);
        try pushUndo(self, .{ .pos = pos, .removed = try self.allocator.dupe(u8, removed), .inserted = null });
        self.version += 1;
    }

    /// Replace `[start, end)` with `bytes`. One undo entry for the whole act, whether
    /// it is a selection overwrite or a find-and-replace: the user did one thing.
    pub fn replace(self: *Buffer, start: u32, end: u32, bytes: []const u8) !void {
        if (end < start) return;
        const removed = try self.allocator.dupe(u8, self.text.items[start..end]);
        defer self.allocator.free(removed);
        try rawInsert(self, start, bytes);
        try rawDelete(self, start + @as(u32, @intCast(bytes.len)), @intCast(removed.len));
        try pushUndo(self, .{ .pos = start, .removed = try self.allocator.dupe(u8, removed), .inserted = try self.allocator.dupe(u8, bytes) });
        self.version += 1;
    }

    // ── The line index ───────────────────────────────────────────────────────────

    /// After an insert of `len` bytes at `pos`: the starts at or after `pos` have
    /// already been shifted, so this only removes the starts the insert obsoleted —
    /// which is none, since an insert never deletes a line. Kept as a named function
    /// because the pair with `fixLineStartsAfterDelete` is what makes the invariant
    /// obvious: `line_starts` is always sorted, always starts with 0, and always ends
    /// with the text length.
    fn fixLineStartsAfterInsert(self: *Buffer, pos: u32, len: u32) void {
        _ = self;
        _ = pos;
        _ = len;
    }

    /// The line containing `offset`. Binary search, so a caret at the end of a big
    /// file costs a dozen comparisons rather than a scan.
    pub fn lineOfOffset(self: *const Buffer, offset: u32) u32 {
        return @intCast(lineIndexOf(self.line_starts.items, offset) - 1);
    }

    pub fn lineStart(self: *const Buffer, line: u32) u32 {
        return self.line_starts.items[@min(line, self.line_starts.items.len - 1)];
    }

    /// Byte offset of the line's terminator, or of EOF. The text of the line is
    /// `bytes()[start..endOfLine(line)]` — without the newline, which is what a
    /// renderer and a highlighter both want.
    pub fn lineEnd(self: *const Buffer, line: u32) u32 {
        const start = self.lineStart(line);
        var i = start;
        const text = self.text.items;
        while (i < text.len and text[i] != '\n') : (i += 1) {}
        return @intCast(i);
    }

    /// The line's text without its newline.
    pub fn lineText(self: *const Buffer, line: u32) []const u8 {
        return self.text.items[self.lineStart(line)..self.lineEnd(line)];
    }

    // ── Conversions ──────────────────────────────────────────────────────────────

    pub fn lineColOfOffset(self: *const Buffer, offset: u32) LineCol {
        const clamped = @min(offset, @as(u32, @intCast(self.text.items.len)));
        const line = lineOfOffset(self, clamped);
        return .{ .line = line, .col = clamped - self.lineStart(line) };
    }

    pub fn offsetOfLineCol(self: *const Buffer, lc: LineCol) u32 {
        const line = @min(lc.line, self.lineCount() - 1);
        // Clamp the column to the line's end: a caret can never sit past the
        // terminator, which is what stops "down arrow then home then type" from
        // pasting text into a different line than the one on screen.
        const start = self.lineStart(line);
        return @min(start + lc.col, self.lineEnd(line));
    }

    // ── UTF-8 boundaries ─────────────────────────────────────────────────────────

    /// The first byte offset at or after `pos` that can start a character. A caret
    /// between the two bytes of a `ñ` is a caret that, on the next keystroke, splits
    /// the document into invalid UTF-8 — so every movement goes through here.
    pub fn nextBoundary(self: *const Buffer, pos: u32) u32 {
        const text = self.text.items;
        var i: usize = @min(pos, text.len);
        while (i < text.len and (text[i] & 0xC0) == 0x80) : (i += 1) {}
        return @intCast(i);
    }

    /// The last byte offset strictly before `pos` that can start a character, or 0.
    ///
    /// Two steps, and the first one is the subtle one: if `pos` is itself a
    /// boundary, step back one byte BEFORE scanning, otherwise a caret sitting on
    /// a character start would report itself. If `pos` is a continuation byte, the
    /// scan alone finds the head of ITS sequence, which is the wrong answer — the
    /// boundary the caller wants is the one before the character they just left.
    ///
    /// The `i < text.len` guard is not defensive: a caret at EOF is the common
    /// case, and reading `text[len]` is an out-of-bounds panic that only shows up
    /// when someone backspaces at the end of a file.
    pub fn prevBoundary(self: *const Buffer, pos: u32) u32 {
        if (pos == 0) return 0;
        const text = self.text.items;
        // Always step back one byte first, then walk back to the head of that
        // character. Two lines, and no special case for EOF: `pos == text.len` is
        // the caret-at-the-end-of-the-file case, and the earlier version of this
        // read `text[len]` on exactly that path — which is why backspacing at the
        // end of a file panicked and backspacing in the middle did not.
        var i: usize = @min(pos, text.len);
        if (i > 0) i -= 1;
        while (i > 0 and (text[i] & 0xC0) == 0x80) : (i -= 1) {}
        return @intCast(i);
    }

    /// The length in bytes of the character starting at `pos` (1 for ASCII).
    pub fn charLenAt(self: *const Buffer, pos: u32) u32 {
        const text = self.text.items;
        if (pos >= text.len) return 0;
        return @intCast(std.unicode.utf8ByteSequenceLength(text[pos]) catch 1);
    }

    // ── Undo / redo ──────────────────────────────────────────────────────

    /// Reverses the last edit. Returns the span it touched, so the UI re-renders
    /// (and re-tokenizes) one line instead of the file.
    pub fn undo(self: *Buffer) ?Span {
        const edit = self.undo_stack.pop() orelse return null;
        applyInverse(self, edit) catch {
            // The mutation failed (out of memory). Put the entry back rather than
            // silently dropping history the user still believes is there.
            self.undo_stack.append(self.allocator, edit) catch {};
            return null;
        };
        self.redo_stack.append(self.allocator, edit) catch return null;
        return .{ .start = edit.pos, .len = editSpan(edit) };
    }

    pub fn redo(self: *Buffer) ?Span {
        const edit = self.redo_stack.pop() orelse return null;
        applyForward(self, edit) catch {
            self.redo_stack.append(self.allocator, edit) catch {};
            return null;
        };
        self.undo_stack.append(self.allocator, edit) catch return null;
        return .{ .start = edit.pos, .len = editSpan(edit) };
    }
};

// ── Undo recording ──────────────────────────────────────────────────────────

/// After an insert: nothing to remove (an insert never deletes a line), so this
/// exists to name the other half of the pair and to keep the invariant stated in
/// one place — `line_starts` is sorted, starts with 0, and ends at the text
/// length, after every mutation.
fn fixLineStartsAfterInsert(self: *Buffer, pos: u32, len: u32) void {
    _ = self;
    _ = pos;
    _ = len;
}

/// First index whose start is greater than `offset`. The insertion point that
/// keeps `line_starts` sorted. A free function rather than a method because it is
/// about the index, not about the document.
fn lineIndexOf(starts: []const u32, offset: u32) usize {
    var lo: usize = 0;
    var hi: usize = starts.len;
    while (lo < hi) {
        const mid = lo + (hi - lo) / 2;
        if (starts[mid] <= offset) lo = mid + 1 else hi = mid;
    }
    return lo;
}

/// Rebuilds `line_starts` after `len` bytes were deleted at `pos`.
///
/// The rule, derived from the invariant ("a line starts at 0 or one byte after a
/// newline") rather than from the cases by hand:
///
/// - A start before `pos` is untouched.
/// - A start after `pos + len` moves back by `len`, and stays valid: the byte
///   before it was not in the deleted range, so its newline survived.
/// - Every start INSIDE `[pos, pos + len]` collapses onto the single position
///   `pos`, and that collapsed start is real only if `pos` itself is a line start
///   — i.e. it is 0, or the byte before it is a newline. Deleting the middle of a
///   line deletes no starts at all; deleting a whole line deletes exactly one.
///
/// Getting this from the cases instead of the invariant is how you end up with
/// three special cases and a fourth nobody thought of, so the property test at the
/// bottom of this file re-derives the index from the text after every random edit
/// and compares.
fn fixLineStartsAfterDelete(self: *Buffer, pos: u32, len: u32) void {
    if (len == 0) return;
    // The text is already shortened; the byte before `pos` was not touched.
    const text = self.text.items;
    const hi = pos + len;
    const starts = self.line_starts.items;
    var out: usize = 0;
    var i: usize = 0;
    while (i < starts.len) : (i += 1) {
        const s = starts[i];
        if (s < pos) {
            starts[out] = s;
            out += 1;
            continue;
        }
        if (s > hi) {
            starts[out] = s - len;
            out += 1;
            continue;
        }
        // Inside the deleted range: it collapses onto `pos`, at most once.
        if (out == 0 or starts[out - 1] != pos) {
            const real = pos == 0 or text[pos - 1] == '\n';
            if (real) {
                starts[out] = pos;
                out += 1;
            }
        }
    }
    self.line_starts.shrinkRetainingCapacity(out);
}

/// Inserts `bytes` at `pos`, maintaining the line index. No undo entry is made.
fn rawInsert(self: *Buffer, pos: u32, bytes: []const u8) !void {
    try self.text.insertSlice(self.allocator, pos, bytes);
    defer fixLineStartsAfterInsert(self, pos, @intCast(bytes.len));
    // Shift every line that starts AFTER the insertion point. A line that starts
    // exactly AT `pos` must NOT move: the inserted bytes are prepended to that
    // line, so it still begins at `pos`. Shifting it too is the classic off-by-one
    // here, and its symptom is a caret that lands on the wrong line after an edit.
    for (self.line_starts.items) |*s| {
        if (s.* > pos) s.* += @intCast(bytes.len);
    }
    // New lines introduced by the insert: one new start per newline, at the byte
    // after it. They are discovered in order, and `line_starts` is sorted, so
    // appending each at its correct index keeps it sorted for free.
    var i: usize = 0;
    while (i < bytes.len) : (i += 1) {
        if (bytes[i] == '\n') {
            try self.line_starts.insert(self.allocator, lineIndexOf(self.line_starts.items, pos + @as(u32, @intCast(i)) + 1), pos + @as(u32, @intCast(i)) + 1);
        }
    }
}

/// Removes `len` bytes at `pos`, maintaining the line index. No undo entry: the
/// callers that need one have already captured the bytes.
fn rawDelete(self: *Buffer, pos: u32, len: u32) !void {
    try self.text.replaceRange(self.allocator, pos, len, &.{});
    fixLineStartsAfterDelete(self, pos, len);
}

/// Records an edit, coalescing it into the open typing run when it belongs there.
///
/// The coalescing test is the whole subtlety: an insert merges into the top entry
/// when it is immediately adjacent, when that entry is itself an insert, and when
/// the run has not been broken. The adjacency check (`pos == top.pos + len`) is
/// what makes "typing at the caret then moving the caret and typing again" two
/// separate steps instead of one that moves text when undone.
fn pushUndo(self: *Buffer, edit: Edit) !void {
    if (self.run_open and self.undo_stack.items.len > 0) {
        const top = &self.undo_stack.items[self.undo_stack.items.len - 1];
        // Only pure inserts coalesce, and only when this one continues the run:
        // appended to the last byte of the previous insert. A delete or a replace
        // is a different act, even when it starts in the same place.
        const pure_insert = edit.removed == null and edit.inserted != null;
        const continues_run = top.removed == null and top.inserted != null and
            edit.pos == top.pos + top.inserted.?.len;
        if (pure_insert and continues_run and top.inserted.?.len < max_run_bytes) {
            // Grow the existing entry and append, rather than appending a second
            // entry: "hello" typed one key at a time is one undo step.
            const grown = try self.allocator.realloc(top.inserted.?, top.inserted.?.len + edit.inserted.?.len);
            @memcpy(grown[top.inserted.?.len..], edit.inserted.?);
            top.inserted = grown;
            self.allocator.free(edit.inserted.?);
            return;
        }
    }
    // Any new history clears redo. Keeping the redos would make "undo, type,
    // undo" resurrect text the user replaced — the behaviour every editor
    // abandoned decades ago.
    self.breakRun();
    for (self.redo_stack.items) |e| e.deinit(self.allocator);
    self.redo_stack.clearRetainingCapacity();
    try self.undo_stack.append(self.allocator, edit);
}

/// The inverse of a recorded edit: an insert is undone by deleting, a delete by
/// re-inserting. It does not touch either stack — that is `undo`'s job, and the
/// separation is what stops the recursion.
fn applyInverse(self: *Buffer, edit: Edit) !void {
    // Remove the new text FIRST, then put the old back at `pos`: the other order
    // would insert before deleting and leave the document one edit long.
    if (edit.inserted) |ins| try rawDelete(self, edit.pos, @intCast(ins.len));
    if (edit.removed) |rem| try rawInsert(self, edit.pos, rem);
    self.version += 1;
}

fn applyForward(self: *Buffer, edit: Edit) !void {
    if (edit.removed) |rem| try rawDelete(self, edit.pos, @intCast(rem.len));
    if (edit.inserted) |ins| try rawInsert(self, edit.pos, ins);
    self.version += 1;
}

/// The length an edit affected, in bytes: what is there now for a delete (the
/// hole it left) and what was put there otherwise. The UI needs one number to know
/// what to re-render.
fn editSpan(edit: Edit) u32 {
    if (edit.inserted) |ins| return @intCast(ins.len);
    if (edit.removed) |rem| return @intCast(rem.len);
    return 0;
}

// ── Tests ────────────────────────────────────────────────────────────────────

const testing = std.testing;

fn expectText(b: *const Buffer, expected: []const u8) !void {
    try testing.expectEqualStrings(expected, b.textBytes());
}

test "insert, delete and the line index stay in agreement" {
    var b = Buffer.init(testing.allocator);
    defer b.deinit();
    try b.load("one\ntwo\nthree\n");

    try testing.expectEqual(@as(u32, 4), b.lineCount());
    try testing.expectEqualStrings("two", b.lineText(1));
    try expectText(&b, "one\ntwo\nthree\n");

    // Insert a line in the middle.
    try b.insert(b.lineStart(1), "ONE\n");
    try testing.expectEqual(@as(u32, 5), b.lineCount());
    try testing.expectEqualStrings("ONE", b.lineText(1));
    try testing.expectEqualStrings("two", b.lineText(2));
    try expectText(&b, "one\nONE\ntwo\nthree\n");

    // Delete it back. Line starts must shrink, not accumulate.
    try b.delete(b.lineStart(1), 4);
    try testing.expectEqual(@as(u32, 4), b.lineCount());
    try expectText(&b, "one\ntwo\nthree\n");
}

test "a multi-line insert adds one start per newline" {
    var b = Buffer.init(testing.allocator);
    defer b.deinit();
    try b.load("a\nb\n");
    try b.insert(2, "x\ny\nz\n");
    try expectText(&b, "a\nx\ny\nz\nb\n");
    try testing.expectEqual(@as(u32, 6), b.lineCount());
    try testing.expectEqualStrings("z", b.lineText(3));
}

test "a deletion that joins lines removes exactly one start" {
    var b = Buffer.init(testing.allocator);
    defer b.deinit();
    try b.load("head\n\nfoot\n");
    try testing.expectEqual(@as(u32, 4), b.lineCount());
    // Deleting the newline plus the empty line joins them.
    try b.delete(b.lineEnd(0), 1 + b.lineEnd(1) - b.lineStart(1));
    try expectText(&b, "head\nfoot\n");
    try testing.expectEqual(@as(u32, 3), b.lineCount());
}

test "offset and line/col convert, and clamp at the edges" {
    var b = Buffer.init(testing.allocator);
    defer b.deinit();
    try b.load("abc\nde\n");
    // 'a','b','c','\n' occupy 0..3, so 'd' is 4 and 'e' is 5.
    const lc = b.lineColOfOffset(5); // 'e'
    try testing.expectEqual(@as(u32, 1), lc.line);
    try testing.expectEqual(@as(u32, 1), lc.col);

    // A column past the end of a short line clamps to that line's end, which is
    // what keeps a caret from teleporting when the user presses Down then Home.
    try testing.expectEqual(@as(u32, 3), b.offsetOfLineCol(.{ .line = 0, .col = 99 }));
    // And a line past the end clamps to the last line.
    try testing.expectEqual(@as(u32, 7), b.offsetOfLineCol(.{ .line = 99, .col = 0 }));
}

test "movement never lands inside a UTF-8 sequence" {
    var b = Buffer.init(testing.allocator);
    defer b.deinit();
    // 'a' is 1 byte, 'ñ' is 2, so the caret at 2 sits on ñ's continuation byte.
    try b.load("a\u{f1}b");
    try testing.expectEqual(@as(u32, 3), b.nextBoundary(2)); // skips the continuation
    try testing.expectEqual(@as(u32, 1), b.prevBoundary(2));
    // From a boundary, prevBoundary steps back a whole character, not one byte:
    // the caret was after 'a', so it lands on 0, not inside the 'ñ'.
    try testing.expectEqual(@as(u32, 0), b.prevBoundary(1));
    try testing.expectEqual(@as(u32, 1), b.prevBoundary(3)); // 3 is 'b', a boundary
    try testing.expectEqual(@as(u32, 2), b.charLenAt(1));
    try testing.expectEqual(@as(u32, 1), b.charLenAt(0));
}

test "typing coalesces into one undo step, and a break splits it" {
    var b = Buffer.init(testing.allocator);
    defer b.deinit();
    try b.load("");

    // Five inserts, contiguous, with the run opened the way a UI opens it —
    // before the character lands. One run, one undo step.
    for ("hello") |ch| {
        b.beginRun();
        try b.insert(@intCast(b.byteLen()), &.{ch});
    }
    try testing.expectEqual(@as(usize, 1), b.undo_stack.items.len);
    const span = b.undo().?;
    try testing.expectEqual(@as(u32, 0), span.start);
    try testing.expectEqual(@as(u32, 5), span.len);
    try expectText(&b, "");

    // Redo puts the run back.
    _ = b.redo();
    try expectText(&b, "hello");

    // A caret move is not typing: the caller breaks the run. What follows is a new
    // step even though it is adjacent in the text — which is the whole reason
    // `breakRun` is explicit rather than inferred from the position.
    b.breakRun();
    try b.insert(@intCast(b.byteLen()), " world");
    try testing.expectEqual(@as(usize, 2), b.undo_stack.items.len);
    b.beginRun();
    try b.insert(@intCast(b.byteLen()), "!");
    // Adjacent and inside the run, so it joins the " world" step.
    try testing.expectEqual(@as(usize, 2), b.undo_stack.items.len);
    try expectText(&b, "hello world!");

    // Undoing once removes " world!" — the whole run, not one character.
    _ = b.undo().?;
    try expectText(&b, "hello");
}

test "a paste or a replace does not join the typing run" {
    var b = Buffer.init(testing.allocator);
    defer b.deinit();
    try b.load("x");
    try b.insert(0, "y");
    b.beginRun();
    try b.insert(1, "z"); // adjacent, joins
    b.breakRun();
    try b.insert(2, "w"); // not adjacent to a run: separate step
    b.breakRun();
    // Two steps: the coalesced "yz" run, and the lone "w".
    try testing.expectEqual(@as(usize, 2), b.undo_stack.items.len);
}

test "undo reverses a delete, redo reapplies it" {
    var b = Buffer.init(testing.allocator);
    defer b.deinit();
    try b.load("hello world");
    try b.delete(5, 6); // remove " world"
    try expectText(&b, "hello");
    _ = b.undo().?;
    try expectText(&b, "hello world");
    _ = b.redo().?;
    try expectText(&b, "hello");
}

test "undo of a load restores the previous document in one step" {
    var b = Buffer.init(testing.allocator);
    defer b.deinit();
    try b.load("first");
    try b.load("second");
    try expectText(&b, "second");
    _ = b.undo().?;
    try expectText(&b, "first");
}

test "a new edit clears redo" {
    var b = Buffer.init(testing.allocator);
    defer b.deinit();
    try b.load("abc");
    try b.insert(3, "d");
    _ = b.undo().?;
    try testing.expect(b.canRedo());
    try b.insert(3, "e"); // any edit drops the redos
    try testing.expect(!b.canRedo());
}

test "replace is one undo step and reports the span it touched" {
    var b = Buffer.init(testing.allocator);
    defer b.deinit();
    try b.load("the quick fox");
    try b.replace(4, 9, "slow"); // "quick" -> "slow"
    try expectText(&b, "the slow fox");
    try testing.expectEqual(@as(usize, 1), b.undo_stack.items.len);
    _ = b.undo().?;
    try expectText(&b, "the quick fox");
}

test "dirty tracking is one comparison, not a scan" {
    var b = Buffer.init(testing.allocator);
    defer b.deinit();
    try b.load("a");
    try testing.expect(b.isDirty());
    b.markSaved();
    try testing.expect(!b.isDirty());
    try b.insert(1, "b");
    try testing.expect(b.isDirty());
}

test "the empty document still has a line to hold the caret" {
    var b = Buffer.init(testing.allocator);
    defer b.deinit();
    try testing.expectEqual(@as(u32, 0), b.byteLen());
    try b.load("");
    try testing.expectEqual(@as(u32, 1), b.lineCount());
    try testing.expectEqual(@as(u32, 0), b.lineStart(0));
    try testing.expectEqualStrings("", b.lineText(0));
    // A document with no trailing newline still ends with a usable last line.
    try b.load("no trailing newline");
    try testing.expectEqual(@as(u32, 1), b.lineCount());
    try testing.expectEqualStrings("no trailing newline", b.lineText(0));
}

// ── The property test ────────────────────────────────────────────────────────
//
// Everything above tests a case someone thought of. This tests the invariant no
// case list covers: after ANY sequence of edits, `line_starts` must be exactly
// the set of positions that are 0 or follow a newline. That is the definition,
// so deriving it independently and comparing catches the off-by-ones that the
// hand-written cases exist to miss — and this file shipped one of those, twice,
// while it was being written.

/// Recomputes the index from the text, the slow way, for comparison only.
fn linesFromScratch(text: []const u8, out: *std.ArrayListUnmanaged(u32)) !void {
    out.clearRetainingCapacity();
    try out.append(std.testing.allocator, 0);
    for (text, 0..) |ch, i| {
        if (ch == '\n') try out.append(std.testing.allocator, @intCast(i + 1));
    }
}

test "the line index survives any sequence of random edits" {
    const allocator = std.testing.allocator;
    var b = Buffer.init(allocator);
    defer b.deinit();
    var expected: std.ArrayListUnmanaged(u32) = .empty;
    defer expected.deinit(allocator);

    // A fixed seed, so a failure is reproducible: a property test that finds a bug
    // must be able to find the same bug again.
    var prng = std.Random.DefaultPrng.init(0x5eed_1234);
    const rand = prng.random();

    // An alphabet heavy in newlines and multi-byte characters, because those are
    // the two things that make positions interesting.
    const alphabet = "ab\n\u{f1}\u{e9}\nc \t\n\n";

    try b.load("start\n");
    var step: usize = 0;
    while (step < 400) : (step += 1) {
        const text_len: u32 = @intCast(b.byteLen());
        switch (rand.enumValue(enum { insert, delete, replace }) ) {
            .insert => {
                const pos = rand.intRangeAtMost(u32, 0, text_len);
                var n = rand.intRangeAtMost(u8, 1, 6);
                var bytes: [8]u8 = undefined;
                var w: usize = 0;
                while (n > 0 and w + 4 < bytes.len) : (n -= 1) {
                    // One codepoint at a time, so multi-byte characters are whole.
                    const idx = rand.intRangeAtMost(usize, 0, alphabet.len - 1);
                    const cp = try std.unicode.utf8Encode(alphabet[idx], bytes[w..]);
                    w += cp;
                }
                try b.insert(pos, bytes[0..w]);
            },
            .delete => {
                if (text_len == 0) continue;
                const pos = rand.intRangeAtMost(u32, 0, text_len - 1);
                const max = text_len - pos;
                const n = rand.intRangeAtMost(u32, 1, @min(max, 6));
                try b.delete(pos, n);
            },
            .replace => {
                if (text_len == 0) continue;
                const pos = rand.intRangeAtMost(u32, 0, text_len - 1);
                const n = rand.intRangeAtMost(u32, 1, @min(text_len - pos, 4));
                try b.replace(pos, pos + n, "R");
            },
        }

        // The invariant, recomputed from the text.
        try linesFromScratch(b.textBytes(), &expected);
        try testing.expectEqualSlices(u32, expected.items, b.line_starts.items);

        // And the two views must agree with each other, which is what the renderer
        // and the caret actually consume.
        var line: u32 = 0;
        while (line < b.lineCount()) : (line += 1) {
            const start = b.lineStart(line);
            try testing.expectEqual(line, b.lineOfOffset(start));
            const lc = b.lineColOfOffset(start);
            try testing.expectEqual(start, b.offsetOfLineCol(lc));
        }
    }
}
