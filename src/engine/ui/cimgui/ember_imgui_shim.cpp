// ember_imgui_shim.cpp — the implementation of the C ABI in ember_imgui_shim.h.
//
// Read the header first: it explains why this file exists and what it is
// forbidden to contain. What follows is deliberately dumb — one ImGui call per
// extern function, no logic, no state beyond the font table.
//
// ImGui 1.92 (Docking), pinned in libs/imgui.tag. Two things about that
// version are worth knowing before editing anything below:
//
//   1. `PushFont` takes TWO arguments (`PushFont(NULL, 13.5f)`). The one-argument
//      form was removed in 1.92 on purpose: passing a scaled size used to apply
//      the DPI scale twice, which is a bug that looks like "the text is huge on
//      my monitor" and is not.
//   2. Fonts are baked lazily at whatever size they are used at, so one
//      `AddFontFromFileTTF(path, 16)` serves body text, captions and headings.
//
// The version check below exists so that bumping the pin turns into ONE clear
// compile error naming the APIs that changed, rather than a silent behaviour
// change discovered in a screenshot.

#include "ember_imgui_shim.h"

#include "imgui.h"
// The user-texture API (ImTextureData) lives in the internal header: it is
// still marked EXPERIMENTAL in 1.92, and it is the only way for an app to
// hand ImGui a texture of its own. The official backends include this header
// for the same reason.
#include "imgui_internal.h"

#if !defined(IMGUI_IMPL_WEBGPU_BACKEND_DAWN)
#error "IMGUI_IMPL_WEBGPU_BACKEND_DAWN must be defined: the engine renders with Dawn, and imgui_impl_wgpu needs to be told which WebGPU implementation it is talking to."
#endif
#include "imgui_impl_wgpu.h"

// The engine's own header wins over the pin file: if somebody moves the pin and
// gets a version whose flag name changed, this fails at the include below
// instead of deep inside the backend.
#ifndef EMBER_IMGUI_VERSION_CHECK
#define EMBER_IMGUI_VERSION_CHECK(major, minor, patch) \
    ((major) < 1 || ((major) == 1 && (minor) < 92) || ((major) == 1 && (minor) == 92 && (patch) < 9))
#endif
#if EMBER_IMGUI_VERSION_CHECK(IMGUI_VERSION_NUM / 10000, (IMGUI_VERSION_NUM % 10000) / 100, IMGUI_VERSION_NUM % 100)
#error "This shim targets Dear ImGui 1.92.9+ (see libs/imgui.tag). Bumping ImGui means re-reading imgui.h: PushFont, TreeNode and CalcTextSize all changed in the 1.91-1.92 window."
#endif

#include <vector>

namespace {

// Fonts are addressed from Zig by an integer handle, because an ImFont* is a
// C++ type that would otherwise leak into every widget signature. The table is
// append-only and never freed until shutdown, so a handle stays valid for the
// life of the process.
std::vector<ImFont*>& font_table() {
    static std::vector<ImFont*> fonts;
    return fonts;
}

int register_font(ImFont* f) {
    if (f == nullptr)
        return -1;
    font_table().push_back(f);
    return (int)font_table().size() - 1;
}

ImFont* font_by_handle(int handle) {
    if (handle < 0 || (size_t)handle >= font_table().size())
        return nullptr;
    return font_table()[(size_t)handle];
}

} // namespace

// ── Context lifecycle ───────────────────────────────────────────────────

extern "C" int ember_ui_create(void) {
    IMGUI_CHECKVERSION();
    ImGuiContext* ctx = ImGui::CreateContext();
    if (ctx == nullptr)
        return 0;
    ImGui::StyleColorsDark();
    // Docking is opt-in at RUNTIME as well as compile time (IMGUI_ENABLE_DOCKING
    // in imconfig). Both have to be on for the editor to dock its panels.
    ImGuiIO& io = ImGui::GetIO();
    io.IniFilename = nullptr;
    io.ConfigFlags |= ImGuiConfigFlags_DockingEnable;
    return 1;
}

extern "C" void ember_ui_destroy(void) {
    ImGui::DestroyContext();
    font_table().clear();
}

extern "C" void ember_ui_set_config_flags(unsigned int flags) {
    ImGui::GetIO().ConfigFlags = (ImGuiConfigFlags)flags;
}

extern "C" unsigned int ember_ui_get_config_flags(void) {
    return (unsigned int)ImGui::GetIO().ConfigFlags;
}

extern "C" void ember_ui_set_ini_filename(const char* path) {
    // ImGui's own allocator: the string is freed by the context at shutdown,
    // and a std::string here would be freed by something else entirely.
    void* previous = (void*)ImGui::GetIO().IniFilename;
    ImGui::GetIO().IniFilename = nullptr;
    ImGui::MemFree(previous);
    if (path != nullptr) {
        size_t n = strlen(path);
        char* owned = (char*)ImGui::MemAlloc(n + 1);
        memcpy(owned, path, n + 1);
        ImGui::GetIO().IniFilename = owned;
    }
}

