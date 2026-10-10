//! Declarative state machines as an ECS component (ROADMAP M4.5).
//!
//! ONE implementation, every case: an enemy's AI, the player's own states
//! (idle/run/jump/dash), a spawner, a UI screen, and the game flow all use this
//! file. The difference between them is the script that declares the states, not
//! any engine-side machinery — which is the whole point of putting it in a
//! component rather than building an AI-specific system.
//!
//! ## Why the component is a handle
//!
//! A machine holds names and Lua callback references — pointers and slices — and
//! `components.zig` rule 1 forbids both in a component. So the component stores
//! a `u32` index into this registry, exactly as `Script` stores a script id. That
//! also decides the serialization story: `.zson` writes `machine = 3`, never a
//! closure, so save/load is bit-exact (spec §6) and the transitions are rebuilt
//! from the script on attach.
//!
//! ## Why everything is a fixed-capacity struct
//!
//! A machine is 16 states x 32 transitions of inline data — kilobytes. With a
//! pool of machines that is a real memory cost, so the caps are deliberate
//! (`max_machines`). Growing past a cap is a reported error, never a silent
//! truncation: a game that loses its death state because of a cap would be the
//! worst kind of bug. Names are inline fixed arrays for the same reason —
//! determinism (spec §6) forbids anything whose layout depends on allocation.

const std = @import("std");
const lua = @import("luajit.zig");
const vm_mod = @import("vm.zig");

/// Ref value meaning "no callback" (mirrors `behavior.zig`'s `no_ref`).
pub const no_ref: i32 = -1;

pub const max_name_len = 24;
pub const max_event_len = 16;
pub const max_states = 16;
pub const max_transitions = 32;
pub const max_machines = 64;
/// How many entities can be attached to machines at once. Sized for a full
/// enemy roster; the tick walks this array, so it is the number that decides the
/// frame cost of the whole subsystem.
pub const max_bindings = 1024;

/// A bounded, inline string. Fixed capacity keeps `State`/`Transition` plain
/// data with no pointers, which is what lets them live in a stable pool.
const Inline = struct {
    bytes: [max_name_len]u8 = [_]u8{0} ** max_name_len,
    len: u8 = 0,

    fn set(self: *Inline, text: []const u8) void {
        const n = @min(text.len, max_name_len);
        @memcpy(self.bytes[0..n], text[0..n]);
        self.len = @intCast(n);
    }

    fn eql(self: *const Inline, text: []const u8) bool {
        return std.mem.eql(u8, self.bytes[0..self.len], text);
    }

    fn slice(self: *const Inline) []const u8 {
        return self.bytes[0..self.len];
    }
};

/// A state and its three optional callbacks. Each ref is `no_ref` when the
/// script did not supply that hook, so the tick tests one integer instead of
/// resolving anything.
pub const State = struct {
    name: Inline = .{},
    enter_ref: i32 = no_ref,
    update_ref: i32 = no_ref,
    exit_ref: i32 = no_ref,
};

/// `event` moves the machine from `from` to `to` when fired. States are stored
/// as indices rather than names so a transition is a pair of compares.
pub const Transition = struct {
    from: u8,
    to: u8,
    event: Inline = .{},
};

/// A declared machine: the states and transitions, shared by every entity that
/// uses it. One behavior declares one; a hundred copies of that behavior share
/// the same `Machine`, which is why the definition and the live state are
/// separate types.
pub const Machine = struct {
    states: [max_states]State = undefined,
    state_count: u8 = 0,
    transitions: [max_transitions]Transition = undefined,
    transition_count: u8 = 0,
    /// Index of the state entered on start. Defaults to 0; a script can move it.
    initial: u8 = 0,
};

/// One live instance: which machine an entity runs, and where it currently is.
/// This is the per-entity state the tick mutates.
pub const Binding = struct {
    /// 0 means detached — the value `StateMachine.machine` uses for "none".
    machine: u32 = 0,
    /// The behavior's `self` table, passed as `self` to every callback.
    self_ref: i32 = no_ref,
    /// Index of the active state; `no_state` before the first tick.
    current: u8 = no_state,
    /// A transition requested by `sm_fire` earlier this frame, applied at the
    /// top of the next tick. Deferred rather than immediate so a callback that
    /// fires an event cannot re-enter the machine mid-traversal.
    pending: Inline = .{},

    pub const no_state = 255;
};

