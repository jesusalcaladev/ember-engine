//! M15 TileMap Components — Plain data types only (spec §7).
//!
//! The component is PURE DATA: no slices, no pointers, no allocators.
//! All chunk storage lives in TileMapSystem (physics) and TileMapRenderSystem.

const std = @import("std");
const core_math = @import("core").math;
const registry = @import("registry.zig");

pub const Vec2 = core_math.Vec2;
pub const Filter = registry.Filter;

/// AssetGUID - content-addressable asset identifier (FNV-1a hash).
pub const AssetGUID = struct {
    /// The hash. The default is ZERO, and it means "no asset" ✓ — the
    /// registry's rule is that every field of a component has a default ✓
    /// (the `.zson` baseline ✓: a field with no default has no baseline to
    /// fall back to ✓).
    value: u64 = 0,

    pub fn fromContent(path: []const u8, content: []const u8) AssetGUID {
        var h: u64 = 0xcbf29ce484222325;
        for (path) |c| { h ^= @as(u64, c); h *= 0x100000001b3; }
        for (content) |c| { h ^= @as(u64, c); h *= 0x100000001b3; }
        return .{ .value = h };
    }
    pub fn fromPath(path: []const u8) AssetGUID {
        var h: u64 = 0xcbf29ce484222325;
        for (path) |c| { h ^= @as(u64, c); h *= 0x100000001b3; }
        return .{ .value = h };
    }
    pub fn isNone(self: AssetGUID) bool { return self.value == 0; }
    pub fn toString(self: AssetGUID, buf: []u8) []const u8 {
        _ = std.fmt.bufPrint(buf, "asset_{x:0>16}", .{self.value}) catch return "asset_0000000000000000";
        return buf;
    }
};

/// Maximum tiles per chunk. 16x16 = 256 fits in u16 index.
pub const chunk_size: u16 = 16;
pub const chunk_area: usize = @as(usize, chunk_size) * @as(usize, chunk_size);

/// Tile coordinate in chunk-local space (0..15, 0..15).
pub const ChunkCoord = struct {
    x: u8 = 0, y: u8 = 0,
    pub fn fromTile(tile_x: i32, tile_y: i32) ChunkCoord {
        return .{ .x = @intCast(@mod(tile_x, @as(i32, chunk_size))),
                  .y = @intCast(@mod(tile_y, @as(i32, chunk_size))) };
    }
    pub fn index(self: ChunkCoord) u16 { return @as(u16, self.y) * chunk_size + @as(u16, self.x); }
};

/// Chunk coordinate in world chunk space.
pub const ChunkKey = struct {
    cx: i32 = 0, cy: i32 = 0,
    pub fn fromWorld(world_x: f32, world_y: f32, tile_size: f32) ChunkKey {
        const tile_x = @as(i32, @intFromFloat(@floor(world_x / tile_size)));
        const tile_y = @as(i32, @intFromFloat(@floor(world_y / tile_size)));
        return .{ .cx = @divFloor(tile_x, @as(i32, chunk_size)),
                  .cy = @divFloor(tile_y, @as(i32, chunk_size)) };
    }
    pub fn hash(self: ChunkKey) u64 {
        // FNV-1a. The multiply WRAPS on purpose: the FNV prime is chosen so the
        // 64-bit product overflows every round, and the overflow is the hash. A
        // checked multiply would panic on the second byte of every key.
        var h: u64 = 0xcbf29ce484222325;
        const bytes = std.mem.asBytes(&self);
        for (bytes) |b| {
            h ^= @as(u64, b);
            h *%= 0x100000001b3;
        }
        return h;
    }
    pub fn eql(self: ChunkKey, other: ChunkKey) bool { return self.cx == other.cx and self.cy == other.cy; }
};

