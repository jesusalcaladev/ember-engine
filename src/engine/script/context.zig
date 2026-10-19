//! The shared engine context every Lua binding reaches through its upvalue.
//!
//! It exists so the C functions in `bindings.zig` stay allocation-free and
//! global-free: each is registered as a 1-upvalue closure over a pointer to
//! this struct, so `ctxOf(L)` is one userdata read — no map, no global fetch,
//! no per-call allocation (spec §3.1, ROADMAP M3 "zero-allocation-per-call").
//!
//! What it holds and why:
//! - `world`: the ECS the Actor facade talks to. Lua never sees the ECS type;
//!   it only ever passes the entity handle stamped into its `self` table.
//! - `input`: the action-based input snapshot for this frame. The runtime fills
//!   it once per frame from the platform layer; bindings only read it.
//! - `signals`: the typed signal bus, so `actor.emit` queues into the same
//!   stable-order, drained-once system the rest of the engine uses (spec §6).
//!
//! The `script` module imports the ECS only through the narrow types it needs
//! (World, Entity, components), keeping the Lua boundary from leaking ECS
//! internals into gameplay.

const std = @import("std");
const ecs = @import("ecs");
const input_mod = @import("input.zig");
const lua_c = @import("luajit.zig");
const core_random = @import("core").random;
const core_loop = @import("core").loop;
const statemachine = @import("statemachine.zig");
const tween_mod = @import("tween.zig");
const spatial = @import("spatial.zig");
const physics_mod = @import("physics");
const assets = @import("assets");
const audio_mod = @import("audio");
const render = @import("render");

/// The three operations the M7 `lighting.*` bindings need, as function pointers.
///
/// `ctx` is whatever the runtime's closures need -- the `*Driver` -- and is
/// passed back to every call, so the runtime does not need a module-level global
/// to find it. That matters because the editor and a test can both have a
/// lighting system alive at once and they must not share one.
pub const LightingHooks = struct {
    ctx: ?*anyopaque,
    /// The current tier: 0 off, 1 low, 2 medium, 3 high.
    get_quality: *const fn (ctx: ?*anyopaque) u8,
    /// Changes the tier. False when it could not be taken -- a GI-on tier on a
    /// driver that was created with GI off declines, because the pyramid is a
    /// startup budget decision and the frame was not sized for one.
    set_quality: *const fn (ctx: ?*anyopaque, tier: u8) bool,
    /// Writes the per-frame stats into `out` and returns how many it wrote.
    /// A fixed array and not a struct so the two modules cannot disagree about a
    /// layout: the count is what pairs each number with its name.
    stats: *const fn (ctx: ?*anyopaque, out: *[16]f64) u32,
};

/// The M9 `scene.*` bindings, as a vtable over the runtime's `Fader`.
///
/// Same shape as `LightingHooks` and for the same reason: the `script` module
/// is its own build module and cannot import `render`, so what a transition is
/// crosses the boundary as behaviour and not as a type. The `ctx` is whatever
/// the runtime's closures need (`*Fader`), which keeps the editor and a test
/// from sharing one transition.
pub const SceneHooks = struct {
    ctx: ?*anyopaque,
    /// Begins covering the screen over `duration` real seconds.
    fade_out: *const fn (ctx: ?*anyopaque, duration: f32, r: f32, g: f32, b: f32) void,
    /// Begins uncovering from wherever the curtain currently is.
    fade_in: *const fn (ctx: ?*anyopaque, duration: f32) void,
    /// Jumps straight to a covered screen (a loading screen's first frame).
    fade_covered: *const fn (ctx: ?*anyopaque, r: f32, g: f32, b: f32) void,
    /// Jumps straight back to a clear screen.
    fade_clear: *const fn (ctx: ?*anyopaque) void,
    /// Current coverage, 0..1.
    amount: *const fn (ctx: ?*anyopaque) f32,
    /// True while a transition is running.
    fading: *const fn (ctx: ?*anyopaque) bool,
};

/// The M14 CanvasModulate bindings (`scene.tint*`), as a vtable over the
/// runtime's `Tint`.
///
/// Same shape as `SceneHooks` and for the same reason: the `script` module
/// cannot import `render`, so the tint's state crosses as behaviour. The mode
/// travels as a `u8` (0 off, 1 multiply, 2 add, 3 alpha) for the same reason it
/// does in the uniform — the two modules must not each own an enum the other
/// has to agree with. `ctx` points at the runtime's `Tint`.
pub const TintHooks = struct {
    ctx: ?*anyopaque,
    /// Applies rgb + amount, turning the effect on (multiply) if it was off.
    set: *const fn (ctx: ?*anyopaque, r: f32, g: f32, b: f32, a: f32) void,
    /// Sets only the mix, 0 off, 1 multiply, 2 add, 3 alpha.
    set_mode: *const fn (ctx: ?*anyopaque, mode: u8) void,
    /// Disables the tint and forgets its colour.
    clear: *const fn (ctx: ?*anyopaque) void,
    /// Current strength, 0..1.
    amount: *const fn (ctx: ?*anyopaque) f32,
};

