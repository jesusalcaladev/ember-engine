//! `ember` runtime M2: window + fixed loop + ECS-driven batched 2D sprites.
//!
//! Pipeline (ROADMAP M2, and the frame spec §7 demands):
//!   ECS sim (60 Hz, interpolated) → render2d system → offscreen target → SMAA 1x → swapchain.
//!
//! The game ALWAYS renders to an offscreen target: the editor composes it into
//! the viewport panel in M5 (one process, one window — spec §7).
//!
//! Usage:
//!   ember [--frames N] [--headless] [--vsync on|off] [--smaa on|off]
//!         [--max-fps N] [--sprites N] [--warmup N] [--sort none|layer|ftb|btf]

const std = @import("std");
const engine = @import("engine");
const core = engine.core;
const platform = engine.platform;
const render = engine.render;
const render2d = engine.render2d;
/// M7: the lighting driver. The one owner of the mask, the shadow channels and
/// the GI pyramid — see the note where it is constructed.
const lighting_driver = engine.lighting_driver;
const batcher_mod = engine.batcher;
const backend_null = engine.render.backend_null;
const backend_dawn = engine.render.backend_dawn;
const ecs = engine.ecs;
const script = engine.script;
const components = ecs.components;
const log = core.log.scoped("runtime");

const fixed_dt: f32 = 1.0 / 60.0;
const rotation_speed: f32 = 1.5; // rad/s

const Args = struct {
    frames: u64 = 0, // 0 = infinite
    headless: bool = false,
    vsync: bool = true,
    warmup: u64 = 30,
    max_fps: u32 = 0,
    smaa: bool = true,
    sprites: u32 = 50_000,
    sort: batcher_mod.SortMode = .none,
};

fn parseArgs(init: std.process.Init.Minimal) Args {
    var args = Args{};
    var it = std.process.Args.Iterator.init(init.args);
    _ = it.next();
    while (it.next()) |arg| {
        if (std.mem.eql(u8, arg, "--frames")) {
            if (it.next()) |n| args.frames = std.fmt.parseInt(u64, n, 10) catch 0;
        } else if (std.mem.eql(u8, arg, "--headless")) {
            args.headless = true;
        } else if (std.mem.eql(u8, arg, "--vsync")) {
            if (it.next()) |v| args.vsync = onOff(v, true);
        } else if (std.mem.eql(u8, arg, "--warmup")) {
            if (it.next()) |n| args.warmup = std.fmt.parseInt(u64, n, 10) catch 30;
        } else if (std.mem.eql(u8, arg, "--max-fps")) {
            if (it.next()) |n| args.max_fps = std.fmt.parseInt(u32, n, 10) catch 0;
        } else if (std.mem.eql(u8, arg, "--smaa")) {
            if (it.next()) |v| args.smaa = onOff(v, true);
        } else if (std.mem.eql(u8, arg, "--sprites")) {
            if (it.next()) |n| args.sprites = std.fmt.parseInt(u32, n, 10) catch 50_000;
        } else if (std.mem.eql(u8, arg, "--sort")) {
            if (it.next()) |v| args.sort = parseSort(v);
        }
    }
    return args;
}

fn parseSort(v: []const u8) batcher_mod.SortMode {
    if (std.mem.eql(u8, v, "ftb")) return .front_to_back;
    if (std.mem.eql(u8, v, "btf")) return .back_to_front;
    if (std.mem.eql(u8, v, "layer")) return .by_layer;
    return .none;
}

fn onOff(value: []const u8, default: bool) bool {
    if (value.len == 0) return default;
    if (std.mem.startsWith(u8, value, "off") or std.mem.startsWith(u8, value, "OFF")) return false;
    if (std.mem.startsWith(u8, value, "0")) return false;
    if (std.mem.startsWith(u8, value, "no")) return false;
    return true;
}

/// The camera the scene is DRAWN with this frame (M4.5).
///
/// The M4.5 `Camera2D` view when the scene has one — which is the only case in
/// which a follow, a zoom or a shake is visible at all — and otherwise the plain
/// centred orthographic camera M2 used before cameras existed.
///
/// This closes the loop the culler alone does not: `collectFiltered` decides
/// WHAT is worth drawing and this decides WHERE it lands. If those two read
/// different cameras, sprites get culled for a view they are then drawn outside
/// of (invisible but paid for), which is the failure this pairing exists to make
/// impossible.
fn sceneCamera(view: ?ecs.camera.View, width: u32, height: u32) render.Camera {
    const v = view orelse return render.makeCamera(@floatFromInt(width), @floatFromInt(height));
    return render.makeCameraCustom(
        v.viewProjection(),
        0,
        0,
        width,
        height,
    );
}

