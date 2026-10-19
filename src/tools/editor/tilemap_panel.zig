//! `editor.tilemap_panel` — the tile painting workspace.
//!
//! ## Why the storage is here and not in the component
//!
//! `TileMapLayer` is plain data on purpose (spec §7): no slices, no pointers,
//! no allocator. The chunk pool therefore belongs to whoever owns the editing
//! session, and that is this file. `Store` is a dense array of chunks behind a
//! `ChunkMap`, which is the same shape the runtime's system uses — so moving
//! this into `physics/tilemap.zig` when it is un-parked is a move, not a
//! rewrite.
//!
//! ## What is real here
//!
//! The brushes write tiles, the palette picks one, the layer row toggles
//! physics, and `pushTiles` hands the painted result to the 2D batcher. The one
//! thing the panel does NOT do yet is resolve an atlas texture: tiles draw from
//! the white 1×1 slot and read as flat coloured cells, which is exactly what an
//! editor wants while the art is not final.

const std = @import("std");
const engine = @import("engine");
const ui = @import("ui");
const c = ui.cimgui;
const ecs = engine.ecs;
const components = ecs.components;
const Tile = components.Tile;
const ChunkKey = components.ChunkKey;
const ChunkCoord = components.ChunkCoord;
const TileChunk = components.TileChunk;
const chunk_size = components.chunk_size;

/// Render layer tiles are pushed on. Below the physics overlay (255) and below
/// sprites, so a collider is never hidden by the tile it sits on.
pub const tile_layer: u8 = 1;
/// Atlas slot for a tile cell. 255 is the backend's white 1×1 fallback.
pub const tile_slot: u8 = 255;

/// Side of a palette cell, in points.
const cell: f32 = 26;

pub const Brush = enum {
    pencil,
    rect_fill,
    rect_outline,
    flood_fill,
    eraser,
    picker,

    pub fn name(self: Brush) [:0]const u8 {
        return switch (self) {
            .pencil => "Pencil",
            .rect_fill => "Fill",
            .rect_outline => "Outline",
            .flood_fill => "Bucket",
            .eraser => "Eraser",
            .picker => "Picker",
        };
    }

    /// One-line description for the tooltip, so the toolbar needs no legend.
    pub fn help(self: Brush) [:0]const u8 {
        return switch (self) {
            .pencil => "Paint one tile at a time",
            .rect_fill => "Drag to fill a rectangle",
            .rect_outline => "Drag to outline a rectangle",
            .flood_fill => "Fill the matching region",
            .eraser => "Clear tiles",
            .picker => "Sample the tile under the cursor",
        };
    }
};

