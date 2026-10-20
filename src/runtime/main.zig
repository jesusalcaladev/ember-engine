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
const physics = engine.physics;
const core = engine.core;
const platform = engine.platform;
const render = engine.render;
const render2d = engine.render2d;
/// M7: the lighting driver. The one owner of the mask, the shadow channels and
/// the GI pyramid — see the note where it is constructed.
const lighting_driver = engine.lighting_driver;
/// M9: the scene-transition fader.
const fader_mod = engine.fade;
/// M14: CanvasModulate — the full-screen tint.
const tint_mod = engine.tint;
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
const assets = engine.assets;
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

/// Where a project's `.anim` clips live, relative to the project root. The same
/// convention `audio_asset_dir` follows, for the same reason: the runtime is
/// launched FROM the project root, so a path a script spells
/// (`anim.load("assets/animations/run.anim")`) is exactly the path the boot
/// preload walked — which is what makes the GUID handle agree.
const animation_asset_dir = "assets/animations";

/// Where a project's sprite images live, relative to the project root. The same
/// convention again, and for a sharper reason than the others: `HotReload` keys
/// its watch list on the exact path string, and the atlas keys its rects on the
/// exact path string. A script that spells the path one way and a watcher that
/// derives it another would pack a second copy AND reload nothing.
const image_asset_dir = "assets/sprites";

/// How many changed entries one poll may report. A `git checkout` of the sound
/// directory touches every file in it; the watcher truncates past this and the
/// poll reports the rest on the next frame, which is harmless because a reload
/// is idempotent.
const audio_watch_capacity = 16;

/// The image watcher's capacity. Separate constant, same contract: a checked-out
/// sprite folder is a burst, and a reload is idempotent so truncation is fine.
const image_watch_capacity = 16;

/// Side of the sprite atlas, in texels. 2048² RGBA8 is 16 MB — the M6 per-page
/// budget — and it is the SAME 2048 the Lua binding uses, on purpose: the binding
/// and the reload sink must hand images to one atlas, not two.
const atlas_side: u32 = 2048;

/// M14: the default UI font, loaded at boot when present. It is the vendored
/// test typeface (`libs/fonts.commit` pins it); a project that wants its own
/// default calls `ui.font_load` and `ui.set_font`. A missing file is NOT an
/// error — a UI with no glyphs is still a UI, and the log says so.
const default_font_path = "libs/fonts/Inter-Regular.ttf";
/// Pixel height the default font rasterizes at. 20 reads comfortably at 720p
/// and matches every UI test in the render suite.
const default_font_px: f32 = 20;

