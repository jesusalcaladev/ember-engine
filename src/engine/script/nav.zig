//! The navigation grid and A* over it.
//!
//! ## What it is
//!
//! A UNIFORM GRID of walkable cells, built from the level's colliders, and an
//! A* search over it. A path is a list of waypoints, and a script walks it.
//!
//! The grid is the cheap answer to the expensive question. A navmesh (the
//! "right" answer) is a polygon soup that has to be baked from the level's
//! geometry, and the baking is a whole subsystem. A grid of cells is rastered
//! from the colliders the level already has, costs one byte per cell, and
//! answers "can I walk from here to there" in microseconds. What it cannot do
//! is find a path through a gap narrower than a cell, or along a ledge —
//! and the honest answer to "is a grid enough" is "for most 2D games, yes".
//!
//! ## The scratch
//!
//! A search needs three arrays (the cost, the parent, the open set) the size
//! of the grid, and a search happens INSIDE a frame. So the arrays are
//! allocated ONCE, when the grid is built, and reused by every search
//! (spec §3.1: the frame does not allocate).
//!
//! The "visited" test is a GENERATION counter rather than a clear: a search
//! that cleared the arrays would write every cell of a 65 000-cell grid on
//! every call, and a path that crosses ten cells would pay for the other
//! 64 990.

const std = @import("std");
const ecs = @import("ecs");
const core_math = @import("core").math;

const Vec2 = core_math.Vec2;

/// The default cell size, in world units. A cell should be about the size of
/// an actor: smaller and the grid gets huge, bigger and the paths get ragged.
pub const default_cell: f32 = 24;

/// The most cells a grid may hold. A level bigger than that gets a BIGGER
/// cell, not a bigger grid: the grid is a budget, and a budget that grows
/// with the level is not a budget.
pub const max_cells: u32 = 256 * 256;

/// The most waypoints a path may have. A path longer than this is a level
/// with a problem, and a path that cannot be walked is not worth returning.
pub const max_waypoints: usize = 256;

/// A cell of the grid.
pub const Cell = struct { cx: i32, cy: i32 };

