//! The job, live in GitHub's UI while it runs: its steps as they start and finish
//! (`WorkflowStepsUpdate`), and their log lines as they are logged (the WebSocket feed), as
//! actions/runner sends them. Without it GitHub shows a running job with no steps and no output
//! until `completejob`. Lines arrive from the job (any task) through the log sink's listener and
//! steps through the Dagger observer; a task of its own sends both every 500 ms, so neither the
//! steps nor the log reader wait on the network. Failures are reported once and never fail a job.
const std = @import("std");
const dagger = @import("dagger.zig");
const job_mod = @import("job.zig");
const sink = @import("sink.zig");
const feed = @import("github/feed.zig");
const results = @import("github/results.zig");
const timefmt = @import("timefmt.zig");
const engine = @import("engine.zig");

const Allocator = std.mem.Allocator;

pub const Live = struct {
    gpa: Allocator,
    io: std.Io,
    job: *const job_mod.Job,
    /// The runner's own log, for reporting failures (the shared, locked sink).
    log: *sink.LogSink,
    /// GitHub's id for each log step: 0 "Set up job", 1..n the job's steps (their own ids), then
    /// the runner's own steps. `completejob` uses the same ids.
    ids: []const []const u8,
    /// Forwarded the job's step events (the database's run state).
    next: ?dagger.Observer = null,

    mu: std.Io.Mutex = .init,
    /// Lines logged but not sent, and lines sent, per log step (guarded by `mu`).
    pending: []std.ArrayList([]u8),
    sent: []u64,
    /// The steps GitHub has been told of, in the order they started (guarded by `mu`).
    steps: std.ArrayList(Step) = .empty,
    steps_changed: bool = false,
    change_order: u64 = 0,
    /// The number the next step gets, and the pre steps so far (guarded by `mu`; see `posts`).
    next_number: u32 = 1,
    pres: u32 = 0,

    socket: feed.Socket = undefined,
    feed_open: bool = false,
    /// When the feed last sent something (see `keepalive_ms`); used by the sending task only.
    feed_last_ms: i64 = 0,
    feed_reopened: u32 = 0,
    steps_failed: bool = false,
    stop: std.atomic.Value(bool) = .init(false),
    /// Set by `finish`: later lines and steps are ignored (guarded by `mu`).
    finished: bool = false,
    task: ?std.Io.Future(void) = null,

    const Step = struct {
        log_step: u32,
        number: u32,
        name: []const u8,
        completed: bool = false,
        conclusion: Conclusion = .unknown,
        started_ms: i64,
        completed_ms: i64 = 0,
    };

    /// As the results service numbers them (its protobuf enums).
    pub const Conclusion = enum(u8) { unknown = 0, success = 2, failure = 3, cancelled = 4, skipped = 7 };

    pub fn init(gpa: Allocator, arena: Allocator, io: std.Io, job: *const job_mod.Job, log: *sink.LogSink) !Live {
        const n = dagger.logSteps(job.steps.len) + 1;
        const ids = try arena.alloc([]const u8, n);
        for (ids, 0..) |*id, i| {
            if (i >= 1 and i <= job.steps.len and job.steps[i - 1].id.len > 0) {
                id.* = job.steps[i - 1].id;
            } else {
                var buf: [36]u8 = undefined;
                engine.uuid(io, &buf);
                id.* = try arena.dupe(u8, &buf);
            }
        }
        const pending = try arena.alloc(std.ArrayList([]u8), n);
        @memset(pending, .empty);
        const sent = try arena.alloc(u64, n);
        @memset(sent, 0);
        return .{ .gpa = gpa, .io = io, .job = job, .log = log, .ids = ids, .pending = pending, .sent = sent };
    }

    /// Connects the feed, reports "Set up job" running and starts sending. The Live must not move.
    pub fn start(l: *Live, started_ms: i64) void {
        if (l.job.runtime.feed_url.len > 0) {
            if (l.socket.open(l.gpa, l.io, l.job.runtime.feed_url, l.job.job_token)) |_| {
                l.feed_open = true;
                l.feed_last_ms = std.Io.Clock.real.now(l.io).toMilliseconds();
            } else |e| l.say("live log feed unavailable ({s}); the log appears when the job ends", .{@errorName(e)});
        }
        l.begin(0, "Set up job", started_ms);
        l.task = l.io.concurrent(run, .{l}) catch null;
    }

    pub fn listener(l: *Live) sink.CollectSink.Listener {
        return .{ .ptr = l, .onLine = onLine };
    }

    pub fn observer(l: *Live) dagger.Observer {
        return .{ .ptr = l, .startedFn = stepStarted, .finishedFn = stepFinished, .extraStartedFn = extraStarted, .extraFinishedFn = extraFinished, .postsFn = posts };
    }

    /// GitHub's numbering after the main steps (see `loop.shownSteps`): one number per step that
    /// could have a post and one more are set aside, the post steps take the last of them.
    fn posts(ptr: *anyopaque, count: u32, _: bool) void {
        const l: *Live = @ptrCast(@alignCast(ptr));
        l.mu.lockUncancelable(l.io);
        defer l.mu.unlock(l.io);
        const reserved: u32 = @as(u32, @intCast(l.job.steps.len)) + l.pres + 1;
        l.next_number = l.next_number + reserved - count;
    }

    fn onLine(ptr: *anyopaque, step: u32, text: []const u8) void {
        const l: *Live = @ptrCast(@alignCast(ptr));
        if (step >= l.pending.len) return;
        l.mu.lockUncancelable(l.io);
        defer l.mu.unlock(l.io);
        if (l.finished) return;
        const copy = l.gpa.dupe(u8, text) catch return;
        l.pending[step].append(l.gpa, copy) catch l.gpa.free(copy);
    }

    /// A step started: it gets the next number (steps start in the order GitHub lists them), and
    /// "Set up job" is over once any other step starts.
    pub fn begin(l: *Live, log_step: u32, name: []const u8, started_ms: i64) void {
        l.mu.lockUncancelable(l.io);
        defer l.mu.unlock(l.io);
        _ = l.stepLocked(log_step, name, started_ms);
    }

    fn stepLocked(l: *Live, log_step: u32, name: []const u8, started_ms: i64) ?*Step {
        if (l.finished) return null;
        for (l.steps.items) |*s| if (s.log_step == log_step) return s;
        if (log_step != 0) for (l.steps.items) |*s| if (s.log_step == 0 and !s.completed) {
            s.completed = true;
            s.conclusion = .success;
            s.completed_ms = started_ms;
        };
        const name_copy = l.gpa.dupe(u8, name) catch return null;
        l.steps.append(l.gpa, .{ .log_step = log_step, .number = l.next_number, .name = name_copy, .started_ms = started_ms }) catch {
            l.gpa.free(name_copy);
            return null;
        };
        l.next_number += 1;
        l.steps_changed = true;
        return &l.steps.items[l.steps.items.len - 1];
    }

    pub fn end(l: *Live, log_step: u32, name: []const u8, conclusion: Conclusion, started_ms: i64, completed_ms: i64) void {
        l.mu.lockUncancelable(l.io);
        defer l.mu.unlock(l.io);
        const s = l.stepLocked(log_step, name, if (started_ms > 0) started_ms else completed_ms) orelse return;
        s.completed = true;
        s.conclusion = conclusion;
        s.completed_ms = completed_ms;
        l.steps_changed = true;
    }

    fn stepStarted(ptr: *anyopaque, number: u32, name: []const u8, started_ms: i64) void {
        const l: *Live = @ptrCast(@alignCast(ptr));
        l.begin(number, name, started_ms);
        if (l.next) |o| o.startedFn(o.ptr, number, name, started_ms);
    }

    fn stepFinished(ptr: *anyopaque, number: u32, res: dagger.StepResult) void {
        const l: *Live = @ptrCast(@alignCast(ptr));
        const name = if (res.name.len > 0) res.name else if (number >= 1 and number <= l.job.steps.len) l.job.steps[number - 1].name else "";
        const now = std.Io.Clock.real.now(l.io).toMilliseconds();
        l.end(number, name, conclusionOf(res.outcome, res.continued), res.started_ms, if (res.completed_ms > 0) res.completed_ms else now);
        if (l.next) |o| o.finishedFn(o.ptr, number, res);
    }

    fn extraStarted(ptr: *anyopaque, kind: dagger.ExtraKind, log_step: u32, name: []const u8, started_ms: i64) void {
        const l: *Live = @ptrCast(@alignCast(ptr));
        if (kind == .pre) {
            l.mu.lockUncancelable(l.io);
            l.pres += 1;
            l.mu.unlock(l.io);
        }
        l.begin(log_step, name, started_ms);
    }

    fn extraFinished(ptr: *anyopaque, e: dagger.ExtraStep) void {
        const l: *Live = @ptrCast(@alignCast(ptr));
        l.end(e.log_step, e.name, conclusionOf(e.outcome, false), e.started_ms, e.completed_ms);
    }

    pub fn conclusionOf(outcome: dagger.Outcome, continued: bool) Conclusion {
        return switch (outcome) {
            .success => .success,
            .failure => if (continued) .success else .failure,
            .cancelled => .cancelled,
            .skipped, .not_run => .skipped,
        };
    }

    fn run(l: *Live) void {
        while (!l.stop.load(.acquire)) {
            l.io.sleep(.fromMilliseconds(500), .awake) catch return;
            l.sendPending();
        }
    }

    /// Sends what was logged and changed since the last time: the steps first, so a line's step is
    /// known when it arrives.
    fn sendPending(l: *Live) void {
        var arena_state: std.heap.ArenaAllocator = .init(l.gpa);
        defer arena_state.deinit();
        const arena = arena_state.allocator();

        var steps_json: ?[]const u8 = null;
        var order: u64 = 0;
        const Batch = struct { log_step: u32, start_line: u64, lines: [][]u8 };
        var batches: std.ArrayList(Batch) = .empty;
        {
            l.mu.lockUncancelable(l.io);
            defer l.mu.unlock(l.io);
            if (l.steps_changed and !l.steps_failed) {
                steps_json = l.stepsJsonLocked(arena) catch null;
                l.steps_changed = false;
                l.change_order += 1;
                order = l.change_order;
            }
            for (l.pending, 0..) |*p, i| {
                if (p.items.len == 0) continue;
                const lines = p.toOwnedSlice(l.gpa) catch continue;
                batches.append(arena, .{ .log_step = @intCast(i), .start_line = l.sent[i] + 1, .lines = lines }) catch {
                    freeLines(l.gpa, lines);
                    continue;
                };
                l.sent[i] += lines.len;
            }
        }
        if (steps_json) |js| {
            const r = results.updateSteps(arena, l.io, l.job.*, js, order);
            if (!r.ok) {
                l.steps_failed = true;
                l.say("live steps unavailable ({s}); they appear when the job ends", .{r.detail});
            }
        }
        for (batches.items) |b| {
            defer freeLines(l.gpa, b.lines);
            if (!l.feed_open) continue;
            const msg = feedMessage(arena, l.ids[b.log_step], b.lines, b.start_line) catch continue;
            l.feedSend(msg);
        }
        // A step that prints nothing for a while (`npm install`, a compiler) would leave the feed
        // idle, and idle feeds were closed on the way within about a minute.
        if (l.feed_open and std.Io.Clock.real.now(l.io).toMilliseconds() - l.feed_last_ms >= keepalive_ms) l.feedSend(null);
    }

    const keepalive_ms = 15_000;
    /// Times the feed is opened again after it was lost, before it is given up for the job.
    const max_reopen = 3;

    /// Sends a message (a ping when null). A feed found closed is opened again and the message sent
    /// once more; when that fails too, the rest of the log appears when the job ends.
    fn feedSend(l: *Live, msg: ?[]const u8) void {
        var attempt: u32 = 0;
        while (true) : (attempt += 1) {
            const sent = if (msg) |m| l.socket.sendText(m) else l.socket.ping();
            if (sent) |_| {
                l.feed_last_ms = std.Io.Clock.real.now(l.io).toMilliseconds();
                return;
            } else |e| {
                l.socket.close(l.gpa);
                if (attempt == 0 and l.feed_reopened < max_reopen) {
                    l.feed_reopened += 1;
                    if (l.socket.open(l.gpa, l.io, l.job.runtime.feed_url, l.job.job_token)) |_| continue else |_| {}
                }
                l.feed_open = false;
                l.say("live log feed lost ({s}); the log appears when the job ends", .{@errorName(e)});
                return;
            }
        }
    }

    fn stepsJsonLocked(l: *Live, arena: Allocator) ![]const u8 {
        var aw: std.Io.Writer.Allocating = .init(arena);
        const w = &aw.writer;
        try w.writeByte('[');
        for (l.steps.items, 0..) |s, i| {
            if (i > 0) try w.writeByte(',');
            try writeStep(arena, w, l.ids[s.log_step], s.number, s.name, s.completed, s.conclusion, s.started_ms, s.completed_ms);
        }
        try w.writeByte(']');
        return aw.written();
    }

    /// Ends the live view: what is left is sent, then the final step list (numbers and conclusions
    /// as completejob reports them), and the feed is closed.
    pub fn finish(l: *Live, final_steps: []const Final) void {
        if (l.finished) return;
        l.stop.store(true, .release);
        if (l.task) |*t| t.await(l.io);
        l.sendPending();
        if (!l.steps_failed and final_steps.len > 0) {
            var arena_state: std.heap.ArenaAllocator = .init(l.gpa);
            defer arena_state.deinit();
            const arena = arena_state.allocator();
            var aw: std.Io.Writer.Allocating = .init(arena);
            aw.writer.writeByte('[') catch return;
            for (final_steps, 0..) |s, i| {
                if (i > 0) aw.writer.writeByte(',') catch return;
                writeStep(arena, &aw.writer, s.id, s.number, s.name, true, s.conclusion, s.started_ms, s.completed_ms) catch return;
            }
            aw.writer.writeByte(']') catch return;
            l.change_order += 1;
            _ = results.updateSteps(arena, l.io, l.job.*, aw.written(), l.change_order);
        }
        if (l.feed_open) {
            l.feed_open = false;
            l.socket.close(l.gpa);
        }
        l.mu.lockUncancelable(l.io);
        defer l.mu.unlock(l.io);
        l.finished = true;
        for (l.steps.items) |s| l.gpa.free(s.name);
        l.steps.deinit(l.gpa);
        for (l.pending) |*p| {
            freeLines(l.gpa, p.items);
            p.deinit(l.gpa);
        }
    }

    pub const Final = struct { id: []const u8, number: u32, name: []const u8, conclusion: Conclusion, started_ms: i64, completed_ms: i64 };

    fn say(l: *Live, comptime fmt: []const u8, args: anytype) void {
        var buf: [512]u8 = undefined;
        const text = std.fmt.bufPrint(&buf, "job {d}: " ++ fmt, .{l.job.check_run_id} ++ args) catch return;
        l.log.append(0, 0, .stderr, text) catch {};
    }
};

