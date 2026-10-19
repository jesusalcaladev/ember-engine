//! The tween system: a value that MOVES to another value over time, without
//! a frame counter and without a state machine.
//!
//! ## What it is for
//!
//! Three things a game asks for constantly: "slide the panel in", "fade the
//! sprite out", "punch the player back 20 pixels". The naive answer is a
//! frame counter in a script:
//!
//! ```lua
//! self.t = 0
//! function M:update(dt)
//!   self.t = self.t + dt
//!   if self.t < 0.3 then
//!     actor.set_position(self, 100 * (self.t / 0.3), 0)
//!   else
//!     actor.set_position(self, 100, 0)
//!   end
//! end
//! ```
//!
//! That code is four bugs waiting to happen: it runs forever (the `else` is
//! not an exit), it fights any other system that moves the same actor, it
//! cannot be cancelled, and it cannot be eased. A tween is that code with the
//! four answers built in.
//!
//! ## Why a manager and not a component
//!
//! A tween is TRANSIENT: it runs, it ends, it is gone. A component is the
//! opposite — it is the document, it is serialized, it survives a save. A
//! tween in a `.zson` file would be a tween that has already finished.
//!
//! So the tween lives here, in a fixed-capacity pool owned by the `Behaviors`
//! system (the same owner as the state-machine registry), and a script
//! addresses it by a `u32` handle. Exactly the arrangement `StateMachine` uses
//! for the same reason.
//!
//! ## What a tween drives
//!
//! An ENTITY and a PROPERTY: `"position"`, `"position.x"`, `"tint.a"`,
//! `"energy"`. The property is resolved against the ECS, so a tween moves the
//! real `Transform` and the renderer draws it — it is not a number in a Lua
//! table that happens to look like a position.
//!
//! ## The order of a frame
//!
//! The tweens tick BEFORE the behaviors (see `Behaviors.tickTweens`), so a
//! script reads the tweened value in the same tick it was written, and a
//! script that writes the property itself WINS — the tween's next tick
//! overwrites it, but the script's write was the last word in this one.

const std = @import("std");
const ecs = @import("ecs");
const lua = @import("luajit.zig");
const vm_mod = @import("vm.zig");
const core_math = @import("core").math;

const components = ecs.components;
const Vec2 = core_math.Vec2;
const Easing = core_math.Easing;

/// Ref value meaning "no callback" (mirrors `behavior.zig`'s `no_ref`).
pub const no_ref: i32 = -1;

/// How many tweens can be alive at once. The pool is fixed so the tick never
/// allocates (spec §3.1) and so a runaway script reports a limit instead of
/// eating the heap.
pub const max_tweens = 256;

    /// How many tweens can be chained behind one. A sequence of ten steps is
    /// already unusual; a sequence of a hundred is a state machine wearing a
    /// disguise.
pub const max_chain = 8;

/// How many chained tweens can be released in one tick. A tick that ends a
/// hundred tweens at once is a script that is about to have a bad time, and
/// the cap turns that into a reported limit instead of a dropped release.
pub const max_pending = 64;

/// The value a tween drives. Which shape it has is decided by the property:
/// a scalar, a vector, or a colour.
pub const Value = union(enum) {
    scalar: f32,
    vec2: Vec2,
    color: [4]f32,

    /// The component of the value the tween drives: `x` for a vector, `r` for
    /// a colour, or the whole thing.
    pub fn part(self: Value, p: Part) f32 {
        return switch (p) {
            .whole => switch (self) {
                .scalar => |s| s,
                .vec2 => |v| v.x,
                .color => |c| c[0],
            },
            .x => switch (self) {
                .scalar => |s| s,
                .vec2 => |v| v.x,
                .color => |c| c[0],
            },
            .y => switch (self) {
                .scalar => |s| s,
                .vec2 => |v| v.y,
                .color => |c| c[1],
            },
            .r => switch (self) {
                .scalar => |s| s,
                .vec2 => |v| v.x,
                .color => |c| c[0],
            },
            .g => switch (self) {
                .scalar => |s| s,
                .vec2 => |v| v.y,
                .color => |c| c[1],
            },
            .b => switch (self) {
                .scalar => |s| s,
                .vec2 => |v| v.x,
                .color => |c| c[2],
            },
            .a => switch (self) {
                .scalar => |s| s,
                .vec2 => |v| v.y,
                .color => |c| c[3],
            },
        };
    }

    /// The same value with one component replaced. The base is the FROM value:
    /// a tween of `"tint.a"` must not disturb the colour's RGB.
    pub fn withPart(self: Value, p: Part, v: f32) Value {
        var out = self;
        switch (p) {
            .whole => switch (out) {
                .scalar => |*s| s.* = v,
                .vec2 => |*x| x.* = .{ .x = v, .y = v },
                .color => |*c| c.* = .{ v, v, v, v },
            },
            .x, .r => switch (out) {
                .scalar => |*s| s.* = v,
                .vec2 => |*x| x.x = v,
                .color => |*c| c[0] = v,
            },
            .y, .g => switch (out) {
                .scalar => |*s| s.* = v,
                .vec2 => |*x| x.y = v,
                .color => |*c| c[1] = v,
            },
            .b => switch (out) {
                .scalar => |*s| s.* = v,
                .vec2 => |*x| x.x = v,
                .color => |*c| c[2] = v,
            },
            .a => switch (out) {
                .scalar => |*s| s.* = v,
                .vec2 => |*x| x.y = v,
                .color => |*c| c[3] = v,
            },
        }
        return out;
    }

    /// The two values blended by `t`. A vector or a colour blends component
    /// by component; a scalar blends to itself.
    pub fn lerp(a: Value, b: Value, t: f32) Value {
        return switch (a) {
            .scalar => |x| .{ .scalar = x + (b.part(.x) - x) * t },
            .vec2 => |x| .{ .vec2 = .{
                .x = x.x + (b.part(.x) - x.x) * t,
                .y = x.y + (b.part(.y) - x.y) * t,
            } },
            .color => |x| .{ .color = .{
                x[0] + (b.part(.r) - x[0]) * t,
                x[1] + (b.part(.g) - x[1]) * t,
                x[2] + (b.part(.b) - x[2]) * t,
                x[3] + (b.part(.a) - x[3]) * t,
            } },
        };
    }
};

