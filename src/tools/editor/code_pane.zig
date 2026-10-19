//! `editor.code_pane` — the bridge between the editor CORE and `engine.ui`.
//!
//! ## Why this file exists at all
//!
//! `engine.editor` is a document, a cursor, a lexer and a formatter: pure Zig,
//! no window, no ImGui, testable in milliseconds. `engine.ui` is a component
//! library over Dear ImGui: pure functions of props, no document, no lexer. The
//! two are separate modules on purpose — `ui` may not import `editor` (see the
//! long note at the top of `ui/widgets/code_view.zig`), and `editor` may not
//! import `ui` (its whole test suite runs with no GPU).
//!
//! Something has to hold both, and that something is the editor tool. This file
//! is that adapter and nothing else: it owns the state the two need to share
//! (where the caret is, what is selected, what the tokens are) and it is where
//! the two vocabularies are translated into each other.
//!
//! ## The three translations, and why each one is here
//!
//! 1. **`editor.Kind` -> `ui.CodeKind`.** Two enums with the same nine arms,
//!    deliberately not the same type: each module owns its own vocabulary, and a
//!    shared enum would make `ui` depend on `editor` (or vice versa). The switch
//!    is exhaustive, so a tenth arm added on either side is a compile error here
//!    rather than a colour that silently stops being applied.
//! 2. **A `Buffer` -> the widget's plain data.** `text` is `buffer.textBytes()`,
//!    `line_starts` is `buffer.line_starts.items` (the index the widget is
//!    documented to take, and the one the buffer already maintains, so no scan
//!    happens per frame), and `tokens` is the cached span list re-tagged. The
//!    widget never sees a `Buffer`.
//! 3. **The window's input -> the cursor.** The editor owns its own keyboard
//!    (the same split `ui/widgets/completion.zig` documents for the popup), so
//!    nothing here goes through ImGui's focus machinery: a key press is a key
//!    press, and the code panel is the only text surface in the app.
//!
//! ## The performance contract
//!
//! A frame with no typing must do NO tokenizer work. That is what
//! `editor.highlight_cache` is for, and it is why `tokens()` is keyed on
//! `buffer.version`: a 200k-line file costs one tokenize per EDIT, and an idle
//! frame costs one `u32` compare. The re-tag into `ui.CodeToken` is the only
//! per-frame work in the steady state, and it is a linear copy over the token
//! count, not a re-scan of the text.
//!
//! ## What is deliberately NOT here (yet)
//!
//! - **An incremental lexer.** Editing still re-tokenizes the whole document.
//!   The fix is lexer STATE (are we inside a `--[[`?) carried across a resume
//!   point, which is a change to `lexer.zig`, not to this file. See the note in
//!   `highlight_cache.zig`; the cost is one pass per edit, not per frame.
//! - **Multiple files / tabs.** One document, opened from argv or a built-in
//!   sample. The session model that owns several documents belongs to M5, and
//!   wiring a second one before the first is right is how a pane becomes a
//!   framework.

const std = @import("std");
const ui = @import("ui");
const editor = @import("editor");
const platform = @import("platform");
const glfw = platform.glfw;
const cimgui = ui.cimgui;
const Vec2 = cimgui.Vec2;

const Buffer = editor.Buffer;
const Cursor = editor.Cursor;

// ── Translation 1: the two Kind enums ────────────────────────────────────

/// `editor.Kind` -> `ui.CodeKind`. Exhaustive on purpose: a new arm on either
/// side is a compile error here, which is the only way a colour cannot silently
/// stop being applied.
pub fn codeKind(k: editor.Kind) ui.CodeKind {
    return switch (k) {
        .plain => .plain,
        .comment => .comment,
        .string => .string,
        .number => .number,
        .keyword => .keyword,
        .global => .global,
        .field => .field,
        .operator => .operator,
        .invalid => .invalid,
    };
}

// ── Export geometry: a display column -> a byte offset ───────────────────

