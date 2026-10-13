# AUDIO — integration plan (ROADMAP M8)

**Status:** plan (nothing here is implemented yet beyond the un-wired draft in
`src/engine/audio/`).
**Owner milestone:** M8 — Audio. **Depends on:** M2 (frame loop), M3 (Lua),
M4.5 (`Camera2D`, the Signal bus), M-project (`project.config`).
**Consumers:** the runtime (M-independent), the ImGui editor shell (M5,
"the UI"), the asset browser and the Play/Stop session (M5).

This document is the plan for taking audio from a set of un-compiled draft
files to a subsystem that (a) satisfies the M8 criteria, (b) has a complete,
documented Lua surface with metadata + generated stubs, and (c) exposes the
exact API the future editor UI needs so the UI is a *consumer*, never a
rewrite.

---

## 0. Why this plan, and the one rule it follows

The M8 criteria (ROADMAP) are: **64 simultaneous emitters with no main-thread
spikes**, and **latency ≤ 20 ms**. `spec.md` adds the constraints that make it
hard: audio runs on its own RT-safe thread (§7), the device callback must not
allocate, lock, or touch the filesystem (§3.1, §10), and every cache has a byte
budget with eviction (§3.15).

The draft code already got the *architecture* right — a backend-agnostic port, a
pure mixer, a generation-checked voice pool, buses, a lock-free command ring.
None of it is wired, and most of it does not compile. So this plan is **not a
rethink**: it is (1) make the draft real, (2) add the missing half (backend,
system, signals), (3) put the Lua + config + UI surface on top of it, and (4)
freeze the interfaces the UI will consume.

---

## 1. Current state — what exists, and what is actually broken

### 1.1 The draft (`src/engine/audio/`) is orphaned and does not compile

| File | State |
|---|---|
| `audio.zig` | Port/VTable/`Pcm`/`Stats`/`DeviceDesc`/`VoiceId`. **Good, keep it.** |
| `mixer.zig` | Pure maths: constant-power pan, squared-linear attenuation, `resampleStep`, `sampleAt`. **Good, keep it.** Tests are real. |
| `voice.zig` | `VoicePool` with generation handles and steal policy (quietest at equal priority). Tests are real. **Keep.** |
| `bus.zig` | `Registry` of 16 buses, bus 0 = master. Sound design, but `getMut` **panics** on a locked registry (spec §3.1 forbids panicking in the frame); must return an error. |
| `bank.zig` | **Corrupted.** Line 95/132/142/152/182/228 read `for (self.slots, 0..) \|*\|*s, _\| {` — invalid syntax from a bad find/replace. Lines 128–130 are a triplicated `_ = incoming_bytes;`, line 137 is `_ = void;` (illegal). Its two tests are `try expect(true)` placeholders. |
| `command.zig` | **Good.** Ring, atomics, drop-count, real tests. Keep. |
| `root.zig` | **Missing.** No module root, so the directory cannot be imported. |

The module is also **absent from `build.zig`**: there is no `audio_mod`, no
`addImport("audio", ...)`, and no test entry. Nothing in it has ever been
compiled or run.

### 1.2 There is no backend

The port defines `VTable.decode` and `VTable.createDevice`, but **no file
implements `VTable`** — neither a miniaudio backend nor a headless one. The
port's own doc comments reference a `null.zig` that does not exist.

### 1.3 Audio decoding is duplicated in the asset layer, and is buggy

`src/engine/assets/audio.zig` calls `ma_decoder_init_file` directly, so there
are **two decode paths** and **two LRU caches** (`assets/asset_manager.zig` and
`audio/bank.zig`) for the same bytes — against spec §3.15 (one owner per cache).
Concrete bugs in that path:

- `assets/audio.zig`: the unknown-length fallback allocates 65536 frames and
  reads into it once, so anything longer is **silently truncated**.
- `assets/audio.zig`: `std.mem.copy(path, &p);` copies the zeroed literal `p`
  INTO the caller's `path` slice (and would not compile anyway, since `path` is
  `[]const u8`); the path is never stored in the payload.
