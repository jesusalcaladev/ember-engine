# Timer — component id 19

**Registry name:** `Timer` · **id:** 19


**What it is:** a gameplay clock that fires **named signals** instead of calling back. Reach for it whenever you would write "in 3 seconds, do X": cooldowns, respawn waves, a telegraph that must finish, a status that refreshes.

| Field | Type | Default | Meaning |
|---|---|---|---|
| `duration` | `f32` | `1.0` | Seconds per cycle |
| `elapsed` | `f32` | `0.0` | Seconds accumulated in the current cycle |
| `kind` | `TimerType` | `.once` | `once` (0), `loop` (1), `during` (2) |
| `loop_count` | `u32` | `0` | Total cycles for `loop`/`during`; 0 = forever |
| `current_loop` | `u32` | `0` | Cycles completed so far |
| `paused` | `bool` | `false` | A paused timer is skipped by the tick and keeps its elapsed time |
| `finished` | `bool` | `false` | Set when a `once` fired, or a `loop` exhausted `loop_count` |
| `time_scale` | `f32` | `1.0` | **This timer's own speed** |
| `dropped_cycles` | `u32` | `0` | The cycles it could not run, and why |
| `tick_signal` | `Name` | empty | Fired **every tick** while `kind == .during` |
| `done_signal` | `Name` | empty | Fired when a cycle completes |

`TimerType`: `once` fires `done_signal` once after `duration`; `loop` fires it every `duration`, `loop_count` times; `during` is `loop` plus a `tick_signal` every tick, so a telegraph bar can redraw without a second clock.

**Driven by:** `ecs/timer.zig` — `tick(world, dt, bridge)`, **on the FIXED step**, *before* the behaviours run, so a script's `fixed_update` sees exactly the signals its own timers fired this tick.

**Lua:** `timer.new(self, seconds, kind)`, `timer.set_signals(self, on_tick, on_done)`, `timer.start(self, loops)`, `timer.stop(self)`, `timer.kill(self)`, `timer.progress(self)`, `timer.restart(self)`, `timer.set_duration(self, s)`, `timer.get_duration(self)`, `timer.get_elapsed(self)`, `timer.get_loops(self)`, `timer.set_kind(self, kind)`, `timer.set_time_scale(self, s)`, `timer.is_finished(self)`, `timer.is_paused(self)`, `timer.get_dropped(self)`.

**Connects to:** the world signal bus (typed Zig listeners get a `TimerEvent`) and the `SignalBridge` (Lua `on_signal` handlers). It also feeds the **tweens**: `tween.to(self, "duration", 2.0, 0.5)` can stretch a timer.

**Gotchas:**
- **There is no `autostart` field.** A timer in the world ticks from the moment it exists — a timer declared in a scene file runs with no script at all. A timer that should NOT start has `paused = true`.
- `duration <= 0` is degenerate: it fires `done_signal` **once** and finishes.
- For `.during`, the tick signal fires **before** the completion signal in the same tick, by contract.
- `timer.start` resets `elapsed`/`current_loop`/`finished` and sets `loop_count`; it does not "unpause" a `once` timer that already fired without `timer.restart`.
- The bus emit is gated on `hasListeners`, so a signal nobody subscribed to does not enqueue.
- `dropped_cycles` counts the cycles the catch-up cap refused. It is zero in a healthy game; a number that grows says the timer is running **late**.

---

---

← [Component index](README.md) · [Registry mechanics](../ecs-components.md) · [Lua API](../script-lua-api.md)
