# The editor's recovery, hot reload and prefabs

Three features of the in-engine editor, and what each one is actually
guaranteeing. They are grouped here because they share one property: **each
one exists because something went wrong before, and each one is designed
around the failure rather than around the happy path.**

- [Autosave](#autosave) — a crash must not cost the work.
- [Hot reload](#hot-reload) — a file changed outside must not be lost.
- [Flat prefabs](#flat-prefabs) — a change to an instance must be reversible.

---

## Autosave

### What it is

A **recovery file**: `<scene>.autosave`, beside the scene. The editor writes
it every 60 seconds while the document is dirty, and it is a complete `.zson`
document of the world.

It is NOT a save. The scene file is the document; the recovery file is a
safety net. The user never sees a "the file was autosaved" dialog, because
there is nothing to decide — the recovery file is only consulted when the
scene file is missing what the user believes it has.

### Why it is written the way it is

**The write goes through a temporary name and a rename.** The bytes are
written to `<scene>.autosave.tmp` and then renamed over
`<scene>.autosave`. On POSIX a rename is atomic, so there is no moment in
which the recovery file is half-written:

```
write to .tmp   rename .tmp → .autosave
     ↓                   ↓
old file intact   new file, whole
```

A crash during the write leaves the previous recovery file complete. A
recovery file that is half a scene is worse than no recovery file at all,
because the user cannot tell which half is theirs.

**The timer is separate from the write.** `Editor.tickAutosave` only
accumulates a float and decides that a write is due. The write itself is a
**queued act**, applied in `preFrame` — outside the frame's allocation guard.
Encoding a world allocates megabytes, and a frame may not (spec §3.1). This
is the same rule every other editor act follows, and the same reason: a
click inside the frame records an intent; `preFrame` turns it into an act.

**The interval is a field, not a constant.** `autosave_interval_s` lives on
the editor's state so a preference can move it into `project.config` later
without touching the frame loop. Zero turns it off.

**A clean document resets the timer.** Otherwise the first edit after a long
idle would autosave immediately, which is the opposite of what an interval
means.

### Recovery

At boot, and whenever the open scene changes, the editor compares the
recovery file's mtime with the scene file's. A recovery file that is newer is
work a crash left behind:

- The console says so, once, at boot — with the path.
- **File → Recover Unsaved Work** loads it.

The recovered document is marked **unsaved**. Recovering is not saving: the
user's work is back on screen, and it is their decision when it becomes the
file on disk. An editor that silently overwrote the scene during recovery
would be making that decision for them.

Loading the recovery file and loading the scene file are **one code path** —
`reloadScene` — because the user's action is the same ("take what is on
disk") and only the file differs.

---

## Hot reload

### What it is

The open scene file is **watched** while it is open. A change made outside the
editor — a merge, a generator, a second instance of the editor, a colleague's
commit — is noticed, and the user is told.

### What it deliberately does NOT do

**It does not reload on the spot.** A reload replaces the world: every
entity, every component, the whole document. If the user has unsaved work,
that work dies with the reload. So the change is *recorded*
(`scene_changed_on_disk`), the console says so once, and **File → Reload
Scene From Disk** takes it.

That is the difference between a hot reload and a data loss.

### Telling the editor's own save apart

A file watcher fires on the editor's own save too. The editor records the
scene file's **mtime** when it saves (`noteSceneMtime`), and the watcher
compares: a different mtime is somebody else. The mtime is the cheap check;
hashing the file would mean reading it on every save.

The watcher is **re-armed when the open scene changes** — the watched path
follows `Editor.scenePath()`, so opening another file watches that file.

### The polling is outside the frame

`FileWatcher.poll` is a syscall, and the reload itself is a queued act. Both
happen before the frame's allocation guard is armed.

---

## Flat prefabs

"Flat" means what it means in Godot: a prefab contains no other prefabs.
This engine's version is simpler still — a prefab is a **document**, and the
overrides live in a **sidecar**.

### A prefab is a `.zson` document

```
prefabs/turret.zson
```

```zson
zson 1
entity 12 {
  Name "turret"
  Transform { position: { x: 0, y: 0 }, rotation: 0, scale: { x: 1, y: 1 } }
  Sprite { size: { x: 32, y: 32 }, ... }
}
entity 13 {
  Name "barrel"
  Parent { parent: 12 }
  Sprite { size: { x: 16, y: 8 }, ... }
}
```

The grammar is **exactly a scene's**. `zson.encodeToStringEntities` writes a
subset of the world; `zson.instantiateInto` spawns it back. There is no
second format and no second parser to keep in sync with the component
registry — and the registry is what changes most often, so a second format
would be a second thing to break every time a component is added.

**Create from selection** writes the selected entity *and its children*. The
children come along because a prefab of a "turret" that leaves the barrel
behind is not what anyone means by a prefab. The `Parent` link is dropped
when it points outside the prefab — which is right: the prefab's root is a
root, and the instance lands wherever it is dropped.

**Instantiate** spawns the document at **fresh identities** (scene id 0 means
"mint a new one") and makes the names unique in the world — `enemy`,
`enemy_2` — so two instances of the same prefab can coexist. A duplicate live
name would break `findByName`, and a name that resolves to the wrong entity
is a bug that only gets worse.

### The overrides live in a sidecar

```
samples/level.zson.overrides
```

```
# ember editor: prefab overrides
instance 7 "prefabs/turret.zson" "turret"
override 7 "Sprite" "*" "{size: {x: 64, y: 64}, ...}"
```

**Why not in the world?** Two reasons, and the second one decides it.

1. The world is the **SCENE**. What the game loads is the world. A prefab
   instance in a scene is an ordinary entity with ordinary components; the
   game must not see editor bookkeeping.
2. The overrides are **per-property** in the general case, and a component
   cannot hold that without a registry entry. The registry is append-only,
   so a `SpriteOverrides` component would be a permanent, load-bearing
   addition to the engine's data model to serve a purely editorial feature.

So the sidecar is a **text file beside the scene**, keyed by entity, written
by the editor only. Losing it loses the ability to revert — never the scene.

**This build records overrides per COMPONENT**, not per field. The
inspector's widgets know which field they changed, but `queueSet` receives
the whole struct, and a component-level override is never *wrong*: it
restores the prefab's value for that component. The sidecar's format is
field-shaped (`component`, `field`, `value`) so per-field records are a
format change, not a redesign.

### Revert to Prefab

The override record holds the **current** (edited) value; the original is in
the prefab file. So a revert:

1. reads the prefab,
2. finds the entity the sidecar names (the name the **prefab** gave it, not
   the name the world gave the instance — that one may carry a suffix),
3. writes the prefab's component value into the instance's component,
4. drops the override record.

The value goes through the **same encoder and decoder** a `.zson` file goes
through (`zson.encodeComponentValue` / `zson.decodeComponentValue`). That
symmetry is the contract: a revert that restored a merely-*parsable* value
would be a lie, and a value that reads back is a value that loads.

### What the editor shows

- **Edit → Create Prefab From Selection** — writes `prefabs/<name>.zson`.
- **Edit → Instantiate Prefab…** — a modal listing the prefab files.
- **Edit → Revert To Prefab** — enabled when the selection is an instance.
- **The inspector** shows the instance's prefab, the fields that were
  changed, and the **Revert to Prefab** button.

---

## The three of them, and one rule they share

Each feature exists because of a specific failure:

| Feature | The failure it prevents |
|---|---|
| Autosave | A crash costs the work. |
| Hot reload | A change made outside is silently overwritten. |
| Prefabs | A change to a shared instance is not reversible. |

And they share one rule: **the user's data is never destroyed without the
user's decision.** The recovery file is not the scene file; the hot reload
does not reload on its own; a revert is a button the user presses. An editor
that guesses wrong is worse than one that asks.
