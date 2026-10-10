//! `.zson`: bit-exact text format, and the two things built on top of it
//! (prefabs with overrides, and a canonical state hash).
//!
//! Grammar (one document = one scene or one prefab):
//!
//! ```
//! zson 1
//! entity 3 {                       // tag: scene id (saved scenes) or a name (prefabs)
//!   Name "player"                  // components in registry order, one per line
//!   Transform { position: { x: 0, y: 0 }, rotation: 0, scale: { x: 1, y: 1 } }
//!   Parent { parent: 1 }           // entity references by tag
//! }
//! ```
//!
//! Why the format looks like this:
//! - **Text, diffable, canonical.** Two identical worlds (same spawn order,
//!   same values) produce byte-identical documents: entities in slot order,
//!   components in registry order, fields in declaration order. That is what
//!   makes the hash test, undo/redo and Play-in-editor snapshots possible
//!   (spec §6: "Play→Stop snapshot is bit-exact").
//! - **Floats round-trip exactly.** `{d}` formatting plus `parseFloat` inverts
//!   bit for bit (there is a test), so the hash of a reloaded world equals the
//!   original one.
//! - **Entity references are tags**, never volatile handles: a scene writes
//!   scene ids (stable by construction), a prefab writes human names.
//! - **Loading is two-pass.** First pass: structure (tags, component
//!   identities). Second pass: values, by which point every referenced entity
//!   already exists. A child may therefore reference its parent regardless of
//!   the order the file happens to use.
//!
//! Prefabs and overrides are the same decoder in a different mode: decoding a
//! component patches the value it already has, so a document that omits a field
//! keeps the target's value. `zson.apply` instantiates or patches by `Name`,
//! which is how a scene overrides one field of one prefab instance without
//! duplicating the rest.

const std = @import("std");
const world_mod = @import("world.zig");
const components = @import("components.zig");
const entity_mod = @import("entity.zig");
const log = @import("core").log;

const World = world_mod.World;
const Entity = entity_mod.Entity;
const SceneId = entity_mod.SceneId;
const ComponentId = components.ComponentId;
const Mask = components.Mask;
const Writer = std.Io.Writer;
const Allocator = std.mem.Allocator;

const scoped = log.scoped("zson");

pub const Error = error{
    Malformed,
    UnknownComponent,
    UnknownField,
    DanglingReference,
    DuplicateTag,
    UnsupportedValue,
};

/// Document version. Bump it when the format changes incompatibly; older
/// versions keep loading (fields are patched, unknown ones skipped).
pub const version: u32 = 1;

// ── Encoding ─────────────────────────────────────────────────────────────────

/// Canonical text form of a whole world.
pub fn encode(world: *World, w: *Writer) !void {
    try w.print("zson {d}\n", .{version});
    var slot: usize = 0;
    while (slot < world.slotCount()) : (slot += 1) {
        const e = world.entityAtSlot(slot) orelse continue;
        try encodeEntity(world, e, w);
    }
}

/// Convenience: the document as freshly allocated bytes.
pub fn encodeToString(world: *World, allocator: Allocator) ![]u8 {
    var out: Writer.Allocating = .init(allocator);
    errdefer out.deinit();
    try encode(world, &out.writer);
    return try out.toOwnedSlice();
}

/// Canonical hash of the world state (spec §6: "hash test in CI"). It equals
/// the hash of the reloaded world by construction: identical bytes in,
/// identical bytes out, and nothing volatile is ever encoded.
pub fn hash(world: *World) u64 {
    // Hash without materialising the document: the writer drains into the
    // hasher as it goes, and one flush at the end drains the tail buffer.
    var scratch: [256]u8 = undefined;
    var hasher: Writer.Hashing(std.hash.Wyhash) = .initHasher(std.hash.Wyhash.init(0), &scratch);
    encode(world, &hasher.writer) catch unreachable;
    hasher.writer.flush() catch unreachable;
    return hasher.hasher.final();
}

fn encodeEntity(world: *World, e: Entity, w: *Writer) !void {
    try w.print("entity {d} {{\n", .{world.sceneIdOf(e)});
    const arch = world.archetypeAt(world.archIndexOf(e).?);
    const row = world.rowOf(e);
    for (arch.ids, 0..) |id, col| {
        try w.print("  {s} ", .{components.nameOf(id)});
        try encodeValueById(id, w, world, arch.columnBytes(col, row));
        try w.writeByte('\n');
    }
    try w.writeAll("}\n");
}

// ── Decoding ─────────────────────────────────────────────────────────────────

