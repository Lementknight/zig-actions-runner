//! Runs a job's steps through Dagger (DESIGN §4, SPEC §6).
//!
//! One long-lived Dagger session hosts the whole job: the runner starts `dagger run`, which runs a
//! tiny child that prints the session's port and token and then waits. The runner then speaks
//! GraphQL to that session over HTTP (as the Dagger SDKs do), one query per step, threading the
//! container through by id. Container ids only live as long as the session, which is why this is
//! not one `dagger query` per step.
//!
//! Compared to a single query for the whole job this lets the runner decide what to run next from
//! earlier results (conditions, expressions, step outputs), and `withExec(expect: ANY)` returns the
//! real exit code and separate stdout/stderr, even for steps served from Dagger's cache.
//!
//! Live output comes from `dagger run`'s progress log on stderr, read by a reader task. Each step's
//! script brackets its output with marker lines so lines can be attributed to the step:
//!
//!     <marker>begin N      <marker>end N
//!
//! Dagger's log frontend may repeat a span's header when it switches spans, so lines are attributed
//! to the step named in the most recent span header (a single line that contains the step's `begin`
//! marker text), not simply the last `begin`. A step served
//! from cache prints no log lines at all; its stdout/stderr from the query result are replayed.
const std = @import("std");
const job_mod = @import("job.zig");
const sink = @import("sink.zig");
const broker = @import("github/broker.zig");
const expr = @import("expr.zig");
const context = @import("context.zig");
const commands = @import("commands.zig");

const Allocator = std.mem.Allocator;

pub const default_image = "ubuntu:24.04";
pub const workspace = "/github/workspace";
pub const marker = "::zig-step::";

pub const Marker = union(enum) {
    begin: u32,
    end: u32,
};

pub const Scan = struct {
    /// Step output that preceded the marker on the same line (output without a trailing newline).
    before: []const u8,
    marker: Marker,
};

/// Finds a marker anywhere in `line`. Returns null for ordinary output.
pub fn scan(line: []const u8) ?Scan {
    const i = std.mem.indexOf(u8, line, marker) orelse return null;
    var it = std.mem.tokenizeScalar(u8, line[i + marker.len ..], ' ');
    const kind = it.next() orelse return null;
    const step = std.fmt.parseInt(u32, it.next() orelse return null, 10) catch return null;
    const m: Marker = if (std.mem.eql(u8, kind, "begin"))
        .{ .begin = step }
    else if (std.mem.eql(u8, kind, "end"))
        .{ .end = step }
    else
        return null;
    return .{ .before = line[0..i], .marker = m };
}

/// Dagger prefixes span headers with a block glyph (U+25xx, e.g. "▼", "▋").
fn isSpanHeader(line: []const u8) bool {
    return line.len >= 4 and line[0] == 0xE2 and line[1] == 0x96;
}

/// Step number from a script line such as `echo '::zig-step::begin 2'`.
fn headerStep(line: []const u8) ?u32 {
    const i = std.mem.indexOf(u8, line, marker ++ "begin ") orelse return null;
    const rest = line[i + marker.len + "begin ".len ..];
    var n: usize = 0;
    while (n < rest.len and std.ascii.isDigit(rest[n])) n += 1;
    if (n == 0) return null;
    return std.fmt.parseInt(u32, rest[0..n], 10) catch null;
}

fn shellQuote(w: *std.Io.Writer, s: []const u8) !void {
    try w.writeByte('\'');
    for (s) |c| {
        if (c == '\'') try w.writeAll("'\\''") else try w.writeByte(c);
    }
    try w.writeByte('\'');
}

/// Evaluates an `if:` condition. Null when v0 cannot evaluate it. `job_failed` is true once a step
/// failed without continue-on-error.
pub fn evalCondition(cond: []const u8, job_failed: bool) ?bool {
    const c = std.mem.trim(u8, cond, " ");
    if (std.mem.eql(u8, c, "success()")) return !job_failed;
    if (std.mem.eql(u8, c, "always()")) return true;
    if (std.mem.eql(u8, c, "failure()")) return job_failed;
    if (std.mem.eql(u8, c, "cancelled()")) return false;
    return null;
}

/// A checkout step after its repository was fetched, or failed to be.
pub const Fetched = struct {
    /// Dagger Directory id of the fetched tree, or why it could not be fetched.
    result: union(enum) { dir: []const u8, failed: []const u8 },
    repo: []const u8,
    /// What was checked out, for the log (a short sha or the requested ref).
    ref_label: []const u8,
    /// Absolute directory inside the container.
    mount: []const u8,
};

/// A step with its expressions evaluated, ready to become a script.
pub const Resolved = union(enum) {
    run: struct {
        script: []const u8,
        /// `bash`, `sh`, or null for the default.
        shell: ?[]const u8,
        working_directory: ?[]const u8,
        env: []const job_mod.EnvVar,
    },
    checkout: Fetched,
};

const fc_dir = "/github/file_commands";
const fc_kinds = [_][]const u8{ "output", "env", "path", "step_summary" };

fn fcPath(arena: Allocator, kind: []const u8, n: u32) ![]const u8 {
    return std.fmt.allocPrint(arena, "{s}/{s}_{d}", .{ fc_dir, kind, n });
}

/// The `sh -c` script of step number `n` (1-based). Its exit code is the step's.
///
/// The script creates the step's file commands first and touches them again afterwards, so the
/// query can always read them even if the step deleted them. A `run:` step sees them as
/// `$GITHUB_OUTPUT`, `$GITHUB_ENV`, `$GITHUB_PATH` and `$GITHUB_STEP_SUMMARY`.
pub fn stepScript(arena: Allocator, n: u32, r: Resolved, action_name: []const u8) ![]const u8 {
    var aw: std.Io.Writer.Allocating = .init(arena);
    const w = &aw.writer;
    try w.print("echo '{s}begin {d}'\nmkdir -p " ++ fc_dir ++ " && : ", .{ marker, n });
    for (fc_kinds) |k| try w.print("> {s} ", .{try fcPath(arena, k, n)});
    try w.writeByte('\n');
    switch (r) {
        .run => |sc| {
            try w.writeAll("( ");
            if (sc.working_directory) |wd| {
                try w.writeAll("cd ");
                try shellQuote(w, wd);
                try w.writeAll(" && ");
            }
            try w.writeAll("env ");
            for (sc.env) |e| {
                const pair = try std.fmt.allocPrint(arena, "{s}={s}", .{ e.name, e.value });
                try shellQuote(w, pair);
                try w.writeByte(' ');
            }
            // Set after the step's own env, so a step cannot point these somewhere else.
            const names = [_][]const u8{ "GITHUB_OUTPUT", "GITHUB_ENV", "GITHUB_PATH", "GITHUB_STEP_SUMMARY" };
            for (names, fc_kinds) |name, kind| {
                try shellQuote(w, try std.fmt.allocPrint(arena, "{s}={s}", .{ name, try fcPath(arena, kind, n) }));
                try w.writeByte(' ');
            }
            try shellQuote(w, try std.fmt.allocPrint(arena, "GITHUB_ACTION={s}", .{action_name}));
            try w.writeByte(' ');
            if (sc.shell != null and std.mem.eql(u8, sc.shell.?, "sh")) {
                try w.writeAll("sh -e -c ");
            } else {
                try w.writeAll("bash --noprofile --norc -e -o pipefail -c ");
            }
            try shellQuote(w, sc.script);
            try w.writeAll(" )\nrc=$?\n");
        },
        .checkout => |f| {
            // The tree is mounted by the query (`withDirectory`); the step only reports it.
            try w.writeAll("printf '%s\\n' ");
            try shellQuote(w, try std.fmt.allocPrint(arena, "Syncing repository: {s}", .{f.repo}));
            try w.writeAll("\nprintf '%s\\n' ");
            try shellQuote(w, try std.fmt.allocPrint(arena, "Checked out {s} into {s} (the runner's built-in checkout replaces actions/checkout)", .{ f.ref_label, f.mount }));
            try w.writeAll("\nrc=0\n");
        },
    }
    try w.writeAll("mkdir -p " ++ fc_dir ++ " && : ");
    for (fc_kinds) |k| try w.print(">> {s} ", .{try fcPath(arena, k, n)});
    try w.print("\necho '{s}end {d}'\nexit $rc\n", .{ marker, n });
    return aw.written();
}

pub const Outcome = enum { not_run, success, failure, skipped };

pub const StepResult = struct {
    /// The step's display name with expressions evaluated; empty when it was never evaluated.
    name: []const u8 = "",
    /// Whether `continue-on-error` applied (evaluated), so a failure does not fail the job.
    continued: bool = false,
    outcome: Outcome = .not_run,
    exit_code: i32 = 0,
    started_ms: i64 = 0,
    completed_ms: i64 = 0,
};

