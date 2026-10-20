# GPU particles

The particles of an emitter can live on the **GPU** instead of in the CPU's
pool. The CPU packs the emitter's recipe, the compute shader simulates the
particles, and the draw shader expands them into quads. The CPU never touches
a particle again.

```lua
particles.set_backend(self, "gpu")   -- this emitter's particles live on the GPU
```

## Why

The CPU particle system is good, and for a hundred particles it is the right
answer: the pool is SoA, the integration loop is a straight walk, and the
particles are drawn through the ordinary sprite batcher (so they share a draw
call with the sprites ✓).

At 65 536 particles it stops being good. The CPU would stream 4 MB of particle
state per frame, build 65 536 sprite instances, and upload 2 MB of them — the
per-frame staging ceiling is 2 MB (spec §4), so the particle system alone
would be over budget.

On the GPU the particles never leave the memory they are in. The CPU writes a
few hundred bytes of recipes per frame (the emitters' parameters) and the GPU
does the rest.

## The layout is a contract

| | |
|---|---|
| `GpuParams` (`render/particles_gpu.zig`) | 104 bytes — the recipe |
| `GpuParticle` | 64 bytes — one particle |
| `GpuState` | 20 bytes — the free list and the spawn accumulator |

The WGSL has the same three structs (`shaders/particle_sim.wgsl`), field for
field, at the same offsets. **A layout that drifts is a shader that reads the
wrong numbers** — and the failure is a *picture*, not a crash, which is exactly
the kind of bug that ships. There is a test that compares the two sizes ✓.

## The rules are the CPU's

The GPU shader is a second implementation of the CPU system's rules, and a rule
written twice has to be written the same way twice:

- the drag is `v *= exp(-drag * dt)` ✓ (frame-rate independent ✓),
- the gravity is added before the position is integrated ✓,
- the particle dies when its age reaches its life ✓,
- the size and the colour interpolate from birth to death over the life ✓,
- the `local` space moves the particles with the emitter ✓.

The **randomness** is not the same sequence (the GPU uses a hash, the CPU an
xorshift). What has to hold is that the same scene on the same backend replays
the same particles (spec §6) ✓ — not that the two backends agree particle for
particle ✓.

## The two passes

The spawn and the simulation are **two dispatches in one compute pass** ✓, and
the order matters:

- The **spawn pass** has one thread per emitter. It pops slots off the
  emitter's free list and writes the particles.
- The **simulation pass** has one thread per particle. It integrates the live
  ones and pushes the dead ones back onto the free list.

If both ran in the same dispatch, a particle spawned by one thread could be
integrated by another in the same pass — a data race, and WGSL has no rule
that would make it benign. Two dispatches in the same compute pass are
ordered, and WebGPU puts a memory barrier between them ✓.

## The free list

Each emitter owns a fixed **slice** of 256 particles, and the dead slots form
an intrusive stack inside the particles themselves (the `next` field).

The stack is **lock-free** ✓: the push writes the link and then swaps the head
with a compare-exchange, retrying if somebody else took the head meanwhile.
Writing the link *before* the exchange is what makes it correct — the exchange
only succeeds if the head is still what we saw, and the link is rewritten before
each retry ✓.

## The pool

| | |
|---|---|
| The pool | 256 emitters x 256 particles x 64 bytes = **4 MB** |
| Uploaded | **once**, at boot, with every slot on its emitter's free list |
| The draw | one instanced draw over the whole pool |

The draw is not a compaction: the vertex shader reads the particle by its
index, and a **dead particle produces a degenerate quad** that the rasteriser
throws away ✓. It costs a few dead pixels of vertex work, and it is the trade
that makes the CPU never touch a particle ✓.

## What is not there yet

- **The particles are not lit.** The particle pass writes only the colour
  target, not the light-layer target: a particle has no layer of its own, so
  it is lit by whatever layer is under it. A particle that should be lit by
  its own light is not, yet.
- **The atlas is ignored.** The GPU particles are untextured: one solid colour
  per particle, interpolated over its life.
- **Switching backends drops the live particles.** The old ones are dropped and
  the new ones are born from the recipe. Carrying them over would mean reading
  the GPU's memory back, and a readback is a stall — the one thing the GPU
  backend exists to avoid.
- **The statistics are approximate.** The CPU knows how many emitters there
  are, not how many particles are alive: the live count is the GPU's, and
  reading it back is a stall ✓.

## The scripts

| | |
|---|---|
| `particles.set_backend(self, backend)` | `"cpu"` or `"gpu"` ✓ |
| `particles.backend(self)` | which one this emitter uses ✓ |
| `particles.burst(self, count)` | the CPU backend's burst ✓ (the GPU emitter's burst is not implemented yet) |

## Where the code is

| | |
|---|---|
| `src/engine/render/particles_gpu.zig` | the CPU side: the emitters' slices, the recipes, the packing |
| `src/engine/render/shaders/particle_sim.wgsl` | the compute shader (the spawn and the simulation) |
| `src/engine/render/shaders/particle_draw.wgsl` | the draw shader (the particle IS the instance) |
| `src/engine/render/backend_dawn.zig` | the resources, the pipelines, the dispatches and the pass |
| `src/engine/render/render.zig` | the vtable: `gpuParticlesSimulate` and `gpuParticlesDraw` ✓ |

The null backend implements both as no-ops that count ✓, so the CI's numbers
mean the same thing on both backends ✓.
