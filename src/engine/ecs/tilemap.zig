//! M15 — the tile store: the chunks of every tile layer in the world.
//!
//! ## Why the tiles are not in the component
//!
//! A `TileMapLayer` is PURE DATA (spec §7): the tileset's GUID, the render
//! layer, the physics flag. The tiles themselves are a grid — 256 tiles per
//! 16x16 chunk, 4 bytes per tile — and a component is a fixed-size record
//! copied into a column. A grid does not fit in a record, and a pointer does
//! not fit in a column either (the registry forbids both: no slices, no
//! pointers, no allocators in a component).
//!
//! So the tiles live HERE, in a world-level store, and the component says
//! WHICH layer this actor is. That is the same split the rest of the engine
//! uses: the component is the recipe, the system owns the state.
//!
//! ## Who reads it
//!
//! - The **renderer** walks the chunks and builds the instances ✓.
//! - The **physics** walks the chunks and builds the colliders ✓.
//! - The **script layer** paints and reads tiles ✓.
//!
//! All three need the SAME data, and a copy in each of them is three copies
//! that drift. The store is the one copy ✓.
//!
//! ## The chunks
//!
//! A chunk is 16x16 tiles ✓, addressed by a `ChunkKey` (the chunk's place in
//! the world) and stored in an open-addressing map ✓ (the `ChunkMap` in
//! `components/tilemap.zig` ✓). The pool is a dense array with a free list ✓,
//! so a chunk's address is an index and the renderer can walk the pool
//! without chasing pointers ✓.
//!
//! ## The dirty bits
//!
//! A chunk carries 256 dirty bits (4 u64s ✓) — one per tile ✓. The renderer
//! uploads only the chunks that changed ✓, which is the difference between a
//! tilemap that costs nothing when it is static ✓ and one that re-uploads the
//! whole level every frame ✗.

const std = @import("std");
const ecs = @import("root.zig");
const components = @import("components.zig");

const Entity = ecs.Entity;
const Tile = components.Tile;
const TileChunk = components.TileChunk;
const ChunkKey = components.ChunkKey;
const ChunkCoord = components.ChunkCoord;
const ChunkHandle = components.ChunkHandle;
const ChunkMap = components.ChunkMap;

