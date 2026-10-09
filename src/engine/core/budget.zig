//! spec.md as code: budgets and verdicts (spec §0 and §9).
//!
//! "Budgets are MEASURED, not estimated" (§0). Every number below is copied
//! verbatim from spec.md so a report can print PASS/FAIL instead of a bare
//! number: every run ends in a verdict, not in a pretty table.
//!
//! If spec.md changes, this file changes. One edit, all verdicts follow.

const std = @import("std");
const profiler_mod = @import("profiler.zig");
const core_time = @import("time.zig");
const Profiler = profiler_mod.Profiler;
const Counters = profiler_mod.Counters;

/// Where the numbers come from: the RAM budget differs per profile (§5).
pub const Mode = enum {
    /// Exported game (what players get): the strict budgets.
    game,
    /// Editor (the overlay is allowed its own budget, §2).
    editor,
    /// CI/headless run: budgets apply, but nothing is shipped.
    ci,
};

pub const Budget = struct {
    // §2 frame budget (exported game at 60 FPS)
    frame_work_ms_p50: f64 = 7.0,
    frame_work_ms_p99: f64 = 10.0,
    frame_work_ms_p999: f64 = 16.6,

    // §2 per-system budget, checked by zone name as they appear
    lua_update_ms: f64 = 2.0, // M3
    physics_ms: f64 = 2.0, // M4
    render_cpu_ms: f64 = 1.5, // M2
    signals_ms: f64 = 0.8, // M1
    editor_overlay_ms: f64 = 2.0,

    // §3 anti-spike
    allocs_per_frame: u64 = 0,
    fixed_steps_per_frame: u32 = 1, // "max 1 catch-up step"

    // §4 GPU
    gpu_ms: f64 = 6.0,
    draw_calls: u64 = 32,
    draw_calls_with_gi: u64 = 64,
    upload_bytes_per_frame: u64 = 2 << 20,
    gpu_resources_per_frame: u64 = 0,

    // §5 RAM (MB)
    rss_export_empty_mb: u64 = 48,
    rss_export_demo_mb: u64 = 128,
    rss_editor_empty_mb: u64 = 512,
    rss_editor_demo_mb: u64 = 1200,
};

pub const Status = enum { pass, fail, unknown };

pub const Result = struct {
    name: []const u8,
    value: f64,
    limit: f64,
    unit: enum { ms, count, bytes, mbytes },
    status: Status,
    /// Set when the metric could not be measured (system not present yet).
    note: []const u8 = "",

    pub fn ms(self: Result) f64 {
        return self.value;
    }

    pub fn render(self: Result) void {
        const label = switch (self.status) {
            .pass => "PASS",
            .fail => "FAIL",
            .unknown => " n/a",
        };
        std.debug.print("  [{s}] {s:<26} {d:>9.3} {s} / {d:.3} {s}", .{
            label,
            self.name,
            self.value,
            switch (self.unit) {
                .ms => "ms",
                .count => "  ",
                .bytes => "  ",
                .mbytes => "MB",
            },
            self.limit,
            switch (self.unit) {
                .ms => "ms",
                .count => "  ",
                .bytes => "  ",
                .mbytes => "MB",
            },
        });
        if (self.note.len > 0) std.debug.print("   ({s})", .{self.note});
        std.debug.print("\n", .{});
    }
};

pub const Report = struct {
    results: [24]Result = undefined,
    count: usize = 0,

    pub fn add(self: *Report, r: Result) void {
        if (self.count >= self.results.len) return;
        self.results[self.count] = r;
        self.count += 1;
    }

    pub fn failCount(self: *const Report) usize {
        var n: usize = 0;
        for (self.results[0..self.count]) |r| {
            if (r.status == .fail) n += 1;
        }
        return n;
    }

    pub fn allPass(self: *const Report) bool {
        return self.failCount() == 0;
    }

    pub fn print(self: *const Report) void {
        for (self.results[0..self.count]) |r| r.render();
    }
};

