//! Lua parser for the editor: structure from tokens, with recovery good enough
//! to keep going.
//!
//! ## Why the editor owns a parser
//!
//! Highlighting (the lexer next door) answers one question — what colour is this
//! run of bytes — and never fails, because a highlighter that failed on a
//! half-typed line would fail during exactly the work the user is doing. What
//! the editor needs beyond colour is *structure*: which `end` closes which
//! `function`, which names are locals and where, which call is being written.
//! That question has to be answered by a parser, and the parser has to answer
//! it for half-finished code too.
//!
//! ## Why not LuaJIT's own parser
//!
//! It is available (`luaL_loadbuffer`) and authoritative — and it was rejected
//! deliberately. It reports one error and stops, it returns no tree, it needs a
//! live `lua_State`, and it would give this module (which today compiles and
//! tests with no C runtime at all) a dependency it does not need. A parser that
//! recovers and returns a tree is worth more here than exact error strings for
//! the handful of positions where the two disagree. What it does lose is exact
//! agreement on the wording of a message — and a red underline that is one token
//! off is no worse than no underline at all, which is the alternative.
//!
//! ## The three things it leaves behind
//!
//! 1. **Diagnostics.** Every syntax error becomes a `Diag` at the byte range of
//!    the offending token. The UI draws them as the error lens; nothing in the
//!    parse path knows what a UI is.
//! 2. **Symbols.** Every function, local and parameter, with the span of its
//!    whole declaration. This drives the outline, go-to-definition and
//!    hover-on-a-name.
//! 3. **Calls and uses.** Each call with its callee path (`actor.get_position`)
//!    and its arguments — the shape the API metadata (signatures, parameter
//!    counts) is checked against — plus every name read with the scope it was
//!    read in, which is what makes `undefined global` and `unused local`
//!    answerable without a second pass.
//!
//! ## Error recovery in one sentence
//!
//! Report at the offending token, then skip forward until a token that starts a
//! statement appears at the start of a line (or a block closes), so one typo
//! costs one squiggle and not the rest of the file — and every loop that could
//! fail to consume is forced to advance, because an editor that hangs on a
//! syntax error has produced something worse than a red line.
//!
//! ## The parse is cheap and the edits are small
//!
//! A whole script parses in microseconds, so the editor re-parses on every edit
//! and never has to keep incremental state. If that ever stops being true, the
//! place to fix it is a tree-edit API, not a faster parser.

const std = @import("std");
const lexer = @import("lexer.zig");

/// The parse error set. `OutOfMemory` propagates untouched; `Syntax` is a
/// bail-out that the enclosing statement catches and recovers from, which is
/// why the two are separate — a syntax problem must not look like an
/// allocation failure to the caller.
const ErrSet = error{Syntax} || std.mem.Allocator.Error;
/// A parse step that yields nothing: the by-far most common shape.
const V = ErrSet!void;

/// Every distinct way a parse can be wrong. The message is composed from the
/// code plus the token spans stored in the `Diag`.
pub const Code = enum {
    /// Something that cannot continue the grammar; `expect` holds what to say.
    expected_token,
    /// A byte that cannot start any token (`?`, a stray `@`).
    unexpected_token,
    /// A `"` or `'` string with no closing quote before the end of the line.
    unterminated_string,
    /// A `[[` / `[==[` bracket that never closes, with or without `--`.
    unterminated_comment,
    /// A `function`/`if`/`while`/... whose `end` never came.
    unclosed_block,
    /// An `end` (or `else`/`until`) with no block open.
    unexpected_end,
    /// `= 1` on something that is not a name or an index.
    cannot_assign,
    /// Statements after a `return` in the same block.
    after_return,
    /// The recursion guard tripped: `((((((...` with no end in sight.
    too_deep,
    /// A number literal Lua could not accept.
    malformed_number,
    /// A call whose `)` never came.
    unclosed_call,
};

/// One syntax problem. `expect` is a static string (never allocated) and the
/// near-* fields point at the surprising token, so the message can be rendered
/// by whoever cares without the parser having to formatted anything.
pub const Diag = struct {
    start: u32,
    len: u32,
    code: Code,
    /// For `.expected_token` and friends: the thing that was wanted.
    expect: []const u8 = "",
    /// The offending token, so the message can say "near 'x'". Zero length
    /// means the end of the file.
    near_start: u32 = 0,
    near_len: u32 = 0,
};

/// The offending token's text, or `"<eof>"` when it is the end of the file.
pub fn nearText(d: Diag, src: []const u8) []const u8 {
    const start: usize = @min(@as(usize, d.near_start), src.len);
    const end: usize = @min(start + @as(usize, d.near_len), src.len);
    if (end <= start) return "<eof>";
    return src[start..end];
}

/// Fills `out` with the human message for `d`, reading the offending token from
/// `src`. Truncated rather than failed if the token is enormous.
pub fn describe(d: Diag, src: []const u8, out: *[160]u8) []const u8 {
    const near = nearText(d, src);
    const text: []const u8 = switch (d.code) {
        .expected_token => std.fmt.bufPrint(out, "expected '{s}' near '{s}'", .{ d.expect, near }) catch "expected a token",
        .unexpected_token => std.fmt.bufPrint(out, "unexpected token near '{s}'", .{near}) catch "unexpected token",
        .unterminated_string => std.fmt.bufPrint(out, "unterminated string near '{s}'", .{near}) catch "unterminated string",
        .unterminated_comment => std.fmt.bufPrint(out, "unterminated long comment near '{s}'", .{near}) catch "unterminated comment",
        .unclosed_block => std.fmt.bufPrint(out, "unfinished block: 'end' expected near '{s}'", .{near}) catch return "unfinished block",
        .unexpected_end => std.fmt.bufPrint(out, "unexpected 'end' near '{s}'", .{near}) catch "unexpected 'end'",
        .cannot_assign => std.fmt.bufPrint(out, "cannot assign to '{s}'", .{near}) catch "cannot assign here",
        .after_return => std.fmt.bufPrint(out, "statements are not allowed after 'return' near '{s}'", .{near}) catch "statements after 'return'",
        .too_deep => "expression nests too deeply",
        .malformed_number => std.fmt.bufPrint(out, "malformed number near '{s}'", .{near}) catch "malformed number",
        .unclosed_call => std.fmt.bufPrint(out, "unclosed call: ')' expected near '{s}'", .{near}) catch "unclosed call",
    };
    return text;
}

// ─── Parse results ─────────────────────────────────────────────────────────

pub const SymbolKind = enum { fun, local, param };

/// A declared name. `start`/`len` cover the WHOLE declaration — `function` to
/// `end` — so go-to-definition can select something meaningful.
pub const Symbol = struct {
    name_start: u32,
    name_len: u32,
    start: u32,
    len: u32,
    kind: SymbolKind,
};

/// `assign` is a write of a global (`x = 1`, `function f() ... end`), which is
/// not a read: a global being written for the first time is not a misspelling,
/// and flagging one would put an underline under every top-level function.
pub const UseKind = enum { decl, read, assign };

pub const Use = struct {
    start: u32,
    len: u32,
    /// Index into `Result.scopes` of the scope this name was used in.
    scope: u32,
    kind: UseKind,
};

/// A lexical scope. Blocks, function bodies and table constructors each open
/// one; `parent` walks outwards.
pub const Scope = struct {
    parent: u32,
};

pub const no_scope: u32 = std.math.maxInt(u32);

