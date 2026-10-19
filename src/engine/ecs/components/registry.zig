//! The component registry — ids, layout and the plain-data rules, derived at
//! comptime from the declared list (split out of components.zig).
//!
//! Rules, enforced by compile error instead of runtime surprises:
//! 1. A component is **plain data**: no pointers, no slices, no unions.
//!    It must therefore be copyable, so moving an entity between archetypes
//!    is a `memcpy` of a fixed number of bytes.
//! 2. Every field (including nested ones) has a default: those defaults are
//!    the baseline a `.zson` document starts from in "replace" mode, and the
//!    baseline an override merges into in patch mode (see `zson`).
//! 3. Types are identified by their **explicit registry name** ("Transform",
//!    not a mangled path), because the text format and the profiler logs
//!    must not depend on how the module happens to be imported.
//! 4. Every component fits `max_stride`, the `.zson` decode buffer.
//!
//! Registration is closed on purpose: the ECS is an internal detail and the
//! public surface is Actor + Components (spec §7). Adding a component means
//! adding one line to `component_list` below — and APPENDING, never inserting:
//! dense ids are part of the `.zson` contract.

const std = @import("std");

const name_mod = @import("name.zig");
const transform_mod = @import("transform.zig");
const hierarchy_mod = @import("hierarchy.zig");
const sprite_mod = @import("sprite.zig");
const material_mod = @import("material.zig");
const script_mod = @import("script.zig");
const camera_mod = @import("camera.zig");
const timer_mod = @import("timer.zig");
const physics_mod = @import("physics.zig");
const light_mod = @import("light.zig");
const sound_emitter_mod = @import("sound_emitter.zig");
const particle_mod = @import("particle.zig");
const animation_mod = @import("animation.zig");
const ui_mod = @import("ui.zig");
// M15 PARKED: the tilemap subsystem is unfinished; re-enable this import with
// the component_list entry and the exports in components.zig.
// const tilemap_mod = @import("tilemap.zig");

pub const Name = name_mod.Name;
pub const Transform = transform_mod.Transform;
pub const Parent = hierarchy_mod.Parent;
pub const Velocity = hierarchy_mod.Velocity;
pub const Blend = sprite_mod.Blend;
pub const SpriteShape = sprite_mod.SpriteShape;
pub const Sprite = sprite_mod.Sprite;
pub const ShaderMaterial = material_mod.ShaderMaterial;
pub const Script = script_mod.Script;
pub const StateMachine = script_mod.StateMachine;
pub const Camera2D = camera_mod.Camera2D;
pub const Timer = timer_mod.Timer;
pub const TimerType = timer_mod.TimerType;
pub const SoundEmitter2D = sound_emitter_mod.SoundEmitter2D;
pub const VoiceRef = sound_emitter_mod.VoiceRef;
/// M9: the particle emitter (config only — the pool lives in the system).
pub const ParticleEmitter2D = particle_mod.ParticleEmitter2D;
pub const EmitShape = particle_mod.EmitShape;
pub const ParticleBackend = particle_mod.Backend;
pub const ParticleSpace = particle_mod.Space;
pub const no_particle_slab = particle_mod.no_slab;
pub const packParticleColor = particle_mod.packColor;
pub const unpackParticleColor = particle_mod.unpackColor;
/// M13: the animation player component (plain data).
pub const AnimationPlayer = animation_mod.AnimationPlayer;
pub const anim_clip_loop = animation_mod.clip_loop;
pub const anim_clip_ping_pong = animation_mod.clip_ping_pong;
pub const anim_clip_root_motion = animation_mod.clip_root_motion;
// ── M14: the game UI components (plain data) ────────────────────────────────
pub const InlineText = ui_mod.InlineText;
pub const UiAnchor = ui_mod.UiAnchor;
pub const UiScaleMode = ui_mod.UiScaleMode;
pub const TextAlign = ui_mod.TextAlign;
pub const UiButtonState = ui_mod.UiButtonState;
/// Placement is a field of every widget, not a component of its own.
pub const UiLayout = ui_mod.UiLayout;
pub const UiCanvas = ui_mod.UiCanvas;
pub const Label = ui_mod.Label;
pub const UiButton = ui_mod.UiButton;
pub const UiPanel = ui_mod.UiPanel;
pub const UiProgressBar = ui_mod.UiProgressBar;
pub const RigidBody2D = physics_mod.RigidBody2D;
pub const Collider2D = physics_mod.Collider2D;
pub const CollisionLayers = physics_mod.CollisionLayers;
pub const LightKind = light_mod.LightKind;
pub const LightBlend = light_mod.LightBlend;
pub const ShadowFilter = light_mod.ShadowFilter;
pub const OccluderPolygon = light_mod.OccluderPolygon;
pub const max_occluder_points = light_mod.max_occluder_points;
pub const OccluderMode = light_mod.OccluderMode;
pub const LightBase = light_mod.LightBase;
pub const Light2D = light_mod.Light2D;
pub const PointLight2D = light_mod.PointLight2D;
pub const SpotLight2D = light_mod.SpotLight2D;
pub const DirectionalLight2D = light_mod.DirectionalLight2D;
pub const AmbientLight2D = light_mod.AmbientLight2D;
pub const Environment = light_mod.Environment;
pub const LightOccluder2D = light_mod.LightOccluder2D;