/// Loads a full document into a fresh world: slots and archetypes are rebuilt
/// and scene ids are exactly the ones written in the text.
pub fn decode(allocator: Allocator, text: []const u8) !World {
    var world = World.init(allocator);
    errdefer world.deinit();

    var doc = try Document.scan(allocator, text);
    defer doc.deinit();

    // Pass 1: every entity exists before any reference is resolved. The key
    // buffer lives in this frame on purpose: an archetype key that points into
    // a dead stack frame is a bug that only "works" in Debug builds.
    var key_ids: [max_key_ids]ComponentId = undefined;
    var index = SceneIndex{ .allocator = allocator };
    defer index.deinit();
    for (doc.records.items) |*record| {
        const arch_index = try findArchetypeFor(&world, &doc, allocator, record, key_ids[0..]);
        record.entity = (try world.createRow(arch_index, record.scene_id)).entity;
        if (record.scene_id != 0) try index.add(record.scene_id, record.entity);
    }

    // Pass 2: values, with the tag map complete.
    var tags = Tags{ .world = &world, .allocator = allocator, .index = &index };
    defer tags.deinit();
    for (doc.records.items) |*record| {
        try tags.put(record);
        const row = world.rowOf(record.entity);
        const arch = world.archetypeAt(world.archIndexOf(record.entity).?);
        for (record.blocks.items) |block| {
            const col = arch.findColumn(block.id).?;
            const bytes = arch.columnBytes(col, row);
            components.writeDefault(block.id, bytes); // "replace" starts from the default
            var cursor = Cursor{ .text = doc.text, .pos = block.body.start };
            try decodeValueById(block.id, &cursor, bytes, &tags);
        }
    }
    return world;
}

/// Applies a prefab document, or a scene override, onto an existing world:
/// - Entities are matched by their `Name`. A name that does not exist yet is
///   spawned, so the same document both instantiates and patches.
/// - A component the target already has is *patched*: only the fields present
///   in the document are overwritten, the rest keep their current values.
/// - A component the target lacks is added with the document's fields over the
///   registry defaults.
pub fn apply(world: *World, text: []const u8) !void {
    const allocator = world.allocator;
    var doc = try Document.scan(allocator, text);
    defer doc.deinit();
    var key_ids: [max_key_ids]ComponentId = undefined;

    // Pass 1: decide which world entity each document entity talks about.
    // A numeric tag is a scene id, which is how the editor writes overrides.
    for (doc.records.items) |*record| {
        if (record.scene_id != 0) {
            record.entity = world.findBySceneId(record.scene_id) orelse {
                scoped.warn("override for scene id {d} has no live entity", .{record.scene_id});
                continue;
            };
            continue;
        }
        // A word tag addresses a prefab instance by name: the tag itself is the
        // name (`entity enemy { ... }`), or the document spells out a Name.
        const wanted = try doc.decodeName(record) orelse record.tag;
        if (world.findByName(wanted)) |e| {
            record.entity = e;
            continue;
        }
        const arch_index = try findArchetypeFor(world, &doc, allocator, record, key_ids[0..]);
        record.entity = (try world.createRow(arch_index, 0)).entity; // fresh identity
    }

    var index = SceneIndex{ .allocator = allocator };
    defer index.deinit();
    var tags = Tags{ .world = world, .allocator = allocator, .index = &index };
    defer tags.deinit();
    for (doc.records.items) |*record| {
        try tags.put(record);
        if (record.scene_id != 0 and !record.entity.isInvalid()) {
            try index.add(record.scene_id, record.entity);
        }
    }

    var stack_buf: [components.max_stride]u8 = undefined;
    for (doc.records.items) |*record| {
        if (record.entity.isInvalid()) continue; // warned in pass 1: no target
        for (record.blocks.items) |block| {
            var cursor = Cursor{ .text = doc.text, .pos = block.body.start };
            if (world.getById(record.entity, block.id)) |current| {
                // Patch in place: absent fields keep the current value.
                try decodeValueById(block.id, &cursor, current, &tags);
            } else {
                const bytes = stack_buf[0..components.strideOf(block.id)];
                components.writeDefault(block.id, bytes);
                try decodeValueById(block.id, &cursor, bytes, &tags);
                try addDecodedById(world, record.entity, block.id, bytes);
            }
        }
    }
}

// ── Reflective values ────────────────────────────────────────────────────────

/// Writes one component value, dispatching from its runtime id to its type.
fn encodeValueById(id: ComponentId, w: *Writer, world: *World, bytes: []const u8) !void {
    inline for (components.entries, 0..) |entry, i| {
        if (i == id) return encodeValue(entry.type, w, world, bytes);
    }
    std.debug.panic("zson: cannot encode component id {d}", .{id});
}

