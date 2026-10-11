//! Engine-aware diagnostics: what the parser found, finished with what the
//! engine knows.
//!
//! ## Why this exists on top of the parser
//!
//! Error lens is normally a red underline for a syntax mistake. That is the
//! small half. The half worth having is the one no generic LSP can produce,
//! because it is not about Lua: this engine ships a binding registry in which
//! every function exposed to scripts has a signature, parameter types and a
//! description. From that table, three questions become answerable while the
//! user types:
//!
//! 1. **`actor.set_position(self, 1)`** — the binding takes three arguments
//!    and two were written. Nothing in Lua's grammar knows that.
//! 2. **`actor.set_position(self, "home", 2)`** — the parameter typed `number`
//!    is being handed a string. A syntax parser cannot see it either; the
//!    metadata has the type.
//! 3. **`actr.get_position(...)`** — a misspelled engine global. The generic
//!    rule only needs the whitelist of names that exist, and the lexer has it
//!    for colouring: the two now share one list instead of two that drift.
//!
//! Plus the three Lua-level ones that any editor should have: an unknown
//! global, an unused local, and a local shadowing an outer one.
//!
//! ## Why the checks are conservative
//!
//! A wrong diagnostic is worse than a missing one: a user who is told a line
//! is broken learns to ignore the lens, and then it protects nothing. So the
//! type rule fires only when the argument is a *literal* of the wrong shape —
//! a variable could hold anything, and a table might be a Vec2. The arity rule
//! checks the lower bound only, because "too many" has no reading of
//! "arguments" that survives a Lua table spread. And every rule here can be
//! switched off without the parse changing, which is the point of running
//! them as a pass over a finished result rather than inside the parser.

const std = @import("std");
const parser = @import("parser.zig");
const lexer = @import("lexer.zig");
const api_meta = @import("api_meta");
const resolve = @import("resolve.zig");

/// How loud a problem is, in the vocabulary the lens draws with: an error stops
/// the script, a warning is almost certainly wrong, a hint is worth knowing.
pub const Severity = enum { err, warn, hint };

pub const Code = enum {
    /// From the parser: the script will not run.
    syntax,
    /// A name that is neither local, nor the engine's, nor Lua's.
    unknown_global,
    /// A documented call with fewer arguments than the signature requires.
    arity,
    /// A literal of the wrong shape for a typed parameter.
    arg_type,
    /// A declared local that is never read.
    unused_local,
    /// A local hiding one of the same name in an enclosing scope.
    shadow,
};

pub const Diagnostic = struct {
    start: u32,
    len: u32,
    severity: Severity,
    code: Code,
    /// For `.arity`: the argument count the signature asks for.
    expected: u8 = 0,
    /// For `.arity`: what the call actually passes, `self` included.
    found: u16 = 0,
};

