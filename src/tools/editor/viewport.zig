//! The viewport — the editor's window onto the scene.
//!
//! ## What it is, in one line
//!
//! A camera over a REGION of the editor window, an adaptive grid, click-to-
//! select in the scene itself, and the three Godot-style gizmos: drag the body
//! to move it, the arrows to move it along one axis, the ring to rotate it and
//! the corners to scale it.
//!
//! ## The region, and why the camera is not the window
//!
//! The viewport is a RECTANGLE in the middle of the editor: the hierarchy is
//! on the left, the inspector on the right, the console at the bottom, and the
//! scene is what is left over. So the camera shows the REGION, the pointer is
//! measured from the region's origin, and the scene is projected into the
//! region (`View.setTarget`).
//!
//! It used to be the whole window, and the difference was visible every
//! frame: the camera centred on the WINDOW, so the middle of the viewport was
//! off-centre, the scene sat under the docks, and a good half of what the
//! camera showed was hidden behind the hierarchy. The grid made it obvious —
//! the axes were in the middle of the WINDOW, not the middle of the viewport.
//!
//! ## The two axes
//!
//! The world is y-UP (Box2D's convention, and the renderer's: a larger world
//! y is drawn HIGHER). The screen is y-DOWN (the framebuffer's convention, and
//! the mouse's). `ecs.camera.View` is the one place that translates between
//! them, and the viewport measures the pointer in the screen's convention
//! everywhere. A viewport that mixed the two would pick the entity mirrored
//! across the middle of the window, which is exactly what it used to do.
//!
//! ## Why there is no ImGui window behind it
//!
//! The centre of the shell is deliberately window-less: any window there would
//! swallow every pointer event before scene interaction could see one. So this
//! module reads the pointer from the raw platform `Mouse` — the exact source
//! the tilemap brush already uses — and `ui.wantsMouse()` is the gate that
//! keeps the two worlds from fighting: an interaction happens only when the
//! last frame said the pointer was over empty scene, never over a dock or a
//! floating tool.
//!
//! ## Why the gizmo is drawn with ImGui and not with the 2D batcher
//!
//! The batcher's quads do not rotate: a `SpriteInstance` is a centre and two
//! half extents. A selection outline that follows the object's rotation, an
//! arrow that points along a rotated axis and a rotation ring are all
//! impossible with it. ImGui's draw list can do all three, and the BACKGROUND
//! list is drawn after the scene (the whole editor overlay is one pass over
//! the resolved frame) and before the windows — so the gizmo is over the scene
//! and under the panels, which is the layer it belongs to.
//!
//! ## Why the edits go through `queueSet` during a drag
//!
//! A long drag produces one `queueSet` per frame, which is exactly what
//! `Model.set` coalesces on the same (entity, component) key: the whole drag
//! lands as ONE undo act, and the world reflects the cursor the same frame (the
//! queue drains in `preFrame`, before the render). The `prev_*` snapshot
//! travels with the edit, so the sprite interpolator never rubber-bands an
//! edit the mouse is holding.
//!
//! ## Pick rules
//!
//! Only entities that have a `Sprite` are pickable — the sprite's scaled size
//! is the bounding box (rendering and picking can then never disagree about
//! what is under the pointer). Priority is the sprite's render layer, then its
//! stable `order`, then slot order: what you see on top is what you pick. The
//! current selection's handles beat everything else within a few pixels.

const std = @import("std");
const ui = @import("ui");
const cimgui = ui.cimgui;

const engine = @import("engine");
const platform = engine.platform;
const render2d = engine.render2d;
const ecs = engine.ecs;

const ed_mod = @import("editor_state.zig");
const Editor = ed_mod.Editor;
const Entity = ed_mod.Entity;

const Vec2 = @TypeOf(@as(ecs.components.Transform, undefined).position);

/// Which pointer behavior owns the viewport. The tile tool is the classic
/// brush (the TileMap panel's modes apply as-is); the cursor tool is the
/// scene editor: picking and gizmos.
pub const Tool = enum { cursor, tile };

/// Which gizmo the cursor tool shows. The three verbs every 2D editor has,
/// and the three keys that go with them (W, E, R).
pub const Gizmo = enum { move, rotate, scale };

/// Which part of the selection the pointer is touching.
pub const Handle = enum {
    none,
    /// The object itself: a free move.
    body,
    /// The local X arrow: a move along the object's OWN X axis.
    move_x,
    /// The local Y arrow.
    move_y,
    /// The rotation ring.
    rotate,
    /// The four scale corners, in screen order: top-left, top-right,
    /// bottom-right, bottom-left.
    scale_nw,
    scale_ne,
    scale_se,
    scale_sw,
    /// The centre handle: a uniform scale.
    scale_center,
};

const min_zoom: f32 = 0.1;
const max_zoom: f32 = 12.0;
/// Base grid pitch in world units. The DRAWN grid adapts to zoom (so lines are
/// never tighter than the minimum screen spacing below), and the MOVE SNap
/// follows the drawn cell, so what you snap to is exactly what you see.
const grid_base: f32 = 32.0;
/// A grid line is never drawn closer together than this on screen (pixels).
const grid_min_px: f32 = 24.0;
/// ...and never FURTHER apart than this, or a zoomed-in view is three lonely
/// lines instead of a grid.
const grid_max_px: f32 = 96.0;
/// Handle hit radius, in screen pixels.
const handle_hit_px: f32 = 11.0;
/// How long the move arrows are, in screen pixels.
const arrow_len: f32 = 74.0;
/// How far the rotation ring sits outside the box, in screen pixels.
const ring_pad: f32 = 20.0;
/// The rotation snap step, in radians (15°, Godot's default).
const rotate_snap: f32 = std.math.pi / 12.0;

/// The same white-slot constant the physics overlay uses, so the editor's
/// own quads share its single white page.
const debug_slot: u8 = 255;
const grid_layer: u16 = 0;

/// Grid colors. Literal, like the physics overlay's, because a gizmo color
/// is an editor decision the runtime theme has no stake in.
const col_grid_minor = [4]u8{ 128, 140, 160, 22 };
const col_grid_major = [4]u8{ 150, 165, 190, 52 };
const col_axis_x = [4]u8{ 235, 84, 84, 150 };
const col_axis_y = [4]u8{ 96, 224, 128, 150 };

/// The rectangle of the editor window the scene is drawn in.
pub const Region = struct {
    x: f32 = 0,
    y: f32 = 0,
    w: f32 = 1,
    h: f32 = 1,

    /// Is a window-space point inside the region?
    pub fn contains(self: Region, p: Vec2) bool {
        return p.x >= self.x and p.x < self.x + self.w and
            p.y >= self.y and p.y < self.y + self.h;
    }

    /// The region as a rect, for ImGui's clip and hit tests.
    pub fn rect(self: Region) ui.cimgui.Rect {
        return ui.draw.rect(self.x, self.y, self.x + self.w, self.y + self.h);
    }
};

/// The selection's geometry, in SCREEN pixels (the window's).
///
/// Everything the gizmo draws and everything the pointer hits is in this
/// space: the pointer's coordinates are window pixels, so a handle that is
/// drawn in world units would have to be converted before every comparison.
/// One conversion, here, and the rest of the module never thinks about it.
const Box = struct {
    entity: Entity,
    /// The four corners in screen space, in the order top-left, top-right,
    /// bottom-right, bottom-left.
    corners: [4]Vec2,
    /// The pivot, in screen space.
    centre: Vec2,
    /// The tips of the two move arrows, in screen space.
    x_tip: Vec2,
    y_tip: Vec2,
    /// The rotation ring's radius, in screen pixels.
    ring_radius: f32,
    /// The entity's transform, for the drags.
    position: Vec2,
    rotation: f32,
    scale: Vec2,
    /// The sprite's size in world units (before the scale).
    size: Vec2,
};

