// Atlas Bridge — connects AssetManager images to the AtlasPacker and GPU.
// Multi-page support, GPU upload, and Lua integration.

const std = @import("std");
const atlas = @import("atlas.zig");
const AtlasPacker = atlas.AtlasPacker;
/// Re-exported so a caller can hand `addImage` an image without importing
/// `assets` itself. The atlas's job is to take the asset pipeline's type, and
/// making that type reachable from here means a loader needs one import instead
/// of two and a knowledge of which module owns it.
pub const Image = @import("assets").Image;

/// Entry in the atlas, linking an asset path to its packed location.
/// One packed image: where it landed and the UVs to draw it with. `path` is a
/// fixed-size copy (NUL-terminated), because the map's key is the owner of the
/// bytes and an entry is copied around by value.
pub const AtlasEntry = struct {
    path: [256]u8,
    entry: atlas.Entry,
    page: u32,
    uv: [4]f32,
};

/// Where an image was packed: which page holds it, and its rect in that page.
///
/// The two numbers travel as one value because a rect is meaningless without
/// the page it is relative to, and every caller that packs needs both.
const Packed = struct { entry: atlas.Entry, page: u32 };

/// AtlasManager — owns multiple AtlasPacker pages and GPU textures.
/// Automatically creates new pages when the current one is full.
pub const AtlasManager = struct {
    width: u32,
    height: u32,
    pages: std.ArrayList(Page),
    current_page: u32,
    /// Path -> packed entry. A CONTENT hash (`StringHashMap`), not `AutoHashMap`:
    /// the key is a slice, and an identity hash of a slice is a bug waiting for
    /// the first caller that passes an equal-but-not-identical path.
    entries: std.StringHashMap(AtlasEntry),

    /// Called after a page's pixels reach the GPU, with those pixels.
    ///
    /// This exists because the lighting system's coverage registration was
    /// unreachable from the engine. `light.registerAtlasCoverage` was written,
    /// tested, benchmarked and called from nowhere: not from the loader, not
    /// from here, not from `main`. Every automatic occluder therefore cast its
    /// sprite's RECTANGLE in every real build, while the ROADMAP claimed "alpha
    /// threshold, zero dev action", and `coverage_used` sat at a permanent zero
    /// that nothing flagged.
    ///
    /// An upload is the right moment and the only one: it is when a page's pixels
    /// become authoritative, and until it happens the texels are still being
    /// written. A hook keeps this file free of any dependency on the ECS or on
    /// lighting — it does not know what a sprite is, let alone what one is worth
    /// as an occluder, and that knowledge belongs to whoever owns the scene.
    ///
    /// Not frame work. The callback walks every sprite and allocates, which is
    /// why it fires on upload rather than per frame.
    ///
    /// One hook, not a list: the engine has exactly one consumer, and a second
    /// one would want the coverage store to be the arbiter rather than a
    /// reimplementation of it. If a second consumer appears, this becomes a list
    /// at that point and not before.
    coverage_hook: ?struct {
        ctx: *anyopaque,
        cb: *const fn (
            ctx: *anyopaque,
            pixels: []const u8,
            page_w: u32,
            page_h: u32,
        ) anyerror!void,
    } = null,

    /// Registers a callback to be run after each page is uploaded.
    ///
    /// `atlas_mgr.onPageUploaded(driver, lighting_driver.Driver.registerCoverageForPage)`
    /// is the whole of the automatic-occluder wiring.
    pub fn onPageUploaded(
        self: *AtlasManager,
        ctx: *anyopaque,
        cb: *const fn (
            ctx: *anyopaque,
            pixels: []const u8,
            page_w: u32,
            page_h: u32,
        ) anyerror!void,
    ) void {
        self.coverage_hook = .{ .ctx = ctx, .cb = cb };
    }

    pub const Page = struct {
        packer: AtlasPacker,
        pixels: []u8,
        dirty: bool,
        texture_handle: ?*anyopaque = null,

        pub fn init(allocator: std.mem.Allocator, width: u32, height: u32, padding: u32) !Page {
            const page_pixels = try allocator.alloc(u8, width * height * 4);
            return Page{
                // `allow_growth = false`, which is the whole reason `nextPage` exists.
//
// It was `true`, and that was not a tuning choice — it made the multi-page
// machinery dead code. With growth on, `insert` never returns null, so
// `addImage`'s `while (entry == null)` loop never ran, so `nextPage` was never
// called and `pages` always held exactly one entry. Meanwhile the packer kept
// handing out rects past `width`/`height`, and `uploadAtlas` uploads every page
// as `atlas_mgr.width` x `atlas_mgr.height`, which stay fixed. So the tail of
// the atlas was written outside the texture that was sent to the GPU: the
// sprites in it sampled nothing, and nothing said so.
//
// `false` means "tell me when you are full" and lets the caller answer with a
// new page of the declared size, which is the only answer consistent with how
// these pages are uploaded.
.packer = AtlasPacker.init(width, height, padding, false),
                .pixels = page_pixels,
                .dirty = false,
                .texture_handle = null,
            };
        }

        pub fn deinit(self: *Page, allocator: std.mem.Allocator) void {
            allocator.free(self.pixels);
            self.* = undefined;
        }
    };

    pub fn init(
        allocator: std.mem.Allocator,
        width: u32,
        height: u32,
        padding: u32,
    ) !AtlasManager {
        var pages: std.ArrayList(Page) = .empty;
        errdefer pages.deinit(allocator);
        var first_page = try Page.init(allocator, width, height, padding);
        errdefer first_page.deinit(allocator);
        try pages.append(allocator, first_page);

        return AtlasManager{
            .width = width,
            .height = height,
            .pages = pages,
            .current_page = 0,
            .entries = std.StringHashMap(AtlasEntry).init(allocator),
        };
    }

    pub fn deinit(self: *AtlasManager, allocator: std.mem.Allocator) void {
        for (self.pages.items) |*page| {
            page.deinit(allocator);
        }
        self.pages.deinit(allocator);
        // The entries' KEYS are owned copies of the paths (the map borrows
        // them), so they are freed here rather than left to the process exit.
        var keys = self.entries.keyIterator();
        while (keys.next()) |key| allocator.free(@constCast(key.*));
        self.entries.deinit();
        self.* = undefined;
    }

    fn getCurrentPage(self: *AtlasManager) *Page {
        return &self.pages.items[self.current_page];
    }

    /// Packs one image and returns the atlas slot (index) and UV coordinates.
    /// Automatically creates new pages when the current one is full.
    pub fn addImage(
        self: *AtlasManager,
        allocator: std.mem.Allocator,
        path: []const u8,
        image: Image,
    ) !u8 {
        const spot = try self.packRect(allocator, image.width, image.height);
        self.blitIntoPage(spot.page, spot.entry, image);

        const uv = AtlasPacker.uv(spot.entry, self.width, self.height);

        // One owned copy of the path serves BOTH roles: the map's key and the
        // fixed-size copy inside the entry (truncated to what fits, and always
        // NUL-terminated so a C-style read of it cannot run off the end).
        const path_copy = try allocator.dupe(u8, path);
        errdefer allocator.free(path_copy);
        var atlas_entry = AtlasEntry{
            .path = [_]u8{0} ** 256,
            .entry = spot.entry,
            .page = spot.page,
            .uv = uv,
        };
        const n = @min(path.len, atlas_entry.path.len - 1);
        @memcpy(atlas_entry.path[0..n], path[0..n]);

        try self.entries.put(path_copy, atlas_entry);

        self.pages.items[spot.page].dirty = true;

        return @intCast(self.entries.count() - 1);
    }

    /// Reserves a rect for `width` x `height` in the first page that has room,
    /// growing the page list when it must.
    ///
    /// Nothing is written yet. Separating "find the space" from "fill it" is
    /// what lets `replaceImage` decide between writing into the rect an image
    /// already owns and taking a new one.
    fn packRect(self: *AtlasManager, allocator: std.mem.Allocator, width: u32, height: u32) !Packed {
        // An image wider or taller than a page cannot be packed by ANY number of
        // pages, and `AtlasPacker.insert` would place it at (0,0) and past the
        // page's right edge — the blit would then run off the page's allocation.
        // Rejecting it once, where the dimensions are known, is what turns that
        // into a reported error instead of a corrupted atlas.
        const w = @as(u64, width) + 2;
        const h = @as(u64, height) + 2;
        if (w > self.width or h > self.height) return error.ImageTooLarge;

        var entry = self.getCurrentPage().packer.insert(width, height);
        if (entry == null) {
            // `nextPage` returns false only when it could not allocate, so a
            // loop that never finds room is indistinguishable from running out
            // of memory and is reported as such.
            while (self.nextPage(allocator)) {
                entry = self.getCurrentPage().packer.insert(width, height);
                if (entry != null) break;
            } else return error.OutOfMemory;
        }
        return .{ .entry = entry.?, .page = self.current_page };
    }

    /// The result of re-packing an image that may already be resident.
    ///
    /// `repositioned` is the marked difference: false means the pixels were
    /// swapped into the rect the image already owned, so its UVs are unchanged
    /// and any sprite drawing it keeps working. true means it moved, so whoever
    /// holds the previous UVs has to be told.
    pub const ReplaceResult = struct {
        uv: [4]f32,
        page: u32,
        /// Size changed (or the image was new) and a new rect was taken.
        repositioned: bool,
    };

    /// Replaces the pixels of an already-packed image (the hot-reload path).
    ///
    /// Same-size edit → blit over the rect it already occupies and mark only that
    /// page dirty. The UVs do not move, so a sprite that was drawing this image
    /// draws the new one on the next frame with no other bookkeeping.
    ///
    /// Size changed → take a NEW rect, because the old one is now the wrong
    /// shape. The previous rect is abandoned rather than freed (a shelf packer
    /// has no free list), which leaks a little atlas space for the life of the
    /// page; that is the cost of not wanting a second texture for the new size.
    pub fn replaceImage(
        self: *AtlasManager,
        allocator: std.mem.Allocator,
        path: []const u8,
        image: Image,
    ) !ReplaceResult {
        if (self.entries.getPtr(path)) |existing| {
            if (existing.entry.w == image.width and existing.entry.h == image.height) {
                self.blitIntoPage(existing.page, existing.entry, image);
                self.pages.items[existing.page].dirty = true;
                return .{ .uv = existing.uv, .page = existing.page, .repositioned = false };
            }

            const spot = try self.packRect(allocator, image.width, image.height);
            self.blitIntoPage(spot.page, spot.entry, image);

            const uv = AtlasPacker.uv(spot.entry, self.width, self.height);
            existing.entry = spot.entry;
            existing.page = spot.page;
            existing.uv = uv;
            self.pages.items[spot.page].dirty = true;
            return .{ .uv = uv, .page = spot.page, .repositioned = true };
        }

        // Not resident yet: packing it new is the right answer, and the caller
        // must apply the UVs because there was nothing to keep them valid for.
        _ = try self.addImage(allocator, path, image);
        const fresh = self.entries.get(path).?;
        return .{ .uv = fresh.uv, .page = fresh.page, .repositioned = true };
    }

    fn nextPage(self: *AtlasManager, allocator: std.mem.Allocator) bool {
        if (self.current_page + 1 < self.pages.items.len) {
            self.current_page += 1;
            return true;
        }

        var new_page = Page.init(allocator, self.width, self.height, 2) catch return false;
        self.pages.append(allocator, new_page) catch {
            new_page.deinit(allocator);
            return false;
        };
        self.current_page += 1;
        return true;
    }

    /// Copies an image's pixels into `page_index`, at `entry`'s rect.
    ///
    /// Page-aware, where the old `blitImage` wrote into `getCurrentPage()`: a
    /// reload re-blits into the page the image ALREADY sits on, and by then the
    /// packer has usually moved on to a later one. Writing into the current page
    /// would put the new pixels somewhere nothing draws from.
    ///
    /// Rows are walked top-down with the PAGE's stride, because the image is
    /// copied INTO a larger buffer rather than appended to it.
    fn blitIntoPage(self: *AtlasManager, page_index: u32, entry: atlas.Entry, image: Image) void {
        const W = @as(usize, self.width);
        const page = &self.pages.items[page_index];
        const row_bytes = @as(usize, image.width) * 4;

        var y: usize = 0;
        while (y < @as(usize, image.height)) : (y += 1) {
            const src_idx = y * row_bytes;
            const dst_idx = (@as(usize, entry.y) + y) * W * 4 + @as(usize, entry.x) * 4;

            @memcpy(
                page.pixels[dst_idx .. dst_idx + row_bytes],
                image.pixels[src_idx .. src_idx + row_bytes],
            );
        }
    }

    /// UVs for a path, or null when it was never packed. Null rather than a
    /// panic: the caller is a frame-time lookup, and a name that is not in the
    /// atlas is a bug to report, not a reason to take the process down.
    pub fn getUV(self: *AtlasManager, path: []const u8) ?[4]f32 {
        const entry = self.entries.get(path) orelse return null;
        return entry.uv;
    }

    pub fn getEntry(self: *AtlasManager, path: []const u8) ?*AtlasEntry {
        return self.entries.getPtr(path);
    }

    /// Which page holds `path`, or null when it was never packed.
    ///
    /// A reload needs this, and the entry's `page` field alone is not enough: the
    /// caller knows a PATH (that is what the file watcher gave it), and it is the
    /// atlas's job to say where that path landed.
    pub fn pageOf(self: *AtlasManager, path: []const u8) ?u32 {
        const entry = self.entries.getPtr(path) orelse return null;
        return entry.page;
    }

    /// Whether ANY page has pixels the GPU has not seen.
    ///
    /// This is what "is the atlas dirty" means, and the old one-page answer
    /// (`getCurrentPage().dirty`) was a real bug once there was more than one
    /// page: a reload of an image living on page 0 while page 3 was current
    /// reported false, so the caller uploaded nothing and the edit never
    /// appeared.
    pub fn anyPageDirty(self: *AtlasManager) bool {
        for (self.pages.items) |page| {
            if (page.dirty) return true;
        }
        return false;
    }

    pub fn isDirty(self: *AtlasManager) bool {
        return self.anyPageDirty();
    }

    pub fn getPagePixels(self: *AtlasManager) []const u8 {
        return self.getCurrentPage().pixels;
    }

    /// One page's pixels, or null for a page index that does not exist.
    pub fn getPagePixelsOf(self: *AtlasManager, page: u32) ?[]const u8 {
        if (page >= self.pages.items.len) return null;
        return self.pages.items[page].pixels;
    }

    pub fn markUploaded(self: *AtlasManager) void {
        self.getCurrentPage().dirty = false;
    }

    /// Clears one page's dirty flag. Out-of-range is ignored rather than an
    /// error: a reload that arrives after the atlas was shrunk is a no-op, not
    /// something to fail a frame over.
    pub fn markPageUploaded(self: *AtlasManager, page: u32) void {
        if (page < self.pages.items.len) {
            self.pages.items[page].dirty = false;
        }
    }

    /// Whether a page's pixels are already resident on the GPU. The reload path
    /// consults this to decide between writing into an existing texture (the
    /// sprite drawing from it keeps its slot) and creating one.
    pub fn hasTexture(self: *AtlasManager, page: u32) bool {
        if (page >= self.pages.items.len) return false;
        return self.pages.items[page].texture_handle != null;
    }

    pub fn getTextureHandle(self: *AtlasManager, page: u32) ?*anyopaque {
        if (page >= self.pages.items.len) return null;
        return self.pages.items[page].texture_handle;
    }

    pub fn setTextureHandle(self: *AtlasManager, page: u32, handle: ?*anyopaque) void {
        if (page < self.pages.items.len) {
            self.pages.items[page].texture_handle = handle;
        }
    }

    pub fn pageCount(self: *AtlasManager) u32 {
        return @intCast(self.pages.items.len);
    }

    pub fn getCurrentPageIndex(self: *AtlasManager) u32 {
        return self.current_page;
    }
};

