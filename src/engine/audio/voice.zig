//! The voice pool: fixed slots, generation-checked handles, and stealing (M8).
//!
//! ## Why a pool and not an allocation
//!
//! A voice is created from the device thread, inside a callback that must not
//! allocate (spec §3.1 and §10). So the slots exist from load time, and
//! "starting a sound" is writing into a free slot — never a malloc.
//!
//! ## Why stealing is not optional
//!
//! The M8 criterion is 64 simultaneous emitters. Without a policy, the 65th
//! sound simply does not play, which from the outside is indistinguishable from
//! the request having been lost or the engine having hung. So the pool has a
//! policy, and the policy is: **at equal priority, the quietest voice dies.**
//!
//! Quietest rather than oldest, because a long ambient loop sitting near the
//! listener is loud, and an explosion elsewhere is quieter but matters more. An
//! oldest-first policy would let a footstep kill a gunshot. Priority breaks the
//! tie explicitly when the caller has an opinion, which is what it is for.
//!
//! ## Why the handle carries a generation
//!
//! The same reason `ecs.Entity` and `physics.BodyId` do: a voice id held by Lua
//! or by a component across a frame must not silently start addressing whoever
//! moved into that slot. `stop(voice)` on a stale handle is a no-op, which is
//! the correct behaviour — the sound it named is genuinely gone.

const std = @import("std");
const audio = @import("audio.zig");

const VoiceId = audio.VoiceId;

/// One playing sound. Plain data, and small enough that a pool of 256 of them is
/// a few kilobytes reserved at load time.
pub const Voice = struct {
    active: bool = false,
    /// Reserved by the MAIN thread for a sound the device thread has not filled
    /// in yet. It exists because `audio.play` has to hand back a handle before
    /// the buffer runs, and without it the next `allocate` would hand out the
    /// same free-looking slot again — every `play` in a frame would land on one
    /// voice. `allocate` skips reserved slots; the device clears it when it
    /// activates the voice.
    reserved: bool = false,
    /// Which decoded sound this is playing. An index into the bank.
    bank_slot: u16 = 0,
    /// Read position in SOURCE frames, fractional. Advances by the resample
    /// step each output frame, which is what makes pitch and rate correct.
    cursor: f32 = 0,
    bus: u8 = 0,
    base_volume: f32 = 1,
    /// World position. Used for panning and attenuation.
    x: f32 = 0,
    y: f32 = 0,
    /// 0 = global: never attenuated, never panned.
    max_distance: f32 = 0,
    /// How far an offset reaches full hard-pan.
    spread: f32 = 400,
    pitch: f32 = 1,
    loop: bool = false,
    /// Higher survives a steal.
    priority: u8 = 0,
    /// The engine tick this was issued at (spec §6). Carried on the event that
    /// comes back out so a finished sound can be attributed to its tick.
    tick: u64 = 0,
    /// Current computed level, after attenuation and bus gain. This is what the
    /// steal policy reads to decide what is quietest.
    level: f32 = 0,

    pub fn isGlobal(self: Voice) bool {
        return self.max_distance <= 0;
    }
};

/// What happened to a voice during one render, for the caller to report.
pub const Finished = struct {
    voice: VoiceId,
    bank_slot: u16,
    tick: u64,
};

