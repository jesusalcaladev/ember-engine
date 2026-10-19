//! The viewport — the editor's window onto the scene.
//!
//! ## What it is, in one line
//!
//! A persistent camera (pan, zoom-at-cursor), an adaptive grid, click-to-select
//! in the scene itself, and the three Godot-style edit gizmos: drag the body to
//! move, the corner disc to scale, the top disc to rotate.
//!
//! ## Why there is no ImGui window behind it
//!
//! The center of the shell is deliberately window-less: any window there would
//! swallow every pointer event before scene interaction could see one. So this
//! module draws THROUGH the 2D batcher (grid and gizmos are ordinary
//! `SpriteInstance` quads — the same budget every entity already uses) and it
//! reads the pointer from the raw platform `Mouse`, the exact source the
//! tilemap brush already uses. `ui.wantsMouse()` is the gate that keeps the two
//! worlds from fighting: an interaction happens only when the last frame said
//! the pointer was over empty scene, never over a dock or a floating tool.
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

/// Which part of the selection the pointer is touching.
pub const Handle = enum { none, body, scale, rotate };

const min_zoom: f32 = 0.1;
const max_zoom: f32 = 12.0;
/// Base grid pitch in world units. The DRAWN grid adapts to zoom (so lines are
/// never tighter than the minimum screen spacing below), and the MOVE SNap
/// follows the drawn cell, so what you snap to is exactly what you see.
const grid_base: f32 = 32.0;
/// A grid line is never drawn closer together than this on screen (pixels).
const grid_min_px: f32 = 24.0;
/// Handle hit radius, in screen pixels.
const handle_hit_px: f32 = 11.0;
/// The rotate handle sits this many screen pixels above the box's top edge.
const rotate_offset_px: f32 = 22.0;
/// The same white-slot / top-layer constants the physics overlay uses, so the
/// gizmos share its single white page and sit directly under its layer.
const debug_slot: u8 = 255;
const overlay_layer: u16 = 254;
const grid_layer: u16 = 0;

/// Overlay colors. Literal, like the physics overlay's, because a gizmo color
/// is an editor decision the runtime theme has no stake in.
const col_grid_minor = [4]u8{ 128, 140, 160, 22 };
const col_grid_major = [4]u8{ 150, 165, 190, 52 };
const col_axis_x = [4]u8{ 235, 84, 84, 150 };
const col_axis_y = [4]u8{ 96, 224, 128, 150 };
const col_accent = [4]u8{ 47, 129, 247, 240 }; // the theme accent, hex baked
const col_accent_hover = [4]u8{ 68, 147, 248, 255 };
const col_hover_ghost = [4]u8{ 47, 129, 247, 90 };

