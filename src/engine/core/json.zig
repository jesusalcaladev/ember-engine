//! Minimal allocation-free JSON writer (libc file I/O + fixed buffer).
//!
//! Used for the machine-readable report (`report.json`, which the CI gate
//! consumes) and for the Chrome/Perfetto trace. Not a general JSON library:
//! flat schemas, commas are explicit, escaping is the minimum.
//!
//! Like everything in core: no allocations, no std.Io. The file is always
//! flushed and closed outside the frame loop (spec §3.4).

const std = @import("std");

pub const O_WRONLY: c_int = 1;
pub const O_CREAT: c_int = 0o100;
pub const O_TRUNC: c_int = 0o1000;
pub const O_RDONLY: c_int = 0;

extern "c" fn open(path: [*:0]const u8, flags: c_int, ...) c_int;
extern "c" fn close(fd: c_int) c_int;
extern "c" fn read(fd: c_int, buf: [*]u8, count: usize) isize;
extern "c" fn write(fd: c_int, buf: [*]const u8, count: usize) isize;
extern "c" fn unlink(path: [*:0]const u8) c_int;

comptime {
    _ = open;
    _ = close;
    _ = read;
    _ = write;
    _ = unlink;
}

/// Reads a whole (small) file into `buf`. Used by the tests and by
/// tools/profile (the CI gate), which reports with a fixed buffer.
pub fn readWholeFile(path: [*:0]const u8, buf: []u8) ?usize {
    const fd = open(path, O_RDONLY, @as(c_int, 0));
    if (fd < 0) return null;
    defer _ = close(fd);
    const n = read(fd, buf.ptr, buf.len);
    if (n < 0) return null;
    return @intCast(n);
}

pub const Error = error{ OpenFailed, WriteFailed };

pub const Writer = struct {
    buf: [8192]u8 = undefined,
    len: usize = 0,
    fd: c_int = -1,
    err: ?anyerror = null,
    scratch: [64]u8 = undefined,

    /// Opens `path` for writing (truncating). `deinit` flushes and closes.
    pub fn create(path: [*:0]const u8) Error!Writer {
        const fd = open(path, O_WRONLY | O_CREAT | O_TRUNC, @as(c_int, 0o644));
        if (fd < 0) return error.OpenFailed;
        return .{ .fd = fd };
    }

    pub fn deinit(self: *Writer) void {
        self.flush();
        if (self.fd >= 0) {
            _ = close(self.fd);
            self.fd = -1;
        }
    }

    pub fn ok(self: *const Writer) bool {
        return self.err == null;
    }

    /// Object member. Commas are EXPLICIT (`raw(",")` before each member
    /// except the first): the schemas here are flat, and auto-comma logic
    /// produces `,,` as soon as two layers disagree.
    pub fn field(self: *Writer, name: []const u8) void {
        self.str(name);
        self.raw(":");
    }

    pub fn startObject(self: *Writer) void {
        self.raw("{");
    }

    pub fn endObject(self: *Writer) void {
        self.raw("}");
    }

    pub fn startArray(self: *Writer) void {
        self.raw("[");
    }

    pub fn endArray(self: *Writer) void {
        self.raw("]");
    }

    /// Raw bytes (formatting is explicit on purpose).
    pub fn raw(self: *Writer, bytes: []const u8) void {
        if (self.err != null) return;
        if (self.len + bytes.len > self.buf.len) {
            self.flush();
            if (self.err != null) return;
            if (bytes.len > self.buf.len) {
                _ = self.writeAll(bytes);
                return;
            }
        }
        @memcpy(self.buf[self.len..][0..bytes.len], bytes);
        self.len += bytes.len;
    }

    pub fn rawByte(self: *Writer, b: u8) void {
        self.raw(&[_]u8{b});
    }

    pub fn flush(self: *Writer) void {
        if (self.len == 0) return;
        if (self.fd < 0) {
            self.len = 0;
            self.err = error.WriteFailed;
            return;
        }
        _ = self.writeAll(self.buf[0..self.len]);
        self.len = 0;
    }

    fn writeAll(self: *Writer, bytes: []const u8) bool {
        var off: usize = 0;
        while (off < bytes.len) {
            const n = write(self.fd, bytes.ptr + off, bytes.len - off);
            if (n <= 0) {
                self.err = error.WriteFailed;
                return false;
            }
            off += @intCast(n);
        }
        return true;
    }

    // ── value helpers ───────────────────────────────────────────────────────

    pub fn str(self: *Writer, value: []const u8) void {
        self.raw("\"");
        for (value) |c| {
            switch (c) {
                '"' => self.raw("\\\""),
                '\\' => self.raw("\\\\"),
                '\n' => self.raw("\\n"),
                '\r' => self.raw("\\r"),
                '\t' => self.raw("\\t"),
                0...8, 11, 12, 14...31 => self.raw("?"),
                else => self.raw(&[_]u8{c}),
            }
        }
        self.raw("\"");
    }

    pub fn num(self: *Writer, value: anytype) void {
        const text = std.fmt.bufPrint(&self.scratch, "{d}", .{value}) catch {
            self.err = error.WriteFailed;
            return;
        };
        self.raw(text);
    }

    pub fn numFloat(self: *Writer, value: f64) void {
        const text = std.fmt.bufPrint(&self.scratch, "{d:.3}", .{value}) catch {
            self.err = error.WriteFailed;
            return;
        };
        self.raw(text);
    }
};

const flat_json = "{\"name\":\"ember\",\"frames\":1200,\"p50_ms\":7.500,\"pass\":true}";

test "json writer produces the expected shape" {
    var w = Writer{};
    w.raw("{");
    w.field("name");
    w.str("ember");
    w.raw(",");
    w.field("frames");
    w.num(@as(u64, 1200));
    w.raw(",");
    w.field("p50_ms");
    w.numFloat(7.5);
    w.raw(",");
    w.field("pass");
    w.raw("true");
    w.raw("}");
    try std.testing.expect(w.ok());
    try std.testing.expectEqualStrings(flat_json, w.buf[0..w.len]);
}

test "json escaping is minimal but safe" {
    var w = Writer{};
    w.str("a\"b\\c\nd");
    // expected: "a\"b\\c\nd" — quote, backslash and newline escaped.
    try std.testing.expectEqual(@as(usize, 12), w.len);
    try std.testing.expectEqual(@as(u8, '"'), w.buf[0]);
    try std.testing.expectEqual(@as(u8, 'a'), w.buf[1]);
    try std.testing.expectEqual(@as(u8, '\\'), w.buf[2]);
    try std.testing.expectEqual(@as(u8, '"'), w.buf[3]);
    try std.testing.expectEqual(@as(u8, 'n'), w.buf[9]);
    try std.testing.expectEqual(@as(u8, 'd'), w.buf[10]);
    try std.testing.expectEqual(@as(u8, '"'), w.buf[11]);
    try std.testing.expect(w.ok());
}

test "round trip through a real file" {
    const path = "/tmp/ember-json-test.json";
    var w = Writer.create(path) catch return error.SkipZigTest;
    defer {
        w.deinit();
        _ = unlink(path);
    }
    w.startObject();
    w.field("frames");
    w.num(@as(u64, 1200));
    w.raw(",");
    w.field("pass");
    w.raw("true");
    w.endObject();
    try std.testing.expect(w.ok());
    w.flush(); // make it visible to the reader before the deferred close

    var buf: [128]u8 = undefined;
    const n = readWholeFile(path, &buf) orelse return error.SkipZigTest;
    try std.testing.expectEqualStrings("{\"frames\":1200,\"pass\":true}", buf[0..n]);
}
