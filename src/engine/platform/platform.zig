//! Platform layer: window + input (M0: Linux/X11 through GLFW 3.4).
//!
//! Contract with the rest of the engine:
//! - `poll()` once per frame; events fill `Input` (no allocations).
//! - `nativeHandle()` exposes the minimum needed to create a WebGPU surface.
//! - Nothing from this layer leaks into gameplay: only `Input` and sizes.

const std = @import("std");
/// The raw GLFW ABI: keycodes, mouse buttons, modifiers.
///
/// PUBIC because /ui needs the keycodes to map them to ImGui keys, and two
/// copies of "32 is space" is one copy too many. It is the only thing in this
/// module that re-exports another module's surface unchanged.
pub const glfw = @import("glfw_bindings.zig");

pub const log = @import("core").log.scoped("platform");


pub const WindowDesc = struct {
    width: u32 = 1280,
    height: u32 = 720,
    title: [:0]const u8 = "ember",
    resizable: bool = true,
};

/// Native handles to create a WebGPU surface (Dawn).
pub const NativeHandle = union(enum) {
    x11: struct { display: *anyopaque, window: u32 },
    wayland: struct { display: *anyopaque, surface: *anyopaque },
};

/// The mouse, in a form that does not leak GLFW.
///
/// Split from `Input` because the two have different owners: `Input` is the
/// GAME's (actions, edges, no allocations) and this is the WINDOW's (a cursor
/// position is not a game concept). The editor's UI reads this one; the game
/// never sees it.
pub const Mouse = struct {
    /// Framebuffer pixels, origin top-left, which is what every ImGui
    /// coordinate in this engine is.
    x: f32 = 0,
    y: f32 = 0,
    /// Movement since the last frame. Kept because a drag needs the delta and
    /// recomputing it from positions is wrong as soon as a frame is dropped.
    dx: f32 = 0,
    dy: f32 = 0,
    /// Per-button state, indexed by GLFW's zero-based button number.
    buttons: [8]bool = [_]bool{false} ** 8,
    /// Per-button "went down this frame", same indexing.
    pressed: [8]bool = [_]bool{false} ** 8,
    /// Wheel clicks since the last frame. X is horizontal (trackpad swipe).
    wheel_x: f32 = 0,
    wheel_y: f32 = 0,
    /// True while the cursor is inside the window. A drag that leaves the
    /// window and comes back is common, and without this the button is stuck
    /// down for the whole excursion.
    inside: bool = false,
    /// False when the window does not have keyboard focus. ImGui needs this
    /// because an unfocused window still receives key REPEATS, and a text field
    /// would fill itself with whatever was held down when focus was lost.
    focused: bool = true,
    shift: bool = false,
    ctrl: bool = false,
    alt: bool = false,
    super: bool = false,

    pub fn down(self: *const Mouse, button: usize) bool {
        return if (button < self.buttons.len) self.buttons[button] else false;
    }

    pub fn justPressed(self: *const Mouse, button: usize) bool {
        return if (button < self.pressed.len) self.pressed[button] else false;
    }

    /// One frame of the modifiers, as the four bits GLFW reports.
    pub fn mods(self: *const Mouse) u32 {
        var m: u32 = 0;
        if (self.shift) m |= glfw.MOD_SHIFT;
        if (self.ctrl) m |= glfw.MOD_CONTROL;
        if (self.alt) m |= glfw.MOD_ALT;
        if (self.super) m |= glfw.MOD_SUPER;
        return m;
    }
};

/// UTF-8 text typed this frame, accumulated from GLFW's codepoint callback.
///
/// A fixed capacity on purpose. It is drained once per frame by the UI, and a
/// burst of IME input is bounded in practice; when it overflows the excess is
/// DROPPED and the count below says so, which turns "some characters silently
/// vanish while pasting Japanese" into a number somebody can look at.
pub const TextInput = struct {
    buf: [4096]u8 = undefined,
    len: usize = 0,
    dropped: u32 = 0,

    pub fn slice(self: *const TextInput) []const u8 {
        return self.buf[0..self.len];
    }

    fn push(self: *TextInput, bytes: []const u8) void {
        if (self.len + bytes.len > self.buf.len) {
            self.dropped += 1;
            return;
        }
        @memcpy(self.buf[self.len..][0..bytes.len], bytes);
        self.len += bytes.len;
    }

    fn appendCodepoint(self: *TextInput, cp: u32) void {
        // Surrogates and out-of-range values are dropped rather than encoded:
        // a lone surrogate is not a character, and `utf8Encode` would refuse it
        // anyway — the cast is here so the refusal is a `catch` on a range we
        // can name, not a panic on a value that came from the window system.
        if (cp > 0x10FFFF or (cp >= 0xD800 and cp <= 0xDFFF)) return;
        var tmp: [4]u8 = undefined;
        const n = std.unicode.utf8Encode(@intCast(cp), &tmp) catch return;
        self.push(tmp[0..n]);
    }

    fn clear(self: *TextInput) void {
        self.len = 0;
        self.dropped = 0;
    }
};

