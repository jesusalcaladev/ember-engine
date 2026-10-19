//! The hierarchy panel — the scene's entity tree.
//!
//! ## What it is, in one line
//!
//! A filtered, indented TREE of the world's live entities, where a click
//! selects, a click on the chevron folds, a double click renames, and the
//! toolbar creates, duplicates and deletes. It reads `Editor.selection` (the
//! UI's own, immediate authority) and writes through `Editor`'s queued
//! actions, because creating and destroying entities journal and therefore
//! allocate — see `editor_state.zig` for why that has to happen outside the
//! frame.
//!
//! ## Indentation is real, and folding is real
//!
//! Depth is read from the `Parent` component, so a child is drawn under its
//! parent with the position the actual scene graph gives it. A collapsed
//! ancestor hides every entity below it: the panel shows what the scene graph
//! shows, not a flat list with indents. The open state lives on the editor
//! keyed by entity index, so an undo that reshuffles slots does not un-fold
//! the tree behind the user's back.
//!
//! ## The scale guards
//!
//! Two passes here are quadratic (`hasChildren` scans the world per row; the
//! ancestor walk scans per row). A 2000-entity scene of a real level is
//! thousands of rows; past that ceiling the panel degrades to the FLAT
//! rendering rather than to a stall — an editor that hangs announcing a big
//! scene is worse than one that shows a list.
//!
//! ## Pick-parent mode
//!
//! `Editor.pick_parent` turns the next row click into "make the selection a
//! child of what was clicked". The mode is entered from the inspector's
//! `Parent` section — drag-and-drop re-parenting is parked with the M-group
//! docking work until the ImGui drag-drop shim exists (grep the shim: there
//! is no BeginDragDropSource in it yet) — and the click that lands is routed
//! through `Editor.pickParentClick`, so one click has one meaning.

const std = @import("std");
const ui = @import("ui");
const cimgui = ui.cimgui;

const ed_mod = @import("editor_state.zig");
const Editor = ed_mod.Editor;
const Entity = ed_mod.Entity;
const ecs = @import("engine").ecs;

/// Past this entity count the panel stops scanning per row (the child search
/// and the ancestor walk are both O(n·something)); it renders the flat list
/// the pre-tree version had. See the module comment.
const tree_limit: usize = 2000;

/// Published for the scroll body (a function pointer cannot close over the
/// editor).
pub var drawing: ?*Editor = null;

fn labelOf(world: *ecs.World, e: Entity, buf: []u8) []const u8 {
    if (world.get(e, ecs.components.Name)) |n| {
        if (n.len > 0) return n.slice();
    }
    return std.fmt.bufPrint(buf, "Entity #{d}", .{e.index}) catch "Entity";
}

/// How deep an entity sits. Bounded: a cycle in `Parent` (which the ECS does
/// not forbid) would otherwise hang the editor, and "the editor hangs on a bad
/// scene" is a worse failure than "the indent looks wrong".
fn depthOf(world: *ecs.World, e: Entity) u16 {
    var depth: u16 = 0;
    var cur = e;
    while (depth < 32) : (depth += 1) {
        const p = world.get(cur, ecs.components.Parent) orelse break;
        if (!world.isAlive(p.parent)) break;
        cur = p.parent;
    }
    return depth;
}

/// A linear scan per row, which is why `tree_limit` exists: the alternative is
/// a per-frame child index, and building one without allocating is work the
/// ECS has not been asked for yet.
fn hasChildren(world: *ecs.World, e: Entity) bool {
    var slot: usize = 0;
    while (slot < world.slotCount()) : (slot += 1) {
        const other = world.entityAtSlot(slot) orelse continue;
        if (world.get(other, ecs.components.Parent)) |p| {
            if (p.parent.index == e.index and p.parent.generation == e.generation) return true;
        }
    }
    return false;
}

/// True when a COLLAPSED ancestor owns this row: the tree does not draw what a
/// fold hides. Bounded, like everything that walks `Parent`.
fn hiddenByFold(world: *ecs.World, ed: *Editor, e: Entity) bool {
    var cur = e;
    var hops: usize = 0;
    while (hops < 32) : (hops += 1) {
        const p = world.get(cur, ecs.components.Parent) orelse return false;
        if (!world.isAlive(p.parent)) return false;
        if (!ed.treeOpen(p.parent)) return true;
        cur = p.parent;
    }
    return false;
}

