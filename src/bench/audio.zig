//! Benchmark for M8 audio. Run with `zig build bench-audio`.
//!
//! The ROADMAP criterion is "64 simultaneous emitters with no main-thread
//! spikes; latency ≤ 20 ms", and it is enforced here as numbers a machine can
//! fail against:
//!
//!   - **64 emitters actually playing**, via `voices_peak` (the peak count, not
//!     the instantaneous one — the whole point is that they overlapped).
//!   - **Zero allocations on the main-thread path.** A counting allocator wraps
//!     the system allocator and the frame path (`play` + `pump`) must not move
//!     the count: no decoding, no growing a queue, no temporary tables.
//!   - **Latency** derived from the negotiated period (`Stats.latencyMs`).
//!   - **The mix cost per buffer**, so a regression in the inner loop is
//!     visible rather than inferred.
//!
//! It runs on the NULL backend, so it needs no sound card and produces the same
//! answer on any machine — which is what makes it a CI gate instead of a local
//! ritual.

const std = @import("std");
const audio = @import("audio");
const core = @import("core");

/// Wraps the real allocator and counts allocations. `resize`/`remap`/`free`
/// are delegated without counting, so the check is "does the frame path allocate"
/// and not "does it ever touch the allocator", which is the question that
/// matters.
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

const emitters: usize = 64;
const buffers_measured: usize = 200;
const period_frames: u32 = 480;

pub fn main() !void {
    var counting = Counting{ .child = std.heap.c_allocator };
    const alloc = counting.allocator();

    const cfg = audio.Config{
        .desc = .{ .sample_rate = 48000, .period_frames = period_frames, .channels = 2 },
        .voices = 256,
        .budget_bytes = 16 << 20,
    };
    const sys = try audio.Audio.create(alloc, .null, cfg);
    defer sys.destroy();

    // Load one sound (this MAY allocate: it decodes).
    const slot = try sys.load("boom:4800"); // 100 ms at 48 kHz
    const allocations_after_load = counting.allocations;

    // ── Frame path: 64 emitters, then their buffers ─────────────────────────
    var t0 = core.time.monotonicNs();
    for (0..emitters) |i| {
        const x = @as(f32, @floatFromInt(i)) * 8.0 - 256.0;
        _ = sys.play(slot, .{
            .x = x,
            .y = 0,
            .spread = 400,
            .max_distance = 800,
            .loop = true,
        });
    }
    const play_ns = core.time.monotonicNs() - t0;
    const allocations_after_play = counting.allocations;
    if (allocations_after_play != allocations_after_load) {
        std.debug.print("FAIL: play() allocated on the main thread (frame path must not)\n", .{});
        return error.AllocatedInFrame;
    }

    t0 = core.time.monotonicNs();
    for (0..buffers_measured) |_| sys.pump(period_frames);
    const mix_ns = core.time.monotonicNs() - t0;
    const allocations_after_mix = counting.allocations;
    if (allocations_after_mix != allocations_after_play) {
        std.debug.print("FAIL: the mix path allocated\n", .{});
        return error.AllocatedInFrame;
    }

    const st = sys.stats();
    const per_buffer_us = @as(f64, @floatFromInt(mix_ns)) / buffers_measured / 1000.0;
    const play_us = @as(f64, @floatFromInt(play_ns)) / emitters / 1000.0;
    const budget_us = @as(f64, @floatFromInt(period_frames)) /
        @as(f64, @floatFromInt(st.sample_rate)) * 1_000_000.0;

    std.debug.print(
        \\
        \\== M8 audio (null backend, {d} emitters) ==
        \\  play() on the main thread      {d:.2} us/voice   ({d} total)
        \\  mix per {d}-frame buffer        {d:.1} us  (budget {d:.0} us)
        \\  voices_peak                    {d}
        \\  latency                        {d:.2} ms
        \\  xruns                          {d}
        \\  allocations on the frame path  0
        \\
    , .{
        emitters,
        play_us,
        emitters,
        period_frames,
        per_buffer_us,
        budget_us,
        st.voices_peak,
        st.latencyMs(),
        st.xruns,
    });

    var ok = true;
    if (st.voices_peak < emitters) {
        std.debug.print("FAIL: peak active was {d}, expected >= {d}\n", .{ st.voices_peak, emitters });
        ok = false;
    }
    if (st.latencyMs() > 20.0) {
        std.debug.print("FAIL: latency {d:.2} ms exceeds the 20 ms budget\n", .{st.latencyMs()});
        ok = false;
    }
    if (st.xruns != 0) {
        std.debug.print("FAIL: {d} xruns, expected 0\n", .{st.xruns});
        ok = false;
    }
    if (per_buffer_us > budget_us) {
        std.debug.print("FAIL: the mix missed its buffer deadline ({d:.1} us > {d:.0} us)\n", .{ per_buffer_us, budget_us });
        ok = false;
    }
    if (!ok) return error.BudgetMissed;
    std.debug.print("all M8 audio criteria passed\n", .{});
}
