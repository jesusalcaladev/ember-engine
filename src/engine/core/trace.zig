//! Frame trace: per-frame recording of what the profiler measured, exported
//! as Chrome Trace Events (Perfetto) JSON.
//!
//! Why a separate ring: the profiler keeps the last 128 frames for the HUD,
//! but a "when did it spike" investigation needs the whole sequence. This
//! ring is allocated at start (from the boot allocator, outside the frame
//! loop) so recording one frame is a memcpy away.
//!
//! The file is written on demand and ALWAYS outside the frame loop: blocking
//! I/O inside the frame is forbidden (spec §3.4).
//!
//! Output format: Chrome Trace Events — open it in ui.perfetto.dev (or
//! chrome://tracing) for a zoomable timeline with counters. Zero deps.

const std = @import("std");
const profiler_mod = @import("profiler.zig");
const json = @import("json.zig");

const Profiler = profiler_mod.Profiler;

/// Frames kept by default. The trace is a ring: the LAST `frame_cap` frames.
pub const DEFAULT_FRAME_CAP = 2048;

pub const Meta = struct {
    backend: []const u8 = "unknown",
    clock: []const u8 = "unknown",
    tsc_hz: u64 = 0,
    cpu_model: []const u8 = "unknown",
    width: u32 = 0,
    height: u32 = 0,
    frames_total: u64 = 0,
    frames_warmup: u64 = 0,
};

