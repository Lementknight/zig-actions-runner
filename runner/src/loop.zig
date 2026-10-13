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
const engine = @import("engine.zig");
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

/// Deletes the cycle's runner registration, trying again (after 1 s, then 2 s) when GitHub refuses
/// for now (422 right after a job, 5xx) or the request fails; a registration still left is reported
/// instead of being dropped silently. 404: already gone.
fn removeRegistration(c: Context, id: u64, name: []const u8) void {
    var last: []const u8 = "";
    for (0..3) |attempt| {
        if (attempt > 0) c.io.sleep(.fromMilliseconds(@as(i64, @intCast(attempt)) * 1000), .awake) catch {};
        if (jitconfig.deleteRunner(c.arena, c.io, c.cfg, id)) |status| {
            const code = @backingInt(status);
            if (status.class() == .success or code == 404) return;
            last = std.fmt.allocPrint(c.arena, "HTTP {d}", .{code}) catch "HTTP error";
            if (code != 422 and status.class() != .server_error) break;
        } else |e| last = @errorName(e);
    }
    c.err.print("could not remove runner registration '{s}' (id {d}): {s}; delete it in the repository's runner settings\n", .{ name, id, last }) catch {};
}

/// One registration and at most one job.
pub fn cycle(c: Context) !Cycle {
    var status: std.http.Status = .ok;
    var message: []const u8 = "";
    const jit = jitconfig.generate(c.arena, c.io, c.cfg, c.name, &status, &message) catch |e| {
        try c.err.writeAll("github error: ");
        try redact.write(c.err, @errorName(e), c.secrets);
        try c.err.print(" (HTTP {d})", .{@backingInt(status)});
        if (message.len > 0) {
            try c.err.writeAll(": ");
            try redact.write(c.err, message, c.secrets);
        }
        // What the token needs, for the refusals a wrong token causes.
        if (@backingInt(status) == 403 or @backingInt(status) == 404)
            try c.err.writeAll("\n  GH_TOKEN must be able to manage self-hosted runners of GH_SCOPE: a fine-grained token with \"Administration: read and write\" on the repository (\"Self-hosted runners: read and write\" for an organization), or a classic token with repo (admin:org)");
        try c.err.writeByte('\n');
        // Rejected credentials or scope will be rejected again; anything else may be transient.
        const fatal = switch (@backingInt(status)) {
            401, 403, 404, 422 => true,
            else => false,
        };
        return .{ .failed = .{ .exit = .github, .retry = !fatal } };
    };
    // GitHub removes ephemeral runners itself once their job completes; an idle one must be removed.
    defer removeRegistration(c, jit.runner_id, jit.runner_name);
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
        return handleJob(c, .{ .creds = creds, .token = token, .token_at = token_at, .url = try broker.messageUrl(c.arena, base, sid, "Busy") }, inner);
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

    fn jobFinished(r: *Reporter, job: job_mod.Job, runner_name: []const u8, conclusion: []const u8, started_ms: i64, now_ms: i64) void {
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

/// Same vocabulary as the DB's `steps.conclusion`: success | failure | cancelled | skipped.
fn stepConclusion(res: dagger.StepResult) []const u8 {
    return switch (res.outcome) {
        .success => "success",
        .failure => if (res.continued) "success" else "failure",
        .cancelled => "cancelled",
        .skipped, .not_run => "skipped",
    };
}

/// The runner's session, kept listening while a job runs (see `CancelWatch`).
const Listening = struct {
    creds: auth.Credentials,
    token: []const u8,
    token_at: i64,
    /// The broker's message URL, with the runner `Busy`.
    url: []const u8,
};

fn handleJob(c: Context, session: Listening, inner_body: []const u8) !Cycle {
    const runner_token = session.token;
    const jr = runservice.parseJobRequest(c.arena, inner_body) catch |e| return fail(c, "job request", e);
    const acq = runservice.acquire(c.arena, c.io, jr, runner_token) catch |e| return fail(c, "acquirejob", e);
    if (acq.status.class() != .success) return failBody(c, "acquirejob", acq);

    // The definition holds secrets; it is parsed but never printed.
    const job = job_mod.parse(c.arena, acq.body) catch |e| return fail(c, "parse job", e);

    // GitHub cancels a job (in its UI, or at the job's timeout-minutes) through the runner's session.
    var cancel: dagger.Cancel = .{};
    // Keep the hold on the job while it runs, as GitHub's runner does (see `Renewer`).
    var renewer: Renewer = .{ .c = c, .token = job.job_token, .jr = jr, .plan_id = job.plan_id, .job_id = job.job_id, .log_job = job.check_run_id, .cancel = &cancel };
    var renewing: ?std.Io.Future(void) = c.io.concurrent(Renewer.run, .{&renewer}) catch null;
    defer if (renewing) |*f| {
        renewer.stop.store(true, .release);
        f.await(c.io);
    };
    var watcher: CancelWatch = .{ .c = c, .session = session, .job_id = job.job_id, .log_job = job.check_run_id, .cancel = &cancel };
    var watching: ?std.Io.Future(void) = c.io.concurrent(CancelWatch.run, .{&watcher}) catch null;
    defer if (watching) |*f| {
        watcher.stop.store(true, .release);
        f.cancel(c.io);
    };
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
    const unsupported: ?[]const u8 = job.container_error orelse job.services_error;
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
            .cancel = &cancel,
            .observer = if (reporter) |*r| r.observer() else null,
            .sink_job_id = job.check_run_id,
            .runner_name = c.name,
        }, job, log);
        // A cancel can also end the job through a query it cut short (past the grace period).
        if (cancel.requested.load(.acquire)) {
            result.cancelled = true;
            result.succeeded = false;
        }
        if (result.engine_error) |msg| if (!result.cancelled) {
            try log.append(job.check_run_id, 0, .stderr, "dagger failed before running the steps:");
            try log.append(job.check_run_id, 0, .stderr, msg);
        };
    }
    // "Complete job", as GitHub's runner ends a job (the job's containers went with its session).
    const complete_started = std.Io.Clock.real.now(c.io).toMilliseconds();
    const complete_step: u32 = if (result.next_log_step > 0) result.next_log_step else @intCast(job.steps.len + 1);
    for (result.output_lines) |l| try log.append(job.check_run_id, complete_step, .stdout, l);
    try log.append(job.check_run_id, complete_step, .stdout, "Cleaning up orphan processes");
    try log.flush();
    if (reporter) |*r| {
        r.jobFinished(job, c.name, if (result.cancelled) "cancelled" else if (result.succeeded) "success" else "failure", job_started_ms, std.Io.Clock.real.now(c.io).toMilliseconds());
        if (r.failures > 0) try c.err.print("run state: {d} database write(s) failed (last: {s})\n", .{ r.failures, r.last_error });
    }
    const shown = try shownSteps(c.arena, c.io, job, result, job_started_ms, .{ .log_step = complete_step, .started_ms = complete_started, .completed_ms = std.Io.Clock.real.now(c.io).toMilliseconds() });
    try uploadLogs(c, job, shown, log.collect.lines.items, result.summaries, log.currentSecrets());

    const conclusion: runservice.Conclusion = if (result.cancelled) .canceled else if (result.succeeded) .succeeded else .failed;
    const step_json = try stepResultsJson(c.arena, shown);
    const annotations_json = try annotationsJson(c.arena, shown, result.annotations);
    var done = runservice.complete(c.arena, c.io, jr, job.job_token, job.plan_id, job.job_id, conclusion, step_json, result.outputs, annotations_json) catch |e| return fail(c, "completejob", e);
    if (done.status.class() != .success) {
        // A held job blocks the run for minutes, so always finish it: retry without step details.
        try c.err.print("completejob with step results and annotations failed (HTTP {d}: {s}); retrying without them\n", .{ @backingInt(done.status), done.body[0..@min(done.body.len, 200)] });
        done = runservice.complete(c.arena, c.io, jr, job.job_token, job.plan_id, job.job_id, conclusion, "[]", result.outputs, "[]") catch |e| return fail(c, "completejob", e);
        if (done.status.class() != .success) return failBody(c, "completejob", done);
    }
    try log.append(job.check_run_id, 0, .stdout, try std.fmt.allocPrint(c.arena, "job {s}", .{@tagName(conclusion)}));
    return .{ .job = result.succeeded };
}

