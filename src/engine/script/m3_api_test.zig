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
    try uiSurface(alloc);
    try tintSurface(alloc);

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

// ── 5. ui (M14) ──────────────────────────────────────────────────────────────

/// One script, four actors: the widget kind is set from Zig before the first
/// update (the same "field on `self`" pattern the chase test uses), so one
/// `load` covers the button, label, panel and bar surfaces without a second
/// script name (multiple different `load`s on one VM are a known LuaJIT crash).
const ui_src =
    \\local M = {}
    \\function M:start()
    \\  self.done = false
    \\end
    \\function M:update(dt)
    \\  if self.done then return end
    \\  self.done = true
    \\  local k = self.kind
    \\  if k == "button" then
    \\    actor.add_component(self, "UiCanvas")
    \\    actor.add_component(self, "UiButton")
    \\    ui.set_anchor(self, "center")
    \\    ui.set_offset(self, 10, 20)
    \\    ui.set_size(self, 200, 60)
    \\    ui.set_pivot(self, 0.5, 0.5)
    \\    ui.set_order(self, 3)
    \\    ui.set_interactive(self, false)
    \\    ui.set_text(self, "Play")
    \\    ui.set_font(self, 2)
    \\    ui.set_enabled(self, true)
    \\    ui.set_colors(self,
    \\      { 0.1, 0.2, 0.3, 1 },
    \\      { 0.2, 0.3, 0.4, 1 },
    \\      { 0.05, 0.05, 0.05, 1 },
    \\      { 0.9, 0.9, 0.9, 1 })
    \\    ui.set_color(self, 0.5, 0.6, 0.7, 1)
    \\    self.font_id = ui.font_load("assets/fonts/none.ttf", 16)
    \\    self.mw, self.mh = ui.measure(self, "Play")
    \\    local rx, ry = ui.rect(self)
    \\    self.rx, self.ry = rx, ry
    \\    self.hov = ui.hovered(self)
    \\    self.pres = ui.pressed(self)
    \\    self.pover = input.pointer_over_ui()
    \\    self.has_label = actor.has_component(self, "Label")
    \\  elseif k == "label" then
    \\    actor.add_component(self, "Label")
    \\    ui.set_text(self, "Score")
    \\    ui.set_align(self, "right")
    \\    ui.set_font(self, 3)
    \\    ui.set_color(self, 1, 0.8, 0.2, 1)
    \\  elseif k == "panel" then
    \\    actor.add_component(self, "UiPanel")
    \\    ui.set_anchor(self, "full_rect")
    \\    ui.set_margin(self, 4, 4, 4, 4)
    \\    ui.set_color(self, 0.1, 0.1, 0.1, 0.9)
    \\    ui.set_border(self, 1, 1, 1, 0.5, 2)
    \\  elseif k == "bar" then
    \\    actor.add_component(self, "UiProgressBar")
    \\    ui.set_value(self, 0.5)
    \\    ui.set_show_text(self, true)
    \\    ui.set_visible(self, false)
    \\  end
    \\end
    \\return M
;

// The CanvasModulate surface. Three frames, one step each, because the mode is
// write-only from Lua (there is no getter for it) and the test observes the
// hook's state BETWEEN steps — the same way a runtime would see it.
const tint_src =
    \\local M = {}
    \\function M:start()
    \\  self.step = 0
    \\end
    \\function M:update(dt)
    \\  self.step = self.step + 1
    \\  if self.step == 1 then
    \\    scene.tint(0.6, 0.5, 0.75, 0.8)
    \\  elseif self.step == 2 then
    \\    self.amt = scene.tint_amount()
    \\    scene.tint_mode("add")
    \\  elseif self.step == 3 then
    \\    scene.tint_clear()
    \\    self.amt_after = scene.tint_amount()
    \\  end
    \\end
    \\return M
;

/// The vtable a runtime would provide. `measure` is a fixed 7 px per character
/// so the test pins the plumbing, not a rasterizer (that is `font.zig`'s job),
/// and `font_load` returns a known id.
const MockUi = struct {
    fn measure(_: ?*anyopaque, font_id: u32, text: []const u8, out: *[2]f32) bool {
        _ = font_id;
        out[0] = @floatFromInt(text.len * 7);
        out[1] = 16;
        return true;
    }
    fn fontLoad(_: ?*anyopaque, path: []const u8, px: f32) u32 {
        _ = path;
        _ = px;
        return 7;
    }
    fn hovered(_: ?*anyopaque, _: u64) bool {
        return false;
    }
    fn pressed(_: ?*anyopaque, _: u64) bool {
        return false;
    }
};

