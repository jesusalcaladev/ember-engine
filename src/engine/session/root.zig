//! `engine.session` — the editing session: the core of Play/Stop, undo/redo and
//! the visual node graph, with no UI in it.
//!
//! ## What this module is for
//!
//! Everything between "a user clicks something in an editor" and "the world
//! changes". The editor draws the window; the ECS holds the data; this is the
//! layer that knows what an edit IS, that it can be undone, that Play is a state
//! the world can be in and that Stop returns to what it was, and that a state
//! machine or an animation clip is a graph of nodes with states and edges rather
//! than a pile of components the user cannot see.
//!
//! ## Why it is separate from both the UI and the ECS
//!
//! The UI half is where the bugs are not: a button that draws in the wrong place
//! is a screenshot away. The interesting bugs — a Stop that leaves one boss
//! behind, an undo that reverses one keystroke of a word, a state machine with a
//! transition nobody can reach — are all in here, and all of them are testable
//! with no window. The runtime and the ImGui shell consume this the way the
//! renderer consumes a batcher.
//!
//! ## The integration contract, in one paragraph
//!
//! The session owns the world's POINTER, not just its contents, because a
//! restore rebuilds the world from a snapshot rather than patching the live one.
//! Everything downstream — the UI, the runtime, the renderer — reads the world
//! from the session while a session is in play, because Stop can replace it.
//! Commands flow one way: the UI asks the session to do a thing, the session
//! pushes an act onto the undo stack and applies it, and the world the session
//! hands out is the world that changed. Nothing reaches past the session to poke
//! the world, because an edit that did not go through the stack is an edit that
//! cannot be undone.

pub const undo = @import("undo.zig");
pub const play = @import("play.zig");

/// The node graph: a state machine or an animation clip as a document with
/// nodes, edges and a layout. It is a document the editor edits, so the same
/// rules apply to it as to the world.
pub const graph = @import("graph.zig");

/// The editing document the UI drives: the selection, the dirty flag, and the
/// world edits — each one an act on the undo stack.
pub const model = @import("model.zig");

test {
    @import("std").testing.refAllDecls(@This());
}
