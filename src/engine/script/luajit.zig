//! LuaJIT C API bindings (the Lua 5.1 ABI, which LuaJIT implements).
//!
//! This is the ONLY file that talks to LuaJIT's C ABI. Everything above it
//! (`vm`, `bindings`, `behavior`) goes through these thin, typed wrappers, so a
//! future Lua 5.4 Web backend (ROADMAP Risks) swaps THIS file and nothing else.
//!
//! Conventions kept deliberately narrow:
//! - The Lua stack is a scratch space. Helpers here push/pop around a balanced
//!   point and never leak slots; the frame-facing code in `bindings` relies on
//!   that balance to stay allocation-free (spec §3.1).
//! - `lua_Number` is a C `double`, `lua_Integer` a `ptrdiff_t` (`isize`). The
//!   engine stores f32 in components; every boundary converts once, here.
//! - Errors surface as Lua's own error strings via `pcall`; we never longjmp
//!   across Zig frames, so a script bug is a returned error, not a crash.

const std = @import("std");

pub const lua_State = opaque {};
pub const lua_CFunction = *const fn (L: ?*lua_State) callconv(.c) c_int;

// ── Constants (lua.h / lauxlib.h) ────────────────────────────────────────────

pub const MULTIRET: c_int = -1;
pub const REGISTRYINDEX: c_int = -10000;
pub const GLOBALSINDEX: c_int = -10002;
pub const ENVIRONINDEX: c_int = -10001;
pub const NOREF: c_int = -2;
pub const REFNIL: c_int = -1;

pub const TNONE: c_int = -1;
pub const TNIL: c_int = 0;
pub const TBOOLEAN: c_int = 1;
pub const TLIGHTUSERDATA: c_int = 2;
pub const TNUMBER: c_int = 3;
pub const TSTRING: c_int = 4;
pub const TTABLE: c_int = 5;
pub const TFUNCTION: c_int = 6;
pub const TUSERDATA: c_int = 7;
pub const TTHREAD: c_int = 8;

pub const YIELD: c_int = 1;
pub const ERRRUN: c_int = 2;
pub const ERRSYNTAX: c_int = 3;
pub const ERRMEM: c_int = 4;
pub const ERRERR: c_int = 5;
pub const ERRFILE: c_int = ERRRUN + 1;

pub const GCSTOP: c_int = 0;
pub const GCRESTART: c_int = 1;
pub const GCCOLLECT: c_int = 2;
pub const GCCOUNT: c_int = 3;
pub const GCCOUNTB: c_int = 4;
pub const GCSTEP: c_int = 5;
pub const GCSETPAUSE: c_int = 6;
pub const GCSETSTEPMUL: c_int = 7;

/// The `luaL_Reg` array terminator convention: a null name ends the list.
pub const luaL_Reg = extern struct {
    name: ?[*:0]const u8,
    func: ?lua_CFunction,
};

// ── Core state lifecycle ─────────────────────────────────────────────────────

pub extern "c" fn luaL_newstate() ?*lua_State;
pub extern "c" fn lua_newstate(f: AllocFn, ud: ?*anyopaque) ?*lua_State;
pub extern "c" fn lua_close(L: ?*lua_State) void;
pub extern "c" fn lua_newthread(L: ?*lua_State) ?*lua_State;
pub extern "c" fn lua_atpanic(L: ?*lua_State, panicf: ?lua_CFunction) ?lua_CFunction;

pub const AllocFn = *const fn (ud: ?*anyopaque, ptr: ?*anyopaque, osize: usize, nsize: usize) callconv(.c) ?*anyopaque;

// ── Basic stack manipulation ─────────────────────────────────────────────────

pub extern "c" fn lua_gettop(L: ?*lua_State) c_int;
pub extern "c" fn lua_settop(L: ?*lua_State, idx: c_int) void;
pub extern "c" fn lua_pushvalue(L: ?*lua_State, idx: c_int) void;
pub extern "c" fn lua_remove(L: ?*lua_State, idx: c_int) void;
pub extern "c" fn lua_insert(L: ?*lua_State, idx: c_int) void;
pub extern "c" fn lua_replace(L: ?*lua_State, idx: c_int) void;
pub extern "c" fn lua_checkstack(L: ?*lua_State, sz: c_int) c_int;
pub extern "c" fn lua_xmove(from: ?*lua_State, to: ?*lua_State, n: c_int) void;

