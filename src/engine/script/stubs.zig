//! EmmyLua/LuaLS stub generation from the binding metadata (ROADMAP M5.5).
//!
//! The same comptime registry that powers the in-engine autocomplete also
//! generates the `.lua` annotation files LuaLS reads in VS Code / Neovim / Zed,
//! so the editor outside the engine and the editor inside it describe the SAME
//! API. CI regenerates these and fails the build if they drift from the
//! metadata (M5.5 criterion), which is only possible because there is exactly
//! one source of truth.
//!
//! Output shape: one annotated `function` per binding (actor methods as
//! `Actor:method`, module functions as `module.name`), written through a
//! minimal allocation-free cursor (`Buffer`) rather than `std.io`, matching how
//! the rest of `core`/`ecs` writes text (see `json.Writer`).

const std = @import("std");
const metadata = @import("metadata.zig");

const Binding = metadata.Binding;
const Kind = metadata.Kind;

/// A fixed-capacity, allocation-free write cursor. Implements the `print`,
/// `writeAll` and `writeByte` methods `writeStubs` needs, so the generator is
/// generic over the sink and the test can capture into a slice. Overflow is an
/// error, never a silent truncation (a truncated stub would look like metadata
/// drift in CI and fail the diff anyway).
pub const Buffer = struct {
    buf: []u8,
    len: usize = 0,

    pub const Error = error{OutOfBuffer};

    pub fn writeAll(self: *Buffer, bytes: []const u8) Error!void {
        if (self.len + bytes.len > self.buf.len) return error.OutOfBuffer;
        @memcpy(self.buf[self.len..][0..bytes.len], bytes);
        self.len += bytes.len;
    }

    pub fn writeByte(self: *Buffer, b: u8) Error!void {
        return self.writeAll(&[_]u8{b});
    }

    /// `std.fmt`-style printing, which is what the generator uses for the
    /// `---@param` lines. Any format error becomes `OutOfBuffer`.
    pub fn print(self: *Buffer, comptime fmt: []const u8, args: anytype) Error!void {
        const out = std.fmt.bufPrint(self.buf[self.len..], fmt, args) catch
            return error.OutOfBuffer;
        self.len += out.len;
    }

    pub fn written(self: *const Buffer) []const u8 {
        return self.buf[0..self.len];
    }
};

/// Upper bound on distinct modules. A fixed array keeps the generator
/// allocation-free (it runs in a build step, but it also runs inside a `zig
/// test`, where a failed allocation would be a confusing second error on top of
/// the real one).
const max_modules = 32;

/// Writes the complete stub file for every documented binding into `writer`.
/// Deterministic: same registry → same bytes, which is what lets CI diff them.
pub fn writeStubs(writer: anytype) !void {
    try writer.writeAll("--- Ember engine Lua API — GENERATED from metadata.zig, do not edit by hand.\n");
    try writer.writeAll("--- Regenerate with `zig build stubs` (CI fails if this drifts).\n\n");
    // `---@meta` tells LuaLS this file only annotates; it is not the real
    // implementation to jump into.
    try writer.writeAll("---@meta\n\n");

    // Group bindings by module, preserving registry order within each module.
    //
    // `seen` is a SET, not a comparison against the previous entry. Comparing
    // against the previous entry only works if the registry happens to be
    // sorted by module; the day one binding is appended at the end instead of
    // into its section, the same module gets a second header and its functions
    // are emitted twice — which is exactly what happened when the M4 physics
    // bindings were added at the end of the list rather than in place.
    //
    // Emitting a module twice is not cosmetic: an editor reading the stubs sees
    // two definitions of the same function and the second shadows the first.
    var seen: [max_modules][]const u8 = undefined;
    var seen_len: usize = 0;

    var module_i: usize = 0;
    while (module_i < metadata.bindings.len) : (module_i += 1) {
        const module = metadata.bindings[module_i].module;
        var already = false;
        for (seen[0..seen_len]) |s| {
            if (std.mem.eql(u8, s, module)) already = true;
        }
        if (already) continue;
        if (seen_len == max_modules) return error.TooManyModules;
        seen[seen_len] = module;
        seen_len += 1;
        try writer.print("-- ── {s} ──\n", .{module});

        var i: usize = 0;
        while (i < metadata.bindings.len) : (i += 1) {
            const b = metadata.bindings[i];
            if (!std.mem.eql(u8, b.module, module)) continue;
            try writeBinding(writer, b);
        }
        try writer.writeByte('\n');
    }
}

