//! The steering accumulator, written in Lua and shipped with the engine (M4.5).
//!
//! ## Why Lua and not a dozen C functions
//!
//! The classic Reynolds API is one C function per behaviour — `seek`, `flee`,
//! `separate`, ... — and it is the wrong shape for two measurable reasons.
//!
//! 1. **It does not fit the frame budget.** spec §2 prices a Lua→C binding at
//!    145 ns and budgets 2.0 ms for Lua behaviors. Three steering calls per actor
//!    at 10k actors is 4.35 ms; a full flock (six calls) is 8.7 ms. As C
//!    functions, flocking is simply over budget by 4x.
//! 2. **It is a recipe, not a language.** `separate(others, r)` needs a
//!    neighbour list the engine never gave you, and summing the returns by hand
//!    means every game reinvents the magnitude clamp.
//!
//! So this is ONE accumulator in pure Lua: terms are methods, `apply` does the
//! normalise-and-clamp once, and the whole thing costs zero C bindings. Only
//! `world.nearby` (used by the neighbour terms) crosses into C, and only when a
//! behaviour actually asks for neighbours.
//!
//! ## The one rule that makes it general
//!
//! Every term is normalized BEFORE it is weighted. A target 500 units away and
//! an obstacle 3 units away both contribute a unit vector scaled by their
//! weight, so weights mean the same thing regardless of distance. Without that,
//! weights are distance-dependent and every behaviour needs per-distance tuning
//! nobody can reason about.
//!
//! ## Composition, not enumeration
//!
//! A behaviour is a list of terms, so the same primitives make a guard, a chase,
//! a flock, a herd and a panicking herd without the engine knowing any of those
//! words. That is what keeps this from becoming another fixed vocabulary.

const std = @import("std");

