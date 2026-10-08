//! Engine logging: one output (stderr) with levels.
//!
//! Rules (spec.md):
//! - No allocations (format straight to stderr).
//! - The sink is swappable: the editor will redirect it to its console panel.

const std = @import("std");

pub const Level = enum(u8) {
    err = 0,
    warn = 1,
    info = 2,
    debug = 3,

    pub fn label(self: Level) []const u8 {
        return switch (self) {
            .err => "ERR ",
            .warn => "WARN",
            .info => "INFO",
            .debug => "DEBG",
        };
    }
};

/// Minimum level that gets emitted (the rest is dropped early).
pub var min_level: Level = .info;

// The sink is stderr by design in M0: Zig function pointers cannot be
// generic and allocation-free formatting needs comptime fmt. The editor will
// redirect the runtime's stderr to its console panel (no extra cost).

fn log(level: Level, comptime fmt: []const u8, args: anytype) void {
    if (@intFromEnum(level) > @intFromEnum(min_level)) return;
    std.debug.print("[{s}] " ++ fmt ++ "\n", .{level.label()} ++ args);
}

pub fn err(comptime fmt: []const u8, args: anytype) void {
    log(.err, fmt, args);
}
pub fn warn(comptime fmt: []const u8, args: anytype) void {
    log(.warn, fmt, args);
}
pub fn info(comptime fmt: []const u8, args: anytype) void {
    log(.info, fmt, args);
}
pub fn debug(comptime fmt: []const u8, args: anytype) void {
    log(.debug, fmt, args);
}

/// Comptime namespace that prefixes messages with the subsystem.
pub fn scoped(comptime scope: []const u8) type {
    return struct {
        pub fn err(comptime fmt: []const u8, args: anytype) void {
            log(.err, "[" ++ scope ++ "] " ++ fmt, args);
        }
        pub fn warn(comptime fmt: []const u8, args: anytype) void {
            log(.warn, "[" ++ scope ++ "] " ++ fmt, args);
        }
        pub fn info(comptime fmt: []const u8, args: anytype) void {
            log(.info, "[" ++ scope ++ "] " ++ fmt, args);
        }
        pub fn debug(comptime fmt: []const u8, args: anytype) void {
            log(.debug, "[" ++ scope ++ "] " ++ fmt, args);
        }
    };
}

test "level filter" {
    min_level = .warn;
    // Must not crash nor write below the minimum level.
    debug("not visible {}", .{1});
    warn("visible {}", .{2});
    min_level = .info;
}
