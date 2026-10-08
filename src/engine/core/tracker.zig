//! Tracked allocator (spec §5 and §3.1).
//!
//! Counts allocs/frees/live bytes for the memory report and, while
//! `in_frame` is on, forbids allocating through it inside the frame loop:
//! all transient memory must come from the frame arena. That way the
//! "zero allocations in the frame loop" invariant is verified, not hoped for.

const std = @import("std");

pub const TrackedAllocator = struct {
    child: std.mem.Allocator,
    count_allocs: u64 = 0,
    count_frees: u64 = 0,
    live_bytes: i64 = 0,
    peak_live_bytes: usize = 0,
    in_frame: bool = false,

    const vtable = std.mem.Allocator.VTable{
        .alloc = allocFn,
        .resize = resizeFn,
        .remap = remapFn,
        .free = freeFn,
    };

    pub fn allocator(self: *TrackedAllocator) std.mem.Allocator {
        return .{ .ptr = self, .vtable = &vtable };
    }

    pub fn beginFrame(self: *TrackedAllocator) void {
        self.in_frame = true;
    }

    pub fn endFrame(self: *TrackedAllocator) void {
        self.in_frame = false;
        if (self.live_bytes > 0) {
            const live: usize = @intCast(self.live_bytes);
            if (live > self.peak_live_bytes) self.peak_live_bytes = live;
        }
    }

    fn allocFn(ctx: *anyopaque, len: usize, alignment: std.mem.Alignment, ret_addr: usize) ?[*]u8 {
        const self: *TrackedAllocator = @ptrCast(@alignCast(ctx));
        if (self.in_frame) {
            std.debug.panic("allocation of {} bytes outside the frame arena during the frame", .{len});
        }
        const mem = self.child.rawAlloc(len, alignment, ret_addr) orelse return null;
        self.count_allocs += 1;
        self.live_bytes += @intCast(len);
        return mem;
    }

    fn resizeFn(ctx: *anyopaque, memory: []u8, alignment: std.mem.Alignment, new_len: usize, ret_addr: usize) bool {
        const self: *TrackedAllocator = @ptrCast(@alignCast(ctx));
        if (!self.child.rawResize(memory, alignment, new_len, ret_addr)) return false;
        self.live_bytes += @as(i64, @intCast(new_len)) - @as(i64, @intCast(memory.len));
        return true;
    }

    fn remapFn(ctx: *anyopaque, memory: []u8, alignment: std.mem.Alignment, new_len: usize, ret_addr: usize) ?[*]u8 {
        const self: *TrackedAllocator = @ptrCast(@alignCast(ctx));
        const mem = self.child.rawRemap(memory, alignment, new_len, ret_addr) orelse return null;
        self.live_bytes += @as(i64, @intCast(new_len)) - @as(i64, @intCast(memory.len));
        return mem;
    }

    fn freeFn(ctx: *anyopaque, memory: []u8, alignment: std.mem.Alignment, ret_addr: usize) void {
        const self: *TrackedAllocator = @ptrCast(@alignCast(ctx));
        self.child.rawFree(memory, alignment, ret_addr);
        self.count_frees += 1;
        self.live_bytes -= @intCast(memory.len);
    }
};

test "counts allocs, frees and live bytes" {
    var tracked = TrackedAllocator{ .child = std.heap.page_allocator };
    const a = tracked.allocator();

    const buf = try a.alloc(u8, 256);
    try std.testing.expectEqual(@as(u64, 1), tracked.count_allocs);
    try std.testing.expectEqual(@as(i64, 256), tracked.live_bytes);

    const bigger = try a.realloc(buf, 512);
    try std.testing.expectEqual(@as(i64, 512), tracked.live_bytes);

    a.free(bigger);
    try std.testing.expectEqual(@as(u64, 1), tracked.count_frees);
    try std.testing.expectEqual(@as(i64, 0), tracked.live_bytes);
}

test "peak live bytes recorded when the frame closes" {
    var tracked = TrackedAllocator{ .child = std.heap.page_allocator };
    const a = tracked.allocator();

    // Boot allocations go BEFORE beginFrame: inside the frame this allocator
    // forbids allocating (that is the spec's invariant).
    const buf = try a.alloc(u8, 100);
    tracked.beginFrame();
    tracked.endFrame();
    try std.testing.expectEqual(@as(usize, 100), tracked.peak_live_bytes);
    a.free(buf);
}
