//! The component inspector — the property grid for the selected entity.
//!
//! ## What it draws
//!
//! For the currently selected entity: every component it has, as a `Collapse`
//! section, with each field wired to the correct widget. The widget writes into
//! a local copy of the component, and on commit the copy is handed to
//! `Editor.queueSet`, which journals it through `session.Model.set` (undo/redo
//! is not a separate system — it is the model's journal, and every widget uses
//! it).
//!
//! ## No reflection, no magic
//!
//! Zig has no reflection, and the registry is a comptime table, not a runtime
//! one. So the inspector IS a comptime `switch` on the component type id,
//! expanding to a hand-written field list per component. Adding a component
//! means adding one case here — exactly the same amount of work as adding a
//! field to a class in a language with reflection, and the result is code you
//! can read, debug and inline.
//!
//! The mapping is explicit:
//! - `f32` → `NumberField`
//! - `Vec2` → two `NumberField`s side by side on one row
//! - `[4]f32` → `ColorField` (tint, light colour)
//! - `u8` / `u16` / `u32` / `i32` → `NumberField` through an integer adapter
//! - `bool` → `Checkbox`
//! - enums → `Select`
//! - handles (`Entity`, script ids) → read-only text
//!
//! Curves and arrays of unknown length are not here yet (ROADMAP: curve editor).

const std = @import("std");
const ui = @import("ui");

const ed_mod = @import("editor_state.zig");
const Editor = ed_mod.Editor;
const Entity = ed_mod.Entity;
const ecs = @import("engine").ecs;

/// Published for the scroll body. `ui.list.scrollable` takes a plain function
/// pointer and Zig has no closures, so the editor is reachable through this
/// for the duration of one frame. See `editor_state.zig`.
pub var drawing: ?*Editor = null;

/// The width of the label column, in points. One number, one column: the whole
/// point of an inspector is that the values line up.
const label_w: f32 = 76.0;

pub fn draw(ed: *Editor, ctx: *ui.Context) void {
    drawing = ed;
    _ = ui.list.scrollable(ctx, "insp.scroll", -1, scrollBody);
}

fn scrollBody(ctx: *ui.Context) void {
    const ed = drawing.?;
    const w = ed.world();
    const e = ed.selection orelse {
        ui.text.caption(ctx, "no entity selected");
        return;
    };

    if (!w.isAlive(e)) {
        ui.text.caption(ctx, "the selected entity no longer exists");
        return;
    }

    // Header: what is selected, in the same shape as a list row. Without it a
    // scrolled inspector is a column of fields with no subject.
    var head_buf: [96]u8 = undefined;
    const label = if (w.get(e, ecs.components.Name)) |n|
        n.slice()
    else
        std.fmt.bufPrint(&head_buf, "Entity #{d}", .{e.index}) catch "Entity";
    ui.text.title(ctx, label);
    var id_buf: [48]u8 = undefined;
    ui.text.caption(ctx, std.fmt.bufPrint(&id_buf, "id {d}:{d}", .{ e.index, e.generation }) catch "");

    ui.layout.space(ctx, 1);

    var shown: usize = 0;
    inline for (ecs.components.entries, 0..) |entry, i| {
        if (w.has(e, entry.type)) {
            drawComponent(ctx, ed, e, entry.type, @as(u16, @intCast(i)));
            shown += 1;
        }
    }
    if (shown == 0) {
        ui.text.caption(ctx, "no components");
        ui.layout.space(ctx, 1);
    }

    // The prefab section: where the entity came from, what was changed on it
    // since, and the button that puts the prefab's values back.
    drawPrefabSection(ctx, ed, e);

    if (ui.Button(.{
        .ctx = ctx,
        .id = "insp.add",
        .text = "Add Component",
        .icon = .plus,
        .variant = .ghost,
        .width = @max(ui.draw.contentAvail().x, 1),
    })) {
        ed.pending_add_component_list = true;
    }
}

