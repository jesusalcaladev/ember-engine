const std = @import("std");
const world_mod = @import("world.zig");
const components = @import("components.zig");
const timer = @import("timer.zig");

const World = world_mod.World;
const SignalBridge = timer.SignalBridge;

pub const TrackTarget = enum(u8) { transform_x, transform_y, transform_rotation, sprite_uv_x, sprite_uv_y, sprite_tint, light_energy, camera_zoom };

pub const Keyframe = struct { t: f32, value: f32 };

pub const ValueTrack = struct {
    target: TrackTarget,
    keys: []const Keyframe,
};

pub const SpriteFrame = struct {
    t: f32, u0: f32, v0: f32, u1: f32, v1: f32,
};

pub const SpriteTrack = struct {
    frames: []const SpriteFrame,
};

pub const MethodEvent = struct {
    t: f32,
    /// For a plain `method` line: the SIGNAL name to fire. For a `call_lua`
    /// line: the Lua method name to call on the targeted script's instances.
    name: []const u8,
    /// The script to call `name` on, for a `call_lua` event. Null (a plain
    /// `method` event) means FIRE A SIGNAL instead.
    ///
    /// An optional and not a `0`-sentinel, because a script id of 0 is LEGAL:
    /// `Scripts.load` numbers from zero, so the first script a project loads has
    /// id 0 — and with a sentinel it could never receive a method event. (The
    /// acceptance check caught exactly that: an `anim.load` of a clip targeting
    /// script 0 failed to parse.)
    target_script: ?u32 = null,
    fired: bool = false,
};

/// Where the M13 `call_lua` method events go. Same erased-callback shape as
/// `timer.SignalBridge`, and for the same reason: the ECS module cannot import
/// the script module (the module graph runs script -> ecs), so the Lua caller
/// crosses the boundary as behaviour rather than as a type.
///
/// The animation system holds ONE of these (a runtime has one `Behaviors`), set
/// at boot. Null means `call_lua` events are dropped, which is what a headless
/// tool or a test without a VM wants: the clip still plays and still fires its
/// signal `method` events.
pub const MethodHook = struct {
    ctx: ?*anyopaque = null,
    call: ?*const fn (ctx: ?*anyopaque, script_id: u32, name: []const u8) void = null,
};

/// The M6 asset GUID of a clip at `path`, as the `u32` handle an
/// `AnimationPlayer.clip_id` stores.
///
/// Derived from the path with the SAME FNV-1a the asset registry uses
/// (`assets.registry.AssetGUID.fromPath`), so a clip's handle is stable across
/// sessions: a scene or a script that only knows the path lands on the same id
/// the loader produced, with no table in common. The low 32 bits of the 64-bit
/// GUID are what a `u32` handle can hold; a collision needs two paths whose
/// hashes agree in 32 bits.
///
/// 0 is the "nothing playing" sentinel (`AnimationPlayer.clip_id == 0` means
/// idle), so a hash that lands on it is bumped to 1 — a collision with the
/// sentinel, not with another clip.
pub fn clipIdForPath(path: []const u8) u32 {
    var h: u64 = 0xcbf29ce484222325; // FNV offset basis, as `AssetGUID` uses
    for (path) |c| {
        h ^= @as(u64, c);
        // WRAPPING multiply: FNV's whole mechanics are the u64 overflow, and
        // plain `*=` panics on it in Debug (a test that loads a clip caught
        // this). `AssetGUID` in the assets module has the same correction.
        h *%= 0x100000001b3;
    }
    const id: u32 = @truncate(h);
    return if (id == 0) 1 else id;
}

pub const MethodTrack = struct {
    events: []MethodEvent,
};

pub const Clip = struct {
    duration: f32 = 1.0,
    flags: u8 = components.anim_clip_loop,
    root_motion: bool = false,
    root_motion_dx: f32 = 0.0,
    root_motion_dy: f32 = 0.0,
    root_motion_dr: f32 = 0.0,
    value_tracks: []const ValueTrack = &.{},
    sprite_tracks: []const SpriteTrack = &.{},
    method_tracks: []const MethodTrack = &.{},
    /// When loaded from a file, the decoded bytes are kept alive here because
    /// `MethodEvent.name` slices into them. `null` for hand-built clips, whose
    /// names are static strings. `freeClip` releases it.
    name_pool: ?[]u8 = null,
};

