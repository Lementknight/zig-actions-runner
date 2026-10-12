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
const action = @import("action.zig");

const Allocator = std.mem.Allocator;

pub const default_image = "ubuntu:24.04";
pub const workspace = "/github/workspace";
pub const marker = "::zig-step::";

/// Makes `ubuntu:24.04` usable for typical steps: git (checked-out workspaces are real repositories), xz (to unpack toolchains),
/// curl, CA certificates and jq (which composite actions often assume, as on GitHub's hosted images). Dagger caches this
/// exec, so only the first run pays for it.
pub const provision_script = "apt-get update -qq && DEBIAN_FRONTEND=noninteractive apt-get install -y -qq --no-install-recommends git ca-certificates curl xz-utils jq >/dev/null && rm -rf /var/lib/apt/lists/*";

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
    return stepScriptFc(arena, n, n, r, action_name);
}

/// As `stepScript`, with file commands numbered `fc` instead of `n`. The steps of a composite action
/// all log as their `uses:` step (`n`), but each needs its own file commands.
fn stepScriptFc(arena: Allocator, n: u32, fc: u32, r: Resolved, action_name: []const u8) ![]const u8 {
    var aw: std.Io.Writer.Allocating = .init(arena);
    const w = &aw.writer;
    try w.print("echo '{s}begin {d}'\nmkdir -p " ++ fc_dir ++ " && : ", .{ marker, n });
    for (fc_kinds) |k| try w.print("> {s} ", .{try fcPath(arena, k, fc)});
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
                try shellQuote(w, try std.fmt.allocPrint(arena, "{s}={s}", .{ name, try fcPath(arena, kind, fc) }));
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
    for (fc_kinds) |k| try w.print(">> {s} ", .{try fcPath(arena, k, fc)});
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

/// Told when each step starts and finishes, so run state can be recorded at those transitions.
pub const Observer = struct {
    ptr: *anyopaque,
    startedFn: *const fn (ptr: *anyopaque, number: u32, name: []const u8, started_ms: i64) void,
    finishedFn: *const fn (ptr: *anyopaque, number: u32, result: StepResult) void,

    fn started(o: Observer, number: u32, name: []const u8, started_ms: i64) void {
        o.startedFn(o.ptr, number, name, started_ms);
    }
    fn finished(o: Observer, number: u32, result: StepResult) void {
        o.finishedFn(o.ptr, number, result);
    }
};

pub const Options = struct {
    observer: ?Observer = null,
    /// The `dagger` command.
    dagger_cmd: []const u8 = "dagger",
    image: []const u8 = default_image,
    /// Installed into the image before the job (one cached exec). Used for the default image only,
    /// which has no git; a custom image is expected to bring what it needs.
    provision: bool = true,
    /// Key under which output lines are written to the sink.
    sink_job_id: u64 = 0,
    /// Steps may use the job's Dagger engine (`dagger call` inside a step): `experimentalPrivilegedNesting`.
    nesting: bool = true,
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
    // `depth` is always sent: Dagger's default is 1, and 0 is what fetches the full history.
    try w.print(" {{ tree(depth:{d}{s}) {{ id }} }} }} }}", .{ co.fetch_depth, if (co.fetch_tags) ",includeTags:true" else "" });
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

        const secret_entries = try arena.alloc(expr.Value.Entry, ev.job.secret_vars.len);
        for (ev.job.secret_vars, secret_entries) |sv, *o| o.* = .{ .key = sv.name, .value = .{ .string = sv.value } };

        const ctxs = try arena.alloc(expr.Value.Entry, 11);
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
        ctxs[10] = .{ .key = "secrets", .value = .{ .object = secret_entries } };
        return .{
            .contexts = ctxs,
            .job_failed = ev.job_failed,
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

// --- secrets in the environment ---

/// Whether a value contains a secret. Such env values reach the step through a Dagger secret
/// (`withSecretVariable`), so they are not written into the command (which Dagger would keep in its
/// cache metadata and print in its progress log). Very short secret values are ignored: they would
/// match unrelated text.
fn containsSecret(job: job_mod.Job, value: []const u8) bool {
    for (job.secrets) |sec| if (sec.len >= 3 and std.mem.indexOf(u8, value, sec) != null) return true;
    return false;
}

const SecretRef = struct { name: []const u8, id: []const u8 };

/// Registers `plaintext` as a Dagger secret in this session and returns its id.
fn newSecret(arena: Allocator, t: Transport, counter: *u32, plaintext: []const u8, err_msg: *[]const u8) ![]const u8 {
    counter.* += 1;
    var doc: std.Io.Writer.Allocating = .init(arena);
    const w = &doc.writer;
    try w.print("{{ setSecret(name:\"zig-secret-{d}\",plaintext:", .{counter.*});
    try std.json.Stringify.value(plaintext, .{}, w);
    try w.writeAll(") { id } }");
    const data = try gql(arena, t, doc.written(), err_msg);
    return jsonFindString(data, "id") orelse {
        err_msg.* = "Dagger returned no secret id";
        return error.DaggerQueryFailed;
    };
}

/// Splits env into plain variables and secret-bearing ones (registered as Dagger secrets).
fn splitEnv(
    arena: Allocator,
    t: Transport,
    job: job_mod.Job,
    counter: *u32,
    env: []const job_mod.EnvVar,
    plain: *std.ArrayList(job_mod.EnvVar),
    secret: *std.ArrayList(SecretRef),
    err_msg: *[]const u8,
) !void {
    for (env) |e| {
        if (containsSecret(job, e.value)) {
            try secret.append(arena, .{ .name = e.name, .id = try newSecret(arena, t, counter, e.value, err_msg) });
        } else {
            try plain.append(arena, e);
        }
    }
}

fn writeEnvNodes(w: *std.Io.Writer, plain: []const job_mod.EnvVar, secret: []const SecretRef) !usize {
    for (plain) |e| {
        try w.writeAll("withEnvVariable(name:");
        try std.json.Stringify.value(e.name, .{}, w);
        try w.writeAll(",value:");
        try std.json.Stringify.value(e.value, .{}, w);
        try w.writeAll(") { ");
    }
    for (secret) |sr| {
        try w.writeAll("withSecretVariable(name:");
        try std.json.Stringify.value(sr.name, .{}, w);
        try w.writeAll(",secret:");
        try std.json.Stringify.value(sr.id, .{}, w);
        try w.writeAll(") { ");
    }
    return plain.len + secret.len;
}

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
    var secret_counter: u32 = 0;
    var err_msg: []const u8 = "";
    const container_id: []const u8 = blk: {
        var doc: std.Io.Writer.Allocating = .init(arena);
        const w = &doc.writer;
        try w.writeAll("{ container { from(address:");
        try std.json.Stringify.value(opts.image, .{}, w);
        try w.writeAll(") { ");
        const provision = opts.provision and std.mem.eql(u8, opts.image, default_image);
        if (provision) {
            try w.writeAll("withExec(args:");
            try std.json.Stringify.value([_][]const u8{ "sh", "-c", provision_script }, .{}, w);
            try w.writeAll(") { ");
        }
        try w.print("withWorkdir(path:\"{s}\") {{ ", .{workspace});
        const defaults = try ev.defaultEnv();
        for (defaults) |e| {
            try w.writeAll("withEnvVariable(name:");
            try std.json.Stringify.value(e.name, .{}, w);
            try w.writeAll(",value:");
            try std.json.Stringify.value(e.value, .{}, w);
            try w.writeAll(") { ");
        }
        // Workflow- and job-level env is part of every step's environment.
        var plain_job: std.ArrayList(job_mod.EnvVar) = .empty;
        var secret_job: std.ArrayList(SecretRef) = .empty;
        splitEnv(arena, transport, job, &secret_counter, ev.job_env.items, &plain_job, &secret_job, &err_msg) catch return fail(&sh, results, err_msg);
        const job_env_nodes = try writeEnvNodes(w, plain_job.items, secret_job.items);
        try w.writeAll("id");
        for (0..defaults.len + job_env_nodes + 4 + @as(usize, if (provision) 1 else 0)) |_| try w.writeAll(" }");
        const data = gql(arena, transport, doc.written(), &err_msg) catch return fail(&sh, results, err_msg);
        break :blk jsonFindString(data, "id") orelse return fail(&sh, results, "Dagger returned no container");
    };

    var x: Exec = .{
        .arena = arena,
        .io = io,
        .transport = transport,
        .sh = &sh,
        .ev = &ev,
        .job = &job,
        .container_id = container_id,
        .secret_counter = secret_counter,
        .next_fc = @intCast(job.steps.len + 1),
        .nesting = opts.nesting,
    };

    for (job.steps, results, 1..) |step, *res, n| {
        const num: u32 = @intCast(n);
        res.name = step.name;

        // 1. The condition, with the job env visible.
        ev.diag = "";
        const sc0 = try ev.scope(&.{});
        if (step.name_expr) |ne| res.name = expr.evalString(arena, ne, sc0) catch step.name;
        const should_run = expr.evalCondition(arena, step.condition, sc0) catch {
            try failStep(&ev, &sh, opts.observer, step, res, num, try std.fmt.allocPrint(arena, "could not evaluate the condition '{s}': {s}", .{ step.condition, ev.diag }), false);
            continue;
        };
        if (!should_run) {
            res.outcome = .skipped;
            try ev.record(step, .skipped, false, &.{});
            if (opts.observer) |o| o.finished(num, res.*);
            continue;
        }

        // 2. Step env and continue-on-error, then the step's own inputs.
        const step_env = ev.renderEnv(step.env, sc0) catch {
            try failStep(&ev, &sh, opts.observer, step, res, num, try std.fmt.allocPrint(arena, "could not evaluate env: {s}", .{ev.diag}), false);
            continue;
        };
        const sc1 = try ev.scope(step_env);
        const coe = std.mem.eql(u8, ev.render(step.continue_on_error, sc1) catch "false", "true");
        res.continued = coe;

        // Env that carries a secret goes in as a Dagger secret, the rest in the script.
        var plain_step_env: std.ArrayList(job_mod.EnvVar) = .empty;
        var secret_step_env: std.ArrayList(SecretRef) = .empty;
        splitEnv(arena, transport, job, &x.secret_counter, step_env, &plain_step_env, &secret_step_env, &x.err_msg) catch {
            try failStep(&ev, &sh, opts.observer, step, res, num, try std.fmt.allocPrint(arena, "Dagger could not register a secret: {s}", .{x.err_msg}), coe);
            continue;
        };

        var resolved: Resolved = undefined;
        var mount_buf: [1]Mount = undefined;
        var mounts: []const Mount = &.{};
        switch (step.action) {
            .unsupported => |why| {
                try failStep(&ev, &sh, opts.observer, step, res, num, why, coe);
                continue;
            },
            .script => |sc| {
                const script = ev.render(sc.script, sc1) catch {
                    try failStep(&ev, &sh, opts.observer, step, res, num, try std.fmt.allocPrint(arena, "could not evaluate the script: {s}", .{ev.diag}), coe);
                    continue;
                };
                const shell: ?[]const u8 = if (sc.shell) |t| (ev.render(t, sc1) catch null) else null;
                if (shell) |sh_name| if (!job_mod.validShell(sh_name)) {
                    try failStep(&ev, &sh, opts.observer, step, res, num, try std.fmt.allocPrint(arena, "unsupported shell '{s}' (v0 supports bash and sh)", .{sh_name}), coe);
                    continue;
                };
                const wd: ?[]const u8 = if (sc.working_directory) |t| (ev.render(t, sc1) catch null) else null;
                resolved = .{ .run = .{ .script = script, .shell = shell, .working_directory = wd, .env = plain_step_env.items } };
            },
            .checkout => |inputs| {
                const rendered = ev.renderEnv(inputs, sc1) catch {
                    try failStep(&ev, &sh, opts.observer, step, res, num, try std.fmt.allocPrint(arena, "could not evaluate the checkout inputs: {s}", .{ev.diag}), coe);
                    continue;
                };
                const co = switch (try job_mod.checkoutFromInputs(arena, rendered)) {
                    .ok => |c| c,
                    .unsupported => |why| {
                        try failStep(&ev, &sh, opts.observer, step, res, num, why, coe);
                        continue;
                    },
                };
                const f = try fetchCheckout(arena, transport, job, co);
                if (f.result == .failed) {
                    try failStep(&ev, &sh, opts.observer, step, res, num, f.result.failed, coe);
                    continue;
                }
                resolved = .{ .checkout = f };
                mount_buf[0] = .{ .path = f.mount, .dir = f.result.dir };
                mounts = &mount_buf;
            },
            .uses => |u| {
                res.started_ms = std.Io.Clock.real.now(io).toMilliseconds();
                if (opts.observer) |o| o.started(num, res.name, res.started_ms);
                const out = x.runAction(num, u, sc1, plain_step_env.items, secret_step_env.items) catch |e| switch (e) {
                    error.EngineFailed => return engineFailed(&x, opts.observer, res, num, coe, results),
                    else => return e,
                };
                res.completed_ms = std.Io.Clock.real.now(io).toMilliseconds();
                res.outcome = if (out.failed) .failure else .success;
                res.exit_code = out.exit_code;
                try ev.record(step, res.outcome, coe, out.outputs);
                if (res.outcome == .failure and !coe) ev.job_failed = true;
                if (opts.observer) |o| o.finished(num, res.*);
                continue;
            },
        }

        res.started_ms = std.Io.Clock.real.now(io).toMilliseconds();
        if (opts.observer) |o| o.started(num, res.name, res.started_ms);
        const out = x.execScript(num, num, resolved, if (step.context_name.len > 0) step.context_name else step.id, secret_step_env.items, mounts) catch |e| switch (e) {
            error.EngineFailed => return engineFailed(&x, opts.observer, res, num, coe, results),
            else => return e,
        };
        res.completed_ms = std.Io.Clock.real.now(io).toMilliseconds();
        res.exit_code = out.code;
        res.outcome = if (out.code == 0) .success else .failure;
        try ev.record(step, res.outcome, coe, out.outputs);
        if (res.outcome == .failure and !coe) ev.job_failed = true;
        if (opts.observer) |o| o.finished(num, res.*);
    }
    return finish(arena, &sh, results, "");
}

/// A directory mounted into the container for one exec.
const Mount = struct { path: []const u8, dir: []const u8 };

/// What running steps needs, shared by the job's own steps and the steps of composite actions.
const Exec = struct {
    arena: Allocator,
    io: std.Io,
    transport: Transport,
    sh: *Shared,
    ev: *Evaluator,
    job: *const job_mod.Job,
    /// The container after the last exec; each exec starts from it.
    container_id: []const u8,
    /// What Dagger said when a query failed.
    err_msg: []const u8 = "",
    secret_counter: u32,
    /// File-command ids for the steps of composite actions, after the job's own step numbers.
    next_fc: u32,
    /// Steps may use the job's Dagger engine (see `Options.nesting`).
    nesting: bool,

    const ExecOut = struct { code: i32, outputs: []const job_mod.EnvVar };

    /// Runs one script in the job's container, logging as step `num`, and applies its file
    /// commands. `error.EngineFailed` (with `err_msg`) when Dagger itself failed.
    fn execScript(x: *Exec, num: u32, fc: u32, resolved: Resolved, action_name: []const u8, secret_env: []const SecretRef, mounts: []const Mount) !ExecOut {
        const arena = x.arena;
        const ev = x.ev;
        const script = try stepScriptFc(arena, num, fc, resolved, action_name);
        var doc: std.Io.Writer.Allocating = .init(arena);
        const w = &doc.writer;
        try w.writeAll("{ loadContainerFromID(id:");
        try std.json.Stringify.value(x.container_id, .{}, w);
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
        braces += try writeEnvNodes(w, &.{}, secret_env);
        for (mounts) |m| {
            try w.writeAll("withDirectory(path:");
            try std.json.Stringify.value(m.path, .{}, w);
            try w.writeAll(",source:");
            try std.json.Stringify.value(m.dir, .{}, w);
            try w.writeAll(") { ");
            braces += 1;
        }
        try w.writeAll("withExec(args:");
        try std.json.Stringify.value([_][]const u8{ "sh", "-c", script }, .{}, w);
        // Nesting gives the step's `dagger` CLI a session on this engine, sharing its cache.
        try w.writeAll(if (x.nesting) ",expect:ANY,experimentalPrivilegedNesting:true) { id exitCode stdout stderr" else ",expect:ANY) { id exitCode stdout stderr");
        for ([_][]const u8{ "output", "env", "path" }) |kind| {
            try w.print(" fc_{s}: file(path:\"{s}\") {{ contents }}", .{ kind, try fcPath(arena, kind, fc) });
        }
        try w.writeAll(" }");
        for (0..braces) |_| try w.writeAll(" }");

        const data = gql(arena, x.transport, doc.written(), &x.err_msg) catch return error.EngineFailed;
        var code: i32 = if (jsonFind(data, "exitCode")) |c| (if (c == .integer) @intCast(c.integer) else 1) else 1;
        if (jsonFindString(data, "id")) |id| x.container_id = id;

        // A cached step prints no log lines. Wait briefly for a live stream, then replay the result.
        awaitLiveOrReplay(x.io, x.sh, num, jsonFindString(data, "stdout") orelse "", jsonFindString(data, "stderr") orelse "");

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
                    x.sh.append(num, try std.fmt.allocPrint(arena, "Warning: ignored GITHUB_ENV entry '{s}' (reserved name)", .{e.name}));
                    continue;
                }
                try Evaluator.putEnv(arena, &ev.job_env, e.name, e.value);
                try ev.pending_env.append(arena, e);
            },
            .invalid => |why| cmd_error = try std.fmt.allocPrint(arena, "Unable to process the GITHUB_ENV file command: {s}", .{why}),
        };
        if (fileCommand(data, "fc_path")) |text| for (try commands.parsePaths(arena, text)) |dir| try ev.pending_path.append(arena, dir);
        if (cmd_error) |msg| {
            x.sh.append(num, msg);
            if (code == 0) code = 1;
        }
        return .{ .code = code, .outputs = outputs };
    }

    const ActionOut = struct { failed: bool, exit_code: i32 = 0, outputs: []const job_mod.EnvVar = &.{} };

    fn actionFailed(x: *Exec, num: u32, comptime fmt: []const u8, args: anytype) !ActionOut {
        x.sh.append(num, try std.fmt.allocPrint(x.arena, fmt, args));
        return .{ .failed = true, .exit_code = 1 };
    }

    /// Runs a `uses:` step: reads the action's metadata and, for a composite action, runs its steps
    /// as part of step `num`. `caller` is the scope of the `uses:` step (for `with:` and defaults);
    /// `step_env` and `step_secret` are its evaluated `env:`, which its steps inherit.
    fn runAction(x: *Exec, num: u32, u: job_mod.Uses, caller: expr.Scope, step_env: []const job_mod.EnvVar, step_secret: []const SecretRef) !ActionOut {
        const arena = x.arena;
        const ev = x.ev;
        const act = switch (try x.loadAction(u)) {
            .failed => |msg| return x.actionFailed(num, "{s}", .{msg}),
            .ok => |a| a,
        };
        const steps = switch (act.meta.runs) {
            .composite => |st| st,
            .node => |nd| return x.actionFailed(num, "{s} is a JavaScript action ({s}); JavaScript actions are not supported yet", .{ act.ref_label, nd.using }),
            .docker => return x.actionFailed(num, "{s} is a Docker action; Docker actions are not supported yet", .{act.ref_label}),
        };

        // Inputs: the step's `with:` values, else the defaults, evaluated where the `uses:` step is.
        var inputs: std.ArrayList(expr.Value.Entry) = .empty;
        for (act.meta.inputs) |def| {
            var val: []const u8 = "";
            if (findInput(u.inputs, def.name)) |t| {
                ev.diag = "";
                val = ev.render(t, caller) catch return x.actionFailed(num, "could not evaluate input '{s}': {s}", .{ def.name, ev.diag });
            } else if (def.default) |d| {
                ev.diag = "";
                val = expr.interpolate(arena, d, caller) catch return x.actionFailed(num, "could not evaluate the default of input '{s}': {s}", .{ def.name, ev.diag });
            }
            try inputs.append(arena, .{ .key = def.name, .value = .{ .string = val } });
        }
        // Like GitHub: warn about inputs the action does not declare, and pass them on anyway.
        var unexpected: std.ArrayList([]const u8) = .empty;
        for (u.inputs) |in| if (act.meta.input(in.name) == null) {
            try unexpected.append(arena, in.name);
            const val = ev.render(in.value, caller) catch "";
            try inputs.append(arena, .{ .key = in.name, .value = .{ .string = val } });
        };
        if (unexpected.items.len > 0) {
            var valid: std.ArrayList([]const u8) = .empty;
            for (act.meta.inputs) |def| try valid.append(arena, def.name);
            x.sh.append(num, try std.fmt.allocPrint(arena, "Warning: Unexpected input(s) '{s}', valid inputs are ['{s}']", .{
                try std.mem.join(arena, "', '", unexpected.items), try std.mem.join(arena, "', '", valid.items),
            }));
        }

        // The action's steps see its own `inputs` and `steps`, and `github.action_path`; the job's come
        // back afterwards. GITHUB_ENV and GITHUB_PATH changes outlive the action, as on GitHub.
        const saved_steps = ev.steps;
        const saved_inputs = ev.inputs;
        const saved_github = ev.github;
        const saved_failed = ev.job_failed;
        defer {
            ev.steps = saved_steps;
            ev.inputs = saved_inputs;
            ev.github = saved_github;
            ev.job_failed = saved_failed;
        }
        const repository = try std.fmt.allocPrint(arena, "{s}/{s}", .{ u.owner, u.name });
        ev.steps = .empty;
        ev.inputs = .{ .object = inputs.items };
        ev.github = try withEntries(arena, ev.github, &.{
            .{ .key = "action_path", .value = .{ .string = act.path } },
            .{ .key = "action_repository", .value = .{ .string = repository } },
            .{ .key = "action_ref", .value = .{ .string = u.ref } },
        });
        ev.job_failed = false;
        const action_env = [_]job_mod.EnvVar{
            .{ .name = "GITHUB_ACTION_PATH", .value = act.path },
            .{ .name = "GITHUB_ACTION_REPOSITORY", .value = repository },
            .{ .name = "GITHUB_ACTION_REF", .value = u.ref },
        };

        var failed = false;
        var exit_code: i32 = 0;
        var mounted = false;
        for (steps, 1..) |st, i| {
            const ctx_id = st.id orelse try std.fmt.allocPrint(arena, "__{d}", .{i});
            ev.diag = "";
            // The step's env is evaluated with the `uses:` step's env visible, then added to it.
            const sc_env = try ev.scope(step_env);
            var nested_env: std.ArrayList(job_mod.EnvVar) = .empty;
            var env_error: ?[]const u8 = null;
            for (st.env) |e| {
                const v = expr.interpolate(arena, e.value, sc_env) catch {
                    env_error = try std.fmt.allocPrint(arena, "could not evaluate env '{s}': {s}", .{ e.name, ev.diag });
                    break;
                };
                try nested_env.append(arena, .{ .name = e.name, .value = v });
            }
            const all_env = try std.mem.concat(arena, job_mod.EnvVar, &.{ step_env, nested_env.items });
            const sc = try ev.scope(all_env);
            var display = if (st.name) |nm| (expr.interpolate(arena, nm, sc) catch nm) else if (st.run) |r| firstLine(r) else st.uses orelse "";
            if (env_error) |msg| {
                try x.nestedFailed(num, ctx_id, display, msg, &failed, &exit_code);
                continue;
            }

            const cond = st.condition orelse "success()";
            const go = expr.evalCondition(arena, cond, sc) catch {
                try x.nestedFailed(num, ctx_id, display, try std.fmt.allocPrint(arena, "could not evaluate the condition '{s}': {s}", .{ cond, ev.diag }), &failed, &exit_code);
                continue;
            };
            if (!go) {
                try ev.steps.append(arena, .{ .id = ctx_id, .outcome = "skipped", .conclusion = "skipped", .outputs = &.{} });
                continue;
            }
            const coe = if (st.continue_on_error) |c| std.mem.eql(u8, expr.interpolate(arena, c, sc) catch "false", "true") else false;
            const run_text = st.run orelse {
                try x.nestedFailed(num, ctx_id, display, try std.fmt.allocPrint(arena, "uses: {s} inside a composite action is not supported yet", .{st.uses.?}), &failed, &exit_code);
                continue;
            };
            const script = expr.interpolate(arena, run_text, sc) catch {
                try x.nestedFailed(num, ctx_id, display, try std.fmt.allocPrint(arena, "could not evaluate the script: {s}", .{ev.diag}), &failed, &exit_code);
                continue;
            };
            // Without a name, the step is shown by its command as it will run.
            if (st.name == null) display = firstLine(script);
            const shell = expr.interpolate(arena, st.shell.?, sc) catch st.shell.?;
            if (!job_mod.validShell(shell)) {
                try x.nestedFailed(num, ctx_id, display, try std.fmt.allocPrint(arena, "unsupported shell '{s}' (v0 supports bash and sh)", .{shell}), &failed, &exit_code);
                continue;
            }
            const wd: ?[]const u8 = if (st.working_directory) |d| (expr.interpolate(arena, d, sc) catch d) else null;

            // Env that carries a secret goes in as a Dagger secret, the rest in the script.
            var plain: std.ArrayList(job_mod.EnvVar) = .empty;
            var secret: std.ArrayList(SecretRef) = .empty;
            try plain.appendSlice(arena, step_env);
            try secret.appendSlice(arena, step_secret);
            splitEnv(arena, x.transport, x.job.*, &x.secret_counter, nested_env.items, &plain, &secret, &x.err_msg) catch return error.EngineFailed;
            try plain.appendSlice(arena, &action_env);

            // As the official runner does: the command, folded away, then its output.
            x.sh.append(num, try std.fmt.allocPrint(arena, "##[group]Run {s}", .{display}));
            var lines = std.mem.splitScalar(u8, std.mem.trimEnd(u8, script, "\n"), '\n');
            while (lines.next()) |l| x.sh.append(num, l);
            x.sh.append(num, "##[endgroup]");

            // The action's files are mounted once; its steps may change them, as on GitHub.
            const m = [_]Mount{.{ .path = act.mount, .dir = act.dir }};
            const fc = x.next_fc;
            x.next_fc += 1;
            // All the action's scripts log as step `num`: after the first, count each one's lines afresh,
            // so a cached one is still replayed.
            if (mounted) {
                x.sh.live_lines[num - 1].store(0, .monotonic);
                x.sh.ended[num - 1].store(false, .release);
            }
            const out = try x.execScript(num, fc, .{ .run = .{ .script = script, .shell = shell, .working_directory = wd, .env = plain.items } }, ctx_id, secret.items, if (mounted) &.{} else &m);
            mounted = true;
            const ok = out.code == 0;
            try ev.steps.append(arena, .{ .id = ctx_id, .outcome = if (ok) "success" else "failure", .conclusion = if (ok or coe) "success" else "failure", .outputs = out.outputs });
            if (!ok and !coe) {
                failed = true;
                ev.job_failed = true;
                if (exit_code == 0) exit_code = out.code;
            }
        }

        // The action's outputs, evaluated against its own steps.
        const sc_out = try ev.scope(step_env);
        const outputs = try arena.alloc(job_mod.EnvVar, act.meta.outputs.len);
        for (act.meta.outputs, outputs) |o, *dst| dst.* = .{ .name = o.name, .value = expr.interpolate(arena, o.value, sc_out) catch "" };
        return .{ .failed = failed, .exit_code = exit_code, .outputs = outputs };
    }

    /// Logs why one of a composite action's steps could not run, and fails the action.
    fn nestedFailed(x: *Exec, num: u32, ctx_id: []const u8, display: []const u8, msg: []const u8, failed: *bool, exit_code: *i32) !void {
        x.sh.append(num, try std.fmt.allocPrint(x.arena, "##[error]{s}: {s}", .{ display, msg }));
        try x.ev.steps.append(x.arena, .{ .id = ctx_id, .outcome = "failure", .conclusion = "failure", .outputs = &.{} });
        failed.* = true;
        x.ev.job_failed = true;
        if (exit_code.* == 0) exit_code.* = 1;
    }

    const Loaded = struct {
        meta: action.Metadata,
        /// Dagger Directory id of the action's repository.
        dir: []const u8,
        /// Where the repository is mounted, and the action's own directory inside it.
        mount: []const u8,
        path: []const u8,
        /// `owner/repo[/path]@ref`, for messages.
        ref_label: []const u8,
    };

    /// Fetches the action's repository (Dagger's git support, cached by the engine) and reads its
    /// `action.yml` or `action.yaml`.
    fn loadAction(x: *Exec, u: job_mod.Uses) !union(enum) { ok: Loaded, failed: []const u8 } {
        const arena = x.arena;
        const sub = if (u.path.len > 0) try std.fmt.allocPrint(arena, "/{s}", .{u.path}) else "";
        const ref_label = try std.fmt.allocPrint(arena, "{s}/{s}{s}@{s}", .{ u.owner, u.name, sub, u.ref });
        const url = try std.fmt.allocPrint(arena, "{s}/{s}/{s}.git", .{ std.mem.trimEnd(u8, x.job.github.server_url, "/"), u.owner, u.name });

        var doc: std.Io.Writer.Allocating = .init(arena);
        const w = &doc.writer;
        try w.writeAll("{ git(url:");
        try std.json.Stringify.value(url, .{}, w);
        try w.writeAll(") { ");
        try w.writeAll(if (isSha(u.ref)) "commit(id:" else "ref(name:");
        try std.json.Stringify.value(u.ref, .{}, w);
        try w.writeAll(") { tree(depth:1) { id entries(path:");
        try std.json.Stringify.value(if (u.path.len > 0) u.path else ".", .{}, w);
        try w.writeAll(") } } } }");
        var msg: []const u8 = "";
        const data = gql(arena, x.transport, doc.written(), &msg) catch
            return .{ .failed = try std.fmt.allocPrint(arena, "could not fetch {s}: {s}{s}", .{
                ref_label, msg, if (looksLikeAuthFailure(msg)) " (private repositories are not supported in v0)" else "",
            }) };
        const dir = jsonFindString(data, "id") orelse return .{ .failed = try std.fmt.allocPrint(arena, "could not fetch {s}: Dagger returned no tree", .{ref_label}) };
        var file_name: ?[]const u8 = null;
        if (jsonFind(data, "entries")) |entries| if (entries == .array) for (entries.array.items) |e| {
            if (e != .string) continue;
            if (std.mem.eql(u8, e.string, "action.yml") or (file_name == null and std.mem.eql(u8, e.string, "action.yaml"))) file_name = e.string;
        };
        const name = file_name orelse return .{ .failed = try std.fmt.allocPrint(arena, "{s} has no action.yml or action.yaml", .{ref_label}) };

        doc = .init(arena);
        const w2 = &doc.writer;
        try w2.writeAll("{ loadDirectoryFromID(id:");
        try std.json.Stringify.value(dir, .{}, w2);
        try w2.writeAll(") { file(path:");
        try std.json.Stringify.value(if (u.path.len > 0) try std.fmt.allocPrint(arena, "{s}/{s}", .{ u.path, name }) else name, .{}, w2);
        try w2.writeAll(") { contents } } }");
        const fdata = gql(arena, x.transport, doc.written(), &msg) catch
            return .{ .failed = try std.fmt.allocPrint(arena, "could not read {s} of {s}: {s}", .{ name, ref_label, msg }) };
        const text = jsonFindString(fdata, "contents") orelse return .{ .failed = try std.fmt.allocPrint(arena, "could not read {s} of {s}", .{ name, ref_label }) };

        const meta = switch (try action.parse(arena, text)) {
            .ok => |m| m,
            .invalid => |why| return .{ .failed = try std.fmt.allocPrint(arena, "{s} of {s} {s}", .{ name, ref_label, why }) },
        };
        const mount = try std.fmt.allocPrint(arena, "/github/_actions/{s}/{s}/{s}", .{ u.owner, u.name, u.ref });
        return .{ .ok = .{
            .meta = meta,
            .dir = dir,
            .mount = mount,
            .path = if (u.path.len > 0) try std.fmt.allocPrint(arena, "{s}/{s}", .{ mount, u.path }) else mount,
            .ref_label = ref_label,
        } };
    }
};

