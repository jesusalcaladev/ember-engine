//! Behaviors: the Lua-side of the Actor+ECS hybrid (ROADMAP M3).
//!
//! A **behavior** is a Lua script bound to an actor, with a lifecycle:
//! `start` (once, on the first update), `update(dt)` (every rendered frame),
//! `fixed_update(dt)` (every fixed 60 Hz tick), `on_signal(name)` (when a signal
//! this actor listens to drains) and `on_destroy` (before the actor goes away).
//!
//! How it stays inside spec §2 ("Lua behaviors 10k updates ≤ 2 ms") and §3.1
//! (no allocation in the frame):
//! - **Dense instances.** All live behaviors sit in one `[]Instance` array. The
//!   update loop is a flat walk over it — no query, no hash, no pointer chase
//!   per actor beyond the cached refs. `reserve`/`lock` mirror the renderer's
//!   discipline: capacities are fixed at load, and a frame that would exceed
//!   them reports an overflow instead of allocating.
//! - **Refs cached, not resolved.** Each instance caches the `self` table ref
//!   and its lifecycle method refs. The hot path (`update`) pushes the cached
//!   `self`, pushes `dt`, and `pcall`s the cached `update` — no `getfield` by
//!   name, no string compare, nothing allocated.
//! - **The actor is a stamped handle.** `self` carries its entity as light
//!   userdata, so a binding reaches the Transform with one `world.get`.
//!
//! The `Script` ECS component is the serializable link: it stores a `script_id`
//! (a stable index into the script cache), never a VM ref. Save/load reproduces
//! the scene; the runtime re-binds the id to the live script on load. That keeps
//! `.zson` bit-exact (spec §6) — a Lua registry ref is meaningless on disk.

const std = @import("std");
const core = @import("core");
const ecs = @import("ecs");
const core_log = core.log.scoped("behavior");
const vm_mod = @import("vm.zig");
const scripts_mod = @import("scripts.zig");
const bindings = @import("bindings.zig");
const input = @import("input.zig");

const World = ecs.World;
const Actor = ecs.Actor;
const Entity = ecs.Entity;
const components = ecs.components;
const lua = @import("luajit.zig");
const lua_State = lua.lua_State;
const no_ref = vm_mod.no_ref;
const entity_key = bindings.entity_key;

// Local aliases over the raw C ABI, so the hot loops read as Lua operations
// rather than C calls. All are `inline` and erased by the optimizer.
inline fn lua_pop(L: ?*lua.lua_State, n: i32) void {
    lua.setTop(L, -(n) - 1);
}
inline fn lua_getfield_top(L: ?*lua.lua_State, name: [*:0]const u8) void {
    lua.getField(L, -1, name);
}
inline fn lua_is_function(L: ?*lua.lua_State) bool {
    return lua.isFunction(L, -1);
}

/// One live behavior instance. Plain data; the Lua `self` table lives in the VM
/// and is reached through `self_ref`.
const Instance = struct {
    entity: Entity,
    script_id: scripts_mod.ScriptId,
    /// Registry ref to this instance's `self` table.
    self_ref: i32,
    /// 1-based index of this instance in the Lua-side `self` table that the
    /// driver iterates. Kept in sync with the position in `instances`, so a
    /// swap-remove has to fix both sides (see `removeInstanceAt`).
    lua_slot: u32 = 0,
    /// Cached method refs (`no_ref` when the script does not define them). This
    /// is what makes the per-frame call a push+pcall with no name lookup.
    update_ref: i32 = no_ref,
    fixed_update_ref: i32 = no_ref,
    on_signal_ref: i32 = no_ref,
    on_destroy_ref: i32 = no_ref,
    /// True once `start` has run (idempotent across reloads).
    started: bool = false,
    /// Flipped false when the entity died; swept on the next update.
    alive: bool = true,
};

