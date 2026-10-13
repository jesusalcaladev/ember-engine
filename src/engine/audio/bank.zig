//! The sound bank: a decoded-PCM cache with a byte budget and LRU eviction.
//!
//! ## Why a bank, and not per-voice data
//!
//! A level has hundreds of sounds but only a few dozen unique clips. Sharing
//! the decoded PCM avoids decoding the same file twice and keeps the kilobytes
//! in one place, under one budget.
//!
//! ## The byte budget and eviction (spec §3.15)
//!
//! The bank OWNS its bytes; the mixer and the voices only borrow `Pcm` views.
//! When a new sound would exceed `budget_bytes`, the least-recently-used
//! sounds are dropped until it fits. A bank with a budget it does not enforce
//! is a leak with extra steps.
//!
//! ## Decoding is load time only
//!
//! The device callback must never decode: it is real I/O and a real
//! allocation, both forbidden in the frame (spec §3.1, §3.4) and on the RT
//! thread (§7). `getOrLoad` is called at load time or from the editor's
//! importer; the runtime only ever reads.
//!
//! ## What the draft got wrong, and how it is fixed here
//!
//! The draft's eviction loop was replaced by a bad search-and-replace: six
//! `for (self.slots, 0..) |*|*s, _|` lines that do not parse, a triplicated
//! `_ = incoming_bytes;`, a bare `_ = void;`, and two `try expect(true)`
//! placeholder tests. It also never stored the allocator, so `freeSlot` could
//! free a slot's PCM but not its path, and `deinit` fished both back out of a
//! loop. The bank now holds its allocator, so a slot's whole footprint is
//! released by the same code that allocated it.

const std = @import("std");
const audio = @import("audio.zig");

const Pcm = audio.Pcm;

/// Index into the bank's slot table. `u16` is the same width the command and
/// the voice carry, so a bank slot survives the trip to the device thread
/// without a widening.
///
/// **0 is the "no slot" sentinel**: `Voice.bank_slot` and
/// `SoundEmitter2D.bank_slot` default to it, and the bank never hands it out
/// (see `pickSlot`), so "nothing loaded" and "the first sound" are different
/// numbers everywhere — which is what lets a scene emitter say "I have no
/// sound" without a second flag.
pub const SlotId = u16;

/// The reserved "nothing loaded" slot. Exported so a caller that wants to
/// clear an emitter's slot writes the engine's own sentinel.
pub const no_slot: SlotId = 0;

/// A streaming source: a file read in chunks, kept in a sliding window (ring)
/// that the MAIN thread refills so the device thread never touches the disk.
///
/// The window covers `[window_start, window_start + window_frames)`, and
/// `ring[0]` is absolute frame `window_start`. `consumed` is the highest frame
/// the device thread has read; the main thread reads it to decide how far the
/// window can slide. It is small and aligned, so `atomic` rather than a lock.
pub const Stream = struct {
    /// The decoder handle, as the backend handed it over.
    handle: ?*anyopaque,
    /// Close with the device that opened it, since the bank holds no device.
    device: audio.Device,
    ring: []f32,
    channels: u16 = 1,
    sample_rate: u32 = 44100,
    /// Total frames, or 0 when the source has no known length.
    total_frames: u32 = 0,
    window_start: u32 = 0,
    window_frames: u32 = 0,
    eof: bool = false,
    consumed: std.atomic.Value(u32) = std.atomic.Value(u32).init(0),

    pub fn capacityFrames(self: *const Stream) u32 {
        if (self.channels == 0) return 0;
        return @intCast(self.ring.len / self.channels);
    }
};

/// One resident sound: either fully decoded (`pcm`) or a stream window.
pub const Slot = struct {
    pcm: Pcm = .{},
    /// The file this slot came from. Owned by the bank; empty = free slot.
    path: []const u8 = "",
    /// LRU clock: the tick this slot was last read.
    last_used_tick: u64 = 0,
    /// Set for a streaming slot; the PCM view above points into `stream.ring`.
    stream: ?*Stream = null,

    pub fn isFree(self: *const Slot) bool {
        return self.path.len == 0;
    }
};

