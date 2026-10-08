//! Null backend: no GPU at all, just frame bookkeeping.
//!
//! Used for: headless CI, runtime tests, and as the template of the contract
//! the Dawn backend fulfills. Zero allocations.

const std = @import("std");
const render = @import("render.zig");

pub const Backend = struct {
    frames: u64 = 0,
    quads_drawn: u64 = 0,

    const vtable = render.Renderer.VTable{
        .drawQuad = drawQuad,
        .present = present,
        .resize = resize,
        .deinit = deinit,
    };

    pub fn renderer(self: *Backend) render.Renderer {
        return .{ .ptr = self, .vtable = &vtable };
    }

    fn drawQuad(ptr: *anyopaque, mvp: *const [16]f32) void {
        _ = mvp;
        const self: *Backend = @ptrCast(@alignCast(ptr));
        self.quads_drawn += 1;
    }

    fn present(ptr: *anyopaque) void {
        const self: *Backend = @ptrCast(@alignCast(ptr));
        self.frames += 1;
    }

    fn resize(ptr: *anyopaque, width: u32, height: u32) void {
        _ = ptr;
        _ = width;
        _ = height;
    }

    fn deinit(ptr: *anyopaque) void {
        _ = ptr;
    }
};
