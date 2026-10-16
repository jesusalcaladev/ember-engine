//! M4.5 acceptance suite for the `rand` and `noise` Lua tables.
//!
//! An EXECUTABLE, not a `zig test`: LuaJIT installs its own signal/`longjmp`
//! handling, which does not survive Zig's test runner (the identical code
//! segfaults inside `lua_pcall` under `zig test` and runs clean here) — the
//! same reason the M3 bench and the other live-VM checks are artifacts. Exit 0 =
//! green, exit 1 = at least one check failed, and every failure is printed.
//!
//! The reason these live here rather than in `core/random.zig`'s unit tests:
//! those can only test the generator, not the bindings. A `rand.float` stub
//! that returned 0 would satisfy every range assertion in the core, and would
//! still break every game.

const std = @import("std");
const lua = @import("luajit.zig");
const vm_mod = @import("vm.zig");
const bindings = @import("bindings.zig");
const context_mod = @import("context.zig");
const ecs = @import("ecs");
const statemachine = @import("statemachine.zig");
const spatial = @import("spatial.zig");
const steer = @import("steer.zig");
const physics = @import("physics");
const audio = @import("audio");
const behavior_mod = @import("behavior.zig");
const build_options = @import("options");

/// One named check. `text` is Lua source that must evaluate to `true`; the
/// script does its own asserting so the failure message can quote the value it
/// saw, which a Zig-side comparison could not do without duplicating the logic.
const Check = struct {
    name: []const u8,
    text: []const u8,
};

const checks = [_]Check{
    .{ .name = "rand.seed replays the sequence", .text =
    \\rand.seed(4242)
    \\local a = {}
    \\for i = 1, 5 do a[i] = rand.float(0, 100) end
    \\rand.seed(4242)
    \\for i = 1, 5 do if rand.float(0, 100) ~= a[i] then return false end end
    \\return true
    },
    .{ .name = "different seeds diverge", .text =
    \\rand.seed(1)
    \\local a = rand.float(0, 1000)
    \\rand.seed(2)
    \\local b = rand.float(0, 1000)
    \\return a ~= b
    },
    .{ .name = "rand.float / rand.range respect bounds", .text =
    \\rand.seed(1)
    \\for i = 1, 500 do
    \\  local v = rand.range(-3, 7)
    \\  if v < -3 or v >= 7 then return false end
    \\  local w = rand.float(0, 1)
    \\  if w < 0 or w >= 1 then return false end
    \\end
    \\return true
    },
    .{ .name = "rand.int is inclusive and tolerates swapped bounds", .text =
    \\rand.seed(9)
    \\local lo, hi = false, false
    \\for i = 1, 2000 do
    \\  local v = rand.int(1, 4)
    \\  if v == 1 then lo = true end
    \\  if v == 4 then hi = true end
    \\  if v < 1 or v > 4 then return false end
    \\end
    \\for i = 1, 100 do
    \\  local v = rand.int(4, 1)
    \\  if v < 1 or v > 4 then return false end
    \\end
    \\return lo and hi
    },
    .{ .name = "rand.chance / rand.gauss behave", .text =
    \\rand.seed(5)
    \\if not rand.chance(1) then return false end
    \\if rand.chance(0) then return false end
    \\local sum = 0
    \\for i = 1, 500 do sum = sum + rand.gauss(0, 1) end
    \\return math.abs(sum / 500) <= 0.3
    },
    .{ .name = "rand.shuffle permutes the caller's table in place", .text =
    \\rand.seed(3)
    \\local cards = { 1, 2, 3, 4, 5, 6, 7, 8 }
    \\local out = rand.shuffle(cards)
    \\if #out ~= 8 then return false end
    \\if out ~= cards then return false end
    \\local seen = {}
    \\for i = 1, 8 do
    \\  local v = out[i]
    \\  if v < 1 or v > 8 then return false end
    \\  if seen[v] then return false end
    \\  seen[v] = true
    \\end
    \\return true
    },
    .{ .name = "rand.choice is nil when empty", .text =
    \\if rand.choice({}) ~= nil then return false end
    \\if rand.choice({ "a" }) ~= "a" then return false end
    \\local d = rand.choice({ "coin", "gem" })
    \\return d == "coin" or d == "gem"
    },
    .{ .name = "noise is reproducible, varies, and stays in range", .text =
    \\noise.seed(11)
    \\if math.abs(noise.perlin(1.5, 2.5) - noise.perlin(1.5, 2.5)) > 0.0001 then return false end
    \\if math.abs(noise.simplex(1.5, 2.5) - noise.simplex(1.5, 2.5)) > 0.0001 then return false end
    \\if math.abs(noise.value(1.5, 2.5) - noise.value(1.5, 2.5)) > 0.0001 then return false end
    \\-- Reproducibility alone is trivial if every value is 0, so also require the
    \\-- field to actually CHANGE with position (non-lattice coordinates: the
    \\-- gradient bases are exactly 0 on their integer lattice).
    \\local base = noise.perlin(1.5, 2.5)
    \\local varied = false
    \\for i = 1, 300 do
    \\  local x = i * 0.137
    \\  if math.abs(noise.perlin(x, 2.5) - base) > 0.01 then varied = true end
    \\  local v = noise.value(x, i * 0.2)
    \\  if v < -1 or v > 1 then return false end
    \\  local s = noise.simplex(x, i * 0.2)
    \\  if s < -1 or s > 1 then return false end
    \\  local f = noise.fbm(x, i * 0.2, 4)
    \\  if f < -1 or f > 1 then return false end
    \\  local r = noise.ridged(x, i * 0.2, 4)
    \\  if r < 0 or r > 1 then return false end
    \\end
    \\return varied
    },
    .{ .name = "noise.seed changes the field; a per-call seed overrides it", .text =
    \\-- NOT at integer coordinates: gradient noise is exactly 0 at every
    \\-- lattice point, so comparing seeds there compares two zeroes.
    \\noise.seed(1)
    \\local a = noise.perlin(2.37, 1.81)
    \\noise.seed(2)
    \\local b = noise.perlin(2.37, 1.81)
    \\if a == b then return false end
    \\-- An explicit per-call seed is independent of the global one.
    \\local c = noise.perlin(2.37, 1.81, 99)
    \\local d = noise.perlin(2.37, 1.81, 99)
    \\if math.abs(c - d) > 0.0001 then return false end
    \\if math.abs(c - a) < 0.0001 then return false end
    \\return true
    },
    .{ .name = "an absurd octave count is clamped", .text =
    \\noise.seed(1)
    \\local v = noise.fbm(0.5, 0.5, 100000)
    \\if v ~= v then return false end
    \\return v >= -1 and v <= 1
    },
    .{ .name = "an unknown basis falls back instead of failing", .text =
    \\noise.seed(1)
    \\local v = noise.fbm(1.0, 1.0, 3, "not-a-basis")
    \\return v >= -1 and v <= 1
    },
};

/// Runs one check. Returns true when the script evaluated to `true`.
/// Longest script a check may hold. Fixed rather than sized from `check.text`:
/// `check` comes from a runtime loop variable, so `text.len` is not
/// comptime-known and cannot size a stack array.
const max_script_len = 4096;

