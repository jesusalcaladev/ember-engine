//! The editor shell — one window, fixed docks, one central workspace.
//!
//! ## The composition (ROADMAP M5.7)
//!
//! ```text
//! +--------------------------------------------------------------+
//! | File  Edit  View  Play                         (menu, 30px)  |
//! +--------------------------------------------------------------+
//! | [ Scene ] [ Script ]                       ▶ ⏭ ⏹  (tabs, 34)|
//! +-----------+------------------------------+-------------------+
//! | Hierarchy |                              |                   |
//! |           |   the active workspace       |   Inspector       |
//! |-----------|   (Scene = the live viewport)|                   |
//! | Assets    |                              |                   |
//! +-----------+------------------------------+-------------------+
//! | Console                                            (console) |
//! +--------------------------------------------------------------+
//! | scene.zson · 25 entities · 60 fps · 16.6 ms       (status)   |
//! +--------------------------------------------------------------+
//! ```
//!
//! Three rules decide everything else:
//!
//! 1. **The docks never move.** Hierarchy/assets left, inspector right, console
//!    at the bottom. Switching a tab swaps ONLY the centre.
//! 2. **Play is chrome, not a tab.** The transport sits in the tab bar row, so
//!    it is visible from every workspace, and stopping the simulation is never
//!    "switch tabs first".
//! 3. **Every seam is draggable.** The widths live on the editor (`Layout`),
//!    not in ImGui's memory, so "Reset Layout" is one assignment and a window
//!    resize cannot leave a dock at 20% of the screen.
//!
//! ## Why the centre is EMPTY on the Scene tab
//!
//! A true hole in ImGui needs docking (ROADMAP). Until then the viewport is the
//! region where no window sits: a full-centre window would make `wantsMouse()`
//! true everywhere and swallow every tilemap brush stroke. The Scene workspace
//! therefore draws nothing in the centre, and only the chrome around it is
//! submitted.
//!
//! ## Why floating windows and not `layout.panel`
//!
//! `ui.layout.panel` is `BeginChild`: a region INSIDE a parent, so it cannot be
//! a dock. The docks are top-level windows pinned with `Cond.Always` and
//! `NoDecoration | NoMove`. The day ImGui docking is wired, this file switches
//! to `DockSpace` and the bodies do not change.

const std = @import("std");
const ui = @import("ui");
const cimgui = ui.cimgui;

const ed_mod = @import("editor_state.zig");
const Editor = ed_mod.Editor;

const hierarchy_mod = @import("hierarchy.zig");
const inspector_mod = @import("inspector.zig");
const console_mod = @import("console.zig");
const tilemap_panel_mod = @import("tilemap_panel.zig");
const ecs = @import("engine").ecs;

// ── Layout constants ───────────────────────────────────────────────────────
//
// One place, so the panels line up by construction and a change to the console
// height moves the two columns above it instead of leaving a gap.

const top_h: f32 = 30;
const tabs_h: f32 = 34;
const status_h: f32 = 22;
/// The drag target at a seam. Wider than the 2px line it draws: a 2px hit box
/// is a divider nobody can grab, and the visible thing stays 2px.
const grip_w: f32 = 7;
const transport_w: f32 = 104;
/// The viewport may never be squeezed below this by the side docks.
const min_center: f32 = 260;

/// The extra `WindowFlags` every pinned dock shares: no frame, no dragging, no
/// remembered geometry. `NoBringToFrontOnFocus` is what stops a click in the
/// hierarchy from putting the hierarchy on top of the inspector.
const dock_flags: u32 = cimgui.WindowFlags.NoDecoration |
    cimgui.WindowFlags.NoMove |
    cimgui.WindowFlags.NoSavedSettings |
    cimgui.WindowFlags.NoBringToFrontOnFocus;

/// Chrome strips (tabs, transport, status) must not scroll: their content is
/// exactly their height by construction, and a scrollbar in a 22px bar is a
/// bar that lost 10px to nothing.
const no_scroll: u32 = cimgui.WindowFlags.NoScrollbar | cimgui.WindowFlags.NoScrollWithMouse;

// ── Geometry ───────────────────────────────────────────────────────────────

/// Where every region goes this frame. Computed once, so two panels cannot
/// disagree about where the console starts.
const Geometry = struct {
    y0: f32,
    left: f32,
    right: f32,
    console_h: f32,
    center_x: f32,
    center_w: f32,
    center_h: f32,
    status_y: f32,
    hierarchy_h: f32,
};

fn layoutFor(ed: *const Editor, w: f32, h: f32) Geometry {
    var g: Geometry = .{
        .y0 = top_h + tabs_h,
        .left = 0,
        .right = 0,
        .console_h = 0,
        .center_x = 0,
        .center_w = 1,
        .center_h = 1,
        .status_y = h - status_h,
        .hierarchy_h = 0,
    };

    var lw: f32 = if (ed.panels.hierarchy or ed.panels.assets) ed.layout.left else 0;
    var rw: f32 = if (ed.panels.inspector) ed.layout.right else 0;
    // The side docks give room back to the viewport when the window shrinks,
    // proportionally, so neither one becomes the only one on screen.
    const room = @max(w - min_center, 100);
    if (lw + rw > room) {
        const scale = room / @max(lw + rw, 1);
        lw *= scale;
        rw *= scale;
    }
    g.left = @max(lw, 0);
    g.right = @max(rw, 0);
    g.center_x = g.left;
    g.center_w = @max(w - g.left - g.right, 1);

    const columns_room = @max(g.status_y - g.y0, 1);
    g.console_h = if (ed.panels.console)
        std.math.clamp(ed.layout.console, 80, columns_room * 0.6)
    else
        0;
    g.center_h = @max(columns_room - g.console_h, 1);

    // With only one of the two visible, it takes the WHOLE column: a half-height
    // hierarchy with an empty half under it is a panel that looks broken.
    g.hierarchy_h = if (ed.panels.hierarchy and ed.panels.assets)
        g.center_h * std.math.clamp(ed.layout.split, 0.15, 0.85)
    else
        g.center_h;

    return g;
}