pub const Viewport = struct {
    tool: Tool = .cursor,
    /// Which gizmo the cursor tool shows.
    gizmo: Gizmo = .move,
    show_grid: bool = true,
    /// Whether a drag snaps to the grid. Ctrl holds the override, so this is
    /// the default rather than a lock.
    snap: bool = true,

    /// The camera, persistent across frames and scenes (a viewport that snaps
    /// home on every undo is not a viewport). The runtime's own shape: the
    /// same `ecs.camera.View` a project camera would produce.
    cam: ecs.camera.View = .{ .cx = 0, .cy = 0, .zoom = 1 },

    /// Where the scene is drawn, in window pixels. Set by the shell's layout,
    /// once a frame, before the pointer is read.
    region: Region = .{},

    /// What the pointer is over this frame. Recomputed every `update` — a
    /// hover is never carried state.
    hover: ?Hover = null,
    /// The edit in progress. Held across frames while the button is down.
    grabbed: Handle = .none,
    grab_entity: ?Entity = null,

    // Grab-time snapshots of the transform and pointer geometry, written once
    // at grab: a drag must not compound on its own output.
    grabbed_pos: Vec2 = .{},
    grabbed_rot: f32 = 0,
    grabbed_scale: Vec2 = .{ .x = 1, .y = 1 },
    grabbed_size: Vec2 = .{ .x = 1, .y = 1 },
    /// The world point under the pointer at the grab. Every drag is measured
    /// from it, so a drag is a DELTA and not an absolute position — which is
    /// what makes an axis-constrained move along a rotated axis work.
    grab_mouse: Vec2 = .{},
    /// The angle around the pivot at the grab (the rotation drag's zero).
    grab_angle: f32 = 0,
    /// The distance from the pivot at the grab (the uniform scale's zero).
    grab_radius: f32 = 0,
    /// Write-only flag for main: a completed drag means collider hosts moved
    /// while Box2D was not stepping them (`takeEdited` reads and clears it).
    edited_this_frame: bool = false,
    /// The world point under the pointer, for the HUD's readout.
    cursor_world: Vec2 = .{},
    /// The drag-select marquee: the box the user is dragging, in SCREEN
    /// pixels (the window's).
    ///
    /// It starts on empty space and it does NOT clear the selection when it
    /// starts: a press that turns into a drag must not have cleared the
    /// selection on the way, or a drag to select four things would have
    /// deselected first and reselected second, and the undo would show it.
    marquee_active: bool = false,
    marquee_start: Vec2 = .{},
    marquee_now: Vec2 = .{},
    /// How many objects are selected, read once a frame for the HUD. The
    /// viewport does not own the selection — the editor does — so it is a
    /// copy, refreshed where the editor is in reach.
    selected_count: usize = 0,
    /// Set when the viewport should fit the scene into the region: at boot,
    /// and after a scene is replaced. It is cleared the frame it is acted on.
    needs_frame: bool = true,
    /// Has the user moved the camera? A window resize re-frames the scene
    /// only while the camera is still where the editor put it: the moment
    /// somebody pans or zooms, the view is THEIRS and a resize leaves it
    /// alone.
    camera_touched: bool = false,
    /// The region's size last frame, so a resize is noticed.
    last_region: Vec2 = .{},

    pub const Hover = union(enum) {
        none,
        entity: Entity,
        handle: Handle,
    };

    // ── Camera helpers ───────────────────────────────────────────────────

    /// Sizes the camera to the REGION and tells it where that region sits in
    /// the render target, then returns the view the renderer consumes.
    pub fn cameraView(vp: *Viewport, fb_w: f32, fb_h: f32) ecs.camera.View {
        vp.cam.viewport_w = @max(vp.region.w, 1);
        vp.cam.viewport_h = @max(vp.region.h, 1);
        vp.cam.setTarget(vp.region.x, vp.region.y, fb_w, fb_h);
        return vp.cam;
    }

    /// Center the camera on the selection and fit it — the F key. A no-op
    /// without a selection.
    ///
    /// Fitting as well as centring is the difference between "focused on" and
    /// "a 32-pixel sprite at 400 %": the second is technically centred and
    /// practically useless.
    pub fn centerOnSelection(vp: *Viewport, ed: *Editor) void {
        const e = ed.selection orelse return;
        const t = ed.world().get(e, ecs.components.Transform) orelse return;
        vp.cam.cx = t.position.x;
        vp.cam.cy = t.position.y;
        if (ed.world().get(e, ecs.components.Sprite)) |sp| {
            const w = @max(sp.size.x * @abs(t.scale.x), 1);
            const h = @max(sp.size.y * @abs(t.scale.y), 1);
            const zoom = @min(@min(vp.region.w / (w * 4.0), vp.region.h / (h * 4.0)), 8.0);
            vp.cam.zoom = std.math.clamp(zoom, min_zoom, max_zoom);
        } else if (vp.cam.zoom < 1) {
            vp.cam.zoom = 1;
        }
        vp.hover = null;
        vp.camera_touched = true;
    }

    /// Fits everything in the scene into the region: the zoom that shows the
    /// lot, centred on the middle of it.
    ///
    /// This is what the editor opens on. A viewport that opens on the origin
    /// of a world whose content is 600 units away is a viewport that opens
    /// EMPTY, and an empty viewport reads as a broken one.
    pub fn frameAll(vp: *Viewport, ed: *Editor) void {
        const world = ed.world();
        var min_x = std.math.inf(f32);
        var min_y = std.math.inf(f32);
        var max_x = -std.math.inf(f32);
        var max_y = -std.math.inf(f32);
        var found = false;

        var slot: usize = 0;
        while (slot < world.slotCount()) : (slot += 1) {
            const e = world.entityAtSlot(slot) orelse continue;
            const t = world.get(e, ecs.components.Transform) orelse continue;
            const sp = world.get(e, ecs.components.Sprite) orelse continue;
            if (!sp.visible) continue;
            const hx = sp.size.x * 0.5 * @abs(t.scale.x);
            const hy = sp.size.y * 0.5 * @abs(t.scale.y);
            if (hx <= 0 or hy <= 0) continue;
            min_x = @min(min_x, t.position.x - hx);
            max_x = @max(max_x, t.position.x + hx);
            min_y = @min(min_y, t.position.y - hy);
            max_y = @max(max_y, t.position.y + hy);
            found = true;
        }

        if (!found) {
            vp.recenter();
            return;
        }

        const w = @max(max_x - min_x, 1);
        const h = @max(max_y - min_y, 1);
        // A margin, so the content does not touch the edge of the region: an
        // object flush against the border reads as cut off.
        const margin: f32 = 1.15;
        const zoom_x = vp.region.w / (w * margin);
        const zoom_y = vp.region.h / (h * margin);
        vp.cam.zoom = std.math.clamp(@min(zoom_x, zoom_y), min_zoom, max_zoom);
        vp.cam.cx = (min_x + max_x) * 0.5;
        vp.cam.cy = (min_y + max_y) * 0.5;
        vp.hover = null;
    }

    /// Home view: the origin, one-to-one.
    pub fn recenter(vp: *Viewport) void {
        vp.cam.cx = 0;
        vp.cam.cy = 0;
        vp.cam.zoom = 1;
        vp.hover = null;
        vp.camera_touched = true;
    }

    /// The grid pitch that IS drawn this frame — and what Move-snap follows.
    ///
    /// It adapts in BOTH directions, and the second direction is the one that
    /// matters when you zoom in: a grid whose cell is 400 pixels wide is not a
    /// grid, it is three lonely lines with very thick strokes between them.
    /// The cell halves until the lines are a comfortable distance apart, and
    /// doubles when they would be a smear.
    ///
    /// The cell is also the SNAP step, so what you snap to is exactly what you
    /// see — at any zoom.
    pub fn gridCell(vp: *const Viewport) f32 {
        var cell = grid_base;
        while (cell * vp.cam.zoom < grid_min_px) cell *= 2;
        while (cell * vp.cam.zoom > grid_max_px) cell /= 2;
        return cell;
    }

    /// The pointer in the region's own coordinates (the space the camera's
    /// screen maths speaks).
    pub fn localPoint(vp: *const Viewport, window_point: Vec2) Vec2 {
        return .{ .x = window_point.x - vp.region.x, .y = window_point.y - vp.region.y };
    }

    // ── Pointer handling (main calls this outside the frame guard) ───────

    pub fn update(
        vp: *Viewport,
        ed: *Editor,
        m: platform.Mouse,
        ui_ctx: *ui.Context,
        fb_w: u32,
        fb_h: u32,
    ) void {
        _ = vp.cameraView(
            @as(f32, @floatFromInt(fb_w)),
            @as(f32, @floatFromInt(fb_h)),
        );
        const over_ui = ui_ctx.wantsMouse();
        const mouse: Vec2 = .{ .x = m.x, .y = m.y };
        // The pointer belongs to the scene only while it is over the scene.
        // The docks are ImGui windows and `wantsMouse` covers them, but the
        // seams between them are not windows, and a click on a seam must not
        // pick whatever happens to be behind it.
        const in_region = vp.region.contains(mouse);
        const local = vp.localPoint(mouse);
        vp.cursor_world = vp.cam.targetToWorld(mouse);
        vp.selected_count = ed.selectedCount();

        // The first frame with a known region — and every frame after a scene
        // is replaced — fits the content into the view. An editor that opens
        // on the origin of a world whose content is elsewhere opens EMPTY.
        //
        // A RESIZE re-frames too, while the camera is still the editor's:
        // the compositor resizes the window right after it opens, and a
        // framing computed for the old size is a framing for a window that
        // is not there any more.
        const region_size = Vec2{ .x = vp.region.w, .y = vp.region.h };
        if (region_size.x != vp.last_region.x or region_size.y != vp.last_region.y) {
            vp.last_region = region_size;
            if (!vp.camera_touched) vp.needs_frame = true;
        }
        if (vp.needs_frame) {
            vp.needs_frame = false;
            vp.frameAll(ed);
        }

        // Wheel zoom: multiplicative (so the same wheel travel feels the same
        // at any depth), anchored at the cursor (the world point under it
        // stays under it), and it only plays over the scene.
        if (!over_ui and in_region and m.wheel_y != 0) {
            const anchor = vp.cursor_world;
            vp.cam.zoom *= std.math.pow(f32, 2, m.wheel_y * 0.25);
            vp.cam.zoom = std.math.clamp(vp.cam.zoom, min_zoom, max_zoom);
            // The anchor must still be under the cursor at the new zoom: the
            // camera's centre moves by exactly what the zoom took away.
            const half = vp.cam.halfExtents();
            vp.cam.cx = anchor.x + half.x - local.x / vp.cam.zoom;
            vp.cam.cy = anchor.y - half.y + local.y / vp.cam.zoom;
            vp.camera_touched = true;
        }

        // Pan: middle-button drag. Free in both tools, over everything — the
        // one gesture that always means "move my window onto the world".
        if (!over_ui and in_region and m.buttons[2]) {
            vp.cam.cx -= m.dx / vp.cam.zoom;
            // The screen's y grows DOWN and the world's grows UP, so a drag
            // downwards moves the camera UP.
            vp.cam.cy += m.dy / vp.cam.zoom;
            vp.camera_touched = true;
        }

        if (vp.tool == .cursor and !over_ui and in_region) {
            const mouse_w = vp.cursor_world;
            if (vp.grabbed == .none and !vp.marquee_active) vp.refreshHover(ed, mouse, mouse_w);

            if (m.justPressed(0)) vp.beginGrab(ed, mouse, mouse_w, m.ctrl);
            if (m.buttons[0] and vp.grabbed != .none) {
                vp.dragTo(ed, mouse_w, m.ctrl, m.shift);
            } else if (!m.buttons[0]) {
                vp.releaseGrab();
            }
        } else {
            // The pointer belongs to UI or to the tile tool — but a drag that
            // started in the scene keeps following the pointer. Cutting a
            // drag off because the cursor grazed a dock is how gizmos lose
            // the user's trust.
            if (vp.grabbed != .none) {
                if (m.buttons[0]) {
                    vp.dragTo(ed, vp.cursor_world, m.ctrl, m.shift);
                } else {
                    vp.releaseGrab();
                }
            } else {
                vp.hover = null;
            }
        }

        // The marquee follows the pointer wherever it goes, and it ends on
        // the release — not on the press, because a press that turns into a
        // drag must not clear the selection on the way.
        if (vp.marquee_active) {
            vp.marquee_now = mouse;
            if (!m.buttons[0]) vp.finishMarquee(ed);
        }
    }

    /// The pointer belongs to this viewport's edit this frame? Set by
    /// `dragTo` and consumed by main (once) — a completed drag means collider
    /// hosts moved while Box2D was not stepping, and the overlay must follow.
    /// One-shot: returns and clears the edited flag. Readonly, no allocation.
    pub fn takeEdited(vp: *Viewport) bool {
        const v = vp.edited_this_frame;
        vp.edited_this_frame = false;
        return v;
    }

    // ── Pointer handling (main calls this outside the frame guard) ───────

    fn releaseGrab(vp: *Viewport) void {
        vp.grabbed = .none;
        vp.grab_entity = null;
    }

    fn refreshHover(vp: *Viewport, ed: *Editor, mouse: Vec2, mouse_w: Vec2) void {
        vp.hover = .none;

        // Handles of the current selection beat any entity: they are drawn on
        // top of it, so they must win the pick that way too.
        if (ed.selection) |sel| {
            if (ed.world().isAlive(sel)) {
                if (vp.hitHandle(ed, sel, mouse)) |h| {
                    vp.hover = .{ .handle = h };
                    return;
                }
            }
        }

        if (pickEntity(ed.world(), mouse_w)) |e| vp.hover = .{ .entity = e };
    }

    fn beginGrab(vp: *Viewport, ed: *Editor, mouse: Vec2, mouse_w: Vec2, ctrl: bool) void {
        const h = vp.hover orelse return;
        switch (h) {
            .none => {
                // Empty space starts a MARQUEE. The selection is cleared when
                // the drag ends without having caught anything — a click that
                // turns into a drag must not have cleared the selection on
                // the way.
                vp.marquee_active = true;
                vp.marquee_start = mouse;
                vp.marquee_now = mouse;
            },
            .entity => |e| {
                if (!ed.world().isAlive(e)) return;
                const t = ed.world().get(e, ecs.components.Transform) orelse return;
                // Ctrl+click ADDS to the selection and does not start a drag:
                // the second Ctrl+click of a multi-select is a selection, not
                // the beginning of a move.
                if (ctrl) {
                    ed.selectAdd(e);
                    return;
                }
                ed.select(e);
                // Dragging the object itself MOVES it, but only when the
                // gizmo says so: in the rotate and scale modes a drag on the
                // body does nothing, exactly as it does in Godot.
                if (vp.gizmo == .move) {
                    vp.grabbed = .body;
                    vp.grab_entity = e;
                    vp.snapshot(ed, e, t, mouse_w);
                }
            },
            .handle => |handle| {
                const sel = ed.selection orelse return;
                const t = ed.world().get(sel, ecs.components.Transform) orelse return;
                vp.grabbed = handle;
                vp.grab_entity = sel;
                vp.snapshot(ed, sel, t, mouse_w);
            },
        }
    }

    /// The marquee ends: the entities it caught become the selection.
    fn finishMarquee(vp: *Viewport, ed: *Editor) void {
        vp.marquee_active = false;
        const w = @abs(vp.marquee_now.x - vp.marquee_start.x);
        const h = @abs(vp.marquee_now.y - vp.marquee_start.y);
        if (w < 4 and h < 4) {
            // A click, not a drag: it clears the selection.
            ed.clearSelection();
            return;
        }

        // The box in world units. The pointer's two corners are enough: the
        // camera is uniform, so a screen rectangle is a world rectangle.
        const a = vp.cam.targetToWorld(vp.marquee_start);
        const b = vp.cam.targetToWorld(vp.marquee_now);
        const min_x = @min(a.x, b.x);
        const max_x = @max(a.x, b.x);
        const min_y = @min(a.y, b.y);
        const max_y = @max(a.y, b.y);

        const world = ed.world();
        const count = entitiesInRect(
            world,
            min_x,
            max_x,
            min_y,
            max_y,
            ed.marquee[0..],
        );

        ed.marquee_len = count;
        ed.marquee_pending = true;
        // The CURRENT object is the first one caught, so the inspector has
        // something to bind to the moment the box is released.
        if (count > 0) {
            ed.selection = ed.marquee[0];
        } else {
            ed.clearSelection();
        }
    }

    fn snapshot(vp: *Viewport, ed: *Editor, e: Entity, t: *const ecs.components.Transform, mouse_w: Vec2) void {
        vp.grab_entity = e;
        vp.grabbed_pos = t.position;
        vp.grabbed_rot = t.rotation;
        vp.grabbed_scale = t.scale;
        vp.grab_mouse = mouse_w;
        // The sprite's size is what scale multiplies. A selection without one
        // (picked in an earlier frame, sprite removed since) still moves.
        const sp = ed.world().get(e, ecs.components.Sprite);
        vp.grabbed_size = if (sp) |s| s.size else .{ .x = 1, .y = 1 };
        // The angle and the radius at the grab: the rotation and the uniform
        // scale are both measured from here, so the handle does not jump when
        // the drag starts.
        const rel = mouse_w.sub(t.position);
        vp.grab_angle = std.math.atan2(rel.y, rel.x);
        vp.grab_radius = @sqrt(rel.x * rel.x + rel.y * rel.y);
    }

    fn dragTo(vp: *Viewport, ed: *Editor, mouse_w: Vec2, ctrl: bool, shift: bool) void {
        const e = vp.grab_entity orelse return;
        const world = ed.world();
        if (!world.isAlive(e)) {
            vp.releaseGrab();
            return;
        }
        var t = world.get(e, ecs.components.Transform) orelse {
            vp.releaseGrab();
            return;
        };

        const snap = ctrl and vp.snap;

        switch (vp.grabbed) {
            .none => {},
            .body => {
                // A free move: the delta from the grab, so the object keeps
                // the point of itself that was clicked.
                const delta = mouse_w.sub(vp.grab_mouse);
                var pos = vp.grabbed_pos.add(delta);
                if (snap) pos = vp.snapToGrid(pos);
                t.position = pos;
            },
            .move_x, .move_y => {
                // The drag follows the object's OWN axis, so a rotated object
                // moves along the arrow the user is holding.
                const axis = if (vp.grabbed == .move_x)
                    Vec2{ .x = @cos(vp.grabbed_rot), .y = @sin(vp.grabbed_rot) }
                else
                    Vec2{ .x = -@sin(vp.grabbed_rot), .y = @cos(vp.grabbed_rot) };
                const delta = mouse_w.sub(vp.grab_mouse);
                const along = delta.x * axis.x + delta.y * axis.y;
                var pos = vp.grabbed_pos.add(axis.scale(along));
                if (snap) pos = vp.snapToGrid(pos);
                t.position = pos;
            },
            .rotate => {
                // The handle rides the pointer's angle around the pivot. The
                // angle at the grab is the zero, so the rotation is a DELTA
                // and the object does not snap to a hard angle when the drag
                // starts.
                const rel = mouse_w.sub(vp.grabbed_pos);
                const a = std.math.atan2(rel.y, rel.x);
                var rot = vp.grabbed_rot + wrapPi(a - vp.grab_angle);
                if (snap) rot = @round(rot / rotate_snap) * rotate_snap;
                t.rotation = rot;
            },
            .scale_nw, .scale_ne, .scale_se, .scale_sw => {
                // The pointer in the object's LOCAL frame (rotation removed):
                // scale multiplies the sprite's size along each axis, so the
                // pointer's offset along those axes IS the new scale.
                const rel = mouse_w.sub(vp.grabbed_pos);
                const c = @cos(vp.grabbed_rot);
                const s = @sin(vp.grabbed_rot);
                const local: Vec2 = .{
                    .x = rel.x * c + rel.y * s,
                    .y = -rel.x * s + rel.y * c,
                };
                // The corner's own sign: the top-right corner is at +x, +y in
                // the local frame (which is y-up), so dragging it right and up
                // grows both axes.
                const sign: Vec2 = switch (vp.grabbed) {
                    .scale_nw => .{ .x = -1, .y = 1 },
                    .scale_ne => .{ .x = 1, .y = 1 },
                    .scale_se => .{ .x = 1, .y = -1 },
                    .scale_sw => .{ .x = -1, .y = -1 },
                    else => .{ .x = 1, .y = 1 },
                };
                const hx = @max(vp.grabbed_size.x * 0.5, 0.0001);
                const hy = @max(vp.grabbed_size.y * 0.5, 0.0001);
                var sx = (local.x * sign.x) / hx;
                var sy = (local.y * sign.y) / hy;
                if (shift) {
                    // Uniform: the larger of the two wins, and the other
                    // follows it.
                    const m = @max(@abs(sx), @abs(sy));
                    sx = if (sx < 0) -m else m;
                    sy = if (sy < 0) -m else m;
                }
                if (snap) {
                    sx = @round(sx * 10.0) / 10.0;
                    sy = @round(sy * 10.0) / 10.0;
                }
                t.scale.x = clampScale(sx);
                t.scale.y = clampScale(sy);
            },
            .scale_center => {
                // Uniform: the ratio of the distances from the pivot.
                const rel = mouse_w.sub(vp.grabbed_pos);
                const d = @sqrt(rel.x * rel.x + rel.y * rel.y);
                const ratio = if (vp.grab_radius > 0.0001) d / vp.grab_radius else 1.0;
                var s = vp.grabbed_scale;
                s.x = clampScale(s.x * ratio);
                s.y = clampScale(s.y * ratio);
                if (snap) {
                    s.x = @round(s.x * 10.0) / 10.0;
                    s.y = @round(s.y * 10.0) / 10.0;
                }
                t.scale = s;
            },
        }

        // One undo act per drag (Model.set coalesces the key) — and the
        // interpolator's previous snapshot travels with it, so nothing
        // rubber-bands while the mouse holds the object.
        t.prev_position = t.position;
        t.prev_rotation = t.rotation;
        t.prev_scale = t.scale;
        ed.queueSet(e, ecs.components.Transform, t.*);
        vp.edited_this_frame = true;
    }

    /// The grid cell a position snaps to. The cell that is DRAWN, so what you
    /// snap to is exactly what you see.
    fn snapToGrid(vp: *const Viewport, p: Vec2) Vec2 {
        const cell = vp.gridCell();
        return .{
            .x = @round(p.x / cell) * cell,
            .y = @round(p.y / cell) * cell,
        };
    }

    // ── Handle geometry (hit-testing and drawing share it) ───────────────

    /// The selection's geometry in screen pixels, or null when it has no
    /// sprite (a selection without one still moves, but there is no box to
    /// draw and no corners to hit).
    fn selectionBox(vp: *Viewport, ed: *Editor, sel: Entity) ?Box {
        const t = ed.world().get(sel, ecs.components.Transform) orelse return null;
        const sp = ed.world().get(sel, ecs.components.Sprite) orelse return null;
        const hx = sp.size.x * 0.5 * @abs(t.scale.x);
        const hy = sp.size.y * 0.5 * @abs(t.scale.y);

        // The local corners, in the object's frame (y up): the top-left is at
        // (-x, +y).
        const local = [_]Vec2{
            .{ .x = -hx, .y = hy },
            .{ .x = hx, .y = hy },
            .{ .x = hx, .y = -hy },
            .{ .x = -hx, .y = -hy },
        };
        const c = @cos(t.rotation);
        const s = @sin(t.rotation);
        var corners: [4]Vec2 = undefined;
        for (local, 0..) |l, i| {
            const world = Vec2{
                .x = t.position.x + l.x * c - l.y * s,
                .y = t.position.y + l.x * s + l.y * c,
            };
            corners[i] = vp.cam.worldToTarget(world);
        }

        const centre = vp.cam.worldToTarget(t.position);
        // The arrows point along the object's own axes. The screen's y grows
        // down, so a world direction (x, y) is a screen direction (x, -y).
        const x_dir = Vec2{ .x = c, .y = -s };
        const y_dir = Vec2{ .x = -s, .y = -c };
        const half_screen_x = hx * vp.cam.zoom;
        const half_screen_y = hy * vp.cam.zoom;

        return .{
            .entity = sel,
            .corners = corners,
            .centre = centre,
            .x_tip = centre.add(x_dir.scale(half_screen_x + arrow_len)),
            .y_tip = centre.add(y_dir.scale(half_screen_y + arrow_len)),
            .ring_radius = @max(half_screen_x, half_screen_y) + ring_pad,
            .position = t.position,
            .rotation = t.rotation,
            .scale = t.scale,
            .size = sp.size,
        };
    }

    /// Which handle, if any, is under the pointer.
    fn hitHandle(vp: *Viewport, ed: *Editor, sel: Entity, mouse: Vec2) ?Handle {
        const box = vp.selectionBox(ed, sel) orelse return null;
        return switch (vp.gizmo) {
            .move => vp.hitMoveHandle(box, mouse),
            .rotate => vp.hitRotateHandle(box, mouse),
            .scale => vp.hitScaleHandle(box, mouse),
        };
    }

    fn hitMoveHandle(vp: *Viewport, box: Box, mouse: Vec2) ?Handle {
        _ = vp;
        // The arrows first: they are drawn on top of the box.
        if (near(box.x_tip, mouse, handle_hit_px)) return .move_x;
        if (near(box.y_tip, mouse, handle_hit_px)) return .move_y;
        if (pointInBox(box, mouse)) return .body;
        return null;
    }

    fn hitRotateHandle(vp: *Viewport, box: Box, mouse: Vec2) ?Handle {
        _ = vp;
        const d = distance(mouse, box.centre);
        if (@abs(d - box.ring_radius) <= handle_hit_px) return .rotate;
        return null;
    }

    fn hitScaleHandle(vp: *Viewport, box: Box, mouse: Vec2) ?Handle {
        _ = vp;
        if (near(box.corners[0], mouse, handle_hit_px)) return .scale_nw;
        if (near(box.corners[1], mouse, handle_hit_px)) return .scale_ne;
        if (near(box.corners[2], mouse, handle_hit_px)) return .scale_se;
        if (near(box.corners[3], mouse, handle_hit_px)) return .scale_sw;
        if (near(box.centre, mouse, handle_hit_px)) return .scale_center;
        return null;
    }

    // ── Drawing ──────────────────────────────────────────────────────────

    /// The grid: pushed BEFORE the sprites, on layer 0, and the batcher's
    /// stable counting sort keeps insertion order inside a layer — so the
    /// grid is under every entity of its layer, every time, with no second
    /// draw pass to pay for.
    pub fn pushUnderlay(vp: *Viewport, r2d: *render2d.Renderer2D) void {
        if (!vp.show_grid) return;

        const bounds = vp.cam.worldBounds();
        const cell = vp.gridCell();
        const zoom = vp.cam.zoom;

        // A one-screen-pixel-thick line, which means its world thickness must
        // follow the zoom.
        const thin = 1.0 / zoom;
        var quads: usize = 0;
        const cap: usize = 1024; // hard cap; a 4K screen at min zoom fits under it

        // A major line every 4 minors — 128 world units at the base pitch.
        const major_every = 4.0 * cell;

        // The world's y grows UP, so the TOP of the screen is the world's
        // LARGEST y. The grid starts there and walks down.
        var gx = @floor(bounds.min.x / cell) * cell;
        while (gx <= bounds.max.x) : (gx += cell) {
            if (quads >= cap) break;
            if (!isOriginLine(gx, thin)) {
                const major = @abs(@rem(gx, major_every)) < thin;
                _ = r2d.pushInstance(.{
                    .pos = .{ gx, vp.cam.cy },
                    .half = .{ thin, vp.cam.viewport_h / zoom },
                    .uv = .{ 0, 0, std.math.maxInt(u16), std.math.maxInt(u16) },
                    .color = if (major) col_grid_major else col_grid_minor,
                    .slot = debug_slot,
                    .shape = 0,
                    .layer = grid_layer,
                });
                quads += 1;
            }
        }

        var gy = @floor(bounds.max.y / cell) * cell;
        while (gy >= bounds.min.y) : (gy -= cell) {
            if (quads >= cap) break;
            if (!isOriginLine(gy, thin)) {
                const major = @abs(@rem(gy, major_every)) < thin;
                _ = r2d.pushInstance(.{
                    .pos = .{ vp.cam.cx, gy },
                    .half = .{ vp.cam.viewport_w / zoom, thin },
                    .uv = .{ 0, 0, std.math.maxInt(u16), std.math.maxInt(u16) },
                    .color = if (major) col_grid_major else col_grid_minor,
                    .slot = debug_slot,
                    .shape = 0,
                    .layer = grid_layer,
                });
                quads += 1;
            }
        }

        // World axes through the origin, in the two colors Godot taught
        // everyone to read: red across (X), green down (Y).
        //
        // One pixel wide, like every other line: an axis that is thicker
        // than the grid it belongs to reads as a bug, not as an emphasis.
        _ = r2d.pushInstance(.{
            .pos = .{ vp.cam.cx, 0 },
            .half = .{ vp.cam.viewport_w / zoom, thin },
            .uv = .{ 0, 0, std.math.maxInt(u16), std.math.maxInt(u16) },
            .color = col_axis_x,
            .slot = debug_slot,
            .shape = 0,
            .layer = grid_layer,
        });
        _ = r2d.pushInstance(.{
            .pos = .{ 0, vp.cam.cy },
            .half = .{ thin, vp.cam.viewport_h / zoom },
            .uv = .{ 0, 0, std.math.maxInt(u16), std.math.maxInt(u16) },
            .color = col_axis_y,
            .slot = debug_slot,
            .shape = 0,
            .layer = grid_layer,
        });
    }

    /// The gizmo, the selection box and the hover ghost.
    ///
    /// Drawn on ImGui's BACKGROUND list and clipped to the region: over the
    /// scene (the overlay pass runs after the scene is resolved) and under the
    /// panels (the background list is drawn before the windows).
    pub fn drawOverlay(vp: *Viewport, ed: *Editor, ctx: *ui.Context) void {
        const list = ui.draw.backgroundList();
        list.pushClip(vp.region.rect(), true);
        defer list.popClip();

        const t = &ctx.theme;

        // An entity the pointer is over but has not picked: a ghost outline.
        if (vp.hover) |h| switch (h) {
            .entity => |e| {
                var ghost = true;
                if (ed.selection) |sel| {
                    if (sel.index == e.index and sel.generation == e.generation) ghost = false;
                }
                if (ghost) {
                    if (vp.selectionBox(ed, e)) |box| {
                        drawBoxOutline(list, box, t.colors.accent.withAlpha(0.45), 1.0);
                    }
                }
            },
            else => {},
        };

        const sel = ed.selection orelse return;
        if (!ed.world().isAlive(sel)) return;
        const box = vp.selectionBox(ed, sel) orelse return;

        // The selection's own box, above everything it edits.
        drawBoxOutline(list, box, t.colors.accent, 1.5);

        // The gizmo belongs to the cursor tool (the tile tool does not edit
        // entities). It shows while a simulation runs, too: Godot edits live,
        // and a running behavior fighting a drag is a fair fight.
        if (vp.tool != .cursor) return;

        switch (vp.gizmo) {
            .move => vp.drawMoveGizmo(list, box, t),
            .rotate => vp.drawRotateGizmo(list, box, t),
            .scale => vp.drawScaleGizmo(list, box, t),
        }
    }

    /// The drag-select marquee: the box the user is dragging.
    ///
    /// It is drawn on the same list as the gizmo and under the same clip, and
    /// it is the one piece of the viewport that is drawn while the pointer is
    /// DOWN — the selection it will produce does not exist yet.
    pub fn drawMarquee(vp: *Viewport, ctx: *ui.Context) void {
        if (!vp.marquee_active) return;
        const list = ui.draw.backgroundList();
        list.pushClip(vp.region.rect(), true);
        defer list.popClip();

        const r = ui.draw.rect(
            @min(vp.marquee_start.x, vp.marquee_now.x),
            @min(vp.marquee_start.y, vp.marquee_now.y),
            @max(vp.marquee_start.x, vp.marquee_now.x),
            @max(vp.marquee_start.y, vp.marquee_now.y),
        );
        const col = ctx.theme.colors.accent;
        list.rect(r, col.withAlpha(0.12), 0);
        list.rectOutline(r, col, 0, 1.0);
    }

    fn drawMoveGizmo(vp: *Viewport, list: ui.draw.List, box: Box, t: *const ui.Theme) void {
        const hot_x = vp.grabbed == .move_x or hoverHandle(vp.hover, .move_x);
        const hot_y = vp.grabbed == .move_y or hoverHandle(vp.hover, .move_y);

        // The pivot: a small disc where the object's origin is.
        list.circle(drawVec(box.centre), 3.5, t.colors.accent);

        drawArrow(list, box.centre, box.x_tip, axisColor(t, true, hot_x));
        drawArrow(list, box.centre, box.y_tip, axisColor(t, false, hot_y));
    }

    fn drawRotateGizmo(vp: *Viewport, list: ui.draw.List, box: Box, t: *const ui.Theme) void {
        const hot = vp.grabbed == .rotate or hoverHandle(vp.hover, .rotate);
        const col = if (hot) t.colors.accent_hover else t.colors.accent;
        list.circleOutline(drawVec(box.centre), box.ring_radius, col.withAlpha(0.75), 1.5);

        // The knob: where the pointer was at the grab, or at the top when
        // nothing is being dragged. It is the handle, so it is where the
        // user expects to grab it.
        const angle = if (vp.grabbed == .rotate) vp.grab_angle else std.math.pi * 0.5;
        const knob = Vec2{
            .x = box.centre.x + @cos(angle) * box.ring_radius,
            .y = box.centre.y - @sin(angle) * box.ring_radius,
        };
        list.circle(drawVec(knob), if (hot) 6.0 else 5.0, col);
    }

    fn drawScaleGizmo(vp: *Viewport, list: ui.draw.List, box: Box, t: *const ui.Theme) void {
        // Each corner lights up on its own: a handle that highlights when the
        // pointer is over a DIFFERENT handle tells the user nothing about
        // which one they are about to grab.
        const corners = [_]Handle{ .scale_nw, .scale_ne, .scale_se, .scale_sw };
        for (box.corners, 0..) |corner, i| {
            const hot = vp.grabbed == corners[i] or hoverHandle(vp.hover, corners[i]);
            const col = if (hot) t.colors.accent_hover else t.colors.accent;
            const r = ui.draw.rect(corner.x - 5, corner.y - 5, corner.x + 5, corner.y + 5);
            list.rect(r, t.colors.surface, 1);
            list.rectOutline(r, col, 1, 1.5);
        }
        // The centre handle: the uniform scale. It is the one the user is
        // most likely to want, so it is the one that reads clearest.
        const centre_hot = vp.grabbed == .scale_center or hoverHandle(vp.hover, .scale_center);
        const ccol = if (centre_hot) t.colors.accent_hover else t.colors.accent;
        const c = ui.draw.rect(box.centre.x - 4.5, box.centre.y - 4.5, box.centre.x + 4.5, box.centre.y + 4.5);
        list.rect(c, t.colors.surface, 1);
        list.rectOutline(c, ccol, 1, 1.5);
    }

    // ── The HUD ──────────────────────────────────────────────────────────

    var drawing_vp: ?*Viewport = null;

    /// The strip along the top-left of the viewport: the tools, the gizmo
    /// modes, the toggles and the readouts.
    ///
    /// It lives INSIDE the region, so it never covers a dock — the old pill
    /// floated over the inspector, which is where a tool has no business
    /// being. It is a real ImGui window (its buttons are real buttons), which
    /// means it takes the pointer over itself and the scene does not see the
    /// clicks there. That is the point of a HUD.
    ///
    /// It is ONE ROW, horizontally: a toolbar that stacks its controls in
    /// three lines is a panel wearing a toolbar's clothes, and it covers a
    /// third of a small viewport. The row is wide — the icons (see
    /// `assets/icons/README.md`) will make it narrow — but it is wide in a
    /// way that reads as a toolbar.
    pub fn drawHud(vp: *Viewport, ctx: *ui.Context) void {
        drawing_vp = vp;
        defer drawing_vp = null;
        cimgui.ember_ui_set_next_window_bg_alpha(0.88);
        ui.layout.floating(ctx, "ViewportHud", .{
            .x = vp.region.x + 10,
            .y = vp.region.y + 10,
            .w = 0,
            .h = 0,
            .resizable = false,
            // The HUD is PINNED: it belongs to the region, it cannot be
            // dragged away, and the region moves when the layout does. So its
            // position is applied every frame, not remembered from the first
            // use — a remembered position is a HUD that stays where the layout
            // used to be.
            .fixed = true,
            .flags = cimgui.WindowFlags.NoTitleBar |
                cimgui.WindowFlags.NoResize |
                cimgui.WindowFlags.NoCollapse |
                cimgui.WindowFlags.NoMove |
                cimgui.WindowFlags.NoScrollbar |
                cimgui.WindowFlags.NoScrollWithMouse |
                cimgui.WindowFlags.NoSavedSettings,
        }, hudBody);
    }

    fn hudBody(ctx: *ui.Context) void {
        const vp = drawing_vp orelse return;

        // ── The tools ────────────────────────────────────────────────────
        if (ui.button.render(.{
            .ctx = ctx,
            .id = "tool.cursor",
            .text = "Cursor",
            .variant = if (vp.tool == .cursor) .primary else .ghost,
            .tooltip = "Q — pick entities in the scene",
        })) vp.tool = .cursor;
        cimgui.ember_ui_same_line(0, 4);
        if (ui.button.render(.{
            .ctx = ctx,
            .id = "tool.tile",
            .text = "Tiles",
            .variant = if (vp.tool == .tile) .primary else .ghost,
            .tooltip = "T — the TileMap brush owns left-click",
        })) vp.tool = .tile;

        cimgui.ember_ui_same_line(0, 10);

        // ── The gizmo modes ──────────────────────────────────────────────
        if (ui.button.render(.{
            .ctx = ctx,
            .id = "gizmo.move",
            .text = "Move",
            .variant = if (vp.gizmo == .move) .primary else .ghost,
            .tooltip = "W — drag the object, or an arrow to move along one axis",
        })) vp.gizmo = .move;
        cimgui.ember_ui_same_line(0, 4);
        if (ui.button.render(.{
            .ctx = ctx,
            .id = "gizmo.rotate",
            .text = "Rotate",
            .variant = if (vp.gizmo == .rotate) .primary else .ghost,
            .tooltip = "E — drag the ring to rotate",
        })) vp.gizmo = .rotate;
        cimgui.ember_ui_same_line(0, 4);
        if (ui.button.render(.{
            .ctx = ctx,
            .id = "gizmo.scale",
            .text = "Scale",
            .variant = if (vp.gizmo == .scale) .primary else .ghost,
            .tooltip = "R — drag a corner to scale, the middle for uniform",
        })) vp.gizmo = .scale;

        cimgui.ember_ui_same_line(0, 10);

        // ── The toggles ─────────────────────────────────────────────────
        if (ui.button.render(.{
            .ctx = ctx,
            .id = "vp.grid",
            .text = "Grid",
            .variant = if (vp.show_grid) .primary else .ghost,
            .tooltip = "the adaptive grid",
        })) vp.show_grid = !vp.show_grid;
        cimgui.ember_ui_same_line(0, 4);
        if (ui.button.render(.{
            .ctx = ctx,
            .id = "vp.snap",
            .text = "Snap",
            .variant = if (vp.snap) .primary else .ghost,
            .tooltip = "Ctrl while dragging snaps to the grid",
        })) vp.snap = !vp.snap;

    }

    /// The readouts, in the region's bottom-left corner: the zoom, the
    /// pointer's world position and how much is selected.
    ///
    /// They are NOT in the toolbar. A toolbar is for controls, and a toolbar
    /// with a number on the end of it is a toolbar that is too wide to be a
    /// toolbar — the readouts are the first thing to move when the row runs
    /// out of room, and they read better in a corner anyway.
    pub fn drawReadout(vp: *Viewport, ctx: *ui.Context) void {
        const list = ui.draw.backgroundList();
        list.pushClip(vp.region.rect(), true);
        defer list.popClip();

        const t = &ctx.theme;
        var buf: [128]u8 = undefined;
        var w = std.Io.Writer.fixed(&buf);
        w.print("{d:.0}%   {d:.0}, {d:.0}", .{
            vp.cam.zoom * 100,
            vp.cursor_world.x,
            vp.cursor_world.y,
        }) catch {};
        if (vp.selected_count > 1) {
            w.print("   ·   {d} selected", .{vp.selected_count}) catch {};
        }

        // The corner: the region's bottom-left, one line's padding up.
        const size = ui.draw.textSize(buf[0..w.end]);
        const x = vp.region.x + 12;
        const y = vp.region.y + vp.region.h - size.y - 10;
        list.text(.{ .x = x, .y = y }, t.colors.text_dim, buf[0..w.end]);
    }
};