fn runCheck(allocator: std.mem.Allocator, check: Check) bool {
    // The buffer is owned here, so the slice handed to `loadBuffer` stays valid
    // for the whole run (a helper returning it would dangle on its own frame).
    var buf: [max_script_len]u8 = undefined;
    const source = std.fmt.bufPrintZ(&buf, "{s}", .{check.text}) catch {
        std.debug.print("  script exceeds the {d}-byte buffer\n", .{max_script_len});
        return false;
    };

    var vm = vm_mod.Vm.init(allocator) catch |e| {
        std.debug.print("  Vm.init failed: {s}\n", .{@errorName(e)});
        return false;
    };
    defer vm.deinit();
    const L = vm.state() orelse {
        std.debug.print("  Vm has no state\n", .{});
        return false;
    };

    var world = ecs.World.init(allocator);
    defer world.deinit();

    const input = context_mod.Input{};
    var ctx = bindings.Context.init(&world, &input);
    bindings.registerAll(L, &ctx);

    // NOT `vm.callPrototype`: that expects the chunk to return a TABLE (the
    // behavior-script convention, where the prototype's methods get cached).
    // These checks are plain scripts returning one boolean, so the chunk is
    // called directly here.
    vm.loadBuffer(source, "api_acceptance") catch |e| {
        std.debug.print("  loadBuffer failed: {s}\n", .{@errorName(e)});
        return false;
    };

    if (lua.lua_pcall(L, 0, 1, 0) != 0) {
        var msg_buf: [256]u8 = undefined;
        if (vm.readError(&msg_buf)) |msg| {
            std.debug.print("  lua error: {s}\n", .{msg});
        } else {
            std.debug.print("  lua error (no message)\n", .{});
        }
        return false;
    }
    return lua.toBool(L, 1);
}

// ── Physics (M4) ─────────────────────────────────────────────────────────────
// The physics bindings are the only ones whose correctness depends on state
// that lives OUTSIDE Lua: the solver owns where things are. A raycast stub that
// always returned "nothing there" would pass a purely-Lua test and break every
// guard and turret in a game, so these run against a real Box2D world with real
// bodies and read the answer back out of the VM.

const components = ecs.components;
const RigidBody2D = components.RigidBody2D;
const Collider2D = components.Collider2D;
const Transform = components.Transform;

