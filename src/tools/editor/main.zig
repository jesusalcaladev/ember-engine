//! The ember editor.
//!
//! One process, three halves that share a frame:
//!
//!   * the world — ECS, physics, animation, particles — stepped on a fixed
//!     timestep exactly like `src/runtime/main.zig`, because an editor that
//!     simulates differently from the game it edits is a lie;
//!   * the viewport — a 2D scene plus the lighting pass, drawn by the same
//!     renderer the runtime uses;
//!   * the editor overlay — Dear ImGui, with a real Lua code pane beside it.
//!
//! ## Why the editor is not a second runtime
//!
//! Everything below `world` is borrowed, never owned. The one exception is the
//! world itself, which the session model owns from the moment it is created
//! (see `main`), and that asymmetry is deliberate: it is the only arrangement
//! in which no two subsystems believe they are responsible for freeing the same
//! archetypes.

const std = @import("std");

const engine = @import("engine");
const core = engine.core;
const platform = engine.platform;
const render = engine.render;
const render2d = engine.render2d;
const lighting_driver = engine.lighting_driver;
const particles_sys = engine.particles;
const fade = engine.fade;
const ecs = engine.ecs;
const script = engine.script;
const project = engine.project;
const assets = engine.assets;
const ui = @import("ui");
const physics = @import("physics");
const session = @import("session");
const code_pane = @import("code_pane.zig");
const tilemap_panel = @import("tilemap_panel.zig");

const Model = session.model.Model;
const log = core.log.scoped("editor");

/// The fixed timestep. Same value the runtime steps on, so a scene edited here
/// behaves identically when it is run.
const fixed_dt: f32 = 1.0 / 60.0;

/// Atlas slot the collision overlay renders from.
///
/// Deliberately 255: the sprite emitter looks a slot up in the atlas array and
/// falls back to a 1x1 white bind group when the index is out of range, so this
/// "slot" names no page and samples pure white. The debug quad's colour is
/// therefore exactly its tint, with no atlas content to leak through — and a
/// project that later creates 256 atlas pages cannot steal the overlay's slot,
/// because doing so would mean re-pointing this one constant on purpose.
const debug_slot: u8 = 255;

/// Render layer the overlay draws on. Last, so it is never hidden by a sprite.
const debug_layer: u8 = 255;

/// Instance budget for the 2D batcher. Sized once at boot so the frame loop
/// drops instances rather than growing a buffer. The headroom over a gameplay
/// scene's needs is the collision overlay's share.
const sprite_budget: usize = 16384;

/// Instances the physics debug renderer may hold. Also reserved once, at boot:
/// its buffer grows with the body count, which is not something a frame may do.
const debug_quad_budget: usize = 4096;

/// Assets the editor pre-registers slots and a byte budget for.
const asset_slots: usize = 1024;
const asset_budget_bytes: usize = 64 * 1024 * 1024;

var frame_count: u64 = 0;

// ─── Arguments ───────────────────────────────────────────────────────────────

const Args = struct {
    project_path: []const u8 = ".",
    headless: bool = false,
    vsync: bool = true,
    gpu_smoke: bool = false,
    /// Collision overlay. ON by default: an editor that hides colliders by
    /// default is an editor whose first bug report is "physics is broken".
    physics_debug: bool = true,
    /// Stop after N frames. 0 = run forever. Exists so the editor can be
    /// smoke-tested in CI without a human closing the window.
    frames: u64 = 0,
    /// Skip the built-in scene. Useful for measuring an empty editor's own
    /// cost, which is the number the frame budget is written against.
    empty_scene: bool = false,
};

