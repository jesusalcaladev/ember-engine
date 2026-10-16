//! TileMap Editor Widget — the 2D scene editor's tile painting workspace.
//!
//! Provides the 2D tile editing UI: tile palette, brush tools, layer management,
//! physics toggle, and integration with TileMapPhysicsSystem for collision editing.

const std = @import("std");
const ecs = @import("ecs");
const components = ecs.components;
const TileMapLayer = components.TileMapLayer;
const TileChunk = components.TileChunk;
const ChunkKey = components.ChunkKey;
const ChunkHandle = components.ChunkHandle;
const Tile = components.Tile;
const Transform = components.Transform;
const assets = @import("assets");
const AssetGUID = components.AssetGUID;
const TileSet = components.TileSet;
// TilePhysics is part of the parked M15 physics surface and is not used by the
// UI yet; import it from `components` when the per-tile shapes land.
// M15 PARKED: the TileMap physics system is not wired into this module yet
// (the real one lives in physics/tilemap.zig and is re-enabled with the rest of
// M15). This local stub keeps the editor's surface compiling — the editor only
// holds a `*TileMapPhysicsSystem` and forwards get/set — and mirrors the two
// signatures the UI actually calls, so swapping the real system in is a
// one-line change to the import.
const TileMapPhysicsSystem = struct {
    pub fn setTile(_: *TileMapPhysicsSystem, _: AssetGUID, _: i32, _: i32, _: Tile) ?usize {
        return null;
    }
    pub fn getTile(_: *TileMapPhysicsSystem, _: AssetGUID, _: i32, _: i32) ?Tile {
        return null;
    }
};

/// Brush tool modes for tile editing.
pub const BrushMode = enum {
    /// Single tile placement (pencil)
    pencil,
    /// Rectangle fill
    rect_fill,
    /// Rectangle outline
    rect_outline,
    /// Flood fill (bucket)
    flood_fill,
    /// Eraser (sets tile to empty)
    eraser,
    /// Picker (sample tile under cursor)
    picker,

    pub fn name(self: BrushMode) []const u8 {
        return switch (self) {
            .pencil => "Pencil",
            .rect_fill => "Rect Fill",
            .rect_outline => "Rect Outline",
            .flood_fill => "Flood Fill",
            .eraser => "Eraser",
            .picker => "Picker",
        };
    }
};

