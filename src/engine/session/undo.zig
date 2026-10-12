//! Undo/redo: one act, one entry.
//!
//! The roadmap asks for undo/redo "on top of serialization", and this is that:
//! a command knows how to apply itself and how to reverse itself, and the stack
//! holds the sequence. The commands themselves are the session's business — what
//! "set the position of entity 12" means — and this module holds nothing about
//! entities, components or worlds, which is what lets it be tested without a
//! running engine and reused by anything else that edits.
//!
//! ## What makes it more than a list
//!
//! Three properties, each of which is the difference between an undo that feels
//! right and one that does not:
//!
//! 1. **An act is one entry.** Dragging a slider, typing a word, moving an
//!    actor: those are acts, not edits. A command that reports a *coalesce key*
//!    merges with the previous act of the same key instead of stacking, so
//!    typing "physics" costs one undo rather than seven — and only while the
//!    key matches, which is why moving the caret and coming back breaks the run.
//! 2. **Redo dies on a new act.** A stack that redoes after a new edit is
//!    replaying a sequence that no longer exists, and the user sees the world
//!    go somewhere they did not ask it to.
//! 3. **History is bounded.** A long editing session must not grow without
//!    limit; the oldest act is dropped, and the act beyond it is simply gone —
//!    a documented cost of the bound, not a bug.
//!
//! ## What it does not own
//!
//! The command's context, its label text and any bytes it captures. The caller
//! allocates those and they must outlive the act: a stack that frees a label it
//! did not allocate is a stack that hands back a dangling string.

const std = @import("std");

pub const Error = error{OutOfMemory};

/// One act. Generic over the context so the caller gets a typed context rather
/// than an `anyopaque` it has to cast — a cast in an undo path is a bug nobody
/// finds until an edit is reversed in the wrong object.
pub fn Command(comptime Ctx: type) type {
    return struct {
        const Self = @This();

        /// For the UI: "Undo Move Actor".
        label: []const u8,
        ctx: *Ctx,
        applyFn: *const fn (*Ctx) Error!void,
        revertFn: *const fn (*Ctx) Error!void,
        /// When it returns a non-null key, `push` merges this command into the
        /// previous act of the same key. Null means "never merge".
        coalesceFn: ?*const fn (*Ctx) ?[]const u8 = null,

        fn apply(c: Self) Error!void {
            return c.applyFn(c.ctx);
        }

        fn revert(c: Self) Error!void {
            return c.revertFn(c.ctx);
        }

        fn key(c: Self) ?[]const u8 {
            const f = c.coalesceFn orelse return null;
            return f(c.ctx);
        }
    };
}