// ── The pinned-window helper ───────────────────────────────────────────────

const Dock = struct {
    x: f32 = 0,
    y: f32 = 0,
    w: f32 = 0,
    h: f32 = 0,
    menu_bar: bool = false,
    /// False for the transport strip: it has to show the tab bar's surface
    /// behind it, or it is a 104px rectangle of a different colour.
    background: bool = true,
    /// Window padding override. `null` keeps the theme's (a dock's content has
    /// to breathe); chrome strips set their own so a 26px control fits in a
    /// 34px bar.
    pad: ?[2]f32 = null,
    extra_flags: u32 = 0,
};

/// A dock: a pinned, undecorated, square-cornered window that paints its own
/// surface. Everything in the shell that is not the viewport goes through here,
/// which is what keeps the chrome consistent.
fn dock(ctx: *ui.Context, id: []const u8, d: Dock, body: *const fn (ctx: *ui.Context) void) void {
    const t = &ctx.theme;

    var vars: c_int = 0;
    var cols: c_int = 0;
    cimgui.ember_ui_push_style_var_f(@intFromEnum(cimgui.StyleVar.WindowRounding), 0);
    vars += 1;
    if (d.pad) |p| {
        cimgui.ember_ui_push_style_var_v2(@intFromEnum(cimgui.StyleVar.WindowPadding), p[0], p[1]);
        vars += 1;
    }
    if (d.background) {
        // A dock is a SURFACE, not a hole in the window. The viewport behind it
        // is the scene, which has nothing to do with the docks' colour.
        cimgui.ember_ui_push_style_color(
            @intFromEnum(cimgui.Col.WindowBg),
            @intCast(t.colors.surface.pack()),
        );
        cols += 1;
    }
    defer {
        if (cols > 0) cimgui.ember_ui_pop_style_color(cols);
        cimgui.ember_ui_pop_style_var(vars);
    }

    ui.layout.floating(ctx, id, .{
        .x = d.x,
        .y = d.y,
        .w = d.w,
        .h = d.h,
        .resizable = false,
        .fixed = true,
        .menu_bar = d.menu_bar,
        .flags = dock_flags | d.extra_flags | (if (d.background) 0 else cimgui.WindowFlags.NoBackground),
    }, body);
}

// ── Draggable seams ────────────────────────────────────────────────────────
//
// `ui.layout.splitter` splits a region INSIDE one window (it lays out at the
// cursor). The docks are separate windows, so the seam between two of them is
// its own 7px window whose whole body is one invisible button. The trick is
// that it WRITES the value: the layout reads it next frame, and the drag is
// therefore one line of arithmetic instead of a re-layout pass.

const Grip = struct {
    id: []const u8,
    x: f32,
    y: f32,
    w: f32,
    h: f32,
    axis: enum { vertical, horizontal },
    /// The value this seam moves: a width, a height, or the split fraction.
    value: *f32,
    /// Which way a positive mouse delta moves the value. The inspector's seam
    /// is on its LEFT edge, so dragging right makes the inspector narrower.
    sign: f32 = 1,
    /// Deltas in pixels -> units of `value`. The split is a fraction of the
    /// column, so its scale is 1/height.
    scale: f32 = 1,
    min: f32 = 0,
    max: f32 = 10000,
};

/// The grip being drawn. `ui.layout.floating` takes a bare `fn (*Context) void`
/// and Zig has no closures, so the body reads this — immediate mode means it is
/// already set by the time `floating` calls the body, and cleared right after.
var grip_pending: Grip = undefined;

fn grip(ctx: *ui.Context, g: Grip) void {
    grip_pending = g;
    defer grip_pending = undefined;

    cimgui.ember_ui_push_style_var_v2(@intFromEnum(cimgui.StyleVar.WindowPadding), 0, 0);
    defer cimgui.ember_ui_pop_style_var(1);

    ui.layout.floating(ctx, g.id, .{
        .x = g.x,
        .y = g.y,
        .w = g.w,
        .h = g.h,
        .resizable = false,
        .fixed = true,
        .flags = dock_flags | no_scroll | cimgui.WindowFlags.NoBackground,
    }, gripBody);
}

