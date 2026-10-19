//! The game-UI system (M14): canvas, layout, hit-testing and button state.
//!
//! Runs once per frame, before the renderer consumes the frame's instances. It
//! is deliberately part of `ecs` and NOT of `render`: the module graph forbids
//! `ecs` from importing `render`, and the work this does — resolve the canvas,
//! place each widget, decide what the pointer is over, move the button state
//! machine — is world state, not drawing. `render/ui_draw.zig` reads the
//! `State` this produces (and the components it wrote back) to emit quads; the
//! split is what keeps "where is the button" and "what colour is the button"
//! from knowing about each other.
//!
//! ## What it touches
//!
//! - `UiCanvas` (the first one in slot order) defines virtual resolution and
//!   scale mode; `resolveCanvas` turns that plus the framebuffer size into a
//!   `Canvas` (a scale and a letterbox offset).
//! - every widget's `UiLayout` gets its `resolved` rect for this frame, so
//!   `ui_draw` and `ui.rect(self)` are plain component reads and never a second
//!   layout pass.
//! - `UiButton.state` (normal/hover/pressed) is written here.
//! - the world signal bus and the Lua bridge get `ui_pressed` when a press and
//!   its release land on the same button ("pressed in A, released in B" does
//!   not fire — the classic double-click bug this exists to prevent).
//!
//! ## What it does NOT do
//!
//! No allocation, no GPU work, no I/O: the frame loop rule (spec §3.1). The
//! `items` buffer is a fixed array on the `State` the caller owns across
//! frames, and overflow CLIPS with a counter instead of growing.
//!
//! ## Which widgets capture the pointer
//!
//! Only the widgets that can be a click target — `UiButton` and `UiPanel` —
//! participate in hit-testing, and only while their `UiLayout.interactive` is
//! true (a disabled button sets it false). A `Label` or `UiProgressBar` is
//! decoration: a HUD score label must not swallow the click that is meant for
//! the world underneath it. This is the same distinction Godot draws with
//! `mouse_filter`, and it is why `pointer_over_ui` is "the pointer is over
//! something interactive" rather than "the pointer is over any UI component".

const std = @import("std");
const core_math = @import("core").math;
const world_mod = @import("world.zig");
const components = @import("components.zig");
const entity_mod = @import("entity.zig");
const zson = @import("zson.zig");

const World = world_mod.World;
const Entity = entity_mod.Entity;
const Vec2 = core_math.Vec2;
const Rect2 = core_math.Rect2;

/// Forwards a completed button press to a consumer the typed bus cannot reach —
/// concretely, `Behaviors.dispatchSignalPayload`, which broadcasts to Lua
/// `on_signal` handlers *with* the button's id and entity. The timer's
/// `SignalBridge` only carries a name; a button click needs to say which button,
/// so this sink is a little wider. The ECS must not import `script`, so it
/// arrives erased.
pub const PressSink = struct {
    ctx: ?*anyopaque = null,
    fire: ?*const fn (ctx: ?*anyopaque, id: u32, entity: u64) void = null,

    /// Delivers one press. A null `fire` is a sink nobody subscribed to, which
    /// is not an error — the typed bus may still carry the event.
    pub fn deliver(self: PressSink, id: u32, entity: u64) void {
        if (self.fire) |f| f(self.ctx, id, entity);
    }
};

/// Bounded widget budget for one frame. A scene with more widgets than this
/// clips the tail (reported in `State.dropped`), the same trade the lighting
/// and particle systems make: a budget beats an allocation in the frame loop.
pub const max_items = 256;

/// The signal name every button emits. Interned at load time by the runtime so
/// the in-frame `emit` never allocates.
pub const pressed_signal = "ui_pressed";

/// Payload queued on the world bus for a button press, for typed Zig listeners.
/// `entity` is the button's handle bits (`Entity.bits`), mirroring `TimerEvent`
/// so a listener can identify the widget without the payload owning an `Entity`.
pub const UiEvent = struct {
    id: u32 = 0,
    entity: u64 = 0,
};

/// The pointer for this frame: framebuffer pixels (origin top-left, the same
/// space everything else in the engine uses), whether a button is held, whether
/// it went down THIS frame, and whether the cursor is even in the window.
pub const PointerState = struct {
    x: f32 = 0,
    y: f32 = 0,
    down: bool = false,
    pressed: bool = false,
    inside: bool = true,
};

/// Virtual resolution mapped onto the framebuffer. `scale` and `offset` are the
/// whole of the mapping: `screen = offset + logical * scale`.
pub const Canvas = struct {
    /// The framebuffer rect (origin at 0,0).
    screen: Rect2 = .{},
    /// The virtual resolution being mapped.
    logical: Vec2 = .{ .x = 1280, .y = 720 },
    /// Multiplier from logical to screen pixels (uniform for `fit`).
    scale: Vec2 = .{ .x = 1, .y = 1 },
    /// Where the logical origin lands in the framebuffer (the letterbox bars for
    /// `fit` when the aspect ratios differ).
    offset: Vec2 = .{ .x = 0, .y = 0 },
    /// Layer UI instances carry (`layer_base + order`). 255 (the light wildcard)
    /// keeps an unlit HUD from going dark; `ui_draw` clamps it to the byte the
    /// instance holds.
    layer_base: u16 = 255,
};