/// One tile entry: atlas index + flip flags + user data.
/// Packed into 32 bits: 16 bits atlas index, 2 bits flip, 14 bits user.
pub const Tile = struct {
    atlas_index: u16 = 0, flags: u8 = 0, user: u16 = 0,
    pub const FlagFlipX: u8 = 0x01; pub const FlagFlipY: u8 = 0x02;
    pub fn isEmpty(self: Tile) bool { return self.atlas_index == 0; }
    pub fn flipX(self: Tile) bool { return (self.flags & FlagFlipX) != 0; }
    pub fn flipY(self: Tile) bool { return (self.flags & FlagFlipY) != 0; }
    pub fn withFlipX(self: Tile, v: bool) Tile { return .{ .atlas_index = self.atlas_index, .flags = if (v) self.flags | FlagFlipX else self.flags & ~FlagFlipX, .user = self.user }; }
    pub fn withFlipY(self: Tile, v: bool) Tile { return .{ .atlas_index = self.atlas_index, .flags = if (v) self.flags | FlagFlipY else self.flags & ~FlagFlipY, .user = self.user }; }
};

/// Per-tile physics/shape data. Stored in TileSet, indexed by atlas_index.
pub const TilePhysics = struct {
    shape: ShapeKind = .none,
    half_extents: Vec2 = .{ .x = 0.5, .y = 0.5 },
    radius: f32 = 0.5,
    polygon: [8]Vec2 = @splat(Vec2{}),
    polygon_count: u8 = 0,
    filter: Filter = Filter.pass_all,
    is_sensor: bool = false,
    nav_cost: f32 = 1.0,
    trigger_id: u16 = 0,
    one_way: bool = false,
    one_way_dir: OneWayDir = .up,
    pub const ShapeKind = enum(u8) { none = 0, box = 1, circle = 2, capsule = 3, polygon = 4 };
    pub const OneWayDir = enum(u8) { up = 0, down = 1, left = 2, right = 3 };
};

/// TileSet asset reference (immutable data lives in asset system).
pub const TileSet = struct {
    guid: AssetGUID = .{ .value = 0 },
    tile_size: f32 = 32.0,
    atlas_guid: AssetGUID = .{ .value = 0 },
    atlas_slot: u8 = 0,
    tile_count: u16 = 0,
    physics: []TilePhysics = &.{},  // Populated by asset system
    autotiling: Autotiling = .none,
    pub const WangRule = struct { tile: u16 = 0, mask: u8 = 0, check_mask: u8 = 0 };
    pub const BlobRule = struct { base_tile: u16 = 0, transitions: [47]u16 = @splat(0) };
    pub const Autotiling = union(enum) {
        none,
        wang: std.ArrayList(WangRule),
        blob: BlobRule,
        pub fn deinit(self: *Autotiling, allocator: std.mem.Allocator) void {
            switch (self.*) { .wang => |*rules| rules.deinit(allocator), .blob => {}, .none => {}, }
        }
    };
};

/// TileMapLayer — PURE DATA component (spec §7).
/// NO slices, NO pointers, NO allocators.
/// All chunk storage lives in TileMapSystem / TileMapRenderSystem.
pub const TileMapLayer = struct {
    /// The tile set's identity, as the hash the asset registry uses ✓.
    ///
    /// A plain `u64` and not the asset's own `AssetGUID` type ✓: the ECS
    /// layer does not depend on the asset layer ✓ (the dependency runs the
    /// other way ✓), and the identity is a hash either way ✓. The renderer
    /// turns it back into the registry's type when it looks the tile set up
    /// ✓.
    tileset_guid: u64 = 0,
    /// Render layer (same as Sprite.layer). Lower draws first.
    layer: u16 = 0,
    /// Z offset for parallax / layering within the same render layer.
    z_offset: f32 = 0.0,
    /// Physics: whether this layer participates in collision.
    physics_enabled: bool = false,
    /// Override tile size (0 = use TileSet default).
    tile_size_override: f32 = 0.0,
    /// The tile size in world units, when the layer does not use the tile
    /// set's own ✓. Zero means "the tile set's" ✓.
    ///
    /// The layer carries the tile set's MEASUREMENTS ✓ (the size ✓, the
    /// atlas page ✓, the tiles per row ✓) and not the tile set's data ✓
    /// (the physics shapes ✓, the autotiling rules ✓): the measurements are
    /// what a LAYER needs to place its tiles ✓, and they are four numbers ✓
    /// that fit in a component ✓ — while the rules are a recipe that belongs
    /// in the asset ✓.
    tile_size: f32 = 32.0,
    /// The atlas page the tiles sample ✓.
    atlas_slot: u8 = 0,
    /// How many tiles fit in one row of the atlas page ✓. The UV of a tile
    /// is its index in that grid ✓.
    tiles_per_row: u8 = 8,
    /// How many tiles the atlas page has ✓.
    tile_count: u16 = 0,
    /// Default flip for new tiles.
    default_flip_x: bool = false,
    default_flip_y: bool = false,
    /// Reserved for future use.
    _reserved: [3]u8 = @splat(0),
};

