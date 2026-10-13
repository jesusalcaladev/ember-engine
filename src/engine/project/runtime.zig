//! `project.runtime` — from a validated `Config` to a running engine.
//!
//! The project module is deliberately dependency-free (core only, spec §7), so
//! it cannot call `window.setVsync` or `physics.setGravity` itself — those
//! types live behind the engine boundary. Two pieces live here instead:
//!
//! 1. **`apply` + `Targets`** — the portable half. `Targets` is a table of
//!    callbacks (one per section) plus a context pointer, which is the same
//!    erased-interface pattern the ECS timer bridge and the physics VTable
//!    already use. Whoever owns the engine objects (the runtime, the editor
//!    panel) fills the table in and `apply` walks the config: validate once,
//!    then hand each section to the subsystem that understands it. The glue
//!    that touches real engine types lives in `src/runtime/project_hook.zig`,
//!    where those modules are visible.
//!
//! 2. **`resolve`** — names to codes. `input_map` binds `"KEY_A"`, not `65`:
//!    a name is readable in the file, stable across platforms, and survives a
//!    format bump; the GLFW code is a per-boot detail. `resolve` walks the
//!    config once at startup and produces `RuntimeConfig`: each action with
//!    its resolved key codes and joystick buttons, unknown names warned and
//!    dropped (a typo in a binding is a key that does nothing, never a crash).

const std = @import("std");
const core = @import("core");
const config = @import("config.zig");
const schema = @import("schema.zig");

const log = core.log.scoped("project");

const Allocator = std.mem.Allocator;

pub const Config = config.Config;

// ── Applying ────────────────────────────────────────────────────────────────

/// One callback per section, all optional, over an erased context. Optional
/// rather than required so a caller can apply just what it owns: the runtime
/// has no splash screen yet, and a null callback is the honest no-op.
pub const Targets = struct {
    ctx: *anyopaque,
    application: ?*const fn (*anyopaque, *const config.Application) void = null,
    display: ?*const fn (*anyopaque, *const config.Display) void = null,
    rendering: ?*const fn (*anyopaque, *const config.Rendering) void = null,
    lighting: ?*const fn (*anyopaque, *const config.Lighting) void = null,
    physics: ?*const fn (*anyopaque, *const config.Physics) void = null,
    layers: ?*const fn (*anyopaque, *const config.Layers) void = null,
    audio: ?*const fn (*anyopaque, *const config.Audio) void = null,
    input_map: ?*const fn (*anyopaque, []const config.InputAction) void = null,
};

pub const ApplyError = schema.ValidationError;

/// Validates, then hands every section to its target, in schema order. A
/// config that fails validation is applied nowhere: half-applied settings are
/// the failure mode where the window says 1920 and the limiter says the old
/// 1280's vsync, and nobody can say which value is the truth.
pub fn apply(cfg: *const Config, targets: Targets) ApplyError!void {
    try schema.validate(cfg);
    if (targets.application) |f| f(targets.ctx, &cfg.application);
    if (targets.display) |f| f(targets.ctx, &cfg.display);
    if (targets.rendering) |f| f(targets.ctx, &cfg.rendering);
    // The receiver is expected to call `lighting_driver.Driver.setGiResolution`
    // and a shadow-mask resize. BOTH allocate, so this callback is boot-time:
    // an editor applying a config live has to stage it and apply it between
    // frames, which is a real constraint on the panel and one it needs to know
    // before it offers a slider.
    if (targets.lighting) |f| f(targets.ctx, &cfg.lighting);
    if (targets.physics) |f| f(targets.ctx, &cfg.physics);
    if (targets.layers) |f| f(targets.ctx, &cfg.layers);
    if (targets.audio) |f| f(targets.ctx, &cfg.audio);
    if (targets.input_map) |f| f(targets.ctx, cfg.input_map);
}