extern "C" int ember_ui_get_font_loaded(void) {
    // 1 when a real typeface made it into the atlas, 0 when the editor is
    // running on ProggyClean. Worth reporting: "the UI looks like a DOS
    // screenshot" is almost always this returning 0, not a style bug.
    return font_table().empty() ? 0 : 1;
}

// ── Renderer (WebGPU / Dawn) ────────────────────────────────────────────

extern "C" int ember_ui_init_renderer(void* device, unsigned int format, int frames_in_flight) {
    if (device == nullptr)
        return 0;
    ImGui_ImplWGPU_InitInfo info;
    info.Device = (WGPUDevice)device;
    info.NumFramesInFlight = frames_in_flight > 0 ? frames_in_flight : 3;
    info.RenderTargetFormat = (WGPUTextureFormat)format;
    // The editor draws UI into the same pass the swapchain resolves into, which
    // has no depth attachment. Asking for one would make ImGui create a pipeline
    // layout that does not match the pass we hand it — a validation error on
    // every frame, not a crash, which is the worst kind.
    info.DepthStencilFormat = WGPUTextureFormat_Undefined;
    return ImGui_ImplWGPU_Init(&info) ? 1 : 0;
}

extern "C" void ember_ui_shutdown_renderer(void) {
    ImGui_ImplWGPU_Shutdown();
}

extern "C" void ember_ui_new_frame(float delta_time) {
    ImGuiIO& io = ImGui::GetIO();
    io.DeltaTime = delta_time > 0.0f ? delta_time : 1.0f / 60.0f;
    ImGui_ImplWGPU_NewFrame();
    ImGui::NewFrame();
}

extern "C" void ember_ui_render(void) {
    ImGui::Render();
}

extern "C" void ember_ui_render_draw_data(void* render_pass_encoder) {
    ImDrawData* draw_data = ImGui::GetDrawData();
    if (draw_data == nullptr || render_pass_encoder == nullptr)
        return;
    ImGui_ImplWGPU_RenderDrawData(draw_data, (WGPURenderPassEncoder)render_pass_encoder);
}

// ── Platform input ──────────────────────────────────────────────────────

extern "C" void ember_ui_set_display_size(float w, float h) {
    ImGuiIO& io = ImGui::GetIO();
    io.DisplaySize = ImVec2(w, h);
    // FramebufferScale is what ImGui multiplies DisplaySize by to get the
    // pixels a draw command actually lands on. Leaving it at 1 while the
    // window is on a HiDPI monitor draws the whole UI at half size in the
    // corner of the screen — the single most common "my UI is tiny" bug.
    io.DisplayFramebufferScale = ImVec2(1.0f, 1.0f);
}

extern "C" void ember_ui_set_focus(int focused) {
    ImGui::GetIO().AddFocusEvent(focused != 0);
}

extern "C" void ember_ui_set_mouse_pos(float x, float y) {
    ImGui::GetIO().AddMousePosEvent(x, y);
}

extern "C" void ember_ui_set_mouse_button(int button, int down) {
    ImGui::GetIO().AddMouseButtonEvent((ImGuiMouseButton)button, down != 0);
}

extern "C" void ember_ui_set_mouse_wheel(float horizontal, float vertical) {
    ImGui::GetIO().AddMouseWheelEvent(horizontal, vertical);
}

extern "C" void ember_ui_set_key(int imgui_key, int down) {
    ImGui::GetIO().AddKeyEvent((ImGuiKey)imgui_key, down != 0);
}

extern "C" void ember_ui_set_input_chars(const char* utf8) {
    if (utf8 != nullptr && utf8[0] != '\0')
        ImGui::GetIO().AddInputCharactersUTF8(utf8);
}

extern "C" int ember_ui_want_mouse(void) {
    return ImGui::GetIO().WantCaptureMouse ? 1 : 0;
}

extern "C" int ember_ui_want_keyboard(void) {
    return ImGui::GetIO().WantCaptureKeyboard ? 1 : 0;
}

extern "C" int ember_ui_want_text_input(void) {
    return ImGui::GetIO().WantTextInput ? 1 : 0;
}

// ── Style ───────────────────────────────────────────────────────────────

extern "C" void* ember_ui_style(void) {
    return &ImGui::GetStyle();
}

extern "C" void ember_ui_style_colors_dark(void) {
    ImGui::StyleColorsDark();
}

extern "C" float* ember_ui_style_col(int index) {
    // Colors[] is a real array member, so handing out a pointer into it is safe
    // and stays valid for the life of the context.
    ImVec4* col = &ImGui::GetStyle().Colors[index];
    return &col->x;
}

// ── Style, by name ──────────────────────────────────────────────────────
//
// NOT by `ImGuiStyleVar` index. That enum is a flat list whose values live in
// named members of ImGuiStyle (FramePadding, ItemSpacing, GrabRounding, ...),
// and the index-to-member correspondence lives inside imgui.cpp, not in the
// header. Exposing an index would mean the shim carrying that mapping, or
// Zig guessing it — and a guess that is off by one silently rounds the wrong
// corner on every frame. So the theme asks for what it wants by name:
//
//     ember_ui_style_set_frame_padding(10, 6)
//
// which is longer and impossible to get wrong. The colours keep the index form
// because ImGuiCol_ IS a real array and the Zig side mirrors the enum.
#define EMBER_STYLE_SCALAR(field)                                       \
    extern "C" void ember_ui_style_set_##field(float v) {               \
        ImGui::GetStyle().field = v;                                    \
    }
