//! Flat prefabs — creating them from a selection, instantiating them, and
//! reverting the overrides a user made to an instance.
//!
//! ## What a prefab is here
//!
//! A prefab is a **`.zson` document** holding one or more entities, exactly
//! like a scene — the same grammar, the same encoder, the same decoder. There
//! is no second format and no second parser: `zson.encodeToStringEntities`
//! writes a subset of the world and `zson.instantiate` spawns it back at fresh
//! identities. That is deliberate. A prefab format of its own would be a second
//! thing to keep in sync with the component registry, and the registry is
//! exactly what changes most often (every new component renumbers nothing but
//! does add a field to every record).
//!
//! ## The three operations
//!
//! - **Create from selection.** The selected entity (and, optionally, its
//!   children) is written to `prefabs/<name>.zson`. The document is the entity
//!   as it is RIGHT NOW — a prefab is a snapshot, not a template with rules.
//! - **Instantiate.** The document is spawned into the world at a fresh
//!   identity, with the names made unique (`enemy`, `enemy_2`, …) so two
//!   instances of the same prefab can coexist. This is `zson.instantiate`.
//! - **Revert.** Every instance records where it came from — the prefab file
//!   and the entity name inside it — in a **sidecar** `.overrides` file next to
//!   the scene. The sidecar lists, per instance, the properties that were
//!   changed after instantiation. "Revert" writes the prefab's values back
//!   over the instance's, for exactly those properties.
//!
//! ## Why the overrides live in a sidecar and not in the world
//!
//! Two reasons, and the second is the one that decides it.
//!
//! 1. The world is the SCENE. What the game loads is the world. A prefab
//!    instance in a scene is an ordinary entity with ordinary components — the
//!    game must not see editor bookkeeping, and a `PrefabInstance` component
//!    would be one more thing every `.zson` file carries.
//! 2. The overrides are per-PROPERTY, not per-component. `Sprite.tint` may
//!    have been changed while `Sprite.size` was not. A component cannot hold
//!    that without a registry entry, and the registry is append-only — a
//!    `SpriteOverrides` component would be a permanent, load-bearing addition
//!    to the engine's data model to serve a purely editorial feature.
//!
//! So the sidecar is a **text file beside the scene**, keyed by entity, and it
//! is written by the editor only. Losing it loses the ability to revert; it
//! never affects what the game loads.
//!
//! ## The format
//!
//! ```
//! # prefab overrides for samples/level.zson
//! instance <scene-id> <prefab-file> <entity-name-in-prefab>
//! override <scene-id> <component> <field> <value>
//! ```
//!
//! `instance` lines say where an instance came from. `override` lines say what
//! was changed on it. Both are comments-and-data: a line the editor does not
//! understand is skipped rather than fatal, because a file written by a newer
//! editor must not break an older one.

const std = @import("std");
const ecs = @import("engine").ecs;
const zson = ecs.zson;
const components = ecs.components;

/// One recorded change on an instance: a component and one of its fields.
///
/// The value is stored as TEXT — the same text `zson` writes — rather than as
/// bytes, because a byte blob of unknown length in a sidecar is a parsing
/// problem the format has no reason to have. The editor parses the text back
/// with the same decoder that reads a `.zson` file.
pub const Override = struct {
    /// The entity the override applies to (by scene id).
    entity: ecs.SceneId,
    /// The component's registry name ("Sprite").
    component: []const u8,
    /// The field's name within that component ("tint").
    field: []const u8,
    /// The value, as text.
    value: []const u8,
};

/// Where an instance came from.
pub const Instance = struct {
    entity: ecs.SceneId,
    /// The prefab file, relative to the project root ("prefabs/enemy.zson").
    prefab: []const u8,
    /// The entity's name inside the prefab document.
    source_name: []const u8,
};