/// A step as GitHub shows it for the job.
pub const Shown = struct {
    /// GitHub's step id, or one made here for the steps the runner adds.
    id: []const u8,
    number: u32,
    name: []const u8,
    /// Which lines are its log (`sink.CollectedLine.step`): 0 is "Set up job", 1..n the job's steps,
    /// then `pre`/`post` scripts and "Complete job" (see `dagger.ExtraStep`).
    log_step: u32,
    /// succeeded / failed / skipped, as completejob takes them.
    conclusion: []const u8,
    started_ms: i64 = 0,
    completed_ms: i64 = 0,
};

/// Renews the runner's hold on its job every 60 s while the job runs, as GitHub's runner does
/// (`renewjob`). Without it GitHub fails the job 10 minutes after it was acquired ("The self-hosted
/// runner lost communication with the server"), even while its steps still run (SPEC §3). Like
/// completejob it takes the job's own token; the runner's gets 401. Runs next to the job, so it
/// has memory of its own and reports through the runner's shared (locked) sink, not the job's log.
const Renewer = struct {
    c: Context,
    token: []const u8,
    jr: runservice.JobRequest,
    plan_id: []const u8,
    job_id: []const u8,
    log_job: u64,
    /// Set when GitHub no longer has the job (404): it ended it, so nothing of it runs on.
    cancel: *dagger.Cancel,
    stop: std.atomic.Value(bool) = .init(false),

    pub const interval_secs = 60;

    fn run(r: *Renewer) void {
        var reported = false;
        while (true) {
            var waited: u32 = 0;
            while (waited < interval_secs * 5 and !r.stop.load(.acquire)) : (waited += 1) r.c.io.sleep(.fromMilliseconds(200), .awake) catch return;
            if (r.stop.load(.acquire)) return;
            var call: std.heap.ArenaAllocator = .init(r.c.gpa);
            defer call.deinit();
            const arena = call.allocator();
            const resp = runservice.renew(arena, r.c.io, r.jr, r.token, r.plan_id, r.job_id) catch |e| {
                r.say(arena, "renewjob failed: {s}", .{@errorName(e)});
                continue;
            };
            if (resp.status == .not_found) {
                // Seen when a cancelled job's grace period ran out: GitHub closed the job itself.
                r.say(arena, "GitHub no longer has the job (renewjob: HTTP 404); stopping it", .{});
                r.cancel.hard_deadline_ms.store(std.Io.Clock.real.now(r.c.io).toMilliseconds(), .release);
                r.cancel.requested.store(true, .release);
                return;
            }
            if (resp.status.class() != .success) {
                r.say(arena, "renewjob failed: HTTP {d}: {s}", .{ @backingInt(resp.status), resp.body[0..@min(resp.body.len, 200)] });
            } else if (!reported) {
                reported = true;
                r.say(arena, "job hold renewed (locked until {s})", .{jsonString(arena, resp.body, "lockedUntil") orelse "?"});
            }
        }
    }

    fn say(r: *Renewer, arena: Allocator, comptime fmt: []const u8, args: anytype) void {
        const text = std.fmt.allocPrint(arena, "job {d}: " ++ fmt, .{r.log_job} ++ args) catch return;
        r.c.log.append(0, 0, .stderr, text) catch {};
    }
};

