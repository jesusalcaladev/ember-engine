//! `Audio` — the one owner of the audio device and everything above it (M8).
//!
//! The runtime holds exactly one of these, feeds it the listener once a frame,
//! and drains its events into the signal bus. The editor holds one too (with the
//! null backend, for previews). Nothing else constructs a `Device`.
//!
//! ## The two threads, and who writes what
//!
//! - **The main thread** owns the pool's STRUCTURE: it reserves and recycles
//!   slots (`VoicePool.allocate`), and it decides what to play. It never fills a
//!   live voice's runtime fields.
//! - **The device thread** owns a live voice's RUNTIME state: it fills a slot
//!   the main thread reserved, advances the cursor, computes the level, and
//!   clears `active` when the sound ends. It reports that through the event
//!   ring so only the main thread reaches the ECS.
//!
//! The command ring carries the structural asks (play/stop/volume); placement
//! scalars (listener, bus gains, master) are plain fields the main thread
//! stores and the device thread loads — a single aligned word each, so no read
//! can tear, and the buffer boundary is the ordering point that matters.
//!
//! ## Why a null backend is the default in tests
//!
//! Every test and the bench drive `create(..., .null, ...)` and then `pump`,
//! which runs the REAL mixer. That is how "64 simultaneous emitters" is checked
//! on a machine with no sound card.

const std = @import("std");
const core = @import("core");
const core_time = core.time;
const audio = @import("audio.zig");
const bank_mod = @import("bank.zig");
const bus_mod = @import("bus.zig");
const command_mod = @import("command.zig");
const events_mod = @import("events.zig");
const mix = @import("mix.zig");
const voice_mod = @import("voice.zig");
const backend_null = @import("backend_null.zig");
const backend_miniaudio = @import("backend_miniaudio.zig");

const Bank = bank_mod.Bank;
const BankSlot = bank_mod.SlotId;
const VoicePool = voice_mod.VoicePool;
const Voice = voice_mod.Voice;
const VoiceId = audio.VoiceId;

/// `bus_send_to` sentinel: this bus sends nowhere.
pub const no_send: u8 = std.math.maxInt(u8);

/// Which backend to open. A comptime tag so a typo is a compile error and an
/// unused backend's file is never linked (the same shape as
/// `physics.createWorld`).
pub const Backend = enum { null, miniaudio };

/// How the system is built. Every field has a default, so `Config{}` is a
/// working stereo 48 kHz/480-frame device with a 256-voice pool and a 32 MiB
/// decoded-PCM budget.
pub const Config = struct {
    desc: audio.DeviceDesc = .{},
    voices: usize = 256,
    budget_bytes: usize = 32 << 20,
    command_capacity: usize = command_mod.default_capacity,
    event_capacity: usize = events_mod.default_capacity,
    /// Per-bus gains, indexed by bus id. Bus 0 is master.
    bus_gain: [bus_mod.bus_count]f32 = [_]f32{1} ** bus_mod.bus_count,
    bus_muted: [bus_mod.bus_count]bool = [_]bool{false} ** bus_mod.bus_count,
    master_gain: f32 = 1,
};

/// Options for one `play`. Mirrors `Command.Play` minus the voice, which the
/// system reserves.
pub const PlayOpts = struct {
    bus: u8 = 0,
    volume: f32 = 1,
    pitch: f32 = 1,
    x: f32 = 0,
    y: f32 = 0,
    /// 0 = global: never attenuated, never panned (music, UI).
    max_distance: f32 = 0,
    spread: f32 = 400,
    loop: bool = false,
    /// Higher survives a steal when the pool is full.
    priority: u8 = 0,
};