#define EMBER_STYLE_VEC2(field)                                         \
    extern "C" void ember_ui_style_set_##field(float x, float y) {      \
        ImGui::GetStyle().field = ImVec2(x, y);                         \
    }

extern "C" void ember_ui_style_set_alpha(float v) { ImGui::GetStyle().Alpha = v; }
EMBER_STYLE_VEC2(WindowPadding)
EMBER_STYLE_SCALAR(WindowRounding)
EMBER_STYLE_SCALAR(WindowBorderSize)
EMBER_STYLE_SCALAR(ChildRounding)
EMBER_STYLE_SCALAR(ChildBorderSize)
EMBER_STYLE_SCALAR(PopupRounding)
EMBER_STYLE_SCALAR(PopupBorderSize)
EMBER_STYLE_VEC2(FramePadding)
EMBER_STYLE_SCALAR(FrameRounding)
EMBER_STYLE_SCALAR(FrameBorderSize)
EMBER_STYLE_VEC2(ItemSpacing)
EMBER_STYLE_VEC2(ItemInnerSpacing)
EMBER_STYLE_VEC2(CellPadding)
EMBER_STYLE_VEC2(TouchExtraPadding)
EMBER_STYLE_SCALAR(IndentSpacing)
EMBER_STYLE_SCALAR(ColumnsMinSpacing)
EMBER_STYLE_SCALAR(ScrollbarSize)
EMBER_STYLE_SCALAR(GrabMinSize)
EMBER_STYLE_SCALAR(GrabRounding)
EMBER_STYLE_SCALAR(TabRounding)
EMBER_STYLE_SCALAR(TabBorderSize)
EMBER_STYLE_SCALAR(AntiAliasedLines)
EMBER_STYLE_SCALAR(AntiAliasedLinesUseTex)
EMBER_STYLE_SCALAR(AntiAliasedFill)
EMBER_STYLE_SCALAR(CurveTessellationTol)
EMBER_STYLE_SCALAR(CircleTessellationMaxError)

#undef EMBER_STYLE_SCALAR
#undef EMBER_STYLE_VEC2

extern "C" void ember_ui_style_set_color(int index, float r, float g, float b, float a) {
    ImGui::GetStyle().Colors[index] = ImVec4(r, g, b, a);
}

extern "C" void ember_ui_style_set_font_size(float px) {
    ImGui::GetStyle().FontSizeBase = px;
}

extern "C" void ember_ui_scale_all_sizes(float scale) {
    ImGui::GetStyle().ScaleAllSizes(scale);
}

// ── Fonts ───────────────────────────────────────────────────────────────

extern "C" int ember_ui_load_font(const char* path, float size) {
    if (path == nullptr)
        return -1;
    ImFont* f = ImGui::GetIO().Fonts->AddFontFromFileTTF(path, size);
    return register_font(f);
}

extern "C" void* ember_ui_push_font(int handle) {
    ImFont* previous = ImGui::GetFont();
    ImGui::PushFont(font_by_handle(handle), 0.0f);
    return previous;
}

extern "C" void ember_ui_pop_font(void) {
    ImGui::PopFont();
}

extern "C" void ember_ui_set_font(int handle) {
    ImFont* f = font_by_handle(handle);
    ImGui::PushFont(f, 0.0f);
    ImGui::PopFont();
}

extern "C" void* ember_ui_font_current(void) {
    return ImGui::GetFont();
}

extern "C" void* ember_ui_font_default(void) {
    // Fonts[0] is whatever was added first, which is what ImGui binds at
    // NewFrame when nothing is pushed. This is the escape hatch for
    // "render this one label in the engine's default font".
    ImFontAtlas* atlas = ImGui::GetIO().Fonts;
    if (atlas == nullptr || atlas->Fonts.empty())
        return nullptr;
    return atlas->Fonts[0];
}

extern "C" float ember_ui_font_measure(void* font, float size) {
    ImFont* f = (font != nullptr) ? (ImFont*)font : ImGui::GetFont();
    if (f == nullptr)
        return ImGui::CalcTextSize("W").x;
    return f->CalcTextSizeA(size, FLT_MAX, 0.0f, "W").x;
}

// ── Windows and layout ──────────────────────────────────────────────────

extern "C" int ember_ui_begin(const char* name, int flags) {
    return ImGui::Begin(name, nullptr, (ImGuiWindowFlags)flags) ? 1 : 0;
}

extern "C" void ember_ui_end(void) {
    ImGui::End();
}

extern "C" void ember_ui_set_next_window_pos(float x, float y, int cond) {
    ImGui::SetNextWindowPos(ImVec2(x, y), (ImGuiCond)cond);
}

extern "C" void ember_ui_set_next_window_pos_center(float x, float y, int cond) {
    ImGui::SetNextWindowPos(ImVec2(x, y), (ImGuiCond)cond, ImVec2(0.5f, 0.5f));
}