/// The driver: a small Lua chunk that loops over every instance table and
/// calls `update` on it. This is THE optimization of the M3 gameplay path.
///
/// Why the loop lives in Lua instead of Zig: driving a behavior from Zig costs
/// four C calls per instance (push fn, push self, push dt, pcall), and the
/// isolated cost is ~65 ns of pure framework overhead before any gameplay
/// runs — 0.65 ms for 10k behaviors against spec §2's 2.0 ms row, plus the
/// same again per frame for `fixedUpdate`. Running the loop INSIDE LuaJIT
/// costs three C calls per FRAME and lets the tracing JIT compile the whole
/// iteration, so the per-instance overhead collapses to a table read and a
/// call. Measured with the bench in `src/bench/script.zig`.
///
/// Error isolation is preserved per instance (`pcall` inside the loop), and the
/// message goes back through `__behavior_error`, a C function closed over the
/// Behaviors context, so a broken script is still a logged line and not a dead
/// frame. `return errors` gives the frame its error count without a C call.
const driver_src =
    \\local M = {}
    \\local report = __behavior_error
    \\function M.drive(insts, dt)
    \\  local errors = 0
    \\  local n = #insts
    \\  local i = 1
    \\  while i <= n do
    \\    local inst = insts[i]
    \\    local fn = inst.update
    \\    if fn ~= nil then
    \\      local ok, err = pcall(fn, inst, dt)
    \\      if not ok then
    \\        errors = errors + 1
    \\        if report ~= nil then report(inst, err) end
    \\      end
    \\    end
    \\    i = i + 1
    \\  end
    \\  return errors
    \\end
    \\return M
;

