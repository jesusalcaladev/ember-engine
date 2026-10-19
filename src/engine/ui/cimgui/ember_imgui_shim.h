// ember_imgui_shim.h — the C ABI between Zig and Dear ImGui.
//
// WHY THIS FILE EXISTS
// -------------------
// `imgui.h` is C++, and it is not `extern "C"`: every `ImGui::` symbol is
// name-mangled, so a Zig `extern fn ImGui_Button(...)` would not link and
// could not even be spelled. cimgui solves this by generating a C wrapper; we
// solve it by writing one by hand, because the wrapper we actually need is
// small, and a generated one carries 4 MB of bindings for the 200 functions
// this editor uses.
//
// The rule that keeps this file honest: **it contains no design.** No colour,
// no spacing, no widget. Everything here is a mechanical translation of one
// ImGui call into a C symbol; every decision about how the editor LOOKS lives
// in `src/engine/ui/theme.zig` and the widgets, in Zig, where they can be
// changed and reviewed. The day this file starts making choices is the day the
// framework has stopped being one.
//
// Conventions:
//   - `int` returns are `bool` in disguise (0/1).
//   - Colours are `unsigned int` (ImU32, 0xAABBGGRR — note the order).
//   - Enum parameters are `int`, with Zig mirroring the enum in cimgui.zig.
//   - `void*` handles are opaque on the Zig side (ImDrawList*, ImFont*, ...).

#ifndef EMBER_UI_SHIM_H
#define EMBER_UI_SHIM_H

