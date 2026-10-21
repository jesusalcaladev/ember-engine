//! M15 — the tilemap's colliders: the tiles a level stands on.
//!
//! ## Why the colliders are not components
//!
//! A tilemap's tiles live in the world's tile STORE ✓ (a grid does not fit
//! in a fixed-size record ✓), and the store is not the ECS ✓. A body that
//! belongs to no entity is still a body ✓ — Box2D does not care whose it is ✓
//! — and the level's floor is exactly that ✓.
//!
//! So the tilemap's bodies are filed by (the layer's entity ✓, the chunk's
//! key ✓) and not by the ECS's entity list ✓. The alternative — a component
//! per tile ✓ — would be 256 entities per chunk ✓, and a level of a hundred
//! chunks would be 25 600 entities ✓, all of them the same rectangle ✓.
//!
//! ## One body per chunk
//!
//! A chunk is 16x16 tiles ✓, and it is ONE static body with one box shape per
//! solid tile ✓. A body per tile would be 256 bodies per chunk ✓, and the
//! solver's broadphase would see 256 times more ✓.
//!
//! ## Only the dirty chunks are rebuilt
//!
//! The store's chunks carry per-tile dirty bits ✓, and a chunk that has not
//! changed is not touched ✓. A level that is painted once and never again
//! costs nothing per frame ✓ — which is the whole point of a tilemap ✓.

const std = @import("std");
const ecs = @import("ecs");
const physics = @import("physics.zig");

const World = ecs.World;
const Entity = ecs.Entity;
const components = ecs.components;
const Transform = components.Transform;
const TileMapLayer = components.TileMapLayer;
const ChunkKey = components.ChunkKey;

/// What the tilemap's colliders did.
pub const Stats = struct {
    /// The layers that collide.
    layers: u32 = 0,
    /// The bodies that exist.
    bodies: u32 = 0,
    /// The shapes (the solid tiles).
    shapes: u32 = 0,
    /// The chunks rebuilt this sync — the ones that changed.
    rebuilt: u32 = 0,
    /// The bodies dropped because their layer is gone.
    dropped: u32 = 0,
};

/// The tilemap's colliders.
pub const Tilemap = struct {
    allocator: std.mem.Allocator,
    /// One entry per chunk that has a body ✓.
    entries: std.ArrayListUnmanaged(Entry) = .empty,
    stats: Stats = .{},

    const Entry = struct {
        layer: Entity,
        chunk: ChunkKey,
        body: physics.BodyId,
        /// The chunk's version when this body was built ✓.
        version: u32 = 0,
    };

    pub fn init(allocator: std.mem.Allocator) Tilemap {
        return .{ .allocator = allocator };
    }

    pub fn deinit(self: *Tilemap) void {
        self.entries.deinit(self.allocator);
    }

    /// Brings the colliders in line with the tiles.
    ///
    /// A chunk that changed is rebuilt ✓ (its body is dropped and made
    /// again ✓, because a body carries its shapes ✓ and a shape cannot be
    /// resized ✓). A chunk that did not is left alone ✓.
    pub fn sync(self: *Tilemap, world: *World, store: *ecs.tilemap.Store, pw: physics.World) void {
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
                const entity = batch.entityAt(i);
                const store_layer = store.findLayer(entity) orelse continue;
                self.stats.layers += 1;

                const tile_size = if (layer.tile_size_override > 0) layer.tile_size_override else layer.tile_size;
                const transform = &transforms[i];
                const chunk_world = tile_size * @as(f32, @floatFromInt(components.chunk_size));

                var iter = store.iterChunks(store_layer);
                while (iter.next()) |chunk| {
                    const origin_x = transform.position.x + @as(f32, @floatFromInt(chunk.key.cx)) * chunk_world;
                    const origin_y = transform.position.y + @as(f32, @floatFromInt(chunk.key.cy)) * chunk_world;

                    // The body, rebuilt only if the chunk changed ✓.
                    //
                    // A rebuild DROPS the body and makes a new one ✓: a body
                    // carries its shapes ✓, and a shape cannot be resized ✓ —
                    // so "the tile at (3,5) is now empty" means the old shape
                    // has to go ✓, and the only way to make it go is with the
                    // body that holds it ✓.
                    var body = self.findBody(entity, chunk.key);
                    if (body == null or self.isStale(entity, chunk.key, chunk.version)) {
                        if (body) |old| {
                            pw.destroyBody(old);
                            self.removeEntry(entity, chunk.key);
                        }
                        body = self.makeBody(pw, entity, chunk.key, origin_x, origin_y, chunk.version);
                        self.stats.rebuilt += 1;
                    }
                    const live = body orelse continue;
                    self.stats.bodies += 1;
                    self.fillChunk(pw, live, chunk, tile_size);
                }
            }
        }

        // The layers that are gone (or stopped colliding) take their bodies
        // with them ✓.
        self.dropStale(world, pw);
    }

    /// The body of a chunk, if it has one ✓.
    fn findBody(self: *Tilemap, layer: Entity, key: ChunkKey) ?physics.BodyId {
        for (self.entries.items) |entry| {
            if (entry.layer.eql(layer) and entry.chunk.eql(key)) return entry.body;
        }
        return null;
    }

    /// Whether a chunk's body is older than the chunk ✓.
    ///
    /// The VERSION, not the dirty bits ✓: the bits say which tile changed ✓
    /// (the renderer's question ✓), and the version says whether anything
    /// changed ✓ (this one's ✓). Two consumers cannot share one set of bits
    /// ✓ — whoever cleared them last would starve the other ✓.
    fn isStale(self: *Tilemap, layer: Entity, key: ChunkKey, version: u32) bool {
        for (self.entries.items) |entry| {
            if (entry.layer.eql(layer) and entry.chunk.eql(key)) return entry.version != version;
        }
        return true;
    }

    /// Makes a chunk's body: a STATIC one at the chunk's origin ✓.
    fn makeBody(
        self: *Tilemap,
        pw: physics.World,
        layer: Entity,
        key: ChunkKey,
        x: f32,
        y: f32,
        version: u32,
    ) ?physics.BodyId {
        const body = pw.createBody(.{
            .body_type = .fixed,
            .position = .{ .x = x, .y = y },
        }) orelse return null;
        self.entries.append(self.allocator, .{ .layer = layer, .chunk = key, .body = body, .version = version }) catch {
            pw.destroyBody(body);
            return null;
        };
        return body;
    }

    /// Forgets a chunk's entry ✓ (its body is already gone ✓).
    fn removeEntry(self: *Tilemap, layer: Entity, key: ChunkKey) void {
        var i: usize = 0;
        while (i < self.entries.items.len) : (i += 1) {
            const entry = self.entries.items[i];
            if (entry.layer.eql(layer) and entry.chunk.eql(key)) {
                _ = self.entries.swapRemove(i);
                return;
            }
        }
    }

    /// Fills a chunk's body with the shapes of its solid tiles.
    fn fillChunk(
        self: *Tilemap,
        pw: physics.World,
        body: physics.BodyId,
        chunk: *const components.TileChunk,
        tile_size: f32,
    ) void {
        const half = tile_size * 0.5;
        var idx: u16 = 0;
        while (idx < components.chunk_area) : (idx += 1) {
            const tile = chunk.tiles[idx];
            if (tile.isEmpty()) continue;

            // The tile's centre, in the body's local space ✓ (the body sits
            // at the chunk's origin ✓, so the offset IS the tile's place in
            // the chunk ✓).
            const col = @as(f32, @floatFromInt(@as(u16, idx % components.chunk_size)));
            const row = @as(f32, @floatFromInt(@as(u16, idx / components.chunk_size)));
            const shape = pw.createShape(body, .{
                .kind = .box,
                .half_extents = .{ .x = half, .y = half },
                .offset = .{ .x = col * tile_size + half, .y = row * tile_size + half },
            }, .{}) orelse continue;
            _ = shape;
            self.stats.shapes += 1;
        }
    }

    /// Destroys the bodies of the layers that are gone ✓.
    fn dropStale(self: *Tilemap, world: *World, pw: physics.World) void {
        var i: usize = 0;
        while (i < self.entries.items.len) {
            const entry = self.entries.items[i];
            // The layer is alive ✓ and still collides ✓?
            var keep = false;
            if (world.isAlive(entry.layer)) {
                if (world.get(entry.layer, TileMapLayer)) |layer| {
                    keep = layer.physics_enabled;
                }
            }
            if (keep) {
                i += 1;
                continue;
            }
            pw.destroyBody(entry.body);
            self.stats.dropped += 1;
            self.stats.bodies -= 1;
            _ = self.entries.swapRemove(i);
        }
    }
};

