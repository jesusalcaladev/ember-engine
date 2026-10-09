# spec.md — Performance contract (non-negotiable invariants)

This document is **law**: budgets and rules that no change may break. A PR that breaks a budget is a blocking bug, not a "pending optimization".

## 0. Golden rule
Budgets are **measured**, not estimated. Everything here is verified with the built-in profiler and the benchmark CI (roadmap M11).

## 1. Reference hardware
- **Desktop**: average 2022 laptop — 4C/8T, iGPU (Vega 8 / Iris Xe), 16 GB RAM, SSD, 1080p.
- **Web**: stable Chrome on that same hardware.

All numbers are measured there. On superior hardware they may only improve; on inferior hardware it degrades gracefully (resolution/steps, never with spikes).

## 2. Frame budget (exported game @ 60 FPS)
- Total CPU: **≤ 7.0 ms p50** · p99 ≤ 10 ms · **p99.9 ≤ 16.6 ms** (zero dropped frames at 60 Hz in canonical scenes).

| System | Budget |
|---|---|
| Lua behaviors (10k updates) | 2.0 ms — **M3: 0.650 ms p50 measured** (framework floor; the bench splits engine cost from gameplay cost, see below) |
| Physics (fixed 60 Hz step + interpolation) | 2.0 ms |
| Render CPU (encoding 50k sprites) | 1.5 ms — **M2: 0.54 ms measured** (instanced, 32 B/sprite, no per-frame sort) |
| ECS: 100k transform updates over SoA queries | 2.0 ms — **M1: 0.484 ms p50 measured** |
| ECS: parent-chain resolution (10k entities) | 2.0 ms — **M1: 0.586 ms p50 measured** |
| Signals + framework | 0.8 ms |
| Headroom | the rest |

**On the Lua budget, measured**: `zig build bench` reports two rows, because the
number is otherwise unfalsifiable. The **framework floor** — 10k behaviors driven
through the full lifecycle (instance walk, cached refs, one protected call) with
an `update` that does nothing — is 0.650 ms p50, and that is the engine's charge
against this row. A **realistic gameplay behavior** (state + two trig calls +
one fused `actor.move_by`) costs 2.856 ms p50 at 10k instances, reported
informationally with the breakdown, because the per-call cost of a Lua→C binding
is a *gameplay design constraint*, not an engine invariant:

