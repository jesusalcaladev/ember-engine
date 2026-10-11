//! The help panel: what Ctrl+Click opens, and what the panel browses.
//!
//! ROADMAP M5.5 wants the whole API one Ctrl+Click away, "like Godot's
//! documentation", and it asks for two things this module provides the data for:
//!
//! 1. **Ctrl+Click** on a name. Three outcomes, and the order between them is
//!    the decision that matters: a name declared in the file jumps to its
//!    declaration, because the file is what the user is editing and its own
//!    names are the ones they just wrote; a documented binding opens the panel;
//!    and anything else does nothing. Getting that order wrong would open the
//!    engine's documentation for a local called `actor`, which is a real name in
//!    every script.
//! 2. **The browsable index.** Every module with the functions it owns, in the
//!    registry's own order, plus a search that ranks the way a person reads: the
//!    name they are typing beats a name that contains it, and both beat a
//!    summary that happens to mention it.
//!
//! ## Why the panel's data is headless
//!
//! The panel paints a table, and a table is easy. The hard part is knowing what
//! goes in it — which is resolution, and the same resolution goto uses — and
//! that is testable with no window. The UI is a projection of this, exactly as
//! the renderer is a projection of a batcher.
//!
//! ## One source, four surfaces
//!
//! The same registry row feeds the completion popup's signature and summary, the
//! hover tooltip, the stub generator for external editors, and this panel. That
//! is the M3 rule ("no metadata, no merge") paying off: a binding cannot gain a
//! tooltip without gaining every other surface, and none of them can drift from
//! another because they are all the same bytes.

const std = @import("std");
const parser = @import("parser.zig");
const resolve = @import("resolve.zig");
const goto = @import("goto.zig");
const api_meta = @import("api_meta");

/// What a Ctrl+Click resolved to. An explicit `nothing` rather than an
/// optional, because the caller has to handle the case and a silent null is how
/// a click becomes a jump to nowhere.
pub const Action = union(enum) {
    /// Open the panel on this binding.
    help: api_meta.Binding,
    /// Jump to a declaration in the file.
    jump: goto.Span,
    nothing,
};

/// Resolves a Ctrl+Click. The precedence is the file's own names first: a local
/// declared in this file is what the user just wrote, and sending them to the
/// engine's documentation instead of their own line would be the wrong answer,
/// however good the documentation.
pub fn activate(src: []const u8, parsed: parser.Result, offset: u32) Action {
    // 1. The file's own names: a declaration to jump to.
    if (goto.definition(src, parsed, offset)) |span| return .{ .jump = span };

    // 2. The engine's registry: the documentation to open.
    const path = @import("help.zig").nameAt(src, offset);
    if (path.len == 0) return .nothing;
    if (api_meta.find(path)) |binding| return .{ .help = binding };

    return .nothing;
}

// ─── The index ─────────────────────────────────────────────────────────────

/// One browsable entry: the binding itself. The panel reads `signature`,
/// `summary`, `params`, `returns` and `example` out of it, which is the whole
/// point of one registry.
pub const Entry = struct {
    binding: api_meta.Binding,
};

/// A module in the index: `physics`, `sprite`, `vec2`.
pub const Module = struct {
    name: []const u8,
    entries: []Entry,
};

/// Every module in the registry, in registry order, with its functions. An
/// empty result is impossible — the registry has entries, and a binding without
/// one would not have merged — but an empty slice is the honest shape for a
/// system that can gain modules at compile time.
pub fn index(allocator: std.mem.Allocator) ![]Module {
    var mods: std.ArrayListUnmanaged(Module) = .empty;
    errdefer {
        for (mods.items) |m| allocator.free(m.entries);
        mods.deinit(allocator);
    }

    // Comptime-deduplicated module names, in registry order.
    const names = moduleNames();
    for (names) |name| {
        var entries: std.ArrayListUnmanaged(Entry) = .empty;
        errdefer entries.deinit(allocator);
        for (api_meta.bindings) |b| {
            if (!std.mem.eql(u8, b.module, name)) continue;
            try entries.append(allocator, .{ .binding = b });
        }
        try mods.append(allocator, .{ .name = name, .entries = try entries.toOwnedSlice(allocator) });
    }
    return mods.toOwnedSlice(allocator);
}