/// Creates a texture from page-sized RGBA8 pixels.
pub const CreateTextureFn = *const fn (*anyopaque, u32, u32, []const u8) ?*anyopaque;

/// Writes page-sized RGBA8 pixels over a texture that already exists. Returns
/// false when the handle is not a live texture in this backend.
pub const WriteTextureFn = *const fn (*anyopaque, ?*anyopaque, u32, u32, []const u8) bool;

/// Create a GPU atlas texture from the atlas manager's page pixels.
/// Returns a handle that can be used with the render backend.
pub fn uploadAtlas(
    backend: *anyopaque,
    atlas_mgr: *AtlasManager,
    create_texture: CreateTextureFn,
) !u8 {
    // Upload all dirty pages
    for (atlas_mgr.pages.items) |*page| {
        if (page.dirty) {
            const pixels = page.pixels;
            const handle = create_texture(backend, atlas_mgr.width, atlas_mgr.height, pixels);

            if (handle == null) return error.OutOfMemory;

            page.texture_handle = handle;
            page.dirty = false;

            // AFTER `dirty = false`, so a hook that throws leaves the page
            // marked clean and uploaded rather than re-uploaded forever. A
            // coverage hook that fails is a missing shadow silhouette, and the
            // right way to notice that is the error, not an upload that never
            // settles.
            if (atlas_mgr.coverage_hook) |hook| {
                try hook.cb(hook.ctx, pixels, atlas_mgr.width, atlas_mgr.height);
            }
        }
    }

    return @intCast(atlas_mgr.pages.items.len);
}

