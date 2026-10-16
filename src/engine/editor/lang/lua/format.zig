//! `editor.lang.lua.format` — the Lua formatter, run on save.
//!
//! ## What this is, and what it is not
//!
//! It is an INDENTATION and whitespace formatter: it fixes indentation, trims
//! trailing whitespace, collapses blank runs, and guarantees one trailing
//! newline. It is not a pretty-printer that reflows expressions — wrapping a
//! long call across lines requires knowing what the code MEANS, and a formatter
//! that guesses wrong is worse than none because the user has to review every
//! diff it produces. This one only ever changes leading whitespace, trailing
//! whitespace, and blank lines, so its diff is boring in exactly the way a
//! format-on-save diff must be.
//!
//! ## Why it uses the lexer and not just the text
//!
//! The two things that make a whitespace formatter dangerous are multi-line
//! strings and multi-line comments: `[[ ... ]]` and `--[[ ... ]]`. Reindenting
//! a line INSIDE one of those changes the string's value, and trimming its
//! trailing space changes it too. So the formatter runs the same tokenizer the
//! highlighter uses, and any line whose start lies inside a `string` or
//! `comment` token is copied VERBATIM. That is the whole reason the lexer exists
//! one directory over and is reused here rather than hand-parsed.
//!
//! ## The block model
//!
//! Indentation is a running depth, updated per line by the block keywords on
//! it. The rules are Lua's, spelled out once:
//!
//! - `function`, `do`, `repeat`, and `then` (for an `if`) open a level;
//! - `end` and `until` close one;
//! - `else` and `elseif` sit at the OUTER level (they dedent the line) without
//!   changing the depth, because an `if/elseif/else` chain is one block closed
//!   by one `end`;
//! - an `elseif` line's `then` does NOT open a level — the distinction between
//!   `if … then` and `elseif … then` is the single subtlety here, and it is why
//!   `then` is conditional on the line's first keyword.
//!
//! Because the depth is a NET per line (`opens - closes`), one-liners fall out
//! for free: `if x then return end` opens and closes on the same line and its
//! net is zero, so the line after it is unaffected.
//!
//! ## Known limitation
//!
//! A block keyword split across lines (`if a and\n   b then`) indents the
//! continuation at the current depth rather than one deeper, because the opener
//! (`then`) is on the second line. Handling that needs the parser, not the
//! lexer; it is stated here so nobody mistakes it for a bug.

const std = @import("std");
const lexer = @import("lexer.zig");
const buffer_mod = @import("../../doc/buffer.zig");
const Buffer = buffer_mod.Buffer;

pub const Options = struct {
    /// Spaces per level when `use_tabs` is false.
    indent: u8 = 4,
    /// Indent with one `\t` per level instead of spaces. Off by default: a tab
    /// renders at a different width in every tool, and a formatter that picks
    /// one width for the user is a formatter that starts an argument.
    use_tabs: bool = false,
    /// How many consecutive blank lines to keep. 1 keeps a single separator
    /// between functions and collapses the accidental runs; 0 removes them all.
    max_blank_lines: u8 = 1,
    /// Always end the file with exactly one newline.
    final_newline: bool = true,
};

