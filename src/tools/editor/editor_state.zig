//! The editor's own state — the thing the shell, the menüs and every panel
//! read and write.
//!
//! ## One owner, and it is the session model
//!
//! The world has exactly one owner: `session.Model`, which already existed for
//! this purpose and already carries the two things a real editor is defined by
//! — a **selection** and an **undo/redo journal of acts** (`session/model.zig`).
//! The editor does not keep a second copy of the world, and it does not keep a
//! second undo stack: it edits through the model, and both the menu's "Undo set"
//! label and the undo itself come from the same stack the runtime's tests
//! exercise.
//!
//! That is also why every mutation here is *queued* rather than applied at the
//! click site: `Model.spawn`/`set`/`add`/`remove` journal and therefore
//! allocate, and the editor's frame loop runs under a no-allocation guard (spec
//! §3.1). A click inside the frame records an intent; `preFrame` — which runs
//! outside the guard — turns it into an act.
//!
//! ## Why the panels hold pointers, not closures
//!
//! Zig has no closures, and `ui.layout`/`ui.list` take `*const fn(*Context) void`
//! bodies. So the panels published here are reached through `active`, set once
//! per frame by the shell. It is the same trick `tilemap_panel` uses, and it is
//! the honest shape of an immediate-mode UI in a language without closures.

const std = @import("std");
const engine = @import("engine");
const ui = @import("ui");

const ecs = engine.ecs;
const session = @import("session");
const script = engine.script;

const console_mod = @import("console.zig");
const asset_browser = @import("asset_browser.zig");
const tilemap_panel = @import("tilemap_panel.zig");
const code_pane = @import("code_pane.zig");
const viewport_mod = @import("viewport.zig");
const prefab_mod = @import("prefab.zig");

pub const Entity = ecs.Entity;
pub const Model = session.model.Model;
pub const Console = console_mod.Console;
pub const Level = console_mod.Level;
pub const AssetBrowser = asset_browser.AssetBrowser;
pub const Vec2 = ecs.components.Vec2;
pub const CollisionLayers = ecs.components.CollisionLayers;

/// Cached atlas page side, matching the budget the runtime uses. A lazy
/// creation constant, not a policy: it is what the atlas manager is created
/// with when the first browser image arrives.
pub const atlas_side: u32 = 2048;

/// The payload kinds the editor's drag-and-drop uses. String names, because
/// the payload kind crosses the C shim as text and because a second copy of a
/// kind on one panel would silently drop into nothing.
pub const drag_kinds = struct {
    /// 8 bytes: entity index + generation, little-endian.
    pub const entity: [:0]const u8 = "ember/entity";
    /// NUL-terminated relative path of a file the browser is dragging.
    pub const file: [:0]const u8 = "ember/file";
};

/// Serializes one entity handle for a drag payload.
pub fn encodeEntity(e: Entity, buf: *[8]u8) void {
    std.mem.writeInt(u32, buf[0..4], e.index, .little);
    std.mem.writeInt(u32, buf[4..8], e.generation, .little);
}

/// The inverse of `encodeEntity`. Rejects short payloads rather than guessing.
pub fn decodeEntity(payload: []const u8) ?Entity {
    if (payload.len != 8) return null;
    return Entity{
        .index = std.mem.readInt(u32, payload[0..4], .little),
        .generation = std.mem.readInt(u32, payload[4..8], .little),
    };
}

/// The Spawn Sprite bridge — the render side the editor needs to turn a file
/// on disk into a sprite that draws.
///
/// It is a POINTER set by `main` because the renderer and the asset manager
/// are values there, alive for the whole run, and the editor only borrows
/// them. The atlas handle is opaque (`?*anyopaque`): the backend's draw path
/// is the only thing that resolves it, and the editor's job is to thread it
/// back through the same calls the Lua API does, not to know what it is.
pub const RenderBridge = struct {
    renderer: *engine.render.Renderer,
    assets: *engine.assets.AssetManager,
    /// The atlas manager (as an opaque backend handle), created on the first
    /// image so a session that never touches the browser never pays for a
    /// 16 MB page.
    atlas: ?*anyopaque = null,
};

/// The centre of the editor. One tab bar, and switching a tab swaps ONLY the
/// centre — the docks stay put, and the selection, the open scene and the undo
/// history belong to the editor and survive the switch (ROADMAP M5.7).
pub const Workspace = enum { scene, script };

pub const PlayState = enum { stopped, playing, paused };

/// The parts of the dock layout the user can drag.
///
/// Pixels for the three docks, a FRACTION for the hierarchy/assets split so the
/// split survives a window resize instead of turning into "assets is 300px no
/// matter how tall the window is". The shell clamps these at use rather than
/// writing clamped values back: shrinking the window must not silently forget
/// the widths the user chose for a bigger one.
pub const Layout = struct {
    left: f32 = 264,
    right: f32 = 320,
    console: f32 = 168,
    /// The share of the left column the hierarchy takes.
    split: f32 = 0.56,
};

/// The panels a View menu can hide. Kept as a struct of booleans rather than a
/// bitset because the layout reads them by name and a `|` mask cannot be grepped.
pub const PanelVisibility = struct {
    hierarchy: bool = true,
    inspector: bool = true,
    assets: bool = true,
    console: bool = true,
    tilemap: bool = true,
};

/// One queued component write. The bytes are the NEW value; the OLD one is read
/// from the live component when the act is recorded, which is what makes the
/// undo step return to the value before the drag rather than to the value after
/// it.
const PendingSet = struct {
    entity: Entity = Entity.invalid,
    component: u16 = 0,
    bytes: [ecs.components.max_stride]u8 = undefined,
    len: u16 = 0,
};

/// Intents that are one act of history, or one file operation. Queued by name
/// so the order the user clicked them is the order they happen in.
const Action = enum { create, duplicate, delete, save, open, new_scene, undo, redo, spawn_sprite, begin_play, end_play, create_prefab, instantiate_prefab, revert_prefab, autosave, reload_scene };

/// Number of named collision layers. 16 bits, so 16 names — the masks are
/// `u16` and the bit the user sees is the row they named here.
pub const layer_bits = 16;
/// Length of one layer-name cell, including room for the terminator.
pub const layer_name_len = 24;

