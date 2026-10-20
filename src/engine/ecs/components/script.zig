//! Script-side components — `Script` (M3) and `StateMachine` (M4.5) (split out
//! of components.zig).

const std = @import("std");

/// The Lua behavior bound to an actor (M3). This is the serializable link: it
/// stores a *script id* (a stable index into the engine's script cache), never a
/// VM reference — a Lua registry ref is meaningless across save/load, so `.zson`
/// writes the id and the runtime re-binds it to the live script on load. That is
/// what keeps scene serialization bit-exact (spec §6) while still letting a
/// scene say "this actor runs player.lua".
///
/// The behavior's Lua state (the `self` table and its cached method refs) lives
/// in the `script` subsystem, keyed off this component; the ECS only owns the
/// stable id, exactly as the ECS is an internal detail and the public API is
/// Actor + Components + Signals (spec §7).
pub const Script = struct {
    /// Index into the script cache.
    ///
    /// NOT the project's behavior index: a scene file's `Script {script: 1}`
    /// means "the FIRST behavior the project declares", and the loader
    /// resolves that through the project's table into the cache id this field
    /// stores. The two are different numbering systems, and the scene file
    /// uses the one the project controls.
    ///
    /// The cache's own ids start at ZERO — the first script loaded is id 0 — so
    /// this field cannot use 0 to mean "no script". A `Script` component with
    /// `script = 0` is a VALID script: the first one loaded.
    script: u32 = 0,
};

/// A link to a state machine defined by Lua (ROADMAP M4.5).
///
/// The same component serves every case — an enemy's AI, the player's own
/// states, a spawner, a UI screen, the game flow — because the states and their
/// transitions are script data, not component data.
///
/// It is a HANDLE, not the machine itself, and that is forced by rule 1 of the
/// registry: a machine holds names and Lua callbacks, which are pointers and
/// slices, so it cannot live in a component. The engine owns the machines in a
/// side registry (`script/statemachine.zig`) and the component stores the index,
/// exactly as `Script` stores a script id. Two consequences worth knowing:
///
/// - **The handle is what serializes.** A `.zson` file saves `machine = 3`, not a
///   Lua closure, so save/load stays bit-exact (spec §6). The transitions are
///   rebuilt from the script when the behavior attaches.
/// - **0 means "no machine"**, matching `Script`'s convention, so an entity that
///   has never opted in costs one branch in every tick.
pub const StateMachine = struct {
    /// Index into the engine's state-machine registry; 0 is "none".
    machine: u32 = 0,

    /// True once the machine has been entered, so the first tick runs `enter` on
    /// the starting state exactly once instead of every frame until something
    /// transitions it away and back.
    started: bool = false,
};

// ── Tests ────────────────────────────────────────────────────────────────────

const testing = std.testing;

test "handle components stay tiny" {
    try testing.expectEqual(@as(usize, 4), @sizeOf(Script));
    try testing.expectEqual(@as(usize, 8), @sizeOf(StateMachine));
}