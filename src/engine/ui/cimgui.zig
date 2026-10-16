//! `ui.cimgui` — the Zig side of the C ABI declared in `cimgui/ember_imgui_shim.h`.
//!
//! Read `cimgui/ember_imgui_shim.h` first: it explains why the bridge exists
//! (imgui.h is C++ with no `extern "C"`, so Zig cannot name its symbols) and
//! why it contains no design.
//!
//! What this file is: types, enum mirrors, and thin argument-marshalling
//! helpers so that a widget in `ui/widgets/button.zig` reads
//!
//!     cimgui.invisibleButton(id, w, h, 0)
//!
//! and not a nine-argument extern call with a cast on every integer.
//!
//! ## The enum mirrors, and why they are allowed to exist
//!
//! `ImGuiCol_`, `ImGuiWindowFlags_`, `ImGuiStyleVar_` and friends are plain
//! C enums: their values are part of the ABI, they are documented in `imgui.h`,
//! and a wrong value is a wrong colour rather than a crash. Mirroring them in
//! Zig is what turns `push_style_color(4, ...)` into `pushStyleColor(.WindowBg,
//! ...)` — a typo the compiler catches instead of a colour nobody can find.
//!
//! Each mirror carries the header's own value, so a reordering in a future
//! ImGui is visible here. `keys.zig` additionally ships a test that reads
//! `libs/imgui/imgui.h` and fails if the mirrors have drifted, because "the
//! colours went weird after an ImGui bump" is exactly the kind of bug that
//! costs a day.

const std = @import("std");

pub extern fn ember_ui_create() c_int;
pub extern fn ember_ui_destroy() void;
pub extern fn ember_ui_set_config_flags(flags: c_uint) void;
pub extern fn ember_ui_get_config_flags() c_uint;
pub extern fn ember_ui_set_ini_filename(path: ?[*:0]const u8) void;
pub extern fn ember_ui_get_font_loaded() c_int;

pub extern fn ember_ui_init_renderer(device: ?*anyopaque, format: c_uint, frames_in_flight: c_int) c_int;
pub extern fn ember_ui_shutdown_renderer() void;
pub extern fn ember_ui_new_frame(delta_time: f32) void;
pub extern fn ember_ui_render() void;
pub extern fn ember_ui_render_draw_data(pass: ?*anyopaque) void;

pub extern fn ember_ui_set_display_size(w: f32, h: f32) void;
pub extern fn ember_ui_set_focus(focused: c_int) void;
pub extern fn ember_ui_set_mouse_pos(x: f32, y: f32) void;
pub extern fn ember_ui_set_mouse_button(button: c_int, down: c_int) void;
pub extern fn ember_ui_set_mouse_wheel(horizontal: f32, vertical: f32) void;
pub extern fn ember_ui_set_key(imgui_key: c_int, down: c_int) void;
pub extern fn ember_ui_set_input_chars(utf8: [*:0]const u8) void;
pub extern fn ember_ui_want_mouse() c_int;
pub extern fn ember_ui_want_keyboard() c_int;
pub extern fn ember_ui_want_text_input() c_int;

pub extern fn ember_ui_style() ?*anyopaque;
pub extern fn ember_ui_style_colors_dark() void;
pub extern fn ember_ui_style_col(index: c_int) [*]f32;
pub extern fn ember_ui_style_set_color(index: c_int, r: f32, g: f32, b: f32, a: f32) void;
pub extern fn ember_ui_style_set_alpha(v: f32) void;
pub extern fn ember_ui_style_set_font_size(px: f32) void;
pub extern fn ember_ui_style_set_WindowPadding(x: f32, y: f32) void;
pub extern fn ember_ui_style_set_WindowRounding(v: f32) void;
pub extern fn ember_ui_style_set_WindowBorderSize(v: f32) void;
pub extern fn ember_ui_style_set_ChildRounding(v: f32) void;
pub extern fn ember_ui_style_set_ChildBorderSize(v: f32) void;
pub extern fn ember_ui_style_set_PopupRounding(v: f32) void;
pub extern fn ember_ui_style_set_PopupBorderSize(v: f32) void;
pub extern fn ember_ui_style_set_FramePadding(x: f32, y: f32) void;
pub extern fn ember_ui_style_set_FrameRounding(v: f32) void;
pub extern fn ember_ui_style_set_FrameBorderSize(v: f32) void;
pub extern fn ember_ui_style_set_ItemSpacing(x: f32, y: f32) void;
pub extern fn ember_ui_style_set_ItemInnerSpacing(x: f32, y: f32) void;
pub extern fn ember_ui_style_set_CellPadding(x: f32, y: f32) void;
pub extern fn ember_ui_style_set_TouchExtraPadding(x: f32, y: f32) void;
pub extern fn ember_ui_style_set_IndentSpacing(v: f32) void;
pub extern fn ember_ui_style_set_ColumnsMinSpacing(v: f32) void;
pub extern fn ember_ui_style_set_ScrollbarSize(v: f32) void;
pub extern fn ember_ui_style_set_GrabMinSize(v: f32) void;
pub extern fn ember_ui_style_set_GrabRounding(v: f32) void;
pub extern fn ember_ui_style_set_TabRounding(v: f32) void;
pub extern fn ember_ui_style_set_TabBorderSize(v: f32) void;
pub extern fn ember_ui_scale_all_sizes(scale: f32) void;