/// The behavior system: owns the VM, the script cache and the dense instance
/// array, and drives the lifecycle. The runtime creates one, reserves capacity
/// at load, and calls `startAll`/`update`/`fixedUpdate` from the frame loop.
pub const Behaviors = struct {
    vm: vm_mod.Vm,
    scripts: scripts_mod.Scripts,
    ctx: bindings.Context,
    instances: std.ArrayListUnmanaged(Instance) = .empty,
    allocator: std.mem.Allocator,
    /// Per-frame counters for the acceptance report (M3 criteria).
    updates: u32 = 0,
    errors: u32 = 0,
    locked: bool = false,
    /// Registry ref to the dense `self` table the driver iterates, and to the
    /// driver function itself. Both live for the system's lifetime.
    insts_table_ref: i32 = no_ref,
    driver_ref: i32 = no_ref,

    pub const Error = error{ OutOfMemory, StateCreationFailed, DriverCompilationFailed } || vm_mod.Vm.Error || scripts_mod.Scripts.Error;

    /// Wires this Behaviors system in place: creates the VM (sandboxed Lua heap
    /// owner), binds the engine API against `world` + `input`, and prepares the
    /// script cache.
    ///
    /// This takes `*Behaviors` instead of returning a value because the system is
    /// SELF-REFERENTIAL: `scripts` holds `&self.vm`, and the registered C
    /// functions hold `&self.ctx` as an upvalue. If `init` built a local and
    /// returned it by value, those pointers would dangle the moment the caller
    /// copied it. The caller declares the storage (a stack `var` in `main`, a
    /// test, or a box) and never moves it — then every interior pointer stays
    /// valid. `world` and `input` must likewise outlive this struct.
    pub fn init(
        self: *Behaviors,
        allocator: std.mem.Allocator,
        world: *World,
        input_snap: *const input.Input,
    ) Error!void {
        self.* = Behaviors{ .vm = undefined, .scripts = undefined, .ctx = undefined, .allocator = allocator };
        self.vm = try vm_mod.Vm.init(allocator);
        errdefer self.vm.deinit();
        self.vm.sandbox();
        self.ctx = bindings.Context.init(world, input_snap);
        bindings.registerAll(self.vm.state(), &self.ctx);
        self.scripts = scripts_mod.Scripts.init(&self.vm, allocator);
        self.buildDriver() catch |e| {
            self.scripts.deinit();
            self.vm.deinit();
            return e;
        };
    }

    /// Compiles the Lua-side loop and the dense `self` table it iterates.
    ///
    /// Called once at init. The driver needs `__behavior_error` to exist in the
    /// sandbox (it is a C function closed over this Behaviors' context), and it
    /// must be compiled AFTER `registerAll` — hence here and not in the VM.
    fn buildDriver(self: *Behaviors) Error!void {
        const L = self.vm.state().?;
        // `__behavior_error(self, msg)`: reports one instance's error through the
        // same channel as a Zig-side failure, so both paths log identically.
        lua.setGlobalFromC(L, "__behavior_error", reportError);

        _ = lua.lua_createtable(L, 0, 0); // [insts]
        self.insts_table_ref = self.vm.refTop(); // ref + pop

        // Compile and keep the driver module's `drive` function.
        // The source is a comptime string: `loadbuffer` avoids the null-terminator copy.
        if (lua.luaL_loadbuffer(L, driver_src, driver_src.len, "@behavior_driver") != 0)
            return error.DriverCompilationFailed;
        // pcall it: the chunk returns the module table (needs the base/sandbox).
        if (lua.lua_pcall(L, 0, 1, 0) != 0) return error.DriverCompilationFailed;
        lua.getField(L, -1, "drive"); // [module, drive]
        // Keep `drive` (the top) and drop the module table under it.
        self.driver_ref = self.vm.refTop2();
    }

    pub fn deinit(self: *Behaviors) void {
        for (self.instances.items) |*inst| {
            self.vm.unref(inst.self_ref);
            self.vm.unref(inst.update_ref);
            self.vm.unref(inst.fixed_update_ref);
            self.vm.unref(inst.on_signal_ref);
            self.vm.unref(inst.on_destroy_ref);
        }
        self.instances.deinit(self.allocator);
        if (self.driver_ref != no_ref) self.vm.unref(self.driver_ref);
        if (self.insts_table_ref != no_ref) self.vm.unref(self.insts_table_ref);
        self.scripts.deinit();
        self.vm.deinit();
    }

    /// The VM (for the runtime to drive the GC step and read heap stats).
    pub fn vmLoop(self: *Behaviors) *vm_mod.Vm {
        return &self.vm;
    }

    /// Loads a script by name. Returns its stable id (used by the `Script`
    /// component and by `attach`). Re-loading the same name hot-reloads it.
    pub fn load(self: *Behaviors, name: []const u8, source: []const u8) Error!scripts_mod.ScriptId {
        const id = try self.scripts.load(name, source);
        // Loading a name that ALREADY has live instances IS a hot-reload: the
        // prototype behind their metatable just changed, so the cached method
        // refs are stale. Re-resolving here (instead of only in `reload`) is
        // what makes "edit the file and reload it" just work — and for a brand
        // new name the loop is a no-op because there are no instances yet.
        self.recacheInstancesOf(id);
        return id;
    }

    /// Re-resolves the cached lifecycle method refs of every instance bound to
    /// `id`. Call after a script's prototype changed. State (`self` tables)
    /// is untouched: only the closures cached per instance move.
    fn recacheInstancesOf(self: *Behaviors, id: scripts_mod.ScriptId) void {
        for (self.instances.items) |*inst| {
            if (inst.script_id != id) continue;
            self.cacheMethods(inst);
        }
    }

    /// Hot-reloads a script by name, preserving every live instance's state.
    pub fn reload(self: *Behaviors, name: []const u8, source: []const u8) Error!void {
        const id = try self.scripts.reload(name, source);
        self.recacheInstancesOf(id);
    }

    /// Pre-allocates the instance array. Call at load time; `lock` freezes it.
    pub fn reserve(self: *Behaviors, n: usize) !void {
        if (n > self.instances.capacity) {
            try self.instances.ensureTotalCapacity(self.allocator, n);
        }
    }

    /// Freezes capacity: a frame that would exceed it reports an overflow rather
    /// than allocating (spec §3.1, mirroring the renderer's discipline).
    pub fn lock(self: *Behaviors) void {
        self.locked = true;
    }

    pub fn instanceCount(self: *const Behaviors) usize {
        return self.instances.items.len;
    }

    /// Binds a script to an actor: instantiates a `self` table, stamps the
    /// entity handle into it, caches the lifecycle method refs, and records the
    /// instance. Also adds the serializable `Script` component so save/load can
    /// reconstruct the binding. Instantiation allocates (one table + refs), so
    /// this is load/spawn time, never the frame loop.
    pub fn attach(
        self: *Behaviors,
        entity: Entity,
        script_id: scripts_mod.ScriptId,
    ) !void {
        if (self.locked and self.instances.items.len >= self.instances.capacity) {
            self.errors += 1;
            return error.OutOfMemory;
        }
        const L = self.vm.state().?;

        // 1. Fresh `self` with the shared metatable; stamp the entity handle.
        self.scripts.instantiate(script_id); // leaves `self` on top
        bindings.stampSelfEntity(L, entity);
        const self_ref = self.vm.refTop(); // ref + pop `self`

        // 2. Record the instance and resolve its cached method refs.
        var inst = Instance{
            .entity = entity,
            .script_id = script_id,
            .self_ref = self_ref,
        };
        self.cacheMethods(&inst);

        const slot: u32 = @intCast(self.instances.items.len + 1);
        inst.lua_slot = slot;
        try self.instances.append(self.allocator, inst);

        // Keep the Lua-side dense table in step: insts[slot] = self. This is the
        // array the driver walks, so its length must equal `instances.len` at
        // every point between frames.
        self.vm.pushRef(self.insts_table_ref); // [insts]
        self.vm.pushRef(self_ref); // [insts, self]
        lua.lua_rawseti(L, -2, @intCast(slot)); // insts[slot] = self (pops self)
        lua.pop(L, 1); // []

        // 3. The serializable link: a `Script` component holding the stable id.
        try self.ctx.world.add(entity, components.Script{ .script = script_id });
    }

    /// Resolves and caches an instance's lifecycle method refs off the shared
    /// prototype. A method the script does not define caches as `no_ref`, so the
    /// hot path is a single integer compare. Called at attach and after reload.
    fn cacheMethods(self: *Behaviors, inst: *Instance) void {
        const L = self.vm.state().?;
        // The metatable's __index IS the prototype; reading a method name off
        // `self` resolves through it, so one getfield per name suffices.
        //
        // Do NOT cache the resolved method onto `self` itself: an instance field
        // SHADOWS the prototype, so the next reload would resolve `update` to
        // the very function it is trying to replace (measured: the reload test
        // went back to the old body). Paying the metatable lookup is 0.05 ms
        // per 10k instances; getting hot-reload wrong is not a trade.
        self.vm.pushRef(inst.self_ref); // push self
        inst.update_ref = self.refMethod(L, "update");
        inst.fixed_update_ref = self.refMethod(L, "fixed_update");
        inst.on_signal_ref = self.refMethod(L, "on_signal");
        inst.on_destroy_ref = self.refMethod(L, "on_destroy");
        lua.pop(L, 1); // pop self
    }

    /// Reads field `name` off the table on top of the stack; if it is a function,
    /// refs and pops it (returns the ref); else pops it and returns `no_ref`.
    fn refMethod(self: *Behaviors, L: ?*lua.lua_State, name: [*:0]const u8) i32 {
        lua_getfield_top(L, name);
        if (!lua_is_function(L)) {
            lua.pop(L, 1);
            return no_ref;
        }
        return self.vm.refTop();
    }

    /// Runs `start` once on every instance that has not started yet. The runtime
    /// calls this before the first `update`. Idempotent: an instance that has
    /// started is skipped, and a hot-reload does NOT re-run `start` (state
    /// survives; `start` is for one-time setup).
    pub fn startAll(self: *Behaviors) void {
        const L = self.vm.state().?;
        for (self.instances.items) |*inst| {
            if (inst.started) continue;
            if (!self.ctx.world.isAlive(inst.entity)) continue; // sweep finalizes it
            inst.started = true;
            // Call `self:start()` if the script defines it. `start` is resolved
            // on demand here (once per instance, not per frame), so it is not in
            // the cached hot-path set. Stack: [self] -> getfield -> [self, fn];
            // then push self again as the argument -> [self, fn, self] and
            // pcall(1) (function + one arg = self), leaving the original [self].
            self.vm.pushRef(inst.self_ref); // [self]
            lua.getField(L, -1, "start"); // [self, fn_or_nil]
            if (lua.isFunction(L, -1)) {
                self.vm.pushRef(inst.self_ref); // [self, fn, self]
                self.callMethod(inst, 1); // pcall(1): fn(self) -> [self]
            } else {
                lua.pop(L, 1); // [self]
            }
            lua.pop(L, 1); // []
        }
    }

    /// Runs `update(dt)` on every live instance. The M3 acceptance path: "10k
    /// behavior updates ≤ 2 ms". A flat walk over cached refs; the only per-call
    /// work is two stack pushes and a protected call. Errors are caught, counted
    /// and logged — one broken script never takes down the frame (spec: a script
    /// bug is a logged error, not a crash).
    pub fn update(self: *Behaviors, dt: f32) void {
        self.updates = 0;
        const n = self.instances.items.len;
        if (n == 0 or self.driver_ref == no_ref) return;
        const state = self.vm.state().?;

        // THREE C calls per FRAME instead of four per instance: push the
        // driver, push the dense `self` table, push dt — then one pcall. The
        // per-instance loop (and its own pcall) runs inside LuaJIT, where the
        // tracing JIT can compile it. See `driver_src` for the measurement that
        // justifies it.
        self.vm.pushRef(self.driver_ref); // [drive]
        self.vm.pushRef(self.insts_table_ref); // [drive, insts]
        lua.pushF32(state, dt); // [drive, insts, dt]
        if (lua.lua_pcall(state, 2, 1, 0) != 0) {
            // The driver itself failing is an engine bug (its own errors are
            // caught per instance inside), so report it loudly.
            self.errors += 1;
            var buf: [256]u8 = undefined;
            if (self.vm.readError(&buf)) |msg| {
                core_log.err("behavior driver failed: {s}", .{msg});
            }
            return;
        }
        // The driver returns how many instances errored; `reportError` already
        // logged each one, so this is only the counter the report reads.
        if (lua.isNumber(state, -1)) {
            const reported: u64 = @intFromFloat(lua.lua_tonumber(state, -1));
            if (reported > 0) self.errors += @intCast(reported);
        }
        lua.pop(state, 1); // []
        self.updates = @intCast(n);
    }

    /// `__behavior_error(self, msg)`: published as a global at init and called by
    /// the driver's Lua-side pcall when one behavior raises. Logging happens
    /// here rather than counting in Lua so a broken script produces exactly the
    /// same output whether it was driven from Zig or from the Lua loop.
    fn reportError(L: ?*lua_State) callconv(.c) c_int {
        const msg = lua.toString(L, 2);
        core_log.err("behavior: {s}", .{msg});
        return 0;
    }

    /// Removes the instance at `i` and fixes BOTH stores: the Zig array
    /// (swap-remove) and the Lua dense table (move the last element into the
    /// hole, clear the tail). Every removal path goes through here, because a
    /// desync between the two is silent and drops or double-runs a behavior.
    fn removeInstanceAt(self: *Behaviors, i: usize) void {
        const inst = self.instances.items[i];
        self.vm.unref(inst.self_ref);
        self.vm.unref(inst.update_ref);
        self.vm.unref(inst.fixed_update_ref);
        self.vm.unref(inst.on_signal_ref);
        self.vm.unref(inst.on_destroy_ref);

        const L = self.vm.state().?;
        const last = self.instances.items.len;
        if (i + 1 != last) {
            const moved = &self.instances.items[last - 1];
            moved.lua_slot = inst.lua_slot;
            self.vm.pushRef(self.insts_table_ref); // [insts]
            self.vm.pushRef(moved.self_ref); // [insts, self]
            lua.lua_rawseti(L, -2, @intCast(inst.lua_slot)); // insts[hole] = last
            lua.pop(L, 1); // []
        }
        // Clear the tail so the driver's `#insts` shrinks with the array.
        self.vm.pushRef(self.insts_table_ref); // [insts]
        lua.pushNil(L); // [insts, nil]
        lua.lua_rawseti(L, -2, @intCast(last)); // insts[last] = nil
        lua.pop(L, 1); // []

        _ = self.instances.swapRemove(i);
    }

    /// Runs `fixed_update(dt)` on every live instance, once per fixed 60 Hz tick.
    /// Same shape as `update`; kept separate so the runtime drives them from
    /// different points in the loop (spec §3.3: fixed sim, decoupled render).
    pub fn fixedUpdate(self: *Behaviors, dt: f32) void {
        const L = self.vm.state().?;
        for (self.instances.items) |*inst| {
            if (!inst.alive) continue;
            if (!self.ctx.world.isAlive(inst.entity)) continue; // sweep finalizes it
            if (inst.fixed_update_ref == no_ref) continue;
            self.vm.pushRef(inst.fixed_update_ref);
            self.vm.pushRef(inst.self_ref);
            lua.pushF32(L, dt);
            self.callMethod(inst, 2); // fn(self, dt)
        }
    }

    /// Invokes `on_signal(name)` on every live instance that defines it. The
    /// runtime calls this from the signal drain so Lua handlers run in the same
    /// frame the signal fires, after the typed Zig listeners.
    pub fn dispatchSignal(self: *Behaviors, name: []const u8) void {
        const L = self.vm.state().?;
        for (self.instances.items) |*inst| {
            if (!inst.alive) continue;
            if (!self.ctx.world.isAlive(inst.entity)) continue;
            if (inst.on_signal_ref == no_ref) continue;
            self.vm.pushRef(inst.on_signal_ref); // [fn]
            self.vm.pushRef(inst.self_ref); // [fn, self]
            lua.pushSlice(L, name); // [fn, self, name]
            self.callMethod(inst, 2); // fn(self, name)
        }
    }

    /// Protected call helper: the function and its `nargs` arguments are already
    /// on the stack as `[fn, arg1, ... argN]`. `nargs` counts EVERY argument,
    /// including `self` (a colon call `self:update(dt)` is `fn(self, dt)` = 2).
    /// On error the message is popped, counted and logged; on success pcall
    /// pops fn+args and pushes 0 results, so the stack stays balanced. Never
    /// longjmps across Zig.
    fn callMethod(self: *Behaviors, inst: *Instance, nargs: c_int) void {
        const L = self.vm.state().?;
        if (lua.lua_pcall(L, nargs, 0, 0) != 0) {
            self.errors += 1;
            var buf: [256]u8 = undefined;
            if (self.vm.readError(&buf)) |msg| {
                core_log.err("behavior on entity {d}: {s}", .{ inst.entity.index, msg });
            }
        }
    }

    /// Sweeps dead instances: for each whose entity died, runs `on_destroy`
    /// (once), releases its Lua refs, and swap-removes it from the array. The
    /// runtime calls this once per frame after the update passes. Swap-remove
    /// keeps it O(1) per removal and does not disturb the live instances, which
    /// is what keeps the "no allocation in the frame" rule while still honoring
    /// the `on_destroy` lifecycle.
    pub fn sweepDestroyed(self: *Behaviors) void {
        const L = self.vm.state().?;
        _ = L;
        var i: usize = 0;
        while (i < self.instances.items.len) {
            const inst = &self.instances.items[i];
            if (inst.alive and self.ctx.world.isAlive(inst.entity)) {
                i += 1;
                continue;
            }
            // Dead: fire on_destroy if defined and not already fired.
            if (inst.alive and inst.on_destroy_ref != no_ref) {
                self.vm.pushRef(inst.on_destroy_ref); // [fn]
                self.vm.pushRef(inst.self_ref); // [fn, self]
                self.callMethod(inst, 1); // pcall(1): fn(self)
            }
            // Release every cached ref for this instance and fix both stores.
            // Swap-remove keeps it O(1) and does not disturb the rest.
            self.removeInstanceAt(i);
        }
    }

    /// Detaches a behavior from an actor explicitly (frees its Lua state without
    /// waiting for the entity to die). Used by the editor when a component is
    /// removed during play.
    pub fn detach(self: *Behaviors, entity: Entity) void {
        var i: usize = 0;
        while (i < self.instances.items.len) : (i += 1) {
            if (!self.instances.items[i].entity.eql(entity)) continue;
            self.removeInstanceAt(i);
            return;
        }
    }
};

