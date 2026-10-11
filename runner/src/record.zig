//! Records runs, jobs and steps in the database (SPEC §5.2): one write per transition, job start,
//! step start, step end and job end, each idempotent on the primary key. The statements are built
//! as data (`Statement`) so the SQL and the status mapping are tested without a database.
//!
//! A database failure is reported on stderr and never fails the job. After a failed live write the
//! remaining step writes are skipped; `jobEnd` rewrites every row anyway, so the database catches
//! up as soon as it answers again. `jobEnd` is a separate call so the loop can order it after the
//! final log flush (the API's `job_done` relies on that, SPEC §5.3) and after `completejob`.
const std = @import("std");
const Db = @import("db/Db.zig");
const job_mod = @import("job.zig");
const dagger = @import("dagger.zig");
const redact = @import("redact.zig");
const timefmt = @import("timefmt.zig");

const Allocator = std.mem.Allocator;
const Param = Db.Param;

pub const Statement = struct { sql: []const u8, params: []const Param };

/// The vocabulary of `steps.conclusion` and `jobs.conclusion` (the GitHub REST one).
pub const Conclusion = enum {
    success,
    failure,
    skipped,

    /// The same rule `stepResultsJson` reports to GitHub: a failure under `continue-on-error`
    /// counts as success, and a step that never ran is skipped.
    pub fn ofStep(outcome: dagger.Outcome, continue_on_error: bool) Conclusion {
        return switch (outcome) {
            .success => .success,
            .failure => if (continue_on_error) .success else .failure,
            .skipped, .not_run => .skipped,
        };
    }
};

/// Step 0 holds the runner's own lines (job acquired, engine errors); the frontend shows it as
/// GitHub's "Set up job".
pub const setup_step_name = "Set up job";

const upsert_run =
    \\INSERT INTO runs (id, repo, workflow, event, branch, sha, status)
    \\VALUES ($1, $2, $3, $4, $5, $6, 'in_progress')
    \\ON CONFLICT (id) DO UPDATE SET repo = EXCLUDED.repo, workflow = EXCLUDED.workflow,
    \\  event = EXCLUDED.event, branch = EXCLUDED.branch, sha = EXCLUDED.sha,
    \\  status = 'in_progress', conclusion = NULL, completed_at = NULL
;

const upsert_job_start =
    \\INSERT INTO jobs (id, run_id, name, runner_name, status, started_at)
    \\VALUES ($1, $2, $3, $4, 'in_progress', $5)
    \\ON CONFLICT (id) DO UPDATE SET run_id = EXCLUDED.run_id, name = EXCLUDED.name,
    \\  runner_name = EXCLUDED.runner_name, status = 'in_progress', conclusion = NULL,
    \\  started_at = EXCLUDED.started_at, completed_at = NULL
;

/// A NULL timestamp never erases one already written, so a late or replayed write cannot lose a
/// step's start time.
const upsert_step =
    \\INSERT INTO steps (job_id, number, name, status, conclusion, started_at, completed_at)
    \\VALUES ($1, $2, $3, $4, $5, $6, $7)
    \\ON CONFLICT (job_id, number) DO UPDATE SET name = EXCLUDED.name, status = EXCLUDED.status,
    \\  conclusion = EXCLUDED.conclusion,
    \\  started_at = COALESCE(EXCLUDED.started_at, steps.started_at),
    \\  completed_at = COALESCE(EXCLUDED.completed_at, steps.completed_at)
;

const update_job_end =
    \\UPDATE jobs SET status = 'completed', conclusion = $2, completed_at = $3 WHERE id = $1
;

/// The runner only sees its own jobs, so the run's state is derived from the jobs the database
/// holds for it: completed once all of them are, failure if any failed, cancelled if any was.
const recompute_run =
    \\UPDATE runs SET
    \\  status = CASE WHEN j.done THEN 'completed' ELSE 'in_progress' END,
    \\  conclusion = CASE WHEN NOT j.done THEN NULL
    \\    WHEN j.failed THEN 'failure' WHEN j.cancelled THEN 'cancelled' ELSE 'success' END,
    \\  completed_at = CASE WHEN j.done THEN j.last ELSE NULL END
    \\FROM (SELECT bool_and(status = 'completed') AS done,
    \\        bool_or(conclusion = 'failure') AS failed,
    \\        bool_or(conclusion = 'cancelled') AS cancelled,
    \\        max(completed_at) AS last
    \\      FROM jobs WHERE run_id = $1) AS j
    \\WHERE runs.id = $1 AND j.done IS NOT NULL
