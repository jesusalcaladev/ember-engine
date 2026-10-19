//! `engine` — the engine's public boundary.
//!
//! The runtime and the editor import this module by name and only see what
//! is re-exported here. Dawn/GLFW stay hidden behind platform/render (spec §7).
//!
//! `core` and `ecs` are separate build *modules* so each one can be compiled
//! (and tested) on its own: `zig build test` runs them without linking Dawn.

pub const core = @import("core");
pub const ecs = @import("ecs");
// `platform` and `render` are build MODULES, not paths: `script` imports the
// renderer too (for the camera view and the stats it publishes), and a file can
// only belong to one module. So the boundary reaches them by module name and
// re-exports their submodules from `render.zig` rather than importing the files
// relatively — which is exactly the "file exists in two modules" error this
// used to trip.
pub const platform = @import("platform");
pub const render = @import("render");
/// M2: CPU sprite batcher (order + draw-call grouping) and the atlas packer.
pub const batcher = render.batcher;
pub const atlas = render.atlas;
/// M2/M3: the ECS-driven render system (Actors -> GPU instances).
pub const render2d = render.render2d;
/// M9: the CPU particle system.
pub const particles = render.particles;
/// M9: scene transitions — the fade.
pub const fade = render.fade;
/// M14: CanvasModulate — the full-screen tint.
pub const tint = render.tint;
/// M7: 2D lighting. Lights, occluders, 1D shadow maps and the GI field.
pub const light = render.light;
/// M7: the lighting DRIVER — the owner that ties the above to the renderer.
/// Separate from `light` because `light.zig` is the system and the driver is
/// the wiring, and the runtime needs the wiring.
pub const lighting_driver = render.lighting_driver;
/// M3: the LuaJIT scripting layer (behaviors, bindings, metadata). Exposed
/// through the engine boundary so gameplay/runtime can drive it without ever
/// importing LuaJIT directly (spec §7: Lua never touches the platform).
pub const script = @import("script");
/// M-project: `project.config` — the file that says what a project IS. The UI
/// panel drives `project.Config`; the engine consumes `project.RuntimeConfig`.
pub const project = @import("project");
pub const assets = @import("assets");
/// M8: the audio system — the port, the mixer, the buses and the bank. The
/// runtime reaches it through this boundary (the same way it does `assets`),
/// so nothing above the engine ever imports a backend by path.
pub const audio = @import("audio");

test {
    @import("std").testing.refAllDecls(@This());

    // `refAllDecls(@This())` covers THIS root's declarations and stops there.
    // It does not recurse, so a declaration that lives one level down — inside
    // `render` — is never referenced, and an unreferenced `@import` is a file
    // whose tests never enter the test binary at all.
    //
    // That is not hypothetical. `render.backend_null` holds the only headless
    // check of the light pass, and it was compiled but never run: the suite was
    // green, 46 tests passed, and nothing had ever exercised `drawLights`. A
    // green suite that silently omits its own tests is worse than a red one,
    // because it is the one you stop looking at.
    //
    // Referenced explicitly rather than through `refAllDecls(render)` so the
    // intent survives: these are the backends, and a backend with no test is a
    // backend whose contract is only checked on a machine with a GPU.
    _ = render.backend_null;
}