/// The icon is the most interesting thing on the entity: a camera looks like a
/// camera, a scripted actor has a gear. Three cases, checked in order, and
/// everything else is a file — the point is to make a long list scannable by
/// silhouette, not to enumerate every component.
fn iconOf(world: *ecs.World, e: Entity) ui.icons.Icon {
    if (world.has(e, ecs.components.Camera2D)) return .camera;
    if (world.has(e, ecs.components.Script)) return .gear;
    if (world.has(e, ecs.components.ParticleEmitter2D)) return .dot_;
    if (world.has(e, ecs.components.Light2D)) return .info_;
    return .file;
}

fn containsIgnoreCase(haystack: []const u8, needle: []const u8) bool {
    if (needle.len == 0) return true;
    if (needle.len > haystack.len) return false;
    var i: usize = 0;
    while (i + needle.len <= haystack.len) : (i += 1) {
        var ok = true;
        for (needle, 0..) |c, j| {
            if (std.ascii.toLower(haystack[i + j]) != std.ascii.toLower(c)) {
                ok = false;
                break;
            }
        }
        if (ok) return true;
    }
    return false;
}

fn onRenameEnter(_: ?*anyopaque) void {
    ed_mod.active.?.commitRename();
}

fn scrollBody(ctx: *ui.Context) void {
    const ed = drawing.?;
    const world = ed.world();

    // The row id text: both parts of the handle, because the drop callback
    // reaches the TARGET through it (a row id that drops its generation
    // would survive undos it must not).
    var id_buf: [28]u8 = undefined;
    var label_buf: [64]u8 = undefined;
    var shown: usize = 0;
    const as_tree = world.entityCount() <= tree_limit;

    var slot: usize = 0;
    while (slot < world.slotCount()) : (slot += 1) {
        const e = world.entityAtSlot(slot) orelse continue;
        const label = labelOf(world, e, &label_buf);
        if (!containsIgnoreCase(label, std.mem.sliceTo(&ed.filter_buf, 0))) continue;
        if (as_tree and hiddenByFold(world, ed, e)) continue;

        // The rename row replaces the normal row rather than sitting next to
        // it: two rows for one entity is how a list starts lying about its own
        // length.
        if (ed.renaming) |target| {
            if (target.index == e.index and target.generation == e.generation) {
                _ = ui.input.textField(.{
                    .ctx = ctx,
                    .id = "rename",
                    .buf = &ed.rename_buf,
                    .capacity = @intCast(ed.rename_buf.len - 1),
                    .placeholder = "name",
                    .on_enter = onRenameEnter,
                });
                ui.cimgui.ember_ui_same_line(0, ctx.theme.metrics.gap());
                if (ui.button.icon(.{ .ctx = ctx, .id = "rename.ok", .icon = .check, .variant = .icon, .tooltip = "Rename (Enter)" })) {
                    ed.commitRename();
                }
                ui.cimgui.ember_ui_same_line(0, ctx.theme.metrics.gap());
                if (ui.button.icon(.{ .ctx = ctx, .id = "rename.no", .icon = .close, .variant = .icon, .tooltip = "Cancel (Esc)" })) {
                    ed.cancelRename();
                }
                shown += 1;
                continue;
            }
        }

        const depth = depthOf(world, e);
        const kids = as_tree and hasChildren(world, e);

        // The drag payload, built per row: 8 fixed bytes nobody else writes.
        var entity_bytes: [8]u8 = undefined;
        ed_mod.encodeEntity(e, &entity_bytes);

        const r = ui.list.row(
            .{
                // The id carries both parts of the handle, because the drop
                // callback reaches the TARGET through it — a plain index
                // would name a row that a subsequent undo could re-point.
                .id = std.fmt.bufPrint(&id_buf, "e{d}g{d}", .{ e.index, e.generation }) catch "ent",
                .label = label,
                .icon = if (kids) (if (ed.treeOpen(e)) .chevron_down else .chevron_right) else iconOf(world, e),
                .depth = depth,
                .selected = isSelected(ed, e),
                .trailing = if (world.has(e, ecs.components.Sprite)) "sprite" else "",
                .drag = .{ .kind = ed_mod.drag_kinds.entity, .data = &entity_bytes, .preview = label },
                .drop = &drop_kinds,
            },
            .{ .ctx = ctx, .on_drop = onRowDrop },
        );

        // Pick-parent mode: the click re-parents instead of selecting, and the
        // banner (drawn by `draw`) tells the user that is the deal.
        if (r.clicked and !ed.pickParentClick(e)) {
            shown += 1;
            continue;
        }
        if (r.clicked) ed.select(e);
        if (r.activated) ed.beginRename(e);

        // Fold chevron for parents, laid OVER the row's own icon cell: the row
        // is already drawn, so the chevron is a small button stacked on top of
        // its leftmost part — the topmost item wins the click, the row keeps
        // its full-width selection fill, and both stay hit-testable. The
        // layout cursor is saved and restored, because the next row's
        // position is "wherever the previous one ended", not "wherever the
        // chevron moved it".
        if (kids) {
            var after_row: [2]f32 = undefined;
            cimgui.ember_ui_get_cursor_pos(&after_row);
            const cx = r.rect.min.x + ctx.theme.metrics.pad_x() + @as(f32, @floatFromInt(depth)) * 16.0;
            cimgui.ember_ui_set_cursor_pos(cx, r.rect.min.y);
            cimgui.ember_ui_push_id_str(cimgui.textLit("fold##"));
            _ = cimgui.ember_ui_push_id_int(@intCast(e.index));
            if (cimgui.ember_ui_invisible_button("chev", 16, r.rect.max.y - r.rect.min.y, 0) != 0) {
                ed.toggleTree(e);
            }
            cimgui.ember_ui_pop_id();
            cimgui.ember_ui_pop_id();
            cimgui.ember_ui_set_cursor_pos(after_row[0], after_row[1]);
        }
        shown += 1;
    }

    if (shown == 0) {
        ui.text.caption(ctx, if (world.entityCount() == 0) "the scene is empty" else "no entity matches the filter");
    }
}

