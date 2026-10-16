# Asset Pipeline (M6)

**Source:** `src/engine/assets/`

The asset pipeline turns files on disk into assets the engine can name, load
and reload: a PNG into a decoded image, a WAV into PCM, a `.lua` into validated
source, all under a stable GUID — and bundles the lot into one `.pak` the
exported game reads without touching the real filesystem.

It is intentionally a **load/bake-time** subsystem. Nothing here is reachable
from the frame loop (spec §3.4: no blocking I/O in a frame); hot reload is
event-driven rather than polled per frame.

```
  import.zig        bytes -> validated asset (sniff, decode, GUID, hash)
       |            uses image.zig (PNG/JPEG/WEBP), audio_asset.zig (WAV/OGG),
       |                 script_asset.zig (Lua), registry.zig (identity)
       v
  pack.zig          validated assets -> one .pak   (compress.zig per entry)
       |
       v
  vfs.zig           `.pak` OR the real filesystem behind one read surface
       |
       v
  asset_manager.zig byte-budgeted LRU of decoded payloads (spec §5)
       |
       v
  hot_reload.zig    mtime + content-hash watcher -> decode -> typed event
                        |
                        v
  (render) asset_reload.zig   event -> atlas rect -> texture, IN PLACE
```

The module depends only on `core`, so the whole pipeline tests headlessly:

```
zig build test-assets      # 36 tests, no window, GPU, Lua or Box2D
```

## Import

`import.zig` is the M6 entry point.

```zig
const asset = try import.importOne(allocator, "sprites/hero.png", bytes);
// asset.format  == .png        (detected from the BYTES, not the name)
// asset.guid    == AssetGUID.fromPath("sprites/hero.png")
// asset.image   == decoded RGBA (owned; free with asset.deinit)
```

Two rules the pipeline enforces, both of which the previous draft broke:

1. **Detection is by content, not extension.** A `.png` that is really a JPEG
   still imports as a JPEG; a `.lua` that is a renamed binary is refused. A
   path's extension is only consulted to *disambiguate text* (`.lua`).
2. **Hashing wraps on purpose.** Identity goes through `registry.hashBytes`,
   whose multiply is `*%=`. FNV's mixing *is* the `u64` overflow; a non-wrapping
   multiply panics in a Debug build, which is how the draft's `guidFromPath`
   aborted on any path longer than a few bytes.

`importBatch` builds a manifest and frees it all-or-nothing on failure;
`bakeAlloc`/`bakeFile` run a batch and write the `.pak` in one call.

| Format | Detected by | Validated by |
|---|---|---|
| PNG | `\x89PNG\r\n\x1a\n` | full decode via `stb_image` |
| JPEG | `\xFF\xD8\xFF` | full decode |
| WebP | `RIFF….WEBP` | full decode |
| WAV | `RIFF….WAVE` | chunk walk + PCM decode |
| OGG | `OggS` | Vorbis identification header |
| Lua | `.lua` + UTF-8 text | `script_asset.validate` |

## The `.pak` format

Written by `pack.writeAlloc`, read by `pack.Archive`. One encoder, one decoder,
one round-trip test — the layout has no second interpretation.

All integers are little-endian:

```
header (16 bytes)
  [0..4)    magic   "EMPK"
  [4..8)    version u32 = 2
  [8..12)   flags   u32        reserved, must be 0
  [12..16)  count   u32
entry table (count rows, variable length)
  path_len    u16
  path        [path_len]u8
  method      u8               per-entry compression (0 store, 1 deflate)
  reserved    [3]u8            zero
  offset      u64              absolute payload offset
  raw_size    u64              size before compression
  stored_size u64              size as stored
payloads (concatenated, table order)
```

- **Variable-length paths** avoid the draft's fixed-256 field, which disagreed
  with both its own reserved table size and the VFS reader.
- **Per-entry compression** is raw deflate (`compress.zig`, `std.compress.flate`),
  not zstd: Zig's standard library ships deflate as its only compressor, and a
  container written at export time should not add a second C dependency. Any
  entry that does not shrink is stored verbatim, so a "compressed" entry is
  never larger than the original.
- **Validation is total at open.** A table that points outside the buffer is
  rejected by `Archive.init`, so `extractAlloc` never bounds-checks a hostile
  offset.

```zig
const bytes = try pack.writeAlloc(allocator, &.{
    .{ .path = "sprites/hero.png", .data = png_bytes },
}, .{ .compression = .deflate });

var archive = try pack.Archive.init(allocator, bytes);
defer archive.deinit();
const hero = try archive.extractPathAlloc(allocator, "sprites/hero.png");
```

## Virtual filesystem

`vfs.VFS` gives one `readFileAlloc` / `exists` / `fileSize` surface over the
filesystem and a mounted `.pak`. The `.pak` wins when it has the entry; misses
fall through to `root/`.

