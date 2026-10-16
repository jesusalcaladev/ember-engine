//! `.pak` container — the single file the exported game loads its assets from
//! (M6, consumed by M10's export).
//!
//! ## The format
//!
//! All integers are little-endian. The layout is chosen so a loader reads the
//! whole table once (spec §3.4: no blocking I/O in the frame) and then serves
//! every asset by slicing a buffer it already has in memory.
//!
//! ```
//! header (16 bytes)
//!   [0..4)   magic  "EMPK"
//!   [4..8)   version u32 = 2
//!   [8..12)  flags   u32        reserved, must be 0
//!   [12..16) count   u32        number of entries
//! entry table (count entries, variable length, immediately after the header)
//!   path_len   u16
//!   path       [path_len]u8
//!   method     u8               compress.Method (0 store, 1 deflate)
//!   reserved   [3]u8            zero
//!   offset     u64              absolute byte offset of the payload
//!   raw_size   u64              payload size before compression
//!   stored_size u64             payload size after compression
//! payloads (concatenated, in table order)
//! ```
//!
//! ## What the previous draft got wrong, and why this one cannot
//!
//! The draft wrote a **fixed 256-byte** path field but reserved `@sizeOf` bytes
//! per entry while filling in fewer (struct padding), so the second entry's
//! table row started seven bytes off — the table and the payloads disagreed
//! about where anything was. The reader in `vfs.zig` read a null-terminated
//! path, a third convention again. Three encoders, no round-trip test.
//!
//! This version has exactly **one** encoder (`writeEntryTable`) and one decoder
//! (`Cursor`), both over the same explicit layout, and the round-trip test
//! builds an archive in memory and reads every entry back.

const std = @import("std");
const compress = @import("compress.zig");

pub const magic = "EMPK";
pub const format_version: u32 = 2;

/// The fixed part of an entry row: everything except the path bytes.
const entry_fixed_len = 2 + 1 + 3 + 8 + 8 + 8;

pub const PakError = error{
    /// The bytes do not start with the magic, or the version is not one this
    /// build reads.
    CorruptPak,
    /// The table claims an entry whose bytes run past the end of the archive.
    TruncatedEntry,
    /// Two sources were handed to the writer under the same path.
    DuplicatePath,
    /// A path is longer than the `u16` the format stores.
    PathTooLong,
    /// A payload failed to decompress.
    CorruptStream,
};

/// One asset to store. `data` is borrowed for the duration of the write.
pub const Source = struct {
    path: []const u8,
    data: []const u8,
};

/// One entry as it exists in an archive.
pub const Entry = struct {
    /// Owned by the `Archive` that produced it.
    path: []const u8,
    method: compress.Method,
    /// Absolute offset of the payload from the start of the archive.
    offset: u64,
    /// Payload length before compression.
    raw_size: u64,
    /// Payload length as stored.
    stored_size: u64,

    pub fn isCompressed(self: Entry) bool {
        return self.method == .deflate;
    }
};

pub const WriteOptions = struct {
    /// Try to shrink each entry. `store` writes payloads verbatim.
    compression: compress.Method = .store,
    level: compress.Level = .default,
};