- `assets/audio.zig`: the error `defer` frees the buffer when the length is
  unknown, and the read-error path frees it again — a double free when both
  conditions hold.
- `assets/asset_manager.zig:142,164`: `return .idx;` — invalid syntax.
- `assets/asset_types.zig:44`: `payload: *const void` — illegal; `AssetSlot.assetType`
  is a `*const AssetType` compared against `@typeInfo(...)`.

### 1.4 The engine boundary is currently red

`src/engine/root.zig:31` does `pub const assets = @import("assets");` but
`build.zig` declares **no module named `assets`**, and there is no
`src/engine/assets.zig` file at that path. `src/engine/script/context.zig` also
names `assets.AssetManager` **without importing `assets`**. So the `engine`
module — and `script`, which imports it — **cannot compile as the tree stands.**
(The pure `project` module does compile; `zig build test-project` is green.)

**Phase 0 exists to turn this red green before anything else is built.**

### 1.5 None of the surrounding integration exists

- **Runtime:** `src/runtime/main.zig` never opens a device, never mixes, never
  drains a command ring, never feeds a listener.
- **Engine boundary:** `root.zig` does not export `audio`.
- **Lua:** no `audio.*` / `sound.*` bindings, no `metadata.bindings` entry, no
  stubs, no acceptance test.
- **Config:** `project.config` has six sections; none is audio.
- **Signals:** nothing emits on sound start/finish, so ROADMAP M8's
  "audio events → Signals" is unmet.
- **UI:** there is no UI yet (M5), so "the API for the UI" is defined *here*,
  up front, so the UI lands on top of a frozen surface instead of reshaping it.

---

## 2. Target architecture (one picture)

```
                 main thread (game / editor)                  device thread
 commands ─────────────► [CommandRing] ─────────────► mix callback (RT-safe)
 play / stop / volume        (SPSC, drop+count)         │
 buses / listener                                       │ pops commands
                                                        ▼
  Audio (system.zig)                             VoicePool + Bank PCM
   · Bank   (decoded PCM, byte budget, LRU)       mixer.zig maths
   · Voices (pool, generations)                    ▼
   · Buses  (registry, master=0)                   bus sums → master → soft clip
   · Device (port VTable)                                │
   ◄────────── [EventRing] ◄── sound_started / sound_finished (SPSC)
        drains into World signals on the main thread
```

The dividing line is the existing port's, and it holds:

- **The backend owns two things only:** the device (thread, clock, format,
  conversion) and **load-time** decoding. It never owns the mixer.
- **Everything else is engine-side and pure:** voices, banks, buses, the
  command ring, the mixer maths. `backend_null.zig` opens no device and
  synthesises PCM, so the *entire* mixing path is exercised headlessly and
  deterministically (this is what makes the phase tests and `bench-audio`
  possible on CI with no sound card).