extern "C" void ember_ui_set_next_window_size(float w, float h, int cond) {
    ImGui::SetNextWindowSize(ImVec2(w, h), (ImGuiCond)cond);
}

extern "C" void ember_ui_set_next_window_bg_alpha(float alpha) {
    ImGui::SetNextWindowBgAlpha(alpha);
}

extern "C" int ember_ui_begin_child(const char* id, float w, float h, int child_flags, int window_flags) {
    return ImGui::BeginChild(id, ImVec2(w, h), (ImGuiChildFlags)child_flags, (ImGuiWindowFlags)window_flags) ? 1 : 0;
}

extern "C" void ember_ui_end_child(void) {
    ImGui::EndChild();
}

extern "C" void ember_ui_set_next_item_width(float width) {
    ImGui::SetNextItemWidth(width);
}

// 1.92's PushItemWidth returns void (it used to return the previous width).
// Nobody in /ui needs the old value: layout code that wants it saves it from
// `theme.metrics.item_width`, which is the number it would have restored.
extern "C" void ember_ui_push_item_width(float width) {
    ImGui::PushItemWidth(width);
}

extern "C" void ember_ui_get_cursor_pos(float* out_xy) {
    ImVec2 p = ImGui::GetCursorPos();
    out_xy[0] = p.x;
    out_xy[1] = p.y;
}

extern "C" void ember_ui_set_cursor_pos(float x, float y) {
    ImGui::SetCursorPos(ImVec2(x, y));
}

extern "C" void ember_ui_get_cursor_screen_pos(float* out_xy) {
    ImVec2 p = ImGui::GetCursorScreenPos();
    out_xy[0] = p.x;
    out_xy[1] = p.y;
}

// The CURRENT window's position, in screen pixels.
//
// It exists for one reason: a floating tool that belongs to a region has to
// know whether the USER moved it. The shell places the tool at the region's
// edge every frame, and stops the moment the window's position is not the
// one it put there — which is the only way to tell "the user dragged this"
// from "the layout changed".
extern "C" void ember_ui_get_window_pos(float* out_xy) {
    ImVec2 p = ImGui::GetWindowPos();
    out_xy[0] = p.x;
    out_xy[1] = p.y;
}

extern "C" void ember_ui_get_content_region_avail(float* out_wh) {
    ImVec2 a = ImGui::GetContentRegionAvail();
    out_wh[0] = a.x;
    out_wh[1] = a.y;
}

extern "C" void ember_ui_get_item_rect_min(float* out_xy) {
    ImVec2 p = ImGui::GetItemRectMin();
    out_xy[0] = p.x;
    out_xy[1] = p.y;
}

extern "C" void ember_ui_get_item_rect_max(float* out_xy) {
    ImVec2 p = ImGui::GetItemRectMax();
    out_xy[0] = p.x;
    out_xy[1] = p.y;
}

extern "C" void ember_ui_dummy(float w, float h) {
    ImGui::Dummy(ImVec2(w, h));
}

extern "C" void ember_ui_spacing(void) {
    ImGui::Spacing();
}

extern "C" void ember_ui_same_line(float offset_from_start, float spacing) {
    ImGui::SameLine(offset_from_start, spacing);
}

extern "C" void ember_ui_set_scroll_here_y(float center_y_ratio) {
    ImGui::SetScrollHereY(center_y_ratio);
}

extern "C" void ember_ui_indent(float width) {
    ImGui::Indent(width);
}

extern "C" void ember_ui_unindent(float width) {
    ImGui::Unindent(width);
}

extern "C" void ember_ui_separator(void) {
    ImGui::Separator();
}

extern "C" float ember_ui_frame_height(void) {
    return ImGui::GetFrameHeight();
}

extern "C" float ember_ui_frame_height_with_spacing(void) {
    return ImGui::GetFrameHeightWithSpacing();
}

extern "C" float ember_ui_text_line_height(void) {
    return ImGui::GetTextLineHeight();
}

extern "C" void ember_ui_item_spacing(float* out_xy) {
    ImVec2 s = ImGui::GetStyle().ItemSpacing;
    out_xy[0] = s.x;
    out_xy[1] = s.y;
}

extern "C" void ember_ui_window_padding(float* out_xy) {
    ImVec2 s = ImGui::GetStyle().WindowPadding;
    out_xy[0] = s.x;
    out_xy[1] = s.y;
}

// ── Stacks ──────────────────────────────────────────────────────────────

extern "C" void ember_ui_push_id_str(const char* id) {
    ImGui::PushID(id);
}

extern "C" void ember_ui_push_id_int(int id) {
    ImGui::PushID(id);
}

extern "C" void ember_ui_push_id_ptr(const void* id) {
    ImGui::PushID(id);
}

extern "C" void ember_ui_pop_id(void) {
    ImGui::PopID();
}

extern "C" void ember_ui_push_style_color(int index, unsigned int col) {
    ImGui::PushStyleColor(index, col);
}

extern "C" void ember_ui_push_style_color4(int index, float r, float g, float b, float a) {
    ImGui::PushStyleColor(index, ImVec4(r, g, b, a));
}