pub const Result = struct {
    steps: []StepResult,
    /// Set when the engine itself failed (pull error, session lost): what Dagger said.
    engine_error: ?[]const u8,
    /// False if any step failed without continue-on-error, or the engine failed before running them.
    succeeded: bool,
};

/// Sends one GraphQL document to the Dagger session and returns the response body.
pub const Transport = struct {
    ptr: *anyopaque,
    sendFn: *const fn (ptr: *anyopaque, arena: Allocator, doc: []const u8) anyerror![]const u8,

    fn send(t: Transport, arena: Allocator, doc: []const u8) ![]const u8 {
        return t.sendFn(t.ptr, arena, doc);
    }
};

pub const Options = struct {
    /// The `dagger` command.
    dagger_cmd: []const u8 = "dagger",
    image: []const u8 = default_image,
    /// Key under which output lines are written to the sink.
    sink_job_id: u64 = 0,
    /// Tests only: replaces `dagger run ...` (it must print "<port> <token>" first) and the HTTP transport.
    test_session_argv: ?[]const []const u8 = null,
    test_transport: ?Transport = null,
};

// --- the HTTP transport to the session ---

const HttpTransport = struct {
    io: std.Io,
    url: []const u8,
    auth: []const u8,

    fn send(ptr: *anyopaque, arena: Allocator, doc: []const u8) anyerror![]const u8 {
        const self: *HttpTransport = @ptrCast(@alignCast(ptr));
        var body: std.Io.Writer.Allocating = .init(arena);
        try body.writer.writeAll("{\"query\":");
        try std.json.Stringify.value(doc, .{}, &body.writer);
        try body.writer.writeByte('}');
        const r = try broker.request(arena, self.io, .POST, self.url, body.written(), .{
            .extra_headers = &.{.{ .name = "Authorization", .value = self.auth }},
        });
        // GraphQL errors can arrive with a non-2xx status; the body says what was wrong.
        if (r.status.class() != .success and r.body.len == 0) return error.DaggerSessionHttpError;
        return r.body;
    }
};

fn jsonFind(v: std.json.Value, key: []const u8) ?std.json.Value {
    if (v != .object) return null;
    var it = v.object.iterator();
    while (it.next()) |e| {
        if (std.mem.eql(u8, e.key_ptr.*, key)) return e.value_ptr.*;
        if (jsonFind(e.value_ptr.*, key)) |f| return f;
    }
    return null;
}

fn jsonFindString(v: std.json.Value, key: []const u8) ?[]const u8 {
    const f = jsonFind(v, key) orelse return null;
    return if (f == .string) f.string else null;
}

/// Runs a document and returns the parsed `data`, or the first GraphQL error message.
fn gql(arena: Allocator, t: Transport, doc: []const u8, err_msg: *[]const u8) !std.json.Value {
    const body = t.send(arena, doc) catch |e| {
        err_msg.* = try std.fmt.allocPrint(arena, "could not reach the Dagger session: {s}", .{@errorName(e)});
        return error.DaggerQueryFailed;
    };
    const root = std.json.parseFromSliceLeaky(std.json.Value, arena, body, .{}) catch {
        err_msg.* = "Dagger returned a response that is not JSON";
        return error.DaggerQueryFailed;
    };
    if (root == .object) {
        if (root.object.get("errors")) |errs| if (errs == .array and errs.array.items.len > 0) {
            err_msg.* = jsonFindString(errs.array.items[0], "message") orelse "Dagger returned an error";
            return error.DaggerQueryFailed;
        };
        if (root.object.get("data")) |d| return d;
    }
    err_msg.* = "Dagger returned no data";
    return error.DaggerQueryFailed;
}

// --- checkout resolution ---

fn isSha(s: []const u8) bool {
    if (s.len != 40) return false;
    for (s) |c| if (!std.ascii.isHex(c)) return false;
    return true;
}

/// The query that resolves a checkout to a Directory id, or null with a reason.
pub fn checkoutQuery(arena: Allocator, job: job_mod.Job, co: job_mod.Checkout) !union(enum) { doc: []const u8, err: []const u8 } {
    const repo = co.repository orelse job.github.repository;
    if (repo.len == 0) return .{ .err = "no repository to check out (the job has no github.repository)" };
    const own = co.repository == null or std.mem.eql(u8, repo, job.github.repository);
    const url = try std.fmt.allocPrint(arena, "{s}/{s}.git", .{ std.mem.trimEnd(u8, job.github.server_url, "/"), repo });

    var aw: std.Io.Writer.Allocating = .init(arena);
    const w = &aw.writer;
    try w.writeAll("{ git(url:");
    try std.json.Stringify.value(url, .{}, w);
    try w.writeAll(",keepGitDir:true) { ");
    if (co.ref orelse (if (own and job.github.sha.len > 0) job.github.sha else null)) |ref| {
        if (isSha(ref)) {
            try w.writeAll("commit(id:");
        } else {
            try w.writeAll("ref(name:");
        }
        try std.json.Stringify.value(ref, .{}, w);
        try w.writeAll(")");
    } else {
        try w.writeAll("head");
    }
    if (co.fetch_depth == 0) try w.writeAll(" { tree { id } } } }") else try w.print(" {{ tree(depth:{d}) {{ id }} }} }} }}", .{co.fetch_depth});
    return .{ .doc = aw.written() };
}

fn looksLikeAuthFailure(text: []const u8) bool {
    const needles = [_][]const u8{ "not found", "authentication", "Authentication", "denied", "403", "401", "could not read Username" };
    for (needles) |n| if (std.mem.indexOf(u8, text, n) != null) return true;
    return false;
}

fn fetchCheckout(arena: Allocator, t: Transport, job: job_mod.Job, co: job_mod.Checkout) !Fetched {
    const repo = co.repository orelse job.github.repository;
    const mount = if (co.path) |pth|
        try std.fmt.allocPrint(arena, "{s}/{s}", .{ workspace, std.mem.trim(u8, pth, "/") })
    else
        workspace;
    const want = co.ref orelse (if (co.repository == null) job.github.sha else "HEAD");
    const label = if (isSha(want)) want[0..7] else want;
    var f: Fetched = .{ .result = .{ .failed = "" }, .repo = repo, .ref_label = label, .mount = mount };

    const doc = switch (try checkoutQuery(arena, job, co)) {
        .err => |msg| {
            f.result = .{ .failed = msg };
            return f;
        },
        .doc => |d| d,
    };
    var msg: []const u8 = "";
    if (gql(arena, t, doc, &msg)) |data| {
        if (jsonFindString(data, "id")) |id| {
            f.result = .{ .dir = id };
            return f;
        }
        msg = "Dagger returned no tree";
    } else |_| {}
    f.result = .{ .failed = try std.fmt.allocPrint(arena, "could not fetch {s}@{s}: {s}{s}", .{
        repo, label, msg, if (looksLikeAuthFailure(msg)) " (private repositories are not supported in v0)" else "",
    }) };
    return f;
}

// --- expression evaluation ---

const StepCtx = struct { id: []const u8, outcome: []const u8, conclusion: []const u8, outputs: []const job_mod.EnvVar };