/// M14: the runtime's owner for the game UI — the font cache and the frame's
/// resolved `ui_system.State`.
///
/// One owner serves both vtables that need UI state: `ui_draw.FontSource`
/// (which font a widget's id resolves to) and `script.context.UiHooks`
/// (`measure`/`font_load` and the hover/press queries). They must see the SAME
/// cache and the SAME frame, so they point at one `UiRuntime`. It is
/// module-scope so its hook functions can name its type; the runtime builds
/// exactly one instance.
const UiRuntime = struct {
    allocator: std.mem.Allocator,
    /// Kept so a font loaded later can attach its own glyph atlas. By value
    /// because `Renderer` is a vtable-plus-pointer handle, like `Context.renderer`.
    renderer: render.Renderer,
    entries: [max_fonts]?Entry = [_]?Entry{null} ** max_fonts,
    /// Number of id slots in use. Id 0 is RESERVED for the default font even
    /// when it failed to load, so `ui.font_load` ids never collide with "the
    /// default".
    count: usize = 0,
    /// The frame's resolved widgets, hover and press state. Written by
    /// `ui_system.update`, read by `ui_draw` and the query hooks.
    state: ecs.ui_system.State = .{},

    /// 16 faces/sizes is more than a HUD needs and keeps the table tiny.
    const max_fonts = 16;
    /// Longest path remembered for `ui.font_load` de-duplication.
    const max_path = 192;
    /// Each font's glyph page. 1024² RGBA8 is 4 MB; the sprite atlas is 2048².
    const font_atlas_side = 1024;

    const Entry = struct {
        handle: *render.font.Font,
        pixel_height: f32,
        path_len: u16 = 0,
        path: [max_path]u8 = [_]u8{0} ** max_path,

        fn sameRequest(self: *const Entry, path: []const u8, px: f32) bool {
            if (self.pixel_height != px) return false;
            const n = @min(path.len, max_path);
            if (self.path_len != n) return false;
            return std.mem.eql(u8, self.path[0..n], path[0..n]);
        }
    };

    fn init(allocator: std.mem.Allocator, renderer: render.Renderer) UiRuntime {
        return .{ .allocator = allocator, .renderer = renderer };
    }

    fn deinit(self: *UiRuntime) void {
        for (self.entries[0..self.count]) |e| {
            const entry = e orelse continue;
            entry.handle.deinit();
            self.allocator.destroy(entry.handle);
        }
        self.count = 0;
    }

    /// The `Font` for a widget's `font` id, or null. Ids are their index in
    /// `entries`, so 0 is the default font when it loaded and null when it did
    /// not (drawing then falls back to nothing rather than to garbage).
    fn fontFor(self: *UiRuntime, id: u32) ?*render.font.Font {
        if (id >= self.count) return null;
        const entry = self.entries[id] orelse return null;
        return entry.handle;
    }

    /// Builds a `Font` from `bytes`, attaches its glyph atlas, and stores it.
    /// Returns the new id (its index) or null when the table is full or the
    /// bytes are not a font.
    fn add(self: *UiRuntime, path: []const u8, bytes: []const u8, px: f32) ?u32 {
        if (self.count >= max_fonts) return null;
        const handle = self.allocator.create(render.font.Font) catch return null;
        handle.* = render.font.Font.init(self.allocator, bytes, px) catch {
            self.allocator.destroy(handle);
            return null;
        };
        // A headless backend has no atlas; `attachAtlas` declines and the font
        // keeps its CPU metrics, so `measure` still works and drawing does not.
        handle.attachAtlas(self.renderer, font_atlas_side) catch {};

        const idx = self.count;
        var entry = Entry{ .handle = handle, .pixel_height = px };
        const n = @min(path.len, max_path);
        @memcpy(entry.path[0..n], path[0..n]);
        entry.path_len = @intCast(n);
        self.entries[idx] = entry;
        self.count += 1;
        return @intCast(idx);
    }

    /// Reads a `.ttf` and adds it, or returns an existing id for the same
    /// (path, pixel_height). Reads a file, so this is a load-time call, not a
    /// per-frame one.
    fn fontLoad(self: *UiRuntime, path: []const u8, px: f32) ?u32 {
        if (px <= 0 or path.len == 0) return null;
        for (self.entries[0..self.count], 0..) |e, i| {
            const entry = e orelse continue;
            if (entry.sameRequest(path, px)) return @intCast(i);
        }
        const bytes = readFileAlloc(self.allocator, path) catch return null;
        defer self.allocator.free(bytes);
        return self.add(path, bytes, px);
    }

    /// The engine default: `path` at `px`, if it exists. Id 0 either way, so a
    /// widget's default `font = 0` stays meaningful and `ui.font_load` hands out
    /// ids from 1.
    fn loadDefault(self: *UiRuntime, path: []const u8, px: f32) void {
        const bytes = readFileAlloc(self.allocator, path) catch |err| {
            log.info("no default UI font ({s} at '{s}'); ui.font_load can still add one", .{ @errorName(err), path });
            self.count = @max(self.count, 1);
            return;
        };
        defer self.allocator.free(bytes);
        if (self.add(path, bytes, px) == null) {
            log.warn("default UI font '{s}' could not be built", .{path});
            self.count = @max(self.count, 1);
        }
    }

    // ── The `UiHooks` function pointers (see `script.context.UiHooks`) ────────

    fn hookMeasure(ctx: ?*anyopaque, font_id: u32, text: []const u8, out: *[2]f32) bool {
        const self: *UiRuntime = @ptrCast(@alignCast(ctx.?));
        const font = self.fontFor(font_id) orelse return false;
        out[0] = font.measure(text);
        out[1] = font.lineHeight();
        return true;
    }

    fn hookFontLoad(ctx: ?*anyopaque, path: []const u8, px: f32) u32 {
        const self: *UiRuntime = @ptrCast(@alignCast(ctx.?));
        return self.fontLoad(path, px) orelse 0;
    }

    fn hookHovered(ctx: ?*anyopaque, entity_bits: u64) bool {
        const self: *UiRuntime = @ptrCast(@alignCast(ctx.?));
        const hot = self.state.hot orelse return false;
        return hot.bits() == entity_bits;
    }

    fn hookPressed(ctx: ?*anyopaque, entity_bits: u64) bool {
        const self: *UiRuntime = @ptrCast(@alignCast(ctx.?));
        const active = self.state.active orelse return false;
        return active.bits() == entity_bits;
    }

    /// The `ui_draw.FontSource` that resolves a widget's font id against this
    /// cache.
    fn fontSource(self: *UiRuntime) render.ui_draw.FontSource {
        return .{
            .ctx = self,
            .get = struct {
                fn get(ctx: ?*anyopaque, id: u32) ?*render.font.Font {
                    const runtime: *UiRuntime = @ptrCast(@alignCast(ctx.?));
                    return runtime.fontFor(id);
                }
            }.get,
        };
    }
};

