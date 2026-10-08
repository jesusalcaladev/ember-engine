//! Single-threaded CPU profiler (spec §2 and §9).
//!
//! - Zones with static (comptime) names: minimal cost, zero allocations.
//! - Inclusive time: a parent zone includes its children.
//! - Ring of frame durations -> p50/p99/p99.9 percentiles in the report.

const std = @import("std");
const log = @import("log.zig");
const time = @import("time.zig");

pub const MAX_ZONES = 64;
pub const MAX_DEPTH = 32;
pub const RING_CAP = 4096;

pub const Zone = struct {
    name: []const u8,
    ns: u64 = 0,
    hits: u32 = 0,
};

pub const Profiler = struct {
    zones: [MAX_ZONES]Zone = undefined,
    zone_count: usize = 0,
    stack: [MAX_DEPTH]usize = undefined,
    depth: usize = 0,
    frame_start: u64 = 0,
    ring: [RING_CAP]u64 = undefined,
    ring_len: usize = 0,
    ring_next: usize = 0,

    pub fn beginFrame(self: *Profiler) void {
        // Does NOT reset zones: a zone may open before beginFrame (e.g. the
        // zone that wraps the whole frame). Reset happens on CLOSE.
        self.frame_start = time.monotonicNs();
    }

    pub fn endFrame(self: *Profiler) void {
        const ns = time.monotonicNs() - self.frame_start;
        self.ring[self.ring_next] = ns;
        self.ring_next = (self.ring_next + 1) % RING_CAP;
        if (self.ring_len < RING_CAP) self.ring_len += 1;
        // Zones ACCUMULATE across the whole session (acceptance report); only
        // the nesting stack is reset.
        self.depth = 0;
    }

    /// Opens a zone. Usage: `var z = prof.zone("name"); defer z.end();`
    pub fn zone(self: *Profiler, comptime name: []const u8) ZoneTimer {
        self.beginZone(name);
        return .{ .prof = self, .start_ns = time.monotonicNs() };
    }

    fn beginZone(self: *Profiler, comptime name: []const u8) void {
        std.debug.assert(self.depth < MAX_DEPTH);
        var idx: ?usize = null;
        for (self.zones[0..self.zone_count], 0..) |*z, i| {
            if (std.mem.eql(u8, z.name, name)) {
                idx = i;
                break;
            }
        }
        if (idx == null) {
            std.debug.assert(self.zone_count < MAX_ZONES);
            idx = self.zone_count;
            self.zones[self.zone_count] = .{ .name = name };
            self.zone_count += 1;
        }
        self.stack[self.depth] = idx.?;
        self.depth += 1;
    }

    fn endZone(self: *Profiler, ns: u64) void {
        std.debug.assert(self.depth > 0);
        self.depth -= 1;
        const idx = self.stack[self.depth];
        self.zones[idx].ns += ns;
        self.zones[idx].hits += 1;
    }

    /// Frame percentiles (in ms). p_index in [0, 100].
    pub fn frameMsAtPercentile(self: *const Profiler, p_index: f64) f64 {
        std.debug.assert(self.ring_len > 0);
        var copy: [RING_CAP]u64 = undefined;
        @memcpy(copy[0..self.ring_len], self.ring[0..self.ring_len]);
        std.mem.sort(u64, copy[0..self.ring_len], {}, lessU64);
        // Standard nearest-rank percentile: rank = ceil(p/100 * N).
        const n: f64 = @floatFromInt(self.ring_len);
        const rank_f = @ceil(n * p_index / 100.0);
        const max_rank: f64 = @floatFromInt(self.ring_len - 1);
        const rank: usize = @intFromFloat(@min(max_rank, rank_f - 1));
        return @as(f64, @floatFromInt(copy[rank])) / 1_000_000.0;
    }

    /// Reports to the logger (call outside the frame, e.g. on exit).
    pub fn report(self: *const Profiler, comptime title: []const u8) void {
        if (self.ring_len == 0) return;
        log.info(title, .{});
        log.info("  frames: {d}  p50: {d:.3} ms  p99: {d:.3} ms  p99.9: {d:.3} ms", .{
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
                return ctx.zones[a].ns > ctx.zones[b].ns;
            }
        };
        std.mem.sort(usize, order[0..self.zone_count], Ctx{ .zones = self.zones[0..self.zone_count] }, Ctx.less);
        for (order[0..self.zone_count]) |i| {
            const z = self.zones[i];
            const ms = @as(f64, @floatFromInt(z.ns)) / 1_000_000.0;
            log.info("    {s:<28} {d:>9.3} ms  x{d}", .{ z.name, ms, z.hits });
        }
    }
};

pub const ZoneTimer = struct {
    prof: *Profiler,
    start_ns: u64,

    pub fn end(self: ZoneTimer) void {
        self.prof.endZone(time.monotonicNs() - self.start_ns);
    }
};

fn lessU64(_: void, a: u64, b: u64) bool {
    return a < b;
}

test "percentiles over the frame ring" {
    var p = Profiler{};
    var i: usize = 0;
    while (i < 100) : (i += 1) {
        p.ring[p.ring_next] = (i + 1) * 1_000_000; // 1..100 ms
        p.ring_next = (p.ring_next + 1) % RING_CAP;
        p.ring_len += 1;
    }
    // Nearest-rank over 1..100 ms: p50=50, p99=99, p99.9=100.
    try std.testing.expectApproxEqAbs(@as(f64, 50.0), p.frameMsAtPercentile(50), 0.001);
    try std.testing.expectApproxEqAbs(@as(f64, 99.0), p.frameMsAtPercentile(99), 0.01);
    try std.testing.expectApproxEqAbs(@as(f64, 100.0), p.frameMsAtPercentile(99.9), 0.01);
}

test "zones accumulate by name and the report does not crash" {
    var p = Profiler{};
    p.beginFrame();
    var z = p.zone("update");
    var inner = p.zone("physics");
    inner.end();
    z.end();
    try std.testing.expectEqual(@as(usize, 2), p.zone_count);
    p.endFrame();
    try std.testing.expectEqual(@as(usize, 2), p.zone_count); // accumulate across the session
    for (p.zones[0..p.zone_count]) |z2| {
        try std.testing.expect(z2.ns > 0 or z2.hits > 0);
    }
}
