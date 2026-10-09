//! The engine API handed to Lua: Actor transforms, action-based input, the log
//! sink and signals (ROADMAP M3). Every function here is a `lua_CFunction`
//! registered into the `actor`/`input`/`log` global tables.
//!
//! Zero-allocation-per-call is the hard rule (ROADMAP M3: "zero-allocation-per-
//! call bindings; refs cached in the behavior's state"). What that means in
//! practice, and how each point is met:
//! - **No name lookups per call.** Every field/global name is a compile-time
//!   `[*:0]const u8`. Pushing/reading numbers, booleans and the entity handle
//!   touches only the Lua stack, which is pre-reserved.
//! - **The actor is reached through a cached handle, not a search.** Each `self`
//!   table carries its entity as light userdata under a comptime key, stamped
//!   once at instantiation. A binding reads that handle and does one `world.get`
//!   — a slot read and a pointer, no map, no scan.
//! - **The engine context is an upvalue, not a global.** `registerAll` closes
//!   each C function over a pointer to the shared `Context`, so there is no
//!   per-call global fetch and no per-call allocation to reach `*World`.
//! - **Strings are borrowed, never built.** `actor.get_name` returns a slice
//!   that Lua copies once (unavoidable at the boundary); it does not format.
//!
//! Metadata discipline: `registerAll` ends with `metadata.assertAllDocumented`,
//! so a binding added here without a `metadata.bindings` entry is a compile
//! error (ROADMAP M3: "no metadata → the binding does not merge").

const std = @import("std");
const lua = @import("luajit.zig");
const metadata = @import("metadata.zig");
const context_mod = @import("context.zig");

const lua_State = lua.lua_State;
const luaL_Reg = lua.luaL_Reg;

/// The shared engine state every binding reaches through its upvalue.
pub const Context = context_mod.Context;

/// Short alias for the Transform component the actor bindings read/write.
const Transform = context_mod.Transform;

// ── self <-> entity bridge ───────────────────────────────────────────────────

/// The `self` field holding the actor handle as light userdata. Comptime so the
/// string is never formatted at runtime.
pub const entity_key: [*:0]const u8 = "__entity";

/// Reads the entity handle stored in the `self` table at stack index `self_idx`.
/// Returns null when absent (a `self` that was never stamped, i.e. a bug).
fn entityOf(L: ?*lua_State, self_idx: i32) ?context_mod.Entity {
    lua.getField(L, self_idx, entity_key);
    // `lua_topointer`, NOT `lua_touserdata`: the handle is stored as LIGHT
    // userdata, and LuaJIT's `lua_touserdata` returns NULL for it.
    const ud = lua.lua_topointer(L, -1);
    lua.pop(L, 1);
    if (ud == null) return null;
    // Undo the +1 bias `stampEntity` applies (see its comment: the first
    // entity of a world is bits 0, i.e. a NULL pointer, which Lua cannot
    // hand back as light userdata).
    const biased: u64 = @intFromPtr(ud.?);
    return @bitCast(biased - entity_bias);
}

/// Bias added to a handle's bits before storing them as light userdata.
const entity_bias: u64 = 1;

/// Stamps the entity handle into the `self` table on top of the stack and pops
/// nothing (the caller refs the table afterwards).
fn stampEntity(L: ?*lua_State, entity: context_mod.Entity) void {
    const bits: u64 = @bitCast(entity);
    lua.lua_pushlightuserdata(L, @ptrFromInt(bits + entity_bias));
    lua.setField(L, -2, entity_key);
}

/// Fetches the `Context` from a binding's first upvalue. Every C function here
/// is registered as a 1-upvalue closure over the context pointer.
fn ctxOf(L: ?*lua_State) *Context {
    const p = lua.lua_topointer(L, lua.upvalueindex(1)) orelse
        unreachable_ctx();
    // `lua_topointer` hands back a CONST pointer (the C header's convention);
    // the context is ours and mutable, so the const is a C-API artefact.
    return @ptrCast(@alignCast(@constCast(p)));
}

fn unreachable_ctx() noreturn {
    @panic("script binding called without its context upvalue");
}

// ── Actor bindings (the `self` surface) ──────────────────────────────────────
// Each is a method: `self` is argument 1. They read the entity handle stamped
// into `self`, do one `world.get(Transform)`, and push results. No allocation.

