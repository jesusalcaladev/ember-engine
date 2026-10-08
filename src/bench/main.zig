//! M1 benchmark suite: the acceptance criteria of ROADMAP M1, in numbers.
//!
//! Usage: `zig build bench` (headless, exits after reporting)
//!
//! What it measures and against what (spec.md is law):
//! 1. **100k actors with updated transforms ≤ 2 ms** (M1 criterion #1).
//! 2. **10k parent/child entities with no frame spikes** (M1 criterion #3).
//! 3. **save→load reproduces an identical hash** (M1 criterion #2).
//! 4. Informational: structural churn (spawn + add + remove + despawn).
//!
//! Every number is measured, not estimated (spec §0): the frame loop runs with
//! the world's growth locked, so an allocation here is a panic, not a sample.

// Headless on purpose: the bench links `core` and `ecs` directly, so a renderer
// being edited in the middle does not stop the numbers from being measured.
const std = @import("std");
const core = @import("core");
const ecs = @import("ecs");

const components = ecs.components;
const World = ecs.World;

const transforms_count: usize = 100_000;
const hierarchy_count: usize = 10_000;
const scene_count: usize = 1_000;
const structural_count: usize = 10_000;
const iterations: usize = 240; // frames simulated per measurement
const warmup: usize = 8;

/// Seconds per simulated frame (60 Hz, like the real loop).
const dt: f32 = 1.0 / 60.0;

/// Spike ceiling from spec §2: a p99 above this would cost a dropped frame.
const spike_limit_ms: f64 = 10.0;

const Budget = struct {
    name: []const u8,
    measured_ms: f64,
    limit_ms: f64,
};

var failures: usize = 0;

/// Steady-state measurement against a budget: the ROADMAP criteria are
/// per-frame costs, so they are checked at p50 like spec §2 does.
fn report(b: Budget) void {
    const ok = b.measured_ms <= b.limit_ms;
    if (!ok) failures += 1;
    core.log.info("  {s:<28} {d:>9.3} ms   (budget {d:.3} ms) {s}", .{
        b.name, b.measured_ms, b.limit_ms, if (ok) "OK" else "OVER BUDGET",
    });
}

/// Tail measurement: not a budget by itself, but a spike above the §2 p99
/// ceiling would mean dropped frames at 60 Hz, so it still gates the run.
fn reportSpike(b: Budget) void {
    const ok = b.measured_ms <= b.limit_ms;
    if (!ok) failures += 1;
    core.log.info("  {s:<28} {d:>9.3} ms   (spike ceiling {d:.3} ms) {s}", .{
        b.name, b.measured_ms, b.limit_ms, if (ok) "OK" else "SPIKE",
    });
}

const Sample = struct {
    values: []u64 = &.{},
    filled: usize = 0,
    allocator: std.mem.Allocator,

    fn init(allocator: std.mem.Allocator, count: usize) !Sample {
        var sample = Sample{ .allocator = allocator };
        sample.values = try allocator.alloc(u64, count);
        @memset(sample.values, 0); // the tail must not pollute the percentiles
        return sample;
    }
    fn deinit(self: *Sample) void {
        self.allocator.free(self.values);
    }
    fn record(self: *Sample, ns: u64) void {
        if (self.filled < self.values.len) {
            self.values[self.filled] = ns;
            self.filled += 1;
        }
    }
    /// Percentile with nearest-rank ordering (deterministic, no fuss).
    fn percentile(self: *Sample, fraction: f64) f64 {
        std.mem.sort(u64, self.values[0..self.filled], {}, std.sort.asc(u64));
        const last = if (self.filled == 0) 0 else self.filled - 1;
        const index: usize = @intFromFloat(@max(0, @as(f64, @floatFromInt(last)) * fraction));
        return @as(f64, @floatFromInt(self.values[index])) / std.time.ns_per_ms;
    }
};

pub fn main(init: std.process.Init) !void {
    var arena = core.arena.FrameArena.init(std.heap.c_allocator, 256 * 1024 * 1024) catch unreachable;
    defer arena.deinit(std.heap.c_allocator);
    const bench_alloc = arena.allocator();

    // `zig build bench -- --scene` also exercises the `.zson` file format
    // end-to-end (write a scene, load it back), which is what the editor, the
    // exports and the undo/redo of M5 will use.
    if (hasArg(init, "--scene")) {
        try sceneFile(init.io, bench_alloc);
        return;
    }

    core.log.info("== M1 benchmarks ({d} runs, {d} warmup) ==", .{ iterations, warmup });
    core.log.info("budget reference: spec.md §2 and ROADMAP M1", .{});

    const transforms = try benchTransforms(bench_alloc);
    const hierarchy = try benchHierarchy(bench_alloc);
    const hash_ok = try benchSaveLoad(bench_alloc);
    try benchStructural(bench_alloc);

    report(.{ .name = "100k transforms p50", .measured_ms = transforms.p50, .limit_ms = 2.0 });
    reportSpike(.{ .name = "100k transforms p99", .measured_ms = transforms.p99, .limit_ms = spike_limit_ms });
    report(.{ .name = "10k hierarchy p50", .measured_ms = hierarchy.p50, .limit_ms = 2.0 });
    reportSpike(.{ .name = "10k hierarchy p99", .measured_ms = hierarchy.p99, .limit_ms = spike_limit_ms });
    report(.{ .name = "save/load hash", .measured_ms = if (hash_ok) 0 else 1, .limit_ms = 0 });

    core.log.info("bench scratch memory: {d} bytes", .{arena.usedNow()});

    if (failures > 0) {
        core.log.err("{d} budget(s) exceeded: a broken budget is a blocking bug (spec §0)", .{failures});
        std.process.exit(1);
    }
    core.log.info("all M1 budgets met", .{});
}

