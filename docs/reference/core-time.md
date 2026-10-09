# Core Time

**Source:** `src/engine/core/time.zig`

Engine time: monotonic clock for measurements (never wall-clock in gameplay, spec §6).

Two interchangeable implementations behind ONE api (`monotonicNs`):

- **`clock_gettime(CLOCK_MONOTONIC)`** — libc/vDSO, always available. ~50-60 ns per read on the dev box (1 GHz), ~20-25 ns on a 2022 laptop.
- **`rdtscp` + invariant TSC (x86_64)** — ~28 ns per read. The TSC rate does NOT follow P-states, so it is calibrated ONCE at boot against the monotonic clock and converted with a fixed-point factor (a single 64x32 multiply + shift). Residual drift measured on the dev box: ~24 ppm, i.e. 0.4 us per frame at 60 fps.

Both clocks are for MEASURING only (profiler zones, frame pacing). Gameplay must never read a clock: it consumes the fixed loop's dt (§6).

---

## Constants

| Name | Value | Description |
|------|-------|-------------|
| `CLOCK_MONOTONIC` | `1` | Linux monotonic clock ID. |
| `FP_SHIFT` | `32` | Fixed-point precision of the TSC→ns conversion (32 fractional bits). |

---

## Global State

| Name | Type | Description |
|------|------|-------------|
| `kind` | `Kind` | Active clock implementation (`.monotonic` or `.rdtscp`). |
| `tsc_scale` | `u64` | TSC ticks per nanosecond, fixed point: `(1 << FP_SHIFT) * 1e9 / tsc_hz`. |
| `tsc_hz` | `u64` | Measured TSC frequency in Hz. |
| `tsc_zero` | `u64` | TSC tick count at calibration time. |
| `ns_zero` | `u64` | Monotonic nanoseconds at calibration time. |
| `last_calibration_ppm` | `i64` | Error of the TSC clock against the monotonic clock, in ppm (from the last calibration). Informational: it goes into the report's environment block. |

---

## Kind Enum

```zig
pub const Kind = enum { monotonic, rdtscp };
```

Which clock implementation is active.

---

## Functions

### `sleepNs`

```zig
pub fn sleepNs(ns: u64) void
```

**Parameters:** `ns` — duration to sleep in nanoseconds.
**Returns:** Nothing. Sleeps for `ns`, retrying on EINTR. Only for boot, tests and idle waits — NEVER inside the frame loop (spec §3.4).

```zig
sleepNs(1_000_000); // sleep 1 ms
```

### `fixedScale`

```zig
pub fn fixedScale(hz: u64) u64
```

**Parameters:** `hz` — TSC frequency in Hz.
**Returns:** Scale factor (fixed point) for a given TSC frequency. Pure: tested without needing a TSC.

```zig
const scale = fixedScale(1_896_000_000); // scale for ~1.9 GHz TSC
```

### `tscToNs`

```zig
pub inline fn tscToNs(ticks: u64) u64
```

**Parameters:** `ticks` — raw TSC tick count.
**Returns:** Ticks converted to nanoseconds using the active scale. Pure enough to test.

```zig
const ns = tscToNs(raw_ticks);
```

### `calibrate`

```zig
pub fn calibrate(window_ns: u64) Calibration
```

**Parameters:** `window_ns` — measurement window in nanoseconds.
**Returns:** A `Calibration` struct with the measured TSC frequency and error. Pure measurement: no state is modified.

```zig
const cal = calibrate(20_000_000); // measure over 20 ms
```

### `init`

```zig
pub fn init(prefer_tsc: bool) Calibration
```

**Parameters:** `prefer_tsc` — whether to try the TSC clock (falls back to monotonic if false or if the CPU lacks an invariant TSC).
**Returns:** The `Calibration` from the measurement. Selects and activates the measurement clock. `prefer_tsc = false` (or a machine without an invariant TSC) silently falls back to monotonic.

```zig
const cal = init(true); // try TSC, fall back to monotonic
```

### `monotonicNs`

```zig
pub inline fn monotonicNs() u64
```

**Returns:** Monotonic nanoseconds since an arbitrary process origin. This is THE read used by the profiler: one branch + one clock access.

```zig
const t = monotonicNs();
```

### `startNs`

```zig
pub inline fn startNs() u64
```

**Returns:** Timestamp for a zone's START (pipeline-draining read). Uses `lfence; rdtsc` to drain the pipeline so the timestamp is not taken early.

```zig
const t0 = startNs();
// ... measured code ...
const elapsed = monotonicNs() - t0;
```

---

## Calibration Struct

```zig
pub const Calibration = struct {
    tsc_hz: u64 = 0,
    error_ppm: i64 = 0,
    ok: bool = false,
};
```

| Field | Type | Description |
|-------|------|-------------|
| `tsc_hz` | `u64` | Measured TSC frequency in Hz. |
| `error_ppm` | `i64` | Error of the fixed-point conversion against the monotonic clock, in ppm. |
| `ok` | `bool` | Whether calibration succeeded. |
