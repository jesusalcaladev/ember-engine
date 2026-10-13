const std = @import("std");

pub const TrackTarget = enum(u8) {
    transform_x,
    transform_y,
    transform_rotation,
    sprite_uv_x,
    sprite_uv_y,
    sprite_tint,
    light_energy,
    camera_zoom,
};

pub const Keyframe = struct {
    t: f32,
    value: f32,
};

pub const ValueTrack = struct {
    target: TrackTarget,
    keys: []const Keyframe,
};

pub const SpriteFrame = struct {
    t: f32,
    u0: f32,
    v0: f32,
    u1: f32,
    v1: f32,
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
    events: []const MethodEvent,
};

pub const Clip = struct {
    id: u32,
    guid: u64,
    duration: f32,
    flags: u8,
    value_tracks: []const ValueTrack = &.{},
    sprite_tracks: []const SpriteTrack = &.{},
    method_tracks: []const MethodTrack = &.{},
    root_motion: bool = false,
    root_motion_dx: f32 = 0.0,
    root_motion_dy: f32 = 0.0,
    root_motion_dr: f32 = 0.0,
};

pub fn deinitClip(alloc: std.mem.Allocator, clip: *Clip) void {
    for (clip.value_tracks) |track| alloc.free(track.keys);
    if (clip.value_tracks.len > 0) alloc.free(clip.value_tracks);
    for (clip.sprite_tracks) |track| alloc.free(track.frames);
    if (clip.sprite_tracks.len > 0) alloc.free(clip.sprite_tracks);
    for (clip.method_tracks) |track| alloc.free(track.events);
    if (clip.method_tracks.len > 0) alloc.free(clip.method_tracks);
}
