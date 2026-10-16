//! `ember-ui-demo` — the component gallery.
//!
//! ## Why this exists
//!
//! A UI framework is judged by looking at it, and the editor's `main.zig` is
//! being written by someone else at the same time. So the gallery is its own
//! executable with its own file: every component on screen, in every state, with
//! a live accent picker in the corner.
//!
//! It is the regression suite for the LOOK. When a widget's padding changes,
//! the change is visible here in about four seconds instead of "somewhere in the
//! editor, if you happen to open that panel and know to look".
//!
//! ## What it is not
//!
//! It is not the editor. It loads no scene and knows what an actor is not.
//! Everything on screen is either a component or a prop for one. That is the
//! point: the gallery proves the widgets; the editor proves the widgets work.

const std = @import("std");
const engine = @import("engine");
const core = engine.core;
const platform = engine.platform;
const ui = @import("ui");

const log = core.log.scoped("ui-demo");

/// The context the overlay callback draws with.
///
/// A file-level pointer rather than one passed through the renderer, because
/// `Renderer.drawOverlay` takes `(ctx, draw)` and the `ctx` is for the CALLER's
/// state. Threading the whole gallery through a renderer's vtable would make the
/// renderer know about a demo.
var active: ?*ui.Context = null;

pub fn main(init: std.process.Init.Minimal) !void {
    _ = init;
    const allocator = std.heap.c_allocator;

    try platform.init();
    defer platform.deinit();

    var window: platform.Window = try platform.Window.create(.{
        .title = "ember ui — components",
        .width = 1440,
        .height = 900,
        .resizable = true,
    });
    defer window.destroy();
    platform.setUserPointer(window.handle, &window);

    // The engine's own Dawn backend, because the UI draws INTO the swapchain
    // through the renderer's overlay hook and nothing else. There is no scene
    // here: acquire, overlay, present.
    const dawn = try engine.render.backend_dawn.Backend.create(
        allocator,
        window.nativeHandle(),
        window.fb_width,
        window.fb_height,
        engine.render.backend_dawn.Options{
            .vsync = true,
            .smaa = false,
            .max_sprites = 1024,
        },
    );
    var renderer = dawn.renderer();
    defer renderer.deinit();

    var ctx = try ui.Context.init(allocator, &window, dawn.gpuDevice(), dawn.swapchainFormat());
    defer ctx.deinit();
    active = &ctx;

    if (!ctx.stats.font_loaded) {
        log.warn("no Inter in libs/fonts — ImGui's bitmap font is in use", .{});
        log.warn("run `bash libs/bootstrap.sh` to fetch the typefaces", .{});
    }

    var gallery: Gallery = .{ .ctx = &ctx };
    var last = core.time.monotonicNs();
    var frames: u64 = 0;
    var fps_window = last;
    var fps: f32 = 0;

    while (true) {
        const now = core.time.monotonicNs();
        const dt = @as(f32, @floatFromInt(now - last)) / std.time.ns_per_s;
        last = now;

        window.poll();
        if (window.shouldClose()) break;

        // Resize, before anything reads the framebuffer size.
        const fb = window.framebufferSize();
        if (window.resized) {
            window.resized = false;
            renderer.resize(fb.w, fb.h);
        }

        frames += 1;
        if (now - fps_window > std.time.ns_per_s) {
            const elapsed: f32 = @floatFromInt(now - fps_window);
            fps = @as(f32, @floatFromInt(frames)) * @as(f32, @floatFromInt(std.time.ns_per_s)) / elapsed;
            frames = 0;
            fps_window = now;
        }

        // The frame, in the order the framework documents.
        ctx.newFrame(dt);
        gallery.draw(fps);

        renderer.beginFrame();
        renderer.acquireSurface();
        renderer.drawOverlay(null, struct {
            fn draw(_: ?*anyopaque, pass: ?*anyopaque) void {
                if (active) |c| c.render(pass);
            }
        }.draw);
        renderer.present();

        window.input.endFrame();
    }
}

// ── The gallery ──────────────────────────────────────────────────────────