fn findInput(inputs: []const job_mod.Input, name: []const u8) ?job_mod.Template {
    for (inputs) |in| if (std.ascii.eqlIgnoreCase(in.name, name)) return in.value;
    return null;
}

/// `base` (an object, or null) with `extra` entries added or replaced.
fn withEntries(arena: Allocator, base: expr.Value, extra: []const expr.Value.Entry) !expr.Value {
    var list: std.ArrayList(expr.Value.Entry) = .empty;
    if (base == .object) for (base.object) |e| {
        var replaced = false;
        for (extra) |x| if (std.ascii.eqlIgnoreCase(x.key, e.key)) {
            replaced = true;
        };
        if (!replaced) try list.append(arena, e);
    };
    try list.appendSlice(arena, extra);
    return .{ .object = list.items };
}

fn firstLine(s: []const u8) []const u8 {
    const t = std.mem.trim(u8, s, " \n\r\t");
    return t[0 .. std.mem.indexOfScalar(u8, t, '\n') orelse t.len];
}

/// Dagger itself failed during a step: the step and the job fail with what Dagger said.
fn engineFailed(x: *Exec, observer: ?Observer, res: *StepResult, num: u32, coe: bool, results: []StepResult) !Result {
    res.* = .{ .name = res.name, .continued = coe, .outcome = .failure, .exit_code = 1, .started_ms = res.started_ms, .completed_ms = std.Io.Clock.real.now(x.io).toMilliseconds() };
    x.sh.append(num, try std.fmt.allocPrint(x.arena, "Dagger error: {s}", .{x.err_msg}));
    if (observer) |o| o.finished(num, res.*);
    return finish(x.arena, x.sh, results, x.err_msg);
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
fn failStep(ev: *Evaluator, sh: *Shared, observer: ?Observer, step: job_mod.Step, res: *StepResult, num: u32, msg: []const u8, coe: bool) !void {
    sh.append(num, msg);
    const name = res.name;
    res.* = .{ .name = name, .continued = coe, .outcome = .failure, .exit_code = 1 };
    try ev.record(step, .failure, coe, &.{});
    if (!coe) ev.job_failed = true;
    if (observer) |o| o.finished(num, res.*);
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
    try std.testing.expectEqualStrings("{ git(url:\"https://github.com/o/r.git\",keepGitDir:true) { ref(name:\"refs/pull/7/merge\") { tree(depth:0) { id } } } }", by_ref);
    const tags = (try checkoutQuery(a.allocator(), job, .{ .fetch_tags = true })).doc;
    try std.testing.expect(std.mem.indexOf(u8, tags, "tree(depth:1,includeTags:true) { id }") != null);
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
        \\ "variables":{"TOKEN":{"value":"s3cr3t-value","isSecret":true}},
        \\ "environmentVariables":[{"type":2,"map":[{"Key":{"lit":"JOB_ENV"},"Value":{"type":3,"expr":"format('{0}-job', github.ref_name)"}},{"Key":{"lit":"JOB_SECRET"},"Value":{"type":3,"expr":"secrets.TOKEN"}}]}],
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
        \\   "environment":{"type":2,"map":[{"Key":{"lit":"DB_PASSWORD"},"Value":{"type":3,"expr":"secrets.TOKEN"}},{"Key":{"lit":"WITH_SECRET"},"Value":{"type":3,"expr":"format('user:{0}@host', secrets.TOKEN)"}}]},
        \\   "inputs":{"type":2,"map":[{"Key":{"lit":"script"},"Value":{"lit":"echo uses-secret-env"}}]}},
        \\  {"type":"action","reference":{"type":"script"},"id":"s6","contextName":"__run_5","name":"__run_5","condition":"always()",
        \\   "inputs":{"type":2,"map":[{"Key":{"lit":"script"},"Value":{"lit":"echo cleanup"}}]}}
        \\ ]}
    ;
    const job = try job_mod.parse(arena, json);
    const answers = [_][]const u8{
        "{\"data\":{\"setSecret\":{\"id\":\"SEC_JOB\"}}}", // JOB_SECRET (job-level env), before the base container
        base_answer,
        try exec(arena, "C1", 0, "ok\\n"),
        try exec(arena, "C2", 0, "ok\\n"),
        try exec(arena, "C3", 0, "ok\\n"),
        "{\"data\":{\"setSecret\":{\"id\":\"SEC_A\"}}}", // DB_PASSWORD
        "{\"data\":{\"setSecret\":{\"id\":\"SEC_B\"}}}", // WITH_SECRET
        try exec(arena, "C4", 0, "ok\\n"),
        try exec(arena, "C5", 0, "ok\\n"),
    };
    var fake: FakeSession = .{ .answers = &answers, .arena = arena };
    var buf: [4096]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buf);
    var log: sink.LogSink = .{ .stdout = .{ .writer = &w } };
    const res = try run(arena, std.testing.io, &env, .{ .test_session_argv = &.{ "sh", "-c", fake_child }, .test_transport = fake.transport() }, job, &log);

    // Names and outcomes.
    try std.testing.expectEqualStrings("Build main", res.steps[0].name);
    try std.testing.expectEqual(Outcome.success, res.steps[0].outcome);
    try std.testing.expectEqual(Outcome.success, res.steps[1].outcome);
    try std.testing.expectEqual(Outcome.skipped, res.steps[2].outcome); // condition false
    try std.testing.expectEqual(Outcome.success, res.steps[3].outcome);
    try std.testing.expectEqual(Outcome.success, res.steps[4].outcome);
    try std.testing.expectEqual(Outcome.success, res.steps[5].outcome);
    try std.testing.expect(res.succeeded);
    for (fake.seen.items) |d| try std.testing.expect(braceBalanced(d));
    // seen: 0 setSecret(job), 1 base, 2 s1, 3 s2, 4 s4, 5 setSecret, 6 setSecret, 7 s5, 8 s6
    try std.testing.expectEqual(@as(usize, 9), fake.seen.items.len);
    // Evaluated scripts reached Dagger: sha, step env, job env (from an expression), steps.* outcomes.
    try std.testing.expect(std.mem.indexOf(u8, fake.seen.items[2], "echo abc123 $STEP_ENV main-job") != null);
    try std.testing.expect(std.mem.indexOf(u8, fake.seen.items[2], "STEP_ENV=abc123") != null);
    try std.testing.expect(std.mem.indexOf(u8, fake.seen.items[4], "echo outcome=success skipped=skipped") != null);
    // Job-level env is part of the base container: the plain value inline, the secret as a Dagger secret.
    try std.testing.expect(std.mem.indexOf(u8, fake.seen.items[1], "withEnvVariable(name:\"JOB_ENV\",value:\"main-job\")") != null);
    try std.testing.expect(std.mem.indexOf(u8, fake.seen.items[1], "withSecretVariable(name:\"JOB_SECRET\",secret:\"SEC_JOB\")") != null);
    // Secret-bearing step env is passed as Dagger secrets and appears nowhere in a command.
    try std.testing.expect(std.mem.indexOf(u8, fake.seen.items[7], "withSecretVariable(name:\"DB_PASSWORD\",secret:\"SEC_A\")") != null);
    try std.testing.expect(std.mem.indexOf(u8, fake.seen.items[7], "withSecretVariable(name:\"WITH_SECRET\",secret:\"SEC_B\")") != null);
    for (fake.seen.items, 0..) |d, i| {
        const is_set_secret = std.mem.indexOf(u8, d, "setSecret") != null;
        try std.testing.expectEqual(is_set_secret, std.mem.indexOf(u8, d, "s3cr3t-value") != null);
        _ = i;
    }
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

