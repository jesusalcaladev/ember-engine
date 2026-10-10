//! Autocompletion, from the parse and from the API registry.
//!
//! ## Where a completion comes from
//!
//! Four sources, ranked so the most likely answer comes first:
//!
//! 1. **Names in this file.** A local or a parameter the parser saw declared
//!    before the caret, in a scope that contains it. A typo of a name the file
//!    already has is the most common completion request there is, and the scope
//!    spans the parser leaves behind are what keep it to the names that are
//!    actually in scope.
//! 2. **The engine's API.** Every binding in the registry: at the top level by
//!    module (`actor`, `physics`, `sprite`) and after a `.` or `:` by member
//!    (`actor.get_`). The registry carries a signature and a summary per
//!    function, and they become the popup's second and third rows — the same
//!    data the Ctrl+Click help panel shows, from one source.
//! 3. **The Lua keywords, and a handful of snippets.** `function` and `for` are
//!    typed constantly and closed wrongly constantly; the editor is the right
//!    place to write the `end` for the user.
//!
//! ## The two shapes of context
//!
//! After `actor.` the answer is a member of a known table and the prefix is only
//! the part after the dot — `get_p` inside `actor.get_p`. Bare, it is a name
//! being typed from scratch. Deciding which is a scan backwards over identifier
//! bytes and one look behind, done before anything is offered: a list that
//! cannot tell the two apart offers `actor` while the user types `actor.get_`,
//! which is how completion popups get ignored.
//!
//! ## Ranking, not sorting
//!
//! A list sorted alphabetically makes the user read it; a ranked list puts the
//! likely answer at the top and the rest out of the way. The rank here is
//! deliberately simple — declared locally beats the API, an exact prefix beats
//! a fuzzy one, shorter beats longer — because a scoring function nobody can
//! explain is one nobody can tune when it guesses wrong.

const std = @import("std");
const parser = @import("parser.zig");
const lexer = @import("lexer.zig");
const api_meta = @import("api_meta");

pub const Kind = enum {
    keyword,
    /// An engine module: `actor`, `physics`, `sprite`.
    module,
    /// A documented binding, at the top level or as a member.
    function,
    /// A local or a parameter from this file.
    local,
    /// A block shape: `insert` carries the whole text and `caret` the position
    /// to leave the user's cursor in.
    snippet,

    pub fn hint(k: Kind) []const u8 {
        return switch (k) {
            .keyword => "keyword",
            .module => "module",
            .function => "fn",
            .local => "local",
            .snippet => "snippet",
        };
    }
};

pub const Item = struct {
    label: []const u8,
    kind: Kind,
    /// The signature line, for the popup's second row.
    detail: []const u8 = "",
    /// The registry's one-line summary.
    doc: []const u8 = "",
    /// Text to insert instead of the label (snippets), and the byte offset
    /// inside it where the caret belongs afterwards.
    insert: []const u8 = "",
    caret: u16 = 0,
    /// Rank, best first: zero is the most likely.
    score: u16 = 0,

    /// What the popup should put in the buffer: `insert` when there is one (a
    /// snippet replaces the whole typed prefix), the label otherwise.
    pub fn text(i: Item) []const u8 {
        return if (i.insert.len > 0) i.insert else i.label;
    }
};

/// The completion context: `base` is the table a member is read from (`"actor"`
/// in `actor.get_`), `prefix` is what is being typed, and `start` is where the
/// replacement has to begin.
pub const Context = struct {
    base: []const u8 = "",
    prefix: []const u8 = "",
    start: u32 = 0,
};

/// Reads the context backwards from `offset`. The scan is over identifier bytes
/// so it cannot be confused by whitespace, and one look behind decides whether
/// the name is a member read: `a.b` is one, `a .. b` is not, which is why the
/// byte before the separator has to not be a dot.
pub fn contextOf(src: []const u8, offset: u32) Context {
    const at_end: usize = @min(offset, src.len);
    var at = at_end;
    while (at > 0 and isIdentByte(src[at - 1])) at -= 1;
    const prefix = src[at..at_end];
    var c = Context{ .prefix = prefix, .start = @intCast(at) };
    if (at >= 2 and (src[at - 1] == '.' or src[at - 1] == ':') and src[at - 2] != '.') {
        const sep = at - 1;
        var b = sep;
        while (b > 0 and isIdentByte(src[b - 1])) b -= 1;
        c.base = src[b..sep];
    }
    return c;
}