/// Holds what expressions can see while a job runs and evaluates the templates of each step.
const Evaluator = struct {
    arena: Allocator,
    job: *const job_mod.Job,
    /// github, inputs, matrix, needs, strategy, vars from the job's contextData.
    github: expr.Value,
    inputs: expr.Value,
    matrix: expr.Value,
    needs: expr.Value,
    strategy: expr.Value,
    vars: expr.Value,
    job_context: expr.Value,
    /// Workflow- and job-level env, evaluated once.
    job_env: std.ArrayList(job_mod.EnvVar) = .empty,
    steps: std.ArrayList(StepCtx) = .empty,
    /// Changes a step made through $GITHUB_ENV / $GITHUB_PATH, applied to the container before the next step.
    pending_env: std.ArrayList(job_mod.EnvVar) = .empty,
    pending_path: std.ArrayList([]const u8) = .empty,
    job_failed: bool = false,
    diag: []const u8 = "",

    fn init(arena: Allocator, job: *const job_mod.Job) !Evaluator {
        var ev: Evaluator = .{
            .arena = arena,
            .job = job,
            .github = try context.named(arena, job.context_data, "github"),
            .inputs = try context.named(arena, job.context_data, "inputs"),
            .matrix = try context.named(arena, job.context_data, "matrix"),
            .needs = try context.named(arena, job.context_data, "needs"),
            .strategy = try context.named(arena, job.context_data, "strategy"),
            .vars = try context.named(arena, job.context_data, "vars"),
            .job_context = try context.named(arena, job.context_data, "job"),
        };
        for (job.env) |in| {
            const sc = try ev.scope(&.{});
            const val = ev.render(in.value, sc) catch continue; // an env value that cannot be evaluated stays unset
            try putEnv(arena, &ev.job_env, in.name, val);
        }
        return ev;
    }

    fn putEnv(arena: Allocator, list: *std.ArrayList(job_mod.EnvVar), name: []const u8, value: []const u8) !void {
        for (list.items) |*e| if (std.mem.eql(u8, e.name, name)) {
            e.value = value;
            return;
        };
        try list.append(arena, .{ .name = name, .value = value });
    }

    /// The scope for evaluating one step: `step_env` is applied on top of the job's env.
    fn scope(ev: *Evaluator, step_env: []const job_mod.EnvVar) !expr.Scope {
        const arena = ev.arena;
        var env_list: std.ArrayList(job_mod.EnvVar) = .empty;
        try env_list.appendSlice(arena, ev.job_env.items);
        for (step_env) |e| try putEnv(arena, &env_list, e.name, e.value);
        const env_entries = try arena.alloc(expr.Value.Entry, env_list.items.len);
        for (env_list.items, env_entries) |e, *o| o.* = .{ .key = e.name, .value = .{ .string = e.value } };

        const step_entries = try arena.alloc(expr.Value.Entry, ev.steps.items.len);
        for (ev.steps.items, step_entries) |sc, *o| {
            const outs = try arena.alloc(expr.Value.Entry, sc.outputs.len);
            for (sc.outputs, outs) |ov, *oo| oo.* = .{ .key = ov.name, .value = .{ .string = ov.value } };
            const fields = try arena.alloc(expr.Value.Entry, 3);
            fields[0] = .{ .key = "outputs", .value = .{ .object = outs } };
            fields[1] = .{ .key = "outcome", .value = .{ .string = sc.outcome } };
            fields[2] = .{ .key = "conclusion", .value = .{ .string = sc.conclusion } };
            o.* = .{ .key = sc.id, .value = .{ .object = fields } };
        }

        const job_fields = try arena.alloc(expr.Value.Entry, 1);
        job_fields[0] = .{ .key = "status", .value = .{ .string = if (ev.job_failed) "failure" else "success" } };
        const runner_fields = try arena.alloc(expr.Value.Entry, 5);
        runner_fields[0] = .{ .key = "os", .value = .{ .string = "Linux" } };
        runner_fields[1] = .{ .key = "arch", .value = .{ .string = "X64" } };
        runner_fields[2] = .{ .key = "name", .value = .{ .string = "zig-runner" } };
        runner_fields[3] = .{ .key = "temp", .value = .{ .string = "/tmp" } };
        runner_fields[4] = .{ .key = "tool_cache", .value = .{ .string = "/opt/hostedtoolcache" } };

        const ctxs = try arena.alloc(expr.Value.Entry, 10);
        ctxs[0] = .{ .key = "github", .value = ev.github };
        ctxs[1] = .{ .key = "env", .value = .{ .object = env_entries } };
        ctxs[2] = .{ .key = "steps", .value = .{ .object = step_entries } };
        ctxs[3] = .{ .key = "job", .value = .{ .object = job_fields } };
        ctxs[4] = .{ .key = "runner", .value = .{ .object = runner_fields } };
        ctxs[5] = .{ .key = "inputs", .value = ev.inputs };
        ctxs[6] = .{ .key = "matrix", .value = ev.matrix };
        ctxs[7] = .{ .key = "needs", .value = ev.needs };
        ctxs[8] = .{ .key = "strategy", .value = ev.strategy };
        ctxs[9] = .{ .key = "vars", .value = ev.vars };
        return .{
            .contexts = ctxs,
            .job_failed = ev.job_failed,
            .unsupported_contexts = &.{"secrets"},
            .diag = &ev.diag,
        };
    }

    fn render(ev: *Evaluator, t: job_mod.Template, sc: expr.Scope) ![]const u8 {
        return switch (t) {
            .lit => |l| l,
            .expr => |e| expr.evalString(ev.arena, e, sc),
        };
    }

    fn renderEnv(ev: *Evaluator, inputs: []const job_mod.Input, sc: expr.Scope) ![]const job_mod.EnvVar {
        const out = try ev.arena.alloc(job_mod.EnvVar, inputs.len);
        for (inputs, out) |in, *o| o.* = .{ .name = in.name, .value = try ev.render(in.value, sc) };
        return out;
    }

    fn record(ev: *Evaluator, step: job_mod.Step, outcome: Outcome, continued: bool, outputs: []const job_mod.EnvVar) !void {
        const raw: []const u8 = switch (outcome) {
            .success => "success",
            .failure => "failure",
            .skipped, .not_run => "skipped",
        };
        const conclusion: []const u8 = if (outcome == .failure and continued) "success" else raw;
        try ev.steps.append(ev.arena, .{ .id = if (step.context_name.len > 0) step.context_name else step.id, .outcome = raw, .conclusion = conclusion, .outputs = outputs });
    }

    /// A string from the `github` context ("" when absent).
    fn githubString(ev: *const Evaluator, key: []const u8) []const u8 {
        if (ev.github != .object) return "";
        for (ev.github.object) |e| if (std.ascii.eqlIgnoreCase(e.key, key)) return switch (e.value) {
            .string => |str| str,
            else => "",
        };
        return "";
    }

    /// The variables every step sees, as on a GitHub-hosted runner.
    fn defaultEnv(ev: *const Evaluator) ![]const job_mod.EnvVar {
        var out: std.ArrayList(job_mod.EnvVar) = .empty;
        const fixed = [_]job_mod.EnvVar{
            .{ .name = "CI", .value = "true" },
            .{ .name = "GITHUB_ACTIONS", .value = "true" },
            .{ .name = "GITHUB_WORKSPACE", .value = workspace },
            .{ .name = "RUNNER_OS", .value = "Linux" },
            .{ .name = "RUNNER_ARCH", .value = "X64" },
            .{ .name = "RUNNER_NAME", .value = "zig-runner" },
            .{ .name = "RUNNER_TEMP", .value = "/tmp" },
            .{ .name = "RUNNER_TOOL_CACHE", .value = "/opt/hostedtoolcache" },
        };
        try out.appendSlice(ev.arena, &fixed);
        const from_github = [_][2][]const u8{
            .{ "GITHUB_REPOSITORY", "repository" },
            .{ "GITHUB_REPOSITORY_OWNER", "repository_owner" },
            .{ "GITHUB_SHA", "sha" },
            .{ "GITHUB_REF", "ref" },
            .{ "GITHUB_REF_NAME", "ref_name" },
            .{ "GITHUB_REF_TYPE", "ref_type" },
            .{ "GITHUB_EVENT_NAME", "event_name" },
            .{ "GITHUB_ACTOR", "actor" },
            .{ "GITHUB_TRIGGERING_ACTOR", "triggering_actor" },
            .{ "GITHUB_RUN_ID", "run_id" },
            .{ "GITHUB_RUN_NUMBER", "run_number" },
            .{ "GITHUB_RUN_ATTEMPT", "run_attempt" },
            .{ "GITHUB_JOB", "job" },
            .{ "GITHUB_WORKFLOW", "workflow" },
            .{ "GITHUB_BASE_REF", "base_ref" },
            .{ "GITHUB_HEAD_REF", "head_ref" },
            .{ "GITHUB_SERVER_URL", "server_url" },
            .{ "GITHUB_API_URL", "api_url" },
            .{ "GITHUB_GRAPHQL_URL", "graphql_url" },
        };
        for (from_github) |m| {
            const v = ev.githubString(m[1]);
            if (v.len > 0) try out.append(ev.arena, .{ .name = m[0], .value = v });
        }
        return out.items;
    }
};

// --- the log reader ---