fn checkPhysics(allocator: std.mem.Allocator) bool {
    var vm = vm_mod.Vm.init(allocator) catch {
        std.debug.print("  Vm.init failed\n", .{});
        return false;
    };
    defer vm.deinit();
    const L = vm.state() orelse {
        std.debug.print("  Vm has no state\n", .{});
        return false;
    };

    var world = ecs.World.init(allocator);
    defer world.deinit();

    // A real solver world, stepped by the real Driver.
    var phys = physics.System.init(allocator, .box2d, .{ .x = 0, .y = 0 }) catch {
        std.debug.print("  could not create a physics world\n", .{});
        return false;
    };
    defer phys.deinit();

    // A fixed floor to stand on, and a wall to block sight lines.
    const floor_e = world.spawn(.{
        Transform{ .position = .{ .x = 0, .y = 100 }, .rotation = 0 },
        RigidBody2D{ .body_type = 0 }, // fixed
        Collider2D{ .kind = 0, .size = .{ .x = 400, .y = 10 } },
    }) catch return false;
    const wall_e = world.spawn(.{
        Transform{ .position = .{ .x = 100, .y = 0 }, .rotation = 0 },
        RigidBody2D{ .body_type = 0 },
        Collider2D{ .kind = 0, .size = .{ .x = 10, .y = 100 } },
    }) catch return false;
    const ball_e = world.spawn(.{
        Transform{ .position = .{ .x = 0, .y = 0 }, .rotation = 0 },
        RigidBody2D{ .body_type = 2 }, // dynamic
        Collider2D{ .kind = 1, .size = .{ .x = 8, .y = 8 } },
    }) catch return false;

    phys.syncLoad(&world);

    const input = context_mod.Input{};
    var ctx = bindings.Context.init(&world, &input);
    // The one line that makes physics reachable from Lua at all.
    ctx.physics = &phys;
    bindings.registerAll(L, &ctx);

    var ok = true;

    // Publish the stamped `self` as a global. `runWithSelf` calls the chunk with
    // zero arguments, so a vararg would arrive as nil; and a global is closer to
    // what a behavior actually sees anyway.
    lua.lua_createtable(L, 0, 1); // [T]
    lua.lua_createtable(L, 0, 1); // [T, self]
    bindings.stampEntityForTest(L, ball_e);
    lua.setField(L, -2, "__actor_self");
    lua.setGlobal(L, "T");

    // A stepper, so the Lua-side checks can advance the simulation. Without it
    // they would read state that a real frame never produces: an impulse is
    // queued and only lands once something steps, so a check that never steps
    // proves the binding "works" exactly when it is doing nothing.
    const step_lua = struct {
        fn call(state: ?*lua.lua_State) callconv(.c) c_int {
            const c = bindings.ctxFromUpvalue(state);
            const sys = c.physics orelse return 0;
            var i: f32 = 0;
            const frames = lua.toF32(state, 1);
            while (i < frames) : (i += 1) {
                _ = sys.step(c.world, 1.0 / 60.0);
            }
            return 0;
        }
    }.call;
    // Through `installModule`, NOT a bare `setFuncs`: the context travels as a
    // shared upvalue, and a function registered without it panics on the first
    // call. The helper is exported for exactly this.
    const step_regs = [_]lua.luaL_Reg{.{ .name = "step", .func = step_lua }, .{ .name = null, .func = null }};
    bindings.installModule(L, &ctx, "TSTEP", &step_regs);

    // Each assertion is run as its own chunk so one failure does not mask the
    // rest, and each prints its own name.
    const cases = [_]struct { name: []const u8, src: []const u8 }{
        .{
            .name = "cast_ray finds a wall and reports where",
            .src =
            \\local self = T.__actor_self
            \\local hit, t, px, py = physics.cast_ray(0, 0, 200, 0)
            \\return hit == true and t > 0.4 and t < 0.6 and px > 80 and px < 120 and py == 0
            ,
        },
        .{
            .name = "cast_ray reports clear when nothing is in the way",
            .src =
            \\local self = T.__actor_self
            \\return physics.cast_ray(0, -60, 200, -60) == false
            ,
        },
        .{
            .name = "line_of_sight is the same question, cheaper",
            .src =
            \\local self = T.__actor_self
            \\return physics.line_of_sight(0, 0, 200, 0) == false
            \\   and physics.line_of_sight(0, -60, 200, -60) == true
            ,
        },
        .{
            .name = "apply_impulse is queued, then takes effect on the next step",
            .src =
            \\local self = T.__actor_self
            \\actor.set_linear_velocity(self, 0, 0)
            \\actor.apply_impulse(self, 0, -4000)
            \\-- queued, not applied: nothing has stepped yet
            \\local _, vy0 = actor.get_linear_velocity(self)
            \\TSTEP.step(1)
            \\local vx, vy = actor.get_linear_velocity(self)
            \\return vy0 == 0 and vy < -1
            ,
        },
        .{
            .name = "set_linear_velocity survives a step instead of being overwritten",
            .src =
            \\local self = T.__actor_self
            \\actor.set_linear_velocity(self, 33, 0)
            \\TSTEP.step(1)
            \\local vx, vy = actor.get_linear_velocity(self)
            \\-- gravity is off in this fixture, so x must survive the step intact
            \\return vx > 30 and vx <= 33 and vy == 0
            ,
        },
        .{
            .name = "physics.stats reports a broadphase that is actually rejecting pairs",
            .src =
            \\local self = T.__actor_self
            \\local s = physics.stats()
            \\-- These are the counters that distinguish "the solver is working"
            \\-- from "the solver is running and the broadphase stopped helping".
            \\return s ~= nil
            \\   and s.bodies >= 3
            \\   and s.pairs_per_body >= 0
            \\   and s.pairs_per_body < s.bodies
            \\   and s.sleeping >= 0 and s.sleeping <= s.bodies
            \\   and s.active_fraction >= 0 and s.active_fraction <= 1
            ,
        },
        .{
            .name = "physics.set_view culls without deleting the world",
            .src =
            \\local self = T.__actor_self
            \\-- A view that contains nothing the camera can see.
            \\physics.set_view(100000, 100000, 1, 1, true)
            \\TSTEP.step(1)
            \\local away = physics.stats()
            \\-- Back to where the bodies actually are.
            \\physics.set_view(0, 0, 1000, 1000, true)
            \\TSTEP.step(1)
            \\local here = physics.stats()
            \\return here.simulated >= away.simulated
            ,
        },
        .{
            .name = "the editor can place, resize and retune a shape",
            .src =
            \\local self = T.__actor_self
            \\physics.create_shape(self, 0, 20, 20)   -- a box
            \\TSTEP.step(1)
            \\physics.reshape(self, 1, 8, 8)         -- now a circle, smaller
            \\physics.set_material(self, 0.9, 0.2, 1.0)
            \\TSTEP.step(1)
            \\-- Reshaping repeatedly must not break the body: this is the
            \\-- drag-a-handle path, and it fires every frame.
            \\for i = 1, 20 do physics.reshape(self, 0, 10 + i, 10 + i) end
            \\TSTEP.step(1)
            \\local vx, vy = actor.get_linear_velocity(self)
            \\return vx == vx and vy == vy   -- still a live body
            ,
        },
        .{
            .name = "the editor can toggle collision without losing the shape",
            .src =
            \\local self = T.__actor_self
            \\physics.set_body_enabled(self, false)
            \\TSTEP.step(1)
            \\physics.set_body_enabled(self, true)
            \\TSTEP.step(1)
            \\local hit = physics.cast_ray(0, 0, 200, 0)
            \\return hit == true
            ,
        },
        .{
            .name = "overlap_rect finds a shape the editor can select",
            .src =
            \\local self = T.__actor_self
            \\physics.create_shape(self, 0, 10, 10)
            \\TSTEP.step(1)
            \\local n, found = physics.overlap_rect(0, 0, 60, 60)
            \\-- The wall at x=100 and the ball at the origin are both in that box.
            \\return n >= 1 and found ~= nil
            ,
        },
        .{
            .name = "contains_point picks what a click lands on",
            .src =
            \\local self = T.__actor_self
            \\local hit = physics.contains_point(0, 0)
            \\return hit ~= nil
            ,
        },
        .{
            .name = "a prototype can be drawn with no texture at all",
            .src =
            \\local self = T.__actor_self
            \\sprite.rect(self, 32, 48, 1, 0, 0, 1)
            \\sprite.circle(self, 24, 0, 1, 0, 0.5)
            \\sprite.set_layer(self, 3)
            \\-- And then given real art, which is the whole point of prototyping
            \\-- with primitives: it is one call, not a rewrite.
            \\sprite.texture(self, 64, 64, 2, 0, 0, 0.5, 0.5)
            \\return true
            ,
        },
        .{
            .name = "render reports culled separately from hidden",
            .src =
            \\local self = T.__actor_self
            \\render.set_view(0, 0, 480, 270)
            \\local entities, drawn, culled, hidden = render.stats()
            \\-- Four numbers, and culled is not hidden: one is the engine
            \\-- saving work, the other is a decision somebody made.
            \\return entities >= 0 and drawn >= 0 and culled >= 0 and hidden >= 0
            ,
        },
        .{
            .name = "the editor can add, inspect and remove a component",
            .src =
            \\local self = T.__actor_self
            \\-- Godot's model: an actor is a bag of components.
            \\if actor.has_component(self, "Sprite") then actor.remove_component(self, "Sprite") end
            \\local added = actor.add_component(self, "Sprite")
            \\if not added then return false end
            \\-- adding twice is refused rather than duplicating
            \\if actor.add_component(self, "Sprite") then return false end
            \\if not actor.has_component(self, "Sprite") then return false end
            \\sprite.set_size(self, 40, 24)
            \\sprite.set_tint(self, 1, 0, 0, 1)
            \\local w, h = sprite.get_size(self)
            \\local r, g, b, a = sprite.get_tint(self)
            \\-- and Transform cannot be removed: everything assumes it exists
            \\local no_transform = actor.remove_component(self, "Transform")
            \\local gone = actor.remove_component(self, "Sprite")
            \\return w == 40 and h == 24 and r == 1 and g == 0 and no_transform == false and gone == true
            ,
        },
        .{
            .name = "a light and an occluder can be configured and read back",
            .src =
            \\local self = T.__actor_self
            \\light.new(self, 0, 192, 1.0, 0.69, 0.41, 1)
            \\light.set_cone(self, 45, 0.25)
            \\light.set_shadow(self, true, 2, 2)
            \\light.set_mask(self, 255)
            \\local r, e = light.get_radius(self), light.get_energy(self)
            \\local degs, pen = light.get_cone(self)
            \\local casts, filter, smooth = light.get_shadow(self)
            \\-- A manual occluder: the shape, not the sprite's alpha.
            \\occluder.new(self, 1)
            \\occluder.set_mode(self, 1)
            \\occluder.set_threshold(self, 0.6)
            \\occluder.set_mask(self, 255)
            \\occluder.set_polygon(self, {0, 0, 32, 0, 32, 48, 0, 48})
            \\local pts = occluder.get_polygon(self)
            \\local mode = occluder.get_mode(self)
            \\return r == 192 and e == 1 and degs == 45 and pen == 0.25
            \\    and casts == true and filter == 2 and smooth == 2
            \\    and mode == 1 and #pts == 8 and pts[1] == 0 and pts[5] == 48
            ,
        },
        .{
            .name = "the inspector surface: kind_of, describe and the GI/bloom fields",
            // What an editor's light panel is built on. `kind_of` decides which
            // panel to draw, `describe` decides which fields, and the
            // environment setters are the only way GI and bloom can be reached
            // from a scene at all — they had no bindings before this.
            .src =
            \\local self = T.__actor_self
            \\-- "no light" is nil, not a kind: an inspector must be able to tell
            \\-- "this actor has no light" from "this actor has a broken one".
            \\if light.kind_of(self) ~= nil then return false end
            \\point.new(self, 192)
            \\if light.kind_of(self) ~= "point" then return false end
            \\local d = light.describe(self)
            \\if d.radius ~= 192 then return false end
            \\if d.cast_shadows == nil then return false end
            \\-- The mask that used to be a field nothing read.
            \\light.set_mask(self, 4)
            \\if light.describe(self).item_cull_mask ~= 4 then return false end
            \\-- A spot is a DIFFERENT panel with an EXTRA field.
            \\local other = T.__spawn()
            \\spot.new(other, 300)
            \\spot.set_cone(other, 45, 0.25)
            \\if light.kind_of(other) ~= "spot" then return false end
            \\local sd = light.describe(other)
            \\if sd.cone_angle == nil or sd.penumbra == nil then return false end
            \\-- And the shared fields are under the SAME names in both, which is
            \\-- why `describe` is flat.
            \\if sd.energy == nil or sd.radius == nil then return false end
            \\-- GI and bloom were unreachable: no environment.new, and no setter
            \\-- for the sky, the GI switch, or the intensity that actually turns
            \\-- the chain on.
            \\environment.new(self)
            \\environment.set_sky(self, 0.4, 0.45, 0.6)
            \\local r, g, b = environment.get_sky(self)
            \\if r ~= 0.4 or g ~= 0.45 or b ~= 0.6 then return false end
            
            \\environment.set_bloom(self, 0.4, 0.85)
            \\local amb = environment.get_ambient(self)
            \\return amb ~= nil and r == 0.4
            ,
        },
        .{
            .name = "lighting.quality reports -1 with no system and never lies",
            // The editor's quality dropdown. With no driver wired it must say
            // -1 rather than 0, because "there is no lighting system" and "the
            // lighting system is off" send the user looking for different bugs.
            .src =
            \\local self = T.__actor_self
            \\local q = lighting.quality()
            \\if q ~= -1 then return false end
            \\if lighting.set_quality(2) ~= false then return false end
            \\-- And the stats table is empty rather than nil, so an inspector can
            \\-- read it without a guard.
            \\local s = lighting.stats()
            \\if s == nil then return false end
            \\return next(s) == nil
            ,
        },
        .{
            .name = "a body at rest reads as not awake, an impulse wakes it",
            .src =
            \\local self = T.__actor_self
            \\actor.set_linear_velocity(self, 0, 0)
            \\TSTEP.step(2)
            \\local was_awake = actor.is_awake(self)
            \\actor.apply_impulse(self, 5000, 0)
            \\TSTEP.step(1)
            \\local now_awake = actor.is_awake(self)
            \\return was_awake == false and now_awake == true
            ,
        },
    };

    for (cases) |c| {
        const pass = runWithSelf(L, &vm, c.src);
        if (pass) {
            std.debug.print("  ok    physics: {s}\n", .{c.name});
        } else {
            std.debug.print("  FAIL  physics: {s}\n", .{c.name});
            ok = false;
        }
    }

    _ = floor_e;
    _ = wall_e;
    return ok;
}

