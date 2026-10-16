//! LogSink (SPEC §5.1). The runner must work with `StdoutSink` alone; `PostgresSink` comes with M5.
const std = @import("std");
const redact = @import("redact.zig");
const pgsink = @import("pgsink.zig");

pub const Stream = enum { stdout, stderr };

/// Explicit because LogSink and CollectSink call each other.
pub const Error = std.Io.Writer.Error || std.mem.Allocator.Error;

pub const StdoutSink = struct {
    writer: *std.Io.Writer,
    secrets: []const []const u8 = &.{},
    /// Set when several runners in the process share the sink: each line is written whole.
    io: ?std.Io = null,
    mu: std.Io.Mutex = .init,

    /// Buffered; never blocks on anything but the underlying writer.
    pub fn append(s: *StdoutSink, job_id: u64, step_number: u32, stream: Stream, line: []const u8) Error!void {
        if (s.io) |io| s.mu.lockUncancelable(io);
        defer if (s.io) |io| s.mu.unlock(io);
        try s.writer.print("[job {d} step {d} {s}] ", .{ job_id, step_number, @tagName(stream) });
        try redact.write(s.writer, line, s.secrets);
        try s.writer.writeByte('\n');
        // Dev sink: show lines as they arrive so streaming is visible.
        try s.writer.flush();
    }

    pub fn flush(s: *StdoutSink) Error!void {
        if (s.io) |io| s.mu.lockUncancelable(io);
        defer if (s.io) |io| s.mu.unlock(io);
        try s.writer.flush();
    }

    pub fn close(s: *StdoutSink) void {
        s.flush() catch {};
    }
};

/// `seq` is the line's place in its step's output, counted from 1 and assigned when the line is
/// logged rather than when it is sent. Everything downstream — the live feed's `startLine`, a retry,
/// an upload — can then say where a line belongs without counting arrivals, which is what let the
/// feed's numbering and the uploaded log's drift apart when a line was dropped at the cap.
pub const CollectedLine = struct { step: u32, seq: u64, ts_ms: i64, text: []const u8 };

/// A job's log on disk, written as it is logged, so that the copy the upload reads is not the only
/// copy and does not sit in memory for the length of the job. Other runners spool the same way:
/// Airflow's task handlers write a local file and serve it live, Buildkite's agent has
/// `--enable-job-log-tmpfile` (docs/RELATED.md, "Streaming a step's output").
///
/// A record is `<step> <seq> <ts_ms> <bytes>\n<text>\n`, length-prefixed so a line may contain
/// anything. Writing is best-effort: logging must never fail a job, so a failed write turns the
/// spool off for the rest of the job and falls back to keeping lines in memory.
pub const Spool = struct {
    file: std.Io.File,
    io: std.Io,
    buf: [8 * 1024]u8 = undefined,
    /// One writer for the spool's lifetime, so the file position advances: `File.writer` is
    /// positional and would put every record at the start. It points at `buf`, so a Spool must not
    /// be copied once it has been written to.
    w: ?std.Io.File.Writer = null,
    /// Bytes written, for the same cap the in-memory path has.
    bytes: usize = 0,
    /// Set when a write failed: the sink then keeps lines in memory instead.
    broken: bool = false,

    fn write(sp: *Spool, line: CollectedLine) void {
        if (sp.w == null) sp.w = sp.file.writerStreaming(sp.io, &sp.buf);
        const w = &sp.w.?.interface;
        w.print("{d} {d} {d} {d}\n{s}\n", .{ line.step, line.seq, line.ts_ms, line.text.len, line.text }) catch {
            sp.broken = true;
            return;
        };
        // Flushed per line: the point of the spool is that it is on disk before the job ends.
        w.flush() catch {
            sp.broken = true;
            return;
        };
        sp.bytes += line.text.len;
    }

    /// Every record, in the order they were written. The caller owns the result.
    pub fn read(sp: *Spool, arena: std.mem.Allocator) ![]CollectedLine {
        var out: std.ArrayList(CollectedLine) = .empty;
        // A positional reader: it starts at the beginning whatever the write position is, and does
        // not disturb it.
        var buf: [64 * 1024]u8 = undefined;
        var r = sp.file.reader(sp.io, &buf);
        const all = r.interface.allocRemaining(arena, .limited(CollectSink.max_bytes)) catch return out.items;
        var rest = all;
        while (rest.len > 0) {
            const nl = std.mem.indexOfScalar(u8, rest, '\n') orelse break;
            const header = rest[0..nl];
            rest = rest[nl + 1 ..];
            var it = std.mem.tokenizeScalar(u8, header, ' ');
            const step = std.fmt.parseInt(u32, it.next() orelse break, 10) catch break;
            const seq = std.fmt.parseInt(u64, it.next() orelse break, 10) catch break;
            const ts = std.fmt.parseInt(i64, it.next() orelse break, 10) catch break;
            const len = std.fmt.parseInt(usize, it.next() orelse break, 10) catch break;
            if (rest.len < len + 1) break;
            try out.append(arena, .{ .step = step, .seq = seq, .ts_ms = ts, .text = rest[0..len] });
            rest = rest[len + 1 ..];
        }
        return out.items;
    }
};

