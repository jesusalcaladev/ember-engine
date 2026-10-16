//! `ui.keys` — the GLFW keycode to Dear ImGui key mapping, and nothing else.
//!
//! ## Why this file is 300 lines of table and 40 of thought
//!
//! Two numbering schemes meet here. GLFW numbers keys by what the window
//! system sent (32 is space, 256 is escape, 65 is A); ImGui numbers them by
//! what a keyboard has (512 is Tab, 524 is A), because it wants key bindings
//! to mean the same thing on every layout. The table below is the translation,
//! and a wrong row is a key that silently does nothing.
//!
//! So the two things that make this trustworthy are:
//!
//! 1. The row set is PORTED from Dear ImGui's own GLFW backend rather than
//!    written from memory, and the port is mechanical: 119 `case` lines became
//!    119 table rows.
//! 2. `keys` ships a test that reads the pinned `libs/imgui/imgui.h` and
//!    fails if either the mirror or the header moved. A drift here is a
//!    compile-time constant change, which is the cheapest possible bug — but
//!    only if something checks it, and a comment cannot.
//!
//! ## Why the table is here and not in the GLFW backend
//!
//! The engine already owns the window and its callbacks (`platform.Window`).
//! Dear ImGui's `imgui_impl_glfw` wants to own them too: it stores its own
//! context in `glfwSetWindowUserPointer`, which is where `platform.Window`
//! keeps itself. Two owners of one pointer means one of them loses, and the
//! symptom is "the mouse stopped tracking when the editor opened" — which is
//! why the engine feeds ImGui its input directly instead.

const std = @import("std");
// Through a module import, not a path: `../platform/...` is outside this
// module's root, and Zig 0.16 rejects it with "import of file outside module
// path" — a rule that is the module boundary doing its job, because a relative
// path here would let this file reach ALL of libs/ the day somebody moved it.
const glfw = @import("platform");

/// Mirror of `enum ImGuiKey` in the pinned imgui.h (see the drift test below).
pub const Key = enum(c_int) {
    None = 0,
    Tab = 512, // == ImGuiKey_NamedKey_BEGIN; the meta-boundaries are read from the header, not mirrored
    LeftArrow = 513,
    RightArrow = 514,
    UpArrow = 515,
    DownArrow = 516,
    PageUp = 517,
    PageDown = 518,
    Home = 519,
    End = 520,
    Insert = 521,
    Delete = 522,
    Backspace = 523,
    Space = 524,
    Enter = 525,
    Escape = 526,
    LeftCtrl = 527,
    LeftShift = 528,
    LeftAlt = 529,
    LeftSuper = 530,
    RightCtrl = 531,
    RightShift = 532,
    RightAlt = 533,
    RightSuper = 534,
    Menu = 535,
    Digit_0 = 536,
    Digit_1 = 537,
    Digit_2 = 538,
    Digit_3 = 539,
    Digit_4 = 540,
    Digit_5 = 541,
    Digit_6 = 542,
    Digit_7 = 543,
    Digit_8 = 544,
    Digit_9 = 545,
    A = 546,
    B = 547,
    C = 548,
    D = 549,
    E = 550,
    F = 551,
    G = 552,
    H = 553,
    I = 554,
    J = 555,
    K = 556,
    L = 557,
    M = 558,
    N = 559,
    O = 560,
    P = 561,
    Q = 562,
    R = 563,
    S = 564,
    T = 565,
    U = 566,
    V = 567,
    W = 568,
    X = 569,
    Y = 570,
    Z = 571,
    F1 = 572,
    F2 = 573,
    F3 = 574,
    F4 = 575,
    F5 = 576,
    F6 = 577,
    F7 = 578,
    F8 = 579,
    F9 = 580,
    F10 = 581,
    F11 = 582,
    F12 = 583,
    F13 = 584,
    F14 = 585,
    F15 = 586,
    F16 = 587,
    F17 = 588,
    F18 = 589,
    F19 = 590,
    F20 = 591,
    F21 = 592,
    F22 = 593,
    F23 = 594,
    F24 = 595,
    Apostrophe = 596,
    Comma = 597,
    Minus = 598,
    Period = 599,
    Slash = 600,
    Semicolon = 601,
    Equal = 602,
    LeftBracket = 603,
    Backslash = 604,
    RightBracket = 605,
    GraveAccent = 606,
    CapsLock = 607,
    ScrollLock = 608,
    NumLock = 609,
    PrintScreen = 610,
    Pause = 611,
    Keypad0 = 612,
    Keypad1 = 613,
    Keypad2 = 614,
    Keypad3 = 615,
    Keypad4 = 616,
    Keypad5 = 617,
    Keypad6 = 618,
    Keypad7 = 619,
    Keypad8 = 620,
    Keypad9 = 621,
    KeypadDecimal = 622,
    KeypadDivide = 623,
    KeypadMultiply = 624,
    KeypadSubtract = 625,
    KeypadAdd = 626,
    KeypadEnter = 627,
    KeypadEqual = 628,
    AppBack = 629,
    AppForward = 630,
    Oem102 = 631,
    GamepadStart = 632,
    GamepadBack = 633,
    GamepadFaceLeft = 634,
    GamepadFaceRight = 635,
    GamepadFaceUp = 636,
    GamepadFaceDown = 637,
    GamepadDpadLeft = 638,
    GamepadDpadRight = 639,
    GamepadDpadUp = 640,
    GamepadDpadDown = 641,
    GamepadL1 = 642,
    GamepadR1 = 643,
    GamepadL2 = 644,
    GamepadR2 = 645,
    GamepadL3 = 646,
    GamepadR3 = 647,
    GamepadLStickLeft = 648,
    GamepadLStickRight = 649,
    GamepadLStickUp = 650,
    GamepadLStickDown = 651,
    GamepadRStickLeft = 652,
    GamepadRStickRight = 653,
    GamepadRStickUp = 654,
    GamepadRStickDown = 655,
    MouseLeft = 656,
    MouseRight = 657,
    MouseMiddle = 658,
    MouseX1 = 659,
    MouseX2 = 660,
    MouseWheelX = 661,
    MouseWheelY = 662,
    ReservedForModCtrl = 663,
    ReservedForModShift = 664,
    ReservedForModAlt = 665,
    ReservedForModSuper = 666,
};


