//! The comptime schema of `project.config`: one table that says what every
//! section and field IS, and everything that reads that table.
//!
//! Three consumers, one source of truth:
//! - the **UI** asks `getMetadata("display", "max_fps")` for the type, the
//!   range and the tooltip of a field, and gets the same answer the validator
//!   uses — a slider cannot drift out of the range the engine accepts;
//! - **validation** (`validate`) walks a `Config` against the table: ranges,
//!   colors, layer counts, the cross-field rule that `default_mask` names a
//!   layer that exists;
//! - **the parser and encoder** take section names and list styles from here,
//!   so the file format and the metadata are one artifact.
//!
//! The table is kept honest by construction: a comptime consistency check
//! walks every schema entry and the struct it describes, and fails to compile
//! on any disagreement — a field added to `Display` with no metadata, an enum
//! option missing from the table, a tooltip pointing at a field that no longer
//! exists. That is the same contract the ECS registry enforces on components
//! (registry.zig): dense, complete, and checked before anything runs.
//!
//! Defaults live in the structs in `config.zig` (a `Config{}` IS the defaults),
//! and the table carries a textual copy for the UI's "reset" affordance. A test
//! in `tests.zig` parses each textual default and compares it to the struct's,
//! so the copy cannot drift either.

const std = @import("std");
const core = @import("core");
const config = @import("config.zig");
const parser = @import("parser.zig");

const log = core.log.scoped("project");

pub const Config = config.Config;

/// What a field is, in the vocabulary the UI switches on.
pub const Kind = enum {
    bool,
    int,
    float,
    string,
    path,
    color,
    @"enum",
    string_list,
    /// A nested block (`splash_screen`): not editable as a scalar.
    section,
    /// An `input_map` action: a list of device names. `getMetadata` returns
    /// this for ANY field name in the `input_map` section, because actions are
    /// user-defined.
    bindings,
    /// Returned by `getMetadata` for a section or field the schema does not
    /// know: the UI shows the section as uneditable rather than guessing.
    unknown,
};

/// How a `string_list` is written by the canonical encoder. The parser accepts
/// either form for every list; the encoder picks one per field so a save never
/// rewrites the style the sample (and the user) started with.
pub const ListStyle = enum { bracketed, bare };

pub const Field = struct {
    name: []const u8,
    type: Kind = .string,
    /// Textual default, as it would appear in the file. Copy of the struct
    /// default; pinned by a test.
    default: []const u8 = "",
    /// Inclusive bounds, enforced by `validate`. Null = unbounded on that side.
    min: ?f64 = null,
    max: ?f64 = null,
    /// For `enum`: the legal values, in declaration order.
    options: []const []const u8 = &.{},
    tooltip: []const u8 = "",
    list_style: ListStyle = .bracketed,
    /// For `string_list`: the most items allowed (layers: `max_layers`).
    max_items: ?usize = null,
};

pub const Section = struct {
    /// Dotted path: `"application"` or `"application.splash_screen"`.
    name: []const u8,
    tooltip: []const u8 = "",
    fields: []const Field = &.{},
};

/// What `getMetadata` hands back. Same facts as a `Field`, minus the name.
pub const Metadata = struct {
    type: Kind = .unknown,
    default: []const u8 = "",
    min: ?f64 = null,
    max: ?f64 = null,
    options: []const []const u8 = &.{},
    tooltip: []const u8 = "",
    list_style: ListStyle = .bracketed,
    max_items: ?usize = null,
};

/// Section name → the struct that holds it. The parser decodes into `T` and the
/// encoder reads from it; `void` marks the one dynamic section (`input_map`),
/// whose fields are user-defined action names rather than struct fields.
pub const Entry = struct { name: []const u8, T: type };

/// Top-level sections, in file (and canonical output) order.
pub const registry: []const Entry = &.{
    .{ .name = "application", .T = config.Application },
    .{ .name = "display", .T = config.Display },
    .{ .name = "rendering", .T = config.Rendering },
    .{ .name = "lighting", .T = config.Lighting },
    .{ .name = "physics", .T = config.Physics },
    .{ .name = "layers", .T = config.Layers },
    .{ .name = "audio", .T = config.Audio },
    .{ .name = "input_map", .T = void },
};