/// Which component a gathered item came from. The rank is also the paint
/// order within one `order` value: panels behind, then bars, then buttons, then
/// labels on top.
pub const WidgetKind = enum(u8) {
    panel = 0,
    progress = 1,
    button = 2,
    label = 3,

    /// Whether a widget of this kind can be hovered and clicked.
    fn captures(self: WidgetKind) bool {
        return self == .button or self == .panel;
    }
};

/// One widget resolved for this frame: enough for hit-testing and for `ui_draw`
/// to paint it without re-deriving anything.
pub const Item = struct {
    entity: Entity,
    kind: WidgetKind,
    order: i32,
    /// Screen-pixel rect (canvas already applied).
    rect: Rect2,
    visible: bool,
    /// Visible, interactive and of a capturing kind.
    hit_testable: bool,
};

/// Per-frame output plus the little bit of state that has to survive between
/// frames (who is hovered, who is being pressed). Owned by the runtime.
pub const State = struct {
    canvas: Canvas = .{},
    items: [max_items]Item = undefined,
    count: usize = 0,
    /// Widgets over the budget last frame (reported, not silent).
    dropped: usize = 0,
    /// True when the pointer is over an interactive widget: the game's input
    /// surface reads this to keep a click from also being a world action.
    pointer_over_ui: bool = false,
    /// The capturing widget under the pointer, or null.
    hot: ?Entity = null,
    /// The button that was pressed and not yet released.
    active: ?Entity = null,
    /// Pointer held state last frame, for the release edge.
    prev_down: bool = false,

    /// The gathered items, in paint order (lowest first).
    pub fn slice(self: *const State) []const Item {
        return self.items[0..self.count];
    }

    /// The item for an entity, in this frame's gathered set.
    pub fn itemOf(self: *const State, e: Entity) ?Item {
        for (self.items[0..self.count]) |it| {
            if (it.entity.index == e.index and it.entity.generation == e.generation) return it;
        }
        return null;
    }
};

// ── Canvas ───────────────────────────────────────────────────────────────────

/// The first `UiCanvas` in slot order wins (deterministic, spec §6); with none,
/// a default 1280x720 fit canvas is used so a label is still visible.
pub fn resolveCanvas(world: *World, screen_size: Vec2) Canvas {
    var vw: f32 = 1280;
    var vh: f32 = 720;
    var mode: components.UiScaleMode = .fit;
    var layer_base: u16 = 255;

    var slot: usize = 0;
    while (slot < world.slotCount()) : (slot += 1) {
        const e = world.entityAtSlot(slot) orelse continue;
        if (world.get(e, components.UiCanvas)) |c| {
            vw = c.virtual_w;
            vh = c.virtual_h;
            mode = c.scale_mode;
            layer_base = c.layer_base;
            break;
        }
    }
    vw = @max(vw, 1);
    vh = @max(vh, 1);
    const sw = @max(screen_size.x, 1);
    const sh = @max(screen_size.y, 1);

    var scale = Vec2{ .x = 1, .y = 1 };
    var offset = Vec2{ .x = 0, .y = 0 };
    switch (mode) {
        // Exact pixels: a HUD that must land on whole texels.
        .pixel => {},
        // Uniform scale, centred: the game is authored at one aspect ratio and
        // letterboxed into anything else.
        .fit => {
            const s = @min(sw / vw, sh / vh);
            scale = .{ .x = s, .y = s };
            offset = .{ .x = (sw - vw * s) * 0.5, .y = (sh - vh * s) * 0.5 };
        },
        // Independent axes: fills the window and accepts the distortion.
        .stretch => {
            scale = .{ .x = sw / vw, .y = sh / vh };
        },
    }
    return .{
        .screen = .{ .position = .{}, .size = .{ .x = sw, .y = sh } },
        .logical = .{ .x = vw, .y = vh },
        .scale = scale,
        .offset = offset,
        .layer_base = layer_base,
    };
}

/// The anchor preset as a fraction of the canvas (Godot's anchor points). The
/// stretch presets do not use this — `layoutRect` handles them directly.
fn anchorFraction(a: components.UiAnchor) Vec2 {
    return switch (a) {
        .top_left => .{ .x = 0, .y = 0 },
        .top_center => .{ .x = 0.5, .y = 0 },
        .top_right => .{ .x = 1, .y = 0 },
        .middle_left => .{ .x = 0, .y = 0.5 },
        .center => .{ .x = 0.5, .y = 0.5 },
        .middle_right => .{ .x = 1, .y = 0.5 },
        .bottom_left => .{ .x = 0, .y = 1 },
        .bottom_center => .{ .x = 0.5, .y = 1 },
        .bottom_right => .{ .x = 1, .y = 1 },
        // Reached only through `layoutRect`'s stretch arms; a sane default keeps
        // the function total.
        .stretch_h, .stretch_v, .full_rect => .{ .x = 0, .y = 0 },
    };
}