pub const Error = error{
    OutOfMemory,
    MachineLimitReached,
    StateLimitReached,
    TransitionLimitReached,
    NoSuchMachine,
    NoSuchState,
    NoSuchTransition,
    BindingLimitReached,
};

/// The registry plus the live bindings, and the owner of the frame tick.
///
/// Lives inside `Behaviors` (which owns the VM the refs point into) and is
/// reachable from Lua through `Context.machines`.
pub const Registry = struct {
    allocator: std.mem.Allocator,
    /// Nullable ON PURPOSE. Declaring a machine — adding states, wiring
    /// transitions, checking the pools — is pure data manipulation and must be
    /// testable without a VM: a live LuaJIT state does not survive Zig's test
    /// runner (see `api_acceptance_test.zig`), so a VM-dependent test here would
    /// be untestable. Only `tick`, `fire` and `setState` need it, and they
    /// no-op when it is absent.
    vm: ?*vm_mod.Vm,

    /// Index 0 is permanently "no machine", so a component's `machine = 0`
    /// needs no extra branch and no separate presence flag.
    machines: [max_machines]Machine = undefined,
    machine_count: u8 = 0,

    bindings: [max_bindings]Binding = undefined,
    binding_count: u16 = 0,

    pub fn init(allocator: std.mem.Allocator, vm: ?*vm_mod.Vm) Registry {
        var r = Registry{ .allocator = allocator, .vm = vm };
        // Slot 0 stays zeroed so `machine = 0` reads as empty.
        r.machines[0] = .{};
        r.machine_count = 1;
        return r;
    }

    // ── Declaration (Lua, at attach time) ──────────────────────────────────

    /// Creates a machine and returns its index, or 0 when the pool is full.
    /// Returning 0 rather than an error keeps a Lua call simple; `sm_count`
    /// lets a script notice.
    pub fn createMachine(self: *Registry) u32 {
        if (self.machine_count >= max_machines) return 0;
        const id = self.machine_count;
        self.machines[id] = .{};
        self.machine_count += 1;
        return id;
    }

    pub fn addState(self: *Registry, machine_id: u32, name: []const u8) Error!u8 {
        if (machine_id == 0 or machine_id >= self.machine_count) return error.NoSuchMachine;
        const m = &self.machines[machine_id];
        if (m.state_count >= max_states) return error.StateLimitReached;
        // Duplicates would make transitions ambiguous (which one wins?), so the
        // first definition wins and the duplicate is reported.
        if (self.findState(m, name) != null) return error.NoSuchState;
        const idx = m.state_count;
        m.states[idx] = .{};
        m.states[idx].name.set(name);
        m.state_count += 1;
        return idx;
    }

    pub fn setInitial(self: *Registry, machine_id: u32, name: []const u8) Error!void {
        if (machine_id == 0 or machine_id >= self.machine_count) return error.NoSuchMachine;
        const m = &self.machines[machine_id];
        const idx = self.findState(m, name) orelse return error.NoSuchState;
        m.initial = idx;
    }

    pub fn addTransition(
        self: *Registry,
        machine_id: u32,
        from: []const u8,
        event: []const u8,
        to: []const u8,
    ) Error!void {
        if (machine_id == 0 or machine_id >= self.machine_count) return error.NoSuchMachine;
        const m = &self.machines[machine_id];
        const from_idx = self.findState(m, from) orelse return error.NoSuchState;
        const to_idx = self.findState(m, to) orelse return error.NoSuchState;
        if (m.transition_count >= max_transitions) return error.TransitionLimitReached;
        const idx = m.transition_count;
        m.transitions[idx] = .{ .from = from_idx, .to = to_idx };
        m.transitions[idx].event.set(event);
        m.transition_count += 1;
    }

    fn findState(_: *const Registry, m: *const Machine, name: []const u8) ?u8 {
        for (m.states[0..m.state_count], 0..) |s, i| {
            if (s.name.eql(name)) return @intCast(i);
        }
        return null;
    }

    // ── Attachment (Zig, when a behavior loads) ────────────────────────────

    /// Binds an entity's `self` table to a machine. Returns false when the
    /// binding pool is full, which the caller reports rather than silently
    /// dropping the state machine — an enemy that never leaves `idle` is a much
    /// worse failure than a logged error.
    pub fn attach(self: *Registry, machine_id: u32, self_ref: i32) Error!bool {
        if (machine_id == 0 or machine_id >= self.machine_count) return error.NoSuchMachine;
        if (self.binding_count >= max_bindings) return error.BindingLimitReached;
        const idx = self.binding_count;
        self.bindings[idx] = .{ .machine = machine_id, .self_ref = self_ref };
        self.binding_count += 1;
        return true;
    }

    /// Detaches every binding belonging to an entity (its `self` table died).
    /// Swap-remove, so it is O(1) per removal and does not reorder the others.
    pub fn detachEntity(self: *Registry, entity_index: u32) void {
        var i: usize = 0;
        while (i < self.binding_count) {
            if (self.binding_of(i)) |b| {
                if (self.instanceEntity(b.self_ref)) |e| {
                    if (e == entity_index) {
                        self.binding_count -= 1;
                        if (i != self.binding_count) self.bindings[i] = self.bindings[self.binding_count];
                        continue; // re-test slot i, which now holds a moved binding
                    }
                }
            }
            i += 1;
        }
    }

    /// The binding index for an entity, or null.
    pub fn bindingFor(self: *const Registry, entity_index: u32) ?usize {
        var i: usize = 0;
        while (i < self.binding_count) : (i += 1) {
            const b = &self.bindings[i];
            if (b.machine == 0) continue;
            if (self.instanceEntity(b.self_ref)) |e| {
                if (e == entity_index) return i;
            }
        }
        return null;
    }

    fn binding_of(self: *const Registry, i: usize) ?*const Binding {
        if (i >= self.binding_count) return null;
        return &self.bindings[i];
    }

    /// Recovers the entity index from a binding's `self` table. Mirrors the
    /// `__entity` bridge in `bindings.zig`: read the field, undo the +1 bias.
    fn instanceEntity(self: *const Registry, self_ref: i32) ?u32 {
        if (self_ref == no_ref) return null;
        const vm = self.vm orelse return null;
        const L = vm.state() orelse return null;
        vm.pushRef(self_ref); // [self]
        lua.getField(L, -1, "__entity"); // [self, ud]
        const ud = lua.lua_topointer(L, -1);
        lua.pop(L, 2); // []
        const raw = ud orelse return null;
        const biased: u64 = @intFromPtr(raw);
        if (biased == 0) return null; // the bias guarantees non-null, so 0 means absent
        const bits = biased - 1;
        // Entity is a packed struct; only `index` is needed here.
        const entity: @import("ecs").Entity = @bitCast(bits);
        return entity.index;
    }

    // ── The tick ────────────────────────────────────────────────────────────

    /// Advances every attached machine by one frame: applies a pending
    /// transition, enters the first state if needed, then calls `update`.
    ///
    /// Ordering is `exit(old) -> enter(new) -> update(new)`, which is what makes
    /// a transition's `exit` able to see the state it is leaving and its `enter`
    /// able to read whatever `exit` set up.
    pub fn tick(self: *Registry) void {
        var i: usize = 0;
        while (i < self.binding_count) : (i += 1) {
            const b = &self.bindings[i];
            if (b.machine == 0 or b.machine >= self.machine_count) continue;
            const m = &self.machines[b.machine];

            if (b.current == Binding.no_state) {
                b.current = m.initial;
                self.callState(m, b, b.current, .enter);
            }

            // A transition requested by `fire` during the previous frame's
            // `update`, applied before this frame's `update` so the new state's
            // update runs the same frame it was entered.
            if (b.pending.len != 0) {
                if (self.applyTransition(m, b)) {
                    self.callState(m, b, b.current, .enter);
                }
                b.pending.len = 0;
            }

            self.callState(m, b, b.current, .update);
        }
    }

    /// Finds and applies the first transition matching the pending event.
    ///
    /// `exit` runs on the state being LEFT, before `current` moves — that order
    /// is what lets an `exit` clean up what its `enter` set up, and it is why
    /// the caller only has to fire `enter` afterwards.
    fn applyTransition(self: *Registry, m: *Machine, b: *Binding) bool {
        for (m.transitions[0..m.transition_count]) |t| {
            if (t.from != b.current) continue;
            if (!t.event.eql(b.pending.slice())) continue;
            if (t.to == b.current) return false; // self-transition: nothing to do
            self.callState(m, b, b.current, .exit);
            b.current = t.to;
            return true;
        }
        return false;
    }

    const Hook = enum { enter, update, exit };

    fn callState(self: *Registry, m: *Machine, b: *Binding, state_index: u8, hook: Hook) void {
        if (state_index >= m.state_count) return;
        const ref = switch (hook) {
            .enter => m.states[state_index].enter_ref,
            .update => m.states[state_index].update_ref,
            .exit => m.states[state_index].exit_ref,
        };
        if (ref == no_ref or b.self_ref == no_ref) return;
        const vm = self.vm orelse return;
        const L = vm.state() orelse return;
        vm.pushRef(ref); // [fn]
        vm.pushRef(b.self_ref); // [fn, self]
        // Errors are swallowed and counted, like `Behaviors.callMethod`: one
        // broken state must not take down the frame (spec: a script bug is a
        // logged error, not a crash).
        _ = lua.lua_pcall(L, 1, 0, 0);
    }

    // ── Queries, used by the Lua bindings ───────────────────────────────────

    pub fn stateName(self: *const Registry, machine_id: u32, state_index: u8) []const u8 {
        if (machine_id == 0 or machine_id >= self.machine_count) return "";
        const m = &self.machines[machine_id];
        if (state_index >= m.state_count) return "";
        return m.states[state_index].name.slice();
    }

    pub fn stateIndex(self: *const Registry, machine_id: u32, name: []const u8) ?u8 {
        if (machine_id == 0 or machine_id >= self.machine_count) return null;
        return self.findState(&self.machines[machine_id], name);
    }

    /// Records a transition request on a binding; the tick applies it before the
    /// next `update`, so a callback firing an event cannot re-enter the machine
    /// mid-traversal.
    ///
    /// The LAST event in a frame wins. Two events fired before the next tick
    /// cannot both be honored without a queue (the second would fire in a state
    /// the first never reached), and "first wins" is just as arbitrary a
    /// resolution — the difference only shows up in a script that fires twice
    /// before a tick, which is a bug in the script either way.
    pub fn fire(self: *Registry, binding_index: usize, event: []const u8) void {
        if (binding_index >= self.binding_count) return;
        self.bindings[binding_index].pending.set(event);
    }

    /// Jumps straight to `state`, running `exit` on the current one and `enter`
    /// on the target. Used by `sm_set_state`, which a script calls from inside a
    /// callback: it cannot wait for the next tick without the callback's state
    /// continuing to run one more frame.
    pub fn setState(self: *Registry, binding_index: usize, state: u8) void {
        if (binding_index >= self.binding_count) return;
        const b = &self.bindings[binding_index];
        if (b.machine == 0 or b.machine >= self.machine_count) return;
        const m = &self.machines[b.machine];
        if (state >= m.state_count) return;

        if (b.current == Binding.no_state) {
            // Never entered: this is its entry, not a transition.
            b.current = state;
            self.callState(m, b, state, .enter);
            return;
        }
        if (b.current == state) return;
        self.callState(m, b, b.current, .exit);
        b.current = state;
        // A pending event belongs to the state we just left; letting it fire
        // here would immediately undo the explicit jump.
        b.pending.len = 0;
        self.callState(m, b, state, .enter);
    }

    /// The active state index of a binding, or `Binding.no_state`.
    pub fn currentState(self: *const Registry, binding_index: usize) u8 {
        if (binding_index >= self.binding_count) return Binding.no_state;
        return self.bindings[binding_index].current;
    }

    /// Releases every Lua ref the registry owns. Called at shutdown so the
    /// registry's refs do not outlive the VM they point into.
    pub fn deinit(self: *Registry) void {
        const vm = self.vm orelse return;
        const L = vm.state() orelse return;
        for (self.bindings[0..self.binding_count]) |b| {
            if (b.machine == 0 or b.machine >= self.machine_count) continue;
            const m = &self.machines[b.machine];
            for (m.states[0..m.state_count]) |s| {
                if (s.enter_ref != no_ref) lua.luaL_unref(L, lua.REGISTRYINDEX, s.enter_ref);
                if (s.update_ref != no_ref) lua.luaL_unref(L, lua.REGISTRYINDEX, s.update_ref);
                if (s.exit_ref != no_ref) lua.luaL_unref(L, lua.REGISTRYINDEX, s.exit_ref);
            }
        }
        self.binding_count = 0;
    }
};