/// Every section the file may contain, nested ones included. The UI iterates
/// this to build the panel; nothing else should hardcode the section list.
pub const sections: []const Section = &.{
    .{
        .name = "application",
        .tooltip = "What the project IS: title, icon, splash screen.",
        .fields = &.{
            .{ .name = "name", .type = .string, .default = "Untitled", .tooltip = "Window title and the name the OS shows for the game." },
            .{ .name = "icon", .type = .path, .tooltip = "Window icon image, relative to the project root. Empty = platform default." },
            .{ .name = "splash_screen", .type = .section, .tooltip = "Shown while the engine boots. No image = no splash." },
        },
    },
    .{
        .name = "application.splash_screen",
        .fields = &.{
            .{ .name = "image", .type = .path, .tooltip = "Splash image, relative to the project root." },
            .{ .name = "duration", .type = .float, .default = "2", .min = 0, .max = 60, .tooltip = "Seconds the splash stays on screen." },
            .{ .name = "background_color", .type = .color, .default = "#000000", .tooltip = "Backdrop while the splash is up, #rrggbb or #rgb." },
        },
    },
    .{
        .name = "display",
        .tooltip = "The window: size, borders and pacing.",
        .fields = &.{
            .{ .name = "width", .type = .int, .default = "1280", .min = 1, .max = 16384, .tooltip = "Window width in pixels (client area)." },
            .{ .name = "height", .type = .int, .default = "720", .min = 1, .max = 16384, .tooltip = "Window height in pixels (client area)." },
            .{ .name = "vsync", .type = .bool, .default = "true", .tooltip = "Fifo present mode: the display's refresh paces the frame." },
            .{ .name = "fullscreen", .type = .bool, .default = "false", .tooltip = "Start fullscreen on the primary monitor." },
            .{ .name = "resizable", .type = .bool, .default = "true", .tooltip = "Whether the user can resize the window." },
            .{ .name = "max_fps", .type = .int, .default = "0", .min = 0, .max = 1000, .tooltip = "Frame cap. 0 = unlimited (vsync still paces when on)." },
        },
    },
    .{
        .name = "rendering",
        .tooltip = "How the 2D renderer draws: order, capacity, edge smoothing.",
        .fields = &.{
            .{ .name = "antialiasing", .type = .@"enum", .default = "smaa", .options = &.{ "none", "smaa", "fxaa", "msaa" }, .tooltip = "Edge smoothing. Only 'none' and 'smaa' are implemented; the others are accepted and ignored with a warning." },
            .{ .name = "sort_mode", .type = .@"enum", .default = "front_to_back", .options = &.{ "none", "front_to_back", "back_to_front", "layer" }, .tooltip = "Sprite draw order. 'layer' is the engine's by_layer: stable inside a layer, layers ascending." },
            .{ .name = "max_sprites", .type = .int, .default = "50000", .min = 1, .max = 4_000_000, .tooltip = "GPU instance-buffer capacity. Boot-time: changing it re-creates the buffer." },
        },
    },
    .{
        .name = "lighting",
        .tooltip = "2D lighting budgets: what shadows and bounce light are allowed to cost.",
        .fields = &.{
            .{ .name = "gi_resolution", .type = .int, .default = "128", .min = 0, .max = 4096, .tooltip = "GI field resolution, longest side in cells. Lower = cheaper bounce light. 0 = one GI texel per shadow texel (the finest, and by far the most expensive: 264 ms per rebuild against 2.7 ms here)." },
            .{ .name = "shadow_resolution", .type = .int, .default = "1024", .min = 256, .max = 8192, .tooltip = "Shadow map resolution, longest side in cells. This is the shadow quality dial AND the per-frame cost dial, because the mask raster and the angular sweep run every time an occluder moves and both are linear in area. It does NOT affect the GI pyramid, which reads gi_resolution instead. Measured: 2048 costs 26.6 ms/frame of lighting on a moving-occluder frame against 9.5 ms here, and over a 1920-wide view 1024 is already one texel per ~2x2 screen pixels." },
            .{ .name = "gi_backend", .type = .@"enum", .default = "sky", .options = &.{ "off", "sky", "bounce" }, .tooltip = "Global illumination model. 'sky' traces to the sky and bounces it inward: right outdoors, nothing in a sealed room. 'bounce' carries the scene's own lights off the walls: right for interiors, and cheaper. 'off' is for a project that lights by hand -- it frees every GI buffer instead of skipping the work. A scene can override this per Environment." },
            .{ .name = "bounce_iterations", .type = .int, .default = "8", .min = 0, .max = 256, .tooltip = "Diffusion passes per frame for the 'bounce' model. Cost and how far light travels are both linear in it: a pass moves light exactly one cell. 0 turns the bounce off while leaving shadows and lights alone." },
            .{ .name = "bounce_albedo", .type = .float, .default = "0.6", .min = 0, .max = 1, .tooltip = "How much light a wall keeps on each bounce pass. 0.6 is a mid-grey painted wall; 0.2 is velvet. Two bounces through a corridor keep bounce_albedo squared." },
        },
    },
    .{
        .name = "physics",
        .tooltip = "The fixed-step solver: gravity, iteration budget, sleep.",
        .fields = &.{
            .{ .name = "gravity", .type = .float, .default = "9.8", .min = -1000, .max = 1000, .tooltip = "Gravity in m/s², +Y down (the engine's convention)." },
            .{ .name = "solver_iterations", .type = .int, .default = "4", .min = 1, .max = 64, .tooltip = "Box2D sub-steps per world step: quality vs cost in contacts." },
            .{ .name = "time_before_sleep", .type = .float, .default = "0.5", .min = 0, .max = 60, .tooltip = "Seconds a body stays under both thresholds before it sleeps." },
            .{ .name = "max_physics_steps_per_frame", .type = .int, .default = "4", .min = 1, .max = 16, .tooltip = "Catch-up cap: a stalled frame cannot spiral into a death spiral." },
            .{ .name = "sleep_threshold_linear", .type = .float, .default = "8", .min = 0, .max = 1000, .tooltip = "Linear velocity under this counts as resting." },
            .{ .name = "sleep_threshold_angular", .type = .float, .default = "8", .min = 0, .max = 1000, .tooltip = "Angular velocity under this counts as resting." },
        },
    },
    .{
        .name = "layers",
        .tooltip = "Named collision layers (the u16 mask: at most 16).",
        .fields = &.{
            .{ .name = "names", .type = .string_list, .list_style = .bare, .max_items = config.max_layers, .tooltip = "Layer names, in bit order: the first is bit 0, the sixteenth bit 15." },
            .{ .name = "default_mask", .type = .string, .default = "world", .tooltip = "Layer new entities join. Must be one of 'names' when layers are declared." },
        },
    },
    .{
        .name = "audio",
        .tooltip = "The mixer (M8): the device, the voice pool, the memory budget and the bus map.",
        .fields = &.{
            .{ .name = "enabled", .type = .bool, .default = "true", .tooltip = "Open a device at all. Off = nothing is mixed and the Lua surface reports zeros." },
            .{ .name = "backend", .type = .@"enum", .default = "miniaudio", .options = &.{ "null", "miniaudio" }, .tooltip = "'null' mixes with no device (editor preview, CI); 'miniaudio' opens a real one." },
            .{ .name = "sample_rate", .type = .@"enum", .default = "48000", .options = &.{ "44100", "48000" }, .tooltip = "Requested output rate. The mixer resamples to whatever the device negotiates." },
            .{ .name = "period_frames", .type = .int, .default = "480", .min = 64, .max = 8192, .tooltip = "Frames per device callback. 480 at 48 kHz is 10 ms; smaller means lower latency and more callbacks." },
            .{ .name = "voices", .type = .int, .default = "256", .min = 1, .max = 256, .tooltip = "Voice pool size, reserved at load. Past it a play steals the quietest voice." },
            .{ .name = "budget_bytes", .type = .int, .default = "33554432", .min = 1048576, .max = 268435456, .tooltip = "Decoded-PCM cache ceiling in bytes (spec §3.15). 32 MiB is about 90 seconds of stereo 48 kHz." },
            .{ .name = "master_volume", .type = .float, .default = "1", .min = 0, .max = 4, .tooltip = "Master gain (bus 0), applied after every bus sum." },
            .{ .name = "buses", .type = .string_list, .list_style = .bare, .default = "\"master\" \"music\" \"sfx\" \"ui\"", .max_items = config.max_audio_buses, .tooltip = "Bus names in id order; the first is master. Names are how scripts and the mixer panel address a bus." },
        },
    },
    .{
        .name = "input_map",
        .tooltip = "Named actions and the keys/buttons that trigger them: `jump [\"KEY_SPACE\"]`.",
        .fields = &.{},
    },
};