pub const Bank = struct {
    allocator: std.mem.Allocator,
    slots: []Slot,
    /// Total bytes currently held by decoded sounds.
    bytes_used: usize = 0,
    /// Maximum bytes the bank may hold. Set at init from the project config.
    budget_bytes: usize = 0,
    /// Monotonic LRU clock. The owner advances it once per frame.
    current_tick: u64 = 0,

    const Self = @This();

    pub fn init(allocator: std.mem.Allocator, count: usize, budget_bytes: usize) !Self {
        const slots = try allocator.alloc(Slot, count);
        for (slots) |*s| s.* = .{};
        return .{
            .allocator = allocator,
            .slots = slots,
            .budget_bytes = budget_bytes,
        };
    }

    pub fn deinit(self: *Self) void {
        for (0..self.slots.len) |i| self.freeSlot(i);
        self.allocator.free(self.slots);
        self.* = undefined;
    }

    pub fn capacity(self: *const Self) usize {
        return self.slots.len;
    }

    pub fn bytesUsed(self: *const Self) usize {
        return self.bytes_used;
    }

    /// Advances the LRU clock once per frame.
    pub fn advanceTick(self: *Self) void {
        self.current_tick += 1;
    }

    /// Returns the bank slot for `path`, decoding it if it is not resident.
    ///
    /// Evicts LRU slots until the decoded sound fits. Returns
    /// `error.OutOfMemory` when the sound is larger than the whole budget
    /// (evicting everything would be strictly worse than failing).
    pub fn getOrLoad(self: *Self, device: audio.Device, path: []const u8) !SlotId {
        // Resident? Just touch the LRU clock.
        for (self.slots, 0..) |*s, i| {
            if (!s.isFree() and std.mem.eql(u8, s.path, path)) {
                s.last_used_tick = self.current_tick;
                return @intCast(i);
            }
        }

        // Decode BEFORE evicting: a file that fails to decode must not cost us
        // a resident sound.
        var pcm = Pcm{};
        try device.decode(self.allocator, path, &pcm);
        errdefer self.allocator.free(pcm.samples);
        if (pcm.isEmpty()) return error.UnsupportedFormat;

        const bytes = pcm.samples.len * @sizeOf(f32);
        if (bytes > self.budget_bytes) return error.OutOfMemory;

        const slot = self.pickSlot();
        self.freeSlot(slot);

        // `bytes <= budget`, so this always terminates once there is room.
        while (self.bytes_used + bytes > self.budget_bytes) {
            const victim = self.lruIndex() orelse break;
            if (victim == slot) break;
            self.freeSlot(victim);
        }

        const owned_path = try self.allocator.dupe(u8, path);
        errdefer self.allocator.free(owned_path);

        self.slots[slot].pcm = pcm;
        self.slots[slot].path = owned_path;
        self.slots[slot].last_used_tick = self.current_tick;
        self.bytes_used += bytes;
        return @intCast(slot);
    }

    /// The slot to reuse: a free one if any, otherwise the LRU.
    ///
    /// Slot 0 is never returned. `Voice.bank_slot` and
    /// `SoundEmitter2D.bank_slot` both default to 0, and the component's rule is
    /// "0 means nothing loaded" — so a bank that handed out slot 0 would make an
    /// emitter that never configured a sound name the first sound anyone
    /// decoded. One slot of 4096 is the price of that being unambiguous.
    fn pickSlot(self: *Self) usize {
        for (self.slots[1..], 1..) |s, i| {
            if (s.isFree()) return i;
        }
        return self.lruIndex() orelse 1;
    }

    fn lruIndex(self: *const Self) ?usize {
        var best: ?usize = null;
        var oldest: u64 = std.math.maxInt(u64);
        for (self.slots[1..], 1..) |s, i| {
            if (!s.isFree() and s.last_used_tick < oldest) {
                oldest = s.last_used_tick;
                best = i;
            }
        }
        return best;
    }

    fn freeSlot(self: *Self, index: usize) void {
        const s = &self.slots[index];
        if (s.isFree() and s.stream == null) return;
        if (s.stream) |st| {
            st.device.streamClose(st.handle);
            self.bytes_used -= @min(self.bytes_used, st.ring.len * @sizeOf(f32));
            self.allocator.free(st.ring);
            self.allocator.destroy(st);
        } else {
            self.bytes_used -= @min(self.bytes_used, s.pcm.samples.len * @sizeOf(f32));
            self.allocator.free(s.pcm.samples);
        }
        self.allocator.free(s.path);
        s.* = .{};
    }

    /// A borrowed PCM view for a slot. The bank retains ownership; the caller
    /// must not free or modify the samples. Touches the LRU clock.
    pub fn get(self: *Self, slot: SlotId) ?*const Pcm {
        if (slot >= self.slots.len) return null;
        const s = &self.slots[slot];
        if (s.isFree()) return null;
        s.last_used_tick = self.current_tick;
        return &s.pcm;
    }

    /// A borrowed PCM view that does NOT touch the LRU clock.
    ///
    /// The mixer runs on the device thread and the bank's clock is advanced by
    /// the main thread, so a `get` from the device thread would be a write on a
    /// value another thread owns. `peek` is a pure read: the device thread only
    /// ever calls this one.
    pub fn peek(self: *const Self, slot: SlotId) ?*const Pcm {
        if (slot >= self.slots.len) return null;
        const s = &self.slots[slot];
        if (s.isFree()) return null;
        return &s.pcm;
    }

    /// Replaces the PCM of an already-loaded path (the hot-reload path). The
    /// slot keeps its identity, so live voices pointing at it pick up the new
    /// bytes; the caller clamps their cursors.
    pub fn replace(self: *Self, slot: SlotId, device: audio.Device, path: []const u8) !void {
        if (slot >= self.slots.len) return error.OutOfRange;
        var pcm = Pcm{};
        try device.decode(self.allocator, path, &pcm);
        errdefer self.allocator.free(pcm.samples);
        if (pcm.isEmpty()) return error.UnsupportedFormat;

        const old_bytes = if (self.slots[slot].isFree()) 0 else self.slots[slot].pcm.samples.len * @sizeOf(f32);
        const new_bytes = pcm.samples.len * @sizeOf(f32);
        // Free the old bytes first so the budget check is honest about the
        // space the replacement actually needs.
        self.bytes_used -= @min(self.bytes_used, old_bytes);
        self.allocator.free(self.slots[slot].pcm.samples);
        self.slots[slot].pcm = pcm;
        self.bytes_used += new_bytes;

        // Over budget after a bigger replacement: shed the LRU, never the slot
        // we just refreshed.
        while (self.bytes_used > self.budget_bytes) {
            const victim = self.lruIndex() orelse break;
            if (victim == slot) break;
            self.freeSlot(victim);
        }
    }

    /// Frees a specific sound by path (the editor deleting a sound asset).
    /// Returns true when something was removed.
    pub fn remove(self: *Self, path: []const u8) bool {
        for (self.slots, 0..) |*s, i| {
            if (!s.isFree() and std.mem.eql(u8, s.path, path)) {
                self.freeSlot(i);
                return true;
            }
        }
        return false;
    }

    // ── Streaming ───────────────────────────────────────────────────────────

    /// Opens `path` as a STREAM: the file is not decoded into one buffer, only a
    /// window of `window_frames` is ever resident. Returns
    /// `error.UnsupportedFormat` when the backend has no streaming support, so
    /// the caller can fall back to a full decode.
    ///
    /// Load time only (it opens the file). The ring is charged to the same byte
    /// budget as decoded PCM, so a stream cannot smuggle memory past §3.15.
    pub fn openStream(
        self: *Self,
        device: audio.Device,
        path: []const u8,
        window_frames: u32,
    ) !SlotId {
        for (self.slots, 0..) |*s, i| {
            if (!s.isFree() and std.mem.eql(u8, s.path, path)) {
                s.last_used_tick = self.current_tick;
                return @intCast(i);
            }
        }

        var info = audio.StreamInfo{};
        const handle = try device.streamOpen(path, &info);
        errdefer device.streamClose(handle);
        if (info.channels == 0) return error.UnsupportedFormat;

        // The window is what the caller asked for, but never larger than the
        // sound itself: a 1-second clip should not reserve a 20-minute ring.
        // The caller (the system) sizes it from the device period.
        const want = @max(window_frames, 1);
        const frames = if (info.frames != 0) @max(@min(want, info.frames), 1) else want;
        const ring = try self.allocator.alloc(f32, @as(usize, frames) * info.channels);
        errdefer self.allocator.free(ring);

        const st = try self.allocator.create(Stream);
        errdefer self.allocator.destroy(st);
        st.* = .{
            .handle = handle,
            .device = device,
            .ring = ring,
            .channels = info.channels,
            .sample_rate = info.sample_rate,
            .total_frames = info.frames,
        };

        const slot = self.pickSlot();
        self.freeSlot(slot);
        const ring_bytes = ring.len * @sizeOf(f32);
        if (ring_bytes > self.budget_bytes) return error.OutOfMemory;
        while (self.bytes_used + ring_bytes > self.budget_bytes) {
            const victim = self.lruIndex() orelse break;
            if (victim == slot) break;
            self.freeSlot(victim);
        }

        const owned_path = try self.allocator.dupe(u8, path);
        errdefer self.allocator.free(owned_path);

        self.slots[slot].stream = st;
        self.slots[slot].path = owned_path;
        self.slots[slot].last_used_tick = self.current_tick;
        self.bytes_used += ring_bytes;
        // Fill the window before anyone plays it, so the first buffer is not
        // silence while the prefetch catches up.
        self.refillSlot(@intCast(slot));
        return @intCast(slot);
    }

    /// The device thread's note of how far a streaming voice has read. Stored
    /// atomically; the main thread reads it in `refillSlot`.
    pub fn noteStreamCursor(self: *Self, slot: SlotId, cursor: f32) void {
        if (slot >= self.slots.len) return;
        const st = self.slots[slot].stream orelse return;
        const f: u32 = if (cursor <= 0) 0 else @intFromFloat(cursor);
        st.consumed.store(f, .monotonic);
    }

    /// True when the slot is fed from a file window rather than a full decode.
    /// A stream cannot be re-decoded in place: its PCM is a window into a ring
    /// the main thread refills, so `replace` would free an interior pointer.
    /// `Audio.reload` refuses streaming slots for exactly this reason.
    pub fn isStream(self: *const Self, slot: SlotId) bool {
        if (slot >= self.slots.len) return false;
        return self.slots[slot].stream != null;
    }

    /// The main thread's half of streaming: slide the window to follow the
    /// device's cursor and read ahead until it is full. No allocation, no lock,
    /// and it is the only place a stream file is read.
    pub fn refillSlot(self: *Self, slot: SlotId) void {
        if (slot >= self.slots.len) return;
        const s = &self.slots[slot];
        const st = s.stream orelse return;
        const cap = st.capacityFrames();
        if (cap == 0) return;
        const ch = st.channels;
        const consumed = st.consumed.load(.monotonic);

        if (consumed < st.window_start or consumed > st.window_start + st.window_frames) {
            // The device is outside the window: a loop wrapped, or it ran past
            // the read-ahead. Re-anchor at what it is reading now.
            if (st.device.streamSeek(st.handle, consumed)) {
                st.window_start = consumed;
                st.window_frames = 0;
                st.eof = false;
            }
        } else {
            const drop = consumed - st.window_start;
            if (drop >= st.window_frames) {
                st.window_start += drop;
                st.window_frames = 0;
            } else if (drop > 0) {
                std.mem.copyForwards(
                    f32,
                    st.ring[0 .. (st.window_frames - drop) * ch],
                    st.ring[drop * ch .. st.window_frames * ch],
                );
                st.window_start += drop;
                st.window_frames -= drop;
            }
        }

        while (!st.eof and st.window_frames < cap) {
            const want = cap - st.window_frames;
            const got = st.device.streamRead(
                st.handle,
                st.ring.ptr + @as(usize, st.window_frames) * ch,
                want,
            );
            st.window_frames += got;
            if (got < want) {
                st.eof = true;
                break;
            }
        }
        self.publishWindow(slot);
    }

    /// Points the slot's Pcm view at the current window. The device thread reads
    /// this; the window only ever moves forward past what it has consumed.
    fn publishWindow(self: *Self, slot: usize) void {
        const s = &self.slots[slot];
        const st = s.stream orelse return;
        const total = if (st.total_frames != 0) st.total_frames else st.window_start + st.window_frames;
        s.pcm = .{
            .frames = total,
            .channels = st.channels,
            .sample_rate = st.sample_rate,
            .samples = st.ring[0 .. @as(usize, st.window_frames) * st.channels],
            .base_frame = st.window_start,
            .streaming = true,
        };
    }

    /// Refills every streaming slot. Called once per frame from the main thread.
    pub fn refillAllStreams(self: *Self) void {
        for (self.slots, 0..) |s, i| {
            if (s.stream != null) self.refillSlot(@intCast(i));
        }
    }

    /// The slot a path currently occupies, or null. For the editor and the
    /// emitter component, which store a slot id rather than a path.
    pub fn find(self: *const Self, path: []const u8) ?SlotId {
        for (self.slots, 0..) |s, i| {
            if (!s.isFree() and std.mem.eql(u8, s.path, path)) return @intCast(i);
        }
        return null;
    }

    /// The path a slot was decoded from, borrowed from the bank. Empty when the
    /// slot is free, and empty for a streaming slot (the window is fed from the
    /// file by the bank, and the authoritative name is the one `openStream` was
    /// given — see `streamPath`).
    ///
    /// This is what an inspector shows next to a slot id: the emitter component
    /// stores the id (M1: components are bit-exact, strings are not saved in
    /// them), and the bank is the one place that remembers the name behind it.
    pub fn pathOf(self: *const Self, slot: SlotId) []const u8 {
        if (slot >= self.slots.len) return "";
        const s = &self.slots[slot];
        if (s.isFree()) return "";
        return s.path;
    }

    /// Stats for the memory report (spec §3.15).
    pub const Stats = struct {
        slots_total: usize,
        slots_used: usize,
        bytes_used: usize,
        budget_bytes: usize,
    };

    pub fn stats(self: *const Self) Stats {
        var used: usize = 0;
        for (self.slots) |s| {
            if (!s.isFree()) used += 1;
        }
        return .{
            .slots_total = self.slots.len,
            .slots_used = used,
            .bytes_used = self.bytes_used,
            .budget_bytes = self.budget_bytes,
        };
    }
};

