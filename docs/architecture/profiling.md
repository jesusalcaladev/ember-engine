# Ember Engine — Profiling Architecture

Ember's profiling system is the instrument that verifies `spec.md` (budgets
are law). It is not a nice-to-have dashboard — it is how the engine proves
its performance contract. This document covers the CPU profiler, Chrome Trace
Events, the spec.md contract, and the CI gate.

---

## The Pipeline

```
┌─────────────────────────────────────────────────────────────────────┐
│                     PROFILING PIPELINE                              │
│                                                                     │
│   Profiler ──► Trace ring ──► Perfetto JSON ──► ui.perfetto.dev    │
│   (zones)      (2048 frames)   (Chrome Trace)    (visual timeline)  │
│                                                                     │
│   Profiler ──► report.json ──► ember-profile ──► CI gate           │
│   (counters)   (machine-readable)  (compare)       (exit 1 on >5%) │
│                                                                     │
│   Profiler ──► spec.md verdicts (budget.zig)                        │
│   (measured)   (PASS / FAIL / unknown)                              │
└─────────────────────────────────────────────────────────────────────┘
```

Every run ends in a **verdict** against `spec.md`, not in a pretty table.

---

## 1. CPU Profiler

**File:** `src/engine/core/profiler.zig`

The profiler instruments the frame with **zones** — named regions of work.
Each zone has inclusive time, exclusive (self) time, per-call histograms,
and a per-frame timeline.

### Architecture

```
Profiler
├── zones: [128]Zone                    ← fixed-size zone pool
├── hash_slots: [256]u16                ← comptime FNV-1a intern table
├── timers: [32]ZoneTimer               ← live zone stack (depth ≤ 32)
├── stack: [32]StackEntry               ← {idx, start_ns, child_ns}
│
├── ring: [4096]u64                     ← exact frame durations (wall)
├── work_ring: [4096]u64                ← frame minus vsync wait
│
└── counters: Counters                  ← engine-wide metrics
```

### Zone Interning

Zone names are hashed at **comptime** (FNV-1a) and interned into a fixed
open-addressed table. The hot path is a mask + probe + one u32 compare —
no string compare, no allocation:

```zig
fn intern(self: *Profiler, comptime name: []const u8) u16 {
    const h = comptime fnv1a(name);              // comptime hash
    var slot = h & (HASH_CAP - 1);
    while (true) {
        const entry = self.hash_slots[slot];
        if (entry == EMPTY) break;
        const idx = entry;
        if (self.zones[idx].hash == h and std.mem.eql(u8, self.zones[idx].name, name))
            return idx;
        slot = (slot + 1) & (HASH_CAP - 1);
    }
    // ... create new zone ...
}
```

### Inclusive vs Exclusive Time

Closing a zone adds its duration to its parent's `child_ns`, so self time =
inclusive − children. This tells you where the time is, not just who was
open:

```zig
fn endZone(self: *Profiler, idx: u16, start_ns: u64, out_ns: ?*u64) void {
    self.depth -= 1;
    const entry = &self.stack[self.depth];
    const ns = time.monotonicNs() - start_ns;

    const z = &self.zones[idx];
    z.ns_total += ns;
    z.hits += 1;
    z.ns_frame += ns;
    z.hist[histBucket(ns)] += 1;

    const self_ns = ns - entry.child_ns;         // exclusive = inclusive - children
    z.self_frame += self_ns;
    z.self_ns_total += self_ns;

    if (self.depth > 0) self.stack[self.depth - 1].child_ns += ns;
}
```

### Per-Call Histogram

Each zone keeps a power-of-two bucket histogram (24 buckets, O(1) update,
no sort) giving p50/p99/p99.9 per zone. Bucket *b* covers `[2^(b-1), 2^b)`
µs:

```zig
fn histBucket(ns: u64) usize {
    const us = ns / std.time.ns_per_us;
    if (us == 0) return 0;
    if (us >= HIST_MAX_US) return HIST_BUCKETS - 1;
    const log2: usize = @intCast(std.math.log2_int(usize, @intCast(us)));
    return @min(HIST_BUCKETS - 1, log2 + 1);
}
```

### Per-Frame Timeline

Each zone keeps the last 128 frames of inclusive µs (u16 each) in a circular
buffer. This is what answers "when did this zone spike" — without it, only
the total frame time would be available.

### Frame Rings

Two exact rings of frame durations (4096 entries each):
- **wall ring**: the whole loop iteration, including the vsync wait.
- **work ring**: wall minus the `render_acquire` zone. This is the number
  the spec.md budgets apply to (§2).

### Counters

Engine-wide metrics, written every frame, read by the report and tracer:

