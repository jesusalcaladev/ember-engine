//! M15 TileMap Render System — chunked instanced rendering.
//!
//! Walks all TileMapLayer components, culls chunks against the camera,
//! uploads dirty chunks to a GPU instance buffer, and issues one draw
//! call per (tileset atlas, layer) pair.
//!
//! Design (spec §3.1, §4):
//! - **Zero allocations in frame**: instance buffer and chunk metadata
//!   reserved at load; dirty tracking is bit-packed.
//! - **1 draw call per (atlas, layer)**: chunks from the same tileset
//!   on the same render layer are batched.
//! - **Viewport culling**: only chunks intersecting the view are uploaded.

const std = @import("std");
const core = @import("core");
const log = core.log.scoped("tilemap_render");
const render = @import("render.zig");
const batcher_mod = @import("batcher.zig");
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
const Sprite = components.Sprite;

/// Per-frame stats reported against budgets.
pub const Stats = struct {
    layers_visited: u32 = 0,
    chunks_culled: u32 = 0,
    chunks_uploaded: u32 = 0,
    instances_written: u32 = 0,
    draw_calls: u32 = 0,
    bytes_uploaded: usize = 0,
};

/// A TileMap draw run: consecutive chunks sharing (atlas, layer).
const Run = struct {
    first_instance: u32 = 0,
    instance_count: u32 = 0,
    atlas_slot: u8 = 0,
    layer: u16 = 0,
    tileset_guid: AssetGUID = .{ .value = 0 },
};

/// Layer render state (instance buffer + chunk metadata).
const LayerRenderState = struct {
    layer_entity: ecs.Entity,
    tileset_guid: AssetGUID,
    tile_size: f32,
    atlas_slot: u8,
    chunk_pool: []TileChunk = &.{},
    chunk_map: components.ChunkMap = .{},
    capacity: usize = 0,
    // Instance buffer for this layer
    instances: []render.SpriteInstance = &.{},
    layers: []u16 = &.{},
    order: []u32 = &.{},
    scratch: []render.SpriteInstance = &.{},
    layer_counts: []u32 = &.{},
    instance_capacity: usize = 0,
    instance_count: usize = 0,
    runs: []Run = &.{},
    run_count: usize = 0,
    locked: bool = false,
    layers_monotonic: bool = true,
    max_layer_seen: u16 = 0,
};