#ifdef __cplusplus
extern "C" {
#endif

// ── Context lifecycle ───────────────────────────────────────────────────
int ember_ui_create(void);
void ember_ui_destroy(void);
void ember_ui_set_config_flags(unsigned int flags);
unsigned int ember_ui_get_config_flags(void);
void ember_ui_set_ini_filename(const char* path); // NULL disables imgui.ini
int ember_ui_get_font_loaded(void);

// ── Renderer (WebGPU / Dawn) ────────────────────────────────────────────
// `device` is a WGPUDevice, `format` a WGPUTextureFormat. The engine's Dawn
// device is passed straight through: ImGui does not get to own a GPU context,
// it draws into a pass the engine opens (see `ember_ui_render_draw_data`).
int ember_ui_init_renderer(void* device, unsigned int format, int frames_in_flight);
void ember_ui_shutdown_renderer(void);
void ember_ui_new_frame(float delta_time);
void ember_ui_render(void);
void ember_ui_render_draw_data(void* render_pass_encoder);

// ── Platform input ──────────────────────────────────────────────────────
void ember_ui_set_display_size(float w, float h);
void ember_ui_set_focus(int focused);
void ember_ui_set_mouse_pos(float x, float y);
void ember_ui_set_mouse_button(int button, int down);
void ember_ui_set_mouse_wheel(float horizontal, float vertical);
void ember_ui_set_key(int imgui_key, int down);
void ember_ui_set_input_chars(const char* utf8);
int ember_ui_want_mouse(void);
int ember_ui_want_keyboard(void);
int ember_ui_want_text_input(void);

// ── Style ───────────────────────────────────────────────────────────────
// Set by NAME, not by `ImGuiStyleVar` index: those values live in named
// members of ImGuiStyle and the index-to-member mapping is private to
// imgui.cpp, so an index here would be a guess. Colours keep the index form
// because `ImGuiCol_` really is an array.
void* ember_ui_style(void);
void ember_ui_style_colors_dark(void);
float* ember_ui_style_col(int index); // -> ImVec4 (4 floats)
void ember_ui_style_set_color(int index, float r, float g, float b, float a);
void ember_ui_style_set_alpha(float v);
void ember_ui_style_set_font_size(float px);
void ember_ui_style_set_WindowPadding(float x, float y);
void ember_ui_style_set_WindowRounding(float v);
void ember_ui_style_set_WindowBorderSize(float v);
void ember_ui_style_set_ChildRounding(float v);
void ember_ui_style_set_ChildBorderSize(float v);
void ember_ui_style_set_PopupRounding(float v);
void ember_ui_style_set_PopupBorderSize(float v);
void ember_ui_style_set_FramePadding(float x, float y);
void ember_ui_style_set_FrameRounding(float v);
void ember_ui_style_set_FrameBorderSize(float v);
void ember_ui_style_set_ItemSpacing(float x, float y);
void ember_ui_style_set_ItemInnerSpacing(float x, float y);
void ember_ui_style_set_CellPadding(float x, float y);
void ember_ui_style_set_TouchExtraPadding(float x, float y);
void ember_ui_style_set_IndentSpacing(float v);
void ember_ui_style_set_ColumnsMinSpacing(float v);
void ember_ui_style_set_ScrollbarSize(float v);
void ember_ui_style_set_GrabMinSize(float v);
void ember_ui_style_set_GrabRounding(float v);
void ember_ui_style_set_TabRounding(float v);
void ember_ui_style_set_TabBorderSize(float v);
void ember_ui_style_set_AntiAliasedLines(float v);
void ember_ui_style_set_AntiAliasedLinesUseTex(float v);
void ember_ui_style_set_AntiAliasedFill(float v);
void ember_ui_style_set_CurveTessellationTol(float v);
void ember_ui_style_set_CircleTessellationMaxError(float v);
void ember_ui_scale_all_sizes(float scale);

// ── Fonts ───────────────────────────────────────────────────────────────
// Returns a handle (>= 0) or -1. Handles are stable for the process; pass
// them to ember_ui_push_font / ember_ui_set_font.
int ember_ui_load_font(const char* path, float size);
void* ember_ui_push_font(int handle);
void ember_ui_pop_font(void);
void ember_ui_set_font(int handle);
void* ember_ui_font_current(void);
void* ember_ui_font_default(void);
float ember_ui_font_measure(void *font, float size);

// ── Windows and layout ──────────────────────────────────────────────────
int ember_ui_begin(const char* name, int flags);
void ember_ui_end(void);
void ember_ui_set_next_window_pos(float x, float y, int cond);
void ember_ui_set_next_window_pos_center(float x, float y, int cond);
void ember_ui_set_next_window_size(float w, float h, int cond);
void ember_ui_set_next_window_bg_alpha(float alpha);
int ember_ui_begin_child(const char* id, float w, float h, int child_flags, int window_flags);
void ember_ui_end_child(void);
void ember_ui_set_next_item_width(float width);
void ember_ui_push_item_width(float width);
void ember_ui_get_cursor_pos(float* out_xy);
void ember_ui_set_cursor_pos(float x, float y);
void ember_ui_get_cursor_screen_pos(float* out_xy);
void ember_ui_get_content_region_avail(float* out_wh);
void ember_ui_get_item_rect_min(float* out_xy);
void ember_ui_get_item_rect_max(float* out_xy);
void ember_ui_dummy(float w, float h);
void ember_ui_spacing(void);
void ember_ui_same_line(float offset_from_start, float spacing);
void ember_ui_set_scroll_here_y(float center_y_ratio);
void ember_ui_indent(float width);
void ember_ui_unindent(float width);
void ember_ui_separator(void);
float ember_ui_frame_height(void);
float ember_ui_frame_height_with_spacing(void);
float ember_ui_text_line_height(void);
void ember_ui_item_spacing(float* out_xy);
void ember_ui_window_padding(float* out_xy);

// ── Stacks ──────────────────────────────────────────────────────────────
void ember_ui_push_id_str(const char* id);
void ember_ui_push_id_int(int id);
void ember_ui_push_id_ptr(const void* id);
void ember_ui_pop_id(void);
void ember_ui_push_style_color(int index, unsigned int col);
void ember_ui_push_style_color4(int index, float r, float g, float b, float a);
void ember_ui_pop_style_color(int count);
void ember_ui_push_style_var_f(int index, float value);
void ember_ui_push_style_var_v2(int index, float x, float y);
void ember_ui_push_style_var_x(int index, float x);
void ember_ui_push_style_var_y(int index, float y);
void ember_ui_pop_style_var(int count);
void ember_ui_push_item_flag(int flags);
void ember_ui_pop_item_flag(void);
unsigned int ember_ui_hash_str(const char* s);

// ── Widgets ─────────────────────────────────────────────────────────────
int ember_ui_button(const char* label, float w, float h);
int ember_ui_invisible_button(const char* str_id, float w, float h, int flags);
int ember_ui_checkbox(const char* label, int* value);
int ember_ui_radio_button(const char* label, int* value, int active);
int ember_ui_selectable(const char* label, int selected, int flags, float w, float h);
int ember_ui_input_text(const char* label, char* buf, unsigned int capacity, int flags);
int ember_ui_input_text_multiline(const char* label, char* buf, unsigned int capacity, const float* size, int flags);
int ember_ui_drag_float(const char* label, float* value, float speed, float vmin, float vmax, const char* fmt, int flags);
int ember_ui_drag_int(const char* label, int* value, float speed, int vmin, int vmax, int flags);
int ember_ui_drag_float2(const char* label, float* value, float speed, float vmin, float vmax, const char* fmt, int flags);
int ember_ui_slider_float(const char* label, float* value, float vmin, float vmax, const char* fmt, int flags);
int ember_ui_color_edit4(const char* label, float* rgba, int flags);
int ember_ui_begin_combo(const char* label, const char* preview, int flags);
void ember_ui_end_combo(void);
int ember_ui_collapsing_header(const char* label, int flags);
int ember_ui_tree_node(const char* label, int flags);
void ember_ui_tree_pop(void);
int ember_ui_begin_popup(const char* id, int flags);
void ember_ui_end_popup(void);
int ember_ui_open_popup(const char* id);
int ember_ui_begin_popup_modal(const char* id, int flags);
int ember_ui_is_popup_open(const char* id, int flags);
int ember_ui_begin_menu_bar(const char* name);
void ember_ui_end_menu_bar(void);
int ember_ui_begin_menu(const char* label, int enabled);
void ember_ui_end_menu(void);
int ember_ui_is_key_pressed(int key, int repeat);
void ember_ui_draw_stats(int* out);
int ember_ui_is_key_down(int key);
int ember_ui_is_mouse_double_clicked(int button);
int ember_ui_menu_item(const char* label, const char* shortcut, int* selected, int flags);
int ember_ui_begin_tooltip(void);
void ember_ui_end_tooltip(void);
void ember_ui_set_tooltip(const char* text);
int ember_ui_is_item_hovered(int flags);
int ember_ui_is_item_clicked(int button);
int ember_ui_is_item_active(void);
int ember_ui_is_item_deactivated_after_edit(void);
int ember_ui_is_item_focused(void);
int ember_ui_is_window_focused(int flags);
void ember_ui_set_window_focus(void);

// ── Drag & drop ───────────────────────────────────────────────────────────
// Signatures match the .cpp block: one ImGui call each, no state. The accept
// call returns the payload's bytes and writes its size; the bytes are valid
// only until the caller calls ember_ui_end_drag_drop_target, so a consumer
// copies them out immediately.
int ember_ui_is_mouse_dragging(int button, float lock_threshold);
int ember_ui_is_drag_drop_active(void);
int ember_ui_begin_drag_drop_source(int flags);
int ember_ui_set_drag_drop_payload(const char* type, const void* data, unsigned int size);
void ember_ui_end_drag_drop_source(void);
int ember_ui_begin_drag_drop_target(void);
const void* ember_ui_accept_drag_drop_payload(const char* type, int flags, unsigned int* out_size);
void ember_ui_end_drag_drop_target(void);
void ember_ui_text(const char* s);
void ember_ui_text_colored(unsigned int col, const char* s);
void ember_ui_text_wrapped(unsigned int col, const char* s);
void ember_ui_text_unformatted(const char* s);
void ember_ui_calc_text_size(const char* s, float* out_wh);
void ember_ui_calc_text_size_ws(const char* s, float wrap_width, float* out_wh);
double ember_ui_time(void);
long long ember_ui_frame_count(void);

// ── Draw lists ──────────────────────────────────────────────────────────
// The look. ImGui's stock widgets are what every ImGui program looks like;
// these primitives are how `/ui` draws its own rounded, hovered, focused,
// gradient-buttoned widgets instead.
void* ember_ui_get_item_draw_list(void);
void* ember_ui_get_window_draw_list(void);
void* ember_ui_get_foreground_draw_list(void);
void* ember_ui_get_background_draw_list(void);

void ember_draw_rect_filled(void* dl, float x0, float y0, float x1, float y1, unsigned int col, float rounding, int flags);
void ember_draw_rect(void* dl, float x0, float y0, float x1, float y1, unsigned int col, float rounding, float thickness, int flags);
void ember_draw_rect_filled_multi(void* dl, float x0, float y0, float x1, float y1, unsigned int c_tl, unsigned int c_tr, unsigned int c_br, unsigned int c_bl);
void ember_draw_circle_filled(void* dl, float cx, float cy, float radius, unsigned int col, int segments);
void ember_draw_circle(void* dl, float cx, float cy, float radius, unsigned int col, int segments, float thickness);
void ember_draw_line(void* dl, float x0, float y0, float x1, float y1, unsigned int col, float thickness);
void ember_draw_text(void* dl, void* font, float x, float y, unsigned int col, const char* s);
void ember_draw_path_arc(void* dl, float cx, float cy, float radius, float a0, float a1, int segments);
void ember_draw_path_line(void* dl, float x, float y);
void ember_draw_path_reset(void* dl);
void ember_draw_path_fill(void* dl, unsigned int col);
void ember_draw_path_stroke(void* dl, unsigned int col, float thickness, int flags);
void ember_draw_push_clip(void* dl, float x0, float y0, float x1, float y1, int intersect);
void ember_draw_pop_clip(void* dl);
int ember_draw_cmd_count(void* dl);

#ifdef __cplusplus
}
#endif

#endif // EMBER_UI_SHIM_H
