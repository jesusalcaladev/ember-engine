//! CPU profiler: zones, exclusive time, per-zone stats, frame percentiles
//! and the counters the report needs (spec §2, §3 and §9).
//!
//! What changed from M0 and why:
//! - Zone lookup is now a comptime FNV-1a hash interned into a fixed
//!   open-addressed table: O(1) open/close. M0 scanned every zone comparing
//!   strings on every open, which was already the biggest single overhead of
//!   the profiler.
//! - Inclusive AND exclusive (self) time: closing a zone adds its duration to
//!   its parent's "child time", so self = inclusive - children, without
//!   instrumenting anything twice. This is what tells you where the time is,
//!   not just who was open.
//! - Per-zone history: a per-CALL histogram (O(1) update, no sort) giving
//!   p50/p99/p99.9 per zone, plus a per-FRAME timeline of the last
//!   HISTORY_FRAMES frames in µs. Without this, "when did this zone spike"
//!   is unanswerable: M0 only kept the total frame time.
//! - Counters: draw calls, passes, uploads, steps, arena bytes, RSS... so the
//!   report can print verdicts against spec.md instead of bare numbers.
//! - `enabled`: with it off, `zone()` costs a single predictable branch
//!   (§9: zero cost when disabled). No clock reads, no bookkeeping.
//! - Warm-up frames are excluded from the stats, and the report separates
//!   the vsync wait from real work (see `frameWorkMsAtPercentile`).
//!
//! Budget note: each zone costs two clock reads (~28 ns with the TSC clock,
//! ~50 ns with clock_gettime). Wrap work above ~200 ns in a zone; below that
//! the measurement costs more than the work.

const std = @import("std");
const log = @import("log.zig");
const time = @import("time.zig");

pub const MAX_ZONES = 128;
pub const MAX_DEPTH = 32;
/// Frames of per-zone timeline kept for the HUD/exporter (u16 µs each).
pub const HISTORY_FRAMES = 128;
/// Buckets of the per-call histogram; bucket i covers [2^(i-1), 2^i) µs.
pub const HIST_BUCKETS = 24;
pub const HIST_MAX_US: u64 = 1 << (HIST_BUCKETS - 1);
/// Exact frame-duration ring (nearest-rank percentiles come from here).
pub const RING_CAP = 4096;

const HASH_CAP = 256; // power of two, > MAX_ZONES
const EMPTY: u16 = 0xFFFF;

pub const Zone = struct {
    name: []const u8,
    hash: u32,

    // session totals (inclusive)
    ns_total: u64 = 0,
    hits: u64 = 0,
    ns_max: u64 = 0,
    // session totals (exclusive = inclusive - children)
    self_ns_total: u64 = 0,
    self_ns_max: u64 = 0,

    // current frame (reset every frame)
    ns_frame: u64 = 0,
    self_frame: u64 = 0,
    hits_frame: u32 = 0,

    // per-call inclusive histogram (µs) -> percentile per zone without sort
    hist: [HIST_BUCKETS]u32 = [_]u32{0} ** HIST_BUCKETS,
    // per-frame inclusive µs, circular
    timeline: [HISTORY_FRAMES]u16 = [_]u16{0} ** HISTORY_FRAMES,

    fn resetStats(self: *Zone) void {
        self.ns_total = 0;
        self.hits = 0;
        self.ns_max = 0;
        self.self_ns_total = 0;
        self.self_ns_max = 0;
        self.hist = [_]u32{0} ** HIST_BUCKETS;
        self.timeline = [_]u16{0} ** HISTORY_FRAMES;
    }
};

