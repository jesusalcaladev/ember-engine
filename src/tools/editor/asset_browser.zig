//! The asset browser — a real filesystem view of the project's assets.
//!
//! ## Why the filesystem and not the AssetManager
//!
//! `assets.AssetManager` is a *loaded-asset* cache: it knows what the running
//! game has pulled in, keyed by handle. An asset browser has to show what is on
//! DISK — including the file the artist saved ninety seconds ago and nothing has
//! imported yet. Those are different questions, and answering the first one with
//! the second is how an editor ends up with an asset browser that cannot see a
//! new file until the game reloads.
//!
//! So this walks a directory with `std.Io.Dir`, and the M6 importer will later
//! hang thumbnails and GUIDs off the same listing.
//!
//! ## The frame rule
//!
//! Scanning allocates (the names are owned, because a `Dir.Entry`'s name is only
//! valid until the iterator advances). Scanning therefore happens in
//! `refresh()`, which the editor calls OUTSIDE the allocation-guarded frame;
//! `draw()` only reads the cached list. A navigation click inside the frame just
//! writes the new path and sets `want_refresh`, so the work still lands on the
//! safe side of the guard.

const std = @import("std");
const ui = @import("ui");

const ed_mod = @import("editor_state.zig");

/// Extensions the browser treats as assets. Anything else is still shown when
/// `show_all` is on — the list is a filter, not a permission system.
const asset_extensions = [_][]const u8{
    "png",  "jpg",  "jpeg", "bmp",  "tga", "webp", "gif",
    "wav",  "ogg",  "mp3",  "flac", "lua",  "zson", "anim",
    "ttf",  "otf",  "json", "config", "atlas", "wgsl",
};

