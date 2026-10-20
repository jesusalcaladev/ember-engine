//! Setting a component's fields from Lua.
//!
//! `actor.add_component(self, "Sprite")` adds the component with its
//! DEFAULTS. That is not enough: a sprite of 40x32 in red is not the default
//! sprite, and a game that has to add a component and then poke at each field
//! through a different call is a game nobody enjoys writing.
//!
//! So the fields can come WITH the component:
//!
//! ```lua
//! actor.add_component(self, "Sprite", {
//!   size = { x = 40, y = 32 },
//!   tint = { r = 1, g = 0, b = 0, a = 1 },
//!   layer = 3,
//!   blend = "additive",
//! })
//! ```
//!
//! ## How a Lua value becomes a field
//!
//! The rule is the same one the `.zson` format uses, because the same developer
//! is typing both:
//!
//! | Field type | The Lua value |
//! |---|---|
//! | a number | a number |
//! | a bool | a bool |
//! | `Vec2` | `{ x = .., y = .. }` |
//! | `[4]f32` (a colour) | `{ r = .., g = .., b = .., a = .. }` or `{ r, g, b, a }` |
//! | a name (`Name`, `InlineText`) | `{ value = "the text" }` |
//! | an enum | its NAME: `"alpha"`, `"additive"`, `"center"` |
//! | a struct (`UiLayout`) | a table of its own fields, recursively |
//!
//! An enum by its NAME and not by its number is the important one: the numbers
//! are an implementation detail that changes when a value is inserted into the
//! enum, and a scene that said `blend: 2` would silently become a different
//! blend.

const std = @import("std");
const lua = @import("luajit.zig");
const ecs = @import("ecs");
const core = @import("core");

const components = ecs.components;
const core_math = core.math;
const core_log = core.log.scoped("lua");

/// The component's fields, set from a Lua table.
///
/// A field the table does not mention keeps its default, and a key that is not
/// a field of the component is IGNORED — a typo in a field name should not take
/// the whole call down, but it should be visible, so it is reported.
pub fn applyFields(comptime T: type, dst: *T, L: ?*lua.lua_State, idx: c_int) void {
    if (!lua.isTable(L, idx)) return;
    // ABSOLUTE, because the walk below pushes and pops: a relative index
    // would mean a different slot by the time it is used, and `lua_next` with
    // the wrong slot is a crash, not a wrong value.
    const table = lua.absIndex(L, idx);

    // A name-like component IS a string: `{ value = "player" }`.
    if (T == components.Name or T == components.InlineText) {
        applyText(T, dst, L, idx);
        return;
    }

    // `lua_next` is the only way to walk a table's pairs: the keys are not
    // reachable by index.
    lua.pushNil(L); // [nil]
    while (lua.lua_next(L, table) != 0) { // [key, value]
        const key = lua.toString(L, -2);
        if (!setFieldByName(T, dst, key, L, -1)) {
            core_log.warn("component field: '{s}' is not a field of this component", .{key});
        }
        lua.pop(L, 1); // pop the value, keep the key for the next `next`
    }
    // NO extra pop: `lua_next` pops the key itself when the table is done,
    // and popping again would take the CALLER's stack with it.
}

/// Sets the field of that name, if the component has one.
fn setFieldByName(comptime T: type, dst: *T, key: []const u8, L: ?*lua.lua_State, idx: c_int) bool {
    inline for (@typeInfo(T).@"struct".fields) |f| {
        if (std.mem.eql(u8, f.name, key)) {
            const slot = &@field(dst, f.name);
            setValue(f.type, slot, L, idx);
            return true;
        }
    }
    return false;
}

/// A name-like component, set from `{ value = "..." }` (or `{ text = "..." }`).
fn applyText(comptime T: type, dst: *T, L: ?*lua.lua_State, idx: c_int) void {
    inline for (.{ "value", "text" }) |key| {
        lua.getField(L, idx, key);
        if (lua.isString(L, -1)) {
            dst.set(lua.toString(L, -1));
            lua.pop(L, 1);
            return;
        }
        lua.pop(L, 1);
    }
}