pub const Trace = struct {
    alloc: std.mem.Allocator,
    frame_cap: usize,
    zone_count: usize,

    /// Copies of the zone names (the profiler's are static anyway, but a
    /// trace must be self-describing).
    names: [][]const u8 = &.{},
    frame_index: []u64 = &.{},
    wall_ns: []u64 = &.{},
    work_ns: []u64 = &.{},
    steps: []u8 = &.{},
    dropped: []u8 = &.{},
    draw_calls: []u16 = &.{},
    gpu_ns: []u32 = &.{},
    zones: []u16 = &.{}, // frame_cap * zone_count (inclusive µs per frame)

    next: usize = 0,
    len: usize = 0,
    total: u64 = 0,

    /// Allocates the ring. Called OUTSIDE the frame loop.
    pub fn init(alloc: std.mem.Allocator, frame_cap: usize, prof: *const Profiler) !Trace {
        const names = try alloc.alloc([]const u8, prof.zone_count);
        for (names, 0..) |*n, i| n.* = prof.zones[i].name;

        const cap = if (frame_cap == 0) DEFAULT_FRAME_CAP else frame_cap;
        return .{
            .alloc = alloc,
            .frame_cap = cap,
            .zone_count = prof.zone_count,
            .names = names,
            .frame_index = try alloc.alloc(u64, cap),
            .wall_ns = try alloc.alloc(u64, cap),
            .work_ns = try alloc.alloc(u64, cap),
            .steps = try alloc.alloc(u8, cap),
            .dropped = try alloc.alloc(u8, cap),
            .draw_calls = try alloc.alloc(u16, cap),
            .gpu_ns = try alloc.alloc(u32, cap),
            .zones = try alloc.alloc(u16, cap * @max(prof.zone_count, 1)),
        };
    }

    pub fn deinit(self: *Trace) void {
        const alloc = self.alloc;
        if (self.names.len > 0) alloc.free(self.names);
        if (self.frame_index.len > 0) alloc.free(self.frame_index);
        if (self.wall_ns.len > 0) alloc.free(self.wall_ns);
        if (self.work_ns.len > 0) alloc.free(self.work_ns);
        if (self.steps.len > 0) alloc.free(self.steps);
        if (self.dropped.len > 0) alloc.free(self.dropped);
        if (self.draw_calls.len > 0) alloc.free(self.draw_calls);
        if (self.gpu_ns.len > 0) alloc.free(self.gpu_ns);
        if (self.zones.len > 0) alloc.free(self.zones);
        self.* = .{ .alloc = alloc, .frame_cap = 0, .zone_count = 0 };
    }

    /// Records one frame. Cheap: fixed-size writes, no branches over zones.
    pub fn record(
        self: *Trace,
        frame_index: u64,
        wall_ns: u64,
        work_ns: u64,
        steps: u8,
        dropped: u8,
        draw_calls: u16,
        gpu_ns: u32,
        zone_us: []const u16,
    ) void {
        const i = self.next;
        self.frame_index[i] = frame_index;
        self.wall_ns[i] = wall_ns;
        self.work_ns[i] = work_ns;
        self.steps[i] = steps;
        self.dropped[i] = dropped;
        self.draw_calls[i] = draw_calls;
        self.gpu_ns[i] = gpu_ns;
        const n = @min(zone_us.len, self.zone_count);
        @memcpy(self.zones[i * self.zone_count ..][0..n], zone_us[0..n]);
        for (n..self.zone_count) |z| self.zones[i * self.zone_count + z] = 0;

        self.next = (self.next + 1) % self.frame_cap;
        if (self.len < self.frame_cap) self.len += 1;
        self.total += 1;
    }

    /// Writes the Chrome/Perfetto trace. Returns an error on I/O problems.
    pub fn writePerfetto(self: *const Trace, path: [*:0]const u8, meta: Meta) !void {
        var w = try json.Writer.create(path);
        defer w.deinit();

        w.raw("{\"traceEvents\":[");

        // Base timestamp so the numbers stay small and positive.
        const t0: u64 = if (self.len > 0) self.wallAt(0) else 0;

        var i: usize = 0;
        while (i < self.len) : (i += 1) {
            const slot = self.slotAt(i);
            const ts = (self.wall_ns[slot] -| t0) / 1000; // ns -> µs
            const dur = self.wall_ns[slot] / 1000;
            const work = self.work_ns[slot] / 1000;

            if (i != 0) w.raw(",");
            w.raw("{\"ph\":\"X\",\"name\":\"frame\",\"pid\":1,\"tid\":1,\"ts\":");
            w.num(ts);
            w.raw(",\"dur\":");
            w.num(dur);
            w.raw("}");

            if (work != dur) {
                w.raw(",{\"ph\":\"X\",\"name\":\"work\",\"pid\":1,\"tid\":2,\"ts\":");
                w.num(ts);
                w.raw(",\"dur\":");
                w.num(work);
                w.raw("}");
            }
            if (self.gpu_ns[slot] > 0) {
                w.raw(",{\"ph\":\"X\",\"name\":\"gpu\",\"pid\":1,\"tid\":3,\"ts\":");
                w.num(ts);
                w.raw(",\"dur\":");
                w.num(self.gpu_ns[slot]);
                w.raw("}");
            }
            const zones = self.zones[slot * self.zone_count ..][0..self.zone_count];
            for (zones, 0..) |zus, z| {
                if (zus == 0) continue;
                w.raw(",{\"ph\":\"X\",\"name\":");
                w.str(self.names[z]);
                w.raw(",\"pid\":1,\"tid\":4,\"ts\":");
                w.num(ts);
                w.raw(",\"dur\":");
                w.num(zus);
                w.raw("}");
            }
            // counters (ts is the frame start)
            w.raw(",{\"ph\":\"C\",\"pid\":1,\"tid\":5,\"ts\":");
            w.num(ts);
            w.raw(",\"args\":{\"steps\":");
            w.num(self.steps[slot]);
            w.raw(",\"dropped\":");
            w.num(self.dropped[slot]);
            if (self.draw_calls[slot] > 0) {
                w.raw(",\"draw_calls\":");
                w.num(self.draw_calls[slot]);
            }
            w.raw("}}");
        }

        w.raw("],\"displayTimeUnit\":\"ms\",\"otherData\":{");
        w.raw("\"backend\":");
        w.str(meta.backend);
        w.raw(",\"clock\":");
        w.str(meta.clock);
        w.raw(",\"frames\":");
        w.num(meta.frames_total);
        w.raw(",\"warmup\":");
        w.num(meta.frames_warmup);
        w.raw(",\"recorded\":");
        w.num(self.total);
        w.raw(",\"zones\":");
        w.num(self.zone_count);
        w.raw(",\"cpu_model\":");
        w.str(meta.cpu_model);
        w.raw(",\"resolution\":\"");
        w.num(meta.width);
        w.rawByte('x');
        w.num(meta.height);
        w.raw("\"}}");
        if (!w.ok()) return error.WriteFailed;
    }

    fn slotAt(self: *const Trace, i: usize) usize {
        // ring order: oldest first
        if (self.len < self.frame_cap) return i;
        return (self.next + i) % self.frame_cap;
    }

    fn wallAt(self: *const Trace, i: usize) u64 {
        return self.wall_ns[self.slotAt(i)];
    }
};