/// Runs `src` as a chunk that receives the stamped `self` as its vararg.
fn runWithSelf(L: ?*lua.lua_State, vm: *vm_mod.Vm, src: []const u8) bool {
    vm.loadBuffer(src, "physics_acceptance") catch return false;
    if (lua.lua_pcall(L, 0, 1, 0) != 0) {
        var msg_buf: [256]u8 = undefined;
        if (vm.readError(&msg_buf)) |msg| {
            std.debug.print("  lua error: {s}\n", .{msg});
        }
        return false;
    }
    return lua.toBool(L, 1);
}

// ── State machines (M4.5) ────────────────────────────────────────────────────
// Driven from Zig rather than from a Lua script, and that is deliberate: the
// `sm.*` bindings only work on a behavior's `self` table, and the tick is a
// C-side pass a script cannot drive. This builds the same shape the behavior
// layer builds — real Lua callbacks, refed, attached to a machine, ticked —
// then reads back what ran. Checking it any other way would exercise a
// different path than a game takes.

/// The chunk that defines the state callbacks and a global table to record what
/// ran. Re-run before each scenario so the counters start at zero.
const sm_setup_src =
    \\_SM = { trace = "", enters = 0, updates = 0 }
    \\_SM.hooks = {
    \\  idle = {
    \\    enter  = function(self) _SM.trace = _SM.trace .. "i>"; _SM.enters = _SM.enters + 1 end,
    \\    update = function(self) _SM.updates = _SM.updates + 1 end,
    \\    exit   = function(self) _SM.trace = _SM.trace .. "i<" end,
    \\  },
    \\  chase = {
    \\    enter  = function(self) _SM.trace = _SM.trace .. "c>" end,
    \\    update = function(self) _SM.updates = _SM.updates + 1 end,
    \\    exit   = function(self) _SM.trace = _SM.trace .. "c<" end,
    \\  },
    \\}
;

/// Reads the string field `key` of the global `_SM` table.
fn smString(L: ?*lua.lua_State, key: [*:0]const u8) []const u8 {
    lua.getGlobal(L, "_SM");
    defer lua.pop(L, 1);
    lua.getField(L, -1, key); // [_SM, value]
    defer lua.pop(L, 1);
    return lua.toSlice(L, -1) orelse "";
}

/// Reads the number field `key` of the global `_SM` table.
fn smNumber(L: ?*lua.lua_State, key: [*:0]const u8) f64 {
    lua.getGlobal(L, "_SM");
    defer lua.pop(L, 1);
    lua.getField(L, -1, key);
    defer lua.pop(L, 1);
    if (!lua.isNumber(L, -1)) return -1;
    return lua.lua_tonumber(L, -1);
}

/// Refs `_SM.hooks[state][hook]`, or `no_ref` when it is not a function.
/// Both indexes are needed: `hooks` is a table of tables.
fn smHookRef(L: ?*lua.lua_State, state: [*:0]const u8, hook: [*:0]const u8) i32 {
    lua.getGlobal(L, "_SM"); // [_SM]
    lua.getField(L, -1, "hooks"); // [_SM, hooks]
    lua.getField(L, -1, state); // [_SM, hooks, state]
    lua.getField(L, -1, hook); // [_SM, hooks, state, fn]
    if (!lua.isFunction(L, -1)) {
        lua.pop(L, 1);
        return statemachine.no_ref;
    }
    const ref: i32 = @intCast(lua.luaL_ref(L, lua.REGISTRYINDEX)); // pops
    lua.pop(L, 2); // hooks, _SM
    return ref;
}

/// One scenario. `fail` receives the specific reason on the first mismatch.
const SmCheck = struct {
    name: []const u8,
    run: *const fn (L: ?*lua.lua_State, reg: *statemachine.Registry, bi: usize, fail: *[]const u8) bool,
};

fn sm_enters_once(L: ?*lua.lua_State, reg: *statemachine.Registry, bi: usize, fail: *[]const u8) bool {
    _ = bi;
    reg.tick();
    if (smNumber(L, "enters") != 1) {
        fail.* = "enter should run exactly once on the first tick";
        return false;
    }
    reg.tick();
    reg.tick();
    if (smNumber(L, "updates") != 3) {
        fail.* = "update should run once per tick";
        return false;
    }
    if (smNumber(L, "enters") != 1) {
        fail.* = "enter must not re-run on later ticks";
        return false;
    }
    return true;
}

fn sm_transition_order(L: ?*lua.lua_State, reg: *statemachine.Registry, bi: usize, fail: *[]const u8) bool {
    reg.tick(); // enter idle
    reg.fire(bi, "see_player");
    reg.tick(); // exit idle -> enter chase
    const state = reg.stateName(reg.bindings[bi].machine, reg.currentState(bi));
    if (!std.mem.eql(u8, state, "chase")) {
        fail.* = "firing see_player should move idle -> chase";
        return false;
    }
    if (!std.mem.eql(u8, smString(L, "trace"), "i>i<c>")) {
        fail.* = "hooks must run enter(old), exit(old), enter(new) in that order";
        return false;
    }
    return true;
}

fn sm_unfired_event_is_ignored(_: ?*lua.lua_State, reg: *statemachine.Registry, bi: usize, fail: *[]const u8) bool {
    reg.tick();
    reg.fire(bi, "no_such_event");
    reg.tick();
    const state = reg.stateName(reg.bindings[bi].machine, reg.currentState(bi));
    if (!std.mem.eql(u8, state, "idle")) {
        fail.* = "an event with no matching transition must not move the machine";
        return false;
    }
    return true;
}

fn sm_set_state_is_immediate(L: ?*lua.lua_State, reg: *statemachine.Registry, bi: usize, fail: *[]const u8) bool {
    reg.tick();
    const chase = reg.stateIndex(reg.bindings[bi].machine, "chase") orelse return false;
    reg.setState(bi, chase);
    // No tick in between: the jump and its hooks must already have happened.
    const got = reg.stateName(reg.bindings[bi].machine, reg.currentState(bi));
    if (!std.mem.eql(u8, got, "chase")) {
        fail.* = "set_state must move the machine immediately";
        return false;
    }
    if (!std.mem.eql(u8, smString(L, "trace"), "i>i<c>")) {
        fail.* = "set_state must run exit then enter without waiting for a tick";
        return false;
    }
    return true;
}

fn sm_returns_to_idle(L: ?*lua.lua_State, reg: *statemachine.Registry, bi: usize, fail: *[]const u8) bool {
    reg.tick();
    reg.fire(bi, "see_player");
    reg.tick(); // now in chase
    reg.fire(bi, "lost_player");
    reg.tick(); // back to idle
    const state = reg.stateName(reg.bindings[bi].machine, reg.currentState(bi));
    if (!std.mem.eql(u8, state, "idle")) {
        fail.* = "a two-step transition chain should return to idle";
        return false;
    }
    if (!std.mem.eql(u8, smString(L, "trace"), "i>i<c>c<i>")) {
        fail.* = "chase exit and idle re-enter should both have run";
        return false;
    }
    return true;
}

const sm_checks = [_]SmCheck{
    .{ .name = "enter runs once, update runs every tick", .run = sm_enters_once },
    .{ .name = "a transition runs exit(old) then enter(new)", .run = sm_transition_order },
    .{ .name = "an event with no transition changes nothing", .run = sm_unfired_event_is_ignored },
    .{ .name = "set_state jumps immediately, hooks included", .run = sm_set_state_is_immediate },
    .{ .name = "a transition chain returns to the first state", .run = sm_returns_to_idle },
};