/// A foldable range: a block whose header is on the first line and whose `end`
/// (or `until`) is the last.
pub const Fold = struct {
    start: u32,
    len: u32,
};

/// What an argument literally is, for the API checks (a string literal where a
/// number was asked for is visible without running the script).
pub const ArgKind = enum {
    number,
    string,
    boolean,
    nil,
    table,
    func,
    name,
    vararg,
    expr,
};

pub const Arg = struct {
    start: u32,
    /// Covers the whole argument expression, not just its first token, so a
    /// diagnostic can underline what the user actually wrote.
    len: u32,
    kind: ArgKind,
};

pub const Call = struct {
    /// `"actor.get_position"`: the callee's byte range in the source.
    path_start: u32,
    path_len: u32,
    /// Index of the first argument in `Result.args`.
    arg_first: u32,
    arg_count: u16,
    /// A `:` call: Lua adds the implicit `self` argument on its own.
    method: bool,
};

/// Everything the parse produced. All offsets are byte offsets into the source
/// that was parsed; nothing is copied out of it.
pub const Result = struct {
    diags: []Diag,
    symbols: []Symbol,
    uses: []Use,
    scopes: []Scope,
    calls: []Call,
    args: []Arg,
    folds: []Fold,

    /// The callee text of a call, with surrounding bytes trimmed: a newline
    /// between `actor` and `.` is legal Lua, and the metadata path is not.
    pub fn callPath(src: []const u8, call: Call) []const u8 {
        const raw = src[call.path_start .. @min(call.path_start + call.path_len, src.len)];
        return std.mem.trim(u8, raw, " \t\r\n");
    }

    pub fn name(src: []const u8, sym: Symbol) []const u8 {
        return src[sym.name_start .. sym.name_start + sym.name_len];
    }

    pub fn deinit(self: *Result, allocator: std.mem.Allocator) void {
        allocator.free(self.diags);
        allocator.free(self.symbols);
        allocator.free(self.uses);
        allocator.free(self.scopes);
        allocator.free(self.calls);
        allocator.free(self.args);
        allocator.free(self.folds);
    }
};

/// Parses `src`, allocating every list in `allocator`. Never fails on a syntax
/// problem: a broken file parses as far as it can and reports what it found,
/// because an editor is asked to parse broken files far more often than whole
/// ones.
pub fn parse(allocator: std.mem.Allocator, src: []const u8) !Result {
    var p = try Parser.init(allocator, src);
    defer p.deinit();
    try p.chunk();
    return Result{
        .diags = try p.diags.toOwnedSlice(allocator),
        .symbols = try p.symbols.toOwnedSlice(allocator),
        .uses = try p.uses.toOwnedSlice(allocator),
        .scopes = try p.scopes.toOwnedSlice(allocator),
        .calls = try p.calls.toOwnedSlice(allocator),
        .args = try p.args.toOwnedSlice(allocator),
        .folds = try p.folds.toOwnedSlice(allocator),
    };
}

// ─── The parser ──────────────────────────────────────────────────────────────

const max_diags = 256;
const max_depth = 100;
/// Unary precedence, straight out of Lua 5.1's table.
const unary_prio = 8;

const TokKind = enum { eof, name, number, string, op, invalid };

const Token = struct {
    kind: TokKind,
    start: usize,
    len: usize,
    /// Offset of the start of the line the token is on. Used to tell "a
    /// statement starts here" from "in the middle of whatever it was".
    line_start: usize,

    fn end(self: Token) usize {
        return self.start + self.len;
    }
};

