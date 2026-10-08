//! Queries: typed iteration over archetypes, batch first.
//!
//! Two access shapes, both over the same code path:
//! - `nextBatch()` gives one **archetype** at a time as `[]T` columns: the
//!   shape a system wants (M2 renderer, physics sync), because the loop body
//!   is a plain Zig loop over slices the optimizer can vectorize.
//! - `next()` gives one **entity** row at a time: the shape a facade wants
//!   (`Actor.get`-style logic inside a system).
//!
//! Cost per iteration step: one mask test (4 word comparisons) and, once per
//! archetype, the column indices — never per entity. Asking for a component an
//! entity does not have is impossible by construction.

const std = @import("std");
const components = @import("components.zig");
const archetype_mod = @import("archetype.zig");
const entity = @import("entity.zig");

pub const Archetype = archetype_mod.Archetype;
pub const Entity = entity.Entity;
pub const ComponentId = components.ComponentId;
pub const Mask = components.Mask;

pub fn Query(comptime WorldT: type, comptime with: anytype, comptime without: anytype) type {
    const with_count = countOf(with);

    return struct {
        world: *WorldT,
        /// Masks are comptime constants per call site.
        required: Mask = maskOfTypes(with),
        excluded: Mask = maskOfTypes(without),
        /// Next archetype to consider.
        arch_index: usize = 0,
        current: ?*Archetype = null,
        row: usize = 0,
        /// Column index of each requested type inside `current`.
        cols: [with_count]u16 = undefined,

        const Self = @This();

        /// One archetype worth of rows: `slice` for columns, `entitySlice`
        /// for the handles. Valid until the underlying tables grow.
        pub const Batch = struct {
            arch: *const Archetype,
            cols: [with_count]u16,

            pub fn len(self: Batch) usize {
                return self.arch.len;
            }

            /// Typed column for `T`: a dense slice, no per-element checks.
            pub fn slice(self: Batch, comptime T: type) []T {
                const k = comptime indexOf(with, T);
                return self.arch.columnSlice(T, self.cols[k]);
            }

            /// Entities of this archetype, parallel to every column.
            pub fn entitySlice(self: Batch) []Entity {
                return self.arch.entities[0..self.arch.len];
            }

            pub fn entityAt(self: Batch, row: usize) Entity {
                return self.arch.entities[row];
            }
        };

        /// One entity row: `get(T)` is a typed pointer into the column.
        pub const Row = struct {
            arch: *const Archetype,
            cols: [with_count]u16,
            row: usize,

            pub fn entity(self: *const Row) Entity {
                return self.arch.entities[self.row];
            }

            pub fn get(self: *const Row, comptime T: type) *T {
                const k = comptime indexOf(with, T);
                return self.arch.cellPtr(T, self.cols[k], self.row);
            }
        };

        /// Advances to the next matching archetype, or `null` at the end.
        pub fn nextBatch(self: *Self) ?Batch {
            const arches = self.world.archetypes.items;
            while (self.arch_index < arches.len) {
                const arch = &arches[self.arch_index];
                self.arch_index += 1;
                if (!arch.matches(self.required, self.excluded)) continue;
                self.current = arch;
                self.row = 0;
                inline for (with, 0..) |T, k| {
                    // Required components are present by construction.
                    const col = arch.findColumn(comptime components.componentId(T)).?;
                    self.cols[k] = @intCast(col);
                }
                return .{ .arch = arch, .cols = self.cols };
            }
            self.current = null;
            return null;
        }

        /// One entity row at a time; systems that can should use `nextBatch`.
        pub fn next(self: *Self) ?Row {
            const arch = self.current orelse null;
            if (arch == null or self.row >= arch.?.len) {
                const batch = self.nextBatch() orelse return null;
                return .{ .arch = batch.arch, .cols = batch.cols, .row = self.row };
            }
            const cursor = Row{ .arch = arch.?, .cols = self.cols, .row = self.row };
            self.row += 1;
            return cursor;
        }
    };
}

fn countOf(comptime tuple: anytype) usize {
    return @typeInfo(@TypeOf(tuple)).@"struct".fields.len;
}

/// Comptime tuple -> slice of the types it contains (values are accepted too,
/// so the same helper serves spawn tuples of values).
fn TypesOf(comptime tuple: anytype) []const type {
    comptime {
        const len = countOf(tuple);
        var types: [len]type = undefined;
        for (tuple, &types) |item, *slot| {
            const T = if (@TypeOf(item) == type) item else @TypeOf(item);
            slot.* = T;
        }
        const final = types;
        return &final;
    }
}

fn maskOfTypes(comptime tuple: anytype) Mask {
    const types = TypesOf(tuple);
    var mask = Mask.initEmpty();
    inline for (types) |T| mask.set(components.componentId(T));
    return mask;
}

/// Position of `T` inside the query tuple (comptime constant).
fn indexOf(comptime tuple: anytype, comptime T: type) usize {
    comptime {
        const types = TypesOf(tuple);
        for (types, 0..) |U, i| {
            if (U == T) return i;
        }
        @compileError("component not part of this query: " ++ @typeName(T));
    }
}
