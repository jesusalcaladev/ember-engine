# Benchmarks

Ember ships two benchmark suites and a profiling/CI-gate tool. Everything is
**measured, never estimated** (spec §0): the frame loops run with the world's
growth locked, so an allocation is a panic, not a sample.

## Running Benchmarks

```bash
# Run both M1 (ECS) and M3 (LuaJIT) benchmark suites
zig build bench

# Run with extra arguments (e.g. the .zson scene round-trip)
zig build bench -- --scene
```

Both suites are headless — they link `core` and `ecs` (and `script` for M3)
directly, so a renderer being edited does not stop the numbers from being
measured.

## M1 Benchmark Suite (`ember-bench`)

**Source**: `src/bench/main.zig`

Measures the acceptance criteria of ROADMAP M1. Runs 240 iterations with 8
warmup frames per measurement.

### What It Measures

| # | Criterion | Budget | Measurement |
|---|---|---|---|
| 1 | 100k actors with updated transforms | p50 ≤ 2 ms | Batch iteration over Transform + Velocity |
| 2 | 10k parent/child entities, no frame spikes | p50 ≤ 2 ms, p99 ≤ 10 ms | Flat hierarchy resolver |
| 3 | save → load reproduces identical hash | bit-exact | ZSON encode → decode → hash comparison |
| 4 | Structural churn (informational) | none | spawn + add + remove + despawn throughput |

### Key Details

- **Allocation locking**: `world.lockAllocs()` is called before the measurement
  loop. Any allocation during the frame is a bug (spec §3.1), not a sample.
- **Percentiles**: nearest-rank ordering, deterministic. p50 is checked against
  the budget; p99 is checked against the spike ceiling (10 ms).
- **Warmup**: 8 frames are discarded before sampling to avoid first-touch noise.
- **`--scene` flag**: exercises the `.zson` file format end-to-end (write a
  scene, load it back, compare hashes). This is the format the editor, exports,
  and undo/redo will use.

### Interpreting Results

```
== M1 benchmarks (240 runs, 8 warmup) ==
  100k transforms p50        0.823 ms   (budget 2.000 ms) OK
  100k transforms p99        1.245 ms   (spike ceiling 10.000 ms) OK
  10k hierarchy p50          0.312 ms   (budget 2.000 ms) OK
  10k hierarchy p99          0.587 ms   (spike ceiling 10.000 ms) OK
  save/load hash             0.000 ms   (budget 0.000 ms) OK
  40000 structural changes: 12.345 ms (308.6 ns each)
all M1 budgets met
```

- **p50** (median) is the steady-state frame cost — this is what the budget applies to.
- **p99** is the tail — a spike above 10 ms would cost a dropped frame at 60 Hz.
- **Structural churn** is informational: it tells you how many archetype
  operations per second the ECS can sustain, but has no budget.
- If any budget is exceeded, the process exits with code 1 and the message
  "a broken budget is a blocking bug (spec §0)".

## M3 Benchmark Suite (`ember-bench-script`)

**Source**: `src/bench/script.zig`

Measures the acceptance criteria of ROADMAP M3 (LuaJIT scripting). Runs 240
iterations with 8 warmup frames per measurement.

### What It Measures

| # | Criterion | Budget | Measurement |
|---|---|---|---|
| 1 | "Press Play" boot | informational | VM + sandbox + bindings + first script compile |
| 2 | Hot-reload | < 100 ms | Recompile with 10 live instances, preserving `self` tables |
| 3 | 10k behavior updates | p50 ≤ 2 ms, p99 ≤ 10 ms | Framework floor (empty `update`) |
| 4 | Incremental GC step | p50 ≤ 0.4 ms | `lua_gc(L, GCSTEP)` after heap churn |
| 5 | Per-call cost (informational) | none | One realistic gameplay behavior, cold vs JIT-warm |

### Key Details

- **Separate binary**: The M3 bench links LuaJIT, so it is a separate artifact
  from the M1 bench. This keeps the M1 bench runnable while the script layer is
  mid-edit. `zig build bench` runs both.
- **Framework floor**: The 10k update budget applies to the engine's own
  lifecycle cost (instance walk, cached refs, one protected call per behavior)
  with an `update` that does nothing. This is the number spec §2's "Lua
  behaviors (10k updates) ≤ 2.0 ms" is about.
- **Gameplay behavior**: A realistic script (state + two trig calls + one fused
  `actor.move_by`) is measured separately, with per-call cost printed. This is
  not a budget — it tells you how much gameplay a behavior can afford.
- **JIT warmup**: The gameplay bench runs 200 unsampled updates before
  measurement, because LuaJIT's tracing JIT compiles the hot loop only after it
  runs. An unsampled run would measure the interpreter.
- **GC step**: Measured after 40 frames of real gameplay updates, so the heap
  has churn to collect. A GC step on an empty heap would flatter the number.

### Interpreting Results

