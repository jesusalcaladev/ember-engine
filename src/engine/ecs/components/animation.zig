//! `AnimationPlayer` — pure-data playback state (ROADMAP M13).

pub const clip_loop: u8 = 1 << 0;
pub const clip_ping_pong: u8 = 1 << 1;
pub const clip_root_motion: u8 = 1 << 2;

pub const AnimationPlayer = struct {
    clip_id: u32 = 0,
    next_clip_id: u32 = 0,
    time: f32 = 0.0,
    speed: f32 = 1.0,
    flags: u8 = 0,
    blend_factor: f32 = 0.0,
    blend_remaining: f32 = 0.0,
    blend_duration: f32 = 0.0,
    state: u32 = 0,
    queued_count: u8 = 0,
    queued_0: u32 = 0,
    queued_1: u32 = 0,
    queued_2: u32 = 0,
    queued_3: u32 = 0,
};