/// The prefab section of the inspector.
///
/// It shows three things and one button: the file the entity was instantiated
/// from, the fields that were changed since, and "Revert to Prefab" — which
/// writes the prefab's values back over exactly those fields.
///
/// The overrides are read from the SIDECAR, not computed by comparing the
/// entity with the prefab file on the spot. That is deliberate: the sidecar
/// says what the user changed, and the comparison would say what DIFFERS —
/// which is not the same thing. A field the user changed and changed back is
/// not an override, and the sidecar knows that because the second change
/// replaced the first.
fn drawPrefabSection(ctx: *ui.Context, ed: *Editor, e: Entity) void {
    const inst = ed.prefabOf(e) orelse return;

    var buf: [160]u8 = undefined;
    ui.text.caption(ctx, std.fmt.bufPrint(&buf, "prefab: {s}", .{inst.prefab}) catch "prefab");

    const overrides = ed.overridesOf(e);
    defer ed.allocator.free(overrides);

    if (overrides.len == 0) {
        ui.text.caption(ctx, "no overrides — this instance matches the prefab");
    } else {
        for (overrides) |o| {
            var row: [160]u8 = undefined;
            ui.text.caption(ctx, std.fmt.bufPrint(&row, "{s}.{s} = {s}", .{
                o.component,
                o.field,
                o.value,
            }) catch "override");
        }
    }

    if (ui.Button(.{
        .ctx = ctx,
        .id = "insp.prefab.revert",
        .text = "Revert to Prefab",
        .icon = .undo,
        .variant = .ghost,
        .width = @max(ui.draw.contentAvail().x, 1),
        .disabled = overrides.len == 0,
    })) {
        ed.requestRevertPrefab();
    }
}