const Parser = struct {
    allocator: std.mem.Allocator,
    src: []const u8,
    pos: usize = 0,
    /// Offset of the start of the current line, maintained by the scanner.
    line_start: usize = 0,
    /// End offset of the token that was consumed before `tok`, which is how
    /// "this token is at the start of a line" is answered without a second pass.
    prev_end: usize = 0,
    tok: Token = .{ .kind = .eof, .start = 0, .len = 0, .line_start = 0 },
    diags: std.ArrayListUnmanaged(Diag) = .empty,
    symbols: std.ArrayListUnmanaged(Symbol) = .empty,
    uses: std.ArrayListUnmanaged(Use) = .empty,
    scopes: std.ArrayListUnmanaged(Scope) = .empty,
    calls: std.ArrayListUnmanaged(Call) = .empty,
    args: std.ArrayListUnmanaged(Arg) = .empty,
    folds: std.ArrayListUnmanaged(Fold) = .empty,
    depth: u16 = 0,
    cur_scope: u32 = 0,

    fn init(allocator: std.mem.Allocator, src: []const u8) !Parser {
        var p = Parser{ .allocator = allocator, .src = src };
        // Scope 0 is the chunk's own scope, always present: every use has a
        // parent to ask for, including the ones at the very top of the file.
        try p.scopes.append(allocator, .{ .parent = no_scope });
        try p.advance();
        return p;
    }

    fn deinit(self: *Parser) void {
        self.diags.deinit(self.allocator);
        self.symbols.deinit(self.allocator);
        self.uses.deinit(self.allocator);
        self.scopes.deinit(self.allocator);
        self.calls.deinit(self.allocator);
        self.args.deinit(self.allocator);
        self.folds.deinit(self.allocator);
    }

    // ── Diagnostics ────────────────────────────────────────────────────────

    fn pushDiag(self: *Parser, d: Diag) V {
        // A file that is entirely broken must not produce megabytes of
        // diagnostics; the first 256 are the ones the lens could show anyway.
        if (self.diags.items.len >= max_diags) return;
        try self.diags.append(self.allocator, d);
    }

    fn errAt(self: *Parser, code: Code, t: Token) V {
        try self.pushDiag(.{
            .start = u(t.start),
            .len = if (t.kind == .eof) 0 else u(t.len),
            .code = code,
            .near_start = u(t.start),
            .near_len = if (t.kind == .eof) 0 else u(t.len),
        });
    }

    fn errExpected(self: *Parser, want: []const u8) V {
        try self.pushDiag(.{
            .start = u(self.tok.start),
            .len = if (self.tok.kind == .eof) 0 else u(self.tok.len),
            .code = .expected_token,
            .expect = want,
            .near_start = u(self.tok.start),
            .near_len = if (self.tok.kind == .eof) 0 else u(self.tok.len),
        });
    }

    fn expectWord(self: *Parser, want: []const u8) V {
        if (self.tokWord(want)) {
            try self.advance();
            return;
        }
        try self.errExpected(want);
        return error.Syntax;
    }

    /// The `)` form of a call: reported as an unclosed call rather than a bare
    /// "expected ')'", because that is what the position means to a reader.
    fn expectCallClose(self: *Parser) V {
        if (self.tokIs(")")) return self.advance();
        try self.pushDiag(.{
            .start = u(self.tok.start),
            .len = if (self.tok.kind == .eof) 0 else u(self.tok.len),
            .code = .unclosed_call,
            .near_start = u(self.tok.start),
            .near_len = if (self.tok.kind == .eof) 0 else u(self.tok.len),
        });
        return error.Syntax;
    }

    fn expectOp(self: *Parser, want: []const u8) V {
        if (self.tokIs(want)) {
            try self.advance();
            return;
        }
        try self.errExpected(want);
        return error.Syntax;
    }

    fn expectName(self: *Parser) V {
        if (self.tok.kind == .name) {
            try self.advance();
            return;
        }
        try self.errExpected("a name");
        return error.Syntax;
    }

    // ── Recording ─────────────────────────────────────────────────────────

    /// Records the use at the current token and returns its index, so the
    /// caller can re-label it once the grammar says which kind it was: only a
    /// statement-level rule knows whether `x` is being read or written.
    fn recordName(self: *Parser, kind: UseKind) ErrSet!?u32 {
        if (self.tok.kind != .name) return null;
        try self.uses.append(self.allocator, .{
            .start = u(self.tok.start),
            .len = u(self.tok.len),
            .scope = self.cur_scope,
            .kind = kind,
        });
        return @intCast(self.uses.items.len - 1);
    }

    /// A declaration token (a local's name, a parameter): recorded as a use so
    /// the semantic pass has one thing to reason about for every name.
    fn recordDecl(self: *Parser, t: Token) V {
        try self.uses.append(self.allocator, .{
            .start = u(t.start),
            .len = u(t.len),
            .scope = self.cur_scope,
            .kind = .decl,
        });
    }

    fn recordSymbol(self: *Parser, name: Token, body_start: usize, body_len: usize, kind: SymbolKind) V {
        try self.symbols.append(self.allocator, .{
            .name_start = u(name.start),
            .name_len = u(name.len),
            .start = u(body_start),
            .len = u(body_len),
            .kind = kind,
        });
    }

    fn recordFold(self: *Parser, header_start: usize) V {
        try self.folds.append(self.allocator, .{
            .start = u(header_start),
            .len = u(self.prev_end - header_start),
        });
    }

    // ── Scopes ─────────────────────────────────────────────────────────────

    fn pushScope(self: *Parser) V {
        try self.scopes.append(self.allocator, .{ .parent = self.cur_scope });
        self.cur_scope = @intCast(self.scopes.items.len - 1);
    }

    fn popScope(self: *Parser) void {
        const parent = self.scopes.items[self.cur_scope].parent;
        if (parent != no_scope) self.cur_scope = parent;
    }

    // ── Token helpers ─────────────────────────────────────────────────────

    fn tokText(self: *Parser) []const u8 {
        if (self.tok.kind == .eof) return "";
        return self.src[self.tok.start..self.tok.end()];
    }

    fn tokIs(self: *Parser, word: []const u8) bool {
        return self.tok.kind == .op and eq(self.tokText(), word);
    }

    fn tokWord(self: *Parser, word: []const u8) bool {
        return self.tok.kind == .name and eq(self.tokText(), word);
    }

    /// A copy of the next token taken by saving and restoring the scanner
    /// position — cheaper than a look-ahead buffer, and correct because the
    /// scanner is a pure function of its position.
    fn peekTok(self: *Parser) Token {
        const save_pos = self.pos;
        const save_line = self.line_start;
        const r = self.scan();
        self.pos = save_pos;
        self.line_start = save_line;
        return r.tok;
    }

    fn peekIs(self: *Parser, word: []const u8) bool {
        const t = self.peekTok();
        return t.kind == .op and eq(self.src[t.start..t.end()], word);
    }

    fn advance(self: *Parser) V {
        self.prev_end = self.tok.end();
        const r = self.scan();
            self.tok = r.tok;
        if (r.diag) |d| try self.pushDiag(d);
    }

    // ── The scanner ────────────────────────────────────────────────────────

    const Scan = struct { tok: Token, diag: ?Diag = null };

    /// Reads the next token. Allocation-free: a lexical problem is returned
    /// next to its token rather than pushed here, so look-ahead cannot spend
    /// diagnostics it has not consumed yet.
    fn scan(self: *Parser) Scan {
        var diag: ?Diag = null;
        // Trivia (whitespace, comments) can only ever come before a token, so
        // one pass is enough: the function returning false means "real token".
        while (self.skipTrivia(&diag)) {}
        if (self.pos >= self.src.len) {
            return .{ .tok = .{ .kind = .eof, .start = self.src.len, .len = 0, .line_start = self.line_start }, .diag = diag };
        }
        const start = self.pos;
        const ch = self.src[start];

        // A quoted string. An unterminated one is a token whose run stops at
        // the newline, which is where Lua's own parser stops complaining.
        if (ch == '"' or ch == '\'') {
            const quote = ch;
            self.pos += 1;
            var closed = false;
            while (self.pos < self.src.len) {
                const c = self.src[self.pos];
                if (c == '\\') {
                    self.pos = @min(self.pos + 2, self.src.len);
                    continue;
                }
                if (c == quote) {
                    self.pos += 1;
                    closed = true;
                    break;
                }
                if (c == '\n') break;
                self.pos += 1;
            }
            const tok = self.mk(if (closed) .string else .invalid, start, self.pos - start);
            if (!closed) diag = .{
                .start = u(start),
                .len = u(self.pos - start),
                .code = .unterminated_string,
                .near_start = u(start),
                .near_len = u(self.pos - start),
            };
            return .{ .tok = tok, .diag = diag };
        }

        // A long string, or a plain `[` index. The bracket level is the same
        // rule the highlighter uses, kept in one place per file.
        if (ch == '[') {
            const mark = self.pos;
            if (self.longOpen()) |level| {
                if (!self.skipLongBody(level)) {
                    // Unterminated: the whole run to the end of the file.
                    diag = .{
                        .start = u(mark),
                        .len = u(self.src.len - mark),
                        .code = .unterminated_comment,
                        .near_start = u(mark),
                        .near_len = u(self.src.len - mark),
                    };
                    return .{ .tok = self.mk(.string, start, self.pos - start), .diag = diag };
                }
                return .{ .tok = self.mk(.string, start, self.pos - start), .diag = diag };
            }
        }

        if (isDigit(ch) or (ch == '.' and self.pos + 1 < self.src.len and isDigit(self.src[self.pos + 1]))) {
            var malformed = false;
            if (ch == '0' and self.pos + 1 < self.src.len and (self.src[self.pos + 1] | 0x20) == 'x') {
                self.pos += 2;
                while (self.pos < self.src.len and isHexDigit(self.src[self.pos])) self.pos += 1;
                if (isIdentByte(self.src[self.pos])) malformed = true;
            } else {
                while (self.pos < self.src.len and (isDigit(self.src[self.pos]) or self.src[self.pos] == '.')) self.pos += 1;
                if (self.pos < self.src.len and (self.src[self.pos] == 'e' or self.src[self.pos] == 'E')) {
                    self.pos += 1;
                    if (self.pos < self.src.len and (self.src[self.pos] == '+' or self.src[self.pos] == '-')) self.pos += 1;
                    if (self.pos < self.src.len and isDigit(self.src[self.pos])) {
                        while (self.pos < self.src.len and isDigit(self.src[self.pos])) self.pos += 1;
                    } else malformed = true;
                }
                if (self.pos < self.src.len and isIdentByte(self.src[self.pos])) malformed = true;
            }
            if (malformed) return .{ .tok = self.mk(.invalid, start, self.pos - start) };
            return .{ .tok = self.mk(.number, start, self.pos - start) };
        }

        if (isAlphabetic(ch) or ch == '_') {
            while (self.pos < self.src.len and isIdentByte(self.src[self.pos])) self.pos += 1;
            return .{ .tok = self.mk(.name, start, self.pos - start) };
        }

        // `...` before the two-character forms, or `..` would eat two of it. The
        // length check is what keeps `..` and `...` from both matching a bare
        // `..`: a token must be found by position, not by prefix.
        if (self.pos + 3 <= self.src.len and eq(self.src[self.pos .. self.pos + 3], "...")) {
            self.pos += 3;
            return .{ .tok = self.mk(.op, start, 3) };
        }
        if (self.pos + 1 < self.src.len) {
            const two = self.src[self.pos .. self.pos + 2];
            if (eq(two, "==") or eq(two, "~=") or eq(two, "<=") or eq(two, ">=") or
                eq(two, "..") or eq(two, "::") or eq(two, "//") or eq(two, "<<"))
            {
                self.pos += 2;
                return .{ .tok = self.mk(.op, start, 2) };
            }
        }
        const singles = "+-*/%^#&~|<>=(){}[];:,.?";
        if (std.mem.indexOfScalar(u8, singles, ch) != null) {
            self.pos += 1;
            return .{ .tok = self.mk(.op, start, 1) };
        }
        // A multi-byte character: advance past the whole codepoint so tokens
        // never split one, and let the parser call it unexpected.
        if (ch >= 0x80) {
            self.pos += std.unicode.utf8ByteSequenceLength(ch) catch 1;
            return .{ .tok = self.mk(.invalid, start, self.pos - start) };
        }
        // Anything else is a byte Lua has no token for. It must still consume
        // exactly one byte: a zero-length token would leave the scanner and
        // the parser pointing at the same position for ever, and an editor
        // that hangs on a stray `@` is worse than one that underlines it.
        self.pos += 1;
        return .{ .tok = self.mk(.invalid, start, 1) };
    }

    fn mk(self: *Parser, kind: TokKind, start: usize, len: usize) Token {
        return .{
            .kind = kind,
            .start = start,
            .len = len,
            .line_start = self.line_start,
        };
    }

    fn skipTrivia(self: *Parser, diag: *?Diag) bool {
        while (self.pos < self.src.len) {
            const ch = self.src[self.pos];
            if (ch == '\n') {
                self.pos += 1;
                self.line_start = self.pos;
                return true;
            }
            if (ch == ' ' or ch == '\t' or ch == '\r' or ch == '\x0C') {
                self.pos += 1;
                return true;
            }
            if (ch == '-' and self.pos + 1 < self.src.len and self.src[self.pos + 1] == '-') {
                const comment_start = self.pos;
                self.pos += 2;
                if (self.pos < self.src.len and self.src[self.pos] == '[') {
                    if (self.longOpen()) |level| {
                        if (!self.skipLongBody(level)) {
                            diag.* = .{
                                .start = u(comment_start),
                                .len = u(self.src.len - comment_start),
                                .code = .unterminated_comment,
                                .near_start = u(comment_start),
                                .near_len = u(self.src.len - comment_start),
                            };
                        }
                        return true;
                    }
                }
                while (self.pos < self.src.len and self.src[self.pos] != '\n') self.pos += 1;
                return true;
            }
            return false;
        }
        return false;
    }

    /// If the scan position starts a long bracket (`[`, `[=`, `[==`), returns
    /// its level and leaves the position just after the opening bracket.
    fn longOpen(self: *Parser) ?usize {
        var p = self.pos;
        if (p >= self.src.len or self.src[p] != '[') return null;
        p += 1;
        var level: usize = 0;
        while (p < self.src.len and self.src[p] == '=') : (p += 1) level += 1;
        if (p >= self.src.len or self.src[p] != '[') return null;
        p += 1;
        self.pos = p;
        return level;
    }

    /// Skips a long-bracket body of `level`, leaving the position past its
    /// close. False means it never closed, and the position is at the end.
    fn skipLongBody(self: *Parser, level: usize) bool {
        var buf: [66]u8 = undefined;
        buf[0] = ']';
        var w: usize = 1;
        var bytes: usize = 0;
        while (bytes < level and w + 2 < buf.len) : (bytes += 1) {
            buf[w] = '=';
            w += 1;
        }
        buf[w] = ']';
        w += 1;
        const close = buf[0..w];
        if (std.mem.indexOfPos(u8, self.src, self.pos, close)) |at| {
            self.pos = at + close.len;
            return true;
        }
        self.pos = self.src.len;
        return false;
    }

    // ── Grammar ───────────────────────────────────────────────────────────

    fn chunk(self: *Parser) V {
        self.cur_scope = 0;
        try self.block();
        // Whatever closes a block here has no block open: at the top level an
        // `end` is a stray one, and saying so is more honest than swallowing it
        // (it usually means a block above lost its header).
        var guard: usize = 0;
        while (self.tok.kind != .eof) : (guard += 1) {
            if (guard > max_diags) return;
            if (self.atBlockEnd()) try self.errAt(.unexpected_end, self.tok);
            try self.advance();
        }
    }

    /// A block: statements plus an optional trailing `return`, in a scope of
    /// its own. `params` are the names that live only inside it — function
    /// parameters and loop variables — because Lua puts them in the body
    /// scope, not outside it.
    fn block(self: *Parser) V {
        try self.blockIn(null);
    }

    fn blockIn(self: *Parser, params: ?[]const Token) V {
        try self.pushScope();
        defer self.popScope();
        if (params) |ps| for (ps) |t| try self.recordDecl(t);
        try self.statements();
        if (self.tokWord("return")) try self.retstat();
    }

    fn statements(self: *Parser) V {
        while (!self.atBlockEnd() and self.tok.kind != .eof) {
            const before = self.tok.start;
            // A bail-out here means a statement could not be parsed at all:
            // recover to the next statement boundary and keep going. An
            // allocation failure is the only error that escapes the loop.
            self.statement() catch |err| switch (err) {
                error.OutOfMemory => return error.OutOfMemory,
                error.Syntax => try self.synchronize(),
            };
            // The progress guarantee. Without it, a token that no rule can
            // consume — and no error can report twice — would spin forever, and
            // an editor that hangs is worse than one that draws a wrong squiggle.
            if (self.tok.start == before and self.tok.kind != .eof) try self.advance();
        }
    }

    fn atBlockEnd(self: *Parser) bool {
        if (self.tok.kind != .name) return false;
        const w = self.tokText();
        return eq(w, "end") or eq(w, "else") or eq(w, "elseif") or eq(w, "until");
    }

    fn statement(self: *Parser) V {
        switch (self.tok.kind) {
            .name => {
                const w = self.tokText();
                if (eq(w, "if")) return self.statIf();
                if (eq(w, "while")) return self.statWhile();
                if (eq(w, "do")) return self.statDo();
                if (eq(w, "for")) return self.statFor();
                if (eq(w, "repeat")) return self.statRepeat();
                if (eq(w, "function")) return self.statFunction();
                if (eq(w, "local")) return self.statLocal();
                if (eq(w, "break")) {
                    try self.advance();
                    return;
                }
                if (eq(w, "return")) return self.retstat();
                // `goto name` is a LuaJIT extension, and it is only a statement
                // when a name follows: `goto = 1` is an assignment to a global.
                if (eq(w, "goto") and self.peekTok().kind == .name) {
                    try self.advance();
                    try self.expectName();
                    return;
                }
                return self.exprStat();
            },
            .op => {
                if (self.tokIs("::")) {
                    try self.advance();
                    try self.expectName();
                    try self.expectOp("::");
                    return;
                }
                if (self.tokIs(";")) {
                    try self.advance();
                    return;
                }
                try self.errAt(.unexpected_token, self.tok);
                return error.Syntax;
            },
            else => {
                try self.errAt(.unexpected_token, self.tok);
                return error.Syntax;
            },
        }
    }

    /// Skip forward to a place a statement could start: a fresh statement at
    /// the start of a line, or a token that closes the enclosing block. Bounded
    /// by construction — every iteration consumes — and only ever moves forward.
    fn synchronize(self: *Parser) V {
        while (self.tok.kind != .eof) {
            if (self.atBlockEnd()) return;
            if (self.startsStatement() and self.tok.line_start > self.prev_end) return;
            try self.advance();
        }
    }

    fn startsStatement(self: *Parser) bool {
        if (self.tok.kind == .name) {
            const w = self.tokText();
            return eq(w, "local") or eq(w, "if") or eq(w, "while") or eq(w, "for") or
                eq(w, "repeat") or eq(w, "function") or eq(w, "return") or
                eq(w, "break") or eq(w, "do") or eq(w, "end") or eq(w, "else");
        }
        return self.tokIs("::");
    }

    fn closeBlock(self: *Parser, header_start: usize) V {
        if (self.tokWord("end")) {
            // Advance first, so `prev_end` is the end of the `end` itself: the
            // fold has to include the line it is on.
            try self.advance();
            try self.recordFold(header_start);
            return;
        }
        // A block that never closed is its own kind of wrong: saying which
        // construct it belonged to is more use to a reader than "expected 'end'".
        try self.pushDiag(.{
            .start = u(self.tok.start),
            .len = if (self.tok.kind == .eof) 0 else u(self.tok.len),
            .code = .unclosed_block,
            .near_start = u(self.tok.start),
            .near_len = if (self.tok.kind == .eof) 0 else u(self.tok.len),
        });
        return error.Syntax;
    }

    fn statIf(self: *Parser) V {
        const start = self.tok.start;
        try self.advance();
        try self.expr();
        try self.expectWord("then");
        try self.block();
        while (self.tokWord("elseif")) {
            try self.advance();
            try self.expr();
            try self.expectWord("then");
            try self.block();
        }
        if (self.tokWord("else")) {
            try self.advance();
            try self.block();
        }
        try self.closeBlock(start);
    }

    fn statWhile(self: *Parser) V {
        const start = self.tok.start;
        try self.advance();
        try self.expr();
        try self.expectWord("do");
        try self.block();
        try self.closeBlock(start);
    }

    fn statDo(self: *Parser) V {
        const start = self.tok.start;
        try self.advance();
        try self.block();
        try self.closeBlock(start);
    }

    fn statRepeat(self: *Parser) V {
        const start = self.tok.start;
        try self.advance();
        try self.block();
        // `until` closes a repeat the way `end` closes the others, and the
        // expression after it is still part of the fold: selecting the range
        // should include the line that condition is on.
        if (!self.tokWord("until")) {
            try self.errExpected("until");
            return error.Syntax;
        }
        try self.advance();
        try self.expr();
        try self.recordFold(start);
    }

    fn statFor(self: *Parser) V {
        const start = self.tok.start;
        try self.advance(); // for
        var names: [32]Token = undefined;
        var n: usize = 0;
        if (self.tok.kind != .name) {
            try self.errExpected("a name");
            return error.Syntax;
        }
        names[n] = self.tok;
        n += 1;
        try self.advance();
        while (self.tokIs(",")) {
            try self.advance();
            if (n < names.len) {
                names[n] = self.tok;
                n += 1;
            }
            if (self.tok.kind != .name) {
                try self.errExpected("a name");
                return error.Syntax;
            }
            try self.advance();
        }
        if (self.tokIs("=")) {
            // Numeric for: exactly one name, three expressions.
            try self.advance();
            try self.expr();
            try self.expectOp(",");
            try self.expr();
            if (self.tokIs(",")) {
                try self.advance();
                try self.expr();
            }
        } else if (self.tokWord("in")) {
            try self.advance();
            try self.exprlist();
        } else {
            try self.errExpected("= or 'in'");
            return error.Syntax;
        }
        try self.expectWord("do");
        try self.blockIn(names[0..n]);
        try self.closeBlock(start);
        // The loop variables are locals of the body scope; the symbol records
        // the whole statement so go-to-definition lands somewhere useful.
        const decl_len = self.prev_end - start;
        for (names[0..n]) |t| {
            try self.recordSymbol(t, start, decl_len, .local);
        }
    }

    fn statFunction(self: *Parser) V {
        const start = self.tok.start;
        try self.advance(); // function
        if (self.tok.kind != .name) {
            try self.errExpected("a name");
            return error.Syntax;
        }
        // `a.b.c` reads a global and writes a field of it; only the LAST name
        // is what the declaration is called. A bare `f` writes a global, which
        // is not a read — see `UseKind.assign`.
        const read_idx = try self.recordName(.read);
        var last = self.tok;
        try self.advance();
        var wrote_field = false;
        while (self.tokIs(".")) {
            wrote_field = true;
            try self.advance();
            last = self.tok;
            try self.expectName();
        }
        if (self.tokIs(":")) {
            wrote_field = true;
            try self.advance();
            last = self.tok;
            try self.expectName();
        }
        if (!wrote_field) {
            if (read_idx) |i| self.uses.items[i].kind = .assign;
        }
        try self.funcbody(start);
        try self.recordSymbol(last, start, self.prev_end - start, .fun);
    }

    fn statLocal(self: *Parser) V {
        const start = self.tok.start;
        try self.advance(); // local
        if (self.tokWord("function")) {
            try self.advance();
            const name_tok = self.tok;
            if (name_tok.kind != .name) {
                try self.errExpected("a name");
                return error.Syntax;
            }
            try self.advance();
            // The name is in scope inside its own body, which is what makes
            // recursion work; recording it before the body is parsed is exactly
            // that.
            try self.recordDecl(name_tok);
            try self.funcbody(start);
            try self.recordSymbol(name_tok, start, self.prev_end - start, .fun);
            return;
        }
        var names: [32]Token = undefined;
        var n: usize = 0;
        while (true) {
            if (self.tok.kind != .name) {
                try self.errExpected("a name");
                return error.Syntax;
            }
            if (n < names.len) {
                names[n] = self.tok;
                n += 1;
            }
            try self.advance();
            if (self.tokIs(",")) {
                try self.advance();
                continue;
            }
            break;
        }
        // The names are declared the moment they are read. Recording them
        // BEFORE the initializer is parsed is deliberate: `local x =` with
        // nothing after it yet must still leave the symbol behind, or the
        // outline empties exactly while the user is typing that line.
        const first_sym = self.symbols.items.len;
        const name_end = self.prev_end;
        for (names[0..n]) |t| {
            try self.recordSymbol(t, start, name_end - start, .local);
            try self.recordDecl(t);
        }
        if (self.tokIs("=")) {
            try self.advance();
            try self.exprlist();
            // The initializer parsed, so the declaration now covers it too. A
            // broken one leaves the shorter span rather than no symbol at all.
            const decl_len = self.prev_end - start;
            for (self.symbols.items[first_sym..]) |*sym| sym.len = u(decl_len);
        }
    }

    /// A parameter list, a body and an `end`, from the `function` keyword to
    /// the close. Parameters become locals of the body scope; a method's
    /// implicit `self` has no token here, because Lua adds it on its own and
    /// the API metadata already names it.
    fn funcbody(self: *Parser, body_start: usize) V {
        try self.expectOp("(");
        var params: [32]Token = undefined;
        var n: usize = 0;
        while (!self.tokIs(")") and !self.atBlockEnd() and self.tok.kind != .eof) {
            if (self.tok.kind != .name) break;
            if (n < params.len) {
                params[n] = self.tok;
                n += 1;
            }
            try self.advance();
            if (self.tokIs(",")) {
                try self.advance();
                continue;
            }
            break;
        }
        if (self.tokIs("...")) {
            try self.advance();
            if (self.tokIs(",")) try self.advance();
        }
        try self.expectOp(")");
        try self.blockIn(params[0..n]);
        try self.closeBlock(body_start);
        for (params[0..n]) |t| {
            try self.recordSymbol(t, body_start, self.prev_end - body_start, .param);
        }
    }

    fn retstat(self: *Parser) V {
        try self.advance(); // return
        if (!self.atBlockEnd() and self.tok.kind != .eof and !self.tokIs(";")) {
            try self.exprlist();
        }
        if (self.tokIs(";")) try self.advance();
        // `return` ends a block: anything after it in the same block is a
        // statement Lua will not run, which is worth saying even though the
        // parse continues.
        if (!self.atBlockEnd() and self.tok.kind != .eof) {
            try self.errAt(.after_return, self.tok);
        }
    }

    /// An expression used as a statement: the only legal form is a function
    /// call. Assignment slips in here because it starts like one.
    fn exprStat(self: *Parser) V {
        var targets: [8]u32 = undefined;
        var n_targets: usize = 0;
        const s = try self.suffixedExpr();
        if (s.read_idx) |i| if (n_targets < targets.len) {
            targets[n_targets] = i;
            n_targets += 1;
        };
        if (self.tokIs(",") or self.tokIs("=")) {
            if (!s.assignable) try self.errAt(.cannot_assign, s.start_tok);
            while (self.tokIs(",")) {
                try self.advance();
                const lhs = try self.suffixedExpr();
                if (!lhs.assignable) try self.errAt(.cannot_assign, lhs.start_tok);
                if (lhs.read_idx) |i| if (n_targets < targets.len) {
                    targets[n_targets] = i;
                    n_targets += 1;
                };
            }
            // Now that the grammar has said this is an assignment, the left
            // side is being written. Re-labelling is why `recordName` hands
            // back an index.
            for (targets[0..n_targets]) |i| self.uses.items[i].kind = .assign;
            try self.expectOp("=");
            try self.exprlist();
            return;
        }
        if (!s.is_call) {
            try self.errAt(.unexpected_token, self.tok);
            return error.Syntax;
        }
    }

    /// Statements and expressions that build an assignment or a call. `assign`
    /// is true when the expression so far could have `= 1` written after it —
    /// a name, an index; not a call.
    fn suffixedExpr(self: *Parser) ErrSet!Suffixed {
        const start_tok = self.tok;
        var s = Suffixed{ .start_tok = start_tok };
        if (self.tok.kind == .name) {
            s.read_idx = try self.recordName(.read);
            s.assignable = true;
            try self.advance();
        } else if (self.tokIs("(")) {
            try self.advance();
            try self.expr();
            try self.expectOp(")");
        } else {
            try self.errAt(.unexpected_token, self.tok);
            return error.Syntax;
        }
        while (true) {
            if (self.tokIs(".")) {
                try self.advance();
                try self.expectName();
            } else if (self.tokIs("[")) {
                try self.advance();
                try self.expr();
                try self.expectOp("]");
            } else if (self.tokIs(":")) {
                try self.advance();
                try self.expectName();
                try self.callArgs(start_tok.start, true);
                s.is_call = true;
                s.assignable = false;
            } else if (self.tokIs("(") or self.tok.kind == .string or self.tokIs("{")) {
                try self.callArgs(start_tok.start, false);
                s.is_call = true;
                s.assignable = false;
            } else break;
        }
        return s;
    }

    fn callArgs(self: *Parser, path_start: usize, method: bool) V {
        // The callee ends where the arguments begin, which is this token — not
        // the one after them, which is where the scan sits once it is done.
        const args_start = self.tok.start;
        const arg_first = self.args.items.len;
        var arg_count: u16 = 0;
        if (self.tokIs("(")) {
            try self.advance();
            arg_count = try self.arglist();
            try self.expectCallClose();
        } else if (self.tok.kind == .string) {
            const start = self.tok.start;
            arg_count = 1;
            try self.advance();
            try self.args.append(self.allocator, .{ .start = u(start), .len = u(self.prev_end - start), .kind = .string });
        } else if (self.tokIs("{")) {
            const start = self.tok.start;
            arg_count = 1;
            try self.tableCtor();
            try self.args.append(self.allocator, .{ .start = u(start), .len = u(self.prev_end - start), .kind = .table });
        } else {
            try self.errExpected("function arguments");
            return error.Syntax;
        }
        try self.calls.append(self.allocator, .{
            .path_start = u(path_start),
            .path_len = u(args_start - path_start),
            .arg_first = @intCast(arg_first),
            .arg_count = arg_count,
            .method = method,
        });
    }

    /// A comma-separated argument list, recording each argument's literal kind
    /// before parsing it, because that is the only moment its shape is obvious.
    fn arglist(self: *Parser) ErrSet!u16 {
        var n: u16 = 0;
        while (!self.tokIs(")") and self.tok.kind != .eof) {
            if (n >= 4096) return n;
            const kind = argKindOf(self.tok, self.src);
            const start = self.tok.start;
            // Recorded after the parse, so the span covers the argument the
            // user wrote rather than the first token of it.
            try self.expr();
            try self.args.append(self.allocator, .{ .start = u(start), .len = u(self.prev_end - start), .kind = kind });
            n += 1;
            if (self.tokIs(",")) {
                try self.advance();
                continue;
            }
            break;
        }
        return n;
    }

    fn exprlist(self: *Parser) V {
        try self.expr();
        while (self.tokIs(",")) {
            try self.advance();
            try self.expr();
        }
    }

    fn expr(self: *Parser) V {
        return self.subexpr(0);
    }

    /// Precedence climbing, mirroring Lua's own `subexpr`: unary operators bind
    /// tighter than every binary operator except `^`, and `..` and `^`
    /// associate to the right. The numbers are Lua 5.1's own.
    fn subexpr(self: *Parser, limit: u8) V {
        self.depth += 1;
        defer self.depth -= 1;
        if (self.depth > max_depth) {
            try self.errAt(.too_deep, self.tok);
            return error.Syntax;
        }
        if (self.tokWord("not") or self.tokIs("-") or self.tokIs("#")) {
            try self.advance();
            try self.subexpr(unary_prio);
        } else {
            try self.simpleexp();
        }
        while (true) {
            if (self.tok.kind != .name and self.tok.kind != .op) break;
            const w = self.tokText();
            const left = binopLeft(w) orelse break;
            if (left <= limit) break;
            const right = binopRight(w);
            try self.advance();
            if (right) try self.subexpr(left - 1) else try self.subexpr(left);
        }
    }

    fn simpleexp(self: *Parser) V {
        switch (self.tok.kind) {
            .number, .string => try self.advance(),
            .name => {
                const w = self.tokText();
                if (eq(w, "nil") or eq(w, "true") or eq(w, "false")) {
                    try self.advance();
                } else if (eq(w, "function")) {
                    const start = self.tok.start;
                    try self.advance();
                    try self.funcbody(start);
                } else {
                    _ = try self.suffixedExpr();
                }
            },
            .op => {
                if (self.tokIs("(")) {
                    try self.advance();
                    try self.expr();
                    try self.expectOp(")");
                } else if (self.tokIs("{")) {
                    try self.tableCtor();
                } else if (self.tokIs("...")) {
                    try self.advance();
                } else {
                    try self.errAt(.unexpected_token, self.tok);
                    return error.Syntax;
                }
            },
            else => {
                try self.errAt(.unexpected_token, self.tok);
                return error.Syntax;
            },
        }
    }

    fn tableCtor(self: *Parser) V {
        try self.expectOp("{");
        while (!self.tokIs("}") and self.tok.kind != .eof) {
            if (self.tokIs("[")) {
                try self.advance();
                try self.expr();
                try self.expectOp("]");
                try self.expectOp("=");
                try self.expr();
            } else if (self.tok.kind == .name and self.peekIs("=")) {
                try self.advance(); // the key
                try self.expectOp("=");
                try self.expr();
            } else {
                try self.expr();
            }
            // A separator means another field; anything else ends the table,
            // and the `}` below will say whether that was legal.
            if (self.tokIs(",") or self.tokIs(";")) {
                try self.advance();
                continue;
            }
            break;
        }
        try self.expectOp("}");
    }
};

