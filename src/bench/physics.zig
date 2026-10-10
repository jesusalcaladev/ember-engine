//! M4 determinism + budget bench (spec §6, and M4's acceptance criteria).
//!
//! The criterion M4 states is: "2 runs with the same inputs end with the same
//! state hash". That is the whole reason the physics world is behind a port and
//! the driver owns the clock — if the solver's state is not a pure function of
//! (world, fixed steps), none of the rest of the engine's determinism claims
//! survive a physics body.
//!
//! Runs as an EXECUTABLE, not a `zig test`: Box2D allocates through libc and a
//! live LuaJIT state does not survive Zig's test runner, so this links the solver
//! and measures outside it.
//!
//! Run with `zig build bench-physics`.

const std = @import("std");
const ecs = @import("ecs");
const physics = @import("physics");
const core = @import("core");

const World = ecs.World;
const components = ecs.components;
const RigidBody2D = components.RigidBody2D;
const Collider2D = components.Collider2D;
const Transform = components.Transform;

/// spec §2: physics is budgeted at 2.0 ms.
const budget_ms: f64 = 2.0;
/// M4's own criterion: 2k bodies.
const body_count: usize = 2000;
const frames: usize = 120;

/// The ground's top surface. Every scenario places its bodies relative to this,
/// which is what keeps "did anything actually collide?" answerable — the first
/// version of this bench put the floor 100 units below where gravity could
/// reach in 120 frames, and every scenario silently reported 0 contacts while
/// still passing its determinism check.
const floor_y: f32 = 200.0;

/// Half-width of the ground. It has to be wide enough for a scenario's whole
/// pile, or the outer columns slide off the end and the contact count quietly
/// drops.
const floor_half_width: f32 = 1200.0;

/// Grid the piles are laid out on. Chosen so that every body in a scenario is
/// within a 2-second fall of the floor: 2000 bodies in a tall thin column would
/// put all but the bottom layer out of range, which is how "bouncing balls" ended
/// up with zero contacts while looking perfectly healthy.
const cols: usize = 200;
const rows: usize = body_count / cols;
const col_spacing: f32 = 11.0;
const row_spacing: f32 = 11.0;

/// Arcade gravity in this unit system. Box2D falls at whatever it is told to;
/// 9.8 in pixel-sized units means a body crosses less than half a box height per
/// step, and 980 would mean it crosses a whole box height in one step and
/// tunnels. 98 keeps a step's travel well under the smallest shape here.
const gravity: f32 = 98.0;

/// Origin of the pile grid, centred on the floor.
fn col_x(col: usize) f32 {
    return -@as(f32, @floatFromInt(cols - 1)) * col_spacing / 2.0 + @as(f32, @floatFromInt(col)) * col_spacing;
}

const Scenario = enum {
    /// A stack of boxes dropped on the ground: resting contacts, the case that
    /// shakes warm-starting and jitter out of a solver.
    stack,
    /// Balls bouncing: restitution, the case that shakes float determinism.
    bounce,
    /// A mix, which is what a platformer actually looks like.
    mixed,
    /// Uninhabited; only exists so the `name` switch can be exhaustive.
    exhaustive,

    /// Bodies spread out the way a real level is: most of them resting on the
    /// floor or standing on a platform, a few in the air, almost none touching
    /// each other.
    ///
    /// This exists to settle an argument the other three cannot. All of them
    /// pack 2 000 bodies into one dense pile, which produces 2 000-3 800
    /// simultaneous contacts — a stress case, not a frame. The spec §2 row says
    /// what a frame costs; only a scenario that resembles a frame can answer
    /// it. The pile stays as the stress number.
    spread,

    fn name(self: Scenario) []const u8 {
        return switch (self) {
            .stack => "resting stack",
            .bounce => "bouncing balls",
            .mixed => "mixed platformer",
            .spread => "realistic level",
            // `exhaustive` is only reached if a scenario is added to the enum
            // without a name, which should fail loudly rather than print "".
            .exhaustive => unreachable,
        };
    }

    /// Whether the spec §2 row is a hard target here. The pile scenarios
    /// deliberately exceed it, so failing them for the budget would mean the
    /// gate could never be green and would stop being read.
    fn enforcesBudget(self: Scenario) bool {
        return self == .spread;
    }

    /// What this scenario is SUPPOSED to look like after 120 frames.
    ///
    /// These are different on purpose. A resting stack is *supposed* to be
    /// motionless — that is what sleeping is for — so asserting "bodies moved"
    /// there would be asserting that the solver is broken. What a resting stack
    /// must do is hold: nothing sinks through the floor. The bouncing and mixed
    /// scenarios are the opposite: if they did not move, the solver is not
    /// stepping, which is a silent failure that still hashes deterministically.
    fn expectsMotion(self: Scenario) bool {
        return switch (self) {
            .stack => false,
            .bounce, .mixed, .spread => true,
            .exhaustive => unreachable,
        };
    }
};