pub extern fn ember_ui_load_font(path: [*:0]const u8, size: f32) c_int;
pub extern fn ember_ui_push_font(handle: c_int) ?*anyopaque;
pub extern fn ember_ui_pop_font() void;
pub extern fn ember_ui_set_font(handle: c_int) void;
pub extern fn ember_ui_font_current() ?*anyopaque;
pub extern fn ember_ui_font_default() ?*anyopaque;
pub extern fn ember_ui_font_measure(font: ?*anyopaque, size: f32) f32;

pub extern fn ember_ui_begin(name: [*:0]const u8, flags: c_int) c_int;
pub extern fn ember_ui_end() void;
pub extern fn ember_ui_set_next_window_pos(x: f32, y: f32, cond: c_int) void;
pub extern fn ember_ui_set_next_window_pos_center(x: f32, y: f32, cond: c_int) void;
pub extern fn ember_ui_set_next_window_size(w: f32, h: f32, cond: c_int) void;
pub extern fn ember_ui_set_next_window_bg_alpha(alpha: f32) void;
pub extern fn ember_ui_begin_child(id: [*:0]const u8, w: f32, h: f32, child_flags: c_int, window_flags: c_int) c_int;
pub extern fn ember_ui_end_child() void;
pub extern fn ember_ui_set_next_item_width(width: f32) void;
pub extern fn ember_ui_push_item_width(width: f32) void;
pub extern fn ember_ui_get_cursor_pos(out_xy: [*]f32) void;
pub extern fn ember_ui_set_cursor_pos(x: f32, y: f32) void;
pub extern fn ember_ui_get_cursor_screen_pos(out_xy: [*]f32) void;
pub extern fn ember_ui_get_content_region_avail(out_wh: [*]f32) void;
pub extern fn ember_ui_get_item_rect_min(out_xy: [*]f32) void;
pub extern fn ember_ui_get_item_rect_max(out_xy: [*]f32) void;
pub extern fn ember_ui_dummy(w: f32, h: f32) void;
pub extern fn ember_ui_spacing() void;
pub extern fn ember_ui_same_line(offset_from_start: f32, spacing: f32) void;
pub extern fn ember_ui_indent(width: f32) void;
pub extern fn ember_ui_unindent(width: f32) void;
pub extern fn ember_ui_separator() void;
pub extern fn ember_ui_frame_height() f32;
pub extern fn ember_ui_frame_height_with_spacing() f32;
pub extern fn ember_ui_text_line_height() f32;
pub extern fn ember_ui_item_spacing(out_xy: [*]f32) void;
pub extern fn ember_ui_window_padding(out_xy: [*]f32) void;

pub extern fn ember_ui_push_id_str(id: [*:0]const u8) void;
pub extern fn ember_ui_push_id_int(id: c_int) void;
pub extern fn ember_ui_push_id_ptr(id: ?*const anyopaque) void;
pub extern fn ember_ui_pop_id() void;
pub extern fn ember_ui_push_style_color(index: c_int, col: c_uint) void;
pub extern fn ember_ui_push_style_color4(index: c_int, r: f32, g: f32, b: f32, a: f32) void;
pub extern fn ember_ui_pop_style_color(count: c_int) void;
pub extern fn ember_ui_push_style_var_f(index: c_int, value: f32) void;
pub extern fn ember_ui_push_style_var_v2(index: c_int, x: f32, y: f32) void;
pub extern fn ember_ui_push_style_var_x(index: c_int, x: f32) void;
pub extern fn ember_ui_push_style_var_y(index: c_int, y: f32) void;
pub extern fn ember_ui_pop_style_var(count: c_int) void;
pub extern fn ember_ui_push_item_flag(flags: c_int) void;
pub extern fn ember_ui_pop_item_flag() void;
pub extern fn ember_ui_hash_str(s: [*:0]const u8) c_uint;