/// The byte offset on a line whose DISPLAY column is `col`, expanding tabs the
/// same way `code_view.columnAt` does — this is that function's inverse, and the
/// two have to agree or a click lands the caret one column off per indent level.
///
/// `col` past the end of the line clamps to the line's end, which is what makes
/// a click to the right of the last character put the caret after it instead of
/// on the next line. The scroll/line resolution belongs to the caller: this is
/// pure line geometry with no document in it.
pub fn byteAtColumn(
    text: []const u8,
    line_start: u32,
    line_end: u32,
    col: u32,
    tab_width: u32,
) u32 {
    const tw: u32 = if (tab_width == 0) 1 else tab_width;
    const start: usize = @min(line_start, text.len);
    const end: usize = @min(line_end, text.len);
    var c: u32 = 0;
    var i: usize = start;
    while (i < end) : (i += 1) {
        // Tabs advance to the next stop; a column inside the tab's span lands
        // on the tab, which is what makes clicking the middle of an indent put
        // the caret at the start of it rather than somewhere inside.
        const w: u32 = if (text[i] == '\t') ((c / tw) + 1) * tw - c else 1;
        if (c + w > col) return @intCast(i);
        c += w;
    }
    return @intCast(end);
}

/// The byte offset for a click at `point`, given the panel's own geometry. Kept
/// as a free function of numbers so it is readable and so the widget's layout
/// rules (`gutter + 8` for the text origin, `line_h` per line) live in ONE place
/// in this file rather than being re-derived at the call site.
pub fn offsetAtPoint(
    text: []const u8,
    line_starts: []const u32,
    point: Vec2,
    origin: Vec2,
    scroll: f32,
    line_h: f32,
    advance: f32,
    gutter: f32,
    tab_width: u32,
) u32 {
    if (line_starts.len == 0) return 0;
    const lh: f32 = if (line_h > 1.0) line_h else 14.0;
    const adv: f32 = if (advance > 0.0) advance else 1.0;

    const row = (point.y - origin.y) / lh + scroll;
    const line_f = @floor(row);
    const line: u32 = @intFromFloat(std.math.clamp(
        line_f,
        0.0,
        @as(f32, @floatFromInt(line_starts.len - 1)),
    ));

    const col_f = (point.x - origin.x - gutter - 8.0) / adv;
    const col: u32 = @intFromFloat(@max(@floor(col_f), 0.0));

    var end: u32 = @intCast(text.len);
    if (@as(usize, line) + 1 < line_starts.len) end = line_starts[line + 1];
    // The click is inside the text, so the newline is not a column: a click at
    // the very end of the line lands BEFORE the newline rather than on it.
    var text_end = end;
    while (text_end > line_starts[line] and (text[text_end - 1] == '\n' or text[text_end - 1] == '\r')) {
        text_end -= 1;
    }
    return byteAtColumn(text, line_starts[line], text_end, col, tab_width);
}

// ── The pane ─────────────────────────────────────────────────────────────

/// Above this many bytes, the full-document parse that completion needs is not
/// run automatically while typing. The highlight, the caret and the formatter
/// are unaffected — only the popup is, and Ctrl+Space still forces it. This is a
/// stated limit rather than a hidden one: the parser has no incremental mode, so
/// "completion on every keystroke of a 100k-line file" would be a per-keystroke
/// full parse, which is a slower editor with a nicer popup.
pub const completion_parse_budget: usize = 256 * 1024;

pub const default_sample =
    \\-- ember editor — Lua
    \\--
    \\-- The panel to the right is a real document: type into it, Ctrl+S formats
    \\-- and writes it, Ctrl+Space completes, Tab indents.
    \\
    \\local speed = 12.5
    \\
    \\function update(self, dt)
    \\    self.x = self.x + speed * dt
    \\    if self.x > 100 then
    \\        self.x = 0
    \\    end
    \\end
    \\
;