pub fn indexDeinit(mods: []Module, allocator: std.mem.Allocator) void {
    for (mods) |m| allocator.free(m.entries);
    allocator.free(mods);
}

/// The distinct module names, in registry order, found at comptime. Walking the
/// registry rather than writing a list is the same anti-drift rule the
/// highlighter's globals follow.
const module_names = blk: {
    @setEvalBranchQuota(20000);
    var names: [api_meta.bindings.len][]const u8 = undefined;
    var n: usize = 0;
    for (api_meta.bindings) |b| {
        var seen = false;
        for (names[0..n]) |m| {
            if (std.mem.eql(u8, m, b.module)) seen = true;
        }
        if (!seen) {
            names[n] = b.module;
            n += 1;
        }
    }
    break :blk names[0..n].*;
};

fn moduleNames() []const []const u8 {
    return &module_names;
}

/// The bindings whose name or summary matches `query`, best first.
///
/// The ranking is the one thing about a search that is a decision rather than a
/// detail, and it is deliberately readable: an exact name beats a name that
/// starts with the query, which beats a name that contains it, which beats a
/// summary that mentions it. A fancy scorer nobody can predict makes the panel
/// slower to use than no panel at all.
pub fn search(allocator: std.mem.Allocator, query: []const u8, limit: usize) ![]api_meta.Binding {
    // Case-insensitive, and a query of nothing is a request for a browse list
    // rather than a search: everything matches, in registry order.
    if (query.len == 0) {
        const n = @min(limit, api_meta.bindings.len);
        const out = try allocator.alloc(api_meta.Binding, n);
        @memcpy(out, api_meta.bindings[0..n]);
        return out;
    }

    var out: std.ArrayListUnmanaged(Ranked) = .empty;
    defer out.deinit(allocator);
    for (api_meta.bindings) |b| {
        const rank = rankOf(b, query) orelse continue;
        try out.append(allocator, .{ .binding = b, .rank = rank });
    }
    std.mem.sort(Ranked, out.items, {}, better);

    const n = @min(limit, out.items.len);
    const bindings = try allocator.alloc(api_meta.Binding, n);
    for (bindings, out.items[0..n]) |*dst, r| dst.* = r.binding;
    return bindings;
}

const Ranked = struct {
    binding: api_meta.Binding,
    rank: u8,
};

/// Lower is better. Zero is the best rank there is.
fn rankOf(binding: api_meta.Binding, query: []const u8) ?u8 {
    if (startsWithCI(binding.name, query)) return 0;
    if (startsWithCI(shortName(binding), query)) return 1;
    if (containsCI(binding.name, query)) return 2;
    if (containsCI(binding.signature, query)) return 3;
    if (containsCI(binding.summary, query)) return 4;
    return null;
}

/// `actor.get_position` → `get_position`: the part a user types when they have
/// already typed the module.
fn shortName(binding: api_meta.Binding) []const u8 {
    if (std.mem.indexOfScalar(u8, binding.name, '.')) |dot| return binding.name[dot + 1 ..];
    return binding.name;
}

fn better(_: void, a: Ranked, b: Ranked) bool {
    if (a.rank != b.rank) return a.rank < b.rank;
    return a.binding.name.len < b.binding.name.len;
}

fn startsWithCI(haystack: []const u8, needle: []const u8) bool {
    if (haystack.len < needle.len) return false;
    return std.ascii.eqlIgnoreCase(haystack[0..needle.len], needle);
}