pub const Input = struct {
    /// GLFW_KEY_LAST = 348 -> 352 for safety.
    keys: [352]u8 = [_]u8{0} ** 352,
    presses: [352]u8 = [_]u8{0} ** 352,
    /// The mouse and the typed text. See `Mouse` for why they are not folded
    /// into the two arrays above.
    mouse: Mouse = .{},
    text: TextInput = .{},

    const max_key: usize = 352;

    fn handleKey(self: *Input, key: c_int, action: c_int) void {
        if (key < 0 or @as(usize, @intCast(key)) >= max_key) return;
        const k: usize = @intCast(key);
        if (action == glfw.PRESS) {
            self.keys[k] = 1;
            self.presses[k] = 1;
        } else if (action == glfw.RELEASE) {
            self.keys[k] = 0;
        }
        // REPEAT: key stays down, pressed does not re-fire.
    }

    pub fn down(self: *const Input, key: c_int) bool {
        if (key < 0 or @as(usize, @intCast(key)) >= max_key) return false;
        return self.keys[@intCast(key)] != 0;
    }

    /// True only in the frame where it was pressed (edge, no repeat).
    pub fn pressed(self: *const Input, key: c_int) bool {
        if (key < 0 or @as(usize, @intCast(key)) >= max_key) return false;
        return self.presses[@intCast(key)] != 0;
    }

    pub fn shift(self: *const Input) bool {
        return self.mouse.shift;
    }
    pub fn ctrl(self: *const Input) bool {
        return self.mouse.ctrl;
    }
    pub fn alt(self: *const Input) bool {
        return self.mouse.alt;
    }

    /// Call ONCE at the end of the frame.
    pub fn endFrame(self: *Input) void {
        @memset(&self.presses, 0);
        self.mouse.pressed = [_]bool{false} ** 8;
        self.mouse.wheel_x = 0;
        self.mouse.wheel_y = 0;
        self.text.clear();
    }
};

