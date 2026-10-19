//! The editor console — a bounded ring of log lines, drawn as a panel.
//!
//! ## Why the console owns its own buffer
//!
//! The engine's `log` (see `core/log.zig`) writes straight to stderr and is
//! deliberately sink-free: a Zig function pointer cannot be generic, and the
//! engine's logging has to stay allocation-free. So the editor cannot "hook"
//! the engine's log by calling one function — and pretending to would mean
//! either an allocation per log line or a global mutable callback that the
//! runtime, the tests and the tools would all fight over.
//!
//! The console therefore has an explicit API: everything the editor does that a
//! user should be able to read back goes through `push`. That is a smaller
//! promise than "every engine log line appears here", and it is a promise this
//! file can keep. Redirecting the engine's `log` into this buffer is a ROADMAP
//! item that needs a sink in the engine, not a hack here.
//!
//! ## Why a ring and not an `ArrayList`
//!
//! A console is the one panel that grows without bound: a chatty frame writes a
//! line every tick, and a list that appends forever is a leak with a scrollbar.
//! The ring caps memory at `capacity * sizeof(Line)` (about 100 KiB), never
//! allocates after init, and — the part that matters for an editor running
//! inside a no-allocation frame — can be written to from inside the frame.

const std = @import("std");
const ui = @import("ui");

pub const Level = enum(u8) {
    info = 0,
    success = 1,
    warn = 2,
    err = 3,

    /// A 2-character gutter marker. Wide enough to scan, narrow enough that it
    /// does not read as the message.
    pub fn tag(self: Level) []const u8 {
        return switch (self) {
            .info => "  ",
            .success => "ok",
            .warn => "!!",
            .err => "XX",
        };
    }

    pub fn color(self: Level, t: *const ui.Theme) ui.Rgba {
        return switch (self) {
            .info => t.colors.text_dim,
            .success => t.colors.success,
            .warn => t.colors.warning,
            .err => t.colors.danger,
        };
    }
};

pub const Console = struct {
    pub const capacity = 512;
    pub const line_capacity = 192;

    pub const Line = struct {
        level: Level = .info,
        text: [line_capacity]u8 = [_]u8{0} ** line_capacity,
        len: u16 = 0,

        pub fn slice(self: *const Line) []const u8 {
            return self.text[0..self.len];
        }
    };

    lines: [capacity]Line = [_]Line{.{}} ** capacity,
    /// Where the next line is written. The newest line is at `head - 1`.
    head: usize = 0,
    /// Live lines, saturating at `capacity` so an ancient message is dropped
    /// rather than the array wrapping onto itself.
    count: usize = 0,
    /// Minimum severity shown. The filter is a view setting, not a write
    /// setting: a line below it is still stored, so raising the filter and
    /// lowering it again does not lose history.
    filter: Level = .info,
    /// Keep the newest line in view. Cleared when the user scrolls up, so a
    /// console that is being read does not get yanked to the bottom by the next
    /// log line.
    follow: bool = true,
    /// Counts per level since the last `clear`, for the tab badges.
    counts: [4]u32 = [_]u32{0} ** 4,

    pub fn push(self: *Console, level: Level, comptime fmt: []const u8, args: anytype) void {
        const line = &self.lines[self.head];
        line.level = level;
        // `bufPrint` writes atomically: on overflow it writes NOTHING, so the
        // fallback is not a truncation of a good message but an explicit marker
        // saying the line was too long. Silently showing half a message is how
        // a 300-character error becomes a mystery.
        const written = std.fmt.bufPrint(&line.text, fmt, args) catch blk: {
            line.text[0] = '!';
            line.text[1] = '!';
            break :blk line.text[0..2];
        };
        line.len = @intCast(written.len);
        self.head = (self.head + 1) % capacity;
        if (self.count < capacity) self.count += 1;
        self.counts[@intFromEnum(level)] +%= 1;
    }

    pub fn clear(self: *Console) void {
        self.head = 0;
        self.count = 0;
        self.counts = [_]u32{0} ** 4;
    }

    /// The `i`th live line, oldest first, or null past the end.
    pub fn nth(self: *const Console, i: usize) ?*const Line {
        if (i >= self.count) return null;
        const idx = (self.head + capacity - self.count + i) % capacity;
        return &self.lines[idx];
    }

    /// Lines at or above the current filter. The console row count is this, not
    /// `count`: the scroll region must not reserve space for lines it will not
    /// draw, or the scrollbar lies about how much there is to read.
    pub fn visibleCount(self: *const Console) usize {
        const min = @intFromEnum(self.filter);
        var n: usize = 0;
        var i: usize = 0;
        while (i < self.count) : (i += 1) {
            if (@intFromEnum(self.nth(i).?.level) >= min) n += 1;
        }
        return n;
    }

    pub fn errorCount(self: *const Console) u32 {
        return self.counts[@intFromEnum(Level.err)];
    }
    pub fn warnCount(self: *const Console) u32 {
        return self.counts[@intFromEnum(Level.warn)];
    }

    // ── Tests ──────────────────────────────────────────────────────────────

    pub fn nthIsOldestFirst(self: *const Console, i: usize, want: []const u8) bool {
        const line = self.nth(i) orelse return false;
        return std.mem.eql(u8, line.slice(), want);
    }
};