/// Runs every state-machine scenario. Each gets a fresh registry and a fresh
/// counter table, so one scenario cannot pass on another's leftovers.
fn checkStateMachines(allocator: std.mem.Allocator) bool {
    var all_ok = true;
    for (sm_checks) |check| {
        // The whole scenario lives in its own block so the teardown order is
        // enforced by scope rather than by hand: the registry holds Lua refs, so
        // it MUST be destroyed before the VM it refs into. Getting that backwards
        // closes the state out from under `luaL_unref` and aborts inside LuaJIT.
        const ok = blk: {
            // A fresh VM per scenario: re-running the setup chunk is not enough,
            // because the previous machine's refs are still live in the old VM.
            var vm = vm_mod.Vm.init(allocator) catch break :blk false;
            defer vm.deinit();
            const SL = vm.state() orelse break :blk false;

            var buf: [2048]u8 = undefined;
            const source = std.fmt.bufPrintZ(&buf, "{s}", .{sm_setup_src}) catch break :blk false;
            vm.loadBuffer(source, "sm_acceptance") catch break :blk false;
            if (lua.lua_pcall(SL, 0, 0, 0) != 0) break :blk false;

            var reg = statemachine.Registry.init(allocator, &vm);
            defer reg.deinit();

            const machine = reg.createMachine();
            const idle = reg.addState(machine, "idle") catch break :blk false;
            const chase = reg.addState(machine, "chase") catch break :blk false;
            reg.addTransition(machine, "idle", "see_player", "chase") catch break :blk false;
            reg.addTransition(machine, "chase", "lost_player", "idle") catch break :blk false;
            reg.setInitial(machine, "idle") catch break :blk false;

            reg.machines[machine].states[idle].enter_ref = smHookRef(SL, "idle", "enter");
            reg.machines[machine].states[idle].update_ref = smHookRef(SL, "idle", "update");
            reg.machines[machine].states[idle].exit_ref = smHookRef(SL, "idle", "exit");
            reg.machines[machine].states[chase].enter_ref = smHookRef(SL, "chase", "enter");
            reg.machines[machine].states[chase].update_ref = smHookRef(SL, "chase", "update");
            reg.machines[machine].states[chase].exit_ref = smHookRef(SL, "chase", "exit");

            // An actor `self` table, exactly what the behavior layer would stamp
            // onto an entity. The tick walks the binding array directly and never
            // needs the entity, so this test does not spawn one — `bindingFor`
            // (which the `sm.*` bindings use to go from an entity to a binding)
            // is the only path that needs it, and those run in a behavior.
            lua.lua_createtable(SL, 0, 0);
            const self_ref: i32 = @intCast(lua.luaL_ref(SL, lua.REGISTRYINDEX));
            _ = reg.attach(machine, self_ref) catch break :blk false;

            const bi: usize = 0; // the only binding in a fresh registry
            var reason: []const u8 = "unspecified";
            if (!check.run(SL, &reg, bi, &reason)) {
                std.debug.print("  FAIL  {s}: {s}\n", .{ check.name, reason });
                all_ok = false;
            }
            break :blk true;
        };
        if (ok) std.debug.print("  ok    {s}\n", .{check.name});
    }
    return all_ok;
}

// ── Steering + spatial queries (M4.5) ────────────────────────────────────────
// Runs in this executable rather than under `zig test` for the same reason the
// state machines do: a live LuaJIT state aborts inside Zig's test runner.

/// Loads `script`, runs it, and returns its truthiness. `fail` receives a short
/// reason so the suite prints WHICH assertion broke.
fn eval(L: ?*lua.lua_State, script: []const u8, fail: *[]const u8) bool {
    var buf: [4096]u8 = undefined;
    const source = std.fmt.bufPrintZ(&buf, "{s}", .{script}) catch {
        fail.* = "script exceeds the buffer";
        return false;
    };
    if (lua.luaL_loadbuffer(L, source.ptr, source.len, "@steer_check") != 0) {
        fail.* = lua.toSlice(L, -1) orelse "syntax error";
        lua.pop(L, 1);
        return false;
    }
    if (lua.lua_pcall(L, 0, 1, 0) != 0) {
        fail.* = lua.toSlice(L, -1) orelse "runtime error";
        lua.pop(L, 1);
        return false;
    }
    const ok = lua.toBool(L, -1);
    lua.pop(L, 1);
    if (!ok) fail.* = "assertion returned false";
    return ok;
}

/// One steering scenario: a Lua script that returns true when it holds.
const SteerCheck = struct {
    name: []const u8,
    script: []const u8,
};

const steer_checks = [_]SteerCheck{
    .{ .name = "steer.at returns an accumulator and seek aims at the target", .script =
    \\local a = steer.at(0, 0)
    \\if a == nil then return false end
    \\local vx, vy = a:seek(10, 0):apply(100)
    \\return math.abs(vx - 100) < 0.01 and math.abs(vy) < 0.01
    },
    .{ .name = "apply clamps the SUM, not each term", .script =
    \\local a = steer.at(0, 0)
    \\a:seek(1000, 0, 1)
    \\a:seek(-1000, 0, 1)
    \\a:seek(0, 1000, 1)
    \\local vx, vy = a:apply(50)
    \\local speed = math.sqrt(vx * vx + vy * vy)
    \\-- three unit forces must not produce a 3x speedup
    \\return speed <= 50.01
    },
    .{ .name = "each term is normalized, so distance does not change its weight", .script =
    \\local far = steer.at(0, 0)
    \\far:seek(1000, 0, 1)
    \\local fv = select(1, far:apply(10))
    \\local near = steer.at(0, 0)
    \\near:seek(1, 0, 1)
    \\local nv = select(1, near:apply(10))
    \\return math.abs(fv - nv) < 0.001
    },
    // `apply` normalizes, so a lone arrive always yields the cap regardless of
    // weight — weight only shows up in COMPOSITION. So the braking is checked
    // against a competing force: close in, arrive's pull is weaker and the
    // other term wins more of the heading.
    .{ .name = "arrive brakes inside the slow radius", .script =
    \\local far = steer.at(0, 0)
    \\far:arrive(100, 0, 10, 1)   -- full-strength pull to the right
    \\far:flee(0, 100, 1)         -- competing pull upward
    \\local _, fy = far:apply(100)
    \\local near = steer.at(0, 0)
    \\near:arrive(5, 0, 10, 1)    -- half-strength: we are close
    \\near:flee(0, 100, 1)
    \\local _, ny = near:apply(100)
    \\-- Braking means arrive pulls weaker, so the competing force claims
    \\-- MORE of the heading: `ny` lands further from zero than `fy`
    \\-- (the vectors point down, so more braking = more negative).
    \\return ny < fy
    },
    .{ .name = "flee points away from the threat", .script =
    \\local a = steer.at(0, 0)
    \\local vx = select(1, a:flee(10, 0):apply(100))
    \\return vx < -99
    },
    .{ .name = "the neighbour terms run over a populated world", .script =
    \\local a = steer.at(0, 0)
    \\a:separate(100, 1.5)
    \\a:align(100, 1.0)
    \\a:cohere(100, 0.7)
    \\local vx, vy = a:apply(120)
    \\-- NaN check: a division by a zero-length average would show up here
    \\return vx == vx and vy == vy
    },
    .{ .name = "a behaviour of no terms yields no velocity", .script =
    \\local vx, vy = steer.at(0, 0):apply(100)
    \\return vx == 0 and vy == 0
    },
};