// ── Access functions (stack -> Zig) ──────────────────────────────────────────

pub extern "c" fn lua_type(L: ?*lua_State, idx: c_int) c_int;
pub extern "c" fn lua_typename(L: ?*lua_State, tp: c_int) [*:0]const u8;
pub extern "c" fn lua_tonumber(L: ?*lua_State, idx: c_int) f64;
pub extern "c" fn lua_tointeger(L: ?*lua_State, idx: c_int) isize;
pub extern "c" fn lua_toboolean(L: ?*lua_State, idx: c_int) c_int;
pub extern "c" fn lua_tolstring(L: ?*lua_State, idx: c_int, len: ?*usize) ?[*:0]const u8;
pub extern "c" fn lua_objlen(L: ?*lua_State, idx: c_int) usize;
pub extern "c" fn lua_tocfunction(L: ?*lua_State, idx: c_int) ?lua_CFunction;
pub extern "c" fn lua_touserdata(L: ?*lua_State, idx: c_int) ?*anyopaque;
/// Pointer of a userdata OR a light userdata. This one matters: LuaJIT's
/// `lua_touserdata` returns NULL for LIGHT userdata (verified: ttype ==
/// LUA_TLIGHTUSERDATA and `lua_touserdata` still yielded NULL), so reading a
/// stamped entity handle through it silently produced a dead entity.
pub extern "c" fn lua_topointer(L: ?*lua_State, idx: c_int) ?*const anyopaque;
pub extern "c" fn lua_tothread(L: ?*lua_State, idx: c_int) ?*lua_State;

// ── Push functions (Zig -> stack) ────────────────────────────────────────────

pub extern "c" fn lua_pushnil(L: ?*lua_State) void;
pub extern "c" fn lua_pushnumber(L: ?*lua_State, n: f64) void;
pub extern "c" fn lua_pushinteger(L: ?*lua_State, n: isize) void;
pub extern "c" fn lua_pushlstring(L: ?*lua_State, s: [*]const u8, l: usize) void;
pub extern "c" fn lua_pushstring(L: ?*lua_State, s: [*:0]const u8) void;
pub extern "c" fn lua_pushboolean(L: ?*lua_State, b: c_int) void;
pub extern "c" fn lua_pushcclosure(L: ?*lua_State, f: lua_CFunction, n: c_int) void;
pub extern "c" fn lua_pushlightuserdata(L: ?*lua_State, p: ?*anyopaque) void;

// ── Get functions (Lua -> stack) ─────────────────────────────────────────────

pub extern "c" fn lua_gettable(L: ?*lua_State, idx: c_int) void;
pub extern "c" fn lua_getfield(L: ?*lua_State, idx: c_int, k: [*:0]const u8) void;
pub extern "c" fn lua_rawget(L: ?*lua_State, idx: c_int) void;
pub extern "c" fn lua_rawgeti(L: ?*lua_State, idx: c_int, n: c_int) void;
pub extern "c" fn lua_createtable(L: ?*lua_State, narr: c_int, nrec: c_int) void;
pub extern "c" fn lua_newuserdata(L: ?*lua_State, sz: usize) ?*anyopaque;
pub extern "c" fn lua_getmetatable(L: ?*lua_State, objindex: c_int) c_int;
pub extern "c" fn lua_getfenv(L: ?*lua_State, idx: c_int) void;

// ── Set functions (stack -> Lua) ─────────────────────────────────────────────

pub extern "c" fn lua_settable(L: ?*lua_State, idx: c_int) void;
pub extern "c" fn lua_setfield(L: ?*lua_State, idx: c_int, k: [*:0]const u8) void;
pub extern "c" fn lua_rawset(L: ?*lua_State, idx: c_int) void;
pub extern "c" fn lua_rawseti(L: ?*lua_State, idx: c_int, n: c_int) void;
pub extern "c" fn lua_setmetatable(L: ?*lua_State, objindex: c_int) c_int;
pub extern "c" fn lua_setfenv(L: ?*lua_State, idx: c_int) c_int;

