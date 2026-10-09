# Render Pipeline

**Sources:** `src/engine/render/render.zig`, `src/engine/render/2d.zig`

The render pipeline is the bridge from the ECS world to the GPU. It is structured in layers:

- **`render.zig`** — the backend-agnostic renderer interface, shared types (`SpriteInstance`, `Camera`, `FrameStats`), and the vtable.
- **`2d.zig`** — the ECS-driven 2D renderer that walks `(Transform, Sprite)` entities and produces GPU instances.
- **`backend_dawn.zig`** — the Dawn/WebGPU backend that executes the actual GPU work.

## Architecture overview

```
ECS World (Transform + Sprite components)
        │
        ▼
   Renderer2D.collect()     ← walks entities, applies interpolation, writes SpriteInstance[]
        │
        ▼
   Renderer2D.submit()      ← passes instances to the backend
        │
        ▼
   backend.drawSprites()     ← uploads instance buffer, issues instanced draws
        │
        ▼
   GPU (offscreen target → SMAA → swapchain)
```

## The Renderer interface

The renderer is a `ptr + vtable` struct so the backend can change (null / dawn) without touching the runtime:

```zig
pub const Renderer = struct {
    ptr: *anyopaque,
    vtable: *const VTable,

    pub const VTable = struct {
        beginFrame: *const fn (ptr: *anyopaque) void,
        acquireSurface: *const fn (ptr: *anyopaque) void,
        drawQuad: *const fn (ptr: *anyopaque, mvp: *const [16]f32) void,
        present: *const fn (ptr: *anyopaque) void,
        resize: *const fn (ptr: *anyopaque, width: u32, height: u32) void,
        stats: *const fn (ptr: *anyopaque) *const FrameStats,
        deinit: *const fn (ptr: *anyopaque) void,

        // M2 extensions
        createOffscreenTarget: *const fn (ptr: *anyopaque, width: u32, height: u32) OffscreenTarget,
        destroyOffscreenTarget: *const fn (ptr: *anyopaque, target: OffscreenTarget) void,
        beginScene: *const fn (ptr: *anyopaque, target: OffscreenTarget, camera: Camera) void,
        endScene: *const fn (ptr: *anyopaque, enable_smaa: bool, smaa_quality: SMAAQuality) void,
        drawSprites: *const fn (ptr: *anyopaque, instances: []const SpriteInstance, count: usize) void,
        createTexture: *const fn (ptr: *anyopaque, width: u32, height: u32, pixels: []const u8) ?*anyopaque,
        destroyTexture: *const fn (ptr: *anyopaque, texture: ?*anyopaque) void,
    };
    // ...
};
```

## SpriteInstance — the GPU record

Each sprite is a 32-byte instanced record. The vertex shader derives the four quad corners from `vertex_index`, so there is no index buffer and no per-vertex expansion:

```zig
pub const SpriteInstance = struct {
    pos: [2]f32,       // world-space center
    half: [2]f32,      // half extents in world units
    uv: [4]u16,        // atlas rect (u0, v0, u1, v1) as unorm16
    color: [4]u8,      // tint RGBA as unorm8
    slot: u8,          // atlas slot; consecutive instances with the same slot batch together
    _pad: [3]u8 = .{ 0, 0, 0 },
};
```

A compile-time assertion enforces the 32-byte size:

```zig
comptime {
    if (@sizeOf(SpriteInstance) != 32) @compileError("SpriteInstance must stay 32 bytes");
}
```

### Why 32 bytes and not 52

UV as 4× u16 unorm and tint as 4× u8 unorm are visually lossless for 2D sprites and save 20 bytes per sprite — 1 MB per frame at the 50k scene. The 50k scene at 32 B/sprite = 1.6 MB, inside the spec §4 budget of 2 MB/frame.

### Unorm packing helpers

```zig
pub fn toUnorm16(v: f32) u16 {
    const c = @max(0.0, @min(1.0, v));
    return @intFromFloat(c * 65535.0 + 0.5);
}

pub fn toUnorm8(v: f32) u8 {
    const c = @max(0.0, @min(1.0, v));
    return @intFromFloat(c * 255.0 + 0.5);
}
```

## Camera

The camera is an orthographic view-projection matrix plus a viewport:

```zig
pub const Camera = struct {
    vp: [16]f32 = [_]f32{1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1},
    viewport_x: u32 = 0,
    viewport_y: u32 = 0,
    viewport_w: u32 = 0,
    viewport_h: u32 = 0,
};
```

`makeCamera` builds an orthographic projection covering `width × height` pixels, centered at the origin:

```zig
pub fn makeCamera(width: f32, height: f32) Camera {
    const left = -width * 0.5;
    const right = width * 0.5;
    const bottom = -height * 0.5;
    const top = height * 0.5;
    const near = -1.0;
    const far = 1.0;

    const sx = 2.0 / (right - left);
    const sy = 2.0 / (top - bottom);
    const sz = -2.0 / (far - near);
    const tx = -(right + left) / (right - left);
    const ty = -(top + bottom) / (top - bottom);
    const tz = -(far + near) / (far - near);

    return Camera{
        .vp = .{
            sx, 0, 0, 0,
            0, sy, 0, 0,
            0, 0, sz, 0,
            tx, ty, tz, 1,
        },
        .viewport_w = @intFromFloat(width),
        .viewport_h = @intFromFloat(height),
    };
}
```

For custom view-projection matrices (editor viewport, etc.):

```zig
pub fn makeCameraCustom(vp: [16]f32, vp_x: u32, vp_y: u32, vp_w: u32, vp_h: u32) Camera
```

## FrameStats — per-frame metrics

```zig
pub const FrameStats = struct {
    draw_calls: u64 = 0,
    render_passes: u64 = 0,
    pipeline_changes: u64 = 0,
    bind_group_changes: u64 = 0,
    vertex_count: u64 = 0,
    upload_bytes: u64 = 0,          // spec §4: <= 2 MB/frame
    gpu_ns: u64 = 0,                // GPU frame time from timestamp queries
    gpu_passes: u32 = 0,
    resources_created_total: u64 = 0,
    resources_created_frame: u64 = 0, // must be 0 (spec §3.6)
    present_mode: c_uint = 1,
    timestamp_queries: bool = false,
    timestamp_maps: u64 = 0,
    timestamp_reads: u64 = 0,
    timestamp_bad: u64 = 0,
    timestamp_ranges: u64 = 0,
};
```

## Offscreen target

The game always renders to an offscreen target (the editor composites it into the viewport):

```zig
pub const OffscreenTarget = struct {
    width: u32,
    height: u32,
    handle: ?*anyopaque = null,  // opaque backend handle
};
```

## SMAA quality presets

```zig
pub const SMAAQuality = enum { Low, Medium, High };
```

## The 2D Renderer (ECS bridge)

`Renderer2D` is the system that walks the ECS world and produces GPU instances.

### Design constraints

- **Zero allocations in the frame** (spec §3.1): the instance buffer and the batcher are reserved by `reserve()` at load and locked afterwards.
- **1 draw call per (atlas, blend) run**: entities in the same archetype are already contiguous, and archetypes are visited in creation order.
- **Hierarchy**: when enabled, `hierarchy.resolve` produces world transforms; the renderer composes the local sprite with the resolved parent chain.

### Stats

```zig
pub const Stats = struct {
    entities: u32 = 0,      // entities visited by the query
    instances: u32 = 0,     // instances actually written (visible ones)
    hidden: u32 = 0,        // entities skipped because invisible
    draw_calls: u32 = 0,    // draw calls the backend issued
    overflowed: u32 = 0,    // instances dropped (buffer full)
};
```

### Lifecycle

```zig
pub fn init(allocator: std.mem.Allocator) Renderer2D
pub fn reserve(self: *Renderer2D, n: usize) !void  // load-time reservation
pub fn lock(self: *Renderer2D) void                 // freeze capacities
pub fn beginFrame(self: *Renderer2D) void           // O(1) reset
pub fn collect(self: *Renderer2D, world: *World, alpha: f32) void  // walk + write
pub fn submit(self: *Renderer2D, r: render.Renderer) void          // upload + draw
pub fn deinit(self: *Renderer2D) void
```

### The collect pass

`collect` walks every `(Transform, Sprite)` entity in column batches, applies the interpolated world transform, and writes 32-byte GPU instances:

```zig
pub fn collect(self: *Renderer2D, world: *World, alpha: f32) void {
    var q = world.query(.{ Transform, Sprite });

    while (q.nextBatch()) |batch| {
        const transforms = batch.slice(Transform);
        const sprites = batch.slice(Sprite);
        const n = batch.len();
        self.stats.entities += @intCast(n);

        var i: usize = 0;
        while (i < n) : (i += 1) {
            const sprite = &sprites[i];
            if (!sprite.visible) {
                self.stats.hidden += 1;
                continue;
            }
            if (self.count >= self.capacity) {
                self.stats.overflowed += 1;
                continue;
            }
            const t = transforms[i].interpolated(alpha);
            self.instances[self.count] = instanceFor(t, sprite);
            self.layers[self.count] = sprite.layer;
            self.count += 1;
            // Track layer monotonicity for the sort fast-path
            if (sprite.layer < self.max_layer_seen) self.layers_monotonic = false;
            if (sprite.layer > self.max_layer_seen) self.max_layer_seen = sprite.layer;
            self.stats.instances += 1;
        }
    }

    if (self.options.sort != .none and !self.layers_monotonic) self.sortByLayer();
    self.buildRuns();
}
```

### Interpolation

The `alpha` parameter is the fixed-timestep interpolation factor (spec §3.3). The renderer shows where the actor is *between* two ticks, not where the simulation left it — this removes stutter at 60 Hz sim / any refresh rate.

### Draw runs

Consecutive sprites with the same atlas slot share one instanced draw call. A change of atlas closes the run:

```zig
pub const Run = struct {
    first: u32,
    count: u32,
    atlas: u8,
};
```

### Instance building

`instanceFor` converts a `Transform` + `Sprite` into a `SpriteInstance`:

```zig
fn instanceFor(t: Transform, sprite: *const Sprite) render.SpriteInstance {
    const size_x = sprite.size.x * t.scale.x;
    const size_y = sprite.size.y * t.scale.y;
    return .{
        .pos = .{ t.position.x, t.position.y },
        .half = .{ @abs(size_x) * 0.5, @abs(size_y) * 0.5 },
        .uv = .{
            render.toUnorm16(sprite.uv[0]),
            render.toUnorm16(sprite.uv[1]),
            render.toUnorm16(sprite.uv[2]),
            render.toUnorm16(sprite.uv[3]),
        },
        .color = .{
            render.toUnorm8(sprite.tint[0]),
            render.toUnorm8(sprite.tint[1]),
            render.toUnorm8(sprite.tint[2]),
            render.toUnorm8(sprite.tint[3]),
        },
        .slot = sprite.atlas,
    };
}
```

### Layer sorting

When the scene is not already layer-monotonic and `sort` is enabled, a stable counting sort reorders instances by layer in O(n + span):

```zig
fn sortByLayer(self: *Renderer2D) void {
    if (self.count < 2) return;
    const n = self.count;
    var min_layer: u16 = std.math.maxInt(u16);
    var max_layer: u16 = 0;
    for (self.layers[0..n]) |l| {
        min_layer = @min(min_layer, l);
        max_layer = @max(max_layer, l);
    }
    const span = @as(usize, max_layer - min_layer) + 1;
    if (span > self.layer_counts.len) return;  // pathological range: skip
    const counts = self.layer_counts[0..span];
    @memset(counts, 0);
    for (self.layers[0..n]) |l| counts[l - min_layer] += 1;
    var acc: u32 = 0;
    for (counts) |*c| { const v = c.*; c.* = acc; acc += v; }
    for (self.layers[0..n], 0..) |l, i| {
        const idx = l - min_layer;
        self.scratch[counts[idx]] = self.instances[i];
        counts[idx] += 1;
    }
    @memcpy(self.instances[0..n], self.scratch[0..n]);
}
```

### Submit

The instance buffer is uploaded once per frame:

```zig
pub fn submit(self: *Renderer2D, r: render.Renderer) void {
    if (self.count == 0) return;
    r.drawSprites(self.instances[0..self.count], self.count);
    self.stats.draw_calls = @intCast(r.stats().draw_calls);
}
```

## Frame loop integration

```zig
// At load:
var r2d = Renderer2D.init(allocator);
try r2d.reserve(65536);
r2d.lock();

// Each frame:
r2d.beginFrame();
r2d.collect(&world, alpha);
r2d.submit(renderer);
```