// ── Tests ────────────────────────────────────────────────────────────────────

const testing = std.testing;

/// A backend that returns synthetic PCM of a length derived from the path, so
/// the bank's budgeting and eviction can be tested with no device and no files.
const FakeBackend = struct {
    var last_len_frames: u32 = 0;

    fn createDevice(_: audio.DeviceDesc, _: audio.MixCallback, _: ?*anyopaque) ?*anyopaque {
        return null;
    }
    fn destroyDevice(_: ?*anyopaque) void {}
    fn startDevice(_: ?*anyopaque) bool {
        return true;
    }
    fn stopDevice(_: ?*anyopaque) void {}
    fn stats(_: ?*anyopaque) audio.Stats {
        return .{};
    }
    fn decode(allocator: std.mem.Allocator, path: []const u8, out: *Pcm) audio.DecodeError!void {
        // "<name>:N" -> N mono frames of silence. The name makes paths DISTINCT
        // (so two entries are two sounds), the number sets the size. Anything
        // with no colon or a non-numeric tail is a decode failure, which is how
        // the "a bad file costs no resident sound" test works.
        const colon = std.mem.lastIndexOfScalar(u8, path, ':') orelse return error.UnsupportedFormat;
        const frames: u32 = std.fmt.parseInt(u32, path[colon + 1 ..], 10) catch return error.UnsupportedFormat;
        const samples = allocator.alloc(f32, frames) catch return error.OutOfMemory;
        @memset(samples, 0);
        last_len_frames = frames;
        out.* = .{ .frames = frames, .channels = 1, .sample_rate = 48000, .samples = samples };
    }

    /// A fake stream: synthesises frame `n` as `n % 251`, so the window's
    /// contents are exactly the ABSOLUTE frames it claims to hold and a test can
    /// assert where the window slid to.
    const FakeStream = struct { frames: u32, cursor: u32 = 0 };

    fn streamOpen(path: []const u8, out: *audio.StreamInfo) audio.StreamError!?*anyopaque {
        const colon = std.mem.lastIndexOfScalar(u8, path, ':') orelse return error.UnsupportedFormat;
        const frames: u32 = std.fmt.parseInt(u32, path[colon + 1 ..], 10) catch return error.UnsupportedFormat;
        const s = std.heap.c_allocator.create(FakeStream) catch return error.OutOfMemory;
        s.* = .{ .frames = frames };
        out.* = .{ .frames = frames, .channels = 1, .sample_rate = 48000 };
        return @ptrCast(s);
    }
    fn streamRead(handle: ?*anyopaque, buf: [*]f32, frames: u32) u32 {
        const s: *FakeStream = @ptrCast(@alignCast(handle.?));
        if (s.cursor >= s.frames) return 0;
        const n = @min(frames, s.frames - s.cursor);
        var i: u32 = 0;
        while (i < n) : (i += 1) {
            buf[i] = @floatFromInt((s.cursor + i) % 251);
        }
        s.cursor += n;
        return n;
    }
    fn streamSeek(handle: ?*anyopaque, frame: u32) bool {
        const s: *FakeStream = @ptrCast(@alignCast(handle.?));
        s.cursor = @min(frame, s.frames);
        return true;
    }
    fn streamClose(handle: ?*anyopaque) void {
        std.heap.c_allocator.destroy(@as(*FakeStream, @ptrCast(@alignCast(handle.?))));
    }

    const vtable = audio.VTable{
        .createDevice = createDevice,
        .destroyDevice = destroyDevice,
        .startDevice = startDevice,
        .stopDevice = stopDevice,
        .stats = stats,
        .decode = decode,
        .streamOpen = streamOpen,
        .streamRead = streamRead,
        .streamSeek = streamSeek,
        .streamClose = streamClose,
    };
    fn device() audio.Device {
        return .{ .vtable = &vtable, .ctx = null, .name = "fake" };
    }
};

