//! `project.Config` — the typed shape of `project.config`, and the file I/O
//! that reads and writes it.
//!
//! Every field carries its default, so an EMPTY document is still a complete
//! configuration: `project "Untitled" / version "0.1.0"` plus seven sections of
//! defaults, which is exactly what `Config{}` is. A project that says nothing
//! gets a 1280x720 vsynced window at 9.8 m/s², and that is a real project.
//!
//! Ownership: `load` parses into an arena the returned `*Config` owns, so every
//! string in it (project name, layer names, key bindings) is valid until
//! `deinit`. Mutating the struct is plain field assignment — Zig cannot hook
//! `config.display.width = 1920`, so `dirty` is a hint the UI maintains with
//! `markDirty()`, not a trap on writes. `save` clears it.
//!
//! Validation lives in `schema.zig`, not here: parsing answers "is this a
//! well-formed document?", validation answers "is this a sane configuration?".
//! The UI wants to load a config with a slider out of range, show the problem
//! and let the user fix it — a load that refuses to return is a config the UI
//! cannot display.

const std = @import("std");
const parser = @import("parser.zig");

const Allocator = std.mem.Allocator;

/// Layers beyond this cannot exist: the collision mask is a `u16`, one bit per
/// layer (`ecs.collision_layers.layer_count`). The duplicate is deliberate —
/// the project module does not depend on the ECS (spec §7: the config layer
/// reads no engine headers), and a schema that describes layers must be able to
/// say "sixteen" on its own. The mirror is pinned at compile time on the engine
/// side, where both modules are visible: `src/runtime/project_hook.zig` has a
/// `comptime` assert equating this number to the ECS's.
pub const max_layers = 16;

/// Buses beyond this do not exist: a voice's bus is one byte, the mixer
/// accumulates into a fixed array, and the bus registry is a `[16]Bus`. Same
/// deliberate mirror as `max_layers`, pinned at compile time in
/// `src/runtime/project_hook.zig` where `audio.bus.bus_count` is visible.
pub const max_audio_buses = 16;

/// The file itself: header + seven sections + the input map.
pub const Config = struct {
    /// `project "..."` — the internal project name (not the window title's
    /// twin; the window title is `application.name`).
    project: []const u8 = "Untitled",
    /// `version "..."` — the project's own version, free-form semver.
    version: []const u8 = "0.1.0",

    application: Application = .{},
    display: Display = .{},
    rendering: Rendering = .{},
    lighting: Lighting = .{},
    physics: Physics = .{},
    layers: Layers = .{},
    audio: Audio = .{},
    /// Ordered actions, because a UI wants them in file order and the runtime
    /// wants to iterate them once at boot. A plain slice, not a map: action
    /// names are unique (the parser rejects duplicates) and dozens long.
    input_map: []const InputAction = &.{},

    // ── Ownership and state (never encoded: no schema field names them) ──────
    /// True when the in-memory config may differ from the file. Set it with
    /// `markDirty()` after a UI edit; `save` clears it.
    dirty: bool = false,
    /// The arena every string in this struct points into. Null only for a
    /// `Config{}` that was never loaded, which owns nothing.
    arena: ?*std.heap.ArenaAllocator = null,

    pub fn deinit(self: *Config) void {
        if (self.arena) |arena| {
            const child = arena.child_allocator;
            arena.deinit();
            child.destroy(arena);
            self.arena = null;
        }
    }

    /// Destroys the heap-allocated Config returned by `load`/`loadDiag`.
    /// Call this AFTER `deinit()` to free the Config struct itself.
    pub fn destroy(self: *Config, gpa: Allocator) void {
        self.deinit();
        gpa.destroy(self);
    }

    /// Marks the config as differing from its file. Zig cannot intercept field
    /// assignment, so the UI calls this (or `save`) after an edit.
    pub fn markDirty(self: *Config) void {
        self.dirty = true;
    }

    /// The allocator the config owns its strings from: the arena, for a loaded
    /// config; the C allocator for a hand-built one (which then owns nothing
    /// and frees nothing — the caller keeps its strings alive).
    pub fn allocator(self: *const Config) Allocator {
        if (self.arena) |arena| return arena.allocator();
        return std.heap.c_allocator;
    }

    /// Re-reads `path` into this config, replacing every field. The hot-reload
    /// half of the story: the editor panel calls it when the file changes on
    /// disk. No file watcher exists yet — this is the primitive one would use.
    pub fn reload(self: *Config, gpa: Allocator, path: []const u8) !void {
        const replacement = try loadOwned(gpa, path, null);
        const stale = self.arena;
        self.* = replacement;
        if (stale) |arena| {
            arena.deinit();
            gpa.destroy(arena);
        }
    }
};

// ── Sections ────────────────────────────────────────────────────────────────