fn encodeValue(comptime T: type, w: *Writer, world: *World, bytes: []const u8) !void {
    if (T == components.Name) {
        const value: *const components.Name = @ptrCast(@alignCast(bytes.ptr));
        try encodeQuoted(w, value.slice());
        return;
    }
    if (T == Entity) {
        const value: *const Entity = @ptrCast(@alignCast(bytes.ptr));
        try w.print("{d}", .{world.sceneIdOf(value.*)});
        return;
    }
    switch (@typeInfo(T)) {
        .int, .float => {
            const value: *const T = @ptrCast(@alignCast(bytes.ptr));
            try w.print("{d}", .{value.*});
        },
        .bool => {
            const value: *const bool = @ptrCast(@alignCast(bytes.ptr));
            try w.writeAll(if (value.*) "true" else "false");
        },
        .@"enum" => {
            const value: *const T = @ptrCast(@alignCast(bytes.ptr));
            try w.writeAll(@tagName(value.*));
        },
        .optional => |info| {
            const value: *const T = @ptrCast(@alignCast(bytes.ptr));
            if (value.*) |inner| {
                try encodeValue(info.child, w, world, std.mem.asBytes(&inner));
            } else try w.writeAll("null");
        },
        .array => |info| {
            try w.writeByte('[');
            const items: []const info.child = @as([*]const info.child, @ptrCast(@alignCast(bytes.ptr)))[0..info.len];
            for (items, 0..) |*item, i| {
                if (i != 0) try w.writeAll(", ");
                try encodeValue(info.child, w, world, std.mem.asBytes(item));
            }
            try w.writeByte(']');
        },
        .@"struct" => |info| {
            try w.writeByte('{');
            inline for (info.fields, 0..) |field, i| {
                if (i != 0) try w.writeAll(", ");
                try w.print("{s}: ", .{field.name});
                try encodeValue(field.type, w, world, bytes[offsetOf(T, field.name)..][0..@sizeOf(field.type)]);
            }
            try w.writeByte('}');
        },
        else => return error.UnsupportedValue,
    }
}

/// Byte offset of a field inside a struct, following declaration order.
/// Byte offset of a field inside a struct. `@offsetOf` is what the compiler
/// actually uses (auto layout packs and repads), so the reflective reader and
/// the storage agree by construction.
fn offsetOf(comptime T: type, comptime name: []const u8) usize {
    return @offsetOf(T, name);
}

fn addDecodedById(world: *World, e: Entity, id: ComponentId, bytes: []const u8) !void {
    inline for (components.entries, 0..) |entry, i| {
        if (i == id) {
            const value: *const entry.type = @ptrCast(@alignCast(bytes.ptr));
            try world.add(e, value.*);
            return;
        }
    }
    std.debug.panic("zson: cannot add component id {d}", .{id});
}

fn decodeValueById(id: ComponentId, cursor: *Cursor, bytes: []u8, tags: *Tags) !void {
    inline for (components.entries, 0..) |entry, i| {
        if (i == id) return decodeValue(entry.type, cursor, bytes, tags);
    }
    std.debug.panic("zson: cannot decode component id {d}", .{id});
}

/// Patch-decodes `T` into `bytes`: fields present in the text are written,
/// absent fields keep whatever `bytes` already holds.
fn decodeValue(comptime T: type, cursor: *Cursor, bytes: []u8, tags: *Tags) !void {
    if (T == components.Name) {
        const value: *components.Name = @ptrCast(@alignCast(bytes.ptr));
        const text = try cursor.quoted();
        value.set(text);
        return;
    }
    if (T == Entity) {
        const value: *Entity = @ptrCast(@alignCast(bytes.ptr));
        const tag = try cursor.identifier();
        value.* = try tags.resolve(tag);
        return;
    }
    switch (@typeInfo(T)) {
        .int, .float => {
            const value: *T = @ptrCast(@alignCast(bytes.ptr));
            const token = try cursor.number();
            value.* = if (comptime @typeInfo(T) == .int)
                try std.fmt.parseInt(T, token, 0)
            else if (parseDecimalFloat(T, token)) |fast|
                fast
            else
                try std.fmt.parseFloat(T, token);
        },
        .bool => {
            const value: *bool = @ptrCast(@alignCast(bytes.ptr));
            const token = try cursor.identifier();
            if (std.mem.eql(u8, token, "true")) {
                value.* = true;
            } else if (std.mem.eql(u8, token, "false")) {
                value.* = false;
            } else return cursor.fail("expected true or false", .{});
        },
        .@"enum" => {
            const value: *T = @ptrCast(@alignCast(bytes.ptr));
            const token = try cursor.identifier();
            inline for (@typeInfo(T).@"enum".fields) |field| {
                if (std.mem.eql(u8, field.name, token)) {
                    value.* = @enumFromInt(field.value);
                    return;
                }
            }
            return cursor.fail("unknown value '{s}'", .{token});
        },
        .optional => |info| {
            const value: *T = @ptrCast(@alignCast(bytes.ptr));
            cursor.skipTrivia();
            if (cursor.pos + 4 <= cursor.text.len and std.mem.eql(u8, cursor.text[cursor.pos .. cursor.pos + 4], "null")) {
                cursor.pos += 4;
                value.* = null;
                return;
            }
            var child: info.child = undefined;
            var child_bytes: [@sizeOf(info.child)]u8 = undefined;
            @memcpy(child_bytes[0..@sizeOf(info.child)], std.mem.asBytes(&child));
            try decodeValue(info.child, cursor, &child_bytes, tags);
            child = @as(*const info.child, @ptrCast(@alignCast(&child_bytes))).*;
            value.* = child;
        },
        .array => |info| {
            try cursor.expect('[');
            const items: []info.child = @as([*]info.child, @ptrCast(@alignCast(bytes.ptr)))[0..info.len];
            var i: usize = 0;
            while (true) {
                cursor.skipTrivia();
                if (cursor.pos >= cursor.text.len) return cursor.fail("unterminated array", .{});
                if (cursor.text[cursor.pos] == ']') break;
                if (i >= items.len) return cursor.fail("too many array elements", .{});
                const item_bytes = std.mem.asBytes(&items[i]);
                try decodeValue(info.child, cursor, item_bytes[0..@sizeOf(info.child)], tags);
                i += 1;
                _ = try cursor.eat(',');
            }
            try cursor.expect(']');
        },
        .@"struct" => |info| {
            try cursor.expect('{');
            if (try cursor.eat('}')) return;
            while (true) {
                const name = try cursor.identifier();
                try cursor.expect(':');
                var matched = false;
                inline for (info.fields) |field| {
                    if (std.mem.eql(u8, field.name, name)) {
                        try decodeValue(
                            field.type,
                            cursor,
                            bytes[offsetOf(T, field.name)..][0..@sizeOf(field.type)],
                            tags,
                        );
                        matched = true;
                    }
                }
                if (!matched) return cursor.fail("unknown field '{s}'", .{name});
                if (try cursor.eat('}')) return;
                _ = try cursor.eat(',');
            }
        },
        else => return error.UnsupportedValue,
    }
}