/// Chunk of tile data (owned by systems, not component).
pub const TileChunk = struct {
    key: ChunkKey = .{},
    tiles: [chunk_area]Tile = @splat(Tile{}),
    dirty: [4]u64 = @splat(0),
    generation: u32 = 0,
    has_tiles: bool = false,
    pub fn markDirty(self: *TileChunk, local_index: u16) void {
        const word: usize = @intCast(local_index >> 6); const bit: u6 = @intCast(local_index & 63);
        const row = self.dirty[0..];
        row[word] = row[word] | (@as(u64, 1) << bit);
    }
    pub fn clearDirty(self: *TileChunk) void { @memset(self.dirty[0..], 0); }
    pub fn isDirty(self: *const TileChunk, local_index: u16) bool {
        const word: usize = @intCast(local_index >> 6); const bit: u6 = @intCast(local_index & 63);
        const row = self.dirty[0..];
        return (row[word] & (@as(u64, 1) << bit)) != 0;
    }
    pub fn anyDirty(self: *const TileChunk) bool {
        return self.dirty[0] != 0 or self.dirty[1] != 0 or self.dirty[2] != 0 or self.dirty[3] != 0;
    }
};

/// Handle to a chunk in a system's chunk pool.
pub const ChunkHandle = struct {
    index: u32 = 0xFFFF_FFFF, generation: u32 = 0,
    pub fn isNone(self: ChunkHandle) bool { return self.index == 0xFFFF_FFFF; }
    pub fn eql(self: ChunkHandle, other: ChunkHandle) bool {
        return self.index == other.index and self.generation == other.generation;
    }
};

/// Round up to the next power of two (a hash table wants a power-of-two mask,
/// not a division). Local rather than `std.math` because the exact spelling of
/// the std helper has moved between releases and this is three lines.
fn roundUpToPowerOfTwo(v: usize) usize {
    if (v <= 1) return 1;
    var x: usize = 1;
    while (x < v) x *= 2;
    return x;
}