/// Reads a whole file, with the 8 MiB limit the font tests use: a `.ttf` bigger
/// than that is not a font anyone wants rasterized at runtime.
fn readFileAlloc(allocator: std.mem.Allocator, path: []const u8) ![]u8 {
    const io = std.Io.Threaded.global_single_threaded.io();
    return std.Io.Dir.cwd().readFileAlloc(io, path, allocator, .limited(8 << 20));
}

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
    /// The scene to load: a `.zson` file, relative to the project root. Empty
    /// = the built-in canonical scene.
    scene: []const u8 = "",
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
        } else if (std.mem.eql(u8, arg, "--scene")) {
            if (it.next()) |v| args.scene = v;
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

/// Polls the sprite directory and hands each changed name to the reload manager,
/// which decodes it and drives the atlas through the `render.asset_reload` sink.
///
/// The filter is a prediction, not a promise: `isImageAsset` names the extensions
/// `import.detect` will accept, so a name that passes is one the reload can
/// actually classify. Names it rejects (a `.swp`, a `.pak`) are dropped here
/// instead of taking a `stat` and a `readFileAlloc` to be discarded one layer
/// down.
///
/// A watched path that is NOT in the manager's list reloads nothing — that is the
/// intended outcome, not a gap: only images a script has packed into the atlas
/// are registered (`sprite.set_image` does it), and an image nothing has drawn has
/// no rect to update. Editing one is a no-op until it is first set.
fn reloadChangedImages(hot: *assets.HotReload, watcher: *platform.DirectoryWatcher) void {
    var names: [image_watch_capacity][]const u8 = undefined;
    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const n = watcher.pollNames(&names);
    for (names[0..n]) |name| {
        if (!platform.isImageAsset(name)) continue;
        const path = std.fmt.bufPrint(&path_buf, "{s}/{s}", .{ image_asset_dir, name }) catch continue;
        // `reloadPath` runs the callback SYNCHRONOUSLY, and that callback does the
        // GPU upload — so this returns only once the new pixels are in the
        // texture. There is no second step to forget.
        _ = hot.reloadPath(path) catch |err| {
            log.warn("image reload of {s} failed: {s}", .{ path, @errorName(err) });
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

// ── Global scripts ───────────────────────────────────────────────────────
// The `scripts { global "..." }` section of `project.config`: Lua scripts
// mounted with NO actor (the game manager, the score, the spawner). One
// mount per listed path, in file order — file order is start order, so list
// the manager before the scripts that read it.

/// Reads, compiles and mounts every global script in the section. Each path
/// is relative to the project root (the same paths as `audio.play_file`),
/// validated like every other script the engine loads (BOM strip included),
/// and mounted under its file's BASENAME: `scripts/globals/game.lua` is
/// `globals.get("game")` from any script, with no path in the Lua surface.
///
/// A failure is logged and skipped, one script at a time: a typo in one file
/// costs that one manager this session, not the boot. This matches how a
/// behavior's compile error is a logged line, never a dead frame.
fn mountGlobalScripts(
    behaviors: *script.Behaviors,
    cfg: *const project.config.Config,
    alloc: std.mem.Allocator,
) void {
    for (cfg.scripts.global) |path| {
        // One async-io handle for the whole section: boot-time file reads,
        // where the threaded engine costs nothing this early.
        const io = std.Io.Threaded.global_single_threaded.io();
        const bytes = std.Io.Dir.cwd().readFileAlloc(io, path, alloc, .limited(assets.script_asset.default_max_bytes)) catch {
            log.warn("global script '{s}': file not found, skipping it", .{path});
            continue;
        };
        defer alloc.free(bytes);
        const v = assets.script_asset.validate(bytes, assets.script_asset.default_max_bytes) catch |err| {
            log.warn("global script '{s}' rejected ({s}), skipping it", .{ path, @errorName(err) });
            continue;
        };
        // The basename resolves the mount name: no '/'. survives into Lua.
        const name = if (std.mem.lastIndexOfScalar(u8, path, '/')) |slash| path[slash + 1 ..] else path;
        const id = behaviors.loadGlobal(name, v.source) catch |err| {
            log.warn("global script '{s}' failed to compile ({s})", .{ path, @errorName(err) });
            continue;
        };
        behaviors.attachGlobal(id) catch |err| {
            log.warn("global script '{s}' failed to mount ({s})", .{ path, @errorName(err) });
        };
    }
    // `startAll` is idempotent — the actors already started; this runs `start`
    // for exactly the globals that mounted above. Called here instead of
    // inside the loop so a global's first call is never half..scheduled.
    behaviors.startAll();
}

/// Loads a scene file and the behaviors its actors run.
///
/// THE ID CONTRACT: the `scripts { behavior "..." }` list's ORDER is the id.
/// A scene file says `Script {script: 1}`, and "1" is the FIRST entry of that
/// list; `0` means "no script", the same convention the component documents.
/// The scene file stays free of paths — the PROJECT decides what "script 1"
/// means, the scene decides that an actor runs it.
///
/// A failure is logged and skipped, one piece at a time: a scene that does not
/// load costs the game its scene, not its boot.
fn loadScene(
    behaviors: *script.Behaviors,
    world: *ecs.World,
    physics_sys: *physics.System,
    scene_path: []const u8,
    alloc: std.mem.Allocator,
) void {
    // 1. The scene itself.
    const io = std.Io.Threaded.global_single_threaded.io();
    const text = std.Io.Dir.cwd().readFileAlloc(io, scene_path, alloc, .limited(64 * 1024 * 1024)) catch |err| {
        log.warn("scene '{s}': {s}", .{ scene_path, @errorName(err) });
        return;
    };
    defer alloc.free(text);
    // `replace`, not `apply`: `apply` is the PREFAB applier (it patches an
    // existing world by name), and `replace` rebuilds the world from the
    // document IN PLACE — the address does not move, so every subsystem that
    // holds a `*World` keeps a valid pointer.
    ecs.zson.replace(world, text) catch |err| {
        log.warn("scene '{s}': {s}", .{ scene_path, @errorName(err) });
        return;
    };
    log.info("scene '{s}': {d} entities", .{ scene_path, world.entityCount() });

    // The bodies the scene declares become SOLVER bodies. Without this the
    // colliders are data and nothing simulates: the physics is a separate
    // system and it has to be told what exists.
    physics_sys.syncLoad(world);

    // 3. The behaviors: every entity that carries a `Script` component.
    var q = world.query(.{components.Script});
    while (q.nextBatch()) |batch| {
        const scripts = batch.slice(components.Script);
        const entities = batch.entitySlice();
        for (scripts, entities) |*sc, e| {
            const index = sc.script;
            const id = behaviors.behaviorIdAt(index) orelse {
                log.warn("entity {d} wants script {d}, which the project does not declare", .{ e.index, index });
                continue;
            };
            behaviors.attach(e, id) catch |err| {
                log.warn("entity {d}: script {d} failed to attach ({s})", .{ e.index, index, @errorName(err) });
            };
        }
    }
    // The behaviors' `start` runs here, after every actor is attached, so a
    // script can already see the whole scene.
    behaviors.startAll();
}

/// The `scripts { behavior "..." }` section: the behaviors an actor can run.
///
/// Loaded at BOOT, not with the scene: a project may have behaviors and no
/// scene (the built-in canonical one), and `actor.spawn` needs the table even
/// when nothing was loaded from disk.
///
/// The list's ORDER is the id: the first entry is script 1, and that is what a
/// scene file's `Script {script: 1}` and a script's `actor.spawn(x, y,
/// { script = 1 })` both mean. The ids live in the behaviors, so the scene
/// loader and the spawn path cannot disagree about what "script 1" is.
fn loadBehaviorScripts(
    behaviors: *script.Behaviors,
    cfg: *const project.config.Config,
    alloc: std.mem.Allocator,
) void {
    for (cfg.scripts.behavior, 0..) |path, i| {
        const io = std.Io.Threaded.global_single_threaded.io();
        const bytes = std.Io.Dir.cwd().readFileAlloc(io, path, alloc, .limited(assets.script_asset.default_max_bytes)) catch {
            log.warn("behavior script '{s}': file not found, skipping it", .{path});
            continue;
        };
        defer alloc.free(bytes);
        const v = assets.script_asset.validate(bytes, assets.script_asset.default_max_bytes) catch |err| {
            log.warn("behavior script '{s}' rejected ({s}), skipping it", .{ path, @errorName(err) });
            continue;
        };
        const id = behaviors.load(path, v.source) catch |err| {
            log.warn("behavior script '{s}' failed to compile ({s})", .{ path, @errorName(err) });
            continue;
        };
        // 1-based: 0 means "no script" in the component and in the spawn
        // options, and a list that starts at 0 would make the first entry
        // unreachable.
        behaviors.setBehaviorId(@intCast(i + 1), id);
    }
    if (behaviors.behaviorCount() != 0) {
        log.info("behaviors: {d} script(s) declared", .{behaviors.behaviorCount()});
    }
}

/// How many actors a script may SPAWN before the world runs out of slots.
///
/// A reservation, not a limit: the slots are capacity, and a script that
/// spawns past it gets the frame guard's panic — which is the engine's
/// standing answer to "you allocated in the frame". A game that needs more
/// raises this.
const spawn_reserve = 4096;

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

    // ── The game clock: the global time scale, and the `time.*` surface ──────
    //
    // The ONE owner of the scale. The simulation, the scripts and the Lua
    // bindings all read it from here, so they cannot disagree about how fast
    // the game is running. The clock is a local of `main` and outlives every
    // frame, so the pointer the context holds stays valid for the whole run.
    var game_time = core.loop.GameTime.init(fixed_dt);
    behaviors.ctx.time = &game_time;

    // ── M14: the game UI. The runtime owns one `UiRuntime` — the font cache and
    // the frame's resolved widget/hover/press state — and publishes it to Lua
    // through `Context.ui`. The default font is loaded here (outside the frame
    // guard: `ui.font_load` is a load-time call by contract), so text works with
    // no project setup at all.
    var ui_runtime = UiRuntime.init(boot_alloc, renderer);
    defer ui_runtime.deinit();
    ui_runtime.loadDefault(default_font_path, default_font_px);
    var ui_hooks = script.context.UiHooks{
        .ctx = &ui_runtime,
        .measure = UiRuntime.hookMeasure,
        .font_load = UiRuntime.hookFontLoad,
        .hovered = UiRuntime.hookHovered,
        .pressed = UiRuntime.hookPressed,
    };
    behaviors.ctx.ui = &ui_hooks;

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
    // The canonical scene is the DEFAULT: a project that ships its own scene
    // (`--scene game.zson`) must not also get 50 000 demo sprites under it.
    while (args.scene.len == 0 and row < capped_sprites / cols + 1) : (row += 1) {
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

    // ── Physics ─────────────────────────────────────────────────────────────
    // The runtime had NO physics system, which meant the `physics.*` bindings
    // were inert in a game and the collision signal had nothing to publish.
    // The editor has had one all along; this is the same wiring.
    var physics_sys = physics.System.init(boot_alloc, .box2d, .{}) catch |err| {
        log.warn("physics init failed ({s}); the world will not simulate", .{@errorName(err)});
        return err;
    };
    defer physics_sys.deinit();
    behaviors.ctx.physics = &physics_sys;

    // ── Global scripts, mounted before the first frame ───────────────────
    // AFTER the audio publish above (a global's `start` deserves the same
    // full binding surface a behavior's gets), and skipped in headless mode
    // for the same reason every other config section is: headless runs the
    // defaults, so `zig build run -- --headless` measures the empty world.
    if (!args.headless) mountGlobalScripts(&behaviors, &project_config, boot_alloc);

    // The project's BEHAVIOR scripts, at boot for the same reason the globals
    // are: the scene may not exist, and `actor.spawn` needs the table either
    // way.
    if (!args.headless) loadBehaviorScripts(&behaviors, &project_config, boot_alloc);

    // ── The collision signal, bridged to Lua ───────────────────────────────
    // The physics publishes contacts on the world's typed bus, which only the
    // Zig listeners see. The bridge is what lets a SCRIPT react to being
    // touched — and, with `other_is_sensor`, tells a trigger from a wall.
    //
    // The runtime has no physics system yet (the editor does), so nothing
    // publishes the signal here yet; the subscription is in place for the day
    // it lands, and it costs nothing while it is quiet.
    behaviors.bridgeCollisions(&world) catch |err| {
        log.warn("could not bridge the collision signal to Lua: {s}", .{@errorName(err)});
    };

    // ── The scene, and the behaviors its actors run ────────────────────────
    // AFTER the globals are mounted (a global's `start` may want to know what
    // the scene contains) and BEFORE the first frame, so the world that the
    // first frame draws is the one the project asked for.
    //
    // The built-in canonical scene is the default: `--scene game.zson` is how
    // a project ships its own.
    if (args.scene.len != 0) {
        loadScene(&behaviors, &world, &physics_sys, args.scene, boot_alloc);
    }

    // The world is REBUILT by the scene load (`zson.replace`), so the
    // reservations above are gone with the old world. And the spawn path
    // needs room it cannot ask for in the frame: a new archetype and a free
    // entity slot are ALLOCATIONS, and the frame's guard turns an allocation
    // into a panic.
    //
    // So the two archetypes a spawned actor can need, and the slots for the
    // actors, are reserved HERE — at load time, where allocating is allowed.
    try world.reserveEntities(spawn_reserve);
    try world.reserve(.{components.Transform, components.Name}, spawn_reserve);
    try world.reserve(.{components.Transform, components.Name, components.Script}, spawn_reserve);

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
    // M13: `anim.length` needs the clip registry, and nothing else hands the
    // script context a pointer to it — without this line the binding silently
    // returned nothing for every actor.
    behaviors.ctx.animations = &anim_system;

    // ── M13: clips are ASSETS ───────────────────────────────────────────────
    // Two halves of the same promise, both wired at boot:
    //
    // 1. **Preload.** Every `.anim` in the project's animation directory is
    //    decoded before the first scene runs, so a clip is resident and a script
    //    only names it (`anim.play(self, anim.load(path))` is then a lookup, not
    //    a decode). Each clip's id is the GUID-derived handle of its path
    //    (`clipIdForPath`), so the handle a scene or a script computes from the
    //    path is the one the loader produced.
    //
    // 2. **Method track → Lua.** A clip's `call_lua <t> <script_id> <fn>`
    //    keyframe reaches the named behavior through this hook. Crossed as a
    //    function pointer because `ecs` cannot import `script` (the module graph
    //    runs script -> ecs), exactly like the signal bridge.
    //
    // A missing directory is not an error: a project with no animations yet
    // simply has nothing to preload, and the engine still runs.
    anim_system.method_hook = behaviors.animationMethodHook();
    if (anim_system.preloadDir(animation_asset_dir)) |report| {
        if (report.loaded > 0 or report.failed > 0) {
            log.info("preloaded {d} clip(s) from {s} ({d} failed)", .{
                report.loaded, animation_asset_dir, report.failed,
            });
        }
    } else |err| {
        log.info("no animation asset preload ({s} at '{s}')", .{ @errorName(err), animation_asset_dir });
    }

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

    // ── M14: CanvasModulate (the full-screen tint). Owned by the runtime beside
    // the fader, for the same reason: engine state that outlives a script, fed
    // into `SceneEnvironment` every frame and reached from Lua through the hook
    // struct below. It does not advance on its own — a script sets a colour and
    // a mode, and the post pass applies them.
    var tint_state = tint_mod.Tint{};
    var tint_hooks = script.context.TintHooks{
        .ctx = &tint_state,
        .set = struct {
            fn set_fn(ctx: ?*anyopaque, r: f32, g: f32, b: f32, a: f32) void {
                const t: *tint_mod.Tint = @ptrCast(@alignCast(ctx.?));
                t.set(r, g, b, a);
            }
        }.set_fn,
        .set_mode = struct {
            fn set_mode_fn(ctx: ?*anyopaque, mode: u8) void {
                const t: *tint_mod.Tint = @ptrCast(@alignCast(ctx.?));
                // The wire code is the wire code: anything the runtime does not
                // recognise falls back to `off` rather than being trusted into
                // an invalid enum.
                t.setMode(switch (mode) {
                    1 => .multiply,
                    2 => .add,
                    3 => .alpha,
                    else => .off,
                });
            }
        }.set_mode_fn,
        .clear = struct {
            fn clear_fn(ctx: ?*anyopaque) void {
                const t: *tint_mod.Tint = @ptrCast(@alignCast(ctx.?));
                t.clear();
            }
        }.clear_fn,
        .amount = struct {
            fn amount_fn(ctx: ?*anyopaque) f32 {
                const t: *tint_mod.Tint = @ptrCast(@alignCast(ctx.?));
                return t.amount();
            }
        }.amount_fn,
    };
    behaviors.ctx.tint = &tint_hooks;

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

    // ── M6: image asset hot-reload (the render half of the promise) ─────────
    //
    // `assets.HotReload` notices an on-disk edit and decodes it; it cannot put
    // the pixels anywhere, because `assets` may not import `render`. The adapter
    // that crosses that boundary lives in `render.asset_reload`, and this is the
    // piece of the runtime that owns one of them.
    //
    // Everything here is OUTSIDE the frame loop by construction: the sink is
    // built once, and `reloadChangedImages` below runs next to the audio poll,
    // before `tracker.beginFrame`. An image reload decodes a file and writes a
    // texture — I/O plus a GPU upload — and neither belongs inside a measured
    // frame (spec §3.4).
    var asset_registry = assets.AssetRegistry.init(boot_alloc);
    defer asset_registry.deinit();

    // The manager `sprite.set_image` loads through. 4096 slots and a 256 MB
    // decoded budget are the M6 numbers, and the same ones the asset suite
    // exercises, so a scene that fits the tests fits here.
    var asset_manager = assets.AssetManager.init(boot_alloc, 4096, 256 << 20) catch |err| blk: {
        log.warn("asset manager init failed ({s}); sprite.set_image is disabled", .{@errorName(err)});
        break :blk null;
    };
    defer if (asset_manager) |*am| am.deinit();
    if (asset_manager) |*am| behaviors.ctx.assets = am;
    // The renderer is a by-value handle (a vtable plus a pointer), so the context
    // holds its address — and `renderer` outlives every frame, including the
    // `defer renderer.deinit()` above, which runs after this whole block.
    behaviors.ctx.renderer = &renderer;

    // The reload manager and its sink. The sink reads `ctx.atlas_manager` at call
    // time (see `ImageSink.forRenderer`), so the atlas stays lazily created by
    // the first `sprite.set_image` rather than being forced into existence here
    // for a scene that may never load an image.
    const image_io = std.Io.Threaded.global_single_threaded.io();
    var asset_hot = assets.HotReload.init(boot_alloc, image_io, &asset_registry);
    defer asset_hot.deinit();
    // `sprite.set_image` registers each packed path here, which is the only way
    // the watcher below learns what to re-check.
    behaviors.ctx.hot_reload = &asset_hot;

    var image_sink = render.asset_reload.ImageSink.forRenderer(renderer, &behaviors.ctx.atlas_manager);
    var image_reloader = render.asset_reload.Reloader{ .sink = image_sink.sink() };
    image_reloader.attach(&asset_hot);

    // A missing directory is not an error, exactly as for audio: a project with
    // no sprites yet, or one that ships its images inside a `.pak`, has nothing
    // on disk to watch.
    var image_watcher: ?platform.DirectoryWatcher = null;
    if (!args.headless) {
        if (platform.watchDirectory(boot_alloc, image_asset_dir)) |w| {
            image_watcher = w;
            log.info("watching {s} for image changes", .{image_asset_dir});
        } else |err| {
            log.info("no image asset watch ({s} at '{s}')", .{ @errorName(err), image_asset_dir });
        }
    }
    defer if (image_watcher) |*w| w.deinit(boot_alloc);

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

    // M14: the UI button signal, interned for the same reason: the button fires
    // it from inside the frame, where `emit` must never allocate.
    world.signals.preintern(ecs.ui_system.pressed_signal) catch |err| {
        log.warn("could not reserve the '{s}' signal: {s}", .{ ecs.ui_system.pressed_signal, @errorName(err) });
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

    // ── M14: the UI button → Lua signal sink.
    // A completed click reaches Lua as `on_signal("ui_pressed", { id, entity })`
    // through this erased callback, for the same reason the timer bridge exists:
    // the ECS must not import the script layer. The typed bus still carries the
    // event for Zig listeners (inside `ui_system`), so both see one press.
    const ui_press_sink = ecs.ui_system.PressSink{
        .ctx = &behaviors,
        .fire = struct {
            fn fire(ctx: ?*anyopaque, id: u32, entity: u64) void {
                const b: *script.Behaviors = @ptrCast(@alignCast(ctx.?));
                const fields = [_]script.Behaviors.PayloadField{
                    .{ .name = "id", .value = .{ .integer = @intCast(id) } },
                    .{ .name = "entity", .value = .{ .integer = @bitCast(entity) } },
                };
                b.dispatchSignalPayload(ecs.ui_system.pressed_signal, &fields);
            }
        }.fire,
    };

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

        // ── M6: image asset hot-reload: poll the sprite directory.
        // The same placement and the same reason as the audio poll above: the
        // reload decodes a file and writes a texture, and blocking I/O plus a GPU
        // upload both belong outside the frame the profiler is measuring.
        if (image_watcher) |*w| reloadChangedImages(&asset_hot, w);

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
        // The clock owns the hitch clamp AND the global time scale, and hands
        // back the SCALED delta. The accumulator and the scripts both advance
        // by that same number: a slow-motion game runs the same simulation,
        // less often, and a script can never move at a different speed than
        // the world it is in.
        const dt = game_time.beginFrame(real_dt);
        const steps = loop.addTime(dt);
        var s: u32 = 0;
        while (s < steps) : (s += 1) {
            // ── The interpolation snapshot, FIRST.
            //
            // `prev_*` is what the renderer blends from, and it must be the
            // position the renderer last SAW — so it is captured before
            // anything writes a transform this tick. Without this the
            // renderer interpolates from the spawn position, and every moving
            // actor (and every tween) drags a line back to where it was born.
            world.captureTransforms();
            // ── M4.5: the Timer system, BEFORE the behaviors run.
            // That order is the contract a scripted timer depends on: a
            // behavior's `fixed_update` observes exactly the signals its own
            // timers fired THIS tick, not the ones from the previous one. The
            // bridge forwards the fired names to Lua `on_signal`, which the
            // typed bus cannot reach by itself.
            ecs.timer.tick(&world, fixed_dt, timer_bridge);
            anim_system.update(&world, fixed_dt, timer_bridge);
            // ── The tweens, BEFORE the behaviors run.
            //
            // Same contract as the timers, and the same reason: a script that
            // reads a tweened property in `fixed_update` sees the value the
            // tween just wrote, and a script that writes the property itself
            // has the last word in this tick.
            behaviors.tickTweens(fixed_dt);
            // M3: behaviors run at the fixed 60 Hz tick. `startAll` already ran,
            // so this is the gameplay itself: Lua -> actor.* bindings -> ECS.
            behaviors.fixedUpdate(fixed_dt);
            // M9: particle simulation, AFTER gameplay so a behavior that moves
            // or bursts an emitter this tick is honoured by the same tick's
            // integration rather than the next one. Same fixed dt, same order
            // every frame, which is what makes a particle scene deterministic.
            particles.fixedUpdate(&world, fixed_dt);
            // The solver runs AFTER the gameplay (so the scripts' writes are
            // pushed to it) and BEFORE the root motion (which must be last).
            // It also publishes the contacts the collision bridge hands to Lua.
            _ = physics_sys.step(&world, fixed_dt);
            // M13: root motion runs LAST — after the physics step and gameplay —
            // so a solver (or a behavior) that wrote `Transform` this tick does
            // not overwrite the clip's baked displacement.
            anim_system.applyRootMotion(&world, fixed_dt);
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
        // The physics FOCUS: the camera's centre. The activity tiers decide
        // how much physics a body gets from its distance to the focus, so a
        // focus that never moves tiers the whole world by its distance to the
        // ORIGIN — and a level that does not sit on the origin simulates
        // nothing.
        physics_sys.setFocus(if (camera_view) |v|
            .{ .x = v.cx, .y = v.cy }
        else
            .{ .x = 0, .y = 0 });
        z_sim.end();

        // The bodies of the actors that are gone. A body that outlives its
        // actor keeps simulating — the solver does not know the ECS despawned
        // it — so it falls forever and costs solver time for an actor nobody
        // can see.
        physics_sys.sweepDead(&world);

        // M3: the scripted per-frame update (decoupled from the fixed step, like
        // the renderer) plus the incremental GC step. spec §3.2 budgets that GC
        // step at ≤ 0.4 ms/frame; `vm.gcStep()` measures nothing, so the frame
        // cost lands in `script_update` where the budget gate can see it.
        var z_script = prof.zone("script_update");
        behaviors.update(dt);
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

        // ── M14: the game UI. Resolve the canvas, lay out and hit-test every
        // widget, advance the button state machine and fire `ui_pressed`, then
        // emit the UI instances into the SAME buffer the world just filled — so
        // they draw on top without a second pass. Runs after `collectFiltered`
        // and before `submit` on purpose: emission order IS the UI's z-order.
        //
        // The framebuffer the canvas maps onto is the OFFSCREEN TARGET
        // (`view_w`/`view_h`), not the window: the UI lives inside the game's
        // own render, and the editor composites that later (plan §9.6).
        const ui_pointer: ecs.ui_system.PointerState = if (has_window) .{
            .x = window.input.mouse.x,
            .y = window.input.mouse.y,
            .down = window.input.mouse.down(0),
            .pressed = window.input.mouse.justPressed(0),
            .inside = window.input.mouse.inside,
        } else .{ .inside = false };
        ecs.ui_system.update(
            &ui_runtime.state,
            &world,
            .{ .x = @floatFromInt(view_w), .y = @floatFromInt(view_h) },
            ui_pointer,
            ui_press_sink,
        );
        // Publish the capture flag BEFORE the next `behaviors.update` so a
        // world script asking `input.pointer_over_ui()` this frame sees the
        // widget the pointer was over in the frame just laid out.
        input_state.setPointerOverUi(ui_runtime.state.pointer_over_ui);
        _ = render.ui_draw.emit(&r2d, &world, &ui_runtime.state, .{
            .view = camera_view,
            .fonts = UiRuntime.fontSource(&ui_runtime),
        });
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
        // M14: the CanvasModulate tint. Merged here for the same reason as the
        // fade: it is a full-screen effect the runtime owns, not a value on the
        // scene's Environment component, so a scene with no `environment.new`
        // can still be tinted.
        lighting_env.tint_color = tint_state.rgba();
        lighting_env.tint_mode = @intFromEnum(tint_state.mode);

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