test "the default image is provisioned with git; a custom image is left alone" {
    var a: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer a.deinit();
    const arena = a.allocator();
    var env: std.process.Environ.Map = .init(arena);
    const steps = [_]job_mod.Step{testStep("true")};
    for ([_]struct { image: []const u8, expect_provision: bool }{
        .{ .image = default_image, .expect_provision = true },
        .{ .image = "custom/image:1", .expect_provision = false },
    }) |case| {
        const answers = [_][]const u8{ base_answer, try exec(arena, "C1", 0, "") };
        var fake: FakeSession = .{ .answers = &answers, .arena = arena };
        var buf: [512]u8 = undefined;
        var w: std.Io.Writer = .fixed(&buf);
        var log: sink.LogSink = .{ .stdout = .{ .writer = &w } };
        _ = try run(arena, std.testing.io, &env, .{ .image = case.image, .test_session_argv = &.{ "sh", "-c", fake_child }, .test_transport = fake.transport() }, testJob(&steps), &log);
        const base = fake.seen.items[0];
        try std.testing.expect(braceBalanced(base));
        try std.testing.expectEqual(case.expect_provision, std.mem.indexOf(u8, base, "apt-get install") != null);
        try std.testing.expect(std.mem.indexOf(u8, base, case.image) != null);
    }
}

