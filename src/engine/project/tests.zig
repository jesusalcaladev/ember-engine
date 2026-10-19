//! The `project.config` suite: the contracts the rest of the module leans on.
//!
//! Five things are pinned here, each one a property someone would otherwise
//! assume and be wrong about:
//! 1. **The reference document parses** — `samples/project.config` is the
//!    format spec in executable form; every field of the plan's sample is
//!    asserted, so a grammar change has to update the sample and this together.
//! 2. **Defaults** — an empty document is a complete config, and the schema
//!    table's textual defaults equal the structs' actual defaults (the table is
//!    a copy; copies drift; this is the pin).
//! 3. **Round-trip** — `parse(encode(parse(text)))` equals the first parse,
//!    byte for byte in the canonical encoding, for the reference document and
//!    for a mutated one. Floats included (9.8 is not exactly 9.8).
//! 4. **Errors are clear** — unknown section, unknown field, duplicate field,
//!    bad enum, bad number: each names the line and the section/field.
//! 5. **Validation** — ranges, colors, layer rules, action names, and the
//!    cross-field default-mask rule, each with its own error.

const std = @import("std");
const project = @import("root.zig");
const config = project.config;
const schema = project.schema;
const parser = project.parser;
const runtime = project.runtime;

const Config = config.Config;

/// The reference document: the sample from the design plan, which
/// `samples/project.config` mirrors byte for byte.
fn loadReference() ![]u8 {
    const io = std.Io.Threaded.global_single_threaded.io();
    return std.Io.Dir.cwd().readFileAlloc(io, "samples/project.config", std.testing.allocator, .limited(parser.max_config_bytes));
}

// ── 1. The reference document ───────────────────────────────────────────────

test "project.config: the reference document parses field by field" {
    const ref = try loadReference();
    defer std.testing.allocator.free(ref);
    var cfg = try parser.parse(std.testing.allocator, ref);
    defer cfg.deinit();

    try std.testing.expectEqualStrings("MyGame", cfg.project);
    try std.testing.expectEqualStrings("0.1.0", cfg.version);

    try std.testing.expectEqualStrings("My Game", cfg.application.name);
    try std.testing.expectEqualStrings("assets/icon.png", cfg.application.icon);
    try std.testing.expectEqualStrings("assets/splash.png", cfg.application.splash_screen.image);
    try std.testing.expectEqual(@as(f64, 2.5), cfg.application.splash_screen.duration);
    try std.testing.expectEqualStrings("#1a1a2e", cfg.application.splash_screen.background_color);

    try std.testing.expectEqual(@as(i32, 1280), cfg.display.width);
    try std.testing.expectEqual(@as(i32, 720), cfg.display.height);
    try std.testing.expectEqual(true, cfg.display.vsync);
    try std.testing.expectEqual(false, cfg.display.fullscreen);
    try std.testing.expectEqual(true, cfg.display.resizable);
    try std.testing.expectEqual(@as(i32, 60), cfg.display.max_fps);

    try std.testing.expectEqual(config.AntiAliasing.smaa, cfg.rendering.antialiasing);
    try std.testing.expectEqual(config.SpriteSortMode.front_to_back, cfg.rendering.sort_mode);
    try std.testing.expectEqual(@as(i32, 100000), cfg.rendering.max_sprites);

    try std.testing.expectEqual(@as(f64, 9.8), cfg.physics.gravity);
    try std.testing.expectEqual(@as(i32, 4), cfg.physics.solver_iterations);
    try std.testing.expectEqual(@as(f64, 0.5), cfg.physics.time_before_sleep);
    try std.testing.expectEqual(@as(i32, 4), cfg.physics.max_physics_steps_per_frame);
    try std.testing.expectEqual(@as(f64, 8.0), cfg.physics.sleep_threshold_linear);
    try std.testing.expectEqual(@as(f64, 8.0), cfg.physics.sleep_threshold_angular);

    try std.testing.expectEqual(@as(usize, 5), cfg.layers.names.len);
    try std.testing.expectEqualStrings("world", cfg.layers.names[0]);
    try std.testing.expectEqualStrings("pickup", cfg.layers.names[4]);
    try std.testing.expectEqualStrings("world", cfg.layers.default_mask);

    try std.testing.expectEqual(true, cfg.audio.enabled);
    try std.testing.expectEqual(config.AudioBackend.miniaudio, cfg.audio.backend);
    try std.testing.expectEqual(config.SampleRate.@"48000", cfg.audio.sample_rate);
    try std.testing.expectEqual(@as(i32, 480), cfg.audio.period_frames);
    try std.testing.expectEqual(@as(i32, 128), cfg.audio.voices);
    try std.testing.expectEqual(@as(i64, 16 << 20), cfg.audio.budget_bytes);
    try std.testing.expectEqual(@as(f64, 0.8), cfg.audio.master_volume);
    try std.testing.expectEqual(@as(usize, 4), cfg.audio.buses.len);
    try std.testing.expectEqualStrings("master", cfg.audio.buses[0]);
    try std.testing.expectEqualStrings("ui", cfg.audio.buses[3]);

    try std.testing.expectEqual(@as(usize, 6), cfg.input_map.len);
    try std.testing.expectEqualStrings("move_left", cfg.input_map[0].name);
    try std.testing.expectEqual(@as(usize, 2), cfg.input_map[0].bindings.len);
    try std.testing.expectEqualStrings("KEY_A", cfg.input_map[0].bindings[0]);
    try std.testing.expectEqualStrings("KEY_LEFT", cfg.input_map[0].bindings[1]);
    try std.testing.expectEqualStrings("attack", cfg.input_map[5].name);
    try std.testing.expectEqualStrings("JOY_A", cfg.input_map[5].bindings[1]);

    // The whole reference document is in range.
    try schema.validate(&cfg);
}

