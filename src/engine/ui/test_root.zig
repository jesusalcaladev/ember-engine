//! `ui.test_root` — the headless half of the UI framework's tests.
//!
//! ## What can be tested without a window, and what cannot
//!
//! Everything that is DECISION and nothing that is PIXELS: the key mapping and
//! its drift against the pinned header, the palette's packing, the spacing
//! scale, the store's path addressing, the memo's invalidation, the clamping
//! rules. All of it runs in milliseconds with no Dawn, no GLFW and no display —
//! which is the same split `engine/editor/` makes, and for the same reason: a
//! test that needs a GPU is a test CI cannot run.
//!
//! What is NOT here is anything that submits an ImGui item. Those need a context
//! and a device, and they are exercised by `src/tools/ui_demo` (the component
//! gallery) and by the editor itself.
//!
//! The filter matters: a test whose name misses every filter does not fail, it
//! simply never runs, which is a green suite measuring nothing. The names here
//! all start with "ui ".

const std = @import("std");

pub const cimgui = @import("cimgui.zig");
pub const keys = @import("keys.zig");
pub const theme = @import("theme.zig");
pub const reactive = @import("reactive.zig");
pub const draw = @import("draw.zig");
pub const icons = @import("icons.zig");
pub const context = @import("context.zig");
pub const layout = @import("layout.zig");
pub const widget = @import("widgets/widget.zig");
pub const button = @import("widgets/button.zig");
pub const toggle = @import("widgets/toggle.zig");
pub const input = @import("widgets/input.zig");
pub const color = @import("widgets/color.zig");
pub const curve = @import("widgets/curve.zig");
pub const code_view = @import("widgets/code_view.zig");
pub const completion = @import("widgets/completion.zig");
pub const select = @import("widgets/select.zig");
pub const text = @import("widgets/text.zig");
pub const card = @import("widgets/card.zig");
pub const list = @import("widgets/list.zig");
pub const tabs = @import("widgets/tabs.zig");
pub const modal = @import("widgets/modal.zig");
pub const feedback = @import("widgets/feedback.zig");

test {
    // Pull in every test in the module. `refAllDecls` references the DECLARED
    // subsections (the `pub const`s above, each of which itself calls
    // `refAllDecls` on its own file when compiled as a test root) — which is
    // what makes a NEW file's tests run without editing this one. There is no
    // `refAllDeclsRecursive` in std, and inventing one that walks private
    // declarations would be the difference between a test suite and a test
    // file.
    std.testing.refAllDecls(@This());
}
