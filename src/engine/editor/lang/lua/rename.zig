//! Rename: every place one variable is named, changed in one act.
//!
//! ## Why this is a whole module and not a find-and-replace
//!
//! Renaming `speed` must not touch the `speed` in an unrelated function, and it
//! must not touch the word `speed` inside a string or a comment. A find/replace
//! cannot tell those apart, because the difference is not textual — it is which
//! declaration each occurrence resolves to. That question is already answered by
//! `resolve.zig`, and the scope chain it walks is what makes a rename correct:
//! the same rule that decides go-to-definition decides what gets replaced, so
//! the two can never disagree about where a name lives.
//!
//! ## What it refuses to do
//!
//! Three refusals, and each one is worth more than the rename it prevents:
//!
//! 1. **A name that resolves to nothing local.** Renaming a global would edit
//!    every use site of an engine API in the file, which is not a rename of a
//!    variable — it is damage.
//! 2. **A name that is not an identifier.** `not a name` and `end` are not Lua
//!    names, and a dialog that accepts anything would produce a file that no
//!    longer parses.
//! 3. **A name already taken where the occurrences live.** The result would
//!    silently change what the code means — a nested `local` of that name would
//!    be captured, or a same-scope rebind would make the initializer read itself
//!    — and a rename that changes meaning is worse than one that fails.
//!
//! ## One act of undo
//!
//! The whole rename is applied as a single `Buffer.replace` over the whole
//! document, exactly as `find.replaceAll` does it: one undo entry, so pressing
//! undo after a rename undoes the rename and not a fifth of it.

const std = @import("std");
const parser = @import("parser.zig");
const resolve = @import("resolve.zig");
const buffer_mod = @import("../../doc/buffer.zig");

const Buffer = buffer_mod.Buffer;

/// One place the name is written.
pub const Occurrence = struct {
    start: u32,
    len: u32,

    pub fn end(o: Occurrence) u32 {
        return o.start + o.len;
    }
};

/// The rename target: the declaration, plus every use that resolves to it. Both
/// are byte ranges of the NAME, which is why the declaration entry describes the
/// name and not the whole declaration — a replace replaces a name.
pub const Target = struct {
    decl: Occurrence,
    /// Every use of the same variable, in source order. The declaration is not
    /// repeated here; `spans` is where the two are joined.
    uses: []Occurrence,
    /// The name as it is written today, for the dialog's initial value.
    old_name: []const u8,

    pub fn count(t: Target) usize {
        return t.uses.len + 1;
    }

    /// Every byte range to replace, declaration included, in source order.
    pub fn spans(t: Target, allocator: std.mem.Allocator) ![]Occurrence {
        const out = try allocator.alloc(Occurrence, t.uses.len + 1);
        out[0] = t.decl;
        @memcpy(out[1..], t.uses);
        std.mem.sort(Occurrence, out, {}, lessThan);
        return out;
    }
};

fn lessThan(_: void, a: Occurrence, b: Occurrence) bool {
    return a.start < b.start;
}

/// Resolves the name at `offset` into a rename target, or null when it resolves
/// to nothing local: a global, a keyword, or nothing at all.
///
/// The name read here is the identifier under the caret, NOT the dotted path the
/// hover rule uses. A local is a local; `actor.get_position` has no local to
/// rename, and asking the path question would find the wrong answer sooner.
pub fn target(
    allocator: std.mem.Allocator,
    src: []const u8,
    parsed: parser.Result,
    offset: u32,
) !?Target {
    const name = identifierAt(src, offset);
    if (name.len == 0) return null;

    const decls = try resolve.declarations(allocator, parsed);
    defer allocator.free(decls);

    // The declaration the caret is on: the nearest local of that name, at or
    // before the caret, inside a scope the caret is in. The same rule goto
    // uses, so the two agree by construction rather than by coincidence.
    const caret_scope = parsed.scopeAt(offset);
    var decl: ?usize = null;
    for (decls, 0..) |d, i| {
        if (d.start >= offset) continue;
        if (!std.mem.eql(u8, src[d.start .. d.start + d.len], name)) continue;
        if (!resolve.containsScope(parsed.scopes, caret_scope, d.scope)) continue;
        if (decl) |j| {
            if (decls[j].start > d.start) continue;
        }
        decl = i;
    }
    const at = decl orelse return null;

    var uses: std.ArrayListUnmanaged(Occurrence) = .empty;
    errdefer uses.deinit(allocator);
    for (parsed.uses) |use| {
        if (use.kind == .decl) continue;
        if (use.start < decls[at].start) continue;
        if (!std.mem.eql(u8, src[use.start .. use.start + use.len], name)) continue;
        // Resolving each candidate use is what keeps the second `x` in an
        // unrelated scope out of this rename, and a string that happens to spell
        // the same word out of it as well.
        const here = resolve.resolution(parsed.scopes, decls, use, src) orelse continue;
        if (here.start != decls[at].start) continue;
        try uses.append(allocator, .{ .start = use.start, .len = use.len });
    }
    return Target{
        .decl = .{ .start = decls[at].start, .len = decls[at].len },
        .uses = try uses.toOwnedSlice(allocator),
        .old_name = name,
    };
}