fn statusFor(value: f64, limit: f64, higher_is_fail: bool) Status {
    if (value == 0) return .unknown;
    return if (higher_is_fail) (if (value <= limit) .pass else .fail) else (if (value >= limit) .pass else .fail);
}

/// Evaluates the spec.md budgets against a measured run.
/// `prof` may have zero frames (then everything is unknown) and counters may
/// be empty (systems not implemented yet).
pub fn evaluate(b: Budget, prof: *const Profiler, ctr: *const Counters, mode: Mode) Report {
    var rep = Report{};

    if (prof.ring_len == 0) {
        rep.add(.{ .name = "no frames measured", .value = 0, .limit = 0, .unit = .ms, .status = .unknown });
        return rep;
    }

    // ── §2 frame budget (on the work frame: no vsync in the number) ─────────
    rep.add(.{
        .name = "frame work p50",
        .value = prof.frameWorkMsAtPercentile(50),
        .limit = b.frame_work_ms_p50,
        .unit = .ms,
        .status = statusFor(prof.frameWorkMsAtPercentile(50), b.frame_work_ms_p50, true),
    });
    rep.add(.{
        .name = "frame work p99",
        .value = prof.frameWorkMsAtPercentile(99),
        .limit = b.frame_work_ms_p99,
        .unit = .ms,
        .status = statusFor(prof.frameWorkMsAtPercentile(99), b.frame_work_ms_p99, true),
    });
    rep.add(.{
        .name = "frame work p99.9",
        .value = prof.frameWorkMsAtPercentile(99.9),
        .limit = b.frame_work_ms_p999,
        .unit = .ms,
        .status = statusFor(prof.frameWorkMsAtPercentile(99.9), b.frame_work_ms_p999, true),
    });

    // ── §2 per-system budgets, by zone name (they exist from M1 on) ─────────
    const zone_rules = [_]struct { name: []const u8, limit: f64 }{
        .{ .name = "lua_update", .limit = b.lua_update_ms },
        .{ .name = "physics", .limit = b.physics_ms },
        .{ .name = "render", .limit = b.render_cpu_ms },
        .{ .name = "signals", .limit = b.signals_ms },
        .{ .name = "editor_overlay", .limit = b.editor_overlay_ms },
    };
    for (zone_rules) |rule| {
        const found = findZone(prof, rule.name) orelse {
            rep.add(.{
                .name = rule.name,
                .value = 0,
                .limit = rule.limit,
                .unit = .ms,
                .status = .unknown,
                .note = "zone not instrumented yet",
            });
            continue;
        };
        const p99 = prof.zoneFrameMsAtPercentile(found, 99);
        rep.add(.{
            .name = rule.name,
            .value = p99,
            .limit = rule.limit,
            .unit = .ms,
            .status = statusFor(p99, rule.limit, true),
        });
    }

    // ── §3 anti-spike ───────────────────────────────────────────────────────
    rep.add(.{
        .name = "allocs in frame",
        .value = @floatFromInt(ctr.allocs_in_frame),
        .limit = @floatFromInt(b.allocs_per_frame),
        .unit = .count,
        .status = if (ctr.allocs_in_frame <= b.allocs_per_frame) .pass else .fail,
    });
    rep.add(.{
        .name = "GPU objects in frame",
        .value = @floatFromInt(ctr.gpu_resources_created),
        .limit = @floatFromInt(b.gpu_resources_per_frame),
        .unit = .count,
        // 0 is the only acceptable value; a non-zero counter means something
        // created a GPU object mid-frame, which §3.6 forbids outright.
        .status = if (ctr.gpu_resources_created == 0) .pass else .fail,
    });

    // ── §4 GPU ──────────────────────────────────────────────────────────────
    rep.add(.{
        .name = "gpu frame (passes)",
        .value = @as(f64, @floatFromInt(ctr.gpu_ns)) / 1_000_000.0,
        .limit = b.gpu_ms,
        .unit = .ms,
        .status = if (ctr.gpu_ns == 0)
            .unknown
        else
            statusFor(@as(f64, @floatFromInt(ctr.gpu_ns)) / 1_000_000.0, b.gpu_ms, true),
        .note = if (ctr.gpu_ns == 0) "no timestamp queries on this device" else "",
    });
    rep.add(.{
        .name = "draw calls",
        .value = @floatFromInt(ctr.draw_calls),
        .limit = @floatFromInt(b.draw_calls),
        .unit = .count,
        .status = statusFor(@floatFromInt(ctr.draw_calls), @floatFromInt(b.draw_calls), true),
    });
    rep.add(.{
        .name = "upload bytes/frame",
        .value = @floatFromInt(ctr.upload_bytes),
        .limit = @floatFromInt(b.upload_bytes_per_frame),
        .unit = .bytes,
        .status = statusFor(@floatFromInt(ctr.upload_bytes), @floatFromInt(b.upload_bytes_per_frame), true),
    });

    // ── §5 RAM ──────────────────────────────────────────────────────────────
    const rss_mb: f64 = @as(f64, @floatFromInt(ctr.rss_bytes)) / (1024.0 * 1024.0);
    const rss_limit: f64 = switch (mode) {
        .game, .ci => @floatFromInt(b.rss_export_demo_mb),
        .editor => @floatFromInt(b.rss_editor_demo_mb),
    };
    rep.add(.{
        .name = "RSS (demo profile)",
        .value = rss_mb,
        .limit = rss_limit,
        .unit = .mbytes,
        .status = if (ctr.rss_bytes == 0) .unknown else statusFor(rss_mb, rss_limit, true),
        .note = if (ctr.rss_bytes == 0) "sampler off" else "",
    });

    return rep;
}