/// Which part of a value a tween drives.
pub const Part = enum(u8) {
    whole = 0,
    x = 1,
    y = 2,
    r = 3,
    g = 4,
    b = 5,
    a = 6,

    /// Resolves the sub-field of a property name: `"position.x"` drives the
    /// `x` of a vector, `"tint.a"` the alpha of a colour.
    pub fn fromName(name: []const u8) Part {
        if (std.mem.eql(u8, name, "x")) return .x;
        if (std.mem.eql(u8, name, "y")) return .y;
        if (std.mem.eql(u8, name, "r")) return .r;
        if (std.mem.eql(u8, name, "g")) return .g;
        if (std.mem.eql(u8, name, "b")) return .b;
        if (std.mem.eql(u8, name, "a")) return .a;
        return .whole;
    }
};

/// The properties a tween can drive.
///
/// Each one names a field of a COMPONENT, because that is what a tween
/// actually writes: the renderer draws `Transform`, the light pass reads
/// `energy`, the UI draws `color`.
pub const Field = enum(u8) {
    /// `Transform.position` — where the actor is.
    position = 0,
    /// `Transform.rotation` — which way it faces, in radians.
    rotation = 1,
    /// `Transform.scale` — how big it is.
    scale = 2,
    /// `Sprite.tint` — the sprite's colour; `tint.a` is the opacity.
    tint = 3,
    /// The UI colour: `Label.color` or `UiPanel.color`.
    color = 4,
    /// A light's brightness: `LightBase.energy`.
    energy = 5,
    /// A light's reach: the point and spot lights' `radius`.
    radius = 6,
    /// `UiProgressBar.value` — the 0..1 fill.
    value = 7,
    /// `Timer.duration` — the length of a cycle.
    duration = 8,

    /// Resolves a property name, with or without a sub-field.
    ///
    /// Null for an unknown name: a typo is a REPORTED failure, not a tween
    /// that quietly does nothing (which looks exactly like a tween whose
    /// duration never ends).
    pub fn fromName(name: []const u8) ?Field {
        if (std.mem.eql(u8, name, "position")) return .position;
        if (std.mem.eql(u8, name, "rotation")) return .rotation;
        if (std.mem.eql(u8, name, "scale")) return .scale;
        if (std.mem.eql(u8, name, "tint")) return .tint;
        if (std.mem.eql(u8, name, "color")) return .color;
        if (std.mem.eql(u8, name, "energy")) return .energy;
        if (std.mem.eql(u8, name, "radius")) return .radius;
        if (std.mem.eql(u8, name, "value")) return .value;
        if (std.mem.eql(u8, name, "duration")) return .duration;
        return null;
    }
};

/// How a tween was asked for. The `Behaviors` layer fills this from the Lua
/// options table.
pub const Options = struct {
    easing: Easing = .linear,
    /// Seconds to wait before the tween starts moving anything.
    delay: f32 = 0,
    /// Extra cycles: 0 runs once, 2 runs three times, -1 runs forever.
    repeat: i32 = 0,
    /// Each cycle runs backwards: out and back, out and back.
    yoyo: bool = false,
    /// The tween is created PARKED: it starts when it is released or when the
    /// tween it is chained to finishes. This is what makes a sequence
    /// possible.
    hold: bool = false,
    /// The start value. Null = read it from the entity when the tween starts.
    from: ?Value = null,
    /// A Lua callback run when the tween finishes.
    on_complete: i32 = no_ref,
    /// The `self` table the callback is called with.
    self_ref: i32 = no_ref,
};

/// One live tween.
pub const Tween = struct {
    /// The entity the tween drives. `Entity.invalid` = a tween with no target
    /// (which is legal: it still runs, it just writes nothing).
    entity: ecs.Entity = ecs.Entity.invalid,
    field: Field = .position,
    part: Part = .whole,
    from: Value = .{ .scalar = 0 },
    to: Value = .{ .scalar = 0 },
    duration: f32 = 0,
    elapsed: f32 = 0,
    delay: f32 = 0,
    easing: Easing = .linear,
    repeat: i32 = 0,
    yoyo: bool = false,
    /// The cycle counter: 0 is the first run.
    cycle: i32 = 0,
    /// The current cycle runs backwards (the yoyo).
    reversed: bool = false,
    /// The tweens that start when this one finishes.
    chain: [max_chain]u32 = undefined,
    chain_len: u8 = 0,
    on_complete: i32 = no_ref,
    self_ref: i32 = no_ref,
    /// Parked: waiting for `release` or for a chain parent.
    held: bool = false,
    /// The slot is in use.
    alive: bool = false,
    /// The tween already ran and is being torn down.
    finished: bool = false,
};