pub const Editor = struct {
    allocator: std.mem.Allocator,
    model: *Model,

    console: Console = .{},
    assets: AssetBrowser,
    /// The tool panels the shell draws inside its own dock windows. They are
    /// pointers, not values, because `main.zig` owns them: the brush loop and
    /// the pane's input handling run outside the frame, next to the world they
    /// edit, and a second copy inside the editor would be a second source of
    /// truth.
    tilemap: ?*tilemap_panel.Panel = null,
    pane: ?*code_pane.Pane = null,
    /// The scene viewport: persistent camera, cursor/tile tool, grid and
    /// gizmo state. Lives here because both consumers reach it every frame —
    /// the tool pill in the shell and main's pointer loop — and because one
    /// copy of camera state is the only copy that can be trusted.
    viewport: viewport_mod.Viewport = .{},
    /// Set by `main` after the renderer and the asset registry exist. Null in
    /// the headless run, where "spawn a sprite" can only be a logged refusal.
    bridge: ?*RenderBridge = null,
    /// The asset file the queued `.spawn_sprite` act pulls in. A fixed buffer,
    /// like every path the editor owns.
    sprite_asset: [512]u8 = undefined,
    sprite_asset_len: usize = 0,
    /// One act behind the sprite act: re-parent the freshly spawned sprite
    /// under the entity a drop landed on. Null resets requestSpawnSprite.
    pending_sprite_under: ?Entity = null,
    selection: ?Entity = null,
    play: PlayState = .stopped,
    /// A single fixed tick requested while paused.
    step_pending: bool = false,

    // ── Play-in-editor: the M5 snapshot contract ────────────────────────────
    //
    // Entering Play takes a zson document of the world and hashes it; Stop
    // restores that document IN PLACE (the same `zson.replace` the Open path
    // uses, so no cached `*World` has to move) and the hash proves the restore.
    // Nothing the game does during Play survives: edits made while playing are
    // microframes the Stop throws away. This is the editor side of
    // `session/play.zig`, which is headless; the editor adds only WHEN the two
    // halves run (queued acts in `preFrame`, because encode/decode allocate and
    // this runs outside the frame's allocation guard).
    /// The world document captured when Play began. The only truth Stop
    /// restores from.
    play_snapshot: ?[]u8 = null,
    /// The zson hash the world had on entry — the number a Stop must
    /// reproduce. Verified on stop and REPORTED, never asserted: a mismatch is
    /// information the user wants in their console, not a crash the editor
    /// should die on.
    play_hash: u64 = 0,
    /// What "unsaved" meant when Play began. The restore brings back the world,
    /// so it must bring back its dirty state too — otherwise a Stop invents
    /// edits that were never made.
    dirty_before_play: bool = false,
    /// The selection when Play began. The played world's entities died with the
    /// world (the replace rebuilds slot-for-slot, so the handles come back as
    /// they went in) and the user's selection is editor state, not gameplay
    /// state — Stop has no business clearing it.
    selection_before_play: ?Entity = null,
    /// The scripting system, set by `main` after it exists (null headless).
    /// `beginPlay` warms it up so actor `start`s run; Stop's world swap kills
    /// every instance the played world held, and the sweep each frame already
    /// performs dispatches their `on_destroy` and frees their refs.
    behaviors: ?*script.Behaviors = null,
    workspace: Workspace = .scene,
    panels: PanelVisibility = .{},
    layout: Layout = .{},

    /// Last frame's wall time. The status bar reports it, and it is measured by
    /// the frame loop (the one place that already owns the clock), not by the
    /// UI: a second clock is a second definition of "frame".

    /// The scene the Save menu writes and the Open menu reads. A buffer and not
    /// a slice: the toolbar edits it in place, and an editor owns its own path.
    frame_dt: f32 = 0,
    scene_path: [256]u8 = undefined,
    scene_path_len: usize = 0,
    open_path: [256]u8 = undefined,
    open_path_len: usize = 0,

    /// Set by any queued act; cleared by save/open. It is the editor's own flag
    /// and not `Model.dirty` because "the file on disk matches" and "the journal
    /// has entries" are different questions — an undo back to the saved state
    /// leaves the journal non-empty and the file correct.
    dirty: bool = false,
    /// Set by the menu's Quit item.
    should_quit: bool = false,
    /// True for one frame after a scene replace, so the frame loop rebuilds the
    /// physics bodies for the world that just arrived.
    scene_replaced: bool = false,

    // ── Prefabs (flat, file-backed) ─────────────────────────────────────────
    //
    // The prefab machinery lives in `prefab.zig`; the editor holds the state
    // it needs: where the prefabs live, which one is being worked on, and the
    // sidecar that records the overrides.
    /// The prefab sidecar: the instances of this scene and the overrides on
    /// them. It carries its own allocator (the editor's), so it is set in
    /// `init` rather than defaulted here.
    prefabs: prefab_mod.Sidecar,
    /// The prefab file the next instantiate act will load ("prefabs/enemy.zson").
    prefab_asset: [256]u8 = undefined,
    prefab_asset_len: usize = 0,
    /// The prefab picker modal: open, and the list of prefab files it shows.
    ///
    /// The list is REFRESHED when the modal opens, not every frame: scanning
    /// a directory allocates (the names are owned), and the modal is drawn
    /// inside the frame.
    prefab_picker_open: bool = false,
    prefab_picker_entries: std.ArrayListUnmanaged([128]u8) = .empty,
    prefab_picker_len: usize = 0,
    prefab_picker_selected: usize = 0,
    /// The name the next "create prefab" act will use. Empty means "ask".
    prefab_name: [64]u8 = undefined,
    prefab_name_len: usize = 0,
    /// The sidecar's path for the open scene, rebuilt when the scene changes.
    prefab_sidecar_path: [320]u8 = undefined,
    prefab_sidecar_path_len: usize = 0,
    /// True when the sidecar on disk is newer than the scene it belongs to —
    /// the signal that a crash left work behind.
    prefab_sidecar_stale: bool = false,

    // ── Autosave ────────────────────────────────────────────────────────────
    //
    // How often the editor writes a recovery copy of the scene, in seconds.
    // Zero turns it off. The value is a field rather than a constant so the
    // preference can live in `project.config` later without touching the
    // frame loop.
    autosave_interval_s: f32 = 60.0,
    /// Seconds since the last autosave. Accumulated by the frame loop, which
    /// owns the clock.
    autosave_timer: f32 = 0,
    /// The recovery file for the open scene ("<scene>.autosave").
    autosave_path: [320]u8 = undefined,
    autosave_path_len: usize = 0,
    /// True when a recovery file exists that is newer than the saved scene.
    /// The editor offers to restore it at boot rather than silently.
    autosave_recoverable: bool = false,

    // ── Hot reload ──────────────────────────────────────────────────────────
    //
    // The scene file is watched while it is open, so a change made outside the
    // editor (a merge, a generator, a second instance) shows up instead of
    // being overwritten by the next save.
    hot_reload_enabled: bool = true,
    /// The mtime the editor last saw for the scene file. A change is "the file
    /// on disk is newer than what we have" — and mtime is compared, not
    /// content, because the content check costs a full read.
    scene_mtime_ns: i128 = 0,
    /// True when the file changed on disk and the editor has NOT reloaded it
    /// yet (because the user has unsaved work, or the reload is queued).
    scene_changed_on_disk: bool = false,

    /// Per-component-type expansion in the inspector. Keyed by component type
    /// and not by (entity, type): opening "Sprite" once should stay open for the
    /// next thing the user clicks, which is what every inspector does.
    insp_open: [ecs.components.entries.len]bool = [_]bool{true} ** ecs.components.entries.len,

    // ── Queued work ─────────────────────────────────────────────────────────
    pending: [32]PendingSet = [_]PendingSet{.{}} ** 32,
    pending_len: usize = 0,
    pending_select: ?Entity = null,
    pending_add_component: ?u16 = null,
    /// Open the component picker modal.
    pending_add_component_list: bool = false,
    pending_remove_component: ?u16 = null,
    pending_rename: bool = false,
    actions: [16]Action = undefined,
    actions_len: usize = 0,

    /// The inline rename buffer, owned by the editor because the text field does
    /// not own a buffer (see `ui.input.textField`).
    rename_buf: [64]u8 = [_]u8{0} ** 64,
    /// The entity whose name is being edited inline, or null.
    renaming: ?Entity = null,

    /// Hierarchy search text. Live: filtering is a read of this buffer.
    filter_buf: [64]u8 = [_]u8{0} ** 64,

/// The component picker modal state.
    component_picker_open: bool = false,
    component_picker_entity: ?Entity = null,

    // ── Collision layers (the editor's layer table) ─────────────────────────
    // Godot's "Layer Names" project setting, for the same reason: a 16-bit
    // mask nobody has names is a mask nobody can set correctly. The names are
    // the editor's own table (a project-wide setting is M-project work), NUL
    // terminated so a text field can edit the buffer in place.
    layer_names: [layer_bits][layer_name_len]u8 = undefined,
    layer_names_open: bool = false,

    // ── Re-parenting ────────────────────────────────────────────────────────
    /// The "Set Parent" flow: the user clicks the button (entering this mode),
    /// then clicks an entity in the hierarchy, and the child is re-parented on
    /// that click instead of being selected. Cancels on Escape or a second
    /// click of the button.
    pick_parent: bool = false,
    /// Queued re-parent, drained outside the frame like every act.
    pending_reparent_child: ?Entity = null,
    pending_reparent_parent: ?Entity = null,
    pending_detach: bool = false,

    // ── Hierarchy tree state ────────────────────────────────────────────────
    /// Expanded/collapsed per entity INDEX (not slot): an undo that moves an
    /// entity to a different slot keeps its open state. Beyond the array the
    /// tree is always open, which is the honest fallback for a scene larger
    /// than the array — it degrades to the flat list, not to hidden rows.
    tree_open: [1024]bool = [_]bool{true} ** 1024,

    // ── Methods ──────────────────────────────────────────────────────────────

    // ── Methods ──────────────────────────────────────────────────────────────

    pub fn init(allocator: std.mem.Allocator, model: *Model) Editor {
        var ed = Editor{
            .allocator = allocator,
            .model = model,
            .assets = AssetBrowser.init(allocator),
            .prefabs = .{ .allocator = allocator },
        };
        ed.setPath(&ed.scene_path, &ed.scene_path_len, "samples/editor_scene.zson");
        ed.setPath(&ed.open_path, &ed.open_path_len, "samples/scene.zson");
        ed.resetLayerNames();
        ed.rebuildRecoveryPaths();
        ed.log(.info, "editor ready — {d} entities", .{model.entityCount()});
        return ed;
    }

    /// Recomputes the paths that follow the open scene: the sidecar beside
    /// it, the recovery file beside it, and what the sidecar says.
    ///
    /// Called when the scene changes and at boot. The sidecar is READ here
    /// (not written) so the editor knows which instances have overrides
    /// before anything touches the world.
    pub fn rebuildRecoveryPaths(self: *Editor) void {
        const scene = self.scenePath();

        // The sidecar: "<scene>.overrides".
        const side = std.fmt.bufPrint(&self.prefab_sidecar_path, "{s}.overrides", .{scene}) catch {
            self.prefab_sidecar_path_len = 0;
            return;
        };
        self.prefab_sidecar_path_len = side.len;

        // The recovery file: "<scene>.autosave".
        const rec = std.fmt.bufPrint(&self.autosave_path, "{s}.autosave", .{scene}) catch {
            self.autosave_path_len = 0;
            return;
        };
        self.autosave_path_len = rec.len;

        // Read the sidecar. A missing file is an empty sidecar, not an error.
        self.prefabs.deinit();
        self.prefabs = prefab_mod.Sidecar.load(self.allocator, self.prefab_sidecar_path[0..self.prefab_sidecar_path_len]) catch |err| blk: {
            self.log(.warn, "prefab sidecar unreadable: {s}", .{@errorName(err)});
            break :blk prefab_mod.Sidecar{ .allocator = self.allocator };
        };

        // A recovery file newer than the scene is work a crash left behind.
        self.autosave_recoverable = self.recoveryIsNewer();
    }

    /// True when the recovery file exists and is newer than the scene file.
    fn recoveryIsNewer(self: *const Editor) bool {
        const io = std.Io.Threaded.global_single_threaded.io();
        const rec = std.Io.Dir.cwd().statFile(io, self.autosave_path[0..self.autosave_path_len], .{}) catch return false;
        const scene = std.Io.Dir.cwd().statFile(io, self.scenePath(), .{}) catch return true;
        return rec.mtime.nanoseconds > scene.mtime.nanoseconds;
    }

    /// Layer names back to the default table. Used at boot and by the
    /// "Reset names" item in the names dialog.
    pub fn resetLayerNames(self: *Editor) void {
        var i: usize = 0;
        while (i < layer_bits) : (i += 1) {
            const s = std.fmt.bufPrint(&self.layer_names[i], "Layer {d}", .{i + 1}) catch "Layer";
            self.layer_names[i][s.len] = 0;
        }
    }

    pub fn layerName(self: *const Editor, i: usize) []const u8 {
        if (i >= layer_bits) return "?";
        const cell = &self.layer_names[i];
        return std.mem.sliceTo(cell, 0);
    }

    /// The default name when the user has not renamed a layer yet. Godot shows
    /// "Layer N" until touched; so does this, by construction of `resetLayer`.
    pub fn setLayerName(self: *Editor, i: usize, name: []const u8) void {
        if (i >= layer_bits) return;
        @memset(&self.layer_names[i], 0);
        const n = @min(name.len, layer_name_len - 1);
        @memcpy(self.layer_names[i][0..n], name[0..n]);
    }

    /// One summary of what a mask selects, in the names the user gave: a grid
    /// of checkboxes with no readable summary is a grid nobody can audit.
    pub fn describeMask(self: *const Editor, mask: u16, buf: []u8) []const u8 {
        if (mask == 0) return "—";
        if (mask == CollisionLayers.everything) return "everything";
        var w: std.Io.Writer = .fixed(buf);
        var i: usize = 0;
        var first = true;
        while (i < layer_bits) : (i += 1) {
            if ((mask >> @intCast(i)) & 1 == 0) continue;
            if (!first) {
                w.writeAll(", ") catch return buf[0..w.end];
            }
            w.writeAll(self.layerName(i)) catch break;
            first = false;
        }
        return buf[0..w.end];
    }

    pub fn deinit(self: *Editor) void {
        if (self.play_snapshot) |s| self.allocator.free(s);
        self.play_snapshot = null;
        self.prefabs.deinit();
        self.assets.deinit();
        self.* = undefined;
    }

    fn setPath(_: *Editor, buf: *[256]u8, len: *usize, p: []const u8) void {
        const n = @min(p.len, buf.len);
        @memcpy(buf[0..n], p[0..n]);
        len.* = n;
    }

    pub fn scenePath(self: *const Editor) []const u8 {
        return self.scene_path[0..self.scene_path_len];
    }
    pub fn openPath(self: *const Editor) []const u8 {
        return self.open_path[0..self.open_path_len];
    }

    /// Points both the Save and the Open path at one file. Used when the editor
    /// is launched ON a scene: the next Ctrl+S must write the document it just
    /// loaded, not the default path.
    pub fn setSceneFile(self: *Editor, p: []const u8) void {
        self.setPath(&self.scene_path, &self.scene_path_len, p);
        self.setPath(&self.open_path, &self.open_path_len, p);
    }

    /// The Asset Browser's "open this .zson" path: points the Open buffer at
    /// the picked file and queues the load. The queue is what makes the click
    /// frame-rule clean — replacing a world allocates, and the click happens
    /// inside the frame guard.
    pub fn openFile(self: *Editor, p: []const u8) void {
        self.setPath(&self.open_path, &self.open_path_len, p);
        self.pushAction(.open);
    }

    pub fn world(self: *Editor) *ecs.World {
        return self.model.world();
    }

    pub fn log(self: *Editor, level: Level, comptime fmt: []const u8, args: anytype) void {
        self.console.push(level, fmt, args);
    }

    // ── Queued edits, called from inside the frame ──────────────────────────

    pub fn requestCreate(self: *Editor) void {
        self.pushAction(.create);
    }
    pub fn requestNewScene(self: *Editor) void {
        self.pushAction(.new_scene);
    }
    pub fn requestDuplicate(self: *Editor) void {
        self.pushAction(.duplicate);
    }
    pub fn requestDelete(self: *Editor) void {
        self.pushAction(.delete);
    }
    pub fn requestSave(self: *Editor) void {
        self.pushAction(.save);
    }
    pub fn requestOpen(self: *Editor) void {
        self.pushAction(.open);
    }

    /// Queue "make a sprite entity from this asset file". The load and the
    /// atlas upload allocate (a decode is megabytes), so the work happens in
    /// `preFrame`, on the safe side of the frame's allocation guard — the
    /// queue is what makes the click frame-rule clean.
    pub fn requestSpawnSprite(self: *Editor, asset_path: []const u8) void {
        const n = @min(asset_path.len, self.sprite_asset.len - 1);
        @memcpy(self.sprite_asset[0..n], asset_path[0..n]);
        self.sprite_asset[n] = 0;
        self.sprite_asset_len = n;
        self.pending_sprite_under = null;
        self.pushAction(.spawn_sprite);
    }

    /// The drop-on-entity flow: the sprite spawns AND becomes a child of the
    /// entity it was dropped on, in one queued act pair (spawn first, then the
    /// re-parent, which is the order undo replays in).
    pub fn requestSpawnSpriteUnder(self: *Editor, asset_path: []const u8, parent: Entity) void {
        self.requestSpawnSprite(asset_path);
        self.pending_sprite_under = parent;
    }
    pub fn requestUndo(self: *Editor) void {
        self.pushAction(.undo);
    }
    pub fn requestRedo(self: *Editor) void {
        self.pushAction(.redo);
    }

    // ── Prefabs ─────────────────────────────────────────────────────────────

    /// "Create prefab from selection": the selected entity (and its children)
    /// is written to `prefabs/<name>.zson`.
    ///
    /// The name comes from the entity's own `Name` component, because that is
    /// the name the user already sees in the hierarchy; the name can be
    /// overridden before the act runs.
    pub fn requestCreatePrefab(self: *Editor) void {
        if (self.selection) |e| {
            if (self.world().get(e, ecs.components.Name)) |n| {
                const s = n.slice();
                const len = @min(s.len, self.prefab_name.len - 1);
                @memcpy(self.prefab_name[0..len], s[0..len]);
                self.prefab_name[len] = 0;
                self.prefab_name_len = len;
            }
        }
        self.pushAction(.create_prefab);
    }

    /// Sets the name the next "create prefab" act will use.
    pub fn setPrefabName(self: *Editor, name: []const u8) void {
        const n = @min(name.len, self.prefab_name.len - 1);
        @memcpy(self.prefab_name[0..n], name[0..n]);
        self.prefab_name[n] = 0;
        self.prefab_name_len = n;
    }

    pub fn prefabName(self: *const Editor) []const u8 {
        return self.prefab_name[0..self.prefab_name_len];
    }

    /// "Instantiate prefab": the named file is spawned into the world at a
    /// fresh identity, and the sidecar records where it came from.
    pub fn requestInstantiatePrefab(self: *Editor, path: []const u8) void {
        const n = @min(path.len, self.prefab_asset.len - 1);
        @memcpy(self.prefab_asset[0..n], path[0..n]);
        self.prefab_asset[n] = 0;
        self.prefab_asset_len = n;
        self.pushAction(.instantiate_prefab);
    }

    /// Opens the prefab picker, refreshing the list of prefab files.
    ///
    /// The refresh is a directory scan, which allocates — so it happens HERE,
    /// on the click, which is outside the frame's allocation guard (the menu
    /// item is drawn inside the frame, but the click's work is queued).
    pub fn openPrefabPicker(self: *Editor) void {
        self.refreshPrefabList();
        self.prefab_picker_open = true;
    }

    /// The prefab files in `prefabs/`, as paths relative to the project root.
    pub fn refreshPrefabList(self: *Editor) void {
        self.prefab_picker_entries.deinit(self.allocator);
        self.prefab_picker_entries = .empty;
        self.prefab_picker_len = 0;
        self.prefab_picker_selected = 0;

        const io = std.Io.Threaded.global_single_threaded.io();
        var dir = std.Io.Dir.cwd().openDir(io, "prefabs", .{ .iterate = true }) catch {
            // No prefabs folder yet: the picker says so, and creating a
            // prefab makes the folder.
            return;
        };
        defer dir.close(io);

        var it = dir.iterate();
        while (it.next(io) catch null) |entry| {
            if (entry.kind == .directory) continue;
            if (!std.mem.endsWith(u8, entry.name, ".zson")) continue;
            var buf: [128]u8 = undefined;
            _ = std.fmt.bufPrint(&buf, "prefabs/{s}", .{entry.name}) catch continue;
            self.prefab_picker_entries.append(self.allocator, buf) catch break;
            self.prefab_picker_len += 1;
        }
    }

    /// The prefab paths the picker shows.
    pub fn prefabList(self: *const Editor) []const [128]u8 {
        return self.prefab_picker_entries.items;
    }

    pub fn prefabListLen(self: *const Editor) usize {
        return self.prefab_picker_len;
    }

    pub fn prefabListSelected(self: *const Editor) usize {
        return self.prefab_picker_selected;
    }

    pub fn setPrefabListSelected(self: *Editor, i: usize) void {
        self.prefab_picker_selected = i;
    }

    /// "Revert to prefab": the instance's overridden fields are written back
    /// to the prefab's values, and the override records are dropped.
    pub fn requestRevertPrefab(self: *Editor) void {
        self.pushAction(.revert_prefab);
    }

    /// The prefab an entity was instantiated from, or null.
    pub fn prefabOf(self: *Editor, e: Entity) ?prefab_mod.Instance {
        const sid = self.world().sceneIdOf(e);
        if (sid == 0) return null;
        return self.prefabs.instanceOf(sid);
    }

    /// The overrides recorded for an entity.
    ///
    /// The returned slice is ALWAYS the caller's to free — including the empty
    /// one. A `&.{}` fallback would be a static slice the caller must not
    /// free, and "sometimes you own it" is a worse contract than "you always
    /// do".
    pub fn overridesOf(self: *Editor, e: Entity) []prefab_mod.Override {
        const sid = self.world().sceneIdOf(e);
        if (sid == 0) return self.allocator.alloc(prefab_mod.Override, 0) catch &.{};
        return self.prefabs.overridesOf(sid, self.allocator) catch self.allocator.alloc(prefab_mod.Override, 0) catch &.{};
    }

    // ── Autosave ────────────────────────────────────────────────────────────

    /// Called by the frame loop with the frame's elapsed time. Returns true
    /// when an autosave is due, and the act is queued.
    ///
    /// The timer runs on the frame loop's clock and the WRITE happens in
    /// `preFrame` — outside the allocation guard, because encoding a world
    /// allocates and a frame may not.
    pub fn tickAutosave(self: *Editor, dt: f32) bool {
        if (self.autosave_interval_s <= 0) return false;
        if (!self.dirty) {
            // Not dirty: reset the timer, so the first edit after a long idle
            // does not autosave immediately.
            self.autosave_timer = 0;
            return false;
        }
        self.autosave_timer += dt;
        if (self.autosave_timer < self.autosave_interval_s) return false;
        self.autosave_timer = 0;
        self.pushAction(.autosave);
        return true;
    }

    /// The recovery file's path, for the UI to show.
    pub fn autosavePath(self: *const Editor) []const u8 {
        return self.autosave_path[0..self.autosave_path_len];
    }

    /// Writes the recovery copy NOW, rather than waiting for the interval.
    /// The menu item behind it is the user's own "save my work" gesture.
    pub fn requestAutosaveNow(self: *Editor) void {
        self.pushAction(.autosave);
    }

    /// True when the selected entity is an instance of a prefab — the
    /// condition for "Revert To Prefab" being worth a click.
    pub fn selectionIsPrefabInstance(self: *Editor) bool {
        const e = self.selection orelse return false;
        if (!self.world().isAlive(e)) return false;
        return self.prefabOf(e) != null;
    }

    /// Restores the recovery file over the current scene, if there is one.
    pub fn requestRecoverAutosave(self: *Editor) void {
        self.pushAction(.reload_scene);
    }

    // ── Hot reload ──────────────────────────────────────────────────────────

    /// The frame loop tells the editor the scene file changed on disk.
    ///
    /// The editor does NOT reload it on the spot: a reload replaces the world,
    /// and the user may have unsaved work. The change is recorded, the status
    /// bar says so, and the user decides (File → Reload From Disk).
    pub fn notifySceneChanged(self: *Editor) void {
        if (self.scene_changed_on_disk) return;
        self.scene_changed_on_disk = true;
        self.log(.warn, "the scene file changed on disk — File → Reload to take it", .{});
    }

    /// True when the file on disk is newer than what the editor has.
    pub fn sceneChangedOnDisk(self: *Editor) bool {
        return self.scene_changed_on_disk;
    }

    /// The mtime the editor has for the scene file, recorded at load and save.
    pub fn noteSceneMtime(self: *Editor) void {
        const io = std.Io.Threaded.global_single_threaded.io();
        const st = std.Io.Dir.cwd().statFile(io, self.scenePath(), .{}) catch return;
        self.scene_mtime_ns = st.mtime.nanoseconds;
        self.scene_changed_on_disk = false;
    }

    fn pushAction(self: *Editor, action: Action) void {
        if (self.actions_len >= self.actions.len) return;
        self.actions[self.actions_len] = action;
        self.actions_len += 1;
    }

    pub fn select(self: *Editor, e: Entity) void {
        self.selection = e;
        self.pending_select = e;
    }

    /// The inspector's write path: the widget wrote into a local copy of the
    /// component, and this is the copy handed to the journal.
    ///
    /// When the entity is a prefab INSTANCE, the change is also recorded as an
    /// OVERRIDE — the sidecar's list of what the user changed on this
    /// instance, which is what "Revert to Prefab" later undoes.
    ///
    /// The recording is at COMPONENT granularity, not field granularity, and
    /// that is a deliberate limit: the inspector's widgets know which field
    /// they changed, but `queueSet` receives the whole struct. A component
    /// level override means a revert restores the whole component, which is
    /// the common case anyway (a drag on a colour, a drag on a size) and is
    /// never wrong — it restores the prefab's value for that component.
    pub fn queueSet(self: *Editor, e: Entity, comptime T: type, value: T) void {
        // A long-lived drag produces one of these per frame. Coalescing on the
        // same (entity, component) pair is what makes the whole drag ONE undo
        // act, and it happens in `Model.set`, so dropping the duplicate frames
        // here would only lose the last value.
        if (self.pending_len >= self.pending.len) {
            // Over full: replace the last slot rather than lose the newest
            // value. The alternative — dropping it — makes a drag silently stop
            // responding.
            self.pending_len -= 1;
        }
        const slot = &self.pending[self.pending_len];
        slot.entity = e;
        slot.component = ecs.components.componentId(T);
        const bytes = std.mem.asBytes(&value);
        slot.len = @intCast(bytes.len);
        @memcpy(slot.bytes[0..bytes.len], bytes);
        self.pending_len += 1;
        self.dirty = true;
    }

    pub fn beginRename(self: *Editor, e: Entity) void {
        const name = self.world().get(e, ecs.components.Name) orelse return;
        const s = name.slice();
        const n = @min(s.len, self.rename_buf.len - 1);
        @memcpy(self.rename_buf[0..n], s[0..n]);
        self.rename_buf[n] = 0;
        self.renaming = e;
        self.selection = e;
        self.pending_select = e;
    }

    pub fn commitRename(self: *Editor) void {
        // `renaming` stays set: `preFrame` is what turns it into an act, and it
        // needs to know which entity to write.
        if (self.renaming) |e| {
            self.pending_rename = true;
            self.pending_select = e;
            self.dirty = true;
        }
    }

    pub fn cancelRename(self: *Editor) void {
        self.renaming = null;
    }

    /// Every intent that allocates, drained OUTSIDE the frame guard. The order
    /// is fixed and deliberate: component writes first (they are the common
    /// case and the ones a structural change could invalidate), then the acts,
    /// then the selection — because `create` picks the new entity and the
    /// selection has to be applied after it exists.
    pub fn preFrame(self: *Editor) void {
        if (self.assets.want_refresh) self.assets.refresh();

        self.applyPendingSets();

        if (self.pending_add_component) |id| {
            self.pending_add_component = null;
            if (self.selection) |e| self.addComponent(e, id);
        }
        if (self.pending_add_component_list) {
            self.pending_add_component_list = false;
            if (self.selection) |e| self.openComponentPicker(e);
        }
        if (self.pending_remove_component) |id| {
            self.pending_remove_component = null;
            if (self.selection) |e| self.removeComponent(e, id);
        }

        if (self.pending_rename) {
            self.pending_rename = false;
            if (self.renaming) |e| self.applyRename(e);
            self.renaming = null;
        }

        if (self.pending_detach) {
            self.pending_detach = false;
            if (self.selection) |e| self.detachParent(e);
        }
        if (self.pending_reparent_child) |child| {
            self.pending_reparent_child = null;
            if (self.pending_reparent_parent) |parent| {
                self.pending_reparent_parent = null;
                self.reparent(child, parent);
            }
        }

        var i: usize = 0;
        while (i < self.actions_len) : (i += 1) {
            switch (self.actions[i]) {
                .create => self.createEntity(),
                .duplicate => self.duplicateSelected(),
                .delete => self.deleteSelected(),
                .save => self.saveScene(),
                .open => self.openScene(),
                .new_scene => self.newScene(),
                .undo => self.undo(),
                .redo => self.redo(),
                .spawn_sprite => self.spawnSpriteFromAsset(),
                .begin_play => self.beginPlay(),
                .end_play => self.endPlay(),
                .create_prefab => self.createPrefab(),
                .instantiate_prefab => self.instantiatePrefab(),
                .revert_prefab => self.revertPrefab(),
                .autosave => self.performAutosave(),
                .reload_scene => self.reloadScene(),
            }
        }
        self.actions_len = 0;

        if (self.pending_select) |e| {
            self.pending_select = null;
            if (self.world().isAlive(e)) {
                self.model.select(e) catch {};
            }
        }
    }

    fn applyPendingSets(self: *Editor) void {
        var i: usize = 0;
        while (i < self.pending_len) : (i += 1) {
            const slot = &self.pending[i];
            self.setById(slot.entity, slot.component, slot.bytes[0..slot.len]);
            // A change to a prefab INSTANCE is also an override: the sidecar
            // records it, and "Revert to Prefab" is what undoes it.
            self.recordOverride(slot.entity, slot.component);
        }
        self.pending_len = 0;
    }

    /// Records that a component of an instance was changed.
    ///
    /// The record is per-COMPONENT, and the value stored is the component's
    /// WHOLE value as text — the shape `zson` writes it in. A revert then
    /// decodes that text back into the component, which restores the prefab's
    /// value for the whole component.
    ///
    /// The value is read AFTER the change was applied, so it is the value the
    /// user actually set — and the sidecar replaces an earlier record for the
    /// same component, so a drag that produced thirty frames leaves ONE
    /// record with the final value.
    fn recordOverride(self: *Editor, e: Entity, component_id: u16) void {
        const sid = self.world().sceneIdOf(e);
        if (sid == 0) return;
        if (self.prefabs.instanceOf(sid) == null) return; // not an instance

        const id: ecs.components.ComponentId = component_id;
        const name = ecs.components.nameOf(id);

        // The component's value, as text. A component the entity does not have
        // (it was just removed) has no value to record.
        var out: std.Io.Writer.Allocating = .init(self.allocator);
        defer out.deinit();
        inline for (ecs.components.entries, 0..) |_, i| {
            if (i == component_id) {
                const arch = self.world().archetypeAt(self.world().archIndexOf(e) orelse return);
                const row = self.world().rowOf(e);
                const col = arch.findColumn(id) orelse return;
                const bytes = arch.columnBytes(col, row);
                ecs.zson.encodeComponentValue(id, &out.writer, self.world(), bytes) catch return;
            }
        }
        const value = out.toOwnedSlice() catch return;
        defer self.allocator.free(value);

        self.prefabs.setOverride(sid, name, "*", value) catch return;
        self.saveSidecar();
    }

    /// The runtime-type → comptime-type dispatch. The registry is the only
    /// place that knows the mapping, so this walks it rather than keeping a
    /// second table that could drift.
    fn setById(self: *Editor, e: Entity, id: u16, bytes: []const u8) void {
        inline for (ecs.components.entries, 0..) |entry, i| {
            if (i == id) {
                const T = entry.type;
                if (bytes.len < @sizeOf(T)) return;
                if (self.world().get(e, T) == null) return;
                var value: T = undefined;
                @memcpy(std.mem.asBytes(&value), bytes[0..@sizeOf(T)]);
                self.model.set(T, e, value) catch |err| {
                    self.log(.err, "set {s}: {s}", .{ entry.name, @errorName(err) });
                };
            }
        }
    }

    fn addComponent(self: *Editor, e: Entity, id: u16) void {
        inline for (ecs.components.entries, 0..) |entry, i| {
            if (i == id) {
                const T = entry.type;
                var value: T = undefined;
                ecs.components.writeDefault(id, std.mem.asBytes(&value));
                self.model.add(e, value) catch |err| {
                    self.log(.err, "add {s}: {s}", .{ entry.name, @errorName(err) });
                    return;
                };
                self.log(.info, "added {s}", .{entry.name});
                self.dirty = true;
            }
        }
    }

    fn removeComponent(self: *Editor, e: Entity, id: u16) void {
        inline for (ecs.components.entries, 0..) |entry, i| {
            if (i == id) {
                const T = entry.type;
                self.model.remove(T, e) catch |err| {
                    self.log(.err, "remove {s}: {s}", .{ entry.name, @errorName(err) });
                    return;
                };
                self.log(.info, "removed {s}", .{entry.name});
                self.dirty = true;
            }
        }
    }

    fn openComponentPicker(self: *Editor, e: Entity) void {
        self.component_picker_entity = e;
        self.component_picker_open = true;
    }

    // ── Re-parenting ────────────────────────────────────────────────────────

    /// Edit → "Set Parent" mode. Clicking an entity in the hierarchy now
    /// re-parents under it instead of selecting it. A second click of the
    /// button (or Escape) leaves the mode.
    pub fn requestSetParent(self: *Editor) void {
        if (self.selection == null) {
            self.log(.warn, "select an entity first", .{});
            return;
        }
        self.pick_parent = !self.pick_parent;
        if (self.pick_parent) self.log(.info, "pick parent: click an entity in the hierarchy", .{});
    }

    pub fn cancelPickParent(self: *Editor) void {
        self.pick_parent = false;
    }

    /// Handles a hierarchy click while the pick-parent mode is on. Returns the
    /// entity the click landed on when the caller should treat it as a
    /// selection, false-ish otherwise — the hierarchy asks this BEFORE it does
    /// its own select, so the one event has exactly one meaning.
    pub fn pickParentClick(self: *Editor, e: Entity) bool {
        if (!self.pick_parent) return true; // not in pick mode: caller selects
        self.pick_parent = false;
        const child = self.selection orelse return false;
        if (child.index == e.index and child.generation == e.generation) {
            self.log(.warn, "an entity cannot be its own parent", .{});
            return false;
        }
        self.pending_reparent_child = child;
        self.pending_reparent_parent = e;
        return false;
    }

    /// Moves `child` under `parent`. Guarded against cycles: making a parent a
    /// descendant of its own child would trap the transform solver in a loop,
    /// so a chain walk rejects it first.
    fn reparent(self: *Editor, child: Entity, parent: Entity) void {
        const w = self.world();
        if (!w.isAlive(child) or !w.isAlive(parent)) return;

        // The cycle walk is bounded, like `depthOf`: a bad scene must not hang
        // the editor while fixing itself.
        var cur = parent;
        var hops: usize = 0;
        while (hops < 256) : (hops += 1) {
            if (cur.index == child.index and cur.generation == child.generation) {
                self.log(.err, "cannot re-parent under a descendant", .{});
                return;
            }
            const p = w.get(cur, ecs.components.Parent) orelse break;
            if (!w.isAlive(p.parent)) break;
            cur = p.parent;
        }

        const link = ecs.components.Parent{ .parent = parent };
        if (w.get(child, ecs.components.Parent) != null) {
            self.model.set(ecs.components.Parent, child, link) catch |err| {
                self.log(.err, "re-parent: {s}", .{@errorName(err)});
                return;
            };
        } else {
            self.model.add(child, link) catch |err| {
                self.log(.err, "re-parent: {s}", .{@errorName(err)});
                return;
            };
        }
        self.dirty = true;
        if (w.get(parent, ecs.components.Name)) |n| {
            self.log(.info, "made child of {s}", .{n.slice()});
        } else {
            self.log(.info, "made child of entity {d}", .{parent.index});
        }
    }

    /// Removes the Parent link; the entity becomes a root.
    pub fn requestDetach(self: *Editor) void {
        self.pending_detach = true;
    }

    fn detachParent(self: *Editor, e: Entity) void {
        self.model.remove(ecs.components.Parent, e) catch |err| {
            self.log(.err, "detach: {s}", .{@errorName(err)});
            return;
        };
        self.dirty = true;
        self.log(.info, "detached from its parent", .{});
    }

    // ── Spawn Sprite (the browser → scene path) ─────────────────────────────

    /// The act behind "Spawn Sprite" in the asset browser: load the image,
    /// pack it into the atlas, upload, and educate an entity that draws it.
    ///
    /// This is the SAME path the Lua API uses (`sprite.set_image` in
    /// bindings.zig), for one reason: two ways of getting pixels to the GPU
    /// means two ways for them to disagree.
    ///
    /// Runs in `preFrame` — the decode and the upload allocate, and this runs
    /// outside the frame's allocation guard. `Model.spawn` is what journals,
    /// so the spawn itself is undoable like every other edit.
    fn spawnSpriteFromAsset(self: *Editor) void {
        const bridge = self.bridge orelse {
            self.log(.warn, "no render bridge — sprites come from --headless's world only", .{});
            return;
        };
        // The drop target is consumed at entry: a failed spawn must not lose
        // it (the act queued a child under a specific entity), but a LATER
        // plain spawn must not inherit it either.
        const parent_target = self.pending_sprite_under;
        self.pending_sprite_under = null;
        const path = std.mem.sliceTo(self.sprite_asset[0..self.sprite_asset_len], 0);
        if (path.len == 0) return;
        defer self.sprite_asset_len = 0;

        // Load + decode through the same pipeline the game uses.
        const slot = bridge.assets.getOrLoad(path) catch |err| {
            self.log(.err, "load '{s}': {s}", .{ path, @errorName(err) });
            return;
        };
        const payload = bridge.assets.get(.{ .id = slot, .generation = 0 }) orelse {
            self.log(.err, "load '{s}': not loaded", .{path});
            return;
        };
        const image: *const engine.assets.Image = @ptrCast(@alignCast(payload));

        // The atlas director: created lazily on the first image. The handle is
        // opaque on purpose — only the backend resolves it.
        const atlas = bridge.atlas orelse blk: {
            const a = bridge.renderer.createAtlasManager(atlas_side, atlas_side) orelse {
                self.log(.err, "could not create the atlas manager", .{});
                return;
            };
            bridge.atlas = a;
            break :blk a;
        };

        const update = bridge.renderer.updateImageInAtlas(atlas, path, image.width, image.height, image.pixels) orelse {
            self.log(.err, "pack '{s}': too big for an atlas page or bad handle", .{path});
            return;
        };
        const texture = bridge.renderer.refreshAtlas(atlas) orelse {
            self.log(.err, "upload '{s}': atlas refresh failed", .{path});
            return;
        };

        // The handle is an index + 1 (0 = "none"), the convention bindings.zig
        // documents. Checked, not truncating: a 256th texture drawing the wrong
        // page silently is the worst possible failure mode of a u8 field.
        const texture_index = @intFromPtr(texture) - 1;
        if (texture_index > std.math.maxInt(u8)) {
            self.log(.err, "atlas texture table is full", .{});
            return;
        }

        // The entity: named after the file, sprite sized to the image but
        // capped so a 4K texture does not fill the whole viewport.
        var name_buf: [ecs.components.Name.max_len + 8]u8 = undefined;
        const stem = if (std.mem.lastIndexOfScalar(u8, path, '/')) |slash| path[slash + 1 ..] else path;
        const name = std.fmt.bufPrint(&name_buf, "{s}", .{stem}) catch stem;

        var size = ecs.components.Vec2{
            .x = @floatFromInt(image.width),
            .y = @floatFromInt(image.height),
        };
        const max_px: f32 = 512;
        const longest = @max(size.x, size.y);
        if (longest > max_px) {
            const s = max_px / longest;
            size.x *= s;
            size.y *= s;
        }

        const e = self.model.spawn(.{
            ecs.components.Name.init(name),
            ecs.components.Transform{ .position = .{ .x = 0, .y = 0 } },
            ecs.components.Sprite{
                .atlas = @intCast(texture_index),
                .uv = .{ update.uv[0], update.uv[1], update.uv[2], update.uv[3] },
                .size = size,
                .tint = .{ 1, 1, 1, 1 },
            },
        }) catch |err| {
            self.log(.err, "spawn sprite: {s}", .{@errorName(err)});
            return;
        };
        self.dirty = true;
        self.selection = e;
        self.pending_select = e;
        self.log(.success, "spawned sprite '{s}' ({d}×{d})", .{ name, image.width, image.height });
        // The drop-on-entity flow finishes here: the new sprite becomes a
        // child of what it was dropped on. Called directly (not queued) — this
        // IS preFrame work already, running outside the frame guard.
        if (parent_target) |parent| self.reparent(e, parent);
    }

    // ── Tree open state ─────────────────────────────────────────────────────

    pub fn treeOpen(self: *const Editor, e: Entity) bool {
        if (e.index >= self.tree_open.len) return true;
        return self.tree_open[e.index];
    }

    pub fn toggleTree(self: *Editor, e: Entity) void {
        if (e.index >= self.tree_open.len) return;
        self.tree_open[e.index] = !self.tree_open[e.index];
    }

    pub fn setAllTreeOpen(self: *Editor, open: bool) void {
        @memset(&self.tree_open, open);
    }

    fn applyRename(self: *Editor, e: Entity) void {
        const text = std.mem.sliceTo(&self.rename_buf, 0);
        if (text.len == 0) return;
        self.model.set(ecs.components.Name, e, ecs.components.Name.init(text)) catch |err| {
            self.log(.err, "rename: {s}", .{@errorName(err)});
            return;
        };
        self.log(.info, "renamed to \"{s}\"", .{text});
    }

    // ── Acts ────────────────────────────────────────────────────────────────

    fn createEntity(self: *Editor) void {
        const e = self.model.spawn(.{
            ecs.components.Name.init("Entity"),
            ecs.components.Transform{},
        }) catch |err| {
            self.log(.err, "create failed: {s}", .{@errorName(err)});
            return;
        };
        self.log(.info, "created entity {d}", .{e.index});
        self.dirty = true;
        self.selection = e;
        self.pending_select = e;
    }

    /// A copy of the selection that is safe to hand to the physics solver: the
    /// body and shape handles are NOT copied. A duplicated `RigidBody2D` that
    /// still points at the original's body would make two components own one
    /// solver body, and the first `sync` would move the copy to wherever the
    /// original was.
    fn duplicateSelected(self: *Editor) void {
        const src = self.selection orelse return;
        const w = self.world();
        if (!w.isAlive(src)) return;

        const dst = self.model.spawn(.{}) catch |err| {
            self.log(.err, "duplicate failed: {s}", .{@errorName(err)});
            return;
        };

        if (w.get(src, ecs.components.Name)) |n| {
            var copy: [ecs.components.Name.max_len + 8]u8 = undefined;
            const made = std.fmt.bufPrint(&copy, "{s} copy", .{n.slice()}) catch copy[0..0];
            self.model.add(dst, ecs.components.Name.init(made)) catch {};
        }
        if (w.get(src, ecs.components.Transform)) |tr| {
            var t = tr.*;
            t.position.x += 16;
            t.position.y += 16;
            t.capturePrevious();
            self.model.add(dst, t) catch {};
        }
        if (w.get(src, ecs.components.Sprite)) |s| self.model.add(dst, s.*) catch {};
        if (w.get(src, ecs.components.Velocity)) |v| self.model.add(dst, v.*) catch {};
        if (w.get(src, ecs.components.Camera2D)) |c| self.model.add(dst, c.*) catch {};
        if (w.get(src, ecs.components.Timer)) |t| self.model.add(dst, t.*) catch {};
        if (w.get(src, ecs.components.Light2D)) |l| self.model.add(dst, l.*) catch {};
        if (w.get(src, ecs.components.RigidBody2D)) |rb| {
            var copy = rb.*;
            copy.body = ecs.components.RigidBody2D.invalid_body;
            copy.generation = 0;
            self.model.add(dst, copy) catch {};
        }
        if (w.get(src, ecs.components.Collider2D)) |col| {
            var copy = col.*;
            copy.shape = ecs.components.Collider2D.invalid_shape;
            copy.generation = 0;
            self.model.add(dst, copy) catch {};
        }
        if (w.get(src, ecs.components.CollisionLayers)) |cl| self.model.add(dst, cl.*) catch {};

        self.log(.info, "duplicated entity {d}", .{src.index});
        self.dirty = true;
        self.selection = dst;
        self.pending_select = dst;
    }

    fn deleteSelected(self: *Editor) void {
        const e = self.selection orelse return;
        if (!self.world().isAlive(e)) return;
        self.model.despawn(e) catch |err| {
            self.log(.err, "delete failed: {s}", .{@errorName(err)});
            return;
        };
        self.log(.info, "deleted entity {d}", .{e.index});
        self.dirty = true;
        self.selection = null;
        self.pending_select = null;
        // The model's selection is its own list, and a handle that names a
        // destroyed row is a selection nothing can act on.
        self.model.clearSelection();
    }

    fn undo(self: *Editor) void {
        if (self.model.undo()) |label| {
            // Undo changes the document: the file on disk is now older than the
            // world, which is exactly what the unsaved marker means.
            self.dirty = true;
            self.log(.info, "undo {s}", .{label});
            self.pruneSelection();
        } else {
            self.log(.warn, "nothing to undo", .{});
        }
    }

    fn redo(self: *Editor) void {
        if (self.model.redo()) |label| {
            self.dirty = true;
            self.log(.info, "redo {s}", .{label});
            self.pruneSelection();
        } else {
            self.log(.warn, "nothing to redo", .{});
        }
    }

    fn pruneSelection(self: *Editor) void {
        if (self.selection) |e| {
            if (!self.world().isAlive(e)) self.selection = null;
        }
    }

    // ── Files ──────────────────────────────────────────────────────────────

    fn saveScene(self: *Editor) void {
        const bytes = ecs.zson.encodeToString(self.world(), self.allocator) catch |err| {
            self.log(.err, "encode failed: {s}", .{@errorName(err)});
            return;
        };
        defer self.allocator.free(bytes);

        const io = std.Io.Threaded.global_single_threaded.io();
        std.Io.Dir.cwd().writeFile(io, .{ .sub_path = self.scenePath(), .data = bytes }) catch |err| {
            self.log(.err, "cannot write {s}: {s}", .{ self.scenePath(), @errorName(err) });
            return;
        };
        self.dirty = false;
        self.noteSceneMtime();
        self.log(.success, "saved {s} ({d} bytes, {d} entities)", .{ self.scenePath(), bytes.len, self.model.entityCount() });
    }

    fn openScene(self: *Editor) void {
        const io = std.Io.Threaded.global_single_threaded.io();
        const bytes = std.Io.Dir.cwd().readFileAlloc(io, self.openPath(), self.allocator, .limited(8 << 20)) catch |err| {
            self.log(.err, "cannot read {s}: {s}", .{ self.openPath(), @errorName(err) });
            return;
        };
        defer self.allocator.free(bytes);

        const w = self.world();
        const before = w.entityCount();
        ecs.zson.replace(w, bytes) catch |err| {
            // `replace` never leaves a half-loaded world: the engine rebuilds
            // in place and reports failure instead of keeping the pieces.
            self.log(.err, "cannot load {s}: {s}", .{ self.openPath(), @errorName(err) });
            return;
        };

        // The archetypes are fresh, so the guarantees the editor made to the
        // subsystems are re-established here rather than assumed.
        self.reassertWorldInvariants();

        // Save from now on writes the document that was opened. An Open that
        // leaves Save pointing at the previous file is how an editor silently
        // forks a project into two scenes nobody can tell apart.
        self.setPath(&self.scene_path, &self.scene_path_len, self.openPath());

        // The sidecar and the recovery file follow the scene: they belong to
        // the document that was just opened, not to the one before it.
        self.rebuildRecoveryPaths();

        self.model.clearHistory();
        self.model.clearSelection();
        self.selection = null;
        self.pending_select = null;
        self.scene_replaced = true;
        self.dirty = false;
        self.noteSceneMtime();
        self.log(.success, "opened {s} ({d} → {d} entities)", .{ self.openPath(), before, w.entityCount() });
    }

    /// File → New Scene. A DOCUMENT operation, not an undoable edit: the history
    /// belongs to the scene that is being replaced, so it is cleared rather than
    /// left holding acts that name entities which no longer exist.
    ///
    /// It replaces the world IN PLACE through the same `zson.replace` the Open
    /// path uses. The alternative — despawning every entity through the model —
    /// journals a whole-world snapshot per entity (a despawn's payload is a
    /// document), which is O(n²) on a scene of any size. The address stays the
    /// same either way, so no subsystem has to re-learn its `*World`.
    fn newScene(self: *Editor) void {
        const w = self.world();
        const before = w.entityCount();
        ecs.zson.replace(w, "zson 1\n") catch |err| {
            self.log(.err, "new scene: {s}", .{@errorName(err)});
            return;
        };
        self.reassertWorldInvariants();
        self.model.clearHistory();
        self.model.clearSelection();
        self.selection = null;
        self.pending_select = null;
        self.pending_len = 0;
        self.scene_replaced = true;
        self.dirty = false;
        self.log(.success, "new scene ({d} entities cleared)", .{before});
    }

    // ── Prefabs ─────────────────────────────────────────────────────────────

    /// Writes the selected entity (and its children) to `prefabs/<name>.zson`.
    ///
    /// The children come along because a prefab of a "turret" that leaves the
    /// barrel behind is not what anyone means by a prefab. The parent link is
    /// dropped by the encoder when it points outside the prefab — which is
    /// exactly right: the prefab's root is a root, and the instance lands
    /// wherever it is dropped.
    fn createPrefab(self: *Editor) void {
        const root = self.selection orelse {
            self.log(.warn, "select an entity to make a prefab of it", .{});
            return;
        };
        if (!self.world().isAlive(root)) return;

        // The subtree: the entity and every descendant.
        var members: std.ArrayListUnmanaged(Entity) = .empty;
        defer members.deinit(self.allocator);
        self.collectSubtree(root, &members) catch {
            self.log(.err, "prefab: out of memory", .{});
            return;
        };
        if (members.items.len == 0) return;

        const name = if (self.prefabName().len > 0) self.prefabName() else "prefab";
        const path = prefab_mod.prefabPath(self.allocator, name) catch {
            self.log(.err, "prefab: out of memory", .{});
            return;
        };
        defer self.allocator.free(path);

        const text = ecs.zson.encodeToStringEntities(self.world(), members.items, self.allocator) catch |err| {
            self.log(.err, "prefab: encode failed: {s}", .{@errorName(err)});
            return;
        };
        defer self.allocator.free(text);

        // The `prefabs/` directory may not exist yet — a project that has never
        // made a prefab has no such folder, and creating the file would fail
        // with a message about a missing directory rather than about the
        // prefab.
        const io = std.Io.Threaded.global_single_threaded.io();
        std.Io.Dir.cwd().createDirPath(io, "prefabs") catch {};

        std.Io.Dir.cwd().writeFile(io, .{ .sub_path = path, .data = text }) catch |err| {
            self.log(.err, "prefab: cannot write {s}: {s}", .{ path, @errorName(err) });
            return;
        };
        self.log(.success, "prefab saved: {s} ({d} entities)", .{ path, members.items.len });
    }

    /// The entity and every descendant, in a stable order (the entity first,
    /// then its children breadth-first). The order is what makes the prefab
    /// file's records come out the same way twice.
    fn collectSubtree(self: *Editor, root: Entity, out: *std.ArrayListUnmanaged(Entity)) !void {
        try out.append(self.allocator, root);
        var i: usize = 0;
        while (i < out.items.len) : (i += 1) {
            const parent = out.items[i];
            var slot: usize = 0;
            while (slot < self.world().slotCount()) : (slot += 1) {
                const other = self.world().entityAtSlot(slot) orelse continue;
                const p = self.world().get(other, ecs.components.Parent) orelse continue;
                if (!p.parent.eql(parent)) continue;
                try out.append(self.allocator, other);
            }
        }
    }

    /// Spawns the prefab file's entities into the world at fresh identities.
    ///
    /// The instance is recorded in the sidecar, which is what makes "revert to
    /// prefab" possible later: without the record, the editor cannot know
    /// which file an entity came from, and an override is a value with no
    /// origin.
    fn instantiatePrefab(self: *Editor) void {
        const path = self.prefab_asset[0..self.prefab_asset_len];
        if (path.len == 0) {
            self.log(.warn, "no prefab selected", .{});
            return;
        }

        const io = std.Io.Threaded.global_single_threaded.io();
        const text = std.Io.Dir.cwd().readFileAlloc(io, path, self.allocator, .limited(4 << 20)) catch |err| {
            self.log(.err, "prefab: cannot read {s}: {s}", .{ path, @errorName(err) });
            return;
        };
        defer self.allocator.free(text);

        // The names the prefab gives its records, in the order the records
        // appear. The i-th created entity is the i-th record, so the two lists
        // are the same list seen from two sides.
        const names = ecs.zson.recordNames(self.allocator, text) catch |err| {
            self.log(.err, "prefab: cannot read {s}: {s}", .{ path, @errorName(err) });
            return;
        };
        defer {
            for (names) |n| self.allocator.free(n);
            self.allocator.free(names);
        }

        // The entities the instantiation creates, in the same order. A fixed
        // buffer: a prefab with more entities than this is refused rather than
        // silently truncated, and the limit is generous for a flat prefab.
        var created_buf: [256]ecs.Entity = undefined;
        const created = ecs.zson.instantiateInto(self.world(), text, &created_buf) catch |err| {
            self.log(.err, "prefab: instantiate failed: {s}", .{@errorName(err)});
            return;
        };
        if (created == 0) {
            self.log(.warn, "prefab: {s} is empty", .{path});
            return;
        }

        // Record the origin. The name stored is the PREFAB's name, not the
        // world's: a second instance of the same prefab is called `enemy_2` in
        // the world, and a revert has to find the record the instance came
        // from, not the name the world gave it.
        for (created_buf[0..created], 0..) |e, i| {
            const sid = self.world().sceneIdOf(e);
            if (sid == 0) continue;
            const source_name = if (i < names.len) names[i] else "";
            self.prefabs.addInstance(sid, path, source_name) catch {
                self.log(.err, "prefab: out of memory", .{});
                return;
            };
        }
        self.saveSidecar();

        // The new root is selected: an instantiated prefab is what the user
        // is now looking at, and selecting it is what shows its properties.
        if (created > 0) self.select(created_buf[0]);

        self.log(.success, "instantiated {s} ({d} entities)", .{ path, created });
        self.dirty = true;
    }

    /// Writes the prefab's values back over the instance's overridden
    /// components.
    ///
    /// The override records hold the CURRENT (edited) value, not the original
    /// one — the original is in the prefab file. So a revert reads the prefab,
    /// finds the entity it names, and writes that entity's component value
    /// into the instance's component. The record is then dropped, because the
    /// component is no longer an override.
    fn revertPrefab(self: *Editor) void {
        const e = self.selection orelse {
            self.log(.warn, "select an instance to revert it", .{});
            return;
        };
        const sid = self.world().sceneIdOf(e);
        if (sid == 0) return;
        const inst = self.prefabs.instanceOf(sid) orelse {
            self.log(.warn, "that entity is not a prefab instance", .{});
            return;
        };

        // The prefab's document, decoded into a scratch world so the values
        // can be read without touching the live one.
        const io = std.Io.Threaded.global_single_threaded.io();
        const text = std.Io.Dir.cwd().readFileAlloc(io, inst.prefab, self.allocator, .limited(4 << 20)) catch |err| {
            self.log(.err, "prefab: cannot read {s}: {s}", .{ inst.prefab, @errorName(err) });
            return;
        };
        defer self.allocator.free(text);

        var scratch = ecs.zson.decode(self.allocator, text) catch |err| {
            self.log(.err, "prefab: cannot decode {s}: {s}", .{ inst.prefab, @errorName(err) });
            return;
        };
        defer scratch.deinit();

        // The entity inside the prefab. The sidecar stored the name the
        // PREFAB gave it — not the name the world gave the instance, which
        // may carry a suffix (`enemy_2`).
        const src = scratch.findByName(inst.source_name) orelse {
            self.log(.err, "prefab: {s} has no entity named {s}", .{ inst.prefab, inst.source_name });
            return;
        };

        // Every override of this instance, written back.
        var reverted: usize = 0;
        for (self.prefabs.overrides.items) |o| {
            if (o.entity != sid) continue;
            const id = ecs.components.idOfName(o.component) orelse continue;

            // The prefab's value for that component, written as text.
            var out: std.Io.Writer.Allocating = .init(self.allocator);
            defer out.deinit();
            const src_arch = scratch.archetypeAt(scratch.archIndexOf(src).?);
            const src_row = scratch.rowOf(src);
            const col = src_arch.findColumn(id) orelse continue;
            ecs.zson.encodeComponentValue(id, &out.writer, &scratch, src_arch.columnBytes(col, src_row)) catch continue;
            const value = out.toOwnedSlice() catch continue;
            defer self.allocator.free(value);

            // And into the instance's component.
            const arch = self.world().archetypeAt(self.world().archIndexOf(e) orelse continue);
            const row = self.world().rowOf(e);
            const icol = arch.findColumn(id) orelse continue;
            ecs.zson.decodeComponentValue(id, self.world(), arch.columnBytes(icol, row), value) catch {
                self.log(.warn, "prefab: cannot revert {s}", .{o.component});
                continue;
            };
            reverted += 1;
        }
        self.prefabs.clearOverrides(sid);
        self.saveSidecar();

        self.log(.success, "reverted {d} component(s) of {s}", .{ reverted, inst.prefab });
        self.dirty = true;
    }

    /// Writes the sidecar to disk. A failure is logged, not fatal: the scene
    /// is still valid without it — only the ability to revert is lost.
    fn saveSidecar(self: *Editor) void {
        self.prefabs.save(self.prefab_sidecar_path[0..self.prefab_sidecar_path_len]) catch |err| {
            self.log(.warn, "prefab: cannot write the sidecar: {s}", .{@errorName(err)});
        };
    }

    // ── Autosave and hot reload ─────────────────────────────────────────────

    /// Writes the recovery copy. The write goes through a temporary name and
    /// is renamed into place: a crash halfway through leaves the PREVIOUS
    /// recovery file intact rather than a half-written one, which is the whole
    /// point of a recovery file.
    fn performAutosave(self: *Editor) void {
        if (self.autosave_path_len == 0) return;
        const bytes = ecs.zson.encodeToString(self.world(), self.allocator) catch |err| {
            self.log(.err, "autosave: encode failed: {s}", .{@errorName(err)});
            return;
        };
        defer self.allocator.free(bytes);

        const io = std.Io.Threaded.global_single_threaded.io();
        const tmp = std.fmt.allocPrint(self.allocator, "{s}.tmp", .{self.autosavePath()}) catch return;
        defer self.allocator.free(tmp);

        std.Io.Dir.cwd().writeFile(io, .{ .sub_path = tmp, .data = bytes }) catch |err| {
            self.log(.err, "autosave: cannot write: {s}", .{@errorName(err)});
            return;
        };
        std.Io.Dir.cwd().rename(tmp, std.Io.Dir.cwd(), self.autosavePath(), io) catch |err| {
            self.log(.err, "autosave: cannot rename into place: {s}", .{@errorName(err)});
            return;
        };
        self.autosave_recoverable = true;
        self.log(.info, "autosaved {d} bytes to {s}", .{ bytes.len, self.autosavePath() });
    }

    /// Loads the recovery file over the scene, or the scene file itself when
    /// there is no recovery file.
    ///
    /// One path for both, because the user's action is the same — "take what
    /// is on disk" — and the difference is only WHICH file is on disk.
    fn reloadScene(self: *Editor) void {
        // The recovery file first: it is the newer truth when there is one.
        const use_recovery = self.autosave_recoverable;
        const path = if (use_recovery) self.autosavePath() else self.scenePath();

        const io = std.Io.Threaded.global_single_threaded.io();
        const bytes = std.Io.Dir.cwd().readFileAlloc(io, path, self.allocator, .limited(8 << 20)) catch |err| {
            self.log(.err, "cannot read {s}: {s}", .{ path, @errorName(err) });
            return;
        };
        defer self.allocator.free(bytes);

        const w = self.world();
        const before = w.entityCount();
        ecs.zson.replace(w, bytes) catch |err| {
            self.log(.err, "cannot load {s}: {s}", .{ path, @errorName(err) });
            return;
        };
        self.reassertWorldInvariants();
        self.model.clearHistory();
        self.model.clearSelection();
        self.selection = null;
        self.pending_select = null;
        self.scene_replaced = true;
        self.scene_changed_on_disk = false;
        self.dirty = use_recovery; // a restored recovery is unsaved work
        self.noteSceneMtime();
        self.log(.success, "loaded {s} ({d} → {d} entities)", .{ path, before, w.entityCount() });
    }

    /// The guarantees the editor's subsystems were given at boot, re-established
    /// after a document replaced the archetypes. `openScene` and `newScene` both
    /// call this, because "the world is new" is the same event in both.
    fn reassertWorldInvariants(self: *Editor) void {
        const w = self.world();
        w.reserveEntities(10_000) catch {};
        w.reserve(.{ ecs.components.Transform, ecs.components.Sprite }, 10_000) catch {};
        w.enableHierarchy() catch {};
    }

    /// Consumed by the frame loop: a replace can invalidate every physics body.
    pub fn takeSceneReplaced(self: *Editor) bool {
        const v = self.scene_replaced;
        self.scene_replaced = false;
        return v;
    }

    // ── Play ────────────────────────────────────────────────────────────────

    pub fn simulationEnabled(self: *Editor) bool {
        return self.play == .playing;
    }

    /// One fixed step on demand, consumed exactly once. Stepping is what makes
    /// "paused" a usable state rather than a state you have to leave to see
    /// anything.
    pub fn takeStep(self: *Editor) bool {
        const v = self.step_pending;
        self.step_pending = false;
        return v;
    }

    pub fn togglePlay(self: *Editor) void {
        switch (self.play) {
            .playing => {
                self.play = .paused;
                self.log(.info, "play: paused", .{});
            },
            .paused => {
                self.play = .playing;
                self.log(.info, "play: resuming", .{});
            },
            // Stopped → playing is a TRANSACTION, not a flag: the snapshot is
            // world work (it allocates and can fail), so it is queued and
            // applied in `preFrame` — next frame, outside the allocation
            // guard — exactly like every other act.
            .stopped => self.pushAction(.begin_play),
        }
    }

    /// Step: pause, then run exactly one fixed tick on the next frame.
    pub fn step(self: *Editor) void {
        self.play = .paused;
        self.step_pending = true;
    }

    /// Stop: queued like begin, for the same reason — the restore rebuilds the
    /// world, which allocates. The play state flips HERE (the toolbar and the
    /// main loop must not step the played world after the click); the world
    /// itself is restored by `endPlay` in `preFrame`, one frame later. A queued
    /// Stop that left the state at `.playing` would keep simulating the world
    /// Stop is about to discard.
    pub fn stop(self: *Editor) void {
        if (self.play == .stopped) return;
        self.pushAction(.end_play);
        self.play = .stopped;
        self.log(.info, "play: stopped", .{});
    }

    /// The queued half of `togglePlay`: capture the world BEFORE anything moves.
    /// The snapshot is the only truth Stop restores from, and the hash taken
    /// beside it is what that restore has to reproduce — spec §6's "bit-exact
    /// serialization" consumed by the feature that needs it.
    fn beginPlay(self: *Editor) void {
        const snap = ecs.zson.encodeToString(self.world(), self.allocator) catch |err| {
            self.log(.err, "play: snapshot failed: {s}", .{@errorName(err)});
            return;
        };
        if (self.play_snapshot) |old| self.allocator.free(old);
        self.play_snapshot = snap;
        self.play_hash = ecs.zson.hash(self.world());
        self.dirty_before_play = self.dirty;
        self.selection_before_play = self.selection;
        self.play = .playing;

        // Idempotent, on purpose: actors already started are skipped. It runs
        // AFTER the snapshot, so everything a Lua `start` does (spawning,
        // rewriting) is gameplay — part of what Stop throws away, never part of
        // the world the user sat down to play.
        if (self.behaviors) |b| b.startAll();
        self.log(.info, "play: {d} entities, hash {x}", .{ self.model.entityCount(), self.play_hash });
    }

    /// The queued half of `stop`: restore the snapshot over the world that was
    /// just played. The restore runs through the SAME `zson.replace` the Open
    /// path uses — in place, so the world's address never moves and every view
    /// and subsystem keeps its cached pointer — and the guarantees the editor
    /// gave its subsystems at boot are re-asserted afterwards, which is what
    /// `reassertWorldInvariants` is for.
    ///
    /// The undo journal is cleared rather than kept: every act it holds names an
    /// entity of the played world, and undoing one of them after the restore
    /// would edit a world those entities no longer exist in. Play is an editor
    /// transaction, not document history.
    fn endPlay(self: *Editor) void {
        self.play = .stopped;
        const snap = self.play_snapshot orelse return;
        const w = self.world();
        const before = w.entityCount();
        ecs.zson.replace(w, snap) catch |err| {
            // `replace` never leaves a half-restored world. The snapshot is kept
            // so a retry (Stop again after the world is sane) is possible — but
            // the failed restore also means the state on screen is neither the
            // played one nor the edited one, and that has to be said.
            self.log(.err, "stop: restore failed ({s}); the world may be inconsistent", .{@errorName(err)});
            return;
        };

        self.reassertWorldInvariants();
        self.model.clearHistory();
        self.model.clearSelection();
        self.pending_select = null;
        self.pending_len = 0;
        // The selection comes back with the world: it is editor state, not
        // gameplay state, and the restore rebuilds the world slot-for-slot, so
        // the handles taken before Play name the same entities again.
        self.selection = null;
        if (self.selection_before_play) |e| {
            if (self.world().isAlive(e)) {
                self.model.select(e) catch {};
                self.selection = e;
            }
        }
        self.selection_before_play = null;
        self.scene_replaced = true;
        self.dirty = self.dirty_before_play;

        // The criterion, as a number. Equal means the restore is bit-exact;
        // unequal is not fatal (the world on screen IS the pre-play world by
        // construction) but something differed — order, float bits — and the
        // console is where that gets noticed before it gets trusted.
        const after_hash = ecs.zson.hash(w);
        if (after_hash == self.play_hash) {
            self.log(.success, "stop: world restored bit-exactly ({d} entities)", .{w.entityCount()});
        } else {
            self.log(.warn, "stop: world restored ({d} → {d} entities) but hash differs", .{ before, w.entityCount() });
        }
    }
};