// ── Module helpers ───────────────────────────────────────────────────────────

/// ImGui's draw list speaks its own `Vec2`, and the engine's math type is a
/// different struct with the same two fields. One conversion, here, so no
/// call site has to remember which one it is holding.
fn drawVec(v: Vec2) ui.cimgui.Vec2 {
    return .{ .x = v.x, .y = v.y };
}

/// The X and Y axis colors: red and green, the two everyone already reads.
fn axisColor(t: *const ui.Theme, x_axis: bool, hot: bool) ui.Rgba {
    const base = if (x_axis) t.colors.danger else t.colors.success;
    return if (hot) base.lerp(ui.Rgba.of(1, 1, 1, 1), 0.35) else base;
}

fn drawBoxOutline(list: ui.draw.List, box: Box, col: ui.Rgba, thickness: f32) void {
    // A translucent fill plus a border: the fill says "this is the object",
    // the border says "this is the selection".
    list.pathReset();
    for (box.corners) |c| list.pathLine(drawVec(c));
    list.pathFill(col.withAlpha(col.a * 0.12));
    list.pathReset();
    for (box.corners) |c| list.pathLine(drawVec(c));
    list.pathStroke(col, thickness, true);
}

fn drawArrow(list: ui.draw.List, from: Vec2, tip: Vec2, col: ui.Rgba) void {
    const dx = tip.x - from.x;
    const dy = tip.y - from.y;
    const len = @sqrt(dx * dx + dy * dy);
    if (len < 0.001) return;
    const dir = Vec2{ .x = dx / len, .y = dy / len };
    const perp = Vec2{ .x = -dir.y, .y = dir.x };
    const head: f32 = 9.0;

    list.line(drawVec(from), drawVec(tip), col, 2.0);
    list.pathReset();
    list.pathLine(drawVec(tip));
    list.pathLine(drawVec(Vec2{
        .x = tip.x - dir.x * head + perp.x * head * 0.55,
        .y = tip.y - dir.y * head + perp.y * head * 0.55,
    }));
    list.pathLine(drawVec(Vec2{
        .x = tip.x - dir.x * head - perp.x * head * 0.55,
        .y = tip.y - dir.y * head - perp.y * head * 0.55,
    }));
    list.pathFill(col);
}