| Group | Counters |
|---|---|
| Frame pacing | `frame_wall_ns`, `frame_work_ns`, `present_wait_ns`, `pacing_wait_ns` |
| Simulation | `fixed_steps`, `fixed_steps_dropped`, `accumulator_leftover_ns` |
| Render | `draw_calls`, `render_passes`, `pipeline_changes`, `upload_bytes`, `gpu_ns`, `gpu_resources_created` |
| Memory | `arena_used_bytes`, `arena_high_water_bytes`, `live_bytes`, `peak_live_bytes`, `allocs_in_frame`, `rss_bytes` |
| Threads | `cpu_ticks_total`, `cpu_ticks_main`, `thread_count` |

### Zero Cost When Disabled

With `enabled = false`, `zone()` costs a single predictable branch (spec §9).
No clock reads, no bookkeeping:

```zig
pub fn zone(self: *Profiler, comptime name: []const u8) *ZoneTimer {
    if (!self.enabled) {
        const t = &self.timers[0];
        t.* = .{ .prof = self, .idx = EMPTY };   // end() is a no-op
        return t;
    }
    // ... normal path ...
}
```

### Warm-Up Frames

The first N frames (default 30) are excluded from stats — surface configure,
first acquire, first page faults, lazy calibration. The first measured
frame after warm-up resets the zone stats:

```zig
pub fn beginFrame(self: *Profiler, record: bool) void {
    if (record and !self.stats_active) {
        for (self.zones[0..self.zone_count]) |*z| z.resetStats();
        self.stats_active = true;
    }
    // ...
}
```

### Budget Note

Each zone costs two clock reads (~28 ns with the TSC clock, ~50 ns with
`clock_gettime`). Wrap work above ~200 ns in a zone; below that the
measurement costs more than the work.

---

## 2. Chrome Trace Events

**File:** `src/engine/core/trace.zig`

The trace ring records per-frame, per-zone events and counters, exported as
Chrome Trace Events (Perfetto) JSON. Open in <https://ui.perfetto.dev> for
a zoomable timeline.

### Why a separate ring

The profiler keeps the last 128 frames for the HUD, but a "when did it
spike" investigation needs the whole sequence. The trace ring is allocated
at start (from the boot allocator, outside the frame loop) so recording one
frame is a memcpy away:

```zig
pub const Trace = struct {
    names: [][]const u8,          // zone names (self-describing)
    frame_index: []u64,
    wall_ns: []u64,
    work_ns: []u64,
    steps: []u8,
    dropped: []u8,
    draw_calls: []u16,
    gpu_ns: []u32,
    zones: []u16,                 // frame_cap × zone_count (inclusive µs)
    // ...
};
```

### Recording

Recording is cheap — fixed-size writes, no branches over zones:

```zig
pub fn record(self: *Trace, frame_index: u64, wall_ns: u64, work_ns: u64,
               steps: u8, dropped: u8, draw_calls: u16, gpu_ns: u32,
               zone_us: []const u16) void {
    const i = self.next;
    self.frame_index[i] = frame_index;
    self.wall_ns[i] = wall_ns;
    self.work_ns[i] = work_ns;
    // ...
    @memcpy(self.zones[i * self.zone_count ..][0..n], zone_us[0..n]);
    self.next = (self.next + 1) % self.frame_cap;
}
```

### Perfetto Export

The file is written on demand and **always outside the frame loop** —
blocking I/O inside the frame is forbidden (spec §3.4):

```
{"traceEvents":[
  {"ph":"X","name":"frame","pid":1,"tid":1,"ts":0,"dur":16666},
  {"ph":"X","name":"work","pid":1,"tid":2,"ts":0,"dur":856},
  {"ph":"X","name":"gpu","pid":1,"tid":3,"ts":0,"dur":66},
  {"ph":"X","name":"render","pid":1,"tid":4,"ts":0,"dur":540},
  {"ph":"C","pid":1,"tid":5,"ts":0,"args":{"steps":1,"dropped":0,"draw_calls":1}},
  ...
],"displayTimeUnit":"ms","otherData":{...}}
```

Event types:
- `ph:"X"` — complete events (frame, work, gpu, each zone) with `ts` + `dur` in µs.
- `ph:"C"` — counter events (steps, dropped, draw_calls) at each frame's start.

---

## 3. The spec.md Contract

**Files:** `spec.md`, `src/engine/core/budget.zig`

spec.md is **law**: budgets and rules that no change may break. A PR that
breaks a budget is a blocking bug, not a "pending optimization".

### Golden Rule

> Budgets are **measured**, not estimated.

### Frame Budget (exported game @ 60 FPS)