/// Metadata for one field, for the UI. Any `field` inside the `input_map`
/// section is `.bindings` — actions are user-defined, so the schema describes
/// the shape, not the names. Unknown section or field returns `.unknown`
/// (`type == .unknown`), which the UI reads as "do not offer an editor".
pub fn getMetadata(section: []const u8, field: []const u8) Metadata {
    for (sections) |*s| {
        if (!std.mem.eql(u8, s.name, section)) continue;
        for (s.fields) |f| {
            if (std.mem.eql(u8, f.name, field)) return metaOf(f);
        }
        if (std.mem.eql(u8, section, "input_map")) {
            return .{ .type = .bindings, .tooltip = "Device names that trigger this action, e.g. [\"KEY_A\", \"KEY_LEFT\"]." };
        }
        return .{};
    }
    return .{};
}

/// Metadata for a whole section (`fields` empty: iterate `sections`).
pub fn getSection(name: []const u8) ?Section {
    for (sections) |*s| {
        if (std.mem.eql(u8, s.name, name)) return s.*;
    }
    return null;
}

/// The table's textual default for a schema field. Comptime: a typo in the
/// section or field name is a compile error, not a null the UI forgets to
/// handle. The struct default is `Config{}` — this is its display copy.
pub fn defaultOf(comptime section: []const u8, comptime field: []const u8) []const u8 {
    return comptime fieldMeta(section, field).default;
}

