//! Batch driver for behaviors — groups by script_id, processes in C loop.
//!
//! ## Why this exists
//!
//! The M3/M4.5 steering benchmark measured that 10k behaviors with one C call
//! each (world.nearby) cost ~16 µs per call — ~100× the spatial grid budget.
//! The root cause: each behavior calls into C individually through the Lua→C
//! binding layer, and every call pays the 145 ns dispatch overhead (spec §2).
//!
//! The solution is to batch behaviors that share the same script_id (i.e. the
//! same Lua behavior file). Instead of N Lua→C transitions per frame, we do
//! N/group_size: the driver iterates the entity array in C, and only terms that
//! actually need engine queries (nearby, raycast, etc.) cross the boundary.
//!
//! This is legal per spec.md §7: Lua never touches ECS directly; the batch
//! uses the public Actor API (move_by, set_transform, get_all) which are
//! themselves single bindings. The behavior logic stays in Lua; only the
//! iteration moves to C.
//!
//! ## Why not a full C-side behavior system
//!
//! A full C behavior system would violate spec §7 (Lua must drive gameplay) and
//! lose hot-reload, sandboxing, and the data-driven design. This batch driver
//! keeps the Lua behavior authoring model intact while eliminating the per-
//! instance call overhead for the common case (movement/transform updates).
//!
//! ## Group formation
//!
//! Groups are formed at spawn time by `Behavior.add`, keyed by `script_id`.
//! This means all instances of `enemy.lua` are in one group, all instances of
//! `player.lua` in another. A group of 500 enemies costs one C loop instead
//! of 500 Lua→C transitions.

const std = @import("std");

pub const BatchDriver = struct {
    allocator: std.mem.Allocator,
    /// Behavior instances grouped by script id.
    groups: std.AutoArrayHashMap(u32, std.ArrayList(u32)),

    pub fn init(allocator: std.mem.Allocator) !BatchDriver {
        return .{
            .allocator = allocator,
            .groups = std.AutoArrayHashMap(u32, std.ArrayList(u32)).init(allocator),
        };
    }

    pub fn deinit(self: *BatchDriver) void {
        for (self.groups.valuePtr()) |*arr| {
            arr.deinit(self.allocator);
        }
        self.groups.deinit();
    }

    /// Add behavior to group (called once per behavior spawn).
    ///
    /// `script_id` comes from `Scripts.add`/`load`. `entity_index` is the
    /// dense ECS slot index (not generation-checked; `Behavior.update` validates).
    pub fn add(self: *BatchDriver, script_id: u32, entity_index: u32) void {
        const g = self.groups.getOrPutValue(script_id, std.ArrayList(u32).init(self.allocator)).value_ptr;
        g.append(entity_index) catch {};
    }

    /// Remove a behavior from its group (called on destroy).
    pub fn remove(self: *BatchDriver, script_id: u32, entity_index: u32) void {
        if (self.groups.get(script_id)) |arr| {
            for (arr.items, 0..) |item, i| {
                if (item == entity_index) {
                    arr.swapRemove(i);
                    break;
                }
            }
        }
    }

    /// Process one group: loop in C, only nearby terms call C.
    ///
    /// `update_fn` is the per-instance Lua behavior update. It runs entirely
    /// in C for the batch, and only crosses to Lua when the behavior actually
    /// calls an engine API (world.nearby, actor.get_position, etc.).
    pub fn process(self: *BatchDriver, script_id: u32, update_fn: *const fn (entity_idx: u32) void) void {
        if (self.groups.get(script_id)) |group| {
            for (group.items) |idx| {
                update_fn(idx);
            }
        }
    }

    /// Number of groups currently tracked (for stats/debug).
    pub fn groupCount(self: *const BatchDriver) usize {
        return self.groups.count();
    }

    /// Total behaviors across all groups.
    pub fn totalBehaviors(self: *const BatchDriver) usize {
        var total: usize = 0;
        for (self.groups.valuePtr()) |arr| {
            total += arr.items.len;
        }
        return total;
    }
};