/// The editing session's tile storage.
pub const Store = struct {
    allocator: std.mem.Allocator,
    chunks: std.ArrayListUnmanaged(TileChunk) = .empty,
    map: components.ChunkMap = .{},
    /// The number of non-empty tiles, so the status line does not have to walk
    /// the pool to answer "did anything happen".
    painted: usize = 0,

    pub fn init(allocator: std.mem.Allocator) !Store {
        return .{
            .allocator = allocator,
            .map = try components.ChunkMap.init(allocator, 64),
        };
    }

    pub fn deinit(self: *Store) void {
        self.chunks.deinit(self.allocator);
        self.map.deinit(self.allocator);
    }

    pub fn chunkCount(self: *const Store) usize {
        return self.chunks.items.len;
    }

    fn find(self: *Store, key: ChunkKey) ?*TileChunk {
        const handle = self.map.get(key) orelse return null;
        if (handle.index >= self.chunks.items.len) return null;
        const chunk = &self.chunks.items[handle.index];
        if (chunk.generation != handle.generation) return null;
        return chunk;
    }

    fn ensure(self: *Store, key: ChunkKey) !*TileChunk {
        if (self.find(key)) |chunk| return chunk;
        const index: u32 = @intCast(self.chunks.items.len);
        var chunk = TileChunk{ .key = key, .generation = @intCast(index + 1) };
        chunk.has_tiles = false;
        try self.chunks.append(self.allocator, chunk);
        self.map.put(key, .{ .index = index, .generation = chunk.generation });
        return &self.chunks.items[index];
    }

    pub fn getTile(self: *Store, tile_x: i32, tile_y: i32) Tile {
        const key = chunkOfTile(tile_x, tile_y);
        const chunk = self.find(key) orelse return .{};
        const local = ChunkCoord.fromTile(tile_x, tile_y);
        return chunk.tiles[local.index()];
    }

    /// Writes one tile. Returns true when the value actually changed, so a drag
    /// that stays on one cell is not counted as a hundred edits.
    pub fn setTile(self: *Store, tile_x: i32, tile_y: i32, tile: Tile) !bool {
        const key = chunkOfTile(tile_x, tile_y);
        const chunk = try self.ensure(key);
        const local = ChunkCoord.fromTile(tile_x, tile_y);
        const idx = local.index();
        const before = chunk.tiles[idx];
        if (before.atlas_index == tile.atlas_index and before.flags == tile.flags) return false;
        chunk.tiles[idx] = tile;
        chunk.markDirty(idx);
        chunk.has_tiles = true;
        if (tile.isEmpty()) {
            if (!before.isEmpty()) self.painted -|= 1;
        } else if (before.isEmpty()) {
            self.painted += 1;
        }
        return true;
    }

    /// Flood fill inside ONE chunk, bounded by the chunk's 16×16 cells. That is
    /// the honest limit of a first slice: a region that spans chunks needs the
    /// neighbour lookup the runtime system owns, and painting across a seam is a
    /// feature to add when it can be tested, not to guess at now.
    pub fn floodFill(self: *Store, tile_x: i32, tile_y: i32, tile: Tile) !usize {
        const target = self.getTile(tile_x, tile_y);
        if (target.atlas_index == tile.atlas_index and target.flags == tile.flags) return 0;

        const key = chunkOfTile(tile_x, tile_y);
        const start = ChunkCoord.fromTile(tile_x, tile_y);
        const base_x = @as(i32, key.cx) * @as(i32, chunk_size);
        const base_y = @as(i32, key.cy) * @as(i32, chunk_size);

        var visited = [_]bool{false} ** (@as(usize, chunk_size) * @as(usize, chunk_size));
        var queue: [256]u16 = undefined;
        var head: usize = 0;
        var tail: usize = 0;
        const start_idx: u16 = start.index();
        queue[tail] = start_idx;
        tail += 1;
        visited[start_idx] = true;
        var filled: usize = 0;

        while (head < tail) {
            const idx = queue[head];
            head += 1;
            const cx: i32 = @intCast(idx % chunk_size);
            const cy: i32 = @intCast(idx / chunk_size);
            const tx = base_x + cx;
            const ty = base_y + cy;
            const here = self.getTile(tx, ty);
            if (here.atlas_index != target.atlas_index or here.flags != target.flags) continue;
            if (try self.setTile(tx, ty, tile)) filled += 1;

            const neighbours = [_][2]i32{ .{ cx - 1, cy }, .{ cx + 1, cy }, .{ cx, cy - 1 }, .{ cx, cy + 1 } };
            for (neighbours) |n| {
                if (n[0] < 0 or n[1] < 0 or n[0] >= chunk_size or n[1] >= chunk_size) continue;
                const n_idx: u16 = @intCast(n[1] * chunk_size + n[0]);
                if (visited[n_idx]) continue;
                const nt = self.getTile(base_x + n[0], base_y + n[1]);
                if (nt.atlas_index != target.atlas_index or nt.flags != target.flags) continue;
                visited[n_idx] = true;
                queue[tail] = n_idx;
                tail += 1;
            }
        }
        return filled;
    }
};