// ── Validation ──────────────────────────────────────────────────────────────

pub const ValidationError = error{
    EmptyProjectName,
    EmptyVersion,
    OutOfRange,
    InvalidColor,
    TooManyLayers,
    EmptyLayerName,
    DuplicateLayer,
    UnknownDefaultMask,
    InvalidActionName,
    EmptyBinding,
    DuplicateAction,
    /// A `string_list` that is not `layers.names` (today: `audio.buses`) ran
    /// into the same three rules: capped, non-empty, distinct. Kept apart from
    /// the layer errors so a message can say "bus" and mean it.
    TooManyItems,
    EmptyItem,
    DuplicateItem,
};

/// Validates a config: ranges, colors, layer rules, action names. The first
/// problem stops it — a UI re-validates after each fix, and the second problem
/// is still there when it does.
pub fn validate(cfg: *const Config) !void {
    try validateDiag(cfg, null);
}

/// `validate` with a diagnostics sink naming the offending section and field.
pub fn validateDiag(cfg: *const Config, diag: ?*parser.Diagnostics) !void {
    if (cfg.project.len == 0) return fail(diag, "project", "", ValidationError.EmptyProjectName, "the project name is empty", .{});
    if (cfg.version.len == 0) return fail(diag, "project", "", ValidationError.EmptyVersion, "the version is empty", .{});

    // ONE LINE PER SECTION, and that is a property worth defending rather than a
    // style. `lighting.gi_resolution` was in `registry`, in `sections`, in the
    // struct, in the sample and in the parser, and every one of those accepted
    // it — while `validate` walked its own hand-written list that did not name
    // it. So the range check never ran: `gi_resolution 99999` validated clean,
    // and the slider's own far end would have handed developers a config the
    // engine rejected at boot.
    //
    // Two lists of the same sections is the defect; the comptime consistency
    // check below cannot catch it because both lists are individually complete.
    // The list below is now the only place a section has to be named.
    try validateSection(diag, "application", &cfg.application);
    try validateSection(diag, "display", &cfg.display);
    try validateSection(diag, "rendering", &cfg.rendering);
    try validateSection(diag, "lighting", &cfg.lighting);
    try validateSection(diag, "physics", &cfg.physics);
    try validateSection(diag, "layers", &cfg.layers);
    try validateSection(diag, "audio", &cfg.audio);

    // The one cross-field rule: a default mask naming a layer that does not
    // exist is a body that collides with nothing, silently.
    if (cfg.layers.names.len > 0) {
        var found = false;
        for (cfg.layers.names) |name| {
            if (std.mem.eql(u8, name, cfg.layers.default_mask)) found = true;
        }
        if (!found) return fail(diag, "layers", "default_mask", ValidationError.UnknownDefaultMask, "'{s}' is not one of the declared layers", .{cfg.layers.default_mask});
    }

    for (cfg.input_map) |action| {
        if (!isIdentifier(action.name)) return fail(diag, "input_map", action.name, ValidationError.InvalidActionName, "'{s}' is not a bare identifier: action names are written unquoted and must round-trip", .{action.name});
        for (action.bindings) |binding| {
            if (binding.len == 0) return fail(diag, "input_map", action.name, ValidationError.EmptyBinding, "action '{s}' has an empty binding", .{action.name});
        }
    }
}

