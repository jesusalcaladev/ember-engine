//! The command ring: how the main thread talks to the device thread (M8).
//!
//! ## Why a ring and not a call
//!
//! `audio.play` is called from Lua on the main thread. The sound is actually
//! started on the device thread, inside a callback that spec §3.7 and §10 forbid
//! from taking long-held locks. So the two threads never touch the same mutable
//! state: the main thread WRITES commands into this ring, the device thread
//! READS them out. One writer, one reader, no lock on either side.
//!
//! ## Why it is fixed-capacity, and what happens when it fills
//!
//! Growing the ring would allocate, and this is written from the frame loop
//! (spec §3.1). So the capacity is reserved at load time and a full ring DROPS
//! the new command while counting it — exactly the rule `ecs/signals.zig`
//! states: "a queue full is a budget, not a spill". Dropping is visible in
//! `Stats.commands_dropped` rather than silent, because a sound that quietly
//! fails to play is indistinguishable from a sound that was never requested.
//!
//! ## The atomics, and why they are the only ones
//!
//! `head` is written by the producer alone, `tail` by the consumer alone. Each
//! side reads the other's index with acquire and publishes its own with release,
//! which is what makes the payload visible rather than merely eventually
//! correct. No CAS, no contention: a lock-free ring that never spins waiting,
//! because the audio thread must never wait on the game.

const std = @import("std");

/// Default capacity. 4096 commands is ~68 seconds of 60 plays per frame, which
/// is far past anything a frame can legitimately ask for; the point is that
/// overflow is a bug to be reported, not a condition to design around.
pub const default_capacity: usize = 4096;

/// Imported here rather than reached through the module root so the ring is
/// self-contained and compiles as its own translation unit in tests.
const VoiceId = @import("audio.zig").VoiceId;

/// Everything the main thread can ask the mixer to do.
///
/// A tagged union rather than a struct with a `kind` field: the tag is checked
/// by the compiler, so a new command that forgets a case is a compile error at
/// the drain site instead of a sound that silently does nothing.
pub const Command = union(enum) {
    /// Start a sound. Carries a bank slot rather than a path, because the file
    /// was decoded at load time and the device thread must not touch a path.
    play: Play,
    /// Stop one voice.
    stop: Stop,
    /// Change one playing voice's volume.
    set_volume: SetVolume,
    /// Change one playing voice's pitch (the resample ratio).
    set_pitch: SetPitch,
    /// Change a bus's volume.
    set_bus_volume: SetBusVolume,
    /// Change the master volume.
    set_master_volume: f32,
    /// Move the listener. This is what makes a sound pan as the camera moves.
    set_listener: Listener,
    pause_bus: u8,
    resume_bus: u8,
    /// Stop everything. Used by Play/Stop in the editor, where the snapshot has
    /// to be exact.
    stop_all,

    pub const Play = struct {
        /// The pool slot the MAIN thread already reserved for this sound.
        ///
        /// The main thread reserves it because `audio.play` has to return a
        /// handle synchronously, and the device thread is what fills the slot
        /// in. Dividing it this way keeps each field single-writer (the pool's
        /// structure is the main thread's, a live voice's runtime state is the
        /// device thread's) instead of having both threads write the same
        /// struct.
        voice: VoiceId = VoiceId.none,
        bank_slot: u16,
        bus: u8 = 0,
        volume: f32 = 1,
        pitch: f32 = 1,
        /// World position. Ignored when `max_distance` is 0 (a global sound such
        /// as music, which is never panned or attenuated).
        x: f32 = 0,
        y: f32 = 0,
        /// 0 = global. Otherwise the distance at which the sound reaches zero.
        max_distance: f32 = 0,
        /// How far an offset from the listener reaches full hard-pan.
        spread: f32 = 400,
        loop: bool = false,
        /// Which voice to steal first when the pool is full. Higher survives.
        priority: u8 = 0,
        /// The engine tick this was issued at (spec §6: gameplay time, never
        /// wall-clock). Carried so an event that comes back out of the audio
        /// thread can be attributed to the tick that caused it.
        tick: u64 = 0,
    };

    pub const Stop = struct {
        voice: VoiceId,
    };

    pub const SetVolume = struct {
        voice: VoiceId,
        volume: f32,
    };

    pub const SetPitch = struct {
        voice: VoiceId,
        pitch: f32,
    };

    pub const SetBusVolume = struct {
        bus: u8,
        volume: f32,
    };

    pub const Listener = struct {
        x: f32,
        y: f32,
        /// Which way the ears face, in radians (0 = +x). Optional so a caller
        /// that only moves the listener does not have to think about turning it.
        rot: f32 = 0,
    };
};