;

/// Why a job gets no rows, or null when it can be recorded.
pub fn unrecordable(job: job_mod.Job) ?[]const u8 {
    if (job.run_id == null) return "no github.run_id";
    if (job.check_run_id == 0) return "no check_run_id";
    if (job.repo == null) return "no github.repository";
    if (job.workflow == null) return "no github.workflow";
    return null;
}

fn idText(arena: Allocator, id: u64) ![]const u8 {
    return std.fmt.allocPrint(arena, "{d}", .{id});
}

fn timeText(arena: Allocator, ms: i64) !?[]const u8 {
    return if (ms > 0) try timefmt.isoTime(arena, ms) else null;
}

/// Job start: the run (in progress, `created_at` kept), the job, and step 0 in progress.
pub fn jobStartStatements(arena: Allocator, job: job_mod.Job, now_ms: i64) ![3]Statement {
    const run_id = try idText(arena, job.run_id.?);
    const job_id = try idText(arena, job.check_run_id);
    const now = try timeText(arena, now_ms);
    return .{
        .{ .sql = upsert_run, .params = try arena.dupe(Param, &.{ run_id, job.repo.?, job.workflow.?, job.event, job.branch, job.sha }) },
        .{ .sql = upsert_job_start, .params = try arena.dupe(Param, &.{ job_id, run_id, job.name, job.runner_name, now }) },
        try stepStatement(arena, job.check_run_id, 0, setup_step_name, .in_progress, null, now_ms, 0),
    };
}

pub const StepStatus = enum { in_progress, completed };

pub fn stepStatement(arena: Allocator, job_id: u64, number: u32, name: []const u8, status: StepStatus, conclusion: ?Conclusion, started_ms: i64, completed_ms: i64) !Statement {
    return .{ .sql = upsert_step, .params = try arena.dupe(Param, &.{
        try idText(arena, job_id),
        try std.fmt.allocPrint(arena, "{d}", .{number}),
        name,
        @tagName(status),
        if (conclusion) |c| @tagName(c) else null,
        try timeText(arena, started_ms),
        try timeText(arena, completed_ms),
    }) };
}

/// A step's row from what Dagger reported. `now_ms` stands in for the completion time of a step
/// that was skipped (the skip marker carries no times).
pub fn stepRowStatement(arena: Allocator, job: job_mod.Job, number: u32, r: dagger.StepResult, now_ms: i64) !Statement {
    const step = job.steps[number - 1];
    if (r.outcome == .not_run and r.started_ms > 0) // begun, not ended
        return stepStatement(arena, job.check_run_id, number, step.name, .in_progress, null, r.started_ms, 0);
    const c = Conclusion.ofStep(r.outcome, step.continue_on_error);
    const completed = if (r.completed_ms > 0) r.completed_ms else if (r.outcome == .skipped) now_ms else 0;
    return stepStatement(arena, job.check_run_id, number, step.name, .completed, c, r.started_ms, completed);
}

/// Job end: step 0 and every step in its final state, the job completed, then the run recomputed.
/// The steps that never reported are written as skipped, as GitHub is told.
pub fn jobEndStatements(arena: Allocator, job: job_mod.Job, result: dagger.Result, setup_failed: bool, now_ms: i64) ![]Statement {
    var out: std.ArrayList(Statement) = .empty;
    const setup: Conclusion = if (setup_failed) .failure else .success;
    try out.append(arena, try stepStatement(arena, job.check_run_id, 0, setup_step_name, .completed, setup, 0, now_ms));
    for (result.steps, 1..) |r, n| {
        var final = r;
        if (final.outcome == .not_run) final.started_ms = 0; // never finished: skipped, like GitHub
        try out.append(arena, try stepRowStatement(arena, job, @intCast(n), final, now_ms));
    }
    const job_conclusion: Conclusion = if (result.succeeded) .success else .failure;
    try out.append(arena, .{ .sql = update_job_end, .params = try arena.dupe(Param, &.{ try idText(arena, job.check_run_id), @tagName(job_conclusion), try timeText(arena, now_ms) }) });
    try out.append(arena, .{ .sql = recompute_run, .params = try arena.dupe(Param, &.{try idText(arena, job.run_id.?)}) });
    return out.items;
}