fn gripBody(ctx: *ui.Context) void {
    const g = grip_pending;
    const t = &ctx.theme;

    const avail = ui.draw.contentAvail();
    _ = cimgui.ember_ui_invisible_button(ui.cimgui.textLit("##grip"), @max(avail.x, 1), @max(avail.y, 1), 0);
    const hovered = cimgui.ember_ui_is_item_hovered(cimgui.HoveredFlags.None) != 0;
    const active = cimgui.ember_ui_is_item_active() != 0;

    if (active) {
        const mouse = &ctx.window.input.mouse;
        const delta = if (g.axis == .vertical) mouse.dx else mouse.dy;
        if (delta != 0) {
            const next = g.value.* + delta * g.sign * g.scale;
            g.value.* = std.math.clamp(next, g.min, @max(g.max, g.min));
        }
    }

    const r = ui.draw.itemRect();
    const list = ui.draw.itemList();
    // A 2px line, not a filled 7px band: the band is the GRAB TARGET. Idle is
    // the same border colour as every other rule, so an untouched layout reads
    // as panels separated by hairlines rather than by stripes.
    const col = if (active)
        t.colors.accent
    else if (hovered)
        t.colors.border_strong
    else
        t.colors.border;

    switch (g.axis) {
        .vertical => {
            const cx = (r.min.x + r.max.x) * 0.5;
            list.rect(ui.draw.rect(cx - 1, r.min.y, cx + 1, r.max.y), col, 0);
        },
        .horizontal => {
            const cy = (r.min.y + r.max.y) * 0.5;
            list.rect(ui.draw.rect(r.min.x, cy - 1, r.max.x, cy + 1), col, 0);
        },
    }
}

// ── Panel bodies ───────────────────────────────────────────────────────────
//
// `ui.layout.floating` takes a `*const fn(*Context) void` and Zig has no
// closures, so each body reaches the editor through `ed_mod.active` — set once
// per frame by `draw` and cleared at the end of it.

fn drawHierarchy(ctx: *ui.Context) void {
    const ed = ed_mod.active.?;
    const count = ed.model.entityCount();
    var buf: [48]u8 = undefined;
    header(ctx, std.fmt.bufPrint(&buf, "Hierarchy  ({d})", .{count}) catch "Hierarchy");
    hierarchy_mod.draw(ed, ctx);
}

fn drawInspector(ctx: *ui.Context) void {
    const ed = ed_mod.active.?;
    header(ctx, "Inspector");
    inspector_mod.draw(ed, ctx);
}

fn drawAssets(ctx: *ui.Context) void {
    const ed = ed_mod.active.?;
    header(ctx, "Assets");
    ed.assets.draw(ctx);
}

fn drawConsole(ctx: *ui.Context) void {
    const ed = ed_mod.active.?;
    header(ctx, "Console");
    console_mod.draw(&ed.console, ctx);
}

fn drawTilemap(ctx: *ui.Context) void {
    const ed = ed_mod.active.?;
    if (ed.tilemap) |panel| {
        panel.drawContents(ctx);
    } else {
        ui.text.caption(ctx, "no tilemap panel");
    }
}

fn drawPane(ctx: *ui.Context) void {
    const ed = ed_mod.active.?;
    if (ed.pane) |pane| {
        pane.drawContents(ctx, 0);
    } else {
        ui.text.caption(ctx, "no code pane");
    }
}

/// A panel's own title. Pinned docks have no ImGui title bar, so without this
/// the layout is four anonymous regions. The 28px accent rule under the label
/// is the chrome's one signature: the same mark on every dock, so "where a
/// panel starts" is readable from across the room.
fn header(ctx: *ui.Context, name: []const u8) void {
    const t = &ctx.theme;
    ui.text.title(ctx, name);
    const p = ui.draw.cursorPos();
    ui.draw.itemList().rect(
        ui.draw.rect(p.x, p.y + 1, p.x + 28, p.y + 3),
        t.colors.accent,
        1,
    );
    ui.layout.space(ctx, 0.5);
}

// ── Frame ──────────────────────────────────────────────────────────────────

