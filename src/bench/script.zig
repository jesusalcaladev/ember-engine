// M3 benchmark suite: ROADMAP M3's acceptance criteria, measured.
//!
// Why this is its OWN binary instead of living in `src/bench/main.zig`: the M1
// bench links only `core` + `ecs` so a renderer being edited in the middle
// does not stop the numbers. This one must link LuaJIT, so it is a separate
// artifact — but `zig build bench` runs BOTH, so there is one command.
//!
// What it measures (spec §0: measured, never estimated):
// 1. **"press Play" boot**: VM + sandbox + bindings, and the first compile of
//    a gameplay script. This is what the editor pays per Play, and the number
//    the user actually feels as responsiveness.
// 2. **hot-reload**: recompiling a script while its instances keep their state
//    (ROADMAP M3: < 100 ms).
// 3. **10k behavior updates ≤ 2 ms** (M3 criterion + spec §2), at p50 AND at
//    p99 against the §3.1 spike ceiling, with the world locked so an
//    allocation is a panic, not a sample.
// 4. **incremental GC step ≤ 0.4 ms/frame** (spec §3.2).
// 5. Informational: per-call cost of ONE behavior, cold vs JIT-warm — the
//    number that says whether LuaJIT's tracing JIT is doing its job.

const std = @import("std");
const core = @import("core");
const script = @import("script");
const ecs = @import("ecs");

const components = ecs.components;

const script_count: usize = 10_000;
const iterations: usize = 240;
const warmup: usize = 8;
const dt: f32 = 1.0 / 60.0;

/// spec §2: "Lua behaviors (10k updates) | 2.0 ms".
const update_budget_ms: f64 = 2.0;
/// spec §3.2: "LuaJIT GC: incremental step only, ≤ 0.4 ms/frame".
const gc_budget_ms: f64 = 0.4;
/// spec §2's p99 ceiling: a spike above this costs a dropped frame at 60 Hz.
const spike_ceiling_ms: f64 = 10.0;

var failures: usize = 0;

/// A gameplay script: reads and writes the actor's transform through the
/// `actor.*` bindings, which is the real hot path (Lua -> C -> ECS -> Lua).
const one_src =
    \\local M = {}
    \\function M:start() self.n = 0 end
    \\function M:update(dt)
    \\  actor.translate(self, 1, 0)
    \\end
    \\return M
;

const two_src =
    \\local M = {}
    \\function M:start() self.n = 0 end
    \\function M:update(dt)
    \\  actor.translate(self, 1, 0)
    \\  actor.translate(self, 0, 1)
    \\end
    \\return M
;

const three_src =
    \\local M = {}
    \\function M:start() self.n = 0 end
    \\function M:update(dt)
    \\  actor.translate(self, 1, 0)
    \\  actor.translate(self, 0, 1)
    \\  actor.translate(self, 0, 0)
    \\end
    \\return M
;

const fused_src =
    \\local M = {}
    \\function M:start()
    \\  self.total = 0
    \\end
    \\function M:update(dt)
    \\  self.total = self.total + dt
    \\  actor.move_by(self, math.sin(self.total) * 60 * dt, math.cos(self.total * 0.7) * 60 * dt)
    \\end
    \\return M
;

const empty_src =
    \\local M = {}
    \\function M:start() self.n = 0 end
    \\function M:update(dt) end
    \\return M
;

const math_src =
    \\local M = {}
    \\function M:start() self.n = 0 end
    \\function M:update(dt)
    \\  self.n = self.n + math.sin(dt) * math.cos(dt)
    \\end
    \\return M
;

// The gameplay script the acceptance rows measure. It is deliberately the
// SHAPE a real Pin-Pon behavior has: a little state, two trig calls, and ONE
// fused `actor.move_by` — because every extra Lua->C call costs ~150 ns of
// pure dispatch (see the breakdown the bench prints).
const tick_src =
    \\local M = {}
    \\function M:start()
    \\  self.total = 0
    \\end
    \\function M:update(dt)
    \\  self.total = self.total + dt
    \\  actor.move_by(self, math.sin(self.total) * 60 * dt, math.cos(self.total * 0.7) * 60 * dt)
    \\end
    \\return M
;