pub const Error = error{
    OutOfMemory,
    /// The pool is full: a script asked for more tweens than the engine
    /// allows. Reported, never silently dropped.
    TweenLimitReached,
    NoSuchTween,
    NoSuchProperty,
    /// The entity does not carry the component the property lives in.
    NoSuchComponent,
    /// The chain list is full.
    ChainLimitReached,
};

/// The tween pool. Fixed capacity, no allocation after `init`.
pub const Manager = struct {
    allocator: std.mem.Allocator,
    /// The VM, for the completion callback. Null in a harness without one: the
    /// tweens still run, they just cannot call back.
    vm: ?*vm_mod.Vm,
    /// The world the tweens write to. Null means the manager is inert.
    world: ?*ecs.World,

    tweens: [max_tweens]Tween = undefined,
    /// The slots that are free, as a stack. A handle is a SLOT INDEX, and a
    /// slot's index never changes — so a handle stays valid for the whole life
    /// of its tween, which a swap-remove pool could not promise.
    free: [max_tweens]u32 = undefined,
    free_len: u16 = 0,
    live: u16 = 0,

    /// The global tween speed. 0 freezes every tween, 0.5 halves them, 2
    /// doubles them. Separate from the engine's own time scale: this one
    /// moves the ANIMATIONS, not the world.
    time_scale: f32 = 1,
    /// How many tweens have finished, ever. A diagnostic, not a gameplay
    /// number.
    finished_total: u32 = 0,
    /// The tweens a finished tween released, waiting for the end of the tick
    /// to start. A child released DURING the tick would get a whole frame of
    /// travel before the player ever saw the parent arrive.
    pending: [max_pending]u32 = undefined,
    pending_len: u16 = 0,

    pub fn init(allocator: std.mem.Allocator, vm: ?*vm_mod.Vm) Manager {
        var m = Manager{
            .allocator = allocator,
            .vm = vm,
            .world = null,
        };
        // Every slot starts EMPTY, and `alive = false` is what says so. The
        // tick walks ALL the slots, and a slot that was never written holds
        // garbage — a garbage `alive` is a garbage tween, and a garbage tween
        // is a crash in the middle of a frame.
        var i: usize = 0;
        while (i < max_tweens) : (i += 1) {
            m.tweens[i] = .{};
        }
        // The free stack is filled so that popping takes the LOWEST slot
        // first: the pool is dense for the slots in use, which keeps the tick's
        // memory pattern tight.
        var j: u16 = 0;
        while (j < max_tweens) : (j += 1) {
            m.free[j] = max_tweens - 1 - j;
        }
        m.free_len = max_tweens;
        return m;
    }

    pub fn deinit(self: *Manager) void {
        // The Lua refs live in the VM, which owns the ref table; the manager
        // only holds indices into it. Unreffing here would need the VM, and
        // the VM is torn down after this — the state machine's registry has
        // the same shape and the same answer.
        self.* = undefined;
    }

    /// Points the manager at the world it writes to. The `Behaviors` system
    /// owns the world, so it sets this once at init.
    pub fn setWorld(self: *Manager, world: *ecs.World) void {
        self.world = world;
    }

    /// Creates a tween and returns its handle (0 = none).
    ///
    /// The handle is stable for the life of the tween. The `from` value is
    /// read from the entity NOW unless the options give one, so a tween that
    /// starts later still begins where the property was when it was asked for.
    pub fn create(
        self: *Manager,
        entity: ecs.Entity,
        field: Field,
        part: Part,
        to: Value,
        duration: f32,
        opts: Options,
    ) Error!u32 {
        if (self.free_len == 0) return error.TweenLimitReached;
        const slot = self.free[self.free_len - 1];
        self.free_len -= 1;
        // A slot that is not a slot is a pool that was corrupted by something
        // else. Refusing is better than writing past the end of the array, and
        // the guard is what turns a wild write into a reported error.
        if (slot >= max_tweens) return error.TweenLimitReached;

        var t = Tween{
            .entity = entity,
            .field = field,
            .part = part,
            .to = to,
            .duration = @max(duration, 0),
            .delay = @max(opts.delay, 0),
            .easing = opts.easing,
            .repeat = opts.repeat,
            .yoyo = opts.yoyo,
            .on_complete = opts.on_complete,
            .self_ref = opts.self_ref,
            .held = opts.hold,
            .alive = true,
        };
        t.chain_len = 0;

        // The start value: the one the options gave, or the one the entity
        // carries right now.
        if (opts.from) |f| {
            t.from = f;
        } else if (self.world) |w| {
            t.from = readValue(w, entity, field) orelse Value{ .scalar = 0 };
        } else {
            t.from = Value{ .scalar = 0 };
        }

        self.tweens[slot] = t;
        self.live += 1;
        return slot + 1;
    }

    /// True when the handle names a live tween.
    pub fn isAlive(self: *const Manager, handle: u32) bool {
        if (handle == 0 or handle > max_tweens) return false;
        const t = &self.tweens[handle - 1];
        return t.alive and !t.finished;
    }

    /// Releases a parked tween: it starts now.
    pub fn release(self: *Manager, handle: u32) bool {
        if (handle == 0 or handle > max_tweens) return false;
        const t = &self.tweens[handle - 1];
        if (!t.alive or t.finished) return false;
        t.held = false;
        return true;
    }

    /// Parks the child tween and starts it when the parent finishes.
    ///
    /// The child is RESET: it goes back to its start value and waits. A child
    /// that was already running therefore jumps back to where it began — chain
    /// a tween before it runs (or create it with `hold`) to avoid the jump.
    pub fn chain(self: *Manager, parent: u32, child: u32) Error!bool {
        if (parent == 0 or parent > max_tweens) return error.NoSuchTween;
        if (child == 0 or child > max_tweens) return error.NoSuchTween;
        const p = &self.tweens[parent - 1];
        const c = &self.tweens[child - 1];
        if (!p.alive or p.finished) return error.NoSuchTween;
        if (!c.alive or c.finished) return error.NoSuchTween;
        if (p.chain_len >= max_chain) return error.ChainLimitReached;
        p.chain[p.chain_len] = child;
        p.chain_len += 1;
        // The child waits, and it waits from the beginning.
        c.held = true;
        c.elapsed = 0;
        c.delay = 0;
        c.cycle = 0;
        c.reversed = false;
        return true;
    }

    /// Stops a tween. The completion callback does NOT run: a killed tween was
    /// cancelled, and a cancelled thing has not finished.
    pub fn kill(self: *Manager, handle: u32) bool {
        if (handle == 0 or handle > max_tweens) return false;
        const slot: u16 = @intCast(handle - 1);
        const t = &self.tweens[slot];
        if (!t.alive) return false;
        self.retire(slot);
        return true;
    }

    /// Stops every tween driving `entity`. The count of stopped tweens comes
    /// back so a script can tell "nothing was running" from "it stopped five".
    pub fn killEntity(self: *Manager, entity: ecs.Entity) u32 {
        var n: u32 = 0;
        for (&self.tweens, 0..) |*t, i| {
            if (!t.alive or t.finished) continue;
            if (t.entity.index != entity.index or t.entity.generation != entity.generation) continue;
            self.retire(@intCast(i));
            n += 1;
        }
        return n;
    }

    /// Stops every tween.
    pub fn killAll(self: *Manager) void {
        for (&self.tweens, 0..) |*t, i| {
            if (!t.alive or t.finished) continue;
            self.retire(@intCast(i));
        }
    }

    /// The number of live tweens.
    pub fn liveCount(self: *const Manager) u32 {
        return self.live;
    }

    /// The global tween speed. Clamped to `[0, 100]`.
    pub fn setTimeScale(self: *Manager, s: f32) void {
        if (std.math.isNan(s)) return;
        self.time_scale = std.math.clamp(s, 0.0, 100.0);
    }

    /// Advances every tween by `dt` seconds.
    pub fn tick(self: *Manager, dt: f32) void {
        const scaled = dt * self.time_scale;
        // A frozen manager (scale 0) does not advance anything, and a
        // negative dt would run the tweens backwards.
        if (scaled <= 0) return;
        const world = self.world orelse return;

        var i: usize = 0;
        while (i < max_tweens) : (i += 1) {
            const t = &self.tweens[i];
            if (!t.alive or t.finished or t.held) continue;

            if (t.delay > 0) {
                t.delay -= scaled;
                if (t.delay > 0) continue; // still waiting
                // The delay ran out inside this frame. The tween starts on the
                // NEXT one, from zero: the rest of this frame is not spent on
                // it, because a tween that started late must not get a head
                // start over one that did not.
                t.delay = 0;
                continue;
            }

            t.elapsed += scaled;
            const t01 = if (t.duration <= 0) 1.0 else @min(t.elapsed / t.duration, 1.0);
            const e = core_math.ease(t.easing, t01);

            // The value. A whole-value tween blends the two values; a tween of
            // ONE part blends that part and leaves the rest of the value
            // alone (a tween of "tint.a" must not disturb the colour).
            //
            // The BASE for the untouched parts is the component's CURRENT
            // value, not the value the tween started from: two tweens on the
            // same actor (one on x, one on y) must not fight, and a base
            // captured at creation would restore whatever the other tween had
            // already moved.
            //
            // A yoyo runs BACKWARDS: it goes from the target back to the
            // start, which is why the endpoints swap.
            const start = t.from.part(t.part);
            const end = t.to.part(t.part);
            const driven = if (t.reversed)
                end + (start - end) * e
            else
                start + (end - start) * e;
            const blended = if (t.part == .whole)
                Value.lerp(if (t.reversed) t.to else t.from, if (t.reversed) t.from else t.to, e)
            else
                (readValue(world, t.entity, t.field) orelse t.from).withPart(t.part, driven);
            _ = writeValue(world, t.entity, t.field, blended);

            if (t01 < 1.0) continue;

            // The half is over.
            if (t.yoyo and !t.reversed) {
                // The way back. The run is not over yet: a yoyo is ONE run
                // that goes out and comes back, not two runs.
                t.reversed = true;
                t.elapsed = 0;
                continue;
            }
            if (t.yoyo) {
                // The way back is over: the run is complete.
                t.reversed = false;
                t.elapsed = 0;
                t.cycle += 1;
                if (t.repeat < 0 or t.cycle <= t.repeat) {
                    _ = writeValue(world, t.entity, t.field, t.from);
                    continue;
                }
                self.finish(@intCast(i));
                continue;
            }

            t.elapsed = 0;
            t.cycle += 1;
            if (t.repeat < 0 or t.cycle <= t.repeat) {
                // Another cycle: the value goes back to the start, which is
                // what "repeat" means (a pulse, not a ping-pong).
                _ = writeValue(world, t.entity, t.field, t.from);
                continue;
            }
            self.finish(@intCast(i));
        }

        // The tweens a finished tween released start NOW, at the end of the
        // tick: the child begins from zero and its first frame of travel is
        // the NEXT frame, not the tail of the one the parent finished in.
        var p: u16 = 0;
        while (p < self.pending_len) : (p += 1) {
            const handle = self.pending[p];
            if (handle == 0 or handle > max_tweens) continue;
            const c = &self.tweens[handle - 1];
            if (!c.alive or c.finished) continue;
            c.held = false;
        }
        self.pending_len = 0;
    }

    /// The tween reached its end: the callback runs, the chain starts, the
    /// slot is freed.
    ///
    /// The SLOT INDEX, not a pointer to the tween. A pointer into the pool is
    /// only valid while the pool stays where it is, and the slot is what the
    /// pool's free list actually wants — deriving it from a pointer is how a
    /// free list ends up holding an index that was never a slot index, and the
    /// next allocation then writes past the end of the pool.
    fn finish(self: *Manager, slot: u16) void {
        const t = &self.tweens[slot];
        t.finished = true;
        self.finished_total += 1;

        // The callback, before the chain: a script that starts something in
        // its callback should not find the chain already running.
        if (t.on_complete != no_ref) {
            if (self.vm) |vm| {
                if (vm.state()) |L| {
                    vm.pushRef(t.on_complete);
                    if (t.self_ref != no_ref) {
                        vm.pushRef(t.self_ref);
                        _ = lua.lua_pcall(L, 1, 0, 0);
                    } else {
                        _ = lua.lua_pcall(L, 0, 0, 0);
                    }
                }
            }
        }

        // The chain: the child tweens start at the END of this tick, not in
        // the middle of it.
        var i: u8 = 0;
        while (i < t.chain_len) : (i += 1) {
            const child = t.chain[i];
            if (child == 0 or child > max_tweens) continue;
            if (self.pending_len >= max_pending) continue; // the cap, not a crash
            self.pending[self.pending_len] = child;
            self.pending_len += 1;
        }

        self.retire(slot);
    }

    /// Frees a slot. The Lua ref is released: a tween that is gone must not
    /// keep a closure alive.
    ///
    /// The SLOT INDEX comes in as an argument, for the reason `finish` says:
    /// the free list wants an index, and an index derived from a pointer is
    /// only right while the pointer is right.
    fn retire(self: *Manager, slot: u16) void {
        if (slot >= max_tweens) return;
        const t = &self.tweens[slot];
        if (!t.alive) return;
        if (t.on_complete != no_ref) {
            if (self.vm) |vm| {
                if (vm.state()) |L| {
                    _ = lua.luaL_unref(L, lua.REGISTRYINDEX, t.on_complete);
                }
            }
        }
        t.alive = false;
        t.finished = true;
        t.chain_len = 0;
        t.on_complete = no_ref;
        self.live -= 1;
        // The free list has a cap, and the cap is a GUARD: a push past the end
        // would write into the fields that follow the array, and the pool would
        // hand out a slot that was never a slot.
        if (self.free_len >= max_tweens) return;
        self.free[self.free_len] = slot;
        self.free_len += 1;
    }
};

