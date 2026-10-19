# AGENT.md — how to work in this repository

**Ember** is a 2D game engine written in Zig (Dawn/WebGPU, Box2D, LuaJIT). This file is the contract between the engine and whoever — human or agent — is changing it.

Read it before you touch anything. It is short on purpose.

---

## 1. What the documentation is for

**`docs/` documents THE ENGINE. Nothing else.**

The rule in one line:

> If a page is about *how the engine works* or *how to call the engine*, it belongs in `docs/`.
> If it is about *how to build a particular game*, *how to learn Lua*, or *how this project is organised*, it does **not** belong in `docs/`.

Concretely, `docs/` holds:

| Folder | What lives there |
|---|---|
| `docs/reference/` | The API. One page per component, per subsystem, per Lua module |
| `docs/architecture/` | How the layers fit together |
| `docs/internals/` | How a subsystem is built, and what it costs |
| `docs/guides/` | Engine usage patterns (movement, camera, collision, sequencing) — **the engine's** patterns, not a project |
| `docs/getting-started/` | Installing, building, and the first scene |

What does **not** belong in `docs/`:

- A tutorial for a game that does not exist yet ("the collector game", "the pin-pong demo"). A tutorial that teaches the engine's API is fine; a tutorial that walks through a fictional project is not.
- Notes about the agent workflow, the session, or what "we" are doing this week.
- Teaching Lua the language. That is Lua's documentation's job; the engine's job is "here is how Lua meets the engine".
- Anything about `project.config`'s *project* semantics that the engine does not own.

**If a page does not describe the engine, it does not go in `docs/`.** Put it in the repository root, in the commit message, or in the issue tracker.

### The two rules that keep the docs honest

1. **Every API in a doc must exist.** Before you write a function call, check `src/engine/script/metadata.zig` (the single source of truth: the bindings, the metadata and the generated stubs all come from it). A doc that names a function the engine does not have is worse than no doc: it teaches a lie that costs an afternoon.
2. **Every page must say where it came from.** Every reference page names its source file. A page without a source cannot be checked, and an unchecked page rots.

---

## 2. The engine's shape

- **Zig 0.16**, no GC, no allocations in the frame loop (spec §3.1).
- **Dawn** (WebGPU) for the renderer, **Box2D v3** for the physics, **LuaJIT** for the scripting.
- **The ECS is the document.** A component is plain data: no pointers, no slices, no unions; every field has a default; the registry is **append-only** because a dense component id *is* the `.zson` encoding.
- **A component never holds a callback.** It holds a *name* (`Timer.done_signal`) or a *handle* (`StateMachine.machine`). The engine resolves it.
- **The frame is fixed-step at 60 Hz** and the render is decoupled. The order inside a fixed step is a contract, not an accident.

Read `spec.md` and `ROADMAP.md` before changing behaviour. `docs/architecture/overview.md` is the map.

---

## 3. Working rules

- **Measure, do not assume.** The engine has a bench (`zig build bench`), a profiler (`zig build run -- --report-json`) and a CI gate that fails on a 5 % regression. A change that touches a hot path needs a number, not a feeling.
- **A bug found is a bug fixed.** If you find one, fix it in the same change and say so in the commit message. A commit that mentions a bug it did not fix is a lie in the history.
- **Never edit `meta/ember.lua` by hand.** It is generated: `zig build stubs`. CI fails if it drifts from the metadata.
- **Never insert into `component_list`.** Append. An insertion renumbers every committed `.zson` file in the repository.
- **Adding a Lua binding means four things**: the binding, the `registered_names` entry, the `metadata.bindings` entry, and the regenerated stubs. The metadata gate is a *compile error* on purpose — do not work around it.
- **A doc and its code change together.** A new component gets a page in `docs/reference/components/`; a new binding gets a metadata entry (which is what the reference is generated from).

---

## 4. The tests

```bash
zig build test          # everything
zig build test-script   # the scripting layer
zig build test-api      # the Lua API acceptance suites (real Lua, real VM)
zig build bench         # the budgets — a non-zero exit is a blocking bug
zig build stubs         # regenerate meta/ember.lua
```

`zig build test-api` is the one that catches a binding that does not do what it says: it drives the real Lua surface against a real VM and reads the answer back out of the world.

---

## 5. The commit message

The engine's history is a design record: the message says **what changed and why**, and the "why" is the part that cannot be recovered from the diff. Write the "why" first.

- One change per commit, and the commit builds and passes the tests on its own.
- Say which invariant the change protects, and what the alternative was. A diff already shows the "what".
- When a measurement justifies a decision, put the number in the message. "0.61 ms p50 against a 2 ms budget" is a fact a future reader can check; "fast enough" is not.

---

## 6. The map

| I want to… | Go to |
|---|---|
| Know what a component does | `docs/reference/components/README.md` |
| Know the Lua API | `docs/reference/script-lua-api.md` |
| Know how the frame is built | `docs/architecture/overview.md` |
| Know what is planned | `ROADMAP.md` |
| Know what is measured | `PROFILING.md`, `spec.md` |
| Know why the code is the way it is | `git log` — the messages are the design record |
