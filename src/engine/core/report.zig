//! The perf report: what the run measured, plus the verdict against spec.md.
//!
//! Two consumers of the same numbers:
//! - the logger (human): the full table, counters, memory, verdicts.
//! - `report.json` (machine): the CI gate (roadmap M11) reads it, so a >5%
//!   regression on any metric MUST be automatable, not something a human
//!   eyeballs in a terminal.
//!
//! Everything here runs at exit, never inside the frame loop.

const std = @import("std");
const log = @import("log.zig");
const time = @import("time.zig");
const profiler_mod = @import("profiler.zig");
const budget_mod = @import("budget.zig");
const sampler_mod = @import("sampler.zig");
const json = @import("json.zig");

const Profiler = profiler_mod.Profiler;
const Counters = profiler_mod.Counters;
const Sampler = sampler_mod.Sampler;

fn zoneIndex(prof: *const Profiler, name: []const u8) ?usize {
    for (0..prof.zone_count) |i| {
        if (std.mem.eql(u8, prof.zones[i].name, name)) return i;
    }
    return null;
}

pub const Options = struct {
    mode: budget_mod.Mode = .game,
    budget: budget_mod.Budget = .{},
    warmup_frames: u64 = 0,
    /// Wall-clock seconds the loop ran (for the CPU% of the sampler).
    run_seconds: f64 = 0,
    backend: []const u8 = "unknown",
    resolution: []const u8 = "-",
    vsync: bool = true,
    notes: []const []const u8 = &.{},
};