/// Draws the entire editor UI for one frame. Called from `main.zig` inside the
/// ImGui frame, after `ui_ctx.newFrame` and before `ui_ctx.drawCommands`.
pub fn draw(ed: *Editor, ctx: *ui.Context, fb_w: u32, fb_h: u32) void {
    ed_mod.active = ed;
    defer ed_mod.active = null;

    handleShortcuts(ed, ctx);

    const w: f32 = @floatFromInt(fb_w);
    const h: f32 = @floatFromInt(fb_h);
    const g = layoutFor(ed, w, h);

    // ── Menu bar ──────────────────────────────────────────────────────────
    dock(ctx, "editor.menubar", .{
        .x = 0,
        .y = 0,
        .w = w,
        .h = top_h,
        .menu_bar = true,
        // No padding: ImGui draws the bar at the window's top, and the theme's
        // 12px padding would push it down by its own height.
        .pad = .{ 0, 0 },
    }, drawMenuBar);

    // ── Tab bar + transport ───────────────────────────────────────────────
    dock(ctx, "editor.tabs", .{
        .x = 0,
        .y = top_h,
        .w = w,
        .h = tabs_h,
        .pad = .{ 0, 0 },
        .extra_flags = no_scroll,
    }, drawWorkspaceTabs);

    dock(ctx, "editor.transport", .{
        .x = w - transport_w,
        .y = top_h,
        .w = transport_w,
        .h = tabs_h,
        .pad = .{ 6, 4 },
        .background = false,
        .extra_flags = no_scroll,
    }, drawTransport);

    // ── Left column: hierarchy over assets ────────────────────────────────
    if (ed.panels.hierarchy) {
        dock(ctx, "editor.hierarchy", .{
            .x = 0,
            .y = g.y0,
            .w = g.left,
            .h = g.hierarchy_h,
        }, drawHierarchy);
    }
    if (ed.panels.assets) {
        const y = g.y0 + g.hierarchy_h;
        dock(ctx, "editor.assets", .{
            .x = 0,
            .y = y,
            .w = g.left,
            .h = @max(g.y0 + g.center_h - y, 1),
        }, drawAssets);
    }

    // ── Centre: the active workspace ──────────────────────────────────────
    //
    // Scene draws NOTHING here: the viewport is the absence of a window. Script
    // gets a real window, because a code pane over a moving scene is unreadable.
    if (ed.workspace == .script) {
        dock(ctx, "editor.workspace.pane", .{
            .x = g.center_x,
            .y = g.y0,
            .w = g.center_w,
            .h = g.center_h,
        }, drawPane);
    }

    // ── Right column: inspector ───────────────────────────────────────────
    if (ed.panels.inspector) {
        dock(ctx, "editor.inspector", .{
            .x = w - g.right,
            .y = g.y0,
            .w = g.right,
            .h = g.center_h,
        }, drawInspector);
    }

    // ── Bottom: console, then the status bar ──────────────────────────────
    if (ed.panels.console) {
        dock(ctx, "editor.console", .{
            .x = 0,
            .y = g.status_y - g.console_h,
            .w = w,
            .h = g.console_h,
        }, drawConsole);
    }

    dock(ctx, "editor.status", .{
        .x = 0,
        .y = g.status_y,
        .w = w,
        .h = status_h,
        .pad = .{ 12, 2 },
        .extra_flags = no_scroll,
    }, drawStatus);

    // ── Seams ─────────────────────────────────────────────────────────────
    //
    // LAST among the docks: ImGui's hit test goes to the topmost window, and a
    // seam that is under the panel it separates cannot be grabbed.
    if (g.left > 0) {
        grip(ctx, .{
            .id = "editor.seam.left",
            .x = g.left - grip_w * 0.5,
            .y = g.y0,
            .w = grip_w,
            .h = g.center_h,
            .axis = .vertical,
            .value = &ed.layout.left,
            .min = 150,
            .max = @max(w - g.right - min_center, 150),
        });
    }
    if (g.right > 0) {
        grip(ctx, .{
            .id = "editor.seam.right",
            .x = w - g.right - grip_w * 0.5,
            .y = g.y0,
            .w = grip_w,
            .h = g.center_h,
            .axis = .vertical,
            .value = &ed.layout.right,
            .sign = -1,
            .min = 200,
            .max = @max(w - g.left - min_center, 200),
        });
    }
    if (ed.panels.hierarchy and ed.panels.assets) {
        grip(ctx, .{
            .id = "editor.seam.left.split",
            .x = 0,
            .y = g.y0 + g.hierarchy_h - grip_w * 0.5,
            .w = g.left,
            .h = grip_w,
            .axis = .horizontal,
            .value = &ed.layout.split,
            .scale = 1 / @max(g.center_h, 1),
            .min = 0.15,
            .max = 0.85,
        });
    }
    if (ed.panels.console) {
        const columns_room = @max(g.status_y - g.y0, 1);
        grip(ctx, .{
            .id = "editor.seam.console",
            .x = 0,
            .y = g.status_y - g.console_h - grip_w * 0.5,
            .w = w,
            .h = grip_w,
            .axis = .horizontal,
            .value = &ed.layout.console,
            .sign = -1,
            .min = 80,
            .max = @max(columns_room * 0.6, 80),
        });
    }

    // ── TileMap: a real floating tool window ──────────────────────────────
    // Not pinned: it is a tool the user puts where they want it, and it has an
    // ImGui title bar so it can be moved and closed like one. It belongs to the
    // SCENE workspace — a paint palette floating over the code editor is a tool
    // for a document that is not on screen.
    if (ed.panels.tilemap and ed.workspace == .scene) {
        const tw: f32 = 300;
        const th: f32 = 430;
        ui.layout.floating(ctx, "TileMap", .{
            .x = @max(g.center_x + g.center_w - tw - 12, g.center_x + 8),
            .y = g.y0 + 12,
            .w = tw,
            .h = th,
            .first_use = true,
            .resizable = true,
            .flags = cimgui.WindowFlags.NoSavedSettings,
        }, drawTilemap);
    }

    // ── Component picker ──────────────────────────────────────────────────
    if (ed.component_picker_open) {
        ui.Modal(.{
            .ctx = ctx,
            .id = "add_component",
            .title = "Add Component",
            .width = 360,
            .open = &ed.component_picker_open,
            .body = drawComponentPickerBody,
        });
        if (!ed.component_picker_open) ed.component_picker_entity = null;
    }

    // ── Prefab picker ────────────────────────────────────────────────────
    // The list of prefab files, and the button that instantiates the selected
    // one. The list is read from the editor's cache — the scan that fills it
    // ran when the menu item was clicked, outside the frame.
    if (ed.prefab_picker_open) {
        ui.Modal(.{
            .ctx = ctx,
            .id = "prefab_picker",
            .title = "Instantiate Prefab",
            .width = 380,
            .open = &ed.prefab_picker_open,
            .body = drawPrefabPickerBody,
            .footer = drawPrefabPickerFooter,
        });
    }

    // ── Collision layer names ─────────────────────────────────────────────
    // Godot keeps them in Project Settings; the editor keeps them on its own
    // state. The dialog is the only writer, which is what keeps the inspector's
    // grid and the physics filter reading the same table.
    if (ed.layer_names_open) {
        ui.Modal(.{
            .ctx = ctx,
            .id = "layer_names",
            .title = "Collision Layer Names",
            .width = 300,
            .open = &ed.layer_names_open,
            .body = drawLayerNamesBody,
            .footer = drawLayerNamesFooter,
        });
    }
}