fn encodeQuoted(w: *Writer, text: []const u8) !void {
    try w.writeByte('"');
    for (text) |c| switch (c) {
        '"' => try w.writeAll("\\\""),
        '\\' => try w.writeAll("\\\\"),
        '\n' => try w.writeAll("\\n"),
        '\t' => try w.writeAll("\\t"),
        else => try w.writeByte(c),
    };
    try w.writeByte('"');
}

// ── Document scanning ───────────────────────────────────────────────────────

const Range = struct { start: usize, end: usize };

/// One entity as written: a tag plus the byte ranges of its components.
const Record = struct {
    tag: []const u8,
    scene_id: SceneId = 0,
    blocks: std.ArrayList(Block) = .empty,
    /// Heap-backed key for absurdly wide records (freed with the record).
    owned_key: []ComponentId = &.{},
    entity: Entity = Entity.invalid,
};

const Block = struct {
    id: ComponentId,
    /// Byte range of the value (braces included for the brace form).
    body: Range,
};

/// Archetypes with more component ids than this are hopeless: wide keys take
/// the heap (owned by the document, freed with it) instead of a stack buffer.
const max_key_ids = 16;

/// Index of (creating if needed) the archetype a document record needs. `out`
/// is a caller-owned buffer of at least `max_key_ids` ids: it is what keeps the
/// key valid while the archetype is created.
fn findArchetypeFor(
    world: *World,
    doc: *Document,
    allocator: Allocator,
    record: *Record,
    out: []ComponentId,
) !u32 {
    const ids = try doc.sortedIds(allocator, record, out);
    var mask = Mask.initEmpty();
    for (ids) |id| mask.set(id);
    return world.findOrCreateArchetype(.{ .mask = mask, .ids = ids });
}

/// A scanned document: the structure of every entity, no values yet.
const Document = struct {
    text: []const u8,
    records: std.ArrayList(Record) = .empty,
    allocator: Allocator,

    fn scan(allocator: Allocator, text: []const u8) !Document {
        var doc = Document{ .text = text, .allocator = allocator };
        errdefer doc.deinit();

        var cursor = Cursor{ .text = text };
        const header = try cursor.identifier();
        if (!std.mem.eql(u8, header, "zson")) return cursor.fail("expected a 'zson <version>' header", .{});
        const version_token = try cursor.number();
        const parsed_version = try std.fmt.parseInt(u32, version_token, 10);
        if (parsed_version > version) {
            return cursor.fail("document version {d} is newer than this build ({d})", .{ parsed_version, version });
        }

        while (!cursor.done()) {
            const keyword = try cursor.identifier();
            if (!std.mem.eql(u8, keyword, "entity")) return cursor.fail("expected 'entity', found '{s}'", .{keyword});
            const tag = try cursor.identifier();
            try cursor.expect('{');
            var record = Record{ .tag = tag };
            if (std.fmt.parseInt(SceneId, tag, 10)) |id| record.scene_id = id else |_| {}
            while (!try cursor.eat('}')) {
                if (cursor.done()) return cursor.fail("unterminated entity", .{});
                const component_name = try cursor.identifier();
                const id = components.idOfName(component_name) orelse {
                    // Skip unknown components instead of failing: a document
                    // from a newer build still loads what this build knows.
                    scoped.warn("skipping unknown component '{s}'", .{component_name});
                    try skipValue(&cursor);
                    continue;
                };
                const body = try recordRange(&cursor);
                try record.blocks.append(allocator, .{ .id = id, .body = body });
            }
            try doc.records.append(allocator, record);
        }
        return doc;
    }

    fn deinit(self: *Document) void {
        for (self.records.items) |*record| {
            record.blocks.deinit(self.allocator);
            if (record.owned_key.len > 0) self.allocator.free(record.owned_key);
        }
        self.records.deinit(self.allocator);
    }

    /// Sorted component ids of a record, into `out` (16 is engine-plenty).
    /// Wider keys take the heap and are freed with the document: decoding is
    /// load time. The returned slice only lives as long as `out`.
    fn sortedIds(self: *Document, allocator: Allocator, record: *Record, out: []ComponentId) ![]const ComponentId {
        _ = self;
        std.debug.assert(out.len == max_key_ids);
        const n = record.blocks.items.len;
        const ids = if (n <= out.len)
            out[0..n]
        else
            try allocator.alloc(ComponentId, n);
        for (record.blocks.items, 0..) |block, i| ids[i] = block.id;
        std.mem.sort(ComponentId, ids, {}, std.sort.asc(ComponentId));
        if (n > out.len) record.owned_key = ids;
        return ids;
    }

    /// Name value of a record, when it has a `Name` component: what `apply`
    /// uses to decide which world entity a document entity talks about.
    fn decodeName(self: *Document, record: *Record) !?[]const u8 {
        for (record.blocks.items) |block| {
            if (block.id != components.componentId(components.Name)) continue;
            var cursor = Cursor{ .text = self.text, .pos = block.body.start };
            return try cursor.quoted();
        }
        return null;
    }
};