pub const Audio = struct {
    allocator: std.mem.Allocator,
    device: audio.Device,
    bank: Bank,
    pool: VoicePool,
    buses: bus_mod.Registry,
    /// Owns the bytes of every registered bus name. `project.config` is loaded
    /// into an arena that dies on the next hot-reload, and the registry only
    /// BORROWS the names it is given — so the copies live here, bounded by
    /// `bus_count` and reset in place whenever the map is rebuilt.
    bus_names: std.heap.ArenaAllocator,
    commands: command_mod.CommandRing,
    events: events_mod.EventRing,

    bus_gain: [bus_mod.bus_count]f32,
    bus_muted: [bus_mod.bus_count]bool,
    master_gain: f32 = 1,
    listener_x: f32 = 0,
    listener_y: f32 = 0,
    /// Which way the ears face, in radians. Turns the pan axis with the
    /// listener (`mixer.zig`); 0 is the historical "ears face +x".
    listener_rot: f32 = 0,
    /// Solo flags, per bus. When any bus is soloed, every non-soloed bus is
    /// silenced — master excepted, because master is where the soloed signal
    /// ends up and "solo master" would mean "solo everything".
    bus_solo: [bus_mod.bus_count]bool = [_]bool{false} ** bus_mod.bus_count,
    /// Single-level aux send: bus `b` routes `bus_send_amount[b]` of its signal
    /// into bus `bus_send_to[b]`'s gain path. `no_send` means the bus sends
    /// nowhere. Chains are not followed (a send of a send), by design — one
    /// level is what a reverb/duck bus actually needs and it keeps the frame
    /// cost a fixed two passes over 16 buses.
    bus_send_to: [bus_mod.bus_count]u8 = [_]u8{no_send} ** bus_mod.bus_count,
    bus_send_amount: [bus_mod.bus_count]f32 = [_]f32{0} ** bus_mod.bus_count,
    /// Output rate the mixer resamples against: the NEGOTIATED rate, read back
    /// from the device once at create, never the requested one.
    output_rate: u32 = 48000,
    channels: u16 = 2,
    tick: u64 = 0,
    running: bool = false,
    /// Running total of commands dropped, accumulated as they are read so
    /// `stats()` is a pure read.
    commands_dropped: u64 = 0,
    /// Running total of events dropped.
    events_dropped: u64 = 0,
    /// Buffers the device has rendered. The bench reads it to prove the pump ran.
    buffers: u64 = 0,
    /// Total nanoseconds spent inside `mixCallback` (the device thread). Written
    /// only there and read only from the main thread, so a plain add is enough:
    /// the device thread is the sole writer and a torn read would still be a
    /// plausible number, never a jump by half a frame.
    ///
    /// This is the number that says whether the callback FITS in its period,
    /// which is the only audio question a profile can answer: overruns are a
    /// symptom, this is the cause.
    mix_ns_total: u64 = 0,

    const Self = @This();

    /// Creates and starts a system. Returns a heap pointer because the device's
    /// mix callback closes over `self`, which has to have a stable address.
    pub fn create(allocator: std.mem.Allocator, backend: Backend, cfg: Config) !*Self {
        const self = try allocator.create(Self);
        errdefer allocator.destroy(self);

        // Allocate the pieces into locals FIRST, each with its own errdefer, so
        // a failure part-way frees exactly what was built and never touches a
        // half-initialized `self`. The copies assigned into `self` below are the
        // same slices, so the locals' errdefers are the only frees.
        var bank = try Bank.init(allocator, bank_slots, cfg.budget_bytes);
        errdefer bank.deinit();
        var pool = try VoicePool.init(allocator, cfg.voices);
        errdefer pool.deinit(allocator);
        var commands = try command_mod.CommandRing.init(allocator, cfg.command_capacity);
        errdefer commands.deinit(allocator);
        var event_ring = try events_mod.EventRing.init(allocator, cfg.event_capacity);
        errdefer event_ring.deinit(allocator);

        self.* = .{
            .allocator = allocator,
            .device = undefined,
            .bank = bank,
            .pool = pool,
            .buses = bus_mod.Registry.init(),
            .bus_names = std.heap.ArenaAllocator.init(allocator),
            .commands = commands,
            .events = event_ring,
            .bus_gain = cfg.bus_gain,
            .bus_muted = cfg.bus_muted,
            .master_gain = cfg.master_gain,
        };

        self.device = switch (backend) {
            .null => backend_null.create(cfg.desc, mixCallback, self) orelse return error.OutOfMemory,
            // A machine with no device (a container, a headless CI box) is not a
            // boot failure: fall back to the null backend, which mixes for real
            // and makes no sound. `device.name` is what the log prints, so the
            // silence is stated rather than mysterious.
            .miniaudio => backend_miniaudio.create(cfg.desc, mixCallback, self) orelse
                backend_null.create(cfg.desc, mixCallback, self) orelse return error.OutOfMemory,
        };
        // Read back what the device actually negotiated; the mixer resamples
        // against this, and `latencyMs` is only honest if it is the real rate.
        const s = self.device.stats();
        self.output_rate = if (s.sample_rate != 0) s.sample_rate else cfg.desc.sample_rate;
        self.channels = if (s.channels != 0) s.channels else cfg.desc.channels;

        self.running = self.device.start();
        return self;
    }

    pub fn destroy(self: *Self) void {
        self.device.deinit();
        self.bank.deinit();
        self.bus_names.deinit();
        self.pool.deinit(self.allocator);
        self.commands.deinit(self.allocator);
        self.events.deinit(self.allocator);
        const a = self.allocator;
        a.destroy(self);
    }

    /// Slot count reserved for decoded PCM. The bank is indexable by `u16`, so
    /// this is the ceiling the command and the voice already carry.
    const bank_slots: usize = 4096;

    // ── Main thread: loading (LOAD TIME / PREVIEW ONLY) ─────────────────────

    /// Decodes `path` into the bank, returning its slot. Allocates and does
    /// blocking I/O: call it at load time or from the editor's importer, never
    /// from the frame (spec §3.4).
    pub fn load(self: *Self, path: []const u8) !BankSlot {
        return self.bank.getOrLoad(self.device, path);
    }

    /// Loads if needed and plays. The convenience form for a UI audition or a
    /// load-time script; it may decode, so it is NOT the frame-safe path.
    pub fn playFile(self: *Self, path: []const u8, opts: PlayOpts) !VoiceId {
        const slot = try self.load(path);
        return self.play(slot, opts);
    }

    /// Opens `path` as a STREAM (a window, not the whole sound) and plays it.
    ///
    /// This is the path for long music: the file is never fully resident, and
    /// `frame()` keeps the window fed. It opens the file, so it is load time /
    /// preview only, never the frame (spec §3.4).
    ///
    /// `window_frames` is the prefetch depth; the bank raises it to at least
    /// 50 ms so a slow frame cannot drain the ring.
    pub fn playFileStream(self: *Self, path: []const u8, opts: PlayOpts, window_frames: u32) !VoiceId {
        const slot = try self.bank.openStream(self.device, path, self.streamWindow(window_frames));
        return self.play(slot, opts);
    }

    /// The prefetch depth a stream uses when the caller does not pick one: four
    /// device periods (~40 ms at 480 frames), enough that a slow frame cannot
    /// drain the ring before the next refill.
    pub fn streamWindow(self: *const Self, requested: u32) u32 {
        if (requested != 0) return requested;
        const period = self.device.stats().period_frames;
        return if (period != 0) period * 4 else 1920;
    }

    /// Load time: opens a stream without playing it (the emitter component
    /// resolves a path to a slot id at load and plays it later).
    pub fn loadStream(self: *Self, path: []const u8, window_frames: u32) !BankSlot {
        return self.bank.openStream(self.device, path, self.streamWindow(window_frames));
    }

    /// Advances every streaming slot's prefetch window. MAIN THREAD ONLY — this
    /// is the one place a stream file is read, which is what keeps the device
    /// thread free of I/O (spec §3.4, §10). `frame()` calls it; tests call it
    /// directly.
    pub fn refillStreams(self: *Self) void {
        self.bank.refillAllStreams();
    }

    // ── Main thread: the frame-safe surface (never allocates) ───────────────

    /// Starts a resident sound. Returns the voice handle synchronously; the
    /// device thread fills the slot and it becomes audible on the next buffer.
    pub fn play(self: *Self, slot: BankSlot, opts: PlayOpts) VoiceId {
        const idx = self.pool.allocate();
        const id = self.pool.handleAt(idx);
        _ = self.commands.push(.{ .play = .{
            .voice = id,
            .bank_slot = slot,
            .bus = opts.bus,
            .volume = opts.volume,
            .pitch = opts.pitch,
            .x = opts.x,
            .y = opts.y,
            .max_distance = opts.max_distance,
            .spread = opts.spread,
            .loop = opts.loop,
            .priority = opts.priority,
            .tick = self.tick,
        } });
        return id;
    }

    pub fn stop(self: *Self, id: VoiceId) void {
        _ = self.commands.push(.{ .stop = .{ .voice = id } });
    }

    pub fn stopAll(self: *Self) void {
        _ = self.commands.push(.stop_all);
    }

    pub fn setVolume(self: *Self, id: VoiceId, volume: f32) void {
        _ = self.commands.push(.{ .set_volume = .{ .voice = id, .volume = volume } });
    }

    pub fn setPitch(self: *Self, id: VoiceId, pitch: f32) void {
        _ = self.commands.push(.{ .set_pitch = .{ .voice = id, .pitch = pitch } });
    }

    /// Whether a voice is still playing. Reads the pool's live view, which the
    /// device thread has already updated by the time the next frame runs.
    pub fn isPlaying(self: *Self, id: VoiceId) bool {
        return self.pool.resolve(id) != null;
    }

    // ── Load time: the bus map ──────────────────────────────────────────────

    /// Registers the bus map (`project.config`'s `audio.buses`): item `i` names
    /// bus `i`, item 0 is skipped (bus 0 is master for good), and the list stops
    /// at `bus_count`. Names are COPIED, so the caller's slice may die with the
    /// config arena that owns it.
    ///
    /// Load time only (boot, or the editor applying an edited section), never
    /// from the frame: it unlocks the registry while it rebuilds it and locks it
    /// again after, which is the point of the lock (spec §3.13.1).
    pub fn defineBuses(self: *Self, names: []const []const u8) !void {
        self.buses.unlock();
        defer self.buses.lock();

        // Every registered name points into the arena being reset, so clear
        // them FIRST: a bus left out of the new map must end up unnamed, not
        // holding bytes the reset just freed.
        for (self.buses.buses[1..]) |*bus| bus.name = "";
        _ = self.bus_names.reset(.retain_capacity);
        const alloc = self.bus_names.allocator();

        for (names, 0..) |name, i| {
            if (i == 0) continue;
            if (i >= bus_mod.bus_count) break;
            if (name.len == 0) continue;
            const owned = try alloc.dupe(u8, name);
            try self.buses.setName(@intCast(i), owned);
        }
    }

    /// The name of a bus id, or "" for an unnamed one. The UI draws the mixer
    /// from this; "" is a channel the project declared no name for.
    pub fn busName(self: *const Self, id: u8) []const u8 {
        const bus = self.buses.get(id) orelse return "";
        return bus.name;
    }

    // ── Main thread: placement, buses, clock ────────────────────────────────

    pub fn setListener(self: *Self, x: f32, y: f32, rot: f32) void {
        self.listener_x = x;
        self.listener_y = y;
        self.listener_rot = rot;
    }

    /// The per-bus gain the mixer actually applies: mute and solo folded in
    /// first, then the single-level sends.
    ///
    /// This is a pure function of `self`'s bus fields with no device involved,
    /// which is what lets solo and sends be tested without a sound card — the
    /// mix callback just calls it.
    ///
    /// Why sends fold into the SOURCE bus's gain and not a second voice pass:
    /// both the direct copy and the sent copy end at master, so a source bus
    /// with `g_b` sending `a` into a target with `g_t` contributes
    /// `g_b + a*g_t` per sample. That is exactly the two contributions summed,
    /// at no extra per-voice cost. One level only: a send of a send is not
    /// followed, which keeps this a fixed two passes over 16 buses.
    pub fn effectiveBusGains(self: *const Self, out: *[bus_mod.bus_count]f32) void {
        var any_solo = false;
        for (self.bus_solo[1..]) |s| {
            if (s) any_solo = true;
        }
        var base: [bus_mod.bus_count]f32 = undefined;
        for (0..bus_mod.bus_count) |i| {
            var g = if (self.bus_muted[i]) 0 else self.bus_gain[i];
            if (any_solo and i != 0 and !self.bus_solo[i]) g = 0;
            out[i] = g;
            base[i] = g;
        }
        for (1..bus_mod.bus_count) |b| {
            const t = self.bus_send_to[b];
            const a = self.bus_send_amount[b];
            if (t < bus_mod.bus_count and a > 0) out[b] += a * base[t];
        }
    }

    /// Silences every bus except the soloed ones. Bus 0 (master) is never a
    /// solo target; soloing a bus other than master is the audible case.
    pub fn setBusSolo(self: *Self, id: u8, solo: bool) void {
        if (id == 0 or id >= bus_mod.bus_count) return;
        self.bus_solo[id] = solo;
    }

    pub fn busSolo(self: *const Self, id: u8) bool {
        if (id >= bus_mod.bus_count) return false;
        return self.bus_solo[id];
    }

    /// Routes `amount` of bus `id`'s signal into bus `target`'s gain path. A
    /// negative amount, or a target of `no_send`, clears the send.
    pub fn setBusSend(self: *Self, id: u8, target: u8, amount: f32) void {
        if (id == 0 or id >= bus_mod.bus_count) return;
        if (target == no_send or target >= bus_mod.bus_count or target == id or amount <= 0) {
            self.bus_send_to[id] = no_send;
            self.bus_send_amount[id] = 0;
            return;
        }
        self.bus_send_to[id] = target;
        self.bus_send_amount[id] = std.math.clamp(amount, 0, 4);
    }

    pub fn busSendTo(self: *const Self, id: u8) u8 {
        if (id >= bus_mod.bus_count) return no_send;
        return self.bus_send_to[id];
    }

    pub fn busSendAmount(self: *const Self, id: u8) f32 {
        if (id >= bus_mod.bus_count) return 0;
        return self.bus_send_amount[id];
    }

    pub fn setMasterGain(self: *Self, gain: f32) void {
        self.master_gain = std.math.clamp(gain, 0, 4);
    }

    /// Sets a bus gain by id. Applied by the device at the next buffer.
    pub fn setBusGain(self: *Self, id: u8, gain: f32) void {
        if (id >= bus_mod.bus_count) return;
        self.bus_gain[id] = std.math.clamp(gain, 0, 10);
    }

    pub fn setBusMuted(self: *Self, id: u8, muted: bool) void {
        if (id >= bus_mod.bus_count) return;
        self.bus_muted[id] = muted;
    }

    pub fn busGain(self: *const Self, id: u8) f32 {
        if (id >= bus_mod.bus_count) return 1;
        return if (self.bus_muted[id]) 0 else self.bus_gain[id];
    }

    /// Advances the frame clock (used to stamp commands and emitted events).
    pub fn beginFrame(self: *Self, tick: u64) void {
        self.tick = tick;
        self.bank.advanceTick();
        // Feed the streaming windows BEFORE the device renders the next buffer.
        self.bank.refillAllStreams();
    }

    /// Replaces a resident sound's PCM in place (hot-reload). The slot keeps its
    /// id, so live voices pick up the new bytes; their cursors are clamped by
    /// the mixer's end-of-buffer handling.
    ///
    /// A path the bank does not know is LOADED rather than reloaded: the caller
    /// (the editor, the runtime's asset watch) asks for a file it just saved and
    /// does not know or care whether it is resident yet.
    ///
    /// A STREAMING slot is refused (`error.StreamNotReloadable`). Its PCM is a
    /// window into a ring the main thread refills, so "replacing" it would free
    /// an interior pointer — the honest answer is to stop the voice and open the
    /// stream again, which is what the caller has to do.
    pub fn reload(self: *Self, path: []const u8) !void {
        const slot = self.bank.find(path) orelse {
            _ = try self.load(path);
            return;
        };
        if (self.bank.isStream(slot)) return error.StreamNotReloadable;
        try self.bank.replace(slot, self.device, path);
    }

    /// The path behind a bank slot, or "" when the slot is free. What an
    /// inspector shows next to the emitter's slot id.
    pub fn slotPath(self: *const Self, slot: BankSlot) []const u8 {
        return self.bank.pathOf(slot);
    }

    /// Pops one device→main event, or null. The runtime turns these into
    /// signals at the frame's drain point.
    pub fn popEvent(self: *Self) ?events_mod.SoundEvent {
        return self.events.pop();
    }

    /// Drains every queued event into `bridge`, in the order the device thread
    /// produced them.
    ///
    /// This is the MAIN THREAD's half of the event ring, and the reason the ring
    /// exists: the mixer learns on the device thread that a voice ended, and only
    /// the main thread may touch the ECS or the signal bus. Zero allocation: the
    /// bridge builds a POD payload and the bus interns the name at load time.
    pub fn drainEvents(self: *Self, bridge: events_mod.Bridge) void {
        while (self.events.pop()) |ev| {
            bridge.fire(bridge.ctx, ev.kind, .{
                .bank_slot = ev.bank_slot,
                .voice_index = ev.voice.index,
                .voice_generation = ev.voice.generation,
                .tick = ev.tick,
            });
        }
    }

    /// Headless only: advance the mix by `frames` on the CALLING thread. Null
    /// for a real backend, where the device thread owns the clock.
    pub fn pump(self: *Self, frames: u32) void {
        self.device.pump(frames);
    }

    pub fn stats(self: *Self) audio.Stats {
        self.commands_dropped += self.commands.takeDropped();
        self.events_dropped += self.events.takeDropped();
        var s = self.device.stats();
        s.voices_active = self.pool.activeCount();
        s.voices_peak = self.pool.peak_active;
        s.commands_dropped = self.commands_dropped;
        s.sample_rate = self.output_rate;
        s.channels = self.channels;
        return s;
    }

    pub fn bankStats(self: *const Self) bank_mod.Bank.Stats {
        return self.bank.stats();
    }

    /// Device-thread mix cost per buffer, averaged over the run, in
    /// nanoseconds. Zero before the first buffer, and zero for a backend that
    /// reported no buffers — never a guess.
    ///
    /// Read from the main thread while the device thread writes: an average
    /// across a torn read is still the average, which is why the total is a
    /// plain `u64` and not an atomic.
    pub fn mixNsPerBuffer(self: *const Self) u64 {
        if (self.buffers == 0) return 0;
        return self.mix_ns_total / self.buffers;
    }

    // ── Device thread ───────────────────────────────────────────────────────

    fn mixCallback(ctx: ?*anyopaque, out: [*]f32, frames: u32) void {
        const self: *Self = @ptrCast(@alignCast(ctx.?));
        // The clock is read BEFORE the mix, and its cost is one `rdtsc`: the
        // measurement must never be the reason a buffer is late, so it is the
        // cheapest monotonic read in the engine (`core.time.monotonicNs`) and
        // nothing else is timed here.
        const t0 = core_time.monotonicNs();
        self.drainCommands();

        var gains: [bus_mod.bus_count]f32 = undefined;
        self.effectiveBusGains(&gains);

        mix.render(self.pool.voices, &self.bank, .{
            .output_rate = self.output_rate,
            .channels = self.channels,
            .listener_x = self.listener_x,
            .listener_y = self.listener_y,
            .listener_rot = self.listener_rot,
            .bus_gain = &gains,
            .master_gain = self.master_gain,
        }, out, frames, .{ .ctx = self, .onFinish = onFinish });

        self.pool.updatePeak();
        self.buffers += 1;
        // A wrapping subtraction would be a negative number, and `monotonicNs`
        // is monotonic for the process's lifetime, so a plain difference is
        // honest for any run this engine will see.
        self.mix_ns_total += core_time.monotonicNs() -| t0;
    }

    fn onFinish(ctx: *anyopaque, v: *const Voice) void {
        const self: *Self = @ptrCast(@alignCast(ctx));
        const index = (@intFromPtr(v) - @intFromPtr(self.pool.voices.ptr)) / @sizeOf(Voice);
        _ = self.events.push(.{
            .kind = .finished,
            .voice = .{ .index = @intCast(index), .generation = self.pool.generations[index] },
            .bank_slot = v.bank_slot,
            .tick = v.tick,
        });
    }

    fn drainCommands(self: *Self) void {
        while (self.commands.pop()) |cmd| {
            switch (cmd) {
                .play => |p| {
                    // NOT `pool.resolve`: that requires the voice to be active
                    // already, and the whole point is that it is not yet. The
                    // main thread reserved this slot (and bumped the
                    // generation); the device fills it in and only then sets
                    // `active`.
                    if (p.voice.index < self.pool.voices.len) {
                        const v = &self.pool.voices[p.voice.index];
                        v.* = .{
                            .active = true,
                            .bank_slot = p.bank_slot,
                            .cursor = 0,
                            .bus = p.bus,
                            .base_volume = p.volume,
                            .x = p.x,
                            .y = p.y,
                            .max_distance = p.max_distance,
                            .spread = p.spread,
                            .pitch = p.pitch,
                            .loop = p.loop,
                            .priority = p.priority,
                            .tick = p.tick,
                        };
                        _ = self.events.push(.{
                            .kind = .started,
                            .voice = p.voice,
                            .bank_slot = p.bank_slot,
                            .tick = p.tick,
                        });
                    }
                },
                .stop => |s| {
                    if (self.pool.resolve(s.voice)) |v| v.active = false;
                },
                .set_volume => |s| {
                    if (self.pool.resolve(s.voice)) |v| v.base_volume = s.volume;
                },
                .set_pitch => |s| {
                    if (self.pool.resolve(s.voice)) |v| v.pitch = s.pitch;
                },
                .set_bus_volume => |s| {
                    if (s.bus < bus_mod.bus_count) self.bus_gain[s.bus] = s.volume;
                },
                .set_master_volume => |g| self.master_gain = g,
                .set_listener => |l| {
                    self.listener_x = l.x;
                    self.listener_y = l.y;
                    self.listener_rot = l.rot;
                },
                .pause_bus => |b| {
                    if (b < bus_mod.bus_count) self.bus_muted[b] = true;
                },
                .resume_bus => |b| {
                    if (b < bus_mod.bus_count) self.bus_muted[b] = false;
                },
                .stop_all => self.pool.stopAll(),
            }
        }
    }
};

