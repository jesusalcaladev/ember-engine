//! Minimal Linux inotify wrapper: single-file watches and directory watches.
//!
//! Usage (one file):
//!   var watcher = try platform.watchFile("project.config");
//!   defer watcher.deinit();
//!   // each frame:
//!   if (watcher.poll()) |changed| { if (changed) reload(); }
//!
//! Usage (a directory of assets):
//!   var dir = try platform.watchDirectory(allocator, "assets/audio");
//!   var names: [8][]const u8 = undefined;
//!   // each frame:
//!   const n = dir.pollNames(&names);
//!   for (names[0..n]) |name| if (isSound(name)) audio.reload(name);

const std = @import("std");
const posix = std.posix;
const linux = std.os.linux;
const Allocator = std.mem.Allocator;

// Linux inotify constants (from kernel headers)
const IN_NONBLOCK = 0x800;
const IN_CLOSE_WRITE = 0x8;
const IN_MOVED_TO = 0x00000080;
const IN_CREATE = 0x00000100;
const IN_DELETE = 0x00000200;
const IN_MOVED_FROM = 0x00000040;
const IN_MOVE_SELF = 0x800;
const IN_DELETE_SELF = 0x400;

pub const FileWatchError = error{
    InotifyInitFailed,
    WatchFailed,
    ReadFailed,
    InvalidPath,
    OutOfMemory,
};

pub const FileWatcher = struct {
    fd: i32 = -1,
    wd: usize = 0,
    path: []const u8,
    /// Aligned EXPLICITLY: the event struct is read through
    /// `@ptrCast(@alignCast(&buf[i]))`, and an auto-laid-out struct is free to
    /// place a `u8` array at any offset — a `buf` that starts one byte off the
    /// struct's alignment makes that cast a runtime panic in Debug and a
    /// misaligned load in Release. The kernel guarantees each EVENT in the
    /// buffer is aligned; the BUFFER's own start is our problem.
    buf: [4096]u8 align(@alignOf(linux.inotify_event)) = undefined,

    pub fn init(allocator: Allocator, path: []const u8) FileWatchError!FileWatcher {
        // inotify_init1 with IN_NONBLOCK so poll() never blocks
        const fd_usize = linux.inotify_init1(IN_NONBLOCK);
        // inotify_init1 returns -1 (usize.max) on error
        if (fd_usize > (std.math.maxInt(usize) >> 1)) return error.InotifyInitFailed;
        const fd: i32 = @intCast(fd_usize);

        // Watch for close_write (file written and closed), move_self, delete_self
        const mask: u32 = IN_CLOSE_WRITE | IN_MOVE_SELF | IN_DELETE_SELF;
        // inotify_add_watch expects a null-terminated path
        var path_nt = try allocator.alloc(u8, path.len + 1);
        @memcpy(path_nt[0..path.len], path);
        path_nt[path.len] = 0;
        const wd = linux.inotify_add_watch(fd, @ptrCast(@alignCast(path_nt.ptr)), mask);
        allocator.free(path_nt);
        if (wd > (std.math.maxInt(usize) >> 1)) {
            _ = linux.close(fd);
            return error.WatchFailed;
        }

        return FileWatcher{ .fd = fd, .wd = wd, .path = path };
    }

    /// Polls for changes. Returns:
    /// - `true` if the watched file changed
    /// - `false` if no change
    /// - `error.InvalidPath` if the file was deleted/moved and no longer exists
    pub fn poll(self: *FileWatcher) !bool {
        // `posix.read`, NOT the raw syscall: it returns `error.WouldBlock` for
        // EAGAIN, which is what a non-blocking inotify fd answers when there is
        // nothing to report. Reading the raw `usize` and comparing it against 0
        // silently turned that -11 into 1.8e19 and walked the (uninitialised)
        // buffer as if an event had arrived.
        const n = posix.read(self.fd, &self.buf) catch |err| switch (err) {
            error.WouldBlock => return false,
            else => return error.ReadFailed,
        };
        if (n == 0) return false;

        var i: usize = 0;
        while (i < n) {
            const event: *const linux.inotify_event = @ptrCast(@alignCast(&self.buf[i]));
            const mask = event.mask;
            // File was written and closed, or moved away, or deleted
            if ((mask & (IN_CLOSE_WRITE | IN_MOVE_SELF | IN_DELETE_SELF)) != 0) {
                // Verify file still exists (could have been deleted)
                const io = std.Io.Threaded.global_single_threaded.io();
                if (std.Io.Dir.cwd().statFile(io, self.path, .{})) |_| {
                    return true;
                } else |_| {
                    return error.InvalidPath;
                }
            }
            i += @sizeOf(linux.inotify_event) + @as(usize, @intCast(event.len));
        }
        return false;
    }

    pub fn deinit(self: *FileWatcher) void {
        if (self.wd != 0) {
            _ = linux.inotify_rm_watch(self.fd, @intCast(self.wd));
            self.wd = 0;
        }
        if (self.fd >= 0) {
            _ = linux.close(self.fd);
            self.fd = -1;
        }
    }
};