pub const Recorder = struct {
    /// Null when there is no database or the job cannot be recorded; every call is then a no-op.
    db: ?*Db,
    arena: Allocator,
    io: std.Io,
    job: *const job_mod.Job,
    err: *std.Io.Writer,
    secrets: []const []const u8,
    started: bool = false,
    /// Cleared by the first failed live write: later step writes are skipped until `jobEnd`.
    live: bool = true,
    setup_done: bool = false,

    pub fn init(db: ?*Db, arena: Allocator, io: std.Io, job: *const job_mod.Job, err: *std.Io.Writer, secrets: []const []const u8) Recorder {
        return .{ .db = db, .arena = arena, .io = io, .job = job, .err = err, .secrets = secrets };
    }

    fn now(r: *Recorder) i64 {
        return std.Io.Clock.real.now(r.io).toMilliseconds();
    }

    /// Writes the run, the job and step 0. A job `unrecordable` names gets no rows at all (the loop
    /// says so in the job's log).
    pub fn jobStart(r: *Recorder) void {
        if (r.db == null) return;
        if (unrecordable(r.job.*) != null) {
            r.db = null;
            return;
        }
        const stmts = jobStartStatements(r.arena, r.job.*, r.now()) catch |e| return r.dropLive("job start", e);
        r.started = r.execAll(&stmts, "job start");
        if (!r.started) r.stopLive();
    }

    /// A `dagger.StepHook`: each begin, end or skip marker becomes one step upsert.
    pub fn hook(r: *Recorder) dagger.StepHook {
        return .{ .ctx = r, .call = onStep };
    }

    fn onStep(ctx: *anyopaque, number: u32, result: dagger.StepResult, now_ms: i64) void {
        const r: *Recorder = @ptrCast(@alignCast(ctx));
        if (r.db == null or !r.live) return;
        // Set up job ends when the first step begins.
        if (!r.setup_done) {
            r.setup_done = true;
            const s = stepStatement(r.arena, r.job.check_run_id, 0, setup_step_name, .completed, .success, 0, now_ms) catch |e| return r.dropLive("step 0", e);
            if (!r.execAll(&.{s}, "step 0")) return r.stopLive();
        }
        const s = stepRowStatement(r.arena, r.job.*, number, result, now_ms) catch |e| return r.dropLive("step", e);
        if (!r.execAll(&.{s}, "step")) r.stopLive();
    }

    /// Final step rows, the job's conclusion and the run's recomputed state. Call after the job's
    /// final log flush. `setup_failed` marks step 0 failed (engine error, unsupported job).
    pub fn jobEnd(r: *Recorder, result: dagger.Result, setup_failed: bool) void {
        if (r.db == null) return;
        // A failed job start left no run or job row for the updates below to land on.
        if (!r.started) {
            const start = jobStartStatements(r.arena, r.job.*, r.now()) catch |e| return r.dropLive("job end", e);
            if (!r.execAll(&start, "job end")) return;
        }
        const stmts = jobEndStatements(r.arena, r.job.*, result, setup_failed, r.now()) catch |e| return r.dropLive("job end", e);
        _ = r.execAll(stmts, "job end");
    }

    /// Runs the statements in order, stopping at the first failure. False on failure (reported).
    fn execAll(r: *Recorder, stmts: []const Statement, what: []const u8) bool {
        const db = r.db orelse return false;
        for (stmts) |s| {
            _ = db.exec(r.arena, s.sql, s.params) catch |e| {
                r.report(what, e);
                return false;
            };
        }
        return true;
    }

    fn stopLive(r: *Recorder) void {
        if (!r.live) return;
        r.live = false;
        r.err.writeAll("database: skipping live step updates for this job; the job-end write retries them\n") catch {};
    }

    fn dropLive(r: *Recorder, what: []const u8, e: anyerror) void {
        r.report(what, e);
        r.stopLive();
    }

    fn report(r: *Recorder, what: []const u8, e: anyerror) void {
        const w = r.err;
        w.print("database: {s} write failed: {s}", .{ what, @errorName(e) }) catch return;
        if (r.db) |db| if (db.last_error) |detail| {
            w.writeAll(": ") catch {};
            redact.write(w, detail, r.secrets) catch {};
        };
        w.writeByte('\n') catch {};
        w.flush() catch {};
    }
};