/// Resolve one widget's layout to a screen-pixel rect.
///
/// The nine presets place a `size`-sized box at an anchor point, shifted by
/// `offset` and re-centred by `pivot` (0,0 = the box's top-left sits at the
/// anchor; 0.5,0.5 = it is centred on it). The three stretch presets ignore
/// `size` on the axis they fill and use `margin` instead:
/// - `stretch_h`: full canvas width, `size.y` tall, pinned to the top.
/// - `stretch_v`: full canvas height, `size.x` wide, pinned to the left.
/// - `full_rect`: the whole canvas inset by `margin` (top/right/bottom/left).
///
/// The result is in framebuffer pixels: the canvas scale and letterbox offset
/// are applied last, so callers never see virtual units.
pub fn layoutRect(layout: components.UiLayout, canvas: Canvas) Rect2 {
    const lw = canvas.logical.x;
    const lh = canvas.logical.y;
    const m = layout.margin;

    var logical: Rect2 = undefined;
    switch (layout.anchor) {
        .full_rect => {
            logical = .{
                .position = .{ .x = m[3] + layout.offset.x, .y = m[0] + layout.offset.y },
                .size = .{
                    .x = @max(0, lw - m[1] - m[3]),
                    .y = @max(0, lh - m[0] - m[2]),
                },
            };
        },
        .stretch_h => {
            logical = .{
                .position = .{ .x = m[3] + layout.offset.x, .y = m[0] + layout.offset.y },
                .size = .{ .x = @max(0, lw - m[1] - m[3]), .y = layout.size.y },
            };
        },
        .stretch_v => {
            logical = .{
                .position = .{ .x = m[3] + layout.offset.x, .y = m[0] + layout.offset.y },
                .size = .{ .x = layout.size.x, .y = @max(0, lh - m[0] - m[2]) },
            };
        },
        else => {
            const f = anchorFraction(layout.anchor);
            logical = .{
                .position = .{
                    .x = f.x * lw + layout.offset.x - layout.pivot.x * layout.size.x,
                    .y = f.y * lh + layout.offset.y - layout.pivot.y * layout.size.y,
                },
                .size = layout.size,
            };
        },
    }

    return .{
        .position = .{
            .x = canvas.offset.x + logical.position.x * canvas.scale.x,
            .y = canvas.offset.y + logical.position.y * canvas.scale.y,
        },
        .size = .{
            .x = logical.size.x * canvas.scale.x,
            .y = logical.size.y * canvas.scale.y,
        },
    };
}

// ── The per-frame system ─────────────────────────────────────────────────────

/// Runs once per frame. Fills `state` from the world, resolves every widget's
/// rect (writing it back to the component), decides the pointer's target,
/// advances the button state machine and fires `ui_pressed` on a completed
/// click. Zero allocations.
pub fn update(
    state: *State,
    world: *World,
    screen_size: Vec2,
    pointer: PointerState,
    sink: PressSink,
) void {
    state.canvas = resolveCanvas(world, screen_size);
    gather(state, world);
    sortItems(state.items[0..state.count]);

    const hovered = hitTest(state, pointer);
    state.hot = if (hovered) |ix| state.items[ix].entity else null;
    state.pointer_over_ui = hovered != null;

    // Press and release edges. `pressed` covers the down transition even when
    // it did not survive to see it (a down+up inside one frame); the release
    // edge uses last frame's held state and is also true for that same
    // same-frame click, so a fast tap is a click and not a miss.
    const press_edge = pointer.pressed or (pointer.down and !state.prev_down);
    const release_edge = !pointer.down and (state.prev_down or pointer.pressed);

    if (press_edge) {
        if (hovered) |ix| {
            if (state.items[ix].kind == .button) state.active = state.items[ix].entity;
        }
    }

    if (release_edge) {
        if (state.active) |a| {
            const landed = if (hovered) |ix| state.items[ix].entity else null;
            if (landed != null and sameEntity(landed.?, a)) {
                firePressed(world, sink, a);
            }
            state.active = null;
        }
    }

    applyButtonStates(state, world, hovered, pointer.down);
    state.prev_down = pointer.down;
}

/// Walks every live entity for a widget component and records it. The
/// component's `resolved` field is written here so no later reader has to lay
/// the widget out again.
fn gather(state: *State, world: *World) void {
    state.count = 0;
    state.dropped = 0;

    var slot: usize = 0;
    while (slot < world.slotCount()) : (slot += 1) {
        const e = world.entityAtSlot(slot) orelse continue;

        var kind: WidgetKind = undefined;
        var layout: *components.UiLayout = undefined;
        var enabled = true;
        // Precedence within one entity is fixed and documented: a button, then
        // a panel, then a bar, then a label. A widget entity normally has
        // exactly one of them; the order only matters for a malformed stack.
        if (world.get(e, components.UiButton)) |b| {
            kind = .button;
            layout = &b.layout;
            enabled = b.enabled;
        } else if (world.get(e, components.UiPanel)) |p| {
            kind = .panel;
            layout = &p.layout;
        } else if (world.get(e, components.UiProgressBar)) |p| {
            kind = .progress;
            layout = &p.layout;
        } else if (world.get(e, components.Label)) |l| {
            kind = .label;
            layout = &l.layout;
        } else continue;

        const rect = layoutRect(layout.*, state.canvas);
        layout.resolved = rect;

        if (state.count >= max_items) {
            state.dropped += 1;
            continue;
        }
        state.items[state.count] = .{
            .entity = e,
            .kind = kind,
            .order = layout.order,
            .rect = rect,
            .visible = layout.visible,
            .hit_testable = layout.visible and layout.interactive and enabled and kind.captures(),
        };
        state.count += 1;
    }
}