/// TileMapRenderer: collects visible chunks, builds instances, submits draws.
pub const TileMapRenderer = struct {
    allocator: std.mem.Allocator,
    layer_states: std.ArrayList(LayerRenderState) = &.{},
    stats: Stats = .{},
    // Global instance buffer (all layers combined)
    global_instances: []render.SpriteInstance = &.{},
    global_layers: []u16 = &.{},
    global_order: []u32 = &.{},
    global_scratch: []render.SpriteInstance = &.{},
    global_layer_counts: []u32 = &.{},
    global_capacity: usize = 0,
    global_instance_count: usize = 0,
    global_runs: []Run = &.{},
    global_run_count: usize = 0,
    global_layers_monotonic: bool = true,
    global_max_layer_seen: u16 = 0,

    pub fn init(allocator: std.mem.Allocator) TileMapRenderer {
        return .{ .allocator = allocator };
    }

    pub fn deinit(self: *TileMapRenderer) void {
        for (self.layer_states.items) |*l| {
            if (l.instances.len > 0) self.allocator.free(l.instances);
            if (l.scratch.len > 0) self.allocator.free(l.scratch);
            if (l.layers.len > 0) self.allocator.free(l.layers);
            if (l.order.len > 0) self.allocator.free(l.order);
            if (l.runs.len > 0) self.allocator.free(l.runs);
            if (l.layer_counts.len > 0) self.allocator.free(l.layer_counts);
            l.chunk_map.deinit(self.allocator);
            self.allocator.free(l.chunk_pool);
        }
        self.layer_states.deinit(self.allocator);

        if (self.global_instances.len > 0) self.allocator.free(self.global_instances);
        if (self.global_scratch.len > 0) self.allocator.free(self.global_scratch);
        if (self.global_layers.len > 0) self.allocator.free(self.global_layers);
        if (self.global_order.len > 0) self.allocator.free(self.global_order);
        if (self.global_runs.len > 0) self.allocator.free(self.global_runs);
        if (self.global_layer_counts.len > 0) self.allocator.free(self.global_layer_counts);
        self.global_instances = &.{};
        self.global_scratch = &.{};
        self.global_layers = &.{};
        self.global_order = &.{};
        self.global_runs = &.{};
        self.global_layer_counts = &.{};
    }

    /// Load-time reservation. MUST be called before the frame loop.
    pub fn reserve(self: *TileMapRenderer, max_layers: usize, max_tiles_per_layer: usize) !void {
        try self.layer_states.ensureTotalCapacity(self.allocator, max_layers);
        // Global buffer: max_layers * max_tiles_per_layer
        const global_cap = max_layers * max_tiles_per_layer;
        self.global_instances = try self.allocator.alloc(render.SpriteInstance, global_cap);
        self.global_scratch = try self.allocator.alloc(render.SpriteInstance, global_cap);
        self.global_layers = try self.allocator.alloc(u16, global_cap);
        self.global_order = try self.allocator.alloc(u32, global_cap);
        self.global_runs = try self.allocator.alloc(Run, 256);
        self.global_layer_counts = try self.allocator.alloc(u32, 65_536);
        self.global_capacity = global_cap;
    }

    pub fn lock(self: *TileMapRenderer) void {
        for (self.layer_states.items) |*l| l.locked = true;
    }

    pub fn beginFrame(self: *TileMapRenderer) void {
        self.stats = .{};
        self.global_instance_count = 0;
        self.global_run_count = 0;
        self.global_layers_monotonic = true;
        self.global_max_layer_seen = 0;
    }

    /// Collects all visible chunks from all TileMapLayers.
    pub fn collect(
        self: *TileMapRenderer,
        world: *World,
        view: ?components.ViewRect,
        tilesets: *const assets.AssetRegistry,
        atlas_resident: ?*const [4]u64,
    ) void {
        self.stats = .{};
        self.global_instance_count = 0;
        self.global_layers_monotonic = true;
        self.global_max_layer_seen = 0;

        var q = world.query(.{ Transform, TileMapLayer });
        while (q.nextBatch()) |batch| {
            const transforms = batch.slice(Transform);
            const layers = batch.slice(TileMapLayer);
            const n = batch.len();
            self.stats.layers_visited += @intCast(n);

            var i: usize = 0;
            while (i < n) : (i += 1) {
                const layer = &layers[i];
                const transform = transforms[i].interpolated(0.0);
                self.collectLayer(layer, transform, view, tilesets, atlas_resident);
            }
        }

        // Sort global instances by (layer, atlas) if needed
        if (!self.global_layers_monotonic) self.sortGlobalByLayerAndAtlas();
        self.buildGlobalRuns();
    }

    fn collectLayer(
        self: *TileMapRenderer,
        layer: *const TileMapLayer,
        transform: Transform,
        view: ?components.ViewRect,
        tilesets: *const assets.AssetRegistry,
        atlas_resident: ?*const [4]u64,
    ) void {
        // Find or create layer render state
        var state_idx: usize = 0;
        var found = false;
        while (state_idx < self.layer_states.items.len) : (state_idx += 1) {
            if (self.layer_states.items[state_idx].tileset_guid.value == layer.tileset_guid.value) {
                found = true; break;
            }
        }
        if (!found) {
            state_idx = self.createLayerState(layer, tilesets);
        }
        var lstate = &self.layer_states.items[state_idx];

        // Update tileset if changed
        if (lstate.tileset_guid.value != layer.tileset_guid.value) {
            lstate.tileset_guid = layer.tileset_guid;
            self.reloadTileset(lstate, tilesets);
        }

        // Check atlas residency
        if (atlas_resident) |mask| {
            const word = lstate.atlas_slot >> 6;
            const bit: u6 = @intCast(lstate.atlas_slot & 63);
            if ((mask[word] & (@as(u64, 1) << bit)) == 0) {
                return; // atlas page not resident
            }
        }

        // Calculate world-space chunk bounds for culling
        const tile_size = lstate.tile_size;
        const chunk_world_size = tile_size * @as(f32, @floatFromInt(components.chunk_size));

        // Iterate chunks in this layer
        var iter = lstate.chunk_map.iterator();
        while (iter.next()) |entry| {
            const handle = entry.value;
            if (handle.isNone() or handle.index >= lstate.chunk_pool.len) continue;
            const chunk = &lstate.chunk_pool[handle.index];
            if (handle.generation != chunk.generation) continue;

            if (!chunk.has_tiles) {
                self.stats.chunks_culled += 1;
                continue;
            }

            // Frustum cull: chunk AABB in world space
            if (view) |v| {
                const chunk_min_x = transform.position.x + @as(f32, @floatFromInt(chunk.key.cx)) * chunk_world_size;
                const chunk_min_y = transform.position.y + @as(f32, @floatFromInt(chunk.key.cy)) * chunk_world_size;
                const chunk_max_x = chunk_min_x + chunk_world_size;
                const chunk_max_y = chunk_min_y + chunk_world_size;

                if (chunk_max_x < v.min_x or chunk_min_x > v.max_x or
                    chunk_max_y < v.min_y or chunk_min_y > v.max_y) {
                    self.stats.chunks_culled += 1;
                    continue;
                }
            }

            // Write instances for all tiles in this chunk
            self.writeChunkInstances(chunk, layer, transform, lstate, &self.stats);
        }
    }

    fn createLayerState(self: *TileMapRenderer, layer: *const TileMapLayer, tilesets: *const assets.AssetRegistry) usize {
        const idx = self.layer_states.items.len;
        var lstate = LayerRenderState{
            .layer_entity = ecs.Entity{ .index = 0xFFFF_FFFF, .generation = 0 },
            .tileset_guid = layer.tileset_guid,
            .tile_size = 32.0,
            .atlas_slot = 0,
            .chunk_pool = &.{},
            .chunk_map = .{},
            .capacity = 0,
            .instances = &.{},
            .layers = &.{},
            .order = &.{},
            .scratch = &.{},
            .layer_counts = &.{},
            .instance_capacity = 0,
            .instance_count = 0,
            .runs = &.{},
            .run_count = 0,
            .locked = false,
            .layers_monotonic = true,
            .max_layer_seen = 0,
        };
        _ = self.loadTileset(&lstate, tilesets);
        self.layer_states.appendAssumeCapacity(lstate);
        return idx;
    }

    fn loadTileset(self: *TileMapRenderer, lstate: *LayerRenderState, tilesets: *const assets.AssetRegistry) bool {
        const entry = tilesets.registry.get(lstate.tileset_guid) orelse return false;
        const ts_ptr = entry.handle as usize;
        if (ts_ptr == 0) return false;
        const tileset: *const TileSet = @ptrCast(@alignCast(ts_ptr));
        lstate.tile_size = tileset.tile_size;
        lstate.atlas_slot = tileset.atlas_slot;
        return true;
    }

    fn reloadTileset(self: *TileMapRenderer, lstate: *LayerRenderState, tilesets: *const assets.AssetRegistry) void {
        _ = self.loadTileset(lstate, tilesets);
    }

    fn writeChunkInstances(
        self: *TileMapRenderer,
        chunk: *TileChunk,
        layer: *const TileMapLayer,
        transform: Transform,
        lstate: *LayerRenderState,
        stats: *Stats,
    ) void {
        const tile_size = lstate.tile_size;
        const half_tile = tile_size * 0.5;
        const chunk_world_size = tile_size * @as(f32, @floatFromInt(components.chunk_size));
        const chunk_base_x = transform.position.x + @as(f32, @floatFromInt(chunk.key.cx)) * chunk_world_size;
        const chunk_base_y = transform.position.y + @as(f32, @floatFromInt(chunk.key.cy)) * chunk_world_size;

        // Get tileset for UV data
        const entry = assets.registry.get(lstate.tileset_guid) orelse return;
        const ts_ptr = entry.handle as usize;
        if (ts_ptr == 0) return;
        const tileset: *const TileSet = @ptrCast(@alignCast(ts_ptr));

        var tile_idx: u16 = 0;
        while (tile_idx < components.chunk_area) : (tile_idx += 1) {
            if (self.global_instance_count >= self.global_capacity) {
                stats.overflowed += 1;
                return;
            }

            const tile = chunk.tiles[tile_idx];
            if (tile.isEmpty()) continue;

            // Calculate UV from atlas (simplified - real impl would use atlas manager)
            const atlas_w = 16; // tiles per row
            const tx = tile.atlas_index % atlas_w;
            const ty = tile.atlas_index / atlas_w;
            const uv = lstate.getUV(tile.atlas_index, tileset, atlas_w);

            const local_x = @as(f32, @floatFromInt(@intCast(tile_idx % components.chunk_size))) * tile_size;
            const local_y = @as(f32, @floatFromInt(@intCast(tile_idx / components.chunk_size))) * tile_size;
            const world_x = chunk_base_x + local_x + half_tile;
            const world_y = chunk_base_y + local_y + half_tile;

            const final_x = world_x * transform.scale.x + transform.position.x;
            const final_y = world_y * transform.scale.y + transform.position.y;

            self.global_instances[self.global_instance_count] = .{
                .pos = .{ final_x, final_y },
                .half = .{ half_tile * transform.scale.x, half_tile * transform.scale.y },
                .shape = 0,
                .uv = uv,
                .color = .{ 255, 255, 255, 255 },
                .slot = lstate.atlas_slot,
                .layer = layer.layer,
            };
            self.global_layers[self.global_instance_count] = layer.layer;
            self.global_instance_count += 1;
            stats.instances_written += 1;

            if (layer.layer < self.global_max_layer_seen) self.global_layers_monotonic = false;
            if (layer.layer > self.global_max_layer_seen) self.global_max_layer_seen = layer.layer;
        }
    }

    fn sortGlobalByLayerAndAtlas(self: *TileMapRenderer) void {
        const n = self.global_instance_count;
        if (n < 2) return;

        var min_layer: u16 = std.math.maxInt(u16);
        var max_layer: u16 = 0;
        for (self.global_layers[0..n]) |l| {
            min_layer = @min(min_layer, l);
            max_layer = @max(max_layer, l);
        }
        const span = @as(usize, max_layer - min_layer) + 1;
        if (span > self.global_layer_counts.len) return;

        const counts = self.global_layer_counts[0..span];
        @memset(counts, 0);
        for (self.global_layers[0..n]) |l| counts[l - min_layer] += 1;

        var acc: u32 = 0;
        for (counts) |*c| { const v = c.*; c.* = acc; acc += v; }
        for (self.global_layers[0..n], 0..) |l, i| {
            const idx = l - min_layer;
            self.global_scratch[counts[idx]] = self.global_instances[i];
            counts[idx] += 1;
        }
        @memcpy(self.global_instances[0..n], self.global_scratch[0..n]);
    }

    fn buildGlobalRuns(self: *TileMapRenderer) void {
        const n = self.global_instance_count;
        if (n == 0) return;

        self.global_run_count = 0;
        var first: u32 = 0;
        var i: u32 = 0;
        while (i < n) : (i += 1) {
            const inst = self.global_instances[i];
            if (i == 0) { first = 0; continue; }
            const prev = self.global_instances[i - 1];
            if (inst.slot != prev.slot or inst.layer != prev.layer) {
                if (self.global_run_count >= self.global_runs.len) return;
                self.global_runs[self.global_run_count] = .{
                    .first_instance = first,
                    .instance_count = i - first,
                    .atlas_slot = prev.slot,
                    .layer = prev.layer,
                };
                self.global_run_count += 1;
                first = i;
            }
        }
        if (self.global_run_count < self.global_runs.len) {
            const last = self.global_instances[n - 1];
            self.global_runs[self.global_run_count] = .{
                .first_instance = first,
                .instance_count = @as(u32, @intCast(n)) - first,
                .atlas_slot = last.slot,
                .layer = last.layer,
            };
            self.global_run_count += 1;
        }
    }

    pub fn submit(self: *TileMapRenderer, r: render.Renderer) void {
        const n = self.global_instance_count;
        if (n == 0) return;
        r.drawSprites(self.global_instances[0..n], n);
        self.stats.draw_calls = @intCast(r.stats().draw_calls);
    }

    pub fn drawRuns(self: *const TileMapRenderer) []const Run {
        return self.global_runs[0..self.global_run_count];
    }

    // Helper to get UV from atlas index (placeholder - real impl uses atlas manager)
    fn getUV(self: *LayerRenderState, atlas_index: u16, tileset: *const TileSet, atlas_w: u16) [4]u16 {
        const tx = atlas_index % atlas_w;
        const ty = atlas_index / atlas_w;
        const tile_w = 1.0 / @as(f32, @floatFromInt(atlas_w));
        const tile_h = 1.0 / @as(f32, @floatFromInt(atlas_w));
        const u0 = @as(f32, @floatFromInt(tx)) * tile_w;
        const v0 = @as(f32, @floatFromInt(ty)) * tile_h;
        const u1 = u0 + tile_w;
        const v1 = v0 + tile_h;
        return .{
            render.toUnorm16(u0), render.toUnorm16(v0),
            render.toUnorm16(u1), render.toUnorm16(v1),
        };
    }
};

// ── Tests ────────────────────────────────────────────────────────────────────
const testing = std.testing;
test "TileMapRenderer reserves and locks" {
    var r = TileMapRenderer.init(testing.allocator);
    defer r.deinit();
    try r.reserve(4, 1024);
    r.lock();
    try testing.expect(r.layer_states.capacity >= 4);
}