/// The panel: brush state plus the two things a pointer is allowed to change.
pub const Panel = struct {
    store: *Store,
    brush: Brush = .pencil,
    brush_tile: Tile = .{ .atlas_index = 1 },
    flip_x: bool = false,
    flip_y: bool = false,
    tile_size: f32 = 32.0,
    /// Palette size. A real project reads this from the TileSet; until the
    /// asset is loaded it is the thing the palette draws, and it is editable.
    tile_count: u16 = 24,
    cols: u16 = 8,
    /// Layer row state. One layer for now; the array is here so adding a second
    /// is a data change.
    layer_visible: [4]bool = .{ true, true, true, true },
    layer_physics: [4]bool = .{ false, false, false, false },
    active_layer: usize = 0,
    selected_palette: ?u16 = null,

    /// Last tile the cursor was over, in tile coordinates, and the anchor of a
    /// rectangle drag. `?[2]i32` and not a `ChunkKey`: the brush works in whole
    /// tiles, and converting to chunks here would put the seam arithmetic in
    /// the wrong file.
    hover: ?[2]i32 = null,
    drag_anchor: ?[2]i32 = null,

    /// Called after a paint so the shell can mark the scene dirty.
    on_edit: ?*const fn (ctx: ?*anyopaque) void = null,
    edit_ctx: ?*anyopaque = null,

    fn tellEdited(self: *Panel) void {
        if (self.on_edit) |f| f(self.edit_ctx);
    }

    fn effectiveTile(self: *const Panel) Tile {
        var tile = self.brush_tile;
        if (self.brush == .eraser) tile.atlas_index = 0;
        tile = tile.withFlipX(self.flip_x);
        tile = tile.withFlipY(self.flip_y);
        return tile;
    }

    /// Applies the current brush at one tile. `committed` is false during a
    /// rectangle drag (the preview would otherwise stamp the whole path) and
    /// true on release.
    pub fn paintAt(self: *Panel, tile_x: i32, tile_y: i32, committed: bool) !void {
        const tile = self.effectiveTile();
        switch (self.brush) {
            .pencil, .eraser => {
                if (try self.store.setTile(tile_x, tile_y, tile)) self.tellEdited();
            },
            .picker => {
                const sampled = self.store.getTile(tile_x, tile_y);
                if (!sampled.isEmpty()) {
                    self.brush_tile = sampled;
                    self.flip_x = sampled.flipX();
                    self.flip_y = sampled.flipY();
                    self.selected_palette = sampled.atlas_index;
                }
            },
            .flood_fill => {
                if (committed and try self.store.floodFill(tile_x, tile_y, tile) > 0) self.tellEdited();
            },
            .rect_fill, .rect_outline => {
                if (!committed) return;
                const anchor = self.drag_anchor orelse .{ tile_x, tile_y };
                const x0 = @min(anchor[0], tile_x);
                const x1 = @max(anchor[0], tile_x);
                const y0 = @min(anchor[1], tile_y);
                const y1 = @max(anchor[1], tile_y);
                var changed = false;
                var y = y0;
                while (y <= y1) : (y += 1) {
                    var x = x0;
                    while (x <= x1) : (x += 1) {
                        const on_edge = x == x0 or x == x1 or y == y0 or y == y1;
                        if (self.brush == .rect_outline and !on_edge) continue;
                        if (try self.store.setTile(x, y, tile)) changed = true;
                    }
                }
                if (changed) self.tellEdited();
            },
        }
    }

    /// Draws the panel as its own floating window. Kept for a standalone run;
    /// the editor shell calls `drawContents` inside the window IT owns, so the
    /// panel is a dock like every other one.
    pub fn draw(self: *Panel) void {
        current = self;
        defer current = null;
        ui.floating(host_ctx.?, "TileMap", .{ .x = 16, .y = 16, .w = 268, .h = 440 }, drawBody);
    }

    /// The panel's body, drawn into the CURRENT window. `ctx` is also stashed in
    /// `host_ctx` because the widgets below take it directly (the body itself is
    /// a plain function pointer and cannot reach it any other way).
    pub fn drawContents(self: *Panel, ctx: *ui.Context) void {
        host_ctx = ctx;
        current = self;
        defer current = null;
        drawBody(ctx);
    }

    /// The shell sets this before `draw`; it is the context the window opens on.
    pub var host_ctx: ?*ui.Context = null;
    var current: ?*Panel = null;
    /// How many times the window body has drawn. The shell reports it so a
    /// headless smoke test can tell "the panel is in the frame" from "the
    /// panel compiled and was never called".
    pub var draws: usize = 0;

    fn drawBody(ctx: *ui.Context) void {
        _ = ctx;
        draws += 1;
        const self = current orelse return;
        self.drawToolbar();
        self.drawPalette();
        self.drawLayers();
        self.drawStatus();
    }

    fn drawToolbar(self: *Panel) void {
        // One button per brush, wrapping through the theme. Grouped in rows of
        // two so six brushes do not force the window wide.
        var first = true;
        for (std.enums.values(Brush)) |brush| {
            if (!first) c.ember_ui_same_line(0, 4);
            first = false;
            if (ui.button.render(.{
                .ctx = host_ctx.?,
                .id = brush.name(),
                .text = brush.name(),
                .variant = if (self.brush == brush) .primary else .ghost,
                .tooltip = brush.help(),
            })) {
                self.brush = brush;
            }
        }

        c.ember_ui_separator();
        var flip_x = self.flip_x;
        if (ui.toggle.checkbox(.{ .ctx = host_ctx.?, .id = "tile.flipx", .label = "Flip X", .value = &flip_x })) {
            self.flip_x = flip_x;
        }
        c.ember_ui_same_line(0, 8);
        var flip_y = self.flip_y;
        if (ui.toggle.checkbox(.{ .ctx = host_ctx.?, .id = "tile.flipy", .label = "Flip Y", .value = &flip_y })) {
            self.flip_y = flip_y;
        }
    }

    fn drawPalette(self: *Panel) void {
        ui.text.subtitle(host_ctx.?, "Palette");
        const list = ui.draw.windowList();
        const cols: usize = self.cols;
        var idx: u16 = 0;
        while (idx < self.tile_count) : (idx += 1) {
            const col = idx % self.cols;
            if (col != 0) c.ember_ui_same_line(0, 2);

            var id_buf: [32]u8 = undefined;
            const id = std.fmt.bufPrintZ(&id_buf, "tile##{d}", .{idx}) catch "tile";
            _ = c.ember_ui_invisible_button(id.ptr, cell, cell, 0);

            var min_xy: [2]f32 = undefined;
            var max_xy: [2]f32 = undefined;
            c.ember_ui_get_item_rect_min(&min_xy);
            c.ember_ui_get_item_rect_max(&max_xy);
            const rect = c.Rect{
                .min = .{ .x = min_xy[0], .y = min_xy[1] },
                .max = .{ .x = max_xy[0], .y = max_xy[1] },
            };

            const selected = self.selected_palette != null and self.selected_palette.? == idx;
            list.rect(rect, tileColor(idx + 1), 3);
            if (selected) list.rectOutline(rect, ui.Rgba.hex(0xFFFFFF, 1), 3, 2);
            if (c.ember_ui_is_item_clicked(0) != 0) {
                self.selected_palette = idx;
                self.brush_tile = Tile{ .atlas_index = idx + 1 };
            }
            if (c.ember_ui_is_item_hovered(0) != 0) {
                c.ember_ui_set_tooltip(c.text("left-click to select"));
            }
            _ = cols;
        }
    }

    fn drawLayers(self: *Panel) void {
        _ = c.ember_ui_separator();
        ui.text.subtitle(host_ctx.?, "Layers");
        var i: usize = 0;
        while (i < self.layer_visible.len) : (i += 1) {
            var label_buf: [24]u8 = undefined;
            var vis_buf: [32]u8 = undefined;
            const label = std.fmt.bufPrintZ(&label_buf, "Layer {d}", .{i}) catch "Layer";
            const vis_id = std.fmt.bufPrintZ(&vis_buf, "vis{d}", .{i}) catch "vis";
            var visible = self.layer_visible[i];
            if (ui.toggle.checkbox(.{ .ctx = host_ctx.?, .id = vis_id, .label = label, .value = &visible })) {
                self.layer_visible[i] = visible;
            }
            var phys_buf: [32]u8 = undefined;
            const phys_id = std.fmt.bufPrintZ(&phys_buf, "phys{d}", .{i}) catch "phys";
            var physics = self.layer_physics[i];
            if (ui.toggle.checkbox(.{ .ctx = host_ctx.?, .id = phys_id, .label = "collides", .value = &physics })) {
                self.layer_physics[i] = physics;
            }
        }
    }

    fn drawStatus(self: *Panel) void {
        _ = c.ember_ui_separator();
        var buf: [96]u8 = undefined;
        if (self.hover) |h| {
            const msg = std.fmt.bufPrintZ(&buf, "Tile {d},{d}  |  {d} painted", .{ h[0], h[1], self.store.painted }) catch "?";
            _ = c.ember_ui_text(msg.ptr);
        } else {
            const msg = std.fmt.bufPrintZ(&buf, "{d} painted  |  {d} chunks", .{ self.store.painted, self.store.chunkCount() }) catch "?";
            _ = c.ember_ui_text(msg.ptr);
        }
    }

    /// Hands every painted tile to the 2D batcher. Called inside the frame, so
    /// it allocates nothing: it walks the pool and pushes instances.
    pub fn pushTiles(self: *Panel, r2d: anytype) usize {
        const half = self.tile_size * 0.5;
        var pushed: usize = 0;
        for (self.store.chunks.items) |chunk| {
            if (!chunk.has_tiles) continue;
            const base_x = @as(f32, @floatFromInt(@as(i32, chunk.key.cx) * @as(i32, chunk_size)));
            const base_y = @as(f32, @floatFromInt(@as(i32, chunk.key.cy) * @as(i32, chunk_size)));
            for (chunk.tiles, 0..) |tile, i| {
                if (tile.isEmpty()) continue;
                const cx: f32 = @floatFromInt(i % chunk_size);
                const cy: f32 = @floatFromInt(i / chunk_size);
                const origin = (base_x + cx) * self.tile_size;
                const origin_y = (base_y + cy) * self.tile_size;
                _ = r2d.pushInstance(.{
                    .pos = .{ origin + half, origin_y + half },
                    .half = .{ half, half },
                    .uv = .{ 0, 0, std.math.maxInt(u16), std.math.maxInt(u16) },
                    .color = rgbaToU8(tileColor(tile.atlas_index)),
                    .slot = tile_slot,
                    .shape = 0,
                    .layer = tile_layer,
                });
                pushed += 1;
            }
        }
        return pushed;
    }
};

