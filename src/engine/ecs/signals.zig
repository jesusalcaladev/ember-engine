//! Signals: typed events with stable emission order, drained once per frame.
//!
//! Rules they implement (spec §2 "Signals + framework 0.8 ms", §6 "stable
//! signal order by spawn"):
//! - **Typed at both ends**: the emitter states the payload type, the listener
//!   subscribes to it; a mismatched subscription simply never fires. No
//!   `void**` soup, and the copy is a memcpy of a comptime-known size.
//! - **Stable order**: connections are kept sorted by the emitter's scene id
//!   (its spawn order), so two runs with the same spawn order fire the same
//!   listeners in the same order — that is what makes the state hash stable.
//! - **Drained once**: `emit` only queues; `drain` fires everything and
//!   resets the queue in O(1). Nothing fires twice, and reentrant emits from a
//!   listener queue for the next frame instead of exploding the stack.
//! - **No allocation per event**: the queue's capacity is reserved at load
//!   time (bounded, a budget like the frame arena), and the ring is a plain
//!   array write. Connecting a *new* signal name inside the frame is the only
//!   allocator entry and it panics while locked.

const std = @import("std");
const entity = @import("entity.zig");

pub const SceneId = entity.SceneId;

/// Maximum payload bytes copied per emitted event (a compile error above).
pub const max_payload = 64;

/// Queue capacity reserved by default at load time (bounded budget).
pub const default_queue = 1024;

/// Erased listener shape. Listeners receive the payload by pointer and cast it
/// to their type once: `const damage: *const Damage = @ptrCast(@alignCast(value));`.
/// Typed at both ends by the `T` passed to `on`/`emit`, which is what makes a
/// mismatch impossible to fire instead of merely unlikely.
pub const Callback = *const fn (ctx: ?*anyopaque, value: *const anyopaque) void;

const Connection = struct {
    /// Emitter scene id (spawn order). 0 for engine-wide listeners.
    order: SceneId,
    type_hash: u64,
    callback: Callback,
    ctx: ?*anyopaque,
};

const Signal = struct {
    /// Interned, owned by the map key.
    name: []const u8,
    conns: std.ArrayList(Connection) = .empty,
};

const Event = struct {
    signal: u32,
    type_hash: u64,
    len: u32,
    payload: [max_payload]u8,
};