/// Stable insertion sort by (order, kind rank). Equal keys keep their gather
/// order, which is entity slot order — the documented tie-break. n is capped at
/// `max_items` and the comparator is two integer compares, so this is cheap.
fn sortItems(items: []Item) void {
    var i: usize = 1;
    while (i < items.len) : (i += 1) {
        const cur = items[i];
        var j = i;
        while (j > 0 and itemLess(cur, items[j - 1])) : (j -= 1) {
            items[j] = items[j - 1];
        }
        items[j] = cur;
    }
}

fn itemLess(a: Item, b: Item) bool {
    if (a.order != b.order) return a.order < b.order;
    return @intFromEnum(a.kind) < @intFromEnum(b.kind);
}

/// Topmost hit-testable widget under the pointer, or null. Iterating the
/// paint-ordered list backwards means the last-drawn widget wins, which is
/// exactly "highest order, then latest rank, then latest slot".
fn hitTest(state: *const State, pointer: PointerState) ?usize {
    if (!pointer.inside) return null;
    const pt = Vec2{ .x = pointer.x, .y = pointer.y };
    var i = state.count;
    while (i > 0) {
        i -= 1;
        const it = state.items[i];
        if (!it.hit_testable) continue;
        if (it.rect.contains(pt)) return i;
    }
    return null;
}

/// Writes `UiButton.state` for every button this frame: `.pressed` on the
/// button being held under the cursor, `.hover` on the one under the cursor,
/// `.normal` otherwise (including the active button once the cursor leaves it).
fn applyButtonStates(state: *const State, world: *World, hovered: ?usize, down: bool) void {
    var i: usize = 0;
    while (i < state.count) : (i += 1) {
        const it = state.items[i];
        if (it.kind != .button) continue;
        const btn = world.get(it.entity, components.UiButton) orelse continue;

        const is_hot = hovered != null and sameEntity(state.items[hovered.?].entity, it.entity);
        const is_active = state.active != null and sameEntity(state.active.?, it.entity);

        btn.state = if (is_active and down and is_hot)
            .pressed
        else if (is_active)
            .normal
        else if (is_hot)
            .hover
        else
            .normal;
    }
}

/// Queues the typed event for Zig listeners (only when something is
/// subscribed, so an unheard signal never fills the queue) and forwards the
/// id and entity to Lua through the sink. The typed bus runs first so an ECS
/// listener and a Lua handler see the same press in the same frame.
fn firePressed(world: *World, sink: PressSink, e: Entity) void {
    const id = if (world.get(e, components.UiButton)) |b| b.id else 0;
    if (world.signals.hasListeners(pressed_signal)) {
        world.signals.emit(UiEvent, pressed_signal, .{ .id = id, .entity = e.bits() });
    }
    sink.deliver(id, e.bits());
}

fn sameEntity(a: Entity, b: Entity) bool {
    return a.index == b.index and a.generation == b.generation;
}

// ── Tests ────────────────────────────────────────────────────────────────────

const testing = std.testing;

const test_canvas = Canvas{
    .screen = .{ .position = .{}, .size = .{ .x = 1280, .y = 720 } },
    .logical = .{ .x = 1280, .y = 720 },
    .scale = .{ .x = 1, .y = 1 },
    .offset = .{ .x = 0, .y = 0 },
    .layer_base = 255,
};

fn rectApproxEq(actual: Rect2, expected: Rect2) !void {
    try testing.expectApproxEqAbs(expected.position.x, actual.position.x, 1e-3);
    try testing.expectApproxEqAbs(expected.position.y, actual.position.y, 1e-3);
    try testing.expectApproxEqAbs(expected.size.x, actual.size.x, 1e-3);
    try testing.expectApproxEqAbs(expected.size.y, actual.size.y, 1e-3);
}

test "layoutRect places the nine presets from anchor, pivot and offset" {
    // top_left: the box's top-left sits at the canvas origin.
    try rectApproxEq(
        layoutRect(.{ .anchor = .top_left }, test_canvas),
        .{ .position = .{ .x = 0, .y = 0 }, .size = .{ .x = 100, .y = 30 } },
    );
    // center with a half pivot: the box is centred on the canvas centre.
    try rectApproxEq(
        layoutRect(.{ .anchor = .center, .pivot = .{ .x = 0.5, .y = 0.5 } }, test_canvas),
        .{ .position = .{ .x = 590, .y = 345 }, .size = .{ .x = 100, .y = 30 } },
    );
    // bottom_right with a full pivot: the box's bottom-right meets the corner.
    try rectApproxEq(
        layoutRect(.{ .anchor = .bottom_right, .pivot = .{ .x = 1, .y = 1 } }, test_canvas),
        .{ .position = .{ .x = 1180, .y = 690 }, .size = .{ .x = 100, .y = 30 } },
    );
    // offset shifts from the anchor point; pivot still applies to the size.
    try rectApproxEq(
        layoutRect(.{ .anchor = .top_center, .offset = .{ .x = 0, .y = 12 }, .pivot = .{ .x = 0.5, .y = 0 } }, test_canvas),
        .{ .position = .{ .x = 590, .y = 12 }, .size = .{ .x = 100, .y = 30 } },
    );
}