pub fn print(prof: *const Profiler, ctr: *const Counters, sampler: ?*const Sampler, opts: Options) void {
    const measured: usize = if (prof.work_ring_len > 0) prof.work_ring_len else prof.ring_len;
    log.info("== PERF ({s}) ==", .{opts.backend});
    log.info("  frames: {d} (warm-up excluded: {d}, measured: {d}, ring cap: {d})", .{
        ctr.frame_index,
        opts.warmup_frames,
        measured,
        profiler_mod.RING_CAP,
    });
    if (measured == 0) {
        log.warn("  no frames measured: run longer, or check --warmup", .{});
        return;
    }
    if (!opts.vsync) {
        log.info("  vsync OFF: the CPU budget verdicts below are meaningful", .{});
    } else {
        log.info("  vsync ON: the WALL times below include the vsync wait; the budgets apply to the work frame", .{});
    }

    // frame times
    log.info("  frame wall   p50 {d:.3} ms  p99 {d:.3} ms  p99.9 {d:.3} ms  (max {d:.3})", .{
        prof.frameMsAtPercentile(50),
        prof.frameMsAtPercentile(99),
        prof.frameMsAtPercentile(99.9),
        prof.frameMsMax(),
    });
    if (prof.work_ring_len > 0) {
        log.info("  frame work   p50 {d:.3} ms  p99 {d:.3} ms  p99.9 {d:.3} ms  <-- spec §2 applies here", .{
            prof.frameWorkMsAtPercentile(50),
            prof.frameWorkMsAtPercentile(99),
            prof.frameWorkMsAtPercentile(99.9),
        });
    }
    if (prof.zone_count > 0 and zoneIndex(prof, "render_acquire") != null) {
        log.info("  pacing wait (surface acquire) p99 {d:.3} ms — with vsync this is the frame cap", .{
            prof.zoneFrameMsAtPercentile(zoneIndex(prof, "render_acquire").?, 99),
        });
    }
    if (ctr.present_wait_ns > 0 or prof.frame_count > 0) {
        log.info("  present wait: {d:.3} ms   (vsync lives in render_acquire, not here)", .{
            @as(f64, @floatFromInt(ctr.present_wait_ns)) / 1_000_000.0,
        });
    }

    // zones
    log.info("  zones (per frame: avg / p99 / self-time share):", .{});
    var order: [profiler_mod.MAX_ZONES]usize = undefined;
    for (0..prof.zone_count) |i| order[i] = i;
    const Ctx = struct {
        zones: []const profiler_mod.Zone,
        fn less(ctx: @This(), a: usize, b: usize) bool {
            return ctx.zones[a].self_ns_total > ctx.zones[b].self_ns_total;
        }
    };
    std.mem.sort(usize, order[0..prof.zone_count], Ctx{ .zones = prof.zones[0..prof.zone_count] }, Ctx.less);
    for (order[0..prof.zone_count]) |i| {
        const z = prof.zones[i];
        const hits_per_frame = @as(f64, @floatFromInt(z.hits)) / @as(f64, @floatFromInt(measured));
        const avg_ms = @as(f64, @floatFromInt(z.ns_total)) / @as(f64, @floatFromInt(@max(measured, 1))) / 1_000_000.0;
        const self_share = if (z.ns_total == 0) 0 else
            @as(f64, @floatFromInt(z.self_ns_total)) * 100.0 / @as(f64, @floatFromInt(z.ns_total));
        log.info("    {s:<24} {d:>8.4} ms/f  p99 {d:>8.4} ms  calls/f {d:>7.2}  self {d:>5.1}%  max {d:.4} ms", .{
            z.name,
            avg_ms,
            prof.zoneMsAtPercentile(i, 99),
            hits_per_frame,
            self_share,
            @as(f64, @floatFromInt(z.ns_max)) / 1_000_000.0,
        });
    }

    // counters
    log.info("  render: {d} draw calls, {d} passes, {d} pipeline changes, {d} bind groups, {d} bytes/frame", .{
        ctr.draw_calls,
        ctr.render_passes,
        ctr.pipeline_changes,
        ctr.bind_group_changes,
        ctr.upload_bytes,
    });
    if (ctr.gpu_ns > 0) {
        log.info("  gpu: {d:.3} ms ({} timestamped pass(es))", .{
            @as(f64, @floatFromInt(ctr.gpu_ns)) / 1_000_000.0,
            ctr.gpu_pass_count,
        });
    } else {
        // Say WHY: no feature on the device, or the readback never completed.
        var reason_buf: [128]u8 = undefined;
        const reason = if (ctr.ts_maps == 0)
            "query set unavailable (adapter has no timestamp-query feature)"
        else if (ctr.ts_polls_ok > 0 and ctr.ts_reads == 0)
            std.fmt.bufPrint(&reason_buf, "samples invalid or zero ({d} ok maps, {d} bad)", .{ ctr.ts_polls_ok, ctr.ts_bad }) catch "invalid samples"
        else if (ctr.ts_reads == 0)
            "the map future never completed (bounded retry gave up)"
        else
            "no valid samples";
        log.info("  gpu: not measured — {s} [maps {d}, polls_ok {d}, ranges {d}, bad {d}]", .{ reason, ctr.ts_maps, ctr.ts_polls_ok, ctr.ts_ranges, ctr.ts_bad });
    }
    log.info("  loop: {d} fixed step(s)/frame, {d} dropped total, arena {d} bytes high-water", .{
        @as(f64, @floatFromInt(ctr.fixed_steps_total)) / @as(f64, @floatFromInt(@max(measured, 1))),
        ctr.fixed_steps_dropped_total,
        ctr.arena_high_water_bytes,
    });

    // memory + threads
    log.info("  mem: live {d} bytes, peak {d} bytes, arena high-water {d} bytes ({d} in use)", .{
        ctr.live_bytes,
        ctr.peak_live_bytes,
        ctr.arena_high_water_bytes,
        ctr.arena_used_bytes,
    });
    if (sampler) |s| {
        if (s.latest().rss_bytes > 0) {
            log.info("  proc: rss {d:.1} MiB (peak {d:.1} MiB), {d} threads, cpu total {d:.1}%, main {d:.1}%", .{
                @as(f64, @floatFromInt(s.latest().rss_bytes)) / (1024.0 * 1024.0),
                @as(f64, @floatFromInt(s.peakRssBytes())) / (1024.0 * 1024.0),
                s.latest().thread_count,
                s.cpuPercentTotal(),
                s.cpuPercentMain(),
            });
        }
    }
    for (opts.notes) |n| log.info("  note: {s}", .{n});

    // verdicts
    const rep = budget_mod.evaluate(opts.budget, prof, ctr, opts.mode);
    log.info("== spec.md verdicts ==", .{});
    for (rep.results[0..rep.count]) |r| {
        const label = switch (r.status) {
            .pass => "PASS",
            .fail => "FAIL",
            .unknown => " n/a",
        };
        log.info("  [{s}] {s:<22} {d:>9.3} {s} (limit {d:.3})", .{
            label,
            r.name,
            r.value,
            switch (r.unit) {
                .ms => "ms",
                .count, .bytes => " ",
                .mbytes => "MB",
            },
            r.limit,
        });
    }
    if (rep.allPass()) {
        log.info("  all measured budgets pass", .{});
    } else {
        std.debug.print("[PERF] {d} budget(s) FAILED (spec.md)\n", .{rep.failCount()});
    }
}

