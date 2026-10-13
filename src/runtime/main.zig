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
/// M9: the scene-transition fader.
const fader_mod = engine.fade;
/// M9: the CPU particle system.
const particles_mod = engine.particles;
const batcher_mod = engine.batcher;
const backend_null = engine.render.backend_null;
const backend_dawn = engine.render.backend_dawn;
const ecs = engine.ecs;
const script = engine.script;
const project = engine.project;
/// M-project → M8: the one file that can see `project.config` AND `audio`.
const project_hook = @import("project_hook.zig");
const components = ecs.components;
const log = core.log.scoped("runtime");

const fixed_dt: f32 = 1.0 / 60.0;
const rotation_speed: f32 = 1.5; // rad/s

/// Where a project's sound files live, relative to the project root.///
/// The runtime is launched FROM the project root — that is where
/// `project.config` is read from (`project.config.default_path`) — so the path
/// a script plays (`audio.play_file("assets/audio/boom.wav")`) is spelled
/// exactly the way the watcher reports it. That is what makes a reload find the
/// bank slot: `Bank.find` is a string match, and a directory watched under a
/// different spelling would report names no slot ever held.
const audio_asset_dir = "assets/audio";

/// How many changed entries one poll may report. A `git checkout` of the sound
/// directory touches every file in it; the watcher truncates past this and the
/// poll reports the rest on the next frame, which is harmless because a reload
/// is idempotent.
const audio_watch_capacity = 16;