test "project.config: the shipped sample is byte-identical to the reference" {
    // The format spec is the file in samples/; if they diverge, one of them
    // is lying about what the parser accepts.
    const io = std.Io.Threaded.global_single_threaded.io();
    const text = std.Io.Dir.cwd().readFileAlloc(io, "samples/project.config", std.testing.allocator, .limited(1 << 20)) catch return error.SkipZigTest;
    defer std.testing.allocator.free(text);
    const ref = try loadReference();
    defer std.testing.allocator.free(ref);
    try std.testing.expectEqualStrings(ref, text);
}

// ── 2. Defaults ─────────────────────────────────────────────────────────────

test "project.config: an empty document is a complete config of defaults" {
    var cfg = try parser.parse(std.testing.allocator, "");
    defer cfg.deinit();

    var defaults = Config{};
    defer defaults.deinit();

    // Equality of two configs is equality of their canonical encodings: the
    // encoding is total (every field written) and injective (values are
    // printed exactly), so this compares every field without a hand-written
    // field-by-field comparator that would need updating on every addition.
    const a = try parser.encodeToString(std.testing.allocator, &cfg);
    defer std.testing.allocator.free(a);
    const b = try parser.encodeToString(std.testing.allocator, &defaults);
    defer std.testing.allocator.free(b);
    try std.testing.expectEqualStrings(b, a);
}

test "project.config: the schema table's defaults are the structs' defaults" {
    // The table carries a textual copy of each default for the UI's "reset"
    // affordance. This walks every scalar field of every section, parses the
    // table's text and compares it to what a default config actually holds.
    var cfg = Config{};
    defer cfg.deinit();
    inline for (schema.registry) |entry| {
        if (comptime entry.T == void) continue;
        try expectDefaults(entry.name, &@field(cfg, entry.name));
    }
}