test "layoutRect stretch presets fill an axis and honour the margins" {
    // stretch_h: full width, `size.y` tall, pinned to the top, top margin in.
    try rectApproxEq(
        layoutRect(.{ .anchor = .stretch_h, .size = .{ .x = 999, .y = 24 }, .margin = .{ 10, 0, 0, 0 } }, test_canvas),
        .{ .position = .{ .x = 0, .y = 10 }, .size = .{ .x = 1280, .y = 24 } },
    );
    // stretch_v: full height, `size.x` wide, pinned to the left.
    try rectApproxEq(
        layoutRect(.{ .anchor = .stretch_v, .size = .{ .x = 60, .y = 999 }, .margin = .{ 0, 0, 0, 16 } }, test_canvas),
        .{ .position = .{ .x = 16, .y = 0 }, .size = .{ .x = 60, .y = 720 } },
    );
    // full_rect: the whole canvas inset top/right/bottom/left.
    try rectApproxEq(
        layoutRect(.{ .anchor = .full_rect, .margin = .{ 8, 16, 8, 16 } }, test_canvas),
        .{ .position = .{ .x = 16, .y = 8 }, .size = .{ .x = 1248, .y = 704 } },
    );
}

test "the canvas scale and letterbox reach the resolved rect" {
    // A 640x360 virtual canvas fit into 1280x720: uniform 2x, no bars.
    const scaled = Canvas{
        .screen = test_canvas.screen,
        .logical = .{ .x = 640, .y = 360 },
        .scale = .{ .x = 2, .y = 2 },
        .offset = .{ .x = 0, .y = 0 },
        .layer_base = 255,
    };
    try rectApproxEq(
        layoutRect(.{ .anchor = .top_left, .size = .{ .x = 100, .y = 30 } }, scaled),
        .{ .position = .{ .x = 0, .y = 0 }, .size = .{ .x = 200, .y = 60 } },
    );

    // 1280x720 into 1920x720: 1.5x with 240px bars on each side.
    const letterboxed = Canvas{
        .screen = .{ .position = .{}, .size = .{ .x = 1920, .y = 720 } },
        .logical = .{ .x = 1280, .y = 720 },
        .scale = .{ .x = 1.5, .y = 1.5 },
        .offset = .{ .x = 240, .y = 0 },
        .layer_base = 255,
    };
    try rectApproxEq(
        layoutRect(.{ .anchor = .top_left, .size = .{ .x = 100, .y = 30 } }, letterboxed),
        .{ .position = .{ .x = 240, .y = 0 }, .size = .{ .x = 150, .y = 45 } },
    );
}

test "resolveCanvas reads the first canvas and fits the framebuffer" {
    var world = World.init(testing.allocator);
    defer world.deinit();
    _ = try world.spawn(.{components.UiCanvas{ .virtual_w = 1280, .virtual_h = 720, .scale_mode = .fit }});

    // Same aspect: uniform scale, no letterbox.
    const even = resolveCanvas(&world, .{ .x = 1920, .y = 1080 });
    try testing.expectApproxEqAbs(@as(f32, 1.5), even.scale.x, 1e-4);
    try testing.expectApproxEqAbs(@as(f32, 1.5), even.scale.y, 1e-4);
    try testing.expectApproxEqAbs(@as(f32, 0), even.offset.x, 1e-4);

    // Wider framebuffer: the scale is the smaller ratio and bars appear.
    const wide = resolveCanvas(&world, .{ .x = 2560, .y = 1080 });
    try testing.expectApproxEqAbs(@as(f32, 1.5), wide.scale.x, 1e-4);
    try testing.expectApproxEqAbs(@as(f32, 320), wide.offset.x, 1e-4);
}

test "resolveCanvas stretch and pixel modes" {
    var world = World.init(testing.allocator);
    defer world.deinit();
    const e = try world.spawn(.{components.UiCanvas{ .virtual_w = 640, .virtual_h = 360, .scale_mode = .stretch }});

    const st = resolveCanvas(&world, .{ .x = 1920, .y = 360 });
    try testing.expectApproxEqAbs(@as(f32, 3), st.scale.x, 1e-4);
    try testing.expectApproxEqAbs(@as(f32, 1), st.scale.y, 1e-4);

    world.get(e, components.UiCanvas).?.scale_mode = .pixel;
    const px = resolveCanvas(&world, .{ .x = 1920, .y = 360 });
    try testing.expectApproxEqAbs(@as(f32, 1), px.scale.x, 1e-4);
    try testing.expectApproxEqAbs(@as(f32, 1), px.scale.y, 1e-4);
}