test "the bank never hands out slot 0, the 'nothing loaded' sentinel" {
    const alloc = testing.allocator;
    var bank = try Bank.init(alloc, 4, 1 << 20);
    defer bank.deinit();

    // The first sound decoded lands in slot 1: `Voice.bank_slot` and
    // `SoundEmitter2D.bank_slot` both default to 0, and the component's rule is
    // "0 means nothing loaded". A bank that started at 0 would make an emitter
    // that never configured a sound name the first sound anyone decoded.
    var i: usize = 0;
    while (i < 4) : (i += 1) {
        var name: [16]u8 = undefined;
        const path = try std.fmt.bufPrint(&name, "s{d}:10", .{i});
        const slot = try bank.getOrLoad(FakeBackend.device(), path);
        try testing.expect(slot != no_slot);
    }
    // Slot 0 stayed empty, so `Slot.isFree` still reports it as such and the
    // sentinel keeps its meaning after the bank has been full and evicted.
    try testing.expect(bank.slots[0].isFree());
}

test "a sound is decoded once and re-read from the bank" {
    const alloc = testing.allocator;
    var bank = try Bank.init(alloc, 4, 1 << 20);
    defer bank.deinit();

    const a = try bank.getOrLoad(FakeBackend.device(), "same:10");
    const b = try bank.getOrLoad(FakeBackend.device(), "same:10");
    try testing.expectEqual(a, b);
    try testing.expectEqual(@as(usize, 1), bank.stats().slots_used);
    try testing.expectEqual(@as(usize, 40), bank.bytesUsed()); // 10 frames * 4 B
}