const Suffixed = struct {
    start_tok: Token,
    is_call: bool = false,
    assignable: bool = false,
    /// Index of the recorded read of the leading name, if there was one: the
    /// statement that sees the whole expression decides whether that name was
    /// read or written.
    read_idx: ?u32 = null,
};

fn argKindOf(t: Token, src: []const u8) ArgKind {
    return switch (t.kind) {
        .number => .number,
        .string => .string,
        .op => if (eq(src[t.start..t.end()], "{")) .table else .expr,
        .name => blk: {
            const w = src[t.start..t.end()];
            if (eq(w, "nil")) break :blk .nil;
            if (eq(w, "true") or eq(w, "false")) break :blk .boolean;
            if (eq(w, "function")) break :blk .func;
            break :blk .name;
        },
        else => .expr,
    };
}

/// Lua 5.1's binary operator table: `or` 1, `and` 2, comparisons 3, `..`
/// right-associative at 5, `+ -` 6, `* / %` 7, unary 8, `^` right at 10.
const binops = [_]struct { word: []const u8, left: u8, right: bool }{
    .{ .word = "or", .left = 1, .right = false },
    .{ .word = "and", .left = 2, .right = false },
    .{ .word = "<", .left = 3, .right = false },
    .{ .word = ">", .left = 3, .right = false },
    .{ .word = "<=", .left = 3, .right = false },
    .{ .word = ">=", .left = 3, .right = false },
    .{ .word = "~=", .left = 3, .right = false },
    .{ .word = "==", .left = 3, .right = false },
    .{ .word = "..", .left = 5, .right = true },
    .{ .word = "+", .left = 6, .right = false },
    .{ .word = "-", .left = 6, .right = false },
    .{ .word = "*", .left = 7, .right = false },
    .{ .word = "/", .left = 7, .right = false },
    .{ .word = "%", .left = 7, .right = false },
    .{ .word = "//", .left = 7, .right = false },
    .{ .word = "^", .left = 10, .right = true },
};