pub const Window = struct {
    handle: *glfw.GLFWwindow,
    input: Input = .{},
    fb_width: u32 = 0,
    fb_height: u32 = 0,
    resized: bool = false,

    pub fn create(desc: WindowDesc) !Window {
        glfw.glfwWindowHint(glfw.CLIENT_API, glfw.NO_API);
        glfw.glfwWindowHint(glfw.RESIZABLE, if (desc.resizable) glfw.TRUE else glfw.FALSE);
        const handle = glfw.glfwCreateWindow(
            @intCast(desc.width),
            @intCast(desc.height),
            desc.title.ptr,
            null,
            null,
        ) orelse return error.WindowCreationFailed;

        var self = Window{ .handle = handle };
        var w: c_int = 0;
        var h: c_int = 0;
        glfw.glfwGetFramebufferSize(handle, &w, &h);
        self.fb_width = @intCast(w);
        self.fb_height = @intCast(h);

        _ = glfw.glfwSetKeyCallback(handle, keyCallback);
        _ = glfw.glfwSetFramebufferSizeCallback(handle, fbSizeCallback);
        // The M5 set: everything the editor's UI needs that the game does not.
        // Installed here rather than by the UI layer on purpose — a second
        // owner calling `glfwSetCursorPosCallback` would silently REPLACE this
        // one, and the failure would be "the mouse stopped tracking" rather than
        // anything that names the cause.
        _ = glfw.glfwSetCursorPosCallback(handle, cursorPosCallback);
        _ = glfw.glfwSetMouseButtonCallback(handle, mouseButtonCallback);
        _ = glfw.glfwSetScrollCallback(handle, scrollCallback);
        _ = glfw.glfwSetCharCallback(handle, charCallback);
        _ = glfw.glfwSetCursorEnterCallback(handle, cursorEnterCallback);
        _ = glfw.glfwSetWindowFocusCallback(handle, focusCallback);
        return self;
    }

    pub fn destroy(self: *Window) void {
        glfw.glfwDestroyWindow(self.handle);
    }

    pub fn shouldClose(self: *const Window) bool {
        return glfw.glfwWindowShouldClose(self.handle) != 0;
    }

    pub fn poll(self: *Window) void {
        glfw.glfwPollEvents();
        self.syncMods();
    }

    pub fn framebufferSize(self: *const Window) struct { w: u32, h: u32 } {
        return .{ .w = self.fb_width, .h = self.fb_height };
    }

    pub fn nativeHandle(self: *const Window) NativeHandle {
        // M0 builds GLFW with X11 only (see build.zig); the Wayland branch
        // lands when the platform layer gains it (see ROADMAP).
        return switch (glfw.glfwGetPlatform()) {
            glfw.PLATFORM_X11 => .{ .x11 = .{
                .display = glfw.glfwGetX11Display().?,
                .window = glfw.glfwGetX11Window(self.handle),
            } },
            else => @panic("only the X11 platform is supported in M0"),
        };
    }

    fn keyCallback(win: ?*glfw.GLFWwindow, key: c_int, scancode: c_int, action: c_int, mods: c_int) callconv(.c) void {
        _ = scancode;
        _ = mods;
        // Recover the Window from the user pointer stored in create().
        const self: *Window = @ptrCast(@alignCast(userPointer(win).?));
        self.input.handleKey(key, action);
        if (key == glfw.KEY_ESCAPE and action == glfw.PRESS) {
            glfw.glfwSetWindowShouldClose(self.handle, glfw.TRUE);
        }
    }

    fn fbSizeCallback(win: ?*glfw.GLFWwindow, w: c_int, h: c_int) callconv(.c) void {
        const self: *Window = @ptrCast(@alignCast(userPointer(win).?));
        self.fb_width = @intCast(@max(1, w));
        self.fb_height = @intCast(@max(1, h));
        self.resized = true;
    }

    // ── M5: the input the editor's UI needs ──────────────────────────────
    //
    // Every one of these recovers the Window from the GLFW user pointer the
    // same way the key callback does, and none of them touches the game-facing
    // `Input` semantics above: the game still sees only `keys`/`presses`, and
    // the editor UI is what reads `mouse` and `text`.

    fn cursorPosCallback(win: ?*glfw.GLFWwindow, x: f64, y: f64) callconv(.c) void {
        const self: *Window = @ptrCast(@alignCast(userPointer(win).?));
        const m = &self.input.mouse;
        const nx: f32 = @floatCast(x);
        const ny: f32 = @floatCast(y);
        m.dx += nx - m.x;
        m.dy += ny - m.y;
        m.x = nx;
        m.y = ny;
    }

    fn mouseButtonCallback(win: ?*glfw.GLFWwindow, button: c_int, action: c_int, mods: c_int) callconv(.c) void {
        if (button < 0 or @as(usize, @intCast(button)) >= 8) return;
        const self: *Window = @ptrCast(@alignCast(userPointer(win).?));
        const b: usize = @intCast(button);
        const down = action == glfw.PRESS;
        self.input.mouse.buttons[b] = down;
        if (down) self.input.mouse.pressed[b] = true;
        updateMods(&self.input.mouse, mods);
    }

    fn scrollCallback(win: ?*glfw.GLFWwindow, xoff: f64, yoff: f64) callconv(.c) void {
        const self: *Window = @ptrCast(@alignCast(userPointer(win).?));
        self.input.mouse.wheel_x += @floatCast(xoff);
        self.input.mouse.wheel_y += @floatCast(yoff);
    }

    fn charCallback(win: ?*glfw.GLFWwindow, codepoint: c_uint) callconv(.c) void {
        const self: *Window = @ptrCast(@alignCast(userPointer(win).?));
        // Control characters are key events wearing a codepoint costume; a text
        // field that received them would fill itself with newlines and DEL.
        if (codepoint < 0x20 or codepoint == 0x7f) return;
        self.input.text.appendCodepoint(codepoint);
    }

    fn cursorEnterCallback(win: ?*glfw.GLFWwindow, entered: c_int) callconv(.c) void {
        const self: *Window = @ptrCast(@alignCast(userPointer(win).?));
        const m = &self.input.mouse;
        m.inside = entered != 0;
        if (!m.inside) {
            // Leaving the window RELEASES every button, which is the only way
            // a drag that ends outside the window ever ends.
            m.buttons = [_]bool{false} ** 8;
        }
    }

    fn focusCallback(win: ?*glfw.GLFWwindow, focused: c_int) callconv(.c) void {
        const self: *Window = @ptrCast(@alignCast(userPointer(win).?));
        const m = &self.input.mouse;
        m.focused = focused != 0;
        if (!m.focused) {
            m.buttons = [_]bool{false} ** 8;
            // Modifiers are the classic stuck-key bug: alt-tab away holding
            // Ctrl, come back, and every menu keeps opening shortcuts.
            m.shift = false;
            m.ctrl = false;
            m.alt = false;
            m.super = false;
        }
    }

    fn updateMods(m: *Mouse, mods: c_int) void {
        m.shift = mods & glfw.MOD_SHIFT != 0;
        m.ctrl = mods & glfw.MOD_CONTROL != 0;
        m.alt = mods & glfw.MOD_ALT != 0;
        m.super = mods & glfw.MOD_SUPER != 0;
    }

    /// Re-reads the modifier keys from the window system. Called once per frame
    /// by `poll`, because a modifier can change between events (holding shift
    /// and pressing another key sends the mods on THAT event, so the last event
    /// of a frame can be older than the last modifier change).
    fn syncMods(self: *Window) void {
        var mods: c_int = 0;
        if (glfw.glfwGetKey(self.handle, glfw.KEY_LEFT_SHIFT) == glfw.PRESS or
            glfw.glfwGetKey(self.handle, glfw.KEY_RIGHT_SHIFT) == glfw.PRESS) mods |= glfw.MOD_SHIFT;
        if (glfw.glfwGetKey(self.handle, glfw.KEY_LEFT_CONTROL) == glfw.PRESS or
            glfw.glfwGetKey(self.handle, glfw.KEY_RIGHT_CONTROL) == glfw.PRESS) mods |= glfw.MOD_CONTROL;
        if (glfw.glfwGetKey(self.handle, glfw.KEY_LEFT_ALT) == glfw.PRESS or
            glfw.glfwGetKey(self.handle, glfw.KEY_RIGHT_ALT) == glfw.PRESS) mods |= glfw.MOD_ALT;
        if (glfw.glfwGetKey(self.handle, glfw.KEY_LEFT_SUPER) == glfw.PRESS or
            glfw.glfwGetKey(self.handle, glfw.KEY_RIGHT_SUPER) == glfw.PRESS) mods |= glfw.MOD_SUPER;
        updateMods(&self.input.mouse, mods);
    }

    /// The clipboard, as a slice valid until the next call. Null when the
    /// window has no clipboard (X11 with no selection owner), which is a normal
    /// answer and not an error: pasting an empty clipboard should clear the
    /// field, not crash.
    pub fn clipboard(self: *Window) ?[]const u8 {
        const s = glfw.glfwGetClipboardString(self.handle) orelse return null;
        return std.mem.span(s);
    }

    pub fn setClipboard(self: *Window, text: [:0]const u8) void {
        glfw.glfwSetClipboardString(self.handle, text.ptr);
    }

    pub fn isFocused(self: *const Window) bool {
        return self.input.mouse.focused;
    }
};