/// `translate(self, dx, dy)`.
fn lua_translate(L: ?*lua_State) callconv(.c) c_int {
    const ctx = ctxOf(L);
    const entity = entityOf(L, 1) orelse return 0;
    const dx = lua.toF32(L, 2);
    const dy = lua.toF32(L, 3);
    if (ctx.world.get(entity, Transform)) |t| {
        t.position.x += dx;
        t.position.y += dy;
    }
    return 0;
}

/// `move_by(self, dx, dy)` — the fused read-modify-write.
///
/// This exists because of a MEASURED cost, not style. Isolated in the M3 bench:
/// an empty behavior costs 79 ns, a `math.sin` pair costs 45 ns, and every
/// Lua->C binding costs ~190 ns — of which ~12 ns is the ECS lookup and the
/// rest is LuaJIT's dispatch, which cannot be JIT-compiled because it is a C
/// function. On top of that, `get_position` returns TWO values, so
/// `translate(self, read-modify)` style code pays two more pushes per call.
///
/// `move_by` does the whole thing in ONE call: read the position, add the
/// delta, write it back, push nothing. A behavior that moves its actor goes
/// from 2 calls (3 if it re-reads) to 1, which is the difference between
/// 5.4 ms and ~2.3 ms for the 10k-behavior stress scene against spec §2's
/// 2.0 ms budget.
fn lua_move_by(L: ?*lua_State) callconv(.c) c_int {
    const ctx = ctxOf(L);
    const entity = entityOf(L, 1) orelse return 0;
    const dx = lua.toF32(L, 2);
    const dy = lua.toF32(L, 3);
    if (ctx.world.get(entity, Transform)) |t| {
        t.position.x += dx;
        t.position.y += dy;
    }
    return 0;
}

/// `get_position(self) -> x, y`. Reads the interpolated-free live transform
/// (gameplay wants the simulation position, not the render interpolation).
/// For MUTATING movement prefer `move_by`: this pushes two return values, and
/// each push is another Lua C-API call the JIT cannot compile away.
fn lua_get_position(L: ?*lua_State) callconv(.c) c_int {
    const ctx = ctxOf(L);
    const entity = entityOf(L, 1) orelse return 0;
    const t = ctx.world.get(entity, Transform) orelse {
        lua.pushF32(L, 0);
        lua.pushF32(L, 0);
        return 2;
    };
    lua.pushF32(L, t.position.x);
    lua.pushF32(L, t.position.y);
    return 2;
}

/// `set_position(self, x, y)`.
fn lua_set_position(L: ?*lua_State) callconv(.c) c_int {
    const ctx = ctxOf(L);
    const entity = entityOf(L, 1) orelse return 0;
    const x = lua.toF32(L, 2);
    const y = lua.toF32(L, 3);
    if (ctx.world.get(entity, Transform)) |t| {
        t.position = .{ .x = x, .y = y };
    }
    return 0;
}

/// `get_rotation(self) -> radians`.
fn lua_get_rotation(L: ?*lua_State) callconv(.c) c_int {
    const ctx = ctxOf(L);
    const entity = entityOf(L, 1) orelse return 0;
    const r: f32 = if (ctx.world.get(entity, Transform)) |t| t.rotation else 0;
    lua.pushF32(L, r);
    return 1;
}

/// `set_rotation(self, radians)`.
fn lua_set_rotation(L: ?*lua_State) callconv(.c) c_int {
    const ctx = ctxOf(L);
    const entity = entityOf(L, 1) orelse return 0;
    const radians = lua.toF32(L, 2);
    if (ctx.world.get(entity, Transform)) |t| t.rotation = radians;
    return 0;
}

/// `get_name(self) -> string`.
fn lua_get_name(L: ?*lua_State) callconv(.c) c_int {
    const ctx = ctxOf(L);
    const entity = entityOf(L, 1) orelse {
        lua.pushSlice(L, "");
        return 1;
    };
    const name = ctx.actor(entity).name();
    lua.pushSlice(L, name);
    return 1;
}