const Recorder = struct {
    events: std.ArrayList([]const u8) = .empty,
    arena: Allocator,

    fn started(ptr: *anyopaque, number: u32, name: []const u8, started_ms: i64) void {
        const self: *Recorder = @ptrCast(@alignCast(ptr));
        const msg = std.fmt.allocPrint(self.arena, "start {d} {s} {s}", .{ number, name, if (started_ms > 0) "t" else "-" }) catch return;
        self.events.append(self.arena, msg) catch {};
    }

    fn finished(ptr: *anyopaque, number: u32, r: StepResult) void {
        const self: *Recorder = @ptrCast(@alignCast(ptr));
        const msg = std.fmt.allocPrint(self.arena, "finish {d} {s} {s}", .{ number, r.name, @tagName(r.outcome) }) catch return;
        self.events.append(self.arena, msg) catch {};
    }
};

test "the observer sees each step start and finish, including skipped and failed-to-evaluate steps" {
    var a: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer a.deinit();
    const arena = a.allocator();
    var env: std.process.Environ.Map = .init(arena);
    var s2 = testStep("never");
    s2.condition = "failure()";
    var s3 = testStep("x");
    s3.action = .{ .unsupported = "not supported here" };
    const steps = [_]job_mod.Step{ testStep("ok"), s2, s3, testStep("bad") };
    const answers = [_][]const u8{ base_answer, try exec(arena, "C1", 0, "a\\n"), try exec(arena, "C2", 1, "b\\n") };
    var fake: FakeSession = .{ .answers = &answers, .arena = arena };
    var rec: Recorder = .{ .arena = arena };
    var buf: [1024]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buf);
    var log: sink.LogSink = .{ .stdout = .{ .writer = &w } };
    // step 3 is unsupported (fails without running); step 4 is skipped by success() afterwards.
    _ = try run(arena, std.testing.io, &env, .{
        .test_session_argv = &.{ "sh", "-c", fake_child },
        .test_transport = fake.transport(),
        .observer = .{ .ptr = &rec, .startedFn = Recorder.started, .finishedFn = Recorder.finished },
    }, testJob(&steps), &log);

    const want = [_][]const u8{
        "start 1 n t", // the step has begun, with a start time
        "finish 1 n success",
        "finish 2 n skipped", // failure() was false: reported once, never "started"
        "finish 3 n failure", // unsupported: reported once, never "started"
        "finish 4 n skipped", // success() after a failure
    };
    try std.testing.expectEqual(want.len, rec.events.items.len);
    for (want, rec.events.items) |expected, got| try std.testing.expectEqualStrings(expected, got);
}