pub const AssetBrowser = struct {
    pub const Entry = struct {
        name: []u8,
        is_dir: bool,
    };

    allocator: std.mem.Allocator,

    entries: std.ArrayListUnmanaged(Entry) = .empty,
    /// The directory being shown. A buffer and not a slice: navigating must not
    /// allocate, because the click that navigates happens inside the frame.
    path: [512]u8 = undefined,
    path_len: usize = 0,
    selected: usize = 0,
    /// Set by anything that changes the directory; drained by `refresh`.
    want_refresh: bool = true,
    /// True once a scan has completed, so "empty because it failed" and "empty
    /// because it is still loading" are different pictures.
    scanned: bool = false,
    show_all: bool = false,
    /// The owning editor, set once in `Editor.init`. It is what makes the
    /// browser CONNECTED rather than a read-only listing: a double click on a
    /// `.zson` opens that scene through the editor's queued Open act.
    editor: ?*@import("editor_state.zig").Editor = null,
    /// Human-readable result of the last scan (or its failure).
    status: [160]u8 = undefined,
    status_len: usize = 0,

    pub fn init(allocator: std.mem.Allocator) AssetBrowser {
        var b = AssetBrowser{ .allocator = allocator };
        // The first directory that exists wins. `assets` is the M6 layout;
        // `samples` is what this repository ships; `.` is the honest fallback
        // for a project that has neither yet.
        const candidates = [_][]const u8{ "assets", "samples", "." };
        for (candidates) |c| {
            if (dirExists(c)) {
                b.setPath(c);
                break;
            }
        }
        if (b.path_len == 0) b.setPath(".");
        return b;
    }

    pub fn deinit(self: *AssetBrowser) void {
        self.freeEntries();
        self.entries.deinit(self.allocator);
        self.* = undefined;
    }

    fn freeEntries(self: *AssetBrowser) void {
        for (self.entries.items) |e| self.allocator.free(e.name);
        self.entries.clearRetainingCapacity();
    }

    pub fn pathSlice(self: *const AssetBrowser) []const u8 {
        return self.path[0..self.path_len];
    }

    pub fn statusSlice(self: *const AssetBrowser) []const u8 {
        return self.status[0..self.status_len];
    }

    fn setPath(self: *AssetBrowser, p: []const u8) void {
        const n = @min(p.len, self.path.len);
        @memcpy(self.path[0..n], p[0..n]);
        self.path_len = n;
        self.want_refresh = true;
    }

    fn setStatus(self: *AssetBrowser, comptime fmt: []const u8, args: anytype) void {
        const s = std.fmt.bufPrint(&self.status, fmt, args) catch blk: {
            self.status[0] = '?';
            break :blk self.status[0..1];
        };
        self.status_len = s.len;
    }

    /// Navigates into a subdirectory of the current path.
    fn pushPath(self: *AssetBrowser, name: []const u8) void {
        var buf: [512]u8 = undefined;
        const joined = std.fmt.bufPrint(&buf, "{s}/{s}", .{ self.pathSlice(), name }) catch return;
        self.setPath(joined);
    }

    /// Navigates to the parent of the current path. `..` is computed by
    /// trimming the last component rather than by joining "..": the browser
    /// shows a path the user can read, and "/a/b/.." is not that.
    fn popPath(self: *AssetBrowser) void {
        const p = self.pathSlice();
        if (std.mem.lastIndexOfScalar(u8, p, '/')) |cut| {
            if (cut == 0) return self.setPath("/");
            return self.setPath(p[0..cut]);
        }
        // A bare name ("samples"): the parent is the current directory.
        self.setPath(".");
    }

    pub fn selectedName(self: *const AssetBrowser) []const u8 {
        if (self.selected >= self.entries.items.len) return "";
        return self.entries.items[self.selected].name;
    }

    // ── Scanning (OUTSIDE the frame) ────────────────────────────────────────

    pub fn refresh(self: *AssetBrowser) void {
        self.want_refresh = false;
        self.freeEntries();
        self.selected = 0;

        const io = std.Io.Threaded.global_single_threaded.io();
        var dir = std.Io.Dir.cwd().openDir(io, self.pathSlice(), .{ .iterate = true }) catch |err| {
            self.scanned = true;
            self.setStatus("cannot open '{s}': {s}", .{ self.pathSlice(), @errorName(err) });
            return;
        };
        defer dir.close(io);

        var it = dir.iterate();
        var dirs: usize = 0;
        var files: usize = 0;
        while (it.next(io) catch null) |entry| {
            if (entry.name.len == 0) continue;
            if (entry.name[0] == '.') continue; // dotfiles are not assets
            const is_dir = entry.kind == .directory;
            if (!is_dir and !self.show_all and !isAsset(entry.name)) continue;

            // `entry.name` dies on the next `next`, so the copy is not
            // optional — and it is why this runs outside the frame.
            const name = self.allocator.dupe(u8, entry.name) catch return;
            self.entries.append(self.allocator, .{ .name = name, .is_dir = is_dir }) catch {
                self.allocator.free(name);
                return;
            };
            if (is_dir) dirs += 1 else files += 1;
        }

        std.mem.sort(Entry, self.entries.items, {}, lessEntry);
        self.scanned = true;
        self.setStatus("{d} dirs, {d} files in {s}", .{ dirs, files, self.pathSlice() });
    }

    fn lessEntry(_: void, a: Entry, b: Entry) bool {
        // Directories first, then alphabetical: the order every file list on
        // every platform has agreed on, and disagreeing with it reads as a bug.
        if (a.is_dir != b.is_dir) return a.is_dir;
        return std.mem.lessThan(u8, a.name, b.name);
    }

    // ── Drawing (INSIDE the frame) ──────────────────────────────────────────

    /// Published for the scroll body, which is a function pointer and so cannot
    /// close over the editor's state. See the shell for why Zig's lack of
    /// closures makes this the shape every panel takes.
    pub var drawing: ?*AssetBrowser = null;

    fn scrollBody(ctx: *ui.Context) void {
        drawing.?.drawRows(ctx);
    }

    pub fn drawRows(self: *AssetBrowser, ctx: *ui.Context) void {
        if (self.entries.items.len == 0) {
            ui.text.caption(ctx, if (self.scanned) "empty" else "scanning…");
            return;
        }
        var path_buf: [640]u8 = undefined;
        for (self.entries.items, 0..) |entry, i| {
            const dot: ?ui.Rgba = if (entry.is_dir) null else extensionColor(ctx, entry.name);
            // Files are drag sources: the payload is the path relative to the
            // cwd, the same one `AssetManager.getOrLoad` takes. Directories
            // navigate, they do not drag.
            const src: ?ui.list.DragSrc = if (entry.is_dir) null else blk: {
                const j = std.fmt.bufPrintZ(&path_buf, "{s}/{s}", .{ self.pathSlice(), entry.name }) catch break :blk null;
                break :blk .{
                    .kind = ed_mod.drag_kinds.file,
                    .data = path_buf[0 .. j.len + 1],
                    .preview = entry.name,
                };
            };
            const r = ui.list.row(
                .{
                    .id = entry.name,
                    .label = entry.name,
                    .icon = if (entry.is_dir) .folder else .file,
                    .trailing = if (entry.is_dir) "" else extensionOf(entry.name),
                    .dot = dot,
                    .selected = self.selected == i,
                    .drag = src,
                },
                .{ .ctx = ctx },
            );
            if (r.clicked) {
                self.selected = i;
                if (entry.is_dir) self.pushPath(entry.name);
            }
            if (r.activated) {
                if (entry.is_dir) {
                    self.pushPath(entry.name);
                } else if (std.ascii.eqlIgnoreCase(extensionOf(entry.name), "zson")) {
                    if (self.editor) |ed| {
                        var buf: [600]u8 = undefined;
                        const path = std.fmt.bufPrint(&buf, "{s}/{s}", .{ self.pathSlice(), entry.name }) catch entry.name;
                        ed.openFile(path);
                    }
                }
            }
        }
    }

    pub fn draw(self: *AssetBrowser, ctx: *ui.Context) void {
        const t = &ctx.theme;
        drawing = self;

        // Header: where we are, then the navigation controls on the right.
        ui.text.caption(ctx, self.pathSlice());
        if (ui.button.icon(.{ .ctx = ctx, .id = "ab.up", .icon = .chevron_up, .variant = .icon, .tooltip = "Parent directory" })) {
            self.popPath();
        }
        ui.cimgui.ember_ui_same_line(0, t.metrics.gap());
        if (ui.button.icon(.{ .ctx = ctx, .id = "ab.re", .icon = .refresh, .variant = .icon, .tooltip = "Rescan" })) {
            self.want_refresh = true;
        }
        ui.cimgui.ember_ui_same_line(0, t.metrics.gap());
        var all = self.show_all;
        if (ui.toggle.checkbox(.{ .ctx = ctx, .id = "ab.all", .label = "all files", .value = &all })) {
            self.show_all = all;
            self.want_refresh = true;
        }

        ui.layout.space(ctx, 1);
        // A negative height means "the rest of the panel", which is what a list
        // filling a dock wants and what keeps the status line pinned below it.
        _ = ui.list.scrollable(ctx, "ab.scroll", -34, scrollBody);

        ui.layout.space(ctx, 1);
        // The browser's one action button, for the one kind of asset a click
        // can already turn into something in the scene: an image becomes a
        // sprite entity (loaded, packed, uploaded — the Lua-API path). Scenes
        // open by double click; scripts and audio wait on their own importers.
        if (self.selectedImageSlice().len > 0) {
            if (ui.Button(.{
                .ctx = ctx,
                .id = "ab.spawn",
                .text = "Spawn Sprite",
                .icon = .plus,
                .variant = .primary,
                .width = @max(ui.draw.contentAvail().x, 1),
            })) {
                if (self.editor) |ed| {
                    var buf: [600]u8 = undefined;
                    const path = std.fmt.bufPrint(&buf, "{s}/{s}", .{ self.pathSlice(), self.selectedImageSlice() }) catch "";
                    if (path.len > 0) ed.requestSpawnSprite(path);
                }
            }
        }
        ui.text.caption(ctx, self.statusSlice());
    }

    /// The name of the selected entry when it is an image the pipeline can
    /// decode, else empty. Kept a read on THIS struct so the draw body above
    /// stays a row of widget calls.
    fn selectedImageSlice(self: *const AssetBrowser) []const u8 {
        if (self.selected >= self.entries.items.len) return "";
        const name = self.entries.items[self.selected].name;
        if (self.entries.items[self.selected].is_dir) return "";
        const ext = extensionOf(name);
        inline for (.{ "png", "jpg", "jpeg", "bmp", "tga", "webp" }) |img| {
            if (std.ascii.eqlIgnoreCase(ext, img)) return name;
        }
        return "";
    }
};