/// Engine-wide metrics. The frame loop writes here every frame; the report
/// and the tracer read them. Grouped so the runtime can reset them at once.
pub const Counters = struct {
    // --- frame pacing ---
    frame_index: u64 = 0,
    /// Whole loop iteration, INCLUDING present/vsync.
    frame_wall_ns: u64 = 0,
    /// frame_wall minus the present wait: the engine's actual work.
    frame_work_ns: u64 = 0,
    /// vsync/frame-present wait inside `present`.
    present_wait_ns: u64 = 0,
    /// Wait for the swapchain image (the actual vsync wait with Fifo).
    pacing_wait_ns: u64 = 0,
    /// Timestamp-readback diagnostics (spec §4): how many maps/reads.
    ts_maps: u64 = 0,
    ts_reads: u64 = 0,
    ts_bad: u64 = 0,
    ts_ranges: u64 = 0,
    ts_polls_ok: u64 = 0,

    // --- simulation ---
    fixed_steps: u32 = 0, // steps executed this frame
    fixed_steps_dropped: u32 = 0, // dropped by the anti-death-spiral rule (§3.3)
    fixed_steps_total: u64 = 0, // accumulated over the run (for the mean)
    fixed_steps_dropped_total: u64 = 0,
    accumulator_leftover_ns: u64 = 0,

    // --- render (from the backend's FrameStats) ---
    draw_calls: u64 = 0,
    render_passes: u64 = 0,
    pipeline_changes: u64 = 0,
    bind_group_changes: u64 = 0,
    vertex_count: u64 = 0,
    /// Staged uploads of this frame (spec §4: <= 2 MB/frame steady state).
    upload_bytes: u64 = 0,
    /// GPU frame time from timestamp queries (0 = unavailable).
    gpu_ns: u64 = 0,
    gpu_pass_count: u32 = 0,
    /// GPU objects created DURING the frame (must be 0: spec §3.6).
    gpu_resources_created: u64 = 0,

    // --- memory ---
    arena_used_bytes: u64 = 0,
    arena_high_water_bytes: u64 = 0,
    live_bytes: i64 = 0,
    /// High-water of the tracked (non-frame) allocator, from the tracker.
    peak_live_bytes: u64 = 0,
    alloc_allocs: u64 = 0,
    alloc_frees: u64 = 0,
    /// Tracked allocations performed DURING the frame (must be 0: §3.1).
    allocs_in_frame: u64 = 0,
    alloc_bytes_in_frame: u64 = 0,
    rss_bytes: u64 = 0,

    // --- threads (from the sampler) ---
    cpu_ticks_total: u64 = 0,
    cpu_ticks_main: u64 = 0,
    thread_count: u32 = 0,

    pub fn resetPerFrame(self: *Counters) void {
        self.fixed_steps = 0;
        self.fixed_steps_dropped = 0;
        self.present_wait_ns = 0;
        self.pacing_wait_ns = 0;
        self.draw_calls = 0;
        self.render_passes = 0;
        self.pipeline_changes = 0;
        self.bind_group_changes = 0;
        self.vertex_count = 0;
        self.upload_bytes = 0;
        self.gpu_ns = 0;
        self.gpu_resources_created = 0;
        self.allocs_in_frame = 0;
        self.alloc_bytes_in_frame = 0;
    }
};

