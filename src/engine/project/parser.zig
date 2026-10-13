//! `project.config` decoding and canonical encoding.
//!
//! The format is the line-oriented flavor of the same grammar `.zson` uses
//! (spec §6: one bit-exact text format for everything the engine persists):
//!
//! ```
//! project "MyGame"                // header: name and version, free order
//! version "0.1.0"
//!
//! display {                       // section: schema name + '{'
//!   width 1280                    //   field: name + one value, one per line
//!   vsync true
//! }
//!
//! layers {
//!   names "world" "player"        // a list is bare strings...
//! }
//!
//! input_map {
//!   jump ["KEY_SPACE"]            // ...or bracketed; bindings prefer brackets
//! }
//! ```
//!
//! Why it looks like this:
//! - **Line-oriented, one field per line.** The file is meant to be hand-edited
//!   and diffed; a field's value is on the same line as its name, so a change
//!   to `max_fps` is one changed line in review.
//! - **Values carry no type tags.** The schema decides: `width 1280` is an int
//!   because the schema says `display.width` is one. That is what makes the
//!   file readable and the parser small — and what makes the schema the single
//!   place a field can be added.
//! - **Missing fields keep their defaults.** A section may be absent entirely;
//!   a field may be absent; the parse result is a complete `Config` either way.
//!   The canonical encoding always writes every section and every field, so
//!   `parse(encode(cfg))` equals `cfg` for any config (round-trip test).
//! - **Comments (`//`) are accepted and dropped.** The canonical form is a
//!   pure function of the config; a saved file is exactly what `encode` writes.
//! - **Floats round-trip.** `{d}` formatting plus `parseFloat` inverts bit for
//!   bit, the same property `.zson` relies on.
//!
//! Parsing is strict in the ways that catch typos (unknown section, unknown
//! field, duplicate field, value on a second token of the line) and lenient in
//! the ways that help a human (comments, blank lines, either list style,
//! either color of whitespace). Out-of-range values are NOT rejected here —
//! `schema.validate` does that, so the UI can load a config it disagrees with,
//! show the problem and let the user fix it.

const std = @import("std");
const core = @import("core");
const config = @import("config.zig");
const schema = @import("schema.zig");

const log = core.log.scoped("project");

const Allocator = std.mem.Allocator;
const Writer = std.Io.Writer;

pub const Config = config.Config;

pub const ParseError = error{
    Malformed,
    UnterminatedSection,
    UnterminatedString,
    UnknownSection,
    UnknownField,
    DuplicateField,
    DuplicateAction,
    TypeMismatch,
    InvalidValue,
    OutOfMemory,
};

/// Where and what. One buffer, because a parse fails once and the caller wants
/// the first problem, not a list to page through.
pub const Diagnostics = struct {
    line: usize = 0,
    buf: [192]u8 = undefined,
    len: usize = 0,

    pub fn text(self: *const Diagnostics) []const u8 {
        return self.buf[0..self.len];
    }

    /// Records `prefix: message`. `prefix` names the section and field (empty
    /// for whole-document problems), which is what makes a validation message
    /// readable: "physics.gravity: 100000 is above the maximum of 1000".
    pub fn record(self: *Diagnostics, line: usize, prefix: []const u8, comptime fmt: []const u8, args: anytype) void {
        self.line = line;
        const head_len = @min(prefix.len, self.buf.len);
        @memcpy(self.buf[0..head_len], prefix[0..head_len]);
        if (std.fmt.bufPrint(self.buf[head_len..], fmt, args)) |msg| {
            self.len = head_len + msg.len;
        } else |_| {
            self.len = head_len; // overflowed: keep the prefix, drop the tail
        }
    }
};

/// Caps the file read in `config.load`. A project config is hundreds of bytes;
/// a megabyte is already a typo or an append-loop in a tool, and both deserve
/// a clear error rather than a growing allocation.
pub const max_config_bytes = 1 << 20;