pub fn targetDeinit(t: Target, allocator: std.mem.Allocator) void {
    allocator.free(t.uses);
}

/// The identifier under the caret, or an empty slice when there is not one.
fn identifierAt(src: []const u8, offset: u32) []const u8 {
    const caret: usize = @min(offset, src.len);
    var lo = caret;
    while (lo > 0 and isNameByte(src[lo - 1])) lo -= 1;
    var hi = caret;
    while (hi < src.len and isNameByte(src[hi])) hi += 1;
    return src[lo..hi];
}

fn isNameByte(ch: u8) bool {
    return std.ascii.isAlphanumeric(ch) or ch == '_';
}

/// True when `name` is a name Lua would accept. A `ñ` inside a name is a name,
/// but a keyword is not, and a dialog that offers `end` would produce a file
/// that parses differently than it reads.
pub fn validName(name: []const u8) bool {
    if (name.len == 0) return false;
    const first = name[0];
    if (!(std.ascii.isAlphabetic(first) or first == '_' or first >= 0x80)) return false;
    for (name[1..]) |ch| {
        if (std.ascii.isAlphanumeric(ch) or ch == '_' or ch >= 0x80) continue;
        return false;
    }
    return !isKeyword(name);
}

fn isKeyword(name: []const u8) bool {
    const keywords = [_][]const u8{
        "and", "break",    "do",     "else", "elseif", "end",   "false",
        "for", "function", "if",     "in",   "local",  "nil",   "not",
        "or",  "repeat",   "return", "then", "true",   "until", "while",
    };
    for (keywords) |k| if (std.mem.eql(u8, k, name)) return true;
    return false;
}

/// Is the new name already taken somewhere the rename lands? Two cases, and both
/// change what the code means rather than what it is called:
///
/// - **The same scope.** A rebind makes the initializer read the very thing it
///   is declaring: `local y = 2; local x = y` becomes `local y = y`.
/// - **A scope inside the renamed one.** A nested binding of that name would be
///   shadowed by the renamed variable from the point where it is declared, so
///   uses that meant the nested one would mean this one.
fn collides(
    src: []const u8,
    parsed: parser.Result,
    decls: []const resolve.Decl,
    decl_index: usize,
    new_name: []const u8,
) bool {
    const mine = decls[decl_index];
    for (decls, 0..) |d, i| {
        if (i == decl_index) continue;
        if (d.len != new_name.len) continue;
        if (!std.mem.eql(u8, src[d.start .. d.start + d.len], new_name)) continue;
        if (d.scope == mine.scope) return true;
        if (resolve.containsScope(parsed.scopes, d.scope, mine.scope)) return true;
    }
    return false;
}