/// The gallery the section bodies reach through.
///
/// A pointer rather than a parameter because a component body is
/// `fn (ctx, index) void` — the framework's convention, and the reason a
/// section body cannot accidentally capture the wrong gallery. One global
/// beats threading `*Gallery` through every callback signature in a demo.
var gal: ?*Gallery = null;

const Gallery = struct {
    ctx: *ui.Context,

    // Every piece of control state the gallery needs. In the editor all of this
    // would live in the `Store` under a path; here it is local, because the
    // gallery is the thing that DEMONSTRATES the components and nothing else.
    tab: usize = 0,
    checkbox: bool = true,
    switch_on: bool = true,
    segment: usize = 0,
    select_value: usize = 2,
    number: f32 = 12.5,
    range: f32 = 0.62,
    progress: f32 = 0.45,
    list_selected: usize = 2,
    tree_selected: usize = 1,
    collapse_a: bool = true,
    collapse_b: bool = false,
    modal_open: bool = false,
    menu_open: bool = false,
    last_action: []const u8 = "—",
    clicks: u32 = 0,

    name: [128]u8 = @splat(0),
    search: [128]u8 = @splat(0),
    comment: [512]u8 = @splat(0),

    // The colour pickers. Three of them, because one swatch proves nothing:
    // an opaque accent, a translucent tint (so the checkerboard is on screen),
    // and one with the hex field wired to a buffer, which is the mode that
    // proves the round trip through `parseHex` works while typing.
    color: ui.Rgba = ui.Rgba.hex(0x2F81F7, 1.0),
    tint: ui.Rgba = ui.Rgba.hex(0xF85149, 0.4),
    color_hex: [16]u8 = @splat(0),
    color_hexed: ui.Rgba = ui.Rgba.hex(0x3FB950, 1.0),

    // The easing curve editor. One curve, edited by dragging its two handles,
    // with a preview dot walking it every second so the shape is felt and not
    // only seen.
    easing: ui.Easing = ui.curve.Preset.ease_in_out.easing(),

    fn draw(self: *Gallery, fps: f32) void {
        gal = self;
        const c = self.ctx;

        // Full-bleed, no decoration: a gallery of windows inside a window with
        // a title bar is two demonstrations of the same thing, and the outer
        // one hides the inner one's padding.
        // The flags are already integers: `cimgui.WindowFlags` is a struct of
        // u32 constants, not an enum, so they OR directly.
        const flags: u32 = ui.cimgui.WindowFlags.NoDecoration |
            ui.cimgui.WindowFlags.NoMove |
            ui.cimgui.WindowFlags.NoSavedSettings;
        ui.cimgui.ember_ui_set_next_window_pos(
            @as(f32, @floatFromInt(c.window.fb_width)) * 0.5,
            @as(f32, @floatFromInt(c.window.fb_height)) * 0.5,
            @intFromEnum(ui.cimgui.Cond.Always),
        );
        ui.cimgui.ember_ui_set_next_window_size(
            @floatFromInt(c.window.fb_width),
            @floatFromInt(c.window.fb_height),
            @intFromEnum(ui.cimgui.Cond.Always),
        );
        if (ui.cimgui.ember_ui_begin("gallery", @bitCast(flags)) == 0) return;
        defer ui.cimgui.ember_ui_end();

        self.topbar();
        ui.cimgui.ember_ui_dummy(1, c.theme.metrics.gap());
        self.tabs_bar();
        _ = fps;
    }

    fn topbar(self: *Gallery) void {
        const ctx = self.ctx;
        const t = &ctx.theme;
        const m = &t.metrics;

        ui.cimgui.ember_ui_dummy(ui.draw.contentAvail().x, 40);
        const bar = ui.draw.itemRect();
        {
            const list = ui.draw.itemList();
            list.rect(bar, t.colors.surface, 0);
            list.rect(ui.draw.rect(bar.min.x, bar.max.y - 1, bar.max.x, bar.max.y), t.colors.border, 0);
        }
        ui.draw.setCursorPos(.{ .x = bar.min.x + m.panel_pad(), .y = bar.min.y + 6 });
        const start = ui.draw.cursorPos();

        _ = ui.IconButton(.{ .ctx = ctx, .id = "play", .icon = .play, .tooltip = "Play (F6)", .on_click = bump, .ctx_arg = self });
        _ = ui.IconButton(.{ .ctx = ctx, .id = "stop", .icon = .stop, .tooltip = "Stop (Shift+F6)", .on_click = bump, .ctx_arg = self });
        _ = ui.IconButton(.{ .ctx = ctx, .id = "undo", .icon = .undo, .variant = .ghost, .tooltip = "Undo", .on_click = bump, .ctx_arg = self });
        _ = ui.IconButton(.{ .ctx = ctx, .id = "redo", .icon = .redo, .variant = .ghost, .tooltip = "Redo", .on_click = bump, .ctx_arg = self });
        ui.gap(m.gap() * 2);
        _ = ui.Button(.{ .ctx = ctx, .id = "save", .text = "Save", .icon = .save, .on_click = bump, .ctx_arg = self });
        _ = ui.Button(.{ .ctx = ctx, .id = "ghost", .text = "Ghost", .variant = .ghost, .on_click = bump, .ctx_arg = self });
        _ = ui.Button(.{ .ctx = ctx, .id = "disabled", .text = "Disabled", .disabled = true });
        _ = ui.Button(.{ .ctx = ctx, .id = "delete", .text = "Delete", .icon = .trash, .variant = .danger, .on_click = bump, .ctx_arg = self });

        const after = ui.draw.cursorPos();
        ui.draw.setCursorPos(.{ .x = start.x, .y = after.y });

        // Right side: the accent, live. One colour picker that changes the
        // whole editor is the fastest way to see whether a palette is a palette
        // or a list of colours that happen to be dark.
        ui.spacerToEnd(ctx);
        var accent: [4]f32 = .{ t.colors.accent.r, t.colors.accent.g, t.colors.accent.b, 1 };
        ui.cimgui.ember_ui_set_next_item_width(160);
        _ = ui.cimgui.ember_ui_color_edit4("accent", &accent[0], 0);
        ui.gap(m.gap());
        _ = ui.IconButton(.{ .ctx = ctx, .id = "modal", .icon = .gear, .tooltip = "Open a dialog", .on_click = openModal, .ctx_arg = self });
        _ = ui.IconButton(.{ .ctx = ctx, .id = "menu", .icon = .list_, .tooltip = "Toggle a menu", .on_click = toggleMenu, .ctx_arg = self });
    }

    fn tabs_bar(self: *Gallery) void {
        const ctx = self.ctx;
        const tab_list = [_]ui.tabs.Tab{
            .{ .id = "basics", .label = "Basics", .icon = .grid },
            .{ .id = "inputs", .label = "Inputs", .icon = .list_ },
            .{ .id = "containers", .label = "Containers", .icon = .folder },
            .{ .id = "feedback", .label = "Feedback", .icon = .info_ },
            .{ .id = "color", .label = "Color", .icon = .camera },
        };
        ui.Tabs(.{
            .ctx = ctx,
            .id = "workspace",
            .tabs = &tab_list,
            .selected = &self.tab,
            .body = struct {
                fn body(c: *ui.Context, index: usize) void {
                    const g = gal orelse return;
                    switch (index) {
                        0 => g.section_basics(),
                        1 => g.section_inputs(),
                        2 => g.section_containers(),
                        3 => g.section_feedback(),
                        else => g.section_color(),
                    }
                    _ = c;
                }
            }.body,
        });
    }

    fn section_basics(self: *Gallery) void {
        const ctx = self.ctx;
        const m = &ctx.theme.metrics;

        ui.Card(.{
            .ctx = ctx,
            .id = "buttons",
            .title = "Buttons",
            .subtitle = "five variants, four states",
            .icon = .grid,
            .height = 250,
            .body = struct {
                fn body(c: *ui.Context) void {
                    const g = gal.?;
                    const mm = &c.theme.metrics;
                    _ = ui.Button(.{ .ctx = c, .id = "b1", .text = "Primary", .variant = .primary, .on_click = bump, .ctx_arg = g });
                    ui.gap(mm.gap());
                    _ = ui.Button(.{ .ctx = c, .id = "b2", .text = "Secondary", .on_click = bump, .ctx_arg = g });
                    ui.gap(mm.gap());
                    _ = ui.Button(.{ .ctx = c, .id = "b3", .text = "Ghost", .variant = .ghost, .on_click = bump, .ctx_arg = g });
                    ui.gap(mm.gap());
                    _ = ui.Button(.{ .ctx = c, .id = "b4", .text = "Disabled", .disabled = true });
                    ui.gap(mm.gap());
                    _ = ui.Button(.{ .ctx = c, .id = "b5", .text = "With icon", .icon = .gear, .on_click = bump, .ctx_arg = g });

                    ui.cimgui.ember_ui_same_line(0, mm.gap() * 2);
                    _ = ui.IconButton(.{ .ctx = c, .id = "b6", .icon = .save, .tooltip = "Save", .on_click = bump, .ctx_arg = g });
                    _ = ui.IconButton(.{ .ctx = c, .id = "b7", .icon = .search, .variant = .ghost });
                    _ = ui.IconButton(.{ .ctx = c, .id = "b8", .icon = .gear, .variant = .ghost });
                    _ = ui.IconButton(.{ .ctx = c, .id = "b9", .icon = .trash, .variant = .danger, .on_click = bump, .ctx_arg = g });

                    ui.space(c, 1);
                    ui.Caption(c, "A dialog's action row — equal widths, primary last:");
                    ui.space(c, 0.5);
                    ui.button.row(c, "actions", &[_]ui.button.Item{
                        .{ .text = "Cancel", .variant = .secondary, .on_click = bump, .ctx_arg = g },
                        .{ .text = "Apply", .variant = .secondary, .on_click = bump, .ctx_arg = g },
                        .{ .text = "Save", .variant = .primary, .icon = .save, .on_click = bump, .ctx_arg = g },
                    }, .{ .stretch = true });
                }
            }.body,
        });
        ui.cimgui.ember_ui_dummy(1, m.gap());

        ui.Card(.{
            .ctx = ctx,
            .id = "toggles",
            .title = "Toggles",
            .subtitle = "checkbox, switch, segmented",
            .icon = .check,
            .height = 210,
            .body = struct {
                fn body(c: *ui.Context) void {
                    const g = gal.?;
                    const segs = [_]ui.toggle.Segment{
                        .{ .id = "2d", .label = "2D" },
                        .{ .id = "script", .label = "Script" },
                        .{ .id = "world", .label = "World" },
                    };
                    _ = ui.Checkbox(.{
                        .ctx = c,
                        .id = "chk",
                        .label = "Show grid",
                        .value = &g.checkbox,
                        .tooltip = "A checkbox is a setting in a list",
                    });
                    ui.space(c, 0.5);
                    _ = ui.Checkbox(.{
                        .ctx = c,
                        .id = "chk-off",
                        .label = "Disabled checkbox",
                        .value = &g.checkbox,
                        .disabled = true,
                    });
                    ui.space(c, 0.5);
                    _ = ui.Switch(.{
                        .ctx = c,
                        .id = "sw",
                        .label = "Physics debug (live)",
                        .value = &g.switch_on,
                        .tooltip = "A switch is a thing that is running now",
                    });
                    ui.space(c, 1);
                    _ = ui.Segmented(.{ .ctx = c, .id = "seg", .segments = &segs, .selected = &g.segment });
                }
            }.body,
        });
    }

    fn section_inputs(self: *Gallery) void {
        const ctx = self.ctx;
        const m = &ctx.theme.metrics;

        ui.Card(.{
            .ctx = ctx,
            .id = "fields",
            .title = "Fields",
            .subtitle = "text, search, number, slider, select",
            .icon = .list_,
            .height = 430,
            .body = struct {
                fn body(c: *ui.Context) void {
                    const g = gal.?;
                    const opts = [_]ui.select.Option{
                        .{ .value = 0, .label = "Sprite", .hint = "32x32" },
                        .{ .value = 2, .label = "Animated", .hint = "8 frames" },
                        .{ .value = 3, .label = "Tilemap", .hint = "16x16" },
                        .{ .value = 4, .label = "Font", .hint = "OFL" },
                    };
                    _ = ui.TextField(.{ .ctx = c, .id = "name", .label = "Name", .buf = &g.name, .capacity = 128, .placeholder = "player_sprite", .label_slot = 90, .width = 260 });
                    ui.space(c, 0.5);
                    _ = ui.SearchField(.{
                        .ctx = c,
                        .id = "search",
                        .buf = &g.search,
                        .capacity = 128,
                        .placeholder = "Search assets",
                        .width = 350,
                    });
                    ui.space(c, 0.5);
                    _ = ui.NumberField(.{ .ctx = c, .id = "n", .label = "Offset", .value = &g.number, .speed = 0.2, .format = "%.2f", .unit = "px", .label_slot = 90, .width = 260 });
                    ui.space(c, 0.5);
                    _ = ui.Slider(.{ .ctx = c, .id = "range", .label = "Opacity", .value = &g.range, .label_slot = 90, .width = 260 });
                    ui.space(c, 0.5);
                    _ = ui.Select(.{
                        .ctx = c,
                        .id = "sel",
                        .label = "Type",
                        .options = &opts,
                        .selected = &g.select_value,
                        .label_slot = 90,
                        .width = 260,
                    });
                    ui.space(c, 1);
                    ui.Label(c, "Description");
                    ui.space(c, 0.25);
                    _ = ui.TextField(.{
                        .ctx = c,
                        .id = "comment",
                        .buf = &g.comment,
                        .capacity = 512,
                        .placeholder = "What is this actor for?",
                        .multiline = true,
                        .height = 72,
                    });
                }
            }.body,
        });
        _ = m;
    }

    fn section_containers(self: *Gallery) void {
        const ctx = self.ctx;
        const m = &ctx.theme.metrics;

        ui.Card(.{
            .ctx = ctx,
            .id = "list",
            .title = "List",
            .subtitle = "rows with icons, trailing values and selection",
            .icon = .layers,
            .height = 300,
            .body = struct {
                fn body(c: *ui.Context) void {
                    const g = gal.?;
                    const rows = [_]ui.list.Row{
                        .{ .id = "a", .label = "player", .icon = .file, .trailing = "Sprite" },
                        .{ .id = "b", .label = "enemies", .icon = .folder, .trailing = "12 actors", .selected = g.list_selected == 1 },
                        .{ .id = "c", .label = "tileset", .icon = .grid, .trailing = "16x16", .selected = g.list_selected == 2, .dot = c.theme.colors.warning },
                        .{ .id = "d", .label = "main.lua", .icon = .file, .trailing = "Script", .selectable = false },
                    };
                    for (rows, 0..) |r, i| {
                        _ = ui.Row2(r, .{
                            .ctx = c,
                            .on_click = selectRow,
                            .ctx_arg = g,
                        });
                        if (std.mem.eql(u8, r.id, "b")) g.list_selected = i;
                    }
                }
            }.body,
        });
        ui.cimgui.ember_ui_dummy(1, m.gap());

        ui.Card(.{
            .ctx = ctx,
            .id = "tree",
            .title = "Tree",
            .subtitle = "open state in the store, by path",
            .icon = .folder,
            .height = 240,
            .body = struct {
                fn body(c: *ui.Context) void {
                    const g = gal.?;
                    const nodes = [_]ui.list.TreeNode{
                        .{ .id = "scene", .label = "main.zson", .icon = .file, .trailing = "scene" },
                        .{ .id = "actors", .label = "actors", .trailing = "34" },
                        .{ .id = "assets", .label = "assets", .trailing = "128" },
                        .{ .id = "scripts", .label = "scripts", .trailing = "12" },
                    };
                    ui.Tree(.{
                        .ctx = c,
                        .open_prefix = "gallery/tree",
                        .nodes = &nodes,
                        .selected = &g.tree_selected,
                    });
                    ui.space(c, 0.5);
                    _ = ui.Collapse(.{
                        .ctx = c,
                        .id = "col-a",
                        .label = "Collapsible section",
                        .open = &g.collapse_a,
                        .icon = .layers,
                        .trailing = "12",
                    });
                    if (g.collapse_a) {
                        ui.column(c, 24, struct {
                            fn body(cc: *ui.Context) void {
                                ui.Caption(cc, "Indented content, collapsed by one flag in the store.");
                            }
                        }.body);
                    }
                    _ = ui.Collapse(.{
                        .ctx = c,
                        .id = "col-b",
                        .label = "Another one",
                        .open = &g.collapse_b,
                    });
                    if (g.collapse_b) {
                        ui.column(c, 24, struct {
                            fn body(cc: *ui.Context) void {
                                ui.Caption(cc, "The same widget, closed.");
                            }
                        }.body);
                    }
                }
            }.body,
        });
    }

    fn section_color(self: *Gallery) void {
        const ctx = self.ctx;
        const m = &ctx.theme.metrics;

        ui.Card(.{
            .ctx = ctx,
            .id = "colors",
            .title = "Color",
            .subtitle = "swatch, hue bar, sat/value square, hex",
            .icon = .camera,
            .height = 300,
            .body = struct {
                fn body(c: *ui.Context) void {
                    const g = gal.?;
                    ui.Label(c, "Click a swatch to open the picker.");
                    ui.space(c, 0.5);
                    _ = ui.ColorField(.{
                        .ctx = c,
                        .id = "accent",
                        .label = "Accent",
                        .value = &g.color,
                        .label_slot = 90,
                        .tooltip = "Opaque: no alpha bar in the popup",
                        .on_change = colorChanged,
                        .ctx_arg = g,
                    });
                    ui.space(c, 0.5);
                    _ = ui.ColorField(.{
                        .ctx = c,
                        .id = "tint",
                        .label = "Tint",
                        .value = &g.tint,
                        .label_slot = 90,
                        .tooltip = "Translucent: the swatch shows the checkerboard",
                        .on_change = colorChanged,
                        .ctx_arg = g,
                    });
                    ui.space(c, 0.5);
                    _ = ui.ColorField(.{
                        .ctx = c,
                        .id = "typed",
                        .label = "Typed hex",
                        .value = &g.color_hexed,
                        .label_slot = 90,
                        .hex_buf = &g.color_hex,
                        .hex_capacity = 16,
                        .tooltip = "Type #RRGGBBAA into the popup's Hex field",
                        .on_change = colorChanged,
                        .ctx_arg = g,
                    });
                    ui.space(c, 1);
                    // The maths, shown. A picker is a conversion with handles,
                    // and a gallery that shows the numbers is a gallery where a
                    // wrong hue is visible without opening a debugger.
                    var buf: [128]u8 = undefined;
                    const hsv = ui.color.rgbToHsv(g.color);
                    var hexb: [12]u8 = undefined;
                    const hex = ui.color.hexString(g.color, &hexb, false);
                    const s = std.fmt.bufPrint(
                        &buf,
                        "{s}   H {d:.0}°   S {d:.0}%   V {d:.0}%   A {d:.2}",
                        .{ hex, hsv.h, hsv.s * 100.0, hsv.v * 100.0, hsv.a },
                    ) catch "…";
                    ui.Caption(c, s);
                }
            }.body,
        });
        ui.cimgui.ember_ui_dummy(1, m.gap());

        ui.Card(.{
            .ctx = ctx,
            .id = "curves",
            .title = "Easing curve",
            .subtitle = "cubic bezier — drag the two handles",
            .icon = .refresh,
            .height = 260,
            .body = struct {
                fn body(c: *ui.Context) void {
                    const g = gal.?;
                    const phase: f32 = @floatCast(c.now() * 0.6);
                    const preview = @mod(phase, 1.0);
                    _ = ui.CurveField(.{
                        .ctx = c,
                        .id = "easing",
                        .label = "Curve",
                        .easing = &g.easing,
                        .label_slot = 90,
                        .preview = preview,
                        .on_change = colorChanged,
                        .ctx_arg = g,
                    });
                    ui.space(c, 0.5);
                    var tuple_buf: [64]u8 = undefined;
                    const tuple = ui.curve.format(g.easing, &tuple_buf);
                    var buf: [160]u8 = undefined;
                    const s = std.fmt.bufPrint(
                        &buf,
                        "cubic-bezier{s}   at(0.5) = {d:.3}   velocity(0.5) = {d:.2}",
                        .{ tuple, g.easing.at(0.5), g.easing.velocity(0.5) },
                    ) catch "…";
                    ui.Caption(c, s);
                }
            }.body,
        });
        ui.cimgui.ember_ui_dummy(1, m.gap());

        ui.Card(.{
            .ctx = ctx,
            .id = "swatches",
            .title = "Palette",
            .subtitle = "the theme's own tokens, as swatches",
            .icon = .grid,
            .height = 150,
            .body = struct {
                fn body(c: *ui.Context) void {
                    const p = c.theme.colors;
                    const row = [_]ui.Rgba{
                        p.bg,         p.surface,      p.surface_hi, p.surface_hi2,
                        p.accent,     p.success,      p.warning,    p.danger,
                        p.text,       p.text_dim,     p.border,     p.overlay,
                    };
                    for (row, 0..) |col, i| {
                        const r = ui.draw.rect(
                            ui.draw.cursorPos().x,
                            ui.draw.cursorPos().y,
                            ui.draw.cursorPos().x + 46,
                            ui.draw.cursorPos().y + 34,
                        );
                        _ = ui.cimgui.ember_ui_invisible_button("sw", 46, 34, 0);
                        ui.color.paintSwatch(ui.draw.List.item(), &c.theme, ui.draw.itemRect(), col, false);
                        _ = r;
                        if (i % 6 != 5) ui.cimgui.ember_ui_same_line(0, c.theme.metrics.gap());
                    }
                }
            }.body,
        });
    }

    fn section_feedback(self: *Gallery) void {
        const ctx = self.ctx;

        ui.Card(.{
            .ctx = ctx,
            .id = "progress",
            .title = "Progress",
            .subtitle = "bar, spinner, status, badges",
            .icon = .info_,
            .height = 250,
            .body = struct {
                fn body(c: *ui.Context) void {
                    const g = gal.?;
                    _ = ui.Progress(.{ .ctx = c, .value = g.progress, .label = "Importing textures" });
                    ui.space(c, 0.5);
                    _ = ui.Progress(.{ .ctx = c, .value = g.progress, .show_percent = true });
                    ui.space(c, 0.5);
                    _ = ui.Progress(.{ .ctx = c, .value = 0.8, .tone = .success, .label = "Saved" });
                    ui.space(c, 0.5);
                    _ = ui.Progress(.{ .ctx = c, .value = 0.3, .tone = .danger, .label = "3 errors" });
                    ui.space(c, 0.5);
                    _ = ui.Status(.{ .ctx = c, .icon = .success_, .text = "Scene saved in 42 ms", .tone = .success });
                    _ = ui.Status(.{ .ctx = c, .icon = .warning_, .text = "2 scripts failed to compile", .tone = .warning });
                    _ = ui.Status(.{ .ctx = c, .icon = .error_, .text = "player.prefab:12 — unknown function", .tone = .danger });
                    ui.space(c, 0.5);
                    ui.Badge(.{ .ctx = c, .text = "neutral" });
                    ui.Badge(.{ .ctx = c, .text = "accent", .tone = .accent });
                    ui.Badge(.{ .ctx = c, .text = "success", .tone = .success });
                    ui.Badge(.{ .ctx = c, .text = "warning", .tone = .warning });
                    ui.Badge(.{ .ctx = c, .text = "danger", .tone = .danger });
                    ui.gap(c.theme.metrics.gap());
                    ui.kbd(c, "Ctrl S");
                    ui.gap(4);
                    ui.kbd(c, "Shift F6");
                }
            }.body,
        });

        // The popups, opened by the two buttons in the top bar.
        ui.Modal(.{
            .ctx = ctx,
            .id = "confirm",
            .open = &self.modal_open,
            .title = "Delete 3 actors?",
            .width = 420,
            .body = struct {
                fn body(c: *ui.Context) void {
                    ui.Label(c, "This cannot be undone. The scene is saved first.");
                    ui.space(c, 0.5);
                    ui.Caption(c, "actors/  •  3 selected  •  main.zson");
                }
            }.body,
            .footer = struct {
                fn body(c: *ui.Context) void {
                    const g = gal.?;
                    ui.button.row(c, "confirm-actions", &[_]ui.button.Item{
                        .{ .text = "Cancel", .variant = .secondary, .on_click = closeModal, .ctx_arg = g },
                        .{ .text = "Delete", .icon = .trash, .variant = .danger, .on_click = confirmModal, .ctx_arg = g },
                    }, .{ .stretch = true });
                }
            }.body,
        });

        if (self.menu_open) {
            _ = ui.MenuItem(ctx, "mi1", "Rename", .{ .icon = .file, .shortcut = "F2" });
            _ = ui.MenuItem(ctx, "mi2", "Duplicate", .{ .icon = .copy, .shortcut = "Ctrl D" });
            _ = ui.MenuItem(ctx, "mi3", "Delete", .{ .icon = .trash, .shortcut = "Del" });
        }

        self.statusbar();
    }

    fn statusbar(self: *Gallery) void {
        const ctx = self.ctx;
        const m = &ctx.theme.metrics;
        const avail = ui.draw.contentAvail();
        ui.draw.setCursorPos(.{ .x = avail.x, .y = avail.y - 24 });
        _ = m;
        var buf: [160]u8 = undefined;
        const s = std.fmt.bufPrint(
            &buf,
            "frame {d}   draw cmds {d}   want-mouse {s}   want-text {s}   clicks {d}   last {s}",
            .{ ctx.stats.frame, ctx.drawCommands(), yesNo(ctx.wantsMouse()), yesNo(ctx.wantsKeyboard()), self.clicks, self.last_action },
        ) catch "…";
        ui.Status(.{ .ctx = ctx, .icon = .info_, .text = s, .tone = .neutral });
    }
};