test "a decode failure does not evict a resident sound" {
    const alloc = testing.allocator;
    var bank = try Bank.init(alloc, 4, 1 << 20);
    defer bank.deinit();

    _ = try bank.getOrLoad(FakeBackend.device(), "keep:10");
    try testing.expectError(error.UnsupportedFormat, bank.getOrLoad(FakeBackend.device(), "not-a-sound"));
    try testing.expectError(error.UnsupportedFormat, bank.getOrLoad(FakeBackend.device(), "bad:NaN"));
    try testing.expectEqual(@as(usize, 1), bank.stats().slots_used);
    try testing.expect(bank.find("keep:10") != null);
}

test "eviction respects the byte budget, dropping the least recently used" {
    const alloc = testing.allocator;
    // 4 slots, room for exactly 25 mono frames (100 bytes).
    var bank = try Bank.init(alloc, 4, 100);
    defer bank.deinit();

    bank.advanceTick();
    const a = try bank.getOrLoad(FakeBackend.device(), "a:10"); // 40 B
    bank.advanceTick();
    const b = try bank.getOrLoad(FakeBackend.device(), "b:10"); // 40 B, total 80
    bank.advanceTick();
    // Touch `b` so `a` is the LRU.
    _ = bank.get(b);
    bank.advanceTick();
    // A third 40 B sound would need 120: `a` (the LRU) is evicted to fit.
    const c = try bank.getOrLoad(FakeBackend.device(), "c:10");
    try testing.expect(c != a);
    try testing.expect(bank.find("a:10") == null);
    try testing.expect(bank.bytesUsed() <= 100);
    // The two survivors are the two most recently used.
    try testing.expect(bank.get(b) != null);
    try testing.expect(bank.get(c) != null);
    try testing.expect(bank.get(a) == null);
}

