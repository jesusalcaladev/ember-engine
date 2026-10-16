//! M15 TileMap Physics System — owns chunk storage and physics bodies.
//!
//! One system per world. Owns all TileChunk pools for physics-enabled layers.
//! Creates/destroys static physics bodies per layer, manages per-tile shapes.

const std = @import("std");
const core = @import("core");
const log = core.log.scoped("tilemap_physics");
const physics = @import("physics");
const ecs = @import("ecs");
const components = ecs.components;
const TileMapLayer = components.TileMapLayer;
const TileChunk = components.TileChunk;
const ChunkHandle = components.ChunkHandle;
const ChunkKey = components.ChunkKey;
const Tile = components.Tile;
const assets = @import("assets");
const AssetGUID = assets.AssetGUID;
const TileSet = assets.TileSet;
const TilePhysics = assets.TilePhysics;

const World = ecs.World;
const Transform = components.Transform;

/// Per-frame stats.
pub const Stats = struct {
    layers_processed: u32 = 0,
    chunks_rebuilt: u32 = 0,
    shapes_created: u32 = 0,
    shapes_destroyed: u32 = 0,
};

/// Per-layer system state (chunk pool + physics body).
const LayerState = struct {
    layer_entity: ecs.Entity,
    tileset_guid: AssetGUID,
    tile_size: f32,
    chunk_pool: []TileChunk = &.{},
    chunk_map: components.ChunkMap = .{},
    physics_body: physics.BodyId = physics.BodyId.none,
    physics_dirty: bool = false,
    capacity: usize = 0,
};