/// Listens on the runner's session while its job runs, as GitHub's runner does, for a
/// `JobCancellation` message: `{"jobId": ..., "timeout": "0.00:05:00.0000"}`, sent when the run is
/// cancelled and when the job reaches its `timeout-minutes` (GitHub enforces that limit itself; the
/// job definition does not carry it). The timeout is the grace period for what still runs after the
/// cancel (`if: always()` steps, post scripts); past it, the job's queries are ended too.
const CancelWatch = struct {
    c: Context,
    session: Listening,
    job_id: []const u8,
    log_job: u64,
    cancel: *dagger.Cancel,
    stop: std.atomic.Value(bool) = .init(false),

    fn run(w: *CancelWatch) void {
        var state: std.heap.ArenaAllocator = .init(w.c.gpa);
        defer state.deinit();
        var token = w.session.token;
        var token_at = w.session.token_at;
        while (!w.stop.load(.acquire)) {
            var call: std.heap.ArenaAllocator = .init(w.c.gpa);
            defer call.deinit();
            var cc = w.c;
            cc.arena = call.allocator();
            const now = std.Io.Clock.real.now(cc.io).toSeconds();
            if (now - token_at > token_refresh_secs) {
                var status: std.http.Status = .ok;
                if (mintToken(cc, w.session.creds, &status)) |t| {
                    token = state.allocator().dupe(u8, t) catch token;
                    token_at = now;
                } else |_| {}
            }
            const m = broker.call(cc.arena, cc.io, .GET, w.session.url, token, null) catch |e| {
                if (e == error.Canceled) return;
                cc.io.sleep(.fromSeconds(5), .awake) catch return;
                continue;
            };
            if (m.status.class() != .success or m.body.len == 0) {
                if (m.status != .accepted and m.status.class() != .success) cc.io.sleep(.fromSeconds(5), .awake) catch return;
                continue;
            }
            const mtype = jsonString(cc.arena, m.body, "messageType") orelse "";
            if (!std.mem.eql(u8, mtype, "JobCancellation")) continue;
            const inner = jsonString(cc.arena, m.body, "body") orelse continue;
            const id = jsonString(cc.arena, inner, "jobId") orelse continue;
            if (!std.mem.eql(u8, id, w.job_id)) continue;
            const grace_ms = timeSpanMs(jsonString(cc.arena, inner, "timeout") orelse "") orelse default_grace_ms;
            w.cancel.hard_deadline_ms.store(std.Io.Clock.real.now(cc.io).toMilliseconds() + grace_ms, .release);
            w.cancel.requested.store(true, .release);
            const text = std.fmt.allocPrint(cc.arena, "job {d}: cancelled by GitHub; stopping the running step ({d} s for what still runs)", .{ w.log_job, @divTrunc(grace_ms, 1000) }) catch return;
            w.c.log.append(0, 0, .stderr, text) catch {};
            return;
        }
    }

    /// GitHub's default `cancel-timeout-minutes`.
    const default_grace_ms = 5 * 60 * 1000;
};

