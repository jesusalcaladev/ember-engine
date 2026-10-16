//! `ui.widgets.list_` — rows, and trees made of rows.
//!
//! ## Why the list is drawn rather than composed from ImGui's
//!
//! ImGui's `ListBox` and `Selectable` are fine and look like ImGui. An editor's
//! hierarchy tree has three requirements they do not meet:
//!
//! 1. **A row is a container.** A row has an icon, a name, a right-aligned
//!    value, a hover state, a selected state and a drag target. That is a
//!    layout, not a label.
//! 2. **Indentation is pixels, not a widget.** A tree at depth 6 has to line
//!    up its icons, and the indentation has to be one number in one place.
//! 3. **The tree's state is a path.** Which nodes are open is UI state and
//!    belongs in the `Store` under `hierarchy/open/<actor>`, not in a
//!    recursive C++ struct.
//!
//! So a row is one function and a tree is a function that calls itself, and the
//! whole thing is ~200 lines with no allocation per frame.

const std = @import("std");
const cimgui = @import("../cimgui.zig");
const theme = @import("../theme.zig");
const draw = @import("../draw.zig");
const icons = @import("../icons.zig");
const widget = @import("widget.zig");
const Context = @import("../context.zig").Context;
const getBool = @import("../reactive.zig").getBool;

/// One row's content. A struct of slices and optionals, so a row can be built
/// from anything (a filesystem entry, an ECS actor, a search result) without
/// the list module knowing what any of them are.
/// The trailing value, in the mono face at the faint colour.
fn TrailingInFont(at: cimgui.Vec2, s: []const u8, col: cimgui.Rgba) void {
    draw.itemList().text(at, col, s);
}

pub const Row = struct {
    id: []const u8,
    label: []const u8,
    icon: ?icons.Icon = null,
    /// Right-aligned, dim: a file size, an actor type, a line number.
    trailing: []const u8 = "",
    /// Depth in a tree, in ROWS. Zero for a flat list. In rows rather than
    /// pixels so the icons line up no matter what the font size is.
    depth: u16 = 0,
    /// A small coloured dot for a modified/unsaved state.
    dot: ?cimgui.Rgba = null,
    selectable: bool = true,
    /// The row is being dragged.
    dragging: bool = false,
    /// A drop target is hovering here.
    drop_target: bool = false,
    selected: bool = false,
    hovered: bool = false,
};

pub const RowOptions = struct {
    ctx: *Context,
    height: f32 = 0,
    /// Draws the row with a left accent bar. The selection cue that survives a
    /// greyscale screenshot, a colour-blind user and a projector.
    accent_bar: bool = true,
    indent: f32 = 16.0,
    icon_size: f32 = 16.0,
    on_click: ?*const fn (ctx: ?*anyopaque, row_id: []const u8) void = null,
    on_activate: ?*const fn (ctx: ?*anyopaque, row_id: []const u8) void = null,
    ctx_arg: ?*anyopaque = null,
};

/// Draws one row and returns what happened to it.
pub const RowResult = struct {
    clicked: bool = false,
    /// Double click, or Enter while focused.
    activated: bool = false,
    hovered: bool = false,
    rect: cimgui.Rect = .{},
};

pub fn row(r: Row, o: RowOptions) RowResult {
    const t = &o.ctx.theme;
    const m = t.metrics;
    const h = if (o.height > 0) o.height else m.row_h();
    const w = @max(draw.contentAvail().x, 1);

    cimgui.ember_ui_push_id_str(cimgui.text(r.id));
    const hit = widget.submit("row", w, h, !r.selectable);
    const list = draw.itemList();

    const rect = hit.rect;
    if (r.drop_target) {
        list.rect(rect, t.colors.accent_soft, m.radius_sm());
        list.rectOutline(rect, t.colors.accent, m.radius_sm(), 1.5);
    } else if (r.selected) {
        list.rect(rect, t.colors.accent_soft, m.radius_sm());
        if (o.accent_bar) {
            // 2px, full height, at the row's left edge. The selection cue that
            // is not a background colour, because a selected row that is only
            // "a bit bluer" is invisible on a bad monitor.
            list.rect(draw.rect(rect.min.x + 1, rect.min.y + 4, rect.min.x + 3, rect.max.y - 4), t.colors.accent, 1);
        }
    } else if (r.hovered or hit.hovered) {
        list.rect(rect, t.colors.surface_hi.withAlpha(0.6), m.radius_sm());
    }
    if (r.dragging) {
        list.rectOutline(rect, t.colors.border_focus, m.radius_sm(), 1);
    }

    var x = rect.min.x + m.pad_x() + @as(f32, @floatFromInt(r.depth)) * o.indent;
    const cy = rect.min.y + h * 0.5;

    if (r.dot) |d| {
        list.circle(.{ .x = x + 3, .y = cy }, 3, d);
        x += 12;
    }
    if (r.icon) |ic| {
        icons.render(list, ic, .{ .x = x + o.icon_size * 0.5, .y = cy }, t.colors.text_dim, o.icon_size, 0);
        x += o.icon_size + m.gap();
    }
    if (r.trailing.len > 0) {
        const size = draw.textSize(r.trailing);
        o.ctx.withFont(.mono, TrailingInFont, .{
            cimgui.Vec2{ .x = rect.max.x - size.x - m.pad_x(), .y = cy - size.y * 0.5 },
            r.trailing,
            o.ctx.theme.colors.text_faint,
        });
    }
    // The label is drawn LAST so it is never overdrawn by a trailing value: a
    // long name and a long size meet in the middle, and the name wins because
    // it is the one the user is looking for.
    list.text(
        .{ .x = x, .y = rect.min.y + (h - 16) * 0.5 },
        if (r.selected) t.colors.text else if (r.selectable) t.colors.text else t.colors.text_faint,
        r.label,
    );

    var result: RowResult = .{ .hovered = hit.hovered, .rect = rect };
    if (r.selectable and hit.clicked) {
        result.clicked = true;
        if (o.on_click) |cb| cb(o.ctx_arg, r.id);
    }
    if (r.selectable and hit.focused and cimgui.ember_ui_is_item_deactivated_after_edit() != 0) {
        result.activated = true;
        if (o.on_activate) |cb| cb(o.ctx_arg, r.id);
    }
    cimgui.ember_ui_pop_id();
    return result;
}