fn isAsset(name: []const u8) bool {
    const ext = extensionOf(name);
    for (asset_extensions) |known| {
        if (std.ascii.eqlIgnoreCase(ext, known)) return true;
    }
    return false;
}

fn extensionOf(name: []const u8) []const u8 {
    const dot = std.mem.lastIndexOfScalar(u8, name, '.') orelse return "";
    return name[dot + 1 ..];
}

/// A colour coding by kind, so a list of filenames can be scanned by
/// silhouette: images green, audio blue, code accent, data dim. It is a
/// hint, not information — the extension is still on the row.
fn extensionColor(ctx: *ui.Context, name: []const u8) ?ui.Rgba {
    const ext = extensionOf(name);
    const c = ctx.theme.colors;
    if (std.ascii.eqlIgnoreCase(ext, "png") or std.ascii.eqlIgnoreCase(ext, "jpg") or
        std.ascii.eqlIgnoreCase(ext, "jpeg") or std.ascii.eqlIgnoreCase(ext, "webp") or
        std.ascii.eqlIgnoreCase(ext, "bmp") or std.ascii.eqlIgnoreCase(ext, "tga")) return c.success;
    if (std.ascii.eqlIgnoreCase(ext, "wav") or std.ascii.eqlIgnoreCase(ext, "ogg") or
        std.ascii.eqlIgnoreCase(ext, "mp3") or std.ascii.eqlIgnoreCase(ext, "flac")) return c.accent_text;
    if (std.ascii.eqlIgnoreCase(ext, "lua")) return c.warning;
    return null;
}

fn dirExists(path: []const u8) bool {
    const io = std.Io.Threaded.global_single_threaded.io();
    var dir = std.Io.Dir.cwd().openDir(io, path, .{}) catch return false;
    dir.close(io);
    return true;
}

const testing = std.testing;

test "asset browser: extension parsing" {
    try testing.expectEqualStrings("png", extensionOf("hero.png"));
    try testing.expectEqualStrings("zson", extensionOf("a/b/scene.zson"));
    try testing.expectEqualStrings("", extensionOf("Makefile"));
    try testing.expect(isAsset("hero.PNG"));
    try testing.expect(isAsset("music.ogg"));
    try testing.expect(!isAsset("main.zig"));
}
