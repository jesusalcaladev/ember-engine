//! M14 — game-UI drawing: turn the frame's resolved widgets into instances.
//!
//! This is the render half of the M14 split. `ecs/ui_system.zig` decided WHERE
//! everything is and WHAT the pointer is doing; this file decides what the GPU
//! sees, and it is the only place that touches `Renderer2D`. The direction of
//! the dependency is the reason for the split: `ecs` cannot import `render`
//! (module graph), and `render` may import `ecs`, so the emitter lives here.
//!
//! ## No new pipeline
//!
//! A panel, a button and a progress bar are `SpriteInstance` quads drawn from
//! the WHITE fallback texture (slot 255) with a full [0,0,1,1] uv and a flat
//! tint; the border is four thin quads (no nine-slice in v1). Text is one quad
//! per glyph, from the font's atlas page (the same page a sprite atlas would
//! live on), tinted by the label colour. Everything goes into the SAME instance
//! buffer the sprites and particles use, so the UI is not a second pass and the
//! backend learns nothing new.
//!
//! ## Screen space to world space
//!
//! The batcher applies ONE MVP per scene (the camera's), so an instance is
//! positioned in WORLD units. A UI rect is in framebuffer pixels with y growing
//! DOWN from the top-left; the camera's `screenToWorld` is y-up from the world
//! rect's bottom-left. `Mapper` is the single place that bridges the two —
//! `screen_y_up = viewport_h - screen_y_down` and `half_world = half_screen /
//! zoom` — so a widget stays pinned to the screen at any zoom without a second
//! draw call. With no camera the runtime renders `makeCamera(w, h)`, whose world
//! origin is the screen centre; `defaultView` reproduces exactly that.
//!
//! ## Paint order and the draw-call budget
//!
//! Instances are appended in `ui_system`'s paint order (order, then kind rank),
//! after the world was collected, so the UI is always on top and the order is
//! deliberate rather than sorted. The backend batches CONSECUTIVE same-slot
//! instances, so the cost is one run for the fills plus one per font: the kind
//! ranking puts every background (panel/border/bar/button) before every label
//! within an order group, which is what keeps a normal HUD at a handful of draw
//! calls even though fills and glyphs use different slots.

const std = @import("std");
const core = @import("core");
const ecs = @import("ecs");
const render = @import("render.zig");
const render2d = @import("2d.zig");
const font_mod = @import("font.zig");
const ui_system = ecs.ui_system;

const Vec2 = core.math.Vec2;
const Rect2 = core.math.Rect2;
const World = ecs.World;
const components = ecs.components;
const Renderer2D = render2d.Renderer2D;
const Font = font_mod.Font;

/// The white fallback: the slot the backend substitutes when no atlas resolves,
/// and the one a plain quad wants. `Renderer2D` and `SpriteInstance` already use
/// 255 for "no page"; the UI is the first producer that does it on purpose.
pub const white_slot: u8 = 255;

/// Resolves a widget's `font` id (0 = the scene default) to a `Font`. A function
/// pointer plus a context, the same erased shape the atlas and signal bridges
/// use, so `ui_draw` owns no font cache and the runtime owns exactly one.
pub const FontSource = struct {
    ctx: ?*anyopaque = null,
    get: ?*const fn (ctx: ?*anyopaque, id: u32) ?*Font = null,

    pub fn resolve(self: FontSource, id: u32) ?*Font {
        const get = self.get orelse return null;
        return get(self.ctx, id);
    }
};

pub const Options = struct {
    /// The active camera's view, or null for "no camera" (screen centre = world
    /// origin, matching `render.makeCamera`).
    view: ?ecs.camera.View = null,
    fonts: FontSource = .{},
};

/// What the frame's UI emission produced. `glyphs` is counted for the tests that
/// prove text reached the instance buffer on a headless backend.
pub const Stats = struct {
    /// Non-text quads (panels, borders, bars, button backgrounds).
    quads: usize = 0,
    /// Glyph quads.
    glyphs: usize = 0,
    /// Instances the renderer refused because the frame budget was spent.
    dropped: usize = 0,
};

