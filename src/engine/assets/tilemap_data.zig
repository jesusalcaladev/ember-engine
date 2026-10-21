//! M15 — the tile map DATA decoder: loads `.tilemap` files.
//!
//! A tile map's DATA is the tiles themselves ✓ — the recipe's result ✓ —
//! and it is not in the component ✓ (a grid does not fit in a fixed-size
//! record ✓). So it is an asset ✓, and the component says which one ✓.
//!
//! The format is line-oriented text ✓, like the tile set's ✓:
//!
//! ```
//! tilemap 1
//! tileset asset_0123456789abcdef
//! tile 0 0 1
//! tile 1 0 2 flipx
//! tile 2 0 3 flipy
//! ```
//!
//! A text format and not a binary one ✓: a level is a thing people edit ✓,
//! diff ✓ and argue about ✓, and a file that cannot be read without the
//! engine is a file nobody can fix ✓.

const std = @import("std");
const types = @import("asset_types.zig");

/// Decodes a `.tilemap` file ✓.
pub fn decode(allocator: std.mem.Allocator, path: []const u8) !types.TileMapData {
    const io = std.Io.Threaded.global_single_threaded.io();
    const text = try std.Io.Dir.cwd().readFileAlloc(io, path, allocator, .limited(16 * 1024 * 1024));
    defer allocator.free(text);

    var map = types.TileMapData{};
    errdefer map.deinit(allocator);

    var cursor = Cursor{ .text = text };
    try cursor.expectIdentifier("tilemap");
    const version = try cursor.parseUint(u32);
    if (version != 1) return error.InvalidTilemap;

    while (!cursor.done()) {
        cursor.skipTrivia();
        if (cursor.done()) break;
        const keyword = try cursor.identifier();
        if (std.mem.eql(u8, keyword, "tileset")) {
            map.tileset_guid = try cursor.parseGuid();
        } else if (std.mem.eql(u8, keyword, "tile")) {
            const x = try cursor.parseInt(i32);
            const y = try cursor.parseInt(i32);
            const index = try cursor.parseUint(u16);
            var flags: u8 = 0;
            // The flags are OPTIONAL and they are words ✓, not a bitmask ✓:
            // a file a person edits should say `flipx` ✓ and not `1` ✓.
            if (cursor.peekWord()) |word| {
                if (std.mem.eql(u8, word, "flipx")) {
                    flags |= types.TileMapData.FlagFlipX;
                    cursor.skipWord();
                } else if (std.mem.eql(u8, word, "flipy")) {
                    flags |= types.TileMapData.FlagFlipY;
                    cursor.skipWord();
                }
            }
            try map.tiles.append(allocator, .{ .x = x, .y = y, .atlas_index = index, .flags = flags });
        } else {
            return error.InvalidTilemap;
        }
    }
    return map;
}

/// A line-oriented reader ✓ — the same shape as the tile set's ✓.
const Cursor = struct {
    text: []const u8,
    pos: usize = 0,

    fn done(self: *const Cursor) bool {
        return self.pos >= self.text.len;
    }

    fn skipTrivia(self: *Cursor) void {
        while (self.pos < self.text.len) {
            const c = self.text[self.pos];
            if (c == ' ' or c == '\t' or c == '\r' or c == '\n') {
                self.pos += 1;
            } else if (c == '#') {
                // A COMMENT to the end of the line ✓: a level file wants to
                // say why a tile is there ✓.
                while (self.pos < self.text.len and self.text[self.pos] != '\n') self.pos += 1;
            } else break;
        }
    }

    fn identifier(self: *Cursor) ![]const u8 {
        self.skipTrivia();
        const start = self.pos;
        while (self.pos < self.text.len) {
            const c = self.text[self.pos];
            if ((c >= 'a' and c <= 'z') or (c >= 'A' and c <= 'Z') or (c >= '0' and c <= '9') or c == '_') {
                self.pos += 1;
            } else break;
        }
        if (self.pos == start) return error.InvalidTilemap;
        return self.text[start..self.pos];
    }

    fn expectIdentifier(self: *Cursor, want: []const u8) !void {
        const got = try self.identifier();
        if (!std.mem.eql(u8, got, want)) return error.InvalidTilemap;
    }

    fn parseUint(self: *Cursor, comptime T: type) !T {
        self.skipTrivia();
        const start = self.pos;
        while (self.pos < self.text.len and self.text[self.pos] >= '0' and self.text[self.pos] <= '9') self.pos += 1;
        if (self.pos == start) return error.InvalidTilemap;
        return std.fmt.parseInt(T, self.text[start..self.pos], 10) catch error.InvalidTilemap;
    }

    fn parseInt(self: *Cursor, comptime T: type) !T {
        self.skipTrivia();
        const start = self.pos;
        if (self.pos < self.text.len and (self.text[self.pos] == '-' or self.text[self.pos] == '+')) self.pos += 1;
        while (self.pos < self.text.len and self.text[self.pos] >= '0' and self.text[self.pos] <= '9') self.pos += 1;
        if (self.pos == start) return error.InvalidTilemap;
        return std.fmt.parseInt(T, self.text[start..self.pos], 10) catch error.InvalidTilemap;
    }

    /// An asset GUID, as the registry prints it: `asset_0123456789abcdef` ✓.
    fn parseGuid(self: *Cursor) !u64 {
        self.skipTrivia();
        const start = self.pos;
        while (self.pos < self.text.len and self.text[self.pos] != ' ' and self.text[self.pos] != '\n' and self.text[self.pos] != '\r') self.pos += 1;
        const word = self.text[start..self.pos];
        if (!std.mem.startsWith(u8, word, "asset_")) return error.InvalidTilemap;
        const hex = word[6..];
        if (hex.len != 16) return error.InvalidTilemap;
        var value: u64 = 0;
        for (hex) |c| {
            value <<= 4;
            const digit: u64 = if (c >= '0' and c <= '9') c - '0' else if (c >= 'a' and c <= 'f') c - 'a' + 10 else if (c >= 'A' and c <= 'F') c - 'A' + 10 else return error.InvalidTilemap;
            value |= digit & 0xF;
        }
        return value;
    }

    /// The next word, if it is one ✓ (without consuming it ✓).
    fn peekWord(self: *Cursor) ?[]const u8 {
        const save = self.pos;
        defer self.pos = save;
        self.skipTrivia();
        const start = self.pos;
        while (self.pos < self.text.len) {
            const c = self.text[self.pos];
            if ((c >= 'a' and c <= 'z') or (c >= 'A' and c <= 'Z')) {
                self.pos += 1;
            } else break;
        }
        if (self.pos == start) return null;
        return self.text[start..self.pos];
    }

    fn skipWord(self: *Cursor) void {
        _ = self.peekWord();
    }
};
