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
/// And for the Sprite, which `get_half_size` reads (the collision-style half
/// extents of what is drawn).
const Sprite = context_mod.components.Sprite;
const ShaderMaterial = context_mod.components.ShaderMaterial;

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
pub const ContextFromUpvalue = @TypeOf(ctxOf);
pub fn ctxFromUpvalue(L: ?*lua_State) *Context {
    return ctxOf(L);
}

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

// ── actor: spatial queries between actors ───────────────────────────────────
//
// The point of these (rather than making Lua do `get_position` twice and
// `vec2.dist` on the results) is that one of them costs ONE C call instead of
// three, and the pair of `world.get` lookups happens back to back on data that
// is already hot. Measured in the M3 bench: a Lua->C call is ~145 ns, so the
// Godot-style
//     local ax, ay = self:get_position()
//     local bx, by = other:get_position()
//     local d = vec2.dist(ax, ay, bx, by)
// costs 3 calls, while `actor.distance_to(self, other)` costs 1.
//
// All of them take the other actor as another behavior's `self` table — the
// same `__entity` bridge this actor uses, so the pair resolves with one field
// read each and no map.

/// Position of an actor as a Vec2 (or zero when it has no Transform).
fn positionOf(ctx: *Context, entity: context_mod.Entity) m.Vec2 {
    const t = ctx.world.get(entity, Transform) orelse return m.Vec2.zero;
    return t.position;
}

/// `distance_to(self, other) -> number`. World-space distance in the engine's
/// units: pixels by default, whatever `scale` means for the game (the Lua API
/// is unit-agnostic, so "meters" is just a scale the game picks).
fn lua_distance_to(L: ?*lua_State) callconv(.c) c_int {
    const ctx = ctxOf(L);
    const a = entityOf(L, 1) orelse return 1;
    const b = entityOf(L, 2) orelse return 1;
    lua.pushF32(L, m.Vec2.distance(positionOf(ctx, a), positionOf(ctx, b)));
    return 1;
}

/// `distance_to_point(self, x, y) -> number`. Same as `distance_to` but against
/// a bare point (a click, a spawn marker, a waypoint).
fn lua_distance_to_point(L: ?*lua_State) callconv(.c) c_int {
    const ctx = ctxOf(L);
    const a = entityOf(L, 1) orelse return 1;
    const p = m.Vec2{ .x = lua.toF32(L, 2), .y = lua.toF32(L, 3) };
    lua.pushF32(L, m.Vec2.distance(positionOf(ctx, a), p));
    return 1;
}

/// `distance_squared_to(self, other) -> number`. The comparison form: sorting
/// or testing against a radius by SQUARING the radius avoids one sqrt. Prefer
/// this in a loop over many candidates.
fn lua_distance_squared_to(L: ?*lua_State) callconv(.c) c_int {
    const ctx = ctxOf(L);
    const a = entityOf(L, 1) orelse return 1;
    const b = entityOf(L, 2) orelse return 1;
    const d = positionOf(ctx, b).sub(positionOf(ctx, a));
    lua.pushF32(L, d.x * d.x + d.y * d.y);
    return 1;
}

/// `is_within_radius(self, other, radius) -> boolean`. The "is it in range"
/// test, squared on both sides so there is no sqrt at all.
fn lua_is_within_radius(L: ?*lua_State) callconv(.c) c_int {
    const ctx = ctxOf(L);
    const a = entityOf(L, 1) orelse return 1;
    const b = entityOf(L, 2) orelse return 1;
    const r = lua.toF32(L, 3);
    const d = positionOf(ctx, b).sub(positionOf(ctx, a));
    const inside = (d.x * d.x + d.y * d.y) <= (r * r);
    lua.lua_pushboolean(L, @intFromBool(inside));
    return 1;
}

/// `is_within_radius_of_point(self, x, y, radius) -> boolean`.
fn lua_is_within_radius_of_point(L: ?*lua_State) callconv(.c) c_int {
    const ctx = ctxOf(L);
    const a = entityOf(L, 1) orelse return 1;
    const p = m.Vec2{ .x = lua.toF32(L, 2), .y = lua.toF32(L, 3) };
    const r = lua.toF32(L, 4);
    const d = p.sub(positionOf(ctx, a));
    const inside = (d.x * d.x + d.y * d.y) <= (r * r);
    lua.lua_pushboolean(L, @intFromBool(inside));
    return 1;
}

/// `direction_to(self, other) -> x, y`. Unit vector pointing from this actor to
/// the other, as TWO numbers (zero allocation). The zero vector maps to zero,
/// never NaN.
fn lua_direction_to(L: ?*lua_State) callconv(.c) c_int {
    const ctx = ctxOf(L);
    const a = entityOf(L, 1) orelse return 2;
    const b = entityOf(L, 2) orelse return 2;
    const d = positionOf(ctx, b).sub(positionOf(ctx, a)).normalized();
    lua.pushF32(L, d.x);
    lua.pushF32(L, d.y);
    return 2;
}

/// `angle_to(self, other) -> radians`. Signed angle from this actor's +X axis to
/// the other one; positive = clockwise on screen.
fn lua_angle_to(L: ?*lua_State) callconv(.c) c_int {
    const ctx = ctxOf(L);
    const a = entityOf(L, 1) orelse return 1;
    const b = entityOf(L, 2) orelse return 1;
    const from = m.Vec2{ .x = 1, .y = 0 };
    const to = positionOf(ctx, b).sub(positionOf(ctx, a));
    lua.pushF32(L, m.Vec2.angleTo(from, to));
    return 1;
}