// ── Decoding ────────────────────────────────────────────────────────────────

/// Parses a document into an arena-owned `Config`. The arena is created from
/// `allocator` and stored on the result: every string in the config points
/// into it, and `Config.deinit` frees it.
pub fn parse(allocator: Allocator, text: []const u8) ParseError!Config {
    return parseDiag(allocator, text, null);
}

/// `parse` with a diagnostics sink: on failure, the line number and a message
/// naming the section and field.
pub fn parseDiag(allocator: Allocator, text: []const u8, diag: ?*Diagnostics) ParseError!Config {
    var arena = allocator.create(std.heap.ArenaAllocator) catch return error.OutOfMemory;
    arena.* = std.heap.ArenaAllocator.init(allocator);
    errdefer {
        arena.deinit();
        allocator.destroy(arena);
    }

    var cfg = Config{};
    var p = Parser{ .text = text, .alloc = arena.allocator(), .diag = diag };

    while (true) {
        p.skipTrivia();
        if (p.pos >= p.text.len) break;
        const name = try p.identifier();
        if (std.mem.eql(u8, name, "project")) {
            cfg.project = try p.stringLit();
            try p.expectEol("project");
        } else if (std.mem.eql(u8, name, "version")) {
            cfg.version = try p.stringLit();
            try p.expectEol("version");
        } else {
            var matched = false;
            inline for (schema.registry) |entry| {
                if (std.mem.eql(u8, entry.name, name)) {
                    matched = true;
                    if (comptime entry.T == void) {
                        try p.parseInputMap(&cfg.input_map);
                    } else {
                        try p.parseSectionBody(entry.T, entry.name, &@field(cfg, entry.name));
                    }
                }
            }
            if (!matched) return p.fail(error.UnknownSection, "unknown section '{s}'", .{name});
        }
    }

    cfg.arena = arena;
    return cfg;
}