fn validateSection(diag: ?*parser.Diagnostics, comptime section: []const u8, value: anytype) !void {
    const T = @TypeOf(value.*);
    inline for (@typeInfo(T).@"struct".fields) |sf| {
        const meta = fieldMeta(section, sf.name);
        const v = @field(value, sf.name);
        const full = section ++ "." ++ sf.name;
        // A plain string is range-free; only a string that CLAIMS a format is
        // checked (colors). Kept out of the switch below because `[]const u8`
        // is a slice like the lists are, and the two cases are not the same.
        if (sf.type == []const u8) {
            if (meta.type == .color) try checkColor(diag, section, sf.name, v);
            continue;
        }
        switch (@typeInfo(sf.type)) {
            .bool => {},
            .@"enum" => {},
            .int, .float => try checkRange(diag, section, sf.name, meta, asF64(v)),
            .@"struct" => try validateSection(diag, full, &v),
            .pointer => |ptr| {
                if (ptr.size != .slice or ptr.child != []const u8) {
                    @compileError("schema section '" ++ section ++ "' field '" ++ sf.name ++ "': unsupported slice type " ++ @typeName(sf.type));
                }
                // A list of names is a lookup table at runtime — a collision
                // mask's bits, a bus's id — so its three rules (capped,
                // non-empty, distinct) are checked here for every one of them.
                // The errors say which KIND of list failed, because "layer"
                // and "bus" are the words the person reading it knows.
                const names = comptime isNameList(section, sf.name);
                const too_many = comptime if (isLayersList(section, sf.name)) ValidationError.TooManyLayers else ValidationError.TooManyItems;
                const empty = comptime if (isLayersList(section, sf.name)) ValidationError.EmptyLayerName else ValidationError.EmptyItem;
                const dup = comptime if (isLayersList(section, sf.name)) ValidationError.DuplicateLayer else ValidationError.DuplicateItem;
                if (meta.max_items) |cap| {
                    if (v.len > cap) return fail(diag, section, sf.name, too_many, "{d} items exceeds the maximum of {d}", .{ v.len, cap });
                }
                for (v, 0..) |item, i| {
                    if (item.len == 0) return fail(diag, section, sf.name, empty, "item {d} has an empty name", .{i});
                }
                if (names) {
                    for (v, 0..) |a, i| {
                        for (v[i + 1 ..]) |b| {
                            if (std.mem.eql(u8, a, b)) {
                                if (comptime isLayersList(section, sf.name)) {
                                    return fail(diag, section, sf.name, dup, "layer '{s}' is declared twice", .{a});
                                }
                                return fail(diag, section, sf.name, dup, "name '{s}' is declared twice", .{a});
                            }
                        }
                    }
                }
            },
            else => @compileError("schema section '" ++ section ++ "' field '" ++ sf.name ++ "': unsupported type " ++ @typeName(sf.type)),
        }
    }
}