// ── End-to-end tests ─────────────────────────────────────────────────────────
// These drive the REAL stack: a World, a sandBoxed VM, the registered C
// bindings, a Lua script, and the lifecycle. They are the acceptance proof for
// M3's core claims (bindings reach the ECS, hot-reload preserves state).

/// Reads a numeric field off an instance's `self` table (test-only: reaches
/// into `instances`, which the public API keeps hidden).
fn readSelfNumber(b: *Behaviors, self_ref: i32, key: [*:0]const u8) ?f64 {
    const L = b.vm.state().?;
    b.vm.pushRef(self_ref); // [self]
    lua.getField(L, -1, key); // [self, v]
    const v: ?f64 = if (lua.isNumber(L, -1)) lua.lua_tonumber(L, -1) else null;
    lua.pop(L, 2); // []
    return v;
}

/// Reads a string field off an instance's `self` table (test-only).
fn readSelfString(b: *Behaviors, self_ref: i32, key: [*:0]const u8) ?[]const u8 {
    const L = b.vm.state().?;
    b.vm.pushRef(self_ref); // [self]
    lua.getField(L, -1, key); // [self, v]
    const s = if (lua.isString(L, -1)) lua.toSlice(L, -1) else null;
    lua.pop(L, 2); // []
    return s;
}

