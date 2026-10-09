//! Binding metadata registry — the single source of truth for everything the
//! Lua surface exposes (ROADMAP M3, M5.5).
//!
//! Every function handed to Lua is described here ONCE, in comptime data:
//! signature, parameters (type + default), return value, a one-line summary and
//! a runnable example. From this one table we derive, with no hand-written
//! duplication:
//! - the in-engine autocomplete + tooltips (M5.5),
//! - the Ctrl+Click help panel (M5.5),
//! - the static docs site (M12),
//! - the **EmmyLua/LuaLS stubs** so VS Code/Neovim/Zed autocomplete the same
//!   API the engine actually ships (`stubs.zig`).
//!
//! It is also the gate for the gameplay toolkit (ROADMAP M4.5): `rand`, `noise`,
//! the state-machine component and the steering helpers land through this same
//! registry, so none of them can ship without a summary, typed params, typed
//! returns and a runnable example.
//!
//! The rule the roadmap states — "no metadata → the binding does not merge" —
//! is enforced mechanically: `bindings.zig` registers its C functions through
//! `assertAllDocumented`, a comptime check that every registered name has an
//! entry here with a non-empty summary and example. A new binding without
//! metadata is a compile error, not a review comment.
//!
//! Why comptime structs and not Zig doc-comments: Zig does not expose
//! `///`-comments through `@typeInfo`, so "doc-comments" as a *reflection*
//! source is not available. Declaring the metadata as explicit comptime data
//! next to the registry is the equivalent that actually compiles, and it keeps
//! the example (which must be real Lua, not prose) in a first-class field.

const std = @import("std");

/// The Lua-visible type of a parameter or return. Drives both the help panel
/// and the stub annotations (`---@param`), so the two can never disagree.
pub const Kind = enum {
    number,
    integer,
    string,
    boolean,
    vec2,
    rect2,
    actor,
    any,

    pub fn luaName(self: Kind) []const u8 {
        return switch (self) {
            .number => "number",
            .integer => "integer",
            .string => "string",
            .boolean => "boolean",
            .vec2 => "Vec2",
            .rect2 => "Rect2",
            .actor => "Actor",
            .any => "any",
        };
    }
};

/// One parameter: its Lua name, its type, an optional default (rendered in the
/// signature and the stub) and an optional per-parameter note.
pub const Param = struct {
    name: []const u8,
    kind: Kind,
    default: ?[]const u8 = null,
    doc: []const u8 = "",
};

/// One return value: its type and an optional description.
pub const Return = struct {
    kind: Kind,
    doc: []const u8 = "",
};

/// One documented binding. `name` is the fully-qualified Lua name
/// (`"actor.get_position"`, `"math.clamp"`); `module` groups it for the stubs
/// and the docs index.
pub const Binding = struct {
    name: []const u8,
    module: []const u8,
    /// Human-readable signature, e.g. `"get_position(self) -> number, number"`.
    signature: []const u8,
    /// One-line description shown in the tooltip and the docs index.
    summary: []const u8,
    params: []const Param = &.{},
    /// Typed return values; empty slice when the function returns nothing.
    returns: []const Return = &.{},
    /// A complete, runnable Lua snippet. Must be real Lua: the M3 criterion is
    /// "every API exposed to Lua has metadata + example".
    example: []const u8,
};

// ── The registry ─────────────────────────────────────────────────────────────

