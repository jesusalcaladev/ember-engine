//! `ember-profile` — reads a `report.json` produced by the runtime and prints
//! the measured numbers, then acts as the CI regression gate (spec §9,
//! roadmap M11: "> 5% regression on any metric = red CI").
//!
//!   ember-profile run.json                        # print the numbers
//!   ember-profile run.json --baseline base.json   # + the gate
//!   ember-profile run.json --tolerance 0.05       # gate at 5% (default)
//!
//! Exit codes: 0 = everything within tolerance, 1 = regression or failed
//! spec verdicts, 2 = the file could not be read/parsed.
//!
//! It imports only `engine.core`: no Dawn, no GLFW, so it runs everywhere
//! (including a headless CI container) and it is unit-testable.

const std = @import("std");
const engine = @import("engine");
const core = engine.core;

const USAGE =
    \\usage: ember-profile <report.json> [--baseline <base.json>] [--tolerance <0..1>]
    \\
    \\  prints the measured performance report and, with --baseline, fails
    \\  (exit 1) when any metric regresses more than --tolerance (spec §9).
    \\
;

const ExitCode = enum(u8) { ok = 0, gate_failed = 1, bad_input = 2 };

/// The metrics the gate watches. Everything here is "lower is better": they
/// are all times, counts or sizes from spec.md.
const Metric = enum {
    work_p50,
    work_p99,
    work_p999,
    work_max,
    wall_p50,
    wall_p99,
    gpu_ns,
    draw_calls,
    upload_bytes,
    allocs_in_frame,
    gpu_resources_in_frame,
    arena_high_water,
    rss_bytes,
    frames,

    fn key(self: Metric) []const u8 {
        return switch (self) {
            .work_p50 => "work_p50",
            .work_p99 => "work_p99",
            .work_p999 => "work_p999",
            .work_max => "work_max",
            .wall_p50 => "wall_p50",
            .wall_p99 => "wall_p99",
            .gpu_ns => "gpu_ns",
            .draw_calls => "draw_calls",
            .upload_bytes => "upload_bytes",
            .allocs_in_frame => "allocs_in_frame",
            .gpu_resources_in_frame => "gpu_resources_in_frame",
            .arena_high_water => "arena_high_water",
            .rss_bytes => "rss_bytes",
            .frames => "frames",
        };
    }

    /// Where the value lives in the report schema.
    fn section(self: Metric) []const u8 {
        return switch (self) {
            .work_p50, .work_p99, .work_p999, .work_max, .wall_p50, .wall_p99 => "frame_ms",
            .draw_calls, .upload_bytes, .allocs_in_frame, .gpu_resources_in_frame, .arena_high_water, .gpu_ns, .rss_bytes => "counters",
            .frames => "",
        };
    }

    fn unit(self: Metric) []const u8 {
        return switch (self) {
            .work_p50, .work_p99, .work_p999, .work_max, .wall_p50, .wall_p99 => "ms",
            .gpu_ns => "ns",
            .draw_calls, .allocs_in_frame, .gpu_resources_in_frame, .frames => " ",
            .upload_bytes, .arena_high_water, .rss_bytes => "B",
        };
    }
};

fn out(comptime fmt: []const u8, args: anytype) void {
    std.debug.print(fmt ++ "\n", args);
}

fn ms(value: f64) f64 {
    return value / 1_000_000.0;
}