/// Chunk containing a tile coordinate. Integer math on purpose: a tile index
/// divided by the chunk size is exact, and routing it through `fromWorld`'s
/// float path would introduce a rounding question that has no business here.
fn chunkOfTile(tile_x: i32, tile_y: i32) ChunkKey {
    return .{
        .cx = @divFloor(tile_x, @as(i32, chunk_size)),
        .cy = @divFloor(tile_y, @as(i32, chunk_size)),
    };
}

/// A stable colour per atlas index, so two tiles are distinguishable without an
/// atlas loaded. Hash the index into the hue wheel; keep saturation/lightness
/// fixed so no cell is unreadable.
fn tileColor(atlas_index: u16) ui.Rgba {
    if (atlas_index == 0) return ui.Rgba.hex(0x303030, 1);
    const h: f32 = @as(f32, @floatFromInt((atlas_index *% 47) % 360)) / 360.0;
    return hsv(h, 0.55, 0.85);
}

/// `Rgba` to the instance's unorm8 tint. Clamped rather than truncated so a
/// hand-written 1.2 does not wrap to a dark colour.
fn rgbaToU8(col: ui.Rgba) [4]u8 {
    const conv = struct {
        fn f(v: f32) u8 {
            return @intFromFloat(@round(std.math.clamp(v, 0, 1) * 255.0));
        }
    }.f;
    return .{ conv(col.r), conv(col.g), conv(col.b), conv(col.a) };
}