/// The editor frame `shell.draw` publishes for the panel bodies. Set once per
/// frame; read by every function that has to be a `*const fn(*Context) void`.
pub var active: ?*Editor = null;

const testing = std.testing;

test "layer names: defaults and set" {
    var model = try Model.init(testing.allocator, ecs.World.init(testing.allocator));
    defer model.deinit();
    var ed = Editor.init(testing.allocator, &model);
    defer ed.deinit();

    try testing.expectEqualStrings("Layer 1", ed.layerName(0));
    try testing.expectEqualStrings("Layer 16", ed.layerName(15));
    ed.setLayerName(3, "enemy");
    try testing.expectEqualStrings("enemy", ed.layerName(3));
    ed.resetLayerNames();
    try testing.expectEqualStrings("Layer 4", ed.layerName(3));
}

test "describeMask: the three cases a mask can be in" {
    var model = try Model.init(testing.allocator, ecs.World.init(testing.allocator));
    defer model.deinit();
    var ed = Editor.init(testing.allocator, &model);
    defer ed.deinit();
    ed.setLayerName(0, "world");
    ed.setLayerName(1, "player");

    var buf: [128]u8 = undefined;
    try testing.expectEqualStrings("—", ed.describeMask(0, &buf));
    try testing.expectEqualStrings("everything", ed.describeMask(CollisionLayers.everything, &buf));
    const one = ed.describeMask(1 << 1, &buf);
    try testing.expectEqualStrings("player", one);
    const two = ed.describeMask((1 << 1) | 1, &buf);
    try testing.expectEqualStrings("world, player", two);
}