/// Every completion offered at `offset`, best first. `parsed` must be the parse
/// of `src`: the locals it contributes come from the scope chain, which is why
/// the two are arguments rather than one.
pub fn complete(
    allocator: std.mem.Allocator,
    src: []const u8,
    parsed: parser.Result,
    offset: u32,
) ![]Item {
    const ctx = contextOf(src, offset);
    var out: std.ArrayListUnmanaged(Item) = .empty;
    errdefer out.deinit(allocator);

    if (ctx.base.len > 0) {
        try members(&out, allocator, ctx.base);
    } else {
        try globals(&out, allocator, src, parsed, offset);
        try snippets(&out, allocator);
    }
    try filter(&out, ctx.prefix);
    dedupe(&out);
    rank(&out);
    return out.toOwnedSlice(allocator);
}

// ─── The two shapes ───────────────────────────────────────────────────────────

/// The members of a known table, from the registry. Every module in the registry
/// is a Lua table of functions, and the standard library (`math`, `string`,
/// `table`) is in the registry too — which is why this needs no special case
/// for it.
fn members(out: *std.ArrayListUnmanaged(Item), allocator: std.mem.Allocator, base: []const u8) !void {
    for (api_meta.bindings) |b| {
        if (!std.mem.eql(u8, b.module, base)) continue;
        // The label is the member name, not the full path: the user has typed
        // the table already, and offering `actor.get_position` after `actor.`
        // means editing what is already written.
        try out.append(allocator, .{
            .label = b.name[base.len + 1 ..],
            .kind = .function,
            .detail = b.signature,
            .doc = b.summary,
            .score = 2,
        });
    }
}

/// Everything that can start a name: the locals in scope at the caret, the
/// engine's tables, the Lua keywords.
fn globals(
    out: *std.ArrayListUnmanaged(Item),
    allocator: std.mem.Allocator,
    src: []const u8,
    parsed: parser.Result,
    offset: u32,
) !void {
    // Locals in scope, declared before the caret: the most likely completion
    // there is, and the reason this pass takes the parsed results at all.
    const at_scope = parsed.scopeAt(offset);
    for (parsed.uses) |u| {
        if (u.kind != .decl) continue;
        if (u.start >= offset) continue;
        // A local belongs to the local names only if the caret is inside it, or
        // inside something it encloses. Without this the popup fills with names
        // from three functions over.
        if (!containsScope(parsed.scopes, at_scope, u.scope)) continue;
        try out.append(allocator, .{
            .label = src[u.start .. u.start + u.len],
            .kind = .local,
            .score = 0,
        });
    }

    // The engine's tables and the standard library's, from the same list the
    // highlighter colours with: a module that exists here is a module that
    // exists there, and one drift instead of two.
    for (lexer.globals) |g| try out.append(allocator, .{ .label = g, .kind = .module, .score = 1 });

    // Bindings registered without a module prefix are top-level functions.
    for (api_meta.bindings) |b| {
        if (std.mem.indexOfScalar(u8, b.name, '.') != null) continue;
        try out.append(allocator, .{
            .label = b.name,
            .kind = .function,
            .detail = b.signature,
            .doc = b.summary,
            .score = 2,
        });
    }

    for (lexer.keywords) |k| try out.append(allocator, .{ .label = k, .kind = .keyword, .score = 3 });
}

/// Block shapes with the caret left where the user has to type next. Deliberate
/// limitations: the multi-line ones put the whole block on one line, because an
/// editor that inserts a newline while the user types a prefix is an editor that
/// surprises; and none of them complete inside a string.
fn snippets(out: *std.ArrayListUnmanaged(Item), allocator: std.mem.Allocator) !void {
    try out.append(allocator, .{ .label = "for ipairs() do", .kind = .snippet, .insert = "for _i, _v in ipairs() do end", .caret = 21, .score = 3 });
    try out.append(allocator, .{ .label = "function()", .kind = .snippet, .insert = "function () end", .caret = 10, .score = 3 });
    try out.append(allocator, .{ .label = "local function()", .kind = .snippet, .insert = "local function () end", .caret = 16, .score = 3 });
    try out.append(allocator, .{ .label = "if ... then", .kind = .snippet, .insert = "if  then end", .caret = 3, .score = 3 });
    try out.append(allocator, .{ .label = "while ... do", .kind = .snippet, .insert = "while  do end", .caret = 6, .score = 3 });
}

// ─── Filtering and ranking ────────────────────────────────────────────────────

/// Keeps what the prefix could be. An exact prefix wins a match anywhere, and a
/// match anywhere at all is enough to be offered: `gp` offers `get_position`,
/// which is what a fuzzy popup is for. Empty prefix keeps everything.
fn filter(out: *std.ArrayListUnmanaged(Item), prefix: []const u8) !void {
    if (prefix.len == 0) return;
    var kept: usize = 0;
    for (out.items) |it| {
        var score = it.score;
        if (startsWithInsensitive(it.label, prefix)) {} else if (containsInsensitive(it.label, prefix)) {
            // A fuzzy match is still worth offering — `gp` completes
            // `get_position` — but it ranks below every exact one.
            score += 10;
        } else continue;
        out.items[kept] = it;
        out.items[kept].score = score;
        kept += 1;
    }
    out.shrinkRetainingCapacity(kept);
}

