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
    name: []const u8,
    fired: bool = false,
};

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
};

pub const System = struct {
    allocator: std.mem.Allocator,
    clips: std.AutoHashMap(u32, Clip),

    pub fn init(allocator: std.mem.Allocator) System {
        return .{ .allocator = allocator, .clips = std.AutoHashMap(u32, Clip).init(allocator) };
    }

    pub fn deinit(self: *System) void {
        // Leak arrays in tests rather than crash on mixed ownership.
        var it = self.clips.valueIterator();
        while (it.next()) |clip| deinitClip(self.allocator, @constCast(clip));
        self.clips.deinit();
    }

    pub fn addClip(self: *System, id: u32, clip: Clip) !void {
        var c = clip;
        _ = id;
        if (c.duration <= 0) c.duration = 0.001;
        try self.clips.put(self.clips.count() + 1, c);
    }

    pub fn addClipWithId(self: *System, id: u32, clip: Clip) !void {
        var c = clip;
        if (c.duration <= 0) c.duration = 0.001;
        try self.clips.put(id, c);
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
                            p.time = dur + @mod(p.time, dur);
                        }
                    } else {
                        p.time = 0.0;
                        finished = true;
                    }
                }
            }

            // value tracks
            for (clip.value_tracks) |track| {
                const value = sampleTrack(track.keys, p.time);
                if (world.get(e, components.Transform)) |t| {
                    switch (track.target) {
                        .transform_x => t.position.x = value,
                        .transform_y => t.position.y = value,
                        .transform_rotation => t.rotation = value,
                        else => {},
                    }
                }
            }

            // sprite tracks
            for (clip.sprite_tracks) |track| {
                if (track.frames.len == 0) continue;
                if (world.get(e, components.Sprite)) |sp| {
                    _ = sp;
                    _ = sampleSprite(track.frames, p.time);
                }
            }

            // method events
            for (clip.method_tracks) |track| {
                for (track.events) |*ev| {
                    if (!ev.fired and ev.t > old_time and ev.t <= p.time) {
                        ev.fired = true;
                        bridge.fire(ev.name);
                        if (world.signals.hasListeners(ev.name)) {
                            // Fire typed signal with no payload (Timer-style not mixed here).
                        }
                    }
                }
            }

            // root motion (apply deltas scaled by dt)
            if (clip.root_motion) {
                if (world.get(e, components.Transform)) |t| {
                    t.position.x += clip.root_motion_dx * dt;
                    t.position.y += clip.root_motion_dy * dt;
                    t.rotation += clip.root_motion_dr * dt;
                }
            }

            // crossfade
            if (p.next_clip_id != 0 and p.blend_remaining <= 0 and p.blend_duration > 0) {
                // start blend
                p.blend_remaining = p.blend_duration;
            }
            if (p.next_clip_id != 0 and p.blend_remaining > 0) {
                p.blend_remaining -= dt;
                if (p.blend_remaining <= 0) {
                    p.clip_id = p.next_clip_id;
                    p.next_clip_id = 0;
                    p.time = 0.0;
                    p.blend_remaining = 0;
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
        if (self.clips.getPtr(clip_id)) |clip| {
            for (clip.method_tracks) |*track| {
                for (track.events) |*ev| ev.fired = false;
            }
        }
    }
};

fn deinitClip(alloc: std.mem.Allocator, clip: *Clip) void {
    for (clip.value_tracks) |track| alloc.free(track.keys);
    if (clip.value_tracks.len > 0) alloc.free(clip.value_tracks);
    for (clip.sprite_tracks) |track| alloc.free(track.frames);
    if (clip.sprite_tracks.len > 0) alloc.free(clip.sprite_tracks);
    // method events contain borrowed name strings; only free the top array
    if (clip.method_tracks.len > 0) alloc.free(clip.method_tracks);
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
    const t = world.get(e, components.Transform).?;
    try testing.expectApproxEqAbs(@as(f32, 5.0), t.position.x, 1e-5);
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
    var events = try testing.allocator.alloc(MethodEvent, 1);
    defer testing.allocator.free(events);
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