pub const ComponentId = u16;

/// Maximum number of distinct component types. Deliberate ceiling: it keeps
/// every archetype test inside 4 machine words (`Mask`), which is what makes
/// queries cost O(#archetypes) instead of O(#entities).
pub const max_components = 256;

/// Component set as a bitmask: fast superset/disjoint tests during queries.
pub const Mask = std.StaticBitSet(max_components);

/// Buffer size generous enough to hold any registered component while
/// decoding a document. It grew from 128 to 512 for M14: a `UiButton` carries
/// its 68-byte layout, four RGBA colours and a 129-byte inline label, which does
/// not fit the old bound. The buffer is a stack local in the `.zson` decoder and
/// a field in the editor's pending-edit state; the extra 384 bytes are nothing
/// next to the correctness of "the biggest component fits".
pub const max_stride = 512;

// ── Registry ─────────────────────────────────────────────────────────────────

/// One entry per component type. Order defines the dense ids, so it is also
/// the canonical order `.zson` writes components in: identical files for
/// identical worlds (spec §6).
pub const Entry = struct {
    name: []const u8,
    type: type,
    /// Layout of one element inside an archetype column.
    stride: u32,
    align_pow: u8,
};

// Stride/alignment are derived from the type: writing them by hand is exactly
// how a silent column misalignment bug starts.
fn layoutOf(comptime T: type) struct { u32, u8 } {
    return .{ @sizeOf(T), @as(u8, @ctz(@as(usize, @alignOf(T)))) };
}

pub const entries: [component_list.len]Entry = blk: {
    var out: [component_list.len]Entry = undefined;
    for (component_list, &out) |spec, *entry| {
        const stride, const align_pow = layoutOf(spec.type);
        entry.* = .{ .name = spec.name, .type = spec.type, .stride = stride, .align_pow = align_pow };
    }
    break :blk out;
};

/// The registry as declared: name + type. Layout metadata is derived above.
///
/// APPEND-ONLY, and the first fourteen entries are load-bearing in a way the
/// rest are not: they are the M1/M2/M4 contract every committed `.zson` file
/// and every pinned test id rests on, because a dense id IS the on-disk
/// encoding. Inserting a component in the middle silently renumbers every
/// component after it, which turns every existing scene into a scene about
/// different components. So: add at the END, always.
///
/// (The four concrete light kinds were registered late for exactly this
/// reason — they were the last thing to grow the list.)
const component_list = [_]struct { name: []const u8, type: type }{
    .{ .name = "Name", .type = Name },
    .{ .name = "Transform", .type = Transform },
    .{ .name = "Parent", .type = Parent },
    .{ .name = "Velocity", .type = Velocity },
    .{ .name = "Sprite", .type = Sprite },
    .{ .name = "ShaderMaterial", .type = ShaderMaterial },
    .{ .name = "Script", .type = Script },
    .{ .name = "StateMachine", .type = StateMachine },
    .{ .name = "RigidBody2D", .type = RigidBody2D },
    .{ .name = "Collider2D", .type = Collider2D },
    .{ .name = "CollisionLayers", .type = CollisionLayers },
    .{ .name = "Light2D", .type = Light2D },
    .{ .name = "LightOccluder2D", .type = LightOccluder2D },
    .{ .name = "Environment", .type = Environment },
    // ── M7: the concrete light kinds (id 14+), appended, never inserted ────
    .{ .name = "PointLight2D", .type = PointLight2D },
    .{ .name = "SpotLight2D", .type = SpotLight2D },
    .{ .name = "DirectionalLight2D", .type = DirectionalLight2D },
    .{ .name = "AmbientLight2D", .type = AmbientLight2D },
    // ── M4.5 — appended, never inserted ────────────────────────────────────
    .{ .name = "Camera2D", .type = Camera2D },
    .{ .name = "Timer", .type = Timer },
    // ── M8 — appended, never inserted ──────────────────────────────────────
    .{ .name = "SoundEmitter2D", .type = SoundEmitter2D },
    // ── M9 — appended, never inserted ──────────────────────────────────────
    .{ .name = "ParticleEmitter2D", .type = ParticleEmitter2D },
    // -- M13 -- appended, never inserted
    .{ .name = "AnimationPlayer", .type = AnimationPlayer },
    // -- M14 -- appended, never inserted
    .{ .name = "UiCanvas", .type = UiCanvas },
    .{ .name = "Label", .type = Label },
    .{ .name = "UiButton", .type = UiButton },
    .{ .name = "UiPanel", .type = UiPanel },
    .{ .name = "UiProgressBar", .type = UiProgressBar },
    // -- M15 PARKED: appended at id 23 once the tilemap subsystem is finished.
    // .{ .name = "TileMapLayer", .type = tilemap_mod.TileMapLayer },
};

