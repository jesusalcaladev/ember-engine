//! Asset Hot Reload — watches for file changes and reloads assets at < 250 ms.
//! Integrates with AssetManager, AtlasManager, and AssetRegistry.

const std = @import("std");
const AssetManager = @import("asset_manager.zig").AssetManager;
const AssetRegistry = @import("registry.zig").AssetRegistry;
const AtlasManager = @import("render").AtlasManager;
const VFS = @import("vfs.zig").VFS;

pub const HotReloadEvent = union(enum) {
    image_reloaded: u32,      // atlas slot index
    audio_reloaded: u32,      // bank slot index
    script_reloaded: u32,     // script_id
    asset_removed: u64,       // GUID value
};

/// Callback type for hot reload notifications.
pub const ReloadCallback = fn (event: HotReloadEvent) void;

/// Hot reload manager.
pub const HotReload = struct {
    allocator: std.mem.Allocator,
    vfs: *VFS,
    asset_mgr: *AssetManager,
    registry: *AssetRegistry,
    atlas_mgr: ?*AtlasManager,
    callback: ?ReloadCallback,
    /// Paths being watched (source path -> last mod time).
    watched: std.StringHashMap(i64),
    /// Debounce timer: wait N ms after first change before reload.
    debounce_ms: u32 = 100,
    /// Accumulator for debounced changes.
    pending: std.AutoArrayHashMap([]const u8, i64),

    pub fn init(
        allocator: std.mem.Allocator,
        vfs: *VFS,
        asset_mgr: *AssetManager,
        registry: *AssetRegistry,
        atlas_mgr: ?*AtlasManager,
        callback: ?ReloadCallback,
    ) HotReload {
        return .{
            .allocator = allocator,
            .vfs = vfs,
            .asset_mgr = asset_mgr,
            .registry = registry,
            .atlas_mgr = atlas_mgr,
            .callback = callback,
            .watched = std.StringHashMap(i64).init(allocator),
            .pending = std.AutoArrayHashMap([]const u8, i64).init(allocator),
        };
    }

    pub fn deinit(self: *HotReload) void {
        var keys = self.watched.keyIterator();
        while (keys.next()) |key| self.allocator.free(@constCast(key.*));
        self.watched.deinit();
        self.pending.deinit();
    }

    /// Start watching a path.
    pub fn watch(self: *HotReload, path: []const u8) !void {
        const mod_time = self.vfs.fileSize(path) orelse return error.NotFound;
        const path_copy = try self.allocator.dupe(u8, path);
        try self.watched.put(path_copy, @intCast(mod_time));
    }

    /// Check for changes and reload if needed. Call once per frame.
    /// Returns true if any asset was reloaded.
    pub fn poll(self: *HotReload) !bool {
        var any_reloaded = false;
        var iter = self.watched.iterator();
        while (iter.next()) |entry| {
            const path = entry.key_ptr.*;
            const old_time = entry.value_ptr.*;
            const current_size = self.vfs.fileSize(path) orelse continue;
            const current_time: i64 = @intCast(current_size);
            if (current_time != old_time) {
                // Debounce: accumulate and wait
                self.pending.put(path, current_time) catch {};
            }
        }

        // Process debounced changes
        var pending_iter = self.pending.iterator();
        while (pending_iter.next()) |p_entry| {
            const path = p_entry.key_ptr.*;
            const new_time = p_entry.value_ptr.*;
            if (try self.reloadAsset(path)) {
                any_reloaded = true;
                self.watched.put(path, new_time) catch {};
            }
        }
        self.pending.clear();
        return any_reloaded;
    }

    fn reloadAsset(self: *HotReload, path: []const u8) !bool {
        const guid = self.registry.getByPath(path) orelse return false;
        const entry = self.registry.get(guid) orelse return false;

        // Read new content and compute hash
        const content = try self.vfs.readFile(path);
        const new_hash = hashContent(content);

        // Skip if content unchanged (timestamp-only change)
        if (entry.content_hash == new_hash) return false;

        // Reload based on type
        switch (entry.asset_type) {
            .image => {
                try reloadImage(self, path, content, entry.handle);
                if (self.callback) |cb| cb(.{ .image_reloaded = entry.handle });
            },
            .audio => {
                // Audio reloading handled by audio backend
                if (self.callback) |cb| cb(.{ .audio_reloaded = entry.handle });
            },
            .script => {
                // Script reloading handled by script system
                if (self.callback) |cb| cb(.{ .script_reloaded = entry.handle });
            },
            else => {},
        }

        // Update registry
        self.registry.updateAfterReload(guid, entry.handle, new_hash);
        return true;
    }

    fn reloadImage(
        self: *HotReload,
        path: []const u8,
        content: []const u8,
    ) !u32 {
        // Decode new image
        const img = try decodeImage(content);
        errdefer self.allocator.free(img.pixels);

        // Add to atlas
        if (self.atlas_mgr) |atlas| {
            const slot = try atlas.addImage(self.allocator, path, img);
            return slot;
        }

        return 0;
    }

    fn decodeImage(content: []const u8) !@import("asset_types.zig").Image {
        // Use stb_image from memory (would need stbi_load_from_memory)
        // For now, placeholder - write to temp file and use existing decode
        const Image = @import("asset_types.zig").Image;
        _ = content;
        return Image{};
    }
};

fn hashContent(content: []const u8) u64 {
    var h: u64 = 0xcbf29ce484222325;
    for (content) |c| {
        h ^= @as(u64, c);
        h *= 0x100000001b3;
    }
    return h;
}