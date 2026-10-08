//! Minimal 2D math for M0: Vec2, Mat4 and lerp.
//!
//! Column-major (compatible with WGSL mat4x4<f32>). Grows per milestone;
//! nothing here allocates memory.

const std = @import("std");

pub const Vec2 = struct {
    x: f32 = 0,
    y: f32 = 0,

    pub const zero = Vec2{};

    pub fn add(a: Vec2, b: Vec2) Vec2 {
        return .{ .x = a.x + b.x, .y = a.y + b.y };
    }
    pub fn sub(a: Vec2, b: Vec2) Vec2 {
        return .{ .x = a.x - b.x, .y = a.y - b.y };
    }
    pub fn scale(a: Vec2, s: f32) Vec2 {
        return .{ .x = a.x * s, .y = a.y * s };
    }
    pub fn dot(a: Vec2, b: Vec2) f32 {
        return a.x * b.x + a.y * b.y;
    }
    pub fn length(a: Vec2) f32 {
        return @sqrt(a.dot(a));
    }
    pub fn lerp(a: Vec2, b: Vec2, t: f32) Vec2 {
        return .{ .x = a.x + (b.x - a.x) * t, .y = a.y + (b.y - a.y) * t };
    }
};

pub fn lerpF(a: f32, b: f32, t: f32) f32 {
    return a + (b - a) * t;
}

pub const Mat4 = struct {
    /// Column-major: m[col * 4 + row]
    m: [16]f32,

    pub const identity = Mat4{ .m = .{
        1, 0, 0, 0,
        0, 1, 0, 0,
        0, 0, 1, 0,
        0, 0, 0, 1,
    } };

    /// 2D orthographic projection in pixels: (0,0) is top-left.
    pub fn orthoPixels(w: f32, h: f32) Mat4 {
        const sx = 2.0 / w;
        const sy = -2.0 / h;
        return .{ .m = .{
            sx, 0,  0, 0,
            0,  sy, 0, 0,
            0,  0,  1, 0,
            -1, 1,  0, 1,
        } };
    }

    pub fn rotateZ(radians: f32) Mat4 {
        const c = @cos(radians);
        const s = @sin(radians);
        return .{ .m = .{
            c,   s,   0, 0,
            -s,  c,   0, 0,
            0,   0,   1, 0,
            0,   0,   0, 1,
        } };
    }

    /// Translation in pixel space (column-major, compatible with WGSL).
    pub fn translate(x: f32, y: f32) Mat4 {
        return .{ .m = .{
            1, 0, 0, 0,
            0, 1, 0, 0,
            0, 0, 1, 0,
            x, y, 0, 1,
        } };
    }

    /// Uniform 2D scale (z untouched, w kept at 1).
    pub fn scale(s: f32) Mat4 {
        return .{ .m = .{
            s, 0, 0, 0,
            0, s, 0, 0,
            0, 0, 1, 0,
            0, 0, 0, 1,
        } };
    }

    pub fn mul(a: Mat4, b: Mat4) Mat4 {
        var out: [16]f32 = undefined;
        for (0..4) |col| {
            for (0..4) |row| {
                var sum: f32 = 0;
                for (0..4) |k| {
                    sum += a.m[k * 4 + row] * b.m[col * 4 + k];
                }
                out[col * 4 + row] = sum;
            }
        }
        return .{ .m = out };
    }
};

test "ortho maps corners to clip space" {
    const m = Mat4.orthoPixels(1280, 720);
    // Pixel center (640, 360) -> clip space center (0, 0).
    const cx = m.m[0] * 640 + m.m[4] * 360 + m.m[12];
    const cy = m.m[1] * 640 + m.m[5] * 360 + m.m[13];
    try std.testing.expectApproxEqAbs(@as(f32, 0), cx, 0.001);
    try std.testing.expectApproxEqAbs(@as(f32, 0), cy, 0.001);
    // Corner (0,0) -> (-1, 1) (top-left of clip space).
    const ux = m.m[12];
    const uy = m.m[13];
    try std.testing.expectApproxEqAbs(@as(f32, -1), ux, 0.001);
    try std.testing.expectApproxEqAbs(@as(f32, 1), uy, 0.001);
}

test "mul with identity is identity" {
    const m = Mat4.rotateZ(1.234);
    const r = Mat4.mul(Mat4.identity, m);
    for (r.m, m.m) |a, b| try std.testing.expectApproxEqAbs(b, a, 0.0001);
}

test "lerp interpolates endpoints" {
    try std.testing.expectEqual(@as(f32, 2), lerpF(2, 10, 0));
    try std.testing.expectEqual(@as(f32, 10), lerpF(2, 10, 1));
    try std.testing.expectApproxEqAbs(@as(f32, 6), lerpF(2, 10, 0.5), 0.0001);
}
