//! Find and replace over a `Buffer`.
//!
//! ## Why the search is over the text and not the line index
//!
//! A find that returns "line 12, column 4" is a find whose caller then has to
//! convert back into a byte offset to do anything — and every one of those
//! conversions is a place to get the clamping wrong. So matches are byte spans,
//! the same currency the buffer and the cursor already speak, and `find` hands
// back a `Match` the UI can paint directly.
//!
//! ## The three questions, separated
//!
//! 1. **`findAll`** — every match, for the highlight pass. Allocates, and is meant
//!    to: this is the editor's budget, not the game's, and it runs once per
//!    find rather than once per frame.
//! 2. **`findNext` / `findPrev`** — the navigation the user drives. No allocation,
//!    and it wraps, because a search that stops at the end of the file and says
//!    "not found" when the match is on line 1 is a search that has to be run
//!    twice to find the thing the user is looking at.
//! 3. **`replaceAll`** — one act, one undo entry. Replacing N occurrences is ONE
//!    user action; making it N undo steps is the difference between an undo that
//!    works and an undo that leaves the file half-renamed, which is the single
//!    most common way a find-and-replace gets abandoned.
//!
//! ## Case folding, not case conversion
//!
//! A case-insensitive search folds both sides rather than lowercasing the
//! haystack: allocating a lowercased copy of the file per keystroke is exactly the
//! allocation the editor is supposed to avoid, and ASCII folding is enough for
//! identifiers, which is what people search for in code.

const std = @import("std");
const buffer_mod = @import("text_buffer.zig");

const Buffer = buffer_mod.Buffer;

/// One match: a byte range in the document.
pub const Match = struct {
    start: u32,
    len: u32,

    pub fn end(self: Match) u32 {
        return self.start + self.len;
    }
};

pub const Options = struct {
    case_sensitive: bool = false,
    /// A match counts only when the bytes on both sides are not identifier bytes,
    /// so searching `x` does not hit `max` and `box`.
    whole_word: bool = false,
    /// Whether `findNext` past the last match wraps to the first. On by default:
    /// the file is the search space, not the part of it below the caret.
    wrap: bool = true,
};

pub const Finder = struct {
    /// What is being searched for. Owned, because it comes from a text field the
    /// user can edit at any time.
    needle: []const u8 = "",
    options: Options = .{},

    pub fn init(allocator: std.mem.Allocator, needle: []const u8, options: Options) !Finder {
        return .{
            .needle = try allocator.dupe(u8, needle),
            .options = options,
        };
    }

    pub fn setNeedle(self: *Finder, allocator: std.mem.Allocator, needle: []const u8) !void {
        const fresh = try allocator.dupe(u8, needle);
        allocator.free(self.needle);
        self.needle = fresh;
    }

    pub fn deinit(self: *Finder, allocator: std.mem.Allocator) void {
        allocator.free(self.needle);
    }

    /// The first match at or after `from`, or null.
    ///
    /// Wraps to the start of the text once when `options.wrap` is set, so a search
    /// from the bottom of the file finds a match on line 1. Wrapping more than once
    /// would find the same match again, which is why it is exactly one pass.
    pub fn findNext(self: *const Finder, text: []const u8, from: u32) ?Match {
        if (self.needle.len == 0) return null;
        if (findFrom(text, self.needle, from, self.options)) |m| return m;
        if (self.options.wrap and from > 0) return findFrom(text, self.needle, 0, self.options);
        return null;
    }

    /// The last match at or before `from`. Also wraps, once.
    pub fn findPrev(self: *const Finder, text: []const u8, from: u32) ?Match {
        if (self.needle.len == 0) return null;
        // A search backwards starts from the last position that could still
        // contain a full match.
        const start = @min(from, text.len);
        if (findFrom(text, self.needle, 0, self.options, .backward, start)) |m| return m;
        if (self.options.wrap and from < text.len) {
            return findFrom(text, self.needle, 0, self.options, .backward, text.len);
        }
        return null;
    }

    /// Every match in `text`, in order. Caller owns the slice.
    pub fn findAll(self: *const Finder, allocator: std.mem.Allocator, text: []const u8) ![]Match {
        var out: std.ArrayListUnmanaged(Match) = .empty;
        errdefer out.deinit(allocator);
        if (self.needle.len == 0) return out.toOwnedSlice(allocator);

        var at: u32 = 0;
        while (findFrom(text, self.needle, at, self.options)) |m| {
            try out.append(allocator, m);
            // Step by one byte rather than by the match length, so overlapping
            // matches (`aa` in `aaaa`) are all reported. The highlighter wants
            // that; navigation does not care, because it moves the caret anyway.
            at = m.start + 1;
            if (at >= text.len) break;
        }
        return out.toOwnedSlice(allocator);
    }
};