/// Writes one annotated function stub. The signature comes from the structured
/// params (not the prose `signature` field) so `---@param` types are exact.
fn writeBinding(writer: anytype, b: Binding) !void {
    try writer.print("---{s}\n", .{b.summary});

    for (b.params) |p| {
        const lua_type = p.kind.luaName();
        if (p.default) |def| {
            try writer.print("---@param {s} {s}? #{s}# {s}\n", .{ p.name, lua_type, def, p.doc });
        } else {
            try writer.print("---@param {s} {s} {s}\n", .{ p.name, lua_type, p.doc });
        }
    }
    for (b.returns) |r| {
        const lua_type = r.kind.luaName();
        try writer.print("---@return {s} {s}\n", .{ lua_type, r.doc });
    }

    // `self`-taking actor methods are emitted as `Actor:method` so LuaLS
    // offers them on the colon-call form gameplay uses.
    const has_self = b.params.len > 0 and std.mem.eql(u8, b.params[0].name, "self");
    if (has_self) {
        try writer.writeAll("function Actor:");
        try writer.writeAll(shortName(b.name));
        try writer.writeByte('(');
        try writeParamList(writer, b.params[1..]);
        try writer.writeAll(") end\n\n");
    } else {
        try writer.print("function {s}.{s}(", .{ b.module, shortName(b.name) });
        try writeParamList(writer, b.params);
        try writer.writeAll(") end\n\n");
    }
}

fn writeParamList(writer: anytype, params: []const metadata.Param) !void {
    for (params, 0..) |p, i| {
        if (i != 0) try writer.writeAll(", ");
        try writer.writeAll(p.name);
    }
}

/// The Lua-visible short name: strips the `module.` prefix so `actor.get_name`
/// becomes `get_name` (the field name inside the module/class table).
fn shortName(qualified: []const u8) []const u8 {
    const dot = std.mem.indexOfScalar(u8, qualified, '.') orelse return qualified;
    return qualified[dot + 1 ..];
}

// ── Tests ────────────────────────────────────────────────────────────────────

test "stub generation covers every binding and annotates types" {
    var buf: [1024 * 1024]u8 = undefined;
    var sink = Buffer{ .buf = &buf };
    try writeStubs(&sink);

    const out = sink.written();
    // Header + meta marker.
    try std.testing.expect(std.mem.indexOf(u8, out, "---@meta") != null);
    // Every binding's summary appears.
    for (metadata.bindings) |b| {
        try std.testing.expect(std.mem.indexOf(u8, out, b.summary) != null);
    }
    // Actor methods are emitted as `Actor:name` (the colon form gameplay uses).
    try std.testing.expect(std.mem.indexOf(u8, out, "function Actor:get_position(") != null);
    // Module functions keep the `module.name` form.
    try std.testing.expect(std.mem.indexOf(u8, out, "function input.is_action_down(") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "function math.clamp(") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "function vec2.dist(") != null);
    // Typed params are annotated (from the structured params, exact types).
    try std.testing.expect(std.mem.indexOf(u8, out, "---@param x number") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "---@param self Actor") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "---@param other Actor") != null);
    // The Emmylua optional/default form for parameters that have one.
    try std.testing.expect(std.mem.indexOf(u8, out, "---@param y number? #0#") != null);
    // Vec2/Rect2 kinds map to their LuaLS names.
    try std.testing.expect(std.mem.indexOf(u8, out, "---@param v Vec2") != null);
}

test "stub generation is deterministic (CI can diff it)" {
    var buf_a: [1024 * 1024]u8 = undefined;
    var buf_b: [1024 * 1024]u8 = undefined;
    var a = Buffer{ .buf = &buf_a };
    var b = Buffer{ .buf = &buf_b };
    try writeStubs(&a);
    try writeStubs(&b);
    try std.testing.expectEqualStrings(a.written(), b.written());
}