pub extern fn ember_ui_button(label: [*:0]const u8, w: f32, h: f32) c_int;
pub extern fn ember_ui_invisible_button(str_id: [*:0]const u8, w: f32, h: f32, flags: c_int) c_int;
pub extern fn ember_ui_checkbox(label: [*:0]const u8, value: *c_int) c_int;
pub extern fn ember_ui_radio_button(label: [*:0]const u8, value: *c_int, active: c_int) c_int;
pub extern fn ember_ui_selectable(label: [*:0]const u8, selected: c_int, flags: c_int, w: f32, h: f32) c_int;
pub extern fn ember_ui_input_text(label: [*:0]const u8, buf: [*]u8, capacity: c_uint, flags: c_int) c_int;
pub extern fn ember_ui_input_text_multiline(label: [*:0]const u8, buf: [*]u8, capacity: c_uint, size: *const [2]f32, flags: c_int) c_int;
pub extern fn ember_ui_drag_float(label: [*:0]const u8, value: *f32, speed: f32, vmin: f32, vmax: f32, fmt: [*:0]const u8, flags: c_int) c_int;
pub extern fn ember_ui_drag_int(label: [*:0]const u8, value: *c_int, speed: f32, vmin: c_int, vmax: c_int, flags: c_int) c_int;
pub extern fn ember_ui_drag_float2(label: [*:0]const u8, value: *f32, speed: f32, vmin: f32, vmax: f32, fmt: [*:0]const u8, flags: c_int) c_int;
pub extern fn ember_ui_slider_float(label: [*:0]const u8, value: *f32, vmin: f32, vmax: f32, fmt: [*:0]const u8, flags: c_int) c_int;
pub extern fn ember_ui_color_edit4(label: [*:0]const u8, rgba: *f32, flags: c_int) c_int;
pub extern fn ember_ui_begin_combo(label: [*:0]const u8, preview: [*:0]const u8, flags: c_int) c_int;
pub extern fn ember_ui_end_combo() void;
pub extern fn ember_ui_collapsing_header(label: [*:0]const u8, flags: c_int) c_int;
pub extern fn ember_ui_tree_node(label: [*:0]const u8, flags: c_int) c_int;
pub extern fn ember_ui_tree_pop() void;
pub extern fn ember_ui_begin_popup(id: [*:0]const u8, flags: c_int) c_int;
pub extern fn ember_ui_end_popup() void;
pub extern fn ember_ui_open_popup(id: [*:0]const u8) c_int;
pub extern fn ember_ui_begin_popup_modal(id: [*:0]const u8, flags: c_int) c_int;
pub extern fn ember_ui_is_popup_open(id: [*:0]const u8, flags: c_int) c_int;
pub extern fn ember_ui_begin_menu_bar(name: [*:0]const u8) c_int;
pub extern fn ember_ui_end_menu_bar() void;
pub extern fn ember_ui_menu_item(label: [*:0]const u8, shortcut: ?[*:0]const u8, selected: ?*c_int, flags: c_int) c_int;
pub extern fn ember_ui_begin_tooltip() c_int;
pub extern fn ember_ui_end_tooltip() void;
pub extern fn ember_ui_set_tooltip(text: [*:0]const u8) void;
pub extern fn ember_ui_is_item_hovered(flags: c_int) c_int;
pub extern fn ember_ui_is_item_clicked(button: c_int) c_int;
pub extern fn ember_ui_is_item_active() c_int;
pub extern fn ember_ui_is_item_deactivated_after_edit() c_int;
pub extern fn ember_ui_is_item_focused() c_int;
pub extern fn ember_ui_is_window_focused(flags: c_int) c_int;
pub extern fn ember_ui_set_window_focus() void;
pub extern fn ember_ui_text(s: [*:0]const u8) void;
pub extern fn ember_ui_text_colored(col: c_uint, s: [*:0]const u8) void;
pub extern fn ember_ui_text_wrapped(col: c_uint, s: [*:0]const u8) void;
pub extern fn ember_ui_text_unformatted(s: [*:0]const u8) void;
pub extern fn ember_ui_calc_text_size(s: [*:0]const u8, out_wh: [*]f32) void;
pub extern fn ember_ui_calc_text_size_ws(s: [*:0]const u8, wrap_width: f32, out_wh: [*]f32) void;
pub extern fn ember_ui_time() f64;
pub extern fn ember_ui_frame_count() c_longlong;

pub extern fn ember_ui_get_item_draw_list() ?*anyopaque;
pub extern fn ember_ui_get_window_draw_list() ?*anyopaque;
pub extern fn ember_ui_get_foreground_draw_list() ?*anyopaque;
pub extern fn ember_ui_get_background_draw_list() ?*anyopaque;

pub extern fn ember_draw_rect_filled(dl: ?*anyopaque, x0: f32, y0: f32, x1: f32, y1: f32, col: c_uint, rounding: f32, flags: c_int) void;
pub extern fn ember_draw_rect(dl: ?*anyopaque, x0: f32, y0: f32, x1: f32, y1: f32, col: c_uint, rounding: f32, thickness: f32, flags: c_int) void;
pub extern fn ember_draw_rect_filled_multi(dl: ?*anyopaque, x0: f32, y0: f32, x1: f32, y1: f32, c_tl: c_uint, c_tr: c_uint, c_br: c_uint, c_bl: c_uint) void;
pub extern fn ember_draw_circle_filled(dl: ?*anyopaque, cx: f32, cy: f32, radius: f32, col: c_uint, segments: c_int) void;
pub extern fn ember_draw_circle(dl: ?*anyopaque, cx: f32, cy: f32, radius: f32, col: c_uint, segments: c_int, thickness: f32) void;
pub extern fn ember_draw_line(dl: ?*anyopaque, x0: f32, y0: f32, x1: f32, y1: f32, col: c_uint, thickness: f32) void;
pub extern fn ember_draw_text(dl: ?*anyopaque, font: ?*anyopaque, x: f32, y: f32, col: c_uint, s: [*:0]const u8) void;
pub extern fn ember_draw_path_arc(dl: ?*anyopaque, cx: f32, cy: f32, radius: f32, a0: f32, a1: f32, segments: c_int) void;
pub extern fn ember_draw_path_line(dl: ?*anyopaque, x: f32, y: f32) void;
pub extern fn ember_draw_path_reset(dl: ?*anyopaque) void;
pub extern fn ember_draw_path_fill(dl: ?*anyopaque, col: c_uint) void;
pub extern fn ember_draw_path_stroke(dl: ?*anyopaque, col: c_uint, thickness: f32, flags: c_int) void;
pub extern fn ember_draw_push_clip(dl: ?*anyopaque, x0: f32, y0: f32, x1: f32, y1: f32, intersect: c_int) void;
pub extern fn ember_draw_pop_clip(dl: ?*anyopaque) void;
pub extern fn ember_draw_cmd_count(dl: ?*anyopaque) c_int;