/// Runs every rule over `src` and `parsed`. `parsed` must be the parse of
/// `src`: the two are walked together, which is why they are separate
/// arguments and not one structure — the parse results are shared with the
/// outline and the completion engine, and only this pass reads them together.
pub fn analyze(allocator: std.mem.Allocator, src: []const u8, parsed: parser.Result) ![]Diagnostic {
    var out: std.ArrayListUnmanaged(Diagnostic) = .empty;
    errdefer out.deinit(allocator);

    // ── Syntax, straight through ───────────────────────────────────────────
    // The parser put them in order and at a byte offset; this only re-labels
    // them, because a rule that re-derives a parse error from a parse is a
    // rule that disagrees with it eventually.
    for (parsed.diags) |d| {
        try out.append(allocator, .{
            .start = d.start,
            .len = d.len,
            .severity = .err,
            .code = .syntax,
        });
    }

    // ── Declarations ─────────────────────────────────────────────────────────
    // Every name the file introduces, with the scope it belongs to. A read is
    // answered by the nearest declaration in an enclosing scope that comes
    // BEFORE it, which is exactly Lua's rule: a local is not in scope before
    // its own declaration, so `print(x); local x = 1` reads a global.
    const decls = try resolve.declarations(allocator, parsed);
    defer allocator.free(decls);

    // ── Names that resolve to nothing ──────────────────────────────────────
    for (parsed.uses) |u| {
        if (u.kind != .read) continue;
        if (resolve.resolves(parsed.scopes, decls, u, src)) continue;
        const name = src[u.start .. u.start + u.len];
        if (isKnownGlobal(name)) continue;
        try out.append(allocator, .{
            .start = u.start,
            .len = u.len,
            .severity = .warn,
            .code = .unknown_global,
        });
    }

    // ── Locals that are never read, and locals that hide an outer one ──────
    // Both need the surviving locals, which is why they are one pass: two
    // passes would build the same table twice.
    for (parsed.symbols) |sym| {
        if (sym.kind != .local) continue;
        const decl = resolve.declOf(decls, sym) orelse continue;
        const name = parser.Result.name(src, sym);
        // `_` and `_unused` are the convention for "deliberately not read",
        // and honouring it is what keeps the rule from being noise.
        if (name.len > 0 and name[0] == '_') continue;

        var reads: usize = 0;
        for (parsed.uses) |u| {
            if (u.kind != .read) continue;
            if (!readsLocal(parsed, u, decl, src)) continue;
            reads += 1;
        }
        if (reads == 0) {
            try out.append(allocator, .{
                .start = sym.name_start,
                .len = sym.name_len,
                .severity = .hint,
                .code = .unused_local,
            });
        }

        // Shadowing is a hint rather than a warning because Lua programmers do
        // it on purpose: `for _, item in ipairs(x)` inside a function that
        // also has an `item` is idiomatic, not a mistake.
        if (shadowsOuter(parsed.scopes, decls, decl, src)) {
            try out.append(allocator, .{
                .start = sym.name_start,
                .len = sym.name_len,
                .severity = .hint,
                .code = .shadow,
            });
        }
    }

    // ── The engine's own rules ────────────────────────────────────────────
    // A call is only checked when its callee names a documented binding. The
    // engine's members are the value here: `actor.set_position` is a path the
    // registry knows, and nothing else in a Lua editor does.
    for (parsed.calls) |call| {
        const path = parser.Result.callPath(src, call);
        const binding = api_meta.find(path) orelse continue;
        // A `:` call passes the receiver as the first argument without the
        // user writing it, so the count has to account for it or every method
        // would look one short.
        const found: u16 = call.arg_count + @intFromBool(call.method);

        var required: u8 = 0;
        for (binding.params) |p| {
            if (p.default == null) required += 1;
        }
        if (found < required) {
            try out.append(allocator, .{
                .start = call.path_start,
                .len = @intCast(path.len),
                .severity = .warn,
                .code = .arity,
                .expected = required,
                .found = found,
            });
            continue;
        }

        var i: u16 = 0;
        while (i < call.arg_count and i < binding.params.len) : (i += 1) {
            const want = binding.params[i].kind;
            // A `:` call's first parameter is the receiver, typed `actor`, and
            // the first argument the user wrote is the second parameter: shift.
            const got = parsed.args[call.arg_first + i];
            if (!shapeMismatch(want, got.kind)) continue;
            try out.append(allocator, .{
                .start = got.start,
                .len = got.len,
                .severity = .warn,
                .code = .arg_type,
            });
        }
    }

    return out.toOwnedSlice(allocator);
}

// ─── Name resolution, shared with goto and completion ────────────────────────
// `resolve.resolution` answers "which declaration is this name", and the rules
// that need the answer live there so they can exist once. What is left here is
// the one rule that is diagnostics-only: a local is unused when NOTHING reads
// it, and a read only counts when it actually resolves to THIS declaration.
// Two locals with the same name in different scopes are two variables, and the
// first one is still unused if the second one is being read.

const no_scope = parser.no_scope;

/// Does this read resolve to THIS local, and not to some other one? Used to
/// decide whether the local was ever used.
fn readsLocal(parsed: parser.Result, use: parser.Use, decl: resolve.Decl, src: []const u8) bool {
    if (!std.mem.eql(u8, src[use.start .. use.start + use.len], src[decl.start .. decl.start + decl.len])) return false;
    if (use.start < decl.start) return false;
    // The read has to sit inside the declaration's scope: a read of a name
    // spelled the same in an unrelated scope does not count, and counting it
    // would excuse a genuinely unused local.
    return resolve.containsScope(parsed.scopes, use.scope, decl.scope);
}

/// Does an enclosing scope already have this name, declared before this one?
fn shadowsOuter(scopes: []const parser.Scope, decls: []const resolve.Decl, decl: resolve.Decl, src: []const u8) bool {
    // The search starts one level out: the declaration's own scope is where the
    // name is being introduced, and a redeclaration in the SAME scope is a
    // rebind, not a shadow — Lua programs do that freely.
    var scope = scopes[decl.scope].parent;
    while (scope != no_scope) {
        for (decls) |d| {
            if (d.scope != scope) continue;
            if (d.start >= decl.start) continue;
            if (!std.mem.eql(u8, src[d.start .. d.start + d.len], src[decl.start .. decl.start + decl.len])) continue;
            return true;
        }
        scope = scopes[scope].parent;
    }
    return false;
}

// ─── The whitelist ────────────────────────────────────────────────────────────

