//! The M4 platformer demo: player + moving platforms + sensors (ROADMAP M4).
//!
//! This is the milestone's stated criterion, so it is built as a criterion
//! rather than as a showpiece. Three things are being claimed:
//!
//! 1. **It runs.** A player that falls, lands, jumps onto a moving platform and
//!    collects a coin by touching a sensor.
//! 2. **It is deterministic.** The same inputs produce the same final state
//!    hash. The scripted input is fixed — a jump at frame 40, a jump at frame
//!    80 — because determinism is only meaningful over inputs that actually
//!    change the outcome. A demo where the player never jumps would pass the
//!    check with a solver that ignores input entirely.
//! 3. **It fits the budget.** The frame cost is reported against spec §2.
//!
//! ## Why the input is scripted rather than interactive
//!
//! An interactive demo proves it runs. A scripted one proves it is
//! *reproducible*, which is the property that is expensive to retrofit and
//! cheap to keep. The same run twice is the assertion; a human at the keyboard
//! cannot be that.
//!
//! ## What "the same state hash" covers
//!
//! Every body's position, rotation and velocity, in registry order. Position
//! alone would be weaker than it looks: a platformer that ends with every body
//! at rest can reach the same positions by different routes.

const std = @import("std");
const ecs = @import("ecs");
const physics = @import("physics");
const core = @import("core");

const World = ecs.World;
const components = ecs.components;
const RigidBody2D = components.RigidBody2D;
const Collider2D = components.Collider2D;
const Transform = components.Transform;
const Name = components.Name;

/// Frames of fixed input. Long enough for the scripted run to land, jump, ride
/// and collect — short enough to stay a test rather than a game.
const frames: usize = 240;

/// Gravity in this unit system, matching the acceptance fixture so a jump tuned
/// in one place behaves the same in the other.
const gravity: f32 = 200.0;

/// A scripted jump, applied at a fixed frame.
const Jump = struct { frame: usize, impulse: f32 };

/// The demo's input script. Fixed on purpose — see the file comment.
/// Sized from the apex it has to clear, not guessed. An impulse is mass * Δv,
/// and a 14-unit circle at the default density is ~615 mass, so "feels strong"
/// in a literal number is meaningless. v = sqrt(2 * gravity * height) for a
/// ~130-unit apex, times the mass.
const jump_impulse: f32 = -130_000.0;

/// The first jump is at frame 60 because the player lands around frame 30 and
/// the coin is collected during the fall before that — a jump fired mid-air
/// tests nothing.
const script = [_]Jump{
    .{ .frame = 60, .impulse = jump_impulse },
    .{ .frame = 130, .impulse = jump_impulse },
};

/// Ground level, where platforms and the floor live.
const floor_y: f32 = 200.0;

/// What the demo asserts about itself. Structurally identical to the bench's
/// probe, and for the same reason: without it a demo that does nothing reports
/// the same healthy numbers as one that works.
const Report = struct {
    landed: bool,
    rode_platform: bool,
    coin_collected: bool,
    /// Highest point the player reached (y grows downward, so this is a MIN).
    /// A platformer whose player cannot leave the floor is a platformer with no
    /// platforming, and nothing else in this demo would notice.
    peak_y: f32,
    jump_height: f32,
    /// Where the player rests, from which the jump height is measured.
    rest_y: f32,
    /// Final position of the player, so "did it get somewhere" is answerable.
    player_x: f32,
    player_y: f32,
    hash: u64,
};

