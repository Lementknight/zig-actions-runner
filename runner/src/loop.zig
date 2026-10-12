//! The runner's main flow (DESIGN §6): register a JIT runner, open a broker session, wait for one
//! job, acquire it, execute it through Dagger, report the result, and start over with a new
//! registration (`serve`), or exit after one job with `--once`.
const std = @import("std");
const Config = @import("config.zig").Config;
const jitconfig = @import("github/jitconfig.zig");
const auth = @import("github/auth.zig");
const broker = @import("github/broker.zig");
const runservice = @import("github/runservice.zig");
const job_mod = @import("job.zig");
const dagger = @import("dagger.zig");
const results = @import("github/results.zig");
const db = @import("db.zig");
const sink = @import("sink.zig");
const redact = @import("redact.zig");
const timefmt = @import("timefmt.zig");

const Allocator = std.mem.Allocator;

/// SPEC §2 exit codes.
pub const Exit = enum(u8) { done = 0, config = 1, github = 2, db = 3 };

/// SIGTERM / SIGINT received so far (`main` installs the handlers). The first asks the runners to
/// stop: waiting ones stop at once, running jobs finish first. The second exits immediately.
pub var stop_signals: std.atomic.Value(u32) = .init(0);

pub fn stopRequested() bool {
    return stop_signals.load(.acquire) > 0;
}

pub const Context = struct {
    /// Lives for one cycle (`serve` frees it after each job).
    arena: Allocator,
    /// Backs each cycle's arena.
    gpa: Allocator,
    io: std.Io,
    environ: *const std.process.Environ.Map,
    cfg: *const Config,
    log: *sink.LogSink,
    err: *std.Io.Writer,
    /// Config secrets; the job's own secrets are appended once it is acquired.
    secrets: []const []const u8,
    /// The runner's registration name; `serve` gives each cycle a new one.
    name: []const u8,
    /// Where run state is written (SPEC §5.2); null when the runner has no database.
    store: ?*db.Store = null,
};

fn say(c: Context, comptime fmt: []const u8, args: anytype) !void {
    const text = try std.fmt.allocPrint(c.arena, fmt, args);
    try c.log.append(0, 0, .stderr, text);
}

/// Poll responses are 202 when idle. A fresh token is minted before the old one can expire.
const token_refresh_secs = 10 * 60;

/// What one cycle did.
pub const Cycle = union(enum) {
    /// A job ran and GitHub was told; whether it succeeded.
    job: bool,
    /// No job ran (or it could not be completed): the exit code, and whether trying again could help.
    failed: struct { exit: Exit, retry: bool = true },
    /// A stop was requested while the runner waited for a job.
    stopped,
};

/// Runs `n` runners in this process as concurrent tasks (`std.Io.Group`), each serving jobs one after
/// another (`serve`) with its own registrations, memory per job and Dagger session per job. They
/// share the configuration, the log sinks and the database connection (all safe to share). Returns
/// once every runner has stopped: the most severe exit code among them.
pub fn pool(c: Context, n: u32) !Exit {
    const slots = try c.arena.alloc(Slot, n);
    var group: std.Io.Group = .init;
    for (slots) |*s| {
        s.* = .{ .c = c };
        group.concurrent(c.io, Slot.main, .{s}) catch |e| {
            try c.err.print("could not start {d} runners: {s}\n", .{ n, @errorName(e) });
            group.cancel(c.io);
            return .config;
        };
    }
    if (n > 1) try say(c, "started {d} runners", .{n});
    group.await(c.io) catch {};
    var worst: Exit = .done;
    for (slots) |s| if (@backingInt(s.exit) > @backingInt(worst)) {
        worst = s.exit;
    };
    return worst;
}

