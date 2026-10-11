//! LogSink that writes job logs to the `job_logs` hypertable in batches (SPEC §4, §5.1).
//!
//! Lines are redacted, stamped with a per-job `seq` (1, 2, 3, ... with no gaps) and a timestamp when
//! appended, and buffered. A batch is written with one `COPY` when it reaches `flush_lines`, when
//! `flush_ms` has passed since the last write (checked on append and by a background flusher, so a
//! quiet job's last line is not stuck), and on `flush()`/`close()` (step and job end).
//!
//! The database must never fail a job. If a write fails, the lines stay buffered and the next flush
//! reconnects and retries (not more often than every 2 s); if the buffer outgrows `max_buffered`,
//! the oldest lines are dropped and counted, which is the only way a `seq` gap can appear. Every
//! line is also passed to `inner` (the console) first.
const std = @import("std");
const pg = @import("pg.zig");
const sink = @import("sink.zig");
const redact = @import("redact.zig");
const timefmt = @import("timefmt.zig");

const Allocator = std.mem.Allocator;
const Io = std.Io;

const Row = struct {
    ts_ms: i64,
    job_id: u64,
    step: u32,
    seq: u64,
    stream: sink.Stream,
    text: []u8,
};

pub const PgSink = struct {
    gpa: Allocator,
    io: Io,
    cfg: pg.Config,
    /// A scratch schema for tests; null in production.
    schema: ?[]const u8 = null,
    inner: *sink.LogSink,
    secrets: []const []const u8 = &.{},
    flush_lines: usize = 200,
    flush_ms: u32 = 500,
    max_buffered: usize = 100_000,

    mu: Io.Mutex = .init,
    client: ?*pg.Client = null,
    rows: std.ArrayList(Row) = .empty,
    next_seq: std.AutoHashMapUnmanaged(u64, u64) = .empty,
    last_flush_ms: i64 = 0,
    retry_after_ms: i64 = 0,
    written: u64 = 0,
    dropped: u64 = 0,
    /// Most recent failure, for reporting once the job is done.
    last_error: [256]u8 = undefined,
    last_error_len: usize = 0,

    stop: std.atomic.Value(bool) = .init(false),
    flusher: ?Io.Future(void) = null,

    pub fn append(s: *PgSink, job_id: u64, step_number: u32, stream: sink.Stream, line: []const u8) sink.Error!void {
        try s.inner.append(job_id, step_number, stream, line);
        // Job id 0 marks messages that belong to no job (registering, waiting for work): console only.
        if (job_id == 0) return;

        var aw: Io.Writer.Allocating = .init(s.gpa);
        defer aw.deinit();
        try redact.write(&aw.writer, line, s.secrets);
        const owned = try s.gpa.dupe(u8, aw.written());
        errdefer s.gpa.free(owned);

        s.mu.lockUncancelable(s.io);
        defer s.mu.unlock(s.io);
        const gop = try s.next_seq.getOrPut(s.gpa, job_id);
        if (!gop.found_existing) gop.value_ptr.* = 1;
        const seq = gop.value_ptr.*;
        gop.value_ptr.* += 1;
        try s.rows.append(s.gpa, .{ .ts_ms = now(s.io), .job_id = job_id, .step = step_number, .seq = seq, .stream = stream, .text = owned });
        if (s.rows.items.len >= s.flush_lines or now(s.io) - s.last_flush_ms >= s.flush_ms) s.flushLocked();
        s.enforceCap();
    }

    pub fn flush(s: *PgSink) sink.Error!void {
        try s.inner.flush();
        s.mu.lockUncancelable(s.io);
        defer s.mu.unlock(s.io);
        s.flushLocked();
    }

    pub fn close(s: *PgSink) void {
        s.stop.store(true, .release);
        if (s.flusher) |*f| f.await(s.io);
        s.flusher = null;
        s.mu.lockUncancelable(s.io);
        s.flushLocked();
        if (s.client) |c| c.close();
        s.client = null;
        s.mu.unlock(s.io);
        for (s.rows.items) |r| s.gpa.free(r.text);
        s.rows.deinit(s.gpa);
        s.next_seq.deinit(s.gpa);
    }

    /// Starts the task that writes a quiet job's pending lines on time.
    pub fn startFlusher(s: *PgSink) !void {
        s.flusher = try s.io.concurrent(flusherMain, .{s});
    }

    fn flusherMain(s: *PgSink) void {
        const tick: i64 = @max(50, @divFloor(@as(i64, s.flush_ms), 2));
        while (!s.stop.load(.acquire)) {
            s.io.sleep(.fromMilliseconds(tick), .awake) catch return;
            s.mu.lockUncancelable(s.io);
            if (s.rows.items.len > 0 and now(s.io) - s.last_flush_ms >= s.flush_ms) s.flushLocked();
            s.mu.unlock(s.io);
        }
    }

    pub fn errorText(s: *const PgSink) []const u8 {
        return s.last_error[0..s.last_error_len];
    }

    fn now(io: Io) i64 {
        return Io.Clock.real.now(io).toMilliseconds();
    }

    fn remember(s: *PgSink, what: []const u8, detail: []const u8) void {
        const t = std.fmt.bufPrint(&s.last_error, "{s}: {s}", .{ what, detail }) catch s.last_error[0..0];
        s.last_error_len = t.len;
    }

    /// Writes the buffered rows; on failure keeps them and backs off. Called with `mu` held.
    fn flushLocked(s: *PgSink) void {
        if (s.rows.items.len == 0) return;
        const t = now(s.io);
        if (t < s.retry_after_ms) return;
        s.writeBatch() catch |e| {
            s.remember("log write failed", if (s.client) |c| (if (c.lastErrorText().len > 0) c.lastErrorText() else @errorName(e)) else @errorName(e));
            if (s.client) |c| c.close();
            s.client = null;
            s.retry_after_ms = t + 2000;
            return;
        };
        s.last_flush_ms = t;
    }

    fn writeBatch(s: *PgSink) !void {
        if (s.client == null) {
            const c = try pg.Client.connect(s.gpa, s.io, s.cfg);
            s.client = c;
            if (s.schema) |sc| {
                var arena_state: std.heap.ArenaAllocator = .init(s.gpa);
                defer arena_state.deinit();
                var aw: Io.Writer.Allocating = .init(arena_state.allocator());
                try @import("db.zig").writeSetSchema(&aw.writer, sc);
                try c.exec(aw.written());
            }
        }
        var arena_state: std.heap.ArenaAllocator = .init(s.gpa);
        defer arena_state.deinit();
        var data: Io.Writer.Allocating = .init(arena_state.allocator());
        const w = &data.writer;
        for (s.rows.items) |r| {
            try w.writeAll(try timefmt.isoTime(arena_state.allocator(), r.ts_ms));
            try w.print("\t{d}\t{d}\t{d}\t{s}\t", .{ r.job_id, r.step, r.seq, @tagName(r.stream) });
            try pg.copyField(w, r.text);
            try w.writeByte('\n');
        }
        const n = try s.client.?.copyIn("COPY job_logs (ts, job_id, step_number, seq, stream, line) FROM STDIN", data.written());
        if (n != s.rows.items.len) return error.ShortCopy;
        s.written += n;
        for (s.rows.items) |r| s.gpa.free(r.text);
        s.rows.clearRetainingCapacity();
    }

    /// If the database stays down, drop the oldest lines rather than grow without bound.
    fn enforceCap(s: *PgSink) void {
        if (s.rows.items.len <= s.max_buffered) return;
        const drop = s.rows.items.len - s.max_buffered;
        for (s.rows.items[0..drop]) |r| s.gpa.free(r.text);
        std.mem.copyForwards(Row, s.rows.items[0..s.max_buffered], s.rows.items[drop..]);
        s.rows.shrinkRetainingCapacity(s.max_buffered);
        s.dropped += drop;
    }
};

