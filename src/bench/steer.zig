//! Measure the M4.5 steering + spatial path against spec §2.
//!
//! The design decision behind the accumulator was argued, not measured: "the
//! classic API is 4x over the 2.0 ms Lua budget", from spec §2's own figure of
//! 145 ns per Lua→C binding. This exists to turn that into a number — and, just
//! as importantly, to make sure the number is one that can be trusted.
//!
//! ## What made the first version of this lie
//!
//! It reported 2.39 ms, then 11.70 ms for the same work after an unrelated
//! edit. Three causes, all of which any timing harness in a managed runtime has
//! to handle and none of which the first version did:
//!
//! 1. **The collector ran inside the timed region.** LuaJIT steps its GC
//!    incrementally, and with a few thousand tables live a step lands wherever
//!    it lands. Here it is stopped explicitly around every timed section.
//! 2. **The JIT had not warmed up.** The first execution of a hot loop is
//!    interpreted and then traced; charging that to the measurement reports the
//!    cost of compilation, not of the code. There is now an explicit warm-up.
//! 3. **One sample per configuration.** Scheduling noise, page faults and the
//!    allocator land in a single sample. Every configuration is now run several
//!    times and the BEST is reported: the fastest run is the one least polluted
//!    by everything that is not the code under test.
//!
//! ## What is measured
//!
//! - **Pure Lua**: the accumulator with no engine calls at all. This is the
//!   floor the design was chosen for, and it is the number that decides whether
//!   the design is affordable.
//! - **Flock**: the three neighbour terms, which cost exactly ONE C crossing.
//!   Run twice: a spread population and the pathological dense cluster.
//! - **Classic shape**: the same neighbour work as one C call per term, which is
//!   what the accumulator replaced. The comparison the design rests on.
//!
//! Run with `zig build bench-steer`.

const std = @import("std");
const ecs = @import("ecs");
const script = @import("script");
const core_time = @import("core").time;

// Through the module, not by relative path: this file lives in `src/bench`, and
// the engine's script layer is only reachable as the `script` module.
const lua = script.luajit;
const vm_mod = script.vm;
const bindings = script.bindings;
const context_mod = script.context;
const statemachine = script.statemachine;
const spatial = script.spatial;
const steer = script.steer;

/// spec §2's Lua behavior row: 2.0 ms for 10k updates.
const budget_ms: f64 = 2.0;
/// spec §2's measured price of one Lua→C binding.
const binding_ns: f64 = 145.0;

const agents: i64 = 10_000;
/// Flocking is measured separately, at a population a game actually ships. It is
/// O(n x k) in the neighbourhood size by definition — every agent visits every
/// neighbour — so folding it into the 10k "behaviors" row of spec §2 would be
/// measuring a different workload under a budget that was not written for it.
const flock_agents: i64 = 500;
/// Timed runs per configuration. The best is reported; see the file header.
const trials: usize = 7;
/// Untimed runs before measuring, so the loop is traced and hot.
const warmups: usize = 3;

/// The population the neighbour queries run against.
const flock_size: usize = 2000;

// LuaJIT's `lua_gc` commands.
const LUA_GCSTOP: c_int = 1;
const LUA_GCRESTART: c_int = 2;

/// Pure-Lua accumulation: seek + arrive + apply, zero engine calls.
const script_pure =
    \\local N = _G.N
    \\-- One accumulator, reused: this is the intended usage. Creating one per
    \\-- agent per frame allocates a table and a metatable each time, which is
    \\-- both a spec §10 violation and, measured, roughly 4x slower.
    \\local acc = steer.at(0, 0)
    \\for i = 1, N do
    \\  acc:reset(0, 0)
    \\  acc:seek(100, 50, 1)
    \\  acc:arrive(10, 10, 5, 1)
    \\  acc:apply(120)
    \\end
    \\return true
;