/// Shared between the main task (which runs queries) and the reader task (which streams logs).
const Shared = struct {
    io: std.Io,
    arena: Allocator,
    log: *sink.LogSink,
    sink_job_id: u64,
    mu: std.Io.Mutex = .init,
    /// Lines streamed live per step (index = step - 1) and whether the step's `end` marker was seen.
    live_lines: []std.atomic.Value(u32),
    ended: []std.atomic.Value(bool),
    /// Dagger's own progress lines outside any step (guarded by `mu`), kept for engine errors.
    tail: [20][]const u8 = undefined,
    tail_len: usize = 0,
    /// Lines replayed from a query result whose live copy may still arrive late (guarded by `mu`).
    /// Key is "<step>:<text>"; the value is how many live copies to swallow.
    replayed: std.StringHashMapUnmanaged(u32) = .empty,

    fn append(sh: *Shared, step: u32, text: []const u8) void {
        sh.mu.lockUncancelable(sh.io);
        defer sh.mu.unlock(sh.io);
        sh.log.append(sh.sink_job_id, step, .stdout, text) catch {};
    }

    fn flush(sh: *Shared) void {
        sh.mu.lockUncancelable(sh.io);
        defer sh.mu.unlock(sh.io);
        sh.log.flush() catch {};
    }

    fn emitLive(sh: *Shared, step: u32, text: []const u8) void {
        if (step >= 1 and step <= sh.live_lines.len) _ = sh.live_lines[step - 1].fetchAdd(1, .monotonic);
        if (sh.swallowIfReplayed(step, text)) return;
        sh.append(step, text);
    }

    /// True if this live line was already logged by a replay (the stream was just late).
    fn swallowIfReplayed(sh: *Shared, step: u32, text: []const u8) bool {
        sh.mu.lockUncancelable(sh.io);
        defer sh.mu.unlock(sh.io);
        if (sh.replayed.count() == 0) return false;
        var key_buf: [512]u8 = undefined;
        const key = std.fmt.bufPrint(&key_buf, "{d}:{s}", .{ step, text }) catch return false;
        const entry = sh.replayed.getPtr(key) orelse return false;
        if (entry.* > 1) entry.* -= 1 else _ = sh.replayed.remove(key);
        return true;
    }

    /// Logs a line taken from a query result and remembers it so a late live copy is dropped.
    fn replay(sh: *Shared, step: u32, text: []const u8) void {
        {
            sh.mu.lockUncancelable(sh.io);
            defer sh.mu.unlock(sh.io);
            if (std.fmt.allocPrint(sh.arena, "{d}:{s}", .{ step, text })) |key| {
                const gop = sh.replayed.getOrPut(sh.arena, key) catch null;
                if (gop) |g| {
                    if (!g.found_existing) g.value_ptr.* = 0;
                    g.value_ptr.* += 1;
                }
            } else |_| {}
        }
        sh.append(step, text);
    }

    fn noise(sh: *Shared, line: []const u8) void {
        sh.mu.lockUncancelable(sh.io);
        defer sh.mu.unlock(sh.io);
        if (sh.tail_len == sh.tail.len) {
            std.mem.copyForwards([]const u8, sh.tail[0 .. sh.tail.len - 1], sh.tail[1..]);
            sh.tail_len -= 1;
        }
        sh.tail[sh.tail_len] = sh.arena.dupe(u8, line) catch return;
        sh.tail_len += 1;
    }
};

/// Splits Dagger's log stream into per-step output.
const Demux = struct {
    sh: *Shared,
    span_step: ?u32 = null,

    fn feed(d: *Demux, line: []const u8) void {
        // Span headers are one line (the script's newlines are escaped) and name the step.
        if (isSpanHeader(line)) {
            d.span_step = headerStep(line);
            return;
        }
        if (scan(line)) |sc| {
            if (d.span_step) |c| if (sc.before.len > 0) d.sh.emitLive(c, sc.before);
            switch (sc.marker) {
                .begin => |n| d.span_step = n,
                .end => |n| {
                    if (n >= 1 and n <= d.sh.ended.len) d.sh.ended[n - 1].store(true, .release);
                    d.sh.flush();
                    d.span_step = null;
                },
            }
        } else if (d.span_step) |c| {
            d.sh.emitLive(c, line);
        } else if (line.len > 0) {
            d.sh.noise(line);
        }
    }
};

fn readLogs(io: std.Io, sh: *Shared, file: std.Io.File) void {
    var demux: Demux = .{ .sh = sh };
    var rbuf: [64 * 1024]u8 = undefined;
    var fr = file.readerStreaming(io, &rbuf);
    const r = &fr.interface;
    while (true) {
        const raw = r.takeDelimiter('\n') catch |e| switch (e) {
            error.StreamTooLong => {
                _ = r.discardDelimiterInclusive('\n') catch return;
                continue;
            },
            error.ReadFailed => return,
        } orelse return;
        demux.feed(std.mem.trimEnd(u8, raw, "\r"));
    }
}

// --- running a job ---

/// Prints the session's port and token for the runner, then waits for stdin to close.
const session_script = "printf '%s %s\\n' \"$DAGGER_SESSION_PORT\" \"$DAGGER_SESSION_TOKEN\"; cat >/dev/null";

fn base64Encode(arena: Allocator, s: []const u8) ![]const u8 {
    const enc = std.base64.standard.Encoder;
    const buf = try arena.alloc(u8, enc.calcSize(s.len));
    return enc.encode(buf, s);
}