fn containsCI(haystack: []const u8, needle: []const u8) bool {
    if (needle.len == 0) return true;
    if (haystack.len < needle.len) return false;
    var at: usize = 0;
    while (at + needle.len <= haystack.len) : (at += 1) {
        if (std.ascii.eqlIgnoreCase(haystack[at .. at + needle.len], needle)) return true;
    }
    return false;
}

/// The whole panel content for one binding, as text: the signature, the summary,
/// a parameters table with types and notes, the return types, and the example.
///
/// Text rather than a widget tree because the panel is not the only surface that
/// renders this: the in-engine console can print the same block, a text-mode
/// build has nothing to draw with, and a test can read it. The UI lays this out;
/// it does not have to know what goes in it.
pub fn render(binding: api_meta.Binding, allocator: std.mem.Allocator) ![]u8 {
    var out: std.Io.Writer.Allocating = .init(allocator);
    errdefer out.deinit();
    const w = &out.writer;
    try w.writeAll(binding.signature);
    try w.writeByte('\n');
    if (binding.summary.len > 0) {
        try w.writeAll(binding.summary);
        try w.writeByte('\n');
    }

    try w.writeAll("\nParameters\n");
    if (binding.params.len == 0) {
        try w.writeAll("  (none)\n");
    }
    for (binding.params) |p| {
        try w.print("  {s}: {s}", .{ p.name, p.kind.luaName() });
        if (p.default) |d| try w.print(" = {s}", .{d});
        if (p.doc.len > 0) try w.print("  — {s}", .{p.doc});
        try w.writeByte('\n');
    }

    try w.writeAll("\nReturns\n");
    if (binding.returns.len == 0) {
        // "nothing" is information: a function that returns no value is a
        // function whose result cannot be used, and saying so saves a question.
        try w.writeAll("  nothing\n");
    }
    for (binding.returns) |r| {
        try w.print("  {s}", .{r.kind.luaName()});
        if (r.doc.len > 0) try w.print("  — {s}", .{r.doc});
        try w.writeByte('\n');
    }

    if (binding.example.len > 0) {
        try w.writeAll("\nExample\n");
        try w.writeAll(binding.example);
        try w.writeByte('\n');
    }
    return out.toOwnedSlice();
}

// ─── Tests ───────────────────────────────────────────────────────────────────

const testing = std.testing;

fn activateOf(src: []const u8, at: usize, allocator: std.mem.Allocator) Action {
    var r = parser.parse(allocator, src) catch return .nothing;
    defer r.deinit(allocator);
    return activate(src, r, @intCast(at));
}

test "Ctrl+Click on a binding opens the panel" {
    const a = testing.allocator;
    const src = "actor.set_position(self, x, y)";
    const at = std.mem.indexOf(u8, src, "position").? + 2;
    switch (activateOf(src, at, a)) {
        .help => |b| try testing.expectEqualStrings("actor.set_position", b.name),
        else => return error.WrongAction,
    }
}

test "Ctrl+Click on the file's own name jumps, and does not open the panel" {
    // A local called `actor` is a real thing a user writes. The file's own name
    // wins over the engine's module of the same spelling, because it is the one
    // they just typed.
    const a = testing.allocator;
    const src =
        \\local actor = 1
        \\return actor
    ;
    const at = std.mem.indexOf(u8, src, "return actor").? + "return ".len;
    switch (activateOf(src, at, a)) {
        .jump => |span| try testing.expectEqualStrings("local actor = 1", src[span.start .. span.start + span.len]),
        else => return error.WrongAction,
    }
}

test "Ctrl+Click on nothing does nothing" {
    const a = testing.allocator;
    switch (activateOf("print(1)", 0, a)) {
        .nothing => {},
        else => return error.WrongAction,
    }
}

test "the index lists every module the registry has" {
    const a = testing.allocator;
    const mods = try index(a);
    defer indexDeinit(mods, a);
    try testing.expect(mods.len > 4);

    // Every binding appears exactly once, under its own module.
    var total: usize = 0;
    for (mods) |m| {
        try testing.expect(m.entries.len > 0);
        total += m.entries.len;
        for (m.entries) |e| try testing.expectEqualStrings(m.name, e.binding.module);
    }
    try testing.expectEqual(api_meta.bindings.len, total);
}