/// Serialises `sources` into a fresh archive buffer the caller owns.
pub fn writeAlloc(
    allocator: std.mem.Allocator,
    sources: []const Source,
    options: WriteOptions,
) ![]u8 {
    // 1. Compress what can be compressed, and decide each entry's stored size.
    //    Any compressed payload that did not shrink is kept as `store`: a
    //    "compressed" entry larger than the raw one helps nobody. Duplicate
    //    paths are refused here because the format has no way to say which of
    //    two rows `get` should return.
    for (sources, 0..) |a, i| {
        if (a.path.len > std.math.maxInt(u16)) return error.PathTooLong;
        for (sources[i + 1 ..]) |b| {
            if (std.mem.eql(u8, a.path, b.path)) return error.DuplicatePath;
        }
    }

    // 1a. Initialise every row to "store", so the cleanup `defer` below is
    //     valid no matter where a later step fails. The compressed payloads
    //     are owned; the stored ones borrow the caller's bytes.
    var rows = try allocator.alloc(Row, sources.len);
    defer allocator.free(rows);
    for (sources, 0..) |source, i| {
        rows[i] = .{
            .path = source.path,
            .method = .store,
            .raw_size = source.data.len,
            .payload = source.data,
        };
    }
    defer {
        // Free by METHOD, not by a running index: an incompressible entry
        // between two compressible ones would make an index-prefix free the
        // wrong buffer (and leak the right one).
        for (rows) |r| {
            if (r.method == .deflate) allocator.free(@constCast(r.payload));
        }
    }

    // 1b. Compress what can be compressed. Any payload that did not shrink is
    //     kept as `store`: a "compressed" entry larger than the raw one helps
    //     nobody.
    if (options.compression == .deflate) {
        for (rows) |*r| {
            if (r.payload.len == 0) continue;
            const blob = try compress.deflateAlloc(allocator, r.payload, options.level);
            if (blob.len < r.payload.len) {
                r.method = .deflate;
                r.payload = blob;
            } else {
                allocator.free(blob);
            }
        }
    }

    // 2. Lay out the table and payloads. The table's size is a function of the
    //    paths, so payload offsets can be computed before anything is written.
    var table_size: usize = 0;
    for (rows) |r| {
        table_size += entry_fixed_len + r.path.len;
    }

    var payload_offset: u64 = 16 + table_size;
    for (rows) |*r| {
        r.offset = payload_offset;
        payload_offset += r.payload.len;
    }

    // 3. Emit. A byte list is enough; the format has no alignment requirement.
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);
    try out.ensureTotalCapacityPrecise(allocator, @intCast(payload_offset));

    try out.appendSlice(allocator, magic);
    appendInt(allocator, &out, u32, format_version);
    appendInt(allocator, &out, u32, 0); // global flags, reserved
    appendInt(allocator, &out, u32, @intCast(rows.len));

    for (rows) |r| try writeEntryTable(allocator, &out, r);
    for (rows) |r| try out.appendSlice(allocator, r.payload);

    std.debug.assert(out.items.len == payload_offset);
    return out.toOwnedSlice(allocator);
}

const Row = struct {
    path: []const u8,
    method: compress.Method,
    offset: u64 = 0,
    raw_size: u64,
    payload: []const u8,
};

fn writeEntryTable(allocator: std.mem.Allocator, out: *std.ArrayList(u8), r: Row) !void {
    appendInt(allocator, out, u16, @intCast(r.path.len));
    try out.appendSlice(allocator, r.path);
    try out.append(allocator, @intFromEnum(r.method));
    try out.appendSlice(allocator, &.{ 0, 0, 0 }); // reserved
    appendInt(allocator, out, u64, r.offset);
    appendInt(allocator, out, u64, r.raw_size);
    appendInt(allocator, out, u64, @intCast(r.payload.len));
}

fn appendInt(
    allocator: std.mem.Allocator,
    out: *std.ArrayList(u8),
    comptime T: type,
    value: T,
) void {
    var buf: [8]u8 = undefined;
    std.mem.writeInt(T, buf[0..@sizeOf(T)], value, .little);
    out.appendSlice(allocator, buf[0..@sizeOf(T)]) catch unreachable; // caller reserved
}

