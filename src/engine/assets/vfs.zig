//! Virtual filesystem — one `readFileAlloc`/`exists`/`fileSize` surface over two
//! backends: the real filesystem (development) and a mounted `.pak` (export).
//!
//! ## Rules this file exists to enforce
//!
//! - **No blocking I/O in the frame** (spec §3.4). A `.pak` is read whole and
//!   parsed once, at mount time; afterwards an entry is a slice of a buffer the
//!   VFS already holds. Nothing here touches the disk twice.
//! - **The `.pak` format has one decoder**, `pack.zig`. The previous draft
//!   re-implemented the table parse here against a *third* convention (fixed
//!   256-byte paths in the writer, null-terminated paths here) and could never
//!   have read what it wrote. This file asks `pack.Archive` instead.
//! - **No freeing of stack memory.** The draft `defer free()`d the result of a
//!   `bufPrint` into a stack buffer on the file-exists path — a corrupting free
//!   that only stayed latent because nothing called it. Paths are built into a
//!   caller-owned scratch buffer here and never freed.
//!
//! The `root` is a development convenience (a project directory); in an export
//! the `.pak` is the whole filesystem and the root is never consulted.

const std = @import("std");
const pack = @import("pack.zig");

/// The longest project-relative path the VFS will build. Zig's `max_path_bytes`
/// is the ceiling for the resolved form; the extra headroom is the root prefix.
pub const max_path = 1024;

pub const Stats = struct {
    /// Entries in the mounted `.pak` (0 when none is mounted).
    pak_entries: usize,
    /// Bytes the path table costs, for the memory report.
    index_bytes: usize,
    /// The table's byte budget (spec §5: every cache has one).
    budget_bytes: usize,
    /// Bytes of the mapped `.pak`, or 0.
    pak_bytes: usize,
    /// True when a `.pak` is mounted.
    mounted: bool,
};

pub const VFS = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    /// Development root, e.g. a project directory. Owned.
    root: []const u8,
    /// The mounted archive's bytes. Owned; kept alive because `archive`
    /// borrows them.
    pak_bytes: ?[]u8 = null,
    archive: ?pack.Archive = null,
    index_budget: usize,

    pub fn init(
        allocator: std.mem.Allocator,
        io: std.Io,
        root: []const u8,
        index_budget: usize,
    ) !VFS {
        return .{
            .allocator = allocator,
            .io = io,
            .root = try allocator.dupe(u8, if (root.len == 0) "." else root),
            .index_budget = index_budget,
        };
    }

    pub fn deinit(self: *VFS) void {
        if (self.archive) |*a| a.deinit();
        if (self.pak_bytes) |b| self.allocator.free(b);
        self.allocator.free(@constCast(self.root));
        self.* = undefined;
    }

    /// Reads `path` whole and mounts it as the pak backend. Replaces any
    /// archive already mounted.
    pub fn openPak(self: *VFS, path: []const u8) !void {
        const bytes = try std.Io.Dir.cwd().readFileAlloc(self.io, path, self.allocator, .limited(1 << 31));
        errdefer self.allocator.free(bytes);

        var archive = try pack.Archive.init(self.allocator, bytes);
        errdefer archive.deinit();

        if (self.archive) |*old| old.deinit();
        if (self.pak_bytes) |old| self.allocator.free(old);

        self.pak_bytes = bytes;
        self.archive = archive;
    }

    /// Reads an asset by path. The pak wins when it has the entry; otherwise
    /// the file is read from `root`. Caller owns the bytes.
    pub fn readFileAlloc(self: *VFS, allocator: std.mem.Allocator, path: []const u8) ![]u8 {
        if (self.archive) |*a| {
            if (a.get(path)) |entry| return a.extractAlloc(allocator, entry);
        }
        var scratch: [max_path]u8 = undefined;
        const full = self.resolve(&scratch, path) orelse return error.NameTooLong;
        return std.Io.Dir.cwd().readFileAlloc(self.io, full, allocator, .limited(1 << 31));
    }

    pub fn exists(self: *VFS, path: []const u8) bool {
        if (self.archive) |*a| {
            if (a.has(path)) return true;
        }
        var scratch: [max_path]u8 = undefined;
        const full = self.resolve(&scratch, path) orelse return false;
        _ = std.Io.Dir.cwd().statFile(self.io, full, .{}) catch return false;
        return true;
    }

    pub fn fileSize(self: *VFS, path: []const u8) ?usize {
        if (self.archive) |*a| {
            if (a.get(path)) |entry| return @intCast(entry.raw_size);
        }
        var scratch: [max_path]u8 = undefined;
        const full = self.resolve(&scratch, path) orelse return null;
        const stat = std.Io.Dir.cwd().statFile(self.io, full, .{}) catch return null;
        return @intCast(stat.size);
    }

    /// Builds `root/path` into `scratch`. Returns null (never overflows) when
    /// the joined path cannot fit.
    fn resolve(self: *const VFS, scratch: []u8, path: []const u8) ?[]const u8 {
        // "." means "relative to cwd", so joining would only add a "./" prefix
        // that no caller benefits from.
        if (std.mem.eql(u8, self.root, ".")) {
            if (path.len > scratch.len) return null;
            @memcpy(scratch[0..path.len], path);
            return scratch[0..path.len];
        }
        return std.fmt.bufPrint(scratch, "{s}/{s}", .{ self.root, path }) catch null;
    }

    pub fn stats(self: *const VFS) Stats {
        var index_bytes: usize = 0;
        var entries: usize = 0;
        if (self.archive) |*a| {
            entries = a.count();
            for (a.entries) |e| index_bytes += e.path.len + @sizeOf(pack.Entry);
        }
        return .{
            .pak_entries = entries,
            .index_bytes = index_bytes,
            .budget_bytes = self.index_budget,
            .pak_bytes = if (self.pak_bytes) |b| b.len else 0,
            .mounted = self.archive != null,
        };
    }
};

