# Platform Layer — Window

**Source:** `src/engine/platform/platform.zig`

The platform layer owns the OS window and the raw input state. It is the only part of the engine that talks to GLFW, and it exposes a minimal contract to the rest of the engine:

- `poll()` once per frame — events fill `Input` (no allocations).
- `nativeHandle()` exposes the minimum needed to create a WebGPU surface.
- Nothing from this layer leaks into gameplay: only `Input` and sizes.

## Initialization

GLFW must be initialized before any window is created:

```zig
pub fn init() !void {
    if (glfw.glfwInit() == 0) return error.GlfwInitFailed;
}

pub fn deinit() void {
    glfw.glfwTerminate();
}
```

## Window creation

```zig
pub const WindowDesc = struct {
    width: u32 = 1280,
    height: u32 = 720,
    title: [:0]const u8 = "ember",
    resizable: bool = true,
};
```

`Window.create` sets `CLIENT_API` to `NO_API` (the engine renders via WebGPU, not OpenGL), applies the resizable hint, creates the GLFW window, reads the framebuffer size, and installs the key and framebuffer-size callbacks:

```zig
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
```

## Window handle

```zig
pub const Window = struct {
    handle: *glfw.GLFWwindow,
    input: Input = .{},
    fb_width: u32 = 0,
    fb_height: u32 = 0,
    resized: bool = false,
    // ...
};
```

Key methods:

| Method | Description |
|---|---|
| `shouldClose() bool` | True when the user pressed Escape or clicked the close button. |
| `poll() void` | Calls `glfwPollEvents()` — dispatches key and resize callbacks. |
| `framebufferSize() {w, h}` | Current framebuffer dimensions in pixels. |
| `nativeHandle() NativeHandle` | Platform handles for WebGPU surface creation. |
| `destroy() void` | Destroys the GLFW window. |

## Native handles

The `NativeHandle` union carries the platform-specific window identifiers Dawn needs to create a WebGPU surface:

```zig
pub const NativeHandle = union(enum) {
    x11: struct { display: *anyopaque, window: u32 },
    wayland: struct { display: *anyopaque, surface: *anyopaque },
};
```

`nativeHandle()` queries GLFW for the current platform and returns the appropriate variant. M0 builds GLFW with X11 only; the Wayland branch is reserved for future platform support:

```zig
pub fn nativeHandle(self: *const Window) NativeHandle {
    return switch (glfw.glfwGetPlatform()) {
        glfw.PLATFORM_X11 => .{ .x11 = .{
            .display = glfw.glfwGetX11Display().?,
            .window = glfw.glfwGetX11Window(self.handle),
        } },
        else => @panic("only the X11 platform is supported in M0"),
    };
}
```

## Callbacks

### Key callback

The key callback recovers the `Window` from the GLFW user pointer and forwards the event to `Input.handleKey`. Pressing Escape sets the window-should-close flag:

```zig
fn keyCallback(win: ?*glfw.GLFWwindow, key: c_int, scancode: c_int, action: c_int, mods: c_int) callconv(.c) void {
    _ = scancode;
    _ = mods;
    const self: *Window = @ptrCast(@alignCast(userPointer(win).?));
    self.input.handleKey(key, action);
    if (key == glfw.KEY_ESCAPE and action == glfw.PRESS) {
        glfw.glfwSetWindowShouldClose(self.handle, glfw.TRUE);
    }
}
```

### Framebuffer size callback

Updates the stored framebuffer dimensions (clamped to a minimum of 1) and sets the `resized` flag:

```zig
fn fbSizeCallback(win: ?*glfw.GLFWwindow, w: c_int, h: c_int) callconv(.c) void {
    const self: *Window = @ptrCast(@alignCast(userPointer(win).?));
    self.fb_width = @intCast(@max(1, w));
    self.fb_height = @intCast(@max(1, h));
    self.resized = true;
}
```

## User pointer bridge

Two extern functions bridge the GLFW C callback to the Zig `Window` struct:

```zig
extern fn glfwSetWindowUserPointer(window: *glfw.GLFWwindow, ptr: ?*anyopaque) void;
extern fn glfwGetWindowUserPointer(window: *glfw.GLFWwindow) ?*anyopaque;
```

The pointer is set during `create()` and retrieved in the callbacks to recover the `Window` instance.

## Frame loop integration

A typical frame loop uses the platform layer like this:

```zig
var window = try platform.Window.create(.{ .title = "my game", .width = 1280, .height = 720 });
defer window.destroy();

while (!window.shouldClose()) {
    window.poll();
    // ... game logic, rendering ...
    window.input.endFrame();  // clear per-frame edge state
}
```