/// ORs flag constants. `flags(WindowFlags.NoResize, WindowFlags.NoMove)` reads as
/// the thing it is, and returns the integer ImGui wants — rather than making every
/// call site reach for `or` and every reader count the bits.
pub fn flags(a: u32, b: u32) u32 {
    return a | b;
}

// ── Enums ────────────────────────────────────────────────────────────────

pub const Col = enum(c_int) {
    Text = 0,
    TextDisabled = 1,
    WindowBg = 2,
    ChildBg = 3,
    PopupBg = 4,
    Border = 5,
    BorderShadow = 6,
    FrameBg = 7,
    FrameBgHovered = 8,
    FrameBgActive = 9,
    TitleBg = 10,
    TitleBgActive = 11,
    TitleBgCollapsed = 12,
    MenuBarBg = 13,
    ScrollbarBg = 14,
    ScrollbarGrab = 15,
    ScrollbarGrabHovered = 16,
    ScrollbarGrabActive = 17,
    CheckMark = 18,
    SliderGrab = 19,
    SliderGrabActive = 20,
    Button = 21,
    ButtonHovered = 22,
    ButtonActive = 23,
    Header = 24,
    HeaderHovered = 25,
    HeaderActive = 26,
    Separator = 27,
    SeparatorHovered = 28,
    SeparatorActive = 29,
    ResizeGrip = 30,
    ResizeGripHovered = 31,
    ResizeGripActive = 32,
    Tab = 33,
    TabHovered = 34,
    TabSelected = 35,
    TabSelectedOverline = 36,
    DockingPreview = 37,
    DockingEmptyBg = 38,
    PlotLines = 39,
    PlotLinesHovered = 40,
    PlotHistogram = 41,
    PlotHistogramHovered = 42,
    TableHeaderBg = 43,
    TableBorderStrong = 44,
    TableBorderLight = 45,
    TableRowBg = 46,
    TableRowBgAlt = 47,
    TextSelectedBg = 48,
    DragDropTarget = 49,
    NavHighlight = 50,
    NavWindowingHighlight = 51,
    NavWindowingDimBg = 52,
    ModalWindowDimBg = 53,
    COUNT = 54,
};

pub const Cond = enum(c_int) { None = 0, Always = 1, Once = 2, FirstUseEver = 4, Appearing = 8 };

/// WindowFlags — ImGui takes these as ONE integer, so they are integers here.
///
/// `flags(a, b)` ORs them. Every value comes from the pinned imgui.h.
pub const WindowFlags = struct {
    pub const @"None": u32 = 0;
    pub const NoTitleBar: u32 = (1 << @as(u32,1));
    pub const NoResize: u32 = (1 << @as(u32,2));
    pub const NoMove: u32 = (1 << @as(u32,3));
    pub const NoScrollbar: u32 = (1 << @as(u32,4));
    pub const NoScrollWithMouse: u32 = (1 << @as(u32,5));
    pub const NoCollapse: u32 = (1 << @as(u32,6));
    pub const AlwaysAutoResize: u32 = (1 << @as(u32,7));
    pub const NoBackground: u32 = (1 << @as(u32,8));
    pub const NoSavedSettings: u32 = (1 << @as(u32,9));
    pub const NoMouseInputs: u32 = (1 << @as(u32,10));
    pub const MenuBar: u32 = (1 << @as(u32,11));
    pub const HorizontalScrollbar: u32 = (1 << @as(u32,12));
    pub const NoFocusOnAppearing: u32 = (1 << @as(u32,13));
    pub const NoBringToFrontOnFocus: u32 = (1 << @as(u32,14));
    pub const AlwaysVerticalScrollbar: u32 = (1 << @as(u32,15));
    pub const AlwaysHorizontalScrollbar: u32 = (1 << @as(u32,16));
    pub const AlwaysUseWindowPadding: u32 = (1 << @as(u32,17));
    pub const NoNavInputs: u32 = (1 << @as(u32,18));
    pub const NoNavFocus: u32 = (1 << @as(u32,19));
    pub const UnsavedDocument: u32 = (1 << @as(u32,20));
    pub const NoNav: u32 = (1 << @as(u32,18)) | (1 << @as(u32,19));
    pub const NoDecoration: u32 = (1 << @as(u32,1)) | (1 << @as(u32,2)) | (1 << @as(u32,4)) | (1 << @as(u32,6));
    pub const NoInputs: u32 = (1 << @as(u32,10)) | (1 << @as(u32,18)) | (1 << @as(u32,19));
};