/// Spawns a button at a screen-pixel rect (canvas is 1:1 in these tests).
fn spawnButton(world: *World, rect: Rect2, order: i32, id: u32) !Entity {
    return world.spawn(.{
        components.UiButton{
            .layout = .{
                .anchor = .top_left,
                .offset = rect.position,
                .size = rect.size,
                .order = order,
            },
            .id = id,
        },
    });
}

test "hit-testing picks the highest order widget under the pointer" {
    var world = World.init(testing.allocator);
    defer world.deinit();

    const low = try spawnButton(&world, .{ .position = .{ .x = 0, .y = 0 }, .size = .{ .x = 100, .y = 100 } }, 0, 1);
    const high = try spawnButton(&world, .{ .position = .{ .x = 50, .y = 50 }, .size = .{ .x = 100, .y = 100 } }, 5, 2);

    var state = State{};
    const over_both = PointerState{ .x = 60, .y = 60, .inside = true };
    update(&state, &world, test_canvas.screen.size, over_both, .{});

    // The pointer is in the overlap; the higher order wins.
    try testing.expectEqual(high.index, state.hot.?.index);
    try testing.expect(state.pointer_over_ui);

    // Off both widgets: nothing hot, no capture.
    update(&state, &world, test_canvas.screen.size, .{ .x = 500, .y = 500, .inside = true }, .{});
    try testing.expect(state.hot == null);
    try testing.expect(!state.pointer_over_ui);

    // Only the low-order widget left: the same point now hits it.
    _ = world.despawn(high);
    update(&state, &world, test_canvas.screen.size, over_both, .{});
    try testing.expectEqual(low.index, state.hot.?.index);
}

test "gathering writes the resolved rect back to the component" {
    var world = World.init(testing.allocator);
    defer world.deinit();
    const e = try spawnButton(&world, .{ .position = .{ .x = 12, .y = 34 }, .size = .{ .x = 44, .y = 22 } }, 0, 0);

    var state = State{};
    update(&state, &world, test_canvas.screen.size, .{ .x = -1, .y = -1 }, .{});

    const resolved = world.get(e, components.UiButton).?.layout.resolved;
    try testing.expectApproxEqAbs(@as(f32, 12), resolved.position.x, 1e-4);
    try testing.expectApproxEqAbs(@as(f32, 34), resolved.position.y, 1e-4);
    try testing.expectApproxEqAbs(@as(f32, 44), resolved.size.x, 1e-4);
}

test "labels and bars are decoration: they never capture the pointer" {
    var world = World.init(testing.allocator);
    defer world.deinit();
    const label = try world.spawn(.{components.Label{
        .layout = .{ .anchor = .full_rect },
        .text = components.InlineText.init("score: 100"),
    }});
    const bar = try world.spawn(.{components.UiProgressBar{
        .layout = .{ .anchor = .full_rect },
        .value = 0.5,
    }});
    _ = label;
    _ = bar;

    var state = State{};
    update(&state, &world, test_canvas.screen.size, .{ .x = 100, .y = 100, .inside = true }, .{});
    try testing.expect(!state.pointer_over_ui);
    try testing.expect(state.hot == null);
    // They were still gathered (and painted) — just not hit-tested.
    try testing.expectEqual(@as(usize, 2), state.count);
}

test "an interactive panel captures the pointer; a non-interactive one does not" {
    var world = World.init(testing.allocator);
    defer world.deinit();
    const panel = try world.spawn(.{components.UiPanel{
        .layout = .{ .anchor = .full_rect },
    }});

    var state = State{};
    update(&state, &world, test_canvas.screen.size, .{ .x = 640, .y = 360, .inside = true }, .{});
    try testing.expect(state.pointer_over_ui);

    world.get(panel, components.UiPanel).?.layout.interactive = false;
    update(&state, &world, test_canvas.screen.size, .{ .x = 640, .y = 360, .inside = true }, .{});
    try testing.expect(!state.pointer_over_ui);
}

test "a disabled button is inert" {
    var world = World.init(testing.allocator);
    defer world.deinit();
    const e = try spawnButton(&world, .{ .position = .{ .x = 0, .y = 0 }, .size = .{ .x = 100, .y = 100 } }, 0, 1);
    world.get(e, components.UiButton).?.enabled = false;

    var state = State{};
    update(&state, &world, test_canvas.screen.size, .{ .x = 50, .y = 50, .inside = true }, .{});
    try testing.expect(!state.pointer_over_ui);
    try testing.expectEqual(components.UiButtonState.normal, world.get(e, components.UiButton).?.state);
}

test "the pointer outside the window captures nothing" {
    var world = World.init(testing.allocator);
    defer world.deinit();
    _ = try spawnButton(&world, .{ .position = .{ .x = 0, .y = 0 }, .size = .{ .x = 100, .y = 100 } }, 0, 1);

    var state = State{};
    update(&state, &world, test_canvas.screen.size, .{ .x = 50, .y = 50, .inside = false }, .{});
    try testing.expect(!state.pointer_over_ui);
}

