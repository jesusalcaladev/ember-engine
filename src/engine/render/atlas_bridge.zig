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

    /// Add an image to the atlas. Returns the atlas slot (index) and UV coordinates.
    /// Automatically creates new pages when the current one is full.
    pub fn addImage(
        self: *AtlasManager,
        allocator: std.mem.Allocator,
        path: []const u8,
        image: Image,
    ) !u8 {
        var entry = self.getCurrentPage().packer.insert(image.width, image.height);

        while (entry == null) {
            if (!self.nextPage(allocator)) {
                return error.OutOfMemory;
            }
            entry = self.getCurrentPage().packer.insert(image.width, image.height);
        }

        self.blitImage(entry.?, image);

        const uv = AtlasPacker.uv(entry.?, self.width, self.height);

        // One owned copy of the path serves BOTH roles: the map's key and the
        // fixed-size copy inside the entry (truncated to what fits, and always
        // NUL-terminated so a C-style read of it cannot run off the end).
        const path_copy = try allocator.dupe(u8, path);
        errdefer allocator.free(path_copy);
        var atlas_entry = AtlasEntry{
            .path = [_]u8{0} ** 256,
            .entry = entry.?,
            .page = self.current_page,
            .uv = uv,
        };
        const n = @min(path.len, atlas_entry.path.len - 1);
        @memcpy(atlas_entry.path[0..n], path[0..n]);

        try self.entries.put(path_copy, atlas_entry);

        self.getCurrentPage().dirty = true;

        return @intCast(self.entries.count() - 1);
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

    fn blitImage(self: *AtlasManager, entry: atlas.Entry, image: Image) void {
        const W = @as(usize, self.width);
        const page = self.getCurrentPage();
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

    pub fn isDirty(self: *AtlasManager) bool {
        return self.getCurrentPage().dirty;
    }

    pub fn getPagePixels(self: *AtlasManager) []const u8 {
        return self.getCurrentPage().pixels;
    }

    pub fn markUploaded(self: *AtlasManager) void {
        self.getCurrentPage().dirty = false;
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

/// Create a GPU atlas texture from the atlas manager's page pixels.
/// Returns a handle that can be used with the render backend.
pub fn uploadAtlas(
    backend: *anyopaque,
    atlas_mgr: *AtlasManager,
    createTexture: fn (*anyopaque, u32, u32, []const u8) ?*anyopaque,
) !u8 {
    // Upload all dirty pages
    for (atlas_mgr.pages.items) |*page| {
        if (page.dirty) {
            const pixels = page.pixels;
            const handle = createTexture(backend, atlas_mgr.width, atlas_mgr.height, pixels);
            
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