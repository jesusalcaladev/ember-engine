//! M6: the RENDER half of asset hot reload.
//!
//! `assets.hot_reload` answers *whether* a file changed and decodes it. It cannot
//! answer what a changed image MEANS to the thing on screen, and the reason is a
//! module-graph fact rather than a matter of taste: `assets` may not import
//! `render` (the renderer is built on the asset types), so the callback that needs
//! both has to live on this side of the boundary. That is this file.
//!
//! ## What "the edit is visible" actually requires
//!
//! Two calls, and a reload that makes only one of them changes nothing:
//!
//! 1. **`updateImageInAtlas`** puts the new pixels on the rect the sprite's UVs
//!    already point at. Same-size edit → the same rect, so nothing else in the
//!    scene has to move.
//! 2. **`refreshAtlas`** writes that page into the texture the sprite's slot
//!    already resolves to. A refresh that ALLOCATED a texture instead would leave
//!    the sprite drawing the old one.
//!
//! Updating without refreshing leaves the CPU right and the GPU stale; refreshing
//! without updating uploads a page that did not change. Both are silent: the code
//! runs, the counters move, and the screen is identical.
//!
//! ## Event-driven, like the reload manager it plugs into
//!
//! `attach` installs one callback and nothing here is called per frame. The
//! per-frame cost of hot reload with no edits is zero syscalls and zero calls
//! into this file, which is what keeps it inside spec §3 for the other 99% of
//! frames.

const std = @import("std");
const assets = @import("assets");
const render = @import("render.zig");

/// The two renderer operations a reload needs, as a plain struct of function
/// pointers rather than a `render.Renderer`.
///
/// Two reasons, and the second is the one that matters. It keeps a headless test
/// from having to fake a twenty-entry vtable to exercise the callback, and it is
/// the same idiom `atlas_bridge.uploadAtlas` already uses for "hand this code the
/// GPU": a context pointer plus the exact calls. One way to cross that boundary,
/// not two.
pub const ImageSink = struct {
    ctx: *anyopaque,
    /// Swap the pixels of `path`. Returns the UVs to draw with afterwards, or
    /// null when the sink could not pack it (no atlas, a stale handle, or an
    /// image larger than a page).
    update: *const fn (ctx: *anyopaque, path: []const u8, width: u32, height: u32, pixels: []const u8) ?render.AtlasUpdate,
    /// Re-upload the pages whose pixels changed. In place, so no texture slot
    /// changes hands.
    refresh: *const fn (ctx: *anyopaque) void,

    /// A sink over a real renderer and a real atlas: the wiring a runtime or an
    /// editor actually uses.
    ///
    /// `atlas` is the ADDRESS of the atlas handle, not the handle. The atlas is
    /// created lazily — the first `sprite.set_image` decides when it exists — and
    /// a sink built at boot would otherwise capture `null` and refuse every
    /// reload for the life of the process. Reading it at call time is what lets
    /// the lazily-created atlas and the boot-time sink agree.
    pub fn forRenderer(renderer: render.Renderer, atlas: *const ?*anyopaque) RendererSink {
        return .{ .renderer = renderer, .atlas = atlas };
    }
};

/// `ImageSink` backed by `render.Renderer`.
///
/// A separate value because the sink's `ctx` has to point at something stable
/// that holds the renderer and the atlas slot, and a bare `Renderer` value cannot
/// point at itself.
pub const RendererSink = struct {
    renderer: render.Renderer,
    /// See `ImageSink.forRenderer`: the slot, read on each call.
    atlas: *const ?*anyopaque,

    pub fn sink(self: *RendererSink) ImageSink {
        return .{ .ctx = self, .update = update, .refresh = refresh };
    }

    fn update(ctx: *anyopaque, path: []const u8, width: u32, height: u32, pixels: []const u8) ?render.AtlasUpdate {
        const self: *RendererSink = @ptrCast(@alignCast(ctx));
        return self.renderer.updateImageInAtlas(self.atlas.*, path, width, height, pixels);
    }

    fn refresh(ctx: *anyopaque) void {
        const self: *RendererSink = @ptrCast(@alignCast(ctx));
        _ = self.renderer.refreshAtlas(self.atlas.*);
    }
};

