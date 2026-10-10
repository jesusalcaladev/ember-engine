//! `zig build stubs` — writes the LuaLS/EmmyLua stubs for the engine's Lua API.
//!
//! Why this is a build step and not a script somebody runs by hand: the stubs
//! are generated from the SAME comptime metadata the engine registers its
//! bindings from (`script/metadata.zig`). That is what makes drift impossible —
//! `git diff --exit-code` after `zig build stubs` in CI fails the build if a
//! binding changed and the stubs were not regenerated (ROADMAP M5.5).
//!
//! The output is a plain file, committed, so VS Code/Neovim/Zed autocomplete the
//! engine API without the editor needing the Zig toolchain.

const std = @import("std");
const script = @import("script");

pub fn main() !void {
    var buf: [1 << 20]u8 = undefined;
    var sink = script.stubs.Buffer{ .buf = &buf };
    try script.stubs.writeStubs(&sink);

    // Write through `core.json.Writer` rather than std.Io: this is a build-time
    // tool, so it stays on the engine's own fixed-buffer, allocation-free file
    // path (the same one the report writer uses) instead of pulling the newer
    // `Io` interface in.
    var w = @import("core").json.Writer.create("meta/ember.lua") catch |e| {
        std.debug.print("cannot open meta/ember.lua: {s}\n", .{@errorName(e)});
        return e;
    };
    defer w.deinit();
    w.raw(sink.written());
    if (!w.ok()) return error.WriteFailed;

    std.debug.print("wrote meta/ember.lua ({d} bytes, {d} bindings)\n", .{
        sink.written().len,
        script.metadata.bindings.len,
    });
}
