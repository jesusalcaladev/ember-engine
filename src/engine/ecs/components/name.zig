//! `Name` — the inline display-name component (M1, split out of components.zig).

const std = @import("std");

/// Inline name: identity for humans, and the key `.zson` overrides match by.
/// Fixed size keeps it POD (no allocation, no lifetime, byte-copyable).
pub const Name = struct {
    bytes: [32]u8 = [_]u8{0} ** 32,
    len: u8 = 0,

    pub const max_len = 32;

    pub fn init(text: []const u8) Name {
        var name = Name{};
        name.set(text);
        return name;
    }

    pub fn set(self: *Name, text: []const u8) void {
        const len = @min(text.len, Name.max_len);
        @memcpy(self.bytes[0..len], text[0..len]);
        self.len = @intCast(len);
    }

    pub fn slice(self: *const Name) []const u8 {
        return self.bytes[0..self.len];
    }

    pub fn eql(self: *const Name, text: []const u8) bool {
        return std.mem.eql(u8, self.slice(), text);
    }
};

// ── Tests ────────────────────────────────────────────────────────────────────

const testing = std.testing;

test "Name: init, set, truncation to max_len" {
    const short = Name.init("quad");
    try testing.expectEqualStrings("quad", short.slice());
    const long = Name.init(&[_]u8{'a'} ** 64);
    try testing.expectEqual(Name.max_len, long.len);
    try testing.expect(long.eql(&[_]u8{'a'} ** 32));
}

test "Name is 33 bytes: 32 inline plus the length" {
    // A component is a column in an SoA archetype, so its size is multiplied by
    // the entity count (see components_test.zig for why this is pinned).
    try testing.expectEqual(@as(usize, 33), @sizeOf(Name));
}