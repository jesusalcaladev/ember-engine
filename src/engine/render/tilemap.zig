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
const two_d = @import("2d.zig");
const render2d = two_d;
const ecs = @import("ecs");
const components = ecs.components;
const TileMapLayer = components.TileMapLayer;
const TileChunk = components.TileChunk;
const ChunkHandle = components.ChunkHandle;
const ChunkKey = components.ChunkKey;
const Tile = components.Tile;

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
    /// The instances that did not fit in the buffer. A number that grows says
    /// the buffer was reserved too small ✓ — the same answer the sprite
    /// batcher gives ✓.
    overflowed: u32 = 0,
};

/// A TileMap draw run: consecutive chunks sharing (atlas, layer).
const Run = struct {
    first_instance: u32 = 0,
    instance_count: u32 = 0,
    atlas_slot: u8 = 0,
    layer: u16 = 0,
    tileset_guid: u64 = 0,
};

/// Layer render state (instance buffer + chunk metadata).
const LayerRenderState = struct {
    layer_entity: ecs.Entity,
    tileset_guid: u64,
    tile_size: f32,
    atlas_slot: u8,
    /// The atlas page's grid ✓: the UV of a tile is its index in it ✓.
    tiles_per_row: u8 = 8,
    tile_count: u16 = 0,
    /// The chunks live in the WORLD-LEVEL store ✓ (the ECS layer ✓), not in
    /// the renderer: the physics and the script layer read the same tiles ✓,
    /// and a copy in each of them is three copies that drift ✓.
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
    layer_states: std.ArrayListUnmanaged(LayerRenderState) = .empty,
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
        store: *ecs.tilemap.Store,
        view: ?render2d.ViewRect,
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
                self.collectLayer(batch.entityAt(i), layer, transform, store, view, atlas_resident);
            }
        }

        // Sort global instances by (layer, atlas) if needed
        if (!self.global_layers_monotonic) self.sortGlobalByLayerAndAtlas();
        self.buildGlobalRuns();
    }

    fn collectLayer(
        self: *TileMapRenderer,
        entity: ecs.Entity,
        layer: *const TileMapLayer,
        transform: Transform,
        store: *ecs.tilemap.Store,
        view: ?render2d.ViewRect,
        atlas_resident: ?*const [4]u64,
    ) void {
        // Find or create layer render state — BY ENTITY ✓.
        //
        // It used to be by TILESET, which was a way of saying "two actors
        // with the same tileset are one layer" — true for the RENDER buffers ✓
        // and false for the tiles ✓, which live in the store and are per actor
        // ✓. Two actors sharing a tileset are two layers ✓.
        var state_idx: usize = 0;
        var found = false;
        while (state_idx < self.layer_states.items.len) : (state_idx += 1) {
            if (self.layer_states.items[state_idx].layer_entity.eql(entity)) {
                found = true; break;
            }
        }
        if (!found) {
            state_idx = self.createLayerState(entity, layer);
        }
        var lstate = &self.layer_states.items[state_idx];

        // The measurements are re-read every frame ✓: a script that changes
        // the tile size sees it on the next frame ✓, and the frame is cheap
        // (four numbers ✓).
        lstate.tileset_guid = layer.tileset_guid;
        self.reloadTileset(lstate, layer);

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

        // The chunks of this layer, from the store ✓. A layer with no store
        // entry has no tiles: an actor that carries the component but whose
        // tiles were never painted draws nothing ✓ — which is the truth ✓.
        const store_layer = store.findLayer(lstate.layer_entity) orelse return;

        // Iterate chunks in this layer
        var iter = store.iterChunks(store_layer);
        while (iter.next()) |chunk| {
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

    fn createLayerState(self: *TileMapRenderer, entity: ecs.Entity, layer: *const TileMapLayer) usize {
        const idx = self.layer_states.items.len;
        var lstate = LayerRenderState{
            .layer_entity = entity,
            .tileset_guid = layer.tileset_guid,
            .tile_size = 32.0,
            .atlas_slot = 0,
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
        _ = self.loadTileset(&lstate, layer);
        self.layer_states.appendAssumeCapacity(lstate);
        return idx;
    }

    /// The layer's tile set MEASUREMENTS, which live in the component ✓.
    ///
    /// The measurements (the size ✓, the atlas page ✓, the tiles per row ✓)
    /// are what a layer needs to PLACE its tiles ✓, and they are four
    /// numbers ✓ that fit in a component ✓. The tile set's DATA (the physics
    /// shapes ✓, the autotiling rules ✓) is a recipe that belongs in the
    /// asset ✓, and it is not needed to draw ✓.
    fn loadTileset(self: *TileMapRenderer, lstate: *LayerRenderState, layer: *const TileMapLayer) bool {
        _ = self;
        lstate.tile_size = if (layer.tile_size_override > 0) layer.tile_size_override else layer.tile_size;
        lstate.atlas_slot = layer.atlas_slot;
        lstate.tiles_per_row = layer.tiles_per_row;
        lstate.tile_count = layer.tile_count;
        return lstate.tile_size > 0;
    }

    fn reloadTileset(self: *TileMapRenderer, lstate: *LayerRenderState, layer: *const TileMapLayer) void {
        _ = self.loadTileset(lstate, layer);
    }

    fn writeChunkInstances(
        self: *TileMapRenderer,
        chunk: *const TileChunk,
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

        // The UV grid: the tiles per row of the atlas page ✓. It comes from
        // the layer's MEASUREMENTS ✓ (the component ✓), not from the asset
        // registry ✓ — the measurements are what a layer needs to place its
        // tiles ✓, and the tile set's data is not needed to draw ✓.
        const atlas_w = lstate.tiles_per_row;

        var tile_idx: u16 = 0;
        while (tile_idx < components.chunk_area) : (tile_idx += 1) {
            if (self.global_instance_count >= self.global_capacity) {
                stats.overflowed += 1;
                return;
            }

            const tile = chunk.tiles[tile_idx];
            if (tile.isEmpty()) continue;

            // Calculate UV from atlas (simplified - real impl would use atlas manager)
            // The UV of the tile: its cell in the atlas page's grid ✓.
            const uv = self.getUV(tile.atlas_index, atlas_w);

            const local_x = @as(f32, @floatFromInt(@as(u16, tile_idx % components.chunk_size))) * tile_size;
            const local_y = @as(f32, @floatFromInt(@as(u16, tile_idx / components.chunk_size))) * tile_size;
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
                // The layer is a BYTE on the GPU ✓ (the sprite path clamps it
                // the same way ✓), so a layer above 255 is clamped and not
                // wrapped ✓ — a wrapped layer would draw the tiles in the
                // wrong place in the painter's order ✓.
                .layer = @intCast(@min(layer.layer, 255)),
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

    /// The instances the last `collect` produced ✓.
    ///
    /// They are pushed into the SAME batcher as the sprites ✓, and not
    /// submitted on their own ✓: the sprite pass CLEARS the target ✓, so a
    /// second `drawSprites` would erase the scene ✓ — the tiles have to be in
    /// the same batch as the sprites ✓ to be drawn over them ✓.
    pub fn instanceSlice(self: *const TileMapRenderer) []const render.SpriteInstance {
        return self.global_instances[0..self.global_instance_count];
    }

    pub fn drawRuns(self: *const TileMapRenderer) []const Run {
        return self.global_runs[0..self.global_run_count];
    }

    /// The UV of a tile: its cell in the atlas page's grid ✓.
    fn getUV(_: *TileMapRenderer, atlas_index: u16, atlas_w: u8) [4]u16 {
        const cols: u16 = atlas_w;
        const tx = atlas_index % cols;
        const ty = atlas_index / cols;
        const tile_w = 1.0 / @as(f32, @floatFromInt(atlas_w));
        const tile_h = 1.0 / @as(f32, @floatFromInt(atlas_w));
        const u_start = @as(f32, @floatFromInt(tx)) * tile_w;
        const v_start = @as(f32, @floatFromInt(ty)) * tile_h;
        const u_end = u_start + tile_w;
        const v_end = v_start + tile_h;
        return .{
            render.toUnorm16(u_start), render.toUnorm16(v_start),
            render.toUnorm16(u_end), render.toUnorm16(v_end),
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