// --- tests ---

fn countLogs(sc: *@import("dbtest.zig").Scratch) !u64 {
    return std.fmt.parseInt(u64, try sc.scalar("select count(*) from job_logs"), 10);
}

fn testSink(sc: *@import("dbtest.zig").Scratch, inner: *sink.LogSink) PgSink {
    return .{ .gpa = std.testing.allocator, .io = std.testing.io, .cfg = sc.cfg, .schema = sc.schema, .inner = inner };
}

test "integration: batches are written with gapless seq, redaction and the right columns" {
    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var sc = try @import("dbtest.zig").Scratch.create(arena);
    defer sc.destroy();
    // job_logs has no foreign key, so no run or job rows are needed (SPEC §4).
    var console_out: Io.Writer.Allocating = .init(arena);
    var console: sink.LogSink = .{ .stdout = .{ .writer = &console_out.writer } };
    var pgs = testSink(&sc, &console);
    pgs.flush_lines = 100;
    pgs.flush_ms = 60_000; // only size and explicit flushes
    pgs.secrets = &.{"s3cr3t"};
    defer pgs.close();

    // 450 lines across several batches, with hostile content.
    for (0..450) |i| {
        const text = if (i % 90 == 0) "tab\there \\ back\\slash \"quote\" it's s3cr3t \x1b[31mred\x1b[0m" else "plain line";
        try pgs.append(99, if (i < 200) 0 else 1, if (i % 2 == 0) .stdout else .stderr, text);
    }
    try std.testing.expect(pgs.written >= 400); // size-triggered batches already went out
    try pgs.flush();

    try std.testing.expectEqual(@as(u64, 450), try countLogs(&sc));
    try std.testing.expectEqualStrings("1/450/450", try sc.scalar("select min(seq) || '/' || max(seq) || '/' || count(distinct seq) from job_logs where job_id = 99")); // gapless
    try std.testing.expectEqualStrings("0", try sc.scalar("select count(*) from job_logs where line like '%s3cr3t%'")); // redacted
    try std.testing.expectEqualStrings("tab\there \\ back\\slash \"quote\" it's *** \x1b[31mred\x1b[0m", try sc.scalar("select line from job_logs where seq = 1"));
    try std.testing.expectEqualStrings("200", try sc.scalar("select count(*) from job_logs where step_number = 0"));
    try std.testing.expectEqualStrings("225", try sc.scalar("select count(*) from job_logs where stream = 'stderr'"));
    // seq order is also arrival order.
    try std.testing.expectEqualStrings("true", try sc.scalar("select (bool_and(ts >= prev_ts))::text from (select ts, lag(ts) over (order by seq) as prev_ts from job_logs) t where prev_ts is not null"));
    // Everything was shown on the console too.
    try std.testing.expectEqual(@as(usize, 450), std.mem.count(u8, console_out.written(), "[job 99 step"));
}

