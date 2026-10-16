//! `engine.ui` — the editor's UI framework: tokens, primitives, widgets.
//!
//! ## What this module is
//!
//! A component library over Dear ImGui with one rule: **a component is a pure
//! function of its props.** It draws, it returns what happened, and it keeps
//! nothing. State lives in `reactive.Store`, addressed by a path written at the
//! call site, so:
//!
//! - a bug in a component is fixed in ONE file, because there is no state
//!   spread across the other forty that could be the other half of it;
//! - a component can be read top to bottom and diffed, which is the property
//!   the request "if there is a bug we go and modify it, like React" is
//!   actually asking for;
//! - the whole framework is a set of functions, so a new one costs a file and
//!   no wiring.
//!
//! ## The map
//!
//! ```
//! cimgui.zig      the C ABI: externs, enum mirrors, Rgba, argument marshalling
//! cimgui/         the C++ shim: one ImGui call per symbol, no design
//! keys.zig        GLFW keycode -> ImGui key, with a test that reads imgui.h
//! theme.zig       TOKENS. The only file with literal colours in it.
//! reactive.zig    Store, Signal, memo — the "React" part
//! draw.zig        draw-list primitives; no widget knows what a button is
//! icons.zig       icons as geometry, not as assets
//! context.zig     the one piece of state that is not path-addressed
//! layout.zig      row / column / panel / splitter / window
//! widgets/        button, toggle, input, select, text, card, list, tabs,
//!                 modal, feedback
//! ```
//!
//! ## The rule about colours
//!
//! There is one palette, in `theme.zig`, and a widget that needs a colour that
//! is not in it adds the NAME to the palette. No widget writes `0xFF202020`.
//! The test for whether a value belongs in a widget or in the theme is whether
//! two different widgets would want it: if yes it is a token, if no it is a
//! local.
//!
//! ## Where it is used
//!
//! `src/tools/editor/` for the editor (M5), and `src/tools/ui_demo/` for the
//! component gallery — which is the regression suite: every component is on
//! screen at once, so a change to one is visible in one run.

const std = @import("std");

pub const cimgui = @import("cimgui.zig");
pub const keys = @import("keys.zig");
pub const theme = @import("theme.zig");
pub const Theme = theme.Theme;
pub const Palette = theme.Palette;
pub const Metrics = theme.Metrics;
pub const Rgba = cimgui.Rgba;
pub const Color = cimgui.Rgba;

pub const reactive = @import("reactive.zig");
pub const Store = reactive.Store;
pub const Signal = reactive.Signal;

pub const draw = @import("draw.zig");
pub const icons = @import("icons.zig");
pub const Icon = icons.Icon;
pub const List = draw.List;

pub const Context = @import("context.zig").Context;
pub const Stats = @import("context.zig").Stats;
pub const Fonts = @import("context.zig").Fonts;

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

// ── The shortcuts a call site actually uses ──────────────────────────────
//
// The re-exports below are the API. `ui.Button(...)` reads like the component
// it is; `ui.button.render(.{...})` reads like a function call with a
// configuration object, which is also what it is, and is the honest name.

/// A button. See `widgets/button.zig` for the variants.
pub const Button = button.render;
pub const IconButton = button.icon;
/// A checkbox. Takes a `toggle.Checkbox`; there are no positional arguments
/// because a positional argument list for a control with nine props is how
/// `checkbox(ctx, "x", &v, false)` becomes `checkbox(ctx, "x", &v, true)`.
pub const Checkbox = toggle.checkbox;
pub const Switch = toggle.switch_;
pub const Segmented = toggle.segmented;
pub const TextField = input.textField;
pub const ColorField = color.field;
pub const Hsv = color.Hsv;
pub const CurveField = curve.field;
pub const Easing = curve.Easing;
pub const CodeView = code_view.view;
pub const CodeToken = code_view.Token;
pub const CodeKind = code_view.Kind;
pub const Completion = completion.popup;
pub const CompletionItem = completion.Item;
pub const SearchField = input.search;
pub const NumberField = input.numberField;
pub const Slider = input.slider;
pub const Select = select.select;
pub const Label = text.label;
pub const Caption = text.caption;
pub const Value = text.value;
pub const Title = text.title;
pub const Subtitle = text.subtitle;
pub const Badge = text.Badge.render;
pub const kbd = text.kbd;
pub const Card = card.card;
pub const Section = card.section;
pub const Collapse = card.collapse;
pub const Row2 = list.row;
pub const Tree = list.tree;
pub const Tabs = tabs.tabs;
pub const Modal = modal.modal;
pub const MenuItem = modal.menuItem;
pub const Progress = feedback.Progress.render;
pub const Status = feedback.Status.render;

/// The row/column helpers, re-exported at the top level because every panel
/// uses them and `ui.row(ctx, ...)` beats `ui.layout.row(ctx, ...)`.
pub const row = layout.row;
pub const column = layout.column;
pub const space = layout.space;
pub const gap = layout.gap;
pub const spacerToEnd = layout.spacerToEnd;
pub const panel = layout.panel;
pub const splitter = layout.splitter;
pub const fullscreen = layout.fullscreen;
pub const floating = layout.floating;

/// Applies a theme to a live context. See `theme.Theme.apply`.
pub fn applyTheme(ctx: *Context) void {
    ctx.applyTheme();
}

test {
    // The module's own tests, run by `zig build test-ui`. They are here in one
    // place so the list of what /ui guarantees is readable, and so a component
    // that grows a test cannot be forgotten.
    std.testing.refAllDecls(@This());
}