/// The M9 `particles.*` bindings that need the pool rather than a component.
///
/// Configuring an emitter is a plain component write and goes through
/// `ctx.world` like every other per-actor surface. BURSTING and reading STATS
/// need the system that owns the pool, and those two cross as function pointers
/// for the same module-boundary reason `LightingHooks` does.
pub const ParticleHooks = struct {
    ctx: ?*anyopaque,
    /// Emits `count` particles NOW. `entity_bits` is `Entity.bits()`, so the
    /// runtime can recover the handle without the script module naming it.
    burst: *const fn (ctx: ?*anyopaque, entity_bits: u64, count: u32) u32,
    /// Writes the per-frame counters into `out`, returns how many it wrote. A
    /// fixed array and not a struct, so the two modules cannot disagree about a
    /// layout: the count is what pairs each number with its name.
    stats: *const fn (ctx: ?*anyopaque, out: *[16]f64) u32,
};

/// The global-script surface (scripts mounted with NO actor), as a vtable over
/// the `Behaviors` system that owns them.
///
/// Same shape and same reason as `LightingHooks`: the globals LIVE in the
/// behavior system (they share its VM, its script cache and its Lua refs), and
/// `bindings.zig` cannot import `behavior.zig` — that import is circular, since
/// behavior.zig registers the bindings. So what a binding needs crosses as two
/// function pointers, and the editor and a test keep separate globals because
/// the pointer reaches through each Behaviors' own context upvalue.
pub const GlobalsHooks = struct {
    ctx: ?*anyopaque,
    /// Pushes the named global script's `self` table onto the Lua stack and
    /// returns true; false (nothing pushed) when no global with that name is
    /// mounted. PUSHING instead of returning a registry ref keeps the ref
    /// arithmetic inside the one module that owns the VM: a binding must never
    /// `lua_getref` a table it cannot reliably unref.
    push_self: *const fn (ctx: ?*anyopaque, L: ?*lua_c.lua_State, name: []const u8) bool,
    /// True when a global script with this name is mounted (has a live `self`).
    exists: *const fn (ctx: ?*anyopaque, name: []const u8) bool,
};

/// The M14 `ui.*` bindings that need the runtime's font cache and the frame's
/// resolved UI state, as a vtable.
///
/// Two module boundaries meet here at once. The `script` module cannot import
/// `render`, so the glyph rasterizer and its atlas cross as function pointers;
/// and the per-frame `ui_system.State` lives in the RUNTIME (it is a local of
/// the frame loop), not on the `Context`, so the hover/press queries cross the
/// same way. It is the same erased shape as `LightingHooks`, and for the same
/// reason: two runtimes (the editor and a test) can each have their own UI and
/// must not share one. `ctx` points at the runtime's UI holder.
///
/// Null in a harness with no renderer wired (a headless tool, a unit test): the
/// queries then report `false` and `font_load` returns 0, so a missing UI fails
/// safe instead of dereferencing a null pointer.
pub const UiHooks = struct {
    ctx: ?*anyopaque,
    /// Measures `text` in the font `font_id` (0 = the engine default) and writes
    /// (width, height) into `out`. False when the id is unknown, in which case
    /// the binding returns nil rather than a zero that looks like an empty
    /// string.
    measure: *const fn (ctx: ?*anyopaque, font_id: u32, text: []const u8, out: *[2]f32) bool,
    /// Loads `path` at `pixel_height` (or returns an already-loaded font with
    /// the same pair) and returns its id, or 0 when it could not be read. 0 is
    /// the engine default and is only the answer to a failed load.
    font_load: *const fn (ctx: ?*anyopaque, path: []const u8, pixel_height: f32) u32,
    /// True when `entity_bits` (`Entity.bits()`) is the widget the pointer is
    /// over this frame.
    hovered: *const fn (ctx: ?*anyopaque, entity_bits: u64) bool,
    /// True when `entity_bits` is the button currently being held down.
    pressed: *const fn (ctx: ?*anyopaque, entity_bits: u64) bool,
};

pub const World = ecs.World;
pub const Actor = ecs.Actor;
pub const Entity = ecs.Entity;
pub const components = ecs.components;
pub const Vec2 = components.Vec2;
pub const Transform = components.Transform;

