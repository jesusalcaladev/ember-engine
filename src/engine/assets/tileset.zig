//! M15 TileSet decoder: loads .tileset files (JSON-like text format).
//!
//! A .tileset file references an atlas image and defines per-tile physics,
//! autotiling rules, and tile metadata. It is a plain text format for
//! diffability and editor friendliness.

const std = @import("std");
const types = @import("asset_types.zig");
const TileSet = types.TileSet;
const TilePhysics = types.TilePhysics;
const Autotiling = types.Autotiling;
const WangRule = types.WangRule;
const BlobRule = types.BlobRule;
const assets = @import("registry.zig");
const components = @import("../ecs/components.zig");
const core_math = @import("core").math;

/// Decodes a .tileset file into a TileSet asset.
/// Format is a simple line-oriented format:
/// ```
/// tileset 1
/// tile_size 32.0
/// atlas_guid asset_abc123
/// atlas_slot 0
/// tile_count 48
/// physics 0 box 0.5 0.5 0 0 0.3 0.0 1.0 0 false up
/// physics 1 circle 0.4 0 0 0 0.2 0.5 1.0 1 false up
/// wang 5 0xFF 0xFF
/// blob 10 [0,1,2,3,...] (47 entries)
/// ```
pub fn decode(allocator: std.mem.Allocator, path: []const u8) !TileSet {
    const text = try std.fs.cwd().readFileAlloc(allocator, path, 1024 * 1024);
    errdefer allocator.free(text);

    var cursor = Cursor{ .text = text };
    var tileset = TileSet{};

    // Parse header
    try cursor.expectIdentifier("tileset");
    const version = try cursor.parseUint(u32);
    if (version != 1) return error.InvalidTileset;

    while (!cursor.done()) {
        cursor.skipTrivia();
        if (cursor.done()) break;

        const keyword = try cursor.identifier();
        if (keyword == "tile_size") {
            tileset.tile_size = try cursor.parseFloat(f32);
        } else if (keyword == "atlas_guid") {
            tileset.atlas_guid = try parseAssetGUID(&cursor);
        } else if (keyword == "atlas_slot") {
            tileset.atlas_slot = try cursor.parseUint(u8);
        } else if (keyword == "tile_count") {
            tileset.tile_count = try cursor.parseUint(u16);
            // Pre-allocate physics array
            tileset.physics = try allocator.alloc(TilePhysics, tileset.tile_count);
            for (tileset.physics) |*p| p.* = TilePhysics{};
        } else if (keyword == "physics") {
            try parsePhysics(&cursor, &tileset);
        } else if (keyword == "wang") {
            try parseWangRule(&cursor, &tileset, allocator);
        } else if (keyword == "blob") {
            try parseBlobRule(&cursor, &tileset);
        } else {
            // Skip unknown lines for forward compatibility
            try cursor.skipLine();
        }
    }

    return tileset;
}

fn parsePhysics(cursor: *Cursor, tileset: *TileSet) !void {
    const index = try cursor.parseUint(u16);
    if (index >= tileset.tile_count) return error.InvalidTileset;

    var phys = &tileset.physics[index];
    const shape_str = try cursor.identifier();
    phys.shape = try parseShapeKind(shape_str);

    phys.half_extents.x = try cursor.parseFloat(f32);
    phys.half_extents.y = try cursor.parseFloat(f32);
    phys.radius = try cursor.parseFloat(f32);

    phys.filter.category_bits = try cursor.parseUint(u64);
    phys.filter.mask_bits = try cursor.parseUint(u64);

    phys.is_sensor = try cursor.parseBool();
    phys.nav_cost = try cursor.parseFloat(f32);
    phys.trigger_id = try cursor.parseUint(u16);
    phys.one_way = try cursor.parseBool();

    const dir_str = try cursor.identifier();
    phys.one_way_dir = try parseOneWayDir(dir_str);

    // Polygon vertices if shape == polygon
    if (phys.shape == .polygon) {
        phys.polygon_count = try cursor.parseUint(u8);
        for (0..phys.polygon_count) |i| {
            phys.polygon[i].x = try cursor.parseFloat(f32);
            phys.polygon[i].y = try cursor.parseFloat(f32);
        }
    }
}

fn parseWangRule(cursor: *Cursor, tileset: *TileSet, allocator: std.mem.Allocator) !void {
    const rule = WangRule{
        .tile = try cursor.parseUint(u16),
        .mask = try cursor.parseUint(u8),
        .check_mask = try cursor.parseUint(u8),
    };

    switch (tileset.autotiling) {
        .wang => |*rules| {
            try rules.append(allocator, rule);
        },
        .none => {
            var rules = std.ArrayList(WangRule).init(allocator);
            try rules.append(allocator, rule);
            tileset.autotiling = .wang(rules);
        },
        .blob => return error.InvalidTileset, // Can't mix wang and blob
    }
}

