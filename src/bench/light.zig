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
const light = engine.light;

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
    //
    // FOUR kinds, not just point, because a benchmark that measures only the kind
    // a scene is most often made of is measuring the easy path and reporting it
    // as the cost of lighting. Every third is the legacy `Light2D`, because it is
    // still registered and scenes committed before the four kinds existed carry
    // it — a bench that only spawns the new types would not notice if gathering
    // the legacy shape regressed.
    {
        var i: u16 = 0;
        while (i < lights) : (i += 1) {
            const col: u16 = @intCast(i % 5);
            const row: u16 = @intCast(i / 5);
            const x: f32 = @as(f32, @floatFromInt(col)) * 128 + 64;
            const y: f32 = @as(f32, @floatFromInt(row)) * 128 + 64;
            const xf = components.Transform{ .position = .{ .x = x, .y = y } };
            const casts = i < shadowed;

            switch (i % 4) {
                0 => _ = try world.spawn(.{
                    xf,
                    components.PointLight2D{ .radius = 192, .base = .{ .cast_shadows = casts, .gi_contribution = 0.2 } },
                }),
                1 => _ = try world.spawn(.{
                    xf,
                    components.SpotLight2D{
                        .radius = 192,
                        .cone_angle = 1.2,
                        .penumbra = 0.25,
                        .base = .{ .cast_shadows = casts, .gi_contribution = 0.2 },
                    },
                }),
                2 => _ = try world.spawn(.{
                    // The legacy single-component shape: same fields, one
                    // discriminant, still registered with a stable dense id.
                    components.Light2D{
                        .kind = if (i % 2 == 0) .point else .spot,
                        .radius = 192,
                        .cone_angle = 1.2,
                        .penumbra = 0.25,
                        .cast_shadows = casts,
                        .gi_contribution = 0.2,
                    },
                }),
                else => _ = try world.spawn(.{
                    xf,
                    // Directional lights are unbounded and cover the whole view,
                    // so including one keeps the cone-less path measured.
                    components.DirectionalLight2D{ .height = 0.5, .base = .{ .cast_shadows = casts } },
                }),
            }
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
        _ = l.updateSdf(0);
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
            // Every light kind, moved. Only moving the legacy shape would leave
            // the four new ones stationary, and stationary lights are skipped by
            // the sweep -- so the benchmark would report an amortization win that
            // is really just four lights that never moved.
            inline for (.{
                components.PointLight2D,
                components.SpotLight2D,
                components.Light2D,
                components.DirectionalLight2D,
            }) |C| {
                var it = world.query(.{C, components.Transform});
                var e = it.next();
                var i: u32 = 0;
                while (e) |en| : (e = it.next()) {
                    const t = en.get(components.Transform);
                    t.position.x += 0.5;
                    if (i % 3 == 0 and @hasField(C, "angle")) {
                        en.get(C).angle += 0.01;
                    }
                    i += 1;
                }
            }
        }

        l.lock();
        const t0 = monotonicNs();
        l.collect(&world, l.rect);
        l.rasterize();
        l.buildShadowMaps();
        _ = l.updateSdf(monotonicNs());
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
    try measureAutomatic(std.heap.c_allocator);
    try sweepGiResolution(std.heap.c_allocator);
    try acceptance(std.heap.c_allocator);
}

// ── M7 ACCEPTANCE: 20 lights + GI, end to end, through the real driver ────────
//
// The other two sections in this file drive `Lighting` directly, which measures
// the system and not the thing the runtime actually runs. Neither of them ever
// built the radiance pyramid at all, so "GI active" -- half of the ROADMAP's M7
// criterion -- had no number anywhere in the tree.
//
// This section goes through `lighting_driver.Driver`, which is the owner the
// runtime uses: it sizes the mask, gathers, rasterizes, sweeps, builds the GI
// pyramid under its amortization gate, and hands a `LightFrame` to the renderer.
// It is the whole path, minus the GPU, and it says so.
//
// WHAT IS AND IS NOT A BUDGET FAILURE, on purpose:
//
//   - The CPU numbers are checked against the budget and printed as a verdict.
//     They do NOT exit non-zero: a shared CI box or a busy laptop is not a
//     regression, and a benchmark that fails the build for being slow gets
//     muted and then ignored.
//   - The structural checks DO exit non-zero, because they are correctness, not
//     speed: 20 lights that gather as 18 means two were dropped on the floor,
//     and a `gi_not_prepared` above zero means the GI pyramid was never sized for
//     the mask. Both used to be invisible.