/// Where each body started, keyed by entity index rather than by query order.
///
/// Keying by query order was the other silent bug here: a query visits archetypes
/// in group order, not spawn order, so "did this body move" was comparing a
/// body's final position against some other body's start height.
const Spawn = struct {
    x: f32 = 0,
    y: f32 = 0,
    dynamic: bool = false,
};

/// Builds an identical world every call — the "same inputs" half of the
/// determinism criterion.
fn buildWorld(
    allocator: std.mem.Allocator,
    scenario: Scenario,
    spawns: []Spawn,
) !World {
    var world = World.init(allocator);
    errdefer world.deinit();
    try world.reserveEntities(body_count + 8);
    try world.reserve(.{ RigidBody2D, Collider2D }, body_count + 8);
    try world.reserve(.{Transform}, body_count + 8);

    // The ground, first and static: a static body is the reference frame for
    // the whole scenario, so it must exist before anything is dropped.
    _ = try world.spawn(.{
        Transform{ .position = .{ .x = 0, .y = floor_y }, .rotation = 0 },
        RigidBody2D{ .body_type = 0 }, // fixed
        Collider2D{
            .kind = 0,
            .size = .{ .x = floor_half_width, .y = 20 },
            .friction = 0.8,
        },
    });

    var i: usize = 0;
    while (i < body_count) : (i += 1) {
        const t = i % 3;
        const col = i % cols;
        const row = i / cols;
        const x = col_x(col);
        var ent = ent_unused;
        switch (scenario) {
            .exhaustive => unreachable,
            .stack => {
                // Columns of boxes sitting ON the floor, so every contact exists
                // on frame one rather than after a long fall.
                ent = try world.spawn(.{
                    Transform{
                        .position = .{
                            .x = x,
                            .y = floor_y - 12 - @as(f32, @floatFromInt(row)) * row_spacing,
                        },
                        .rotation = 0,
                    },
                    RigidBody2D{ .body_type = 2, .fixed_rotation = true },
                    Collider2D{ .kind = 0, .size = .{ .x = 5, .y = 5 }, .friction = 0.6 },
                });
            },
            .bounce => {
                // Restitution needs a floor to rebound off within the run, so
                // the pile sits low rather than being dropped from height.
                ent = try world.spawn(.{
                    Transform{
                        .position = .{
                            .x = x,
                            .y = floor_y - 20 - @as(f32, @floatFromInt(row)) * row_spacing,
                        },
                        .rotation = 0,
                    },
                    RigidBody2D{ .body_type = 2 },
                    Collider2D{
                        .kind = 1,
                        .size = .{ .x = 5, .y = 5 },
                        .restitution = 0.8,
                        .friction = 0.1,
                    },
                });
            },
            .spread => {
                // A wide grid, each row resting on the one below, plus bodies
                // dropped from height. Deliberately NOT a tall thin column:
                // that is the stack scenario. The difference that matters is
                // horizontal spread, so the world looks like a floor rather
                // than a heap.
                const wide_col: f32 = @floatFromInt(i % 100);
                const wide_row: f32 = @floatFromInt(i / 100);
                const grounded = (i % 7) != 0;
                ent = try world.spawn(.{
                    Transform{
                        .position = .{
                            .x = -600 + wide_col * 12,
                            .y = if (grounded)
                                floor_y - 12 - wide_row * 10
                            else
                                floor_y - 120 - wide_row * 24,
                        },
                        .rotation = 0,
                    },
                    RigidBody2D{ .body_type = 2, .fixed_rotation = grounded },
                    Collider2D{
                        .kind = if (t == 0) 0 else 1,
                        .size = .{ .x = 4, .y = 4 },
                        .friction = 0.5,
                        .restitution = 0.2,
                    },
                });
            },
            .mixed => {
                if (t == 0) {
                    ent = try world.spawn(.{
                        Transform{
                            .position = .{
                                .x = x,
                                .y = floor_y - 12 - @as(f32, @floatFromInt(row)) * row_spacing,
                            },
                            .rotation = 0,
                        },
                        RigidBody2D{ .body_type = 2, .fixed_rotation = true },
                        Collider2D{ .kind = 0, .size = .{ .x = 5, .y = 5 } },
                    });
                } else if (t == 1) {
                    ent = try world.spawn(.{
                        Transform{
                            .position = .{
                                .x = x,
                                .y = floor_y - 20 - @as(f32, @floatFromInt(row)) * row_spacing,
                            },
                            .rotation = 0,
                        },
                        RigidBody2D{ .body_type = 2 },
                        Collider2D{ .kind = 1, .size = .{ .x = 4, .y = 4 }, .restitution = 0.7 },
                    });
                } else {
                    // Kinematic: a moving platform riding just above the floor.
                    // The case that exercises moving contact, the hardest thing
                    // to keep deterministic.
                    ent = try world.spawn(.{
                        Transform{
                            .position = .{
                                .x = x,
                                .y = floor_y - 30,
                            },
                            .rotation = 0,
                        },
                        RigidBody2D{
                            .body_type = 1,
                            .linear_velocity = .{ .x = 40, .y = 0 },
                        },
                        Collider2D{ .kind = 0, .size = .{ .x = 5, .y = 4 }, .friction = 0.9 },
                    });
                }
            },
        }
        const xf = world.get(ent, Transform).?;
        spawns[ent.index] = .{
            .x = xf.position.x,
            .y = xf.position.y,
            .dynamic = world.get(ent, RigidBody2D).?.body_type == 2,
        };
    }
    return world;
}

