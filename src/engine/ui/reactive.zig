//! `ui.reactive` — the "React" part of the framework, for an immediate-mode UI.
//!
//! ## The problem this solves
//!
//! Dear ImGui is immediate mode: a frame is a function call tree, and nothing
//! survives it unless it is stored somewhere. That is a fine model for a game
//! HUD and a bad one for a tool, because a tool is mostly STATE: which panel is
//! open, what is selected, what was typed and not yet committed, which tab,
//! how far a tree has been expanded.
//!
//! The two obvious answers are both bad. Global mutable variables spread state
//! across every widget and make the "who changed this" question unanswerable.
//! A retained-mode scene graph re-implements React badly, in a language with
//! no compiler support for the cycle, and every panel then owns its lifetime.
//!
//! ## What this is instead
//!
//! The one idea that makes immediate mode work for tools:
//!
//! > **A component is a pure function of (props, stored state). It is called
//! > again every frame, and the only thing that makes it cheap or stable is
//! > that its state is ADDRESSED, not captured.**
//!
//! So state lives in a `Store` keyed by a path string, and the key is written
//! at the call site:
//!
//! ```zig
//! var open = store.bool("panels/inspector/open", true);
//! ui.Collapse(.{ .id = "panels/inspector", .open = &open }, InspectorBody);
//! ```
//!
//! `InspectorBody` is a plain `fn(Props) void`. It can be read top to bottom,
//! diffed, moved to another file, or replaced, and the state still lands in the
//! same place — because the place is a string in the source, not an address in
//! the heap. That is the entire trick, and it is the same trick React uses with
//! hooks: the identity of a piece of state is its POSITION in the tree, not its
//! address.
//!
//! ## The three rules, which are the contract
//!
//! 1. **A widget function never stores anything in a global.** It reads props
//!    and returns; if it needs to remember, the caller owns the variable.
//! 2. **A key is a path, written in full, at the call site.** Not a hash of the
//!    label, not an index. `inspector/transform/x` can be found in the source
//!    with grep, and when two panels both want a "search" field they do not
//!    collide.
//! 3. **A `Signal` is the only way to cause a side effect, and it fires from
//!    the frame in which the value changed.** No "dirty" flags, no
//!    setTimeout, no effect cleanup to forget.

const std = @import("std");

/// A value in the store. Small, copyable, no heap per value.
///
/// A tagged union rather than `anyopaque` on purpose: the alternative is a
/// JSON-ish blob, and then "the inspector wrote a number where a string was
/// expected" is a runtime surprise instead of a compile error.
pub const Value = union(enum) {
    bool: bool,
    int: i64,
    float: f32,
    /// A NUL-terminated string, stored inline. 256 bytes covers a path, a
    /// search term, a node name and a hex colour; anything longer belongs in
    /// the document, not in UI state.
    text: struct { buf: [256]u8 = undefined, len: u16 = 0 },
    /// An opaque handle for "the thing that is selected", so a panel can share
    /// a selection without knowing what it is.
    handle: usize,
    void_: void,
};

/// The maximum key length. A key is a source-level path, and source-level paths
/// are short; a longer one is a mistake that should be visible, not a silent
/// truncation that makes two panels share a variable.
pub const max_key_len = 128;

const Entry = struct {
    value: Value = .{ .void_ = {} },
    /// Bumped on every write. `memo` uses it to decide whether a cached
    /// computation is still valid, which is cheaper than hashing the inputs.
    revision: u64 = 0,
    /// The last input hash `memo` saw for this key.
    memo_hash: u64 = 0,
    /// Whether `memo_hash` was ever written. Separate from `revision` because a
    /// memo that has never run is not invalid, it is ABSENT, and treating those
    /// the same produces a cache that returns nothing on the first frame and
    /// something on the second — the worst of both.
    memo_valid: bool = false,
};