fn near(a: Vec2, b: Vec2, px: f32) bool {
    const dx = a.x - b.x;
    const dy = a.y - b.y;
    return dx * dx + dy * dy <= px * px;
}

fn distance(a: Vec2, b: Vec2) f32 {
    const dx = a.x - b.x;
    const dy = a.y - b.y;
    return @sqrt(dx * dx + dy * dy);
}

/// Is the point inside the selection's (possibly rotated) box?
fn pointInBox(box: Box, p: Vec2) bool {
    // The corners are in screen space and the box is a parallelogram, so the
    // test is done in the box's own frame: the vectors from the top-left
    // corner to the top-right and to the bottom-left are the box's axes.
    const ex = Vec2{ .x = box.corners[1].x - box.corners[0].x, .y = box.corners[1].y - box.corners[0].y };
    const ey = Vec2{ .x = box.corners[3].x - box.corners[0].x, .y = box.corners[3].y - box.corners[0].y };
    const rel = Vec2{ .x = p.x - box.corners[0].x, .y = p.y - box.corners[0].y };
    const det = ex.x * ey.y - ex.y * ey.x;
    if (@abs(det) < 0.0001) return false;
    const u = (rel.x * ey.y - rel.y * ey.x) / det;
    const v = (ex.x * rel.y - ex.y * rel.x) / det;
    return u >= 0 and u <= 1 and v >= 0 and v <= 1;
}

