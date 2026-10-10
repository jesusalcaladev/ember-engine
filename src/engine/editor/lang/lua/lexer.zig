//! Lua tokenizer for the editor's syntax highlighting.
//!
//! ## Why a hand-written scanner and not a parser
//!
//! Highlighting is a per-frame cost paid on the whole visible file, and it answers
//! exactly one question: "what colour is this run of bytes". A parser answers a
//! much harder question ("what does this mean"), and the answer is not needed —
//! worse, a parser would make the highlighter fail on a half-typed line, which is
//! the normal state of a file being edited. A scanner that never fails and never
//! allocates is the right tool; the parse-error markers M5.5 wants later are a
//! separate pass with different requirements.
//!
//! ## The two hard cases
//!
//! 1. **`--` vs `--[[`**. A `--` comment runs to the end of the line; a `--[[`
//!   long comment runs until the matching `]]`, across lines. Getting this wrong
//!   colors the rest of the file as a comment, which is the most visible bug a
//!   highlighter can ship.
//! 2. **Long strings**: `[[ ... ]]` and `[==[ ... ]==]`, where the number of `=`
//!   signs must match. The level is not optional: `[==[` does not close on `]]`.
//!
//! Both are handled with the same rule — a bracket level — because Lua's two long
//! forms are one rule with different delimiters, and an implementation that
//! special-cases each one is an implementation that gets one of them wrong.
//!
//! ## What is emitted
//!
//! A flat list of `Span{ start, len, kind }` covering the text with no gaps and no
//! overlaps, so the renderer can walk it once and draw a run per span. Whitespace
//! is a span like any other: the renderer needs to know it is not a token, and a
//! gap in the list would mean a colour the editor never chose.

const std = @import("std");

pub const Kind = enum {
    /// Ordinary bytes: whitespace, and identifiers that are not keywords.
    plain,
    /// `--` line comments and `--[[ ]]` long comments.
    comment,
    /// Short strings, long strings, and quoted string escapes.
    string,
    /// Numeric literals, decimal and hex.
    number,
    /// Lua keywords: `if`, `local`, `function`, ...
    keyword,
    /// The engine's globals: `actor`, `self`, `math`, ...
    global,
    /// A member of something: the `x` in `self.x`, including after `.` and `:`.
    field,
    /// Operators and punctuation.
    operator,
    /// Bytes that cannot start any token. Rendered in an error colour, which is
    /// how a stray byte in a string literal becomes visible instead of invisible.
    invalid,
};

/// A coloured run. `len` is bytes; a span never splits a UTF-8 sequence because
/// the scanner only ever advances past whole codepoints.
pub const Span = struct {
    start: u32,
    len: u32,
    kind: Kind,
};

/// The Lua keywords. Lua 5.1 (which is what LuaJIT implements) has no `goto` and
/// no `continue`, so neither is here: highlighting `continue` as a keyword would
/// tell a user the line does something, and it silently does not.
const keywords = [_][]const u8{
    "and",   "break", "do",   "else",     "elseif", "end",   "false", "for",
    "function", "if", "in",   "local",    "nil",    "not",   "or",    "repeat",
    "return", "then", "true", "until",    "while",
};

/// Names that exist in every Ember script. Kept as its own kind rather than
/// folded into keywords because they are the engine's own vocabulary — the words
/// a user is most likely to look up — and colouring them distinctly makes a typo
/// (`actr.get_position`) visible on the line it is written.
///
/// Public because the diagnostics read it too: an unknown global and a
/// miscoloured global are the same question answered twice, and two answers is
/// one drift too many.
pub const globals = [_][]const u8{
    "actor", "input", "log", "math", "noise", "physics", "rand", "self",
    "sm", "steer", "vec2", "world",
    // The Lua standard library, which is whitelisted by the sandbox.
    "assert", "collectgarbage", "error", "ipairs", "next", "pairs", "pcall",
    "print", "rawequal", "rawget", "rawset", "require", "select", "setmetatable",
    "string", "table", "tonumber", "tostring", "type", "unpack", "xpcall",
};

fn isKeyword(word: []const u8) bool {
    for (keywords) |k| if (std.mem.eql(u8, k, word)) return true;
    return false;
}

fn isGlobal(word: []const u8) bool {
    for (globals) |g| if (std.mem.eql(u8, g, word)) return true;
    return false;
}

fn isIdentByte(ch: u8) bool {
    return std.ascii.isAlphanumeric(ch) or ch == '_';
}