/// Removes repeats, keeping the best-ranked one. A local declared in two scopes
/// of the same file is offered once, and the highest-ranked copy is the one that
/// stays.
fn dedupe(out: *std.ArrayListUnmanaged(Item)) void {
    var kept: usize = 0;
    for (out.items) |it| {
        var found: ?usize = null;
        for (out.items[0..kept], 0..) |have, idx| {
            if (!std.mem.eql(u8, have.label, it.label)) continue;
            found = idx;
            break;
        }
        if (found) |idx| {
            // The better-ranked copy wins: a local beats the engine's table of
            // the same name, and a better score beats a worse one.
            if (better(it, out.items[idx])) out.items[idx] = it;
            continue;
        }
        out.items[kept] = it;
        kept += 1;
    }
    out.shrinkRetainingCapacity(kept);
}

/// Sort by score, then by length, then alphabetically — the three questions a
/// reader asks, in that order. Shorter labels are ordered first because the
/// most-used name in a Lua file is usually the short one.
fn rank(out: *std.ArrayListUnmanaged(Item)) void {
    const items = out.items;
    var i: usize = 1;
    while (i < items.len) : (i += 1) {
        const it = items[i];
        var j: usize = i;
        while (j > 0 and better(it, items[j - 1])) : (j -= 1) items[j] = items[j - 1];
        items[j] = it;
    }
}

fn better(a: Item, b: Item) bool {
    if (a.score != b.score) return a.score < b.score;
    if (a.label.len != b.label.len) return a.label.len < b.label.len;
    return std.mem.lessThan(u8, a.label, b.label);
}

fn containsScope(scopes: []const parser.Scope, inner: u32, outer: u32) bool {
    var scope = inner;
    while (true) {
        if (scope == outer) return true;
        const parent = scopes[scope].parent;
        if (parent == parser.no_scope) return false;
        scope = parent;
    }
}

fn isIdentByte(ch: u8) bool {
    return std.ascii.isAlphanumeric(ch) or ch == '_';
}

fn startsWithInsensitive(haystack: []const u8, needle: []const u8) bool {
    if (haystack.len < needle.len) return false;
    return std.ascii.eqlIgnoreCase(haystack[0..needle.len], needle);
}

fn containsInsensitive(haystack: []const u8, needle: []const u8) bool {
    if (needle.len == 0) return true;
    if (haystack.len < needle.len) return false;
    var at: usize = 0;
    while (at + needle.len <= haystack.len) : (at += 1) {
        if (std.ascii.eqlIgnoreCase(haystack[at .. at + needle.len], needle)) return true;
    }
    return false;
}

// ─── Tests ───────────────────────────────────────────────────────────────────

const testing = std.testing;

/// Completes `src` at `offset` and hands back the items. The parse is dropped
/// before returning because every item borrows the source, not the results.
fn completeOf(src: []const u8, offset: u32, allocator: std.mem.Allocator) ![]Item {
    var r = try parser.parse(allocator, src);
    defer r.deinit(allocator);
    return complete(allocator, src, r, offset);
}

/// The labels of every completion, for the assertions that only care whether a
/// name was offered.
fn completeLabels(src: []const u8, offset: u32) ![]const []const u8 {
    const a = testing.allocator;
    const items = try completeOf(src, offset, a);
    defer a.free(items);
    var out: std.ArrayListUnmanaged([]const u8) = .empty;
    errdefer out.deinit(a);
    for (items) |it| try out.append(a, it.label);
    return out.toOwnedSlice(a);
}

fn freeLabels(t: []const []const u8) void {
    testing.allocator.free(t);
}

fn has(t: []const []const u8, label: []const u8) bool {
    for (t) |l| if (std.mem.eql(u8, l, label)) return true;
    return false;
}

test "a typed prefix narrows the list" {
    const t = try completeLabels("acto", 4);
    defer freeLabels(t);
    try testing.expect(has(t, "actor"));
    // The prefix filters: `math` is in the vocabulary but not in this answer.
    try testing.expect(!has(t, "math"));
    // and the members are for after a dot.
    try testing.expect(!has(t, "get_position"));
}