/// TileMap editor state — all the UI state for the tilemap workspace.
pub const TileMapEditor = struct {
    allocator: std.mem.Allocator,

    // Current brush state
    brush_mode: BrushMode = .pencil,
    brush_tile: Tile = .{ .atlas_index = 1 },
    brush_flip_x: bool = false,
    brush_flip_y: bool = false,

    // TileSet selection
    tileset_guid: AssetGUID = .{ .value = 0 },
    tileset_ptr: ?*const TileSet = null,
    tileset_tile_size: f32 = 32.0,
    tileset_atlas_w: u16 = 16,
    tileset_atlas_h: u16 = 16,

    // Layer management
    active_layer: usize = 0,
    layer_visibility: []bool = &.{},
    layer_physics: []bool = &.{},

    // Tile palette state
    palette_scroll: f32 = 0.0,
    palette_cols: u16 = 16,
    selected_palette_idx: ?u16 = null,

    // Viewport interaction
    viewport_hover: bool = false,
    viewport_pos: ecs.components.Vec2 = .{},
    viewport_hover_tile: ?ChunkKey = null,
    viewport_hover_local: ?components.ChunkCoord = null,
    drag_start: ?ChunkKey = null,
    drag_start_local: ?components.ChunkCoord = null,

    // TileMap system references
    physics_sys: ?*TileMapPhysicsSystem = null,
    tilemap_renderer: ?*render.TileMapRenderer = null,

    // Undo/redo integration
    session_model: ?*session.Model = null,

    pub fn init(allocator: std.mem.Allocator) !TileMapEditor {
        return .{
            .allocator = allocator,
            .layer_visibility = try allocator.alloc(bool, 16),
            .layer_physics = try allocator.alloc(bool, 16),
        };
    }

    pub fn deinit(self: *TileMapEditor) void {
        self.allocator.free(self.layer_visibility);
        self.allocator.free(self.layer_physics);
        self.* = undefined;
    }

    /// Set the TileMapPhysicsSystem reference (called after physics init)
    pub fn setPhysicsSystem(self: *TileMapEditor, sys: *TileMapPhysicsSystem) void {
        self.physics_sys = sys;
    }

    /// Set the TileMapRenderer reference
    pub fn setTileMapRenderer(self: *TileMapEditor, r: *render.TileMapRenderer) void {
        self.tilemap_renderer = r;
    }

    /// Set the session model for undo/redo
    pub fn setSessionModel(self: *TileMapEditor, model: *session.Model) void {
        self.session_model = model;
    }

    /// Set the active TileSet
    pub fn setTileset(self: *TileMapEditor, guid: AssetGUID, tilesets: *const assets.AssetRegistry) bool {
        const entry_opt = tilesets.registry.get(guid) orelse return false;
        const entry = entry_opt.?;
        const ts_ptr: usize = @intCast(entry.handle);
        if (ts_ptr == 0) return false;
        const tileset: *const TileSet = @ptrCast(@alignCast(ts_ptr));

        self.tileset_guid = guid;
        self.tileset_ptr = tileset;
        self.tileset_tile_size = tileset.tile_size;
        self.tileset_atlas_w = tileset_atlas_w(tileset);
        self.tileset_atlas_h = tileset_atlas_h(tileset);
        self.selected_palette_idx = 1; // first non-empty tile
        return true;
    }

    /// Ensure layers arrays can hold at least `count` layers
    fn ensureLayerCapacity(self: *TileMapEditor, count: usize) !void {
        if (self.layer_visibility.len < count) {
            self.layer_visibility = try self.allocator.resize(self.layer_visibility, count);
            self.layer_physics = try self.allocator.resize(self.layer_physics, count);
            // Default new layers to visible, no physics
            for (self.layer_visibility[self.active_layer..]) |*v| v = true;
            for (self.layer_physics[self.active_layer..]) |*v| v = false;
        }
    }

    /// Get the active layer's TileMapLayer component (creates if needed)
    fn getActiveLayer(self: *TileMapEditor, world: *ecs.World, entity: ecs.Entity) ?*TileMapLayer {
        if (world.get(entity, TileMapLayer)) |layer| {
            return layer;
        }
        // Add TileMapLayer component if missing
        try world.add(entity, TileMapLayer{
            .tileset_guid = self.tileset_guid,
            .layer = @intCast(self.active_layer),
        }) catch return null;
        return world.get(entity, TileMapLayer);
    }

    // ─── UI Rendering ────────────────────────────────────────────────────────

    /// Render the TileMap editor toolbar (brush modes, tile picker, layer list)
    pub fn toolbar(self: *TileMapEditor, ui: *imgui.ImGui, world: *ecs.World, selected: ecs.Entity) void {
        ui.beginToolbar("TileMap Toolbar");
        defer ui.endToolbar();

        // Brush mode selector
        ui.text("Brush:");
        ui.sameLine();
        if (ui.beginCombo("##brush_mode", self.brush_mode.name())) {
            for (BrushMode) |mode| {
                if (ui.selectable(mode.name(), self.brush_mode == mode)) {
                    self.brush_mode = mode;
                }
            }
            ui.endCombo();
        }

        ui.sameLine();
        ui.separator();
        ui.sameLine();

        // TileSet selector
        if (self.tileset_ptr != null) {
            var buf: [32]u8 = undefined;
            const guid_str = self.tileset_guid.toString(&buf);
            ui.text("TileSet: " ++ guid_str);
        } else {
            ui.textColored(.{ 1, 0.3, 0.3, 1 }, "No TileSet");
        }
        ui.sameLine();
        if (ui.button("Pick TileSet")) {
            // TODO: Open TileSet picker dialog
        }

        ui.sameLine();
        ui.separator();
        ui.sameLine();

        // Brush tile preview
        ui.text("Brush:");
        ui.sameLine();
        if (self.brush_tile.atlas_index > 0) {
            // Show tile preview (would use atlas UV)
            var tile_buf: [16]u8 = undefined;
            ui.text(std.fmt.bufPrint(&tile_buf, "Tile #{d}", .{self.brush_tile.atlas_index}) catch "Tile #?");
        } else {
            ui.textColored(.{ 0.5, 0.5, 0.5, 1 }, "(empty)");
        }
        ui.sameLine();
        ui.checkbox("Flip X", &self.brush_flip_x);
        ui.sameLine();
        ui.checkbox("Flip Y", &self.brush_flip_y);

        ui.sameLine();
        ui.separator();
        ui.sameLine();

        // Tile size override
        var tile_size = self.tileset_tile_size;
        if (ui.dragFloat("Tile Size", &tile_size, 0.5, 1.0, 512.0, "%.0f")) {
            // Apply to active layer
            if (world.get(selected, TileMapLayer)) |layer| {
                layer.tile_size_override = tile_size;
            }
        }
        ui.sameLine();
        ui.checkbox("Flip X", &self.brush_flip_x);
        ui.sameLine();
        ui.checkbox("Flip Y", &self.brush_flip_y);
    }

    /// Render the tile palette (grid of tiles from current TileSet)
    pub fn palette(self: *TileMapEditor, ui: *imgui.ImGui) void {
        ui.beginChild("Tile Palette", .{ .x = 0, .y = 200 }, true);
        defer ui.endChild();

        if (self.tileset_ptr == null) {
            ui.text("No TileSet selected");
            return;
        }

        const ts = self.tileset_ptr.?;
        const tile_count = ts.tile_count;
        const cols = self.palette_cols;
        const rows = (tile_count + cols - 1) / cols;

        // Scrollable palette
        ui.pushStyleVar(imgui.StyleVar.ItemSpacing, .{ .x = 2, .y = 2 });
        defer ui.popStyleVar();

        var idx: u16 = 0;
        var row: u16 = 0;
        while (row < rows) : (row += 1) {
            var col: u16 = 0;
            while (col < cols and idx < tile_count) : (col += 1) {
                idx += 1;

                const tile_idx = idx;
                const selected = self.selected_palette_idx == tile_idx;

                // Tile button (would show actual tile texture)
                ui.pushID(idx);
                if (ui.selectable("", selected, imgui.SelectableFlags.None, .{ .x = 32, .y = 32 })) {
                    self.selected_palette_idx = tile_idx;
                    self.brush_tile.atlas_index = tile_idx;
                }
                ui.popID();

                if (col < cols - 1 and idx < tile_count) ui.sameLine();
            }
        }

        // Handle scroll
        self.palette_scroll = ui.getScrollY();
    }

    /// Layer list panel
    pub fn layers(self: *TileMapEditor, ui: *imgui.ImGui, world: *ecs.World, selected: ecs.Entity) void {
        _ = selected;
        ui.beginChild("Layers", .{ .x = 0, .y = 300 }, true);
        defer ui.endChild();

        // Layer list
        if (self.layer_visibility.len > 0) {
            var i: usize = 0;
            while (i < self.layer_visibility.len) : (i += 1) {
                ui.pushID(i);

                // Visibility toggle
                var vis = self.layer_visibility[i];
                if (ui.checkbox("##vis", &vis)) {
                    self.layer_visibility[i] = vis;
                    // Apply to layer component
                    // TODO: update layer component
                }
                ui.sameLine();

                // Physics toggle
                var phys = self.layer_physics[i];
                if (ui.checkbox("##phys", &phys)) {
                    self.layer_physics[i] = phys;
                    // Apply physics toggle
                    if (world.get(self.getActiveEntity(world), TileMapLayer)) |layer| {
                        layer.physics_enabled = phys;
                    }
                }
                ui.sameLine();

                // Layer name
                var name_buf: [32]u8 = undefined;
                const name = std.fmt.bufPrint(&name_buf, "Layer {d}", .{i}) catch "Layer ?";
                if (ui.selectable(name, self.active_layer == i)) {
                    self.active_layer = i;
                }

                // Context menu for layer ops
                if (ui.beginPopupContextItem("layer_ctx")) {
                    if (ui.menuItem("Add Layer Above")) {
                        _ = self.addLayerAbove(i);
                    }
                    if (ui.menuItem("Add Layer Below")) {
                        _ = self.addLayerBelow(i);
                    }
                    if (ui.menuItem("Duplicate Layer")) {
                        _ = self.duplicateLayer(i);
                    }
                    if (ui.menuItem("Delete Layer")) {
                        _ = self.deleteLayer(i);
                    }
                    ui.endPopup();
                }

                ui.popID();
            }
        }

        ui.separator();
        if (ui.button("Add Layer")) {
            _ = self.addLayer();
        }
        ui.sameLine();
        if (ui.button("Delete Active")) {
            _ = self.deleteActiveLayer();
        }
    }

    fn addLayerAbove(self: *TileMapEditor, at: usize) !void {
        try self.ensureLayerCapacity(self.layer_visibility.len + 1);
        // Shift layers up
        self.layer_visibility = try self.allocator.resize(self.layer_visibility, self.layer_visibility.len + 1);
        self.layer_physics = try self.allocator.resize(self.layer_physics, self.layer_physics.len + 1);
        // Shift up from insertion point
        var i = self.layer_visibility.len - 1;
        while (i > at) : (i -= 1) {
            self.layer_visibility[i] = self.layer_visibility[i - 1];
            self.layer_physics[i] = self.layer_physics[i - 1];
        }
        self.layer_visibility[at + 1] = true;
        self.layer_physics[at + 1] = false;
    }

    fn addLayerBelow(self: *TileMapEditor, at: usize) !void {
        try self.ensureLayerCapacity(self.layer_visibility.len + 1);
        self.layer_visibility = try self.allocator.resize(self.layer_visibility, self.layer_visibility.len + 1);
        self.layer_physics = try self.allocator.resize(self.layer_physics, self.layer_physics.len + 1);
        // Shift up from insertion point
        var i = self.layer_visibility.len - 1;
        while (i > at + 1) : (i -= 1) {
            self.layer_visibility[i] = self.layer_visibility[i - 1];
            self.layer_physics[i] = self.layer_physics[i - 1];
        }
        self.layer_visibility[at + 1] = true;
        self.layer_physics[at + 1] = false;
    }

    fn addLayer(self: *TileMapEditor) !void {
        try self.ensureLayerCapacity(self.layer_visibility.len + 1);
        self.layer_visibility = try self.allocator.resize(self.layer_visibility, self.layer_visibility.len + 1);
        self.layer_physics = try self.allocator.resize(self.layer_physics, self.layer_physics.len + 1);
        self.layer_visibility[self.layer_visibility.len - 1] = true;
        self.layer_physics[self.layer_physics.len - 1] = false;
        self.active_layer = self.layer_visibility.len - 1;
    }

    fn duplicateLayer(self: *TileMapEditor, at: usize) !void {
        // TODO: duplicate layer data
        _ = self;
        _ = at;
    }

    fn deleteLayer(self: *TileMapEditor, at: usize) !void {
        if (self.layer_visibility.len <= 1) return; // keep at least 1
        self.layer_visibility = self.layer_visibility[0..at] ++ self.layer_visibility[at + 1..];
        self.layer_physics = self.layer_physics[0..at] ++ self.layer_physics[at + 1..];
        if (self.active_layer >= self.layer_visibility.len) {
            self.active_layer = self.layer_visibility.len - 1;
        }
    }

    fn deleteActiveLayer(self: *TileMapEditor) !void {
        if (self.layer_visibility.len <= 1) return;
        self.deleteLayer(self.active_layer);
    }

    /// Viewport interaction: handle mouse input for tile painting
    pub fn viewport(self: *TileMapEditor, ui: *imgui.ImGui, world: *ecs.World, selected: ecs.Entity, camera: render.Camera, alpha: f32) void {
        _ = selected;
        _ = alpha;
        if (!ui.isWindowHovered() or !ui.isMouseHoveringRect()) {
            self.viewport_hover = false;
            return;
        }
        self.viewport_hover = true;

        // Get viewport mouse position in world coords
        const mouse = ui.getMousePos();
        const canvas_pos = ui.getCanvasPos();
        const mouse_world = self.screenToWorld(mouse, canvas_pos, camera);

        // Convert to tile coordinates
        const tile_size = self.tileset_tile_size;
        const tile_x = @floor(mouse_world.x / tile_size);
        const tile_y = @floor(mouse_world.y / tile_size);

        // Convert to chunk/local coords
        const chunk_key = ChunkKey.fromWorld(mouse_world.x, mouse_world.y, tile_size);
        const local = components.ChunkCoord.fromTile(tile_x, tile_y);

        self.viewport_pos = .{ .x = tile_x, .y = tile_y };
        self.viewport_hover_tile = chunk_key;
        self.viewport_hover_local = local;

        // Handle input
        if (ui.isMouseDown(imgui.MouseButton.Left)) {
            if (!self.drag_start) {
                self.drag_start = chunk_key;
                self.drag_start_local = local;
            }
            self.paintTile(world, chunk_key, local);
        } else {
            self.drag_start = null;
            self.drag_start_local = null;
        }

        if (ui.isMouseReleased(imgui.MouseButton.Left)) {
            self.drag_start = null;
            self.drag_start_local = null;
        }

        // Right click - picker
        if (ui.isMouseClicked(imgui.MouseButton.Right)) {
            self.pickTileAt(chunk_key, local);
        }

        // Show hover info
        var tile_buf: [48]u8 = undefined;
        ui.text(std.fmt.bufPrint(&tile_buf, "Tile: {d}, {d}", .{ tile_x, tile_y }) catch "Tile: ?");
        var chunk_buf: [48]u8 = undefined;
        ui.text(std.fmt.bufPrint(&chunk_buf, "Chunk: {d}, {d}", .{ chunk_key.cx, chunk_key.cy }) catch "Chunk: ?");
    }

    fn paintTile(self: *TileMapEditor, world: *ecs.World, chunk_key: ChunkKey, local: components.ChunkCoord) void {
        _ = chunk_key;
        const entity = self.getActiveEntity(world) orelse return;
        _ = entity;
        const phys_sys = self.physics_sys orelse return;

        var tile = self.brush_tile;
        if (self.brush_mode == .eraser) {
            tile.atlas_index = 0;
        }
        if (self.brush_flip_x) tile.flags |= Tile.FlagFlipX;
        if (self.brush_flip_y) tile.flags |= Tile.FlagFlipY;

        switch (self.brush_mode) {
            .pencil => {
                _ = phys_sys.setTile(self.tileset_guid, @intCast(local.x), @intCast(local.y), tile);
            },
            .rect_fill => {
                if (self.drag_start) |start| {
                    self.fillRectBetween(start, self.drag_start_local.?, local, self.brush_mode == .rect_fill);
                }
            },
            .flood_fill => {
                // TODO: flood fill implementation
            },
            .picker => {
                // Handled on right-click
            },
            .eraser => {
                _ = phys_sys.setTile(self.tileset_guid, @intCast(local.x), @intCast(local.y), .{ .atlas_index = 0 });
            },
        }
    }

    fn fillRectBetween(self: *TileMapEditor, start: ChunkKey, start_local: components.ChunkCoord, end_local: components.ChunkCoord, fill: bool) void {
        // TODO: implement rectangle fill
        _ = self;
        _ = start;
        _ = start_local;
        _ = end_local;
        _ = fill;
    }

    fn pickTileAt(self: *TileMapEditor, chunk_key: ChunkKey, local: components.ChunkCoord) void {
        // Sample tile under cursor and set as brush
        _ = self;
        _ = chunk_key;
        _ = local;
    }

    fn getActiveEntity(self: *TileMapEditor, world: *ecs.World) ?ecs.Entity {
        // Return the selected entity that has a TileMapLayer
        const model = self.session_model orelse return null;
        const selection = model.selected();
        for (selection) |e| {
            if (world.get(e, TileMapLayer)) |_| return e;
        }
        return null;
    }

    fn screenToWorld(self: *TileMapEditor, screen: imgui.Vec2, canvas: imgui.Vec2, camera: render.Camera) ecs.components.Vec2 {
        // Convert screen coords to world coords using camera
        // This is a simplified version
        _ = self;
        _ = screen;
        _ = canvas;
        _ = camera;
        return .{ .x = 0, .y = 0 };
    }

    /// Apply layer changes to the TileMapLayer component
    pub fn applyLayerState(self: *TileMapEditor, world: *ecs.World, entity: ecs.Entity) void {
        if (world.get(entity, TileMapLayer)) |layer| {
            layer.layer = @intCast(self.active_layer);
            layer.physics_enabled = self.layer_physics[self.active_layer];
            // Visibility would be handled by renderer
        }
    }

    /// Get the tile at world coordinates (for inspector)
    pub fn getTileAt(self: *TileMapEditor, world: *ecs.World, tile_x: i32, tile_y: i32) ?Tile {
        _ = world;
        const phys_sys = self.physics_sys orelse return null;
        return phys_sys.getTile(self.tileset_guid, tile_x, tile_y);
    }
};