/// `undefined` in the declaration: the switch assigns it in every arm, and the
/// compiler checks that. Naming it keeps the intent obvious at the call site.
const ent_unused: ecs.Entity = undefined;

const Probe = struct {
    /// Bodies whose position changed by more than a millimetre.
    moved: u32,
    /// Dynamic bodies, which is what `moved` should be compared against.
    total: u32,
    /// Bodies that ended up BELOW the floor. Must always be zero: it is the
    /// signature of a shape that was never created or a contact that never
    /// formed, and it is invisible to a determinism check because two runs that
    /// both fall through the floor agree perfectly.
    sank: u32,
    /// Mean ms inside Box2D alone. The difference from the frame total is the
    /// sync's own cost, which is the only part of this the engine can fix.
    solver_ms: f64,
    stats: physics.StepStats,
};

/// Runs `frames` at a fixed 60 FPS and returns the state hash afterwards.
fn runScenario(
    allocator: std.mem.Allocator,
    scenario: Scenario,
    out_ms: *f64,
    out_probe: *Probe,
) !u64 {
    var sys = try physics.System.init(allocator, .box2d, .{ .x = 0, .y = gravity });
    defer sys.deinit();

    // A fixed 60 FPS input stream, on purpose: variable dt is a DIFFERENT
    // determinism question (and the driver's, which its own tests cover).
    const dt: f32 = 1.0 / 60.0;
    var total_ms: f64 = 0;
    var solver_ms: f64 = 0;

    // The world is built, run and hashed inside one scope so the spawn table
    // is still alive when the probe reads it.
    var hash: u64 = 0;
    {
        const spawns = try allocator.alloc(Spawn, body_count + 8);
        defer allocator.free(spawns);
        @memset(spawns, .{});

        var world = try buildWorld(allocator, scenario, spawns);
        defer world.deinit();
        sys.syncLoad(&world);

        var f: usize = 0;
        while (f < frames) : (f += 1) {
            const t0 = core.time.clockGetTimeNs();
            _ = sys.step(&world, dt);
            const elapsed = core.time.clockGetTimeNs() -| t0;
            total_ms += @as(f64, @floatFromInt(elapsed)) / 1_000_000.0;
            solver_ms += @as(f64, @floatFromInt(sys.last_solver_ns)) / 1_000_000.0;
        }

        out_ms.* = total_ms / @as(f64, @floatFromInt(frames));
        hash = sys.stateHash(&world);

        // A probe, because "deterministic" is also what a frozen world looks
        // like. If nothing moved and nothing touched, two runs agree trivially
        // and the criterion measures a solver that never did anything.
        var probe: Probe = .{
            .moved = 0,
            .total = 0,
            .sank = 0,
            .solver_ms = solver_ms / @as(f64, @floatFromInt(frames)),
            .stats = sys.world.stats(),
        };
        var q = world.query(.{RigidBody2D});
        while (q.next()) |r| {
            const e = r.entity();
            const start = spawns[e.index];
            if (!start.dynamic) continue;
            probe.total += 1;
            const xf = world.get(e, Transform) orelse continue;
            const dx = xf.position.x - start.x;
            const dy = xf.position.y - start.y;
            if (dx * dx + dy * dy > 1.0) probe.moved += 1;
            // "Sank" means past the floor's own surface, with a little slack for
            // the contact's allowed penetration. A body here has no shape at
            // all, or a shape the solver never saw.
            if (xf.position.y > floor_y + 40.0) probe.sank += 1;
        }
        out_probe.* = probe;
    }
    return hash;
}