extern "C" void ember_ui_pop_style_color(int count) {
    ImGui::PopStyleColor(count);
}

extern "C" void ember_ui_push_style_var_f(int index, float value) {
    ImGui::PushStyleVar(index, value);
}

extern "C" void ember_ui_push_style_var_v2(int index, float x, float y) {
    ImGui::PushStyleVar(index, ImVec2(x, y));
}

// There is no `PushStyleVar(idx, x, y, z)` in 1.92: the overloads are scalar,
// ImVec2, and the per-axis PushStyleVarX/Y. Components are pushed one at a
// time; the shim takes them separately for the same reason it does everywhere
// else — an ImVec3 typedef would not survive the C ABI anyway.
extern "C" void ember_ui_push_style_var_x(int index, float x) {
    ImGui::PushStyleVarX(index, x);
}

extern "C" void ember_ui_push_style_var_y(int index, float y) {
    ImGui::PushStyleVarY(index, y);
}

extern "C" void ember_ui_pop_style_var(int count) {
    ImGui::PopStyleVar(count);
}

extern "C" void ember_ui_push_item_flag(int flags) {
    ImGui::PushItemFlag((ImGuiItemFlags)flags, true);
}

extern "C" void ember_ui_pop_item_flag(void) {
    // 1.92 takes no count here (it takes none in PopStyleColor either when
    // defaulted, but the count form survives).
    ImGui::PopItemFlag();
}

extern "C" unsigned int ember_ui_hash_str(const char* s) {
    return (unsigned int)ImGui::GetID(s);
}

// ── Widgets ─────────────────────────────────────────────────────────────

extern "C" int ember_ui_button(const char* label, float w, float h) {
    // ImGui 1.92's Button() has no flags parameter; the flags-bearing variant
    // is InvisibleButton(), which is also what every widget in /ui that draws
    // itself uses (see `invisible_button` below).
    return ImGui::Button(label, ImVec2(w, h)) ? 1 : 0;
}

// The workhorse of a custom widget: reserves the item, takes the click, and
// leaves the drawing entirely to us. A rounded, gradient, animated button is
// `invisible_button()` for the interaction plus three draw-list calls, which is
// why /ui can look like a 2026 design system while still being immediate-mode.
extern "C" int ember_ui_invisible_button(const char* str_id, float w, float h, int flags) {
    return ImGui::InvisibleButton(str_id, ImVec2(w, h), (ImGuiButtonFlags)flags) ? 1 : 0;
}

extern "C" int ember_ui_checkbox(const char* label, int* value) {
    bool v = *value != 0;
    if (ImGui::Checkbox(label, &v))
        *value = v ? 1 : 0;
    return *value;
}

extern "C" int ember_ui_radio_button(const char* label, int* value, int active) {
    // The int* overload is the one that exists in 1.92; the (bool*, bool)
    // overload was removed along with a dozen other transitional signatures.
    if (ImGui::RadioButton(label, value, active))
        return *value;
    return *value;
}

extern "C" int ember_ui_selectable(const char* label, int selected, int flags, float w, float h) {
    return ImGui::Selectable(label, selected != 0, (ImGuiSelectableFlags)flags, ImVec2(w, h)) ? 1 : 0;
}

extern "C" int ember_ui_input_text(const char* label, char* buf, unsigned int capacity, int flags) {
    return ImGui::InputText(label, buf, (size_t)capacity, (ImGuiInputTextFlags)flags) ? 1 : 0;
}

extern "C" int ember_ui_input_text_multiline(const char* label, char* buf, unsigned int capacity, const float* size, int flags) {
    ImVec2 s(size[0], size[1]);
    return ImGui::InputTextMultiline(label, buf, (size_t)capacity, s, (ImGuiInputTextFlags)flags) ? 1 : 0;
}

extern "C" int ember_ui_drag_float(const char* label, float* value, float speed, float vmin, float vmax, const char* fmt, int flags) {
    return ImGui::DragFloat(label, value, speed, vmin, vmax, fmt, (ImGuiSliderFlags)flags) ? 1 : 0;
}

extern "C" int ember_ui_drag_int(const char* label, int* value, float speed, int vmin, int vmax, int flags) {
    return ImGui::DragInt(label, value, speed, vmin, vmax, "%d", (ImGuiSliderFlags)flags) ? 1 : 0;
}

extern "C" int ember_ui_drag_float2(const char* label, float* value, float speed, float vmin, float vmax, const char* fmt, int flags) {
    return ImGui::DragFloat2(label, value, speed, vmin, vmax, fmt, (ImGuiSliderFlags)flags) ? 1 : 0;
}

extern "C" int ember_ui_slider_float(const char* label, float* value, float vmin, float vmax, const char* fmt, int flags) {
    return ImGui::SliderFloat(label, value, vmin, vmax, fmt, (ImGuiSliderFlags)flags) ? 1 : 0;
}

extern "C" int ember_ui_color_edit4(const char* label, float* rgba, int flags) {
    return ImGui::ColorEdit4(label, rgba, (ImGuiColorEditFlags)flags) ? 1 : 0;
}