fn freeLines(gpa: Allocator, lines: []const []u8) void {
    for (lines) |line| gpa.free(line);
    gpa.free(lines);
}

/// One step for `WorkflowStepsUpdate` (actions/runner's results `Step`: snake_case names, the
/// status and conclusion as their protobuf numbers).
fn writeStep(arena: Allocator, w: *std.Io.Writer, id: []const u8, number: u32, name: []const u8, completed: bool, conclusion: Live.Conclusion, started_ms: i64, completed_ms: i64) !void {
    try w.writeAll("{\"external_id\":");
    try std.json.Stringify.value(id, .{}, w);
    try w.print(",\"number\":{d},\"name\":", .{number});
    try std.json.Stringify.value(name, .{}, w);
    // 3: in progress, 6: completed.
    try w.print(",\"status\":{d}", .{@as(u8, if (completed) 6 else 3)});
    if (started_ms > 0) try w.print(",\"started_at\":\"{s}\"", .{try timefmt.isoTime(arena, started_ms)});
    if (completed) {
        try w.print(",\"conclusion\":{d}", .{@backingInt(conclusion)});
        if (completed_ms > 0) try w.print(",\"completed_at\":\"{s}\"", .{try timefmt.isoTime(arena, completed_ms)});
    }
    try w.writeByte('}');
}

