//! Engine logging: one output (stderr) with levels.
//!
//! Rules (spec.md):
//! - No allocations (format straight to stderr).
//! - The sink is swappable: the editor will redirect it to its console panel.

const std = @import("std");

extern "c" fn open(path: [*:0]const u8, flags: c_int, ...) c_int;
extern "c" fn close(fd: c_int) c_int;
extern "c" fn dup2(oldfd: c_int, newfd: c_int) c_int;
extern "c" fn unlink(path: [*:0]const u8) c_int;

comptime {
    _ = open;
    _ = close;
    _ = dup2;
    _ = unlink;
}

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
    // Capture fd 2 so the assertion is real (did the line come out?) and the
    // build stays clean: Zig 0.16 prints any stderr from a passing step inside
    // a misleading "failed command" banner.
    const json = @import("json.zig");
    const path = "/tmp/ember-log-test.stderr";
    const cap = open(path, json.O_WRONLY | json.O_CREAT | json.O_TRUNC, @as(c_int, 0o644));
    try std.testing.expect(cap >= 0);
    defer _ = unlink(path);
    const saved = dup2(cap, 2);
    if (saved < 0) {
        _ = close(cap);
        return error.SkipZigTest;
    }
    defer min_level = .info;

    min_level = .warn;
    debug("not visible {}", .{1});
    warn("visible {}", .{2});

    _ = dup2(saved, 2); // restore stderr before asserting
    _ = close(saved);
    _ = close(cap);

    var buf: [512]u8 = undefined;
    const n = json.readWholeFile(path, &buf) orelse return error.SkipZigTest;
    const out = buf[0..n];
    try std.testing.expect(std.mem.indexOf(u8, out, "not visible") == null);
    try std.testing.expect(std.mem.indexOf(u8, out, "visible 2") != null);
}