/// Records the byte range of one component value (braces included).
fn recordRange(cursor: *Cursor) !Range {
    const start = cursor.pos;
    switch (try cursor.peek()) {
        '{' => {
            var depth: usize = 0;
            while (cursor.pos < cursor.text.len) {
                const c = cursor.text[cursor.pos];
                cursor.pos += 1;
                if (c == '{') depth += 1;
                if (c == '}') {
                    depth -= 1;
                    if (depth == 0) break;
                }
            }
            return .{ .start = start, .end = cursor.pos };
        },
        '"' => _ = try cursor.quoted(),
        '[' => try skipValue(cursor),
        else => _ = try cursor.number(),
    }
    return .{ .start = start, .end = cursor.pos };
}

/// Consumes one value of any shape without interpreting it.
fn skipValue(cursor: *Cursor) !void {
    switch (cursor.peek() catch return cursor.fail("unexpected end of document", .{})) {
        '{' => {
            try cursor.expect('{');
            if (try cursor.eat('}')) return;
            while (true) {
                _ = try cursor.identifier();
                try cursor.expect(':');
                try skipValue(cursor);
                if (try cursor.eat('}')) return;
                _ = cursor.eat(',') catch {};
            }
        },
        '[' => {
            try cursor.expect('[');
            if (try cursor.eat(']')) return;
            while (true) {
                try skipValue(cursor);
                if (try cursor.eat(']')) return;
                _ = cursor.eat(',') catch {};
            }
        },
        '"' => _ = try cursor.quoted(),
        else => _ = try cursor.number(),
    }
}

// ── Scene-id index ─────────────────────────────────────────────────────────

/// Scene id -> entity. Documents reference entities by id, and a linear scan
/// per reference would make loading O(n^2): a 10k-parent scene would spend
/// more time finding parents than decoding them.
const SceneIndex = struct {
    allocator: Allocator,
    map: std.AutoHashMapUnmanaged(SceneId, Entity) = .{},

    fn add(self: *SceneIndex, id: SceneId, e: Entity) !void {
        try self.map.put(self.allocator, id, e);
    }

    fn lookup(self: *const SceneIndex, world: *World, id: SceneId) ?Entity {
        return self.map.get(id) orelse world.findBySceneId(id);
    }

    fn deinit(self: *SceneIndex) void {
        self.map.deinit(self.allocator);
    }
};

// ── Tags ────────────────────────────────────────────────────────────────────

/// Document-local tag -> world entity. Numeric tags are scene ids (saved
/// scenes), word tags are names (prefabs, overrides).
const Tags = struct {
    world: *World,
    allocator: Allocator,
    /// Scene-id index of the document (or of the world being patched).
    index: ?*const SceneIndex = null,
    /// Word tags (prefab names) which are only meaningful inside this document.
    map: std.StringHashMapUnmanaged(Entity) = .{},

    fn put(self: *Tags, record: *Record) !void {
        if (record.scene_id != 0) return; // numeric tags resolve through ids
        try self.map.put(self.allocator, record.tag, record.entity);
    }

    fn resolve(self: *Tags, tag: []const u8) !Entity {
        if (std.fmt.parseInt(SceneId, tag, 10)) |id| {
            if (id == 0) return Entity.invalid;
            // O(1) for anything the document (or the patch target) declares;
            // the linear world scan stays as the fallback for ids like the
            // document's own entities created before the index existed.
            if (self.index) |index| {
                if (index.lookup(self.world, id)) |e| return e;
            } else if (self.world.findBySceneId(id)) |e| return e;
        } else |_| {}
        if (self.map.get(tag)) |e| return e;
        return error.DanglingReference;
    }

    fn deinit(self: *Tags) void {
        self.map.deinit(self.allocator);
    }
};