/// Writes the machine-readable summary used by the CI gate.
pub fn writeJson(w: *json.Writer, prof: *const Profiler, ctr: *const Counters, opts: Options) void {
    w.startObject();
    w.field("schema");
    w.num(@as(u32, 1));
    w.raw(",");
    w.field("backend");
    w.str(opts.backend);
    w.raw(",");
    w.field("mode");
    w.str(@tagName(opts.mode));
    w.raw(",");
    w.field("clock");
    w.str(@tagName(time.kind));
    w.raw(",");
    w.field("tsc_hz");
    w.num(time.tsc_hz);
    w.raw(",");
    w.field("vsync");
    w.raw(if (opts.vsync) "true" else "false");
    w.raw(",");
    w.field("frames");
    w.num(prof.frame_count);
    w.raw(",");
    w.field("warmup_frames");
    w.num(opts.warmup_frames);
    w.raw(",");
    w.field("measured");
    w.num(prof.work_ring_len);
    w.raw(",");
    w.field("frame_ms");
    w.startObject();
    w.field("wall_p50");
    w.numFloat(prof.frameMsAtPercentile(50));
    w.raw(",");
    w.field("wall_p99");
    w.numFloat(prof.frameMsAtPercentile(99));
    w.raw(",");
    w.field("wall_p999");
    w.numFloat(prof.frameMsAtPercentile(99.9));
    w.raw(",");
    w.field("work_p50");
    w.numFloat(prof.frameWorkMsAtPercentile(50));
    w.raw(",");
    w.field("work_p99");
    w.numFloat(prof.frameWorkMsAtPercentile(99));
    w.raw(",");
    w.field("work_p999");
    w.numFloat(prof.frameWorkMsAtPercentile(99.9));
    w.raw(",");
    w.field("work_max");
    w.numFloat(prof.frameWorkMsAtPercentile(100));
    w.endObject();
    w.raw(",");

    // zones
    w.field("zones");
    w.startArray();
    for (0..prof.zone_count) |i| {
        if (i != 0) w.raw(",");
        const z = prof.zones[i];
        w.startObject();
        w.field("name");
        w.str(z.name);
        w.raw(",");
        w.field("hits");
        w.num(z.hits);
        w.raw(",");
        w.field("avg_ms");
        w.numFloat(@as(f64, @floatFromInt(z.ns_total)) / @as(f64, @floatFromInt(@max(prof.work_ring_len, 1))) / 1_000_000.0);
        w.raw(",");
        w.field("p99_ms");
        w.numFloat(prof.zoneMsAtPercentile(i, 99));
        w.raw(",");
        w.field("frame_p99_ms");
        w.numFloat(prof.zoneFrameMsAtPercentile(i, 99));
        w.raw(",");
        w.field("max_ms");
        w.numFloat(@as(f64, @floatFromInt(z.ns_max)) / 1_000_000.0);
        w.raw(",");
        w.field("self_share");
        w.numFloat(if (z.ns_total == 0) 0 else @as(f64, @floatFromInt(z.self_ns_total)) * 100.0 / @as(f64, @floatFromInt(z.ns_total)));
        w.endObject();
    }
    w.endArray();
    w.raw(",");

    // counters (the ones the gate and §3/§4 care about)
    w.field("counters");
    w.startObject();
    w.field("draw_calls");
    w.num(ctr.draw_calls);
    w.raw(",");
    w.field("render_passes");
    w.num(ctr.render_passes);
    w.raw(",");
    w.field("pipeline_changes");
    w.num(ctr.pipeline_changes);
    w.raw(",");
    w.field("bind_group_changes");
    w.num(ctr.bind_group_changes);
    w.raw(",");
    w.field("upload_bytes");
    w.num(ctr.upload_bytes);
    w.raw(",");
    w.field("fixed_steps");
    w.num(ctr.fixed_steps);
    w.raw(",");
    w.field("fixed_steps_dropped");
    w.num(ctr.fixed_steps_dropped);
    w.raw(",");
    w.field("gpu_ns");
    w.num(ctr.gpu_ns);
    w.raw(",");
    w.field("gpu_passes");
    w.num(ctr.gpu_pass_count);
    w.raw(",");
    w.field("gpu_resources_in_frame");
    w.num(ctr.gpu_resources_created);
    w.raw(",");
    w.field("allocs_in_frame");
    w.num(ctr.allocs_in_frame);
    w.raw(",");
    w.field("arena_high_water");
    w.num(ctr.arena_high_water_bytes);
    w.raw(",");
    w.field("live_bytes");
    w.num(ctr.live_bytes);
    w.raw(",");
    w.field("peak_live_bytes");
    w.num(ctr.peak_live_bytes);
    w.raw(",");
    w.field("rss_bytes");
    w.num(ctr.rss_bytes);
    w.endObject();
    w.raw(",");

    // verdicts
    const rep = budget_mod.evaluate(opts.budget, prof, ctr, opts.mode);
    w.field("verdicts");
    w.startArray();
    for (rep.results[0..rep.count], 0..) |r, i| {
        if (i != 0) w.raw(",");
        w.startObject();
        w.field("name");
        w.str(r.name);
        w.raw(",");
        w.field("value");
        w.numFloat(r.value);
        w.raw(",");
        w.field("limit");
        w.numFloat(r.limit);
        w.raw(",");
        w.field("unit");
        w.str(@tagName(r.unit));
        w.raw(",");
        w.field("status");
        w.str(@tagName(r.status));
        w.endObject();
    }
    w.endArray();
    w.raw(",");
    w.field("pass");
    w.raw(if (rep.allPass()) "true" else "false");
    w.endObject();
}

test "report json is well formed and contains the gate fields" {
    var prof = Profiler{};
    var ctr = Counters{};
    prof.beginFrame(true);
    var z = prof.zone("render");
    time.sleepNs(1_000_000); // 1 ms of work
    z.end();
    prof.endFrame();
    prof.pushWorkFrame(1_000_000);
    ctr.draw_calls = 1;
    ctr.rss_bytes = 40 * 1024 * 1024;

    var w = json.Writer{};
    writeJson(&w, &prof, &ctr, .{});
    const text = w.buf[0..w.len];
    try std.testing.expect(std.mem.indexOf(u8, text, "\"schema\":1") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "\"verdicts\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "\"zones\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "\"work_p50\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "\"render\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "\"pass\":") != null);
    // endFrame must count the frame: the gate compares `frames` across runs.
    try std.testing.expect(std.mem.indexOf(u8, text, "\"frames\":1") != null);
}
