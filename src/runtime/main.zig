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
const batcher_mod = engine.batcher;
const backend_null = engine.render.backend_null;
const backend_dawn = engine.render.backend_dawn;
const ecs = engine.ecs;
const script = engine.script;
const components = ecs.components;

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
    defer r2d.deinit();
    try r2d.reserve(args.sprites);
    r2d.options.sort = args.sort;
    r2d.lock();


    var loop = core.loop.FixedLoop.init(fixed_dt);
    var limiter = core.loop.FrameLimiter.init(args.max_fps, args.vsync);
    var last_ns = core.time.monotonicNs();
    var frame_count: u64 = 0;
    var draw_calls_max: u32 = 0;

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
            // M3: behaviors run at the fixed 60 Hz tick. `startAll` already ran,
            // so this is the gameplay itself: Lua -> actor.* bindings -> ECS.
            behaviors.fixedUpdate(fixed_dt);
        }
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
        r2d.collect(&world, loop.alpha());
        z_batch.end();

        // ── M2: render into the offscreen target, SMAA, compose to swapchain.
        var z_render = prof.zone("render");
        // Counter reset + publish the GPU timestamps resolved 2 frames ago,
        // then acquire the swapchain texture. With a Fifo present mode the
        // acquire is where the frame blocks for the display, so it stays its
        // own call and the profiler can time it apart from the encoding.
        renderer.beginFrame();
        if (has_window) renderer.acquireSurface();
        if (has_window) {
            const fb = window.framebufferSize();
            const cam = render.makeCamera(@floatFromInt(fb.w), @floatFromInt(fb.h));
            renderer.beginScene(target, cam);
            r2d.submit(renderer);
            renderer.endScene(args.smaa, .Medium);
        } else {
            // Headless: still exercise the whole M2 path against the null
            // backend so CI measures draw calls and batching for real.
            const cam = render.makeCamera(@floatFromInt(view_w), @floatFromInt(view_h));
            renderer.beginScene(target, cam);
            r2d.submit(renderer);
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