pub fn UndoStack(comptime Ctx: type) type {
    return struct {
        const Self = @This();
        const Cmd = Command(Ctx);

        /// A stacked entry. A merged run keeps the FIRST revert — undoing a typing
        /// run has to return to before the run started, not to before the last
        /// keystroke — and the LAST label, because that is the one describing
        /// what the run became.
        const Act = struct {
            cmd: Cmd,
            label: []const u8,
            coalesce_key: ?[]const u8,
        };

        acts: std.ArrayListUnmanaged(Act) = .empty,
        /// Index of the next act to apply. Everything at or after it is redo.
        at: usize = 0,
        /// The bound. 256 acts is a deep history and a bounded one; the act
        /// beyond it is gone, which is the documented price of the bound.
        max: usize = 256,

        pub fn init() Self {
            return .{};
        }

        pub fn deinit(self: *Self, allocator: std.mem.Allocator) void {
            self.acts.deinit(allocator);
            self.at = 0;
        }

        pub fn canUndo(self: *const Self) bool {
            return self.at > 0;
        }

        pub fn canRedo(self: *const Self) bool {
            return self.at < self.acts.items.len;
        }

        pub fn depth(self: *const Self) usize {
            return self.at;
        }

        /// Pushes an act, applying it. A new act discards any redo.
        ///
        /// The command is stored BY VALUE: the context it points at is the
        /// caller's, and so is the label text, and both must outlive the act.
        pub fn push(self: *Self, allocator: std.mem.Allocator, cmd: Cmd) Error!void {
            return self.record(allocator, cmd, true);
        }

        /// Pushes an act the caller has ALREADY applied, which is the shape of a
        /// creation: it produced a result (the handle of what it made) the caller
        /// needs in order to say what reversing it means. Redo and undo behave
        /// exactly as they do for a pushed act.
        pub fn pushApplied(self: *Self, allocator: std.mem.Allocator, cmd: Cmd) Error!void {
            return self.record(allocator, cmd, false);
        }

        /// The one place an act is recorded. `do_apply` is what separates the two
        /// entry points above: a pushed act is applied here, an already-applied
        /// one is not, and applying twice would double every edit in a coalescing
        /// run — which is a bug this function's shape exists to make impossible.
        fn record(self: *Self, allocator: std.mem.Allocator, cmd: Cmd, do_apply: bool) Error!void {
            const k = cmd.key();

            // A run continues: the same coalesce key as the act just done.
            if (self.at > 0) {
                const top = &self.acts.items[self.at - 1];
                if (top.coalesce_key != null and k != null and std.mem.eql(u8, top.coalesce_key.?, k.?)) {
                    if (do_apply) try cmd.apply();
                    // The label becomes the new one — it describes what the run
                    // has turned into — but the COMMAND is left alone, and that
                    // is the whole point: its revert returns to before the run
                    // started, not to before the last edit inside it.
                    top.label = cmd.label;
                    return;
                }
            }

            if (do_apply) try cmd.apply();
            // Redo is a sequence that no longer exists once something new is
            // done. Truncating here is the only place that decision is made.
            self.acts.shrinkRetainingCapacity(self.at);
            try self.acts.append(allocator, .{ .cmd = cmd, .label = cmd.label, .coalesce_key = k });
            self.at += 1;
            self.trim(allocator);
        }

        pub fn undoLabel(self: *const Self) ?[]const u8 {
            if (!self.canUndo()) return null;
            return self.acts.items[self.at - 1].label;
        }

        pub fn redoLabel(self: *const Self) ?[]const u8 {
            if (!self.canRedo()) return null;
            return self.acts.items[self.at].label;
        }

        /// Reverses the last act and returns its label.
        pub fn undo(self: *Self) ?[]const u8 {
            if (!self.canUndo()) return null;
            self.at -= 1;
            const act = self.acts.items[self.at];
            // The revert must not fail in a way the caller cannot see, and the
            // only error the interface allows is memory: put the act back where
            // it was rather than silently dropping history the user believes in.
            act.cmd.revert() catch {
                self.at += 1;
                return null;
            };
            return act.label;
        }

        /// Re-applies the act after the one last undone.
        pub fn redo(self: *Self) ?[]const u8 {
            if (!self.canRedo()) return null;
            const act = self.acts.items[self.at];
            act.cmd.apply() catch return null;
            self.at += 1;
            return act.label;
        }

        pub fn clear(self: *Self, allocator: std.mem.Allocator) void {
            self.acts.clearRetainingCapacity();
            self.at = 0;
            _ = allocator;
        }

        /// Drops the oldest acts past the bound, keeping `at` consistent.
        fn trim(self: *Self, allocator: std.mem.Allocator) void {
            if (self.acts.items.len <= self.max) return;
            const extra = self.acts.items.len - self.max;
            // The acts kept are the last `max`, so the boundary moves back
            // without touching the act the user is standing on.
            std.mem.copyForwards(Act, self.acts.items[0 .. self.acts.items.len - extra], self.acts.items[extra..]);
            self.acts.shrinkRetainingCapacity(self.acts.items.len - extra);
            if (self.at > self.acts.items.len) self.at = self.acts.items.len;
            _ = allocator;
        }
    };
}

// ─── Tests ───────────────────────────────────────────────────────────────────

const testing = std.testing;