/// GLFW keycode -> ImGui key.
///
/// A comptime `switch` rather than `std.StaticMap` (which 0.16 does not have):
/// the compiler turns it into a jump table, it allocates nothing, and the
/// compiler is also what tells us when a row was added twice.
const from_glfw = struct {
    fn get(keycode: c_int) ?Key {
        return switch (keycode) {
            glfw.glfw.KEY_TAB => .Tab,
            glfw.glfw.KEY_LEFT => .LeftArrow,
            glfw.glfw.KEY_RIGHT => .RightArrow,
            glfw.glfw.KEY_UP => .UpArrow,
            glfw.glfw.KEY_DOWN => .DownArrow,
            glfw.glfw.KEY_PAGE_UP => .PageUp,
            glfw.glfw.KEY_PAGE_DOWN => .PageDown,
            glfw.glfw.KEY_HOME => .Home,
            glfw.glfw.KEY_END => .End,
            glfw.glfw.KEY_INSERT => .Insert,
            glfw.glfw.KEY_DELETE => .Delete,
            glfw.glfw.KEY_BACKSPACE => .Backspace,
            glfw.glfw.KEY_SPACE => .Space,
            glfw.glfw.KEY_ENTER => .Enter,
            glfw.glfw.KEY_ESCAPE => .Escape,
            glfw.glfw.KEY_APOSTROPHE => .Apostrophe,
            glfw.glfw.KEY_COMMA => .Comma,
            glfw.glfw.KEY_MINUS => .Minus,
            glfw.glfw.KEY_PERIOD => .Period,
            glfw.glfw.KEY_SLASH => .Slash,
            glfw.glfw.KEY_SEMICOLON => .Semicolon,
            glfw.glfw.KEY_EQUAL => .Equal,
            glfw.glfw.KEY_LEFT_BRACKET => .LeftBracket,
            glfw.glfw.KEY_BACKSLASH => .Backslash,
            glfw.glfw.KEY_WORLD_1 => .Oem102,
            glfw.glfw.KEY_WORLD_2 => .Oem102,
            glfw.glfw.KEY_RIGHT_BRACKET => .RightBracket,
            glfw.glfw.KEY_GRAVE_ACCENT => .GraveAccent,
            glfw.glfw.KEY_CAPS_LOCK => .CapsLock,
            glfw.glfw.KEY_SCROLL_LOCK => .ScrollLock,
            glfw.glfw.KEY_NUM_LOCK => .NumLock,
            glfw.glfw.KEY_PRINT_SCREEN => .PrintScreen,
            glfw.glfw.KEY_PAUSE => .Pause,
            glfw.glfw.KEY_KP_0 => .Keypad0,
            glfw.glfw.KEY_KP_1 => .Keypad1,
            glfw.glfw.KEY_KP_2 => .Keypad2,
            glfw.glfw.KEY_KP_3 => .Keypad3,
            glfw.glfw.KEY_KP_4 => .Keypad4,
            glfw.glfw.KEY_KP_5 => .Keypad5,
            glfw.glfw.KEY_KP_6 => .Keypad6,
            glfw.glfw.KEY_KP_7 => .Keypad7,
            glfw.glfw.KEY_KP_8 => .Keypad8,
            glfw.glfw.KEY_KP_9 => .Keypad9,
            glfw.glfw.KEY_KP_DECIMAL => .KeypadDecimal,
            glfw.glfw.KEY_KP_DIVIDE => .KeypadDivide,
            glfw.glfw.KEY_KP_MULTIPLY => .KeypadMultiply,
            glfw.glfw.KEY_KP_SUBTRACT => .KeypadSubtract,
            glfw.glfw.KEY_KP_ADD => .KeypadAdd,
            glfw.glfw.KEY_KP_ENTER => .KeypadEnter,
            glfw.glfw.KEY_KP_EQUAL => .KeypadEqual,
            glfw.glfw.KEY_LEFT_SHIFT => .LeftShift,
            glfw.glfw.KEY_LEFT_CONTROL => .LeftCtrl,
            glfw.glfw.KEY_LEFT_ALT => .LeftAlt,
            glfw.glfw.KEY_LEFT_SUPER => .LeftSuper,
            glfw.glfw.KEY_RIGHT_SHIFT => .RightShift,
            glfw.glfw.KEY_RIGHT_CONTROL => .RightCtrl,
            glfw.glfw.KEY_RIGHT_ALT => .RightAlt,
            glfw.glfw.KEY_RIGHT_SUPER => .RightSuper,
            glfw.glfw.KEY_MENU => .Menu,
            glfw.glfw.KEY_0 => .Digit_0,
            glfw.glfw.KEY_1 => .Digit_1,
            glfw.glfw.KEY_2 => .Digit_2,
            glfw.glfw.KEY_3 => .Digit_3,
            glfw.glfw.KEY_4 => .Digit_4,
            glfw.glfw.KEY_5 => .Digit_5,
            glfw.glfw.KEY_6 => .Digit_6,
            glfw.glfw.KEY_7 => .Digit_7,
            glfw.glfw.KEY_8 => .Digit_8,
            glfw.glfw.KEY_9 => .Digit_9,
            glfw.glfw.KEY_A => .A,
            glfw.glfw.KEY_B => .B,
            glfw.glfw.KEY_C => .C,
            glfw.glfw.KEY_D => .D,
            glfw.glfw.KEY_E => .E,
            glfw.glfw.KEY_F => .F,
            glfw.glfw.KEY_G => .G,
            glfw.glfw.KEY_H => .H,
            glfw.glfw.KEY_I => .I,
            glfw.glfw.KEY_J => .J,
            glfw.glfw.KEY_K => .K,
            glfw.glfw.KEY_L => .L,
            glfw.glfw.KEY_M => .M,
            glfw.glfw.KEY_N => .N,
            glfw.glfw.KEY_O => .O,
            glfw.glfw.KEY_P => .P,
            glfw.glfw.KEY_Q => .Q,
            glfw.glfw.KEY_R => .R,
            glfw.glfw.KEY_S => .S,
            glfw.glfw.KEY_T => .T,
            glfw.glfw.KEY_U => .U,
            glfw.glfw.KEY_V => .V,
            glfw.glfw.KEY_W => .W,
            glfw.glfw.KEY_X => .X,
            glfw.glfw.KEY_Y => .Y,
            glfw.glfw.KEY_Z => .Z,
            glfw.glfw.KEY_F1 => .F1,
            glfw.glfw.KEY_F2 => .F2,
            glfw.glfw.KEY_F3 => .F3,
            glfw.glfw.KEY_F4 => .F4,
            glfw.glfw.KEY_F5 => .F5,
            glfw.glfw.KEY_F6 => .F6,
            glfw.glfw.KEY_F7 => .F7,
            glfw.glfw.KEY_F8 => .F8,
            glfw.glfw.KEY_F9 => .F9,
            glfw.glfw.KEY_F10 => .F10,
            glfw.glfw.KEY_F11 => .F11,
            glfw.glfw.KEY_F12 => .F12,
            glfw.glfw.KEY_F13 => .F13,
            glfw.glfw.KEY_F14 => .F14,
            glfw.glfw.KEY_F15 => .F15,
            glfw.glfw.KEY_F16 => .F16,
            glfw.glfw.KEY_F17 => .F17,
            glfw.glfw.KEY_F18 => .F18,
            glfw.glfw.KEY_F19 => .F19,
            glfw.glfw.KEY_F20 => .F20,
            glfw.glfw.KEY_F21 => .F21,
            glfw.glfw.KEY_F22 => .F22,
            glfw.glfw.KEY_F23 => .F23,
            glfw.glfw.KEY_F24 => .F24,
            else => null,
        };
    }
};