/// A feed message: actions/runner's `TimelineRecordFeedLinesWrapper`, camelCase.
pub fn feedMessage(arena: Allocator, step_id: []const u8, lines: []const []const u8, start_line: u64) ![]const u8 {
    var aw: std.Io.Writer.Allocating = .init(arena);
    const w = &aw.writer;
    try w.print("{{\"count\":{d},\"value\":", .{lines.len});
    try std.json.Stringify.value(lines, .{}, w);
    try w.writeAll(",\"stepId\":");
    try std.json.Stringify.value(step_id, .{}, w);
    try w.print(",\"startLine\":{d}}}", .{start_line});
    return aw.written();
}

test "feed message: the lines, their step and where they start in its log" {
    var a: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer a.deinit();
    try std.testing.expectEqualStrings(
        \\{"count":2,"value":["one","two \"2\""],"stepId":"abc","startLine":5}
    , try feedMessage(a.allocator(), "abc", &.{ "one", "two \"2\"" }, 5));
}

test "steps update: in progress, then completed with a conclusion" {
    var a: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer a.deinit();
    var aw: std.Io.Writer.Allocating = .init(a.allocator());
    try writeStep(a.allocator(), &aw.writer, "id", 2, "Build", false, .unknown, 1000, 0);
    try std.testing.expectEqualStrings("{\"external_id\":\"id\",\"number\":2,\"name\":\"Build\",\"status\":3,\"started_at\":\"1970-01-01T00:00:01.000Z\"}", aw.written());
    aw.clearRetainingCapacity();
    try writeStep(a.allocator(), &aw.writer, "id", 2, "Build", true, .failure, 1000, 2000);
    try std.testing.expectEqualStrings("{\"external_id\":\"id\",\"number\":2,\"name\":\"Build\",\"status\":6,\"started_at\":\"1970-01-01T00:00:01.000Z\",\"conclusion\":3,\"completed_at\":\"1970-01-01T00:00:02.000Z\"}", aw.written());
}
