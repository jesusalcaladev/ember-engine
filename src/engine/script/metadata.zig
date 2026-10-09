//! Binding metadata registry — the single source of truth for everything the
//! Lua surface exposes (ROADMAP M3, M5.5).
//!
//! Every function handed to Lua is described here ONCE, in comptime data:
//! signature, parameters (type + default), return value, a one-line summary and
//! a runnable example. From this one table we derive, with no hand-written
//! duplication:
//! - the in-engine autocomplete + tooltips (M5.5),
//! - the Ctrl+Click help panel (M5.5),
//! - the static docs site (M12),
//! - the **EmmyLua/LuaLS stubs** so VS Code/Neovim/Zed autocomplete the same
//!   API the engine actually ships (`stubs.zig`).
//!
//! The rule the roadmap states — "no metadata → the binding does not merge" —
//! is enforced mechanically: `bindings.zig` registers its C functions through
//! `assertAllDocumented`, a comptime check that every registered name has an
//! entry here with a non-empty summary and example. A new binding without
//! metadata is a compile error, not a review comment.
//!
//! Why comptime structs and not Zig doc-comments: Zig does not expose
//! `///`-comments through `@typeInfo`, so "doc-comments" as a *reflection*
//! source is not available. Declaring the metadata as explicit comptime data
//! next to the registry is the equivalent that actually compiles, and it keeps
//! the example (which must be real Lua, not prose) in a first-class field.

const std = @import("std");

/// The Lua-visible type of a parameter or return. Drives both the help panel
/// and the stub annotations (`---@param`), so the two can never disagree.
pub const Kind = enum {
    number,
    integer,
    string,
    boolean,
    vec2,
    rect2,
    actor,
    any,

    pub fn luaName(self: Kind) []const u8 {
        return switch (self) {
            .number => "number",
            .integer => "integer",
            .string => "string",
            .boolean => "boolean",
            .vec2 => "Vec2",
            .rect2 => "Rect2",
            .actor => "Actor",
            .any => "any",
        };
    }
};

/// One parameter: its Lua name, its type, an optional default (rendered in the
/// signature and the stub) and an optional per-parameter note.
pub const Param = struct {
    name: []const u8,
    kind: Kind,
    default: ?[]const u8 = null,
    doc: []const u8 = "",
};

/// One documented binding. `name` is the fully-qualified Lua name
/// (`"actor.get_position"`, `"math.clamp"`); `module` groups it for the stubs
/// and the docs index.
pub const Binding = struct {
    name: []const u8,
    module: []const u8,
    /// Human-readable signature, e.g. `"get_position(self) -> number, number"`.
    signature: []const u8,
    /// One-line description shown in the tooltip and the docs index.
    summary: []const u8,
    params: []const Param = &.{},
    /// Description of the return value(s); empty when the function returns none.
    returns: []const u8 = "",
    /// A complete, runnable Lua snippet. Must be real Lua: the M3 criterion is
    /// "every API exposed to Lua has metadata + example".
    example: []const u8,
};

// ── The registry ─────────────────────────────────────────────────────────────

/// Every binding the engine hands to Lua, documented. Append-only: order is the
/// order the docs index and the stubs list them in, and `bindings.zig` asserts
/// this set and its own registration are identical (no drift, no undocumented
/// binding).
pub const bindings = [_]Binding{
    // ── actor: the per-behavior `self` surface ──────────────────────────────
    .{
        .name = "actor.get_position",
        .module = "actor",
        .signature = "get_position(self) -> number, number",
        .summary = "World-space position of this actor as x, y.",
        .params = &.{.{ .name = "self", .kind = .actor }},
        .returns = "x, y in world units.",
        .example =
        \\local x, y = self:get_position()
        \\log.info("player at " .. x .. ", " .. y)
        ,
    },
    .{
        .name = "actor.set_position",
        .module = "actor",
        .signature = "set_position(self, x, y)",
        .summary = "Sets the world-space position of this actor.",
        .params = &.{
            .{ .name = "self", .kind = .actor },
            .{ .name = "x", .kind = .number },
            .{ .name = "y", .kind = .number },
        },
        .example =
        \\self:set_position(100, 200)
        ,
    },
    .{
        .name = "actor.translate",
        .module = "actor",
        .signature = "translate(self, dx, dy)",
        .summary = "Moves the actor by a delta, relative to its current position.",
        .params = &.{
            .{ .name = "self", .kind = .actor },
            .{ .name = "dx", .kind = .number },
            .{ .name = "dy", .kind = .number },
        },
        .example =
        \\-- move right by 5 units this frame
        \\self:translate(5, 0)
        ,
    },
    .{
        .name = "actor.get_rotation",
        .module = "actor",
        .signature = "get_rotation(self) -> number",
        .summary = "Rotation of this actor in radians (clockwise on screen).",
        .params = &.{.{ .name = "self", .kind = .actor }},
        .returns = "angle in radians.",
        .example =
        \\local angle = self:get_rotation()
        ,
    },
    .{
        .name = "actor.set_rotation",
        .module = "actor",
        .signature = "set_rotation(self, radians)",
        .summary = "Sets the rotation of this actor in radians.",
        .params = &.{
            .{ .name = "self", .kind = .actor },
            .{ .name = "radians", .kind = .number },
        },
        .example =
        \\self:set_rotation(math.pi / 2)  -- quarter turn
        ,
    },
    .{
        .name = "actor.get_name",
        .module = "actor",
        .signature = "get_name(self) -> string",
        .summary = "The display name of this actor (empty string if unnamed).",
        .params = &.{.{ .name = "self", .kind = .actor }},
        .returns = "the actor name.",
        .example =
        \\if self:get_name() == "player" then log.info("hi!") end
        ,
    },
    .{
        .name = "actor.emit",
        .module = "actor",
        .signature = "emit(self, event)",
        .summary = "Emits a signal from this actor; on_signal handlers fire next drain.",
        .params = &.{
            .{ .name = "self", .kind = .actor },
            .{ .name = "event", .kind = .string },
        },
        .example =
        \\self:emit("died")
        ,
    },

    // ── input: action-based, remappable (ROADMAP M3) ────────────────────────
    .{
        .name = "input.is_action_pressed",
        .module = "input",
        .signature = "is_action_pressed(action) -> boolean",
        .summary = "True only on the frame the action went down (edge, no repeat).",
        .params = &.{.{ .name = "action", .kind = .string }},
        .returns = "true on the press frame.",
        .example =
        \\if input.is_action_pressed("jump") then self:emit("jumped") end
        ,
    },
    .{
        .name = "input.is_action_down",
        .module = "input",
        .signature = "is_action_down(action) -> boolean",
        .summary = "True while the action is held (including repeats).",
        .params = &.{.{ .name = "action", .kind = .string }},
        .returns = "true while held.",
        .example =
        \\if input.is_action_down("move_right") then self:translate(3, 0) end
        ,
    },
    .{
        .name = "input.get_axis",
        .module = "input",
        .signature = "get_axis(negative, positive) -> number",
        .summary = "Signed axis in [-1, 1] from two opposing actions (e.g. left/right).",
        .params = &.{
            .{ .name = "negative", .kind = .string },
            .{ .name = "positive", .kind = .string },
        },
        .returns = "-1, 0 or 1 (or between for analog devices).",
        .example =
        \\local dx = input.get_axis("move_left", "move_right")
        \\self:translate(dx * 4, 0)
        ,
    },

    // ── log: the whitelisted print sink ─────────────────────────────────────
    .{
        .name = "log.info",
        .module = "log",
        .signature = "log.info(message)",
        .summary = "Writes an info line to the engine log (the console panel).",
        .params = &.{.{ .name = "message", .kind = .string }},
        .example =
        \\log.info("hello from Lua")
        ,
    },
    .{
        .name = "log.warn",
        .module = "log",
        .signature = "log.warn(message)",
        .summary = "Writes a warning line to the engine log.",
        .params = &.{.{ .name = "message", .kind = .string }},
        .example =
        \\log.warn("health is low")
        ,
    },
};