/// An in-memory view of a `.pak`. The `bytes` are BORROWED for the archive's
/// lifetime; only the entry paths are owned.
pub const Archive = struct {
    allocator: std.mem.Allocator,
    bytes: []const u8,
    entries: []Entry,

    /// Parses the header and table. Validation is total: a table that points
    /// outside `bytes` is rejected at open, so `extractAlloc` never has to
    /// bounds-check a hostile offset.
    pub fn init(allocator: std.mem.Allocator, bytes: []const u8) !Archive {
        var c = Cursor{ .bytes = bytes };
        if (!std.mem.eql(u8, c.take(4) orelse return error.CorruptPak, magic)) return error.CorruptPak;
        const version = c.readInt(u32) orelse return error.CorruptPak;
        if (version != format_version) return error.CorruptPak;
        _ = c.readInt(u32) orelse return error.CorruptPak; // global flags
        const entry_count = c.readInt(u32) orelse return error.CorruptPak;

        // A count that cannot fit in the remaining bytes is corrupt before we
        // even try to allocate for it.
        if (@as(usize, entry_count) > (bytes.len - c.pos) / entry_fixed_len) return error.CorruptPak;

        const entries = try allocator.alloc(Entry, entry_count);
        errdefer allocator.free(entries);

        var parsed: usize = 0;
        errdefer for (entries[0..parsed]) |e| allocator.free(@constCast(e.path));

        while (parsed < entry_count) : (parsed += 1) {
            const entry = try parseEntry(allocator, &c, bytes.len);
            entries[parsed] = entry;
        }

        return .{ .allocator = allocator, .bytes = bytes, .entries = entries };
    }

    pub fn deinit(self: *Archive) void {
        for (self.entries) |e| self.allocator.free(@constCast(e.path));
        self.allocator.free(self.entries);
        self.* = undefined;
    }

    pub fn count(self: *const Archive) usize {
        return self.entries.len;
    }

    /// The entry for `path`, or null. First match wins; the writer refuses
    /// duplicate paths, so there is at most one.
    pub fn get(self: *const Archive, path: []const u8) ?*const Entry {
        for (self.entries) |*e| {
            if (std.mem.eql(u8, e.path, path)) return e;
        }
        return null;
    }

    pub fn has(self: *const Archive, path: []const u8) bool {
        return self.get(path) != null;
    }

    /// The entry's payload, decompressed when needed. Caller owns the result.
    pub fn extractAlloc(
        self: *const Archive,
        allocator: std.mem.Allocator,
        entry: *const Entry,
    ) ![]u8 {
        const end = entry.offset + entry.stored_size;
        // Asserted, not checked: `init` rejected any entry that ran past the
        // buffer, so reaching here with bad bounds is a bug in this file.
        std.debug.assert(end <= self.bytes.len);
        const stored = self.bytes[@intCast(entry.offset)..@intCast(end)];
        return switch (entry.method) {
            .store => allocator.dupe(u8, stored),
            .deflate => compress.inflateAlloc(allocator, stored, @intCast(entry.raw_size)) catch
                return error.CorruptStream,
        };
    }

    /// Convenience: look up by path and extract, or `error.FileNotFound`.
    pub fn extractPathAlloc(
        self: *const Archive,
        allocator: std.mem.Allocator,
        path: []const u8,
    ) ![]u8 {
        const entry = self.get(path) orelse return error.FileNotFound;
        return self.extractAlloc(allocator, entry);
    }
};

fn parseEntry(allocator: std.mem.Allocator, c: *Cursor, total: usize) !Entry {
    const path_len = c.readInt(u16) orelse return error.CorruptPak;
    const path_bytes = c.take(path_len) orelse return error.TruncatedEntry;
    const method_raw = c.take(1) orelse return error.CorruptPak;
    const method: compress.Method = switch (method_raw[0]) {
        0 => .store,
        1 => .deflate,
        else => return error.CorruptPak,
    };
    _ = c.take(3) orelse return error.CorruptPak; // reserved
    const offset = c.readInt(u64) orelse return error.CorruptPak;
    const raw_size = c.readInt(u64) orelse return error.CorruptPak;
    const stored_size = c.readInt(u64) orelse return error.CorruptPak;

    // Every pointer in an entry must land inside the archive.
    if (offset > total or stored_size > total - offset) return error.TruncatedEntry;
    if (method == .store and raw_size != stored_size) return error.CorruptPak;

    return .{
        .path = try allocator.dupe(u8, path_bytes),
        .method = method,
        .offset = offset,
        .raw_size = raw_size,
        .stored_size = stored_size,
    };
}

const Cursor = struct {
    bytes: []const u8,
    pos: usize = 0,

    fn take(self: *Cursor, n: usize) ?[]const u8 {
        if (self.pos + n > self.bytes.len) return null;
        const s = self.bytes[self.pos..][0..n];
        self.pos += n;
        return s;
    }

    fn readInt(self: *Cursor, comptime T: type) ?T {
        const s = self.take(@sizeOf(T)) orelse return null;
        return std.mem.readInt(T, s[0..@sizeOf(T)], .little);
    }
};

// ── File helpers (load/bake time only; never in the frame) ──────────────────

/// Writes an archive to `path` on the current working directory.
pub fn writeFile(
    io: std.Io,
    allocator: std.mem.Allocator,
    path: []const u8,
    sources: []const Source,
    options: WriteOptions,
) !usize {
    const bytes = try writeAlloc(allocator, sources, options);
    defer allocator.free(bytes);
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = path, .data = bytes });
    return bytes.len;
}

/// Reads an archive file whole. The caller owns the bytes and must keep them
/// alive for as long as an `Archive` built over them is used.
pub fn readFileAlloc(io: std.Io, allocator: std.mem.Allocator, path: []const u8) ![]u8 {
    return std.Io.Dir.cwd().readFileAlloc(io, path, allocator, .limited(1 << 31));
}

