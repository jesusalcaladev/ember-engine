//! Play-in-editor: the snapshot, the running frame, and the restore.
//!
//! ROADMAP M5's headline is "Play and Stop in the same window": the user presses
//! play, the game runs inside the editor's viewport, Stop brings back exactly
//! what was there. That "exactly" is the whole feature, and it is already
//! possible — `zson` serializes a world canonically and `zson.hash` gives it a
//! fingerprint (spec §6 says those exist for "undo/redo and Play-in-editor
//! snapshots"). This module is the state machine around them.
//!
//! ## Why the session owns the world
//!
//! Restoring cannot be done by patching the live world: `zson.apply` only
//! overrides the entities a document names, so it cannot un-spawn something the
//! game spawned or un-destroy something the game destroyed. The restore has to
//! REBUILD the world from the snapshot — which means the world's contents change
//! identity, and the session is the thing that knows that.
//!
//! But a session that replaced the POINTER would break everything holding one,
//! so it does not. The world lives in a cell the session allocates, and
//! `session.world()` hands out the same address before and after Stop; what
//! changes is what that address holds. That is the integration contract for the
//! UI and the runtime both: **read the world from the session, and the pointer
//! survives**. A restore that changed the address would be a restore that
//! invalidated every cached view of the world at the exact moment the user is
//! watching it change.
//!
//! ## The rules during Play
//!
//! Nothing the game does survives. The snapshot taken on entry is the only
//! truth, and Stop rebuilds from it: the same entities, the same components, the
//! same bytes, which `zson.hash` verifies to the last bit. Edits made during
//! Play are real edits that Stop throws away — which is why the criterion is a
//! hash, not a feeling.
//!
//! ## What this module does not do
//!
//! It does not run the systems. Behaviours, physics and rendering belong to the
//! runtime, which knows about windows and Lua; this is the state and the
//! snapshot, headless and testable, the way the rest of the engine is.

const std = @import("std");
const ecs = @import("ecs");
const zson = ecs.zson;
const components = ecs.components;

const World = ecs.World;

pub const Error = error{
    OutOfMemory,
    /// The snapshot could not be taken or restored. `WriteFailed` is the
    /// allocator failing inside the writer that builds the document, which is
    /// how an out-of-memory reaches this module from `zson` — one name for it,
    /// because "the encode ran out of memory" and "the write failed" are the
    /// same event seen from two sides.
    WriteFailed,
    AlreadyPlaying,
    NotPlaying,
};

pub const State = enum { stopped, playing };

pub const Session = struct {
    allocator: std.mem.Allocator,
    /// The one World the session, the UI and the runtime all read. The address
    /// is stable for the session's life: Stop changes what it HOLDS, not where
    /// it points.
    cell: *World,
    state: State = .stopped,
    /// The snapshot text, owned by this session, from the call to `begin`.
    snapshot: ?[]u8 = null,
    /// `zson.hash` of the world on entry: what Stop must produce again.
    hash_on_entry: u64 = 0,
    entities_on_entry: usize = 0,
    /// Fixed steps run so far in this play, for the UI's frame counter.
    tick: u64 = 0,
    elapsed_ns: u64 = 0,

    /// Takes ownership of the world. The caller must not deinit it afterwards.
    pub fn init(allocator: std.mem.Allocator, world_in: World) !Session {
        const cell = try allocator.create(World);
        cell.* = world_in;
        return Session{ .allocator = allocator, .cell = cell };
    }

    pub fn deinit(self: *Session) void {
        self.cell.deinit();
        self.allocator.destroy(self.cell);
        if (self.snapshot) |s| self.allocator.free(s);
        self.snapshot = null;
        self.* = undefined;
    }

    /// The live world. The same pointer before, during and after Play, which is
    /// what lets a view cache it.
    pub fn world(self: *const Session) *World {
        return self.cell;
    }

    pub fn isPlaying(self: *const Session) bool {
        return self.state == .playing;
    }

    /// Captures the world and starts playing. The snapshot is the ONLY truth:
    /// it is taken before anything moves, so Stop returns to exactly this.
    pub fn begin(self: *Session) !void {
        if (self.state == .playing) return error.AlreadyPlaying;
        const text = try zson.encodeToString(self.cell, self.allocator);
        errdefer self.allocator.free(text);
        // The hash is of the world as it stands, captured before the systems
        // run: this is the number Stop has to reproduce.
        const h = zson.hash(self.cell);
        if (self.snapshot) |old| self.allocator.free(old);
        self.snapshot = text;
        self.hash_on_entry = h;
        self.entities_on_entry = self.cell.entityCount();
        self.tick = 0;
        self.elapsed_ns = 0;
        self.state = .playing;
    }

    /// Rebuilds the world from the snapshot and stops. Returns the hash the
    /// restored world has, which must equal `hashOnEntry` — the criterion, and
    /// the reason it returns a number rather than nothing.
    pub fn stop(self: *Session) !u64 {
        if (self.state != .playing) return error.NotPlaying;
        const snap = self.snapshot orelse return error.NotPlaying;

        // The restored world is built and validated BEFORE the live one is
        // touched. A restore that failed halfway would leave the editor with a
        // world that is neither the played one nor the edited one, which is the
        // worst state it could be in.
        const restored = try self.allocator.create(World);
        errdefer self.allocator.destroy(restored);
        restored.* = try zson.decode(self.allocator, snap);

        // Swap the CONTENTS, not the cell: the old world's tables are freed
        // through a copy of the struct that owned them, and the address every
        // view has cached keeps meaning the same thing.
        var old: World = self.cell.*;
        self.cell.* = restored.*;
        old.deinit();
        self.allocator.destroy(restored);

        self.state = .stopped;
        return zson.hash(self.cell);
    }

    pub fn hashOnEntry(self: *const Session) u64 {
        return self.hash_on_entry;
    }

    pub fn entitiesOnEntry(self: *const Session) usize {
        return self.entities_on_entry;
    }

    pub fn elapsedNs(self: *const Session) u64 {
        return self.elapsed_ns;
    }

    /// Steps the play forward by one fixed step: bookkeeping a UI needs to
    /// display, and nothing else. The systems themselves are the runtime's.
    pub fn advance(self: *Session, dt_ns: u64) void {
        self.tick += 1;
        self.elapsed_ns += dt_ns;
    }
};