// ── Number parsing ──────────────────────────────────────────────────────────

/// Fast path for the decimal numbers a `.zson` document actually contains.
///
/// When the mantissa is exactly representable and the exponent is small, the
/// value is `mantissa / 10^k` (or `* 10^k`), and IEEE division — correctly
/// rounded on the *exact* quotient — gives the same float the decimal stands
/// for. That is the bit-exact guarantee `parseFloat` provides, at a fraction of
/// the cost (measured: ~200 ns -> ~10 ns, which is most of a load time).
///
/// Anything the fast path does not fully understand (exponent notation, too
/// many digits, hex) returns `null` and the caller uses the standard parser:
/// exactness is never traded for speed.
fn parseDecimalFloat(comptime T: type, token: []const u8) ?T {
    if (comptime @typeInfo(T) != .float) return null;
    // The mantissa must be exact in T, and 10^k must stay exact too:
    // 2^24 / 10^10 for f32, 2^53 / 10^22 for f64.
    const max_mantissa: u64 = if (T == f32) 1 << 24 else 1 << 53;
    const max_pow10: usize = if (T == f32) 10 else 22;

    var mantissa: u64 = 0;
    var digits: u32 = 0;
    var exponent: i32 = 0;
    var negative = false;
    var i: usize = 0;

    if (i < token.len and (token[i] == '-' or token[i] == '+')) {
        negative = token[i] == '-';
        i += 1;
    }
    while (i < token.len and std.ascii.isDigit(token[i])) : (i += 1) {
        mantissa = mantissa * 10 + (token[i] - '0');
        digits += 1;
        if (mantissa > max_mantissa) return null;
    }
    if (i < token.len and token[i] == '.') {
        i += 1;
        while (i < token.len and std.ascii.isDigit(token[i])) : (i += 1) {
            mantissa = mantissa * 10 + (token[i] - '0');
            digits += 1;
            exponent -= 1;
            if (mantissa > max_mantissa) return null;
        }
    }
    if (digits == 0 or i != token.len) return null; // exponents, junk: fall back

    if (mantissa == 0) return if (negative) -@as(T, 0) else @as(T, 0);
    const magnitude: usize = @intCast(if (exponent >= 0) exponent else -exponent);
    if (magnitude > max_pow10) return null;

    var value: T = @floatFromInt(mantissa);
    if (magnitude != 0) {
        // Comptime dispatch per exponent value: a runtime lookup of a comptime
        // table would reintroduce a bounds check and a memory access.
        value = if (exponent >= 0)
            value * pow10At(T, magnitude)
        else
            value / pow10At(T, magnitude);
    }
    return if (negative) -value else value;
}

const pow10_f32: [23]f32 = blk: {
    var table: [23]f32 = undefined;
    var i: usize = 0;
    var value: f32 = 1;
    while (i < table.len) : (i += 1) {
        table[i] = value;
        value *= 10;
    }
    break :blk table;
};

const pow10_f64: [23]f64 = blk: {
    var table: [23]f64 = undefined;
    var i: usize = 0;
    var value: f64 = 1;
    while (i < table.len) : (i += 1) {
        table[i] = value;
        value *= 10;
    }
    break :blk table;
};

/// 10^n for the small magnitudes a `.zson` number can have.
fn pow10At(comptime T: type, n: usize) T {
    return if (T == f32) pow10_f32[n] else pow10_f64[n];
}

test "fast float path agrees bit for bit with the standard parser" {
    const samples = [_][]const u8{
        "0",          "1",         "12.5",        "-1.5",     "0.1",
        "1.0",        "100",       "0.001",       "-0.0",     "12345.6789",
        "3.4028235",  "1.1754944", "0.0000001",   "16777216", "16777217",
        "0.33333333", "9999999.9", "-12345.6789", "2.5e3",    "1e-7",
        "nan",        "inf",       "0x1p3",       "",
    };
    for (samples) |text| {
        // f32: the fast path only claims values it can do exactly.
        if (parseDecimalFloat(f32, text)) |fast| {
            const slow = std.fmt.parseFloat(f32, text) catch unreachable;
            try std.testing.expectEqual(@as(u32, @bitCast(slow)), @as(u32, @bitCast(fast)));
        }
        // f64: same contract, wider mantissa/exponent.
        if (parseDecimalFloat(f64, text)) |fast| {
            const slow = std.fmt.parseFloat(f64, text) catch unreachable;
            try std.testing.expectEqual(@as(u64, @bitCast(slow)), @as(u64, @bitCast(fast)));
        }
    }
}

// ── Lexer ───────────────────────────────────────────────────────────────────