extern "C" int ember_ui_begin_combo(const char* label, const char* preview, int flags) {
    return ImGui::BeginCombo(label, preview, (ImGuiComboFlags)flags) ? 1 : 0;
}

extern "C" void ember_ui_end_combo(void) {
    ImGui::EndCombo();
}

extern "C" int ember_ui_collapsing_header(const char* label, int flags) {
    return ImGui::CollapsingHeader(label, (ImGuiTreeNodeFlags)flags) ? 1 : 0;
}

extern "C" int ember_ui_tree_node(const char* label, int flags) {
    return ImGui::TreeNodeEx(label, (ImGuiTreeNodeFlags)flags) ? 1 : 0;
}

extern "C" void ember_ui_tree_pop(void) {
    ImGui::TreePop();
}

extern "C" int ember_ui_begin_popup(const char* id, int flags) {
    return ImGui::BeginPopup(id, (ImGuiPopupFlags)flags) ? 1 : 0;
}

extern "C" void ember_ui_end_popup(void) {
    ImGui::EndPopup();
}

extern "C" int ember_ui_open_popup(const char* id) {
    ImGui::OpenPopup(id);
    return 1;
}

extern "C" int ember_ui_begin_popup_modal(const char* id, int flags) {
    return ImGui::BeginPopupModal(id, nullptr, (ImGuiWindowFlags)flags) ? 1 : 0;
}

extern "C" int ember_ui_is_popup_open(const char* id, int flags) {
    return ImGui::IsPopupOpen(id, (ImGuiPopupFlags)flags) ? 1 : 0;
}

extern "C" int ember_ui_begin_menu_bar(const char* name) {
    return ImGui::BeginMenuBar() ? 1 : 0;
}

extern "C" void ember_ui_end_menu_bar(void) {
    ImGui::EndMenuBar();
}

extern "C" int ember_ui_begin_menu(const char* label, int enabled) {
    return ImGui::BeginMenu(label, enabled != 0) ? 1 : 0;
}

extern "C" void ember_ui_end_menu(void) {
    ImGui::EndMenu();
}

extern "C" int ember_ui_is_key_pressed(int key, int repeat) {
    return ImGui::IsKeyPressed((ImGuiKey)key, repeat != 0) ? 1 : 0;
}

// The size of the frame ImGui just rendered: draw lists, vertices, indices.
// Read after `ImGui::Render()`, which `ember_ui_render` calls. A frame of
// geometry with zero vertices is the difference between "the UI drew" and "the
// UI's draw list was empty", and no log line can tell them apart otherwise.
extern "C" void ember_ui_draw_stats(int* out) {
    ImDrawData* dd = ImGui::GetDrawData();
    out[0] = dd ? dd->CmdListsCount : 0;
    out[1] = dd ? dd->TotalVtxCount : 0;
    out[2] = dd ? dd->TotalIdxCount : 0;
}

extern "C" int ember_ui_is_key_down(int key) {
    return ImGui::IsKeyDown((ImGuiKey)key) ? 1 : 0;
}

// A double click, asked of the ITEM the caller just submitted (ImGui tracks the
// hovered item), not of the mouse in the abstract. `widget.submit` uses
// InvisibleButton, which has no activation signal of its own — this is what
// makes a hierarchy row's double-click mean something.
extern "C" int ember_ui_is_mouse_double_clicked(int button) {
    return ImGui::IsMouseDoubleClicked((ImGuiMouseButton)button) ? 1 : 0;
}

// Bit 0 of `flags` is "disabled" (see `MenuItemFlags` in cimgui.zig). The
// previous version accepted the flag and then ignored it, which made every
// greyed-out menu entry in the editor a lie: it looked enabled because it was.
extern "C" int ember_ui_menu_item(const char* label, const char* shortcut, int* selected, int flags) {
    bool sel = selected != nullptr && *selected != 0;
    const bool disabled = (flags & 1) != 0;
    if (disabled) ImGui::BeginDisabled();
    bool clicked = ImGui::MenuItem(label, shortcut, sel);
    if (disabled) ImGui::EndDisabled();
    if (clicked && !disabled && selected != nullptr)
        *selected = sel ? 0 : 1;
    return (clicked && !disabled) ? 1 : 0;
}

extern "C" int ember_ui_begin_tooltip(void) {
    return ImGui::BeginTooltip() ? 1 : 0;
}

extern "C" void ember_ui_end_tooltip(void) {
    ImGui::EndTooltip();
}

extern "C" void ember_ui_set_tooltip(const char* text) {
    ImGui::SetTooltip("%s", text);
}

extern "C" int ember_ui_is_item_hovered(int flags) {
    return ImGui::IsItemHovered((ImGuiHoveredFlags)flags) ? 1 : 0;
}

extern "C" int ember_ui_is_item_clicked(int button) {
    return ImGui::IsItemClicked((ImGuiMouseButton)button) ? 1 : 0;
}

extern "C" int ember_ui_is_item_active(void) {
    return ImGui::IsItemActive() ? 1 : 0;
}