/// ChildFlags — ImGui takes these as ONE integer, so they are integers here.
///
/// `flags(a, b)` ORs them. Every value comes from the pinned imgui.h.
pub const ChildFlags = struct {
    pub const @"None": u32 = 0;
    pub const Borders: u32 = 0;
    pub const ResizeX: u32 = (1 << @as(u32,1));
    pub const AlwaysUseWindowPadding: u32 = (1 << @as(u32,2));
    pub const BorderSize: u32 = (1 << @as(u32,3));
    pub const AutoResizeX: u32 = (1 << @as(u32,4));
    pub const AutoResizeY: u32 = (1 << @as(u32,5));
    pub const AlwaysVerticalScrollbar: u32 = (1 << @as(u32,6));
    pub const AlwaysHorizontalScrollbar: u32 = (1 << @as(u32,7));
    pub const FrameStyle: u32 = (1 << @as(u32,10));
};

/// ButtonFlags — ImGui takes these as ONE integer, so they are integers here.
///
/// `flags(a, b)` ORs them. Every value comes from the pinned imgui.h.
pub const ButtonFlags = struct {
    pub const @"None": u32 = 0;
    pub const Left: u32 = 0;
    pub const Right: u32 = (1 << @as(u32,1));
    pub const Middle: u32 = (1 << @as(u32,2));
};

/// ItemFlags — ImGui takes these as ONE integer, so they are integers here.
///
/// `flags(a, b)` ORs them. Every value comes from the pinned imgui.h.
pub const ItemFlags = struct {
    pub const @"None": u32 = 0;
    pub const NoTabStop: u32 = 0;
    pub const Disabled: u32 = (1 << @as(u32,1));
    pub const NoNav: u32 = (1 << @as(u32,2));
    pub const Selectable: u32 = (1 << @as(u32,3));
};

/// HoveredFlags — ImGui takes these as ONE integer, so they are integers here.
///
/// `flags(a, b)` ORs them. Every value comes from the pinned imgui.h.
pub const HoveredFlags = struct {
    pub const @"None": u32 = 0;
    pub const ChildWindows: u32 = 0;
    pub const AllowWhenBlockedByPopup: u32 = (1 << @as(u32,1));
    pub const AllowWhenBlockedByActiveItem: u32 = (1 << @as(u32,2));
    pub const ForTooltip: u32 = (1 << @as(u32,3));
    pub const Stationary: u32 = (1 << @as(u32,13));
    pub const DelayShort: u32 = (1 << @as(u32,14));
    pub const DelayNormal: u32 = (1 << @as(u32,15));
    pub const NoTooltip: u32 = (1 << @as(u32,20));
};

/// SelectableFlags — ImGui takes these as ONE integer, so they are integers here.
///
/// `flags(a, b)` ORs them. Every value comes from the pinned imgui.h.
pub const SelectableFlags = struct {
    pub const @"None": u32 = 0;
    pub const DontClosePopups: u32 = 0;
    pub const SpanAllColumns: u32 = (1 << @as(u32,1));
    pub const AllowDoubleClick: u32 = (1 << @as(u32,2));
    pub const Disabled: u32 = (1 << @as(u32,3));
    pub const AllowOverlap: u32 = (1 << @as(u32,5));
};

/// TreeNodeFlags — ImGui takes these as ONE integer, so they are integers here.
///
/// `flags(a, b)` ORs them. Every value comes from the pinned imgui.h.
pub const TreeNodeFlags = struct {
    pub const @"None": u32 = 0;
    pub const Leaves: u32 = (1 << @as(u32,6));
    pub const Framed: u32 = (1 << @as(u32,11));
    pub const FramePadding: u32 = (1 << @as(u32,12));
    pub const SpanAvailWidth: u32 = (1 << @as(u32,13));
    pub const SpanAllColumns: u32 = (1 << @as(u32,14));
    pub const DefaultOpen: u32 = (1 << @as(u32,15));
    pub const DefaultClosed: u32 = (1 << @as(u32,16));
    pub const OpenOnArrow: u32 = (1 << @as(u32,17));
    pub const OpenOnDoubleClick: u32 = (1 << @as(u32,18));
    pub const Overlay: u32 = (1 << @as(u32,19));
    pub const AutoOpen: u32 = (1 << @as(u32,20));
};