fn drawComponent(ctx: *ui.Context, ed: *Editor, e: Entity, comptime T: type, id: u16) void {
    const w = drawing.?.world();
    const comp = w.get(e, T) orelse return;

    // A local copy the widgets write into. On any change the whole struct is
    // handed to the journal: one drag is one undo act because `Model.set`
    // coalesces on (entity, component), not because the inspector batches.
    var local: T = comp.*;

    var open = ed.insp_open[id];
    _ = ui.card.collapse(.{
        .ctx = ctx,
        .id = entryName(T),
        .label = entryName(T),
        .open = &open,
        .icon = iconFor(T),
    });
    ed.insp_open[id] = open;
    if (!open) return;

    var changed = false;
    switch (T) {
        ecs.components.Transform => {
            changed |= drawVec2(ctx, "Position", &local.position, 0.1, "px");
            changed |= drawFloat(ctx, "Rotation", &local.rotation, 0.01, "rad", -std.math.pi, std.math.pi);
            changed |= drawVec2(ctx, "Scale", &local.scale, 0.01, "");
        },
        ecs.components.Sprite => {
            changed |= drawInt(ctx, "Atlas", &local.atlas, 0, 255);
            changed |= drawInt(ctx, "Layer", &local.layer, 0, 65535);
            changed |= drawVec2(ctx, "Size", &local.size, 0.1, "px");
            changed |= drawEnum(ctx, "Shape", ecs.components.SpriteShape, &local.shape, &.{ "quad", "circle" });
            changed |= drawColor(ctx, "Tint", &local.tint, true);
            changed |= drawEnum(ctx, "Blend", ecs.components.Blend, &local.blend, &.{ "solid", "alpha", "additive" });
            changed |= drawInt(ctx, "Order", &local.order, -1_000_000, 1_000_000);
            changed |= drawVec4(ctx, "UV", &local.uv, 0.01);
            changed |= drawBool(ctx, "spr.vis", "Visible", &local.visible);
        },
        ecs.components.RigidBody2D => {
            changed |= drawSelectU8(ctx, "Type", "body_type", &local.body_type, &.{ "fixed", "kinematic", "dynamic" });
            changed |= drawVec2(ctx, "Linear Vel", &local.linear_velocity, 1.0, "px/s");
            changed |= drawFloat(ctx, "Angular Vel", &local.angular_velocity, 0.1, "rad/s", -100, 100);
            changed |= drawFloat(ctx, "Linear Damp", &local.linear_damping, 0.01, "", 0, 100);
            changed |= drawFloat(ctx, "Angular Damp", &local.angular_damping, 0.01, "", 0, 100);
            changed |= drawFloat(ctx, "Gravity Scale", &local.gravity_scale, 0.1, "", 0, 10);
            changed |= drawBool(ctx, "rb.frot", "Fixed Rotation", &local.fixed_rotation);
            changed |= drawBool(ctx, "rb.sleep", "Allow Sleep", &local.allow_sleep);
            changed |= drawBool(ctx, "rb.bullet", "Bullet", &local.is_bullet);
            // The handle is solver state, not scene data: shown so the user can
            // tell "no body" from "body 4", and never edited.
            drawHandle(ctx, "Body", local.body);
        },
        ecs.components.Collider2D => {
            changed |= drawSelectU8(ctx, "Kind", "collider_kind", &local.kind, &.{ "box", "circle", "capsule", "cylinder", "polygon" });
            changed |= drawVec2(ctx, "Size", &local.size, 0.1, "px");
            changed |= drawVec2(ctx, "Offset", &local.offset, 0.1, "px");
            changed |= drawFloat(ctx, "Density", &local.density, 0.01, "", 0, 100);
            changed |= drawFloat(ctx, "Friction", &local.friction, 0.01, "", 0, 10);
            changed |= drawFloat(ctx, "Restitution", &local.restitution, 0.01, "", 0, 1);
            changed |= drawBool(ctx, "col.sensor", "Is Sensor", &local.is_sensor);
            drawHandle(ctx, "Shape", local.shape);
        },
        ecs.components.CollisionLayers => {
            // Godot's layer/mask editor: named bit cells for "who I am"
            // (layer) and "who I collide with" (mask), plus the same summary
            // text under each, so a wrong mask is readable without decoding
            // hex. The physics system reads this pair verbatim (see
            // `physics.system.filterFor`), so editing here IS configuring.
            changed |= drawMaskBits(ctx, ed, "cl.layer", "Layer", &local.layer);
            ui.layout.space(ctx, 0.2);
            changed |= drawMaskBits(ctx, ed, "cl.mask", "Mask", &local.mask);
            ui.layout.space(ctx, 0.2);
            if (ui.Button(.{
                .ctx = ctx,
                .id = "cl.names",
                .text = "Layer Names…",
                .icon = .layers,
                .variant = .ghost,
            })) {
                ed.layer_names_open = true;
            }
        },
        ecs.components.Velocity => {
            changed |= drawVec2(ctx, "Linear", &local.linear, 0.1, "px/s");
            changed |= drawFloat(ctx, "Angular", &local.angular, 0.01, "rad/s", -100, 100);
        },
        ecs.components.Camera2D => {
            changed |= drawFloat(ctx, "Zoom", &local.zoom, 0.01, "", local.min_zoom, local.max_zoom);
            changed |= drawFloat(ctx, "Damping", &local.damping, 0.1, "", 0, 100);
            changed |= drawFloat(ctx, "Look Ahead", &local.look_ahead, 0.1, "s", 0, 10);
            changed |= drawVec2(ctx, "Deadzone Pos", &local.deadzone.position, 1.0, "px");
            changed |= drawVec2(ctx, "Deadzone Size", &local.deadzone.size, 1.0, "px");
            changed |= drawBool(ctx, "cam.follow", "Follow Enabled", &local.follow_enabled);
            changed |= drawBool(ctx, "cam.enabled", "Enabled", &local.enabled);
        },
        ecs.components.Timer => {
            changed |= drawEnum(ctx, "Type", ecs.components.TimerType, &local.kind, &.{ "once", "loop", "during" });
            changed |= drawFloat(ctx, "Duration", &local.duration, 0.01, "s", 0, 1000);
            changed |= drawFloat(ctx, "Elapsed", &local.elapsed, 0.01, "s", 0, 1000);
            changed |= drawInt(ctx, "Loop Count", &local.loop_count, 0, 1000);
            changed |= drawBool(ctx, "tm.paused", "Paused", &local.paused);
        },
        ecs.components.Light2D => {
            changed |= drawEnum(ctx, "Kind", ecs.components.LightKind, &local.kind, &.{ "point", "spot", "directional", "ambient" });
            changed |= drawColor(ctx, "Color", &local.color, true);
            changed |= drawFloat(ctx, "Energy", &local.energy, 0.1, "", 0, 1000);
            changed |= drawVec2(ctx, "Offset", &local.offset, 1.0, "px");
            changed |= drawFloat(ctx, "Radius", &local.radius, 1.0, "px", 0, 5000);
            changed |= drawFloat(ctx, "Angle", &local.angle, 0.01, "rad", -std.math.pi, std.math.pi);
            changed |= drawFloat(ctx, "Cone Angle", &local.cone_angle, 0.01, "rad", 0, std.math.pi);
            changed |= drawFloat(ctx, "Penumbra", &local.penumbra, 0.01, "", 0, 1);
            changed |= drawFloat(ctx, "Attenuation", &local.attenuation, 0.01, "", 0, 10);
            changed |= drawEnum(ctx, "Blend", ecs.components.LightBlend, &local.blend, &.{ "add", "subtract", "mix" });
            changed |= drawBool(ctx, "lt.shadow", "Cast Shadows", &local.cast_shadows);
            changed |= drawEnum(ctx, "Shadow Filter", ecs.components.ShadowFilter, &local.shadow_filter, &.{ "off", "pcf1", "pcf3", "pcf5" });
            changed |= drawFloat(ctx, "Shadow Smooth", &local.shadow_filter_smooth, 0.1, "px", 0, 16);
        },
        ecs.components.Script => {
            // A handle, not data: the code pane is where a script is edited.
            drawHandle(ctx, "Script", local.script);
        },
        ecs.components.StateMachine => {
            drawHandle(ctx, "Machine", local.machine);
            changed |= drawBool(ctx, "sm.started", "Started", &local.started);
        },
        ecs.components.Parent => {
            const parent = local.parent;
            const alive = w.isAlive(parent);
            if (alive) {
                if (w.get(parent, ecs.components.Name)) |pn| {
                    var buf: [64]u8 = undefined;
                    readOnly(ctx, "Parent", std.fmt.bufPrint(&buf, "{s} #{d}", .{ pn.slice(), parent.index }) catch "?");
                } else {
                    readOnly(ctx, "Parent", "(unnamed)");
                }
            } else {
                readOnly(ctx, "Parent", "(root)");
            }
            // The re-parent controls. The handle itself is scene structure, not
            // a number: editing it means picking another entity, which is what
            // these buttons drive (the picker runs in the hierarchy panel).
            if (alive) {
                if (ui.Button(.{
                    .ctx = ctx,
                    .id = "parent.detach",
                    .text = "Detach",
                    .icon = .unlink,
                    .variant = .ghost,
                })) ed.requestDetach();
                ui.cimgui.ember_ui_same_line(0, ctx.theme.metrics.gap());
            }
            if (ui.Button(.{
                .ctx = ctx,
                .id = "parent.pick",
                .text = "Set Parent…",
                .icon = .link,
                .variant = if (ed.pick_parent) .primary else .ghost,
                .tooltip = "Click an entity in the hierarchy to make it the parent",
            })) ed.requestSetParent();
            if (ed.pick_parent) {
                ui.text.caption(ctx, "picking… click an entity in the hierarchy (Esc to cancel)");
            }
        },
        else => {
            // Honest fallback: name and size, not an empty section. The user can
            // see the component exists even when its editor has not been written.
            var buf: [96]u8 = undefined;
            ui.text.caption(ctx, std.fmt.bufPrint(&buf, "no field editor yet ({d} bytes)", .{@sizeOf(T)}) catch "no field editor yet");
        },
    }

    if (changed) ed.queueSet(e, T, local);

    ui.layout.space(ctx, 0.5);
    if (ui.Button(.{
        .ctx = ctx,
        .id = "insp.rm",
        .text = "Remove",
        .icon = .trash,
        .variant = .ghost,
    })) {
        ed.pending_remove_component = id;
    }
    ui.layout.space(ctx, 1);

    // The indent `collapse` opened is closed here, INSIDE the open branch: a
    // close that runs when the section is collapsed unindents a level that was
    // never opened, and the rest of the panel slides left one level per click.
    ui.card.collapseEnd(ctx);
}