/// The bindings of one action, by name. UI and gameplay ask for "jump"'s keys
/// without knowing where the map lives.
pub fn bindingsFor(cfg: *const Config, action: []const u8) ?[]const []const u8 {
    for (cfg.input_map) |a| {
        if (std.mem.eql(u8, a.name, action)) return a.bindings;
    }
    return null;
}

// ── Resolving names to codes ────────────────────────────────────────────────

/// A name like `"KEY_A"`: what the file holds and the UI offers. Codes are
/// GLFW's, which is what `platform.Input` indexes by (keys are `c_int` there).
pub fn keyFromName(name: []const u8) ?i32 {
    // Letters and digits: GLFW's codes ARE their ASCII values, so the table
    // below only owes the non-printable keys.
    // "KEY_A" -> 5 chars: K-E-Y-_-A. "KEY_1" -> same.
    if (name.len == 5 and std.mem.startsWith(u8, name, "KEY_")) {
        const c = name[4];
        if ((c >= 'A' and c <= 'Z') or (c >= '0' and c <= '9')) return c;
    }
    for (key_names) |entry| {
        if (std.mem.eql(u8, entry.name, name)) return entry.code;
    }
    return null;
}

/// A name like `"JOY_A"`: an XInput-style button index. The platform layer
/// does not poll joysticks yet, so these resolve but are warned about at
/// `resolve` time — the config is right, the plumbing is not there yet.
pub fn joyButtonFromName(name: []const u8) ?u8 {
    for (joy_names) |entry| {
        if (std.mem.eql(u8, entry.name, name)) return entry.button;
    }
    return null;
}

pub fn isJoystickBinding(name: []const u8) bool {
    return std.mem.startsWith(u8, name, "JOY_");
}

const key_names = [_]struct { name: []const u8, code: i32 }{
    // Non-printable keys. GLFW's printable keys are their ASCII codes, and the
    // KEY_A..KEY_Z / KEY_0..KEY_9 prefix form is handled before this table.
    .{ .name = "KEY_SPACE", .code = 32 },
    .{ .name = "KEY_APOSTROPHE", .code = 39 },
    .{ .name = "KEY_COMMA", .code = 44 },
    .{ .name = "KEY_MINUS", .code = 45 },
    .{ .name = "KEY_PERIOD", .code = 46 },
    .{ .name = "KEY_SLASH", .code = 47 },
    .{ .name = "KEY_SEMICOLON", .code = 59 },
    .{ .name = "KEY_EQUAL", .code = 61 },
    .{ .name = "KEY_LEFT_BRACKET", .code = 91 },
    .{ .name = "KEY_BACKSLASH", .code = 92 },
    .{ .name = "KEY_RIGHT_BRACKET", .code = 93 },
    .{ .name = "KEY_GRAVE_ACCENT", .code = 96 },
    .{ .name = "KEY_ESCAPE", .code = 256 },
    .{ .name = "KEY_ENTER", .code = 257 },
    .{ .name = "KEY_TAB", .code = 258 },
    .{ .name = "KEY_BACKSPACE", .code = 259 },
    .{ .name = "KEY_INSERT", .code = 260 },
    .{ .name = "KEY_DELETE", .code = 261 },
    .{ .name = "KEY_RIGHT", .code = 262 },
    .{ .name = "KEY_LEFT", .code = 263 },
    .{ .name = "KEY_DOWN", .code = 264 },
    .{ .name = "KEY_UP", .code = 265 },
    .{ .name = "KEY_PAGE_UP", .code = 266 },
    .{ .name = "KEY_PAGE_DOWN", .code = 267 },
    .{ .name = "KEY_HOME", .code = 268 },
    .{ .name = "KEY_END", .code = 269 },
    .{ .name = "KEY_CAPS_LOCK", .code = 280 },
    .{ .name = "KEY_SCROLL_LOCK", .code = 281 },
    .{ .name = "KEY_NUM_LOCK", .code = 282 },
    .{ .name = "KEY_PRINT_SCREEN", .code = 283 },
    .{ .name = "KEY_PAUSE", .code = 284 },
    .{ .name = "KEY_F1", .code = 290 },
    .{ .name = "KEY_F2", .code = 291 },
    .{ .name = "KEY_F3", .code = 292 },
    .{ .name = "KEY_F4", .code = 293 },
    .{ .name = "KEY_F5", .code = 294 },
    .{ .name = "KEY_F6", .code = 295 },
    .{ .name = "KEY_F7", .code = 296 },
    .{ .name = "KEY_F8", .code = 297 },
    .{ .name = "KEY_F9", .code = 298 },
    .{ .name = "KEY_F10", .code = 299 },
    .{ .name = "KEY_F11", .code = 300 },
    .{ .name = "KEY_F12", .code = 301 },
    .{ .name = "KEY_LEFT_SHIFT", .code = 340 },
    .{ .name = "KEY_LEFT_CONTROL", .code = 341 },
    .{ .name = "KEY_LEFT_ALT", .code = 342 },
    .{ .name = "KEY_LEFT_SUPER", .code = 343 },
    .{ .name = "KEY_RIGHT_SHIFT", .code = 344 },
    .{ .name = "KEY_RIGHT_CONTROL", .code = 345 },
    .{ .name = "KEY_RIGHT_ALT", .code = 346 },
    .{ .name = "KEY_RIGHT_SUPER", .code = 347 },
    .{ .name = "KEY_MENU", .code = 348 },
};