/// Captures the presses a sink forwards, like the timer's Recorder.
const Recorder = struct {
    ids: [8]u32 = undefined,
    entities: [8]u64 = undefined,
    len: usize = 0,
    fn record(ctx: ?*anyopaque, id: u32, entity: u64) void {
        const self: *Recorder = @ptrCast(@alignCast(ctx.?));
        if (self.len < self.ids.len) {
            self.ids[self.len] = id;
            self.entities[self.len] = entity;
            self.len += 1;
        }
    }
    fn sink(self: *Recorder) PressSink {
        return .{ .ctx = self, .fire = Recorder.record };
    }
};

test "press and release on the same button fires ui_pressed" {
    var world = World.init(testing.allocator);
    defer world.deinit();
    const e = try spawnButton(&world, .{ .position = .{ .x = 0, .y = 0 }, .size = .{ .x = 100, .y = 100 } }, 0, 7);

    var rec = Recorder{};
    var state = State{};

    // Frame 1: the down edge over the button.
    update(&state, &world, test_canvas.screen.size, .{ .x = 50, .y = 50, .down = true, .pressed = true }, rec.sink());
    try testing.expectEqual(components.UiButtonState.pressed, world.get(e, components.UiButton).?.state);
    try testing.expectEqual(@as(usize, 0), rec.len); // queued, not fired yet

    // Frame 2: held (no edge, still pressed).
    update(&state, &world, test_canvas.screen.size, .{ .x = 50, .y = 50, .down = true }, rec.sink());
    try testing.expectEqual(components.UiButtonState.pressed, world.get(e, components.UiButton).?.state);
    try testing.expectEqual(@as(usize, 0), rec.len);

    // Frame 3: released over the button -> the click completes.
    update(&state, &world, test_canvas.screen.size, .{ .x = 50, .y = 50, .down = false }, rec.sink());
    try testing.expectEqual(@as(usize, 1), rec.len);
    try testing.expectEqual(@as(u32, 7), rec.ids[0]);
    try testing.expectEqual(e.bits(), rec.entities[0]);
    try testing.expectEqual(components.UiButtonState.hover, world.get(e, components.UiButton).?.state);
    try testing.expect(state.active == null);
}

test "press in A and release in B does not fire" {
    var world = World.init(testing.allocator);
    defer world.deinit();
    _ = try spawnButton(&world, .{ .position = .{ .x = 0, .y = 0 }, .size = .{ .x = 100, .y = 100 } }, 0, 1);
    const b = try spawnButton(&world, .{ .position = .{ .x = 200, .y = 0 }, .size = .{ .x = 100, .y = 100 } }, 0, 2);

    var rec = Recorder{};
    var state = State{};

    // Down over A.
    update(&state, &world, test_canvas.screen.size, .{ .x = 50, .y = 50, .down = true, .pressed = true }, rec.sink());
    // Slide to B while held.
    update(&state, &world, test_canvas.screen.size, .{ .x = 250, .y = 50, .down = true }, rec.sink());
    // Release over B: no click, and nothing latched.
    update(&state, &world, test_canvas.screen.size, .{ .x = 250, .y = 50, .down = false }, rec.sink());

    try testing.expectEqual(@as(usize, 0), rec.len);
    try testing.expect(state.active == null);
    // B is merely hovered.
    try testing.expectEqual(components.UiButtonState.hover, world.get(b, components.UiButton).?.state);
}

test "a down+up inside one frame is still a click" {
    var world = World.init(testing.allocator);
    defer world.deinit();
    _ = try spawnButton(&world, .{ .position = .{ .x = 0, .y = 0 }, .size = .{ .x = 100, .y = 100 } }, 0, 3);

    var rec = Recorder{};
    var state = State{};
    // `pressed` is set but `down` already false: the platform saw a tap.
    update(&state, &world, test_canvas.screen.size, .{ .x = 50, .y = 50, .down = false, .pressed = true }, rec.sink());
    try testing.expectEqual(@as(usize, 1), rec.len);
    try testing.expect(state.active == null);
}

test "the typed bus carries the button id to a Zig listener" {
    var world = World.init(testing.allocator);
    defer world.deinit();
    try world.reserveSignals(16);
    _ = try spawnButton(&world, .{ .position = .{ .x = 0, .y = 0 }, .size = .{ .x = 100, .y = 100 } }, 0, 42);

    var seen: u32 = 0;
    const Sink = struct {
        fn cb(ctx: ?*anyopaque, value: *const anyopaque) void {
            const ev: *const UiEvent = @ptrCast(@alignCast(value));
            const slot: *u32 = @ptrCast(@alignCast(ctx.?));
            slot.* = ev.id;
        }
    };
    try world.signals.on(UiEvent, pressed_signal, 0, &seen, Sink.cb);

    var state = State{};
    update(&state, &world, test_canvas.screen.size, .{ .x = 50, .y = 50, .down = true, .pressed = true }, .{});
    update(&state, &world, test_canvas.screen.size, .{ .x = 50, .y = 50, .down = false }, .{});

    try testing.expectEqual(@as(usize, 1), world.signals.queuedEvents());
    world.signals.drain();
    try testing.expectEqual(@as(u32, 42), seen);
}

