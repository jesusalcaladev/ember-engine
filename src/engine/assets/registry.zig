//! Asset Registry — stable GUID identity for assets across sessions.
//! Enables: hot reload, cross-references, save/load, .pak export.
//!
//! Every asset gets a GUID at import time. The GUID never changes unless
//! the source file content changes (content-addressable). This makes
//! hot-reload, save/load, and .pak export deterministic.

const std = @import("std");

pub const AssetGUID = struct {
    value: u64,

    pub fn fromContent(path: []const u8, content: []const u8) AssetGUID {
        var h: u64 = 0xcbf29ce484222325; // FNV offset basis
        for (path) |c| {
            h ^= @as(u64, c);
            h *= 0x100000001b3;
        }
        for (content) |c| {
            h ^= @as(u64, c);
            h *= 0x100000001b3;
        }
        return .{ .value = h };
    }

    pub fn fromPath(path: []const u8) AssetGUID {
        var h: u64 = 0xcbf29ce484222325;
        for (path) |c| {
            h ^= @as(u64, c);
            h *= 0x100000001b3;
        }
        return .{ .value = h };
    }

    pub fn isNone(self: AssetGUID) bool {
        return self.value == 0;
    }

    pub fn toString(self: AssetGUID, buf: []u8) []const u8 {
        _ = std.fmt.bufPrint(buf, "asset_{x:0>16}", .{self.value}) catch return "asset_0000000000000000";
        return buf;
    }
};

/// Asset type enum for the registry.
pub const AssetType = enum {
    image,
    audio,
    script,
    shader,
    font,
    /// For assets that are collections (atlas pages, audio banks).
    collection,
};

/// Registry entry: maps GUID -> asset metadata.
pub const RegistryEntry = struct {
    guid: AssetGUID,
    asset_type: AssetType,
    /// Source path (for dev mode) or .pak path (for export).
    source_path: []const u8,
    /// For images: atlas entry index. For audio: bank entry. For scripts: script_id.
    handle: u32,
    /// Timestamp of last modification (for hot reload).
    mod_time: i64,
    /// Content hash for change detection.
    content_hash: u64,
    /// Dependencies: GUIDs this asset depends on (e.g., material -> shader, prefab -> texture).
    dependencies: std.ArrayList(AssetGUID),
    /// Dependents: GUIDs that depend on this asset (reverse edges for cascade reload).
    dependents: std.ArrayList(AssetGUID),
};

/// Dependency graph for asset relationships (load order, hot reload cascade).
pub const DependencyGraph = struct {
    allocator: std.mem.Allocator,
    /// GUID -> list of dependent GUIDs (reverse edges)
    reverse_edges: std.AutoArrayHashMap(AssetGUID, std.ArrayList(AssetGUID)),

    pub fn init(allocator: std.mem.Allocator) DependencyGraph {
        return .{
            .allocator = allocator,
            .reverse_edges = std.AutoArrayHashMap(AssetGUID, std.ArrayList(AssetGUID)).init(allocator),
        };
    }

    pub fn deinit(self: *DependencyGraph) void {
        for (self.reverse_edges.valuePtr()) |*arr| arr.deinit(self.allocator);
        self.reverse_edges.deinit();
    }

    /// Add dependency: `dependent` depends on `dependency`.
    pub fn addDep(self: *DependencyGraph, dependent: AssetGUID, dependency: AssetGUID) void {
        const list = self.reverse_edges.getOrPutValue(dependency, std.ArrayList(AssetGUID).init(self.allocator)).value_ptr;
        // Avoid duplicates
        for (list.items) |g| if (g.value == dependent.value) return;
        list.append(dependent) catch {};
    }

    /// Get all assets that (transitively) depend on `guid`.
    pub fn getDependents(self: *DependencyGraph, guid: AssetGUID) !std.ArrayList(AssetGUID) {
        var result = std.ArrayList(AssetGUID).init(self.allocator);
        var visited = std.AutoArrayHashMap(AssetGUID, void).init(self.allocator);
        defer visited.deinit();

        // Use iterative DFS to avoid nested function issues
        var stack = std.ArrayList(AssetGUID).init(self.allocator);
        defer stack.deinit();
        try stack.append(guid);

        while (stack.items.len > 0) {
            const current = stack.items[stack.items.len - 1];
            stack.items.len -= 1;

            if (visited.get(current)) |_| continue;
            visited.put(current, {}) catch {};

            if (self.reverse_edges.get(current)) |deps| {
                for (deps.items) |d| {
                    try result.append(d);
                    try stack.append(d);
                }
            }
        }

        return result;
    }

    /// Topological sort for load order (dependencies before dependents).
    /// Uses Kahn's algorithm (BFS) - no recursion needed.
    pub fn topologicalSort(self: *DependencyGraph, guids: []AssetGUID) !std.ArrayList(AssetGUID) {
        // Build forward edges (dependency -> dependents) for Kahn's algorithm
        var forward_edges = std.AutoArrayHashMap(AssetGUID, std.ArrayList(AssetGUID)).init(self.allocator);
        defer {
            for (forward_edges.valuePtr()) |*arr| arr.deinit(self.allocator);
            forward_edges.deinit();
        }

        // Compute in-degree for each node in the subgraph
        var in_degree = std.AutoArrayHashMap(AssetGUID, usize).init(self.allocator);
        defer in_degree.deinit();

        // Initialize all nodes
        for (guids) |g| {
            _ = in_degree.put(g, 0);
            _ = forward_edges.getOrPutValue(g, std.ArrayList(AssetGUID).init(self.allocator));
        }

        // Build forward edges and in-degrees
        for (guids) |g| {
            if (self.reverse_edges.get(g)) |deps| {
                for (deps.items) |dependent| {
                    // dependent depends on g, so edge is g -> dependent
                    const list = forward_edges.getOrPutValue(g, std.ArrayList(AssetGUID).init(self.allocator)).value_ptr;
                    // Check for duplicate manually (ArrayList has no contains)
                    var found = false;
                    for (list.items) |existing| {
                        if (existing.value == dependent.value) {
                            found = true;
                            break;
                        }
                    }
                    if (!found) try list.append(dependent);
                    const current = in_degree.get(dependent) orelse 0;
                    in_degree.put(dependent, current + 1) catch {};
                }
            }
        }

        // Kahn's algorithm
        var result = std.ArrayList(AssetGUID).init(self.allocator);
        var queue = std.ArrayList(AssetGUID).init(self.allocator);
        defer queue.deinit();

        // Add all nodes with in-degree 0
        var iter = in_degree.iterator();
        while (iter.next()) |entry| {
            if (entry.value_ptr.* == 0) {
                try queue.append(entry.key_ptr.*);
            }
        }

        while (queue.items.len > 0) {
            const current = queue.items[0];
            queue.items[0] = queue.items[queue.items.len - 1];
            queue.items.len -= 1;

            try result.append(current);

            if (forward_edges.get(current)) |deps| {
                for (deps.items) |dependent| {
                    const new_degree = (in_degree.get(dependent) orelse 0) - 1;
                    in_degree.put(dependent, new_degree) catch {};
                    if (new_degree == 0) {
                        try queue.append(dependent);
                    }
                }
            }
        }

        // Check for cycles
        if (result.items.len != guids.len) {
            return error.CycleDetected;
        }

        return result;
    }
};