const FrameTimes = struct {
    p50: f64,
    p99: f64,
};

/// 1. 100k actors integrating a transform, inside the locked frame.
fn benchTransforms(allocator: std.mem.Allocator) !FrameTimes {
    var world = World.init(allocator);
    defer world.deinit();

    // Everything the frames will need is reserved before the loop: the budget
    // is about the frame cost, not about hiding an allocation.
    try world.reserveEntities(transforms_count);
    try world.reserve(.{ components.Transform, components.Velocity }, transforms_count);

    var i: usize = 0;
    while (i < transforms_count) : (i += 1) {
        _ = try world.spawn(.{
            components.Transform{ .position = .{ .x = @floatFromInt(i % 1000), .y = 0 } },
            components.Velocity{ .linear = .{ .x = 1.5, .y = -0.75 }, .angular = 0.1 },
        });
    }
    try std.testing.expectEqual(transforms_count, world.entityCount());

    var samples = try Sample.init(allocator, iterations);
    defer samples.deinit();

    world.lockAllocs(); // from here on, allocating is a bug (spec §3.1)
    for (0..iterations) |frame| {
        const t0 = core.time.monotonicNs();
        var q = world.query(.{ components.Transform, components.Velocity });
        while (q.nextBatch()) |batch| {
            // Batch iteration: the loop body is a plain Zig loop over slices.
            const transforms = batch.slice(components.Transform);
            const velocities = batch.slice(components.Velocity);
            for (transforms, velocities) |*transform, velocity| {
                transform.position.x += velocity.linear.x * dt;
                transform.position.y += velocity.linear.y * dt;
                transform.rotation += velocity.angular * dt;
                transform.capturePrevious();
            }
        }
        const elapsed = core.time.monotonicNs() - t0;
        if (frame >= warmup) samples.record(elapsed);
        std.mem.doNotOptimizeAway(transform_query_checksum(&world));
    }
    world.unlockAllocs();
    return .{ .p50 = samples.percentile(0.50), .p99 = samples.percentile(0.99) };
}

fn transform_query_checksum(world: *World) u64 {
    var sum: u64 = 0;
    var q = world.query(.{components.Transform});
    while (q.nextBatch()) |batch| {
        for (batch.slice(components.Transform)) |t| sum +%= @as(u32, @bitCast(t.position.x));
    }
    return sum;
}

/// 2. 10k entities in a parent/child tree, resolved flat every frame.
fn benchHierarchy(allocator: std.mem.Allocator) !FrameTimes {
    var world = World.init(allocator);
    defer world.deinit();

    // A wide tree (4 children per node, 5 levels): worst case for a recursive
    // walker, trivial for the flat resolver.
    try world.reserveEntities(hierarchy_count);
    const root = try world.spawn(.{components.Transform{ .position = .{ .x = 8, .y = 16 } }});
    var spawned: usize = 1;
    var nodes: [hierarchy_count]ecs.Entity = undefined;
    nodes[0] = root;
    var tail: usize = 1;
    while (spawned < hierarchy_count) {
        const parent = nodes[tail - 1];
        tail -= 1;
        var c: usize = 0;
        while (c < 4 and spawned < hierarchy_count) : (c += 1) {
            const child = try world.spawn(.{
                components.Transform{ .position = .{ .x = 1, .y = -1 }, .rotation = 0.01 },
                components.Parent{ .parent = parent },
            });
            nodes[spawned] = child;
            spawned += 1;
        }
        // Push the children back so the walk stays breadth-first-ish.
        tail += c;
    }
    try world.enableHierarchy();

    var samples = try Sample.init(allocator, iterations);
    defer samples.deinit();

    world.lockAllocs();
    for (0..iterations) |frame| {
        const t0 = core.time.monotonicNs();
        world.hierarchy.resolve(&world);
        const elapsed = core.time.monotonicNs() - t0;
        if (frame >= warmup) samples.record(elapsed);
        std.mem.doNotOptimizeAway(world.hierarchy.last_resolved);
    }
    world.unlockAllocs();
    return .{ .p50 = samples.percentile(0.50), .p99 = samples.percentile(0.99) };
}

