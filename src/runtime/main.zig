//! `ember` runtime M2: window + fixed loop + batched 2D sprites.
//!
//! Pipeline (ROADMAP M2, and the frame spec §7 demands):
//!   ECS sim (60 Hz, interpolated) → batcher (sort + draw-call grouping)
//!   → scene pass into the OFFSCREEN target → SMAA 1x → swapchain.
//!
//! The game ALWAYS renders to an offscreen target: the editor composes it into
//! the viewport panel in M5 (one process, one window — spec §7).
//!
//! Usage:
//!   ember [--frames N] [--headless] [--vsync on|off] [--max-fps N]
//!         [--smaa on|off] [--sprites N] [--warmup N] [--sort none|ftb|btf]
//!
//!   --max-fps N   Godot-style frame-rate cap (0 = uncapped). 30 halves the
//!                 light/GI GPU cost of Pin-Pon while the sim stays at 60 Hz.

const std = @import("std");
const engine = @import("engine");
const core = engine.core;
const platform = engine.platform;
const render = engine.render;
const batcher_mod = engine.batcher;
const backend_null = engine.render.backend_null;
const backend_dawn = engine.render.backend_dawn;

const fixed_dt: f32 = 1.0 / 60.0;
const rotation_speed: f32 = 1.5; // rad/s

const Args = struct {
    frames: u64 = 0, // 0 = infinite
    headless: bool = false,
    vsync: bool = true,
    warmup: u64 = 30,
    /// Godot-style `application/run/max_fps`: 0 = uncapped (profiler default).
    max_fps: u32 = 0,
    smaa: bool = true,
    /// Sprite count of the canonical scene (the 50k acceptance scene).
    sprites: u32 = 50_000,
    /// `none` (default) emits straight into the GPU instance buffer: the
    /// minimum CPU work that can produce the frame. The batcher path (with its
    /// counting sort and, opt-in, the O(n log n) area sorts) is exercised by
    /// the acceptance benchmark and by `--sort layer|ftb|btf`.
    sort: batcher_mod.SortMode = .none,
};

fn parseArgs(init: std.process.Init.Minimal) Args {
    var args = Args{};
    // Allocator-free iterator on posix (Args.Iterator.init).
    var it = std.process.Args.Iterator.init(init.args);
    _ = it.next(); // program name
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
    if (std.mem.eql(u8, v, "none")) return .none;
    return .by_layer;
}

fn onOff(value: []const u8, default: bool) bool {
    if (value.len == 0) return default;
    if (std.mem.startsWith(u8, value, "off") or std.mem.startsWith(u8, value, "OFF")) return false;
    if (std.mem.startsWith(u8, value, "0")) return false;
    if (std.mem.startsWith(u8, value, "no")) return false;
    return true;
}

