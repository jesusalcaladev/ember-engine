//! `engine.audio` — the audio system (ROADMAP M8).
//!
//! Layered so the interesting half is pure and testable with no sound card:
//!
//! - `audio`: the **port**. A `VTable` a backend fulfils, plus the vocabulary
//!   both sides speak (`Pcm`, `Stats`, `DeviceDesc`, `VoiceId`, `Device`).
//! - `mixer`: the **maths** a speaker and a shader both depend on — constant
//!   power panning, squared-linear attenuation, and resampling. Pure.
//! - `voice`: the fixed **voice pool** with generation-checked handles and a
//!   steal policy, because a callback that must not allocate cannot create one.
//! - `bus`: the **bus registry**, 16 named gains with bus 0 as master.
//! - `bank`: the **decoded-PCM cache** — the one owner of a sound's bytes, with
//!   a byte budget and LRU eviction (spec §3.15).
//! - `command`: the **SPSC command ring** the main thread writes and the device
//!   thread reads, so the two never share mutable state.
//!
//! The backend owns exactly two things: the device (its thread, its clock, its
//! format) and load-time decoding. Everything above the port is engine-side.

const std = @import("std");

/// The backend-agnostic contract.
pub const audio = @import("audio.zig");
/// Pure mixing maths.
pub const mixer = @import("mixer.zig");
/// The voice pool.
pub const voice = @import("voice.zig");
/// Named buses.
pub const bus = @import("bus.zig");
/// The byte-budgeted PCM cache.
pub const bank = @import("bank.zig");
/// The main-thread → device-thread command ring.
pub const command = @import("command.zig");
/// The device-thread → main-thread event ring.
pub const events = @import("events.zig");
/// The per-sample render loop.
pub const mix = @import("mix.zig");
/// The owner the runtime drives: device + bank + voices + buses + rings.
pub const system = @import("system.zig");
/// The headless backend (no device; synthesised PCM; explicit pump).
pub const backend_null = @import("backend_null.zig");
/// The real backend: miniaudio, through the C shim in `miniaudio_impl.c`. The
/// ONLY file in this module that links C, which is why everything else here
/// still tests with nothing installed.
pub const backend_miniaudio = @import("backend_miniaudio.zig");

// ── The port's vocabulary, re-exported under short names ────────────────────
pub const Pcm = audio.Pcm;
pub const Stats = audio.Stats;
pub const VoiceId = audio.VoiceId;
pub const Device = audio.Device;
pub const DeviceDesc = audio.DeviceDesc;
pub const VTable = audio.VTable;
pub const MixCallback = audio.MixCallback;
pub const DecodeError = audio.DecodeError;

// ── The engine-side pieces ──────────────────────────────────────────────────
pub const Voice = voice.Voice;
pub const VoicePool = voice.VoicePool;
pub const Bus = bus.Bus;
pub const Buses = bus.Registry;
pub const Bank = bank.Bank;
pub const BankSlot = bank.SlotId;
/// The bank's "nothing loaded" slot: what an emitter's `bank_slot` is worth
/// before anything is resolved, and what the bank never assigns.
pub const no_bank_slot = bank.no_slot;
pub const Command = command.Command;
pub const CommandRing = command.CommandRing;
pub const SoundEvent = events.SoundEvent;
pub const EventRing = events.EventRing;
/// What a drained event becomes on the signal bus (POD), and the table the
/// runtime hands `Audio.drainEvents` to reach it.
pub const SoundSignal = events.SoundSignal;
pub const SoundBridge = events.Bridge;
pub const EventKind = events.Kind;
pub const soundSignalName = events.signalName;

// ── The system and its configuration ────────────────────────────────────────
pub const Audio = system.Audio;
pub const Config = system.Config;
pub const PlayOpts = system.PlayOpts;
pub const Backend = system.Backend;
/// `bus_send_to` sentinel: the bus sends nowhere. Re-exported so the Lua layer
/// clears a send with the engine's own vocabulary rather than a magic number.
pub const no_send = system.no_send;

/// Opens a device through the named backend. A comptime tag, so a typo is a
/// compile error and an unused backend's file is never linked — the same shape
/// as `physics.createWorld(.box2d, ...)`.
///
/// Null means "no device", which every caller must treat as silence plus a
/// name in the log, never as a reason to stop.
pub fn createDevice(comptime backend: Backend, desc: DeviceDesc, mix_cb: MixCallback, mix_ctx: ?*anyopaque) ?Device {
    return switch (backend) {
        .null => backend_null.create(desc, mix_cb, mix_ctx),
        .miniaudio => backend_miniaudio.create(desc, mix_cb, mix_ctx),
    };
}

test {
    std.testing.refAllDecls(@This());
}
