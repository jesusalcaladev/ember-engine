# Profiling ember

How to measure the engine, where the numbers come from, and how CI blocks a
performance regression. Everything here implements `spec.md` (budgets are law,
§0 and §9): the profiler is not a nice-to-have dashboard, it is the instrument
the budgets are checked with.

- [Quick start](#quick-start)
- [What gets measured](#what-gets-measured)
- [The frame is split: work vs wall](#the-frame-is-split-work-vs-wall)
- [The runtime flags](#the-runtime-flags)
- [The report: log, JSON, trace](#the-report-log-json-trace)
- [The CI gate: `ember-profile`](#the-ci-gate-ember-profile)
- [Budgets and verdicts](#budgets-and-verdicts)
- [Instrumenting your own code](#instrumenting-your-own-code)
- [Design notes and cost](#design-notes-and-cost)

## Quick start

```bash
# 600 frames, print the report on exit, write the machine-readable one
zig build run -- --frames 600 --report-json report.json

# the same numbers, pretty-printed + the spec.md verdicts
./zig-out/bin/ember-profile report.json

# freeze a baseline, then fail CI when a metric regresses more than 5%
./zig-out/bin/ember-profile report.json --baseline baseline.json
echo $?    # 0 = ok, 1 = regression or failed verdict, 2 = bad input

# Chrome/Perfetto trace (open at https://ui.perfetto.dev)
zig build run -- --frames 600 --trace run
#   => run.perfetto-trace
```

`ember-profile` is built by `zig build` and installed next to `ember`. It
links neither Dawn nor GLFW, so it runs on a headless CI container.

## What gets measured

| Instrument | Source | Cost per frame |
|---|---|---|
| CPU zones | `rdtscp` TSC (calibrated against `clock_gettime`, invariant on modern x86) or `clock_gettime` fallback | ~28 ns/zone |
| Frame rings | exact `beginFrame..endFrame` and work-frame durations, 4096-frame rings | 2 stores |
| GPU timestamps | WebGPU `QuerySet` + non-blocking `mapAsync` readback (2 frames of latency) | ~0 when off |
| Counters | draw calls, passes, uploads, allocs, arena high-water, steps, drops | plain adds |
| RSS + CPU% | background thread reading `/proc/self/stat`, 250 ms period | 0 (other thread, no locks in the frame) |

Every run ends in a **verdict** against `spec.md`, not in a pretty table: PASS,
FAIL or `unknown` (system not implemented yet — e.g. `physics` before M4).

## The frame is split: work vs wall

With vsync on, the swapchain acquire **waits** for the previous frame to be
displayed. That wait is not engine work, and charging it to the frame would
make every budget meaningless (everything would "take" 16.6 ms). So:

- **wall frame** = the whole iteration (`loop_start` to next `loop_start`),
  including the vsync wait. `p50 ≈ 16.7 ms` at 60 FPS is *correct* here.
- **work frame** = wall minus the `render_acquire` zone. This is the number
  the spec.md budgets apply to (§2), and the one the gate watches.

Zones in the runtime: `input`, `fixed_update`, `render_acquire`, `render_encode`,
`present` (inside `frame_total`). `present` and `render_acquire` are where the
GPU pacing lives; `render_encode` is the CPU's real submission cost.

> Historical note: M0 wrapped everything in a single `render` zone that included
> the present, so its frame times were indistinguishable from the vsync period.

## The runtime flags

```
ember [--frames N]            exit after N frames (0 = run until closed)
       [--headless]           no window, null backend (CI)
       [--vsync on|off]       off = measure the CPU without pacing (default on)
       [--prof on|off]        zone recording (default on; off ≈ free, §9)
       [--tsc on|off]         rdtscp clock vs clock_gettime (default on)
       [--mem on|off]         RSS/CPU sampler thread (default on)
       [--warmup N]           frames excluded from the stats (default 30)
       [--budgets on|off]     spec.md verdicts in the report (default on)
       [--trace PATH]         write PATH.perfetto-trace on exit
       [--report-json PATH]   write report.json on exit (the gate's input)
```

The warm-up exists because the first frames are noise (surface configure, first
acquire, first page faults, lazy calibration); including them would poison the
percentiles.

## The report: log, JSON, trace

Three outputs, one measurement:

1. **Log** (on exit): the human table — frame percentiles, per-zone times,
   counters, memory, verdicts. `--frames` + read stderr.
2. **`report.json`**: flat, allocation-free schema (see
   `src/engine/core/json.zig`); `frame_ms` in ms, `gpu_ns` in ns, plus the
   `verdicts` array. This is the gate's input.
3. **Perfetto trace**: per-frame, per-zone events + counters, capped ring
   (2048 frames by default). Open in <https://ui.perfetto.dev>.

Example (600 frames, windowed, this machine):

```text
frame work: p50 0.856 ms  p99 1.489 ms  p99.9 3.686 ms  max 3.686 ms
frame wall: p50 17.026 ms  p99 1002.054 ms          <- wall: includes vsync
gpu 0.066 ms   draw calls 1   uploads 64 B/frame   allocs in frame 0
rss 46.6 MiB
spec.md verdicts: all pass
```

## The CI gate: `ember-profile`

`ember-profile run.json [--baseline base.json] [--tolerance 0.05]`:

- prints the same report from the JSON (so CI logs show real numbers);
- with `--baseline`, compares 14 metrics (frame work p50/p99/p99.9/max, wall
  p50/p99, GPU ms, draw calls, uploads, allocs in frame, GPU resources in
  frame, arena high-water, RSS, frames) and **fails (exit 1)** when any of them
  regresses more than the tolerance (default 5%, spec §9 / ROADMAP M11);
- also fails when the run itself breaks a spec.md budget, with or without a
  baseline.

Exit codes: `0` pass, `1` regression or failed verdict, `2` unreadable input.

Minimal CI step:

```bash
zig build run -- --headless --frames 600 --report-json new.json
./zig-out/bin/ember-profile new.json --baseline perf/baseline.json \
  || { cp new.json perf/baseline.json; }   # refresh only when it passes
```

Note: run-to-run noise on a laptop (power governor, thermals) can exceed 5% on
tail percentiles. Take baselines on the CI machine, with `--vsync off` and a
pinned governor for stable numbers, and prefer p50/p99 for decisions.

## Budgets and verdicts

The budgets live in `src/engine/core/budget.zig`, copied verbatim from
`spec.md`: p50 ≤ 7 ms, p99 ≤ 10 ms, p99.9 ≤ 16.6 ms (work frame), GPU ≤ 6 ms,
≤ 32 draw calls, ≤ 2 MB uploads/frame, 0 allocations in the frame, RSS ≤ 48 MB
(export, empty). If spec.md changes, that file changes: one edit, every verdict
follows.

## Instrumenting your own code

```zig
var z = prof.zone("physics");
defer z.end();                       // end() is idempotent

// after the frame:
const i = prof.zoneIndexByName("physics");  // handles are reused by siblings
const ns = prof.zoneFrameNs(i.?);           // read it back later
prof.counters.upload_bytes = bytes;         // counters are plain fields
prof.pushWorkFrame(work_ns);                // runtime: report the work frame
```

Rules:

- Zones are interned by name at first use (FNV-1a, comptime), then looked up
  by hash: no allocation, no string compare in the frame.
- Percentiles, histograms and the timeline are per zone: p50/p99 of each call
  and of each frame's inclusive time, for the last 128 frames.
- `prof.enabled = false` makes `zone()` cost one branch (spec §9: zero cost
  when off).

## Design notes and cost

- **No allocations, no I/O in the frame** (spec §3): the rings, histograms and
  trace are fixed-size arrays; the report, JSON and trace are written at exit.
- **Timestamps readback never blocks**: the resolve buffer is mapped with
  `mapAsync` and polled with `WaitAny(0)`; results arrive 2 frames late.
- **The sampler is a thread**, so RSS/CPU sampling cannot stall the frame; it
  uses `read()` on `/proc` and atomics only.
- **The clock**: `rdtscp` (invariant TSC, calibrated once at boot against
  `clock_gettime`, ~200–750 ppm of drift in the tests) or the monotonic
  fallback; `--tsc off` forces the fallback.
