//! M13 animation benchmark. Run with `zig build bench-animation`.
//!
//! The ROADMAP M13 criterion is **"the system costs ≤ 0.05 ms/frame for 100
//! clips simultaneously"**, and this enforces it as a number a machine fails
//! against rather than a claim:
//!
//!   - **100 clips playing at once**, each on its own entity, through the real
//!     `System.update` path — not a synthetic inner loop. Each clip is decoded
//!     by `parseClip` from real `.anim` text (4 value tracks, an 8-frame sprite
//!     track and a method event), which is what a character clip actually looks
//!     like.
//!   - **p50 under the budget**, because the criterion is a per-frame cost
//!     (spec §2), measured after a warm-up so the first-frame cold caches do not
//!     count. p99 is reported too: a spike above the budget is what drops a
//!     frame.
//!   - **Zero allocations on the frame path.** A counting allocator wraps the
//!     system allocator and `update` must not move the count — no growing a
//!     map, no temporary array, no string.
//!
//! Headless by construction: it links `core` + `ecs` and nothing else, so a
//! renderer or a script layer mid-edit cannot stop the number from being
//! measured (the same reason `bench/main.zig` is its own artifact).
//!
//! `--clips <n>` changes the entity count, so a developer can see where the
//! curve turns (`zig build bench-animation -- --clips 400`).

const std = @import("std");
const core = @import("core");
const ecs = @import("ecs");

const components = ecs.components;
const World = ecs.World;

/// The ROADMAP criterion, in milliseconds per frame.
const budget_ms: f64 = 0.05;
/// 60 Hz, like the real loop: the per-frame cost is what the criterion names.
const dt: f32 = 1.0 / 60.0;
const frames: usize = 240;
const warmup_frames: usize = 16;
const default_clips: usize = 100;

/// Wraps the real allocator and counts allocations. `resize`/`remap`/`free` are
/// delegated without counting, so the check is "does the frame path allocate"
/// and not "does it ever touch the allocator".
const Counting = struct {
    child: std.mem.Allocator,
    allocations: usize = 0,

    fn cast(p: *anyopaque) *Counting {
        return @ptrCast(@alignCast(p));
    }
    fn allocFn(ctx: *anyopaque, len: usize, alignment: std.mem.Alignment, ra: usize) ?[*]u8 {
        const self = cast(ctx);
        self.allocations += 1;
        return self.child.vtable.alloc(self.child.ptr, len, alignment, ra);
    }
    fn resizeFn(ctx: *anyopaque, memory: []u8, alignment: std.mem.Alignment, new_len: usize, ra: usize) bool {
        const self = cast(ctx);
        return self.child.vtable.resize(self.child.ptr, memory, alignment, new_len, ra);
    }
    fn remapFn(ctx: *anyopaque, memory: []u8, alignment: std.mem.Alignment, new_len: usize, ra: usize) ?[*]u8 {
        const self = cast(ctx);
        return self.child.vtable.remap(self.child.ptr, memory, alignment, new_len, ra);
    }
    fn freeFn(ctx: *anyopaque, memory: []u8, alignment: std.mem.Alignment, ra: usize) void {
        const self = cast(ctx);
        self.child.vtable.free(self.child.ptr, memory, alignment, ra);
    }
    const vtable = std.mem.Allocator.VTable{
        .alloc = allocFn,
        .resize = resizeFn,
        .remap = remapFn,
        .free = freeFn,
    };
    fn allocator(self: *Counting) std.mem.Allocator {
        return .{ .ptr = self, .vtable = &vtable };
    }
};

/// Counts the method events and `animation_finished` signals a run produced, so
/// the bench proves the tracks ran rather than only that they were cheap.
const Counter = struct {
    fired: usize = 0,
    fn dispatch(ctx: ?*anyopaque, _: []const u8) void {
        const self: *Counter = @ptrCast(@alignCast(ctx.?));
        self.fired += 1;
    }
    fn bridge(self: *Counter) ecs.timer.SignalBridge {
        return .{ .ctx = self, .dispatch = Counter.dispatch };
    }
};

fn percentile(sorted: []const u64, p: f64) f64 {
    if (sorted.len == 0) return 0;
    const idx = @min(sorted.len - 1, @as(usize, @intFromFloat(@as(f64, @floatFromInt(sorted.len - 1)) * p)));
    return @as(f64, @floatFromInt(sorted[idx])) / 1_000_000.0; // ns -> ms
}

