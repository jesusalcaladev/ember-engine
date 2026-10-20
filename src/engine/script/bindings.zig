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
// Module import, not a relative path — see build.zig's
// `script_mod.addImport("api_meta", ...)`.
const metadata = @import("api_meta");
const context_mod = @import("context.zig");
const tween_mod = @import("tween.zig");
const assets_mod = @import("assets");
const ecs = @import("ecs");

const lua_State = lua.lua_State;
const luaL_Reg = lua.luaL_Reg;

/// The shared engine state every binding reaches through its upvalue.
pub const Context = context_mod.Context;

/// Short alias for the Transform component the actor bindings read/write.
const Transform = context_mod.Transform;
/// And for the Sprite, which `get_half_size` reads (the collision-style half
/// extents of what is drawn).
const Sprite = context_mod.components.Sprite;
const components = context_mod.components;
const core_math = @import("core").math;
const ShaderMaterial = context_mod.components.ShaderMaterial;
/// The M8 emitter component the `sound.*` bindings read and write.
const SoundEmitter2D = components.SoundEmitter2D;

// The layout pin `ecs/components/sound_emitter.zig` promises.
//
// The component cannot import `audio` (ecs is the module everything imports,
// and `audio` drags in a device, a decoder and a C translation unit), so the
// voice handle is declared twice: once in `ecs` as `VoiceRef`, once in `audio`
// as `VoiceId`. This is the ONE file that sees both, so the assertion that
// they are the same two `u32`s in the same order lives here — and if either
// side ever drifts, this fails to compile instead of a component silently
// holding a handle the mixer misreads.
comptime {
    if (@sizeOf(components.VoiceRef) != @sizeOf(VoiceId) or
        @offsetOf(components.VoiceRef, "index") != @offsetOf(VoiceId, "index") or
        @offsetOf(components.VoiceRef, "generation") != @offsetOf(VoiceId, "generation"))
    {
        @compileError("ecs.components.VoiceRef and audio.VoiceId must be field-for-field identical");
    }
    if (@sizeOf(components.SoundEmitter2D) > 128) {
        @compileError("SoundEmitter2D outgrew the .zson decode buffer (max_stride)");
    }
}

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

/// `actor.set_transform(self, x, y, rot?, scale?)` — the batch write.
///
/// One call where the naive spelling is three, and each binding is ~145 ns of
/// LuaJIT dispatch (spec §2): a spawn, a teleport and a reset-to-default all
/// write the same triple, so they pay for it three times. Rotation and scale
/// are OPTIONAL and keep their current value when omitted, because a spawn
/// usually means "put it here, facing where it faced".
///
/// `prev_*` is deliberately NOT written: the fixed tick calls
/// `capturePrevious`, and a script that stamped the previous snapshot itself
/// would make the renderer interpolate from a point the simulation never
/// occupied. A teleport therefore interpolates across one tick, which is what
/// §3.3 says it should do.
fn lua_actor_set_transform(L: ?*lua_State) callconv(.c) c_int {
    const ctx = ctxOf(L);
    const entity = entityOf(L, 1) orelse return 0;
    const t = ctx.world.get(entity, Transform) orelse return 0;
    t.position = .{ .x = lua.toF32(L, 2), .y = lua.toF32(L, 3) };
    if (lua.getTop(L) >= 4) t.rotation = lua.toF32(L, 4);
    if (lua.getTop(L) >= 5) {
        const s = lua.toF32(L, 5);
        t.scale = .{ .x = s, .y = s };
    }
    return 0;
}