/// Re-export the action-based input snapshot (filled by the runtime per frame).
pub const Input = input_mod.Input;

/// The physics world the bindings query (ROADMAP M4).
///
/// This is the PORT's `World` — a vtable plus an opaque context — and not the
/// `System` that owns it. Two consequences worth stating, because they are the
/// reason the port exists at all:
///
/// - The Lua layer never learns which solver is behind the questions. Swapping
///   Box2D for another engine changes `physics_mod.createWorld`, and this file
///   does not move.
/// - The bindings can ask the world things (raycasts) without owning the clock.
///   Stepping belongs to the `Driver`, which the runtime drives; a script that
///   could step the world itself could break the fixed-60 Hz contract that
///   determinism rests on.
pub const PhysicsWorld = physics_mod.World;

/// The ECS-facing physics system, which is what Lua actually talks to.
///
/// Not the raw `World`: the port's `World` is the solver's door, and going
/// through it directly is how an impulse gets silently cancelled (`pushDown`
/// re-asserts the component's velocity every frame, wiping anything set on the
/// solver between frames). The `System` is the layer that knows about the
/// frame, and gameplay needs the frame's semantics.
pub const PhysicsSystem = physics_mod.System;

/// What the camera can see, for render culling. Mirrors `render.ViewRect` but is
/// declared here so the script module does not have to import the renderer.
pub const RenderViewRect = struct {
    min_x: f32 = 0,
    min_y: f32 = 0,
    max_x: f32 = 0,
    max_y: f32 = 0,
};

/// The counters `render.stats()` reports.
pub const RenderStats = struct {
    entities: u32 = 0,
    instances: u32 = 0,
    culled: u32 = 0,
    hidden: u32 = 0,
};

