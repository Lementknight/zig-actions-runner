//! LogSink (SPEC §5.1). The runner must work with `StdoutSink` alone; `PostgresSink` comes with M5.
const std = @import("std");
const redact = @import("redact.zig");

pub const Stream = enum { stdout, stderr };

/// Explicit because LogSink and CollectSink call each other.
pub const Error = std.Io.Writer.Error || std.mem.Allocator.Error;

pub const StdoutSink = struct {
    writer: *std.Io.Writer,
    secrets: []const []const u8 = &.{},

    /// Buffered; never blocks on anything but the underlying writer.
    pub fn append(s: *StdoutSink, job_id: u64, step_number: u32, stream: Stream, line: []const u8) Error!void {
        try s.writer.print("[job {d} step {d} {s}] ", .{ job_id, step_number, @tagName(stream) });
        try redact.write(s.writer, line, s.secrets);
        try s.writer.writeByte('\n');
        // Dev sink: show lines as they arrive so streaming is visible.
        try s.writer.flush();
    }

    pub fn flush(s: *StdoutSink) Error!void {
        try s.writer.flush();
    }

    pub fn close(s: *StdoutSink) void {
        s.flush() catch {};
    }
};

pub const CollectedLine = struct { step: u32, ts_ms: i64, text: []const u8 };

/// Forwards every line to `inner` and keeps a redacted, timestamped copy so the job's logs can be
/// uploaded to GitHub once it finishes. Memory is capped; lines past the cap are counted, not kept.
pub const CollectSink = struct {
    arena: std.mem.Allocator,
    io: std.Io,
    inner: *LogSink,
    secrets: []const []const u8 = &.{},
    lines: std.ArrayList(CollectedLine) = .empty,
    bytes: usize = 0,
    dropped: usize = 0,

    pub const max_bytes: usize = 64 * 1024 * 1024;

    pub fn append(s: *CollectSink, job_id: u64, step_number: u32, stream: Stream, line: []const u8) Error!void {
        try s.inner.append(job_id, step_number, stream, line);
        if (s.bytes + line.len > max_bytes) {
            s.dropped += 1;
            return;
        }
        var aw: std.Io.Writer.Allocating = .init(s.arena);
        try redact.write(&aw.writer, line, s.secrets);
        const text = aw.written();
        s.bytes += text.len;
        try s.lines.append(s.arena, .{ .step = step_number, .ts_ms = std.Io.Clock.real.now(s.io).toMilliseconds(), .text = text });
    }

    pub fn flush(s: *CollectSink) Error!void {
        try s.inner.flush();
    }

    /// The inner sink is owned by the caller.
    pub fn close(s: *CollectSink) void {
        _ = s;
    }
};

/// Closed set of implementations; dispatch is a switch, so no vtable or allocation.
pub const LogSink = union(enum) {
    stdout: StdoutSink,
    collect: CollectSink,

    pub fn append(s: *LogSink, job_id: u64, step_number: u32, stream: Stream, line: []const u8) Error!void {
        switch (s.*) {
            inline else => |*impl| try impl.append(job_id, step_number, stream, line),
        }
    }

    /// Replaces the redaction list (e.g. with a job's secrets once it is known).
    pub fn setSecrets(s: *LogSink, secrets: []const []const u8) void {
        switch (s.*) {
            .collect => |*c| {
                c.secrets = secrets;
                c.inner.setSecrets(secrets);
            },
            inline else => |*impl| impl.secrets = secrets,
        }
    }

    pub fn flush(s: *LogSink) Error!void {
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

test "collect sink forwards, redacts and timestamps" {
    var buf: [256]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buf);
    var inner: LogSink = .{ .stdout = .{ .writer = &w } };
    var a: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer a.deinit();
    var sink: LogSink = .{ .collect = .{ .arena = a.allocator(), .io = std.testing.io, .inner = &inner } };
    sink.setSecrets(&.{"s3cret"});
    try sink.append(1, 2, .stdout, "token=s3cret ok");
    try std.testing.expectEqualStrings("[job 1 step 2 stdout] token=*** ok\n", w.buffered());
    const c = sink.collect;
    try std.testing.expectEqual(@as(usize, 1), c.lines.items.len);
    try std.testing.expectEqual(@as(u32, 2), c.lines.items[0].step);
    try std.testing.expectEqualStrings("token=*** ok", c.lines.items[0].text);
    try std.testing.expect(c.lines.items[0].ts_ms > 0);
}