fn isDigit(ch: u8) bool {
    return ch >= '0' and ch <= '9';
}

/// Tokenizes `text`, pushing spans into `out`.
///
/// `out` is not cleared, so a caller can tokenize one line at a time into a
/// reused buffer — the offsets are absolute, which is what makes that work.
pub fn tokenize(text: []const u8, out: *std.ArrayListUnmanaged(Span), allocator: std.mem.Allocator) !void {
    var i: usize = 0;
    while (i < text.len) {
        const start = i;
        const ch = text[i];

        // ── Whitespace ───────────────────────────────────────────────────────
        if (ch == ' ' or ch == '\t' or ch == '\r' or ch == '\n') {
            while (i < text.len and (text[i] == ' ' or text[i] == '\t' or text[i] == '\r' or text[i] == '\n')) : (i += 1) {}
            try push(out, allocator, start, i - start, .plain);
            continue;
        }

        // ── Comments: `--`, `--[[`, `--[==[` ─────────────────────────────────
        if (ch == '-' and i + 1 < text.len and text[i + 1] == '-') {
            i += 2;
            // A long comment starts with a level's opening bracket.
            if (i < text.len and text[i] == '[') {
                if (try scanLong(text, &i)) |content_end| {
                    // Success: skip past the closing bracket too.
                    i = content_end;
                    try push(out, allocator, start, i - start, .comment);
                    continue;
                }
            }
            // A short comment: to the end of the line. It stops at the newline
            // rather than consuming it, so the newline stays its own span and a
            // renderer that draws per line does not lose it.
            while (i < text.len and text[i] != '\n') : (i += 1) {}
            try push(out, allocator, start, i - start, .comment);
            continue;
        }

        // ── Strings ──────────────────────────────────────────────────────────
        if (ch == '"' or ch == '\'') {
            i += 1;
            while (i < text.len) {
                const c = text[i];
                if (c == '\\') {
                    // Skip the escape and whatever it escapes, so `\"` does not
                    // end the string and `\` alone at end of line does not run
                    // into the next one.
                    i += 2;
                    continue;
                }
                if (c == ch) {
                    i += 1;
                    break;
                }
                if (c == '\n') break; // unterminated: stop at the line
                i += 1;
            }
            try push(out, allocator, start, i - start, .string);
            continue;
        }

        // A long string: `[[ ... ]]`, `[==[ ... ]==]`.
        if (ch == '[') {
            const save = i;
            if (try scanLong(text, &i)) |content_end| {
                i = content_end;
                try push(out, allocator, start, i - start, .string);
                continue;
            }
            i = save; // not a long bracket after all: falls through to operators
        }

        // ── Numbers ──────────────────────────────────────────────────────────
        if (isDigit(ch) or (ch == '.' and i + 1 < text.len and isDigit(text[i + 1]))) {
            if (ch == '0' and i + 1 < text.len and (text[i + 1] == 'x' or text[i + 1] == 'X')) {
                i += 2;
                while (i < text.len and (isDigit(text[i]) or (text[i] | 0x20) == 'a' or (text[i] | 0x20) == 'b' or (text[i] | 0x20) == 'c' or (text[i] | 0x20) == 'd' or (text[i] | 0x20) == 'e' or (text[i] | 0x20) == 'f')) : (i += 1) {}
            } else {
                while (i < text.len and (isDigit(text[i]) or text[i] == '.')) : (i += 1) {}
                // Exponent. Only after the mantissa, so `1e5` is one number and
                // `and5` is not.
                if (i < text.len and (text[i] == 'e' or text[i] == 'E')) {
                    var j = i + 1;
                    if (j < text.len and (text[j] == '+' or text[j] == '-')) j += 1;
                    if (j < text.len and isDigit(text[j])) {
                        i = j;
                        while (i < text.len and isDigit(text[i])) : (i += 1) {}
                    }
                }
            }
            try push(out, allocator, start, i - start, .number);
            continue;
        }

        // ── Identifiers, keywords, globals, fields ───────────────────────────
        if (std.ascii.isAlphabetic(ch) or ch == '_') {
            var was_field = false;
            // Walk back over whitespace to see whether a `.` or `:` preceded this
            // name: `self.x` and `obj:method` are field reads, not globals. The
            // walk is bounded by the identifier's own start, so this is O(spaces).
            var k: usize = start;
            while (k > 0 and (text[k - 1] == ' ' or text[k - 1] == '\t')) k -= 1;
            if (k > 0 and (text[k - 1] == '.' or text[k - 1] == ':')) was_field = true;

            while (i < text.len and isIdentByte(text[i])) : (i += 1) {}
            const word = text[start..i];

            // A name immediately followed by `(` is being called, which is the
            // same information to a reader either way — but a field is still a
            // field, so the `.`/`:` test wins.
            var kind: Kind = .plain;
            if (!was_field) {
                if (isKeyword(word)) kind = .keyword else if (isGlobal(word)) kind = .global;
            } else {
                kind = .field;
            }
            try push(out, allocator, start, i - start, kind);
            continue;
        }

        // ── Operators and punctuation ────────────────────────────────────────
        // `...` is the vararg, and it is three bytes — so it must be tested before
        // the two-character forms, or `..` eats the first two and the display
        // shows two operators where the user typed one token.
        if (i + 2 < text.len and std.mem.eql(u8, text[i .. i + 3], "...")) {
            i += 3;
            try push(out, allocator, start, i - start, .operator);
            continue;
        }
        // Two-character forms next, so `==` is one span and not two.
        if (i + 1 < text.len) {
            const two = text[i .. i + 2];
            if (std.mem.eql(u8, two, "==") or std.mem.eql(u8, two, "~=") or
                std.mem.eql(u8, two, "<=") or std.mem.eql(u8, two, ">=") or
                std.mem.eql(u8, two, "..") or std.mem.eql(u8, two, "::") or
                std.mem.eql(u8, two, "//") or std.mem.eql(u8, two, "<<"))
            {
                i += 2;
                try push(out, allocator, start, i - start, .operator);
                continue;
            }
        }
        const single = "+-*/%^#=<>(){}[];:,.";
        if (std.mem.indexOfScalar(u8, single, ch) != null) {
            i += 1;
            try push(out, allocator, start, i - start, .operator);
            continue;
        }

        // ── Anything else ────────────────────────────────────────────────────
        // A multi-byte character: advance past the whole codepoint so the span
        // does not split it, and colour it as plain — a `ñ` inside an identifier
        // is not an error, it is a name.
        if (ch >= 0x80) {
            i += std.unicode.utf8ByteSequenceLength(ch) catch 1;
            try push(out, allocator, start, i - start, .plain);
            continue;
        }
        i += 1;
        try push(out, allocator, start, i - start, .invalid);
    }
}