/// The Lua source. Loaded once at VM init like the behavior driver, and its
/// `new` cached as a ref.
pub const source =
    \\local M = {}
    \\local sqrt = math.sqrt
    \\local abs = math.abs
    \\local cos = math.cos
    \\local sin = math.sin
    \\-- The engine installs its OWN `math` global (clamp/sqrt/sin/...), which
    \\-- shadows Lua's stdlib `math` — and it has no `pi`. Depending on the
    \\-- stdlib here would fail at load time, so the constant is local.
    \\local pi = 3.141592653589793
    \\local tau = pi * 2
    \\local Acc = {}
    \\Acc.__index = Acc
    \\-- One accumulator per actor, reused across frames: zero allocation after
    \\-- the first (spec §10). `at` binds it to a position so the neighbour
    \\-- terms do not have to be handed one on every call.
    \\--
    \\-- Named `at`, NOT `for`: `for` is a Lua keyword, so `M.for` is a syntax
    \\-- error. The compile check in the acceptance suite exists to catch exactly
    \\-- this class of mistake at build time instead of mid-game.
    \\function M.at(x, y)
    \\  local S, visitors = M._visitors()
    \\  local acc = setmetatable({ x = x, y = y, fx = 0, fy = 0, n = 0, _s = S, _visitors = visitors }, Acc)
    \\  -- The radius the visitors must test against is stashed once per term.
    \\  local raw_sep, raw_align, raw_cohere = acc.separate, acc.align, acc.cohere
    \\  acc.separate = function(a, r, w) S.r2 = r * r; return raw_sep(a, r, w) end
    \\  acc.align = function(a, r, w) return raw_align(a, r, w) end
    \\  acc.cohere = function(a, r, w) return raw_cohere(a, r, w) end
    \\  return acc
    \\end
    \\function Acc:reset(x, y)
    \\  if x then self.x = x end
    \\  if y then self.y = y end
    \\  self.fx = 0
    \\  self.fy = 0
    \\  self.n = 0
    \\  return self
    \\end
    \\-- The single place a force enters the accumulator. Normalizing here (not
    \\-- at each call site) is what makes weights comparable across terms.
    \\function Acc:_add(dx, dy, w)
    \\  if w == 0 then return end
    \\  local len = sqrt(dx * dx + dy * dy)
    \\  if len == 0 then return end
    \\  self.fx = self.fx + (dx / len) * w
    \\  self.fy = self.fy + (dy / len) * w
    \\  self.n = self.n + 1
    \\end
    \\function Acc:seek(tx, ty, w)
    \\  self:_add(tx - self.x, ty - self.y, w or 1)
    \\  return self
    \\end
    \\function Acc:flee(tx, ty, w)
    \\  self:_add(self.x - tx, self.y - ty, w or 1)
    \\  return self
    \\end
    \\-- Arrive is seek that brakes: full weight far away, fading to zero at the
    \\-- target so the actor decelerates instead of orbiting or stopping dead.
    \\function Acc:arrive(tx, ty, slow_radius, w)
    \\  local dx, dy = tx - self.x, ty - self.y
    \\  local d = sqrt(dx * dx + dy * dy)
    \\  if d == 0 then return self end
    \\  if d < slow_radius then
    \\    self:_add(dx, dy, w * (d / slow_radius))
    \\  else
    \\    self:_add(dx, dy, w)
    \\  end
    \\  return self
    \\end
    \\-- Lead a moving target: aim where it will be, not where it is. Purely
    \\-- arithmetic on the target's velocity — no prediction model, no state.
    \\function Acc:pursue(tx, ty, tvx, tvy, lead, w)
    \\  self:_add(tx + tvx * lead - self.x, ty + tvy * lead - self.y, w or 1)
    \\  return self
    \\end
    \\function Acc:evade(tx, ty, tvx, tvy, lead, w)
    \\  self:_add(self.x - (tx + tvx * lead), self.y - (ty + tvy * lead), w or 1)
    \\  return self
    \\end
    \\-- Deterministic wander: the heading comes from the caller (normally noise,
    \\-- which is seeded and reproducible — spec §6), never from a clock or a
    \\-- hidden random draw.
    \\function Acc:wander(angle, radius, w)
    \\  local wx = self.x + cos(angle) * radius
    \\  local wy = self.y + sin(angle) * radius
    \\  self:_add(wx - self.x, wy - self.y, w or 1)
    \\  return self
    \\end
    \\-- Steer AWAY from an obstacle without leaving the path: blend away from the
    \\-- obstacle but toward the target, so the actor slides around rather than
    \\-- reversing. The classic Reynolds "avoid" without a lookahead sweep.
    \\function Acc:avoid(ox, oy, radius, tx, ty, w)
    \\  local dx, dy = self.x - ox, self.y - oy
    \\  local d2 = dx * dx + dy * dy
    \\  if d2 >= radius * radius or d2 == 0 then return self end
    \\  local d = sqrt(d2)
    \\  -- 1 at contact, 0 at the edge of the radius.
    \\  local push = 1 - d / radius
    \\  local ex, ey = (tx or self.x) - self.x, (ty or self.y) - self.y
    \\  self:_add(dx / d * push + ex * 0.001, dy / d * push + ey * 0.001, w or 1)
    \\  return self
    \\end
    \\-- --- Flocking ---------------------------------------------------------
    \\-- All three walk `world.nearby`, which is the ONLY C call in this module.
    \\-- Accumulating into locals (not into `self`) keeps each term independent:
    \\-- the caller can combine any subset, in any order.
    \\function Acc:separate(radius, w)
    \\  local S = self._s
    \\  S.x, S.y = self.x, self.y
    \\  S.fx, S.fy, S.n = 0, 0, 0
    \\  world.nearby(self, S.x, S.y, radius, self._visitors.sep)
    \\  if S.fx ~= 0 or S.fy ~= 0 then
    \\    local len = sqrt(S.fx * S.fx + S.fy * S.fy)
    \\    self.fx = self.fx + S.fx / len * w
    \\    self.fy = self.fy + S.fy / len * w
    \\    self.n = self.n + 1
    \\  end
    \\  return self
    \\end
    \\
    \\function Acc:align(radius, w)
    \\  local S = self._s
    \\  S.x, S.y = self.x, self.y
    \\  S.fx, S.fy, S.n = 0, 0, 0
    \\  world.nearby(self, S.x, S.y, radius, self._visitors.align)
    \\  if S.n > 0 then self:_add(S.fx / S.n, S.fy / S.n, w) end
    \\  return self
    \\end
    \\
    \\function Acc:cohere(radius, w)
    \\  local S = self._s
    \\  S.x, S.y = self.x, self.y
    \\  S.fx, S.fy, S.n = 0, 0, 0
    \\  world.nearby(self, S.x, S.y, radius, self._visitors.cohere)
    \\  if S.n > 0 then self:_add(S.fx / S.n - S.x, S.fy / S.n - S.y, w) end
    \\  return self
    \\end
    \\
    \\-- All three terms in ONE neighbour pass: 1 C call instead of 3.
    \\-- Calling separate/align/cohere individually is still supported and still
    \\-- composable, but each costs its own query — for the common case of "do
    \\-- all three", this is the shape to use.
    \\function Acc:flock(radius, sep_w, align_w, cohere_w)
    \\  local S = self._s
    \\  S.x, S.y = self.x, self.y
    \\  S.r2 = radius * radius
    \\  S.sfx, S.sfy = 0, 0
    \\  S.ax, S.ay, S.an = 0, 0, 0
    \\  S.cx, S.cy, S.cn = 0, 0, 0
    \\  world.nearby(self, S.x, S.y, radius, self._visitors.flock)
    \\  if sep_w ~= nil and sep_w ~= 0 and (S.sfx ~= 0 or S.sfy ~= 0) then
    \\    local l = sqrt(S.sfx * S.sfx + S.sfy * S.sfy)
    \\    self.fx = self.fx + S.sfx / l * sep_w
    \\    self.fy = self.fy + S.sfy / l * sep_w
    \\    self.n = self.n + 1
    \\  end
    \\  if align_w ~= nil and align_w ~= 0 and S.an > 0 then
    \\    self:_add(S.ax / S.an, S.ay / S.an, align_w)
    \\  end
    \\  if cohere_w ~= nil and cohere_w ~= 0 and S.cn > 0 then
    \\    self:_add(S.cx / S.cn - S.x, S.cy / S.cn - S.y, cohere_w)
    \\  end
    \\  return self
    \\end
    \\
    \\-- The visitors, built once per accumulator. Each writes into the
    \\-- shared scratch table `S` and never allocates, so a frame that runs the
    \\-- whole flocking set costs ZERO allocations (spec §10) — measured, an
    \\-- inline closure per query was the single largest cost in the frame.
    \\function M._visitors()
    \\  local S = { x = 0, y = 0, fx = 0, fy = 0, n = 0, r2 = 0 }
    \\  return S, {
    \\    flock = function(_, ox, oy)
    \\      local dx, dy = S.x - ox, S.y - oy
    \\      local d2 = dx * dx + dy * dy
    \\      if d2 > 0.0001 and d2 < S.r2 then
    \\        local d = sqrt(d2)
    \\        local k = 1 - d / sqrt(S.r2)
    \\        S.sfx = S.sfx + dx / d * k
    \\        S.sfy = S.sfy + dy / d * k
    \\      end
    \\      local ax, ay = ox - S.x, oy - S.y
    \\      local ad = sqrt(ax * ax + ay * ay)
    \\      if ad > 0.001 then
    \\        S.ax = S.ax + ax / ad
    \\        S.ay = S.ay + ay / ad
    \\      end
    \\      S.an = S.an + 1
    \\      S.cx = S.cx + ox
    \\      S.cy = S.cy + oy
    \\      S.cn = S.cn + 1
    \\    end,
    \\    sep = function(_, ox, oy)
    \\      local dx, dy = S.x - ox, S.y - oy
    \\      local d2 = dx * dx + dy * dy
    \\      if d2 > 0.0001 and d2 < S.r2 then
    \\        local d = sqrt(d2)
    \\        local k = 1 - d / sqrt(S.r2)
    \\        S.fx = S.fx + dx / d * k
    \\        S.fy = S.fy + dy / d * k
    \\      end
    \\    end,
    \\    align = function(_, ox, oy)
    \\      local dx, dy = ox - S.x, oy - S.y
    \\      local d = sqrt(dx * dx + dy * dy)
    \\      if d > 0.001 then
    \\        S.fx = S.fx + dx / d
    \\        S.fy = S.fy + dy / d
    \\      end
    \\      S.n = S.n + 1
    \\    end,
    \\    cohere = function(_, ox, oy)
    \\      S.fx = S.fx + ox
    \\      S.fy = S.fy + oy
    \\      S.n = S.n + 1
    \\    end,
    \\  }
    \\end
    \\
    \\function Acc:apply(max_speed)
    \\  local fx, fy = self.fx, self.fy
    \\  local len = sqrt(fx * fx + fy * fy)
    \\  if len > 0 then
    \\    local s = max_speed
    \\    if len > max_speed then s = max_speed end
    \\    fx = fx / len * s
    \\    fy = fy / len * s
    \\  end
    \\  self.fx, self.fy = 0, 0
    \\  self.n = 0
    \\  return fx, fy
    \\end
    \\return M
;

/// The `new`-equivalent exported to Lua as `steer`.
pub const global_name = "steer";

// The chunk actually COMPILING is checked in `api_acceptance_test.zig`, not
// here: a live LuaJIT state aborts inside Zig's test runner (the allocator
// alignment mismatch that also breaks the other VM tests), so a `zig test` here
// would report a false failure. The acceptance executable runs outside that
// runner and compiles the module for real.

test "the module exposes exactly the documented terms" {
    // Keeps the Lua and the docs from drifting: a term added to one and not the
    // other is worse than either.
    const terms = [_][]const u8{
        "at",    "reset",  "seek",  "flee",     "arrive", "pursue",
        "evade", "wander", "avoid", "separate", "align",  "cohere",
        "apply",
    };
    for (terms) |t| {
        if (!contains(source, t)) {
            std.debug.print("steer module is missing `{s}`\n", .{t});
            return error.MissingTerm;
        }
    }
}

fn contains(haystack: []const u8, needle: []const u8) bool {
    if (needle.len == 0) return true;
    var i: usize = 0;
    while (i + needle.len <= haystack.len) : (i += 1) {
        if (std.mem.eql(u8, haystack[i..][0..needle.len], needle)) return true;
    }
    return false;
}