/// A full flocking behaviour: seek + the three neighbour terms + apply. The
/// neighbour terms are the ONLY thing that reaches into C, and they do it once
/// per term through one shared accumulator.
///
/// The walk covers a wide lattice so a query sees a realistic handful of
/// neighbours; the dense case is measured separately as the worst case.
const script_flock =
    \\local N = _G.N
    \\local spread = _G.SPREAD
    \\local x, y = 0, 0
    \\local acc = steer.at(0, 0)
    \\for i = 1, N do
    \\  x = x + spread
    \\  if x > 1600 then x = 0; y = y + spread end
    \\  if y > 1600 then y = 0 end
    \\  acc:reset(x, y)
    \\  acc:seek(x + 100, y + 50, 1)
    \\  acc:separate(80, 1.5)
    \\  acc:align(80, 1.0)
    \\  acc:cohere(80, 0.7)
    \\  acc:apply(120)
    \\end
    \\return true
;

/// The classic shape: the same three neighbour terms as three separate C calls,
/// each doing its own query. This is the API the accumulator replaced, kept here
/// so the design claim is checked rather than asserted.
const script_classic =
    \\local N = _G.N
    \\local spread = _G.SPREAD
    \\local x, y = 0, 0
    \\local n = 0
    \\for i = 1, N do
    \\  x = x + spread
    \\  if x > 1600 then x = 0; y = y + spread end
    \\  if y > 1600 then y = 0 end
    \\  world.nearby(self, x, y, 80, function(o) n = n + 1 end)
    \\  world.nearby(self, x, y, 80, function(o) n = n + 1 end)
    \\  world.nearby(self, x, y, 80, function(o) n = n + 1 end)
    \\end
    \\return n >= 0
;

/// One measured configuration.
const Arm = struct {
    name: []const u8,
    note: []const u8,
    source: []const u8,
    spread: i64,
    /// Whether the grid is wired up (the pure-Lua arm never touches it).
    use_grid: bool,
    /// How many agents this arm runs. Defaults to the full population.
    population: i64 = agents,
};

const arms = [_]Arm{
    .{
        .name = "pure lua     ",
        .note = "seek + arrive + apply, 0 engine calls",
        .source = script_pure,
        .spread = 1,
        .use_grid = false,
    },
    .{
        .name = "flock spread ",
        .note = "3 neighbour terms, 1 C call, realistic density",
        .source = script_flock,
        .spread = 8,
        .use_grid = true,
        .population = flock_agents,
    },
    .{
        .name = "flock dense  ",
        .note = "same, worst case: dense cluster",
        .source = script_flock,
        .spread = 1,
        .use_grid = true,
        .population = flock_agents,
    },
    .{
        .name = "classic shape",
        .note = "3 separate C calls (the API this replaces)",
        .source = script_classic,
        .spread = 120,
        .use_grid = true,
    },
};

/// Everything a trial needs, built once so the JIT state and the Lua heap are
/// identical across trials — otherwise the first trial pays for the rest.
const Harness = struct {
    vm: vm_mod.Vm,
    reg: statemachine.Registry,
    grid: spatial.Grid,
    world: ecs.World,
    /// Lives here, not on the stack of `buildHarness`: every binding holds a
    /// pointer to it for as long as the VM is alive.
    input: context_mod.Input,
    chunk: [:0]const u8,

    fn deinit(self: *Harness) void {
        // Order matters: the registry holds refs into the VM, so it must go
        // first. Getting this backwards aborts inside LuaJIT.
        self.reg.deinit();
        self.grid.deinit();
        self.world.deinit();
        self.vm.deinit();
    }
};