/// The navigation grid: the cells, and the search over them.
pub const Grid = struct {
    allocator: std.mem.Allocator,
    /// The cell size in world units.
    cell: f32 = default_cell,
    /// The world position of the grid's (0,0) corner.
    origin: Vec2 = .{},
    cols: u32 = 0,
    rows: u32 = 0,
    /// One byte per cell: 0 = walkable, 1 = blocked.
    blocked: []u8 = &.{},

    // ── The search's scratch, allocated once ────────────────────────────────
    /// The cost so far, per cell.
    g_score: []f32 = &.{},
    /// The cell each cell came from, -1 for none.
    came_from: []i32 = &.{},
    /// The generation of each cell's data. A cell whose generation is not
    /// the current one has never been touched by THIS search.
    stamp: []u32 = &.{},
    /// The generation counter.
    generation: u32 = 1,
    /// The open set: a binary min-heap of (f, cell).
    heap: Heap = .{},

    pub fn deinit(self: *Grid) void {
        self.allocator.free(self.blocked);
        self.allocator.free(self.g_score);
        self.allocator.free(self.came_from);
        self.allocator.free(self.stamp);
        self.heap.deinit();
        self.* = undefined;
    }

    /// Builds the grid from the world's colliders.
    ///
    /// A collider BLOCKS the cells it covers. A sensor does NOT: a trigger is
    /// something you walk THROUGH, and a grid that treated it as a wall would
    /// make every pickup unreachable.
    ///
    /// The cell size grows until the grid fits `max_cells`: the grid is a
    /// budget, and a budget that grows with the level is not a budget.
    pub fn build(allocator: std.mem.Allocator, world: *ecs.World, cell: f32) !Grid {
        var self_ = Grid{ .allocator = allocator, .cell = @max(cell, 1.0) };

        // The bounds: the colliders' extent, with a margin so the start and
        // the goal are usually INSIDE the grid rather than on its edge.
        var min_x: f32 = 0;
        var min_y: f32 = 0;
        var max_x: f32 = 0;
        var max_y: f32 = 0;
        var any = false;

        var q = world.query(.{ ecs.components.Collider2D });
        while (q.nextBatch()) |batch| {
            const colliders = batch.slice(ecs.components.Collider2D);
            const entities = batch.entitySlice();
            for (colliders, entities) |c, e| {
                if (c.is_sensor) continue; // a trigger is walkable
                const t = world.get(e, ecs.components.Transform) orelse continue;
                const half = c.size;
                const x0 = t.position.x + c.offset.x - half.x;
                const y0 = t.position.y + c.offset.y - half.y;
                const x1 = t.position.x + c.offset.x + half.x;
                const y1 = t.position.y + c.offset.y + half.y;
                if (!any) {
                    min_x = x0;
                    min_y = y0;
                    max_x = x1;
                    max_y = y1;
                    any = true;
                    continue;
                }
                min_x = @min(min_x, x0);
                min_y = @min(min_y, y0);
                max_x = @max(max_x, x1);
                max_y = @max(max_y, y1);
            }
        }
        if (!any) {
            // No colliders: an empty grid, and a path that is just the goal.
            // A level with no walls is a level you can walk across.
            self_.origin = .{ .x = -self_.cell, .y = -self_.cell };
            self_.cols = 2;
            self_.rows = 2;
            try self_.allocate();
            @memset(self_.blocked, 0);
            return self_;
        }

        // A generous margin: a quarter of the level, at least two cells. The
        // grid is rastered from the COLLIDERS, and a level's walkable space
        // extends past its walls — a start or a goal just outside the walls
        // must still be on the grid.
        const margin_x = @max((max_x - min_x) * 0.25, self_.cell * 2);
        const margin_y = @max((max_y - min_y) * 0.25, self_.cell * 2);
        min_x -= margin_x;
        min_y -= margin_y;
        max_x += margin_x;
        max_y += margin_y;

        // The cell size grows until the grid fits the budget.
        const width = @max(max_x - min_x, 1.0);
        const height = @max(max_y - min_y, 1.0);
        while (true) {
            const cols = @as(u32, @intFromFloat(@ceil(width / self_.cell)));
            const rows = @as(u32, @intFromFloat(@ceil(height / self_.cell)));
            if (cols * rows <= max_cells or self_.cell > 4096) break;
            self_.cell *= 2;
        }

        self_.origin = .{ .x = min_x, .y = min_y };
        self_.cols = @max(@as(u32, @intFromFloat(@ceil(width / self_.cell))), 1);
        self_.rows = @max(@as(u32, @intFromFloat(@ceil(height / self_.cell))), 1);
        try self_.allocate();
        @memset(self_.blocked, 0);

        // Rasterize the colliders.
        var q2 = world.query(.{ ecs.components.Collider2D });
        while (q2.nextBatch()) |batch| {
            const colliders = batch.slice(ecs.components.Collider2D);
            const entities = batch.entitySlice();
            for (colliders, entities) |c, e| {
                if (c.is_sensor) continue;
                const t = world.get(e, ecs.components.Transform) orelse continue;
                const half = c.size;
                const p0 = self_.cellOf(.{ .x = t.position.x + c.offset.x - half.x, .y = t.position.y + c.offset.y - half.y });
                const p1 = self_.cellOf(.{ .x = t.position.x + c.offset.x + half.x, .y = t.position.y + c.offset.y + half.y });
                var cy = p0.cy;
                while (cy <= p1.cy) : (cy += 1) {
                    var cx = p0.cx;
                    while (cx <= p1.cx) : (cx += 1) {
                        if (!self_.inBounds(cx, cy)) continue;
                        self_.blocked[self_.index(cx, cy)] = 1;
                    }
                }
            }
        }
        return self_;
    }

    fn allocate(self: *Grid) !void {
        const n = @as(usize, self.cols) * @as(usize, self.rows);
        self.blocked = try self.allocator.alloc(u8, n);
        errdefer self.allocator.free(self.blocked);
        self.g_score = try self.allocator.alloc(f32, n);
        errdefer self.allocator.free(self.g_score);
        self.came_from = try self.allocator.alloc(i32, n);
        errdefer self.allocator.free(self.came_from);
        self.stamp = try self.allocator.alloc(u32, n);
        errdefer self.allocator.free(self.stamp);
        try self.heap.init(self.allocator, n);
    }

    /// The cell a world position falls in.
    fn cellOf(self: *const Grid, p: Vec2) Cell {
        return .{
            .cx = @intFromFloat(@floor((p.x - self.origin.x) / self.cell)),
            .cy = @intFromFloat(@floor((p.y - self.origin.y) / self.cell)),
        };
    }

    /// A cell clamped into the grid.
    ///
    /// The grid covers the level's COLLIDERS plus a margin, so a start or a
    /// goal just past the edge is clamped to the nearest cell inside it
    /// rather than refused: an actor standing outside the walls is still
    /// somewhere the level can be walked from.
    fn clampCell(self: *const Grid, c: Cell) Cell {
        const max_x: i32 = @intCast(self.cols - 1);
        const max_y: i32 = @intCast(self.rows - 1);
        return .{
            .cx = std.math.clamp(c.cx, 0, max_x),
            .cy = std.math.clamp(c.cy, 0, max_y),
        };
    }

    fn inBounds(self: *const Grid, cx: i32, cy: i32) bool {
        return cx >= 0 and cy >= 0 and cx < @as(i32, @intCast(self.cols)) and cy < @as(i32, @intCast(self.rows));
    }

    fn index(self: *const Grid, cx: i32, cy: i32) usize {
        return @as(usize, @intCast(cy)) * @as(usize, @intCast(self.cols)) + @as(usize, @intCast(cx));
    }

    /// The world position of a cell's centre.
    pub fn cellCenter(self: *const Grid, cx: i32, cy: i32) Vec2 {
        return .{
            .x = self.origin.x + (@as(f32, @floatFromInt(cx)) + 0.5) * self.cell,
            .y = self.origin.y + (@as(f32, @floatFromInt(cy)) + 0.5) * self.cell,
        };
    }

    /// Whether a world position is on a walkable cell.
    ///
    /// A position just outside the grid is clamped to the edge cell: the grid
    /// is rastered from the level's colliders, and an actor standing a little
    /// past the last wall is still on the level.
    pub fn isWalkable(self: *const Grid, p: Vec2) bool {
        const c = self.clampCell(self.cellOf(p));
        return self.blocked[self.index(c.cx, c.cy)] == 0;
    }

    /// Finds a path from `from` to `to`, writing the waypoints into `out`.
    ///
    /// Returns how many waypoints there are; 0 means "no path". The path
    /// EXCLUDES the start (the actor is already there) and INCLUDES the goal.
    ///
    /// The search is 8-way: a diagonal step costs √2, so a path does not
    /// zigzag between two cells that touch only at a corner.
    pub fn pathfind(self: *Grid, from: Vec2, to: Vec2, out: []Vec2) usize {
        if (out.len == 0) return 0;
        const start = self.clampCell(self.cellOf(from));
        const goal = self.clampCell(self.cellOf(to));
        if (!self.inBounds(start.cx, start.cy) or !self.inBounds(goal.cx, goal.cy)) return 0;
        // The goal is inside a wall: the closest walkable cell to it is the
        // goal. A path to the wall next to the door is the path a player would
        // walk.
        const goal_cell = self.nearestWalkable(goal) orelse return 0;

        const start_index = self.index(start.cx, start.cy);
        const goal_index = self.index(goal_cell.cx, goal_cell.cy);
        if (start_index == goal_index) {
            out[0] = self.cellCenter(goal_cell.cx, goal_cell.cy);
            return 1;
        }

        self.generation +%= 1;
        if (self.generation == 0) {
            // The counter wrapped: every stamp is stale, so clear them.
            @memset(self.stamp, 0);
            self.generation = 1;
        }
        const gen = self.generation;

        self.heap.clear();
        self.g_score[start_index] = 0;
        self.stamp[start_index] = gen;
        self.came_from[start_index] = -1;
        self.heap.push(.{
            .f = self.heuristic(start, goal_cell),
            .g = 0,
            .cell = start_index,
        }) catch return 0;

        var found = false;
        while (self.heap.pop()) |entry| {
            const cell = entry.cell;
            if (cell == goal_index) {
                found = true;
                break;
            }
            if (self.stamp[cell] == gen and entry.g > self.g_score[cell] + 0.001) continue; // stale entry
            const cx = @as(i32, @intCast(cell % @as(usize, @intCast(self.cols))));
            const cy = @as(i32, @intCast(cell / @as(usize, @intCast(self.cols))));

            for (0..8) |d| {
                const dx: i32 = switch (d) {
                    0 => 1,
                    1 => -1,
                    2 => 0,
                    3 => 0,
                    4 => 1,
                    5 => 1,
                    6 => -1,
                    else => -1,
                };
                const dy: i32 = switch (d) {
                    0 => 0,
                    1 => 0,
                    2 => 1,
                    3 => -1,
                    4 => 1,
                    5 => -1,
                    6 => 1,
                    else => -1,
                };
                const nx = cx + dx;
                const ny = cy + dy;
                if (!self.inBounds(nx, ny)) continue;
                if (self.blocked[self.index(nx, ny)] != 0) continue;
                // A diagonal step may not cut a corner between two walls.
                if (dx != 0 and dy != 0) {
                    if (self.blocked[self.index(cx + dx, cy)] != 0) continue;
                    if (self.blocked[self.index(cx, cy + dy)] != 0) continue;
                }
                const ni = self.index(nx, ny);
                const step: f32 = if (dx != 0 and dy != 0) 1.41421356 else 1.0;
                const tentative = self.g_score[cell] + step;
                if (self.stamp[ni] == gen and tentative >= self.g_score[ni]) continue;
                self.stamp[ni] = gen;
                self.g_score[ni] = tentative;
                self.came_from[ni] = @intCast(cell);
                const c = Cell{ .cx = nx, .cy = ny };
                self.heap.push(.{
                    .f = tentative + self.heuristic(c, goal_cell),
                    .g = tentative,
                    .cell = ni,
                }) catch return 0;
            }
        }
        if (!found) return 0;

        // Walk the parents back, then reverse.
        var path: [max_waypoints]Vec2 = undefined;
        var n: usize = 0;
        var cur = @as(i32, @intCast(goal_index));
        while (cur >= 0 and n < max_waypoints) {
            const cols_i: i32 = @intCast(self.cols);
            const cx = @rem(cur, cols_i);
            const cy = @divTrunc(cur, cols_i);
            path[n] = self.cellCenter(cx, cy);
            n += 1;
            if (@as(usize, @intCast(cur)) == start_index) break;
            cur = self.came_from[@intCast(cur)];
        }
        if (n == 0) return 0;
        // The start is the actor's own cell: the path starts at the NEXT one.
        const count = @min(n - 1, out.len);
        var i: usize = 0;
        while (i < count) : (i += 1) {
            out[i] = path[n - 2 - i];
        }
        return count;
    }

    /// The closest walkable cell to a target, searched in rings.
    fn nearestWalkable(self: *const Grid, target: Cell) ?Cell {
        if (self.inBounds(target.cx, target.cy) and self.blocked[self.index(target.cx, target.cy)] == 0) {
            return target;
        }
        var r: i32 = 1;
        while (r <= 8) : (r += 1) {
            var dy: i32 = -r;
            while (dy <= r) : (dy += 1) {
                var dx: i32 = -r;
                while (dx <= r) : (dx += 1) {
                    // Only the ring's border.
                    if (@abs(dx) != r and @abs(dy) != r) continue;
                    const cx = target.cx + dx;
                    const cy = target.cy + dy;
                    if (!self.inBounds(cx, cy)) continue;
                    if (self.blocked[self.index(cx, cy)] != 0) continue;
                    return .{ .cx = cx, .cy = cy };
                }
            }
        }
        return null;
    }

    /// The octile distance: the straight-line distance, never underestimating.
    fn heuristic(self: *const Grid, a: Cell, b: Cell) f32 {
        _ = self;
        const dx = @abs(a.cx - b.cx);
        const dy = @abs(a.cy - b.cy);
        const lo = @min(dx, dy);
        const hi = @max(dx, dy);
        return @as(f32, @floatFromInt(hi - lo)) + 1.41421356 * @as(f32, @floatFromInt(lo));
    }
};