test "a sound larger than the whole budget fails instead of emptying the bank" {
    const alloc = testing.allocator;
    var bank = try Bank.init(alloc, 4, 32); // 32 bytes
    defer bank.deinit();
    try testing.expectError(error.OutOfMemory, bank.getOrLoad(FakeBackend.device(), "big:100"));
    try testing.expectEqual(@as(usize, 0), bank.bytesUsed());
}

test "remove frees the bytes and the path" {
    const alloc = testing.allocator;
    var bank = try Bank.init(alloc, 4, 1 << 20);
    defer bank.deinit();
    _ = try bank.getOrLoad(FakeBackend.device(), "gone:40");
    try testing.expectEqual(@as(usize, 160), bank.bytesUsed());
    try testing.expect(bank.remove("gone:40"));
    try testing.expectEqual(@as(usize, 0), bank.bytesUsed());
    try testing.expect(!bank.remove("gone:40")); // already gone
}

test "a stream keeps only a window, and the window follows the cursor" {
    const alloc = testing.allocator;
    var bank = try Bank.init(alloc, 4, 1 << 20);
    defer bank.deinit();

    // A 1000-frame sound streamed through an 8-frame window: 32 bytes resident,
    // not 4000. The whole point of streaming, as a number the test can fail on.
    const slot = try bank.openStream(FakeBackend.device(), "song:1000", 8);
    try testing.expect(bank.isStream(slot));
    try testing.expectEqual(@as(usize, 32), bank.bytesUsed());

    const p0 = bank.peek(slot).?;
    try testing.expect(p0.streaming);
    try testing.expectEqual(@as(u32, 1000), p0.frames); // the total is still known
    try testing.expectEqual(@as(u32, 0), p0.base_frame);
    try testing.expectEqual(@as(u32, 8), p0.windowFrames());
    // The window holds absolute frames 0..8 (frame n reads as n % 251).
    try testing.expectEqual(@as(f32, 0), p0.samples[0]);
    try testing.expectEqual(@as(f32, 7), p0.samples[7]);

    // The device has read up to frame 4; the main thread slides the window.
    bank.noteStreamCursor(slot, 4);
    bank.refillSlot(slot);
    const p1 = bank.peek(slot).?;
    try testing.expectEqual(@as(u32, 4), p1.base_frame);
    try testing.expectEqual(@as(u32, 8), p1.windowFrames());
    try testing.expectEqual(@as(f32, 4), p1.samples[0]); // absolute frame 4
    try testing.expectEqual(@as(f32, 11), p1.samples[7]); // absolute frame 11
    // Still bounded: the window did not grow with the sound.
    try testing.expectEqual(@as(usize, 32), bank.bytesUsed());

    // A loop wrapped (the device seeked back): the window re-anchors at 0.
    bank.noteStreamCursor(slot, 0);
    bank.refillSlot(slot);
    try testing.expectEqual(@as(u32, 0), bank.peek(slot).?.base_frame);
    try testing.expectEqual(@as(f32, 0), bank.peek(slot).?.samples[0]);
}

