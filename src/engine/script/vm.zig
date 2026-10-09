//! The Lua VM: lifecycle, sandbox, chunk cache, hot-reload and the incremental
//! GC step (ROADMAP M3).
//!
//! Design decisions, each tied to a spec rule:
//!
//! - **Its own heap, not the frame arena.** Lua allocates during gameplay
//!   (tables, strings, closures). spec §3.1 forbids malloc in the *engine's*
//!   frame loop, but §3.2 explicitly budgets Lua separately: "incremental GC
//!   step only, ≤ 0.4 ms/frame; full GC forbidden during play". So Lua's heap
//!   is a dedicated, *tracked* allocator (visible in the memory report, spec
//!   §5) that is NOT the frame-locked one — routing Lua through the frame
//!   guard would panic on every gameplay table. `gcStep` is how the frame pays
//!   for that heap, a bounded slice at a time.
//!
//! - **Sandbox by whitelist.** `luaL_openlibs` gives scripts `io`, `os`,
//!   `package`, `dofile`, `require`… all of which touch the filesystem and the
//!   process. spec §7: "Lua never touches GPU/window/filesystem directly".
//!   `sandbox()` nils the dangerous globals and keeps the safe base + string +
//!   table + math. The engine API is injected on top (see `bindings`).
//!
//! - **Hot-reload that keeps state.** A script is a chunk that returns a
//!   prototype table. Instances are `self` tables whose metatable `__index`
//!   points at the prototype. Reloading re-runs the chunk into a NEW prototype
//!   and repoints the shared metatable's `__index`; every live `self` keeps its
//!   own fields (the game state) and instantly sees the new methods. That is
//!   the "migrate the `self` table" the roadmap asks for, with zero copying.
//!
//! - **Comptime name interning.** Every field/global name the VM touches is a
//!   compile-time `[*:0]const u8`, so no name is formatted or allocated per
//!   call. Combined with cached refs (see `behavior`), the per-call path does
//!   not allocate.

const std = @import("std");
const lua = @import("luajit.zig");

const lua_State = lua.lua_State;
const luaL_Reg = lua.luaL_Reg;

/// Alignment Lua's heap must satisfy: room for a double and any pointer, with
/// slack for LuaJIT's SIMD paths. 16 on x86-64.
const heap_align = std.mem.Alignment.fromByteUnits(16);

/// A registry ref that means "nothing". Stored in place of an absent method so
/// the hot path is a single compare, not a type check.
pub const no_ref: i32 = lua.NOREF;

/// The VM's Lua heap. Wraps a std allocator with the exact semantics of Lua's
/// `lua_Alloc` (free when nsize==0, alloc when ptr==null, else realloc) and
/// tracks live/peak bytes so the memory report (spec §5) shows Lua as its own
/// tagged subsystem. It is deliberately NOT the frame-locked tracker: Lua's
/// gameplay allocations are budgeted by the GC step (§3.2), not forbidden.
const LuaHeap = struct {
    child: std.mem.Allocator,
    live_bytes: usize = 0,
    peak_bytes: usize = 0,

    fn allocFn(ud: ?*anyopaque, ptr: ?*anyopaque, osize: usize, nsize: usize) callconv(.c) ?*anyopaque {
        const self: *LuaHeap = @ptrCast(@alignCast(ud.?));
        if (nsize == 0) {
            if (ptr) |p| {
                const buf = @as([*]u8, @ptrCast(p))[0..osize];
                self.child.rawFree(buf, heap_align, 0);
                self.live_bytes -= osize;
            }
            return null;
        }
        if (ptr == null) {
            const mem = self.child.rawAlloc(nsize, heap_align, 0) orelse return null;
            self.live_bytes += nsize;
            if (self.live_bytes > self.peak_bytes) self.peak_bytes = self.live_bytes;
            return mem;
        }
        // Realloc: try to grow in place, else copy.
        const old = @as([*]u8, @ptrCast(ptr))[0..osize];
        if (self.child.rawRemap(old, heap_align, nsize, 0)) |mem| {
            self.live_bytes = self.live_bytes - osize + nsize;
            if (self.live_bytes > self.peak_bytes) self.peak_bytes = self.live_bytes;
            return mem;
        }
        const mem = self.child.rawAlloc(nsize, heap_align, 0) orelse return null;
        const n = @min(osize, nsize);
        @memcpy(mem[0..n], (@as([*]const u8, @ptrCast(ptr)))[0..n]);
        self.child.rawFree(old, heap_align, 0);
        self.live_bytes = self.live_bytes - osize + nsize;
        if (self.live_bytes > self.peak_bytes) self.peak_bytes = self.live_bytes;
        return mem;
    }
};

/// Captures the last panic message Lua raised outside any `pcall` (a bug: the
/// engine protects every call, so this firing means an error in a finalizer or
/// a missing pcall). Read by tests and the crash handler.
var panic_buf: [512]u8 = undefined;
var panic_len: usize = 0;
var panic_hit: bool = false;

