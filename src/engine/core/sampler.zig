//! Background process metrics: RSS, threads and CPU ticks (spec §5 and §2).
//!
//! Why a separate thread: reading /proc is blocking I/O, and blocking I/O in
//! the frame loop is forbidden (spec §3.4). So a low-priority thread samples
//! every `period_ms` and the frame loop only ever READS a coherent snapshot.
//!
//! The thread uses its own allocation-free file reads (fixed stack buffers)
//! and never touches the tracked allocator: the tracker panics on any
//! allocation while `in_frame` is set, and the frame loop sets that flag.
//!
//! Linux only in M0. On other targets every accessor returns zeros and the
//! frame loop is unchanged.

const std = @import("std");
const builtin = @import("builtin");
const core_time = @import("time.zig");

const linux = builtin.os.tag == .linux;

pub const CAP = 64; // samples kept (about 16 s at 250 ms)

pub const Sample = struct {
    t_ns: u64 = 0,
    rss_bytes: u64 = 0,
    /// utime + stime of the whole process, in clock ticks.
    cpu_total_ticks: u64 = 0,
    /// utime + stime of the main (engine) thread, in clock ticks.
    cpu_main_ticks: u64 = 0,
    thread_count: u32 = 0,
};

pub const Sampler = struct {
    thread: ?std.Thread = null,
    stop_flag: std.atomic.Value(bool) = .init(false),
    period_ms: u32 = 250,

    writes: std.atomic.Value(u64) = .init(0),
    samples: [CAP]Sample = [_]Sample{.{}} ** CAP,

    peak_rss: std.atomic.Value(u64) = .init(0),
    main_tid: i32 = 0,
    ticks_per_second: u64 = 100,
    page_size: u64 = 4096,
    alloc: std.mem.Allocator,

    /// Starts the sampling thread. Idempotent.
    pub fn start(self: *Sampler) !void {
        if (self.thread != null or !linux) return;
        self.stop_flag.store(false, .release);
        // Stack: glibc's pthread_create returns EINVAL for stacks below ~512 KB on
        // this machine (measured: 512 KB ok, 256 KB EINVAL). 1 MB is plenty for
        // two small /proc buffers.
        self.thread = try std.Thread.spawn(.{ .stack_size = 1 << 20 }, worker, .{self});
    }

    /// Stops it, taking a final sample. Safe to call without start().
    pub fn stop(self: *Sampler) void {
        if (!linux) return;
        self.stop_flag.store(true, .release);
        if (self.thread) |t| {
            t.join();
            self.thread = null;
        }
    }

    pub fn isRunning(self: *const Sampler) bool {
        return self.thread != null;
    }

    /// Number of samples a reader can safely see.
    fn visibleCount(self: *const Sampler) u64 {
        const total = self.writes.load(.acquire);
        return @min(total, CAP);
    }

    /// Most recent sample (zeros if there is none).
    pub fn latest(self: *const Sampler) Sample {
        if (!linux) return .{};
        const total = self.writes.load(.acquire);
        if (total == 0) return .{};
        return self.samples[(total - 1) % CAP];
    }

    /// Sample `back` frames before the last one (0 = last).
    pub fn history(self: *const Sampler, back: u64) Sample {
        const visible = self.visibleCount();
        if (back + 1 > visible) return .{};
        const total = self.writes.load(.acquire);
        const idx = (total - 1 - back) % CAP;
        return self.samples[idx];
    }

    pub fn historyLen(self: *const Sampler) u64 {
        return self.visibleCount();
    }

    pub fn peakRssBytes(self: *const Sampler) u64 {
        return self.peak_rss.load(.acquire);
    }

    /// CPU% of the whole process over the whole sampled window.
    pub fn cpuPercentTotal(self: *const Sampler) f64 {
        if (self.ticks_per_second == 0) return 0;
        const first = self.history(self.historyLen() - 1);
        const last = self.latest();
        if (last.t_ns <= first.t_ns) return 0;
        const ticks = last.cpu_total_ticks - first.cpu_total_ticks;
        const seconds_ns = @as(f64, @floatFromInt(last.t_ns - first.t_ns));
        // ticks -> seconds -> fraction -> percent. The x100 was missing and
        // the report was showing 0.87% for an 87% busy process.
        return @as(f64, @floatFromInt(ticks)) * 100.0 * 1_000_000_000.0 /
            seconds_ns / @as(f64, @floatFromInt(self.ticks_per_second));
    }

    /// CPU% of the engine (main) thread over the same window.
    pub fn cpuPercentMain(self: *const Sampler) f64 {
        if (self.ticks_per_second == 0) return 0;
        const first = self.history(self.historyLen() - 1);
        const last = self.latest();
        if (last.t_ns <= first.t_ns) return 0;
        const ticks = last.cpu_main_ticks - first.cpu_main_ticks;
        const seconds_ns = @as(f64, @floatFromInt(last.t_ns - first.t_ns));
        return @as(f64, @floatFromInt(ticks)) * 100.0 * 1_000_000_000.0 /
            seconds_ns / @as(f64, @floatFromInt(self.ticks_per_second));
    }

    /// One /proc read-through. Pure enough to be tested without a thread.
    pub fn readSnapshot(self: *const Sampler) Sample {
        if (!linux) return .{};
        var s: Sample = .{ .t_ns = coreTimeNs() };
        s.cpu_total_ticks = readProcStatTicks("/proc/self/stat");
        if (self.main_tid > 0) {
            s.cpu_main_ticks = readTidTicks(self.main_tid);
        } else {
            s.cpu_main_ticks = readProcStatTicks("/proc/self/stat");
        }
        readProcStatus(&s.rss_bytes, &s.thread_count);
        return s;
    }

    fn worker(self: *Sampler) void {
        while (!self.stop_flag.load(.acquire)) {
            self.publish(self.readSnapshot());
            core_time.sleepNs(@as(u64, self.period_ms) * std.time.ns_per_ms);
        }
        self.publish(self.readSnapshot());
    }

    fn publish(self: *Sampler, sample: Sample) void {
        const idx = self.writes.fetchAdd(1, .release) % CAP;
        self.samples[idx] = sample;
        if (sample.rss_bytes > self.peak_rss.load(.acquire)) {
            self.peak_rss.store(sample.rss_bytes, .release);
        }
    }
};