/// Persistent UI state, addressed by path.
pub const Store = struct {
    allocator: std.mem.Allocator,
    entries: std.StringHashMapUnmanaged(Entry) = .{},

    pub fn init(allocator: std.mem.Allocator) Store {
        return .{ .allocator = allocator };
    }

    pub fn deinit(self: *Store) void {
        var it = self.entries.keyIterator();
        while (it.next()) |k| self.allocator.free(k.*);
        self.entries.deinit(self.allocator);
    }

    fn key(self: *Store, path: []const u8) ![]u8 {
        if (path.len >= max_key_len) return error.KeyTooLong;
        return self.allocator.dupe(u8, path);
    }

    fn slot(self: *Store, path: []const u8) !*Entry {
        if (self.entries.getPtr(path)) |e| return e;
        const owned = try self.key(path);
        // `getOrPut` does NOT initialise the value on a miss: the slot is
        // whatever was in the memory, and the next read switches on it. The
        // value is written HERE, before anybody can see the pointer, which is
        // the only place the entry is "not yet valid" — a window that does not
        // exist if `get` always goes through this function.
        const gop = try self.entries.getOrPut(self.allocator, owned);
        if (gop.found_existing) {
            // A key that is already here was duplicated by `owned`, so it has
            // to go back: the map owns the copy it returned when it was created,
            // and this one is ours.
            self.allocator.free(owned);
            return gop.value_ptr;
        }
        gop.value_ptr.* = .{ .value = .{ .void_ = {} } };
        return gop.value_ptr;
    }

    pub fn has(self: *const Store, path: []const u8) bool {
        return self.entries.contains(path);
    }

    /// Reads with a default, creating the entry if it is not there. This is
    /// `useState`'s lazy initialiser: the default runs once, not every frame,
    /// which matters when the default is something like `rowCount()`.
    pub fn get(self: *Store, path: []const u8, comptime T: type, default: T) !T {
        const e = try self.slot(path);
        if (e.value == .void_) {
            e.value = fromDefault(T, default) orelse return error.BadDefault;
        }
        return toTyped(T, e.value);
    }

    pub fn set(self: *Store, path: []const u8, comptime T: type, v: T) !void {
        const e = try self.slot(path);
        e.value = fromTyped(T, v) orelse return error.BadValue;
        e.revision += 1;
    }

    /// `get` + `set` in one call, which is what every text field wants and
    /// what makes the "commit on change" behaviour impossible to forget.
    pub fn edit(self: *Store, path: []const u8, comptime T: type, default: T, v: *T) !void {
        if (self.has(path)) {
            const stored = try self.get(path, T, default);
            if (!eql(T, stored, v.*)) try self.set(path, T, v.*);
        } else {
            try self.set(path, T, v.*);
        }
    }

    /// Removes a subtree's worth of keys: everything under `prefix/`.
    ///
    /// Used when a scene closes or an actor is destroyed, and the reason a
    /// long-lived editor does not grow a megabyte of remembered panel scroll
    /// positions for scenes that no longer exist.
    pub fn forgetSubtree(self: *Store, prefix: []const u8) void {
        var full_buf: [max_key_len]u8 = undefined;
        if (prefix.len + 1 > full_buf.len) return;
        @memcpy(full_buf[0..prefix.len], prefix);
        full_buf[prefix.len] = '/';
        const full = full_buf[0 .. prefix.len + 1];

        // The keys go into `doomed` as the MAP's own allocations: `remove` gives
        // them back, and they are freed here. Duplicating them into the list
        // instead (which the first version did) leaks one copy per key, because
        // the map's copy is removed but never freed.
        var doomed: std.ArrayListUnmanaged([]const u8) = .empty;
        defer doomed.deinit(self.allocator);
        var it = self.entries.keyIterator();
        while (it.next()) |k| {
            if (std.mem.startsWith(u8, k.*, full)) {
                doomed.append(self.allocator, k.*) catch {};
            }
        }
        for (doomed.items) |k| {
            if (self.entries.fetchRemove(k)) |removed| {
                self.allocator.free(removed.key);
            }
        }
    }

    pub fn count(self: *const Store) usize {
        return self.entries.count();
    }

    /// The revision of a key, 0 when absent. Exposed so `memo` and `Signal`
    /// can be built on the same primitive instead of each inventing one.
    pub fn revision(self: *const Store, path: []const u8) u64 {
        const e = self.entries.get(path) orelse return 0;
        return e.revision;
    }

    fn toTyped(comptime T: type, v: Value) !T {
        // A `switch (v)` per type, not a cast: a `T` that does not match the
        // stored tag is a bug the caller made, and "get returns a default it
        // silently invented" is worse than "get returns WrongType", which is
        // what this does when it happens.
        return switch (T) {
            bool => switch (v) {
                .bool => |b| b,
                else => error.WrongType,
            },
            i64, i32 => switch (v) {
                .int => |i| @intCast(i),
                else => error.WrongType,
            },
            f32 => switch (v) {
                .float => |f| f,
                else => error.WrongType,
            },
            f64 => switch (v) {
                .float => |f| @floatCast(f),
                else => error.WrongType,
            },
            usize => switch (v) {
                .handle => |h| h,
                else => error.WrongType,
            },
            []const u8 => switch (v) {
                .text => |t| t.buf[0..t.len],
                else => error.WrongType,
            },
            else => @compileError("ui.reactive.Store does not hold " ++ @typeName(T)),
        };
    }

    fn fromDefault(comptime T: type, d: T) ?Value {
        if (T == bool) return .{ .bool = d };
        if (T == i64 or T == i32) return .{ .int = d };
        if (T == f32 or T == f64) return .{ .float = @floatCast(d) };
        if (T == usize) return .{ .handle = d };
        if (T == []const u8) return text(d);
        return null;
    }

    fn fromTyped(comptime T: type, v: T) ?Value {
        if (T == bool) return .{ .bool = v };
        if (T == i64 or T == i32) return .{ .int = v };
        if (T == f32 or T == f64) return .{ .float = @floatCast(v) };
        if (T == usize) return .{ .handle = v };
        if (T == []const u8) return text(v);
        return null;
    }

    fn text(s: []const u8) ?Value {
        if (s.len > 255) return null;
        var t: Value = .{ .text = .{ .len = @intCast(s.len) } };
        @memcpy(t.text.buf[0..s.len], s);
        return t;
    }

    fn eql(comptime T: type, a: T, b: T) bool {
        if (T == []const u8) return std.mem.eql(u8, a, b);
        if (T == f32 or T == f64) return @abs(a - b) < 0.0001;
        return a == b;
    }
};