/// A name that exists without being declared in this file. Two sources, and
/// the point of having two is that neither can drift silently: the lexer's
/// list is what colours the name, and the metadata's modules are what the
/// engine actually ships. A new engine module added to the registry stops
/// being flagged as unknown on its own.
fn isKnownGlobal(name: []const u8) bool {
    for (lexer.globals) |g| if (std.mem.eql(u8, g, name)) return true;
    for (api_meta.bindings) |b| {
        if (std.mem.eql(u8, b.module, name)) return true;
        // A binding registered without a module prefix (`vec2`, `require`).
        if (std.mem.indexOfScalar(u8, b.name, '.') == null and std.mem.eql(u8, b.name, name)) return true;
    }
    return false;
}

/// The only argument shapes worth disagreeing about. Anything that could be
/// a table (`vec2`, `rect2`, `actor`) is left alone: the metadata types it as
/// one kind, and a literal that is the wrong string in that position may still
/// be right through a variable. A number handed a string, or a string handed a
/// number, is wrong whatever came before it.
fn shapeMismatch(want: api_meta.Kind, got: parser.ArgKind) bool {
    return switch (want) {
        .number, .integer => switch (got) {
            .string => true,
            else => false,
        },
        .string => switch (got) {
            .number, .boolean, .nil => true,
            else => false,
        },
        else => false,
    };
}

// ─── Tests ───────────────────────────────────────────────────────────────────

const testing = std.testing;

/// Parses and analyzes `src`, returning the diagnostics for the caller to pick
/// a problem out of. The two steps are kept separate in tests because the
/// interesting question is always "which rule fired", not "did anything fire".
const Analyzed = struct { r: parser.Result, diags: []Diagnostic };

fn analyzeOf(src: []const u8) !Analyzed {
    const a = testing.allocator;
    const r = try parser.parse(a, src);
    const found = try analyze(a, src, r);
    return .{ .r = r, .diags = found };
}

fn freeOf(t: Analyzed) void {
    const a = testing.allocator;
    a.free(t.diags);
    var copy = t.r;
    copy.deinit(a);
}

fn diags(src: []const u8, code: Code) !usize {
    const t = try analyzeOf(src);
    defer freeOf(t);
    var n: usize = 0;
    for (t.diags) |d| if (d.code == code) {
        n += 1;
    };
    return n;
}

test "a correct behavior produces no diagnostics" {
    const src =
        \\local M = {}
        \\
        \\function M.update(self, dt)
        \\    local x, y = actor.get_position(self)
        \\    actor.set_position(self, x + 1, y)
        \\    log.info("at " .. x)
        \\    for i = 1, 10 do
        \\        local angle = i * 0.1
        \\        print(math.sin(angle))
        \\    end
        \\    return x
        \\end
        \\
        \\return M
    ;
    try testing.expectEqual(@as(usize, 0), try diags(src, .unknown_global));
    try testing.expectEqual(@as(usize, 0), try diags(src, .arity));
    try testing.expectEqual(@as(usize, 0), try diags(src, .arg_type));
    try testing.expectEqual(@as(usize, 0), try diags(src, .unused_local));
    try testing.expectEqual(@as(usize, 0), try diags(src, .syntax));
}

test "a misspelled engine global is caught" {
    try testing.expectEqual(@as(usize, 1), try diags("actr.get_position(self)", .unknown_global));
    // The whole engine vocabulary is fine, including the modules that were
    // added after the lexer's list was written.
    try testing.expectEqual(@as(usize, 0), try diags("sprite.set_size(self, 2, 3)", .unknown_global));
    try testing.expectEqual(@as(usize, 0), try diags("render.set_view(1, 2)", .unknown_global));
    // Lua's own library, and the names a script declares itself.
    // Lua's own library: the pairs and print the sandbox whitelists for
    // colouring are the same names that must not be flagged as unknown.
    try testing.expectEqual(@as(usize, 0), try diags("print(pairs({}))", .unknown_global));
    try testing.expectEqual(@as(usize, 0), try diags("local t = {}\nprint(t)", .unknown_global));
}

test "a documented call is checked against its signature" {
    // `actor.set_position(self, x, y)`: three, of which self has no default.
    try testing.expectEqual(@as(usize, 1), try diags("actor.set_position(self, 1)", .arity));
    try testing.expectEqual(@as(usize, 0), try diags("actor.set_position(self, 1, 2)", .arity));
    // Defaults are not required arguments: `noise.fbm(x, y, octaves=4,
    // basis="perlin")` is happy with two, and unhappy with one.
    try testing.expectEqual(@as(usize, 0), try diags("local h = noise.fbm(1, 2)", .arity));
    try testing.expectEqual(@as(usize, 1), try diags("local h = noise.fbm(1)", .arity));
    // A member call on something else is not the engine's to check: `self` is
    // a real global and `self.set_layer` is not a documented path.
    try testing.expectEqual(@as(usize, 0), try diags("sprite.set_layer(self, 1)", .arity));
}