// ── /proc parsing (Linux, allocation-free: fixed stack buffers) ──────────────

const TIMESpec = extern struct { sec: isize, nsec: isize };
extern "c" fn clock_gettime(clk_id: c_int, tp: *TIMESpec) c_int;
extern "c" fn sysconf(name: c_int) c_long;
extern "c" fn gettid() c_int;
// libc file I/O: allocation-free, no std.Io plumbing (and /proc is Linux).
extern "c" fn open(path: [*:0]const u8, flags: c_int, ...) c_int;
extern "c" fn close(fd: c_int) c_int;
extern "c" fn read(fd: c_int, buf: [*]u8, count: usize) isize;

// Forces the externs above to be referenced from this file: they are only
// used behind a `linux` guard inside the module body.
comptime {
    _ = open;
    _ = close;
    _ = read;
}

const O_RDONLY: c_int = 0;
const SC_CLK_TCK: c_int = 2;
const SC_PAGESIZE: c_int = 30;
const CLOCK_MONOTONIC: c_int = 1;

pub fn createDefault(alloc: std.mem.Allocator) Sampler {
    return .{
        .alloc = alloc,
        .main_tid = if (linux) gettid() else 0,
        .ticks_per_second = if (linux) @intCast(sysconf(SC_CLK_TCK)) else 100,
        .page_size = if (linux) @intCast(sysconf(SC_PAGESIZE)) else 4096,
    };
}

fn coreTimeNs() u64 {
    var t: TIMESpec = undefined;
    if (clock_gettime(CLOCK_MONOTONIC, &t) != 0) return 0;
    return @as(u64, @intCast(t.sec)) *% 1_000_000_000 +% @as(u64, @intCast(t.nsec));
}

/// utime + stime of a stat file, in clock ticks. 0 on any failure.
fn readProcStatTicks(path: [*:0]const u8) u64 {
    var buf: [2048]u8 = undefined;
    const len = readFileInto(path, &buf) orelse return 0;
    return parseStatTicks(buf[0..len]);
}

fn readTidTicks(tid: i32) u64 {
    var buf: [2048]u8 = undefined;
    var path: [64]u8 = undefined;
    const p = std.fmt.bufPrintZ(&path, "/proc/self/task/{d}/stat", .{tid}) catch return 0;
    const len = readFileInto(p, &buf) orelse return 0;
    return parseStatTicks(buf[0..len]);
}