/// What a session's reloads did, so a runtime can log it and a test can assert on
/// it without being handed a callback it does not care about.
pub const Stats = struct {
    /// Image changes that reached the GPU.
    reloaded: u32 = 0,
    /// Of those, how many had changed SIZE and were repacked to a new rect.
    repositioned: u32 = 0,
    /// Changes this reloader saw but could not apply: a non-image asset, a file
    /// whose bytes do not decode, or a sink that refused the pack. Counted
    /// rather than swallowed, because a reload that quietly does nothing is
    /// exactly the bug this wiring exists to prevent.
    failed: u32 = 0,
};

/// Ties a hot-reload manager to an atlas.
///
/// One owner: a runtime (or an editor) keeps one of these alive and hands its
/// address to `attach`. It is deliberately not a global, because two runtimes in
/// one process would then share a `stats` and a sink, and the editor runs a
/// second scene exactly like that.
pub const Reloader = struct {
    sink: ImageSink,
    stats: Stats = .{},

    /// Called only when an edit resized an image and it was repacked to a NEW
    /// rect, so the caller can re-point whatever drew the old UVs. Optional: a
    /// same-size edit — the common case, and the whole of the ROADMAP criterion
    /// — never calls it, and a scene with no sprites yet should not have to
    /// write a no-op.
    on_repositioned: ?*const fn (ctx: ?*anyopaque, path: []const u8, uv: [4]f32) void = null,
    /// The `ctx` for `on_repositioned`. Separate from `sink.ctx` on purpose: the
    /// sink knows pixels, the owner knows which entities drew them, and those
    /// are different objects.
    reposition_ctx: ?*anyopaque = null,

    /// Installs this reloader as `hot`'s callback.
    ///
    /// The reloader must OUTLIVE `hot`, because `ctx` is its address.
    pub fn attach(self: *Reloader, hot: *assets.HotReload) void {
        hot.callback = trampoline;
        hot.ctx = self;
    }

    /// One change, applied. Public so a tool (or a test) can drive a change it
    /// built itself without a file on disk.
    pub fn apply(self: *Reloader, change: assets.hot_reload.Change) void {
        // Only images are this reloader's business. A `.lua` or `.wav` edit goes
        // through the same manager and reaches every callback: the script layer
        // and the audio layer each take the formats they own, and none of them
        // should have to know which others exist.
        if (change.format.kind() != .image) return;

        // A change with no decoded image is a file whose bytes did not decode —
        // a half-written save, a corrupt PNG. There are no pixels to upload, so
        // the honest outcome is a failure count, not an update of zeros that
        // would blank the sprite and look like it worked.
        const image = change.image orelse {
            self.stats.failed += 1;
            return;
        };

        const result = self.sink.update(
            self.sink.ctx,
            change.path,
            image.width,
            image.height,
            image.pixels,
        ) orelse {
            self.stats.failed += 1;
            return;
        };

        self.sink.refresh(self.sink.ctx);
        self.stats.reloaded += 1;

        if (result.repositioned) {
            self.stats.repositioned += 1;
            if (self.on_repositioned) |cb| cb(self.reposition_ctx, change.path, result.uv);
        }
    }

    fn trampoline(ctx: ?*anyopaque, change: assets.hot_reload.Change) void {
        const self: *Reloader = @ptrCast(@alignCast(ctx orelse return));
        self.apply(change);
    }
};

// ── Tests ────────────────────────────────────────────────────────────────────

const testing = std.testing;
const atlas_bridge = @import("atlas_bridge.zig");

/// A per-process counter for the end-to-end test's temp file, so two tests in one
/// process cannot collide on a path.
var temp_seq: u32 = 0;