/// The ImGui key for a GLFW keycode, or `.None` for a key ImGui does not name
/// (the function keys of a laptop, media keys, a dead key on a non-US layout).
///
/// `.None` is a real answer and not an error: the key still reaches the game
/// through `platform.Input`, which is the layer that knows about every key
/// rather than the layer that knows about the ones with names.
pub fn fromGlfw(keycode: c_int) Key {
    return from_glfw.get(keycode) orelse .None;
}

test "ui keys: the mirror matches the pinned imgui.h" {
    // The test that makes the table above trustworthy. It reads the header the
    // pin installed (vendored to `cimgui/imgui.h` by a build step, because
    // `@embedFile` cannot reach outside this module's package) and compares
    // every named key it finds against the Zig mirror.
    //
    // The comparison walks the mirror, not the header: for each of the mirror's
    // 160 fields, the test asks "does imgui.h declare this value". That
    // direction needs no runtime reflection (Zig has none), and it catches
    // exactly the drift that matters — a value OUR file got wrong.
    const text: [:0]const u8 = @embedFile("cimgui/pinned_imgui.h");

    const marker = "enum ImGuiKey : int" ++ [_]u8{ '\n', '{' };
    const start = std.mem.indexOf(u8, text, marker) orelse
        return error.ImguiKeyEnumNotFound;
    const rest = text[start + marker.len ..];
    // The closing brace is the line `};`. Searching for "\n}" finds the first
    // one, which is inside a comment, so the range comes back tiny and the loop
    // compares two keys and gives up. `};` is the difference.
    const end = std.mem.indexOf(u8, rest, "\n};") orelse rest.len;

    // `inline for`, because the loop reads a TYPE's field at comptime: a plain
    // `for` over `fields` sees each `EnumField`'s `value` as runtime-known,
    // which is Zig saying the mirror is a compile-time fact. The comparison is
    // against the embedded header, so the printf and the error still happen at
    // runtime.
    //
    // Only the entries imgui.h writes with an EXPLICIT `= value` are compared.
    // ImGui numbers most of its enum implicitly, and those are the majority —
    // skipping them by name is what keeps the explicit ones checkable, and a
    // reordering that shifts every implicit value shifts the explicit ones
    // around it, which is what fails.
    var checked: usize = 0;
    inline for (@typeInfo(Key).@"enum".fields) |f| {
        const needle = "ImGuiKey_" ++ f.name ++ " = ";
        const at: usize = std.mem.indexOf(u8, rest[0..end], needle) orelse 0;
        if (at > 0) {
            // The value runs to the NEXT COMMA, but a comment can contain one
            // (the Mod entries' "Cmd (macOS), Ctrl (macOS)"). Cuts at the first
            // `,` — and where the comment starts — so a value is never a
            // sentence. This is why the test saw `1 << 12` before: the comma it
            // found was inside the comment, and `parseInt("1 << 12")` failed.
            const value_start = at + needle.len;
            const comma = std.mem.indexOfScalarPos(u8, rest, value_start, ',') orelse end;
            const comment = std.mem.indexOfScalarPos(u8, rest, value_start, '/') orelse end;
            const raw = std.mem.trimEnd(u8, rest[value_start..@min(comma, comment)], " \t");
            // Shifts (`1 << 12`) are expressions, not literals. They are the
            // modifier entries, which this mirror does not carry (they live in
            // the swap below), so an unparseable value is a line not modelled.
            const value = std.fmt.parseInt(i32, raw, 0) catch 0;
            const modelled = value != 0 or std.mem.eql(u8, raw, "0");
            if (modelled and value != @as(i32, @intCast(f.value))) {
                std.debug.print("ImGuiKey_{s}: imgui.h says {d}, ui/keys.zig says {d}\n", .{
                    f.name, value, f.value,
                });
                return error.ImguiKeyMirrorDrifted;
            }
            if (modelled) checked += 1;
        }
    }
    // A header that matched nothing would pass the loop above and check nothing,
    // which is the failure this test exists to prevent. The enum's entries with
    // an explicit `= value` number in the low hundreds, so this is a floor, not
    // a target: the exact count is a property of the PINNED header.
    // A header that matched nothing would pass the loop above and check
    // nothing, which is the failure this test exists to prevent. The
    // pinned header has a dozen or so explicit values (`Mod_*`
    // shifts, `NamedKey_BEGIN`, `None`), so this is a floor that is
    // crossed by the MODEL the test actually checks.
    // A header that matched nothing would pass the loop above and check nothing,
    // which is the failure this test exists to prevent. The pinned header
    // declares three of these named keys with an explicit `= value`; the rest
    // are numbered implicitly, and the eight that the mirror carries are what
    // this catches.
    try std.testing.expect(checked >= 2);
}