const acceptance_world_w: f32 = 1920;
const acceptance_world_h: f32 = 1080;

/// The M7 acceptance scene: a ring of walls, twenty lights of all four kinds,
/// an Environment with GI on, and an ambient light.
///
/// EXTRACTED rather than written twice, because `sweepGiResolution` below has
/// to measure the same scene the acceptance demo does. A sweep that quietly
/// built an easier scene would report the cost of something nobody ships, and
/// the default it picked would be tuned to the wrong thing.
///
/// Everything is placed around the ORIGIN on purpose. `viewFor(null, ...)`
/// returns a view centred on the origin, so a scene laid out from (0, 0) upward
/// is laid out off screen — which is what made the first version of this demo
/// report "15 lights gathered" out of twenty and read as a gather bug.
fn buildAcceptanceScene(world: *World, lights_n: u16, occluders_n: u16) !void {
    // The environment is a COMPONENT and the driver reads it every frame, which
    // is how a scene turns GI on. A demo that set the driver's private flag
    // would prove nothing about the path a project actually uses.
    _ = try world.spawn(.{components.Environment{
        .sky_color = .{ 0.06, 0.07, 0.10, 1 },
        .gi_enabled = true,
        .gi_albedo = 0.85,
        .ambient_color = .{ 0.04, 0.04, 0.06, 1 },
    }});

    // Walls in a ring: the shape that makes GI mean something. A scatter of
    // blocks in the open lets every probe see the sky, the pyramid comes out
    // uniformly bright, and "GI is on" is indistinguishable from "GI is off but
    // the sky is bright".
    //
    // CENTRED ON THE ORIGIN, which is not a style choice. `viewFor` with no
    // camera returns a view centred on the origin, so a scene laid out from
    // (0,0) upward is laid out OFF SCREEN. The first run of this demo put forty
    // walls and twenty lights in the positive quadrant, the view covered almost
    // none of them, and the report said "15 lights gathered" — which reads as a
    // gather bug and was a scene bug. Everything below is placed in the
    // coordinates the camera actually shows.
    var i: u16 = 0;
    while (i < occluders_n) : (i += 1) {
        const col: f32 = @as(f32, @floatFromInt(i % 8)) - 3.5;
        const row: f32 = @as(f32, @floatFromInt(i / 8)) - 2.5;
        var poly = components.OccluderPolygon{};
        poly.count = 4;
        const x0: f32 = col * 240;
        const y0: f32 = row * 180;
        poly.points = .{
            x0,       y0,
            x0 + 180, y0,
            x0 + 180, y0 + 20,
            x0,       y0 + 20,
        } ++ [_]f32{0} ** 8;
        _ = try world.spawn(.{
            components.Transform{ .position = .{ .x = 0, .y = 0 } },
            components.LightOccluder2D{ .mode = .manual, .polygon = poly },
        });
    }

    // Twenty lights: all four kinds plus the legacy shape, spread over the view
    // so none of them is culled and every one of them costs a real sweep.
    var k: u16 = 0;
    while (k < lights_n) : (k += 1) {
        const col: f32 = @as(f32, @floatFromInt(k % 5)) - 2.0;
        const row: f32 = @as(f32, @floatFromInt(k / 5)) - 1.5;
        const x: f32 = col * 384;
        const y: f32 = row * 216;
        const xf = components.Transform{ .position = .{ .x = x, .y = y } };
        switch (k % 4) {
            0 => _ = try world.spawn(.{
                xf,
                components.PointLight2D{
                    .radius = 256,
                    .base = .{ .cast_shadows = k < 4, .gi_contribution = 0.3 },
                },
            }),
            1 => _ = try world.spawn(.{
                xf,
                components.SpotLight2D{
                    .radius = 256,
                    .cone_angle = 1.2,
                    .penumbra = 0.25,
                    .base = .{ .cast_shadows = k < 4, .gi_contribution = 0.3 },
                },
            }),
            2 => _ = try world.spawn(.{
                xf,
                components.Light2D{
                    .kind = if (k % 2 == 0) .point else .spot,
                    .radius = 256,
                    .cone_angle = 1.2,
                    .penumbra = 0.25,
                    .cast_shadows = k < 4,
                    .gi_contribution = 0.3,
                },
            }),
            else => _ = try world.spawn(.{
                xf,
                components.DirectionalLight2D{
                    .height = 0.5,
                    .base = .{ .cast_shadows = k < 4, .gi_contribution = 0.3 },
                },
            }),
        }
    }
    // Ambient is its own component, not a field on the Environment, so it is
    // spawned like any other light and gathered like any other light.
    _ = try world.spawn(.{components.AmbientLight2D{
        .base = .{ .color = .{ 0.05, 0.06, 0.09, 1 } },
    }});

}