/// `get_half_size(self) -> x, y`. Half the sprite's extent, so "is the click on
/// me" is `|x - cx| <= hw and |y - cy| <= hh` with no Rect2 needed.
fn lua_get_half_size(L: ?*lua_State) callconv(.c) c_int {
    const ctx = ctxOf(L);
    const entity = entityOf(L, 1) orelse return 2;
    const sprite = ctx.world.get(entity, Sprite) orelse {
        lua.pushF32(L, 0);
        lua.pushF32(L, 0);
        return 2;
    };
    lua.pushF32(L, sprite.size.x * 0.5);
    lua.pushF32(L, sprite.size.y * 0.5);
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

// ── world.nearby: the spatial query primitive (M4.5) ──────────────────────────
// One primitive, not one per AI behaviour. Flocking, obstacle avoidance, "the
// closest threat", area triggers and squad cohesion are all the same question
// with different consumers, so the engine answers it once.

/// Carries the visitor across the C boundary. The grid's visitor is a plain C
/// function pointer and cannot be a closure, so the pieces it needs travel here.
const NearbyCtx = struct {
    L: ?*lua_State,
    /// The visitor, refed so it survives the protected call below. Set to
    /// `no_self_ref` once the script has raised, which stops the iteration
    /// instead of replaying the same error for every remaining neighbour.
    fn_ref: i32,
    /// The asking actor, excluded from its own results. Compared by ENTITY, not
    /// by ref: two behaviors can share nothing, and the entity is what the grid
    /// actually holds.
    origin: context_mod.Entity,
    /// `Grid.self_refs`, indexed by entity slot.
    slots: []i32,
};

/// Pushes the behaviour `self` table behind entity slot `index` onto the stack.
/// Uses `lua_rawgeti` on the registry directly, because a binding has the
/// `Context` (not the `Vm`) as its upvalue and cannot call `Vm.pushRef`.
fn pushSelfRef(L: ?*lua_State, ref: i32) void {
    lua.lua_rawgeti(L, lua.REGISTRYINDEX, ref);
}

fn visitNearby(vctx: *NearbyCtx, t: *const context_mod.Transform, entity: context_mod.Entity) void {
    if (vctx.fn_ref == spatial_mod.no_self_ref) return;
    const L = vctx.L orelse return;
    if (entity.index == vctx.origin.index and entity.generation == vctx.origin.generation) return; // never hand an actor its own table
    if (entity.index >= vctx.slots.len) return;
    const ref = vctx.slots[entity.index];
    if (ref == spatial_mod.no_self_ref) return; // no behavior attached

    pushSelfRef(L, ref); // [neighbour_self]
    lua.lua_pushvalue(L, vctx.fn_ref); // [neighbour_self, fn]
    lua.lua_pushvalue(L, -2); // [neighbour_self, fn, neighbour_self]
    // The position comes WITH the neighbour. A visitor that had to call
    // `actor.get_position` would pay a Lua→C binding PER NEIGHBOUR (145 ns,
    // spec §2) — measured, that was the single largest cost in a flocking
    // frame, and it is entirely avoidable.
    lua.pushF32(L, t.position.x); // [.., other_self, ox]
    lua.pushF32(L, t.position.y); // [.., other_self, ox, oy]
    if (lua.lua_pcall(L, 3, 0, 0) != 0) {
        vctx.fn_ref = spatial_mod.no_self_ref;
        return;
    }
}

/// `world.nearby(self, x, y, radius, fn)`: calls `fn(other_self, ox, oy)` for
/// every actor within `radius`, excluding the caller.
///
/// The visitor form rather than returning a list is what keeps spec §10
/// satisfied: materialising an array would allocate per call, and flocking calls
/// this once per agent per frame.
fn lua_world_nearby(L: ?*lua_State) callconv(.c) c_int {
    const ctx = ctxOf(L);
    const grid = ctx.spatial orelse return 0;
    if (!lua.isFunction(L, 5)) return 0;
    const radius = lua.toF32(L, 4);
    if (radius < 0.0) return 0;

    lua.lua_pushvalue(L, 5); // [.., fn]
    const fn_ref: i32 = @intCast(lua.luaL_ref(L, lua.REGISTRYINDEX));
    defer lua.luaL_unref(L, lua.REGISTRYINDEX, fn_ref);

    var vctx = NearbyCtx{
        .L = L,
        .fn_ref = fn_ref,
        .origin = entityOf(L, 1) orelse context_mod.Entity{ .index = std.math.maxInt(u32), .generation = 0 },
        .slots = grid.self_refs,
    };
    grid.forEachInRadius(ctx.world, lua.toF32(L, 2), lua.toF32(L, 3), radius, &vctx, visitNearby);
    return 0;
}

// ── State-machine bindings (ROADMAP M4.5) ───────────────────────────────────
// Methods on `self`, like the `actor` table, because a state machine belongs to
// one actor. The same calls serve an enemy, the player, a spawner or a UI
// screen: only the declaring script differs.
//
// Every failure path returns 0 (nil / false) rather than raising a Lua error.
// A behavior that mis-declares a transition should keep running — it degrades
// to a machine that never leaves its initial state, which is visible and
// debuggable, instead of a frame-killing error in a game that cannot reach a
// console.

/// Stamps `entity` into the `self` table on top of the stack.
///
/// Public because the benchmark and the acceptance suite both have to build a
/// behaviour-shaped `self` table outside the behavior layer, and duplicating
/// the +1 bias convention in two places is how the two would drift.
pub fn stampEntityForTest(L: ?*lua_State, entity: context_mod.Entity) void {
    stampEntity(L, entity);
}

/// Strong-references the table at `idx` into the registry and returns the ref
/// (or `no_ref`). The state machine needs its own ref because it keeps the
/// `self` table alive for as long as the machine is attached — the behavior
/// layer's ref dies with the instance, and a callback firing two frames later
/// would otherwise be calling into a collected table.
fn refTableAt(L: ?*lua_State, idx: c_int) i32 {
    lua.lua_pushvalue(L, idx);
    return @intCast(lua.luaL_ref(L, lua.REGISTRYINDEX));
}

/// The registry, or null when the runtime has none.
fn machinesOf(L: ?*lua_State) ?*statemachine_mod.Registry {
    return ctxOf(L).machines;
}

/// The binding index for `self`'s entity, or null.
fn machineBindingOf(L: ?*lua_State, self_idx: c_int) ?usize {
    const reg = machinesOf(L) orelse return null;
    const entity = entityOf(L, self_idx) orelse return null;
    return reg.bindingFor(entity.index);
}

/// Reads the `self` table of a state callback table into a ref. Absent or
/// non-function fields cache as `no_ref`, so the tick tests one integer.
fn refStateHook(L: ?*lua_State, reg: *statemachine_mod.Registry, table_idx: c_int, name: [*:0]const u8) i32 {
    if (!lua.isTable(L, table_idx)) return statemachine_mod.no_ref;
    lua.getField(L, table_idx, name); // [.., fn_or_nil]
    if (!lua.isFunction(L, -1)) {
        lua.pop(L, 1);
        return statemachine_mod.no_ref;
    }
    return reg.vm.?.refTop();
}

/// `self:sm_add_state(name, hooks)`: declares a state and its optional
/// `{ enter, update, exit }` callbacks, creating this actor's machine on first
/// use.
///
/// The machine is created lazily rather than in a separate `sm_new`: a script
/// that declares zero states has no business owning one, and a separate
/// constructor is one more call to get wrong.
fn lua_sm_add_state(L: ?*lua_State) callconv(.c) c_int {
    const ctx = ctxOf(L);
    const reg = ctx.machines orelse return 0;
    const entity = entityOf(L, 1) orelse return 0;
    const name = lua.toSlice(L, 2) orelse return 0;

    // Reuse the machine this actor already owns, or make one.
    var machine_id: u32 = 0;
    if (reg.bindingFor(entity.index)) |bi| machine_id = reg.bindings[bi].machine;
    if (machine_id == 0) {
        machine_id = reg.createMachine();
        if (machine_id == 0) return 0; // pool exhausted
        const self_ref = refTableAt(L, 1);
        if (self_ref == statemachine_mod.no_ref) return 0;
        _ = reg.attach(machine_id, self_ref) catch return 0;
        ctx.world.add(entity, context_mod.components.StateMachine{ .machine = machine_id }) catch return 0;
    }

    const idx = reg.addState(machine_id, name) catch return 0;
    const st = &reg.machines[machine_id].states[idx];
    st.enter_ref = refStateHook(L, reg, 3, "enter");
    st.update_ref = refStateHook(L, reg, 3, "update");
    st.exit_ref = refStateHook(L, reg, 3, "exit");
    lua.lua_pushboolean(L, 1);
    return 1;
}

/// `self:sm_add_transition(from, event, to)`.
fn lua_sm_add_transition(L: ?*lua_State) callconv(.c) c_int {
    const reg = machinesOf(L) orelse return 0;
    const bi = machineBindingOf(L, 1) orelse return 0;
    const from = lua.toSlice(L, 2) orelse return 0;
    const event = lua.toSlice(L, 3) orelse return 0;
    const to = lua.toSlice(L, 4) orelse return 0;
    reg.addTransition(reg.bindings[bi].machine, from, event, to) catch return 0;
    return 0;
}

/// `self:sm_set_initial(name)`: the state entered on start.
fn lua_sm_set_initial(L: ?*lua_State) callconv(.c) c_int {
    const reg = machinesOf(L) orelse return 0;
    const bi = machineBindingOf(L, 1) orelse return 0;
    const name = lua.toSlice(L, 2) orelse return 0;
    reg.setInitial(reg.bindings[bi].machine, name) catch return 0;
    return 0;
}

/// `self:sm_fire(event)`: requests a transition; it is applied before the next
/// `update`, so firing from inside a callback cannot re-enter the machine.
fn lua_sm_fire(L: ?*lua_State) callconv(.c) c_int {
    const reg = machinesOf(L) orelse return 0;
    const bi = machineBindingOf(L, 1) orelse return 0;
    const event = lua.toSlice(L, 2) orelse return 0;
    reg.fire(bi, event);
    return 0;
}

/// `self:sm_set_state(name)`: jump immediately, running `exit` and `enter`.
fn lua_sm_set_state(L: ?*lua_State) callconv(.c) c_int {
    const reg = machinesOf(L) orelse return 0;
    const bi = machineBindingOf(L, 1) orelse return 0;
    const name = lua.toSlice(L, 2) orelse return 0;
    const idx = reg.stateIndex(reg.bindings[bi].machine, name) orelse return 0;
    reg.setState(bi, idx);
    return 0;
}

/// `self:sm_state() -> string`: the active state, or "" before the first tick.
fn lua_sm_state(L: ?*lua_State) callconv(.c) c_int {
    const reg = machinesOf(L) orelse return 0;
    const bi = machineBindingOf(L, 1) orelse return 0;
    const cur = reg.currentState(bi);
    if (cur == statemachine_mod.Binding.no_state) return 0;
    lua.pushSlice(L, reg.stateName(reg.bindings[bi].machine, cur));
    return 1;
}

/// `self:sm_is_in(name) -> boolean`.
fn lua_sm_is_in(L: ?*lua_State) callconv(.c) c_int {
    const reg = machinesOf(L) orelse return 0;
    const bi = machineBindingOf(L, 1) orelse return 0;
    const name = lua.toSlice(L, 2) orelse return 0;
    const want = reg.stateIndex(reg.bindings[bi].machine, name) orelse return 0;
    const cur = reg.currentState(bi);
    lua.lua_pushboolean(L, @intFromBool(cur == want));
    return 1;
}

const core_log = @import("core").log.scoped("lua");

// ── rand / noise bindings (ROADMAP M4.5) ─────────────────────────────────────
// Both draw from state that lives in the `Context`, never from a module global:
// a global would be shared between two runtimes in the same process (the editor
// and a test, or a preview and the game) and would make the determinism
// contract (spec §6) depend on unrelated code having run first.

// `rand.seed(n)`: restarts the sequence. Deterministic by construction — the
// same seed replays the same draws, which is what makes a bug report
// reproducible ("here is the seed, here is the replay").
fn lua_rand_seed(L: ?*lua_State) callconv(.c) c_int {
    const ctx = ctxOf(L);
    ctx.rng = core_random.Rng.init(toSeed(L, 1));
    return 0;
}

/// `rand.float(lo, hi)`. Both bounds are required: a default of 0..1 would make
/// `rand.float()` silently mean "unit interval" while every caller reading the
/// signature would have to guess.
fn lua_rand_float(L: ?*lua_State) callconv(.c) c_int {
    const ctx = ctxOf(L);
    lua.pushF32(L, ctx.rng.float(lua.toF32(L, 1), lua.toF32(L, 2)));
    return 1;
}

/// `rand.range(lo, hi)`: the Godot/Unity spelling of `rand.float`.
fn lua_rand_range(L: ?*lua_State) callconv(.c) c_int {
    const ctx = ctxOf(L);
    lua.pushF32(L, ctx.rng.float(lua.toF32(L, 1), lua.toF32(L, 2)));
    return 1;
}

/// `rand.int(lo, hi)`, both ends inclusive.
fn lua_rand_int(L: ?*lua_State) callconv(.c) c_int {
    const ctx = ctxOf(L);
    // Clamped rather than trusting the script: the core asserts lo <= hi, and an
    // assertion that a Lua typo can reach would abort the process over a
    // recoverable mistake. Swapping the bounds is the forgiving behaviour every
    // other engine has.
    var lo = toInt(L, 1);
    var hi = toInt(L, 2);
    if (lo > hi) {
        const t = lo;
        lo = hi;
        hi = t;
    }
    pushInt(L, ctx.rng.int(lo, hi));
    return 1;
}

/// `rand.chance(p)`.
fn lua_rand_chance(L: ?*lua_State) callconv(.c) c_int {
    const ctx = ctxOf(L);
    lua.lua_pushboolean(L, @intFromBool(ctx.rng.chance(lua.toF32(L, 1))));
    return 1;
}

/// `rand.sign()`.
fn lua_rand_sign(L: ?*lua_State) callconv(.c) c_int {
    const ctx = ctxOf(L);
    lua.pushF32(L, ctx.rng.sign());
    return 1;
}

/// `rand.gauss(mu, sigma)`.
fn lua_rand_gauss(L: ?*lua_State) callconv(.c) c_int {
    const ctx = ctxOf(L);
    lua.pushF32(L, ctx.rng.gauss(lua.toF32(L, 1), lua.toF32(L, 2)));
    return 1;
}

/// `rand.choice(t)`: one element of an array table, nil when empty.
///
/// Pushed by reference (the element itself), not copied: for a Vec2 or a config
/// table the caller wants the value, and for scalars Lua copies on read anyway.
fn lua_rand_choice(L: ?*lua_State) callconv(.c) c_int {
    const ctx = ctxOf(L);
    if (!lua.isTable(L, 1)) return 0;
    const len = lua.lua_objlen(L, 1);
    const idx = ctx.rng.choiceIndex(len) orelse return 0;
    lua.lua_rawgeti(L, 1, @intCast(idx + 1)); // [t, elem]
    return 1;
}

/// `rand.shuffle(t)`: Fisher-Yates, in place, returns the same table so it can
/// chain (`local deck = rand.shuffle(cards)`).
///
/// Walks high to low, swapping with a draw in `[0, i]` — the high-to-low
/// direction is what makes it unbiased; the naive low-to-high form is not.
fn lua_rand_shuffle(L: ?*lua_State) callconv(.c) c_int {
    const ctx = ctxOf(L);
    if (!lua.isTable(L, 1)) return 0;
    const len = lua.lua_objlen(L, 1);
    if (len < 2) {
        lua.lua_pushvalue(L, 1); // [t, t]
        return 1;
    }
    var i: usize = len;
    while (i > 1) {
        i -= 1;
        const j = ctx.rng.int(0, @intCast(i));
        // t[i+1], t[j+1] = t[j+1], t[i+1]
        lua.lua_rawgeti(L, 1, @intCast(i + 1)); // [t, vi]
        lua.lua_rawgeti(L, 1, @as(c_int, @intCast(j + 1))); // [t, vi, vj]
        lua.lua_rawseti(L, 1, @as(c_int, @intCast(i + 1))); // [t, vi]
        lua.lua_pushvalue(L, -1); // [t, vi, vi]
        lua.lua_rawseti(L, 1, @as(c_int, @intCast(j + 1))); // [t, vi]
        lua.pop(L, 1); // [t]
    }
    lua.lua_pushvalue(L, 1); // [t, t]
    return 1;
}

/// `noise.seed(n)`: sets the seed every later `noise.*` call uses unless it
/// passes one explicitly.
fn lua_noise_seed(L: ?*lua_State) callconv(.c) c_int {
    const ctx = ctxOf(L);
    ctx.noise_seed = toSeed(L, 1);
    return 0;
}

/// The seed argument, when given, else the context default. Lets a script keep
/// two independent fields (terrain vs. weather) without reseeding between calls.
///
/// The `getTop` guard is not defensive padding: probing an index PAST the
/// argument list hands `lua_type` an index the stack does not have, and what it
/// reports for that is whatever happens to be there — a "seed" read out of
/// uninitialised stack is a silent wrong-answer generator, which is exactly the
/// failure this suite caught.
fn noiseSeedFor(L: ?*lua_State, seed_idx: c_int) u64 {
    const ctx = ctxOf(L);
    if (seed_idx > 0 and lua.getTop(L) >= seed_idx and lua.isNumber(L, seed_idx)) {
        return toSeed(L, seed_idx);
    }
    return ctx.noise_seed;
}

// `noise.value(x, y)` / `noise.perlin(x, y)` / `noise.simplex(x, y)`, with an
// optional trailing seed.
fn lua_noise_value(L: ?*lua_State) callconv(.c) c_int {
    lua.pushF32(L, core_noise.value(noiseSeedFor(L, 3), lua.toF32(L, 1), lua.toF32(L, 2)));
    return 1;
}
fn lua_noise_perlin(L: ?*lua_State) callconv(.c) c_int {
    lua.pushF32(L, core_noise.perlin(noiseSeedFor(L, 3), lua.toF32(L, 1), lua.toF32(L, 2)));
    return 1;
}
fn lua_noise_simplex(L: ?*lua_State) callconv(.c) c_int {
    lua.pushF32(L, core_noise.simplex(noiseSeedFor(L, 3), lua.toF32(L, 1), lua.toF32(L, 2)));
    return 1;
}

/// `noise.fbm(x, y, octaves, basis, seed)`: `basis` is one of "value", "perlin"
/// or "simplex", defaulting to perlin. Octaves are clamped by the core, so a
/// script asking for 200 gets the cap instead of a frame-long stall.
fn lua_noise_fbm(L: ?*lua_State) callconv(.c) c_int {
    lua.pushF32(L, core_noise.fbm(
        noiseSeedFor(L, 5),
        lua.toF32(L, 1),
        lua.toF32(L, 2),
        toOctaves(L, 3),
        basisArg(L, 4),
    ));
    return 1;
}

/// `noise.ridged(x, y, octaves, basis, seed)`.
fn lua_noise_ridged(L: ?*lua_State) callconv(.c) c_int {
    lua.pushF32(L, core_noise.ridged(
        noiseSeedFor(L, 5),
        lua.toF32(L, 1),
        lua.toF32(L, 2),
        toOctaves(L, 3),
        basisArg(L, 4),
    ));
    return 1;
}

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

    // ── actor: spatial queries between actors ──────────────────────────────
    // These take the OTHER actor as an argument, which in this engine is just
    // another behavior's `self` table — it carries the same stamped `__entity`
    // bridge, so the pair resolves with one field read each.
    .{ .name = "distance_to", .func = lua_distance_to },
    .{ .name = "distance_to_point", .func = lua_distance_to_point },
    .{ .name = "distance_squared_to", .func = lua_distance_squared_to },
    .{ .name = "is_within_radius", .func = lua_is_within_radius },
    .{ .name = "is_within_radius_of_point", .func = lua_is_within_radius_of_point },
    .{ .name = "direction_to", .func = lua_direction_to },
    .{ .name = "angle_to", .func = lua_angle_to },
    .{ .name = "get_half_size", .func = lua_get_half_size },
    // Physics (M4). On `actor` rather than on `physics` because each one is
    // about THIS actor's body; the world-level questions live on `physics`.
    .{ .name = "set_linear_velocity", .func = lua_actor_set_linear_velocity },
    .{ .name = "get_linear_velocity", .func = lua_actor_get_linear_velocity },
    .{ .name = "apply_impulse", .func = lua_actor_apply_impulse },
    .{ .name = "is_awake", .func = lua_actor_is_awake },
    // The component inspector (M2/editor): generic add/remove/has, so a tool
    // does not need a setter per component.
    .{ .name = "add_component", .func = lua_actor_add_component },
    .{ .name = "has_component", .func = lua_actor_has_component },
    .{ .name = "remove_component", .func = lua_actor_remove_component },
    .{ .name = null, .func = null },
};

