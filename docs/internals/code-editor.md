# The In-Engine Code Editor (core)

**Source:** `src/engine/editor/` — module root `root.zig`, text layer in `doc/`
(`buffer.zig`, `cursor.zig`, `find.zig`), Lua language layer in `lang/lua/`
(`lexer.zig`, `parser.zig`, `diagnostics.zig`).

The non-UI half of ROADMAP M5.5. This is the part with no ImGui in it: a text
document, a cursor, a Lua highlighter, a Lua parser with recovery, an error-lens
and a find engine. The UI half consumes it the way the renderer consumes a
batcher.

```
editor.Buffer   text + line index + undo        doc/buffer.zig
engine.Cursor   caret, selection, intent         doc/cursor.zig
engine.tokenize Lua -> coloured spans           lang/lua/lexer.zig
engine.parse      Lua -> tree, with recovery      lang/lua/parser.zig
engine.diagnostics parse + metadata -> the lens   lang/lua/diagnostics.zig
engine.Finder   find / replace over a Buffer     doc/find.zig
```

## Why the non-UI half is built first

1. **It is where the bugs are.** A caret inside a UTF-8 sequence, an undo that
   forgets the last keystroke, a find that matches inside a string — none of those
   show up in a screenshot and all of them are testable with no window.
2. **It is reusable.** The same buffer drives the in-editor console, the `.zson`
   viewer and (post-1.0) an LSP server. None of them should re-implement undo.
3. **It can be measured headlessly.** `zig build test` runs the whole thing with
   no Dawn, no window and no ImGui, in milliseconds. 85 tests.

## Where it may allocate

The zero-allocation rule (spec §3.1) is about the **game** frame. The editor
overlay has its own budget (spec §2) and disappears entirely in exports, so this
module allocates freely — what it must not do is allocate per rendered frame for
state that did not change. Every mutation returns the span it touched, so the UI
re-tokenizes one line instead of the file when a character is typed.

## The two Lua layers, and why they are separate

The lexer answers "what colour is this run" and never fails, because a highlighter
that failed on a half-typed line would fail during exactly the work the user is
doing. The parser answers "what does this mean" and is allowed to fail — it
reports at the offending token and resyncs to the next statement, so one typo
costs one underline and not the rest of the file. Splitting them is what lets the
highlighter stay trivially correct on broken code while the structure layer stays
useful on it.

LuaJIT's own parser was the obvious thing to reach for, and it was rejected: one
error and stop, no tree, a live `lua_State`, and a C dependency in a module that
today compiles with no C runtime at all. What the editor gains from a tree it
cannot get from a message: folds, an outline, and the scope information every
"undefined global" answer depends on.

## The diagnostics pass: the part no generic LSP has

Error lens is normally a red underline for syntax. The half worth having is the
one that is not about Lua at all: every binding this engine hands to scripts is
described once in `metadata.zig` — signature, parameter types, defaults, a summary
and an example — and that table is reachable from here as its own module, which
is why `build.zig` has an `api_meta` module in the editor's block. From it three
questions become answerable while the user types:

- `actor.set_position(self, 1)` — three arguments, two written.
- `actor.set_position(self, "home", 2)` — a `number` parameter handed a string.
- `actr.get_position(...)` — a misspelled engine global, checked against the same
  name list the highlighter colours with, so the two answers cannot drift.

The rules are deliberately conservative. A wrong diagnostic teaches the user to
ignore the lens, and then it protects nothing: the type check only fires on a
literal of the wrong shape (a variable could hold anything; a table might be a
Vec2), and the arity check only the lower bound. `x = 1` and `function f() ... end`
are writes of a global, not reads, which is why the parser re-labels them rather
than flagging them.

## The design decisions worth knowing

### Byte offsets everywhere

`Buffer`, `Cursor` and `Finder` all speak byte offsets, never (line, column)
pairs. Every other representation has to convert, and a conversion that forgets a
multi-byte character corrupts the text. Conversion happens at the edges
(`lineColOfOffset` / `offsetOfLineCol`), and movement only ever lands on a
character boundary (`nextBoundary` / `prevBoundary`).