test "nothing queued on the bus when nobody listens" {
    var world = World.init(testing.allocator);
    defer world.deinit();
    try world.reserveSignals(16);
    _ = try spawnButton(&world, .{ .position = .{ .x = 0, .y = 0 }, .size = .{ .x = 100, .y = 100 } }, 0, 1);

    var rec = Recorder{};
    var state = State{};
    update(&state, &world, test_canvas.screen.size, .{ .x = 50, .y = 50, .down = true, .pressed = true }, rec.sink());
    update(&state, &world, test_canvas.screen.size, .{ .x = 50, .y = 50, .down = false }, rec.sink());

    // The sink still saw it; the typed bus stayed empty.
    try testing.expectEqual(@as(usize, 1), rec.len);
    try testing.expectEqual(@as(usize, 0), world.signals.queuedEvents());
}

test "paint order is order, then kind rank, then slot" {
    var world = World.init(testing.allocator);
    defer world.deinit();

    // Spawned in an order that does NOT match the expected paint order.
    const bar = try world.spawn(.{components.UiProgressBar{ .layout = .{ .order = 0 } }});
    const label_hi = try world.spawn(.{components.Label{ .layout = .{ .order = 10 } }});
    const panel = try world.spawn(.{components.UiPanel{ .layout = .{ .order = 0 } }});
    const label_lo = try world.spawn(.{components.Label{ .layout = .{ .order = 0 } }});

    var state = State{};
    update(&state, &world, test_canvas.screen.size, .{ .x = -1, .y = -1 }, .{});

    const items = state.slice();
    try testing.expectEqual(@as(usize, 4), items.len);
    // order 0 first: panel (rank 0), then bar (rank 1), then label (rank 3).
    try testing.expectEqual(panel.index, items[0].entity.index);
    try testing.expectEqual(bar.index, items[1].entity.index);
    try testing.expectEqual(label_lo.index, items[2].entity.index);
    // order 10 last.
    try testing.expectEqual(label_hi.index, items[3].entity.index);
}

test "the shipped HUD sample decodes into the widgets its docs describe" {
    // `samples/ui-hud/scene.zson` is the M14 acceptance sample (plan §11). It is
    // decoded here from the real file, so a field rename or a registry change
    // that would rot the sample fails the suite instead of shipping a dead link.
    const io = std.Io.Threaded.global_single_threaded.io();
    const text = try std.Io.Dir.cwd().readFileAlloc(
        io,
        "samples/ui-hud/scene.zson",
        testing.allocator,
        .limited(1 << 20),
    );
    defer testing.allocator.free(text);

    var world = try zson.decode(testing.allocator, text);
    defer world.deinit();

    // The screen root carries the canvas; the widgets are one component each.
    const canvas = world.get(world.findByName("hud").?, components.UiCanvas).?;
    try testing.expectEqual(components.UiScaleMode.fit, canvas.scale_mode);
    try testing.expectEqual(@as(f32, 1280), canvas.virtual_w);

    const score_e = world.findByName("hud_score").?;
    const score = world.get(score_e, components.Label).?;
    try testing.expectEqualStrings("Score: 0", score.text.slice());
    try testing.expectEqual(components.TextAlign.left, score.alignment);

    const bar = world.get(world.findByName("hud_bar").?, components.UiProgressBar).?;
    try testing.expectApproxEqAbs(@as(f32, 1), bar.value, 1e-6);
    try testing.expect(bar.show_text);
    try testing.expectEqualStrings("30s", bar.text.slice());

    const pause_e = world.findByName("hud_pause").?;
    const pause = world.get(pause_e, components.UiButton).?;
    try testing.expectEqual(@as(u32, 1), pause.id);
    try testing.expectEqualStrings("Pause", pause.text.slice());
    try testing.expectEqual(components.UiAnchor.top_right, pause.layout.anchor);
    try testing.expectApproxEqAbs(@as(f32, 1), pause.layout.pivot.x, 1e-6);

    const panel = world.get(world.findByName("hud_panel").?, components.UiPanel).?;
    try testing.expect(!panel.layout.interactive);

    // The capture rule the sample leans on (it is what keeps the UI from
    // leaking input to the world): the label is decoration, the button is the
    // one widget a pointer over the HUD can be "over".
    var state = State{};
    const screen = Vec2{ .x = 1280, .y = 720 };
    update(&state, &world, screen, .{ .inside = false }, .{});

    const button_rect = state.itemOf(pause_e).?.rect;
    const over_button = PointerState{
        .x = button_rect.position.x + button_rect.size.x * 0.5,
        .y = button_rect.position.y + button_rect.size.y * 0.5,
        .inside = true,
    };
    update(&state, &world, screen, over_button, .{});
    try testing.expect(state.pointer_over_ui);
    try testing.expect(state.hot.?.eql(pause_e));

    const label_rect = state.itemOf(score_e).?.rect;
    update(&state, &world, screen, .{
        .x = label_rect.position.x + label_rect.size.x * 0.5,
        .y = label_rect.position.y + label_rect.size.y * 0.5,
        .inside = true,
    }, .{});
    try testing.expect(!state.pointer_over_ui);
}