/// Builds a world with behaviours attached and a live spatial grid, publishes
/// the `steer` global exactly as `Behaviors.buildSteer` does, and runs every
/// scenario against it.
fn checkSteering(allocator: std.mem.Allocator) bool {
    var vm = vm_mod.Vm.init(allocator) catch return false;
    defer vm.deinit();
    const L = vm.state() orelse return false;

    var world = ecs.World.init(allocator);
    defer world.deinit();

    const input = context_mod.Input{};
    var ctx = bindings.Context.init(&world, &input);
    var reg = statemachine.Registry.init(allocator, &vm);
    defer reg.deinit();
    var grid = spatial.Grid.init(allocator, spatial.default_cell_size, spatial.default_extent, 64) catch return false;
    defer grid.deinit();
    ctx.machines = &reg;
    ctx.spatial = &grid;
    bindings.registerAll(L, &ctx);

    // A handful of actors, so the neighbour terms have real neighbours instead
    // of trivially finding nothing.
    var i: usize = 0;
    while (i < 8) : (i += 1) {
        _ = world.spawn(.{ecs.components.Transform{ .position = .{
            .x = @as(f32, @floatFromInt(i)) * 10,
            .y = 0,
        } }}) catch break;
    }
    grid.rebuild(&world);

    // Publish `steer`, the same way the behavior layer does.
    if (lua.luaL_loadbuffer(L, steer.source, steer.source.len, "@steer") != 0) {
        std.debug.print("  FAIL  steer module does not compile: {s}\n", .{lua.toSlice(L, -1) orelse "?"});
        return false;
    }
    if (lua.lua_pcall(L, 0, 1, 0) != 0) {
        std.debug.print("  FAIL  steer module raised: {s}\n", .{lua.toSlice(L, -1) orelse "?"});
        return false;
    }
    // Publish the MODULE table (the stack top), so scripts get `steer.at(...)`
    // rather than a callable global.
    lua.setGlobal(L, "steer");
    lua.pop(L, 1);

    var all_ok = true;
    for (steer_checks) |check| {
        var reason: []const u8 = "unspecified";
        if (eval(L, check.script, &reason)) {
            std.debug.print("  ok    {s}\n", .{check.name});
        } else {
            std.debug.print("  FAIL  {s}: {s}\n", .{ check.name, reason });
            all_ok = false;
        }
    }
    return all_ok;
}

// ── Audio (M8) ───────────────────────────────────────────────────────────────
// The audio bindings' correctness depends on state that lives outside Lua: the
// system owns whether a voice is live. An `audio.is_playing` stub that always
// returned true would pass a pure-Lua test and break every one-shot, so these
// drive a real `Audio` on the null backend and read the answer back out.

/// Runs a chunk that returns one boolean. Separate from `runCheck` because the
/// audio check needs the SAME VM across steps (it pumps the device between
/// them), which `runCheck`'s fresh VM per call cannot provide.
///
/// The result is read from the TOP and POPPED, which is the fix for a bug that
/// made every check below vacuous: `loadBuffer` leaves the compiled function on
/// the stack and `lua_pcall` leaves its result on top of it, so with the result
/// never popped, check N read whatever check 1 left at index 1 — a `true` that
/// had nothing to do with the code that had just run. A check whose assertions
/// all failed still reported `ok`. The stack is the state here; index -1 is the
/// answer to THIS call.
fn runSrcBool(vm: *vm_mod.Vm, src: [:0]const u8, label: [*:0]const u8) bool {
    const L = vm.state() orelse return false;
    vm.loadBuffer(src, label) catch |e| {
        std.debug.print("  loadBuffer failed: {s}\n", .{@errorName(e)});
        return false;
    };
    if (lua.lua_pcall(L, 0, 1, 0) != 0) {
        var msg_buf: [256]u8 = undefined;
        if (vm.readError(&msg_buf)) |msg| std.debug.print("  lua error: {s}\n", .{msg});
        lua.pop(L, 1); // the error message, so the next check starts clean
        return false;
    }
    const ok = lua.toBool(L, -1);
    lua.pop(L, 1);
    return ok;
}

