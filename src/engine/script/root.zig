//! `engine.script` — the LuaJIT scripting layer (M3).
//!
//! Layer map:
//! - `luajit`: the Lua 5.1/LuaJIT C ABI, the only file that talks to it. A Web
//!   Lua 5.4 backend (ROADMAP Risks) swaps this file and nothing above it.
//! - `vm`: VM lifecycle, the sandbox whitelist, and the incremental GC step
//!   (spec §3.2: ≤ 0.4 ms/frame, no full GC during play).
//! - `scripts`: the chunk cache and O(1) state-preserving hot-reload.
//! - `bindings`: the zero-allocation-per-call engine API handed to Lua, each
//!   function documented in `metadata`.
//! - `metadata`: the single comptime source of truth for autocomplete, help and
//!   the EmmyLua stubs. No metadata → the binding does not merge.
//! - `stubs`: LuaLS/EmmyLua `.lua` annotation generation from `metadata`.
//! - `input`: the action-based input snapshot Lua reads (never raw keys).
//! - `behavior`: the Behaviors system — start/update/fixed_update/on_signal/
//!   on_destroy over a dense instance array, driving the 10k-update budget.
//! - `statemachine`: declarative states + transitions behind a handle component
//!   (M4.5). One implementation serves enemy AI, the player, spawners, UI screens
//!   and game flow; only the declaring script differs.
//!
//! The public API is the `Behaviors` system plus the `Input` snapshot; the ECS
//! stays hidden behind the Actor facade (spec §7).

const std = @import("std");

/// Build-time feature flags (`-Dsteering`, see build.zig). Read through this so
/// the reason a subsystem is gated is in one place rather than scattered.
pub const options = @import("options");

/// Whether the steering accumulator and `world.nearby` are compiled in.
pub const steering_enabled = options.steering;

pub const luajit = @import("luajit.zig");
pub const vm = @import("vm.zig");
pub const scripts = @import("scripts.zig");
pub const bindings = @import("bindings.zig");
pub const metadata = @import("metadata.zig");
pub const stubs = @import("stubs.zig");
pub const input = @import("input.zig");
pub const behavior = @import("behavior.zig");
pub const context = @import("context.zig");
pub const statemachine = @import("statemachine.zig");
pub const spatial = @import("spatial.zig");
pub const steer = @import("steer.zig");

// Short names for what the runtime imports constantly.
pub const Vm = vm.Vm;
pub const Scripts = scripts.Scripts;
pub const ScriptId = scripts.ScriptId;
pub const Behaviors = behavior.Behaviors;
pub const Input = input.Input;
pub const Context = context.Context;
pub const StateMachines = statemachine.Registry;

test {
    @import("std").testing.refAllDecls(@This());
}