/// The sidecar: instances and overrides for one scene.
///
/// Owned by the editor, freed with it. The strings are OWNED copies, not
/// slices into the file's buffer: the file is read once and parsed, and the
/// parsed state outlives it (the editor adds overrides to it as the user
/// works). A slice into a buffer the editor then frees would be a dangling
/// pointer waiting for a bad day.
pub const Sidecar = struct {
    allocator: std.mem.Allocator,
    instances: std.ArrayListUnmanaged(Instance) = .empty,
    overrides: std.ArrayListUnmanaged(Override) = .empty,

    pub fn deinit(self: *Sidecar) void {
        for (self.instances.items) |inst| {
            self.allocator.free(inst.prefab);
            self.allocator.free(inst.source_name);
        }
        for (self.overrides.items) |o| {
            self.allocator.free(o.component);
            self.allocator.free(o.field);
            self.allocator.free(o.value);
        }
        self.instances.deinit(self.allocator);
        self.overrides.deinit(self.allocator);
        self.* = undefined;
    }

    /// Reads a sidecar. A missing file is an EMPTY sidecar, not an error: a
    /// scene that has never had a prefab instantiated has no sidecar, and that
    /// is the normal case, not a failure.
    pub fn load(allocator: std.mem.Allocator, path: []const u8) !Sidecar {
        var self = Sidecar{ .allocator = allocator };
        errdefer self.deinit();

        const io = std.Io.Threaded.global_single_threaded.io();
        const bytes = std.Io.Dir.cwd().readFileAlloc(io, path, allocator, .limited(1 << 20)) catch |err| switch (err) {
            error.FileNotFound => return self,
            else => return err,
        };
        defer allocator.free(bytes);
        try self.parse(bytes);
        return self;
    }

    /// Parses the text. Every line is `keyword rest...`; an unknown keyword is
    /// skipped with the rest of the line, because a file from a newer editor
    /// must not make an older one fail to open the scene.
    ///
    /// The TEXT fields are quoted, because a name or a value may contain
    /// spaces — `{x: 5, y: -6}` is one value, not three tokens. The quotes are
    /// what make the format unambiguous, and the field reader below is what
    /// honours them: a plain whitespace tokenizer would cut the value in half.
    fn parse(self: *Sidecar, text: []const u8) !void {
        var lines = std.mem.splitScalar(u8, text, '\n');
        while (lines.next()) |raw| {
            const line = std.mem.trim(u8, raw, " \t\r");
            if (line.len == 0 or line[0] == '#') continue;

            var fields = Fields{ .text = line };
            const keyword = fields.next() orelse continue;
            if (std.mem.eql(u8, keyword, "instance")) {
                const id = fields.next() orelse continue;
                const prefab = fields.next() orelse continue;
                const source_name = fields.next() orelse continue;
                const parsed = std.fmt.parseInt(ecs.SceneId, id, 10) catch continue;
                try self.instances.append(self.allocator, .{
                    .entity = parsed,
                    .prefab = try unquote(prefab, self.allocator),
                    .source_name = try unquote(source_name, self.allocator),
                });
            } else if (std.mem.eql(u8, keyword, "override")) {
                const id = fields.next() orelse continue;
                const component = fields.next() orelse continue;
                const field = fields.next() orelse continue;
                const value = fields.next() orelse continue;
                const parsed = std.fmt.parseInt(ecs.SceneId, id, 10) catch continue;
                try self.overrides.append(self.allocator, .{
                    .entity = parsed,
                    .component = try unquote(component, self.allocator),
                    .field = try unquote(field, self.allocator),
                    .value = try unquote(value, self.allocator),
                });
            }
        }
    }

    /// The instance record for an entity, or null.
    pub fn instanceOf(self: *const Sidecar, entity: ecs.SceneId) ?Instance {
        for (self.instances.items) |inst| {
            if (inst.entity == entity) return inst;
        }
        return null;
    }

    /// The overrides recorded for an entity.
    ///
    /// The list is short by construction — a handful of fields on a handful of
    /// instances — so the filtered copy is cheaper than a view type would be.
    /// The allocation happens on a user action, never inside a frame.
    pub fn overridesOf(self: *const Sidecar, entity: ecs.SceneId, allocator: std.mem.Allocator) ![]Override {
        var out: std.ArrayListUnmanaged(Override) = .empty;
        errdefer out.deinit(allocator);
        for (self.overrides.items) |o| {
            if (o.entity == entity) try out.append(allocator, o);
        }
        return out.toOwnedSlice(allocator);
    }

    /// Records an override. The previous value for the same (entity,
    /// component, field) is REPLACED, not appended to: a field changed twice
    /// has one current value, and the prefab's is the one revert restores.
    pub fn setOverride(self: *Sidecar, entity: ecs.SceneId, component: []const u8, field: []const u8, value: []const u8) !void {
        for (self.overrides.items) |*o| {
            if (o.entity == entity and std.mem.eql(u8, o.component, component) and std.mem.eql(u8, o.field, field)) {
                self.allocator.free(o.value);
                o.value = try self.allocator.dupe(u8, value);
                return;
            }
        }
        try self.overrides.append(self.allocator, .{
            .entity = entity,
            .component = try self.allocator.dupe(u8, component),
            .field = try self.allocator.dupe(u8, field),
            .value = try self.allocator.dupe(u8, value),
        });
    }

    /// Records an instance's origin.
    ///
    /// An entity has ONE origin, so a second record for the same entity
    /// REPLACES the first: the scene id identifies the entity, and an entity
    /// that was re-instantiated from a different prefab has a different
    /// origin. Two records for one entity would make "where did this come
    /// from" have two answers.
    pub fn addInstance(self: *Sidecar, entity: ecs.SceneId, prefab: []const u8, source_name: []const u8) !void {
        for (self.instances.items) |*inst| {
            if (inst.entity == entity) {
                self.allocator.free(inst.prefab);
                self.allocator.free(inst.source_name);
                inst.prefab = try self.allocator.dupe(u8, prefab);
                inst.source_name = try self.allocator.dupe(u8, source_name);
                return;
            }
        }
        try self.instances.append(self.allocator, .{
            .entity = entity,
            .prefab = try self.allocator.dupe(u8, prefab),
            .source_name = try self.allocator.dupe(u8, source_name),
        });
    }

    /// Drops every override of an entity — the instance is back to being
    /// exactly what the prefab says.
    pub fn clearOverrides(self: *Sidecar, entity: ecs.SceneId) void {
        var kept: std.ArrayListUnmanaged(Override) = .empty;
        for (self.overrides.items) |o| {
            if (o.entity != entity) {
                kept.append(self.allocator, o) catch {
                    kept.deinit(self.allocator);
                    return;
                };
                continue;
            }
            self.allocator.free(o.component);
            self.allocator.free(o.field);
            self.allocator.free(o.value);
        }
        self.overrides.deinit(self.allocator);
        self.overrides = kept;
    }

    /// Writes the sidecar. The text is built fresh (so the file is always a
    /// faithful picture of the state, not an append-only log), and the file is
    /// written THROUGH a temporary name and renamed: a crash mid-write leaves
    /// the previous sidecar intact rather than a half-written one.
    pub fn save(self: *const Sidecar, path: []const u8) !void {
        var out: std.Io.Writer.Allocating = .init(self.allocator);
        defer out.deinit();
        const w = &out.writer;

        try w.writeAll("# ember editor: prefab overrides\n");
        for (self.instances.items) |inst| {
            try w.print("instance {d} ", .{inst.entity});
            try writeQuoted(w, inst.prefab);
            try w.writeByte(' ');
            try writeQuoted(w, inst.source_name);
            try w.writeByte('\n');
        }
        for (self.overrides.items) |o| {
            try w.print("override {d} {s} ", .{ o.entity, o.component });
            try writeQuoted(w, o.field);
            try w.writeByte(' ');
            try writeQuoted(w, o.value);
            try w.writeByte('\n');
        }

        const io = std.Io.Threaded.global_single_threaded.io();
        const tmp = try std.fmt.allocPrint(self.allocator, "{s}.tmp", .{path});
        defer self.allocator.free(tmp);
        try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = tmp, .data = out.writer.buffered() });
        // The rename is what makes the write atomic: until it happens the
        // temporary file exists and the sidecar does not, and after it the
        // sidecar is complete. There is no state in between.
        try std.Io.Dir.cwd().rename(tmp, std.Io.Dir.cwd(), path, io);
    }
};