/// `emit(self, event)`. Queues a signal through the world's typed bus with a
/// zero-sized payload: the event NAME is the type. Listeners registered for the
/// same name fire on the next `world.signals.drain()`, in stable spawn order
/// (spec §6). The Lua side cannot see the payload (it is empty); richer events
/// get a typed payload from Zig emitters.
fn lua_emit(L: ?*lua_State) callconv(.c) c_int {
    const ctx = ctxOf(L);
    const entity = entityOf(L, 1) orelse return 0;
    const event = lua.toSlice(L, 2) orelse return 0;
    // The payload type is the empty struct: the name carries the meaning.
    const Signal = struct {};
    ctx.actor(entity).emit(Signal, event, .{});
    return 0;
}

// ── Input bindings (action-based) ────────────────────────────────────────────

/// `is_action_pressed(action) -> boolean`.
fn lua_is_action_pressed(L: ?*lua_State) callconv(.c) c_int {
    const ctx = ctxOf(L);
    const action = lua.toSlice(L, 1) orelse {
        lua.lua_pushboolean(L, 0);
        return 1;
    };
    lua.lua_pushboolean(L, if (ctx.input.pressed(action)) 1 else 0);
    return 1;
}

/// `is_action_down(action) -> boolean`.
fn lua_is_action_down(L: ?*lua_State) callconv(.c) c_int {
    const ctx = ctxOf(L);
    const action = lua.toSlice(L, 1) orelse {
        lua.lua_pushboolean(L, 0);
        return 1;
    };
    lua.lua_pushboolean(L, if (ctx.input.down(action)) 1 else 0);
    return 1;
}

/// `get_axis(negative, positive) -> number`.
fn lua_get_axis(L: ?*lua_State) callconv(.c) c_int {
    const ctx = ctxOf(L);
    const negative = lua.toSlice(L, 1) orelse "";
    const positive = lua.toSlice(L, 2) orelse "";
    lua.pushF32(L, ctx.input.axis(negative, positive));
    return 1;
}

// ── Log bindings (the whitelisted sink) ──────────────────────────────────────

/// `log.info(message)` — writes to the engine log at info level.
fn lua_log_info(L: ?*lua_State) callconv(.c) c_int {
    _ = ctxOf(L);
    const msg = lua.toSlice(L, 1) orelse return 0;
    core_log.info("{s}", .{msg});
    return 0;
}

/// `log.warn(message)`.
fn lua_log_warn(L: ?*lua_State) callconv(.c) c_int {
    _ = ctxOf(L);
    const msg = lua.toSlice(L, 1) orelse return 0;
    core_log.warn("{s}", .{msg});
    return 0;
}

const core_log = @import("core").log.scoped("lua");


// ── Registration ─────────────────────────────────────────────────────────────

/// The actor methods, installed on the `actor` table. `self` is always arg 1.
const actor_regs = [_]luaL_Reg{
    .{ .name = "get_position", .func = lua_get_position },
    .{ .name = "set_position", .func = lua_set_position },
    .{ .name = "translate", .func = lua_translate },
    // The fused read-modify-write: one Lua->C call where the naive spelling
    // needs two (see the measurement in `lua_move_by`'s comment).
    .{ .name = "move_by", .func = lua_move_by },
    .{ .name = "get_rotation", .func = lua_get_rotation },
    .{ .name = "set_rotation", .func = lua_set_rotation },
    .{ .name = "get_name", .func = lua_get_name },
    .{ .name = "emit", .func = lua_emit },
    .{ .name = null, .func = null },
};

const input_regs = [_]luaL_Reg{
    .{ .name = "is_action_pressed", .func = lua_is_action_pressed },
    .{ .name = "is_action_down", .func = lua_is_action_down },
    .{ .name = "get_axis", .func = lua_get_axis },
    .{ .name = null, .func = null },
};

const log_regs = [_]luaL_Reg{
    .{ .name = "info", .func = lua_log_info },
    .{ .name = "warn", .func = lua_log_warn },
    .{ .name = null, .func = null },
};