pub const Profiler = struct {
    zones: [MAX_ZONES]Zone = undefined,
    zone_count: usize = 0,
    hash_slots: [HASH_CAP]u16 = [_]u16{EMPTY} ** HASH_CAP,

    timers: [MAX_DEPTH]ZoneTimer = undefined,
    stack: [MAX_DEPTH]StackEntry = undefined,
    depth: usize = 0,

    frame_start: u64 = 0,
    /// Duration of the frame body (beginFrame..endFrame), exact.
    frame_body_ns: u64 = 0,

    /// Exact frame-duration rings (the wall one includes present/vsync).
    ring: [RING_CAP]u64 = undefined,
    ring_len: usize = 0,
    ring_next: usize = 0,
    work_ring: [RING_CAP]u64 = undefined,
    work_ring_len: usize = 0,
    work_ring_next: usize = 0,

    frame_count: u64 = 0,
    stats_active: bool = false,
    recording: bool = false,
    /// False => zone() costs one branch (spec §9).
    enabled: bool = true,
    tl_next: usize = 0,
    tl_len: usize = 0,

    counters: Counters = .{},

    const StackEntry = struct {
        idx: u16,
        start_ns: u64,
        child_ns: u64,
    };

    /// A live zone handle. It points into the profiler's timer pool, so it
    /// is only valid until another zone opens at the SAME nesting depth:
    /// siblings reuse the slot. To read a zone's time later, use
    /// `zoneFrameNs`/`zoneIndexByName` — that is what the runtime does.
    pub const ZoneTimer = struct {
        prof: *Profiler,
        idx: u16 = EMPTY,
        start_ns: u64 = 0,
        /// Duration of this close. Valid right after `end()` (and until a
        /// sibling zone reuses the slot).
        ns: u64 = 0,

        /// Idempotent: closing twice is a no-op (M0 double-counted).
        pub fn end(self: *ZoneTimer) void {
            if (self.idx == EMPTY) return;
            self.prof.endZone(self.idx, self.start_ns, &self.ns);
            self.idx = EMPTY;
        }
    };

    pub fn beginFrame(self: *Profiler, record: bool) void {
        if (record and !self.stats_active) {
            // First measured frame after warm-up: previous frames are noise
            // (surface configure, first acquire, first page faults).
            for (self.zones[0..self.zone_count]) |*z| z.resetStats();
            self.stats_active = true;
        }
        self.recording = record;
        self.depth = 0;
        for (&self.timers) |*t| t.idx = EMPTY;
        for (self.zones[0..self.zone_count]) |*z| {
            z.ns_frame = 0;
            z.self_frame = 0;
            z.hits_frame = 0;
        }
        self.counters.resetPerFrame();
        self.frame_start = time.startNs();
    }

    pub fn endFrame(self: *Profiler) void {
        const end = time.monotonicNs();
        self.frame_body_ns = end - self.frame_start;
        self.frame_count += 1; // every frame, warm-up included (report + json)

        // A frame that leaves zones open is a bug in the instrumentation.
        // M0 silently reset the stack and lost the mismatch.
        std.debug.assert(self.depth == 0);
        for (&self.timers) |*t| t.idx = EMPTY;

        if (self.recording and self.stats_active) {
            self.pushFrame(self.frame_body_ns);
            for (self.zones[0..self.zone_count]) |*z| {
                const us: u64 = z.ns_frame / std.time.ns_per_us;
                z.timeline[self.tl_next] = if (us > 0xFFFF) 0xFFFF else @intCast(us);
            }
            self.tl_next = (self.tl_next + 1) % HISTORY_FRAMES;
            if (self.tl_len < HISTORY_FRAMES) self.tl_len += 1;
        }
        self.depth = 0;
    }

    fn pushFrame(self: *Profiler, ns: u64) void {
        self.ring[self.ring_next] = ns;
        self.ring_next = (self.ring_next + 1) % RING_CAP;
        if (self.ring_len < RING_CAP) self.ring_len += 1;
    }

    /// Same as above for the "work" frame (everything except the present
    /// wait). Called by the runtime right after endFrame.
    pub fn pushWorkFrame(self: *Profiler, ns: u64) void {
        if (!self.recording or !self.stats_active) return;
        self.work_ring[self.work_ring_next] = ns;
        self.work_ring_next = (self.work_ring_next + 1) % RING_CAP;
        if (self.work_ring_len < RING_CAP) self.work_ring_len += 1;
    }

    /// Opens a zone. Usage unchanged from M0:
    ///   `var z = prof.zone("input"); ... z.end();`
    /// Returns a pointer to an internal timer, so `end()` is idempotent and
    /// the nesting depth is bounded (asserted).
    pub fn zone(self: *Profiler, comptime name: []const u8) *ZoneTimer {
        if (!self.enabled) {
            // Reuse slot 0 for everyone: idx == EMPTY makes end() a no-op,
            // so nesting does not matter when disabled.
            const t = &self.timers[0];
            t.* = .{ .prof = self, .idx = EMPTY };
            return t;
        }
        const idx = self.intern(name);
        const start = time.startNs();
        std.debug.assert(self.depth < MAX_DEPTH);
        self.stack[self.depth] = .{ .idx = idx, .start_ns = start, .child_ns = 0 };
        self.depth += 1;
        const t = &self.timers[self.depth - 1];
        t.* = .{ .prof = self, .idx = idx, .start_ns = start };
        return t;
    }

    fn endZone(self: *Profiler, idx: u16, start_ns: u64, out_ns: ?*u64) void {
        std.debug.assert(self.depth > 0);
        self.depth -= 1;
        const entry = &self.stack[self.depth];
        std.debug.assert(entry.idx == idx);
        const ns = time.monotonicNs() - start_ns;
        if (out_ns) |o| o.* = ns;

        const z = &self.zones[idx];
        z.ns_total += ns;
        z.hits += 1;
        if (ns > z.ns_max) z.ns_max = ns;
        z.ns_frame += ns;
        z.hits_frame += 1;
        z.hist[histBucket(ns)] += 1;

        const self_ns = ns - entry.child_ns;
        z.self_frame += self_ns;
        z.self_ns_total += self_ns;
        if (self_ns > z.self_ns_max) z.self_ns_max = self_ns;

        if (self.depth > 0) self.stack[self.depth - 1].child_ns += ns;
    }

    /// Comptime FNV-1a + open addressing. The hash is computed at comptime,
    /// so the hot path is a mask + probe + one u32 compare.
    fn intern(self: *Profiler, comptime name: []const u8) u16 {
        const h = comptime fnv1a(name);
        var slot = h & (HASH_CAP - 1);
        while (true) {
            const entry = self.hash_slots[slot];
            if (entry == EMPTY) break;
            const idx = entry;
            if (self.zones[idx].hash == h and std.mem.eql(u8, self.zones[idx].name, name)) return idx;
            slot = (slot + 1) & (HASH_CAP - 1);
        }
        std.debug.assert(self.zone_count < MAX_ZONES);
        const fresh: u16 = @intCast(self.zone_count);
        self.zones[fresh] = .{ .name = name, .hash = h };
        self.hash_slots[slot] = fresh;
        self.zone_count += 1;
        return fresh;
    }

    // ── Accessors for the report / the tracer ──────────────────────────────

    pub fn zoneAt(self: *const Profiler, i: usize) *const Zone {
        return &self.zones[i];
    }

    /// Inclusive µs of a zone in frame `back` frames ago (0 = last frame).
    pub fn zoneTimelineUs(self: *const Profiler, i: usize, back: usize) f64 {
        if (back >= self.tl_len) return 0;
        const pos = (self.tl_next + HISTORY_FRAMES - 1 - back) % HISTORY_FRAMES;
        return @floatFromInt(self.zones[i].timeline[pos]);
    }

    /// Percentile (0..100) of a zone's per-call durations, in ms. Resolution
    /// is the histogram bucket (powers of two), which is plenty to rank zones.
    pub fn zoneMsAtPercentile(self: *const Profiler, i: usize, p: f64) f64 {
        const z = &self.zones[i];
        if (z.hits == 0) return 0;
        const n: f64 = @floatFromInt(z.hits);
        const rank_f = @ceil(n * p / 100.0);
        var rank: u64 = @intFromFloat(@min(@as(f64, @floatFromInt(z.hits)), rank_f));
        if (rank == 0) rank = 1;
        var acc: u64 = 0;
        for (z.hist, 0..) |count, b| {
            acc += count;
            if (acc >= rank) {
                return @as(f64, @floatFromInt(@as(u32, 1) << @as(u5, @intCast(b)))) / 1000.0;
            }
        }
        return @as(f64, @floatFromInt(1 << (HIST_BUCKETS - 1))) / 1000.0;
    }

    /// Percentile (0..100) of a zone's PER-FRAME inclusive time, in ms, from
    /// the exact timeline. This is what the per-system budgets of spec §2
    /// apply to (a zone can be entered several times per frame).
    pub fn zoneFrameMsAtPercentile(self: *const Profiler, i: usize, p: f64) f64 {
        if (self.tl_len == 0) return 0;
        var copy: [HISTORY_FRAMES]u16 = undefined;
        @memcpy(copy[0..self.tl_len], self.zones[i].timeline[0..self.tl_len]);
        std.mem.sort(u16, copy[0..self.tl_len], {}, lessU16);
        const n: f64 = @floatFromInt(self.tl_len);
        const rank_f = @ceil(n * p / 100.0);
        const max_rank: f64 = @floatFromInt(self.tl_len - 1);
        const rank: usize = @intFromFloat(@min(max_rank, rank_f - 1));
        return @as(f64, @floatFromInt(copy[rank])) / 1000.0;
    }

    /// Index of a zone by name, or null if it has never been opened.
    pub fn zoneIndexByName(self: *const Profiler, name: []const u8) ?usize {
        for (0..self.zone_count) |i| {
            if (std.mem.eql(u8, self.zones[i].name, name)) return i;
        }
        return null;
    }

    /// Inclusive ns of a zone in the last frame (the sum of its calls).
    pub fn zoneFrameNs(self: *const Profiler, i: usize) u64 {
        if (i >= self.zone_count) return 0;
        return self.zones[i].ns_frame;
    }

    /// Inclusive µs of every zone in the last frame, in interned order. The
    /// tracer only needs a memcpy away.
    pub fn frameZoneUs(self: *const Profiler, out: []u16) void {
        const n = @min(out.len, self.zone_count);
        for (0..n) |i| {
            const us = self.zones[i].ns_frame / std.time.ns_per_us;
            out[i] = if (us > 0xFFFF) 0xFFFF else @intCast(us);
        }
        for (n..out.len) |i| out[i] = 0;
    }

    /// Frame percentiles (ms) from the exact ring. Nearest-rank, as in M0.
    pub fn frameMsAtPercentile(self: *const Profiler, p_index: f64) f64 {
        return ringPercentile(&self.ring, self.ring_len, p_index);
    }

    /// Percentiles of the frame ring MINUS the present wait: this is the
    /// number the spec budgets apply to (the wall frame is vsync-bound).
    pub fn frameWorkMsAtPercentile(self: *const Profiler, p_index: f64) f64 {
        if (self.work_ring_len == 0) return 0;
        return ringPercentile(&self.work_ring, self.work_ring_len, p_index);
    }

    pub fn frameMsMin(self: *const Profiler) f64 {
        var m: u64 = std.math.maxInt(u64);
        for (self.ring[0..self.ring_len]) |v| m = @min(m, v);
        return @as(f64, @floatFromInt(m)) / 1_000_000.0;
    }

    pub fn frameMsMax(self: *const Profiler) f64 {
        var m: u64 = 0;
        for (self.ring[0..self.ring_len]) |v| m = @max(m, v);
        return @as(f64, @floatFromInt(m)) / 1_000_000.0;
    }

    pub fn frameMsMean(self: *const Profiler) f64 {
        if (self.ring_len == 0) return 0;
        var sum: u128 = 0;
        for (self.ring[0..self.ring_len]) |v| sum += v;
        return @as(f64, @floatFromInt(@as(u64, @intCast(sum / self.ring_len)))) / 1_000_000.0;
    }

    /// Human-readable report on the logger (kept from M0; the full report
    /// with counters and verdicts lives in core/report.zig).
    pub fn report(self: *const Profiler, comptime title: []const u8) void {
        if (self.ring_len == 0) return;
        log.info(title, .{});
        log.info("  frames: {d} (measured {d})  p50: {d:.3} ms  p99: {d:.3} ms  p99.9: {d:.3} ms", .{
            self.frame_count,
            self.ring_len,
            self.frameMsAtPercentile(50),
            self.frameMsAtPercentile(99),
            self.frameMsAtPercentile(99.9),
        });
        log.info("  zones (inclusive, sorted by time):", .{});
        var order: [MAX_ZONES]usize = undefined;
        for (0..self.zone_count) |i| order[i] = i;
        const Ctx = struct {
            zones: []const Zone,
            fn less(ctx: @This(), a: usize, b: usize) bool {
                return ctx.zones[a].ns_total > ctx.zones[b].ns_total;
            }
        };
        std.mem.sort(usize, order[0..self.zone_count], Ctx{ .zones = self.zones[0..self.zone_count] }, Ctx.less);
        for (order[0..self.zone_count]) |i| {
            const z = self.zones[i];
            const ms = @as(f64, @floatFromInt(z.ns_total)) / 1_000_000.0;
            log.info("    {s:<28} {d:>9.3} ms  x{d}", .{ z.name, ms, z.hits });
        }
    }
};

