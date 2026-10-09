# Ember Engine — Script Cache and Hot-Reload

The script cache is the engine's mechanism for loading Lua scripts and hot-reloading them without losing state. It is designed around one key insight: **instance state and script methods are separate**, so swapping methods never requires migrating state.

## Object Model

A script is a Lua chunk that returns a **prototype table** — its methods and defaults. The cache compiles it once and holds a registry reference to the prototype.

A behavior instance is a **`self` table**. Every `self` of a given script shares **one metatable** whose `__index` points to that script's prototype. So:

- `self:update(dt)` resolves `update` on the prototype (via `__index`).
- `self.speed` (per-instance state) lives on `self` itself.

This split is what makes hot-reload almost free.

## How Hot-Reload Works

When a script is reloaded (same name, new source), the cache:

1. **Recompiles** the source into a **new prototype**.
2. **Repoints** the shared metatable's `__index` at the new prototype.
3. **Unrefs** the old prototype.

Every live `self` instantly sees the new methods and keeps its own fields. It is **O(1)** in the number of instances: the `self` tables are never visited, copied, or migrated.

## What Survives a Reload

- **Instance state** — all fields set on `self` (e.g. `self.hp = 50`, `self.n = 42`) are untouched.
- **Method overrides** — if the prototype says `speed = 100` and an instance set `self.speed = 50`, the reloaded prototype may say `speed = 200` but the instance still reads `50` (its own field wins over `__index`).
- **The `started` flag** — `start` does NOT re-run on reload. It is one-time setup.

## What Changes on Reload

- **Method bodies** — `update`, `fixed_update`, `on_signal`, `on_destroy` are re-resolved from the new prototype for every live instance.
- **Prototype defaults** — new fields on the prototype become visible to all instances (unless shadowed by an instance field).

## The Script Component

The `Script` ECS component is the serializable link: it stores a `script_id` (a stable index into the script cache), never a VM ref. Save/load reproduces the scene; the runtime re-binds the id to the live script on load. This keeps `.zson` bit-exact — a Lua registry ref is meaningless on disk.

## API (Zig Side)

The script cache is used by the behavior system:

| Method | Description |
|---|---|
| `load(name, source)` | Loads (or reloads) a script by name. Returns the stable `ScriptId`. |
| `reload(name, source)` | Hot-reloads by name (what the editor's "reload script" action calls). |
| `instantiate(id)` | Creates a fresh `self` table with the script's shared metatable. |
| `idOf(name)` | Resolves a script name to its id, or null. |
| `prototypeRef(id)` | Returns the prototype ref (for tests and method-cache warm-up). |

## Lifecycle Interaction

When a script is reloaded, the behavior system's `recacheInstancesOf(id)` re-resolves the cached lifecycle method refs for every instance bound to that id. State (`self` tables) is untouched: only the closures cached per instance move.

The cache does **not** cache resolved methods onto `self` itself — an instance field shadows the prototype, so caching `update` onto `self` would make the next reload resolve to the very function it is trying to replace. Instead, methods are resolved through the metatable's `__index` each time (0.05 ms per 10k instances, a deliberate trade for correct hot-reload).

## Editor Workflow

1. Edit a `.lua` file in the editor.
2. The editor calls `load(name, source)` (or `reload`).
3. The cache recompiles and repoints the metatable.
4. All live instances immediately run the new code with their state intact.
5. `start` does NOT re-run — if the new `start` sets `self.n = 0`, that does NOT take effect on existing instances.

This is the "edit during play reflects instantly but the run's state is safe" contract.