/// 3. Save → load must reproduce the exact same state (bit-exact, spec §6).
fn benchSaveLoad(allocator: std.mem.Allocator) !bool {
    var world = World.init(allocator);
    defer world.deinit();

    var i: usize = 0;
    while (i < scene_count) : (i += 1) {
        const name = try std.fmt.allocPrint(allocator, "actor_{d}", .{i});
        _ = try world.spawn(.{
            components.Name.init(name),
            components.Transform{
                .position = .{ .x = @as(f32, @floatFromInt(i)) * 0.25, .y = -1.5 },
                .rotation = @as(f32, @floatFromInt(i % 360)) * 0.017453292,
            },
            components.Velocity{ .linear = .{ .x = 0.5, .y = -0.5 }, .angular = 0.002 },
        });
        if (i % 4 == 0) {
            const parent = try world.spawn(.{components.Name.init("group")});
            _ = try world.spawn(.{components.Parent{ .parent = parent }});
        }
    }

    const before = ecs.zson.hash(&world);
    const text = try ecs.zson.encodeToString(&world, allocator);
    defer allocator.free(text);

    const t0 = core.time.monotonicNs();
    var reloaded = try ecs.zson.decode(allocator, text);
    defer reloaded.deinit();
    const decode_ms = @as(f64, @floatFromInt(core.time.monotonicNs() - t0)) / std.time.ns_per_ms;

    const after = ecs.zson.hash(&reloaded);
    core.log.info("  scene: {d} entities, {d} bytes, decode {d:.3} ms", .{ world.entityCount(), text.len, decode_ms });
    core.log.info("  hash: {d} -> {d} ({s})", .{
        before, after, if (before == after) "identical" else "DIFFERENT",
    });
    return before == after;
}

/// Argument scanning without an allocator (bench args are flags at most).
fn hasArg(init: std.process.Init, name: []const u8) bool {
    var it = std.process.Args.Iterator.init(init.minimal.args);
    _ = it.next(); // program name
    while (it.next()) |arg| {
        if (std.mem.eql(u8, arg, name)) return true;
    }
    return false;
}

/// Writes a scene as `.zson`, loads it back from disk and compares hashes:
/// the M1 sample of the format the whole engine now round-trips through.
fn sceneFile(io: std.Io, allocator: std.mem.Allocator) !void {
    var world = World.init(allocator);
    defer world.deinit();

    const root = try world.spawn(.{
        components.Name.init("camera"),
        components.Transform{ .position = .{ .x = 640, .y = 360 } },
    });
    var i: usize = 0;
    while (i < 24) : (i += 1) {
        const actor = try world.spawn(.{
            components.Name.init(try std.fmt.allocPrint(allocator, "sprite_{d}", .{i})),
            components.Transform{
                .position = .{ .x = @as(f32, @floatFromInt(i * 24)), .y = @as(f32, @floatFromInt(i * 16)) },
                .rotation = @as(f32, @floatFromInt(i)) * 0.05,
                .scale = .{ .x = 2, .y = 2 },
            },
            components.Parent{ .parent = root },
            components.Velocity{ .linear = .{ .x = 1, .y = -1 } },
        });
        if (i % 5 == 0) try world.add(actor, components.Parent{ .parent = root });
    }

    const text = try ecs.zson.encodeToString(&world, allocator);
    const path = "scene.zson"; // the shipped sample is samples/scene.zson
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = path, .data = text });

    const loaded = try std.Io.Dir.cwd().readFileAlloc(io, path, allocator, .limited(1 << 24));
    defer allocator.free(loaded);
    var reloaded = try ecs.zson.decode(allocator, loaded);
    defer reloaded.deinit();

    core.log.info("scene {s}: {d} entities, {d} bytes", .{ path, world.entityCount(), text.len });
    core.log.info("hash before {d} / after {d} ({s})", .{
        ecs.zson.hash(&world), ecs.zson.hash(&reloaded),
        if (ecs.zson.hash(&world) == ecs.zson.hash(&reloaded)) "identical" else "DIFFERENT",
    });
    if (ecs.zson.hash(&world) != ecs.zson.hash(&reloaded)) return error.HashMismatch;
}

/// 4. Informational: archetype churn per second (spawn, add, remove, despawn).
fn benchStructural(allocator: std.mem.Allocator) !void {
    var world = World.init(allocator);
    defer world.deinit();
    try world.reserveEntities(structural_count);

    const t0 = core.time.monotonicNs();
    var i: usize = 0;
    while (i < structural_count) : (i += 1) {
        const e = try world.spawn(.{components.Transform{ .position = .{ .x = 1, .y = 2 } }});
        try world.add(e, components.Velocity{ .linear = .{ .x = 3, .y = 4 } });
        try world.add(e, components.Name.init("churn"));
        _ = world.remove(e, components.Velocity);
        if (!world.despawn(e)) return error.StructuralFailure;
    }
    const total_ms = @as(f64, @floatFromInt(core.time.monotonicNs() - t0)) / std.time.ns_per_ms;
    core.log.info("  {d} structural changes: {d:.3} ms ({d:.1} ns each)", .{
        structural_count * 4, total_ms, total_ms * std.time.ns_per_ms / @as(f64, @floatFromInt(structural_count * 4)),
    });
}