/// Formats `source` and returns the new text, owned by the caller. The source is
/// not modified.
pub fn format(allocator: std.mem.Allocator, source: []const u8, opts: Options) ![]u8 {
    if (source.len == 0) return allocator.dupe(u8, "");

    var tokens: std.ArrayListUnmanaged(lexer.Span) = .empty;
    defer tokens.deinit(allocator);
    try lexer.tokenize(source, &tokens, allocator);
    const toks = tokens.items;

    var out: std.ArrayListUnmanaged(u8) = .empty;
    errdefer out.deinit(allocator);

    var depth: i32 = 0;
    var blank_run: u8 = 0;
    // The token cursor: the one token that could contain the current line's
    // start. It only ever moves forward, so the whole pass over the token list
    // is O(tokens), not O(tokens x lines).
    var ti: usize = 0;

    var line_start: usize = 0;
    while (line_start < source.len) {
        var line_end = line_start;
        while (line_end < source.len and source[line_end] != '\n') : (line_end += 1) {}

        while (ti < toks.len and @as(usize, toks[ti].start) + toks[ti].len <= line_start) ti += 1;
        const starts_inside = ti < toks.len and toks[ti].start < line_start and
            (toks[ti].kind == .string or toks[ti].kind == .comment);

        if (starts_inside) {
            // Inside a long string or comment: copy VERBATIM. Reindenting here
            // edits the string's value, which is the bug this check exists for.
            if (out.items.len > 0) try out.append(allocator, '\n');
            try out.appendSlice(allocator, source[line_start..line_end]);
            blank_run = 0;
        } else {
            // `ti` is already the first token with `end > line_start`: the caller
            // advanced it above, for the `starts_inside` test. Handing it over is
            // what makes this loop linear in the tokens rather than in their
            // product with the line count.
            const cls = classify(source, toks, ti, line_end);

            // Trim leading whitespace for the emptiness test and the content.
            var content_start = line_start;
            while (content_start < line_end and (source[content_start] == ' ' or source[content_start] == '\t')) : (content_start += 1) {}

            if (content_start == line_end) {
                // A blank line. Emit at most `max_blank_lines` of them, and
                // never a leading one (out is empty, so the separator is
                // skipped and nothing is written).
                if (blank_run < opts.max_blank_lines) {
                    if (out.items.len > 0) try out.append(allocator, '\n');
                    blank_run += 1;
                }
            } else {
                const indent_level: i32 = @max(depth - cls.dedent, 0);
                if (out.items.len > 0) try out.append(allocator, '\n');
                if (opts.use_tabs) {
                    var k: i32 = 0;
                    while (k < indent_level) : (k += 1) try out.append(allocator, '\t');
                } else {
                    var k: i32 = 0;
                    while (k < indent_level) : (k += 1) {
                        var s: u8 = 0;
                        while (s < opts.indent) : (s += 1) try out.append(allocator, ' ');
                    }
                }
                // Trailing whitespace is trimmed for a code line, but NOT when
                // the line ends inside a long string: there the space is part
                // of the value.
                var content_end = line_end;
                if (!cls.ends_in_string) {
                    while (content_end > content_start and
                        (source[content_end - 1] == ' ' or source[content_end - 1] == '\t' or source[content_end - 1] == '\r')) : (content_end -= 1)
                    {}
                }
                try out.appendSlice(allocator, source[content_start..content_end]);
                blank_run = 0;
            }

            depth = @max(depth + cls.opens - cls.closes, 0);
        }

        if (line_end >= source.len) break;
        line_start = line_end + 1;
    }

    if (opts.final_newline and out.items.len > 0 and out.items[out.items.len - 1] != '\n') {
        try out.append(allocator, '\n');
    }
    return out.toOwnedSlice(allocator);
}

/// Formats the document in place as ONE undo step, and reports whether it
/// changed anything.
///
/// One `replace` is the point: a user who hits "format on save" and dislikes the
/// result undoes it once. A formatter that emits an edit per line is a formatter
/// whose undo has to be pressed two hundred times.
pub fn formatBuffer(allocator: std.mem.Allocator, buf: *Buffer, opts: Options) !bool {
    const formatted = try format(allocator, buf.textBytes(), opts);
    defer allocator.free(formatted);
    if (std.mem.eql(u8, formatted, buf.textBytes())) return false;
    try buf.replace(0, @intCast(buf.byteLen()), formatted);
    return true;
}

const Classified = struct {
    opens: i32 = 0,
    closes: i32 = 0,
    /// 1 when the line's first keyword is `end`, `until`, `else` or `elseif`, so
    /// the LINE is indented one level out.
    dedent: i32 = 0,
    /// True when a `string` or `comment` token crosses `line_end`: the line ends
    /// inside a long literal, so its trailing whitespace is content.
    ends_in_string: bool = false,
};

fn classify(source: []const u8, toks: []const lexer.Span, start_index: usize, line_end: usize) Classified {
    var c: Classified = .{};
    var first_is_elseif = false;
    var seen_first = false;
    // `start_index` is the caller's token cursor: the first span whose end is
    // past this line's start. It is a PARAMETER, and that is the whole point.
    //
    // The previous version took `line_start` and found that span itself, with a
    // scan from index 0 — O(tokens) per line, i.e. O(tokens x lines) per file.
    // The caller had ALREADY advanced its cursor to the same span and, because
    // `classify` was not given it, the work was done a second time and thrown
    // away. Measured on a 20 000-line, 1.4 MB document: 54 seconds to format a
    // file the tokenizer reads in about half a second, and every one of those
    // seconds was this scan. Formatting is on the Ctrl+S path, so the cost was
    // paid on the keystroke that is supposed to feel instant.
    var j: usize = start_index;

    while (j < toks.len and toks[j].start < line_end) : (j += 1) {
        const tk = toks[j];
        if ((tk.kind == .string or tk.kind == .comment) and @as(usize, tk.start) + tk.len > line_end) {
            c.ends_in_string = true;
        }
        if (tk.kind != .keyword) continue;
        const word = source[tk.start .. @as(usize, tk.start) + tk.len];
        if (!seen_first) {
            seen_first = true;
            if (std.mem.eql(u8, word, "elseif")) first_is_elseif = true;
            if (std.mem.eql(u8, word, "end") or std.mem.eql(u8, word, "until") or
                std.mem.eql(u8, word, "else") or std.mem.eql(u8, word, "elseif"))
            {
                c.dedent = 1;
            }
        }
        if (std.mem.eql(u8, word, "function") or std.mem.eql(u8, word, "do") or std.mem.eql(u8, word, "repeat")) {
            c.opens += 1;
        } else if (std.mem.eql(u8, word, "then")) {
            if (!first_is_elseif) c.opens += 1;
        } else if (std.mem.eql(u8, word, "end") or std.mem.eql(u8, word, "until")) {
            c.closes += 1;
        }
    }
    return c;
}