pub const System = struct {
    allocator: std.mem.Allocator,
    clips: std.AutoHashMap(u32, Clip),
    /// Source path -> clip id. A hot reload swaps the decoded clip in under its
    /// EXISTING id, so every `AnimationPlayer` pointing at it keeps its `time`
    /// (the M13 hot-reload contract). It is also the index `preloadDir` and
    /// `lookupPath` walk, so a project knows which paths are resident.
    path_to_id: std.StringHashMap(u32),
    /// Where `call_lua` method events go (the M13 method track). Null = the
    /// events are dropped, which is the right answer for a headless tool.
    method_hook: ?MethodHook = null,

    pub fn init(allocator: std.mem.Allocator) System {
        return .{
            .allocator = allocator,
            .clips = std.AutoHashMap(u32, Clip).init(allocator),
            .path_to_id = std.StringHashMap(u32).init(allocator),
        };
    }

    pub fn deinit(self: *System) void {
        var it = self.clips.valueIterator();
        while (it.next()) |clip| freeClip(self.allocator, @constCast(clip));
        self.clips.deinit();
        var keys = self.path_to_id.keyIterator();
        while (keys.next()) |k| self.allocator.free(@constCast(k.*));
        self.path_to_id.deinit();
    }

    /// Registers `clip` under `id`. The id is the handle a player stores in
    /// `AnimationPlayer.clip_id`, so a caller-supplied id is honoured; `id == 0`
    /// is refused because 0 is the "nothing playing" sentinel.
    pub fn addClip(self: *System, id: u32, clip: Clip) !void {
        try self.setClip(id, clip);
    }

    pub fn addClipWithId(self: *System, id: u32, clip: Clip) !void {
        try self.setClip(id, clip);
    }

    /// Stores `clip` under `id` with ownership transfer, freeing whatever clip
    /// was there. Replacing in place is what makes a hot reload safe.
    pub fn setClip(self: *System, id: u32, clip: Clip) !void {
        if (id == 0) return error.InvalidClipId;
        var c = clip;
        if (c.duration <= 0) c.duration = 0.001;
        if (self.clips.getPtr(id)) |old| freeClip(self.allocator, old);
        try self.clips.put(id, c);
    }

    /// Loads a `.anim` clip from `path` and returns its id, which is the M6
    /// GUID-derived handle `clipIdForPath(path)` — stable across sessions.
    /// Loading a path that is already registered re-decodes it and swaps it in
    /// under the SAME id, preserving any player's playback position (the M13
    /// hot-reload contract).
    pub fn loadFile(self: *System, path: []const u8) !u32 {
        const clip = try decodeFile(self.allocator, path);
        errdefer freeClip(self.allocator, @constCast(&clip));
        const id = clipIdForPath(path);
        // Keyed by path, so `lookupPath` and `preloadDir` can report what is
        // resident. The id is a pure function of the path, so a re-load needs no
        // allocation here beyond the first insert.
        if (self.path_to_id.get(path) == null) {
            const key = try self.allocator.dupe(u8, path);
            errdefer self.allocator.free(key);
            try self.path_to_id.put(key, id);
            errdefer _ = self.path_to_id.remove(path);
        }
        try self.setClip(id, clip);
        return id;
    }

    pub fn lookupPath(self: *const System, path: []const u8) ?u32 {
        return self.path_to_id.get(path);
    }

    /// How a `preloadDir` went: how many `.anim` files decoded, and how many
    /// were skipped because they did not. A file that fails is COUNTED rather
    /// than fatal — one broken clip must not keep the rest of the project's
    /// animation from loading — but it is never silently ignored.
    pub const PreloadReport = struct {
        loaded: usize = 0,
        failed: usize = 0,
    };

    /// Loads every `.anim` file directly inside `dir_path`, returning how many
    /// decoded. The boot-time half of the M13 asset story: the runtime points
    /// this at the project's animation directory, so clips are resident before
    /// the first scene runs and a script references them by their GUID handle.
    ///
    /// Files only — no recursion. The same rule the audio asset watch follows:
    /// one directory is a level's library, and a nested tree is a decision the
    /// project should make explicitly rather than inherit from this loop.
    ///
    /// A missing directory IS an error here (unlike the audio watch), because a
    /// caller that asked for a specific directory and got nothing should hear
    /// about it; the runtime logs it and carries on.
    pub fn preloadDir(self: *System, dir_path: []const u8) !PreloadReport {
        const io = std.Io.Threaded.global_single_threaded.io();
        var dir = try std.Io.Dir.cwd().openDir(io, dir_path, .{ .iterate = true });
        defer dir.close(io);

        var report = PreloadReport{};
        var it = dir.iterate();
        var buf: [512]u8 = undefined;
        while (try it.next(io)) |entry| {
            if (entry.kind == .directory) continue;
            if (!std.mem.endsWith(u8, entry.name, ".anim")) continue;
            // `entry.name` is only valid until the next `next`, so the joined
            // path is built into `buf` and consumed before the loop advances.
            const full = std.fmt.bufPrint(&buf, "{s}/{s}", .{ dir_path, entry.name }) catch {
                report.failed += 1;
                continue;
            };
            _ = self.loadFile(full) catch {
                report.failed += 1;
                continue;
            };
            report.loaded += 1;
        }
        return report;
    }

    pub fn update(self: *System, world: *World, dt: f32, bridge: SignalBridge) void {
        if (dt == 0) return;
        var slot: usize = 0;
        while (slot < world.slotCount()) : (slot += 1) {
            const e = world.entityAtSlot(slot) orelse continue;
            const p = world.get(e, components.AnimationPlayer) orelse continue;
            if (p.clip_id == 0) { p.state = 0; continue; }
            const clip = self.clips.getPtr(p.clip_id) orelse continue;

            p.flags = clip.flags;
            if (p.speed == 0.0) { p.state = 2; continue; }
            p.state = 1;

            const loop = (clip.flags & components.anim_clip_loop) != 0;
            const ping = (clip.flags & components.anim_clip_ping_pong) != 0;
            const dur = clip.duration;

            // Crossfade init
            if (p.next_clip_id != 0 and p.blend_remaining <= 0 and p.blend_duration > 0) {
                p.blend_remaining = p.blend_duration;
                p.next_time = 0.0;
            }
            // The direction the clock is travelling THIS frame, captured before
            // a ping-pong flip rewrites `p.speed`, so method events can tell a
            // forward pass from a backward one.
            const advancing_forward = p.speed > 0.0;
            // advance next
            if (p.next_clip_id != 0) {
                p.next_time += p.speed * dt;
            }

            const old_time = p.time;
            p.time += p.speed * dt;

            var finished = false;
            if (p.speed > 0.0) {
                if (p.time >= dur) {
                    if (loop) {
                        if (ping) {
                            const overshoot = p.time - dur;
                            p.time = dur - overshoot;
                            if (p.time < 0.0) p.time = 0.0;
                            p.speed = -@abs(p.speed);
                        } else {
                            p.time = @mod(p.time, dur);
                        }
                    } else {
                        p.time = dur;
                        finished = true;
                    }
                }
            } else {
                if (p.time <= 0.0) {
                    if (loop) {
                        if (ping) {
                            const overshoot = -p.time;
                            p.time = overshoot;
                            if (p.time > dur) p.time = dur;
                            p.speed = @abs(p.speed);
                        } else {
                            p.time = @mod(p.time, dur);
                        }
                    } else {
                        p.time = 0.0;
                        finished = true;
                    }
                }
            }

            // Cache the mutable target components once; every value track then
            // writes through these without a second lookup. A track whose
            // component the entity lacks is a no-op, like a missing property.
            const t_opt = world.get(e, components.Transform);
            const sp_opt = world.get(e, components.Sprite);
            const light_opt = world.get(e, components.Light2D);
            const cam_opt = world.get(e, components.Camera2D);

            // value tracks
            for (clip.value_tracks) |track| {
                const value = sampleTrack(track.keys, p.time);
                applyValue(track.target, t_opt, sp_opt, light_opt, cam_opt, value);
            }

            // Crossfade weighting for value tracks: read the value the current
            // clip just wrote and move it toward the next clip's, so every
            // target blends, not just position/rotation.
            if (p.next_clip_id != 0 and p.blend_remaining > 0 and p.blend_duration > 0) {
                const w = 1.0 - (p.blend_remaining / p.blend_duration);
                if (self.clips.getPtr(p.next_clip_id)) |nclip| {
                    for (nclip.value_tracks) |ntrack| {
                        const nv = sampleTrack(ntrack.keys, p.next_time);
                        if (readValue(ntrack.target, t_opt, sp_opt, light_opt, cam_opt)) |cur| {
                            applyValue(ntrack.target, t_opt, sp_opt, light_opt, cam_opt, cur + (nv - cur) * w);
                        }
                    }
                }
            }

            // sprite tracks
            for (clip.sprite_tracks) |track| {
                if (track.frames.len == 0) continue;
                if (sp_opt) |sp| {
                    const frame = sampleSprite(track.frames, p.time);
                    var ua = frame.u0;
                    var va = frame.v0;
                    var ub = frame.u1;
                    var vb = frame.v1;
                    if (p.next_clip_id != 0 and p.blend_remaining > 0 and p.blend_duration > 0) {
                        const w = 1.0 - (p.blend_remaining / p.blend_duration);
                        if (self.clips.getPtr(p.next_clip_id)) |nclip| {
                            for (nclip.sprite_tracks) |ntrack| {
                                if (ntrack.frames.len == 0) continue;
                                const nf = sampleSprite(ntrack.frames, p.next_time);
                                ua = ua + (nf.u0 - ua) * w;
                                va = va + (nf.v0 - va) * w;
                                ub = ub + (nf.u1 - ub) * w;
                                vb = vb + (nf.v1 - vb) * w;
                            }
                        }
                    }
                    sp.uv = .{ ua, va, ub, vb };
                }
            }

            // method events — against the segment actually traversed this frame,
            // so a loop wrap or a reverse pass does not swallow an event.
            fireMethodEvents(clip, old_time, p.time, dur, loop, advancing_forward, bridge, self.method_hook);

            // Root motion is NOT applied here: it is a separate pass
            // (`applyRootMotion`) the runtime runs AFTER the physics step, so
            // the solver does not overwrite the displacement (spec M13).

            // crossfade advance
            if (p.next_clip_id != 0 and p.blend_remaining > 0) {
                p.blend_remaining -= dt;
                if (p.blend_remaining <= 0) {
                    // switch clips
                    p.clip_id = p.next_clip_id;
                    p.next_clip_id = 0;
                    p.time = p.next_time;
                    p.next_time = 0.0;
                    p.blend_remaining = 0;
                    p.blend_duration = 0;
                    // reset method fired flags for new clip
                    if (self.clips.getPtr(p.clip_id)) |nc| {
                        for (nc.method_tracks) |*track| for (track.events) |*ev| { ev.fired = false; };
                    }
                    p.state = 1;
                }
            }

            // queue
            if (finished) {
                if (p.queued_count > 0) {
                    p.clip_id = p.queued_0;
                    // shift queue
                    p.queued_0 = p.queued_1;
                    p.queued_1 = p.queued_2;
                    p.queued_2 = p.queued_3;
                    p.queued_3 = 0;
                    if (p.queued_count > 0) p.queued_count -= 1;
                    p.time = 0.0;
                    p.state = 1;
                    // reset method fired
                    resetMethodFired(self, p.clip_id);
                } else {
                    p.state = 3;
                    bridge.fire("animation_finished");
                }
            }
        }
    }

    /// Applies root motion for every playing entity. A SEPARATE pass because it
    /// must run after the physics step: the solver writes `Transform`, and a
    /// displacement applied before it would be overwritten. The runtime calls
    /// this once per fixed tick, after physics and gameplay.
    pub fn applyRootMotion(self: *System, world: *World, dt: f32) void {
        if (dt == 0) return;
        var slot: usize = 0;
        while (slot < world.slotCount()) : (slot += 1) {
            const e = world.entityAtSlot(slot) orelse continue;
            const p = world.get(e, components.AnimationPlayer) orelse continue;
            if (p.clip_id == 0 or p.speed == 0.0 or p.state == 3) continue;
            const clip = self.clips.getPtr(p.clip_id) orelse continue;
            if (!(clip.root_motion or (clip.flags & components.anim_clip_root_motion) != 0)) continue;
            const t = world.get(e, components.Transform) orelse continue;

            var dx = clip.root_motion_dx;
            var dy = clip.root_motion_dy;
            var dr = clip.root_motion_dr;
            if (p.next_clip_id != 0 and p.blend_remaining > 0 and p.blend_duration > 0) {
                const w = 1.0 - (p.blend_remaining / p.blend_duration);
                if (self.clips.getPtr(p.next_clip_id)) |nclip| {
                    if (nclip.root_motion or (nclip.flags & components.anim_clip_root_motion) != 0) {
                        dx = dx + (nclip.root_motion_dx - dx) * w;
                        dy = dy + (nclip.root_motion_dy - dy) * w;
                        dr = dr + (nclip.root_motion_dr - dr) * w;
                    }
                }
            }
            t.position.x += dx * dt;
            t.position.y += dy * dt;
            t.rotation += dr * dt;
        }
    }

    pub fn play(world: *World, entity: @import("entity.zig").Entity, clip_id: u32) void {
        if (world.get(entity, components.AnimationPlayer)) |p| {
            p.clip_id = clip_id;
            p.time = 0.0;
            p.state = 1;
        }
    }

    pub fn stop(world: *World, entity: @import("entity.zig").Entity) void {
        if (world.get(entity, components.AnimationPlayer)) |p| {
            p.clip_id = 0;
            p.time = 0.0;
            p.state = 0;
        }
    }

    pub fn queueClip(world: *World, entity: @import("entity.zig").Entity, clip_id: u32) void {
        if (world.get(entity, components.AnimationPlayer)) |p| {
            if (p.queued_count < 4) {
                switch (p.queued_count) {
                    0 => p.queued_0 = clip_id,
                    1 => p.queued_1 = clip_id,
                    2 => p.queued_2 = clip_id,
                    3 => p.queued_3 = clip_id,
                    else => {},
                }
                p.queued_count += 1;
            }
        }
    }

    fn resetMethodFired(self: *System, clip_id: u32) void {
        if (self.clips.getPtr(clip_id)) |clip| resetFired(clip);
    }
};

