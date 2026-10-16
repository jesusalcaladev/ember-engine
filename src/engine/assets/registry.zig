//! Asset Registry — stable GUID identity for assets across sessions.
//! Enables: hot reload, cross-references, save/load, .pak export.
//!
//! Every asset gets a GUID at import time. The GUID never changes unless
//! the source file content changes (content-addressable). This makes
//! hot-reload, save/load, and .pak export deterministic.

const std = @import("std");

// ── Wall clock, for `mod_time` ──────────────────────────────────────────────
//
// Zig 0.16 removed `std.time.timestamp()`. `mod_time` is compared against a
// FILE's mtime, so it must be a wall clock — `core.time`'s monotonic clock is
// for measuring, and mixing the two would make every reload look like a change.
const Timespec = extern struct {
    sec: isize,
    nsec: isize,
};

extern "c" fn clock_gettime(clk_id: c_int, tp: *Timespec) c_int;

const CLOCK_REALTIME: c_int = 0; // Linux

/// Seconds since the Unix epoch, or 0 if the clock could not be read (a 0
/// `mod_time` is a "unknown", not a valid timestamp, which `needsReload`
/// treats as a change — the safe direction for a hot reload).
fn unixTimeSeconds() i64 {
    var ts: Timespec = undefined;
    if (clock_gettime(CLOCK_REALTIME, &ts) != 0) return 0;
    return @intCast(ts.sec);
}

/// FNV-1a over arbitrary bytes. The one hash the asset layer uses for content
/// identity, change detection and the import manifest, so a file cannot hash
/// differently in two places.
///
/// The multiply is WRAPPING (`*%=`), and that is the whole point of using it:
/// FNV's mixing *is* the u64 overflow. A plain `*=` panics on it in Debug, which
/// is how the first version aborted on any path longer than a few bytes.
pub fn hashBytes(bytes: []const u8) u64 {
    var h: u64 = 0xcbf29ce484222325; // FNV offset basis
    for (bytes) |c| {
        h ^= @as(u64, c);
        h *%= 0x100000001b3;
    }
    return h;
}

fn hashPathInto(h0: u64, path: []const u8) u64 {
    var h = h0;
    for (path) |c| {
        h ^= @as(u64, c);
        h *%= 0x100000001b3;
    }
    return h;
}

pub const AssetGUID = struct {
    value: u64,

    /// Identity from path + content: two files at different paths are different
    /// assets, and the same path with edited bytes is the same asset with a new
    /// content hash (which is what hot reload compares).
    pub fn fromContent(path: []const u8, content: []const u8) AssetGUID {
        return .{ .value = hashPathInto(hashBytes(content), path) };
    }

    /// Identity from the path alone — the stable id a scene or script names,
    /// independent of whether the file is currently loaded.
    pub fn fromPath(path: []const u8) AssetGUID {
        return .{ .value = hashPathInto(0xcbf29ce484222325, path) };
    }

    pub fn isNone(self: AssetGUID) bool {
        return self.value == 0;
    }

    /// Writes `asset_<16 hex>` into `buf` and returns the PRINTED SLICE. The
    /// printed length is the return value, not the buffer's: returning `buf`
    /// handed callers 32 bytes with garbage after the id (a `log("{s}")` would
    /// print the tail of the buffer).
    pub fn toString(self: AssetGUID, buf: []u8) []const u8 {
        return std.fmt.bufPrint(buf, "asset_{x:0>16}", .{self.value}) catch "asset_0000000000000000";
    }
};