// ── Tests ────────────────────────────────────────────────────────────────────

const testing = std.testing;

fn testSystem(alloc: std.mem.Allocator, voices: usize) !*Audio {
    return Audio.create(alloc, .null, .{
        .desc = .{ .sample_rate = 48000, .period_frames = 480, .channels = 2 },
        .voices = voices,
        .budget_bytes = 1 << 20,
    });
}

test "play is synchronous but the sound starts one buffer later (the command is drained by the device)" {
    const alloc = testing.allocator;
    const sys = try testSystem(alloc, 8);
    defer sys.destroy();

    const slot = try sys.load("boom:100");
    const v = sys.play(slot, .{});
    try testing.expect(!v.isNone());

    // The main thread has reserved the slot; the DEVICE has not filled it yet,
    // so nothing is active until the buffer runs.
    try testing.expectEqual(@as(u32, 0), sys.pool.activeCount());
    // 48 frames of a 100-frame sound: still playing at the end of the buffer.
    sys.pump(48);
    try testing.expectEqual(@as(u32, 1), sys.pool.activeCount());
    try testing.expect(sys.isPlaying(v));
}

test "a one-shot reports started and finished through the event ring" {
    const alloc = testing.allocator;
    const sys = try testSystem(alloc, 8);
    defer sys.destroy();

    const slot = try sys.load("ping:64");
    _ = sys.play(slot, .{});
    // Ask for more frames than the sound has: it ends inside the buffer.
    sys.pump(480);

    var saw_started = false;
    var saw_finished = false;
    while (sys.popEvent()) |ev| {
        if (ev.kind == .started) saw_started = true;
        if (ev.kind == .finished) {
            saw_finished = true;
            try testing.expectEqual(@as(u16, slot), ev.bank_slot);
        }
    }
    try testing.expect(saw_started);
    try testing.expect(saw_finished);
    try testing.expectEqual(@as(u32, 0), sys.pool.activeCount());
}

