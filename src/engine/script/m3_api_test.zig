//! M3 acceptance suite: the engine's Lua API exercised the way a game uses it.
//!
//! `zig build test-api` runs this AND `api_acceptance_test.zig` (the other
//! suites that grew here); this file owns the M3 surface — actor, math, vec2
//! and the spatial queries — one Behaaviors per phase, because more than one
//! `load` of a DIFFERENT name on the same VM crashes inside LuaJIT's heap
//! (tracked in vm.zig; the runtime, the bench and hot-reload are unaffected).
//!
//! The scripts are written as a GAME would write them, not one function per
//! check: that is what catches a binding that exists but is wrong.
//!
//! Exit 0 = green, 1 = a failure (so CI can gate on it).

const std = @import("std");
const ecs = @import("ecs");
const script = @import("script");

const components = ecs.components;

const chase_src =
    \\local M = {}
    \\function M:start()
    \\  self.speed = 240
    \\  self.total = 0
    \\end
    \\function M:update(dt)
    \\  self.total = self.total + dt
    \\  local target = self.target
    \\  if target == nil then return end
    \\  local d = actor.distance_to(self, target)
    \\  if actor.is_within_radius(self, target, 40) then
    \\    actor.move_by(self, 0, 0)              -- in range: stop
    \\  else
    \\    local dx, dy = actor.direction_to(self, target)
    \\    -- vec2.perpendicular returns a Vec2 TABLE, so its components are read
    \\    -- off it: the two-number form is for INPUTS, not outputs.
    \\    local perp = vec2.perpendicular(dx, dy)
    \\    local sway = math.sin(self.total * 4) * 0.35
    \\    actor.move_by(self,
    \\      (dx + perp.x * sway) * self.speed * dt,
    \\      (dy + perp.y * sway) * self.speed * dt)
    \\  end
    \\  self.dist = d
    \\end
    \\return M
;

const hud_src =
    \\local M = {}
    \\function M:start()
    \\  self.hp = 75
    \\  self.fade = 0
    \\end
    \\function M:update(dt)
    \\  self.hp = math.clamp(self.hp - 10 * dt, 0, 100)
    \\  self.bar_w = math.remap(self.hp, 0, 100, 0, 200)
    \\  self.vis = math.smoothstep(0, 1, self.fade)
    \\  self.fade = math.wrap(self.fade + dt, 0, 2)
    \\  self.ping = math.pingpong(self.fade, 1)
    \\  self.approx = math.is_close(self.hp, 100, 1)
    \\  self.rounded = math.round(self.bar_w)
    \\  self.hp = math.move_toward(self.hp, 0, 5 * dt)
    \\end
    \\return M
;

const vec2_src =
    \\local M = {}
    \\function M:start()
    \\  local a = vec2.new(3, 4)
    \\  local b = vec2.new(0, 0)
    \\  local c = vec2.to_vec(1, 1)
    \\  self.dist = vec2.dist(a, b)
    \\  self.dist2 = vec2.dist(3, 4, 0, 0)
    \\  self.dist_sq = vec2.dist_sq(a, b)
    \\  self.len = vec2.length(a)
    \\  self.len_sq = vec2.length_sq(a)
    \\  self.norm = vec2.normalized(a)
    \\  self.dir = vec2.direction(a, b)
    \\  self.dotted = vec2.dot(a, c)
    \\  self.crossed = vec2.cross(a, c)
    \\  self.perp = vec2.perpendicular(a)
    \\  self.clamped = vec2.clamp_length(a, 2)
    \\  self.clamped2 = vec2.clamped(a, 2)
    \\end
    \\return M
;

const spatial_src =
    \\local other = ...
    \\local self = _G.__self
    \\local out = {}
    \\out.d = actor.distance_to(self, other)
    \\out.dsq = actor.distance_squared_to(self, other)
    \\out.dp = actor.distance_to_point(self, 30, 40)
    \\out.in50 = actor.is_within_radius(self, other, 50)
    \\out.in49 = actor.is_within_radius(self, other, 49)
    \\return out
;

var failures: usize = 0;

fn check(comptime name: []const u8, ok: bool) void {
    std.debug.print("  [{s}] {s}\n", .{ if (ok) "PASS" else "FAIL", name });
    if (!ok) failures += 1;
}

fn near(a: f64, b: f64) bool {
    const d = a - b;
    return d < 0.0001 and d > -0.0001;
}

pub fn main() !void {
    const alloc = std.heap.c_allocator;
    std.debug.print("== M3 API acceptance (actor + math + vec2 + spatial) ==\n", .{});
    try chase(alloc);
    try mathSet(alloc);
    try vec2All(alloc);
    try spatial(alloc);

    if (failures == 0) {
        std.debug.print("== M3 API acceptance: all green ==\n", .{});
    } else {
        std.debug.print("== M3 API acceptance: {d} failure(s) ==\n", .{failures});
        std.process.exit(1);
    }
}

