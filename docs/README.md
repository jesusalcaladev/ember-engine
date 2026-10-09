# Ember Engine Documentation

**Ember** is a 2D game engine written in [Zig](https://ziglang.org/) with a
[WebGPU](https://www.w3.org/TR/webgpu/) renderer (via Dawn), an ECS core, and
[LuaJIT](https://luajit.org/) scripting. It is developed by Daara Studios.

---

## Start Here: Your Learning Path

New to Ember? Follow this path. Each step builds on the previous one.

### Level 0 — I have never made a game

1. [Installation](getting-started/installation.md) — Build and run the engine (10 min)
2. [Quickstart](getting-started/quickstart.md) — Something moving on screen in 5 minutes
3. [Learning Lua: Fundamentals](guides/learning-lua.md) — Lua from zero (sections 1–5)

### Level 1 — I know Lua but never used Ember

1. [Quickstart](getting-started/quickstart.md) — Get something running fast
2. [First Scene](getting-started/first-scene.md) — The `.zson` format
3. [First Script](getting-started/first-script.md) — Behaviors and the `self` table
4. [Lua in Ember](guides/ember-lua.md) — The engine API in depth
5. [First Game](guides/first-game.md) — Build a complete mini-game

### Level 2 — I want to understand the engine

1. [Architecture Overview](architecture/overview.md) — How the layers connect
2. [Memory Model](architecture/memory.md) — Frame arena, zero-allocation loop
3. [Determinism](architecture/determinism.md) — Fixed timestep, PRNG, serialization
4. [Profiling](architecture/profiling.md) — spec.md, CI gate, budgets

### Level 3 — I want the full API reference

- [Lua API Reference](reference/script-lua-api.md) — Every binding, with examples
- [Core Math](reference/core-math.md) — Vec2, Mat4, Rect2, scalar functions
- [Random](reference/core-random.md) — Deterministic PRNG
- [Noise](reference/core-noise.md) — Procedural noise
- [ECS](reference/ecs-entities.md) — Entities, components, actors, queries
- [Rendering](reference/render-pipeline.md) — Pipeline, batching, atlas
- [Scripting](reference/script-behaviors.md) — Behaviors, state machines, hot-reload

### Level 4 — I want to build real games

- [Common Patterns](guides/common-patterns.md) — Movement, camera, collision, spawning
- [First Game](guides/first-game.md) — A complete collector game tutorial
- [State Machines](reference/script-state-machines.md) — Declarative state management
- [Steering Behaviors](reference/script-lua-api.md#steer) — AI movement

---

## Quick Navigation

| I want to... | Go to |
|---|---|
| Build the engine | [Installation](getting-started/installation.md) |
| See something move | [Quickstart](getting-started/quickstart.md) |
| Learn Lua from zero | [Learning Lua](guides/learning-lua.md) |
| Learn the Ember API | [Lua in Ember](guides/ember-lua.md) |
| Write a scene | [First Scene](getting-started/first-scene.md) |
| Write a script | [First Script](getting-started/first-script.md) |
| Make a game | [First Game](guides/first-game.md) |
| Copy-paste patterns | [Common Patterns](guides/common-patterns.md) |
| Understand the engine | [Architecture](architecture/overview.md) |
| Look up a function | [Lua API Reference](reference/script-lua-api.md) |
| Debug a problem | [Troubleshooting](getting-started/troubleshooting.md) |

---

## What is Ember?

Ember is a **2D game engine** with these core ideas:

- **Scenes are text.** You describe entities, components, and hierarchy in
  `.zson` files — a canonical, diffable, bit-exact format.
- **Behavior is Lua.** Gameplay logic runs in LuaJIT scripts bound to actors.
  Hot-reload works: edit the file, see the change, keep your state.
- **The ECS is hidden.** You work with actors and components. The data-oriented
  ECS underneath is an implementation detail.
- **Zero allocations in the frame loop.** The engine never allocates during
  gameplay. Capacities are reserved at load.
- **Deterministic.** Fixed 60 Hz timestep, seeded PRNG, stable signal order.
  The same inputs always produce the same outputs.

### The Lua API at a Glance

Ember exposes a small set of global tables to Lua scripts:

| Table | Purpose |
|---|---|
| `actor` | Transform, spatial queries, signals (methods on `self`) |
| `vec2` | 2D vector math (zero-allocation scalar form + table form) |
| `math` | Scalar math: clamp, lerp, smoothstep, move_toward, etc. |
| `input` | Action-based input: `is_action_pressed`, `is_action_down`, `get_axis` |
| `log` | Engine log sink: `log.info`, `log.warn` |
| `rand` | Deterministic RNG: seed, float, int, chance, gauss, shuffle |
| `noise` | Procedural noise: value, perlin, simplex, fbm, ridged |
| `sm` | Declarative state machines: add_state, add_transition, fire, state |
| `world` | Spatial queries: `world.nearby` |
| `steer` | Steering behaviors: seek, flee, arrive, wander, separate, align, cohere |

### Project Structure

```
src/engine/core/       Foundations: math, arena, profiler, logging, RNG, noise
src/engine/ecs/        ECS: archetypes, queries, hierarchy, signals, actors, .zson
src/engine/platform/   Window + input (GLFW 3.4 / X11)
src/engine/render/     Renderer interface + Dawn backend + WebGPU bindings
src/engine/script/     LuaJIT scripting: VM, sandbox, bindings, behaviors, steering
src/runtime/           The ember executable (the game loop)
src/bench/             Benchmark suites (acceptance criteria, measured)
src/tools/             ember-profile: report reader + CI regression gate
```

---

## License

Proprietary software. Copyright (c) 2026 Daara Studios. See
[LICENSE](https://github.com/jesusalcaladev/ember-engine/blob/main/LICENSE).