fn checkAudio(allocator: std.mem.Allocator) bool {
    var vm = vm_mod.Vm.init(allocator) catch {
        std.debug.print("  Vm.init failed\n", .{});
        return false;
    };
    defer vm.deinit();
    const L = vm.state() orelse {
        std.debug.print("  Vm has no state\n", .{});
        return false;
    };

    var world = ecs.World.init(allocator);
    defer world.deinit();
    const input = context_mod.Input{};
    var ctx = bindings.Context.init(&world, &input);

    // The one line that makes audio reachable from Lua at all.
    const sys = audio.Audio.create(allocator, .null, .{ .voices = 16, .budget_bytes = 1 << 20 }) catch {
        std.debug.print("  Audio.create failed\n", .{});
        return false;
    };
    defer sys.destroy();
    // Named buses beyond master, so the mixer-panel surface (solo, sends) has
    // something to point at. Load time only, which is where this runs.
    sys.defineBuses(&.{ "master", "music", "sfx" }) catch {
        std.debug.print("  defineBuses failed\n", .{});
        return false;
    };
    ctx.audio = sys;
    bindings.registerAll(L, &ctx);

    // 1. A play returns a handle synchronously (the device fills it in later).
    if (!runSrcBool(
        &vm,
        \\V = audio.play_file("boom:100", { loop = true, bus_name = "master" })
        \\return V ~= nil
    , "audio_play")) {
        std.debug.print("  FAIL audio.play_file did not return a handle\n", .{});
        return false;
    }

    // The device thread starts the sound on its next buffer. The headless
    // backend is pumped by hand, exactly as the bench does.
    sys.pump(64);

    // 2. It is playing; buses, gains and stats are all readable; the controls
    //    write and the stop lands.
    if (!runSrcBool(
        &vm,
        \\if not audio.is_playing(V) then return false end
        \\audio.set_bus_volume("master", 0.5)
        \\if math.abs(audio.bus_gain("master") - 0.5) > 0.001 then return false end
        \\audio.set_master_volume(0.8)
        \\audio.set_listener(10, 20, 1.2)  -- rotation is accepted
        \\local s = audio.stats()
        \\if s.xruns ~= 0 then return false end
        \\if s.latency_ms > 20 then return false end
        \\if s.voices_active ~= 1 then return false end
        \\local b = audio.buses()
        \\if #b < 1 then return false end
        \\if b[1].name ~= "master" then return false end
        \\audio.solo_bus("sfx", true)
        \\local soloed = false
        \\for _, bus in ipairs(audio.buses()) do
        \\  if bus.name == "sfx" and bus.solo then soloed = true end
        \\end
        \\if not soloed then return false end
        \\audio.solo_bus("sfx", false)
        \\audio.set_bus_send("sfx", "music", 0.25)
        \\local sent = false
        \\for _, bus in ipairs(audio.buses()) do
        \\  if bus.name == "sfx" and bus.send_amount > 0.2 then sent = true end
        \\end
        \\if not sent then return false end
        \\audio.set_volume(V, 0.5)
        \\audio.set_pitch(V, 0.5)
        \\audio.stop(V)
        \\return true
    , "audio_state")) {
        std.debug.print("  FAIL audio state / buses / stats / stop\n", .{});
        return false;
    }

    sys.pump(64);

    // 3. The stopped handle is stale: is_playing is false and a second stop is
    //    a no-op, not an error.
    if (!runSrcBool(
        &vm,
        \\if audio.is_playing(V) then return false end
        \\audio.stop(V)
        \\audio.stop_all()
        \\return true
    , "audio_stale")) {
        std.debug.print("  FAIL a stopped voice still reads as playing\n", .{});
        return false;
    }

    // 4. A STREAMED sound: `play_stream` opens a window instead of decoding the
    //    whole file. It starts like any other voice and the window is fed by
    //    `beginFrame`/`refillStreams` (called just below).
    if (!runSrcBool(
        &vm,
        \\local S = audio.play_stream("long:4000", { volume = 1.0 })
        \\if S == nil then return false end
        \\STREAMV = S
        \\return true
    , "audio_stream_start")) {
        std.debug.print("  FAIL audio.play_stream did not return a handle\n", .{});
        return false;
    }
    // The frame loop's refill, then a buffer: the stream becomes live.
    sys.beginFrame(1);
    sys.pump(480);
    if (!runSrcBool(
        &vm,
        \\if not audio.is_playing(STREAMV) then return false end
        \\return true
    , "audio_stream_playing")) {
        std.debug.print("  FAIL a streamed voice never became live\n", .{});
        return false;
    }
    // Let it drain and stop it: a streaming voice stops like any other.
    sys.beginFrame(2);
    sys.pump(480);
    if (!runSrcBool(
        &vm,
        \\audio.stop(STREAMV)
        \\return true
    , "audio_stream_stop")) {
        std.debug.print("  FAIL could not stop a streamed voice\n", .{});
        return false;
    }

    // 5. `sound.*`: the per-actor emitter. Two things this checks that
    //    `audio.*` cannot: the voice carries the ACTOR's transform (a
    //    positional play is the whole point of the component), and the
    //    component is the configuration an inspector reads back.
    const actor = world.spawn(.{ecs.components.Transform{ .position = .{ .x = 300, .y = 40 } }}) catch {
        std.debug.print("  spawn failed\n", .{});
        return false;
    };
    // A behaviour-shaped `self`: one table with the entity stamped in, exactly
    // what `behavior.zig` does for a real instance.
    _ = lua.lua_createtable(L, 0, 1);
    bindings.stampEntityForTest(L, actor);
    lua.setGlobal(L, "SELF");   // pops the table: [..] -> [..]

    if (!runSrcBool(
        &vm,
        \\local V = sound.play(SELF, "boom:100", { volume = 0.5 })
        \\if V == nil then return false end
        \\SOUNDV = V
        \\return true
    , "sound_play")) {
        std.debug.print("  FAIL sound.play did not return a handle\n", .{});
        return false;
    }
    sys.pump(64);

    // The Zig half of the check: the voice the binding started must sit at the
    // actor's coordinates, which is the difference between `audio.play_file`
    // and an emitter. Read back through the component the binding wrote.
    if (world.get(actor, ecs.components.SoundEmitter2D)) |em| {
        const id = audio.VoiceId{ .index = em.playing.index, .generation = em.playing.generation };
        const v = sys.pool.resolve(id) orelse {
            std.debug.print("  FAIL the emitter's voice does not resolve\n", .{});
            return false;
        };
        if (v.x != 300 or v.y != 40) {
            std.debug.print("  FAIL the voice is at ({d}, {d}), expected (300, 40)\n", .{ v.x, v.y });
            return false;
        }
        if (v.base_volume != 0.5) {
            std.debug.print("  FAIL the voice's volume is {d}, expected 0.5\n", .{v.base_volume});
            return false;
        }
    } else {
        std.debug.print("  FAIL sound.play did not add a SoundEmitter2D\n", .{});
        return false;
    }

    if (!runSrcBool(
        &vm,
        \\if not sound.is_playing(SELF) then return false end
        \\sound.set_volume(SELF, 0.25)
        \\sound.set_pitch(SELF, 1.5)
        \\local d = sound.describe(SELF)
        \\if d.volume ~= 0.25 then return false end
        \\if d.pitch ~= 1.5 then return false end
        \\if d.path ~= "boom:100" then return false end
        \\if d.max_distance ~= 0 then return false end   -- 0 is global, the default
        \\if not d.playing then return false end
        \\return true
    , "sound_state")) {
        std.debug.print("  FAIL sound state / describe\n", .{});
        return false;
    }

    // The setters that are NEXT-play only must not pretend otherwise: the voice
    // keeps the radius it started with, and the component still reports what
    // the next play will use.
    if (!runSrcBool(
        &vm,
        \\sound.set_radius(SELF, 900)
        \\sound.set_spread(SELF, 200)
        \\sound.set_loop(SELF, true)
        \\local d = sound.describe(SELF)
        \\if d.max_distance ~= 900 then return false end
        \\if d.spread ~= 200 then return false end
        \\if not d.loop then return false end
        \\if not sound.is_playing(SELF) then return false end
        \\return true
    , "sound_next_play")) {
        std.debug.print("  FAIL sound configuration fields\n", .{});
        return false;
    }

    sys.pump(64);
    if (!runSrcBool(
        &vm,
        \\sound.stop(SELF)
        \\if sound.is_playing(SELF) then return false end
        \\sound.stop(SELF)   -- a second stop is a no-op, not an error
        \\return true
    , "sound_stop")) {
        std.debug.print("  FAIL sound.stop / is_playing\n", .{});
        return false;
    }

    // With no audio system wired, the same surface reports failure rather than
    // reaching through null: a headless tool gets nil/false, not a crash.
    {
        var quiet_world = ecs.World.init(allocator);
        defer quiet_world.deinit();
        const quiet_input = context_mod.Input{};
        var quiet_ctx = bindings.Context.init(&quiet_world, &quiet_input);
        bindings.registerAll(L, &quiet_ctx);
        _ = lua.lua_createtable(L, 0, 1);
        bindings.stampEntityForTest(L, actor);
        lua.setGlobal(L, "SELF");   // pops the table: it is now _G.SELF
        if (!runSrcBool(
            &vm,
            \\local a = sound.play(SELF, "boom:100")
            \\local b = sound.is_playing(SELF)
            \\local d = sound.describe(SELF)
            \\if a ~= nil then return false end          -- no system: nil, not a crash
            \\if b then return false end
            \\if type(d) ~= "table" then return false end
            \\if d.volume ~= nil then return false end   -- an empty table: this world has no emitter
            \\return true
        , "sound_no_system")) {
            std.debug.print("  FAIL sound.* with no audio system\n", .{});
            return false;
        }
        // Put the real context back: the checks below must keep working.
        bindings.registerAll(L, &ctx);
        _ = lua.lua_createtable(L, 0, 1);
        bindings.stampEntityForTest(L, actor);
        lua.setGlobal(L, "SELF");   // pops the table: it is now _G.SELF
    }

    std.debug.print("  ok    emitters: positional play, live control, describe, stop\n", .{});
    return true;
}

