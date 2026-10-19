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
const context = @import("context.zig");
const statemachine_mod = @import("statemachine.zig");
const tween_mod = @import("tween.zig");
const spatial_mod = @import("spatial.zig");
const steer_mod = @import("steer.zig");
const build_options = @import("options");
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
    // `lua.pop` is the wrapper over `lua_settop`; there is no `lua.setTop`
    // extern (this alias called one that never existed, which went unnoticed
    // while nothing used it).
    lua.pop(L, n);
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

/// One mounted GLOBAL script: the same lifecycle as a behavior, with no actor.
///
/// A global exists for everything gameplay that is not "one actor's logic" — a
/// game manager, the score, the spawn director, the game flow. It is a single
/// `self` table per script (one per name, the singleton rule), driven by the
/// same hooks (`start`, `update(dt)`, `fixed_update(dt)`,
/// `on_signal(name, payload)`) plus `on_destroy` when it is detached — never
/// swept, because nothing it belongs to can die.
///
/// It has no entity and stamps no `__entity` handle: `actor.*` on a global's
/// `self` is a caller mistake and fails the way "no entity" always fails, while
/// the world-level surfaces (`world.*`, `input.*`, `scene.*`, `globals.get`)
/// are exactly what a global is FOR. Behaviors reach its state through
/// `globals.get("name")`, which is the Lua singleton pattern.
const GlobalInstance = struct {
    /// The script this global serves. One global per script id — a second
    /// `attachGlobal` of the same id is an error, not a second instance.
    script_id: scripts_mod.ScriptId,
    /// Registry ref to this global's `self` table (never stamped with an
    /// entity — see the struct comment).
    self_ref: i32,
    /// 1-based index in the Lua side of the dense table the driver walks for
    /// globals (`globals[1..n]`), kept in step with the Zig array exactly like
    /// `Instance.lua_slot` is with `instances`.
    lua_slot: u32 = 0,
    /// Cached method refs (same set and shape as `Instance`'s; `no_ref` when
    /// the script does not define the hook).
    update_ref: i32 = no_ref,
    fixed_update_ref: i32 = no_ref,
    on_signal_ref: i32 = no_ref,
    on_destroy_ref: i32 = no_ref,
    /// True once `start` has run (idempotent, like a behavior's).
    started: bool = false,
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

/// The coroutine layer: `self:async(fn)` and the global `wait(seconds)`.
///
/// WHY IT IS ALL LUA: a coroutine that yields has to be resumed by someone, and
/// the natural someone is the script layer itself. A yield cannot cross the C
/// boundary of a `pcall` in plain Lua 5.1 — but this engine runs LuaJIT, whose
/// VM is fully resumable, and the whole scheme is easier to get right with the
/// resume loop in the same language as the code that yields.
///
/// The resume loop runs on the FIXED step, so a `wait(1.0)` is a second of
/// GAME time: it slows down with the global time scale and it replays
/// identically, which a frame-rate-dependent wait would not.
const coroutine_src =
    \\local M = {}
    \\local report = __behavior_error
    \\-- The coroutine list lives on the instance's own table, under a private
    \\-- key. It is per instance, so two actors never share a coroutine.
    \\local LIST = "__coroutines"
    \\-- The errors a coroutine raised since the last drive. The driver hands
    \\-- them to the engine so they land in the same counter the behaviors'
    \\-- errors do: a broken coroutine has to show up in the report.
    \\local pending_errors = 0
    \\-- Starts `fn` as a coroutine on this instance.
    \\--
    \\-- `fn` is called with the instance's `self` as its argument and may call
    \\-- the global `wait(seconds)` to pause. The coroutine is resumed by the
    \\-- engine's fixed step.
    \\function M.async(self, fn)
    \\  if type(fn) ~= "function" then
    \\    error("async expects a function", 2)
    \\  end
    \\  local list = self[LIST]
    \\  if list == nil then
    \\    list = {}
    \\    self[LIST] = list
    \\  end
    \\  local entry = { co = coroutine.create(fn), wait = 0, dead = false }
    \\  list[#list + 1] = entry
    \\  M.resume(self, entry)
    \\  return true
    \\end
    \\-- Resumes a coroutine once. A YIELD means "sleep this long"; a coroutine
    \\-- that ERRORED is reported and dropped, exactly like a broken behavior.
    \\function M.resume(self, entry)
    \\  local ok, value = coroutine.resume(entry.co, self)
    \\  if not ok then
    \\    if report ~= nil then report(self, value) end
    \\    entry.dead = true
    \\    pending_errors = pending_errors + 1
    \\    return
    \\  end
    \\  if coroutine.status(entry.co) == "dead" then
    \\    entry.dead = true
    \\    return
    \\  end
    \\  entry.wait = value or 0
    \\end
    \\-- Pauses the current coroutine for `seconds` of game time.
    \\--
    \\-- The method form, `self:wait(1.0)`, is what a script reaches for: it
    \\-- reads like the rest of the behavior API and it cannot be shadowed by
    \\-- an unrelated global. The global form, `wait(1.0)`, is the same
    \\-- function and exists because it is the spelling the roadmap names.
    \\function M.wait_self(self, seconds)
    \\  return M.wait(seconds)
    \\end
    \\-- Pauses the current coroutine for `seconds` of game time.
    \\function M.wait(seconds)
    \\  local _, is_main = coroutine.running()
    \\  if is_main then
    \\    error("wait() only works inside a coroutine: start one with self:async(function() ... end)", 2)
    \\  end
    \\  return coroutine.yield(seconds or 0)
    \\end
    \\-- Advances every coroutine of every instance by `dt`.
    \\function M.drive_co(insts, dt)
    \\  local n = #insts
    \\  local i = 1
    \\  while i <= n do
    \\    local inst = insts[i]
    \\    local list = inst[LIST]
    \\    if list ~= nil then
    \\      local k = #list
    \\      while k >= 1 do
    \\        local entry = list[k]
    \\        if entry.dead then
    \\          table.remove(list, k)
    \\        else
    \\          entry.wait = entry.wait - dt
    \\          if entry.wait <= 0 then
    \\            M.resume(inst, entry)
    \\            if entry.dead then table.remove(list, k) end
    \\          end
    \\        end
    \\        k = k - 1
    \\      end
    \\    end
    \\    i = i + 1
    \\  end
    \\  local errors = pending_errors
    \\  pending_errors = 0
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
    /// The state-machine registry (ROADMAP M4.5). Owned here rather than by the
    /// runtime because it holds Lua refs into `self.vm`: the registry must be
    /// destroyed before the VM, and this struct already owns that ordering.
    machines: statemachine_mod.Registry,
    /// The tween pool (M4.5 follow-up). Owned here for the same reason as
    /// `machines`: it holds Lua refs into `self.vm` (the completion callback)
    /// and it must be destroyed before the VM.
    ///
    /// It is a MANAGER and not a component because a tween is transient: it
    /// runs, it ends, it is gone. A component is the opposite — the document,
    /// serialized, surviving a save. A tween in a `.zson` file would be a
    /// tween that has already finished.
    tweens: tween_mod.Manager,
    /// The spatial grid behind `world.nearby` (ROADMAP M4.5), plus the steering
    /// module. Owned here for the same reason as `machines`.
    grid: spatial_mod.Grid,
    /// Registry ref of the steering module's `for` constructor.
    steer_ref: i32 = no_ref,
    /// The coroutine layer's `async` method, injected into every instance's
    /// `self` table so a script can start a coroutine: `self:async(fn)`.
    async_ref: i32 = no_ref,
    /// The coroutine layer's `wait` method, injected into every instance's
    /// `self` table: `self:wait(seconds)`.
    wait_ref: i32 = no_ref,
    /// The coroutine layer's resume loop, driven once per fixed step.
    co_driver_ref: i32 = no_ref,
    /// The mounted GLOBAL scripts (see `GlobalInstance`). Kept in a second
    /// dense array rather than mixed into `instances` on purpose: an actor
    /// lifecycle question (`world.isAlive`, the sweep) has a definite answer
    /// for a global — "always alive" — and folding that special case into the
    /// hot arrays would put a branch in every actor pass to serve at most a few
    /// dozen globals. The driver walks this array from its own Lua table, so
    /// the JIT-compiled loop pays nothing extra.
    globals: std.ArrayListUnmanaged(GlobalInstance) = .empty,
    /// Registry ref to the dense globals table the driver's second call
    /// iterates. Same lifetime discipline as `insts_table_ref`.
    globals_table_ref: i32 = no_ref,
    /// Storage for the hook vtable `ctx.globals` points at. A field and not an
    /// inline literal in `init` on purpose: `&self.globals_hooks` stays valid
    /// for the struct's lifetime (the rule `init`'s doc comment states), while
    /// a stack temporary would die at the end of `init` and hand the bindings
    /// a dangling context. Filled once in `init`, never again.
    globals_hooks: context.GlobalsHooks = .{
        .ctx = null,
        .push_self = pushGlobalSelf,
        .exists = globalExistsHook,
        .global_ref_of_self = globalRefOfSelfHook,
    },
    /// Per-frame counters for the acceptance report (M3 criteria).
    updates: u32 = 0,
    errors: u32 = 0,
    locked: bool = false,
    /// Registry ref to the dense `self` table the driver iterates, and to the
    /// driver function itself. Both live for the system's lifetime.
    insts_table_ref: i32 = no_ref,
    driver_ref: i32 = no_ref,

    pub const Error = error{ OutOfMemory, StateCreationFailed, DriverCompilationFailed, SteerCompilationFailed, GlobalAlreadyMounted } || vm_mod.Vm.Error || scripts_mod.Scripts.Error;

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
        self.* = Behaviors{ .vm = undefined, .scripts = undefined, .ctx = undefined, .allocator = allocator, .machines = undefined, .tweens = undefined, .grid = undefined, .steer_ref = no_ref };
        self.vm = try vm_mod.Vm.init(allocator);
        errdefer self.vm.deinit();
        self.vm.sandbox();
        // Before `ctx`: the context hands the machine registry to the `sm.*`
        // bindings as its upvalue, and the registry outlives both.
        self.machines = statemachine_mod.Registry.init(allocator, &self.vm);
        // The tween pool, same discipline: it holds Lua refs into the VM and
        // it writes into the world, so it is set up before the context points
        // the `tween.*` bindings at it.
        self.tweens = tween_mod.Manager.init(allocator, &self.vm);
        self.tweens.setWorld(world);
        // Sized from the world the caller already reserved, so the grid never
        // allocates while it is being filled (spec §10).
        self.grid = spatial_mod.Grid.init(allocator, spatial_mod.default_cell_size, spatial_mod.default_extent, world.slotCount()) catch {
            self.machines.deinit();
            self.vm.deinit();
            return error.OutOfMemory;
        };
        self.ctx = bindings.Context.init(world, input_snap);
        self.ctx.machines = &self.machines;
        self.ctx.tweens = &self.tweens;
        self.ctx.spatial = &self.grid;
        // The `globals.*` bindings reach the mounted globals through this
        // vtable, stored IN the struct (see the field's comment) and pointed at
        // the Behaviors the bindings' shared upvalue already reaches.
        self.globals_hooks.ctx = self;
        self.ctx.globals = &self.globals_hooks;
        bindings.registerAll(self.vm.state(), &self.ctx);
        if (build_options.steering) {
            self.buildSteer() catch |e| {
                self.machines.deinit();
                self.grid.deinit();
                self.vm.deinit();
                return e;
            };
        }
        self.scripts = scripts_mod.Scripts.init(&self.vm, allocator);
        self.buildDriver() catch |e| {
            self.scripts.deinit();
            self.vm.deinit();
            return e;
        };
    }

    /// Compiles the steering module and publishes it as the global `steer`.
    /// Built after `registerAll` because its neighbour terms call `world.nearby`
    /// and `actor.get_position`, which must already exist.
    fn buildSteer(self: *Behaviors) Error!void {
        const L = self.vm.state().?;
        if (lua.luaL_loadbuffer(L, steer_mod.source, steer_mod.source.len, "@steer") != 0)
            return error.SteerCompilationFailed;
        if (lua.lua_pcall(L, 0, 1, 0) != 0) return error.SteerCompilationFailed;
        // [module]
        // Publish the MODULE table (the stack top), so scripts get
        // `steer.at(...)` rather than a callable global.
        lua.setGlobal(L, steer_mod.global_name);
        // The module table itself has no reason to outlive this line: `at` is
        // the only entry point, and keeping it as a global is one less
        // reference the sandbox can mutate.
        lua.pop(L, 1);
    }

    /// Rebuilds the spatial grid and republishes each entity's `self` ref, so
    /// `world.nearby` can hand Lua a real `self` table.
    fn rebuildGrid(self: *Behaviors) void {
        self.grid.rebuild(self.ctx.world);
        // `self_refs` is indexed by entity slot; the instance array is dense and
        // small next to the slot space, so a linear pass over instances beats
        // any lookup structure here.
        for (self.instances.items) |inst| {
            if (!self.ctx.world.isAlive(inst.entity)) continue;
            if (inst.entity.index >= self.grid.self_refs.len) continue;
            self.grid.self_refs[inst.entity.index] = inst.self_ref;
        }
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

        // The globals' side of the driver: a second dense table, exactly the
        // same walk. Empty at init (globals mount after the driver is built —
        // a project's scripts are read from disk once the runtime is up).
        _ = lua.lua_createtable(L, 0, 0); // [globs]
        self.globals_table_ref = self.vm.refTop(); // ref + pop

        // Compile and keep the driver module's `drive` function.
        // The source is a comptime string: `loadbuffer` avoids the null-terminator copy.
        if (lua.luaL_loadbuffer(L, driver_src, driver_src.len, "@behavior_driver") != 0)
            return error.DriverCompilationFailed;
        // pcall it: the chunk returns the module table (needs the base/sandbox).
        if (lua.lua_pcall(L, 0, 1, 0) != 0) return error.DriverCompilationFailed;
        lua.getField(L, -1, "drive"); // [module, drive]
        // Keep `drive` (the top) and drop the module table under it.
        self.driver_ref = self.vm.refTop2();

        // The coroutine layer: the `async` method every instance carries, the
        // global `wait`, and the resume loop.
        if (lua.luaL_loadbuffer(L, coroutine_src, coroutine_src.len, "@behavior_coroutine") != 0)
            return error.DriverCompilationFailed;
        if (lua.lua_pcall(L, 0, 1, 0) != 0) return error.DriverCompilationFailed;
        // [module]
        lua.getField(L, -1, "async"); // [module, async]
        self.async_ref = self.vm.refTop(); // ref + pop
        lua.getField(L, -1, "wait_self"); // [module, wait_self]
        self.wait_ref = self.vm.refTop(); // ref + pop
        lua.getField(L, -1, "wait"); // [module, wait]
        lua.setGlobal(L, "wait"); // the global a coroutine calls to pause
        lua.getField(L, -1, "drive_co"); // [module, drive_co]
        self.co_driver_ref = self.vm.refTop2(); // keep it, drop the module
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
        // Globals: release every ref the same way, drop the dense table, and
        // free the array. There is no sweep for a global — `on_destroy` fires
        // from `detachGlobal` while the instance can still call out.
        for (self.globals.items) |*g| {
            self.vm.unref(g.self_ref);
            self.vm.unref(g.update_ref);
            self.vm.unref(g.fixed_update_ref);
            self.vm.unref(g.on_signal_ref);
            self.vm.unref(g.on_destroy_ref);
        }
        self.globals.deinit(self.allocator);
        if (self.driver_ref != no_ref) self.vm.unref(self.driver_ref);
        if (self.async_ref != no_ref) self.vm.unref(self.async_ref);
        if (self.wait_ref != no_ref) self.vm.unref(self.wait_ref);
        if (self.co_driver_ref != no_ref) self.vm.unref(self.co_driver_ref);
        if (self.insts_table_ref != no_ref) self.vm.unref(self.insts_table_ref);
        if (self.globals_table_ref != no_ref) self.vm.unref(self.globals_table_ref);
        // The spatial grid is allocated by `init` (a cell table plus the
        // self-ref array) and was never freed here: every `Behaviors` that was
        // torn down leaked its grid, which the test runner reports as one leak
        // per booted harness.
        self.grid.deinit();
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
        // A mounted global of the same script reloads with it too: the cache is
        // shared (a `.lua` file may serve an actor AND a global), so one reload
        // re-resolves both kinds of consumers.
        for (self.globals.items) |*g| {
            if (g.script_id != id) continue;
            self.cacheGlobalMethods(g);
        }
    }

    /// Hot-reloads a script by name, preserving every live instance's state.
    pub fn reload(self: *Behaviors, name: []const u8, source: []const u8) Error!void {
        const id = try self.scripts.reload(name, source);
        self.recacheInstancesOf(id);
    }

    // ── Global scripts (no actor) ────────────────────────────────────────────

    /// The number of mounted globals (diagnostics).
    pub fn globalCount(self: *const Behaviors) usize {
        return self.globals.items.len;
    }
    /// Loads a script as a GLOBAL: same shared cache as `load` (so one `.lua`
    /// file can serve actors and a global at once, and reloading the name
    /// updates every consumer), but does not mount anything — mount with
    /// `attachGlobal`. One global per script: `attachGlobal` rejects an id
    /// that is already mounted, and a second `loadGlobal` of the same name is
    /// simply a hot-reload like everywhere else in the cache.
    ///
    /// File reading and `.lua` validation are deliberately NOT here: `script`
    /// is its own build module and cannot import `assets` (the module graph
    /// refuses a file in two modules — the same wall the render/lighting
    /// comments document). The runtime and the editor read the file, validate
    /// it with `assets.script_asset.validate` and call this; the name they
    /// pass is the basename, so the Lua-side handle stays location-free.
    pub fn loadGlobal(self: *Behaviors, name: []const u8, source: []const u8) Error!scripts_mod.ScriptId {
        return self.load(name, source);
    }

    /// Mounts a global: one `self` table (no entity stamped), cached method
    /// refs, appended to the dense globals array and mirrors into the Lua-side
    /// table the driver walks. Load/spawn-time only (it allocates). Rejects an
    /// id that is already mounted — the singleton rule is enforced here, not
    /// left to the caller's discipline. NOT gated on `lock` on purpose: globals
    /// mount after the actor array is frozen (the config is read later than the
    /// sprites are reserved), and a few dozen globals are noise next to the
    /// ten-thousand array the lock exists to size.
    pub fn attachGlobal(self: *Behaviors, script_id: scripts_mod.ScriptId) Error!void {
        if (script_id >= self.scripts.entries.items.len) return error.LoadFailed;
        if (self.indexOfGlobal(script_id) != null) return error.GlobalAlreadyMounted;

        const L = self.vm.state().?;

        // 1. Fresh `self` with the shared metatable — and NO entity handle.
        //    That is the whole difference from a behavior: `actor.*` on this
        //    table resolves the same "absent handle" path as a self whose
        //    entity just died, which is the right failure for a global (it
        //    should be talking to `world.*`, not to an actor that does not
        //    belong to it).
        self.scripts.instantiate(script_id); // leaves `self` on top
        // The coroutine method, the same injection a behavior gets: a global
        // can sequence too (it just cannot touch an actor).
        if (self.async_ref != no_ref) {
            self.vm.pushRef(self.async_ref); // [self, async]
            lua.setField(L, -2, "async"); // self.async = async (pops async)
        }
        if (self.wait_ref != no_ref) {
            self.vm.pushRef(self.wait_ref); // [self, wait]
            lua.setField(L, -2, "wait"); // self.wait = wait (pops wait)
        }
        const self_ref = self.vm.refTop(); // ref + pop `self`

        // 2. Record the instance and resolve its cached method refs. From the
        //    first ref on, an OOM anywhere below must release all of them —
        //    the refs are the only resource here (the Lua mirror below cannot
        //    fail: `rawseti` never allocates).
        var g = GlobalInstance{
            .script_id = script_id,
            .self_ref = self_ref,
        };
        self.cacheGlobalMethods(&g);
        const slot: u32 = @intCast(self.globals.items.len + 1);
        g.lua_slot = slot;
        errdefer {
            self.vm.unref(g.update_ref);
            self.vm.unref(g.fixed_update_ref);
            self.vm.unref(g.on_signal_ref);
            self.vm.unref(g.on_destroy_ref);
            self.vm.unref(self_ref);
        }
        try self.globals.append(self.allocator, g);

        // Keep the Lua-side dense table in step: globals[slot] = self. Exactly
        // the mirror `attach` maintains for actors, so removeGlobalAt's
        // swap-fix has the same invariant to protect.
        self.vm.pushRef(self.globals_table_ref); // [globs]
        self.vm.pushRef(self_ref); // [globs, self]
        lua.lua_rawseti(L, -2, @intCast(slot)); // globs[slot] = self (pops self)
        lua.pop(L, 1); // []
    }

    /// Detaches the global named `name`: runs `on_destroy` if the script
    /// defines it (once, while the `self` table is still fully reachable),
    /// then releases every ref and removes it from both stores. Returns false
    /// when no global with that name is mounted — a no-op, the same silent
    /// contract `detach` has for actors.
    pub fn detachGlobal(self: *Behaviors, name: []const u8) bool {
        const id = self.scripts.idOf(name) orelse return false;
        const i = self.indexOfGlobal(id) orelse return false;
        const g = &self.globals.items[i];
        if (g.on_destroy_ref != no_ref) {
            self.vm.pushRef(g.on_destroy_ref); // [fn]
            self.vm.pushRef(g.self_ref); // [fn, self]
            self.callGlobalMethod(g, 1); // pcall(1): fn(self)
        }
        self.removeGlobalAt(i);
        return true;
    }

    /// The index in `globals` of the global bound to `script_id`, or null.
    /// Linear on purpose: a project mounts at most a few dozen globals, and a
    /// map would buy nothing but a second invariant to keep in step with a
    /// swap-remove (the exact bug class `removeInstanceAt` exists to close).
    fn indexOfGlobal(self: *const Behaviors, script_id: scripts_mod.ScriptId) ?usize {
        for (self.globals.items, 0..) |g, i| {
            if (g.script_id == script_id) return i;
        }
        return null;
    }

    /// Resolves and caches a global's lifecycle method refs off the shared
    /// prototype. Identical discipline to `cacheMethods` — same method names,
    /// same "never cache ONTO self" rule (an instance field would shadow the
    /// next reload) — over a GlobalInstance.
    fn cacheGlobalMethods(self: *Behaviors, g: *GlobalInstance) void {
        const L = self.vm.state().?;
        self.vm.pushRef(g.self_ref); // push self
        g.update_ref = self.refMethod(L, "update");
        g.fixed_update_ref = self.refMethod(L, "fixed_update");
        g.on_signal_ref = self.refMethod(L, "on_signal");
        g.on_destroy_ref = self.refMethod(L, "on_destroy");
        lua.pop(L, 1); // pop self
    }

    /// Removes the global at `i` and fixes BOTH stores — the Zig array
    /// (swap-remove) and the Lua dense table (move the last into the hole,
    /// clear the tail) — the mirrors of `removeInstanceAt`'s invariants, one
    /// desync of which silently drops or double-runs a global.
    fn removeGlobalAt(self: *Behaviors, i: usize) void {
        const g = self.globals.items[i];
        self.vm.unref(g.self_ref);
        self.vm.unref(g.update_ref);
        self.vm.unref(g.fixed_update_ref);
        self.vm.unref(g.on_signal_ref);
        self.vm.unref(g.on_destroy_ref);

        const L = self.vm.state().?;
        const last = self.globals.items.len;
        if (i + 1 != last) {
            const moved = &self.globals.items[last - 1];
            moved.lua_slot = g.lua_slot;
            self.vm.pushRef(self.globals_table_ref); // [globs]
            self.vm.pushRef(moved.self_ref); // [globs, self]
            lua.lua_rawseti(L, -2, @intCast(g.lua_slot)); // globs[hole] = last
            lua.pop(L, 1); // []
        }
        // Clear the tail so the driver's `#globs` shrinks with the array.
        self.vm.pushRef(self.globals_table_ref); // [globs]
        lua.pushNil(L); // [globs, nil]
        lua.lua_rawseti(L, -2, @intCast(last)); // globs[last] = nil
        lua.pop(L, 1); // []

        _ = self.globals.swapRemove(i);
    }

    /// The registry ref of a mounted global's `self` table (tests read state
    /// through it; the Lua surface reaches the same table via `globals.get`).
    pub fn globalSelfRef(self: *Behaviors, name: []const u8) ?i32 {
        const id = self.scripts.idOf(name) orelse return null;
        const i = self.indexOfGlobal(id) orelse return null;
        return self.globals.items[i].self_ref;
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
        // The coroutine method goes on the INSTANCE's table, so it is found
        // before the prototype's `__index` — a script that defines its own
        // `async` would be shadowed, which is why the name is documented as
        // the engine's.
        if (self.async_ref != no_ref) {
            self.vm.pushRef(self.async_ref); // [self, async]
            lua.setField(L, -2, "async"); // self.async = async (pops async)
        }
        if (self.wait_ref != no_ref) {
            self.vm.pushRef(self.wait_ref); // [self, wait]
            lua.setField(L, -2, "wait"); // self.wait = wait (pops wait)
        }
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
    ///
    /// Globals run FIRST: a global is higher-level state (the manager, the
    /// score) and a behavior's `start` may legitimately read
    /// `globals.get("game")` in the same call.
    pub fn startAll(self: *Behaviors) void {
        const L = self.vm.state().?;
        for (self.globals.items) |*g| {
            if (g.started) continue;
            g.started = true;
            // Resolved on demand, once per global — same choice `start` makes
            // for behaviors (it is not in the cached hot-path set).
            self.vm.pushRef(g.self_ref); // [self]
            lua.getField(L, -1, "start"); // [self, fn_or_nil]
            if (lua.isFunction(L, -1)) {
                self.vm.pushRef(g.self_ref); // [self, fn, self]
                self.callGlobalMethod(g, 1); // pcall(1): fn(self) -> [self]
            } else {
                lua.pop(L, 1); // [self]
            }
            lua.pop(L, 1); // []
        }
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
        // The state machines advance BEFORE the behaviors, and that order is the
        // contract: a state's `update` may call `sm_fire` or `sm_set_state`, and a
        // behavior's `update` reads `sm.state()`. Ticking machines first means a
        // behavior sees the state its machine just entered, rather than the one
        // it left last frame.
        // The flow counts too: it is a GLOBAL machine, and a game whose only
        // state machine is the flow has no entity bindings at all — so the
        // "are there any bindings" shortcut used to leave the flow frozen.
        if (self.machines.binding_count != 0 or self.machines.hasFlow()) self.machines.tick();
        // The grid is rebuilt AFTER the machines tick and BEFORE the behaviors
        // run: a machine that moved actors must be visible to the neighbours
        // those actors query this same frame, or the flock lags a frame behind.
        if (build_options.steering) self.rebuildGrid();
        const n = self.instances.items.len;
        const gn = self.globals.items.len;
        if ((n == 0 and gn == 0) or self.driver_ref == no_ref) {
            self.updates = @intCast(n + gn);
            return;
        }

        // Globals run FIRST on the same driver: a global's `update` sets the
        // shared state (score, spawn budget, game phase) that a behavior's
        // `update` may read one line later in the same frame. Two drive calls,
        // six C calls per frame — the per-instance cost is unchanged.
        if (gn != 0) self.driveTable(self.globals_table_ref, dt);
        // THREE C calls per FRAME instead of four per instance: push the
        // driver, push the dense `self` table, push dt — then one pcall. The
        // per-instance loop (and its own pcall) runs inside LuaJIT, where the
        // tracing JIT can compile it. See `driver_src` for the measurement that
        // justifies it.
        if (n != 0) self.driveTable(self.insts_table_ref, dt);
        self.updates = @intCast(n + gn);
    }

    /// Drives one dense table (`insts_table_ref` or `globals_table_ref`)
    /// through the Lua driver: push the driver, push the table, push dt, one
    /// pcall. The driver pcall-protects each instance inside the loop and
    /// returns its error count, which lands in `errors` exactly like a
    /// Zig-driven call's would. The driver failing ITSELF is an engine bug
    /// (its own errors are caught per instance inside), so it is reported
    /// loudly and the caller's pass simply ends.
    fn driveTable(self: *Behaviors, table_ref: i32, dt: f32) void {
        const state = self.vm.state() orelse return;
        self.vm.pushRef(self.driver_ref); // [drive]
        self.vm.pushRef(table_ref); // [drive, insts]
        lua.pushF32(state, dt); // [drive, insts, dt]
        if (lua.lua_pcall(state, 2, 1, 0) != 0) {
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

    /// Advances every live tween by `dt`.
    ///
    /// Called from the FIXED step, before the behaviors run, and that order is
    /// the contract: a script reads the tweened value in the same tick it was
    /// written, and a script that writes the property itself has the last word
    /// in that tick (the tween's next tick overwrites it).
    ///
    /// The fixed step and not the frame: a tween that ran on the variable dt
    /// would land on a different value every frame, and a game that replays
    /// would not replay the same animation.
    pub fn tickTweens(self: *Behaviors, dt: f32) void {
        self.tweens.tick(dt);
    }

    /// Runs `fixed_update(dt)` on every live instance, once per fixed 60 Hz tick.
    /// Same shape as `update`; kept separate so the runtime drives them from
    /// different points in the loop (spec §3.3: fixed sim, decoupled render).
    /// Globals run first, for the same reason `update` runs them first: the
    /// manager's decision this tick should be visible to every behavior that
    /// ticks after it.
    pub fn fixedUpdate(self: *Behaviors, dt: f32) void {
        const L = self.vm.state().?;
        for (self.globals.items) |*g| {
            if (g.fixed_update_ref == no_ref) continue;
            self.vm.pushRef(g.fixed_update_ref);
            self.vm.pushRef(g.self_ref);
            lua.pushF32(L, dt);
            self.callGlobalMethod(g, 2); // fn(self, dt)
        }
        for (self.instances.items) |*inst| {
            if (!inst.alive) continue;
            if (!self.ctx.world.isAlive(inst.entity)) continue; // sweep finalizes it
            if (inst.fixed_update_ref == no_ref) continue;
            self.vm.pushRef(inst.fixed_update_ref);
            self.vm.pushRef(inst.self_ref);
            lua.pushF32(L, dt);
            self.callMethod(inst, 2); // fn(self, dt)
        }
        // The coroutines advance on the FIXED step, after the behaviors: a
        // `wait(1.0)` is a second of game time, it slows down with the global
        // time scale, and it replays identically.
        if (self.co_driver_ref != no_ref) self.driveCoroutines(dt);
    }

    /// Advances every coroutine of every instance by `dt`.
    fn driveCoroutines(self: *Behaviors, dt: f32) void {
        const state = self.vm.state() orelse return;
        self.vm.pushRef(self.co_driver_ref); // [drive_co]
        self.vm.pushRef(self.insts_table_ref); // [drive_co, insts]
        lua.pushF32(state, dt); // [drive_co, insts, dt]
        if (lua.lua_pcall(state, 2, 1, 0) != 0) {
            self.errors += 1;
            var buf: [256]u8 = undefined;
            if (self.vm.readError(&buf)) |msg| {
                core_log.err("coroutine driver failed: {s}", .{msg});
            }
            return;
        }
        // The driver returns how many coroutines errored; `report` already
        // logged each one, so this is only the counter the report reads.
        if (lua.isNumber(state, -1)) {
            const reported: u64 = @intFromFloat(lua.lua_tonumber(state, -1));
            if (reported > 0) self.errors += @intCast(reported);
        }
        lua.pop(state, 1); // []
    }

    /// One field of a signal payload, as Lua sees it: a name and a value.
    ///
    /// The engine side stays POD (a union of scalars and one borrowed string),
    /// and building the Lua TABLE is this module's business — the runtime that
    /// emits `sound_finished` must not have to reach into `lua_State`.
    pub const PayloadField = struct {
        name: [*:0]const u8,
        value: Value,

        pub const Value = union(enum) {
            number: f64,
            integer: i64,
            boolean: bool,
            /// Borrowed for the duration of the call; copied into the VM.
            string: []const u8,
        };
    };

    /// Invokes `on_signal(name)` on every live instance that defines it. The
    /// runtime calls this from the signal drain so Lua handlers run in the same
    /// frame the signal fires, after the typed Zig listeners.
    pub fn dispatchSignal(self: *Behaviors, name: []const u8) void {
        self.dispatchSignalPayload(name, &.{});
    }

    /// `dispatchSignal` with a payload: `on_signal(name, payload)`.
    ///
    /// An EMPTY payload passes `nil` rather than an empty table, so a handler
    /// written as `function M:on_signal(name)` — every handler written before
    /// payloads existed — keeps working unchanged, and one that wants the fields
    /// gets them. The table is built on the Lua stack and never escapes the call.
    pub fn dispatchSignalPayload(self: *Behaviors, name: []const u8, payload: []const PayloadField) void {
        const L = self.vm.state().?;
        // Globals first: the manager hears the event before the actors do, the
        // same "higher level first" order `start`/`update`/`fixedUpdate` use.
        for (self.globals.items) |*g| {
            if (g.on_signal_ref == no_ref) continue;
            self.vm.pushRef(g.on_signal_ref); // [fn]
            self.vm.pushRef(g.self_ref); // [fn, self]
            lua.pushSlice(L, name); // [fn, self, name]
            if (payload.len == 0) {
                lua.pushNil(L); // [fn, self, name, nil]
            } else {
                lua.lua_createtable(L, 0, @intCast(payload.len));
                for (payload) |field| {
                    switch (field.value) {
                        .number => |v| lua.lua_pushnumber(L, v),
                        .integer => |v| lua.lua_pushinteger(L, v),
                        .boolean => |v| lua.lua_pushboolean(L, @intFromBool(v)),
                        .string => |v| lua.pushSlice(L, v),
                    }
                    lua.setField(L, -2, field.name); // pops the value
                }
            }
            self.callGlobalMethod(g, 3); // fn(self, name, payload)
        }
        for (self.instances.items) |*inst| {
            if (!inst.alive) continue;
            if (!self.ctx.world.isAlive(inst.entity)) continue;
            if (inst.on_signal_ref == no_ref) continue;
            self.vm.pushRef(inst.on_signal_ref); // [fn]
            self.vm.pushRef(inst.self_ref); // [fn, self]
            lua.pushSlice(L, name); // [fn, self, name]
            if (payload.len == 0) {
                lua.pushNil(L); // [fn, self, name, nil]
            } else {
                lua.lua_createtable(L, 0, @intCast(payload.len));
                for (payload) |field| {
                    switch (field.value) {
                        .number => |v| lua.lua_pushnumber(L, v),
                        .integer => |v| lua.lua_pushinteger(L, v),
                        .boolean => |v| lua.lua_pushboolean(L, @intFromBool(v)),
                        .string => |v| lua.pushSlice(L, v),
                    }
                    lua.setField(L, -2, field.name); // pops the value
                }
            }
            self.callMethod(inst, 3); // fn(self, name, payload)
        }
    }

    /// Invokes a NAMED method on every live instance of `script_id`: the target
    /// of an animation clip's M13 method track (`call_lua <t> <script_id> <fn>`).
    ///
    /// The clip carries only a script id and a function name, so an animator can
    /// hang a footstep sound off a keyframe without the engine knowing any
    /// script's name. Resolution is by name off the prototype, so a hot reload
    /// replaces the body with no re-attach, and an instance that does not define
    /// the method is SKIPPED rather than an error — one shared `run` clip may be
    /// used by characters only some of which handle a footstep. An id with no
    /// live instances is a no-op, which is the right answer for a clip that
    /// outlives the actor it was authored for.
    pub fn callMethodNamed(self: *Behaviors, script_id: u32, name: []const u8) void {
        if (name.len == 0) return;
        const L = self.vm.state() orelse return;
        for (self.instances.items) |*inst| {
            if (!inst.alive) continue;
            if (inst.script_id != script_id) continue;
            if (!self.ctx.world.isAlive(inst.entity)) continue;
            // [self] -> push the key -> gettable -> [fn_or_nil]. A dynamic key
            // needs gettable; getfield takes a NUL-terminated literal.
            self.vm.pushRef(inst.self_ref);
            lua.pushSlice(L, name);
            lua.lua_gettable(L, -2);
            if (!lua.isFunction(L, -1)) {
                lua_pop(L, 2); // drop the key and `self`
                continue;
            }
            self.vm.pushRef(inst.self_ref); // [fn, self]
            self.callMethod(inst, 1); // fn(self) -> []
        }
    }

    /// The animation system's `call_lua` hook, aimed at this behavior set.
    ///
    /// Built HERE and not in the runtime because the `script -> ecs` direction
    /// is the one that knows both types, so the erased-callback cast lives with
    /// the code it targets and a unit test can exercise the wiring without a
    /// window. The runtime's job is one line: `anim.method_hook =
    /// behaviors.animationMethodHook()`.
    pub fn animationMethodHook(self: *Behaviors) ecs.animation.MethodHook {
        return .{ .ctx = self, .call = struct {
            fn call_fn(ctx: ?*anyopaque, script_id: u32, name: []const u8) void {
                const b: *Behaviors = @ptrCast(@alignCast(ctx.?));
                b.callMethodNamed(script_id, name);
            }
        }.call_fn };
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

    /// `callMethod` for a GLOBAL: pcall-protected like everything else (a
    /// broken script is a logged line, never a dead frame), logged without an
    /// entity index because there is no entity — the name outlives the call
    /// site, which is what matters when someone greps the console.
    fn callGlobalMethod(self: *Behaviors, g: *GlobalInstance, nargs: c_int) void {
        const L = self.vm.state().?;
        if (lua.lua_pcall(L, nargs, 0, 0) != 0) {
            self.errors += 1;
            var buf: [256]u8 = undefined;
            if (self.vm.readError(&buf)) |msg| {
                core_log.err("global script {s}: {s}", .{ self.scripts.entries.items[g.script_id].name, msg });
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

// ── Globals hooks (the `globals.*` vtable) ──────────────────────────────────
// File-level because a function WITH an `anyopaque`-erased callback cannot be a
// struct method with a `*Behaviors` receiver without casting anyway — these
// cast once, immediately, and reach the rest through the real type.

/// `GlobalsHooks.push_self`: pushes the named global's `self` table; false (and
/// nothing pushed) when it is not mounted.
fn pushGlobalSelf(ctx: ?*anyopaque, L: ?*lua_State, name: []const u8) bool {
    const b: *Behaviors = @ptrCast(@alignCast(ctx orelse return false));
    _ = L;
    const id = b.scripts.idOf(name) orelse return false;
    const i = b.indexOfGlobal(id) orelse return false;
    b.vm.pushRef(b.globals.items[i].self_ref);
    return true;
}

/// `GlobalsHooks.exists`: a name counts only when its global is MOUNTED —
/// `globals.exists` answers "can I call this", not "does the file exist".
fn globalExistsHook(ctx: ?*anyopaque, name: []const u8) bool {
    const b: *Behaviors = @ptrCast(@alignCast(ctx orelse return false));
    const id = b.scripts.idOf(name) orelse return false;
    return b.indexOfGlobal(id) != null;
}

/// The registry ref of the global whose `self` table is the one at `idx`.
///
/// The table IDENTITY is what matches, not its contents: two globals can hold
/// equal tables, and the one that CALLS is the one the flow belongs to. The
/// comparison is a pointer compare, which is why the table is pushed first:
/// `lua_topointer` is the only way to ask "is this the same table".
fn globalRefOfSelfHook(ctx: ?*anyopaque, L: ?*lua_State, idx: c_int) i32 {
    const b: *Behaviors = @ptrCast(@alignCast(ctx orelse return statemachine_mod.no_ref));
    const want = lua.lua_topointer(L, idx) orelse return statemachine_mod.no_ref;
    for (b.globals.items) |*g| {
        if (g.self_ref == statemachine_mod.no_ref) continue;
        b.vm.pushRef(g.self_ref); // [table]
        const got = lua.lua_topointer(L, -1);
        lua.pop(L, 1); // []
        if (got != null and got == want) return g.self_ref;
    }
    return statemachine_mod.no_ref;
}

// ── The flow: the global state machine with a stack ─────────────────────────

const flow_global_src =
    \\local M = {}
    \\function M:start()
    \\  self.log = {}
    \\  flow.add_state(self, "menu", {
    \\    enter = function(self) table.insert(self.log, "enter:menu") end,
    \\  })
    \\  flow.add_state(self, "playing", {
    \\    enter = function(self) table.insert(self.log, "enter:playing") end,
    \\    exit = function(self) table.insert(self.log, "exit:playing") end,
    \\  })
    \\  flow.add_state(self, "paused", {
    \\    enter = function(self) table.insert(self.log, "enter:paused") end,
    \\  })
    \\  flow.add_transition(self, "menu", "start", "playing")
    \\  flow.set_initial(self, "menu")
    \\end
    \\function M:update(dt)
    \\  self.ticks = (self.ticks or 0) + 1
    \\  if self.ticks == 2 then flow.fire(self, "start") end
    \\end
    \\return M
;

test "the flow is a global machine with a stack of states" {
    var h: Harness = undefined;
    try h.init(std.testing.allocator);
    defer h.deinit();

    const gid = try h.b.loadGlobal("flow.lua", flow_global_src);
    try h.b.attachGlobal(gid);
    h.b.startAll();

    const self_ref = h.b.globalSelfRef("flow.lua").?;
    const reg = h.b.ctx.machines.?;

    // The flow starts in its initial state on its first tick, and the state's
    // `enter` ran.
    try std.testing.expect(reg.hasFlow());
    h.b.update(1.0 / 60.0);
    try std.testing.expectEqualStrings("menu", reg.flowStateName());
    try std.testing.expect(selfLogEntryIs(&h.b, self_ref, 0, "enter:menu"));

    // A transition REPLACES the whole stack: the phase changed. The event is
    // fired on the second update and applied on the third, because a
    // transition is applied at the TOP of the next tick.
    h.b.update(1.0 / 60.0); // the global's update fires the event
    h.b.update(1.0 / 60.0); // the machine's tick applies it
    try std.testing.expectEqualStrings("playing", reg.flowStateName());
    try std.testing.expect(selfLogEntryIs(&h.b, self_ref, 1, "enter:playing"));

    // A push LAYERS: the state below stays, and a pop returns to it.
    const paused = reg.stateIndex(reg.flow.machine, "paused").?;
    try std.testing.expect(reg.flowPush(paused));
    try std.testing.expectEqualStrings("paused", reg.flowStateName());
    try std.testing.expect(reg.flowIsIn("paused"));
    try std.testing.expect(reg.flowPop());
    try std.testing.expectEqualStrings("playing", reg.flowStateName());

    // The stack, bottom to top.
    var names: [statemachine_mod.max_stack][]const u8 = undefined;
    const n = reg.flowStackNames(&names);
    try std.testing.expectEqual(@as(usize, 1), n);
    try std.testing.expectEqualStrings("playing", names[0]);
}

test "the flow's callbacks run with the OWNING global's self" {
    var h: Harness = undefined;
    try h.init(std.testing.allocator);
    defer h.deinit();

    const gid = try h.b.loadGlobal("flow.lua", flow_global_src);
    try h.b.attachGlobal(gid);
    h.b.startAll();

    const self_ref = h.b.globalSelfRef("flow.lua").?;
    // The `enter` hook wrote to the global's own table — the flow's self IS
    // the global's, so a flow callback can read the game's state.
    h.b.update(1.0 / 60.0);
    try std.testing.expectEqual(@as(usize, 1), readSelfLogLength(&h.b, self_ref));
}

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

test "the tween pool is wired to the world and to the bindings" {
    var h: Harness = undefined;
    try h.init(std.testing.allocator);
    defer h.deinit();

    // The pool the `tween.*` bindings reach IS the behaviors' own pool, and
    // it writes into the behaviors' own world. A tween that drove a
    // different world would move nothing the renderer draws.
    const pool = h.b.ctx.tweens orelse return error.TestUnexpectedResult;
    try std.testing.expectEqual(@as(usize, @intFromPtr(&h.b.tweens)), @as(usize, @intFromPtr(pool)));

    const e = try h.world.spawn(.{components.Transform{ .position = .{ .x = 0, .y = 0 } }});
    const handle = pool.create(e, .position, .x, .{ .scalar = 100 }, 1.0, .{}) catch
        return error.TestUnexpectedResult;
    pool.tick(0.5);
    try std.testing.expectApproxEqAbs(@as(f32, 50), h.world.get(e, components.Transform).?.position.x, 0.001);
    pool.tick(0.5);
    try std.testing.expectApproxEqAbs(@as(f32, 100), h.world.get(e, components.Transform).?.position.x, 0.001);
    try std.testing.expect(!pool.isAlive(handle));
}

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

const payload_src =
    \\local M = {}
    \\function M:on_signal(name, payload)
    \\  self.last_signal = name
    \\  if payload then
    \\    self.slot = payload.slot
    \\    self.tick = payload.tick
    \\    self.loop_n = payload.loop and 1 or 0
    \\    self.path = payload.path
    \\  else
    \\    self.slot = -1
    \\  end
    \\end
    \\return M
;

test "on_signal receives the payload as a table, and nil when there is none" {
    var h: Harness = undefined;
    try h.init(std.testing.allocator);
    defer h.deinit();

    const sid = try h.b.load("payload.lua", payload_src);
    const e = try h.world.spawn(.{components.Transform{ .position = .{ .x = 0, .y = 0 } }});
    try h.b.attach(e, sid);
    h.b.startAll();
    const self_ref = h.b.instances.items[0].self_ref;

    // No payload: `nil`, not an empty table — the handler above takes a
    // two-argument `on_signal` and must keep working with one.
    h.b.dispatchSignal("hit");
    try std.testing.expectEqualStrings("hit", readSelfString(&h.b, self_ref, "last_signal").?);
    try std.testing.expectEqual(@as(f64, -1), readSelfNumber(&h.b, self_ref, "slot").?);

    // With one: exactly the fields handed over, each in its own Lua type.
    const fields = [_]Behaviors.PayloadField{
        .{ .name = "slot", .value = .{ .integer = 3 } },
        .{ .name = "tick", .value = .{ .integer = 41 } },
        .{ .name = "loop", .value = .{ .boolean = true } },
        .{ .name = "path", .value = .{ .string = "boom.wav" } },
    };
    h.b.dispatchSignalPayload("sound_finished", &fields);
    try std.testing.expectEqualStrings("sound_finished", readSelfString(&h.b, self_ref, "last_signal").?);
    try std.testing.expectEqual(@as(f64, 3), readSelfNumber(&h.b, self_ref, "slot").?);
    try std.testing.expectEqual(@as(f64, 41), readSelfNumber(&h.b, self_ref, "tick").?);
    try std.testing.expectEqual(@as(f64, 1), readSelfNumber(&h.b, self_ref, "loop_n").?);
    try std.testing.expectEqualStrings("boom.wav", readSelfString(&h.b, self_ref, "path").?);
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

// ── Global scripts (no actor, singleton access) ─────────────────────────────

const manager_src =
    \\local M = {}
    \\M.phase = "menu"
    \\function M:start()
    \\  self.score = 0
    \\  self.ticks = 0
    \\end
    \\function M:update(dt)
    \\  self.ticks = self.ticks + 1
    \\  changed = self.phase  -- a global the tests read (survives the call)
    \\end
    \\function M:fixed_update(dt)
    \\  self.fixed_ticks = (self.fixed_ticks or 0) + 1
    \\end
    \\function M:on_signal(name, payload)
    \\  self.last_signal = name
    \\  if payload then self.slot = payload.slot end
    \\end
    \\function M:on_destroy()
    \\  destroy_count = (destroy_count or 0) + 1
    \\end
    \\return M
;

test "a global script runs start/update/fixed_update with no entity" {
    var h: Harness = undefined;
    try h.init(std.testing.allocator);
    defer h.deinit();

    const sid = try h.b.loadGlobal("manager.lua", manager_src);
    try h.b.attachGlobal(sid);
    h.b.startAll();

    // The self table exists, carries NO entity handle, and start seeded it.
    const self_ref = h.b.globalSelfRef("manager.lua").?;
    try std.testing.expectEqual(@as(f64, 0), readSelfNumber(&h.b, self_ref, "score").?);

    h.b.fixedUpdate(1.0 / 60.0);
    h.b.update(1.0 / 60.0);
    try std.testing.expectEqual(@as(f64, 1), readSelfNumber(&h.b, self_ref, "ticks").?);
    try std.testing.expectEqual(@as(f64, 1), readSelfNumber(&h.b, self_ref, "fixed_ticks").?);
    // Counts: one global, no behaviors.
    try std.testing.expectEqual(@as(usize, 1), h.b.globalCount());
    try std.testing.expectEqual(@as(u32, 1), h.b.updates);
    try std.testing.expectEqual(@as(usize, 0), h.b.instanceCount());
}

test "a global's update runs before behaviors: visible the same frame" {
    var h: Harness = undefined;
    try h.init(std.testing.allocator);
    defer h.deinit();

    const gid = try h.b.loadGlobal("manager.lua", manager_src);
    try h.b.attachGlobal(gid);

    const sid = try h.b.load("read_global.lua",
        \\local M = {}
        \\function M:update(dt)
        \\  local g = globals.get("manager.lua")
        \\  if g then self.seen = g.ticks or 0 end
        \\end
        \\return M
    );
    const e = try h.world.spawn(.{components.Transform{}});
    try h.b.attach(e, sid);
    h.b.startAll();

    // One update: the global's `update` ran FIRST (ticks 0 -> 1) and the actor
    // saw the post-global value, not the one the global started the frame with.
    h.b.update(1.0 / 60.0);
    const g_self = h.b.globalSelfRef("manager.lua").?;
    try std.testing.expectEqual(@as(f64, 1), readSelfNumber(&h.b, g_self, "ticks").?);
    const a_self = h.b.instances.items[0].self_ref;
    try std.testing.expectEqual(@as(f64, 1), readSelfNumber(&h.b, a_self, "seen").?);
}

test "hot-reload of a global preserves self state and swaps methods" {
    var h: Harness = undefined;
    try h.init(std.testing.allocator);
    defer h.deinit();

    const sid = try h.b.loadGlobal("manager.lua", manager_src);
    try h.b.attachGlobal(sid);
    h.b.startAll();
    h.b.update(1.0 / 60.0); // ticks = 1
    const self_ref = h.b.globalSelfRef("manager.lua").?;

    // Reload: same name through the SHARED cache (a .lua can serve an actor and
    // a global), new body. The old `changed` global stays untouched — the new
    // update only renames the counter.
    const sid2 = try h.b.loadGlobal("manager.lua",
        \\local M = {}
        \\function M:update(dt)
        \\  self.ticks = self.ticks + 10
        \\end
        \\return M
    );
    try std.testing.expectEqual(sid, sid2);

    h.b.update(1.0 / 60.0); // ticks = 1 + 10 (state survived, method swapped)
    try std.testing.expectEqual(@as(f64, 11), readSelfNumber(&h.b, self_ref, "ticks").?);
}

test "signals reach a global's on_signal, payload included" {
    var h: Harness = undefined;
    try h.init(std.testing.allocator);
    defer h.deinit();

    const sid = try h.b.loadGlobal("manager.lua", manager_src);
    try h.b.attachGlobal(sid);
    h.b.startAll();

    h.b.dispatchSignal("hit");
    const self_ref = h.b.globalSelfRef("manager.lua").?;
    try std.testing.expectEqualStrings("hit", readSelfString(&h.b, self_ref, "last_signal").?);
    try std.testing.expect(readSelfNumber(&h.b, self_ref, "slot") == null); // nil payload

    const fields = [_]Behaviors.PayloadField{
        .{ .name = "slot", .value = .{ .integer = 7 } },
    };
    h.b.dispatchSignalPayload("level_cleared", &fields);
    try std.testing.expectEqualStrings("level_cleared", readSelfString(&h.b, self_ref, "last_signal").?);
    try std.testing.expectEqual(@as(f64, 7), readSelfNumber(&h.b, self_ref, "slot").?);
}

test "one global per script: re-attach is an error, re-load is a hot-reload" {
    var h: Harness = undefined;
    try h.init(std.testing.allocator);
    defer h.deinit();

    const sid = try h.b.loadGlobal("manager.lua", manager_src);
    try h.b.attachGlobal(sid);
    // The singleton rule is enforced: a second mount of the SAME id is an
    // error, not a second hidden instance whose update would double-run.
    try std.testing.expectError(error.GlobalAlreadyMounted, h.b.attachGlobal(sid));
    // A second loadGlobal of the same name is the usual hot-reload path.
    const sid2 = try h.b.loadGlobal("manager.lua", manager_src);
    try std.testing.expectEqual(sid, sid2);
    try std.testing.expectEqual(@as(usize, 1), h.b.globalCount());
}

test "detachGlobal fires on_destroy once and removes the global" {
    var h: Harness = undefined;
    try h.init(std.testing.allocator);
    defer h.deinit();

    const sid = try h.b.loadGlobal("manager.lua", manager_src);
    try h.b.attachGlobal(sid);
    h.b.startAll();
    try std.testing.expect(readGlobalNumber(&h.b, "destroy_count") == null);

    try std.testing.expect(h.b.detachGlobal("manager.lua"));
    try std.testing.expectEqual(@as(f64, 1), readGlobalNumber(&h.b, "destroy_count"));
    try std.testing.expectEqual(@as(usize, 0), h.b.globalCount());
    try std.testing.expect(h.b.globalSelfRef("manager.lua") == null);

    // Detaching twice is a silent no-op (and on_destroy did not re-fire).
    try std.testing.expect(!h.b.detachGlobal("manager.lua"));
    try std.testing.expectEqual(@as(f64, 1), readGlobalNumber(&h.b, "destroy_count"));
}

test "globals.get/exist bindings reach a global from Lua; unknown names return nil/false" {
    var h: Harness = undefined;
    try h.init(std.testing.allocator);
    defer h.deinit();

    const sid = try h.b.loadGlobal("manager.lua", manager_src);
    try h.b.attachGlobal(sid);
    h.b.startAll();

    // From real Lua, through the real bindings: read a field, call a method on
    // the global's self, and check the negative paths for an unknown name.
    const ok = runChunkBool(&h.b,
        \\local g = globals.get("manager.lua")
        \\if not g or g.score ~= 0 then return false end
        \\g.score = 99
        \\if globals.get("nope.lua") ~= nil then return false end
        \\if globals.exists("nope.lua") then return false end
        \\return globals.exists("manager.lua") and globals.get("manager.lua").score == 99
    );
    try std.testing.expect(ok);
}

/// Runs a Lua chunk in the harness VM and returns its truthiness. The
/// globals-binding probe compiles real Lua through the real sandbox, so the
/// test exercises the registered C functions, not a Zig-side stand-in.
fn runChunkBool(b: *Behaviors, comptime src: []const u8) bool {
    const L = b.vm.state() orelse return false;
    b.vm.loadBuffer(src, "@globals_probe") catch |e| {
        std.debug.print("  globals probe loadBuffer failed: {s}\n", .{@errorName(e)});
        return false;
    };
    if (lua.lua_pcall(L, 0, 1, 0) != 0) {
        var buf: [256]u8 = undefined;
        if (b.vm.readError(&buf)) |msg| std.debug.print("  globals probe lua error: {s}\n", .{msg});
        lua.pop(L, 1); // drop the error message, the stack starts clean again
        return false;
    }
    const ok = lua.toBool(L, -1);
    lua.pop(L, 1);
    return ok;
}

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

// ── Coroutines: `self:async(fn)` and the global `wait(seconds)` ─────────────

const coroutine_script_src =
    \\local M = {}
    \\function M:start()
    \\  self.log = {}
    \\  self:async(function(self)
    \\    table.insert(self.log, "a")
    \\    wait(0.5)
    \\    table.insert(self.log, "b")
    \\    wait(0.5)
    \\    table.insert(self.log, "c")
    \\  end)
    \\end
    \\return M
;

const coroutine_broken_src =
    \\local M = {}
    \\function M:start()
    \\  self:async(function(self)
    \\    error("the coroutine exploded")
    \\  end)
    \\end
    \\return M
;

test "a coroutine runs, waits, and resumes on the fixed step" {
    var h: Harness = undefined;
    try h.init(std.testing.allocator);
    defer h.deinit();

    const sid = try h.b.load("coroutine.lua", coroutine_script_src);
    const e = try h.world.spawn(.{components.Transform{}});
    try h.b.attach(e, sid);
    h.b.startAll();

    // The coroutine starts immediately and runs until its first `wait`.
    const self_ref = h.b.instances.items[0].self_ref;
    try std.testing.expectEqual(@as(usize, 1), readSelfLogLength(&h.b, self_ref));
    try std.testing.expect(selfLogEntryIs(&h.b, self_ref, 0, "a"));

    // Half a second of fixed steps: still waiting.
    var i: usize = 0;
    while (i < 29) : (i += 1) h.b.fixedUpdate(1.0 / 60.0);
    try std.testing.expectEqual(@as(usize, 1), readSelfLogLength(&h.b, self_ref));

    // One more step crosses the half second: the coroutine resumes.
    h.b.fixedUpdate(1.0 / 60.0);
    try std.testing.expectEqual(@as(usize, 2), readSelfLogLength(&h.b, self_ref));
    try std.testing.expect(selfLogEntryIs(&h.b, self_ref, 1, "b"));

    // And the second wait.
    i = 0;
    while (i < 30) : (i += 1) h.b.fixedUpdate(1.0 / 60.0);
    try std.testing.expectEqual(@as(usize, 3), readSelfLogLength(&h.b, self_ref));
    try std.testing.expect(selfLogEntryIs(&h.b, self_ref, 2, "c"));
}

test "a coroutine that errors is reported, not fatal" {
    var h: Harness = undefined;
    try h.init(std.testing.allocator);
    defer h.deinit();

    const sid = try h.b.load("coroutine_broken.lua", coroutine_broken_src);
    const e = try h.world.spawn(.{components.Transform{}});
    try h.b.attach(e, sid);

    // The error happens inside the coroutine, at its FIRST resume — which is
    // when `start` starts it. The frame survives it: a broken coroutine is a
    // logged error, like a broken behavior.
    const before = h.b.errors;
    h.b.startAll();

    // The count lands on the next drive, the same place a behavior's errors
    // land: the driver is what reports them.
    h.b.fixedUpdate(1.0 / 60.0);
    try std.testing.expect(h.b.errors > before);

    // And the frame after that is unaffected: the dead coroutine is dropped,
    // not resumed again.
    const after = h.b.errors;
    h.b.fixedUpdate(1.0 / 60.0);
    try std.testing.expectEqual(after, h.b.errors);
}

/// The number of entries in the instance's `self.log`.
fn readSelfLogLength(b: *Behaviors, self_ref: i32) usize {
    const L = b.vm.state().?;
    b.vm.pushRef(self_ref); // [self]
    lua.getField(L, -1, "log"); // [self, log]
    const n = lua.lua_objlen(L, -1);
    lua.pop(L, 2); // []
    return n;
}

/// Whether the `index`-th entry of the instance's `self.log` is `expected`.
/// Compared in place: the string belongs to the Lua heap and copying it out
/// would leak it.
fn selfLogEntryIs(b: *Behaviors, self_ref: i32, index: usize, expected: []const u8) bool {
    const L = b.vm.state().?;
    b.vm.pushRef(self_ref); // [self]
    lua.getField(L, -1, "log"); // [self, log]
    lua.lua_rawgeti(L, -1, @intCast(index + 1)); // [self, log, entry]
    const ok = std.mem.eql(u8, lua.toString(L, -1), expected);
    lua.pop(L, 3); // []
    return ok;
}

// ── M13 method track: `call_lua(script_id, fn)` ─────────────────────────────

const footstep_src =
    \\local M = {}
    \\function M:on_footstep()
    \\  self.steps = (self.steps or 0) + 1
    \\end
    \\return M
;

// A second script that does NOT define `on_footstep`: a shared clip may be used
// by characters only some of which handle a footstep, and that must be skipped,
// not an error.
const quiet_src =
    \\local M = {}
    \\function M:update(dt)
    \\end
    \\return M
;

test "a call_lua method reaches only the named script's instances" {
    var h: Harness = undefined;
    try h.init(std.testing.allocator);
    defer h.deinit();

    const speaker = try h.b.load("step.lua", footstep_src);
    const quiet = try h.b.load("quiet.lua", quiet_src);
    const e1 = try h.world.spawn(.{components.Transform{}});
    const e2 = try h.world.spawn(.{components.Transform{}});
    try h.b.attach(e1, speaker);
    try h.b.attach(e2, quiet);
    h.b.startAll();

    // The runtime's wiring, not a stand-in: the hook the animation system holds
    // is built by the helper `main.zig` calls.
    const hook = h.b.animationMethodHook();
    const call = hook.call.?;

    // Targeting the speaker's id calls it once on the speaker...
    call(hook.ctx, speaker, "on_footstep");
    try std.testing.expectEqual(@as(f64, 1), readSelfNumber(&h.b, h.b.instances.items[0].self_ref, "steps").?);
    // ...and not on the quiet instance (no method of that name).
    try std.testing.expect(readSelfNumber(&h.b, h.b.instances.items[1].self_ref, "steps") == null);

    // Targeting an id with no live instances is a no-op, not a crash: a clip can
    // outlive the actor it was authored for.
    call(hook.ctx, 999_999, "on_footstep");
    // A method the instance does not define is skipped silently, which is what
    // makes one shared `run` clip usable by characters that handle different
    // events.
    call(hook.ctx, quiet, "on_footstep");
    call(hook.ctx, speaker, "on_no_such_method");
    try std.testing.expectEqual(@as(usize, 0), h.b.errors);

    // A second step on the speaker is the second call, so events accumulate the
    // way a looping walk cycle needs.
    call(hook.ctx, speaker, "on_footstep");
    try std.testing.expectEqual(@as(f64, 2), readSelfNumber(&h.b, h.b.instances.items[0].self_ref, "steps").?);
}