// ── Physics: raycasts and impulses (M4) ──────────────────────────────────────
//
// The Lua surface is deliberately small. It exposes the two questions gameplay
// actually asks — "is that shot blocked?" and "make this thing move" — and
// nothing about solvers, bodies or steps. Everything else about physics is the
// engine's business, and a game that could step the world itself could break
// the fixed-60 Hz contract that determinism rests on.

const physics_mod = @import("physics");
const RigidBody2D = context_mod.components.RigidBody2D;
const Collider2D = context_mod.components.Collider2D;
const CollisionLayers = context_mod.components.CollisionLayers;

/// The solver body behind an entity, or null when it has none.
///
/// Null covers three different situations and they are deliberately not
/// distinguished for the caller: no `RigidBody2D` at all (a pure-transform
/// actor), one that the runtime has not synced yet (load in progress), and one
/// whose handle was retired. From Lua they are the same thing — this actor is
/// not simulated — and a binding that tried to tell them apart would leak the
/// engine's lifecycle into gameplay.
fn bodyOf(ctx: *Context, e: context_mod.Entity) ?physics_mod.BodyId {
    const rb = ctx.world.get(e, RigidBody2D) orelse return null;
    if (!rb.isSimulated()) return null;
    return .{ .index = rb.body, .generation = rb.generation };
}

/// The physics world, or null when the runtime runs without one.
///
/// Null is reported as a failed call rather than as an empty answer: a
/// line-of-sight test that finds nothing because there is no physics reads to
/// Lua as "clear shot", and an AI that fires on a false clear is worse than one
/// that sees an error.
fn physicsOf(L: ?*lua_State) ?physics_mod.System {
    const ctx = ctxOf(L);
    const p = ctx.physics orelse return null;
    return p.*;
}

/// `physics.cast_ray(x1, y1, x2, y2) -> hit, t, px, py, nx, ny`
///
/// Six returns rather than a table, because a table would allocate on every
/// call and this is meant to be affordable once per AI agent per frame
/// (spec §3.1). The hit point and surface normal are enough to place a
/// bullet impact decal or steer a homing projectile; nothing about the hit
/// shape is exposed because nothing in gameplay should depend on it.
fn lua_physics_cast_ray(L: ?*lua_State) callconv(.c) c_int {
    const world = physicsOf(L) orelse return 0;
    const solver = world.world;
    const p1 = physics_mod.Vec2{ .x = lua.toF32(L, 1), .y = lua.toF32(L, 2) };
    const p2 = physics_mod.Vec2{ .x = lua.toF32(L, 3), .y = lua.toF32(L, 4) };

    // `.fixed` as the filter means "anything solid blocks me", which is what a
    // line of sight means. A body-type filter would answer "can a dynamic body
    // hit it", a different question the raycast does not ask.
    const hit = solver.castRay(p1, p2, .pass_all) orelse {
        lua.lua_pushboolean(L, 0);
        return 1;
    };
    lua.lua_pushboolean(L, 1);
    lua.pushF32(L, hit.fraction); // how far along the segment, 0..1
    lua.pushF32(L, hit.point.x);
    lua.pushF32(L, hit.point.y);
    lua.pushF32(L, hit.normal.x);
    lua.pushF32(L, hit.normal.y);
    return 6;
}

/// `physics.line_of_sight(x1, y1, x2, y2) -> boolean`
///
/// The same query with everything but the answer discarded. It exists because
/// "can I see there" is the overwhelmingly common case — a turret deciding
/// whether to fire, a guard deciding whether to alert — and pushing five
/// numbers a caller will ignore is work for no reason.
fn lua_physics_line_of_sight(L: ?*lua_State) callconv(.c) c_int {
    const world = physicsOf(L) orelse return 0;
    const solver = world.world;
    const p1 = physics_mod.Vec2{ .x = lua.toF32(L, 1), .y = lua.toF32(L, 2) };
    const p2 = physics_mod.Vec2{ .x = lua.toF32(L, 3), .y = lua.toF32(L, 4) };
    const clear = solver.castRay(p1, p2, .pass_all) == null;
    lua.lua_pushboolean(L, @intFromBool(clear));
    return 1;
}

/// `actor.set_linear_velocity(vx, vy)`.
///
/// Sets the velocity outright rather than adding to it. Games reach for "set"
/// far more often than they think — a conveyor belt, a knockback, a scripted
/// cutscene — and an `add_*` variant is one line away for the cases that need it.
fn lua_actor_set_linear_velocity(L: ?*lua_State) callconv(.c) c_int {
    const ctx = ctxOf(L);
    const e = entityOf(L, 1) orelse return 0;
    const p = ctx.physics orelse return 0;
    const sys: *physics_mod.System = p;
    // Through the component, not the solver: `System.step` re-asserts the
    // component's velocity every frame, so a velocity set on the solver is
    // discarded before it is ever integrated. Only the LINEAR component is
    // touched, so setting it never silently stops a spinning actor.
    sys.setLinearVelocity(ctx.world, e, .{ .x = lua.toF32(L, 2), .y = lua.toF32(L, 3) });
    return 0;
}

/// `actor.get_linear_velocity() -> vx, vy`
fn lua_actor_get_linear_velocity(L: ?*lua_State) callconv(.c) c_int {
    const ctx = ctxOf(L);
    const e = entityOf(L, 1) orelse return 0;
    const sys = ctx.physics orelse return 0;
    const v = sys.linearVelocity(ctx.world, e) orelse return 0;
    lua.pushF32(L, v.x);
    lua.pushF32(L, v.y);
    return 2;
}

/// `actor.apply_impulse(ix, iy)` — the jump primitive.
///
/// Applied at the centre of mass, so it cannot spin the actor, and it wakes a
/// sleeping body: an actor that fell asleep on a ledge must still be able to
/// jump when the player presses the button, and that is the single most common
/// way a jump "does nothing".
fn lua_actor_apply_impulse(L: ?*lua_State) callconv(.c) c_int {
    const ctx = ctxOf(L);
    const e = entityOf(L, 1) orelse return 0;
    const sys = ctx.physics orelse return 0;
    // QUEUED, not applied now. The impulse is handed to the System and applied
    // during the next `pushDown`, after the component's velocity has been
    // written — applying it here would have it overwritten a moment later, and
    // a jump that silently does nothing is the hardest kind of bug to find.
    sys.pendingImpulse(e, .{ .x = lua.toF32(L, 2), .y = lua.toF32(L, 3) });
    return 0;
}

/// `actor.is_awake() -> boolean`
///
/// Exposed because "my actor is not moving and I do not know why" is a real
/// debugging session, and sleeping is invisible from the outside until you know
/// to look for it.
fn lua_actor_is_awake(L: ?*lua_State) callconv(.c) c_int {
    const ctx = ctxOf(L);
    const e = entityOf(L, 1) orelse return 0;
    const sys = ctx.physics orelse return 0;
    const v = sys.linearVelocity(ctx.world, e) orelse return 0;
    const rb = ctx.world.get(e, RigidBody2D) orelse return 0;
    const still = v.x == 0.0 and v.y == 0.0 and rb.angular_velocity == 0.0;
    lua.lua_pushboolean(L, @intFromBool(!still));
    return 1;
}