fn findZone(prof: *const Profiler, name: []const u8) ?usize {
    for (0..prof.zone_count) |i| {
        if (std.mem.eql(u8, prof.zones[i].name, name)) return i;
    }
    return null;
}

// ── tests ───────────────────────────────────────────────────────────────────

test "a fast run passes the frame budget" {
    const b = Budget{};
    var prof = Profiler{};
    var ctr = Counters{};
    // three measured frames of 1 ms of work each
    var i: usize = 0;
    while (i < 3) : (i += 1) {
        prof.beginFrame(true);
        var z = prof.zone("render");
        core_time.sleepNs(1_000_000);
        z.end();
        prof.endFrame();
        prof.pushWorkFrame(1_000_000);
    }
    ctr.rss_bytes = 30 * 1024 * 1024;
    ctr.draw_calls = 4;
    ctr.gpu_ns = 2_000_000;
    ctr.upload_bytes = 128 * 1024;

    const rep = evaluate(b, &prof, &ctr, .game);
    try std.testing.expect(rep.allPass());
    try std.testing.expectEqual(@as(usize, 0), rep.failCount());
}

test "a slow zone fails its per-system budget" {
    const b = Budget{};
    var prof = Profiler{};
    var ctr = Counters{};
    prof.beginFrame(true);
    var z = prof.zone("render");
    core_time.sleepNs(20_000_000); // 20 ms of render: the §2 budget is 1.5 ms
    z.end();
    prof.endFrame();
    prof.pushWorkFrame(20_000_000);

    const rep = evaluate(b, &prof, &ctr, .game);
    try std.testing.expect(!rep.allPass());
    // the failing result must be the render one
    var found_fail = false;
    for (rep.results[0..rep.count]) |r| {
        if (std.mem.eql(u8, r.name, "render") and r.status == .fail) found_fail = true;
    }
    try std.testing.expect(found_fail);
}

test "zones that do not exist are reported as unknown, not as failure" {
    const b = Budget{};
    var prof = Profiler{};
    var ctr = Counters{};
    prof.beginFrame(true);
    prof.endFrame();
    prof.pushWorkFrame(100_000);
    const rep = evaluate(b, &prof, &ctr, .game);
    var lua_status: Status = .pass;
    for (rep.results[0..rep.count]) |r| {
        if (std.mem.eql(u8, r.name, "lua_update")) lua_status = r.status;
    }
    try std.testing.expectEqual(Status.unknown, lua_status);
}