/// Convenience readers, so the call site is `store.bool(path, true)` rather
/// than `try store.get(path, bool, true)` with a `!` in a draw function.
pub fn getBool(s: *Store, path: []const u8, default: bool) bool {
    return s.get(path, bool, default) catch default;
}
pub fn getInt(s: *Store, path: []const u8, default: i64) i64 {
    return s.get(path, i64, default) catch default;
}
pub fn getFloat(s: *Store, path: []const u8, default: f32) f32 {
    return s.get(path, f32, default) catch default;
}
pub fn getHandle(s: *Store, path: []const u8, default: usize) usize {
    return s.get(path, usize, default) catch default;
}

/// A mutable handle into the store, for the widgets that own a value.
pub const BoolRef = struct {
    store: *Store,
    path: []const u8,
    default: bool,

    pub fn value(self: *const BoolRef) bool {
        return getBool(self.store, self.path, self.default);
    }
    pub fn set(self: *const BoolRef, v: bool) void {
        self.store.set(self.path, bool, v) catch {};
    }
    /// Returns true when the value actually CHANGED.
    ///
    /// A value comparison, not a revision comparison: a write of the value it
    /// already holds still bumps the revision (the store has no way to know it
    /// is a no-op without comparing), and "changed" to a caller means what it
    /// says. Comparing revisions here is how a panel ends up re-uploading a
    /// 50k-sprite scene every frame.
    pub fn update(self: *const BoolRef, v: bool) bool {
        const before = self.value();
        self.set(v);
        return before != v;
    }
    fn revision(self: *const BoolRef) u64 {
        return self.store.revision(self.path);
    }
};

pub fn refBool(store: *Store, path: []const u8, default: bool) BoolRef {
    return .{ .store = store, .path = path, .default = default };
}

// ── Signals ──────────────────────────────────────────────────────────────

/// What a listener gets: the key that changed, and the frame it changed in.
///
/// Not "old and new values": the values are already in the store, and passing
/// them means two sources of truth — the classic way a signal ends up firing
/// with a value that does not match what the store holds.
pub const Change = struct {
    key: []const u8,
    revision: u64,
};

const Listener = struct {
    id: u32,
    callback: *const fn (ctx: ?*anyopaque, change: Change) void,
    ctx: ?*anyopaque,
};