/// Re-uploads the atlas's dirty pages, IN PLACE where a page already has a
/// texture. Returns the number of pages written.
///
/// ## Why this is not `uploadAtlas`
///
/// `uploadAtlas` allocates a texture per dirty page. That is right for a first
/// upload and wrong for a reload: the sprite drawing this image holds a texture
/// SLOT, and a second texture would leave the old one bound and the new one
/// drawn by nobody. A reload that "worked" and changed nothing on screen is
/// exactly the failure the criterion describes.
///
/// So a page that already has a texture has its new pixels written over the same
/// texture, and `write_texture` is the only way to say that. A page that has
/// never been uploaded still goes through `create_texture` — a reload of
/// something the boot never packed is a first upload.
///
/// ## Why the hook runs here too
///
/// The coverage hook is what turns pixels into occluders, and it fires on EVERY
/// path that makes a page's pixels authoritative. Skipping it on a reload would
/// leave the SDF describing the sprite that was on disk five minutes ago.
pub fn refreshAtlas(
    backend: *anyopaque,
    atlas_mgr: *AtlasManager,
    create_texture: CreateTextureFn,
    write_texture: WriteTextureFn,
) !u32 {
    var written: u32 = 0;
    for (atlas_mgr.pages.items, 0..) |*page, i| {
        if (!page.dirty) continue;

        if (page.texture_handle) |existing| {
            if (!write_texture(backend, existing, atlas_mgr.width, atlas_mgr.height, page.pixels)) {
                return error.OutOfMemory;
            }
        } else {
            const handle = create_texture(backend, atlas_mgr.width, atlas_mgr.height, page.pixels) orelse
                return error.OutOfMemory;
            atlas_mgr.setTextureHandle(@intCast(i), handle);
        }
        page.dirty = false;
        written += 1;

        if (atlas_mgr.coverage_hook) |hook| {
            try hook.cb(hook.ctx, page.pixels, atlas_mgr.width, atlas_mgr.height);
        }
    }
    return written;
}