fn histBucket(ns: u64) usize {
    const us = ns / std.time.ns_per_us;
    if (us == 0) return 0;
    if (us >= HIST_MAX_US) return HIST_BUCKETS - 1;
    // floor(log2(us)) + 1: bucket b holds durations in [2^(b-1), 2^b) µs.
    const log2: usize = @intCast(std.math.log2_int(usize, @intCast(us)));
    return @min(HIST_BUCKETS - 1, log2 + 1);
}

fn fnv1a(comptime s: []const u8) u32 {
    var h: u32 = 0x811C9DC5;
    for (s) |c| {
        h ^= c;
        h *%= 16777619;
    }
    return h;
}

fn ringPercentile(samples: *const [RING_CAP]u64, len: usize, p_index: f64) f64 {
    std.debug.assert(len > 0);
    var copy: [RING_CAP]u64 = undefined;
    @memcpy(copy[0..len], samples[0..len]);
    std.mem.sort(u64, copy[0..len], {}, lessU64);
    const n: f64 = @floatFromInt(len);
    const rank_f = @ceil(n * p_index / 100.0);
    const max_rank: f64 = @floatFromInt(len - 1);
    const rank: usize = @intFromFloat(@min(max_rank, rank_f - 1));
    return @as(f64, @floatFromInt(copy[rank])) / 1_000_000.0;
}

