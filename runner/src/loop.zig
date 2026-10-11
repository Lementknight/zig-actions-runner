//! The runner's main flow (DESIGN §6): register a JIT runner, open a broker session, wait for one
//! job, acquire it, execute it through Dagger, report the result, and exit (ephemeral).
const std = @import("std");
const Config = @import("config.zig").Config;
const jitconfig = @import("github/jitconfig.zig");
const auth = @import("github/auth.zig");
const broker = @import("github/broker.zig");
const runservice = @import("github/runservice.zig");
const job_mod = @import("job.zig");
const dagger = @import("dagger.zig");
const results = @import("github/results.zig");
const sink = @import("sink.zig");
const redact = @import("redact.zig");
const timefmt = @import("timefmt.zig");

const Allocator = std.mem.Allocator;

/// SPEC §2 exit codes.
pub const Exit = enum(u8) { done = 0, config = 1, github = 2, db = 3 };

pub const Context = struct {
    arena: Allocator,
    io: std.Io,
    environ: *const std.process.Environ.Map,
    cfg: *const Config,
    log: *sink.LogSink,
    err: *std.Io.Writer,
    /// Config secrets; the job's own secrets are appended once it is acquired.
    secrets: []const []const u8,
    name: []const u8,
};

fn say(c: Context, comptime fmt: []const u8, args: anytype) !void {
    const text = try std.fmt.allocPrint(c.arena, fmt, args);
    try c.log.append(0, 0, .stderr, text);
}

/// Poll responses are 202 when idle. A fresh token is minted before the old one can expire.
const token_refresh_secs = 10 * 60;

