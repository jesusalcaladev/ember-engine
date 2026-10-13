//! `engine.assets` — the asset layer (M3/M6).
//!
//! Complete pipeline: VFS (.pak + filesystem) → AssetManager (LRU cache)
//! → AssetRegistry (stable GUIDs) → AtlasManager (GPU upload) → HotReload
//! → Audio/Script loaders. All deterministic per spec §6.

const std = @import("std");

/// The handle/identity vocabulary.
pub const asset = @import("asset.zig");
/// Payload shapes and the cache slot.
pub const asset_types = @import("asset_types.zig");
/// The byte-budgeted LRU cache (images only).
pub const asset_manager = @import("asset_manager.zig");
/// Import pipeline: PNG/OGG/Lua batch processing.
pub const import = @import("import.zig");
/// .pak writer: export bundles (M6/M10).
pub const pack = @import("pack.zig");
/// Image decoding (`stb_image`). Load time only.
pub const image = @import("image.zig");
/// Virtual filesystem: .pak + filesystem abstraction.
pub const vfs = @import("vfs.zig");
/// Asset registry: stable GUID identity across sessions.
pub const registry = @import("registry.zig");
/// Hot reload: < 250 ms asset updates.
pub const hot_reload = @import("hot_reload.zig");
/// Audio asset bridge to audio.Bank.
pub const audio_asset = @import("audio_asset.zig");
/// Script asset bridge to script system.
pub const script_asset = @import("script_asset.zig");

/// Re-exports for convenience.
pub const AssetHandle = asset.AssetHandle;
pub const AssetId = asset.AssetId;
pub const AssetKind = asset_types.AssetKind;
pub const AssetSlot = asset_types.AssetSlot;
pub const Image = asset_types.Image;
pub const AssetManager = asset_manager.AssetManager;
pub const AssetError = asset_manager.AssetError;
pub const ImportBatch = import.ImportResult;
pub const PakWriter = pack.PakHeader;
pub const VFS = vfs.VFS;
pub const AssetRegistry = registry.AssetRegistry;
pub const HotReload = hot_reload.HotReload;

test {
    std.testing.refAllDecls(@This());
}