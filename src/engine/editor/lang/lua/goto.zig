//! Goto-definition and find-all-references, over the resolvedor.
//!
//! ## The part that is hard, and where it lives
//!
//! "Where is this defined" is a name-resolution question, and the rules that
//! answer it — innermost scope first, declared before the use — already exist in
//! `resolve.zig` for the diagnostics and the reference list. This module adds
//! the two questions that are actually *navigation*: pick one answer, and list
//! every use of the same variable.
//!
//! ## Goto-definition, in one line
//!
//! The declaration the name under the caret resolves to, as a byte range. The
//! subtlety is that the caret is rarely on the declaration itself: it is on a
//! use, and `help.nameAt` already knows how to read the whole path out of the
//! buffer, so a click on `position` inside `actor.get_position` resolves the
//! whole path — which is what the registry has an entry for.
//!
//! ## References, and what counts as one
//!
//! The declaration, then every read and every write of the same variable — in
//! source order, with offsets, because a list of positions is what an editor
//! highlights. "The same variable" means resolving each candidate use through
//! the scope chain and keeping the ones that resolve to THIS declaration, which
//! is the difference between "the places this name is spelled" and "the places
//! this name means the thing it means here". A file with two locals called `x`
//! in unrelated scopes gets two lists, not one wrong one.

const std = @import("std");
const parser = @import("parser.zig");
const resolve = @import("resolve.zig");
const help = @import("help.zig");

/// A byte range in the source. The UI invites a jump or paints a highlight.
pub const Span = struct {
    start: u32,
    len: u32,
};

/// The declaration of the name under `offset`, if the parse found one. Null
/// means the name resolves to nothing local — a global, a keyword, or a
/// misspelling — and "nowhere to go" is the correct answer, not an error.
///
/// It allocates nothing: the declarations are read straight out of the parse
/// results, because a jump is bound to a keystroke and a keystroke must not be
/// able to fail.
pub fn definition(src: []const u8, parsed: parser.Result, offset: u32) ?Span {
    const path = help.nameAt(src, offset);
    if (path.len == 0) return null;

    const d = declFor(src, parsed, offset, path) orelse return null;
    // The row is the whole declaration, so the jump lands on something
    // selectable rather than on the name alone.
    for (parsed.symbols) |sym| {
        if (sym.name_start == d.start and sym.name_len == d.len) {
            return .{ .start = sym.start, .len = sym.len };
        }
    }
    return .{ .start = d.start, .len = d.len };
}

/// The declaration the caret is on: nearest local of that name, at or before
/// the caret, in a scope the caret is inside. Shared with `references` so the
/// two can never disagree about which variable was clicked on.
fn declFor(src: []const u8, parsed: parser.Result, offset: u32, path: []const u8) ?resolve.Decl {
    var best: ?resolve.Decl = null;
    const caret_scope = parsed.scopeAt(offset);
    for (parsed.uses) |use| {
        if (use.kind != .decl) continue;
        if (use.start >= offset) continue;
        if (!std.mem.eql(u8, src[use.start .. use.start + use.len], path)) continue;
        // Only the caret's own scope chain: a declaration of the same name in
        // an unrelated function is a different variable.
        if (!resolve.containsScope(parsed.scopes, caret_scope, use.scope)) continue;
        if (best) |b| {
            if (b.start > use.start) continue;
        }
        best = .{ .start = use.start, .len = use.len, .scope = use.scope };
    }
    return best;
}

/// Every place this variable is read or written, in source order, plus the
/// declaration itself. Empty is a legitimate answer for a name that resolves to
/// nothing local, and the UI says "no references" rather than jumping anywhere.
pub fn references(
    allocator: std.mem.Allocator,
    src: []const u8,
    parsed: parser.Result,
    offset: u32,
) ![]Span {
    const path = help.nameAt(src, offset);
    if (path.len == 0) return &.{};

    const decls = try resolve.declarations(allocator, parsed);
    defer allocator.free(decls);

    // The declaration the caret is on, found the same way `definition` finds it:
    // one rule for "which variable is this", two consumers of the answer.
    const target: ?resolve.Decl = blk: {
        const caret_scope = parsed.scopeAt(offset);
        var best: ?resolve.Decl = null;
        for (decls) |d| {
            if (d.start >= offset) continue;
            if (!std.mem.eql(u8, src[d.start .. d.start + d.len], path)) continue;
            if (!resolve.containsScope(parsed.scopes, caret_scope, d.scope)) continue;
            if (best) |b| {
                if (b.start > d.start) continue;
            }
            best = d;
        }
        break :blk best;
    };

    var out: std.ArrayListUnmanaged(Span) = .empty;
    errdefer out.deinit(allocator);
    if (target) |t| {
        // The declaration first, then every use that resolves to it. The row is
        // the whole declaration, so the list starts where the eye should go.
        var decl_row = Span{ .start = t.start, .len = t.len };
        for (parsed.symbols) |sym| {
            if (sym.name_start == t.start and sym.name_len == t.len) {
                decl_row = .{ .start = sym.start, .len = sym.len };
            }
        }
        try out.append(allocator, decl_row);

        for (parsed.uses) |use| {
            if (use.kind == .decl) continue;
            if (use.start < t.start) continue;
            if (!std.mem.eql(u8, src[use.start .. use.start + use.len], src[t.start .. t.start + t.len])) continue;
            // Resolving each candidate is what makes the list "every place this
            // variable is used" rather than "every place this name is spelled":
            // a second `x` in an unrelated scope does not appear in the first
            // one's list.
            const resolves_here = resolve.resolution(parsed.scopes, decls, use, src) orelse continue;
            if (resolves_here.start != t.start or resolves_here.len != t.len) continue;
            try out.append(allocator, .{ .start = use.start, .len = use.len });
        }
    }
    return out.toOwnedSlice(allocator);
}