// ─── Tests ───────────────────────────────────────────────────────────────────

const testing = std.testing;

fn testWorld(a: std.mem.Allocator) !World {
    var world = World.init(a);
    errdefer world.deinit();
    try world.enableHierarchy();
    _ = try world.spawn(.{
        components.Transform{ .position = .{ .x = 1.5, .y = -2.25 }, .rotation = 0.5, .scale = .{ .x = 2, .y = 2 } },
    });
    _ = try world.spawn(.{
        components.Transform{ .position = .{ .x = 7, .y = 8 } },
        components.Name.init("block"),
    });
    _ = try world.spawn(.{
        components.Name.init("player"),
    });
    return world;
}

test "Stop restores the exact world the play began from" {
    const a = testing.allocator;
    var s = try Session.init(a, try testWorld(a));
    defer s.deinit();

    const before = zson.hash(s.world());
    try s.begin();
    try testing.expect(s.isPlaying());
    try testing.expectEqual(before, s.hashOnEntry());
    try testing.expectEqual(@as(usize, 3), s.entitiesOnEntry());

    // Play: the game spawns, moves and destroys things. None of it may survive.
    _ = try s.world().spawn(.{components.Name.init("boss")});
    try testing.expect(s.world().entityCount() == 4);
    var q = s.world().query(.{components.Transform});
    while (q.next()) |row| {
        row.get(components.Transform).position.x += 100;
    }
    _ = s.world().despawn(s.world().entityAtSlot(0).?);
    try testing.expect(s.world().entityCount() == 3);

    const after = try s.stop();
    try testing.expect(!s.isPlaying());
    // The criterion, as a number: the same bytes, not a similar world.
    try testing.expectEqual(before, after);
    try testing.expectEqual(@as(usize, 3), s.world().entityCount());
}

test "the world pointer survives a Stop" {
    // The integration contract: a view that cached `session.world()` does not
    // have to invalidate it, because the address never changes and only what it
    // holds does.
    const a = testing.allocator;
    var s = try Session.init(a, try testWorld(a));
    defer s.deinit();
    const cached = s.world();

    try s.begin();
    _ = try s.stop();
    try testing.expectEqual(@as(*World, @ptrFromInt(@intFromPtr(cached))), s.world());
}

test "begin while playing and stop while stopped are errors, not surprises" {
    const a = testing.allocator;
    var s = try Session.init(a, try testWorld(a));
    defer s.deinit();

    // Nothing is playing, so there is nothing to stop: an editor that "stops" a
    // stopped world would think it had restored something.
    try testing.expectError(error.NotPlaying, s.stop());
    try s.begin();
    try testing.expectError(error.AlreadyPlaying, s.begin());
}

test "a begin that cannot allocate leaves the session stopped" {
    const a = testing.allocator;
    // A budget exactly big enough for the session's own cell and nothing else:
    // the encode of the snapshot is the allocation that runs out, which is the
    // failure worth testing.
    var buf: [@sizeOf(World) + 64]u8 = undefined;
    var fba = std.heap.FixedBufferAllocator.init(&buf);
    const world = try testWorld(a);
    var s = try Session.init(fba.allocator(), world);
    defer s.deinit();

    try testing.expectError(error.WriteFailed, s.begin());
    try testing.expect(!s.isPlaying());
    try testing.expectEqual(@as(u64, 0), s.hashOnEntry());
    // And Stop is refused, because there is nothing to stop: the session has
    // not entered Play, and saying otherwise would be how a user loses a file.
    try testing.expectError(error.NotPlaying, s.stop());
}

test "the frame counter advances, and only while asked" {
    const a = testing.allocator;
    var s = try Session.init(a, try testWorld(a));
    defer s.deinit();

    s.advance(1_000_000);
    s.advance(2_000_000);
    try testing.expectEqual(@as(u64, 2), s.tick);
    try testing.expectEqual(@as(u64, 3_000_000), s.elapsedNs());
}