/// The sidecar's path for a scene: the scene's path with `.overrides` tacked
/// on. `samples/level.zson` → `samples/level.zson.overrides`.
pub fn sidecarPath(allocator: std.mem.Allocator, scene_path: []const u8) ![]u8 {
    return std.fmt.allocPrint(allocator, "{s}.overrides", .{scene_path});
}

/// The prefab's path for a name: `prefabs/<name>.zson`.
///
/// The name is sanitised, because it comes from a user-typed label and ends up
/// in a path. Anything that is not a letter, a digit, a dash or an underscore
/// becomes an underscore — the same rule a build system uses for a symbol.
pub fn prefabPath(allocator: std.mem.Allocator, name: []const u8) ![]u8 {
    var safe: [128]u8 = undefined;
    const n = @min(name.len, safe.len);
    for (name[0..n], 0..) |c, i| {
        safe[i] = switch (c) {
            'a'...'z', 'A'...'Z', '0'...'9', '-', '_' => c,
            else => '_',
        };
    }
    if (n == 0) {
        @memcpy(safe[0..7], "prefab_");
        return std.fmt.allocPrint(allocator, "prefabs/{s}.zson", .{safe[0..7]});
    }
    return std.fmt.allocPrint(allocator, "prefabs/{s}.zson", .{safe[0..n]});
}