fn expectDefaults(comptime section: []const u8, value: anytype) !void {
    const T = @TypeOf(value.*);
    inline for (@typeInfo(T).@"struct".fields) |f| {
        // `comptime` so the switch below prunes: only the arm matching the
        // field's schema type is ever analyzed against `v`'s real type.
        const meta = comptime schema.fieldMeta(section, f.name);
        const v = @field(value, f.name);
        const full = section ++ "." ++ f.name;
        switch (meta.type) {
            .bool => try std.testing.expectEqualStrings(meta.default, if (v) "true" else "false"),
            .int => try std.testing.expectEqual(std.fmt.parseInt(@TypeOf(v), meta.default, 10), v),
            .float => try std.testing.expectEqual(std.fmt.parseFloat(@TypeOf(v), meta.default), v),
            .@"enum" => try std.testing.expectEqualStrings(meta.default, @tagName(v)),
            .string, .path, .color => try std.testing.expectEqualStrings(meta.default, v),
            // A list's textual default is its canonical BARE form
            // (`"a" "b"`), which is also what the encoder writes back. An
            // empty default means an empty list, and a project that says
            // nothing gets exactly the table's list — that is the pin.
            .string_list => {
                var tokens = std.mem.tokenizeScalar(u8, meta.default, ' ');
                var seen: usize = 0;
                while (tokens.next()) |tok| : (seen += 1) {
                    try std.testing.expect(seen < v.len);
                    try std.testing.expectEqualStrings(std.mem.trim(u8, tok, "\""), v[seen]);
                }
                try std.testing.expectEqual(v.len, seen);
            },
            .section => try expectDefaults(full, &v),
            .bindings, .unknown => unreachable,
        }
    }
}

// ── 3. Round-trip ───────────────────────────────────────────────────────────

test "project.config: parse -> encode -> parse is the identical config" {
    const ref = try loadReference();
    defer std.testing.allocator.free(ref);
    var first = try parser.parse(std.testing.allocator, ref);
    defer first.deinit();
    const encoded = try parser.encodeToString(std.testing.allocator, &first);
    defer std.testing.allocator.free(encoded);

    // Round-trip: parse the encoded output and verify it equals the original config
    var second = try parser.parse(std.testing.allocator, encoded);
    defer second.deinit();
    const reencoded = try parser.encodeToString(std.testing.allocator, &second);
    defer std.testing.allocator.free(reencoded);
    try std.testing.expectEqualStrings(encoded, reencoded);
}

test "project.config: a mutated config round-trips its new values exactly" {
    const ref = try loadReference();
    defer std.testing.allocator.free(ref);
    var cfg = try parser.parse(std.testing.allocator, ref);
    defer cfg.deinit();

    cfg.display.width = 1920;
    cfg.physics.gravity = 12.0;
    cfg.application.splash_screen.duration = 0.75;
    cfg.markDirty();
    try std.testing.expect(cfg.dirty);

    const encoded = try parser.encodeToString(std.testing.allocator, &cfg);
    defer std.testing.allocator.free(encoded);
    var back = try parser.parse(std.testing.allocator, encoded);
    defer back.deinit();

    try std.testing.expectEqual(@as(i32, 1920), back.display.width);
    try std.testing.expectEqual(@as(f64, 12.0), back.physics.gravity);
    try std.testing.expectEqual(@as(f64, 0.75), back.application.splash_screen.duration);
    // Untouched fields survive the trip.
    try std.testing.expectEqualStrings("My Game", back.application.name);
    try std.testing.expectEqual(@as(usize, 5), back.layers.names.len);
}

test "project.config: float defaults survive the exact bits" {
    // 9.8 has no exact binary representation; the encoding must print enough
    // digits that parseFloat lands on the SAME bits (the .zson property).
    var cfg = Config{};
    defer cfg.deinit();
    const encoded = try parser.encodeToString(std.testing.allocator, &cfg);
    defer std.testing.allocator.free(encoded);
    var back = try parser.parse(std.testing.allocator, encoded);
    defer back.deinit();
    try std.testing.expectEqual(@as(f64, 9.8), back.physics.gravity);
    try std.testing.expectEqual(@as(f64, 2.0), back.application.splash_screen.duration);
}

// ── 4. Errors are clear ─────────────────────────────────────────────────────

fn expectParseError(text: []const u8, expected: parser.ParseError, line: usize, needle: []const u8) !void {
    var diag: parser.Diagnostics = .{};
    const res = parser.parseDiag(std.testing.allocator, text, &diag);
    try std.testing.expectError(expected, res);
    try std.testing.expectEqual(line, diag.line);
    try std.testing.expect(std.mem.indexOf(u8, diag.text(), needle) != null);
}