fn hoverHandle(h: ?Viewport.Hover, kind: Handle) bool {
    const u = h orelse return false;
    return switch (u) {
        .handle => |handle| handle == kind,
        else => false,
    };
}

/// A scale of zero is a rendering bug, not a feature: keep at least a sliver
/// on each axis, either sign (flipping across the center stays legal).
fn clampScale(s: f32) f32 {
    if (s > 0 and s < 0.01) return 0.01;
    if (s < 0 and s > -0.01) return -0.01;
    // Exactly zero is a hole, not a sprite.
    if (s == 0) return 0.01;
    return s;
}

fn wrapPi(a: f32) f32 {
    var r = @mod(a + std.math.pi, std.math.tau);
    if (r < 0) r += std.math.tau;
    return r - std.math.pi;
}

/// True when a grid line at coordinate `v` is the origin line (the axes draw
/// their own colored lines through 0).
fn isOriginLine(v: f32, thin: f32) bool {
    return @abs(v) < thin;
}

/// The entities whose box the rectangle TOUCHES, in world units.
///
/// It touches rather than contains: a marquee that only caught the entities
/// it fully swallowed would be useless on small sprites, and "did the box
/// touch it" is the question a user is really asking.
///
/// The result is written into `out` and its LENGTH returned — the caller
/// owns the buffer, and a frame may not allocate.
fn entitiesInRect(
    world: *ecs.World,
    min_x: f32,
    max_x: f32,
    min_y: f32,
    max_y: f32,
    out: []Entity,
) usize {
    var count: usize = 0;
    var slot: usize = 0;
    while (slot < world.slotCount()) : (slot += 1) {
        const e = world.entityAtSlot(slot) orelse continue;
        const t = world.get(e, ecs.components.Transform) orelse continue;
        const sp = world.get(e, ecs.components.Sprite) orelse continue;
        if (!sp.visible) continue;
        const hx = sp.size.x * 0.5 * @abs(t.scale.x);
        const hy = sp.size.y * 0.5 * @abs(t.scale.y);
        if (t.position.x + hx < min_x) continue;
        if (t.position.x - hx > max_x) continue;
        if (t.position.y + hy < min_y) continue;
        if (t.position.y - hy > max_y) continue;
        if (count >= out.len) break;
        out[count] = e;
        count += 1;
    }
    return count;
}

