//! Minimal hand-written GLFW 3.4 bindings.
//!
//! Explicit extern declarations instead of translate-c: faster builds, full
//! control over what we use and zero macro surprises. If more of GLFW is
//! needed, declare it here.

pub const GLFWwindow = opaque {};
pub const GLFWmonitor = opaque {};
pub const GLFWvidmode = opaque {};

// Callbacks
pub const KeyCallback = *const fn (?*GLFWwindow, c_int, c_int, c_int, c_int) callconv(.c) void;
pub const FramebufferSizeCallback = *const fn (?*GLFWwindow, c_int, c_int) callconv(.c) void;

// Constants (glfw3.h)
pub const TRUE: c_int = 1;
pub const FALSE: c_int = 0;

pub const PRESS: c_int = 1;
pub const RELEASE: c_int = 0;
pub const REPEAT: c_int = 2;

pub const CLIENT_API: c_int = 0x00022001;
pub const NO_API: c_int = 0;
pub const RESIZABLE: c_int = 0x00022003;
pub const VISIBLE: c_int = 0x00022004;
pub const MAXIMIZED: c_int = 0x00022008;

pub const PLATFORM_X11: c_int = 0x00060004;
pub const PLATFORM_WAYLAND: c_int = 0x00060003;

// Keys we use (core range 32..348)
pub const KEY_SPACE: c_int = 32;
pub const KEY_ESCAPE: c_int = 256;
pub const KEY_RIGHT: c_int = 262;
pub const KEY_LEFT: c_int = 263;
pub const KEY_DOWN: c_int = 264;
pub const KEY_UP: c_int = 265;

pub extern fn glfwInit() c_int;
pub extern fn glfwTerminate() void;
pub extern fn glfwWindowHint(hint: c_int, value: c_int) void;
pub extern fn glfwCreateWindow(width: c_int, height: c_int, title: [*:0]const u8, monitor: ?*GLFWmonitor, share: ?*GLFWwindow) ?*GLFWwindow;
pub extern fn glfwDestroyWindow(window: *GLFWwindow) void;
pub extern fn glfwWindowShouldClose(window: *GLFWwindow) c_int;
pub extern fn glfwSetWindowShouldClose(window: *GLFWwindow, value: c_int) void;
pub extern fn glfwPollEvents() void;
pub extern fn glfwGetFramebufferSize(window: *GLFWwindow, width: *c_int, height: *c_int) void;
pub extern fn glfwGetKey(window: *GLFWwindow, key: c_int) c_int;
pub extern fn glfwSetKeyCallback(window: *GLFWwindow, cb: ?KeyCallback) ?KeyCallback;
pub extern fn glfwSetFramebufferSizeCallback(window: *GLFWwindow, cb: ?FramebufferSizeCallback) ?FramebufferSizeCallback;
pub extern fn glfwGetPlatform() c_int;

// Native access (for creating the WebGPU surface; X11 only in M0)
pub extern fn glfwGetX11Display() ?*anyopaque;
pub extern fn glfwGetX11Window(window: *GLFWwindow) u32;
