//! The outline: the file as a tree, for the panel on the left.
//!
//! ## What the tree is made of
//!
//! The parser already records every function, local and parameter as a `Symbol`
//! with the span of its whole declaration, which is exactly what an outline row
//! needs. Building the hierarchy from that list answers one question per row:
//! which symbol's span contains this one, innermost first. A parameter is a child
//! of its function, a local inside a loop is a child of the function holding the
//! loop, and a nested `function` is a child of the function it is nested in.
//!
//! ## Why a flat array and not pointers
//!
//! A tree of nodes with children slices needs one allocation per node and a free
//! walk, in a module the UI calls on every keystroke. A flat slice in source
//! order — where each row carries its depth, the index of its first child and
//! how many children it has — allocates once and renders with an indent and no
//! traversal at all. The rows are also stable: row `i` is row `i` whether the
//! panel is collapsed or not, so a click target never moves under the cursor.
//!
//! ## What is deliberately not a row
//!
//! Nothing. The parser says a name was declared, so it is in the outline, and the
//! panel decides what to show; `Options` exists so a UI can ask for "the
//! functions only" without this module knowing what a user wants.

const std = @import("std");
const parser = @import("parser.zig");

const no_parent: u32 = std.math.maxInt(u32);

/// One row. `name` is borrowed from the source.
pub const Row = struct {
    name: []const u8,
    kind: parser.SymbolKind,
    /// The whole declaration's byte range, for the click.
    start: u32,
    len: u32,
    /// Nesting depth: zero is a top-level declaration.
    depth: u16,
    /// Index of the first child row in the returned slice, and how many.
    first_child: u32,
    child_count: u16,
};

pub const Options = struct {
    include_params: bool = true,
    include_locals: bool = true,
};

/// The outline of `src`, in source order.
pub fn outline(allocator: std.mem.Allocator, src: []const u8, parsed: parser.Result, opts: Options) ![]Row {
    // Collect, then sort: the parser emits a function's parameters AFTER its
    // body, so source order is not the order the symbols arrive in.
    var syms: std.ArrayListUnmanaged(parser.Symbol) = .empty;
    defer syms.deinit(allocator);
    for (parsed.symbols) |sym| {
        if (!opts.include_params and sym.kind == .param) continue;
        if (!opts.include_locals and sym.kind == .local) continue;
        try syms.append(allocator, sym);
    }
    std.mem.sort(parser.Symbol, syms.items, {}, lessThan);
    if (syms.items.len == 0) return &.{};

    const n = syms.items.len;
    const parent = try allocator.alloc(u32, n);
    defer allocator.free(parent);
    for (syms.items, 0..) |sym, i| {
        var best: ?usize = null;
        for (syms.items, 0..) |maybe, j| {
            if (i == j) continue;
            if (maybe.start > sym.start) continue;
            if (maybe.start + maybe.len < sym.start + sym.len) continue;
            if (maybe.start == sym.start and maybe.len == sym.len) continue;
            // The SHORTEST containing row is the parent: a row three deep is a
            // child of the nearest one, not of the outermost.
            if (best) |b| {
                if (syms.items[b].len <= maybe.len) continue;
            }
            best = j;
        }
        parent[i] = if (best) |b| @intCast(b) else no_parent;
    }

    // Children are counted rather than linked, so the rows stay a flat slice.
    var firsts = try allocator.alloc(u32, n);
    defer allocator.free(firsts);
    var counts = try allocator.alloc(u16, n);
    defer allocator.free(counts);
    @memset(firsts, no_parent);
    @memset(counts, 0);
    for (0..n) |i| {
        const p = parent[i];
        if (p == no_parent) continue;
        if (firsts[p] == no_parent) firsts[p] = @intCast(i);
        counts[p] += 1;
    }

    var rows = try allocator.alloc(Row, n);
    for (syms.items, 0..) |sym, i| {
        rows[i] = .{
            .name = parser.Result.name(src, sym),
            .kind = sym.kind,
            .start = sym.start,
            .len = sym.len,
            // Depth is the number of ancestors, which is bounded by the row
            // count; walking parent links is the same answer as a stack would
            // give, without keeping one.
            .depth = @intCast(depthOf(parent, i)),
            .first_child = firsts[i],
            .child_count = counts[i],
        };
    }
    return rows;
}