/// Scans a long bracket at `i` (`[`, `[=`, `[==`, ...), and on success leaves `i`
/// past the CLOSING bracket, returning its end. On failure (no bracket here)
/// `i` is left where the caller put it and null is returned.
///
/// Shared by strings and comments because they differ only in what comes before
/// the bracket — `--` or nothing — and a rule that covers both is a rule that
/// cannot disagree with itself.
fn scanLong(text: []const u8, i: *usize) !?usize {
    var p = i.*;
    if (p >= text.len or text[p] != '[') return null;
    p += 1;
    var level: usize = 0;
    while (p < text.len and text[p] == '=') : (p += 1) level += 1;
    if (p >= text.len or text[p] != '[') return null; // an index like `t[1]`
    p += 1;

    // The closing bracket for this level, built on the stack: no allocation, and
    // `"=" ** level` is not a comptime expression when the level came from the
    // text. A stack buffer of 64 covers every level Lua's own parser accepts.
    var buf: [64]u8 = undefined;
    buf[0] = ']';
    var w: usize = 1;
    var eq: usize = 0;
    while (eq < level and w < buf.len - 1) : (eq += 1) {
        buf[w] = '=';
        w += 1;
    }
    buf[w] = ']';
    w += 1;
    const close = buf[0..w];

    // Search from just after the opening bracket. `indexOfPos` on the closing
    // sequence is exact — and, unlike a naive `]]` search, respects the level.
    const found = std.mem.indexOfPos(u8, text, p, close) orelse {
        // Unterminated: consume to the end of the text rather than looping
        // forever, and let the caller colour it as a comment to EOF.
        i.* = text.len;
        return text.len;
    };
    p = found + close.len;
    i.* = p;
    return p;
}

fn push(out: *std.ArrayListUnmanaged(Span), allocator: std.mem.Allocator, start: usize, len: usize, kind: Kind) !void {
    try out.append(allocator, .{
        .start = @intCast(start),
        .len = @intCast(len),
        .kind = kind,
    });
}

// ── Tests ────────────────────────────────────────────────────────────────────