fn lessU64(_: void, a: u64, b: u64) bool {
    return a < b;
}

fn lessU16(_: void, a: u16, b: u16) bool {
    return a < b;
}

test "zones: inclusive and exclusive time" {
    var p = Profiler{};
    p.beginFrame(true);
    {
        var outer = p.zone("outer");
        time.sleepNs(2_000_000); // 2 ms of the parent's own work
        {
            var inner = p.zone("inner");
            time.sleepNs(1_000_000); // 1 ms inside the child
            inner.end();
        }
        time.sleepNs(500_000);
        outer.end();
    }
    p.endFrame();

    try std.testing.expectEqual(@as(usize, 2), p.zone_count);
    const outer = p.zoneAt(0);
    const inner = p.zoneAt(1);
    try std.testing.expectEqualStrings("outer", outer.name);
    try std.testing.expectEqualStrings("inner", inner.name);
    try std.testing.expectEqual(@as(u64, 1), outer.hits);
    try std.testing.expectEqual(@as(u64, 1), inner.hits);
    // inclusive ~3.5 ms, self ~2.5 ms: children must be excluded
    try std.testing.expect(outer.ns_total >= 3_000_000);
    try std.testing.expect(outer.self_ns_total >= 2_000_000);
    try std.testing.expect(outer.self_ns_total < outer.ns_total);
    try std.testing.expect(inner.self_ns_total >= 1_000_000);
    try std.testing.expect(p.frameMsAtPercentile(50) > 3.0);
}