/// The registry name of a type, without assuming a name mangling scheme: the
/// registry is the one place that knows what a component is called in a file.
fn entryName(comptime T: type) []const u8 {
    inline for (ecs.components.entries) |entry| {
        if (entry.type == T) return entry.name;
    }
    return @tagName(T);
}

fn iconFor(comptime T: type) ?ui.icons.Icon {
    return switch (T) {
        ecs.components.Transform => .drag,
        ecs.components.Sprite => .file,
        ecs.components.RigidBody2D => .layers,
        ecs.components.Collider2D => .grid,
        ecs.components.Velocity => .drag,
        ecs.components.Camera2D => .camera,
        ecs.components.Timer => .info_,
        ecs.components.Light2D => .info_,
        ecs.components.Script => .gear,
        ecs.components.StateMachine => .layers,
        ecs.components.Name => .file,
        ecs.components.Parent => .link,
        ecs.components.CollisionLayers => .list_,
        else => null,
    };
}

// ── Field drawers ──────────────────────────────────────────────────────────

/// Side of one cell in the layer grid, in points.
const mask_cell: f32 = 24.0;

/// Godot's collision layer grid, inline: sixteen cells, one per bit of the
/// mask, each labelled with its bit number and named by `Editor.layerName`.
/// A click toggles the bit; the summary under the grid is the named list.
///
/// The label column is the same as every other field's, so the panel stays a
/// table; the cells are fixed-width because sixteen of them cannot share a
/// row's free width and stay clickable.
fn drawMaskBits(ctx: *ui.Context, ed: *ed_mod.Editor, id: []const u8, label: []const u8, v: *u16) bool {
    const t = &ctx.theme;
    const m = t.metrics;

    // The label slot, then the summary the slot cannot hold.
    ui.widget.labelSlot(t, label, label_w, m.row_h());
    var sum_buf: [192]u8 = undefined;
    ui.text.caption(ctx, ed.describeMask(v.*, &sum_buf));
    ui.layout.space(ctx, 0.2);

    var changed = false;
    var i: usize = 0;
    while (i < ed_mod.layer_bits) : (i += 1) {
        const col = i % 8;
        if (col != 0) ui.cimgui.ember_ui_same_line(0, 2);

        var id_buf: [48]u8 = undefined;
        const cell_id = std.fmt.bufPrint(&id_buf, "{s}.{d}", .{ id, i }) catch id;
        var num_buf: [8]u8 = undefined;
        const num = std.fmt.bufPrintZ(&num_buf, "{d}", .{i + 1}) catch "?";
        const on = (v.* >> @intCast(i)) & 1 == 1;
        if (ui.Button(.{
            .ctx = ctx,
            .id = cell_id,
            .text = num,
            .variant = if (on) .primary else .ghost,
            .width = mask_cell,
        })) {
            v.* ^= @as(u16, 1) << @intCast(i);
            changed = true;
        }
        // The name is the tooltip: the cell is one digit, the meaning is the
        // name the user gave.
        if (ui.cimgui.ember_ui_is_item_hovered(ui.cimgui.HoveredFlags.None) != 0) {
            var tip_buf: [80]u8 = undefined;
            const tip = std.fmt.bufPrintZ(&tip_buf, "bit {d} — {s}", .{ i, ed.layerName(i) }) catch "bit";
            ui.cimgui.ember_ui_set_tooltip(tip.ptr);
        }
    }
    return changed;
}

