//! `engine.assets` — the asset layer (M3/M6).
//!
//! The pipeline, in dependency order:
//!
//! ```
//!   import.zig      bytes -> validated asset (format sniff, decode, GUID)
//!        |          uses: image.zig (PNG), audio_asset.zig (WAV),
//!        |                script_asset.zig (Lua), registry.zig (identity)
//!        v
//!   pack.zig        validated assets -> one .pak  (compress.zig per entry)
//!        |
//!        v
//!   vfs.zig         `.pak` OR the real filesystem behind one read surface
//!        |
//!        v
//!   asset_manager.zig  byte-budgeted LRU of decoded payloads
//!        |
//!        v
//!   hot_reload.zig  mtime watcher -> decode -> typed event (no frame I/O)
//! ```
//!
//! Everything here is load/bake-time or event-driven; nothing allocates or does
//! I/O on the game's frame path (spec §3). The module depends only on `core`,
//! which is why the whole pipeline is testable with `zig build test-assets` and
//! no window, GPU, LuaJIT or Box2D in sight.

const std = @import("std");

/// The handle/identity vocabulary.
pub const asset = @import("asset.zig");
/// Payload shapes and the cache slot.
pub const asset_types = @import("asset_types.zig");
/// Per-entry compression for the `.pak` container (raw deflate).
pub const compress = @import("compress.zig");
/// Image decoding (`stb_image`), from a path or from memory.
pub const image = @import("image.zig");
/// The `.pak` container: writer, reader, entry table.
pub const pack = @import("pack.zig");
/// Virtual filesystem: `.pak` + filesystem behind one surface.
pub const vfs = @import("vfs.zig");
/// Asset registry: stable GUID identity and the dependency graph.
pub const registry = @import("registry.zig");
/// Import pipeline: sniff, validate, decode, GUID. The M6 entry point.
pub const import = @import("import.zig");
/// The byte-budgeted LRU cache of decoded images (spec §5).
pub const asset_manager = @import("asset_manager.zig");
/// Audio asset decoding: WAV to PCM, OGG probing.
pub const audio_asset = @import("audio_asset.zig");
/// Script asset validation: encoding and shape checks before the script layer.
pub const script_asset = @import("script_asset.zig");
/// Hot reload: < 250 ms asset updates, driven by file mtimes.
pub const hot_reload = @import("hot_reload.zig");

/// Re-exports for convenience.
pub const AssetHandle = asset.AssetHandle;
pub const AssetId = asset.AssetId;
pub const AssetState = asset.AssetState;
pub const AssetKind = asset_types.AssetKind;
pub const AssetSlot = asset_types.AssetSlot;
pub const Image = asset_types.Image;
pub const AssetManager = asset_manager.AssetManager;
pub const AssetError = asset_manager.AssetError;
pub const AssetRegistry = registry.AssetRegistry;
pub const AssetGUID = registry.AssetGUID;
pub const AssetType = registry.AssetType;

/// The `.pak` container.
pub const Archive = pack.Archive;
pub const PakSource = pack.Source;
pub const PakEntry = pack.Entry;
pub const Compression = compress.Method;

/// The VFS and its decoded-asset bridges.
pub const VFS = vfs.VFS;
pub const VFSSize = vfs.Stats;
pub const HotReload = hot_reload.HotReload;

/// The import result vocabulary.
pub const ImportedAsset = import.ImportedAsset;
pub const Format = import.Format;
pub const ImportError = import.ImportError;

test {
    // `refAllDecls` pulls every public declaration into the compilation, which
    // is what makes an unused-but-broken file fail the build instead of hiding.
    std.testing.refAllDecls(@This());
    // The end-to-end suite: import -> pak -> vfs -> hot reload.
    _ = @import("assets_test.zig");
}