// ── 1. chase ─────────────────────────────────────────────────────────────────

fn chase(alloc: std.mem.Allocator) !void {
    std.debug.print("-- chase: actor.* + vec2 + math driving the ECS --\n", .{});
    var world = ecs.World.init(alloc);
    defer world.deinit();
    try world.reserveEntities(16);
    try world.reserve(.{components.Transform}, 16);
    var input = script.Input{};
    input.define("jump");
    input.define("move_left");
    input.define("move_right");
    var b: script.Behaviors = undefined;
    try b.init(alloc, &world, &input);
    defer b.deinit();

    const chase_id = try b.load("chase.lua", chase_src);

    const paddle = try world.spawn(.{components.Transform{ .position = .{ .x = 100, .y = 0 } }});
    const ball = try world.spawn(.{components.Transform{ .position = .{ .x = 0, .y = 0 } }});
    try b.attach(paddle, chase_id);
    try b.attach(ball, chase_id);
    b.startAll();

    // Point the ball at the paddle: a field on its own `self` table, set from
    // Lua — this is how gameplay shares references between behaviors.
    const L = b.vm.state().?;
    b.vm.pushRef(b.instances.items[1].self_ref); // [self]
    b.vm.pushRef(b.instances.items[0].self_ref); // [self, target]
    script.luajit.setField(L, -2, "target"); // self.target = target (pops target)
    script.luajit.pop(L, 1); // []

    // One second of chasing at 240 u/s.
    var frames: usize = 0;
    while (frames < 60) : (frames += 1) b.update(1.0 / 60.0);

    const pos = world.get(ball, components.Transform).?.position;
    check("chase moved the ball well past its start (x > 20)", pos.x > 20);
    check("chase never passed the paddle (x <= 100)", pos.x <= 100);
    check("no behavior errors", b.errors == 0);
}

// ── 2. math ──────────────────────────────────────────────────────────────────

fn mathSet(alloc: std.mem.Allocator) !void {
    std.debug.print("-- math: the scalar set from Lua --\n", .{});
    var world = ecs.World.init(alloc);
    defer world.deinit();
    try world.reserveEntities(16);
    try world.reserve(.{components.Transform}, 16);
    var input = script.Input{};
    input.define("jump");
    var b: script.Behaviors = undefined;
    try b.init(alloc, &world, &input);
    defer b.deinit();

    _ = try b.load("hud.lua", hud_src);
    const e = try world.spawn(.{components.Transform{}});
    try b.attach(e, 0);
    b.startAll();

    var frames: usize = 0;
    while (frames < 30) : (frames += 1) b.update(1.0 / 60.0);

    const s = b.instances.items[0].self_ref;
    const hp = readNumber(&b, s, "hp").?;
    const bar = readNumber(&b, s, "bar_w").?;
    const ping = readNumber(&b, s, "ping").?;
    check("clamp kept hp inside [0, 100]", hp >= 0 and hp <= 100);
    check("remap(0..100 -> 0..200) kept the bar inside [0, 200]", bar >= 0 and bar <= 200);
    check("pingpong stayed inside [0,1] (degenerate guard)", ping >= 0 and ping <= 1);
    check("no behavior errors", b.errors == 0);
}

// ── 3. vec2 ──────────────────────────────────────────────────────────────────

fn vec2All(alloc: std.mem.Allocator) !void {
    std.debug.print("-- vec2: every helper, from Lua --\n", .{});
    var world = ecs.World.init(alloc);
    defer world.deinit();
    try world.reserveEntities(16);
    try world.reserve(.{components.Transform}, 16);
    var input = script.Input{};
    input.define("jump");
    var b: script.Behaviors = undefined;
    try b.init(alloc, &world, &input);
    defer b.deinit();

    _ = try b.load("vec2.lua", vec2_src);
    const e = try world.spawn(.{components.Transform{}});
    try b.attach(e, 0);
    b.startAll();

    const s = b.instances.items[0].self_ref;
    check("dist(table, table) == 5", near(readNumber(&b, s, "dist").?, 5));
    check("dist(4 numbers) == 5", near(readNumber(&b, s, "dist2").?, 5));
    check("dist_sq == 25", near(readNumber(&b, s, "dist_sq").?, 25));
    check("length == 5", near(readNumber(&b, s, "len").?, 5));
    check("length_sq == 25", near(readNumber(&b, s, "len_sq").?, 25));
    check("dot((3,4),(1,1)) == 7", near(readNumber(&b, s, "dotted").?, 7));
    check("cross((3,4),(1,1)) == -1", near(readNumber(&b, s, "crossed").?, -1));
    check("normalized returns a TABLE with x == 0.6", near(readField(&b, s, "norm", "x").?, 0.6));
    check("normalized returns a TABLE with y == 0.8", near(readField(&b, s, "norm", "y").?, 0.8));
    check("clamp_length caps the length at 2", near(readVecLen(&b, s, "clamped"), 2));
    check("clamped (the Godot spelling) does the same", near(readVecLen(&b, s, "clamped2"), 2));
    check("perpendicular returns a TABLE", readField(&b, s, "perp", "x") != null);
    check("no behavior errors", b.errors == 0);
}