```
== M3 benchmarks (LuaJIT, 240 iterations, 8 warmup) ==
  play: VM+sandbox+bindings      2.345 ms
  play: first script compile     0.123 ms
  play: attach + startAll        0.089 ms
  TOTAL (one actor)              2.557 ms
  hot-reload (10 instances)     12.345 ms   (budget 100.000 ms) OK
  10k behaviors framework p50    1.234 ms   (budget 2.000 ms) OK
  10k behaviors framework p99    2.567 ms   (spike ceiling 10.000 ms) OK
  10k behaviors gameplay p50     1.876 ms   (0.188 us/behavior, informational)
  incremental GC step p50        0.234 ms   (budget 0.400 ms) OK
  GC step p99                    0.345 ms   (Lua heap: 512 KiB)
all M3 budgets met
```

- **Boot time**: Under ~100 ms reads as "no wait" to the user; ~300 ms is
  where they start wondering. The total is what the editor pays per Play.
- **Hot-reload**: Must be under 100 ms with live instances. The script ID must
  not change across a reload.
- **Framework floor**: This is the engine's overhead before any gameplay runs.
  If this is over budget, the problem is in the lifecycle, not the game code.
- **Gameplay per-call**: Tells you the Lua→C boundary cost. Every extra
  Lua→C call costs ~150 ns of pure dispatch.
- **GC step**: Must be under 0.4 ms/frame. The Lua heap size is printed for
  context — a growing heap means the GC step will get slower.

## Profiling and CI Gate

### Runtime Profiling

The `ember` runtime has a built-in profiler (see `PROFILING.md` for full
details):

```bash
# 600 frames, write machine-readable report
zig build run -- --frames 600 --report-json report.json

# Chrome/Perfetto trace
zig build run -- --frames 600 --trace run
```

The profiler instruments:
- **CPU zones** via `rdtscp` TSC (~28 ns/zone overhead)
- **Frame rings** (4096-frame rings, 2 stores per frame)
- **GPU timestamps** via WebGPU `QuerySet` (non-blocking, 2-frame latency)
- **Counters** (draw calls, uploads, allocs, arena high-water, etc.)
- **RSS + CPU%** via a background thread reading `/proc/self/stat`

### `ember-profile` — The CI Gate

**Source**: `src/tools/profile/main.zig`

Reads a `report.json` produced by the runtime and acts as the CI regression
gate (spec §9, roadmap M11: "> 5% regression on any metric = red CI").

```bash
# Print the numbers
./zig-out/bin/ember-profile report.json

# Compare against a baseline (default tolerance: 5%)
./zig-out/bin/ember-profile report.json --baseline baseline.json

# Custom tolerance
./zig-out/bin/ember-profile report.json --baseline baseline.json --tolerance 0.03
```

**Exit codes**:
- `0` — everything within tolerance
- `1` — regression or failed spec verdicts
- `2` — file could not be read/parsed

**Gated metrics** (14 total, all "lower is better"):

| Metric | Source |
|---|---|
| `work_p50`, `work_p99`, `work_p999`, `work_max` | `frame_ms` section |
| `wall_p50`, `wall_p99` | `frame_ms` section |
| `gpu_ns` | `counters` section |
| `draw_calls` | `counters` section |
| `upload_bytes` | `counters` section |
| `allocs_in_frame` | `counters` section |
| `gpu_resources_in_frame` | `counters` section |
| `arena_high_water` | `counters` section |
| `rss_bytes` | `counters` section |
| `frames` | top-level |

The gate also fails when the run itself breaks a spec.md budget, with or
without a baseline.

### Minimal CI Step

```bash
zig build run -- --headless --frames 600 --report-json new.json
./zig-out/bin/ember-profile new.json --baseline perf/baseline.json \
  || { cp new.json perf/baseline.json; }   # refresh only when it passes
```

### Interpreting Profile Results

```
== ember profile: dawn ==
  clock tsc (1000000000 Hz)  vsync on  mode windowed
  frames 600 (warm-up 30, measured 570)
  frame work: p50 0.856 ms  p99 1.489 ms  p99.9 3.686 ms  max 3.686 ms
  frame wall: p50 17.026 ms  p99 1002.054 ms
  gpu 0.066 ms   draw calls 1   uploads 64 B/frame   allocs in frame 0
  arena high-water 1048576 B   rss 46.6 MiB
  spec.md verdicts: all pass
```

- **work frame** = wall minus the `render_acquire` zone. This is the number
  the spec.md budgets apply to. p50 ≈ 0.856 ms means the engine uses ~12% of
  the 7 ms budget.
- **wall frame** = the whole iteration including the vsync wait. p50 ≈ 16.7 ms
  at 60 FPS is correct — it includes the display pacing wait.
- **p99/p99.9/max**: tail latencies. A p99 above 10 ms or p99.9 above 16.6 ms
  would fail the spec verdicts.
- **allocs in frame**: must be 0 (spec §3.1). Any allocation during the
  frame is a bug.
- **arena high-water**: peak arena usage. Should be well under the 48 MB RSS budget.

### Stable Baselines

Run-to-run noise on a laptop (power governor, thermals) can exceed 5% on tail
percentiles. For stable CI numbers:

- Take baselines on the CI machine, not a laptop.
- Use `--vsync off` to measure without display pacing.
- Pin the CPU governor (`performance`).
- Prefer p50/p99 for decisions; p99.9 and max are inherently noisy.
