//! Name resolution, shared: which declaration is this name actually naming?
//!
//! Three features need the same answer and the answer is subtle enough that
//! having it once is worth a module of its own:
//!
//! - **Diagnostics** asks "does this read resolve to anything", because an
//!   unresolvable name is a misspelled global.
//! - **Goto-definition** asks "which declaration", which is the same question
//!   with the answer kept.
//! - **Completion** asks the negative one: which names in this file are live
//!   where the caret is.
//!
//! ## The rule, in one place
//!
//! A name resolves to the nearest declaration of that name in an enclosing
//! scope, **declared before the use**. The "before" is Lua's rule, not a
//! convenience: `print(x); local x = 1` reads a global, and it is the single
//! thing that makes forward declarations behave the way every user expects.
//!
//! The "nearest" is the innermost scope first and then outwards, which is why
//! the parser records a scope chain with a parent per scope and this module
//! walks it. Everything here is in byte offsets: a scope's identity is the
//! index of its `Scope` record, and containment is a walk from the use's scope
//! up to the root.

const std = @import("std");
const parser = @import("parser.zig");

pub const Decl = struct {
    start: u32,
    len: u32,
    /// Index into `parsed.scopes`.
    scope: u32,
};

/// Every declaration the parse produced, in source order. One allocation, one
/// walk, shared by every consumer: the diagnostics, goto-definition and the
/// reference list all pass this list around instead of building their own.
pub fn declarations(allocator: std.mem.Allocator, parsed: parser.Result) ![]Decl {
    var out: std.ArrayListUnmanaged(Decl) = .empty;
    errdefer out.deinit(allocator);
    for (parsed.uses) |u| {
        if (u.kind != .decl) continue;
        try out.append(allocator, .{
            .start = u.start,
            .len = u.len,
            .scope = u.scope,
        });
    }
    return out.toOwnedSlice(allocator);
}

/// The declaration that IS this local's name. A local symbol and its `decl` use
/// carry the same name offset, so the identity is the offset — which is also
/// why this is not a lookup by name: two locals with the same name in
/// different scopes are two different declarations with the same text.
pub fn declOf(decls: []const Decl, sym: parser.Symbol) ?Decl {
    for (decls) |d| {
        if (d.start == sym.name_start and d.len == sym.name_len) return d;
    }
    return null;
}

/// The declaration this use names, or null if it names nothing local. A use
/// resolves to the first declaration found walking outwards from its own scope,
/// which is innermost-first because that is the first one Lua finds.
pub fn resolution(
    scopes: []const parser.Scope,
    decls: []const Decl,
    use: parser.Use,
    src: []const u8,
) ?Decl {
    const name = src[use.start .. use.start + use.len];
    var scope = use.scope;
    while (true) {
        // The nearest declaration before the use, in this scope. Scanning
        // backwards and taking the first makes a rebind win over the binding it
        // replaced, which is what `local x = 1; local x = 2; print(x)` does.
        var i = decls.len;
        while (i > 0) {
            i -= 1;
            const d = decls[i];
            if (d.scope != scope) continue;
            if (d.start >= use.start) continue;
            if (!std.mem.eql(u8, src[d.start .. d.start + d.len], name)) continue;
            return d;
        }
        const parent = scopes[scope].parent;
        if (parent == parser.no_scope) return null;
        scope = parent;
    }
}

/// Does this use resolve to anything at all? A shortcut for the diagnostics,
/// which only wants the yes/no and would otherwise allocate nothing to learn it.
pub fn resolves(
    scopes: []const parser.Scope,
    decls: []const Decl,
    use: parser.Use,
    src: []const u8,
) bool {
    return resolution(scopes, decls, use, src) != null;
}

/// Is `inner` the same scope as `outer`, or inside it?
pub fn containsScope(scopes: []const parser.Scope, inner: u32, outer: u32) bool {
    var scope = inner;
    while (true) {
        if (scope == outer) return true;
        const parent = scopes[scope].parent;
        if (parent == parser.no_scope) return false;
        scope = parent;
    }
}

// ─── Tests ───────────────────────────────────────────────────────────────────

const testing = std.testing;