/// Reads a numeric global (used to observe `on_destroy`, which would otherwise
/// have its `self` released the moment the instance is swept).
fn readGlobalNumber(b: *Behaviors, key: [*:0]const u8) ?f64 {
    const L = b.vm.state().?;
    lua.getGlobal(L, key); // [v]
    const v: ?f64 = if (lua.isNumber(L, -1)) lua.lua_tonumber(L, -1) else null;
    lua.pop(L, 1); // []
    return v;
}

/// A single test harness wiring a World + Input + Behaviors. The `var` storage

const counter_src =
    \\local M = {}
    \\function M:start()
    \\  self.n = 0
    \\  self.step = 2
    \\end
    \\function M:update(dt)
    \\  self.n = self.n + 1
    \\  actor.translate(self, self.step, 0)
    \\end
    \\function M:on_signal(name)
    \\  self.last_signal = name
    \\end
    \\function M:on_destroy()
    \\  destroy_count = (destroy_count or 0) + 1
    \\end
    \\return M
;

// A reloaded body: `start` is NOT re-run on reload, and its new values (n=0,
// step=999) must NOT take effect — the instance keeps its own state. Only the
// methods change: `update` now moves by 100 instead of `step`.
const reloaded_src =
    \\local M = {}
    \\function M:start()
    \\  self.n = 0
    \\  self.step = 999
    \\end
    \\function M:update(dt)
    \\  self.n = self.n + 1
    \\  actor.translate(self, 100, 0)
    \\end
    \\return M