/// Topmost entity under the world point. "Topmost" = the highest sprite
/// layer, then the stable order inside it, then the later slot — the exact
/// tie-breaks the renderer's painter's sort uses, so picking and drawing
/// can never disagree about what is on top.
fn pickEntity(world: *ecs.World, mouse_w: Vec2) ?Entity {
    var best: ?Entity = null;
    var best_layer: u16 = 0;
    var best_order: i32 = std.math.minInt(i32);
    var best_slot: usize = 0;

    var slot: usize = 0;
    while (slot < world.slotCount()) : (slot += 1) {
        const e = world.entityAtSlot(slot) orelse continue;
        const t = world.get(e, ecs.components.Transform) orelse continue;
        const sp = world.get(e, ecs.components.Sprite) orelse continue;
        if (!sp.visible) continue;
        const hx = sp.size.x * 0.5 * @abs(t.scale.x);
        const hy = sp.size.y * 0.5 * @abs(t.scale.y);
        if (hx <= 0 or hy <= 0) continue;
        if (@abs(mouse_w.x - t.position.x) > hx) continue;
        if (@abs(mouse_w.y - t.position.y) > hy) continue;

        const better = best == null or
            sp.layer > best_layer or
            (sp.layer == best_layer and (sp.order > best_order or
                (sp.order == best_order and slot >= best_slot)));
        if (better) {
            best = e;
            best_layer = sp.layer;
            best_order = sp.order;
            best_slot = slot;
        }
    }
    return best;
}