/// A `string_list` whose items are NAMES other things resolve through: the
/// layers (bit order) and the audio buses (id order). Both are lists a runtime
/// lookup walks, so both owe distinct, non-empty items.
fn isNameList(comptime section: []const u8, comptime field: []const u8) bool {
    return isLayersList(section, field) or
        (std.mem.eql(u8, section, "audio") and std.mem.eql(u8, field, "buses"));
}

fn isLayersList(comptime section: []const u8, comptime field: []const u8) bool {
    return std.mem.eql(u8, section, "layers") and std.mem.eql(u8, field, "names");
}

/// Any numeric field, as the f64 the range check compares against. `i64` does
/// not coerce to `f64` on its own (`audio.budget_bytes` is one), and the bounds
/// are exact: every schema integer fits an f64 mantissa.
fn asF64(value: anytype) f64 {
    return switch (@typeInfo(@TypeOf(value))) {
        .int => @floatFromInt(value),
        .float => @floatCast(value),
        else => @compileError("schema range check on a non-number: " ++ @typeName(@TypeOf(value))),
    };
}

fn checkRange(diag: ?*parser.Diagnostics, section: []const u8, field: []const u8, meta: Field, value: f64) !void {
    if (meta.min) |min| {
        if (value < min) return fail(diag, section, field, ValidationError.OutOfRange, "{d} is below the minimum of {d}", .{ value, min });
    }
    if (meta.max) |max| {
        if (value > max) return fail(diag, section, field, ValidationError.OutOfRange, "{d} is above the maximum of {d}", .{ value, max });
    }
}

fn checkColor(diag: ?*parser.Diagnostics, section: []const u8, field: []const u8, value: []const u8) !void {
    if (!isColor(value)) {
        return fail(diag, section, field, ValidationError.InvalidColor, "'{s}' is not #rrggbb or #rgb", .{value});
    }
}

fn isHexDigit(c: u8) bool {
    return (c >= '0' and c <= '9') or (c >= 'a' and c <= 'f') or (c >= 'A' and c <= 'F');
}

fn isColor(value: []const u8) bool {
    if (value.len != 7 and value.len != 4) return false;
    if (value[0] != '#') return false;
    for (value[1..]) |c| {
        if (!isHexDigit(c)) return false;
    }
    return true;
}

/// Identifier shape an action name must have to survive a save unquoted.
pub fn isIdentifier(name: []const u8) bool {
    if (name.len == 0) return false;
    const head = name[0];
    if (!std.ascii.isAlphabetic(head) and head != '_') return false;
    for (name[1..]) |c| {
        if (!std.ascii.isAlphanumeric(c) and c != '_') return false;
    }
    return true;
}

fn fail(
    diag: ?*parser.Diagnostics,
    section: []const u8,
    field: []const u8,
    err: ValidationError,
    comptime fmt: []const u8,
    args: anytype,
) ValidationError {
    if (diag) |d| {
        var where_buf: [160]u8 = undefined;
        const where = if (field.len > 0)
            std.fmt.bufPrint(&where_buf, "{s}.{s}: ", .{ section, field }) catch section
        else
            std.fmt.bufPrint(&where_buf, "{s}: ", .{section}) catch section;
        d.record(0, where, fmt, args); // no line: validation sees values, not text
    }
    return err;
}

// ── Lookup ──────────────────────────────────────────────────────────────────

fn metaOf(f: Field) Metadata {
    return .{
        .type = f.type,
        .default = f.default,
        .min = f.min,
        .max = f.max,
        .options = f.options,
        .tooltip = f.tooltip,
        .list_style = f.list_style,
        .max_items = f.max_items,
    };
}