/// The `physics` table: world-level queries about the simulation.
/// `physics.stats() -> table`
///
/// The one function here that is about the ENGINE rather than the world. It
/// returns the counters a developer needs when a scene is slower than it should
/// be, and it is the difference between "physics is slow" and "physics is slow
/// because 1 900 of your bodies are awake and in contact".
///
/// Everything in it is a measurement, so it is safe to poll every frame from a
/// debug overlay. It allocates one small table, which is why it is not something
/// to call from a hot gameplay path by accident.
fn lua_physics_stats(L: ?*lua_State) callconv(.c) c_int {
    const sys = ctxOf(L).physics orelse return 0;
    const s = sys.world.stats();
    const a = &sys.activity.stats;

    lua.lua_createtable(L, 0, 10); // [t]

    const put = struct {
        fn str(state: ?*lua_State, k: [*:0]const u8, v: []const u8) void {
            lua.pushSlice(state, v);
            lua.setField(state, -2, k);
        }
        fn num(state: ?*lua_State, k: [*:0]const u8, v: f64) void {
            lua.lua_pushnumber(state, v);
            lua.setField(state, -2, k);
        }
    };

    // The broadphase, which is the part that can fail silently.
    put.num(L, "pairs", @floatFromInt(s.broadphase_pairs));
    put.num(L, "pairs_per_body", s.pairsPerBody());
    put.num(L, "tree_height", @floatFromInt(s.broadphase_height));
    put.num(L, "static_tree_height", @floatFromInt(s.broadphase_static_height));
    put.num(L, "solver_bytes", @floatFromInt(s.solver_bytes));

    // What the solver is actually thinking about.
    put.num(L, "bodies", @floatFromInt(s.bodies));
    put.num(L, "shapes", @floatFromInt(s.shapes));
    put.num(L, "contacts", @floatFromInt(s.contacts));
    put.num(L, "islands", @floatFromInt(s.islands));
    put.num(L, "sleeping", @floatFromInt(s.sleeping));

    // What the activity system decided.
    put.num(L, "simulated", @floatFromInt(a.by_tier[0] + a.by_tier[1]));
    put.num(L, "active_fraction", a.activeFraction());
    put.num(L, "transitions", @floatFromInt(a.transitions));
    return 1;
}

/// `physics.set_view(cx, cy, half_w, half_h, enabled)`
///
/// Tells the engine what the camera can see, which is what turns on physics view
/// culling. Separate from the focus point because a multiplayer server has a
/// focus and no camera, and culling against a zero-sized view would delete the
/// world out from under it.
fn lua_physics_set_view(L: ?*lua_State) callconv(.c) c_int {
    const ctx = ctxOf(L);
    const sys = ctx.physics orelse return 0;
    sys.setView(
        .{ .x = lua.toF32(L, 1), .y = lua.toF32(L, 2) },
        .{ .x = lua.toF32(L, 3), .y = lua.toF32(L, 4) },
        lua.toBool(L, 5),
    );
    return 0;
}

/// `physics.set_focus(x, y)` — where the player is, for distance tiers.
fn lua_physics_set_focus(L: ?*lua_State) callconv(.c) c_int {
    const sys = ctxOf(L).physics orelse return 0;
    sys.setFocus(.{ .x = lua.toF32(L, 1), .y = lua.toF32(L, 2) });
    return 0;
}

// ── The editor surface ───────────────────────────────────────────────────────
//
// Everything an editor needs to PLACE, RESIZE, RETUNE and SELECT physics
// without writing Zig. Each of these is the editor's verb, not the engine's:
// "make a box here" is an editor operation, and the engine's job is to make it
// safe to call sixty times a second while a handle is being dragged.

/// How many entities one `physics.overlap_rect` call may return.
///
/// A drag-select over a whole level can hit anything, so this is a hint for the
/// caller to grow its buffer and ask again, not a limit. Silently truncating
/// would make an editor select "everything that fitted" and report that as the
/// selection.
const overlap_capacity: usize = 256;

/// Scratch for the overlap result, kept out of the stack because it is 256
/// entities and a C binding's frame is the default thread stack.
var overlap_scratch: [overlap_capacity]context_mod.Entity = undefined;

/// `physics.create_shape(self_entity, kind, half_w, half_h)`
///
/// Turns an existing actor into a solid body, or re-shapes one that already is.
/// The editor spawns an actor first — actors are the document — and then gives
/// it a shape, which is exactly how a designer thinks: place a sprite, give it a
/// collider.
///
/// `kind` is the same ordinal the component uses: 0 box, 1 circle, 2 capsule,
/// 3 cylinder, 4 polygon.
fn lua_physics_create_shape(L: ?*lua_State) callconv(.c) c_int {
    const ctx = ctxOf(L);
    const e = entityOf(L, 1) orelse return 0;
    const sys = ctx.physics orelse return 0;

    // A body that has never been synced needs creating rather than reshaping.
    if (ctx.world.get(e, RigidBody2D)) |rb| {
        if (!rb.isSimulated()) {
            sys.syncEntity(ctx.world, e);
        }
    } else {
        _ = ctx.world.add(e, RigidBody2D{}) catch return 0;
        sys.syncEntity(ctx.world, e);
    }

    sys.reshape(ctx.world, e, @as(u8, @truncate(@as(u32, @intFromFloat(@max(lua.toF32(L, 2), 0))))), lua.toF32(L, 3), lua.toF32(L, 4));
    return 0;
}

/// `physics.reshape(self, kind, half_w, half_h)` — the drag-resize path.
fn lua_physics_reshape(L: ?*lua_State) callconv(.c) c_int {
    const ctx = ctxOf(L);
    const e = entityOf(L, 1) orelse return 0;
    const sys = ctx.physics orelse return 0;
    sys.reshape(ctx.world, e, @as(u8, @truncate(@as(u32, @intFromFloat(@max(lua.toF32(L, 2), 0))))), lua.toF32(L, 3), lua.toF32(L, 4));
    return 0;
}

/// `physics.set_material(self, friction, restitution, density)`
fn lua_physics_set_material(L: ?*lua_State) callconv(.c) c_int {
    const ctx = ctxOf(L);
    const e = entityOf(L, 1) orelse return 0;
    const sys = ctx.physics orelse return 0;
    sys.setMaterial(ctx.world, e, lua.toF32(L, 2), lua.toF32(L, 3), lua.toF32(L, 4));
    return 0;
}

/// `physics.set_sensor(self, is_sensor)` — a trigger volume with no contact
/// response. Separate from `reshape` because it is a different KIND of thing,
/// not a different size, and flipping it should not require re-specifying the
/// shape.
fn lua_physics_set_sensor(L: ?*lua_State) callconv(.c) c_int {
    const ctx = ctxOf(L);
    const e = entityOf(L, 1) orelse return 0;
    const sys = ctx.physics orelse return 0;
    const c = ctx.world.get(e, Collider2D) orelse return 0;
    const want = lua.toBool(L, 2);
    if (c.is_sensor == want) return 0;
    c.is_sensor = want;
    sys.reshape(ctx.world, e, c.kind, c.size.x, c.size.y);
    return 0;
}

/// `physics.set_layers(self, layer_mask, collide_mask)`
///
/// Bitmasks, not names: resolving a name to a bit needs the project's layer
/// table, and a binding that could not find one would have to guess. The editor
/// holds the table and passes the bits.
fn lua_physics_set_layers(L: ?*lua_State) callconv(.c) c_int {
    const ctx = ctxOf(L);
    const e = entityOf(L, 1) orelse return 0;
    const sys = ctx.physics orelse return 0;
    if (ctx.world.get(e, CollisionLayers)) |cl| {
        cl.layer = @as(u16, @truncate(@as(u32, @intFromFloat(@max(lua.toF32(L, 2), 0)))));
        cl.mask = @as(u16, @truncate(@as(u32, @intFromFloat(@max(lua.toF32(L, 3), 0)))));
        sys.reapplyFilter(ctx.world, e);
    } else {
        _ = ctx.world.add(e, CollisionLayers{
            .layer = @as(u16, @truncate(@as(u32, @intFromFloat(@max(lua.toF32(L, 2), 0))))),
            .mask = @as(u16, @truncate(@as(u32, @intFromFloat(@max(lua.toF32(L, 3), 0))))),
        }) catch return 0;
        sys.reapplyFilter(ctx.world, e);
    }
    return 0;
}

/// `physics.set_body_type(self, kind)` — 0 fixed, 1 kinematic, 2 dynamic.
fn lua_physics_set_body_type(L: ?*lua_State) callconv(.c) c_int {
    const ctx = ctxOf(L);
    const e = entityOf(L, 1) orelse return 0;
    const sys = ctx.physics orelse return 0;
    const rb = ctx.world.get(e, RigidBody2D) orelse return 0;
    const want: u8 = @truncate(@as(u32, @intFromFloat(@max(lua.toF32(L, 2), 0))));
    if (rb.body_type == want) return 0;
    rb.body_type = want;
    sys.setBodyType(ctx.world, e, want);
    return 0;
}

/// `physics.set_body_enabled(self, enabled)` — collision on/off without losing
/// the shape. What an editor's eye toggle calls.
fn lua_physics_set_body_enabled(L: ?*lua_State) callconv(.c) c_int {
    const ctx = ctxOf(L);
    const e = entityOf(L, 1) orelse return 0;
    const sys = ctx.physics orelse return 0;
    sys.setBodyEnabled(ctx.world, e, lua.toBool(L, 2));
    return 0;
}

/// `physics.overlap_rect(cx, cy, half_w, half_h) -> count, [entities...]`
///
/// The selection query. Returns the entities as varargs rather than a table so
/// a drag-select does not allocate an array every frame while the mouse moves.
///
/// Approximate: a shape is found when a ray crosses it, so a selection smaller
/// than the ray spacing can miss. See `overlapBox` in the adapter for why this
/// solver's API forces it.
fn lua_physics_overlap_rect(L: ?*lua_State) callconv(.c) c_int {
    const ctx = ctxOf(L);
    const sys = ctx.physics orelse return 0;
    const cx = lua.toF32(L, 1);
    const cy = lua.toF32(L, 2);
    const hw = @abs(lua.toF32(L, 3));
    const hh = @abs(lua.toF32(L, 4));

    const box = physics_mod.Aabb.centred(cx, cy, hw, hh);
    const total = sys.overlapEntities(box, &overlap_scratch);

    // De-duplicate: the ray grid crosses one shape many times, and an editor
    // selection must not contain the same actor twice.
    var unique: usize = 0;
    for (overlap_scratch[0..@min(total, overlap_capacity)]) |candidate| {
        var dup = false;
        for (overlap_scratch[0..unique]) |seen| {
            if (seen.eql(candidate)) dup = true;
        }
        if (!dup) {
            overlap_scratch[unique] = candidate;
            unique += 1;
        }
    }

    // Each entity needs its own table: `stampEntity` writes the handle INTO the
    // table on top of the stack, so there has to be one. Pushing a bare
    // light-userdata would leave the caller with a number it cannot call
    // `actor.get_position` on.
    for (overlap_scratch[0..unique]) |ent| {
        lua.lua_createtable(L, 0, 1);
        stampEntity(L, ent);
    }
    // The count goes LAST, which is why it is moved to the top: a caller reads
    // `local n, a, b = ...` and wants the count first.
    lua.lua_pushinteger(L, @intCast(unique));
    lua.lua_insert(L, -@as(c_int, @intCast(unique + 1)));
    return @intCast(unique + 1);
}

/// `physics.contains_point(x, y) -> actor|nil`
///
/// Click-to-select. A ray cast of zero length is not useful, so this is the
/// same grid query over a tiny box — small enough that the spacing is below any
/// shape an editor places.
fn lua_physics_contains_point(L: ?*lua_State) callconv(.c) c_int {
    const ctx = ctxOf(L);
    const sys = ctx.physics orelse return 0;
    const p = .{ .x = lua.toF32(L, 1), .y = lua.toF32(L, 2) };
    const box = physics_mod.Aabb.centred(p.x, p.y, 0.5, 0.5);
    const total = sys.overlapEntities(box, &overlap_scratch);
    if (total == 0) {
        lua.lua_pushnil(L);
        return 1;
    }
    lua.lua_createtable(L, 0, 1);
    stampEntity(L, overlap_scratch[0]);
    return 1;
}