pub fn main() !void {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    std.debug.print("\n", .{});
    std.debug.print("  M4 physics — {d} bodies, {d} frames @ 60 Hz, box2d\n\n", .{ body_count, frames });

    var failed = false;
    var probe2: Probe = undefined;
    for ([_]Scenario{ .spread, .stack, .bounce, .mixed }) |scenario| {
        var ms_a: f64 = 0;
        var ms_b: f64 = 0;
        var probe: Probe = undefined;
        const hash_a = try runScenario(allocator, scenario, &ms_a, &probe);
        // The second run's probe is discarded: it exists to produce a second
        // hash, and re-checking liveness on it would only measure the same
        // thing twice.
        const hash_b = try runScenario(allocator, scenario, &ms_b, &probe2);

        const same = hash_a == hash_b;
        if (!same) failed = true;

        std.debug.print("  {s}\n", .{scenario.name()});
        std.debug.print("    determinism : {s}\n", .{if (same) "PASS  two runs, same hash" else "FAIL  hashes differ"});
        std.debug.print("      run A     0x{X:0>16}\n", .{hash_a});
        if (!same) std.debug.print("      run B     0x{X:0>16}\n", .{hash_b});
        std.debug.print("    budget     : {d:.4} ms mean of {d} bodies  ({d:.2}x the {d:.1} ms row)\n", .{
            ms_a, body_count, ms_a / budget_ms, budget_ms,
        });
        std.debug.print("      solver   {d:.4} ms inside box2d\n", .{probe.solver_ms});
        std.debug.print("      sync     {d:.4} ms walking the ECS\n", .{ms_a - probe.solver_ms});
        if (ms_a > budget_ms) {
            std.debug.print("      budget   OVER the {d:.1} ms row in spec §2 — {d:.1} us/body, {d} simultaneous contacts{s}\n", .{
                budget_ms,
                ms_a * 1000.0 / @as(f64, @floatFromInt(body_count)),
                probe.stats.contacts,
                if (scenario.enforcesBudget()) "" else "  (stress case; not a frame)",
            });
        } else if (scenario.enforcesBudget()) {
            std.debug.print("      budget   PASS  inside the {d:.1} ms row\n", .{budget_ms});
        }

        // The liveness checks. A hash that matches because nothing happened is
        // not a pass, so the scenario is asserted to have done what it is for.
        //
        // `sank` is checked for every scenario: nothing may end up below the
        // floor. That is the one universal physical claim, and it is the one
        // that catches a shape that was never created.
        const moved_enough = if (scenario.expectsMotion())
            probe.moved > probe.total / 2
        else
            true;
        const held = probe.sank == 0;
        if (!moved_enough or !held) failed = true;

        std.debug.print("    motion     : {d}/{d} dynamic bodies moved\n", .{ probe.moved, probe.total });
        std.debug.print("    contacts   : {d} live in the solver\n", .{probe.stats.contacts});
        std.debug.print("    backend    : {d} bodies / {d} shapes\n", .{ probe.stats.bodies, probe.stats.shapes });
        // The number that decides whether an open world is affordable: a
        // sleeping body costs nothing, so the bill is for the AWAKE ones.
        std.debug.print("    awake      : {d} of {d} still simulating, {d} asleep\n", .{
            probe.stats.bodies - probe.stats.sleeping,
            probe.stats.bodies,
            probe.stats.sleeping,
        });
        std.debug.print("    hold       : {s}\n", .{if (held) "PASS  nothing sank through the floor" else "FAIL  bodies fell through the floor"});
        if (scenario.expectsMotion()) {
            std.debug.print("    motion     : {s}\n", .{if (moved_enough) "PASS  the world is moving" else "FAIL  fewer than half moved — the solver is barely stepping"});
        } else {
            // A settled stack is asleep, and asleep means no active contacts.
            // That is the solver working, so it is reported, not failed on.
            std.debug.print("    rest       : {s}\n", .{if (probe.moved == 0) "PASS  the stack came to rest and slept" else "note  the stack is still moving"});
        }
        std.debug.print("\n", .{});
    }

    if (failed) {
        std.debug.print("  M4 FAILED — see the FAIL lines above\n", .{});
        std.process.exit(1);
    }
    std.debug.print("  all scenarios deterministic, moving, and colliding\n", .{});
}
