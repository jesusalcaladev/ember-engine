# Audio: emitters and the `sound` surface

**Source:** `src/engine/ecs/components/sound_emitter.zig` (the component),
`src/engine/script/bindings.zig` (the `sound.*` table)

`audio.*` is about SOUNDS — a UI click, music, an audition. `sound.*` is about
**this actor's emitter**, and it is the half of the audio surface a scene
actually uses: the component says what the actor sounds like, the bindings say
when.

---

## The component is the configuration

```zig
pub const SoundEmitter2D = struct {
    bank_slot: u16 = 0,      // 0 = nothing loaded; the editor writes the ID
    bus: u8 = 0,             // 0 is master; the project names the rest
    volume: f32 = 1.0,
    pitch: f32 = 1.0,
    loop: bool = false,
    max_distance: f32 = 0.0, // 0 = GLOBAL (never attenuated, never panned)
    spread: f32 = 400.0,     // distance to full hard-pan
    autoplay: bool = false,
    playing: VoiceRef = .{}, // the voice this emitter started
    tick: u64 = 0,           // the frame it started in
};
```

It is plain data, which is the M1 rule: a `.zson` document writes it, it is
bit-exact, and a hot-reload keeps it. The `bank_slot` is an **id, not a path** —
the editor resolves `assets/audio/boom.wav` to a slot at load, exactly the way
`Sprite` stores an atlas slot.

### Why the voice handle is declared twice

`playing` is naturally an `audio.VoiceId`, but `ecs` is the module everything
imports and `audio` pulls in miniaudio — a real device, a real decoder, a C
translation unit. Importing it for two `u32`s would link all of that into every
ECS consumer. So the handle is a local `VoiceRef` with the same shape, and
`script/bindings.zig` — the one place that sees both modules — pins the layouts
equal with a comptime assert. If they ever drift, the build fails instead of a
component silently holding a handle the mixer misreads.

---

## `sound.*` — the verbs

Every one takes `self` (the behaviour's actor) and does one `world.get` plus, at
most, one command-ring push.

| Call | What it does |
|---|---|
| `sound.play(self, path?, opts?) -> voice` | plays at the actor's transform. With a `path` it may decode (author-time); without one it plays the emitter's resolved slot (frame-safe) |
| `sound.stop(self)` | stops the voice this emitter started; a no-op when it already ended |
| `sound.set_volume(self, v)` / `sound.set_pitch(self, p)` | writes the emitter AND pushes the live command |
| `sound.set_loop(self, on)` / `sound.set_radius(self, r)` / `sound.set_spread(self, s)` | writes the emitter — takes effect on the NEXT play |
| `sound.is_playing(self) -> boolean` | asks the SYSTEM, then clears a stale handle |
| `sound.describe(self) -> table` | every readable field, for an inspector |

```lua
function M:start()
  -- a one-shot at this actor's position, on the sfx bus
  self.blast = sound.play(self, "assets/audio/boom.wav", {
    volume = 0.8, max_distance = 600, bus_name = "sfx",
  })
end

function M:update(dt)
  -- the frame-safe form once the slot is resolved: no decode, one push
  if not sound.is_playing(self) then sound.play(self) end
end
```

### The setters that are next-play only

`set_loop`, `set_radius` and `set_spread` write the component and do NOT touch a
running voice. A voice's loop flag and its placement are computed when it starts
on the device thread; changing either mid-voice is a click at the loop point or a
sound that jumps. There is no command for it, and pretending otherwise would be
the bug. `set_volume` and `set_pitch` DO reach the running voice, because the
command for both exists.

---

## Placement: global, panned, attenuated

The listener is `audio.set_listener(x, y, rot)` — by default the camera's centre,
which the runtime folds in every frame. Placement then follows one rule:

| `max_distance` | Behaviour |
|---|---|
| `0` | **global**: never attenuated, never panned. Music, UI, ambience |
| `> 0` | squared-linear attenuation to that distance, and constant-power pan across `spread` |

The listener's rotation turns the pan axis with the ears: a sound to the
world-east pans RIGHT when the ears face +x.

---

## Hot-reload by asset

Saving a `.wav`/`.ogg` under the project's sound directory re-decodes it **into
its bank slot**: the slot keeps its id, so a voice already playing that slot
picks up the new bytes with no restart and no position jump.

```
assets/audio/            <- watched (one inotify directory watch, not one per file)
  boom.wav               <- edit it: Audio.reload("assets/audio/boom.wav")
```

The path is spelled the way a script plays it, which is what makes the reload
find the slot: `Bank.find` is a string match. Three refusals are deliberate:

- a non-audio write is ignored (the watcher reports every write in the
  directory and knows nothing about audio);
- a file the bank does not hold is ignored — reloading would DECODE a sound
  nobody is playing and charge it to the PCM budget, evicting one that is. An
  evicted sound is decoded again the next time it plays;
- a **streaming** slot is refused with `error.StreamNotReloadable`: its PCM is a
  window into a refill ring, so "replacing" it would free an interior pointer.
  Stop the voice and play it again.

The runtime watches only in a windowed run; a headless CI box has no one editing
sounds. The watcher itself is `platform.watchDirectory`
(`src/engine/platform/inotify.zig`), which reports the entries that changed and
leaves the extension filter to the caller.

---

## Signals

A voice reports `sound_started` when the device thread fills it and
`sound_finished` when it ends, carrying `{ slot, voice, generation, tick }`:

```lua
function M:on_signal(name, data)
  if name == "sound_finished" then self.cooldown = data.tick end
end
```

`data` is a table with `slot` (the bank slot), `voice` and `generation` (the
handle that ended) and `tick`. The payload is POD bytes on the typed bus, so
`path` is deliberately not a field: a listener that wants the name asks the bank,
which is what owns it. The `tick` is the frame the sound was ISSUED at, not the
buffer it ended in, so two listeners cannot disagree about "when".

A handler written before payloads existed — `function M:on_signal(name)` — keeps
working and simply receives `nil` for the second argument.