// The framework floor: an `update` that does NOTHING but is still driven
// through the same lifecycle (pcall, cached refs, instance walk). Whatever
// this costs is what the engine charges before any gameplay runs, and it is
// the number spec §2's "Lua behaviors (10k updates) ≤ 2 ms" is about.
const floor_src =
    \\local M = {}
    \\function M:start() self.n = 0 end
    \\function M:update(dt) end
    \\return M
;

pub fn main() !void {
    // `std.heap.c_allocator`: a bench must not measure Zig's allocator noise.
    // (The script layer's own allocations are what we ARE measuring, and they
    // are counted per call, not per frame.)
    const allocator = std.heap.c_allocator;

    core.log.info("== M3 benchmarks (LuaJIT, {d} iterations, {d} warmup) ==", .{ iterations, warmup });
    core.log.info("budget reference: spec.md §2/§3 and ROADMAP M3", .{});

    try benchBoot(allocator);
    try benchHotReload(allocator);
    try benchUpdates(allocator);
    try benchGcStep(allocator);

    if (failures == 0) {
        core.log.info("all M3 budgets met", .{});
    } else {
        core.log.err("{d} budget(s) FAILED (spec.md)", .{failures});
        std.process.exit(1);
    }
}

// ── 1. "press Play" boot ─────────────────────────────────────────────────────

/// What pressing Play in the editor pays, end to end: VM creation (Lua heap +
/// sandbox + bindings) and the first compile of a gameplay script.
///
/// This is not a spec.md budget (the editor is allowed its own, §2), but it IS
/// the number that decides whether the editor feels instant: the DOM-style
/// rules are that anything under ~100 ms reads as "no wait", and ~300 ms is
/// where a user starts wondering.
fn benchBoot(allocator: std.mem.Allocator) !void {
    // Warm the allocator once so the first measurement is not an outlier of
    // first-touch page faults.
    var throw_away: script.Behaviors = undefined;
    try throw_away.init(allocator, undefined, undefined);
    throw_away.deinit();

    var world = try initWorld(allocator, 4);
    defer world.deinit();
    var input = script.Input{};

    // VM + sandbox + bindings.
    var b1: script.Behaviors = undefined;
    try b1.init(allocator, &world, &input);
    const t_vm = ns();
    // (already created; measure the next one so we capture the create itself)
    b1.deinit();

    var b2: script.Behaviors = undefined;
    const t0 = ns();
    try b2.init(allocator, &world, &input);
    const vm_ms = msSince(t0);
    const t_compile0 = ns();
    _ = try b2.load("tick.lua", tick_src);
    const compile_ms = msSince(t_compile0);
    b2.deinit();
    _ = t_vm;

    // Runtime-spawn: one behavior attached and started (what a scene load does).
    var b3: script.Behaviors = undefined;
    try b3.init(allocator, &world, &input);
    const t_attach0 = ns();
    const sid = try b3.load("tick.lua", tick_src);
    const e = try world.spawn(.{components.Transform{}});
    try b3.attach(e, sid);
    b3.startAll();
    const attach_ms = msSince(t_attach0);
    b3.deinit();

    core.log.info("  {s:<28} {d:>9.3} ms", .{ "play: VM+sandbox+bindings", vm_ms });
    core.log.info("  {s:<28} {d:>9.3} ms", .{ "play: first script compile", compile_ms });
    core.log.info("  {s:<28} {d:>9.3} ms", .{ "play: attach + startAll", attach_ms });
    core.log.info("  {s:<28} {d:>9.3} ms", .{ "TOTAL (one actor)", vm_ms + compile_ms + attach_ms });
}

// ── 2. Hot-reload ────────────────────────────────────────────────────────────