const testing = std.testing;

/// The token list of a short input, filled into a fixed buffer and returned BY
/// VALUE: no allocation, so no test can leak, and no slice to dangle. Every string
/// used below is far shorter than the buffer, and a longer one fails loudly.
const max_spans = 64;
const TokenList = struct {
    n: usize = 0,
    items: [max_spans]Kind = undefined,
};

fn kindsOf(text: []const u8, allocator: std.mem.Allocator) !TokenList {
    var spans: std.ArrayListUnmanaged(Span) = .empty;
    defer spans.deinit(allocator);
    try tokenize(text, &spans, allocator);
    var out: TokenList = .{};
    for (spans.items, 0..) |sp, idx| {
        if (idx >= max_spans) return error.TooManySpans;
        out.items[idx] = sp.kind;
    }
    out.n = spans.items.len;
    return out;
}

/// The concatenated text of every span of one kind, for checking WHERE a kind
/// landed rather than only that it did.
const TextList = struct {
    n: usize = 0,
    items: [512]u8 = undefined,
};

fn textOfKind(text: []const u8, want: Kind, allocator: std.mem.Allocator) !TextList {
    var spans: std.ArrayListUnmanaged(Span) = .empty;
    defer spans.deinit(allocator);
    try tokenize(text, &spans, allocator);
    var out: TextList = .{};
    for (spans.items) |sp| {
        if (sp.kind != want) continue;
        const slice = text[sp.start .. sp.start + sp.len];
        if (out.n + slice.len > out.items.len) return error.TooManyBytes;
        @memcpy(out.items[out.n..][0..slice.len], slice);
        out.n += slice.len;
    }
    return out;
}

/// The kinds of a short input, as a slice ready for `expectEqualSlices`.
fn kindsOfSlice(text: []const u8, allocator: std.mem.Allocator, out: *[max_spans]Kind) ![]const Kind {
    const list = try kindsOf(text, allocator);
    out.* = list.items;
    return out[0..list.n];
}

test "keywords, globals and plain identifiers are told apart" {
    const a = std.testing.allocator;
    var buf: [max_spans]Kind = undefined;
    try testing.expectEqualSlices(Kind, &.{.keyword}, try kindsOfSlice("if", a, &buf));
    try testing.expectEqualSlices(Kind, &.{.global}, try kindsOfSlice("self", a, &buf));
    // A name that is neither, and a near-miss of an engine global.
    try testing.expectEqualSlices(Kind, &.{.plain}, try kindsOfSlice("my_var", a, &buf));
    try testing.expectEqualSlices(Kind, &.{.plain}, try kindsOfSlice("actr", a, &buf));
}

test "a member access is a field, not a global" {
    const a = std.testing.allocator;
    var buf: [max_spans]Kind = undefined;
    // `self.px` is one global followed by an operator and a field.
    try testing.expectEqualSlices(Kind, &.{ .global, .operator, .field }, try kindsOfSlice("self.px", a, &buf));
    // Even when the name is a keyword: `t.end` reads a field.
    try testing.expectEqualSlices(Kind, &.{ .plain, .operator, .field }, try kindsOfSlice("t.end", a, &buf));
}

test "a short comment stops at the newline and does not eat it" {
    const a = std.testing.allocator;
    var buf: [max_spans]Kind = undefined;
    try testing.expectEqualSlices(Kind, &.{ .comment, .plain, .plain }, try kindsOfSlice("-- hi\nx", a, &buf));
}

test "a long comment runs to the matching bracket, across lines" {
    const a = std.testing.allocator;
    // `--[[` ... `]]`, and everything in between is one comment, newlines included.
    const text = "--[[ a\nb ]] x";
    const comments = try textOfKind(text, .comment, a);
    try testing.expectEqualStrings("--[[ a\nb ]]", comments.items[0..comments.n]);

    const rest = try textOfKind(text, .plain, a);
    try testing.expectEqualStrings(" x", rest.items[0..rest.n]);
}

test "the long-bracket level is respected" {
    const a = std.testing.allocator;
    // The outer bracket is level 1, so the inner `]]` does not close it: only the
    // `]=]` does. Getting this wrong colours half the file as a string.
    const text = "[==[ outer ]] inner ]==] after";
    const strings = try textOfKind(text, .string, a);
    try testing.expectEqualStrings("[==[ outer ]] inner ]==]", strings.items[0..strings.n]);

    const rest = try textOfKind(text, .plain, a);
    try testing.expectEqualStrings(" after", rest.items[0..rest.n]);
}