| Isolated cost | ns/behavior |
|---|---|
| floor (pcall + empty `update`) | 65 |
| + 2 `math` calls | +45 |
| + 1 Lua→C binding | **+145** (12 ns of it is the ECS lookup; the rest is LuaJIT's dispatch, which cannot be JIT-compiled for a C function) |

That 145 ns per binding is why `actor.move_by` exists: it does read-modify-write
in ONE call where `get_position` + `set_position` costs two and pushes two more
return values. A Pin-Pon-scale scene (order ~10 behaviors) spends ~3 µs/frame on
gameplay, which is 0.02 % of the frame; 10k simultaneous behaviors is a stress
row for the engine, not a shape the demo ever takes.

- **Editor**: adds ≤ 2.0 ms (overlay + composition). Its cost never appears in the exported game.

## 3. Anti-spike (hard rules against CPU spikes)
1. **Zero allocations in the frame loop**: per-frame arena with O(1) reset; assert in debug builds. Structural ECS growth (slots, archetypes, rows) is locked during the frame: it must be reserved at load time, and a spike is not allowed to hide behind a reallocation.
2. **LuaJIT GC**: incremental step only, ≤ 0.4 ms/frame; full GC forbidden during play.
3. **Physics**: max 1 catch-up step per frame (no death spirals); mandatory physics→render interpolation.
4. **Blocking I/O in the frame: forbidden** (preload or async VFS).
5. No import/bake inside the frame: everything async or budgeted (SDF, atlas, GI full bake).
6. Pipelines/buffers/shaders/textures are created only at load time; assert if anything GPU is created in-frame.
7. Audio on its own RT-safe thread: no long locks in the callback.
8. Workers: spin only within the frame window; parked after 2 idle frames.

## 4. GPU
- **Draw calls ≤ 32** in a typical frame (batching per material/atlas); ≤ 64 with lights + GI (compute passes count).
  *M2 measured: 4 for the 50k-sprite canonical scene (1 sprite pass + 3 SMAA passes).*
- **GPU frame ≤ 6 ms @ 1080p** on the reference iGPU, canonical scene (50k sprites + 20 lights + GI).
- **Radiance Cascades (GI)**: amortized update ≤ 1.5 ms GPU/frame; full bake only at load/light editing, asynchronous.
- Occluder SDFs: baked at import; incremental async re-bake.
- Persistent buffers with suballocation (ring); staging uploads ≤ 2 MB/frame in steady state (outside loading screens).
  *This is why sprites are INSTANCED at 32 B each and not 6 vertices x 36 B: the vertex form needs 10.8 MB/frame at 50k sprites, the instance form 1.6 MB. M2 measured: 1 600 096 B/frame.*
- GPU timestamps per pass: mandatory in debug, opt-in in release.

## 5. RAM (memory)

| Profile | RSS limit |
|---|---|
| Exported game, empty project | ≤ 48 MB |
| Exported game, full demo | ≤ 128 MB |
| Editor, empty project | ≤ 512 MB |
| Editor, full demo | ≤ 1.2 GB |
| Web (total) | ≤ 200 MB |

Rules:
- **Every cache has a byte-budget + eviction** and shows up in the memory report.
- 8 h soak test: memory drift ≤ 2%.
- Compressed textures in export; atlas mandatory.
- Allocators tagged per subsystem; high-water marks visible in the report.
- Growth > 5% between consecutive frames is logged in debug (never silent).

## 6. Determinism
- Physics at a fixed 60 Hz; gameplay only uses `engine.time` (never wall-clock).
- Same binary + same inputs → same final state (hash test in CI).
- Stable signal order (by spawn order).
- Play→Stop snapshot is **bit-exact** (hash test in CI) — that is what makes editing during play safe.
- Scene serialization is canonical and **bit-exact**: same world → same bytes → same hash (`.zson`), float formatting round-trips every bit.

## 7. Invariant architecture
- **One process, one window.** The game ALWAYS renders to an offscreen target; the editor composes. Godot-style play in a separate window is forbidden by design.
- Lua never touches GPU/window/filesystem directly: only the engine API.
- The ECS is an internal detail; the public API is **Actor + Components + Signals** and can only grow with semver.
- Every subsystem owns its (tagged) allocator; the editor uses its own allocators.
- v1 targets: **Windows x86_64 (D3D12), Linux x86_64 (Vulkan), Web (WebGPU)**. Nothing else enters scope until post-1.0.

## 8. Web-specific rules
- No threads by default (SharedArrayBuffer optional); physics ≤ 2 steps/frame.
- Half-resolution GI; its own budgets: initial load < 10 s, RAM ≤ 200 MB.
- Single graphics backend: WebGPU (Chrome/Edge). Fallbacks: post-1.0.

## 9. Enforcement (how this is guaranteed)
- **Bench suite** in CI: 3 canonical scenes (static sprites; lights + GI; physics + behaviors) on the 3 targets.
- **Gate**: > 5% regression on any metric = red CI.
- Built-in profiler (CPU zones + GPU timestamps) with zero cost when off.
- **Memory report** command + automated weekly soak.
- Every feature PR ships **sample + benchmark**; without them it does not merge.

## 10. Forbidden (explicit list)
- `malloc/free` (or equivalents) in the frame loop.
- Synchronous I/O inside the frame.
- Creating/destroying GPU resources per frame.
- Full GC during play.
- A second window or process for playing.
- Long-held locks on the audio thread.
- Charging the editor's cost to the exported game's budget.
- Memory growth without a defined byte-budget.
