# Ember Engine — Uniform Spatial Grid

The uniform spatial grid is the engine's data structure for answering neighborhood queries: "who is within 80 units of me?" It is the backing store behind the [`world.nearby`](script-lua-api.md#worldnearby) Lua binding, and it is also used internally by the steering module.

## Why It Exists

Neighborhood questions are the input to flocking, obstacle avoidance, area triggers, and squad AI. Answering them with a linear scan is O(n) per question and O(n^2) for flocking: a 200-agent flock asks 200 questions and scans 40,000 pairs per frame. The spatial grid bins entities into a uniform grid once per frame and answers each question from the ~9 cells its bounding box touches, which is O(1) in the number of entities.

## Why a Counting Grid (Not Bucket Lists)

A bucket grid (an ArrayList per cell) is the obvious shape and it allocates: clearing and refilling thousands of lists every frame is exactly the `malloc`/`free` in the frame loop that the engine forbids. The counting grid never moves an entity into storage — it counts, prefix-sums, then writes into one flat array. Three passes over the entities, zero allocations, and the same constant factor.

Overfull cells are not a special case: the flat array is sized for the total entity count, so a cell can hold any number of entities and the cost of a dense neighbourhood degrades gracefully instead of dropping agents.

## Parameters

| Parameter | Default | Meaning |
|---|---|---|
| `cell_size` | 64.0 | Cell size in world units. Chosen so a cell is about the size of a typical separation radius: a query then touches a 3x3 block instead of more. |
| `extent` | 4096.0 | World extent the grid covers, centred on the origin. A game that scrolls past it needs a bigger grid at construction. |
| `entity_capacity` | (from world) | Maximum number of entities the flat array can hold. Sized from the world at init so the grid never allocates while being filled. |

## Rebuild (Once Per Frame)

The grid is rebuilt from every entity carrying a `Transform`, once per frame, **before** gameplay runs, so a query during the frame sees the positions the frame started from.

The rebuild is three passes, no allocation:

1. **Clear counts, prefix-sum, fill.** Count how many entities land in each cell.
2. **Prefix sum.** `offsets[i]` is where cell `i`'s run begins in the flat `entries` array.
3. **Fill.** Write entities into the flat array, using offsets as write cursors. Restore the prefix sums afterward.

The grid also tracks a `self_refs` map: entity slot to the behavior's `self` table ref (or `no_self_ref` = -1). This is what allows `world.nearby` to hand Lua a real `self` table, not a bare entity — every actor binding reads the entity out of the `self` table's stamped `__entity` field.

## Query: `forEachInRadius`

`forEachInRadius(world, x, y, radius, visit)` calls `visit(Transform, Entity)` for every entity whose position is within `radius` of `(x, y)`.

The candidate set is the cells the bounding box touches; the exact circle test is applied per candidate, because a square is not a circle:

1. Compute the cell range from the query centre and radius (`span = radius / cell_size`).
2. For each cell in that range, iterate its run in the flat array.
3. For each entity, do the exact distance test: `dx*dx + dy*dy <= radius*radius`.

A cell whose size already exceeds the query radius is visited whole, which is the common case for tight queries and costs no extra branching.

## Entities Outside the Grid

Entities whose positions fall outside the grid extent are **counted**, not silently dropped. The `outside` counter is exposed so a game can detect and report actors that have wandered past the grid boundary — an actor that silently stops being visible to every neighbour is a bug that would otherwise present as "the flocking is weird in that corner."

## Idempotent Rebuild

Rebuilding is idempotent: calling it multiple times in a row produces the same grid. A stale grid would corrupt every query, so this is a critical invariant.

## Lua Binding: `world.nearby`

The Lua-facing API is a single function:

```lua
world.nearby(self, x, y, radius, fn)
```

- `self` — the asking actor (excluded from results).
- `x, y` — the query centre in world units.
- `radius` — the search radius.
- `fn` — a visitor called as `fn(other_self)` for every actor within radius.

The visitor form (rather than returning a list) keeps the engine allocation-free: materializing an array would allocate per call, and flocking calls this once per agent per frame.

```lua
-- "who is close enough to push me?"
world.nearby(self, self.px, self.py, 80, function(other)
  self.push = self.push + (other.px - self.px) * 0.01
end)
```

## Performance Characteristics

| Operation | Complexity |
|---|---|
| Rebuild | O(n) — three passes over all entities with a Transform |
| Query | O(1) in the number of entities (touches ~9 cells for a typical radius) |
| Memory | O(n + cell_count) — flat arrays, no per-cell allocation |

The grid is owned by the behavior system (which owns the VM the `self` refs point into) and is reachable from Lua through the `world` table.