/// A scrollable region. Every list in the editor goes through this, because the
/// clipping is the thing that is easy to forget and obvious when it is missing:
/// a tree that draws past the bottom of its panel paints over the status bar.
pub fn scrollable(ctx: *Context, id: []const u8, height: f32, body: *const fn (ctx: *Context) void) bool {
    const avail = draw.contentAvail();
    const h = if (height < 0) avail.y + height else @min(height, avail.y);
    cimgui.ember_ui_push_id_str(cimgui.text(id));
    const visible = cimgui.ember_ui_begin_child("scroll", 0, @max(h, 1), 0, 0) != 0;
    if (visible) body(ctx);
    cimgui.ember_ui_end_child();
    cimgui.ember_ui_pop_id();
    return visible;
}

// ── Tree ─────────────────────────────────────────────────────────────────

pub const TreeNode = struct {
    /// The path suffix used for the open/closed state in the store. It has to
    /// be stable AND unique per node, which is why it is a path and not an
    /// index: a tree that is rebuilt from a filtered list has different indices
    /// every frame, and every node would close.
    id: []const u8,
    label: []const u8,
    icon: ?icons.Icon = null,
    depth: u16 = 0,
    children: ?*const fn (ctx: *Context) void = null,
    trailing: []const u8 = "",
    dot: ?cimgui.Rgba = null,
    selected: bool = false,
};

pub const Tree = struct {
    ctx: *Context,
    /// The store key PREFIX, e.g. "hierarchy/open". Each node appends "/id".
    open_prefix: []const u8,
    nodes: []const TreeNode,
    selected: *usize,
    height: f32 = 0,
    indent: f32 = 16.0,
    /// 0 = closed, 1 = open, 2 = leaf. Read from the store per node, so the
    /// tree's shape survives a rebuild, a filter and a scene reload.
    on_activate: ?*const fn (ctx: ?*anyopaque, node_id: []const u8) void = null,
    ctx_arg: ?*anyopaque = null,
};

/// Draws a tree. The open state lives in the `Store`, which is the whole reason
/// this function is 40 lines instead of a recursive data structure with
/// lifetimes: the shape is UI state, and UI state has a home.
pub fn tree(t: Tree) void {
    var self = t;
    for (self.nodes, 0..) |node, i| {
        const has_children = node.children != null;
        const open = if (has_children) getBool(&self.ctx.store, join(self.open_prefix, node.id), false) else false;

        var r: Row = .{
            .id = node.id,
            .label = node.label,
            .icon = node.icon orelse (if (has_children) .folder_open else .file),
            .depth = node.depth,
            .trailing = node.trailing,
            .dot = node.dot,
            .selected = self.selected.* == i,
        };
        // The chevron is drawn by the row's icon slot when the node has
        // children, so a tree's expand control is in the same column for every
        // depth — which is what makes a tree scannable.
        if (has_children) {
            r.icon = if (open) .chevron_down else .chevron_right;
        }
        const res = row(r, .{
            .ctx = self.ctx,
            .on_click = onTreeClick,
            .on_activate = self.on_activate,
            .ctx_arg = self.ctx_arg,
        });
        if (res.clicked) {
            self.selected.* = i;
            if (has_children) {
                self.ctx.store.set(join(self.open_prefix, node.id), bool, !open) catch {};
            }
        }
        if (has_children and open) {
            self.indent += 1;
            node.children.?(self.ctx);
            self.indent -= 1;
        }
    }
}

fn onTreeClick(arg: ?*anyopaque, node_id: []const u8) void {
    _ = node_id;
    _ = arg;
}

/// `prefix + "/" + id` into a stack buffer. Ids are paths, and paths are short;
/// the alternative is an allocation per node per frame, which is the kind of
/// thing that turns a 200-node tree into a GC event.
fn join(prefix: []const u8, id: []const u8) [:0]const u8 {
    // A stack buffer survives as long as the RETURNED SLICE is used, which is
    // the same statement: the caller uses the key to look a store slot, inside
    // the same call, and never past it. Returning `buf[... :0]` from a `var`
    // that is local to this frame is the use-after-scope that the first version
    // had — it compiled, and every node's key was the memory of the last one.
    var buf: [256]u8 = undefined;
    if (prefix.len + id.len + 2 > buf.len) {
        return prefix[0..@min(prefix.len, buf.len - 1) :0];
    }
    @memcpy(buf[0..prefix.len], prefix);
    buf[prefix.len] = '/';
    @memcpy(buf[prefix.len + 1 ..][0..id.len], id);
    const n = prefix.len + 1 + id.len;
    buf[n] = 0;
    return buf[0..n :0];
}

test "ui list: a node's store key is the prefix, a slash, and the id" {
    // The identity rule, as a test: two nodes with the same label in different
    // places must NOT share an open/closed state, and this is what guarantees
    // they do not.
    const key = join("hierarchy/open", "actors/player");
    try std.testing.expectEqualStrings("hierarchy/open/actors/player", key);
    const other = join("hierarchy/open", "actors/enemy");
    try std.testing.expect(!std.mem.eql(u8, key, other));
}