/// Releases everything a clip owns. Safe on a zero-value clip and on a clip
/// whose `name_pool` is null (hand-built clips borrow static strings).
pub fn freeClip(alloc: std.mem.Allocator, clip: *Clip) void {
    for (clip.value_tracks) |track| alloc.free(track.keys);
    if (clip.value_tracks.len > 0) alloc.free(clip.value_tracks);
    for (clip.sprite_tracks) |track| alloc.free(track.frames);
    if (clip.sprite_tracks.len > 0) alloc.free(clip.sprite_tracks);
    for (clip.method_tracks) |track| alloc.free(track.events);
    if (clip.method_tracks.len > 0) alloc.free(clip.method_tracks);
    if (clip.name_pool) |pool| alloc.free(pool);
}

// ── Clip asset loading (M13) ────────────────────────────────────────────────
//
// A clip file is a small line-oriented text format, so a clip is diffable and
// an artist can hand-write one. Grammar (whitespace-separated; `#` starts a
// comment; blank lines are ignored; counts keep each line unambiguous):
//
//   clip 1                                   # header, version 1 (required)
//   duration 1.0
//   flags loop ping_pong                     # any of: loop ping_pong root_motion
//   root_motion 0.0 0.0 0.0                  # dx dy dr, units per second
//   value transform_x 2 0.0 0.0 1.0 10.0     # target, key count, then t/value pairs
//   sprite 2 0.0 0.0 0.0 1.0 1.0 0.0 0.0 1.0 1.0  # count, then t u0 v0 u1 v1
//   method 0.5 footstep                      # time, signal name
//   call_lua 0.5 3 on_footstep               # time, script id, Lua method
//
// `parseClip` borrows method-event names from `text`; `decodeFile` keeps the
// file bytes as `Clip.name_pool` so `freeClip` can release them.

pub const ClipParseError = error{ InvalidClip, UnknownTarget };

/// Reads and decodes a `.anim` file. The returned clip owns its arrays AND the
/// file bytes (via `name_pool`); release it with `freeClip`.
pub fn decodeFile(allocator: std.mem.Allocator, path: []const u8) !Clip {
    const io = std.Io.Threaded.global_single_threaded.io();
    const text = try std.Io.Dir.cwd().readFileAlloc(io, path, allocator, .limited(16 * 1024 * 1024));
    errdefer allocator.free(text);
    var clip = try parseClip(allocator, text);
    // Keep the bytes alive: method-event names slice into them.
    clip.name_pool = text;
    return clip;
}