// ── 4. spatial ───────────────────────────────────────────────────────────────

fn spatial(alloc: std.mem.Allocator) !void {
    std.debug.print("-- spatial: actor-to-actor queries vs a hand-computed 3-4-5 --\n", .{});
    var world = ecs.World.init(alloc);
    defer world.deinit();
    try world.reserveEntities(16);
    try world.reserve(.{components.Transform}, 16);
    var input = script.Input{};
    input.define("jump");
    var b: script.Behaviors = undefined;
    try b.init(alloc, &world, &input);
    defer b.deinit();

    _ = try b.load("hud.lua", hud_src);
    const a = try world.spawn(.{components.Transform{ .position = .{ .x = 0, .y = 0 } }});
    const o = try world.spawn(.{components.Transform{ .position = .{ .x = 30, .y = 40 } }});
    try b.attach(a, 0);
    try b.attach(o, 0);
    b.startAll();

    const L = b.vm.state().?;
    try b.vm.loadBuffer(spatial_src, "@probe");
    b.vm.pushRef(b.instances.items[0].self_ref);
    script.luajit.setGlobal(L, "__self");
    b.vm.pushRef(b.instances.items[1].self_ref); // the `...` argument
    if (script.luajit.lua_pcall(L, 1, 1, 0) != 0) {
        std.debug.print("  probe failed: {s}\n", .{script.luajit.toString(L, -1)});
        check("probe ran", false);
        return;
    }
    // [results] — copy every value out FIRST, then drop the table.
    const d = readTableNumber(&b, -1, "d").?;
    const dsq = readTableNumber(&b, -1, "dsq").?;
    const dp = readTableNumber(&b, -1, "dp").?;
    const in50 = readTableBool(&b, -1, "in50");
    const in49 = readTableBool(&b, -1, "in49");
    script.luajit.pop(L, 1);

    check("distance_to == 50", near(d, 50));
    check("distance_squared_to == 2500", near(dsq, 2500));
    check("distance_to_point == 50", near(dp, 50));
    check("is_within_radius(other, 50) is true (edge inclusive)", in50);
    check("is_within_radius(other, 49) is false", !in49);
    check("no behavior errors", b.errors == 0);
}

// ── readers ──────────────────────────────────────────────────────────────────

fn readNumber(b: *script.Behaviors, self_ref: i32, key: [*:0]const u8) ?f64 {
    const L = b.vm.state().?;
    b.vm.pushRef(self_ref);
    script.luajit.getField(L, -1, key);
    const v: ?f64 = if (script.luajit.isNumber(L, -1)) script.luajit.lua_tonumber(L, -1) else null;
    script.luajit.pop(L, 2);
    return v;
}

fn readField(b: *script.Behaviors, self_ref: i32, table: [*:0]const u8, field: [*:0]const u8) ?f64 {
    const L = b.vm.state().?;
    b.vm.pushRef(self_ref);
    script.luajit.getField(L, -1, table);
    if (script.luajit.lua_type(L, -1) != script.luajit.TTABLE) {
        script.luajit.pop(L, 2);
        return null;
    }
    script.luajit.getField(L, -1, field);
    const v: ?f64 = if (script.luajit.isNumber(L, -1)) script.luajit.lua_tonumber(L, -1) else null;
    script.luajit.pop(L, 3);
    return v;
}

fn readTableNumber(b: *script.Behaviors, table_idx: c_int, field: [*:0]const u8) ?f64 {
    const L = b.vm.state().?;
    script.luajit.getField(L, table_idx, field);
    const v: ?f64 = if (script.luajit.isNumber(L, -1)) script.luajit.lua_tonumber(L, -1) else null;
    script.luajit.pop(L, 1);
    return v;
}

/// Reads a BOOLEAN field: the radius predicates return true/false, not numbers.
fn readTableBool(b: *script.Behaviors, table_idx: c_int, field: [*:0]const u8) bool {
    const L = b.vm.state().?;
    script.luajit.getField(L, table_idx, field);
    const v = script.luajit.lua_toboolean(L, -1) != 0;
    script.luajit.pop(L, 1);
    return v;
}

fn readVecLen(b: *script.Behaviors, self_ref: i32, field: [*:0]const u8) f64 {
    const x = readField(b, self_ref, field, "x") orelse return -1;
    const y = readField(b, self_ref, field, "y") orelse return -1;
    return @sqrt(x * x + y * y);
}