comptime {
    // The rule checks below recurse through every field of every component.
    // The default comptime branch quota (1000) is not enough once the registry
    // carries nested structs like `SoundEmitter2D.VoiceRef`, so it is raised
    // here rather than per call site: a component that trips it is a compile
    // error about the quota, not about the component.
    @setEvalBranchQuota(20000);
    if (entries.len > max_components)
        @compileError("component registry exceeds max_components (" ++ std.fmt.comptimePrint("{d}", .{max_components}) ++ ")");
    for (entries) |entry| {
        assertComponentRules(entry.type);
        if (entry.stride > max_stride)
            @compileError("component " ++ entry.name ++ " is " ++ std.fmt.comptimePrint("{d}", .{entry.stride}) ++
                " bytes, over max_stride (" ++ std.fmt.comptimePrint("{d}", .{max_stride}) ++
                "); the .zson decoder's fixed buffer would overflow");
    }
}

/// Rules 1, 2 and 4 of this file, as compile errors next to the offending type.
fn assertComponentRules(comptime T: type) void {
    if (@typeInfo(T) != .@"struct")
        @compileError("component must be a struct: " ++ @typeName(T));
    assertPlainData(T, T);
    assertDefaultable(T);
}

fn assertPlainData(comptime T: type, comptime origin: type) void {
    switch (@typeInfo(T)) {
        .bool, .int, .float => {},
        .@"enum" => {},
        .optional => |o| assertPlainData(o.child, origin),
        .array => |a| assertPlainData(a.child, origin),
        .@"struct" => |s| inline for (s.fields) |f| assertPlainData(f.type, origin),
        else => @compileError("component " ++ @typeName(origin) ++ ": field type " ++ @typeName(T) ++ " is not plain data (no pointers, slices or unions allowed)"),
    }
}

fn assertDefaultable(comptime T: type) void {
    switch (@typeInfo(T)) {
        .@"struct" => |s| inline for (s.fields) |f| {
            if (f.default_value_ptr == null)
                @compileError("component " ++ @typeName(T) ++ ": field '" ++ f.name ++ "' has no default; defaults are the .zson baseline");
            assertDefaultable(f.type);
        },
        .array => |a| assertDefaultable(a.child),
        .optional => |o| assertDefaultable(o.child),
        else => {},
    }
}

/// Dense id of a component type. Unknown type = compile error at the call
/// site, which is the point: components must be registered, not discovered.
pub fn componentId(comptime T: type) ComponentId {
    inline for (entries, 0..) |entry, i| {
        if (entry.type == T) return @as(ComponentId, @intCast(i));
    }
    @compileError("component type not registered: " ++ @typeName(T) ++ " (add it to the component_list in components/registry.zig)");
}

pub fn strideOf(id: ComponentId) u32 {
    return strides[id];
}

/// Component alignment as a power of two (column buffers are allocated with it).
pub fn alignOfPow(id: ComponentId) u8 {
    return align_pows[id];
}

/// Registry name of a component id — the name `.zson` writes and the editor
/// shows. The runtime-indexable projections below are what the storage and the
/// serializers use.
pub fn nameOf(id: ComponentId) []const u8 {
    return names[id];
}

pub fn alignmentOf(id: ComponentId) std.mem.Alignment {
    return std.mem.Alignment.fromByteUnits(@as(usize, 1) << @intCast(align_pows[id]));
}

const names: [entries.len][]const u8 = blk: {
    var out: [entries.len][]const u8 = undefined;
    for (entries, &out) |entry, *slot| slot.* = entry.name;
    break :blk out;
};

const strides: [entries.len]u32 = blk: {
    var out: [entries.len]u32 = undefined;
    for (entries, &out) |entry, *slot| slot.* = entry.stride;
    break :blk out;
};

const align_pows: [entries.len]u8 = blk: {
    var out: [entries.len]u8 = undefined;
    for (entries, &out) |entry, *slot| slot.* = entry.align_pow;
    break :blk out;
};