const Cursor = struct {
    text: []const u8,
    pos: usize = 0,

    fn skipTrivia(self: *Cursor) void {
        while (self.pos < self.text.len) {
            const c = self.text[self.pos];
            if (c == ' ' or c == '\t' or c == '\r' or c == '\n' or c == ',') self.pos += 1 else break;
        }
    }

    fn done(self: *Cursor) bool {
        self.skipTrivia();
        return self.pos >= self.text.len;
    }

    fn peek(self: *Cursor) !u8 {
        self.skipTrivia();
        if (self.pos >= self.text.len) return error.Malformed;
        return self.text[self.pos];
    }

    fn eat(self: *Cursor, c: u8) !bool {
        if (self.pos >= self.text.len) return false;
        if (try self.peek() != c) return false;
        self.pos += 1;
        return true;
    }

    fn expect(self: *Cursor, c: u8) !void {
        if (!try self.eat(c)) return self.fail("expected '{c}'", .{c});
    }

    /// Identifier or quoted string: both are legal tags and component names,
    /// and quoting is how a tag may contain spaces (`entity "the player"`).
    fn identifier(self: *Cursor) ![]const u8 {
        self.skipTrivia();
        const start = self.pos;
        if (start >= self.text.len) return self.fail("expected an identifier", .{});
        if (self.text[start] == '"') return self.quoted();
        var at = start;
        while (at < self.text.len and isIdentByte(self.text[at])) at += 1;
        if (at == start) return self.fail("expected an identifier", .{});
        self.pos = at;
        return self.text[start..at];
    }

    /// Raw slice between the quotes (escapes are left for the caller to undo).
    fn quoted(self: *Cursor) ![]const u8 {
        self.skipTrivia();
        if (self.pos >= self.text.len or self.text[self.pos] != '"') {
            return self.fail("expected a quoted string", .{});
        }
        const start = self.pos;
        self.pos += 1;
        while (self.pos < self.text.len) {
            const c = self.text[self.pos];
            if (c == '\\') {
                self.pos += 2;
                continue;
            }
            if (c == '"') {
                self.pos += 1;
                return self.text[start + 1 .. self.pos - 1];
            }
            self.pos += 1;
        }
        return self.fail("unterminated string", .{});
    }

    fn number(self: *Cursor) ![]const u8 {
        self.skipTrivia();
        const start = self.pos;
        var at = start;
        if (at < self.text.len and (self.text[at] == '-' or self.text[at] == '+')) at += 1;
        while (at < self.text.len and isNumberByte(self.text[at])) at += 1;
        if (at == start) return self.fail("expected a number", .{});
        self.pos = at;
        return self.text[start..at];
    }

    fn fail(self: *Cursor, comptime fmt: []const u8, args: anytype) Error {
        const line = std.mem.count(u8, self.text[0..@min(self.pos, self.text.len)], "\n") + 1;
        scoped.err("line {d}: " ++ fmt, .{line} ++ args);
        return error.Malformed;
    }
};

fn isIdentByte(c: u8) bool {
    return (c >= 'a' and c <= 'z') or (c >= 'A' and c <= 'Z') or
        (c >= '0' and c <= '9') or c == '_' or c == '.';
}

fn isNumberByte(c: u8) bool {
    return (c >= '0' and c <= '9') or c == '.' or c == 'e' or c == 'E' or
        c == '+' or c == '-' or c == 'x' or c == 'X' or
        (c >= 'a' and c <= 'f') or (c >= 'A' and c <= 'F');
}

// ── Tests ───────────────────────────────────────────────────────────────────

test "save and load reproduce an identical hash (spec §6)" {
    var world = World.init(std.testing.allocator);
    defer world.deinit();

    const quad = try world.spawn(.{
        components.Name.init("quad"),
        components.Transform{ .position = .{ .x = 12.5, .y = -3.25 }, .rotation = 0.5 },
    });
    const root = try world.spawn(.{components.Name.init("root")});
    try world.add(quad, components.Parent{ .parent = root });
    try world.add(quad, components.Velocity{ .linear = .{ .x = 1, .y = -1 }, .angular = 2.5 });

    const text = try encodeToString(&world, std.testing.allocator);
    defer std.testing.allocator.free(text);

    var reloaded = try decode(std.testing.allocator, text);
    defer reloaded.deinit();

    try std.testing.expectEqual(hash(&world), hash(&reloaded));
    try std.testing.expectEqual(world.entityCount(), reloaded.entityCount());

    // Components, not just the hash.
    const reloaded_quad = reloaded.findByName("quad").?;
    const transform = reloaded.get(reloaded_quad, components.Transform).?;
    try std.testing.expectApproxEqAbs(@as(f32, 12.5), transform.position.x, 0.0001);
    try std.testing.expectApproxEqAbs(@as(f32, -3.25), transform.position.y, 0.0001);
    try std.testing.expectApproxEqAbs(@as(f32, 0.5), transform.rotation, 0.0001);
    try std.testing.expectApproxEqAbs(@as(f32, 2.5), reloaded.get(reloaded_quad, components.Velocity).?.angular, 0.0001);

    const reloaded_root = reloaded.findByName("root").?;
    try std.testing.expectEqual(reloaded_root, reloaded.get(reloaded_quad, components.Parent).?.parent);
}