// ── The panel ────────────────────────────────────────────────────────────

/// Published for the scroll body. See the shell for why every panel body that
/// is a function pointer needs one of these.
pub var drawing: ?*Console = null;

fn scrollBody(ctx: *ui.Context) void {
    const c = drawing.?;
    const min = @intFromEnum(c.filter);
    // Ids must be unique among the SIBLINGS ImGui sees, and a filtered list
    // changes which line is at which position — so the id is the ring index
    // (`i`), which is stable for a given line, and not the visible ordinal.
    var id_buf: [24]u8 = undefined;
    var label_buf: [Console.line_capacity + 8]u8 = undefined;
    var i: usize = 0;
    while (i < c.count) : (i += 1) {
        const line = c.nth(i).?;
        if (@intFromEnum(line.level) < min) continue;
        const id = std.fmt.bufPrint(&id_buf, "cl{d}", .{i}) catch "cl";
        const label = std.fmt.bufPrint(&label_buf, "{s}  {s}", .{ line.level.tag(), line.slice() }) catch line.slice();
        _ = ui.list.row(
            .{
                .id = id,
                .label = label,
                .trailing = "",
                .selectable = false,
            },
            .{ .ctx = ctx, .height = 18.0 },
        );
    }
    if (c.visibleCount() == 0) ui.text.caption(ctx, "no messages at this level");

    // Keep the newest line in view. `SetScrollHereY(1)` has to run while the
    // scroll child is the current window, which is exactly here — after the
    // rows are submitted and before the child closes.
    if (c.follow) ui.cimgui.ember_ui_set_scroll_here_y(1.0);
}

pub fn draw(c: *Console, ctx: *ui.Context) void {
    drawing = c;

    // Filter, clear, follow — one row, because a console's own controls must not
    // cost more vertical space than the messages they filter.
    var errors_only = c.filter == .warn;
    if (ui.toggle.checkbox(.{ .ctx = ctx, .id = "con.err", .label = "warnings +", .value = &errors_only })) {
        c.filter = if (errors_only) .warn else .info;
        // Turning the filter OFF is the one case that should snap back to the
        // newest line: the user is looking for something that just happened.
        if (!errors_only) c.follow = true;
    }
    ui.cimgui.ember_ui_same_line(0, ctx.theme.metrics.gap());
    var follow = c.follow;
    if (ui.toggle.checkbox(.{ .ctx = ctx, .id = "con.follow", .label = "follow", .value = &follow })) {
        c.follow = follow;
    }
    ui.cimgui.ember_ui_same_line(0, ctx.theme.metrics.gap());
    if (ui.Button(.{ .ctx = ctx, .id = "con.clear", .text = "Clear", .icon = .trash, .variant = .ghost })) {
        c.clear();
    }

    ui.layout.space(ctx, 1);

    // A negative height means "everything left", which keeps the counts row
    // pinned to the bottom of the dock at any panel size.
    _ = ui.list.scrollable(ctx, "con.scroll", -30, scrollBody);

    ui.text.caption(ctx, std.fmt.bufPrint(&status_buf, "{d} lines · {d} warnings · {d} errors", .{
        c.count,
        c.warnCount(),
        c.errorCount(),
    }) catch "");
}

var status_buf: [96]u8 = undefined;

const testing = std.testing;

test "console: oldest-first order and the ring evicting the oldest" {
    var c = Console{};
    c.push(.info, "one", .{});
    c.push(.warn, "two", .{});
    c.push(.err, "three", .{});
    try testing.expectEqual(@as(usize, 3), c.count);
    try testing.expect(c.nthIsOldestFirst(0, "one"));
    try testing.expect(c.nthIsOldestFirst(2, "three"));
    try testing.expect(c.nth(3) == null);

    // Overflowing the ring keeps the LAST `capacity` lines, still in order.
    var i: usize = 0;
    while (i < Console.capacity + 10) : (i += 1) c.push(.info, "line {d}", .{i});
    try testing.expectEqual(Console.capacity, c.count);
    try testing.expect(c.nthIsOldestFirst(0, "line 10"));
    // The newest is `capacity + 9`, and `count` live lines end there.
    var buf: [32]u8 = undefined;
    const newest = std.fmt.bufPrint(&buf, "line {d}", .{Console.capacity + 9}) catch unreachable;
    try testing.expect(c.nthIsOldestFirst(Console.capacity - 1, newest));
}

test "console: a long line is marked, never silently halved" {
    var c = Console{};
    const long = "x" ** (Console.line_capacity + 40);
    c.push(.info, "{s}", .{long});
    const line = c.nth(0).?;
    // The fallback marker, not a prefix of the message.
    try testing.expectEqualStrings("!!", line.slice());
}

test "console: the filter hides but does not delete" {
    var c = Console{};
    c.push(.info, "quiet", .{});
    c.push(.err, "loud", .{});
    try testing.expectEqual(@as(usize, 2), c.visibleCount());
    c.filter = .warn;
    try testing.expectEqual(@as(usize, 1), c.visibleCount());
    c.filter = .info;
    try testing.expectEqual(@as(usize, 2), c.visibleCount());
}