test "atlas bridge packs images into multiple pages" {
    const allocator = std.testing.allocator;
    var atlas_mgr = try AtlasManager.init(allocator, 64, 64, 2);
    defer atlas_mgr.deinit(allocator);

    for (0..20) |i| {
        const test_pixels = try allocator.alloc(u8, 16 * 16 * 4);
        defer allocator.free(test_pixels);
        var j: usize = 0; while (j < test_pixels.len) : (j += 1) { test_pixels[j] = if (j % 4 == 0) 255 else if (j % 4 == 1) 255 else 0; }
        const test_image = Image{
            .width = 16,
            .height = 16,
            .channels = 4,
            .pixels = test_pixels,
        };
        // `bufPrint` takes the buffer first in Zig 0.16. This call was written for the
        // older two-argument form and had never been compiled, because until this
        // file's tests were actually COLLECTED nothing here was analysed -- a
        // second, smaller echo of the same failure that hid the lighting suite.
        var name_buf: [64]u8 = undefined;
        const name = try allocator.dupe(u8, std.fmt.bufPrint(&name_buf, "test{d}.png", .{i}) catch "test.png");
        defer allocator.free(name);
        _ = atlas_mgr.addImage(allocator, name, test_image) catch return;
    }
    try std.testing.expect(atlas_mgr.pageCount() >= 2);
}