/// One runner of a pool. Its error messages go through its own buffer, flushed a cycle at a time, so
/// runners' messages do not interleave mid-line.
const Slot = struct {
    c: Context,
    exit: Exit = .done,
    err_buf: [4096]u8 = undefined,

    fn main(s: *Slot) void {
        var err_w: std.Io.File.Writer = .initStreaming(.stderr(), s.c.io, &s.err_buf);
        var c = s.c;
        c.err = &err_w.interface;
        s.exit = serve(c) catch |e| blk: {
            c.err.print("runner stopped: {s}\n", .{@errorName(e)}) catch {};
            break :blk .github;
        };
        err_w.interface.flush() catch {};
    }
};

/// Runs jobs one after another: each cycle registers a fresh JIT runner (GitHub gives a JIT runner a
/// single job), waits for a job, runs it, and frees everything the cycle allocated before the next.
/// A cycle that fails before running a job is retried with a growing delay (`backoffSecs`), unless
/// GitHub rejected the registration itself (bad token or scope), which retrying cannot fix.
/// With `--once`, returns after the first cycle: 0 if its job succeeded.
pub fn serve(c: Context) !Exit {
    var failures: u32 = 0;
    while (true) {
        var cycle_arena: std.heap.ArenaAllocator = .init(c.gpa);
        defer cycle_arena.deinit();
        var cc = c;
        cc.arena = cycle_arena.allocator();
        var suffix: [4]u8 = undefined;
        c.io.random(&suffix);
        cc.name = try std.fmt.allocPrint(cc.arena, "{s}-{x}", .{ c.cfg.name_prefix, suffix });

        const r = try cycle(cc);
        c.err.flush() catch {};
        if (c.cfg.once) return switch (r) {
            .job => |ok| if (ok) .done else .github,
            .failed => |f| f.exit,
            .stopped => .done,
        };
        if (r == .stopped or stopRequested()) return .done;
        switch (r) {
            .job => failures = 0,
            .stopped => unreachable,
            .failed => |f| {
                if (!f.retry) return f.exit;
                failures += 1;
                const wait = backoffSecs(failures);
                try c.err.print("trying again in {d}s ({d} failed attempt(s) in a row)\n", .{ wait, failures });
                try c.err.flush();
                // In steps, so a stop is not kept waiting.
                var waited: u32 = 0;
                while (waited < wait * 5 and !stopRequested()) : (waited += 1) c.io.sleep(.fromMilliseconds(200), .awake) catch {};
                if (stopRequested()) return .done;
            },
        }
    }
}

/// Seconds to wait after `failures` failed cycles in a row: 5, 10, 20, ... up to 5 minutes.
pub fn backoffSecs(failures: u32) u32 {
    if (failures == 0) return 0;
    const shift: u5 = @intCast(@min(failures - 1, 6));
    return @min(@as(u32, 5) << shift, 300);
}

const Polled = union(enum) { poll: anyerror!broker.Response, stop: void };

/// One long poll for a message (it can take about 50 s), given up as soon as a stop is requested:
/// the poll runs next to a watcher, and whichever ends first cancels the other (a blocked read is
/// interrupted). The cycle's cleanup then deletes the session and the registration.
fn poll(c: Context, url: []const u8, token: []const u8) !Polled {
    var buf: [2]Polled = undefined;
    var sel: std.Io.Select(Polled) = .init(c.io, &buf);
    try sel.concurrent(.poll, pollOnce, .{ c.arena, c.io, url, token });
    try sel.concurrent(.stop, waitForStop, .{c});
    const first = sel.await() catch Polled{ .stop = {} };
    while (sel.cancel()) |_| {}
    return first;
}

fn pollOnce(arena: Allocator, io: std.Io, url: []const u8, token: []const u8) anyerror!broker.Response {
    return broker.call(arena, io, .GET, url, token, null);
}

var stop_announced: std.atomic.Value(bool) = .init(false);