/// Every binding the engine hands to Lua, documented. Append-only: order is the
/// order the docs index and the stubs list them in, and `bindings.zig` asserts
/// this set and its own registration are identical (no drift, no undocumented
/// binding).
///
/// The examples are real Lua and are the M3 acceptance criterion: "every API
/// exposed to Lua has metadata + example". They are also the only place the
/// argument shapes are pinned down (e.g. `vec2.dist` accepting either two vec2
/// tables or four numbers), so keep them honest when a signature changes.
pub const bindings = [_]Binding{
    // ── actor: the per-behavior `self` surface ──────────────────────────────
    .{
        .name = "actor.get_position",
        .module = "actor",
        .signature = "actor.get_position(self) -> number, number",
        .summary = "World-space position of this actor as x, y.",
        .params = &.{.{ .name = "self", .kind = .actor }},
        .returns = &.{
            .{ .kind = .number, .doc = "x in world units (pixels unless the game scales them)" },
            .{ .kind = .number, .doc = "y in world units" },
        },
        .example =
        \\local x, y = actor.get_position(self)
        \\log.info("player at " .. x .. ", " .. y)
        ,
    },
    .{
        .name = "actor.set_position",
        .module = "actor",
        .signature = "actor.set_position(self, x, y)",
        .summary = "Sets the world-space position of this actor.",
        .params = &.{
            .{ .name = "self", .kind = .actor },
            .{ .name = "x", .kind = .number },
            .{ .name = "y", .kind = .number },
        },
        .returns = &.{},
        .example =
        \\actor.set_position(self, 100, 200)
        ,
    },
    .{
        .name = "actor.translate",
        .module = "actor",
        .signature = "actor.translate(self, dx, dy)",
        .summary = "Moves the actor by a delta, relative to its current position.",
        .params = &.{
            .{ .name = "self", .kind = .actor },
            .{ .name = "dx", .kind = .number },
            .{ .name = "dy", .kind = .number },
        },
        .returns = &.{},
        .example =
        \\-- move right by 5 units this frame
        \\actor.translate(self, 5, 0)
        ,
    },
    .{
        .name = "actor.move_by",
        .module = "actor",
        .signature = "actor.move_by(self, dx, dy)",
        .summary = "Read-modify-write move: adds a delta to the actor's position in ONE call.",
        .params = &.{
            .{ .name = "self", .kind = .actor },
            .{ .name = "dx", .kind = .number },
            .{ .name = "dy", .kind = .number },
        },
        .returns = &.{},
        .example =
        \\-- the fast way to move: one Lua->C call instead of two
        \\actor.move_by(self, math.cos(self.heading) * 120 * dt, math.sin(self.heading) * 120 * dt)
        ,
    },
    .{
        .name = "actor.get_rotation",
        .module = "actor",
        .signature = "actor.get_rotation(self) -> number",
        .summary = "Rotation of this actor in radians (clockwise on screen).",
        .params = &.{.{ .name = "self", .kind = .actor }},
        .returns = &.{
            .{ .kind = .number, .doc = "angle in radians" },
        },
        .example =
        \\local angle = actor.get_rotation(self)
        \\log.info("heading: " .. math.round(math.rad_to_deg(angle)) .. "°")
        ,
    },
    .{
        .name = "actor.set_rotation",
        .module = "actor",
        .signature = "actor.set_rotation(self, radians)",
        .summary = "Sets the rotation of this actor, in radians.",
        .params = &.{
            .{ .name = "self", .kind = .actor },
            .{ .name = "radians", .kind = .number, .doc = "angle in radians (positive = clockwise on screen)" },
        },
        .returns = &.{},
        .example =
        \\actor.set_rotation(self, math.rad_to_deg(90))
        ,
    },
    .{
        .name = "actor.get_name",
        .module = "actor",
        .signature = "actor.get_name(self) -> string",
        .summary = "The Name component of this actor, or an empty string when it has none.",
        .params = &.{.{ .name = "self", .kind = .actor }},
        .returns = &.{
            .{ .kind = .string, .doc = "the actor's name, or empty string" },
        },
        .example =
        \\log.info("hello from " .. actor.get_name(self))
        ,
    },
    .{
        .name = "actor.emit",
        .module = "actor",
        .signature = "actor.emit(self, event)",
        .summary = "Queues a signal on this actor; listeners run on the next drain, in stable spawn order.",
        .params = &.{
            .{ .name = "self", .kind = .actor },
            .{ .name = "event", .kind = .string, .doc = "signal name, matched by listeners on the same name" },
        },
        .returns = &.{},
        .example =
        \\actor.emit(self, "hit")   -- a listener's on_signal("hit") fires next drain
        ,
    },
    .{
        .name = "actor.get_half_size",
        .module = "actor",
        .signature = "actor.get_half_size(self) -> number, number",
        .summary = "Half the sprite's extent: the half-width and half-height of what is drawn.",
        .params = &.{.{ .name = "self", .kind = .actor }},
        .returns = &.{
            .{ .kind = .number, .doc = "half width (0 if no Sprite component)" },
            .{ .kind = .number, .doc = "half height (0 if no Sprite component)" },
        },
        .example =
        \\local hw, hh = actor.get_half_size(self)
        \\-- a point test with no rect needed:
        \\local inside = math.abs(click_x - self.px) <= hw
        ,
    },
    // ── actor: spatial queries between actors ──────────────────────────────
    .{
        .name = "actor.distance_to",
        .module = "actor",
        .signature = "actor.distance_to(self, other) -> number",
        .summary = "Distance between this actor and another, in world units (pixels by default).",
        .params = &.{
            .{ .name = "self", .kind = .actor },
            .{ .name = "other", .kind = .actor, .doc = "any other behavior's self table" },
        },
        .returns = &.{
            .{ .kind = .number, .doc = "distance in world units" },
        },
        .example =
        \\local d = actor.distance_to(self, other)
        \\if d < 50 then log.info("too close!") end
        ,
    },
    .{
        .name = "actor.distance_to_point",
        .module = "actor",
        .signature = "actor.distance_to_point(self, x, y) -> number",
        .summary = "Distance from this actor to a bare point (a click, a marker, a waypoint).",
        .params = &.{
            .{ .name = "self", .kind = .actor },
            .{ .name = "x", .kind = .number },
            .{ .name = "y", .kind = .number },
        },
        .returns = &.{
            .{ .kind = .number, .doc = "distance in world units" },
        },
        .example =
        \\local d = actor.distance_to_point(self, 640, 360)
        \\log.info("dist to center: " .. math.round(d))
        ,
    },
    .{
        .name = "actor.distance_squared_to",
        .module = "actor",
        .signature = "actor.distance_squared_to(self, other) -> number",
        .summary = "Squared distance: the comparison form, with no square root.",
        .params = &.{
            .{ .name = "self", .kind = .actor },
            .{ .name = "other", .kind = .actor },
        },
        .returns = &.{
            .{ .kind = .number, .doc = "distance squared; compare against radius*radius" },
        },
        .example =
        \\-- "is it within 100 units?" without a sqrt
        \\if actor.distance_squared_to(self, other) <= 100 * 100 then end
        ,
    },
    .{
        .name = "actor.is_within_radius",
        .module = "actor",
        .signature = "actor.is_within_radius(self, other, radius) -> boolean",
        .summary = "True when the other actor is within `radius` world units of this one.",
        .params = &.{
            .{ .name = "self", .kind = .actor },
            .{ .name = "other", .kind = .actor },
            .{ .name = "radius", .kind = .number },
        },
        .returns = &.{
            .{ .kind = .boolean, .doc = "true if within radius, false otherwise" },
        },
        .example =
        \\if actor.is_within_radius(self, other, 200) then
        \\  log.info("close!")
        \\end
        ,
    },
    .{
        .name = "actor.is_within_radius_of_point",
        .module = "actor",
        .signature = "actor.is_within_radius_of_point(self, x, y, radius) -> boolean",
        .summary = "True when a bare point is within `radius` of this actor.",
        .params = &.{
            .{ .name = "self", .kind = .actor },
            .{ .name = "x", .kind = .number },
            .{ .name = "y", .kind = .number },
            .{ .name = "radius", .kind = .number },
        },
        .returns = &.{
            .{ .kind = .boolean, .doc = "true if point is within radius" },
        },
        .example =
        \\-- was this actor clicked?
        \\if actor.is_within_radius_of_point(self, mouse_x, mouse_y, 64) then
        \\  actor.emit(self, "clicked")
        \\end
        ,
    },
    .{
        .name = "actor.direction_to",
        .module = "actor",
        .signature = "actor.direction_to(self, other) -> number, number",
        .summary = "Unit vector pointing from this actor to the other.",
        .params = &.{
            .{ .name = "self", .kind = .actor },
            .{ .name = "other", .kind = .actor },
        },
        .returns = &.{
            .{ .kind = .number, .doc = "dx in [-1, 1]; 0 when actors coincide" },
            .{ .kind = .number, .doc = "dy in [-1, 1]; 0 when actors coincide" },
        },
        .example =
        \\local dx, dy = actor.direction_to(self, other)
        \\actor.move_by(self, dx * 60 * dt, dy * 60 * dt)
        ,
    },
    .{
        .name = "actor.angle_to",
        .module = "actor",
        .signature = "actor.angle_to(self, other) -> number",
        .summary = "Angle from this actor to the other, relative to +X; positive is clockwise.",
        .params = &.{
            .{ .name = "self", .kind = .actor },
            .{ .name = "other", .kind = .actor },
        },
        .returns = &.{
            .{ .kind = .number, .doc = "angle in radians" },
        },
        .example =
        \\actor.set_rotation(self, actor.angle_to(self, other))  -- face the player
        ,
    },

    // ── math: the scalar set ───────────────────────────────────────────────
    .{
        .name = "math.clamp",
        .module = "math",
        .signature = "math.clamp(v, lo, hi) -> number",
        .summary = "Clamps `v` into the range `[lo, hi]`.",
        .params = &.{
            .{ .name = "v", .kind = .number, .doc = "value to clamp" },
            .{ .name = "lo", .kind = .number, .doc = "minimum allowed value" },
            .{ .name = "hi", .kind = .number, .doc = "maximum allowed value" },
        },
        .returns = &.{ .{ .kind = .number, .doc = "`v` constrained to [lo, hi]" } },
        .example =
        \\self.hp = math.clamp(self.hp - damage, 0, self.max_hp)
        ,
    },
    .{
        .name = "math.min",
        .module = "math",
        .signature = "math.min(a, b) -> number",
        .summary = "The smaller of two numbers.",
        .params = &.{ .{ .name = "a", .kind = .number }, .{ .name = "b", .kind = .number } },
        .returns = &.{ .{ .kind = .number, .doc = "the lesser of `a` and `b`" } },
        .example =
        \\local steps = math.min(self.queue_len, 4)
        ,
    },
    .{
        .name = "math.max",
        .module = "math",
        .signature = "math.max(a, b) -> number",
        .summary = "The larger of two numbers.",
        .params = &.{ .{ .name = "a", .kind = .number }, .{ .name = "b", .kind = .number } },
        .returns = &.{ .{ .kind = .number, .doc = "the greater of `a` and `b`" } },
        .example =
        \\local scale = math.max(1, self.level * 0.5)
        ,
    },
    .{
        .name = "math.abs",
        .module = "math",
        .signature = "math.abs(v) -> number",
        .summary = "Absolute value: the distance from zero, always >= 0.",
        .params = &.{.{ .name = "v", .kind = .number, .doc = "any number; the sign is discarded" }},
        .returns = &.{ .{ .kind = .number, .doc = "`v` without its sign" } },
        .example =
        \\local overshoot = math.abs(self.best - self.time)
        ,
    },
    .{
        .name = "math.sign",
        .module = "math",
        .signature = "math.sign(v) -> number",
        .summary = "The sign of `v`: -1, 0 or +1 (zero maps to 0, not +1).",
        .params = &.{.{ .name = "v", .kind = .number }},
        .returns = &.{ .{ .kind = .number, .doc = "-1, 0 or +1" } },
        .example =
        \\actor.move_by(self, math.sign(self.vx) * 10, 0)
        ,
    },
    .{
        .name = "math.floor",
        .module = "math",
        .signature = "math.floor(v) -> number",
        .summary = "Largest integer not greater than `v`.",
        .params = &.{.{ .name = "v", .kind = .number }},
        .returns = &.{ .{ .kind = .integer, .doc = "the integral float floor of `v`" } },
        .example =
        \\self.row = math.floor(self.index / self.cols)
        ,
    },
    .{
        .name = "math.ceil",
        .module = "math",
        .signature = "math.ceil(v) -> number",
        .summary = "Smallest integer not less than `v`.",
        .params = &.{.{ .name = "v", .kind = .number }},
        .returns = &.{ .{ .kind = .integer, .doc = "the integral float ceil of `v`" } },
        .example =
        \\local pages = math.ceil(self.items / self.per_page)
        ,
    },
    .{
        .name = "math.round",
        .module = "math",
        .signature = "math.round(v) -> number",
        .summary = "Nearest integer, halves away from zero (not banker's rounding).",
        .params = &.{.{ .name = "v", .kind = .number, .doc = "any finite number" }},
        .returns = &.{ .{ .kind = .integer, .doc = "nearest integral float; .5 rounds away from zero" } },
        .example =
        \\log.info("score: " .. math.round(self.score))
        ,
    },
    .{
        .name = "math.fract",
        .module = "math",
        .signature = "math.fract(v) -> number",
        .summary = "Fractional part of `v`, always in [0, 1) regardless of sign.",
        .params = &.{.{ .name = "v", .kind = .number, .doc = "any number; the integer part is discarded" }},
        .returns = &.{ .{ .kind = .number, .doc = "fractional part in [0, 1)" } },
        .example =
        \\local pulse = math.fract(self.t)   -- 0..1 sawtooth
        ,
    },
    .{
        .name = "math.sqrt",
        .module = "math",
        .signature = "math.sqrt(v) -> number",
        .summary = "Square root.",
        .params = &.{.{ .name = "v", .kind = .number, .doc = "non-negative value" }},
        .returns = &.{ .{ .kind = .number, .doc = "the non-negative square root" } },
        .example =
        \\local speed = math.sqrt(self.vx * self.vx + self.vy * self.vy)
        ,
    },
    .{
        .name = "math.pow",
        .module = "math",
        .signature = "math.pow(base, exp) -> number",
        .summary = "`base` raised to `exp`.",
        .params = &.{
            .{ .name = "base", .kind = .number, .doc = "the base" },
            .{ .name = "exp", .kind = .number, .doc = "the exponent" },
        },
        .returns = &.{ .{ .kind = .number, .doc = "base^exp" } },
        .example =
        \\local damage = 10 * math.pow(2, self.combo)
        ,
    },
    .{
        .name = "math.sin",
        .module = "math",
        .signature = "math.sin(radians) -> number",
        .summary = "Sine of an angle in radians.",
        .params = &.{.{ .name = "radians", .kind = .number, .doc = "angle in radians" }},
        .returns = &.{ .{ .kind = .number, .doc = "sine of the angle, in [-1, 1]" } },
        .example =
        \\local bob = math.sin(self.t * 2) * 8
        ,
    },
    .{
        .name = "math.cos",
        .module = "math",
        .signature = "math.cos(radians) -> number",
        .summary = "Cosine of an angle in radians.",
        .params = &.{.{ .name = "radians", .kind = .number, .doc = "angle in radians" }},
        .returns = &.{ .{ .kind = .number, .doc = "cosine of the angle, in [-1, 1]" } },
        .example =
        \\local phase = math.cos(self.t * 2)
        ,
    },
    .{
        .name = "math.atan2",
        .module = "math",
        .signature = "math.atan2(y, x) -> number",
        .summary = "Two-argument arctangent: the angle of the point (x, y).",
        .params = &.{
            .{ .name = "y", .kind = .number, .doc = "y component" },
            .{ .name = "x", .kind = .number, .doc = "x component" },
        },
        .returns = &.{ .{ .kind = .number, .doc = "angle in radians, in (-pi, pi]" } },
        .example =
        \\local heading = math.atan2(dy, dx)
        ,
    },
    .{
        .name = "math.lerp",
        .module = "math",
        .signature = "math.lerp(a, b, t) -> number",
        .summary = "Linear blend: `a` at t=0, `b` at t=1.",
        .params = &.{
            .{ .name = "a", .kind = .number, .doc = "value at t=0" },
            .{ .name = "b", .kind = .number, .doc = "value at t=1" },
            .{ .name = "t", .kind = .number, .doc = "blend factor, usually 0..1" },
        },
        .returns = &.{ .{ .kind = .number, .doc = "a*(1-t) + b*t" } },
        .example =
        \\self.charge = math.lerp(self.charge, 1, 0.1)
        ,
    },
    .{
        .name = "math.inverse_lerp",
        .module = "math",
        .signature = "math.inverse_lerp(a, b, v) -> number",
        .summary = "Where `v` falls between `a` and `b`, as 0..1 (can leave the range).",
        .params = &.{
            .{ .name = "a", .kind = .number, .doc = "start of the range" },
            .{ .name = "b", .kind = .number, .doc = "end of the range" },
            .{ .name = "v", .kind = .number, .doc = "value to locate within the range" },
        },
        .returns = &.{ .{ .kind = .number, .doc = "0 at a, 1 at b; may go outside 0..1" } },
        .example =
        \\local progress = math.inverse_lerp(self.from_x, self.to_x, self.x)
        ,
    },
    .{
        .name = "math.remap",
        .module = "math",
        .signature = "math.remap(v, in_lo, in_hi, out_lo, out_hi) -> number",
        .summary = "Maps `v` from one range to another.",
        .params = &.{
            .{ .name = "v", .kind = .number, .doc = "value to remap" },
            .{ .name = "in_lo", .kind = .number, .doc = "input range minimum" },
            .{ .name = "in_hi", .kind = .number, .doc = "input range maximum" },
            .{ .name = "out_lo", .kind = .number, .doc = "output range minimum" },
            .{ .name = "out_hi", .kind = .number, .doc = "output range maximum" },
        },
        .returns = &.{ .{ .kind = .number, .doc = "`v` mapped to the output range" } },
        .example =
        \\-- health 0..100 -> a bar's 0..200 pixel width
        \\self.bar_w = math.remap(self.hp, 0, 100, 0, 200)
        ,
    },
    .{
        .name = "math.smoothstep",
        .module = "math",
        .signature = "math.smoothstep(edge0, edge1, v) -> number",
        .summary = "Hermite ease: 0 below `edge0`, 1 above `edge1`, smooth between.",
        .params = &.{
            .{ .name = "edge0", .kind = .number, .doc = "lower edge of the transition" },
            .{ .name = "edge1", .kind = .number, .doc = "upper edge of the transition" },
            .{ .name = "v", .kind = .number, .doc = "value to evaluate" },
        },
        .returns = &.{ .{ .kind = .number, .doc = "smooth 0..1 blend based on where `v` sits" } },
        .example =
        \\local glow = math.smoothstep(100, 400, self.dist)
        ,
    },
    .{
        .name = "math.step",
        .module = "math",
        .signature = "math.step(edge, v) -> number",
        .summary = "Hard threshold: 0 below `edge`, 1 at or above it.",
        .params = &.{
            .{ .name = "edge", .kind = .number, .doc = "threshold value" },
            .{ .name = "v", .kind = .number, .doc = "value to test" },
        },
        .returns = &.{ .{ .kind = .number, .doc = "0 if v < edge, 1 otherwise" } },
        .example =
        \\self.lit = math.step(0.5, self.darkness)
        ,
    },
    .{
        .name = "math.move_toward",
        .module = "math",
        .signature = "math.move_toward(current, target, max_delta) -> number",
        .summary = "Moves `current` toward `target` by at most `max_delta` (never overshoots).",
        .params = &.{
            .{ .name = "current", .kind = .number, .doc = "starting value" },
            .{ .name = "target", .kind = .number, .doc = "value to move toward" },
            .{ .name = "max_delta", .kind = .number, .doc = "maximum step per frame" },
        },
        .returns = &.{ .{ .kind = .number, .doc = "`current` moved toward `target`, clamped to max_delta" } },
        .example =
        \\self.x = math.move_toward(self.x, self.target_x, 200 * dt)
        ,
    },
    .{
        .name = "math.damp",
        .module = "math",
        .signature = "math.damp(a, b, rate, dt) -> number",
        .summary = "Frame-rate independent smoothing toward `b`; prefer it over a raw lerp.",
        .params = &.{
            .{ .name = "a", .kind = .number, .doc = "current value" },
            .{ .name = "b", .kind = .number, .doc = "target value" },
            .{ .name = "rate", .kind = .number, .doc = "time constant; larger is slower" },
            .{ .name = "dt", .kind = .number, .doc = "delta time in seconds" },
        },
        .returns = &.{ .{ .kind = .number, .doc = "smoothed value between `a` and `b`" } },
        .example =
        \\self.x = math.damp(self.x, self.target_x, 8, dt)
        ,
    },
    .{
        .name = "math.wrap",
        .module = "math",
        .signature = "math.wrap(v, lo, hi) -> number",
        .summary = "Wraps `v` into `[lo, hi)` (a modulo with a live floor).",
        .params = &.{
            .{ .name = "v", .kind = .number, .doc = "value to wrap" },
            .{ .name = "lo", .kind = .number, .doc = "lower bound (inclusive)" },
            .{ .name = "hi", .kind = .number, .doc = "upper bound (exclusive)" },
        },
        .returns = &.{ .{ .kind = .number, .doc = "`v` wrapped into [lo, hi)" } },
        .example =
        \\self.lap = self.lap + 1
        \\self.t = math.wrap(self.t, 0, 1)
        ,
    },
    .{
        .name = "math.pingpong",
        .module = "math",
        .signature = "math.pingpong(v, length) -> number",
        .summary = "Triangle wave bouncing between 0 and `length` (period 2*length).",
        .params = &.{
            .{ .name = "v", .kind = .number, .doc = "time or phase value" },
            .{ .name = "length", .kind = .number, .doc = "maximum value before bouncing back" },
        },
        .returns = &.{ .{ .kind = .number, .doc = "triangle wave between 0 and length" } },
        .example =
        \\local sway = math.pingpong(self.t, 40)   -- 0..40..0..40
        ,
    },
    .{
        .name = "math.deg_to_rad",
        .module = "math",
        .signature = "math.deg_to_rad(degrees) -> number",
        .summary = "Degrees to radians.",
        .params = &.{.{ .name = "degrees", .kind = .number, .doc = "angle in degrees" }},
        .returns = &.{ .{ .kind = .number, .doc = "the same angle in radians" } },
        .example =
        \\actor.set_rotation(self, math.deg_to_rad(45))
        ,
    },
    .{
        .name = "math.rad_to_deg",
        .module = "math",
        .signature = "math.rad_to_deg(radians) -> number",
        .summary = "Radians to degrees.",
        .params = &.{.{ .name = "radians", .kind = .number, .doc = "angle in radians" }},
        .returns = &.{ .{ .kind = .number, .doc = "the same angle in degrees" } },
        .example =
        \\log.info("heading: " .. math.rad_to_deg(actor.get_rotation(self)))
        ,
    },
    .{
        .name = "math.is_close",
        .module = "math",
        .signature = "math.is_close(a, b, tolerance) -> boolean",
        .summary = "True when `a` and `b` differ by at most `tolerance`.",
        .params = &.{
            .{ .name = "a", .kind = .number, .doc = "first value" },
            .{ .name = "b", .kind = .number, .doc = "second value" },
            .{ .name = "tolerance", .kind = .number, .doc = "maximum acceptable difference" },
        },
        .returns = &.{ .{ .kind = .boolean, .doc = "true when |a-b| <= tolerance" } },
        .example =
        \\if math.is_close(self.x, self.target_x, 0.01) then self.x = self.target_x end
        ,
    },

    // ── vec2: the spatial set ──────────────────────────────────────────────
    .{
        .name = "vec2.new",
        .module = "vec2",
        .signature = "vec2.new(x, y) -> Vec2",
        .summary = "Builds a vector table. Allocates: use it for state, not inside a hot loop.",
        .params = &.{
            .{ .name = "x", .kind = .number, .default = "0" },
            .{ .name = "y", .kind = .number, .default = "0" },
        },
        .returns = &.{ .{ .kind = .vec2, .doc = "a table with `x` and `y` fields" } },
        .example =
        \\self.target = vec2.new(100, 200)
        ,
    },
    .{
        .name = "vec2.to_vec",
        .module = "vec2",
        .signature = "vec2.to_vec(x, y) -> Vec2",
        .summary = "The width-explicit constructor: identical to `vec2.new`, spelled for clarity.",
        .params = &.{
            .{ .name = "x", .kind = .number, .doc = "x component" },
            .{ .name = "y", .kind = .number, .doc = "y component" },
        },
        .returns = &.{ .{ .kind = .vec2, .doc = "a table with `x` and `y` fields" } },
        .example =
        \\local forward = vec2.to_vec(math.cos(a), math.sin(a))
        ,
    },
    .{
        .name = "vec2.dist",
        .module = "vec2",
        .signature = "vec2.dist(ax, ay, bx, by) -> number",
        .summary = "Distance between two points. Accepts either four numbers or two Vec2 tables.",
        .params = &.{
            .{ .name = "ax", .kind = .number, .doc = "first point x (or a Vec2 table)" },
            .{ .name = "ay", .kind = .number, .doc = "first point y (or a Vec2 table)" },
            .{ .name = "bx", .kind = .number, .doc = "second point x (or a Vec2 table)" },
            .{ .name = "by", .kind = .number, .doc = "second point y (or a Vec2 table)" },
        },
        .returns = &.{ .{ .kind = .number, .doc = "distance" } },
        .example =
        \\local d = vec2.dist(self.x, self.y, other_x, other_y)
        \\-- or, with tables:
        \\local d2 = vec2.dist(self.pos, other.pos)
        ,
    },
    .{
        .name = "vec2.dist_sq",
        .module = "vec2",
        .signature = "vec2.dist_sq(ax, ay, bx, by) -> number",
        .summary = "Squared distance: the comparison form, no square root.",
        .params = &.{
            .{ .name = "ax", .kind = .number, .doc = "first point x (or a Vec2 table)" },
            .{ .name = "ay", .kind = .number, .doc = "first point y (or a Vec2 table)" },
            .{ .name = "bx", .kind = .number, .doc = "second point x (or a Vec2 table)" },
            .{ .name = "by", .kind = .number, .doc = "second point y (or a Vec2 table)" },
        },
        .returns = &.{ .{ .kind = .number, .doc = "distance squared" } },
        .example =
        \\if vec2.dist_sq(self.x, self.y, px, py) <= r * r then end
        ,
    },
    .{
        .name = "vec2.length",
        .module = "vec2",
        .signature = "vec2.length(v) -> number",
        .summary = "Length of a vector (also accepts `x, y` as two numbers).",
        .params = &.{.{ .name = "v", .kind = .vec2, .doc = "a Vec2 table or x, y as two numbers" }},
        .returns = &.{ .{ .kind = .number, .doc = "length; 0 for the zero vector" } },
        .example =
        \\local speed = vec2.length(self.vel)
        ,
    },
    .{
        .name = "vec2.length_sq",
        .module = "vec2",
        .signature = "vec2.length_sq(v) -> number",
        .summary = "Squared length: the comparison form, no square root.",
        .params = &.{.{ .name = "v", .kind = .vec2, .doc = "a Vec2 table" }},
        .returns = &.{ .{ .kind = .number, .doc = "length squared" } },
        .example =
        \\if vec2.length_sq(self.vel) > self.max_speed * self.max_speed then end
        ,
    },
    .{
        .name = "vec2.normalized",
        .module = "vec2",
        .signature = "vec2.normalized(v) -> Vec2",
        .summary = "The vector scaled to length 1; the zero vector maps to zero (never NaN).",
        .params = &.{.{ .name = "v", .kind = .vec2, .doc = "a Vec2 table" }},
        .returns = &.{ .{ .kind = .vec2, .doc = "a unit vector (length 1); zero maps to zero" } },
        .example =
        \\local dir = vec2.normalized(vec2.new(dx, dy))
        ,
    },
    .{
        .name = "vec2.direction",
        .module = "vec2",
        .signature = "vec2.direction(ax, ay, bx, by) -> Vec2",
        .summary = "Unit vector pointing from one point to another.",
        .params = &.{
            .{ .name = "ax", .kind = .number, .doc = "origin point x" },
            .{ .name = "ay", .kind = .number, .doc = "origin point y" },
            .{ .name = "bx", .kind = .number, .doc = "target point x" },
            .{ .name = "by", .kind = .number, .doc = "target point y" },
        },
        .returns = &.{ .{ .kind = .vec2, .doc = "a unit vector; (0,0) when the points coincide" } },
        .example =
        \\local to_ball = vec2.direction(self.x, self.y, ball_x, ball_y)
        ,
    },
    .{
        .name = "vec2.lerp",
        .module = "vec2",
        .signature = "vec2.lerp(a, b, t) -> Vec2",
        .summary = "Blends two vectors: `a` at t=0, `b` at t=1.",
        .params = &.{
            .{ .name = "a", .kind = .vec2, .doc = "value at t=0" },
            .{ .name = "b", .kind = .vec2, .doc = "value at t=1" },
            .{ .name = "t", .kind = .number, .doc = "blend factor, usually 0..1" },
        },
        .returns = &.{ .{ .kind = .vec2, .doc = "the blended vector" } },
        .example =
        \\self.pos = vec2.lerp(self.pos, self.target, 0.1)
        ,
    },
    .{
        .name = "vec2.dot",
        .module = "vec2",
        .signature = "vec2.dot(a, b) -> number",
        .summary = "Dot product: how much two vectors point the same way.",
        .params = &.{
            .{ .name = "a", .kind = .vec2, .doc = "first vector" },
            .{ .name = "b", .kind = .vec2, .doc = "second vector" },
        },
        .returns = &.{ .{ .kind = .number, .doc = "the dot product" } },
        .example =
        \\if vec2.dot(self.dir, vec2.normalized(to_player)) > 0.9 then end  -- in the cone
        ,
    },
    .{
        .name = "vec2.cross",
        .module = "vec2",
        .signature = "vec2.cross(a, b) -> number",
        .summary = "2D cross product; the sign is the orientation test between the vectors.",
        .params = &.{
            .{ .name = "a", .kind = .vec2, .doc = "first vector" },
            .{ .name = "b", .kind = .vec2, .doc = "second vector" },
        },
        .returns = &.{ .{ .kind = .number, .doc = "the scalar cross (z of the 3D cross); positive when b is clockwise from a" } },
        .example =
        \\local side = vec2.cross(self.dir, to_player)   -- + or -
        ,
    },
    .{
        .name = "vec2.angle",
        .module = "vec2",
        .signature = "vec2.angle(v) -> number",
        .summary = "Angle of a vector in radians, relative to +X.",
        .params = &.{.{ .name = "v", .kind = .vec2, .doc = "a Vec2 table" }},
        .returns = &.{ .{ .kind = .number, .doc = "angle in radians" } },
        .example =
        \\local heading = vec2.angle(self.vel)
        ,
    },
    .{
        .name = "vec2.angle_between",
        .module = "vec2",
        .signature = "vec2.angle_between(a, b) -> number",
        .summary = "Signed angle from `a` to `b` in radians; positive is clockwise.",
        .params = &.{
            .{ .name = "a", .kind = .vec2, .doc = "first vector" },
            .{ .name = "b", .kind = .vec2, .doc = "second vector" },
        },
        .returns = &.{ .{ .kind = .number, .doc = "signed angle in (-pi, pi]" } },
        .example =
        \\local turn = vec2.angle_between(self.dir, to_target)
        ,
    },
    .{
        .name = "vec2.rotate",
        .module = "vec2",
        .signature = "vec2.rotate(v, radians) -> Vec2",
        .summary = "Rotates a vector by an angle (positive is clockwise on screen).",
        .params = &.{
            .{ .name = "v", .kind = .vec2, .doc = "vector to rotate" },
            .{ .name = "radians", .kind = .number, .doc = "rotation angle in radians (positive = clockwise)" },
        },
        .returns = &.{ .{ .kind = .vec2, .doc = "the rotated vector" } },
        .example =
        \\local aim = vec2.rotate(vec2.new(1, 0), math.deg_to_rad(30))
        ,
    },
    .{
        .name = "vec2.perpendicular",
        .module = "vec2",
        .signature = "vec2.perpendicular(v) -> Vec2",
        .summary = "The 90-degree rotation of a vector: a wall normal from a direction.",
        .params = &.{.{ .name = "v", .kind = .vec2, .doc = "a Vec2 table" }},
        .returns = &.{ .{ .kind = .vec2, .doc = "the perpendicular vector (90° clockwise rotation)" } },
        .example =
        \\local normal = vec2.perpendicular(vec2.normalized(self.edge))
        ,
    },
    .{
        .name = "vec2.clamp_length",
        .module = "vec2",
        .signature = "vec2.clamp_length(v, max_len) -> Vec2",
        .summary = "Caps the LENGTH of a vector (direction preserved).",
        .params = &.{
            .{ .name = "v", .kind = .vec2, .doc = "vector to clamp" },
            .{ .name = "max_len", .kind = .number, .doc = "maximum length" },
        },
        .returns = &.{ .{ .kind = .vec2, .doc = "the capped vector" } },
        .example =
        \\self.vel = vec2.clamp_length(self.vel, self.max_speed)
        ,
    },
    .{
        .name = "vec2.clamped",
        .module = "vec2",
        .signature = "vec2.clamped(v, max_len) -> Vec2",
        .summary = "Godot's spelling of `clamp_length`; identical behaviour.",
        .params = &.{
            .{ .name = "v", .kind = .vec2, .doc = "vector to clamp" },
            .{ .name = "max_len", .kind = .number, .doc = "maximum length" },
        },
        .returns = &.{ .{ .kind = .vec2, .doc = "the capped vector" } },
        .example =
        \\self.push = vec2.clamped(self.push, 5)
        ,
    },
    .{
        .name = "vec2.reflect",
        .module = "vec2",
        .signature = "vec2.reflect(d, n) -> Vec2",
        .summary = "Bounce: mirrors an incoming direction around a unit normal.",
        .params = &.{
            .{ .name = "d", .kind = .vec2, .doc = "incoming direction" },
            .{ .name = "n", .kind = .vec2, .doc = "unit normal of the surface" },
        },
        .returns = &.{ .{ .kind = .vec2, .doc = "the reflected direction" } },
        .example =
        \\-- the ball off a wall (normal points at the ball)
        \\self.vel = vec2.reflect(self.vel, vec2.new(1, 0))
        ,
    },
    .{
        .name = "vec2.from_angle",
        .module = "vec2",
        .signature = "vec2.from_angle(radians) -> Vec2",
        .summary = "Unit vector at an angle (Godot's `Vector2.from_angle`).",
        .params = &.{.{ .name = "radians", .kind = .number, .doc = "angle in radians" }},
        .returns = &.{ .{ .kind = .vec2, .doc = "a unit vector pointing at the given angle" } },
        .example =
        \\local muzzle = vec2.from_angle(actor.get_rotation(self))
        ,
    },

    // ── rand: deterministic randomness (M4.5) ─────────────────────────────
    // One sequence per runtime, restarted by `rand.seed`. Same seed, same draws,
    // every run — that is the engine's determinism contract (spec §6) reaching
    // gameplay code, and it is what makes a bug report replayable.
    .{
        .name = "rand.seed",
        .module = "rand",
        .signature = "rand.seed(n)",
        .summary = "Restarts the random sequence so the same seed replays the same draws.",
        .params = &.{.{ .name = "n", .kind = .integer, .doc = "seed value; any integer" }},
        .returns = &.{},
        .example =
        \\rand.seed(1234)          -- from here on, everything is reproducible
        \\local d1 = rand.float(0, 100)
        \\rand.seed(1234)
        \\local d2 = rand.float(0, 100)   -- d1 == d2, every time
        ,
    },
    .{
        .name = "rand.float",
        .module = "rand",
        .signature = "rand.float(lo, hi) -> number",
        .summary = "A uniform float in `[lo, hi)`.",
        .params = &.{
            .{ .name = "lo", .kind = .number, .doc = "inclusive lower bound" },
            .{ .name = "hi", .kind = .number, .doc = "exclusive upper bound" },
        },
        .returns = &.{ .{ .kind = .number, .doc = "a random number in [lo, hi)" } },
        .example =
        \\local jitter = rand.float(-10, 10)   -- spread an object a little
        ,
    },
    .{
        .name = "rand.range",
        .module = "rand",
        .signature = "rand.range(lo, hi) -> number",
        .summary = "The Godot/Unity spelling of `rand.float`; identical behaviour.",
        .params = &.{
            .{ .name = "lo", .kind = .number, .doc = "inclusive lower bound" },
            .{ .name = "hi", .kind = .number, .doc = "exclusive upper bound" },
        },
        .returns = &.{ .{ .kind = .number, .doc = "a random number in [lo, hi)" } },
        .example =
        \\local damage = rand.range(8, 14)   -- 8..13.99
        ,
    },
    .{
        .name = "rand.int",
        .module = "rand",
        .signature = "rand.int(lo, hi) -> integer",
        .summary = "A uniform integer in `[lo, hi]`, both ends inclusive.",
        .params = &.{
            .{ .name = "lo", .kind = .integer, .doc = "inclusive lower bound" },
            .{ .name = "hi", .kind = .integer, .doc = "inclusive upper bound" },
        },
        .returns = &.{ .{ .kind = .integer, .doc = "a random integer in [lo, hi]" } },
        .example =
        \\local roll = rand.int(1, 6)   -- a d6; 1 and 6 are both reachable
        ,
    },
    .{
        .name = "rand.chance",
        .module = "rand",
        .signature = "rand.chance(p) -> boolean",
        .summary = "True with probability `p`. `p <= 0` never fires, `p >= 1` always does.",
        .params = &.{.{ .name = "p", .kind = .number, .doc = "probability, 0..1" }},
        .returns = &.{ .{ .kind = .boolean, .doc = "true about p of the time" } },
        .example =
        \\if rand.chance(0.25) then   -- a 25% critical hit
        \\  self.damage = self.damage * 2
        \\end
        ,
    },
    .{
        .name = "rand.sign",
        .module = "rand",
        .signature = "rand.sign() -> number",
        .summary = "Returns -1 or +1 with equal probability.",
        .params = &.{},
        .returns = &.{ .{ .kind = .number, .doc = "-1 or +1" } },
        .example =
        \\actor.move_by(self, rand.sign() * 100 * dt, 0)   -- coin-flip drift
        ,
    },
    .{
        .name = "rand.gauss",
        .module = "rand",
        .signature = "rand.gauss(mu, sigma) -> number",
        .summary = "A normal-distributed sample; most values land near `mu`.",
        .params = &.{
            .{ .name = "mu", .kind = .number, .doc = "mean (centre of the bell)" },
            .{ .name = "sigma", .kind = .number, .doc = "standard deviation (spread)" },
        },
        .returns = &.{ .{ .kind = .number, .doc = "a sample from N(mu, sigma^2)" } },
        .example =
        \\-- enemy accuracy: mostly on target, occasionally off by a lot
        \\local spread = rand.gauss(0.0, 3.0)
        ,
    },
    .{
        .name = "rand.choice",
        .module = "rand",
        .signature = "rand.choice(table) -> any",
        .summary = "Picks one element of an array table at random; nil when it is empty.",
        .params = &.{
            .{ .name = "table", .kind = .any, .doc = "array-like Lua table" },
        },
        .returns = &.{ .{ .kind = .any, .doc = "one element of the table, or nil if empty" } },
        .example =
        \\local drops = { "coin", "gem", "potion" }
        \\local drop = rand.choice(drops)
        ,
    },
    .{
        .name = "rand.shuffle",
        .module = "rand",
        .signature = "rand.shuffle(table) -> table",
        .summary = "Shuffles an array table in place (Fisher-Yates) and returns it.",
        .params = &.{
            .{ .name = "table", .kind = .any, .doc = "array-like Lua table" },
        },
        .returns = &.{ .{ .kind = .any, .doc = "the same table, shuffled" } },
        .example =
        \\local deck = rand.shuffle({ 1, 2, 3, 4, 5 })
        \\local top = deck[1]
        ,
    },

    // ── noise: procedural noise (M4.5) ────────────────────────────────────
    // Stateless per call: the seed is an argument, so terrain height and cloud
    // drift can use different fields at the same time without interfering.
    .{
        .name = "noise.seed",
        .module = "noise",
        .signature = "noise.seed(n)",
        .summary = "Sets the default seed every later `noise.*` call uses.",
        .params = &.{.{ .name = "n", .kind = .integer, .doc = "seed value" }},
        .returns = &.{},
        .example =
        \\noise.seed(7)   -- the same seed regenerates the same world every run
        ,
    },
    .{
        .name = "noise.value",
        .module = "noise",
        .signature = "noise.value(x, y) -> number",
        .summary = "2D value noise in [-1, 1]. Cheap; shows a faint grid when sampled far apart.",
        .params = &.{
            .{ .name = "x", .kind = .number, .doc = "sample x" },
            .{ .name = "y", .kind = .number, .doc = "sample y" },
        },
        .returns = &.{ .{ .kind = .number, .doc = "noise sample in [-1, 1]" } },
        .example =
        \\local h = noise.value(px * 0.05, py * 0.05)   -- terrain height
        ,
    },
    .{
        .name = "noise.perlin",
        .module = "noise",
        .signature = "noise.perlin(x, y) -> number",
        .summary = "2D Perlin gradient noise in [-1, 1]. The smooth default for terrain.",
        .params = &.{
            .{ .name = "x", .kind = .number, .doc = "sample x" },
            .{ .name = "y", .kind = .number, .doc = "sample y" },
        },
        .returns = &.{ .{ .kind = .number, .doc = "noise sample in [-1, 1]" } },
        .example =
        \\local h = noise.perlin(px * 0.02, py * 0.02)
        ,
    },
    .{
        .name = "noise.simplex",
        .module = "noise",
        .signature = "noise.simplex(x, y) -> number",
        .summary = "2D simplex noise in [-1, 1]. No axis bias, so it stays even along circles.",
        .params = &.{
            .{ .name = "x", .kind = .number, .doc = "sample x" },
            .{ .name = "y", .kind = .number, .doc = "sample y" },
        },
        .returns = &.{ .{ .kind = .number, .doc = "noise sample in [-1, 1]" } },
        .example =
        \\-- a wander angle that stays isotropic instead of biasing along the axes
        \\self.heading = noise.simplex(self.t * 0.1, self.seed) * math.tau
        ,
    },
    .{
        .name = "noise.fbm",
        .module = "noise",
        .signature = "noise.fbm(x, y, octaves, basis) -> number",
        .summary = "Fractal Brownian motion: several octaves of a base noise, each finer and weaker.",
        .params = &.{
            .{ .name = "x", .kind = .number, .doc = "sample x" },
            .{ .name = "y", .kind = .number, .doc = "sample y" },
            .{ .name = "octaves", .kind = .integer, .default = "4", .doc = "how many layers; clamped to 12" },
            .{ .name = "basis", .kind = .string, .default = "\"perlin\"", .doc = "\"value\", \"perlin\" or \"simplex\"" },
        },
        .returns = &.{ .{ .kind = .number, .doc = "combined noise in [-1, 1]" } },
        .example =
        \\-- rolling hills: detail at several scales, not one
        \\local h = noise.fbm(px * 0.01, py * 0.01, 5)
        ,
    },
    .{
        .name = "noise.ridged",
        .module = "noise",
        .signature = "noise.ridged(x, y, octaves, basis) -> number",
        .summary = "Ridged multifractal in [0, 1]: sharp crests where the noise crosses zero.",
        .params = &.{
            .{ .name = "x", .kind = .number, .doc = "sample x" },
            .{ .name = "y", .kind = .number, .doc = "sample y" },
            .{ .name = "octaves", .kind = .integer, .default = "4", .doc = "how many layers; clamped to 12" },
            .{ .name = "basis", .kind = .string, .default = "\"perlin\"", .doc = "\"value\", \"perlin\" or \"simplex\"" },
        },
        .returns = &.{ .{ .kind = .number, .doc = "ridge height in [0, 1]" } },
        .example =
        \\-- mountain silhouettes instead of rolling noise
        \\local ridge = noise.ridged(px * 0.01, py * 0.01, 6)
        ,
    },

    // ── input/log ──────────────────────────────────────────────────────────
    .{
        .name = "input.is_action_pressed",
        .module = "input",
        .signature = "input.is_action_pressed(name) -> boolean",
        .summary = "True on the frame an action went down.",
        .params = &.{.{ .name = "name", .kind = .string, .doc = "input action name (e.g. \"jump\")" }},
        .returns = &.{ .{ .kind = .boolean, .doc = "true on the frame the action was pressed" } },
        .example =
        \\if input.is_action_pressed("jump") then self.can_jump = true end
        ,
    },
    .{
        .name = "input.is_action_down",
        .module = "input",
        .signature = "input.is_action_down(name) -> boolean",
        .summary = "True while an action is held.",
        .params = &.{.{ .name = "name", .kind = .string, .doc = "input action name (e.g. \"move_right\")" }},
        .returns = &.{ .{ .kind = .boolean, .doc = "true while the action is held" } },
        .example =
        \\if input.is_action_down("move_right") then actor.move_by(self, 200 * dt, 0) end
        ,
    },
    .{
        .name = "input.get_axis",
        .module = "input",
        .signature = "input.get_axis(negative, positive) -> number",
        .summary = "Axis value in [-1, 1] from two opposing actions.",
        .params = &.{
            .{ .name = "negative", .kind = .string, .doc = "action for the negative direction (e.g. \"move_left\")" },
            .{ .name = "positive", .kind = .string, .doc = "action for the positive direction (e.g. \"move_right\")" },
        },
        .returns = &.{ .{ .kind = .number, .doc = "-1, 0 or +1 (fractional once more devices are mapped)" } },
        .example =
        \\local move = input.get_axis("move_left", "move_right")
        ,
    },
    .{
        .name = "log.info",
        .module = "log",
        .signature = "log.info(message)",
        .summary = "Logs an informational line. Strings are concatenated with `..`.",
        .params = &.{.{ .name = "message", .kind = .string, .doc = "message to log" }},
        .returns = &.{},
        .example =
        \\log.info("hp: " .. self.hp)
        ,
    },
    .{
        .name = "log.warn",
        .module = "log",
        .signature = "log.warn(message)",
        .summary = "Logs a warning line.",
        .params = &.{.{ .name = "message", .kind = .string, .doc = "warning message" }},
        .returns = &.{},
        .example =
        \\log.warn("out of ammo")
        ,
    },
};