const Report = struct {
    text: []const u8,
    frames: f64 = 0,
    warmup: f64 = 0,
    measured: f64 = 0,

    fn value(self: Report, metric: Metric) f64 {
        const region: []const u8 = if (metric.section().len == 0)
            ""
        else
            sectionOf(self.text, metric.section());
        const hay: []const u8 = if (region.len == 0) self.text else region;
        return self.scanNumberIn(hay, metric.key());
    }

    /// Finds `"name":` inside `text` and parses the number that follows.
    fn scanNumberIn(self: Report, text: []const u8, name: []const u8) f64 {
        _ = self;
        var key: [96]u8 = undefined;
        const needle = std.fmt.bufPrint(&key, "\"{s}\":", .{name}) catch return 0;
        const at = std.mem.indexOf(u8, text, needle) orelse return 0;
        return parseNumber(text[at + needle.len ..]);
    }

    /// Flat top-level numeric field (frames, measured, warmup_frames, tsc_hz...).
    fn valueFrom(self: Report, name: []const u8) f64 {
        return self.scanNumberIn(self.text, name);
    }

    /// Flat integer field.
    fn intField(self: Report, name: []const u8) u64 {
        return @intFromFloat(self.valueFrom(name));
    }

    /// Integer field inside the "counters" object.
    fn intField2(self: Report, name: []const u8) u64 {
        const region = sectionOf(self.text, "counters");
        if (region.len == 0) return 0;
        return @intFromFloat(self.scanNumberIn(region, name));
    }

    fn boolField(self: Report, name: []const u8) bool {
        var key: [96]u8 = undefined;
        const needle = std.fmt.bufPrint(&key, "\"{s}\":", .{name}) catch return false;
        const at = std.mem.indexOf(u8, self.text, needle) orelse return false;
        return std.mem.startsWith(u8, self.text[at + needle.len ..], "true");
    }

    fn stringField(self: Report, name: []const u8) []const u8 {
        var key: [96]u8 = undefined;
        const needle = std.fmt.bufPrint(&key, "\"{s}\":\"", .{name}) catch return "?";
        const at = std.mem.indexOf(u8, self.text, needle) orelse return "?";
        const rest = self.text[at + needle.len ..];
        const end = std.mem.indexOfScalar(u8, rest, '"') orelse return "?";
        return rest[0..end];
    }

    /// Verdicts that FAILED, as a comma-separated list (or "none").
    fn failedVerdicts(self: Report, buf: []u8) []const u8 {
        var written: usize = 0;
        var count: usize = 0;
        const start_marker = "\"verdicts\":[";
        const at = std.mem.indexOf(u8, self.text, start_marker) orelse {
            return "unknown (no verdicts section)";
        };
        const region = self.text[at + start_marker.len ..];
        var i: usize = 0;
        while (i < region.len) {
            const fail_at = std.mem.indexOf(u8, region[i..], "\"status\":\"fail\"") orelse break;
            const abs = i + fail_at;
            // walk back to the start of this object and read its name
            var obj_start = abs;
            while (obj_start > 0 and region[obj_start] != '{') obj_start -= 1;
            const name_key = "\"name\":\"";
            const name_at = std.mem.indexOf(u8, region[obj_start..abs], name_key) orelse {
                i = abs + 14;
                continue;
            };
            const name_start = obj_start + name_at + name_key.len;
            const name_end = std.mem.indexOfScalar(u8, region[name_start..abs], '"') orelse abs;
            const name = region[name_start..name_end];
            if (count > 0 and written + 2 < buf.len) {
                @memcpy(buf[written..][0..2], ", ");
                written += 2;
            }
            const n = @min(name.len, buf.len - written);
            @memcpy(buf[written..][0..n], name[0..n]);
            written += n;
            count += 1;
            i = abs + 14;
        }
        if (count == 0) return "none";
        return buf[0..written];
    }
};

/// The body of a top-level object ("frame_ms", "counters") so that keys with
/// the same name in different sections do not collide.
fn sectionOf(text: []const u8, section: []const u8) []const u8 {
    var tag_buf: [64]u8 = undefined;
    const tag = std.fmt.bufPrint(&tag_buf, "\"{s}\":{{", .{section}) catch return "";
    const at = std.mem.indexOf(u8, text, tag) orelse return "";
    const rest = text[at + tag.len ..];
    const end = std.mem.indexOfScalar(u8, rest, '}') orelse return rest;
    return rest[0..end];
}

/// Parses a leading decimal number from a JSON value position.
fn parseNumber(text: []const u8) f64 {
    var i: usize = 0;
    while (i < text.len and (text[i] == '-' or (text[i] >= '0' and text[i] <= '9') or text[i] == '.' or text[i] == 'e' or text[i] == 'E' or text[i] == '+')) : (i += 1) {}
    return std.fmt.parseFloat(f64, text[0..i]) catch 0;
}

const Args = struct {
    path: ?[:0]const u8 = null,
    baseline: ?[:0]const u8 = null,
    tolerance: f64 = 0.05,
};