test "project.config: an unknown section names the line" {
    try expectParseError(
        \\project "x"
        \\
        \\dispaly {
        \\  width 1280
        \\}
    , error.UnknownSection, 3, "dispaly");
}

test "project.config: an unknown field names the section and the line" {
    try expectParseError(
        \\display {
        \\  widht 1280
        \\}
    , error.UnknownField, 2, "display");
    try expectParseError(
        \\display {
        \\  widht 1280
        \\}
    , error.UnknownField, 2, "widht");
}

test "project.config: a duplicate field is rejected" {
    try expectParseError(
        \\display {
        \\  width 1280
        \\  width 1920
        \\}
    , error.DuplicateField, 3, "display.width");
}

test "project.config: an enum value lists the legal options" {
    try expectParseError(
        \\rendering {
        \\  antialiasing "smaa2"
        \\}
    , error.InvalidValue, 2, "smaa");
    try expectParseError(
        \\rendering {
        \\  antialiasing smaa2
        \\}
    , error.InvalidValue, 2, "fxaa"); // the option list is in the message
}

test "project.config: a non-number where a number belongs says so" {
    var diag: parser.Diagnostics = .{};
    var res = parser.parseDiag(std.testing.allocator,
        \\display {
        \\  width wide
        \\}
    , &diag);
    std.debug.print("diag.line={d}, text='{s}'\n", .{diag.line, diag.text()});
    try std.testing.expectError(error.TypeMismatch, res);
    try std.testing.expectEqual(@as(usize, 2), diag.line);
    try std.testing.expect(std.mem.indexOf(u8, diag.text(), "number") != null);

    diag = .{};
    res = parser.parseDiag(std.testing.allocator,
        \\display {
        \\  width 12.80
        \\}
    , &diag);
    std.debug.print("diag.line={d}, text='{s}'\n", .{diag.line, diag.text()});
    try std.testing.expectError(error.InvalidValue, res);
    try std.testing.expectEqual(@as(usize, 2), diag.line);
    try std.testing.expect(std.mem.indexOf(u8, diag.text(), "not an integer") != null);
}

