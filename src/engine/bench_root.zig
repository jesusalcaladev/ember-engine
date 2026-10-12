//! The lighting benchmark's own root.
//!
//! # Why this exists
//!
//! `src/engine/root.zig` is the engine's public boundary and it grows: it now
//! re-exports the project config, the audio subsystem, the editor surface and the
//! asset pipeline. The benchmark links it, so a module being edited over there
//! takes `zig build bench-light` down with it — and a benchmark that cannot run
//! is how a performance claim stops being a measurement and becomes a comment.
//!
//! This root exports what the lighting benchmark actually reaches and nothing
//! else, for the same reason `render/test_root.zig` exists on the test side.
//!
//! It is NOT a second copy of the benchmark or of the lighting system: the same
//! `render/light.zig`, analyzed from a root that does not drag in the rest of the
//! engine.

const std = @import("std");

pub const core = @import("core");
pub const ecs = @import("ecs");
pub const components = ecs.components;

/// M7: 2D lighting. Lights, occluders, 1D shadow maps and the GI field.
pub const light = @import("render").light;
/// The lighting DRIVER — the owner that ties the above to the renderer. The
/// benchmark reaches `CoverageStore` and `registerAtlasCoverage` through here.
pub const lighting_driver = @import("render").lighting_driver;

/// Present so a benchmark file that reaches for it compiles. The lighting bench
/// does not, and re-exporting the renderer would defeat the point of this file.
pub const render = @import("render");

/// M7 ACCEPTANCE: the acceptance section drives one frame all the way through
/// `Renderer2D.submitLights` against the null backend, so the numbers it prints
/// come from a `LightFrame` the renderer actually accepted — right strides, right
/// angle count, environment uploaded before the pass — rather than from a CPU
/// half that computed and threw the result away.
///
/// That is the ONE place in this benchmark that needs the renderer, and it is why
/// these two are here while the timing sections above them deliberately reach for
/// nothing but `Lighting`. The null backend draws nothing, so nothing below is
/// pretending to be a GPU measurement.
pub const render2d = @import("render").render2d;
pub const backend_null = @import("render").backend_null;

test {
    std.testing.refAllDecls(@This());
}