// ── Tests ────────────────────────────────────────────────────────────────

const testing = std.testing;

fn expectFormat(input: []const u8, expected: []const u8) !void {
    const got = try format(testing.allocator, input, .{});
    defer testing.allocator.free(got);
    try testing.expectEqualStrings(expected, got);
}

test "ui format: a function body is indented and the end dedents" {
    try expectFormat(
        "function f()\nreturn 1\nend\n",
        "function f()\n    return 1\nend\n",
    );
}

test "ui format: if / elseif / else / end form one block" {
    // The elseif trap: its `then` must not open a second level, and the `else`
    // must sit one level out. Getting either wrong doubles the indentation on
    // every branch.
    try expectFormat(
        "if a then\nx()\nelseif b then\ny()\nelse\nz()\nend\n",
        "if a then\n    x()\nelseif b then\n    y()\nelse\n    z()\nend\n",
    );
}

test "ui format: a one-liner does not change the depth" {
    // `if x then return end` opens and closes on the same line. The line after
    // it must be at the same level as the line before.
    try expectFormat(
        "local function g()\nif x then return end\nreturn 2\nend\n",
        "local function g()\n    if x then return end\n    return 2\nend\n",
    );
}

test "ui format: for and while open on do, and close on end" {
    try expectFormat(
        "for i = 1, 10 do\nprint(i)\nend\nwhile true do\nbreak\nend\n",
        "for i = 1, 10 do\n    print(i)\nend\nwhile true do\n    break\nend\n",
    );
}

test "ui format: repeat and until" {
    try expectFormat(
        "repeat\nx = x + 1\nuntil x > 10\n",
        "repeat\n    x = x + 1\nuntil x > 10\n",
    );
}

test "ui format: nested blocks stack" {
    try expectFormat(
        "function outer()\nif a then\nfor i = 1, 2 do\nprint(i)\nend\nend\nend\n",
        "function outer()\n    if a then\n        for i = 1, 2 do\n            print(i)\n        end\n    end\nend\n",
    );
}

test "ui format: trailing whitespace is trimmed and a final newline is added" {
    try expectFormat("local x = 1   \nlocal y = 2\t", "local x = 1\nlocal y = 2\n");
}

test "ui format: blank runs collapse to one" {
    try expectFormat(
        "local a = 1\n\n\n\nlocal b = 2\n",
        "local a = 1\n\nlocal b = 2\n",
    );
}

test "ui format: a multi-line string is copied verbatim" {
    // The line inside the `[[ ]]` keeps its own indentation and its trailing
    // space: both are the string's VALUE, and a formatter that touches them
    // corrupts data.
    const input = "local s = [[\n  keep   this indent  \n]]\nlocal x = 1\n";
    const expected = "local s = [[\n  keep   this indent  \n]]\nlocal x = 1\n";
    try expectFormat(input, expected);
}

test "ui format: a long comment is copied verbatim" {
    const input = "local x = 1\n--[[\n   as typed  \n]]\nlocal y = 2\n";
    try expectFormat(input, input);
}

test "ui format: formatting is idempotent" {
    // The property a format-on-save file must have: running it twice is the
    // same as running it once, or the file shows up modified in git every time
    // it is opened and closed.
    const messy = "function f()\nif a then\n\n\n return 1   \nend\nend";
    const once = try format(testing.allocator, messy, .{});
    defer testing.allocator.free(once);
    const twice = try format(testing.allocator, once, .{});
    defer testing.allocator.free(twice);
    try testing.expectEqualStrings(once, twice);
}

test "ui format: a keyword inside a string is not a block keyword" {
    // `end` inside a string must not dedent the line after it — which is only
    // true because the classification reads token KINDS, not raw text.
    const input = "local s = \"end\"\nlocal x = 1\n";
    const expected = "local s = \"end\"\nlocal x = 1\n";
    try expectFormat(input, expected);
}

test "ui format: tabs mode indents with one tab per level" {
    const got = try format(testing.allocator, "function f()\nreturn 1\nend\n", .{ .use_tabs = true });
    defer testing.allocator.free(got);
    try testing.expectEqualStrings("function f()\n\treturn 1\nend\n", got);
}

test "ui format: the buffer round trip is one undo step and is a no-op when clean" {
    var b = Buffer.init(testing.allocator);
    defer b.deinit();
    try b.load("function f()\nreturn 1\nend\n");
    b.markSaved();
    const changed = try formatBuffer(testing.allocator, &b, .{});
    try testing.expect(changed);
    try testing.expectEqualStrings("function f()\n    return 1\nend\n", b.textBytes());
    // One undo step, not one per line.
    try testing.expectEqual(@as(usize, 1), b.undo_stack.items.len);
    // And formatting an already-formatted document changes nothing.
    const again = try formatBuffer(testing.allocator, &b, .{});
    try testing.expect(!again);
}