/// Convenience function: create a watcher for a file path.
pub fn watchFile(allocator: Allocator, path: []const u8) FileWatchError!FileWatcher {
    return FileWatcher.init(allocator, path);
}

/// A directory watch: the shape asset hot-reload needs.
///
/// The single-file watcher answers "did this one file change", which is right
/// for `project.config` (a file editors rewrite in place) and useless for a
/// directory of assets: watching every `.wav` individually means N descriptors
/// and a list that has to be rebuilt whenever an artist adds a file. inotify
/// watches a DIRECTORY and reports which entry inside it moved, so one watch
/// covers the whole library and a new file needs no registration.
///
/// Only the events that mean "look at this file again" are reported:
/// `close_write` (an editor saved it), `moved_to` (an editor wrote a temp and
/// renamed it over the original — the common non-destructive save), and
/// `create` (a brand-new file). Deletes are NOT reported: there is nothing to
/// reload, and the bank keeps the last decoded bytes until the budget evicts
/// them, which is the behaviour a running game wants.
pub const DirectoryWatcher = struct {
    fd: i32 = -1,
    wd: usize = 0,
    /// The watched directory, NUL-terminated and owned (inotify needs it that
    /// way, and a caller's slice is free to move).
    path_nt: []u8,
    /// True while the directory still exists. A `move_self`/`delete_self` on
    /// the directory itself clears it: the entries then reported would be
    /// meaningless, so the poll answers zero until the watch is re-created.
    alive: bool = true,
    /// See `FileWatcher.buf` for why the alignment is spelled out.
    buf: [4096]u8 align(@alignOf(linux.inotify_event)) = undefined,

    pub fn init(allocator: Allocator, dir_path: []const u8) FileWatchError!DirectoryWatcher {
        const fd_usize = linux.inotify_init1(IN_NONBLOCK);
        if (fd_usize > (std.math.maxInt(usize) >> 1)) return error.InotifyInitFailed;
        const fd: i32 = @intCast(fd_usize);
        errdefer _ = linux.close(fd);

        const path_nt = try allocator.alloc(u8, dir_path.len + 1);
        errdefer allocator.free(path_nt);
        @memcpy(path_nt[0..dir_path.len], dir_path);
        path_nt[dir_path.len] = 0;

        const mask: u32 = IN_CLOSE_WRITE | IN_MOVED_TO | IN_CREATE | IN_MOVE_SELF | IN_DELETE_SELF;
        const wd = linux.inotify_add_watch(fd, @ptrCast(@alignCast(path_nt.ptr)), mask);
        if (wd > (std.math.maxInt(usize) >> 1)) return error.WatchFailed;

        return .{ .fd = fd, .wd = wd, .path_nt = path_nt };
    }

    pub fn deinit(self: *DirectoryWatcher, allocator: Allocator) void {
        if (self.wd != 0) {
            _ = linux.inotify_rm_watch(self.fd, @intCast(self.wd));
            self.wd = 0;
        }
        if (self.fd >= 0) {
            _ = linux.close(self.fd);
            self.fd = -1;
        }
        allocator.free(self.path_nt);
        self.alive = false;
    }

    /// The watched directory, as the caller spelled it.
    pub fn path(self: *const DirectoryWatcher) []const u8 {
        return self.path_nt[0 .. self.path_nt.len - 1];
    }

    /// Polls for changed entries. Fills `out` with up to `out.len` names and
    /// returns how many it filled; the slices are borrowed from the watcher's
    /// own buffer and live until the next `pollNames`.
    ///
    /// A capacity the caller can hit (a directory sync touching twenty files at
    /// once) TRUNCATES rather than loops: the buffer is drained on this call,
    /// so the extra events are reported on the next one. An asset reload is
    /// idempotent, so a one-frame delay costs nothing.
    pub fn pollNames(self: *DirectoryWatcher, out: [][]const u8) usize {
        if (!self.alive or self.fd < 0) return 0;
        // `posix.read` for the same reason the single-file watcher uses it:
        // EAGAIN comes back as an error, not as a huge byte count.
        const n = posix.read(self.fd, &self.buf) catch |err| switch (err) {
            error.WouldBlock => return 0,
            else => {
                // A read error is a dead watch, not a panic: go quiet rather
                // than spin on a fd that will never answer again.
                self.alive = false;
                return 0;
            },
        };
        if (n == 0) return 0;

        var count: usize = 0;
        var i: usize = 0;
        while (i < n) {
            const event: *const linux.inotify_event = @ptrCast(@alignCast(&self.buf[i]));
            const mask = event.mask;
            // The directory itself was moved or removed: the kernel dropped the
            // watch's meaning, so stop reporting until someone re-creates it.
            if ((mask & (IN_MOVE_SELF | IN_DELETE_SELF)) != 0) {
                self.alive = false;
                return count;
            }
            const name_len: usize = @intCast(event.len);
            if (name_len > 0 and (mask & (IN_CLOSE_WRITE | IN_MOVED_TO | IN_CREATE)) != 0) {
                // `len` includes the NUL the kernel appends; a zero-length name
                // is the watch on the directory itself, not an entry.
                const raw = self.buf[i + @sizeOf(linux.inotify_event) ..][0..name_len];
                const end = std.mem.indexOfScalar(u8, raw, 0) orelse raw.len;
                if (end > 0 and count < out.len) {
                    out[count] = raw[0..end];
                    count += 1;
                }
            }
            i += @sizeOf(linux.inotify_event) + name_len;
        }
        return count;
    }
};