fn waitForStop(c: Context) void {
    while (!stopRequested()) c.io.sleep(.fromMilliseconds(200), .awake) catch return;
    // No allocation: the poll may be using the cycle's arena at the same time.
    if (!stop_announced.swap(true, .acq_rel)) c.log.append(0, 0, .stderr, "stopping: waiting runners stop now, running jobs finish first (a second signal exits at once)") catch {};
}

/// One registration and at most one job.
pub fn cycle(c: Context) !Cycle {
    var status: std.http.Status = .ok;
    const jit = jitconfig.generate(c.arena, c.io, c.cfg, c.name, &status) catch |e| {
        try c.err.writeAll("github error: ");
        try redact.write(c.err, @errorName(e), c.secrets);
        try c.err.print(" (HTTP {d})\n", .{@backingInt(status)});
        // Rejected credentials or scope will be rejected again; anything else may be transient.
        const fatal = switch (@backingInt(status)) {
            401, 403, 404, 422 => true,
            else => false,
        };
        return .{ .failed = .{ .exit = .github, .retry = !fatal } };
    };
    // Best effort: GitHub removes ephemeral runners itself once their job completes.
    defer _ = jitconfig.deleteRunner(c.arena, c.io, c.cfg, jit.runner_id) catch {};
    try say(c, "registered runner '{s}' (id {d})", .{ jit.runner_name, jit.runner_id });

    const creds = auth.parseCredentials(c.arena, jit.files) catch |e| return fail(c, "credentials", e);
    const settings = broker.parseSettings(c.arena, jit.files) catch |e| return fail(c, "runner settings", e);
    var token = mintToken(c, creds, &status) catch |e| return failHttp(c, "oauth token", e, status);
    var token_at = std.Io.Clock.real.now(c.io).toSeconds();

    const base = try std.fmt.allocPrint(c.arena, "{s}{s}", .{ settings.broker_url, if (std.mem.endsWith(u8, settings.broker_url, "/")) "" else "/" });
    const created = broker.call(c.arena, c.io, .POST, try std.fmt.allocPrint(c.arena, "{s}session", .{base}), token, try broker.sessionBody(c.arena, settings, "zig-runner")) catch |e| return fail(c, "create session", e);
    if (created.status.class() != .success) return failBody(c, "create session", created);
    const sid = jsonString(c.arena, created.body, "sessionId") orelse return fail(c, "create session", error.BadResponse);
    defer _ = broker.call(c.arena, c.io, .DELETE, std.fmt.allocPrint(c.arena, "{s}session?sessionId={s}", .{ base, sid }) catch "", token, null) catch {};
    try say(c, "'{s}' listening for jobs (labels: {s})", .{ c.name, c.cfg.labels });

    while (true) {
        if (stopRequested()) return .stopped;
        const now = std.Io.Clock.real.now(c.io).toSeconds();
        if (now - token_at > token_refresh_secs) {
            token = mintToken(c, creds, &status) catch |e| return failHttp(c, "oauth token refresh", e, status);
            token_at = now;
        }
        const m = switch (try poll(c, try broker.messageUrl(c.arena, base, sid, "Online"), token)) {
            .stop => return .stopped,
            .poll => |r| r catch |e| return fail(c, "poll", e),
        };
        if (m.status == .accepted or (m.status.class() == .success and m.body.len == 0)) continue;
        if (m.status.class() != .success) return failBody(c, "poll", m);

        const mtype = jsonString(c.arena, m.body, "messageType") orelse "";
        if (!std.mem.eql(u8, mtype, "RunnerJobRequest")) {
            try say(c, "ignoring message of type '{s}'", .{mtype});
            continue;
        }
        const inner = jsonString(c.arena, m.body, "body") orelse return fail(c, "job request", error.BadResponse);
        return handleJob(c, token, inner);
    }
}

