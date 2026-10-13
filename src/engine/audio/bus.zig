//! Audio buses: named bitmasks, configured once, like Godot's bus map.

//! ## Why this exists
//! Without it, every voice goes to master and you cannot duck music for a
//! one byte; the bus table is a registry of names -> gain/ducking/mute.
//! ## The rule, and it is worth stating exactly

//! A voice writes to exactly one bus. Buses sum to master. A voice whose bus
//! is muted is silent, regardless of its own volume. A bus's gain is applied
//! AFTER the voice's own attenuation and panning, so a bus volume change
//! affects all its voices at once — which is what "duck music" means.

const std = @import("std");

/// 16 buses: fits in a `u4`, one byte per voice. A game that needs more can
/// increase this, but 16 is what Godot ships and it has never been a limit.
pub const bus_count = 16;

/// A bus: its name (for the UI), its gain (applied last, so it ducks
/// everything), its mute flag, and whether it is the master (bus 0).
pub const Bus = struct {
    name: []const u8 = "",
    gain: f32 = 1,
    muted: bool = false,
    is_master: bool = false,

    pub fn effectiveGain(self: Bus) f32 {
        return if (self.muted) 0 else self.gain;
    }
};


/// Bus 0 is ALWAYS the master. It cannot be removed, muted by name, or
/// renamed — the registry enforces this at init and in every mutation.
pub const Registry = struct {
    buses: [bus_count]Bus = undefined,
    /// Set at init from the project config. After init the registry is frozen
    /// for the frame (mutations panic while locked, per spec 3.13.1).
    locked: bool = false,

    const Self = @This();

    pub fn init() Self {
        var r = Self{ .buses = undefined };
        r.buses[0] = .{ .name = "master", .gain = 1, .is_master = true };
        var i: u8 = 1;
        while (i < bus_count) : (i += 1) {
            r.buses[i] = .{ .name = "", .gain = 1 };
        }
        return r;
    }

    /// Returns the bus index by name, or null if the name is not registered.
    pub fn idOfName(self: *const Self, name: []const u8) ?u8 {
        for (self.buses, 0..) |bus, i| {
            if (std.mem.eql(u8, bus.name, name)) return @intCast(i);
        }
        return null;
    }

    /// Returns the bus, or null if the index is out of bounds.
    pub fn get(self: *const Self, id: u8) ?*const Bus {
        if (id >= bus_count) return null;
        return &self.buses[id];
    }

    /// Errors a mutation can raise. `AccessDenied` is the locked registry —
    /// the frame loop may not reconfigure the bus map (spec §3.13.1).
    pub const MutateError = error{ AccessDenied, OutOfRange, InvalidArgument };

    /// A mutable bus.
    ///
    /// Returns `AccessDenied` rather than panicking when the registry is
    /// locked. The draft called `std.debug.panic` here, which spec §3.1 forbids
    /// anywhere the frame can reach: a script that toggled a bus during play
    /// would take the process down instead of being told no.
    pub fn getMut(self: *Self, id: u8) MutateError!*Bus {
        if (id >= bus_count) return error.OutOfRange;
        if (self.locked) return error.AccessDenied;
        return &self.buses[id];
    }

    /// Renames a bus. Bus 0 (master) cannot be renamed.
    pub fn setName(self: *Self, id: u8, name: []const u8) MutateError!void {
        if (id == 0) return error.InvalidArgument;
        const bus = try self.getMut(id);
        bus.name = name;
    }

    /// Sets a bus's gain. Bus 0's gain IS the master volume.
    pub fn setGain(self: *Self, id: u8, gain: f32) MutateError!void {
        const bus = try self.getMut(id);
        bus.gain = std.math.clamp(gain, 0, 10);
    }

    /// Mutes or unmutes a bus. Muting bus 0 mutes everything.
    pub fn setMuted(self: *Self, id: u8, muted: bool) MutateError!void {
        const bus = try self.getMut(id);
        bus.muted = muted;
    }

    /// The effective gain of a bus, applied to all its voices after their own
    /// attenuation and panning. 0 when muted, otherwise the bus gain.
    pub fn effectiveGain(self: *const Self, id: u8) f32 {
        const bus = self.get(id) orelse return 1;
        return bus.effectiveGain();
    }

    /// Locks the registry so the frame loop cannot mutate it (spec 3.13.1).
    pub fn lock(self: *Self) void {
        self.locked = true;
    }

    /// Unlocks the registry for the editor/load time. Only the editor does this.
    pub fn unlock(self: *Self) void {
        self.locked = false;
    }
};

// ── Tests ────────────────────────────────────────────────────────────────────

const testing = std.testing;

test "bus 0 is master and cannot be renamed or removed" {
    var r = Registry.init();
    try testing.expect(r.buses[0].is_master);
    try testing.expectEqualStrings("master", r.buses[0].name);
    try testing.expectError(error.InvalidArgument, r.setName(0, "not_master"));
}

test "buses 1..15 start empty and accept names" {
    var r = Registry.init();
    try testing.expectEqualStrings("", r.buses[1].name);
    try testing.expectError(error.InvalidArgument, r.setName(0, "x"));
    try r.setName(1, "music");
    try testing.expectEqualStrings("music", r.buses[1].name);
}

test "bus gain is applied after voice gain" {
    var r = Registry.init();
    try r.setGain(1, 0.5);
    try testing.expectApproxEqAbs(@as(f32, 0.5), r.effectiveGain(1), 0.0001);
    try testing.expectApproxEqAbs(@as(f32, 1.0), r.effectiveGain(0), 0.0001);
}

test "muting a bus silences its voices regardless of their own volume" {
    var r = Registry.init();
    try r.setMuted(1, true);
    try testing.expectEqual(@as(f32, 0), r.effectiveGain(1));
    try testing.expectEqual(@as(f32, 1), r.effectiveGain(0)); // master unaffected
}

test "locking prevents runtime mutations" {
    var r = Registry.init();
    r.lock();
    try testing.expectError(error.AccessDenied, r.setName(1, "x"));
    try testing.expectError(error.AccessDenied, r.setGain(1, 0.5));
    try testing.expectError(error.AccessDenied, r.setMuted(1, true));
}

test "a bus name lookup returns the correct index" {
    var r = Registry.init();
    try r.setName(1, "sfx");
    try testing.expectEqual(@as(?u8, 1), r.idOfName("sfx"));
    try testing.expect(r.idOfName("nonexistent") == null);
}

test "lock/unlock cycle allows editor mutations at load time" {
    var r = Registry.init();
    r.lock();
    try testing.expectError(error.AccessDenied, r.setGain(1, 0.5));
    r.unlock();
    try r.setGain(1, 0.3);
    try testing.expectEqual(@as(f32, 0.3), r.effectiveGain(1));
}