extern "C" int ember_ui_is_mouse_dragging(int button, float lock_threshold) {
    return ImGui::IsMouseDragging((ImGuiMouseButton)button, lock_threshold) ? 1 : 0;
}

// ── Drag & drop ──────────────────────────────────────────────────────────────
// The public half of ImGui's DragDrop API. Rows become sources (SetDragDrop-
// Payload carries the row's data) and targets (AcceptDragDropPayload hands the
// caller the bytes; those are valid ONLY between BeginDragDropTarget and
// EndDragDropTarget, so the Zig side copies them out before returning).

extern "C" int ember_ui_is_drag_drop_active(void) {
    // GetDragDropPayload() is null whenever no drag is in flight, which is the
    // active test a shim may ask without dragging imgui_internal.h in.
    return ImGui::GetDragDropPayload() != nullptr ? 1 : 0;
}

extern "C" int ember_ui_begin_drag_drop_source(int flags) {
    return ImGui::BeginDragDropSource((ImGuiDragDropFlags)flags) ? 1 : 0;
}

extern "C" int ember_ui_set_drag_drop_payload(const char* type, const void* data, unsigned int size) {
    return ImGui::SetDragDropPayload(type, data, size, ImGuiCond_Always) ? 1 : 0;
}

extern "C" void ember_ui_end_drag_drop_source(void) {
    ImGui::EndDragDropSource();
}

extern "C" int ember_ui_begin_drag_drop_target(void) {
    return ImGui::BeginDragDropTarget() ? 1 : 0;
}

extern "C" const void* ember_ui_accept_drag_drop_payload(const char* type, int flags, unsigned int* out_size) {
    const ImGuiPayload* payload = ImGui::AcceptDragDropPayload(type, (ImGuiDragDropFlags)flags);
    if (payload == nullptr) return nullptr;
    if (out_size != nullptr) *out_size = payload->DataSize;
    return payload->Data;
}

extern "C" void ember_ui_end_drag_drop_target(void) {
    ImGui::EndDragDropTarget();
}

extern "C" int ember_ui_is_item_deactivated_after_edit(void) {
    return ImGui::IsItemDeactivatedAfterEdit() ? 1 : 0;
}

extern "C" int ember_ui_is_item_focused(void) {
    return ImGui::IsItemFocused() ? 1 : 0;
}

extern "C" int ember_ui_is_window_focused(int flags) {
    return ImGui::IsWindowFocused((ImGuiFocusedFlags)flags) ? 1 : 0;
}

extern "C" void ember_ui_set_window_focus(void) {
    ImGui::SetWindowFocus();
}

extern "C" void ember_ui_text(const char* s) {
    ImGui::TextUnformatted(s);
}

extern "C" void ember_ui_text_colored(unsigned int col, const char* s) {
    ImGui::PushStyleColor(ImGuiCol_Text, col);
    ImGui::TextUnformatted(s);
    ImGui::PopStyleColor();
}

extern "C" void ember_ui_text_wrapped(unsigned int col, const char* s) {
    ImGui::PushStyleColor(ImGuiCol_Text, col);
    ImGui::TextWrapped("%s", s);
    ImGui::PopStyleColor();
}

extern "C" void ember_ui_text_unformatted(const char* s) {
    ImGui::TextUnformatted(s);
}

extern "C" void ember_ui_calc_text_size(const char* s, float* out_wh) {
    ImVec2 size = ImGui::CalcTextSize(s);
    out_wh[0] = size.x;
    out_wh[1] = size.y;
}

extern "C" void ember_ui_calc_text_size_ws(const char* s, float wrap_width, float* out_wh) {
    ImVec2 size = ImGui::CalcTextSize(s, nullptr, false, wrap_width);
    out_wh[0] = size.x;
    out_wh[1] = size.y;
}

extern "C" double ember_ui_time(void) {
    return ImGui::GetTime();
}

extern "C" long long ember_ui_frame_count(void) {
    return (long long)ImGui::GetFrameCount();
}

// ── Draw lists ──────────────────────────────────────────────────────────

// 1.92 removed `GetItemDrawList()`. `GetWindowDrawList()` replaces it for
// every use /ui has: a custom widget reserves its item with
// `invisible_button`, reads the rect with `get_item_rect_min/max`, and draws
// on the window draw list in the SAME coordinate space (both window-local), so
// submission order puts the drawing exactly on the item it belongs to.
extern "C" void* ember_ui_get_item_draw_list(void) {
    return ImGui::GetWindowDrawList();
}

extern "C" void* ember_ui_get_window_draw_list(void) {
    return ImGui::GetWindowDrawList();
}

extern "C" void* ember_ui_get_foreground_draw_list(void) {
    return ImGui::GetForegroundDrawList();
}

extern "C" void* ember_ui_get_background_draw_list(void) {
    return ImGui::GetBackgroundDrawList();
}

extern "C" void ember_draw_rect_filled(void* dl, float x0, float y0, float x1, float y1, unsigned int col, float rounding, int flags) {
    ((ImDrawList*)dl)->AddRectFilled(ImVec2(x0, y0), ImVec2(x1, y1), col, rounding, (ImDrawFlags)flags);
}

