//! `engine.project` — `project.config`: the file that says what a project IS.
//!
//! One document, four layers:
//! - `config`: the typed structs (`Config`, `Display`, `Physics`, ...) plus
//!   `load`/`save`/`reload`. The UI panel and the runtime both hold one of
//!   these; every string is arena-owned until `deinit`.
//! - `schema`: the comptime table that describes every section and field —
//!   type, default, range, tooltip — and the validator that reads it. Adding a
//!   field means editing `config.zig` and the table; a comptime check refuses
//!   to compile until the two agree.
//! - `parser`: the line-oriented ZSON decoder/encoder. Strict about typos,
//!   lenient about whitespace and comments, canonical on save.
//! - `runtime`: the engine-facing half — `apply` (validated config → the
//!   subsystems, through erased callbacks) and `resolve` (binding names → key
//!   codes, once at boot).
//!
//! Usage:
//! ```zig
//! const project = @import("engine").project;
//!
//! var cfg = try project.config.load(alloc, "project.config");
//! defer cfg.deinit();
//! cfg.display.width = 1920;  // Zig cannot hook assignment: call markDirty()
//! cfg.markDirty();           // after UI edits, so the panel knows to save
//! try cfg.save("project.config");
//!
//! const meta = project.schema.getMetadata("display", "max_fps");
//! // meta.type == .int, meta.min == 0, meta.max == 1000, tooltip set
//!
//! try project.runtime.apply(cfg, my_targets);
//! ```
//!
//! The reference document is `samples/project.config`; the round-trip and
//! validation contracts live in `tests.zig`.

const std = @import("std");

/// Structs + `load`/`save`/`reload` — what the UI panel drives.
pub const config = @import("config.zig");
/// The comptime schema: metadata for the UI, validation for the engine.
pub const schema = @import("schema.zig");
/// `project.config` parsing and canonical encoding.
pub const parser = @import("parser.zig");
/// Applying a config to the engine, and resolving binding names to codes.
pub const runtime = @import("runtime.zig");

/// The engine-boundary name for the resolved input map (see `runtime.resolve`).
/// `engine.root` re-exports the module as `project`, and its doc comment names
/// `project.RuntimeConfig` as what the engine consumes: this alias keeps that
/// promise without a second type.
pub const RuntimeConfig = runtime.RuntimeConfig;

test {
    // The suite lives in `tests.zig` (round-trips, validation, diagnostics)
    // so the contracts are findable in one file; the per-file tests above
    // cover the pieces each module owns.
    std.testing.refAllDecls(@This());
    _ = @import("tests.zig");
}