pub fn run(
    arena: Allocator,
    io: std.Io,
    environ: *const std.process.Environ.Map,
    opts: Options,
    job: job_mod.Job,
    log: *sink.LogSink,
) !Result {
    var env = try environ.clone(arena);
    try env.put("NO_COLOR", "1");
    try env.put("DAGGER_NO_NAG", "1");
    try env.put("GIT_TERMINAL_PROMPT", "0");

    const results = try arena.alloc(StepResult, job.steps.len);
    @memset(results, .{});
    const live = try arena.alloc(std.atomic.Value(u32), job.steps.len);
    const ended = try arena.alloc(std.atomic.Value(bool), job.steps.len);
    for (live, ended) |*l, *e| {
        l.* = .init(0);
        e.* = .init(false);
    }
    var sh: Shared = .{ .io = io, .arena = arena, .log = log, .sink_job_id = opts.sink_job_id, .live_lines = live, .ended = ended };

    const argv: []const []const u8 = opts.test_session_argv orelse &.{ opts.dagger_cmd, "run", "--progress=logs", "sh", "-c", session_script };
    var child = try std.process.spawn(io, .{ .argv = argv, .environ_map = &env, .stdin = .pipe, .stdout = .pipe, .stderr = .pipe });
    // The reader must run while we wait on queries.
    var reader = io.concurrent(readLogs, .{ io, &sh, child.stderr.? }) catch |e| {
        child.kill(io);
        return e;
    };
    // Order matters: closing stdin ends the session child and `dagger run`, which gives the reader EOF.
    defer {
        if (child.stdin) |f| f.close(io);
        child.stdin = null;
        _ = child.wait(io) catch {};
        reader.await(io);
    }

    // First line of the child's stdout: "<port> <token>".
    var first: [512]u8 = undefined;
    var out_reader = child.stdout.?.readerStreaming(io, &first);
    const line = (out_reader.interface.takeDelimiter('\n') catch null) orelse {
        return fail(&sh, results, "could not start a Dagger session (is the Docker daemon running?)");
    };
    var parts = std.mem.tokenizeScalar(u8, line, ' ');
    const port = parts.next() orelse return fail(&sh, results, "Dagger session did not report a port");
    const token = parts.next() orelse return fail(&sh, results, "Dagger session did not report a token");

    var http: HttpTransport = .{
        .io = io,
        .url = try std.fmt.allocPrint(arena, "http://127.0.0.1:{s}/query", .{port}),
        .auth = try std.fmt.allocPrint(arena, "Basic {s}", .{try base64Encode(arena, try std.fmt.allocPrint(arena, "{s}:", .{token}))}),
    };
    const transport: Transport = opts.test_transport orelse .{ .ptr = &http, .sendFn = HttpTransport.send };

    var ev = try Evaluator.init(arena, &job);
    var err_msg: []const u8 = "";
    var container_id: []const u8 = blk: {
        var doc: std.Io.Writer.Allocating = .init(arena);
        const w = &doc.writer;
        try w.writeAll("{ container { from(address:");
        try std.json.Stringify.value(opts.image, .{}, w);
        try w.print(") {{ withWorkdir(path:\"{s}\") {{ ", .{workspace});
        const defaults = try ev.defaultEnv();
        for (defaults) |e| {
            try w.writeAll("withEnvVariable(name:");
            try std.json.Stringify.value(e.name, .{}, w);
            try w.writeAll(",value:");
            try std.json.Stringify.value(e.value, .{}, w);
            try w.writeAll(") { ");
        }
        try w.writeAll("id");
        for (0..defaults.len + 4) |_| try w.writeAll(" }");
        const data = gql(arena, transport, doc.written(), &err_msg) catch return fail(&sh, results, err_msg);
        break :blk jsonFindString(data, "id") orelse return fail(&sh, results, "Dagger returned no container");
    };

    for (job.steps, results, 1..) |step, *res, n| {
        const num: u32 = @intCast(n);
        res.name = step.name;

        // 1. The condition, with the job env visible.
        ev.diag = "";
        const sc0 = try ev.scope(&.{});
        if (step.name_expr) |ne| res.name = expr.evalString(arena, ne, sc0) catch step.name;
        const should_run = expr.evalCondition(arena, step.condition, sc0) catch {
            try failStep(&ev, &sh, step, res, num, try std.fmt.allocPrint(arena, "could not evaluate the condition '{s}': {s}", .{ step.condition, ev.diag }), false);
            continue;
        };
        if (!should_run) {
            res.outcome = .skipped;
            try ev.record(step, .skipped, false, &.{});
            continue;
        }

        // 2. Step env and continue-on-error, then the step's own inputs.
        const step_env = ev.renderEnv(step.env, sc0) catch {
            try failStep(&ev, &sh, step, res, num, try std.fmt.allocPrint(arena, "could not evaluate env: {s}", .{ev.diag}), false);
            continue;
        };
        const sc1 = try ev.scope(step_env);
        const coe = std.mem.eql(u8, ev.render(step.continue_on_error, sc1) catch "false", "true");
        res.continued = coe;

        var resolved: Resolved = undefined;
        var fetched: ?Fetched = null;
        switch (step.action) {
            .unsupported => |why| {
                try failStep(&ev, &sh, step, res, num, why, coe);
                continue;
            },
            .script => |sc| {
                const script = ev.render(sc.script, sc1) catch {
                    try failStep(&ev, &sh, step, res, num, try std.fmt.allocPrint(arena, "could not evaluate the script: {s}", .{ev.diag}), coe);
                    continue;
                };
                const shell: ?[]const u8 = if (sc.shell) |t| (ev.render(t, sc1) catch null) else null;
                if (shell) |sh_name| if (!job_mod.validShell(sh_name)) {
                    try failStep(&ev, &sh, step, res, num, try std.fmt.allocPrint(arena, "unsupported shell '{s}' (v0 supports bash and sh)", .{sh_name}), coe);
                    continue;
                };
                const wd: ?[]const u8 = if (sc.working_directory) |t| (ev.render(t, sc1) catch null) else null;
                resolved = .{ .run = .{ .script = script, .shell = shell, .working_directory = wd, .env = step_env } };
            },
            .checkout => |inputs| {
                const rendered = ev.renderEnv(inputs, sc1) catch {
                    try failStep(&ev, &sh, step, res, num, try std.fmt.allocPrint(arena, "could not evaluate the checkout inputs: {s}", .{ev.diag}), coe);
                    continue;
                };
                const co = switch (try job_mod.checkoutFromInputs(arena, rendered)) {
                    .ok => |c| c,
                    .unsupported => |why| {
                        try failStep(&ev, &sh, step, res, num, why, coe);
                        continue;
                    },
                };
                const f = try fetchCheckout(arena, transport, job, co);
                if (f.result == .failed) {
                    try failStep(&ev, &sh, step, res, num, f.result.failed, coe);
                    continue;
                }
                fetched = f;
                resolved = .{ .checkout = f };
            },
        }

        const script = try stepScript(arena, num, resolved, if (step.context_name.len > 0) step.context_name else step.id);
        var doc: std.Io.Writer.Allocating = .init(arena);
        const w = &doc.writer;
        try w.writeAll("{ loadContainerFromID(id:");
        try std.json.Stringify.value(container_id, .{}, w);
        try w.writeAll(") { ");
        var braces: usize = 2; // query + loadContainerFromID
        // Variables and PATH entries the previous steps asked for through $GITHUB_ENV / $GITHUB_PATH.
        for (ev.pending_env.items) |e| {
            try w.writeAll("withEnvVariable(name:");
            try std.json.Stringify.value(e.name, .{}, w);
            try w.writeAll(",value:");
            try std.json.Stringify.value(e.value, .{}, w);
            try w.writeAll(") { ");
            braces += 1;
        }
        if (ev.pending_path.items.len > 0) {
            const joined = try std.mem.join(arena, ":", ev.pending_path.items);
            try w.writeAll("withEnvVariable(name:\"PATH\",value:");
            try std.json.Stringify.value(try std.fmt.allocPrint(arena, "{s}:$PATH", .{joined}), .{}, w);
            try w.writeAll(",expand:true) { ");
            braces += 1;
        }
        ev.pending_env.clearRetainingCapacity();
        ev.pending_path.clearRetainingCapacity();
        if (fetched) |f| {
            try w.writeAll("withDirectory(path:");
            try std.json.Stringify.value(f.mount, .{}, w);
            try w.writeAll(",source:");
            try std.json.Stringify.value(f.result.dir, .{}, w);
            try w.writeAll(") { ");
            braces += 1;
        }
        try w.writeAll("withExec(args:");
        try std.json.Stringify.value([_][]const u8{ "sh", "-c", script }, .{}, w);
        try w.writeAll(",expect:ANY) { id exitCode stdout stderr");
        for ([_][]const u8{ "output", "env", "path" }) |kind| {
            try w.print(" fc_{s}: file(path:\"{s}\") {{ contents }}", .{ kind, try fcPath(arena, kind, num) });
        }
        try w.writeAll(" }");
        for (0..braces) |_| try w.writeAll(" }");

        res.started_ms = std.Io.Clock.real.now(io).toMilliseconds();
        const data = gql(arena, transport, doc.written(), &err_msg) catch {
            res.* = .{ .name = res.name, .continued = coe, .outcome = .failure, .exit_code = 1, .started_ms = res.started_ms, .completed_ms = std.Io.Clock.real.now(io).toMilliseconds() };
            sh.append(num, try std.fmt.allocPrint(arena, "Dagger error: {s}", .{err_msg}));
            return finish(arena, &sh, results, err_msg);
        };
        res.completed_ms = std.Io.Clock.real.now(io).toMilliseconds();
        const code: i32 = if (jsonFind(data, "exitCode")) |c| (if (c == .integer) @intCast(c.integer) else 1) else 1;
        res.exit_code = code;
        res.outcome = if (code == 0) .success else .failure;
        if (jsonFindString(data, "id")) |id| container_id = id;

        // A cached step prints no log lines. Wait briefly for a live stream, then replay the result.
        awaitLiveOrReplay(io, &sh, num, jsonFindString(data, "stdout") orelse "", jsonFindString(data, "stderr") orelse "");

        // File commands: outputs for `steps.<id>.outputs`, env and PATH for the steps that follow.
        var outputs: []const job_mod.EnvVar = &.{};
        var cmd_error: ?[]const u8 = null;
        if (fileCommand(data, "fc_output")) |text| switch (try commands.parseKeyValues(arena, text)) {
            .ok => |kv| outputs = kv,
            .invalid => |why| cmd_error = try std.fmt.allocPrint(arena, "Unable to process the GITHUB_OUTPUT file command: {s}", .{why}),
        };
        if (fileCommand(data, "fc_env")) |text| switch (try commands.parseKeyValues(arena, text)) {
            .ok => |kv| for (kv) |e| {
                if (commands.isProtectedEnvName(e.name)) {
                    sh.append(num, try std.fmt.allocPrint(arena, "Warning: ignored GITHUB_ENV entry '{s}' (reserved name)", .{e.name}));
                    continue;
                }
                try Evaluator.putEnv(arena, &ev.job_env, e.name, e.value);
                try ev.pending_env.append(arena, e);
            },
            .invalid => |why| cmd_error = try std.fmt.allocPrint(arena, "Unable to process the GITHUB_ENV file command: {s}", .{why}),
        };
        if (fileCommand(data, "fc_path")) |text| for (try commands.parsePaths(arena, text)) |dir| try ev.pending_path.append(arena, dir);
        if (cmd_error) |msg| {
            sh.append(num, msg);
            if (res.outcome == .success) {
                res.outcome = .failure;
                res.exit_code = 1;
            }
        }
        try ev.record(step, res.outcome, coe, outputs);
        if (res.outcome == .failure and !coe) ev.job_failed = true;
    }
    return finish(arena, &sh, results, "");
}

/// How long to wait for a step's live lines before assuming it was served from cache. The log stream
/// delivers a real step's `end` marker within milliseconds, and a real run stops waiting as soon as
/// it arrives, so only cached steps pay this. If the stream is later than this, lines show up twice
/// rather than being lost.
const live_grace_ms = 60;

/// The contents of a file command read by the step's query ("" when the field is absent).
fn fileCommand(data: std.json.Value, alias: []const u8) ?[]const u8 {
    const f = jsonFind(data, alias) orelse return null;
    const text = jsonFindString(f, "contents") orelse return null;
    return if (text.len == 0) null else text;
}

/// Gives the reader a moment to deliver this step's lines; if none show up the step was served from
/// cache, so its recorded stdout and stderr are logged instead.
fn awaitLiveOrReplay(io: std.Io, sh: *Shared, step: u32, stdout: []const u8, stderr: []const u8) void {
    const idx = step - 1;
    var waited: u32 = 0;
    while (waited < live_grace_ms and !sh.ended[idx].load(.acquire)) : (waited += 10) {
        io.sleep(.fromMilliseconds(10), .awake) catch {};
    }
    if (sh.live_lines[idx].load(.monotonic) > 0 or sh.ended[idx].load(.acquire)) return;
    for ([_][]const u8{ stdout, stderr }) |text| {
        var lines = std.mem.splitScalar(u8, text, '\n');
        while (lines.next()) |l| {
            const t = std.mem.trimEnd(u8, l, "\r");
            if (scan(t)) |s| {
                if (s.before.len > 0) sh.replay(step, s.before);
                continue;
            }
            if (t.len > 0) sh.replay(step, t);
        }
    }
    sh.flush();
}

/// Logs why a step could not run and marks it failed (the job too, unless continue-on-error).
fn failStep(ev: *Evaluator, sh: *Shared, step: job_mod.Step, res: *StepResult, num: u32, msg: []const u8, coe: bool) !void {
    sh.append(num, msg);
    const name = res.name;
    res.* = .{ .name = name, .continued = coe, .outcome = .failure, .exit_code = 1 };
    try ev.record(step, .failure, coe, &.{});
    if (!coe) ev.job_failed = true;
}

