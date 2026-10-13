//! The event ring: how the device thread talks BACK to the main thread (M8).
//!
//! The command ring (`command.zig`) is one direction: the main thread asks the
//! mixer to do something. This is the other: the mixer learns a voice ended (it
//! ran off the end of its PCM, or was stolen) and that fact has to reach the
//! main thread, because only the main thread may touch the ECS and the signal
//! bus. The device thread must never call into gameplay.
//!
//! Same discipline as the command ring: fixed capacity reserved at load, one
//! writer and one reader, `head`/`tail` as release/acquire atomics, and a full
//! ring DROPS while counting rather than allocating (spec §3.1). An event that
//! is dropped is one that fired while the main thread was not draining; the
//! counter makes it visible instead of silent.

const std = @import("std");
const audio = @import("audio.zig");

const VoiceId = audio.VoiceId;

pub const default_capacity: usize = 1024;

pub const Kind = enum(u8) {
    /// A voice began playing. Emitted so a listener can attribute a finish.
    started,
    /// A voice stopped: it reached the end of its PCM, or was stolen.
    finished,
};

/// What a `sound_started` / `sound_finished` signal carries, as PLAIN DATA.
///
/// POD by contract: the signal bus copies payload BYTES into a fixed slot
/// (`signals.max_payload` is 64), so a payload holding a slice would hand every
/// listener a pointer to memory it does not own. The path is deliberately NOT
/// here for that reason — a listener that wants it asks the bank, which is the
/// only thing that owns the decoded sound's name. `voice_index` + generation is
/// the handle, so a recycled slot is still distinguishable.
pub const SoundSignal = struct {
    bank_slot: u16 = 0,
    voice_index: u32 = 0,
    voice_generation: u32 = 0,
    /// The tick the sound was ISSUED at (spec §6), the same attribution
    /// `SoundEvent` carries: a sound that ends late is attributed to the frame
    /// that started it, not to whichever buffer happened to end.
    tick: u64 = 0,
};

/// Where drained events go.
///
/// A function-pointer table, the same shape as the physics VTable and the M7
/// lighting hooks, because `audio` may import neither `script` nor `ecs`: the
/// runtime owns the ECS and the Lua VM, and hands the audio system one way to
/// reach them. A single function with a `kind` instead of two callbacks so a new
/// kind (a stolen voice, say) cannot be forgotten at the call site.
pub const Bridge = struct {
    ctx: ?*anyopaque,
    fire: *const fn (ctx: ?*anyopaque, kind: Kind, value: SoundSignal) void,
};

/// The signal name for a kind. Kept here, with the kinds, so the producer and
/// the listener cannot disagree about a string in two files.
pub fn signalName(kind: Kind) []const u8 {
    return switch (kind) {
        .started => "sound_started",
        .finished => "sound_finished",
    };
}

/// One thing that happened on the device thread, on its way to the main thread.
pub const SoundEvent = struct {
    kind: Kind,
    voice: VoiceId,
    bank_slot: u16,
    /// The engine tick the SOUND was issued at (spec §6), carried through the
    /// device thread unchanged so a `sound_finished` is attributed to the tick
    /// that started it rather than to whenever the buffer happened to end.
    tick: u64,
};