;

test "behavior lifecycle: start, update drives the ECS, signal dispatch" {
    var h: Harness = undefined;
    try h.init(std.testing.allocator);
    defer h.deinit();

    const sid = try h.b.load("counter.lua", counter_src);
    const e = try h.world.spawn(.{components.Transform{ .position = .{ .x = 0, .y = 0 } }});
    try h.b.attach(e, sid);
    h.b.startAll();

    // `start` set self.n=0 and self.step=2 on the instance.
    const self_ref = h.b.instances.items[0].self_ref;
    try std.testing.expectEqual(@as(f64, 0), readSelfNumber(&h.b, self_ref, "n").?);
    try std.testing.expectEqual(@as(f64, 2), readSelfNumber(&h.b, self_ref, "step").?);

    // Two updates: n=2, and the `translate` binding moved the Transform +2 each
    // (proves the Lua->C->Entity->World bridge works end to end).
    h.b.update(1.0 / 60.0);
    h.b.update(1.0 / 60.0);
    const t = h.world.get(e, components.Transform).?;
    try std.testing.expectEqual(@as(f32, 4), t.position.x);
    try std.testing.expectEqual(@as(f64, 2), readSelfNumber(&h.b, self_ref, "n").?);
    // `updates` is the PER-CALL instance count (what the §2 budget measures),
    // not a cumulative total: every update() reports how many behaviors ran.
    try std.testing.expectEqual(@as(u32, 1), h.b.updates);

    // The `Script` component links the actor to the script (the serializable id).
    try std.testing.expectEqual(sid, h.world.get(e, components.Script).?.script);

    // Signal dispatch calls on_signal with the event name.
    h.b.dispatchSignal("hit");
    try std.testing.expectEqualStrings("hit", readSelfString(&h.b, self_ref, "last_signal").?);
}