const Parser = struct {
    text: []const u8,
    pos: usize = 0,
    line: usize = 1,
    alloc: Allocator,
    diag: ?*Diagnostics = null,

    fn fail(
        self: *Parser,
        comptime kind: ParseError,
        comptime fmt: []const u8,
        args: anytype,
    ) ParseError {
        if (self.diag) |d| {
            d.record(self.line, "", fmt, args);
        }
        return kind;
    }

    /// Whitespace, newlines (counted) and `//` comments.
    fn skipTrivia(self: *Parser) void {
        while (self.pos < self.text.len) {
            switch (self.text[self.pos]) {
                ' ', '\t', '\r' => self.pos += 1,
                '\n' => {
                    self.pos += 1;
                    self.line += 1;
                },
                '/' => {
                    if (self.pos + 1 < self.text.len and self.text[self.pos + 1] == '/') {
                        while (self.pos < self.text.len and self.text[self.pos] != '\n') self.pos += 1;
                    } else return;
                },
                else => return,
            }
        }
    }

    /// Horizontal whitespace only: the value stays on the field's line.
    fn skipSpaces(self: *Parser) void {
        while (self.pos < self.text.len) : (self.pos += 1) {
            const c = self.text[self.pos];
            if (c != ' ' and c != '\t' and c != '\r') return;
        }
    }

    fn peekIs(self: *const Parser, byte: u8) bool {
        return self.pos < self.text.len and self.text[self.pos] == byte;
    }

    fn accept(self: *Parser, byte: u8) bool {
        if (self.pos < self.text.len and self.text[self.pos] == byte) {
            self.pos += 1;
            return true;
        }
        return false;
    }

    fn identifier(self: *Parser) ParseError![]const u8 {
        self.skipSpaces();
        const start = self.pos;
        if (self.pos >= self.text.len) return self.fail(error.Malformed, "expected an identifier, found end of file", .{});
        const head = self.text[self.pos];
        if (!isIdentHead(head)) {
            return self.fail(error.Malformed, "expected an identifier, found '{c}'", .{head});
        }
        while (self.pos < self.text.len and isIdentBody(self.text[self.pos])) self.pos += 1;
        return self.text[start..self.pos];
    }

    /// A double-quoted string with `\" \\ \n \t \r` escapes, returned freshly
    /// allocated (into the config's arena): the config outlives the parse
    /// buffer in the load-from-file case, so aliasing the text would be a
    /// dangling pointer with a nice name.
    fn stringLit(self: *Parser) ParseError![]const u8 {
        self.skipSpaces();
        if (!self.accept('"')) {
            if (self.pos >= self.text.len) {
                return self.fail(error.TypeMismatch, "expected a quoted string, found end of file", .{});
            }
            return self.fail(error.TypeMismatch, "expected a quoted string, found '{c}'", .{self.text[self.pos]});
        }
        var out: std.ArrayList(u8) = .empty;
        errdefer out.deinit(self.alloc);
        while (self.pos < self.text.len) : (self.pos += 1) {
            const c = self.text[self.pos];
            switch (c) {
                '"' => {
                    self.pos += 1;
                    return out.toOwnedSlice(self.alloc) catch return error.OutOfMemory;
                },
                '\n' => return self.fail(error.UnterminatedString, "unterminated string (a raw newline inside \"...\" )", .{}),
                '\\' => {
                    self.pos += 1;
                    if (self.pos >= self.text.len) return self.fail(error.UnterminatedString, "unterminated escape at end of file", .{});
                    const esc = self.text[self.pos];
                    const unescaped: u8 = switch (esc) {
                        '"' => '"',
                        '\\' => '\\',
                        'n' => '\n',
                        't' => '\t',
                        'r' => '\r',
                        else => return self.fail(error.Malformed, "unknown escape '\\{c}'", .{esc}),
                    };
                    out.append(self.alloc, unescaped) catch return error.OutOfMemory;
                },
                else => out.append(self.alloc, c) catch return error.OutOfMemory,
            }
        }
        return self.fail(error.UnterminatedString, "unterminated string at end of file", .{});
    }

    fn numberToken(self: *Parser) ParseError![]const u8 {
        self.skipSpaces();
        const start = self.pos;
        while (self.pos < self.text.len) : (self.pos += 1) {
            const c = self.text[self.pos];
            switch (c) {
                '0'...'9', '+', '-', '.', 'e', 'E' => {},
                else => break,
            }
        }
        if (self.pos == start) {
            if (self.pos >= self.text.len) {
                return self.fail(error.TypeMismatch, "expected a number, found end of file", .{});
            }
            return self.fail(error.TypeMismatch, "expected a number, found '{c}'", .{self.text[self.pos]});
        }
        return self.text[start..self.pos];
    }

    /// After a value: only spaces, a comment and then newline/`}`/EOF. A second
    /// token on the line is a typo, and the message says which field it broke.
    fn expectEol(self: *Parser, what: []const u8) ParseError!void {
        self.skipSpaces();
        if (self.pos + 1 < self.text.len and self.text[self.pos] == '/' and self.text[self.pos + 1] == '/') {
            while (self.pos < self.text.len and self.text[self.pos] != '\n') self.pos += 1;
        }
        if (self.pos >= self.text.len) return;
        const c = self.text[self.pos];
        if (c == '\n' or c == '}') return;
        return self.fail(error.Malformed, "unexpected '{c}' after the value of '{s}'", .{ c, what });
    }

    /// `{ ... }` for a typed section. The fields are matched by name against
    /// the schema struct; every field is optional, none may appear twice.
    fn parseSectionBody(self: *Parser, comptime T: type, comptime section: []const u8, out: *T) ParseError!void {
        self.skipSpaces();
        if (!self.accept('{')) {
            return self.fail(error.Malformed, "expected '{{' after section '{s}'", .{section});
        }
        const fields = @typeInfo(T).@"struct".fields;
        var seen = [_]bool{false} ** fields.len;
        while (true) {
            self.skipTrivia();
            if (self.pos >= self.text.len) {
                return self.fail(error.UnterminatedSection, "section '{s}' is missing its closing '}}'", .{section});
            }
            if (self.text[self.pos] == '}') {
                self.pos += 1;
                return;
            }
            const name = try self.identifier();
            var matched = false;
            inline for (fields, 0..) |f, i| {
                if (std.mem.eql(u8, f.name, name)) {
                    if (seen[i]) {
                        return self.fail(error.DuplicateField, "field '{s}.{s}' appears twice", .{ section, name });
                    }
                    seen[i] = true;
                    matched = true;
                    try self.parseFieldValue(f.type, section ++ "." ++ f.name, &@field(out, f.name));
                    try self.expectEol(section ++ "." ++ f.name);
                }
            }
            if (!matched) {
                return self.fail(error.UnknownField, "unknown field '{s}' in section '{s}'", .{ name, section });
            }
        }
    }

    fn parseFieldValue(self: *Parser, comptime T: type, comptime name: []const u8, out: *T) ParseError!void {
        if (T == []const u8) {
            out.* = try self.stringLit();
            return;
        }
        switch (@typeInfo(T)) {
            .bool => {
                const word = try self.identifier();
                if (std.mem.eql(u8, word, "true")) {
                    out.* = true;
                } else if (std.mem.eql(u8, word, "false")) {
                    out.* = false;
                } else {
                    return self.fail(error.TypeMismatch, "'{s}' expects true or false, found '{s}'", .{ name, word });
                }
            },
            .int => {
                const tok = try self.numberToken();
                out.* = std.fmt.parseInt(T, tok, 10) catch {
                    return self.fail(error.InvalidValue, "'{s}': '{s}' is not an integer", .{ name, tok });
                };
            },
            .float => {
                const tok = try self.numberToken();
                out.* = parseFloatLoose(T, tok) catch {
                    return self.fail(error.InvalidValue, "'{s}': '{s}' is not a number", .{ name, tok });
                };
            },
            .@"enum" => {
                // The canonical spelling is a quoted string (`sort_mode
                // "front_to_back"`), because it reads like every other text
                // value in the file; a bare word is accepted too, since half
                // the enums look exactly like one.
                self.skipSpaces();
                const word = if (self.peekIs('"')) try self.stringLit() else try self.identifier();
                out.* = std.meta.stringToEnum(T, word) orelse {
                    return self.fail(error.InvalidValue, "'{s}': '{s}' is not one of {s}", .{ name, word, comptime enumOptions(T) });
                };
            },
            .@"struct" => try self.parseSectionBody(T, name, out),
            .pointer => |ptr| {
                if (ptr.size == .slice and ptr.is_const and ptr.child == []const u8) {
                    try self.parseStringList(out);
                } else {
                    @compileError("project.config field '" ++ name ++ "': unsupported type " ++ @typeName(T));
                }
            },
            else => @compileError("project.config field '" ++ name ++ "': unsupported type " ++ @typeName(T)),
        }
    }

    /// A list of strings, in either spelling: `["A", "B"]` or `"A" "B"`. The
    /// canonical encoder writes whichever the schema marks for the field
    /// (bare for `layers.names`, brackets for input bindings).
    fn parseStringList(self: *Parser, out: *[]const []const u8) ParseError!void {
        var list: std.ArrayList([]const u8) = .empty;
        errdefer list.deinit(self.alloc);
        self.skipSpaces();
        if (self.accept('[')) {
            while (true) {
                self.skipTrivia();
                if (self.pos >= self.text.len) {
                    return self.fail(error.Malformed, "unterminated '[' list", .{});
                }
                if (self.text[self.pos] == ']') {
                    self.pos += 1;
                    break;
                }
                try list.append(self.alloc, try self.stringLit());
                self.skipSpaces();
                _ = self.accept(',');
            }
        } else {
            while (true) {
                self.skipSpaces();
                if (self.pos < self.text.len and self.text[self.pos] == '"') {
                    try list.append(self.alloc, try self.stringLit());
                } else break;
            }
        }
        out.* = list.toOwnedSlice(self.alloc) catch return error.OutOfMemory;
    }

    /// The one dynamic section: `action_name [bindings]` per line, action names
    /// user-defined (they are gameplay vocabulary, not engine vocabulary).
    fn parseInputMap(self: *Parser, out: *[]const config.InputAction) ParseError!void {
        self.skipSpaces();
        if (!self.accept('{')) {
            return self.fail(error.Malformed, "expected '{{' after section 'input_map'", .{});
        }
        var list: std.ArrayList(config.InputAction) = .empty;
        errdefer list.deinit(self.alloc);
        while (true) {
            self.skipTrivia();
            if (self.pos >= self.text.len) {
                return self.fail(error.UnterminatedSection, "section 'input_map' is missing its closing '}}'", .{});
            }
            if (self.text[self.pos] == '}') {
                self.pos += 1;
                break;
            }
            const action = try self.identifier();
            for (list.items) |existing| {
                if (std.mem.eql(u8, existing.name, action)) {
                    return self.fail(error.DuplicateAction, "action '{s}' is defined twice", .{action});
                }
            }
            var bindings: []const []const u8 = &.{};
            try self.parseStringList(&bindings);
            try self.expectEol(action);
            const owned = self.alloc.dupe(u8, action) catch return error.OutOfMemory;
            list.append(self.alloc, .{ .name = owned, .bindings = bindings }) catch return error.OutOfMemory;
        }
        out.* = list.toOwnedSlice(self.alloc) catch return error.OutOfMemory;
    }
};