// ── Sprite primitives: making a prototype without an art pipeline ────────────
//
// Godot can draw a rectangle, a circle, a line and a polygon with no texture at
// all, which is what makes "grey boxes" a legitimate first step rather than a
// placeholder you have to replace. These are the same four, backed by the
// sprite the renderer already knows how to draw.
//
// They all write the SPRITE component rather than inventing a draw path, so a
// prototype drawn with `sprite_rect` and a prototype drawn with a real atlas are
// the same object afterwards — switching to art later is one line, not a rewrite.

/// `sprite_rect(self, w, h, r, g, b, a)`
///
/// A filled rectangle. `r/g/b/a` are 0..1.
fn lua_sprite_rect(L: ?*lua_State) callconv(.c) c_int {
    const ctx = ctxOf(L);
    const e = entityOf(L, 1) orelse return 0;
    if (ctx.world.get(e, Sprite) == null) _ = ctx.world.add(e, Sprite{}) catch return 0;
    const sprite = ctx.world.get(e, Sprite) orelse return 0;
    sprite.size = .{ .x = lua.toF32(L, 2), .y = lua.toF32(L, 3) };
    sprite.atlas = 0; // the white texture
    sprite.shape = context_mod.components.SpriteShape.quad;
    sprite.tint = .{ lua.toF32(L, 4), lua.toF32(L, 5), lua.toF32(L, 6), lua.toF32(L, 7) };
    return 0;
}

/// `sprite_circle(self, diameter, r, g, b, a)`
///
/// A circle drawn as a quad on the white texture with a circular mask applied
/// by the batcher. Cheaper than it sounds: it is one quad and one extra compare,
/// not a mesh.
fn lua_sprite_circle(L: ?*lua_State) callconv(.c) c_int {
    const ctx = ctxOf(L);
    const e = entityOf(L, 1) orelse return 0;
    const d = lua.toF32(L, 2);
    if (ctx.world.get(e, Sprite) == null) _ = ctx.world.add(e, Sprite{}) catch return 0;
    const sprite = ctx.world.get(e, Sprite) orelse return 0;
    sprite.size = .{ .x = d, .y = d };
    sprite.atlas = 0;
    sprite.tint = .{ lua.toF32(L, 3), lua.toF32(L, 4), lua.toF32(L, 5), lua.toF32(L, 6) };
    sprite.shape = context_mod.components.SpriteShape.circle;
    return 0;
}

/// `sprite_texture(self, w, h, atlas_slot, u0, v0, u1, v1)`
///
/// The same shape, but sampling a real atlas region. This is the "now give it
/// art" call, and it is a DIFFERENT function rather than a flag on the others so
/// that a prototype full of `sprite_rect` calls has an obvious, greppable list
/// to replace.
fn lua_sprite_texture(L: ?*lua_State) callconv(.c) c_int {
    const ctx = ctxOf(L);
    const e = entityOf(L, 1) orelse return 0;
    if (ctx.world.get(e, Sprite) == null) _ = ctx.world.add(e, Sprite{}) catch return 0;
    const sprite = ctx.world.get(e, Sprite) orelse return 0;
    sprite.size = .{ .x = lua.toF32(L, 2), .y = lua.toF32(L, 3) };
    sprite.atlas = @truncate(@as(u32, @intFromFloat(@max(lua.toF32(L, 4), 0))));
    sprite.uv = .{ lua.toF32(L, 5), lua.toF32(L, 6), lua.toF32(L, 7), lua.toF32(L, 8) };
    sprite.blend = .alpha;
    sprite.shape = context_mod.components.SpriteShape.quad;
    return 0;
}

/// `sprite_set_layer(self, layer)` — draw order. Lower draws first.
fn lua_sprite_set_layer(L: ?*lua_State) callconv(.c) c_int {
    const ctx = ctxOf(L);
    const e = entityOf(L, 1) orelse return 0;
    const sprite = ctx.world.get(e, Sprite) orelse return 0;
    sprite.layer = @truncate(@as(u32, @intFromFloat(@max(lua.toF32(L, 2), 0))));
    return 0;
}

/// `sprite_set_visible(self, visible)` — the editor's eye, and a cheap way to
/// keep something in the scene without deleting it.
fn lua_sprite_set_visible(L: ?*lua_State) callconv(.c) c_int {
    const ctx = ctxOf(L);
    const e = entityOf(L, 1) orelse return 0;
    const sprite = ctx.world.get(e, Sprite) orelse return 0;
    sprite.visible = lua.toBool(L, 2);
    return 0;
}

/// `render.set_view(cx, cy, half_w, half_h)` — what the camera can see.
///
/// Turning this on is what makes the renderer cull. Off means "no camera", which
/// is what a headless tool wants, and culling against a zero-sized view would
/// make the world invisible and report success.
fn lua_render_set_view(L: ?*lua_State) callconv(.c) c_int {
    const ctx = ctxOf(L);
    const half_w = @abs(lua.toF32(L, 3));
    const half_h = @abs(lua.toF32(L, 4));
    ctx.render_view = .{
        .min_x = lua.toF32(L, 1) - half_w,
        .min_y = lua.toF32(L, 2) - half_h,
        .max_x = lua.toF32(L, 1) + half_w,
        .max_y = lua.toF32(L, 2) + half_h,
    };
    ctx.render_view_enabled = true;
    return 0;
}

/// `render.stats() -> entities, instances, culled, hidden`
///
/// Culled and hidden are reported SEPARATELY, and that is the whole point: a
/// hidden sprite is a decision somebody made, a culled one is the engine saving
/// you work. A scene where `culled` is zero is paying to draw a world nobody can
/// see.
fn lua_render_stats(L: ?*lua_State) callconv(.c) c_int {
    const ctx = ctxOf(L);
    const s = ctx.render_stats;
    lua.lua_pushinteger(L, @intCast(s.entities));
    lua.lua_pushinteger(L, @intCast(s.instances));
    lua.lua_pushinteger(L, @intCast(s.culled));
    lua.lua_pushinteger(L, @intCast(s.hidden));
    return 4;
}

const render_regs = [_]luaL_Reg{
    .{ .name = "set_view", .func = lua_render_set_view },
    .{ .name = "stats", .func = lua_render_stats },
    .{ .name = "set_resident", .func = lua_render_set_resident },
    .{ .name = "all_resident", .func = lua_render_all_resident },
    .{ .name = null, .func = null },
};

// ── The component inspector ───────────────────────────────────────────────────
//
// Godot's model, and it is the right one: an actor is a bag of COMPONENTS, and
// the editor adds one and then edits its fields. Without this, a tool has to
// know every component in the engine and hard-code a setter for each one, and it
// breaks the moment a component is added.
//
// So there are two layers here. `actor.has_component` / `add_component` /
// `remove_component` are generic and know every registered component by name.
// Below them sit typed setters for the fields an inspector actually shows,
// because a generic `set_field(name, value)` in a C binding means stringly-typed
// lookups in the frame loop and no way for an editor to discover what exists.
//
// The metadata registry is what ties the two together: a tool reads the same
// `meta/ember.lua` a person reads, so the inspector's field list is generated
// rather than maintained.

/// `actor.add_component(name) -> boolean`
///
/// True when the component was added. False when the actor already had it, or
/// when the name is not a component — a tool must not be able to add something
/// the engine does not know, because nothing would ever read it.
fn lua_actor_add_component(L: ?*lua_State) callconv(.c) c_int {
    const ctx = ctxOf(L);
    const e = entityOf(L, 1) orelse return pushFalse(L);
    const name = lua.toSlice(L, 2) orelse "";

    if (std.mem.eql(u8, name, "Sprite")) {
        if (ctx.world.get(e, Sprite) != null) return pushFalse(L);
        _ = ctx.world.add(e, Sprite{}) catch return pushFalse(L);
    } else if (std.mem.eql(u8, name, "CollisionLayers")) {
        if (ctx.world.get(e, CollisionLayers) != null) return pushFalse(L);
        _ = ctx.world.add(e, CollisionLayers{}) catch return pushFalse(L);
    } else if (std.mem.eql(u8, name, "Name")) {
        if (ctx.world.get(e, context_mod.components.Name) != null) return pushFalse(L);
        _ = ctx.world.add(e, context_mod.components.Name{}) catch return pushFalse(L);
    } else {
        // An unknown name is a reportable error, not a silent no-op: a tool that
        // asks for a component that does not exist has a bug, and hiding it here
        // is how an inspector ends up with a field that never does anything.
        return pushFalse(L);
    }
    return pushTrue(L);
}

/// `actor.has_component(name) -> boolean`
fn lua_actor_has_component(L: ?*lua_State) callconv(.c) c_int {
    const ctx = ctxOf(L);
    const e = entityOf(L, 1) orelse return pushFalse(L);
    const name = lua.toSlice(L, 2) orelse "";
    const present = if (std.mem.eql(u8, name, "Sprite"))
        ctx.world.get(e, Sprite) != null
    else if (std.mem.eql(u8, name, "CollisionLayers"))
        ctx.world.get(e, CollisionLayers) != null
    else if (std.mem.eql(u8, name, "RigidBody2D"))
        ctx.world.get(e, RigidBody2D) != null
    else if (std.mem.eql(u8, name, "Collider2D"))
        ctx.world.get(e, Collider2D) != null
    else if (std.mem.eql(u8, name, "Name"))
        ctx.world.get(e, context_mod.components.Name) != null
    else
        false;
    return pushBool(L, present);
}

/// `actor.remove_component(name) -> boolean`
///
/// Refuses on `Transform`: an actor with no transform has no position, and every
/// other component, the renderer and the physics all assume it exists. Silently
/// removing it would leave an actor that renders nowhere and cannot be found.
fn lua_actor_remove_component(L: ?*lua_State) callconv(.c) c_int {
    const ctx = ctxOf(L);
    const e = entityOf(L, 1) orelse return pushFalse(L);
    const name = lua.toSlice(L, 2) orelse "";
    if (std.mem.eql(u8, name, "Transform")) return pushFalse(L);

    const removed = if (std.mem.eql(u8, name, "Sprite"))
        ctx.world.remove(e, Sprite)
    else if (std.mem.eql(u8, name, "CollisionLayers"))
        ctx.world.remove(e, CollisionLayers)
    else if (std.mem.eql(u8, name, "Collider2D"))
        ctx.world.remove(e, Collider2D)
    else
        false;
    return pushBool(L, removed);
}

/// `sprite.set_size(self, w, h)`
fn lua_sprite_set_size(L: ?*lua_State) callconv(.c) c_int {
    const sprite = spriteOf(L) orelse return 0;
    sprite.size = .{ .x = lua.toF32(L, 2), .y = lua.toF32(L, 3) };
    return 0;
}

/// `sprite.set_tint(self, r, g, b, a)`
fn lua_sprite_set_tint(L: ?*lua_State) callconv(.c) c_int {
    const sprite = spriteOf(L) orelse return 0;
    sprite.tint = .{ lua.toF32(L, 2), lua.toF32(L, 3), lua.toF32(L, 4), lua.toF32(L, 5) };
    return 0;
}