// ── Animation (M13) ─────────────────────────────────────────────────────────
// A clip is an asset: `anim.load(path)` decodes a `.anim` file, registers it
// and hands back the clip id `anim.play` takes. These checks drive that through
// Lua against a real `animation.System`, because a binding that returned a
// constant id would satisfy a pure-Zig test and break every game.
fn checkAnimation(allocator: std.mem.Allocator) bool {
    var vm = vm_mod.Vm.init(allocator) catch return false;
    defer vm.deinit();
    const L = vm.state() orelse return false;

    var world = ecs.World.init(allocator);
    defer world.deinit();
    const input = context_mod.Input{};
    var ctx = bindings.Context.init(&world, &input);
    var anim_sys = ecs.animation.System.init(allocator);
    defer anim_sys.deinit();
    ctx.animations = &anim_sys;
    bindings.registerAll(L, &ctx);

    // A real file under `.zig-cache` (which exists during a build): the point
    // of the check is that `anim.load` reads and decodes an asset, so a stub
    // path would test nothing.
    const path = ".zig-cache/anim_acceptance.anim";
    const io = std.Io.Threaded.global_single_threaded.io();
    std.Io.Dir.cwd().writeFile(io, .{ .sub_path = path, .data =
        \\clip 1
        \\duration 1.0
        \\flags loop
        \\value transform_x 2 0.0 0.0 1.0 10.0
    }) catch return false;
    defer std.Io.Dir.cwd().deleteFile(io, path) catch {};

    var ok = true;

    var s1_buf: [1024]u8 = undefined;
    const s1 = std.fmt.bufPrintZ(&s1_buf,
        "local id = anim.load([[{s}]])\nreturn type(id) == 'number' and id > 0\n", .{path}) catch return false;
    if (!runSrcBool(&vm, s1, "anim.load")) ok = false;

    // Loading the same path again must return the SAME id (the hot-reload
    // contract the players rely on to keep their time).
    var s2_buf: [1024]u8 = undefined;
    const s2 = std.fmt.bufPrintZ(&s2_buf,
        "local a = anim.load([[{s}]])\nlocal b = anim.load([[{s}]])\nreturn a == b\n", .{ path, path }) catch return false;
    if (!runSrcBool(&vm, s2, "anim.reload")) ok = false;

    // `anim.set_param` writes the player component; `anim.state` reads it back,
    // so the check is a real round-trip through the binding and not a stub.
    const e = world.spawn(.{ecs.components.AnimationPlayer{}}) catch return false;
    _ = lua.lua_createtable(L, 0, 0);
    bindings.stampSelfEntity(L, e);
    lua.setGlobal(L, "_self");
    const s3 = "anim.set_param(_self, \"state\", 5)\nreturn anim.state(_self) == 5\n";
    if (!runSrcBool(&vm, s3, "anim.set_param")) ok = false;

    // ── M13 as an ASSET: preload a project's animation directory ───────────
    // Every `.anim` in the directory is decoded, so a clip is resident before
    // the first scene runs, and each lands under the GUID-derived handle of its
    // path (`clipIdForPath`) — the identity an M6 scene would reference.
    const dir = ".zig-cache/anim_acceptance_dir";
    // Deleted first, not only at the end: a run that crashed half-way through
    // would otherwise leave a `.anim` behind and the next run would preload one
    // file too many.
    std.Io.Dir.cwd().deleteTree(io, dir) catch {};
    std.Io.Dir.cwd().createDirPath(io, dir) catch return false;
    defer std.Io.Dir.cwd().deleteTree(io, dir) catch {};
    for ([_][]const u8{ "idle", "run" }) |name| {
        var pbuf: [128]u8 = undefined;
        const p = std.fmt.bufPrint(&pbuf, "{s}/{s}.anim", .{ dir, name }) catch return false;
        std.Io.Dir.cwd().writeFile(io, .{ .sub_path = p, .data = "clip 1\nduration 1.0\nflags loop\n" }) catch return false;
    }
    const preloaded = anim_sys.preloadDir(dir) catch {
        std.debug.print("  preloadDir could not open {s}\n", .{dir});
        ok = false;
        return false;
    };

    if (preloaded.loaded != 2 or preloaded.failed != 0) {
        std.debug.print("  preloadDir loaded {d}, failed {d} (wanted 2, 0)\n", .{ preloaded.loaded, preloaded.failed });
        ok = false;
    }
    {
        var pbuf: [128]u8 = undefined;
        const p = std.fmt.bufPrint(&pbuf, "{s}/run.anim", .{dir}) catch return false;
        const via_guid = ecs.animation.clipIdForPath(p);
        if (anim_sys.lookupPath(p) != via_guid) {
            std.debug.print("  path -> handle differs from the GUID of '{s}'\n", .{p});
            ok = false;
        }
        if (anim_sys.clips.get(via_guid) == null) {
            std.debug.print("  clip {d} is not resident after preload\n", .{via_guid});
            ok = false;
        }
    }

    // ── M13 method track: `call_lua <t> <script_id> <fn>` ─────────────────
    // A keyframe names a script and a function; the runtime's hook (the one
    // `main.zig` installs, built by `Behaviors.animationMethodHook`) calls it.
    // Driven through the REAL Behaviors VM, so the Lua -> C -> Lua round trip
    // is what is being checked, not a Zig stub.
    var anim_input = context_mod.Input{};
    var behaviors: behavior_mod.Behaviors = undefined;
    behaviors.init(allocator, &world, &anim_input) catch {
        std.debug.print("  Behaviors.init failed\n", .{});
        ok = false;
        return false;
    };
    defer behaviors.deinit();

    const foot_src =
        \\local M = {}
        \\function M:on_footstep()
        \\  footsteps = (footsteps or 0) + 1
        \\end
        \\return M
    ;
    const foot_id_script = behaviors.load("foot.lua", foot_src) catch {
        std.debug.print("  behaviors.load failed\n", .{});
        ok = false;
        return false;
    };
    const foot_actor = world.spawn(.{ ecs.components.AnimationPlayer{}, ecs.components.Transform{} }) catch return false;
    behaviors.attach(foot_actor, foot_id_script) catch {
        std.debug.print("  method track: attach failed\n", .{});
        ok = false;
        return false;
    };
    behaviors.startAll();
    anim_sys.method_hook = behaviors.animationMethodHook();

    // The clip names the script id, so the file is written once the id is
    // known — exactly how an exporter that knows the script table would.
    var foot_path_buf: [128]u8 = undefined;
    const foot_path = std.fmt.bufPrint(&foot_path_buf, "{s}/foot.anim", .{dir}) catch return false;
    var foot_text_buf: [256]u8 = undefined;
    const foot_text = std.fmt.bufPrint(&foot_text_buf,
        "clip 1\nduration 1.0\ncall_lua 0.25 {d} on_footstep\n", .{foot_id_script}) catch return false;
    std.Io.Dir.cwd().writeFile(io, .{ .sub_path = foot_path, .data = foot_text }) catch return false;
    const foot_clip = anim_sys.loadFile(foot_path) catch |err| {
        std.debug.print("  method track: loadFile failed: {s}\n", .{@errorName(err)});
        ok = false;
        return false;
    };
    {
        const p = world.get(foot_actor, ecs.components.AnimationPlayer) orelse return false;
        p.clip_id = foot_clip;
        p.speed = 1.0;
    }

    const no_signals = ecs.timer.SignalBridge{};
    var tick: usize = 0;
    while (tick < 60) : (tick += 1) anim_sys.update(&world, 1.0 / 60.0, no_signals);
    // The keyframe at 0.25 s fired the Lua method ONCE in the first second.
    var s4_buf: [128]u8 = undefined;
    const s4 = std.fmt.bufPrintZ(&s4_buf, "return (footsteps or 0) == 1", .{}) catch return false;
    if (!runSrcBool(&behaviors.vm, s4, "method track")) {
        std.debug.print("  method track: script {d}, clip {d}, behavior errors {d}\n", .{ foot_id_script, foot_clip, behaviors.errors });
        ok = false;
    }

    return ok;
}

pub fn main() !void {
    // A page allocator: each check builds and tears down its own VM and world,
    // and the process is short-lived, so there is nothing to interleave and no
    // reason to pay for a general-purpose allocator's bookkeeping.
    var arena_state = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena_state.deinit();
    const allocator = arena_state.allocator();

    var failed: usize = 0;
    for (checks) |check| {
        const ok = runCheck(allocator, check);
        if (ok) {
            std.debug.print("  ok    {s}\n", .{check.name});
        } else {
            std.debug.print("  FAIL  {s}\n", .{check.name});
            failed += 1;
        }
    }

    // State machines need their own driver (a real VM per scenario), so they
    // run after the source-level checks rather than inside the same loop.
    std.debug.print("\nstate machines (M4.5):\n", .{});
    if (!checkStateMachines(allocator)) failed += 1;

    // Physics likewise needs a real VM *and* a real solver world, and it is the
    // only check that exercises a binding whose answer comes from outside Lua.
    std.debug.print("\nphysics (M4):\n", .{});
    if (!checkPhysics(allocator)) failed += 1;

    std.debug.print("\naudio (M8):\n", .{});
    if (checkAudio(allocator)) {
        std.debug.print("  ok    play/stop/bus/stats through a real system\n", .{});
    } else {
        failed += 1;
    }

    std.debug.print("\nanimation (M13):\n", .{});
    if (checkAnimation(allocator)) {
        std.debug.print("  ok    anim.load registers + hot-reloads a clip; anim.set_param round-trips;\n" ++
            "        preloadDir keys clips by GUID; a call_lua keyframe runs the named script's method\n", .{});
    } else {
        failed += 1;
    }

    // Behind the same flag as the code: with steering off there is no `world`
    // table, and a check that fails for "the feature is compiled out" trains
    // everyone to ignore red.
    if (build_options.steering) {
        std.debug.print("\nsteering + spatial queries (M4.5):\n", .{});
        if (!checkSteering(allocator)) failed += 1;
    } else {
        std.debug.print("\nsteering (M4.5): skipped (-Dsteering is off)\n", .{});
    }

    if (failed != 0) {
        std.debug.print("\n{d} check group(s) FAILED\n", .{failed});
        std.process.exit(1);
    }
    if (build_options.steering) {
        std.debug.print("\nall {d} checks + {d} FSM + {d} steering scenarios passed\n", .{ checks.len, sm_checks.len, steer_checks.len });
    } else {
        std.debug.print("\nall {d} checks + {d} FSM scenarios passed (steering off)\n", .{ checks.len, sm_checks.len });
    }
}