test "stop silences a voice, and a stale handle is a no-op" {
    const alloc = testing.allocator;
    const sys = try testSystem(alloc, 8);
    defer sys.destroy();

    const slot = try sys.load("loop:1000");
    const v = sys.play(slot, .{ .loop = true });
    sys.pump(64);
    try testing.expect(sys.isPlaying(v));

    sys.stop(v);
    sys.pump(64);
    try testing.expect(!sys.isPlaying(v));

    // Stopping again does nothing: the handle no longer resolves, and the same
    // slot must not be stopped as if it were a different sound.
    sys.stop(v);
    sys.pump(64);
}

test "the pool steals rather than dropping the 65th emitter" {
    const alloc = testing.allocator;
    const sys = try testSystem(alloc, 4);
    defer sys.destroy();

    const slot = try sys.load("tone:1000");
    var i: usize = 0;
    while (i < 8) : (i += 1) _ = sys.play(slot, .{ .loop = true });
    sys.pump(64);
    // The pool never grew: it is still four voices, and the extra plays stole.
    try testing.expectEqual(@as(usize, 4), sys.pool.slotCount());
    try testing.expectEqual(@as(u32, 4), sys.pool.activeCount());
    try testing.expect(sys.pool.steals >= 4);
}

test "the bank budget is enforced through the system, and stats report it" {
    const alloc = testing.allocator;
    const sys = try Audio.create(alloc, .null, .{ .voices = 4, .budget_bytes = 1024 });
    defer sys.destroy();
    _ = try sys.load("a:100"); // 400 B
    _ = try sys.load("b:100"); // 400 B, total 800
    const st = sys.bankStats();
    try testing.expect(st.bytes_used <= st.budget_bytes);
    _ = try sys.load("c:100"); // needs 1200 > 1024: evicts the LRU
    try testing.expect(sys.bankStats().bytes_used <= 1024);
}