test "play/stop restores the world the play began from, through the editor" {
    var model = try Model.init(testing.allocator, ecs.World.init(testing.allocator));
    defer model.deinit();
    try model.world().enableHierarchy();
    var ed = Editor.init(testing.allocator, &model);
    defer ed.deinit();

    const baby = try ed.world().spawn(.{ ecs.components.Transform{ .position = .{ .x = 3, .y = -4 } } });
    _ = try ed.world().spawn(.{ ecs.components.Name.init("player") });
    ed.select(baby);
    ed.preFrame();

    // Stopped → playing is a queued act: preFrame applies it.
    ed.togglePlay();
    ed.preFrame();
    try testing.expect(ed.play == .playing);

    // The game wrecks the world: spawns, destroys, rewrites. None of it survives.
    const wrecked = try ed.world().spawn(.{ ecs.components.Name.init("boss") });
    ed.model.despawn(baby) catch unreachable;
    var q = ed.world().query(.{ecs.components.Transform});
    while (q.next()) |row| row.get(ecs.components.Transform).position.x += 100;

    // Stop the same way the toolbar does, and consume the queued restore.
    ed.stop();
    ed.preFrame();
    try testing.expect(ed.play == .stopped);
    try testing.expectEqual(@as(usize, 2), ed.world().entityCount());

    // The `boss` the game spawned is gone, and the one the user placed is back —
    // at the position and the selection Play began from, not where the game left them.
    try testing.expect(!ed.world().isAlive(wrecked));
    const restored = ed.world().get(baby, ecs.components.Transform).?;
    try testing.expectEqual(@as(f32, 3), restored.position.x);
    try testing.expectEqual(@as(f32, -4), restored.position.y);
    try testing.expectEqual(baby, ed.selection.?);

    // The journal does not survive the restore either: every act in it names an
    // entity of the played world, and Play is not document history.
    try testing.expect(!ed.model.canUndo());
}