/// InputTextFlags — ImGui takes these as ONE integer, so they are integers here.
///
/// `flags(a, b)` ORs them. Every value comes from the pinned imgui.h.
pub const InputTextFlags = struct {
    pub const @"None": u32 = 0;
    pub const CharsDecimal: u32 = 0;
    pub const CharsNoDecimal: u32 = (1 << @as(u32,1));
    pub const CharsHexadecimal: u32 = (1 << @as(u32,2));
    pub const CharsUppercase: u32 = (1 << @as(u32,3));
    pub const CharsNoUppercase: u32 = (1 << @as(u32,4));
    pub const AutoSelectAll: u32 = (1 << @as(u32,5));
    pub const EnterReturnsTrue: u32 = (1 << @as(u32,6));
    pub const CallbackCompletion: u32 = (1 << @as(u32,7));
    pub const CallbackHistory: u32 = (1 << @as(u32,8));
    pub const AllowTabInput: u32 = (1 << @as(u32,9));
    pub const CtrlEnterForNewLine: u32 = (1 << @as(u32,10));
    pub const NoHorizontalScroll: u32 = (1 << @as(u32,11));
    pub const AlwaysOverwrite: u32 = (1 << @as(u32,12));
    pub const ReadOnly: u32 = (1 << @as(u32,13));
    pub const Password: u32 = (1 << @as(u32,14));
    pub const NoUndoRedo: u32 = (1 << @as(u32,16));
    pub const CharsScientific: u32 = (1 << @as(u32,17));
    pub const CallbackResize: u32 = (1 << @as(u32,18));
    pub const CallbackEdit: u32 = (1 << @as(u32,19));
    pub const EscapeClearsAll: u32 = (1 << @as(u32,20));
};

/// SliderFlags — ImGui takes these as ONE integer, so they are integers here.
///
/// `flags(a, b)` ORs them. Every value comes from the pinned imgui.h.
pub const SliderFlags = struct {
    pub const @"None": u32 = 0;
    pub const AlwaysClamp: u32 = (1 << @as(u32,4));
    pub const Logarithmic: u32 = (1 << @as(u32,5));
    pub const NoRound: u32 = (1 << @as(u32,6));
    pub const NoInput: u32 = (1 << @as(u32,7));
    pub const MouseSameAsDrag: u32 = (1 << @as(u32,8));
};

/// DrawFlags — ImGui takes these as ONE integer, so they are integers here.
///
/// `flags(a, b)` ORs them. Every value comes from the pinned imgui.h.
pub const DrawFlags = struct {
    pub const @"None": u32 = 0;
    pub const Closed: u32 = (1 << @as(u32,9));
    pub const RoundCornersNone: u32 = 0;
    pub const RoundCornersTopLeft: u32 = (1 << @as(u32,1));
    pub const RoundCornersTopRight: u32 = (1 << @as(u32,2));
    pub const RoundCornersBotLeft: u32 = (1 << @as(u32,3));
    pub const RoundCornersBotRight: u32 = (1 << @as(u32,4));
    pub const RoundCornersTop: u32 = (1 << @as(u32,1)) | (1 << @as(u32,2));
    pub const RoundCornersBottom: u32 = (1 << @as(u32,3)) | (1 << @as(u32,4));
    pub const RoundCornersLeft: u32 = (1 << @as(u32,1)) | (1 << @as(u32,3));
    pub const RoundCornersRight: u32 = (1 << @as(u32,2)) | (1 << @as(u32,4));
    pub const RoundCornersAll: u32 = (1 << @as(u32,1)) | (1 << @as(u32,2)) | (1 << @as(u32,3)) | (1 << @as(u32,4));
};

/// ConfigFlags — ImGui takes these as ONE integer, so they are integers here.
///
/// `flags(a, b)` ORs them. Every value comes from the pinned imgui.h.
pub const ConfigFlags = struct {
    pub const @"None": u32 = 0;
    pub const NavEnableKeyboard: u32 = 0;
    pub const NavEnableGamepad: u32 = (1 << @as(u32,1));
    pub const NavEnableSetMousePos: u32 = (1 << @as(u32,2));
    pub const NavNoCaptureKeyboard: u32 = (1 << @as(u32,3));
    pub const NoMouse: u32 = (1 << @as(u32,4));
    pub const NoMouseCursorChange: u32 = (1 << @as(u32,5));
    pub const IsTouch: u32 = (1 << @as(u32,6));
    pub const IsPen: u32 = (1 << @as(u32,7));
    pub const ViewportsEnable: u32 = (1 << @as(u32,10));
    pub const DockingEnable: u32 = (1 << @as(u32,11));
    pub const IsSrgb: u32 = (1 << @as(u32,20));
    pub const IsViewer: u32 = (1 << @as(u32,21));
    pub const NoDpi: u32 = (1 << @as(u32,22));
    pub const AlwaysUseTweak: u32 = (1 << @as(u32,24));
};

pub const StyleVar = enum(c_int) {
    Alpha = 0,
    DisabledAlpha = 1,
    WindowPadding = 2,
    WindowRounding = 3,
    WindowBorderSize = 4,
    WindowTitleAlign = 5,
    ChildRounding = 6,
    ChildBorderSize = 7,
    PopupRounding = 8,
    PopupBorderSize = 9,
    FramePadding = 11,
    FrameRounding = 12,
    FrameBorderSize = 13,
    ItemSpacing = 14,
    ItemInnerSpacing = 15,
    CellPadding = 16,
    TouchExtraPadding = 17,
    IndentSpacing = 18,
    ColumnsMinSpacing = 19,
    ScrollbarSize = 20,
    ScrollbarRounding = 21,
    GrabMinSize = 22,
    GrabRounding = 23,
    LogSliderDeadzone = 24,
    TabRounding = 25,
    TabBorderSize = 26,
    TabMinWidthForCloseButton = 27,
    ColorButtonPosition = 28,
    ButtonTextAlign = 29,
    SelectableTextAlign = 30,
    DisplayWindowPadding = 31,
    DisplaySafeAreaPadding = 32,
    MouseCursorScale = 33,
    AntiAliasedLines = 34,
    AntiAliasedLinesUseTex = 35,
    AntiAliasedFill = 36,
    CurveTessellationTol = 37,
    CircleTessellationMaxError = 38,
    COUNT = 39,
};