pub fn main(init: std.process.Init.Minimal) !void {
    var args = Args{};
    // Allocator-free argument iteration (posix), same as the runtime.
    var arg_it = std.process.Args.Iterator.init(init.args);
    _ = arg_it.next(); // program name
    while (arg_it.next()) |arg| {
        if (std.mem.eql(u8, arg, "--baseline")) {
            args.baseline = arg_it.next();
        } else if (std.mem.eql(u8, arg, "--tolerance")) {
            if (arg_it.next()) |t| args.tolerance = std.fmt.parseFloat(f64, t) catch 0.05;
        } else if (std.mem.eql(u8, arg, "--help") or std.mem.eql(u8, arg, "-h")) {
            out("{s}", .{USAGE});
            return;
        } else {
            args.path = arg;
        }
    }
    if (args.path == null) {
        out("{s}", .{USAGE});
        std.process.exit(@intFromEnum(ExitCode.bad_input));
    }

    var buf: [64 * 1024]u8 = undefined;
    const len = core.readFileToBuf(args.path.?, &buf) orelse {
        out("error: cannot read {s}", .{args.path.?});
        std.process.exit(@intFromEnum(ExitCode.bad_input));
    };
    if (len >= buf.len) {
        out("error: report too large ({d} bytes)", .{len});
        std.process.exit(@intFromEnum(ExitCode.bad_input));
    }
    var report = Report{ .text = buf[0..len] };
    report.frames = report.value(.frames);
    report.warmup = report.valueFrom("warmup_frames");
    report.measured = report.valueFrom("measured");

    // ── human table ─────────────────────────────────────────────────────────
    out("== ember profile: {s} ==", .{report.stringField("backend")});
    out("  clock {s} ({d} Hz)  vsync {s}  mode {s}", .{
        report.stringField("clock"),
        report.intField("tsc_hz"),
        if (report.boolField("vsync")) "on" else "off",
        report.stringField("mode"),
    });
    out("  frames {d} (warm-up {d}, measured {d})", .{ report.frames, report.warmup, report.measured });
    out("  frame work: p50 {d:.3} ms  p99 {d:.3} ms  p99.9 {d:.3} ms  max {d:.3} ms", .{
        report.value(.work_p50),
        report.value(.work_p99),
        report.value(.work_p999),
        report.value(.work_max),
    });
    out("  frame wall: p50 {d:.3} ms  p99 {d:.3} ms", .{ report.value(.wall_p50), report.value(.wall_p99) });
    out("  gpu {d:.3} ms   draw calls {d}   uploads {d} B/frame   allocs in frame {d}", .{
        ms(report.value(.gpu_ns)),
        report.intField2("draw_calls"),
        report.intField2("upload_bytes"),
        report.intField2("allocs_in_frame"),
    });
    out("  arena high-water {d} B   rss {d:.1} MiB", .{
        report.intField2("arena_high_water"),
        @as(f64, @floatFromInt(report.intField2("rss_bytes"))) / (1024.0 * 1024.0),
    });

    var names_buf: [256]u8 = undefined;
    if (!report.boolField("pass")) {
        out("  spec.md verdicts FAILED: {s}", .{report.failedVerdicts(&names_buf)});
    } else {
        out("  spec.md verdicts: all pass", .{});
    }

    // ── gate ────────────────────────────────────────────────────────────────
    var failures: usize = 0;
    if (args.baseline) |bp| {
        var base_buf: [64 * 1024]u8 = undefined;
        const base_len = core.readFileToBuf(bp, &base_buf) orelse {
            out("error: cannot read baseline {s}", .{bp});
            std.process.exit(@intFromEnum(ExitCode.bad_input));
        };
        const baseline = Report{ .text = base_buf[0..base_len] };
        out("== regression gate (tolerance {d:.1}%) ==", .{args.tolerance * 100.0});
        inline for (@typeInfo(Metric).@"enum".fields) |f| {
            // `continue` on a runtime condition is not allowed inside an
            // inline for: use a bool guard instead.
            const metric: Metric = @enumFromInt(f.value);
            const new = report.value(metric);
            const old = baseline.value(metric);
            if (new != 0 and old != 0) {
                const delta = (new - old) / old;
                const status = if (delta > args.tolerance) "REGRESSION" else "ok";
                if (delta > args.tolerance) failures += 1;
                const sign: u8 = if (delta >= 0) '+' else '-';
                out("  {s:<24} {d:>14.3} {s:<3} vs {d:>14.3} {s:<3}  {c}{d:>6.1}%  {s}", .{
                    f.name,
                    new,
                    metric.unit(),
                    old,
                    metric.unit(),
                    sign,
                    @abs(delta * 100.0),
                    status,
                });
            }
        }
        if (failures == 0) {
            out("  gate: PASS (no metric above the tolerance)", .{});
        } else {
            out("  gate: FAIL ({d} metric(s) regressed above the tolerance)", .{failures});
        }
    }

    const verdicts_ok = report.boolField("pass");
    if (failures > 0 or !verdicts_ok) {
        std.process.exit(@intFromEnum(ExitCode.gate_failed));
    }
}