/// A .NET TimeSpan as GitHub writes one (`[d.]hh:mm:ss[.fffffff]`) in milliseconds; null when it
/// is not one.
pub fn timeSpanMs(text: []const u8) ?i64 {
    var rest = text;
    var days: i64 = 0;
    const colon = std.mem.indexOfScalar(u8, rest, ':') orelse return null;
    if (std.mem.lastIndexOfScalar(u8, rest[0..colon], '.')) |dot| {
        days = std.fmt.parseInt(i64, rest[0..dot], 10) catch return null;
        rest = rest[dot + 1 ..];
    }
    var parts = std.mem.splitScalar(u8, rest, ':');
    const h = std.fmt.parseInt(i64, parts.next() orelse return null, 10) catch return null;
    const m = std.fmt.parseInt(i64, parts.next() orelse return null, 10) catch return null;
    const sec = std.fmt.parseFloat(f64, parts.next() orelse return null) catch return null;
    if (parts.next() != null) return null;
    return ((days * 24 + h) * 60 + m) * 60_000 + @as(i64, @intFromFloat(sec * 1000));
}

test "timeSpanMs reads GitHub's cancel timeout" {
    try std.testing.expectEqual(@as(?i64, 300_000), timeSpanMs("0.00:05:00.0000"));
    try std.testing.expectEqual(@as(?i64, 90_500), timeSpanMs("00:01:30.5"));
    try std.testing.expectEqual(@as(?i64, 86_400_000 + 60_000), timeSpanMs("1.00:01:00"));
    try std.testing.expectEqual(@as(?i64, null), timeSpanMs("soon"));
}