/// The value of one field of one component, as text.
///
/// The text is exactly what `zson` writes for that field — same encoder, same
/// shape — so an override recorded here is a value a `.zson` file could
/// contain, and it decodes back through the same parser. That is the whole
/// reason the sidecar stores text and not bytes.
///
/// A field that does not exist is an error, not a silent nothing: the caller
/// named a field, and a field that is not there is a bug worth reporting.
pub fn fieldValue(
    world: *ecs.World,
    entity: ecs.Entity,
    component_name: []const u8,
    field_name: []const u8,
    allocator: std.mem.Allocator,
) ![]u8 {
    const id = components.idOfName(component_name) orelse return error.UnknownComponent;
    var out: std.Io.Writer.Allocating = .init(allocator);
    errdefer out.deinit();
    try zson.encodeField(world, entity, id, field_name, &out.writer);
    return out.toOwnedSlice();
}

/// Writes a recorded value back into a field, replacing whatever is there.
///
/// The same decoder a `.zson` file goes through, so a value that the sidecar
/// holds is a value the engine understands.
pub fn applyFieldValue(
    world: *ecs.World,
    entity: ecs.Entity,
    component_name: []const u8,
    field_name: []const u8,
    text: []const u8,
) !void {
    const id = components.idOfName(component_name) orelse return error.UnknownComponent;
    try zson.decodeField(world, entity, id, field_name, text);
}

// ── Field reading ────────────────────────────────────────────────────────────

/// Reads the fields of one line, honouring the quotes.
///
/// A whitespace tokenizer would cut `"[1, 0.5, 0, 1]"` into four pieces, and
/// the value the editor wrote would come back as `[1,`. So the reader walks
/// the line: a quoted field runs to its closing quote, an unquoted one to the
/// next space. The quotes are left IN the field — `unquote` removes them, and
/// the two steps stay separate so a file written without quotes still reads.
const Fields = struct {
    text: []const u8,
    pos: usize = 0,

    fn next(self: *Fields) ?[]const u8 {
        while (self.pos < self.text.len and (self.text[self.pos] == ' ' or self.text[self.pos] == '\t')) {
            self.pos += 1;
        }
        if (self.pos >= self.text.len) return null;
        const start = self.pos;
        if (self.text[self.pos] == '"') {
            self.pos += 1;
            while (self.pos < self.text.len) : (self.pos += 1) {
                if (self.text[self.pos] == '\\' and self.pos + 1 < self.text.len) {
                    self.pos += 1;
                    continue;
                }
                if (self.text[self.pos] == '"') {
                    self.pos += 1;
                    break;
                }
            }
            return self.text[start..self.pos];
        }
        while (self.pos < self.text.len and self.text[self.pos] != ' ' and self.text[self.pos] != '\t') {
            self.pos += 1;
        }
        return self.text[start..self.pos];
    }
};

