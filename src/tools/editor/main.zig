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
const editor_shell = @import("shell.zig");
const editor_state = @import("editor_state.zig");

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

/// The last frame's ImGui geometry: [draw lists, vertices, indices]. Written
/// inside the overlay callback (the only moment ImGui's draw data is valid) and
/// read by the `--frames` summary.
var ui_stats: [3]i32 = .{ 0, 0, 0 };

// ─── Arguments ───────────────────────────────────────────────────────────────

const Args = struct {
    project_path: []const u8 = ".",
    /// A scene document to open at boot. Empty means "keep the built-in demo
    /// scene", which is what an editor with no arguments opens onto.
    scene_path: []const u8 = "",
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
        } else if (std.mem.eql(u8, arg, "--scene")) {
            if (it.next()) |p| args.scene_path = p;
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

/// The editor's camera lives in `Editor.viewport` (pan, zoom, persistence);
/// main only asks for the view each frame — the same `ecs.camera.View` the
/// runtime would read from a project, so switching to a real camera component
/// later is a query, not a rewrite.

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
///
/// The pattern sits ABOVE the origin (the world's y grows up), where the demo
/// scene's floor is not, so the two never overlap and both read at a glance.
fn seedTilePattern(store: *tilemap_panel.Store) void {
    var y: i32 = 0;
    while (y < 4) : (y += 1) {
        var x: i32 = 0;
        while (x < 6) : (x += 1) {
            const tile: ecs.components.Tile = .{ .atlas_index = @intCast(1 + @mod(x + y * 6, 8)) };
            _ = store.setTile(x - 3, y, tile) catch {};
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
///
/// The layout is around the ORIGIN and compact, because the viewport opens
/// framed on the content: a scene spread over 800 units reads as a speck on
/// a big canvas, and a speck is not a first impression.
fn spawnDemoScene(world: *ecs.World) !void {
    const Transform = ecs.components.Transform;
    const Sprite = ecs.components.Sprite;
    const RigidBody2D = ecs.components.RigidBody2D;
    const Collider2D = ecs.components.Collider2D;

    // The floor. `body_type = 0` is fixed: it is the immovable green one.
    // It is BELOW the origin, because the world's y grows up.
    _ = try world.spawn(.{
        Transform{ .position = .{ .x = 0, .y = -120 }, .rotation = 0 },
        Sprite{ .size = .{ .x = 400, .y = 24 }, .tint = .{ 0.35, 0.37, 0.42, 1 } },
        RigidBody2D{ .body_type = 0 },
        Collider2D{ .size = .{ .x = 200, .y = 12 } },
    });

    // A box that falls. Orange while it moves, which is what makes the solver's
    // work visible: the overlay shows the body where the solver actually put it.
    _ = try world.spawn(.{
        Transform{ .position = .{ .x = -130, .y = 20 }, .rotation = 0 },
        Sprite{ .size = .{ .x = 32, .y = 32 }, .tint = .{ 0.9, 0.5, 0.2, 1 } },
        RigidBody2D{ .body_type = 2 },
        Collider2D{ .size = .{ .x = 16, .y = 16 } },
    });

    // A kinematic platform: moved by code, pushes the dynamic box, never falls.
    _ = try world.spawn(.{
        Transform{ .position = .{ .x = 100, .y = -40 }, .rotation = 0 },
        Sprite{ .size = .{ .x = 120, .y = 16 }, .tint = .{ 0.2, 0.7, 0.7, 1 } },
        RigidBody2D{ .body_type = 1 },
        Collider2D{ .size = .{ .x = 60, .y = 8 } },
    });

    // A sensor. Blue whatever it sits on: it detects, it never pushes, and that
    // is the one thing the overlay has to be able to show at a glance. It has
    // a sprite so it can be picked and dragged like anything else.
    _ = try world.spawn(.{
        Transform{ .position = .{ .x = -130, .y = -95 }, .rotation = 0 },
        Sprite{ .size = .{ .x = 48, .y = 8 }, .tint = .{ 0.25, 0.45, 0.9, 0.85 } },
        RigidBody2D{ .body_type = 2 },
        Collider2D{ .size = .{ .x = 24, .y = 4 }, .is_sensor = true },
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

    // ── Editor ───────────────────────────────────────────────────────────────
    // The editor owns the shell's state, not the tools: `main` keeps the tile
    // panel and the code pane because their frame work (painting, lexing)
    // happens outside the no-allocation guard, next to the world they edit.
    var editor = editor_state.Editor.init(boot_alloc, &session_model);
    defer editor.deinit();
    editor.tilemap = &tilemap;
    editor.pane = &pane;
    // The asset browser's Owner pointer. It cannot be set inside `init`
    // because an init returns a copy; the browser double-clicks back into this
    // editor's queued Open act, and that act belongs to this address.
    editor.assets.editor = &editor;
    // Launched on a file: show the file. The Scene tab is the default for a
    // project, and the Script tab is the only useful view for `--project x.lua`.
    if (pane_owned != null) editor.workspace = .script;
    // Launched on a scene: open it through the same deferred path the File menu
    // uses, so boot and a menu click cannot diverge (and so the load happens
    // outside the frame guard, where replacing a world is allowed).
    if (args.scene_path.len > 0) {
        editor.setSceneFile(args.scene_path);
        editor.requestOpen();
    }
    // A paint stroke is an edit: the document is now different on screen from
    // the one on disk, and the tab strip has to say so. The callback exists
    // because the panel is a value in `main` and the dirty flag lives in the
    // editor — and a global would be a second source of truth.
    tilemap.on_edit = markTileEdit;
    tilemap.edit_ctx = &editor;

    // A recovery file newer than the scene is work a crash left behind. The
    // editor says so at boot rather than silently taking it: the user may
    // prefer the file on disk, and the difference is theirs to judge.
    if (editor.autosave_recoverable) {
        editor.log(.warn, "unsaved work was recovered from {s} — File → Recover to restore it", .{
            editor.autosavePath(),
        });
    }

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
    // The Play bridge: beginPlay calls `startAll` so actor `start`s run the
    // moment Play begins. Set here rather than in `Editor.init` because the
    // behaviors did not exist yet — same reason as `editor.assets.editor`.
    editor.behaviors = &behaviors;

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

    // The editor's render bridge: what turns a browser click into pixels.
    // Created AFTER both of its owners exist; the addresses here (`renderer`,
    // `assets_registry`) hold for the whole run, which is what a pointer the
    // editor dereferences every spawn needs to be true.
    var asset_bridge = editor_state.RenderBridge{ .renderer = &renderer, .assets = &assets_registry };
    editor.bridge = &asset_bridge;

    // ── File watchers ───────────────────────────────────────────────────────
    // Polled OUTSIDE the frame guard: reloading decodes, and decoding blocks
    // and allocates. An editor that pays for an artist's save inside the loop it
    // is measuring reports a frame time that no game will ever see.
    var config_watcher: ?platform.FileWatcher = platform.watchFile(boot_alloc, project.config.default_path) catch null;
    defer if (config_watcher) |*w| w.deinit();

    // The scene file's watcher, for the hot reload. It is re-armed when the
    // open scene changes, so the path it watches is kept here next to it.
    var scene_watcher: ?platform.FileWatcher = null;
    defer if (scene_watcher) |*w| w.deinit();
    var watched_scene_path: [256]u8 = undefined;
    var watched_scene_path_len: usize = 0;

    // The parsed config the watcher keeps fresh. Null when there is no
    // `project.config` beside the editor yet, which is a normal way to start a
    // project — not an error.
    const project_config: ?*project.config.Config = project.config.load(boot_alloc, project.config.default_path) catch null;
    defer if (project_config) |c| c.destroy(boot_alloc);

    // ── Global scripts from the config ───────────────────────────────────
    // The `scripts { global "..." }` section, mounted before the first frame
    // exactly like the runtime mounts them. Same one-file-one-try policy: a
    // bad path is a logged skip, not a dead editor.
    if (project_config) |c| {
        for (c.scripts.global) |path| {
            const io = std.Io.Threaded.global_single_threaded.io();
            const bytes = std.Io.Dir.cwd().readFileAlloc(io, path, boot_alloc, .limited(assets.script_asset.default_max_bytes)) catch {
                log.warn("global script '{s}': file not found, skipping it", .{path});
                continue;
            };
            defer boot_alloc.free(bytes);
            const v = assets.script_asset.validate(bytes, assets.script_asset.default_max_bytes) catch |err| {
                log.warn("global script '{s}' rejected ({s}), skipping it", .{ path, @errorName(err) });
                continue;
            };
            const name = if (std.mem.lastIndexOfScalar(u8, path, '/')) |slash| path[slash + 1 ..] else path;
            const id = behaviors.loadGlobal(name, v.source) catch |err| {
                log.warn("global script '{s}' failed to compile ({s})", .{ path, @errorName(err) });
                continue;
            };
            behaviors.attachGlobal(id) catch |err| {
                log.warn("global script '{s}' failed to mount ({s})", .{ path, @errorName(err) });
            };
        }
        // Idempotent: any already-started actors are skipped; the globals just
        // mounted are the only ones whose `start` runs here.
        behaviors.startAll();
    }

    // ── Frame loop ──────────────────────────────────────────────────────────
    var loop = core.loop.FixedLoop.init(fixed_dt);
    // The game clock: the global time scale, shared by the simulation, the
    // scripts and the `time.*` bindings. The editor's own Play/Stop/Step is a
    // SEPARATE switch — it decides whether the world runs at all — while the
    // scale decides how fast it runs when it does. A script that calls
    // `time.pause()` in Play mode therefore freezes the world without
    // confusing the editor's own paused state.
    var game_time = core.loop.GameTime.init(fixed_dt);
    behaviors.ctx.time = &game_time;
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

        // ── Scene hot-reload ────────────────────────────────────────────────
        //
        // The scene file is watched so a change made OUTSIDE the editor (a
        // merge, a generator, a second instance) is noticed instead of being
        // silently overwritten by the next save.
        //
        // The editor does not reload on the spot: a reload replaces the world,
        // and the user may have unsaved work. The change is recorded, the
        // console says so, and File → Reload takes it.
        //
        // The watcher is polled OUTSIDE the frame guard (a poll is a syscall,
        // and the frame may not do work that blocks) and the reload itself is
        // a queued act, because replacing a world allocates.
        if (editor.hot_reload_enabled) {
            // The watched path follows the open scene: opening another file
            // means watching another file.
            const watched = editor.scenePath();
            if (!std.mem.eql(u8, watched, watched_scene_path[0..watched_scene_path_len])) {
                if (scene_watcher) |*old| old.deinit();
                scene_watcher = platform.watchFile(boot_alloc, watched) catch |err| blk: {
                    log.warn("cannot watch {s}: {s}", .{ watched, @errorName(err) });
                    break :blk null;
                };
                @memcpy(watched_scene_path[0..watched.len], watched);
                watched_scene_path_len = watched.len;
            }
            if (scene_watcher) |*w| {
                if (w.poll()) |changed| {
                    if (changed) {
                        // The editor's own save also trips the watcher. The
                        // mtime check is what tells the two apart: the editor
                        // records the mtime when it saves, and a change to a
                        // DIFFERENT mtime is somebody else.
                        const io = std.Io.Threaded.global_single_threaded.io();
                        const st = std.Io.Dir.cwd().statFile(io, watched, .{}) catch {
                            continue;
                        };
                        if (st.mtime.nanoseconds != editor.scene_mtime_ns) {
                            editor.notifySceneChanged();
                        }
                    }
                } else |err| {
                    log.warn("scene watcher error: {s}", .{@errorName(err)});
                }
            }
        }

        // The layout, and with it the region the scene is drawn in.
        //
        // The layout is computed HERE, before the frame, and not inside the
        // shell's draw: the camera shows the viewport's rectangle and the
        // pointer is measured from that rectangle's origin, so both need the
        // numbers before the pointer is read. The shell draws the same
        // numbers (it is handed them), which is what keeps the docks and the
        // viewport from disagreeing about where the scene is.
        const geom = editor_shell.layout(&editor, view_w, view_h);
        editor.viewport.region = geom.centerRect();

        // The camera, and the lighting mask sized for it.
        //
        // BOTH of these allocate — the mask, the SDF, the EDT scratch — and both
        // must run before `tracker.beginFrame` below, which panics on any
        // allocation outside the frame arena. Putting them inside the frame is
        // how the editor used to die on its second frame with a 4 MiB
        // allocation complaint that pointed at lighting rather than at the
        // ordering mistake that caused it.
        const camera_view: ?ecs.camera.View = editor.viewport.cameraView(view_w, view_h);
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
        // allocation, which the guard below forbids. So the brush runs here
        // and only the resulting quads are pushed inside the frame. It owns
        // left-click only while the Tiles tool is up: the cursor tool's
        // picking and gizmos share the same button and must not paint.
        if (has_window and camera_view != null and !ui_ctx.wantsMouse() and
            editor.viewport.tool == .tile)
        {
            const m = window.input.mouse;
            // The brush belongs to the VIEWPORT, so the pointer has to be
            // over the viewport: a click on the console is not a tile.
            const inside = editor.viewport.region.contains(.{ .x = m.x, .y = m.y });
            const world_pos = camera_view.?.targetToWorld(.{ .x = m.x, .y = m.y });
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

        // ── Viewport interaction ───────────────────────────────────────────
        //
        // The cursor tool's picking and gizmo drags. Pointer reads here, and
        // writes through the queued set — which preFrame below turns into
        // world state the render this very frame will show. A drag that
        // started in the scene follows the pointer even over the docks, so
        // everything above stays the authority it claims to be.
        if (has_window) {
            editor.viewport.update(&editor, window.input.mouse, &ui_ctx, fb_w, fb_h);
        }

        // A completed gizmo drag moved collider hosts while the simulation was
        // not stepping them: the physics overlay and the bodies must follow
        // the transform, not trail it. Playing worlds step on their own.
        // Same tool hygiene: the tile hover marker is a Tiles-tool thing.
        if (editor.viewport.takeEdited() and editor.play == .stopped) physics_dirty = true;
        if (editor.viewport.tool != .tile) tilemap.hover = null;

        // ── Editor pre-frame (queued edits, asset refresh, scene replace) ─────
        editor.preFrame();
        if (editor.should_quit) break;
        if (editor.takeSceneReplaced()) {
            physics_dirty = true;
            // A new scene is a new set of contents: the viewport frames them
            // again, unless the user has already taken the camera somewhere
            // of their own.
            if (!editor.viewport.camera_touched) editor.viewport.needs_frame = true;
        }

        // ── Autosave ───────────────────────────────────────────────────────
        //
        // The TIMER runs here (it is a float, no allocation) and the WRITE is
        // queued: encoding a world allocates megabytes, and the frame's
        // allocation guard forbids that inside the frame. The queued act runs
        // in the next `preFrame`, on the safe side.
        _ = editor.tickAutosave(editor.frame_dt);

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
        // The status bar reads the same number the simulation does, so "60 fps"
        // in the corner and the fixed-step accumulator cannot disagree.
        editor.frame_dt = real_dt;
        const steps = loop.addTime(game_time.beginFrame(real_dt));

        // ── Editor overlay ─────────────────────────────────────────────────
        // ONE call: the shell owns every panel, including the code pane and the
        // tilemap tool. Drawing them here as well is what used to put two
        // copies of each window on screen.
        ui_ctx.newFrame(real_dt);
        editor_shell.draw(&editor, &ui_ctx, fb_w, geom);

        // The viewport's gizmo: the selection, the handles and the hover
        // ghost. Drawn on ImGui's BACKGROUND list, so it is over the scene
        // (the overlay pass runs after the scene is resolved) and under the
        // panels.
        if (editor.workspace == .scene) {
            editor.viewport.drawOverlay(&editor, &ui_ctx);
            // The marquee is drawn on the same list: it is the selection that
            // does not exist yet.
            editor.viewport.drawMarquee(&ui_ctx);
        }

        // The viewport's HUD: the tools, the gizmo modes, the toggles and the
        // readouts. It lives INSIDE the viewport region, so it never covers a
        // dock.
        editor.viewport.drawHud(&ui_ctx);

        // ── Fixed-step simulation ──────────────────────────────────────────
        // The Play menu is not decoration: stopped means the world does not
        // move, paused means exactly the steps the user asked for with Step.
        // The accumulator's leftover time is kept either way, so resuming does
        // not replay the pause as a burst.
        var steps_to_run = steps;
        switch (editor.play) {
            .stopped => steps_to_run = 0,
            .paused => steps_to_run = if (editor.takeStep()) 1 else 0,
            .playing => {},
        }
        var s: u32 = 0;
        while (s < steps_to_run) : (s += 1) {
            // The interpolation snapshot, first: `prev_*` is what the renderer
            // blends from, so it must be captured before anything writes a
            // transform this tick.
            world.captureTransforms();
            // The tweens, before the behaviors: a script reads the tweened
            // value in the same tick it was written.
            behaviors.tickTweens(fixed_dt);
            behaviors.fixedUpdate(fixed_dt);
            particles.fixedUpdate(world, fixed_dt);
            anim_system.update(world, fixed_dt, timer_bridge);
            anim_system.applyRootMotion(world, fixed_dt);
            _ = physics_sys.step(world, fixed_dt);
            ecs.timer.tick(world, fixed_dt, timer_bridge);
        }

        // ── Variable-step ──────────────────────────────────────────────────
        // The SCALED delta, the same one the accumulator got: a script must
        // not move faster than the world it is in.
        if (editor.simulationEnabled()) behaviors.update(game_time.delta);
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

        // The editor grid: layer 0, pushed FIRST — the batcher's stable sort
        // keeps insertion order inside a layer, so the grid sits under every
        // sprite drawn after it, on the same single-pass instance stream.
        editor.viewport.pushUnderlay(&r2d);

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

        // Fader
        fader.update(real_dt);

        // Compose. `endScene` is what resolves the scene (SMAA included) into
        // the swapchain, so everything that has to appear ON TOP of it must be
        // drawn after this line. The overlay used to be submitted before it,
        // and the UI was therefore painted over by the scene every frame: the
        // draw data was real (thousands of vertices per frame) and nothing was
        // on screen.
        renderer.endScene(true, .Medium);

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
                // Measured HERE, because ImGui's draw data is only valid
                // between Render() and the next NewFrame(). The summary reads
                // what this frame actually submitted, not what was queued.
                ui.cimgui.ember_ui_draw_stats(&ui_stats);
            }
        }.draw);

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
        log.info("{d} frames, {d} entities, {d} draw calls, physics overlay: {d} bodies ({d} sensors), tiles: {d}, ui: {d} verts", .{
            frame_count,
            world.entityCount(),
            st.draw_calls,
            physics_debug.stats.bodies_drawn,
            physics_debug.stats.sensors_drawn,
            tiles_pushed,
            ui_stats[1],
        });
        log.info("tilemap panel drew {d} frames", .{tilemap_panel.Panel.draws});
    }
}

/// The tilemap panel's edit callback: mark the editor's document dirty.
fn markTileEdit(ctx: ?*anyopaque) void {
    const ed: *editor_state.Editor = @ptrCast(@alignCast(ctx.?));
    ed.dirty = true;
}

// Pull the panels' `test` blocks into the tools' test binary. A test build's
// root file must reference a file for its tests to be collected; these are
// imported anyway by the real program, but the reference alone is not the
// trigger — one comptime touch per file is.
test {
    _ = @import("editor_state.zig");
    _ = @import("tilemap_panel.zig");
    _ = @import("asset_browser.zig");
    _ = @import("hierarchy.zig");
    _ = @import("console.zig");
    _ = @import("inspector.zig");
    _ = @import("viewport.zig");
    _ = @import("prefab.zig");
}

/// The reactive-store keys the editor's own UI keeps its state under.
///
/// Constants rather than literals at each use, so a rename is one line and a
/// typo is a compile error instead of a second, silently independent checkbox.
const ui_stores = struct {
    pub const physics_debug = "editor.physics_debug";
};

/// Whether the overlay is on THIS frame. The View menu writes the store; this
/// is the single read that decides it, which is what keeps the command line and
/// the mouse from ever disagreeing.
fn overlayOn(ctx: *ui.Context, initial: bool) bool {
    return ui.reactive.getBool(&ctx.store, ui_stores.physics_debug, initial);
}