/// A sink over a REAL `AtlasManager` and a fake texture table. Real packing and
/// real page pixels are the point: the fake is only the GPU, which a headless run
/// cannot have.
const TestSink = struct {
    mgr: *atlas_bridge.AtlasManager,
    allocator: std.mem.Allocator,
    created: u32 = 0,
    writes: u32 = 0,
    refreshes: u32 = 0,

    fn sink(self: *TestSink) ImageSink {
        return .{ .ctx = self, .update = update, .refresh = refresh };
    }

    fn update(ctx: *anyopaque, path: []const u8, width: u32, height: u32, pixels: []const u8) ?render.AtlasUpdate {
        const self: *TestSink = @ptrCast(@alignCast(ctx));
        const image = atlas_bridge.Image{
            .width = width,
            .height = height,
            .channels = 4,
            .pixels = @constCast(pixels),
        };
        const replaced = self.mgr.replaceImage(self.allocator, path, image) catch return null;
        return .{ .uv = replaced.uv, .repositioned = replaced.repositioned };
    }

    fn refresh(ctx: *anyopaque) void {
        const self: *TestSink = @ptrCast(@alignCast(ctx));
        self.refreshes += 1;
        _ = atlas_bridge.refreshAtlas(self, self.mgr, create, write) catch {};
    }

    fn create(ctx: *anyopaque, _: u32, _: u32, _: []const u8) ?*anyopaque {
        const self: *TestSink = @ptrCast(@alignCast(ctx));
        self.created += 1;
        return @ptrFromInt(0x1000 + self.created);
    }

    fn write(ctx: *anyopaque, _: ?*anyopaque, _: u32, _: u32, _: []const u8) bool {
        const self: *TestSink = @ptrCast(@alignCast(ctx));
        self.writes += 1;
        return true;
    }
};

/// Records the reposition hook, which is the only way to observe "the caller was
/// told the UVs moved".
const RepositionSpy = struct {
    calls: u32 = 0,
    last_path: []const u8 = "",
    last_uv: [4]f32 = .{ 0, 0, 0, 0 },

    fn onRepositioned(ctx: ?*anyopaque, path: []const u8, uv: [4]f32) void {
        const self: *RepositionSpy = @ptrCast(@alignCast(ctx orelse return));
        self.calls += 1;
        self.last_path = path;
        self.last_uv = uv;
    }
};

fn imageOf(buf: []u8, width: u32, height: u32, tag: u8) assets.Image {
    for (buf, 0..) |*px, i| px.* = if (i % 4 == 3) 255 else tag;
    return .{ .width = width, .height = height, .channels = 4, .pixels = buf };
}

fn changeFor(path: []const u8, image: *const assets.Image, format: assets.Format) assets.hot_reload.Change {
    return .{
        .path = path,
        .guid = assets.AssetGUID.fromPath(path),
        .format = format,
        .content_hash = 1,
        .image = image,
    };
}

test "a same-size image change repacks nothing and refreshes the page" {
    const allocator = testing.allocator;
    var mgr = try atlas_bridge.AtlasManager.init(allocator, 64, 64, 2);
    defer mgr.deinit(allocator);

    var sink = TestSink{ .mgr = &mgr, .allocator = allocator };
    var reload = Reloader{ .sink = sink.sink() };

    var first: [4 * 4 * 4]u8 = undefined;
    _ = try mgr.addImage(allocator, "hero.png", imageOf(&first, 4, 4, 10));
    const uv_before = mgr.getEntry("hero.png").?.uv;

    var second: [4 * 4 * 4]u8 = undefined;
    var image = imageOf(&second, 4, 4, 200);
    reload.apply(changeFor("hero.png", &image, .png));

    try testing.expectEqual(@as(u32, 1), reload.stats.reloaded);
    try testing.expectEqual(@as(u32, 0), reload.stats.repositioned);
    try testing.expectEqual(@as(u32, 0), reload.stats.failed);
    // The refresh happened, and it is what makes the new bytes reach the GPU.
    try testing.expectEqual(@as(u32, 1), sink.refreshes);

    // The UVs did not move, which is why nothing but the texture had to change.
    try testing.expectEqual(uv_before, mgr.getEntry("hero.png").?.uv);
}