test "hot-reload preserves self state while swapping methods (ROADMAP M3)" {
    var h: Harness = undefined;
    try h.init(std.testing.allocator);
    defer h.deinit();

    const sid = try h.b.load("counter.lua", counter_src);
    const e = try h.world.spawn(.{components.Transform{ .position = .{ .x = 0, .y = 0 } }});
    try h.b.attach(e, sid);
    h.b.startAll();

    h.b.update(1.0 / 60.0);
    h.b.update(1.0 / 60.0); // n=2, x=4
    const self_ref = h.b.instances.items[0].self_ref;
    try std.testing.expectEqual(@as(f64, 2), readSelfNumber(&h.b, self_ref, "n").?);
    try std.testing.expectEqual(@as(f32, 4), h.world.get(e, components.Transform).?.position.x);

    // Hot-reload: same name, new source. The id is unchanged.
    const sid2 = try h.b.load("counter.lua", reloaded_src);
    try std.testing.expectEqual(sid, sid2);

    // One update under the new code: n CONTINUES (2 -> 3, start did not re-run)
    // and the new `translate(100, 0)` body runs (x jumps by 100). Both facts
    // together prove the `self` table (state) survived while the method changed.
    h.b.update(1.0 / 60.0);
    try std.testing.expectEqual(@as(f64, 3), readSelfNumber(&h.b, self_ref, "n").?);
    try std.testing.expectEqual(@as(f32, 104), h.world.get(e, components.Transform).?.position.x);
    // The old `step=2` field is still there (the reloaded start's step=999 never
    // ran), confirming instance state was not reset.
    try std.testing.expectEqual(@as(f64, 2), readSelfNumber(&h.b, self_ref, "step").?);
}

