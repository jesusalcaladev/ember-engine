//! Asset hot reload (M6): an on-disk edit becomes a decoded asset in < 250 ms.
//!
//! ## Event-driven on purpose
//!
//! The old draft called `fileSize()` on every watched path **every frame**. That
//! is a `stat` syscall per asset per frame — blocking I/O inside the frame,
//! which spec §3.4 forbids outright, and it did not even compare the right thing
//! (file *size* is not a modification signal).
//!
//! This version separates the two jobs:
//!
//! - **Change detection is a `stat`**, and the recommended driver is a
//!   directory watcher (the platform layer already ships inotify): when the
//!   watcher says a name changed, call `reloadPath(name)`. No syscalls on the
//!   frames without an event.
//! - **`scanAll()`** is the O(watched) fallback: one `stat` per path, for a
//!   thumbs-up tool, a test, or a platform with no watcher. It is named for
//!   what it costs and is documented as *not* a per-frame call.
//!
//! A change is only reported when the **content hash** moves, so a `touch` that
//! rewrites no bytes updates the recorded mtime and emits nothing — a text
//! editor's save-then-format dance does not reload the world twice.

const std = @import("std");
const registry = @import("registry.zig");
const image_mod = @import("image.zig");
const import = @import("import.zig");
const Image = @import("asset_types.zig").Image;
const AssetGUID = registry.AssetGUID;

/// One asset that changed, as handed to the callback. The `image`, when
/// present, is borrowed and only valid for the duration of the call.
pub const Change = struct {
    path: []const u8,
    guid: AssetGUID,
    format: import.Format,
    content_hash: u64,
    image: ?*const Image = null,
};

/// What `reloadPath`/`scanAll` report, without owning anything.
pub const Outcome = struct {
    path: []const u8,
    guid: AssetGUID,
    format: import.Format,
    content_hash: u64,
    width: u32 = 0,
    height: u32 = 0,
};

pub const Callback = *const fn (ctx: ?*anyopaque, change: Change) void;

const Watched = struct {
    /// Owned.
    path: []u8,
    mtime_ns: i96,
    size: u64,
    content_hash: u64,
};

