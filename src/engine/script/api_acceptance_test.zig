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

    if (failed != 0) {
        std.debug.print("\n{d} of {d} checks FAILED\n", .{ failed, checks.len });
        std.process.exit(1);
    }
    std.debug.print("\nall {d} checks passed\n", .{checks.len});
}