pub const Viewport = struct {
    tool: Tool = .cursor,
    show_grid: bool = true,

    /// The camera, persistent across frames and scenes (a viewport that snaps
    /// home on every undo is not a viewport). The runtime's own shape: the
    /// same `ecs.camera.View` a project camera would produce.
    cam: ecs.camera.View = .{ .cx = 0, .cy = 0, .zoom = 1 },

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
    /// Mouse minus entity position at grab (a body drag keeps the corner you
    /// clicked on, not the center).
    grab_offset: Vec2 = .{},
    /// Write-only flag for main: a completed drag means collider hosts moved
    /// while Box2D was not stepping them (`takeEdited` reads and clears it).
    edited_this_frame: bool = false,

    pub const Hover = union(enum) {
        none,
        entity: Entity,
        handle: Handle,
    };

    // ── Camera helpers ───────────────────────────────────────────────────

    /// Sizes the camera to the framebuffer (every frame; a resize is the same
    /// code path) and returns the view the renderer consumes.
    pub fn cameraView(vp: *Viewport, fb_w: f32, fb_h: f32) ecs.camera.View {
        vp.cam.viewport_w = fb_w;
        vp.cam.viewport_h = fb_h;
        return vp.cam;
    }

    /// Center the camera on the selection and lift the zoom to at least
    /// one-to-one — the F key. A no-op without a selection.
    pub fn centerOnSelection(vp: *Viewport, ed: *Editor) void {
        const e = ed.selection orelse return;
        const t = ed.world().get(e, ecs.components.Transform) orelse return;
        vp.centerOn(t.position);
    }

    pub fn centerOn(vp: *Viewport, world: Vec2) void {
        vp.cam.cx = world.x;
        vp.cam.cy = world.y;
        if (vp.cam.zoom < 1) vp.cam.zoom = 1;
        vp.hover = null;
    }

    /// Home view: the origin, one-to-one.
    pub fn recenter(vp: *Viewport) void {
        vp.cam = .{ .zoom = 1 };
        vp.hover = null;
    }

    /// The grid pitch that IS drawn this frame — and what Move-snap follows.
    pub fn gridCell(vp: *const Viewport) f32 {
        var cell = grid_base;
        while (cell * vp.cam.zoom < grid_min_px) cell *= 2;
        return cell;
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

        // Wheel zoom: multiplicative (so the same wheel travel feels the same
        // at any depth), anchored at the cursor (the world point under it
        // stays under it), and it only plays over the scene.
        if (!over_ui and m.inside and m.wheel_y != 0) {
            const anchor = vp.cam.screenToWorld(mouse);
            vp.cam.zoom *= std.math.pow(f32, 2, m.wheel_y * 0.25);
            vp.cam.zoom = std.math.clamp(vp.cam.zoom, min_zoom, max_zoom);
            // The rect's top-left is derived from the center; re-touch it so
            // `anchor` sits exactly under the cursor at the new zoom.
            vp.cam.cx = anchor.x - mouse.x / vp.cam.zoom + vp.cam.viewport_w / (2 * vp.cam.zoom);
            vp.cam.cy = anchor.y - mouse.y / vp.cam.zoom + vp.cam.viewport_h / (2 * vp.cam.zoom);
        }

        // Pan: middle-button drag. Free in both tools, over everything — the
        // one gesture that always means "move my window onto the world".
        if (!over_ui and m.inside and m.buttons[2]) {
            vp.cam.cx -= m.dx / vp.cam.zoom;
            vp.cam.cy -= m.dy / vp.cam.zoom;
        }

        if (vp.tool == .cursor and !over_ui and m.inside) {
            const mouse_w = vp.cam.screenToWorld(mouse);
            if (vp.grabbed == .none) vp.refreshHover(ed, mouse, mouse_w);

            if (m.justPressed(0)) vp.beginGrab(ed, mouse_w);
            if (m.buttons[0] and vp.grabbed != .none) {
                vp.dragTo(ed, mouse_w, m.ctrl);
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
                    vp.dragTo(ed, vp.cam.screenToWorld(mouse), m.ctrl);
                } else {
                    vp.releaseGrab();
                }
            } else {
                vp.hover = null;
            }
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
                if (near(worldToScreen(vp.cam, vp.scaleHandleWorldPos(ed, sel)), mouse, handle_hit_px)) {
                    vp.hover = .{ .handle = .scale };
                    return;
                }
                if (near(worldToScreen(vp.cam, vp.rotateHandleWorldPos(ed, sel)), mouse, handle_hit_px)) {
                    vp.hover = .{ .handle = .rotate };
                    return;
                }
                // the body remains pickable through the generic path below
            }
        }

        if (pickEntity(ed.world(), mouse_w)) |e| vp.hover = .{ .entity = e };
    }

    fn beginGrab(vp: *Viewport, ed: *Editor, mouse_w: Vec2) void {
        const h = vp.hover orelse return;
        switch (h) {
            .none => {
                // Empty space clears the selection — Godot's rule, and the
                // only rule a "select what I clicked" editor can keep.
                ed.selection = null;
            },
            .entity => |e| {
                if (!ed.world().isAlive(e)) return;
                const t = ed.world().get(e, ecs.components.Transform) orelse return;
                ed.select(e);
                vp.grabbed = .body;
                vp.grab_entity = e;
                vp.grab_offset = mouse_w.sub(t.position);
                vp.snapshot(ed, e, t);
            },
            .handle => |handle| {
                const sel = ed.selection orelse return;
                const t = ed.world().get(sel, ecs.components.Transform) orelse return;
                vp.grabbed = handle;
                vp.grab_entity = sel;
                vp.snapshot(ed, sel, t);
            },
        }
    }

    fn snapshot(vp: *Viewport, ed: *Editor, e: Entity, t: *const ecs.components.Transform) void {
        vp.grab_entity = e;
        vp.grabbed_pos = t.position;
        vp.grabbed_rot = t.rotation;
        vp.grabbed_scale = t.scale;
        // The sprite's size is what scale multiplies. A selection without one
        // (picked in an earlier frame, sprite removed since) still moves.
        const sp = ed.world().get(e, ecs.components.Sprite);
        vp.grabbed_size = if (sp) |s| s.size else .{ .x = 1, .y = 1 };
    }

    fn dragTo(vp: *Viewport, ed: *Editor, mouse_w: Vec2, ctrl: bool) void {
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

        switch (vp.grabbed) {
            .none => {},
            .body => {
                var pos = mouse_w.sub(vp.grab_offset);
                if (ctrl) {
                    // Ctrl snaps to the grid cell that is DRAWN — snapping
                    // and seeing must agree, or one of them is lying.
                    const cell = vp.gridCell();
                    pos.x = @round(pos.x / cell) * cell;
                    pos.y = @round(pos.y / cell) * cell;
                }
                t.position = pos;
            },
            .scale => {
                // The pointer in the entity's LOCAL frame (rotation removed):
                // scale multiplies the sprite's size along each axis, so the
                // pointer's offset along those axes IS the new scale.
                const rel = mouse_w.sub(t.position);
                const c = @cos(t.rotation);
                const s = @sin(t.rotation);
                const local: Vec2 = .{
                    .x = rel.x * c + rel.y * s,
                    .y = -rel.x * s + rel.y * c,
                };
                var sx = local.x / (vp.grabbed_size.x * 0.5);
                var sy = local.y / (vp.grabbed_size.y * 0.5);
                // Degenerate scales are a rendering bug, not a feature: keep
                // at least a sliver on each axis, either sign (flipping
                // across the center stays legal).
                if (sx > 0 and sx < 0.01) sx = 0.01;
                if (sx < 0 and sx > -0.01) sx = -0.01;
                if (sy > 0 and sy < 0.01) sy = 0.01;
                if (sy < 0 and sy > -0.01) sy = -0.01;
                t.scale.x = sx;
                t.scale.y = sy;
            },
            .rotate => {
                // The handle rests ABOVE the center — local (0, −r) — which
                // is the angle `rotation − 90°`. A pointer at world angle `a`
                // therefore means rotation `a + 90°`, kept continuous with
                // the grab via wrapPi so 359°→1° does not spin the long way.
                const rel = mouse_w.sub(t.position);
                const a = std.math.atan2(rel.y, rel.x);
                var rot = vp.grabbed_rot + wrapPi(a - vp.grabbed_rot + std.math.pi / 2.0);
                if (ctrl) {
                    const step: f32 = std.math.pi / 12.0; // 15°, Godot's default
                    rot = @round(rot / step) * step;
                }
                t.rotation = rot;
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

    // ── Handle geometry (hit-testing and drawing share it) ───────────────

    fn selectionSprite(ed: *Editor, sel: Entity) ?*ecs.components.Sprite {
        return ed.world().get(sel, ecs.components.Sprite);
    }

    fn scaleHandleWorldPos(vp: *Viewport, ed: *Editor, sel: Entity) Vec2 {
        const t = ed.world().get(sel, ecs.components.Transform) orelse return vp.cam.screenToWorld(.{});
        const sp = selectionSprite(ed, sel) orelse return t.position;
        const corner: Vec2 = .{
            .x = sp.size.x * 0.5 * @abs(t.scale.x),
            .y = sp.size.y * 0.5 * @abs(t.scale.y),
        };
        return rotateVec(t.position, corner, t.rotation);
    }

    fn rotateHandleWorldPos(vp: *Viewport, ed: *Editor, sel: Entity) Vec2 {
        const t = ed.world().get(sel, ecs.components.Transform) orelse return vp.cam.screenToWorld(.{});
        const sp = selectionSprite(ed, sel) orelse
            return t.position.add(.{ .y = -rotate_offset_px });
        const above: Vec2 = .{
            .x = 0,
            .y = -(sp.size.y * 0.5 * @abs(t.scale.y) + rotate_offset_px / vp.cam.zoom),
        };
        return rotateVec(t.position, above, t.rotation);
    }

    fn hoverHandle(h: ?Hover, kind: Handle) bool {
        const u = h orelse return false;
        return switch (u) {
            .handle => |handle| handle == kind,
            else => false,
        };
    }

    // ── Drawing ──────────────────────────────────────────────────────────

    /// The grid: pushed BEFORE the sprites, on layer 0, and the batcher's
    /// stable counting sort keeps insertion order inside a layer — so the
    /// grid is under every entity of its layer, every time, with no second
    /// draw pass to pay for.
    pub fn pushUnderlay(vp: *Viewport, r2d: *render2d.Renderer2D) void {
        if (!vp.show_grid) return;

        const rect = vp.cam.worldRect();
        const cell = vp.gridCell();
        const zoom = vp.cam.zoom;

        // A one-screen-pixel-thick line, which means its world thickness must
        // follow the zoom.
        const thin = 1.0 / zoom;
        var quads: usize = 0;
        const cap: usize = 1024; // hard cap; a 4K screen at min zoom fits under it

        // A major line every 4 minors — 128 world units at the base pitch.
        const major_every = 4.0 * cell;
        var gx = @floor(rect.left() / cell) * cell;
        var gy = @floor(rect.top() / cell) * cell;

        const cols: usize = @intFromFloat(@ceil(rect.size.x / cell) + 1);
        var i: usize = 0;
        while (i < cols) : (i += 1) {
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
            gx += cell;
        }

        const rows: usize = @intFromFloat(@ceil(rect.size.y / cell) + 1);
        i = 0;
        while (i < rows) : (i += 1) {
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
            gy += cell;
        }

        // World axes through the origin, in the two colors Godot taught
        // everyone to read: red across (X), green down (Y).
        _ = r2d.pushInstance(.{
            .pos = .{ vp.cam.cx, 0 },
            .half = .{ vp.cam.viewport_w / zoom, 1.5 / zoom },
            .uv = .{ 0, 0, std.math.maxInt(u16), std.math.maxInt(u16) },
            .color = col_axis_x,
            .slot = debug_slot,
            .shape = 0,
            .layer = grid_layer,
        });
        _ = r2d.pushInstance(.{
            .pos = .{ 0, vp.cam.cy },
            .half = .{ 1.5 / zoom, vp.cam.viewport_h / zoom },
            .uv = .{ 0, 0, std.math.maxInt(u16), std.math.maxInt(u16) },
            .color = col_axis_y,
            .slot = debug_slot,
            .shape = 0,
            .layer = grid_layer,
        });
    }

    /// Hover ghost, selection box, and the scale/rotate handles: pushed after
    /// the tiles, on their own layer, under the physics overlay.
    pub fn pushOverlay(vp: *Viewport, ed: *Editor, r2d: *render2d.Renderer2D) void {
        // An entity the pointer is over but has not picked: a ghost outline.
        if (vp.hover) |h| switch (h) {
            .entity => |e| {
                var ghost = true;
                if (ed.selection) |sel| {
                    if (sel.index == e.index and sel.generation == e.generation) ghost = false;
                }
                if (ghost) vp.outlineBox(ed, r2d, e, col_hover_ghost, 1.0);
            },
            else => {},
        };

        const sel = ed.selection orelse return;
        if (!ed.world().isAlive(sel)) return;
        const t = ed.world().get(sel, ecs.components.Transform) orelse return;

        // The selection's own box, above everything it edits.
        vp.outlineBox(ed, r2d, sel, col_accent, 1.5);

        // Handles live only under the cursor tool (the tile tool does not
        // edit entities). They show while a simulation runs, too: Godot edits
        // live, and a running behavior fighting a drag is a fair fight.
        if (vp.tool != .cursor) return;

        const sp = selectionSprite(ed, sel);
        const scale_pos = vp.scaleHandleWorldPos(ed, sel);
        const rot_pos = vp.rotateHandleWorldPos(ed, sel);
        const s = 4.5 / vp.cam.zoom; // constant screen size

        const scale_color: [4]u8 = if (vp.grabbed == .scale or hoverHandle(vp.hover, .scale))
            col_accent_hover
        else
            col_accent;
        const rot_color: [4]u8 = if (vp.grabbed == .rotate or hoverHandle(vp.hover, .rotate))
            col_accent_hover
        else
            col_accent;

        // Scale: a disc on the corner (bottom-right of the local rect).
        _ = r2d.pushInstance(.{
            .pos = .{ scale_pos.x, scale_pos.y },
            .half = .{ s, s },
            .uv = .{ 0, 0, std.math.maxInt(u16), std.math.maxInt(u16) },
            .color = scale_color,
            .slot = debug_slot,
            .shape = 1,
            .layer = overlay_layer,
        });

        // Rotate: a stem from the box's top edge up to a disc.
        if (sp) |sprite| {
            const top: Vec2 = .{ .x = 0, .y = -(sprite.size.y * 0.5 * @abs(t.scale.y)) };
            const top_w = rotateVec(t.position, top, t.rotation);
            const stem: Vec2 = rot_pos.sub(top_w);
            _ = r2d.pushInstance(.{
                .pos = .{ (top_w.x + rot_pos.x) / 2, (top_w.y + rot_pos.y) / 2 },
                .half = .{ 1.0 / vp.cam.zoom, @abs(stem.y) / 2 + 1.0 / vp.cam.zoom },
                .uv = .{ 0, 0, std.math.maxInt(u16), std.math.maxInt(u16) },
                .color = rot_color,
                .slot = debug_slot,
                .shape = 0,
                .layer = overlay_layer,
            });
        }
        _ = r2d.pushInstance(.{
            .pos = .{ rot_pos.x, rot_pos.y },
            .half = .{ s, s },
            .uv = .{ 0, 0, std.math.maxInt(u16), std.math.maxInt(u16) },
            .color = rot_color,
            .slot = debug_slot,
            .shape = 1,
            .layer = overlay_layer,
        });
    }

    /// The selection's rectangle: a translucent fill plus a four-quad border.
    /// Axis-aligned, because `SpriteInstance` quads do not rotate — and the
    /// hit-test uses the same box, so neither can be surprised by the other.
    fn outlineBox(vp: *Viewport, ed: *Editor, r2d: *render2d.Renderer2D, e: Entity, color: [4]u8, thick_px: f32) void {
        const t = ed.world().get(e, ecs.components.Transform) orelse return;
        const sp = ed.world().get(e, ecs.components.Sprite) orelse return;
        const hx = sp.size.x * 0.5 * @abs(t.scale.x);
        const hy = sp.size.y * 0.5 * @abs(t.scale.y);
        const w = thick_px / vp.cam.zoom;

        _ = r2d.pushInstance(.{
            .pos = .{ t.position.x, t.position.y },
            .half = .{ hx, hy },
            .uv = .{ 0, 0, std.math.maxInt(u16), std.math.maxInt(u16) },
            .color = translucent(color),
            .slot = debug_slot,
            .shape = 0,
            .layer = overlay_layer,
        });
        _ = r2d.pushInstance(.{ // top
            .pos = .{ t.position.x, t.position.y - hy },
            .half = .{ hx + w, w },
            .uv = .{ 0, 0, std.math.maxInt(u16), std.math.maxInt(u16) },
            .color = color,
            .slot = debug_slot,
            .shape = 0,
            .layer = overlay_layer,
        });
        _ = r2d.pushInstance(.{ // bottom
            .pos = .{ t.position.x, t.position.y + hy },
            .half = .{ hx + w, w },
            .uv = .{ 0, 0, std.math.maxInt(u16), std.math.maxInt(u16) },
            .color = color,
            .slot = debug_slot,
            .shape = 0,
            .layer = overlay_layer,
        });
        _ = r2d.pushInstance(.{ // left
            .pos = .{ t.position.x - hx, t.position.y },
            .half = .{ w, hy + w },
            .uv = .{ 0, 0, std.math.maxInt(u16), std.math.maxInt(u16) },
            .color = color,
            .slot = debug_slot,
            .shape = 0,
            .layer = overlay_layer,
        });
        _ = r2d.pushInstance(.{ // right
            .pos = .{ t.position.x + hx, t.position.y },
            .half = .{ w, hy + w },
            .uv = .{ 0, 0, std.math.maxInt(u16), std.math.maxInt(u16) },
            .color = color,
            .slot = debug_slot,
            .shape = 0,
            .layer = overlay_layer,
        });
    }

    // ── The tool pill ────────────────────────────────────────────────────

    var drawing_vp: ?*Viewport = null;

    /// A small floating window, top-right of the framebuffer: the tool pair,
    /// the grid toggle, and Home. A pill and not a dock — the viewport is the
    /// one region without a window behind it, and this is how it keeps one.
    pub fn drawToolbar(vp: *Viewport, ctx: *ui.Context, fb_w: u32) void {
        drawing_vp = vp;
        const x = @as(f32, @floatFromInt(fb_w)) - 96;
        ui.floating(ctx, "ViewportTools", .{ .x = x, .y = 14, .w = 60, .h = 90, .resizable = false }, toolbarBody);
        drawing_vp = null;
    }

    fn toolbarBody(ctx: *ui.Context) void {
        const vp = drawing_vp orelse return;

        if (ui.button.render(.{
            .ctx = ctx,
            .id = "tool.cursor",
            .text = "Cursor",
            .variant = if (vp.tool == .cursor) .primary else .ghost,
            .tooltip = "Q — pick and edit entities in the scene",
        })) vp.tool = .cursor;
        cimgui.ember_ui_same_line(0, 4);
        if (ui.button.render(.{
            .ctx = ctx,
            .id = "tool.tile",
            .text = "Tiles",
            .variant = if (vp.tool == .tile) .primary else .ghost,
            .tooltip = "T — the TileMap brush owns left-click",
        })) {
            vp.tool = .tile;
        }
    }
};

// ── Module helpers ───────────────────────────────────────────────────────────

fn worldToScreen(cam: ecs.camera.View, world: Vec2) Vec2 {
    return cam.worldToScreen(world);
}

fn near(a: Vec2, b: Vec2, px: f32) bool {
    const dx = a.x - b.x;
    const dy = a.y - b.y;
    return dx * dx + dy * dy <= px * px;
}

fn rotateVec(origin: Vec2, offset: Vec2, radians: f32) Vec2 {
    const c = @cos(radians);
    const s = @sin(radians);
    return .{
        .x = origin.x + offset.x * c - offset.y * s,
        .y = origin.y + offset.x * s + offset.y * c,
    };
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

fn translucent(color: [4]u8) [4]u8 {
    var c = color;
    c[3] = @intCast(color[3] / 4);
    return c;
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
    const vp = Viewport{ .cam = .{ .zoom = 4 } };
    try testing.expectEqual(grid_base, vp.gridCell());
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