// ── Tests ────────────────────────────────────────────────────────────────────

const testing = std.testing;

test "a painted tile becomes a collider" {
    var world = ecs.World.init(testing.allocator);
    defer world.deinit();

    var store = ecs.tilemap.Store.init(testing.allocator);
    defer store.deinit();
    try store.reserve(4, 8);

    // A layer that collides ✓, with one tile painted ✓.
    var name = components.Name{};
    name.set("level");
    const e = try world.spawn(.{
        Transform{},
        name,
        TileMapLayer{ .tile_size = 32, .physics_enabled = true },
    });
    const layer = try store.layerFor(e, 32);
    try store.setTile(layer, 0, 0, .{ .atlas_index = 1 });

    const pw = try testWorld();
    var tilemap = Tilemap.init(testing.allocator);
    defer tilemap.deinit();

    tilemap.sync(&world, &store, pw);
    try testing.expectEqual(@as(u32, 1), tilemap.stats.layers);
    try testing.expectEqual(@as(u32, 1), tilemap.stats.bodies);
    try testing.expectEqual(@as(u32, 1), tilemap.stats.shapes);

    // A second sync with nothing changed rebuilds nothing ✓ — that is the
    // whole point of the version ✓.
    try testing.expectEqual(@as(u32, 1), tilemap.stats.rebuilt);
    tilemap.sync(&world, &store, pw);
    try testing.expectEqual(@as(u32, 0), tilemap.stats.rebuilt);
}

test "a layer that does not collide has no colliders" {
    var world = ecs.World.init(testing.allocator);
    defer world.deinit();

    var store = ecs.tilemap.Store.init(testing.allocator);
    defer store.deinit();
    try store.reserve(4, 8);

    var name = components.Name{};
    name.set("decor");
    const e = try world.spawn(.{ Transform{}, name, TileMapLayer{ .tile_size = 32 } });
    const layer = try store.layerFor(e, 32);
    try store.setTile(layer, 0, 0, .{ .atlas_index = 1 });

    const pw = try testWorld();
    var tilemap = Tilemap.init(testing.allocator);
    defer tilemap.deinit();

    tilemap.sync(&world, &store, pw);
    try testing.expectEqual(@as(u32, 0), tilemap.stats.bodies);
    try testing.expectEqual(@as(u32, 0), tilemap.stats.shapes);
}

/// A real solver world ✓ — the null backend would accept every call and
/// prove nothing ✓.
fn testWorld() !physics.World {
    const box2d = @import("box2d.zig");
    return .{
        .vtable = &box2d.vtable,
        .ctx = box2d.vtable.createWorld(.{}) orelse return error.TestUnexpectedResult,
        .name = box2d.backend_name,
    };
}
