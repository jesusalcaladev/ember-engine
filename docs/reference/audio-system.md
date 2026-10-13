# Audio: the mixer

**Source:** `src/engine/audio/` (`audio.zig` the port, `mixer.zig` the maths,
`voice.zig` the pool, `bank.zig` the PCM cache, `bus.zig` the buses,
`command.zig` + `events.zig` the rings, `mix.zig` the render loop,
`system.zig` the owner, `backend_null.zig` / `backend_miniaudio.zig` the two
backs)

Audio is the one subsystem in the engine with a second thread that the
simulation does not control. Everything in this page follows from that: the two
threads never share mutable state, the device thread never allocates, and the
only thing that crosses between them is a fixed-size command ring and a
fixed-size event ring.

---

## The two threads

```
                main thread (game / editor)              device thread
  audio.play(slot) ──► CommandRing ──────────────► mixCallback (RT-safe)
  audio.stop / set_volume   (SPSC, drop+count)      │ pops commands
  bus gains · listener · master                      ▼
                                          VoicePool + Bank PCM (read)
                                                     mixer maths
                                                     ▼
                                          bus sums → master → soft clip
  Audio.drainEvents() ◄──────── EventRing ◄── started / finished
        │                    (SPSC, drop+count)
        ▼
  world.signals → Lua `on_signal("sound_finished", …)`
```

| Who | Owns |
|---|---|
| Main thread | the pool's STRUCTURE (`VoicePool.allocate` reserves a slot), the bank, the bus map, the listener, every command |
| Device thread | a live voice's RUNTIME state: it fills the reserved slot, advances the cursor, computes the level, clears `active` when the sound ends |

The dividing line is the port's and it holds: **the backend owns exactly two
things** — the device (its thread, its clock, its format) and load-time
decoding. Everything else is engine-side and pure, which is what makes the whole
mixing path testable with no sound card.

`backend_null` opens no device and synthesises deterministic PCM for any path
(`"boom:100"` is a 100-frame tone), so every test and both benches drive the
REAL mixer through `pump`. A machine with no sound card is not a special case;
it is the default for CI.

---

## The pieces

| File | What it is | The rule it enforces |
|---|---|---|
| `audio.zig` | the port: `VTable`, `Pcm`, `Stats`, `DeviceDesc`, `VoiceId`, `Device` | no engine type appears in a backend |
| `mixer.zig` | constant-power pan, squared-linear attenuation, `resampleStep`, `sampleAt` | pure functions, no allocation, no I/O |
| `voice.zig` | fixed voice pool, generation-checked handles, steal policy | a pool that must not allocate cannot create a voice — it steals |
| `bank.zig` | decoded-PCM cache with a byte budget and LRU eviction | one owner per sound's bytes (spec §3.15) |
| `bus.zig` | 16 named gains, bus 0 is master | a locked registry refuses a write instead of panicking in the frame |
| `command.zig` | SPSC main→device ring | drop and COUNT rather than block |
| `events.zig` | SPSC device→main ring | only the main thread touches the ECS |
| `mix.zig` | the per-sample render | the device thread's inner loop |
| `system.zig` | `Audio`: the owner the runtime drives | one per process (the runtime owns one, the editor owns one) |

### `Audio` — the one object

```zig
var sys = try audio.Audio.create(alloc, .miniaudio, .{
    .desc = .{ .sample_rate = 48000, .period_frames = 480, .channels = 2 },
    .voices = 128,
    .budget_bytes = 16 << 20,
});
defer sys.destroy();
sys.defineBuses(&.{ "master", "music", "sfx", "ui" }) catch {};
```

`create` takes a comptime backend tag, so a typo is a compile error and an
unused backend's file is never linked. `miniaudio` falls back to the null
backend when there is no device: a machine with no sound card runs silent and
says so in the log, rather than failing to boot.

