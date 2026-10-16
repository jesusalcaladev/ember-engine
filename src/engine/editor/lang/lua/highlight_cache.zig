//! `editor.lang.lua.highlight_cache` — tokenize once per document version.
//!
//! ## The problem this solves
//!
//! The highlighter is a pure function of the whole document: `lexer.tokenize`
//! walks the text start to end. Calling it on every rendered frame is the
//! difference between an editor that holds 60 fps on a file of a few thousand
//! lines and one that drops to single digits on a file of a hundred thousand —
//! and the cost is paid 60 times a second for a document that usually has not
//! changed since the last frame.
//!
//! So the spans are CACHED, keyed by a version number the caller owns. The
//! editor's `Buffer` bumps `version` on every mutation and never otherwise, so
//! "the text changed" is one integer compare instead of a hash of the file.
//!
//! ## Why not per line
//!
//! `lexer.tokenize`'s own comment says a caller may tokenize one line at a
//! time because the offsets are absolute. That is true only when no token
//! SPANS lines: `--[[ ... ]]` and `[[ ... ]]` do, and tokenizing from a line
//! that begins inside one colours the rest of the file as code. An incremental
//! highlighter therefore needs the lexer to carry state (are we inside a long
//! bracket?) across the resume point, which is a change to the lexer, not to
//! this file. Until that exists, correctness wins: one pass over the document
//! per EDIT, not per frame, is the honest and the fast answer.
//!
//! ## What it owns
//!
//! The span array, and nothing else. The text is borrowed for the duration of
//! the call — the caller keeps the text alive, which it must anyway, because
//! the spans are byte offsets INTO it. This is the same contract `CodeView`
//! takes: text in, offsets out, no copy.
//!
//! ## The allocation rule, stated
//!
//! `text` and `spans` do NOT allocate on the steady path: `clearRetainingCapacity`
//! keeps the token array's buffer across edits, so typing into a large file
//! reuses one allocation rather than growing a fresh one per keystroke. The
//! editor may allocate freely (it is the overlay, not the game frame), but it
//! must not allocate per frame for state that did not change — and here it
//! allocates per edit, into a buffer it already has.

const std = @import("std");
const lexer = @import("lexer.zig");

pub const Span = lexer.Span;
pub const Kind = lexer.Kind;

/// A tokenization of one document version. Holds no text.
pub const Cache = struct {
    allocator: std.mem.Allocator,
    tokens: std.ArrayListUnmanaged(Span) = .empty,
    /// The version the tokens were built from, or null before the first build.
    /// The version is the caller's — a `Buffer.version`, or any counter that
    /// changes exactly when the text does.
    version: ?u32 = null,
    /// How many times the lexer actually ran. Exposed so a test can prove the
    /// cache hit, and so a profile can see the edit rate directly instead of
    /// inferring it from frame time.
    builds: u64 = 0,

    pub fn init(allocator: std.mem.Allocator) Cache {
        return .{ .allocator = allocator };
    }

    pub fn deinit(self: *Cache) void {
        self.tokens.deinit(self.allocator);
    }

    /// The spans for `text` at `version`, re-tokenizing only when the version
    /// moved. The returned slice is owned by the cache and is valid until the
    /// next call with a different version.
    pub fn spans(self: *Cache, text: []const u8, version: u32) ![]const Span {
        if (self.version) |v| {
            if (v == version) return self.tokens.items;
        }
        self.tokens.clearRetainingCapacity();
        try lexer.tokenize(text, &self.tokens, self.allocator);
        self.version = version;
        self.builds += 1;
        return self.tokens.items;
    }

    /// Forgets the cached version so the next `spans` re-tokenizes even if the
    /// version number happens to match. Needed when the TEXT changed without
    /// the version moving — which a correct `Buffer` never does, and a caller
    /// that loaded a file some other way might.
    pub fn invalidate(self: *Cache) void {
        self.version = null;
    }
};

// ── Tests ────────────────────────────────────────────────────────────────

const testing = std.testing;

test "highlight cache: the same version does not re-tokenize" {
    var cache = Cache.init(testing.allocator);
    defer cache.deinit();

    const text = "local x = 1\nprint(x)\n";
    const first = try cache.spans(text, 7);
    try testing.expectEqual(@as(u64, 1), cache.builds);
    try testing.expect(first.len > 0);

    // A second call at the SAME version returns the cached slice: same length
    // AND same base pointer, which is the property "it did not rebuild" means.
    const again = try cache.spans(text, 7);
    try testing.expectEqual(@as(u64, 1), cache.builds);
    try testing.expectEqual(first.len, again.len);
    try testing.expectEqual(@intFromPtr(first.ptr), @intFromPtr(again.ptr));
}

test "highlight cache: a new version re-tokenizes" {
    var cache = Cache.init(testing.allocator);
    defer cache.deinit();

    _ = try cache.spans("local a = 1\n", 1);
    try testing.expectEqual(@as(u64, 1), cache.builds);
    _ = try cache.spans("local a = 12\n", 2);
    try testing.expectEqual(@as(u64, 2), cache.builds);
}

test "highlight cache: invalidate forces a rebuild at the same version" {
    var cache = Cache.init(testing.allocator);
    defer cache.deinit();

    _ = try cache.spans("x\n", 3);
    cache.invalidate();
    _ = try cache.spans("x\n", 3);
    try testing.expectEqual(@as(u64, 2), cache.builds);
}

test "highlight cache: the spans cover a multi-line long comment as one token" {
    // The case that makes per-line tokenization WRONG, and the reason the cache
    // keys on the whole document: a long comment spans lines, so its span must
    // too. If a future incremental rewrite breaks this, this test says so.
    var cache = Cache.init(testing.allocator);
    defer cache.deinit();

    const text = "--[[ line one\nline two\n]]\nlocal x = 1\n";
    const spans = try cache.spans(text, 1);
    // The whole `--[[ ... ]]` block, newlines included, is ONE comment run: it
    // starts at 0 and is exactly the 25 bytes up to and including `]]`.
    try testing.expectEqual(@as(u32, 0), spans[0].start);
    try testing.expectEqual(Kind.comment, spans[0].kind);
    try testing.expectEqualStrings("--[[ line one\nline two\n]]", text[spans[0].start .. spans[0].start + spans[0].len]);
    var comment_len: u32 = 0;
    for (spans) |s| {
        if (s.kind == .comment) comment_len += s.len;
    }
    try testing.expectEqual(@as(u32, 25), comment_len);
}

test "highlight cache: hundreds of lines tokenize into sorted, non-overlapping spans" {
    // A cheap correctness check at a size where a per-frame re-tokenize would
    // start to matter: the spans must still be ordered and disjoint, which is
    // the invariant `CodeView`'s single advancing cursor relies on.
    const allocator = testing.allocator;
    var text: std.ArrayListUnmanaged(u8) = .empty;
    defer text.deinit(allocator);
    var line: usize = 0;
    while (line < 2000) : (line += 1) {
        var line_buf: [64]u8 = undefined;
        const s = try std.fmt.bufPrint(&line_buf, "local value_{d} = math.floor(12.5) -- a comment\n", .{line});
        try text.appendSlice(allocator, s);
    }

    var cache = Cache.init(allocator);
    defer cache.deinit();
    const spans = try cache.spans(text.items, 1);
    try testing.expect(spans.len > 2000);

    var prev_end: u32 = 0;
    for (spans) |s| {
        try testing.expect(s.start >= prev_end);
        prev_end = s.start + s.len;
    }
    try testing.expectEqual(@as(u32, @intCast(text.items.len)), prev_end);
}
