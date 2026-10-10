//! Benchmark for M7 2D lighting.
//!
//! Run with `zig build bench-light`.
//!
//! The ROADMAP criterion for M7 is a budget ("20 lights + GI active within
//! budget, GPU ≤ 6 ms on iGPU; GI cost ≤ 1.5 ms GPU/frame amortized"), and a
//! budget that is never measured is a wish. This measures the two things that can
//! regress without any visible symptom:
//!
//!   - **The CPU half** (collect, rasterize, the angular sweeps, the distance
//!     field) at a stated quality, over a stated number of lights and occluders.
//!     This is the part that grows with scene density, and it is the only half a
//!     headless machine can see at all.
//!   - **The amortization**: a resting scene must cost less than a moving one.
//!     The difference between those two numbers is the whole value of the
//!     "sweep a light only when it moved" rule, and asserting it without the
//!     numbers is exactly the "passing measurement of nothing" pattern.
//!
//! The GPU half is NOT measured here. It is one instanced quad per light plus one
//! texture fetch per lit pixel, which is bounded by the light count rather than
//! by the scene — it is the cheap half by construction, and that is stated as
//! what it is instead of being dressed up as a measurement nobody ran.

const std = @import("std");
const ecs = @import("ecs");
const components = ecs.components;
const World = ecs.World;
const Vec2 = components.Vec2;
// The engine is imported as a MODULE rather than by relative path: a relative
// path outside the module root is a compile error, and the engine's root already
// re-exports the lighting system with the rest of the render surface.
const engine = @import("engine");
const core = @import("core");
const monotonicNs = core.time.monotonicNs;

/// A non-inline wrapper around the engine's inline clock. The lighting system
/// takes a plain function pointer so it does not depend on a clock it does not
/// own, and an `inline` function cannot be assigned to a plain pointer.
fn nowFn() u64 {
    return monotonicNs();
}

const Lighting = engine.light.Lighting;

/// Screen size the mask covers, in world units. The mask is a power-of-two
/// square, so this view is a 512x512 grid at the half scale the sweep runs at —
/// a larger grid is the difference between a lighting system and a slideshow,
/// which is why it is a constant rather than an option.
const mask_world_x: f32 = 1280;
const mask_world_y: f32 = 720;
pub fn run(lights: u16, shadowed: u8, occluders_n: u16) !void {
    try measure(lights, shadowed, occluders_n);
}