test "play over an already-playing world, and stopping without one, are both safe" {
    var model = try Model.init(testing.allocator, ecs.World.init(testing.allocator));
    defer model.deinit();
    var ed = Editor.init(testing.allocator, &model);
    defer ed.deinit();

    // Stop while nothing was ever playing: the queued act has no snapshot and
    // logs rather than dereferencing a null.
    ed.stop();
    ed.preFrame();
    try testing.expect(ed.play == .stopped);

    // Pause → resume keeps the SAME snapshot: a paused world restored on a mere
    // pause/press cycle would be a Stop the user never asked for.
    _ = try ed.world().spawn(.{ ecs.components.Transform{} });
    ed.togglePlay();
    ed.preFrame();
    try testing.expect(ed.play == .playing);
    const hash_while_playing = ed.play_hash;
    ed.togglePlay();
    try testing.expect(ed.play == .paused);
    ed.togglePlay();
    try testing.expect(ed.play == .playing);
    try testing.expectEqual(hash_while_playing, ed.play_hash);
}

// ── Autosave ─────────────────────────────────────────────────────────────────

test "autosave fires on the interval, and only when there is work to save" {
    var model = try Model.init(testing.allocator, ecs.World.init(testing.allocator));
    defer model.deinit();
    var ed = Editor.init(testing.allocator, &model);
    defer ed.deinit();
    ed.autosave_interval_s = 10;

    // Clean document: the timer keeps resetting and nothing is queued. An
    // autosave of an unchanged scene is a file nobody asked for.
    try testing.expect(!ed.tickAutosave(5));
    try testing.expect(!ed.tickAutosave(5));
    try testing.expect(!ed.tickAutosave(5));

    // Dirty: the interval elapses and the act is queued. The interval is 10
    // seconds, so three four-second ticks reach it.
    ed.dirty = true;
    try testing.expect(!ed.tickAutosave(4));
    try testing.expect(!ed.tickAutosave(4));
    try testing.expect(ed.tickAutosave(4));

    // The timer resets, so the next one is a whole interval away.
    try testing.expect(!ed.tickAutosave(1));
}