/// The steps GitHub shows for a job, in its runner's order and numbering: "Set up job", the actions'
/// `pre` scripts, the job's steps, their `post` scripts, "Complete job". GitHub lists only the job's
/// own steps; its runner adds the others with ids of their own, and so does this one.
pub fn shownSteps(arena: Allocator, io: std.Io, job: job_mod.Job, result: dagger.Result, job_started_ms: i64, complete: struct { log_step: u32, started_ms: i64, completed_ms: i64 }) ![]Shown {
    var out: std.ArrayList(Shown) = .empty;
    var first_started: i64 = complete.started_ms;
    for (result.steps) |r| if (r.started_ms > 0 and r.started_ms < first_started) {
        first_started = r.started_ms;
    };
    for (result.extra) |e| if (e.started_ms > 0 and e.started_ms < first_started) {
        first_started = e.started_ms;
    };
    try out.append(arena, .{ .id = try newId(arena, io), .number = 0, .name = "Set up job", .log_step = 0, .conclusion = "succeeded", .started_ms = job_started_ms, .completed_ms = first_started });
    for (result.extra) |e| if (e.kind == .pre) try out.append(arena, try extraShown(arena, io, e));
    for (job.steps, result.steps, 1..) |step, r, n| try out.append(arena, .{
        .id = step.id,
        .number = 0,
        .name = if (r.name.len > 0) r.name else step.name,
        .log_step = @intCast(n),
        // Same vocabulary as the job conclusion (verified live): succeeded / failed / canceled / skipped.
        .conclusion = switch (r.outcome) {
            .success => "succeeded",
            .failure => if (r.continued) "succeeded" else "failed",
            .cancelled => "canceled",
            .skipped, .not_run => "skipped",
        },
        .started_ms = r.started_ms,
        .completed_ms = r.completed_ms,
    });
    for (result.extra) |e| if (e.kind == .post) try out.append(arena, try extraShown(arena, io, e));
    try out.append(arena, .{ .id = try newId(arena, io), .number = 0, .name = "Complete job", .log_step = complete.log_step, .conclusion = "succeeded", .started_ms = complete.started_ms, .completed_ms = complete.completed_ms });
    for (out.items, 1..) |*s, n| s.number = @intCast(n);
    return out.items;
}

fn extraShown(arena: Allocator, io: std.Io, e: dagger.ExtraStep) !Shown {
    return .{
        .id = try newId(arena, io),
        .number = 0,
        .name = e.name,
        .log_step = e.log_step,
        .conclusion = if (e.outcome == .success) "succeeded" else "failed",
        .started_ms = e.started_ms,
        .completed_ms = e.completed_ms,
    };
}

fn newId(arena: Allocator, io: std.Io) ![]const u8 {
    const id = try arena.alloc(u8, 36);
    engine.uuid(io, id[0..36]);
    return id;
}

/// Uploads each shown step's log, then the whole job's, so GitHub's UI can show them. Failures are
/// reported but never stop the job from completing.
fn uploadLogs(c: Context, job: job_mod.Job, shown: []const Shown, lines: []const sink.CollectedLine, summaries: []const []const u8, secrets: []const []const u8) !void {
    for (shown) |s| {
        const blob = try results.formatBlob(c.arena, lines, s.log_step);
        if (blob.line_count == 0) continue;
        const r = results.upload(c.arena, c.io, job, .{ .step = s.id }, blob);
        try c.err.print("job {d}: log upload '{s}': {s}{s}\n", .{ job.check_run_id, s.name, if (r.ok) "ok, " else "FAILED: ", r.detail });
    }
    // Step summaries, masked as the logs are.
    for (shown) |s| {
        if (s.log_step == 0 or s.log_step > summaries.len) continue;
        const md = summaries[s.log_step - 1];
        if (md.len == 0) continue;
        var masked: std.Io.Writer.Allocating = .init(c.arena);
        try redact.write(&masked.writer, md, secrets);
        const r = results.uploadSummary(c.arena, c.io, job, s.id, masked.written());
        try c.err.print("job {d}: summary upload '{s}': {s}{s}\n", .{ job.check_run_id, s.name, if (r.ok) "ok, " else "FAILED: ", r.detail });
    }
    const all = try results.formatBlob(c.arena, lines, null);
    if (all.line_count > 0) {
        const r = results.upload(c.arena, c.io, job, .job, all);
        try c.err.print("job {d}: log upload job: {s}{s}\n", .{ job.check_run_id, if (r.ok) "ok, " else "FAILED: ", r.detail });
    }
}