```zig
var vfs = try VFS.init(allocator, io, ".", 64 * 1024);
defer vfs.deinit();
try vfs.openPak("game.pak");                 // read whole + parse once
const source = try vfs.readFileAlloc(allocator, "scripts/player.lua");
```

The `.pak` is read whole and parsed at mount; afterwards an entry is a slice of
a buffer the VFS already owns. In an export the `.pak` *is* the filesystem and
`root` is never consulted.

## Hot reload

`hot_reload.HotReload` watches paths and reports changes. Detection is a `stat`
compared by mtime and size, then confirmed by **content hash**, so a `touch`
that rewrites nothing emits no event.

```zig
var hr = HotReload.init(allocator, io, &registry);
defer hr.deinit();
try hr.watch("sprites/hero.png");

// Drive it from the platform directory watcher (inotify):
if (try hr.reloadPath("sprites/hero.png")) |change| {
    // change.image is a decoded RGBA image, valid for the callback only
}
```

- **`reloadPath` is the event-driven path.** Call it when the watcher says a
  name changed; no syscalls happen on frames without an event.
- **`scanAll` is the O(watched) fallback** — one `stat` per path, for a test or
  a platform with no watcher. It is *not* a per-frame call.
- Image changes carry a decoded `Image` in the callback; the manager owns it
  and frees it when the callback returns.

The mechanism is complete and tested. Putting a reloaded image on SCREEN is the
**render half** of the promise, and it lives on the other side of the module
boundary — `render` imports `assets`, so a callback that needs both belongs to
`render`. See [Into the atlas](#into-the-atlas-the-render-half).

## Into the atlas (the render half)

`HotReload` decides *that* an image changed; `render/asset_reload.zig` decides
what that means to the thing on screen. Two calls, and a reload that makes only
one of them changes nothing:

1. **`updateImageInAtlas`** re-blits the new pixels over the rect the sprite's UVs
   already name. A same-size edit reuses the SAME rect, so no scene bookkeeping is
   needed; only a size change repacks to a new rect and reports
   `repositioned = true`.
2. **`refreshAtlas`** writes the page into the texture the sprite's slot already
   resolves to — **in place**, so the slot a sprite stored stays valid. A refresh
   that allocated a texture instead would leave the sprite drawing the old one.

`asset_reload.Reloader` ties the two together as a `HotReload` callback:

```zig
var sink = render.asset_reload.ImageSink.forRenderer(renderer, &ctx.atlas_manager);
var reloader = render.asset_reload.Reloader{ .sink = sink.sink() };
reloader.attach(&hot);              // hot.callback/ctx now point at `reloader`
// ...in the loop, when the platform watcher reports a name:
_ = try hot.reloadPath(path);       // decode -> atlas -> texture, synchronously
```

The sink is a struct of two function pointers, not a `render.Renderer`, so the
callback is tested with a real `AtlasManager` and a fake texture table — no GPU.
`forRenderer` takes the atlas **slot's address**, read on each call, so the atlas
that the first `sprite.set_image` creates lazily is the one the boot-time sink
writes to.

The runtime wires exactly this: it watches `assets/sprites` and polls it next to
the audio watcher (outside the frame, per §3.4). `sprite.set_image(path)` registers
the path with `HotReload` as it packs it, so an edit to a live image reloads in
place, while an edit to an image nothing has drawn is a no-op — it has no rect to
update until it is first set.

## Identity and the registry

`registry.AssetRegistry` gives every asset a GUID and a dependency graph.

- `AssetGUID.fromPath(path)` — the stable id a scene or script names, whether or
  not the file is loaded.
- `AssetGUID.fromContent(path, bytes)` — path plus a content hash, which is what
  hot reload compares.
- `registry.hashBytes(bytes)` — the one FNV-1a used for identity, change
  detection and the import manifest.

## Compression

`compress.zig` wraps `std.compress.flate` in a raw container:

- `deflateAlloc(allocator, input, level)` — compress;
- `inflateAlloc(allocator, input, raw_size)` — decompress to an exact size, a
  truncated stream failing rather than returning a half-filled buffer.

## Tests

`zig build test-assets` runs the suite. The interesting assertions:

- deflate round-trips entropy and repetition at every level; a truncated stream
  errors;
- a `.pak` round-trips every entry, compressed and not;
- a corrupt archive is rejected at open, not at extract;
- the VFS serves a mounted `.pak` and shadows the filesystem;
- import detection follows bytes, not extensions;
- an edit fires hot reload once; a no-op touch fires nothing;
- watching the same path twice keeps one entry and still reloads on the edit;
- the LRU evicts to hold its byte budget with the real decoder.

`zig build test-light` runs `render/asset_reload.zig`, which asserts the reload
half end to end (a real edited PNG on disk, through the reload manager, onto an
atlas page).