const Args = struct {
    frames: u64 = 0, // 0 = infinite
    headless: bool = false,
    vsync: bool = true,
    warmup: u64 = 30,
    max_fps: u32 = 0,
    smaa: bool = true,
    /// Boot the real backend, compile every shader, render a few frames, and
    /// EXIT NON-ZERO if the GPU reported anything.
    gpu_smoke: bool = false,
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
        } else if (std.mem.eql(u8, arg, "--gpu-smoke")) {
            args.gpu_smoke = true;
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
/// The M7 `lighting.*` bindings, as a vtable over the driver.
///
/// The script module cannot import `render`, so the three things a Lua caller
/// needs -- the tier, a way to change it, and the per-frame stats -- are published
/// as function pointers instead of a pointer to the driver. A vtable and not a
/// module global: the editor and a test can both have a lighting system alive at
/// once and they must not share one.
///
/// `ctx` is filled in once the driver exists, below.
var lighting_hooks = script.context.LightingHooks{
    .ctx = undefined,
    .get_quality = struct {
        fn f(ctx: ?*anyopaque) u8 {
            const d: *lighting_driver.Driver = @ptrCast(@alignCast(ctx.?));
            return @intFromEnum(d.quality());
        }
    }.f,
    .set_quality = struct {
        fn f(ctx: ?*anyopaque, tier: u8) bool {
            const d: *lighting_driver.Driver = @ptrCast(@alignCast(ctx.?));
            return d.setQuality(@enumFromInt(tier));
        }
    }.f,
    // Index order IS the name order in `lua_lighting_stats`. Both lists live in
    // one place per module and a fixed 16-wide array crosses the boundary, so a
    // value cannot be paired with the wrong name.
    .stats = struct {
        fn f(ctx: ?*anyopaque, out: *[16]f64) u32 {
            const d: *lighting_driver.Driver = @ptrCast(@alignCast(ctx.?));
            const s = &d.lighting.stats;
            const v = [_]f64{
                @floatFromInt(s.lights),
                @floatFromInt(s.shadow_lights),
                @floatFromInt(s.shadow_denied),
                @floatFromInt(s.occluders),
                @floatFromInt(s.occluders_rasterized),
                @floatFromInt(s.coverage_used),
                @floatFromInt(s.coverage_dropped),
                @floatFromInt(s.sweep_steps),
                @floatFromInt(s.sweep_skips),
                @floatFromInt(d.lighting.channel_masks_built),
                @as(f64, @floatCast(s.mask_fill)),
                @floatFromInt(s.collect_ns),
                @floatFromInt(s.sweep_ns),
                @floatFromInt(s.raster_ns),
            };
            const n = @min(v.len, out.len);
            @memcpy(out[0..n], v[0..n]);
            return @intCast(n);
        }
    }.f,
};

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

/// Re-decodes every resident sound whose file just changed.
///
/// Three deliberate refusals, each of which is the honest answer rather than a
/// best effort:
///
/// - **A non-audio entry is ignored.** The watcher reports every write in the
///   directory (it knows nothing about audio), so the extension check is here.
/// - **A file the bank does not hold is ignored.** Reloading would DECODE a
///   sound nobody is playing and charge it to the PCM budget, evicting
///   something that is. A sound that was evicted is decoded again the next time
///   it is played, which is correct — just later.
/// - **A streaming slot is refused by `Audio.reload`**, because its PCM is a
///   window into a ring and re-decoding it would free an interior pointer. That
///   is logged rather than swallowed: the operator needs to know why the edit
///   did not take.
fn reloadChangedAudio(sys: *engine.audio.Audio, watcher: *platform.DirectoryWatcher) void {
    var names: [audio_watch_capacity][]const u8 = undefined;
    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const n = watcher.pollNames(&names);
    for (names[0..n]) |name| {
        if (!platform.isAudioAsset(name)) continue;
        const path = std.fmt.bufPrint(&path_buf, "{s}/{s}", .{ audio_asset_dir, name }) catch continue;
        if (sys.bank.find(path) == null) continue;
        sys.reload(path) catch |err| switch (err) {
            error.StreamNotReloadable => log.info("{s} is streamed: stop and play it again to pick up the edit", .{path}),
            else => log.warn("audio reload of {s} failed: {s}", .{ path, @errorName(err) }),
        };
    }
}

// ── Project config apply callbacks ──────────────────────────────────────
// These are called by `project.runtime.apply` to push config values into
// engine subsystems. Kept here so the runtime owns the engine objects.

fn applyDisplay(_: *anyopaque, d: *const project.config.Display) void {
    // Window size/title changes would require GLFW API additions (not yet exposed)
    // For now, log what would change.
    // TODO: window.resize(d.width, d.height); window.setTitle(d.name);
    //       window.setFullscreen(d.fullscreen); window.setVsync(d.vsync);
    _ = d;
}

fn applyRendering(_: *anyopaque, r: *const project.config.Rendering) void {
    // Renderer sort mode and max_sprites are boot-time only (need re-create).
    // SMAA quality is per-frame via renderer.endScene().
    _ = r;
}

fn applyPhysics(_: *anyopaque, p: *const project.config.Physics) void {
    // Physics gravity and solver settings are creation-time in current engine.
    // Would need physics.setGravity() and physics.setSolverIterations().
    _ = p;
}

/// The `lighting` section, applied to the live driver.
///
/// This callback is the ONLY path by which `shadow_resolution`
/// ever reaches the lighting system. Without it the whole section is inert and the
/// driver runs on its constructor's guesses — which is how `shadow_resolution`
/// stayed at 2048 for a release while the config file said 1024.
///
/// It is a config callback rather than a line at boot so that EDITING the file
/// re-applies it: the two dials that cost the most are exactly the two a
/// developer tunes by watching the frame time, and a setting you must relaunch to
/// see is one you tune once and forget.
///
/// `applyLightingConfig` can allocate (a resolution change resizes the field),
/// so the error is logged rather than propagated: a project that asks for a grid
/// too large to allocate gets the driver's previous settings and a warning,
/// rather than no window.
fn applyLighting(ctx: *anyopaque, l: *const project.config.Lighting) void {
    const driver: *lighting_driver.Driver = @ptrCast(@alignCast(ctx));
    driver.applyLightingConfig(l.*) catch |err| {
        log.warn("lighting config not applied ({s}); keeping the previous settings", .{
            @errorName(err),
        });
        return;
    };
    // NO resize here, deliberately.
    //
    // At config-apply time the driver has no view yet — `lighting.rect` is still
    // empty — and the shadow resolution is a SCALE derived from a view, so
    // resizing there asks the mask to be 1x1 against a scale meant for 1920 and
    // panics in `allocMask`. It was tried, and it crashed on the first frame.
    //
    // Nothing is lost by waiting: `Driver.resize` re-derives the scale from the
    // view it is given, so the frame loop's own resize — which has a real view —
    // applies the stored resolution. Storing the number at config time and
    // applying it at resize time is also the only order that survives a window
    // resize, which is why `Driver` remembers it rather than deriving it once.
}

fn applyLayers(_: *anyopaque, l: *const project.config.Layers) void {
    // Collision layer names would need ecs.collision_layers.Registry integration.
    _ = l;
}

fn applyInputMap(_: *anyopaque, actions: []const project.config.InputAction) void {
    // Input bindings would need to be resolved and pushed to script.Input.
    // Currently: input_state.set(action_name, key_down, key_pressed)
    _ = actions;
}

/// M9: the payload a finished scene transition carries on the world bus.
///
/// The signal is what a Lua `on_signal("scene_faded")` handler and a Zig
/// listener both receive; the amount says WHICH transition settled (1 = covered,
/// 0 = clear), which is the difference between "swap the level now" and "the
/// screen is clear again".
const FadeSignal = struct {
    /// The settled coverage, 0..1.
    amount: f32 = 0,
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
    // Kept so the smoke gate can reach the device the backend made. Null in
    // headless, where the smoke gate refuses to claim a verdict it cannot earn.
    var dawn_device: ?backend_dawn.wgpu.WGPUDevice = null;
    var dawn_handle: ?*anyopaque = null;
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
        dawn_device = dawn.gpuDevice();
        dawn_handle = @ptrCast(dawn);
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
    // The scripting layer gets an allocator OUTSIDE the frame guard.
    //
    // The tracker's rule (spec §3.1) is that the frame allocates nothing: every
    // transient byte comes from the frame arena. The Lua heap is not transient
    // engine memory — it has its own budget (spec §3.2: the incremental GC step
    // is ≤ 0.4 ms/frame) and its own accounting (`vm.heapStats()`), and LuaJIT
    // legitimately allocates from a script's very first update onward. Charging
    // it to the frame guard aborts every scripted frame, which is a false alarm
    // about the engine wrapped around a real one about the wiring.
    const script_alloc = std.heap.c_allocator;
    try behaviors.init(script_alloc, &world, &input_state);
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
    // Publish the lighting system to Lua's `lighting.*` module. Here, after both
    // exist and before the first script runs, so a script that asks for the
    // quality in its first tick gets a real answer rather than -1.
    lighting_hooks.ctx = &lighting;
    behaviors.ctx.lighting = &lighting_hooks;

    // ── Project config hot-reload ────────────────────────────────────────
    // Load project.config, apply it to engine subsystems, and watch for changes.
    var project_config = project.config.Config{};
    var config_watcher: ?platform.FileWatcher = null;
    // The apply callbacks all share ONE context pointer, and for audio that
    // context is the hook itself: it stores the section, and `create` below
    // turns it into a running mixer.
    var audio_hook = project_hook.AudioHook{};
    defer audio_hook.destroy();
    if (!args.headless) {
        // Load config (or defaults if file doesn't exist)
        const loaded = project.config.load(boot_alloc, project.config.default_path);
        if (loaded) |cfg| {
            project_config = cfg.*;
            log.info("loaded project.config: {s}", .{project_config.project});
        } else |err| {
            log.info("no project.config found ({s}), using defaults", .{@errorName(err)});
        }

        // Apply config to engine subsystems
        project.runtime.apply(&project_config, .{
            .ctx = &audio_hook,
            .display = applyDisplay,
            .rendering = applyRendering,
            .physics = applyPhysics,
            .layers = applyLayers,
            .lighting = applyLighting,
            .audio = project_hook.AudioHook.apply,
            .input_map = applyInputMap,
        }) catch |err| {
            log.warn("project.config apply failed: {s}", .{@errorName(err)});
        };

        // Start file watcher for hot-reload
        const watcher_result = platform.watchFile(boot_alloc, project.config.default_path);
        if (watcher_result) |w| {
            config_watcher = w;
            log.info("watching project.config for hot-reload", .{});
        } else |err| {
            log.warn("file watcher failed: {s}", .{@errorName(err)});
        }
    }
    defer {
        if (config_watcher) |*w| w.deinit();
        project_config.deinit();
    }

    // ── M8: the mixer ────────────────────────────────────────────────────
    // Built AFTER the section is applied, because the section decides the
    // backend, the pool size, the PCM budget and the bus map. In headless mode
    // nothing was applied, so the defaults stand and the NULL backend is forced:
    // CI has no sound card and must not need one to exercise the mixer.
    if (args.headless) audio_hook.section.backend = .null;
    var audio_system: ?*engine.audio.Audio = audio_hook.create(boot_alloc) catch |err| blk: {
        // No device, no mixer: the engine keeps running silent (spec: a missing
        // sound card must not stop a game) and the log says which it was.
        log.warn("audio unavailable: {s} — running silent", .{@errorName(err)});
        break :blk null;
    };
    if (audio_system) |sys| {
        log.info("audio: {s} backend, {d} Hz, {d} frames ({d:.1} ms), {d} voices, {d} MiB PCM budget", .{
            sys.device.name,
            sys.stats().sample_rate,
            sys.stats().period_frames,
            sys.stats().latencyMs(),
            sys.pool.slotCount(),
            sys.bank.stats().budget_bytes / (1 << 20),
        });
    }
    // Published before the first script runs, so an `audio.*` call in a
    // behavior's `start()` sees the real system rather than null.
    behaviors.ctx.audio = audio_system;

    // ── M9: the scene-transition fader. Owned by the runtime like the camera:
    // it is engine state that outlives a script, and the `scene.*` bindings
    // reach it through the hook struct below. A transition advances on REAL
    // time (see `fade.zig` for why it must not be the fixed step), so it is
    // updated in the render section with the frame's real dt.
    var fader = fader_mod.Fader{};

    // ── M9: the CPU particle system. A pool reserved at boot like the sprite
    // instance buffer, with the same discipline: `reserve` sizes it, `lock`
    // freezes it, and a frame that asks for more than was reserved DROPS and
    // reports instead of allocating (spec §3.1). The pool is not part of the
    // scene: it is a cache the system owns, and `.zson` never sees it.
    var particles = particles_mod.System.init(boot_alloc);
    particles.reserve(.{
        .max_particles = 65_536,
        .max_emitters = 256,
        .max_per_emitter = 4096,
    }) catch |err| {
        log.err("particle pool reserve failed: {s} — emitters will emit nothing", .{@errorName(err)});
    };
    defer particles.deinit();
    particles.setFixedDt(fixed_dt);
    particles.lock();

    var anim_system = ecs.animation.System.init(boot_alloc);
    defer anim_system.deinit();

    // ── M9: the scene-transition fader hooks ────────────────────────────────
    var scene_hooks = script.context.SceneHooks{
        .ctx = &fader,
        .fade_out = struct {
            fn fade_out_fn(ctx: ?*anyopaque, duration: f32, r: f32, g: f32, b: f32) void {
                const fd: *fader_mod.Fader = @ptrCast(@alignCast(ctx.?));
                fd.fadeOut(duration, .{ r, g, b });
            }
        }.fade_out_fn,
        .fade_in = struct {
            fn fade_in_fn(ctx: ?*anyopaque, duration: f32) void {
                const fd: *fader_mod.Fader = @ptrCast(@alignCast(ctx.?));
                fd.fadeIn(duration);
            }
        }.fade_in_fn,
        .fade_covered = struct {
            fn fade_covered_fn(ctx: ?*anyopaque, r: f32, g: f32, b: f32) void {
                const fd: *fader_mod.Fader = @ptrCast(@alignCast(ctx.?));
                fd.snapCovered(.{ r, g, b });
            }
        }.fade_covered_fn,
        .fade_clear = struct {
            fn fade_clear_fn(ctx: ?*anyopaque) void {
                const fd: *fader_mod.Fader = @ptrCast(@alignCast(ctx.?));
                fd.snapClear();
            }
        }.fade_clear_fn,
        .amount = struct {
            fn amount_fn(ctx: ?*anyopaque) f32 {
                const fd: *fader_mod.Fader = @ptrCast(@alignCast(ctx.?));
                return fd.amount;
            }
        }.amount_fn,
        .fading = struct {
            fn fading_fn(ctx: ?*anyopaque) bool {
                const fd: *fader_mod.Fader = @ptrCast(@alignCast(ctx.?));
                return !fd.isIdle();
            }
        }.fading_fn,
    };
    behaviors.ctx.scene = &scene_hooks;

    // ── M9: the particle pool hooks ──────────────────────────────────────────
    var particles_hooks = script.context.ParticleHooks{
        .ctx = &particles,
        .burst = struct {
            fn burst_fn(ctx: ?*anyopaque, entity_bits: u64, count: u32) u32 {
                const ps: *particles_mod.System = @ptrCast(@alignCast(ctx.?));
                const e = ecs.Entity{ .index = @intCast(entity_bits), .generation = @intCast(entity_bits >> 32) };
                return ps.burst(e, count);
            }
        }.burst_fn,
        .stats = struct {
            fn stats_fn(ctx: ?*anyopaque, out: *[16]f64) u32 {
                const ps: *particles_mod.System = @ptrCast(@alignCast(ctx.?));
                const s = ps.getStats();
                const v = [_]f64{
                    @floatFromInt(s.simulated),
                    @floatFromInt(s.live),
                    @floatFromInt(s.spawned),
                    @floatFromInt(s.drawn),
                    @floatFromInt(s.culled),
                    @floatFromInt(s.dropped_spawn),
                    @floatFromInt(s.slab_denied),
                    @as(f64, @floatFromInt(s.sim_ns)) / 1_000_000.0,
                    @as(f64, @floatFromInt(s.collect_ns)) / 1_000_000.0,
                };
                const n = @min(v.len, out.len);
                @memcpy(out[0..n], v[0..n]);
                return @intCast(n);
            }
        }.stats_fn,
    };
    behaviors.ctx.particles = &particles_hooks;

    // ── M8: audio asset hot-reload (inotify on the sound directory) ─────────
    // `project.config` has its own watcher above; this one is per-ASSET, which
    // is the other half of the M8 hot-reload promise: saving `boom.wav` in the
    // project's sound directory re-decodes it INTO ITS BANK SLOT, so a voice
    // already playing that slot picks up the new bytes without a restart.
    //
    // One directory watch rather than one per file: a level's library is dozens
    // of clips, and a watch per clip is N descriptors plus a list to rebuild
    // every time an artist adds a file.
    //
    // A missing directory is not an error: a project with no sounds yet (or a
    // game that plays its audio from a `.pak`) simply has nothing to watch.
    var audio_watcher: ?platform.DirectoryWatcher = null;
    if (audio_system != null and !args.headless) {
        if (platform.watchDirectory(boot_alloc, audio_asset_dir)) |w| {
            audio_watcher = w;
            log.info("watching {s} for sound changes", .{audio_asset_dir});
        } else |err| {
            log.info("no audio asset watch ({s} at '{s}')", .{ @errorName(err), audio_asset_dir });
        }
    }
    defer if (audio_watcher) |*w| w.deinit(boot_alloc);

    // ── M8: sound events → Signals (ROADMAP M8, spec §6) ─────────────────────
    // The device thread learns that a voice started or ended; only the MAIN
    // thread may touch the ECS or the signal bus, so the event ring is where the
    // two meet and this is the drain. Both names are interned at boot: `emit`
    // panics on a name it has never seen (it would allocate), by design.
    if (audio_system != null) {
        for ([_][]const u8{ "sound_started", "sound_finished" }) |name| {
            world.signals.preintern(name) catch |err| {
                log.warn("could not reserve the '{s}' signal: {s}", .{ name, @errorName(err) });
            };
        }
    }

    // M9: the fade's completion signal, interned for the same reason as the
    // audio ones — `emit` panics on a name it has never seen, because
    // interning allocates and the frame loop forbids it.
    world.signals.preintern("scene_faded") catch |err| {
        log.warn("could not reserve the 'scene_faded' signal: {s}", .{@errorName(err)});
    };

    const AudioSignals = struct {
        world: *ecs.World,
        behaviors: *script.Behaviors,

        fn fire(ctx: ?*anyopaque, kind: engine.audio.EventKind, value: engine.audio.SoundSignal) void {
            const self: *@This() = @ptrCast(@alignCast(ctx.?));
            const name = engine.audio.soundSignalName(kind);
            // The typed bus first: an ECS listener sees the event whether or not
            // any script is interested.
            self.world.signals.emit(engine.audio.SoundSignal, name, value);
            // Then Lua, as a table. `path` is deliberately not a field — a
            // signal payload crosses the bus as POD bytes, so a listener that
            // wants the name asks the bank, which is what owns it.
            const fields = [_]script.Behaviors.PayloadField{
                .{ .name = "slot", .value = .{ .integer = value.bank_slot } },
                .{ .name = "voice", .value = .{ .integer = value.voice_index } },
                .{ .name = "generation", .value = .{ .integer = value.voice_generation } },
                .{ .name = "tick", .value = .{ .integer = @intCast(value.tick) } },
            };
            self.behaviors.dispatchSignalPayload(name, &fields);
        }
    };
    var audio_signals = AudioSignals{ .world = &world, .behaviors = &behaviors };

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

        // ── Project config hot-reload: poll file watcher
        if (config_watcher) |*w| {
            if (w.poll()) |changed| {
                if (changed) {
                    log.info("project.config changed, reloading...", .{});
                    project_config.reload(boot_alloc, project.config.default_path) catch |err| {
                        log.err("project.config reload failed: {s}", .{@errorName(err)});
                        return;
                    };
                    // Re-apply config after reload
                    project.runtime.apply(&project_config, .{
                        .ctx = &audio_hook,
                        .display = applyDisplay,
                        .rendering = applyRendering,
                        .physics = applyPhysics,
                        .layers = applyLayers,
                        .audio = project_hook.AudioHook.apply,
                        .input_map = applyInputMap,
                    }) catch |err| {
                        log.warn("project.config re-apply failed: {s}", .{@errorName(err)});
                    };
                    // M8: the audio section is boot-time only (the device, the
                    // pool and the budget cannot be resized in place), so a
                    // change to it REBUILDS the mixer — and a change to any
                    // OTHER section does not, which is what `sync` decides. An
                    // edit to `display.width` restarting the mixer would drop
                    // every voice and glitch the device for no reason.
                    audio_system = audio_hook.sync(boot_alloc) catch |err| blk: {
                        log.warn("audio reload failed: {s} — running silent", .{@errorName(err)});
                        break :blk null;
                    };
                    behaviors.ctx.audio = audio_system;
                }
            } else |err| {
                log.warn("file watcher error: {s}", .{@errorName(err)});
            }
        }

        // ── M8: audio asset hot-reload: poll the sound directory.
        // NEXT TO the config watch and OUTSIDE the frame guard, because reloading
        // decodes (blocking I/O plus an allocation) and §3.4 forbids both inside
        // a frame. Ordering it before `tracker.beginFrame` below is what keeps
        // the reload honest: the engine never pays for an artist's save inside
        // the loop it is measuring.
        if (audio_watcher) |*w| {
            if (audio_system) |sys| reloadChangedAudio(sys, w);
        }

        // ── M7: the lighting mask is sized HERE, before the allocation guard is
        // armed, and not in the render section below where it used to live.
        //
        // `Lighting.resize` and `reserve` allocate — the GI pixel buffer, the
        // mask, the SDF, the EDT scratch, the gather arrays. `tracker.beginFrame`
        // (three lines down) panics on any allocation outside the frame arena,
        // which is the spec §3.1 invariant being *verified* rather than hoped
        // for. Putting the call inside the frame meant the very first frame
        // panicked on an 8 MiB `gi_pixels`, and no camera zoom or window drag
        // would have been able to resize again either: the call could only ever
        // run in the zone where it is forbidden.
        //
        // The mask follows the camera, and `camera_view` is updated further down
        // inside the frame — so this sizes to LAST frame's view. That one frame
        // of latency on a resize is deliberate and costs nothing: the mask is
        // already a power of two wider than the view, and `resize` is a no-op
        // until the view actually changes shape. When it does, the buffer is
        // ready one frame before the first frame that needs the new size.
        const fb_w: u32 = if (has_window) window.framebufferSize().w else view_w;
        const fb_h: u32 = if (has_window) window.framebufferSize().h else view_h;
        lighting.resize(lighting_driver.Driver.viewFor(camera_view, fb_w, fb_h)) catch |err| log.warn("lighting mask resize failed: {s}", .{@errorName(err)});
        if (lighting.needs_resize) {
            // A precondition, not a hint: `collect` appends without capacity
            // checks because allocating mid-frame is forbidden (spec §3.1).
            lighting.lighting.reserve(lighting_budget.lights, lighting_budget.occluders) catch {};
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

        // ── M8: the mixer's frame boundary. One call, BEFORE the gameplay that
        // may play something: it advances the bank's clock (so a sound's tick is
        // the frame it started in) and folds the listener in from the camera.
        // It allocates nothing — the audio path is command-ring pushes only, and
        // the frame's allocation guard is armed from `tracker.beginFrame` above.
        //
        // Its own zone is what makes the main-thread audio cost visible in the
        // report: `play` pushes a command and returns, and a scene that fires
        // fifty sounds in one frame pays fifty pushes. That number was
        // invisible before M8 closed, and a regression in it is exactly the
        // kind of thing PROFILING.md promises CI will catch.
        var z_audio_main = prof.zone("audio");
        if (audio_system) |sys| {
            sys.beginFrame(@intCast(frame_index));
            // Rotation 0: the runtime ears face +x. A game that wants the ears
            // to turn with an actor calls `audio.set_listener(x, y, rot)`.
            if (camera_view) |v| sys.setListener(v.cx, v.cy, 0);

            // The device thread's own numbers, published once a frame. These
            // are the M8 criteria as counters: the peak proves the emitters
            // overlapped, the xrun count is the one failure mode audio has that
            // is not a crash, and the mix cost is whether the callback fits in
            // its period.
            const a = sys.stats();
            const bs = sys.bankStats();
            const c = &prof.counters;
            c.audio_voices_peak = @max(c.audio_voices_peak, a.voices_peak);
            c.audio_xruns = a.xruns;
            c.audio_commands_dropped = a.commands_dropped;
            c.audio_latency_us = @intFromFloat(@as(f64, @floatFromInt(a.period_frames)) /
                @as(f64, @floatFromInt(@max(a.sample_rate, 1))) * 1_000_000.0);
            c.audio_mix_ns = sys.mixNsPerBuffer();
            c.audio_bank_bytes = bs.bytes_used;
            c.audio_bank_budget = bs.budget_bytes;
        }
        z_audio_main.end();

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
            anim_system.update(&world, fixed_dt, timer_bridge);
            // M3: behaviors run at the fixed 60 Hz tick. `startAll` already ran,
            // so this is the gameplay itself: Lua -> actor.* bindings -> ECS.
            behaviors.fixedUpdate(fixed_dt);
            // M9: particle simulation, AFTER gameplay so a behavior that moves
            // or bursts an emitter this tick is honoured by the same tick's
            // integration rather than the next one. Same fixed dt, same order
            // every frame, which is what makes a particle scene deterministic.
            particles.fixedUpdate(&world, fixed_dt);
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

        // ── The frame's signal drain (spec §6).
        // Audio events first: they were produced on the device thread during the
        // last buffer and have been waiting for the main thread since. Then the
        // typed bus fires everything queued THIS frame, in emission order, so a
        // `sound_finished` a script emitted into Lua is also visible to any ECS
        // listener, in the same frame, without a second drain point.
        if (audio_system) |sys| sys.drainEvents(.{ .ctx = &audio_signals, .fire = AudioSignals.fire });
        world.signals.drain();
        z_script.end();

        // ── M2: ECS → GPU instances via render2d.
        var z_batch = prof.zone("batch");
        // M9: the particles go into the SAME instance list as the sprites, so
        // they batch with them: one atlas, one draw call, and the ≤ 32 draw-call
        // budget (spec §4) counts them the same way it counts every other quad.
        particles.beginFrame();
        particles.collect(
            &r2d,
            &world,
            loop.alpha(),
            if (camera_view) |v| render2d.ViewRect.around(
                v.cx,
                v.cy,
                v.viewport_w / v.zoom * 0.5,
                v.viewport_h / v.zoom * 0.5,
                64,
            ) else null,
        );
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

        // ── M9: advance the scene transition, then fold it into the
        // environment the post pass reads. A finished transition fires
        // `scene_faded` exactly once — the Lua bridge first, so a behavior's
        // `on_signal` can swap the level, then the typed bus for any Zig
        // listener. Gates on `hasListeners` like physics contacts: a signal
        // nobody subscribed to must not enqueue.
        fader.update(real_dt);
        if (fader.just_finished) {
            const amount = fader.amount;
            timer_bridge.fire("scene_faded");
            if (world.signals.hasListeners("scene_faded")) {
                world.signals.emit(FadeSignal, "scene_faded", .{ .amount = amount });
            }
        }

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
        // M9: the curtain. Merged here rather than passed through the light
        // driver because it belongs to the TRANSITION and not to the scene's
        // Environment component: a `environment.new` actor still gets its fog
        // and bloom, and a fade does not need a component to exist.
        lighting_env.fade_color = fader.rgba();

        // The mask is already sized by `sync_lighting_buffers` above, OUTSIDE
        // the tracker guard, because `resize` allocates and `Lighting.resize`
        // says so in its own docs. Everything from here to the end of the frame
        // reads buffers that already exist.

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
    // The sprite count was a literal `0` with a TODO beside it, printed in a line
    // that reads as a measurement. So the canonical scene reported "0 sprites ->
    // N draw calls" and nobody could tell from the output whether the world had
    // loaded, the collector had dropped everything, or the number was simply never
    // wired up -- which is exactly what it was.
    //
    // `Stats.instances` has existed the whole time. Three of the four counters in
    // this line were already real; this one was a constant wearing a label.
    core.log.info("batcher: {d} sprites -> {d} draw calls this frame (max {d} in the run), budget 32", .{
        r2d.stats.instances,
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
    // M9: the particle numbers, beside the renderer's. A pool reporting
    // `dropped_spawn` or `slab_denied` is the M9 equivalent of a clipped batch:
    // the scene asked for more than was reserved, and the counters say which of
    // the two limits was hit (a slab at capacity, or the pool out of room).
    const pstats = particles.getStats();
    core.log.info("particles: {d} emitters simulated, {d} live, {d} spawned, {d} drawn (culled {d})", .{
        pstats.simulated,
        pstats.live,
        pstats.spawned,
        pstats.drawn,
        pstats.culled,
    });
    if (pstats.dropped_spawn > 0 or pstats.slab_denied > 0) {
        core.log.warn("particles: {d} spawns dropped at emitter capacity, {d} emitters denied a slab (reserve too small)", .{
            pstats.dropped_spawn,
            pstats.slab_denied,
        });
    }
    core.log.info("particles: sim {d:.3} ms/tick, collect {d:.3} ms/frame (last frame)", .{
        @as(f64, @floatFromInt(pstats.sim_ns)) / 1_000_000.0,
        @as(f64, @floatFromInt(pstats.collect_ns)) / 1_000_000.0,
    });
    // M9: the transition state at exit, which is how a CI run says "the demo
    // ended mid-fade" instead of a screenshot nobody looks at.
    core.log.info("scene fade: {s}, amount {d:.2}", .{ @tagName(fader.state), fader.amount });
    // M8: the audio numbers, next to the renderer's. A mixer reporting xruns or
    // dropped commands is the one failure mode audio has — it does not crash, it
    // crackles — so the counters are printed where a run's report already is.
    if (audio_system) |sys| {
        const a = sys.stats();
        core.log.info("audio: {d} voices active (peak {d}), {d} xruns, {d} commands dropped, {d:.1} ms latency", .{
            a.voices_active,
            a.voices_peak,
            a.xruns,
            a.commands_dropped,
            a.latencyMs(),
        });
        const bs = sys.bankStats();
        core.log.info("audio bank: {d} sounds resident, {d} B used of {d} B budget", .{
            bs.slots_used, bs.bytes_used, bs.budget_bytes,
        });
    }
    core.log.info("gpu upload: {d} B/frame (budget 2097152, spec §4)", .{st.upload_bytes});
    if (st.upload_bytes > 2 * 1024 * 1024) {
        core.log.warn("staging upload {d} B/frame exceeds the spec §4 ceiling (2 MB)", .{st.upload_bytes});
    }
    // ── THE GPU GATE ────────────────────────────────────────────────────────────
    //
    // Everything else in this report is a measurement the CPU made about itself.
    // This is the one question only the device can answer: did the GPU accept
    // what we asked it to draw?
    //
    // It is a separate exit path on purpose. `--frames N` exits zero whether or
    // not anything rendered, because a benchmark that fails for being slow gets
    // muted -- but a VALIDATION ERROR is not slowness. It is the driver saying
    // "I did not build that pipeline", and the frame that follows is drawn with
    if (args.gpu_smoke) {
        if (dawn_device != null) {
            const shader_failures = if (dawn_device) |d| backend_dawn.Backend.checkShaders(d) else 0;
            const gpu_errors = backend_dawn.gpu_error_count;
            core.log.info("== GPU SMOKE ==", .{});
            core.log.info("  shaders refused by the device: {d} of 6", .{shader_failures});
            core.log.info("  uncaptured GPU errors this run: {d}", .{gpu_errors});
            core.log.info("  frames rendered: {d}", .{frame_count});
            if (shader_failures != 0 or gpu_errors != 0) {
                core.log.err("GPU SMOKE FAILED: the device did not accept everything we sent it", .{});
                std.process.exit(1);
            }
            core.log.info("  OK: the device compiled every shader and raised nothing.", .{});
        }
    }
    prof.report("== PERF (frames) ==");
    core.log.info("mem: frame arena high-water: {d} bytes", .{frame_arena.high_water});
    core.log.info("allocs boot: {d} frees: {d} peak: {d} bytes", .{
        tracker.count_allocs, tracker.count_frees, tracker.peak_live_bytes,
    });
}