/// Comptime field lookup: a section or field the table does not know is a
/// compile error wherever the engine asks for it — the alternative is a silent
/// `null` in the middle of a UI panel.
pub fn fieldMeta(comptime section: []const u8, comptime field: []const u8) Field {
    return comptime blk: {
        for (sections) |s| {
            if (!std.mem.eql(u8, s.name, section)) continue;
            for (s.fields) |f| {
                if (std.mem.eql(u8, f.name, field)) break :blk f;
            }
        }
        @compileError("project schema: no field '" ++ field ++ "' in section '" ++ section ++ "'");
    };
}

/// The struct type behind a top-level section name. `void` = dynamic section.
pub fn SectionType(comptime section: []const u8) type {
    return comptime blk: {
        for (registry) |entry| {
            if (std.mem.eql(u8, entry.name, section)) break :blk entry.T;
        }
        @compileError("project schema: no section '" ++ section ++ "'");
    };
}

// ── The consistency check ───────────────────────────────────────────────────
//
// The table and the structs describe the same document from two directions.
// This walks both and refuses to compile on any disagreement, which is the
// only check that runs early enough to be free: a schema field with no struct
// field, a struct field with no metadata, an enum option the type rejects, a
// nested struct with no sub-section.

fn assertConsistent(comptime section: []const u8, comptime T: type) void {
    comptime {
        // Walking six sections twice, every string compared byte by byte, adds
        // up: this check is worth the branch quota it asks for.
        @setEvalBranchQuota(10_000);
        const meta_fields = blk: {
            var found: ?Section = null;
            for (sections) |s| {
                if (std.mem.eql(u8, s.name, section)) found = s;
            }
            if (found == null) @compileError("project schema: section '" ++ section ++ "' has no metadata");
            break :blk found.?.fields;
        };
        // struct field -> metadata exists, and the facts agree with the type
        for (@typeInfo(T).@"struct".fields) |sf| {
            var m: ?Field = null;
            for (meta_fields) |f| {
                if (std.mem.eql(u8, f.name, sf.name)) m = f;
            }
            if (m == null) @compileError("project schema: field '" ++ section ++ "." ++ sf.name ++ "' has no metadata");
            const meta = m.?;
            // A plain string (path/color/string) is a slice too, and the
            // string-list case below would reject it as one.
            if (sf.type == []const u8) {
                if (meta.type != .string and meta.type != .path and meta.type != .color) {
                    @compileError("project schema: '" ++ section ++ "." ++ sf.name ++ "' is a string in the struct, " ++ @tagName(meta.type) ++ " in the table");
                }
                continue;
            }
            switch (@typeInfo(sf.type)) {
                .bool => if (meta.type != .bool) @compileError("project schema: '" ++ section ++ "." ++ sf.name ++ "' is bool in the struct, " ++ @tagName(meta.type) ++ " in the table"),
                .int => if (meta.type != .int) @compileError("project schema: '" ++ section ++ "." ++ sf.name ++ "' is int in the struct, " ++ @tagName(meta.type) ++ " in the table"),
                .float => if (meta.type != .float) @compileError("project schema: '" ++ section ++ "." ++ sf.name ++ "' is float in the struct, " ++ @tagName(meta.type) ++ " in the table"),
                .@"enum" => |e| {
                    if (meta.type != .@"enum") @compileError("project schema: '" ++ section ++ "." ++ sf.name ++ "' is an enum in the struct, " ++ @tagName(meta.type) ++ " in the table");
                    if (meta.options.len != e.fields.len) @compileError("project schema: '" ++ section ++ "." ++ sf.name ++ "' lists " ++ std.fmt.comptimePrint("{d}", .{meta.options.len}) ++ " options, the enum has " ++ std.fmt.comptimePrint("{d}", .{e.fields.len}));
                    for (e.fields, 0..) |ef, i| {
                        if (!std.mem.eql(u8, meta.options[i], ef.name)) @compileError("project schema: option " ++ std.fmt.comptimePrint("{d}", .{i}) ++ " of '" ++ section ++ "." ++ sf.name ++ "' is '" ++ meta.options[i] ++ "', the enum says '" ++ ef.name ++ "'");
                    }
                },
                .@"struct" => {
                    if (meta.type != .section) @compileError("project schema: '" ++ section ++ "." ++ sf.name ++ "' is a nested section in the struct, " ++ @tagName(meta.type) ++ " in the table");
                    assertConsistent(section ++ "." ++ sf.name, sf.type);
                },
                .pointer => |ptr| {
                    if (ptr.size != .slice or ptr.child != []const u8) @compileError("project schema: '" ++ section ++ "." ++ sf.name ++ "': unsupported slice type " ++ @typeName(sf.type));
                    if (meta.type != .string_list) @compileError("project schema: '" ++ section ++ "." ++ sf.name ++ "' is a string list in the struct, " ++ @tagName(meta.type) ++ " in the table");
                },
                else => @compileError("project schema: '" ++ section ++ "." ++ sf.name ++ "': unsupported type " ++ @typeName(sf.type)),
            }
        }
        // metadata -> struct field exists
        for (meta_fields) |f| {
            var found = false;
            for (@typeInfo(T).@"struct".fields) |sf| {
                if (std.mem.eql(u8, f.name, sf.name)) found = true;
            }
            if (!found) @compileError("project schema: metadata for '" ++ section ++ "." ++ f.name ++ "' has no struct field");
        }
    }
}