/// A binary min-heap over (f, cell). The open set of the A*.
const Heap = struct {
    items: []Item = &.{},
    len: usize = 0,
    allocator: std.mem.Allocator = undefined,

    const Item = struct {
        /// The estimate: g + h.
        f: f32,
        /// The cost so far when the entry was pushed. The STALE test needs it:
        /// comparing `f` against the cell's g would compare the heuristic with
        /// the cost, and every entry would look stale.
        g: f32,
        cell: usize,
    };

    pub fn init(self: *Heap, allocator: std.mem.Allocator, capacity: usize) !void {
        self.allocator = allocator;
        self.items = try allocator.alloc(Item, capacity);
        self.len = 0;
    }

    pub fn deinit(self: *Heap) void {
        if (self.items.len != 0) self.allocator.free(self.items);
        self.items = &.{};
        self.len = 0;
    }

    pub fn clear(self: *Heap) void {
        self.len = 0;
    }

    pub fn push(self: *Heap, item: Item) !void {
        if (self.len >= self.items.len) return error.NoSpaceLeft;
        self.items[self.len] = item;
        var i = self.len;
        self.len += 1;
        while (i > 0) {
            const parent = (i - 1) / 2;
            if (self.items[parent].f <= self.items[i].f) break;
            const t = self.items[parent];
            self.items[parent] = self.items[i];
            self.items[i] = t;
            i = parent;
        }
    }

    pub fn pop(self: *Heap) ?Item {
        if (self.len == 0) return null;
        const top = self.items[0];
        self.len -= 1;
        if (self.len > 0) {
            self.items[0] = self.items[self.len];
            var i: usize = 0;
            while (true) {
                const l = 2 * i + 1;
                const r = l + 1;
                var smallest = i;
                if (l < self.len and self.items[l].f < self.items[smallest].f) smallest = l;
                if (r < self.len and self.items[r].f < self.items[smallest].f) smallest = r;
                if (smallest == i) break;
                const t = self.items[smallest];
                self.items[smallest] = self.items[i];
                self.items[i] = t;
                i = smallest;
            }
        }
        return top;
    }
};