/// The prefab list. Each row is a file in `prefabs/`; the selected one is
/// what the footer button instantiates.
fn drawPrefabPickerBody(ctx: *ui.Context) void {
    const ed = ed_mod.active.?;
    const list = ed.prefabList();
    if (list.len == 0) {
        ui.text.caption(ctx, "no prefabs yet — Edit → Create Prefab From Selection");
        return;
    }
    for (list, 0..) |entry, i| {
        const name = std.mem.sliceTo(entry[0..], 0);
        if (ui.Button(.{
            .ctx = ctx,
            .id = name,
            .text = name,
            .variant = if (ed.prefabListSelected() == i) .primary else .ghost,
            .width = @max(ui.draw.contentAvail().x, 1),
        })) {
            ed.setPrefabListSelected(i);
        }
    }
}

fn drawPrefabPickerFooter(ctx: *ui.Context) void {
    const ed = ed_mod.active.?;
    if (ed.prefabListLen() == 0) return;
    const list = ed.prefabList();
    const sel = ed.prefabListSelected();
    if (sel >= list.len) return;
    const path = std.mem.sliceTo(list[sel][0..], 0);
    if (ui.Button(.{
        .ctx = ctx,
        .id = "prefab_instantiate",
        .text = "Instantiate",
        .variant = .primary,
        .width = @max(ui.draw.contentAvail().x, 1),
    })) {
        ed.requestInstantiatePrefab(path);
        ed.prefab_picker_open = false;
    }
}

/// The layer-names dialog: one field per bit, in the order the bits read in
/// the masks. Editing writes the editor's own fixed buffers, so a frame may
/// do it in place with no allocation and no queue.
fn drawLayerNamesBody(ctx: *ui.Context) void {
    const ed = ed_mod.active.?;
    ui.text.caption(ctx, "bit 1 is the first; names also appear in the Layer/Mask grid");
    ui.layout.space(ctx, 1);
    var i: usize = 0;
    while (i < ed_mod.layer_bits) : (i += 1) {
        var id_buf: [24]u8 = undefined;
        const id = std.fmt.bufPrint(&id_buf, "ln.{d}", .{i}) catch "ln";
        var num_buf: [8]u8 = undefined;
        const num = std.fmt.bufPrint(&num_buf, "{d}", .{i + 1}) catch "?";
        _ = ui.input.textField(.{
            .ctx = ctx,
            .id = id,
            .label = num,
            .buf = &ed.layer_names[i],
            .capacity = @intCast(ed_mod.layer_name_len - 1),
        });
    }
}

fn drawLayerNamesFooter(ctx: *ui.Context) void {
    const ed = ed_mod.active.?;
    if (ui.Button(.{ .ctx = ctx, .id = "ln.reset", .text = "Reset names", .icon = .refresh, .variant = .ghost })) {
        ed.resetLayerNames();
        ed.log(.info, "layer names reset", .{});
    }
    ui.cimgui.ember_ui_same_line(0, ctx.theme.metrics.gap());
    if (ui.Button(.{ .ctx = ctx, .id = "ln.close", .text = "Close", .variant = .primary })) {
        ed.layer_names_open = false;
        ed.log(.info, "layer names applied", .{});
    }
}

// ── Workspace tabs ─────────────────────────────────────────────────────────

fn noBody(ctx: *ui.Context, index: usize) void {
    _ = ctx;
    _ = index;
}

fn drawWorkspaceTabs(ctx: *ui.Context) void {
    const ed = ed_mod.active.?;
    const t = &ctx.theme;

    var selected: usize = switch (ed.workspace) {
        .scene => 0,
        .script => 1,
    };

    // The unsaved marker is a DOT on the tab, the way every editor with a tab
    // bar does it: a label that gains two characters resizes the tab row, and a
    // tab row that jumps when a document is edited is a tab row nobody clicks
    // twice in the same place.
    const tabs = [_]ui.tabs.Tab{
        .{
            .id = "scene",
            .label = "Scene",
            .icon = .camera,
            .dot = if (ed.dirty) t.colors.warning else null,
        },
        .{
            .id = "script",
            .label = "Script",
            .icon = .file,
        },
    };

    // The body is empty ON PURPOSE: the tab bar is chrome and the workspace is
    // drawn in the region below it. `Tabs` is still the right widget — it owns
    // the overline, the hit testing and the selected state — and the empty body
    // is the one-line way to say "bar only".
    ui.Tabs(.{
        .ctx = ctx,
        .id = "editor.ws.tabs",
        .tabs = &tabs,
        .selected = &selected,
        .body = noBody,
        .height = tabs_h,
    });

    ed.workspace = if (selected == 0) .scene else .script;
}

// ── Transport ──────────────────────────────────────────────────────────────
//
// Play is GLOBAL (ROADMAP M5.7): one row over every workspace, so it is never
// "switch to the Scene tab first". The icons are the colours of the actions
// they perform — play is green, stop is red — because that is the one place in
// an editor where a colour is not decoration.