// --- composite actions ---

fn treeAnswer(arena: Allocator, dir: []const u8, entries: []const []const u8) ![]const u8 {
    var aw: std.Io.Writer.Allocating = .init(arena);
    try aw.writer.print("{{\"data\":{{\"git\":{{\"ref\":{{\"tree\":{{\"id\":\"{s}\",\"entries\":", .{dir});
    try std.json.Stringify.value(entries, .{}, &aw.writer);
    try aw.writer.writeAll("}}}}}");
    return aw.written();
}

fn fileAnswer(arena: Allocator, contents: []const u8) ![]const u8 {
    var aw: std.Io.Writer.Allocating = .init(arena);
    try aw.writer.writeAll("{\"data\":{\"loadDirectoryFromID\":{\"file\":{\"contents\":");
    try std.json.Stringify.value(contents, .{}, &aw.writer);
    try aw.writer.writeAll("}}}}");
    return aw.written();
}

fn usesStep(id: []const u8, owner: []const u8, name: []const u8, ref: []const u8, inputs: []const job_mod.Input) job_mod.Step {
    return .{ .id = id, .context_name = id, .name = "uses", .condition = "success()", .action = .{ .uses = .{ .owner = owner, .name = name, .ref = ref, .inputs = inputs } } };
}

test "a composite action runs its steps with its inputs, and its outputs reach later steps" {
    var a: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer a.deinit();
    const arena = a.allocator();
    var env: std.process.Environ.Map = .init(arena);

    const action_yml =
        \\inputs:
        \\  version:
        \\    default: latest
        \\  verb:
        \\    default: call
        \\outputs:
        \\  out:
        \\    value: ${{ steps.second.outputs.result }}-${{ inputs.version }}
        \\runs:
        \\  using: composite
        \\  steps:
        \\    - shell: bash
        \\      run: echo v=${{ inputs.version }} verb=${{ inputs.verb }} path=${{ github.action_path }}
        \\    - id: skipped
        \\      if: inputs.verb == 'nope'
        \\      shell: bash
        \\      run: echo never
        \\    - id: second
        \\      shell: sh
        \\      env:
        \\        X: ${{ inputs.version }}
        \\      run: echo "result=ok" >> "$GITHUB_OUTPUT"
    ;
    const inputs = [_]job_mod.Input{ .{ .name = "version", .value = .{ .lit = "0.21.10" } }, .{ .name = "bogus", .value = .{ .lit = "1" } } };
    var after = testStep("");
    after.action.script.script = .{ .expr = "format('echo {0}', steps.dag.outputs.out)" };
    const steps = [_]job_mod.Step{ usesStep("dag", "o", "act", "v1", &inputs), after };
    const answers = [_][]const u8{
        base_answer,
        try treeAnswer(arena, "D1", &.{ "README.md", "action.yml" }),
        try fileAnswer(arena, action_yml),
        try exec(arena, "C1", 0, ""),
        try execFc(arena, "C2", "", "result=ok\\n", "", ""),
        try exec(arena, "C3", 0, ""),
    };
    var fake: FakeSession = .{ .answers = &answers, .arena = arena };
    var buf: [8192]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buf);
    var log: sink.LogSink = .{ .stdout = .{ .writer = &w } };
    const res = try run(arena, std.testing.io, &env, .{ .test_session_argv = &.{ "sh", "-c", fake_child }, .test_transport = fake.transport() }, testJob(&steps), &log);

    try std.testing.expect(res.succeeded);
    try std.testing.expectEqual(Outcome.success, res.steps[0].outcome);
    const seen = fake.seen.items;
    try std.testing.expectEqual(@as(usize, 6), seen.len); // the skipped step never runs
    for (seen) |d| try std.testing.expect(braceBalanced(d));
    try std.testing.expect(std.mem.indexOf(u8, seen[1], "git(url:\"https://github.com/o/act.git\") { ref(name:\"v1\") { tree(depth:1) { id entries(path:\".\")") != null);
    try std.testing.expect(std.mem.indexOf(u8, seen[2], "loadDirectoryFromID(id:\"D1\") { file(path:\"action.yml\")") != null);
    // First step: interpolated inputs (given and default) and action path; the action is mounted once.
    try std.testing.expect(std.mem.indexOf(u8, seen[3], "echo v=0.21.10 verb=call path=/github/_actions/o/act/v1") != null);
    try std.testing.expect(std.mem.indexOf(u8, seen[3], "withDirectory(path:\"/github/_actions/o/act/v1\",source:\"D1\")") != null);
    try std.testing.expect(std.mem.indexOf(u8, seen[3], "/github/file_commands/output_3") != null);
    try std.testing.expect(std.mem.indexOf(u8, seen[4], "withDirectory") == null);
    try std.testing.expect(std.mem.indexOf(u8, seen[4], "'X=0.21.10'") != null);
    try std.testing.expect(std.mem.indexOf(u8, seen[4], "'GITHUB_ACTION_PATH=/github/_actions/o/act/v1'") != null);
    try std.testing.expect(std.mem.indexOf(u8, seen[4], "/github/file_commands/output_4") != null);
    // The action's output, built from its own step's output and input, reaches the next job step.
    try std.testing.expect(std.mem.indexOf(u8, seen[5], "echo ok-0.21.10") != null);
    const out = w.buffered();
    try std.testing.expect(std.mem.indexOf(u8, out, "Warning: Unexpected input(s) 'bogus', valid inputs are ['version', 'verb']") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "##[group]Run echo v=0.21.10") != null);
}

