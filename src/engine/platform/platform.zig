//! Platform layer: window + input (M0: Linux/X11 through GLFW 3.4).
//!
//! Contract with the rest of the engine:
//! - `poll()` once per frame; events fill `Input` (no allocations).
//! - `nativeHandle()` exposes the minimum needed to create a WebGPU surface.
//! - Nothing from this layer leaks into gameplay: only `Input` and sizes.

const std = @import("std");
const glfw = @import("glfw_bindings.zig");

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

pub const Input = struct {
    /// GLFW_KEY_LAST = 348 -> 352 for safety.
    keys: [352]u8 = [_]u8{0} ** 352,
    presses: [352]u8 = [_]u8{0} ** 352,

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

    /// Call ONCE at the end of the frame.
    pub fn endFrame(self: *Input) void {
        @memset(&self.presses, 0);
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
        return self;
    }

    pub fn destroy(self: *Window) void {
        glfw.glfwDestroyWindow(self.handle);
    }

    pub fn shouldClose(self: *const Window) bool {
        return glfw.glfwWindowShouldClose(self.handle) != 0;
    }

    pub fn poll(self: *Window) void {
        _ = self;
        glfw.glfwPollEvents();
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