/// `stepResults` for completejob. Field names follow `actions/runner`'s StepResult; verified live
/// by checking the steps GitHub reports for the job.
/// `annotations` for completejob, as actions/runner sends them (its `Annotation` contract): level
/// FAILURE / WARNING / NOTICE, the message, and where it points (a repository path and lines and
/// columns) when the workflow command said, with the number of the step it came from. An annotation
/// without a file is shown by GitHub on the job's line in the workflow file.
pub fn annotationsJson(arena: Allocator, shown: []const Shown, annotations: []const dagger.Annotation) ![]const u8 {
    const Item = struct {
        level: []const u8,
        message: []const u8,
        title: ?[]const u8 = null,
        path: ?[]const u8 = null,
        startLine: ?u32 = null,
        endLine: ?u32 = null,
        startColumn: ?u32 = null,
        endColumn: ?u32 = null,
        stepNumber: ?u32 = null,
        isInfrastructureIssue: bool = false,
    };
    const items = try arena.alloc(Item, annotations.len);
    for (items, annotations) |*it, a| {
        const an = a.an;
        const line = propertyNumber(an.line);
        const col = propertyNumber(an.col);
        it.* = .{
            .level = if (std.mem.eql(u8, an.level, "error")) "FAILURE" else if (std.mem.eql(u8, an.level, "warning")) "WARNING" else "NOTICE",
            .message = an.message,
            .title = if (an.title) |t| (if (t.len > 0) t else null) else null,
            .path = if (an.file) |f| (if (f.len > 0) f else null) else null,
            .startLine = line,
            .endLine = propertyNumber(an.end_line) orelse line,
            .startColumn = col,
            .endColumn = propertyNumber(an.end_column) orelse col,
            .stepNumber = for (shown) |s| (if (s.log_step == a.step) break s.number) else null,
        };
    }
    var aw: std.Io.Writer.Allocating = .init(arena);
    try std.json.Stringify.value(items, .{ .emit_null_optional_fields = false }, &aw.writer);
    return aw.written();
}

fn propertyNumber(text: ?[]const u8) ?u32 {
    return std.fmt.parseInt(u32, std.mem.trim(u8, text orelse return null, " "), 10) catch null;
}

test "annotations: GitHub's levels, the place they point to, and the step they came from" {
    var a: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer a.deinit();
    const shown = [_]Shown{
        .{ .id = "s", .number = 1, .name = "Set up job", .log_step = 0, .conclusion = "succeeded" },
        .{ .id = "b", .number = 2, .name = "Build", .log_step = 1, .conclusion = "failed" },
    };
    const json = try annotationsJson(a.allocator(), &shown, &.{
        .{ .step = 1, .an = .{ .level = "error", .message = "bad", .file = "src/a.zig", .line = "3", .col = "5", .title = "T" } },
        .{ .step = 1, .an = .{ .level = "notice", .message = "fyi", .line = "x" } },
    });
    try std.testing.expectEqualStrings(
        \\[{"level":"FAILURE","message":"bad","title":"T","path":"src/a.zig","startLine":3,"endLine":3,"startColumn":5,"endColumn":5,"stepNumber":2,"isInfrastructureIssue":false},{"level":"NOTICE","message":"fyi","stepNumber":2,"isInfrastructureIssue":false}]
    , json);
}