fn parseBlobRule(cursor: *Cursor, tileset: *TileSet) !void {
    var rule = BlobRule{
        .base_tile = try cursor.parseUint(u16),
    };
    // Parse 47 transitions
    try cursor.expect('[');
    for (0..47) |i| {
        rule.transitions[i] = try cursor.parseUint(u16);
        if (i != 46) _ = try cursor.eat(',');
    }
    try cursor.expect(']');
    tileset.autotiling = .blob(rule);
}

fn parseShapeKind(s: []const u8) !TilePhysics.ShapeKind {
    return switch (s) {
        "none" => .none,
        "box" => .box,
        "circle" => .circle,
        "capsule" => .capsule,
        "polygon" => .polygon,
        else => return error.InvalidTileset,
    };
}

fn parseOneWayDir(s: []const u8) !TilePhysics.OneWayDir {
    return switch (s) {
        "up" => .up,
        "down" => .down,
        "left" => .left,
        "right" => .right,
        else => return error.InvalidTileset,
    };
}

fn parseAssetGUID(cursor: *Cursor) !assets.AssetGUID {
    const hex = try cursor.identifier();
    // Format: asset_XXXXXXXXXXXXXXXX (16 hex chars after "asset_")
    if (!std.mem.startsWith(u8, hex, "asset_")) return error.InvalidTileset;
    const hex_part = hex[6..];
    if (hex_part.len != 16) return error.InvalidTileset;
    var value: u64 = 0;
    for (hex_part) |c| {
        value <<= 4;
        value |= @as(u64, @intFromChar(c)) & 0xF;
    }
    return .{ .value = value };
}

// ── Lexer ──────────────────────────────────────────────────────────────────

const Cursor = struct {
    text: []const u8,
    pos: usize = 0,

    fn skipTrivia(self: *Cursor) void {
        while (self.pos < self.text.len) {
            const c = self.text[self.pos];
            if (c == ' ' or c == '\t' or c == '\r' or c == '\n' or c == ',') {
                self.pos += 1;
            } else break;
        }
    }

    fn done(self: *Cursor) bool {
        self.skipTrivia();
        return self.pos >= self.text.len;
    }

    fn identifier(self: *Cursor) ![]const u8 {
        self.skipTrivia();
        const start = self.pos;
        if (start >= self.text.len) return error.InvalidTileset;
        var at = start;
        while (at < self.text.len) {
            const c = self.text[at];
            if ((c >= 'a' and c <= 'z') or (c >= 'A' and c <= 'Z') or
                (c >= '0' and c <= '9') or c == '_' or c == '.' or c == 'x') {
                at += 1;
            } else break;
        }
        if (at == start) return error.InvalidTileset;
        self.pos = at;
        return self.text[start..at];
    }

    fn expectIdentifier(self: *Cursor, expected: []const u8) !void {
        const got = try self.identifier();
        if (!std.mem.eql(u8, got, expected)) return error.InvalidTileset;
    }

    fn parseUint(self: *Cursor, comptime T: type) !T {
        const tok = try self.identifier();
        return std.fmt.parseInt(T, tok, 10);
    }

    fn parseFloat(self: *Cursor, comptime T: type) !T {
        const tok = try self.identifier();
        return std.fmt.parseFloat(T, tok);
    }

    fn parseBool(self: *Cursor) !bool {
        const tok = try self.identifier();
        if (std.mem.eql(u8, tok, "true")) return true;
        if (std.mem.eql(u8, tok, "false")) return false;
        return error.InvalidTileset;
    }

    fn eat(self: *Cursor, c: u8) !bool {
        self.skipTrivia();
        if (self.pos >= self.text.len) return false;
        if (self.text[self.pos] != c) return false;
        self.pos += 1;
        return true;
    }

    fn expect(self: *Cursor, c: u8) !void {
        if (!try self.eat(c)) return error.InvalidTileset;
    }

    fn skipLine(self: *Cursor) !void {
        while (self.pos < self.text.len) {
            if (self.text[self.pos] == '\n') {
                self.pos += 1;
                return;
            }
            self.pos += 1;
        }
    }
};

// ── Tests ──────────────────────────────────────────────────────────────────

const testing = std.testing;

test "parseAssetGUID" {
    var cursor = Cursor{ .text = "asset_0123456789abcdef" };
    const guid = try parseAssetGUID(&cursor);
    try testing.expectEqual(@as(u64, 0x0123456789abcdef), guid.value);
}

test "parseShapeKind" {
    try testing.expectEqual(.box, try parseShapeKind("box"));
    try testing.expectEqual(.circle, try parseShapeKind("circle"));
    try testing.expectEqual(.polygon, try parseShapeKind("polygon"));
}

test "parseOneWayDir" {
    try testing.expectEqual(.up, try parseOneWayDir("up"));
    try testing.expectEqual(.down, try parseOneWayDir("down"));
}