fn buildHarness(allocator: std.mem.Allocator) !Harness {
    var h = Harness{
        .vm = try vm_mod.Vm.init(allocator),
        .reg = undefined,
        .grid = undefined,
        .world = ecs.World.init(allocator),
        .input = context_mod.Input{},
        .chunk = undefined,
    };
    errdefer h.vm.deinit();
    h.vm.sandbox();

    const L = h.vm.state().?;

    h.grid = try spatial.Grid.init(allocator, spatial.default_cell_size, spatial.default_extent, flock_size);
    h.reg = statemachine.Registry.init(allocator, &h.vm);

    // The input snapshot is a stub here: nothing in the measured arms reads it,
    // but the bindings close over the pointer and it must stay alive for the
    // harness's lifetime.
    h.input = context_mod.Input{};
    var ctx = bindings.Context.init(&h.world, &h.input);
    ctx.machines = &h.reg;
    ctx.spatial = &h.grid;
    bindings.registerAll(L, &ctx);

    // The population, on a wide lattice so a query sees a realistic
    // neighbourhood instead of the whole world.
    try h.world.reserveEntities(flock_size);
    var i: usize = 0;
    while (i < flock_size) : (i += 1) {
        _ = try h.world.spawn(.{ecs.components.Transform{ .position = .{
            .x = @as(f32, @floatFromInt(i % 100)) * 100,
            .y = @as(f32, @floatFromInt(i / 100)) * 100,
        } }});
    }
    h.grid.rebuild(&h.world);

    // A `self` table stamped with an entity, as the behavior layer does: the
    // classic arm calls `world.nearby(self, ...)`, which needs one to exclude.
    const first = h.world.entityAtSlot(0).?;
    lua.lua_createtable(L, 0, 0);
    bindings.stampEntityForTest(L, first);
    lua.setGlobal(L, "self");
    lua.pop(L, 1);

    // Publish the steering module.
    if (lua.luaL_loadbuffer(L, steer.source, steer.source.len, "@steer") != 0)
        return error.SteerCompilationFailed;
    if (lua.lua_pcall(L, 0, 1, 0) != 0) return error.SteerCompilationFailed;
    lua.setGlobal(L, "steer");

    return h;
}

/// Attaches one `self` table per entity, IN THIS VM. A registry ref means
/// nothing outside the VM that made it, which is the entire reason the registry
/// exists — so these cannot be built once and reused across harnesses.
/// Called once per trial so the refcount grows the same way every trial does.
fn attachSelfRefs(h: *Harness) void {
    const L = h.vm.state() orelse return;
    var i: usize = 0;
    while (i < h.grid.self_refs.len) : (i += 1) {
        h.grid.self_refs[i] = spatial.no_self_ref;
        if (!h.world.isAlive(.{ .index = @intCast(i), .generation = 0 })) continue;
        lua.lua_createtable(L, 0, 0);
        h.grid.self_refs[i] = @intCast(lua.luaL_ref(L, lua.REGISTRYINDEX));
    }
}

fn setGlobalInt(L: ?*lua.lua_State, name: [*:0]const u8, v: i64) void {
    lua.lua_pushinteger(L, v);
    lua.setGlobal(L, name);
}

/// Runs one trial with the collector stopped, returning elapsed ms.
fn trialOnce(h: *Harness, arm: Arm, n: i64) ?f64 {
    const L = h.vm.state() orelse return null;

    setGlobalInt(L, "N", n);
    setGlobalInt(L, "SPREAD", arm.spread);
    attachSelfRefs(h);

    if (lua.luaL_loadbuffer(L, arm.source.ptr, arm.source.len, "@bench") != 0) return null;

    // Stop the collector for the timed region only. A step landing inside the
    // loop was the single biggest source of variance in the first version.
    _ = lua.lua_gc(L, LUA_GCSTOP, 0);
    const start = core_time.clockGetTimeNs();
    const ok = lua.lua_pcall(L, 0, 1, 0);
    const elapsed = core_time.clockGetTimeNs() -| start;
    _ = lua.lua_gc(L, LUA_GCRESTART, 0);

    if (ok != 0) {
        std.debug.print("    (script raised: {s})\n", .{lua.toSlice(L, -1) orelse "?"});
        lua.pop(L, 1);
        return null;
    }
    lua.pop(L, 1);
    return @as(f64, @floatFromInt(elapsed)) / 1_000_000.0;
}