// ── Property resolution ──────────────────────────────────────────────────────
//
// The two functions that know what a property NAME means. Everything else in
// the system works with `Field` and `Part` and never looks at a string.

/// Reads the current value of a property from an entity.
pub fn readValue(world: *ecs.World, entity: ecs.Entity, field: Field) ?Value {
    return switch (field) {
        .position => if (world.get(entity, components.Transform)) |t| Value{ .vec2 = t.position } else null,
        .rotation => if (world.get(entity, components.Transform)) |t| Value{ .scalar = t.rotation } else null,
        .scale => if (world.get(entity, components.Transform)) |t| Value{ .vec2 = t.scale } else null,
        .tint => if (world.get(entity, components.Sprite)) |s| Value{ .color = s.tint } else null,
        .color => blk: {
            if (world.get(entity, components.Label)) |l| break :blk Value{ .color = l.color };
            if (world.get(entity, components.UiPanel)) |p| break :blk Value{ .color = p.color };
            break :blk null;
        },
        .energy => blk: {
            if (world.get(entity, components.PointLight2D)) |l| break :blk Value{ .scalar = l.base.energy };
            if (world.get(entity, components.SpotLight2D)) |l| break :blk Value{ .scalar = l.base.energy };
            if (world.get(entity, components.DirectionalLight2D)) |l| break :blk Value{ .scalar = l.base.energy };
            if (world.get(entity, components.AmbientLight2D)) |l| break :blk Value{ .scalar = l.base.energy };
            if (world.get(entity, components.Light2D)) |l| break :blk Value{ .scalar = l.energy };
            break :blk null;
        },
        .radius => blk: {
            if (world.get(entity, components.PointLight2D)) |l| break :blk Value{ .scalar = l.radius };
            if (world.get(entity, components.SpotLight2D)) |l| break :blk Value{ .scalar = l.radius };
            break :blk null;
        },
        .value => if (world.get(entity, components.UiProgressBar)) |b| Value{ .scalar = b.value } else null,
        .duration => if (world.get(entity, components.Timer)) |t| Value{ .scalar = t.duration } else null,
    };
}