// ── Tests ────────────────────────────────────────────────────────────────────

const testing = std.testing;

fn testIo() std.Io {
    return std.Io.Threaded.global_single_threaded.io();
}

/// A per-process unique name, so parallel test binaries and repeated runs never
/// collide. A counter, not a clock: `std.time` no longer offers a wall clock.
var temp_seq: u32 = 0;
fn tempPath(buf: []u8, name: []const u8) []const u8 {
    temp_seq += 1;
    return std.fmt.bufPrint(buf, "/tmp/opencode/ember-vfs-{d}-{s}", .{ temp_seq, name }) catch unreachable;
}

test "the filesystem backend reads, sizes and finds a file" {
    const io = testIo();
    var path_buf: [128]u8 = undefined;
    const path = tempPath(&path_buf, "fs.txt");
    defer std.Io.Dir.cwd().deleteFile(io, path) catch {};

    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = path, .data = "filesystem bytes" });

    var vfs = try VFS.init(testing.allocator, io, ".", 4096);
    defer vfs.deinit();

    const got = try vfs.readFileAlloc(testing.allocator, path);
    defer testing.allocator.free(got);
    try testing.expectEqualStrings("filesystem bytes", got);
    try testing.expect(vfs.exists(path));
    try testing.expectEqual(@as(usize, 16), vfs.fileSize(path).?);

    try testing.expect(!vfs.exists("/tmp/opencode/definitely-not-here-12345"));
    try testing.expect(vfs.fileSize("/tmp/opencode/definitely-not-here-12345") == null);
}

test "a mounted pak serves entries and shadows the filesystem" {
    const io = testIo();
    var path_buf: [128]u8 = undefined;
    const pak_path = tempPath(&path_buf, "game.pak");
    defer std.Io.Dir.cwd().deleteFile(io, pak_path) catch {};

    const sources = [_]pack.Source{
        .{ .path = "sprites/hero.dat", .data = "HERO" ** 32 },
        .{ .path = "config.json", .data = "{\"v\":1}" },
    };
    _ = try pack.writeFile(io, testing.allocator, pak_path, &sources, .{ .compression = .deflate });

    var vfs = try VFS.init(testing.allocator, io, ".", 4096);
    defer vfs.deinit();
    try vfs.openPak(pak_path);

    const hero = try vfs.readFileAlloc(testing.allocator, "sprites/hero.dat");
    defer testing.allocator.free(hero);
    try testing.expectEqualStrings("HERO" ** 32, hero);
    try testing.expect(vfs.exists("config.json"));
    try testing.expectEqual(@as(usize, 7), vfs.fileSize("config.json").?);

    const st = vfs.stats();
    try testing.expect(st.mounted);
    try testing.expectEqual(@as(usize, 2), st.pak_entries);
    try testing.expect(st.pak_bytes > 0);

    // A path the archive does not have falls through to the filesystem.
    try testing.expect(!vfs.exists("not/in/the/pak"));
    try testing.expectError(error.FileNotFound, vfs.readFileAlloc(testing.allocator, "not/in/the/pak"));
}
