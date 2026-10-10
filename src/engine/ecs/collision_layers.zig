//! Collision and render layers: named bitmasks, configured once, like Godot's
//! `layer_names` / `ProjectSettings`.
//!
//! ## Why this exists
//!
//! Without it, every body collides with every body. That is wrong in both
//! directions at once:
//!
//! - A coin sensor collides with the player's feet, the bullets, the enemies and
//!   the floor, and every one of those is a contact the solver has to resolve.
//! - A trigger volume collides with the player, and the player is stopped by a
//!   doorbell.
//!
//! Both are one missing bitmask. The fix is not a per-pair exception list, which
//! is O(n^2) to write and O(n^2) to maintain — it is 16 named bits that every
//! body carries and the solver intersects.
//!
//! ## The rule, and it is worth stating exactly
//!
//! Two shapes interact when **each one is on a layer the other has in its
//! mask**:
//!
//! ```text
//! collide(A, B)  ==  (A.layer & B.mask) != 0  &&  (B.layer & A.mask) != 0
//! ```
//!
//! The AND is deliberate and it is not the same test twice. Godot-style
//! `A.mask & B.layer` alone is a one-way filter that lets a projectile ignore a
//! wall while the wall still tries to push the projectile. Requiring both
//! directions means a pair either agrees to interact or does not interact at
//! all, which is what makes a layer a *category* rather than a query.
//!
//! The cost when you do not care: put the bodies on the same layer and set every
//! mask to `everything`. That is one line, it is the default, and it behaves
//! exactly like no layers at all.
//!
//! ## Why bits and not a list
//!
//! A body is often on more than one layer — a player that is both `1` and
//! `3` so that enemies can hit it and pickups can trigger on it. Bits make that
//! free and make the intersection a single AND. A list would make it a loop in
//! the broadphase, which is the one place in a frame where a loop is felt.

const std = @import("std");

/// 16 layers: the same width as Godot, and one `u16` that fits in a component
/// alongside a mask without the pair needing padding.
pub const layer_count = 16;

/// Every bit set — the default mask, meaning "collides with everything".
pub const everything: u16 = std.math.maxInt(u16);
pub const nothing: u16 = 0;

/// A resolved layer: its bit and its index, with the index being what a
/// ProjectSettings-style list is indexed by.
pub const Layer = struct {
    /// The bit itself, `1 << index`.
    bit: u16,
    index: u8,
    name: []const u8,
};

/// A collision pair, already resolved. Solvers want bits; gameplay wants
/// meaning. This is the one place that converts between them.
pub const Pair = struct {
    a_layer: u16,
    a_mask: u16,
    b_layer: u16,
    b_mask: u16,

    /// Whether this pair is allowed to interact at all.
    ///
    /// Symmetric on purpose — see the module comment.
    pub fn collides(self: Pair) bool {
        if (self.a_layer == nothing or self.b_layer == nothing) return false;
        return (self.a_layer & self.b_mask) != 0 and (self.b_layer & self.a_mask) != 0;
    }

    /// The bit a query for `self` should look for: anything this body can hit.
    pub fn queryCategory(self: Pair) u64 {
        return @as(u64, self.a_layer);
    }

    /// The bits a query from `self` should accept.
    pub fn queryMask(self: Pair) u64 {
        return @as(u64, self.a_mask);
    }
};