/// A value with one act on it: "set it to `new`, remembering what it was". The
/// old value is captured when the command is BUILT, which is what makes the
/// revert absolute — the shape a coalescing run needs.
const Ledger = struct {
    value: i32 = 0,
    applies: usize = 0,
    reverts: usize = 0,
};

const Set = struct {
    ledger: *Ledger,
    old: i32,
    new: i32,
    /// Non-null is what makes this command a candidate for a run.
    run: ?[]const u8 = null,

    fn apply(s: *Set) Error!void {
        s.ledger.value = s.new;
        s.ledger.applies += 1;
    }

    fn revert(s: *Set) Error!void {
        s.ledger.value = s.old;
        s.ledger.reverts += 1;
    }

    fn key(s: *Set) ?[]const u8 {
        return s.run;
    }
};

const Stack = UndoStack(Set);

/// One set command, carrying the value to return to.
fn set(ledger: *Ledger, cmd: *Set, target: i32, label: []const u8) Stack.Cmd {
    cmd.* = .{ .ledger = ledger, .old = ledger.value, .new = target };
    return .{
        .label = label,
        .ctx = cmd,
        .applyFn = Set.apply,
        .revertFn = Set.revert,
        .coalesceFn = Set.key,
    };
}

/// The same command with a run key, which is how keystrokes in one word arrive.
fn typed(ledger: *Ledger, cmd: *Set, target: i32, label: []const u8) Stack.Cmd {
    const c = set(ledger, cmd, target, label);
    cmd.run = "word";
    return c;
}

test "apply, undo and redo put the world back" {
    const a = testing.allocator;
    var ledger = Ledger{};
    var s = Stack.init();
    defer s.deinit(a);

    var cmd: Set = undefined;
    try s.push(a, set(&ledger, &cmd, 1, "set"));
    try testing.expectEqual(@as(i32, 1), ledger.value);
    try testing.expectEqualStrings("set", s.undo().?);
    try testing.expectEqual(@as(i32, 0), ledger.value);
    try testing.expectEqualStrings("set", s.redo().?);
    try testing.expectEqual(@as(i32, 1), ledger.value);
    // Nothing after that: two undos, and the third is nothing at all.
    try testing.expect(s.undo() != null);
    try testing.expect(s.undo() == null);
    try testing.expect(!s.canUndo());
    // And the undone act is still redoable, which is the other half of the pair:
    // an undo that destroyed history would be a history that only goes back.
    try testing.expect(s.canRedo());
    try testing.expectEqualStrings("set", s.redo().?);
}

test "a new act discards the redo" {
    const a = testing.allocator;
    var ledger = Ledger{};
    var s = Stack.init();
    defer s.deinit(a);

    var one: Set = undefined;
    var two: Set = undefined;
    try s.push(a, set(&ledger, &one, 1, "one"));
    _ = s.undo();
    try s.push(a, set(&ledger, &two, 9, "two"));
    // The undone act is gone: redo has nothing to replay, and replaying a
    // sequence that no longer exists is how the world goes somewhere the user
    // did not ask it to.
    try testing.expect(!s.canRedo());
    try testing.expectEqual(@as(i32, 9), ledger.value);
    try testing.expectEqual(@as(usize, 1), s.depth());
}

test "a coalesced run is one act" {
    const a = testing.allocator;
    var ledger = Ledger{};
    var s = Stack.init();
    defer s.deinit(a);

    // Seven keystrokes, each capturing the value the run STARTED from, and each
    // with its own context: the stack copies the command, not what it points
    // at, so a run that shares one context would revert to wherever that
    // context was last left.
    var runs: [7]Set = undefined;
    var i: usize = 0;
    while (i < 7) : (i += 1) {
        try s.push(a, typed(&ledger, &runs[i], @intCast(i + 1), "type"));
        try testing.expectEqual(@as(usize, 1), s.depth());
    }
    try testing.expectEqual(@as(i32, 7), ledger.value);
    // Seven applies, and one revert for the whole run.
    try testing.expectEqual(@as(usize, 7), ledger.applies);
    try testing.expectEqual(@as(usize, 0), ledger.reverts);

    _ = s.undo();
    try testing.expectEqual(@as(i32, 0), ledger.value);
    try testing.expectEqual(@as(usize, 1), ledger.reverts);
}