/// A subscription list. The engine's own signals (see `ecs/signals.zig`) have
/// the same shape and the same rule: drained once per frame, in a stable order.
pub const Signal = struct {
    listeners: std.ArrayListUnmanaged(Listener) = .empty,
    allocator: std.mem.Allocator,
    /// Everything that fired since the last `drain`, so a listener that is
    /// added mid-frame does not miss the change that woke it.
    pending: std.ArrayListUnmanaged(Change) = .empty,

    pub fn init(allocator: std.mem.Allocator) Signal {
        return .{ .allocator = allocator };
    }

    pub fn deinit(self: *Signal) void {
        self.listeners.deinit(self.allocator);
        self.pending.deinit(self.allocator);
    }

    pub fn on(
        self: *Signal,
        id: u32,
        ctx: ?*anyopaque,
        callback: *const fn (ctx: ?*anyopaque, change: Change) void,
    ) !void {
        try self.listeners.append(self.allocator, .{ .id = id, .ctx = ctx, .callback = callback });
    }

    pub fn off(self: *Signal, id: u32) void {
        var i: usize = 0;
        while (i < self.listeners.items.len) {
            if (self.listeners.items[i].id == id) {
                _ = self.listeners.orderedRemove(i);
                continue;
            }
            i += 1;
        }
    }

    /// Queues a change. NOT fired immediately: a listener that mutates the
    /// store while the store is being written is a re-entrancy bug that only
    /// shows up under load.
    pub fn emit(self: *Signal, key: []const u8, revision: u64) void {
        self.pending.append(self.allocator, .{ .key = key, .revision = revision }) catch {};
    }

    /// Fires everything queued, then clears the queue. One call per frame, at
    /// a point the owner chooses — normally after the whole UI has drawn,
    /// because a listener that opens a popup during the draw phase is opening
    /// a popup into a frame that already ended.
    pub fn drain(self: *Signal) void {
        if (self.pending.items.len == 0) return;
        var i: usize = 0;
        while (i < self.pending.items.len) : (i += 1) {
            const change = self.pending.items[i];
            for (self.listeners.items) |l| l.callback(l.ctx, change);
        }
        self.pending.clearRetainingCapacity();
    }

    pub fn pendingCount(self: *const Signal) usize {
        return self.pending.items.len;
    }
};

// ── memo ─────────────────────────────────────────────────────────────────

/// Caches one value per key and recomputes it only when the inputs change.
///
/// Not premature: this is the "React" part that pays for itself. A panel that
/// walks 500 actors to build a filtered list, or an inspector that formats
/// 200 float values, should not do that work at 60 Hz to draw the same result.
/// The cache key is the path and the input hash, and both are written at the
/// call site, so a stale cache is a bug in the caller's hash and not a mystery.
pub fn memo(
    store: *Store,
    path: []const u8,
    input_hash: u64,
    comptime T: type,
    compute: fn () T,
) T {
    const e = store.slot(path) catch return compute();
    if (e.memo_valid and e.memo_hash == input_hash) {
        return Store.toTyped(T, e.value) catch compute();
    }
    const v = compute();
    e.value = Store.fromTyped(T, v) orelse e.value;
    e.memo_hash = input_hash;
    e.memo_valid = true;
    return v;
}

/// A 64-bit hash, for the `input_hash` above. FNV-1a: tiny, no allocation,
/// and no dependency on a hashing library whose defaults change.
pub fn hash(seed: u64, bytes: []const u8) u64 {
    var h: u64 = if (seed == 0) 0xcbf29ce484222325 else seed;
    for (bytes) |b| {
        h ^= b;
        h *%= 0x100000001b3;
    }
    return h;
}

pub fn hashInt(seed: u64, v: anytype) u64 {
    var buf: [8]u8 = undefined;
    std.mem.writeInt(u64, &buf, @bitCast(v), .little);
    return hash(seed, &buf);
}

pub fn hashFloat(seed: u64, v: f32) u64 {
    return hashInt(seed, @as(u32, @bitCast(v)));
}

pub fn hashBool(seed: u64, v: bool) u64 {
    return hashInt(seed, @as(u8, @intFromBool(v)));
}

// ── Tests ────────────────────────────────────────────────────────────────

const testing = std.testing;

test "ui reactive: a value read twice is the same value" {
    var s = Store.init(testing.allocator);
    defer s.deinit();

    try testing.expectEqual(@as(bool, true), try s.get("panels/inspector/open", bool, true));
    s.set("panels/inspector/open", bool, false) catch {};
    try testing.expectEqual(@as(bool, false), try s.get("panels/inspector/open", bool, true));
    // The default must NOT come back: that is the difference between a store
    // and a local variable.
    try testing.expectEqual(@as(bool, false), getBool(&s, "panels/inspector/open", true));
}

test "ui reactive: a default is only used when the key is absent" {
    // The default is CONSTRUCTED on every `get` (the caller owns it), but the
    // store only STORES it the first time. The value that comes back is the
    // first default, and a different default afterwards does not win — which
    // is the `useState` behaviour, and the only one that makes a control
    // remember what the user did to it.
    var s = Store.init(testing.allocator);
    defer s.deinit();
    try testing.expectEqual(@as(bool, true), try s.get("x", bool, true));
    // A LATER default does not overwrite the stored value.
    try testing.expectEqual(@as(bool, true), try s.get("x", bool, false));
    // And a `set` moves it, as it must.
    s.set("x", bool, false) catch {};
    try testing.expectEqual(@as(bool, false), try s.get("x", bool, true));
}

