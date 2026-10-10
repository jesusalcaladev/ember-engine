//! Hover: what is this name, and where does it come from?
//!
//! ROADMAP M5.5 asks for the whole API one Ctrl+Click away — a panel with the
//! description, the typed parameters, the return value and the example. This is
//! the data half of that: given a byte offset, it answers "what is this" from the
//! two places the answer can live.
//!
//! 1. **A documented binding.** `actor.get_` resolves through the registry to a
//!    signature, a one-line summary, typed parameters with defaults and notes,
//!    typed returns, and the runnable example that is the M3 acceptance
//!    criterion — every binding has one, so the panel never shows an empty
//!    block. The registry is the same source the autocomplete popup and the stub
//!    generator read, so the three can never disagree.
//! 2. **A name from this file.** A local or a parameter hover gives its
//!    declaration, as a byte range: that is go-to-definition, and the outline
//!    jump is the same operation with the offset of the symbol's name.
//!
//! ## What hover is not
//!
//! It is not the panel. The panel paints a table of parameters and decides the
//! colour; this only returns the rows, which is what keeps it testable without
//! a window and reusable — the in-editor console, the help index and the
//! (post-1.0) LSP all ask the same question.

const std = @import("std");
const parser = @import("parser.zig");
const api_meta = @import("api_meta");

/// Where the answer came from, so the UI can shape the panel: a binding gets
/// signature + parameters + example, a local name gets a declaration.
pub const Kind = enum {
    binding,
    symbol,
};

pub const Topic = struct {
    /// The name as written: `actor.get_position`, or the local's own name.
    name: []const u8,
    kind: Kind,
    /// The registry's one-line summary. Empty for a name from this file.
    summary: []const u8 = "",
    /// The full signature, e.g. `"actor.set_position(self, x, y)"`.
    signature: []const u8 = "",
    /// Typed parameters, with defaults and per-parameter notes.
    params: []const api_meta.Param = &.{},
    returns: []const api_meta.Return = &.{},
    /// A complete runnable snippet, as every binding is required to have.
    example: []const u8 = "",
    /// For a name from this file: the byte range of the whole declaration, so
    /// Ctrl+Click has somewhere to go.
    decl_start: u32 = 0,
    decl_len: u32 = 0,
};

/// The name under the caret: the path it completes, walked out to its edges.
/// `actor.get_position` is one name, not three — a hover on `position` is a
/// hover on the whole path, and a scan that stopped at the last dot would
/// answer "position", which is not a name.
pub fn nameAt(src: []const u8, offset: u32) []const u8 {
    const caret: usize = @min(offset, src.len);
    // A separator immediately before the caret means a member is being read
    // and nothing has been typed after it yet. The name the caret is on starts
    // here, and is empty — a hover right after `actor.` says nothing about a
    // member that does not exist, rather than offering the table twice.
    if (caret > 0 and (src[caret - 1] == '.' or src[caret - 1] == ':')) {
        var hi = caret;
        while (hi < src.len and isPathByte(src[hi])) hi += 1;
        return src[caret..hi];
    }
    // Otherwise the caret is inside a path, and a path is one name:
    // `actor.get_position` is not three hover targets.
    var lo = caret;
    while (lo > 0 and isPathByte(src[lo - 1])) lo -= 1;
    var hi = caret;
    while (hi < src.len and isPathByte(src[hi])) hi += 1;
    while (lo < hi and (src[lo] == '.' or src[lo] == ':')) lo += 1;
    while (hi > lo and (src[hi - 1] == '.' or src[hi - 1] == ':')) hi -= 1;
    return src[lo..hi];
}