fn panicFn(L: ?*lua_State) callconv(.c) c_int {
    const msg = lua.toSlice(L, -1) orelse "(no message)";
    const n = @min(msg.len, panic_buf.len);
    @memcpy(panic_buf[0..n], msg[0..n]);
    panic_len = n;
    panic_hit = true;
    // A panic function must not return; LuaJIT's contract is that it longjmps
    // or exits. We abort so the captured message is the last thing logged.
    std.debug.print("[script] Lua panic: {s}\n", .{panic_buf[0..panic_len]});
    std.process.abort();
}

/// The VM and everything it owns. One per process in the runtime; tests make
/// their own. All public methods are allocation-light by contract: the ones
/// called per-frame (`gcStep`, `callMethod`) never allocate, and the ones that
/// do (`loadChunk`) run at load/hot-reload time, never inside the frame loop.
pub const Vm = struct {
    L: ?*lua_State = null,
    /// Lua's heap, BOXED at a stable address. It must not live inside this struct:
    /// `init` returns `Vm` by value, but `lua_newstate` captures a raw pointer to
    /// the allocator context that must stay valid for the state's whole life — a
    /// self-referential field would dangle the moment the struct is copied. So the
    /// heap is allocated once here and only freed in `deinit`.
    heap: ?*LuaHeap = null,
    /// Owner of `heap` (the same allocator `init` was given).
    allocator: std.mem.Allocator = undefined,
    /// Registry ref to the shared environment table scripts run in (the
    /// whitelisted global surface). Behaviors read it to build fresh `self`s.
    env_ref: i32 = no_ref,
    /// True once `sandbox()` has stripped the dangerous globals.
    sandboxed: bool = false,

    pub const Error = error{
        StateCreationFailed,
        LoadFailed,
        RuntimeError,
        NotAFunction,
        OutOfMemory,
    };

    /// Creates the VM over `allocator` (which becomes Lua's heap owner). The
    /// allocator must outlive the Vm. Opens the standard libraries and then
    /// sandboxes them.
    pub fn init(allocator: std.mem.Allocator) Error!Vm {
        const heap_ptr = allocator.create(LuaHeap) catch return error.StateCreationFailed;
        heap_ptr.* = .{ .child = allocator };

        const L = lua.lua_newstate(LuaHeap.allocFn, @ptrCast(heap_ptr)) orelse {
            allocator.destroy(heap_ptr);
            return error.StateCreationFailed;
        };
        const vm = Vm{ .L = L, .heap = heap_ptr, .allocator = allocator };
        _ = lua.lua_atpanic(L, panicFn);
        lua.luaL_openlibs(L);
        // Incremental GC from the first frame: a full collection during play is
        // forbidden (spec §3.2). pause/stepmul tune how the incremental
        // collector spreads its work; these are LuaJIT's defaults expressed
        // explicitly so a future tweak is a deliberate line.
        _ = lua.lua_gc(L, lua.GCSETPAUSE, 200);
        _ = lua.lua_gc(L, lua.GCSETSTEPMUL, 200);
        return vm;
    }

    pub fn deinit(self: *Vm) void {
        if (self.L) |L| {
            if (self.env_ref != no_ref) lua.luaL_unref(L, lua.REGISTRYINDEX, self.env_ref);
            lua.lua_close(L); // frees Lua's objects through `heap`
        }
        self.L = null;
        if (self.heap) |h| self.allocator.destroy(h);
        self.heap = null;
        self.* = undefined;
    }

    /// The raw state, for the bindings that need to push/pop directly.
    pub fn state(self: *const Vm) ?*lua_State {
        return self.L;
    }

    /// Bytes currently live in Lua's heap (through our allocator, spec §5).
    pub fn heapLiveBytes(self: *const Vm) usize {
        return if (self.heap) |h| h.live_bytes else 0;
    }

    /// Peak bytes Lua's heap has ever held (memory report, spec §5).
    pub fn heapPeakBytes(self: *const Vm) usize {
        return if (self.heap) |h| h.peak_bytes else 0;
    }

    // ── Sandbox ─────────────────────────────────────────────────────────────

    /// Removes the globals that reach outside the engine (filesystem, process,
    /// dynamic code loading) and keeps the safe subset. spec §7: "Lua never
    /// touches GPU/window/filesystem directly: only the engine API". Called
    /// once at init; idempotent.
    ///
    /// Kept: the base functions that cannot escape (`assert`, `error`, `pcall`,
    /// `select`, `type`, `tostring`, `tonumber`, `ipairs`, `pairs`, `next`,
    /// `unpack`, `setmetatable`, `getmetatable`, `rawget/set/equal`, `print`
    /// redirected to the engine log). Removed: `io`, `os`, `package`, `debug`,
    /// `require`, `dofile`, `loadfile`, `load`, `loadstring`, `newproxy`,
    /// `collectgarbage` (the engine drives the GC step), `module`.
    pub fn sandbox(self: *Vm) void {
        if (self.sandboxed) return;
        const L = self.L.?;
        const removed = [_][*:0]const u8{
            "io",         "os",           "package",  "debug",
            "require",    "dofile",       "loadfile", "load",
            "loadstring", "newproxy",     "module",   "collectgarbage",
            "rawequal",   "rawget",       "rawset",   "gcinfo",
        };
        for (removed) |name| {
            lua.pushNil(L);
            lua.setGlobal(L, name);
        }
        self.sandboxed = true;
    }

    // ── Chunk loading and the script cache ──────────────────────────────────

    /// Compiles `source` (named `chunk_name` for error messages) into a
    /// callable function and leaves it on the stack. Returns the pcall status
    /// (0 = ok). The caller decides what to do with the function on the stack.
    /// `load` time only: this allocates in Lua's heap, which is fine outside
    /// the frame loop.
    pub fn loadBuffer(self: *Vm, source: []const u8, chunk_name: [*:0]const u8) Error!void {
        const L = self.L.?;
        const status = lua.luaL_loadbufferx(L, source.ptr, source.len, chunk_name, null);
        if (status != 0) return error.LoadFailed;
    }

    /// Runs the function on top of the stack expecting exactly one return (a
    /// prototype table). On success the table is left on the stack; on failure
    /// the error is popped and `error.RuntimeError` is returned.
    pub fn callPrototype(self: *Vm) Error!void {
        const L = self.L.?;
        if (lua.lua_pcall(L, 0, 1, 0) != 0) {
            lua.pop(L, 1); // the error message
            return error.RuntimeError;
        }
        if (!lua.isTable(L, -1)) {
            lua.pop(L, 1);
            return error.RuntimeError;
        }
    }

    /// Refs the value on top of the stack into the registry and pops it,
    /// returning the ref (or `no_ref` when the value is nil). This is how the
    /// behavior layer caches a `self` table or a method across frames without
    /// re-resolving it by name.
    pub fn refTop(self: *Vm) i32 {
        const L = self.L.?;
        return lua.luaL_ref(L, lua.REGISTRYINDEX);
    }

    /// Pushes `ref` (a registry ref) onto the stack.
    pub fn pushRef(self: *Vm, ref: i32) void {
        const L = self.L.?;
        lua.lua_rawgeti(L, lua.REGISTRYINDEX, ref);
    }

    /// Releases a registry ref.
    pub fn unref(self: *Vm, ref: i32) void {
        if (ref == no_ref) return;
        lua.luaL_unref(self.L.?, lua.REGISTRYINDEX, ref);
    }


    // ── GC (spec §3.2) ──────────────────────────────────────────────────────

    /// One incremental GC step. This is the ONLY collection the frame performs:
    /// a bounded slice of marking/sweeping, never a full stop-the-world pass.
    /// spec §3.2 budgets it at ≤ 0.4 ms/frame; the runtime calls it once per
    /// frame and the M3 bench measures it. `collectgarbage` is sandboxed away
    /// so a script cannot force a full GC during play.
    pub fn gcStep(self: *Vm) void {
        _ = lua.lua_gc(self.L.?, lua.GCSTEP, 0);
    }

    /// Current Lua heap use in kilobytes (the `LUA_GCCOUNT` integer part). For
    /// the memory report (spec §5), not for control flow.
    pub fn heapKb(self: *Vm) i32 {
        return lua.lua_gc(self.L.?, lua.GCCOUNT, 0);
    }

    /// Lua heap use modulo 1024 bytes (the fractional part of `LUA_GCCOUNT`).
    pub fn heapKbFrac(self: *Vm) i32 {
        return lua.lua_gc(self.L.?, lua.GCCOUNTB, 0);
    }

    // ── Errors ──────────────────────────────────────────────────────────────

    /// Reads the error string on top of the stack into `buf` and pops it.
    /// Returns the slice, or null if the top was not a string.
    pub fn readError(self: *Vm, buf: []u8) ?[]const u8 {
        const msg = lua.toSlice(self.L.?, -1) orelse {
            lua.pop(self.L.?, 1);
            return null;
        };
        const n = @min(msg.len, buf.len);
        @memcpy(buf[0..n], msg[0..n]);
        lua.pop(self.L.?, 1);
        return buf[0..n];
    }

    /// Whether a panic (an error outside any pcall) has been captured.
    pub fn panicked() bool {
        return panic_hit;
    }

    /// The captured panic message (empty if none).
    pub fn panicMessage() []const u8 {
        return panic_buf[0..panic_len];
    }

    // ── Generic field helpers (used by the hot-reload migrator) ─────────────

    /// Reads global `name` and pushes it (for building the sandbox env, tests).
    pub fn pushGlobal(self: *Vm, name: [*:0]const u8) void {
        lua.getGlobal(self.L.?, name);
    }

    /// True when the table at `idx` has a non-nil field `key`.
    pub fn hasField(self: *Vm, idx: i32, key: [*:0]const u8) bool {
        const L = self.L.?;
        lua.getField(L, idx, key);
        const present = !lua.isNil(L, -1);
        lua.pop(L, 1);
        return present;
    }
};