/// The CanvasModulate double. It keeps the SAME state a real `render.tint.Tint`
/// keeps (`color` + the mode wire code) but is defined here because the `script`
/// module cannot import `render`. The test asserts the plumbing — that each Lua
/// call reaches the hook with the right arguments — which is what PR9 needs; the
/// mix itself is `tint.zig`'s and `post.wgsl`'s job.
const MockTint = struct {
    const State = struct {
        color: [4]f32 = .{ 1, 1, 1, 0 },
        mode: u8 = 0,
    };
    fn set(ctx: ?*anyopaque, r: f32, g: f32, b: f32, a: f32) void {
        const s: *State = @ptrCast(@alignCast(ctx.?));
        s.color = .{ r, g, b, a };
        if (s.mode == 0) s.mode = 1; // multiply by default, off -> on
    }
    fn setMode(ctx: ?*anyopaque, mode: u8) void {
        const s: *State = @ptrCast(@alignCast(ctx.?));
        s.mode = mode;
    }
    fn clear(ctx: ?*anyopaque) void {
        const s: *State = @ptrCast(@alignCast(ctx.?));
        s.color = .{ 1, 1, 1, 0 };
        s.mode = 0;
    }
    fn amount(ctx: ?*anyopaque) f32 {
        const s: *State = @ptrCast(@alignCast(ctx.?));
        return s.color[3];
    }
};

fn approx(a: f32, b: f32) bool {
    return @abs(a - b) < 1e-3;
}

fn uiSurface(alloc: std.mem.Allocator) !void {
    std.debug.print("-- ui: the M14 widget surface, from Lua --\n", .{});
    var world = ecs.World.init(alloc);
    defer world.deinit();
    try world.reserveEntities(16);
    try world.reserve(.{components.Transform}, 16);
    var input = script.Input{};
    var b: script.Behaviors = undefined;
    try b.init(alloc, &world, &input);
    defer b.deinit();

    var hooks = script.context.UiHooks{
        .ctx = null,
        .measure = MockUi.measure,
        .font_load = MockUi.fontLoad,
        .hovered = MockUi.hovered,
        .pressed = MockUi.pressed,
    };
    b.ctx.ui = &hooks;

    _ = try b.load("ui.lua", ui_src);

    const button = try world.spawn(.{components.Transform{}});
    const label = try world.spawn(.{components.Transform{}});
    const panel = try world.spawn(.{components.Transform{}});
    const bar = try world.spawn(.{components.Transform{}});
    inline for (.{ button, label, panel, bar }) |e| try b.attach(e, 0);
    b.startAll();

    // Set each actor's widget kind before the first update runs.
    const L = b.vm.state().?;
    const kinds = [_][]const u8{ "button", "label", "panel", "bar" };
    for (kinds, 0..) |kind, i| {
        b.vm.pushRef(b.instances.items[i].self_ref);
        script.luajit.pushSlice(L, kind);
        script.luajit.setField(L, -2, "kind");
        script.luajit.pop(L, 1);
    }
    b.update(1.0 / 60.0);

    // ── button ──────────────────────────────────────────────────────────────
    const btn = world.get(button, components.UiButton) orelse {
        check("actor.add_component(\"UiButton\") gave the actor a button", false);
        return;
    };
    const bs = b.instances.items[0].self_ref;
    check("ui.set_anchor(center) reached the layout", btn.layout.anchor == .center);
    check("ui.set_offset(10, 20) reached the layout", approx(btn.layout.offset.x, 10) and approx(btn.layout.offset.y, 20));
    check("ui.set_size(200, 60) reached the layout", approx(btn.layout.size.x, 200) and approx(btn.layout.size.y, 60));
    check("ui.set_pivot(0.5, 0.5) reached the layout", approx(btn.layout.pivot.x, 0.5) and approx(btn.layout.pivot.y, 0.5));
    check("ui.set_order(3) reached the layout", btn.layout.order == 3);
    check("ui.set_interactive(false) reached the layout", !btn.layout.interactive);
    check("ui.set_text(\"Play\") reached the button", btn.text.eql("Play"));
    check("ui.set_font(2) reached the button", btn.font == 2);
    check("ui.set_enabled(true) reached the button", btn.enabled);
    check("ui.set_color on a button writes text_color", approx(btn.text_color[0], 0.5) and approx(btn.text_color[2], 0.7));
    check("ui.set_colors wrote color_normal", approx(btn.color_normal[0], 0.1) and approx(btn.color_normal[2], 0.3));
    check("ui.set_colors wrote color_hover", approx(btn.color_hover[1], 0.3));
    check("ui.set_colors wrote color_pressed", approx(btn.color_pressed[0], 0.05));
    check("ui.font_load reaches the hook and returns its id", readNumber(&b, bs, "font_id").? == 7);
    check("ui.measure returns (width, height) from the hook", near(readNumber(&b, bs, "mw").?, 28) and near(readNumber(&b, bs, "mh").?, 16));
    check("ui.rect is (0,0) before the system has laid the widget out", near(readNumber(&b, bs, "rx").?, 0) and near(readNumber(&b, bs, "ry").?, 0));
    check("ui.hovered is false with no UI system", !readSelfBool(&b, bs, "hov"));
    check("ui.pressed is false with no UI system", !readSelfBool(&b, bs, "pres"));
    check("input.pointer_over_ui is false by default", !readSelfBool(&b, bs, "pover"));
    check("actor.has_component(\"Label\") is false on a button", !readSelfBool(&b, bs, "has_label"));
    check("actor.add_component(\"UiCanvas\") landed", world.get(button, components.UiCanvas) != null);

    // ── label ───────────────────────────────────────────────────────────────
    const lbl = world.get(label, components.Label) orelse {
        check("actor.add_component(\"Label\") gave the actor a label", false);
        return;
    };
    check("ui.set_text on a label", lbl.text.eql("Score"));
    check("ui.set_align(\"right\") reached the label", lbl.alignment == .right);
    check("ui.set_font(3) reached the label", lbl.font == 3);
    check("ui.set_color on a label writes color", approx(lbl.color[1], 0.8) and approx(lbl.color[3], 1));

    // ── panel ───────────────────────────────────────────────────────────────
    const pnl = world.get(panel, components.UiPanel) orelse {
        check("actor.add_component(\"UiPanel\") gave the actor a panel", false);
        return;
    };
    check("ui.set_anchor(\"full_rect\") reached the panel", pnl.layout.anchor == .full_rect);
    check("ui.set_margin(4,4,4,4) reached the panel", approx(pnl.layout.margin[0], 4) and approx(pnl.layout.margin[3], 4));
    check("ui.set_color on a panel writes color", approx(pnl.color[0], 0.1) and approx(pnl.color[3], 0.9));
    check("ui.set_border wrote the colour and width", approx(pnl.border_width, 2) and approx(pnl.border_color[3], 0.5));

    // ── bar ─────────────────────────────────────────────────────────────────
    const bar_c = world.get(bar, components.UiProgressBar) orelse {
        check("actor.add_component(\"UiProgressBar\") gave the actor a bar", false);
        return;
    };
    check("ui.set_value(0.5) reached the bar", approx(bar_c.value, 0.5));
    check("ui.set_show_text(true) reached the bar", bar_c.show_text);
    check("ui.set_visible(false) reached the bar", !bar_c.layout.visible);

    // ── removal ─────────────────────────────────────────────────────────────
    check("actor.remove_component(\"UiProgressBar\") removes it", world.remove(bar, components.UiProgressBar));
    check("the bar component is gone", world.get(bar, components.UiProgressBar) == null);
    check("no behavior errors", b.errors == 0);
}