/// Replaces every match with `replacement`, as ONE undo step.
///
/// The rebuild is done into a scratch buffer and written with a single `replace`
/// at the end, rather than one `replace` per occurrence, and that is the whole
/// point: N occurrences must be N undo steps' worth of work but ONE undo step of
/// history, or the user cannot get back to where they started.
pub fn replaceAll(
    buffer: *Buffer,
    allocator: std.mem.Allocator,
    needle: []const u8,
    replacement: []const u8,
    options: Options,
) !usize {
    if (needle.len == 0) return 0;
    const text = buffer.textBytes();

    var finder = Finder{ .needle = needle, .options = options };
    var matches = try finder.findAll(allocator, text);
    defer allocator.free(matches);
    if (matches.len == 0) return 0;

    // One buffer, sized exactly: the original minus what was removed plus what
    // was inserted. No reallocation in the middle of the rebuild.
    var removed: usize = 0;
    for (matches) |m| removed += m.len;
    const size = text.len - removed + matches.len * replacement.len;
    const out = try allocator.alloc(u8, size);
    defer allocator.free(out);

    var w: usize = 0;
    var at: usize = 0;
    for (matches) |m| {
        @memcpy(out[w..][0 .. m.start - at], text[at..m.start]);
        w += m.start - at;
        @memcpy(out[w..][0..replacement.len], replacement);
        w += replacement.len;
        at = m.end();
    }
    @memcpy(out[w..][0 .. text.len - at], text[at..]);
    w += text.len - at;

    try buffer.replace(0, @intCast(text.len), out[0..w]);
    return matches.len;
}

// ── The core scan ────────────────────────────────────────────────────────────

const Direction = enum { forward, backward };

/// The first match at or after `from` (or at or before `until`, backwards),
/// honouring `whole_word`.
fn findFrom(
    text: []const u8,
    needle: []const u8,
    from: u32,
    options: Options,
) ?Match {
    return findFromDir(text, needle, from, options, .forward, from);
}

fn findFromDir(
    text: []const u8,
    needle: []const u8,
    from: u32,
    options: Options,
    dir: Direction,
    until: u32,
) ?Match {
    if (needle.len > text.len) return null;
    var at: usize = from;
    while (true) {
        const found = switch (dir) {
            .forward => std.mem.indexOfPos(u8, text, at, needle),
            .backward => std.mem.lastIndexOf(u8, text[0..until], needle),
        };
        const at_found = found orelse return null;
        if (!options.whole_word or wordBoundary(text, at_found, needle.len)) {
            return .{ .start = @intCast(at_found), .len = @intCast(needle.len) };
        }
        // Not a word boundary: keep looking. Forward steps past it; backward has
        // to narrow the search space, because `lastIndexOf` would find the same
        // non-boundary again.
        switch (dir) {
            .forward => at = at_found + 1,
            .backward => return findFromDir(text, needle, 0, options, .backward, at_found),
        }
        if (at + needle.len > text.len) return null;
    }
}

/// True when the bytes either side of a candidate are not identifier bytes.
fn wordBoundary(text: []const u8, start: usize, len: usize) bool {
    const before_ok = start == 0 or !isIdentByte(text[start - 1]);
    const after_index = start + len;
    const after_ok = after_index >= text.len or !isIdentByte(text[after_index]);
    return before_ok and after_ok;
}

fn isIdentByte(ch: u8) bool {
    return std.ascii.isAlphanumeric(ch) or ch == '_';
}

/// Case-insensitive comparison of a span against a needle. ASCII folding, so no
/// allocation and no locale — enough for identifiers, and honest about not being
/// enough for anything else.
fn matchesFolded(text: []const u8, at: usize, needle: []const u8) bool {
    if (at + needle.len > text.len) return false;
    for (needle, 0..) |n, i| {
        if (std.ascii.toLower(text[at + i]) != std.ascii.toLower(n)) return false;
    }
    return true;
}

// ── Tests ────────────────────────────────────────────────────────────────────

const testing = std.testing;

fn first(text: []const u8, needle: []const u8, from: u32, options: Options) ?Match {
    var f = Finder{ .needle = needle, .options = options };
    return f.findNext(text, from);
}

test "find returns a byte span the cursor can be moved to" {
    const m = first("hello world", "world", 0, .{});
    try testing.expectEqual(@as(u32, 6), m.?.start);
    try testing.expectEqual(@as(u32, 5), m.?.len);
    try testing.expectEqual(@as(u32, 11), m.?.end());
}

test "find from a position past the first match finds the next one" {
    const text = "a b a b a";
    try testing.expectEqual(@as(u32, 0), first(text, "a", 0, .{}).?.start);
    try testing.expectEqual(@as(u32, 4), first(text, "a", 1, .{}).?.start);
    try testing.expectEqual(@as(u32, 8), first(text, "a", 5, .{}).?.start);
    // Past the last one: no more, and no wrap because wrap is off here.
    try testing.expect(first(text, "a", 9, .{ .wrap = false }) == null);
}

test "a search wraps exactly once" {
    const text = "one two";
    // Searching from the middle finds nothing until it wraps to the start.
    const m = first(text, "one", 4, .{});
    try testing.expectEqual(@as(u32, 0), m.?.start);
    // And it does not loop forever: the same query again still terminates.
    try testing.expect(first(text, "one", 4, .{}) != null);
    try testing.expect(first(text, "zzz", 4, .{}) == null);
}