pub const EventRing = struct {
    entries: []SoundEvent,
    head: usize = 0,
    tail: usize = 0,
    mask: usize,
    dropped: std.atomic.Value(u64) = std.atomic.Value(u64).init(0),

    const Self = @This();

    pub fn init(allocator: std.mem.Allocator, capacity: usize) !Self {
        var cap: usize = 1;
        while (cap < capacity) cap <<= 1;
        return .{
            .entries = try allocator.alloc(SoundEvent, cap),
            .mask = cap - 1,
        };
    }

    pub fn deinit(self: *Self, allocator: std.mem.Allocator) void {
        allocator.free(self.entries);
        self.* = undefined;
    }

    pub fn slotCount(self: *const Self) usize {
        return self.mask + 1;
    }

    // ── Producer side (device thread) ────────────────────────────────────────

    pub fn push(self: *Self, ev: SoundEvent) bool {
        const h = self.head;
        const t = @atomicLoad(usize, &self.tail, .acquire);
        if (h -% t >= self.mask) {
            _ = self.dropped.fetchAdd(1, .monotonic);
            return false;
        }
        self.entries[h & self.mask] = ev;
        @atomicStore(usize, &self.head, h +% 1, .release);
        return true;
    }

    // ── Consumer side (main thread) ──────────────────────────────────────────

    pub fn pop(self: *Self) ?SoundEvent {
        const t = self.tail;
        const h = @atomicLoad(usize, &self.head, .acquire);
        if (t == h) return null;
        const ev = self.entries[t & self.mask];
        @atomicStore(usize, &self.tail, t +% 1, .release);
        return ev;
    }

    pub fn takeDropped(self: *Self) u64 {
        return self.dropped.swap(0, .monotonic);
    }
};

// ── Tests ────────────────────────────────────────────────────────────────────

const testing = std.testing;

test "events round-trip in order and report emptiness" {
    var ring = try EventRing.init(testing.allocator, 8);
    defer ring.deinit(testing.allocator);

    try testing.expect(ring.pop() == null);
    try testing.expect(ring.push(.{ .kind = .started, .voice = .{ .index = 1, .generation = 0 }, .bank_slot = 3, .tick = 7 }));
    try testing.expect(ring.push(.{ .kind = .finished, .voice = .{ .index = 1, .generation = 0 }, .bank_slot = 3, .tick = 7 }));

    const a = ring.pop().?;
    try testing.expectEqual(Kind.started, a.kind);
    try testing.expectEqual(@as(u16, 3), a.bank_slot);
    try testing.expectEqual(@as(u64, 7), a.tick);
    try testing.expectEqual(Kind.finished, ring.pop().?.kind);
    try testing.expect(ring.pop() == null);
}

test "a signal payload is plain data: no slices, and inside the bus's budget" {
    // The bus copies @sizeOf(T) bytes into a 64-byte slot and hands listeners a
    // pointer to that copy, so ANY slice in this struct would dangle. Asserting
    // the property beats writing it in a comment nobody reads twice.
    try testing.expect(@sizeOf(SoundSignal) <= 64);
    // 8 (tick) + 4 + 4 + 2, padded to the u64's alignment: 24 bytes. Pinned so a
    // field added carelessly is visible as a number, not just as a comment.
    try testing.expectEqual(@as(usize, 24), @sizeOf(SoundSignal));
    inline for (@typeInfo(SoundSignal).@"struct".fields) |f| {
        switch (@typeInfo(f.type)) {
            .int => {},
            .pointer => @compileError("SoundSignal field '" ++ f.name ++ "' is a pointer: a signal payload must be POD"),
            else => @compileError("SoundSignal field '" ++ f.name ++ "' is not a plain scalar"),
        }
    }
    // And the names the producer emits are the names the docs promise.
    try testing.expectEqualStrings("sound_started", signalName(.started));
    try testing.expectEqualStrings("sound_finished", signalName(.finished));
}

test "a full event ring drops and counts rather than blocking" {
    var ring = try EventRing.init(testing.allocator, 4);
    defer ring.deinit(testing.allocator);
    var i: usize = 0;
    while (i < 3) : (i += 1) try testing.expect(ring.push(.{ .kind = .started, .voice = .none, .bank_slot = 0, .tick = 0 }));
    try testing.expect(!ring.push(.{ .kind = .started, .voice = .none, .bank_slot = 0, .tick = 0 }));
    try testing.expectEqual(@as(u64, 1), ring.takeDropped());
    try testing.expectEqual(@as(u64, 0), ring.takeDropped());
}