pub const VoicePool = struct {
    voices: []Voice,
    /// Bumped on every slot reuse, so a handle from a previous life is stale.
    generations: []u32,
    /// Highest simultaneous active voices since boot. The M8 criterion (64) is
    /// about this, not about the instantaneous count.
    peak_active: u32 = 0,
    /// Slots taken by stealing rather than by being free. Non-zero means the
    /// scene asked for more voices than it reserved, which is a tuning number
    /// worth seeing rather than a silent truncation.
    steals: u64 = 0,

    const Self = @This();

    pub fn init(allocator: std.mem.Allocator, count: usize) !Self {
        // `alloc` returns UNINITIALIZED memory: a `Voice`'s field defaults are
        // for literals, not for `alloc`. Without this loop every slot starts
        // with garbage `active`/`reserved`/`priority`, so the first free-slot
        // pass never matches and every `play` takes the steal path — which is
        // invisible until a scene asks for more than one voice at a time.
        const voices = try allocator.alloc(Voice, count);
        for (voices) |*v| v.* = .{};
        const generations = try allocator.alloc(u32, count);
        @memset(generations, 0);
        return .{ .voices = voices, .generations = generations };
    }

    /// A fresh pool has every slot free. Pinned by a test because the failure
    /// mode above is silent: the pool still answers, just with the wrong slot.
    pub fn freeCount(self: *const Self) usize {
        var n: usize = 0;
        for (self.voices) |v| {
            if (!v.active and !v.reserved) n += 1;
        }
        return n;
    }

    pub fn deinit(self: *Self, allocator: std.mem.Allocator) void {
        allocator.free(self.voices);
        allocator.free(self.generations);
        self.* = undefined;
    }

    pub fn slotCount(self: *const Self) usize {
        return self.voices.len;
    }

    pub fn activeCount(self: *const Self) u32 {
        var n: u32 = 0;
        for (self.voices) |v| {
            if (v.active) n += 1;
        }
        return n;
    }

    /// The handle for a slot, valid exactly while that generation lives.
    pub fn handleAt(self: *const Self, index: usize) VoiceId {
        return .{ .index = @intCast(index), .generation = self.generations[index] };
    }

    /// Resolves a handle to a slot, or null when the handle is stale.
    ///
    /// The generation check is the whole point: a slot recycled since the handle
    /// was issued answers with a different generation, and a `stop` against a
    /// finished sound must do nothing rather than stop whatever is playing now.
    pub fn resolve(self: *Self, id: VoiceId) ?*Voice {
        if (id.isNone()) return null;
        if (id.index >= self.voices.len) return null;
        if (self.generations[id.index] != id.generation) return null;
        const v = &self.voices[id.index];
        return if (v.active) v else null;
    }

    /// Takes a slot for a new voice: a free one if there is one, otherwise the
    /// best victim to steal. Never returns null — a pool always has an answer,
    /// and the answer may be "something else stops".
    pub fn allocate(self: *Self) usize {
        // First pass: a free slot, so the common case never consults the policy.
        // A slot that is reserved-but-not-yet-started is NOT free.
        for (self.voices, 0..) |*v, i| {
            if (!v.active and !v.reserved) {
                v.* = .{};
                v.reserved = true;
                self.generations[i] +%= 1;
                return i;
            }
        }

        // Full: pick the victim. Lowest priority first, then quietest, then
        // lowest slot so the choice is deterministic when all else ties.
        var victim: usize = 0;
        var best = StealKey.worst();
        for (self.voices, 0..) |*v, i| {
            const key = StealKey{ .priority = v.priority, .level = v.level, .index = @intCast(i) };
            if (key.betterVictimThan(best)) {
                best = key;
                victim = i;
            }
        }
        self.voices[victim] = .{};
        self.voices[victim].reserved = true;
        self.generations[victim] +%= 1;
        self.steals += 1;
        return victim;
    }

    /// Called once per render, after the mixer has computed each voice's level,
    /// so the steal policy has something current to read.
    pub fn updatePeak(self: *Self) void {
        var n: u32 = 0;
        for (self.voices) |v| {
            if (v.active) n += 1;
        }
        if (n > self.peak_active) self.peak_active = n;
    }

    pub fn stopAll(self: *Self) void {
        for (self.voices) |*v| {
            v.active = false;
            v.reserved = false;
        }
    }

    /// Orders candidates for stealing. `betterVictimThan` is true when `self`
    /// should be stolen in preference to `other`.
    const StealKey = struct {
        priority: u8,
        level: f32,
        index: u32,

        /// A key no real voice can beat: the highest priority and the loudest
        /// possible level, so the first real voice always displaces it.
        fn worst() StealKey {
            return .{ .priority = 255, .level = std.math.floatMax(f32), .index = std.math.maxInt(u32) };
        }

        fn betterVictimThan(self: StealKey, other: StealKey) bool {
            if (self.priority != other.priority) return self.priority < other.priority;
            // Same priority: the quieter one goes. An epsilon so two voices at
            // exactly the same level fall through to the index rather than being
            // decided by float noise.
            if (@abs(self.level - other.level) > 0.0001) return self.level < other.level;
            return self.index < other.index;
        }
    };
};

// ── Tests ────────────────────────────────────────────────────────────────────

const testing = std.testing;

test "allocate hands out free slots and never returns null" {
    var pool = try VoicePool.init(testing.allocator, 4);
    defer pool.deinit(testing.allocator);

    var seen: [4]usize = undefined;
    var i: usize = 0;
    while (i < 4) : (i += 1) {
        const slot = pool.allocate();
        pool.voices[slot].active = true;
        seen[i] = slot;
    }
    // Four distinct slots: the first pass found each one free.
    try testing.expectEqual(@as(usize, 4), pool.activeCount());
    try testing.expect(seen[0] != seen[1] and seen[1] != seen[2] and seen[2] != seen[3]);
}