pub const CommandRing = struct {
    entries: []Command,
    /// Written by the producer (main thread) only.
    head: usize = 0,
    /// Written by the consumer (device thread) only.
    tail: usize = 0,
    /// Capacity minus one; the mask that makes indexing a wrap.
    mask: usize,
    /// Producer-side drop count. Read by the consumer for `Stats`, so it is
    /// relaxed rather than exact: a dropped command is a bug to notice, and the
    /// count being off by one in a race is not worth a fence to prevent.
    dropped: std.atomic.Value(u64) = std.atomic.Value(u64).init(0),

    const Self = @This();

    /// `capacity` is rounded up to a power of two so the wrap is a mask instead
    /// of a division. A non-power-of-two request silently getting a bigger ring
    /// is fine; a request that gets a ring too small is not.
    pub fn init(allocator: std.mem.Allocator, capacity: usize) !Self {
        var cap: usize = 1;
        while (cap < capacity) cap <<= 1;
        return .{
            .entries = try allocator.alloc(Command, cap),
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

    /// How many commands are queued right now.
    pub fn queued(self: *const Self) usize {
        const h = @atomicLoad(usize, &self.head, .acquire);
        const t = @atomicLoad(usize, &self.tail, .acquire);
        return h -% t;
    }

    // ── Producer side (main thread) ──────────────────────────────────────────

    /// Queues one command. Returns false when the ring is full, in which case
    /// the command was dropped and counted — never blocking, never allocating.
    pub fn push(self: *Self, cmd: Command) bool {
        const h = self.head;
        const t = @atomicLoad(usize, &self.tail, .acquire);
        // `mask + 1` slots exist and one is deliberately left empty, so a FULL
        // ring is distinguishable from an EMPTY one (both would otherwise read
        // head == tail) without carrying a separate count. Rejecting at `mask`
        // rather than `mask + 1` is what keeps that one free; rejecting at
        // `mask + 1` fills every slot and makes the two states identical.
        if (h -% t >= self.mask) {
            _ = self.dropped.fetchAdd(1, .monotonic);
            return false;
        }
        self.entries[h & self.mask] = cmd;
        // Release: the payload write above must be visible before the head
        // advance that makes the consumer look at it.
        @atomicStore(usize, &self.head, h +% 1, .release);
        return true;
    }

    // ── Consumer side (device thread) ────────────────────────────────────────

    /// Takes one command, or null when the ring is empty. Never waits.
    pub fn pop(self: *Self) ?Command {
        const t = self.tail;
        const h = @atomicLoad(usize, &self.head, .acquire);
        if (t == h) return null;
        const cmd = self.entries[t & self.mask];
        @atomicStore(usize, &self.tail, t +% 1, .release);
        return cmd;
    }

    pub fn takeDropped(self: *Self) u64 {
        return self.dropped.swap(0, .monotonic);
    }
};

// ── Tests ────────────────────────────────────────────────────────────────────

const testing = std.testing;

test "a round trip delivers what was pushed, in order" {
    var ring = try CommandRing.init(testing.allocator, 8);
    defer ring.deinit(testing.allocator);

    try testing.expect(ring.push(.stop_all));
    try testing.expect(ring.push(.{ .set_master_volume = 0.5 }));
    try testing.expectEqual(@as(usize, 2), ring.queued());

    try testing.expect(ring.pop().? == .stop_all);
    const second = ring.pop().?;
    try testing.expectApproxEqAbs(@as(f32, 0.5), second.set_master_volume, 1e-6);
    try testing.expect(ring.pop() == null);
}

test "capacity is rounded up to a power of two" {
    var ring = try CommandRing.init(testing.allocator, 100);
    defer ring.deinit(testing.allocator);
    // 100 becomes 128: a request is never silently given a ring too small.
    try testing.expectEqual(@as(usize, 128), ring.slotCount());
}

test "a full ring drops and counts instead of blocking or growing" {
    var ring = try CommandRing.init(testing.allocator, 4);
    defer ring.deinit(testing.allocator);

    // capacity 4, one slot reserved: 3 fit.
    var i: usize = 0;
    while (i < 3) : (i += 1) try testing.expect(ring.push(.stop_all));
    try testing.expect(!ring.push(.stop_all)); // full: dropped, not blocked
    try testing.expectEqual(@as(u64, 1), ring.takeDropped());
    // Taking the count clears it, so it is a delta and not a lifetime total
    // that would double-count on the next read.
    try testing.expectEqual(@as(u64, 0), ring.takeDropped());
}

test "draining empties the ring and leaves it reusable" {
    var ring = try CommandRing.init(testing.allocator, 4);
    defer ring.deinit(testing.allocator);

    var i: usize = 0;
    while (i < 3) : (i += 1) _ = ring.push(.stop_all);
    i = 0;
    while (i < 3) : (i += 1) try testing.expect(ring.pop() != null);
    try testing.expectEqual(@as(usize, 0), ring.queued());
    // Reusable after a full drain: the wrap must not strand the ring.
    try testing.expect(ring.push(.stop_all));
}

test "the ring wraps many times without losing a command" {
    var ring = try CommandRing.init(testing.allocator, 4);
    defer ring.deinit(testing.allocator);

    // Push and pop interleaved far past the capacity: the indices are wrapping
    // usize arithmetic, and an off-by-one in the mask shows up here as a
    // duplicate or a lost command rather than as anything obvious.
    var round: usize = 0;
    while (round < 200) : (round += 1) {
        try testing.expect(ring.push(.{ .set_master_volume = @floatFromInt(round) }));
        const got = ring.pop().?;
        try testing.expectApproxEqAbs(@as(f32, @floatFromInt(round)), got.set_master_volume, 1e-6);
    }
}

test "a Command is small enough that a ring of them is a modest reservation" {
    // The ring is reserved at load time out of the same budget as everything
    // else; a Command that quietly grew would grow that reservation with it.
    // 64 bytes keeps 4096 entries at 256 KB.
    try testing.expect(@sizeOf(Command) <= 64);
}