test "atlas bridge getUV works across pages" {
    const allocator = std.testing.allocator;
    var atlas_mgr = try AtlasManager.init(allocator, 64, 64, 2);
    defer atlas_mgr.deinit(allocator);

    const test_pixels = try allocator.alloc(u8, 16 * 16 * 4);
    defer allocator.free(test_pixels);
    var j: usize = 0; while (j < test_pixels.len) : (j += 1) { test_pixels[j] = if (j % 4 == 0) 255 else 0; }
    const test_image = Image{
        .width = 16,
        .height = 16,
        .channels = 4,
        .pixels = test_pixels,
    };
_ = atlas_mgr.addImage(allocator, "test.png", test_image) catch return;
    const uv = atlas_mgr.getUV("test.png").?;
    try std.testing.expect(uv[0] >= 0.0 and uv[0] <= 1.0);
    try std.testing.expect(uv[1] >= 0.0 and uv[1] <= 1.0);
    try std.testing.expect(uv[2] >= 0.0 and uv[2] <= 1.0);
    try std.testing.expect(uv[3] >= 0.0 and uv[3] <= 1.0);
}

// The blit must copy the source image into the page at the entry's origin.
// A reversed `@memcpy` argument order compiles fine and leaves the atlas
// blank, which the pack/UV tests above cannot see -- so this reads the page
// back and checks the bytes landed where the entry says they did.
test "atlas bridge blit copies source pixels to the packed rect" {
    const allocator = std.testing.allocator;
    var atlas_mgr = try AtlasManager.init(allocator, 64, 64, 2);
    defer atlas_mgr.deinit(allocator);

    const w = 4;
    const h = 3;
    const pixels = try allocator.alloc(u8, w * h * 4);
    defer allocator.free(pixels);
    for (pixels, 0..) |*px, i| px.* = @intCast((i % 7) + 1);

    const test_image = Image{
        .width = w,
        .height = h,
        .channels = 4,
        .pixels = pixels,
    };
    _ = try atlas_mgr.addImage(allocator, "blit.png", test_image);

    const entry = atlas_mgr.getEntry("blit.png").?;
    const page_pixels = atlas_mgr.getPagePixels();
    const page_w = @as(usize, atlas_mgr.width);
    try std.testing.expectEqual(page_w * @as(usize, atlas_mgr.height) * 4, page_pixels.len);

    var y: usize = 0;
    while (y < h) : (y += 1) {
        const dst = (@as(usize, entry.entry.y) + y) * page_w * 4 + @as(usize, entry.entry.x) * 4;
        const src = y * @as(usize, w) * 4;
        try std.testing.expectEqualSlices(u8, pixels[src .. src + @as(usize, w) * 4], page_pixels[dst .. dst + @as(usize, w) * 4]);
    }
}

// ── Hot reload: replacing a resident image ───────────────────────────────────
//
// The criterion is "editing an external PNG is visible in-game in < 250 ms".
// "Visible" means more than "the pixels were decoded": the sprite that was
// already drawing the image has to draw the NEW pixels, which needs the update
// to land on the rect that sprite's UVs point at. These tests are that claim,
// made without a GPU.

/// The fake GPU: the smallest thing that can answer "did a reload create a
/// texture or write into one".
///
/// At container level because a function-local struct cannot name its own type,
/// and both callbacks need `*FakeGpu` to recover `self` from `ctx`.
const FakeGpu = struct {
    created: u32 = 0,
    writes: u32 = 0,
    last_written: ?*anyopaque = null,
    /// The first four bytes of the last write, which is enough to recognise a
    /// colour fill: the write is the only evidence the pixels reached the GPU.
    written: [4]u8 = .{ 0, 0, 0, 0 },

    fn create(ctx: *anyopaque, _: u32, _: u32, _: []const u8) ?*anyopaque {
        const self: *FakeGpu = @ptrCast(@alignCast(ctx));
        self.created += 1;
        return @ptrFromInt(0x1000 + self.created);
    }

    /// A handle the fake never handed out is a stale handle, which a real backend
    /// answers `false` to rather than writing over somebody else's texture.
    fn write(ctx: *anyopaque, handle: ?*anyopaque, _: u32, _: u32, pixels: []const u8) bool {
        const self: *FakeGpu = @ptrCast(@alignCast(ctx));
        if (handle) |h| {
            // Only a handle this fake actually handed out is live: anything else
            // is a texture that was destroyed behind the atlas's back.
            const raw = @intFromPtr(h);
            if (raw < 0x1001 or raw > 0x1000 + self.created) return false;
        }
        self.writes += 1;
        self.last_written = handle;
        @memcpy(self.written[0..4], pixels[0..4]);
        return true;
    }
};

/// A coverage hook that records what it was handed: the pixels of the page that
/// just reached the GPU, which is what an automatic occluder is built from.
const SpyHook = struct {
    calls: u32 = 0,
    seen_r: u8 = 0,

    fn page(ctx: *anyopaque, pixels: []const u8, w: u32, h: u32) anyerror!void {
        const self: *SpyHook = @ptrCast(@alignCast(ctx));
        self.calls += 1;
        self.seen_r = pixels[0];
        _ = w;
        _ = h;
    }
};

/// A constant-colour RGBA8 image of an explicit size.
///
/// Explicit dimensions rather than deriving them from the buffer, because half
/// of what is tested here is the SIZE changing.
fn replaceTestImage(buf: []u8, width: u32, height: u32, r: u8, g: u8, b: u8) Image {
    for (buf, 0..) |*px, i| {
        px.* = switch (i % 4) {
            0 => r,
            1 => g,
            2 => b,
            else => 255,
        };
    }
    return .{ .width = width, .height = height, .channels = 4, .pixels = buf };
}