test "the arity diagnostic carries both counts" {
    const a = testing.allocator;
    const src = "actor.set_position(self, 1)";
    var r = try parser.parse(a, src);
    defer r.deinit(a);
    const diag_list = try analyze(a, src, r);
    defer a.free(diag_list);
    var found: ?Diagnostic = null;
    for (diag_list) |d| {
        if (d.code == .arity) found = d;
    }
    try testing.expect(found != null);
    try testing.expectEqual(@as(u8, 3), found.?.expected);
    try testing.expectEqual(@as(u16, 2), found.?.found);
    // It underlines the call, not one of its arguments.
    try testing.expectEqualStrings("actor.set_position", src[found.?.start .. found.?.start + found.?.len]);
}

test "a string is not a number" {
    try testing.expectEqual(@as(usize, 1), try diags("actor.set_position(self, \"home\", 2)", .arg_type));
    // The other direction: a number handed to a string parameter. `log.info`
    // takes a message, and a number is not one.
    try testing.expectEqual(@as(usize, 1), try diags("log.info(12)", .arg_type));
    // A variable is not a literal: it could hold anything, and saying so when
    // it might be right is how a lens gets ignored.
    try testing.expectEqual(@as(usize, 0), try diags("local p = 0\nactor.set_position(self, p, 2)", .arg_type));
}

test "the type diagnostic underlines the argument itself" {
    const a = testing.allocator;
    const src = "actor.set_position(self, \"home\", 2)";
    var r = try parser.parse(a, src);
    defer r.deinit(a);
    const diag_list = try analyze(a, src, r);
    defer a.free(diag_list);
    var found: ?Diagnostic = null;
    for (diag_list) |d| {
        if (d.code == .arg_type) found = d;
    }
    try testing.expect(found != null);
    try testing.expectEqualStrings("\"home\"", src[found.?.start .. found.?.start + found.?.len]);
}

test "a local that is never read is a hint, not an error" {
    const src = "local total = 0\nlocal used = 1\nprint(used)";
    try testing.expectEqual(@as(usize, 1), try diags(src, .unused_local));
    const a = testing.allocator;
    var r = try parser.parse(a, src);
    defer r.deinit(a);
    const diag_list = try analyze(a, src, r);
    defer a.free(diag_list);
    var found: ?Diagnostic = null;
    for (diag_list) |d| {
        if (d.code == .unused_local) found = d;
    }
    try testing.expectEqualStrings("total", src[found.?.start .. found.?.start + found.?.len]);
    // The convention for "written on purpose" is honoured.
    try testing.expectEqual(@as(usize, 0), try diags("local _scratch = 0", .unused_local));
    // A local with a broken initializer still counts as declared: it is
    // exactly the file being typed, and this rule must not shout in it.
    try testing.expectEqual(@as(usize, 1), try diags("local x =\nprint(1)", .unused_local));
}

test "a local hiding an outer one is a hint" {
    const src =
        \\local item = 1
        \\print(item)
        \\for item in ipairs({}) do print(item) end
    ;
    try testing.expectEqual(@as(usize, 1), try diags(src, .shadow));
}

test "a script the size of a real project stays quiet" {
    // Scale, not timing: a parse is re-run on every keystroke, so the property
    // that matters is that a file the size of a real behavior module produces
    // exactly the diagnostics it should and nothing that grows with it. A
    // timing budget lives in the benchmark, because a test that measures
    // milliseconds is a test that fails on a loaded machine.
    const a = testing.allocator;
    var src: std.ArrayListUnmanaged(u8) = .empty;
    defer src.deinit(a);
    // One module table, then two hundred blocks in it: the shape a real
    // behavior file has after a year of additions.
    try src.appendSlice(a, "local M = {}\n\n");
    const body = "function M.update(self, dt)\n    local x, y = actor.get_position(self)\n    return x + y\nend\n\n";
    for (0..200) |_| try src.appendSlice(a, body);
    const t = try analyzeOf(src.items);
    defer freeOf(t);
    // Nothing scales with the file that should not scale with it: the two
    // locals per function are each read, the calls match the registry, and
    // there is not one diagnostic per repetition.
    try testing.expectEqual(@as(usize, 0), t.diags.len);
    // One local, plus 200 blocks of function + two parameters + two locals.
    try testing.expectEqual(@as(usize, 1001), t.r.symbols.len);
    // One fold per block: 200 functions, and no fold for the module table.
    try testing.expectEqual(@as(usize, 200), t.r.folds.len);
}

test "syntax errors pass through as errors" {
    const a = testing.allocator;
    const src = "function f() return";
    var r = try parser.parse(a, src);
    defer r.deinit(a);
    const diag_list = try analyze(a, src, r);
    defer a.free(diag_list);
    try testing.expectEqual(@as(usize, 1), diag_list.len);
    try testing.expectEqual(Diagnostic{
        .start = r.diags[0].start,
        .len = r.diags[0].len,
        .severity = .err,
        .code = .syntax,
    }, diag_list[0]);
}
