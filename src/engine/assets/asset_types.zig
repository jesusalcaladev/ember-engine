//! Asset payload types used by the `AssetManager`.
//!
//! The draft this replaces had two bugs that made it uncompilable and one that
//! made it leaky:
//! - `payload: *const void` is not a type, and `@typeInfo(T)` compared against
//!   a runtime pointer is not a thing Zig does — a slot now carries an
//!   `AssetKind` enum and an erased `?*anyopaque`.
//! - the path was a slice into the *payload*, so evicting a slot freed the
//!   payload and stranded the string. The path is now stored INLINE in the
//!   slot, so a slot owns exactly one allocation (its payload) and nothing is
//!   left dangling between a `freeSlot` and a `deinit`.
//!
//! Audio is deliberately absent: decoded PCM is owned by the audio bank
//! (`engine.audio.Bank`), which has its own byte budget. One cache per resource
//! (spec §3.15); a second PCM cache in here is how the two drift apart.

/// What a slot holds. A plain enum, not a type pointer.
pub const AssetKind = enum { image };

/// The longest path a slot can store, including the NUL we never write.
pub const max_path = 256;

/// Decoded image pixels, owned by the manager and freed on eviction.
pub const Image = struct {
    width: u32 = 0,
    height: u32 = 0,
    /// Channels in `pixels`. Decoding requests RGBA, so this is 4 in practice.
    channels: u8 = 4,
    /// RGBA u8, `width * height * channels` long.
    pixels: []u8 = &.{},

    pub fn isEmpty(self: *const Image) bool {
        return self.pixels.len == 0;
    }
};

/// One cache slot. Owns its payload pointer and its path bytes; frees nothing
/// on its own (the manager knows the allocator and the kind).
pub const AssetSlot = struct {
    /// null = the slot is free. This is the emptiness test; there is no
    /// separate `occupied` flag to fall out of sync with it.
    kind: ?AssetKind = null,
    path_buf: [max_path]u8 = [_]u8{0} ** max_path,
    path_len: u16 = 0,
    payload: ?*anyopaque = null,
    /// Cost of `payload` in bytes, for the budget and the memory report.
    bytes: usize = 0,
    /// LRU clock: the tick this slot was last read.
    lastUsedTick: u64 = 0,
    /// Bumped on every reuse, so a handle is never mistaken for the asset that
    /// used to live here (the same rule `ecs.Entity` and `audio.VoiceId` use).
    generation: u32 = 0,

    pub fn path(self: *const AssetSlot) []const u8 {
        return self.path_buf[0..self.path_len];
    }

    pub fn setPath(self: *AssetSlot, p: []const u8) void {
        // Truncate rather than fail: a 300-character path is a config mistake,
        // and an asset whose name is cut is still loadable and still logged.
        const n = @min(p.len, max_path);
        @memcpy(self.path_buf[0..n], p[0..n]);
        self.path_len = @intCast(n);
    }
};