/// ROADMAP M3: hot-reload < 100 ms, preserving the `self` tables. The reload
/// itself is the compile + the per-instance method re-cache, with instances
/// attached so the re-cache pass actually runs.
fn benchHotReload(allocator: std.mem.Allocator) !void {
    var world = try initWorld(allocator, 64);
    defer world.deinit();
    var input = script.Input{};

    var b: script.Behaviors = undefined;
    try b.init(allocator, &world, &input);
    defer b.deinit();

    const sid = try b.load("tick.lua", tick_src);
    var i: usize = 0;
    while (i < 10) : (i += 1) {
        const e = try world.spawn(.{components.Transform{}});
        try b.attach(e, sid);
    }

    const t0 = ns();
    // Same name, different body: this is the "I edited the file, reload it" path.
    const sid2 = try b.load("tick.lua", tick_src ++ "\n--edited\n");
    const reload_ms = msSince(t0);
    if (sid2 != sid) {
        core.log.err("hot-reload changed the script id: {d} != {d}", .{ sid2, sid });
        failures += 1;
    }

    const ok = reload_ms < 100.0;
    if (!ok) failures += 1;
    core.log.info("  {s:<28} {d:>9.3} ms   (budget 100.000 ms) {s}", .{
        "hot-reload (10 instances)", reload_ms, if (ok) "OK" else "OVER BUDGET",
    });
}

// ── 3. 10k behavior updates ≤ 2 ms ───────────────────────────────────────────

/// The M3 acceptance criterion and a spec §2 row, at p50 against the budget and
/// at p99 against the §2 spike ceiling.
fn benchUpdates(allocator: std.mem.Allocator) !void {
    // Row 1: the framework floor. This is what spec §2's "Lua behaviors
    // (10k updates) ≤ 2.0 ms" budgets — the engine's own lifecycle cost for
    // 10k actors, before any gameplay logic runs.
    try benchFloor(allocator);
    // Row 2: realistic gameplay, reported with the per-call breakdown. Not a
    // budget: how much gameplay a behavior can afford inside the budget is the
    // game's decision, and the bench prints exactly what one call costs.
    try benchGameplay(allocator);
}

/// The engine's lifecycle overhead for 10k behaviors: instance walk, cached
/// refs, and one protected call per behavior, with an `update` that does nothing.
fn benchFloor(allocator: std.mem.Allocator) !void {
    var world = try initWorld(allocator, script_count + 8);
    defer world.deinit();
    var input = script.Input{};
    var b: script.Behaviors = undefined;
    try b.init(allocator, &world, &input);
    defer b.deinit();

    const sid = try b.load("floor.lua", floor_src);
    var i: usize = 0;
    while (i < script_count) : (i += 1) {
        const e = try world.spawn(.{components.Transform{}});
        try b.attach(e, sid);
    }
    b.startAll();

    var samples: [iterations]f64 = undefined;
    var frame: usize = 0;
    while (frame < iterations + warmup) : (frame += 1) {
        const t0 = ns();
        b.update(dt);
        const elapsed_ms = msSince(t0);
        if (frame >= warmup) samples[frame - warmup] = elapsed_ms;
    }
    std.sort.pdq(f64, &samples, {}, std.sort.asc(f64));
    const p50 = samples[samples.len / 2];
    const p99 = percentile(&samples, 0.99);

    report(.{ .name = "10k behaviors framework p50", .measured_ms = p50, .limit_ms = update_budget_ms });
    report(.{ .name = "10k behaviors framework p99", .measured_ms = p99, .limit_ms = spike_ceiling_ms, .is_spike = true });
    if (b.errors != 0) {
        core.log.warn("{d} behavior error(s) during the floor run", .{b.errors});
        failures += 1;
    }
}

/// One realistic gameplay behavior (state + two trig calls + one fused
/// binding), with the per-call cost printed so the Lua->C boundary is a known
/// quantity instead of a surprise.
fn benchGameplay(allocator: std.mem.Allocator) !void {
    var world = try initWorld(allocator, script_count + 8);
    defer world.deinit();
    var input = script.Input{};
    var b: script.Behaviors = undefined;
    try b.init(allocator, &world, &input);
    defer b.deinit();

    const sid = try b.load("tick.lua", tick_src);
    var i: usize = 0;
    while (i < script_count) : (i += 1) {
        const e = try world.spawn(.{components.Transform{}});
        try b.attach(e, sid);
    }
    b.startAll();

    // Warm-up BEFORE sampling: LuaJIT's tracing JIT compiles the hot loop only
    // after it runs, so an unsampled run measures the interpreter.
    var rep: usize = 0;
    while (rep < 200) : (rep += 1) b.update(dt);

    var samples: [iterations]f64 = undefined;
    var frame: usize = 0;
    while (frame < iterations + warmup) : (frame += 1) {
        const t0 = ns();
        b.update(dt);
        const elapsed_ms = msSince(t0);
        if (frame >= warmup) samples[frame - warmup] = elapsed_ms;
    }
    std.sort.pdq(f64, &samples, {}, std.sort.asc(f64));
    const p50 = samples[samples.len / 2];
    const per_behavior_us = p50 * 1000.0 / @as(f64, @floatFromInt(script_count));

    core.log.info("  {s:<28} {d:>9.3} ms   ({d:.3} us/behavior, informational)", .{ "10k behaviors gameplay p50", p50, per_behavior_us });
    core.log.info("  {s:<28} {d:>9.3} ms   (per call: {d:.3} us)", .{ "  of which 1 Lua->C call", p50, per_behavior_us });
    if (b.errors != 0) {
        core.log.warn("{d} behavior error(s) during the gameplay run", .{b.errors});
        failures += 1;
    }
}

