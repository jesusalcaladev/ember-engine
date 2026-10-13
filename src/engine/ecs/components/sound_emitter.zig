//! `SoundEmitter2D` — the per-actor audio emitter (ROADMAP M8, Phase 6).
//!
//! The component is PLAIN DATA (registry rule 1): a scene document writes the
//! emitter's configuration and the editor resolves an asset path to a
//! `bank_slot` id at load, exactly the way `Sprite` stores an atlas slot and
//! not a filename (M1: components are bit-exact, strings are not saved in
//! them).
//!
//! ## Why `VoiceRef` is declared here and not imported from `audio`
//!
//! `playing` is a runtime handle, and the natural spelling is `audio.VoiceId`.
//! But `ecs` is the one module every other module imports, and `audio` pulls in
//! miniaudio (a real device, a real decoder, a C translation unit). Importing
//! it here would link all of that into every ECS consumer — the editor core,
//! the session, every bench — for a field that is two `u32`s. So the handle is
//! a local struct with the same shape, and `script/bindings.zig` (the one place
//! that sees both modules) pins the two layouts equal with a comptime assert.
//! If they ever drift, that assert fails to compile rather than a sentence
//! being believed.
//!
//! ## What this component does NOT own
//!
//! Mixing. The emitter is the scene-side description; `Audio.system.zig` is
//! what turns a `play` into a voice. The emitter carries the handle only so a
//! despawn can stop what it started and an inspector can show it.

const std = @import("std");

/// A runtime voice handle, field-for-field `audio.VoiceId`.
///
/// Declared locally to keep `ecs` free of the native audio module (see the file
/// header). `invalid_index` is the same sentinel the port uses, so `.none`
/// round-trips through `audio.VoiceId` unchanged.
pub const VoiceRef = struct {
    index: u32 = invalid_index,
    generation: u32 = 0,

    pub const invalid_index = std.math.maxInt(u32);
    pub const none = VoiceRef{};

    pub fn isNone(self: VoiceRef) bool {
        return self.index == invalid_index;
    }
};

pub const SoundEmitter2D = struct {
    /// Bank slot of the decoded sound. 0 means "nothing loaded" — the editor
    /// writes the id, never a path (M1: components are bit-exact).
    bank_slot: u16 = 0,
    /// Bus this emitter feeds. 0 is master; the project config names the rest.
    bus: u8 = 0,
    /// Emitter gain, before bus gain.
    volume: f32 = 1.0,
    /// Resample ratio for playback; 1 is the file's own pitch.
    pitch: f32 = 1.0,
    /// Whether playback loops (music, ambience) or is a one-shot (a hit).
    loop: bool = false,
    /// Distance at which the sound is inaudible. **0 means global**: never
    /// attenuated, never panned (music/UI) — the port's documented zero case.
    max_distance: f32 = 0.0,
    /// Distance at which panning reaches a hard left/right. Irrelevant when
    /// `max_distance` is 0.
    spread: f32 = 400.0,
    /// Start playing when the frame loop first sees the emitter. An emitter
    /// that is not autoplaying is a sound waiting for a script to call
    /// `sound.play(self)`.
    autoplay: bool = false,
    /// The voice this emitter started, so `sound.stop(self)` and a despawn
    /// stop the right one. Stale after a recycle, which is a no-op by design.
    playing: VoiceRef = .{},
    /// Tick the current voice was started at. The signal bus stamps events
    /// with it so a listener can tell "this emitter's blast" from "the last
    /// one", the same way `Timer` carries its fixed-step clock.
    tick: u64 = 0,

    /// True while `playing` names a live voice the emitter believes is its own.
    pub fn isPlaying(self: *const SoundEmitter2D) bool {
        return !self.playing.isNone();
    }
};

// ── Tests ────────────────────────────────────────────────────────────────────

const testing = std.testing;

test "SoundEmitter2D defaults to a silent, self-paced one-shot" {
    const e = SoundEmitter2D{};
    try testing.expectEqual(@as(u16, 0), e.bank_slot);
    try testing.expectEqual(@as(u8, 0), e.bus);
    try testing.expectEqual(@as(f32, 1.0), e.volume);
    try testing.expectEqual(@as(f32, 1.0), e.pitch);
    try testing.expect(!e.loop);
    try testing.expectEqual(@as(f32, 0.0), e.max_distance); // global
    try testing.expect(!e.autoplay);
    try testing.expect(!e.isPlaying());
    try testing.expectEqual(@as(u64, 0), e.tick);
}

test "VoiceRef mirrors the port's invalid sentinel" {
    const none = VoiceRef.none;
    try testing.expect(none.isNone());
    try testing.expectEqual(VoiceRef.invalid_index, none.index);
    const live = VoiceRef{ .index = 3, .generation = 9 };
    try testing.expect(!live.isNone());
}

test "SoundEmitter2D fits the .zson decode buffer" {
    // `max_stride` is the decode buffer; the registry comptime check refuses a
    // larger component, and this pins the number next to the type it protects.
    try testing.expect(@sizeOf(SoundEmitter2D) <= 128);
}