### The line index is derived, and tested as such

`Buffer` keeps one contiguous text buffer plus a sorted array of the offset each
line starts at — a line array, not a rope, because a 4 KB Lua script does not need
a rope's per-character pointer chase and the renderer wants lines anyway.

The invariant is *"a line starts at 0 or one byte after a newline"*, and a
property test re-derives the index from the text after 400 random edits
(insert / delete / replace) and compares. That test earned its place: the delete
path was wrong twice while being written, and both versions passed every
hand-written case.

### An edit is a replacement

```zig
pub const Edit = struct { pos: u32, removed: ?[]u8, inserted: ?[]u8 };
```

Not an insert-or-delete. Reversing an insert-only entry gives back the text you
deleted but leaves the text you typed, which is exactly the bug that shape
prevents: overwriting `he` with `HE` and pressing undo used to leave `llo world`.

Every act is one entry: typing over a selection, indenting twenty lines,
replacing forty occurrences. Undo reverses an *act*, not a keystroke.

### Undo coalescing is per act

Typing merges into the open run while the inserts are contiguous (capped at 512
bytes, and the caller declares the break — a caret move, a click, a paste). A
paste or a replace never joins the run. "Undo a word" is what a person expects;
"undo a character" is what they get otherwise.

### The cursor has intent

`preferred_column` is the column a vertical movement is trying to hold. Down on a
short line and Down again onto a long one must return the caret to the column the
user was heading for, not to the end of every short line it passes. It is clamped
to each line's end on the way through, so it comes back out again; a horizontal
move clears it.

Selection is an **anchor**, taken *before* the move (not after — that was a real
bug: the first shift+arrow anchored at the destination).

### Highlighting is a scanner, not a parser

A parser would fail on a half-typed line, which is the normal state of a file
being edited, and highlighting does not need to know what the code *means*. The
two forms that break scanners are handled with one rule — a bracket **level** —
because Lua's long strings and long comments are the same construct with a
different prefix:

```lua
--  a short comment, to the newline   (the newline stays its own span)
--[[ a long comment, to the matching ]] ]]
[[ a string, to the matching ]] ]]
[==[ ... ]==]      -- the level must match: an inner ]] does not close it
```

Spans are absolute, contiguous and non-overlapping, so the UI can tokenize one
line into a reused buffer and draw one run per span. Unterminated long forms
consume to EOF rather than looping — the difference between a red line and a hung
editor.

### Search returns byte spans

`findAll` (highlight pass) allocates on purpose; `findNext` / `findPrev`
(navigation) allocate nothing and wrap exactly once; `replaceAll` rebuilds the
whole affected region into a scratch buffer and writes it with a single
`replace`, so forty replacements are one undo step.

Case-insensitive search folds both sides rather than lowercasing a copy of the
file.

## What is deliberately not here

- **Tabs, split panes, the help panel, Ctrl+Click.** Those are M5.5 UI work and
  they consume this module rather than extending it.
- **Autocompletion.** Next up, on top of the symbols and calls the parser already
  produces.
- **An LSP.** Stubs ship at v1; the LSP is post-1.0 (ROADMAP §Post-1.0).

## Running it

```bash
zig build test          # the editor suite runs first, in milliseconds
```

| File | Tests |
|---|---|
| `doc/buffer.zig` | 14 — line index, undo/redo, coalescing, the 400-edit property test |
| `doc/cursor.zig` | 18 — movement, intent, selection, auto-indent, word/page movement |
| `lang/lua/lexer.zig` | 12 — long brackets, escapes, span coverage, unterminated forms |
| `lang/lua/parser.zig` | 16 — recovery, spans, calls, scopes, the depth guard, garbage that cannot loop |
| `lang/lua/diagnostics.zig` | 13 — every rule, in both directions, at scale |
| `doc/find.zig` | 14 — wrap, whole word, folding, replace-all as one act |