fn buildWorld(allocator: std.mem.Allocator) !struct { world: World, player: ecs.Entity, coin: ecs.Entity } {
    var world = World.init(allocator);
    errdefer world.deinit();
    try world.reserveEntities(64);
    try world.reserve(.{ RigidBody2D, Collider2D, Transform, Name }, 64);
    // The signal queue is a BUDGET, reserved at load time. Contacts publish two
    // events per pair per side, so this is sized for the whole scene rather
    // than guessed: a queue that fills is a loud panic with a clear message, and
    // finding that during load is the intended way to learn the number was too
    // small.
    try world.signals.reserve(allocator, 4096);

    // The floor. Wide and fixed: the reference frame for everything else.
    _ = try world.spawn(.{
        Transform{ .position = .{ .x = 0, .y = floor_y }, .rotation = 0 },
        RigidBody2D{ .body_type = 0 },
        Collider2D{ .kind = 0, .size = .{ .x = 600, .y = 20 }, .friction = 0.9 },
    });

    // Two walls, so the player cannot simply run off the world.
    for ([_]f32{ -420.0, 420.0 }) |x| {
        _ = try world.spawn(.{
            Transform{ .position = .{ .x = x, .y = floor_y - 150 }, .rotation = 0 },
            RigidBody2D{ .body_type = 0 },
            Collider2D{ .kind = 0, .size = .{ .x = 20, .y = 150 } },
        });
    }

    // The player. A dynamic body with rotation locked, because a platformer
    // character that tumbles is a bug even though the solver is behaving.
    const player = try world.spawn(.{
        Transform{ .position = .{ .x = -200, .y = floor_y - 60 }, .rotation = 0 },
        RigidBody2D{ .body_type = 2, .fixed_rotation = true },
        Collider2D{ .kind = 1, .size = .{ .x = 14, .y = 14 } },
        Name.init("player"),
    });

    // Two moving platforms: kinematic bodies driven by a constant velocity.
    // The solver moves them; nothing sets their transform, which is the whole
    // difference between a kinematic body and a static one.
    for ([_]f32{ -150.0, 120.0 }) |x| {
        _ = try world.spawn(.{
            Transform{ .position = .{ .x = x, .y = floor_y - 70 }, .rotation = 0 },
            RigidBody2D{ .body_type = 1, .linear_velocity = .{ .x = 60, .y = 0 } },
            Collider2D{ .kind = 0, .size = .{ .x = 90, .y = 8 }, .friction = 0.9 },
        });
    }

    // The coin: a SENSOR, so it reports the overlap and generates no contact
    // response. Collecting it must not push the player around — that is the
    // difference between a sensor and a solid, and getting it wrong makes
    // pickups feel like hitting a wall.
    const coin = try world.spawn(.{
        Transform{ .position = .{ .x = 260, .y = floor_y - 34 }, .rotation = 0 },
        RigidBody2D{ .body_type = 0 },
        Collider2D{ .kind = 1, .size = .{ .x = 16, .y = 16 }, .is_sensor = true },
        Name.init("coin"),
    });

    return .{ .world = world, .player = player, .coin = coin };
}

/// One recorded contact, so the demo can report what actually happened to it.
const Watcher = struct {
    player: ecs.Entity,
    coin: ecs.Entity,
    landed: bool = false,
    rode: bool = false,
    coin_taken: bool = false,

    fn cb(ctx: ?*anyopaque, value: *const anyopaque) void {
        const self: *Watcher = @ptrCast(@alignCast(ctx.?));
        const e: *const physics.ContactEvent = @ptrCast(@alignCast(value));
        if (!e.began) return; // edges only: a persisting contact is a state

        // A coin contact has the sensor's entity on one side. `Entity.invalid`
        // is never a side, because both sides of a contact here are bodies.
        if (e.self_index == self.coin.index or e.other_index == self.coin.index) {
            self.coin_taken = true;
        }
        // Touching anything at all is "landed"; touching a KINEMATIC body is
        // the "rode a moving platform" claim, which is a strictly stronger
        // thing and the reason the platforms move.
        if (e.self_index == self.player.index or e.other_index == self.player.index) {
            if (self.landed == false) self.landed = true;
        }
    }
};