fn testJob(steps: []const job_mod.Step) job_mod.Job {
    return .{
        .plan_id = "p",
        .job_id = "j",
        .job_token = "t",
        .check_run_id = 9100000042,
        .has_container = false,
        .secrets = &.{},
        .run_id = 9000000042,
        .repo = "o/r",
        .workflow = "CI",
        .event = "push",
        .branch = null,
        .sha = "abc",
        .name = "build",
        .runner_name = "zig-runner-1",
        .steps = steps,
    };
}

fn testStep(name: []const u8, coe: bool) job_mod.Step {
    return .{ .id = name, .name = name, .condition = "success()", .continue_on_error = coe, .env = &.{}, .action = .{ .unsupported = "x" } };
}

fn expectParams(want: []const Param, got: []const Param) !void {
    try std.testing.expectEqual(want.len, got.len);
    for (want, got) |w, g| {
        if (w) |ws| try std.testing.expectEqualStrings(ws, g.?) else try std.testing.expect(g == null);
    }
}

test "Conclusion.ofStep matches what GitHub is told" {
    try std.testing.expectEqual(Conclusion.success, Conclusion.ofStep(.success, false));
    try std.testing.expectEqual(Conclusion.failure, Conclusion.ofStep(.failure, false));
    try std.testing.expectEqual(Conclusion.success, Conclusion.ofStep(.failure, true));
    try std.testing.expectEqual(Conclusion.skipped, Conclusion.ofStep(.skipped, false));
    try std.testing.expectEqual(Conclusion.skipped, Conclusion.ofStep(.not_run, false));
}

test "unrecordable names the missing metadata" {
    const steps = [_]job_mod.Step{};
    var job = testJob(&steps);
    try std.testing.expect(unrecordable(job) == null);
    job.workflow = null;
    try std.testing.expectEqualStrings("no github.workflow", unrecordable(job).?);
    job.run_id = null;
    try std.testing.expectEqualStrings("no github.run_id", unrecordable(job).?);
}

test "job start writes the run, the job and step 0" {
    var a: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer a.deinit();
    const arena = a.allocator();
    const steps = [_]job_mod.Step{testStep("one", false)};
    const s = try jobStartStatements(arena, testJob(&steps), 1791739405042);
    try std.testing.expect(std.mem.indexOf(u8, s[0].sql, "ON CONFLICT (id) DO UPDATE") != null);
    try std.testing.expect(std.mem.indexOf(u8, s[0].sql, "created_at") == null); // kept on conflict
    try expectParams(&.{ "9000000042", "o/r", "CI", "push", null, "abc" }, s[0].params);
    try expectParams(&.{ "9100000042", "9000000042", "build", "zig-runner-1", "2026-10-11T17:23:25.042Z" }, s[1].params);
    try expectParams(&.{ "9100000042", "0", "Set up job", "in_progress", null, "2026-10-11T17:23:25.042Z", null }, s[2].params);
}

