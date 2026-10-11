//! `engine.editor` — the in-engine code editor (ROADMAP M5.5).
//!
//! Godot writes Lua inside the editor, and this is the part of that which has
//! nothing to do with a UI: a text document, a cursor, a highlighter, a Lua
//! parser, an error lens, completion, hover, an outline, goto-definition and a
//! find engine. The ImGui half of M5.5 (tabs, popups, the help panel) consumes
//! this the way the renderer consumes a batcher.
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
//!
//! ## The map
//!
//! ```
//! doc/       text with no language in it: buffer, cursor, find
//! lang/lua/  the Lua layer:
//!   lexer       tokens -> coloured spans
//!   parser      tokens -> tree, with recovery
//!   resolve     which declaration is this name naming (shared)
//!   diagnostics parse + API registry -> the error lens
//!   complete    what to offer at the caret
//!   help        hover / Ctrl+Click
//!   outline     the file as a tree
//!   goto        definition and references
//!   rename      every place one name is named
//!   help_index  Ctrl+Click, and the browsable index
//! ```
//!
//! The rule that keeps it legible: `doc/` never mentions Lua, and `lang/lua/` is
//! where a language is allowed to be understood. Everything here speaks byte
//! offsets, so the UI layer converts once and never thinks about multi-byte
//! characters again.

const std = @import("std");

pub const buffer = @import("doc/buffer.zig");
pub const highlight = @import("lang/lua/lexer.zig");
pub const cursor = @import("doc/cursor.zig");
pub const find = @import("doc/find.zig");
pub const lexer = highlight;
pub const parser = @import("lang/lua/parser.zig");
pub const diagnostics = @import("lang/lua/diagnostics.zig");
pub const complete = @import("lang/lua/complete.zig");
pub const help = @import("lang/lua/help.zig");
pub const resolve = @import("lang/lua/resolve.zig");
pub const outline = @import("lang/lua/outline.zig");
pub const goto = @import("lang/lua/goto.zig");
pub const rename = @import("lang/lua/rename.zig");
pub const help_index = @import("lang/lua/help_index.zig");

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
