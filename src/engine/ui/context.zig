//! `ui.context` — the one piece of UI state that is not addressable by a path.
//!
//! ## What belongs here and what does not
//!
//! Everything that is a *fact about the session* (the theme, the DPI, the
//! store of path-addressed state) lives in `Context`; everything that is a
//! *fact about a panel* lives in the `Store` under a path (see `reactive.zig`).
//! The test is whether two different panels could want different values: if
//! they could, it is a `Store` key, and if they could not — because there is
//! only ever one editor — it is a field here.
//!
//! ## The frame
//!
//! ```zig
//! ctx.newFrame(dt);          // 1. feed the window's input, open the frame
//! drawTheEditor(ctx);        // 2. the editor's own code: Begin/End + widgets
//! ctx.render(pass_encoder);  // 3. close the frame, hand the draw data to Dawn
//! ```
//!
//! Step 1 and step 3 are the ONLY two places that talk to ImGui's frame
//! lifecycle, and `context.zig` is the only file that knows they exist. A
//! widget that called `NewFrame` would be a widget that has opinions about
//! ordering, and the bug would only appear when two widgets disagreed.

const std = @import("std");
const cimgui = @import("cimgui.zig");
const keys = @import("keys.zig");
const theme_mod = @import("theme.zig");
const reactive = @import("reactive.zig");
// Same rule as `keys.zig`: `platform` is an import declared in build.zig,
// not a path. See the note there.
const platform = @import("platform");

/// Where the UI's typefaces and settings come from.
///
/// Defaults are the ones in `libs/`, fetched by the bootstrap. A missing file
/// is NOT fatal: the editor comes up on ImGui's built-in font and says so in
/// `Context.stats.font_loaded`, because a tool that refuses to start because a
/// font did not download is worse than one that looks slightly wrong.
pub const Fonts = struct {
    ui: ?[*:0]const u8 = "libs/fonts/Inter-Regular.ttf",
    ui_medium: ?[*:0]const u8 = "libs/fonts/Inter-Medium.ttf",
    ui_semibold: ?[*:0]const u8 = "libs/fonts/Inter-SemiBold.ttf",
    mono: ?[*:0]const u8 = "libs/fonts/JetBrainsMono-Regular.ttf",
    mono_medium: ?[*:0]const u8 = "libs/fonts/JetBrainsMono-Medium.ttf",
};

/// What a frame cost. Not a vanity metric: spec §2 budgets the editor overlay
/// at 2 ms, and a number nobody reads is a budget nobody keeps.
pub const Stats = struct {
    /// Draw commands ImGui queued this frame. ImGui batches, so a busy panel
    /// is a handful of commands; the number that matters is the CPU time.
    draw_commands: usize = 0,
    /// The typefaces that actually loaded. See `Fonts`.
    font_loaded: bool = false,
    /// True while ImGui wants the mouse — i.e. while the cursor is over a
    /// panel. The game input path reads this so that clicking a button does
    /// not also click the game.
    want_mouse: bool = false,
    want_keyboard: bool = false,
    want_text_input: bool = false,
    /// Frames rendered since `init`. Used by the demo's FPS readout and by the
    /// "the UI is not drawing at all" assertion.
    frame: u64 = 0,
};

pub const Error = error{
    ImguiUnavailable,
    RendererUnavailable,
    /// The engine's Dawn device or swapchain format was not what the UI needs.
    /// Almost always means the caller initialised the UI before the renderer.
    BadDevice,
};