pub const Application = struct {
    name: []const u8 = "Untitled",
    /// Window icon, relative to the project root. Empty = the platform default.
    icon: []const u8 = "",
    splash_screen: SplashScreen = .{},
};

pub const SplashScreen = struct {
    image: []const u8 = "",
    /// Seconds on screen. 0 with an image set still skips the splash.
    duration: f64 = 2.0,
    background_color: []const u8 = "#000000",
};

pub const Display = struct {
    width: i32 = 1280,
    height: i32 = 720,
    vsync: bool = true,
    fullscreen: bool = false,
    resizable: bool = true,
    /// 0 = no cap. The frame limiter is inert at 0 when vsync is on anyway.
    max_fps: i32 = 0,
};

pub const AntiAliasing = enum { none, smaa, fxaa, msaa };

/// The order sprites are drawn in. `layer` is the engine's `by_layer`: stable
/// order inside a layer, layers in ascending order.
pub const SpriteSortMode = enum { none, front_to_back, back_to_front, layer };

pub const Rendering = struct {
    antialiasing: AntiAliasing = .smaa,
    sort_mode: SpriteSortMode = .front_to_back,
    /// GPU instance-buffer capacity. Boot-time: growing it means re-creating
    /// the buffer, which is a `Renderer2D.reserve` call, not a write.
    max_sprites: i32 = 50_000,
};

/// How the 2D lighting system resolves shadows and bounce light.
///
/// Separate from `rendering` because these are the numbers that decide what a
/// frame COSTS, and a developer tuning a game on a laptop wants them somewhere
/// they can find them rather than inferred from a draw-call budget.
pub const Lighting = struct {
    /// The GI field's longest side, in cells. This is the dial that decides what
    /// bounce light costs: the distance field, the radiance pyramid and the
    /// upload are all sized by it, and all three shrink with it.
    ///
    /// `0` means "match the shadow mask" -- one GI texel per shadow texel, which
    /// is the most detail the hardware can carry. It is not the default because
    /// it is not free: measured at 264 ms per rebuild against 2.7 ms at the
    /// default, on a 2048x2048 mask. It stays reachable for a project that wants
    /// it and has the frame time to pay for it.
    ///
    /// The default is in `light.default_gi_res` and was chosen from the table
    /// `zig build bench-light` prints, not by taste.
    gi_resolution: i32 = 128,

    /// Shadow-map resolution, in cells along the longest side of the view. Like
    /// `gi_resolution` this is a budget rather than a look: the angular sweep
    /// marches a step per cell, so halving it halves the work and the fidelity
    /// together.
    shadow_resolution: i32 = 2048,
};

pub const Physics = struct {
    /// m/s², +Y down (the engine's convention: `physics.Gravity.y = 9.8`).
    gravity: f64 = 9.8,
    /// Box2D sub-steps per `b2World_Step`.
    solver_iterations: i32 = 4,
    /// Seconds a body must be under both thresholds before it sleeps.
    time_before_sleep: f64 = 0.5,
    max_physics_steps_per_frame: i32 = 4,
    /// Linear/angular sleep thresholds, in the engine's units. Mirrors
    /// `ecs.PhysicsTuning`, which validates the same numbers at load.
    sleep_threshold_linear: f64 = 8.0,
    sleep_threshold_angular: f64 = 8.0,
};

pub const Layers = struct {
    names: []const []const u8 = &.{},
    /// Layer new entities join by default. Must be one of `names` (or anything
    /// when no layers are declared — the world has no opinion yet).
    default_mask: []const u8 = "world",
};

/// Which device backend the engine opens. A backend is a file that fulfills
/// `audio.VTable`, selected at comptime, so a project that never mentions
/// miniaudio never links it.
pub const AudioBackend = enum {
    /// No device at all: the mixer still runs every buffer (which is what makes
    /// the whole path testable), but nothing is heard. Editor previews and CI.
    @"null",
    /// A real device through the vendored miniaudio (`libs/miniaudio.h`).
    miniaudio,
};

/// Requested output rate. The mixer resamples to whatever the DEVICE
/// negotiates; these are the two rates desktop hardware asks for.
///
/// The values are SPELLED OUT: an enum's default discriminants are 0, 1, 2, so
/// `@intFromEnum(.@"48000")` would be 1 — a device asked for 1 Hz. The tag names
/// are the file's spelling and these are the engine's number, and they agree by
/// construction here rather than by hope.
pub const SampleRate = enum(u32) { @"44100" = 44100, @"48000" = 48000 };

/// The bus map a project that says nothing gets: master plus the four channels
/// a game reaches for first. Declaring them in the file rather than inventing
/// them at runtime is what makes `audio.set_bus_volume("music", 0.5)` resolve
/// in a fresh project.
pub const default_buses = [_][]const u8{ "master", "music", "sfx", "ui" };