test "trace records frames and wraps like a ring" {
    var buf: [8192]u8 = [_]u8{0} ** 8192;
    var arena = std.heap.FixedBufferAllocator.init(&buf);
    const alloc = arena.allocator();

    var prof = Profiler{};
    prof.beginFrame(true);
    var z = prof.zone("render");
    z.end();
    prof.endFrame();

    var t = try Trace.init(alloc, 3, &prof);
    defer t.deinit();

    var zone_us: [profiler_mod.MAX_ZONES]u16 = undefined;
    var i: usize = 0;
    while (i < 5) : (i += 1) {
        prof.frameZoneUs(&zone_us);
        t.record(i, 1_000_000 * (i + 1), 900_000, 1, 0, 1, 500, &zone_us);
    }
    try std.testing.expectEqual(@as(usize, 3), t.len);
    try std.testing.expectEqual(@as(u64, 5), t.total);
    // the oldest recorded frame is now the 3rd one
    try std.testing.expectEqual(@as(u64, 2), t.frame_index[t.slotAt(0)]);
    try std.testing.expectEqual(@as(u64, 4), t.frame_index[t.slotAt(2)]);
    try std.testing.expectEqual(@as(u64, 900_000), t.work_ns[t.slotAt(2)]);
}

test "perfetto export contains frames, zones and counters" {
    var buf: [8192]u8 = [_]u8{0} ** 8192;
    var arena = std.heap.FixedBufferAllocator.init(&buf);
    const alloc = arena.allocator();

    var prof = Profiler{};
    prof.beginFrame(true);
    var z = prof.zone("render");
    prof_time.sleepNs(2_000_000); // 2 ms, so the µs field is non-zero
    z.end();
    prof.endFrame();

    var t = try Trace.init(alloc, 8, &prof);
    defer t.deinit();
    var zone_us: [profiler_mod.MAX_ZONES]u16 = undefined;
    prof.frameZoneUs(&zone_us);
    t.record(7, 2_000_000, 1_500_000, 1, 0, 1, 2_000, &zone_us);

    const path = "/tmp/ember-trace-test.json";
    try t.writePerfetto(path, .{ .backend = "null", .clock = "tsc" });
    defer {
        _ = unlink(path);
    }

    var out: [4096]u8 = undefined;
    const n = json.readWholeFile(path, &out) orelse return error.SkipZigTest;
    const text = out[0..n];
    try std.testing.expect(std.mem.indexOf(u8, text, "\"traceEvents\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "\"name\":\"frame\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "\"name\":\"render\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "\"draw_calls\":1") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "\"dur\":2000") != null); // gpu µs
    try std.testing.expect(std.mem.indexOf(u8, text, "\"displayTimeUnit\"") != null);
    // closes properly
    try std.testing.expect(text[text.len - 1] == '}');
}

const prof_time = @import("time.zig");
extern "c" fn unlink(path: [*:0]const u8) c_int;