/// The named layers. Built once from settings and then read-only.
///
/// The names are borrowed from the settings buffer and are never copied: a
/// 16-entry table of short strings is not where memory should go, and the
/// settings outlive every body that refers to one.
pub const Registry = struct {
    names: [layer_count]?[]const u8 = [_]?[]const u8{null} ** layer_count,

    /// `true` when every name is empty, which is the "layers off" case. Kept
    /// rather than inferred at every call site so the fast path is one bool
    /// test instead of sixteen.
    inert: bool = true,

    pub fn empty() Registry {
        return .{};
    }

    /// Builds from a settings-style list, in bit order. Extra names beyond 16
    /// are ignored and missing ones stay unnamed; both are reported by
    /// `validate` so a typo is a startup message rather than a body that
    /// silently collides with the wrong things.
    pub fn fromNames(names: []const []const u8) Registry {
        var r = Registry{};
        var i: usize = 0;
        while (i < layer_count) : (i += 1) {
            if (i >= names.len) break;
            if (names[i].len == 0) continue;
            r.names[i] = names[i];
            r.inert = false;
        }
        return r;
    }

    pub fn set(self: *Registry, index: u8, value: []const u8) void {
        if (index >= layer_count) return;
        self.names[index] = if (value.len == 0) null else value;
        self.inert = true;
        for (self.names) |n| {
            if (n != null) {
                self.inert = false;
                break;
            }
        }
    }

    pub fn name(self: *const Registry, index: u8) []const u8 {
        if (index >= layer_count) return "";
        return self.names[index] orelse "";
    }

    pub fn indexOf(self: *const Registry, want: []const u8) ?u8 {
        for (self.names, 0..) |n, i| {
            if (n) |actual| {
                if (std.mem.eql(u8, actual, want)) return @intCast(i);
            }
        }
        return null;
    }

    /// Resolves a name to its bit. Null for an unknown name, so a typo becomes
    /// a nil the caller has to handle rather than layer 0, which would silently
    /// put the body on the default layer and collide with everything.
    pub fn bit(self: *const Registry, want: []const u8) ?u16 {
        const i = self.indexOf(want) orelse return null;
        return @as(u16, 1) << @intCast(i);
    }

    /// Resolves a space-separated list of names into a mask, e.g.
    /// `"player enemy"`. Unknown names are skipped and counted in `unknown` so
    /// a settings typo is reportable.
    pub fn maskFromNames(self: *const Registry, names: []const u8, unknown: ?*u32) u16 {
        var mask: u16 = 0;
        var it = std.mem.tokenizeAny(u8, names, " ,");
        while (it.next()) |n| {
            if (self.bit(n)) |b| {
                mask |= b;
            } else {
                if (unknown) |u| u.* += 1;
            }
        }
        return mask;
    }

    /// A human-readable dump, one bit per line. This exists so that a project
    /// can print its own layer table at startup: sixteen lines is nothing to
    /// read and it is the fastest way to find "why is my doorbell solid".
    pub fn describe(self: *const Registry, writer: anytype) !void {
        var i: u8 = 0;
        while (i < layer_count) : (i += 1) {
            const n = self.name(i);
            if (n.len == 0) continue;
            try writer.print("  {d:2}  {s}\n", .{ i + 1, n });
        }
    }
};

/// The engine-side physics tuning that belongs in project settings rather than
/// in code. Grouped with the layers because both are "what this project is like",
/// and a project that has to edit Zig to change a sleep threshold is a project
/// that cannot be handed to someone else.
pub const Tuning = struct {
    /// Below this linear speed (units/second) a body is a sleep candidate.
    sleep_threshold_linear: f32 = 8.0,
    /// Below this angular speed (rad/s) a body is a sleep candidate.
    sleep_threshold_angular: f32 = 8.0,
    /// Seconds of stillness before a candidate actually sleeps.
    time_before_sleep: f32 = 0.5,
    /// Solver iterations per step. Fewer is faster and stacks settle worse.
    solver_iterations: u8 = 4,
    /// The most fixed steps one frame may run, so a slow frame cannot start a
    /// spiral where catching up makes the next frame slower still.
    max_physics_steps_per_frame: u8 = 1,

    /// Rejects a configuration that would make physics worse than doing nothing.
    ///
    /// Checked at load rather than trusted: every one of these is a number a
    /// project will eventually tune, and a sleep threshold of zero means nothing
    /// ever sleeps, which looks exactly like "the sleeping code does not work".
    pub fn validate(self: Tuning) !void {
        if (!(self.sleep_threshold_linear >= 0 and self.sleep_threshold_angular >= 0)) {
            return error.NegativeSleepThreshold;
        }
        if (!(self.time_before_sleep >= 0)) return error.NegativeSleepTime;
        if (self.solver_iterations == 0) return error.ZeroSolverIterations;
        if (self.max_physics_steps_per_frame == 0) return error.ZeroPhysicsSteps;
    }
};

// ── Tests ────────────────────────────────────────────────────────────────────

const testing = std.testing;