fn drawTransport(ctx: *ui.Context) void {
    const ed = ed_mod.active.?;
    const t = &ctx.theme;

    const play_icon: ui.Icon = if (ed.play == .playing) .pause else .play;
    const play_col = if (ed.play == .playing) t.colors.warning else t.colors.play;
    const play_tip = if (ed.play == .playing) "Pause (F5)" else "Play (F5)";
    if (transportButton(ctx, "tr.play", play_icon, play_col, true, play_tip)) ed.togglePlay();

    cimgui.ember_ui_same_line(0, 4);
    if (transportButton(ctx, "tr.step", .skip_end, t.colors.text_dim, true, "Step one fixed tick (F6)")) ed.step();

    cimgui.ember_ui_same_line(0, 4);
    if (transportButton(ctx, "tr.stop", .stop, t.colors.stop, ed.play != .stopped, "Stop (Shift+F5)")) ed.stop();
}

/// An icon button with an explicit colour. `ui.button.icon` paints with the
/// text colour, which is right for a toolbar and wrong for the transport: the
/// one place an icon has to say "go" or "halt" on its own.
fn transportButton(
    ctx: *ui.Context,
    id: []const u8,
    icon: ui.Icon,
    col: ui.Rgba,
    enabled: bool,
    tip: []const u8,
) bool {
    const t = &ctx.theme;
    const m = t.metrics;
    const size = m.icon_btn() - 2;
    const hit = ui.widget.submit(cimgui.text(id), size, size, !enabled);

    if (hit.state != .idle) ui.draw.itemList().rect(hit.rect, ui.theme.fill(t, hit.state), m.radius_sm());
    ui.icons.render(
        ui.draw.itemList(),
        icon,
        ui.draw.center(hit.rect),
        if (enabled) col else col.withAlpha(0.35),
        16,
        0,
    );
    if (hit.hovered) cimgui.ember_ui_set_tooltip(cimgui.text(tip));
    return hit.clicked;
}

// ── Status bar ─────────────────────────────────────────────────────────────

fn fileName(p: []const u8) []const u8 {
    if (std.mem.lastIndexOfScalar(u8, p, '/')) |i| {
        if (i + 1 < p.len) return p[i + 1 ..];
    }
    return p;
}

fn playLabel(state: ed_mod.PlayState) []const u8 {
    return switch (state) {
        .stopped => "stopped",
        .playing => "playing",
        .paused => "paused",
    };
}

fn playColor(t: *const ui.Theme, state: ed_mod.PlayState) ui.Rgba {
    return switch (state) {
        .stopped => t.colors.text_faint,
        .playing => t.colors.success,
        .paused => t.colors.warning,
    };
}

/// The bar along the bottom: what document is open, how big it is, and what the
/// frame costs. Drawn with the window's draw list at measured positions rather
/// than with three ImGui items, because a right-aligned cluster needs the
/// WIDTHS, and `spacerToEnd` positions the next item at the edge rather than
/// its right end.
fn drawStatus(ctx: *ui.Context) void {
    const ed = ed_mod.active.?;
    const t = &ctx.theme;

    const avail = ui.draw.contentAvail();
    cimgui.ember_ui_dummy(@max(avail.x, 1), 1);
    const bar = ui.draw.itemRect();
    const list = ui.draw.itemList();
    const y = bar.min.y;

    var left_buf: [192]u8 = undefined;
    const left = std.fmt.bufPrint(&left_buf, "{s}{s}   ·   {d} entities   ·   {s}", .{
        fileName(ed.scenePath()),
        if (ed.dirty) " *" else "",
        ed.model.entityCount(),
        @tagName(ed.workspace),
    }) catch "editor";
    list.text(.{ .x = bar.min.x, .y = y }, t.colors.text_dim, left);

    // Right cluster, measured and drawn right to left from the bar's edge.
    var tail_buf: [64]u8 = undefined;
    const fps: f32 = if (ed.frame_dt > 0) 1 / ed.frame_dt else 0;
    const tail = std.fmt.bufPrint(&tail_buf, "   ·   {d:.0} fps   ·   {d:.1} ms", .{
        fps,
        ed.frame_dt * 1000.0,
    }) catch "";

    const state = playLabel(ed.play);
    const state_w = ui.draw.textSize(state).x;
    const tail_w = ui.draw.textSize(tail).x;
    const x = bar.max.x - state_w - tail_w;
    list.text(.{ .x = x, .y = y }, playColor(t, ed.play), state);
    list.text(.{ .x = x + state_w, .y = y }, t.colors.text_faint, tail);
}

// ── Shortcuts ──────────────────────────────────────────────────────────────
//
// The labels in the menus are part of the UI, so they have to be true: every
// shortcut printed there is handled here, and nothing is handled that is not
// printed. ImGui owns the keyboard state (the window feeds it, see `ui.keys`),
// so these ask ImGui rather than the platform layer — one input path, and it is
// the one that knows whether a text field is focused.

fn keyPressed(k: ui.keys.Key) bool {
    return cimgui.ember_ui_is_key_pressed(@intFromEnum(k), 0) != 0;
}

fn keyDown(k: ui.keys.Key) bool {
    return cimgui.ember_ui_is_key_down(@intFromEnum(k)) != 0;
}