test "an autosave of zero interval is off" {
    var model = try Model.init(testing.allocator, ecs.World.init(testing.allocator));
    defer model.deinit();
    var ed = Editor.init(testing.allocator, &model);
    defer ed.deinit();
    ed.autosave_interval_s = 0;
    ed.dirty = true;
    try testing.expect(!ed.tickAutosave(1000));
}

test "the recovery file is written atomically and reads back as the scene" {
    var model = try Model.init(testing.allocator, ecs.World.init(testing.allocator));
    defer model.deinit();
    var ed = Editor.init(testing.allocator, &model);
    defer ed.deinit();

    // A scene file to recover INTO. The editor's own scene path is used, and
    // the recovery file sits beside it.
    const scene = "samples/autosave_test_scene.zson";
    const recovery = "samples/autosave_test_scene.zson.autosave";
    const io = std.Io.Threaded.global_single_threaded.io();
    defer std.Io.Dir.cwd().deleteFile(io, scene) catch {};
    defer std.Io.Dir.cwd().deleteFile(io, recovery) catch {};

    ed.setSceneFile(scene);
    ed.rebuildRecoveryPaths();
    try testing.expectEqualStrings(recovery, ed.autosavePath());

    _ = try ed.world().spawn(.{ ecs.components.Name.init("kept") });
    ed.dirty = true;
    ed.requestAutosaveNow();
    ed.preFrame();

    // The recovery file exists and holds the scene.
    const text = std.Io.Dir.cwd().readFileAlloc(io, recovery, testing.allocator, .limited(1 << 20)) catch {
        return error.TestUnexpectedResult;
    };
    defer testing.allocator.free(text);
    try testing.expect(std.mem.indexOf(u8, text, "kept") != null);

    // And the temporary file the write went through is gone: the rename
    // consumed it. A leftover `.tmp` would be a crash's debris.
    const tmp = "samples/autosave_test_scene.zson.autosave.tmp";
    if (std.Io.Dir.cwd().statFile(io, tmp, .{})) |_| {
        return error.TestUnexpectedResult;
    } else |_| {}
}