fn hsv(h: f32, s: f32, v: f32) ui.Rgba {
    const i = @floor(h * 6.0);
    const f = h * 6.0 - i;
    const p = v * (1.0 - s);
    const q = v * (1.0 - f * s);
    const t = v * (1.0 - (1.0 - f) * s);
    const sector: u32 = @intFromFloat(@mod(i, 6.0));
    return switch (sector) {
        0 => .{ .r = v, .g = t, .b = p },
        1 => .{ .r = q, .g = v, .b = p },
        2 => .{ .r = p, .g = v, .b = t },
        3 => .{ .r = p, .g = q, .b = v },
        4 => .{ .r = t, .g = p, .b = v },
        else => .{ .r = v, .g = p, .b = q },
    };
}

test "store: a tile round-trips and the painted count tracks emptiness" {
    var store = try Store.init(std.testing.allocator);
    defer store.deinit();

    try std.testing.expectEqual(@as(usize, 0), store.painted);
    try std.testing.expect(store.getTile(3, 5).isEmpty());

    _ = try store.setTile(3, 5, .{ .atlas_index = 7 });
    try std.testing.expectEqual(@as(u16, 7), store.getTile(3, 5).atlas_index);
    try std.testing.expectEqual(@as(usize, 1), store.painted);
    try std.testing.expectEqual(@as(usize, 1), store.chunkCount());

    // Writing the same value is not an edit.
    try std.testing.expect(!try store.setTile(3, 5, .{ .atlas_index = 7 }));

    // Erasing brings the count back down.
    _ = try store.setTile(3, 5, .{});
    try std.testing.expectEqual(@as(usize, 0), store.painted);
    try std.testing.expect(store.getTile(3, 5).isEmpty());
}