fn handleShortcuts(ed: *Editor, ctx: *ui.Context) void {
    const ctrl = keyDown(.LeftCtrl) or keyDown(.RightCtrl);
    const shift = keyDown(.LeftShift) or keyDown(.RightShift);

    // Transport keys work even while a field is focused: stopping the scene is
    // not a document edit and must never be swallowed by an editor.
    if (keyPressed(.F5)) {
        if (shift) ed.stop() else ed.togglePlay();
        return;
    }
    if (keyPressed(.F6)) {
        ed.step();
        return;
    }

    // Escape leaves the pick-a-parent mode. It sits with the transport keys
    // because cancelling a mode is not a document edit either.
    if (ed.pick_parent and keyPressed(.Escape)) {
        ed.cancelPickParent();
        ed.log(.info, "pick parent cancelled", .{});
    }

    // Everything below edits the document or the selection, so it waits for the
    // keyboard to be free: Ctrl+S while typing "s" is a save, but a bare "s" is
    // a character.
    if (!ctx.shortcutAllowed()) return;

    if (ctrl and keyPressed(.S)) {
        ed.requestSave();
    } else if (ctrl and keyPressed(.O)) {
        ed.requestOpen();
    } else if (ctrl and keyPressed(.N)) {
        if (shift) ed.requestCreate() else ed.requestNewScene();
    } else if (ctrl and keyPressed(.Z)) {
        if (shift) ed.requestRedo() else ed.requestUndo();
    } else if (ctrl and keyPressed(.Y)) {
        ed.requestRedo();
    } else if (ctrl and keyPressed(.D)) {
        ed.requestDuplicate();
    } else if (keyPressed(.Delete)) {
        ed.requestDelete();
    } else if (keyPressed(.F2)) {
        if (ed.selection) |e| ed.beginRename(e);
    } else if (keyPressed(.Q)) {
        ed.viewport.tool = .cursor;
    } else if (keyPressed(.T)) {
        ed.viewport.tool = .tile;
    } else if (keyPressed(.F)) {
        ed.viewport.centerOnSelection(ed);
    } else if (keyPressed(.Home)) {
        ed.viewport.recenter();
    }
}

// ── Menus ──────────────────────────────────────────────────────────────────

fn drawMenuBar(ctx: *ui.Context) void {
    if (cimgui.ember_ui_begin_menu_bar(cimgui.text("##menubar")) == 0) return;
    defer cimgui.ember_ui_end_menu_bar();

    const ed = ed_mod.active.?;
    const has_selection = ed.selection != null and ed.world().isAlive(ed.selection.?);

    // ── File ──────────────────────────────────────────────────────────────
    if (cimgui.ember_ui_begin_menu(cimgui.text("File"), 1) != 0) {
        if (menuItem("New Scene", "Ctrl+N", true)) ed.requestNewScene();
        if (menuItem("Open Scene…", "Ctrl+O", true)) ed.requestOpen();
        if (menuItem("Save Scene", "Ctrl+S", true)) ed.requestSave();
        _ = cimgui.ember_ui_separator();
        // The reload item is only worth a click when there IS something to
        // take: the scene file changed on disk, or a recovery file is waiting.
        const reload_label: []const u8 = if (ed.autosave_recoverable)
            "Recover Unsaved Work…"
        else if (ed.sceneChangedOnDisk())
            "Reload Scene From Disk"
        else
            "Reload Scene From Disk";
        if (menuItem(reload_label, "", ed.autosave_recoverable or ed.sceneChangedOnDisk())) {
            ed.requestRecoverAutosave();
        }
        if (menuItem("Save Recovery Copy Now", "", true)) ed.requestAutosaveNow();
        _ = cimgui.ember_ui_separator();
        if (menuItem("Quit", "Alt+F4", true)) ed.should_quit = true;
        cimgui.ember_ui_end_menu();
    }

    // ── Edit ──────────────────────────────────────────────────────────────
    if (cimgui.ember_ui_begin_menu(cimgui.text("Edit"), 1) != 0) {
        var und_buf: [64]u8 = undefined;
        var red_buf: [64]u8 = undefined;
        const undo_label = if (ed.model.undoLabel()) |l|
            std.fmt.bufPrint(&und_buf, "Undo {s}", .{l}) catch "Undo"
        else
            "Undo";
        const redo_label = if (ed.model.redoLabel()) |l|
            std.fmt.bufPrint(&red_buf, "Redo {s}", .{l}) catch "Redo"
        else
            "Redo";
        if (menuItem(undo_label, "Ctrl+Z", ed.model.canUndo())) ed.requestUndo();
        if (menuItem(redo_label, "Ctrl+Y", ed.model.canRedo())) ed.requestRedo();
        _ = cimgui.ember_ui_separator();
        if (menuItem("Create Entity", "Ctrl+Shift+N", true)) ed.requestCreate();
        if (menuItem("Duplicate", "Ctrl+D", has_selection)) ed.requestDuplicate();
        if (menuItem("Delete", "Del", has_selection)) ed.requestDelete();
        if (menuItem("Rename", "F2", has_selection)) {
            if (ed.selection) |e| ed.beginRename(e);
        }
        _ = cimgui.ember_ui_separator();
        // Prefabs. "Create" needs a selection (it makes a prefab OF it);
        // "Revert" needs a selection that IS an instance.
        if (menuItem("Create Prefab From Selection", "", has_selection)) ed.requestCreatePrefab();
        if (menuItem("Instantiate Prefab…", "", true)) ed.openPrefabPicker();
        if (menuItem("Revert To Prefab", "", has_selection and ed.selectionIsPrefabInstance())) {
            ed.requestRevertPrefab();
        }
        _ = cimgui.ember_ui_separator();
        if (menuItem("Collision Layer Names…", "", true)) ed.layer_names_open = true;
        cimgui.ember_ui_end_menu();
    }

    // ── View ──────────────────────────────────────────────────────────────
    if (cimgui.ember_ui_begin_menu(cimgui.text("View"), 1) != 0) {
        menuToggle("Hierarchy", &ed.panels.hierarchy);
        menuToggle("Inspector", &ed.panels.inspector);
        menuToggle("Asset Browser", &ed.panels.assets);
        menuToggle("Console", &ed.panels.console);
        menuToggle("TileMap", &ed.panels.tilemap);
        _ = cimgui.ember_ui_separator();
        // The collision overlay is the reactive store's, not the editor's: the
        // render path reads it by name every frame. This menu item is the only
        // control that writes it, and without it the overlay could only be
        // turned on from the command line.
        menuToggleStore(ctx, "Physics Overlay", ui_stores.physics_debug);
        _ = cimgui.ember_ui_separator();
        if (menuItem("Scene", "", ed.workspace != .scene)) ed.workspace = .scene;
        if (menuItem("Script", "", ed.workspace != .script)) ed.workspace = .script;
        _ = cimgui.ember_ui_separator();
        if (menuItem("Reset Layout", "", true)) {
            ed.panels = .{};
            ed.layout = .{};
            ed.workspace = .scene;
        }
        cimgui.ember_ui_end_menu();
    }

    // ── Play ──────────────────────────────────────────────────────────────
    if (cimgui.ember_ui_begin_menu(cimgui.text("Play"), 1) != 0) {
        const play_label: []const u8 = switch (ed.play) {
            .stopped => "Play",
            .playing => "Pause",
            .paused => "Resume",
        };
        if (menuItem(play_label, "F5", true)) ed.togglePlay();
        if (menuItem("Step", "F6", ed.play == .paused)) ed.step();
        if (menuItem("Stop", "Shift+F5", ed.play != .stopped)) ed.stop();
        _ = cimgui.ember_ui_separator();
        var label_buf: [48]u8 = undefined;
        const state = std.fmt.bufPrint(&label_buf, "state: {s}", .{@tagName(ed.play)}) catch "state";
        // A disabled item as a readout: the menu is the cheapest status bar.
        _ = menuItem(state, "", false);
        cimgui.ember_ui_end_menu();
    }
}