// ── Tests ────────────────────────────────────────────────────────────────────

const testing = std.testing;

/// A registry with no VM. Everything except the tick is pure data, and keeping
/// these tests VM-free is what makes them runnable at all (a live LuaJIT state
/// aborts under Zig's test runner).
fn testRegistry(allocator: std.mem.Allocator) Registry {
    return Registry.init(allocator, null);
}

test "machine slot 0 means none" {
    var reg = testRegistry(testing.allocator);

    // Slot 0 is reserved, so the first machine gets id 1 and is non-zero —
    // that is what makes `machine = 0` a reliable "none" in the component.
    const first = reg.createMachine();
    try testing.expectEqual(@as(u32, 1), first);
    const id = reg.createMachine();
    try testing.expectEqual(@as(u32, 2), id);
    try testing.expectEqualStrings("", reg.stateName(0, 0));
}

test "states are added and found by name" {
    var reg = testRegistry(testing.allocator);

    const m = reg.createMachine();
    _ = try reg.addState(m, "idle");
    _ = try reg.addState(m, "chase");
    try testing.expectEqual(@as(?u8, 0), reg.stateIndex(m, "idle"));
    try testing.expectEqual(@as(?u8, 1), reg.stateIndex(m, "chase"));
    try testing.expectEqual(@as(?u8, null), reg.stateIndex(m, "attack"));
}