/// Writes a value to an entity's property. False when the entity does not
/// carry the component the property lives in — the tween then does nothing
/// rather than crashing.
pub fn writeValue(world: *ecs.World, entity: ecs.Entity, field: Field, v: Value) bool {
    switch (field) {
        .position => {
            const t = world.get(entity, components.Transform) orelse return false;
            t.position = switch (v) {
                .vec2 => |x| x,
                .scalar => |s| .{ .x = s, .y = s },
                .color => |c| .{ .x = c[0], .y = c[1] },
            };
        },
        .rotation => {
            const t = world.get(entity, components.Transform) orelse return false;
            t.rotation = v.part(.x);
        },
        .scale => {
            const t = world.get(entity, components.Transform) orelse return false;
            t.scale = switch (v) {
                .vec2 => |x| x,
                .scalar => |s| .{ .x = s, .y = s },
                .color => |c| .{ .x = c[0], .y = c[1] },
            };
        },
        .tint => {
            const s = world.get(entity, components.Sprite) orelse return false;
            s.tint = switch (v) {
                .color => |c| c,
                .scalar => |x| .{ x, x, x, x },
                .vec2 => |x| .{ x.x, x.y, 0, 1 },
            };
        },
        .color => {
            if (world.get(entity, components.Label)) |l| {
                l.color = switch (v) {
                    .color => |c| c,
                    .scalar => |x| .{ x, x, x, x },
                    .vec2 => |x| .{ x.x, x.y, 0, 1 },
                };
                return true;
            }
            const p = world.get(entity, components.UiPanel) orelse return false;
            p.color = switch (v) {
                .color => |c| c,
                .scalar => |x| .{ x, x, x, x },
                .vec2 => |x| .{ x.x, x.y, 0, 1 },
            };
        },
        .energy => {
            if (world.get(entity, components.PointLight2D)) |l| {
                l.base.energy = v.part(.x);
                return true;
            }
            if (world.get(entity, components.SpotLight2D)) |l| {
                l.base.energy = v.part(.x);
                return true;
            }
            if (world.get(entity, components.DirectionalLight2D)) |l| {
                l.base.energy = v.part(.x);
                return true;
            }
            if (world.get(entity, components.AmbientLight2D)) |l| {
                l.base.energy = v.part(.x);
                return true;
            }
            const l = world.get(entity, components.Light2D) orelse return false;
            l.energy = v.part(.x);
        },
        .radius => {
            if (world.get(entity, components.PointLight2D)) |l| {
                l.radius = v.part(.x);
                return true;
            }
            const l = world.get(entity, components.SpotLight2D) orelse return false;
            l.radius = v.part(.x);
        },
        .value => {
            const b = world.get(entity, components.UiProgressBar) orelse return false;
            b.value = v.part(.x);
        },
        .duration => {
            const t = world.get(entity, components.Timer) orelse return false;
            t.duration = v.part(.x);
        },
    }
    return true;
}