/// M8 — the mixer. Every field is a boot-time setting: the device, the pool
/// and the byte budget are fixed once the system exists, which is why the
/// editor applies a changed section by rebuilding the system, not by poking it.
pub const Audio = struct {
    /// Off = no device is opened and nothing is mixed. The Lua surface still
    /// answers (`audio.is_playing` is false, `audio.stats()` reports zeros), so
    /// a script written against audio does not have to branch on this.
    enabled: bool = true,
    backend: AudioBackend = .miniaudio,
    sample_rate: SampleRate = .@"48000",
    /// Frames per device callback: the period, and therefore the latency dial.
    /// 480 at 48 kHz is 10 ms, and the M8 budget (≤ 20 ms) is about two
    /// periods, so halving this halves the latency and doubles the callbacks.
    period_frames: i32 = 480,
    /// Voice pool size, reserved once at load. A play past it STEALS the
    /// quietest voice at equal priority (voice.zig); it never drops silently.
    voices: i32 = 256,
    /// Ceiling for the decoded-PCM cache, in bytes (spec §3.15). The LRU evicts
    /// to stay under it — 32 MiB is roughly 90 seconds of stereo 48 kHz.
    budget_bytes: i64 = 32 << 20,
    /// Master gain (bus 0), applied after every bus sum.
    master_volume: f64 = 1.0,
    /// Bus names, indexed BY BUS ID: item `i` names bus `i`, at most
    /// `max_audio_buses` items. Item 0 is bus 0, which is always master and is
    /// never renamed — the entry is conventional (`"master"`) and ignored, the
    /// other names are what `audio.set_bus_volume("music", 0.5)` resolves.
    /// A bus's gain and mute are RUNTIME mixer state (the panel's sliders),
    /// not project settings, which is why they are not in this file.
    buses: []const []const u8 = &default_buses,
};

/// One named action and the device names that trigger it. Bindings are names,
/// not codes: `"KEY_A"` means the same on every machine and survives the file
/// format; the GLFW code is resolved at boot by `runtime.resolve`.
pub const InputAction = struct {
    name: []const u8,
    bindings: []const []const u8 = &.{},
};

// ── File I/O ────────────────────────────────────────────────────────────────

pub const Error = error{
    FileNotFound,
    ReadFailed,
    WriteFailed,
    OutOfMemory,
};

pub const default_path = "project.config";

/// Loads `path` into a heap-owned `Config`. Missing file is an error; use
/// `loadOrNull` for "defaults when there is no project". Parsing only — the
/// result is well-formed but may still fail `schema.validate` (the UI needs to
/// display a broken config in order to fix it).
pub fn load(allocator: Allocator, path: []const u8) !*Config {
    return loadDiag(allocator, path, null);
}

/// `load` with a diagnostics sink: on failure `diag` names the line and what
/// the parser expected, which is what turns "invalid project.config" into
/// "line 12: unknown field 'widht' in section 'display'".
pub fn loadDiag(allocator: Allocator, path: []const u8, diag: ?*parser.Diagnostics) !*Config {
    var parsed = try loadOwned(allocator, path, diag);
    errdefer parsed.deinit();
    const self = try allocator.create(Config);
    self.* = parsed;
    return self;
}

/// Parses `path` into a by-value `Config` (arena-attached). Internal; the heap
/// form is what the public API returns.
fn loadOwned(allocator: Allocator, path: []const u8, diag: ?*parser.Diagnostics) !Config {
    const io = std.Io.Threaded.global_single_threaded.io();
    const text = std.Io.Dir.cwd().readFileAlloc(io, path, allocator, .limited(parser.max_config_bytes)) catch |err| {
        if (err == error.FileNotFound) return error.FileNotFound;
        return error.ReadFailed;
    };
    defer allocator.free(text);
    return parser.parseDiag(allocator, text, diag);
}

/// Writes the config to `path` in canonical form and clears `dirty`. The file
/// is rewritten whole, in schema order: comments do not survive a save, and
/// that is the price of a format whose bytes are a function of the config.
pub fn save(self: *Config, path: []const u8) !void {
    const alloc = self.allocator();
    const text = try parser.encodeToString(alloc, self);
    defer alloc.free(text);
    const io = std.Io.Threaded.global_single_threaded.io();
    std.Io.Dir.cwd().writeFile(io, .{ .sub_path = path, .data = text }) catch return error.WriteFailed;
    self.dirty = false;
}

test "config: defaults describe a working game" {
    var c = Config{};
    try std.testing.expectEqual(@as(i32, 1280), c.display.width);
    try std.testing.expectEqual(@as(i32, 720), c.display.height);
    try std.testing.expectEqual(true, c.display.vsync);
    try std.testing.expectEqual(@as(f64, 9.8), c.physics.gravity);
    try std.testing.expectEqual(AntiAliasing.smaa, c.rendering.antialiasing);
    try std.testing.expectEqual(@as(usize, 0), c.input_map.len);
    c.deinit(); // owns nothing: must be a no-op
}