/// Writes run state at the transitions SPEC §5.2 names: job start, step start, step end, job end.
/// Database errors are counted and reported at the end; they never fail the job.
const Reporter = struct {
    store: *db.Store,
    arena: Allocator,
    io: std.Io,
    job_id: u64,
    run_id: u64,
    failures: usize = 0,
    last_error: []const u8 = "",

    fn observer(r: *Reporter) dagger.Observer {
        return .{ .ptr = r, .startedFn = stepStartedFn, .finishedFn = stepFinishedFn };
    }

    fn iso(r: *Reporter, ms: i64) ?[]const u8 {
        if (ms <= 0) return null;
        return timefmt.isoTime(r.arena, ms) catch null;
    }

    fn note(r: *Reporter, e: anyerror) void {
        r.failures += 1;
        r.last_error = if (r.store.client.lastErrorText().len > 0) r.store.client.lastErrorText() else @errorName(e);
    }

    fn stepStartedFn(ptr: *anyopaque, number: u32, name: []const u8, started_ms: i64) void {
        const r: *Reporter = @ptrCast(@alignCast(ptr));
        r.store.upsertStep(.{ .job_id = r.job_id, .number = number, .name = name, .status = "in_progress", .started_at = r.iso(started_ms) }) catch |e| r.note(e);
    }

    fn stepFinishedFn(ptr: *anyopaque, number: u32, res: dagger.StepResult) void {
        const r: *Reporter = @ptrCast(@alignCast(ptr));
        r.store.upsertStep(.{
            .job_id = r.job_id,
            .number = number,
            .name = res.name,
            .status = "completed",
            .conclusion = stepConclusion(res),
            .started_at = r.iso(res.started_ms),
            .completed_at = r.iso(res.completed_ms),
        }) catch |e| r.note(e);
    }

    fn jobStarted(r: *Reporter, job: job_mod.Job, runner_name: []const u8, now_ms: i64) void {
        const g = job.github;
        r.store.upsertRun(.{
            .id = r.run_id,
            .repo = g.repository,
            .workflow = if (g.workflow.len > 0) g.workflow else "(unknown)",
            .event = nonEmpty(g.event_name),
            .branch = nonEmpty(g.ref_name),
            .sha = nonEmpty(g.sha),
            .status = "in_progress",
        }) catch |e| r.note(e);
        r.store.upsertJob(.{
            .id = r.job_id,
            .run_id = r.run_id,
            .name = jobName(job),
            .runner_name = runner_name,
            .status = "in_progress",
            .started_at = r.iso(now_ms),
        }) catch |e| r.note(e);
        // Step 0 is "Set up job" (db/migrations/001_init.sql): registration, acquiring and parsing.
        r.store.upsertStep(.{ .job_id = r.job_id, .number = 0, .name = "Set up job", .status = "completed", .conclusion = "success", .started_at = r.iso(now_ms), .completed_at = r.iso(now_ms) }) catch |e| r.note(e);
    }

    fn jobFinished(r: *Reporter, job: job_mod.Job, runner_name: []const u8, succeeded: bool, started_ms: i64, now_ms: i64) void {
        const conclusion: []const u8 = if (succeeded) "success" else "failure";
        r.store.upsertJob(.{
            .id = r.job_id,
            .run_id = r.run_id,
            .name = jobName(job),
            .runner_name = runner_name,
            .status = "completed",
            .conclusion = conclusion,
            .started_at = r.iso(started_ms),
            .completed_at = r.iso(now_ms),
        }) catch |e| r.note(e);
        // One runner handles one job, so the run's state follows this job (SPEC §5.2).
        const g = job.github;
        r.store.upsertRun(.{
            .id = r.run_id,
            .repo = g.repository,
            .workflow = if (g.workflow.len > 0) g.workflow else "(unknown)",
            .event = nonEmpty(g.event_name),
            .branch = nonEmpty(g.ref_name),
            .sha = nonEmpty(g.sha),
            .status = "completed",
            .conclusion = conclusion,
            .completed_at = r.iso(now_ms),
        }) catch |e| r.note(e);
    }
};