// ─── Tests ───────────────────────────────────────────────────────────────────

const testing = std.testing;

fn defSpan(src: []const u8, at: usize, allocator: std.mem.Allocator) ?Span {
    var r = parser.parse(allocator, src) catch return null;
    defer r.deinit(allocator);
    return definition(src, r, @intCast(at));
}

fn refsOf(src: []const u8, at: usize, allocator: std.mem.Allocator) ![]Span {
    var r = try parser.parse(allocator, src);
    defer r.deinit(allocator);
    return references(allocator, src, r, @intCast(at));
}

test "a jump lands on the declaration, not on the name" {
    const a = testing.allocator;
    const src = "local total = 0\nreturn total";
    const at = std.mem.indexOf(u8, src, "return total").? + "return ".len;
    const s = defSpan(src, at, a) orelse return error.NoDefinition;
    try testing.expectEqualStrings("local total = 0", src[s.start .. s.start + s.len]);
}

test "a jump from inside a function finds the outer local" {
    const a = testing.allocator;
    const src =
        \\local speed = 4
        \\local function step(dt)
        \\    return speed * dt
        \\end
    ;
    const at = std.mem.indexOf(u8, src, "return speed").? + "return ".len;
    const s = defSpan(src, at, a) orelse return error.NoDefinition;
    try testing.expectEqualStrings("local speed = 4", src[s.start .. s.start + s.len]);
}

test "a click on the declaration itself keeps the same target" {
    // The caret is on the name in `local total = 0`: the jump has to resolve to
    // the same declaration a click on the use resolves to, or the two disagree
    // about where a name lives.
    const a = testing.allocator;
    const src = "local total = 0\nreturn total";
    const on_decl = std.mem.indexOf(u8, src, "total").? + "total".len;
    const s = defSpan(src, on_decl, a) orelse return error.NoDefinition;
    try testing.expectEqualStrings("local total = 0", src[s.start .. s.start + s.len]);
}

test "references include the declaration when the caret is on it" {
    const a = testing.allocator;
    const src =
        \\local count = 0
        \\local function bump()
        \\    count = count + 1
        \\    return count
        \\end
    ;
    const on_decl = std.mem.indexOf(u8, src, "count").? + "count".len;
    const spans = try refsOf(src, on_decl, a);
    defer a.free(spans);
    try testing.expectEqual(@as(usize, 4), spans.len);
}

test "a global has nowhere to go" {
    const a = testing.allocator;
    // `actor` is a real name but not a local, so it has no declaration here:
    // "nowhere" is the answer, and an editor that invents a target is worse.
    try testing.expect(defSpan("actor.get_position(self)", 3, a) == null);
    try testing.expect(defSpan("print(1)", 1, a) == null);
}

test "references list the declaration and the uses, in order" {
    const a = testing.allocator;
    const src =
        \\local count = 0
        \\local function bump()
        \\    count = count + 1
        \\    return count
        \\end
    ;
    const at = std.mem.indexOf(u8, src, "return count").? + "return ".len;
    const spans = try refsOf(src, at, a);
    defer a.free(spans);
    try testing.expectEqual(@as(usize, 4), spans.len);
    // First the declaration, as the whole line: a highlight that starts at the
    // declaration should be where the eye has to go, not on the name alone.
    try testing.expectEqualStrings("local count = 0", src[spans[0].start .. spans[0].start + spans[0].len]);
    // Then the three uses, in source order, each the name and nothing else.
    var last: u32 = 0;
    for (spans[1..]) |s| {
        try testing.expectEqualStrings("count", src[s.start .. s.start + s.len]);
        try testing.expect(s.start >= last);
        last = s.start;
    }
}

test "a shadowed name gets its own reference list" {
    const a = testing.allocator;
    const src =
        \\local x = 1
        \\local function f()
        \\    local x = 2
        \\    return x
        \\end
        \\return x
    ;
    // The read inside `f` belongs to the inner `x`: two entries — the
    // declaration and the read — and NOT the outer one's.
    const inner_at = std.mem.indexOf(u8, src, "return x").? + "return ".len;
    const inner = try refsOf(src, inner_at, a);
    defer a.free(inner);
    try testing.expectEqual(@as(usize, 2), inner.len);
    try testing.expect(inner[0].start > 20);

    // The read outside belongs to the outer one, whose declaration is the first
    // one in the file.
    const outer_at = std.mem.lastIndexOf(u8, src, "return x").? + "return ".len;
    const outer = try refsOf(src, outer_at, a);
    defer a.free(outer);
    try testing.expectEqual(@as(usize, 2), outer.len);
    try testing.expectEqual(@as(u32, 0), outer[0].start);
}

test "a name with no references resolves to nothing, not to everything" {
    const a = testing.allocator;
    const spans = try refsOf("print(x)", 6, a);
    defer a.free(spans);
    try testing.expectEqual(@as(usize, 0), spans.len);
}