test "step rows map Dagger's outcomes" {
    var a: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer a.deinit();
    const arena = a.allocator();
    const steps = [_]job_mod.Step{ testStep("a", false), testStep("b", true), testStep("c", false) };
    const job = testJob(&steps);
    const t0 = 1791739405000;

    // begin: in progress with a start time
    var s = try stepRowStatement(arena, job, 1, .{ .started_ms = t0 }, t0);
    try expectParams(&.{ "9100000042", "1", "a", "in_progress", null, "2026-10-11T17:23:25.000Z", null }, s.params);
    // end, failed under continue-on-error: success, as GitHub is told
    s = try stepRowStatement(arena, job, 2, .{ .outcome = .failure, .exit_code = 3, .started_ms = t0, .completed_ms = t0 + 1500 }, t0);
    try expectParams(&.{ "9100000042", "2", "b", "completed", "success", "2026-10-11T17:23:25.000Z", "2026-10-11T17:23:26.500Z" }, s.params);
    // end, failed
    s = try stepRowStatement(arena, job, 1, .{ .outcome = .failure, .started_ms = t0, .completed_ms = t0 + 1 }, t0);
    try std.testing.expectEqualStrings("failure", s.params[4].?);
    // skip: completed at the skip marker, no start
    s = try stepRowStatement(arena, job, 3, .{ .outcome = .skipped }, t0 + 2000);
    try expectParams(&.{ "9100000042", "3", "c", "completed", "skipped", null, "2026-10-11T17:23:27.000Z" }, s.params);
    // The upsert never erases a timestamp with NULL.
    try std.testing.expect(std.mem.indexOf(u8, s.sql, "COALESCE(EXCLUDED.started_at, steps.started_at)") != null);
}

test "job end finalizes every step, the job and the run" {
    var a: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer a.deinit();
    const arena = a.allocator();
    const steps = [_]job_mod.Step{ testStep("a", false), testStep("b", false), testStep("c", false) };
    const t0 = 1791739405000;
    var rs = [_]dagger.StepResult{
        .{ .outcome = .success, .started_ms = t0, .completed_ms = t0 + 10 },
        .{ .outcome = .failure, .exit_code = 1, .started_ms = t0 + 10, .completed_ms = t0 + 20 },
        .{ .started_ms = t0 + 20 }, // began, never ended (engine died): skipped, as GitHub is told
    };
    const s = try jobEndStatements(arena, testJob(&steps), .{ .steps = &rs, .engine_error = null, .succeeded = false }, false, t0 + 30);
    try std.testing.expectEqual(@as(usize, 6), s.len);
    try expectParams(&.{ "9100000042", "0", "Set up job", "completed", "success", null, "2026-10-11T17:23:25.030Z" }, s[0].params);
    try std.testing.expectEqualStrings("success", s[1].params[4].?);
    try std.testing.expectEqualStrings("failure", s[2].params[4].?);
    try expectParams(&.{ "9100000042", "3", "c", "completed", "skipped", null, null }, s[3].params);
    try std.testing.expectEqualStrings(update_job_end, s[4].sql);
    try expectParams(&.{ "9100000042", "failure", "2026-10-11T17:23:25.030Z" }, s[4].params);
    try std.testing.expectEqualStrings(recompute_run, s[5].sql);
    try expectParams(&.{"9000000042"}, s[5].params);

    // An engine failure marks step 0 failed.
    const s2 = try jobEndStatements(arena, testJob(&steps), .{ .steps = &rs, .engine_error = "boom", .succeeded = false }, true, t0);
    try std.testing.expectEqualStrings("failure", s2[0].params[4].?);
}

test "a job without metadata is not recorded" {
    var a: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer a.deinit();
    const steps = [_]job_mod.Step{};
    var job = testJob(&steps);
    job.run_id = null;
    var buf: [256]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buf);
    // A non-null db that must never be touched: the recorder disables itself first.
    var db: Db = undefined;
    var r: Recorder = .init(&db, a.allocator(), std.testing.io, &job, &w, &.{});
    r.jobStart();
    try std.testing.expect(r.db == null);
    r.jobEnd(.{ .steps = &.{}, .engine_error = null, .succeeded = true }, false);
    const h = r.hook();
    h.call(h.ctx, 1, .{}, 1);
}