/// Decodes clip text. Names are slices into `text`, so `text` must outlive the
/// clip (or be handed to it via `name_pool`).
///
/// Named `parseClip` rather than `decode` so the asset module's `decode`
/// convention does not imply it read a file.
pub fn parseClip(allocator: std.mem.Allocator, text: []const u8) !Clip {
    var result = Clip{ .name_pool = null };
    errdefer freeClip(allocator, &result);

    var value_tracks: std.ArrayList(ValueTrack) = .empty;
    errdefer {
        for (value_tracks.items) |t| allocator.free(t.keys);
        value_tracks.deinit(allocator);
    }
    var sprite_tracks: std.ArrayList(SpriteTrack) = .empty;
    errdefer {
        for (sprite_tracks.items) |t| allocator.free(t.frames);
        sprite_tracks.deinit(allocator);
    }
    var method_tracks: std.ArrayList(MethodTrack) = .empty;
    errdefer {
        for (method_tracks.items) |t| allocator.free(t.events);
        method_tracks.deinit(allocator);
    }

    var saw_header = false;
    var lines = std.mem.splitScalar(u8, text, '\n');
    while (lines.next()) |raw_line| {
        const line = std.mem.trim(u8, raw_line, " \t\r");
        if (line.len == 0 or line[0] == '#') continue;
        var it = std.mem.tokenizeAny(u8, line, " \t");
        const keyword = it.next() orelse continue;

        if (std.mem.eql(u8, keyword, "clip")) {
            const version = try parseUint(u32, it.next() orelse return error.InvalidClip);
            if (version != 1) return error.InvalidClip;
            saw_header = true;
        } else if (std.mem.eql(u8, keyword, "duration")) {
            result.duration = try parseFloat(it.next() orelse return error.InvalidClip);
        } else if (std.mem.eql(u8, keyword, "flags")) {
            result.flags = 0;
            while (it.next()) |f| {
                if (std.mem.eql(u8, f, "loop")) {
                    result.flags |= components.anim_clip_loop;
                } else if (std.mem.eql(u8, f, "ping_pong")) {
                    result.flags |= components.anim_clip_ping_pong;
                } else if (std.mem.eql(u8, f, "root_motion")) {
                    result.flags |= components.anim_clip_root_motion;
                } else return error.InvalidClip;
            }
        } else if (std.mem.eql(u8, keyword, "root_motion")) {
            result.root_motion = true;
            result.root_motion_dx = try parseFloat(it.next() orelse return error.InvalidClip);
            result.root_motion_dy = try parseFloat(it.next() orelse return error.InvalidClip);
            result.root_motion_dr = try parseFloat(it.next() orelse return error.InvalidClip);
        } else if (std.mem.eql(u8, keyword, "value")) {
            const target = try parseTarget(it.next() orelse return error.InvalidClip);
            const count = try parseUint(usize, it.next() orelse return error.InvalidClip);
            const keys = try allocator.alloc(Keyframe, count);
            errdefer allocator.free(keys);
            for (keys) |*k| {
                k.t = try parseFloat(it.next() orelse return error.InvalidClip);
                k.value = try parseFloat(it.next() orelse return error.InvalidClip);
            }
            try value_tracks.append(allocator, .{ .target = target, .keys = keys });
        } else if (std.mem.eql(u8, keyword, "sprite")) {
            const count = try parseUint(usize, it.next() orelse return error.InvalidClip);
            const frames = try allocator.alloc(SpriteFrame, count);
            errdefer allocator.free(frames);
            for (frames) |*fr| {
                fr.t = try parseFloat(it.next() orelse return error.InvalidClip);
                fr.u0 = try parseFloat(it.next() orelse return error.InvalidClip);
                fr.v0 = try parseFloat(it.next() orelse return error.InvalidClip);
                fr.u1 = try parseFloat(it.next() orelse return error.InvalidClip);
                fr.v1 = try parseFloat(it.next() orelse return error.InvalidClip);
            }
            try sprite_tracks.append(allocator, .{ .frames = frames });
        } else if (std.mem.eql(u8, keyword, "method")) {
            const t = try parseFloat(it.next() orelse return error.InvalidClip);
            const name = it.next() orelse return error.InvalidClip;
            const events = try allocator.alloc(MethodEvent, 1);
            errdefer allocator.free(events);
            events[0] = .{ .t = t, .name = name, .fired = false };
            try method_tracks.append(allocator, .{ .events = events });
        } else if (std.mem.eql(u8, keyword, "call_lua")) {
            // `call_lua <t> <script_id> <fn>` — the M13 method track. The event
            // carries the SCRIPT id and the function name; the runtime's hook
            // calls `fn` on that script's live instances. Both tokens are
            // required: a bare `call_lua 0.5 footstep` is a typo, not a signal.
            // Script 0 is legal (ids start at zero), so it is accepted.
            const t = try parseFloat(it.next() orelse return error.InvalidClip);
            const script_id = try parseUint(u32, it.next() orelse return error.InvalidClip);
            const name = it.next() orelse return error.InvalidClip;
            const events = try allocator.alloc(MethodEvent, 1);
            errdefer allocator.free(events);
            events[0] = .{ .t = t, .name = name, .target_script = script_id, .fired = false };
            try method_tracks.append(allocator, .{ .events = events });
        } else {
            return error.InvalidClip;
        }
    }
    if (!saw_header) return error.InvalidClip;

    result.value_tracks = try value_tracks.toOwnedSlice(allocator);
    result.sprite_tracks = try sprite_tracks.toOwnedSlice(allocator);
    result.method_tracks = try method_tracks.toOwnedSlice(allocator);
    return result;
}

fn parseFloat(tok: []const u8) !f32 {
    return std.fmt.parseFloat(f32, tok) catch error.InvalidClip;
}

fn parseUint(comptime T: type, tok: []const u8) !T {
    return std.fmt.parseInt(T, tok, 10) catch error.InvalidClip;
}

fn parseTarget(tok: []const u8) !TrackTarget {
    const table = .{
        .{ "transform_x", TrackTarget.transform_x },
        .{ "transform_y", TrackTarget.transform_y },
        .{ "transform_rotation", TrackTarget.transform_rotation },
        .{ "sprite_uv_x", TrackTarget.sprite_uv_x },
        .{ "sprite_uv_y", TrackTarget.sprite_uv_y },
        .{ "sprite_tint", TrackTarget.sprite_tint },
        .{ "light_energy", TrackTarget.light_energy },
        .{ "camera_zoom", TrackTarget.camera_zoom },
    };
    inline for (table) |entry| {
        if (std.mem.eql(u8, tok, entry[0])) return entry[1];
    }
    return error.UnknownTarget;
}

/// Fires every not-yet-fired method event that lies on the clock segment
/// `[from, to]` traversed this frame, in the direction of travel.
///
/// On a loop, the segment can cross the clip boundary in one step: the tail of
/// the old pass `(from, dur]` fires first, `fired` is re-armed for the new pass
/// (which is what makes a looping walk cycle produce a footstep every cycle),
/// and then the head `[0, to]` fires.
fn fireMethodEvents(clip: *Clip, from: f32, to: f32, dur: f32, loop: bool, forward: bool, bridge: SignalBridge, hook: ?MethodHook) void {
    if (forward) {
        if (from <= to) {
            fireRange(clip, from, to, true, bridge, hook);
        } else {
            fireRange(clip, from, dur, true, bridge, hook);
            if (loop) resetFired(clip);
            fireRange(clip, 0.0, to, true, bridge, hook);
        }
    } else {
        if (to <= from) {
            fireRange(clip, to, from, false, bridge, hook);
        } else {
            fireRange(clip, 0.0, from, false, bridge, hook);
            if (loop) resetFired(clip);
            fireRange(clip, to, dur, false, bridge, hook);
        }
    }
}

/// `forward` fires events in the half-open interval `(a, b]` (time moving up);
/// otherwise it fires `[b, a)`. The half-open side keeps an event exactly on the
/// current frame from firing twice.
fn fireRange(clip: *Clip, a: f32, b: f32, forward: bool, bridge: SignalBridge, hook: ?MethodHook) void {
    for (clip.method_tracks) |track| {
        for (track.events) |*ev| {
            if (ev.fired) continue;
            const hit = if (forward) (ev.t > a and ev.t <= b) else (ev.t < a and ev.t >= b);
            if (!hit) continue;
            ev.fired = true;
            // A `call_lua` event targets one script's live instances and does
            // NOT also fire a signal: the two dispatch paths would otherwise
            // both deliver the same footstep (the signal to EVERY listener, the
            // call to the named one). A plain `method` event is unchanged.
            if (ev.target_script) |sid| {
                if (hook) |h| {
                    if (h.call) |call| call(h.ctx, sid, ev.name);
                }
            } else {
                bridge.fire(ev.name);
            }
        }
    }
}

fn resetFired(clip: *Clip) void {
    for (clip.method_tracks) |track| {
        for (track.events) |*ev| ev.fired = false;
    }
}