fn binopLeft(word: []const u8) ?u8 {
    for (binops) |b| if (eq(b.word, word)) return b.left;
    return null;
}

fn binopRight(word: []const u8) bool {
    for (binops) |b| if (eq(b.word, word)) return b.right;
    return false;
}

/// The parser works in `usize` because that is what indexing wants; the
/// public types carry `u32` because that is what the buffer spans carry. This
/// is the single place the two meet.
fn u(v: usize) u32 {
    return @intCast(v);
}

fn eq(a: []const u8, b: []const u8) bool {
    return std.mem.eql(u8, a, b);
}

// ─── Tests ───────────────────────────────────────────────────────────────────

const testing = std.testing;

/// Parses `src` and asserts it came out clean, so the tests below read as the
/// grammar they cover rather than as a diag count each one repeats.
fn parseClean(src: []const u8) !Result {
    var r = try parse(testing.allocator, src);
    errdefer r.deinit(testing.allocator);
    if (r.diags.len != 0) {
        var buf: [160]u8 = undefined;
        std.debug.print("unexpected diag: {s}\n", .{describe(r.diags[0], src, &buf)});
    }
    try testing.expectEqual(@as(usize, 0), r.diags.len);
    return r;
}

fn parseFirst(src: []const u8, code: Code) !Result {
    var r = try parse(testing.allocator, src);
    for (r.diags) |d| {
        if (d.code == code) return r;
    }
    var buf: [160]u8 = undefined;
    std.debug.print("got: ", .{});
    for (r.diags) |d| std.debug.print("{s} | ", .{describe(d, src, &buf)});
    std.debug.print("\n", .{});
    r.deinit(testing.allocator);
    return error.WrongCode;
}

