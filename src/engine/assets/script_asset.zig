//! Script asset validation (M6): what the importer checks about a `.lua` file
//! before the script layer ever sees it.
//!
//! ## The scope line
//!
//! This module answers "is this a text Lua source file?", not "does this Lua
//! compile?". Compilation is LuaJIT's job and is already wired: the runtime's
//! `script.Behaviors`/`Scripts` compiles and hot-reloads chunks. Re-implementing
//! a Lua parser here would be a second, weaker source of truth, and it would
//! reject a valid file the day it disagreed with the real one. So the checks are
//! exactly the ones a *parser cannot* make for you:
//!
//! - **non-empty** — an empty script is a mistake, not a program;
//! - **no NUL bytes** — the tell-tale of a file that is not source at all;
//! - **valid UTF-8** — the editor lexes, colours and completes by UTF-8
//!   codepoint; a script it cannot decode is a script it renders as noise;
//! - **within the size cap** — a bound that keeps the frame arena honest later.
//!
//! It also strips a leading UTF-8 BOM, because a BOM before `function` is the
//! one byte sequence that silently breaks `loadstring` on some editors' output.

const std = @import("std");

pub const ScriptError = error{
    Empty,
    ContainsNul,
    NotUtf8,
    TooLarge,
};

/// The largest script the importer will accept. Generous for hand-written code,
/// small enough that a mis-typed `.lua` pointing at a binary is refused fast.
pub const default_max_bytes: usize = 8 * 1024 * 1024;

pub const Validated = struct {
    /// The source to compile: BOM already removed, everything else untouched.
    source: []const u8,
    /// True when a UTF-8 BOM was present and stripped.
    had_bom: bool,
    /// Byte length of `source` after stripping.
    size: usize,
};

/// Validates a script's bytes. On success the returned `source` is a sub-slice
/// of the input (no allocation); the caller owns the original buffer.
pub fn validate(bytes: []const u8, max_bytes: usize) ScriptError!Validated {
    if (bytes.len > max_bytes) return error.TooLarge;

    var source = bytes;
    var had_bom = false;
    if (std.mem.startsWith(u8, source, "\xEF\xBB\xBF")) {
        source = source[3..];
        had_bom = true;
    }

    if (source.len == 0) return error.Empty;
    if (std.mem.indexOfScalar(u8, source, 0) != null) return error.ContainsNul;
    if (!std.unicode.utf8ValidateSlice(source)) return error.NotUtf8;

    return .{ .source = source, .had_bom = had_bom, .size = source.len };
}

// ── Tests ────────────────────────────────────────────────────────────────────

const testing = std.testing;

test "a plain Lua script passes and is returned unchanged" {
    const src = "local function update(self, dt)\n  self.x = self.x + dt\nend\n";
    const v = try validate(src, default_max_bytes);
    try testing.expectEqualStrings(src, v.source);
    try testing.expect(!v.had_bom);
}

test "a UTF-8 BOM is stripped so the first token is really the first token" {
    const v = try validate("\xEF\xBB\xBFfunction f() end", default_max_bytes);
    try testing.expect(v.had_bom);
    try testing.expectEqualStrings("function f() end", v.source);
}

test "empties, NULs, binary and oversize files are each refused" {
    try testing.expectError(error.Empty, validate("", default_max_bytes));
    try testing.expectError(error.Empty, validate("\xEF\xBB\xBF", default_max_bytes));

    try testing.expectError(error.ContainsNul, validate("function f()\x00 end", default_max_bytes));

    // A byte that is the start of a multi-byte sequence with no continuation is
    // invalid UTF-8 (and a good stand-in for a renamed binary: no NUL to trip
    // the earlier check first).
    try testing.expectError(error.NotUtf8, validate("local x = \xFF\xFEy", default_max_bytes));

    try testing.expectError(error.TooLarge, validate("aaaa", 3));
}

test "valid multi-byte UTF-8 in a string literal is accepted" {
    const src = "local greeting = \"hola, mañana — señor\"\n";
    _ = try validate(src, default_max_bytes);
}