const Mapper = struct {
    view: ecs.camera.View,

    /// Screen-pixel point (y down) to world units.
    fn world(self: Mapper, p: Vec2) Vec2 {
        return self.view.screenToWorld(.{ .x = p.x, .y = self.view.viewport_h - p.y });
    }

    /// Screen-pixel half extents to world units. The camera scales world by
    /// `zoom` on the way to the screen, so undo it.
    fn half(self: Mapper, size: Vec2) Vec2 {
        const z = if (self.view.zoom == 0) 1 else self.view.zoom;
        return .{ .x = @abs(size.x) * 0.5 / z, .y = @abs(size.y) * 0.5 / z };
    }
};

/// The camera the runtime renders with when the scene has none: `makeCamera`
/// centres the world origin on the screen and shows `[-w/2, w/2] x [-h/2, h/2]`.
fn defaultView(canvas: ui_system.Canvas) ecs.camera.View {
    return .{
        .cx = 0,
        .cy = 0,
        .zoom = 1,
        .viewport_w = canvas.screen.size.x,
        .viewport_h = canvas.screen.size.y,
    };
}

const Emitter = struct {
    r2d: *Renderer2D,
    world: *World,
    mapper: Mapper,
    layer_base: u16,
    fonts: FontSource,
    stats: Stats = .{},

    /// The render layer a UI instance carries: `layer_base + order`, clamped to
    /// the byte the instance and the R8 layer target can hold. 255 is the
    /// wildcard the light pass treats as "every light", which is what an unlit
    /// HUD wants; draw ORDER above the world comes from emission order, not from
    /// this number.
    fn layerFor(self: *Emitter, order: i32) u8 {
        const base: i32 = @intCast(@min(self.layer_base, 255));
        return @intCast(std.math.clamp(base + order, 0, 255));
    }

    const full_uv = [4]f32{ 0, 0, 1, 1 };

    /// One flat quad. `uv` is a full [0,0,1,1] for fills and a glyph rect for
    /// text; `slot` is the white fallback or the font page. Returns false when
    /// the frame budget refused it.
    fn push(self: *Emitter, rect: Rect2, uv: [4]f32, rgba: [4]f32, slot: u8, layer: u8) bool {
        if (rect.size.x <= 0 or rect.size.y <= 0) return false;
        const c = rect.center();
        const wp = self.mapper.world(c);
        const wh = self.mapper.half(rect.size);
        const inst = render.SpriteInstance{
            .pos = .{ wp.x, wp.y },
            .half = .{ wh.x, wh.y },
            .uv = .{
                render.toUnorm16(uv[0]),
                render.toUnorm16(uv[1]),
                render.toUnorm16(uv[2]),
                render.toUnorm16(uv[3]),
            },
            .color = .{
                render.toUnorm8(rgba[0]),
                render.toUnorm8(rgba[1]),
                render.toUnorm8(rgba[2]),
                render.toUnorm8(rgba[3]),
            },
            .slot = slot,
            .shape = 0,
            .layer = layer,
        };
        if (!self.r2d.pushInstance(inst)) {
            self.stats.dropped += 1;
            return false;
        }
        return true;
    }

    fn fill(self: *Emitter, rect: Rect2, rgba: [4]f32, layer: u8) void {
        if (self.push(rect, full_uv, rgba, white_slot, layer)) self.stats.quads += 1;
    }

    /// A four-quad border inside `rect` (no nine-slice in v1). Degenerate
    /// thickness or a fully transparent colour draws nothing.
    fn border(self: *Emitter, rect: Rect2, rgba: [4]f32, thickness: f32, layer: u8) void {
        if (thickness <= 0 or rgba[3] <= 0) return;
        const t = @min(thickness, @min(rect.size.x, rect.size.y) * 0.5);
        if (t <= 0) return;
        const inner_h = @max(0, rect.size.y - t * 2);
        // top, bottom, then the two sides between them.
        self.fill(.{ .position = .{ .x = rect.left(), .y = rect.top() }, .size = .{ .x = rect.size.x, .y = t } }, rgba, layer);
        self.fill(.{ .position = .{ .x = rect.left(), .y = rect.bottom() - t }, .size = .{ .x = rect.size.x, .y = t } }, rgba, layer);
        self.fill(.{ .position = .{ .x = rect.left(), .y = rect.top() + t }, .size = .{ .x = t, .y = inner_h } }, rgba, layer);
        self.fill(.{ .position = .{ .x = rect.right() - t, .y = rect.top() + t }, .size = .{ .x = t, .y = inner_h } }, rgba, layer);
    }

    /// A run of text laid out inside `rect`, horizontally by `alignment` and
    /// vertically centred on the line box. One quad per drawable glyph.
    fn text(self: *Emitter, font: *Font, body: []const u8, rect: Rect2, alignment: components.TextAlign, rgba: [4]f32, layer: u8) void {
        if (body.len == 0) return;
        const width = font.measure(body);
        const start_x = switch (alignment) {
            .left => rect.left(),
            .center => rect.center().x - width * 0.5,
            .right => rect.right() - width,
        };
        // The line box centre sits `(ascent + descent) / 2` above the baseline
        // (descent is negative), so put the baseline that far below the rect's
        // vertical centre.
        const baseline = rect.center().y + (font.ascent + font.descent) * 0.5;

        var pen = start_x;
        var i: usize = 0;
        while (i < body.len) {
            const cp = nextCodepoint(body, &i);
            if (cp == '\n') continue; // v1 is single-line; a newline draws nothing
            const g = font.glyph(cp) orelse continue;
            if (g.has_pixels and g.width > 0 and g.height > 0) {
                const ok = self.push(.{
                    .position = .{ .x = pen + g.start_x, .y = baseline + g.start_y },
                    .size = .{ .x = g.width, .y = g.height },
                }, g.uv, rgba, font.slot, layer);
                if (ok) self.stats.glyphs += 1;
            }
            pen += g.advance;
        }
        // Lazily rasterized (non-ASCII) glyphs are only real once the page is
        // uploaded; a cache hit leaves the page clean and this is a no-op.
        font.flushAtlas();
    }
};