fn countDiags(src: []const u8, code: Code) !usize {
    const a = testing.allocator;
    var r = try parse(a, src);
    defer r.deinit(a);
    var n: usize = 0;
    for (r.diags) |d| if (d.code == code) {
        n += 1;
    };
    return n;
}

test "a whole script parses with no diagnostics" {
    const a = testing.allocator;
    const src =
        \\-- a behavior: everything at once
        \\local M = {}
        \\local throttle = 3.14
        \\local long = [==[ a ]] string ]==]
        \\
        \\function M.update(self, dt)
        \\    local x, y = actor.get_position(self)
        \\    for i = 1, 10, 2 do print(i) end
        \\    for k, v in pairs(M) do print(k, v) end
        \\    if x > 0 and y <= 1 or not(x == 2) then
        \\        y = y + #"abc" .. "-" .. long
        \\    elseif x ~= "a" then
        \\        y = #M + 2 ^ 3 ^ 2 - -1 / 2 % 3 // 2
        \\    else
        \\        while y < 10 do y = y + 0.5 end
        \\    end
        \\    repeat y = y - 1 until y <= 0
        \\    do local inner = 1 print(inner) end
        \\    local t = { a = 1, [2] = "x", 3, f = function(z) return z end }
        \\    M:wrap(x, y, t, long)
        \\end
        \\
        \\local function helper(n, ...)
        \\    ::top::
        \\    if n > 0 then return helper(n - 1) end
        \\    return ...
        \\end
        \\
        \\return M
    ;
    var r = try parseClean(src);
    defer r.deinit(a);
    // One fold per block: M.update, both `for`s, the if/elseif/else, the
    // `while`, the `repeat`, the bare `do`, the anonymous function inside the
    // table, `helper` and its own `if`. Ten, counted by hand.
    try testing.expectEqual(@as(usize, 10), r.folds.len);
}

