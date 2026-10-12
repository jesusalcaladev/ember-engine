//! `engine` — the engine's public boundary.
//!
//! The runtime and the editor import this module by name and only see what
//! is re-exported here. Dawn/GLFW stay hidden behind platform/render (spec §7).
//!
//! `core` and `ecs` are separate build *modules* so each one can be compiled
//! (and tested) on its own: `zig build test` runs them without linking Dawn.

pub const core = @import("core");
pub const ecs = @import("ecs");
pub const platform = @import("platform/platform.zig");
pub const render = @import("render/render.zig");
/// M2: CPU sprite batcher (order + draw-call grouping) and the atlas packer.
pub const batcher = @import("render/batcher.zig");
pub const atlas = @import("render/atlas.zig");
/// M2/M3: the ECS-driven render system (Actors -> GPU instances).
pub const render2d = @import("render/2d.zig");
/// M7: 2D lighting. Lights, occluders, 1D shadow maps and the GI field.
pub const light = @import("render/light.zig");
/// M3: the LuaJIT scripting layer (behaviors, bindings, metadata). Exposed
/// through the engine boundary so gameplay/runtime can drive it without ever
/// importing LuaJIT directly (spec §7: Lua never touches the platform).
pub const script = @import("script");
/// M-project: `project.config` — the file that says what a project IS. The UI
/// panel drives `project.Config`; the engine consumes `project.RuntimeConfig`.
pub const project = @import("project");

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