comptime {
    for (registry) |entry| {
        if (entry.T == void) continue;
        assertConsistent(entry.name, entry.T);
    }

    // Every section the document can contain must be VALIDATED.
    //
    // `lighting` shipped with metadata, a struct, a sample line and a parser,
    // and passed every consistency check above — because each of those is
    // individually complete — while `validateDiag`'s hand-written list never
    // named it, so its `gi_resolution` range was never enforced. Two complete
    // lists of the same sections is the defect, and neither existing check can
    // see it.
    //
    // So the validated list is now a declaration, and this compares it to
    // `registry`. Adding a section to one without the other is a compile error
    // naming both.
    for (registry) |entry| {
        if (entry.T == void) continue;
        var found = false;
        for (validated_sections) |name| {
            if (std.mem.eql(u8, name, entry.name)) found = true;
        }
        if (!found) @compileError(
            "project schema: section '" ++ entry.name ++
                "' is in the registry but not in `validated_sections`, so its fields would never be range-checked",
        );
    }
}

/// The sections `validateDiag` actually walks, in the order it walks them.
///
/// Mirrors `validateDiag`'s body, and the comptime block above refuses to let
/// the two disagree. `input_map` is absent because it is a list of actions
/// rather than a struct of fields, and is validated by its own loop.
const validated_sections = [_][]const u8{
    "application",
    "display",
    "rendering",
    "lighting",
    "physics",
    "layers",
    "audio",
};

test "schema: getMetadata answers for a real field, and says .unknown for the rest" {
    const fps = getMetadata("display", "max_fps");
    try std.testing.expectEqual(Kind.int, fps.type);
    try std.testing.expectEqual(@as(?f64, 0), fps.min);
    try std.testing.expectEqual(@as(?f64, 1000), fps.max);
    try std.testing.expect(fps.tooltip.len > 0);

    try std.testing.expectEqual(Kind.unknown, getMetadata("display", "widht").type);
    try std.testing.expectEqual(Kind.unknown, getMetadata("nonesuch", "x").type);

    // Any action name inside input_map is a binding list.
    try std.testing.expectEqual(Kind.bindings, getMetadata("input_map", "jump").type);
}

test "schema: the default text is what a default config holds" {
    var cfg = Config{};
    defer cfg.deinit();
    try std.testing.expectEqualStrings("Untitled", cfg.application.name);
    try std.testing.expectEqualStrings(defaultOf("display", "width"), "1280");
    try std.testing.expectEqualStrings(defaultOf("physics", "gravity"), "9.8");
    try std.testing.expectEqualStrings(defaultOf("rendering", "antialiasing"), "smaa");
}

test "schema: a default config validates" {
    var cfg = Config{};
    defer cfg.deinit();
    try validate(&cfg);
}