/// Asset type enum for the registry.
pub const AssetType = enum {
    image,
    audio,
    script,
    shader,
    font,
    /// A `.anim` clip (ROADMAP M13). Its `handle` is the clip's id in the
    /// animation system — the same GUID-derived `u32` an `AnimationPlayer`
    /// stores — so a script, a scene or the editor names one asset either way.
    clip,
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
    reverse_edges: std.AutoHashMap(AssetGUID, std.ArrayList(AssetGUID)),

    pub fn init(allocator: std.mem.Allocator) DependencyGraph {
        return .{
            .allocator = allocator,
            .reverse_edges = std.AutoHashMap(AssetGUID, std.ArrayList(AssetGUID)).init(allocator),
        };
    }

    pub fn deinit(self: *DependencyGraph) void {
        for (self.reverse_edges.valuePtr()) |*arr| arr.deinit(self.allocator);
        self.reverse_edges.deinit();
    }

    /// Add dependency: `dependent` depends on `dependency`.
    pub fn addDep(self: *DependencyGraph, dependent: AssetGUID, dependency: AssetGUID) void {
        const list = self.reverse_edges.getOrPutValue(dependency, std.ArrayList(AssetGUID).empty).value_ptr;
        // Avoid duplicates
        for (list.items) |g| if (g.value == dependent.value) return;
        list.append(self.allocator, dependent) catch {};
    }

    /// Get all assets that (transitively) depend on `guid`.
    pub fn getDependents(self: *DependencyGraph, guid: AssetGUID) !std.ArrayList(AssetGUID) {
        var result: std.ArrayList(AssetGUID) = .empty;
        var visited = std.AutoHashMap(AssetGUID, void).init(self.allocator);
        defer visited.deinit();

        // Use iterative DFS to avoid nested function issues
        var stack: std.ArrayList(AssetGUID) = .empty;
        defer stack.deinit(self.allocator);
        try stack.append(self.allocator, guid);

        while (stack.items.len > 0) {
            const current = stack.items[stack.items.len - 1];
            stack.items.len -= 1;

            if (visited.get(current)) |_| continue;
            visited.put(current, {}) catch {};

            if (self.reverse_edges.get(current)) |deps| {
                for (deps.items) |d| {
                    try result.append(self.allocator, d);
                    try stack.append(self.allocator, d);
                }
            }
        }

        return result;
    }

    /// Topological sort for load order (dependencies before dependents).
    /// Uses Kahn's algorithm (BFS) - no recursion needed.
    pub fn topologicalSort(self: *DependencyGraph, guids: []AssetGUID) !std.ArrayList(AssetGUID) {
        // Build forward edges (dependency -> dependents) for Kahn's algorithm
        var forward_edges = std.AutoHashMap(AssetGUID, std.ArrayList(AssetGUID)).init(self.allocator);
        defer {
            for (forward_edges.valuePtr()) |*arr| arr.deinit(self.allocator);
            forward_edges.deinit();
        }

        // Compute in-degree for each node in the subgraph
        var in_degree = std.AutoHashMap(AssetGUID, usize).init(self.allocator);
        defer in_degree.deinit();

        // Initialize all nodes
        for (guids) |g| {
            _ = in_degree.put(g, 0);
            _ = forward_edges.getOrPutValue(g, std.ArrayList(AssetGUID).empty);
        }

        // Build forward edges and in-degrees
        for (guids) |g| {
            if (self.reverse_edges.get(g)) |deps| {
                for (deps.items) |dependent| {
                    // dependent depends on g, so edge is g -> dependent
                    const list = forward_edges.getOrPutValue(g, std.ArrayList(AssetGUID).empty).value_ptr;
                    // Check for duplicate manually (ArrayList has no contains)
                    var found = false;
                    for (list.items) |existing| {
                        if (existing.value == dependent.value) {
                            found = true;
                            break;
                        }
                    }
                    if (!found) try list.append(self.allocator, dependent);
                    const current = in_degree.get(dependent) orelse 0;
                    in_degree.put(dependent, current + 1) catch {};
                }
            }
        }

        // Kahn's algorithm
        var result: std.ArrayList(AssetGUID) = .empty;
        var queue: std.ArrayList(AssetGUID) = .empty;
        defer queue.deinit(self.allocator);

        // Add all nodes with in-degree 0
        var iter = in_degree.iterator();
        while (iter.next()) |entry| {
            if (entry.value_ptr.* == 0) {
                try queue.append(self.allocator, entry.key_ptr.*);
            }
        }

        while (queue.items.len > 0) {
            const current = queue.items[0];
            queue.items[0] = queue.items[queue.items.len - 1];
            queue.items.len -= 1;

            try result.append(self.allocator, current);

            if (forward_edges.get(current)) |deps| {
                for (deps.items) |dependent| {
                    const new_degree = (in_degree.get(dependent) orelse 0) - 1;
                    in_degree.put(dependent, new_degree) catch {};
                    if (new_degree == 0) {
                        try queue.append(self.allocator, dependent);
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
    /// GUID -> RegistryEntry. A plain `AutoHashMap` and not the array flavor:
    /// Zig 0.16 removed `std.AutoArrayHashMap`, and this file never needed its
    /// insertion order — `getByType` hands callers a list, and the dependency
    /// walk is a Kahn sort, not an iteration over registration order.
    entries: std.AutoHashMap(AssetGUID, RegistryEntry),
    /// Source path -> GUID (for fast lookup by path).
    path_to_guid: std.StringHashMap(AssetGUID),

    pub fn init(allocator: std.mem.Allocator) AssetRegistry {
        return .{
            .allocator = allocator,
            .entries = std.AutoHashMap(AssetGUID, RegistryEntry).init(allocator),
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
        // `getPtr`, not `get`: `AutoHashMap.get` hands back a COPY, so the
        // original `get(...).* = ...` could never have compiled. An update
        // writes through the pointer and keeps the entry's own path string.
        if (self.entries.getPtr(guid)) |existing| {
            existing.asset_type = asset_type;
            existing.handle = handle;
            existing.mod_time = unixTimeSeconds();
            existing.content_hash = content_hash;
            return guid;
        }

        const path_copy = try self.allocator.dupe(u8, source_path);
        const entry = RegistryEntry{
            .guid = guid,
            .asset_type = asset_type,
            .source_path = path_copy,
            .handle = handle,
            .mod_time = unixTimeSeconds(),
            .content_hash = content_hash,
            // A fresh entry has no edges yet; `addDep`/the dependency graph
            // fills them. `RegistryEntry.dependencies`/`dependents` were added
            // after this literal was written and nothing ever set them, which
            // is why the struct never compiled.
            .dependencies = .empty,
            .dependents = .empty,
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

    /// Get all GUIDs of a specific type, in a list the CALLER frees (the
    /// allocator goes to `deinit`; `std.ArrayList` is unmanaged in Zig 0.16).
    pub fn getByType(self: *AssetRegistry, asset_type: AssetType) !std.ArrayList(AssetGUID) {
        var list: std.ArrayList(AssetGUID) = .empty;
        var iter = self.entries.iterator();
        while (iter.next()) |entry| {
            if (entry.value_ptr.asset_type == asset_type) {
                try list.append(self.allocator, entry.key_ptr.*);
            }
        }
        return list;
    }

    /// Check if asset needs reload (file modified).
    pub fn needsReload(self: *AssetRegistry, guid: AssetGUID, current_mod_time: i64, current_hash: u64) bool {
        if (self.entries.getPtr(guid)) |entry| {
            return entry.mod_time != current_mod_time or entry.content_hash != current_hash;
        }
        return false;
    }

    /// Update entry after hot reload.
    pub fn updateAfterReload(self: *AssetRegistry, guid: AssetGUID, new_handle: u32, new_hash: u64) void {
        // Through the pointer: `get` returns a copy, so the original body
        // silently updated a temporary and the reload never took.
        if (self.entries.getPtr(guid)) |entry| {
            entry.handle = new_handle;
            entry.content_hash = new_hash;
            entry.mod_time = unixTimeSeconds();
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

test "a GUID is stable for a path and differs across paths" {
    // Regression: this hashed to a u64 OVERFLOW, which panics in Debug — the
    // FNV multiply is now wrapping, so naming an asset no longer aborts a
    // debug build.
    const a = AssetGUID.fromPath("assets/animations/run.anim");
    try std.testing.expectEqual(a.value, AssetGUID.fromPath("assets/animations/run.anim").value);
    try std.testing.expect(a.value != AssetGUID.fromPath("assets/animations/idle.anim").value);
    try std.testing.expect(!a.isNone());

    var buf: [32]u8 = undefined;
    const text = a.toString(&buf);
    try std.testing.expect(std.mem.startsWith(u8, text, "asset_"));
    try std.testing.expectEqual(@as(usize, 22), text.len);
}

test "a clip registers as an asset and keeps its animation handle" {
    var reg = AssetRegistry.init(std.testing.allocator);
    defer reg.deinit();

    const path = "assets/animations/walk.anim";
    const clip_id: u32 = 0xdead_beef;
    const guid = try reg.register(.clip, path, clip_id, 0);

    const entry = reg.get(guid) orelse return error.NotFound;
    try std.testing.expectEqual(AssetType.clip, entry.asset_type);
    // The registry's handle IS the animation system's clip id, so the two
    // halves of M13 name the same asset with the same number.
    try std.testing.expectEqual(clip_id, entry.handle);
    try std.testing.expectEqual(guid.value, reg.getByPath(path).?.value);

    var clips = try reg.getByType(.clip);
    defer clips.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 1), clips.items.len);
}