/// Text in a field slot. For handles and derived values: read-only, but drawn
/// with the same label column as everything else, so the panel stays a table.
fn readOnly(ctx: *ui.Context, label: []const u8, value: []const u8) void {
    ui.widget.labelSlot(&ctx.theme, label, label_w, ctx.theme.metrics.row_h());
    ui.text.caption(ctx, value);
}

fn drawHandle(ctx: *ui.Context, label: []const u8, handle: anytype) void {
    var buf: [32]u8 = undefined;
    const text = if (handle == std.math.maxInt(@TypeOf(handle)))
        "(none)"
    else
        std.fmt.bufPrint(&buf, "{d}", .{handle}) catch "?";
    readOnly(ctx, label, text);
}

fn drawVec2(ctx: *ui.Context, label: []const u8, v: *ecs.components.Vec2, speed: f32, unit: []const u8) bool {
    const gap = ctx.theme.metrics.gap();
    var changed = false;
    ui.widget.labelSlot(&ctx.theme, label, label_w, ctx.theme.metrics.row_h());

    // The two mini-labels are drawn HERE, not by the field.
    //
    // A field's own label slot is an ABSOLUTE offset from the line's start,
    // and this row has already spent that column on "Position": the field
    // would place itself at the line's start + 16 and draw its box on top of
    // the row's label. Which is exactly what it did — the position values
    // were unreadable because the box was sitting on the label.
    const slot: f32 = 13;
    // Two mini-labels and two fields have to fit in what is left of the row.
    const avail = @max(ui.draw.contentAvail().x, 40);
    const w = @max((avail - 2.0 * (slot + gap) - gap) * 0.5, 26);

    // `label` is a runtime slice (it comes from the caller's field list), so
    // the ids are assembled here instead of with `++`, which is comptime-only.
    var id_buf: [64]u8 = undefined;
    const id_x = std.fmt.bufPrint(&id_buf, "{s}.x", .{label}) catch label;
    ui.widget.labelSlotRelative(&ctx.theme, "X", slot, ctx.theme.metrics.row_h());
    changed |= ui.input.numberField(.{ .ctx = ctx, .id = id_x, .value = &v.x, .speed = speed, .unit = unit, .width = w });

    ui.cimgui.ember_ui_same_line(0, gap);
    var id_buf2: [64]u8 = undefined;
    const id_y = std.fmt.bufPrint(&id_buf2, "{s}.y", .{label}) catch label;
    ui.widget.labelSlotRelative(&ctx.theme, "Y", slot, ctx.theme.metrics.row_h());
    changed |= ui.input.numberField(.{ .ctx = ctx, .id = id_y, .value = &v.y, .speed = speed, .unit = unit, .width = w });
    return changed;
}

