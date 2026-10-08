//! `ember` runtime M0: window + fixed-timestep loop + animated quad.
//!
//! Acceptance criteria (ROADMAP M0):
//! - Animated quad at 60 FPS (vsync).
//! - Frame times p50/p99 logged on exit.
//! - Zero allocations in the frame loop (tracker assert in debug).
//!
//! Usage: ember [--frames N] [--headless]
//!   --frames N   exit after N frames (CI/measurable demo)
//!   --headless   no window (null backend; CI without display)

const std = @import("std");
const engine = @import("engine");
const core = engine.core;
const platform = engine.platform;
const render = engine.render;
const backend_null = engine.render.backend_null;
const backend_dawn = engine.render.backend_dawn;

const fixed_dt: f32 = 1.0 / 60.0;
const rotation_speed: f32 = 1.5; // rad/s

const Args = struct {
    frames: u64 = 0, // 0 = infinite
    headless: bool = false,
    vsync: bool = true,
    warmup: u64 = 30,
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
        }
    }
    return args;
}

fn onOff(value: []const u8, default: bool) bool {
    if (value.len == 0) return default;
    if (std.mem.startsWith(u8, value, "off") or std.mem.startsWith(u8, value, "OFF")) return false;
    if (std.mem.startsWith(u8, value, "0")) return false;
    if (std.mem.startsWith(u8, value, "no")) return false;
    return true;
}

const GameState = struct {
    angle: f32 = 0,
    prev_angle: f32 = 0,

    fn fixedUpdate(self: *GameState, dt: f32) void {
        self.prev_angle = self.angle;
        self.angle += rotation_speed * dt;
    }

    /// Interpolated angle for render (spec §3.3: interpolation required).
    fn renderAngle(self: *const GameState, alpha: f32) f32 {
        return core.math.lerpF(self.prev_angle, self.angle, alpha);
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
            backend_dawn.Options{ .vsync = args.vsync },
        );
        renderer = dawn.renderer();
    }
    defer renderer.deinit();

    core.log.info("ember M0 — {s}, {d}x{d}, backend: {s}", .{
        if (args.headless) "headless" else "window",
        if (has_window) window.fb_width else 0,
        if (has_window) window.fb_height else 0,
        if (args.headless) "null" else "dawn",
    });

    var state = GameState{};
    var loop = core.loop.FixedLoop.init(fixed_dt);
    var last_ns = core.time.monotonicNs();
    var frame_count: u64 = 0;

    while (true) {
        const measuring = frame_count >= args.warmup;
        prof.beginFrame(measuring); // marks the start of the frame for the time ring
        var z = prof.zone("frame_total"); // no defer: closed BEFORE endFrame
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
        while (s < steps) : (s += 1) state.fixedUpdate(fixed_dt);
        z_sim.end();

        // Render (interpolated)
        var z_render = prof.zone("render");
        if (has_window) {
            if (window.resized) {
                window.resized = false;
                renderer.resize(window.fb_width, window.fb_height);
            }
            const fb = window.framebufferSize();
            const cx: f32 = @floatFromInt(fb.w / 2);
            const cy: f32 = @floatFromInt(fb.h / 2);
            // model = translate(center) * rotateZ * scale(240 px): the unit
            // quad lives in pixel space, so it must be scaled to be visible.
            const view = core.math.Mat4.orthoPixels(@floatFromInt(fb.w), @floatFromInt(fb.h));
            const model = core.math.Mat4.mul(
                core.math.Mat4.translate(cx, cy),
                core.math.Mat4.mul(
                    core.math.Mat4.rotateZ(state.renderAngle(loop.alpha())),
                    core.math.Mat4.scale(240),
                ),
            );
            const mvp = core.math.Mat4.mul(view, model);
            renderer.drawQuad(&mvp.m);
        } else {
            const mvp = core.math.Mat4.identity;
            renderer.drawQuad(&mvp.m);
        }
        renderer.present();
        z_render.end();

        frame_arena.endFrame();
        tracker.endFrame(); // end of the forbidden zone
        z.end(); // close the zone that wraps the frame
        prof.endFrame(); // records duration and drains zones
        if (has_window) window.input.endFrame();

        frame_count += 1;
        if (args.frames != 0 and frame_count >= args.frames) break;
    }

    // Acceptance report (M0)
    core.log.info("frames rendered: {d}", .{frame_count});
    prof.report("== PERF (frames) ==");
    core.log.info("mem: frame arena high-water: {d} bytes", .{frame_arena.high_water});
    core.log.info("allocs boot: {d} frees: {d} peak: {d} bytes", .{
        tracker.count_allocs, tracker.count_frees, tracker.peak_live_bytes,
    });
}