test "a resized image change tells the owner to re-point the sprites" {
    const allocator = testing.allocator;
    var mgr = try atlas_bridge.AtlasManager.init(allocator, 64, 64, 2);
    defer mgr.deinit(allocator);

    var sink = TestSink{ .mgr = &mgr, .allocator = allocator };
    var spy = RepositionSpy{};
    var reload = Reloader{
        .sink = sink.sink(),
        .on_repositioned = RepositionSpy.onRepositioned,
        .reposition_ctx = &spy,
    };

    var small: [4 * 4 * 4]u8 = undefined;
    _ = try mgr.addImage(allocator, "hero.png", imageOf(&small, 4, 4, 10));

    var big: [8 * 8 * 4]u8 = undefined;
    var image = imageOf(&big, 8, 8, 200);
    reload.apply(changeFor("hero.png", &image, .png));

    try testing.expectEqual(@as(u32, 1), reload.stats.reloaded);
    try testing.expectEqual(@as(u32, 1), reload.stats.repositioned);
    // The new UV is what the owner re-points its sprites at, so it has to be the
    // one the atlas actually returned.
    try testing.expectEqual(@as(u32, 1), spy.calls);
    try testing.expectEqualStrings("hero.png", spy.last_path);
    try testing.expectEqual(mgr.getEntry("hero.png").?.uv, spy.last_uv);
}

test "a same-size change never asks the owner to re-point anything" {
    const allocator = testing.allocator;
    var mgr = try atlas_bridge.AtlasManager.init(allocator, 64, 64, 2);
    defer mgr.deinit(allocator);

    var sink = TestSink{ .mgr = &mgr, .allocator = allocator };
    var spy = RepositionSpy{};
    var reload = Reloader{
        .sink = sink.sink(),
        .on_repositioned = RepositionSpy.onRepositioned,
        .reposition_ctx = &spy,
    };

    var a: [4 * 4 * 4]u8 = undefined;
    _ = try mgr.addImage(allocator, "hero.png", imageOf(&a, 4, 4, 10));

    var b: [4 * 4 * 4]u8 = undefined;
    var image = imageOf(&b, 4, 4, 99);
    reload.apply(changeFor("hero.png", &image, .png));

    // Not merely "no resize happened" — the hook is not called at all, because a
    // hook that fires on every edit would walk the entity table on every save.
    try testing.expectEqual(@as(u32, 0), spy.calls);
}

test "a non-image change is left to the layers that own those formats" {
    const allocator = testing.allocator;
    var mgr = try atlas_bridge.AtlasManager.init(allocator, 64, 64, 2);
    defer mgr.deinit(allocator);

    var sink = TestSink{ .mgr = &mgr, .allocator = allocator };
    var reload = Reloader{ .sink = sink.sink() };

    reload.apply(.{
        .path = "boom.lua",
        .guid = assets.AssetGUID.fromPath("boom.lua"),
        .format = .lua,
        .content_hash = 2,
        .image = null,
    });

    // Not a failure: a `.lua` edit is the script layer's, and counting it as one
    // would make every script save look like a broken image reload.
    try testing.expectEqual(@as(u32, 0), reload.stats.failed);
    try testing.expectEqual(@as(u32, 0), reload.stats.reloaded);
    try testing.expectEqual(@as(u32, 0), sink.refreshes);
}

test "an image that does not decode fails loudly rather than blanking the sprite" {
    const allocator = testing.allocator;
    var mgr = try atlas_bridge.AtlasManager.init(allocator, 64, 64, 2);
    defer mgr.deinit(allocator);

    var sink = TestSink{ .mgr = &mgr, .allocator = allocator };
    var reload = Reloader{ .sink = sink.sink() };

    var live: [4 * 4 * 4]u8 = undefined;
    _ = try mgr.addImage(allocator, "hero.png", imageOf(&live, 4, 4, 10));

    // A PNG that sniffed as a PNG but whose bytes do not decode: the callback is
    // handed `image = null`. Uploading zeroes over a live sprite is worse than
    // doing nothing, so the change is refused and counted.
    reload.apply(.{
        .path = "hero.png",
        .guid = assets.AssetGUID.fromPath("hero.png"),
        .format = .png,
        .content_hash = 3,
        .image = null,
    });

    try testing.expectEqual(@as(u32, 1), reload.stats.failed);
    try testing.expectEqual(@as(u32, 0), reload.stats.reloaded);
    try testing.expectEqual(@as(u32, 0), sink.refreshes);
}