fn drawVec4(ctx: *ui.Context, label: []const u8, v: *[4]f32, speed: f32) bool {
    const gap = ctx.theme.metrics.gap();
    var changed = false;
    ui.widget.labelSlot(&ctx.theme, label, label_w, ctx.theme.metrics.row_h());
    const avail = @max((ui.draw.contentAvail().x - gap * 3) * 0.25, 24);
    inline for (.{ "u0", "v0", "u1", "v1" }, 0..) |name, i| {
        if (i != 0) ui.cimgui.ember_ui_same_line(0, gap);
        changed |= ui.input.numberField(.{
            .ctx = ctx,
            .id = name,
            .label = "",
            .label_slot = 0,
            .value = &v[i],
            .speed = speed,
            .min = 0,
            .max = 1,
            .width = avail,
        });
    }
    return changed;
}

fn drawFloat(ctx: *ui.Context, label: []const u8, v: *f32, speed: f32, unit: []const u8, min: f32, max: f32) bool {
    return ui.input.numberField(.{
        .ctx = ctx,
        .id = label,
        .label = label,
        .value = v,
        .speed = speed,
        .min = min,
        .max = max,
        .format = if (speed < 0.01) "%.4f" else "%.3f",
        .label_slot = label_w,
        .unit = unit,
    });
}