/// Writes one value track's sampled value into the target component. A target
/// whose component the entity does not carry is ignored, like a missing field.
fn applyValue(
    target: TrackTarget,
    t: ?*components.Transform,
    sp: ?*components.Sprite,
    light: ?*components.Light2D,
    cam: ?*components.Camera2D,
    value: f32,
) void {
    switch (target) {
        .transform_x => {
            if (t) |x| x.position.x = value;
        },
        .transform_y => {
            if (t) |x| x.position.y = value;
        },
        .transform_rotation => {
            if (t) |x| x.rotation = value;
        },
        .sprite_uv_x => {
            if (sp) |s| s.uv[0] = value;
        },
        .sprite_uv_y => {
            if (sp) |s| s.uv[1] = value;
        },
        // A scalar tint is brightness: RGB follow the value, alpha is kept so a
        // fade authored on alpha is not clobbered.
        .sprite_tint => {
            if (sp) |s| {
                s.tint[0] = value;
                s.tint[1] = value;
                s.tint[2] = value;
            }
        },
        .light_energy => {
            if (light) |l| l.energy = value;
        },
        .camera_zoom => {
            if (cam) |c| c.zoom = value;
        },
    }
}

/// Reads a target's current value, for crossfade blending. Null when the entity
/// does not carry the target's component.
fn readValue(
    target: TrackTarget,
    t: ?*components.Transform,
    sp: ?*components.Sprite,
    light: ?*components.Light2D,
    cam: ?*components.Camera2D,
) ?f32 {
    return switch (target) {
        .transform_x => if (t) |x| x.position.x else null,
        .transform_y => if (t) |x| x.position.y else null,
        .transform_rotation => if (t) |x| x.rotation else null,
        .sprite_uv_x => if (sp) |s| s.uv[0] else null,
        .sprite_uv_y => if (sp) |s| s.uv[1] else null,
        .sprite_tint => if (sp) |s| s.tint[0] else null,
        .light_energy => if (light) |l| l.energy else null,
        .camera_zoom => if (cam) |c| c.zoom else null,
    };
}

fn sampleTrack(keys: []const Keyframe, t: f32) f32 {
    if (keys.len == 0) return 0.0;
    if (t <= keys[0].t) return keys[0].value;
    if (t >= keys[keys.len - 1].t) return keys[keys.len - 1].value;
    var i: usize = 0;
    while (i + 1 < keys.len) : (i += 1) {
        if (t >= keys[i].t and t <= keys[i + 1].t) {
            const span = keys[i + 1].t - keys[i].t;
            if (span <= 0.0) return keys[i + 1].value;
            const u = (t - keys[i].t) / span;
            return keys[i].value + (keys[i + 1].value - keys[i].value) * u;
        }
    }
    return keys[keys.len - 1].value;
}

fn sampleSprite(frames: []const SpriteFrame, t: f32) SpriteFrame {
    if (frames.len == 0) return .{ .t = 0, .u0 = 0, .v0 = 0, .u1 = 1, .v1 = 1 };
    if (t <= frames[0].t) return frames[0];
    if (t >= frames[frames.len - 1].t) return frames[frames.len - 1];
    var i: usize = 0;
    while (i + 1 < frames.len) : (i += 1) {
        if (t >= frames[i].t and t <= frames[i + 1].t) return frames[i];
    }
    return frames[frames.len - 1];
}

// Back-compat tests (retain simple ones)
const testing = std.testing;

const Recorder = struct {
    names: [16][]const u8 = undefined,
    len: usize = 0,
    fn record(ctx: ?*anyopaque, name: []const u8) void {
        const self: *Recorder = @ptrCast(@alignCast(ctx.?));
        if (self.len < self.names.len) {
            self.names[self.len] = name;
            self.len += 1;
        }
    }
    fn bridge(self: *Recorder) SignalBridge {
        return .{ .ctx = self, .dispatch = Recorder.record };
    }
};

test "clip advances and fires animation_finished when non-looping" {
    var world = World.init(testing.allocator);
    defer world.deinit();
    var sys = System.init(testing.allocator);
    defer sys.deinit();
    try sys.addClipWithId(1, .{ .duration = 1.0, .flags = 0 });

    const e = try world.spawn(.{ components.AnimationPlayer{ .clip_id = 1, .speed = 1.0 }, components.Transform{} });

    var rec = Recorder{};
    sys.update(&world, 0.6, rec.bridge());
    try testing.expectEqual(@as(f32, 0.6), world.get(e, components.AnimationPlayer).?.time);
    try testing.expectEqual(@as(u32, 1), world.get(e, components.AnimationPlayer).?.state);
    sys.update(&world, 0.6, rec.bridge());
    const p = world.get(e, components.AnimationPlayer).?;
    try testing.expectEqual(@as(f32, 1.0), p.time);
    try testing.expectEqual(@as(u32, 3), p.state);
    try testing.expectEqual(@as(usize, 1), rec.len);
}

test "root motion moves transform deterministically" {
    var world = World.init(testing.allocator);
    defer world.deinit();
    var sys = System.init(testing.allocator);
    defer sys.deinit();
    try sys.addClipWithId(7, .{ .duration = 2.0, .flags = components.anim_clip_loop, .root_motion = true, .root_motion_dx = 10.0 });

    const e = try world.spawn(.{ components.AnimationPlayer{ .clip_id = 7 }, components.Transform{} });

    var rec = Recorder{};
    sys.update(&world, 0.5, rec.bridge());
    // `update` samples and advances but does NOT move the actor: root motion is
    // the post-physics pass.
    try testing.expectApproxEqAbs(@as(f32, 0.0), world.get(e, components.Transform).?.position.x, 1e-5);
    sys.applyRootMotion(&world, 0.5);
    const t = world.get(e, components.Transform).?;
    try testing.expectApproxEqAbs(@as(f32, 5.0), t.position.x, 1e-5);
}

test "crossfade interpolates values" {
    var world = World.init(testing.allocator);
    defer world.deinit();
    var sys = System.init(testing.allocator);
    defer sys.deinit();

    var clip_a: Clip = .{ .duration = 1.0, .flags = 0 };
    const ka = try testing.allocator.dupe(Keyframe, &[_]Keyframe{ .{ .t = 0.0, .value = 0.0 }, .{ .t = 1.0, .value = 0.0 } });
    const ta = try testing.allocator.dupe(ValueTrack, &[_]ValueTrack{ .{ .target = .transform_x, .keys = ka } });
    clip_a.value_tracks = ta;
    try sys.addClipWithId(1, clip_a);

    var clip_b: Clip = .{ .duration = 1.0, .flags = 0 };
    const kb = try testing.allocator.dupe(Keyframe, &[_]Keyframe{ .{ .t = 0.0, .value = 10.0 }, .{ .t = 1.0, .value = 10.0 } });
    const tb = try testing.allocator.dupe(ValueTrack, &[_]ValueTrack{ .{ .target = .transform_x, .keys = kb } });
    clip_b.value_tracks = tb;
    try sys.addClipWithId(2, clip_b);

    const e = try world.spawn(.{ components.AnimationPlayer{
        .clip_id = 1,
        .next_clip_id = 2,
        .speed = 0.0,
        .blend_duration = 1.0,
        .blend_remaining = 0.0,
        .state = 1,
    }, components.Transform{} });

    // speed 0 avoids time motion; manually set
    world.get(e, components.AnimationPlayer).?.speed = 1.0;
    var rec = Recorder{};
    // frame 1: weight near 0
    sys.update(&world, 0.25, rec.bridge());
    const t1 = world.get(e, components.Transform).?.position.x;
    // should be closer to 0
    try testing.expect(t1 < 5.0);
    // frame 2 advances blend
    sys.update(&world, 0.5, rec.bridge());
    const t2 = world.get(e, components.Transform).?.position.x;
    try testing.expect(t2 > t1);
}