pub fn main(init: std.process.Init.Minimal) !void {
    const args = parseArgs(init);

    // Allocators (boot-time): tracked over c_allocator. The frame uses ONLY
    // the frame arena (spec §3.1).
    var tracker = core.tracker.TrackedAllocator{ .child = std.heap.c_allocator };
    const boot_alloc = tracker.allocator();

    var frame_arena = try core.arena.FrameArena.init(boot_alloc, 8 * 1024 * 1024);
    defer frame_arena.deinit(boot_alloc);

    var prof = core.profiler.Profiler{};

    // Window (or headless for CI). Non-optional + flag: the user-pointer of
    // the callback points at this stable address in main.
    var window: platform.Window = undefined;
    var has_window = false;
    if (!args.headless) {
        try platform.init();
        errdefer platform.deinit();
        window = try platform.Window.create(.{});
        has_window = true;
        platform.setUserPointer(window.handle, &window);
    }
    defer {
        if (has_window) window.destroy();
        if (!args.headless) platform.deinit();
    }

    // Renderer: Dawn with a window, null in headless mode.
    var null_backend = backend_null.Backend{};
    var renderer: render.Renderer = undefined;
    if (args.headless) {
        renderer = null_backend.renderer();
    } else {
        const dawn = try backend_dawn.Backend.create(
            boot_alloc,
            window.nativeHandle(),
            window.fb_width,
            window.fb_height,
            backend_dawn.Options{
                .vsync = args.vsync,
                .smaa = args.smaa,
                .max_sprites = args.sprites,
            },
        );
        renderer = dawn.renderer();
    }
    defer renderer.deinit();

    // ── M2: offscreen target (the game NEVER draws straight to the swapchain)
    const view_w: u32 = if (has_window) window.fb_width else 1280;
    const view_h: u32 = if (has_window) window.fb_height else 720;
    var target = renderer.createOffscreenTarget(view_w, view_h);

    // ── ECS World: the source of truth for the scene.
    var world = ecs.World.init(boot_alloc);
    defer world.deinit();
    try world.reserveEntities(args.sprites);
    try world.reserve(.{ components.Transform, components.Sprite }, args.sprites);
    try world.enableHierarchy();

    // ── M3: LuaJIT VM + the Behaviors system (Actor + Components + script).
    // `Behaviors.init` builds its own Vm, installs the sandboxed API over the
    // Context (world + input) and owns the script cache, so there is no
    // separate registration step to forget.
    var input_state = script.Input{};
    input_state.define("move_left");
    input_state.define("move_right");
    input_state.define("jump");

    var behaviors: script.Behaviors = undefined;
    try behaviors.init(boot_alloc, &world, &input_state);
    defer behaviors.deinit();
    try behaviors.reserve(args.sprites);
    behaviors.lock();

    // A script that drives the actor's transform: this is the M3 acceptance
    // path (Lua -> binding -> ECS), attached to the first sprite so the grid
    // visibly moves through scripted gameplay.
    const spin_src =
        \\local M = {}
        \\function M:start()
        \\  self.total = 0
        \\end
        \\function M:update(dt)
        \\  self.total = self.total + dt
        \\  local x, y = actor.get_position(self)
        \\  x = x + math.sin(self.total) * 40 * dt
        \\  actor.set_position(self, x, y)
        \\end
        \\return M
    ;
    const spin_id = try behaviors.load("spin.lua", spin_src);

    // Spawn the canonical scene: a grid of sprites, one per cell.
    const capped_sprites: u32 = @min(args.sprites, 65_536);
    const rows: u32 = @max(1, (capped_sprites + 1) / 2); // ~square grid
    const cols: u32 = @max(1, (capped_sprites + rows - 1) / rows);
    const cell_w: f32 = @as(f32, @floatFromInt(view_w)) / @as(f32, @floatFromInt(cols));
    const cell_h: f32 = @as(f32, @floatFromInt(view_h)) / @as(f32, @floatFromInt(rows));
    const cell = @min(cell_w, cell_h);

    var i: u32 = 0;
    var row: u32 = 0;
    while (row < capped_sprites / cols + 1) : (row += 1) {
        var col: u32 = 0;
        while (col < cols) : (col += 1) {
            if (i >= capped_sprites) break;
            const x = (@as(f32, @floatFromInt(col)) - @as(f32, @floatFromInt(cols)) * 0.5) * cell;
            const y = (@as(f32, @floatFromInt(row)) - @as(f32, @floatFromInt(capped_sprites / cols + 1)) * 0.5) * cell;
            const half = cell * 0.35;
            const h = @as(f32, @floatFromInt(i % 16)) / 16.0;
            const tint = [4]f32{ 0.25 + 0.75 * h, 0.5, 1.0 - 0.75 * h, 1.0 };

            const e = try world.spawn(.{
                components.Transform{
                    .position = .{ .x = x, .y = y },
                    .scale = .{ .x = 1.0, .y = 1.0 },
                },
                components.Sprite{
                    .size = .{ .x = half * 2.0, .y = half * 2.0 },
                    .uv = .{ 0, 0, 1, 1 },
                    .tint = tint,
                    .layer = @as(u16, @intCast(row)),
                    .blend = components.Blend.alpha,
                    .visible = true,
                },
            });
            // The first actor also carries the Lua behavior: the grid renders,
            // and one of them is gameplay-driven.
            if (i == 0) try behaviors.attach(e, spin_id);
            i += 1;
        }
    }
    behaviors.startAll();

    // ── M2: render2d system (ECS → GPU instances)
    var r2d = render2d.Renderer2D.init(boot_alloc);

    // ── M7: lighting. Owns the mask, the shadow channels and the GI pyramid.
    //
    // `scale` is world units per mask texel: 1 means the mask is the size of the
    // view in pixels, which is also what makes the shadow sweep's step length
    // half a texel. Halving it doubles the mask along each axis and quarters the
    // angle a shadow map's bucket covers, which is the quality dial the whole
    // system turns on.
    var lighting = lighting_driver.Driver.init(boot_alloc, .medium) catch |err| {
        log.err("lighting init failed: {s} — the scene renders unlit", .{@errorName(err)});
        return err;
    };
    defer lighting.deinit();
    // A budget rather than a count taken from the world: `collect` appends
    // without capacity checks, and a scene that grows past this CLIPS rather
    // than allocating in the middle of a frame. Reported, not silent.
    const lighting_budget = .{ .lights = 256, .occluders = 512 };
    var lighting_drawn: usize = 0;
    var lighting_env: render.SceneEnvironment = .{};
    var frame_index: i128 = 0;
    defer r2d.deinit();
    try r2d.reserve(args.sprites);
    r2d.options.sort = args.sort;
    r2d.lock();

    var loop = core.loop.FixedLoop.init(fixed_dt);
    var limiter = core.loop.FrameLimiter.init(args.max_fps, args.vsync);
    var last_ns = core.time.monotonicNs();
    var frame_count: u64 = 0;
    var draw_calls_max: u32 = 0;

    // ── M4.5: the Timer → Lua signal bridge.
    // `Behaviors.dispatchSignal` broadcasts to every `on_signal`, and the timer
    // system needs to reach it through an erased callback because the ECS must
    // not import the script layer. One shim function carries the pointer; there
    // is exactly one Behaviors in this process.
    const timer_bridge = ecs.timer.SignalBridge{
        .ctx = &behaviors,
        .dispatch = struct {
            fn fire(ctx: ?*anyopaque, name: []const u8) void {
                const b: *script.Behaviors = @ptrCast(@alignCast(ctx.?));
                b.dispatchSignal(name);
            }
        }.fire,
    };

    // ── M4.5: the camera's view, kept between frames.
    // `null` means the scene has no enabled Camera2D, and that is not an error:
    // the culler then draws everything, exactly as it did before M4.5.
    var camera_view: ?ecs.camera.View = null;

    while (true) {
        // ── Frame limiter (Godot-style). Runs BEFORE the frame so the pacing
        // wait is not counted as engine work.
        const pacing = limiter.wait(core.time.monotonicNs());
        limiter.sleep(pacing.wait_ns);

        // ── Resize handling, OUTSIDE the forbidden zone. Building the
        // offscreen target creates GPU objects and allocates, and spec §3.6
        // forbids both inside a frame: the loop may only USE a target.
        if (has_window) {
            const fb = window.framebufferSize();
            if (window.resized or target.width != fb.w or target.height != fb.h) {
                window.resized = false;
                renderer.resize(fb.w, fb.h);
                target = renderer.createOffscreenTarget(fb.w, fb.h);
            }
        }

        prof.beginFrame(frame_count >= args.warmup);
        var z = prof.zone("frame_total");
        tracker.beginFrame(); // from here on: no allocations outside the arena
        frame_arena.beginFrame();

        // Input
        var z_input = prof.zone("input");
        if (has_window) {
            window.poll();
            if (window.shouldClose()) break;
        }
        z_input.end();

        // Fixed-timestep simulation
        const now_ns = core.time.monotonicNs();
        const frame_ns = now_ns - last_ns;
        last_ns = now_ns;
        const real_dt: f32 = @as(f32, @floatFromInt(frame_ns)) / std.time.ns_per_s;
        var z_sim = prof.zone("fixed_update");
        const steps = loop.addTime(real_dt);
        var s: u32 = 0;
        while (s < steps) : (s += 1) {
            // ── M4.5: the Timer system, BEFORE the behaviors run.
            // That order is the contract a scripted timer depends on: a
            // behavior's `fixed_update` observes exactly the signals its own
            // timers fired THIS tick, not the ones from the previous one. The
            // bridge forwards the fired names to Lua `on_signal`, which the
            // typed bus cannot reach by itself.
            ecs.timer.tick(&world, fixed_dt, timer_bridge);
            // M3: behaviors run at the fixed 60 Hz tick. `startAll` already ran,
            // so this is the gameplay itself: Lua -> actor.* bindings -> ECS.
            behaviors.fixedUpdate(fixed_dt);
        }
        // ── M4.5: the Camera2D system, once per fixed window (not per step).
        // The camera is what the player LOOKS at, so it belongs to the rendered
        // frame, and stepping it once per sub-step would advance follow and
        // decay trauma at 2x on a 120 Hz display for the same motion.
        camera_view = ecs.camera.update(
            &world,
            fixed_dt * @as(f32, @floatFromInt(steps)),
            @floatFromInt(view_w),
            @floatFromInt(view_h),
        );
        z_sim.end();

        // M3: the scripted per-frame update (decoupled from the fixed step, like
        // the renderer) plus the incremental GC step. spec §3.2 budgets that GC
        // step at ≤ 0.4 ms/frame; `vm.gcStep()` measures nothing, so the frame
        // cost lands in `script_update` where the budget gate can see it.
        var z_script = prof.zone("script_update");
        behaviors.update(real_dt);
        behaviors.sweepDestroyed();
        behaviors.vm.gcStep();
        z_script.end();

        // ── M2: ECS → GPU instances via render2d.
        var z_batch = prof.zone("batch");
        // The camera's view, translated from `camera.View` into the renderer's
        // `ViewRect`. The margin is the sprite-extent insurance the culler asks
        // for: a sprite walking right must not pop out one frame before it is
        // actually on screen. Without a camera the view is null and the culler
        // draws everything — the pre-M4.5 behaviour, unchanged.
        r2d.collectFiltered(
            &world,
            loop.alpha(),
            if (camera_view) |v| render2d.ViewRect.around(
                v.cx,
                v.cy,
                v.viewport_w / v.zoom * 0.5,
                v.viewport_h / v.zoom * 0.5,
                64,
            ) else null,
            null,
        );
        z_batch.end();

        // ── M2: render into the offscreen target, SMAA, compose to swapchain.
        var z_render = prof.zone("render");
        // Counter reset + publish the GPU timestamps resolved 2 frames ago,
        // then acquire the swapchain texture. With a Fifo present mode the
        // acquire is where the frame blocks for the display, so it stays its
        // own call and the profiler can time it apart from the encoding.
        renderer.beginFrame();
        if (has_window) renderer.acquireSurface();

        // The Environment is read every frame because a script can change it
        // mid-run, and reading it is two field loads. The sky follows it, since
        // the GI cascades measure against whatever the sky is right now.
        lighting_env = lighting_driver.Driver.environmentOf(&world, .{});
        lighting.sky = lighting_env.sky;

        // ── M7: the lighting driver. One owner, one call, one place.
        //
        // The driver is what makes a `PointLight2D` in a scene actually light
        // that scene: it owns the `Lighting`, sizes its mask to the view, gathers
        // the lights, rasterizes the occluders, sweeps the shadow channels,
        // rebuilds the GI pyramid when the field moved, and hands the lot to the
        // renderer. Every one of those steps existed and none of them was called.
        //
        // `resize` is here rather than in the setup because the mask follows the
        // view, and the view follows the camera. It is a no-op when the view has
        // not changed, and it only reports `needs_resize` on the frame it did.
        // Two integers rather than a struct. Zig's anonymous struct types are
        // NOMINAL: `Window.framebufferSize`'s result is a different type from an
        // equally-shaped literal, so an `if` that produced one or the other does
        // not type-check however alike they look. Two scalars are the shape that
        // a conditional expression can actually produce.
        const fb_w: u32 = if (has_window) window.framebufferSize().w else view_w;
        const fb_h: u32 = if (has_window) window.framebufferSize().h else view_h;
        lighting.resize(lighting_driver.Driver.viewFor(camera_view, fb_w, fb_h)) catch |err| log.warn("lighting mask resize failed: {s}", .{@errorName(err)});
        if (lighting.needs_resize) {
            // A precondition, not a hint: `collect` appends without capacity
            // checks because allocating mid-frame is forbidden (spec §3.1).
            lighting.lighting.reserve(lighting_budget.lights, lighting_budget.occluders) catch {};
        }

        if (has_window) {
            const fb = window.framebufferSize();
            renderer.beginScene(target, sceneCamera(camera_view, fb.w, fb.h));
            r2d.submit(renderer);
            lighting_drawn = lighting.render(&world, &r2d, renderer, lighting_env, frame_index);
            renderer.endScene(args.smaa, .Medium);
        } else {
            // Headless: still exercise the whole M2 path against the null
            // backend so CI measures draw calls and batching for real.
            renderer.beginScene(target, sceneCamera(camera_view, view_w, view_h));
            r2d.submit(renderer);
            lighting_drawn = lighting.render(&world, &r2d, renderer, lighting_env, frame_index);
            renderer.endScene(args.smaa, .Medium);
        }
        renderer.present();
        z_render.end();

        const st = renderer.stats();
        if (st.draw_calls > draw_calls_max) draw_calls_max = @intCast(st.draw_calls);

        frame_arena.endFrame();
        tracker.endFrame(); // end of the forbidden zone
        z.end(); // close the zone that wraps the frame
        prof.endFrame(); // records duration and drains zones
        if (has_window) window.input.endFrame();

        frame_index += 1;
        frame_count += 1;
        if (args.frames != 0 and frame_count >= args.frames) break;
    }

    // ── Acceptance report (M2)
    const st = renderer.stats();
    core.log.info("frames rendered: {d}", .{frame_count});
    core.log.info("batcher: {d} sprites -> {d} draw calls this frame (max {d} in the run), budget 32", .{
        0, // TODO: expose from r2d
        draw_calls_max,
        draw_calls_max,
    });
    core.log.info("renderer: {d} draw calls, {d} passes, {d} gpu objects created in frame (budget 0)", .{
        st.draw_calls,
        st.render_passes,
        st.resources_created_frame,
    });
    // M7: the numbers that say whether lighting is doing anything at all. A
    // scene reporting zero lights and zero post passes is a scene with no lights
    // in it OR a scene whose lights were never gathered, and those two look
    // identical from the outside — so both are printed.
    core.log.info("lighting: {d} lights in the last frame, {d} post passes", .{
        lighting_drawn,
        st.post_passes,
    });
    core.log.info("  occluders {d}, shadow channels {d}/{d} granted, shadow rays/frame {d}", .{
        lighting.lighting.stats.occluders,
        lighting.lighting.stats.shadow_lights,
        lighting.lighting.cfg.shadowLights(),
        lighting.lighting.stats.sweep_steps,
    });
    core.log.info("gpu upload: {d} B/frame (budget 2097152, spec §4)", .{st.upload_bytes});
    if (st.upload_bytes > 2 * 1024 * 1024) {
        core.log.warn("staging upload {d} B/frame exceeds the spec §4 ceiling (2 MB)", .{st.upload_bytes});
    }
    prof.report("== PERF (frames) ==");
    core.log.info("mem: frame arena high-water: {d} bytes", .{frame_arena.high_water});
    core.log.info("allocs boot: {d} frees: {d} peak: {d} bytes", .{
        tracker.count_allocs, tracker.count_frees, tracker.peak_live_bytes,
    });
}