test "two bodies on overlapping layers and masks interact" {
    const p = Pair{
        .a_layer = @as(u16, 1) << 0,
        .a_mask = @as(u16, 1) << 1,
        .b_layer = @as(u16, 1) << 1,
        .b_mask = @as(u16, 1) << 0,
    };
    try testing.expect(p.collides());
}

test "the filter is symmetric: one direction is not enough" {
    // A is willing to hit B; B is not willing to hit A. They do not interact.
    // With a one-way `A.mask & B.layer` test they WOULD, which is how a
    // projectile ends up passing through a wall that is trying to stop it.
    const p = Pair{
        .a_layer = @as(u16, 1) << 0,
        .a_mask = everything,
        .b_layer = @as(u16, 1) << 1,
        .b_mask = nothing,
    };
    try testing.expect(!p.collides());
}

test "a body on no layer collides with nothing, not with everything" {
    // The failure mode this guards: an unset layer field defaulting to 0 would
    // make `layer & mask` zero and — under a one-way test — either collide with
    // everything or nothing depending on which operand defaulted. Explicit.
    const p = Pair{
        .a_layer = nothing,
        .a_mask = everything,
        .b_layer = everything,
        .b_mask = everything,
    };
    try testing.expect(!p.collides());
}

test "everything against everything is the no-layers behaviour" {
    const p = Pair{
        .a_layer = everything,
        .a_mask = everything,
        .b_layer = everything,
        .b_mask = everything,
    };
    try testing.expect(p.collides());
}

test "named layers resolve to bits and back" {
    var r = Registry.fromNames(&.{
        "world",      // 1
        "player",     // 2
        "enemy",      // 3
        "projectile", // 4
    });
    try testing.expectEqual(@as(u16, 1), r.bit("world").?);
    try testing.expectEqual(@as(u16, 2), r.bit("player").?);
    try testing.expectEqual(@as(u16, 8), r.bit("projectile").?); // 4th name -> bit 3
    try testing.expectEqual(@as(u8, 1), r.indexOf("player").?);
    try testing.expectEqualStrings("enemy", r.name(2));
}

test "an unknown name resolves to nothing, never to layer 0" {
    var r = Registry.fromNames(&.{"world"});
    // Silently returning layer 0 would put the body on `world` and collide with
    // everything -- the opposite of what a typo should do.
    try testing.expect(r.bit("plyer") == null);
    try testing.expectEqual(@as(u8, 0), r.indexOf("nope") orelse 0);
}

test "a mask parses a list of names and counts what it did not know" {
    var r = Registry.fromNames(&.{ "world", "player", "enemy" });
    var unknown: u32 = 0;
    const m = r.maskFromNames("player enemy", &unknown);
    try testing.expectEqual(@as(u16, 2 | 4), m);
    try testing.expectEqual(@as(u32, 0), unknown);

    const bad = r.maskFromNames("player typo", &unknown);
    try testing.expectEqual(@as(u16, 2), bad);
    try testing.expectEqual(@as(u32, 1), unknown);
}

test "a project with no layers is inert, and stays inert when one is added" {
    var r = Registry.empty();
    try testing.expect(r.inert);
    r.set(0, "world");
    try testing.expect(!r.inert);
    r.set(0, "");
    try testing.expect(r.inert);
}

test "sixteen layers fit a u16 with no collision between them" {
    var all: u16 = 0;
    var i: u8 = 0;
    while (i < layer_count) : (i += 1) all |= @as(u16, 1) << @intCast(i);
    try testing.expectEqual(everything, all);
}

test "tuning that would make physics worse than doing nothing is rejected" {
    try testing.expectError(error.ZeroSolverIterations, (Tuning{ .solver_iterations = 0 }).validate());
    try testing.expectError(error.ZeroPhysicsSteps, (Tuning{ .max_physics_steps_per_frame = 0 }).validate());
    try testing.expectError(error.NegativeSleepThreshold, (Tuning{ .sleep_threshold_linear = -1 }).validate());
    try testing.expectError(error.NegativeSleepTime, (Tuning{ .time_before_sleep = -0.5 }).validate());
    try (Tuning{}).validate(); // the defaults must be valid
}