// Live check against a migrated database (db/migrations). Skips unless `DATABASE_URL` is set and
// the schema is there; uses its own ids and removes its rows.
test "records a run's jobs and steps through every transition (DATABASE_URL)" {
    const url_mod = @import("db/url.zig");
    const raw = std.testing.environ.getPosix("DATABASE_URL") orelse return error.SkipZigTest;
    var a: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer a.deinit();
    const arena = a.allocator();
    var db: Db = .init(std.testing.allocator, std.testing.io, try url_mod.parse(arena, raw));
    defer db.deinit();
    _ = try db.exec(arena, "SELECT 1", &.{});
    const c = db.client.?;
    if ((try c.queryScalar(arena, "SELECT to_regclass('public.runs')::text")) == null) return error.SkipZigTest;
    const cleanup = "DELETE FROM steps WHERE job_id IN (9280000001, 9280000002); DELETE FROM jobs WHERE run_id = 9280000000; DELETE FROM runs WHERE id = 9280000000";
    _ = try c.query(arena, cleanup);
    defer _ = c.query(arena, cleanup) catch {};

    const steps = [_]job_mod.Step{ testStep("Build", false), testStep("Lint", true), testStep("Deploy", false) };
    var job = testJob(&steps);
    job.run_id = 9280000000;
    job.check_run_id = 9280000001;
    var errbuf: [1024]u8 = undefined;
    var ew: std.Io.Writer = .fixed(&errbuf);
    var r: Recorder = .init(&db, arena, std.testing.io, &job, &ew, &.{});
    const q = struct {
        fn one(cl: *@import("db/Client.zig"), ar: Allocator, sql: []const u8) ![]const u8 {
            return (try cl.queryScalar(ar, sql)) orelse "NULL";
        }
    }.one;

    r.jobStart();
    try std.testing.expectEqualStrings("in_progress|CI|o/r", try q(c, arena, "SELECT status || '|' || workflow || '|' || repo FROM runs WHERE id = 9280000000"));
    try std.testing.expectEqualStrings("in_progress|zig-runner-1|true", try q(c, arena, "SELECT status || '|' || runner_name || '|' || (started_at IS NOT NULL) FROM jobs WHERE id = 9280000001"));
    try std.testing.expectEqualStrings("Set up job|in_progress", try q(c, arena, "SELECT name || '|' || status FROM steps WHERE job_id = 9280000001 AND number = 0"));
    const created = try q(c, arena, "SELECT created_at::text FROM runs WHERE id = 9280000000");

    // Steps as Dagger reports them, checked as each one is written.
    const h = r.hook();
    const t0 = std.Io.Clock.real.now(std.testing.io).toMilliseconds();
    h.call(h.ctx, 1, .{ .started_ms = t0 }, t0);
    try std.testing.expectEqualStrings("completed|success", try q(c, arena, "SELECT status || '|' || conclusion FROM steps WHERE job_id = 9280000001 AND number = 0"));
    try std.testing.expectEqualStrings("Build|in_progress|true", try q(c, arena, "SELECT name || '|' || status || '|' || (started_at IS NOT NULL) FROM steps WHERE job_id = 9280000001 AND number = 1"));
    var rs = [_]dagger.StepResult{
        .{ .outcome = .success, .started_ms = t0, .completed_ms = t0 + 5 },
        .{ .outcome = .failure, .exit_code = 2, .started_ms = t0 + 5, .completed_ms = t0 + 9 },
        .{ .outcome = .skipped },
    };
    h.call(h.ctx, 1, rs[0], t0 + 5);
    h.call(h.ctx, 2, .{ .started_ms = t0 + 5 }, t0 + 5);
    h.call(h.ctx, 2, rs[1], t0 + 9);
    h.call(h.ctx, 3, rs[2], t0 + 9);
    try std.testing.expectEqualStrings("1:completed:success,2:completed:success,3:completed:skipped", try q(c, arena,
        \\SELECT string_agg(number || ':' || status || ':' || conclusion, ',' ORDER BY number) FROM steps WHERE job_id = 9280000001 AND number > 0
    ));

    r.jobEnd(.{ .steps = &rs, .engine_error = null, .succeeded = true }, false);
    try std.testing.expectEqualStrings("completed|success|true", try q(c, arena, "SELECT status || '|' || conclusion || '|' || (completed_at IS NOT NULL) FROM jobs WHERE id = 9280000001"));
    try std.testing.expectEqualStrings("completed|success|true", try q(c, arena, "SELECT status || '|' || conclusion || '|' || (completed_at IS NOT NULL) FROM runs WHERE id = 9280000000"));

    // Every write again: nothing changes, and the run keeps its created_at.
    var again: Recorder = .init(&db, arena, std.testing.io, &job, &ew, &.{});
    again.jobStart();
    again.jobEnd(.{ .steps = &rs, .engine_error = null, .succeeded = true }, false);
    try std.testing.expectEqualStrings("completed|success", try q(c, arena, "SELECT status || '|' || conclusion FROM runs WHERE id = 9280000000"));
    try std.testing.expectEqualStrings(created, try q(c, arena, "SELECT created_at::text FROM runs WHERE id = 9280000000"));
    try std.testing.expectEqualStrings("4", try q(c, arena, "SELECT count(*) FROM steps WHERE job_id = 9280000001"));

    // A second job of the same run: the run is in progress again, then failed when that job fails.
    var job2 = job;
    job2.check_run_id = 9280000002;
    var r2: Recorder = .init(&db, arena, std.testing.io, &job2, &ew, &.{});
    r2.jobStart();
    try std.testing.expectEqualStrings("in_progress", try q(c, arena, "SELECT status || coalesce(conclusion, '') FROM runs WHERE id = 9280000000"));
    var rs2 = [_]dagger.StepResult{ .{ .outcome = .failure, .exit_code = 1, .started_ms = t0, .completed_ms = t0 + 1 }, .{}, .{} };
    r2.jobEnd(.{ .steps = &rs2, .engine_error = null, .succeeded = false }, false);
    try std.testing.expectEqualStrings("completed|failure", try q(c, arena, "SELECT status || '|' || conclusion FROM runs WHERE id = 9280000000"));
    try std.testing.expectEqualStrings("1:failure,2:skipped,3:skipped", try q(c, arena,
        \\SELECT string_agg(number || ':' || conclusion, ',' ORDER BY number) FROM steps WHERE job_id = 9280000002 AND number > 0
    ));
    try std.testing.expectEqual(@as(usize, 0), ew.buffered().len); // no database errors reported
}