test "composite failures: JavaScript actions, a missing action.yml, and a failing step with failure() cleanup" {
    var a: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer a.deinit();
    const arena = a.allocator();
    var env: std.process.Environ.Map = .init(arena);

    const failing_yml =
        \\runs:
        \\  using: composite
        \\  steps:
        \\    - shell: bash
        \\      run: exit 3
        \\    - if: failure()
        \\      shell: bash
        \\      run: echo cleanup
        \\    - shell: bash
        \\      run: echo not after a failure
    ;
    var s2 = usesStep("missing", "o", "none", "v1", &.{});
    s2.condition = "always()";
    var s3 = usesStep("fails", "o", "act2", "0123456789012345678901234567890123456789", &.{});
    s3.condition = "always()";
    const steps = [_]job_mod.Step{ usesStep("js", "o", "js", "v1", &.{}), s2, s3 };
    const answers = [_][]const u8{
        base_answer,
        try treeAnswer(arena, "D1", &.{"action.yml"}),
        try fileAnswer(arena, "runs:\n  using: node24\n  main: dist/index.js\n"),
        try treeAnswer(arena, "D2", &.{"README.md"}),
        try treeAnswer(arena, "D3", &.{"action.yaml"}),
        try fileAnswer(arena, failing_yml),
        try exec(arena, "C1", 3, ""),
        try exec(arena, "C2", 0, ""),
    };
    var fake: FakeSession = .{ .answers = &answers, .arena = arena };
    var buf: [8192]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buf);
    var log: sink.LogSink = .{ .stdout = .{ .writer = &w } };
    const res = try run(arena, std.testing.io, &env, .{ .test_session_argv = &.{ "sh", "-c", fake_child }, .test_transport = fake.transport() }, testJob(&steps), &log);

    try std.testing.expect(!res.succeeded);
    try std.testing.expectEqual(Outcome.failure, res.steps[0].outcome);
    try std.testing.expectEqual(Outcome.failure, res.steps[1].outcome);
    try std.testing.expectEqual(Outcome.failure, res.steps[2].outcome);
    try std.testing.expectEqual(@as(i32, 3), res.steps[2].exit_code);
    const seen = fake.seen.items;
    try std.testing.expectEqual(@as(usize, 8), seen.len); // the step after the failure is skipped
    try std.testing.expect(std.mem.indexOf(u8, seen[4], "commit(id:\"0123456789012345678901234567890123456789\")") != null);
    try std.testing.expect(std.mem.indexOf(u8, seen[5], "file(path:\"action.yaml\")") != null);
    try std.testing.expect(std.mem.indexOf(u8, seen[7], "echo cleanup") != null);
    const out = w.buffered();
    try std.testing.expect(std.mem.indexOf(u8, out, "o/js@v1 is a JavaScript action (node24); JavaScript actions are not supported yet") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "o/none@v1 has no action.yml or action.yaml") != null);
}

