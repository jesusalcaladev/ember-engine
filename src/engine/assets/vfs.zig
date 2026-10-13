//! Virtual Filesystem (VFS) — abstracts file access for both dev (filesystem)
//! and export (.pak). Spec §3.15: byte-budgeted, no blocking I/O in frame.

const std = @import("std");

pub const VFSError = error{
    NotFound,
    CorruptPak,
    UnsupportedOperation,
};

/// Source of a file: either a real filesystem path or a .pak entry.
pub const Source = union(enum) {
    filesystem: []const u8,
    pak: PakEntry,
};

pub const PakEntry = struct {
    offset: usize,
    size: usize,
};

/// VFS handle: can read from filesystem or .pak.
pub const VFS = struct {
    allocator: std.mem.Allocator,
    /// Root directory for filesystem reads (empty = cwd).
    root: []const u8,
    /// Open .pak file for export reads.
    pak_file: ?std.fs.File = null,
    /// Pak entry table: path -> PakEntry.
    pak_index: std.StringHashMap(PakEntry),
    /// Byte budget for pak index (spec §3.15).
    index_budget: usize,

    pub fn init(allocator: std.mem.Allocator, root: []const u8, index_budget: usize) !VFS {
        return .{
            .allocator = allocator,
            .root = if (root.len == 0) "." else root,
            .pak_index = std.StringHashMap(PakEntry).init(allocator),
            .index_budget = index_budget,
        };
    }

    pub fn deinit(self: *VFS) void {
        var keys = self.pak_index.keyIterator();
        while (keys.next()) |key| self.allocator.free(@constCast(key.*));
        self.pak_index.deinit();
        if (self.pak_file) |f| f.close();
        self.* = undefined;
    }

    /// Open a .pak file and build the index.
    pub fn openPak(self: *VFS, path: []const u8) !void {
        const file = try std.fs.cwd().openFile(path, .{});
        self.pak_file = file;
        try self.buildPakIndex(file);
    }

    fn buildPakIndex(self: *VFS, file: std.fs.File) !void {
        var reader = file.reader();
        // Read magic
        var magic: [4]u8 = undefined;
        try reader.readAll(&magic);
        if (!std.mem.eql(u8, &magic, "EMPK")) return error.CorruptPak;

        // Read version + count
        const version = try reader.readInt(u32, .little);
        if (version != 1) return error.CorruptPak;
        const count = try reader.readInt(u32, .little);

        // Read entries: path\0 + offset + size
        for (0..count) |_| {
            var path_buf: [256]u8 = undefined;
            var i: usize = 0;
            while (true) {
                const byte = try reader.readByte();
                if (byte == 0) break;
                path_buf[i] = byte;
                i += 1;
            }
            const path = try self.allocator.dupe(u8, path_buf[0..i]);
            const offset = try reader.readInt(usize, .little);
            const size = try reader.readInt(usize, .little);
            try self.pak_index.put(path, .{ .offset = offset, .size = size });
        }
    }

    /// Read entire file into memory (load time only, not frame).
    pub fn readFile(self: *VFS, path: []const u8) ![]u8 {
        if (self.pak_file) |pak| {
            const entry = self.pak_index.get(path) orelse return error.NotFound;
            const buf = try self.allocator.alloc(u8, entry.size);
            var reader = pak.reader();
            try reader.seekTo(@as(i64, @intCast(entry.offset)));
            try reader.readAll(buf);
            return buf;
        } else {
            const full_path = try self.allocator.dupe(u8, std.fmt.bufPrint("{s}/{s}", .{self.root, path}) catch "?");
            defer self.allocator.free(full_path);
            return try self.allocator.readFileAlloc(full_path, 100 * 1024 * 1024);
        }
    }

    /// Check if file exists.
    pub fn exists(self: *VFS, path: []const u8) bool {
        if (self.pak_index.get(path)) |_| return true;
        const full_path = std.fmt.bufPrint("{s}/{s}", .{self.root, path}) catch "?";
        defer self.allocator.free(full_path);
        return std.fs.cwd().exists(full_path);
    }

    /// Get file size without reading.
    pub fn fileSize(self: *VFS, path: []const u8) ?usize {
        if (self.pak_index.get(path)) |entry| return entry.size;
        const full_path = std.fmt.bufPrint("{s}/{s}", .{self.root, path}) catch "?";
        defer self.allocator.free(full_path);
        if (std.fs.cwd().openFile(full_path, .{})) |file| {
            const info = file.getInfo() catch return null;
            return info.size;
        }
        return null;
    }

    /// Stats for memory report (spec §3.15).
    pub const Stats = struct {
        pak_entries: usize,
        index_bytes: usize,
        budget_bytes: usize,
    };

    pub fn stats(self: *const VFS) Stats {
        var index_bytes: usize = 0;
        for (self.pak_index.keyIterator()) |key| {
            index_bytes += key.len;
        }
        index_bytes += self.pak_index.count() * @sizeOf(PakEntry);
        return .{
            .pak_entries = self.pak_index.count(),
            .index_bytes = index_bytes,
            .budget_bytes = self.index_budget,
        };
    }
};