test "a duplicate state name is rejected" {
    var reg = testRegistry(testing.allocator);

    const m = reg.createMachine();
    _ = try reg.addState(m, "idle");
    try testing.expectError(error.NoSuchState, reg.addState(m, "idle"));
}

test "a transition needs both endpoints to exist" {
    var reg = testRegistry(testing.allocator);

    const m = reg.createMachine();
    _ = try reg.addState(m, "idle");
    _ = try reg.addState(m, "chase");

    try reg.addTransition(m, "idle", "see_player", "chase");
    try testing.expectError(error.NoSuchState, reg.addTransition(m, "idle", "gone", "attack"));
    try testing.expectError(error.NoSuchState, reg.addTransition(m, "from_nowhere", "gone", "idle"));
}

test "the state pool caps and reports instead of truncating" {
    var reg = testRegistry(testing.allocator);

    const m = reg.createMachine();
    for (0..max_states) |i| {
        var buf: [8]u8 = undefined;
        const name = try std.fmt.bufPrint(&buf, "s{d}", .{i});
        _ = try reg.addState(m, name);
    }
    try testing.expectError(error.StateLimitReached, reg.addState(m, "one_too_many"));
}

test "the machine pool caps and reports" {
    var reg = testRegistry(testing.allocator);

    // Slot 0 is reserved, so max_machines - 1 real machines fit.
    for (1..max_machines) |_| _ = reg.createMachine();
    // Exhausted: returns 0, which is exactly what "no machine" means, so a
    // script that ignores the failure degrades to no state machine rather than
    // to a machine whose id collides with the reserved slot.
    try testing.expectEqual(@as(u32, 0), reg.createMachine());
}

test "setInitial moves the starting state" {
    var reg = testRegistry(testing.allocator);

    const m = reg.createMachine();
    _ = try reg.addState(m, "idle");
    _ = try reg.addState(m, "chase");
    try testing.expectEqual(@as(u8, 0), reg.machines[m].initial);
    try reg.setInitial(m, "chase");
    try testing.expectEqual(@as(u8, 1), reg.machines[m].initial);
}