pub const Pane = struct {
    allocator: std.mem.Allocator,
    buffer: Buffer,
    /// Points at `buffer`; only valid after `init`, which is why `init` takes a
    /// pointer rather than returning a value (a returned `Cursor` would point at
    /// the copy's buffer).
    cursor: Cursor,
    cache: editor.highlight_cache.Cache,
    /// The re-tagged spans handed to the widget. Grown once and reused: an edit
    /// re-fills it, it does not reallocate.
    view_tokens: std.ArrayListUnmanaged(ui.CodeToken) = .empty,
    scroll: f32 = 0.0,
    /// Owned. Empty means "no file yet": Ctrl+S says so instead of writing one.
    path: []u8 = &.{},
    /// One line of feedback, drawn in the footer. Set by an action, cleared by
    /// the next one, so it never becomes a stale status bar.
    notice: []const u8 = "",
    /// How many tokens were drawn last frame. Kept so the footer can report it
    /// without calling `tokens()` a second time from inside a format argument.
    last_tokens: usize = 0,
    /// ImGui draw commands the panel queued on the frame it last drew. Sampled
    /// INSIDE the window, because `GetWindowDrawList` is only valid between
    /// `Begin` and `End` — asking after the frame is a null-pointer panic, which
    /// is exactly what happened the first time this was reported from the
    /// summary instead of from here.
    last_draw_cmds: usize = 0,

    // Set by a click handler during the draw, acted on after it: mutating the
    // buffer while ImGui is mid-window is how a re-entrancy bug is born.
    request_save: bool = false,
    request_format: bool = false,
    request_undo: bool = false,
    request_redo: bool = false,

    // ── Completion state ─────────────────────────────────────────────────
    items: []editor.complete.Item = &.{},
    item_views: std.ArrayListUnmanaged(ui.CompletionItem) = .empty,
    /// The parse the current item list borrows from. `complete.complete` returns
    /// labels that POINT INTO the source for locals, so the parse and the text it
    /// borrowed have to outlive the popup. They do: both are replaced together.
    parsed: ?editor.parser.Result = null,
    popup_open: bool = false,
    popup_selected: usize = 0,
    /// The word being completed, copied out of the buffer so it survives the
    /// mutation that accepting a completion performs.
    prefix_buf: [96]u8 = undefined,
    prefix_len: usize = 0,
    prefix_start: u32 = 0,

    /// Frames on which the tokenizer actually ran. The cache's own counter, shown
    /// in the footer: it is the number that proves a big file is not being
    /// re-tokenized per frame.
    pub fn builds(self: *const Pane) u64 {
        return self.cache.builds;
    }

    pub fn init(self: *Pane, allocator: std.mem.Allocator, path: []const u8, source: []const u8) !void {
        self.* = .{
            .allocator = allocator,
            .buffer = Buffer.init(allocator),
            .cursor = undefined,
            .cache = editor.highlight_cache.Cache.init(allocator),
        };
        // AFTER the struct is in its final home: `Cursor` stores `&buffer`, and
        // taking that pointer before the assignment would point at the temporary.
        self.cursor = Cursor.init(&self.buffer);
        try self.buffer.load(source);
        if (path.len > 0) self.path = try allocator.dupe(u8, path);
    }

    pub fn deinit(self: *Pane) void {
        self.dropCompletions();
        if (self.path.len > 0) self.allocator.free(self.path);
        self.view_tokens.deinit(self.allocator);
        self.item_views.deinit(self.allocator);
        self.cache.deinit();
        self.buffer.deinit();
    }

    /// The document text. Valid until the next mutation.
    pub fn text(self: *const Pane) []const u8 {
        return self.buffer.textBytes();
    }

    // ── Tokenisation ─────────────────────────────────────────────────────

    /// The widget's token list for the CURRENT buffer version. One pass over the
    /// cached spans to re-tag them; the lexer runs only when the version moved.
    pub fn tokens(self: *Pane) ![]const ui.CodeToken {
        const spans = try self.cache.spans(self.buffer.textBytes(), self.buffer.version);
        try self.view_tokens.ensureTotalCapacity(self.allocator, spans.len);
        self.view_tokens.items.len = spans.len;
        for (spans, 0..) |s, i| {
            self.view_tokens.items[i] = .{ .start = s.start, .len = s.len, .kind = codeKind(s.kind) };
        }
        return self.view_tokens.items;
    }

    // ── Actions ──────────────────────────────────────────────────────────

    /// Formats the document as ONE undo step and reports whether it changed.
    pub fn formatDocument(self: *Pane) !bool {
        const changed = try editor.format.formatBuffer(self.allocator, &self.buffer, .{});
        self.dropCompletions();
        return changed;
    }

    /// Format-on-save, then write. The ORDER is the feature the user asked for:
    /// the bytes that reach the disk are the formatted ones, not the ones that
    /// happened to be on screen.
    pub fn save(self: *Pane, format_first: bool) void {
        if (format_first) {
            _ = self.formatDocument() catch {
                // The formatter's error set is exactly `OutOfMemory` — it walks
                // the text and appends, and nothing in it can fail any other
                // way. A wider catch here would be a lie about the contract.
                self.notice = "format failed: out of memory";
                return;
            };
        }
        if (self.path.len == 0) {
            self.buffer.markSaved();
            self.notice = "no path: formatted in memory only";
            return;
        }
        // The Io API the rest of the engine uses (`project/config.zig`): Zig's
        // filesystem is reached through an explicit `Io` instance, which is what
        // makes a blocking write and an async one the same call site.
        const io = std.Io.Threaded.global_single_threaded.io();
        std.Io.Dir.cwd().writeFile(io, .{
            .sub_path = self.path,
            .data = self.buffer.textBytes(),
        }) catch {
            self.notice = "save failed: write error";
            return;
        };
        self.buffer.markSaved();
        self.notice = "saved (formatted)";
    }

    // ── Completion ───────────────────────────────────────────────────────

    fn dropCompletions(self: *Pane) void {
        if (self.parsed) |*p| p.deinit(self.allocator);
        self.parsed = null;
        self.items = &.{};
        self.item_views.clearRetainingCapacity();
        self.popup_open = false;
        self.prefix_len = 0;
    }

    /// Recomputes the suggestion list for the word at the caret. Returns whether
    /// the popup should be shown.
    fn refreshCompletions(self: *Pane, force: bool) !void {
        if (!force and self.buffer.byteLen() > completion_parse_budget) {
            self.dropCompletions();
            return;
        }
        const src = self.buffer.textBytes();
        const ctx = editor.complete.contextOf(src, self.cursor.pos);
        if (ctx.prefix.len == 0 and !force) {
            self.dropCompletions();
            return;
        }
        if (!force and ctx.prefix.len < 1) {
            self.dropCompletions();
            return;
        }

        // Both are replaced together: the old parse must go only after the list
        // that borrows from it is gone.
        self.dropCompletions();
        const parsed = editor.parser.parse(self.allocator, src) catch return;
        const items = editor.complete.complete(self.allocator, src, parsed, self.cursor.pos) catch {
            var p = parsed;
            p.deinit(self.allocator);
            return;
        };
        self.parsed = parsed;
        self.items = items;

        const n = @min(ctx.prefix.len, self.prefix_buf.len);
        @memcpy(self.prefix_buf[0..n], ctx.prefix[0..n]);
        self.prefix_len = n;
        self.prefix_start = ctx.start;
        self.popup_selected = 0;
        self.popup_open = items.len > 0;
        self.syncItemViews();
    }

    /// Maps the editor's `Item`s onto the widget's `Item`s. Labels are BORROWED
    /// straight through — the parse that owns the local names outlives the popup,
    /// so nothing is copied and nothing dangles.
    fn syncItemViews(self: *Pane) void {
        self.item_views.clearRetainingCapacity();
        self.item_views.ensureTotalCapacity(self.allocator, self.items.len) catch return;
        for (self.items) |it| {
            self.item_views.appendAssumeCapacity(.{
                .label = it.label,
                .detail = it.detail,
                .kind = switch (it.kind) {
                    .keyword => .keyword,
                    .module => .module,
                    .function => .function_,
                    .local => .variable,
                    .snippet => .keyword,
                },
            });
        }
    }

    /// Replaces the word under the caret with the selected suggestion.
    fn acceptCompletion(self: *Pane) void {
        if (self.items.len == 0) return;
        const idx = @min(self.popup_selected, self.items.len - 1);
        const item = self.items[idx];
        const bytes = item.text();
        const caret_rel: u32 = if (item.insert.len > 0) item.caret else @intCast(bytes.len);
        // One undo step for a completion, so Ctrl+Z takes back the whole insert
        // rather than one character of it.
        self.buffer.breakRun();
        self.cursor.moveTo(self.prefix_start);
        self.buffer.beginRun();
        self.cursor.insert(bytes) catch return;
        self.buffer.breakRun();
        self.cursor.moveTo(self.prefix_start + caret_rel);
        self.dropCompletions();
    }

    // ── Input ────────────────────────────────────────────────────────────

    /// The window's input, applied to the document. Called once per frame, before
    /// drawing, so the frame draws the state the user just produced.
    pub fn handleInput(self: *Pane, input: *platform.Input) void {
        if (!input.mouse.focused) return;
        const ctrl = input.ctrl();
        const shift = input.shift();

        // ── The popup owns the keyboard while it is open ───────────────────
        if (self.popup_open) {
            if (input.pressed(glfw.KEY_ESCAPE)) {
                self.dropCompletions();
                return;
            }
            if (input.pressed(glfw.KEY_UP)) {
                self.popup_selected = ui.completion.step(self.popup_selected, self.items.len, -1);
                return;
            }
            if (input.pressed(glfw.KEY_DOWN)) {
                self.popup_selected = ui.completion.step(self.popup_selected, self.items.len, 1);
                return;
            }
            if (input.pressed(glfw.KEY_ENTER) or input.pressed(glfw.KEY_TAB)) {
                self.acceptCompletion();
                return;
            }
        }

        // ── Commands ───────────────────────────────────────────────────────
        if (ctrl) {
            if (input.pressed(glfw.KEY_S)) {
                self.save(true);
                return;
            }
            if (input.pressed(glfw.KEY_Z)) {
                _ = self.buffer.undo();
                self.afterEdit();
                return;
            }
            if (input.pressed(glfw.KEY_Y)) {
                _ = self.buffer.redo();
                self.afterEdit();
                return;
            }
            if (input.pressed(glfw.KEY_A)) {
                self.cursor.selectAll();
                return;
            }
            if (input.pressed(glfw.KEY_SPACE)) {
                self.refreshCompletions(true) catch {};
                return;
            }
            // Ctrl+Home/End are the document ends; the plain forms are line ends.
        }

        // ── Movement ───────────────────────────────────────────────────────
        const page = self.pageLines();
        if (input.pressed(glfw.KEY_LEFT)) {
            self.buffer.breakRun();
            self.cursor.moveLeft(shift);
        } else if (input.pressed(glfw.KEY_RIGHT)) {
            self.buffer.breakRun();
            self.cursor.moveRight(shift);
        } else if (input.pressed(glfw.KEY_UP)) {
            self.buffer.breakRun();
            self.cursor.moveUp(shift);
        } else if (input.pressed(glfw.KEY_DOWN)) {
            self.buffer.breakRun();
            self.cursor.moveDown(shift);
        } else if (input.pressed(glfw.KEY_PAGE_UP)) {
            self.buffer.breakRun();
            self.cursor.page_lines = page;
            self.cursor.movePageUp(shift);
        } else if (input.pressed(glfw.KEY_PAGE_DOWN)) {
            self.buffer.breakRun();
            self.cursor.page_lines = page;
            self.cursor.movePageDown(shift);
        } else if (input.pressed(glfw.KEY_HOME)) {
            self.buffer.breakRun();
            if (ctrl) self.cursor.moveHome(shift) else self.cursor.moveLineStart(shift);
        } else if (input.pressed(glfw.KEY_END)) {
            self.buffer.breakRun();
            self.cursor.moveLineEnd(shift);
        } else if (input.pressed(glfw.KEY_BACKSPACE)) {
            self.cursor.backspace() catch return;
            self.afterEdit();
        } else if (input.pressed(glfw.KEY_DELETE)) {
            self.cursor.delete() catch return;
            self.afterEdit();
        } else if (input.pressed(glfw.KEY_ENTER)) {
            self.cursor.insertNewline() catch return;
            self.afterEdit();
        } else if (input.pressed(glfw.KEY_TAB)) {
            self.cursor.indent(shift) catch return;
            self.afterEdit();
        } else if (input.pressed(glfw.KEY_V) and ctrl) {
            // handled in the ctrl block above; kept here so the ordering is
            // obvious to a reader of this switch.
        }
    }

    /// Typed characters. Separate from `handleInput` because the window reports
    /// text as its own stream, and because a typed character is the only thing
    /// that *should* refresh the completion list as it goes.
    pub fn handleText(self: *Pane, input: *platform.Input) void {
        if (!input.mouse.focused) return;
        if (input.ctrl() or input.alt()) return; // a shortcut, not a character
        const typed = input.text.slice();
        if (typed.len == 0) return;
        // Control bytes are not text: Enter, Tab and Backspace are keys, and
        // letting their raw byte through would insert a literal `\n` twice.
        var printable: [64]u8 = undefined;
        var n: usize = 0;
        for (typed) |b| {
            if (b < 0x20 or b == 0x7F) continue;
            if (n == printable.len) break;
            printable[n] = b;
            n += 1;
        }
        if (n == 0) return;
        self.cursor.typeChar(printable[0..n]) catch return;
        self.afterEdit();

        // The list follows the word being typed. Recomputing here (rather than
        // per frame) is what keeps an idle frame free of parser work.
        const src = self.buffer.textBytes();
        const ctx = editor.complete.contextOf(src, self.cursor.pos);
        const same_word = self.popup_open and ctx.start == self.prefix_start;
        if (ctx.prefix.len == 0) {
            self.dropCompletions();
        } else if (!same_word or ctx.prefix.len != self.prefix_len) {
            self.refreshCompletions(false) catch {};
        }
    }

    fn afterEdit(self: *Pane) void {
        // Any edit invalidates the borrowed completion labels, because local
        // labels point into the buffer that just moved.
        self.dropCompletions();
    }

    fn pageLines(self: *const Pane) u32 {
        _ = self;
        return 30;
    }

    // ── Drawing ──────────────────────────────────────────────────────────

    /// Draws the pane as a full-window editor. Kept for a standalone run (and
    /// for the `--frames` smoke test); the editor shell calls `drawContents`
    /// inside its centre panel so the pane shares the dock with the viewport.
    pub fn draw(self: *Pane, ctx: *ui.Context, dt: f32) void {
        const flags: u32 = cimgui.WindowFlags.NoTitleBar |
            cimgui.WindowFlags.NoResize |
            cimgui.WindowFlags.NoCollapse |
            cimgui.WindowFlags.NoMove |
            cimgui.WindowFlags.NoSavedSettings |
            cimgui.WindowFlags.NoBringToFrontOnFocus;
        cimgui.ember_ui_set_next_window_pos(0, 0, @intFromEnum(cimgui.Cond.Always));
        cimgui.ember_ui_set_next_window_size(
            @floatFromInt(ctx.window.fb_width),
            @floatFromInt(ctx.window.fb_height),
            @intFromEnum(cimgui.Cond.Always),
        );
        if (cimgui.ember_ui_begin(cimgui.text("##editor_code"), @bitCast(flags)) == 0) {
            cimgui.ember_ui_end();
            return;
        }
        defer cimgui.ember_ui_end();
        self.drawContents(ctx, dt);
    }

    /// The pane's body, drawn into the CURRENT window at the current cursor.
    ///
    /// Everything below measures from the cursor and the remaining content
    /// area, so the same code fills a full screen and a 900×600 dock panel. The
    /// caller owns the window (and its begin/end pair); this owns the chrome
    /// and the document.
    ///
    /// `dt` is unused today and taken anyway, so adding an animation later does
    /// not change every call site.
    pub fn drawContents(self: *Pane, ctx: *ui.Context, dt: f32) void {
        _ = dt;
        const t = &ctx.theme;
        const m = t.metrics;

        const list = ui.draw.List.window();
        const origin = ui.draw.cursorScreenPos();
        const avail = ui.draw.contentAvail();

        // ── Header ─────────────────────────────────────────────────────────
        const header_h: f32 = 40.0;
        const bar = ui.draw.rect(origin.x, origin.y, origin.x + avail.x, origin.y + header_h);
        list.rect(bar, t.colors.surface, 0);
        list.separator(ui.draw.rect(bar.min.x, bar.max.y - 1, bar.max.x, bar.max.y), t.colors.border);

        ui.draw.setCursorPos(.{ .x = origin.x + m.panel_pad(), .y = origin.y + 8 });
        const name = if (self.path.len > 0) std.fs.path.basename(self.path) else "(unsaved)";
        var title_buf: [160]u8 = undefined;
        const title = std.fmt.bufPrint(&title_buf, "{s}{s}", .{ name, if (self.buffer.isDirty()) " *" else "" }) catch name;
        list.text(.{ .x = origin.x + m.panel_pad(), .y = origin.y + 12 }, t.colors.text, title);

        // Buttons, drawn with the framework's own component. The labels carry
        // their shortcut, which is the cheapest documentation an editor has.
        //
        // Every one is preceded by an explicit `setCursorPos`: the title above is
        // a DRAW-LIST text, not an ImGui item, so it does not advance the layout
        // cursor, and a button without one would land on top of it. The x values
        // are fixed rather than accumulated so that changing one label cannot
        // silently overlap the next control.
        const btn_y = origin.y + 6;
        ui.draw.setCursorPos(.{ .x = origin.x + 240.0, .y = btn_y });
        _ = ui.Button(.{ .ctx = ctx, .id = "save", .text = "Save (Ctrl+S)", .on_click = clickSave, .ctx_arg = self });
        ui.draw.setCursorPos(.{ .x = origin.x + 380.0, .y = btn_y });
        _ = ui.Button(.{ .ctx = ctx, .id = "format", .text = "Format", .on_click = clickFormat, .ctx_arg = self });
        ui.draw.setCursorPos(.{ .x = origin.x + 490.0, .y = btn_y });
        _ = ui.Button(.{ .ctx = ctx, .id = "undo", .text = "Undo", .variant = .ghost, .on_click = clickUndo, .ctx_arg = self });
        ui.draw.setCursorPos(.{ .x = origin.x + 578.0, .y = btn_y });
        _ = ui.Button(.{ .ctx = ctx, .id = "redo", .text = "Redo", .variant = .ghost, .on_click = clickRedo, .ctx_arg = self });

        // ── The code view ──────────────────────────────────────────────────
        const footer_h: f32 = 26.0;
        const code_y = origin.y + header_h;
        const code_h = @max(avail.y - header_h - footer_h, 40.0);
        // `CodeView` asks the CURRENT layout cursor for its rect, so the cursor
        // has to be parked at the panel's top-left before the call.
        ui.draw.setCursorPos(.{ .x = origin.x, .y = code_y });

        // The caret's screen position is computed from the SAME numbers the
        // widget uses (`gutter + 8`, the mono line height, the advance of "0"),
        // because it is the popup's anchor. Measuring them here, before the call,
        // is the only way to have them in scope for the popup afterwards.
        const geom = self.measure(ctx);

        var sel: ?ui.code_view.Selection = null;
        if (self.cursor.selection()) |s| sel = .{ .from = s.from, .to = s.to };

        // The token list for THIS version. `tokens()` re-tokenizes only when the
        // buffer version moved, so this is a re-tag in the steady state and a
        // lexer pass right after an edit — never once per frame.
        const toks: []const ui.CodeToken = self.tokens() catch &[_]ui.CodeToken{};
        self.last_tokens = toks.len;

        ui.CodeView(.{
            .ctx = ctx,
            .id = "code",
            .text = self.buffer.textBytes(),
            .line_starts = self.buffer.line_starts.items,
            .tokens = toks,
            .scroll = &self.scroll,
            .caret = self.cursor.pos,
            .selection = sel,
            .width = avail.x,
            .height = code_h,
        });

        const panel = ui.draw.rect(origin.x, code_y, origin.x + avail.x, code_y + code_h);
        self.handleMouse(ctx, panel, geom);
        self.followCaret(geom.line_h, code_h);

        // ── Completion popup ───────────────────────────────────────────────
        if (self.popup_open and self.items.len > 0) {
            const at = self.caretScreenPos(panel, geom);
            var header_buf: [48]u8 = undefined;
            const header = std.fmt.bufPrint(&header_buf, "{d} matches", .{self.items.len}) catch "";
            if (ui.Completion(.{
                .ctx = ctx,
                .id = "##completion",
                .items = self.item_views.items,
                .selected = &self.popup_selected,
                .anchor = at,
                .header = header,
            })) |picked| {
                self.popup_selected = picked;
                self.acceptCompletion();
            }
        }

        // ── Footer ─────────────────────────────────────────────────────────
        const fy = code_y + code_h;
        const foot = ui.draw.rect(origin.x, fy, origin.x + avail.x, fy + footer_h);
        list.rect(foot, t.colors.surface, 0);
        list.separator(ui.draw.rect(foot.min.x, foot.min.y, foot.max.x, foot.min.y + 1), t.colors.border);

        const lc = self.buffer.lineColOfOffset(self.cursor.pos);
        var sbuf: [256]u8 = undefined;
        const status = if (self.notice.len > 0)
            std.fmt.bufPrint(&sbuf, "{s}   ·   Ln {d}, Col {d}   ·   {d} lines", .{
                self.notice, lc.line + 1, lc.col + 1, self.buffer.lineCount(),
            }) catch ""
        else
            std.fmt.bufPrint(&sbuf, "Ln {d}, Col {d}   ·   {d} lines   ·   {d} tokens   ·   {d} tokenize(s)", .{
                lc.line + 1, lc.col + 1, self.buffer.lineCount(), self.last_tokens, self.cache.builds,
            }) catch "";
        list.text(.{ .x = foot.min.x + m.panel_pad(), .y = foot.min.y + 5 }, t.colors.text_dim, status);

        // Still inside the window: see the note on `last_draw_cmds`.
        self.last_draw_cmds = ctx.drawCommands();
    }

    const Geom = struct {
        line_h: f32,
        advance: f32,
        gutter: f32,
    };

    /// The mono metrics the widget will use. Measured with the mono face pushed,
    /// exactly as `CodeView` measures them.
    fn measure(self: *Pane, ctx: *ui.Context) Geom {
        _ = self;
        var pushed = false;
        if (ctx.font_mono >= 0) {
            _ = cimgui.ember_ui_push_font(ctx.font_mono);
            pushed = true;
        }
        defer if (pushed) cimgui.ember_ui_pop_font();
        const lh = cimgui.ember_ui_text_line_height();
        const adv = ui.draw.textSize("0").x;
        return .{
            .line_h = if (lh > 1.0) lh else 14.0,
            .advance = @max(adv, 1.0),
            .gutter = 52.0,
        };
    }

    /// Places the caret and drags a selection. Uses the panel rect plus the same
    /// geometry the widget drew with, so a click lands where the user aimed.
    fn handleMouse(self: *Pane, ctx: *ui.Context, panel: cimgui.Rect, geom: Geom) void {
        const mouse = &ctx.window.input.mouse;
        const inside = mouse.x >= panel.min.x and mouse.x <= panel.max.x and
            mouse.y >= panel.min.y and mouse.y <= panel.max.y;
        if (!inside) return;
        const at = offsetAtPoint(
            self.buffer.textBytes(),
            self.buffer.line_starts.items,
            .{ .x = mouse.x, .y = mouse.y },
            panel.min,
            self.scroll,
            geom.line_h,
            geom.advance,
            geom.gutter,
            4,
        );
        if (mouse.justPressed(0)) {
            self.buffer.breakRun();
            self.cursor.moveTo(at);
            self.cursor.anchor = at;
        } else if (mouse.down(0)) {
            self.buffer.breakRun();
            self.cursor.moveTo(at);
            // A drag WITHOUT a shift claims the selection; a click that never
            // moves leaves an empty one, which `selection()` reports as null.
        } else if (mouse.justPressed(2)) {
            self.buffer.breakRun();
            self.cursor.moveTo(at);
        }
    }

    /// Keeps the caret on screen. Whole lines, because a half-scrolled editor is
    /// a screenshot nobody can read.
    fn followCaret(self: *Pane, line_h: f32, height: f32) void {
        const line = self.buffer.lineOfOffset(self.cursor.pos);
        const visible = @max(height / line_h, 1.0);
        const caret_f: f32 = @floatFromInt(line);
        if (caret_f < self.scroll) self.scroll = caret_f;
        if (caret_f >= self.scroll + visible) self.scroll = caret_f - visible + 1.0;
        self.scroll = ui.code_view.clampScroll(self.scroll, self.buffer.lineCount(), visible);
    }

    fn caretScreenPos(self: *Pane, panel: cimgui.Rect, geom: Geom) Vec2 {
        const line = self.buffer.lineOfOffset(self.cursor.pos);
        const ls = self.buffer.lineStart(line);
        const col = ui.code_view.columnAt(self.buffer.textBytes(), ls, self.cursor.pos, 4);
        return .{
            .x = panel.min.x + geom.gutter + 8.0 + @as(f32, @floatFromInt(col)) * geom.advance,
            .y = panel.min.y + (@as(f32, @floatFromInt(line)) - self.scroll + 1.0) * geom.line_h,
        };
    }

    // ── Click handlers (ImGui calls these from inside the draw) ──────────

    fn clickSave(arg: ?*anyopaque) void {
        const self: *Pane = @ptrCast(@alignCast(arg.?));
        self.request_save = true;
    }
    fn clickFormat(arg: ?*anyopaque) void {
        const self: *Pane = @ptrCast(@alignCast(arg.?));
        self.request_format = true;
    }
    fn clickUndo(arg: ?*anyopaque) void {
        const self: *Pane = @ptrCast(@alignCast(arg.?));
        self.request_undo = true;
    }
    fn clickRedo(arg: ?*anyopaque) void {
        const self: *Pane = @ptrCast(@alignCast(arg.?));
        self.request_redo = true;
    }

    /// Runs the actions a click asked for. Called OUTSIDE the draw, next frame,
    /// so no buffer mutation happens while ImGui is walking its window stack.
    pub fn applyRequests(self: *Pane) void {
        if (self.request_save) {
            self.request_save = false;
            self.save(true);
        }
        if (self.request_format) {
            self.request_format = false;
            const changed = self.formatDocument() catch false;
            self.notice = if (changed) "formatted" else "already formatted";
        }
        if (self.request_undo) {
            self.request_undo = false;
            _ = self.buffer.undo();
            self.afterEdit();
        }
        if (self.request_redo) {
            self.request_redo = false;
            _ = self.buffer.redo();
            self.afterEdit();
        }
    }
};
