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
/// `(window, x, y)` in SCREEN coordinates (may be negative off-screen).
pub const CursorPosCallback = *const fn (?*GLFWwindow, f64, f64) callconv(.c) void;
/// `(window, button, action, mods)` — `button` is 0-based, which is the
/// convention ImGui's `ImGuiMouseButton` also uses, so it needs no remap.
pub const MouseButtonCallback = *const fn (?*GLFWwindow, c_int, c_int, c_int) callconv(.c) void;
/// `(window, xoff, yoff)` — scroll deltas, already in wheel clicks.
pub const ScrollCallback = *const fn (?*GLFWwindow, f64, f64) callconv(.c) void;
/// `(window, codepoint)` — ONE Unicode codepoint, not UTF-8. This is the
/// callback that makes typing an accented character, an emoji or any CJK text
/// work at all; a text input that only reads keys cannot produce them.
pub const CharCallback = *const fn (?*GLFWwindow, c_uint) callconv(.c) void;
/// `(window, entered)` — 1 on entering the window.
pub const CursorEnterCallback = *const fn (?*GLFWwindow, c_int) callconv(.c) void;
/// `(window, focused)` — 1 when the window gained focus.
pub const FocusCallback = *const fn (?*GLFWwindow, c_int) callconv(.c) void;
pub const ClipboardCallback = *const fn (?*GLFWwindow, c_int) callconv(.c) void;

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

// ── Keys ─────────────────────────────────────────────────────────────────
//
// The whole printable range plus the editing/navigation block, taken from
// glfw3.h. M5 needs all of them: the editor's text input is a text field, and
// a text field that cannot receive Home/End/PageUp or a dead key is not a text
// field. The values are the ABI (they are what the window system sends), so
// they are written out rather than computed.
//
// The mapping from these numbers to Dear ImGui's `ImGuiKey_*` lives in
// `ui/keys.zig`, NOT here: GLFW numbers are a windowing fact, ImGui keys are a
// UI fact, and the translation is allowed to change when either does.
pub const KEY_UNKNOWN: c_int = -1;
pub const KEY_SPACE: c_int = 32;
pub const KEY_APOSTROPHE: c_int = 39;
pub const KEY_COMMA: c_int = 44;
pub const KEY_MINUS: c_int = 45;
pub const KEY_PERIOD: c_int = 46;
pub const KEY_SLASH: c_int = 47;
pub const KEY_0: c_int = 48;
pub const KEY_1: c_int = 49;
pub const KEY_2: c_int = 50;
pub const KEY_3: c_int = 51;
pub const KEY_4: c_int = 52;
pub const KEY_5: c_int = 53;
pub const KEY_6: c_int = 54;
pub const KEY_7: c_int = 55;
pub const KEY_8: c_int = 56;
pub const KEY_9: c_int = 57;
pub const KEY_SEMICOLON: c_int = 59;
pub const KEY_EQUAL: c_int = 61;
pub const KEY_A: c_int = 65;
pub const KEY_B: c_int = 66;
pub const KEY_C: c_int = 67;
pub const KEY_D: c_int = 68;
pub const KEY_E: c_int = 69;
pub const KEY_F: c_int = 70;
pub const KEY_G: c_int = 71;
pub const KEY_H: c_int = 72;
pub const KEY_I: c_int = 73;
pub const KEY_J: c_int = 74;
pub const KEY_K: c_int = 75;
pub const KEY_L: c_int = 76;
pub const KEY_M: c_int = 77;
pub const KEY_N: c_int = 78;
pub const KEY_O: c_int = 79;
pub const KEY_P: c_int = 80;
pub const KEY_Q: c_int = 81;
pub const KEY_R: c_int = 82;
pub const KEY_S: c_int = 83;
pub const KEY_T: c_int = 84;
pub const KEY_U: c_int = 85;
pub const KEY_V: c_int = 86;
pub const KEY_W: c_int = 87;
pub const KEY_X: c_int = 88;
pub const KEY_Y: c_int = 89;
pub const KEY_Z: c_int = 90;
pub const KEY_LEFT_BRACKET: c_int = 91;
pub const KEY_BACKSLASH: c_int = 92;
pub const KEY_RIGHT_BRACKET: c_int = 93;
pub const KEY_GRAVE_ACCENT: c_int = 96;
pub const KEY_WORLD_1: c_int = 161;
pub const KEY_WORLD_2: c_int = 162;
pub const KEY_ESCAPE: c_int = 256;
pub const KEY_ENTER: c_int = 257;
pub const KEY_TAB: c_int = 258;
pub const KEY_BACKSPACE: c_int = 259;
pub const KEY_INSERT: c_int = 260;
pub const KEY_DELETE: c_int = 261;
pub const KEY_RIGHT: c_int = 262;
pub const KEY_LEFT: c_int = 263;
pub const KEY_DOWN: c_int = 264;
pub const KEY_UP: c_int = 265;
pub const KEY_PAGE_UP: c_int = 266;
pub const KEY_PAGE_DOWN: c_int = 267;
pub const KEY_HOME: c_int = 268;
pub const KEY_END: c_int = 269;
pub const KEY_CAPS_LOCK: c_int = 280;
pub const KEY_SCROLL_LOCK: c_int = 281;
pub const KEY_NUM_LOCK: c_int = 282;
pub const KEY_PRINT_SCREEN: c_int = 283;
pub const KEY_PAUSE: c_int = 284;
pub const KEY_F1: c_int = 290;
pub const KEY_F2: c_int = 291;
pub const KEY_F3: c_int = 292;
pub const KEY_F4: c_int = 293;
pub const KEY_F5: c_int = 294;
pub const KEY_F6: c_int = 295;
pub const KEY_F7: c_int = 296;
pub const KEY_F8: c_int = 297;
pub const KEY_F9: c_int = 298;
pub const KEY_F10: c_int = 299;
pub const KEY_F11: c_int = 300;
pub const KEY_F12: c_int = 301;
pub const KEY_F13: c_int = 302;
pub const KEY_F14: c_int = 303;
pub const KEY_F15: c_int = 304;
pub const KEY_F16: c_int = 305;
pub const KEY_F17: c_int = 306;
pub const KEY_F18: c_int = 307;
pub const KEY_F19: c_int = 308;
pub const KEY_F20: c_int = 309;
pub const KEY_F21: c_int = 310;
pub const KEY_F22: c_int = 311;
pub const KEY_F23: c_int = 312;
pub const KEY_F24: c_int = 313;
pub const KEY_KP_0: c_int = 320;
pub const KEY_KP_1: c_int = 321;
pub const KEY_KP_2: c_int = 322;
pub const KEY_KP_3: c_int = 323;
pub const KEY_KP_4: c_int = 324;
pub const KEY_KP_5: c_int = 325;
pub const KEY_KP_6: c_int = 326;
pub const KEY_KP_7: c_int = 327;
pub const KEY_KP_8: c_int = 328;
pub const KEY_KP_9: c_int = 329;
pub const KEY_KP_DECIMAL: c_int = 330;
pub const KEY_KP_DIVIDE: c_int = 331;
pub const KEY_KP_MULTIPLY: c_int = 332;
pub const KEY_KP_SUBTRACT: c_int = 333;
pub const KEY_KP_ADD: c_int = 334;
pub const KEY_KP_ENTER: c_int = 335;
pub const KEY_KP_EQUAL: c_int = 336;
pub const KEY_LEFT_SHIFT: c_int = 340;
pub const KEY_LEFT_CONTROL: c_int = 341;
pub const KEY_LEFT_ALT: c_int = 342;
pub const KEY_LEFT_SUPER: c_int = 343;
pub const KEY_RIGHT_SHIFT: c_int = 344;
pub const KEY_RIGHT_CONTROL: c_int = 345;
pub const KEY_RIGHT_ALT: c_int = 346;
pub const KEY_RIGHT_SUPER: c_int = 347;
pub const KEY_MENU: c_int = 348;
pub const KEY_LAST: c_int = 348;