fn fail(sh: *Shared, results: []StepResult, msg: []const u8) !Result {
    sh.flush();
    return .{ .steps = results, .engine_error = msg, .succeeded = false };
}

fn finish(arena: Allocator, sh: *Shared, results: []StepResult, engine_msg: []const u8) !Result {
    sh.flush();
    var any_failed = false;
    var any_not_run = false;
    for (results) |res| {
        if (res.outcome == .failure and !res.continued) any_failed = true;
        if (res.outcome == .not_run) any_not_run = true;
    }
    var engine_error: ?[]const u8 = null;
    if ((any_not_run and !any_failed) or engine_msg.len > 0) {
        sh.mu.lockUncancelable(sh.io);
        defer sh.mu.unlock(sh.io);
        const tail = try std.mem.join(arena, "\n", sh.tail[0..sh.tail_len]);
        engine_error = if (engine_msg.len > 0)
            try std.fmt.allocPrint(arena, "{s}{s}{s}", .{ engine_msg, if (tail.len > 0) "\n" else "", tail })
        else
            tail;
    }
    return .{ .steps = results, .engine_error = engine_error, .succeeded = !any_failed and engine_error == null };
}

// --- tests ---

fn testStep(script: []const u8) job_mod.Step {
    return .{ .id = "x", .name = "n", .condition = "success()", .action = .{ .script = .{ .script = .{ .lit = script }, .shell = null, .working_directory = null } } };
}

fn testJob(steps: []const job_mod.Step) job_mod.Job {
    return .{
        .plan_id = "p",
        .job_id = "j",
        .job_token = "t",
        .check_run_id = 1,
        .has_container = false,
        .secrets = &.{},
        .github = .{ .repository = "o/r", .sha = "0123456789012345678901234567890123456789", .ref = "refs/heads/x" },
        .steps = steps,
    };
}

test "scan finds markers, with and without leading output" {
    try std.testing.expect(scan("plain output") == null);
    try std.testing.expectEqual(@as(u32, 3), scan(marker ++ "begin 3").?.marker.begin);
    const e = scan("tail without newline" ++ marker ++ "end 2").?;
    try std.testing.expectEqualStrings("tail without newline", e.before);
    try std.testing.expectEqual(@as(u32, 2), e.marker.end);
    try std.testing.expect(scan(marker ++ "bogus 1") == null);
    // Script source shown in a span header must not parse as a marker.
    try std.testing.expect(scan("echo '" ++ marker ++ "begin 2'\\''") == null);
    try std.testing.expectEqual(@as(?u32, 2), headerStep("echo '" ++ marker ++ "begin 2'\\''"));
}

test "evalCondition" {
    try std.testing.expectEqual(@as(?bool, true), evalCondition("success()", false));
    try std.testing.expectEqual(@as(?bool, false), evalCondition("success()", true));
    try std.testing.expectEqual(@as(?bool, true), evalCondition("failure()", true));
    try std.testing.expectEqual(@as(?bool, true), evalCondition(" always() ", true));
    try std.testing.expectEqual(@as(?bool, null), evalCondition("github.ref == 'x'", false));
}

test "script quotes, applies env, shell and working directory, and propagates the exit code" {
    var a: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer a.deinit();
    const w = try stepScript(a.allocator(), 2, .{ .run = .{
        .script = "echo 'hi' && echo $X",
        .shell = "sh",
        .working_directory = "sub dir",
        .env = &.{.{ .name = "X", .value = "a b" }},
    } }, "build");
    try std.testing.expect(std.mem.indexOf(u8, w, "cd 'sub dir' && env 'X=a b' 'GITHUB_OUTPUT=/github/file_commands/output_2'") != null);
    try std.testing.expect(std.mem.indexOf(u8, w, "'GITHUB_ACTION=build' sh -e -c 'echo '\\''hi'\\'' && echo $X'") != null);
    // The file commands exist before the step and are touched again after it.
    try std.testing.expect(std.mem.indexOf(u8, w, ": > /github/file_commands/output_2 > /github/file_commands/env_2") != null);
    try std.testing.expect(std.mem.indexOf(u8, w, ">> /github/file_commands/path_2") != null);
    try std.testing.expect(std.mem.indexOf(u8, w, marker ++ "begin 2") != null);
    try std.testing.expect(std.mem.endsWith(u8, w, "exit $rc\n"));
}

test "checkoutQuery picks commit, ref or head and honours fetch-depth" {
    var a: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer a.deinit();
    const job = testJob(&.{});
    const own = (try checkoutQuery(a.allocator(), job, .{})).doc;
    try std.testing.expectEqualStrings("{ git(url:\"https://github.com/o/r.git\",keepGitDir:true) { commit(id:\"0123456789012345678901234567890123456789\") { tree(depth:1) { id } } } }", own);
    const by_ref = (try checkoutQuery(a.allocator(), job, .{ .ref = "refs/pull/7/merge", .fetch_depth = 0 })).doc;
    try std.testing.expectEqualStrings("{ git(url:\"https://github.com/o/r.git\",keepGitDir:true) { ref(name:\"refs/pull/7/merge\") { tree { id } } } }", by_ref);
    const other = (try checkoutQuery(a.allocator(), job, .{ .repository = "x/y", .fetch_depth = 3 })).doc;
    try std.testing.expect(std.mem.indexOf(u8, other, "x/y.git") != null and std.mem.indexOf(u8, other, "{ head { tree(depth:3)") != null);
    var empty = job;
    empty.github.repository = "";
    try std.testing.expect((try checkoutQuery(a.allocator(), empty, .{})) == .err);
}

fn braceBalanced(doc: []const u8) bool {
    var depth: i32 = 0;
    var in_str = false;
    var i: usize = 0;
    while (i < doc.len) : (i += 1) {
        const c = doc[i];
        if (in_str) {
            if (c == '\\') i += 1 else if (c == '"') in_str = false;
        } else switch (c) {
            '"' => in_str = true,
            '{' => depth += 1,
            '}' => {
                depth -= 1;
                if (depth < 0) return false;
            },
            else => {},
        }
    }
    return depth == 0 and !in_str;
}

/// A scripted stand-in for the Dagger session: answers queries in order and records them.
const FakeSession = struct {
    answers: []const []const u8,
    next: usize = 0,
    seen: std.ArrayList([]const u8) = .empty,
    arena: Allocator,

    fn send(ptr: *anyopaque, arena: Allocator, doc: []const u8) anyerror![]const u8 {
        const self: *FakeSession = @ptrCast(@alignCast(ptr));
        try self.seen.append(self.arena, try arena.dupe(u8, doc));
        defer self.next += 1;
        if (self.next >= self.answers.len) return error.NoMoreAnswers;
        return self.answers[self.next];
    }

    fn transport(self: *FakeSession) Transport {
        return .{ .ptr = self, .sendFn = send };
    }
};

const fake_child = "printf '0 tok\\n'; cat >/dev/null";
const base_answer = "{\"data\":{\"container\":{\"from\":{\"withWorkdir\":{\"id\":\"C0\"}}}}}";

fn exec(arena: Allocator, id: []const u8, code: i32, out: []const u8) ![]const u8 {
    return std.fmt.allocPrint(arena, "{{\"data\":{{\"loadContainerFromID\":{{\"withExec\":{{\"id\":\"{s}\",\"exitCode\":{d},\"stdout\":\"{s}\",\"stderr\":\"\"}}}}}}}}", .{ id, code, out });
}