// ── Tests ────────────────────────────────────────────────────────────────────

const testing = std.testing;

test "a tween moves a property from where it was to where it is going" {
    var world = ecs.World.init(testing.allocator);
    defer world.deinit();
    const e = try world.spawn(.{components.Transform{ .position = .{ .x = 0, .y = 0 } }});

    var m = Manager.init(testing.allocator, null);
    m.setWorld(&world);

    const h = try m.create(e, .position, .whole, .{ .vec2 = .{ .x = 100, .y = 50 } }, 1.0, .{});
    try testing.expect(m.isAlive(h));

    // Halfway.
    m.tick(0.5);
    const t = world.get(e, components.Transform).?;
    try testing.expectApproxEqAbs(@as(f32, 50), t.position.x, 0.001);
    try testing.expectApproxEqAbs(@as(f32, 25), t.position.y, 0.001);

    // Done: the value is exactly the target, and the tween is gone.
    m.tick(0.5);
    const done = world.get(e, components.Transform).?;
    try testing.expectApproxEqAbs(@as(f32, 100), done.position.x, 0.001);
    try testing.expectApproxEqAbs(@as(f32, 50), done.position.y, 0.001);
    try testing.expect(!m.isAlive(h));
    try testing.expectEqual(@as(u32, 0), m.liveCount());
}

