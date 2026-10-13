# Audio: buses

**Source:** `src/engine/audio/bus.zig` (the registry),
`src/engine/audio/system.zig` (the gains, solo and sends)

A bus is a named gain with a mute flag. Sixteen of them, bus 0 is master for
good, and every voice names the bus it feeds. That is the whole model — the rest
of this page is what makes it useful.

---

## The map

`project.config` names the buses:

```
audio {
  buses "master" "music" "sfx" "ui"
}
```

`Audio.defineBuses` copies those names (it owns them — a hot-reload frees the
config arena they came from) and `AudioHook.create` calls it at boot. Item `i`
of the list names bus `i`; item 0 is skipped because bus 0 cannot be renamed.

Nothing may rewrite the map afterwards: `bus.zig`'s registry **locks**. A
`setName` after `lock` returns `error.AccessDenied` instead of panicking, so a
late editor callback cannot corrupt the map the device thread is reading.

An unnamed bus is not an error — it is a channel the project declared no name
for, and `audio.buses()` simply reports an empty name for it.

---

## The gain the mixer actually applies

`Audio.effectiveBusGains` is the function the device thread calls, and it is the
only place mute, solo and sends are folded together:

```
base[b] = muted[b] ? 0 : gain[b]
if (any bus soloed and b != 0) base[b] = soloed[b] ? base[b] : 0
out[b]  = base[b] + send_amount[b] * base[send_to[b]]
```

Three consequences worth stating, because each one is a decision a sound
designer can feel:

- **Mute wins over solo.** A muted bus that is also soloed is still silent:
  solo says "the others off", mute says "this one off", and both are true.
- **Solo never targets master.** With `sfx` soloed, master still passes — master
  is where the soloed signal ENDS UP. "Solo master" would mean "solo
  everything".
- **Sends fold into the SOURCE bus's gain**, not into a second pass. A source at
  1.0 sending 0.25 into a target at 0.5 contributes `1.0 + 0.25×0.5 = 1.125`,
  which is exactly the sum of the two contributions, at no per-voice cost.

Sends are one level: a send of a send is not followed. One level is what a
reverb or duck bus actually needs, and it keeps the frame cost a fixed two
passes over 16 buses.

---

## From Lua

| Call | Reads / writes |
|---|---|
| `audio.buses()` | every named bus as `{ name, id, gain, muted, solo, send_to, send_amount }`, in bus order |
| `audio.bus_gain(bus)` | current gain by name or id; a missing name reads as 1 |
| `audio.set_bus_volume(bus, gain)` | what a mixer slider writes (clamped 0..10) |
| `audio.mute_bus(bus, muted)` | muted voices keep PLAYING, silently |
| `audio.solo_bus(bus, solo)` | the mixer panel's "S" button |
| `audio.set_bus_send(bus, target, amount)` | an aux/reverb send; a nil `target` clears it |
| `audio.set_master_volume(gain)` | bus 0 (clamped 0..4) |

A bus argument is a **name or an id**, because an editor has the name and a
script often has the number. A name that resolves to nothing reports the
documented default (gain 1) rather than failing, so a project with no audio
section still behaves.

Everything here is a plain field write or a read — no ring push, no allocation.
The device thread picks the new gain up at the next buffer, which is why a
slider drag does not click.

---

## What a bus is not

- **Not a group of actors.** A voice names its bus when it starts; moving it is
  stopping it and playing it again.
- **Not per-voice.** Per-voice gain is the emitter's `volume` (`audio.set_volume`
  for a handle), applied BEFORE bus gain.
- **Not a panner.** Left/right placement is the listener's, not the bus's: see
  [audio-emitters](audio-emitters.md) and `audio.set_listener`.