const joy_names = [_]struct { name: []const u8, button: u8 }{
    .{ .name = "JOY_A", .button = 0 },
    .{ .name = "JOY_B", .button = 1 },
    .{ .name = "JOY_X", .button = 2 },
    .{ .name = "JOY_Y", .button = 3 },
    .{ .name = "JOY_L1", .button = 4 },
    .{ .name = "JOY_R1", .button = 5 },
    .{ .name = "JOY_L2", .button = 6 },
    .{ .name = "JOY_R2", .button = 7 },
    .{ .name = "JOY_SELECT", .button = 8 },
    .{ .name = "JOY_START", .button = 9 },
    .{ .name = "JOY_L3", .button = 10 },
    .{ .name = "JOY_R3", .button = 11 },
};

/// One action, resolved: what the per-frame pump iterates. `keys` and `joy`
/// are code lists, not names — resolution happens once, at boot, not per frame.
pub const ResolvedBinding = struct {
    action: []const u8,
    keys: []const i32 = &.{},
    joy: []const u8 = &.{},
};

/// The engine-facing view of an input map. This is `project.RuntimeConfig` at
/// the engine boundary: a `Config` the subsystems can index by code.
pub const RuntimeConfig = struct {
    bindings: []const ResolvedBinding = &.{},
    arena: ?*std.heap.ArenaAllocator = null,

    pub fn action(self: *const RuntimeConfig, name: []const u8) ?ResolvedBinding {
        for (self.bindings) |b| {
            if (std.mem.eql(u8, b.action, name)) return b;
        }
        return null;
    }

    pub fn deinit(self: *RuntimeConfig) void {
        if (self.arena) |arena| {
            const child = arena.child_allocator;
            arena.deinit();
            child.destroy(arena);
            self.arena = null;
        }
    }
};

pub const ResolveError = error{OutOfMemory};