test "a tween drives ONE part of a value and leaves the rest alone" {
    var world = ecs.World.init(testing.allocator);
    defer world.deinit();
    const e = try world.spawn(.{components.Transform{ .position = .{ .x = 0, .y = 7 } }});

    var m = Manager.init(testing.allocator, null);
    m.setWorld(&world);
    _ = try m.create(e, .position, .x, .{ .scalar = 100 }, 1.0, .{});
    m.tick(0.5);

    const t = world.get(e, components.Transform).?;
    try testing.expectApproxEqAbs(@as(f32, 50), t.position.x, 0.001);
    try testing.expectApproxEqAbs(@as(f32, 7), t.position.y, 0.001); // untouched
}

test "an easing changes WHERE the tween is, not WHERE it ends" {
    var world = ecs.World.init(testing.allocator);
    defer world.deinit();
    const e = try world.spawn(.{components.Transform{ .position = .{ .x = 0, .y = 0 } }});

    var m = Manager.init(testing.allocator, null);
    m.setWorld(&world);
    _ = try m.create(e, .position, .x, .{ .scalar = 100 }, 1.0, .{ .easing = .out_quad });
    m.tick(0.5);

    // out_quad is past the halfway mark at t=0.5.
    const t = world.get(e, components.Transform).?;
    try testing.expect(t.position.x > 50);
    try testing.expectApproxEqAbs(@as(f32, 75), t.position.x, 0.001);
}

test "a delay holds the tween and then it runs" {
    var world = ecs.World.init(testing.allocator);
    defer world.deinit();
    const e = try world.spawn(.{components.Transform{ .position = .{ .x = 0, .y = 0 } }});

    var m = Manager.init(testing.allocator, null);
    m.setWorld(&world);
    _ = try m.create(e, .position, .x, .{ .scalar = 100 }, 1.0, .{ .delay = 0.5 });

    m.tick(0.25);
    try testing.expectApproxEqAbs(@as(f32, 0), world.get(e, components.Transform).?.position.x, 0.001);

    // The delay expires inside this frame. The tween does NOT start in the
    // middle of it: it starts on the next one, from zero, with no head start.
    m.tick(0.5);
    try testing.expectApproxEqAbs(@as(f32, 0), world.get(e, components.Transform).?.position.x, 0.001);

    m.tick(0.25);
    try testing.expectApproxEqAbs(@as(f32, 25), world.get(e, components.Transform).?.position.x, 0.001);
}

test "repeat runs the tween again, and yoyo runs it backwards" {
    var world = ecs.World.init(testing.allocator);
    defer world.deinit();
    const e = try world.spawn(.{components.Transform{ .position = .{ .x = 0, .y = 0 } }});

    var m = Manager.init(testing.allocator, null);
    m.setWorld(&world);
    // One extra cycle: the tween runs twice.
    const h = try m.create(e, .position, .x, .{ .scalar = 100 }, 1.0, .{ .repeat = 1 });
    m.tick(0.5);
    try testing.expectApproxEqAbs(@as(f32, 50), world.get(e, components.Transform).?.position.x, 0.001);

    // The cycle ends and the NEXT one begins: the value goes back to the
    // start. That is what "repeat" is — a pulse, not a ping-pong.
    m.tick(0.5);
    try testing.expectApproxEqAbs(@as(f32, 0), world.get(e, components.Transform).?.position.x, 0.001);
    try testing.expect(m.isAlive(h)); // the second cycle is pending
    m.tick(0.5);
    try testing.expectApproxEqAbs(@as(f32, 50), world.get(e, components.Transform).?.position.x, 0.001);
    m.tick(0.5);
    try testing.expectApproxEqAbs(@as(f32, 100), world.get(e, components.Transform).?.position.x, 0.001);
    try testing.expect(!m.isAlive(h));

    // The yoyo: out and back. It is ONE run, so it takes twice the time.
    const e2 = try world.spawn(.{components.Transform{ .position = .{ .x = 0, .y = 0 } }});
    _ = try m.create(e2, .position, .x, .{ .scalar = 100 }, 1.0, .{ .yoyo = true });
    m.tick(1.0);
    try testing.expectApproxEqAbs(@as(f32, 100), world.get(e2, components.Transform).?.position.x, 0.001);
    m.tick(0.5);
    try testing.expectApproxEqAbs(@as(f32, 50), world.get(e2, components.Transform).?.position.x, 0.001);
    m.tick(0.5);
    try testing.expectApproxEqAbs(@as(f32, 0), world.get(e2, components.Transform).?.position.x, 0.001);
}

