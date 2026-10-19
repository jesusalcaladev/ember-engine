# Parent — component id 2

**Registry name:** `Parent` · **id:** 2


**What it is:** one link saying "this actor hangs off that one". It is the only thing stored per entity about hierarchy; the world transform of the chain is derived, never stored, so re-parenting never costs a structural change.

| Field | Type | Default | Meaning |
|---|---|---|---|
| `parent` | `Entity` | `Entity.invalid` | The parent. Invalid (or dead) means "root". |

**Driven by:** `ecs/hierarchy.zig` — a flat, iterative, allocation-free breadth-first pass that seeds each entity's world transform from its local one and folds each child into its parent.

**Lua:** **no bindings.** Parenting is a Zig-only operation today (`Actor.setParent`), which refuses self-parenting and cycles.

**Connects to:** `Transform` (the resolver needs both).

**Gotcha:** the resolver is opt-in (`World.enableHierarchy()`), and the shipped runtime's frame loop does not call it — the renderer composes from the *local* transform.

---

---

← [Component index](README.md) · [Registry mechanics](../ecs-components.md) · [Lua API](../script-lua-api.md)