test "steps get the engine (privileged nesting) unless it is turned off" {
    var a: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer a.deinit();
    const arena = a.allocator();
    var env: std.process.Environ.Map = .init(arena);
    const steps = [_]job_mod.Step{testStep("dagger call ci")};
    for ([_]bool{ true, false }) |nesting| {
        const answers = [_][]const u8{ base_answer, try exec(arena, "C1", 0, "") };
        var fake: FakeSession = .{ .answers = &answers, .arena = arena };
        var buf: [1024]u8 = undefined;
        var w: std.Io.Writer = .fixed(&buf);
        var log: sink.LogSink = .{ .stdout = .{ .writer = &w } };
        _ = try run(arena, std.testing.io, &env, .{ .nesting = nesting, .test_session_argv = &.{ "sh", "-c", fake_child }, .test_transport = fake.transport() }, testJob(&steps), &log);
        // The setup query (and its provisioning exec) never gets it; the step does when enabled.
        try std.testing.expect(std.mem.indexOf(u8, fake.seen.items[0], "experimentalPrivilegedNesting") == null);
        try std.testing.expectEqual(nesting, std.mem.indexOf(u8, fake.seen.items[1], ",expect:ANY,experimentalPrivilegedNesting:true)") != null);
        try std.testing.expect(braceBalanced(fake.seen.items[1]));
    }
}
