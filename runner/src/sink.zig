//! LogSink (SPEC §5.1). The runner must work with `StdoutSink` alone; `PostgresSink` comes with M5.
const std = @import("std");
const redact = @import("redact.zig");

pub const Stream = enum { stdout, stderr };

pub const StdoutSink = struct {
    writer: *std.Io.Writer,
    secrets: []const []const u8 = &.{},

    /// Buffered; never blocks on anything but the underlying writer.
    pub fn append(s: *StdoutSink, job_id: u64, step_number: u32, stream: Stream, line: []const u8) !void {
        try s.writer.print("[job {d} step {d} {s}] ", .{ job_id, step_number, @tagName(stream) });
        try redact.write(s.writer, line, s.secrets);
        try s.writer.writeByte('\n');
        // Dev sink: show lines as they arrive so streaming is visible.
        try s.writer.flush();
    }

    pub fn flush(s: *StdoutSink) !void {
        try s.writer.flush();
    }

    pub fn close(s: *StdoutSink) void {
        s.flush() catch {};
    }
};

/// Closed set of implementations; dispatch is a switch, so no vtable or allocation.
pub const LogSink = union(enum) {
    stdout: StdoutSink,

    pub fn append(s: *LogSink, job_id: u64, step_number: u32, stream: Stream, line: []const u8) !void {
        switch (s.*) {
            inline else => |*impl| try impl.append(job_id, step_number, stream, line),
        }
    }

    /// Replaces the redaction list (e.g. with a job's secrets once it is known).
    pub fn setSecrets(s: *LogSink, secrets: []const []const u8) void {
        switch (s.*) {
            inline else => |*impl| impl.secrets = secrets,
        }
    }

    pub fn flush(s: *LogSink) !void {
        switch (s.*) {
            inline else => |*impl| try impl.flush(),
        }
    }

    pub fn close(s: *LogSink) void {
        switch (s.*) {
            inline else => |*impl| impl.close(),
        }
    }
};

test "stdout sink formats and redacts" {
    var buf: [256]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buf);
    var sink: LogSink = .{ .stdout = .{ .writer = &w, .secrets = &.{"s3cret"} } };
    try sink.append(7, 2, .stderr, "key=s3cret \x1b[31mred\x1b[0m");
    try sink.flush();
    try std.testing.expectEqualStrings("[job 7 step 2 stderr] key=*** \x1b[31mred\x1b[0m\n", w.buffered());
}