pub fn run(c: Context) !Exit {
    var status: std.http.Status = .ok;
    const jit = jitconfig.generate(c.arena, c.io, c.cfg, c.name, &status) catch |e| {
        try c.err.writeAll("github error: ");
        try redact.write(c.err, @errorName(e), c.secrets);
        try c.err.print(" (HTTP {d})\n", .{@backingInt(status)});
        return .github;
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
    try say(c, "listening for jobs (labels: {s})", .{c.cfg.labels});

    while (true) {
        const now = std.Io.Clock.real.now(c.io).toSeconds();
        if (now - token_at > token_refresh_secs) {
            token = mintToken(c, creds, &status) catch |e| return failHttp(c, "oauth token refresh", e, status);
            token_at = now;
        }
        const m = broker.call(c.arena, c.io, .GET, try broker.messageUrl(c.arena, base, sid, "Online"), token, null) catch |e| return fail(c, "poll", e);
        if (m.status == .accepted or (m.status.class() == .success and m.body.len == 0)) continue;
        if (m.status.class() != .success) return failBody(c, "poll", m);

        const mtype = jsonString(c.arena, m.body, "messageType") orelse "";
        if (!std.mem.eql(u8, mtype, "RunnerJobRequest")) {
            try say(c, "ignoring message of type '{s}'", .{mtype});
            continue;
        }
        const inner = jsonString(c.arena, m.body, "body") orelse return fail(c, "job request", error.BadResponse);
        return handleJob(c, token, inner, settings.agent_name);
    }
}

fn handleJob(c: Context, runner_token: []const u8, inner_body: []const u8, runner_name: []const u8) !Exit {
    const jr = runservice.parseJobRequest(c.arena, inner_body) catch |e| return fail(c, "job request", e);
    const acq = runservice.acquire(c.arena, c.io, jr, runner_token) catch |e| return fail(c, "acquirejob", e);
    if (acq.status.class() != .success) return failBody(c, "acquirejob", acq);

    // The definition holds secrets; it is parsed but never printed.
    var job = job_mod.parse(c.arena, acq.body) catch |e| return fail(c, "parse job", e);
    job.runner_name = runner_name;
    // Everything the job logs is also kept (redacted, timestamped) so it can be uploaded to GitHub.
    var collect: sink.LogSink = .{ .collect = .{ .arena = c.arena, .io = c.io, .inner = c.log } };
    collect.setSecrets(try std.mem.concat(c.arena, []const u8, &.{ c.secrets, job.secrets }));
    const log = &collect;
    try log.append(job.check_run_id, 0, .stdout, try std.fmt.allocPrint(c.arena, "job acquired: {d} steps", .{job.steps.len}));
    if (job.run_id == null) try log.append(job.check_run_id, 0, .stderr, "job definition has no github.run_id; the job runs but no run, job or step rows are recorded");

    var result: dagger.Result = undefined;
    if (job.has_container) {
        const step_results = try c.arena.alloc(dagger.StepResult, job.steps.len);
        @memset(step_results, .{});
        try log.append(job.check_run_id, 0, .stderr, "container: jobs are not supported yet");
        result = .{ .steps = step_results, .engine_error = null, .succeeded = false };
    } else {
        result = try dagger.run(c.arena, c.io, c.environ, .{
            .argv = &.{ c.cfg.dagger_cmd, "--progress=logs", "query" },
            .sink_job_id = job.check_run_id,
        }, job, log);
        if (result.engine_error) |msg| {
            try log.append(job.check_run_id, 0, .stderr, "dagger failed before running the steps:");
            try log.append(job.check_run_id, 0, .stderr, msg);
        }
    }
    try log.flush();
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
    return if (result.succeeded) .done else .github;
}

/// Uploads each step's log, then the whole job's, so GitHub's UI can show them. Failures are reported
/// but never stop the job from completing.
fn uploadLogs(c: Context, job: job_mod.Job, lines: []const sink.CollectedLine) !void {
    for (job.steps, 1..) |step, n| {
        const blob = try results.formatBlob(c.arena, lines, @intCast(n));
        if (blob.line_count == 0) continue;
        const r = results.upload(c.arena, c.io, job, .{ .step = step.id }, blob);
        try c.err.print("log upload step {d}: {s}{s}\n", .{ n, if (r.ok) "ok, " else "FAILED: ", r.detail });
    }
    const all = try results.formatBlob(c.arena, lines, null);
    if (all.line_count > 0) {
        const r = results.upload(c.arena, c.io, job, .job, all);
        try c.err.print("log upload job: {s}{s}\n", .{ if (r.ok) "ok, " else "FAILED: ", r.detail });
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
            .name = step.name,
            .status = "completed",
            // Same vocabulary as the job conclusion (verified live): succeeded / failed / skipped.
            .conclusion = switch (r.outcome) {
                .success => "succeeded",
                .failure => if (step.continue_on_error) "succeeded" else "failed",
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

fn fail(c: Context, what: []const u8, e: anyerror) !Exit {
    try c.err.print("error during {s}: ", .{what});
    try redact.write(c.err, @errorName(e), c.secrets);
    try c.err.writeByte('\n');
    return .github;
}

fn failHttp(c: Context, what: []const u8, e: anyerror, status: std.http.Status) !Exit {
    try c.err.print("error during {s}: {s} (HTTP {d})\n", .{ what, @errorName(e), @backingInt(status) });
    return .github;
}

fn failBody(c: Context, what: []const u8, r: broker.Response) !Exit {
    // Error bodies are short JSON documents without credentials.
    try c.err.print("error during {s}: HTTP {d}: {s}\n", .{ what, @backingInt(r.status), r.body[0..@min(r.body.len, 400)] });
    return .github;
}

test "stepResultsJson maps outcomes and continue-on-error" {
    var a: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer a.deinit();
    const arena = a.allocator();
    const mk = struct {
        fn step(id: []const u8, coe: bool) job_mod.Step {
            return .{ .id = id, .name = id, .condition = "success()", .continue_on_error = coe, .env = &.{}, .action = .{ .unsupported = "x" } };
        }
    };
    const steps = [_]job_mod.Step{ mk.step("a", false), mk.step("b", true), mk.step("c", false), mk.step("d", false) };
    const job: job_mod.Job = .{ .plan_id = "p", .job_id = "j", .job_token = "t", .check_run_id = 1, .has_container = false, .secrets = &.{}, .steps = &steps };
    var rs = [_]dagger.StepResult{
        .{ .outcome = .success, .started_ms = 1000, .completed_ms = 2000 },
        .{ .outcome = .failure, .exit_code = 5 },
        .{ .outcome = .failure, .exit_code = 2 },
        .{ .outcome = .skipped },
    };
    const json = try stepResultsJson(arena, job, .{ .steps = &rs, .engine_error = null, .succeeded = false });
    try std.testing.expect(std.mem.indexOf(u8, json, "\"external_id\":\"a\",\"number\":1,\"name\":\"a\",\"status\":\"completed\",\"conclusion\":\"succeeded\",\"started_at\":\"1970-01-01T00:00:01.000Z\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"name\":\"b\",\"status\":\"completed\",\"conclusion\":\"succeeded\"}") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"name\":\"c\",\"status\":\"completed\",\"conclusion\":\"failed\"}") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"name\":\"d\",\"status\":\"completed\",\"conclusion\":\"skipped\"}") != null);
}