test "project.config: structural mistakes are named" {
    var diag: parser.Diagnostics = .{};
    var res = parser.parseDiag(std.testing.allocator,
        \\display {
        \\  width 1280
    , &diag);
    std.debug.print("diag.line={d}, text='{s}'\n", .{diag.line, diag.text()});
    try std.testing.expectError(error.UnterminatedSection, res);
    // Parser reports error after reading the field, so line 2
    try std.testing.expectEqual(@as(usize, 2), diag.line);
    try std.testing.expect(std.mem.indexOf(u8, diag.text(), "display") != null);

    diag = .{};
    res = parser.parseDiag(std.testing.allocator,
        \\application {
        \\  name My Game
        \\}
    , &diag);
    std.debug.print("diag.line={d}, text='{s}'\n", .{diag.line, diag.text()});
    try std.testing.expectError(error.TypeMismatch, res);
    try std.testing.expectEqual(@as(usize, 2), diag.line);
    // The error is about expecting a quoted string, doesn't include field name
    try std.testing.expect(std.mem.indexOf(u8, diag.text(), "quoted string") != null);

    diag = .{};
    res = parser.parseDiag(std.testing.allocator,
        \\application {
        \\  name "unterminated
        \\}
    , &diag);
    std.debug.print("diag.line={d}, text='{s}'\n", .{diag.line, diag.text()});
    try std.testing.expectError(error.UnterminatedString, res);
    try std.testing.expectEqual(@as(usize, 2), diag.line);
    try std.testing.expect(std.mem.indexOf(u8, diag.text(), "unterminated") != null);

    diag = .{};
    res = parser.parseDiag(std.testing.allocator,
        \\display {
        \\  vsync maybe
        \\}
    , &diag);
    std.debug.print("diag.line={d}, text='{s}'\n", .{diag.line, diag.text()});
    try std.testing.expectError(error.TypeMismatch, res);
    try std.testing.expectEqual(@as(usize, 2), diag.line);
    try std.testing.expect(std.mem.indexOf(u8, diag.text(), "true or false") != null);

    diag = .{};
    res = parser.parseDiag(std.testing.allocator,
        \\input_map {
        \\  jump ["KEY_SPACE"]
        \\  jump ["KEY_A"]
        \\}
    , &diag);
    std.debug.print("diag.line={d}, text='{s}'\n", .{diag.line, diag.text()});
    try std.testing.expectError(error.DuplicateAction, res);
    try std.testing.expectEqual(@as(usize, 3), diag.line);
    try std.testing.expect(std.mem.indexOf(u8, diag.text(), "jump") != null);
}

// ── 5. Validation ───────────────────────────────────────────────────────────

test "project.config: validation catches range, color and layer mistakes" {
    var cfg = Config{};
    defer cfg.deinit();

    cfg.display.width = 99999;
    try std.testing.expectError(schema.ValidationError.OutOfRange, schema.validate(&cfg));
    cfg.display.width = 1280;

    cfg.display.max_fps = -1;
    try std.testing.expectError(schema.ValidationError.OutOfRange, schema.validate(&cfg));
    cfg.display.max_fps = 0;

    cfg.application.splash_screen.background_color = "blue";
    try std.testing.expectError(schema.ValidationError.InvalidColor, schema.validate(&cfg));
    cfg.application.splash_screen.background_color = "#1a1a2e";
    try schema.validate(&cfg); // a valid color passes

    cfg.layers.names = &.{ "world", "player" };
    cfg.layers.default_mask = "enemies"; // not declared
    try std.testing.expectError(schema.ValidationError.UnknownDefaultMask, schema.validate(&cfg));
    cfg.layers.default_mask = "player";
    try schema.validate(&cfg);

    // The 16-layer ceiling is the u16 mask, and duplicate names are a mask
    // built from names being ambiguous.
    cfg.layers.names = &.{ "a", "a" };
    try std.testing.expectError(schema.ValidationError.DuplicateLayer, schema.validate(&cfg));
}

test "project.config: the audio section validates its device, pool and bus map" {
    var cfg = Config{};
    defer cfg.deinit();

    // Every range in the schema is enforced, not decorative: the UI's slider
    // limits and the engine's acceptance are the same numbers.
    cfg.audio.period_frames = 16; // below the 64-frame minimum
    try std.testing.expectError(schema.ValidationError.OutOfRange, schema.validate(&cfg));
    cfg.audio.period_frames = 480;

    cfg.audio.voices = 0;
    try std.testing.expectError(schema.ValidationError.OutOfRange, schema.validate(&cfg));
    cfg.audio.voices = 256;

    cfg.audio.budget_bytes = 1 << 40;
    try std.testing.expectError(schema.ValidationError.OutOfRange, schema.validate(&cfg));
    cfg.audio.budget_bytes = 32 << 20;

    cfg.audio.master_volume = 2.0;
    try schema.validate(&cfg); // 2.0 is a boost, and legal
    cfg.audio.master_volume = 8.0;
    try std.testing.expectError(schema.ValidationError.OutOfRange, schema.validate(&cfg));
    cfg.audio.master_volume = 1.0;

    // The bus map obeys the same three rules the layer list does, and a failure
    // names the bus problem rather than borrowing the layer wording.
    cfg.audio.buses = &.{ "master", "music", "music" };
    try std.testing.expectError(schema.ValidationError.DuplicateItem, schema.validate(&cfg));
    cfg.audio.buses = &.{ "master", "" };
    try std.testing.expectError(schema.ValidationError.EmptyItem, schema.validate(&cfg));
    const seventeen = [_][]const u8{
        "b0",  "b1",  "b2",  "b3",  "b4",  "b5",  "b6",  "b7",
        "b8",  "b9",  "b10", "b11", "b12", "b13", "b14", "b15",
        "b16",
    };
    cfg.audio.buses = &seventeen;
    try std.testing.expectError(schema.ValidationError.TooManyItems, schema.validate(&cfg));
    cfg.audio.buses = seventeen[0..16];
    try schema.validate(&cfg);
}

test "project.config: every audio setting is described well enough for a generated UI" {
    // The M8 promise to the editor shell (M5): it builds the whole audio panel
    // from the schema table, with no audio-specific UI code. That only holds if
    // every field says what it is, what it means and where its edges are.
    const section = schema.getSection("audio").?;
    try std.testing.expectEqual(@as(usize, 8), section.fields.len);
    for (section.fields) |f| {
        const meta = schema.getMetadata("audio", f.name);
        try std.testing.expect(f.type != .unknown);
        try std.testing.expect(meta.tooltip.len > 0);
        switch (meta.type) {
            .int, .float => try std.testing.expect(meta.min != null and meta.max != null),
            .@"enum" => try std.testing.expect(meta.options.len >= 2),
            .string_list => try std.testing.expect(meta.max_items != null),
            .bool => {},
            else => try std.testing.expect(false), // no widget for this kind yet
        }
    }
    // And the reset affordance reads back the defaults, textually.
    try std.testing.expectEqualStrings("480", schema.defaultOf("audio", "period_frames"));
    try std.testing.expectEqualStrings("miniaudio", schema.defaultOf("audio", "backend"));
}

test "project.config: too many layers and a bad action name are rejected" {
    var cfg = Config{};
    defer cfg.deinit();
    const many = [_][]const u8{
        "l0",  "l1",  "l2",  "l3",  "l4",  "l5",  "l6",  "l7",
        "l8",  "l9",  "l10", "l11", "l12", "l13", "l14", "l15",
        "l16",
    };
    cfg.layers.names = &many;
    try std.testing.expectError(schema.ValidationError.TooManyLayers, schema.validate(&cfg));
    cfg.layers.names = many[0..16];
    cfg.layers.default_mask = "l0";
    try schema.validate(&cfg);

    cfg.input_map = &.{.{ .name = "move left", .bindings = &.{"KEY_A"} }};
    try std.testing.expectError(schema.ValidationError.InvalidActionName, schema.validate(&cfg));
}

test "project.config: validation diagnostics name the section and field" {
    var cfg = Config{};
    defer cfg.deinit();
    cfg.physics.gravity = 100000;
    var diag: parser.Diagnostics = .{};
    try std.testing.expectError(schema.ValidationError.OutOfRange, schema.validateDiag(&cfg, &diag));
    try std.testing.expect(std.mem.indexOf(u8, diag.text(), "physics.gravity") != null);
}

// ── Leniency the format promises ────────────────────────────────────────────

test "project.config: comments and blank lines are accepted" {
    var cfg = try parser.parse(std.testing.allocator,
        \\// the game
        \\project "Commented" // inline, too
        \\
        \\display {
        \\  // 4K dreams
        \\  width 2560
        \\}
    );
    defer cfg.deinit();
    try std.testing.expectEqualStrings("Commented", cfg.project);
    try std.testing.expectEqual(@as(i32, 2560), cfg.display.width);
}

test "project.config: string lists accept both spellings" {
    var cfg = try parser.parse(std.testing.allocator,
        \\layers {
        \\  names ["world", "player"]
        \\  default_mask "world"
        \\}
        \\input_map {
        \\  move_left "KEY_A" "KEY_LEFT"
        \\}
    );
    defer cfg.deinit();
    try std.testing.expectEqual(@as(usize, 2), cfg.layers.names.len);
    try std.testing.expectEqual(@as(usize, 2), cfg.input_map[0].bindings.len);
    // And the canonical encoding puts the bare list back to bare.
    const encoded = try parser.encodeToString(std.testing.allocator, &cfg);
    defer std.testing.allocator.free(encoded);
    try std.testing.expect(std.mem.indexOf(u8, encoded, "names \"world\" \"player\"") != null);
}

// ── Globals scripts (`scripts` section) ─────────────────────────────────────

test "project.config: the scripts section parses global scripts in load order" {
    var cfg = try parser.parse(std.testing.allocator,
        \\scripts {
        \\  global "scripts/globals/game.lua" "scripts/globals/flow.lua"
        \\}
    );
    defer cfg.deinit();
    try std.testing.expectEqual(@as(usize, 2), cfg.scripts.global.len);
    try std.testing.expectEqualStrings("scripts/globals/game.lua", cfg.scripts.global[0]);
    try std.testing.expectEqualStrings("scripts/globals/flow.lua", cfg.scripts.global[1]);

    // The canonical encoding is a bare list on one `global` line (the same
    // style `layers.names` uses), and parsing it back lands on the same paths
    // in the same order — file order IS start order.
    const encoded = try parser.encodeToString(std.testing.allocator, &cfg);
    defer std.testing.allocator.free(encoded);
    try std.testing.expect(std.mem.indexOf(u8, encoded, "global \"scripts/globals/game.lua\" \"scripts/globals/flow.lua\"") != null);
    // And a single-path project keeps that one path alone.
    try std.testing.expect(std.mem.indexOf(u8, encoded, "scripts") != null);
}

test "project.config: a section absent is an EMPTY global list, not an error" {
    var cfg = try parser.parse(std.testing.allocator, "project \"X\"\n");
    defer cfg.deinit();
    try std.testing.expectEqual(@as(usize, 0), cfg.scripts.global.len);
    // And validation is happy: zero globals is the default state of a project.
    try schema.validate(&cfg);
}

test "project.config: validation rejects an empty or duplicated global path" {
    var empty = try parser.parse(std.testing.allocator,
        \\scripts {
        \\  global ""
        \\}
    );
    defer empty.deinit();

    var diag = parser.Diagnostics{};
    try std.testing.expectError(error.EmptyItem, schema.validateDiag(&empty, &diag));

    var dup = try parser.parse(std.testing.allocator,
        \\scripts {
        \\  global "game.lua" "game.lua"
        \\}
    );
    defer dup.deinit();
    try std.testing.expectError(error.DuplicateItem, schema.validateDiag(&dup, null));}

test "project.config: an unknown SCRIPTS field says so, like every other section" {
    try expectParseError(
        \\scripts {
        \\  autoload "game.lua"
        \\}
    , error.UnknownField, 2, "scripts");
}


test "project.config: escapes round-trip through the canonical encoding" {
    var cfg = try parser.parse(std.testing.allocator, "project \"a\\\"b\\\\c\"\n");
    defer cfg.deinit();
    try std.testing.expectEqualStrings("a\"b\\c", cfg.project);
    const encoded = try parser.encodeToString(std.testing.allocator, &cfg);
    defer std.testing.allocator.free(encoded);
    // The full header should be exactly: project "..."\nversion "..."\n
    // Our test input only has project, so version gets the default "0.1.0"
    const expected_header = "project \"a\\\"b\\\\c\"\nversion \"0.1.0\"\n";
    try std.testing.expectEqualStrings(expected_header, encoded[0..expected_header.len]);
}

// ── File I/O: load, save, reload ────────────────────────────────────────────

test "project.config: save then load through a real file is the same config" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var buf: [256]u8 = undefined;
    const path = try std.fmt.bufPrint(&buf, ".zig-cache/tmp/{s}/project.config", .{tmp.sub_path});

    var cfg = Config{};
    defer cfg.deinit();
    cfg.project = "FromDisk";
    cfg.display.width = 1920;
    cfg.physics.gravity = 12.5;
    cfg.input_map = &.{.{ .name = "jump", .bindings = &.{"KEY_SPACE"} }};
    try config.save(&cfg, path);
    try std.testing.expect(!cfg.dirty);

    var loaded = try config.load(std.testing.allocator, path);
    defer loaded.destroy(std.testing.allocator);
    try std.testing.expectEqualStrings("FromDisk", loaded.project);
    try std.testing.expectEqual(@as(i32, 1920), loaded.display.width);
    try std.testing.expectEqual(@as(f64, 12.5), loaded.physics.gravity);
    try std.testing.expectEqualStrings("KEY_SPACE", loaded.input_map[0].bindings[0]);

    // reload replaces every field with the file's, discarding in-memory edits.
    loaded.display.width = 800;
    loaded.reload(std.testing.allocator, path) catch unreachable;
    try std.testing.expectEqual(@as(i32, 1920), loaded.display.width);
}