/// Resolves every action's bindings into codes. Unknown names are warned about
/// and skipped: a config with one typo still binds the other twelve keys, and
/// the log names the typo. Arena-owned, `deinit` when done.
pub fn resolve(allocator: Allocator, cfg: *const Config) ResolveError!RuntimeConfig {
    var arena = allocator.create(std.heap.ArenaAllocator) catch return error.OutOfMemory;
    arena.* = std.heap.ArenaAllocator.init(allocator);
    errdefer {
        arena.deinit();
        allocator.destroy(arena);
    }
    const alloc = arena.allocator();

    var list: std.ArrayList(ResolvedBinding) = .empty;
    errdefer list.deinit(alloc);

    for (cfg.input_map) |action| {
        var keys: std.ArrayList(i32) = .empty;
        errdefer keys.deinit(alloc);
        var joy: std.ArrayList(u8) = .empty;
        errdefer joy.deinit(alloc);
        for (action.bindings) |name| {
            if (joyButtonFromName(name)) |button| {
                // The config is right; the platform layer has no joystick
                // polling yet. Say so once per binding, at boot, not per frame.
                log.warn("binding {s} for action '{s}': joystick input is not polled yet, ignoring", .{ name, action.name });
                try joy.append(alloc, button);
                continue;
            }
            if (keyFromName(name)) |code| {
                try keys.append(alloc, code);
            } else {
                log.warn("unknown binding '{s}' for action '{s}'", .{ name, action.name });
            }
        }
        const owned_action = try alloc.dupe(u8, action.name);
        try list.append(alloc, .{
            .action = owned_action,
            .keys = try keys.toOwnedSlice(alloc),
            .joy = try joy.toOwnedSlice(alloc),
        });
    }

    return .{
        .bindings = try list.toOwnedSlice(alloc),
        .arena = arena,
    };
}

test "runtime: key names resolve to GLFW codes, unknown names to null" {
    try std.testing.expectEqual(@as(?i32, 'A'), keyFromName("KEY_A"));
    try std.testing.expectEqual(@as(?i32, '9'), keyFromName("KEY_9"));
    try std.testing.expectEqual(@as(?i32, 256), keyFromName("KEY_ESCAPE"));
    try std.testing.expectEqual(@as(?i32, 263), keyFromName("KEY_LEFT"));
    try std.testing.expectEqual(@as(?i32, 340), keyFromName("KEY_LEFT_SHIFT"));
    try std.testing.expectEqual(@as(?i32, null), keyFromName("KEY_TYPO"));
    try std.testing.expectEqual(@as(?i32, null), keyFromName("A"));
    try std.testing.expectEqual(@as(?u8, 0), joyButtonFromName("JOY_A"));
    try std.testing.expect(isJoystickBinding("JOY_START"));
    try std.testing.expect(!isJoystickBinding("KEY_A"));
}

test "runtime: resolve drops unknown bindings and keeps the known ones" {
    var cfg = Config{
        .input_map = &.{
            .{ .name = "jump", .bindings = &.{ "KEY_SPACE", "KEY_W" } },
            .{ .name = "attack", .bindings = &.{ "JOY_A", "KEY_NOT_A_KEY" } },
        },
    };
    defer cfg.deinit();
    var resolved = try resolve(std.testing.allocator, &cfg);
    defer resolved.deinit();

    try std.testing.expectEqual(@as(usize, 2), resolved.bindings.len);
    const jump = resolved.action("jump").?;
    try std.testing.expectEqual(@as(usize, 2), jump.keys.len);
    try std.testing.expectEqual(@as(i32, 32), jump.keys[0]);
    const attack = resolved.action("attack").?;
    try std.testing.expectEqual(@as(usize, 0), attack.keys.len); // typo dropped
    try std.testing.expectEqual(@as(usize, 1), attack.joy.len);
}

test "runtime: apply refuses an invalid config and touches no target" {
    const S = struct {
        var calls: usize = 0;
        fn display(_: *anyopaque, _: *const config.Display) void {
            calls += 1;
        }
    };
    S.calls = 0;

    var bad = Config{};
    bad.display.width = 99999; // above the schema max
    defer bad.deinit();
    try std.testing.expectError(schema.ValidationError.OutOfRange, apply(&bad, .{
        .ctx = @ptrFromInt(1),
        .display = S.display,
    }));
    try std.testing.expectEqual(@as(usize, 0), S.calls);

    var good = Config{};
    defer good.deinit();
    try apply(&good, .{ .ctx = @ptrFromInt(1), .display = S.display });
    try std.testing.expectEqual(@as(usize, 1), S.calls);
}
