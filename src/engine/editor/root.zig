//! `engine.editor` — the in-engine code editor (ROADMAP M5.5).
//!
//! Godot writes Lua inside the editor, and this is the part of that which has
//! nothing to do with a UI: a text document, a cursor, a highlighter and a find
//! engine. The ImGui half of M5.5 (tabs, popups, the help panel) consumes this
//! the way the renderer consumes a batcher.
//!
//! ## Why the non-UI half is built first
//!
//! 1. **It is where the bugs are.** A cursor that walks into the middle of a
//!    UTF-8 sequence, an undo stack that forgets the last keystroke, a find that
//!    matches inside a string — none of those are visible in a screenshot, and all
//!    of them are trivially unit-testable without a window. The UI is a thin
//!    projection of this state; the state is what has to be right.
//! 2. **It is reusable outside the editor.** The same buffer drives the in-editor
//!    console, the `.zson` read-only viewer and (post-1.0) the LSP server. There
//!    is no reason for any of them to re-implement undo.
//! 3. **It can be measured headlessly.** `zig build test-editor` runs the whole
//!    thing with no Dawn, no window and no ImGui, exactly like the ECS tests.
//!
//! ## Where it may allocate
//!
//! The frame-loop rule (spec §3.1: zero allocations while a game runs) is a rule
//! about the GAME frame, not about the editor overlay. The editor has its own
//! budget (spec §2) and disappears entirely in exports, so this module allocates
//! freely and says so — what it must not do is allocate per rendered frame for
//! state that did not change. Every mutation returns the span it touched, so the
//! UI re-tokenizes one line instead of the whole file when a character is typed.

const std = @import("std");

pub const buffer = @import("text_buffer.zig");
pub const highlight = @import("lua_highlight.zig");
pub const cursor = @import("cursor.zig");
pub const find = @import("find.zig");

// Short names for what the UI layer imports constantly. `Token` is a highlighted
// run; `Span` is a plain byte range, and the two names are kept distinct because
// the UI passes both around in the same function.
pub const Buffer = buffer.Buffer;
pub const Cursor = cursor.Cursor;
pub const Span = buffer.Span;
pub const LineCol = buffer.LineCol;
pub const Token = highlight.Span;
pub const Kind = highlight.Kind;

test {
    @import("std").testing.refAllDecls(@This());
}