/// The shared engine state shared by all Lua bindings. One per runtime; tests build
/// their own. It borrows `world` (does not own it): the runtime owns the World
/// and the Vm, and this struct is the bridge between them for script calls.
pub const Context = struct {
    world: *World,
    input: *const Input,
    /// The one PRNG every Lua `rand.*` call draws from (ROADMAP M4.5). It lives
    /// here rather than in a module global so that two runtimes (the editor and
    /// a test, say) never share a sequence, and so `save/load` has exactly one
    /// place to snapshot it for determinism (spec §6).
    rng: core_random.Rng,
    /// The default seed for the `noise.*` functions. Per-call, not per-Context:
    /// two subsystems wanting different noise fields pass their own seed, so
    /// terrain height does not move when the cloud layer is re-seeded.
    noise_seed: u64,
    /// The state-machine registry (ROADMAP M4.5). Null when the runtime has no
    /// machine support wired (a headless tool, a test): the `sm.*` bindings then
    /// report failure instead of reaching through a null pointer.
    machines: ?*statemachine.Registry = null,
    /// The spatial grid behind `world.nearby` (ROADMAP M4.5). Null for the same
    /// reason as `machines`; `nearby` then reports zero neighbours rather than
    /// scanning the world linearly, so a missing grid fails safe instead of
    /// silently turning an O(n^2) query into a correct-but-slow one.
    spatial: ?*spatial.Grid = null,
    /// What the M7 `lighting.*` bindings need from the lighting system, as
    /// function pointers. Null when the runtime has no renderer wired (a headless
    /// tool, a test, an editor with no 2D view).
    ///
    /// A VTABLE and not the `Driver` type because `script` is its own build
    /// MODULE and cannot import `render` -- reaching the file directly is a
    /// compile error ("file exists in modules 'engine' and 'script'"), and
    /// widening the module graph to fix one field would couple the scripting
    /// layer to the renderer.
    ///
    /// It is also the smaller ask. What the bindings need is two numbers and a
    /// bag of counters, not a mask, four shadow channels and a radiance pyramid.
    /// Exposing exactly that is what keeps the boundary honest.
    ///
    /// Null means the bindings REPORT failure rather than reaching through a
    /// null pointer: a `lighting.set_quality` that silently did nothing would be
    /// an inspector dropdown that appears to work.
    lighting: ?*const LightingHooks = null,
    /// The physics world, or null when the runtime has none (a headless tool, a
    /// test, an editor previewing a scene without physics). Null rather than a
    /// dummy world on purpose: a dummy would answer "nothing in the way" to a
    /// line-of-sight test, and a guard the AI reads as "clear shot" is worse
    /// than a hard failure. The bindings report the failure instead.
    physics: ?*PhysicsSystem = null,
    /// The asset manager for loading images and audio (M3). Null when the
    /// runtime has no asset system wired (a headless tool, a test).
    assets: ?*assets.AssetManager = null,
    /// The renderer for atlas management and sprite rendering. Null when the
    /// runtime has no renderer wired (a headless tool, a test).
    renderer: ?*render.Renderer = null,
    /// Persistent atlas manager handle, so `sprite.set_image` reuses one atlas
    /// across calls instead of creating a new one per image. Null until the
    /// first image is set; the binding creates it lazily.
    atlas_manager: ?*anyopaque = null,
    /// The asset hot-reload manager (M6). `sprite.set_image` registers each image
    /// here as it packs it, which is what gives the runtime's directory watcher a
    /// path to re-check: `HotReload.reloadPath` only re-checks paths it was told
    /// to watch, and the manager has no way to discover them on its own. Null in
    /// a headless tool or a test, where the binding simply does not register —
    /// there is no watcher, so there is nothing to register FOR.
    hot_reload: ?*assets.HotReload = null,
    /// The audio system (M8). Null means the `audio.*` bindings report failure
    /// rather than dereferencing null — a headless tool with no device, or an
    /// editor with sound disabled, both reach every call and get `false`/nil.
    audio: ?*audio_mod.Audio = null,

    /// M9: the scene-transition fader. Null when the runtime has no renderer
    /// wired (a headless tool, a test): the `scene.*` bindings then report
    /// failure rather than reaching through a null pointer, the same rule every
    /// other optional system here follows.
    scene: ?*const SceneHooks = null,
    /// M14: CanvasModulate — the full-screen tint. Null for the same reason as
    /// `scene`: the `scene.tint*` bindings then report failure (or a zero
    /// amount) rather than reaching through a null pointer.
    tint: ?*const TintHooks = null,
    /// M9: the particle pool, for `particles.burst` and `particles.stats`.
    /// Null for the same reason; the CONFIGURE half of the API is component
    /// writes and works without it.
    particles: ?*const ParticleHooks = null,
    /// M13: animation system, for clip length queries. Null means `anim.length`
    /// returns nil; component writes still work.
    animations: ?*ecs.animation.System = null,

    /// The game clock and the global time scale (M4.5 follow-up), behind the
    /// `time.*` bindings. Null when the runtime has no clock wired (a headless
    /// tool, a test): the `time.*` bindings then report a zero delta and
    /// refuse to change the scale, rather than reaching through a null
    /// pointer. A zero delta is the SAFE answer — a script that multiplies by
    /// `time.delta()` gets a still frame instead of a crash.
    time: ?*core_loop.GameTime = null,

    /// The tween pool, behind the `tween.*` bindings. Null in a harness that
    /// never wires one: the `tween.*` bindings then report failure rather
    /// than reaching through a null pointer, the same rule every other
    /// optional system here follows.
    tweens: ?*tween_mod.Manager = null,

    /// The global scripts (mounted with no actor), as the vtable above. Null in
    /// a harness that never mounts one: `globals.get` then returns nil and
    /// `globals.exists` false, which is the right answer for a world with no
    /// globals rather than a lookup the caller must guard.
    globals: ?*const GlobalsHooks = null,

    /// M14: the game-UI surface — the runtime's font cache and the frame's
    /// resolved hover/press state. Null when nothing wired a UI (a headless
    /// tool, a test): `ui.measure`/`ui.font_load` then fail cleanly and the
    /// hover queries answer false, the same rule every optional system here
    /// follows.
    ui: ?*const UiHooks = null,

    /// The camera's view for RENDER culling, which is a different rectangle from
    /// the physics one on purpose: the renderer asks "can I see it", physics asks
    /// "can it affect anything", and those are not the same question. A sprite
    /// just off-screen is not worth drawing and IS worth simulating if something
    /// can still walk into it.
    render_view: RenderViewRect = .{},
    render_view_enabled: bool = false,
    /// Which atlas slots currently hold a resident texture. All set by default:
    /// a machine with no streaming wants no skipping, and a mask of zeroes would
    /// render nothing at all and look like a bug rather than a policy.
    render_resident: [4]u64 = .{ 1, 1, 1, 1 },
    /// The last frame's render stats, so `render.stats()` is a read rather than
    /// a cross-module call from a binding.
    render_stats: RenderStats = .{},

    pub fn init(world: *World, input: *const Input) Context {
        return .{
            .world = world,
            .input = input,
            // A fixed default, NOT the clock: a run that starts from an
            // unseedable generator cannot be reproduced, which would break the
            // determinism contract from the first frame.
            .rng = core_random.Rng.init(core_random.Rng.default_seed),
            .noise_seed = 0,
            .assets = null,
        };
    }

    /// The Actor facade over a handle, for a binding that resolved an entity
    /// from a `self` table. Cheap: a struct of two words.
    pub fn actor(self: *const Context, e: Entity) Actor {
        return Actor.from(self.world, e);
    }
};