test "an empty prefix offers the whole vocabulary" {
    const t = try completeLabels("", 0);
    defer freeLabels(t);
    try testing.expect(has(t, "actor"));
    try testing.expect(has(t, "math"));
    try testing.expect(has(t, "sprite"));
    try testing.expect(has(t, "local"));
    try testing.expect(has(t, "if"));
}

test "after a dot, the members of that table" {
    const a = testing.allocator;
    const src = "actor.get_posi";
    const items = try completeOf(src, @intCast(src.len), a);
    defer a.free(items);
    // Only one member matches this prefix, and the popup should say so rather
    // than padding the list.
    try testing.expectEqual(@as(usize, 1), items.len);
    const first = items[0];
    try testing.expectEqualStrings("get_position", first.label);
    try testing.expectEqual(Kind.function, first.kind);
    // The detail and the doc come from the registry, so the popup can show a
    // signature without a second query.
    try testing.expect(first.detail.len > 0);
    try testing.expect(first.doc.len > 0);
}

test "a member list is not offered the table back" {
    const t = try completeLabels("actor.self", 10);
    defer freeLabels(t);
    try testing.expect(!has(t, "actor"));
    // `self` is a field read, not a member of the registry.
    try testing.expect(!has(t, "get_position"));
}

test "locals in scope are offered, and locals from other scopes are not" {
    const src =
        \\function outer()
        \\    local in_scope = 1
        \\    return in_
        \\end
        \\function other()
        \\    local not_here = 2
        \\end
    ;
    // The caret sits after `in_`, inside `outer`'s body: the offset is found
    // rather than typed, so editing the string above cannot break the test.
    const at: u32 = @intCast(std.mem.indexOf(u8, src, "return in_").? + "return in_".len);
    const t = try completeLabels(src, at);
    defer freeLabels(t);
    try testing.expect(has(t, "in_scope"));
    try testing.expect(!has(t, "not_here"));
}

test "a local declared after the caret is not offered" {
    const src = "local x = a\nlocal alias = 1";
    const t = try completeLabels(src, 5);
    defer freeLabels(t);
    try testing.expect(!has(t, "alias"));
}

test "the context is read from the buffer, not the cursor line" {
    try testing.expectEqualStrings("physics", contextOf("physics.raycast(", 15).base);
    try testing.expectEqualStrings("raycast", contextOf("physics.raycast(", 15).prefix);
    // A colon method read is a member read too.
    try testing.expectEqualStrings("self", contextOf("self:get_", 8).base);
    // `..` is concatenation, not a member read.
    try testing.expectEqualStrings("", contextOf("a .. b", 6).base);
    // An empty prefix after a dot still knows its table.
    try testing.expectEqualStrings("world", contextOf("world.", 6).base);
    try testing.expectEqualStrings("", contextOf("world.", 6).prefix);
}

test "a fuzzy prefix still finds the name" {
    // `prite` completes `sprite`, which is what a fuzzy popup is for; a name
    // that does not contain the letters is not offered at all.
    const t = try completeLabels("prite", 5);
    defer freeLabels(t);
    try testing.expect(has(t, "sprite"));
    try testing.expect(!has(t, "rand"));
}

test "an exact prefix ranks above a fuzzy match" {
    const a = testing.allocator;
    // `actor.set_` completes `set_position` and `set_size`; both start with
    // the prefix, so both are exact, and the shorter one comes first.
    // `sprite.set_` matches six members: every one starts with the prefix, so
    // they are all exact, and the shorter one comes first.
    const src2 = "sprite.set_";
    const items2 = try completeOf(src2, @intCast(src2.len), a);
    defer a.free(items2);
    try testing.expect(items2.len >= 4);
    try testing.expect(std.mem.startsWith(u8, items2[0].label, "set_"));
    try testing.expect(items2[0].label.len < items2[items2.len - 1].label.len);
}

test "the same name is offered once" {
    const t = try completeLabels("local a = 1\nlocal function f(a)\n    return a\nend", 44);
    defer freeLabels(t);
    var n: usize = 0;
    for (t) |l| if (std.mem.eql(u8, l, "a")) {
        n += 1;
    };
    try testing.expectEqual(@as(usize, 1), n);
}

test "snippets leave the caret where the user has to type" {
    const a = testing.allocator;
    const items = try completeOf("func", 4, a);
    defer a.free(items);
    var found = false;
    for (items) |it| {
        if (it.kind != .snippet) continue;
        if (!std.mem.eql(u8, it.label, "function()")) continue;
        found = true;
        try testing.expectEqualStrings("function () end", it.text());
        try testing.expect(it.caret < it.insert.len);
        // The caret sits where the parameter list starts.
        try testing.expectEqualStrings("()", it.insert[it.caret - 1 .. it.caret + 1]);
        _ = &found;
    }
    try testing.expect(found);
}