/// Emits this frame's UI into `r2d`, after the world has been collected and
/// before `submit`. Zero allocations on the ASCII path.
pub fn emit(
    r2d: *Renderer2D,
    world: *World,
    state: *const ui_system.State,
    opts: Options,
) Stats {
    var em = Emitter{
        .r2d = r2d,
        .world = world,
        .mapper = .{ .view = opts.view orelse defaultView(state.canvas) },
        .layer_base = state.canvas.layer_base,
        .fonts = opts.fonts,
    };

    for (state.slice()) |item| {
        if (!item.visible) continue;
        const layer = em.layerFor(item.order);
        switch (item.kind) {
            .panel => drawPanel(&em, item.entity, item.rect, layer),
            .progress => drawProgress(&em, item.entity, item.rect, layer),
            .button => drawButton(&em, item.entity, item.rect, layer),
            .label => drawLabel(&em, item.entity, item.rect, layer),
        }
    }
    return em.stats;
}

fn drawPanel(em: *Emitter, e: ecs.Entity, rect: Rect2, layer: u8) void {
    const panel = em.world.get(e, components.UiPanel) orelse return;
    em.fill(rect, panel.color, layer);
    em.border(rect, panel.border_color, panel.border_width, layer);
}

fn drawProgress(em: *Emitter, e: ecs.Entity, rect: Rect2, layer: u8) void {
    const bar = em.world.get(e, components.UiProgressBar) orelse return;
    em.fill(rect, bar.bg_color, layer);
    const v = std.math.clamp(bar.value, 0, 1);
    if (v > 0) {
        em.fill(.{
            .position = rect.position,
            .size = .{ .x = rect.size.x * v, .y = rect.size.y },
        }, bar.fill_color, layer);
    }
    if (bar.show_text and bar.text.len > 0) {
        if (em.fonts.resolve(bar.font)) |font| {
            // The plan gives the bar no text colour of its own; white reads on
            // both the background and the fill.
            em.text(font, bar.text.slice(), rect, .center, .{ 1, 1, 1, 1 }, layer);
        }
    }
}

fn drawButton(em: *Emitter, e: ecs.Entity, rect: Rect2, layer: u8) void {
    const btn = em.world.get(e, components.UiButton) orelse return;
    const bg = switch (btn.state) {
        .normal => btn.color_normal,
        .hover => btn.color_hover,
        .pressed => btn.color_pressed,
    };
    em.fill(rect, bg, layer);
    if (btn.text.len > 0) {
        if (em.fonts.resolve(btn.font)) |font| {
            em.text(font, btn.text.slice(), rect, .center, btn.text_color, layer);
        }
    }
}