test "a different key breaks the run" {
    const a = testing.allocator;
    var ledger = Ledger{};
    var s = Stack.init();
    defer s.deinit(a);

    var type_cmd: Set = undefined;
    var move_cmd: Set = undefined;
    try s.push(a, typed(&ledger, &type_cmd, 1, "type"));
    try s.push(a, set(&ledger, &move_cmd, 2, "move"));
    try testing.expectEqual(@as(usize, 2), s.depth());

    // Two undos now: the run is one act, and the move is another.
    try testing.expectEqualStrings("move", s.undo().?);
    try testing.expectEqual(@as(i32, 1), ledger.value);
    try testing.expectEqualStrings("type", s.undo().?);
    try testing.expectEqual(@as(i32, 0), ledger.value);
}

test "history is bounded" {
    const a = testing.allocator;
    var ledger = Ledger{};
    var s = Stack.init();
    defer s.deinit(a);
    s.max = 4;

    // Each command carries its own context, so they cannot share one struct:
    // the stack stores what it is handed, by value, for as long as the act
    // lives.
    var cmds: [10]Set = undefined;
    var i: usize = 0;
    while (i < 10) : (i += 1) {
        cmds[i] = undefined;
        try s.push(a, set(&ledger, &cmds[i], @intCast(i + 1), "set"));
    }
    try testing.expectEqual(@as(usize, 4), s.depth());
    try testing.expectEqual(@as(usize, 4), s.acts.items.len);
    try testing.expectEqual(@as(i32, 10), ledger.value);

    // Undoing the four that are still reachable: the rest is gone, which is the
    // price of the bound and the reason it is documented rather than surprising.
    var n: usize = 0;
    while (s.undo() != null) n += 1;
    try testing.expectEqual(@as(usize, 4), n);
    // Each revert returns to the value before its own act, so undoing four
    // steps back from ten arrives at six.
    try testing.expectEqual(@as(i32, 6), ledger.value);
}

test "an already-applied act is one act, and applies twice at most" {
    // `pushApplied` is for creations: the caller wanted the result, so the edit
    // is already in the world and the stack must not apply it a second time.
    const a = testing.allocator;
    var ledger = Ledger{};
    var s = Stack.init();
    defer s.deinit(a);

    var cmd: Set = undefined;
    // The act records the world as it was before the edit, and the caller has
    // already applied the edit itself: the world shows the new value, and the
    // act records only what it must undo and redo.
    try s.pushApplied(a, set(&ledger, &cmd, 5, "already applied"));
    ledger.value = 5;
    try testing.expectEqual(@as(i32, 5), ledger.value);
    // It has not applied anything itself — that is the difference from a push.
    try testing.expectEqual(@as(usize, 0), ledger.applies);
    // Undo reverses it, and the redo re-applies it: the two halves of an act
    // the caller made, which is what makes a creation undoable.
    _ = s.undo();
    try testing.expectEqual(@as(i32, 0), ledger.value);
    try testing.expectEqual(@as(usize, 1), ledger.reverts);
    _ = s.redo();
    try testing.expectEqual(@as(i32, 5), ledger.value);
    try testing.expectEqual(@as(usize, 1), ledger.applies);
}

test "undo and redo report nothing rather than lying" {
    const a = testing.allocator;
    var ledger = Ledger{};
    _ = &ledger;
    var s = Stack.init();
    defer s.deinit(a);
    try testing.expect(s.undoLabel() == null);
    try testing.expect(s.redoLabel() == null);
    try testing.expect(s.undo() == null);
    try testing.expect(s.redo() == null);
    try testing.expect(!s.canUndo());
    try testing.expect(!s.canRedo());
}