test "root motion rotation" {
    var world = World.init(testing.allocator);
    defer world.deinit();
    var sys = System.init(testing.allocator);
    defer sys.deinit();
    try sys.addClipWithId(9, .{ .duration = 2.0, .flags = components.anim_clip_loop, .root_motion = true, .root_motion_dr = 4.0 });
    const e = try world.spawn(.{ components.AnimationPlayer{ .clip_id = 9 }, components.Transform{} });
    var rec = Recorder{};
    sys.update(&world, 0.5, rec.bridge());
    sys.applyRootMotion(&world, 0.5);
    const t = world.get(e, components.Transform).?;
    try testing.expectApproxEqAbs(@as(f32, 2.0), t.rotation, 1e-5);
}

test "value track evaluates" {
    var world = World.init(testing.allocator);
    defer world.deinit();
    var sys = System.init(testing.allocator);
    defer sys.deinit();
    var clip: Clip = .{ .duration = 1.0, .flags = 0 };
    const keys = try testing.allocator.dupe(Keyframe, &[_]Keyframe{ .{ .t = 0.0, .value = 0.0 }, .{ .t = 1.0, .value = 10.0 } });
    const tracks = try testing.allocator.dupe(ValueTrack, &[_]ValueTrack{ .{ .target = .transform_x, .keys = keys } });
    clip.value_tracks = tracks;
    try sys.addClipWithId(2, clip);

    const e = try world.spawn(.{ components.AnimationPlayer{ .clip_id = 2, .speed = 1.0 }, components.Transform{} });
    var rec = Recorder{};
    sys.update(&world, 0.5, rec.bridge());
    const t = world.get(e, components.Transform).?;
    try testing.expectApproxEqAbs(@as(f32, 5.0), t.position.x, 1e-5);
}

test "method event fires once" {
    var world = World.init(testing.allocator);
    defer world.deinit();
    var sys = System.init(testing.allocator);
    defer sys.deinit();
    var clip: Clip = .{ .duration = 1.0, .flags = 0 };
    const events = try testing.allocator.alloc(MethodEvent, 1);
    events[0] = .{ .t = 0.25, .name = "footstep", .fired = false };
    const mtracks = try testing.allocator.dupe(MethodTrack, &[_]MethodTrack{ .{ .events = events[0..] } });
    clip.method_tracks = mtracks;
    try sys.addClipWithId(3, clip);

    _ = try world.spawn(.{ components.AnimationPlayer{ .clip_id = 3, .speed = 1.0 }, components.Transform{} });
    var rec = Recorder{};
    sys.update(&world, 0.5, rec.bridge());
    // event fired
    try testing.expectEqual(@as(usize, 1), rec.len);
    // update again should not re-fire
    sys.update(&world, 0.1, rec.bridge());
    try testing.expectEqual(@as(usize, 1), rec.len);
}

test "looping clip re-fires its method events each cycle" {
    var world = World.init(testing.allocator);
    defer world.deinit();
    var sys = System.init(testing.allocator);
    defer sys.deinit();
    var clip: Clip = .{ .duration = 1.0, .flags = components.anim_clip_loop };
    const events = try testing.allocator.alloc(MethodEvent, 1);
    events[0] = .{ .t = 0.5, .name = "footstep" };
    clip.method_tracks = try testing.allocator.dupe(MethodTrack, &[_]MethodTrack{.{ .events = events }});
    try sys.addClipWithId(4, clip);

    _ = try world.spawn(.{ components.AnimationPlayer{ .clip_id = 4, .speed = 1.0 }, components.Transform{} });
    var rec = Recorder{};
    sys.update(&world, 0.6, rec.bridge()); // 0.0 -> 0.6: fires
    sys.update(&world, 0.4, rec.bridge()); // 0.6 -> 1.0: already fired
    try testing.expectEqual(@as(usize, 1), rec.len);
    sys.update(&world, 0.6, rec.bridge()); // 1.0 -> wraps to 0.6: fires again
    try testing.expectEqual(@as(usize, 2), rec.len);
}

test "an event before the loop end fires even when the tick wraps past it" {
    var world = World.init(testing.allocator);
    defer world.deinit();
    var sys = System.init(testing.allocator);
    defer sys.deinit();
    var clip: Clip = .{ .duration = 1.0, .flags = components.anim_clip_loop };
    const events = try testing.allocator.alloc(MethodEvent, 1);
    events[0] = .{ .t = 0.9, .name = "footstep" };
    clip.method_tracks = try testing.allocator.dupe(MethodTrack, &[_]MethodTrack{.{ .events = events }});
    try sys.addClipWithId(5, clip);

    _ = try world.spawn(.{ components.AnimationPlayer{ .clip_id = 5, .speed = 1.0 }, components.Transform{} });
    var rec = Recorder{};
    sys.update(&world, 0.5, rec.bridge()); // 0.0 -> 0.5: not yet
    try testing.expectEqual(@as(usize, 0), rec.len);
    sys.update(&world, 0.6, rec.bridge()); // 0.5 -> 1.1 wraps to 0.1: 0.9 is in the tail
    try testing.expectEqual(@as(usize, 1), rec.len);
}

test "root motion flag alone enables root motion" {
    var world = World.init(testing.allocator);
    defer world.deinit();
    var sys = System.init(testing.allocator);
    defer sys.deinit();
    try sys.addClipWithId(8, .{
        .duration = 2.0,
        .flags = components.anim_clip_loop | components.anim_clip_root_motion,
        .root_motion_dx = 10.0,
    });

    const e = try world.spawn(.{ components.AnimationPlayer{ .clip_id = 8 }, components.Transform{} });
    var rec = Recorder{};
    sys.update(&world, 0.5, rec.bridge());
    sys.applyRootMotion(&world, 0.5);
    try testing.expectApproxEqAbs(@as(f32, 5.0), world.get(e, components.Transform).?.position.x, 1e-5);
}

test "reverse loop wraps into the clip instead of past the end" {
    var world = World.init(testing.allocator);
    defer world.deinit();
    var sys = System.init(testing.allocator);
    defer sys.deinit();
    try sys.addClipWithId(6, .{ .duration = 1.0, .flags = components.anim_clip_loop });

    const e = try world.spawn(.{ components.AnimationPlayer{ .clip_id = 6, .speed = -1.0, .time = 0.1 }, components.Transform{} });
    var rec = Recorder{};
    sys.update(&world, 0.2, rec.bridge()); // 0.1 -> -0.1 wraps to 0.9, not 1.9
    const p = world.get(e, components.AnimationPlayer).?;
    try testing.expectApproxEqAbs(@as(f32, 0.9), p.time, 1e-5);
}

// ── Clip asset loading (M13) ────────────────────────────────────────────────