/// Redacts every line with the job's secrets, forwards it to `inner`, and keeps a timestamped copy so
/// the job's logs can be uploaded to GitHub once it finishes — on disk when a `spool` is set, in
/// memory otherwise. Either way it is capped; lines past the cap are forwarded and counted, not kept.
/// Redacting here, not in `inner`, keeps the job's secrets (which live as long as the job) out of the
/// runner's shared sinks.
pub const CollectSink = struct {
    arena: std.mem.Allocator,
    io: std.Io,
    inner: *LogSink,
    secrets: []const []const u8 = &.{},
    lines: std.ArrayList(CollectedLine) = .empty,
    /// Where the lines go instead of `lines`, when the runner could open one.
    spool: ?*Spool = null,
    /// The last result of `collected`, so reading the spool twice at the end of a job reads the file
    /// once. Cleared by `append`, so a line logged in between is never missed.
    cache: ?[]const CollectedLine = null,
    /// The next sequence number for each step, indexed by step number.
    seqs: std.ArrayList(u64) = .empty,
    bytes: usize = 0,
    dropped: usize = 0,
    /// Told of every line as it is logged, redacted (the live log in GitHub's UI, see `live.zig`).
    listener: ?Listener = null,

    pub const max_bytes: usize = 64 * 1024 * 1024;

    pub const Listener = struct {
        ptr: *anyopaque,
        onLine: *const fn (ptr: *anyopaque, step: u32, seq: u64, text: []const u8) void,
    };

    /// The next number for `step`, counted from 1. A line dropped at the cap still takes one, so a
    /// gap in what was kept is visible rather than silent.
    fn nextSeq(s: *CollectSink, step: u32) u64 {
        while (s.seqs.items.len <= step) s.seqs.append(s.arena, 0) catch return 0;
        s.seqs.items[step] += 1;
        return s.seqs.items[step];
    }

    pub fn append(s: *CollectSink, job_id: u64, step_number: u32, stream: Stream, line: []const u8) Error!void {
        var aw: std.Io.Writer.Allocating = .init(s.arena);
        try redact.write(&aw.writer, line, s.secrets);
        const text = aw.written();
        s.cache = null;
        const seq = s.nextSeq(step_number);
        // The number goes down with the line, so the database row and the line GitHub shows carry
        // the same one rather than two counters that happen to agree.
        try s.inner.appendStep(job_id, step_number, seq, stream, text);
        if (s.listener) |l| l.onLine(l.ptr, step_number, seq, text);
        if (s.bytes + text.len > max_bytes) {
            s.dropped += 1;
            return;
        }
        s.bytes += text.len;
        const kept: CollectedLine = .{
            .step = step_number,
            .seq = seq,
            .ts_ms = std.Io.Clock.real.now(s.io).toMilliseconds(),
            .text = text,
        };
        if (s.spool) |sp| {
            if (!sp.broken) {
                sp.write(kept);
                if (!sp.broken) return;
            }
        }
        try s.lines.append(s.arena, kept);
    }

    pub fn flush(s: *CollectSink) Error!void {
        try s.inner.flush();
    }

    /// Every line the job logged and the sink kept: from the spool when there is one, and from
    /// memory otherwise — including the lines memory holds because a spool write failed part way.
    pub fn collected(s: *CollectSink, arena: std.mem.Allocator) []const CollectedLine {
        const sp = s.spool orelse return s.lines.items;
        if (s.cache) |c| return c;
        const spooled = sp.read(arena) catch return s.lines.items;
        const all = if (s.lines.items.len == 0)
            spooled
        else
            std.mem.concat(arena, CollectedLine, &.{ spooled, s.lines.items }) catch spooled;
        s.cache = all;
        return all;
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
    postgres: pgsink.PgSink,

    /// As `append`, with the line's number in its own step where the caller knows it. Only
    /// `CollectSink` does; everything else logs through `append`.
    pub fn appendStep(s: *LogSink, job_id: u64, step_number: u32, step_seq: ?u64, stream: Stream, line: []const u8) Error!void {
        return switch (s.*) {
            .postgres => |*p| p.appendStep(job_id, step_number, step_seq, stream, line),
            // The console and the collector show a line the same way whatever its number is.
            else => s.append(job_id, step_number, stream, line),
        };
    }

    pub fn append(s: *LogSink, job_id: u64, step_number: u32, stream: Stream, line: []const u8) Error!void {
        switch (s.*) {
            inline else => |*impl| try impl.append(job_id, step_number, stream, line),
        }
    }

    /// The current redaction list.
    pub fn currentSecrets(s: *LogSink) []const []const u8 {
        return switch (s.*) {
            inline else => |*impl| impl.secrets,
        };
    }

    /// Replaces the redaction list (e.g. with a job's secrets once it is known).
    pub fn setSecrets(s: *LogSink, secrets: []const []const u8) void {
        switch (s.*) {
            .collect => |*c| c.secrets = secrets,
            .postgres => |*p| {
                p.secrets = secrets;
                p.inner.setSecrets(secrets);
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
    // The job's secrets stay with the job's sink; the shared sink gets redacted text.
    try std.testing.expectEqual(@as(usize, 0), inner.currentSecrets().len);
    try std.testing.expectEqualStrings("[job 1 step 2 stdout] token=*** ok\n", w.buffered());
    const c = sink.collect;
    try std.testing.expectEqual(@as(usize, 1), c.lines.items.len);
    try std.testing.expectEqual(@as(u32, 2), c.lines.items[0].step);
    try std.testing.expectEqualStrings("token=*** ok", c.lines.items[0].text);
    try std.testing.expect(c.lines.items[0].ts_ms > 0);
}

test "collect sink numbers each step's lines from one, and a dropped line still takes a number" {
    var buf: [4096]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buf);
    var inner: LogSink = .{ .stdout = .{ .writer = &w } };
    var a: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer a.deinit();
    var sink: LogSink = .{ .collect = .{ .arena = a.allocator(), .io = std.testing.io, .inner = &inner } };

    // Two steps, interleaved: each counts its own lines.
    try sink.append(1, 1, .stdout, "one");
    try sink.append(1, 2, .stdout, "a");
    try sink.append(1, 1, .stdout, "two");
    try sink.append(1, 2, .stdout, "b");
    const seqs = [_]u64{ 1, 1, 2, 2 };
    const steps = [_]u32{ 1, 2, 1, 2 };
    for (sink.collect.lines.items, seqs, steps) |l, seq, step| {
        try std.testing.expectEqual(seq, l.seq);
        try std.testing.expectEqual(step, l.step);
    }

    // Past the cap a line is forwarded and counted but not kept — and it still takes its number, so
    // the next line that is kept does not quietly inherit it. A gap in the numbers is the record of
    // a gap in the log.
    sink.collect.bytes = CollectSink.max_bytes;
    try sink.append(1, 1, .stdout, "dropped");
    try std.testing.expectEqual(@as(usize, 1), sink.collect.dropped);
    sink.collect.bytes = 0;
    try sink.append(1, 1, .stdout, "kept");
    const last = sink.collect.lines.items[sink.collect.lines.items.len - 1];
    try std.testing.expectEqual(@as(u64, 4), last.seq);
    try std.testing.expectEqualStrings("kept", last.text);
}

test "a spooled job's lines come back from disk, in order, with their numbers" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const file = try tmp.dir.createFile(std.testing.io, "spool", .{ .read = true });
    defer file.close(std.testing.io);

    var buf: [1024]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buf);
    var inner: LogSink = .{ .stdout = .{ .writer = &w } };
    var a: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer a.deinit();
    var spool: Spool = .{ .file = file, .io = std.testing.io };
    var sink: LogSink = .{ .collect = .{
        .arena = a.allocator(),
        .io = std.testing.io,
        .inner = &inner,
        .spool = &spool,
    } };

    try sink.append(1, 1, .stdout, "first");
    try sink.append(1, 2, .stdout, "other step");
    // A line with a newline in it: the record is length-prefixed, so it survives whole.
    try sink.append(1, 1, .stdout, "two\nlines");

    // Nothing is held in memory for the length of the job.
    try std.testing.expectEqual(@as(usize, 0), sink.collect.lines.items.len);

    const back = sink.collect.collected(a.allocator());
    try std.testing.expectEqual(@as(usize, 3), back.len);
    try std.testing.expectEqual(@as(u32, 1), back[0].step);
    try std.testing.expectEqual(@as(u64, 1), back[0].seq);
    try std.testing.expectEqualStrings("first", back[0].text);
    try std.testing.expectEqual(@as(u32, 2), back[1].step);
    try std.testing.expectEqual(@as(u64, 1), back[1].seq);
    try std.testing.expectEqual(@as(u64, 2), back[2].seq);
    try std.testing.expectEqualStrings("two\nlines", back[2].text);
}

test "a spool that breaks falls back to memory, and both halves come back" {
    var buf: [1024]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buf);
    var inner: LogSink = .{ .stdout = .{ .writer = &w } };
    var a: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer a.deinit();
    // Marked broken from the start: a disk that stopped taking writes, without needing one.
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const file = try tmp.dir.createFile(std.testing.io, "spool", .{ .read = true });
    defer file.close(std.testing.io);
    var spool: Spool = .{ .file = file, .io = std.testing.io, .broken = true };
    var sink: LogSink = .{ .collect = .{
        .arena = a.allocator(),
        .io = std.testing.io,
        .inner = &inner,
        .spool = &spool,
    } };
    try sink.append(1, 1, .stdout, "kept in memory");
    const back = sink.collect.collected(a.allocator());
    try std.testing.expectEqual(@as(usize, 1), back.len);
    try std.testing.expectEqualStrings("kept in memory", back[0].text);
}

test "a spool is read once for two callers, and again after a new line" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const file = try tmp.dir.createFile(std.testing.io, "spool", .{ .read = true });
    defer file.close(std.testing.io);
    var buf: [256]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buf);
    var inner: LogSink = .{ .stdout = .{ .writer = &w } };
    var a: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer a.deinit();
    var spool: Spool = .{ .file = file, .io = std.testing.io };
    var sink: LogSink = .{ .collect = .{ .arena = a.allocator(), .io = std.testing.io, .inner = &inner, .spool = &spool } };

    try sink.append(1, 1, .stdout, "one");
    const first = sink.collect.collected(a.allocator());
    const again = sink.collect.collected(a.allocator());
    try std.testing.expectEqual(first.ptr, again.ptr); // the same read, not a second one
    try sink.append(1, 1, .stdout, "two");
    const after = sink.collect.collected(a.allocator());
    try std.testing.expectEqual(@as(usize, 2), after.len);
}