fn parseArgs(init: std.process.Init.Minimal) Args {
    var args = Args{};
    var it = std.process.Args.Iterator.init(init.args);
    _ = it.next();
    while (it.next()) |arg| {
        if (std.mem.eql(u8, arg, "--project")) {
            if (it.next()) |p| args.project_path = p;
        } else if (std.mem.eql(u8, arg, "--headless")) {
            args.headless = true;
        } else if (std.mem.eql(u8, arg, "--gpu-smoke")) {
            args.gpu_smoke = true;
        } else if (std.mem.eql(u8, arg, "--vsync")) {
            if (it.next()) |v| args.vsync = onOff(v, true);
        } else if (std.mem.eql(u8, arg, "--physics-debug")) {
            if (it.next()) |v| args.physics_debug = onOff(v, true);
        } else if (std.mem.eql(u8, arg, "--frames")) {
            if (it.next()) |v| args.frames = std.fmt.parseInt(u64, v, 10) catch 0;
        } else if (std.mem.eql(u8, arg, "--empty-scene")) {
            args.empty_scene = true;
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

/// The camera the scene is rendered through: the project's view when there is
/// one, and a pixel-for-pixel ortho when there is not (an empty scene still has
/// to render, or "nothing is wrong" and "nothing is set up" look identical).
fn sceneCamera(view: ?ecs.camera.View, width: u32, height: u32) render.Camera {
    const v = view orelse return render.makeCamera(@floatFromInt(width), @floatFromInt(height));
    return render.makeCameraCustom(v.viewProjection(), 0, 0, width, height);
}

/// The editor's camera. Fixed for now, but it is the same `ecs.camera.View` the
/// runtime would read from a project, so switching to a real camera component
/// later is a query, not a rewrite.
fn editorView(w: f32, h: f32) ecs.camera.View {
    return .{ .cx = 0, .cy = 0, .zoom = 1, .viewport_w = w, .viewport_h = h };
}

/// The world's environment, or a neutral one. A scene with no `Environment`
/// component still has to light, or an unconfigured project renders black and
/// looks broken.
fn defaultEnvironment() ecs.components.Environment {
    return .{};
}

// ─── Headless smoke test ─────────────────────────────────────────────────────

/// The whole editor, minus a window. Runs the CPU half of a frame against the
/// null backend so a build can be checked without a display — which is the
/// situation CI is always in.
fn runHeadless(allocator: std.mem.Allocator, args: Args) !void {
    var tracker = core.tracker.TrackedAllocator{ .child = allocator };
    const boot_alloc = tracker.allocator();

    var world = ecs.World.init(boot_alloc);
    defer world.deinit();
    try world.reserveEntities(1000);
    try world.enableHierarchy();

    var physics_sys = physics.System.init(boot_alloc, .box2d, .{}) catch |err| {
        log.err("physics init: {s}", .{@errorName(err)});
        return err;
    };
    defer physics_sys.deinit();
    log.info("headless: physics ready", .{});

    if (!args.empty_scene) try spawnDemoScene(&world);

    physics_sys.syncLoad(&world);

    var dbg = physics.debug.PhysicsDebugRenderer.init(boot_alloc);
    defer dbg.deinit();
    try dbg.reserve(debug_quad_budget);

    dbg.collect(&world, physics_sys.getWorld());

    log.info("headless: {d} entities, {d} collider quads ({d} sensors)", .{
        world.entityCount(),
        dbg.quadSlice().len,
        dbg.stats.sensors_drawn,
    });
}

// ─── The built-in scene ──────────────────────────────────────────────────────

/// A 6×4 checker of tiles, so the panel and the 2D batcher have something to
/// show the moment the editor opens. Painted through the same `Store` the
/// brushes use, which is what makes it a smoke test rather than a fixture.
fn seedTilePattern(store: *tilemap_panel.Store) void {
    var y: i32 = 0;
    while (y < 4) : (y += 1) {
        var x: i32 = 0;
        while (x < 6) : (x += 1) {
            const tile: ecs.components.Tile = .{ .atlas_index = @intCast(1 + @mod(x + y * 6, 8)) };
            _ = store.setTile(x - 3, y - 12, tile) catch {};
        }
    }
}

/// A scene small enough to read at a glance and large enough to prove every
/// body class the overlay knows how to colour: a floor, a dynamic box that
/// falls onto it, a kinematic platform, and a sensor.
///
/// It exists so the editor opens with something in it. An editor that boots to
/// an empty viewport reads as broken, and "is the tool broken or is my scene
/// empty" is a question nobody should have to answer to get started.
fn spawnDemoScene(world: *ecs.World) !void {
    const Transform = ecs.components.Transform;
    const Sprite = ecs.components.Sprite;
    const RigidBody2D = ecs.components.RigidBody2D;
    const Collider2D = ecs.components.Collider2D;

    // The floor. `body_type = 0` is fixed: it is the immovable green one.
    _ = try world.spawn(.{
        Transform{ .position = .{ .x = 0, .y = 200 }, .rotation = 0 },
        Sprite{ .size = .{ .x = 800, .y = 32 }, .tint = .{ 0.35, 0.37, 0.42, 1 } },
        RigidBody2D{ .body_type = 0 },
        Collider2D{ .size = .{ .x = 400, .y = 16 } },
    });

    // A box that falls. Orange while it moves, which is what makes the solver's
    // work visible: the overlay shows the body where the solver actually put it.
    _ = try world.spawn(.{
        Transform{ .position = .{ .x = -120, .y = -180 }, .rotation = 0 },
        Sprite{ .size = .{ .x = 32, .y = 32 }, .tint = .{ 0.9, 0.5, 0.2, 1 } },
        RigidBody2D{ .body_type = 2 },
        Collider2D{ .size = .{ .x = 16, .y = 16 } },
    });

    // A kinematic platform: moved by code, pushes the dynamic box, never falls.
    _ = try world.spawn(.{
        Transform{ .position = .{ .x = 160, .y = 40 }, .rotation = 0 },
        Sprite{ .size = .{ .x = 160, .y = 16 }, .tint = .{ 0.2, 0.7, 0.7, 1 } },
        RigidBody2D{ .body_type = 1 },
        Collider2D{ .size = .{ .x = 80, .y = 8 } },
    });

    // A sensor. Blue whatever it sits on: it detects, it never pushes, and that
    // is the one thing the overlay has to be able to show at a glance.
    _ = try world.spawn(.{
        Transform{ .position = .{ .x = -120, .y = 120 }, .rotation = 0 },
        RigidBody2D{ .body_type = 2 },
        Collider2D{ .size = .{ .x = 48, .y = 8 }, .is_sensor = true },
    });
}

// ─── Main ────────────────────────────────────────────────────────────────────

pub fn main(init: std.process.Init) !void {
    const args = parseArgs(init.minimal);

    if (args.headless) return runHeadless(std.heap.c_allocator, args);

    // Every long-lived allocation is tracked, and while `in_frame` is armed a
    // frame may not allocate outside the arena. That is the spec §3.1 invariant
    // being VERIFIED rather than hoped for, and it is the reason the frame loop
    // below keeps every growing buffer outside its own body.
    var tracker = core.tracker.TrackedAllocator{ .child = std.heap.c_allocator };
    const boot_alloc = tracker.allocator();

    var frame_arena = try core.arena.FrameArena.init(boot_alloc, 32 * 1024 * 1024);
    defer frame_arena.deinit(boot_alloc);

    // ── Window ──────────────────────────────────────────────────────────────
    var window: platform.Window = undefined;
    var has_window = false;
    try platform.init();
    errdefer platform.deinit();
    window = try platform.Window.create(.{
        .title = "ember editor",
        .width = 1600,
        .height = 900,
        .resizable = true,
    });
    has_window = true;
    platform.setUserPointer(window.handle, &window);
    defer {
        window.destroy();
        platform.deinit();
    }

    // ── Renderer ────────────────────────────────────────────────────────────
    const dawn = try engine.render.backend_dawn.Backend.create(
        boot_alloc,
        window.nativeHandle(),
        window.fb_width,
        window.fb_height,
        .{ .max_sprites = 50_000 },
    );
    var renderer = dawn.renderer();
    defer renderer.deinit();

    var target = renderer.createOffscreenTarget(window.fb_width, window.fb_height);

    // ── The editor's own UI (ImGui) ──────────────────────────────────────────
    //
    // The C allocator, NOT the tracked boot allocator, and that is deliberate:
    // the frame loop arms a no-allocation guard with `tracker.beginFrame()`,
    // and ImGui — plus the code pane's token and completion buffers — allocates
    // legitimately inside a frame. The editor overlay has its own budget and
    // disappears entirely in an export, which is exactly why it does not
    // belong inside the game frame's arena.
    const ui_alloc = std.heap.c_allocator;
    var ui_ctx = ui.Context.init(ui_alloc, &window, dawn.gpuDevice(), dawn.swapchainFormat()) catch |err| {
        log.err("editor UI init failed: {s}", .{@errorName(err)});
        return err;
    };
    defer ui_ctx.deinit();
    if (!ui_ctx.stats.font_loaded) {
        log.warn("no Inter in libs/fonts — ImGui's bitmap font is in use", .{});
        log.warn("run `bash libs/bootstrap.sh` to fetch the typefaces", .{});
    }

    // ── Code pane ───────────────────────────────────────────────────────────
    //
    // A real document on the real Lua lexer: type into it, Ctrl+S formats and
    // writes it, Ctrl+Space completes. It is what proves the editor's text
    // stack end to end rather than in a unit test.
    var pane: code_pane.Pane = undefined;
    // The pane opens on a project file when one was named, and on the built-in
    // sample otherwise — so `--project script.lua` edits a real file and a bare
    // run still shows a real document. A path of "." is the default and means
    // "none": the working directory is not a Lua file.
    const pane_owned: ?[]u8 = blk: {
        if (std.mem.eql(u8, args.project_path, ".")) break :blk null;
        break :blk std.Io.Dir.cwd().readFileAlloc(init.io, args.project_path, boot_alloc, .limited(4 << 20)) catch null;
    };
    defer if (pane_owned) |b| boot_alloc.free(b);
    const pane_source: []const u8 = pane_owned orelse code_pane.default_sample;
    const pane_path: []const u8 = if (pane_owned != null) args.project_path else "";
    pane.init(boot_alloc, pane_path, pane_source) catch |err| {
        log.err("code pane init failed: {s}", .{@errorName(err)});
        return err;
    };
    defer pane.deinit();

    // ── TileMap panel ───────────────────────────────────────────────────────
    //
    // The store owns the chunks, the panel owns the brush. Both live OUTSIDE
    // the frame guard because painting allocates (a new chunk is an append);
    // the panel's `draw` and `pushTiles` only read.
    var tile_store = tilemap_panel.Store.init(boot_alloc) catch |err| {
        log.err("tilemap store init failed: {s}", .{@errorName(err)});
        return err;
    };
    defer tile_store.deinit();
    var tilemap = tilemap_panel.Panel{ .store = &tile_store };
    tilemap_panel.Panel.host_ctx = &ui_ctx;

    // Seed a small checker of tiles. An editor that opens onto an empty canvas
    // reads as broken even when it is not, and this is also what proves the
    // palette-to-batcher path end to end on the first frame.
    seedTilePattern(&tile_store);

    // ── ECS World ───────────────────────────────────────────────────────────
    //
    // Ownership goes to the session model IMMEDIATELY, and everything below
    // borrows it through `world` (a `*ecs.World` with a stable address).
    //
    // Handing the model a BY-VALUE world and also deferring `world.deinit()`
    // is what crashed the editor on exit: `Model.init` copies the struct into a
    // heap cell, so the local and the cell end up pointing at the same
    // archetypes, and whichever was torn down second walks freed memory. One
    // owner, borrowed by everyone else, is the only arrangement that cannot
    // double-free.
    var session_model = Model.init(boot_alloc, ecs.World.init(boot_alloc)) catch |err| {
        log.err("session model init failed: {s}", .{@errorName(err)});
        return err;
    };
    defer session_model.deinit();
    const world = session_model.world();

    try world.reserveEntities(10_000);
    try world.reserve(.{ ecs.components.Transform, ecs.components.Sprite }, 10_000);
    try world.enableHierarchy();

    // ── Input ───────────────────────────────────────────────────────────────
    var input_state = script.Input{};
    input_state.define("move_left");
    input_state.define("move_right");
    input_state.define("jump");

    // ── Scripting ───────────────────────────────────────────────────────────
    //
    // The behaviours run on the C allocator and hold a pointer to the world,
    // not a copy: `World` owns its storage and a second owner would free it.
    const script_alloc = std.heap.c_allocator;
    var behaviors: script.Behaviors = undefined;
    try behaviors.init(script_alloc, world, &input_state);
    defer behaviors.deinit();
    try behaviors.reserve(10_000);
    behaviors.lock();

    // ── Physics ─────────────────────────────────────────────────────────────
    var physics_sys = physics.System.init(boot_alloc, .box2d, .{}) catch |err| {
        log.err("physics init failed: {s}", .{@errorName(err)});
        return err;
    };
    defer physics_sys.deinit();

    // Collision overlay. Collected OUTSIDE the frame's allocation guard because
    // its buffer grows with the body count; the reservation below is the only
    // place it is allowed to allocate. See the push loop in the render section
    // for how the quads reach the screen.
    var physics_debug = physics.debug.PhysicsDebugRenderer.init(boot_alloc);
    defer physics_debug.deinit();
    physics_debug.reserve(debug_quad_budget) catch |err| log.warn("physics debug reserve failed: {s}", .{@errorName(err)});

    // ── Scene ───────────────────────────────────────────────────────────────
    if (!args.empty_scene) spawnDemoScene(world) catch |err| {
        log.warn("demo scene spawn failed: {s}", .{@errorName(err)});
    };

    // Bodies for the scene that just arrived. A LOAD-TIME operation: it
    // allocates, and a frame may not.
    physics_sys.syncLoad(world);

    // Set when the set of ENTITIES changed since the last sync. Rebuilding the
    // solver's bodies allocates, so it happens here — outside the frame's
    // allocation guard — rather than at the edit site, which is inside one.
    //
    // Driven by the entity count rather than by every edit call site: a spawn, an
    // undo, a redone delete and a Lua `entity.create` all move that number, and
    // there is no single function every one of them must remember to call.
    var last_entity_count = world.entityCount();
    var physics_dirty = false;

    // ── Render systems ──────────────────────────────────────────────────────
    var r2d = render2d.Renderer2D.init(boot_alloc);
    defer r2d.deinit();
    // Sized ONCE at boot and then locked, which is the whole point of `lock`:
    // the frame loop drops instances rather than growing a buffer, so a scene
    // edit cannot make the editor allocate mid-frame.
    r2d.reserve(sprite_budget) catch |err| {
        log.err("2D batcher reserve failed: {s}", .{@errorName(err)});
        return err;
    };
    r2d.lock();

    var lighting = lighting_driver.Driver.init(boot_alloc, .medium) catch |err| {
        log.err("lighting init failed: {s}", .{@errorName(err)});
        return err;
    };
    defer lighting.deinit();

    var fader = fade.Fader{};

    var particles = particles_sys.System.init(boot_alloc);
    defer particles.deinit();
    particles.reserve(.{
        .max_particles = 65_536,
        .max_emitters = 256,
        .max_per_emitter = 4096,
    }) catch |err| log.warn("particle pool reserve failed: {s}", .{@errorName(err)});

    var anim_system = ecs.animation.System.init(boot_alloc);
    defer anim_system.deinit();

    // ── Assets ──────────────────────────────────────────────────────────────
    var assets_registry = assets.AssetManager.init(boot_alloc, asset_slots, asset_budget_bytes) catch |err| {
        log.err("asset manager init failed: {s}", .{@errorName(err)});
        return err;
    };
    defer assets_registry.deinit();

    // ── File watchers ───────────────────────────────────────────────────────
    // Polled OUTSIDE the frame guard: reloading decodes, and decoding blocks
    // and allocates. An editor that pays for an artist's save inside the loop it
    // is measuring reports a frame time that no game will ever see.
    var config_watcher: ?platform.FileWatcher = platform.watchFile(boot_alloc, project.config.default_path) catch null;
    defer if (config_watcher) |*w| w.deinit();

    // The parsed config the watcher keeps fresh. Null when there is no
    // `project.config` beside the editor yet, which is a normal way to start a
    // project — not an error.
    const project_config: ?*project.config.Config = project.config.load(boot_alloc, project.config.default_path) catch null;
    defer if (project_config) |c| c.destroy(boot_alloc);

    // ── Frame loop ──────────────────────────────────────────────────────────
    var loop = core.loop.FixedLoop.init(fixed_dt);
    var limiter = core.loop.FrameLimiter.init(60, args.vsync);
    var view_w: f32 = @floatFromInt(window.fb_width);
    var view_h: f32 = @floatFromInt(window.fb_height);

    // Timer bridge for script timers.
    const timer_bridge = ecs.timer.SignalBridge{
        .ctx = &behaviors,
        .dispatch = struct {
            fn fire(ctx: ?*anyopaque, name: []const u8) void {
                const b: *script.Behaviors = @ptrCast(@alignCast(ctx.?));
                b.dispatchSignal(name);
            }
        }.fire,
    };

    var last_ns = core.time.monotonicNs();
    // ImGui's command count for the last frame drawn. Read inside the loop
    // because `drawCommands` needs a live ImGui frame — calling it in the
    // summary below asserts inside ImGui, since the frame is long over.
    var last_ui_cmds: usize = 0;
    // Tiles the TileMap panel pushed on the last frame.
    var tiles_pushed: usize = 0;
    while (true) {
        // Frame limiter
        const pacing = limiter.wait(core.time.monotonicNs());
        limiter.sleep(pacing.wait_ns);

        if (has_window) {
            window.poll();
            if (window.shouldClose()) break;
        }

        // Resize handling
        if (has_window) {
            const fb = window.framebufferSize();
            if (window.resized or target.width != fb.w or target.height != fb.h) {
                window.resized = false;
                renderer.resize(fb.w, fb.h);
                target = renderer.createOffscreenTarget(fb.w, fb.h);
                view_w = @floatFromInt(fb.w);
                view_h = @floatFromInt(fb.h);
            }
        }

        // Project config hot-reload
        if (config_watcher) |*w| {
            if (w.poll()) |changed| {
                if (changed) {
                    log.info("project.config changed, reloading...", .{});
                    if (project_config) |c| {
                        c.reload(boot_alloc, project.config.default_path) catch |err| {
                            log.warn("project.config reload failed: {s}", .{@errorName(err)});
                        };
                    }
                }
            } else |err| {
                log.warn("file watcher error: {s}", .{@errorName(err)});
            }
        }

        // The camera, and the lighting mask sized for it.
        //
        // BOTH of these allocate — the mask, the SDF, the EDT scratch — and both
        // must run before `tracker.beginFrame` below, which panics on any
        // allocation outside the frame arena. Putting them inside the frame is
        // how the editor used to die on its second frame with a 4 MiB
        // allocation complaint that pointed at lighting rather than at the
        // ordering mistake that caused it.
        const camera_view: ?ecs.camera.View = editorView(view_w, view_h);
        const fb_w: u32 = if (has_window) window.framebufferSize().w else @intFromFloat(view_w);
        const fb_h: u32 = if (has_window) window.framebufferSize().h else @intFromFloat(view_h);
        lighting.resize(lighting_driver.Driver.viewFor(camera_view, fb_w, fb_h)) catch |err| log.warn("lighting mask resize failed: {s}", .{@errorName(err)});

        // The toolbar writes the reactive store while ImGui is drew, so this
        // read sees the LAST frame's value — one frame of latency, which is what
        // a checkbox in a rendered toolbar has and what makes the value stable
        // for the whole frame that follows.
        const overlay = overlayOn(&ui_ctx, args.physics_debug);

        // M15 collision overlay: collect the collider quads HERE, next to the
        // lighting resize and for the same reason. `collect` reads the physics
        // world's live transforms (so a fast body does not ghost by one step)
        // and its buffer can grow, which is exactly what `tracker.beginFrame`
        // below forbids inside the frame. The quads are pushed into the 2D
        // batcher further down, where pushing costs no allocation at all.
        if (overlay) {
            physics_debug.collect(world, physics_sys.getWorld());
        }

        // A structural edit (spawn, undo, a tile painted into a new entity)
        // means new bodies. Rebuilt here rather than at the edit site because
        // the edit site is inside a frame.
        const entity_count = world.entityCount();
        if (entity_count != last_entity_count) {
            last_entity_count = entity_count;
            physics_dirty = true;
        }
        if (physics_dirty) {
            physics_dirty = false;
            physics_sys.syncLoad(world);
        }

        // The code pane's frame work is the one part of the overlay that
        // ALLOCATES: an edit re-lexes the document, and applying the pane's
        // pending requests grows its undo stack. It runs here, ahead of the
        // guard, and the `draw` inside the frame only reads the cache this
        // warmed. Re-lexing inside the guard is how the editor died on its
        // first keystroke with "allocation of 132 bytes outside the frame".
        if (has_window) {
            pane.handleInput(&window.input);
            pane.handleText(&window.input);
        }
        pane.applyRequests();
        _ = pane.tokens() catch {};

        // ── TileMap brush, OUTSIDE the frame ───────────────────────────────
        //
        // Painting can create a chunk, and a chunk is an append — an
        // allocation, which the guard below forbids. So the brush runs here and
        // only the resulting quads are pushed inside the frame.
        if (has_window and camera_view != null and !ui_ctx.wantsMouse()) {
            const m = window.input.mouse;
            const inside = m.x >= 0 and m.y >= 0 and m.x < @as(f32, @floatFromInt(fb_w)) and m.y < @as(f32, @floatFromInt(fb_h));
            const world_pos = camera_view.?.screenToWorld(.{ .x = m.x, .y = m.y });
            const tx: i32 = @intFromFloat(@floor(world_pos.x / tilemap.tile_size));
            const ty: i32 = @intFromFloat(@floor(world_pos.y / tilemap.tile_size));
            tilemap.hover = .{ tx, ty };

            if (m.buttons[0] and inside) {
                if (tilemap.drag_anchor == null) {
                    tilemap.drag_anchor = .{ tx, ty };
                    switch (tilemap.brush) {
                        .pencil, .eraser, .flood_fill, .picker => tilemap.paintAt(tx, ty, true) catch {},
                        else => {},
                    }
                } else switch (tilemap.brush) {
                    .pencil, .eraser => tilemap.paintAt(tx, ty, true) catch {},
                    else => {},
                }
            } else if (tilemap.drag_anchor != null) {
                // Released: a rectangle commits once, on the release edge.
                switch (tilemap.brush) {
                    .rect_fill, .rect_outline => tilemap.paintAt(tx, ty, true) catch {},
                    else => {},
                }
                tilemap.drag_anchor = null;
            }
        }

        // ── The allocation-guarded frame ───────────────────────────────────
        tracker.beginFrame(); // from here on: no allocations outside the arena
        frame_arena.beginFrame();

        // Real elapsed wall time, measured on the engine's own clock so the
        // simulation shares its notion of "now" with the profiler. The limiter's
        // wait is deliberately included: a fixed-step accumulator consumes wall
        // time, not "time we were not sleeping".
        const now_ns = core.time.monotonicNs();
        const frame_ns = now_ns - last_ns;
        last_ns = now_ns;
        const real_dt: f32 = @as(f32, @floatFromInt(frame_ns)) / std.time.ns_per_s;
        const steps = loop.addTime(real_dt);

        // ── Editor overlay: input, then widgets, then the code pane ───────
        ui_ctx.newFrame(real_dt);
        drawEditorUi(&ui_ctx, &pane, camera_view.?);
        tilemap.draw();
        pane.draw(&ui_ctx, real_dt);
        last_ui_cmds = ui_ctx.drawCommands();

        // ── Fixed-step simulation ──────────────────────────────────────────
        var s: u32 = 0;
        while (s < steps) : (s += 1) {
            behaviors.fixedUpdate(fixed_dt);
            particles.fixedUpdate(world, fixed_dt);
            anim_system.update(world, fixed_dt, timer_bridge);
            anim_system.applyRootMotion(world, fixed_dt);
            _ = physics_sys.step(world, fixed_dt);
            ecs.timer.tick(world, fixed_dt, timer_bridge);
        }

        // ── Variable-step ──────────────────────────────────────────────────
        behaviors.update(real_dt);
        behaviors.sweepDestroyed();
        behaviors.vm.gcStep();
        particles.beginFrame();
        world.signals.drain();

        // ── Render ─────────────────────────────────────────────────────────
        renderer.beginFrame();
        if (has_window) renderer.acquireSurface();

        // The scene must be OPEN before anything is drawn into it. The Dawn
        // backend's sprite emitter returns early when no scene is active, so an
        // editor that skipped this compiled, ran, and showed a black window
        // with zero draw calls — no error anywhere to point at the omission.
        renderer.beginScene(target, sceneCamera(camera_view, fb_w, fb_h));

        r2d.collectFiltered(
            world,
            loop.alpha(),
            render2d.ViewRect.around(
                camera_view.?.cx,
                camera_view.?.cy,
                camera_view.?.viewport_w / camera_view.?.zoom * 0.5,
                camera_view.?.viewport_h / camera_view.?.zoom * 0.5,
                64,
            ),
            null,
        );

        // Collision overlay: push the collected quads into the same batcher the
        // sprites use, so they cost one more instanced draw rather than a
        // second pipeline. They are pushed AFTER `collectFiltered` so the
        // overlay is never frustum-culled against a scene that moved under it.
        if (overlay) {
            for (physics_debug.quadSlice()) |q| {
                _ = r2d.pushInstance(.{
                    .pos = q.pos,
                    .half = q.half,
                    .uv = .{ 0, 0, std.math.maxInt(u16), std.math.maxInt(u16) },
                    .color = q.color,
                    .slot = debug_slot,
                    .shape = 0,
                    .layer = debug_layer,
                });
            }
        }

        const tiles = tilemap.pushTiles(&r2d);
        tiles_pushed = tiles;
        r2d.submit(renderer);

        // ── Lighting ───────────────────────────────────────────────────────
        const lighting_env = lighting_driver.Driver.environmentOf(world, defaultEnvironment());
        _ = lighting.render(world, &r2d, renderer, lighting_env, 0);

        // ── Editor overlay on top ──────────────────────────────────────────
        //
        // The pass handle is valid ONLY for the duration of this call: the
        // backend ends and submits the overlay pass as soon as it returns.
        // Holding one across a frame is exactly the "works until the next
        // resize" WebGPU bug, so the context is never stored.
        renderer.drawOverlay(&ui_ctx, struct {
            fn draw(ctx: ?*anyopaque, pass: ?*anyopaque) void {
                const c: *ui.Context = @ptrCast(@alignCast(ctx.?));
                c.render(pass);
            }
        }.draw);

        // Fader
        fader.update(real_dt);

        // Compose
        renderer.endScene(true, .Medium);
        renderer.present();

        // Close the frame: the arena drains and the tracker's allocation guard
        // is disarmed. Without `endFrame` the guard stays armed from the first
        // frame on, and the NEXT frame's `lighting.resize` — which allocates
        // the mask before `beginFrame` — would panic on a 4 MiB allocation
        // inside the zone §3.1 forbids.
        frame_arena.endFrame();
        tracker.endFrame();

        if (has_window) window.input.endFrame();

        frame_count += 1;
        if (args.frames != 0 and frame_count >= args.frames) break;
    }

    // A `--frames N` run that finished is a successful smoke test, so it says
    // what it drew rather than exiting silently: a CI log that prints nothing
    // cannot distinguish "worked" from "never started".
    if (args.frames != 0) {
        const st = renderer.stats();
        log.info("{d} frames, {d} draw calls, physics overlay: {d} bodies ({d} sensors), tiles: {d}, ui: {d} cmds", .{
            frame_count,
            st.draw_calls,
            physics_debug.stats.bodies_drawn,
            physics_debug.stats.sensors_drawn,
            tiles_pushed,
            last_ui_cmds,
        });
        log.info("tilemap panel drew {d} frames", .{tilemap_panel.Panel.draws});
    }
}

/// The reactive-store keys the editor's own UI keeps its state under.
///
/// Constants rather than literals at each use, so a rename is one line and a
/// typo is a compile error instead of a second, silently independent checkbox.
const ui_stores = struct {
    pub const physics_debug = "editor.physics_debug";
};

/// The editor's ImGui chrome.
///
/// Drawn with the engine's own `ui` module rather than raw ImGui calls, so a
/// theme change lands here and in the code pane at once — and so the editor
/// cannot drift into a look the rest of the tool does not share.
///
/// ## Why the store, and not `*Args`
///
/// The reactive store holds the editor's one piece of interactive state:
/// whether the collision overlay is on. A checkbox writes it by name and the
/// render path reads it by the same name, so the command line, the mouse and
/// the frame all see one value. Handing the toolbar a pointer to the frame
/// loop's args instead would be a second source of truth that drifts the first
/// time someone adds a panel.
fn drawEditorUi(ctx: *ui.Context, pane: *code_pane.Pane, view: ecs.camera.View) void {
    _ = pane;
    _ = view;

    // No closure wraps this: Zig has none, so a widget drawn inside a layout
    // body cannot reach a local of the caller's. The checkbox is drawn directly
    // against the context — the layout helpers are for panels that genuinely
    // need one, not for holding a variable the language cannot close over.
    var on = ui.reactive.getBool(&ctx.store, ui_stores.physics_debug, true);
    if (ui.toggle.checkbox(.{
        .ctx = ctx,
        .id = "editor.dbg",
        .label = "Physics debug",
        .value = &on,
    })) {
        ctx.store.set(ui_stores.physics_debug, bool, !on) catch {};
    }
}

/// Whether the overlay is on THIS frame. The toolbar writes the store; this is
/// the single read that decides it, which is what keeps the command line and
/// the mouse from ever disagreeing.
fn overlayOn(ctx: *ui.Context, initial: bool) bool {
    return ui.reactive.getBool(&ctx.store, ui_stores.physics_debug, initial);
}