// ── Lookup and the registration gate ────────────────────────────────────────

/// Finds a binding's metadata by its fully-qualified Lua name, or null.
pub fn find(name: []const u8) ?Binding {
    for (bindings) |b| {
        if (std.mem.eql(u8, b.name, name)) return b;
    }
    return null;
}

/// True when `name` is documented (used by the stub generator's sanity check).
pub fn isDocumented(name: []const u8) bool {
    return find(name) != null;
}

/// The "no metadata → the binding does not merge" rule, mechanically.
///
/// Two directions, both compile errors:
///   1. a registered name with no entry here → a binding shipped undocumented;
///   2. an entry here that is never registered → documentation for something
///      that does not exist (a stale doc is worse than none: it teaches a call
///      that will fail at runtime).
/// Plus a completeness check on each entry, so a half-filled Binding cannot
/// pass by accident.
pub fn assertAllDocumented(comptime registered: []const []const u8) void {
    @setEvalBranchQuota(100_000);
    // Direction 1: every registered name must have an entry.
    inline for (registered) |name| {
        const b = comptime find(name) orelse
            @compileError("binding '" ++ name ++ "' is registered but has no metadata entry (add it to metadata.bindings)");
        comptime {
            if (b.summary.len == 0 or b.example.len == 0 or b.signature.len == 0)
                @compileError("binding '" ++ name ++ "' has empty metadata: signature, summary and example are all mandatory");
        }
    }
    // Direction 2 — every entry must be REGISTERED — lives in `bindings.zig`,
    // which owns the authoritative name list (`registered_names`). Checking it
    // here would need a comptime walk over a slice this function cannot see,
    // and Zig refuses to `@compileError` on a runtime comparison.
}