test "a chain starts the child when the parent finishes" {
    var world = ecs.World.init(testing.allocator);
    defer world.deinit();
    const e = try world.spawn(.{components.Transform{ .position = .{ .x = 0, .y = 0 } }});

    var m = Manager.init(testing.allocator, null);
    m.setWorld(&world);
    const parent = try m.create(e, .position, .x, .{ .scalar = 100 }, 1.0, .{});
    const child = try m.create(e, .position, .y, .{ .scalar = 100 }, 1.0, .{ .hold = true });
    try testing.expect(try m.chain(parent, child));

    // The child is parked: the parent moves x and the child does not.
    m.tick(0.5);
    const t = world.get(e, components.Transform).?;
    try testing.expectApproxEqAbs(@as(f32, 50), t.position.x, 0.001);
    try testing.expectApproxEqAbs(@as(f32, 0), t.position.y, 0.001);

    // The parent finishes. The child is released, but it starts on the NEXT
    // tick: the tail of this frame belongs to the parent.
    m.tick(0.5);
    const t1 = world.get(e, components.Transform).?;
    try testing.expectApproxEqAbs(@as(f32, 100), t1.position.x, 0.001);
    try testing.expectApproxEqAbs(@as(f32, 0), t1.position.y, 0.001);

    // Now the child runs.
    m.tick(0.5);
    const t2 = world.get(e, components.Transform).?;
    try testing.expectApproxEqAbs(@as(f32, 50), t2.position.y, 0.001);
}

test "killing a tween stops it and frees its slot" {
    var world = ecs.World.init(testing.allocator);
    defer world.deinit();
    const e = try world.spawn(.{components.Transform{ .position = .{ .x = 0, .y = 0 } }});

    var m = Manager.init(testing.allocator, null);
    m.setWorld(&world);
    const h = try m.create(e, .position, .x, .{ .scalar = 100 }, 1.0, .{});
    m.tick(0.5);
    try testing.expect(m.kill(h));
    try testing.expect(!m.isAlive(h));
    try testing.expectEqual(@as(u32, 0), m.liveCount());

    // The value stays where the tween left it: a killed tween does not
    // teleport the property back.
    m.tick(0.5);
    try testing.expectApproxEqAbs(@as(f32, 50), world.get(e, components.Transform).?.position.x, 0.001);
}

test "a slot freed by a finished tween is handed out again — and to the right one" {
    // The regression this pins: the pool freed a slot and then handed out a
    // slot index that was not a slot index at all, and the next tween wrote
    // 14400 entries past the end of the pool. The cause was deriving the slot
    // from a POINTER (`&tweens[0]` arithmetic) instead of carrying the index:
    // the pointer is only valid while the manager stays where it was.
    var world = ecs.World.init(testing.allocator);
    defer world.deinit();
    const e = try world.spawn(.{components.Transform{ .position = .{ .x = 0, .y = 0 } }});

    var m = Manager.init(testing.allocator, null);
    m.setWorld(&world);
    const first = try m.create(e, .position, .x, .{ .scalar = 100 }, 0.5, .{});
    try testing.expect(first >= 1 and first <= max_tweens);

    // Let it finish: the slot goes back on the free list.
    m.tick(1.0);
    try testing.expectEqual(@as(u32, 0), m.liveCount());

    // The next tween gets a real slot — and the pool still holds.
    const second = try m.create(e, .position, .x, .{ .scalar = 50 }, 0.5, .{});
    try testing.expect(second >= 1 and second <= max_tweens);
    try testing.expectEqual(@as(u32, 1), m.liveCount());

    // And a tween that is killed frees its slot the same way.
    try testing.expect(m.kill(second));
    m.tick(0.1);
    const third = try m.create(e, .position, .x, .{ .scalar = 25 }, 0.5, .{});
    try testing.expect(third >= 1 and third <= max_tweens);
}

test "the pool reports a full house instead of dropping a tween" {
    var m = Manager.init(testing.allocator, null);
    var i: u32 = 0;
    while (i < max_tweens) : (i += 1) {
        _ = try m.create(ecs.Entity.invalid, .position, .whole, .{ .scalar = 1 }, 1.0, .{});
    }
    try testing.expectError(error.TweenLimitReached, m.create(ecs.Entity.invalid, .position, .whole, .{ .scalar = 1 }, 1.0, .{}));
    try testing.expectEqual(@as(u32, max_tweens), m.liveCount());
}

test "the global tween scale moves the animations, not the world" {
    var world = ecs.World.init(testing.allocator);
    defer world.deinit();
    const e = try world.spawn(.{components.Transform{ .position = .{ .x = 0, .y = 0 } }});

    var m = Manager.init(testing.allocator, null);
    m.setWorld(&world);
    _ = try m.create(e, .position, .x, .{ .scalar = 100 }, 1.0, .{});

    m.setTimeScale(0.5);
    m.tick(1.0);
    try testing.expectApproxEqAbs(@as(f32, 50), world.get(e, components.Transform).?.position.x, 0.001);

    // A frozen manager moves nothing.
    m.setTimeScale(0);
    m.tick(1.0);
    try testing.expectApproxEqAbs(@as(f32, 50), world.get(e, components.Transform).?.position.x, 0.001);
}

test "a tween on an entity without the component does nothing, and does not crash" {
    var world = ecs.World.init(testing.allocator);
    defer world.deinit();
    const e = try world.spawn(.{components.Transform{}});

    var m = Manager.init(testing.allocator, null);
    m.setWorld(&world);
    // A sprite tween on an entity with no Sprite.
    _ = try m.create(e, .tint, .a, .{ .scalar = 0 }, 1.0, .{});
    m.tick(0.5);
    try testing.expect(true); // the point is that it did not crash
}