test "an unclosed block says so at the end of the file" {
    const a = testing.allocator;
    var r = try parseFirst("function M.update(self)\n    return 1", .unclosed_block);
    defer r.deinit(a);
    const d = r.diags[0];
    var buf: [160]u8 = undefined;
    try testing.expectEqualStrings("unfinished block: 'end' expected near '<eof>'", describe(d, "function M.update(self)\n    return 1", &buf));
}

test "a stray end at the top level is an unexpected end" {
    const a = testing.allocator;
    var r = try parseFirst("end", .unexpected_end);
    defer r.deinit(a);
}

test "an unterminated string is reported where the quote opened" {
    const a = testing.allocator;
    const src = "local s = \"abc";
    var r = try parseFirst(src, .unterminated_string);
    defer r.deinit(a);
    try testing.expectEqual(@as(u32, 10), r.diags[0].start);
}

test "an unterminated long comment runs to the end of the file" {
    const a = testing.allocator;
    var r = try parseFirst("--[[ never closed\nx = 1", .unterminated_comment);
    defer r.deinit(a);
    try testing.expectEqual(@as(u32, 0), r.diags[0].start);
    try testing.expectEqual(@as(u32, 23), r.diags[0].len);
}

test "a missing closing paren is an unclosed call" {
    const a = testing.allocator;
    var r = try parseFirst("actor.get_position(self", .unclosed_call);
    defer r.deinit(a);
}