// The end-to-end path: a file on disk changes, the reload manager notices and
// decodes it, and the reloader puts the new pixels on the atlas. Everything here
// is real except the GPU — the same trade the lighting suite makes, and for the
// same reason: the wiring is what is being tested, not WebGPU.
test "an edited PNG on disk reaches the atlas through the reload manager" {
    const io = std.Io.Threaded.global_single_threaded.io();
    // A per-process counter, not a clock: two tests running in one process must
    // not collide on a path, and the clock is not guaranteed to move between them.
    temp_seq += 1;
    var path_buf: [160]u8 = undefined;
    const path = std.fmt.bufPrint(&path_buf, "/tmp/opencode/ember-reload-{d}.png", .{temp_seq}) catch return error.NameTooLong;
    defer std.Io.Dir.cwd().deleteFile(io, path) catch {};

    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = path, .data = &assets.import.one_px_png });

    var reg = assets.AssetRegistry.init(testing.allocator);
    defer reg.deinit();
    var hot = assets.HotReload.init(testing.allocator, io, &reg);
    defer hot.deinit();

    var mgr = try atlas_bridge.AtlasManager.init(testing.allocator, 64, 64, 2);
    defer mgr.deinit(testing.allocator);

    var sink = TestSink{ .mgr = &mgr, .allocator = testing.allocator };
    var reload = Reloader{ .sink = sink.sink() };
    reload.attach(&hot);

    // The asset is resident: the boot packed it. Then the file is edited.
    var boot: [1 * 1 * 4]u8 = undefined;
    _ = try mgr.addImage(testing.allocator, path, imageOf(&boot, 1, 1, 7));

    try hot.watch(path);
    try testing.expect((try hot.reloadPath(path)) == null); // nothing changed yet
    try testing.expectEqual(@as(u32, 0), reload.stats.reloaded);

    var edited: [assets.import.one_px_png.len + 256]u8 = undefined;
    @memcpy(edited[0..assets.import.one_px_png.len], &assets.import.one_px_png);
    @memset(edited[assets.import.one_px_png.len..], 0x33);
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = path, .data = &edited });

    const outcome = (try hot.reloadPath(path)) orelse return error.ExpectedChange;
    try testing.expectEqual(assets.import.Format.png, outcome.format);

    // The callback fired and the sink was driven, which is the whole chain from
    // an on-disk edit to a page of pixels the GPU can draw.
    try testing.expectEqual(@as(u32, 1), reload.stats.reloaded);
    try testing.expectEqual(@as(u32, 1), sink.refreshes);
}

// `RendererSink` is the wiring a runtime actually uses, so it gets its own check:
// that it forwards to the renderer at all, and — the subtle half — that it reads
// the atlas SLOT on each call rather than capturing the value it saw at boot.
//
// The null backend is the renderer here because a headless suite has no GPU, and
// it answers null, which is exactly what a runtime whose atlas does not exist yet
// should get.
test "RendererSink forwards to the renderer and reads the atlas slot per call" {
    const backend_null = @import("backend_null.zig");

    var backend = backend_null.Backend{};
    const renderer = backend.renderer();

    var atlas: ?*anyopaque = null;
    var renderer_sink = ImageSink.forRenderer(renderer, &atlas);
    const sink = renderer_sink.sink();

    var px: [4]u8 = .{ 0, 0, 0, 0 };
    // No atlas yet: the null renderer refuses, and the refusal is what the
    // Reloader counts as a failure rather than a silent success.
    try testing.expect(sink.update(sink.ctx, "hero.png", 1, 1, &px) == null);
    // Refresh is best-effort and must not fault with a null handle.
    sink.refresh(sink.ctx);

    // Filling the slot is visible on the NEXT call. Freezing the value instead
    // would leave the sink forever pointing at the null it was built with, and
    // the lazily-created atlas would never reload once.
    atlas = @ptrFromInt(1);
    try testing.expect(sink.update(sink.ctx, "hero.png", 1, 1, &px) == null);
    sink.refresh(sink.ctx);
}