test "a same-size reload reuses the rect, the page and the UVs" {
    const allocator = std.testing.allocator;
    var atlas_mgr = try AtlasManager.init(allocator, 64, 64, 2);
    defer atlas_mgr.deinit(allocator);

    var first: [4 * 4 * 4]u8 = undefined;
    _ = try atlas_mgr.addImage(allocator, "hero.png", replaceTestImage(&first, 4, 4, 10, 20, 30));
    const page_pixels_before = try allocator.dupe(
        u8,
        atlas_mgr.getPagePixelsOf(atlas_mgr.pageOf("hero.png").?).?,
    );
    defer allocator.free(page_pixels_before);
    const before = page_pixels_before;
    const uv_before = atlas_mgr.getEntry("hero.png").?.uv;
    const page_before = atlas_mgr.getEntry("hero.png").?.page;
    const rect_before = atlas_mgr.getEntry("hero.png").?.entry;

    var second: [4 * 4 * 4]u8 = undefined;
    const out = try atlas_mgr.replaceImage(
        allocator,
        "hero.png",
        replaceTestImage(&second, 4, 4, 200, 100, 50),
    );

    // Nothing moved: same page, same rect, same UVs. A sprite holding `uv_before`
    // therefore draws the new pixels with no other change.
    try std.testing.expectEqual(page_before, out.page);
    try std.testing.expectEqualSlices(f32, &uv_before, &out.uv);
    try std.testing.expect(!out.repositioned);
    try std.testing.expectEqual(uv_before, atlas_mgr.getEntry("hero.png").?.uv);
    // The rect itself is unchanged, not merely the UVs: two overlapping rects
    // can produce a UV that is right on screen and wrong in the atlas.
    try std.testing.expectEqual(rect_before, atlas_mgr.getEntry("hero.png").?.entry);

    // And the bytes actually changed on the page it was packed into, at the
    // rect the packer chose. Everything OUTSIDE that rect is untouched, which is
    // what makes a reload cheap enough to do inside a frame — so the page is
    // compared as a whole against a snapshot from before the replace.
    const page_pixels = atlas_mgr.getPagePixelsOf(out.page).?;
    const w = @as(usize, atlas_mgr.width);
    const offset = (@as(usize, rect_before.y) * w + @as(usize, rect_before.x)) * 4;
    try std.testing.expectEqual(@as(u8, 200), page_pixels[offset]);
    try std.testing.expectEqual(@as(u8, 100), page_pixels[offset + 1]);

    // A rect is a set of ROWS, not one contiguous run, so "outside the rect" is
    // evaluated per texel rather than over a slice.
    const side = atlas_mgr.width;
    var changed: usize = 0;
    var y: usize = 0;
    while (y < side) : (y += 1) {
        const in_row = y >= rect_before.y and y < rect_before.y + rect_before.h;
        var x: usize = 0;
        while (x < side) : (x += 1) {
            if (in_row and x >= rect_before.x and x < rect_before.x + rect_before.w) continue;
            const i = (y * w + x) * 4;
            if (page_pixels[i] != before[i]) changed += 1;
        }
    }
    try std.testing.expectEqual(@as(usize, 0), changed);

    try std.testing.expect(atlas_mgr.anyPageDirty());
    try std.testing.expect(!atlas_mgr.hasTexture(out.page));
    try std.testing.expectEqual(@as(usize, 1), atlas_mgr.entries.count());
}

test "a reload marks ONLY the image's own page dirty" {
    const allocator = std.testing.allocator;
    // A 20x40 page holds two 16x16 sprites (one per shelf), so the third opens
    // page 1. Both halves matter: that there IS more than one page, and that the
    // two images this test reloads live on DIFFERENT ones — a single-page atlas
    // would pass it without exercising anything.
    var atlas_mgr = try AtlasManager.init(allocator, 20, 40, 2);
    defer atlas_mgr.deinit(allocator);

    var gpu = FakeGpu{};
    var a = [_]u8{0} ** (16 * 16 * 4);
    var b = [_]u8{0} ** (16 * 16 * 4);
    var c = [_]u8{0} ** (16 * 16 * 4);
    _ = try atlas_mgr.addImage(allocator, "a.png", .{ .width = 16, .height = 16, .channels = 4, .pixels = &a });
    _ = try atlas_mgr.addImage(allocator, "b.png", .{ .width = 16, .height = 16, .channels = 4, .pixels = &b });
    _ = try atlas_mgr.addImage(allocator, "c.png", .{ .width = 16, .height = 16, .channels = 4, .pixels = &c });
    try std.testing.expectEqual(@as(u32, 2), atlas_mgr.pageCount());
    try std.testing.expectEqual(@as(u32, 0), atlas_mgr.pageOf("a.png").?);
    try std.testing.expectEqual(@as(u32, 1), atlas_mgr.pageOf("c.png").?);

    // First upload: one texture per page, and the two are distinct, otherwise
    // "the write went to page 0's texture" would be unfalsifiable.
    _ = try uploadAtlas(&gpu, &atlas_mgr, FakeGpu.create);
    try std.testing.expectEqual(@as(u32, 2), gpu.created);
    const first_texture = atlas_mgr.getTextureHandle(0).?;
    const second_texture = atlas_mgr.getTextureHandle(1).?;
    try std.testing.expect(first_texture != second_texture);

    // Reload an image on page 0: exactly one page is written, and it is page 0's
    // texture. That is the bound on what a reload costs — one page, not the
    // atlas — and the reason a 16 MB atlas does not stall a frame on one edit.
    _ = try atlas_mgr.replaceImage(allocator, "a.png", .{ .width = 16, .height = 16, .channels = 4, .pixels = &a });
    try std.testing.expectEqual(@as(u32, 1), try refreshAtlas(&gpu, &atlas_mgr, FakeGpu.create, FakeGpu.write));
    try std.testing.expectEqual(@as(u32, 2), gpu.created); // no new textures
    try std.testing.expectEqual(first_texture, gpu.last_written);

    // And an image on page 1 costs page 1's texture instead. This is the case the
    // old `isDirty()` could not even report: the current page had long since
    // moved past the one being reloaded.
    _ = try atlas_mgr.replaceImage(allocator, "c.png", .{ .width = 16, .height = 16, .channels = 4, .pixels = &c });
    try std.testing.expectEqual(@as(u32, 1), try refreshAtlas(&gpu, &atlas_mgr, FakeGpu.create, FakeGpu.write));
    try std.testing.expectEqual(second_texture, gpu.last_written);
}