test "store: flood fill stops at the region boundary" {
    var store = try Store.init(std.testing.allocator);
    defer store.deinit();

    // A 3x1 run of tile 2, with tile 9 as the wall.
    _ = try store.setTile(0, 0, .{ .atlas_index = 2 });
    _ = try store.setTile(1, 0, .{ .atlas_index = 2 });
    _ = try store.setTile(2, 0, .{ .atlas_index = 2 });
    _ = try store.setTile(3, 0, .{ .atlas_index = 9 });

    const filled = try store.floodFill(0, 0, .{ .atlas_index = 4 });
    try std.testing.expectEqual(@as(usize, 3), filled);
    try std.testing.expectEqual(@as(u16, 4), store.getTile(2, 0).atlas_index);
    // The wall and the far side are untouched.
    try std.testing.expectEqual(@as(u16, 9), store.getTile(3, 0).atlas_index);
    try std.testing.expect(store.getTile(4, 0).isEmpty());
}

test "brush: the eraser erases whatever the brush tile was" {
    var store = try Store.init(std.testing.allocator);
    defer store.deinit();
    var panel = Panel{ .store = &store, .brush_tile = .{ .atlas_index = 5 } };
    panel.brush = .eraser;
    try panel.paintAt(1, 1, true);
    // The eraser writes an empty tile, so nothing is left behind.
    try std.testing.expect(store.getTile(1, 1).isEmpty());
    try std.testing.expectEqual(@as(usize, 0), store.painted);
}