// ── Tests ────────────────────────────────────────────────────────────────────

const testing = std.testing;

test "viewport: wrapPi unwraps a rotation so 359°→1° spins the short way" {
    // A drag that crosses the ±180° seam must not teleport the rotation:
    // a pointer sweep of −6.2 rad past the seam resolves to +0.08 forward,
    // not to a −6.2 spin the long way round.
    try testing.expectApproxEqAbs(@as(f32, -6.2 + std.math.tau), wrapPi(-6.2), 0.001);
    try testing.expectApproxEqAbs(@as(f32, 0.5), wrapPi(0.5), 0.001);
}

test "viewport: grid cell widens as the camera zooms out" {
    // Zoomed IN, the cell HALVES: a 32-unit cell at zoom 4 is 128 px apart on
    // screen, which is not a grid but three lonely lines. The cell adapts in
    // both directions, and this is the direction that matters.
    const vp = Viewport{ .cam = .{ .zoom = 4 } };
    try testing.expectEqual(grid_base / 2, vp.gridCell());
    try testing.expect(vp.gridCell() * vp.cam.zoom <= grid_max_px);
    // Zoomed far out, lines every 32 world units would be sub-pixel soup:
    // the cell must double until it clears the minimum screen spacing.
    var vp_out = Viewport{ .cam = .{ .zoom = 0.3 } };
    try testing.expect(vp_out.gridCell() > grid_base);
    try testing.expect(vp_out.gridCell() * vp_out.cam.zoom >= grid_min_px);
}