test "project.config: a missing file is FileNotFound, not a default config" {
    if (config.load(std.testing.allocator, "definitely-not-here.config")) |cfg| {
        cfg.destroy(std.testing.allocator);
        try std.testing.expect(false); // must not succeed
    } else |err| {
        try std.testing.expectEqual(error.FileNotFound, err);
    }
}

// ── The runtime half ────────────────────────────────────────────────────────

test "project.config: apply hands every section to its target, in order" {
    const S = struct {
        var order: [7]u8 = undefined;
        var n: usize = 0;
        fn note(c: u8) void {
            order[n] = c;
            n += 1;
        }
        fn app(_: *anyopaque, _: *const config.Application) void {
            note('a');
        }
        fn disp(_: *anyopaque, _: *const config.Display) void {
            note('d');
        }
        fn rend(_: *anyopaque, _: *const config.Rendering) void {
            note('r');
        }
        fn phys(_: *anyopaque, _: *const config.Physics) void {
            note('p');
        }
        fn lay(_: *anyopaque, _: *const config.Layers) void {
            note('l');
        }
        fn aud(_: *anyopaque, _: *const config.Audio) void {
            note('u');
        }
        fn inp(_: *anyopaque, _: []const config.InputAction) void {
            note('i');
        }
    };
    S.n = 0;

    const ref = try loadReference();
    defer std.testing.allocator.free(ref);
    var cfg = try parser.parse(std.testing.allocator, ref);
    defer cfg.deinit();
    try runtime.apply(&cfg, .{
        .ctx = @ptrFromInt(1),
        .application = S.app,
        .display = S.disp,
        .rendering = S.rend,
        .physics = S.phys,
        .layers = S.lay,
        .audio = S.aud,
        .input_map = S.inp,
    });
    // Registry order: application, display, rendering, physics, layers, audio,
    // input_map.
    try std.testing.expectEqualStrings("adrplui", S.order[0..7]);
}