// ── Hot reload ───────────────────────────────────────────────────────────────

test "a scene that changed on disk is reported once, and reload is the user's call" {
    var model = try Model.init(testing.allocator, ecs.World.init(testing.allocator));
    defer model.deinit();
    var ed = Editor.init(testing.allocator, &model);
    defer ed.deinit();

    try testing.expect(!ed.sceneChangedOnDisk());
    ed.notifySceneChanged();
    try testing.expect(ed.sceneChangedOnDisk());
    // The second notification does not log again: the user was told once.
    ed.notifySceneChanged();
    try testing.expect(ed.sceneChangedOnDisk());
}

// ── Prefabs ─────────────────────────────────────────────────────────────────

test "a prefab is created from the selection, with its children" {
    var model = try Model.init(testing.allocator, ecs.World.init(testing.allocator));
    defer model.deinit();
    try model.world().enableHierarchy();
    var ed = Editor.init(testing.allocator, &model);
    defer ed.deinit();

    const io = std.Io.Threaded.global_single_threaded.io();
    defer std.Io.Dir.cwd().deleteFile(io, "prefabs/turret.zson") catch {};

    const parent = try ed.world().spawn(.{ ecs.components.Name.init("turret") });
    _ = try ed.world().spawn(.{
        ecs.components.Name.init("barrel"),
        ecs.components.Parent{ .parent = parent },
    });

    ed.select(parent);
    ed.preFrame();
    ed.setPrefabName("turret");
    ed.requestCreatePrefab();
    ed.preFrame();

    // The file exists and holds both entities.
    const text = std.Io.Dir.cwd().readFileAlloc(io, "prefabs/turret.zson", testing.allocator, .limited(1 << 20)) catch {
        return error.TestUnexpectedResult;
    };
    defer testing.allocator.free(text);
    try testing.expect(std.mem.indexOf(u8, text, "turret") != null);
    try testing.expect(std.mem.indexOf(u8, text, "barrel") != null);
}

