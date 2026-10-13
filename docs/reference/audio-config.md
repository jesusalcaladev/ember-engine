# Audio: `project.config`

**Source:** `src/engine/project/config.zig` (the `audio` section and its defaults),
`src/engine/project/schema.zig` (the UI-facing metadata: type, range, tooltip),
`src/runtime/project_hook.zig` (the glue that turns a section into a mixer)

Everything here is a **boot-time** setting: the device, the pool and the byte
budget are fixed once the system exists. That is why the editor applies a changed
section by REBUILDING the mixer rather than poking it — an edit to
`display.width` must not drop every voice and glitch the device.

---

## The section

```
audio {
  enabled true
  backend "miniaudio"
  sample_rate "48000"
  period_frames 480
  voices 128
  budget_bytes 16777216
  master_volume 0.8
  buses "master" "music" "sfx" "ui"
}
```

| Field | Default | Range | Meaning |
|---|---|---|---|
| `enabled` | `true` | — | Open a device at all. Off = nothing is mixed; the Lua surface still answers, with zeros |
| `backend` | `miniaudio` | `null` \| `miniaudio` | `null` mixes with no device (editor preview, CI). It still runs every buffer, so tests exercise the real mixer |
| `sample_rate` | `48000` | `44100` \| `48000` | REQUESTED rate. The mixer resamples to whatever the device negotiates, which is what `Audio.stats()` reports |
| `period_frames` | `480` | 64..8192 | Frames per device callback — the latency dial. 480 at 48 kHz is **10 ms**; halving it halves the latency and doubles the callbacks |
| `voices` | `256` | 1..256 | Voice pool size, reserved at load. Past it a play STEALS the quietest voice at equal priority; it never drops silently |
| `budget_bytes` | 32 MiB | 1 MiB..256 MiB | Decoded-PCM ceiling (spec §3.15). The LRU evicts to stay under it. 32 MiB is roughly 90 seconds of stereo 48 kHz |
| `master_volume` | `1.0` | 0..4 | Master gain (bus 0), applied after every bus sum. Above 1 is allowed and soft-clipped |
| `buses` | `"master" "music" "sfx" "ui"` | ≤ 16 items | Bus names INDEXED BY BUS ID. Item 0 is master and is never renamed; the rest are what `audio.set_bus_volume("music", …)` resolves |

### What is deliberately NOT here

Per-bus gains and mutes. Those are runtime mixer state — the mixer panel's
sliders — and a project file that pinned them would make every play session
start with yesterday's mix. A bus's GAIN is a setting; a bus's LEVEL is state.

---

## How a section becomes a mixer

```
project.config ──► project.schema.validate ──► project.runtime.apply ──► AudioHook.apply
                                                                              │ (stores the section)
                                                                    AudioHook.create ──► audio.Audio.create
                                                                                          └─► defineBuses (copies the names)
```

Validation runs FIRST, so `AudioHook` never has to handle a half-applied section:
a `voices` value of 0 is refused by `schema.validate` before anything is built,
which is the property `project.runtime.apply`'s tests assert.

`AudioHook.sync` is what a hot-reload calls. It compares the section against what
the live system was BUILT from — scalars directly, bus names against the system's
own registry, which owns copies of them because the config arena is free to be
freed — and rebuilds only when something actually changed.

---

## For the editor

The UI never needs audio-specific code. `schema.getMetadata("audio", "period_frames")`
returns the type, the range, the default and the tooltip, so a settings panel is
generated: sliders for the numbers, a dropdown for the enum and the sample-rate
pair, and a name list for `buses`. The comptime check in `schema.zig` refuses to
compile until the table and the struct agree, which is what keeps a generated
panel from advertising a field that does not exist.

The one audio-specific thing an editor still needs is the audition path:
`audio.play_file(path, opts)` from Lua, or `Audio.playFile` from Zig, both of
which decode on demand and are therefore preview-only. Gameplay plays a resolved
bank slot — see [audio-emitters](audio-emitters.md).