test "zone ids are stable and unique by name (interning)" {
    const names = comptime blk: {
        @setEvalBranchQuota(20_000);
        var arr: [MAX_ZONES][]const u8 = undefined;
        for (0..MAX_ZONES) |i| arr[i] = "zz" ++ std.fmt.comptimePrint("{d}", .{i});
        break :blk arr;
    };
    var p = Profiler{};
    p.beginFrame(true);
    inline for (names) |n| {
        var z = p.zone(n);
        z.end();
    }
    p.endFrame();
    try std.testing.expectEqual(@as(usize, MAX_ZONES), p.zone_count);

    // Reopening them all in the SAME frame reuses the same ids.
    const ids_before = p.zone_count;
    p.beginFrame(true);
    inline for (names) |n| {
        var z = p.zone(n);
        z.end();
    }
    p.endFrame();
    try std.testing.expectEqual(ids_before, p.zone_count);
}

test "percentiles over the frame ring (nearest-rank)" {
    var samples: [RING_CAP]u64 = undefined;
    var i: usize = 0;
    while (i < 100) : (i += 1) {
        samples[i] = (i + 1) * 1_000_000; // 1..100 ms
    }
    // Nearest-rank over 1..100 ms: p1=1, p50=50, p99=99, p99.9=100.
    try std.testing.expectApproxEqAbs(@as(f64, 1.0), ringPercentile(&samples, 100, 1), 0.001);
    try std.testing.expectApproxEqAbs(@as(f64, 50.0), ringPercentile(&samples, 100, 50), 0.001);
    try std.testing.expectApproxEqAbs(@as(f64, 99.0), ringPercentile(&samples, 100, 99), 0.01);
    try std.testing.expectApproxEqAbs(@as(f64, 100.0), ringPercentile(&samples, 100, 99.9), 0.01);
    try std.testing.expectApproxEqAbs(@as(f64, 100.0), ringPercentile(&samples, 100, 100), 0.01);
}

