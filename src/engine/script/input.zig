//! Action-based input for Lua (ROADMAP M3: "action-based Input API for Lua").
//!
//! Gameplay must never read a physical key: it reads a named *action*
//! ("move_left", "jump"). The mapping action → key lives in the engine (and,
//! later, in a remappable project file), so rebinding a control never touches a
//! line of Lua, and the same script runs unchanged on keyboard and gamepad.
//!
//! The snapshot is a flat, fixed table the runtime rebuilds once per frame from
//! the platform `Input`. Bindings only read it, so the per-call path is a string
//! compare against a small interned set and an array read — no allocation, no
//! hashing in the common case.
//!
//! Design: actions are interned by name into a fixed pool at setup. The frame
//! path (`pressed`/`down`) is O(actions) with an early length check, which for
//! the handful of actions a 2D game has is cheaper than any hash map and needs
//! no per-frame allocation.

const std = @import("std");

/// Maximum distinct actions the engine tracks. 2D games use a dozen; 64 leaves
/// generous headroom while keeping the whole snapshot compact and the scan
/// trivially branch-predictable.
pub const max_actions = 64;

/// Longest action name (bytes). "move_left" fits with room; this bound lets
/// names live inline, so no action string is ever allocated.
pub const max_name_len = 24;

/// One action's name and its per-frame state. Plain data, no allocation.
const Action = struct {
    name_buf: [max_name_len]u8 = [_]u8{0} ** max_name_len,
    name_len: u8 = 0,
    down: bool = false,
    /// True only on the frame the action went down (edge, no auto-repeat).
    pressed: bool = false,

    fn name(self: *const Action) []const u8 {
        return self.name_buf[0..self.name_len];
    }
};

/// The per-frame input snapshot Lua reads. The runtime fills it; bindings only
/// query it. This is `Input` in the roadmap sense — never the raw key array,
/// which stays inside the platform layer (spec §7: nothing leaks into gameplay).
pub const Input = struct {
    actions: [max_actions]Action = [_]Action{Action{}} ** max_actions,
    count: u8 = 0,

    /// Clears per-frame edge state. Call once at the start of building the
    /// snapshot (pressed flags are recomputed from the platform edge each frame).
    pub fn beginFrame(self: *Input) void {
        for (self.actions[0..self.count]) |*a| a.pressed = false;
    }

    /// Interns an action name so it can be driven each frame. Idempotent:
    /// interning the same name twice does not duplicate it. Names longer than
    /// the bound are truncated (a config typo surfaces as a missing binding,
    /// not a crash).
    pub fn define(self: *Input, name: []const u8) void {
        if (self.find(name) != null) return;
        if (self.count >= max_actions) return;
        var a = &self.actions[self.count];
        const n = @min(name.len, max_name_len);
        @memcpy(a.name_buf[0..n], name[0..n]);
        a.name_len = @intCast(n);
        a.down = false;
        a.pressed = false;
        self.count += 1;
    }
    /// Sets an action's held state for this frame. `just_pressed` marks the edge
    /// frame. Unknown actions are ignored (define first).
    pub fn set(self: *Input, name: []const u8, is_down: bool, just_pressed: bool) void {
        const a = self.findMut(name) orelse return;
        a.down = is_down;
        if (just_pressed) a.pressed = true;
    }

    /// True while the action is held.
    pub fn down(self: *const Input, name: []const u8) bool {
        const a = self.find(name) orelse return false;
        return a.down;
    }

    /// True only on the frame the action went down.
    pub fn pressed(self: *const Input, name: []const u8) bool {
        const a = self.find(name) orelse return false;
        return a.pressed;
    }

    /// Signed axis from two opposing actions: -1 when `negative` is held, +1
    /// when `positive` is held, 0 when neither or both. Analog devices can push
    /// this between the extremes later; the 2D keyboard path is ternary.
    pub fn axis(self: *const Input, negative: []const u8, positive: []const u8) f32 {
        const neg = self.down(negative);
        const pos = self.down(positive);
        if (neg == pos) return 0; // neither, or the contradictory both
        return if (pos) 1 else -1;
    }

    fn find(self: *const Input, name: []const u8) ?*const Action {
        for (self.actions[0..self.count]) |*a| {
            if (a.name_len == name.len and std.mem.eql(u8, a.name(), name)) return a;
        }
        return null;
    }

    fn findMut(self: *Input, name: []const u8) ?*Action {
        for (self.actions[0..self.count]) |*a| {
            if (a.name_len == name.len and std.mem.eql(u8, a.name(), name)) return a;
        }
        return null;
    }
};

// ── Tests ────────────────────────────────────────────────────────────────────

test "define is idempotent and set drives down/pressed" {
    var input = Input{};
    input.beginFrame();
    input.define("move_left");
    input.define("move_left"); // no duplicate
    try std.testing.expectEqual(@as(u8, 1), input.count);

    input.set("move_left", true, true);
    try std.testing.expect(input.down("move_left"));
    try std.testing.expect(input.pressed("move_left"));

    // Next frame: held but no longer an edge.
    input.beginFrame();
    try std.testing.expect(input.down("move_left"));
    try std.testing.expect(!input.pressed("move_left"));
}

test "axis is -1/0/+1 and 0 when both or neither" {
    var input = Input{};
    input.define("left");
    input.define("right");
    try std.testing.expectEqual(@as(f32, 0), input.axis("left", "right"));

    input.set("right", true, false);
    try std.testing.expectEqual(@as(f32, 1), input.axis("left", "right"));

    input.set("left", true, false);
    try std.testing.expectEqual(@as(f32, 0), input.axis("left", "right")); // both held

    input.set("right", false, false);
    try std.testing.expectEqual(@as(f32, -1), input.axis("left", "right"));
}

test "unknown actions are inert, not crashes" {
    var input = Input{};
    input.set("nope", true, true); // never defined: ignored
    try std.testing.expect(!input.down("nope"));
    try std.testing.expect(!input.pressed("nope"));
    try std.testing.expectEqual(@as(f32, 0), input.axis("a", "b"));
}