test "viewport: the origin line is never drawn twice" {
    try testing.expect(isOriginLine(0, 1.0));
    try testing.expect(isOriginLine(0.5, 1.0)); // within the line's thickness
    try testing.expect(!isOriginLine(2.0, 1.0));
}

test "viewport: the region decides where the pointer is measured from" {
    // The pointer is in WINDOW pixels and the camera speaks REGION pixels, so
    // the region is subtracted. Getting this wrong is what put a click
    // half a screen away from the thing it hit.
    const vp = Viewport{ .region = .{ .x = 300, .y = 100, .w = 800, .h = 600 } };
    const local = vp.localPoint(.{ .x = 500, .y = 250 });
    try testing.expectApproxEqAbs(@as(f32, 200), local.x, 0.001);
    try testing.expectApproxEqAbs(@as(f32, 150), local.y, 0.001);

    // And the region is a real hit test: a click on the inspector is not a
    // click on the scene.
    try testing.expect(vp.region.contains(.{ .x = 300, .y = 100 }));
    try testing.expect(!vp.region.contains(.{ .x = 299, .y = 100 }));
    try testing.expect(!vp.region.contains(.{ .x = 300, .y = 99 }));
}

test "viewport: a scale of zero is a sliver, not a hole" {
    try testing.expectApproxEqAbs(@as(f32, 0.01), clampScale(0.0), 0.0001);
    try testing.expectApproxEqAbs(@as(f32, 0.01), clampScale(-0.0), 0.0001);
    try testing.expectApproxEqAbs(@as(f32, 0.01), clampScale(0.001), 0.0001);
    try testing.expectApproxEqAbs(@as(f32, 2.5), clampScale(2.5), 0.0001);
    // A flip across the centre stays legal: negative scales are legal.
    try testing.expectApproxEqAbs(@as(f32, -3.0), clampScale(-3.0), 0.0001);
}

test "viewport: the marquee catches what it touches" {
    var world = ecs.World.init(testing.allocator);
    defer world.deinit();

    const a = try world.spawn(.{
        ecs.components.Transform{ .position = .{ .x = 0, .y = 0 } },
        ecs.components.Sprite{ .size = .{ .x = 20, .y = 20 } },
    });
    const b = try world.spawn(.{
        ecs.components.Transform{ .position = .{ .x = 100, .y = 0 } },
        ecs.components.Sprite{ .size = .{ .x = 20, .y = 20 } },
    });
    const hidden = try world.spawn(.{
        ecs.components.Transform{ .position = .{ .x = 0, .y = 0 } },
        ecs.components.Sprite{ .size = .{ .x = 20, .y = 20 }, .visible = false },
    });

    var out: [8]Entity = undefined;

    // A box around the first one catches it and NOT the one a hundred units
    // away.
    const one = entitiesInRect(&world, -15, 15, -15, 15, out[0..]);
    try testing.expectEqual(@as(usize, 1), one);
    try testing.expectEqual(a.index, out[0].index);

    // A box that reaches the second one catches both.
    const two = entitiesInRect(&world, -15, 115, -15, 15, out[0..]);
    try testing.expectEqual(@as(usize, 2), two);
    try testing.expectEqual(a.index, out[0].index);
    try testing.expectEqual(b.index, out[1].index);

    // An INVISIBLE sprite is not caught: a selection of something the user
    // cannot see is a selection they cannot make.
    _ = hidden;
    const vis = entitiesInRect(&world, -1000, 1000, -1000, 1000, out[0..]);
    try testing.expectEqual(@as(usize, 2), vis);

    // A box that touches an entity's EDGE catches it: "did the box touch it"
    // is the question, not "did the box swallow it". The first sprite spans
    // x ∈ [-10, 10], so a box from 9 catches it.
    const edge = entitiesInRect(&world, 9, 12, -2, 2, out[0..]);
    try testing.expectEqual(@as(usize, 1), edge);
    try testing.expectEqual(a.index, out[0].index);

    // And the second one, which is a hundred units away, is not caught by it.
    const far = entitiesInRect(&world, 9, 12, -2, 2, out[0..]);
    try testing.expectEqual(@as(usize, 1), far);
    try testing.expectEqual(a.index, out[0].index);
}