// ── Quoting ──────────────────────────────────────────────────────────────────

/// Writes a text field in quotes, escaping what needs escaping.
///
/// The sidecar's text fields (a path, a name, a value) may contain spaces, so
/// they are quoted. The escaping is the JSON one — a backslash and a quote —
/// because it is a standard everybody recognises.
fn writeQuoted(w: *std.Io.Writer, text: []const u8) !void {
    try w.writeByte('"');
    for (text) |c| {
        switch (c) {
            '"', '\\' => {
                try w.writeByte('\\');
                try w.writeByte(c);
            },
            '\n' => try w.writeAll("\\n"),
            else => try w.writeByte(c),
        }
    }
    try w.writeByte('"');
}

/// The inverse of `writeQuoted`: a quoted field becomes its text, and an
/// unquoted one is returned as it is (so a file written by an older editor,
/// which did not quote, still reads).
///
/// The result is written into `out`, which owns it — the caller frees it with
/// the allocator that made it.
fn unquote(text: []const u8, allocator: std.mem.Allocator) ![]u8 {
    if (text.len < 2 or text[0] != '"') return allocator.dupe(u8, text);
    const inner = text[1 .. text.len - 1];
    // The common case — no escapes — is a copy, with no scanning.
    if (std.mem.indexOfScalar(u8, inner, '\\') == null) return allocator.dupe(u8, inner);

    var out: std.ArrayListUnmanaged(u8) = .empty;
    errdefer out.deinit(allocator);
    var i: usize = 0;
    while (i < inner.len) : (i += 1) {
        if (inner[i] != '\\' or i + 1 >= inner.len) {
            try out.append(allocator, inner[i]);
            continue;
        }
        i += 1;
        switch (inner[i]) {
            'n' => try out.append(allocator, '\n'),
            else => try out.append(allocator, inner[i]),
        }
    }
    return out.toOwnedSlice(allocator);
}

const testing = std.testing;

test "a sidecar round-trips instances and overrides" {
    var sc = Sidecar{ .allocator = testing.allocator };
    defer sc.deinit();

    try sc.addInstance(7, "prefabs/enemy.zson", "enemy");
    try sc.setOverride(7, "Sprite", "tint", "[1, 0.5, 0, 1]");
    try sc.setOverride(7, "Sprite", "size", "[32, 32]");
    // The same field twice is one record with the LAST value.
    try sc.setOverride(7, "Sprite", "tint", "[0, 1, 0, 1]");

    try testing.expectEqual(@as(usize, 2), sc.overrides.items.len);
    try testing.expectEqualStrings("[0, 1, 0, 1]", sc.overrides.items[0].value);

    const inst = sc.instanceOf(7).?;
    try testing.expectEqualStrings("prefabs/enemy.zson", inst.prefab);
    try testing.expectEqualStrings("enemy", inst.source_name);
    try testing.expect(sc.instanceOf(8) == null);
}

test "clearing overrides leaves the instances alone" {
    var sc = Sidecar{ .allocator = testing.allocator };
    defer sc.deinit();
    try sc.addInstance(7, "p", "n");
    try sc.setOverride(7, "Sprite", "tint", "x");
    try sc.setOverride(9, "Sprite", "tint", "y");

    sc.clearOverrides(7);
    try testing.expectEqual(@as(usize, 1), sc.overrides.items.len);
    try testing.expectEqual(@as(ecs.SceneId, 9), sc.overrides.items[0].entity);
    try testing.expectEqual(@as(usize, 1), sc.instances.items.len);
}