/// Is this entity in the selection?
///
/// The whole SET, not just the current object: a multi-selection the
/// hierarchy does not show is a multi-selection the user cannot see.
fn isSelected(ed: *Editor, e: Entity) bool {
    return ed.isSelected(e);
}

/// The kinds a hierarchy row accepts, declared once — the row's `drop` needs a
/// stable address for the duration of the frame, and every row shares it.
const drop_kinds = [_][:0]const u8{ ed_mod.drag_kinds.entity, ed_mod.drag_kinds.file };

/// `e{index}g{generation}` — the inverse of the row id the tree writes.
fn parseRowEntity(row_id: []const u8) ?Entity {
    if (row_id.len < 3 or row_id[0] != 'e') return null;
    const gen_pos = std.mem.indexOfScalar(u8, row_id, 'g') orelse return null;
    const index = std.fmt.parseInt(u32, row_id[1..gen_pos], 10) catch return null;
    const gen = std.fmt.parseInt(u32, row_id[gen_pos + 1 ..], 10) catch return null;
    return Entity{ .index = index, .generation = gen };
}

/// What a drop on a row means, once, for both payload kinds:
/// an entity drop re-parents THE DRAGGED entity under the row's entity
/// (with the editor's cycle guard sitting in `reparent`), a FILE drop takes
/// the payload's extension: an image spawns a sprite child, a scene opens.
///
/// It runs inside the frame, so it only writes pending state — the acts land
/// in `preFrame`, outside the allocation guard, like always.
fn onRowDrop(arg: ?*anyopaque, row_id: []const u8, kind: []const u8, payload: []const u8) void {
    _ = arg;
    const ed = drawing orelse return;
    const target = parseRowEntity(row_id) orelse return;
    const w = ed.world();
    if (!w.isAlive(target)) return;

    if (std.mem.eql(u8, kind, ed_mod.drag_kinds.entity)) {
        const child = ed_mod.decodeEntity(payload) orelse return;
        if (child.index == target.index and child.generation == target.generation) return;
        if (!w.isAlive(child)) return;
        ed.pending_reparent_child = child;
        ed.pending_reparent_parent = target;
        return;
    }

    if (std.mem.eql(u8, kind, ed_mod.drag_kinds.file)) {
        // The payload is a NUL-terminated relative path.
        const path = std.mem.sliceTo(payload, 0);
        if (path.len == 0) return;
        const ext = extOf(path);
        if (std.ascii.eqlIgnoreCase(ext, "zson")) {
            ed.openFile(path);
        } else if (isImageExt(ext)) {
            ed.requestSpawnSpriteUnder(path, target);
        } else {
            ed.log(.warn, "'{s}': no importer for this file kind yet", .{path});
        }
    }
}