test "run threads the container through steps, applies conditions, and replays cached output" {
    var a: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer a.deinit();
    const arena = a.allocator();
    var env: std.process.Environ.Map = .init(arena);

    var s3 = testStep("c");
    s3.condition = "always()";
    var s4 = testStep("d");
    s4.condition = "success()";
    const steps = [_]job_mod.Step{ testStep("a"), testStep("b"), s3, s4 };
    const answers = [_][]const u8{
        base_answer,
        try exec(arena, "C1", 0, "from-a\\n"),
        try exec(arena, "C2", 3, "from-b\\n"),
        try exec(arena, "C3", 0, "from-c\\n"),
    };
    var fake: FakeSession = .{ .answers = &answers, .arena = arena };

    var buf: [2048]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buf);
    var log: sink.LogSink = .{ .stdout = .{ .writer = &w } };
    const res = try run(arena, std.testing.io, &env, .{ .test_session_argv = &.{ "sh", "-c", fake_child }, .test_transport = fake.transport() }, testJob(&steps), &log);

    try std.testing.expectEqual(Outcome.success, res.steps[0].outcome);
    try std.testing.expectEqual(Outcome.failure, res.steps[1].outcome);
    try std.testing.expectEqual(@as(i32, 3), res.steps[1].exit_code);
    try std.testing.expectEqual(Outcome.success, res.steps[2].outcome); // always()
    try std.testing.expectEqual(Outcome.skipped, res.steps[3].outcome); // success() after a failure
    try std.testing.expect(!res.succeeded);
    // Every document is well-formed GraphQL (balanced braces outside of strings).
    for (fake.seen.items) |d| try std.testing.expect(braceBalanced(d));
    // Each step started from the previous step's container.
    try std.testing.expect(std.mem.indexOf(u8, fake.seen.items[1], "id:\"C0\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, fake.seen.items[2], "id:\"C1\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, fake.seen.items[3], "id:\"C2\"") != null);
    try std.testing.expectEqual(@as(usize, 4), fake.seen.items.len); // the skipped step sends nothing
    // No live lines were streamed, so the recorded stdout was replayed.
    try std.testing.expect(std.mem.indexOf(u8, w.buffered(), "[job 0 step 1 stdout] from-a\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, w.buffered(), "[job 0 step 2 stdout] from-b\n") != null);
}

test "run streams live lines from the session's log and does not replay them" {
    var a: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer a.deinit();
    const arena = a.allocator();
    var env: std.process.Environ.Map = .init(arena);
    const steps = [_]job_mod.Step{testStep("a")};
    const answers = [_][]const u8{ base_answer, try exec(arena, "C1", 0, "live-line\\n") };
    var fake: FakeSession = .{ .answers = &answers, .arena = arena };

    // The fake child also prints Dagger-style log output: noise, a span header, then the step's lines.
    const child =
        \\printf '0 tok\n'
        \\{ echo "connecting"; printf '\342\226\274 withExec sh -c '\''echo '\\\\'\''::zig-step::begin 1'\\\\'\''\\\\nexit $rc\\\\n'\'' (expect: ANY)\n'
        \\  echo "::zig-step::begin 1"; echo "live-line"; echo "::zig-step::end 1"; } >&2
        \\cat >/dev/null
    ;
    var buf: [2048]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buf);
    var log: sink.LogSink = .{ .stdout = .{ .writer = &w } };
    const res = try run(arena, std.testing.io, &env, .{ .test_session_argv = &.{ "sh", "-c", child }, .test_transport = fake.transport() }, testJob(&steps), &log);
    try std.testing.expect(res.succeeded);
    try std.testing.expectEqual(@as(usize, 1), std.mem.count(u8, w.buffered(), "live-line\n"));
    try std.testing.expect(std.mem.indexOf(u8, w.buffered(), "withExec") == null);
    try std.testing.expect(std.mem.indexOf(u8, w.buffered(), "connecting") == null);
}

test "a live line that arrives after its step was replayed is dropped, not logged twice" {
    var a: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer a.deinit();
    var buf: [512]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buf);
    var log: sink.LogSink = .{ .stdout = .{ .writer = &w } };
    const live = [_]std.atomic.Value(u32){.init(0)};
    const ended = [_]std.atomic.Value(bool){.init(false)};
    var sh: Shared = .{ .io = std.testing.io, .arena = a.allocator(), .log = &log, .sink_job_id = 0, .live_lines = @constCast(&live), .ended = @constCast(&ended) };
    sh.replay(1, "hello"); // the step looked cached
    sh.emitLive(1, "hello"); // ...but its live copy arrives late
    sh.emitLive(1, "hello"); // a genuine second line with the same text is kept
    sh.emitLive(1, "other");
    try std.testing.expectEqual(@as(usize, 2), std.mem.count(u8, w.buffered(), "hello\n"));
    try std.testing.expectEqual(@as(usize, 1), std.mem.count(u8, w.buffered(), "other\n"));
}

test "run mounts a fetched checkout, and a failed fetch fails only that step" {
    var a: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer a.deinit();
    const arena = a.allocator();
    var env: std.process.Environ.Map = .init(arena);
    var co = testStep("x");
    co.name = "Run actions/checkout@v4";
    co.action = .{ .checkout = &.{} };
    var after = testStep("echo after");
    after.condition = "always()";
    const steps = [_]job_mod.Step{ co, after };

    const answers = [_][]const u8{
        base_answer,
        "{\"data\":{\"git\":{\"commit\":{\"tree\":{\"id\":\"TREE1\"}}}}}",
        try exec(arena, "C1", 0, "Syncing repository: o/r\\n"),
    };
    var fake: FakeSession = .{ .answers = &answers, .arena = arena };
    var buf: [2048]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buf);
    var log: sink.LogSink = .{ .stdout = .{ .writer = &w } };
    _ = try run(arena, std.testing.io, &env, .{ .test_session_argv = &.{ "sh", "-c", fake_child }, .test_transport = fake.transport() }, testJob(&steps), &log);
    for (fake.seen.items) |d| try std.testing.expect(braceBalanced(d));
    try std.testing.expect(std.mem.indexOf(u8, fake.seen.items[2], "withDirectory(path:\"/github/workspace\",source:\"TREE1\")") != null);
    try std.testing.expect(std.mem.indexOf(u8, fake.seen.items[2], "Checked out 0123456 into /github/workspace") != null);

    // Fetch failure (GraphQL error): that step fails with the reason; the always() step still runs.
    const answers2 = [_][]const u8{
        base_answer,
        "{\"errors\":[{\"message\":\"remote: Repository not found.\"}]}",
        try exec(arena, "C1", 0, "after\\n"),
    };
    var fake2: FakeSession = .{ .answers = &answers2, .arena = arena };
    var buf2: [2048]u8 = undefined;
    var w2: std.Io.Writer = .fixed(&buf2);
    var log2: sink.LogSink = .{ .stdout = .{ .writer = &w2 } };
    const res2 = try run(arena, std.testing.io, &env, .{ .test_session_argv = &.{ "sh", "-c", fake_child }, .test_transport = fake2.transport() }, testJob(&steps), &log2);
    try std.testing.expectEqual(Outcome.failure, res2.steps[0].outcome);
    try std.testing.expectEqual(Outcome.success, res2.steps[1].outcome);
    try std.testing.expect(std.mem.indexOf(u8, w2.buffered(), "could not fetch o/r@0123456: remote: Repository not found. (private repositories are not supported in v0)") != null);
}

test "run reports an engine error when the session cannot start" {
    var a: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer a.deinit();
    const arena = a.allocator();
    var env: std.process.Environ.Map = .init(arena);
    const steps = [_]job_mod.Step{testStep("a")};
    var buf: [256]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buf);
    var log: sink.LogSink = .{ .stdout = .{ .writer = &w } };
    const res = try run(arena, std.testing.io, &env, .{ .test_session_argv = &.{ "sh", "-c", "echo 'cannot connect to docker' >&2; exit 1" } }, testJob(&steps), &log);
    try std.testing.expect(!res.succeeded);
    try std.testing.expect(res.engine_error != null);
    try std.testing.expectEqual(Outcome.not_run, res.steps[0].outcome);
}