/// Resolves the name under `offset`, preferring the registry: an engine
/// function's documentation is the more useful answer, and a file-level name
/// with the same spelling is rare exactly because the engine reserves it.
pub fn hover(src: []const u8, parsed: parser.Result, offset: u32) ?Topic {
    const path = nameAt(src, offset);
    if (path.len == 0) return null;

    if (api_meta.find(path)) |binding| {
        return Topic{
            .name = binding.name,
            .kind = .binding,
            .summary = binding.summary,
            .signature = binding.signature,
            .params = binding.params,
            .returns = binding.returns,
            .example = binding.example,
        };
    }

    // A local or a parameter: the declaration nearest the caret, because a
    // rebind shadows the previous one and the user is asking about the name as
    // it reads at the offset, not as it was once written.
    var best: ?parser.Symbol = null;
    for (parsed.symbols) |sym| {
        if (sym.name_start >= offset) continue;
        if (!std.mem.eql(u8, parser.Result.name(src, sym), path)) continue;
        if (best) |b| {
            if (sym.name_start < b.name_start) continue;
        }
        best = sym;
    }
    const sym = best orelse return null;
    return Topic{
        .name = parser.Result.name(src, sym),
        .kind = .symbol,
        .decl_start = sym.start,
        .decl_len = sym.len,
    };
}

fn isPathByte(ch: u8) bool {
    return std.ascii.isAlphanumeric(ch) or ch == '_' or ch == '.' or ch == ':';
}

// ─── Tests ───────────────────────────────────────────────────────────────────

const testing = std.testing;

fn hoverOf(src: []const u8, at: usize, allocator: std.mem.Allocator) ?Topic {
    var r = parser.parse(allocator, src) catch return null;
    defer r.deinit(allocator);
    return hover(src, r, @intCast(at));
}

test "a binding is documented from the registry" {
    const a = testing.allocator;
    const src = "actor.set_position(self, x, y)";
    // The caret is on `position`, which is in the middle of the path: the hover
    // has to resolve the whole thing.
    const at = std.mem.indexOf(u8, src, "position").? + 2;
    const t = hoverOf(src, at, a) orelse return error.NoTopic;
    try testing.expectEqual(Kind.binding, t.kind);
    try testing.expectEqualStrings("actor.set_position", t.name);
    try testing.expectEqualStrings("Sets the world-space position of this actor.", t.summary);
    try testing.expectEqualStrings("actor.set_position(self, x, y)", t.signature);
    try testing.expectEqual(@as(usize, 3), t.params.len);
    try testing.expectEqualStrings("x", t.params[1].name);
    // Every binding carries an example: the M3 criterion, visible here.
    try testing.expect(t.example.len > 0);
}

test "a name from the file gives its declaration" {
    const a = testing.allocator;
    const src =
        \\local function helper(a, b)
        \\    return a + b
        \\end
    ;
    const at = std.mem.indexOf(u8, src, "helper").? + 3;
    const t = hoverOf(src, at, a) orelse return error.NoTopic;
    try testing.expectEqual(Kind.symbol, t.kind);
    try testing.expectEqualStrings("helper", t.name);
    // The whole declaration, so Ctrl+Click selects something meaningful.
    try testing.expectEqual(@as(u32, 0), t.decl_start);
    try testing.expectEqual(@as(u32, src.len), t.decl_len);
}

test "a hover on a use jumps to the nearest earlier declaration" {
    const a = testing.allocator;
    const src =
        \\local x = 1
        \\local function f()
        \\    return x
        \\end
    ;
    const at = std.mem.indexOf(u8, src, "return x").? + "return ".len;
    const t = hoverOf(src, at, a) orelse return error.NoTopic;
    try testing.expectEqualStrings("local x = 1", src[t.decl_start .. t.decl_start + t.decl_len]);
}

test "the name under the caret is the whole path" {
    try testing.expectEqualStrings("actor.get_position", nameAt("actor.get_position(self)", 14));
    // A hover after a trailing dot is not a hover at all.
    try testing.expectEqualStrings("", nameAt("actor.", 6));
    // A caret at the edge of a path still resolves the whole path: a click
    // just after `world` is a click on `world.query`, not on `world`.
    try testing.expectEqualStrings("world.query", nameAt("world.query", 5));
    // A caret at the start of a name is on that name.
    try testing.expectEqualStrings("print", nameAt("print(1)", 0));
}

test "an unknown name has no answer" {
    const a = testing.allocator;
    try testing.expect(hoverOf("print(zzz_unknown)", 8, a) == null);
}
