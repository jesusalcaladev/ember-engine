//! Script Asset Handling — Lua source validation and script_id registration.
//! Integrates VFS/Registry with the script system.

const std = @import("std");
const Scripts = @import("script").Scripts;
const VFS = @import("vfs.zig").VFS;
const AssetRegistry = @import("registry.zig").AssetRegistry;

pub const ScriptError = error{
    FileNotFound,
    SyntaxError,
    OutOfMemory,
};

/// Load and validate a Lua script, register with script system.
pub fn loadScript(
    vfs: *VFS,
    registry: *AssetRegistry,
    scripts: *Scripts,
    path: []const u8,
) ScriptError!u32 {
    const ext = fileExtension(path) orelse return ScriptError.SyntaxError;
    if (!isScriptExtension(ext)) return ScriptError.SyntaxError;

    const source = try vfs.readFile(path);
    defer vfs.allocator.free(source);

    // Syntax check: compile in LuaJIT (validates without executing)
    const script_id = try scripts.add(source);
    errdefer scripts.remove(script_id);

    // Register in asset registry
    const content_hash = hashContent(source);
    try registry.register(.script, path, @intCast(script_id), content_hash);

    return script_id;
}

/// Reload a script (hot reload).
pub fn reloadScript(
    vfs: *VFS,
    registry: *AssetRegistry,
    scripts: *Scripts,
    path: []const u8,
) ScriptError!u32 {
    const guid = registry.getByPath(path) orelse return ScriptError.FileNotFound;
    const entry = registry.get(guid) orelse return ScriptError.FileNotFound;
    const script_id = entry.handle;

    const source = try vfs.readFile(path);
    defer vfs.allocator.free(source);

    const new_hash = hashContent(source);
    if (entry.content_hash == new_hash) return script_id; // No change

    // Hot reload: replace script content, keep same script_id
    try scripts.replace(script_id, source);
    registry.updateAfterReload(guid, script_id, new_hash);
    return script_id;
}

fn isScriptExtension(ext: []const u8) bool {
    return std.mem.eql(u8, ext, "lua");
}

fn fileExtension(path: []const u8) ?[]const u8 {
    var i: isize = @as(isize, @intCast(path.len)) - 1;
    while (i >= 0) : (i -= 1) {
        const c = path[@intCast(i)];
        if (c == '.') return path[@as(usize, @intCast(i)) + 1 ..];
        if (c == '/' or c == '\\') break;
    }
    return null;
}

fn hashContent(content: []const u8) u64 {
    var h: u64 = 0xcbf29ce484222325;
    for (content) |c| {
        h ^= @as(u64, c);
        h *= 0x100000001b3;
    }
    return h;
}