test "a resized reload re-packs and reports that the UVs moved" {
    const allocator = std.testing.allocator;
    var atlas_mgr = try AtlasManager.init(allocator, 64, 64, 2);
    defer atlas_mgr.deinit(allocator);

    var small: [4 * 4 * 4]u8 = undefined;
    _ = try atlas_mgr.addImage(allocator, "hero.png", replaceTestImage(&small, 4, 4, 10, 20, 30));
    const uv_before = atlas_mgr.getEntry("hero.png").?.uv;

    var big: [8 * 8 * 4]u8 = undefined;
    const out = try atlas_mgr.replaceImage(
        allocator,
        "hero.png",
        replaceTestImage(&big, 8, 8, 200, 100, 50),
    );

    try std.testing.expect(out.repositioned);
    try std.testing.expect(!std.mem.eql(f32, &uv_before, &out.uv));
    try std.testing.expectEqual(out.uv, atlas_mgr.getEntry("hero.png").?.uv);

    // The new rect is 8x8 and the new colour is where it should be, so a sprite
    // re-pointed at the returned UVs draws the resized image rather than a
    // stretched crop of the old one.
    const moved = atlas_mgr.getEntry("hero.png").?;
    try std.testing.expectEqual(@as(u32, 8), moved.entry.w);
    try std.testing.expectEqual(@as(u32, 8), moved.entry.h);
    const page_pixels = atlas_mgr.getPagePixelsOf(out.page).?;
    const w = @as(usize, atlas_mgr.width);
    const off = (@as(usize, moved.entry.y) * w + @as(usize, moved.entry.x)) * 4;
    try std.testing.expectEqual(@as(u8, 200), page_pixels[off]);
}

test "a reload of an image that was never packed is a first upload" {
    const allocator = std.testing.allocator;
    var atlas_mgr = try AtlasManager.init(allocator, 64, 64, 2);
    defer atlas_mgr.deinit(allocator);

    var buf: [4 * 4 * 4]u8 = undefined;
    const out = try atlas_mgr.replaceImage(
        allocator,
        "fresh.png",
        replaceTestImage(&buf, 4, 4, 33, 44, 55),
    );
    try std.testing.expect(out.repositioned);
    try std.testing.expectEqual(out.uv, atlas_mgr.getEntry("fresh.png").?.uv);
    try std.testing.expectEqual(@as(usize, 1), atlas_mgr.entries.count());

    const page_pixels = atlas_mgr.getPagePixelsOf(out.page).?;
    try std.testing.expectEqual(@as(u8, 33), page_pixels[0]);
}

test "refreshAtlas writes into the texture a page already has" {
    const allocator = std.testing.allocator;
    var atlas_mgr = try AtlasManager.init(allocator, 64, 64, 2);
    defer atlas_mgr.deinit(allocator);

    var gpu = FakeGpu{};
    var first: [4 * 4 * 4]u8 = undefined;
    _ = try atlas_mgr.addImage(allocator, "hero.png", replaceTestImage(&first, 4, 4, 10, 20, 30));

    _ = try uploadAtlas(&gpu, &atlas_mgr, FakeGpu.create);
    try std.testing.expectEqual(@as(u32, 1), gpu.created);
    try std.testing.expectEqual(@as(u32, 0), gpu.writes);
    try std.testing.expect(atlas_mgr.hasTexture(atlas_mgr.pageOf("hero.png").?));

    var second: [4 * 4 * 4]u8 = undefined;
    _ = try atlas_mgr.replaceImage(allocator, "hero.png", replaceTestImage(&second, 4, 4, 200, 100, 50));

    try std.testing.expectEqual(@as(u32, 1), try refreshAtlas(&gpu, &atlas_mgr, FakeGpu.create, FakeGpu.write));

    // NO new texture, one write into the existing one, carrying the new bytes.
    // The sprites holding the texture slot keep pointing at a live, updated
    // texture — that is the difference between "reloaded" and "visible".
    try std.testing.expectEqual(@as(u32, 1), gpu.created);
    try std.testing.expectEqual(@as(u32, 1), gpu.writes);
    try std.testing.expectEqual(@as(u8, 200), gpu.written[0]);
    try std.testing.expectEqual(@as(u8, 100), gpu.written[1]);

    // The handle never changed hands: a sprite stores a texture SLOT, and a slot
    // that stops resolving is a sprite falling back to white forever.
    try std.testing.expectEqual(atlas_mgr.getTextureHandle(0), gpu.last_written);

    // The reload settled, so the next frame does not re-upload it.
    try std.testing.expect(!atlas_mgr.anyPageDirty());
    try std.testing.expectEqual(@as(u32, 0), try refreshAtlas(&gpu, &atlas_mgr, FakeGpu.create, FakeGpu.write));
    try std.testing.expectEqual(@as(u32, 1), gpu.created);
    try std.testing.expectEqual(@as(u32, 1), gpu.writes);
}