// ── Load and call ────────────────────────────────────────────────────────────

pub extern "c" fn lua_call(L: ?*lua_State, nargs: c_int, nresults: c_int) void;
pub extern "c" fn lua_pcall(L: ?*lua_State, nargs: c_int, nresults: c_int, errfunc: c_int) c_int;
pub extern "c" fn lua_error(L: ?*lua_State) c_int;
pub extern "c" fn lua_next(L: ?*lua_State, idx: c_int) c_int;
pub extern "c" fn lua_concat(L: ?*lua_State, n: c_int) void;

// ── GC ───────────────────────────────────────────────────────────────────────

pub extern "c" fn lua_gc(L: ?*lua_State, what: c_int, data: c_int) c_int;

// ── Auxiliary library (lauxlib.h) ────────────────────────────────────────────

pub extern "c" fn luaL_openlibs(L: ?*lua_State) void;
pub extern "c" fn luaL_register(L: ?*lua_State, libname: ?[*:0]const u8, l: [*]const luaL_Reg) void;
pub extern "c" fn luaL_setfuncs(L: ?*lua_State, l: [*]const luaL_Reg, nup: c_int) void;
pub extern "c" fn luaL_newmetatable(L: ?*lua_State, tname: [*:0]const u8) c_int;
pub extern "c" fn luaL_checkudata(L: ?*lua_State, ud: c_int, tname: [*:0]const u8) ?*anyopaque;
pub extern "c" fn luaL_ref(L: ?*lua_State, t: c_int) c_int;
pub extern "c" fn luaL_unref(L: ?*lua_State, t: c_int, ref: c_int) void;
pub extern "c" fn luaL_loadbufferx(L: ?*lua_State, buff: [*]const u8, sz: usize, name: ?[*:0]const u8, mode: ?[*:0]const u8) c_int;
pub extern "c" fn luaL_loadstring(L: ?*lua_State, s: [*:0]const u8) c_int;
pub extern "c" fn luaL_loadbuffer(L: ?*lua_State, buff: [*]const u8, size: usize, name: [*:0]const u8) c_int;
pub extern "c" fn luaL_error(L: ?*lua_State, fmt: [*:0]const u8, ...) c_int;
pub extern "c" fn luaL_argerror(L: ?*lua_State, numarg: c_int, extramsg: [*:0]const u8) c_int;
pub extern "c" fn luaL_checklstring(L: ?*lua_State, numArg: c_int, l: ?*usize) [*:0]const u8;
pub extern "c" fn luaL_checknumber(L: ?*lua_State, numArg: c_int) f64;
pub extern "c" fn luaL_checkinteger(L: ?*lua_State, numArg: c_int) isize;
pub extern "c" fn luaL_where(L: ?*lua_State, lvl: c_int) void;

// ── Thin typed wrappers over the raw ABI ─────────────────────────────────────
// These are the ergonomic layer `vm`/`bindings` use. They are `inline` where
// trivial so the optimizer erases them; none of them allocate.

/// Pops `n` values off the stack.
pub inline fn pop(L: ?*lua_State, n: c_int) void {
    lua_settop(L, -(n) - 1);
}

/// Reads the value at `idx` as an f32 (engine storage width). 0 when not a
/// number, matching `lua_tonumber`'s coercion-by-zero.
pub inline fn toF32(L: ?*lua_State, idx: c_int) f32 {
    return @floatCast(lua_tonumber(L, idx));
}

/// Reads the value at `idx` as a Zig bool.
pub inline fn toBool(L: ?*lua_State, idx: c_int) bool {
    return lua_toboolean(L, idx) != 0;
}

/// Reads the value at `idx` as a borrowed slice (valid until the value leaves
/// the stack). Null bytes are preserved; use this over a C-string read when the
/// payload may be binary.
pub inline fn toSlice(L: ?*lua_State, idx: c_int) ?[]const u8 {
    var len: usize = 0;
    const ptr = lua_tolstring(L, idx, &len) orelse return null;
    return ptr[0..len];
}