test "a stream ends at the real end, and freeing it releases the ring" {
    const alloc = testing.allocator;
    var bank = try Bank.init(alloc, 4, 1 << 20);
    defer bank.deinit();

    // 12 frames through a 8-frame window: the read-ahead hits end-of-source.
    const slot = try bank.openStream(FakeBackend.device(), "short:12", 8);
    try testing.expectEqual(@as(u32, 8), bank.peek(slot).?.windowFrames());

    bank.noteStreamCursor(slot, 8);
    bank.refillSlot(slot);
    // Only 4 frames were left, so the window is short but the total is exact.
    try testing.expectEqual(@as(u32, 4), bank.peek(slot).?.windowFrames());
    try testing.expectEqual(@as(u32, 12), bank.peek(slot).?.frames);
    try testing.expectEqual(@as(u32, 8), bank.peek(slot).?.base_frame);

    // Freeing the slot releases the ring (and the path) — `testing.allocator`
    // fails the test if it does not.
    try testing.expect(bank.remove("short:12"));
    try testing.expectEqual(@as(usize, 0), bank.bytesUsed());
}

test "an out-of-range slot reads as null rather than indexing past the table" {
    const alloc = testing.allocator;
    var bank = try Bank.init(alloc, 2, 1 << 20);
    defer bank.deinit();
    try testing.expect(bank.get(9999) == null);
    try testing.expect(bank.get(0) == null); // free slot
}