// ── Tests ────────────────────────────────────────────────────────────────────

const testing = std.testing;

fn expectRoundTrip(sources: []const Source, options: WriteOptions) !void {
    const bytes = try writeAlloc(testing.allocator, sources, options);
    defer testing.allocator.free(bytes);

    var archive = try Archive.init(testing.allocator, bytes);
    defer archive.deinit();

    try testing.expectEqual(sources.len, archive.count());
    for (sources) |src| {
        const entry = archive.get(src.path) orelse return error.MissingEntry;
        try testing.expectEqual(src.data.len, entry.raw_size);
        const back = try archive.extractAlloc(testing.allocator, entry);
        defer testing.allocator.free(back);
        try testing.expectEqualSlices(u8, src.data, back);
    }
}

test "an uncompressed archive round-trips every entry" {
    const sources = [_]Source{
        .{ .path = "sprites/hero.png", .data = "PNG-ish bytes" },
        .{ .path = "a", .data = "" },
        .{ .path = "scripts/player.lua", .data = "function update() end" },
        .{ .path = "audio/jump.wav", .data = "RIFFxxxx" ** 3 },
    };
    try expectRoundTrip(&sources, .{ .compression = .store });
}

test "a deflated archive round-trips, and only shrinks what it can" {
    const repetitive = "tile tile tile tile " ** 50;
    const incompressible = "abcdefghijklmnopqrstuvwxyz0123456789"; // 36 bytes, no repeats
    const sources = [_]Source{
        // Incompressible FIRST, then compressible, then empty: the order that
        // broke an index-prefix cleanup and proves the free-by-method fix.
        .{ .path = "rand.bin", .data = incompressible },
        .{ .path = "big.txt", .data = repetitive },
        .{ .path = "empty", .data = "" },
    };
    try expectRoundTrip(&sources, .{ .compression = .deflate });

    const bytes = try writeAlloc(testing.allocator, &sources, .{ .compression = .deflate });
    defer testing.allocator.free(bytes);
    var archive = try Archive.init(testing.allocator, bytes);
    defer archive.deinit();

    // The repetitive entry shrank and is marked compressed...
    const big = archive.get("big.txt").?;
    try testing.expect(big.isCompressed());
    try testing.expect(big.stored_size < big.raw_size);
    // ...the incompressible one did not, and was kept verbatim rather than
    // stored larger than it started.
    const rand = archive.get("rand.bin").?;
    try testing.expect(!rand.isCompressed());
    try testing.expectEqual(rand.raw_size, rand.stored_size);
    // ...and an empty payload is never sent through the codec.
    const empty = archive.get("empty").?;
    try testing.expectEqual(@as(u64, 0), empty.stored_size);
}

test "a corrupt archive is rejected at open, not at extract" {
    const sources = [_]Source{.{ .path = "x", .data = "hello" }};
    const good = try writeAlloc(testing.allocator, &sources, .{});
    defer testing.allocator.free(good);

    // Wrong magic.
    var bad_magic = try testing.allocator.dupe(u8, good);
    defer testing.allocator.free(bad_magic);
    bad_magic[0] = 'X';
    try testing.expectError(error.CorruptPak, Archive.init(testing.allocator, bad_magic));

    // Truncated: cut the payload off the end.
    try testing.expectError(
        error.TruncatedEntry,
        Archive.init(testing.allocator, good[0 .. good.len - 2]),
    );

    // A duplicate path is refused by the writer, so the archive cannot contain
    // one to begin with.
    const dupes = [_]Source{
        .{ .path = "same", .data = "1" },
        .{ .path = "same", .data = "2" },
    };
    try testing.expectError(error.DuplicatePath, writeAlloc(testing.allocator, &dupes, .{}));
}

test "empty archives are legal and lookups miss cleanly" {
    const empty = try writeAlloc(testing.allocator, &.{}, .{});
    defer testing.allocator.free(empty);
    var archive = try Archive.init(testing.allocator, empty);
    defer archive.deinit();
    try testing.expectEqual(@as(usize, 0), archive.count());
    try testing.expect(archive.get("anything") == null);
    try testing.expectError(error.FileNotFound, archive.extractPathAlloc(testing.allocator, "anything"));
}