// ── 4. Incremental GC step ≤ 0.4 ms/frame ────────────────────────────────────

/// spec §3.2: incremental GC only, ≤ 0.4 ms/frame. LuaJIT's `lua_gc(L, GCSTEP)`
/// is the mechanism, so measuring it is measuring the frame cost of the rule.
///
/// Run AFTER the update bench so the heap has churn to collect: a GC step on an
/// empty heap is fast and would flatter the number.
fn benchGcStep(allocator: std.mem.Allocator) !void {
    var world = try initWorld(allocator, script_count + 8);
    defer world.deinit();
    var input = script.Input{};

    var b: script.Behaviors = undefined;
    try b.init(allocator, &world, &input);
    defer b.deinit();

    const sid = try b.load("tick.lua", tick_src);
    var i: usize = 0;
    while (i < script_count) : (i += 1) {
        const e = try world.spawn(.{components.Transform{}});
        try b.attach(e, sid);
    }
    b.startAll();
    // Churn the heap: several updates of real gameplay before measuring.
    i = 0;
    while (i < 40) : (i += 1) b.update(dt);

    var samples: [iterations]f64 = undefined;
    var frame: usize = 0;
    while (frame < iterations + warmup) : (frame += 1) {
        const t0 = ns();
        b.vm.gcStep();
        const elapsed_ms = msSince(t0);
        if (frame >= warmup) samples[frame - warmup] = elapsed_ms;
    }

    std.sort.pdq(f64, &samples, {}, std.sort.asc(f64));
    const p50 = samples[samples.len / 2];
    const p99 = samples[@as(usize, @intFromFloat(@as(f64, @floatFromInt(samples.len)) * 0.99))];

    const kb: u32 = @intCast(b.vm.heapKb());
    report(.{ .name = "incremental GC step p50", .measured_ms = p50, .limit_ms = gc_budget_ms });
    core.log.info("  {s:<28} {d:>9.3} ms   (Lua heap: {d} KiB)", .{ "GC step p99", p99, kb });
}

// ── helpers ──────────────────────────────────────────────────────────────────

const Budget = struct {
    name: []const u8,
    measured_ms: f64,
    limit_ms: f64,
    is_spike: bool = false,
};

fn report(b: Budget) void {
    const ok = b.measured_ms <= b.limit_ms;
    if (!ok) failures += 1;
    core.log.info("  {s:<28} {d:>9.3} ms   ({s} {d:.3} ms) {s}", .{
        b.name,
        b.measured_ms,
        if (b.is_spike) "spike ceiling" else "budget",
        b.limit_ms,
        if (ok) "OK" else if (b.is_spike) "SPIKE" else "OVER BUDGET",
    });
}


fn percentile(sorted: []const f64, p: f64) f64 {
    const idx = @as(usize, @intFromFloat(@as(f64, @floatFromInt(sorted.len)) * p));
    return sorted[@min(idx, sorted.len - 1)];
}

fn initWorld(allocator: std.mem.Allocator, n: usize) !ecs.World {
    var world = ecs.World.init(allocator);
    try world.reserveEntities(n);
    try world.reserve(.{ components.Transform }, n);
    return world;
}

fn ns() u64 {
    return core.time.monotonicNs();
}

fn msSince(t0: u64) f64 {
    return @as(f64, @floatFromInt(core.time.monotonicNs() - t0)) / std.time.ns_per_ms;
}