/// /proc/<pid>/stat: the comm field may contain spaces and parens, so we
/// parse from the LAST ')' onwards: after-comm index 11 = utime, 12 = stime.
fn parseStatTicks(text: []const u8) u64 {
    const comm_end = std.mem.lastIndexOfScalar(u8, text, ')') orelse return 0;
    var it = std.mem.tokenizeScalar(u8, text[comm_end + 1 ..], ' ');
    var i: usize = 0;
    var utime: u64 = 0;
    var stime: u64 = 0;
    while (it.next()) |field| : (i += 1) {
        switch (i) {
            11 => utime = std.fmt.parseInt(u64, field, 10) catch 0,
            12 => stime = std.fmt.parseInt(u64, field, 10) catch 0,
            else => {},
        }
    }
    return utime + stime;
}

/// /proc/self/status -> VmRSS (kB) and Threads. Allocation-free line parser.
fn readProcStatus(rss_out: *u64, threads_out: *u32) void {
    var buf: [4096]u8 = undefined;
    const len = readFileInto("/proc/self/status", &buf) orelse return;
    var lines = std.mem.splitSequence(u8, buf[0..len], "\n");
    while (lines.next()) |line| {
        if (std.mem.startsWith(u8, line, "VmRSS:")) {
            var kb: u64 = 0;
            parseTailUint(line[6..], &kb);
            rss_out.* = kb * 1024; // the status file reports kB
        } else if (std.mem.startsWith(u8, line, "Threads:")) {
            var threads: u64 = 0;
            parseTailUint(line[8..], &threads);
            threads_out.* = @intCast(@min(threads, 65535));
        }
    }
}

fn parseTailUint(text: []const u8, out: *u64) void {
    // /proc/self/status separates the key from the value with a TAB.
    var it = std.mem.tokenizeAny(u8, text, " \t\r");
    while (it.next()) |field| {
        if (field.len == 0) continue;
        if (field[0] < '0' or field[0] > '9') continue;
        out.* = std.fmt.parseInt(u64, field, 10) catch 0;
        return;
    }
}

fn readFileInto(path: [*:0]const u8, buf: []u8) ?usize {
    const fd = open(path, O_RDONLY);
    if (fd < 0) return null;
    defer _ = close(fd);
    const n = read(fd, buf.ptr, buf.len);
    if (n < 0) return null;
    return @intCast(n);
}

test "proc parsers return sane values" {
    if (!linux) return;
    const s = createDefault(std.testing.allocator);
    const ticks = readProcStatTicks("/proc/self/stat");
    try std.testing.expect(ticks > 0); // the test process has burned CPU

    var rss: u64 = 0;
    var threads: u32 = 0;
    readProcStatus(&rss, &threads);
    try std.testing.expect(rss > 1024 * 1024); // a test process is never under 1 MB
    try std.testing.expect(threads >= 1);
    try std.testing.expect(s.ticks_per_second >= 10);
    try std.testing.expect(s.main_tid > 0);
}

test "sampler thread publishes samples and peak rss" {
    if (!linux) return;
    var s = createDefault(std.testing.allocator);
    s.period_ms = 5;
    try s.start();
    core_time.sleepNs(60_000_000); // 60 ms
    s.stop();

    try std.testing.expect(s.historyLen() >= 2);
    const last = s.latest();
    try std.testing.expect(last.t_ns > 0);
    try std.testing.expect(last.rss_bytes > 0);
    try std.testing.expect(last.thread_count >= 1);
    try std.testing.expect(last.cpu_total_ticks > 0);
    try std.testing.expect(s.peakRssBytes() >= last.rss_bytes);
    // The main thread must have consumed some CPU in the sampler's own window.
    try std.testing.expect(last.cpu_main_ticks > 0);
    // History is ordered (older first).
    const older = s.history(s.historyLen() - 1);
    try std.testing.expect(last.t_ns >= older.t_ns);
    // The window spans at least one sample: the CPU% must be a percentage,
    // not a fraction (a busy process must read above 1%, not 0.87%).
    const cpu = s.cpuPercentTotal();
    try std.testing.expect(cpu > 1.0 or cpu == 0.0);
}