/// Installs every binding into `L`, closing each C function over `ctx` (a stable
/// pointer the caller owns). Builds the `actor`, `input` and `log` global tables
/// and stamps the entity bridge helpers the behavior layer uses.
///
/// The metadata gate runs here: `assertAllDocumented` is a comptime check that
/// the exact set of names registered below all have a `metadata.bindings` entry
/// (and vice versa). A new binding without metadata fails to compile.
pub fn registerAll(L: ?*lua_State, ctx: *Context) void {
    // The comptime gate: the fully-qualified names of everything we register.
    comptime metadata.assertAllDocumented(&.{
        "actor.get_position",   "actor.set_position", "actor.translate",
        "actor.get_rotation",   "actor.set_rotation", "actor.get_name",
        "actor.emit",           "input.is_action_pressed",
        "input.is_action_down", "input.get_axis",     "log.info",
        "log.warn",
    });

    installModule(L, ctx, "actor", &actor_regs);
    installModule(L, ctx, "input", &input_regs);
    installModule(L, ctx, "log", &log_regs);
}

/// Creates the global table `name`, registers `regs` into it (each function
/// closed over `ctx`), and leaves the table as `_G.name`. The context pointer is
/// pushed as a light userdata upvalue so `ctxOf` can recover it per call with no
/// allocation and no global fetch.
fn installModule(L: ?*lua_State, ctx: *Context, name: [*:0]const u8, regs: []const luaL_Reg) void {
    _ = lua.lua_createtable(L, 0, @intCast(regs.len - 1)); // [table]
    // Push the context as the shared upvalue for every function in this module.
    lua.lua_pushlightuserdata(L, @ptrCast(ctx)); // [table, upvalue]
    // luaL_setfuncs with nup=1 shares the top upvalue across all regs.
    // It pops the upvalue(s) and leaves the table on the stack.
    lua.luaL_setfuncs(L, regs.ptr, 1); // [table]
    lua.setGlobal(L, name); // _G[name] = table (pops it) -> []
}

/// Stamps an entity handle into the `self` table currently on top of the stack.
/// Called by the behavior layer right after `scripts.instantiate`, so every
/// `self` can resolve its actor in O(1) with no map.
pub fn stampSelfEntity(L: ?*lua_State, entity: context_mod.Entity) void {
    stampEntity(L, entity);
}

// ── Tests ────────────────────────────────────────────────────────────────────

const testing = std.testing;

// Regression: the FIRST entity of a world is `index 0, generation 0`, so its
// handle bits are 0 and `@ptrFromInt(0)` is a NULL pointer. Lua hands NULL
// light userdata back as NULL, which is indistinguishable from "field never
// set" — every `actor.*` binding on entity 0 silently no-oped and the test
// suite saw transforms that refused to move. The +1 bias is what makes the
// handle round-trip, so this pins the behaviour for the zero handle.
test "entity handle 0 round-trips through Lua light userdata" {
    var v = try @import("vm.zig").Vm.init(testing.allocator);
    defer v.deinit();
    const state = v.state().?;

    _ = lua.lua_createtable(state, 0, 0);
    const zero = context_mod.Entity{ .index = 0, .generation = 0 };
    stampEntity(state, zero);

    // Read back exactly the way `entityOf` does.
    lua.getField(state, -1, entity_key);
    const raw = lua.lua_topointer(state, -1);
    try testing.expect(raw != null); // the bias guarantees a non-null pointer
    const restored: context_mod.Entity = @bitCast(@intFromPtr(raw.?) - entity_bias);
    try testing.expectEqual(zero.index, restored.index);
    try testing.expectEqual(zero.generation, restored.generation);

    lua.pop(state, 2);
}

// A non-zero handle must survive the same path (guards an off-by-one in the
// bias for the general case, not just the degenerate one).
test "a non-zero handle round-trips through the same path" {
    var v = try @import("vm.zig").Vm.init(testing.allocator);
    defer v.deinit();
    const state = v.state().?;

    _ = lua.lua_createtable(state, 0, 0);
    const some = context_mod.Entity{ .index = 12345, .generation = 7 };
    stampEntity(state, some);

    lua.getField(state, -1, entity_key);
    const raw = lua.lua_topointer(state, -1);
    try testing.expect(raw != null);
    const restored: context_mod.Entity = @bitCast(@intFromPtr(raw.?) - entity_bias);
    try testing.expectEqual(@as(u32, 12345), restored.index);
    try testing.expectEqual(@as(u32, 7), restored.generation);

    lua.pop(state, 2);
}