fn drawLabel(em: *Emitter, e: ecs.Entity, rect: Rect2, layer: u8) void {
    const label = em.world.get(e, components.Label) orelse return;
    if (label.text.len == 0) return;
    if (em.fonts.resolve(label.font)) |font| {
        em.text(font, label.text.slice(), rect, label.alignment, label.color, layer);
    }
}

/// The same forgiving UTF-8 walk `font.zig` uses: an invalid sequence advances
/// by its first byte so a corrupt label renders boxes instead of stalling.
fn nextCodepoint(body: []const u8, i: *usize) u21 {
    const b0 = body[i.*];
    if (b0 < 0x80) {
        i.* += 1;
        return b0;
    }
    const len: usize = std.unicode.utf8ByteSequenceLength(b0) catch {
        i.* += 1;
        return b0;
    };
    if (i.* + len > body.len) {
        i.* += 1;
        return b0;
    }
    const cp = std.unicode.utf8Decode(body[i.* .. i.* + len]) catch {
        i.* += 1;
        return b0;
    };
    i.* += len;
    return cp;
}

// ── Tests ────────────────────────────────────────────────────────────────────

const testing = std.testing;

fn testCanvas() ui_system.Canvas {
    return .{
        .screen = .{ .position = .{}, .size = .{ .x = 1280, .y = 720 } },
        .logical = .{ .x = 1280, .y = 720 },
        .scale = .{ .x = 1, .y = 1 },
        .offset = .{ .x = 0, .y = 0 },
        .layer_base = 255,
    };
}

/// A renderer reserved and locked, ready for instance pushes.
fn testR2D() Renderer2D {
    var r2d = Renderer2D.init(testing.allocator);
    r2d.reserve(256) catch unreachable;
    r2d.lock();
    return r2d;
}

/// Runs the UI system (with no pointer) and then emits, so the tests exercise
/// the two halves exactly as the runtime will.
fn runFrame(r2d: *Renderer2D, world: *World, opts: Options) Stats {
    var state = ui_system.State{};
    ui_system.update(&state, world, testCanvas().screen.size, .{ .x = -100, .y = -100, .inside = false }, .{});
    return emit(r2d, world, &state, opts);
}

test "fills are one quad each, on the white slot" {
    var world = World.init(testing.allocator);
    defer world.deinit();
    _ = try world.spawn(.{components.UiPanel{
        .layout = .{ .anchor = .top_left, .offset = .{ .x = 0, .y = 0 }, .size = .{ .x = 100, .y = 40 } },
    }});
    _ = try world.spawn(.{components.UiProgressBar{
        .layout = .{ .anchor = .top_left, .offset = .{ .x = 0, .y = 50 }, .size = .{ .x = 100, .y = 10 } },
        .value = 0.5,
    }});

    var r2d = testR2D();
    defer r2d.deinit();
    const stats = runFrame(&r2d, &world, .{});

    // Panel 1 + bar background 1 + bar fill 1 = 3. No glyphs (no font source).
    try testing.expectEqual(@as(usize, 3), stats.quads);
    try testing.expectEqual(@as(usize, 0), stats.glyphs);
    for (r2d.instanceSlice()) |inst| try testing.expectEqual(white_slot, inst.slot);
}

test "a panel border adds four thin quads" {
    var world = World.init(testing.allocator);
    defer world.deinit();
    _ = try world.spawn(.{components.UiPanel{
        .layout = .{ .anchor = .top_left, .size = .{ .x = 100, .y = 40 } },
        .border_width = 2,
        .border_color = .{ 1, 1, 1, 1 },
    }});

    var r2d = testR2D();
    defer r2d.deinit();
    const stats = runFrame(&r2d, &world, .{});
    try testing.expectEqual(@as(usize, 5), stats.quads); // fill + 4 border strips
}

test "a zero-value bar draws no fill quad" {
    var world = World.init(testing.allocator);
    defer world.deinit();
    _ = try world.spawn(.{components.UiProgressBar{
        .layout = .{ .anchor = .top_left, .size = .{ .x = 100, .y = 10 } },
        .value = 0,
    }});

    var r2d = testR2D();
    defer r2d.deinit();
    const stats = runFrame(&r2d, &world, .{});
    try testing.expectEqual(@as(usize, 1), stats.quads); // background only
}

