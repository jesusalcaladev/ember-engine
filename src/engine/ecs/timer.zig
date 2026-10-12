//! The Timer system (ROADMAP M4.5): advances every `Timer` component on the
//! FIXED step and fires its signals.
//!
//! ## Why the callbacks are signals and not function pointers
//!
//! Registry rule 1 (plain data) forbids pointers in a component, and the world
//! bus is already the engine's event path with the properties gameplay needs:
//! stable order by spawn (spec §6), drained once per frame, and typed payloads
//! for Zig listeners. So a timer declares SIGNAL NAMES; this system both queues
//! them on the bus (for Zig listeners, payload `TimerEvent`) and forwards them
//! through a `SignalBridge` (for Lua `on_signal` handlers, which the bus cannot
//! reach directly because it dispatches to typed Zig callbacks).
//!
//! ## Why the fixed step
//!
//! A timer that gates gameplay must be deterministic (spec §6): the same inputs
//! must fire the same signal at the same tick, or two runs cannot hash equal.
//! `Behaviors.fixedUpdate` calls `tick` before the behaviors run, so a script's
//! `fixed_update` observes exactly the signals its own timers fired this tick.

const std = @import("std");
const world_mod = @import("world.zig");
const components = @import("components.zig");

const World = world_mod.World;

/// Forwards fired signal names to a consumer that the typed bus cannot reach —
/// concretely, `Behaviors.dispatchSignal`, which broadcasts to Lua `on_signal`
/// handlers. Same erased-callback shape as the signal bus itself.
pub const SignalBridge = struct {
    ctx: ?*anyopaque = null,
    dispatch: ?*const fn (ctx: ?*anyopaque, name: []const u8) void = null,

    pub fn fire(self: SignalBridge, name: []const u8) void {
        if (name.len == 0) return;
        if (self.dispatch) |d| d(self.ctx, name);
    }
};

/// Payload queued on the world bus when a timer fires, for typed Zig listeners.
pub const TimerEvent = struct {
    /// The firing actor's handle bits (`Entity.bits`), so a listener can
    /// identify the timer without the payload owning an `Entity` type.
    entity: u64 = 0,
};

/// Caps the cycle catch-up for one tick. A huge `dt` (a breakpoint, a stalled
/// debugger) must not replay a thousand loop cycles in a single frame; the
/// timer simply loses the excess cycles, which is the same trade the physics
/// driver makes (at most one catch-up step per frame).
const max_cycles_per_tick = 16;

/// Advances every `Timer` in the world by `dt` seconds and fires signals.
/// Call once per FIXED tick. Zero allocations.
pub fn tick(world: *World, dt: f32, bridge: SignalBridge) void {
    var slot: usize = 0;
    while (slot < world.slotCount()) : (slot += 1) {
        const e = world.entityAtSlot(slot) orelse continue;
        const t = world.get(e, components.Timer) orelse continue;
        if (t.finished or t.paused) continue;

        t.elapsed += dt;

        // `.during` reports EVERY tick, and it reports it BEFORE the cycle it
        // may also complete. That order is the one the contract states and the
        // one a telegraph bar expects: "this tick happened" is a fact about this
        // tick, and "the cycle ended" is a consequence of it, so a handler that
        // restarts a bar must see the tick first and the completion second.
        if (t.kind == .during) fire(world, e, t.tick_signal.slice(), bridge);

        // Cycle completions. `duration <= 0` is degenerate (fires every tick)
        // and `duration > dt` is the common case; both fall out of this loop.
        var cycles: u32 = 0;
        while (t.duration > 0 and t.elapsed >= t.duration and cycles < max_cycles_per_tick) : (cycles += 1) {
            t.elapsed -= t.duration;
            t.current_loop += 1;
            fire(world, e, t.done_signal.slice(), bridge);
            switch (t.kind) {
                .once => {
                    t.finished = true;
                    break;
                },
                .loop, .during => {
                    if (t.loop_count != 0 and t.current_loop >= t.loop_count) {
                        t.finished = true;
                        break;
                    }
                },
            }
        }
        if (t.duration <= 0) {
            // Zero-duration timers fire their done signal once and finish: a
            // timer that fires EVERY tick with no duration is a busy loop with
            // a signal attached, and scripting that is one `update` away.
            fire(world, e, t.done_signal.slice(), bridge);
            t.finished = true;
            continue;
        }
    }
}