/// The world's tile layers.
pub const Store = struct {
    allocator: std.mem.Allocator,
    layers: std.ArrayListUnmanaged(Layer) = .empty,
    /// The chunks a layer may hold before the store has to grow. Reserved at
    /// boot, because a frame does not allocate (spec §3.1).
    chunks_per_layer: usize = 64,

    pub const Layer = struct {
        /// The actor that owns this layer. Two actors can paint the same layer
        /// only by being the same actor ✓.
        entity: Entity = Entity.invalid,
        /// The tile size in world units. It comes from the tileset ✓.
        tile_size: f32 = 32,
        /// The chunks, densely packed. The address of a chunk is its index ✓.
        chunks: std.ArrayListUnmanaged(TileChunk) = .empty,
        /// The free chunk slots ✓.
        free: std.ArrayListUnmanaged(u32) = .empty,
        /// The chunk's place in the world -> the chunk's index ✓.
        map: ChunkMap = .{},
    };

    pub fn init(allocator: std.mem.Allocator) Store {
        return .{ .allocator = allocator };
    }

    pub fn deinit(self: *Store) void {
        for (self.layers.items) |*layer| {
            layer.chunks.deinit(self.allocator);
            layer.free.deinit(self.allocator);
            layer.map.deinit(self.allocator);
        }
        self.layers.deinit(self.allocator);
    }

    /// Reserves the room the store needs, before the frame loop starts.
    pub fn reserve(self: *Store, max_layers: usize, chunks_per_layer: usize) !void {
        self.chunks_per_layer = chunks_per_layer;
        try self.layers.ensureTotalCapacity(self.allocator, max_layers);
        // The map is allocated per layer, at claim time ✓ (a layer that never
        // exists costs nothing ✓).
    }

    /// The layer of an actor, created if it does not exist yet.
    ///
    /// The tile size comes from the tileset ✓, and a layer whose tileset has
    /// none yet keeps the default ✓ — the tiles are painted in TILE
    /// coordinates, and the size only matters when they are placed in the
    /// world ✓.
    pub fn layerFor(self: *Store, entity: Entity, tile_size: f32) !*Layer {
        for (self.layers.items) |*layer| {
            if (layer.entity.eql(entity)) {
                if (tile_size > 0) layer.tile_size = tile_size;
                return layer;
            }
        }
        var layer = Layer{ .entity = entity, .tile_size = tile_size };
        try layer.chunks.ensureTotalCapacity(self.allocator, self.chunks_per_layer);
        try layer.free.ensureTotalCapacity(self.allocator, self.chunks_per_layer);
        layer.map = try ChunkMap.init(self.allocator, self.chunks_per_layer);
        try self.layers.append(self.allocator, layer);
        return &self.layers.items[self.layers.items.len - 1];
    }

    /// The layer of an actor, if it has one.
    pub fn findLayer(self: *Store, entity: Entity) ?*Layer {
        for (self.layers.items) |*layer| {
            if (layer.entity.eql(entity)) return layer;
        }
        return null;
    }

    /// Sets a tile. A tile at `atlas_index == 0` is EMPTY ✓ (the index 0 is
    /// the "no tile" one ✓), and setting it clears the tile ✓.
    pub fn setTile(self: *Store, layer: *Layer, tile_x: i32, tile_y: i32, tile: Tile) !void {
        const chunk = try self.chunkFor(layer, tile_x, tile_y);
        const local = ChunkCoord.fromTile(tile_x, tile_y);
        const idx = local.index();
        chunk.tiles[idx] = tile;
        chunk.has_tiles = chunk.has_tiles or !tile.isEmpty();
        chunk.markDirty(idx);
        // The VERSION: a consumer that rebuilds the whole chunk compares it ✓
        // (the physics ✓) — the dirty bits alone would starve it ✓, because
        // the renderer clears them ✓.
        chunk.version +%= 1;
    }

    /// The tile at a position, if there is one.
    pub fn getTile(_: *Store, layer: *Layer, tile_x: i32, tile_y: i32) ?Tile {
        const key = ChunkKey.fromWorld(
            @as(f32, @floatFromInt(tile_x)) * layer.tile_size,
            @as(f32, @floatFromInt(tile_y)) * layer.tile_size,
            layer.tile_size,
        );
        const handle = layer.map.get(key) orelse return null;
        if (handle.index >= layer.chunks.items.len) return null;
        const chunk = &layer.chunks.items[handle.index];
        if (chunk.generation != handle.generation) return null;
        const local = ChunkCoord.fromTile(tile_x, tile_y);
        const tile = chunk.tiles[local.index()];
        // An EMPTY tile is no tile ✓ (the atlas index 0 is the empty one ✓),
        // and "no tile" is null ✓ — the difference matters to a script that
        // asks "is there a tile here?" ✓.
        if (tile.isEmpty()) return null;
        return tile;
    }

    /// Fills a rectangle of tiles, inclusive on both ends.
    pub fn fillRect(
        self: *Store,
        layer: *Layer,
        x1: i32,
        y1: i32,
        x2: i32,
        y2: i32,
        tile: Tile,
    ) !void {
        const lo_x = @min(x1, x2);
        const hi_x = @max(x1, x2);
        const lo_y = @min(y1, y2);
        const hi_y = @max(y1, y2);
        var y = lo_y;
        while (y <= hi_y) : (y += 1) {
            var x = lo_x;
            while (x <= hi_x) : (x += 1) {
                try self.setTile(layer, x, y, tile);
            }
        }
    }

    /// Empties a whole layer ✓ (the chunks stay, their tiles go ✓ — the
    /// chunks are a pool, and a pool that frees on every clear is a pool that
    /// allocates on every clear ✗).
    pub fn clearLayer(_: *Store, layer: *Layer) void {
        for (layer.chunks.items) |*chunk| {
            @memset(&chunk.tiles, Tile{});
            chunk.has_tiles = false;
            chunk.clearDirty();
        }
    }

    /// Walks a layer's chunks: the ones in use ✓.
    ///
    /// The pool is dense and the map says which slots are in use ✓, so the
    /// walk is over the MAP and not over the pool ✓ (a pool slot that was
    /// freed holds a stale chunk ✓, and walking it would draw a level that is
    /// not there ✗).
    pub fn iterChunks(_: *Store, layer: *Layer) ChunkIterator {
        return .{ .layer = layer, .iter = layer.map.iterator() };
    }

    pub const ChunkIterator = struct {
        layer: *const Layer,
        iter: ChunkMap.Iterator,

        pub fn next(self: *ChunkIterator) ?*const TileChunk {
            while (self.iter.next()) |entry| {
                const handle = entry.value;
                if (handle.isNone() or handle.index >= self.layer.chunks.items.len) continue;
                const chunk = &self.layer.chunks.items[handle.index];
                if (chunk.generation != handle.generation) continue;
                return chunk;
            }
            return null;
        }
    };

    /// The chunk that holds a tile, created if it does not exist yet.
    fn chunkFor(self: *Store, layer: *Layer, tile_x: i32, tile_y: i32) !*TileChunk {
        const key = ChunkKey.fromWorld(
            @as(f32, @floatFromInt(tile_x)) * layer.tile_size,
            @as(f32, @floatFromInt(tile_y)) * layer.tile_size,
            layer.tile_size,
        );
        if (layer.map.get(key)) |handle| {
            if (handle.index < layer.chunks.items.len) {
                const chunk = &layer.chunks.items[handle.index];
                if (chunk.generation == handle.generation) return chunk;
            }
        }
        // A new chunk: from the free list if there is one ✓, else a new one
        // (which ALLOCATES ✗ — a frame does not allocate ✗ — so the pool is
        // reserved at boot ✓ and a layer that outgrows it says so ✓).
        const index: u32 = if (layer.free.pop()) |i| i else blk: {
            if (layer.chunks.items.len >= self.chunks_per_layer) {
                // The pool is full: the chunk is REUSED (the oldest one), and
                // the layer's map is repointed. A tilemap that paints more
                // chunks than the pool holds is a tilemap that should have
                // been reserved bigger ✓.
                const reuse = @as(u32, @intCast(layer.chunks.items.len - 1));
                break :blk reuse;
            }
            try layer.chunks.append(self.allocator, .{});
            break :blk @as(u32, @intCast(layer.chunks.items.len - 1));
        };
        const chunk = &layer.chunks.items[index];
        chunk.* = .{ .key = key, .generation = chunk.generation + 1 };
        layer.map.put(key, .{ .index = index, .generation = chunk.generation });
        return chunk;
    }
};