test "draining reports started and finished in order, with the tick they were issued at" {
    const alloc = testing.allocator;
    const sys = try testSystem(alloc, 8);
    defer sys.destroy();

    const S = struct {
        var seen: [4]events_mod.Kind = undefined;
        var slots: [4]u16 = undefined;
        var ticks: [4]u64 = undefined;
        var n: usize = 0;
        fn fire(_: ?*anyopaque, kind: events_mod.Kind, value: events_mod.SoundSignal) void {
            seen[n] = kind;
            slots[n] = value.bank_slot;
            ticks[n] = value.tick;
            n += 1;
        }
    };
    S.n = 0;

    const slot = try sys.load("ping:64");
    sys.beginFrame(41); // the tick the sound is ISSUED at
    _ = sys.play(slot, .{});
    sys.pump(480); // past the end of a 64-frame one-shot

    sys.drainEvents(.{ .ctx = null, .fire = S.fire });
    try testing.expectEqual(@as(usize, 2), S.n);
    try testing.expectEqual(events_mod.Kind.started, S.seen[0]);
    try testing.expectEqual(events_mod.Kind.finished, S.seen[1]);
    try testing.expectEqual(slot, S.slots[1]);
    // Both carry the ISSUE tick, not the tick the buffer ended on.
    try testing.expectEqual(@as(u64, 41), S.ticks[0]);
    try testing.expectEqual(@as(u64, 41), S.ticks[1]);

    // A second drain finds nothing: events are consumed, not replayed.
    sys.drainEvents(.{ .ctx = null, .fire = S.fire });
    try testing.expectEqual(@as(usize, 2), S.n);
}