test "search ranks the name being typed above everything else" {
    const a = testing.allocator;
    const found = try search(a, "set_position", 8);
    defer a.free(found);
    try testing.expect(found.len >= 1);
    try testing.expectEqualStrings("actor.set_position", found[0].name);
}

test "search finds a function by what its summary says it does" {
    // `sprite.set_layer`'s summary is "Draw order. Lower draws first": a search
    // on words from the docs is how a panel gets used by someone who does not
    // remember a name.
    const a = testing.allocator;
    const found = try search(a, "Draw order", 8);
    defer a.free(found);
    try testing.expect(found.len >= 1);
    try testing.expectEqualStrings("sprite.set_layer", found[0].name);
}

test "search respects its limit and ranks by distance" {
    const a = testing.allocator;
    const found = try search(a, "set_", 5);
    defer a.free(found);
    try testing.expectEqual(@as(usize, 5), found.len);
    // Every entry starts with `set_` at the rank that matched, and they are
    // ordered best-first.
    for (found) |b| {
        try testing.expect(containsCI(b.name, "set_"));
    }
    try testing.expect(found[0].name.len <= found[1].name.len);
}

test "an empty query browses rather than searches" {
    const a = testing.allocator;
    const found = try search(a, "", 6);
    defer a.free(found);
    try testing.expectEqual(@as(usize, 6), found.len);
    // Registry order, not ranking: a browse list should be predictable.
    try testing.expectEqualStrings(api_meta.bindings[0].name, found[0].name);
}

test "the panel body renders signature, parameters, returns and example" {
    // The M5.5 criterion, as text: description, typed parameters, return value
    // and example, all from the registry row. If any of them is missing the
    // registry entry was incomplete, and that is a build failure rather than an
    // empty paragraph.
    const a = testing.allocator;
    const binding = api_meta.find("sprite.set_layer") orelse return error.NoBinding;
    const text = try render(binding, a);
    defer a.free(text);
    try testing.expect(std.mem.startsWith(u8, text, "sprite.set_layer(self, layer)"));
    try testing.expect(std.mem.indexOf(u8, text, "Draw order.") != null);
    try testing.expect(std.mem.indexOf(u8, text, "self: Actor") != null);
    try testing.expect(std.mem.indexOf(u8, text, "layer: integer") != null);
    try testing.expect(std.mem.indexOf(u8, text, "Returns\n  nothing") != null);
    try testing.expect(std.mem.indexOf(u8, text, "sprite.set_layer(self, 10)") != null);
}

test "a function with a return renders its return type" {
    const a = testing.allocator;
    const binding = api_meta.find("actor.get_position") orelse return error.NoBinding;
    const text = try render(binding, a);
    defer a.free(text);
    try testing.expect(std.mem.indexOf(u8, text, "number") != null);
}

test "the rendered panel is what a user reads, verbatim" {
    // A golden block rather than per-fragment assertions: the panel is text a
    // person reads, and its shape — blank lines, indentation, the order of the
    // sections — is part of the feature. If this ever changes it should change
    // on purpose, with a diff that says what changed.
    const a = testing.allocator;
    const binding = api_meta.find("actor.get_position") orelse return error.NoBinding;
    const text = try render(binding, a);
    defer a.free(text);
    try testing.expectEqualStrings(
        \\actor.get_position(self) -> number, number
        \\World-space position of this actor as x, y.
        \\
        \\Parameters
        \\  self: Actor
        \\
        \\Returns
        \\  number  — x in world units (pixels unless the game scales them)
        \\  number  — y in world units
        \\
        \\Example
        \\local x, y = actor.get_position(self)
        \\log.info("player at " .. x .. ", " .. y)
        \\
    , text);
}