// window user-pointer bridge (minimal extra externs; kept down here to keep
// the declarations next to their only use).
extern fn glfwSetWindowUserPointer(window: *glfw.GLFWwindow, ptr: ?*anyopaque) void;
extern fn glfwGetWindowUserPointer(window: *glfw.GLFWwindow) ?*anyopaque;

pub fn setUserPointer(window: *glfw.GLFWwindow, ptr: ?*anyopaque) void {
    glfwSetWindowUserPointer(window, ptr);
}

fn userPointer(win: ?*glfw.GLFWwindow) ?*anyopaque {
    return glfwGetWindowUserPointer(win.?);
}

pub fn init() !void {
    if (glfw.glfwInit() == 0) return error.GlfwInitFailed;
}

pub fn deinit() void {
    glfw.glfwTerminate();
}

// ── File watcher (Linux inotify) ──────────────────────────────────────
//
// Minimal single-file watcher for hot-reload. Uses inotify directly
// (no extra deps, no thread). Poll once per frame with `poll()`.

const inotify = @import("inotify.zig");

pub const FileWatcher = inotify.FileWatcher;
pub const FileWatchError = inotify.FileWatchError;
/// A directory watch: the asset hot-reload shape. One watch covers every entry
/// in the directory and reports WHICH one changed, which is what the audio
/// bank's `reload` needs (M8).
pub const DirectoryWatcher = inotify.DirectoryWatcher;

/// Creates a watcher for `path`. Returns the watcher; call `poll()` each frame.
pub fn watchFile(allocator: std.mem.Allocator, path: []const u8) !FileWatcher {
    return inotify.watchFile(allocator, path);
}

/// Creates a watcher for a directory of assets. Each frame, `pollNames` fills a
/// caller-owned array with the entries that changed (borrowed slices, valid
/// until the next call).
pub fn watchDirectory(allocator: std.mem.Allocator, path: []const u8) !DirectoryWatcher {
    return inotify.watchDirectory(allocator, path);
}

/// True when a changed entry is a sound file the audio backend can decode.
/// Shared so the editor, the runtime and the asset importer agree on the list.
pub fn isAudioAsset(name: []const u8) bool {
    return inotify.isAudioAsset(name);
}

/// True when a changed entry is an image the asset importer recognises. Shared
/// for the same reason as `isAudioAsset`: the runtime's image watcher, the
/// editor's asset browser and the importer must not each carry their own list.
pub fn isImageAsset(name: []const u8) bool {
    return inotify.isImageAsset(name);
}