| Metric | Budget |
|---|---|
| Total CPU p50 | ≤ 7.0 ms |
| Total CPU p99 | ≤ 10 ms |
| Total CPU p99.9 | ≤ 16.6 ms |

### Per-System Budgets

| System | Budget |
|---|---|
| Lua behaviors (10k updates) | 2.0 ms |
| Physics (fixed 60 Hz + interpolation) | 2.0 ms |
| Render CPU (encoding 50k sprites) | 1.5 ms |
| ECS: 100k transform updates | 2.0 ms |
| ECS: parent-chain resolution (10k) | 2.0 ms |
| Signals + framework | 0.8 ms |
| Editor overlay | ≤ 2.0 ms |

### Anti-Spike (spec §3)

1. **Zero allocations in the frame loop** (see `memory.md`).
2. LuaJIT GC: incremental step only, ≤ 0.4 ms/frame; full GC forbidden.
3. Physics: max 1 catch-up step per frame (no death spirals).
4. Blocking I/O in the frame: forbidden.
5. No import/bake inside the frame.
6. GPU resources created only at load time; assert if created in-frame.

### GPU (spec §4)

| Metric | Budget |
|---|---|
| Draw calls | ≤ 32 (≤ 64 with lights + GI) |
| GPU frame @ 1080p | ≤ 6 ms |
| Staging uploads | ≤ 2 MB/frame steady state |
| GPU resources created in frame | 0 |

### RAM (spec §5)

| Profile | RSS limit |
|---|---|
| Exported game, empty | ≤ 48 MB |
| Exported game, demo | ≤ 128 MB |
| Editor, empty | ≤ 512 MB |
| Editor, demo | ≤ 1.2 GB |

---

## 4. Budgets as Code

**File:** `src/engine/core/budget.zig`

Every number is copied verbatim from spec.md so a report can print
PASS/FAIL instead of a bare number:

```zig
pub const Budget = struct {
    // §2 frame budget (exported game at 60 FPS)
    frame_work_ms_p50: f64 = 7.0,
    frame_work_ms_p99: f64 = 10.0,
    frame_work_ms_p999: f64 = 16.6,

    // §2 per-system budget, checked by zone name
    lua_update_ms: f64 = 2.0,
    physics_ms: f64 = 2.0,
    render_cpu_ms: f64 = 1.5,
    signals_ms: f64 = 0.8,
    editor_overlay_ms: f64 = 2.0,

    // §3 anti-spike
    allocs_per_frame: u64 = 0,
    fixed_steps_per_frame: u32 = 1,

    // §4 GPU
    gpu_ms: f64 = 6.0,
    draw_calls: u64 = 32,
    upload_bytes_per_frame: u64 = 2 << 20,
    gpu_resources_per_frame: u64 = 0,

    // §5 RAM (MB)
    rss_export_empty_mb: u64 = 48,
    rss_export_demo_mb: u64 = 128,
    rss_editor_empty_mb: u64 = 512,
    rss_editor_demo_mb: u64 = 1200,
};
```

If spec.md changes, this file changes. One edit, all verdicts follow.

### Verdicts

`evaluate()` produces a `Report` of `Result` entries, each with a status:

```zig
pub const Status = enum { pass, fail, unknown };
```

- **pass** — measured and within budget.
- **fail** — measured and over budget.
- **unknown** — could not be measured (system not present yet, e.g.
  `physics` before M4, or no GPU timestamps on this device).

---

## 5. The Report

**File:** `src/engine/core/report.zig`

Two consumers of the same numbers:

### Human Report (logger)

Printed on exit: frame percentiles, per-zone times, counters, memory,
verdicts:

```
== PERF (dawn) ==
  frames: 600 (warm-up excluded: 30, measured: 570, ring cap: 4096)
  frame wall   p50 17.026 ms  p99 1002.054 ms  p99.9 1002.054 ms  (max 1002.054)
  frame work   p50 0.856 ms  p99 1.489 ms  p99.9 3.686 ms  <-- spec §2 applies here
  zones (per frame: avg / p99 / self-time share):
    render                        0.5400 ms/f  p99   0.540 ms  calls/f   1.00  self  100.0%
    ...
  render: 4 draw calls, 4 passes, 0 pipeline changes, 0 bind groups, 1600096 bytes/frame
  gpu: 0.066 ms (4 timestamped pass(es))
  loop: 1.00 fixed step(s)/frame, 0 dropped total, arena 262144 bytes high-water
  mem: live 123456 bytes, peak 234567 bytes, arena high-water 262144 bytes (0 in use)
  proc: rss 46.6 MiB (peak 48.2 MiB), 3 threads, cpu total 12.3%, main 11.8%
== spec.md verdicts ==
  [PASS] frame work p50            0.856 ms (limit 7.000)
  ...
  all measured budgets pass
```