/// Queues the name on the world bus (for typed Zig listeners) and forwards it
/// through the bridge (for Lua). The bus emit is gated on `hasListeners` the
/// same way physics contacts are: a signal nobody subscribed to must not
/// enqueue (BUGS-M4 #9).
fn fire(world: *World, e: @import("entity.zig").Entity, name: []const u8, bridge: SignalBridge) void {
    if (name.len == 0) return;
    bridge.fire(name);
    if (world.signals.hasListeners(name)) {
        world.signals.emit(TimerEvent, name, .{ .entity = e.bits() });
    }
}

// ── Tests ────────────────────────────────────────────────────────────────────
// VM-free on purpose: the whole system is plain data + the world, so it is
// testable exactly like the ECS it lives next to.

const testing = std.testing;
const Entity = @import("entity.zig").Entity;

/// Captures fired names so a test can assert the ORDER and the count.
const Recorder = struct {
    names: [16][]const u8 = undefined,
    len: usize = 0,
    fn record(ctx: ?*anyopaque, name: []const u8) void {
        const self: *Recorder = @ptrCast(@alignCast(ctx.?));
        if (self.len < self.names.len) {
            self.names[self.len] = name;
            self.len += 1;
        }
    }
    fn bridge(self: *Recorder) SignalBridge {
        return .{ .ctx = self, .dispatch = Recorder.record };
    }
};

test "a once timer fires its done signal exactly once" {
    var world = World.init(testing.allocator);
    defer world.deinit();

    var t = components.Timer{ .duration = 0.5 };
    t.done_signal.set("boom");
    const e = try world.spawn(.{t});

    var rec = Recorder{};
    var i: usize = 0;
    while (i < 20) : (i += 1) tick(&world, 0.1, rec.bridge());
    try testing.expectEqual(@as(usize, 1), rec.len);
    try testing.expectEqualStrings("boom", rec.names[0]);
    try testing.expect(world.get(e, components.Timer).?.finished);
}

test "a loop timer cycles and stops at loop_count" {
    var world = World.init(testing.allocator);
    defer world.deinit();

    var t = components.Timer{ .duration = 1.0, .kind = .loop, .loop_count = 3 };
    t.done_signal.set("wave");
    _ = try world.spawn(.{t});

    var rec = Recorder{};
    var i: usize = 0;
    while (i < 100) : (i += 1) tick(&world, 0.5, rec.bridge());
    try testing.expectEqual(@as(usize, 3), rec.len);
}

test "during fires tick every tick and done every cycle; paused stops both" {
    var world = World.init(testing.allocator);
    defer world.deinit();

    var t = components.Timer{ .duration = 1.0, .kind = .during };
    t.tick_signal.set("tick");
    t.done_signal.set("cycle");
    const e = try world.spawn(.{t});

    var rec = Recorder{};
    tick(&world, 0.5, rec.bridge());
    try testing.expectEqual(@as(usize, 1), rec.len); // tick only
    try testing.expectEqualStrings("tick", rec.names[0]);
    tick(&world, 0.6, rec.bridge()); // crosses the cycle
    try testing.expectEqual(@as(usize, 3), rec.len); // tick + done
    try testing.expectEqualStrings("tick", rec.names[1]);
    try testing.expectEqualStrings("cycle", rec.names[2]);

    world.get(e, components.Timer).?.paused = true;
    const before = rec.len;
    tick(&world, 5.0, rec.bridge());
    try testing.expectEqual(before, rec.len);
}

test "timers on dead entities are skipped, not crashed into" {
    var world = World.init(testing.allocator);
    defer world.deinit();

    var t = components.Timer{ .duration = 0.1 };
    t.done_signal.set("x");
    const e = try world.spawn(.{t});
    _ = world.despawn(e);
    // The slot is recycled but the timer component is gone with the entity;
    // the walk must survive despawned slots without reading garbage.
    var rec = Recorder{};
    tick(&world, 1.0, rec.bridge());
    try testing.expectEqual(@as(usize, 0), rec.len);
}

test "an empty signal name fires nothing anywhere" {
    var world = World.init(testing.allocator);
    defer world.deinit();

    _ = try world.spawn(.{components.Timer{ .duration = 0.1 }}); // both names empty
    var rec = Recorder{};
    tick(&world, 1.0, rec.bridge());
    try testing.expectEqual(@as(usize, 0), rec.len);
}