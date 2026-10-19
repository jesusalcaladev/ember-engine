//! Component registry — the single comptime source of truth (spec §7).
//!
//! This file used to hold every component inline; the registry now lives in
//! `components/`, one file per domain (name, transform, sprite, physics, light,
//! camera, timer, ...), and THIS file is the facade the rest of the engine
//! imports. The split is cosmetic on purpose: `@import("components.zig")` keeps
//! working everywhere, no call site moved, and the registry order — the dense
//! ids every committed `.zson` document rests on — is unchanged.
//!
//! What each file owns:
//! - `components/registry.zig`: the declared list, the derived ids/layout, and
//!   the plain-data rules enforced as compile errors.
//! - `components/name.zig`, `transform.zig`, `hierarchy.zig`, `sprite.zig`,
//!   `material.zig`, `script.zig`, `physics.zig`, `light.zig`, `camera.zig`,
//!   `timer.zig`: the component types, each with its own tests.
//!
//! Rules the registry enforces (see `components/registry.zig` for the full
//! text): plain data only, every field defaulted, explicit registry names, and
//! every component small enough for the `.zson` decode buffer. Adding a
//! component means APPENDING one line to `component_list` there.

const registry = @import("components/registry.zig");
const entity = @import("entity.zig");
const core_math = @import("core").math;

// Aliases the rest of the engine reads this file through, kept exactly as the
// pre-split file declared them (`ecs.Entity`, `math.Rect2`).
const ecs = entity;
const math = core_math;

pub const Entity = entity.Entity;
pub const SceneId = entity.SceneId;
pub const Vec2 = core_math.Vec2;

// ── Registry surface ─────────────────────────────────────────────────────────

pub const ComponentId = registry.ComponentId;
pub const max_components = registry.max_components;
pub const Mask = registry.Mask;
pub const max_stride = registry.max_stride;
pub const Entry = registry.Entry;
pub const entries = registry.entries;

pub const componentId = registry.componentId;
pub const strideOf = registry.strideOf;
pub const alignOfPow = registry.alignOfPow;
pub const nameOf = registry.nameOf;
pub const alignmentOf = registry.alignmentOf;
pub const idOfName = registry.idOfName;
pub const writeDefault = registry.writeDefault;

// ── Components ───────────────────────────────────────────────────────────────

pub const Name = registry.Name;
pub const Transform = registry.Transform;
pub const Parent = registry.Parent;
pub const Velocity = registry.Velocity;
pub const Blend = registry.Blend;
pub const SpriteShape = registry.SpriteShape;
pub const Sprite = registry.Sprite;
pub const ShaderMaterial = registry.ShaderMaterial;
pub const Script = registry.Script;
pub const StateMachine = registry.StateMachine;
pub const Camera2D = registry.Camera2D;
pub const Timer = registry.Timer;
pub const TimerType = registry.TimerType;
pub const RigidBody2D = registry.RigidBody2D;
pub const Collider2D = registry.Collider2D;
pub const CollisionLayers = registry.CollisionLayers;
pub const LightKind = registry.LightKind;
pub const LightBlend = registry.LightBlend;
pub const ShadowFilter = registry.ShadowFilter;
pub const OccluderPolygon = registry.OccluderPolygon;
pub const max_occluder_points = registry.max_occluder_points;
pub const OccluderMode = registry.OccluderMode;
pub const Light2D = registry.Light2D;
pub const Environment = registry.Environment;
pub const LightOccluder2D = registry.LightOccluder2D;
pub const LightBase = registry.LightBase;
pub const PointLight2D = registry.PointLight2D;
pub const SpotLight2D = registry.SpotLight2D;
pub const DirectionalLight2D = registry.DirectionalLight2D;
pub const AmbientLight2D = registry.AmbientLight2D;
pub const SoundEmitter2D = registry.SoundEmitter2D;
pub const VoiceRef = registry.VoiceRef;
pub const ParticleEmitter2D = registry.ParticleEmitter2D;
pub const EmitShape = registry.EmitShape;
pub const ParticleBackend = registry.ParticleBackend;
pub const ParticleSpace = registry.ParticleSpace;
pub const no_particle_slab = registry.no_particle_slab;
pub const packParticleColor = registry.packParticleColor;
pub const unpackParticleColor = registry.unpackParticleColor;
pub const AnimationPlayer = registry.AnimationPlayer;
pub const anim_clip_loop = registry.anim_clip_loop;
pub const anim_clip_ping_pong = registry.anim_clip_ping_pong;
pub const anim_clip_root_motion = registry.anim_clip_root_motion;
// ── M14: game UI components ─────────────────────────────────────────────────
pub const InlineText = registry.InlineText;
pub const UiAnchor = registry.UiAnchor;
pub const UiScaleMode = registry.UiScaleMode;
pub const TextAlign = registry.TextAlign;
pub const UiButtonState = registry.UiButtonState;
pub const UiLayout = registry.UiLayout;
pub const UiCanvas = registry.UiCanvas;
pub const Label = registry.Label;
pub const UiButton = registry.UiButton;
pub const UiPanel = registry.UiPanel;
pub const UiProgressBar = registry.UiProgressBar;
// M15: TileMap export surface. The types live in components/tilemap.zig (they
// predate the registry entry, and the registry entry stays parked with the rest
// of M15). The editor's tilemap workspace reaches them through this facade the
// same way it reaches Transform, so they are re-exported here rather than
// imported by path from the UI.
const tilemap_mod = @import("components/tilemap.zig");
pub const AssetGUID = tilemap_mod.AssetGUID;
pub const ChunkCoord = tilemap_mod.ChunkCoord;
pub const ChunkKey = tilemap_mod.ChunkKey;
pub const Tile = tilemap_mod.Tile;
pub const TileSet = tilemap_mod.TileSet;
pub const TileMapLayer = tilemap_mod.TileMapLayer;
pub const TileChunk = tilemap_mod.TileChunk;
pub const ChunkHandle = tilemap_mod.ChunkHandle;
pub const ChunkMap = tilemap_mod.ChunkMap;
pub const TilePhysics = tilemap_mod.TilePhysics;
pub const chunk_size = tilemap_mod.chunk_size;
pub const chunk_area = tilemap_mod.chunk_area;
// Pull the per-file tests into the suite: `zig build test` runs the tests of
// every file reachable from the root under test, and these are only reachable
// through this facade.
test {
    const std = @import("std");
    std.testing.refAllDecls(@This());
    _ = @import("components/name.zig");
    _ = @import("components/transform.zig");
    _ = @import("components/hierarchy.zig");
    _ = @import("components/sprite.zig");
    _ = @import("components/material.zig");
    _ = @import("components/script.zig");
    _ = @import("components/physics.zig");
    _ = @import("components/light.zig");
    _ = @import("components/camera.zig");
    _ = @import("components/timer.zig");
    _ = @import("components/sound_emitter.zig");
    _ = @import("components/particle.zig");
    _ = @import("components/animation.zig");
    _ = @import("components/ui.zig");
    _ = @import("components/registry.zig");
}