/// `sprite.set_uv(self, u0, v0, u1, v1)` — the atlas region.
fn lua_sprite_set_uv(L: ?*lua_State) callconv(.c) c_int {
    const sprite = spriteOf(L) orelse return 0;
    sprite.uv = .{ lua.toF32(L, 2), lua.toF32(L, 3), lua.toF32(L, 4), lua.toF32(L, 5) };
    return 0;
}

/// `sprite.set_atlas(self, slot)`
fn lua_sprite_set_atlas(L: ?*lua_State) callconv(.c) c_int {
    const sprite = spriteOf(L) orelse return 0;
    sprite.atlas = @truncate(@as(u32, @intFromFloat(@max(lua.toF32(L, 2), 0))));
    return 0;
}

/// `sprite.set_shape(self, kind)` — 0 quad, 1 circle.
fn lua_sprite_set_shape(L: ?*lua_State) callconv(.c) c_int {
    const sprite = spriteOf(L) orelse return 0;
    sprite.shape = if (lua.toF32(L, 2) == 0) .quad else .circle;
    return 0;
}

/// `sprite.set_blend(self, kind)` — 0 solid, 1 alpha, 2 additive.
fn lua_sprite_set_blend(L: ?*lua_State) callconv(.c) c_int {
    const sprite = spriteOf(L) orelse return 0;
    sprite.blend = switch (@as(u32, @intFromFloat(@max(lua.toF32(L, 2), 0)))) {
        0 => .solid,
        2 => .additive,
        else => .alpha,
    };
    return 0;
}

/// `sprite.get_size(self) -> w, h` — the inspector reads as well as writes.
fn lua_sprite_get_size(L: ?*lua_State) callconv(.c) c_int {
    const sprite = spriteOf(L) orelse return 0;
    lua.pushF32(L, sprite.size.x);
    lua.pushF32(L, sprite.size.y);
    return 2;
}

/// `sprite.get_tint(self) -> r, g, b, a`
fn lua_sprite_get_tint(L: ?*lua_State) callconv(.c) c_int {
    const sprite = spriteOf(L) orelse return 0;
    for (sprite.tint) |c| lua.pushF32(L, c);
    return 4;
}

fn spriteOf(L: ?*lua_State) ?*Sprite {
    const ctx = ctxOf(L);
    const e = entityOf(L, 1) orelse return null;
    return ctx.world.get(e, Sprite);
}

fn pushBool(L: ?*lua_State, v: bool) c_int {
    lua.lua_pushboolean(L, @intFromBool(v));
    return 1;
}
fn pushTrue(L: ?*lua_State) c_int {
    return pushBool(L, true);
}
fn pushFalse(L: ?*lua_State) c_int {
    return pushBool(L, false);
}

// ── Shader materials ─────────────────────────────────────────────────────────
//
// A small, deliberate surface: pick a shader, set four floats. Not a general
// uniform system -- a wider block needs a std140 layout and turns a hook into a
// project.

/// `material.new(self, shader)` — attaches a material to an actor.
fn lua_material_new(L: ?*lua_State) callconv(.c) c_int {
    const ctx = ctxOf(L);
    const e = entityOf(L, 1) orelse return 0;
    if (ctx.world.get(e, ShaderMaterial) == null) {
        _ = ctx.world.add(e, ShaderMaterial{}) catch return 0;
    }
    const mat = ctx.world.get(e, ShaderMaterial) orelse return 0;
    mat.shader = @truncate(@as(u32, @intFromFloat(@max(lua.toF32(L, 2), 0))));
    return 0;
}

/// `material.set_params(self, p0, p1, p2, p3)`
fn lua_material_set_params(L: ?*lua_State) callconv(.c) c_int {
    const mat = materialOf(L) orelse return 0;
    var i: usize = 2;
    while (i < 6) : (i += 1) mat.params[i - 2] = lua.toF32(L, @intCast(i));
    return 0;
}

/// `material.get_params(self) -> p0, p1, p2, p3`
fn lua_material_get_params(L: ?*lua_State) callconv(.c) c_int {
    const mat = materialOf(L) orelse return 0;
    for (mat.params) |p| lua.pushF32(L, p);
    return 4;
}

/// `material.get_shader(self) -> number`
fn lua_material_get_shader(L: ?*lua_State) callconv(.c) c_int {
    const mat = materialOf(L) orelse return 0;
    lua.pushF32(L, @floatFromInt(mat.shader));
    return 1;
}

fn materialOf(L: ?*lua_State) ?*ShaderMaterial {
    const ctx = ctxOf(L);
    const e = entityOf(L, 1) orelse return null;
    return ctx.world.get(e, ShaderMaterial);
}

/// `render.set_resident(slot, loaded)` — marks an atlas page as present or
/// evicted, which is what `collectFiltered` skips against.
///
/// Separate from the frustum because the two recover differently: a frustum
/// cull clears when the camera moves, a residency cull clears when the page is
/// read back in. A system that conflates them produces "the background vanished
/// and nobody knows why".
fn lua_render_set_resident(L: ?*lua_State) callconv(.c) c_int {
    const ctx = ctxOf(L);
    const slot: u8 = @truncate(@as(u32, @intFromFloat(@max(lua.toF32(L, 1), 0))));
    const word = slot >> 6;
    const bit: u6 = @intCast(slot & 63);
    if (lua.toBool(L, 2)) {
        ctx.render_resident[word] |= (@as(u64, 1) << bit);
    } else {
        ctx.render_resident[word] &= ~(@as(u64, 1) << bit);
    }
    return 0;
}

/// `render.all_resident()` — the default, and what a machine with no streaming
/// wants.
fn lua_render_all_resident(L: ?*lua_State) callconv(.c) c_int {
    ctxOf(L).render_resident = .{ 1, 1, 1, 1 };
    return 0;
}

const material_regs = [_]luaL_Reg{
    .{ .name = "new", .func = lua_material_new },
    .{ .name = "set_params", .func = lua_material_set_params },
    .{ .name = "get_params", .func = lua_material_get_params },
    .{ .name = "get_shader", .func = lua_material_get_shader },
    .{ .name = null, .func = null },
};

const sprite_regs = [_]luaL_Reg{
    .{ .name = "rect", .func = lua_sprite_rect },
    .{ .name = "circle", .func = lua_sprite_circle },
    .{ .name = "texture", .func = lua_sprite_texture },
    .{ .name = "set_layer", .func = lua_sprite_set_layer },
    .{ .name = "set_visible", .func = lua_sprite_set_visible },
    .{ .name = "set_size", .func = lua_sprite_set_size },
    .{ .name = "set_tint", .func = lua_sprite_set_tint },
    .{ .name = "set_uv", .func = lua_sprite_set_uv },
    .{ .name = "set_atlas", .func = lua_sprite_set_atlas },
    .{ .name = "set_shape", .func = lua_sprite_set_shape },
    .{ .name = "set_blend", .func = lua_sprite_set_blend },
    .{ .name = "get_size", .func = lua_sprite_get_size },
    .{ .name = "get_tint", .func = lua_sprite_get_tint },
    .{ .name = null, .func = null },
};

const physics_regs = [_]luaL_Reg{
    .{ .name = "cast_ray", .func = lua_physics_cast_ray },
    .{ .name = "line_of_sight", .func = lua_physics_line_of_sight },
    .{ .name = "stats", .func = lua_physics_stats },
    .{ .name = "set_view", .func = lua_physics_set_view },
    .{ .name = "set_focus", .func = lua_physics_set_focus },
    .{ .name = "create_shape", .func = lua_physics_create_shape },
    .{ .name = "reshape", .func = lua_physics_reshape },
    .{ .name = "set_material", .func = lua_physics_set_material },
    .{ .name = "set_sensor", .func = lua_physics_set_sensor },
    .{ .name = "set_layers", .func = lua_physics_set_layers },
    .{ .name = "set_body_type", .func = lua_physics_set_body_type },
    .{ .name = "set_body_enabled", .func = lua_physics_set_body_enabled },
    .{ .name = "overlap_rect", .func = lua_physics_overlap_rect },
    .{ .name = "contains_point", .func = lua_physics_contains_point },
    .{ .name = null, .func = null },
};

/// The `world` table: world-level queries, not per-actor ones. `nearby` lives
/// here rather than on `actor` because it is spatial, not about this actor.
const world_regs = [_]luaL_Reg{
    .{ .name = "nearby", .func = lua_world_nearby },
    .{ .name = null, .func = null },
};

/// Declarative state machines (ROADMAP M4.5). Methods on `self`; the same set
/// covers enemy AI, the player, spawners, UI screens and game flow.
const sm_regs = [_]luaL_Reg{
    .{ .name = "add_state", .func = lua_sm_add_state },
    .{ .name = "add_transition", .func = lua_sm_add_transition },
    .{ .name = "set_initial", .func = lua_sm_set_initial },
    .{ .name = "fire", .func = lua_sm_fire },
    .{ .name = "set_state", .func = lua_sm_set_state },
    .{ .name = "state", .func = lua_sm_state },
    .{ .name = "is_in", .func = lua_sm_is_in },
    .{ .name = null, .func = null },
};

const input_regs = [_]luaL_Reg{
    .{ .name = "is_action_pressed", .func = lua_is_action_pressed },
    .{ .name = "is_action_down", .func = lua_is_action_down },
    .{ .name = "get_axis", .func = lua_get_axis },
    .{ .name = null, .func = null },
};

/// Deterministic random numbers (ROADMAP M4.5). Every entry draws from
/// `ctx.rng`, so the whole table shares one sequence that `rand.seed` restarts.
const rand_regs = [_]luaL_Reg{
    .{ .name = "seed", .func = lua_rand_seed },
    .{ .name = "float", .func = lua_rand_float },
    .{ .name = "range", .func = lua_rand_range },
    .{ .name = "int", .func = lua_rand_int },
    .{ .name = "chance", .func = lua_rand_chance },
    .{ .name = "sign", .func = lua_rand_sign },
    .{ .name = "gauss", .func = lua_rand_gauss },
    .{ .name = "choice", .func = lua_rand_choice },
    .{ .name = "shuffle", .func = lua_rand_shuffle },
    .{ .name = null, .func = null },
};

/// Procedural noise (ROADMAP M4.5). Stateless per call — the seed is an
/// argument — so terrain and weather can use different fields concurrently.
const noise_regs = [_]luaL_Reg{
    .{ .name = "seed", .func = lua_noise_seed },
    .{ .name = "value", .func = lua_noise_value },
    .{ .name = "perlin", .func = lua_noise_perlin },
    .{ .name = "simplex", .func = lua_noise_simplex },
    .{ .name = "fbm", .func = lua_noise_fbm },
    .{ .name = "ridged", .func = lua_noise_ridged },
    .{ .name = null, .func = null },
};

const log_regs = [_]luaL_Reg{
    .{ .name = "info", .func = lua_log_info },
    .{ .name = "warn", .func = lua_log_warn },
    .{ .name = null, .func = null },
};

// ── math: the scalar set gameplay uses every frame (ROADMAP M3) ──────────────
// Thin wrappers over `core.math`: no allocation, no branches that can trap, and
// every one is total on its domain. Registering them from Zig (rather than
// shadowing LuaJIT's own `math`) keeps the semantics fixed across the LuaJIT and
// Lua 5.4 backends — `math.round` in stock 5.4 IS banker's rounding, which is
// not what gameplay wants, so the engine owns the name.