fn depthOf(parent: []const u32, at: usize) usize {
    var depth: usize = 0;
    var i = parent[at];
    while (i != no_parent) : (depth += 1) {
        if (depth > parent.len) break; // a cycle cannot exist, but a walk that
        i = parent[i]; // could not terminate is worse than one that is wrong
    }
    return depth;
}

fn lessThan(_: void, a: parser.Symbol, b: parser.Symbol) bool {
    if (a.start != b.start) return a.start < b.start;
    // The wider declaration first, so a function's row comes before the local
    // declared inside it on the same offset (a `local function`'s name and the
    // function's own span both start at the `local`).
    return a.len > b.len;
}

// ─── Tests ───────────────────────────────────────────────────────────────────

const testing = std.testing;

fn outlineOf(src: []const u8, allocator: std.mem.Allocator, opts: Options) ![]Row {
    var r = try parser.parse(allocator, src);
    defer r.deinit(allocator);
    return outline(allocator, src, r, opts);
}

fn freeRows(rows: []Row, allocator: std.mem.Allocator) void {
    allocator.free(rows);
}

test "a nested function is a child of its parent" {
    const a = testing.allocator;
    const src =
        \\local function outer(a)
        \\    local function inner()
        \\        return a
        \\    end
        \\    return inner
        \\end
    ;
    const rows = try outlineOf(src, a, .{});
    defer freeRows(rows, a);
    // outer, its parameter a, inner: three rows, and both children of `outer`
    // sit at depth one under it.
    try testing.expectEqual(@as(usize, 3), rows.len);
    try testing.expectEqualStrings("outer", rows[0].name);
    try testing.expectEqual(@as(u16, 0), rows[0].depth);
    try testing.expectEqual(@as(u16, 2), rows[0].child_count);
    try testing.expectEqual(@as(u32, 1), rows[0].first_child);
    try testing.expectEqualStrings("a", rows[1].name);
    try testing.expectEqual(@as(u16, 1), rows[1].depth);
    const inner = rows[2];
    try testing.expectEqualStrings("inner", inner.name);
    try testing.expectEqual(@as(u16, 1), inner.depth);
    try testing.expectEqual(@as(u16, 0), inner.child_count);
}

test "the functions-only view drops parameters and locals" {
    const a = testing.allocator;
    const src =
        \\local tally = 0
        \\local function step(n)
        \\    return tally + n
        \\end
    ;
    const rows = try outlineOf(src, a, .{ .include_params = false, .include_locals = false });
    defer freeRows(rows, a);
    try testing.expectEqual(@as(usize, 1), rows.len);
    try testing.expectEqualStrings("step", rows[0].name);
    try testing.expectEqual(parser.SymbolKind.fun, rows[0].kind);
}

test "a function is ordered before its own parameter" {
    // `local function outer(a)` — the function's span and the parameter's both
    // begin at the `local`, so a row order that does not put the wider span
    // first lists the parameter above the function it belongs to. Nothing in the
    // file explains that, which is why it is a test.
    const a = testing.allocator;
    const src = "local function outer(a)\n    return a\nend";
    const rows = try outlineOf(src, a, .{});
    defer freeRows(rows, a);
    try testing.expectEqual(@as(usize, 2), rows.len);
    try testing.expectEqualStrings("outer", rows[0].name);
    try testing.expectEqualStrings("a", rows[1].name);
    try testing.expectEqual(@as(u16, 1), rows[1].depth);
}

test "an empty file has an empty outline" {
    const a = testing.allocator;
    const rows = try outlineOf("", a, .{});
    defer freeRows(rows, a);
    try testing.expectEqual(@as(usize, 0), rows.len);
}

test "a row is a child of the nearest containing row, not the outermost" {
    const a = testing.allocator;
    const src =
        \\local function a()
        \\    local function b()
        \\        local function c()
        \\        end
        \\    end
        \\end
    ;
    const rows = try outlineOf(src, a, .{});
    defer freeRows(rows, a);
    try testing.expectEqual(@as(usize, 3), rows.len);
    try testing.expectEqual(@as(u16, 0), rows[0].depth);
    try testing.expectEqual(@as(u16, 1), rows[1].depth);
    try testing.expectEqual(@as(u16, 2), rows[2].depth);
}