pub const Context = struct {
    allocator: std.mem.Allocator,
    window: *platform.Window,
    store: reactive.Store,
    theme: theme_mod.Theme,
    stats: Stats = .{},

    /// The engine's Dawn device, borrowed. `?*anyopaque` and not a typed
    /// handle so this file does not import `webgpu.zig`: the UI must not be
    /// able to touch the device, only to hand it to ImGui once.
    device: ?*anyopaque = null,
    swapchain_format: u32 = 0,
    frames_in_flight: c_int = 3,

    /// Font handles, by face. -1 means "not loaded".
    font_ui: c_int = -1,
    font_ui_medium: c_int = -1,
    font_ui_semibold: c_int = -1,
    font_mono: c_int = -1,
    font_mono_medium: c_int = -1,

    /// The previous key state, so only the keys that CHANGED are submitted.
    ///
    /// ImGui's input model is edge-based (`AddKeyEvent` twice with the same
    /// value is not a key repeat; it is a key that was pressed and released in
    /// the same frame). Submitting the full 350-key state every frame would
    /// also be 350 calls of noise. The delta is 3 lines and it is also correct
    /// about the "key pressed and released inside one frame" case, which
    /// happens on every fast typist and on every frame that runs long.
    prev_keys: [352]bool = [_]bool{false} ** 352,
    prev_mouse: [8]bool = [_]bool{false} ** 8,
    /// Suppresses ImGui's own hover handling for one frame after the window
    /// moves, so a panel does not light up under a cursor that did not move.
    mouse_valid: bool = true,

    /// Set when the user asked to close the editor. Read by the owner, not by
    /// the UI: the UI is a guest in the window.
    quit_requested: bool = false,

    pub fn init(
        allocator: std.mem.Allocator,
        window: *platform.Window,
        device: ?*anyopaque,
        swapchain_format: u32,
    ) Error!Context {
        if (cimgui.ember_ui_create() == 0) return Error.ImguiUnavailable;
        if (device == null or swapchain_format == 0) return Error.BadDevice;
        if (cimgui.ember_ui_init_renderer(device, swapchain_format, 3) == 0) {
            cimgui.ember_ui_destroy();
            return Error.RendererUnavailable;
        }

        var self: Context = .{
            .allocator = allocator,
            .window = window,
            .store = reactive.Store.init(allocator),
            .theme = .{},
            .device = device,
            .swapchain_format = swapchain_format,
        };
        self.loadFonts(Fonts{});
        self.theme.apply();
        return self;
    }

    pub fn deinit(self: *Context) void {
        cimgui.ember_ui_shutdown_renderer();
        cimgui.ember_ui_destroy();
        self.store.deinit();
    }

    /// Loads the typefaces. A missing file is a warning, not an error: see the
    /// struct comment.
    pub fn loadFonts(self: *Context, fonts: Fonts) void {
        const t = &self.theme;
        self.font_ui = loadOne(fonts.ui, t.font_size);
        self.font_ui_medium = loadOne(fonts.ui_medium, t.font_size);
        self.font_ui_semibold = loadOne(fonts.ui_semibold, t.font_size);
        self.font_mono = loadOne(fonts.mono, t.mono_size);
        self.font_mono_medium = loadOne(fonts.mono_medium, t.mono_size);
        self.stats.font_loaded = self.font_ui >= 0;
        // The DEFAULT face is what ImGui binds when nothing is pushed, so this
        // one line is what makes the whole editor use Inter instead of the
        // bitmap font. Everything else opts in by pushing.
        if (self.font_ui >= 0) cimgui.ember_ui_set_font(self.font_ui);
    }

    fn loadOne(path: ?[*:0]const u8, size: f32) c_int {
        const p = path orelse return -1;
        return cimgui.ember_ui_load_font(p, size);
    }

    // ── Fonts ────────────────────────────────────────────────────────────

    /// Runs `body` with a face pushed, restoring the previous one after.
    ///
    /// A template rather than a `fn` pointer, because every caller passes ONE
    /// function and its arguments: a Zig `struct { fn body(...) }` literal. The
    /// template resolves `body` to that function and `args` to its arguments, so
    /// the caller writes
    ///
    ///     ctx.withFont(.ui_semibold, body, .{ ctx, "Title", colour });
    ///
    /// which is the same shape as every other "draw this with a font" call in
    /// the file — and the reason it is a template, not a callback: `anytype`
    /// with a bare `body()` resolves `body` as a TYPE and fails with "type void
    /// not a function", which is the error the first version produced.
    pub fn withFont(
        self: *Context,
        face: Font,
        comptime body: anytype,
        args: anytype,
    ) void {
        const handle = self.fontHandle(face);
        if (handle < 0) {
            @call(.always_inline, body, args);
            return;
        }
        _ = cimgui.ember_ui_push_font(handle);
        @call(.always_inline, body, args);
        cimgui.ember_ui_pop_font();
    }

    pub const Font = enum { ui, ui_medium, ui_semibold, mono, mono_medium, fallback };

    pub fn fontHandle(self: *const Context, face: Font) c_int {
        return switch (face) {
            .ui => self.font_ui,
            .ui_medium => self.font_ui_medium,
            .ui_semibold => self.font_ui_semibold,
            .mono => self.font_mono,
            .mono_medium => self.font_mono_medium,
            .fallback => -1,
        };
    }

    // ── The frame ────────────────────────────────────────────────────────

    /// Feeds the window's input to ImGui and opens the frame.
    pub fn newFrame(self: *Context, delta_time: f32) void {
        const input = &self.window.input;
        const mouse = &input.mouse;

        cimgui.ember_ui_set_display_size(
            @floatFromInt(self.window.fb_width),
            @floatFromInt(self.window.fb_height),
        );
        cimgui.ember_ui_set_focus(if (mouse.focused) 1 else 0);
        cimgui.ember_ui_set_mouse_pos(mouse.x, mouse.y);
        cimgui.ember_ui_set_mouse_wheel(mouse.wheel_x, mouse.wheel_y);

        // Only the buttons whose state changed, and only if any did. Sending an
        // unchanged mouse button every frame is harmless but it is the kind of
        // noise that makes a frame's worth of input calls unreadable when
        // something IS wrong with them.
        for (0..8) |i| {
            if (mouse.buttons[i] != self.prev_mouse[i]) {
                cimgui.ember_ui_set_mouse_button(@intCast(i), if (mouse.buttons[i]) 1 else 0);
                self.prev_mouse[i] = mouse.buttons[i];
            }
        }

        self.submitKeys();
        self.submitModifiers();
        if (input.text.len > 0) {
            cimgui.ember_ui_set_input_chars(@ptrCast(input.text.slice().ptr));
        }

        cimgui.ember_ui_new_frame(delta_time);

        self.stats.frame += 1;
        self.stats.want_mouse = cimgui.ember_ui_want_mouse() != 0;
        self.stats.want_keyboard = cimgui.ember_ui_want_keyboard() != 0;
        self.stats.want_text_input = cimgui.ember_ui_want_text_input() != 0;
    }

    fn submitKeys(self: *Context) void {
        // Every key the window knows about, mapped through `ui/keys.zig` and
        // submitted only on a change. The loop is 352 iterations of an integer
        // compare: cheaper than the per-widget bookkeeping it replaces, and it
        // cannot miss a key, because "which keys does the UI care about" is not
        // a question this loop has to answer.
        for (0..352) |i| {
            const down = i < self.window.input.keys.len and self.window.input.keys[i] != 0;
            if (down == self.prev_keys[i]) continue;
            self.prev_keys[i] = down;
            const mapped = keys.fromGlfw(@intCast(i));
            if (mapped == .None) continue;
            cimgui.ember_ui_set_key(@intFromEnum(mapped), if (down) 1 else 0);
        }
    }

    fn submitModifiers(self: *Context) void {
        // The modifiers are SUBMITTED AS KEYS, not as a separate field: ImGui
        // resolves a chord (Ctrl+S) from the same key events as everything
        // else, and a "current modifiers" shortcut would need a second,
        // subtly different notion of what is held down.
        const m = &self.window.input.mouse;
        setMod(cimgui.Mod.Ctrl, m.ctrl);
        setMod(cimgui.Mod.Shift, m.shift);
        setMod(cimgui.Mod.Alt, m.alt);
        setMod(cimgui.Mod.Super, m.super);
    }

    fn setMod(mod: cimgui.Mod, down: bool) void {
        cimgui.ember_ui_set_key(@intFromEnum(mod), if (down) 1 else 0);
    }

    /// Closes the frame and draws it into a pass the renderer opened.
    ///
    /// `pass` is the `WGPURenderPassEncoder` the engine's overlay hook hands
    /// out, and it is valid ONLY for this call: the backend ends the pass and
    /// submits it as soon as this returns. Holding one across a frame is the
    /// use-after-free that WebGPU's error messages describe worst.
    pub fn render(self: *Context, pass: ?*anyopaque) void {
        _ = self;
        cimgui.ember_ui_render();
        cimgui.ember_ui_render_draw_data(pass);
    }

    /// The draw commands the last frame queued. For the frame budget report.
    pub fn drawCommands(self: *const Context) usize {
        _ = self; // the draw list is a global, not per-context state
        const dl = cimgui.ember_ui_get_window_draw_list();
        if (dl == null) return 0;
        const n = cimgui.ember_draw_cmd_count(dl);
        return if (n < 0) 0 else @intCast(n);
    }

    // ── Input gating ─────────────────────────────────────────────────────

    /// True when the UI is using the mouse, so the GAME should not be.
    ///
    /// This is the one function that keeps a click in a panel from also being
    /// a click in the viewport. Every engine input path asks it, which is why
    /// it lives on the context and not on a widget: the gate has to be in one
    /// place or the second place will be the one that forgets.
    pub fn wantsMouse(self: *const Context) bool {
        return self.stats.want_mouse;
    }

    pub fn wantsKeyboard(self: *const Context) bool {
        return self.stats.want_keyboard;
    }

    /// A shortcut fires only when the UI is not typing. Ctrl+S must not save
    /// the editor while the user is typing "s" into a name field.
    pub fn shortcutAllowed(self: *const Context) bool {
        return !self.stats.want_text_input;
    }

    // ── Theme ────────────────────────────────────────────────────────────

    /// Re-applies the theme. Called by the demo's accent picker; in the editor
    /// it is what a future "change theme" menu item calls, which is why it is
    /// a method and not a one-off in `init`.
    pub fn applyTheme(self: *Context) void {
        self.theme.apply();
    }

    pub fn now(self: *const Context) f64 {
        _ = self;
        return cimgui.ember_ui_time();
    }
};

test "ui context: the input gate is off before the first frame" {
    // A context that has never drawn reports nothing wanted, so the game gets
    // its mouse. The alternative — initialise to "true" — makes the first
    // frame of a window that starts with a modal open eat the click.
    const testing = std.testing;
    const ctx: Context = .{
        .allocator = testing.allocator,
        .window = undefined,
        // An empty store, owned by `ctx` and deinitialized with it: giving the
        // literal its own `defer store.deinit()` would free the same map twice.
        .store = .{ .allocator = testing.allocator },
        .theme = .{},
    };
    try testing.expect(!ctx.wantsMouse());
    try testing.expect(ctx.shortcutAllowed());
}