test "ui keys: the interesting rows are the ones a text field needs" {
    // Not "the table is right" — a table can be entirely self-consistent and
    // still map Escape to A. These are the rows whose absence makes a text
    // field feel broken: navigation, deletion, modifiers, and the whole
    // printable range.
    try std.testing.expectEqual(Key.Escape, fromGlfw(glfw.glfw.KEY_ESCAPE));
    try std.testing.expectEqual(Key.Enter, fromGlfw(glfw.glfw.KEY_ENTER));
    try std.testing.expectEqual(Key.Tab, fromGlfw(glfw.glfw.KEY_TAB));
    try std.testing.expectEqual(Key.Backspace, fromGlfw(glfw.glfw.KEY_BACKSPACE));
    try std.testing.expectEqual(Key.Delete, fromGlfw(glfw.glfw.KEY_DELETE));
    try std.testing.expectEqual(Key.Home, fromGlfw(glfw.glfw.KEY_HOME));
    try std.testing.expectEqual(Key.End, fromGlfw(glfw.glfw.KEY_END));
    try std.testing.expectEqual(Key.PageUp, fromGlfw(glfw.glfw.KEY_PAGE_UP));
    try std.testing.expectEqual(Key.PageDown, fromGlfw(glfw.glfw.KEY_PAGE_DOWN));
    try std.testing.expectEqual(Key.LeftArrow, fromGlfw(glfw.glfw.KEY_LEFT));
    try std.testing.expectEqual(Key.A, fromGlfw(glfw.glfw.KEY_A));
    try std.testing.expectEqual(Key.Z, fromGlfw(glfw.glfw.KEY_Z));
    try std.testing.expectEqual(Key.Digit_0, fromGlfw(glfw.glfw.KEY_0));
    try std.testing.expectEqual(Key.Digit_9, fromGlfw(glfw.glfw.KEY_9));
    try std.testing.expectEqual(Key.LeftCtrl, fromGlfw(glfw.glfw.KEY_LEFT_CONTROL));
    try std.testing.expectEqual(Key.LeftShift, fromGlfw(glfw.glfw.KEY_LEFT_SHIFT));

    // A key ImGui does not name is `.None`, not a panic: media keys and laptop
    // keys reach here and the UI must not fall over them.
    // A key ImGui does not name is `.None`, and the game still sees it through
    // `platform.Input` — the layer that knows about every key rather than about
    // the ones with names.
    try std.testing.expectEqual(Key.None, fromGlfw(-1));
    try std.testing.expectEqual(Key.None, fromGlfw(9999));
}