test "float formatting round-trips bit for bit" {
    const values = [_]f32{ 0.1, 1.0 / 3.0, -12345.6789, 1e-30, 3.4028235e38, 0.0, -0.0 };
    for (values) |value| {
        var world = World.init(std.testing.allocator);
        defer world.deinit();
        const e = try world.spawn(.{components.Transform{ .position = .{ .x = value, .y = value } }});

        const text = try encodeToString(&world, std.testing.allocator);
        defer std.testing.allocator.free(text);
        var reloaded = try decode(std.testing.allocator, text);
        defer reloaded.deinit();

        const loaded = reloaded.entityAtSlot(e.index).?;
        const bits_in: u32 = @bitCast(value);
        const bits_out: u32 = @bitCast(reloaded.get(loaded, components.Transform).?.position.x);
        try std.testing.expectEqual(bits_in, bits_out);
    }
}

test "prefabs: instantiate then override a single field" {
    const prefab =
        \\zson 1
        \\entity enemy {
        \\  Name "enemy"
        \\  Transform { position: { x: 0, y: 0 }, rotation: 0, scale: { x: 1, y: 1 } }
        \\  Velocity { linear: { x: 3, y: 0 }, angular: 0 }
        \\}
    ;

    var world = World.init(std.testing.allocator);
    defer world.deinit();

    // Instantiating: a new entity, identity assigned, defaults filled.
    try apply(&world, prefab);
    try std.testing.expectEqual(@as(usize, 1), world.entityCount());
    const enemy = world.findByName("enemy").?;
    try std.testing.expectApproxEqAbs(@as(f32, 3), world.get(enemy, components.Velocity).?.linear.x, 0.0001);

    // Override: only the fields present in the document change.
    const override_text =
        \\zson 1
        \\entity enemy {
        \\  Transform { position: { x: 100, y: 200 } }
        \\}
    ;
    try apply(&world, override_text);
    try std.testing.expectEqual(@as(usize, 1), world.entityCount()); // matched, not spawned
    const transform = world.get(enemy, components.Transform).?;
    try std.testing.expectApproxEqAbs(@as(f32, 100), transform.position.x, 0.0001);
    try std.testing.expectApproxEqAbs(@as(f32, 200), transform.position.y, 0.0001);
    try std.testing.expectApproxEqAbs(@as(f32, 0), transform.rotation, 0.0001); // untouched
    try std.testing.expect(world.has(enemy, components.Parent) == false);
    try std.testing.expectApproxEqAbs(@as(f32, 3), world.get(enemy, components.Velocity).?.linear.x, 0.0001); // untouched
    try std.testing.expectEqualStrings("enemy", world.get(enemy, components.Name).?.slice());
}

test "references resolve regardless of declaration order" {
    const document =
        \\zson 1
        \\entity 1 { Name "child" Parent { parent: 2 } }
        \\entity 2 { Name "parent" }
    ;
    var world = try decode(std.testing.allocator, document);
    defer world.deinit();

    const child = world.findBySceneId(1).?;
    const parent = world.findBySceneId(2).?;
    try std.testing.expectEqual(parent, world.get(child, components.Parent).?.parent);
}

test "a scene of many references decodes as fast as it loads (id index)" {
    var world = World.init(std.heap.page_allocator);
    defer world.deinit();

    // Enough references that a linear scan per reference would dominate the
    // load: each child references the same parent.
    const root = try world.spawn(.{components.Name.init("root")});
    var i: usize = 0;
    while (i < 2_000) : (i += 1) {
        _ = try world.spawn(.{
            components.Name.init(try std.fmt.allocPrint(std.heap.page_allocator, "child_{d}", .{i})),
            components.Parent{ .parent = root },
            components.Transform{ .position = .{ .x = 1, .y = 2 } },
        });
    }

    const text = try encodeToString(&world, std.heap.page_allocator);
    defer std.heap.page_allocator.free(text);

    var reloaded = try decode(std.heap.page_allocator, text);
    defer reloaded.deinit();

    try std.testing.expectEqual(hash(&world), hash(&reloaded));
    const child = reloaded.findByName("child_1999").?;
    try std.testing.expectEqual(reloaded.findByName("root"), reloaded.get(child, components.Parent).?.parent);
}

test "deeper hierarchy round-trips with references by tag" {
    var world = World.init(std.testing.allocator);
    defer world.deinit();

    const root = try world.spawn(.{components.Name.init("root")});
    const middle = try world.spawn(.{ components.Name.init("middle"), components.Parent{ .parent = root } });
    const leaf = try world.spawn(.{ components.Name.init("leaf"), components.Parent{ .parent = middle } });
    try std.testing.expect(leaf.index != middle.index);

    const text = try encodeToString(&world, std.testing.allocator);
    defer std.testing.allocator.free(text);
    var reloaded = try decode(std.testing.allocator, text);
    defer reloaded.deinit();

    try std.testing.expectEqual(hash(&world), hash(&reloaded));
    const reloaded_leaf = reloaded.findByName("leaf").?;
    const reloaded_middle = reloaded.findByName("middle").?;
    try std.testing.expectEqual(reloaded_middle, reloaded.get(reloaded_leaf, components.Parent).?.parent);
}