/// `actor.get_all(self) -> table` — the batch read: every component this actor
/// carries, as nested tables.
///
/// Why one table and not N getters: the same reason `light.describe` exists. An
/// inspector, a save system and a debug overlay all want "what is on this
/// actor", and a getter per field means the field list lives in two places and
/// drifts. A component that is absent is an ABSENT KEY rather than a zeroed
/// stub — "no sprite" and "a sprite at the origin" are different facts, and
/// collapsing them is how a tool ends up drawing an invisible sprite.
///
/// `transform.position` is a `{x, y}` table, the same shape `vec2.new` returns,
/// so a caller can hand one straight back to `vec2.*`.
fn lua_actor_get_all(L: ?*lua_State) callconv(.c) c_int {
    const ctx = ctxOf(L);
    const e = entityOf(L, 1) orelse {
        lua.lua_createtable(L, 0, 0);
        return 1;
    };
    lua.lua_createtable(L, 0, 3);

    if (ctx.world.get(e, Transform)) |t| {
        lua.lua_createtable(L, 0, 3);
        pushVec2(L, t.position);
        lua.setField(L, -2, "position");
        pushVec2(L, t.scale);
        lua.setField(L, -2, "scale");
        lua.pushF32(L, t.rotation);
        lua.setField(L, -2, "rotation");
        lua.setField(L, -2, "transform");
    }
    if (ctx.world.get(e, Sprite)) |s| {
        lua.lua_createtable(L, 0, 8);
        pushVec2(L, s.size);
        lua.setField(L, -2, "size");
        lua.lua_createtable(L, 0, 4);
        for (s.uv, 0..) |c, i| {
            lua.pushF32(L, c);
            lua.lua_rawseti(L, -2, @intCast(i + 1));
        }
        lua.setField(L, -2, "uv");
        lua.lua_createtable(L, 0, 4);
        for (s.tint, 0..) |c, i| {
            lua.pushF32(L, c);
            lua.lua_rawseti(L, -2, @intCast(i + 1));
        }
        lua.setField(L, -2, "tint");
        lua.pushF32(L, @floatFromInt(s.atlas));
        lua.setField(L, -2, "atlas");
        lua.pushF32(L, @floatFromInt(s.layer));
        lua.setField(L, -2, "layer");
        lua.pushF32(L, @floatFromInt(@intFromEnum(s.blend)));
        lua.setField(L, -2, "blend");
        lua.pushF32(L, @floatFromInt(@intFromEnum(s.shape)));
        lua.setField(L, -2, "shape");
        lua.lua_pushboolean(L, @intFromBool(s.visible));
        lua.setField(L, -2, "visible");
        lua.setField(L, -2, "sprite");
    }
    if (ctx.world.get(e, components.Name)) |n| {
        lua.pushSlice(L, n.slice());
        lua.setField(L, -2, "name");
    }
    if (ctx.world.get(e, SoundEmitter2D)) |em| {
        lua.lua_createtable(L, 0, 6);
        lua.pushF32(L, @floatFromInt(em.bank_slot));
        lua.setField(L, -2, "bank_slot");
        lua.pushF32(L, @floatFromInt(em.bus));
        lua.setField(L, -2, "bus");
        lua.pushF32(L, em.volume);
        lua.setField(L, -2, "volume");
        lua.pushF32(L, em.pitch);
        lua.setField(L, -2, "pitch");
        lua.lua_pushboolean(L, @intFromBool(em.loop));
        lua.setField(L, -2, "loop");
        lua.lua_pushboolean(L, @intFromBool(em.autoplay));
        lua.setField(L, -2, "autoplay");
        lua.setField(L, -2, "sound");
    }
    return 1;
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

/// `pointer_over_ui() -> boolean` — true while the pointer is over an
/// interactive game-UI widget. Gameplay checks this so a click on a button
/// cannot also be a world action (spec M14: "the UI never leaks input to the
/// world"). Filled each frame by the runtime from the UI system.
fn lua_input_pointer_over_ui(L: ?*lua_State) callconv(.c) c_int {
    const ctx = ctxOf(L);
    return pushBool(L, ctx.input.pointerOverUi());
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

// ── globals: the mounted global scripts (singleton access) ──────────────────
// A global script (one mounted with no actor — the game manager, the score,
// the spawner) is the one piece of Lua game state every OTHER script should be
// able to reach, the way Godot's autoloads work. The surface is two reads:
// `get` hands back the global's `self` table (method calls and field writes
// go straight through it) and `exists` answers "is this one mounted" without
// pushing anything. There is no reflection API on purpose: a global is not a
// service locator, it is one instance per script, resolved by name.

/// `globals.get(name) -> self_table | nil`.
fn lua_globals_get(L: ?*lua_State) callconv(.c) c_int {
    const ctx = ctxOf(L);
    const name = lua.toString(L, 1);
    if (ctx.globals) |hooks| {
        if (hooks.push_self(hooks.ctx, L, name)) return 1;
    }
    // Not mounted (no globals wired, or no global with this name): nil, not an
    // error. Time is a perfectly good answer for "flow hasn't bootstrapped it
    // yet" — a behavior can write `local game = globals.get("game")` and take
    // the nil branch once, at startup.
    lua.pushNil(L);
    return 1;
}

/// `globals.exists(name) -> boolean`.
fn lua_globals_exists(L: ?*lua_State) callconv(.c) c_int {
    const ctx = ctxOf(L);
    const name = lua.toString(L, 1);
    const mounted = if (ctx.globals) |hooks| hooks.exists(hooks.ctx, name) else false;
    lua.lua_pushboolean(L, @intFromBool(mounted));
    return 1;
}

const globals_regs = [_]luaL_Reg{
    .{ .name = "get", .func = lua_globals_get },
    .{ .name = "exists", .func = lua_globals_exists },
    .{ .name = null, .func = null },
};

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
/// `actor.entity_bits(self) -> number` — this actor's handle as a number.
///
/// The handle is what a signal payload carries: the physics publishes the
/// entities involved in a collision, and a script matches them against its own
/// with this number. It is also how a script keeps a reference to another
/// actor in a plain field (see `actor.from_entity`).
fn lua_actor_entity_bits(L: ?*lua_State) callconv(.c) c_int {
    const e = entityOf(L, 1) orelse return 0;
    lua.lua_pushinteger(L, @intCast(@as(u64, @bitCast(e))));
    return 1;
}

/// `actor.from_entity(bits) -> actor|nil` — the actor a handle names.
///
/// The inverse of `actor.entity_bits`: it builds a table stamped with the
/// handle, so the result can be passed to every other `actor.*` function.
/// Nil when the handle names no live entity — a despawned actor, or a handle
/// from another world.
fn lua_actor_from_entity(L: ?*lua_State) callconv(.c) c_int {
    const ctx = ctxOf(L);
    const bits: u64 = @bitCast(lua.toInteger(L, 1));
    const e: context_mod.Entity = @bitCast(bits);
    if (!ctx.world.isAlive(e)) {
        lua.pushNil(L);
        return 1;
    }
    lua.lua_createtable(L, 0, 1); // [T]
    stampEntity(L, e);
    return 1;
}

const actor_regs = [_]luaL_Reg{
    .{ .name = "entity_bits", .func = lua_actor_entity_bits },
    .{ .name = "from_entity", .func = lua_actor_from_entity },
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
    // The batch pair: one call to write position+rotation+scale, one to read
    // every component back. Both exist because of the measured per-binding cost
    // (spec §2), and both are documented in `metadata.zig` like everything else
    // this table hands to Lua.
    .{ .name = "set_transform", .func = lua_actor_set_transform },
    .{ .name = "get_all", .func = lua_actor_get_all },

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
    // The optional fifth argument is a LAYER mask: only the actors whose
    // `CollisionLayers.layer` is in the mask are returned. Without it the
    // query answers "what is in this box", and with it it answers "what is
    // in this box THAT I CARE ABOUT" — which is the question an area or a
    // trigger asks.
    const mask: u64 = if (lua.getTop(L) >= 5) @bitCast(lua.toInteger(L, 5)) else 0;
    const total = if (mask != 0)
        sys.overlapEntitiesMasked(ctx.world, box, mask, &overlap_scratch)
    else
        sys.overlapEntities(box, &overlap_scratch);

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

// ── Physics Debug ─────────────────────────────────────────────────────────────
//
//PHYSDBG-PARKED // Debug visualization of collision shapes, contacts, and other physics internals.
//PHYSDBG-PARKED // Intended for editor use only.
//PHYSDBG-PARKED 
//PHYSDBG-PARKED /// `physics.debug_draw(enabled?) -> boolean`
//PHYSDBG-PARKED fn lua_physics_debug_draw(L: ?*lua_State) callconv(.c) c_int {
//PHYSDBG-PARKED     const ctx = ctxOf(L);
//PHYSDBG-PARKED     const debug = ctx.physics_debug orelse return 0;
//PHYSDBG-PARKED     if (lua.getTop(L) >= 1) {
//PHYSDBG-PARKED         debug.enabled = lua.toBool(L, 1);
//PHYSDBG-PARKED     } else {
//PHYSDBG-PARKED         debug.enabled = !debug.enabled;
//PHYSDBG-PARKED     }
//PHYSDBG-PARKED     lua.lua_pushboolean(L, @intFromBool(debug.enabled));
//PHYSDBG-PARKED     return 1;
//PHYSDBG-PARKED }
//PHYSDBG-PARKED 
//PHYSDBG-PARKED /// `physics.debug_flags(flags?) -> integer`
//PHYSDBG-PARKED fn lua_physics_debug_flags(L: ?*lua_State) callconv(.c) c_int {
//PHYSDBG-PARKED     const ctx = ctxOf(L);
//PHYSDBG-PARKED     const debug = ctx.physics_debug orelse return 0;
//PHYSDBG-PARKED     if (lua.getTop(L) >= 1) {
//PHYSDBG-PARKED         const raw = lua.toInteger(L, 1);
//PHYSDBG-PARKED         debug.flags = @bitCast(@as(u32, raw));
//PHYSDBG-PARKED     } else {
//PHYSDBG-PARKED         lua.pushInteger(L, @intCast(debug.flags));
//PHYSDBG-PARKED         return 1;
//PHYSDBG-PARKED     }
//PHYSDBG-PARKED     return 0;
//PHYSDBG-PARKED }
//PHYSDBG-PARKED 
//PHYSDBG-PARKED /// `physics.debug_colors(table?) -> table`
//PHYSDBG-PARKED fn lua_physics_debug_colors(L: ?*lua_State) callconv(.c) c_int {
//PHYSDBG-PARKED     const ctx = ctxOf(L);
//PHYSDBG-PARKED     const debug = ctx.physics_debug orelse return 0;
//PHYSDBG-PARKED     if (lua.getTop(L) >= 1 and lua.isTable(L, 1)) {
//PHYSDBG-PARKED         lua.getField(L, 1, "solid_static"); if (!lua.isNil(L, -1)) { debug.colors.solid_static = parseColor(L, -1); } lua.pop(L, 1);
//PHYSDBG-PARKED         lua.getField(L, 1, "solid_kinematic"); if (!lua.isNil(L, -1)) { debug.colors.solid_kinematic = parseColor(L, -1); } lua.pop(L, 1);
//PHYSDBG-PARKED         lua.getField(L, 1, "solid_dynamic"); if (!lua.isNil(L, -1)) { debug.colors.solid_dynamic = parseColor(L, -1); } lua.pop(L, 1);
//PHYSDBG-PARKED         lua.getField(L, 1, "sensor"); if (!lua.isNil(L, -1)) { debug.colors.sensor = parseColor(L, -1); } lua.pop(L, 1);
//PHYSDBG-PARKED         lua.getField(L, 1, "one_way"); if (!lua.isNil(L, -1)) { debug.colors.one_way = parseColor(L, -1); } lua.pop(L, 1);
//PHYSDBG-PARKED         lua.getField(L, 1, "tilemap_solid"); if (!lua.isNil(L, -1)) { debug.colors.tilemap_solid = parseColor(L, -1); } lua.pop(L, 1);
//PHYSDBG-PARKED         lua.getField(L, 1, "tilemap_sensor"); if (!lua.isNil(L, -1)) { debug.colors.tilemap_sensor = parseColor(L, -1); } lua.pop(L, 1);
//PHYSDBG-PARKED         lua.getField(L, 1, "tilemap_oneway"); if (!lua.isNil(L, -1)) { debug.colors.tilemap_oneway = parseColor(L, -1); } lua.pop(L, 1);
//PHYSDBG-PARKED         lua.getField(L, 1, "broadphase_aabb"); if (!lua.isNil(L, -1)) { debug.colors.broadphase_aabb = parseColor(L, -1); } lua.pop(L, 1);
//PHYSDBG-PARKED         lua.getField(L, 1, "shape_aabb"); if (!lua.isNil(L, -1)) { debug.colors.shape_aabb = parseColor(L, -1); } lua.pop(L, 1);
//PHYSDBG-PARKED         lua.getField(L, 1, "contact_point"); if (!lua.isNil(L, -1)) { debug.colors.contact_point = parseColor(L, -1); } lua.pop(L, 1);
//PHYSDBG-PARKED         lua.getField(L, 1, "contact_normal"); if (!lua.isNil(L, -1)) { debug.colors.contact_normal = parseColor(L, -1); } lua.pop(L, 1);
//PHYSDBG-PARKED         lua.getField(L, 1, "center_of_mass"); if (!lua.isNil(L, -1)) { debug.colors.center_of_mass = parseColor(L, -1); } lua.pop(L, 1);
//PHYSDBG-PARKED     } else {
//PHYSDBG-PARKED         lua.lua_createtable(L, 0, 13);
//PHYSDBG-PARKED         pushColor(L, "solid_static", debug.colors.solid_static); lua.setField(L, -2, "solid_static");
//PHYSDBG-PARKED         pushColor(L, "solid_kinematic", debug.colors.solid_kinematic); lua.setField(L, -2, "solid_kinematic");
//PHYSDBG-PARKED         pushColor(L, "solid_dynamic", debug.colors.solid_dynamic); lua.setField(L, -2, "solid_dynamic");
//PHYSDBG-PARKED         pushColor(L, "sensor", debug.colors.sensor); lua.setField(L, -2, "sensor");
//PHYSDBG-PARKED         pushColor(L, "one_way", debug.colors.one_way); lua.setField(L, -2, "one_way");
//PHYSDBG-PARKED         pushColor(L, "tilemap_solid", debug.colors.tilemap_solid); lua.setField(L, -2, "tilemap_solid");
//PHYSDBG-PARKED         pushColor(L, "tilemap_sensor", debug.colors.tilemap_sensor); lua.setField(L, -2, "tilemap_sensor");
//PHYSDBG-PARKED         pushColor(L, "tilemap_oneway", debug.colors.tilemap_oneway); lua.setField(L, -2, "tilemap_oneway");
//PHYSDBG-PARKED         pushColor(L, "broadphase_aabb", debug.colors.broadphase_aabb); lua.setField(L, -2, "broadphase_aabb");
//PHYSDBG-PARKED         pushColor(L, "shape_aabb", debug.colors.shape_aabb); lua.setField(L, -2, "shape_aabb");
//PHYSDBG-PARKED         pushColor(L, "contact_point", debug.colors.contact_point); lua.setField(L, -2, "contact_point");
//PHYSDBG-PARKED         pushColor(L, "contact_normal", debug.colors.contact_normal); lua.setField(L, -2, "contact_normal");
//PHYSDBG-PARKED         pushColor(L, "center_of_mass", debug.colors.center_of_mass); lua.setField(L, -2, "center_of_mass");
//PHYSDBG-PARKED         return 1;
//PHYSDBG-PARKED     }
//PHYSDBG-PARKED     return 0;
//PHYSDBG-PARKED }

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
    } else if (std.mem.eql(u8, name, "SoundEmitter2D")) {
        // M8: the emitter is plain data (a bank slot, a bus, a gain), so adding
        // one from the inspector is safe and needs no system call.
        if (ctx.world.get(e, SoundEmitter2D) != null) return pushFalse(L);
        _ = ctx.world.add(e, SoundEmitter2D{}) catch return pushFalse(L);
    } else if (std.mem.eql(u8, name, "UiCanvas")) {
        // M14: the UI widgets are plain data too. Adding one starts from the
        // component defaults (a 100x30 top-left box), which `ui.*` then styles.
        if (ctx.world.get(e, components.UiCanvas) != null) return pushFalse(L);
        _ = ctx.world.add(e, components.UiCanvas{}) catch return pushFalse(L);
    } else if (std.mem.eql(u8, name, "Label")) {
        if (ctx.world.get(e, components.Label) != null) return pushFalse(L);
        _ = ctx.world.add(e, components.Label{}) catch return pushFalse(L);
    } else if (std.mem.eql(u8, name, "UiButton")) {
        if (ctx.world.get(e, components.UiButton) != null) return pushFalse(L);
        _ = ctx.world.add(e, components.UiButton{}) catch return pushFalse(L);
    } else if (std.mem.eql(u8, name, "UiPanel")) {
        if (ctx.world.get(e, components.UiPanel) != null) return pushFalse(L);
        _ = ctx.world.add(e, components.UiPanel{}) catch return pushFalse(L);
    } else if (std.mem.eql(u8, name, "UiProgressBar")) {
        if (ctx.world.get(e, components.UiProgressBar) != null) return pushFalse(L);
        _ = ctx.world.add(e, components.UiProgressBar{}) catch return pushFalse(L);
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
    else if (std.mem.eql(u8, name, "SoundEmitter2D"))
        ctx.world.get(e, SoundEmitter2D) != null
    else if (std.mem.eql(u8, name, "UiCanvas"))
        ctx.world.get(e, components.UiCanvas) != null
    else if (std.mem.eql(u8, name, "Label"))
        ctx.world.get(e, components.Label) != null
    else if (std.mem.eql(u8, name, "UiButton"))
        ctx.world.get(e, components.UiButton) != null
    else if (std.mem.eql(u8, name, "UiPanel"))
        ctx.world.get(e, components.UiPanel) != null
    else if (std.mem.eql(u8, name, "UiProgressBar"))
        ctx.world.get(e, components.UiProgressBar) != null
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
    else if (std.mem.eql(u8, name, "SoundEmitter2D"))
        ctx.world.remove(e, SoundEmitter2D)
    else if (std.mem.eql(u8, name, "UiCanvas"))
        ctx.world.remove(e, components.UiCanvas)
    else if (std.mem.eql(u8, name, "Label"))
        ctx.world.remove(e, components.Label)
    else if (std.mem.eql(u8, name, "UiButton"))
        ctx.world.remove(e, components.UiButton)
    else if (std.mem.eql(u8, name, "UiPanel"))
        ctx.world.remove(e, components.UiPanel)
    else if (std.mem.eql(u8, name, "UiProgressBar"))
        ctx.world.remove(e, components.UiProgressBar)
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

/// Side of the sprite atlas, in texels. 2048² RGBA8 is 16 MB, the M6 budget for
/// one page. A constant so the Lua path and the atlas cannot drift apart.
const atlas_side: u32 = 2048;

/// `sprite.set_image(self, path)` — loads image, packs it, sets texture slot + UV.
///
/// Three things this call gets right and one it deliberately does not:
///
/// - **One atlas for the whole context.** The manager lives on the `Context`
///   (`ctx.atlas_manager`) and is created on first use. The previous version
///   built a fresh 2048×2048 packer — and, through the upload, a fresh GPU
///   texture — on EVERY call, so a scene that set a hundred sprites leaked a
///   hundred atlases and every sprite but the last drew from a texture nothing
///   had ever uploaded.
/// - **The texture SLOT, not the asset slot.** A sprite's `atlas` field indexes
///   the renderer's texture table, which is what `emitInstancedDraw` looks up.
///   The old code stored the ASSET manager's slot — the right number for a
///   different table, which agreed with the right one only by accident on the
///   first call.
/// - **A reload-safe update.** `updateImageInAtlas` re-blits in place when the
///   image is already packed, so setting the same path twice is free and does not
///   leak the interning of the path; `refreshAtlas` writes into the page's
///   EXISTING texture instead of allocating a second one, which is what keeps the
///   slot a sprite already stored valid across a hot reload.
///
/// It does NOT re-pack on a size change behind the sprite's back: `updateImageInAtlas`
/// returns the new UVs when the image was resized, and this call applies them to
/// the sprite it was given. Every OTHER sprite that shared the image keeps the old
/// UVs — they are re-pointed by the runtime's `asset_reload` hook, which sees the
/// same event.
fn lua_sprite_set_image(L: ?*lua_State) callconv(.c) c_int {
    const ctx = ctxOf(L);
    const renderer = ctx.renderer orelse {
        lua.lua_pushnil(L);
        lua.lua_pushstring(L, "renderer not initialized");
        return 2;
    };
    const am = ctx.assets orelse {
        lua.lua_pushnil(L);
        lua.lua_pushstring(L, "assets system not initialized");
        return 2;
    };
    const path = lua.toSlice(L, 2) orelse {
        lua.lua_pushnil(L);
        lua.lua_pushstring(L, "path must be a string");
        return 2;
    };
    const slot = am.getOrLoad(path) catch |err| {
        lua.lua_pushnil(L);
        lua.lua_pushstring(L, @errorName(err));
        return 2;
    };
    const payload = am.get(assets_mod.AssetHandle{ .id = slot, .generation = 0 }) orelse {
        lua.lua_pushnil(L);
        lua.lua_pushstring(L, "asset not loaded");
        return 2;
    };
    const image = @as(*const assets_mod.Image, @ptrCast(@alignCast(payload)));

    // 2048×2048 RGBA8 is 16 MB, which is the budget the atlas was sized for.
    // Created lazily so a script that never sets an image never pays for it.
    const atlas_mgr = ctx.atlas_manager orelse created: {
        const created = renderer.createAtlasManager(atlas_side, atlas_side) orelse {
            lua.lua_pushnil(L);
            lua.lua_pushstring(L, "failed to create atlas manager");
            return 2;
        };
        ctx.atlas_manager = created;
        break :created created;
    };

    const update = renderer.updateImageInAtlas(atlas_mgr, path, image.width, image.height, image.pixels) orelse {
        lua.lua_pushnil(L);
        lua.lua_pushstring(L, "failed to pack image into the atlas");
        return 2;
    };
    const texture = renderer.refreshAtlas(atlas_mgr) orelse {
        lua.lua_pushnil(L);
        lua.lua_pushstring(L, "failed to upload the atlas");
        return 2;
    };

    // Register the path for hot reload NOW, while we know the image is live.
    // This is the only moment anything learns that the atlas holds `path`:
    // `HotReload.reloadPath` re-checks paths it was TOLD to watch and cannot
    // discover them, so a sprite set here would otherwise never reload.
    //
    // `watch` seeds a content hash, which is one read of a file this call has
    // just decoded — a real cost, paid once per image, and the alternative (a
    // first edit counted as a change) is worse. It allocates the path copy, so a
    // runtime that calls this from inside a guarded frame will trip that guard on
    // the load itself long before it reaches here; the honest place to set images
    // is a preload, and the guard then stays armed for the frames that matter.
    if (ctx.hot_reload) |hot| hot.watch(path) catch |err| {
        // Not fatal: the sprite is packed and will draw. It just will not reload
        // until it is set again, so it is worth a line in the log rather than a
        // silent miss.
        core_log.warn("could not watch '{s}' for reload: {s}", .{ path, @errorName(err) });
    };

    const sprite = spriteOf(L) orelse return 0;
    // The handle is an index + 1 (0 means "none"), so the slot is the raw value
    // minus one. The cast is checked rather than truncating: a 256th texture is a
    // real limit of the `u8` field, and silently wrapping it would draw a
    // different texture rather than reporting the overflow.
    const texture_index = @intFromPtr(texture) - 1;
    if (texture_index > std.math.maxInt(u8)) {
        lua.lua_pushnil(L);
        lua.lua_pushstring(L, "atlas texture table is full");
        return 2;
    }
    sprite.atlas = @intCast(texture_index);
    sprite.uv = update.uv;
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

// ── Game UI (M14) ────────────────────────────────────────────────────────────
//
// `ui.*` styles an actor's WIDGET component. It is a setter API over plain-data
// components, the same shape as `sprite.*` and `sound.*`: `ui.set_text` writes
// the label's bytes, `ui.set_anchor` writes the layout, and the per-frame
// system — which runs in Zig, never in Lua — turns those fields into quads. No
// node tree, no allocation, and nothing here touches the GPU.
//
// The one thing that is NOT a component write is the query half (`measure`,
// `font_load`, `hovered`, `pressed`): those need the glyph rasterizer and the
// frame's resolved state, which live in the runtime, so they cross through the
// `Context.ui` vtable (see `context.UiHooks`).

/// The widget layout of the entity in argument 1, whichever widget kind it
/// carries, or null when the actor has no widget component. Precedence matches
/// `ui_system.gather` (button, panel, bar, label) so a malformed entity lays out
/// and draws the same way.
fn uiLayoutOf(L: ?*lua_State) ?*components.UiLayout {
    const ctx = ctxOf(L);
    const e = entityOf(L, 1) orelse return null;
    if (ctx.world.get(e, components.UiButton)) |b| return &b.layout;
    if (ctx.world.get(e, components.UiPanel)) |p| return &p.layout;
    if (ctx.world.get(e, components.UiProgressBar)) |p| return &p.layout;
    if (ctx.world.get(e, components.Label)) |l| return &l.layout;
    return null;
}

/// The font id of a widget, 0 when it has none. Only the three text-bearing
/// widgets carry one.
fn uiFontOf(ctx: *Context, e: context_mod.Entity) u32 {
    if (ctx.world.get(e, components.UiButton)) |b| return b.font;
    if (ctx.world.get(e, components.UiProgressBar)) |p| return p.font;
    if (ctx.world.get(e, components.Label)) |l| return l.font;
    return 0;
}

/// Reads a `{ r, g, b, a }` ARRAY at `idx` into `out`. `a` defaults to 1 when
/// the array has only three entries, and every component is clamped to 0..1.
/// False (and `out` untouched) when `idx` is not a table, so a nil colour
/// argument is a no-op rather than a black flash.
fn readColor(L: ?*lua_State, idx: c_int, out: *[4]f32) bool {
    if (!lua.isTable(L, idx)) return false;
    var c: [4]f32 = .{ 0, 0, 0, 1 };
    var i: usize = 0;
    while (i < 4) : (i += 1) {
        lua.lua_rawgeti(L, idx, @intCast(i + 1));
        // A missing 4th entry reads as nil; `toF32` would call it 0, so the
        // "alpha omitted means opaque" case is handled explicitly.
        if (!(i == 3 and lua.isNil(L, -1))) c[i] = lua.toF32(L, -1);
        lua.pop(L, 1);
    }
    out.* = .{
        std.math.clamp(c[0], 0, 1),
        std.math.clamp(c[1], 0, 1),
        std.math.clamp(c[2], 0, 1),
        std.math.clamp(c[3], 0, 1),
    };
    return true;
}

/// `ui.set_anchor(self, anchor)` — one of the twelve preset names: top_left,
/// top_center, top_right, middle_left, center, middle_right, bottom_left,
/// bottom_center, bottom_right, stretch_h, stretch_v, full_rect.
fn lua_ui_set_anchor(L: ?*lua_State) callconv(.c) c_int {
    const layout = uiLayoutOf(L) orelse return 0;
    const name = lua.toSlice(L, 2) orelse return 0;
    layout.anchor = std.meta.stringToEnum(components.UiAnchor, name) orelse return 0;
    return 0;
}

/// `ui.set_offset(self, x, y)` — displacement from the resolved anchor point.
fn lua_ui_set_offset(L: ?*lua_State) callconv(.c) c_int {
    const layout = uiLayoutOf(L) orelse return 0;
    layout.offset = .{ .x = lua.toF32(L, 2), .y = lua.toF32(L, 3) };
    return 0;
}

/// `ui.set_size(self, w, h)` — widget size in canvas pixels (ignored by the
/// axis a stretch preset fills).
fn lua_ui_set_size(L: ?*lua_State) callconv(.c) c_int {
    const layout = uiLayoutOf(L) orelse return 0;
    layout.size = .{ .x = lua.toF32(L, 2), .y = lua.toF32(L, 3) };
    return 0;
}

/// `ui.set_pivot(self, x, y)` — 0,0 puts the widget's top-left on the anchor,
/// 0.5,0.5 centres it.
fn lua_ui_set_pivot(L: ?*lua_State) callconv(.c) c_int {
    const layout = uiLayoutOf(L) orelse return 0;
    layout.pivot = .{ .x = lua.toF32(L, 2), .y = lua.toF32(L, 3) };
    return 0;
}

/// `ui.set_margin(self, top, right, bottom, left)` — the insets the stretch
/// presets use. Ignored by the nine point presets.
fn lua_ui_set_margin(L: ?*lua_State) callconv(.c) c_int {
    const layout = uiLayoutOf(L) orelse return 0;
    layout.margin = .{
        lua.toF32(L, 2),
        lua.toF32(L, 3),
        lua.toF32(L, 4),
        lua.toF32(L, 5),
    };
    return 0;
}

/// `ui.set_order(self, order)` — the paint and hit-test tie-break. Higher draws
/// later and wins a click.
fn lua_ui_set_order(L: ?*lua_State) callconv(.c) c_int {
    const layout = uiLayoutOf(L) orelse return 0;
    layout.order = @intFromFloat(lua.toF32(L, 2));
    return 0;
}

/// `ui.set_visible(self, visible)` — whether the widget is drawn.
fn lua_ui_set_visible(L: ?*lua_State) callconv(.c) c_int {
    const layout = uiLayoutOf(L) orelse return 0;
    layout.visible = lua.toBool(L, 2);
    return 0;
}

/// `ui.set_interactive(self, interactive)` — whether the widget blocks world
/// input and can be hovered/clicked. Labels and bars never capture regardless.
fn lua_ui_set_interactive(L: ?*lua_State) callconv(.c) c_int {
    const layout = uiLayoutOf(L) orelse return 0;
    layout.interactive = lua.toBool(L, 2);
    return 0;
}

/// `ui.set_text(self, text)` — the widget's string (label, button caption, bar
/// text). Truncated silently at 128 bytes, like every inline text here.
fn lua_ui_set_text(L: ?*lua_State) callconv(.c) c_int {
    const ctx = ctxOf(L);
    const e = entityOf(L, 1) orelse return 0;
    const text = lua.toSlice(L, 2) orelse return 0;
    if (ctx.world.get(e, components.UiButton)) |b| {
        b.text.set(text);
        return 0;
    }
    if (ctx.world.get(e, components.UiProgressBar)) |p| {
        p.text.set(text);
        return 0;
    }
    if (ctx.world.get(e, components.Label)) |l| {
        l.text.set(text);
        return 0;
    }
    return 0;
}

/// `ui.set_font(self, id)` — which font the text uses; 0 is the engine default,
/// any other id comes from `ui.font_load`.
fn lua_ui_set_font(L: ?*lua_State) callconv(.c) c_int {
    const ctx = ctxOf(L);
    const e = entityOf(L, 1) orelse return 0;
    const id: u32 = @truncate(@as(u32, @intFromFloat(@max(lua.toF32(L, 2), 0))));
    if (ctx.world.get(e, components.UiButton)) |b| {
        b.font = id;
        return 0;
    }
    if (ctx.world.get(e, components.UiProgressBar)) |p| {
        p.font = id;
        return 0;
    }
    if (ctx.world.get(e, components.Label)) |l| {
        l.font = id;
        return 0;
    }
    return 0;
}

/// `ui.set_color(self, r, g, b, a)` — the widget's primary colour: a label's
/// text, a panel's fill, a button's caption, a bar's fill.
fn lua_ui_set_color(L: ?*lua_State) callconv(.c) c_int {
    const ctx = ctxOf(L);
    const e = entityOf(L, 1) orelse return 0;
    const rgba = [4]f32{ lua.toF32(L, 2), lua.toF32(L, 3), lua.toF32(L, 4), lua.toF32(L, 5) };
    if (ctx.world.get(e, components.Label)) |l| {
        l.color = rgba;
        return 0;
    }
    if (ctx.world.get(e, components.UiPanel)) |p| {
        p.color = rgba;
        return 0;
    }
    if (ctx.world.get(e, components.UiButton)) |b| {
        b.text_color = rgba;
        return 0;
    }
    if (ctx.world.get(e, components.UiProgressBar)) |p| {
        p.fill_color = rgba;
        return 0;
    }
    return 0;
}

/// `ui.set_colors(self, normal, hover, pressed, text)` — a button's four
/// colours, each a `{r, g, b, a}` table. A nil table leaves that colour alone.
fn lua_ui_set_colors(L: ?*lua_State) callconv(.c) c_int {
    const ctx = ctxOf(L);
    const e = entityOf(L, 1) orelse return 0;
    const b = ctx.world.get(e, components.UiButton) orelse return 0;
    var c: [4]f32 = undefined;
    if (readColor(L, 2, &c)) b.color_normal = c;
    if (readColor(L, 3, &c)) b.color_hover = c;
    if (readColor(L, 4, &c)) b.color_pressed = c;
    if (readColor(L, 5, &c)) b.text_color = c;
    return 0;
}

/// `ui.set_border(self, r, g, b, a, width)` — a panel's outline. Zero width (or
/// zero alpha) draws none.
fn lua_ui_set_border(L: ?*lua_State) callconv(.c) c_int {
    const ctx = ctxOf(L);
    const e = entityOf(L, 1) orelse return 0;
    const p = ctx.world.get(e, components.UiPanel) orelse return 0;
    p.border_color = .{ lua.toF32(L, 2), lua.toF32(L, 3), lua.toF32(L, 4), lua.toF32(L, 5) };
    p.border_width = @max(lua.toF32(L, 6), 0);
    return 0;
}

/// `ui.set_show_text(self, show)` — whether a progress bar draws its text.
fn lua_ui_set_show_text(L: ?*lua_State) callconv(.c) c_int {
    const ctx = ctxOf(L);
    const e = entityOf(L, 1) orelse return 0;
    const p = ctx.world.get(e, components.UiProgressBar) orelse return 0;
    p.show_text = lua.toBool(L, 2);
    return 0;
}

/// `ui.set_value(self, value)` — a progress bar's fill, clamped to 0..1.
fn lua_ui_set_value(L: ?*lua_State) callconv(.c) c_int {
    const ctx = ctxOf(L);
    const e = entityOf(L, 1) orelse return 0;
    const p = ctx.world.get(e, components.UiProgressBar) orelse return 0;
    p.value = std.math.clamp(lua.toF32(L, 2), 0, 1);
    return 0;
}

/// `ui.set_align(self, align)` — a label's horizontal alignment: "left",
/// "center" or "right".
fn lua_ui_set_align(L: ?*lua_State) callconv(.c) c_int {
    const ctx = ctxOf(L);
    const e = entityOf(L, 1) orelse return 0;
    const l = ctx.world.get(e, components.Label) orelse return 0;
    const name = lua.toSlice(L, 2) orelse return 0;
    l.alignment = std.meta.stringToEnum(components.TextAlign, name) orelse return 0;
    return 0;
}

/// `ui.set_enabled(self, enabled)` — a button's enabled flag. A disabled button
/// is inert: no hover, no click, and no pointer capture.
fn lua_ui_set_enabled(L: ?*lua_State) callconv(.c) c_int {
    const ctx = ctxOf(L);
    const e = entityOf(L, 1) orelse return 0;
    const b = ctx.world.get(e, components.UiButton) orelse return 0;
    b.enabled = lua.toBool(L, 2);
    return 0;
}

/// `ui.measure(self, text) -> w, h` — the pixel size `text` would occupy in this
/// widget's font. Returns nil when no UI system is wired (a headless tool).
fn lua_ui_measure(L: ?*lua_State) callconv(.c) c_int {
    const ctx = ctxOf(L);
    const hooks = ctx.ui orelse return 0;
    const e = entityOf(L, 1) orelse return 0;
    const text = lua.toSlice(L, 2) orelse "";
    var out = [2]f32{ 0, 0 };
    if (!hooks.measure(hooks.ctx, uiFontOf(ctx, e), text, &out)) return 0;
    lua.pushF32(L, out[0]);
    lua.pushF32(L, out[1]);
    return 2;
}

/// `ui.rect(self) -> x, y, w, h` — the screen-pixel rect the UI system resolved
/// this frame (the previous frame's, if called before the first layout).
fn lua_ui_rect(L: ?*lua_State) callconv(.c) c_int {
    const layout = uiLayoutOf(L) orelse return 0;
    const r = layout.resolved;
    lua.pushF32(L, r.position.x);
    lua.pushF32(L, r.position.y);
    lua.pushF32(L, r.size.x);
    lua.pushF32(L, r.size.y);
    return 4;
}

/// `ui.hovered(self) -> boolean` — true while the pointer is over this widget.
fn lua_ui_hovered(L: ?*lua_State) callconv(.c) c_int {
    const ctx = ctxOf(L);
    const hooks = ctx.ui orelse return pushFalse(L);
    const e = entityOf(L, 1) orelse return pushFalse(L);
    return pushBool(L, hooks.hovered(hooks.ctx, e.bits()));
}

/// `ui.pressed(self) -> boolean` — true while this button is being held down.
fn lua_ui_pressed(L: ?*lua_State) callconv(.c) c_int {
    const ctx = ctxOf(L);
    const hooks = ctx.ui orelse return pushFalse(L);
    const e = entityOf(L, 1) orelse return pushFalse(L);
    return pushBool(L, hooks.pressed(hooks.ctx, e.bits()));
}

/// `ui.font_load(path, px) -> id` — loads (or returns a cached) TTF at `px`
/// pixels and returns its id for `ui.set_font`. 0 when the file cannot be read.
/// Reads a file, so call it at load time, not per frame.
fn lua_ui_font_load(L: ?*lua_State) callconv(.c) c_int {
    const ctx = ctxOf(L);
    const hooks = ctx.ui orelse {
        lua.lua_pushinteger(L, 0);
        return 1;
    };
    const path = lua.toSlice(L, 1) orelse {
        lua.lua_pushinteger(L, 0);
        return 1;
    };
    const id = hooks.font_load(hooks.ctx, path, lua.toF32(L, 2));
    lua.lua_pushinteger(L, @intCast(id));
    return 1;
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

// ── 2D lighting (M7) ────────────────────────────────────────────────────────
//
// Godot's field names, because an editor author already knows them: a light is
// a Transform + a Light2D, and the interesting part is what it touches. The
// setters are typed and per-field on purpose — a generic setter costs a string
// lookup in the frame loop, and this surface is written once and read by an
// inspector that generated its field list from the metadata registry.
//
// The occluder's polygon is passed as a Lua table of numbers rather than as
// eight positional arguments, for the same reason English has commas: a shape
// with eight coordinates is unreadable as a flat list, and an editor that lets a
// user drag vertices produces them as a list anyway.

// `LUA_TTABLE` is 5 in every Lua 5.x. Declared here rather than imported from
// the header so this layer stays self-contained.
const TTable: c_int = 5;

// Godot has PointLight2D, SpotLight2D, DirectionalLight2D and AmbientLight2D,
// and the reason to use the same names is not familiarity alone: a scene
// ported from Godot means what it says here, and an inspector shows one panel
// per node.
//
// The shared properties live in `LightBase`, which Zig embeds, so the setters
// below reach into `base` and the four call sites are three words each rather
// than a copy-pasted block that a fix to the shadow filter would miss.

const PointLight = components.PointLight2D;
/// The legacy single-component light. Kept distinct here because `kind_of` has
/// to report it: an actor carrying both it and a `PointLight2D` lights twice.
const LegacyLight = components.Light2D;
const SpotLight = components.SpotLight2D;
const DirLight = components.DirectionalLight2D;
const AmbientLight = components.AmbientLight2D;
// M4.5: the camera, aliased for the same reason the lights are — the module is
// named `camera` and the component is named `Camera2D`, and writing the long
// name at every call site is noise.
const Camera2D = components.Camera2D;
const Occluder = components.LightOccluder2D;

// ── the shared properties, written once ─────────────────────────────────────

fn setColor(base: *components.LightBase, c: [4]f32) void {
    base.color = c;
}
fn setEnergy(base: *components.LightBase, v: f32) void {
    base.energy = v;
}
fn setBlend(base: *components.LightBase, k: u8) void {
    base.blend = @enumFromInt(k);
}
fn setShadow(base: *components.LightBase, enabled: bool, f: u8, smooth: f32) void {
    base.cast_shadows = enabled;
    base.shadow_filter = @enumFromInt(f);
    base.shadow_filter_smooth = smooth;
}
fn setMask(base: *components.LightBase, v: u32) void {
    base.item_cull_mask = v;
}

/// `light.set_color(self, r, g, b, a)` — works on whichever of the four is
/// present. Alpha is the light's opacity, so a light fades out by its alpha.
fn lua_light_set_color(L: ?*lua_State) callconv(.c) c_int {
    const ctx = ctxOf(L);
    const e = entityOf(L, 1) orelse return 0;
    const c = [4]f32{ lua.toF32(L, 3), lua.toF32(L, 4), lua.toF32(L, 5), lua.toF32(L, 6) };
    if (ctx.world.get(e, PointLight)) |l| setColor(&l.base, c);
    if (ctx.world.get(e, SpotLight)) |l| setColor(&l.base, c);
    if (ctx.world.get(e, DirLight)) |l| setColor(&l.base, c);
    if (ctx.world.get(e, AmbientLight)) |l| setColor(&l.base, c);
    return 0;
}

fn lua_light_set_energy(L: ?*lua_State) callconv(.c) c_int {
    const ctx = ctxOf(L);
    const e = entityOf(L, 1) orelse return 0;
    const v = lua.toF32(L, 3);
    if (ctx.world.get(e, PointLight)) |l| setEnergy(&l.base, v);
    if (ctx.world.get(e, SpotLight)) |l| setEnergy(&l.base, v);
    if (ctx.world.get(e, DirLight)) |l| setEnergy(&l.base, v);
    if (ctx.world.get(e, AmbientLight)) |l| setEnergy(&l.base, v);
    return 0;
}

/// `light.set_blend(self, kind)` — 0 add, 1 subtract, 2 mix. `mix` is the
/// energy-conserving one: a white surface under it stays white instead of
/// blowing out, which is why it exists.
fn lua_light_set_blend(L: ?*lua_State) callconv(.c) c_int {
    const ctx = ctxOf(L);
    const e = entityOf(L, 1) orelse return 0;
    const k: u8 = @intFromFloat(@max(lua.toF32(L, 3), 0));
    if (ctx.world.get(e, PointLight)) |l| setBlend(&l.base, k);
    if (ctx.world.get(e, SpotLight)) |l| setBlend(&l.base, k);
    if (ctx.world.get(e, DirLight)) |l| setBlend(&l.base, k);
    if (ctx.world.get(e, AmbientLight)) |l| setBlend(&l.base, k);
    return 0;
}

/// `light.set_shadow(self, enabled, filter, smoothness)` — filter is 0 off,
/// 1 one tap, 2 three, 3 five. The raw number because it is a quality dial and
/// a string per draw call is a lookup in the middle of a frame for nothing.
fn lua_light_set_shadow(L: ?*lua_State) callconv(.c) c_int {
    const ctx = ctxOf(L);
    const e = entityOf(L, 1) orelse return 0;
    const enabled = lua.toBool(L, 3);
    const f: u8 = @intFromFloat(@max(lua.toF32(L, 4), 0));
    const smooth = @max(lua.toF32(L, 5), 0);
    // An ambient light never casts a shadow: it has no direction to trace from,
    // and one that tried would be a shadow of nothing.
    if (ctx.world.get(e, PointLight)) |l| setShadow(&l.base, enabled, f, smooth);
    if (ctx.world.get(e, SpotLight)) |l| setShadow(&l.base, enabled, f, smooth);
    if (ctx.world.get(e, DirLight)) |l| setShadow(&l.base, enabled, f, smooth);
    return 0;
}

/// `light.set_mask(self, bitmask)` — which sprite layers this light affects, as a
/// bitmask of `Sprite.layer`. A light on layer 2 lights only layer 2, which is
/// how a scene gets a lamp that does not brighten its own interface.
fn lua_light_set_mask(L: ?*lua_State) callconv(.c) c_int {
    const ctx = ctxOf(L);
    const e = entityOf(L, 1) orelse return 0;
    const v: u32 = @intFromFloat(@max(lua.toF32(L, 3), 0));
    if (ctx.world.get(e, PointLight)) |l| setMask(&l.base, v);
    if (ctx.world.get(e, SpotLight)) |l| setMask(&l.base, v);
    if (ctx.world.get(e, DirLight)) |l| setMask(&l.base, v);
    if (ctx.world.get(e, AmbientLight)) |l| setMask(&l.base, v);
    return 0;
}

fn lua_light_get_energy(L: ?*lua_State) callconv(.c) c_int {
    const ctx = ctxOf(L);
    const e = entityOf(L, 1) orelse return 0;
    if (ctx.world.get(e, PointLight)) |l| lua.pushF32(L, l.base.energy);
    if (ctx.world.get(e, SpotLight)) |l| lua.pushF32(L, l.base.energy);
    if (ctx.world.get(e, DirLight)) |l| lua.pushF32(L, l.base.energy);
    if (ctx.world.get(e, AmbientLight)) |l| lua.pushF32(L, l.base.energy);
    return 1;
}

// ── PointLight2D: the one most scenes are made of ───────────────────────────

/// `point.new(self, radius)` — adds a PointLight2D. A zero radius is clamped
/// rather than rejected: it is not a hard edge, it is a divide-by-zero in every
/// falloff, and a scene that asks for one means "a small light", not "error me".
fn lua_point_new(L: ?*lua_State) callconv(.c) c_int {
    const ctx = ctxOf(L);
    const e = entityOf(L, 1) orelse return 0;
    if (ctx.world.get(e, PointLight) == null) {
        _ = ctx.world.add(e, PointLight{ .radius = @max(lua.toF32(L, 3), 1) }) catch return 0;
    }
    return 0;
}

fn lua_point_set_radius(L: ?*lua_State) callconv(.c) c_int {
    const ctx = ctxOf(L);
    const e = entityOf(L, 1) orelse return 0;
    if (ctx.world.get(e, PointLight)) |l| l.radius = @max(lua.toF32(L, 3), 1);
    return 0;
}

// ── SpotLight2D ─────────────────────────────────────────────────────────────

fn lua_spot_new(L: ?*lua_State) callconv(.c) c_int {
    const ctx = ctxOf(L);
    const e = entityOf(L, 1) orelse return 0;
    if (ctx.world.get(e, SpotLight) == null) {
        _ = ctx.world.add(e, SpotLight{ .radius = @max(lua.toF32(L, 3), 1) }) catch return 0;
    }
    return 0;
}

fn lua_spot_set_radius(L: ?*lua_State) callconv(.c) c_int {
    const ctx = ctxOf(L);
    const e = entityOf(L, 1) orelse return 0;
    if (ctx.world.get(e, SpotLight)) |l| l.radius = @max(lua.toF32(L, 3), 1);
    return 0;
}

/// `spot.set_cone(self, degrees, penumbra)` — two numbers in one call because
/// nothing ever sets one without the other, and a spotlight whose opening moved
/// but whose soft edge did not is a mis-configured light nobody can explain.
fn lua_spot_set_cone(L: ?*lua_State) callconv(.c) c_int {
    const ctx = ctxOf(L);
    const e = entityOf(L, 1) orelse return 0;
    if (ctx.world.get(e, SpotLight)) |l| {
        l.cone_angle = core_math.degToRad(@max(lua.toF32(L, 3), 0));
        l.penumbra = @min(@max(lua.toF32(L, 4), 0), 1);
    }
    return 0;
}

fn lua_spot_set_angle(L: ?*lua_State) callconv(.c) c_int {
    const ctx = ctxOf(L);
    const e = entityOf(L, 1) orelse return 0;
    if (ctx.world.get(e, SpotLight)) |l| l.angle = lua.toF32(L, 3);
    return 0;
}

// ── DirectionalLight2D: the sun ──────────────────────────────────────────────

fn lua_directional_new(L: ?*lua_State) callconv(.c) c_int {
    const ctx = ctxOf(L);
    const e = entityOf(L, 1) orelse return 0;
    if (ctx.world.get(e, DirLight) == null) {
        _ = ctx.world.add(e, DirLight{}) catch return 0;
    }
    return 0;
}

/// `directional.set_angle(self, radians)` — the direction the light TRAVELS,
/// not the direction it points. A sun at 0 shines to the right, which makes
/// shadows run to the left of every object.
fn lua_directional_set_angle(L: ?*lua_State) callconv(.c) c_int {
    const ctx = ctxOf(L);
    const e = entityOf(L, 1) orelse return 0;
    if (ctx.world.get(e, DirLight)) |l| l.angle = lua.toF32(L, 3);
    return 0;
}

/// `directional.set_height(self, h)` — 0..1. How high above the scene the light
/// sits, which scales shadow LENGTH. A 2D scene needs a z coordinate for exactly
/// this, and Godot's 0..1 dial is what a scene author means by it.
fn lua_directional_set_height(L: ?*lua_State) callconv(.c) c_int {
    const ctx = ctxOf(L);
    const e = entityOf(L, 1) orelse return 0;
    if (ctx.world.get(e, DirLight)) |l| l.height = @min(@max(lua.toF32(L, 3), 0), 1);
    return 0;
}

// ── AmbientLight2D ──────────────────────────────────────────────────────────

fn lua_ambient_new(L: ?*lua_State) callconv(.c) c_int {
    const ctx = ctxOf(L);
    const e = entityOf(L, 1) orelse return 0;
    if (ctx.world.get(e, AmbientLight) == null) {
        _ = ctx.world.add(e, AmbientLight{}) catch return 0;
    }
    return 0;
}

/// `ambient.set_local(self, distance)` — a local ambient. 0 restores the
/// scene-wide kind. A lantern's pool of warm air differs from the night around
/// it, and one number cannot hold both.
fn lua_ambient_set_local(L: ?*lua_State) callconv(.c) c_int {
    const ctx = ctxOf(L);
    const e = entityOf(L, 1) orelse return 0;
    if (ctx.world.get(e, AmbientLight)) |l| {
        const d = @max(lua.toF32(L, 3), 0);
        l.global = d <= 0;
        l.max_distance = d;
    }
    return 0;
}

/// `light.new(self, kind, radius, r, g, b, energy)` — adds whichever of the four
/// concrete lights `kind` selects (0 point, 1 spot, 2 directional, 3 ambient),
/// with its colour, radius and energy in ONE call.
///
/// One call rather than `point.new` plus four setters because a light is never
/// authored one field at a time: a scene file, a prefab and a script all arrive
/// with a whole light. It is also the only way `radius` is settable for a
/// directional light, which has none — the argument is simply ignored there.
fn lua_light_new(L: ?*lua_State) callconv(.c) c_int {
    const ctx = ctxOf(L);
    const e = entityOf(L, 1) orelse return 0;
    const kind: u8 = @intFromFloat(@max(lua.toF32(L, 2), 0));
    const radius = @max(lua.toF32(L, 3), 1);
    const color = [4]f32{ lua.toF32(L, 4), lua.toF32(L, 5), lua.toF32(L, 6), 1 };
    const energy = lua.toF32(L, 7);
    switch (kind) {
        1 => _ = ctx.world.add(e, SpotLight{ .radius = radius }) catch return 0,
        2 => _ = ctx.world.add(e, DirLight{}) catch return 0,
        3 => _ = ctx.world.add(e, AmbientLight{}) catch return 0,
        else => _ = ctx.world.add(e, PointLight{ .radius = radius }) catch return 0,
    }
    // The shared fields are written through the same helpers the setters use, so
    // `light.new` and `light.set_*` can never disagree about how a field maps.
    if (ctx.world.get(e, PointLight)) |l| {
        setColor(&l.base, color);
        setEnergy(&l.base, energy);
    }
    if (ctx.world.get(e, SpotLight)) |l| {
        setColor(&l.base, color);
        setEnergy(&l.base, energy);
    }
    if (ctx.world.get(e, DirLight)) |l| {
        setColor(&l.base, color);
        setEnergy(&l.base, energy);
    }
    if (ctx.world.get(e, AmbientLight)) |l| {
        setColor(&l.base, color);
        setEnergy(&l.base, energy);
    }
    return 0;
}

/// `light.get_radius(self) -> number` — how far the light reaches.
fn lua_light_get_radius(L: ?*lua_State) callconv(.c) c_int {
    const ctx = ctxOf(L);
    const e = entityOf(L, 1) orelse return 0;
    if (ctx.world.get(e, PointLight)) |l| lua.pushF32(L, l.radius);
    if (ctx.world.get(e, SpotLight)) |l| lua.pushF32(L, l.radius);
    // A directional light and an ambient light have no radius: they reach
    // everywhere. Returning 0 rather than nil keeps the return type stable, so a
    // generic inspector does not need a per-kind branch.
    return 1;
}

/// `light.set_cone(self, degrees, penumbra)` — spot only. Read back through
/// `light.get_cone`, which is what the acceptance test and the inspector do.
///
/// Degrees in, radians stored. The component stores radians because the shader
/// wants a dot-product threshold, and the binding takes degrees because that is
/// how a cone is authored.
fn lua_light_set_cone(L: ?*lua_State) callconv(.c) c_int {
    const ctx = ctxOf(L);
    const e = entityOf(L, 1) orelse return 0;
    if (ctx.world.get(e, SpotLight)) |l| {
        l.cone_angle = lua.toF32(L, 2) * (core_math.pi / 180.0);
        l.penumbra = core_math.clampf(lua.toF32(L, 3), 0, 1);
    }
    return 0;
}

/// `light.get_cone(self) -> degrees, penumbra`.
fn lua_light_get_cone(L: ?*lua_State) callconv(.c) c_int {
    const ctx = ctxOf(L);
    const e = entityOf(L, 1) orelse return 0;
    if (ctx.world.get(e, SpotLight)) |l| {
        lua.pushF32(L, l.cone_angle * (180.0 / core_math.pi));
        lua.pushF32(L, l.penumbra);
        return 2;
    }
    lua.pushF32(L, 0);
    lua.pushF32(L, 0);
    return 2;
}

/// `light.get_shadow(self) -> casts, filter, smoothness` — the inspector's three
/// shadow knobs in the order the setter takes them.
fn lua_light_get_shadow(L: ?*lua_State) callconv(.c) c_int {
    const ctx = ctxOf(L);
    const e = entityOf(L, 1) orelse return 0;
    // One pointer into whichever light is present, so the three reads below are
    // written once instead of once per kind. This is also why a light added by
    // any of the four modules reports the same shape here.
    var base: ?*const components.LightBase = null;
    if (ctx.world.get(e, PointLight)) |l| base = &l.base;
    if (ctx.world.get(e, SpotLight)) |l| base = &l.base;
    if (ctx.world.get(e, DirLight)) |l| base = &l.base;
    if (ctx.world.get(e, AmbientLight)) |l| base = &l.base;
    const b = base orelse return 0;
    lua.lua_pushboolean(L, @intFromBool(b.cast_shadows));
    lua.pushF32(L, @floatFromInt(@intFromEnum(b.shadow_filter)));
    lua.pushF32(L, b.shadow_filter_smooth);
    return 3;
}

/// The M7 lighting system's own module: the quality tier and the per-frame
/// stats. Separate from `light` because `light.*` acts ON AN ACTOR and these
/// act on the process-wide system that draws them.
const lighting_regs = [_]luaL_Reg{
    .{ .name = "quality", .func = lua_lighting_quality },
    .{ .name = "set_quality", .func = lua_lighting_set_quality },
    .{ .name = "stats", .func = lua_lighting_stats },
    .{ .name = null, .func = null },
};

const light_regs = [_]luaL_Reg{
    .{ .name = "new", .func = lua_light_new },
    .{ .name = "kind_of", .func = lua_light_kind_of },
    .{ .name = "describe", .func = lua_light_describe },
    .{ .name = "set_color", .func = lua_light_set_color },
    .{ .name = "set_energy", .func = lua_light_set_energy },
    .{ .name = "set_blend", .func = lua_light_set_blend },
    .{ .name = "set_shadow", .func = lua_light_set_shadow },
    .{ .name = "set_mask", .func = lua_light_set_mask },
    .{ .name = "set_cone", .func = lua_light_set_cone },
    .{ .name = "get_energy", .func = lua_light_get_energy },
    .{ .name = "get_radius", .func = lua_light_get_radius },
    .{ .name = "get_cone", .func = lua_light_get_cone },
    .{ .name = "get_shadow", .func = lua_light_get_shadow },
    .{ .name = null, .func = null },
};

const point_regs = [_]luaL_Reg{
    .{ .name = "new", .func = lua_point_new },
    .{ .name = "set_radius", .func = lua_point_set_radius },
    .{ .name = null, .func = null },
};

const spot_regs = [_]luaL_Reg{
    .{ .name = "new", .func = lua_spot_new },
    .{ .name = "set_radius", .func = lua_spot_set_radius },
    .{ .name = "set_cone", .func = lua_spot_set_cone },
    .{ .name = "set_angle", .func = lua_spot_set_angle },
    .{ .name = null, .func = null },
};

const directional_regs = [_]luaL_Reg{
    .{ .name = "new", .func = lua_directional_new },
    .{ .name = "set_angle", .func = lua_directional_set_angle },
    .{ .name = "set_height", .func = lua_directional_set_height },
    .{ .name = null, .func = null },
};

const ambient_regs = [_]luaL_Reg{
    .{ .name = "new", .func = lua_ambient_new },
    .{ .name = "set_local", .func = lua_ambient_set_local },
    .{ .name = null, .func = null },
};

// ── LightOccluder2D ─────────────────────────────────────────────────────────
//
// Three modes, because a sprite that looks like it occludes must be able to say
// that it must NOT: a fog card, a UI panel. `none` is why the mode exists at
// all; the alternative is deleting the component and re-adding it without it,
// which is what you do when the only escape hatch is deletion.

fn occluderOf(L: ?*lua_State) ?*Occluder {
    const ctx = ctxOf(L);
    const e = entityOf(L, 1) orelse return null;
    return ctx.world.get(e, Occluder);
}

fn lua_occluder_new(L: ?*lua_State) callconv(.c) c_int {
    const ctx = ctxOf(L);
    const e = entityOf(L, 1) orelse return 0;
    if (ctx.world.get(e, Occluder) == null) {
        _ = ctx.world.add(e, Occluder{
            .mode = @enumFromInt(@as(u8, @intFromFloat(@max(lua.toF32(L, 2), 0)))),
        }) catch return 0;
    }
    return 0;
}

fn lua_occluder_set_mode(L: ?*lua_State) callconv(.c) c_int {
    const o = occluderOf(L) orelse return 0;
    o.mode = @enumFromInt(@as(u8, @intFromFloat(@max(lua.toF32(L, 2), 0))));
    return 0;
}

/// `occluder.set_threshold(self, alpha)` — where the automatic shape draws its
/// own edge. Raising it is the fix for most "my sprite has a fringe of shadow"
/// reports, and a fix that cannot be reached from Lua is not a fix.
fn lua_occluder_set_threshold(L: ?*lua_State) callconv(.c) c_int {
    const o = occluderOf(L) orelse return 0;
    o.alpha_threshold = @min(@max(lua.toF32(L, 2), 0), 1);
    return 0;
}

fn lua_occluder_set_mask(L: ?*lua_State) callconv(.c) c_int {
    const o = occluderOf(L) orelse return 0;
    o.cull_mask = @intFromFloat(@max(lua.toF32(L, 2), 0));
    return 0;
}

/// `occluder.set_polygon(self, {x0, y0, ...})` — the manual shape.
///
/// Read from a table rather than eight positional arguments, because a shape
/// with eight coordinates is unreadable as a flat list and an editor that lets
/// a user drag vertices produces a list anyway.
fn lua_occluder_set_polygon(L: ?*lua_State) callconv(.c) c_int {
    const o = occluderOf(L) orelse return 0;
    if (lua.lua_type(L, 2) != TTable) return 0;

    var poly = components.OccluderPolygon{};
    const n: usize = @intCast(lua.lua_objlen(L, 2));
    var i: usize = 0;
    while (i < n and i < poly.points.len) : (i += 1) {
        lua.lua_pushinteger(L, @intCast(i + 1));
        lua.lua_gettable(L, 2);
        poly.points[i] = lua.toF32(L, -1);
        lua.lua_settop(L, -2);
    }
    poly.count = @intCast(i);
    o.polygon = poly;
    return 0;
}

fn lua_occluder_get_mode(L: ?*lua_State) callconv(.c) c_int {
    const o = occluderOf(L) orelse return 0;
    lua.pushF32(L, @floatFromInt(@intFromEnum(o.mode)));
    return 1;
}

fn lua_occluder_get_threshold(L: ?*lua_State) callconv(.c) c_int {
    const o = occluderOf(L) orelse return 0;
    lua.pushF32(L, o.alpha_threshold);
    return 1;
}

fn lua_occluder_get_mask(L: ?*lua_State) callconv(.c) c_int {
    const o = occluderOf(L) orelse return 0;
    lua.pushF32(L, @floatFromInt(o.cull_mask));
    return 1;
}

/// `occluder.get_polygon(self) -> table` — the manual shape as a flat list. An
/// editor that lets a user drag vertices reads this back to draw them.
///
/// `createtable` with the SECOND argument asks for the array part, which is
/// what makes `#pts` and `ipairs` work. Without it the table is hash-only,
/// `lua_objlen` returns zero, and an editor dragging vertices sees an empty
/// shape — a bug invisible until someone tries to iterate.
fn lua_occluder_get_polygon(L: ?*lua_State) callconv(.c) c_int {
    const o = occluderOf(L) orelse return 0;
    lua.lua_createtable(L, @intCast(o.polygon.count), 0);
    var i: usize = 0;
    while (i < o.polygon.count) : (i += 1) {
        lua.pushF32(L, o.polygon.points[i]);
        lua.lua_rawseti(L, -2, @intCast(i + 1));
    }
    return 1;
}

const occluder_regs = [_]luaL_Reg{
    .{ .name = "new", .func = lua_occluder_new },
    .{ .name = "set_mode", .func = lua_occluder_set_mode },
    .{ .name = "set_threshold", .func = lua_occluder_set_threshold },
    .{ .name = "set_mask", .func = lua_occluder_set_mask },
    .{ .name = "set_polygon", .func = lua_occluder_set_polygon },
    .{ .name = "get_mode", .func = lua_occluder_get_mode },
    .{ .name = "get_threshold", .func = lua_occluder_get_threshold },
    .{ .name = "get_mask", .func = lua_occluder_get_mask },
    .{ .name = "get_polygon", .func = lua_occluder_get_polygon },
    .{ .name = null, .func = null },
};

// ── Environment (M7): the world's global lighting ─────────────────────────────
//
// One of these per world, not per actor: ambient light is a property of the
// world, and "change the mood" should be one number rather than a scene-wide
// edit. Godot calls this `Environment`, so the names match.

const Env = components.Environment;

/// `environment.set_ambient(r, g, b, energy)` — what "dark" means.
///
/// Two numbers, not four: energy is a multiplier on the colour and setting one
/// without the other is how a scene ends up with an ambient of pure white at
/// zero energy and nobody knows why it is still black.
fn lua_environment_set_ambient(L: ?*lua_State) callconv(.c) c_int {
    const ctx = ctxOf(L);
    const e = entityOf(L, 1) orelse return 0;
    const env: *Env = ctx.world.get(e, Env) orelse return 0;
    env.ambient_color = .{ lua.toF32(L, 2), lua.toF32(L, 3), lua.toF32(L, 4), 1 };
    env.ambient_energy = @max(lua.toF32(L, 5), 0);
    return 0;
}

/// `environment.set_clear(r, g, b)` — what nothing lights at all resolves to.
///
/// Separate from the ambient colour, because one is what the world does to what
/// it touches and the other is the empty case. A scene with a clear of black and
/// an ambient of black is correctly not a bug; it is a cave.
fn lua_environment_set_clear(L: ?*lua_State) callconv(.c) c_int {
    const ctx = ctxOf(L);
    const e = entityOf(L, 1) orelse return 0;
    const env: *Env = ctx.world.get(e, Env) orelse return 0;
    env.clear_color = .{ lua.toF32(L, 2), lua.toF32(L, 3), lua.toF32(L, 4), 1 };
    return 0;
}

/// `environment.set_bloom(intensity, threshold)` — how much bloom is added, and
/// the luminance above which a pixel contributes to it.
///
/// TWO arguments, and the previous one-argument form is the bug this fixes: it
/// wrote `bloom_threshold` with an intensity clamp of 0..0.2, so a scene could
/// set a "bloom" value that neither enabled the chain nor was a threshold, and
/// `bloom_intensity` — the number that decides whether the four passes run at
/// all — had no binding and could never be set from Lua. Bloom was unreachable.
///
/// Zero intensity skips the chain entirely rather than running it with a zero
/// multiplier, which is why it is not just another colour channel.
fn lua_environment_set_bloom(L: ?*lua_State) callconv(.c) c_int {
    const ctx = ctxOf(L);
    const e = entityOf(L, 1) orelse return 0;
    const env: *Env = ctx.world.get(e, Env) orelse return 0;
    env.bloom_intensity = @min(@max(lua.toF32(L, 2), 0), 1);
    env.bloom_threshold = @min(@max(lua.toF32(L, 3), 0), 1);
    return 0;
}

fn lua_environment_new(L: ?*lua_State) callconv(.c) c_int {
    const ctx = ctxOf(L);
    const e = entityOf(L, 1) orelse return 0;
    if (ctx.world.get(e, Env) == null) {
        _ = ctx.world.add(e, Env{}) catch return 0;
    }
    return 0;
}

/// `environment.get_sky(self) -> r, g, b` — the sky's radiance.
// ── M9: scene transitions (the fade) ──────────────────────────────────────────

/// `scene.fade_out(duration, r, g, b)` — covers the screen with `color` over
/// `duration` real seconds. Zero duration is an instant cover. Restarting an
/// existing fade replaces it from zero (an interrupted fade is not two
/// overlapping curtains).
fn lua_scene_fade_out(L: ?*lua_State) callconv(.c) c_int {
    const ctx = ctxOf(L);
    const h = ctx.scene orelse return 0;
    const duration = @max(lua.toF32(L, 2), 0);
    const r = @min(@max(lua.toF32(L, 3), 0), 1);
    const g = @min(@max(lua.toF32(L, 4), 0), 1);
    const b = @min(@max(lua.toF32(L, 5), 0), 1);
    h.fade_out(h.ctx, duration, r, g, b);
    return 0;
}

/// `scene.fade_in(duration)` — uncovers from wherever the curtain currently is.
/// Zero duration is an instant clear.
fn lua_scene_fade_in(L: ?*lua_State) callconv(.c) c_int {
    const ctx = ctxOf(L);
    const h = ctx.scene orelse return 0;
    const duration = @max(lua.toF32(L, 2), 0);
    h.fade_in(h.ctx, duration);
    return 0;
}

/// `scene.fade_covered(r, g, b)` — jumps straight to a fully covered screen.
/// What a loading screen does: the player must not watch a fade play before a
/// black frame they are going to sit on for two seconds anyway.
fn lua_scene_fade_covered(L: ?*lua_State) callconv(.c) c_int {
    const ctx = ctxOf(L);
    const h = ctx.scene orelse return 0;
    const r = @min(@max(lua.toF32(L, 2), 0), 1);
    const g = @min(@max(lua.toF32(L, 3), 0), 1);
    const b = @min(@max(lua.toF32(L, 4), 0), 1);
    h.fade_covered(h.ctx, r, g, b);
    return 0;
}

/// `scene.fade_clear()` — jumps back to a clear screen.
fn lua_scene_fade_clear(L: ?*lua_State) callconv(.c) c_int {
    const ctx = ctxOf(L);
    const h = ctx.scene orelse return 0;
    h.fade_clear(h.ctx);
    return 0;
}

/// `scene.fade_amount() -> 0..1` — current coverage.
fn lua_scene_fade_amount(L: ?*lua_State) callconv(.c) c_int {
    const ctx = ctxOf(L);
    const h = ctx.scene orelse {
        lua.pushF32(L, 0);
        return 1;
    };
    lua.pushF32(L, h.amount(h.ctx));
    return 1;
}

/// `scene.fading() -> boolean` — true while a transition is running.
fn lua_scene_fading(L: ?*lua_State) callconv(.c) c_int {
    const ctx = ctxOf(L);
    const h = ctx.scene orelse {
        lua.lua_pushboolean(L, 0);
        return 1;
    };
    lua.lua_pushboolean(L, @intFromBool(h.fading(h.ctx)));
    return 1;
}

// ── M14: CanvasModulate (the full-screen tint) ────────────────────────────────

/// Maps a `scene.tint_mode` name to its wire code: 0 off, 1 multiply, 2 add,
/// 3 alpha. Unknown names are ignored (return null), so a typo does not pick a
/// mode by accident — the call simply does nothing.
fn tintModeFromName(name: []const u8) ?u8 {
    if (std.mem.eql(u8, name, "off")) return 0;
    if (std.mem.eql(u8, name, "multiply")) return 1;
    if (std.mem.eql(u8, name, "add")) return 2;
    if (std.mem.eql(u8, name, "alpha")) return 3;
    return null;
}

/// `scene.tint(r, g, b, a)` — lays a colour over the whole canvas (world AND
/// game UI). Multiply by default; follow with `scene.tint_mode` to flash or
/// veil instead. `a` is the strength, 0..1, and 0 is a no-op.
fn lua_scene_tint(L: ?*lua_State) callconv(.c) c_int {
    const ctx = ctxOf(L);
    const h = ctx.tint orelse return 0;
    const r = @min(@max(lua.toF32(L, 1), 0), 1);
    const g = @min(@max(lua.toF32(L, 2), 0), 1);
    const b = @min(@max(lua.toF32(L, 3), 0), 1);
    const a = @min(@max(lua.toF32(L, 4), 0), 1);
    h.set(h.ctx, r, g, b, a);
    return 0;
}

/// `scene.tint_mode(name)` — how the tint mixes: "multiply" (the default),
/// "add" (a flash), "alpha" (a flat veil) or "off" (disables it). An unknown
/// name is ignored.
fn lua_scene_tint_mode(L: ?*lua_State) callconv(.c) c_int {
    const ctx = ctxOf(L);
    const h = ctx.tint orelse return 0;
    const mode = tintModeFromName(lua.toString(L, 1)) orelse return 0;
    h.set_mode(h.ctx, mode);
    return 0;
}

/// `scene.tint_clear()` — disables the tint and forgets its colour.
fn lua_scene_tint_clear(L: ?*lua_State) callconv(.c) c_int {
    const ctx = ctxOf(L);
    const h = ctx.tint orelse return 0;
    h.clear(h.ctx);
    return 0;
}

/// `scene.tint_amount() -> 0..1` — the current strength. The value a script
/// animates a flash back down to zero against.
fn lua_scene_tint_amount(L: ?*lua_State) callconv(.c) c_int {
    const ctx = ctxOf(L);
    const h = ctx.tint orelse {
        lua.pushF32(L, 0);
        return 1;
    };
    lua.pushF32(L, h.amount(h.ctx));
    return 1;
}

// ── M9: particles (the CPU pool) ──────────────────────────────────────────────

/// `particles.burst(self, count)` — emits `count` particles NOW, from the
/// actor's ParticleEmitter2D. Returns how many were actually emitted (may be
/// less if the emitter's slab is full, and that is counted and reported).
///
/// The CONFIGURE half of the particle API is plain component writes:
/// `emitter.rate = 10`, `emitter.capacity = 256`, `emitter.color_start = 0xFFFFFFFF`,
/// etc. Those work through the normal component surface and do not need this
/// hook. `burst` is the one operation that needs the SYSTEM'S pool.
fn lua_particles_burst(L: ?*lua_State) callconv(.c) c_int {
    const ctx = ctxOf(L);
    const h = ctx.particles orelse return 0;
    const e = entityOf(L, 1) orelse return 0;
    const count: u32 = @as(u32, @intFromFloat(@max(lua.toF32(L, 2), 0)));
    lua.lua_pushinteger(L, @as(i32, @intCast(h.burst(h.ctx, e.bits(), count))));
    return 1;
}

/// `particles.stats() -> { simulated, live, spawned, drawn, culled, dropped_spawn, slab_denied, sim_ms, collect_ms }`
///
/// The names and order are fixed here so a script that reads the table knows
/// exactly what it is getting, and a stub generator can annotate the keys.
fn lua_particles_stats(L: ?*lua_State) callconv(.c) c_int {
    const ctx = ctxOf(L);
    const h = ctx.particles orelse return 0;
    lua.lua_createtable(L, 0, 9);
    var raw: [16]f64 = undefined;
    const n = h.stats(h.ctx, &raw);
    const names = [_][:0]const u8{
        "simulated",    "live",       "spawned",       "drawn",
        "culled",       "dropped_spawn", "slab_denied",  "sim_ms",
        "collect_ms",
    };
    const count = @min(@min(names.len, n), 9);
    for (names[0..count], 0..) |key, i| {
        lua.lua_pushstring(L, key.ptr);
        lua.lua_pushnumber(L, raw[i]);
        lua.lua_rawset(L, -3);
    }
    return 1;
}
///
/// ## Why this is the first thing an inspector asks for
///
/// An actor has FOUR light components and the inspector has to show the right
/// panel for whichever is present. Without this it would probe five `has_component`
/// calls and pick the first that answers, which is fine — but only if the engine
/// tells it the answer directly, and only if there is exactly one answer. An
/// actor carrying both a legacy `Light2D` and a `PointLight2D` lights twice,
/// and that is worth being able to SEE rather than discover by counting shadows.
///
/// ## Why a string and not a number
///
/// Because the editor's panel list is keyed by name and a number here is a
/// translation it has to keep in step with the engine's enum. `nil` means "no
/// light", which is distinct from every kind — and distinct from an error, which
/// is why this returns rather than throwing.
fn lua_light_kind_of(L: ?*lua_State) callconv(.c) c_int {
    const ctx = ctxOf(L);
    const e = entityOf(L, 1) orelse return 0;
    const name: ?[:0]const u8 =
        if (ctx.world.get(e, PointLight)) |_| "point"
        else if (ctx.world.get(e, SpotLight)) |_| "spot"
        else if (ctx.world.get(e, DirLight)) |_| "directional"
        else if (ctx.world.get(e, AmbientLight)) |_| "ambient"
        else if (ctx.world.get(e, LegacyLight)) |_| "legacy"
        else
            null;
    const n = name orelse {
        lua.lua_pushnil(L);
        return 1;
    };
    lua.lua_pushstring(L, n.ptr);
    return 1;
}

/// `light.describe(self) -> table` — every readable field of whichever light
/// component is present, as one flat table.
///
/// ## Why a table and not twenty getters
///
/// An inspector does not know in advance which fields it will draw: it draws
/// whatever the component has. Twenty `light.get_*` calls means the binding list
/// and the inspector's field list are two places that must agree, and the
/// failure is a property that exists and is not editable. One table that is
/// RETURNED rather than declared is the same information with no second list.
///
/// ## Flat and string-keyed
///
/// Flat because the four components share `LightBase` and a nested table would
/// mean the inspector has to know which fields are shared. Keys are the field
/// names as `LightBase` and the per-kind struct spell them, so a name in this
/// table is a name `metadata.zig` documents.
///
/// Returns an EMPTY table, not nil, for "no light": "an actor with no light has
/// no fields" and "this call failed" must not look the same to a caller.
fn lua_light_describe(L: ?*lua_State) callconv(.c) c_int {
    const ctx = ctxOf(L);
    const e = entityOf(L, 1) orelse return 0;
    // The array part is reserved even though every key is a string: `next` over
    // a hash-only table works, but `pairs` ordering is then unspecified and an
    // inspector that re-reads the table per frame would flicker its field order.
    lua.lua_createtable(L, 0, 16);

    // `St`, not `L`: the helper's parameter would otherwise shadow the enclosing
    // C function's `L`, which Zig rejects -- and rightly, because two states in
    // one expression is exactly the confusion that produces a stack corruption.
    const put = struct {
        fn f(St: ?*lua_State, key: [:0]const u8, v: f32) void {
            lua.lua_pushstring(St, key.ptr);
            lua.pushF32(St, v);
            lua.lua_rawset(St, -3);
        }
        fn b(St: ?*lua_State, key: [:0]const u8, v: bool) void {
            lua.lua_pushstring(St, key.ptr);
            // c_int, not bool: LuaJIT's push takes a C int and Zig will not
            // coerce a bool into one implicitly, which is the right refusal.
            lua.lua_pushboolean(St, @intFromBool(v));
            lua.lua_rawset(St, -3);
        }
    };

    if (ctx.world.get(e, PointLight)) |l| {
        put.b(L, "cast_shadows", l.base.cast_shadows);
        put.f(L, "energy", l.base.energy);
        put.f(L, "radius", l.radius);
        put.f(L, "attenuation", l.attenuation);
        put.f(L, "item_cull_mask", @floatFromInt(l.base.item_cull_mask));
        put.f(L, "blend", @floatFromInt(@intFromEnum(l.base.blend)));
        put.f(L, "shadow_filter", @floatFromInt(@intFromEnum(l.base.shadow_filter)));
    } else if (ctx.world.get(e, SpotLight)) |l| {
        put.b(L, "cast_shadows", l.base.cast_shadows);
        put.f(L, "energy", l.base.energy);
        put.f(L, "radius", l.radius);
        put.f(L, "angle", l.angle);
        put.f(L, "cone_angle", l.cone_angle);
        put.f(L, "penumbra", l.penumbra);
        put.f(L, "attenuation", l.attenuation);
        put.f(L, "item_cull_mask", @floatFromInt(l.base.item_cull_mask));
        put.f(L, "blend", @floatFromInt(@intFromEnum(l.base.blend)));
    } else if (ctx.world.get(e, DirLight)) |l| {
        put.b(L, "cast_shadows", l.base.cast_shadows);
        put.f(L, "energy", l.base.energy);
        put.f(L, "angle", l.angle);
        put.f(L, "height", l.height);
        put.f(L, "max_distance", l.max_distance);
        put.f(L, "item_cull_mask", @floatFromInt(l.base.item_cull_mask));
    } else if (ctx.world.get(e, AmbientLight)) |l| {
        put.f(L, "energy", l.base.energy);
        put.b(L, "global", l.global);
        put.f(L, "max_distance", l.max_distance);
    }
    return 1;
}

/// `lighting.quality(self) -> 0..3` — the tier the lighting system is running at.
///
/// 0 off, 1 low, 2 medium, 3 high. Each tier changes the shadow channel count, the
/// angle resolution and whether GI is built, and those are the three numbers an
/// inspector's quality dropdown has to show next to its slider.
///
/// -1 when no driver is wired (a headless tool, a test), which is distinct from
/// 0 = off: one is "there is no lighting system" and the other is "the lighting
/// system is switched off", and an inspector that shows them the same sends the
/// user looking for a bug that is not there.
fn lua_lighting_quality(L: ?*lua_State) callconv(.c) c_int {
    const ctx = ctxOf(L);
    const h = ctx.lighting orelse {
        lua.pushF32(L, -1);
        return 1;
    };
    lua.pushF32(L, @floatFromInt(h.get_quality(h.ctx)));
    return 1;
}

/// `lighting.set_quality(tier) -> bool` — 0 off, 1 low, 2 medium, 3 high.
///
/// False when the tier could not be taken, which is one case and it is worth
/// naming: the pyramid only exists when the driver was created with GI on, so
/// asking a GI-off driver for a GI-on tier declines. That is a BUDGET decision
/// made at startup, and answering honestly is better than allocating a pyramid
/// the frame was never sized for.
fn lua_lighting_set_quality(L: ?*lua_State) callconv(.c) c_int {
    const ctx = ctxOf(L);
    const h = ctx.lighting orelse {
        lua.lua_pushboolean(L, 0);
        return 1;
    };
    const raw = lua.toF32(L, 2);
    const tier: u8 = @intFromFloat(@min(@max(raw, 0), 3));
    const ok: bool = h.set_quality(h.ctx, tier);
    lua.lua_pushboolean(L, @intFromBool(ok));
    return 1;
}

/// `lighting.stats(self) -> table` — what the lighting system cost this frame.
///
/// Timings and counts, not a summary: a profile that reports "the lighting is
/// fine" is not a profile, and these are the numbers `bench-light` prints. The
/// keys are the `Stats` field names, so a doc entry for one of them is this
/// table's documentation.
fn lua_lighting_stats(L: ?*lua_State) callconv(.c) c_int {
    const ctx = ctxOf(L);
    // Reserved for the string part only; every key here is a string.
    lua.lua_createtable(L, 0, 16);
    const h = ctx.lighting orelse return 1; // an empty table: no system, no stats
    var raw: [16]f64 = undefined;
    const n = h.stats(h.ctx, &raw);
    const s = raw[0..n];
    const put = struct {
        fn f(St: ?*lua_State, key: [:0]const u8, v: f64) void {
            lua.lua_pushstring(St, key.ptr);
            lua.lua_pushnumber(St, v);
            lua.lua_rawset(St, -3);
        }
    };
    // Index order IS the name order, and both live here: a fixed array crossed
    // with a separately-maintained list of names is exactly the pair that drifts,
    // and the drift is a stats table where every value is one field off.
    const names = [_][:0]const u8{
        "lights",          "shadow_lights",    "shadow_denied",
        "occluders",       "occluders_rasterized", "coverage_used",
        "coverage_dropped", "sweep_steps",     "sweep_skips",
        "channel_masks_built", "mask_fill",    "collect_ns",
        "sweep_ns",        "raster_ns",        "sdf_ns",
    };
    const count = @min(@min(names.len, s.len), @as(usize, @intCast(n)));
    for (names[0..count], 0..) |key, i| put.f(L, key, s[i]);
    return 1;
}

/// `environment.set_tonemap(enabled)`. For HDR scenes, where a light at energy 3
/// otherwise clips to white and a colour ramp nobody chose.
fn lua_environment_set_tonemap(L: ?*lua_State) callconv(.c) c_int {
    const ctx = ctxOf(L);
    const e = entityOf(L, 1) orelse return 0;
    const env: *Env = ctx.world.get(e, Env) orelse return 0;
    env.tonemap = lua.toBool(L, 2);
    return 0;
}

/// `environment.set_fog(near, far, r, g, b)` — the cheapest depth cue a 2D game
/// has. `far <= near` disables it, and that is the documented way to remove it
/// rather than a special zero case.
fn lua_environment_set_fog(L: ?*lua_State) callconv(.c) c_int {
    const ctx = ctxOf(L);
    const e = entityOf(L, 1) orelse return 0;
    const env: *Env = ctx.world.get(e, Env) orelse return 0;
    const near = @max(lua.toF32(L, 2), 0);
    const far = lua.toF32(L, 3);
    env.fog = .{ near, far };
    env.fog_color = .{ lua.toF32(L, 4), lua.toF32(L, 5), lua.toF32(L, 6), 1 };
    return 0;
}

fn lua_environment_get_ambient(L: ?*lua_State) callconv(.c) c_int {
    const ctx = ctxOf(L);
    const e = entityOf(L, 1) orelse return 0;
    const env: *Env = ctx.world.get(e, Env) orelse return 0;
    for (env.ambient()) |c| lua.pushF32(L, c);
    return 4;
}

fn lua_environment_get_clear(L: ?*lua_State) callconv(.c) c_int {
    const ctx = ctxOf(L);
    const e = entityOf(L, 1) orelse return 0;
    const env: *Env = ctx.world.get(e, Env) orelse return 0;
    for (env.clear_color) |c| lua.pushF32(L, c);
    return 4;
}

fn lua_environment_get_fog(L: ?*lua_State) callconv(.c) c_int {
    const ctx = ctxOf(L);
    const e = entityOf(L, 1) orelse return 0;
    const env: *Env = ctx.world.get(e, Env) orelse return 0;
    lua.pushF32(L, env.fog[0]);
    lua.pushF32(L, env.fog[1]);
    return 2;
}

const environment_regs = [_]luaL_Reg{
    .{ .name = "new", .func = lua_environment_new },
    .{ .name = "set_ambient", .func = lua_environment_set_ambient },
    .{ .name = "set_clear", .func = lua_environment_set_clear },
    .{ .name = "set_bloom", .func = lua_environment_set_bloom },
    .{ .name = "set_tonemap", .func = lua_environment_set_tonemap },
    .{ .name = "set_fog", .func = lua_environment_set_fog },
    .{ .name = "get_ambient", .func = lua_environment_get_ambient },
    .{ .name = "get_clear", .func = lua_environment_get_clear },
    .{ .name = "get_fog", .func = lua_environment_get_fog },
    .{ .name = null, .func = null },
};

const scene_regs = [_]luaL_Reg{
    .{ .name = "fade_out", .func = lua_scene_fade_out },
    .{ .name = "fade_in", .func = lua_scene_fade_in },
    .{ .name = "fade_covered", .func = lua_scene_fade_covered },
    .{ .name = "fade_clear", .func = lua_scene_fade_clear },
    .{ .name = "fade_amount", .func = lua_scene_fade_amount },
    .{ .name = "fading", .func = lua_scene_fading },
    // M14: CanvasModulate (the full-screen tint).
    .{ .name = "tint", .func = lua_scene_tint },
    .{ .name = "tint_mode", .func = lua_scene_tint_mode },
    .{ .name = "tint_clear", .func = lua_scene_tint_clear },
    .{ .name = "tint_amount", .func = lua_scene_tint_amount },
    .{ .name = null, .func = null },
};

const particles_regs = [_]luaL_Reg{
    .{ .name = "burst", .func = lua_particles_burst },
    .{ .name = "stats", .func = lua_particles_stats },
    .{ .name = null, .func = null },
};

// ── Camera2D (M4.5) ──────────────────────────────────────────────────────────
//
// The camera bindings act on THIS actor's `Camera2D`. That is the same choice
// every other module here makes (`point.new(self, ...)`, `sprite.set_size`) and
// it is what makes a camera authorable from the behavior attached to it: the
// script that owns the camera is the script on the camera's own actor.
//
// The system that ADVANCES these fields lives in `ecs/camera.zig` and runs on
// the fixed step, outside Lua entirely. Nothing here moves the camera: these
// are the knobs, and the tick is what turns them. That split is why a camera
// behaves identically whether it was authored in a scene file or driven from a
// script.

/// `camera.new(self)` — adds a Camera2D to this actor. Adding is explicit rather
/// than implicit in `follow`, because a camera is a scene-level decision and a
/// behavior that tried to move a camera it does not own would silently do
/// nothing.
fn lua_camera_new(L: ?*lua_State) callconv(.c) c_int {
    const ctx = ctxOf(L);
    const e = entityOf(L, 1) orelse return 0;
    if (ctx.world.get(e, Camera2D) == null) {
        _ = ctx.world.add(e, Camera2D{}) catch return 0;
    }
    return 0;
}

/// `camera.follow(self, other)` — where the camera looks.
///
/// Takes another actor rather than coordinates, because a camera that follows a
/// POSITION has to be told again every frame and a camera that follows an ACTOR
/// is correct for as long as that actor lives. The target is an `Entity`, so a
/// despawned target degrades to "no target" (the camera holds its last centre)
/// rather than following freed memory.
fn lua_camera_follow(L: ?*lua_State) callconv(.c) c_int {
    const ctx = ctxOf(L);
    const e = entityOf(L, 1) orelse return 0;
    const target = entityOf(L, 2) orelse return 0;
    if (ctx.world.get(e, Camera2D)) |c| c.follow(target);
    return 0;
}

/// `camera.zoom_to(self, zoom)` — the target zoom. Reached through a spring, so
/// this is where the camera is HEADING, not where it is; that is what makes a
/// pinch-to-zoom or a sniper scope feel like motion rather than a cut.
fn lua_camera_zoom_to(L: ?*lua_State) callconv(.c) c_int {
    const ctx = ctxOf(L);
    const e = entityOf(L, 1) orelse return 0;
    if (ctx.world.get(e, Camera2D)) |c| c.zoom_to(@max(lua.toF32(L, 2), 0.001));
    return 0;
}

/// `camera.shake(self, trauma)` — adds trauma, which then decays.
///
/// Trauma, not amplitude: the caller says how hard it was hit and the camera
/// decides how long the screen keeps moving. A second hit while the first is
/// still decaying ADDS, which is what makes a long barrage feel cumulative
/// instead of restarting.
fn lua_camera_shake(L: ?*lua_State) callconv(.c) c_int {
    const ctx = ctxOf(L);
    const e = entityOf(L, 1) orelse return 0;
    if (ctx.world.get(e, Camera2D)) |c| c.add_trauma(@max(lua.toF32(L, 2), 0));
    return 0;
}

/// `camera.set_limits(self, x, y, w, h)` — the rectangle the camera may not
/// leave. A zero width or height disables it, which is what a level with no
/// bounds and what a test both want.
fn lua_camera_set_limits(L: ?*lua_State) callconv(.c) c_int {
    const ctx = ctxOf(L);
    const e = entityOf(L, 1) orelse return 0;
    const w = lua.toF32(L, 4);
    const h = lua.toF32(L, 5);
    if (ctx.world.get(e, Camera2D)) |c| {
        c.set_limits(.{
            .position = .{ .x = lua.toF32(L, 2), .y = lua.toF32(L, 3) },
            .size = .{ .x = w, .y = h },
        }, w > 0 and h > 0);
    }
    return 0;
}

/// `camera.set_damping(self, damping)` — 0 is a camera welded to its target
/// (what a platformer with a fixed view wants); higher is a lazier one. It is
/// one number because a critically-damped spring needs one number.
fn lua_camera_set_damping(L: ?*lua_State) callconv(.c) c_int {
    const ctx = ctxOf(L);
    const e = entityOf(L, 1) orelse return 0;
    if (ctx.world.get(e, Camera2D)) |c| c.damping = @max(lua.toF32(L, 2), 0);
    return 0;
}

/// `camera.get_centre(self) -> x, y` — where the camera is, in world units.
///
/// Returned because a behavior that aims, spawns off-screen or asks "is the
/// player near the edge" needs the same number the renderer uses, and computing
/// it again in Lua would drift from it.
fn lua_camera_get_centre(L: ?*lua_State) callconv(.c) c_int {
    const ctx = ctxOf(L);
    const e = entityOf(L, 1) orelse return 0;
    const c = ctx.world.get(e, Camera2D) orelse return 0;
    lua.pushF32(L, c._offset.x);
    lua.pushF32(L, c._offset.y);
    return 2;
}

// ── Animation (M13) ─────────────────────────────────────────────────────────

fn lua_anim_new(L: ?*lua_State) callconv(.c) c_int {
    const ctx = ctxOf(L);
    const e = entityOf(L, 1) orelse return 0;
    if (ctx.world.get(e, components.AnimationPlayer) == null) {
        _ = ctx.world.add(e, components.AnimationPlayer{}) catch return 0;
    }
    return 0;
}

fn lua_anim_play(L: ?*lua_State) callconv(.c) c_int {
    const ctx = ctxOf(L);
    const e = entityOf(L, 1) orelse return 0;
    if (ctx.world.get(e, components.AnimationPlayer) == null) {
        _ = ctx.world.add(e, components.AnimationPlayer{}) catch return 0;
    }
    const p = ctx.world.get(e, components.AnimationPlayer).?;
    const clip_id: u32 = if (lua.getTop(L) >= 2) @intFromFloat(@max(lua.toF32(L, 2), 0)) else p.clip_id;
    // A third argument blends over that many seconds instead of cutting. A
    // blend with nothing playing (or a replay of the same clip) has nothing to
    // fade FROM, so it falls through to a hard start.
    const blend: f32 = if (lua.getTop(L) >= 3) @max(lua.toF32(L, 3), 0) else 0;
    if (blend > 0 and p.clip_id != 0 and p.clip_id != clip_id) {
        p.next_clip_id = clip_id;
        p.blend_duration = blend;
        p.blend_remaining = 0; // the system arms it on the next tick
        return 0;
    }
    p.clip_id = clip_id;
    p.time = 0;
    p.next_clip_id = 0;
    p.blend_remaining = 0;
    p.blend_duration = 0;
    p.state = 1;
    return 0;
}

fn lua_anim_stop(L: ?*lua_State) callconv(.c) c_int {
    const ctx = ctxOf(L);
    const e = entityOf(L, 1) orelse return 0;
    if (ctx.world.get(e, components.AnimationPlayer)) |p| {
        p.clip_id = 0;
        p.time = 0;
        p.state = 0;
    }
    return 0;
}

fn lua_anim_pause(L: ?*lua_State) callconv(.c) c_int {
    const ctx = ctxOf(L);
    const e = entityOf(L, 1) orelse return 0;
    if (ctx.world.get(e, components.AnimationPlayer)) |p| p.speed = 0;
    return 0;
}

fn lua_anim_resume(L: ?*lua_State) callconv(.c) c_int {
    const ctx = ctxOf(L);
    const e = entityOf(L, 1) orelse return 0;
    if (ctx.world.get(e, components.AnimationPlayer)) |p| {
        if (p.speed == 0) p.speed = 1;
    }
    return 0;
}

fn lua_anim_seek(L: ?*lua_State) callconv(.c) c_int {
    const ctx = ctxOf(L);
    const e = entityOf(L, 1) orelse return 0;
    if (ctx.world.get(e, components.AnimationPlayer)) |p| p.time = @max(lua.toF32(L, 2), 0);
    return 0;
}

fn lua_anim_set_speed(L: ?*lua_State) callconv(.c) c_int {
    const ctx = ctxOf(L);
    const e = entityOf(L, 1) orelse return 0;
    if (ctx.world.get(e, components.AnimationPlayer)) |p| p.speed = lua.toF32(L, 2);
    return 0;
}

fn lua_anim_queue(L: ?*lua_State) callconv(.c) c_int {
    const ctx = ctxOf(L);
    const e = entityOf(L, 1) orelse return 0;
    const clip_id: u32 = @intFromFloat(@max(lua.toF32(L, 2), 0));
    ecs.animation.System.queueClip(ctx.world, e, clip_id);
    return 0;
}

fn lua_anim_state(L: ?*lua_State) callconv(.c) c_int {
    const ctx = ctxOf(L);
    const e = entityOf(L, 1) orelse return 0;
    const p = ctx.world.get(e, components.AnimationPlayer) orelse return 0;
    lua.lua_pushinteger(L, @intCast(p.state));
    return 1;
}

fn lua_anim_time(L: ?*lua_State) callconv(.c) c_int {
    const ctx = ctxOf(L);
    const e = entityOf(L, 1) orelse return 0;
    const p = ctx.world.get(e, components.AnimationPlayer) orelse return 0;
    lua.pushF32(L, p.time);
    return 1;
}

fn lua_anim_length(L: ?*lua_State) callconv(.c) c_int {
    const ctx = ctxOf(L);
    const e = entityOf(L, 1) orelse return 0;
    const p = ctx.world.get(e, components.AnimationPlayer) orelse return 0;
    if (ctx.animations) |sys| {
        if (sys.clips.get(p.clip_id)) |clip| {
            lua.pushF32(L, clip.duration);
            return 1;
        }
    }
    return 0;
}

fn lua_anim_is_playing(L: ?*lua_State) callconv(.c) c_int {
    const ctx = ctxOf(L);
    const e = entityOf(L, 1) orelse return 0;
    const p = ctx.world.get(e, components.AnimationPlayer) orelse return 0;
    lua.lua_pushboolean(L, if (p.state == 1) 1 else 0);
    return 1;
}

/// `anim.load(path) -> clip_id` — decodes a `.anim` clip file and registers it,
/// returning the handle to pass to `anim.play`. Calling it again for the same
/// path hot-reloads the clip under the SAME id, so a player mid-clip keeps its
/// playback position. Returns nil when the animation system is not wired or the
/// file cannot be decoded.
fn lua_anim_load(L: ?*lua_State) callconv(.c) c_int {
    const ctx = ctxOf(L);
    const path = lua.toSlice(L, 1) orelse return 0;
    const sys = ctx.animations orelse return 0;
    const id = sys.loadFile(path) catch return 0;
    lua.lua_pushinteger(L, @intCast(id));
    return 1;
}

/// `anim.set_param(self, name, value)` — sets one playback parameter by name.
/// Recognised names: `"speed"`, `"time"`, `"clip"`, `"blend"`, `"state"`.
/// Unknown names are ignored: a typo must not abort the frame.
fn lua_anim_set_param(L: ?*lua_State) callconv(.c) c_int {
    const ctx = ctxOf(L);
    const e = entityOf(L, 1) orelse return 0;
    const p = ctx.world.get(e, components.AnimationPlayer) orelse return 0;
    const name = lua.toSlice(L, 2) orelse return 0;
    const value = lua.toF32(L, 3);
    if (std.mem.eql(u8, name, "speed")) {
        p.speed = value;
    } else if (std.mem.eql(u8, name, "time")) {
        p.time = @max(value, 0);
    } else if (std.mem.eql(u8, name, "clip")) {
        p.clip_id = @intFromFloat(@max(value, 0));
        p.time = 0;
        p.state = 1;
    } else if (std.mem.eql(u8, name, "blend")) {
        p.blend_duration = @max(value, 0);
        p.blend_remaining = 0; // the system arms it on the next tick
    } else if (std.mem.eql(u8, name, "state")) {
        p.state = @intFromFloat(@max(value, 0));
    }
    return 0;
}

const anim_regs = [_]luaL_Reg{
    .{ .name = "new", .func = lua_anim_new },
    .{ .name = "load", .func = lua_anim_load },
    .{ .name = "play", .func = lua_anim_play },
    .{ .name = "set_param", .func = lua_anim_set_param },
    .{ .name = "stop", .func = lua_anim_stop },
    .{ .name = "pause", .func = lua_anim_pause },
    .{ .name = "resume", .func = lua_anim_resume },
    .{ .name = "seek", .func = lua_anim_seek },
    .{ .name = "set_speed", .func = lua_anim_set_speed },
    .{ .name = "queue", .func = lua_anim_queue },
    .{ .name = "state", .func = lua_anim_state },
    .{ .name = "time", .func = lua_anim_time },
    .{ .name = "length", .func = lua_anim_length },
    .{ .name = "is_playing", .func = lua_anim_is_playing },
    .{ .name = null, .func = null },
};

const camera_regs = [_]luaL_Reg{
    .{ .name = "new", .func = lua_camera_new },
    .{ .name = "follow", .func = lua_camera_follow },
    .{ .name = "zoom_to", .func = lua_camera_zoom_to },
    .{ .name = "shake", .func = lua_camera_shake },
    .{ .name = "set_limits", .func = lua_camera_set_limits },
    .{ .name = "set_damping", .func = lua_camera_set_damping },
    .{ .name = "get_centre", .func = lua_camera_get_centre },
    .{ .name = null, .func = null },
};

// ── Timer (M4.5) ─────────────────────────────────────────────────────────────
//
// A timer is a component, not a Lua closure, which is the whole reason it can be
// authored in a scene file, saved and restored bit-exactly, and survive a
// hot-reload. The callback is a SIGNAL NAME: the tick queues it on the world bus
// and forwards it to every `on_signal`, so a timer and a collision arrive in the
// same handler the same way.

/// `timer.new(self, seconds, kind)` — kind 0 once, 1 loop, 2 during (fires the
/// tick signal every tick and the done signal every cycle).
fn lua_timer_new(L: ?*lua_State) callconv(.c) c_int {
    const ctx = ctxOf(L);
    const e = entityOf(L, 1) orelse return 0;
    const kind: u8 = @intFromFloat(@max(lua.toF32(L, 3), 0));
    var t = components.Timer{ .duration = @max(lua.toF32(L, 2), 0) };
    t.kind = switch (kind) {
        1 => .loop,
        2 => .during,
        else => .once,
    };
    if (ctx.world.get(e, components.Timer) == null) {
        _ = ctx.world.add(e, t) catch return 0;
    }
    return 0;
}

/// `timer.set_signals(self, on_tick, on_done)` — an empty name fires nothing,
/// which is how a timer becomes a silent metronome that only `progress` reads.
fn lua_timer_set_signals(L: ?*lua_State) callconv(.c) c_int {
    const ctx = ctxOf(L);
    const e = entityOf(L, 1) orelse return 0;
    const t = ctx.world.get(e, components.Timer) orelse return 0;
    // `toString` returns "" for a non-string or a nil, and an empty signal name
    // means "fire nothing", so "" is exactly the case that needs no write. One
    // read per argument: calling it twice to test and then to copy would read the
    // Lua stack twice for the same value.
    const tick = lua.toString(L, 2);
    const done = lua.toString(L, 3);
    if (tick.len > 0) t.tick_signal.set(tick);
    if (done.len > 0) t.done_signal.set(done);
    return 0;
}

/// `timer.start(self, loops)` — 0 loops means forever.
///
/// There is no `autostart` field: a timer in the world ticks from the moment it
/// exists, so a timer declared in a scene file runs without any script. What
/// `start` does is put it back to zero (a timer that already fired is
/// `finished`, and the tick skips those) and set how many cycles it runs.
fn lua_timer_start(L: ?*lua_State) callconv(.c) c_int {
    const ctx = ctxOf(L);
    const e = entityOf(L, 1) orelse return 0;
    const t = ctx.world.get(e, components.Timer) orelse return 0;
    t.paused = false;
    t.finished = false;
    t.current_loop = 0;
    t.elapsed = 0;
    t.loop_count = @intFromFloat(@max(lua.toF32(L, 2), 0));
    return 0;
}

/// `timer.stop(self)` — pauses WITHOUT losing `elapsed`, so starting again
/// resumes where it was rather than restarting. Stopping for good is
/// `timer.kill`.
fn lua_timer_stop(L: ?*lua_State) callconv(.c) c_int {
    const ctx = ctxOf(L);
    const e = entityOf(L, 1) orelse return 0;
    if (ctx.world.get(e, components.Timer)) |t| t.paused = true;
    return 0;
}

/// `timer.kill(self)` — finishes it: no more signals ever, and `finished` is
/// what the system checks, so this takes effect on the very next tick.
fn lua_timer_kill(L: ?*lua_State) callconv(.c) c_int {
    const ctx = ctxOf(L);
    const e = entityOf(L, 1) orelse return 0;
    if (ctx.world.get(e, components.Timer)) |t| t.finished = true;
    return 0;
}

/// `timer.progress(self) -> 0..1` — how far through the current cycle.
///
/// The one timer value a UI needs: a cooldown swipe, a reload bar. It is derived
/// from the component's own state, so a bar and the signal that ends it can never
/// disagree about when the timer is done.
fn lua_timer_progress(L: ?*lua_State) callconv(.c) c_int {
    const ctx = ctxOf(L);
    const e = entityOf(L, 1) orelse return 0;
    const t = ctx.world.get(e, components.Timer) orelse return 0;
    lua.pushF32(L, t.progress());
    return 1;
}

/// `timer.restart(self)` — puts the timer back to zero and runs it again.
///
/// The configuration survives: the duration, the kind, the loop count and the
/// signals are all still there. Only the progress is reset — the elapsed time,
/// the cycle counter and the finished flag.
fn lua_timer_restart(L: ?*lua_State) callconv(.c) c_int {
    const ctx = ctxOf(L);
    const e = entityOf(L, 1) orelse return 0;
    const t = ctx.world.get(e, components.Timer) orelse return 0;
    t.restart();
    t.paused = false;
    return 0;
}

/// `timer.set_duration(self, seconds)` — how long one cycle takes.
fn lua_timer_set_duration(L: ?*lua_State) callconv(.c) c_int {
    const ctx = ctxOf(L);
    const e = entityOf(L, 1) orelse return 0;
    const t = ctx.world.get(e, components.Timer) orelse return 0;
    t.duration = @max(lua.toF32(L, 2), 0);
    return 0;
}

/// `timer.get_duration(self) -> seconds`.
fn lua_timer_get_duration(L: ?*lua_State) callconv(.c) c_int {
    const ctx = ctxOf(L);
    const e = entityOf(L, 1) orelse return 0;
    const t = ctx.world.get(e, components.Timer) orelse return 0;
    lua.pushF32(L, t.duration);
    return 1;
}

/// `timer.get_elapsed(self) -> seconds` — how far into the current cycle it is.
fn lua_timer_get_elapsed(L: ?*lua_State) callconv(.c) c_int {
    const ctx = ctxOf(L);
    const e = entityOf(L, 1) orelse return 0;
    const t = ctx.world.get(e, components.Timer) orelse return 0;
    lua.pushF32(L, t.elapsed);
    return 1;
}

/// `timer.get_loops(self) -> count, current` — how many cycles it will run and
/// how many it has run.
fn lua_timer_get_loops(L: ?*lua_State) callconv(.c) c_int {
    const ctx = ctxOf(L);
    const e = entityOf(L, 1) orelse return 0;
    const t = ctx.world.get(e, components.Timer) orelse return 0;
    lua.lua_pushinteger(L, @intCast(t.loop_count));
    lua.lua_pushinteger(L, @intCast(t.current_loop));
    return 2;
}

/// `timer.set_kind(self, kind)` — 0 once, 1 loop, 2 during.
///
/// Changing the kind does not restart the timer: the elapsed time and the
/// cycle counter are still where they were.
fn lua_timer_set_kind(L: ?*lua_State) callconv(.c) c_int {
    const ctx = ctxOf(L);
    const e = entityOf(L, 1) orelse return 0;
    const t = ctx.world.get(e, components.Timer) orelse return 0;
    const kind: u32 = @intFromFloat(@max(lua.toF32(L, 2), 0));
    t.kind = switch (kind) {
        1 => .loop,
        2 => .during,
        else => .once,
    };
    return 0;
}

/// `timer.set_time_scale(self, scale)` — this timer's own speed.
///
/// 1 is normal, 0.5 is half as fast, 0 stops the timer where it is. It
/// multiplies with the GLOBAL scale (`time.scale`): a slow-motion game slows
/// every timer, and a timer slower than the game is slower still.
fn lua_timer_set_time_scale(L: ?*lua_State) callconv(.c) c_int {
    const ctx = ctxOf(L);
    const e = entityOf(L, 1) orelse return 0;
    const t = ctx.world.get(e, components.Timer) orelse return 0;
    const s = lua.toF32(L, 2);
    if (std.math.isNan(s)) return 0;
    t.time_scale = std.math.clamp(s, 0.0, 100.0);
    return 0;
}

/// `timer.is_finished(self) -> boolean` — true once the timer has done its job.
fn lua_timer_is_finished(L: ?*lua_State) callconv(.c) c_int {
    const ctx = ctxOf(L);
    const e = entityOf(L, 1) orelse return 0;
    const t = ctx.world.get(e, components.Timer) orelse return 0;
    return pushBool(L, t.finished);
}

/// `timer.is_paused(self) -> boolean` — true while the timer is stopped.
fn lua_timer_is_paused(L: ?*lua_State) callconv(.c) c_int {
    const ctx = ctxOf(L);
    const e = entityOf(L, 1) orelse return 0;
    const t = ctx.world.get(e, components.Timer) orelse return 0;
    return pushBool(L, t.paused);
}

/// `timer.get_dropped(self) -> count` — the cycles this timer could not run.
///
/// Zero in a healthy game. A number that grows says the timer is running late
/// because one tick asked for more cycles than the engine runs at once.
fn lua_timer_get_dropped(L: ?*lua_State) callconv(.c) c_int {
    const ctx = ctxOf(L);
    const e = entityOf(L, 1) orelse return 0;
    const t = ctx.world.get(e, components.Timer) orelse return 0;
    lua.lua_pushinteger(L, @intCast(t.dropped_cycles));
    return 1;
}

const timer_regs = [_]luaL_Reg{
    .{ .name = "new", .func = lua_timer_new },
    .{ .name = "set_signals", .func = lua_timer_set_signals },
    .{ .name = "start", .func = lua_timer_start },
    .{ .name = "stop", .func = lua_timer_stop },
    .{ .name = "kill", .func = lua_timer_kill },
    .{ .name = "progress", .func = lua_timer_progress },
    .{ .name = "restart", .func = lua_timer_restart },
    .{ .name = "set_duration", .func = lua_timer_set_duration },
    .{ .name = "get_duration", .func = lua_timer_get_duration },
    .{ .name = "get_elapsed", .func = lua_timer_get_elapsed },
    .{ .name = "get_loops", .func = lua_timer_get_loops },
    .{ .name = "set_kind", .func = lua_timer_set_kind },
    .{ .name = "set_time_scale", .func = lua_timer_set_time_scale },
    .{ .name = "is_finished", .func = lua_timer_is_finished },
    .{ .name = "is_paused", .func = lua_timer_is_paused },
    .{ .name = "get_dropped", .func = lua_timer_get_dropped },
    .{ .name = null, .func = null },
};

// ── time: the game clock and the global time scale ───────────────────────────
//
// The clock GAMEPLAY reads, and the engine's one time dial. Every number here
// comes from the same `GameTime` the simulation runs on, so a script can never
// see a delta that disagrees with the world it is moving in.
//
// The scale is GLOBAL: 0 is paused, 0.5 is slow motion, 2 is double speed. It
// slows the SIMULATION — physics, timers, animation, particles — and the `dt`
// the scripts are handed. It does NOT stop the frame loop: a pause menu has to
// keep reading the input and keep drawing, and a paused game that freezes its
// own UI is a worse pause.
//
// The one thing the scale does not touch is PRESENTATION: a scene fade runs on
// real time, because a transition that takes 0.5 s of game time would take 5 s
// of real time in slow motion, which is nobody's idea of a fade.

/// `time.delta() -> seconds` — the last frame's SCALED delta.
///
/// The same number the simulation advanced by, so `self.x = self.x + v * dt`
/// moves at the speed the world moves. It is 0 while the game is paused.
fn lua_time_delta(L: ?*lua_State) callconv(.c) c_int {
    const ctx = ctxOf(L);
    // No clock wired (a headless tool, a test): a zero delta, not a crash.
    // Zero is the SAFE answer — a script that multiplies by it gets a still
    // frame instead of a segfault.
    lua.pushF32(L, if (ctx.time) |t| t.delta else 0);
    return 1;
}

/// `time.unscaled_delta() -> seconds` — the last frame's REAL delta.
///
/// The wall clock, unaffected by the scale. A UI that has to keep moving while
/// the game is paused (a loading spinner) reads this one.
fn lua_time_unscaled_delta(L: ?*lua_State) callconv(.c) c_int {
    const ctx = ctxOf(L);
    lua.pushF32(L, if (ctx.time) |t| t.unscaled_delta else 0);
    return 1;
}

/// `time.elapsed() -> seconds` — scaled game time since boot.
///
/// What a gameplay timer counts: it slows down with the game, so "10 seconds
/// into the level" means ten seconds of PLAY, not ten seconds of wall clock.
fn lua_time_elapsed(L: ?*lua_State) callconv(.c) c_int {
    const ctx = ctxOf(L);
    lua.pushF32(L, if (ctx.time) |t| t.elapsed else 0);
    return 1;
}

/// `time.unscaled_elapsed() -> seconds` — real time since boot.
fn lua_time_unscaled_elapsed(L: ?*lua_State) callconv(.c) c_int {
    const ctx = ctxOf(L);
    lua.pushF32(L, if (ctx.time) |t| t.unscaled_elapsed else 0);
    return 1;
}

/// `time.frame() -> number` — the frame counter.
fn lua_time_frame(L: ?*lua_State) callconv(.c) c_int {
    const ctx = ctxOf(L);
    const frame: isize = if (ctx.time) |t| @intCast(t.frame) else 0;
    lua.lua_pushinteger(L, frame);
    return 1;
}

/// `time.physics_delta() -> seconds` — the fixed simulation step (1/60).
///
/// The step the SOLVER uses, not the frame's delta: it is the number to
/// integrate against when the answer must not depend on the frame rate.
fn lua_time_physics_delta(L: ?*lua_State) callconv(.c) c_int {
    const ctx = ctxOf(L);
    lua.pushF32(L, if (ctx.time) |t| t.physicsDelta() else 0);
    return 1;
}

/// `time.scale() -> number` — the global time scale. 1 is normal.
fn lua_time_scale(L: ?*lua_State) callconv(.c) c_int {
    const ctx = ctxOf(L);
    lua.pushF32(L, if (ctx.time) |t| t.scale else 1);
    return 1;
}

/// `time.set_scale(s)` — sets the global time scale.
///
/// 0 pauses, 0.5 is slow motion, 2 is double speed. Clamped to
/// `[0, 100]`: a negative scale would run the simulation backwards, which
/// nothing supports. A NaN is ignored rather than applied.
fn lua_time_set_scale(L: ?*lua_State) callconv(.c) c_int {
    const ctx = ctxOf(L);
    const t = ctx.time orelse return 0;
    t.setScale(lua.toF32(L, 1));
    return 0;
}

/// `time.pause()` — pauses the simulation.
///
/// The scale goes to 0 and the scale in force is remembered, so `resume`
/// brings back slow motion if that is what was running.
fn lua_time_pause(L: ?*lua_State) callconv(.c) c_int {
    const ctx = ctxOf(L);
    if (ctx.time) |t| t.pause();
    return 0;
}

/// `time.resume()` — unpauses, restoring the scale that was in force.
fn lua_time_resume(L: ?*lua_State) callconv(.c) c_int {
    const ctx = ctxOf(L);
    if (ctx.time) |t| t.unpause();
    return 0;
}

/// `time.is_paused() -> boolean`.
fn lua_time_is_paused(L: ?*lua_State) callconv(.c) c_int {
    const ctx = ctxOf(L);
    return pushBool(L, if (ctx.time) |t| t.isPaused() else false);
}


// ── flow: the global state machine, with a stack of states ───────────────────
//
// The game's own phases: menu → playing → paused → game over. It is GLOBAL
// (no entity) because the flow belongs to the GAME, and it has a STACK because
// "paused" sits ON TOP of "playing" and leaving it must return there.
//
// Every function takes the OWNING global's `self` first, the same shape as
// `sm.*`: the flow's callbacks run with that table, and a global that does not
// own the flow cannot drive it.

/// The registry ref of the global whose `self` table is at `idx`.
fn globalSelfRef(L: ?*lua_State, idx: c_int) i32 {
    const ctx = ctxOf(L);
    const hooks = ctx.globals orelse return statemachine_mod.no_ref;
    return hooks.global_ref_of_self(hooks.ctx, L, idx);
}

/// The flow, when the caller at `idx` OWNS it. A global that does not own the
/// flow gets nothing: one game, one flow.
fn ownedFlow(L: ?*lua_State, idx: c_int) ?*statemachine_mod.Registry {
    const ctx = ctxOf(L);
    const reg = ctx.machines orelse return null;
    if (!reg.hasFlow()) return null;
    const self_ref = globalSelfRef(L, idx);
    if (self_ref == statemachine_mod.no_ref) return null;
    if (self_ref != reg.flow.self_ref) return null;
    return reg;
}

/// `flow.add_state(self, name, hooks) -> boolean`.
///
/// Declares a state of the flow. The first call creates the flow and binds it
/// to this global. The hooks are the same `{ enter, update, exit }` the
/// per-entity state machine takes, and they receive THIS global's `self`.
fn lua_flow_add_state(L: ?*lua_State) callconv(.c) c_int {
    const ctx = ctxOf(L);
    const reg = ctx.machines orelse return 0;
    const self_ref = globalSelfRef(L, 1);
    if (self_ref == statemachine_mod.no_ref) return 0; // not a global
    const name = lua.toSlice(L, 2) orelse return 0;

    // The flow's machine, created on first use.
    var machine_id = reg.flow.machine;
    if (machine_id == 0) {
        machine_id = reg.createMachine();
        if (machine_id == 0) return 0;
        _ = reg.declareFlow(machine_id, self_ref);
    }
    const idx = reg.addState(machine_id, name) catch return 0;
    const st = &reg.machines[machine_id].states[idx];
    st.enter_ref = refStateHook(L, reg, 3, "enter");
    st.update_ref = refStateHook(L, reg, 3, "update");
    st.exit_ref = refStateHook(L, reg, 3, "exit");
    return pushTrue(L);
}

/// `flow.add_transition(self, from, event, to) -> boolean`.
fn lua_flow_add_transition(L: ?*lua_State) callconv(.c) c_int {
    const reg = ownedFlow(L, 1) orelse return 0;
    const from = lua.toSlice(L, 2) orelse return 0;
    const event = lua.toSlice(L, 3) orelse return 0;
    const to = lua.toSlice(L, 4) orelse return 0;
    reg.addTransition(reg.flow.machine, from, event, to) catch return 0;
    return pushTrue(L);
}

/// `flow.set_initial(self, name) -> boolean` — the state the flow starts in.
fn lua_flow_set_initial(L: ?*lua_State) callconv(.c) c_int {
    const reg = ownedFlow(L, 1) orelse return 0;
    const name = lua.toSlice(L, 2) orelse return 0;
    reg.setInitial(reg.flow.machine, name) catch return 0;
    return pushTrue(L);
}

/// `flow.fire(self, event)` — requests a transition.
///
/// Applied at the TOP of the next tick, like `sm.fire`: a callback that fires
/// cannot re-enter the flow. A transition REPLACES the whole stack: the game's
/// phase changed, not the layer on top of it.
fn lua_flow_fire(L: ?*lua_State) callconv(.c) c_int {
    const reg = ownedFlow(L, 1) orelse return 0;
    const event = lua.toSlice(L, 2) orelse return 0;
    reg.flowFire(event);
    return 0;
}

/// `flow.set_state(self, name) -> boolean` — jumps to a state NOW.
///
/// The whole stack is replaced. For a layered change use `flow.push`.
fn lua_flow_set_state(L: ?*lua_State) callconv(.c) c_int {
    const reg = ownedFlow(L, 1) orelse return 0;
    const name = lua.toSlice(L, 2) orelse return 0;
    const idx = reg.stateIndex(reg.flow.machine, name) orelse return 0;
    if (!reg.flowReplace(idx)) return 0;
    return pushTrue(L);
}

/// `flow.push(self, name) -> boolean` — pushes a state on the stack.
///
/// The state below stays: `flow.pop()` returns to it. This is how "paused"
/// sits on top of "playing".
fn lua_flow_push(L: ?*lua_State) callconv(.c) c_int {
    const reg = ownedFlow(L, 1) orelse return 0;
    const name = lua.toSlice(L, 2) orelse return 0;
    const idx = reg.stateIndex(reg.flow.machine, name) orelse return 0;
    if (!reg.flowPush(idx)) return 0;
    return pushTrue(L);
}

/// `flow.pop(self) -> boolean` — leaves the top of the stack.
///
/// False when the stack has only the bottom state: the flow always has a
/// phase.
fn lua_flow_pop(L: ?*lua_State) callconv(.c) c_int {
    const reg = ownedFlow(L, 1) orelse return 0;
    return pushBool(L, reg.flowPop());
}

/// `flow.state(self) -> string` — the state on the top of the stack.
fn lua_flow_state(L: ?*lua_State) callconv(.c) c_int {
    const reg = ownedFlow(L, 1) orelse {
        lua.pushNil(L);
        return 1;
    };
    lua.pushSlice(L, reg.flowStateName());
    return 1;
}

/// `flow.is_in(self, name) -> boolean`.
fn lua_flow_is_in(L: ?*lua_State) callconv(.c) c_int {
    const reg = ownedFlow(L, 1) orelse return pushBool(L, false);
    const name = lua.toSlice(L, 2) orelse return pushBool(L, false);
    return pushBool(L, reg.flowIsIn(name));
}

/// `flow.stack(self) -> table` — the states on the stack, bottom to top.
fn lua_flow_stack(L: ?*lua_State) callconv(.c) c_int {
    const reg = ownedFlow(L, 1) orelse {
        lua.lua_createtable(L, 0, 0);
        return 1;
    };
    var names: [statemachine_mod.max_stack][]const u8 = undefined;
    const n = reg.flowStackNames(&names);
    lua.lua_createtable(L, 0, @intCast(n));
    for (names[0..n], 0..) |name, i| {
        lua.pushSlice(L, name);
        lua.lua_rawseti(L, -2, @intCast(i + 1));
    }
    return 1;
}

const flow_regs = [_]luaL_Reg{
    .{ .name = "add_state", .func = lua_flow_add_state },
    .{ .name = "add_transition", .func = lua_flow_add_transition },
    .{ .name = "set_initial", .func = lua_flow_set_initial },
    .{ .name = "fire", .func = lua_flow_fire },
    .{ .name = "set_state", .func = lua_flow_set_state },
    .{ .name = "push", .func = lua_flow_push },
    .{ .name = "pop", .func = lua_flow_pop },
    .{ .name = "state", .func = lua_flow_state },
    .{ .name = "is_in", .func = lua_flow_is_in },
    .{ .name = "stack", .func = lua_flow_stack },
    .{ .name = null, .func = null },
};

const time_regs = [_]luaL_Reg{
    .{ .name = "delta", .func = lua_time_delta },
    .{ .name = "unscaled_delta", .func = lua_time_unscaled_delta },
    .{ .name = "elapsed", .func = lua_time_elapsed },
    .{ .name = "unscaled_elapsed", .func = lua_time_unscaled_elapsed },
    .{ .name = "frame", .func = lua_time_frame },
    .{ .name = "physics_delta", .func = lua_time_physics_delta },
    .{ .name = "scale", .func = lua_time_scale },
    .{ .name = "set_scale", .func = lua_time_set_scale },
    .{ .name = "pause", .func = lua_time_pause },
    .{ .name = "resume", .func = lua_time_resume },
    .{ .name = "is_paused", .func = lua_time_is_paused },
    .{ .name = null, .func = null },
};

// ── tween: a value that moves to another value over time ─────────────────────
//
// The answer to "slide the panel in", "fade the sprite out" and "punch the
// player back", without a frame counter in the script.
//
// A tween drives a COMPONENT of an actor — the real `Transform`, the real
// `Sprite.tint` — so the renderer draws the result. It is not a number in a
// Lua table that happens to look like a position.
//
// Every tween returns a HANDLE: a small integer that identifies it until it
// finishes. The handle is what `tween.kill` and `tween.chain` take.

/// The properties a tween can drive, in the order the doc lists them.
const tween_property_names = [_][]const u8{
    "position",   "position.x", "position.y",
    "rotation",
    "scale",      "scale.x",    "scale.y",
    "tint",       "tint.r",     "tint.g",     "tint.b",     "tint.a",
    "color",      "color.r",    "color.g",    "color.b",    "color.a",
    "energy",
    "radius",
    "value",
    "duration",
};

/// Reads a Lua argument into a tween value, shaped by the property it drives.
///
/// The SHAPE comes from the property, not from the argument: "position" is a
/// vector, "tint" is a colour, "rotation" is a number. A number given for a
/// vector is a uniform one (`{x = 5, y = 5}`), which is what a designer means
/// by "scale it by five".
fn tweenValueFromLua(L: ?*lua_State, idx: c_int, field: tween_mod.Field, part: tween_mod.Part) ?tween_mod.Value {
    // A sub-field ("position.x") is always a number.
    if (part != .whole) {
        if (!lua.isNumber(L, idx)) return null;
        return .{ .scalar = lua.toF32(L, idx) };
    }
    switch (field) {
        .position, .scale => {
            if (lua.isTable(L, idx)) {
                var v = components.Vec2{};
                lua.getField(L, idx, "x");
                if (lua.isNumber(L, -1)) v.x = lua.toF32(L, -1);
                lua.pop(L, 1);
                lua.getField(L, idx, "y");
                if (lua.isNumber(L, -1)) v.y = lua.toF32(L, -1);
                lua.pop(L, 1);
                return .{ .vec2 = v };
            }
            if (lua.isNumber(L, idx)) {
                const s = lua.toF32(L, idx);
                return .{ .vec2 = .{ .x = s, .y = s } };
            }
            return null;
        },
        .tint, .color => {
            if (lua.isTable(L, idx)) {
                // A missing channel keeps its DEFAULT, and the default alpha is
                // 1: a colour written without an alpha is opaque, not
                // invisible.
                var c = [4]f32{ 1, 1, 1, 1 };
                const names = [_][*:0]const u8{ "r", "g", "b", "a" };
                for (names, 0..) |name, i| {
                    lua.getField(L, idx, name);
                    if (lua.isNumber(L, -1)) c[i] = lua.toF32(L, -1);
                    lua.pop(L, 1);
                }
                return .{ .color = c };
            }
            if (lua.isNumber(L, idx)) {
                const s = lua.toF32(L, idx);
                return .{ .color = .{ s, s, s, s } };
            }
            return null;
        },
        else => {
            if (!lua.isNumber(L, idx)) return null;
            return .{ .scalar = lua.toF32(L, idx) };
        },
    }
}

/// Reads the tween options table: `{ easing, delay, repeat, yoyo, hold, on_complete }`.
fn tweenOptionsFromLua(L: ?*lua_State, idx: c_int, pool: *tween_mod.Manager) tween_mod.Options {
    var opts = tween_mod.Options{};
    if (!lua.isTable(L, idx)) return opts;

    lua.getField(L, idx, "easing");
    if (lua.isString(L, -1)) {
        // An unknown curve is IGNORED, and the tween runs linear. The
        // alternative — refusing the tween — would leave the property where it
        // is, which looks like a broken tween rather than a typo.
        if (core_math.Easing.fromName(lua.toString(L, -1))) |e| opts.easing = e;
    }
    lua.pop(L, 1);

    lua.getField(L, idx, "delay");
    if (lua.isNumber(L, -1)) opts.delay = lua.toF32(L, -1);
    lua.pop(L, 1);

    lua.getField(L, idx, "repeat");
    if (lua.isNumber(L, -1)) opts.repeat = @intFromFloat(lua.toF32(L, -1));
    lua.pop(L, 1);

    lua.getField(L, idx, "yoyo");
    opts.yoyo = lua.toBool(L, -1);
    lua.pop(L, 1);

    lua.getField(L, idx, "hold");
    opts.hold = lua.toBool(L, -1);
    lua.pop(L, 1);

    // The completion callback: a Lua function, kept alive by a registry ref
    // the pool owns and releases when the tween ends.
    lua.getField(L, idx, "on_complete");
    if (lua.isFunction(L, -1)) {
        if (pool.vm) |vm| {
            opts.on_complete = vm.refTop(); // pops
        } else {
            lua.pop(L, 1);
        }
    } else {
        lua.pop(L, 1);
    }
    return opts;
}

/// `tween.to(self, property, value, duration, opts) -> handle`.
///
/// Starts a tween that drives `property` on this actor towards `value` over
/// `duration` seconds. The handle identifies it until it finishes.
///
/// `property` is a component field, optionally with a sub-field:
/// `"position"`, `"position.x"`, `"rotation"`, `"scale"`, `"tint"`, `"tint.a"`,
/// `"color"`, `"energy"`, `"radius"`, `"value"`, `"duration"`.
///
/// `opts` is optional: `{ easing = "out_back", delay = 0.2, repeat = 2,
/// yoyo = true, hold = true, on_complete = function(self) end }`.
fn lua_tween_to(L: ?*lua_State) callconv(.c) c_int {
    const ctx = ctxOf(L);
    const pool = ctx.tweens orelse return 0;
    const e = entityOf(L, 1) orelse return 0;
    const property = lua.toString(L, 2);

    // "position.x" is the field "position" and the part "x".
    var field_name = property;
    var part_name: []const u8 = "";
    if (std.mem.lastIndexOfScalar(u8, property, '.')) |dot| {
        field_name = property[0..dot];
        part_name = property[dot + 1 ..];
    }
    const field = tween_mod.Field.fromName(field_name) orelse return 0;
    const part = tween_mod.Part.fromName(part_name);
    const to = tweenValueFromLua(L, 3, field, part) orelse return 0;
    const duration = lua.toF32(L, 4);

    var opts = tween_mod.Options{};
    if (lua.isTable(L, 5)) {
        opts = tweenOptionsFromLua(L, 5, pool);
        // The callback is called with the actor's `self`, the same shape every
        // other hook in the engine uses.
        if (opts.on_complete != tween_mod.no_ref) opts.self_ref = refTableAt(L, 1);
    }

    const handle = pool.create(e, field, part, to, duration, opts) catch return 0;
    lua.lua_pushinteger(L, @intCast(handle));
    return 1;
}

/// `tween.chain(parent, child) -> boolean`.
///
/// The child tween starts when the parent finishes. The child is parked and
/// reset, so chain it before it runs (or create it with `hold = true`) to
/// avoid a visible jump back to its start value.
fn lua_tween_chain(L: ?*lua_State) callconv(.c) c_int {
    const ctx = ctxOf(L);
    const pool = ctx.tweens orelse return 0;
    const parent: u32 = @intCast(@max(lua.toInteger(L, 1), 0));
    const child: u32 = @intCast(@max(lua.toInteger(L, 2), 0));
    const ok = pool.chain(parent, child) catch return 0;
    return pushBool(L, ok);
}

/// `tween.start(handle) -> boolean` — releases a parked tween.
fn lua_tween_start(L: ?*lua_State) callconv(.c) c_int {
    const ctx = ctxOf(L);
    const pool = ctx.tweens orelse return 0;
    const handle: u32 = @intCast(@max(lua.toInteger(L, 1), 0));
    return pushBool(L, pool.release(handle));
}

/// `tween.kill(handle) -> boolean` — stops a tween where it is.
fn lua_tween_kill(L: ?*lua_State) callconv(.c) c_int {
    const ctx = ctxOf(L);
    const pool = ctx.tweens orelse return 0;
    const handle: u32 = @intCast(@max(lua.toInteger(L, 1), 0));
    return pushBool(L, pool.kill(handle));
}

/// `tween.kill_entity(self) -> count` — stops every tween on this actor.
fn lua_tween_kill_entity(L: ?*lua_State) callconv(.c) c_int {
    const ctx = ctxOf(L);
    const pool = ctx.tweens orelse return 0;
    const e = entityOf(L, 1) orelse return 0;
    lua.lua_pushinteger(L, @intCast(pool.killEntity(e)));
    return 1;
}

/// `tween.kill_all() -> count` — stops every tween in the game.
fn lua_tween_kill_all(L: ?*lua_State) callconv(.c) c_int {
    const ctx = ctxOf(L);
    const pool = ctx.tweens orelse return 0;
    pool.killAll();
    lua.lua_pushinteger(L, @intCast(pool.liveCount()));
    return 1;
}

/// `tween.is_alive(handle) -> boolean`.
fn lua_tween_is_alive(L: ?*lua_State) callconv(.c) c_int {
    const ctx = ctxOf(L);
    const pool = ctx.tweens orelse return 0;
    const handle: u32 = @intCast(@max(lua.toInteger(L, 1), 0));
    return pushBool(L, pool.isAlive(handle));
}

/// `tween.count() -> number` — how many tweens are running.
fn lua_tween_count(L: ?*lua_State) callconv(.c) c_int {
    const ctx = ctxOf(L);
    const pool = ctx.tweens orelse {
        lua.lua_pushinteger(L, 0);
        return 1;
    };
    lua.lua_pushinteger(L, @intCast(pool.liveCount()));
    return 1;
}

/// `tween.time_scale() -> number` — the global tween speed.
fn lua_tween_time_scale(L: ?*lua_State) callconv(.c) c_int {
    const ctx = ctxOf(L);
    const pool = ctx.tweens orelse {
        lua.pushF32(L, 1);
        return 1;
    };
    lua.pushF32(L, pool.time_scale);
    return 1;
}

/// `tween.set_time_scale(s)` — the global tween speed. 0 freezes every tween.
fn lua_tween_set_time_scale(L: ?*lua_State) callconv(.c) c_int {
    const ctx = ctxOf(L);
    const pool = ctx.tweens orelse return 0;
    pool.setTimeScale(lua.toF32(L, 1));
    return 0;
}

/// `tween.properties() -> table` — every property a tween can drive.
///
/// The list is here so a script (and the editor's autocomplete) can discover
/// what is tweenable without the documentation being the only source.
fn lua_tween_properties(L: ?*lua_State) callconv(.c) c_int {
    lua.lua_createtable(L, 0, @intCast(tween_property_names.len));
    for (tween_property_names, 0..) |name, i| {
        lua.pushSlice(L, name);
        lua.lua_rawseti(L, -2, @intCast(i + 1));
    }
    return 1;
}

const tween_regs = [_]luaL_Reg{
    .{ .name = "to", .func = lua_tween_to },
    .{ .name = "chain", .func = lua_tween_chain },
    .{ .name = "start", .func = lua_tween_start },
    .{ .name = "kill", .func = lua_tween_kill },
    .{ .name = "kill_entity", .func = lua_tween_kill_entity },
    .{ .name = "kill_all", .func = lua_tween_kill_all },
    .{ .name = "is_alive", .func = lua_tween_is_alive },
    .{ .name = "count", .func = lua_tween_count },
    .{ .name = "time_scale", .func = lua_tween_time_scale },
    .{ .name = "set_time_scale", .func = lua_tween_set_time_scale },
    .{ .name = "properties", .func = lua_tween_properties },
    .{ .name = null, .func = null },
};

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
    .{ .name = "set_image", .func = lua_sprite_set_image },
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
    // PARKED: physics debug bindings are unfinished (no functions yet).
    // .{ .name = "debug_draw", .func = lua_physics_debug_draw },
    // .{ .name = "debug_flags", .func = lua_physics_debug_flags },
    // .{ .name = "debug_colors", .func = lua_physics_debug_colors },
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
    .{ .name = "pointer_over_ui", .func = lua_input_pointer_over_ui },
    .{ .name = null, .func = null },
};

/// Game UI (M14): style an actor's widget component, plus the two queries that
/// need the runtime (`measure`, `font_load`) and the two that read the frame
/// (`hovered`, `pressed`).
const ui_regs = [_]luaL_Reg{
    .{ .name = "set_anchor", .func = lua_ui_set_anchor },
    .{ .name = "set_offset", .func = lua_ui_set_offset },
    .{ .name = "set_size", .func = lua_ui_set_size },
    .{ .name = "set_pivot", .func = lua_ui_set_pivot },
    .{ .name = "set_margin", .func = lua_ui_set_margin },
    .{ .name = "set_order", .func = lua_ui_set_order },
    .{ .name = "set_visible", .func = lua_ui_set_visible },
    .{ .name = "set_interactive", .func = lua_ui_set_interactive },
    .{ .name = "set_text", .func = lua_ui_set_text },
    .{ .name = "set_font", .func = lua_ui_set_font },
    .{ .name = "set_color", .func = lua_ui_set_color },
    .{ .name = "set_colors", .func = lua_ui_set_colors },
    .{ .name = "set_border", .func = lua_ui_set_border },
    .{ .name = "set_show_text", .func = lua_ui_set_show_text },
    .{ .name = "set_value", .func = lua_ui_set_value },
    .{ .name = "set_align", .func = lua_ui_set_align },
    .{ .name = "set_enabled", .func = lua_ui_set_enabled },
    .{ .name = "measure", .func = lua_ui_measure },
    .{ .name = "rect", .func = lua_ui_rect },
    .{ .name = "hovered", .func = lua_ui_hovered },
    .{ .name = "pressed", .func = lua_ui_pressed },
    .{ .name = "font_load", .func = lua_ui_font_load },
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
    .{ .name = "ease", .func = lua_math_ease },
    .{ .name = "easings", .func = lua_math_easings },
    .{ .name = null, .func = null },
};

/// `math.ease(name, t) -> number` — the easing curve, `t` in `[0,1]`.
///
/// The same curves the tween uses: `"linear"`, `"in_quad"`, `"out_cubic"`,
/// `"in_out_back"`, `"out_elastic"`, `"out_bounce"`… A curve starts at 0 and
/// ends at 1, and the SHAPE between them is the point.
///
/// Nil for an unknown name: a typo is a reported failure, not a silent linear
/// that looks like the easing was ignored.
fn lua_math_ease(L: ?*lua_State) callconv(.c) c_int {
    const name = lua.toString(L, 1);
    const t = lua.toF32(L, 2);
    const v = core_math.easeByName(name, t) orelse {
        lua.pushNil(L);
        return 1;
    };
    lua.pushF32(L, v);
    return 1;
}

/// `math.easings() -> table` — every easing name, so a script (or the
/// editor's autocomplete) can discover them without the docs.
fn lua_math_easings(L: ?*lua_State) callconv(.c) c_int {
    const names = core_math.easing_names;
    lua.lua_createtable(L, 0, @intCast(names.len));
    for (names, 0..) |name, i| {
        lua.pushSlice(L, name);
        lua.lua_rawseti(L, -2, @intCast(i + 1));
    }
    return 1;
}

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

    /// Parses a color table {r, g, b, a} or {r, g, b} (a defaults to 255).
    /// Returns [4]u8 with RGBA values 0-255.
    fn parseColor(L: ?*lua_State, idx: c_int) [4]u8 {
        if (lua.isTable(L, idx)) {
            lua.getField(L, idx, "r"); const r = @as(i32, @intFromFloat(lua.toNumber(L, -1))); lua.pop(L, 1);
            lua.getField(L, idx, "g"); const g = @as(i32, @intFromFloat(lua.toNumber(L, -1))); lua.pop(L, 1);
            lua.getField(L, idx, "b"); const b = @as(i32, @intFromFloat(lua.toNumber(L, -1))); lua.pop(L, 1);
            lua.getField(L, idx, "a");
            const a = if (lua.isNumber(L, -1)) @as(i32, @intFromFloat(lua.toNumber(L, -1))) else 255;
            lua.pop(L, 1);
            return .{ @intCast(r), @intCast(g), @intCast(b), @intCast(a) };
        }
        return .{ 255, 255, 255, 255 };
    }

    /// Pushes a [4]u8 color as a table {r, g, b, a} onto the Lua stack.
    fn pushColor(L: ?*lua_State, color: [4]u8) void {
        _ = lua.lua_createtable(L, 0, 4);
        lua.pushInteger(L, @intCast(color[0])); lua.setField(L, -2, "r");
        lua.pushInteger(L, @intCast(color[1])); lua.setField(L, -2, "g");
        lua.pushInteger(L, @intCast(color[2])); lua.setField(L, -2, "b");
        lua.pushInteger(L, @intCast(color[3])); lua.setField(L, -2, "a");
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


// ── audio (M8) ───────────────────────────────────────────────────────────────
//
// Every call reaches the ONE `Audio` the runtime owns through the context,
// exactly as `physics.*` reaches the solver's system — no module global, so the
// editor and a test can each own one. When no system is wired, a call reports
// failure (`false`/nil) rather than dereferencing null.
//
// A voice handle travels as LIGHT userdata with the same +1 bias the actor
// `__entity` bridge uses: Lua hands back a NULL light userdata as NULL, and a
// voice with index 0 and generation 0 IS NULL. A stale handle is a no-op, never
// an error — the sound it named is genuinely gone.

const audio_mod = @import("audio");
const VoiceId = audio_mod.VoiceId;

/// The audio system, or null when the runtime has none.
fn audioOf(L: ?*lua_State) ?*audio_mod.Audio {
    return ctxOf(L).audio;
}

/// A voice id as a Lua value: generation in the high 32 bits, index in the low,
/// plus the +1 bias so handle 0 is not NULL.
fn pushVoiceId(L: ?*lua_State, id: VoiceId) void {
    const bits: u64 = (@as(u64, id.generation) << 32) | @as(u64, id.index);
    lua.lua_pushlightuserdata(L, @ptrFromInt(bits + 1));
}

fn voiceOf(L: ?*lua_State, idx: c_int) ?VoiceId {
    const p = lua.lua_topointer(L, idx) orelse return null;
    const biased: u64 = @intFromPtr(p);
    if (biased == 0) return null;
    const bits = biased - 1;
    return .{ .index = @truncate(bits), .generation = @truncate(bits >> 32) };
}

/// A 0..255 integer argument, clamped so a stray float cannot trap the cast.
fn u8Arg(L: ?*lua_State, idx: c_int) u8 {
    return @intFromFloat(std.math.clamp(lua.toF32(L, idx), 0, 255));
}

/// A bus id from either a number or a registered name.
fn busIdOf(L: ?*lua_State, idx: c_int) ?u8 {
    if (lua.isNumber(L, idx)) return u8Arg(L, idx);
    const name = lua.toSlice(L, idx) orelse return null;
    const sys = audioOf(L) orelse return null;
    return sys.buses.idOfName(name);
}

/// Reads an options table (all fields optional).
fn optsFrom(L: ?*lua_State, idx: c_int) audio_mod.PlayOpts {
    var o = audio_mod.PlayOpts{};
    if (!lua.isTable(L, idx)) return o;
    lua.getField(L, idx, "volume");
    if (lua.isNumber(L, -1)) o.volume = lua.toF32(L, -1);
    lua.pop(L, 1);
    lua.getField(L, idx, "pitch");
    if (lua.isNumber(L, -1)) o.pitch = lua.toF32(L, -1);
    lua.pop(L, 1);
    lua.getField(L, idx, "max_distance");
    if (lua.isNumber(L, -1)) o.max_distance = lua.toF32(L, -1);
    lua.pop(L, 1);
    lua.getField(L, idx, "spread");
    if (lua.isNumber(L, -1)) o.spread = lua.toF32(L, -1);
    lua.pop(L, 1);
    lua.getField(L, idx, "loop");
    if (!lua.isNil(L, -1)) o.loop = lua.toBool(L, -1);
    lua.pop(L, 1);
    lua.getField(L, idx, "priority");
    if (lua.isNumber(L, -1)) o.priority = u8Arg(L, -1);
    lua.pop(L, 1);
    lua.getField(L, idx, "bus");
    if (lua.isNumber(L, -1)) o.bus = u8Arg(L, -1);
    lua.pop(L, 1);
    lua.getField(L, idx, "bus_name");
    if (lua.isString(L, -1)) {
        if (audioOf(L)) |sys| {
            if (sys.buses.idOfName(lua.toString(L, -1))) |id| o.bus = id;
        }
    }
    lua.pop(L, 1);
    return o;
}

/// `audio.play_file(path, opts?) -> voice`. Load-time / preview: it may decode,
/// so it is NOT the frame-safe path (use a resident slot for gameplay).
fn lua_audio_play_file(L: ?*lua_State) callconv(.c) c_int {
    const sys = audioOf(L) orelse return 0;
    const path = lua.toSlice(L, 1) orelse return 0;
    const opts = if (lua.getTop(L) >= 2) optsFrom(L, 2) else audio_mod.PlayOpts{};
    const id = sys.playFile(path, opts) catch return 0;
    pushVoiceId(L, id);
    return 1;
}

/// `audio.play_stream(path, opts?) -> voice`. Like `play_file`, but the sound
/// is STREAMED: only a small window is ever resident and the frame loop keeps it
/// fed. This is the path for long music; `play_file` decodes the whole sound.
fn lua_audio_play_stream(L: ?*lua_State) callconv(.c) c_int {
    const sys = audioOf(L) orelse return 0;
    const path = lua.toSlice(L, 1) orelse return 0;
    const opts = if (lua.getTop(L) >= 2) optsFrom(L, 2) else audio_mod.PlayOpts{};
    const id = sys.playFileStream(path, opts, 0) catch return 0;
    pushVoiceId(L, id);
    return 1;
}

/// `audio.stop(voice)`.
fn lua_audio_stop(L: ?*lua_State) callconv(.c) c_int {
    const sys = audioOf(L) orelse return 0;
    if (voiceOf(L, 1)) |v| sys.stop(v);
    return 0;
}

/// `audio.stop_all()` — the Play/Stop hook: leaves the mixer silent and exact.
fn lua_audio_stop_all(L: ?*lua_State) callconv(.c) c_int {
    const sys = audioOf(L) orelse return 0;
    sys.stopAll();
    return 0;
}

/// `audio.set_volume(voice, volume)`.
fn lua_audio_set_volume(L: ?*lua_State) callconv(.c) c_int {
    const sys = audioOf(L) orelse return 0;
    if (voiceOf(L, 1)) |v| sys.setVolume(v, lua.toF32(L, 2));
    return 0;
}

/// `audio.set_pitch(voice, pitch)`.
fn lua_audio_set_pitch(L: ?*lua_State) callconv(.c) c_int {
    const sys = audioOf(L) orelse return 0;
    if (voiceOf(L, 1)) |v| sys.setPitch(v, lua.toF32(L, 2));
    return 0;
}

/// `audio.is_playing(voice) -> boolean`. False for a stale handle.
fn lua_audio_is_playing(L: ?*lua_State) callconv(.c) c_int {
    const sys = audioOf(L) orelse {
        lua.lua_pushboolean(L, 0);
        return 1;
    };
    const playing = if (voiceOf(L, 1)) |v| sys.isPlaying(v) else false;
    lua.lua_pushboolean(L, @intFromBool(playing));
    return 1;
}

/// `audio.set_master_volume(gain)`.
fn lua_audio_set_master_volume(L: ?*lua_State) callconv(.c) c_int {
    const sys = audioOf(L) orelse return 0;
    sys.setMasterGain(lua.toF32(L, 1));
    return 0;
}

/// `audio.set_listener(x, y, rotation?)`.
///
/// The rotation is which way the ears face, in radians; it turns the stereo
/// field with the listener. Omitted (or 0) keeps the pre-rotation behaviour.
fn lua_audio_set_listener(L: ?*lua_State) callconv(.c) c_int {
    const sys = audioOf(L) orelse return 0;
    const rot: f32 = if (lua.getTop(L) >= 3) lua.toF32(L, 3) else 0;
    sys.setListener(lua.toF32(L, 1), lua.toF32(L, 2), rot);
    return 0;
}

/// `audio.solo_bus(bus, solo)`. A soloed bus silences every other non-master
/// bus, so the mixer panel's "S" button is one call.
fn lua_audio_solo_bus(L: ?*lua_State) callconv(.c) c_int {
    const sys = audioOf(L) orelse return 0;
    if (busIdOf(L, 1)) |id| sys.setBusSolo(id, lua.toBool(L, 2));
    return 0;
}

/// `audio.set_bus_send(bus, target, amount)`. Routes `amount` of `bus`'s signal
/// into `target`'s gain path (a reverb/duck aux). A nil `target` clears it.
fn lua_audio_set_bus_send(L: ?*lua_State) callconv(.c) c_int {
    const sys = audioOf(L) orelse return 0;
    const id = busIdOf(L, 1) orelse return 0;
    const target = busIdOf(L, 2) orelse {
        sys.setBusSend(id, audio_mod.no_send, 0);
        return 0;
    };
    sys.setBusSend(id, target, lua.toF32(L, 3));
    return 0;
}

/// `audio.bus_gain(bus) -> number`. A missing name reads as 1 (full), which is
/// what a project with no audio section wants.
fn lua_audio_bus_gain(L: ?*lua_State) callconv(.c) c_int {
    const sys = audioOf(L) orelse {
        lua.pushF32(L, 1);
        return 1;
    };
    const id = busIdOf(L, 1) orelse {
        lua.pushF32(L, 1);
        return 1;
    };
    lua.pushF32(L, sys.busGain(id));
    return 1;
}

/// `audio.set_bus_volume(bus, gain)`.
fn lua_audio_set_bus_volume(L: ?*lua_State) callconv(.c) c_int {
    const sys = audioOf(L) orelse return 0;
    if (busIdOf(L, 1)) |id| sys.setBusGain(id, lua.toF32(L, 2));
    return 0;
}

/// `audio.mute_bus(bus, muted)`.
fn lua_audio_mute_bus(L: ?*lua_State) callconv(.c) c_int {
    const sys = audioOf(L) orelse return 0;
    if (busIdOf(L, 1)) |id| sys.setBusMuted(id, lua.toBool(L, 2));
    return 0;
}

/// `audio.buses() -> table`. An ARRAY of `{ name, gain, muted }`, in bus order
/// (bus 1 is master), so the mixer panel iterates rather than looks up by a
/// name it would have to know.
fn lua_audio_buses(L: ?*lua_State) callconv(.c) c_int {
    const sys = audioOf(L) orelse return 0;
    lua.lua_createtable(L, audio_mod.bus.bus_count, 0);
    var n: c_int = 0;
    for (0..audio_mod.bus.bus_count) |i| {
        const name = sys.buses.buses[i].name;
        if (name.len == 0) continue;
        lua.lua_createtable(L, 0, 4);
        lua.pushSlice(L, name);
        lua.setField(L, -2, "name");
        lua.pushF32(L, sys.busGain(@intCast(i)));
        lua.setField(L, -2, "gain");
        lua.lua_pushboolean(L, @intFromBool(sys.bus_muted[i]));
        lua.setField(L, -2, "muted");
        lua.lua_pushboolean(L, @intFromBool(sys.busSolo(@intCast(i))));
        lua.setField(L, -2, "solo");
        lua.lua_pushinteger(L, @intCast(sys.busSendTo(@intCast(i))));
        lua.setField(L, -2, "send_to");
        lua.pushF32(L, sys.busSendAmount(@intCast(i)));
        lua.setField(L, -2, "send_amount");
        lua.lua_pushinteger(L, @intCast(i));
        lua.setField(L, -2, "id");
        n += 1;
        lua.lua_rawseti(L, -2, n);
    }
    return 1;
}

/// `audio.stats() -> table` — the counters a debug overlay polls every frame.
fn lua_audio_stats(L: ?*lua_State) callconv(.c) c_int {
    const sys = audioOf(L) orelse return 0;
    const s = sys.stats();
    const bs = sys.bankStats();

    lua.lua_createtable(L, 0, 10);
    const put = struct {
        fn num(state: ?*lua_State, k: [*:0]const u8, v: f64) void {
            lua.lua_pushnumber(state, v);
            lua.setField(state, -2, k);
        }
    };
    put.num(L, "voices_active", @floatFromInt(s.voices_active));
    put.num(L, "voices_peak", @floatFromInt(s.voices_peak));
    put.num(L, "xruns", @floatFromInt(s.xruns));
    put.num(L, "commands_dropped", @floatFromInt(s.commands_dropped));
    put.num(L, "latency_ms", s.latencyMs());
    put.num(L, "period_frames", @floatFromInt(s.period_frames));
    put.num(L, "sample_rate", @floatFromInt(s.sample_rate));
    put.num(L, "channels", @floatFromInt(s.channels));
    put.num(L, "bank_bytes", @floatFromInt(bs.bytes_used));
    put.num(L, "bank_budget", @floatFromInt(bs.budget_bytes));
    return 1;
}


/// The `audio` table.
const audio_regs = [_]luaL_Reg{
    .{ .name = "play_file", .func = lua_audio_play_file },
    .{ .name = "play_stream", .func = lua_audio_play_stream },
    .{ .name = "stop", .func = lua_audio_stop },
    .{ .name = "stop_all", .func = lua_audio_stop_all },
    .{ .name = "set_volume", .func = lua_audio_set_volume },
    .{ .name = "set_pitch", .func = lua_audio_set_pitch },
    .{ .name = "is_playing", .func = lua_audio_is_playing },
    .{ .name = "set_master_volume", .func = lua_audio_set_master_volume },
    .{ .name = "set_listener", .func = lua_audio_set_listener },
    .{ .name = "solo_bus", .func = lua_audio_solo_bus },
    .{ .name = "set_bus_send", .func = lua_audio_set_bus_send },
    .{ .name = "bus_gain", .func = lua_audio_bus_gain },
    .{ .name = "set_bus_volume", .func = lua_audio_set_bus_volume },
    .{ .name = "mute_bus", .func = lua_audio_mute_bus },
    .{ .name = "buses", .func = lua_audio_buses },
    .{ .name = "stats", .func = lua_audio_stats },
    .{ .name = null, .func = null },
};

// ── sound: the per-actor `SoundEmitter2D` surface (M8) ──────────────────────
//
// `audio.*` is about SOUNDS (a UI click, music, an audition); `sound.*` is about
// THIS ACTOR's emitter, and it is the half of the M8 Lua surface that a scene
// actually uses. The component is plain data (a bank slot, a bus, a gain, a
// radius), and these bindings are the verbs that turn it into a voice:
//
//   - the component is the CONFIGURATION and survives a save/hot-reload;
//   - `sound.play` resolves it to a voice at the actor's transform;
//   - the setters write the component AND push the live command, so an
//     inspector and a gameplay tweak agree about what a field means.
//
// Everything here is one `world.get` plus, at most, one command-ring push —
// the same shape as `sprite.*`, and reachable only through the `__entity`
// bridge, so there is no per-call lookup. When no audio system is wired every
// call reports failure (nil / false / a no-op) rather than dereferencing null.

/// The emitter component, or null when this actor has none. A `self` with no
/// emitter is a script asking a silent object to speak: not an error, a no-op.
fn emitterOf(L: ?*lua_State) ?*components.SoundEmitter2D {
    const ctx = ctxOf(L);
    const e = entityOf(L, 1) orelse return null;
    return ctx.world.get(e, SoundEmitter2D);
}

/// The emitter, creating it when the actor has none.
///
/// Created rather than refused for the same reason `sprite_rect` adds a Sprite:
/// a behavior that plays a sound should not first have to be told that a
/// component exists. The one structural ECS change in this surface happens
/// here, so it is the one call documented as load-time-only in spirit.
fn emitterOfEnsure(L: ?*lua_State) ?*components.SoundEmitter2D {
    const ctx = ctxOf(L);
    const e = entityOf(L, 1) orelse return null;
    if (ctx.world.get(e, SoundEmitter2D) == null) {
        _ = ctx.world.add(e, SoundEmitter2D{}) catch return null;
    }
    return ctx.world.get(e, SoundEmitter2D);
}

/// The actor's world position, or the origin when it has no Transform. A sound
/// placed at (0,0) by accident is a sound in the corner; a sound refused because
/// an actor has no Transform is a sound that never happens.
fn emitterPosition(L: ?*lua_State, ctx: *Context) m.Vec2 {
    const e = entityOf(L, 1) orelse return m.Vec2.zero;
    const t = ctx.world.get(e, Transform) orelse return m.Vec2.zero;
    return t.position;
}

/// `sound.play(self, path, opts?) -> voice` — the emitter's sound, at the
/// emitter's position.
///
/// The argument list is deliberately `path` FIRST and the component second: a
/// scene file writes the configuration, but the common call is "make this noise
/// now", and that is a path. An emitter whose `bank_slot` is already resolved
/// (the editor writes the id at load) is used when the path is omitted, which is
/// the frame-safe spelling — no decode, one command push.
///
/// `opts` overrides the component's own fields for THIS play only; the ones
/// absent keep whatever the scene (or a previous setter) configured.
fn lua_sound_play(L: ?*lua_State) callconv(.c) c_int {
    const ctx = ctxOf(L);
    const sys = ctx.audio orelse return 0;
    const emitter = emitterOfEnsure(L) orelse return 0;

    var slot: audio_mod.BankSlot = emitter.bank_slot;
    if (lua.toSlice(L, 2)) |path| {
        if (path.len > 0) {
            // Load time: this MAY decode. `sound.play` with a path is a
            // preview/authoring call; gameplay plays a resident slot.
            slot = sys.load(path) catch return 0;
            emitter.bank_slot = slot;
        }
    }
    // Slot 0 is the bank's "nothing loaded" sentinel, and the component's
    // `bank_slot` defaults to it — so this one test covers "no path given" and
    // "given a path that resolved to nothing" in a single comparison.
    if (slot == audio_mod.no_bank_slot) return 0;

    var opts = audio_mod.PlayOpts{
        .bus = emitter.bus,
        .volume = emitter.volume,
        .pitch = emitter.pitch,
        .loop = emitter.loop,
        .max_distance = emitter.max_distance,
        .spread = emitter.spread,
    };
    if (lua.getTop(L) >= 3) mergeEmitterOpts(L, 3, &opts);

    const p = emitterPosition(L, ctx);
    opts.x = p.x;
    opts.y = p.y;
    const voice = sys.play(slot, opts);
    emitter.playing = .{ .index = voice.index, .generation = voice.generation };
    emitter.tick = sys.tick;
    pushVoiceId(L, voice);
    return 1;
}

/// Writes the opts-table fields that exist into `opts`. Separate from
/// `optsFrom` (the `audio.*` form) because that one has no component to fall
/// back on and this one must LEAVE the emitter's value alone when a field is
/// absent — an empty `{}` means "as configured", not "as defaulted".
fn mergeEmitterOpts(L: ?*lua_State, idx: c_int, opts: *audio_mod.PlayOpts) void {
    if (!lua.isTable(L, idx)) return;
    lua.getField(L, idx, "volume");
    if (lua.isNumber(L, -1)) opts.volume = lua.toF32(L, -1);
    lua.pop(L, 1);
    lua.getField(L, idx, "pitch");
    if (lua.isNumber(L, -1)) opts.pitch = lua.toF32(L, -1);
    lua.pop(L, 1);
    lua.getField(L, idx, "loop");
    if (!lua.isNil(L, -1)) opts.loop = lua.toBool(L, -1);
    lua.pop(L, 1);
    lua.getField(L, idx, "max_distance");
    if (lua.isNumber(L, -1)) opts.max_distance = @max(lua.toF32(L, -1), 0);
    lua.pop(L, 1);
    lua.getField(L, idx, "spread");
    if (lua.isNumber(L, -1)) opts.spread = @max(lua.toF32(L, -1), 0);
    lua.pop(L, 1);
    lua.getField(L, idx, "priority");
    if (lua.isNumber(L, -1)) opts.priority = u8Arg(L, -1);
    lua.pop(L, 1);
    lua.getField(L, idx, "bus");
    if (lua.isNumber(L, -1)) opts.bus = u8Arg(L, -1);
    lua.pop(L, 1);
    lua.getField(L, idx, "bus_name");
    if (lua.isString(L, -1)) {
        if (audioOf(L)) |sys| {
            if (sys.buses.idOfName(lua.toString(L, -1))) |id| opts.bus = id;
        }
    }
    lua.pop(L, 1);
}

/// `sound.stop(self)` — stops the voice this emitter started. A no-op when the
/// sound already ended, which is the normal case: the event that ended it
/// travels on the signal bus, not back into the component.
fn lua_sound_stop(L: ?*lua_State) callconv(.c) c_int {
    const ctx = ctxOf(L);
    const sys = ctx.audio orelse return 0;
    const emitter = emitterOf(L) orelse return 0;
    if (emitter.playing.isNone()) return 0;
    sys.stop(.{ .index = emitter.playing.index, .generation = emitter.playing.generation });
    emitter.playing = .none;
    return 0;
}

/// `sound.set_volume(self, volume)` — writes the emitter AND the live voice, so
/// the component stays the truth an inspector reads while the sound changes now.
fn lua_sound_set_volume(L: ?*lua_State) callconv(.c) c_int {
    const ctx = ctxOf(L);
    const emitter = emitterOf(L) orelse return 0;
    emitter.volume = @max(lua.toF32(L, 2), 0);
    if (ctx.audio) |sys| applyLiveVoice(sys, emitter, .volume);
    return 0;
}

/// `sound.set_pitch(self, pitch)`.
fn lua_sound_set_pitch(L: ?*lua_State) callconv(.c) c_int {
    const ctx = ctxOf(L);
    const emitter = emitterOf(L) orelse return 0;
    emitter.pitch = @max(lua.toF32(L, 2), 0);
    if (ctx.audio) |sys| applyLiveVoice(sys, emitter, .pitch);
    return 0;
}

/// `sound.set_loop(self, on)` — configuration only.
///
/// There is no "set loop" command: a voice's loop flag is part of the PCM view
/// the device thread built when it started, and changing it under a running
/// voice is a click at the loop point. So this writes the component and takes
/// effect on the next play. Said out loud because a setter that appears to do
/// nothing is the bug report this paragraph prevents.
fn lua_sound_set_loop(L: ?*lua_State) callconv(.c) c_int {
    const emitter = emitterOf(L) orelse return 0;
    emitter.loop = lua.toBool(L, 2);
    return 0;
}

/// `sound.set_radius(self, max_distance)` — 0 is GLOBAL: never attenuated,
/// never panned (music, UI). Also next-play only, for the same reason as
/// `set_loop`: placement is computed when the voice starts.
fn lua_sound_set_radius(L: ?*lua_State) callconv(.c) c_int {
    const emitter = emitterOf(L) orelse return 0;
    emitter.max_distance = @max(lua.toF32(L, 2), 0);
    return 0;
}

/// `sound.set_spread(self, units)` — how far from the listener reaches hard
/// left/right. Next-play only, like the radius it belongs with.
fn lua_sound_set_spread(L: ?*lua_State) callconv(.c) c_int {
    const emitter = emitterOf(L) orelse return 0;
    emitter.spread = @max(lua.toF32(L, 2), 0);
    return 0;
}

/// `sound.is_playing(self) -> boolean` — asks the SYSTEM, not the component.
///
/// The component's `playing` is a handle the emitter believes is live; the
/// system is what knows. When the two disagree the sound has ended, so the
/// handle is cleared here rather than waiting for a despawn to notice — a
/// stale handle is a no-op by design, and this keeps it from lingering.
fn lua_sound_is_playing(L: ?*lua_State) callconv(.c) c_int {
    const ctx = ctxOf(L);
    const emitter = emitterOf(L) orelse return pushFalse(L);
    const sys = ctx.audio orelse return pushFalse(L);
    const live = !emitter.playing.isNone() and sys.isPlaying(.{
        .index = emitter.playing.index,
        .generation = emitter.playing.generation,
    });
    if (!live) emitter.playing = .none;
    return pushBool(L, live);
}

/// `sound.describe(self) -> table` — every readable field of this emitter, as
/// one flat table.
///
/// The inspector's read-back, modelled on `light.describe`: a tool draws
/// whatever the component has, and one table beats a getter per field that then
/// has to be kept in step with it. An empty table (not nil) means "no
/// emitter", because "no fields" and "the call failed" must not look alike.
fn lua_sound_describe(L: ?*lua_State) callconv(.c) c_int {
    const ctx = ctxOf(L);
    lua.lua_createtable(L, 8, 2);
    const emitter = emitterOf(L) orelse return 1;
    const sys = ctx.audio;

    const put = struct {
        fn n(St: ?*lua_State, key: [:0]const u8, v: f64) void {
            lua.lua_pushnumber(St, v);
            lua.setField(St, -2, key);
        }
        fn b(St: ?*lua_State, key: [:0]const u8, v: bool) void {
            lua.lua_pushboolean(St, @intFromBool(v));
            lua.setField(St, -2, key);
        }
        fn s(St: ?*lua_State, key: [:0]const u8, v: []const u8) void {
            lua.pushSlice(St, v);
            lua.setField(St, -2, key);
        }
    };

    put.n(L, "bank_slot", @floatFromInt(emitter.bank_slot));
    // The name behind the slot, from the bank that owns it. Empty when there is
    // no system or the slot was evicted — never a guess.
    put.s(L, "path", if (sys) |system| system.slotPath(emitter.bank_slot) else "");
    put.n(L, "bus", @floatFromInt(emitter.bus));
    put.n(L, "volume", emitter.volume);
    put.n(L, "pitch", emitter.pitch);
    put.b(L, "loop", emitter.loop);
    put.n(L, "max_distance", emitter.max_distance);
    put.n(L, "spread", emitter.spread);
    put.b(L, "autoplay", emitter.autoplay);
    put.b(L, "playing", !emitter.playing.isNone());
    put.n(L, "tick", @floatFromInt(emitter.tick));
    return 1;
}

/// Pushes the one live command a setter can change on a running voice. The
/// fields that cannot change are not here, and neither is a comment explaining
/// why — see `lua_sound_set_loop`.
fn applyLiveVoice(sys: *audio_mod.Audio, emitter: *components.SoundEmitter2D, comptime field: enum { volume, pitch }) void {
    if (emitter.playing.isNone()) return;
    const id = audio_mod.VoiceId{ .index = emitter.playing.index, .generation = emitter.playing.generation };
    switch (field) {
        .volume => sys.setVolume(id, emitter.volume),
        .pitch => sys.setPitch(id, emitter.pitch),
    }
}

const sound_regs = [_]luaL_Reg{
    .{ .name = "play", .func = lua_sound_play },
    .{ .name = "stop", .func = lua_sound_stop },
    .{ .name = "set_volume", .func = lua_sound_set_volume },
    .{ .name = "set_pitch", .func = lua_sound_set_pitch },
    .{ .name = "set_loop", .func = lua_sound_set_loop },
    .{ .name = "set_radius", .func = lua_sound_set_radius },
    .{ .name = "set_spread", .func = lua_sound_set_spread },
    .{ .name = "is_playing", .func = lua_sound_is_playing },
    .{ .name = "describe", .func = lua_sound_describe },
    .{ .name = null, .func = null },
};
// ── M15: TileMap (chunked tile layers) ──────────────────────────────────────
//
// The tilemap bindings act on an actor that carries a `TileMapLayer` component.
// They are per-actor methods like `sprite`/`timer`/`camera`, because a tile layer
// is a component on an actor. The actual tile grid lives in the asset system.

const TileMapLayer = components.TileMapLayer;
const Tile = components.Tile;
const ChunkKey = components.ChunkKey;
const ChunkHandle = components.ChunkHandle;
const AssetGUID = components.AssetGUID;

/// `tilemap.set_tileset(self, tileset_guid)` — which TileSet this layer draws from.
fn lua_tilemap_set_tileset(L: ?*lua_State) callconv(.c) c_int {
    const ctx = ctxOf(L);
    const e = entityOf(L, 1) orelse return 0;
    if (ctx.world.get(e, TileMapLayer)) |layer| {
        const guid_hex = lua.toSlice(L, 2) orelse return 0;
        layer.tileset_guid = parseAssetGUID(guid_hex);
    }
    return 0;
}

/// `tilemap.set_tile(self, tile_x, tile_y, atlas_index, flip_x?, flip_y?)` — sets a single tile.
fn lua_tilemap_set_tile(L: ?*lua_State) callconv(.c) c_int {
    const ctx = ctxOf(L);
    const e = entityOf(L, 1) orelse return 0;
    const layer = ctx.world.get(e, TileMapLayer) orelse return 0;
    const assets = ctx.assets orelse return 0;

    const tile_x = lua.toInteger(L, 2);
    const tile_y = lua.toInt(L, 3);
    const atlas_index = @as(u32, @intFromFloat(@max(lua.toF32(L, 4), 0)));
    const flip_x = lua.getTop(L) >= 5 and lua.toBool(L, 5);
    const flip_y = lua.getTop(L) >= 6 and lua.toBool(L, 6);

    // Find or create chunk
    const tileset_entry_opt = assets.registry.get(layer.tileset_guid);
    if (tileset_entry_opt == null) return 0;
    const tileset_entry = tileset_entry_opt.?;
    const tileset_ptr = tileset_entry.handle;
    if (tileset_ptr == 0) return 0;
    const tileset: *const assets_mod.TileSet = @ptrCast(@alignCast(tileset_ptr));
    const tile_size = tileset.tile_size;

    const chunk_key = ChunkKey.fromWorld(
        @as(f32, @floatFromInt(tile_x)) * tile_size,
        @as(f32, @floatFromInt(tile_y)) * tile_size,
        tile_size,
    );

    var handle = layer.chunk_map.get(chunk_key) orelse {
        // Would need to allocate a new chunk - for now just return
        return 0;
    };

    if (handle.isNone() or handle.index >= layer.chunks.len) return 0;
    const chunk = &layer.chunks[handle.index];
    if (handle.generation != chunk.generation) return 0;

    const local = components.ChunkCoord.fromTile(tile_x, tile_y);
    const idx = local.index();
    var tile = chunk.tiles[idx];
    tile.atlas_index = @intCast(atlas_index);
    tile.flags = 0;
    if (flip_x) tile.flags |= Tile.FlagFlipX;
    if (flip_y) tile.flags |= Tile.FlagFlipY;
    chunk.tiles[idx] = tile;
    chunk.has_tiles = true;
    chunk.markDirty(idx);
    layer.physics_dirty = true;
    return 0;
}

/// `tilemap.get_tile(self, tile_x, tile_y) -> atlas_index, flip_x, flip_y`
fn lua_tilemap_get_tile(L: ?*lua_State) callconv(.c) c_int {
    const ctx = ctxOf(L);
    const e = entityOf(L, 1) orelse return 0;
    const layer = ctx.world.get(e, TileMapLayer) orelse return 0;

    const tile_x = lua.toInteger(L, 2);
    const tile_y = lua.toInt(L, 3);

    const tileset_entry_opt = ctx.assets.registry.get(layer.tileset_guid);
    if (tileset_entry_opt == null) return 0;
    const tileset_entry = tileset_entry_opt.?;
    const tileset_ptr = tileset_entry.handle;
    if (tileset_ptr == 0) return 0;
    const tileset: *const assets_mod.TileSet = @ptrCast(@alignCast(tileset_ptr));
    const tile_size = tileset.tile_size;

    const chunk_key = ChunkKey.fromWorld(
        @as(f32, @floatFromInt(tile_x)) * tile_size,
        @as(f32, @floatFromInt(tile_y)) * tile_size,
        tile_size,
    );

    const handle = layer.chunk_map.get(chunk_key) orelse {
        lua.pushF32(L, 0);
        lua.lua_pushboolean(L, 0);
        lua.lua_pushboolean(L, 0);
        return 3;
    };

    if (handle.isNone() or handle.index >= layer.chunks.len) {
        lua.pushF32(L, 0);
        lua.lua_pushboolean(L, 0);
        lua.lua_pushboolean(L, 0);
        return 3;
    }
    const chunk = &layer.chunks[handle.index];
    if (handle.generation != chunk.generation) {
        lua.pushF32(L, 0);
        lua.lua_pushboolean(L, 0);
        lua.lua_pushboolean(L, 0);
        return 3;
    }

    const local = components.ChunkCoord.fromTile(tile_x, tile_y);
    const idx = local.index();
    const tile = chunk.tiles[idx];
    lua.pushF32(L, @floatFromInt(tile.atlas_index));
    lua.lua_pushboolean(L, @intFromBool(tile.flipX()));
    lua.lua_pushboolean(L, @intFromBool(tile.flipY()));
    return 3;
}

/// `tilemap.fill_rect(self, x1, y1, x2, y2, atlas_index)` — fills a rectangle with a tile.
fn lua_tilemap_fill_rect(L: ?*lua_State) callconv(.c) c_int {
    const ctx = ctxOf(L);
    const e = entityOf(L, 1) orelse return 0;
    const layer = ctx.world.get(e, TileMapLayer) orelse return 0;

    const x1 = lua.toInt(L, 2);
    const y1 = lua.toInt(L, 3);
    const x2 = lua.toInt(L, 4);
    const y2 = lua.toInt(L, 5);
    const atlas_index = @as(u32, @intFromFloat(@max(lua.toF32(L, 6), 0)));

    const tileset_entry_opt = ctx.assets.registry.get(layer.tileset_guid);
    if (tileset_entry_opt == null) return 0;
    const tileset_entry = tileset_entry_opt.?;
    const tileset_ptr = tileset_entry.handle;
    if (tileset_ptr == 0) return 0;
    const tileset: *const assets_mod.TileSet = @ptrCast(@alignCast(tileset_ptr));
    const tile_size = tileset.tile_size;

    const min_x = @min(x1, x2);
    const max_x = @max(x1, x2);
    const min_y = @min(y1, y2);
    const max_y = @max(y1, y2);

    var y = min_y;
    while (y <= max_y) : (y += 1) {
        var x = min_x;
        while (x <= max_x) : (x += 1) {
            const chunk_key = ChunkKey.fromWorld(
                @as(f32, @floatFromInt(x)) * tile_size,
                @as(f32, @floatFromInt(y)) * tile_size,
                tile_size,
            );
            const handle = layer.chunk_map.get(chunk_key) orelse continue;
            if (handle.isNone() or handle.index >= layer.chunks.len) continue;
            const chunk = &layer.chunks[handle.index];
            if (handle.generation != chunk.generation) continue;
            const local = components.ChunkCoord.fromTile(x, y);
            const idx = local.index();
            var tile = chunk.tiles[idx];
            tile.atlas_index = @intCast(atlas_index);
            tile.flags = 0;
            chunk.tiles[idx] = tile;
            chunk.has_tiles = true;
            chunk.markDirty(idx);
        }
    }
    layer.physics_dirty = true;
    return 0;
}

/// `tilemap.set_layer(self, layer)` — render layer (draw order).
fn lua_tilemap_set_layer(L: ?*lua_State) callconv(.c) c_int {
    const ctx = ctxOf(L);
    const e = entityOf(L, 1) orelse return 0;
    if (ctx.world.get(e, TileMapLayer)) |layer| {
        layer.layer = @truncate(@as(u32, @intFromFloat(@max(lua.toF32(L, 2), 0))));
    }
    return 0;
}

/// `tilemap.set_physics_enabled(self, enabled)` — whether this layer collides.
fn lua_tilemap_set_physics_enabled(L: ?*lua_State) callconv(.c) c_int {
    const ctx = ctxOf(L);
    const e = entityOf(L, 1) orelse return 0;
    if (ctx.world.get(e, TileMapLayer)) |layer| {
        layer.physics_enabled = lua.toBool(L, 2);
        layer.physics_dirty = true;
    }
    return 0;
}

/// `tilemap.get_chunk_bounds(self, cx, cy) -> min_x, min_y, max_x, max_y` — world bounds of a chunk.
fn lua_tilemap_get_chunk_bounds(L: ?*lua_State) callconv(.c) c_int {
    const ctx = ctxOf(L);
    const e = entityOf(L, 1) orelse return 0;
    const layer = ctx.world.get(e, TileMapLayer) orelse return 0;

    const cx = lua.toInt(L, 2);
    const cy = lua.toInt(L, 3);

    const tileset_entry_opt = ctx.assets.registry.get(layer.tileset_guid);
    if (tileset_entry_opt == null) return 0;
    const tileset_entry = tileset_entry_opt.?;
    const tileset_ptr = tileset_entry.handle;
    if (tileset_ptr == 0) return 0;
    const tileset: *const assets_mod.TileSet = @ptrCast(@alignCast(tileset_ptr));
    const tile_size = tileset.tile_size;
    const chunk_world_size = tile_size * 16.0;

    const min_x = @as(f32, @floatFromInt(cx)) * chunk_world_size;
    const min_y = @as(f32, @floatFromInt(cy)) * chunk_world_size;
    const max_x = min_x + chunk_world_size;
    const max_y = min_y + chunk_world_size;

    lua.pushF32(L, min_x);
    lua.pushF32(L, min_y);
    lua.pushF32(L, max_x);
    lua.pushF32(L, max_y);
    return 4;
}

fn parseAssetGUID(hex: []const u8) AssetGUID {
    if (!std.mem.startsWith(u8, hex, "asset_")) return AssetGUID{ .value = 0 };
    const hex_part = hex[6..];
    if (hex_part.len != 16) return AssetGUID{ .value = 0 };
    var value: u64 = 0;
    for (hex_part) |c| {
        value <<= 4;
        // Convert hex character to integer value
        const digit = if (c >= '0' and c <= '9') c - '0'
            else if (c >= 'a' and c <= 'f') c - 'a' + 10
            else if (c >= 'A' and c <= 'F') c - 'A' + 10
            else 0;
        value |= @as(u64, digit) & 0xF;
    }
    return AssetGUID{ .value = value };
}

const tilemap_regs = [_]luaL_Reg{
    .{ .name = "set_tileset", .func = lua_tilemap_set_tileset },
    .{ .name = "set_tile", .func = lua_tilemap_set_tile },
    .{ .name = "get_tile", .func = lua_tilemap_get_tile },
    .{ .name = "fill_rect", .func = lua_tilemap_fill_rect },
    .{ .name = "set_layer", .func = lua_tilemap_set_layer },
    .{ .name = "set_physics_enabled", .func = lua_tilemap_set_physics_enabled },
    .{ .name = "get_chunk_bounds", .func = lua_tilemap_get_chunk_bounds },
    .{ .name = null, .func = null },
};

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
    "actor.set_transform",       "actor.get_all",
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
    "math.ease",                 "math.easings",
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
    "input.pointer_over_ui",
    "log.info",                  "log.warn",
    // globals: mounted global scripts (the Lua singleton surface)
    "globals.get",               "globals.exists",
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
    // audio (M8)
    "audio.play_file",
    "audio.play_stream",
    "audio.stop",
    "audio.stop_all",
    "audio.set_volume",
    "audio.set_pitch",
    "audio.is_playing",
    "audio.set_master_volume",
    "audio.set_listener",
    "audio.solo_bus",
    "audio.set_bus_send",
    "audio.bus_gain",
    "audio.set_bus_volume",
    "audio.mute_bus",
    "audio.buses",
    "audio.stats",
    // sound (M8): the per-actor `SoundEmitter2D` surface. Every one of these
    // needs a `metadata.bindings` entry or `assertAllDocumented` fails to
    // compile, which is the gate that keeps stubs, help panel and API aligned.
    "sound.play",
    "sound.stop",
    "sound.set_volume",
    "sound.set_pitch",
    "sound.set_loop",
    "sound.set_radius",
    "sound.set_spread",
    "sound.is_playing",
    "sound.describe",
    // M15 PARKED: TileMap names are disabled with the rest of the subsystem.
    // "tilemap.set_tileset",
    // "tilemap.set_tile",
    // "tilemap.get_tile",
    // "tilemap.fill_rect",
    // "tilemap.erase_rect",
    // "tilemap.set_layer",
    // "tilemap.set_physics_enabled",
    // "tilemap.set_tile_size",
    // "tilemap.get_chunk_bounds",
    // "tilemap.set_default_flip",
    // "tilemap.describe",
    "render.set_view",
    "render.stats",
    "render.set_resident",
    "render.all_resident",
    "environment.set_ambient",
    "environment.set_clear",
    "environment.set_bloom",
    "environment.set_tonemap",
    "environment.set_fog",
    "environment.get_ambient",
    "environment.get_clear",
    "environment.get_fog",
    "light.kind_of",
    "light.describe",
    "lighting.quality",
    "lighting.set_quality",
    "lighting.stats",
    "environment.new",
    // M9: scene transitions (the fade)
    "scene.fade_out",
    "scene.fade_in",
    "scene.fade_covered",
    "scene.fade_clear",
    "scene.fade_amount",
    "scene.fading",
    // M14: CanvasModulate (the full-screen tint)
    "scene.tint",
    "scene.tint_mode",
    "scene.tint_clear",
    "scene.tint_amount",
    // M9: particles (the CPU pool)
    "particles.burst",
    "particles.stats",
    "light.set_color",
    "light.set_energy",
    "light.set_blend",
    "light.set_shadow",
    "light.set_mask",
    "light.get_energy",
    // The M7 set: `light.new` is what a scene file and the acceptance test use,
    // and the three getters are what the inspector reads back.
    "light.new",
    "light.set_cone",
    "light.get_radius",
    "light.get_cone",
    "light.get_shadow",
    "point.new",
    "point.set_radius",
    "spot.new",
    "spot.set_radius",
    "spot.set_cone",
    "spot.set_angle",
    "directional.new",
    "directional.set_angle",
    "directional.set_height",
    "ambient.new",
    "ambient.set_local",
    "occluder.new",
    "occluder.set_mode",
    "occluder.set_threshold",
    "occluder.set_mask",
    "occluder.set_polygon",
    "occluder.get_mode",
    "occluder.get_threshold",
    "occluder.get_mask",
    "occluder.get_polygon",
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
    "sprite.set_image",
    "sprite.set_atlas",
    "sprite.set_shape",
    "sprite.set_blend",
    "sprite.get_size",
    "sprite.get_tint",
    "actor.add_component",
    "actor.has_component",
    "actor.remove_component",
    "actor.entity_bits",
    "actor.from_entity",
    "physics.create_shape",
    "physics.reshape",
    "physics.set_material",
    "physics.set_sensor",
    "physics.set_layers",
    "physics.set_body_type",
    "physics.set_body_enabled",
    "physics.overlap_rect",
    "physics.contains_point",
    // Debug
    // PARKED: physics debug bindings are unfinished.
    // "physics.debug_draw",
    // "physics.debug_flags",
    // "physics.debug_colors",
    "actor.set_linear_velocity",
    "actor.get_linear_velocity", "actor.apply_impulse",
    "actor.is_awake",
    // M15 PARKED: TileMap bindings are disabled until the subsystem is finished
    // (see the `//M15-PARKED` block above). Re-enable these names together with
    // the block and the `installModule` call.
    // "tilemap.set_tileset",
    // "tilemap.set_tile",
    // "tilemap.get_tile",
    // "tilemap.fill_rect",
    // "tilemap.set_layer",
    // "tilemap.set_physics_enabled",
    // "tilemap.get_chunk_bounds",
    // M4.5 — every one of these needs a `metadata.bindings` entry or
    // `assertAllDocumented` above fails to compile, which is the gate that keeps
    // the stubs, the help panel and the API from drifting apart.
    "camera.new",
    "camera.follow",
    "camera.zoom_to",
    "camera.shake",
    "camera.set_limits",
    "camera.set_damping",
    "camera.get_centre",
    "timer.new",
    "timer.set_signals",
    "timer.start",
    "timer.stop",
    "timer.kill",
    "timer.progress",
    "timer.restart",
    "timer.set_duration",
    "timer.get_duration",
    "timer.get_elapsed",
    "timer.get_loops",
    "timer.set_kind",
    "timer.set_time_scale",
    "timer.is_finished",
    "timer.is_paused",
    "timer.get_dropped",
    // time: the game clock and the global time scale
    "time.delta",
    "time.unscaled_delta",
    "time.elapsed",
    "time.unscaled_elapsed",
    "time.frame",
    "time.physics_delta",
    "time.scale",
    "time.set_scale",
    "time.pause",
    "time.resume",
    "time.is_paused",
    // tween: animating a value over time
    "tween.to",
    "tween.chain",
    "tween.start",
    "tween.kill",
    "tween.kill_entity",
    "tween.kill_all",
    "tween.is_alive",
    "tween.count",
    "tween.time_scale",
    "tween.set_time_scale",
    "tween.properties",
    // flow: the global state machine, with a stack of states
    "flow.add_state",
    "flow.add_transition",
    "flow.set_initial",
    "flow.fire",
    "flow.set_state",
    "flow.push",
    "flow.pop",
    "flow.state",
    "flow.is_in",
    "flow.stack",
    // M13: the per-actor AnimationPlayer surface. Same rule as above: every
    // name here must have a metadata entry, or `assertAllDocumented` fails.
    "anim.new",
    "anim.load",
    "anim.play",
    "anim.stop",
    "anim.pause",
    "anim.resume",
    "anim.seek",
    "anim.set_speed",
    "anim.queue",
    "anim.set_param",
    "anim.state",
    "anim.time",
    "anim.length",
    "anim.is_playing",
    // M14: the game UI. Same rule as everything above — every name here needs a
    // `metadata.bindings` entry or `assertAllDocumented` fails to compile.
    "ui.set_anchor",
    "ui.set_offset",
    "ui.set_size",
    "ui.set_pivot",
    "ui.set_margin",
    "ui.set_order",
    "ui.set_visible",
    "ui.set_interactive",
    "ui.set_text",
    "ui.set_font",
    "ui.set_color",
    "ui.set_colors",
    "ui.set_border",
    "ui.set_show_text",
    "ui.set_value",
    "ui.set_align",
    "ui.set_enabled",
    "ui.measure",
    "ui.rect",
    "ui.hovered",
    "ui.pressed",
    "ui.font_load",
};

pub fn registerAll(L: ?*lua_State, ctx: *Context) void {
    // The comptime gate: every name below must have a `metadata.bindings` entry
    // (the reverse direction is checked where the list itself is checked, see
    // `registered_names`' test).
    comptime metadata.assertAllDocumented(&registered_names);

    installModule(L, ctx, "actor", &actor_regs);
    installModule(L, ctx, "math", &math_regs);
    installModule(L, ctx, "audio", &audio_regs);
    installModule(L, ctx, "vec2", &vec2_regs);
    installModule(L, ctx, "input", &input_regs);
    installModule(L, ctx, "log", &log_regs);
    installModule(L, ctx, "globals", &globals_regs);
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
    installModule(L, ctx, "light", &light_regs);
    installModule(L, ctx, "lighting", &lighting_regs);
    installModule(L, ctx, "point", &point_regs);
    installModule(L, ctx, "spot", &spot_regs);
    installModule(L, ctx, "directional", &directional_regs);
    installModule(L, ctx, "ambient", &ambient_regs);
    installModule(L, ctx, "occluder", &occluder_regs);
    installModule(L, ctx, "environment", &environment_regs);
    // M9: scene transitions (the fade) and particle pool
    installModule(L, ctx, "scene", &scene_regs);
    installModule(L, ctx, "particles", &particles_regs);
    // M4.5: the camera is driven from the script on its OWN actor, and the
    // timer is a component that declares signal names. Neither needs a system
    // call per frame — the fixed step advances them.
    installModule(L, ctx, "camera", &camera_regs);
    installModule(L, ctx, "timer", &timer_regs);
    installModule(L, ctx, "time", &time_regs);
    installModule(L, ctx, "tween", &tween_regs);
    installModule(L, ctx, "flow", &flow_regs);
    installModule(L, ctx, "anim", &anim_regs);
    // M14: the game UI (Label/Button/Panel/ProgressBar + layout + queries).
    installModule(L, ctx, "ui", &ui_regs);
    // M8: the per-actor emitter. Beside `sprite` and `timer` because it is the
    // same kind of surface — methods on `self` over a plain-data component.
    installModule(L, ctx, "sound", &sound_regs);
    // M15 PARKED: tilemap module disabled until the subsystem is finished.
    // installModule(L, ctx, "tilemap", &tilemap_regs);
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

test "every binding in a module table is in the registry" {
    // The gate (`assertAllDocumented`) checks the REGISTRY against the
    // metadata. It does not check the MODULE TABLES against the registry, and
    // that gap let a real binding escape: `sprite.set_image` was installed,
    // callable from Lua, and absent from `registered_names` — so it had no
    // metadata, no stub and no line in the reference, and nothing said so.
    //
    // The module tables are the source of truth for what Lua can call, so the
    // registry has to name every one of them. This test is the check.
    const tables = [_]struct { module: []const u8, names: []const []const u8 }{
        .{ .module = "globals", .names = &.{ "get", "exists" } },
        .{ .module = "actor", .names = &.{
            "get_position", "set_position", "translate", "move_by", "get_rotation",
            "set_rotation", "get_name", "emit", "set_transform", "get_all",
            "distance_to", "distance_to_point", "distance_squared_to",
            "is_within_radius", "is_within_radius_of_point", "direction_to",
            "angle_to", "get_half_size", "set_linear_velocity", "get_linear_velocity",
            "apply_impulse", "is_awake", "add_component", "has_component",
            "remove_component",
        } },
        .{ .module = "render", .names = &.{ "set_view", "stats", "set_resident", "all_resident" } },
        .{ .module = "lighting", .names = &.{ "quality", "set_quality", "stats" } },
        .{ .module = "light", .names = &.{
            "new", "kind_of", "describe", "set_color", "set_energy", "set_blend",
            "set_shadow", "set_mask", "set_cone", "get_energy", "get_radius",
            "get_cone", "get_shadow",
        } },
        .{ .module = "point", .names = &.{ "new", "set_radius" } },
        .{ .module = "spot", .names = &.{ "new", "set_radius", "set_cone", "set_angle" } },
        .{ .module = "directional", .names = &.{ "new", "set_angle", "set_height" } },
        .{ .module = "ambient", .names = &.{ "new", "set_local" } },
        .{ .module = "occluder", .names = &.{
            "new", "set_mode", "set_threshold", "set_mask", "set_polygon",
            "get_mode", "get_threshold", "get_mask", "get_polygon",
        } },
        .{ .module = "environment", .names = &.{
            "new", "set_ambient", "set_clear", "set_bloom", "set_tonemap",
            "set_fog", "get_ambient", "get_clear", "get_fog",
        } },
        .{ .module = "scene", .names = &.{
            "fade_out", "fade_in", "fade_covered", "fade_clear", "fade_amount",
            "fading", "tint", "tint_mode", "tint_clear", "tint_amount",
        } },
        .{ .module = "particles", .names = &.{ "burst", "stats" } },
        .{ .module = "anim", .names = &.{
            "new", "load", "play", "set_param", "stop", "pause", "resume", "seek",
            "set_speed", "queue", "state", "time", "length", "is_playing",
        } },
        .{ .module = "camera", .names = &.{
            "new", "follow", "zoom_to", "shake", "set_limits", "set_damping",
            "get_centre",
        } },
        .{ .module = "timer", .names = &.{
            "new", "set_signals", "start", "stop", "kill", "progress", "restart",
            "set_duration", "get_duration", "get_elapsed", "get_loops",
            "set_kind", "set_time_scale", "is_finished", "is_paused", "get_dropped",
        } },
        .{ .module = "flow", .names = &.{
            "add_state", "add_transition", "set_initial", "fire", "set_state",
            "push", "pop", "state", "is_in", "stack",
        } },
        .{ .module = "time", .names = &.{
            "delta", "unscaled_delta", "elapsed", "unscaled_elapsed", "frame",
            "physics_delta", "scale", "set_scale", "pause", "resume", "is_paused",
        } },
        .{ .module = "tween", .names = &.{
            "to", "chain", "start", "kill", "kill_entity", "kill_all", "is_alive",
            "count", "time_scale", "set_time_scale", "properties",
        } },
        .{ .module = "material", .names = &.{ "new", "set_params", "get_params", "get_shader" } },
        .{ .module = "sprite", .names = &.{
            "rect", "circle", "texture", "set_layer", "set_visible", "set_size",
            "set_tint", "set_uv", "set_atlas", "set_image", "set_shape",
            "set_blend", "get_size", "get_tint",
        } },
        .{ .module = "physics", .names = &.{
            "cast_ray", "line_of_sight", "stats", "set_view", "set_focus",
            "create_shape", "reshape", "set_material", "set_sensor", "set_layers",
            "set_body_type", "set_body_enabled", "overlap_rect", "contains_point",
            // The physics debug bindings are PARKED (the functions are
            // commented out), so they are not in the table and not here.
        } },
        .{ .module = "world", .names = &.{ "nearby" } },
        .{ .module = "sm", .names = &.{
            "add_state", "add_transition", "set_initial", "fire", "set_state",
            "state", "is_in",
        } },
        .{ .module = "input", .names = &.{
            "is_action_pressed", "is_action_down", "get_axis", "pointer_over_ui",
        } },
        .{ .module = "ui", .names = &.{
            "set_anchor", "set_offset", "set_size", "set_pivot", "set_margin",
            "set_order", "set_visible", "set_interactive", "set_text", "set_font",
            "set_color", "set_colors", "set_border", "set_show_text", "set_value",
            "set_align", "set_enabled", "measure", "rect", "hovered", "pressed",
            "font_load",
        } },
        .{ .module = "rand", .names = &.{
            "seed", "float", "range", "int", "chance", "sign", "gauss", "choice",
            "shuffle",
        } },
        .{ .module = "noise", .names = &.{ "seed", "value", "perlin", "simplex", "fbm", "ridged" } },
        .{ .module = "log", .names = &.{ "info", "warn" } },
        .{ .module = "math", .names = &.{
            "clamp", "min", "max", "abs", "sign", "floor", "ceil", "round", "fract",
            "sqrt", "pow", "sin", "cos", "atan2", "lerp", "inverse_lerp", "remap",
            "smoothstep", "step", "move_toward", "damp", "wrap", "pingpong",
            "deg_to_rad", "rad_to_deg", "is_close", "ease", "easings",
        } },
        .{ .module = "vec2", .names = &.{
            "new", "dist", "dist_sq", "length", "length_sq", "normalized",
            "direction", "lerp", "dot", "cross", "angle", "angle_between", "rotate",
            "perpendicular", "clamp_length", "reflect", "from_angle", "to_vec",
            "clamped",
        } },
        .{ .module = "audio", .names = &.{
            "play_file", "play_stream", "stop", "stop_all", "set_volume",
            "set_pitch", "is_playing", "set_master_volume", "set_listener",
            "solo_bus", "set_bus_send", "bus_gain", "set_bus_volume", "mute_bus",
            "buses", "stats",
        } },
        .{ .module = "sound", .names = &.{
            "play", "stop", "set_volume", "set_pitch", "set_loop", "set_radius",
            "set_spread", "is_playing", "describe",
        } },
    };

    for (tables) |t| {
        for (t.names) |name| {
            var buf: [64]u8 = undefined;
            const full = std.fmt.bufPrint(&buf, "{s}.{s}", .{ t.module, name }) catch unreachable;
            var found = false;
            for (registered_names) |r| {
                if (std.mem.eql(u8, r, full)) {
                    found = true;
                    break;
                }
            }
            if (!found) {
                std.debug.print("missing from the registry: {s}\n", .{full});
                try testing.expect(found);
            }
        }
    }
}