fn extOf(path: []const u8) []const u8 {
    const name = if (std.mem.lastIndexOfScalar(u8, path, '/')) |slash| path[slash + 1 ..] else path;
    const dot = std.mem.lastIndexOfScalar(u8, name, '.') orelse return "";
    return name[dot + 1 ..];
}

fn isImageExt(ext: []const u8) bool {
    inline for (.{ "png", "jpg", "jpeg", "bmp", "tga", "webp" }) |img| {
        if (std.ascii.eqlIgnoreCase(ext, img)) return true;
    }
    return false;
}

pub fn draw(ed: *Editor, ctx: *ui.Context) void {
    drawing = ed;
    const world = ed.world();

    // Toolbar. Icons only: the panel is 260px wide and "Create Entity" as a
    // caption is a third of it.
    if (ui.button.icon(.{ .ctx = ctx, .id = "h.create", .icon = .plus, .variant = .ghost, .tooltip = "Create entity" })) {
        ed.requestCreate();
    }
    ui.cimgui.ember_ui_same_line(0, 2);
    if (ui.button.icon(.{ .ctx = ctx, .id = "h.dup", .icon = .copy, .variant = .ghost, .tooltip = "Duplicate (Ctrl+D)" })) {
        ed.requestDuplicate();
    }
    ui.cimgui.ember_ui_same_line(0, 2);
    if (ui.button.icon(.{ .ctx = ctx, .id = "h.del", .icon = .trash, .variant = .ghost, .tooltip = "Delete (Del)" })) {
        ed.requestDelete();
    }
    ui.cimgui.ember_ui_same_line(0, 2);
    if (ui.button.icon(.{ .ctx = ctx, .id = "h.openall", .icon = .chevron_down, .variant = .icon, .tooltip = "Expand all" })) {
        ed.setAllTreeOpen(true);
    }
    ui.cimgui.ember_ui_same_line(0, 2);
    if (ui.button.icon(.{ .ctx = ctx, .id = "h.closeall", .icon = .chevron_right, .variant = .icon, .tooltip = "Collapse all" })) {
        ed.setAllTreeOpen(false);
    }
    ui.cimgui.ember_ui_same_line(0, ctx.theme.metrics.gap());
    ui.text.caption(ctx, std.fmt.bufPrint(&count_buf, "{d} entities", .{world.entityCount()}) catch "");

    ui.layout.space(ctx, 1);
    _ = ui.input.search(.{
        .ctx = ctx,
        .id = "h.filter",
        .buf = &ed.filter_buf,
        .capacity = @intCast(ed.filter_buf.len),
        .placeholder = "Search entities…",
    });

    // The pick-parent banner. An affordance that changes what a click does
    // with no visible notice is a bug wearing an editor's clothes.
    if (ed.pick_parent) {
        ui.layout.space(ctx, 1);
        const t = &ctx.theme;
        var buf: [128]u8 = undefined;
        const child = ed.selection.?;
        const name = if (world.get(child, ecs.components.Name)) |n| n.slice() else "select";
        const msg = std.fmt.bufPrint(&buf, "picking parent for {s} — Esc to cancel", .{name}) catch "picking parent";
        const list = ui.draw.itemList();
        const rect_min = ui.draw.cursorPos();
        const w = @max(ui.draw.contentAvail().x, 1);
        const h = ctx.theme.metrics.row_h();
        list.rect(ui.draw.rect(rect_min.x, rect_min.y, rect_min.x + w, rect_min.y + h), t.colors.warning.withAlpha(0.15), t.metrics.radius_sm());
        list.text(.{ .x = rect_min.x + t.metrics.pad_x(), .y = rect_min.y + (h - 14) * 0.5 }, t.colors.warning, msg);
        cimgui.ember_ui_dummy(w, h);
    }

    ui.layout.space(ctx, 1);
    _ = ui.list.scrollable(ctx, "h.scroll", -1, scrollBody);
}

var count_buf: [40]u8 = undefined;