test "a single zone per-call percentile is bucket-consistent" {
    var p = Profiler{};
    p.beginFrame(true);
    var z = p.zone("x");
    time.sleepNs(3_000_000); // 3 ms
    z.end();
    p.endFrame();
    // 3 ms falls in the bucket [2^11, 2^12) µs = [2048, 4096): the reported
    // percentile is the bucket's upper edge, so it must be 4.096 ms.
    const p50 = p.zoneMsAtPercentile(0, 50);
    const p99 = p.zoneMsAtPercentile(0, 99);
    try std.testing.expectApproxEqAbs(@as(f64, 4.096), p50, 0.001);
    try std.testing.expectApproxEqAbs(@as(f64, 4.096), p99, 0.001);
    // ...but the exact min/max are kept separately, at full resolution.
    try std.testing.expect(p.zoneAt(0).ns_max >= 3_000_000);
    try std.testing.expect(p.zoneAt(0).ns_total >= 3_000_000);
}

test "profiling disabled: no zones, no ring, end() is a no-op" {
    var p = Profiler{};
    p.enabled = false;
    p.beginFrame(false);
    var z = p.zone("ghost");
    z.end();
    try std.testing.expectEqual(@as(usize, 0), p.zone_count);
    p.endFrame();
    try std.testing.expectEqual(@as(usize, 0), p.ring_len);
    try std.testing.expectEqual(@as(usize, 0), p.zone_count);
}

test "double close is a no-op" {
    var p = Profiler{};
    p.beginFrame(true);
    var z = p.zone("x");
    z.end();
    z.end(); // must not move the stack nor double-count
    try std.testing.expectEqual(@as(u64, 1), p.zoneAt(0).hits);
    p.endFrame();
}

test "warm-up frames are excluded from the stats" {
    var p = Profiler{};
    p.beginFrame(false);
    var a = p.zone("boot");
    a.end();
    p.endFrame();
    try std.testing.expectEqual(@as(usize, 0), p.ring_len);

    p.beginFrame(true);
    var b = p.zone("boot");
    b.end();
    p.endFrame();
    try std.testing.expectEqual(@as(usize, 1), p.ring_len);
    try std.testing.expectEqual(@as(u64, 1), p.zoneAt(0).hits);
}

test "timeline keeps the last HISTORY_FRAMES frames in µs" {
    var p = Profiler{};
    var f: usize = 0;
    while (f < HISTORY_FRAMES + 5) : (f += 1) {
        p.beginFrame(true);
        var z = p.zone("z");
        time.sleepNs(20_000); // 20 µs
        z.end();
        p.endFrame();
    }
    try std.testing.expectEqual(HISTORY_FRAMES, p.tl_len);
    try std.testing.expect(p.zoneTimelineUs(0, 0) >= 20); // latest frame
    try std.testing.expect(p.zoneTimelineUs(0, HISTORY_FRAMES) == 0); // out of range
}

test "work ring is filled by the runtime, wall ring separately" {
    var p = Profiler{};
    p.beginFrame(true);
    time.sleepNs(1_000_000);
    p.endFrame();
    p.pushWorkFrame(2_000_000);
    try std.testing.expectEqual(@as(usize, 1), p.work_ring_len);
    try std.testing.expectApproxEqAbs(@as(f64, 2.0), p.frameWorkMsAtPercentile(50), 0.01);
    try std.testing.expect(p.frameMsAtPercentile(50) >= 1.0);
}
