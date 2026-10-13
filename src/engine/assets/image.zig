//! Image decoding via `stb_image.h` (vendored in `libs/`, compiled by the
//! `stb_image_impl.c` shim in this directory).
//!
//! Why a C shim and hand-written externs instead of `@cImport`: Zig 0.16's
//! translate-c cannot lower the whole of stb_image — the generated `cimport.zig`
//! fails to compile on unions-of-arrays and bit-cast pointer arithmetic. A
//! one-line C translation unit plus the two `extern` declarations below is the
//! same approach `platform/glfw_bindings.zig` already takes for GLFW.
//!
//! Two bugs in the draft this replaces, both of which would have shown up as a
//! crash or a corrupted image rather than a compile error in a happy path:
//! - `STB_IMAGE_IMPLEMENTATION` was never defined (the shim now defines it once);
//! - `stbi_load` was handed a Zig slice, not the NUL-terminated C string it
//!   takes, and the copy of the returned pixels had its arguments reversed.
//!
//! Decoding is LOAD TIME ONLY. It allocates and it does blocking I/O, which is
//! why it is never reachable from a frame or from the audio device thread.

const std = @import("std");
const Image = @import("asset_types.zig").Image;

// The slice of stb_image we call. `stbi_load` returns a heap buffer owned by
// stb_image until `stbi_image_free`, so the contracts are stated here rather
// than inferred from a generated file.
extern fn stbi_load(
    filename: [*:0]const u8,
    x: *c_int,
    y: *c_int,
    channels_in_file: *c_int,
    desired_channels: c_int,
) ?[*]u8;
extern fn stbi_image_free(data: ?*anyopaque) void;

/// Decodes `path` into RGBA8. The returned `pixels` are allocated with
/// `allocator` and owned by the caller (the asset manager frees them).
pub fn decode(allocator: std.mem.Allocator, path: []const u8) !Image {
    // stbi_load takes a C string; a Zig slice is not NUL-terminated and reading
    // past it is undefined behaviour, not a failed load.
    const path_z = try allocator.dupeZ(u8, path);
    defer allocator.free(path_z);

    var w: c_int = 0;
    var h: c_int = 0;
    var comp_in_file: c_int = 0;
    const channels_requested: c_int = 4; // RGBA, the one format the renderer wants

    const src = stbi_load(path_z.ptr, &w, &h, &comp_in_file, channels_requested);
    if (src == null) return error.FileNotFound;
    defer stbi_image_free(@ptrCast(src));

    if (w <= 0 or h <= 0) return error.InvalidImage;
    const total: usize = @as(usize, @intCast(w)) * @as(usize, @intCast(h)) * @as(usize, @intCast(channels_requested));

    const pixels = try allocator.alloc(u8, total);
    // Forwards: `src` is the source, `pixels` the destination. The draft had
    // the two arguments swapped.
    @memcpy(pixels, src.?[0..total]);

    return .{
        .width = @intCast(w),
        .height = @intCast(h),
        .channels = @intCast(channels_requested),
        .pixels = pixels,
    };
}