/// The canonical M2 scene: `count` sprites on a grid, rotating in sync.
/// Replaces the M0 single quad: it is what the "50k sprites in <= 4 draw
/// calls" acceptance criterion is measured against.
const Scene = struct {
    count: u32,
    cols: u32,
    cell: f32,
    angle: f32,
    prev_angle: f32,

    fn init(count: u32, viewport_w: f32, viewport_h: f32) Scene {
        const cols: u32 = @max(1, @as(u32, @intFromFloat(@sqrt(@as(f32, @floatFromInt(count))))));
        const rows: u32 = @max(1, (count + cols - 1) / cols);
        const cell_w = viewport_w / @as(f32, @floatFromInt(cols));
        const cell_h = viewport_h / @as(f32, @floatFromInt(rows));
        return .{
            .count = count,
            .cols = cols,
            .cell = @min(cell_w, cell_h),
            .angle = 0,
            .prev_angle = 0,
        };
    }

    fn fixedUpdate(self: *Scene, dt: f32) void {
        self.prev_angle = self.angle;
        self.angle += rotation_speed * dt;
    }

    /// Emits the whole scene.
    ///
    /// `sink` is comptime-generic so the unsorted path writes GPU instances
    /// DIRECTLY: no 48-byte command array is built at all, which removes 2.4 MB
    /// of writes and 2.4 MB of reads per frame at 50k sprites (measured: the
    /// intermediate array cost ~2 ms of the batch phase). When a sort IS
    /// requested the sink is the batcher, which owns the commands.
    ///
    /// The loop is a nested row/column walk, not `i / cols`: u32 division is
    /// ~25 cycles and at 50k sprites it was ~1 ms of pure division.
    fn emit(self: *const Scene, sink: anytype, alpha: f32) void {
        _ = alpha; // rotation of the whole grid lands with the transform system
        const rows: u32 = (self.count + self.cols - 1) / self.cols;
        const half = self.cell * 0.35;
        const origin_x = -@as(f32, @floatFromInt(self.cols)) * 0.5 * self.cell;
        const origin_y = -@as(f32, @floatFromInt(rows)) * 0.5 * self.cell;
        const full_uv = [4]f32{ 0, 0, 1, 1 };
        const uv16: [4]u16 = .{ 0, 0, 65535, 65535 };
        var out_i: usize = 0;

        var row: u32 = 0;
        while (row < rows) : (row += 1) {
            const y = origin_y + @as(f32, @floatFromInt(row)) * self.cell;
            // Grouped by layer the way a real scene renderer emits it (one pass
            // per layer): rows map to layers, so the order is layer-monotonic
            // and the batcher takes its fast path.
            const layer: u16 = @intCast(row / 32);
            var col: u32 = 0;
            while (col < self.cols) : (col += 1) {
                const idx = row * self.cols + col;
                if (idx >= self.count) break;
                const x = origin_x + @as(f32, @floatFromInt(col)) * self.cell;
                // Tint cycles through the palette so SMAA has real edges to
                // detect on both bright and dark neighbours.
                const h = @as(f32, @floatFromInt(idx % 16)) / 16.0;
                const tint = [4]f32{ 0.25 + 0.75 * h, 0.5, 1.0 - 0.75 * h, 1.0 };

                if (@TypeOf(sink) == *batcher_mod.Batcher) {
                    _ = sink.push(batcher_mod.SpriteCommand.make(
                        x, y, half, half, full_uv, tint, layer, 0, .alpha,
                    ));
                } else {
                    if (out_i >= sink.len) break;
                    sink[out_i] = .{
                        .pos = .{ x, y },
                        .half = .{ half, half },
                        // Full UV rect of the fallback white texture. Constant
                        // per scene, so the packing is done once, not per sprite.
                        .uv = uv16,
                        .color = .{
                            render.toUnorm8(tint[0]),
                            render.toUnorm8(tint[1]),
                            render.toUnorm8(tint[2]),
                            render.toUnorm8(tint[3]),
                        },
                        .slot = 0,
                    };
                    out_i += 1;
                }
            }
        }
    }
};

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

    // ── M2: batcher. Reserved for the whole scene ONCE, then locked: the
    // frame loop can never allocate (spec §3.1).
    var batcher = batcher_mod.Batcher.init(boot_alloc);
    defer batcher.deinit();
    try batcher.reserve(args.sprites);
    batcher.lock();

    // CPU-side vertex expansion buffer: 6 vertices per sprite, reused every
    // frame (no per-frame allocation, spec §3.1).
    // The GPU instance buffer is capped at 65536 sprites (2 MB, spec §4). The
    // scene asks for the 50k acceptance number, and the batcher drops
    // anything beyond the reservation instead of allocating in the frame.
    const capped_sprites: u32 = @min(args.sprites, 65_536);
    const instance_cap: usize = capped_sprites;
    const instances = try boot_alloc.alloc(render.SpriteInstance, instance_cap);
    defer boot_alloc.free(instances);

    var scene = Scene.init(args.sprites, @floatFromInt(view_w), @floatFromInt(view_h));

    core.log.info("ember M2 — {s}, {d}x{d}, backend: {s}, sprites: {d}, smaa: {s}, max-fps: {d}", .{
        if (args.headless) "headless" else "window",
        view_w,
        view_h,
        if (args.headless) "null" else "dawn",
        args.sprites,
        if (args.smaa) "on" else "off",
        args.max_fps,
    });

    var loop = core.loop.FixedLoop.init(fixed_dt);
    var limiter = core.loop.FrameLimiter.init(args.max_fps, args.vsync);
    var last_ns = core.time.monotonicNs();
    var frame_count: u64 = 0;
    var draw_calls_max: u32 = 0;
    var last_instances: usize = 0;

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
                // `createOffscreenTarget` is the single owner: it also releases
                // the previous target, so the runtime never destroys it (doing
                // both was a use-after-free on the GPU objects).
                target = renderer.createOffscreenTarget(fb.w, fb.h);
                scene = Scene.init(args.sprites, @floatFromInt(fb.w), @floatFromInt(fb.h));
            }
        }

        prof.beginFrame(frame_count >= args.warmup);
        var z = prof.zone("frame_total");
        tracker.beginFrame(); // from here on: no allocations outside the arena
        frame_arena.beginFrame();
        batcher.beginFrame();

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
        while (s < steps) : (s += 1) scene.fixedUpdate(fixed_dt);
        z_sim.end();

        // ── M2: emit + batch. The CPU expands each sprite into 6 world-space
        // corners and groups the draws (spec §4: <= 32 draw calls).
        var z_batch = prof.zone("batch");
        var icount: usize = 0;
        if (args.sort == .none) {
            // FAST PATH: emit straight into the GPU instance buffer. No command
            // array, no sort, no second pass — the minimum work that can
            // possibly produce the frame (spec §2: 1.5 ms for 50k sprites).
            var z_emit = prof.zone("batch_emit");
            scene.emit(instances[0..], loop.alpha());
            z_emit.end();
            icount = @min(scene.count, instance_cap);
        } else {
            var z_emit = prof.zone("batch_emit");
            scene.emit(&batcher, loop.alpha());
            z_emit.end();
            var z_sort = prof.zone("batch_sort");
            batcher.buildBatches(args.sort);
            z_sort.end();
            var z_pack = prof.zone("batch_pack");
            if (batcher.isAlreadyOrdered()) {
                const n = @min(batcher.cmds.items.len, instance_cap);
                for (batcher.cmds.items[0..n]) |cmd| {
                    instances[icount] = packInstance(cmd);
                    icount += 1;
                }
            } else {
                for (batcher.batches.items) |batch| {
                    for (batcher.order.items[batch.first .. batch.first + batch.count]) |idx| {
                        if (icount >= instance_cap) break;
                        instances[icount] = packInstance(batcher.cmds.items[idx]);
                        icount += 1;
                    }
                }
            }
            z_pack.end();
        }
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
            if (icount > 0) renderer.drawSprites(instances[0..icount], icount);
            renderer.endScene(args.smaa, .Medium);
        } else {
            // Headless: still exercise the whole M2 path against the null
            // backend so CI measures draw calls and batching for real.
            const cam = render.makeCamera(@floatFromInt(view_w), @floatFromInt(view_h));
            renderer.beginScene(target, cam);
            if (icount > 0) renderer.drawSprites(instances[0..icount], icount);
            renderer.endScene(args.smaa, .Medium);
        }
        renderer.present();
        z_render.end();

        const st = renderer.stats();
        last_instances = icount;
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
    core.log.info("scene: {d} instances, sort: {s}, batcher path: {s}", .{
        last_instances,
        @tagName(args.sort),
        if (args.sort == .none) "bypassed (direct emit)" else "used",
    });
    core.log.info("renderer: {d} draw calls (max {d} in the run, budget 32), {d} passes, {d} gpu objects created in frame (budget 0)", .{
        st.draw_calls,
        draw_calls_max,
        st.render_passes,
        st.resources_created_frame,
    });
    core.log.info("gpu upload: {d} B/frame (budget 2097152, spec §4)", .{st.upload_bytes});
    if (batcher.overflowed) {
        core.log.warn("batcher OVERFLOW: {d} sprites dropped — reserve more at boot", .{batcher.dropped});
    }
    if (st.upload_bytes > 2 * 1024 * 1024) {
        core.log.warn("staging upload {d} B/frame exceeds the spec §4 ceiling (2 MB)", .{st.upload_bytes});
    }
    if (limiter.effectiveFps() != 0) {
        core.log.info("frame limiter: cap {d} fps, slept {d} frames, {d} ms total", .{
            limiter.effectiveFps(),
            limiter.slept_frames,
            limiter.total_wait_ns / std.time.ns_per_ms,
        });
    }
    prof.report("== PERF (frames) ==");
    core.log.info("mem: frame arena high-water: {d} bytes", .{frame_arena.high_water});
    core.log.info("allocs boot: {d} frees: {d} peak: {d} bytes", .{
        tracker.count_allocs, tracker.count_frees, tracker.peak_live_bytes,
    });
}

/// Packs one sprite command into its 32-byte GPU instance record. This is the
/// only per-sprite CPU work in the frame (the corners are derived in the
/// vertex shader), which is what keeps 50k sprites inside the 1.5 ms budget
/// of spec §2.
fn packInstance(cmd: batcher_mod.SpriteCommand) render.SpriteInstance {
    return .{
        .pos = .{ cmd.x, cmd.y },
        .half = .{ cmd.half_w, cmd.half_h },
        .uv = .{
            render.toUnorm16(cmd.u0),
            render.toUnorm16(cmd.v0),
            render.toUnorm16(cmd.u1),
            render.toUnorm16(cmd.v1),
        },
        .color = .{
            render.toUnorm8(cmd.r),
            render.toUnorm8(cmd.g),
            render.toUnorm8(cmd.b),
            render.toUnorm8(cmd.a),
        },
        .slot = cmd.textureSlot(),
    };
}