/// An integer field. ImGui's drag widgets are float-only, so the round trip is
/// explicit and clamped: a drag past the end of a `u8` must saturate, not wrap.
fn drawInt(ctx: *ui.Context, label: []const u8, v: anytype, min: f32, max: f32) bool {
    var f: f32 = @floatFromInt(v.*);
    if (!ui.input.numberField(.{
        .ctx = ctx,
        .id = label,
        .label = label,
        .value = &f,
        .speed = 1,
        .min = min,
        .max = max,
        .format = "%.0f",
        .label_slot = label_w,
    })) return false;
    const rounded = std.math.clamp(@round(f), min, max);
    v.* = @intFromFloat(rounded);
    return true;
}

fn drawBool(ctx: *ui.Context, id: []const u8, label: []const u8, v: *bool) bool {
    return ui.toggle.checkbox(.{ .ctx = ctx, .id = id, .label = label, .value = v });
}

fn drawColor(ctx: *ui.Context, label: []const u8, c: *[4]f32, show_alpha: bool) bool {
    var rgba = ui.Rgba{ .r = c[0], .g = c[1], .b = c[2], .a = c[3] };
    const changed = ui.color.field(.{
        .ctx = ctx,
        .id = label,
        .label = label,
        .value = &rgba,
        .show_alpha = show_alpha,
    });
    if (changed) {
        c[0] = rgba.r;
        c[1] = rgba.g;
        c[2] = rgba.b;
        c[3] = rgba.a;
    }
    return changed;
}

/// An enum field. The labels are positional, so the enum's declaration order is
/// the wire format of this inspector — which is why every enum used here is a
/// plain `enum(u8)` whose order is already the serialized order.
fn drawEnum(ctx: *ui.Context, label: []const u8, comptime E: type, v: *E, comptime labels: []const []const u8) bool {
    var opts: [16]ui.select.Option = undefined;
    inline for (labels, 0..) |name, i| {
        opts[i] = .{ .value = i, .label = name };
    }
    var idx: usize = @intFromEnum(v.*);
    if (!ui.select.select(.{
        .ctx = ctx,
        .id = label,
        .label = label,
        .options = opts[0..labels.len],
        .selected = &idx,
        .label_slot = label_w,
    })) return false;
    if (idx >= labels.len) return false;
    v.* = @enumFromInt(idx);
    return true;
}

/// The same, for a component that stores its choice as a raw `u8` (the physics
/// components do, because the byte IS the backend's enum).
fn drawSelectU8(ctx: *ui.Context, label: []const u8, id: []const u8, v: *u8, comptime labels: []const []const u8) bool {
    var opts: [16]ui.select.Option = undefined;
    inline for (labels, 0..) |name, i| {
        opts[i] = .{ .value = i, .label = name };
    }
    var idx: usize = v.*;
    if (!ui.select.select(.{
        .ctx = ctx,
        .id = id,
        .label = label,
        .options = opts[0..labels.len],
        .selected = &idx,
        .label_slot = label_w,
    })) return false;
    if (idx >= labels.len) return false;
    v.* = @intCast(idx);
    return true;
}

const testing = std.testing;

test "inspector: every enum label list matches its enum" {
    // The labels are positional. A list that is shorter than the enum silently
    // makes the last values unreachable; a longer one is a label for a value
    // that cannot exist. Both are compile-time-checkable here, at the source.
    try testing.expectEqual(@typeInfo(ecs.components.SpriteShape).@"enum".fields.len, 2);
    try testing.expectEqual(@typeInfo(ecs.components.Blend).@"enum".fields.len, 3);
    try testing.expectEqual(@typeInfo(ecs.components.TimerType).@"enum".fields.len, 3);
    try testing.expectEqual(@typeInfo(ecs.components.LightKind).@"enum".fields.len, 4);
    try testing.expectEqual(@typeInfo(ecs.components.LightBlend).@"enum".fields.len, 3);
    try testing.expectEqual(@typeInfo(ecs.components.ShadowFilter).@"enum".fields.len, 4);
}