const math_regs = [_]luaL_Reg{
    .{ .name = "clamp", .func = scalar3(m.clampf) },
    .{ .name = "min", .func = scalar2(m.min) },
    .{ .name = "max", .func = scalar2(m.max) },
    .{ .name = "abs", .func = scalar1(m.abs) },
    .{ .name = "sign", .func = scalar1(m.sign) },
    .{ .name = "floor", .func = scalar1(m.floorf) },
    .{ .name = "ceil", .func = scalar1(m.ceilf) },
    .{ .name = "round", .func = scalar1(m.round) },
    .{ .name = "fract", .func = scalar1(m.fract) },
    .{ .name = "sqrt", .func = scalar1(m.sqrtf) },
    .{ .name = "pow", .func = scalar2(m.pow) },
    .{ .name = "sin", .func = scalar1(m.sin) },
    .{ .name = "cos", .func = scalar1(m.cos) },
    .{ .name = "atan2", .func = lua_math_atan2 },
    .{ .name = "lerp", .func = scalar3(m.lerpF) },
    .{ .name = "inverse_lerp", .func = scalar3(m.inverseLerp) },
    .{ .name = "remap", .func = scalar5(m.remap) },
    .{ .name = "smoothstep", .func = scalar3(m.smoothstep) },
    .{ .name = "step", .func = scalar2(m.step) },
    .{ .name = "move_toward", .func = scalar3(m.moveToward) },
    .{ .name = "damp", .func = scalar4(m.damp) },
    .{ .name = "wrap", .func = scalar3(m.wrap) },
    .{ .name = "pingpong", .func = scalar2(m.pingpong) },
    .{ .name = "deg_to_rad", .func = scalar1(m.degToRad) },
    .{ .name = "rad_to_deg", .func = scalar1(m.radToDeg) },
    .{ .name = "is_close", .func = lua_math_is_close },
    .{ .name = null, .func = null },
};

/// Factories returning a C function that reads N numbers, calls one core
/// function and pushes one result. Zig forbids a `comptime` parameter on a
/// function with a C calling convention, so the wrapper is a struct closing
/// over the core function and exposing `call`. That keeps the 25 registrations
/// above to one line each with no macro games.
fn scalar1(comptime f: fn (f32) f32) fn (?*lua_State) callconv(.c) c_int {
    return struct {
        fn call(L: ?*lua_State) callconv(.c) c_int {
            lua.pushF32(L, f(lua.toF32(L, 1)));
            return 1;
        }
    }.call;
}
fn scalar2(comptime f: fn (f32, f32) f32) fn (?*lua_State) callconv(.c) c_int {
    return struct {
        fn call(L: ?*lua_State) callconv(.c) c_int {
            lua.pushF32(L, f(lua.toF32(L, 1), lua.toF32(L, 2)));
            return 1;
        }
    }.call;
}
fn scalar3(comptime f: fn (f32, f32, f32) f32) fn (?*lua_State) callconv(.c) c_int {
    return struct {
        fn call(L: ?*lua_State) callconv(.c) c_int {
            lua.pushF32(L, f(lua.toF32(L, 1), lua.toF32(L, 2), lua.toF32(L, 3)));
            return 1;
        }
    }.call;
}
fn scalar4(comptime f: fn (f32, f32, f32, f32) f32) fn (?*lua_State) callconv(.c) c_int {
    return struct {
        fn call(L: ?*lua_State) callconv(.c) c_int {
            lua.pushF32(L, f(lua.toF32(L, 1), lua.toF32(L, 2), lua.toF32(L, 3), lua.toF32(L, 4)));
            return 1;
        }
    }.call;
}
fn scalar5(comptime f: fn (f32, f32, f32, f32, f32) f32) fn (?*lua_State) callconv(.c) c_int {
    return struct {
        fn call(L: ?*lua_State) callconv(.c) c_int {
            lua.pushF32(L, f(
                lua.toF32(L, 1),
                lua.toF32(L, 2),
                lua.toF32(L, 3),
                lua.toF32(L, 4),
                lua.toF32(L, 5),
            ));
            return 1;
        }
    }.call;
}

const m = core_math;

/// The core PRNG and noise generators the `rand`/`noise` tables expose.
const core_random = @import("core").random;
const core_noise = @import("core").noise;
const statemachine_mod = @import("statemachine.zig");
const spatial_mod = @import("spatial.zig");
const build_options = @import("options");

// ── Argument coercion for the rand/noise tables ──────────────────────────────
// Lua numbers are doubles; the core works in f32 and needs u64 seeds. These
// keep the conversion (and its edge cases) in one place instead of repeating it
// in ten bindings.

fn pushInt(L: ?*lua_State, v: i32) void {
    lua.lua_pushinteger(L, @intCast(v));
}

fn toInt(L: ?*lua_State, idx: c_int) i32 {
    return @intCast(@as(isize, @intFromFloat(lua.toF32(L, idx))));
}

/// Octave counts come from Lua as arbitrary doubles. Clamped here so a script
/// asking for `1e9` cannot make the core's `min(octaves, max_octaves)` the only
/// thing standing between a typo and a hang, and so a negative value does not
/// wrap into a huge `u8`.
fn toOctaves(L: ?*lua_State, idx: c_int) u8 {
    const raw = lua.toF32(L, idx);
    if (raw <= 0.0) return 0;
    return @intFromFloat(@min(raw, @as(f32, @floatFromInt(core_noise.max_octaves))));
}

/// A seed is a u64 taken from a Lua number. Doubles hold only 53 bits exactly,
/// so this keeps the integral part and reinterprets a negative one as its
/// two's-complement u64 rather than collapsing it to 0 — `rand.seed(-5)` must
/// not be indistinguishable from `rand.seed(0)`.
fn toSeed(L: ?*lua_State, idx: c_int) u64 {
    const raw = lua.toF32(L, idx);
    const whole = @trunc(raw);
    if (whole < 0.0) return @bitCast(@as(i64, @intFromFloat(whole)));
    return @intFromFloat(whole);
}

/// Reads the basis name argument, defaulting to perlin when absent or unknown.
/// Defaulting rather than erroring keeps a typo'd basis from breaking a level:
/// it falls back to the recommended one instead of halting the game.
fn basisArg(L: ?*lua_State, idx: c_int) core_noise.Basis {
    const s = lua.toSlice(L, idx) orelse return .perlin;
    if (std.mem.eql(u8, s, "value")) return .value;
    if (std.mem.eql(u8, s, "simplex")) return .simplex;
    return .perlin;
}

/// `atan2(y, x)`: the same argument order as stock Lua, so the engine owns the
/// semantics identically on the LuaJIT and Lua 5.4 backends.
fn lua_math_atan2(L: ?*lua_State) callconv(.c) c_int {
    lua.pushF32(L, m.atan2(lua.toF32(L, 1), lua.toF32(L, 2)));
    return 1;
}

/// `is_close(a, b, tolerance) -> boolean`: the one predicate in the set that is
/// not a transform.
fn lua_math_is_close(L: ?*lua_State) callconv(.c) c_int {
    lua.lua_pushboolean(L, @intFromBool(m.isClose(
        lua.toF32(L, 1),
        lua.toF32(L, 2),
        lua.toF32(L, 3),
    )));
    return 1;
}

// ── vec2: the spatial set (Godot's Vec2, minus the per-call allocation) ─────
// Two shapes, on purpose:
//   * `vec2.new(x, y)` returns a TABLE with `x`/`y` fields: ergonomic for state
//     (`self.target = vec2.new(...)`), and it allocates in Lua's heap only when
//     the game explicitly asks for one — never inside a hot loop by accident.
//   * the rest take/return NUMBERS, so a per-frame computation
//     (`vec2.distance(ax, ay, bx, by)`) does zero Lua allocation and one C call.
// That split is the whole design: the table form for readability, the scalar
// form for the frame loop.

const vec2_regs = [_]luaL_Reg{
    .{ .name = "new", .func = lua_vec2_new },
    .{ .name = "dist", .func = lua_vec2_dist },
    .{ .name = "dist_sq", .func = lua_vec2_dist_sq },
    .{ .name = "length", .func = lua_vec2_length },
    .{ .name = "length_sq", .func = lua_vec2_length_sq },
    .{ .name = "normalized", .func = lua_vec2_normalized },
    .{ .name = "direction", .func = lua_vec2_direction },
    .{ .name = "lerp", .func = lua_vec2_lerp },
    .{ .name = "dot", .func = lua_vec2_dot },
    .{ .name = "cross", .func = lua_vec2_cross },
    .{ .name = "angle", .func = lua_vec2_angle },
    .{ .name = "angle_between", .func = lua_vec2_angle_between },
    .{ .name = "rotate", .func = lua_vec2_rotate },
    .{ .name = "perpendicular", .func = lua_vec2_perp },
    .{ .name = "clamp_length", .func = lua_vec2_clamp_length },
    .{ .name = "reflect", .func = lua_vec2_reflect },
    .{ .name = "from_angle", .func = lua_vec2_from_angle },
    .{ .name = "to_vec", .func = lua_vec2_to_vec },
    .{ .name = "clamped", .func = lua_vec2_clamped },
    .{ .name = null, .func = null },
};

/// Reads a `{x=, y=}` table (or two numbers) into a Vec2. Accepting both is what
/// makes `vec2.dist(a, b)` work with vec2.new() tables AND with the four-number
/// form in the same script.
const Input = struct {
    vec: m.Vec2,
};

/// Loads a vec2 from stack index `idx`: a table with `x`/`y` fields, else (0,0).
fn readVec2(L: ?*lua_State, idx: c_int) m.Vec2 {
    if (lua.lua_type(L, idx) == lua.TTABLE) {
        lua.getField(L, idx, "x");
        const x = lua.toF32(L, -1);
        lua.getField(L, idx, "y");
        const y = lua.toF32(L, -1);
        lua.pop(L, 2);
        return .{ .x = x, .y = y };
    }
    return m.Vec2{};
}

/// Returns a vec2 as a TABLE. Used by every vec2 function that must return a
/// vector (normalized, direction, reflect...).
fn pushVec2(L: ?*lua_State, v: m.Vec2) void {
    _ = lua.lua_createtable(L, 0, 2); // [v]
    lua.pushF32(L, v.x);
    lua.setField(L, -2, "x");
    lua.pushF32(L, v.y);
    lua.setField(L, -2, "y");
}

/// Returns ONE number (the zero-allocation companion to `pushVec2`).
fn pushF32(L: ?*lua_State, v: f32) void {
    lua.lua_pushnumber(L, v);
}

fn lua_vec2_new(L: ?*lua_State) callconv(.c) c_int {
    const x = lua.toF32(L, 1);
    const y = lua.toF32(L, 2);
    pushVec2(L, .{ .x = x, .y = y });
    return 1;
}

fn lua_vec2_dist(L: ?*lua_State) callconv(.c) c_int {
    // Both forms: (ax, ay, bx, by) and (vec_a, vec_b).
    const a = readVec2Or2(L, 1);
    const b = readVec2Or2(L, if (lua.lua_type(L, 1) == lua.TTABLE) 2 else 3);
    pushF32(L, m.Vec2.distance(a, b));
    return 1;
}

/// `(x, y, x, y)` as four numbers when the first argument is not a table.
fn readVec2Or2(L: ?*lua_State, idx: c_int) m.Vec2 {
    if (lua.lua_type(L, idx) == lua.TTABLE) return readVec2(L, idx);
    return .{ .x = lua.toF32(L, idx), .y = lua.toF32(L, idx + 1) };
}