/// Writes one Lua value into one field.
fn setValue(comptime F: type, dst: *F, L: ?*lua.lua_State, idx: c_int) void {
    const info = @typeInfo(F);
    // ABSOLUTE: the readers below push onto the stack, and a relative index
    // would start pointing at what they pushed.
    const value = lua.absIndex(L, idx);
    switch (info) {
        .float => dst.* = switch (F) {
            f32 => @floatCast(lua.toF32(L, value)),
            f64 => lua.toF32(L, value),
            else => @compileError("unsupported float width"),
        },
        .int => {
            // A Lua number is a double, so a whole number is the intent and
            // the fraction is dropped. The value is CLAMPED to the field's
            // range: a `u8` layer of 300 is a mistake, and 300 does not fit in
            // a u8, so the alternative is a panic in the middle of a frame.
            const raw = lua.toF32(L, value);
            const as_int: i64 = @intFromFloat(@round(raw));
            dst.* = switch (F) {
                u8 => @intCast(@max(0, @min(255, as_int))),
                u16 => @intCast(@max(0, @min(65535, as_int))),
                u32 => @intCast(@max(0, @as(i64, @min(4294967295, @as(u32, @truncate(@as(u64, @intCast(as_int)))))))),
                i32 => @intCast(@max(-2147483648, @min(2147483647, as_int))),
                i64 => as_int,
                u64 => @intCast(@max(0, as_int)),
                else => @compileError("unsupported int width"),
            };
        },
        .bool => dst.* = lua.toBool(L, value),
        .@"enum" => {
            // By NAME. The numbers are an implementation detail, and a scene
            // that said `blend: 2` would silently become a different blend.
            if (lua.isString(L, value)) {
                const name = lua.toString(L, value);
                if (!setEnumByName(F, dst, name)) {
                    core_log.warn("component field: '{s}' is not a value of this enum", .{name});
                }
            }
        },
        .array => {
            if (F == [4]f32) {
                setColour(dst, L, value);
            }
        },
        .@"struct" => {
            if (F == core_math.Vec2) {
                setVec2(dst, L, value);
            } else if (F == components.Name or F == components.InlineText) {
                // A name-like FIELD takes the string itself: `text = "Score"`.
                if (lua.isString(L, value)) dst.set(lua.toString(L, value));
            } else if (F == ecs.Entity) {
                // An entity handle is opaque: there is no number a developer
                // could type that would mean "that entity". The handle comes
                // from `actor.find_by_name`, not from a literal.
            } else {
                // A plain struct: its own fields, recursively.
                applyFields(F, dst, L, value);
            }
        },
        else => {},
    }
}

/// A `Vec2` from `{ x = .., y = .. }` — or from a single number, which means
/// "the same in both".
fn setVec2(dst: *core_math.Vec2, L: ?*lua.lua_State, idx: c_int) void {
    if (lua.isTable(L, idx)) {
        lua.getField(L, idx, "x");
        if (lua.isNumber(L, -1)) dst.x = lua.toF32(L, -1);
        lua.pop(L, 1);
        lua.getField(L, idx, "y");
        if (lua.isNumber(L, -1)) dst.y = lua.toF32(L, -1);
        lua.pop(L, 1);
    } else if (lua.isNumber(L, idx)) {
        const s = lua.toF32(L, idx);
        dst.* = .{ .x = s, .y = s };
    }
}