// ── Mouse ────────────────────────────────────────────────────────────────
// Zero-based, and the same numbering ImGui uses for `ImGuiMouseButton_Left`,
// so no translation is needed anywhere in the UI layer.
pub const MOUSE_1: c_int = 0;
pub const MOUSE_2: c_int = 1;
pub const MOUSE_3: c_int = 2;
pub const MOUSE_4: c_int = 3;
pub const MOUSE_5: c_int = 4;
pub const MOUSE_6: c_int = 5;
pub const MOUSE_7: c_int = 6;
pub const MOUSE_8: c_int = 7;
pub const MOUSE_LAST: c_int = 7;

pub const MOD_SHIFT: c_int = 0x0001;
pub const MOD_CONTROL: c_int = 0x0002;
pub const MOD_ALT: c_int = 0x0004;
pub const MOD_SUPER: c_int = 0x0008;

pub const CURSOR: c_int = 0x00033001;
pub const FOCUS_ON_SHOW: c_int = 0x00020004;

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
pub extern fn glfwSetCursorPosCallback(window: *GLFWwindow, cb: ?CursorPosCallback) ?CursorPosCallback;
pub extern fn glfwSetMouseButtonCallback(window: *GLFWwindow, cb: ?MouseButtonCallback) ?MouseButtonCallback;
pub extern fn glfwSetScrollCallback(window: *GLFWwindow, cb: ?ScrollCallback) ?ScrollCallback;
pub extern fn glfwSetCharCallback(window: *GLFWwindow, cb: ?CharCallback) ?CharCallback;
pub extern fn glfwSetCursorEnterCallback(window: *GLFWwindow, cb: ?CursorEnterCallback) ?CursorEnterCallback;
/// Named `glfwSetWindowFocusCallback` since GLFW 3.3 — `glfwSetFocusCallback`
/// never existed. The old name is the one every tutorial uses, which is why
/// this note is here rather than in a changelog nobody opens.
pub extern fn glfwSetWindowFocusCallback(window: *GLFWwindow, cb: ?FocusCallback) ?FocusCallback;
pub extern fn glfwGetCursorPos(window: *GLFWwindow, x: *f64, y: *f64) void;
pub extern fn glfwSetCursorPos(window: *GLFWwindow, x: f64, y: f64) void;
pub extern fn glfwGetMouseButton(window: *GLFWwindow, button: c_int) c_int;
pub extern fn glfwGetWindowAttrib(window: *GLFWwindow, attrib: c_int) c_int;
pub extern fn glfwSetClipboardString(window: *GLFWwindow, text: [*:0]const u8) void;
pub extern fn glfwGetClipboardString(window: *GLFWwindow) ?[*:0]const u8;
pub extern fn glfwGetPlatform() c_int;

// Native access (for creating the WebGPU surface; X11 only in M0)
pub extern fn glfwGetX11Display() ?*anyopaque;
pub extern fn glfwGetX11Window(window: *GLFWwindow) u32;