fn lua_vec2_dist_sq(L: ?*lua_State) callconv(.c) c_int {
    const a = readVec2Or2(L, 1);
    const b = readVec2Or2(L, if (lua.lua_type(L, 1) == lua.TTABLE) 2 else 3);
    const d = b.sub(a);
    pushF32(L, d.x * d.x + d.y * d.y);
    return 1;
}

fn lua_vec2_length(L: ?*lua_State) callconv(.c) c_int {
    const v = readVec2Or2(L, 1);
    pushF32(L, v.len());
    return 1;
}

fn lua_vec2_length_sq(L: ?*lua_State) callconv(.c) c_int {
    const v = readVec2Or2(L, 1);
    pushF32(L, v.x * v.x + v.y * v.y);
    return 1;
}

fn lua_vec2_normalized(L: ?*lua_State) callconv(.c) c_int {
    const v = readVec2Or2(L, 1);
    pushVec2(L, v.normalized());
    return 1;
}

/// Unit vector pointing FROM `a` TO `b`. The zero vector maps to zero rather
/// than NaN (a NaN direction silently poisons every downstream multiply).
fn lua_vec2_direction(L: ?*lua_State) callconv(.c) c_int {
    const a = readVec2Or2(L, 1);
    const b = readVec2Or2(L, if (lua.lua_type(L, 1) == lua.TTABLE) 2 else 3);
    const d = b.sub(a);
    pushVec2(L, d.normalized());
    return 1;
}

fn lua_vec2_lerp(L: ?*lua_State) callconv(.c) c_int {
    const a = readVec2Or2(L, 1);
    const second: c_int = if (lua.lua_type(L, 1) == lua.TTABLE) 2 else 3;
    const b = readVec2Or2(L, second);
    const t = lua.toF32(L, second + 1);
    pushVec2(L, a.lerp(b, t));
    return 1;
}

fn lua_vec2_dot(L: ?*lua_State) callconv(.c) c_int {
    const a = readVec2Or2(L, 1);
    const b = readVec2Or2(L, if (lua.lua_type(L, 1) == lua.TTABLE) 2 else 3);
    pushF32(L, a.dot(b));
    return 1;
}

fn lua_vec2_cross(L: ?*lua_State) callconv(.c) c_int {
    const a = readVec2Or2(L, 1);
    const b = readVec2Or2(L, if (lua.lua_type(L, 1) == lua.TTABLE) 2 else 3);
    pushF32(L, m.Vec2.cross(a, b));
    return 1;
}

/// Angle of a single vector, in radians. `atan2(y, x)` so it is defined for
/// every vector including the zero one.
fn lua_vec2_angle(L: ?*lua_State) callconv(.c) c_int {
    const v = readVec2Or2(L, 1);
    pushF32(L, m.atan2(v.y, v.x));
    return 1;
}

/// Signed angle from `a` to `b`, in radians. Positive = clockwise on screen.
fn lua_vec2_angle_between(L: ?*lua_State) callconv(.c) c_int {
    const a = readVec2Or2(L, 1);
    const b = readVec2Or2(L, if (lua.lua_type(L, 1) == lua.TTABLE) 2 else 3);
    pushF32(L, m.Vec2.angleTo(a, b));
    return 1;
}

fn lua_vec2_rotate(L: ?*lua_State) callconv(.c) c_int {
    const v = readVec2Or2(L, 1);
    const second: c_int = if (lua.lua_type(L, 1) == lua.TTABLE) 2 else 3;
    const radians = lua.toF32(L, second + 1);
    pushVec2(L, v.rotate(radians));
    return 1;
}

fn lua_vec2_perp(L: ?*lua_State) callconv(.c) c_int {
    const v = readVec2Or2(L, 1);
    pushVec2(L, v.perp());
    return 1;
}

fn lua_vec2_clamp_length(L: ?*lua_State) callconv(.c) c_int {
    const v = readVec2Or2(L, 1);
    const max_len = lua.toF32(L, if (lua.lua_type(L, 1) == lua.TTABLE) 2 else 3);
    pushVec2(L, v.clamped(max_len));
    return 1;
}

/// Bounce: `reflect(incoming, normal)` returns the incoming direction mirrored
/// around a unit normal. The classic wall/paddle bounce; the normal is assumed
/// normalized (dot with itself is 1).
fn lua_vec2_reflect(L: ?*lua_State) callconv(.c) c_int {
    const d = readVec2Or2(L, 1);
    const n = readVec2Or2(L, if (lua.lua_type(L, 1) == lua.TTABLE) 2 else 3);
    // d - 2 * (d . n) * n
    const dot = d.dot(n);
    pushVec2(L, .{
        .x = d.x - 2.0 * dot * n.x,
        .y = d.y - 2.0 * dot * n.y,
    });
    return 1;
}

/// Unit vector at `radians` (Godot's `Vector2.from_angle`).
fn lua_vec2_from_angle(L: ?*lua_State) callconv(.c) c_int {
    const a = lua.toF32(L, 1);
    pushVec2(L, .{ .x = m.cos(a), .y = m.sin(a) });
    return 1;
}

/// `to_vec(x, y)` is the width-explicit constructor: same as `new`, kept because
/// the scalar/table split above makes the intent obvious at the call site.
fn lua_vec2_to_vec(L: ?*lua_State) callconv(.c) c_int {
    return lua_vec2_new(L);
}

/// Godot spells it `clamped`; `clamp_length` is the width-explicit form. Both
/// cap the LENGTH (not the components) and keep the direction.
fn lua_vec2_clamped(L: ?*lua_State) callconv(.c) c_int {
    return lua_vec2_clamp_length(L);
}

const core_math = @import("core").math;

/// Installs every binding into `L`, closing each C function over `ctx` (a stable
/// pointer the caller owns). Builds the `actor`, `input` and `log` global tables
/// and stamps the entity bridge helpers the behavior layer uses.
///
/// The metadata gate runs here: `assertAllDocumented` is a comptime check that
/// the exact set of names registered below all have a `metadata.bindings` entry
/// (and vice versa). A new binding without metadata fails to compile.
/// The authoritative list of what this file registers, as fully-qualified Lua
/// names. ONE list, used twice: the comptime gate in `registerAll` (every name
/// must be documented) and the stub generator. Adding a binding means adding
/// one line here and one entry in `metadata.bindings`; nothing else can drift.
pub const registered_names = [_][]const u8{

    // actor
    "actor.get_position",        "actor.set_position",
    "actor.translate",           "actor.move_by",
    "actor.get_rotation",        "actor.set_rotation",
    "actor.get_name",            "actor.emit",
    "actor.get_half_size",       "actor.distance_to",
    "actor.distance_to_point",   "actor.distance_squared_to",
    "actor.is_within_radius",    "actor.is_within_radius_of_point",
    "actor.direction_to",        "actor.angle_to",
    // math
    "math.clamp",                "math.min",
    "math.max",                  "math.abs",
    "math.sign",                 "math.floor",
    "math.ceil",                 "math.round",
    "math.fract",                "math.sqrt",
    "math.pow",                  "math.sin",
    "math.cos",                  "math.atan2",
    "math.lerp",                 "math.inverse_lerp",
    "math.remap",                "math.smoothstep",
    "math.step",                 "math.move_toward",
    "math.damp",                 "math.wrap",
    "math.pingpong",             "math.deg_to_rad",
    "math.rad_to_deg",           "math.is_close",
    // vec2
    "vec2.new",                  "vec2.to_vec",
    "vec2.dist",                 "vec2.dist_sq",
    "vec2.length",               "vec2.length_sq",
    "vec2.normalized",           "vec2.direction",
    "vec2.lerp",                 "vec2.dot",
    "vec2.cross",                "vec2.angle",
    "vec2.angle_between",        "vec2.rotate",
    "vec2.perpendicular",        "vec2.clamp_length",
    "vec2.clamped",              "vec2.reflect",
    "vec2.from_angle",
    // input / log
              "input.is_action_pressed",
    "input.is_action_down",      "input.get_axis",
    "log.info",                  "log.warn",
    // rand / noise (M4.5)
    "rand.seed",                 "rand.float",
    "rand.range",                "rand.int",
    "rand.chance",               "rand.sign",
    "rand.gauss",                "rand.choice",
    "rand.shuffle",              "noise.seed",
    "noise.value",               "noise.perlin",
    "noise.simplex",             "noise.fbm",
    "noise.ridged",
    // state machines (M4.5)
                 "sm.add_state",
    "sm.add_transition",         "sm.set_initial",
    "sm.fire",                   "sm.set_state",
    "sm.state",                  "sm.is_in",
    // world (M4.5)
    "world.nearby",
    // physics (M4)
                 "physics.cast_ray",
    "physics.line_of_sight",
    "physics.stats",
    "physics.set_view",
    "physics.set_focus",
    "render.set_view",
    "render.stats",
    "render.set_resident",
    "render.all_resident",
    "material.new",
    "material.set_params",
    "material.get_params",
    "material.get_shader",
    "sprite.rect",
    "sprite.circle",
    "sprite.texture",
    "sprite.set_layer",
    "sprite.set_visible",
    "sprite.set_size",
    "sprite.set_tint",
    "sprite.set_uv",
    "sprite.set_atlas",
    "sprite.set_shape",
    "sprite.set_blend",
    "sprite.get_size",
    "sprite.get_tint",
    "actor.add_component",
    "actor.has_component",
    "actor.remove_component",
    "physics.create_shape",
    "physics.reshape",
    "physics.set_material",
    "physics.set_sensor",
    "physics.set_layers",
    "physics.set_body_type",
    "physics.set_body_enabled",
    "physics.overlap_rect",
    "physics.contains_point",     "actor.set_linear_velocity",
    "actor.get_linear_velocity", "actor.apply_impulse",
    "actor.is_awake",
};

pub fn registerAll(L: ?*lua_State, ctx: *Context) void {
    // The comptime gate: every name below must have a `metadata.bindings` entry
    // (the reverse direction is checked where the list itself is checked, see
    // `registered_names`' test).
    comptime metadata.assertAllDocumented(&registered_names);

    installModule(L, ctx, "actor", &actor_regs);
    installModule(L, ctx, "math", &math_regs);
    installModule(L, ctx, "vec2", &vec2_regs);
    installModule(L, ctx, "input", &input_regs);
    installModule(L, ctx, "log", &log_regs);
    installModule(L, ctx, "rand", &rand_regs);
    installModule(L, ctx, "noise", &noise_regs);
    installModule(L, ctx, "sm", &sm_regs);
    // Behind `-Dsteering`: `world.nearby` measures ~16 us per call, about 100x
    // what the grid should cost, and the cause is not yet known. Compiling the
    // table in by default would put that number inside the frame.
    if (build_options.steering) installModule(L, ctx, "world", &world_regs);
    installModule(L, ctx, "physics", &physics_regs);
    installModule(L, ctx, "render", &render_regs);
    installModule(L, ctx, "sprite", &sprite_regs);
    installModule(L, ctx, "material", &material_regs);
}

/// Creates the global table `name`, registers `regs` into it (each function
/// closed over `ctx`), and leaves the table as `_G.name`. The context pointer is
/// pushed as a light userdata upvalue so `ctxOf` can recover it per call with no
/// allocation and no global fetch.
/// Public because a test harness needs to install its own module with the same
/// upvalue convention. Registering a binding any other way (a bare `setFuncs`)
/// produces a function with no context upvalue, which panics on its first call —
/// so the seam is exported rather than reimplemented.
pub fn installModule(L: ?*lua_State, ctx: *Context, name: [*:0]const u8, regs: []const luaL_Reg) void {
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