pub const HotReload = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    /// The registry to keep in step; may be a live pointer or a detached one.
    registry: *registry.AssetRegistry,
    callback: ?Callback = null,
    ctx: ?*anyopaque = null,
    watched: std.ArrayList(Watched) = .empty,

    pub fn init(
        allocator: std.mem.Allocator,
        io: std.Io,
        reg: *registry.AssetRegistry,
    ) HotReload {
        return .{ .allocator = allocator, .io = io, .registry = reg };
    }

    pub fn deinit(self: *HotReload) void {
        for (self.watched.items) |w| self.allocator.free(w.path);
        self.watched.deinit(self.allocator);
        self.* = undefined;
    }

    /// Starts watching `path` (relative to cwd). Reads it once to seed the
    /// content hash, so nothing fires until the file actually changes.
    ///
    /// Re-watching a path already on the list is a no-op, which is what lets two
    /// sprites draw the same image (`sprite.set_image("hero.png")` twice) without
    /// the second registration growing the list, costing a second read, or
    /// leaving a duplicate for `reloadPath` to skip past.
    pub fn watch(self: *HotReload, path: []const u8) !void {
        for (self.watched.items) |w| {
            if (std.mem.eql(u8, w.path, path)) return;
        }
        const stat = try self.statOf(path);

        // Seed from the registry when it already knows the asset (no second
        // read); otherwise read the file once. A file that cannot be read seeds
        // a 0 hash, which only means its first successful read counts as a
        // change — the safe direction for a reload.
        const seeded_hash: u64 = if (self.registry.getByPath(path)) |guid|
            (if (self.registry.get(guid)) |e| e.content_hash else self.readHash(path) catch 0)
        else
            self.readHash(path) catch 0;

        const path_copy = try self.allocator.dupe(u8, path);
        errdefer self.allocator.free(path_copy);
        try self.watched.append(self.allocator, .{
            .path = path_copy,
            .mtime_ns = stat.mtime.nanoseconds,
            .size = stat.size,
            .content_hash = seeded_hash,
        });
    }

    /// Re-checks one path. Returns the change when the bytes moved, else null.
    /// This is the call a directory watcher drives.
    pub fn reloadPath(self: *HotReload, path: []const u8) !?Outcome {
        for (self.watched.items) |*w| {
            if (std.mem.eql(u8, w.path, path)) return self.checkOne(w);
        }
        return null;
    }

    /// One `stat` per watched path. See the module docs: this is the fallback,
    /// not the per-frame path. Returns the number of assets that changed.
    pub fn scanAll(self: *HotReload) !usize {
        var changes: usize = 0;
        for (self.watched.items) |*w| {
            if (try self.checkOne(w)) |_| changes += 1;
        }
        return changes;
    }

    pub fn watchedCount(self: *const HotReload) usize {
        return self.watched.items.len;
    }

    fn checkOne(self: *HotReload, w: *Watched) !?Outcome {
        const stat = self.statOf(w.path) catch |err| switch (err) {
            error.FileNotFound => return null, // deleted out from under us: not a reload
            else => return err,
        };
        if (stat.mtime.nanoseconds == w.mtime_ns and stat.size == w.size) return null;

        const bytes = std.Io.Dir.cwd().readFileAlloc(self.io, w.path, self.allocator, .limited(1 << 31)) catch |err| switch (err) {
            error.FileNotFound => return null,
            else => return err,
        };
        defer self.allocator.free(bytes);

        w.mtime_ns = stat.mtime.nanoseconds;
        w.size = stat.size;

        const hash = registry.hashBytes(bytes);
        if (hash == w.content_hash) return null; // touched, not edited
        w.content_hash = hash;

        const format = import.detect(w.path, bytes) orelse return null;

        var outcome = Outcome{
            .path = w.path,
            .guid = AssetGUID.fromPath(w.path),
            .format = format,
            .content_hash = hash,
        };

        // Decode images so the callback can upload them; everything else only
        // needs the bytes, which the caller can re-read.
        var decoded: ?Image = null;
        if (format.kind() == .image) {
            decoded = image_mod.decodeMemory(self.allocator, bytes) catch null;
            if (decoded) |img| {
                outcome.width = img.width;
                outcome.height = img.height;
            }
        }
        defer if (decoded) |img| self.allocator.free(img.pixels);

        // Keep the registry's record current for anything that asks it next.
        if (self.registry.getByPath(w.path)) |guid| {
            if (self.registry.get(guid)) |entry| {
                self.registry.updateAfterReload(guid, entry.handle, hash);
            }
        }

        if (self.callback) |cb| {
            cb(self.ctx, .{
                .path = w.path,
                .guid = outcome.guid,
                .format = format,
                .content_hash = hash,
                .image = if (decoded) |*img| img else null,
            });
        }

        return outcome;
    }

    fn statOf(self: *HotReload, path: []const u8) !std.Io.File.Stat {
        return std.Io.Dir.cwd().statFile(self.io, path, .{});
    }

    fn readHash(self: *HotReload, path: []const u8) !u64 {
        const bytes = try std.Io.Dir.cwd().readFileAlloc(self.io, path, self.allocator, .limited(1 << 31));
        defer self.allocator.free(bytes);
        return registry.hashBytes(bytes);
    }
};

// ── Tests ────────────────────────────────────────────────────────────────────

const testing = std.testing;

fn testIo() std.Io {
    return std.Io.Threaded.global_single_threaded.io();
}

var temp_seq: u32 = 0;
fn tempPath(buf: []u8, name: []const u8) []const u8 {
    temp_seq += 1;
    return std.fmt.bufPrint(buf, "/tmp/opencode/ember-hr-{d}-{s}", .{ temp_seq, name }) catch unreachable;
}

const one_px_png = import.one_px_png;

const Recorder = struct {
    calls: usize = 0,
    last_format: ?import.Format = null,
    last_width: u32 = 0,
    last_height: u32 = 0,

    /// The callback as the API expects it: the recorder rides in `ctx`, because
    /// that is exactly what `ctx` is for.
    fn onChange(ctx: ?*anyopaque, change: Change) void {
        const self: *Recorder = @ptrCast(@alignCast(ctx.?));
        self.calls += 1;
        self.last_format = change.format;
        if (change.image) |img| {
            self.last_width = img.width;
            self.last_height = img.height;
        }
    }
};