test "one bad statement costs one squiggle and the rest of the file still parses" {
    const a = testing.allocator;
    const src =
        \\local x = @
        \\local y = 2
    ;
    var r = try parse(a, src);
    defer r.deinit(a);
    try testing.expectEqual(@as(usize, 1), r.diags.len);
    try testing.expectEqual(@as(usize, 2), r.symbols.len);
    try testing.expectEqualStrings("x", src[r.symbols[0].name_start .. r.symbols[0].name_start + r.symbols[0].name_len]);
    try testing.expectEqualStrings("y", src[r.symbols[1].name_start .. r.symbols[1].name_start + r.symbols[1].name_len]);
}

test "assigning to a call is not an assignment" {
    const a = testing.allocator;
    var r = try parseFirst("math.random(1) = 2", .cannot_assign);
    defer r.deinit(a);
}

test "a statement after return is reported" {
    const a = testing.allocator;
    // `return\nprint(1)` is a return OF the call: an expression after it, not
    // a statement. The broken shape needs a complete expression first.
    var r = try parseFirst("return 1\nprint(1)", .after_return);
    defer r.deinit(a);
}

test "a deep nest trips the guard instead of the stack" {
    const a = testing.allocator;
    // 500 open parens and one expression: a stack that recursed once per paren
    // would die here, which is the only way to find out that it would.
    const src = try a.alloc(u8, 501);
    defer a.free(src);
    // A name first, because `(` cannot start a statement — that much is true
    // Lua, and it would hide the depth guard behind a different error.
    @memcpy(src[0..1], "f");
    for (src[1..500]) |*c| c.* = '(';
    src[500] = '1';
    var r = try parse(a, src);
    defer r.deinit(a);
    try testing.expect(r.diags.len > 0);
    try testing.expectEqual(Code.too_deep, r.diags[0].code);
}

test "calls record their path, their arguments and self" {
    const a = testing.allocator;
    const src =
        \\actor.set_position(self, 10, 20)
        \\v:clamp(1)
        \\print("hi", {})
    ;
    var r = try parseClean(src);
    defer r.deinit(a);
    try testing.expectEqual(@as(usize, 3), r.calls.len);

    try testing.expectEqualStrings("actor.set_position", Result.callPath(src, r.calls[0]));
    try testing.expectEqual(@as(u16, 3), r.calls[0].arg_count);
    try testing.expect(!r.calls[0].method);
    try testing.expectEqual(ArgKind.name, r.args[0].kind);

    try testing.expectEqualStrings("v:clamp", Result.callPath(src, r.calls[1]));
    try testing.expect(r.calls[1].method);
    try testing.expectEqual(@as(u16, 1), r.calls[1].arg_count);

    // The literal kinds are what the API checks read: a string and a table
    // among the last call's arguments.
    try testing.expectEqual(ArgKind.string, r.args[4].kind);
    try testing.expectEqual(ArgKind.table, r.args[5].kind);
}

test "symbols cover their whole declaration" {
    const a = testing.allocator;
    const src = "function M.wrap(a, b)\n    return a\nend";
    var r = try parseClean(src);
    defer r.deinit(a);
    // The two parameters, and then the function: the body is parsed before
    // there is an end offset to attach a whole-declaration span to.
    try testing.expectEqual(@as(usize, 3), r.symbols.len);
    var fun: ?Symbol = null;
    for (r.symbols) |sym| {
        if (sym.kind == .fun) fun = sym;
    }
    try testing.expect(fun != null);
    const f = fun.?;
    try testing.expectEqual(@as(u32, 0), f.start);
    try testing.expectEqual(@as(u32, src.len), f.start + f.len);
    try testing.expectEqualStrings("wrap", src[f.name_start .. f.name_start + f.name_len]);
    var params: usize = 0;
    for (r.symbols) |sym| {
        if (sym.kind == .param) params += 1;
    }
    try testing.expectEqual(@as(usize, 2), params);
}

test "locals are declared in the scope they are declared in" {
    const a = testing.allocator;
    const src = "local x = 1\nlocal function f(y)\n    return x + y\nend";
    var r = try parseClean(src);
    defer r.deinit(a);
    // reads: x (scope 0), x and y (body scope), plus the decl of the local
    // function, its name, and y itself.
    var reads: usize = 0;
    for (r.uses) |use| if (use.kind == .read) {
        reads += 1;
    };
    try testing.expectEqual(@as(usize, 2), reads);
    // The body scope is not the root, and its parent is.
    var body_scope: ?u32 = null;
    for (r.uses) |use| {
        if (use.kind == .decl and use.scope != 0) body_scope = use.scope;
    }
    try testing.expect(body_scope != null);
    // Walk out of the parameter's scope until the root: if a scope chain ever
    // fails to reach it, the reader for that name is answered by nobody.
    var walk = r.scopes[body_scope.?];
    var hops: usize = 0;
    while (walk.parent != no_scope) : (hops += 1) {
        if (hops > 32) break;
        walk = r.scopes[walk.parent];
    }
    try testing.expectEqual(no_scope, walk.parent);
}

test "garbage never loops or crashes" {
    const a = testing.allocator;
    const inputs = [_][]const u8{
        "end",              "end end end",     ")))",         "[[[[",
        "'abc",             "function f(",     "local local", "= = =",
        "{[(<",             "else then do",    "1 + 2 +",     "repeat until",
        "::",               "...",             "'\\",          "--[[",
        "goto",             "local x,",        "if if if",    "}}}}",
    };
    for (inputs) |src| {
        var r = try parse(a, src);
        defer r.deinit(a);
        try testing.expect(r.diags.len <= max_diags);
    }
}

test "the scanner delivers tokens the parser can name" {
    const a = testing.allocator;
    // `...` must not be split into `..` plus `.`: the two-char rule would take
    // the first two bytes and the third would become an index error.
    var r = try parseClean("local function f(...)\n    return ...\nend");
    defer r.deinit(a);
    try testing.expectEqual(@as(usize, 1), r.symbols.len);
}

test "a fold covers the block from its header to its end" {
    const a = testing.allocator;
    const src = "if x then\nprint(1)\nend";
    var r = try parseClean(src);
    defer r.deinit(a);
    try testing.expectEqual(@as(usize, 1), r.folds.len);
    try testing.expectEqual(@as(u32, 0), r.folds[0].start);
    try testing.expectEqual(@as(u32, src.len), r.folds[0].start + r.folds[0].len);
}

fn isAlphabetic(ch: u8) bool {
    return (ch >= 'a' and ch <= 'z') or (ch >= 'A' and ch <= 'Z');
}

fn isDigit(ch: u8) bool {
    return ch >= '0' and ch <= '9';
}

fn isHexDigit(ch: u8) bool {
    return isDigit(ch) or (ch | 0x20) >= 'a' and (ch | 0x20) <= 'f';
}

fn isIdentByte(ch: u8) bool {
    return isAlphabetic(ch) or isDigit(ch) or ch == '_';
}