test "the button state selects the background colour" {
    var world = World.init(testing.allocator);
    defer world.deinit();
    const e = try world.spawn(.{components.UiButton{
        .layout = .{ .anchor = .top_left, .size = .{ .x = 100, .y = 30 } },
        .color_normal = .{ 0.1, 0.1, 0.1, 1 },
        .color_hover = .{ 0.2, 0.2, 0.2, 1 },
        .color_pressed = .{ 0.3, 0.3, 0.3, 1 },
    }});

    var r2d = testR2D();
    defer r2d.deinit();

    // The UI system writes the state; `emit` reads it. That is the contract
    // between the two halves, so drive it through the system.
    var state = ui_system.State{};
    ui_system.update(&state, &world, testCanvas().screen.size, .{ .x = 50, .y = 15, .down = false, .inside = true }, .{});
    try testing.expectEqual(components.UiButtonState.hover, world.get(e, components.UiButton).?.state);

    _ = emit(&r2d, &world, &state, .{});
    try testing.expectEqual(@as(usize, 1), r2d.instanceSlice().len);
    // toUnorm8(0.2) = 51: the hover colour reached the instance.
    try testing.expectEqual(@as(u8, 51), r2d.instanceSlice()[0].color[0]);
}

test "screen space converts through the camera to world units" {
    var world = World.init(testing.allocator);
    defer world.deinit();
    _ = try world.spawn(.{components.UiPanel{
        .layout = .{ .anchor = .top_left, .offset = .{ .x = 0, .y = 0 }, .size = .{ .x = 100, .y = 30 } },
    }});

    var r2d = testR2D();
    defer r2d.deinit();

    // A camera whose world rect is exactly (0,0)-(1280,720): world == y-up screen.
    const view = ecs.camera.View{ .cx = 640, .cy = 360, .zoom = 1, .viewport_w = 1280, .viewport_h = 720 };
    var state = ui_system.State{};
    ui_system.update(&state, &world, testCanvas().screen.size, .{ .x = -100, .y = -100, .inside = false }, .{});
    _ = emit(&r2d, &world, &state, .{ .view = view });

    const inst = r2d.instanceSlice()[0];
    // Centre of the panel is (50, 15) screen-down -> (50, 720-15=705) world.
    try testing.expectApproxEqAbs(@as(f32, 50), inst.pos[0], 1e-3);
    try testing.expectApproxEqAbs(@as(f32, 705), inst.pos[1], 1e-3);
    try testing.expectApproxEqAbs(@as(f32, 50), inst.half[0], 1e-3);
    try testing.expectApproxEqAbs(@as(f32, 15), inst.half[1], 1e-3);
}

test "with no camera the screen centre is the world origin" {
    var world = World.init(testing.allocator);
    defer world.deinit();
    // A 100x100 box centred on the screen: screen rect (590,310)-(690,410).
    _ = try world.spawn(.{components.UiPanel{
        .layout = .{ .anchor = .center, .pivot = .{ .x = 0.5, .y = 0.5 }, .size = .{ .x = 100, .y = 100 } },
    }});

    var r2d = testR2D();
    defer r2d.deinit();
    _ = runFrame(&r2d, &world, .{});
    const inst = r2d.instanceSlice()[0];
    // Centre of a screen-centred box is world (0,0) under makeCamera.
    try testing.expectApproxEqAbs(@as(f32, 0), inst.pos[0], 1e-3);
    try testing.expectApproxEqAbs(@as(f32, 0), inst.pos[1], 1e-3);
}

test "zoom scales the world-space half extents back down" {
    var world = World.init(testing.allocator);
    defer world.deinit();
    _ = try world.spawn(.{components.UiPanel{
        .layout = .{ .anchor = .top_left, .size = .{ .x = 100, .y = 30 } },
    }});

    var r2d = testR2D();
    defer r2d.deinit();
    const zoomed = ecs.camera.View{ .cx = 640, .cy = 360, .zoom = 2, .viewport_w = 1280, .viewport_h = 720 };
    var state = ui_system.State{};
    ui_system.update(&state, &world, testCanvas().screen.size, .{ .x = -100, .y = -100, .inside = false }, .{});
    _ = emit(&r2d, &world, &state, .{ .view = zoomed });

    const inst = r2d.instanceSlice()[0];
    // 100 screen px wide -> 50 world units at zoom 2.
    try testing.expectApproxEqAbs(@as(f32, 25), inst.half[0], 1e-3);
    try testing.expectApproxEqAbs(@as(f32, 7.5), inst.half[1], 1e-3);
}