test "a prefab instance is spawned at a fresh identity and recorded" {
    var model = try Model.init(testing.allocator, ecs.World.init(testing.allocator));
    defer model.deinit();
    try model.world().enableHierarchy();
    var ed = Editor.init(testing.allocator, &model);
    defer ed.deinit();

    const io = std.Io.Threaded.global_single_threaded.io();
    defer std.Io.Dir.cwd().deleteFile(io, "prefabs/box.zson") catch {};
    // The sidecar belongs to the SCENE, so a test that uses its own scene
    // gets its own sidecar — and the tests do not tread on each other.
    const sidecar = "samples/test_prefab_box.zson.overrides";
    defer std.Io.Dir.cwd().deleteFile(io, sidecar) catch {};
    ed.setSceneFile("samples/test_prefab_box.zson");
    ed.rebuildRecoveryPaths();

    // The prefab file, written by hand — the same format the editor writes.
    const doc =
        \\zson 1
        \\entity 1 {
        \\  Name "box"
        \\  Transform { position: { x: 4, y: 5 }, rotation: 0, scale: { x: 1, y: 1 } }
        \\}
    ;
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = "prefabs/box.zson", .data = doc });

    const before = ed.world().entityCount();
    ed.requestInstantiatePrefab("prefabs/box.zson");
    ed.preFrame();

    try testing.expectEqual(before + 1, ed.world().entityCount());
    const inst = ed.world().findByName("box").?;
    try testing.expect(ed.prefabOf(inst) != null);
    // The instantiation SELECTS the new instance: it is what the user is now
    // looking at, and its properties are what the inspector shows.
    ed.preFrame();
    try testing.expect(ed.selectionIsPrefabInstance());
    try testing.expectEqual(inst, ed.selection.?);
}

test "an override is recorded when an instance's component changes" {
    var model = try Model.init(testing.allocator, ecs.World.init(testing.allocator));
    defer model.deinit();
    try model.world().enableHierarchy();
    var ed = Editor.init(testing.allocator, &model);
    defer ed.deinit();

    const io = std.Io.Threaded.global_single_threaded.io();
    defer std.Io.Dir.cwd().deleteFile(io, "prefabs/crate.zson") catch {};
    const sidecar = "samples/test_prefab_crate.zson.overrides";
    defer std.Io.Dir.cwd().deleteFile(io, sidecar) catch {};
    ed.setSceneFile("samples/test_prefab_crate.zson");
    ed.rebuildRecoveryPaths();
    const doc =
        \\zson 1
        \\entity 1 {
        \\  Name "crate"
        \\  Transform { position: { x: 1, y: 2 }, rotation: 0, scale: { x: 1, y: 1 } }
        \\}
    ;
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = "prefabs/crate.zson", .data = doc });

    ed.requestInstantiatePrefab("prefabs/crate.zson");
    ed.preFrame();
    const inst = ed.world().findByName("crate").?;
    ed.select(inst);
    ed.preFrame();

    // The sidecar knows where the instance came from, and by WHICH name the
    // prefab gave it — the name the world may have changed.
    const origin = ed.prefabOf(inst).?;
    try testing.expectEqualStrings("prefabs/crate.zson", origin.prefab);
    try testing.expectEqualStrings("crate", origin.source_name);

    // No overrides yet: the instance is exactly what the prefab says.
    const none = ed.overridesOf(inst);
    defer ed.allocator.free(none);
    try testing.expectEqual(@as(usize, 0), none.len);

    // The user moves it.
    ed.queueSet(inst, ecs.components.Transform, ecs.components.Transform{
        .position = .{ .x = 99, .y = 98 },
    });
    ed.preFrame();

    const overrides = ed.overridesOf(inst);
    defer ed.allocator.free(overrides);
    try testing.expectEqual(@as(usize, 1), overrides.len);
    try testing.expectEqualStrings("Transform", overrides[0].component);

    // And a revert puts the prefab's value back.
    ed.requestRevertPrefab();
    ed.preFrame();
    try testing.expectApproxEqAbs(
        @as(f32, 1),
        ed.world().get(inst, ecs.components.Transform).?.position.x,
        0.0001,
    );
    const after = ed.overridesOf(inst);
    defer ed.allocator.free(after);
    try testing.expectEqual(@as(usize, 0), after.len);
}