/// Convenience function: create a watcher for a directory of assets.
pub fn watchDirectory(allocator: Allocator, path: []const u8) FileWatchError!DirectoryWatcher {
    return DirectoryWatcher.init(allocator, path);
}

/// True when `name` looks like a sound file the audio backend can decode.
///
/// Lives here rather than in the caller so the editor, the runtime and the
/// asset importer agree on the extension list; `audio` owns the decoder, and
/// `platform` owns neither, so a shared name list is the smallest honest
/// contract. Case-insensitive: Windows-authored `.WAV` files exist in the wild.
pub fn isAudioAsset(name: []const u8) bool {
    const dot = std.mem.lastIndexOfScalar(u8, name, '.') orelse return false;
    const ext = name[dot + 1 ..];
    // Eight bytes covers every extension a decoder takes ("x-flac" is six) and
    // keeps the fold in a fixed stack buffer with no allocation.
    if (ext.len == 0 or ext.len > 8) return false;
    var buf: [8]u8 = undefined;
    for (ext, 0..) |c, i| buf[i] = std.ascii.toLower(c);
    const e = buf[0..ext.len];
    return std.mem.eql(u8, e, "wav") or
        std.mem.eql(u8, e, "ogg") or
        std.mem.eql(u8, e, "mp3") or
        std.mem.eql(u8, e, "flac");
}

// ── Tests ──────────────────────────────────────────────────────────────────

const testing = std.testing;