fn isIdentHead(c: u8) bool {
    return std.ascii.isAlphabetic(c) or c == '_';
}

fn isIdentBody(c: u8) bool {
    return std.ascii.isAlphanumeric(c) or c == '_';
}

/// `"4"` is a fine float for a human to write; `parseFloat` disagrees. Integers
/// without a fraction or exponent go through `parseInt` and widen.
fn parseFloatLoose(comptime T: type, tok: []const u8) !T {
    if (std.fmt.parseFloat(T, tok)) |v| {
        return v;
    } else |_| {
        if (std.mem.indexOfAny(u8, tok, ".eE") == null) {
            const n = try std.fmt.parseInt(i128, tok, 10);
            return @floatFromInt(n);
        }
        return error.InvalidCharacter;
    }
}

fn enumOptions(comptime T: type) []const u8 {
    comptime {
        var out: []const u8 = "";
        for (@typeInfo(T).@"enum".fields, 0..) |f, i| {
            if (i != 0) out = out ++ ", ";
            out = out ++ "\"" ++ f.name ++ "\"";
        }
        return out;
    }
}

// ── Encoding ────────────────────────────────────────────────────────────────

/// Canonical text: header, then every section in schema order, every field in
/// declaration order, one blank line between sections, final newline. Two
/// configs that are equal produce byte-identical documents, which is what makes
/// `save` diffable and the round-trip test a real equality check.
pub fn encode(cfg: *const Config, w: *Writer) !void {
    try w.writeAll("project ");
    try writeQuoted(w, cfg.project);
    try w.writeAll("\nversion ");
    try writeQuoted(w, cfg.version);
    try w.writeAll("\n");

    var first = true;
    inline for (schema.registry) |entry| {
        if (!first) try w.writeAll("\n");
        first = false;
        if (comptime entry.T == void) {
            try encodeInputMap(cfg.input_map, w);
        } else {
            try w.writeAll(entry.name);
            try w.writeAll(" ");
            try encodeSectionBody(entry.name, &@field(cfg, entry.name), w, 0);
            try w.writeAll("\n");
        }
    }
}