pub fn stepResultsJson(arena: Allocator, shown: []const Shown) ![]const u8 {
    const Item = struct {
        external_id: []const u8,
        number: u32,
        name: []const u8,
        status: []const u8,
        conclusion: []const u8,
        started_at: ?[]const u8,
        completed_at: ?[]const u8,
    };
    const items = try arena.alloc(Item, shown.len);
    for (items, shown) |*it, s| it.* = .{
        .external_id = s.id,
        .number = s.number,
        .name = s.name,
        .status = "completed",
        .conclusion = s.conclusion,
        .started_at = if (s.started_ms > 0) try timefmt.isoTime(arena, s.started_ms) else null,
        .completed_at = if (s.completed_ms > 0) try timefmt.isoTime(arena, s.completed_ms) else null,
    };
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

test "the steps GitHub shows: Set up job, pre, the job's steps, post, Complete job, numbered in order" {
    var a: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer a.deinit();
    const arena = a.allocator();
    const mk = struct {
        fn step(id: []const u8) job_mod.Step {
            return .{ .id = id, .name = id, .condition = "success()", .action = .{ .unsupported = "x" } };
        }
    };
    const steps = [_]job_mod.Step{ mk.step("a"), mk.step("b"), mk.step("c"), mk.step("d") };
    const job: job_mod.Job = .{ .plan_id = "p", .job_id = "j", .job_token = "t", .check_run_id = 1, .secrets = &.{}, .steps = &steps };
    var rs = [_]dagger.StepResult{
        .{ .outcome = .success, .started_ms = 1000, .completed_ms = 2000 },
        .{ .outcome = .failure, .exit_code = 5, .continued = true },
        .{ .outcome = .failure, .exit_code = 2 },
        .{ .outcome = .skipped },
    };
    const extra = [_]dagger.ExtraStep{
        .{ .kind = .pre, .name = "Pre a", .log_step = 5, .outcome = .success, .started_ms = 900, .completed_ms = 950 },
        .{ .kind = .post, .name = "Post a", .log_step = 6, .outcome = .failure, .started_ms = 3000, .completed_ms = 3100 },
    };
    const result: dagger.Result = .{ .steps = &rs, .engine_error = null, .succeeded = false, .extra = &extra, .next_log_step = 7 };
    const shown = try shownSteps(arena, std.testing.io, job, result, 500, .{ .log_step = 7, .started_ms = 3200, .completed_ms = 3300 });
    const names = [_][]const u8{ "Set up job", "Pre a", "a", "b", "c", "d", "Post a", "Complete job" };
    const logs = [_]u32{ 0, 5, 1, 2, 3, 4, 6, 7 };
    try std.testing.expectEqual(names.len, shown.len);
    for (shown, names, logs, 1..) |sh, name, ls, n| {
        try std.testing.expectEqualStrings(name, sh.name);
        try std.testing.expectEqual(ls, sh.log_step);
        try std.testing.expectEqual(@as(u32, @intCast(n)), sh.number);
    }
    // The added steps get ids of their own; the job's keep GitHub's.
    try std.testing.expectEqual(@as(usize, 36), shown[0].id.len);
    try std.testing.expectEqualStrings("a", shown[2].id);
    // "Set up job" runs from the job's start until the first step (here the pre).
    try std.testing.expectEqual(@as(i64, 500), shown[0].started_ms);
    try std.testing.expectEqual(@as(i64, 900), shown[0].completed_ms);
    const json = try stepResultsJson(arena, shown);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"external_id\":\"a\",\"number\":3,\"name\":\"a\",\"status\":\"completed\",\"conclusion\":\"succeeded\",\"started_at\":\"1970-01-01T00:00:01.000Z\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"name\":\"b\",\"status\":\"completed\",\"conclusion\":\"succeeded\"}") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"name\":\"c\",\"status\":\"completed\",\"conclusion\":\"failed\"}") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"name\":\"d\",\"status\":\"completed\",\"conclusion\":\"skipped\"}") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"number\":7,\"name\":\"Post a\",\"status\":\"completed\",\"conclusion\":\"failed\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"number\":8,\"name\":\"Complete job\"") != null);
}