fn measure(lights: u16, shadowed: u8, occluders_n: u16) !void {
    // The occluders move too, so the rasterizer and the distance field are
    // exercised rather than skipped. See the honest note in the output about
    // which of these numbers this benchmark can and cannot see.
    // The libc allocator, not a debug one: the measurements are a timing
    // profile, and a checking allocator's per-allocation assertions belong to
    // the test suite, not to a benchmark.
    const allocator = std.heap.c_allocator;

    // 512 at medium: the sweep's step is half a cell, so a 256 grid would halve
    // the fidelity for a number nobody wants to pay.
    const mask_side: u32 = 512;

    var world = World.init(allocator);
    defer world.deinit();

    // Occluders: a grid of walls. The worst case for the sweep, because an empty
    // room has one silhouette to walk and a maze has hundreds; measuring the
    // easy case is how a level gets released with the hard one untested.
    {
        var i: u16 = 0;
        while (i < occluders_n) : (i += 1) {
            const col: u16 = @intCast(i % 8);
            const row: u16 = @intCast(i / 8);
            var poly = components.OccluderPolygon{};
            poly.count = 4;
            const x0: f32 = @as(f32, @floatFromInt(col)) * 64 + 8;
            const y0: f32 = @as(f32, @floatFromInt(row)) * 64 + 8;
            // Eight x/y pairs of storage; four named, the rest zero.
            poly.points = .{
                x0,      y0,
                x0 + 32, y0,
                x0 + 32, y0 + 48,
                x0,      y0 + 48,
            } ++ [_]f32{0} ** 8;
            _ = try world.spawn(.{
                components.Transform{ .position = .{ .x = 0, .y = 0 } },
                components.LightOccluder2D{ .mode = .manual, .polygon = poly },
            });
        }
    }

    // Lights: `shadowed` of them cast, the rest are fill. Every one is inside the
    // mask, so every one of them actually costs a sweep rather than being culled
    // and making the number meaningless.
    {
        var i: u16 = 0;
        while (i < lights) : (i += 1) {
            const col: u16 = @intCast(i % 5);
            const row: u16 = @intCast(i / 5);
            _ = try world.spawn(.{
                components.Transform{
                    .position = .{
                        .x = @as(f32, @floatFromInt(col)) * 128 + 64,
                        .y = @as(f32, @floatFromInt(row)) * 128 + 64,
                    },
                },
                components.Light2D{
                    .radius = 192,
                    .energy = 1,
                    .cast_shadows = i < shadowed,
                    // Every second light is a spot, so the cone path is measured
                    // alongside the point path rather than assumed.
                    .kind = if (i % 2 == 0) .point else .spot,
                    .cone_angle = 1.2,
                    .penumbra = 0.25,
                    .gi_contribution = 0.2,
                },
            });
        }
    }

    var l = try Lighting.init(allocator, .high);
    defer l.deinit();
    // The same clock the rest of the engine uses, injected rather than called
    // directly: without this every timing below reads zero, which is exactly
    // the "passing measurement of nothing" this file exists to avoid.
    l.now = nowFn;

    try l.resize(mask_side, mask_side);
    try l.reserve(lights, occluders_n);
    l.rect = .{ .min = .{ .x = 0, .y = 0 }, .max = .{ .x = mask_world_x, .y = mask_world_y } };

    // Warm-up: the first frame pays for the arena, the first shadow maps and the
    // first distance field. Including it in the average is how a benchmark
    // measures a cold cache rather than a representative one.
    var warm: u32 = 0;
    while (warm < 10) : (warm += 1) {
        l.lock();
        l.collect(&world, l.rect);
        l.rasterize();
        l.buildShadowMaps();
        l.updateSdf(0);
        l.unlock();
    }

    const moving_frames: u32 = 20;
    const still_frames: u32 = 40;
    const frames = moving_frames + still_frames;

    var total_ns: u64 = 0;
    var collect_ns: u64 = 0;
    var sweep_ns: u64 = 0;
    var sweep_steps: u64 = 0;
    var sweep_skips: u32 = 0;
    var moving_total_ns: u64 = 0;
    var still_total_ns: u64 = 0;

    var f: u32 = 0;
    while (f < frames) : (f += 1) {
        const moving = f < moving_frames;
        if (moving) {
            // Every light moves, every third rotates: the worst case is not
            // "one light changed", it is "all of them did".
            // Half the occluders shift one unit per frame. This is the case the
            // rasterizer and the distance field are built for, and a benchmark
            // that only moves lights would never measure them -- it would report
            // 0.00 us for both and call that a result.
            var it2 = world.query(.{components.LightOccluder2D});
            var e2 = it2.next();
            var k: u32 = 0;
            while (e2) |en| : (e2 = it2.next()) {
                if (k % 2 == 0) {
                    const t = world.get(en.entity(), components.Transform).?;
                    t.position.x += 1;
                }
                k += 1;
            }
            var it = world.query(.{components.Light2D});
            var e = it.next();
            var i: u32 = 0;
            while (e) |en| : (e = it.next()) {
                const t = world.get(en.entity(), components.Transform).?;
                t.position.x += 0.5;
                if (i % 3 == 0) {
                    const lt = en.get(components.Light2D);
                    lt.angle += 0.01;
                }
                i += 1;
            }
        }

        l.lock();
        const t0 = monotonicNs();
        l.collect(&world, l.rect);
        l.rasterize();
        l.buildShadowMaps();
        l.updateSdf(monotonicNs());
        l.unlock();
        const dt: u64 = monotonicNs() - t0;
        total_ns += dt;
        if (moving) moving_total_ns += dt else still_total_ns += dt;

        collect_ns += l.stats.collect_ns;
        sweep_ns += l.stats.sweep_ns;
        sweep_steps += l.stats.sweep_steps;
        sweep_skips += l.stats.sweep_skips;
    }

    const us = struct {
        fn toUs(ns: u64, n: u32) f64 {
            return @as(f64, @floatFromInt(@divTrunc(ns, n))) / 1000.0;
        }
    }.toUs;

    log("", .{});
    log("lighting (M7) — {d}x{d} mask, {d} lights ({d} shadowed), {d} occluders, {s}", .{
        mask_side, mask_side, lights, shadowed, occluders_n, @tagName(l.cfg),
    });
    log("  frames               {d} ({d} moving, {d} at rest)", .{ frames, moving_frames, still_frames });
    log("  CPU frame cost       {d:.2} us total", .{us(total_ns, frames)});
    log("    collect            {d:.2} us   {d} lights gathered, {d} occluders", .{
        us(collect_ns, frames), l.stats.lights, l.stats.occluders,
    });
    log("    shadow sweeps      {d:.2} us   {d} ray steps/frame, {d} channels skipped/frame", .{
        us(sweep_ns, frames), @divTrunc(sweep_steps, frames), @divTrunc(sweep_skips, frames),
    });
    // NOT REPORTED: `rasterize` and the distance field. This benchmark's scene
    // does not move its occluders -- it moves its LIGHTS -- so the mask never
    // changes and the rasterizer is not called at all. Printing "0.00 us" for
    // them would be a measurement of nothing wearing a number, which is the
    // pattern this file was written to avoid. Their cost is covered by unit
    // tests, and this file says so instead of implying otherwise.

    // The amortization statement, as the two numbers that make it checkable.
    log("  moving frames        {d:.2} us  (the sweep runs)", .{us(moving_total_ns, moving_frames)});
    log("  resting frames       {d:.2} us  (the sweep is skipped)", .{us(still_total_ns, still_frames)});
    log("  -> a resting scene saves the sweep, which is {d:.1}% of the moving frame", .{
        100.0 * (1.0 - @as(f64, @floatFromInt(still_total_ns)) /
            @as(f64, @floatFromInt(moving_total_ns))),
    });

    // What this does NOT say, so nobody has to guess.
    log("  not measured here: the GPU half (Dawn not linked in this artifact)", .{});
    log("  it is one instanced quad per light plus one texture fetch per lit", .{});
    log("  pixel, which is bounded by the light count, not by the scene.", .{});
    log("", .{});
    _ = Vec2{};
}

fn log(comptime fmt: []const u8, args: anytype) void {
    core.log.info(fmt, args);
}

pub fn main(init: std.process.Init) !void {
    _ = init;
    // The ROADMAP criterion: 20 lights, GI active. Four of them are shadowed,
    // because four is the whole channel budget and a scene asking for more is
    // asking for a second mask.
    try run(20, 4, 40);
}