test "clip text parses flags, tracks and method events" {
    const text =
        \\clip 1
        \\duration 2.0
        \\flags loop ping_pong
        \\root_motion 10.0 0.0 0.0
        \\value transform_x 2 0.0 0.0 2.0 20.0
        \\sprite 2 0.0 0.0 0.0 1.0 1.0 1.0 0.0 0.0 1.0 1.0
        \\method 0.5 footstep
    ;
    var clip = try parseClip(testing.allocator, text);
    defer freeClip(testing.allocator, &clip);

    try testing.expectEqual(@as(f32, 2.0), clip.duration);
    try testing.expect((clip.flags & components.anim_clip_loop) != 0);
    try testing.expect((clip.flags & components.anim_clip_ping_pong) != 0);
    try testing.expect(clip.root_motion);
    try testing.expectApproxEqAbs(@as(f32, 10.0), clip.root_motion_dx, 1e-6);

    try testing.expectEqual(@as(usize, 1), clip.value_tracks.len);
    try testing.expectEqual(TrackTarget.transform_x, clip.value_tracks[0].target);
    try testing.expectEqual(@as(usize, 2), clip.value_tracks[0].keys.len);
    try testing.expectApproxEqAbs(@as(f32, 20.0), clip.value_tracks[0].keys[1].value, 1e-6);

    try testing.expectEqual(@as(usize, 1), clip.sprite_tracks.len);
    try testing.expectEqual(@as(usize, 2), clip.sprite_tracks[0].frames.len);

    try testing.expectEqual(@as(usize, 1), clip.method_tracks.len);
    try testing.expectEqualStrings("footstep", clip.method_tracks[0].events[0].name);
}

test "an unknown value target is rejected" {
    const text = "clip 1\nduration 1.0\nvalue nonsense 1 0 0\n";
    try testing.expectError(error.UnknownTarget, parseClip(testing.allocator, text));
}

test "clip file loads, plays, and hot-reloads under the same id" {
    var world = World.init(testing.allocator);
    defer world.deinit();
    var sys = System.init(testing.allocator);
    defer sys.deinit();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var buf: [512]u8 = undefined;
    const path = try std.fmt.bufPrint(&buf, ".zig-cache/tmp/{s}/run.anim", .{tmp.sub_path});
    const io = std.Io.Threaded.global_single_threaded.io();

    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = path, .data =
        \\clip 1
        \\duration 1.0
        \\flags loop
        \\value transform_x 2 0.0 0.0 1.0 10.0
    });

    const id = try sys.loadFile(path);
    // The id is the path's GUID handle, not a counter: it names the asset.
    try testing.expectEqual(clipIdForPath(path), id);
    try testing.expectEqual(@as(f32, 1.0), sys.clips.get(id).?.duration);

    const e = try world.spawn(.{ components.AnimationPlayer{ .clip_id = id, .speed = 1.0 }, components.Transform{} });
    var rec = Recorder{};
    sys.update(&world, 0.25, rec.bridge());
    const t_before = world.get(e, components.AnimationPlayer).?.time;
    try testing.expect(t_before > 0.0);

    // Rewrite with a longer clip and reload: same id, playback time untouched.
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = path, .data =
        \\clip 1
        \\duration 5.0
        \\flags loop
        \\value transform_x 2 0.0 0.0 5.0 50.0
    });
    const id2 = try sys.loadFile(path);
    try testing.expectEqual(id, id2);
    try testing.expectEqual(@as(f32, 5.0), sys.clips.get(id).?.duration);
    try testing.expectEqual(t_before, world.get(e, components.AnimationPlayer).?.time);
}

test "value tracks reach sprite, light and camera components" {
    var world = World.init(testing.allocator);
    defer world.deinit();
    var sys = System.init(testing.allocator);
    defer sys.deinit();

    var clip: Clip = .{ .duration = 1.0, .flags = 0 };
    const tint_keys = try testing.allocator.dupe(Keyframe, &[_]Keyframe{ .{ .t = 0.0, .value = 0.0 }, .{ .t = 1.0, .value = 2.0 } });
    const energy_keys = try testing.allocator.dupe(Keyframe, &[_]Keyframe{ .{ .t = 0.0, .value = 0.0 }, .{ .t = 1.0, .value = 4.0 } });
    const zoom_keys = try testing.allocator.dupe(Keyframe, &[_]Keyframe{ .{ .t = 0.0, .value = 1.0 }, .{ .t = 1.0, .value = 3.0 } });
    const uv_keys = try testing.allocator.dupe(Keyframe, &[_]Keyframe{ .{ .t = 0.0, .value = 0.0 }, .{ .t = 1.0, .value = 0.5 } });
    clip.value_tracks = try testing.allocator.dupe(ValueTrack, &[_]ValueTrack{
        .{ .target = .sprite_tint, .keys = tint_keys },
        .{ .target = .light_energy, .keys = energy_keys },
        .{ .target = .camera_zoom, .keys = zoom_keys },
        .{ .target = .sprite_uv_x, .keys = uv_keys },
    });
    try sys.addClipWithId(10, clip);

    const e = try world.spawn(.{
        components.AnimationPlayer{ .clip_id = 10, .speed = 1.0 },
        components.Transform{},
        components.Sprite{},
        components.Light2D{},
        components.Camera2D{},
    });
    var rec = Recorder{};
    sys.update(&world, 0.5, rec.bridge());

    try testing.expectApproxEqAbs(@as(f32, 1.0), world.get(e, components.Sprite).?.tint[0], 1e-5);
    try testing.expectApproxEqAbs(@as(f32, 2.0), world.get(e, components.Light2D).?.energy, 1e-5);
    try testing.expectApproxEqAbs(@as(f32, 2.0), world.get(e, components.Camera2D).?.zoom, 1e-5);
    try testing.expectApproxEqAbs(@as(f32, 0.25), world.get(e, components.Sprite).?.uv[0], 1e-5);
}

test "crossfade blends a non-transform target too" {
    var world = World.init(testing.allocator);
    defer world.deinit();
    var sys = System.init(testing.allocator);
    defer sys.deinit();

    var clip_a: Clip = .{ .duration = 1.0, .flags = 0 };
    clip_a.value_tracks = try testing.allocator.dupe(ValueTrack, &[_]ValueTrack{
        .{ .target = .sprite_tint, .keys = try testing.allocator.dupe(Keyframe, &[_]Keyframe{ .{ .t = 0.0, .value = 0.0 }, .{ .t = 1.0, .value = 0.0 } }) },
    });
    try sys.addClipWithId(11, clip_a);

    var clip_b: Clip = .{ .duration = 1.0, .flags = 0 };
    clip_b.value_tracks = try testing.allocator.dupe(ValueTrack, &[_]ValueTrack{
        .{ .target = .sprite_tint, .keys = try testing.allocator.dupe(Keyframe, &[_]Keyframe{ .{ .t = 0.0, .value = 10.0 }, .{ .t = 1.0, .value = 10.0 } }) },
    });
    try sys.addClipWithId(12, clip_b);

    const e = try world.spawn(.{
        components.AnimationPlayer{
            .clip_id = 11,
            .next_clip_id = 12,
            .speed = 1.0,
            .blend_duration = 1.0,
            .blend_remaining = 0.0,
            .state = 1,
        },
        components.Transform{},
        components.Sprite{},
    });
    var rec = Recorder{};
    // Frame 1 arms the blend (weight 0); frame 2 is halfway from 0 to 10.
    sys.update(&world, 0.5, rec.bridge());
    sys.update(&world, 0.5, rec.bridge());

    try testing.expectApproxEqAbs(@as(f32, 5.0), world.get(e, components.Sprite).?.tint[0], 1e-4);
}

// ── M13: clip identity, preload and the method track ───────────────────────