test "the bus map comes from the config, and its names outlive the config arena" {
    const alloc = testing.allocator;
    const sys = try testSystem(alloc, 4);
    defer sys.destroy();

    try sys.defineBuses(&.{ "master", "music", "sfx" });
    try testing.expectEqualStrings("master", sys.busName(0)); // bus 0 keeps its name
    try testing.expectEqualStrings("music", sys.busName(1));
    try testing.expectEqual(@as(?u8, 1), sys.buses.idOfName("music"));

    // A hot-reload frees the config arena the names came from, so the system
    // must own copies of them. This hands it strings that die immediately.
    var arena = std.heap.ArenaAllocator.init(alloc);
    const a = arena.allocator();
    var names: [3][]const u8 = undefined;
    for ([_][]const u8{ "master", "music", "ui" }, 0..) |name, i| names[i] = try a.dupe(u8, name);
    try sys.defineBuses(&names);
    arena.deinit();

    try testing.expectEqualStrings("music", sys.busName(1));
    try testing.expectEqualStrings("ui", sys.busName(2));
    // "sfx" left the map: the id it had is renamed, and nothing else holds it.
    try testing.expectEqualStrings("", sys.busName(3));
    try testing.expect(sys.buses.idOfName("sfx") == null);
    // And the registry is locked again, so the frame cannot rewrite the map.
    try testing.expectError(error.AccessDenied, sys.buses.setName(3, "late"));
}

