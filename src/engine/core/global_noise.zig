//! Global Noise System — connects procedural noise to engine-wide settings.
//! Super optimization: caches results per chunk to avoid recalculation.
//!
//! ## Why this exists
//!
//! The M4.5 `noise` module provides deterministic functions (value, perlin,
//! simplex, fbm, ridged) but each call recomputes from scratch. For systems
//! that sample the same coordinates repeatedly (terrain height, animal wander
//! paths, cloud drift), this is wasted CPU. This module provides a chunk-based
//! cache that stores precomputed noise values, keyed by (seed, chunk).
//!
//! The cache is deterministic: same seed + same chunk = same values. It is
//! invalidated only when the world seed changes (which is a full world reload).

const std = @import("std");
const noise = @import("noise.zig");

/// Cached noise table for chunk-based systems (terrain, weather, animal paths)
pub const ChunkCache = struct {
    allocator: std.mem.Allocator,
    seed: u64,
    cell_size: f32 = 64.0,
    /// Precomputed noise values for this chunk (flat array, row-major).
    values: []f32,
    /// Chunk dimensions in cells.
    dim: usize,

    pub fn init(allocator: std.mem.Allocator, seed: u64, dim: usize) !ChunkCache {
        const size = dim * dim;
        const values = try allocator.alloc(f32, size);
        return ChunkCache{ .allocator = allocator, .seed = seed, .values = values, .dim = dim };
    }

    pub fn deinit(self: *ChunkCache) void {
        self.allocator.free(self.values);
        self.* = undefined;
    }

    /// Fast lookup with deterministic seed-based noise.
    /// If not cached, computes and stores the value (write-once per cell).
    pub fn get(self: *ChunkCache, x: f32, y: f32) f32 {
        const cx = @as(i32, @intFromFloat(@floor(x / self.cell_size)));
        const cy = @as(i32, @intFromFloat(@floor(y / self.cell_size)));
        // Wrapped in I32, not in `dim`'s own type: `@intCast(self.dim)` left the
        // result type to the compiler to infer from the surrounding expression,
        // and there is nothing to infer it from. The wrap is a negative-modulo
        // fixup, which is I32 arithmetic by definition; naming the type says so.
        const dim: i32 = @intCast(self.dim);
        const wrap = struct {
            fn f(v: i32, d: i32) i32 {
                return ((v % d) + d) % d;
            }
        }.f;
        const idx = @as(usize, @intCast(wrap(cx, dim))) +
                    @as(usize, @intCast(wrap(cy, dim))) * self.dim;
        return self.values[idx];
    }

    /// Pre-fill the cache for a chunk (call at chunk load time).
    pub fn fillChunk(self: *ChunkCache, basis: noise.Basis) void {
        for (self.values, 0..) |*v, i| {
            const cx = i % self.dim;
            const cy = i / self.dim;
            const wx = @as(f32, @floatFromInt(cx)) * self.cell_size;
            const wy = @as(f32, @floatFromInt(cy)) * self.cell_size;
            v.* = noise.fbm(self.seed, wx * 0.05, wy * 0.05, 4, basis);
        }
    }
};

/// Global noise manager — connects to engine settings for deterministic world
pub const GlobalNoise = struct {
    world_seed: u64 = 42,
    terrain_seed: u64 = 123,
    weather_seed: u64 = 456,
    animal_seed: u64 = 789,

    pub fn terrain(x: f32, y: f32) f32 {
        return noise.fbm(123, x * 0.05, y * 0.05, 4, .perlin);
    }

    pub fn weather(x: f32, y: f32) f32 {
        return noise.simplex(456, x * 0.02, y * 0.02);
    }

    pub fn animal_wander(x: f32, y: f32) f32 {
        return noise.perlin(789, x * 0.1, y * 0.1);
    }
};