pub fn main(init: std.process.Init.Minimal) !void {
    var clips_n: usize = default_clips;
    var args = std.process.Args.Iterator.init(init.args);
    _ = args.next();
    while (args.next()) |arg| {
        if (std.mem.eql(u8, arg, "--clips")) {
            if (args.next()) |n| clips_n = std.fmt.parseInt(usize, n, 10) catch default_clips;
        }
    }
    if (clips_n == 0) clips_n = default_clips;

    var counting = Counting{ .child = std.heap.c_allocator };
    const alloc = counting.allocator();

    var world = World.init(alloc);
    defer world.deinit();
    var sys = ecs.animation.System.init(alloc);
    defer sys.deinit();

    // ── Setup: real `.anim` text, decoded by the real parser ────────────────
    // The texts are kept alive for the run because `parseClip` borrows method
    // names out of them (`name_pool` is only set by `decodeFile`).
    const texts = try alloc.alloc([]u8, clips_n);
    defer {
        for (texts) |t| alloc.free(t);
        alloc.free(texts);
    }
    const ids = try alloc.alloc(u32, clips_n);
    defer alloc.free(ids);

    var path_buf: [32]u8 = undefined;
    for (texts, 0..) |*slot, i| {
        slot.* = try std.fmt.allocPrint(alloc,
            \\clip 1
            \\duration {d:.3}
            \\flags loop root_motion
            \\root_motion 4.0 2.0 0.5
            \\value transform_x 3 0.0 0.0 0.500 60.0 1.000 0.0
            \\value transform_y 3 0.0 0.0 0.500 20.0 1.000 0.0
            \\value sprite_tint 3 0.0 1.0 0.500 2.0 1.000 1.0
            \\value light_energy 3 0.0 1.0 0.500 3.0 1.000 1.0
            \\sprite 8 0.000 0.000 0.000 0.125 0.500 0.125 0.000 0.000 0.250 0.500 0.250 0.000 0.000 0.375 0.500 0.375 0.000 0.000 0.500 0.500 0.500 0.000 0.000 0.625 0.500 0.625 0.000 0.000 0.750 0.500 0.750 0.000 0.000 0.875 0.500 0.875 0.000 0.000 1.000 0.500 1.000
            \\method 0.250 step
            \\
        , .{0.5 + @as(f64, @floatFromInt(i % 40)) * 0.01});
        // Decode through the real parser, then register under the GUID-derived
        // handle of a clip path — the same id a project's preload would produce
        // for that path, so the bench measures the shipping identity scheme.
        const clip = try ecs.animation.parseClip(alloc, slot.*);
        const path = try std.fmt.bufPrint(&path_buf, "clip_{d}.anim", .{i});
        ids[i] = ecs.animation.clipIdForPath(path);
        try sys.addClip(ids[i], clip);
    }

    for (0..clips_n) |i| {
        _ = try world.spawn(.{
            components.AnimationPlayer{ .clip_id = ids[i], .speed = 1.0 },
            components.Transform{ .position = .{ .x = @floatFromInt(i), .y = 0 } },
            components.Sprite{},
            components.Light2D{},
        });
    }

    var counter = Counter{};
    const bridge = counter.bridge();

    // Every buffer the measurement needs is allocated BEFORE the baseline is
    // read, or the harness's own allocation would be blamed on the frame path.
    const samples = try alloc.alloc(u64, frames);
    defer alloc.free(samples);

    // ── Warm-up, then the measured loop ─────────────────────────────────────
    for (0..warmup_frames) |_| {
        sys.update(&world, dt, bridge);
        sys.applyRootMotion(&world, dt);
    }
    const events_before = counter.fired;
    const allocations_before = counting.allocations;

    for (0..frames) |f| {
        const t0 = core.time.monotonicNs();
        sys.update(&world, dt, bridge);
        sys.applyRootMotion(&world, dt);
        samples[f] = core.time.monotonicNs() - t0;
    }

    const allocations_after = counting.allocations;
    const zero_alloc = allocations_after == allocations_before;

    std.mem.sort(u64, samples, {}, std.sort.asc(u64));
    const p50 = percentile(samples, 0.50);
    const p99 = percentile(samples, 0.99);
    const worst = @as(f64, @floatFromInt(samples[samples.len - 1])) / 1_000_000.0;

    const clips_resident = sys.clips.count();
    const events = counter.fired - events_before;
    const within_budget = p50 <= budget_ms;

    std.debug.print(
        \\
        \\== M13 animation ({d} clips, {d} frames, {d} warm-up) ==
        \\  update + root motion   p50 {d:.4} ms   p99 {d:.4} ms   worst {d:.4} ms
        \\  budget (ROADMAP M13)   p50 <= {d:.3} ms                        {s}
        \\  clips resident         {d}
        \\  method events fired    {d} over {d} frames
        \\  allocations in frame    {s}
        \\
    , .{
        clips_n,
        frames,
        warmup_frames,
        p50,
        p99,
        worst,
        budget_ms,
        if (within_budget) "OK" else "OVER BUDGET",
        clips_resident,
        events,
        frames,
        if (zero_alloc) "0" else "NON-ZERO",
    });

    if (!within_budget) return error.OverBudget;
    if (!zero_alloc) return error.AllocatedInFrame;
}