/// Comptime map "registry name -> id" for `.zson` decoding.
const name_to_id = blk: {
    var kvs: [entries.len]struct { []const u8, ComponentId } = undefined;
    for (entries, 0..) |entry, i| kvs[i] = .{ entry.name, @as(ComponentId, @intCast(i)) };
    break :blk std.StaticStringMap(ComponentId).initComptime(&kvs);
};

/// Id for a registry name, or `null` if that name is not a component of this
/// build (e.g. a document written by a newer version).
pub fn idOfName(name: []const u8) ?ComponentId {
    return name_to_id.get(name);
}

/// Default value of a component, as raw bytes: the "replace" baseline for
/// `.zson` documents that omit a field (decoders pass values in as bytes, so the
/// dispatch from a runtime id to a type has to happen here).
pub fn writeDefault(id: ComponentId, dst: []u8) void {
    inline for (entries, 0..) |entry, i| {
        if (id == i) {
            const value = entry.type{};
            std.mem.copyForwards(u8, dst[0..entry.stride], std.mem.asBytes(&value));
            return;
        }
    }
    std.debug.panic("components: id {d} is not in the registry", .{id});
}

// ── Tests ────────────────────────────────────────────────────────────────────

const testing = std.testing;

test "registry is dense, unique and self-consistent" {
    inline for (entries, 0..) |entry, i| {
        const id: ComponentId = @intCast(i);
        try testing.expectEqualStrings(entry.name, nameOf(id));
        try testing.expectEqual(id, componentId(entry.type));
        try testing.expectEqual(id, idOfName(entry.name).?);
        try testing.expectEqual(entry.stride, strideOf(id));
    }
}

test "component ids resolved at comptime" {
    try testing.expectEqual(@as(ComponentId, 0), componentId(Name));
    try testing.expectEqual(@as(ComponentId, 1), componentId(Transform));
    try testing.expectEqual(@as(ComponentId, 2), componentId(Parent));
    try testing.expectEqual(@as(ComponentId, 3), componentId(Velocity));
    try testing.expectEqual(@as(ComponentId, 4), componentId(Sprite));
    try testing.expectEqual(@as(?ComponentId, null), idOfName("Nope"));
}

test "the components were APPENDED, not inserted" {
    // Dense ids are part of the `.zson` contract: an inserted component would
    // silently renumber every document ever written. Pin the seam — and pin the
    // M1/M2/M4 fourteen hardest, because those are the ids every committed scene
    // already on disk was written against.
    try testing.expectEqual(@as(ComponentId, 0), componentId(Name));
    try testing.expectEqual(@as(ComponentId, 4), componentId(Sprite));
    try testing.expectEqual(@as(ComponentId, 13), componentId(Environment));
    // Everything past the M1/M2/M4 fourteen is what later milestones appended,
    // in the order they landed: M7's four lights, then M4.5's camera and timer.
    try testing.expectEqual(@as(ComponentId, 14), componentId(PointLight2D));
    try testing.expectEqual(@as(ComponentId, 17), componentId(AmbientLight2D));
    try testing.expectEqual(@as(ComponentId, 18), componentId(Camera2D));
    try testing.expectEqual(@as(ComponentId, 19), componentId(Timer));
    // M8's emitter is the next append: id 20, after Timer's 19.
    try testing.expectEqual(@as(ComponentId, 20), componentId(SoundEmitter2D));
    // M9's emitter follows it: id 21. Same rule — append, never insert.
    try testing.expectEqual(@as(ComponentId, 21), componentId(ParticleEmitter2D));
    // M13's animation player: id 22.
    try testing.expectEqual(@as(ComponentId, 22), componentId(AnimationPlayer));
    // M15 PARKED: the tilemap layer would be id 23; disabled for now.
    // try testing.expectEqual(@as(ComponentId, 23), componentId(tilemap_mod.TileMapLayer));
    // M14 appended five UI components after animation: ids 23..27.
    try testing.expectEqual(@as(ComponentId, 23), componentId(UiCanvas));
    try testing.expectEqual(@as(ComponentId, 24), componentId(Label));
    try testing.expectEqual(@as(ComponentId, 25), componentId(UiButton));
    try testing.expectEqual(@as(ComponentId, 26), componentId(UiPanel));
    try testing.expectEqual(@as(ComponentId, 27), componentId(UiProgressBar));
    try testing.expectEqual(@as(usize, 28), entries.len);
}

test "default baseline bytes match a default value" {
    var buf: [@sizeOf(Transform)]u8 align(@alignOf(Transform)) = undefined;
    writeDefault(componentId(Transform), &buf);
    const restored: *const Transform = @ptrCast(&buf);
    try testing.expectApproxEqAbs(@as(f32, 1), restored.scale.x, 0.0001);
}