// ─── Helpers ────────────────────────────────────────────────────────────────

fn tileset_atlas_w(tileset: *const TileSet) u16 {
    // Approximate: assume square atlas for now
    _ = tileset;
    return 16;
}

fn tileset_atlas_h(tileset: *const TileSet) u16 {
    _ = tileset;
    return 16;
}

// ─── ImGui bindings placeholder ────────────────────────────────────────────
//
// Headless stubs so the editor module compiles and tests without linking the
// real ImGui. Every method returns a benign default; `ImGui` is the surface
// the panel code drives, and the REAL implementation arrives with the UI
// milestone. These are deliberately inert: a test that asserts on their return
// values would be asserting on a stub, not on behaviour.

const imgui = struct {
    pub const Vec2 = struct { x: f32 = 0, y: f32 = 0 };
    pub const SelectableFlags = enum(c_int) { None = 0 };
    pub const StyleVar = c_int;
    pub const MouseButton = enum(c_int) { Left = 0, Right = 1, Middle = 2 };

    pub const ImGui = struct {
        pub fn beginToolbar(_: []const u8) void {}
        pub fn endToolbar() void {}
        pub fn text(_: []const u8) void {}
        pub fn textColored(_: [4]f32, _: []const u8) void {}
        pub fn sameLine() void {}
        pub fn separator() void {}
        pub fn button(_: []const u8) bool {
            return false;
        }
        pub fn checkbox(_: []const u8, _: *bool) bool {
            return false;
        }
        pub fn beginCombo(_: []const u8, _: []const u8) bool {
            return false;
        }
        pub fn endCombo() void {}
        pub fn selectable(_: []const u8, _: bool) bool {
            return false;
        }
        pub fn selectableEx(_: []const u8, _: bool, _: SelectableFlags, _: Vec2) bool {
            return false;
        }
        pub fn beginChild(_: []const u8, _: Vec2, _: bool) void {}
        pub fn endChild() void {}
        pub fn beginPopupContextItem(_: []const u8) bool {
            return false;
        }
        pub fn endPopup() void {}
        pub fn menuItem(_: []const u8) bool {
            return false;
        }
        pub fn dragFloat(_: []const u8, _: *f32, _: f32, _: f32, _: f32, _: []const u8) bool {
            return false;
        }
        pub fn pushID(_: u16) void {}
        pub fn popID() void {}
        pub fn pushStyleVar(_: StyleVar, _: Vec2) void {}
        pub fn popStyleVar() void {}
        pub fn getScrollY() f32 {
            return 0;
        }
        pub fn isWindowHovered() bool {
            return false;
        }
        pub fn isMouseHoveringRect() bool {
            return false;
        }
        pub fn getMousePos() Vec2 {
            return .{};
        }
        pub fn getCanvasPos() Vec2 {
            return .{};
        }
        pub fn isMouseDown(_: MouseButton) bool {
            return false;
        }
        pub fn isMouseReleased(_: MouseButton) bool {
            return false;
        }
        pub fn isMouseClicked(_: MouseButton) bool {
            return false;
        }
    };
};

// ─── Session module placeholder ────────────────────────────────────────────

const session = struct {
    pub const Model = struct {
        pub fn selected(_: *const Model) []const ecs.Entity {
            return &.{};
        }
    };
};

// ─── Render module placeholder ─────────────────────────────────────────────

const render = struct {
    pub const TileMapRenderer = struct {};
    pub const Camera = struct {};
};

// ─── Tests ──────────────────────────────────────────────────────────────────

const testing = std.testing;

test "TileMapEditor initializes" {
    var editor = try TileMapEditor.init(testing.allocator);
    defer editor.deinit();
    // The allocator is stored by value and has no `==`, so compare the
    // identity that actually matters: the context pointer it hands out.
    try testing.expect(editor.allocator.ptr == testing.allocator.ptr);
    try testing.expectEqual(@as(usize, 16), editor.layer_visibility.len);
}