test "a muted bus silences its voices but does not stop them" {
    const alloc = testing.allocator;
    const sys = try testSystem(alloc, 8);
    defer sys.destroy();

    const slot = try sys.load("music:1000");
    const v = sys.play(slot, .{ .bus = 2, .loop = true });
    sys.pump(64);
    sys.setBusMuted(2, true);
    sys.pump(64);
    try testing.expect(sys.busGain(2) == 0);
    try testing.expect(sys.isPlaying(v)); // muted, not stopped
}

test "soloing a bus silences the others; master still passes" {
    const alloc = testing.allocator;
    const sys = try testSystem(alloc, 8);
    defer sys.destroy();

    sys.setBusGain(1, 1.0); // sfx
    sys.setBusGain(2, 1.0); // music
    sys.setBusSolo(1, true);

    var g: [bus_mod.bus_count]f32 = undefined;
    sys.effectiveBusGains(&g);
    try testing.expectEqual(@as(f32, 1), g[1]); // soloed bus is audible
    try testing.expectEqual(@as(f32, 0), g[2]); // not soloed -> silenced
    try testing.expectEqual(@as(f32, 1), g[0]); // master is where the solo ends up

    // Unsolo and the other bus comes back.
    sys.setBusSolo(1, false);
    sys.effectiveBusGains(&g);
    try testing.expectEqual(@as(f32, 1), g[2]);

    // A muted soloed bus is still silent: mute wins over solo.
    sys.setBusMuted(1, true);
    sys.effectiveBusGains(&g);
    try testing.expectEqual(@as(f32, 0), g[1]);
}