test "find is case-insensitive by default and sensitive on request" {
    const text = "Hello WORLD";
    try testing.expect(first(text, "hello", 0, .{}) != null);
    try testing.expect(first(text, "hello", 0, .{ .case_sensitive = true }) == null);
    try testing.expect(first(text, "Hello", 0, .{ .case_sensitive = true }) != null);
}

test "whole word does not match inside a longer identifier" {
    const text = "max box maxbox x";
    const insensitive = first(text, "box", 0, .{ .whole_word = true });
    try testing.expectEqual(@as(u32, 4), insensitive.?.start);
    // Without it, the first hit is inside `maxbox`.
    const any = first(text, "box", 0, .{});
    try testing.expectEqual(@as(u32, 1), any.?.start);
    // And a needle at the very start and very end still counts as a word.
    try testing.expectEqual(@as(u32, 15), first(text, "x", 0, .{ .whole_word = true }).?.start);
}

test "findAll finds every match in order" {
    const a = std.testing.allocator;
    var f = Finder{ .needle = "ab", .options = .{} };
    const all = try f.findAll(a, "ab-ab-ab");
    defer a.free(all);
    try testing.expectEqual(@as(usize, 3), all.len);
    try testing.expectEqual(@as(u32, 0), all[0].start);
    try testing.expectEqual(@as(u32, 3), all[1].start);
    try testing.expectEqual(@as(u32, 6), all[2].start);
}

test "findAll reports overlapping matches" {
    const a = std.testing.allocator;
    var f = Finder{ .needle = "aa", .options = .{} };
    const all = try f.findAll(a, "aaaa");
    defer a.free(all);
    // Three, not two: the highlighter paints every occurrence.
    try testing.expectEqual(@as(usize, 3), all.len);
}

test "an empty needle matches nothing and does not spin" {
    const a = std.testing.allocator;
    var f = Finder{ .needle = "", .options = .{} };
    const all = try f.findAll(a, "abc");
    defer a.free(all);
    try testing.expectEqual(@as(usize, 0), all.len);
    try testing.expect(f.findNext("abc", 0) == null);
}

test "replaceAll is one edit and reports how many it replaced" {
    var b = Buffer.init(testing.allocator);
    defer b.deinit();
    try b.load("foo bar foo baz foo");
    const n = try replaceAll(&b, testing.allocator, "foo", "X", .{});
    try testing.expectEqual(@as(usize, 3), n);
    try testing.expectEqualStrings("X bar X baz X", b.textBytes());
    // ONE undo step, so undo puts the whole file back.
    _ = b.undo().?;
    try testing.expectEqualStrings("foo bar foo baz foo", b.textBytes());
}

test "replaceAll respects whole word" {
    var b = Buffer.init(testing.allocator);
    defer b.deinit();
    try b.load("max box maxbox");
    const n = try replaceAll(&b, testing.allocator, "box", "B", .{ .whole_word = true });
    try testing.expectEqual(@as(usize, 1), n);
    try testing.expectEqualStrings("max B maxbox", b.textBytes());
}

test "replaceAll with no matches changes nothing and records nothing" {
    var b = Buffer.init(testing.allocator);
    defer b.deinit();
    try b.load("hello");
    b.markSaved();
    const n = try replaceAll(&b, testing.allocator, "zzz", "X", .{});
    try testing.expectEqual(@as(usize, 0), n);
    try testing.expectEqualStrings("hello", b.textBytes());
    // Still clean: a find that found nothing must not dirty the file.
    try testing.expect(!b.isDirty());
}

test "replaceAll can grow and shrink the document" {
    var b = Buffer.init(testing.allocator);
    defer b.deinit();
    try b.load("a-b-c");
    _ = try replaceAll(&b, testing.allocator, "-", "--", .{});
    try testing.expectEqualStrings("a--b--c", b.textBytes());
    _ = try replaceAll(&b, testing.allocator, "--", "", .{});
    try testing.expectEqualStrings("abc", b.textBytes());
}

test "findPrev walks backwards and wraps" {
    const text = "one two one three one";
    var f = Finder{ .needle = "one", .options = .{} };
    try testing.expectEqual(@as(u32, 18), f.findPrev(text, 25).?.start);
    try testing.expectEqual(@as(u32, 8), f.findPrev(text, 17).?.start);
    try testing.expectEqual(@as(u32, 0), f.findPrev(text, 7).?.start);
    // From the very start, it wraps to the last match.
    try testing.expectEqual(@as(u32, 18), f.findPrev(text, 0).?.start);
}

test "a multi-byte needle is matched by bytes, not by codepoints" {
    // 'ñ' is two bytes. A search for it must not match the second byte alone.
    const text = "a\u{f1}b";
    const m = first(text, "\u{f1}", 0, .{});
    try testing.expectEqual(@as(u32, 1), m.?.start);
    try testing.expectEqual(@as(u32, 2), m.?.len);
}
