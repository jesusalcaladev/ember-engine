pub const clip = @import("clip.zig");
pub const registry = @import("registry.zig");

pub const Clip = clip.Clip;
pub const Registry = registry.Registry;
pub const deinitClip = clip.deinitClip;

test {
    const std = @import("std");
    std.testing.refAllDecls(@This());
}