test "on_destroy fires once when the entity dies, before refs are released" {
    var h: Harness = undefined;
    try h.init(std.testing.allocator);
    defer h.deinit();

    const src =
        \\local M = {}
        \\function M:on_destroy()
        \\  destroy_count = (destroy_count or 0) + 1
        \\end
        \\return M
    ;
    const sid = try h.b.load("destroy.lua", src);
    const e = try h.world.spawn(.{components.Transform{ .position = .{ .x = 0, .y = 0 } }});
    try h.b.attach(e, sid);
    h.b.startAll();

    // Entity is alive: destroy_count not yet set.
    try std.testing.expect(readGlobalNumber(&h.b, "destroy_count") == null);

    // Despawn the entity; the behavior will be swept on the next sweep.
    _ = h.world.despawn(e);
    try std.testing.expect(readGlobalNumber(&h.b, "destroy_count") == null); // not yet

    // Sweep: on_destroy fires, then refs released.
    h.b.sweepDestroyed();
    try std.testing.expectEqual(@as(f64, 1), readGlobalNumber(&h.b, "destroy_count").?);

    // Second sweep does nothing (already destroyed).
    h.b.sweepDestroyed();
    try std.testing.expectEqual(@as(f64, 1), readGlobalNumber(&h.b, "destroy_count").?);
}

test "actor.translate binding works from Zig" {
    var h: Harness = undefined;
    try h.init(std.testing.allocator);
    defer h.deinit();

    const e = try h.world.spawn(.{components.Transform{ .position = .{ .x = 0, .y = 0 } }});
    const L = h.b.vm.state().?;

    // Build a `self` exactly the way `attach` does, then call the real
    // `actor.translate` binding through it: this exercises the whole
    // Lua -> binding -> entity -> world -> Transform path.
    _ = lua.lua_createtable(L, 0, 0); // [self]
    bindings.stampSelfEntity(L, e); // self.__entity = e (pops nothing)

    lua.getGlobal(L, "actor"); // [self, actor]
    lua.getField(L, -1, "translate"); // [self, actor, fn]
    lua.insert(L, -3); // [fn, self, actor]
    lua.pop(L, 1); // [fn, self]
    lua.pushF32(L, 5); // [fn, self, dx]
    lua.pushF32(L, 0); // [fn, self, dx, dy]
    try std.testing.expectEqual(@as(c_int, 0), lua.lua_pcall(L, 3, 0, 0));

    try std.testing.expectEqual(@as(f32, 5), h.world.get(e, components.Transform).?.position.x);
}

/// lives in the test frame, so the self-referential interior pointers stay valid.
const Harness = struct {
    world: World,
    input: script_Input,
    b: Behaviors,
    fn init(self: *Harness, a: std.mem.Allocator) !void {
        self.world = World.init(a);
        errdefer self.world.deinit();
        try self.world.reserveEntities(64);
        try self.world.reserveSignals(32);
        self.input = .{};
        self.input.define("jump");
        self.input.define("move_left");
        self.input.define("move_right");
        self.b = undefined;
        try self.b.init(a, &self.world, &self.input);
    }
    fn deinit(self: *Harness) void {
        self.b.deinit();
        self.world.deinit();
    }
};

const script_Input = @import("input.zig").Input;