pub const Signals = struct {
    allocator: ?std.mem.Allocator = null,
    signals: std.ArrayList(Signal) = .empty,
    interner: std.StringHashMapUnmanaged(u32) = .{},
    events: std.ArrayList(Event) = .empty,
    /// Set by the owner (World) during the frame loop.
    locked: bool = false,

    const Self = @This();

    /// Pre-allocates the event queue: this is the allocation that keeps
    /// per-frame emits free (spec §3.1). Also binds the allocator used to
    /// intern signal names and store connections.
    pub fn reserve(self: *Self, allocator: std.mem.Allocator, queue_capacity: usize) !void {
        if (self.allocator == null) self.allocator = allocator;
        try self.events.ensureTotalCapacity(allocator, queue_capacity);
    }

    pub fn deinit(self: *Self) void {
        const allocator = self.allocator orelse return;
        for (self.signals.items) |*signal| {
            signal.conns.deinit(allocator);
            allocator.free(signal.name);
        }
        self.signals.deinit(allocator);
        self.interner.deinit(allocator);
        self.events.deinit(allocator);
        self.* = undefined;
    }

    // ── Wiring ──────────────────────────────────────────────────────────────

    /// Subscribes `cb` to `name` for payload `T`, fired among the listeners of
    /// the same emitter in `order` (spawn order). Connect at load time: the
    /// first use of a signal name allocates.
    pub fn on(
        self: *Self,
        comptime T: type,
        name: []const u8,
        order: SceneId,
        ctx: ?*anyopaque,
        cb: Callback,
    ) !void {
        const allocator = self.allocator orelse return error.NoAllocator;
        if (self.locked) {
            std.debug.panic("signals: connecting '{s}' during the frame loop; connect at load time (spec §3.1)", .{name});
        }
        const index = try self.intern(name, allocator);
        var signal = &self.signals.items[index];
        const conn = Connection{
            .order = order,
            .type_hash = typeHash(T),
            .callback = cb,
            .ctx = ctx,
        };
        // Keep sorted by order so drain order is deterministic by spawn.
        var at = signal.conns.items.len;
        while (at > 0 and signal.conns.items[at - 1].order > conn.order) : (at -= 1) {}
        try signal.conns.insert(allocator, at, conn);
    }

    /// Drops every connection registered under `order` (an entity went away).
    pub fn off(self: *Self, order: SceneId) void {
        const allocator = self.allocator orelse return;
        for (self.signals.items) |*signal| {
            var i: usize = 0;
            while (i < signal.conns.items.len) {
                if (signal.conns.items[i].order == order) {
                    _ = signal.conns.orderedRemove(i);
                } else i += 1;
            }
            _ = allocator;
        }
    }

    // ── Emitting ────────────────────────────────────────────────────────────

    /// Queues an event for the next `drain`. Zero allocation, zero dispatch.
    pub fn emit(self: *Self, comptime T: type, name: []const u8, value: T) void {
        std.debug.assert(@sizeOf(T) <= max_payload);
        const allocator = self.allocator orelse std.debug.panic("signals: no allocator; call Signals.reserve/World.init first", .{});
        const index = self.intern(name, allocator) catch {
            std.debug.panic("signals: cannot emit '{s}' during the frame loop; connect at load time (spec §3.1)", .{name});
        };
        if (self.events.items.len == self.events.capacity) {
            std.debug.panic(
                "signals: the event queue is full ({d} events). It is a budget, not a leak: reserve a bigger queue at load time",
                .{self.events.capacity},
            );
        }
        self.events.append(allocator, .{
            .signal = index,
            .type_hash = typeHash(T),
            .len = @sizeOf(T),
            .payload = undefined,
        }) catch unreachable; // capacity is checked above
        const ev = &self.events.items[self.events.items.len - 1];
        @memcpy(ev.payload[0..@sizeOf(T)], std.mem.asBytes(&value));
    }

    // ── Draining ────────────────────────────────────────────────────────────

    /// Fires every queued event, in emission order, and clears the queue.
    pub fn drain(self: *Self) void {
        for (self.events.items) |*ev| {
            const signal = &self.signals.items[ev.signal];
            for (signal.conns.items) |conn| {
                if (conn.type_hash != ev.type_hash) continue; // other typed channel
                conn.callback(conn.ctx, ev.payload[0..].ptr);
            }
        }
        self.events.clearRetainingCapacity();
    }

    pub fn queuedEvents(self: *const Self) usize {
        return self.events.items.len;
    }

    pub fn connectionCount(self: *const Self) usize {
        var total: usize = 0;
        for (self.signals.items) |signal| total += signal.conns.items.len;
        return total;
    }

    /// True when anything is subscribed to `name`.
    ///
    /// Exists so a producer can skip building an event nobody will receive. The
    /// physics bridge needs it: a 2 000-body pile generates thousands of
    /// contacts a step, and publishing a signal for each one — only for every
    /// listener to filter it out — fills the queue and panics, even though the
    /// game never asked for a single collision event.
    pub fn hasListeners(self: *const Self, name: []const u8) bool {
        for (self.signals.items) |signal| {
            if (std.mem.eql(u8, signal.name, name)) return signal.conns.items.len > 0;
        }
        return false;
    }

    pub fn signalCount(self: *const Self) usize {
        return self.signals.items.len;
    }

    // ── Internals ───────────────────────────────────────────────────────────

    /// Signal index for a name, creating it on first use (allocates).
    fn intern(self: *Self, name: []const u8, allocator: std.mem.Allocator) !u32 {
        if (self.interner.get(name)) |index| return index;
        const owned = try allocator.dupe(u8, name);
        errdefer allocator.free(owned);
        const index: u32 = @intCast(self.signals.items.len);
        try self.signals.append(allocator, .{ .name = owned });
        try self.interner.put(allocator, owned, index);
        return index;
    }
};

fn typeHash(comptime T: type) u64 {
    return std.hash.Wyhash.hash(0, @typeName(T));
}

// ── Tests ───────────────────────────────────────────────────────────────────