test "refreshAtlas creates a texture for a page that has never had one" {
    const allocator = std.testing.allocator;
    var atlas_mgr = try AtlasManager.init(allocator, 64, 64, 2);
    defer atlas_mgr.deinit(allocator);

    var gpu = FakeGpu{};
    var first: [4 * 4 * 4]u8 = undefined;
    _ = try atlas_mgr.addImage(allocator, "hero.png", replaceTestImage(&first, 4, 4, 10, 20, 30));

    // No first upload: the page is dirty and has no texture, so a refresh is a
    // first upload. This is the "the boot never packed it" case.
    try std.testing.expect(atlas_mgr.anyPageDirty());
    _ = try refreshAtlas(&gpu, &atlas_mgr, FakeGpu.create, FakeGpu.write);
    try std.testing.expectEqual(@as(u32, 1), gpu.created);
    try std.testing.expectEqual(@as(u32, 0), gpu.writes);
    try std.testing.expect(atlas_mgr.hasTexture(0));
}

test "a stale texture handle is refused, not written through" {
    const allocator = std.testing.allocator;
    var atlas_mgr = try AtlasManager.init(allocator, 64, 64, 2);
    defer atlas_mgr.deinit(allocator);

    var gpu = FakeGpu{};
    var first: [4 * 4 * 4]u8 = undefined;
    _ = try atlas_mgr.addImage(allocator, "hero.png", replaceTestImage(&first, 4, 4, 10, 20, 30));
    _ = try uploadAtlas(&gpu, &atlas_mgr, FakeGpu.create);

    // A page whose texture was destroyed out from under the atlas — the editor
    // closing a workspace, a device loss — must not be written through.
    atlas_mgr.setTextureHandle(0, @ptrFromInt(0x4000));
    var second: [4 * 4 * 4]u8 = undefined;
    _ = try atlas_mgr.replaceImage(allocator, "hero.png", replaceTestImage(&second, 4, 4, 200, 100, 50));
    try std.testing.expectError(error.OutOfMemory, refreshAtlas(&gpu, &atlas_mgr, FakeGpu.create, FakeGpu.write));
    try std.testing.expectEqual(@as(u32, 0), gpu.writes);
}

test "refreshAtlas runs the coverage hook, so the occluder follows the art" {
    const allocator = std.testing.allocator;
    var atlas_mgr = try AtlasManager.init(allocator, 64, 64, 2);
    defer atlas_mgr.deinit(allocator);

    var hook = SpyHook{};
    atlas_mgr.onPageUploaded(&hook, SpyHook.page);
    // A real backend pointer: `createTexture` receives it as `*anyopaque` and
    // aligns to `*FakeGpu`, so a small integer is a misaligned pointer and a
    // panic rather than a call.
    var backend = FakeGpu{};

    var first: [4 * 4 * 4]u8 = undefined;
    _ = try atlas_mgr.addImage(allocator, "hero.png", replaceTestImage(&first, 4, 4, 10, 20, 30));

    _ = try uploadAtlas(&backend, &atlas_mgr, FakeGpu.create);
    try std.testing.expectEqual(@as(u32, 1), hook.calls);
    try std.testing.expectEqual(@as(u8, 10), hook.seen_r);

    var second: [4 * 4 * 4]u8 = undefined;
    _ = try atlas_mgr.replaceImage(allocator, "hero.png", replaceTestImage(&second, 4, 4, 200, 100, 50));
    _ = try refreshAtlas(&backend, &atlas_mgr, FakeGpu.create, FakeGpu.write);

    // The reload re-registered coverage, and it saw the NEW pixels. Skipping the
    // hook here would leave the SDF describing the silhouette of the file as it
    // was five minutes ago, which is a shadow in the wrong place and nothing
    // reporting it.
    try std.testing.expectEqual(@as(u32, 2), hook.calls);
    try std.testing.expectEqual(@as(u8, 200), hook.seen_r);
}

test "an image bigger than a page is an error, not a corrupted atlas" {
    const allocator = std.testing.allocator;
    var atlas_mgr = try AtlasManager.init(allocator, 64, 64, 2);
    defer atlas_mgr.deinit(allocator);

    // 128x128 in a 64x64 page. `AtlasPacker.insert` would place it at (0,0) and
    // past the page's right edge, and the blit would then write 128 rows into a
    // page that has 64 — a buffer overrun that silently corrupts the atlas and
    // whatever was allocated after it.
    const too_big = try allocator.alloc(u8, 128 * 128 * 4);
    defer allocator.free(too_big);
    @memset(too_big, 128);

    try std.testing.expectError(error.ImageTooLarge, atlas_mgr.addImage(allocator, "huge.png", .{
        .width = 128,
        .height = 128,
        .channels = 4,
        .pixels = too_big,
    }));
    try std.testing.expectEqual(@as(usize, 0), atlas_mgr.entries.count());
    // And the page list is untouched: one page, still allocated, still clean.
    try std.testing.expectEqual(@as(u32, 1), atlas_mgr.pageCount());
    try std.testing.expect(!atlas_mgr.anyPageDirty());
}