test "a clip id is the path's GUID handle: stable, non-zero, path-only" {
    // Same path, same id — across Systems, across sessions, no table shared.
    const a = clipIdForPath("assets/animations/run.anim");
    const b = clipIdForPath("assets/animations/run.anim");
    try testing.expectEqual(a, b);
    try testing.expect(a != 0); // 0 is the "nothing playing" sentinel
    // A different path is a different handle (32-bit collision aside).
    try testing.expect(a != clipIdForPath("assets/animations/idle.anim"));

    // Two independent systems agree on the handle with no shared state: the
    // property a scene or a script relies on when it names the path.
    var s1 = System.init(testing.allocator);
    defer s1.deinit();
    var s2 = System.init(testing.allocator);
    defer s2.deinit();
    try s1.addClip(clipIdForPath("x.anim"), .{ .duration = 1.0 });
    try s2.addClip(clipIdForPath("x.anim"), .{ .duration = 1.0 });
    try testing.expect(s1.clips.contains(clipIdForPath("x.anim")));
    try testing.expect(s2.clips.contains(clipIdForPath("x.anim")));
}

test "preloadDir loads every .anim in a directory and counts the broken one" {
    var sys = System.init(testing.allocator);
    defer sys.deinit();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const io = std.Io.Threaded.global_single_threaded.io();

    var ibuf: [256]u8 = undefined;
    const idle = try std.fmt.bufPrint(&ibuf, ".zig-cache/tmp/{s}/idle.anim", .{tmp.sub_path});
    var rbuf: [256]u8 = undefined;
    const run = try std.fmt.bufPrint(&rbuf, ".zig-cache/tmp/{s}/run.anim", .{tmp.sub_path});
    var dbuf: [256]u8 = undefined;
    const ignored = try std.fmt.bufPrint(&dbuf, ".zig-cache/tmp/{s}/notes.txt", .{tmp.sub_path});
    var bbuf: [256]u8 = undefined;
    const broken = try std.fmt.bufPrint(&bbuf, ".zig-cache/tmp/{s}/broken.anim", .{tmp.sub_path});

    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = idle, .data = "clip 1\nduration 1.0\nflags loop\n" });
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = run, .data = "clip 1\nduration 2.0\nflags loop\n" });
    // Not a clip: a non-`.anim` file is skipped entirely, not counted as a
    // failure.
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = ignored, .data = "just a note\n" });
    // A `.anim` that does not parse: counted as failed, and the OTHER two still
    // load. One broken clip must not blank the project's animation.
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = broken, .data = "not a clip at all\n" });

    var dirbuf: [256]u8 = undefined;
    const dir_path = try std.fmt.bufPrint(&dirbuf, ".zig-cache/tmp/{s}", .{tmp.sub_path});
    const report = try sys.preloadDir(dir_path);
    try testing.expectEqual(@as(usize, 2), report.loaded);
    try testing.expectEqual(@as(usize, 1), report.failed);
    // The loaded clips are the real ones, under their GUID handles.
    try testing.expectEqual(clipIdForPath(idle), sys.lookupPath(idle).?);
    try testing.expectEqual(@as(f32, 2.0), sys.clips.get(clipIdForPath(run)).?.duration);
}

test "preloadDir on a missing directory is an error the caller can log" {
    var sys = System.init(testing.allocator);
    defer sys.deinit();
    try testing.expectError(error.FileNotFound, sys.preloadDir(".zig-cache/no-such-animation-dir"));
}

test "a call_lua method event parses its script id and function name" {
    const text =
        \\clip 1
        \\duration 1.0
        \\call_lua 0.5 7 on_footstep
    ;
    var clip = try parseClip(testing.allocator, text);
    defer freeClip(testing.allocator, &clip);
    try testing.expectEqual(@as(usize, 1), clip.method_tracks.len);
    const ev = clip.method_tracks[0].events[0];
    try testing.expectEqual(@as(u32, 7), ev.target_script.?);
    try testing.expectEqualStrings("on_footstep", ev.name);
    try testing.expectApproxEqAbs(@as(f32, 0.5), ev.t, 1e-6);

    // A plain `method` line is a signal, not a targeted call: no target script.
    var signal_clip = try parseClip(testing.allocator, "clip 1\nduration 1.0\nmethod 0.5 step\n");
    defer freeClip(testing.allocator, &signal_clip);
    try testing.expect(signal_clip.method_tracks[0].events[0].target_script == null);

    // Script 0 is a LEGAL id (scripts are numbered from zero), so a call that
    // targets it must parse — that is why "no target" is `null` and not 0.
    var zero_clip = try parseClip(testing.allocator, "clip 1\nduration 1.0\ncall_lua 0.5 0 fn\n");
    defer freeClip(testing.allocator, &zero_clip);
    try testing.expectEqual(@as(?u32, 0), zero_clip.method_tracks[0].events[0].target_script);

    // The id is required: without one this is neither a call nor a signal.
    try testing.expectError(error.InvalidClip, parseClip(testing.allocator, "clip 1\nduration 1.0\ncall_lua 0.5\n"));
}

/// Records `call_lua` dispatches, the way `Recorder` records signals.
const CallRecorder = struct {
    count: usize = 0,
    script_id: u32 = 0,
    last: []const u8 = "",

    fn call(ctx: ?*anyopaque, script_id: u32, name: []const u8) void {
        const self: *CallRecorder = @ptrCast(@alignCast(ctx.?));
        self.count += 1;
        self.script_id = script_id;
        self.last = name;
    }

    fn hook(self: *CallRecorder) MethodHook {
        return .{ .ctx = self, .call = CallRecorder.call };
    }
};

test "a call_lua event reaches the hook and does NOT fire a signal" {
    var world = World.init(testing.allocator);
    defer world.deinit();
    var sys = System.init(testing.allocator);
    defer sys.deinit();

    var calls = CallRecorder{};
    sys.method_hook = calls.hook();

    var clip: Clip = .{ .duration = 1.0, .flags = 0 };
    const events = try testing.allocator.alloc(MethodEvent, 1);
    events[0] = .{ .t = 0.25, .name = "on_footstep", .target_script = 7 };
    clip.method_tracks = try testing.allocator.dupe(MethodTrack, &[_]MethodTrack{.{ .events = events }});
    try sys.addClipWithId(13, clip);

    _ = try world.spawn(.{ components.AnimationPlayer{ .clip_id = 13, .speed = 1.0 }, components.Transform{} });
    var rec = Recorder{};
    sys.update(&world, 0.5, rec.bridge());

    try testing.expectEqual(@as(usize, 1), calls.count);
    try testing.expectEqual(@as(u32, 7), calls.script_id);
    try testing.expectEqualStrings("on_footstep", calls.last);
    // The signal bridge saw nothing: a `call_lua` event is targeted, not
    // broadcast, so the two dispatch paths cannot double-deliver it.
    try testing.expectEqual(@as(usize, 0), rec.len);
}

test "a call_lua event without a hook is a no-op, and still fires once" {
    var world = World.init(testing.allocator);
    defer world.deinit();
    var sys = System.init(testing.allocator);
    defer sys.deinit();

    var clip: Clip = .{ .duration = 1.0, .flags = 0 };
    const events = try testing.allocator.alloc(MethodEvent, 1);
    events[0] = .{ .t = 0.25, .name = "on_footstep", .target_script = 7 };
    clip.method_tracks = try testing.allocator.dupe(MethodTrack, &[_]MethodTrack{.{ .events = events }});
    try sys.addClipWithId(14, clip);

    _ = try world.spawn(.{ components.AnimationPlayer{ .clip_id = 14, .speed = 1.0 }, components.Transform{} });
    var rec = Recorder{};
    sys.update(&world, 0.5, rec.bridge());
    // No hook, no crash, no signal: the event is consumed and marked fired.
    try testing.expectEqual(@as(usize, 0), rec.len);
    try testing.expect(sys.clips.get(14).?.method_tracks[0].events[0].fired);
}