/// A plain action item. Returns true on the frame it was clicked.
fn menuItem(label: []const u8, shortcut: []const u8, enabled: bool) bool {
    const flags: c_int = if (enabled) 0 else @intCast(cimgui.MenuItemFlags.Disabled);
    return cimgui.ember_ui_menu_item(
        cimgui.text(label),
        if (shortcut.len > 0) cimgui.text(shortcut) else null,
        null,
        flags,
    ) != 0;
}

/// The reactive store keys the editor's own view state lives under. Constants
/// rather than literals at each use, so a rename is one line and a typo is a
/// second, silently independent checkbox.
const ui_stores = struct {
    pub const physics_debug = "editor.physics_debug";
};

/// A checkbox item whose value is a `reactive.Store` bool. Used for state that
/// the RENDER path reads directly, where a field on `Editor` would be a second
/// source of truth.
fn menuToggleStore(ctx: *ui.Context, label: []const u8, key: []const u8) void {
    var v: c_int = if (ui.reactive.getBool(&ctx.store, key, true)) 1 else 0;
    if (cimgui.ember_ui_menu_item(cimgui.text(label), null, &v, 0) != 0) {
        ctx.store.set(key, bool, v != 0) catch {};
    }
}

/// A checkbox item — the shape a visibility toggle takes in a menu.
fn menuToggle(label: []const u8, value: *bool) void {
    var v: c_int = if (value.*) 1 else 0;
    // The shim flips `selected` itself when the item is clicked, which is why
    // the value is read back rather than inverted here.
    if (cimgui.ember_ui_menu_item(cimgui.text(label), null, &v, 0) != 0) {
        value.* = v != 0;
    }
}

// ── Component picker ───────────────────────────────────────────────────────

fn drawComponentPickerBody(ctx: *ui.Context) void {
    const ed = ed_mod.active.?;
    const world = ed.world();
    const e = ed.component_picker_entity orelse {
        ui.text.caption(ctx, "nothing selected");
        return;
    };

    var buf: [96]u8 = undefined;
    const name = if (world.get(e, ecs.components.Name)) |n| n.slice() else "entity";
    ui.text.caption(ctx, std.fmt.bufPrint(&buf, "add a component to {s}", .{name}) catch "add a component");
    ui.layout.space(ctx, 1);

    var listed: usize = 0;
    inline for (ecs.components.entries, 0..) |entry, i| {
        if (!world.has(e, entry.type)) {
            if (ui.Button(.{
                .ctx = ctx,
                .id = entry.name,
                .text = entry.name,
                .variant = .ghost,
                .width = @max(ui.draw.contentAvail().x, 1),
            })) {
                ed.pending_add_component = @intCast(i);
                ed.component_picker_open = false;
            }
            listed += 1;
        }
    }
    if (listed == 0) ui.text.caption(ctx, "every component is already present");
}