pub const Cursor = enum(c_int) {
    @"None" = 0,
    Arrow = 1,
    TextInput = 2,
    ResizeAll = 3,
    ResizeNS = 4,
    ResizeEW = 5,
    ResizeNESW = 6,
    ResizeNWSE = 7,
    Hand = 8,
    NotAllowed = 9,
    /// 1024+ are the platform cursors: an ImGui backend may use them, and the
    /// editor does not yet. Naming it `Size*` (as imgui.h does in 1.92.9) would
    /// make `u32` unusable as a field name anywhere below.
    ResizeVertical = 1024,
    ResizeHorizontal = 1025,
    ResizeAll2 = 1026,
    ResizeNESW2 = 1027,
    ResizeNWSE2 = 1028,
};

pub const FocusedFlags = enum(c_int) {
    @"None" = 0,
    ChildWindows = 1,
    RootWindow = 2,
    PopupWindows = 4,
};

pub const MouseButton = enum(c_int) { None = -1, Left = 0, Right = 1, Middle = 2 };

/// Keyboard modifiers, as ImGui's `ImGuiMod_*` values.
///
/// They are NOT `Key` values: a `Key` is a physical key (512..666, `LeftCtrl`
/// is 527) while a mod is a four-bit flag `1 << 12`..`1 << 15`. A chord stores
/// the flag, a rebind screen lists the physical key, and conflating them is how
/// a shortcut starts responding to the wrong key — or, worse, how a backend
/// hands `AddKeyEvent` a value that is neither, and trips ImGui's assertion.
pub const Mod = enum(c_int) {
    None = 0,
    Ctrl = 1 << 12,
    Shift = 1 << 13,
    Alt = 1 << 14,
    Super = 1 << 15,
};

/// PopupFlags — ImGui takes these as ONE integer, so they are integers here.
///
/// `flags(a, b)` ORs them. Every value comes from the pinned imgui.h.
pub const PopupFlags = struct {
    pub const @"None": u32 = 0;
    pub const MouseButtonLeft: u32 = (1 << @as(u32,2));
    pub const NoReopen: u32 = (1 << @as(u32,5));
    pub const NoOpenOverExistingPopup: u32 = (1 << @as(u32,7));
    pub const NoOpenOverItems: u32 = (1 << @as(u32,8));
    pub const AnyPopupId: u32 = (1 << @as(u32,10));
    pub const AnyPopupLevel: u32 = (1 << @as(u32,11));
};

/// ComboFlags — ImGui takes these as ONE integer, so they are integers here.
///
/// `flags(a, b)` ORs them. Every value comes from the pinned imgui.h.
pub const ComboFlags = struct {
    pub const @"None": u32 = 0;
    pub const HeightSmall: u32 = (1 << @as(u32,1));
    pub const HeightRegular: u32 = (1 << @as(u32,2));
    pub const HeightLarge: u32 = (1 << @as(u32,3));
    pub const NoArrowButton: u32 = (1 << @as(u32,4));
    pub const NoPreview: u32 = (1 << @as(u32,5));
};


// ── Argument-marshalling helpers ─────────────────────────────────────────
//
// Each one exists because the raw extern call is wrong in a way the compiler
// does not catch. They are all one-liners with a reason attached; a helper with
// no reason is a helper that should be inlined back into the widget.

/// ImGui takes NUL-terminated strings and Zig slices are not NUL-terminated.
///
/// The alternative — `buf: [256]u8 = s[0..256] ++ "\x00"` — is a memcpy plus a
/// bounds dance at every call site, and the bounds dance is where the bug is:
/// a label of exactly 255 bytes silently loses its last character. This one
/// truncates to 255 and always terminates, so a long label is shorter and a
/// near-overflow label is still correct.
pub const label_buf: usize = 256;

/// The scratch buffer `Cstr` copies into, one per THREAD.
///
/// Per thread rather than shared, because "the string the C ABI is reading"
/// is per-call state and two threads in the same frame (a loader and the draw
/// thread) would otherwise overwrite each other's labels. The size is the
/// label budget: a label longer than the budget is truncated, and a UI whose
/// labels are 256 bytes of text has a different problem.
threadlocal var label_scratch: [label_buf]u8 = undefined;