fn nonEmpty(s: []const u8) ?[]const u8 {
    return if (s.len == 0) null else s;
}

fn jobName(job: job_mod.Job) []const u8 {
    if (job.display_name.len > 0) return job.display_name;
    if (job.github.job.len > 0) return job.github.job;
    return "job";
}

/// Same vocabulary as the DB's `steps.conclusion`: success | failure | skipped.
fn stepConclusion(res: dagger.StepResult) []const u8 {
    return switch (res.outcome) {
        .success => "success",
        .failure => if (res.continued) "success" else "failure",
        .skipped, .not_run => "skipped",
    };
}

fn handleJob(c: Context, runner_token: []const u8, inner_body: []const u8) !Cycle {
    const jr = runservice.parseJobRequest(c.arena, inner_body) catch |e| return fail(c, "job request", e);
    const acq = runservice.acquire(c.arena, c.io, jr, runner_token) catch |e| return fail(c, "acquirejob", e);
    if (acq.status.class() != .success) return failBody(c, "acquirejob", acq);

    // The definition holds secrets; it is parsed but never printed.
    const job = job_mod.parse(c.arena, acq.body) catch |e| return fail(c, "parse job", e);
    // Everything the job logs is also kept (redacted, timestamped) so it can be uploaded to GitHub.
    var collect: sink.LogSink = .{ .collect = .{ .arena = c.arena, .io = c.io, .inner = c.log } };
    collect.setSecrets(try std.mem.concat(c.arena, []const u8, &.{ c.secrets, job.secrets }));
    const log = &collect;
    // For the runner's own console and database only: the job's log starts as GitHub's does.
    try c.log.append(job.check_run_id, 0, .stdout, try std.fmt.allocPrint(c.arena, "job acquired: {d} steps", .{job.steps.len}));

    var reporter: ?Reporter = null;
    const job_started_ms = std.Io.Clock.real.now(c.io).toMilliseconds();
    if (c.store) |st| {
        const run_id = std.fmt.parseInt(u64, job.github.run_id, 10) catch 0;
        if (run_id != 0 and job.check_run_id != 0) {
            reporter = .{ .store = st, .arena = c.arena, .io = c.io, .job_id = job.check_run_id, .run_id = run_id };
            reporter.?.jobStarted(job, c.name, job_started_ms);
        } else try c.err.writeAll("run state not recorded: the job has no run id or job id\n");
    }

    var result: dagger.Result = undefined;
    // Fail the job up front rather than run steps that would fail in confusing ways without them.
    const unsupported: ?[]const u8 = if (job.has_container)
        "container: jobs are not supported yet"
    else if (job.has_services)
        "services: containers are not supported yet (the job's steps could not reach them)"
    else
        null;
    if (unsupported) |why| {
        const step_results = try c.arena.alloc(dagger.StepResult, job.steps.len);
        @memset(step_results, .{});
        try log.append(job.check_run_id, 0, .stderr, why);
        result = .{ .steps = step_results, .engine_error = null, .succeeded = false };
    } else {
        result = try dagger.run(c.arena, c.io, c.environ, .{
            .dagger_cmd = c.cfg.dagger_cmd,
            .image = c.cfg.image,
            .js_runtime = c.cfg.js_runtime,
            .engine = c.cfg.engineEndpoint(),
            .gpa = c.gpa,
            .nesting = c.cfg.dagger_nesting,
            .package_caches = c.cfg.package_caches,
            .step_cache = c.cfg.step_cache,
            .observer = if (reporter) |*r| r.observer() else null,
            .sink_job_id = job.check_run_id,
            .runner_name = c.name,
        }, job, log);
        if (result.engine_error) |msg| {
            try log.append(job.check_run_id, 0, .stderr, "dagger failed before running the steps:");
            try log.append(job.check_run_id, 0, .stderr, msg);
        }
    }
    try log.flush();
    if (reporter) |*r| {
        r.jobFinished(job, c.name, result.succeeded, job_started_ms, std.Io.Clock.real.now(c.io).toMilliseconds());
        if (r.failures > 0) try c.err.print("run state: {d} database write(s) failed (last: {s})\n", .{ r.failures, r.last_error });
    }
    try uploadLogs(c, job, log.collect.lines.items);

    const conclusion: runservice.Conclusion = if (result.succeeded) .succeeded else .failed;
    const step_json = try stepResultsJson(c.arena, job, result);
    var done = runservice.complete(c.arena, c.io, jr, job.job_token, job.plan_id, job.job_id, conclusion, step_json) catch |e| return fail(c, "completejob", e);
    if (done.status.class() != .success) {
        // A held job blocks the run for minutes, so always finish it: retry without step details.
        try c.err.print("completejob with step results failed (HTTP {d}: {s}); retrying without them\n", .{ @backingInt(done.status), done.body[0..@min(done.body.len, 200)] });
        done = runservice.complete(c.arena, c.io, jr, job.job_token, job.plan_id, job.job_id, conclusion, "[]") catch |e| return fail(c, "completejob", e);
        if (done.status.class() != .success) return failBody(c, "completejob", done);
    }
    try log.append(job.check_run_id, 0, .stdout, try std.fmt.allocPrint(c.arena, "job {s}", .{@tagName(conclusion)}));
    return .{ .job = result.succeeded };
}