// ── Comptime validation (the "no metadata → does not merge" gate) ────────────

// Fails to compile if the registry itself is malformed: a duplicate name, a
// missing summary, or a missing example. Runs at comptime, so a bad entry is
// caught the moment the file is compiled, not at runtime.
comptime {
    for (bindings, 0..) |b, i| {
        if (b.summary.len == 0)
            @compileError("binding '" ++ b.name ++ "' has no summary");
        if (b.example.len == 0)
            @compileError("binding '" ++ b.name ++ "' has no example");
        if (b.signature.len == 0)
            @compileError("binding '" ++ b.name ++ "' has no signature");
        for (bindings[i + 1 ..]) |other| {
            if (std.mem.eql(u8, b.name, other.name))
                @compileError("duplicate binding name: " ++ b.name);
        }
    }
}

/// Given the list of C-function names a module actually registers, asserts at
/// comptime that every one is documented here and, symmetrically, that no
/// metadata entry is left unregistered. This is the mechanical form of "no
/// metadata → the binding does not merge": `bindings.zig` calls this with its
/// own names, so drift between the two is a compile error.
pub fn assertAllDocumented(comptime registered: []const []const u8) void {
    comptime {
        for (registered) |name| {
            if (find(name) == null)
                @compileError("binding '" ++ name ++ "' is registered but has no metadata entry (add it to metadata.bindings)");
        }
        // And the reverse: a metadata entry with no registration is dead weight.
        for (bindings) |b| {
            var found = false;
            for (registered) |name| {
                if (std.mem.eql(u8, name, b.name)) found = true;
            }
            if (!found)
                @compileError("metadata for '" ++ b.name ++ "' has no registered binding (remove it or register the function)");
        }
    }
}

/// Runtime lookup by fully-qualified name (for the help panel / autocomplete).
pub fn find(name: []const u8) ?*const Binding {
    for (&bindings) |*b| {
        if (std.mem.eql(u8, b.name, name)) return b;
    }
    return null;
}

/// True when `name` is documented (used by the stub generator's sanity check).
pub fn isDocumented(name: []const u8) bool {
    return find(name) != null;
}

test "every binding has a summary and an example" {
    // The comptime block above already guarantees this at compile time; the
    // test makes the invariant explicit and fails loudly if it ever regresses.
    for (bindings) |b| {
        try std.testing.expect(b.summary.len > 0);
        try std.testing.expect(b.example.len > 0);
        try std.testing.expect(b.signature.len > 0);
    }
}

test "find resolves a fully-qualified name" {
    const b = find("actor.get_position").?;
    try std.testing.expectEqualStrings("actor", b.module);
    try std.testing.expectEqual(@as(usize, 1), b.params.len);
    try std.testing.expectEqualStrings("self", b.params[0].name);
    try std.testing.expect(find("nope.nope") == null);
}

test "assertAllDocumented accepts the exact registry" {
    // Build the name list at comptime from the registry (the identity case the
    // real registration uses): it must pass, proving the gate accepts a registry
    // that matches itself.
    const names = comptime blk: {
        var arr: [bindings.len][]const u8 = undefined;
        for (bindings, &arr) |b, *n| n.* = b.name;
        break :blk arr;
    };
    assertAllDocumented(&names);
}