test "a bus send adds a copy into the target's gain path" {
    const alloc = testing.allocator;
    const sys = try testSystem(alloc, 8);
    defer sys.destroy();

    sys.setBusGain(1, 1.0); // source
    sys.setBusGain(2, 0.5); // target
    sys.setBusSend(1, 2, 0.25);

    var g: [bus_mod.bus_count]f32 = undefined;
    sys.effectiveBusGains(&g);
    // 1.0 direct + 0.25 sent through a 0.5 target = 1.125, exactly the sum of
    // the two contributions the folded form stands in for.
    try testing.expectApproxEqAbs(@as(f32, 1.125), g[1], 0.0001);
    // The target's own gain is untouched.
    try testing.expectEqual(@as(f32, 0.5), g[2]);

    // A muted target means the send carries nothing.
    sys.setBusMuted(2, true);
    sys.effectiveBusGains(&g);
    try testing.expectEqual(@as(f32, 1.0), g[1]);

    // Clearing the send (no target) returns the bus to its plain gain.
    sys.setBusMuted(2, false);
    sys.setBusSend(1, no_send, 0);
    sys.effectiveBusGains(&g);
    try testing.expectEqual(@as(f32, 1.0), g[1]);
}

test "a long sound streams: the window stays bounded and the voice ends in time" {
    const alloc = testing.allocator;
    const sys = try testSystem(alloc, 8);
    defer sys.destroy();

    // A 20000-frame "song" (0.42 s at 48 kHz) through a 480-frame window.
    const v = try sys.playFileStream("song:20000", .{}, 480);
    // Bounded: the bank holds 480 frames (1920 B), not the 80000 B the whole
    // sound would be. That difference IS streaming, as a number.
    const window_bytes = @as(usize, 480) * @sizeOf(f32);
    try testing.expectEqual(window_bytes, sys.bank.stats().bytes_used);

    // Drive real frames: `beginFrame` refills the window, `pump` consumes a
    // period on the device side. The window must never grow.
    var i: u32 = 0;
    var saw_playing = false;
    while (i < 60) : (i += 1) {
        sys.beginFrame(i);
        sys.pump(480);
        if (i == 0) saw_playing = sys.isPlaying(v);
        try testing.expectEqual(window_bytes, sys.bank.stats().bytes_used);
    }
    // It really played (the device drained the command on the first buffer) ...
    try testing.expect(saw_playing);
    // ... and 60 periods > 20000 frames, so the one-shot ended on its own.
    try testing.expect(!sys.isPlaying(v));
}

test "the listener's rotation is part of its placement" {
    const alloc = testing.allocator;
    const sys = try testSystem(alloc, 8);
    defer sys.destroy();

    sys.setListener(10, 20, std.math.pi * 0.5);
    try testing.expectEqual(@as(f32, 10), sys.listener_x);
    try testing.expectEqual(@as(f32, 20), sys.listener_y);
    try testing.expectApproxEqAbs(std.math.pi * 0.5, sys.listener_rot, 0.0001);
}

test "hot-reload re-decodes a resident sound in place and keeps the voice" {
    const alloc = testing.allocator;
    const sys = try testSystem(alloc, 8);
    defer sys.destroy();

    const slot = try sys.load("boom:1000");
    const v = sys.play(slot, .{ .loop = true });
    sys.pump(64);
    try testing.expect(sys.isPlaying(v));
    const before = sys.bank.get(slot).?.frames;

    // A different length through the same slot: the null backend sizes its
    // synthesised PCM from the path, and `replace` re-decodes from the path it
    // is handed, so the slot grows and every voice pointing at it follows.
    try sys.bank.replace(slot, sys.device, "boom:4000");
    try testing.expectEqual(@as(u32, 4000), sys.bank.get(slot).?.frames);
    try testing.expect(before != sys.bank.get(slot).?.frames);
    // The voice is still the same voice: the slot id did not move, so a live
    // handle keeps resolving.
    sys.pump(64);
    try testing.expect(sys.isPlaying(v));

    // And the system's own entry point (same path, still resident) is a no-op
    // on the voice, not a restart: the handle must still resolve afterwards.
    try sys.reload("boom:1000");
    sys.pump(64);
    try testing.expect(sys.isPlaying(v));
}

test "a streaming slot refuses a reload instead of freeing an interior pointer" {
    const alloc = testing.allocator;
    const sys = try testSystem(alloc, 8);
    defer sys.destroy();

    const slot = try sys.loadStream("song:20000", 480);
    try testing.expect(sys.bank.isStream(slot));

    // The regression this pins: `replace` frees `pcm.samples`, and for a stream
    // that pointer is INSIDE the refill ring, not an allocation of its own.
    // Reloading one would hand the allocator a pointer it never returned.
    try testing.expectError(error.StreamNotReloadable, sys.reload("song:20000"));

    // The stream is untouched and still playable, which is the other half of
    // "refuse": it must not be left half-replaced either.
    const pcm = sys.bank.get(slot).?;
    try testing.expect(pcm.streaming);
    const window_bytes = pcm.samples.len * @sizeOf(f32);
    try testing.expectEqual(window_bytes, sys.bank.stats().bytes_used);
    const v = sys.play(slot, .{});
    sys.pump(64);
    try testing.expect(sys.isPlaying(v));
}

test "reloading a path the bank does not know loads it" {
    const alloc = testing.allocator;
    const sys = try testSystem(alloc, 8);
    defer sys.destroy();

    // The asset-watch path: a file was saved and the engine is asked about it
    // without knowing whether it is resident.
    try sys.reload("fresh:100");
    try testing.expect(sys.bank.find("fresh:100") != null);
}