const P = struct {
    r: parser.Result,
    src: []const u8,
    decls: []Decl,

    fn init(a: std.mem.Allocator, src: []const u8) !P {
        const r = try parser.parse(a, src);
        return .{ .r = r, .src = src, .decls = try declarations(a, r) };
    }

    fn deinit(self: *P, a: std.mem.Allocator) void {
        a.free(self.decls);
        var copy = self.r;
        copy.deinit(a);
    }

    /// The declaration a read of `name` at byte offset `at` resolves to. The
    /// offset is where the test says the read is; the helper does the lookup
    /// rather than trusting a number the reader has to count.
    fn resolutionAt(self: P, name: []const u8, at: u32) ?Decl {
        for (self.r.uses) |u| {
            if (u.kind != .read) continue;
            if (u.start != at) continue;
            if (!std.mem.eql(u8, self.src[u.start .. u.start + u.len], name)) continue;
            return resolution(self.r.scopes, self.decls, u, self.src);
        }
        return null;
    }

    /// The declaration this local resolved to, as text, for assertions.
    fn textOf(self: P, d: Decl) []const u8 {
        return self.src[d.start .. d.start + d.len];
    }
};

test "a read resolves to the local before it" {
    const a = testing.allocator;
    const src = "local x = 1\nreturn x";
    var p = try P.init(a, src);
    defer p.deinit(a);
    const at: u32 = @intCast(std.mem.indexOf(u8, src, "return x").? + "return ".len);
    const d = p.resolutionAt("x", at) orelse return error.NoResolution;
    try testing.expectEqualStrings("x", p.textOf(d));
    try testing.expectEqual(@as(u32, 6), d.start);
}

test "a read before the declaration is a global, not the local" {
    // This is Lua's rule and the reason the "before" half exists: the first `x`
    // is read before the local exists, so it is a global, and the second one
    // is the local.
    const a = testing.allocator;
    const src = "print(x)\nlocal x = 1\nreturn x";
    var p = try P.init(a, src);
    defer p.deinit(a);
    const first: u32 = @intCast(std.mem.indexOf(u8, src, "print(x)").? + "print(".len);
    const second: u32 = @intCast(std.mem.indexOf(u8, src, "return x").? + "return ".len);
    try testing.expect(p.resolutionAt("x", first) == null);
    try testing.expect(p.resolutionAt("x", second) != null);
}

test "the innermost declaration wins" {
    const a = testing.allocator;
    const src =
        \\local x = 1
        \\local function f()
        \\    local x = 2
        \\    return x
        \\end
    ;
    var p = try P.init(a, src);
    defer p.deinit(a);
    const at: u32 = @intCast(std.mem.indexOf(u8, src, "return x").? + "return ".len);
    const d = p.resolutionAt("x", at) orelse return error.NoResolution;
    // The inner `x`, not the outer one: the declaration is the NAME inside the
    // second `local`, which is where the parser records a declaration — the
    // keyword is not part of the name.
    const inner_start = std.mem.indexOf(u8, src, "local x = 2").? + "local ".len;
    try testing.expectEqual(inner_start, d.start);
    try testing.expectEqualStrings("x", p.textOf(d));
}

test "an outer scope is found from an inner one" {
    const a = testing.allocator;
    const src =
        \\local outer = 1
        \\local function f()
        \\    return outer
        \\end
    ;
    var p = try P.init(a, src);
    defer p.deinit(a);
    const at: u32 = @intCast(std.mem.indexOf(u8, src, "return outer").? + "return ".len);
    const d = p.resolutionAt("outer", at) orelse return error.NoResolution;
    try testing.expectEqual(@as(u32, 6), d.start);
}

test "a shadowed name resolves to the nearer one" {
    const a = testing.allocator;
    const src =
        \\local x = 1
        \\local function f()
        \\    local x = 2
        \\    return x
        \\end
        \\return x
    ;
    var p = try P.init(a, src);
    defer p.deinit(a);
    const inner_at: u32 = @intCast(std.mem.indexOf(u8, src, "return x").? + "return ".len);
    const outer_at: u32 = @intCast(std.mem.lastIndexOf(u8, src, "return x").? + "return ".len);
    const inner = p.resolutionAt("x", inner_at) orelse return error.NoResolution;
    const outer = p.resolutionAt("x", outer_at) orelse return error.NoResolution;
    try testing.expect(inner.start != outer.start);
    try testing.expectEqual(@as(u32, 6), outer.start);
}

test "scope containment walks the chain" {
    const a = testing.allocator;
    const src =
        \\local function f(a)
        \\    return a
        \\end
    ;
    var p = try P.init(a, src);
    defer p.deinit(a);
    // The body scope is inside the file scope, and not the other way round.
    try testing.expect(containsScope(p.r.scopes, 2, 1));
    try testing.expect(!containsScope(p.r.scopes, 1, 2));
    // The chunk's root scope contains itself.
    try testing.expect(containsScope(p.r.scopes, 1, 1));
}