test "a database that is down is reported and never fails the job" {
    const url_mod = @import("db/url.zig");
    var a: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer a.deinit();
    const arena = a.allocator();
    // Port 1 on loopback refuses at once.
    const u: url_mod.Url = .{ .user = "u", .password = "p", .host = "127.0.0.1", .port = 1, .database = "d", .sslmode = .disable };
    var db: Db = .init(std.testing.allocator, std.testing.io, u);
    defer db.deinit();
    const steps = [_]job_mod.Step{testStep("a", false)};
    const job = testJob(&steps);
    var errbuf: [2048]u8 = undefined;
    var ew: std.Io.Writer = .fixed(&errbuf);
    var r: Recorder = .init(&db, arena, std.testing.io, &job, &ew, &.{});
    r.jobStart();
    const h = r.hook();
    h.call(h.ctx, 1, .{ .started_ms = 1 }, 1);
    var rs = [_]dagger.StepResult{.{ .outcome = .success, .started_ms = 1, .completed_ms = 2 }};
    r.jobEnd(.{ .steps = &rs, .engine_error = null, .succeeded = true }, false);
    const out = ew.buffered();
    try std.testing.expect(std.mem.indexOf(u8, out, "database: job start write failed: ConnectionRefused") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "skipping live step updates") != null);
    // The step hook wrote nothing (live writes stopped); job end tried once and hit the backoff.
    try std.testing.expectEqual(@as(usize, 1), std.mem.count(u8, out, "skipping live step updates"));
    try std.testing.expect(std.mem.indexOf(u8, out, "job end write failed: DatabaseUnavailable") != null);
}