test "a table index is not a long string" {
    const a = std.testing.allocator;
    var buf: [max_spans]Kind = undefined;
    // `t[1]` has no `=` and no second `[`, so it is brackets and a number.
    try testing.expectEqualSlices(Kind, &.{ .plain, .operator, .number, .operator }, try kindsOfSlice("t[1]", a, &buf));
}

test "string escapes do not end the string early" {
    const a = std.testing.allocator;
    const s = try textOfKind("\"a\\\"b\"", .string, a);
    try testing.expectEqualStrings("\"a\\\"b\"", s.items[0..s.n]);
}

test "numbers keep their shape" {
    const a = std.testing.allocator;
    var buf: [max_spans]Kind = undefined;
    try testing.expectEqualSlices(Kind, &.{.number}, try kindsOfSlice("42", a, &buf));
    try testing.expectEqualSlices(Kind, &.{.number}, try kindsOfSlice("0xff", a, &buf));
    try testing.expectEqualSlices(Kind, &.{.number}, try kindsOfSlice("1.5", a, &buf));
    try testing.expectEqualSlices(Kind, &.{.number}, try kindsOfSlice("1e-5", a, &buf));
    try testing.expectEqualSlices(Kind, &.{.number}, try kindsOfSlice(".5", a, &buf));
    // `and5` is ONE identifier, not a keyword plus a number: a scanner that split
    // it would colour half a word, and Lua itself reads it as a name.
    try testing.expectEqualSlices(Kind, &.{.plain}, try kindsOfSlice("and5", a, &buf));
    // With a space it really is the keyword.
    try testing.expectEqualSlices(Kind, &.{ .keyword, .plain, .number }, try kindsOfSlice("and 5", a, &buf));
}

test "operators are grouped and multi-byte forms are one span" {
    const a = std.testing.allocator;
    var buf: [max_spans]Kind = undefined;
    try testing.expectEqualSlices(Kind, &.{.operator}, try kindsOfSlice("==", a, &buf));
    try testing.expectEqualSlices(Kind, &.{.operator}, try kindsOfSlice("...", a, &buf));
    try testing.expectEqualSlices(Kind, &.{.operator}, try kindsOfSlice("..", a, &buf));
    // Two dots separated by a space are two operators with whitespace between.
    try testing.expectEqualSlices(Kind, &.{ .operator, .plain, .operator }, try kindsOfSlice(". .", a, &buf));
}

test "the spans cover the text exactly, with no gap or overlap" {
    // The renderer walks the list once and draws a run per span, so a gap would
    // mean bytes with no colour and an overlap would mean drawn twice.
    const a = std.testing.allocator;
    const text =
        \\local x = 1 -- set x
        \\self.px = x + 0.5
        \\--[[ a long
        \\comment ]]
        \\for i = 1, 10 do print(i) end
    ;
    var spans: std.ArrayListUnmanaged(Span) = .empty;
    defer spans.deinit(a);
    try tokenize(text, &spans, a);

    var at: u32 = 0;
    for (spans.items) |sp| {
        try testing.expectEqual(at, sp.start);
        try testing.expect(sp.len > 0);
        at = sp.start + sp.len;
    }
    try testing.expectEqual(@as(u32, @intCast(text.len)), at);
}

test "a multi-byte character inside a name stays whole" {
    const a = std.testing.allocator;
    var buf: [max_spans]Kind = undefined;
    // 'ñ' is two bytes; the span must cover both, or the renderer draws a
    // replacement glyph in the middle of a word.
    // Three spans, because 'ñ' is not an ASCII identifier byte — but the middle
    // one is exactly two bytes, which is the property that matters: the renderer
    // draws one glyph, not a replacement character in the middle of a word.
    try testing.expectEqualSlices(Kind, &.{ .plain, .plain, .plain }, try kindsOfSlice("a\u{f1}b", a, &buf));
}

test "an unterminated long comment does not loop forever" {
    const a = std.testing.allocator;
    // No closing bracket: the scanner consumes to EOF and returns, which is the
    // difference between a red line and a hung editor.
    var spans: std.ArrayListUnmanaged(Span) = .empty;
    defer spans.deinit(a);
    try tokenize("--[[ never closed", &spans, a);
    try testing.expectEqual(@as(usize, 1), spans.items.len);
    try testing.expectEqual(Kind.comment, spans.items[0].kind);
}
