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
//!
//! The public API is the `Behaviors` system plus the `Input` snapshot; the ECS
//! stays hidden behind the Actor facade (spec §7).

const std = @import("std");

pub const luajit = @import("luajit.zig");
pub const vm = @import("vm.zig");
pub const scripts = @import("scripts.zig");
pub const bindings = @import("bindings.zig");
pub const metadata = @import("metadata.zig");
pub const stubs = @import("stubs.zig");
pub const input = @import("input.zig");
pub const behavior = @import("behavior.zig");
pub const context = @import("context.zig");

// Short names for what the runtime imports constantly.
pub const Vm = vm.Vm;
pub const Scripts = scripts.Scripts;
pub const ScriptId = scripts.ScriptId;
pub const Behaviors = behavior.Behaviors;
pub const Input = input.Input;
pub const Context = context.Context;

test {
    @import("std").testing.refAllDecls(@This());
}