- **The device thread never decodes.** Decoding happens at load (or from the
  editor's importer), because `ma_sound_init_from_file`-style lazy decode is
  synchronous I/O inside a frame, which §3.4 forbids.

### 2.1 File layout after this plan

```
src/engine/audio/
  root.zig               NEW  module root: Audio, Bank, Bus, Voice, mixer, backends
  audio.zig              keep  port: VTable, Pcm, Stats, DeviceDesc, VoiceId, Device
  mixer.zig              keep  pure maths (pan/attenuation/resample/sampleAt)
  mix.zig                NEW   per-sample render: voice loop, bus sums, soft clip
  voice.zig              keep  VoicePool (generation handles, steal policy)
  bus.zig                fix   no panic; errors on a locked registry; ducking fields
  bank.zig               fix   real LRU eviction, real tests
  command.zig            keep  the SPSC command ring
  events.zig             NEW   SPSC device→main ring: SoundEvent{kind,voice,slot,tick}
  system.zig             NEW   `Audio`: the owner the runtime drives
  backend_null.zig       NEW   VTable impl; synthesised PCM; `pump`
  backend_miniaudio.zig  NEW   VTable impl; ma_device + ma_decoder

src/engine/assets/
  root.zig               NEW   module root (fixes the boundary red)
  audio.zig              DELETE  absorbed by audio/backend_miniaudio.zig
```

The asset manager keeps **images/textures and (M6) the GUID registry**; all
decoded PCM lives in **one** place, the audio bank. That removes the duplicate
cache and the duplicate decoder wholesale.

---

## 3. Interfaces to freeze now (the contract the UI will consume)

These are the things a UI written later must be able to call **without touching
the audio internals**. Freezing them here is the point of this document.

| UI need (M5 shell) | Frozen API | Lives in |
|---|---|---|
| Mixer panel: per-bus slider + mute + meter | `Bus.Registry` (readable with no device) + `Audio.busPeak(id)` + `audio.buses()` in Lua | `audio/bus.zig`, `audio/system.zig` |
| Project settings editor (sliders, ranges, tooltips) | `schema.getMetadata("audio", field)` / `schema.sections` | `project/schema.zig` |
| Apply an edited config to a running engine | `runtime.Targets.audio` callback | `project/runtime.zig` |
| Asset browser: audition a clip | `Audio.playFile(path, opts)` (Zig) / `audio.play_file(path, opts)` (Lua) | `audio/system.zig` |
| Inspector for a scene emitter | `SoundEmitter2D` component (plain data, bank-slot handle) | `ecs/components/sound_emitter.zig` |
| Editor preview with no sound card | null backend selected by config | `audio/backend_null.zig` |
| Script bindings in the editor VM | `ctx.audio: ?*audio.Audio` | `script/context.zig` |
| Play/Stop restores exact state | `Audio.stopAll()` + session snapshot hook | `audio/system.zig`, `session/play.zig` |
| Debug overlay (xruns, latency, voices) | `audio.stats()` + `Stats` | `audio/audio.zig` |

**How the script module reaches the system.** `script` imports the `audio`
module directly (exactly as it already imports `physics`), and
`script/context.zig` gains `pub const AudioSystem = audio.Audio; ... audio:
?*AudioSystem = null`. A direct import is right here, unlike `lighting` (which
needed a function-pointer vtable because `render` could not be imported by
`script` without a module-file conflict): `audio` imports neither `script` nor
`ecs`, and there is no file to conflict. Null means the bindings **report
failure** rather than dereferencing null — the established rule.

---

## 4. Phases

Each phase ends green: it compiles, its tests run in `zig build test`, and it
does not move a previously-closed budget.

### Phase 0 — Make the tree green, then wire the module

*Goal: the audio directory compiles, the boundary is no longer red, and the
draft's own tests run.*

1. `src/engine/audio/root.zig`: declare `audio` as a module root re-exporting
   `Audio`, `Bank`, `Bus`, `Voice`, `mixer`, `audio` (the port), and the
   backends; add a `test { refAllDecls(@This()); }` in the engine-boundary
   style.
2. `build.zig`: create `audio_mod` (root `src/engine/audio/root.zig`, imports
   `core`; `link_libc = true`), add it to the `test` step, and add it as an
   import to `engine_mod` and to `script_mod`.
3. `build.zig`: create `assets_mod` (root `src/engine/assets/root.zig`,
   imports `core`) and import it into `engine_mod` and `script_mod` — this is
   what makes `@import("assets")` in `root.zig` and `assets.AssetManager` in
   `context.zig` resolve.
4. `src/engine/assets/root.zig`: new module root.
5. Fix `bank.zig` (`|*|*s, _|` → `|*s, i|`; delete the triplicated
   `_ = incoming_bytes;` and `_ = void;`) and make its two placeholder tests
   real (eviction respects the budget; LRU order survives accesses).
6. Fix `assets/asset_types.zig` (`payload: *anyopaque`, `assetType: AssetKind`
   enum) and `assets/asset_manager.zig` (`return .idx;`, the mismatched
   `AssetSlot` init).
7. Fix `bus.zig`: `getMut` returns an error instead of `std.debug.panic` when
   locked; keep the lock/unlock tests.

*Acceptance:* `zig build test` compiles the `engine`, `script` and `audio`
modules; the audio tests (ring, pool, mixer, bus, bank) pass.

*Risk note:* miniaudio is header-only; the module that ends up compiling it
needs `addIncludePath(libs/)` and the usual `pthread`/`dl`/`m` links. Keep the
`@cImport` in the **backend** file only, so the port, mixer, pool and bank stay
native-dependency-free and testable with nothing installed.

### Phase 1 — Backends: the device and the decoder

1. `audio/backend_null.zig` — implements `VTable` with no device: `decode`
   synthesises deterministic PCM for a small set of known names/paths (a sine
   at a fixed frequency, silence of a fixed length) so tests need no asset
   files; `createDevice` returns a context that `pump(frames)` advances by
   calling the `MixCallback`. `Stats` reports zero xruns and the requested
   period, which is what the latency test asserts against.
2. `audio/backend_miniaudio.zig` — implements `VTable` over `ma_device` +
   `ma_decoder`, using the pinned header in `libs/` (`libs/miniaudio.commit`,
   `libs/miniaudio.h`):
   - `createDevice` builds a `ma_device_config` in the requested format and
     wires `data_callback` to the `MixCallback` (the callback converts f32
     master output to the device's negotiated format — the one place a format
     conversion lives);
   - `decode` replaces the buggy `assets/audio.zig`: query length, **loop the
     read** until `MA_AT_END` when the length is unknown, store the native
     sample rate (the mixer resamples), free exactly once on every path, and
     own the path copy;
   - `stats` returns the real counters (`xruns` from the device's underrun
     callback), and reports the **negotiated** `sample_rate`/`channels` — the
     mixer resamples against *that*, never against the request.
3. `audio.createDevice(comptime kind, desc, mix, ctx)` mirroring
   `physics.createWorld(comptime backend, ...)` (a comptime `Backend` tag so a
   typo is a compile error and the unused backend's file is never linked):
   `.null` or `.miniaudio`, selected from the config flag in Phase 4.
4. `Device` gains a `name` that a log line prints (already planned).

*Acceptance:* null backend mixes headlessly and deterministically; miniaudio
opens on Linux, reports `latencyMs() ≤ 20 ms` for the default 480-frame period
at 48 kHz (already covered by a port test), and survives a no-device machine by
returning `null` (silence + a log line, never a crash).

### Phase 2 — The system (`Audio`) and the real mix loop

1. `audio/mix.zig` — the per-sample render that `mixer.zig` deliberately does
   not contain: for each output frame, walk active voices, read their cached
   `VoiceGains` (bus gain folded in), advance `cursor` by `resampleStep(...)`,
   accumulate into the 16 bus accumulators, sum buses → master, apply
   master gain, **soft-clip** (a `tanh`-ish knee or a clamped polynomial) so 64
   summed voices distort gracefully instead of wrapping, write interleaved f32.
   Keep it pure and testable by giving it the voice slice + bank view.
2. `audio/events.zig` — the reverse SPSC ring (device→main): `SoundEvent {
   kind, voice: VoiceId, bank_slot: u16, tick: u64 }`, kinds
   `{started, finished}`. Same atomics discipline as `command.zig`; fixed
   capacity, drop+count. Needed because the mixer learns a voice ended on the
   device thread and the **main thread** is what may touch the ECS/Signals.
3. `audio/system.zig` — `Audio`, the single owner the runtime drives:
   - `init/deinit`; owns `Device`, `Bank`, `VoicePool`, `Bus.Registry`,
     `CommandRing`, `EventRing`, and the listener.
   - Producer side (main thread, **zero allocation**): `play`, `playFile`
     (bank `getOrLoad`), `stop`, `stopAll`, `setVolume`, `setPitch`,
     `setBusVolume`, `muteBus`, `setMasterVolume`, `setListener` — each a
     `CommandRing.push`.
   - `beginFrame()`: `bank.advanceTick()`, snapshot the listener from the
     `Camera2D` view (or an explicit `setListener`), update the scene
     emitters.
   - `drainEvents()`, called at the frame's existing signal-drain point:
     pops `SoundEvent`s and emits typed `World` signals (Phase 5).
   - Consumer side (`mixCallback`): pop commands, allocate voices, compute
     `Placement.gains`, mix; on voice end, push a `finished` event.
   - `stats() -> audio.Stats` plus `busPeak(id)` for the UI meters.
   - `stopAll()` — the Play/Stop hook (M5 session).
   - `reload(path)` — re-decode a bank slot in place for hot-reload (Phase 6).
4. `Listener` handling: `max_distance <= 0` means **global** (music, UI) —
   never attenuated, never panned; this is already the port's documented zero
   case and it is what the UI's music channel needs.
5. **Precedence/steal policy** is already in `voice.zig`; wire `priority` and
   `tick` through `Command.Play` (both fields already exist).
6. Sample-accurate-ish start: commands are applied at the buffer boundary, so
   a `play` lands up to one period late. Document it (≤ 10 ms at the default
   period) rather than pretending otherwise; a lower `period_frames` buys it
   down at the cost of more callbacks.

*Acceptance:* `src/bench/audio.zig` (new `bench-audio` step) drives the null
backend: 64 simultaneous emitters, asserts **zero main-thread allocations**
during play (the frame-arena high-water is 0), measures the per-command cost on
the main thread and the mix cost on the device thread, and asserts
`latencyMs() ≤ 20 ms` and `xruns == 0`. The M8 criterion, as numbers a test can
fail against.

### Phase 3 — Lua surface + metadata + stubs (the "binding en Lua")

Every binding goes through `metadata.zig` first: the "no metadata → the binding
does not merge" gate is enforced by `bindings.zig`'s `assertAllDocumented`, so
this is compile-checked, not a review comment.

**`audio` — the system table (no `self`).**

| Binding | Purpose |
|---|---|
| `audio.play_file(path, opts) -> voice` | Non-positional sound (UI click, music). `opts = { bus, volume, pitch, loop, priority }`. |
| `audio.stop(voice)` / `audio.stop_all()` | Stop one / everything (Play-Stop uses this). |
| `audio.set_volume(voice, v)` / `audio.set_pitch(voice, p)` | Live control. |
| `audio.is_playing(voice) -> bool` | Handle resolves through the generation check. |
| `audio.set_master_volume(v)` | Bus 0. |
| `audio.bus_volume(name) -> number` | Read (missing name → 1, documented). |
| `audio.set_bus_volume(name, v)` / `audio.mute_bus(name, on)` | The mixer panel's writes. |
| `audio.buses() -> table` | `{ name = { gain, muted, peak } }` — what the UI reads. |
| `audio.set_listener(x, y)` | Overrides camera-derived placement. |
| `audio.stats() -> table` | voices_active, voices_peak, xruns, commands_dropped, latency_ms, period_frames, sample_rate, channels, bank_bytes. **Mirrors `physics.stats()`/`render.stats()`.** |

**`sound` — the per-actor `SoundEmitter2D` surface (takes `self`).** Modelled on
`sprite.*` / `light.*`, and on the ROADMAP's `SoundEmitter2D`:

| Binding | Purpose |
|---|---|
| `sound.play(self, path, opts) -> voice` | Positional play at the actor's transform. |
| `sound.stop(self)` | Stops the voice(s) this emitter started. |
| `sound.set_volume(self, v)` / `set_pitch(self, p)` / `set_loop(self, on)` | Live control. |
| `sound.set_radius(self, max_distance)` | 0 = global (the port's zero case). |
| `sound.set_spread(self, units)` | How far reaches full hard-pan. |
| `sound.is_playing(self) -> bool` | — |

**`voice` handle representation.** Compute the pool's `VoiceId` as a
pointer-sized token stored as **light userdata** with the same `+1` bias
convention the actor `__entity` bridge uses (`lua_topointer`, never
`lua_touserdata` for light userdata — this repo already paid for that bug
once). A stale handle is a no-op, not an error.

**Metadata + stubs.** Add one `metadata.bindings` entry per function with
`signature`, typed `params` (add `Kind.voice`/`Kind.audio_bus` if needed, else
`.any` with a doc), typed `returns`, a one-line `summary` and a **runnable
example**. `zig build stubs` regenerates `meta/ember.lua`; CI diffs it, so a
binding without an example fails the build.

**Acceptance:** a new executable in the style of `src/engine/script/
api_acceptance_test.zig` drives `audio.*`/`sound.*` from real Lua against the
null backend: play → `voices_active` rises, pan gains are correct L/R across
the stereo field, `stop` → handle is stale and a second `stop` is a no-op,
LRU eviction keeps `bank_bytes ≤ budget`, and `audio.stats()` reports `xruns
== 0`. Plus the metadata/stub gate.

### Phase 4 — `project.config`: the `audio` section and the UI settings API

The UI edits *settings*, not engine objects, so audio gets a real schema section
(type, range, default, tooltip) exactly like `display`/`physics`.

1. `project/config.zig` — add:
   ```zig
   pub const Audio = struct {
       enabled: bool = true,
       backend: enum { null, miniaudio } = .miniaudio, // .null = editor preview / CI
       sample_rate: i32 = 48000,
       period_frames: i32 = 480,          // 10 ms at 48 kHz
       voices: i32 = 256,                 // pool size, reserved at load
       budget_bytes: i64 = 32 << 20,      // decoded-PCM cache (spec §3.15)
       master_volume: f64 = 1.0,
       buses: []const BusDefault = &.{},  // { name, gain, muted } — bus 0 stays master
   };
   pub const BusDefault = struct { name: []const u8, gain: f64 = 1.0, muted: bool = false };
   ```
   and a `audio: Audio = .{}` field on `Config`.
2. `project/schema.zig` — add the `audio` section to `registry` and `sections`,
   plus `min`/`max`/`options`/`tooltip` for each field (`voices` 1..256,
   `period_frames` 64..8192 with a tooltip naming the latency trade-off,
   `sample_rate` as an enum of `{44100, 48000}`, `budget_bytes` 1 MiB..256 MiB),
   and the `audio.bus` list. The comptime struct↔table consistency check
   refuses to compile until `config.zig` and the table agree.
3. `project/runtime.zig` — add `audio: ?*const fn (*anyopaque, *const
   config.Audio) void` to `Targets` and one line to `apply` (validate-once,
   then hand the section over — the existing pattern).
4. `src/runtime/project_hook.zig` — the real glue (the file that *can* see both
   `project` and `audio`): construct the `Bus.Registry` from `buses` **before
   `lock()`**, set pool size / bank budget / device desc, and select the
   backend. A bad value is refused by `schema.validate` before anything is
   half-applied (the property `apply`'s tests already assert).
   *Note:* this file is named by the doc comments in `project/runtime.zig` and
   `project/config.zig` but **does not exist yet** — it has to be created
   (or, if the runtime stays a single file, `main.zig` grows the hook and the
   doc comments are corrected; either way, one of the two must change so the
   comments do not point at a missing file).
5. `samples/project.config` — add a commented `audio { ... }` block so the
   reference document stays the source of truth the round-trip test reads.

**Acceptance:** the `project` suite round-trips the new section, `validate`
rejects an out-of-range `voices`, and `apply` hands `audio` to the hook. The UI
can now build the whole audio settings panel from `schema.getMetadata` with no
audio-specific UI code.

### Phase 5 — Signals ("audio events → Signals")

The Lua side's `on_signal(name)` currently receives **only the name**
(`behavior.dispatchSignal(name)`), while `actor.emit`'s payload is the empty
struct. Two options, and this plan picks one:

- **Chosen:** extend the signal bridge so an engine-typed signal can carry a
  small payload into Lua as a table (`SoundFinished{ path, bank_slot, voice }`,
  ≤ `signals.max_payload` = 64 B). `Audio.drainEvents()` emits through
  `world.signals` at the existing drain point, so on the main thread, in
  stable order, with the emitting `tick` attached (spec §6).
- **Fallback if the payload bridge is deferred:** encode the discriminator in
  the *name* (`"sound_finished:" .. path`). Documented as strictly worse,
  because a listener then pattern-matches strings.

Bindings to add: `audio.on_finished(fn)` is **not** proposed — a Lua closure
crossing the RT boundary is the thing the command/event rings exist to avoid.
The signal is the interface.

**Acceptance:** an acceptance check plays a one-shot, lets the null backend
`pump` past its length, drains signals, and asserts `on_signal` saw
`sound_finished` with the right slot. Also a `sound_started` counterpart.

### Phase 6 — Hot-reload, emitters, and the editor lifecycle

1. **Hot-reload.** `platform/inotify.zig` gives a file watcher; when a `.wav`/`.ogg`
   changes, the editor calls `Audio.reload(path)`: re-decode into the *same*
   bank slot, re-point live voices whose `bank_slot` matches, and clamp each
   `cursor` to the new length (a shorter file must not read past the end —
   `sampleAt` already holds the last frame, but the cursor should be clamped so
   a loop point stays sane). Reload must preserve playback position, matching
   the M3 hot-reload promise for scripts.
2. **`SoundEmitter2D` component.** A plain-data component
   (`ecs/components/sound_emitter.zig`) beside `Timer`/`Camera2D`:
   `{ bank_slot: u16, bus: u8, volume: f32, pitch: f32, loop: bool,
   max_distance: f32, spread: f32, autoplay: bool, playing: VoiceId, tick: u64 }`.
   The editor resolves an asset path → bank slot at load and writes the **id**
   into the `.zson` (bit-exact, per the M1 rule; strings are not saved in
   components). Registered in `components/registry.zig` **appended at the next
   dense id** — the registry ids are load-bearing (the ids every committed
   `.zson` rests on cannot move; M4.5 appended `Light2D` kinds and `Camera2D`
   for exactly this reason). A test pins the id.
3. **Play/Stop.** `session/play.zig`'s snapshot must decide what happens to
   audio: the honest, deterministic choice is **stop-all on Stop** and let the
   re-simulated frames re-trigger sounds; if the session wants *audible*
   continuity it snapshots the active `(path, bus, volume, x, y, cursor)`
   tuples too. Pick one and test it; a half-restored mixer is worse than a
   silent Play.
4. **Lifetime.** A scene change despawns emitters → `Audio.stop(voice)` for
   each, then `drainEvents` so the `finished` signal is not attributed to the
   wrong tick.

*Acceptance:* editing a WAV keeps a looping music voice seamless; a scene
round-trips with its emitter component and the same hash; Stop leaves
`voices_active == 0` and a fresh Play reproduces the same sound events.

### Phase 7 — Docs, deps, and the milestone close

1. `docs/reference/audio-*.md` — a reference page per concern (`audio-system`,
   `audio-buses`, `audio-emitters`, `audio-config`), and add them to
   `docs/README.md`'s Level-3 and reference-index tables.
2. `DEPENDENCIES.md` — record miniaudio (`libs/miniaudio.commit`, the pinned
   SHA), the build flags, and why it is vendored rather than linked.
3. `spec.md` — add the audio rows to the memory table (bank budget, command-ring
   reservation, voice-pool reservation) so §3.15 accounts for them.
4. `ROADMAP.md` — flip M8 to closed with the measured numbers, the way M4/M7
   were closed (a table of criterion vs measured vs budget).
5. `PROFILING.md` / `ember-profile` — add the audio metrics (main-thread
   command cost, mix callback cost, xruns, latency) to the CI gate's metric set
   so a regression is red CI, not a subjective "sounds worse".

---

## 5. Acceptance — the whole thing, as one checklist

The M8 criteria (ROADMAP) and this plan's additions, as pass/fail:

| # | Criterion | Where it is checked |
|---|---|---|
| 1 | 64 simultaneous emitters, no main-thread spike | `bench-audio` (null backend) |
| 2 | Output latency ≤ 20 ms | `audio.zig` unit test + `bench-audio` |
| 3 | Zero allocations in the frame loop while audio plays | `bench-audio` arena high-water == 0 |
| 4 | `xruns == 0` on a real device | `Stats` + the runtime log |
| 5 | Bank stays within `budget_bytes`; LRU evicts | `bank.zig` tests + acceptance |
| 6 | Every `audio.*`/`sound.*` binding has metadata + example; stubs regenerated and diffed | `assertAllDocumented` + `zig build stubs` in CI |
| 7 | `sound_finished` / `sound_started` reach Lua as signals with the right slot | Lua acceptance executable |
| 8 | `project.config` `audio` round-trips, validates, and applies | `project` suite |
| 9 | The UI can read/write every audio setting with no audio-specific UI code | `schema.getMetadata` coverage test |
| 10 | Play/Stop leaves the mixer in a defined state, reproducibly | `session` tests |
| 11 | Hot-reloading a WAV preserves playback position | inotify + `Audio.reload` test |

---

## 6. Risks and open decisions

- **Deliberate non-goals for v1:** spatial reverb, filters/EQ, side-chain
  compression, streaming *decode* (music longer than the budget is handled by
  a larger budget, not by a streaming decoder — revisit if a real project
  needs a 20-minute track under a 32 MiB bank). Ducking is a `bus.zig` field
  (a bus gain scaled by another bus's activity) and can land in M8 or be
  deferred; state it either way.
- **`Assets` vs `Audio` ownership.** This plan gives PCM to `Audio` and images
  to `Assets`. If M6's GUID asset registry needs a single unified handle space,
  the bank slot becomes an asset id and `Audio` reads through `Assets` — the
  interface above does not change.
- **Web (M10).** The port exists precisely so the Web target swaps in a Web
  Audio backend; `backend_null` also makes the Web *tests* run with no device.
  Keep the `MixCallback` signature and the "no threads on the device side"
  assumption in mind (spec §8) — the backend interface is already shaped for it.
- **The RT thread and determinism.** Audio must never feed the simulation
  (no gameplay branching on `is_playing` for anything that affects state),
  or the fixed-step determinism contract (spec §6) is broken by a thread the
  simulation does not control. State this in `docs/architecture/determinism.md`.
- **miniaudio as a single TU.** It is header-only and large; compiling it in
  exactly one module (`backend_miniaudio.zig`) keeps the rest of the audio
  module free of C and testable with nothing installed.

---

## 7. Task list (ordering)

1. [x] Phase 0 — `audio/root.zig`, `assets/root.zig`, `build.zig` modules,
   fix `bank.zig` / `bus.zig` / `assets/*`; tree green.
2. [x] Phase 1 — `backend_null.zig`, `backend_miniaudio.zig`, `createDevice`.
3. [x] Phase 2 — `mix.zig`, `events.zig`, `system.zig` (`Audio`), `bench-audio`.
4. [x] Phase 3 — `audio.*` + `sound.*` bindings, metadata, stubs, Lua acceptance.
5. [x] Phase 4 — `config.Audio`, schema section, `Targets.audio`, project hook,
   sample config.
6. [x] Phase 5 — payload signal bridge, `sound_started`/`sound_finished`.
7. [x] Phase 6 — `Audio.reload` + inotify, `SoundEmitter2D`, Play/Stop policy.
8. [x] Phase 7 — docs, deps, spec/ROADMAP/PROFILING, CI metrics.