/// A colour from `{ r = .., g = .., b = .., a = .. }` or from `{ r, g, b, a }`.
///
/// The positional form is the `.zson` form (`tint: [0.2, 0.6, 1, 1]`), and the
/// named form is the one a human types. Both are accepted because a
/// developer who has just written the scene file is thinking in the first one
/// and a developer who has just written the inspector is thinking in the
/// second.
fn setColour(dst: *[4]f32, L: ?*lua.lua_State, idx: c_int) void {
    if (!lua.isTable(L, idx)) {
        if (lua.isNumber(L, idx)) {
            const g = lua.toF32(L, idx);
            dst.* = .{ g, g, g, g };
        }
        return;
    }
    var c: [4]f32 = .{ 1, 1, 1, 1 };
    // The named form.
    inline for (.{ "r", "g", "b", "a" }, 0..) |key, i| {
        lua.getField(L, idx, key);
        if (lua.isNumber(L, -1)) c[i] = lua.toF32(L, -1);
        lua.pop(L, 1);
    }
    // The positional form, for the components whose values did not match.
    const n = lua.lua_objlen(L, idx);
    var i: c_int = 1;
    while (i <= n and i <= 4) : (i += 1) {
        lua.lua_rawgeti(L, idx, i);
        if (lua.isNumber(L, -1)) c[@intCast(i - 1)] = lua.toF32(L, -1);
        lua.pop(L, 1);
    }
    dst.* = c;
}

/// Sets an enum from the NAME of one of its values.
fn setEnumByName(comptime E: type, dst: *E, name: []const u8) bool {
    inline for (@typeInfo(E).@"enum".fields) |f| {
        if (std.mem.eql(u8, f.name, name)) {
            dst.* = @enumFromInt(f.value);
            return true;
        }
    }
    return false;
}

/// The components a script may add at runtime, with their VALUES.
///
/// The list is not every registered component, and the omissions are
/// deliberate: a component a SYSTEM owns (a collider, a rigid body) is wired
/// into that system when the scene loads, and a half-added one — a collider the
/// solver does not know about — is worse than none. So the list holds the
/// components that are PLAIN DATA: they can appear at any moment and the
/// systems that read them will see them on the next frame.
pub const addable_components = [_]struct { name: []const u8, T: type }{
    .{ .name = "Sprite", .T = components.Sprite },
    .{ .name = "CollisionLayers", .T = components.CollisionLayers },
    .{ .name = "Name", .T = components.Name },
    .{ .name = "SoundEmitter2D", .T = components.SoundEmitter2D },
    // M14: the UI widgets are plain data too. Adding one starts from the
    // component defaults (a 100x30 top-left box), which `ui.*` then styles.
    .{ .name = "UiCanvas", .T = components.UiCanvas },
    .{ .name = "Label", .T = components.Label },
    .{ .name = "UiButton", .T = components.UiButton },
    .{ .name = "UiPanel", .T = components.UiPanel },
    .{ .name = "UiProgressBar", .T = components.UiProgressBar },
    .{ .name = "Timer", .T = components.Timer },
    .{ .name = "Camera2D", .T = components.Camera2D },
    .{ .name = "Velocity", .T = components.Velocity },
};

/// Reserves the archetypes `actor.add_component` will need.
///
/// Adding a component to an actor that does not have it yet means a NEW
/// archetype, and a new archetype is an ALLOCATION — and the frame is not
/// allowed to allocate (spec §3.1). So the runtime reserves the shapes a
/// script can produce AT LOAD TIME: the spawned actor's set plus one
/// component, with and without the behavior.
///
/// The reserve is deliberately modest: a hundred and twenty-eight rows is
/// plenty for the widgets a game builds at runtime, and the columns are the
/// component's own size.
pub fn reserveAddable(world: *ecs.World, n: usize) !void {
    inline for (addable_components) |ac| {
        // The spawned actor already HAS a name, so the "Name" row is the same
        // archetype twice — and the world rejects a list with a component in
        // it twice.
        if (ac.T == components.Name) continue;
        try world.reserve(.{ components.Transform, components.Name, ac.T }, n);
        try world.reserve(.{ components.Transform, components.Name, components.Script, ac.T }, n);
    }
}