test "integration: a quiet job's last lines are written by the background flusher" {
    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var sc = try @import("dbtest.zig").Scratch.create(arena);
    defer sc.destroy();
    var buf: [1024]u8 = undefined;
    var w: Io.Writer = .fixed(&buf);
    var console: sink.LogSink = .{ .stdout = .{ .writer = &w } };
    var pgs = testSink(&sc, &console);
    pgs.flush_lines = 10_000;
    pgs.flush_ms = 100;
    try pgs.startFlusher();
    defer pgs.close();

    pgs.last_flush_ms = Io.Clock.real.now(std.testing.io).toMilliseconds();
    try pgs.append(5, 1, .stdout, "only line, then silence");
    try std.testing.expectEqual(@as(u64, 0), try countLogs(&sc)); // not yet: below the thresholds
    try std.testing.io.sleep(.fromMilliseconds(600), .awake);
    try std.testing.expectEqual(@as(u64, 1), try countLogs(&sc)); // written without another append or an explicit flush
}

test "integration: a database outage never fails the caller; lines are kept and written after recovery" {
    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var sc = try @import("dbtest.zig").Scratch.create(arena);
    defer sc.destroy();
    var buf: [1024]u8 = undefined;
    var w: Io.Writer = .fixed(&buf);
    var console: sink.LogSink = .{ .stdout = .{ .writer = &w } };
    var pgs = testSink(&sc, &console);
    pgs.cfg.port = 1; // nothing listens here
    defer pgs.close();

    try pgs.append(8, 0, .stdout, "line during the outage");
    try pgs.flush(); // fails inside, is swallowed
    try std.testing.expectEqual(@as(usize, 1), pgs.rows.items.len);
    try std.testing.expect(pgs.errorText().len > 0);
    try std.testing.expectEqual(@as(u64, 0), try countLogs(&sc));

    pgs.cfg = sc.cfg; // the database is back
    pgs.retry_after_ms = 0;
    try pgs.append(8, 0, .stdout, "line after recovery");
    try pgs.flush();
    try std.testing.expectEqual(@as(u64, 2), try countLogs(&sc));
    try std.testing.expectEqualStrings("1,2", try sc.scalar("select string_agg(seq::text, ',' order by seq) from job_logs where job_id = 8"));
}

test "the buffer is capped: the oldest lines are dropped and counted when the database stays down" {
    var buf: [1024]u8 = undefined;
    var w: Io.Writer = .fixed(&buf);
    var console: sink.LogSink = .{ .stdout = .{ .writer = &w } };
    var pgs: PgSink = .{ .gpa = std.testing.allocator, .io = std.testing.io, .cfg = .{ .host = "127.0.0.1", .port = 1, .user = "u", .database = "d", .sslmode = .disable }, .inner = &console };
    pgs.max_buffered = 5;
    pgs.flush_lines = 1_000_000;
    pgs.flush_ms = 1_000_000;
    pgs.last_flush_ms = Io.Clock.real.now(std.testing.io).toMilliseconds();
    defer pgs.close();
    for (0..8) |i| {
        _ = i;
        var line_buf: [8]u8 = undefined;
        _ = &line_buf;
        try pgs.append(1, 0, .stdout, "x");
    }
    try std.testing.expectEqual(@as(usize, 5), pgs.rows.items.len);
    try std.testing.expectEqual(@as(u64, 3), pgs.dropped);
    // seq keeps counting, so the gap is visible in the data.
    try std.testing.expectEqual(@as(u64, 4), pgs.rows.items[0].seq);
}

test "messages that belong to no job (id 0) stay on the console" {
    var buf: [256]u8 = undefined;
    var w: Io.Writer = .fixed(&buf);
    var console: sink.LogSink = .{ .stdout = .{ .writer = &w } };
    var pgs: PgSink = .{ .gpa = std.testing.allocator, .io = std.testing.io, .cfg = .{ .host = "127.0.0.1", .port = 1, .user = "u", .database = "d", .sslmode = .disable }, .inner = &console };
    defer pgs.close();
    try pgs.append(0, 0, .stderr, "registered runner");
    try std.testing.expectEqual(@as(usize, 0), pgs.rows.items.len);
    try std.testing.expect(std.mem.indexOf(u8, w.buffered(), "registered runner") != null);
}