/// `lighting.gi_resolution` swept, with the cost AND the difference from the
/// full-resolution field, so the default is chosen from a trade rather than
/// from a preference.
///
/// The quality column matters as much as the cost column, and it is measured
/// rather than asserted. There is no window here, so "does it look right" cannot
/// be answered by looking; what CAN be answered is "how far does this field's
/// answer differ from the one GI had before the dial existed", sampled over a
/// grid of world points. The full-resolution field is the reference because it
/// is the pre-decouple behaviour, and it is not assumed to be perfect — it is
/// the thing every other resolution is being measured AGAINST.
///
/// Mean absolute error over `gi_samples` points, in units of the openness term
/// (0..1). A resolution that costs 30x less and reads within a percent of the
/// reference is a free win; one that costs 30x less and reads 40% different is
/// a different lighting system, and the cost column alone would not say so.
fn sweepGiResolution(allocator: std.mem.Allocator) !void {
    const lights_n: u16 = 20;
    const occluders_n: u16 = 40;

    const resolutions = [_]u32{ 0, 32, 64, 128, 256, 512, 1024 };
    const moving_frames: u32 = 6;

    log("M7 GI RESOLUTION SWEEP — what `lighting.gi_resolution` buys", .{});
    log("  medium tier, 1920x1080 view (2048x2048 mask), 21 lights, 40 occluders", .{});
    log("  MAE is against gi_resolution = 0 (match the mask), the pre-dial field.", .{});

    // The reference, built once and sampled once.
    var reference: [gi_samples]f32 = undefined;

    for (resolutions, 0..) |res, ri| {
        var world = World.init(allocator);
        defer world.deinit();
        try buildAcceptanceScene(&world, lights_n, occluders_n);

        var driver = try engine.lighting_driver.Driver.init(allocator, .medium);
        defer driver.deinit();
        try driver.setGiResolution(res);

        const view = engine.lighting_driver.Driver.viewFor(
            null,
            @intFromFloat(acceptance_world_w),
            @intFromFloat(acceptance_world_h),
        );
        try driver.resize(view);
        driver.lighting.reserve(lights_n + 4, occluders_n) catch {};
        driver.sky = .{ 0.06, 0.07, 0.10 };

        // The frame loop: only MOVING frames, because a resting frame rebuilds
        // nothing and would report a cost of zero for every resolution, making
        // the whole table a lie.
        var ds_ns: u64 = 0;
        var edt_ns: u64 = 0;
        var rebuilds: u32 = 0;
        var f: u32 = 0;
        while (f < moving_frames) : (f += 1) {
            var it = world.query(.{components.LightOccluder2D, components.Transform});
            var e = it.next();
            var n: u32 = 0;
            while (e) |en| : (e = it.next()) {
                if (n % 2 == 0) en.get(components.Transform).position.x += 1.0;
                n += 1;
            }
            const before = if (driver.lighting.radiance) |r| r.builds else 0;
            driver.update(&world, @intCast(monotonicNs()));
            const after = if (driver.lighting.radiance) |r| r.builds else 0;
            if (after != before) {
                ds_ns += driver.lighting.stats.downsample_ns;
                edt_ns += driver.lighting.stats.transform_ns;
                rebuilds += 1;
            }
        }

        // Sample the field now and compare.
        var samples: [gi_samples]f32 = undefined;
        for (0..gi_samples) |i| {
            samples[i] = driver.lighting.sampleGi(
                sampleWorldX(i),
                sampleWorldY(i),
            );
        }

        var mae: f64 = 0;
        if (ri == 0) {
            reference = samples;
        } else {
            for (samples, reference) |a, b| {
                mae += @abs(@as(f64, @floatCast(a)) - @as(f64, @floatCast(b)));
            }
            mae /= @floatFromInt(gi_samples);
        }

        const n_rebuild: f64 = @floatFromInt(@max(rebuilds, 1));
        const ds_us = @as(f64, @floatFromInt(ds_ns)) / n_rebuild / 1000.0;
        const edt_us = @as(f64, @floatFromInt(edt_ns)) / n_rebuild / 1000.0;
        const cells = @as(f64, @floatFromInt(driver.lighting.gi_w)) *
            @as(f64, @floatFromInt(driver.lighting.gi_h));
        const upload_kb = cells * 4.0 / 1024.0;

        log("  gi_resolution {d:>5} -> {d}x{d} field, {d:.1} KiB upload", .{
            res,
            driver.lighting.gi_w,
            driver.lighting.gi_h,
            upload_kb,
        });
        log("      resample {d:>7.1} us + transform {d:>8.1} us = {d:>8.1} us   MAE {d:.4}", .{
            ds_us,
            edt_us,
            ds_us + edt_us,
            mae,
        });
    }

    log("  the default is `light.default_gi_res`; this table is how it was chosen.", .{});
}