/// TileMapPhysicsSystem: syncs TileMapLayer tiles to Box2D shapes.
pub const TileMapPhysicsSystem = struct {
    allocator: std.mem.Allocator,
    layers: std.ArrayList(LayerState) = &.{},
    stats: Stats = .{},

    pub fn init(allocator: std.mem.Allocator) TileMapPhysicsSystem {
        return .{ .allocator = allocator };
    }

    pub fn deinit(self: *TileMapPhysicsSystem) void {
        for (self.layers.items) |*l| {
            l.chunk_map.deinit(self.allocator);
            self.allocator.free(l.chunk_pool);
        }
        self.layers.deinit(self.allocator);
        self.* = undefined;
    }

    /// Reserve space for max_layers layers, each with max_chunks_per_layer chunks.
    pub fn reserve(self: *TileMapPhysicsSystem, max_layers: usize, max_chunks_per_layer: usize) !void {
        try self.layers.ensureTotalCapacity(self.allocator, max_layers);
        // Individual layer pools are reserved on first sync.
        _ = max_chunks_per_layer;
    }

    pub fn beginFrame(self: *TileMapPhysicsSystem) void { self.stats = .{}; }

    /// Sync all TileMapLayer components with physics_enabled to the physics world.
    pub fn sync(
        self: *TileMapPhysicsSystem,
        world: *World,
        physics_world: physics.World,
        assets: *const assets.AssetRegistry,
    ) void {
        self.stats = .{};

        var q = world.query(.{ Transform, TileMapLayer });
        while (q.nextBatch()) |batch| {
            const transforms = batch.slice(Transform);
            const layers = batch.slice(TileMapLayer);
            const n = batch.len();

            var i: usize = 0;
            while (i < n) : (i += 1) {
                const layer = &layers[i];
                if (!layer.physics_enabled) continue;
                const transform = transforms[i];
                self.syncLayer(layer, transform, world, physics_world, assets);
                self.stats.layers_processed += 1;
            }
        }
    }

    fn syncLayer(
        self: *TileMapPhysicsSystem,
        layer: *const TileMapLayer,
        transform: Transform,
        world: *World,
        physics_world: physics.World,
        assets: *const assets.AssetRegistry,
    ) void {
        // Find or create layer state
        var layer_idx: usize = 0;
        var found = false;
        while (layer_idx < self.layers.items.len) : (layer_idx += 1) {
            if (self.layers.items[layer_idx].tileset_guid.value == layer.tileset_guid.value) {
                found = true; break;
            }
        }
        if (!found) {
            layer_idx = self.addLayer(layer, world, physics_world, assets);
        }
        var lstate = &self.layers.items[layer_idx];

        // Update tileset if changed
        if (lstate.tileset_guid.value != layer.tileset_guid.value) {
            lstate.tileset_guid = layer.tileset_guid;
            self.reloadTileset(lstate, assets);
        }

        // Update tile_size if overridden
        const tile_size = if (layer.tile_size_override > 0) layer.tile_size_override else lstate.tile_size;

        // Ensure physics body exists
        if (lstate.physics_body.isNone()) {
            lstate.physics_body = physics_world.createBody(physics.BodyDesc{
                .body_type = .fixed,
                .position = transform.position,
                .allow_sleep = true,
                .awake = false,
            }) orelse return;
        } else {
            physics_world.setTransform(lstate.physics_body, physics.Transform{
                .position = transform.position,
                .rotation = transform.rotation,
            });
        }

        // Sync dirty chunks
        var iter = lstate.chunk_map.iterator();
        while (iter.next()) |entry| {
            const handle = entry.value;
            if (handle.isNone() or handle.index >= lstate.chunk_pool.len) continue;
            const chunk = &lstate.chunk_pool[handle.index];
            if (handle.generation != chunk.generation) continue;

            if (!chunk.has_tiles) continue;

            if (chunk.anyDirty() or lstate.physics_dirty) {
                self.rebuildChunkShapes(chunk, lstate, transform, tile_size, physics_world);
                self.stats.chunks_rebuilt += 1;
            }
        }
        lstate.physics_dirty = false;
    }

    fn addLayer(
        self: *TileMapPhysicsSystem,
        layer: *const TileMapLayer,
        world: *World,
        physics_world: physics.World,
        assets: *const assets.AssetRegistry,
    ) usize {
        const idx = self.layers.items.len;
        var lstate = LayerState{
            .layer_entity = ecs.Entity{ .index = 0xFFFF_FFFF, .generation = 0 },
            .tileset_guid = layer.tileset_guid,
            .tile_size = 32.0,
            .chunk_pool = &.{},
            .chunk_map = .{},
            .physics_body = physics.BodyId.none,
            .physics_dirty = true,
            .capacity = 0,
        };
        _ = self.loadTileset(&lstate, assets);
        self.layers.appendAssumeCapacity(lstate);
        return idx;
    }

    fn loadTileset(self: *TileMapPhysicsSystem, lstate: *LayerState, assets: *const assets.AssetRegistry) bool {
        const entry_opt = assets.registry.get(lstate.tileset_guid) orelse return false;
        const entry = entry_opt.?;
        const ts_ptr = @intCast(entry.handle);
        if (ts_ptr == 0) return false;
        const tileset: *const TileSet = @ptrCast(@alignCast(ts_ptr));
        lstate.tile_size = tileset.tile_size;
        return true;
    }

    fn reloadTileset(self: *TileMapPhysicsSystem, lstate: *LayerState, assets: *const assets.AssetRegistry) void {
        _ = self.loadTileset(lstate, assets);
        lstate.physics_dirty = true;
    }

    fn rebuildChunkShapes(
        self: *TileMapPhysicsSystem,
        chunk: *TileChunk,
        lstate: *LayerState,
        transform: Transform,
        tile_size: f32,
        physics_world: physics.World,
    ) void {
        const body_id = lstate.physics_body;
        const chunk_base_x = transform.position.x + @as(f32, @floatFromInt(chunk.key.cx)) * tile_size * 16.0;
        const chunk_base_y = transform.position.y + @as(f32, @floatFromInt(chunk.key.cy)) * tile_size * 16.0;

        // Get tileset for physics data
        const entry_opt = assets.registry.get(lstate.tileset_guid) orelse return;
        const entry = entry_opt.?;
        const ts_ptr = @intCast(entry.handle);
        if (ts_ptr == 0) return;
        const tileset: *const TileSet = @ptrCast(@alignCast(ts_ptr));

        var tile_idx: u16 = 0;
        while (tile_idx < components.chunk_area) : (tile_idx += 1) {
            const tile = chunk.tiles[tile_idx];
            if (tile.isEmpty()) continue;

            const phys_idx = @intCast(tile.atlas_index);
            if (phys_idx == 0 or phys_idx > tileset.tile_count) continue;
            const phys = &tileset.physics[phys_idx - 1];
            if (phys.shape == .none) continue;

            const shape_desc = physics.Shape{
                .kind = phys.shape,
                .filter = phys.filter,
                .half_extents = .{
                    .x = phys.half_extents.x * tile_size,
                    .y = phys.half_extents.y * tile_size,
                },
                .radius = phys.radius * tile_size,
                .offset = .{
                    .x = chunk_base_x + @as(f32, @floatFromInt(@intCast(tile_idx % components.chunk_size))) * tile_size + (phys.half_extents.x * tile_size) - transform.position.x,
                    .y = chunk_base_y + @as(f32, @floatFromInt(@intCast(tile_idx / components.chunk_size))) * tile_size + (phys.half_extents.y * tile_size) - transform.position.y,
                },
                .is_sensor = phys.is_sensor,
            };

            if (phys.shape == .polygon) {
                shape_desc.polygon_count = phys.polygon_count;
                for (0..phys.polygon_count) |i| {
                    shape_desc.polygon[i] = .{
                        .x = phys.polygon[i].x * tile_size,
                        .y = phys.polygon[i].y * tile_size,
                    };
                }
            }

            const mat = physics.Material{
                .density = 0.0, .friction = 0.3, .restitution = 0.0,
            };

            _ = physics_world.createShape(body_id, shape_desc, mat) orelse continue;
            self.stats.shapes_created += 1;
        }
        chunk.clearDirty();
    }

    /// Called when a tile is modified in the editor/gameplay.
    pub fn markTileDirty(layer_state: *LayerState, chunk_key: ChunkKey, local_index: u16) void {
        if (layer_state.chunk_map.get(chunk_key)) |handle| {
            if (!handle.isNone() and handle.index < layer_state.chunk_pool.len) {
                const chunk = &layer_state.chunk_pool[handle.index];
                if (handle.generation == chunk.generation) {
                    chunk.markDirty(local_index);
                    layer_state.physics_dirty = true;
                }
            }
        }
    }

    /// Set a tile in a layer (editor/runtime API).
    /// Returns the LayerState index, or null if tileset not loaded.
    pub fn setTile(
        self: *TileMapPhysicsSystem,
        tileset_guid: AssetGUID,
        tile_x: i32,
        tile_y: i32,
        tile: Tile,
    ) ?usize {
        var layer_idx: usize = 0;
        var found = false;
        while (layer_idx < self.layers.items.len) : (layer_idx += 1) {
            if (self.layers.items[layer_idx].tileset_guid.value == tileset_guid.value) {
                found = true; break;
            }
        }
        if (!found) return null;

        var lstate = &self.layers.items[layer_idx];
        const tile_size = lstate.tile_size;
        const chunk_key = ChunkKey.fromWorld(
            @as(f32, @floatFromInt(tile_x)) * tile_size,
            @as(f32, @floatFromInt(tile_y)) * tile_size,
            tile_size,
        );

        // Get or create chunk
        var handle = lstate.chunk_map.get(chunk_key) orelse {
            handle = self.createChunk(lstate, chunk_key) orelse return null;
        };

        if (handle.isNone() or handle.index >= lstate.chunk_pool.len) return null;
        const chunk = &lstate.chunk_pool[handle.index];
        if (handle.generation != chunk.generation) return null;

        const local = components.ChunkCoord.fromTile(tile_x, tile_y);
        const idx = local.index();
        var chunk_tile = chunk.tiles[idx];
        if (chunk_tile.atlas_index == tile.atlas_index and chunk_tile.flags == tile.flags and chunk_tile.user == tile.user) {
            return layer_idx; // no change
        }

        chunk.tiles[idx] = tile;
        chunk.has_tiles = true;
        chunk.markDirty(idx);
        lstate.physics_dirty = true;
        return layer_idx;
    }

    fn createChunk(self: *TileMapPhysicsSystem, lstate: *LayerState, chunk_key: ChunkKey) ?ChunkHandle {
        // Grow pool if needed
        if (lstate.chunk_pool.len == lstate.capacity) {
            const new_cap = if (lstate.capacity == 0) 64 else lstate.capacity * 2;
            const new_pool = try self.allocator.alloc(TileChunk, new_cap);
            if (lstate.chunk_pool.len > 0) {
                @memcpy(new_pool[0..lstate.chunk_pool.len], lstate.chunk_pool[0..lstate.chunk_pool.len]);
                self.allocator.free(lstate.chunk_pool);
            }
            lstate.chunk_pool = new_pool;
            lstate.capacity = new_cap;

            // Rebuild chunk_map with new capacity
            lstate.chunk_map.deinit(self.allocator);
            lstate.chunk_map = try components.ChunkMap.init(self.allocator, new_cap * 2);
        }

        const new_idx = lstate.chunk_pool.len;
        lstate.chunk_pool[new_idx] = TileChunk{ .key = chunk_key, .generation = 1 };
        lstate.chunk_pool.len += 1;

        const handle = ChunkHandle{ .index = @intCast(new_idx), .generation = 1 };
        lstate.chunk_map.put(chunk_key, handle);
        return handle;
    }

    /// Fill a rectangle with a tile (editor helper).
    pub fn fillRect(
        self: *TileMapPhysicsSystem,
        tileset_guid: AssetGUID,
        x1: i32, y1: i32, x2: i32, y2: i32,
        atlas_index: u16,
    ) ?usize {
        var layer_idx: usize = 0;
        var found = false;
        while (layer_idx < self.layers.items.len) : (layer_idx += 1) {
            if (self.layers.items[layer_idx].tileset_guid.value == tileset_guid.value) {
                found = true; break;
            }
        }
        if (!found) return null;

        var lstate = &self.layers.items[layer_idx];
        const tile_size = lstate.tile_size;

        var min_x = @min(x1, x2);
        var max_x = @max(x1, x2);
        var min_y = @min(y1, y2);
        var max_y = @max(y1, y2);

        var y = min_y;
        while (y <= max_y) : (y += 1) {
            var x = min_x;
            while (x <= max_x) : (x += 1) {
                const tile = Tile{ .atlas_index = atlas_index, .flags = 0, .user = 0 };
                _ = self.setTile(tileset_guid, x, y, tile);
            }
        }
        return layer_idx;
    }

    /// Erase a rectangle (set tiles to empty).
    pub fn eraseRect(
        self: *TileMapPhysicsSystem,
        tileset_guid: AssetGUID,
        x1: i32, y1: i32, x2: i32, y2: i32,
    ) ?usize {
        return self.fillRect(tileset_guid, x1, y1, x2, y2, 0);
    }

    /// Get tile at coordinates.
    pub fn getTile(
        self: *TileMapPhysicsSystem,
        tileset_guid: AssetGUID,
        tile_x: i32,
        tile_y: i32,
    ) ?Tile {
        var layer_idx: usize = 0;
        var found = false;
        while (layer_idx < self.layers.items.len) : (layer_idx += 1) {
            if (self.layers.items[layer_idx].tileset_guid.value == tileset_guid.value) {
                found = true; break;
            }
        }
        if (!found) return null;

        const lstate = &self.layers.items[layer_idx];
        const tile_size = lstate.tile_size;
        const chunk_key = ChunkKey.fromWorld(
            @as(f32, @floatFromInt(tile_x)) * tile_size,
            @as(f32, @floatFromInt(tile_y)) * tile_size,
            tile_size,
        );

        const handle = lstate.chunk_map.get(chunk_key) orelse return null;
        if (handle.isNone() or handle.index >= lstate.chunk_pool.len) return null;
        const chunk = &lstate.chunk_pool[handle.index];
        if (handle.generation != chunk.generation) return null;

        const local = components.ChunkCoord.fromTile(tile_x, tile_y);
        const idx = local.index();
        return chunk.tiles[idx];
    }
};

// ── Tests ────────────────────────────────────────────────────────────────────
const testing = std.testing;
test "TileMapPhysicsSystem reserves and syncs" {
    var sys = TileMapPhysicsSystem.init(testing.allocator);
    defer sys.deinit();
    try sys.reserve(4, 64);
    try testing.expect(sys.layers.capacity == 4);
}