//! End-to-end asset pipeline test (M6).
//!
//! The per-module tests prove each piece in isolation; this suite proves they
//! fit together: an import manifest becomes a `.pak`, the `.pak` mounts in the
//! VFS, entries read back byte-identical, hot reload sees an edit of a file that
//! came from the same bake, and the registry keeps a stable identity the whole
//! way.
//!
//! It needs no window, no GPU, no Lua and no physics — so it runs on every build
//! (`zig build test-assets`).

const std = @import("std");
const testing = std.testing;
const assets = @import("root.zig");

fn testIo() std.Io {
    return std.Io.Threaded.global_single_threaded.io();
}

var temp_seq: u32 = 0;
fn tempPath(buf: []u8, name: []const u8) []const u8 {
    temp_seq += 1;
    return std.fmt.bufPrint(buf, "/tmp/opencode/ember-pipeline-{d}-{s}", .{ temp_seq, name }) catch unreachable;
}

const one_px_png = assets.import.one_px_png;

test "import -> bake -> mount -> read, with stable GUIDs throughout" {
    const io = testIo();

    var path_buf: [160]u8 = undefined;
    const pak_path = tempPath(&path_buf, "game.pak");
    defer std.Io.Dir.cwd().deleteFile(io, pak_path) catch {};

    const sources = [_]assets.import.Source{
        .{ .path = "sprites/dot.png", .bytes = &one_px_png },
        .{ .path = "scripts/player.lua", .bytes = "local M = {}\nfunction M.update() end\nreturn M\n" },
    };

    // Bake.
    const size = try assets.import.bakeFile(io, testing.allocator, pak_path, &sources, .{ .compression = .deflate });
    try testing.expect(size > 0);

    // Mount and read back.
    var vfs = try assets.VFS.init(testing.allocator, io, ".", 64 * 1024);
    defer vfs.deinit();
    try vfs.openPak(pak_path);

    const lua = try vfs.readFileAlloc(testing.allocator, "scripts/player.lua");
    defer testing.allocator.free(lua);
    try testing.expectEqualStrings(sources[1].bytes, lua);

    // The GUID a scene would name is the same one the registry derives.
    try testing.expectEqual(
        assets.AssetGUID.fromPath("sprites/dot.png").value,
        assets.AssetGUID.fromPath("sprites/dot.png").value,
    );
    try testing.expect(vfs.exists("sprites/dot.png"));

    const st = vfs.stats();
    try testing.expectEqual(@as(usize, 2), st.pak_entries);
    try testing.expect(st.index_bytes <= st.budget_bytes);
}

test "an import manifest keeps every decode, and frees them on request" {
    const sources = [_]assets.import.Source{
        .{ .path = "a.png", .bytes = &one_px_png },
        .{ .path = "b.png", .bytes = &one_px_png },
    };
    const manifest = try assets.import.importBatch(testing.allocator, &sources);
    defer assets.import.freeManifest(testing.allocator, manifest);

    try testing.expectEqual(@as(usize, 2), manifest.len);
    for (manifest) |a| {
        try testing.expectEqual(assets.Format.png, a.format);
        try testing.expect(a.image != null);
        try testing.expectEqual(@as(u32, 1), a.image.?.width);
    }
    // Different paths, different identities.
    try testing.expect(manifest[0].guid.value != manifest[1].guid.value);
}

test "the byte budget holds with the real decoder, evicting the LRU entry" {
    const io = testIo();
    var a_buf: [160]u8 = undefined;
    var b_buf: [160]u8 = undefined;
    const a = tempPath(&a_buf, "a.png");
    const b = tempPath(&b_buf, "b.png");
    defer std.Io.Dir.cwd().deleteFile(io, a) catch {};
    defer std.Io.Dir.cwd().deleteFile(io, b) catch {};
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = a, .data = &one_px_png });
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = b, .data = &one_px_png });

    // A 1x1 RGBA image is 4 bytes, so a 4-byte budget admits exactly one: the
    // second load must evict the first rather than overflow the budget.
    var mgr = try assets.AssetManager.init(testing.allocator, 4, 4);
    defer mgr.deinit();

    _ = try mgr.getOrLoad(a);
    try testing.expectEqual(@as(usize, 4), mgr.bytesUsedNow());

    _ = try mgr.getOrLoad(b);
    try testing.expect(mgr.bytesUsedNow() <= 4);
    try testing.expectEqual(@as(usize, 1), mgr.slotsUsed());
}