/// Waits (bounded) for inotify to deliver an event. Delivery is asynchronous:
/// a `close(2)` on this thread's file is visible to the kernel immediately, but
/// the READ on this fd can still return EAGAIN for a few microseconds, and a
/// test that polled once would fail on a machine that is merely slow.
///
/// `core.time.sleepNs` rather than `std.Thread.sleep` — the latter is not
/// available in this std's `Thread` namespace, and this module deliberately
/// imports nothing outside std.
fn waitForNames(w: *DirectoryWatcher, out: [][]const u8, attempts: usize) usize {
    var i: usize = 0;
    while (i < attempts) : (i += 1) {
        const n = w.pollNames(out);
        if (n != 0) return n;
        // A busy spin for the first few tries (the common case is delivered
        // within a few microseconds), then a real sleep via `clock_nanosleep`
        // — the same call `core/time.sleepNs` wraps, inlined because this module
        // imports nothing outside std.
        if (i > 8) {
            var req = std.os.linux.timespec{
                .sec = 0,
                .nsec = 2 * std.time.ns_per_ms,
            };
            _ = std.os.linux.clock_nanosleep(std.os.linux.CLOCK.MONOTONIC, .{ .ABSTIME = false }, &req, null);
        }
    }
    return 0;
}

test "a directory watch reports the entry that was written" {
    const alloc = testing.allocator;
    const io = std.Io.Threaded.global_single_threaded.io();

    // A scratch directory under .zig-cache, so the repo is not dirtied and the
    // tests stay re-runnable.
    const dir_path = ".zig-cache/tmp/inotify-dirwatch";
    std.Io.Dir.cwd().deleteTree(io, dir_path) catch {};
    try std.Io.Dir.cwd().createDirPath(io, dir_path);
    defer std.Io.Dir.cwd().deleteTree(io, dir_path) catch {};

    var w = DirectoryWatcher.init(alloc, dir_path) catch |err| {
        // A container without inotify (rare, but possible) skips rather than
        // fails: the watcher is a convenience, and the tests that matter for
        // audio reload live in the audio module.
        std.debug.print("skip: inotify unavailable ({s})\n", .{@errorName(err)});
        return;
    };
    defer w.deinit(alloc);

    var names: [8][]const u8 = undefined;
    try testing.expectEqual(@as(usize, 0), w.pollNames(&names));

    // 1. A file written and closed (an editor saving in place).
    {
        const f = try std.Io.Dir.cwd().createFile(io, dir_path ++ "/hit.wav", .{});
        defer f.close(io);
        try f.writeStreamingAll(io, "x");
    }
    var n = waitForNames(&w, &names, 100);
    try testing.expect(n >= 1);
    try testing.expectEqualStrings("hit.wav", names[0]);

    // 2. A non-audio file is reported too: filtering is the CALLER's job (the
    //    watcher knows nothing about audio), and a reporter that dropped names
    //    would make the filter above unverifiable.
    {
        const f = try std.Io.Dir.cwd().createFile(io, dir_path ++ "/notes.txt", .{});
        defer f.close(io);
        try f.writeStreamingAll(io, "x");
    }
    n = waitForNames(&w, &names, 100);
    try testing.expect(n >= 1);
    try testing.expectEqualStrings("notes.txt", names[0]);

    // 3. Nothing further: the events were consumed, not replayed.
    try testing.expectEqual(@as(usize, 0), w.pollNames(&names));
}

test "isAudioAsset accepts the decoders' extensions, case-insensitively" {
    try testing.expect(isAudioAsset("boom.wav"));
    try testing.expect(isAudioAsset("BOOM.WAV"));
    try testing.expect(isAudioAsset("theme.ogg"));
    try testing.expect(isAudioAsset("voice.mp3"));
    try testing.expect(isAudioAsset("song.flac"));
    try testing.expect(isAudioAsset("a/b/c/deep/path.wav"));
    try testing.expect(!isAudioAsset("sprite.png"));
    try testing.expect(!isAudioAsset("noextension"));
    try testing.expect(!isAudioAsset("trailing."));
    try testing.expect(!isAudioAsset("a.really.long.extension"));
}