The runtime creates it from `project.config`'s `audio` section, publishes it to
Lua as `ctx.audio`, drains its events at the frame's signal point, and reads its
counters into the profile report (see [PROFILING](../../PROFILING.md)).

---

## Frames of reference (which call, and when)

The split that matters is not "fast vs slow" but **which thread and which
guard**:

| Call | Thread | May decode | May allocate |
|---|---|---|---|
| `play(slot, opts)` | main | no | no — one ring push |
| `stop` / `stopAll` / `setVolume` / `setPitch` | main | no | no — one ring push |
| `setBusGain` / `setBusMuted` / `setBusSolo` / `setBusSend` / `setMasterGain` | main | no | no — plain fields |
| `setListener`, `beginFrame` | main | no | no |
| `load` / `playFile` / `playFileStream` / `loadStream` | main | **yes** | yes — load time only (spec §3.4) |
| `reload(path)` | main | **yes** | yes — the asset hot-reload path |
| `drainEvents` | main | no | no |
| `mixCallback` | device | never | never |

`play_file` is therefore a preview/authoring call: it decodes on demand. A game
that fires gameplay sounds should resolve a bank slot at load (a scene's
`SoundEmitter2D.bank_slot`, or an explicit `load`) and play the slot, which is
the frame-safe path.

---

## The voice pool

`voices` is reserved at load. When the pool is full, `play` **steals**: the
lowest priority first, then the quietest, then the lowest slot — so the choice
is deterministic when everything ties. Stealing is counted (`pool.steals`) and
visible in `audio.stats()`'s `voices_peak`.

A voice handle is `{ index: u32, generation: u32 }`. The generation is the point:
a slot recycled since the handle was issued answers with a different generation,
so `stop` against a finished sound does nothing rather than stopping whatever is
playing now. In Lua the handle travels as **light userdata** with a `+1` bias
(the actor `__entity` bridge's convention — a voice with index 0 and generation
0 is a NULL pointer, and Lua hands NULL light userdata back as NULL).

---

## The bank

One budget, one owner, LRU eviction. A sound larger than the whole budget is
refused (`error.OutOfMemory`) rather than evicting everything to fit.

**Slot 0 is reserved as the "nothing loaded" sentinel.** `Voice.bank_slot` and
`SoundEmitter2D.bank_slot` both default to it, and the bank never hands it out —
otherwise an emitter that never configured a sound would name the first sound
anyone decoded.

Streams are the other shape: `openStream` keeps a WINDOW of a long sound (four
device periods by default, ~40 ms) and `beginFrame` refills it on the main
thread, because the device thread must never touch the disk (spec §3.4, §10). The
window is charged to the same byte budget as decoded PCM, so streaming cannot
smuggle memory past §5.

---

## Latency, and what "no spike" means

Latency is `period_frames / sample_rate` of the device the mixer actually
negotiated — read back from the device after `start`, never the requested rate.
The default (480 frames at 48 kHz) is **10 ms**, well inside the M8 budget of
20 ms; `period_frames` is the dial that trades it against callback frequency.

"No main-thread spikes" is enforced, not asserted: `zig build bench-audio`
drives 64 simultaneous emitters through the null backend with a counting
allocator wrapping the system allocator, and fails if `play()` or the mix moves
the allocation count at all.

---

## Debugging

| Question | Where |
|---|---|
| Is anything playing? | `audio.stats()` — `voices_active`, `voices_peak` (Lua, or the run's exit report) |
| Is it crackling? | `xruns` — one underrun is one audible glitch |
| Did a sound never play? | `commands_dropped` — the ring was full |
| Is the mix too slow? | `audio_mix_ns` in the report, and the `audio` zone for the main thread |
| Where did the bytes go? | `bank_bytes` / `bank_budget` in `audio.stats()` |
| What is on a bus? | `audio.buses()` — name, id, gain, muted, solo, send |

The run's exit report prints the mixer's numbers next to the renderer's, because
audio's failure mode is not a crash — it is a crackle, and a counter nobody
reads is the same as no counter.