/// Pushes an f32 as a Lua number.
pub inline fn pushF32(L: ?*lua_State, v: f32) void {
    lua_pushnumber(L, v);
}

/// Pushes a byte slice as a Lua string (copied into the VM).
pub inline fn pushSlice(L: ?*lua_State, s: []const u8) void {
    lua_pushlstring(L, s.ptr, s.len);
}

/// Pushes a null-terminated static string as a Lua string.
pub inline fn pushStatic(L: ?*lua_State, s: [*:0]const u8) void {
    lua_pushstring(L, s);
}

/// Pushes nil onto the stack.
pub inline fn pushNil(L: ?*lua_State) void {
    lua_pushnil(L);
}

/// Inserts the top element at `idx`, shifting elements above it up.
pub inline fn insert(L: ?*lua_State, idx: c_int) void {
    lua_insert(L, idx);
}

/// Removes the element at `idx`, shifting elements above it down.
pub inline fn remove(L: ?*lua_State, idx: c_int) void {
    lua_remove(L, idx);
}

/// Returns the index of the top element in the stack.
pub inline fn getTop(L: ?*lua_State) c_int {
    return lua_gettop(L);
}

/// Type test helpers mirroring the `lua_is*` macros.
pub inline fn isNumber(L: ?*lua_State, idx: c_int) bool {
    return lua_type(L, idx) == TNUMBER;
}
pub inline fn isString(L: ?*lua_State, idx: c_int) bool {
    return lua_type(L, idx) == TSTRING;
}
pub inline fn isTable(L: ?*lua_State, idx: c_int) bool {
    return lua_type(L, idx) == TTABLE;
}
pub inline fn isFunction(L: ?*lua_State, idx: c_int) bool {
    return lua_type(L, idx) == TFUNCTION;
}
pub inline fn isNil(L: ?*lua_State, idx: c_int) bool {
    return lua_type(L, idx) == TNIL;
}
pub inline fn isUserdata(L: ?*lua_State, idx: c_int) bool {
    return lua_type(L, idx) == TUSERDATA;
}
pub inline fn isLightUserdata(L: ?*lua_State, idx: c_int) bool {
    return lua_type(L, idx) == TLIGHTUSERDATA;
}

/// Reads a field `k` of the table at `idx` and pushes it (leaves it on top).
pub inline fn getField(L: ?*lua_State, idx: c_int, k: [*:0]const u8) void {
    lua_getfield(L, idx, k);
}

/// Pops the top and stores it as field `k` of the table at `idx`.
pub inline fn setField(L: ?*lua_State, idx: c_int, k: [*:0]const u8) void {
    lua_setfield(L, idx, k);
}

/// Pushes a global `name`.
pub inline fn getGlobal(L: ?*lua_State, name: [*:0]const u8) void {
    lua_getfield(L, GLOBALSINDEX, name);
}

/// Pseudo-index of a C closure's i-th upvalue (1-based): `lua_upvalueindex(i)`.
/// The upvalues of the running closure live just below the globals pseudo-index.
pub inline fn upvalueindex(i: c_int) c_int {
    return GLOBALSINDEX - i;
}

/// Pops the top and stores it as the global `name`.
pub inline fn setGlobal(L: ?*lua_State, name: [*:0]const u8) void {
    lua_setfield(L, GLOBALSINDEX, name);
}

/// Reads a string value (empty string if the value is not a string).
pub inline fn toString(L: ?*lua_State, idx: c_int) []const u8 {
    return toSlice(L, idx) orelse "";
}

/// Sets `_G[name]` to a plain C function. The behavior driver uses it to
/// publish `__behavior_error`, which the Lua-side update loop calls on failure.
pub inline fn setGlobalFromC(L: ?*lua_State, name: [*:0]const u8, func: lua_CFunction) void {
    lua_pushcclosure(L, func, 0);
    lua_setfield(L, GLOBALSINDEX, name);
}

/// Registers a null-terminated `luaL_Reg` list into the table on top of the
/// stack (the auxlib equivalent, minus the libname table creation).
pub inline fn setFuncs(L: ?*lua_State, l: [*]const luaL_Reg) void {
    luaL_setfuncs(L, l, 0);
}