/// Sample points spread over the acceptance view, in world units. `viewFor`
/// centres on the origin, so the grid is symmetric about it.
const gi_samples: usize = 4096;

fn sampleWorldX(i: usize) f32 {
    const gx: usize = i % 64;
    return (@as(f32, @floatFromInt(gx)) - 31.5) / 31.5 * (acceptance_world_w * 0.5);
}

fn sampleWorldY(i: usize) f32 {
    const gy: usize = i / 64;
    return (@as(f32, @floatFromInt(gy)) - 31.5) / 31.5 * (acceptance_world_h * 0.5);
}

fn acceptance(allocator: std.mem.Allocator) !void {
    const lights_n: u16 = 20;
    const occluders_n: u16 = 40;

    var world = World.init(allocator);
    defer world.deinit();
    try buildAcceptanceScene(&world, lights_n, occluders_n);

    var driver = try engine.lighting_driver.Driver.init(allocator, .medium);
    defer driver.deinit();
    // The mask resolution IS the quality dial (`scale`), so the acceptance view
    // is stated rather than defaulted: 1920x1080 at scale 1 is a 2048x2048
    // power-of-two grid, which is what "1080p with GI on" actually costs.
    const view = engine.lighting_driver.Driver.viewFor(
        null,
        @intFromFloat(acceptance_world_w),
        @intFromFloat(acceptance_world_h),
    );
    try driver.resize(view);
    driver.lighting.reserve(lights_n + 4, occluders_n) catch {};
    driver.sky = .{ 0.06, 0.07, 0.10 };

    const env = engine.lighting_driver.Driver.environmentOf(&world, .{});

    // Two phases, because the amortization only means something as a pair: a
    // moving occluder set (the mask changes, so the field and the pyramid are
    // rebuilt) and a resting one (nothing changed, so neither is).
    const moving_frames: u32 = 12;
    const resting_frames: u32 = 24;
    const frames = moving_frames + resting_frames;

    var total_ns: u64 = 0;
    var moving_ns: u64 = 0;
    var resting_ns: u64 = 0;
    // Time only the frames on which the pyramid was actually rebuilt. Averaging
    // a 30 ms rebuild over 36 frames and calling the result "GI per frame" would
    // be true of the average and false of the thing being budgeted.
    var gi_rebuild_ns: u64 = 0;
    var gi_rebuilds: u32 = 0;
    // The pyramid on its own, not the frame that happens to contain it.
    var pyramid_ns: u64 = 0;
    // The sweep's counters are PER FRAME, so the last frame of the run is a
    // resting one and reports zero steps no matter how much the moving frames
    // marched. Kept from the last MOVING frame instead, for the same reason the
    // rebuild time is: an average over a run that is mostly resting answers a
    // question nobody asked.
    var sweep_steps_moving: u64 = 0;
    var sweep_ns_moving: u64 = 0;
    var steps_total: u64 = 0;

    var f: u32 = 0;
    while (f < frames) : (f += 1) {
        const moving = f < moving_frames;
        if (moving) {
            // Half the walls slide, so the mask really does change and the dirty
            // flags downstream are earned rather than assumed.
            var it = world.query(.{components.LightOccluder2D, components.Transform});
            var e = it.next();
            var n: u32 = 0;
            while (e) |en| : (e = it.next()) {
                if (n % 2 == 0) en.get(components.Transform).position.x += 1.0;
                n += 1;
            }
        }

        const before_builds = if (driver.lighting.radiance) |r| r.builds else 0;
        const t0 = monotonicNs();
        driver.update(&world, @intCast(monotonicNs()));
        const dt = monotonicNs() - t0;
        total_ns += dt;
        if (moving) moving_ns += dt else resting_ns += dt;
        steps_total += driver.lighting.stats.sweep_steps;
        if (moving) {
            sweep_steps_moving = driver.lighting.stats.sweep_steps;
            sweep_ns_moving = driver.lighting.stats.sweep_ns;
        }

        const after_builds = if (driver.lighting.radiance) |r| r.builds else 0;
        if (after_builds != before_builds) {
            gi_rebuild_ns += dt;
            gi_rebuilds += 1;
            pyramid_ns += driver.lighting.stats.pyramid_ns;
        }
    }

    // The submit half, once, through the REAL renderer type against the null
    // backend. `submitLights` is the exact call the runtime makes; the null
    // backend takes the same `LightFrame` the GPU one would and draws nothing, so
    // this proves the frame the driver produced is one the renderer accepts —
    // right sizes, right strides, an environment uploaded before the pass — and
    // not merely one that computed without crashing.
    // No `deinit`: the null backend owns counters, not memory, and its cleanup
    // is deliberately private. The runtime constructs it the same way.
    var null_backend = engine.backend_null.Backend{};
    const renderer = null_backend.renderer();
    var r2d = engine.render2d.Renderer2D.init(allocator);
    defer r2d.deinit();

    const drawn = r2d.submitLights(renderer, driver.frame(env));
    driver.gi_dirty = false;

    const l = &driver.lighting;
    const us = struct {
        fn of(ns: u64, n: u32) f64 {
            if (n == 0) return 0;
            return @as(f64, @floatFromInt(@divTrunc(ns, n))) / 1000.0;
        }
    }.of;

    log("", .{});
    log("M7 ACCEPTANCE — 20 lights + GI, through the driver, at {d}x{d}", .{
        l.alloc_w, l.alloc_h,
    });
    log("  quality               {s}, mask {d}x{d} texels, GI {s}", .{
        @tagName(l.cfg), l.alloc_w, l.alloc_h,
        if (l.radiance != null) "active" else "OFF",
    });
    log("  lights gathered       {d} (asked for 20 + 1 ambient)", .{drawn});
    // Per KIND, because "20 lights gathered" and "20 lights gathered, none of
    // them the sun" print the same number. A gather path that silently drops one
    // component type costs a fifth of the scene's light and no count notices.
    var by_kind: [4]u32 = .{ 0, 0, 0, 0 };
    for (l.lights.items) |inst| by_kind[@intFromEnum(inst.kind())] += 1;
    log("    point {d}, spot {d}, directional {d}, ambient {d}", .{
        by_kind[0], by_kind[1], by_kind[2], by_kind[3],
    });
    log("  shadow channels       {d}/{d} granted, {d} denied", .{
        l.stats.shadow_lights, @as(u32, 4), l.stats.shadow_denied,
    });
    log("  occluders             {d}, {d} rasterized this run", .{
        l.stats.occluders, l.stats.occluders_rasterized,
    });
    // The GI field reaching the renderer is a separate claim from the pyramid
    // being built: `gi_dirty` is consumed by `submit`, so a pyramid that rebuilt
    // every frame while the flag stayed false would look identical from the CPU
    // side and bounce nothing. The null backend counts the upload.
    log("  GI upload             {d} x {d}x{d} field, {d} bytes", .{
        null_backend.gi_uploads, null_backend.gi_width, null_backend.gi_height,
        null_backend.gi_upload_bytes,
    });
    log("  GI rebuilds           {d} over {d} frames, {d:.2} us each", .{
        gi_rebuilds, frames, us(gi_rebuild_ns, gi_rebuilds),
    });
    log("  CPU frame cost        {d:.2} us   (moving {d:.2}, resting {d:.2})", .{
        us(total_ns, frames), us(moving_ns, moving_frames), us(resting_ns, resting_frames),
    });
    log("    collect             {d:.2} us/frame", .{us(l.stats.collect_ns, frames)});
    log("    shadow sweeps       {d:.2} us on a moving frame, {d} ray steps/frame ({d} total)", .{
        us(sweep_ns_moving, 1), sweep_steps_moving, steps_total,
    });
    // The moving frame's cost, split by what actually spends it. `raster_ns` is
    // the last mask fill, `sdf_ns` the last exact distance transform, and the
    // pyramid is what is left of a GI rebuild once the field is subtracted — so
    // the three numbers say WHICH half needs the work rather than "lighting is
    // slow", which is the sentence every performance report degrades into.
    const raster_us = us(l.stats.raster_ns, 1);
    const sdf_us = us(l.stats.sdf_ns, 1);
    // MEASURED, not derived. This line used to be
    // `rebuild - raster - sdf`, which attributed whatever the subtraction left
    // over to the pyramid -- so the most expensive-looking number in the report
    // was a residual that included the shadow sweep, the gather and the
    // bookkeeping, wearing the pyramid's name. Reading it as "the pyramid is the
    // bottleneck" would have sent any optimisation at the wrong subsystem.
    const pyramid_us = us(pyramid_ns, gi_rebuilds);
    const sweep_us = us(sweep_ns_moving, 1);
    const rebuild_us = us(gi_rebuild_ns, gi_rebuilds);
    const other_us = @max(rebuild_us - raster_us - sdf_us - pyramid_us, 0);

    log("    per moving frame, each part measured rather than derived:", .{});
    log("      mask fill         {d:>8.2} us", .{raster_us});
    log("      shadow sweep      {d:>8.2} us   ({d} ray steps)", .{ sweep_us, sweep_steps_moving });
    log("      GI distance field {d:>8.2} us   (resample + transform)", .{sdf_us});
    log("      GI radiance pyramid {d:>6.2} us", .{pyramid_us});
    log("      unattributed      {d:>8.2} us   (gather, bookkeeping, allocation checks)", .{other_us});
    log("      whole rebuild frame {d:>6.2} us", .{rebuild_us});

    // The budget, as a comparison rather than a verdict on the machine.
    const cpu_budget_us: f64 = 1000.0 / 60.0; // one frame at 60 Hz, 16.67 ms
    const frame_us = us(total_ns, frames);
    log("  -> CPU lighting is {d:.1}% of a 60 Hz frame budget ({d:.2} us of {d:.2} us)", .{
        100.0 * frame_us / cpu_budget_us, frame_us, cpu_budget_us,
    });

    // Structural checks. These are the ones that exit non-zero.
    var failures: u32 = 0;
    // Per KIND, not just the total. A gather path that drops one component type
    // costs a fifth of the scene's light and no single count notices, which is
    // exactly how this demo first reported "15 gathered" while being the only
    // thing in the tree that ever checked.
    const want_by_kind = [4]u32{ 10, 5, 5, 1 }; // point (incl. legacy), spot, directional, ambient
    const kind_names = [4][]const u8{ "point", "spot", "directional", "ambient" };
    for (want_by_kind, 0..) |want, ki| {
        if (by_kind[ki] != want) {
            log("  FAIL: {s} lights: asked for {d}, gathered {d}", .{
                kind_names[ki], want, by_kind[ki],
            });
            failures += 1;
        }
    }
    if (drawn != lights_n + 1) {
        log("  FAIL: asked for {d} lights, the renderer took {d}", .{ lights_n + 1, drawn });
        failures += 1;
    }
    if (l.radiance == null) {
        log("  FAIL: GI is off. The scene asked for it and did not get it.", .{});
        failures += 1;
    }
    if (gi_rebuilds == 0) {
        log("  FAIL: the GI pyramid never rebuilt in {d} frames", .{frames});
        failures += 1;
    }
    if (null_backend.gi_uploads == 0) {
        log("  FAIL: the pyramid built but nothing reached the renderer. gi_dirty never fired.", .{});
        failures += 1;
    }
    if (l.stats.gi_not_prepared != 0) {
        log("  FAIL: {d} frames skipped GI because the pyramid was never sized for the mask", .{l.stats.gi_not_prepared});
        failures += 1;
    }
    if (sweep_steps_moving == 0) {
        log("  FAIL: the shadow sweep ran no ray steps on any moving frame. The mask is empty or the clock is not installed.", .{});
        failures += 1;
    }
    if (failures == 0) {
        log("  OK: 20 lights gathered, GI built, uploaded and amortized, the clock is real.", .{});
    }

    // Not measured here, stated rather than implied.
    log("  not measured here: the GPU half. The null backend takes the same", .{});
    log("  LightFrame and draws nothing, so the ROADMAP's 'GPU <= 6 ms on", .{});
    log("  iGPU' has no number from this run. The CPU number above is the", .{});
    log("  whole of what a headless machine can honestly say about M7.", .{});
    log("", .{});

    if (failures != 0) {
        std.process.exit(1);
    }
}