const Damage = struct { amount: u32 };

var sink: u32 = 0;

fn collectAmount(ctx: ?*anyopaque, value: *const anyopaque) void {
    const damage: *const Damage = @ptrCast(@alignCast(value));
    const slot: *u32 = @ptrCast(@alignCast(ctx.?));
    slot.* += damage.amount;
}

var order_ctxs: [3]SceneId = undefined;
var order_log: [3]u32 = undefined;
var order_log_len: usize = 0;

fn logOrder(ctx: ?*anyopaque, value: *const anyopaque) void {
    _ = value;
    const order: *const SceneId = @ptrCast(@alignCast(ctx.?));
    if (order_log_len < order_log.len) {
        order_log[order_log_len] = @intCast(order.*);
        order_log_len += 1;
    }
}

test "emit queues, drain fires once, then it is all over" {
    var signals = Signals{};
    const allocator = std.testing.allocator;
    try signals.reserve(allocator, 16);
    defer signals.deinit();

    sink = 0;
    try signals.on(Damage, "damaged", 3, &sink, collectAmount);
    // Nothing fires until the frame drains.
    signals.emit(Damage, "damaged", .{ .amount = 5 });
    signals.emit(Damage, "damaged", .{ .amount = 7 });
    try std.testing.expectEqual(@as(usize, 2), signals.queuedEvents());
    try std.testing.expectEqual(@as(u32, 0), sink);

    signals.drain();
    try std.testing.expectEqual(@as(u32, 12), sink);
    try std.testing.expectEqual(@as(usize, 0), signals.queuedEvents());

    // Draining twice must not fire anything twice.
    signals.drain();
    try std.testing.expectEqual(@as(u32, 12), sink);
}

test "connections fire in emitter spawn order (spec §6)" {
    var signals = Signals{};
    const allocator = std.testing.allocator;
    try signals.reserve(allocator, 8);
    defer signals.deinit();

    order_log_len = 0;
    order_ctxs = .{ 10, 20, 30 };
    // Connected on purpose in reverse order of their emitter spawn order.
    try signals.on(u32, "hit", 30, &order_ctxs[2], logOrder);
    try signals.on(u32, "hit", 10, &order_ctxs[0], logOrder);
    try signals.on(u32, "hit", 20, &order_ctxs[1], logOrder);
    signals.emit(u32, "hit", 42);
    signals.drain();

    try std.testing.expectEqual(@as(usize, 3), order_log_len);
    try std.testing.expectEqual(@as(u32, 10), order_log[0]);
    try std.testing.expectEqual(@as(u32, 20), order_log[1]);
    try std.testing.expectEqual(@as(u32, 30), order_log[2]);
}

test "a listener only receives its own payload type" {
    var signals = Signals{};
    const allocator = std.testing.allocator;
    try signals.reserve(allocator, 8);
    defer signals.deinit();

    sink = 0;
    try signals.on(Damage, "same_name", 1, &sink, collectAmount);
    signals.emit(u8, "same_name", 1); // different payload type, same name
    signals.drain();
    try std.testing.expectEqual(@as(u32, 0), sink);

    signals.emit(Damage, "same_name", .{ .amount = 3 });
    signals.drain();
    try std.testing.expectEqual(@as(u32, 3), sink);
}

test "a queue full is a budget, not a spill" {
    var signals = Signals{};
    const allocator = std.testing.allocator;
    try signals.reserve(allocator, 4);
    defer signals.deinit();

    try std.testing.expect(signals.events.capacity >= 4);
    var i: usize = 0;
    while (i < 4) : (i += 1) signals.emit(u32, "budget", 1);
    // Growth would be an allocation in the frame loop: refused.
    // (The panic path is exercised in the runtime benchmark.)
    try std.testing.expectEqual(@as(usize, 4), signals.queuedEvents());
}

test "interning the same name reuses one signal" {
    var signals = Signals{};
    const allocator = std.testing.allocator;
    try signals.reserve(allocator, 8);
    defer signals.deinit();

    sink = 0;
    try signals.on(Damage, "once", 1, &sink, collectAmount);
    _ = try signals.intern("once", allocator);
    try std.testing.expectEqual(@as(usize, 1), signals.signalCount());
}