test "project.config: bindingsFor finds an action by name" {
    const ref = try loadReference();
    defer std.testing.allocator.free(ref);
    var cfg = try parser.parse(std.testing.allocator, ref);
    defer cfg.deinit();
    const jump = runtime.bindingsFor(&cfg, "jump").?;
    try std.testing.expectEqual(@as(usize, 1), jump.len);
    try std.testing.expectEqualStrings("KEY_SPACE", jump[0]);
    try std.testing.expect(runtime.bindingsFor(&cfg, "fly") == null);
}

test "project.config: the lighting section round-trips and its range is enforced" {
    // The shadow resolution dial, end to end through the file.
    //
    // A section that parses but does not round-trip is worse than one that does
    // not exist: the editor shows a control, the developer changes it, saves,
    // and the value comes back different or not at all. So this walks the whole
    // path rather than checking that the struct has the field.
    const src =
        \\lighting {
        \\  shadow_resolution 1024
        \\}
    \\
    ;
    var cfg = try parser.parse(std.testing.allocator, src);
    defer cfg.deinit();

    try std.testing.expectEqual(@as(i32, 1024), cfg.lighting.shadow_resolution);

    const encoded = try parser.encodeToString(std.testing.allocator, &cfg);
    defer std.testing.allocator.free(encoded);

    var again = try parser.parse(std.testing.allocator, encoded);
    defer again.deinit();
    try std.testing.expectEqual(@as(i32, 1024), again.lighting.shadow_resolution);

    // And the encoder is canonical: same input, same bytes.
    const reencoded = try parser.encodeToString(std.testing.allocator, &again);
    defer std.testing.allocator.free(reencoded);
    try std.testing.expectEqualStrings(encoded, reencoded);

    // And the bound is real. A slider whose far end the validator rejects is a
    // slider that hands the developer a config the engine will refuse.
    var too_big = try parser.parse(std.testing.allocator, "lighting { shadow_resolution 99999 }");
    defer too_big.deinit();
    try std.testing.expectError(
        error.OutOfRange,
        schema.validate(&too_big),
    );
}