/// Turns a Zig slice into the NUL-terminated slice the C ABI wants.
///
/// The copy into a thread-local buffer is the ONLY correct option: `s[0..n :0]`
/// claims the byte at `s[n]` is 0, and for a caller-owned slice it is whatever
/// the caller had there. That is not a shortcut, it is a lie the compiler
/// believes — and the API on the other side reads until it finds a zero, which
/// is how a truncated label turns into 256 bytes of the next widget's memory.
/// The comptime-known form, for the constant labels.
///
/// A literal `"##v"` already has a zero after it in memory, so the conversion
/// is a reinterpretation and no copy happens — which is why it is comptime.
pub fn CstrLit(comptime s: [:0]const u8) [*:0]const u8 {
    return s;
}

pub fn Cstr(s: []const u8) [*:0]const u8 {
    const n: usize = if (s.len >= label_buf) label_buf - 1 else s.len;
    // The buffer is written and its length is FIXED before the slice is taken,
    // which is what lets Zig accept `[0..n :0]` on a runtime `n`: the sentinel
    // is a byte at `label_scratch[n]`, and `n < label_buf` is the invariant the
    // branch above maintains.
    var i: usize = 0;
    while (i < n) : (i += 1) label_scratch[i] = s[i];
    label_scratch[n] = 0;
    return @as([*:0]const u8, @ptrCast(&label_scratch));
}

/// The common case: a label, with the framework's own limit.
pub fn text(s: []const u8) [*:0]const u8 {
    return Cstr(s);
}

/// The comptime version: a literal, no copy. `cimgui.text("##v")` at a
/// module-level `const` needs this one, and the distinction is the whole point:
/// a literal's zero is already in the binary, and a runtime string's is not.
pub fn textLit(comptime s: [:0]const u8) [*:0]const u8 {
    return CstrLit(s);
}

/// Float formatting for the drag/slider widgets. The default is "%.3f", which
/// turns every integer-valued transform in an inspector into "1.000" — a
/// value that reads as a float because the widget decided so, not because the
/// data is one.
pub const fmt_f3 = textLit("%.3f");
pub const fmt_f1 = textLit("%.1f");
pub const fmt_f0 = textLit("%.0f");

/// Reads a `float*` out of the style as an `[4]f32`. Used by `theme.apply`.
pub fn styleColor(col: Col) [*]f32 {
    return ember_ui_style_col(@intFromEnum(col));
}


// ── Colours ──────────────────────────────────────────────────────────────

/// An RGBA colour in the SAME layout ImGui packs them: 0xAABBGGRR.
///
/// The layout is the single most common way to get a UI's colours wrong, and
/// the failure is silent: 0xFF404040 and 0x404040FF both "work", and one of
/// them is transparent black. It is spelled out here once so the mistake has to
/// be made on purpose.
pub const Rgba = struct {
    r: f32,
    g: f32,
    b: f32,
    a: f32 = 1.0,

    /// 0..1 floats, as the theme writes them.
    pub fn of(r: f32, g: f32, b: f32, a: f32) Rgba {
        return .{ .r = r, .g = g, .b = b, .a = a };
    }

    /// From a 0xRRGGBB literal, which is how every designer writes a colour.
    /// The layout of THIS function is the readable one; the layout of what goes
    /// to the GPU is ImGui's problem, and `pack` is where the conversion
    /// happens exactly once.
    pub fn hex(v: u32, a: f32) Rgba {
        return .{
            .r = @as(f32, @floatFromInt((v >> 16) & 0xFF)) / 255.0,
            .g = @as(f32, @floatFromInt((v >> 8) & 0xFF)) / 255.0,
            .b = @as(f32, @floatFromInt(v & 0xFF)) / 255.0,
            .a = a,
        };
    }

    /// The packed form ImGui takes, 0xAABBGGRR.
    ///
    /// Named `pack` and not `u32`, because a method named after a primitive
    /// hides what it is: this is a conversion, and it should read like one at
    /// the call site (`col.pack()`).
    pub fn pack(self: Rgba) u32 {
        const A: u32 = toByte(self.a);
        const B: u32 = toByte(self.b);
        const G: u32 = toByte(self.g);
        const R: u32 = toByte(self.r);
        return (A << 24) | (B << 16) | (G << 8) | R;
    }

    pub fn withAlpha(self: Rgba, a: f32) Rgba {
        return .{ .r = self.r, .g = self.g, .b = self.b, .a = a };
    }

    pub fn lerp(self: Rgba, other: Rgba, t: f32) Rgba {
        const k = std.math.clamp(t, 0.0, 1.0);
        return .{
            .r = self.r + (other.r - self.r) * k,
            .g = self.g + (other.g - self.g) * k,
            .b = self.b + (other.b - self.b) * k,
            .a = self.a + (other.a - self.a) * k,
        };
    }

    pub fn scaled(self: Rgba, k: f32) Rgba {
        return .{ .r = self.r * k, .g = self.g * k, .b = self.b * k, .a = self.a };
    }

    fn toByte(v: f32) u32 {
        const x = @as(i32, @intFromFloat(@min(@max(v, 0.0), 1.0) * 255.0 + 0.5));
        return @intCast(@max(0, @min(255, x)));
    }
};


pub const Vec2 = extern struct { x: f32 = 0, y: f32 = 0 };
pub const Rect = extern struct { min: Vec2 = .{}, max: Vec2 = .{} };