extern "C" void ember_draw_rect(void* dl, float x0, float y0, float x1, float y1, unsigned int col, float rounding, float thickness, int flags) {
    ((ImDrawList*)dl)->AddRect(ImVec2(x0, y0), ImVec2(x1, y1), col, rounding, thickness, (ImDrawFlags)flags);
}

extern "C" void ember_draw_rect_filled_multi(void* dl, float x0, float y0, float x1, float y1, unsigned int c_tl, unsigned int c_tr, unsigned int c_br, unsigned int c_bl) {
    ((ImDrawList*)dl)->AddRectFilledMultiColor(ImVec2(x0, y0), ImVec2(x1, y1), c_tl, c_tr, c_br, c_bl);
}

extern "C" void ember_draw_circle_filled(void* dl, float cx, float cy, float radius, unsigned int col, int segments) {
    ((ImDrawList*)dl)->AddCircleFilled(ImVec2(cx, cy), radius, col, segments);
}

extern "C" void ember_draw_image(
    void* dl,
    void* texture,
    float x0,
    float y0,
    float x1,
    float y1,
    float u0,
    float v0,
    float u1,
    float v1,
    unsigned int col) {
    // The texture is an ImTextureData the app owns: ImGui uploads it to the
    // GPU on the next render and hands the backend its identifier. That is
    // the whole reason the UI layer can have a texture of its own without
    // knowing what a graphics API is.
    ImTextureRef ref;
    ref._TexData = (ImTextureData*)texture;
    ((ImDrawList*)dl)->AddImage(
        ref,
        ImVec2(x0, y0),
        ImVec2(x1, y1),
        ImVec2(u0, v0),
        ImVec2(u1, v1),
        col);
}

extern "C" void* ember_ui_texture_create(int w, int h, const unsigned char* rgba) {
    ImTextureData* tex = new ImTextureData();
    tex->Create(ImTextureFormat_RGBA32, w, h);
    if (tex->Pixels != nullptr)
        memcpy(tex->Pixels, rgba, (size_t)w * (size_t)h * 4);
    tex->SetStatus(ImTextureStatus_WantCreate);
    ImGui::RegisterUserTexture(tex);
    return tex;
}

extern "C" void ember_ui_texture_destroy(void* texture) {
    ImTextureData* tex = (ImTextureData*)texture;
    if (tex == nullptr)
        return;
    ImGui::UnregisterUserTexture(tex);
    // The GPU side is released by the backend once the texture has been
    // unused for a frame; the ImTextureData itself is the app's, and ImGui
    // no longer references it once it is unregistered.
    tex->SetStatus(ImTextureStatus_WantDestroy);
    delete tex;
}

extern "C" void ember_draw_circle(void* dl, float cx, float cy, float radius, unsigned int col, int segments, float thickness) {
    ((ImDrawList*)dl)->AddCircle(ImVec2(cx, cy), radius, col, segments, thickness);
}

extern "C" void ember_draw_line(void* dl, float x0, float y0, float x1, float y1, unsigned int col, float thickness) {
    ((ImDrawList*)dl)->AddLine(ImVec2(x0, y0), ImVec2(x1, y1), col, thickness);
}

extern "C" void ember_draw_text(void* dl, void* font, float x, float y, unsigned int col, const char* s) {
    ImFont* f = (font != nullptr) ? (ImFont*)font : ImGui::GetFont();
    ((ImDrawList*)dl)->AddText(f, ImGui::GetFontSize(), ImVec2(x, y), col, s);
}

extern "C" void ember_draw_path_arc(void* dl, float cx, float cy, float radius, float a0, float a1, int segments) {
    ((ImDrawList*)dl)->PathArcTo(ImVec2(cx, cy), radius, a0, a1, segments);
}

extern "C" void ember_draw_path_line(void* dl, float x, float y) {
    ((ImDrawList*)dl)->PathLineTo(ImVec2(x, y));
}

extern "C" void ember_draw_path_reset(void* dl) {
    // Named `reset` in the header; called `PathClear` in 1.92.
    ((ImDrawList*)dl)->PathClear();
}

extern "C" void ember_draw_path_fill(void* dl, unsigned int col) {
    ((ImDrawList*)dl)->PathFillConvex(col);
}

// There is no `PathClose()` in 1.92: closing a stroked path is a FLAG on the
// stroke (ImDrawFlags_Closed), so the Zig side passes `closed` here rather than
// calling a function that would close the shape for filling only.
extern "C" void ember_draw_path_stroke(void* dl, unsigned int col, float thickness, int flags) {
    ((ImDrawList*)dl)->PathStroke(col, thickness, (ImDrawFlags)flags);
}

extern "C" void ember_draw_push_clip(void* dl, float x0, float y0, float x1, float y1, int intersect) {
    ((ImDrawList*)dl)->PushClipRect(ImVec2(x0, y0), ImVec2(x1, y1), intersect != 0);
}

extern "C" void ember_draw_pop_clip(void* dl) {
    ((ImDrawList*)dl)->PopClipRect();
}

extern "C" int ember_draw_cmd_count(void* dl) {
    return (int)((ImDrawList*)dl)->CmdBuffer.Size;
}