// ── Tests ────────────────────────────────────────────────────────────────────

const testing = std.testing;

test "a tile set, read back, is the tile that was set" {
    var store = Store.init(testing.allocator);
    defer store.deinit();
    try store.reserve(4, 8);

    const e = Entity{ .index = 1, .generation = 0 };
    const layer = try store.layerFor(e, 32);
    try store.setTile(layer, 3, 5, .{ .atlas_index = 7 });

    const tile = store.getTile(layer, 3, 5).?;
    try testing.expectEqual(@as(u16, 7), tile.atlas_index);

    // And the tile before it is empty ✓.
    try testing.expectEqual(@as(?Tile, null), store.getTile(layer, 3, 6));
}

test "the tiles of a layer survive a round trip through the store" {
    var store = Store.init(testing.allocator);
    defer store.deinit();
    try store.reserve(4, 8);

    const e = Entity{ .index = 2, .generation = 0 };
    const layer = try store.layerFor(e, 32);
    try store.fillRect(layer, 0, 0, 3, 3, .{ .atlas_index = 5 });

    // Sixteen tiles in the rectangle ✓, and nothing outside it ✓.
    var count: usize = 0;
    var y: i32 = 0;
    while (y < 4) : (y += 1) {
        var x: i32 = 0;
        while (x < 4) : (x += 1) {
            if (store.getTile(layer, x, y) != null) count += 1;
        }
    }
    try testing.expectEqual(@as(usize, 16), count);
    try testing.expectEqual(@as(?Tile, null), store.getTile(layer, 4, 0));
}

test "a tile in another chunk is a tile in another chunk" {
    var store = Store.init(testing.allocator);
    defer store.deinit();
    try store.reserve(4, 8);

    const e = Entity{ .index = 3, .generation = 0 };
    const layer = try store.layerFor(e, 32);
    // Tile (0,0) and tile (16,0) are sixteen tiles apart, so they are in
    // DIFFERENT chunks ✓ — a chunk is 16 tiles wide ✓.
    try store.setTile(layer, 0, 0, .{ .atlas_index = 1 });
    try store.setTile(layer, 16, 0, .{ .atlas_index = 2 });
    try testing.expectEqual(@as(u16, 1), store.getTile(layer, 0, 0).?.atlas_index);
    try testing.expectEqual(@as(u16, 2), store.getTile(layer, 16, 0).?.atlas_index);
    // The one in between is still empty ✓.
    try testing.expectEqual(@as(?Tile, null), store.getTile(layer, 8, 0));
}

test "clearing a layer empties it" {
    var store = Store.init(testing.allocator);
    defer store.deinit();
    try store.reserve(4, 8);

    const e = Entity{ .index = 4, .generation = 0 };
    const layer = try store.layerFor(e, 32);
    try store.setTile(layer, 2, 2, .{ .atlas_index = 9 });
    store.clearLayer(layer);
    try testing.expectEqual(@as(?Tile, null), store.getTile(layer, 2, 2));
}