fn yesNo(b: bool) []const u8 {
    return if (b) "yes" else "no";
}

fn colorChanged(arg: ?*anyopaque) void {
    const g: *Gallery = @ptrCast(@alignCast(arg orelse return));
    g.last_action = "color";
}

fn bump(arg: ?*anyopaque) void {
    const g: *Gallery = @ptrCast(@alignCast(arg orelse return));
    g.clicks += 1;
    g.last_action = "button";
}

fn selectRow(arg: ?*anyopaque, row_id: []const u8) void {
    const g: *Gallery = @ptrCast(@alignCast(arg orelse return));
    g.last_action = row_id;
}

fn openModal(arg: ?*anyopaque) void {
    const g: *Gallery = @ptrCast(@alignCast(arg orelse return));
    g.modal_open = true;
    g.last_action = "dialog";
}

fn toggleMenu(arg: ?*anyopaque) void {
    const g: *Gallery = @ptrCast(@alignCast(arg orelse return));
    g.menu_open = !g.menu_open;
}

fn closeModal(arg: ?*anyopaque) void {
    const g: *Gallery = @ptrCast(@alignCast(arg orelse return));
    g.modal_open = false;
}

fn confirmModal(arg: ?*anyopaque) void {
    const g: *Gallery = @ptrCast(@alignCast(arg orelse return));
    g.modal_open = false;
    g.clicks += 1;
    g.last_action = "delete confirmed";
}