test "run evaluates expressions in conditions, names, env, scripts and the steps context" {
    var a: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer a.deinit();
    const arena = a.allocator();
    var env: std.process.Environ.Map = .init(arena);

    const json =
        \\{"plan":{"planId":"p"},"jobId":"j","resources":{"endpoints":[{"authorization":{"parameters":{"AccessToken":"t"}}}]},
        \\ "environmentVariables":[{"type":2,"map":[{"Key":{"lit":"JOB_ENV"},"Value":{"type":3,"expr":"format('{0}-job', github.ref_name)"}}]}],
        \\ "contextData":{"matrix":null,"github":{"t":2,"d":[{"k":"ref","v":"refs/heads/main"},{"k":"ref_name","v":"main"},{"k":"sha","v":"abc123"},{"k":"repository","v":"o/r"}]}},
        \\ "steps":[
        \\  {"type":"action","reference":{"type":"script"},"id":"s1","contextName":"first","name":"first","condition":"success()",
        \\   "displayNameToken":{"type":3,"expr":"format('Build {0}', github.ref_name)"},
        \\   "environment":{"type":2,"map":[{"Key":{"lit":"STEP_ENV"},"Value":{"type":3,"expr":"github.sha"}}]},
        \\   "inputs":{"type":2,"map":[{"Key":{"lit":"script"},"Value":{"type":3,"expr":"format('echo {0} $STEP_ENV {1}', github.sha, env.JOB_ENV)"}}]}},
        \\  {"type":"action","reference":{"type":"script"},"id":"s2","contextName":"__run","name":"__run","condition":"success() && (github.ref == 'refs/heads/main')",
        \\   "inputs":{"type":2,"map":[{"Key":{"lit":"script"},"Value":{"lit":"echo on-main"}}]}},
        \\  {"type":"action","reference":{"type":"script"},"id":"s3","contextName":"__run_2","name":"__run_2","condition":"success() && (github.ref == 'refs/heads/other')",
        \\   "inputs":{"type":2,"map":[{"Key":{"lit":"script"},"Value":{"lit":"echo never"}}]}},
        \\  {"type":"action","reference":{"type":"script"},"id":"s4","contextName":"__run_3","name":"__run_3","condition":"success()",
        \\   "inputs":{"type":2,"map":[{"Key":{"lit":"script"},"Value":{"type":3,"expr":"format('echo outcome={0} skipped={1}', steps.first.outcome, steps.__run_2.outcome)"}}]}},
        \\  {"type":"action","reference":{"type":"script"},"id":"s5","contextName":"__run_4","name":"__run_4","condition":"success()",
        \\   "inputs":{"type":2,"map":[{"Key":{"lit":"script"},"Value":{"type":3,"expr":"format('echo {0}', secrets.TOKEN)"}}]}},
        \\  {"type":"action","reference":{"type":"script"},"id":"s6","contextName":"__run_5","name":"__run_5","condition":"always()",
        \\   "inputs":{"type":2,"map":[{"Key":{"lit":"script"},"Value":{"lit":"echo cleanup"}}]}}
        \\ ]}
    ;
    const job = try job_mod.parse(arena, json);
    const answers = [_][]const u8{
        base_answer,
        try exec(arena, "C1", 0, "ok\\n"),
        try exec(arena, "C2", 0, "ok\\n"),
        try exec(arena, "C3", 0, "ok\\n"),
        try exec(arena, "C4", 0, "ok\\n"),
    };
    var fake: FakeSession = .{ .answers = &answers, .arena = arena };
    var buf: [4096]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buf);
    var log: sink.LogSink = .{ .stdout = .{ .writer = &w } };
    const res = try run(arena, std.testing.io, &env, .{ .test_session_argv = &.{ "sh", "-c", fake_child }, .test_transport = fake.transport() }, job, &log);

    // Names, outcomes.
    try std.testing.expectEqualStrings("Build main", res.steps[0].name);
    try std.testing.expectEqual(Outcome.success, res.steps[0].outcome);
    try std.testing.expectEqual(Outcome.success, res.steps[1].outcome);
    try std.testing.expectEqual(Outcome.skipped, res.steps[2].outcome); // condition false
    try std.testing.expectEqual(Outcome.success, res.steps[3].outcome);
    try std.testing.expectEqual(Outcome.failure, res.steps[4].outcome); // secrets are unsupported
    try std.testing.expectEqual(Outcome.success, res.steps[5].outcome); // always()
    try std.testing.expect(!res.succeeded);
    // Evaluated scripts reached Dagger: sha, step env, job env (from an expression), and steps.* outcomes.
    try std.testing.expect(std.mem.indexOf(u8, fake.seen.items[1], "echo abc123 $STEP_ENV main-job") != null);
    try std.testing.expect(std.mem.indexOf(u8, fake.seen.items[1], "STEP_ENV=abc123") != null);
    try std.testing.expect(std.mem.indexOf(u8, fake.seen.items[3], "echo outcome=success skipped=skipped") != null);
    // 5 queries: base + steps 1, 2, 4, 6 (the skipped step and the failed one send nothing).
    try std.testing.expectEqual(@as(usize, 5), fake.seen.items.len);
    // The unsupported context is reported in that step's log.
    try std.testing.expect(std.mem.indexOf(u8, w.buffered(), "the 'secrets' context is not supported yet") != null);
}

fn execFc(arena: Allocator, id: []const u8, out: []const u8, fc_output: []const u8, fc_env: []const u8, fc_path: []const u8) ![]const u8 {
    return std.fmt.allocPrint(arena, "{{\"data\":{{\"loadContainerFromID\":{{\"withExec\":{{\"id\":\"{s}\",\"exitCode\":0,\"stdout\":\"{s}\",\"stderr\":\"\",\"fc_output\":{{\"contents\":\"{s}\"}},\"fc_env\":{{\"contents\":\"{s}\"}},\"fc_path\":{{\"contents\":\"{s}\"}}}}}}}}}}", .{ id, out, fc_output, fc_env, fc_path });
}

test "file commands: outputs feed steps.<id>.outputs, GITHUB_ENV and GITHUB_PATH reach later steps" {
    var a: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer a.deinit();
    const arena = a.allocator();
    var env: std.process.Environ.Map = .init(arena);
    const json =
        \\{"plan":{"planId":"p"},"jobId":"j","resources":{"endpoints":[{"authorization":{"parameters":{"AccessToken":"t"}}}]},
        \\ "contextData":{"github":{"t":2,"d":[{"k":"sha","v":"abc"},{"k":"repository","v":"o/r"},{"k":"ref_name","v":"main"}]}},
        \\ "steps":[
        \\  {"type":"action","reference":{"type":"script"},"id":"s1","contextName":"build","name":"build","condition":"success()",
        \\   "inputs":{"type":2,"map":[{"Key":{"lit":"script"},"Value":{"lit":"echo producing"}}]}},
        \\  {"type":"action","reference":{"type":"script"},"id":"s2","contextName":"use","name":"use","condition":"success()",
        \\   "inputs":{"type":2,"map":[{"Key":{"lit":"script"},"Value":{"type":3,"expr":"format('echo version={0} multi={1} env=$FROM_ENV', steps.build.outputs.version, steps.build.outputs.notes)"}}]}},
        \\  {"type":"action","reference":{"type":"script"},"id":"s3","contextName":"bad","name":"bad","condition":"success()",
        \\   "inputs":{"type":2,"map":[{"Key":{"lit":"script"},"Value":{"lit":"echo writes garbage"}}]}},
        \\  {"type":"action","reference":{"type":"script"},"id":"s4","contextName":"after","name":"after","condition":"always()",
        \\   "inputs":{"type":2,"map":[{"Key":{"lit":"script"},"Value":{"lit":"echo done"}}]}}
        \\ ]}
    ;
    const job = try job_mod.parse(arena, json);
    const answers = [_][]const u8{
        base_answer,
        try execFc(arena, "C1", "producing\\n", "version=1.2.3\\nnotes<<EOF\\nline a\\nline b\\nEOF\\n", "FROM_ENV=hello\\nGITHUB_SHA=evil\\n", "/opt/tool/bin\\n"),
        try execFc(arena, "C2", "x\\n", "", "", ""),
        try execFc(arena, "C3", "y\\n", "this is not valid\\n", "", ""),
        try execFc(arena, "C4", "z\\n", "", "", ""),
    };
    var fake: FakeSession = .{ .answers = &answers, .arena = arena };
    var buf: [4096]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buf);
    var log: sink.LogSink = .{ .stdout = .{ .writer = &w } };
    const res = try run(arena, std.testing.io, &env, .{ .test_session_argv = &.{ "sh", "-c", fake_child }, .test_transport = fake.transport() }, job, &log);

    for (fake.seen.items) |d| try std.testing.expect(braceBalanced(d));
    // Default environment is set once on the base container.
    try std.testing.expect(std.mem.indexOf(u8, fake.seen.items[0], "withEnvVariable(name:\"GITHUB_SHA\",value:\"abc\")") != null);
    try std.testing.expect(std.mem.indexOf(u8, fake.seen.items[0], "name:\"CI\",value:\"true\"") != null);
    // Step 1's query reads the file commands.
    try std.testing.expect(std.mem.indexOf(u8, fake.seen.items[1], "fc_output: file(path:\"/github/file_commands/output_1\")") != null);
    // Outputs (including a multi-line one) were evaluated into step 2's script.
    try std.testing.expect(std.mem.indexOf(u8, fake.seen.items[2], "echo version=1.2.3 multi=line a\\nline b env=$FROM_ENV") != null);
    // GITHUB_ENV and GITHUB_PATH apply to the next step's container; reserved names are refused.
    try std.testing.expect(std.mem.indexOf(u8, fake.seen.items[2], "withEnvVariable(name:\"FROM_ENV\",value:\"hello\")") != null);
    try std.testing.expect(std.mem.indexOf(u8, fake.seen.items[2], "withEnvVariable(name:\"PATH\",value:\"/opt/tool/bin:$PATH\",expand:true)") != null);
    try std.testing.expect(std.mem.indexOf(u8, fake.seen.items[2], "name:\"GITHUB_SHA\",value:\"evil\"") == null);
    try std.testing.expect(std.mem.indexOf(u8, w.buffered(), "ignored GITHUB_ENV entry 'GITHUB_SHA'") != null);
    // ...and only once: step 3 no longer re-applies them.
    try std.testing.expect(std.mem.indexOf(u8, fake.seen.items[3], "withEnvVariable") == null);
    // A malformed GITHUB_OUTPUT fails the step that wrote it; always() still runs.
    try std.testing.expectEqual(Outcome.failure, res.steps[2].outcome);
    try std.testing.expect(std.mem.indexOf(u8, w.buffered(), "Unable to process the GITHUB_OUTPUT file command: invalid format 'this is not valid' on line 1") != null);
    try std.testing.expectEqual(Outcome.success, res.steps[3].outcome);
}