test "an unknown keyword is skipped, not fatal" {
    var sc = Sidecar{ .allocator = testing.allocator };
    defer sc.deinit();
    try sc.parse(
        \\# a comment
        \\instance 3 prefabs/a.zson a
        \\something_new 1 2 3
        \\override 3 Sprite tint [1, 1, 1, 1]
    );
    try testing.expectEqual(@as(usize, 1), sc.instances.items.len);
    try testing.expectEqual(@as(usize, 1), sc.overrides.items.len);
}

test "a value with spaces survives the round trip" {
    // `{x: 5, y: -6}` is ONE value. Without quoting, the parser would see
    // three tokens and the override would come back as `{x:`.
    var sc = Sidecar{ .allocator = testing.allocator };
    defer sc.deinit();
    try sc.setOverride(3, "Transform", "position", "{x: 5, y: -6}");

    const path = "prefabs_test_quote.overrides";
    const io = std.Io.Threaded.global_single_threaded.io();
    defer std.Io.Dir.cwd().deleteFile(io, path) catch {};
    try sc.save(path);

    var loaded = try Sidecar.load(testing.allocator, path);
    defer loaded.deinit();
    try testing.expectEqual(@as(usize, 1), loaded.overrides.items.len);
    try testing.expectEqualStrings("{x: 5, y: -6}", loaded.overrides.items[0].value);
}

test "prefab paths are sanitised" {
    const a = try prefabPath(testing.allocator, "enemy boss");
    defer testing.allocator.free(a);
    try testing.expectEqualStrings("prefabs/enemy_boss.zson", a);

    const b = try prefabPath(testing.allocator, "");
    defer testing.allocator.free(b);
    try testing.expectEqualStrings("prefabs/prefab_.zson", b);

    // A name with a path separator cannot escape the directory.
    const c = try prefabPath(testing.allocator, "../../etc/passwd");
    defer testing.allocator.free(c);
    try testing.expect(std.mem.indexOf(u8, c, "..") == null);
}

test "the sidecar path sits beside the scene" {
    const p = try sidecarPath(testing.allocator, "samples/level.zson");
    defer testing.allocator.free(p);
    try testing.expectEqualStrings("samples/level.zson.overrides", p);
}

test "a sidecar written to disk reads back the same" {
    // The round trip is the whole contract of the file: what the editor
    // writes is what the next session reads. A field the editor cannot read
    // back is an override it cannot revert.
    const path = "prefabs_test_sidecar.overrides";
    const io = std.Io.Threaded.global_single_threaded.io();
    defer std.Io.Dir.cwd().deleteFile(io, path) catch {};

    var sc = Sidecar{ .allocator = testing.allocator };
    defer sc.deinit();
    try sc.addInstance(12, "prefabs/enemy.zson", "enemy");
    try sc.setOverride(12, "Sprite", "tint", "[1, 0.5, 0, 1]");
    try sc.setOverride(12, "Transform", "position", "{x: 5, y: -6}");
    try sc.save(path);

    var loaded = try Sidecar.load(testing.allocator, path);
    defer loaded.deinit();
    try testing.expectEqual(@as(usize, 1), loaded.instances.items.len);
    try testing.expectEqual(@as(ecs.SceneId, 12), loaded.instances.items[0].entity);
    try testing.expectEqualStrings("prefabs/enemy.zson", loaded.instances.items[0].prefab);
    try testing.expectEqual(@as(usize, 2), loaded.overrides.items.len);
    try testing.expectEqualStrings("[1, 0.5, 0, 1]", loaded.overrides.items[0].value);
    try testing.expectEqualStrings("{x: 5, y: -6}", loaded.overrides.items[1].value);
}

test "a missing sidecar is empty, not an error" {
    var sc = try Sidecar.load(testing.allocator, "no_such_file_here.overrides");
    defer sc.deinit();
    try testing.expectEqual(@as(usize, 0), sc.instances.items.len);
    try testing.expectEqual(@as(usize, 0), sc.overrides.items.len);
}