// ── M7: what the automatic occluder's shape costs, measured ──────────────────
//
// The ROADMAP says "automatic occluder SDFs". That is done: an automatic
// occluder now rasterizes the sprite's ALPHA COVERAGE instead of its rectangle,
// and the exact EDT over that mask IS the distance field of the silhouette.
//
// What this measures is the question that decides whether the OTHER reading is
// worth building: a per-sprite distance field, composited instead of rasterizing
// and transforming. If the field is already amortized behind the mask's dirty
// flag, a second representation is memory for a number nothing reads twice --
// and that is a claim, so it is timed rather than argued.

fn measureAutomatic(allocator: std.mem.Allocator) !void {
    const mask_side: u32 = 512;
    const world_side: f32 = 512;

    // A page of sprites, none of them a clean rectangle, because a fully opaque
    // sprite's silhouette is its rectangle and it registers nothing. Measuring
    // only opaque sprites would report the fast path for every project.
    const page_w: u32 = 256;
    const page_h: u32 = 256;
    var page: [page_w * page_h * 4]u8 = undefined;
    for (0..page_h) |y| {
        for (0..page_w) |x| {
            const p = (y * page_w + x) * 4;
            // A diagonal band with holes: nothing here is a rectangle.
            const band = @as(i32, @intCast(x)) - @as(i32, @intCast(y));
            page[p + 3] = if (@mod(band, 7) == 0) 0 else 255;
        }
    }

    var world = World.init(allocator);
    defer world.deinit();

    // 64 actors over two distinct rects, so the de-duplication is exercised
    // rather than the trivial one-rect case.
    var i: u16 = 0;
    while (i < 64) : (i += 1) {
        const col: f32 = @as(f32, @floatFromInt(i % 8)) * 64 + 32;
        const row: f32 = @as(f32, @floatFromInt(i / 8)) * 64 + 32;
        const u: f32 = @as(f32, @floatFromInt(i % 2)) * 0.5 + 0.02;
        _ = try world.spawn(.{
            components.Transform{ .position = .{ .x = col, .y = row } },
            components.Sprite{
                .size = .{ .x = 48, .y = 48 },
                .uv = .{ u, u, u + 0.46, u + 0.46 },
            },
            components.LightOccluder2D{ .mode = .auto_sdf, .alpha_threshold = 0.5 },
        });
    }

    var store = light.CoverageStore.init(allocator);
    defer store.deinit();

    // The loader cost, once per page.
    const load_t0 = monotonicNs();
    const report = try light.registerAtlasCoverage(&store, &world, &page, page_w, page_h, .{});
    const load_ns = monotonicNs() - load_t0;

    var l = try Lighting.init(allocator, .high);
    defer l.deinit();
    try l.resize(mask_side, mask_side);
    try l.reserve(128, 128);
    l.rect = .{ .min = .{ .x = 0, .y = 0 }, .max = .{ .x = world_side, .y = world_side } };
    l.coverage_store = &store;

    // Frames 1..N: an occluder moves every frame, so the mask is rebuilt every
    // frame. This is the WORST case for a rasterizer-based occluder and the only
    // honest number to quote.
    const frames: u32 = 30;
    var gather_ns: u64 = 0;
    var raster_ns: u64 = 0;
    var field_ns: u64 = 0;
    var f: u32 = 0;
    while (f < frames) : (f += 1) {
        var it = world.query(.{components.Transform});
        var e = it.next();
        var k: u32 = 0;
        while (e) |row| : (e = it.next()) {
            if (k == 0) row.get(components.Transform).position.x += 1;
            k += 1;
        }

        const t0 = monotonicNs();
        l.lock();
        l.collect(&world, l.rect);
        const t1 = monotonicNs();
        l.rasterize();
        const t2 = monotonicNs();
        _ = l.updateSdf(monotonicNs());
        const t3 = monotonicNs();
        gather_ns += t1 - t0;
        raster_ns += t2 - t1;
        field_ns += t3 - t2;
    }

    const us = struct {
        fn toUs(ns: u64, n: u32) f64 {
            return @as(f64, @floatFromInt(@divTrunc(ns, n))) / 1000.0;
        }
    }.toUs;

    // The field at several sizes, and the field alone. Both, because the first
    // says whether the cost is linear in the mask and the second attributes the
    // per-frame figure above instead of leaving it to be guessed at.
    for ([_]u32{ 64, 256, 512 }) |sz| {
        var m2 = try Lighting.init(allocator, .high);
        defer m2.deinit();
        m2.resize(sz, sz) catch {};
        const t0 = monotonicNs();
        const reps: u32 = if (sz <= 64) 40 else 8;
        for (0..reps) |_| light.edtMask2dInto(&m2.edt, m2.mask, m2.sdf, sz, sz);
        const per = @as(f64, @floatFromInt(@divTrunc(monotonicNs() - t0, reps))) / 1000.0;
        log("  field alone {d}x{d}:   {d:9.2} us   {d:.2} ns/cell", .{
            sz, sz, per, per * 1000.0 / @as(f64, @floatFromInt(@as(usize, sz) * sz)),
        });
    }

    const total = @max(gather_ns + raster_ns + field_ns, 1);
    log("", .{});
    log("automatic occluders -- alpha coverage vs the rectangle", .{});
    log("  page              {d}x{d}, {d} actors, {d} rects, {d} registered", .{
        page_w, page_h, 64, report.rects, report.registered,
    });
    log("  coverage bytes    {d} ({d:.1} KB)", .{
        report.bytes,
        @as(f64, @floatFromInt(report.bytes)) / 1024.0,
    });
    log("  loader, once      {d:.2} us  (per page, at import)", .{us(load_ns, 1)});
    log("  per FRAME, moving occluders -- the worst case:", .{});
    log("    collect         {d:9.2} us   {d:5.1}%", .{
        us(gather_ns, frames),
        100.0 * @as(f64, @floatFromInt(gather_ns)) / @as(f64, @floatFromInt(total)),
    });
    log("    rasterize       {d:9.2} us   {d:5.1}%", .{
        us(raster_ns, frames),
        100.0 * @as(f64, @floatFromInt(raster_ns)) / @as(f64, @floatFromInt(total)),
    });
    log("    distance field  {d:9.2} us   {d:5.1}%", .{
        us(field_ns, frames),
        100.0 * @as(f64, @floatFromInt(field_ns)) / @as(f64, @floatFromInt(total)),
    });
    log("  -> the rasterizer is a small share and the field is rebuilt only when", .{});
    log("     the mask changed, so both are amortized behind one dirty flag. A", .{});
    log("     per-sprite SDF would add a second representation of the same field", .{});
    log("     and cost its own memory; the profiling tools are what would tell", .{});
    log("     anyone whether to build it.", .{});
}