### Machine Report (report.json)

Flat, allocation-free JSON for the CI gate:

```json
{
  "schema": 1,
  "backend": "dawn",
  "mode": "game",
  "frame_ms": { "wall_p50": 17.026, "work_p50": 0.856, ... },
  "zones": [ { "name": "render", "hits": 570, "avg_ms": 0.54, ... } ],
  "counters": { "draw_calls": 4, "allocs_in_frame": 0, ... },
  "verdicts": [ { "name": "frame work p50", "value": 0.856, "limit": 7.0, "status": "pass" } ],
  "pass": true
}
```

---

## 6. The CI Gate

**File:** `PROFILING.md`, tool `ember-profile` in `src/tools/`

`ember-profile` is built by `zig build` and installed next to `ember`. It
links neither Dawn nor GLFW, so it runs on a headless CI container.

### Usage

```bash
zig build run -- --headless --frames 600 --report-json new.json
./zig-out/bin/ember-profile new.json --baseline perf/baseline.json
echo $?    # 0 = ok, 1 = regression or failed verdict, 2 = bad input
```

### What it checks

With `--baseline`, it compares 14 metrics:

- frame work p50 / p99 / p99.9 / max
- wall p50 / p99
- GPU ms
- draw calls
- uploads
- allocs in frame
- GPU resources in frame
- arena high-water
- RSS
- frames

It **fails (exit 1)** when any metric regresses more than the tolerance
(default 5%, spec §9 / ROADMAP M11). It also fails when the run itself
breaks a spec.md budget, with or without a baseline.

### Minimal CI step

```bash
zig build run -- --headless --frames 600 --report-json new.json
./zig-out/bin/ember-profile new.json --baseline perf/baseline.json \
  || { cp new.json perf/baseline.json; }   # refresh only when it passes
```

### Noise note

Run-to-run noise on a laptop (power governor, thermals) can exceed 5% on
tail percentiles. Take baselines on the CI machine, with `--vsync off` and
a pinned governor for stable numbers, and prefer p50/p99 for decisions.

---

## 7. Runtime Flags

```
ember [--frames N]            exit after N frames (0 = run until closed)
       [--headless]           no window, null backend (CI)
       [--vsync on|off]       off = measure the CPU without pacing (default on)
       [--prof on|off]        zone recording (default on; off ~ free, §9)
       [--tsc on|off]         rdtscp clock vs clock_gettime (default on)
       [--mem on|off]         RSS/CPU sampler thread (default on)
       [--warmup N]           frames excluded from the stats (default 30)
       [--budgets on|off]     spec.md verdicts in the report (default on)
       [--trace PATH]         write PATH.perfetto-trace on exit
       [--report-json PATH]   write report.json on exit (the gate's input)
```

---

## 8. The Frame is Split: Work vs Wall

With vsync on, the swapchain acquire **waits** for the previous frame to be
displayed. That wait is not engine work:

```
wall frame  = loop_start → next_loop_start (includes vsync wait)
work frame  = wall - render_acquire (the engine's actual work)
```

At 60 FPS, `p50 ≈ 16.7 ms` wall is *correct* — the budgets apply to the
work frame. Charging vsync to the frame would make every budget
meaningless (everything would "take" 16.6 ms).

Zones in the runtime: `input`, `fixed_update`, `render_acquire`,
`render_encode`, `present` (inside `frame_total`). `present` and
`render_acquire` are where the GPU pacing lives; `render_encode` is the
CPU's real submission cost.

---

## 9. Instrumenting Your Own Code

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
- Zones are interned by name at first use (FNV-1a, comptime), then looked
  up by hash: no allocation, no string compare in the frame.
- Percentiles, histograms and the timeline are per zone: p50/p99 of each
  call and of each frame's inclusive time, for the last 128 frames.
- `prof.enabled = false` makes `zone()` cost one branch (spec §9: zero
  cost when off).

---

## 10. Design Notes

- **No allocations, no I/O in the frame** (spec §3): the rings, histograms
  and trace are fixed-size arrays; the report, JSON and trace are written
  at exit.
- **Timestamps readback never blocks**: the resolve buffer is mapped with
  `mapAsync` and polled with `WaitAny(0)`; results arrive 2 frames late.
- **The sampler is a thread**, so RSS/CPU sampling cannot stall the frame;
  it uses `read()` on `/proc` and atomics only.
- **The clock**: `rdtscp` (invariant TSC, calibrated once at boot against
  `clock_gettime`) or the monotonic fallback; `--tsc off` forces the
  fallback.