/// Renames the variable at `offset` and applies the result to `buffer` as ONE
/// act of undo. Returns how many names were replaced; zero means the name
/// resolved to nothing local and nothing was touched.
pub fn rename(
    buffer: *Buffer,
    allocator: std.mem.Allocator,
    offset: u32,
    new_name: []const u8,
) !usize {
    if (!validName(new_name)) return error.InvalidName;
    const src = buffer.textBytes();

    var parsed = try parser.parse(allocator, src);
    defer parsed.deinit(allocator);

    const t = (try target(allocator, src, parsed, offset)) orelse return 0;
    defer targetDeinit(t, allocator);

    // An undo entry that changed nothing is a history entry that lies.
    if (std.mem.eql(u8, t.old_name, new_name)) return 0;

    const spans = try t.spans(allocator);
    defer allocator.free(spans);

    const decls = try resolve.declarations(allocator, parsed);
    defer allocator.free(decls);
    if (collides(src, parsed, decls, declIndexOf(decls, t.decl), new_name)) {
        return error.NameInUse;
    }

    // One buffer, sized exactly, one replace: the whole rename is a single act
    // of undo, and undo after it puts the file back the way it was.
    var removed: usize = 0;
    for (spans) |s| removed += s.len;
    const size = src.len - removed + spans.len * new_name.len;
    const out = try allocator.alloc(u8, size);
    defer allocator.free(out);

    var w: usize = 0;
    var at: usize = 0;
    for (spans) |s| {
        const gap = s.start - at;
        @memcpy(out[w..][0..gap], src[at..s.start]);
        w += gap;
        @memcpy(out[w..][0..new_name.len], new_name);
        w += new_name.len;
        at = s.end();
    }
    @memcpy(out[w..][0 .. src.len - at], src[at..]);
    w += src.len - at;

    try buffer.replace(0, @intCast(src.len), out[0..w]);
    return spans.len;
}

fn declIndexOf(decls: []const resolve.Decl, decl: Occurrence) usize {
    for (decls, 0..) |d, i| {
        if (d.start == decl.start and d.len == decl.len) return i;
    }
    return 0;
}

// ─── Tests ───────────────────────────────────────────────────────────────────

const testing = std.testing;

fn renameIn(src: []const u8, at: usize, new_name: []const u8) ![]u8 {
    const a = testing.allocator;
    var b = Buffer.init(a);
    defer b.deinit();
    try b.insert(0, src);
    const n = try rename(&b, a, @intCast(at), new_name);
    try testing.expect(n > 0);
    return a.dupe(u8, b.textBytes());
}

test "a rename changes the declaration and every use of it" {
    const a = testing.allocator;
    const src =
        \\local count = 0
        \\local function bump()
        \\    count = count + 1
        \\    return count
        \\end
    ;
    const at = std.mem.indexOf(u8, src, "return count").? + "return ".len;
    const out = try renameIn(src, at, "tally");
    defer a.free(out);
    try testing.expectEqualStrings(
        \\local tally = 0
        \\local function bump()
        \\    tally = tally + 1
        \\    return tally
        \\end
    , out);
}

test "a shadowed name is renamed alone" {
    // The inner `x` is renamed and the outer one is not: two locals with the same
    // name are two variables, and a rename that touches both is a find-and-replace
    // wearing a rename's clothes.
    const a = testing.allocator;
    const src =
        \\local x = 1
        \\local function f()
        \\    local x = 2
        \\    return x
        \\end
    ;
    const at = std.mem.indexOf(u8, src, "return x").? + "return ".len;
    const out = try renameIn(src, at, "y");
    defer a.free(out);
    try testing.expectEqualStrings(
        \\local x = 1
        \\local function f()
        \\    local y = 2
        \\    return y
        \\end
    , out);
}

test "a parameter is renamed with its uses" {
    const a = testing.allocator;
    const src =
        \\function wrap(value)
        \\    return value * 2
        \\end
    ;
    const at = std.mem.indexOf(u8, src, "value *").?;
    const out = try renameIn(src, at, "amount");
    defer a.free(out);
    try testing.expectEqualStrings(
        \\function wrap(amount)
        \\    return amount * 2
        \\end
    , out);
}

test "a word in a string is not a use of the variable" {
    const a = testing.allocator;
    const src =
        \\local tag = "count"
        \\local function read()
        \\    return tag
        \\end
    ;
    const at = std.mem.indexOf(u8, src, "return tag").? + "return ".len;
    const out = try renameIn(src, at, "label");
    defer a.free(out);
    // The string keeps the old spelling: a rename that edits a string literal
    // would change what the file means rather than what it is called.
    try testing.expectEqualStrings(
        \\local label = "count"
        \\local function read()
        \\    return label
        \\end
    , out);
}

