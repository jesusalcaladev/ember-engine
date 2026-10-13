//! Asset identity: a generation-checked handle into the manager's slots.

const std = @import("std");

/// An opaque index into the manager's slot table.
pub const AssetId = usize;

/// `AssetId` plus a generation, so a recycled slot is never mistaken for the
/// asset that used to live there — the same scheme `ecs.Entity` and
/// `audio.VoiceId` use, for the same reason.
pub const AssetHandle = struct {
    id: AssetId,
    generation: u32,

    pub fn isNone(self: AssetHandle) bool {
        return self.id == std.math.maxInt(usize) and self.generation == 0;
    }
};

/// Loading status of an asset, for a UI that shows a spinner while a decode is
/// in flight.
pub const AssetState = enum(u8) {
    Unloaded,
    Loading,
    Loaded,
    Error,
};

/// The invalid handle, as a value rather than a sentinel in the id space.
pub fn invalidHandle() AssetHandle {
    return .{ .id = std.math.maxInt(usize), .generation = 0 };
}

test "a fresh handle is not the invalid one, and the invalid one says so" {
    try std.testing.expect(invalidHandle().isNone());
    try std.testing.expect(!(AssetHandle{ .id = 0, .generation = 1 }).isNone());
}