test "ui reactive: two panels with the same label do not collide" {
    // The failure this prevents: two search fields both keyed "search", so
    // typing in one filters the other.
    var s = Store.init(testing.allocator);
    defer s.deinit();
    s.set("assets/search", []const u8, "sprite") catch {};
    s.set("hierarchy/search", []const u8, "player") catch {};
    try testing.expectEqualStrings("sprite", try s.get("assets/search", []const u8, ""));
    try testing.expectEqualStrings("player", try s.get("hierarchy/search", []const u8, ""));
}

test "ui reactive: a revision changes only on a write" {
    var s = Store.init(testing.allocator);
    defer s.deinit();
    const r0 = s.revision("a");
    s.set("a", i64, 1) catch {};
    const r1 = s.revision("a");
    s.set("a", i64, 1) catch {}; // same value: still a write
    const r2 = s.revision("a");
    try testing.expectEqual(@as(u64, 0), r0);
    try testing.expect(r1 > 0);
    try testing.expectEqual(r1 + 1, r2);
}

test "ui reactive: update reports only real changes" {
    var s = Store.init(testing.allocator);
    defer s.deinit();
    const b = refBool(&s, "tool/snap", false);
    try testing.expect(b.update(true));
    try testing.expect(!b.update(true)); // the frame nobody is watching for
    try testing.expect(b.value());
}

test "ui reactive: forgetting a subtree forgets only that subtree" {
    var s = Store.init(testing.allocator);
    defer s.deinit();
    s.set("scene1/inspector/tab", i64, 0) catch {};
    s.set("scene1/hierarchy/sel", i64, 7) catch {};
    s.set("scene2/inspector/tab", i64, 1) catch {};
    try testing.expectEqual(@as(usize, 3), s.count());
    s.forgetSubtree("scene1");
    try testing.expectEqual(@as(usize, 1), s.count());
    try testing.expect(!s.has("scene1/inspector/tab"));
    try testing.expect(s.has("scene2/inspector/tab"));
}

test "ui reactive: a signal fires in the frame it was emitted" {
    var s = Signal.init(testing.allocator);
    defer s.deinit();
    const Seen = struct {
        count: usize = 0,
        last: Change = .{ .key = "", .revision = 0 },
        fn cb(ctx: ?*anyopaque, change: Change) void {
            const self: *@This() = @ptrCast(@alignCast(ctx.?));
            self.count += 1;
            self.last = change;
        }
    };
    var seen: Seen = .{};
    try s.on(1, &seen, Seen.cb);

    s.emit("panels/inspector/open", 3);
    // Not yet: a listener that draws would be drawing into a frame that has
    // already been submitted.
    try testing.expectEqual(@as(usize, 0), seen.count);
    s.drain();
    try testing.expectEqual(@as(usize, 1), seen.count);
    try testing.expectEqualStrings("panels/inspector/open", seen.last.key);
    // And the queue is empty, so a second drain does not double-fire.
    s.drain();
    try testing.expectEqual(@as(usize, 1), seen.count);
}

test "ui reactive: memo recomputes only when an input changes" {
    var s = Store.init(testing.allocator);
    defer s.deinit();
    // A struct with one static, because a memo's `compute` is a plain
    // `fn () T`: it takes no arguments, so it cannot capture a counter. The
    // counter therefore has to be context-free state, which is also what the
    // framework would do in a real component — the memo's INPUT carries the
    // change, not a closure.
    const Counter = struct {
        var calls: usize = 0;
        fn compute() usize {
            calls += 1;
            return calls * 10;
        }
    };

    const a = memo(&s, "panel/list", 0, usize, Counter.compute);
    try testing.expectEqual(@as(usize, 1), Counter.calls);
    const b = memo(&s, "panel/list", 0, usize, Counter.compute);
    try testing.expectEqual(a, b);
    try testing.expectEqual(@as(usize, 1), Counter.calls); // cached

    const d = memo(&s, "panel/list", 99, usize, Counter.compute);
    try testing.expectEqual(@as(usize, 2), Counter.calls);
    try testing.expectEqual(@as(usize, 20), d);
}

test "ui reactive: the hash is stable and order-dependent" {
    try testing.expectEqual(hash(0, "abc"), hash(0, "abc"));
    try testing.expect(hash(0, "abc") != hash(0, "abd"));
    try testing.expect(hash(0, "ab") != hash(0, "ba"));
    // A different seed is a different hash: two memo paths cannot collide
    // because the caller folds the path in.
    try testing.expect(hash(1, "abc") != hash(0, "abc"));
}