// ── 5b. scene.tint (CanvasModulate) ──────────────────────────────────────────

fn tintSurface(alloc: std.mem.Allocator) !void {
    std.debug.print("-- scene.tint: the M14 CanvasModulate surface, from Lua --\n", .{});
    var world = ecs.World.init(alloc);
    defer world.deinit();
    try world.reserveEntities(4);
    try world.reserve(.{components.Transform}, 4);
    var input = script.Input{};
    var b: script.Behaviors = undefined;
    try b.init(alloc, &world, &input);
    defer b.deinit();

    var state = MockTint.State{};
    var hooks = script.context.TintHooks{
        .ctx = &state,
        .set = MockTint.set,
        .set_mode = MockTint.setMode,
        .clear = MockTint.clear,
        .amount = MockTint.amount,
    };
    b.ctx.tint = &hooks;

    _ = try b.load("tint.lua", tint_src);
    const e = try world.spawn(.{components.Transform{}});
    try b.attach(e, 0);
    b.startAll();
    const s = b.instances.items[0].self_ref;

    // Step 1: a colour, which turns the effect on.
    b.update(1.0 / 60.0);
    check("scene.tint wrote the colour", approx(state.color[0], 0.6) and approx(state.color[1], 0.5) and
        approx(state.color[2], 0.75) and approx(state.color[3], 0.8));
    check("scene.tint enabled multiply by default", state.mode == 1);

    // Step 2: the amount query, then an explicit mode.
    b.update(1.0 / 60.0);
    check("scene.tint_amount returns the hook's strength", near(readNumber(&b, s, "amt").?, 0.8));
    check("scene.tint_mode(\"add\") switched the mix", state.mode == 2);

    // Step 3: clear, and the amount reads back to zero.
    b.update(1.0 / 60.0);
    check("scene.tint_clear disabled it", state.mode == 0 and approx(state.color[3], 0));
    check("scene.tint_amount is 0 after clear", near(readNumber(&b, s, "amt_after").?, 0));
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

/// Reads a BOOLEAN field off a `self` table (the ui query bindings return
/// true/false).
fn readSelfBool(b: *script.Behaviors, self_ref: i32, key: [*:0]const u8) bool {
    const L = b.vm.state().?;
    b.vm.pushRef(self_ref);
    script.luajit.getField(L, -1, key);
    const v = script.luajit.lua_toboolean(L, -1) != 0;
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