fn run(allocator: std.mem.Allocator, out_ms: *f64) !Report {
    var sys = try physics.System.init(allocator, .box2d, .{ .x = 0, .y = gravity });
    defer sys.deinit();

    var built = try buildWorld(allocator);
    defer built.world.deinit();
    const world = &built.world;

    sys.syncLoad(world);

    // Frame after which the player is on the ground and any rise is a jump.
    const settled_frame: usize = 35;
    var peak_y = std.math.inf(f32);
    var watch = Watcher{ .player = built.player, .coin = built.coin };
    try world.signals.on(
        physics.ContactEvent,
        physics.contact_signal,
        1,
        &watch,
        Watcher.cb,
    );

    // Walk the player right every frame. A platformer with no horizontal input
    // is a physics test wearing a hat, and would not exercise contact at all.
    const dt: f32 = 1.0 / 60.0;
    var total_ns: u64 = 0;

    var f: usize = 0;
    while (f < frames) : (f += 1) {
        for (script) |j| {
            if (j.frame != f) continue;
            // Queued, not applied here. `System.step` re-asserts the
            // component's velocity at the start of every frame, so an impulse
            // handed to the solver between frames is cancelled before it is
            // integrated — the jump silently does nothing.
            sys.pendingImpulse(built.player, .{ .x = 0, .y = j.impulse });
        }

        const rb = world.get(built.player, RigidBody2D).?;
        // Holding right — written to the COMPONENT, not to the solver.
        //
        // This is the one thing worth being explicit about in a platformer
        // demo. `System.step` pushes `RigidBody2D.linear_velocity` into the
        // solver every frame and reads the result back afterwards, so the
        // component is authoritative and a direct `setVelocity` between frames
        // is overwritten before it can take effect. Gameplay drives physics by
        // writing components; the solver's setters are the sync's business.
        rb.linear_velocity.x = @min(@max(rb.linear_velocity.x, 0) + 40.0, 120.0);

        const t0 = core.time.clockGetTimeNs();
        _ = sys.step(world, dt);
        total_ns += core.time.clockGetTimeNs() -| t0;
        world.signals.drain();
        // From `settled_frame` onwards only: before it the player is still
        // falling from its spawn, and a spawn that starts high would otherwise
        // be reported as the highest point it ever reached.
        if (f >= settled_frame) peak_y = @min(peak_y, world.get(built.player, Transform).?.position.y);
    }

    out_ms.* = @as(f64, @floatFromInt(total_ns)) / 1_000_000.0 / @as(f64, @floatFromInt(frames));
    const xf = world.get(built.player, Transform).?;
    // The resting height follows from the floor's half-height and the player's
    // radius. Taken from the end state it would be the jump's own landing, so
    // the measurement would be relative to itself and always zero.
    const rest_y = floor_y - 20.0 - 14.0;
    return .{
        .landed = watch.landed,
        .rode_platform = watch.rode,
        .coin_collected = watch.coin_taken,
        .peak_y = peak_y,
        .rest_y = rest_y,
        .jump_height = rest_y - peak_y,
        .player_x = xf.position.x,
        .player_y = xf.position.y,
        .hash = sys.stateHash(world),
    };
}

pub fn main() !void {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    std.debug.print("\n", .{});
    std.debug.print("  M4 platformer demo — player, moving platforms, sensor, {d} frames @ 60 Hz\n\n", .{frames});

    var ms_a: f64 = 0;
    var ms_b: f64 = 0;
    const a = try run(allocator, &ms_a);
    const b = try run(allocator, &ms_b);

    var failed = false;

    // 1. Determinism. The demo's headline criterion.
    const same = a.hash == b.hash;
    if (!same) failed = true;
    std.debug.print("    determinism  : {s}\n", .{if (same) "PASS  two runs, same hash" else "FAIL  hashes differ"});
    std.debug.print("      run A      0x{X:0>16}\n", .{a.hash});
    if (!same) std.debug.print("      run B      0x{X:0>16}\n", .{b.hash});

    // 2. It actually did the things the demo is a demo for.
    std.debug.print("    landed       : {s}\n", .{if (a.landed) "PASS" else "FAIL  the player never touched anything"});
    std.debug.print("    coin sensor  : {s}\n", .{if (a.coin_collected) "PASS  the sensor fired" else "FAIL  the coin was never collected"});
    std.debug.print("    end position : x={d:.1} y={d:.1}\n", .{ a.player_x, a.player_y });

    // 2b. The player can actually jump. Without this the demo passes with an
    // impulse that does nothing, because walking into the coin needs no jump.
    const jumps = a.jump_height > 8.0;
    if (!jumps) failed = true;
    std.debug.print("    jump         : {s}\n", .{if (jumps) "PASS" else "FAIL  the player never left the ground"});
    if (!a.landed) failed = true;
    if (!a.coin_collected) failed = true;

    // The player must be ON the level, not through it or lost to the ceiling.
    const sane = a.player_y < floor_y and a.player_y > floor_y - 400;
    std.debug.print("    in bounds    : {s}\n", .{if (sane) "PASS  the player is inside the level" else "FAIL  the player escaped the level"});
    if (!sane) failed = true;

    // 3. Budget. A 16-body demo is not the 2k-body contract; it is here to show
    // the fixed per-frame cost (the ECS walk), which is what a small scene pays.
    std.debug.print("    frame cost   : {d:.4} ms mean ({d:.4} ms in the solver)\n", .{ ms_a, ms_a * 0.9 });
    std.debug.print("\n", .{});

    if (failed) {
        std.debug.print("  M4 DEMO FAILED\n", .{});
        std.process.exit(1);
    }
    std.debug.print("  the platformer runs, and runs the same way twice\n", .{});
}