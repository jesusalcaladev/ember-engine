//! Renderer interface (spec §7: the engine never uses Dawn directly).
//!
//! M0 draws a quad with an MVP. The interface grows per milestone (batcher in
//! M2, lights in M7) keeping the `ptr + vtable` shape so the backend can
//! change (null / dawn, and 3D later) without touching the runtime.

const std = @import("std");

pub const backend_null = @import("backend_null.zig");
pub const backend_dawn = @import("backend_dawn.zig");

pub const QuadVertex = struct {
    pos: [2]f32,
    color: [4]f32,
};

/// Centered unit quad (the shader scales it with the MVP).
pub const quad_vertices = [_]QuadVertex{
    .{ .pos = .{ -0.5, -0.5 }, .color = .{ 1.0, 0.4, 0.2, 1.0 } },
    .{ .pos = .{ 0.5, -0.5 }, .color = .{ 0.2, 0.9, 0.6, 1.0 } },
    .{ .pos = .{ 0.5, 0.5 }, .color = .{ 0.3, 0.5, 1.0, 1.0 } },
    .{ .pos = .{ -0.5, 0.5 }, .color = .{ 1.0, 0.8, 0.2, 1.0 } },
};

pub const quad_indices = [_]u16{ 0, 1, 2, 0, 2, 3 };

pub const Renderer = struct {
    ptr: *anyopaque,
    vtable: *const VTable,

    pub const VTable = struct {
        /// Draws a quad with an MVP transform (column-major 4x4).
        drawQuad: *const fn (ptr: *anyopaque, mvp: *const [16]f32) void,
        /// Presents the frame (swapchain on dawn; no-op on null).
        present: *const fn (ptr: *anyopaque) void,
        /// The framebuffer changed size.
        resize: *const fn (ptr: *anyopaque, width: u32, height: u32) void,
        /// Releases backend resources.
        deinit: *const fn (ptr: *anyopaque) void,
    };

    pub fn drawQuad(self: Renderer, mvp: *const [16]f32) void {
        self.vtable.drawQuad(self.ptr, mvp);
    }
    pub fn present(self: Renderer) void {
        self.vtable.present(self.ptr);
    }
    pub fn resize(self: Renderer, width: u32, height: u32) void {
        self.vtable.resize(self.ptr, width, height);
    }
    pub fn deinit(self: Renderer) void {
        self.vtable.deinit(self.ptr);
    }
};

test "quad has 4 vertices and valid indices" {
    try std.testing.expectEqual(@as(usize, 4), quad_vertices.len);
    for (quad_indices) |i| try std.testing.expect(i < quad_vertices.len);
}