test "a full pool steals the quietest voice, and counts it" {
    var pool = try VoicePool.init(testing.allocator, 3);
    defer pool.deinit(testing.allocator);

    var i: usize = 0;
    while (i < 3) : (i += 1) {
        const slot = pool.allocate();
        pool.voices[slot].active = true;
        // Slot i is at level 0.1 * (i + 1): slot 0 is the quietest.
        pool.voices[slot].level = 0.1 * @as(f32, @floatFromInt(i + 1));
    }
    const victim = pool.allocate();
    // The quietest (slot 0, level 0.1) is the one that stopped.
    try testing.expectEqual(@as(usize, 0), victim);
    try testing.expectEqual(@as(u64, 1), pool.steals);
    // And the pool did not grow: it is still three voices.
    try testing.expectEqual(@as(usize, 3), pool.slotCount());
}

test "priority beats loudness: a quiet explosion outlives a loud loop" {
    var pool = try VoicePool.init(testing.allocator, 2);
    defer pool.deinit(testing.allocator);

    // A loud ambient loop at priority 0.
    const a = pool.allocate();
    pool.voices[a].active = true;
    pool.voices[a].level = 1.0;
    pool.voices[a].priority = 0;
    // A quiet but important one-shot at priority 9.
    const b = pool.allocate();
    pool.voices[b].active = true;
    pool.voices[b].level = 0.01;
    pool.voices[b].priority = 9;

    const victim = pool.allocate();
    // The loud loop dies, not the quiet important sound. An oldest-first policy
    // would have made the opposite choice.
    try testing.expectEqual(a, victim);
}

test "a stale handle stops resolving after its slot is reused" {
    var pool = try VoicePool.init(testing.allocator, 2);
    defer pool.deinit(testing.allocator);

    const slot = pool.allocate();
    const first = pool.handleAt(slot);
    // The device activating a reserved voice is what clears `reserved`.
    pool.voices[slot].active = true;
    pool.voices[slot].reserved = false;
    try testing.expect(pool.resolve(first) != null);

    // The voice ends and its slot is handed to somebody else.
    pool.voices[slot].active = false;
    const second_slot = pool.allocate();
    // The new voice must be activated for the handle to resolve.
    pool.voices[second_slot].active = true;
    const second = pool.handleAt(second_slot);
    try testing.expect(second.generation != first.generation);
    // The old handle no longer addresses anything: a `stop` against a finished
    // sound must not stop the sound that took its place.
    try testing.expect(pool.resolve(first) == null);
    try testing.expect(pool.resolve(second) != null);
}

test "an out-of-range or empty handle resolves to nothing rather than crashing" {
    var pool = try VoicePool.init(testing.allocator, 2);
    defer pool.deinit(testing.allocator);

    try testing.expect(pool.resolve(VoiceId.none) == null);
    try testing.expect(pool.resolve(.{ .index = 9999, .generation = 0 }) == null);
}

test "a fresh pool starts with every slot free and no steals" {
    var pool = try VoicePool.init(testing.allocator, 8);
    defer pool.deinit(testing.allocator);
    try testing.expectEqual(@as(usize, 8), pool.freeCount());
    // No garbage: reserving eight slots must not steal once.
    var i: usize = 0;
    while (i < 8) : (i += 1) _ = pool.allocate();
    try testing.expectEqual(@as(u64, 0), pool.steals);
    try testing.expectEqual(@as(usize, 0), pool.freeCount());
}

test "the peak is the highest simultaneous count, not the current one" {
    var pool = try VoicePool.init(testing.allocator, 8);
    defer pool.deinit(testing.allocator);

    var i: usize = 0;
    while (i < 5) : (i += 1) {
        const slot = pool.allocate();
        pool.voices[slot].active = true;
    }
    pool.updatePeak();
    try testing.expectEqual(@as(u32, 5), pool.peak_active);

    // Voices end; the peak remembers what was reached, which is the number the
    // M8 criterion (64) is actually about.
    pool.stopAll();
    pool.updatePeak();
    try testing.expectEqual(@as(u32, 0), pool.activeCount());
    try testing.expectEqual(@as(u32, 5), pool.peak_active);
}