pub fn encodeToString(allocator: Allocator, cfg: *const Config) ![]u8 {
    var out: Writer.Allocating = .init(allocator);
    errdefer out.deinit();
    try encode(cfg, &out.writer);
    return out.toOwnedSlice();
}

/// `{` fields `}` for a section whose name the caller already wrote. `indent`
/// is the column the closing brace lands in; nested sections (splash_screen)
/// reuse this at indent + 2.
fn encodeSectionBody(comptime section: []const u8, value: anytype, w: *Writer, indent: usize) !void {
    try w.writeAll("{\n");
    inline for (@typeInfo(@TypeOf(value.*)).@"struct".fields) |f| {
        try writeIndent(w, indent + 2);
        try w.writeAll(f.name);
        try w.writeAll(" ");
        try encodeValue(section ++ "." ++ f.name, f.type, &@field(value, f.name), w, indent + 2);
        try w.writeAll("\n");
    }
    try writeIndent(w, indent);
    try w.writeAll("}");
}

fn encodeValue(comptime name: []const u8, comptime T: type, value: *const T, w: *Writer, indent: usize) !void {
    if (T == []const u8) {
        try writeQuoted(w, value.*);
        return;
    }
    switch (@typeInfo(T)) {
        .bool => try w.writeAll(if (value.*) "true" else "false"),
        .int, .float => try w.print("{d}", .{value.*}),
        .@"enum" => try writeQuoted(w, @tagName(value.*)),
        .@"struct" => try encodeSectionBody(name, value, w, indent),
        .pointer => |ptr| {
            if (ptr.size != .slice or ptr.child != []const u8) {
                @compileError("project.config field '" ++ name ++ "': unsupported type " ++ @typeName(T));
            }
            // "layers.names" -> parent section "layers", field "names": the
            // list style is a property of the FIELD, not of the value.
            const parent = comptime name[0 .. std.mem.lastIndexOfScalar(u8, name, '.').?];
            const field = comptime name[std.mem.lastIndexOfScalar(u8, name, '.').? + 1 ..];
            const style = comptime schema.fieldMeta(parent, field).list_style;
            if (style == .bare) {
                for (value.*, 0..) |s, i| {
                    if (i != 0) try w.writeAll(" ");
                    try writeQuoted(w, s);
                }
            } else {
                try w.writeAll("[");
                for (value.*, 0..) |s, i| {
                    if (i != 0) try w.writeAll(", ");
                    try writeQuoted(w, s);
                }
                try w.writeAll("]");
            }
        },
        else => @compileError("project.config field '" ++ name ++ "': unsupported type " ++ @typeName(T)),
    }
}