/// Uploads each step's log, then the whole job's, so GitHub's UI can show them. Failures are reported
/// but never stop the job from completing.
fn uploadLogs(c: Context, job: job_mod.Job, lines: []const sink.CollectedLine) !void {
    for (job.steps, 1..) |step, n| {
        const blob = try results.formatBlob(c.arena, lines, @intCast(n));
        if (blob.line_count == 0) continue;
        const r = results.upload(c.arena, c.io, job, .{ .step = step.id }, blob);
        try c.err.print("job {d}: log upload step {d}: {s}{s}\n", .{ job.check_run_id, n, if (r.ok) "ok, " else "FAILED: ", r.detail });
    }
    const all = try results.formatBlob(c.arena, lines, null);
    if (all.line_count > 0) {
        const r = results.upload(c.arena, c.io, job, .job, all);
        try c.err.print("job {d}: log upload job: {s}{s}\n", .{ job.check_run_id, if (r.ok) "ok, " else "FAILED: ", r.detail });
    }
}

/// `stepResults` for completejob. Field names follow `actions/runner`'s StepResult; verified live
/// by checking the steps GitHub reports for the job.
pub fn stepResultsJson(arena: Allocator, job: job_mod.Job, result: dagger.Result) ![]const u8 {
    const Item = struct {
        external_id: []const u8,
        number: u32,
        name: []const u8,
        status: []const u8,
        conclusion: []const u8,
        started_at: ?[]const u8,
        completed_at: ?[]const u8,
    };
    const items = try arena.alloc(Item, job.steps.len);
    for (items, job.steps, result.steps, 1..) |*it, step, r, n| {
        it.* = .{
            .external_id = step.id,
            .number = @intCast(n),
            .name = if (r.name.len > 0) r.name else step.name,
            .status = "completed",
            // Same vocabulary as the job conclusion (verified live): succeeded / failed / skipped.
            .conclusion = switch (r.outcome) {
                .success => "succeeded",
                .failure => if (r.continued) "succeeded" else "failed",
                .skipped, .not_run => "skipped",
            },
            .started_at = if (r.started_ms > 0) try timefmt.isoTime(arena, r.started_ms) else null,
            .completed_at = if (r.completed_ms > 0) try timefmt.isoTime(arena, r.completed_ms) else null,
        };
    }
    var aw: std.Io.Writer.Allocating = .init(arena);
    try std.json.Stringify.value(items, .{ .emit_null_optional_fields = false }, &aw.writer);
    return aw.written();
}

