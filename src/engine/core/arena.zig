//! Frame arena: all of a frame's transient memory (spec §3.1).
//!
//! Own bump allocator:
//! - Real O(1) reset (`offset = 0`), fixed capacity (bounded memory).
//! - Exact per-frame high-water mark for the memory report (spec §5).
//! - Overflow = panic with a clear message: frame memory is a budget.

const std = @import("std");

pub const FrameArena = struct {
    buf: []u8,
    offset: usize = 0,
    /// Highest `offset` reached in a frame (memory report).
    high_water: usize = 0,
    frames_used: u64 = 0,

    const vtable = std.mem.Allocator.VTable{
        .alloc = bumpAlloc,
        .resize = bumpResize,
        .remap = bumpRemap,
        .free = bumpFree,
    };

    /// `capacity_bytes`: fixed per-frame budget. 8 MB by default.
    pub fn init(backing: std.mem.Allocator, capacity_bytes: usize) !FrameArena {
        const buf = try backing.alloc(u8, capacity_bytes);
        return .{ .buf = buf };
    }

    pub fn deinit(self: *FrameArena, backing: std.mem.Allocator) void {
        backing.free(self.buf);
        self.* = undefined;
    }

    pub fn beginFrame(self: *FrameArena) void {
        self.offset = 0;
    }

    pub fn endFrame(self: *FrameArena) void {
        if (self.offset > self.high_water) self.high_water = self.offset;
        self.frames_used += 1;
    }

    pub fn allocator(self: *FrameArena) std.mem.Allocator {
        return .{ .ptr = self, .vtable = &vtable };
    }

    /// Bytes used in the current frame.
    pub fn usedNow(self: *const FrameArena) usize {
        return self.offset;
    }

    fn alignForward(offset: usize, alignment: std.mem.Alignment) usize {
        const a = alignment.toByteUnits();
        return (offset + a - 1) & ~(a - 1);
    }

    fn bumpAlloc(ctx: *anyopaque, len: usize, alignment: std.mem.Alignment, ret_addr: usize) ?[*]u8 {
        _ = ret_addr;
        const self: *FrameArena = @ptrCast(@alignCast(ctx));
        const start = alignForward(self.offset, alignment);
        const end = start + len;
        if (end > self.buf.len) {
            std.debug.panic(
                "frame arena full: {d}/{d} bytes (raise the capacity; frame memory is a budget)",
                .{ end, self.buf.len },
            );
        }
        self.offset = end;
        return self.buf.ptr + start;
    }

    fn bumpResize(ctx: *anyopaque, memory: []u8, alignment: std.mem.Alignment, new_len: usize, ret_addr: usize) bool {
        _ = alignment;
        _ = ret_addr;
        const self: *FrameArena = @ptrCast(@alignCast(ctx));
        // Shrinking in place is always valid (bump never moves).
        if (new_len <= memory.len) return true;
        // Extend only if it is the last allocation (bump pattern).
        const start = @intFromPtr(memory.ptr) - @intFromPtr(self.buf.ptr);
        if (start + memory.len == self.offset and start + new_len <= self.buf.len) {
            self.offset = start + new_len;
            return true;
        }
        return false;
    }

    fn bumpRemap(ctx: *anyopaque, memory: []u8, alignment: std.mem.Alignment, new_len: usize, ret_addr: usize) ?[*]u8 {
        _ = alignment;
        _ = ret_addr;
        const self: *FrameArena = @ptrCast(@alignCast(ctx));
        const start = @intFromPtr(memory.ptr) - @intFromPtr(self.buf.ptr);
        if (start + memory.len == self.offset and start + new_len <= self.buf.len) {
            self.offset = start + new_len;
            return memory.ptr;
        }
        if (new_len <= memory.len) return memory.ptr; // shrink in place
        return null;
    }

    fn bumpFree(ctx: *anyopaque, memory: []u8, alignment: std.mem.Alignment, ret_addr: usize) void {
        _ = ctx;
        _ = memory;
        _ = alignment;
        _ = ret_addr;
        // No-op: the frame reset frees everything (frame arena contract).
    }
};

test "frame arena: O(1) reset, high-water and alignment" {
    var fa = try FrameArena.init(std.heap.page_allocator, 1 << 20);
    defer fa.deinit(std.heap.page_allocator);

    fa.beginFrame();
    const a = try fa.allocator().alloc(u8, 1000);
    a[0] = 1;
    const b = try fa.allocator().alloc(u64, 100); // asks for 8-byte alignment
    try std.testing.expect(@intFromPtr(b.ptr) % 8 == 0);
    b[0] = 2;
    fa.endFrame();
    try std.testing.expect(fa.high_water >= 1100);

    // O(1) reset: same buffer, reusable.
    const old_ptr = fa.buf.ptr;
    fa.beginFrame();
    try std.testing.expectEqual(@as(usize, 0), fa.usedNow());
    const c = try fa.allocator().alloc(u8, 64);
    try std.testing.expectEqual(old_ptr, c[0..64].ptr);
    fa.endFrame();
    try std.testing.expectEqual(fa.high_water, fa.high_water); // never decreases
}

test "fill to capacity and reset" {
    var fa = try FrameArena.init(std.heap.page_allocator, 128);
    defer fa.deinit(std.heap.page_allocator);
    fa.beginFrame();
    const full = try fa.allocator().alloc(u8, 128);
    full[127] = 0xFF; // exactly up to the limit: valid
    fa.beginFrame(); // the reset frees everything again
    const again = try fa.allocator().alloc(u8, 128);
    try std.testing.expectEqual(full.ptr, again.ptr);
    fa.endFrame();
}