fn encodeInputMap(actions: []const config.InputAction, w: *Writer) !void {
    try w.writeAll("input_map {\n");
    for (actions) |action| {
        try w.writeAll("  ");
        try w.writeAll(action.name);
        try w.writeAll(" [");
        for (action.bindings, 0..) |b, i| {
            if (i != 0) try w.writeAll(", ");
            try writeQuoted(w, b);
        }
        try w.writeAll("]\n");
    }
    try w.writeAll("}");
}

fn writeIndent(w: *Writer, n: usize) !void {
    var i: usize = 0;
    while (i < n) : (i += 1) try w.writeAll(" ");
}

fn writeQuoted(w: *Writer, text: []const u8) !void {
    try w.writeByte('"');
    for (text) |c| switch (c) {
        '"' => try w.writeAll("\\\""),
        '\\' => try w.writeAll("\\\\"),
        '\n' => try w.writeAll("\\n"),
        '\t' => try w.writeAll("\\t"),
        '\r' => try w.writeAll("\\r"),
        else => try w.writeByte(c),
    };
    try w.writeByte('"');
}

test "parser: a value on a second token of the line is rejected" {
    var diag: Diagnostics = .{};
    const res = parseDiag(std.testing.allocator, "display {\n  width 1280 720\n}\n", &diag);
    try std.testing.expectError(error.Malformed, res);
    try std.testing.expectEqual(@as(usize, 2), diag.line);
}