fn mintToken(c: Context, creds: auth.Credentials, status: *std.http.Status) !([]const u8) {
    var jti: [8]u8 = undefined;
    c.io.random(&jti);
    const now = std.Io.Clock.real.now(c.io).toSeconds();
    const jwt = try auth.buildJwt(c.arena, creds, now, try std.fmt.allocPrint(c.arena, "{x}", .{jti}));
    return auth.fetchAccessToken(c.arena, c.io, creds, jwt, status);
}

fn jsonString(arena: Allocator, body: []const u8, key: []const u8) ?[]const u8 {
    const v = std.json.parseFromSliceLeaky(std.json.Value, arena, body, .{}) catch return null;
    if (v != .object) return null;
    const s = v.object.get(key) orelse return null;
    return if (s == .string) s.string else null;
}

const github_failure: Cycle = .{ .failed = .{ .exit = .github } };

fn fail(c: Context, what: []const u8, e: anyerror) !Cycle {
    try c.err.print("error during {s}: ", .{what});
    try redact.write(c.err, @errorName(e), c.secrets);
    try c.err.writeByte('\n');
    return github_failure;
}

fn failHttp(c: Context, what: []const u8, e: anyerror, status: std.http.Status) !Cycle {
    try c.err.print("error during {s}: {s} (HTTP {d})\n", .{ what, @errorName(e), @backingInt(status) });
    return github_failure;
}

fn failBody(c: Context, what: []const u8, r: broker.Response) !Cycle {
    // Error bodies are short JSON documents without credentials.
    try c.err.print("error during {s}: HTTP {d}: {s}\n", .{ what, @backingInt(r.status), r.body[0..@min(r.body.len, 400)] });
    return github_failure;
}

test "backoffSecs doubles from 5s up to 5 minutes" {
    try std.testing.expectEqual(@as(u32, 5), backoffSecs(1));
    try std.testing.expectEqual(@as(u32, 10), backoffSecs(2));
    try std.testing.expectEqual(@as(u32, 160), backoffSecs(6));
    try std.testing.expectEqual(@as(u32, 300), backoffSecs(7));
    try std.testing.expectEqual(@as(u32, 300), backoffSecs(1000));
}

test "stepResultsJson maps outcomes and continue-on-error" {
    var a: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer a.deinit();
    const arena = a.allocator();
    const mk = struct {
        fn step(id: []const u8, coe: bool) job_mod.Step {
            _ = coe;
            return .{ .id = id, .name = id, .condition = "success()", .action = .{ .unsupported = "x" } };
        }
    };
    const steps = [_]job_mod.Step{ mk.step("a", false), mk.step("b", true), mk.step("c", false), mk.step("d", false) };
    const job: job_mod.Job = .{ .plan_id = "p", .job_id = "j", .job_token = "t", .check_run_id = 1, .has_container = false, .secrets = &.{}, .steps = &steps };
    var rs = [_]dagger.StepResult{
        .{ .outcome = .success, .started_ms = 1000, .completed_ms = 2000 },
        .{ .outcome = .failure, .exit_code = 5, .continued = true },
        .{ .outcome = .failure, .exit_code = 2 },
        .{ .outcome = .skipped },
    };
    const json = try stepResultsJson(arena, job, .{ .steps = &rs, .engine_error = null, .succeeded = false });
    try std.testing.expect(std.mem.indexOf(u8, json, "\"external_id\":\"a\",\"number\":1,\"name\":\"a\",\"status\":\"completed\",\"conclusion\":\"succeeded\",\"started_at\":\"1970-01-01T00:00:01.000Z\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"name\":\"b\",\"status\":\"completed\",\"conclusion\":\"succeeded\"}") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"name\":\"c\",\"status\":\"completed\",\"conclusion\":\"failed\"}") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"name\":\"d\",\"status\":\"completed\",\"conclusion\":\"skipped\"}") != null);
}