test "a name that resolves to nothing local is not touched" {
    const a = testing.allocator;
    var b = Buffer.init(a);
    defer b.deinit();
    const src = "actor.get_position(self)";
    try b.insert(0, src);
    try testing.expectEqual(@as(usize, 0), try rename(&b, a, @intCast("actor".len), "player"));
    try testing.expectEqualStrings(src, b.textBytes());
}

test "a same-scope collision is refused" {
    // Renaming `x` to `y` would leave `local y = 2; local y = y`: the
    // initializer would read the very thing it declares, which is not the rename
    // that was asked for.
    const src =
        \\local x = 1
        \\local y = 2
        \\return x + y
    ;
    const at = std.mem.indexOf(u8, src, "return x").? + "return ".len;
    try testing.expectError(error.NameInUse, renameIn(src, at, "y"));
}

test "a nested collision is refused" {
    const src =
        \\local x = 1
        \\do
        \\    local y = 2
        \\    return x + y
        \\end
    ;
    const at = std.mem.indexOf(u8, src, "return x").? + "return ".len;
    try testing.expectError(error.NameInUse, renameIn(src, at, "y"));
}

test "shadowing an outer binding is allowed" {
    // The reverse of the case above: a new name that already exists in an
    // ENCLOSING scope shadows it, which is a rename every Lua programmer has
    // written by hand, and refusing it would be refusing a rename that works.
    const a = testing.allocator;
    const src =
        \\local x = 1
        \\local function f()
        \\    local inner = 2
        \\    return inner
        \\end
    ;
    const at = std.mem.indexOf(u8, src, "return inner").? + "return ".len;
    const out = try renameIn(src, at, "x");
    defer a.free(out);
    try testing.expectEqualStrings(
        \\local x = 1
        \\local function f()
        \\    local x = 2
        \\    return x
        \\end
    , out);
}

test "a name that is not an identifier is refused" {
    try testing.expectError(error.InvalidName, renameIn("local x = 1\nreturn x", 16, "not a name"));
    try testing.expectError(error.InvalidName, renameIn("local x = 1\nreturn x", 16, "end"));
    try testing.expect(validName("_priv"));
    try testing.expect(validName("M2"));
    try testing.expect(!validName("2x"));
    try testing.expect(!validName(""));
    try testing.expect(!validName("and"));
}

test "renaming to the same name does nothing" {
    const a = testing.allocator;
    var b = Buffer.init(a);
    defer b.deinit();
    const src = "local x = 1\nreturn x";
    try b.insert(0, src);
    try testing.expectEqual(@as(usize, 0), try rename(&b, a, @intCast(std.mem.indexOf(u8, src, "return x").? + "return ".len), "x"));
    try testing.expectEqualStrings(src, b.textBytes());
}

test "the whole rename is one act of undo" {
    // The property that matters more than the count of names changed: one undo
    // after a rename puts the file back, not one place of it.
    const a = testing.allocator;
    var b = Buffer.init(a);
    defer b.deinit();
    const src =
        \\local count = 0
        \\local function bump()
        \\    count = count + 1
        \\    return count
        \\end
    ;
    try b.insert(0, src);
    const at: u32 = @intCast(std.mem.indexOf(u8, src, "return count").? + "return ".len);
    const n = try rename(&b, a, at, "tally");
    try testing.expectEqual(@as(usize, 4), n);
    try testing.expect(b.canUndo());
    // One undo, and the whole file is back: a rename is one act, not one act
    // per name. If it were, the second and third names would still be renamed
    // here and the file would no longer read like the one that was typed.
    _ = b.undo();
    try testing.expectEqualStrings(src, b.textBytes());
    // The only entry left is the one the test itself pushed to fill the buffer,
    // which is exactly what a UI would see: the file, and one rename under it.
    try testing.expect(b.canUndo());
    _ = b.undo();
    try testing.expectEqualStrings("", b.textBytes());
    try testing.expect(!b.canUndo());
}