/// AssetRegistry — the central mapping from GUIDs to loaded assets.
pub const AssetRegistry = struct {
    allocator: std.mem.Allocator,
    /// GUID -> RegistryEntry
    entries: std.AutoArrayHashMap(AssetGUID, RegistryEntry),
    /// Source path -> GUID (for fast lookup by path).
    path_to_guid: std.StringHashMap(AssetGUID),

    pub fn init(allocator: std.mem.Allocator) AssetRegistry {
        return .{
            .allocator = allocator,
            .entries = std.AutoArrayHashMap(AssetGUID, RegistryEntry).init(allocator),
            .path_to_guid = std.StringHashMap(AssetGUID).init(allocator),
        };
    }

    pub fn deinit(self: *AssetRegistry) void {
        var keys = self.path_to_guid.keyIterator();
        while (keys.next()) |key| self.allocator.free(@constCast(key.*));
        self.path_to_guid.deinit();
        self.entries.deinit();
    }

    /// Register an asset. Returns the GUID (new or existing).
    pub fn register(
        self: *AssetRegistry,
        asset_type: AssetType,
        source_path: []const u8,
        handle: u32,
        content_hash: u64,
    ) !AssetGUID {
        const guid = AssetGUID.fromPath(source_path);
        if (self.entries.get(guid)) |existing| {
            // Update existing entry
            existing.* = .{
                .guid = guid,
                .asset_type = asset_type,
                .source_path = existing.source_path,
                .handle = handle,
                .mod_time = std.time.timestamp(),
                .content_hash = content_hash,
            };
            return guid;
        }

        const path_copy = try self.allocator.dupe(u8, source_path);
        const entry = RegistryEntry{
            .guid = guid,
            .asset_type = asset_type,
            .source_path = path_copy,
            .handle = handle,
            .mod_time = std.time.timestamp(),
            .content_hash = content_hash,
        };
        try self.entries.put(guid, entry);
        try self.path_to_guid.put(path_copy, guid);
        return guid;
    }

    /// Look up by GUID.
    pub fn get(self: *AssetRegistry, guid: AssetGUID) ?*const RegistryEntry {
        return self.entries.getPtr(guid);
    }

    /// Look up by source path.
    pub fn getByPath(self: *AssetRegistry, path: []const u8) ?AssetGUID {
        return self.path_to_guid.get(path);
    }

    /// Get all GUIDs of a specific type.
    pub fn getByType(self: *AssetRegistry, asset_type: AssetType) !std.ArrayList(AssetGUID) {
        var list = std.ArrayList(AssetGUID).init(self.allocator);
        var iter = self.entries.iterator();
        while (iter.next()) |entry| {
            if (entry.value_ptr.asset_type == asset_type) {
                try list.append(entry.key_ptr.*);
            }
        }
        return list;
    }

    /// Check if asset needs reload (file modified).
    pub fn needsReload(self: *AssetRegistry, guid: AssetGUID, current_mod_time: i64, current_hash: u64) bool {
        if (self.entries.get(guid)) |entry| {
            return entry.mod_time != current_mod_time or entry.content_hash != current_hash;
        }
        return false;
    }

    /// Update entry after hot reload.
    pub fn updateAfterReload(self: *AssetRegistry, guid: AssetGUID, new_handle: u32, new_hash: u64) void {
        if (self.entries.get(guid)) |entry| {
            entry.handle = new_handle;
            entry.content_hash = new_hash;
            entry.mod_time = std.time.timestamp();
        }
    }

    /// Remove an asset (editor deletion).
    pub fn remove(self: *AssetRegistry, guid: AssetGUID) void {
        if (self.entries.remove(guid)) |entry| {
            self.allocator.free(@constCast(entry.source_path));
            self.path_to_guid.remove(entry.source_path);
        }
    }
};