test "ui instances carry layer_base + order, clamped to the byte" {
    var world = World.init(testing.allocator);
    defer world.deinit();
    _ = try world.spawn(.{components.UiPanel{ .layout = .{ .anchor = .full_rect, .order = 3 } }});

    var r2d = testR2D();
    defer r2d.deinit();
    var state = ui_system.State{};
    ui_system.update(&state, &world, testCanvas().screen.size, .{ .x = -1, .y = -1, .inside = false }, .{});
    state.canvas.layer_base = 200;
    _ = emit(&r2d, &world, &state, .{});
    try testing.expectEqual(@as(u8, 203), r2d.instanceSlice()[0].layer);
}

fn testFontBytes(allocator: std.mem.Allocator) ![]u8 {
    const io = std.Io.Threaded.global_single_threaded.io();
    return std.Io.Dir.cwd().readFileAlloc(io, "libs/fonts/Inter-Regular.ttf", allocator, .limited(8 << 20)) catch |err| switch (err) {
        error.FileNotFound => error.SkipZigTest,
        else => err,
    };
}

test "a label emits one quad per drawable glyph from the font slot" {
    const allocator = testing.allocator;
    const bytes = testFontBytes(allocator) catch |err| switch (err) {
        error.SkipZigTest => return error.SkipZigTest,
        else => return err,
    };
    defer allocator.free(bytes);

    var font = try Font.init(allocator, bytes, 20);
    defer font.deinit();

    var world = World.init(testing.allocator);
    defer world.deinit();
    var label = components.Label{ .layout = .{ .anchor = .top_left, .size = .{ .x = 200, .y = 40 } } };
    label.text.set("Hi");
    _ = try world.spawn(.{label});

    var r2d = testR2D();
    defer r2d.deinit();

    const Source = struct {
        fn get(ctx: ?*anyopaque, id: u32) ?*Font {
            _ = id;
            const f: *Font = @ptrCast(@alignCast(ctx.?));
            return f;
        }
    };
    const stats = runFrame(&r2d, &world, .{ .fonts = .{ .ctx = &font, .get = Source.get } });

    // 'H' and 'i' both have bitmaps at 20px: two glyph quads, no fills.
    try testing.expectEqual(@as(usize, 0), stats.quads);
    try testing.expectEqual(@as(usize, 2), stats.glyphs);
    try testing.expectEqual(@as(usize, 2), r2d.instanceSlice().len);
}

test "paint order is preserved: the UI instances land in system order" {
    var world = World.init(testing.allocator);
    defer world.deinit();
    _ = try world.spawn(.{components.UiPanel{ .layout = .{ .anchor = .full_rect, .order = 0 } }});
    _ = try world.spawn(.{components.UiProgressBar{ .layout = .{ .anchor = .full_rect, .order = 0 }, .value = 0.5 }});
    _ = try world.spawn(.{components.UiProgressBar{ .layout = .{ .anchor = .full_rect, .order = 5 }, .value = 0.5 }});

    var r2d = testR2D();
    defer r2d.deinit();
    var state = ui_system.State{};
    ui_system.update(&state, &world, testCanvas().screen.size, .{ .x = -1, .y = -1, .inside = false }, .{});
    try testing.expectEqual(@as(usize, 3), state.count);

    _ = emit(&r2d, &world, &state, .{});
    // panel(order0) fill, bar(order0) bg+fill, bar(order5) bg+fill = 5.
    try testing.expectEqual(@as(usize, 5), r2d.instanceSlice().len);
}

test "an invisible widget emits nothing" {
    var world = World.init(testing.allocator);
    defer world.deinit();
    _ = try world.spawn(.{components.UiPanel{
        .layout = .{ .anchor = .full_rect, .visible = false },
    }});

    var r2d = testR2D();
    defer r2d.deinit();
    const stats = runFrame(&r2d, &world, .{});
    try testing.expectEqual(@as(usize, 0), stats.quads);
    try testing.expectEqual(@as(usize, 0), r2d.instanceSlice().len);
}