test "every binding has a summary and an example" {
    // The comptime block above already guarantees this at compile time; the
    // test makes the invariant explicit and fails loudly if it ever regresses.
    for (bindings) |b| {
        try std.testing.expect(b.summary.len > 0);
        try std.testing.expect(b.example.len > 0);
        try std.testing.expect(b.signature.len > 0);
    }
}

test "find resolves a fully-qualified name" {
    const b = find("actor.get_position").?;
    try std.testing.expectEqualStrings("actor", b.module);
    try std.testing.expectEqual(@as(usize, 1), b.params.len);
    try std.testing.expectEqualStrings("self", b.params[0].name);
    try std.testing.expect(find("nope.nope") == null);
}

test "the math and vec2 modules are documented" {
    // The M3 criterion is "every API exposed to Lua has metadata + example";
    // these two modules are the ones the roadmap names explicitly.
    try std.testing.expect(find("math.clamp") != null);
    try std.testing.expect(find("math.move_toward") != null);
    try std.testing.expect(find("math.remap") != null);
    try std.testing.expect(find("vec2.dist") != null);
    try std.testing.expect(find("vec2.reflect") != null);
    try std.testing.expect(find("actor.is_within_radius") != null);
}

test "assertAllDocumented accepts the exact registry" {
    // Build the name list at comptime from the registry (the identity case the
    // real registration uses): it must pass, proving the gate accepts a registry
    // that matches itself.
    const names = comptime blk: {
        var arr: [bindings.len][]const u8 = undefined;
        for (bindings, &arr) |b, *n| n.* = b.name;
        break :blk arr;
    };
    assertAllDocumented(&names);
}