/// Compiles the arm's chunk into a fresh function each time, so the call does
/// not measure `loadbuffer`.
fn compileArm(h: *Harness, arm: Arm) bool {
    const L = h.vm.state() orelse return false;
    return lua.luaL_loadbuffer(L, arm.source.ptr, arm.source.len, "@bench") == 0;
}

/// Warms up, then measures `trials` times and returns the best in ms.
fn measure(h: *Harness, arm: Arm) ?f64 {
    const L = h.vm.state() orelse return null;
    if (!compileArm(h, arm)) return null;
    lua.pop(L, 1); // the prototype; each trial loads its own

    var best: f64 = std.math.floatMax(f64);
    var measured: usize = 0;

    // Warm-up: the loop must be TRACED before it is timed, or the first
    // measurement reports the cost of compiling it.
    var w: usize = 0;
    while (w < warmups) : (w += 1) {
        _ = trialOnce(h, arm, arm.population) orelse return null;
    }

    var t: usize = 0;
    while (t < trials) : (t += 1) {
        if (trialOnce(h, arm, arm.population)) |ms| {
            if (ms < best) best = ms;
            measured += 1;
        } else return null;
    }
    if (measured == 0) return null;
    return best;
}

pub fn main() !void {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var h = try buildHarness(allocator);
    defer h.deinit();

    std.debug.print("\n", .{});
    std.debug.print("  M4.5 steering — best of {d} timed runs, after {d} warm-ups\n", .{ trials, warmups });
    std.debug.print("  {d} agents, one behaviour each, per frame\n", .{agents});
    std.debug.print("  collector stopped during each timed region; LuaJIT, ReleaseSafe\n\n", .{});

    var pure_ms: f64 = 0;
    for (arms) |arm| {
        const ms = measure(&h, arm) orelse {
            std.debug.print("  {s}  FAILED TO RUN\n", .{arm.name});
            continue;
        };
        if (std.mem.eql(u8, arm.name, "pure lua     ")) pure_ms = ms;

        const per_agent = ms * 1_000_000.0 / @as(f64, @floatFromInt(arm.population));
        // The budget only applies to the behaviour row. A flock is a different
        // workload; printing an "x budget" figure for it would be dishonest.
        if (arm.population == agents) {
            std.debug.print("  {s}  {d:8.3} ms   {d:7.1} ns/agent   {d:5.2}x the {d:.1} ms row\n", .{
                arm.name, ms, per_agent, ms / budget_ms, budget_ms,
            });
        } else {
            std.debug.print("  {s}  {d:8.3} ms   {d:7.1} ns/agent   ({d} agents)\n", .{
                arm.name, ms, per_agent, arm.population,
            });
        }
        std.debug.print("               {s}\n", .{arm.note});
    }

    // The arithmetic the design decision rested on, checked against a measured
    // number rather than left as an assertion.
    std.debug.print("\n  cross-check against spec §2 ({d} ns per Lua→C binding):\n", .{binding_ns});
    const calls: f64 = 3.0;
    const predicted_ms = calls * binding_ns * @as(f64, @floatFromInt(agents)) / 1_000_000.0;
    std.debug.print("    3 C bindings x {d} agents predicts {d:.2} ms = {d:.1}x over budget\n", .{
        agents, predicted_ms, predicted_ms / budget_ms,
    });
    if (pure_ms > 0) {
        std.debug.print("    the accumulator makes 0 such calls; measured pure-Lua cost is {d:.3} ms\n", .{pure_ms});
        std.debug.print("    the flocking arms are what show whether that survives neighbours\n\n", .{});
    } else {
        std.debug.print("\n", .{});
    }
}