/// Open-addressing hash map: ChunkKey hash -> ChunkHandle.
pub const ChunkMap = struct {
    capacity: usize = 0, hashes: []u64 = &.{}, values: []ChunkHandle = &.{},
    pub fn init(allocator: std.mem.Allocator, capacity: usize) !ChunkMap {
        const cap = roundUpToPowerOfTwo(capacity * 2);
        const hashes = try allocator.alloc(u64, cap);
        @memset(hashes, 0); // 0 is the "empty slot" sentinel; uninit memory would loop forever
        const values = try allocator.alloc(ChunkHandle, cap);
        return .{ .capacity = cap, .hashes = hashes, .values = values };
    }
    pub fn deinit(self: *ChunkMap, allocator: std.mem.Allocator) void {
        allocator.free(self.hashes); allocator.free(self.values);
        self.hashes = &.{}; self.values = &.{}; self.capacity = 0;
    }
    fn idx(self: *const ChunkMap, hash: u64) usize { return @intCast(hash & (@as(u64, self.capacity) - 1)); }
    pub fn put(self: *ChunkMap, key: ChunkKey, handle: ChunkHandle) void {
        const hash = key.hash(); var i = self.idx(hash);
        while (self.hashes[i] != 0) { if (self.hashes[i] == hash) { self.values[i] = handle; return; } i = (i + 1) & (self.capacity - 1); }
        self.hashes[i] = hash; self.values[i] = handle;
    }
    pub fn get(self: *const ChunkMap, key: ChunkKey) ?ChunkHandle {
        const hash = key.hash(); var i = self.idx(hash);
        while (self.hashes[i] != 0) { if (self.hashes[i] == hash) return self.values[i]; i = (i + 1) & (self.capacity - 1); }
        return null;
    }
    pub fn remove(self: *ChunkMap, key: ChunkKey) bool {
        const hash = key.hash(); var i = self.idx(hash);
        while (self.hashes[i] != 0) {
            if (self.hashes[i] == hash) {
                self.hashes[i] = 0; self.values[i] = ChunkHandle{};
                i = (i + 1) & (self.capacity - 1);
                while (self.hashes[i] != 0) {
                    const h = self.hashes[i]; const v = self.values[i];
                    self.hashes[i] = 0; self.values[i] = ChunkHandle{};
                    var j = self.idx(h); while (self.hashes[j] != 0) j = (j + 1) & (self.capacity - 1);
                    self.hashes[j] = h; self.values[j] = v; i = (i + 1) & (self.capacity - 1);
                }
                return true;
            }
            i = (i + 1) & (self.capacity - 1);
        }
        return false;
    }
    pub fn iterator(self: *const ChunkMap) Iterator { return .{ .map = self, .index = 0 }; }
    pub const Iterator = struct {
        map: *const ChunkMap, index: usize = 0,
        pub fn next(self: *Iterator) ?struct { key_hash: u64, value: ChunkHandle } {
            while (self.index < self.map.capacity) { const h = self.map.hashes[self.index]; self.index += 1;
                if (h != 0) return .{ .key_hash = h, .value = self.map.values[self.index - 1] };
            } return null;
        }
    };
};

// ── Tests ────────────────────────────────────────────────────────────────────
const testing = std.testing;
test "ChunkCoord index and fromTile" {
    try testing.expectEqual(@as(u16, 0), ChunkCoord.fromTile(0, 0).index());
    try testing.expectEqual(@as(u16, 255), ChunkCoord.fromTile(15, 15).index());
}
test "ChunkKey hash and equality" {
    const a = ChunkKey{ .cx = 1, .cy = 2 }; const b = ChunkKey{ .cx = 1, .cy = 2 };
    try testing.expect(a.eql(b)); try testing.expectEqual(a.hash(), b.hash());
}
test "Tile packing and flags" {
    var t = Tile{ .atlas_index = 42, .flags = 0, .user = 100 };
    try testing.expect(!t.flipX()); t = t.withFlipX(true); try testing.expect(t.flipX());
}
test "ChunkMap put/get/remove" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator); defer arena.deinit();
    const allocator = arena.allocator();
    var map = try ChunkMap.init(allocator, 16); defer map.deinit(allocator);
    const k1 = ChunkKey{ .cx = 0, .cy = 0 }; const k2 = ChunkKey{ .cx = 1, .cy = 0 };
    const h1 = ChunkHandle{ .index = 1, .generation = 1 }; const h2 = ChunkHandle{ .index = 2, .generation = 1 };
    map.put(k1, h1); map.put(k2, h2);
    try testing.expect(map.get(k1).?.eql(h1)); try testing.expect(map.remove(k1)); try testing.expect(map.get(k1) == null);
}
test "TileChunk dirty tracking" {
    var chunk = TileChunk{ .key = ChunkKey{ .cx = 0, .cy = 0 } };
    try testing.expect(!chunk.anyDirty()); chunk.markDirty(0); try testing.expect(chunk.isDirty(0));
    chunk.clearDirty(); try testing.expect(!chunk.anyDirty());
}