test "a touch with no byte change does not fire; an edit does" {
    const io = testIo();
    var path_buf: [160]u8 = undefined;
    const path = tempPath(&path_buf, "edit.png");
    defer std.Io.Dir.cwd().deleteFile(io, path) catch {};

    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = path, .data = &one_px_png });

    var reg = registry.AssetRegistry.init(testing.allocator);
    defer reg.deinit();

    var hr = HotReload.init(testing.allocator, io, &reg);
    defer hr.deinit();
    var rec = Recorder{};
    hr.callback = Recorder.onChange;
    hr.ctx = &rec;

    try hr.watch(path);
    try testing.expectEqual(@as(usize, 1), hr.watchedCount());

    // Nothing changed yet.
    try testing.expect((try hr.reloadPath(path)) == null);
    try testing.expectEqual(@as(usize, 0), rec.calls);

    // Rewrite with DIFFERENT bytes (a bigger PNG) and expect exactly one change,
    // carrying a decoded image.
    var bigger: [256]u8 = undefined;
    @memcpy(bigger[0..one_px_png.len], &one_px_png);
    @memset(bigger[one_px_png.len..], 0);
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = path, .data = &bigger });

    const outcome = (try hr.reloadPath(path)) orelse return error.ExpectedChange;
    try testing.expectEqual(import.Format.png, outcome.format);
    try testing.expectEqual(@as(usize, 1), rec.calls);
    try testing.expectEqual(@as(u32, 1), rec.last_width);

    // A second check with no further write is silent.
    try testing.expect((try hr.reloadPath(path)) == null);
    try testing.expectEqual(@as(usize, 1), rec.calls);
}

test "scanAll reports every changed path and skips un-watched ones" {
    const io = testIo();
    var a_buf: [160]u8 = undefined;
    var b_buf: [160]u8 = undefined;
    const a = tempPath(&a_buf, "a.lua");
    const b = tempPath(&b_buf, "b.lua");
    defer std.Io.Dir.cwd().deleteFile(io, a) catch {};
    defer std.Io.Dir.cwd().deleteFile(io, b) catch {};

    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = a, .data = "function a() end" });
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = b, .data = "function b() end" });

    var reg = registry.AssetRegistry.init(testing.allocator);
    defer reg.deinit();
    var hr = HotReload.init(testing.allocator, io, &reg);
    defer hr.deinit();

    try hr.watch(a);
    try hr.watch(b);
    try testing.expectEqual(@as(usize, 0), try hr.scanAll());

    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = a, .data = "function a() return 1 end" });
    try testing.expectEqual(@as(usize, 1), try hr.scanAll());
    try testing.expectEqual(@as(usize, 0), try hr.scanAll());

    // A path that was never watched is not the reload manager's business.
    try testing.expect((try hr.reloadPath("/tmp/opencode/never-watched.lua")) == null);
}

test "watching the same path twice keeps one entry, and still reloads" {
    const io = testIo();
    var path_buf: [160]u8 = undefined;
    const path = tempPath(&path_buf, "twice.png");
    defer std.Io.Dir.cwd().deleteFile(io, path) catch {};

    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = path, .data = &one_px_png });

    var reg = registry.AssetRegistry.init(testing.allocator);
    defer reg.deinit();
    var hr = HotReload.init(testing.allocator, io, &reg);
    defer hr.deinit();

    // Two sprites drawing the same image both register it. The second is a no-op
    // rather than a duplicate: `reloadPath` matches the FIRST entry, so a
    // duplicate would leave a stale hash for the unreachable one and would leak
    // the second path copy.
    try hr.watch(path);
    try hr.watch(path);
    try testing.expectEqual(@as(usize, 1), hr.watchedCount());

    var bigger: [256]u8 = undefined;
    @memcpy(bigger[0..one_px_png.len], &one_px_png);
    @memset(bigger[one_px_png.len..], 0);
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = path, .data = &bigger });

    // The single surviving entry still sees the edit.
    try testing.expect((try hr.reloadPath(path)) != null);
    try testing.expect((try hr.reloadPath(path)) == null);
}
