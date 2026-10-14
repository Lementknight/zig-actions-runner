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
const config = @import("config.zig");
const engine = @import("engine.zig");

const Allocator = std.mem.Allocator;

pub const default_image = "ubuntu:24.04";
pub const workspace = "/github/workspace";
pub const marker = "::zig-step::";

/// What the default image (`ubuntu:24.04`) gets before a job: what workflows written for GitHub's
/// `ubuntu-latest` most often assume without a setup action. `sudo` (steps run as root, but many call
/// `sudo apt-get`), compilers and `make`, Python with pip and venv (and `python`), `psql` for a
/// Postgres service, archive and transfer tools, and what composite actions often use (`jq`,
/// `curl`). Installed once per engine: Dagger caches this exec, so only the first job pays for it.
pub const provision_packages = [_][]const u8{
    "git",               "git-lfs",        "ca-certificates", "curl",        "wget",         "xz-utils",
    "bzip2",             "zstd",           "zip",             "unzip",       "jq",           "sudo",
    "gnupg",             "openssh-client", "rsync",           "file",        "lsb-release",  "tzdata",
    "build-essential",   "pkg-config",     "python3",         "python3-pip", "python3-venv", "python-is-python3",
    "postgresql-client", "netcat-openbsd", "procps",
};
pub const provision_script = "apt-get update -qq && DEBIAN_FRONTEND=noninteractive apt-get install -y -qq --no-install-recommends " ++ packageList() ++ " >/dev/null && rm -rf /var/lib/apt/lists/*";

fn packageList() []const u8 {
    comptime {
        var out: []const u8 = "";
        for (provision_packages, 0..) |p, n| out = out ++ (if (n == 0) "" else " ") ++ p;
        return out;
    }
}

pub const Marker = union(enum) {
    begin: u32,
    end: u32,
    /// The first line a service prints (see `startServices`): its output is service n's (0-based).
    service: u32,
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
    else if (std.mem.eql(u8, kind, "service"))
        .{ .service = step }
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
    /// The ref the checkout stands for (`refs/heads/main`, `refs/pull/7/merge`, a bare name from
    /// `with: ref:`), or null for a sha or a repository's default branch. See `checkoutRefCommands`.
    git_ref: ?[]const u8 = null,
    /// What was asked for, for the step's log: the URL, the ref or commit, the depth and tags.
    url: []const u8 = "",
    want: []const u8 = "",
    depth: u32 = 1,
    tags: bool = false,
};

/// A step with its expressions evaluated, ready to become a script.
pub const Resolved = union(enum) {
    run: struct {
        script: []const u8,
        /// `bash`, `sh`, or null for the default.
        shell: ?[]const u8,
        working_directory: ?[]const u8,
        env: []const job_mod.EnvVar,
        /// Names of env variables whose values are Dagger secrets. The `i`th arrives in the container as
        /// `ZIG_SECRET_<i>` and the script gives it its real name (any name works, see `secretAlias`).
        secret_env: []const []const u8 = &.{},
        /// Set for steps that must run every time (they use secrets or read run-specific values): a
        /// line with a per-run value, so the step never matches an earlier run's cache entry.
        always_run: ?[]const u8 = null,
        /// Write the event payload from the volatile ZIG_RUNNER_EVENT variable to GITHUB_EVENT_PATH.
        write_event: bool = false,
    },
    checkout: Fetched,
};

const fc_dir = "/github/file_commands";
/// GITHUB_STATE is written by JavaScript actions (`core.saveState`) for their post scripts.
const fc_kinds = [_][]const u8{ "output", "env", "path", "step_summary", "state" };

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
            if (sc.always_run) |why| {
                try w.writeAll(": ");
                try shellQuote(w, why);
                try w.writeByte('\n');
            }
            if (sc.write_event) try w.writeAll("if [ -n \"${" ++ event_env ++ "+x}\" ]; then mkdir -p " ++ event_dir ++ " && printf '%s' \"$" ++ event_env ++ "\" > " ++ event_path ++ "; fi\n");
            // The script is a file, as on GitHub: `$0`, BASH_SOURCE and error messages name it.
            const path = try scriptPath(arena, fc);
            try w.writeAll("printf '%s' ");
            try shellQuote(w, sc.script);
            try w.print(" > {s}\n", .{path});
            if (sc.shell == null) try w.writeAll("if command -v bash >/dev/null 2>&1; then zig_shell=bash; else zig_shell=sh; fi\n");
            try w.writeAll("( ");
            if (sc.working_directory) |wd| {
                try w.writeAll("cd ");
                try shellQuote(w, wd);
                try w.writeAll(" && ");
            }
            try writeEnvCommand(w, arena, "env ", sc.env, sc.secret_env, sc.write_event, fc, action_name);
            try writeShellCommand(w, arena, sc.shell, path);
            try w.writeAll(")\nrc=$?\n");
        },
        .checkout => |f| {
            // The tree is mounted by the query (`withDirectory`); the step reports it in the shape
            // actions/checkout's log has (the same folds, and the commit last), with what happened.
            for (try checkoutLog(arena, f)) |line| {
                try w.writeAll("printf '%s\\n' ");
                try shellQuote(w, line);
                try w.writeByte('\n');
            }
            if (f.git_ref) |ref| try w.writeAll(try checkoutRefCommands(arena, f.mount, ref));
            try w.writeAll("printf '%s\\n' '##[endgroup]'\n");
            // The commit, as actions/checkout ends (it runs the same git command).
            try w.writeAll("git -C ");
            try shellQuote(w, f.mount);
            try w.writeAll(" log -1 --format=%H 2>/dev/null\nrc=0\n");
        },
    }
    try w.writeAll("mkdir -p " ++ fc_dir ++ " && : ");
    for (fc_kinds) |k| try w.print(">> {s} ", .{try fcPath(arena, k, fc)});
    try w.writeByte('\n');
    try writeCombinedFileCommands(w, arena, "", fc);
    try w.print("echo '{s}end {d}'\nexit $rc\n", .{ marker, n });
    return aw.written();
}

/// After a step: its file commands in one file (`all_<fc>`), each after a `::zig-file-command::<kind>`
/// line and followed by one newline, so the query reads one file instead of one per kind (each
/// read mounts the step's snapshot in the engine). Only `cat` and `printf` are needed.
fn writeCombinedFileCommands(w: *std.Io.Writer, arena: Allocator, prefix: []const u8, fc: u32) !void {
    try w.writeAll("{ ");
    for (fc_kinds) |k| try w.print("printf '%s\\n' '" ++ fc_marker ++ "{s}'; {s}cat {s}; printf '\\n'; ", .{ k, prefix, try fcPath(arena, k, fc) });
    try w.print("}} > {s}\n", .{try fcPath(arena, "all", fc)});
}

const fc_marker = "::zig-file-command::";

/// GitHub's limit on composite actions inside composite actions.
const max_composite_depth = 9;

/// The list of files `hashFiles()` hashes, written next to the exec that hashes them.
const hash_list_path = "/tmp/zig-runner-hashfiles";

/// Where a Docker action's container gets its static busybox, and HOME (shared by the job's Docker
/// actions, as GitHub mounts one /github/home into each).
const busybox_image = "busybox:1.37.0-musl";
const busybox_path = "/github/_runtime/busybox";
const docker_home = "/github/home";

/// The busybox `sh -c` script that runs a Docker action's command `argv` as step `n`: as
/// `stepScriptFc`, with the image's command in place of a shell script, and busybox's own `mkdir`,
/// `printf` and `env` (the image may have none).
fn containerScript(arena: Allocator, n: u32, fc: u32, argv: []const []const u8, env: []const job_mod.EnvVar, secret_env: []const []const u8, always_run: ?[]const u8, write_event: bool, action_name: []const u8) ![]const u8 {
    var aw: std.Io.Writer.Allocating = .init(arena);
    const w = &aw.writer;
    try w.print("echo '{s}begin {d}'\nB=" ++ busybox_path ++ "\n\"$B\" mkdir -p " ++ fc_dir ++ " " ++ docker_home ++ " " ++ event_dir ++ " && : ", .{ marker, n });
    for (fc_kinds) |k| try w.print("> {s} ", .{try fcPath(arena, k, fc)});
    try w.writeByte('\n');
    if (always_run) |why| {
        try w.writeAll(": ");
        try shellQuote(w, why);
        try w.writeByte('\n');
    }
    if (write_event) try w.writeAll("if [ -n \"${" ++ event_env ++ "+x}\" ]; then \"$B\" printf '%s' \"$" ++ event_env ++ "\" > " ++ event_path ++ "; fi\n");
    try writeEnvCommand(w, arena, "\"$B\" env ", env, secret_env, write_event, fc, action_name);
    for (argv) |a| {
        try shellQuote(w, a);
        try w.writeByte(' ');
    }
    try w.writeAll("\nrc=$?\n: ");
    for (fc_kinds) |k| try w.print(">> {s} ", .{try fcPath(arena, k, fc)});
    try w.writeByte('\n');
    try writeCombinedFileCommands(w, arena, "\"$B\" ", fc);
    try w.print("echo '{s}end {d}'\nexit $rc\n", .{ marker, n });
    return aw.written();
}

/// Splits `with: args` of a `docker://` step into arguments as GitHub's runner does (it hands the
/// string to `docker run`): at whitespace, with double quotes grouping and `\"` a literal quote.
fn splitArgs(arena: Allocator, s: []const u8) ![]const []const u8 {
    var out: std.ArrayList([]const u8) = .empty;
    var cur: std.ArrayList(u8) = .empty;
    var in_arg = false;
    var quoted = false;
    var i: usize = 0;
    while (i < s.len) : (i += 1) {
        const c = s[i];
        if (c == '\\' and i + 1 < s.len and s[i + 1] == '"') {
            try cur.append(arena, '"');
            in_arg = true;
            i += 1;
        } else if (c == '"') {
            quoted = !quoted;
            in_arg = true;
        } else if (!quoted and std.ascii.isWhitespace(c)) {
            if (in_arg) try out.append(arena, try cur.toOwnedSlice(arena));
            in_arg = false;
        } else {
            try cur.append(arena, c);
            in_arg = true;
        }
    }
    if (in_arg) try out.append(arena, try cur.toOwnedSlice(arena));
    return out.items;
}

/// Inputs as INPUT_<NAME> (upper case, spaces as underscores, as `@actions/core` reads them).
fn inputEnv(arena: Allocator, inputs: []const expr.Value.Entry) ![]const job_mod.EnvVar {
    const out = try arena.alloc(job_mod.EnvVar, inputs.len);
    for (inputs, out) |in, *dst| {
        const name = try std.ascii.allocUpperString(arena, try std.mem.replaceOwned(u8, arena, in.key, " ", "_"));
        dst.* = .{ .name = try std.fmt.allocPrint(arena, "INPUT_{s}", .{name}), .value = in.value.string };
    }
    return out;
}

/// The inputs an action gets, for the log as GitHub shows them: every one with a value (given or
/// defaulted), in the action's order, then any it does not declare.
fn shownInputs(arena: Allocator, inputs: []const expr.Value.Entry) ![]const job_mod.EnvVar {
    var out: std.ArrayList(job_mod.EnvVar) = .empty;
    for (inputs) |in| if (in.value == .string and in.value.string.len > 0) {
        try out.append(arena, .{ .name = in.key, .value = in.value.string });
    };
    return out.items;
}

/// The strings of a JSON array (an image's entrypoint or command); empty for anything else.
fn jsonStrings(arena: Allocator, v: ?std.json.Value) ![]const []const u8 {
    const arr = v orelse return &.{};
    if (arr != .array) return &.{};
    var out: std.ArrayList([]const u8) = .empty;
    for (arr.array.items) |item| if (item == .string) try out.append(arena, item.string);
    return out.items;
}

/// `<env_cmd>-u <aliases> NAME=value ... GITHUB_OUTPUT=... GITHUB_ACTION=... `: what a step's command
/// starts with, so it gets its env (secret values expanded from their aliases, see `Resolved.run`).
fn writeEnvCommand(w: *std.Io.Writer, arena: Allocator, env_cmd: []const u8, env: []const job_mod.EnvVar, secret_env: []const []const u8, write_event: bool, fc: u32, action_name: []const u8) !void {
    try w.writeAll(env_cmd);
    for (secret_env, 0..) |_, i| try w.print("-u {s} ", .{try secretAlias(arena, i)});
    if (write_event) try w.writeAll("-u " ++ event_env ++ " ");
    for (env) |e| {
        const pair = try std.fmt.allocPrint(arena, "{s}={s}", .{ e.name, e.value });
        try shellQuote(w, pair);
        try w.writeByte(' ');
    }
    // The value is expanded by the shell from the alias; only the variable's name is in the command.
    for (secret_env, 0..) |name, i| {
        try shellQuote(w, try std.fmt.allocPrint(arena, "{s}=", .{name}));
        try w.print("\"${s}\" ", .{try secretAlias(arena, i)});
    }
    // Set after the step's own env, so a step cannot point these somewhere else.
    const names = [_][]const u8{ "GITHUB_OUTPUT", "GITHUB_ENV", "GITHUB_PATH", "GITHUB_STEP_SUMMARY", "GITHUB_STATE" };
    for (names, fc_kinds) |name, kind| {
        try shellQuote(w, try std.fmt.allocPrint(arena, "{s}={s}", .{ name, try fcPath(arena, kind, fc) }));
        try w.writeByte(' ');
    }
    try shellQuote(w, try std.fmt.allocPrint(arena, "GITHUB_ACTION={s}", .{action_name}));
    try w.writeByte(' ');
}

/// The command template for a step's `shell:` as GitHub runs it, `{0}` being the script file: no
/// `shell:` is `bash -e {0}` (`sh -e {0}` when the image has no bash, decided in the script), `bash`
/// adds pipefail and skips the profile and rc files, `sh` is `sh -e {0}`, and a custom command is
/// used as written.
fn shellTemplate(shell: ?[]const u8) []const u8 {
    const s = shell orelse return "bash -e {0}";
    if (std.mem.eql(u8, s, "bash")) return "bash --noprofile --norc -e -o pipefail {0}";
    if (std.mem.eql(u8, s, "sh")) return "sh -e {0}";
    return s;
}

/// The command that runs the script file `path`: the template's words, quoted, with `{0}` replaced.
fn writeShellCommand(w: *std.Io.Writer, arena: Allocator, shell: ?[]const u8, path: []const u8) !void {
    var it = std.mem.tokenizeAny(u8, shellTemplate(shell), " \t");
    var first = true;
    while (it.next()) |word| {
        // No `shell:`: bash, or sh where the image has no bash (`$zig_shell`, set by the script).
        if (first and shell == null) {
            try w.writeAll("\"$zig_shell\" ");
        } else {
            try shellQuote(w, try std.mem.replaceOwned(u8, arena, word, "{0}", path));
            try w.writeByte(' ');
        }
        first = false;
    }
}

/// The `shell:` line of a run step's log header, as GitHub's runner prints it: the template, with a
/// bare `bash` or `sh` as its full path.
fn shellLine(arena: Allocator, shell: ?[]const u8) ![]const u8 {
    const t = shellTemplate(shell);
    var it = std.mem.tokenizeAny(u8, t, " \t");
    const prog = it.next() orelse return std.fmt.allocPrint(arena, "shell: {s}", .{t});
    const rest = std.mem.trimStart(u8, t[prog.len..], " \t");
    const full = if (std.mem.eql(u8, prog, "bash") or std.mem.eql(u8, prog, "sh")) try std.fmt.allocPrint(arena, "/usr/bin/{s}", .{prog}) else prog;
    return std.fmt.allocPrint(arena, "shell: {s} {s}", .{ full, rest });
}

/// Where a step's script is written for its shell, as GitHub writes it under RUNNER_TEMP.
fn scriptPath(arena: Allocator, fc: u32) ![]const u8 {
    return std.fmt.allocPrint(arena, "/tmp/zig-runner-step-{d}.sh", .{fc});
}

/// The name under which a step's `i`th secret variable is attached to the container. Dagger silently
/// drops variables whose names are not identifiers (`INPUT_GITHUB-TOKEN`), and a variable attached to
/// the container would outlive the step; the alias is removed again after the step's exec.
fn secretAlias(arena: Allocator, i: usize) ![]const u8 {
    return std.fmt.allocPrint(arena, "ZIG_SECRET_{d}", .{i});
}

pub const Outcome = enum { not_run, success, failure, skipped, cancelled };

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
    /// GitHub cancelled the job while it ran (a cancel in the UI, or the job's `timeout-minutes`).
    cancelled: bool = false,
    /// Actions' `pre` and `post` scripts that ran, as GitHub shows them: steps of their own.
    extra: []const ExtraStep = &.{},
    /// The first log step number not used (see `ExtraStep.log_step`); 0 means `steps.len + 1`.
    next_log_step: u32 = 0,
    /// The job's outputs, evaluated after its steps (see `job_mod.Job.outputs`), and what to log
    /// about them in "Complete job".
    outputs: []const job_mod.EnvVar = &.{},
    output_lines: []const []const u8 = &.{},
    annotations: []const Annotation = &.{},
    /// $GITHUB_STEP_SUMMARY per log step (index = log step - 1; empty when none was written).
    summaries: []const []const u8 = &.{},
};

/// A published service port: steps reach `localhost:<host>`, forwarded to the service's `container`.
pub const ServicePort = struct { host: u16, container: u16 };

/// `5432`, `5432:5432`, `127.0.0.1:15432:5432`, `5432/tcp`. On GitHub a bare container port is
/// published on a random host port (read back as `job.services.<name>.ports[...]`); here it keeps
/// its own number. Null for UDP and what is not a port.
pub fn parseServicePort(text: []const u8) ?ServicePort {
    var t = std.mem.trim(u8, text, " ");
    if (std.mem.indexOfScalar(u8, t, '/')) |slash| {
        if (!std.ascii.eqlIgnoreCase(t[slash + 1 ..], "tcp")) return null;
        t = t[0..slash];
    }
    var parts: [3][]const u8 = undefined;
    var n: usize = 0;
    var it = std.mem.splitScalar(u8, t, ':');
    while (it.next()) |p| {
        if (n == 3) return null;
        parts[n] = p;
        n += 1;
    }
    const container = std.fmt.parseInt(u16, parts[n - 1], 10) catch return null;
    const host = if (n >= 2 and parts[n - 2].len > 0) std.fmt.parseInt(u16, parts[n - 2], 10) catch return null else container;
    if (container == 0 or host == 0) return null;
    return .{ .host = host, .container = container };
}

/// Shell lines that forward each published port from localhost (IPv4 and IPv6) to its service, with
/// busybox's `tcpsvd` and `nc`, in the background for the step's duration.
fn forwardPrelude(arena: Allocator, services: []const Exec.RunningService) ![]const u8 {
    var aw: std.Io.Writer.Allocating = .init(arena);
    const w = &aw.writer;
    for (services) |r| for (r.ports) |p| {
        for ([_][]const u8{ "127.0.0.1", "::1" }) |addr| {
            try w.print("\"" ++ busybox_path ++ "\" tcpsvd {s} {d} \"" ++ busybox_path ++ "\" nc ", .{ addr, p.host });
            try shellQuote(w, r.name);
            try w.print(" {d} >/dev/null 2>&1 &\n", .{p.container});
        }
    };
    return aw.written();
}

/// The registry an image is pulled from, for its credentials: the first part of the reference when
/// it names a host (a dot, a port or `localhost`), else Docker Hub.
fn registryHost(image: []const u8) []const u8 {
    const slash = std.mem.indexOfScalar(u8, image, '/') orelse return "docker.io";
    const first = image[0..slash];
    if (std.mem.indexOfAny(u8, first, ".:") != null or std.mem.eql(u8, first, "localhost")) return first;
    return "docker.io";
}

/// `withRegistryAuth(...) { ` for a service's or the job container's `credentials`, or null without
/// them. Sets `err_msg` (and returns null) when the password could not be registered as a secret.
fn registryAuthNode(arena: Allocator, ev: *Evaluator, transport: Transport, counter: *u32, svc: job_mod.Service, image: []const u8, err_msg: *[]const u8) !?[]const u8 {
    const ut = svc.username orelse return null;
    const pt = svc.password orelse return null;
    const sc = try ev.scope(&.{});
    const user = ev.render(ut, sc) catch "";
    const pass = ev.render(pt, sc) catch "";
    if (user.len == 0 or pass.len == 0) return null;
    const secret = newSecret(arena, transport, counter, pass, err_msg) catch {
        err_msg.* = try std.fmt.allocPrint(arena, "could not register the credentials for {s}: {s}", .{ image, err_msg.* });
        return null;
    };
    var aw: std.Io.Writer.Allocating = .init(arena);
    const w = &aw.writer;
    try w.writeAll("withRegistryAuth(address:");
    try std.json.Stringify.value(registryHost(image), .{}, w);
    try w.writeAll(",username:");
    try std.json.Stringify.value(user, .{}, w);
    try w.writeAll(",secret:");
    try std.json.Stringify.value(secret, .{}, w);
    try w.writeAll(") { ");
    return aw.written();
}

/// The `options:` of a service that are not carried out, as written. Health checks are: the service
/// is ready when its ports accept connections (`--health-*` is accepted and not run).
fn ignoredServiceOptions(arena: Allocator, options: []const u8) ![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    var it = std.mem.tokenizeAny(u8, options, " \t\n");
    var skip_value = false;
    var in_quote: ?u8 = null;
    while (it.next()) |tok| {
        if (in_quote) |q| {
            if (tok[tok.len - 1] == q) in_quote = null;
            continue;
        }
        if (skip_value) {
            skip_value = false;
            if (tok[0] == '"' or tok[0] == '\'') {
                if (tok.len == 1 or tok[tok.len - 1] != tok[0]) in_quote = tok[0];
            }
            continue;
        }
        if (std.mem.startsWith(u8, tok, "--health-")) {
            skip_value = std.mem.indexOfScalar(u8, tok, '=') == null;
            continue;
        }
        if (out.items.len > 0) try out.append(arena, ' ');
        try out.appendSlice(arena, tok);
    }
    return out.items;
}

/// An annotation and the log step it came from (mapped to GitHub's step number at completion).
pub const Annotation = struct { step: u32, an: commands.Annotation };

/// The log lines a message takes (an annotation's message is logged one line per line).
fn countLines(msg: []const u8) u32 {
    return @intCast(std.mem.count(u8, msg, "\n") + 1);
}

/// Per service, kept for "Stop containers".
const max_service_log_lines = 10_000;

/// The largest step summary GitHub accepts (its `soft_size_limit`).
const max_summary_bytes = 1024 * 1024;

/// Per level and step, as GitHub's runner limits them.
const max_annotations = 10;

/// A `pre` or `post` script that ran: a step of its own in GitHub's list ("Pre Run x@v1",
/// "Post Run x@v1"). Its lines are logged under `log_step`, a number after the job's own steps
/// (0 is "Set up job", 1..n the job's steps).
pub const ExtraKind = enum { pre, post, initialize, stop };

pub const ExtraStep = struct {
    /// `initialize` and `stop` are "Initialize containers" and "Stop containers", which GitHub lists
    /// with the pre and post steps but numbers apart from them (see `loop.shownSteps`).
    kind: ExtraKind,
    name: []const u8,
    log_step: u32,
    outcome: Outcome,
    started_ms: i64,
    completed_ms: i64,
};

/// Log step numbers a job can use: its steps, at most one `pre` and one `post` each, and
/// "Initialize containers" and "Stop containers" for its services.
pub fn logSteps(n: usize) usize {
    return n * 3 + 3;
}

/// Sends one GraphQL document to the Dagger session and returns the response body.
pub const Transport = struct {
    ptr: *anyopaque,
    sendFn: *const fn (ptr: *anyopaque, arena: Allocator, doc: []const u8) anyerror![]const u8,
    /// Ends the document being sent, from another task, so `send` fails; false when none was in
    /// flight. Null when the transport cannot (the `dagger run` CLI): steps then run to their end.
    abortFn: ?*const fn (ptr: *anyopaque) bool = null,

    fn send(t: Transport, arena: Allocator, doc: []const u8) ![]const u8 {
        return t.sendFn(t.ptr, arena, doc);
    }

    fn abort(t: Transport) bool {
        return if (t.abortFn) |f| f(t.ptr) else false;
    }
};

/// Set by the runner when GitHub cancels the job (a `JobCancellation` message), read by the job.
pub const Cancel = struct {
    requested: std.atomic.Value(bool) = .init(false),
    /// When whatever still runs is stopped too (the grace period GitHub gives after a cancel), in
    /// ms since the epoch; 0 for none.
    hard_deadline_ms: std.atomic.Value(i64) = .init(0),
};

/// Stops a step that runs past its `timeout-minutes`, or that is running when the job is cancelled,
/// by aborting the step's query (the engine then cancels the exec). A task of its own checks every
/// 200 ms; `begin` and `end` bracket each step, so an interrupt meant for one step never reaches the
/// next.
const Watch = struct {
    io: std.Io,
    transport: Transport,
    cancel: ?*Cancel,
    mu: std.Io.Mutex = .init,
    in_step: bool = false,
    deadline_ms: i64 = 0,
    /// A cancel arrived while this step ran and its query is still to be aborted.
    cancel_pending: bool = false,
    cancel_seen: bool = false,
    interrupt: Interrupt = .none,
    done: std.atomic.Value(bool) = .init(false),

    const Interrupt = enum { none, timed_out, cancelled };

    fn begin(w: *Watch, deadline_ms: i64) void {
        w.mu.lockUncancelable(w.io);
        defer w.mu.unlock(w.io);
        w.in_step = true;
        w.deadline_ms = deadline_ms;
        w.interrupt = .none;
        w.cancel_pending = false;
    }

    /// How the step was interrupted, if it was.
    fn end(w: *Watch) Interrupt {
        w.mu.lockUncancelable(w.io);
        defer w.mu.unlock(w.io);
        w.in_step = false;
        w.deadline_ms = 0;
        w.cancel_pending = false;
        defer w.interrupt = .none;
        return w.interrupt;
    }

    fn run(w: *Watch) void {
        while (!w.done.load(.acquire)) {
            w.io.sleep(.fromMilliseconds(200), .awake) catch return;
            w.tick(std.Io.Clock.real.now(w.io).toMilliseconds());
        }
    }

    fn tick(w: *Watch, now: i64) void {
        w.mu.lockUncancelable(w.io);
        defer w.mu.unlock(w.io);
        if (w.cancel) |c| {
            if (!w.cancel_seen and c.requested.load(.acquire)) {
                w.cancel_seen = true;
                w.cancel_pending = w.in_step;
            }
            const hard = c.hard_deadline_ms.load(.acquire);
            // Past the grace period nothing runs on: whatever is in flight is ended.
            if (w.cancel_seen and hard > 0 and now > hard) w.cancel_pending = true;
        }
        if (w.cancel_pending and w.transport.abort()) {
            w.interrupt = .cancelled;
            w.cancel_pending = false;
            return;
        }
        if (w.in_step and w.deadline_ms > 0 and now > w.deadline_ms and w.transport.abort()) {
            w.interrupt = .timed_out;
            w.deadline_ms = 0;
        }
    }
};

/// Told when each step starts and finishes, so run state can be recorded at those transitions.
pub const Observer = struct {
    ptr: *anyopaque,
    startedFn: *const fn (ptr: *anyopaque, number: u32, name: []const u8, started_ms: i64) void,
    finishedFn: *const fn (ptr: *anyopaque, number: u32, result: StepResult) void,
    /// The steps the runner adds ("Pre ...", "Post ...", "Initialize containers", "Stop
    /// containers"), by log step (see `ExtraStep`); optional.
    extraStartedFn: ?*const fn (ptr: *anyopaque, kind: ExtraKind, log_step: u32, name: []const u8, started_ms: i64) void = null,
    extraFinishedFn: ?*const fn (ptr: *anyopaque, e: ExtraStep) void = null,
    /// Before the post steps: how many will run, and whether "Stop containers" follows (GitHub
    /// numbers them apart from the steps before, see `loop.shownSteps`).
    postsFn: ?*const fn (ptr: *anyopaque, posts: u32, stop: bool) void = null,

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
    /// The name the runner registered under (`runner.name`, RUNNER_NAME).
    runner_name: []const u8 = "zig-runner",
    /// What runs JavaScript actions.
    js_runtime: config.JsRuntime = .bun,
    /// Steps may use the job's Dagger engine (`dagger call` inside a step): `experimentalPrivilegedNesting`.
    nesting: bool = true,
    /// Mount `package_cache_dirs` from persistent cache volumes, scoped to the repository. The runner
    /// turns this on (`RUNNER_PACKAGE_CACHES`, on by default).
    package_caches: bool = false,
    /// Reuse unchanged steps' results across runs (see `volatile_env`). The runner turns this on
    /// (`RUNNER_STEP_CACHE`, on by default).
    step_cache: bool = false,
    /// Experimental, with `step_cache`: a step that always runs (it uses secrets) no longer makes
    /// every later step run too. What it changed is stored by content digest in a cache volume (see
    /// `Exec.outputKeyed`), and the next step starts from the container before it plus a copy of
    /// that content, so its key depends on what the step produced, not on the step having run. The
    /// runner turns this on with `RUNNER_OUTPUT_KEYS`.
    output_keys: bool = false,
    /// Set by the runner when GitHub cancels the job.
    cancel: ?*Cancel = null,
    /// Talk to the Dagger engine directly (`engine.zig`) instead of through a `dagger run` child.
    engine: ?engine.Endpoint = null,
    /// Backs the direct session's long-lived buffers and tasks; must be thread-safe.
    gpa: Allocator = std.heap.smp_allocator,
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
/// `auth`: a Dagger secret holding the job's GITHUB_TOKEN, sent as GitHub expects a token over HTTPS
/// (user `x-access-token`), so private repositories can be checked out, as actions/checkout does.
pub fn checkoutQuery(arena: Allocator, job: job_mod.Job, co: job_mod.Checkout, auth: ?[]const u8) !union(enum) { doc: []const u8, err: []const u8 } {
    const repo = co.repository orelse job.github.repository;
    if (repo.len == 0) return .{ .err = "no repository to check out (the job has no github.repository)" };
    const own = co.repository == null or std.mem.eql(u8, repo, job.github.repository);
    const url = try std.fmt.allocPrint(arena, "{s}/{s}.git", .{ std.mem.trimEnd(u8, job.github.server_url, "/"), repo });

    var aw: std.Io.Writer.Allocating = .init(arena);
    const w = &aw.writer;
    try w.writeAll("{ git(url:");
    try std.json.Stringify.value(url, .{}, w);
    try writeGitAuth(w, auth);
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

/// The checkout step's log up to the commit: actions/checkout's folds ("Fetching the repository",
/// "Checking out the ref"), filled with what the built-in checkout did instead of git commands it
/// did not run. The script closes the last fold after setting up the refs.
fn checkoutLog(arena: Allocator, f: Fetched) ![]const []const u8 {
    var out: std.ArrayList([]const u8) = .empty;
    try out.append(arena, try std.fmt.allocPrint(arena, "Syncing repository: {s}", .{f.repo}));
    try out.append(arena, "##[group]Fetching the repository");
    try out.append(arena, try std.fmt.allocPrint(arena, "Fetched {s} with Dagger's git support (the runner's built-in checkout replaces actions/checkout)", .{f.url}));
    try out.append(arena, try std.fmt.allocPrint(arena, "{s}: {s}", .{ if (isSha(f.want)) "Commit" else "Ref", f.want }));
    if (f.depth == 0) {
        try out.append(arena, "Depth: full history");
    } else {
        try out.append(arena, try std.fmt.allocPrint(arena, "Depth: {d}", .{f.depth}));
    }
    try out.append(arena, try std.fmt.allocPrint(arena, "Tags: {s}", .{if (f.tags) "fetched" else "not fetched"}));
    try out.append(arena, "##[endgroup]");
    try out.append(arena, "##[group]Checking out the ref");
    try out.append(arena, try std.fmt.allocPrint(arena, "Into {s}", .{f.mount}));
    const ref = f.git_ref orelse {
        try out.append(arena, try std.fmt.allocPrint(arena, "HEAD is detached at {s}", .{f.ref_label}));
        return out.items;
    };
    if (std.mem.startsWith(u8, ref, "refs/heads/")) {
        const b = ref["refs/heads/".len..];
        try out.append(arena, try std.fmt.allocPrint(arena, "Switched to a new branch '{s}'", .{b}));
        try out.append(arena, try std.fmt.allocPrint(arena, "branch '{s}' set up to track 'origin/{s}'.", .{ b, b }));
    } else if (std.mem.startsWith(u8, ref, "refs/pull/")) {
        try out.append(arena, try std.fmt.allocPrint(arena, "HEAD is detached at refs/remotes/pull/{s}", .{ref["refs/pull/".len..]}));
    } else if (std.mem.startsWith(u8, ref, "refs/")) {
        try out.append(arena, try std.fmt.allocPrint(arena, "HEAD is detached at {s}", .{ref}));
    } else {
        try out.append(arena, try std.fmt.allocPrint(arena, "HEAD is detached at origin/{s}", .{ref}));
    }
    return out.items;
}

/// Shell lines that give a fetched tree the refs actions/checkout leaves: Dagger's tree has a
/// detached HEAD and no refs at all. Without a ref at HEAD, a later `git fetch` in the job cannot tell
/// the server what it already has and downloads the whole tree again; that is also why the dagger
/// CLI warned "failed to fetch branch" on pull requests (its go-git reads the PR head right after
/// such a fetch, and does not see the new pack file the large fetch produced).
///   refs/heads/B        -> refs/remotes/origin/B and a local branch B tracking it, checked out
///   refs/pull/N/merge   -> refs/remotes/pull/N/merge (detached), likewise refs/pull/N/head
///   refs/tags/T         -> refs/tags/T (detached)
///   other refs/...      -> the same ref (detached)
///   a bare name         -> refs/remotes/origin/<name> (detached)
/// Failures are ignored (an image without git, say): the checkout itself is already done.
fn checkoutRefCommands(arena: Allocator, mount: []const u8, ref: []const u8) ![]const u8 {
    var aw: std.Io.Writer.Allocating = .init(arena);
    const w = &aw.writer;
    try w.writeAll("if command -v git >/dev/null 2>&1; then ( cd ");
    try shellQuote(w, mount);
    try w.writeAll(" && g() { git -c safe.directory='*' \"$@\"; }");
    if (std.mem.startsWith(u8, ref, "refs/heads/")) {
        const branch = ref["refs/heads/".len..];
        const items = [_][2][]const u8{
            .{ "update-ref", try std.fmt.allocPrint(arena, "refs/remotes/origin/{s}", .{branch}) },
            .{ "update-ref", ref },
        };
        for (items) |it| {
            try w.print(" && g {s} ", .{it[0]});
            try shellQuote(w, it[1]);
            try w.writeAll(" HEAD");
        }
        try w.writeAll(" && g symbolic-ref HEAD ");
        try shellQuote(w, ref);
        try w.writeAll(" && g config ");
        try shellQuote(w, try std.fmt.allocPrint(arena, "branch.{s}.remote", .{branch}));
        try w.writeAll(" origin && g config ");
        try shellQuote(w, try std.fmt.allocPrint(arena, "branch.{s}.merge", .{branch}));
        try w.writeByte(' ');
        try shellQuote(w, ref);
    } else {
        const target = if (std.mem.startsWith(u8, ref, "refs/pull/"))
            try std.fmt.allocPrint(arena, "refs/remotes/pull/{s}", .{ref["refs/pull/".len..]})
        else if (std.mem.startsWith(u8, ref, "refs/"))
            ref
        else
            try std.fmt.allocPrint(arena, "refs/remotes/origin/{s}", .{ref});
        try w.writeAll(" && g update-ref ");
        try shellQuote(w, target);
        try w.writeAll(" HEAD");
    }
    try w.writeAll(" ) >/dev/null 2>&1 || true; fi\n");
    return aw.written();
}

fn looksLikeAuthFailure(text: []const u8) bool {
    const needles = [_][]const u8{ "not found", "authentication", "Authentication", "denied", "403", "401", "could not read Username" };
    for (needles) |n| if (std.mem.indexOf(u8, text, n) != null) return true;
    return false;
}

/// `,httpAuthUsername:...,httpAuthToken:...` for a `git(...)` query, when there is a token.
fn writeGitAuth(w: *std.Io.Writer, auth: ?[]const u8) !void {
    const id = auth orelse return;
    try w.writeAll(",httpAuthUsername:\"x-access-token\",httpAuthToken:");
    try std.json.Stringify.value(id, .{}, w);
}

fn fetchCheckout(arena: Allocator, t: Transport, job: job_mod.Job, co: job_mod.Checkout, auth: ?[]const u8) !Fetched {
    const repo = co.repository orelse job.github.repository;
    const mount = if (co.path) |pth|
        try std.fmt.allocPrint(arena, "{s}/{s}", .{ workspace, std.mem.trim(u8, pth, "/") })
    else
        workspace;
    const want = co.ref orelse (if (co.repository == null) job.github.sha else "HEAD");
    const label = if (isSha(want)) want[0..7] else want;
    // The workflow's own commit is named by the ref that triggered the run, as actions/checkout does.
    const git_ref: ?[]const u8 = if (co.ref) |r| (if (isSha(r)) null else r) else if (co.repository == null and job.github.ref.len > 0) job.github.ref else null;
    var f: Fetched = .{
        .result = .{ .failed = "" },
        .repo = repo,
        .ref_label = label,
        .mount = mount,
        .git_ref = git_ref,
        .url = try std.fmt.allocPrint(arena, "{s}/{s}", .{ std.mem.trimEnd(u8, job.github.server_url, "/"), repo }),
        .want = want,
        .depth = co.fetch_depth,
        .tags = co.fetch_tags,
    };

    const doc = switch (try checkoutQuery(arena, job, co, auth)) {
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
        repo, label, msg, if (looksLikeAuthFailure(msg)) " (the job's GITHUB_TOKEN reads only the job's own repository; another private one cannot be checked out)" else "",
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
    /// Set once GitHub cancelled the job: `cancelled()` is true and `success()` false from then on.
    cancelled: bool = false,
    /// `job.services`: `{<name>: {id, network, ports: {<container port>: <host port>}}}`.
    services: ?expr.Value = null,
    diag: []const u8 = "",
    /// Reads the job's files for `hashFiles()`, once the job's container exists.
    hash_files: ?expr.HashFiles = null,
    /// `runner.name` and RUNNER_NAME: the name the runner registered under.
    runner_name: []const u8 = "zig-runner",

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
        // GitHub's runner adds `github.token` (the job's GITHUB_TOKEN); it is not in contextData. Actions
        // default their `github-token` input to it.
        if (ev.github == .object and !hasKey(ev.github, "token")) {
            for (job.secret_vars) |sv| if (std.mem.eql(u8, sv.name, "GITHUB_TOKEN")) {
                ev.github = try withEntries(arena, ev.github, &.{.{ .key = "token", .value = .{ .string = sv.value } }});
            };
        }
        // Nor is `github.job` (GITHUB_JOB, the job's key in the workflow): it comes from the message's
        // `jobName`.
        if (ev.github == .object and !hasKey(ev.github, "job") and job.github.job.len > 0) {
            ev.github = try withEntries(arena, ev.github, &.{.{ .key = "job", .value = .{ .string = job.github.job } }});
        }
        // Nor is `github.workspace` (GITHUB_WORKSPACE), which actions use as an input default
        // (setup-uv's `working-directory`).
        if (ev.github == .object and !hasKey(ev.github, "workspace")) {
            ev.github = try withEntries(arena, ev.github, &.{.{ .key = "workspace", .value = .{ .string = workspace } }});
        }
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

        const job_fields = try arena.alloc(expr.Value.Entry, if (ev.services != null) 2 else 1);
        job_fields[0] = .{ .key = "status", .value = .{ .string = if (ev.cancelled) "cancelled" else if (ev.job_failed) "failure" else "success" } };
        if (ev.services) |v| job_fields[1] = .{ .key = "services", .value = v };
        const runner_fields = try arena.alloc(expr.Value.Entry, 5);
        runner_fields[0] = .{ .key = "os", .value = .{ .string = "Linux" } };
        runner_fields[1] = .{ .key = "arch", .value = .{ .string = broker.arch } };
        runner_fields[2] = .{ .key = "name", .value = .{ .string = ev.runner_name } };
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
            .cancelled = ev.cancelled,
            .diag = &ev.diag,
            .hash_files = ev.hash_files,
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

    fn setServices(ev: *Evaluator, running: []const Exec.RunningService) !void {
        const arena = ev.arena;
        const entries = try arena.alloc(expr.Value.Entry, running.len);
        for (running, entries) |r, *e| {
            const ports = try arena.alloc(expr.Value.Entry, r.ports.len);
            for (r.ports, ports) |p, *pe| pe.* = .{ .key = try std.fmt.allocPrint(arena, "{d}", .{p.container}), .value = .{ .string = try std.fmt.allocPrint(arena, "{d}", .{p.host}) } };
            // A stable id of the running service (GitHub gives the container's id).
            var digest: [32]u8 = undefined;
            std.crypto.hash.sha2.Sha256.hash(r.id, &digest, .{});
            const fields = try arena.alloc(expr.Value.Entry, 3);
            fields[0] = .{ .key = "id", .value = .{ .string = try std.fmt.allocPrint(arena, "{x}", .{&digest}) } };
            fields[1] = .{ .key = "network", .value = .{ .string = "dagger" } };
            fields[2] = .{ .key = "ports", .value = .{ .object = ports } };
            e.* = .{ .key = r.name, .value = .{ .object = fields } };
        }
        ev.services = .{ .object = entries };
    }

    fn record(ev: *Evaluator, step: job_mod.Step, outcome: Outcome, continued: bool, outputs: []const job_mod.EnvVar) !void {
        const raw: []const u8 = switch (outcome) {
            .success => "success",
            .failure => "failure",
            .cancelled => "cancelled",
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

    /// `github.event` as JSON, for GITHUB_EVENT_PATH; `{}` when the job has none.
    fn eventJson(ev: *Evaluator) ![]const u8 {
        const ctxs = [_]expr.Value.Entry{.{ .key = "github", .value = ev.github }};
        const text = expr.evalString(ev.arena, "toJSON(github.event)", .{ .contexts = &ctxs }) catch return "{}";
        return if (std.mem.eql(u8, text, "null") or text.len == 0) "{}" else text;
    }

    /// The variables every step sees, as on a GitHub-hosted runner.
    fn defaultEnv(ev: *const Evaluator) ![]const job_mod.EnvVar {
        var out: std.ArrayList(job_mod.EnvVar) = .empty;
        const fixed = [_]job_mod.EnvVar{
            .{ .name = "CI", .value = "true" },
            .{ .name = "GITHUB_ACTIONS", .value = "true" },
            .{ .name = "GITHUB_WORKSPACE", .value = workspace },
            .{ .name = "RUNNER_OS", .value = "Linux" },
            .{ .name = "RUNNER_ARCH", .value = broker.arch },
            .{ .name = "RUNNER_NAME", .value = ev.runner_name },
            .{ .name = "RUNNER_TEMP", .value = "/tmp" },
            .{ .name = "RUNNER_TOOL_CACHE", .value = "/opt/hostedtoolcache" },
            .{ .name = "GITHUB_EVENT_PATH", .value = event_path },
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
    /// Workflow-command state per step (index = step - 1, guarded by `mu`).
    commands: []StepCommands = &.{},
    /// Steps whose recorded output was replayed (index = step - 1, guarded by `mu`). If no live line
    /// ever arrives for one, Dagger served it from cache (see `noteReusedSteps`).
    replayed_steps: []bool = &.{},
    /// `ACTIONS_STEP_DEBUG`: show `::debug::` lines.
    step_debug: bool = false,
    /// `::error`/`::warning`/`::notice` lines and the runner's own errors, sent with completejob so
    /// GitHub shows them on the run (guarded by `mu`).
    annotations: std.ArrayList(Annotation) = .empty,
    /// Each service's output (index = service), printed in "Stop containers" as GitHub's runner
    /// prints `docker logs` (guarded by `mu`); lines past `max_service_log_lines` are counted.
    service_logs: []std.ArrayList([]const u8) = &.{},
    service_dropped: []u32 = &.{},
    /// Lines logged per log step so far (guarded by `mu`): an annotation without a file points to
    /// its line in the step's log, as GitHub's runner does.
    line_counts: []u32 = &.{},

    const StepCommands = struct {
        stop_token: ?[]const u8 = null,
        /// From the deprecated `::set-output` and `::save-state`.
        outputs: std.ArrayList(job_mod.EnvVar) = .empty,
        state: std.ArrayList(job_mod.EnvVar) = .empty,
    };

    /// A line from the runner itself; never read as a workflow command.
    fn append(sh: *Shared, step: u32, text: []const u8) void {
        sh.mu.lockUncancelable(sh.io);
        defer sh.mu.unlock(sh.io);
        sh.appendLocked(step, text);
    }

    fn appendLocked(sh: *Shared, step: u32, text: []const u8) void {
        sh.log.append(sh.sink_job_id, step, .stdout, text) catch {};
        if (step < sh.line_counts.len) sh.line_counts[step] += 1;
    }

    /// A line of a step's output: workflow commands (`::add-mask::`, `::group::`, ...) are carried out
    /// and logged the way GitHub shows them; anything else is logged as it is.
    fn stepOutput(sh: *Shared, step: u32, text: []const u8) void {
        sh.mu.lockUncancelable(sh.io);
        defer sh.mu.unlock(sh.io);
        if (step == 0 or step > sh.commands.len) return sh.appendLocked(step, text);
        const st = &sh.commands[step - 1];
        // What a command keeps (an annotation, an output, a stop token) can be a slice of its line,
        // and a direct session's line lives only as long as its log record: keep the line.
        const line = if (std.mem.indexOf(u8, text, "::") != null) sh.arena.dupe(u8, text) catch return else text;
        const cmd = commands.parseWorkflow(sh.arena, line, st.stop_token) catch return sh.appendLocked(step, line);
        switch (cmd) {
            .none => sh.appendLocked(step, text),
            .add_mask => |value| sh.addMask(value),
            .group => |title| sh.appendFmt(step, "##[group]{s}", .{title}),
            .endgroup => sh.appendLocked(step, "##[endgroup]"),
            .annotation => |an| {
                var lines = std.mem.splitScalar(u8, an.message, '\n');
                sh.appendFmt(step, "##[{s}]{s}", .{ an.level, std.mem.trimEnd(u8, lines.first(), "\r") });
                while (lines.next()) |l| sh.appendLocked(step, std.mem.trimEnd(u8, l, "\r"));
                sh.annotateLocked(step, an);
            },
            .debug => |msg| if (sh.step_debug) sh.appendFmt(step, "##[debug]{s}", .{msg}),
            .stop => |token| st.stop_token = token,
            .resume_commands => st.stop_token = null,
            .set_output => |kv| st.outputs.append(sh.arena, kv) catch {},
            .save_state => |kv| st.state.append(sh.arena, kv) catch {},
            .disabled => |name| {
                const msg = std.fmt.allocPrint(sh.arena, "The `{s}` command is disabled. Please upgrade to using Environment Files or opt into unsecure command execution by setting the `ACTIONS_ALLOW_UNSECURE_COMMANDS` environment variable to `true`. For more information see: https://github.blog/changelog/2020-10-01-github-actions-deprecating-set-env-and-add-path-commands/", .{name}) catch return;
                sh.errorLineLocked(step, msg);
            },
            .echo => {},
        }
    }

    /// An error of the runner's own (a failed exit code, a timeout): logged as `##[error]<msg>` and
    /// annotated, as GitHub's runner does.
    fn errorLine(sh: *Shared, step: u32, msg: []const u8) void {
        sh.mu.lockUncancelable(sh.io);
        defer sh.mu.unlock(sh.io);
        sh.errorLineLocked(step, msg);
    }

    fn errorLineLocked(sh: *Shared, step: u32, msg: []const u8) void {
        sh.appendFmt(step, "##[error]{s}", .{msg});
        sh.annotateLocked(step, .{ .level = "error", .message = msg });
    }

    /// Keeps an annotation for completejob. Like GitHub's runner, at most `max_annotations` of each
    /// level per step (the rest are only logged), and a file in the workspace is named from its root.
    fn annotateLocked(sh: *Shared, step: u32, an: commands.Annotation) void {
        var same: usize = 0;
        for (sh.annotations.items) |a| {
            if (a.step == step and std.mem.eql(u8, a.an.level, an.level)) same += 1;
        }
        if (same >= max_annotations) return;
        var copy = an;
        if (an.file) |f| copy.file = if (std.mem.startsWith(u8, f, workspace ++ "/")) f[workspace.len + 1 ..] else f;
        // Its line in the log: the annotation's own line was logged just before this.
        if (an.file == null and an.line == null and step < sh.line_counts.len and sh.line_counts[step] > 0)
            copy.line = std.fmt.allocPrint(sh.arena, "{d}", .{sh.line_counts[step] - countLines(an.message) + 1}) catch null;
        sh.annotations.append(sh.arena, .{ .step = step, .an = copy }) catch {};
    }

    fn appendFmt(sh: *Shared, step: u32, comptime fmt: []const u8, args: anytype) void {
        const text = std.fmt.allocPrint(sh.arena, fmt, args) catch return;
        sh.appendLocked(step, text);
    }

    /// Masks `value` (and each of its lines) in everything logged from now on, in every sink.
    fn addMask(sh: *Shared, value: []const u8) void {
        var list: std.ArrayList([]const u8) = .empty;
        list.appendSlice(sh.arena, sh.log.currentSecrets()) catch return;
        var lines = std.mem.splitScalar(u8, value, '\n');
        while (lines.next()) |l| {
            const v = std.mem.trim(u8, l, " \t\r");
            if (v.len > 0) list.append(sh.arena, sh.arena.dupe(u8, v) catch return) catch return;
        }
        const whole = std.mem.trim(u8, value, " \t\r\n");
        if (whole.len > 0 and std.mem.indexOfScalar(u8, whole, '\n') != null) list.append(sh.arena, sh.arena.dupe(u8, whole) catch return) catch return;
        // Longest first, so a secret that contains another one is masked whole.
        std.mem.sort([]const u8, list.items, {}, struct {
            fn longer(_: void, a: []const u8, b: []const u8) bool {
                return a.len > b.len;
            }
        }.longer);
        sh.log.setSecrets(list.items);
    }

    /// State a step saved with the deprecated `::save-state`, since the last call.
    fn takeState(sh: *Shared, step: u32) []const job_mod.EnvVar {
        sh.mu.lockUncancelable(sh.io);
        defer sh.mu.unlock(sh.io);
        if (step == 0 or step > sh.commands.len) return &.{};
        const st = &sh.commands[step - 1];
        const out = st.state.items;
        st.state = .empty;
        return out;
    }

    /// Outputs a step set with the deprecated `::set-output`, since the last call.
    fn takeOutputs(sh: *Shared, step: u32) []const job_mod.EnvVar {
        sh.mu.lockUncancelable(sh.io);
        defer sh.mu.unlock(sh.io);
        if (step == 0 or step > sh.commands.len) return &.{};
        const st = &sh.commands[step - 1];
        const out = st.outputs.items;
        st.outputs = .empty;
        return out;
    }

    fn flush(sh: *Shared) void {
        sh.mu.lockUncancelable(sh.io);
        defer sh.mu.unlock(sh.io);
        sh.log.flush() catch {};
    }

    fn emitLive(sh: *Shared, step: u32, text: []const u8) void {
        if (step >= 1 and step <= sh.live_lines.len) _ = sh.live_lines[step - 1].fetchAdd(1, .monotonic);
        if (sh.swallowIfReplayed(step, text)) return;
        sh.stepOutput(step, text);
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
        sh.stepOutput(step, text);
    }

    /// Service `n`'s output so far, and a note when lines were left out.
    fn takeServiceLog(sh: *Shared, n: usize) []const []const u8 {
        sh.mu.lockUncancelable(sh.io);
        defer sh.mu.unlock(sh.io);
        if (n >= sh.service_logs.len) return &.{};
        if (sh.service_dropped[n] > 0) {
            const note = std.fmt.allocPrint(sh.arena, "... {d} more lines not kept", .{sh.service_dropped[n]}) catch return sh.service_logs[n].items;
            sh.service_logs[n].append(sh.arena, note) catch {};
        }
        return sh.service_logs[n].items;
    }

    fn serviceLine(sh: *Shared, n: u32, line: []const u8) void {
        sh.mu.lockUncancelable(sh.io);
        defer sh.mu.unlock(sh.io);
        if (n >= sh.service_logs.len) return;
        if (sh.service_logs[n].items.len >= max_service_log_lines) {
            sh.service_dropped[n] += 1;
            return;
        }
        sh.service_logs[n].append(sh.arena, sh.arena.dupe(u8, line) catch return) catch {};
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
                .service => {},
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
    // Per log step: the job's steps, then their `pre` and `post` scripts (see `ExtraStep`).
    const live = try arena.alloc(std.atomic.Value(u32), logSteps(job.steps.len));
    const ended = try arena.alloc(std.atomic.Value(bool), logSteps(job.steps.len));
    for (live, ended) |*l, *e| {
        l.* = .init(0);
        e.* = .init(false);
    }
    const replayed_steps = try arena.alloc(bool, logSteps(job.steps.len));
    @memset(replayed_steps, false);
    const step_commands = try arena.alloc(Shared.StepCommands, logSteps(job.steps.len));
    @memset(step_commands, .{});
    const line_counts = try arena.alloc(u32, logSteps(job.steps.len));
    @memset(line_counts, 0);
    const service_logs = try arena.alloc(std.ArrayList([]const u8), job.services.len);
    @memset(service_logs, .empty);
    const service_dropped = try arena.alloc(u32, job.services.len);
    @memset(service_dropped, 0);
    var sh: Shared = .{
        .io = io,
        .arena = arena,
        .log = log,
        .sink_job_id = opts.sink_job_id,
        .live_lines = live,
        .ended = ended,
        .commands = step_commands,
        .replayed_steps = replayed_steps,
        .line_counts = line_counts,
        .service_logs = service_logs,
        .service_dropped = service_dropped,
        .step_debug = stepDebug(arena, job),
    };

    if (opts.engine) |ep| if (opts.test_transport == null) return runDirect(arena, io, opts, job, &sh, results, ep);

    const argv: []const []const u8 = opts.test_session_argv orelse &.{ opts.dagger_cmd, "run", "--progress=logs", "sh", "-c", session_script };
    var child = try std.process.spawn(io, .{ .argv = argv, .environ_map = &env, .stdin = .pipe, .stdout = .pipe, .stderr = .pipe });
    // The reader must run while we wait on queries.
    var reader = io.concurrent(readLogs, .{ io, &sh, child.stderr.? }) catch |e| {
        child.kill(io);
        return e;
    };
    // Order matters: closing stdin ends the session child and `dagger run`, which gives the reader EOF.
    // Only then has every live line arrived, so only then can reused steps be told apart.
    defer {
        if (child.stdin) |f| f.close(io);
        child.stdin = null;
        _ = child.wait(io) catch {};
        reader.await(io);
        noteReusedSteps(&sh);
        sh.flush();
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
    return runSteps(arena, io, opts, job, &sh, results, transport);
}

/// A job's session held by this process (`engine.zig`), with no `dagger run` child: queries go over
/// the session, and live output comes from its log stream, routed to steps by span (`SpanDemux`).
fn runDirect(arena: Allocator, io: std.Io, opts: Options, job: job_mod.Job, sh: *Shared, results: []StepResult, ep: engine.Endpoint) !Result {
    var demux: SpanDemux = .{ .sh = sh, .gpa = opts.gpa };
    defer demux.deinit();
    var sess: engine.Session = undefined;
    // An engine that is starting (just restarted, or updated) refuses connections, or has no socket
    // yet, for up to a minute or so: wait for it, as GitHub's runner waits for Docker, rather than
    // fail the job.
    const started = std.Io.Clock.awake.now(io).toMilliseconds();
    var waiting = false;
    while (true) {
        if (openSession(&sess, opts, io, ep, .{ .ptr = &demux, .onRecord = SpanDemux.onRecord })) |_| {
            if (waiting) sh.append(0, try std.fmt.allocPrint(arena, "The Dagger engine accepted the session after {d} s.", .{@divTrunc(std.Io.Clock.awake.now(io).toMilliseconds() - started, 1000)}));
            break;
        } else |e| {
            const starting = switch (e) {
                error.ConnectionRefused, error.FileNotFound, error.ConnectionResetByPeer, error.EngineUnreachable => true,
                else => false,
            };
            const cancelled = if (opts.cancel) |c| c.requested.load(.acquire) else false;
            if (!starting or cancelled or std.Io.Clock.awake.now(io).toMilliseconds() - started > engine_wait_ms)
                return fail(sh, results, try engineOpenError(arena, e, ep));
            if (!waiting) sh.append(0, try std.fmt.allocPrint(arena, "Waiting for the Dagger engine to accept connections ({s}): it may be starting", .{@errorName(e)}));
            waiting = true;
            io.sleep(.fromSeconds(2), .awake) catch return fail(sh, results, try engineOpenError(arena, e, ep));
        }
    }
    // Closing the session ends its log stream; only then has every live line arrived.
    defer {
        sess.close();
        demux.flushPartial();
        noteReusedSteps(sh);
        sh.flush();
    }
    var st: SessionTransport = .{ .s = &sess };
    return runSteps(arena, io, opts, job, sh, results, .{ .ptr = &st, .sendFn = SessionTransport.send, .abortFn = SessionTransport.abort });
}

/// Opens a session, starting the engine container first if it exists but is stopped, and having the
/// `dagger` CLI create it (`dagger core version`) if it does not exist, as `dagger run` would.
/// How long a job waits for an engine that refuses connections (see `runDirect`).
const engine_wait_ms = 3 * 60 * 1000;

fn openSession(sess: *engine.Session, opts: Options, io: std.Io, ep: engine.Endpoint, h: engine.LogHandler) !void {
    sess.open(opts.gpa, io, ep, h) catch |e| switch (e) {
        error.EngineContainerNotRunning => {
            try engine.startContainer(opts.gpa, io, ep);
            return sess.open(opts.gpa, io, ep, h);
        },
        error.EngineContainerNotFound => {
            var child = std.process.spawn(io, .{ .argv = &.{ opts.dagger_cmd, "core", "version" }, .stdin = .ignore, .stdout = .ignore, .stderr = .ignore }) catch return e;
            _ = child.wait(io) catch return e;
            return sess.open(opts.gpa, io, ep, h);
        },
        else => return e,
    };
}

fn engineOpenError(arena: Allocator, e: anyerror, ep: engine.Endpoint) ![]const u8 {
    if (ep.host.len > 0) return std.fmt.allocPrint(arena, "could not start a Dagger session on the engine at {s}: {s}", .{ ep.host, @errorName(e) });
    return switch (e) {
        error.EngineContainerNotFound => std.fmt.allocPrint(arena, "the Dagger engine container '{s}' does not exist and `dagger core version` did not create it (set RUNNER_ENGINE=cli to use the dagger CLI instead)", .{ep.container}),
        error.FileNotFound, error.ConnectionRefused => std.fmt.allocPrint(arena, "could not reach the Docker API at {s} (is Docker running? DOCKER_HOST sets another socket)", .{ep.docker_socket}),
        else => std.fmt.allocPrint(arena, "could not start a Dagger session on '{s}': {s}", .{ ep.container, @errorName(e) }),
    };
}

/// actions/checkout's inputs and defaults, in its order, for the step's log header (the token is
/// the job's GITHUB_TOKEN, a secret; `repository` is the job's).
const checkout_defaults = [_][2][]const u8{
    .{ "repository", "" },                    .{ "token", "***" },                .{ "ssh-strict", "true" },
    .{ "ssh-user", "git" },                   .{ "persist-credentials", "true" }, .{ "clean", "true" },
    .{ "sparse-checkout-cone-mode", "true" }, .{ "fetch-depth", "1" },            .{ "fetch-tags", "false" },
    .{ "show-progress", "true" },             .{ "lfs", "false" },                .{ "submodules", "false" },
    .{ "set-safe-directory", "true" },
};

/// Opens a `run:` step's log as GitHub's runner does: the command folded away with its shell and the
/// env it gets (workflow, job and step `env:`, and GITHUB_ENV; secret values are masked by the log).
fn logRunHeader(arena: Allocator, sh: *Shared, num: u32, script: []const u8, shell: ?[]const u8, env: []const job_mod.EnvVar) !void {
    sh.append(num, try std.fmt.allocPrint(arena, "##[group]Run {s}", .{firstLine(script)}));
    var lines = std.mem.splitScalar(u8, std.mem.trimEnd(u8, script, "\n"), '\n');
    while (lines.next()) |l| sh.append(num, l);
    sh.append(num, try shellLine(arena, shell));
    if (env.len > 0) {
        sh.append(num, "env:");
        for (env) |e| sh.append(num, try std.fmt.allocPrint(arena, "  {s}: {s}", .{ e.name, firstLine(e.value) }));
    }
    sh.append(num, "##[endgroup]");
}

/// What GitHub's runner logs when a script exits non-zero.
fn logExitCode(sh: *Shared, num: u32, code: i32) void {
    sh.errorLine(num, std.fmt.allocPrint(sh.arena, "Process completed with exit code {d}.", .{code}) catch return);
}

/// The `env` context a step sees: the job's (workflow, job, GITHUB_ENV), then the step's own.
fn envContext(arena: Allocator, job_env: []const job_mod.EnvVar, step_env: []const job_mod.EnvVar) ![]const job_mod.EnvVar {
    var out: std.ArrayList(job_mod.EnvVar) = .empty;
    try out.appendSlice(arena, job_env);
    for (step_env) |e| try Evaluator.putEnv(arena, &out, e.name, e.value);
    return out.items;
}

/// Sends GraphQL over a direct session.
const SessionTransport = struct {
    s: *engine.Session,

    fn send(ptr: *anyopaque, arena: Allocator, doc: []const u8) anyerror![]const u8 {
        const t: *SessionTransport = @ptrCast(@alignCast(ptr));
        return t.s.query(arena, doc);
    }

    fn abort(ptr: *anyopaque) bool {
        const t: *SessionTransport = @ptrCast(@alignCast(ptr));
        return t.s.abort();
    }
};

/// Routes a direct session's log records to steps. Each exec is a span: its output arrives as
/// records with the span's id, in pieces that are joined into lines here. A span belongs to the step
/// whose `begin` marker it prints; records the engine marks verbose (a repeat of output it already
/// logged, such as a `stdout` field's value) are skipped, as in Dagger's own progress output.
const SpanDemux = struct {
    sh: *Shared,
    gpa: Allocator,
    mu: std.Io.Mutex = .init,
    spans: std.StringHashMapUnmanaged(Span) = .empty,

    const Span = struct {
        step: ?u32 = null,
        /// The span is a service's (its output is kept for "Stop containers").
        service: ?u32 = null,
        partial: std.ArrayList(u8) = .empty,
    };

    fn onRecord(ptr: *anyopaque, rec: engine.LogRecord) void {
        const d: *SpanDemux = @ptrCast(@alignCast(ptr));
        if (rec.verbose) return;
        d.mu.lockUncancelable(d.sh.io);
        defer d.mu.unlock(d.sh.io);
        const gop = d.spans.getOrPut(d.gpa, rec.span) catch return;
        if (!gop.found_existing) {
            gop.key_ptr.* = d.gpa.dupe(u8, rec.span) catch {
                _ = d.spans.remove(rec.span);
                return;
            };
            gop.value_ptr.* = .{};
        }
        const span = gop.value_ptr;
        span.partial.appendSlice(d.gpa, rec.text) catch return;
        var start: usize = 0;
        while (std.mem.indexOfScalarPos(u8, span.partial.items, start, '\n')) |nl| {
            d.line(span, std.mem.trimEnd(u8, span.partial.items[start..nl], "\r"));
            start = nl + 1;
        }
        span.partial.replaceRangeAssumeCapacity(0, start, &.{});
        if (rec.eof and span.partial.items.len > 0) {
            d.line(span, span.partial.items);
            span.partial.clearRetainingCapacity();
        }
    }

    fn line(d: *SpanDemux, span: *Span, text: []const u8) void {
        if (scan(text)) |sc| {
            if (span.step) |c| if (sc.before.len > 0) d.sh.emitLive(c, sc.before);
            switch (sc.marker) {
                .begin => |n| span.step = n,
                .end => |n| {
                    if (n >= 1 and n <= d.sh.ended.len) d.sh.ended[n - 1].store(true, .release);
                    d.sh.flush();
                    span.step = null;
                },
                .service => |n| span.service = n,
            }
        } else if (span.step) |c| {
            d.sh.emitLive(c, text);
        } else if (span.service) |n| {
            d.sh.serviceLine(n, text);
        } else if (text.len > 0) {
            d.sh.noise(text);
        }
    }

    /// Output left without a final newline, once the stream has ended.
    fn flushPartial(d: *SpanDemux) void {
        d.mu.lockUncancelable(d.sh.io);
        defer d.mu.unlock(d.sh.io);
        var it = d.spans.valueIterator();
        while (it.next()) |span| if (span.partial.items.len > 0) {
            d.line(span, span.partial.items);
            span.partial.clearRetainingCapacity();
        };
    }

    fn deinit(d: *SpanDemux) void {
        var it = d.spans.iterator();
        while (it.next()) |e| {
            d.gpa.free(e.key_ptr.*);
            e.value_ptr.partial.deinit(d.gpa);
        }
        d.spans.deinit(d.gpa);
    }
};

/// Runs the job's steps once a session is up (through `dagger run` or directly).
fn runSteps(arena: Allocator, io: std.Io, opts: Options, job: job_mod.Job, sh: *Shared, results: []StepResult, transport: Transport) !Result {
    var ev = try Evaluator.init(arena, &job);
    ev.runner_name = opts.runner_name;
    var secret_counter: u32 = 0;
    var err_msg: []const u8 = "";
    // Services hold state a cached step would not have changed (a migration replayed from cache
    // leaves a fresh database empty), so a job with services runs every step.
    const step_cache = opts.step_cache and !optsOutOfStepCache(ev.job_env.items) and job.services.len == 0;
    // `container:` replaces the image every step runs in.
    const job_image: []const u8 = if (job.container) |jc| (ev.render(jc.image, try ev.scope(&.{})) catch "") else opts.image;
    if (job_image.len == 0) return fail(sh, results, try std.fmt.allocPrint(arena, "container: has no image: {s}", .{ev.diag}));
    // Package managers' caches persist across jobs in Dagger cache volumes (see `package_cache_dirs`).
    const cache_ids: []const []const u8 = if (opts.package_caches and job.github.repository.len > 0) ids: {
        const scope = try packageCacheScope(arena, &ev, job.github.repository);
        var doc: std.Io.Writer.Allocating = .init(arena);
        const w = &doc.writer;
        try w.writeAll("{");
        for (package_cache_dirs, 0..) |d, i| {
            try w.print(" c{d}: cacheVolume(key:", .{i});
            // The tool cache holds binaries built for one image (glibc or musl, its libraries), so
            // each image has its own.
            const key = if (std.mem.eql(u8, d.name, "toolcache"))
                try std.fmt.allocPrint(arena, "zig-runner/{s}/{s}/{s}/{s}", .{ job.github.repository, scope, d.name, job_image })
            else
                try std.fmt.allocPrint(arena, "zig-runner/{s}/{s}/{s}", .{ job.github.repository, scope, d.name });
            try std.json.Stringify.value(key, .{}, w);
            try w.writeAll(") { id }");
        }
        try w.writeAll(" }");
        const data = gql(arena, transport, doc.written(), &err_msg) catch return fail(sh, results, err_msg);
        const ids = try arena.alloc([]const u8, package_cache_dirs.len);
        for (ids, 0..) |*id, i| {
            const v = jsonFind(data, try std.fmt.allocPrint(arena, "c{d}", .{i})) orelse return fail(sh, results, "Dagger returned no cache volume");
            id.* = jsonFindString(v, "id") orelse return fail(sh, results, "Dagger returned no cache volume");
        }
        break :ids ids;
    } else &.{};

    const container_id: []const u8 = blk: {
        var doc: std.Io.Writer.Allocating = .init(arena);
        const w = &doc.writer;
        try w.writeAll("{ container { ");
        var extra_braces: usize = 0;
        if (job.container) |jc| {
            // A private image: its registry's credentials.
            if (try registryAuthNode(arena, &ev, transport, &secret_counter, jc, job_image, &err_msg)) |node| {
                try w.writeAll(node);
                extra_braces += 1;
            } else if (err_msg.len > 0) return fail(sh, results, err_msg);
        }
        try w.writeAll("from(address:");
        try std.json.Stringify.value(job_image, .{}, w);
        try w.writeAll(") { ");
        if (job.container != null) for (cache_ids, 0..) |_, i| {
            // Before the container's env, so its own value wins.
            if (package_cache_dirs[i].env.len == 0) continue;
            try w.writeAll("withEnvVariable(name:");
            try std.json.Stringify.value(package_cache_dirs[i].env, .{}, w);
            try w.writeAll(",value:");
            try std.json.Stringify.value(package_cache_dirs[i].path, .{}, w);
            try w.writeAll(") { ");
            extra_braces += 1;
        };
        if (job.container) |jc| {
            // The container's env, as `docker create -e` sets it: every step sees it.
            const env = ev.renderEnv(jc.env, try ev.scope(&.{})) catch return fail(sh, results, try std.fmt.allocPrint(arena, "could not evaluate the container's env: {s}", .{ev.diag}));
            for (env) |e| {
                try w.writeAll("withEnvVariable(name:");
                try std.json.Stringify.value(e.name, .{}, w);
                try w.writeAll(",value:");
                try std.json.Stringify.value(e.value, .{}, w);
                try w.writeAll(") { ");
                extra_braces += 1;
            }
        }
        const provision = opts.provision and std.mem.eql(u8, job_image, default_image);
        if (provision) {
            try w.writeAll("withExec(args:");
            try std.json.Stringify.value([_][]const u8{ "sh", "-c", provision_script }, .{}, w);
            try w.writeAll(") { ");
        }
        try w.print("withWorkdir(path:\"{s}\") {{ ", .{workspace});
        for (cache_ids, 0..) |id, i| {
            try w.writeAll("withMountedCache(path:");
            try std.json.Stringify.value(package_cache_dirs[i].path, .{}, w);
            try w.writeAll(",cache:");
            try std.json.Stringify.value(id, .{}, w);
            try w.writeAll(") { ");
        }
        // The event payload, as on GitHub (actions read it through GITHUB_EVENT_PATH). It differs on
        // every run, so with step caching it travels in a volatile variable that each step writes to
        // the file; a payload too large for one variable is written into the container instead.
        const event = try ev.eventJson();
        if (step_cache and event.len <= max_event_env) {
            try w.writeAll("withVolatileVariable(name:\"" ++ event_env ++ "\",value:");
        } else {
            try w.writeAll("withNewFile(path:\"" ++ event_path ++ "\",contents:");
        }
        try std.json.Stringify.value(event, .{}, w);
        try w.writeAll(") { ");
        const defaults = try ev.defaultEnv();
        for (defaults) |e| {
            // Run-specific values do not take part in exec cache keys, so unchanged steps are reused.
            try w.writeAll(if (step_cache and isVolatile(e.name)) "withVolatileVariable(name:" else "withEnvVariable(name:");
            try std.json.Stringify.value(e.name, .{}, w);
            try w.writeAll(",value:");
            try std.json.Stringify.value(e.value, .{}, w);
            try w.writeAll(") { ");
        }
        // Workflow- and job-level env is part of every step's environment.
        var plain_job: std.ArrayList(job_mod.EnvVar) = .empty;
        var secret_job: std.ArrayList(SecretRef) = .empty;
        splitEnv(arena, transport, job, &secret_counter, ev.job_env.items, &plain_job, &secret_job, &err_msg) catch return fail(sh, results, err_msg);
        const job_env_nodes = try writeEnvNodes(w, plain_job.items, secret_job.items);
        try w.writeAll("id");
        for (0..defaults.len + job_env_nodes + cache_ids.len + 5 + extra_braces + @as(usize, if (provision) 1 else 0)) |_| try w.writeAll(" }");
        const data = gql(arena, transport, doc.written(), &err_msg) catch return fail(sh, results, err_msg);
        break :blk jsonFindString(data, "id") orelse return fail(sh, results, "Dagger returned no container");
    };

    var x: Exec = .{
        .arena = arena,
        .io = io,
        .transport = transport,
        .sh = sh,
        .ev = &ev,
        .job = &job,
        .container_id = container_id,
        .secret_counter = secret_counter,
        .next_fc = @intCast(job.steps.len + 1),
        .js_runtime = opts.js_runtime,
        .nesting = opts.nesting,
        .step_cache = step_cache,
        .output_keys = if (step_cache and opts.output_keys and job.github.repository.len > 0)
            try std.fmt.allocPrint(arena, "zig-runner/{s}/{s}/step-outputs", .{ job.github.repository, try packageCacheScope(arena, &ev, job.github.repository) })
        else
            null,
        .event_from_env = step_cache and (try ev.eventJson()).len <= max_event_env,
        .job_secret_env = jobEnvHasSecret(job, ev.job_env.items),
        .run_nonce = try runNonce(arena, io, &ev),
        .execs = try zeroed(arena, u32, logSteps(job.steps.len)),
        .next_log_step = @intCast(job.steps.len + 1),
        .loaded = try nulls(arena, Exec.LoadResult, job.steps.len),
        .pre_state = try emptySlices(arena, job_mod.EnvVar, job.steps.len),
        .summaries = try emptySlices(arena, u8, logSteps(job.steps.len)),
        .job_image = job_image,
        .observer = opts.observer,
    };

    ev.hash_files = .{ .ptr = &x, .hashFn = Exec.hashFiles };

    var watch: Watch = .{ .io = io, .transport = transport, .cancel = opts.cancel };
    var watching: ?std.Io.Future(void) = if (transport.abortFn != null) (io.concurrent(Watch.run, .{&watch}) catch null) else null;
    defer if (watching) |*f| {
        watch.done.store(true, .release);
        f.cancel(io);
    };

    // "Set up job": what GitHub's runner logs before the first step, including fetching every action.
    try x.logSetUp(opts);
    var downloaded: std.StringHashMapUnmanaged(void) = .empty;
    for (job.steps, 1..) |step, n| if (step.action == .uses and !step.action.uses.local) {
        const lr = try x.loadFor(@intCast(n), step.action.uses);
        if (lr != .ok) continue;
        const u = step.action.uses;
        const label = try std.fmt.allocPrint(arena, "{s}/{s}@{s}", .{ u.owner, u.name, u.ref });
        if ((try downloaded.getOrPut(arena, label)).found_existing) continue;
        x.setUpLine(if (lr.ok.sha.len > 0)
            try std.fmt.allocPrint(arena, "Download action repository '{s}' (SHA:{s})", .{ label, lr.ok.sha })
        else
            try std.fmt.allocPrint(arena, "Download action repository '{s}'", .{label}));
    };
    x.setUpLine(try std.fmt.allocPrint(arena, "Complete job name: {s}", .{if (job.display_name.len > 0) job.display_name else if (job.github.job.len > 0) job.github.job else "job"}));

    if ((job.container != null or job.services.len > 0) and !try x.startServices()) {
        var failed = try finish(arena, sh, results, "");
        failed.succeeded = false;
        failed.engine_error = null;
        failed.extra = x.extra.items;
        failed.next_log_step = x.next_log_step;
        return failed;
    }

    // JavaScript actions' `pre` scripts run before any step, as on GitHub.
    for (job.steps, 1..) |step, n| if (step.action == .uses) {
        x.runPre(@intCast(n), step) catch |e| switch (e) {
            error.EngineFailed => return finish(arena, sh, results, x.err_msg),
            else => return e,
        };
    };

    for (job.steps, results, 1..) |step, *res, n| {
        const num: u32 = @intCast(n);
        res.name = step.name;
        if (opts.cancel) |c| if (c.requested.load(.acquire)) {
            ev.cancelled = true;
        };

        // 1. The condition, with the job env visible.
        ev.diag = "";
        const sc0 = try ev.scope(&.{});
        if (step.name_expr) |ne| res.name = expr.evalString(arena, ne, sc0) catch step.name;
        const should_run = expr.evalCondition(arena, step.condition, sc0) catch {
            try failStep(&ev, sh, opts.observer, step, res, num, try std.fmt.allocPrint(arena, "could not evaluate the condition '{s}': {s}", .{ step.condition, ev.diag }), false);
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
            try failStep(&ev, sh, opts.observer, step, res, num, try std.fmt.allocPrint(arena, "could not evaluate env: {s}", .{ev.diag}), false);
            continue;
        };
        const sc1 = try ev.scope(step_env);
        const coe = std.mem.eql(u8, ev.render(step.continue_on_error, sc1) catch "false", "true");
        res.continued = coe;
        const timeout: ?[]const u8 = if (step.timeout_minutes) |t| (ev.render(t, sc1) catch null) else null;
        const timeout_ms: i64 = if (timeout) |t| ms: {
            const minutes = std.fmt.parseFloat(f64, std.mem.trim(u8, t, " ")) catch break :ms 0;
            break :ms if (minutes > 0) @intFromFloat(minutes * 60_000) else 0;
        } else 0;

        // Env that carries a secret goes in as a Dagger secret, the rest in the script.
        var plain_step_env: std.ArrayList(job_mod.EnvVar) = .empty;
        var secret_step_env: std.ArrayList(SecretRef) = .empty;
        splitEnv(arena, transport, job, &x.secret_counter, step_env, &plain_step_env, &secret_step_env, &x.err_msg) catch {
            try failStep(&ev, sh, opts.observer, step, res, num, try std.fmt.allocPrint(arena, "Dagger could not register a secret: {s}", .{x.err_msg}), coe);
            continue;
        };

        var resolved: Resolved = undefined;
        var mount_buf: [1]Mount = undefined;
        var mounts: []const Mount = &.{};
        switch (step.action) {
            .unsupported => |why| {
                try failStep(&ev, sh, opts.observer, step, res, num, why, coe);
                continue;
            },
            .script => |sc| {
                const script = ev.render(sc.script, sc1) catch {
                    try failStep(&ev, sh, opts.observer, step, res, num, try std.fmt.allocPrint(arena, "could not evaluate the script: {s}", .{ev.diag}), coe);
                    continue;
                };
                const shell: ?[]const u8 = if (sc.shell) |t| (ev.render(t, sc1) catch null) else null;
                if (shell) |sh_name| if (!job_mod.validShell(sh_name)) {
                    try failStep(&ev, sh, opts.observer, step, res, num, try job_mod.unsupportedShell(arena, sh_name), coe);
                    continue;
                };
                const wd: ?[]const u8 = if (sc.working_directory) |t| (ev.render(t, sc1) catch null) else null;
                resolved = .{ .run = .{ .script = script, .shell = shell, .working_directory = wd, .env = plain_step_env.items } };
                try logRunHeader(arena, sh, num, script, shell, try envContext(arena, ev.job_env.items, step_env));
            },
            .checkout => |inputs| {
                const rendered = ev.renderEnv(inputs, sc1) catch {
                    try failStep(&ev, sh, opts.observer, step, res, num, try std.fmt.allocPrint(arena, "could not evaluate the checkout inputs: {s}", .{ev.diag}), coe);
                    continue;
                };
                // As GitHub opens an action's log: the action and the inputs the workflow gave it.
                sh.append(num, try std.fmt.allocPrint(arena, "##[group]Run {s}", .{if (step.uses.len > 0) step.uses else "actions/checkout"}));
                // The given inputs, then actions/checkout's defaults (the same in v4 to v6), as GitHub shows them.
                sh.append(num, "with:");
                for (rendered) |in| sh.append(num, try std.fmt.allocPrint(arena, "  {s}: {s}", .{ in.name, firstLine(in.value) }));
                for (checkout_defaults) |d| {
                    const given = for (rendered) |in| (if (std.mem.eql(u8, in.name, d[0])) break true) else false;
                    if (given) continue;
                    const value = if (std.mem.eql(u8, d[0], "repository")) job.github.repository else d[1];
                    sh.append(num, try std.fmt.allocPrint(arena, "  {s}: {s}", .{ d[0], value }));
                }
                const co_env = try envContext(arena, ev.job_env.items, step_env);
                if (co_env.len > 0) {
                    sh.append(num, "env:");
                    for (co_env) |e| sh.append(num, try std.fmt.allocPrint(arena, "  {s}: {s}", .{ e.name, firstLine(e.value) }));
                }
                sh.append(num, "##[endgroup]");
                const co = switch (try job_mod.checkoutFromInputs(arena, rendered)) {
                    .ok => |c| c,
                    .unsupported => |why| {
                        try failStep(&ev, sh, opts.observer, step, res, num, why, coe);
                        continue;
                    },
                };
                const f = try fetchCheckout(arena, transport, job, co, x.gitAuth());
                if (f.result == .failed) {
                    try failStep(&ev, sh, opts.observer, step, res, num, f.result.failed, coe);
                    continue;
                }
                resolved = .{ .checkout = f };
                mount_buf[0] = .{ .dir = .{ .path = f.mount, .id = f.result.dir } };
                mounts = &mount_buf;
            },
            .uses, .docker => {
                res.started_ms = std.Io.Clock.real.now(io).toMilliseconds();
                if (opts.observer) |o| o.started(num, res.name, res.started_ms);
                watch.begin(if (timeout_ms > 0) res.started_ms + timeout_ms else 0);
                const ran = switch (step.action) {
                    .uses => |u| x.runAction(num, u, sc1, plain_step_env.items, secret_step_env.items, false),
                    .docker => |d| x.runImageStep(num, d, sc1, plain_step_env.items, secret_step_env.items),
                    else => unreachable,
                };
                const intr = watch.end();
                const out = ran catch |e| switch (e) {
                    error.EngineFailed => if (intr != .none) {
                        try stepInterrupted(&ev, sh, opts.observer, step, res, num, coe, intr, timeout orelse "");
                        continue;
                    } else return engineFailed(&x, opts.observer, res, num, coe, results),
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
        watch.begin(if (timeout_ms > 0) res.started_ms + timeout_ms else 0);
        const ran = x.execScript(num, num, resolved, if (step.context_name.len > 0) step.context_name else step.id, secret_step_env.items, mounts);
        const intr = watch.end();
        const out = ran catch |e| switch (e) {
            error.EngineFailed => if (intr != .none) {
                try stepInterrupted(&ev, sh, opts.observer, step, res, num, coe, intr, timeout orelse "");
                continue;
            } else return engineFailed(&x, opts.observer, res, num, coe, results),
            else => return e,
        };
        if (resolved == .run and out.code != 0) logExitCode(sh, num, out.code);
        // As actions/checkout, a post step once the checkout ran (see `Post.checkout`).
        if (resolved == .checkout) try x.posts.append(arena, .{
            .num = num,
            .name = try std.fmt.allocPrint(arena, "Post {s}", .{res.name}),
            .act = undefined,
            .u = undefined,
            .script = "",
            .condition = "always()",
            .inputs = &.{},
            .step_env = &.{},
            .step_secret = &.{},
            .state = &.{},
            .checkout = true,
        });
        res.completed_ms = std.Io.Clock.real.now(io).toMilliseconds();
        res.exit_code = out.code;
        res.outcome = if (out.code == 0) .success else .failure;
        try ev.record(step, res.outcome, coe, out.outputs);
        if (res.outcome == .failure and !coe) ev.job_failed = true;
        if (opts.observer) |o| o.finished(num, res.*);
    }
    // Then their `post` scripts, last first, and the services.
    const stopping = job.services.len > 0 or job.container != null;
    if (x.posts.items.len > 0 or stopping) if (opts.observer) |o| if (o.postsFn) |f| f(o.ptr, @intCast(x.posts.items.len), stopping);
    x.runPosts() catch |e| switch (e) {
        error.EngineFailed => return finish(arena, sh, results, x.err_msg),
        else => return e,
    };
    try x.stopServices();
    var result = try finish(arena, sh, results, "");
    if (x.hook_failed) result.succeeded = false;
    if (opts.cancel) |c| if (c.requested.load(.acquire)) {
        ev.cancelled = true;
    };
    if (ev.cancelled) {
        result.cancelled = true;
        result.succeeded = false;
    }
    result.extra = x.extra.items;
    result.next_log_step = x.next_log_step;
    result.summaries = x.summaries;
    try jobOutputs(arena, &ev, job, &result);
    return result;
}

/// Evaluates the job's outputs as GitHub's runner does when it finishes a job: against the final
/// contexts (the steps' outputs and outcomes), each output a string. One that would carry a secret is
/// dropped with GitHub's warning (later jobs could read it); one that cannot be evaluated is dropped
/// with the reason.
fn jobOutputs(arena: Allocator, ev: *Evaluator, job: job_mod.Job, result: *Result) !void {
    if (job.outputs.len == 0) return;
    var outs: std.ArrayList(job_mod.EnvVar) = .empty;
    var lines: std.ArrayList([]const u8) = .empty;
    try lines.append(arena, "Evaluate and set job outputs");
    for (job.outputs) |o| {
        ev.diag = "";
        const sc = try ev.scope(&.{});
        const value = ev.render(o.value, sc) catch {
            try lines.append(arena, try std.fmt.allocPrint(arena, "##[warning]Could not evaluate output '{s}': {s}", .{ o.name, ev.diag }));
            continue;
        };
        if (containsSecret(job, value)) {
            try lines.append(arena, try std.fmt.allocPrint(arena, "##[warning]Skip output '{s}' since it may contain secret.", .{o.name}));
            continue;
        }
        try outs.append(arena, .{ .name = o.name, .value = value });
        try lines.append(arena, try std.fmt.allocPrint(arena, "Set output '{s}'", .{o.name}));
    }
    result.outputs = outs.items;
    result.output_lines = lines.items;
}

fn zeroed(arena: Allocator, comptime T: type, n: usize) ![]T {
    const s = try arena.alloc(T, n);
    @memset(s, 0);
    return s;
}

fn nulls(arena: Allocator, comptime T: type, n: usize) ![]?T {
    const s = try arena.alloc(?T, n);
    @memset(s, null);
    return s;
}

fn emptySlices(arena: Allocator, comptime T: type, n: usize) ![][]const T {
    const s = try arena.alloc([]const T, n);
    @memset(s, &.{});
    return s;
}

/// A directory mounted into the container for one exec.
const Mount = union(enum) {
    dir: struct { path: []const u8, id: []const u8 },
    file: struct { path: []const u8, id: []const u8, permissions: u32 },
    new_file: struct { path: []const u8, contents: []const u8, permissions: u32 },
};

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
    js_runtime: config.JsRuntime,
    /// Whether the JavaScript runtime is in the container yet (it is added by the first JS action).
    js_mounted: bool = false,
    /// Per log step (index = step - 1, see `ExtraStep`): execs so far.
    execs: []u32,
    /// The next log step number for a `pre` or `post` script, and the scripts that ran.
    next_log_step: u32,
    extra: std.ArrayList(ExtraStep) = .empty,
    /// Per job step (index = step - 1): the action loaded for it, the state its `pre` saved.
    loaded: []?LoadResult,
    pre_state: [][]const job_mod.EnvVar,
    /// What each log step wrote to $GITHUB_STEP_SUMMARY (index = log step - 1), uploaded with the
    /// logs so GitHub shows it on the run's summary page.
    summaries: [][]const u8,
    /// Action directories already mounted (by path), so a later phase sees what an earlier one left.
    mounted_actions: std.StringHashMapUnmanaged(void) = .empty,
    /// JavaScript actions' `post` scripts, run after the job's steps in reverse order.
    posts: std.ArrayList(Post) = .empty,
    /// A `pre` or `post` script failed: the job fails, whatever its steps' results.
    hook_failed: bool = false,
    /// Steps may use the job's Dagger engine (see `Options.nesting`).
    nesting: bool,
    /// Unchanged steps may be reused across runs (see `Options.step_cache`).
    step_cache: bool,
    /// With `Options.output_keys`: the key of the cache volume that stores steps' changes by digest
    /// (scoped like the package caches), and the volume once created.
    output_keys: ?[]const u8,
    outputs_volume: ?[]const u8 = null,
    /// The event payload is in ZIG_RUNNER_EVENT; each step writes it to GITHUB_EVENT_PATH.
    event_from_env: bool,
    /// Workflow- or job-level env carries a secret, so every step uses secrets.
    job_secret_env: bool,
    /// Differs on every run (and attempt): makes steps that use secrets run every time.
    run_nonce: []const u8,
    /// The job token as a Dagger secret, for ACTIONS_ID_TOKEN_REQUEST_TOKEN (registered on first use).
    id_token_secret: ?[]const u8 = null,
    /// The job's GITHUB_TOKEN as a Dagger secret, for git fetches (see `gitAuth`).
    git_auth: ?union(enum) { none, id: []const u8 } = null,
    /// Docker actions: the static busybox that starts their command, their images (pulled or built
    /// once per job, by `DockerRun.Image` key), and /github/home, which they share, as on GitHub.
    busybox_id: ?[]const u8 = null,
    /// How deep composite actions are nested right now (see `max_composite_depth`).
    depth: u32 = 0,
    /// An empty Directory, for the directories a Docker action's container needs.
    empty_dir: []const u8 = "",
    images: std.StringHashMapUnmanaged(ImageInfo) = .empty,
    docker_home: ?[]const u8 = null,
    /// Told when the runner's own steps start and finish (see `Observer`).
    observer: ?Observer = null,
    /// The image the steps run in: `container:`'s, or the runner's.
    job_image: []const u8 = default_image,
    /// The job's image uses musl (Alpine): JavaScript actions get the runtime's musl build.
    musl: bool = false,
    /// The job's `services:`, running for the whole job (see `startServices`).
    services: std.ArrayList(RunningService) = .empty,
    /// Shell lines at the start of every step that forward `localhost:<port>` to the services, as
    /// a job on GitHub's runner reaches them through ports published on its host.
    forward_prelude: []const u8 = "",

    const RunningService = struct {
        name: []const u8,
        id: []const u8,
        ports: []const ServicePort,
    };

    const Post = struct {
        num: u32,
        /// "Post Run x@v1": the step's name for the step's own action, the action for a nested one.
        name: []const u8,
        act: Loaded,
        u: job_mod.Uses,
        script: []const u8,
        condition: []const u8,
        inputs: []const expr.Value.Entry,
        step_env: []const job_mod.EnvVar,
        step_secret: []const SecretRef,
        state: []const job_mod.EnvVar,
        /// A Docker action's `post-entrypoint` (`script` is then the entrypoint).
        docker: ?DockerRun = null,
        /// The built-in checkout's: actions/checkout has a post step (it removes the credentials it
        /// stored); this checkout stores none, so it only takes its place in the job's steps.
        checkout: bool = false,
    };

    /// A Docker action to run: its image and how it is started (see `runContainer`).
    const DockerRun = struct {
        image: Image,
        /// Replaces the image's entrypoint, and then its command too, as `docker run --entrypoint` does.
        entrypoint: ?[]const u8 = null,
        /// Null: the image's command.
        args: ?[]const []const u8 = null,
        /// The step's env, INPUT_<NAME>, the action's `env:`.
        env: []const job_mod.EnvVar,
        secret: []const SecretRef,
        /// `owner/repo@ref` or `docker://<image>`, for the log and messages.
        label: []const u8,
        /// GITHUB_ACTION_REPOSITORY and GITHUB_ACTION_REF; empty for a `docker://` step.
        repository: []const u8 = "",
        ref: []const u8 = "",
        /// The `with:` inputs the workflow gave, for the log.
        shown: []const job_mod.EnvVar = &.{},
        /// The step's own env (also in `env` and `secret`), shown in the log.
        step_env: []const job_mod.EnvVar = &.{},
        step_secret: []const SecretRef = &.{},

        const Image = union(enum) {
            pull: []const u8,
            /// Built from `dockerfile` with `context` as the build context, both paths in the Directory `dir`.
            build: struct { dir: []const u8, context: []const u8, dockerfile: []const u8 },
        };
    };

    /// `user` is the image's USER ("" for root): the action runs as it, so it gets the directories it writes.
    const ImageInfo = struct { id: []const u8, entrypoint: []const []const u8, cmd: []const []const u8, user: []const u8 };

    const Phase = enum {
        pre,
        main,
        post,
        fn label(p: Phase) []const u8 {
            return switch (p) {
                .pre => "Pre",
                .main => "Run",
                .post => "Post",
            };
        }
    };

    const ExecOut = struct {
        code: i32,
        outputs: []const job_mod.EnvVar,
        /// From GITHUB_STATE and `::save-state`; a JavaScript action's later phases get it as STATE_*.
        state: []const job_mod.EnvVar = &.{},
    };

    /// Runs one script in the job's container, logging as step `num`, and applies its file
    /// commands. `error.EngineFailed` (with `err_msg`) when Dagger itself failed.
    fn execScript(x: *Exec, num: u32, fc: u32, resolved_in: Resolved, action_name: []const u8, secret_env_in: []const SecretRef, mounts: []const Mount) !ExecOut {
        const arena = x.arena;
        const ev = x.ev;
        // Secret variables are for scripts only; they reach them through aliases (`secretAlias`).
        var resolved = resolved_in;
        var secret_env: []const SecretRef = if (resolved == .run) secret_env_in else &.{};
        if (resolved == .run) {
            const uses_secrets = secret_env.len > 0 or x.job_secret_env or containsSecret(x.job.*, resolved.run.script);
            // With `id-token: write`, every step can request OIDC tokens, as on GitHub (`curl
            // "$ACTIONS_ID_TOKEN_REQUEST_URL"` in a script, `core.getIDToken()` in an action).
            const oidc = try x.idToken();
            if (oidc) |t| {
                resolved.run.env = try std.mem.concat(arena, job_mod.EnvVar, &.{ resolved.run.env, &.{t.url} });
                secret_env = try std.mem.concat(arena, SecretRef, &.{ secret_env, &.{t.token} });
            }
            const names = try arena.alloc([]const u8, secret_env.len);
            for (secret_env, names) |s, *n| n.* = s.name;
            resolved.run.secret_env = names;
            resolved.run.write_event = x.event_from_env;
            // A step that uses secrets (a deploy, a publish) must not be skipped because an earlier run
            // had the same inputs, and one that reads run-specific values must not replay an earlier
            // run's; every step after it then runs too. One that can get OIDC tokens may publish or
            // deploy without any secret (npm's trusted publishing, cloud logins), so it runs too.
            if (x.step_cache) {
                const reason: ?[]const u8 = if (uses_secrets)
                    "it uses secrets"
                else if (oidc != null)
                    "it can request OIDC tokens (id-token: write)"
                else if (readsRunSpecific(resolved.run.script))
                    "it reads run-specific values"
                else
                    null;
                if (reason) |r| resolved.run.always_run = try std.fmt.allocPrint(arena, "zig-runner runs this step every time: {s} (run {s})", .{ r, x.run_nonce });
            }
        }
        const script = try std.mem.concat(arena, u8, &.{ x.forward_prelude, try stepScriptFc(arena, num, fc, resolved, action_name) });
        const before = x.container_id;
        var doc: std.Io.Writer.Allocating = .init(arena);
        const w = &doc.writer;
        try w.writeAll("{ loadContainerFromID(id:");
        try std.json.Stringify.value(x.container_id, .{}, w);
        try w.writeAll(") { ");
        const env_start = doc.written().len;
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
        // The variables earlier steps set, which the container before this step lacks.
        const env_nodes = try arena.dupe(u8, doc.written()[env_start..]);
        const env_braces = braces - 2;
        var mount_doc: std.Io.Writer.Allocating = .init(arena);
        const mw = &mount_doc.writer;
        for (mounts) |m| {
            switch (m) {
                .dir => |d| {
                    try mw.writeAll("withDirectory(path:");
                    try std.json.Stringify.value(d.path, .{}, mw);
                    try mw.writeAll(",source:");
                    try std.json.Stringify.value(d.id, .{}, mw);
                },
                .file => |f| {
                    try mw.writeAll("withFile(path:");
                    try std.json.Stringify.value(f.path, .{}, mw);
                    try mw.writeAll(",source:");
                    try std.json.Stringify.value(f.id, .{}, mw);
                    try mw.print(",permissions:{d}", .{f.permissions});
                },
                .new_file => |f| {
                    try mw.writeAll("withNewFile(path:");
                    try std.json.Stringify.value(f.path, .{}, mw);
                    try mw.writeAll(",contents:");
                    try std.json.Stringify.value(f.contents, .{}, mw);
                    try mw.print(",permissions:{d}", .{f.permissions});
                },
            }
            try mw.writeAll(") { ");
        }
        for (secret_env, 0..) |sr, i| {
            try w.writeAll("withSecretVariable(name:");
            try std.json.Stringify.value(try secretAlias(arena, i), .{}, w);
            try w.writeAll(",secret:");
            try std.json.Stringify.value(sr.id, .{}, w);
            try w.writeAll(") { ");
            braces += 1;
        }
        try w.writeAll(mount_doc.written());
        braces += mounts.len;
        try w.writeAll("withExec(args:");
        try std.json.Stringify.value([_][]const u8{ "sh", "-c", script }, .{}, w);
        // Nesting gives the step's `dagger` CLI a session on this engine, sharing its cache. The
        // container id is read after the step's secrets are removed (below).
        try w.writeAll(if (x.nesting) ",expect:ANY,experimentalPrivilegedNesting:true) { exitCode stdout stderr" else ",expect:ANY) { exitCode stdout stderr");
        try w.print(" fc_all: file(path:\"{s}\") {{ contents }}", .{try fcPath(arena, "all", fc)});
        // The next step starts from this container without the step's secrets.
        for (secret_env, 0..) |_, i| {
            try w.writeAll(" withoutSecretVariable(name:");
            try std.json.Stringify.value(try secretAlias(arena, i), .{}, w);
            try w.writeAll(") {");
        }
        try w.writeAll(" id");
        for (secret_env) |_| try w.writeAll(" }");
        try w.writeAll(" }");
        for (0..braces) |_| try w.writeAll(" }");

        x.beginExec(num);
        const data = gql(arena, x.transport, doc.written(), &x.err_msg) catch return error.EngineFailed;
        if (jsonFindString(data, "id")) |id| x.container_id = id;
        const out = try x.collect(num, data);
        if (x.output_keys != null and resolved == .run and resolved.run.always_run != null and out.code == 0) {
            const pre = try std.mem.concat(arena, u8, &.{ env_nodes, mount_doc.written() });
            if (try x.outputKeyed(num, before, pre, env_braces + mounts.len, x.container_id)) |id| x.container_id = id;
        }
        return out;
    }

    /// Where a step's changes are stored, and where the next step's container mounts the store and
    /// busybox while copying them in.
    const outputs_store = "/zig-runner-outputs";
    /// Paths whose changes are left out of a step's output: neither keyed nor carried to the next
    /// step. They change on every run without being anything a later step uses, so keying on them
    /// would make every digest new. Each step's file commands (the runner has read them, and
    /// @actions/core writes a random delimiter into them), and Go's local telemetry counters
    /// (rewritten by every `go` command).
    const outputs_ignored = [_][]const u8{ fc_dir, "/root/.config/go/telemetry" };

    /// Busybox takes its first argument as the applet only when its own name starts with "busybox".
    const outputs_busybox = "/busybox.zig-runner";

    /// For a step that always runs: the container the next step starts from, keyed on what the step
    /// produced rather than on the step. That is `before` (the container before the step) with what
    /// the runner added for the step (`pre`, `pre_braces` nodes: the variables earlier steps set, the
    /// action's code and the JavaScript runtime, whose recipes do not change from run to run), and
    /// one exec that applies the step's changes (copied from the store at their content digest, removed paths deleted). When
    /// the step produces the same files as in an earlier run, the digest, the exec, and so every
    /// later step's key are the same, and the later steps can be replayed.
    ///
    /// The content stays in the engine: the runner only handles the digest and removed paths. Null
    /// (keep the step's own container) when anything fails, so the job runs as without output keys.
    fn outputKeyed(x: *Exec, num: u32, before: []const u8, pre: []const u8, pre_braces: usize, after: []const u8) !?[]const u8 {
        const arena = x.arena;
        const debug = struct {
            fn line(ex: *Exec, n: u32, comptime fmt: []const u8, args: anytype) void {
                if (ex.sh.step_debug) ex.sh.appendFmt(n, "##[debug]" ++ fmt, args);
            }
        }.line;
        var msg: []const u8 = "";
        const busybox = (try x.busyboxFile(num)) orelse return null;
        const volume = x.outputs_volume orelse vol: {
            const data = gql(arena, x.transport, try std.fmt.allocPrint(arena, "{{ cacheVolume(key:{f}) {{ id }} }}", .{std.json.fmt(x.output_keys.?, .{})}), &msg) catch {
                debug(x, num, "Output keys: no store: {s}", .{msg});
                return null;
            };
            const id = jsonFindString(data, "id") orelse return null;
            x.outputs_volume = id;
            break :vol id;
        };

        // What the step changed in the container's filesystem (cache volumes and mounts are not part
        // of it), as a directory with its digest, and what it removed.
        var without: std.Io.Writer.Allocating = .init(arena);
        for (outputs_ignored) |p| try without.writer.print("withoutDirectory(path:{f}) {{ ", .{std.json.fmt(p, .{})});
        const closing = try arena.alloc(u8, 2 * outputs_ignored.len);
        for (0..outputs_ignored.len) |i| @memcpy(closing[2 * i ..][0..2], " }");
        const pre_closing = try arena.alloc(u8, 2 * pre_braces);
        for (0..pre_braces) |i| @memcpy(pre_closing[2 * i ..][0..2], " }");
        const older = gql(arena, x.transport, try std.fmt.allocPrint(arena, "{{ loadContainerFromID(id:{f}) {{ {s}zig_base: id zig_fs: rootfs {{ {s}id{s} }}{s} }} }}", .{ std.json.fmt(before, .{}), pre, without.written(), closing, pre_closing }), &msg) catch {
            debug(x, num, "Output keys: {s}", .{msg});
            return null;
        };
        const base = jsonFindString(older, "zig_base") orelse return null;
        const older_id = (if (jsonFind(older, "zig_fs")) |f| jsonFindString(f, "id") else null) orelse return null;
        const changes = gql(arena, x.transport, try std.fmt.allocPrint(arena, "{{ loadContainerFromID(id:{f}) {{ rootfs {{ {s}changes(from:{f}) {{ removedPaths layer {{ id digest }} }}{s} }} }} }}", .{ std.json.fmt(after, .{}), without.written(), std.json.fmt(older_id, .{}), closing }), &msg) catch {
            debug(x, num, "Output keys: {s}", .{msg});
            return null;
        };
        const layer = jsonFind(changes, "layer") orelse return null;
        const layer_id = jsonFindString(layer, "id") orelse return null;
        const digest_full = jsonFindString(layer, "digest") orelse return null;
        const digest = if (std.mem.indexOfScalar(u8, digest_full, ':')) |c| digest_full[c + 1 ..] else digest_full;
        if (digest.len == 0 or std.mem.indexOfNone(u8, digest, "0123456789abcdef") != null) return null;
        var removed: std.ArrayList([]const u8) = .empty;
        if (jsonFind(changes, "removedPaths")) |r| if (r == .array) for (r.array.items) |p| {
            if (p == .string) try removed.append(arena, p.string);
        };

        // Store it under its digest unless it is there. Another job may store the same digest at the
        // same time: `mv -T` onto an existing directory fails and leaves it as it was. Each store
        // copies to its own temporary name (the run's nonce is shared by its matrix jobs).
        var tmp_raw: [8]u8 = undefined;
        x.io.random(&tmp_raw);
        const tmp_name = std.fmt.bytesToHex(tmp_raw, .lower);
        const store_script = try std.fmt.allocPrint(arena,
            \\d=/store/{s}; test -d "$d" && exit 0
            \\t="$d.tmp.{s}"; /bin/busybox rm -rf "$t"; /bin/busybox cp -a /in/. "$t" || exit 1
            \\/bin/busybox mv -T "$t" "$d" 2>/dev/null || /bin/busybox rm -rf "$t"; test -d "$d"
        , .{ digest, &tmp_name });
        _ = gql(arena, x.transport, try std.fmt.allocPrint(arena, "{{ container {{ withFile(path:\"/bin/busybox\",source:{f},permissions:493) {{ withMountedCache(path:\"/store\",cache:{f}) {{ withMountedDirectory(path:\"/in\",source:{f}) {{ withExec(args:{f}) {{ exitCode }} }} }} }} }} }}", .{
            std.json.fmt(busybox, .{}),
            std.json.fmt(volume, .{}),
            std.json.fmt(layer_id, .{}),
            std.json.fmt([_][]const u8{ "/bin/busybox", "sh", "-c", store_script }, .{}),
        }), &msg) catch {
            debug(x, num, "Output keys: could not store the step's changes: {s}", .{msg});
            return null;
        };

        // The next step's container: the digest and removed paths are the exec's arguments, so they
        // are what its key depends on.
        var apply: std.Io.Writer.Allocating = .init(arena);
        const aw = &apply.writer;
        try aw.writeAll("set -e\ncd /\n");
        if (removed.items.len > 0) {
            try aw.writeAll(outputs_busybox ++ " rm -rf --");
            for (removed.items) |p| {
                try aw.writeAll(" ");
                try shellQuote(aw, try std.fmt.allocPrint(arena, "/{s}", .{std.mem.trimStart(u8, p, "/")}));
            }
            try aw.writeAll("\n");
        }
        try aw.print(outputs_busybox ++ " cp -a " ++ outputs_store ++ "/{s}/. /\n", .{digest});
        var doc: std.Io.Writer.Allocating = .init(arena);
        const w = &doc.writer;
        try w.print("{{ loadContainerFromID(id:{f}) {{ ", .{std.json.fmt(base, .{})});
        try w.print("withMountedCache(path:\"" ++ outputs_store ++ "\",cache:{f}) {{ withMountedFile(path:\"" ++ outputs_busybox ++ "\",source:{f}) {{ ", .{ std.json.fmt(volume, .{}), std.json.fmt(busybox, .{}) });
        // Run now (exitCode), so a failure falls back here rather than failing the next step.
        try w.print("withExec(args:{f}) {{ exitCode withoutMount(path:\"" ++ outputs_store ++ "\") {{ withoutMount(path:\"" ++ outputs_busybox ++ "\") {{ id", .{std.json.fmt([_][]const u8{ outputs_busybox, "sh", "-c", apply.written() }, .{})});
        for (0..5 + 2) |_| try w.writeAll(" }");
        const next = gql(arena, x.transport, doc.written(), &msg) catch {
            debug(x, num, "Output keys: could not apply the step's changes: {s}", .{msg});
            return null;
        };
        const id = jsonFindString(next, "id") orelse return null;
        debug(x, num, "Output keys: the next steps start from this step's output, sha256:{s} ({d} removed paths)", .{ digest[0..@min(12, digest.len)], removed.items.len });
        return id;
    }

    /// Several execs can log as one step (a composite action's steps, a JavaScript action's pre, main
    /// and post): after the first, count each one's live lines afresh, so a cached one is replayed.
    fn beginExec(x: *Exec, num: u32) void {
        if (x.execs[num - 1] > 0) {
            x.sh.live_lines[num - 1].store(0, .monotonic);
            x.sh.ended[num - 1].store(false, .release);
        }
        x.execs[num - 1] += 1;
    }

    /// An exec's result (`exitCode stdout stderr fc_<kind> { contents }`): its output, replayed if it
    /// was cached, and its file commands applied.
    fn collect(x: *Exec, num: u32, data: std.json.Value) !ExecOut {
        const arena = x.arena;
        const ev = x.ev;
        var code: i32 = if (jsonFind(data, "exitCode")) |c| (if (c == .integer) @intCast(c.integer) else 1) else 1;

        // A cached step prints no log lines. Wait briefly for a live stream, then replay the result.
        _ = awaitLiveOrReplay(x.io, x.sh, num, jsonFindString(data, "stdout") orelse "", jsonFindString(data, "stderr") orelse "");

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
        if (fileCommand(data, "fc_step_summary")) |text| if (text.len > 0 and num <= x.summaries.len) {
            const so_far = x.summaries[num - 1];
            if (so_far.len + text.len > max_summary_bytes) {
                // GitHub's runner's words; the summary is not uploaded.
                x.sh.append(num, try std.fmt.allocPrint(arena, "##[error]$GITHUB_STEP_SUMMARY upload aborted, supports content up to a size of {d}k, got {d}k. For more information see: https://docs.github.com/actions/using-workflows/workflow-commands-for-github-actions#adding-a-markdown-summary", .{ max_summary_bytes / 1024, (so_far.len + text.len) / 1024 }));
            } else x.summaries[num - 1] = try std.mem.concat(arena, u8, &.{ so_far, text });
        };
        if (cmd_error) |msg| {
            x.sh.append(num, msg);
            if (code == 0) code = 1;
        }
        // Outputs set with the deprecated `::set-output` come after GITHUB_OUTPUT's, which win.
        const legacy = x.sh.takeOutputs(num);
        if (legacy.len > 0) outputs = try std.mem.concat(arena, job_mod.EnvVar, &.{ outputs, legacy });
        var state: []const job_mod.EnvVar = x.sh.takeState(num);
        if (fileCommand(data, "fc_state")) |text| switch (try commands.parseKeyValues(arena, text)) {
            .ok => |kv| state = try std.mem.concat(arena, job_mod.EnvVar, &.{ state, kv }),
            .invalid => |why| x.sh.append(num, try std.fmt.allocPrint(arena, "Unable to process the GITHUB_STATE file command: {s}", .{why})),
        };
        return .{ .code = code, .outputs = outputs, .state = state };
    }

    const ActionOut = struct { failed: bool, exit_code: i32 = 0, outputs: []const job_mod.EnvVar = &.{} };

    fn actionFailed(x: *Exec, num: u32, comptime fmt: []const u8, args: anytype) !ActionOut {
        x.sh.append(num, try std.fmt.allocPrint(x.arena, fmt, args));
        return .{ .failed = true, .exit_code = 1 };
    }

    /// Runs a `uses:` step: reads the action's metadata and, for a composite action, runs its steps
    /// as part of step `num`. `caller` is the scope of the `uses:` step (for `with:` and defaults);
    /// `step_env` and `step_secret` are its evaluated `env:`, which its steps inherit.
    /// `nested`: a step of a composite action (loaded here, not with the job's own steps). Recursive
    /// through composite actions' `uses:` steps, hence `anyerror`.
    fn runAction(x: *Exec, num: u32, u: job_mod.Uses, caller: expr.Scope, step_env: []const job_mod.EnvVar, step_secret: []const SecretRef, nested: bool) anyerror!ActionOut {
        const arena = x.arena;
        const ev = x.ev;
        const loaded = if (!nested) try x.loadFor(num, u) else if (u.local) try x.loadLocal(u) else try x.loadAction(u);
        const act = switch (loaded) {
            .failed => |msg| return x.actionFailed(num, "{s}", .{msg}),
            .ok => |a| a,
        };

        const inputs = switch (try x.resolveInputs(num, act, u, caller, true)) {
            .failed => |out| return out,
            .ok => |in| in,
        };

        const steps = switch (act.meta.runs) {
            .composite => |st| st,
            .node => |nd| return x.runJs(num, act, u, nd, inputs, step_env, step_secret),
            .docker => |dk| return x.runDocker(num, act, u, dk, inputs, step_env, step_secret),
        };

        // GitHub allows composite actions nested 9 deep.
        if (x.depth >= max_composite_depth) return x.actionFailed(num, "{s}: composite actions can be nested at most {d} levels deep", .{ act.ref_label, max_composite_depth });
        x.depth += 1;
        defer x.depth -= 1;

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
        const repository = act.repository;
        ev.steps = .empty;
        ev.inputs = .{ .object = inputs };
        ev.github = try withEntries(arena, ev.github, &.{
            .{ .key = "action_path", .value = .{ .string = act.path } },
            .{ .key = "action_repository", .value = .{ .string = repository } },
            .{ .key = "action_ref", .value = .{ .string = act.ref } },
        });
        ev.job_failed = false;
        const action_env = [_]job_mod.EnvVar{
            .{ .name = "GITHUB_ACTION_PATH", .value = act.path },
            .{ .name = "GITHUB_ACTION_REPOSITORY", .value = repository },
            .{ .name = "GITHUB_ACTION_REF", .value = act.ref },
        };

        var failed = false;
        var exit_code: i32 = 0;
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
                // `uses:`: its `with:` is evaluated here, in the action's scope; it inherits the env.
                var with: std.ArrayList(job_mod.Input) = .empty;
                for (st.with) |kv| {
                    const v = expr.interpolate(arena, kv.value, sc) catch {
                        env_error = try std.fmt.allocPrint(arena, "could not evaluate input '{s}': {s}", .{ kv.name, ev.diag });
                        break;
                    };
                    try with.append(arena, .{ .name = kv.name, .value = .{ .lit = v } });
                }
                if (env_error) |msg| {
                    try x.nestedFailed(num, ctx_id, display, msg, &failed, &exit_code);
                    continue;
                }
                var plain: std.ArrayList(job_mod.EnvVar) = .empty;
                var secret: std.ArrayList(SecretRef) = .empty;
                try plain.appendSlice(arena, step_env);
                try secret.appendSlice(arena, step_secret);
                splitEnv(arena, x.transport, x.job.*, &x.secret_counter, nested_env.items, &plain, &secret, &x.err_msg) catch return error.EngineFailed;
                const out = try x.runNested(num, ctx_id, st.uses.?, with.items, sc, plain.items, secret.items);
                const ok = !out.failed;
                try ev.steps.append(arena, .{ .id = ctx_id, .outcome = if (ok) "success" else "failure", .conclusion = if (ok or coe) "success" else "failure", .outputs = out.outputs });
                if (!ok and !coe) {
                    failed = true;
                    ev.job_failed = true;
                    if (exit_code == 0) exit_code = if (out.exit_code != 0) out.exit_code else 1;
                }
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
                try x.nestedFailed(num, ctx_id, display, try job_mod.unsupportedShell(arena, shell), &failed, &exit_code);
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
            x.sh.append(num, try shellLine(arena, shell));
            const shown_env = try envContext(arena, ev.job_env.items, all_env);
            if (shown_env.len > 0) {
                x.sh.append(num, "env:");
                for (shown_env) |e| x.sh.append(num, try std.fmt.allocPrint(arena, "  {s}: {s}", .{ e.name, firstLine(e.value) }));
            }
            x.sh.append(num, "##[endgroup]");

            // The action's files are mounted once per job; its steps may change them, as on GitHub.
            const mounted = x.mounted_actions.contains(act.mount);
            const m = [_]Mount{.{ .dir = .{ .path = act.mount, .id = act.dir } }};
            const fc = x.next_fc;
            x.next_fc += 1;
            const out = try x.execScript(num, fc, .{ .run = .{ .script = script, .shell = shell, .working_directory = wd, .env = plain.items } }, ctx_id, secret.items, if (mounted) &.{} else &m);
            try x.mounted_actions.put(arena, act.mount, {});
            if (out.code != 0) logExitCode(x.sh, num, out.code);
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

    /// A composite action's `uses:` step, run as part of step `num` like a step of the job: the built-in
    /// checkout for actions/checkout, a `docker://` image, or a local or remote action (which may be
    /// composite again). Nested actions' `pre` scripts do not run; their `post` scripts do, at the end.
    fn runNested(x: *Exec, num: u32, ctx_id: []const u8, uses_text: []const u8, with: []const job_mod.Input, caller: expr.Scope, step_env: []const job_mod.EnvVar, step_secret: []const SecretRef) anyerror!ActionOut {
        const parsed = action.parseUses(uses_text) orelse return x.actionFailed(num, "uses: {s} is not a valid action reference", .{uses_text});
        switch (parsed) {
            .docker => |image| return x.runImageStep(num, .{ .image = image, .inputs = with }, caller, step_env, step_secret),
            .local => |raw| {
                const dir = job_mod.localActionPath(raw) orelse return x.actionFailed(num, "uses: {s}: a local action must be inside the workspace", .{raw});
                return x.runAction(num, .{ .owner = "", .name = "", .path = dir, .ref = "", .inputs = with, .local = true }, caller, step_env, step_secret, true);
            },
            .repo => |r| {
                if (std.ascii.eqlIgnoreCase(r.owner, "actions") and std.ascii.eqlIgnoreCase(r.name, "checkout") and r.path.len == 0) return x.runNestedCheckout(num, ctx_id, with);
                return x.runAction(num, .{ .owner = r.owner, .name = r.name, .path = r.path, .ref = r.ref, .inputs = with }, caller, step_env, step_secret, true);
            },
        }
    }

    /// actions/checkout inside a composite action: the runner's built-in checkout, as for the job's steps.
    fn runNestedCheckout(x: *Exec, num: u32, ctx_id: []const u8, with: []const job_mod.Input) !ActionOut {
        const arena = x.arena;
        const kv = try arena.alloc(job_mod.EnvVar, with.len);
        for (with, kv) |in, *dst| dst.* = .{ .name = in.name, .value = in.value.lit };
        const co = switch (try job_mod.checkoutFromInputs(arena, kv)) {
            .ok => |c| c,
            .unsupported => |why| return x.actionFailed(num, "{s}", .{why}),
        };
        const f = try fetchCheckout(arena, x.transport, x.job.*, co, x.gitAuth());
        if (f.result == .failed) return x.actionFailed(num, "{s}", .{f.result.failed});
        const m = [_]Mount{.{ .dir = .{ .path = f.mount, .id = f.result.dir } }};
        const fc = x.next_fc;
        x.next_fc += 1;
        const out = try x.execScript(num, fc, .{ .checkout = f }, ctx_id, &.{}, &m);
        return .{ .failed = out.code != 0, .exit_code = out.code, .outputs = out.outputs };
    }

    /// Runs a JavaScript action's `main` with the configured runtime (Bun by default, see SPEC §6).
    fn runJs(x: *Exec, num: u32, act: Loaded, u: job_mod.Uses, nd: @FieldType(action.Runs, "node"), inputs: []const expr.Value.Entry, step_env: []const job_mod.EnvVar, step_secret: []const SecretRef) !ActionOut {
        const out = (try x.runJsScript(num, .main, act, u, nd.main, inputs, step_env, step_secret, x.pre_state[num - 1])) orelse
            return .{ .failed = true, .exit_code = 1 };
        // Its `post` runs after the job's steps, with the inputs and the state saved so far.
        if (nd.post) |post| try x.posts.append(x.arena, .{
            .num = num,
            .name = try x.extraName("Post", num, act),
            .act = act,
            .u = u,
            .script = post,
            .condition = nd.post_if orelse "always()",
            .inputs = inputs,
            .step_env = step_env,
            .step_secret = step_secret,
            .state = try std.mem.concat(x.arena, job_mod.EnvVar, &.{ x.pre_state[num - 1], out.state }),
        });
        return .{ .failed = out.code != 0, .exit_code = out.code, .outputs = out.outputs };
    }

    const LoadResult = union(enum) { ok: Loaded, failed: []const u8 };

    /// The action's repository, loaded once per step, whether it loads or not: the `pre` pass at the
    /// start of the job (as GitHub downloads every action in "Set up job") and the step itself share it.
    fn loadFor(x: *Exec, num: u32, u: job_mod.Uses) !LoadResult {
        if (x.loaded[num - 1]) |l| return l;
        const lr = if (u.local) try x.loadLocal(u) else try x.loadAction(u);
        x.loaded[num - 1] = lr;
        return lr;
    }

    /// Inputs: the step's `with:` values, else the defaults, evaluated where the `uses:` step is.
    /// `warn`: log GitHub's warning about undeclared inputs (once, for the step itself).
    fn resolveInputs(x: *Exec, num: u32, act: Loaded, u: job_mod.Uses, caller: expr.Scope, warn: bool) !union(enum) { ok: []const expr.Value.Entry, failed: ActionOut } {
        const arena = x.arena;
        const ev = x.ev;
        var inputs: std.ArrayList(expr.Value.Entry) = .empty;
        for (act.meta.inputs) |def| {
            var val: []const u8 = "";
            if (findInput(u.inputs, def.name)) |t| {
                ev.diag = "";
                val = ev.render(t, caller) catch return .{ .failed = try x.actionFailed(num, "could not evaluate input '{s}': {s}", .{ def.name, ev.diag }) };
            } else if (def.default) |d| {
                ev.diag = "";
                val = expr.interpolate(arena, d, caller) catch return .{ .failed = try x.actionFailed(num, "could not evaluate the default of input '{s}': {s}", .{ def.name, ev.diag }) };
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
        if (warn and unexpected.items.len > 0) {
            var valid: std.ArrayList([]const u8) = .empty;
            for (act.meta.inputs) |def| try valid.append(arena, def.name);
            x.sh.append(num, try std.fmt.allocPrint(arena, "Warning: Unexpected input(s) '{s}', valid inputs are ['{s}']", .{
                try std.mem.join(arena, "', '", unexpected.items), try std.mem.join(arena, "', '", valid.items),
            }));
        }
        return .{ .ok = inputs.items };
    }

    /// Runs a JavaScript action's `pre` script before the job's steps, when it has one and its
    /// `pre-if` (default `always()`) holds. A failing `pre` fails the job, so later steps see failure().
    /// An action that cannot be loaded or evaluated here is left to its step, which reports why.
    fn runPre(x: *Exec, num: u32, step: job_mod.Step) !void {
        const u = step.action.uses;
        // A local action is read when its step runs, after the checkout; GitHub runs no `pre` for it.
        if (u.local) return;
        const act = switch (try x.loadFor(num, u)) {
            .failed => return,
            .ok => |a| a,
        };
        const pre: []const u8, const pre_if: ?[]const u8 = switch (act.meta.runs) {
            .node => |nd| .{ nd.pre orelse return, nd.pre_if },
            .docker => |dk| .{ dk.pre_entrypoint orelse return, dk.pre_if },
            .composite => return,
        };
        const ev = x.ev;
        ev.diag = "";
        const sc0 = try ev.scope(&.{});
        const step_env = ev.renderEnv(step.env, sc0) catch return;
        const sc1 = try ev.scope(step_env);
        if (!(expr.evalCondition(x.arena, pre_if orelse "always()", sc1) catch false)) return;
        const inputs = switch (try x.resolveInputs(num, act, u, sc1, false)) {
            .failed => return,
            .ok => |in| in,
        };
        var plain: std.ArrayList(job_mod.EnvVar) = .empty;
        var secret: std.ArrayList(SecretRef) = .empty;
        splitEnv(x.arena, x.transport, x.job.*, &x.secret_counter, step_env, &plain, &secret, &x.err_msg) catch return error.EngineFailed;
        // A step of its own, "Pre Run x@v1", logged under the next log step.
        const ls = x.next_log_step;
        x.next_log_step += 1;
        const started = std.Io.Clock.real.now(x.io).toMilliseconds();
        const pre_name = x.extraName("Pre", num, act) catch "Pre";
        x.startExtra(.pre, ls, pre_name, started);
        const pre_out = switch (act.meta.runs) {
            .docker => |dk| if (try x.dockerRunFor(ls, act, u, dk, inputs, plain.items, secret.items, pre)) |dr| try x.runContainer(ls, .pre, dr, &.{}) else null,
            else => try x.runJsScript(ls, .pre, act, u, pre, inputs, plain.items, secret.items, &.{}),
        };
        var ok = false;
        defer x.addExtra(.{ .kind = .pre, .name = pre_name, .log_step = ls, .outcome = if (ok) .success else .failure, .started_ms = started, .completed_ms = std.Io.Clock.real.now(x.io).toMilliseconds() }) catch {};
        const out = pre_out orelse {
            ev.job_failed = true;
            x.hook_failed = true;
            return;
        };
        x.pre_state[num - 1] = out.state;
        if (out.code != 0) {
            logExitCode(x.sh, ls, out.code);
            ev.job_failed = true;
            x.hook_failed = true;
        } else ok = true;
    }

    /// The name GitHub gives a `pre` or `post` step: the prefix and the step's name for the step's
    /// own action ("Post Run actions/cache@v4"), or "<prefix> Run <action>" for an action nested in
    /// a composite one (`depth` > 0 while a composite action's steps run).
    fn extraName(x: *Exec, prefix: []const u8, num: u32, act: Loaded) ![]const u8 {
        if (x.depth == 0) return std.fmt.allocPrint(x.arena, "{s} {s}", .{ prefix, x.job.steps[num - 1].name });
        return std.fmt.allocPrint(x.arena, "{s} Run {s}", .{ prefix, act.ref_label });
    }

    /// Runs the registered `post` scripts, last first, each when its `post-if` (default `always()`)
    /// holds. A failing one fails the job; the steps' own results stay as they were.
    fn runPosts(x: *Exec) !void {
        // Only posts follow a post, and they always run: keying them on its output gains nothing.
        x.output_keys = null;
        var i = x.posts.items.len;
        while (i > 0) {
            i -= 1;
            const p = x.posts.items[i];
            x.ev.diag = "";
            const sc = try x.ev.scope(&.{});
            if (!(expr.evalCondition(x.arena, p.condition, sc) catch true)) continue;
            // A step of its own, "Post Run x@v1", logged under the next log step.
            const ls = x.next_log_step;
            x.next_log_step += 1;
            const started = std.Io.Clock.real.now(x.io).toMilliseconds();
            x.startExtra(.post, ls, p.name, started);
            x.sh.append(ls, "Post job cleanup.");
            if (p.checkout) {
                try x.addExtra(.{ .kind = .post, .name = p.name, .log_step = ls, .outcome = .success, .started_ms = started, .completed_ms = std.Io.Clock.real.now(x.io).toMilliseconds() });
                continue;
            }
            const post_out = if (p.docker) |dr|
                try x.runContainer(ls, .post, dr, p.state)
            else
                try x.runJsScript(ls, .post, p.act, p.u, p.script, p.inputs, p.step_env, p.step_secret, p.state);
            const ok = if (post_out) |out| out.code == 0 else false;
            try x.addExtra(.{ .kind = .post, .name = p.name, .log_step = ls, .outcome = if (ok) .success else .failure, .started_ms = started, .completed_ms = std.Io.Clock.real.now(x.io).toMilliseconds() });
            const out = post_out orelse {
                x.hook_failed = true;
                continue;
            };
            if (out.code != 0) {
                logExitCode(x.sh, ls, out.code);
                x.hook_failed = true;
                x.ev.job_failed = true;
            }
        }
    }

    /// Runs one of a JavaScript action's scripts (`pre`, `main` or `post`, relative to the action's
    /// directory) with the configured runtime (Bun by default, see SPEC §6). `state` reaches it as
    /// STATE_<name>. Null when the runtime could not be set up (the reason is logged).
    fn runJsScript(x: *Exec, num: u32, phase: Phase, act: Loaded, _: job_mod.Uses, script_rel: []const u8, inputs: []const expr.Value.Entry, step_env: []const job_mod.EnvVar, step_secret: []const SecretRef, state: []const job_mod.EnvVar) !?ExecOut {
        const arena = x.arena;
        var mounts: std.ArrayList(Mount) = .empty;
        if (!x.js_mounted) {
            const rt = (if (x.musl) js_runtimes_musl else js_runtimes).get(x.js_runtime);
            var msg: []const u8 = "";
            const libs: []const u8 = if (x.musl) " libs: directory(path:\"/usr/lib\") { filter(include:[\"libstdc++.so*\",\"libgcc_s.so*\"]) { id } }" else "";
            const doc = if (rt.npm_dir) |npm|
                try std.fmt.allocPrint(arena, "{{ container {{ from(address:\"{s}\") {{ bin: file(path:\"{s}\") {{ id }} npm: directory(path:\"{s}\") {{ id }}{s} }} }} }}", .{ rt.image, rt.binary, npm, libs })
            else
                try std.fmt.allocPrint(arena, "{{ container {{ from(address:\"{s}\") {{ bin: file(path:\"{s}\") {{ id }}{s} }} }} }}", .{ rt.image, rt.binary, libs });
            const data = gql(arena, x.transport, doc, &msg) catch {
                _ = try x.actionFailed(num, "could not get the JavaScript runtime from {s}: {s}", .{ rt.image, msg });
                return null;
            };
            const bin = (if (jsonFind(data, "bin")) |b| jsonFindString(b, "id") else null) orelse {
                _ = try x.actionFailed(num, "could not get the JavaScript runtime from {s}", .{rt.image});
                return null;
            };
            if (x.musl) {
                const libs_id = (if (jsonFind(data, "libs")) |l| jsonFindString(l, "id") else null) orelse {
                    _ = try x.actionFailed(num, "could not get the C++ runtime from {s}", .{rt.image});
                    return null;
                };
                try mounts.append(arena, .{ .dir = .{ .path = js_lib_dir, .id = libs_id } });
                try mounts.append(arena, .{ .file = .{ .path = js_musl_dir ++ "/node", .id = bin, .permissions = 0o755 } });
                try mounts.append(arena, .{ .new_file = .{ .path = js_runtime_path, .contents = try muslWrapper(arena, "node"), .permissions = 0o755 } });
            } else try mounts.append(arena, .{ .file = .{ .path = js_runtime_path, .id = bin, .permissions = 0o755 } });
            try mounts.append(arena, .{ .new_file = .{ .path = js_shim_path, .contents = node_shim, .permissions = 0o755 } });
            switch (x.js_runtime) {
                // The same binary named `bun` is Bun's own CLI, for `bun x`.
                .bun => {
                    if (x.musl) {
                        try mounts.append(arena, .{ .file = .{ .path = js_musl_dir ++ "/bun", .id = bin, .permissions = 0o755 } });
                        try mounts.append(arena, .{ .new_file = .{ .path = js_bun_path, .contents = try muslWrapper(arena, "bun"), .permissions = 0o755 } });
                    } else try mounts.append(arena, .{ .file = .{ .path = js_bun_path, .id = bin, .permissions = 0o755 } });
                    try mounts.append(arena, .{ .new_file = .{ .path = js_bin_dir ++ "/npx", .contents = npx_bun_shim, .permissions = 0o755 } });
                },
                .node => {
                    const npm = (if (jsonFind(data, "npm")) |d| jsonFindString(d, "id") else null) orelse {
                        _ = try x.actionFailed(num, "could not get npm from {s}", .{rt.image});
                        return null;
                    };
                    try mounts.append(arena, .{ .dir = .{ .path = js_npm_dir, .id = npm } });
                    try mounts.append(arena, .{ .new_file = .{ .path = js_bin_dir ++ "/npx", .contents = npx_node_shim, .permissions = 0o755 } });
                    try mounts.append(arena, .{ .new_file = .{ .path = js_bin_dir ++ "/npm", .contents = npm_node_shim, .permissions = 0o755 } });
                },
            }
        }
        // Mounted once: a later phase sees what an earlier one left in the action's directory.
        if (!x.mounted_actions.contains(act.mount)) try mounts.append(arena, .{ .dir = .{ .path = act.mount, .id = act.dir } });

        // Inputs as INPUT_<NAME> (spaces become underscores, as in @actions/core), the action's
        // location, and the services actions/cache and artifact actions talk to.
        var env: std.ArrayList(job_mod.EnvVar) = .empty;
        try env.appendSlice(arena, try inputEnv(arena, inputs));
        try env.append(arena, .{ .name = "GITHUB_ACTION_PATH", .value = act.path });
        try env.append(arena, .{ .name = "GITHUB_ACTION_REPOSITORY", .value = act.repository });
        try env.append(arena, .{ .name = "GITHUB_ACTION_REF", .value = act.ref });
        try x.runtimeEnv(&env, state);

        var plain: std.ArrayList(job_mod.EnvVar) = .empty;
        var secret: std.ArrayList(SecretRef) = .empty;
        try plain.appendSlice(arena, step_env);
        try secret.appendSlice(arena, step_secret);
        splitEnv(arena, x.transport, x.job.*, &x.secret_counter, env.items, &plain, &secret, &x.err_msg) catch return error.EngineFailed;

        // GitHub folds the action's inputs at the start of its main step; its pre and post steps
        // start with their output.
        if (phase == .main) try x.logGroup(num, phase, act.ref_label, try shownInputs(arena, inputs), step_env, step_secret, &.{});

        // Started through bash where there is one: dash drops variables whose names are not
        // identifiers (INPUT_GITHUB-TOKEN) when it starts a program; bash, and busybox's sh (Alpine
        // images, which have no bash), pass them on.
        var script: std.Io.Writer.Allocating = .init(arena);
        try script.writer.writeAll("PATH=\"" ++ js_bin_dir ++ ":$PATH\" exec " ++ js_runtime_path ++ " ");
        try shellQuote(&script.writer, try std.fmt.allocPrint(arena, "{s}/{s}", .{ act.path, script_rel }));
        const fc = x.next_fc;
        x.next_fc += 1;
        const out = try x.execScript(num, fc, .{ .run = .{ .script = script.written(), .shell = null, .working_directory = null, .env = plain.items } }, if (act.repository.len > 0) act.repository else act.ref_label, secret.items, mounts.items);
        x.js_mounted = true;
        try x.mounted_actions.put(arena, act.mount, {});
        return out;
    }

    /// `hashFiles(patterns)`, as GitHub computes it: the SHA-256 of the SHA-256 digests of the matching
    /// files under the workspace, "" when none match. Patterns are globs relative to the workspace (or
    /// absolute inside it), one per argument or line; `!` excludes, and the last matching pattern
    /// decides; a pattern that matches a directory matches everything in it. Files are taken in path
    /// order; GitHub takes them in directory-walk order, which can differ when several files match.
    /// The files are listed with Dagger's `glob` and hashed by `sha256sum` in the job's container,
    /// which the exec does not change.
    fn hashFiles(ptr: *anyopaque, arena: Allocator, args: []const []const u8) Allocator.Error!expr.HashFiles.Result {
        const x: *Exec = @ptrCast(@alignCast(ptr));
        const Pattern = struct { glob: []const u8, exclude: bool };
        var patterns: std.ArrayList(Pattern) = .empty;
        var any_include = false;
        for (args) |arg| {
            var lines = std.mem.splitScalar(u8, arg, '\n');
            while (lines.next()) |raw| {
                var p = std.mem.trim(u8, raw, " \t\r");
                if (p.len == 0 or p[0] == '#') continue;
                const exclude = p[0] == '!';
                if (exclude) p = std.mem.trimStart(u8, p[1..], " ");
                if (std.mem.startsWith(u8, p, workspace ++ "/")) p = p[workspace.len + 1 ..] //
                else if (std.mem.eql(u8, p, workspace)) p = "**" //
                else if (p.len > 0 and p[0] == '/') continue; // outside the workspace: GitHub ignores those files
                while (std.mem.startsWith(u8, p, "./")) p = p[2..];
                p = std.mem.trimEnd(u8, p, "/");
                if (p.len == 0) continue;
                if (!exclude) any_include = true;
                try patterns.append(arena, .{ .glob = p, .exclude = exclude });
            }
        }
        if (!any_include) return .{ .ok = "" };

        // Each pattern as given, and with `/**` for the contents of a directory it matches.
        var doc: std.Io.Writer.Allocating = .init(arena);
        const w = &doc.writer;
        w.writeAll("{ loadContainerFromID(id:") catch return error.OutOfMemory;
        std.json.Stringify.value(x.container_id, .{}, w) catch return error.OutOfMemory;
        w.writeAll(") { directory(path:\"" ++ workspace ++ "\") {") catch return error.OutOfMemory;
        for (patterns.items, 0..) |p, i| {
            w.print(" p{d}: glob(pattern:", .{i}) catch return error.OutOfMemory;
            std.json.Stringify.value(p.glob, .{}, w) catch return error.OutOfMemory;
            w.print(") d{d}: glob(pattern:", .{i}) catch return error.OutOfMemory;
            std.json.Stringify.value(try std.fmt.allocPrint(arena, "{s}/**", .{p.glob}), .{}, w) catch return error.OutOfMemory;
            w.writeAll(")") catch return error.OutOfMemory;
        }
        w.writeAll(" } } }") catch return error.OutOfMemory;
        var msg: []const u8 = "";
        const data = gql(arena, x.transport, doc.written(), &msg) catch |e| switch (e) {
            error.OutOfMemory => return error.OutOfMemory,
            else => return .{ .failed = msg },
        };
        const matches = try arena.alloc(std.StringHashMapUnmanaged(void), patterns.items.len);
        var candidates: std.StringArrayHashMapUnmanaged(void) = .empty;
        for (patterns.items, matches, 0..) |p, *set, i| {
            set.* = .empty;
            for ([_][]const u8{ "p", "d" }) |kind| {
                const found = jsonStrings(arena, jsonFind(data, try std.fmt.allocPrint(arena, "{s}{d}", .{ kind, i }))) catch return error.OutOfMemory;
                for (found) |path| {
                    if (std.mem.endsWith(u8, path, "/")) continue; // a directory
                    try set.put(arena, path, {});
                    if (!p.exclude) try candidates.put(arena, path, {});
                }
            }
        }
        var files: std.ArrayList([]const u8) = .empty;
        for (candidates.keys()) |path| {
            var included = false;
            for (patterns.items, matches) |p, set| if (set.contains(path)) {
                included = !p.exclude;
            };
            if (included) try files.append(arena, path);
        }
        if (files.items.len == 0) return .{ .ok = "" };
        std.mem.sort([]const u8, files.items, {}, struct {
            fn lt(_: void, l: []const u8, r: []const u8) bool {
                return std.mem.lessThan(u8, l, r);
            }
        }.lt);

        // One sha256sum line per file, in order (names are listed in a file, so any number fits).
        const list = try std.mem.join(arena, "\n", files.items);
        doc = .init(arena);
        const w2 = &doc.writer;
        w2.writeAll("{ loadContainerFromID(id:") catch return error.OutOfMemory;
        std.json.Stringify.value(x.container_id, .{}, w2) catch return error.OutOfMemory;
        w2.writeAll(") { withNewFile(path:\"" ++ hash_list_path ++ "\",contents:") catch return error.OutOfMemory;
        std.json.Stringify.value(list, .{}, w2) catch return error.OutOfMemory;
        w2.writeAll(") { withExec(args:") catch return error.OutOfMemory;
        std.json.Stringify.value([_][]const u8{ "sh", "-c", "cd " ++ workspace ++ " && tr '\\n' '\\0' < " ++ hash_list_path ++ " | xargs -0 sha256sum --" }, .{}, w2) catch return error.OutOfMemory;
        w2.writeAll(",expect:ANY) { exitCode stdout stderr } } } }") catch return error.OutOfMemory;
        const hdata = gql(arena, x.transport, doc.written(), &msg) catch |e| switch (e) {
            error.OutOfMemory => return error.OutOfMemory,
            else => return .{ .failed = msg },
        };
        const code = if (jsonFind(hdata, "exitCode")) |c| (if (c == .integer) c.integer else 1) else 1;
        if (code != 0) return .{ .failed = std.mem.trim(u8, jsonFindString(hdata, "stderr") orelse "sha256sum failed", " \n") };
        var result = std.crypto.hash.sha2.Sha256.init(.{});
        var lines = std.mem.splitScalar(u8, std.mem.trimEnd(u8, jsonFindString(hdata, "stdout") orelse "", "\n"), '\n');
        var n: usize = 0;
        while (lines.next()) |line_in| {
            // sha256sum marks names it had to escape with a leading backslash.
            const line = if (std.mem.startsWith(u8, line_in, "\\")) line_in[1..] else line_in;
            if (line.len < 64) return .{ .failed = "unexpected sha256sum output" };
            var digest: [32]u8 = undefined;
            _ = std.fmt.hexToBytes(&digest, line[0..64]) catch return .{ .failed = "unexpected sha256sum output" };
            result.update(&digest);
            n += 1;
        }
        if (n != files.items.len) return .{ .failed = "sha256sum did not hash every file" };
        const hex = std.fmt.bytesToHex(result.finalResult(), .lower);
        return .{ .ok = try arena.dupe(u8, &hex) };
    }

    /// A line of the job's "Set up job" log (step 0).
    fn setUpLine(x: *Exec, line: []const u8) void {
        x.sh.append(0, line);
    }

    /// The start of "Set up job", in the form GitHub's runner uses for a self-hosted runner: the
    /// runner, then (for this runner) the image and engine, the GITHUB_TOKEN's permissions, where
    /// secrets come from, and the preparation steps.
    fn logSetUp(x: *Exec, opts: Options) !void {
        const arena = x.arena;
        x.setUpLine(try std.fmt.allocPrint(arena, "Current runner version: '{s}' (zig-runner)", .{broker.version}));
        x.setUpLine(try std.fmt.allocPrint(arena, "Runner name: '{s}'", .{opts.runner_name}));
        if (x.job.runner_group.len > 0) x.setUpLine(try std.fmt.allocPrint(arena, "Runner group name: '{s}'", .{x.job.runner_group}));
        var host_buf: [std.posix.HOST_NAME_MAX]u8 = undefined;
        if (std.posix.gethostname(&host_buf)) |host| {
            x.setUpLine(try std.fmt.allocPrint(arena, "Machine name: '{s}'", .{host}));
        } else |_| {}
        x.setUpLine("##[group]Runner Image");
        x.setUpLine(try std.fmt.allocPrint(arena, "Image: {s}", .{x.job_image}));
        x.setUpLine(if (opts.engine) |ep|
            try std.fmt.allocPrint(arena, "Engine: Dagger {s}, direct session ({s})", .{ engine.client_version, if (ep.host.len > 0) ep.host else ep.container })
        else
            "Engine: Dagger, through `dagger run`");
        x.setUpLine("##[endgroup]");
        if (x.job.token_permissions.len > 0) {
            const perms = std.json.parseFromSliceLeaky(std.json.Value, arena, x.job.token_permissions, .{}) catch null;
            if (perms) |p| if (p == .object) {
                x.setUpLine("##[group]GITHUB_TOKEN Permissions");
                var it = p.object.iterator();
                while (it.next()) |e| if (e.value_ptr.* == .string) {
                    x.setUpLine(try std.fmt.allocPrint(arena, "{s}: {s}", .{ e.key_ptr.*, e.value_ptr.string }));
                };
                x.setUpLine("##[endgroup]");
            };
        }
        x.setUpLine(if (std.mem.eql(u8, x.ev.githubString("actor"), "dependabot[bot]")) "Secret source: Dependabot" else "Secret source: Actions");
        x.setUpLine("Prepare workflow directory");
        x.setUpLine("Prepare all required actions");
        x.setUpLine("Getting action download info");
    }

    /// The job's GITHUB_TOKEN as a Dagger secret, registered on first use: what checkouts (and fetches
    /// of actions in the job's own repository) authenticate with. Null when the job has none or it
    /// could not be registered (the fetch then goes without, as for a public repository).
    fn gitAuth(x: *Exec) ?[]const u8 {
        if (x.git_auth) |g| return switch (g) {
            .none => null,
            .id => |id| id,
        };
        x.git_auth = .none;
        for (x.job.secret_vars) |sv| if (std.mem.eql(u8, sv.name, "GITHUB_TOKEN") and sv.value.len > 0) {
            const id = newSecret(x.arena, x.transport, &x.secret_counter, sv.value, &x.err_msg) catch return null;
            x.git_auth = .{ .id = id };
            return id;
        };
        return null;
    }

    /// With `id-token: write` (GitHub then sends GenerateIdTokenUrl), the variables every step requests
    /// OIDC tokens with: the URL, and the job token as a Dagger secret (registered once per job).
    fn idToken(x: *Exec) !?struct { url: job_mod.EnvVar, token: SecretRef } {
        if (x.job.runtime.id_token_url.len == 0) return null;
        const id = x.id_token_secret orelse id: {
            const id = newSecret(x.arena, x.transport, &x.secret_counter, x.job.job_token, &x.err_msg) catch return error.EngineFailed;
            x.id_token_secret = id;
            break :id id;
        };
        return .{
            .url = .{ .name = "ACTIONS_ID_TOKEN_REQUEST_URL", .value = x.job.runtime.id_token_url },
            .token = .{ .name = "ACTIONS_ID_TOKEN_REQUEST_TOKEN", .id = id },
        };
    }

    /// What GitHub's runner gives actions besides their inputs: the services actions/cache and artifact
    /// actions talk to, and what earlier phases saved (`core.saveState`) as STATE_<name>.
    fn runtimeEnv(x: *Exec, env: *std.ArrayList(job_mod.EnvVar), state: []const job_mod.EnvVar) !void {
        const rt = x.job.runtime;
        const vars = [_]job_mod.EnvVar{
            .{ .name = "ACTIONS_RUNTIME_URL", .value = rt.pipelines_url },
            .{ .name = "ACTIONS_RUNTIME_TOKEN", .value = x.job.job_token },
            .{ .name = "ACTIONS_CACHE_URL", .value = rt.cache_url },
            .{ .name = "ACTIONS_RESULTS_URL", .value = rt.results_url },
            .{ .name = "ACTIONS_CACHE_SERVICE_V2", .value = if (rt.cache_v2) "True" else "" },
        };
        for (vars) |v| if (v.value.len > 0) try env.append(x.arena, v);
        for (state) |st| try env.append(x.arena, .{ .name = try std.fmt.allocPrint(x.arena, "STATE_{s}", .{st.name}), .value = st.value });
    }

    /// As GitHub shows an action: `##[group]Run <action>`, its inputs, the env it gets (the job's and
    /// the step's; secret-backed variables as ***), `##[endgroup]`.
    fn logGroup(x: *Exec, num: u32, phase: Phase, label: []const u8, shown: []const job_mod.EnvVar, step_env: []const job_mod.EnvVar, step_secret: []const SecretRef, extra: []const []const u8) !void {
        const arena = x.arena;
        x.sh.append(num, try std.fmt.allocPrint(arena, "##[group]{s} {s}", .{ phase.label(), label }));
        if (shown.len > 0) {
            x.sh.append(num, "with:");
            for (shown) |in| x.sh.append(num, try std.fmt.allocPrint(arena, "  {s}: {s}", .{ in.name, firstLine(in.value) }));
        }
        var env = try envContext(arena, x.ev.job_env.items, step_env);
        for (step_secret) |sr| env = try envContext(arena, env, &.{.{ .name = sr.name, .value = "***" }});
        if (env.len > 0) {
            x.sh.append(num, "env:");
            for (env) |e| x.sh.append(num, try std.fmt.allocPrint(arena, "  {s}: {s}", .{ e.name, firstLine(e.value) }));
        }
        for (extra) |l| x.sh.append(num, l);
        x.sh.append(num, "##[endgroup]");
    }

    /// Runs a Docker action (`runs.using: docker`) and registers its `post-entrypoint`.
    fn runDocker(x: *Exec, num: u32, act: Loaded, u: job_mod.Uses, dk: @FieldType(action.Runs, "docker"), inputs: []const expr.Value.Entry, step_env: []const job_mod.EnvVar, step_secret: []const SecretRef) !ActionOut {
        const failed: ActionOut = .{ .failed = true, .exit_code = 1 };
        const dr = (try x.dockerRunFor(num, act, u, dk, inputs, step_env, step_secret, dk.entrypoint)) orelse return failed;
        const out = (try x.runContainer(num, .main, dr, x.pre_state[num - 1])) orelse return failed;
        if (dk.post_entrypoint) |post| {
            var p = dr;
            p.entrypoint = post;
            try x.posts.append(x.arena, .{
                .num = num,
                .name = try x.extraName("Post", num, act),
                .act = act,
                .u = u,
                .script = post,
                .condition = dk.post_if orelse "always()",
                .inputs = inputs,
                .step_env = step_env,
                .step_secret = step_secret,
                .state = try std.mem.concat(x.arena, job_mod.EnvVar, &.{ x.pre_state[num - 1], out.state }),
                .docker = p,
            });
        }
        return .{ .failed = out.code != 0, .exit_code = out.code, .outputs = out.outputs };
    }

    /// How a Docker action runs: its image (`docker://<image>`, or built from the Dockerfile in its
    /// directory, with the Dockerfile's directory as the context, as GitHub builds it), and its `args`
    /// and `env:` evaluated with its `inputs` in scope. Null when they cannot be evaluated (logged).
    fn dockerRunFor(x: *Exec, num: u32, act: Loaded, _: job_mod.Uses, dk: @FieldType(action.Runs, "docker"), inputs: []const expr.Value.Entry, step_env: []const job_mod.EnvVar, step_secret: []const SecretRef, entrypoint: ?[]const u8) !?DockerRun {
        const arena = x.arena;
        const ev = x.ev;
        const saved_inputs = ev.inputs;
        defer ev.inputs = saved_inputs;
        ev.inputs = .{ .object = inputs };
        ev.diag = "";
        const sc = try ev.scope(step_env);

        var args: ?[]const []const u8 = null;
        if (dk.args) |list| {
            const out = try arena.alloc([]const u8, list.len);
            for (list, out) |a, *dst| dst.* = expr.interpolate(arena, a, sc) catch {
                _ = try x.actionFailed(num, "could not evaluate the args of {s}: {s}", .{ act.ref_label, ev.diag });
                return null;
            };
            args = out;
        }
        var env: std.ArrayList(job_mod.EnvVar) = .empty;
        try env.appendSlice(arena, step_env);
        try env.appendSlice(arena, try inputEnv(arena, inputs));
        for (dk.env) |e| try env.append(arena, .{ .name = e.name, .value = expr.interpolate(arena, e.value, sc) catch {
            _ = try x.actionFailed(num, "could not evaluate env '{s}' of {s}: {s}", .{ e.name, act.ref_label, ev.diag });
            return null;
        } });

        const image: DockerRun.Image = if (std.mem.startsWith(u8, dk.image, "docker://"))
            .{ .pull = dk.image["docker://".len..] }
        else img: {
            const rel = try std.fs.path.resolveAllocPosix(arena, &.{ if (act.sub.len > 0) act.sub else ".", dk.image });
            break :img .{ .build = .{
                .dir = act.dir,
                .context = std.fs.path.dirnamePosix(rel) orelse ".",
                .dockerfile = std.fs.path.basenamePosix(rel),
            } };
        };
        return .{
            .image = image,
            .entrypoint = entrypoint,
            .args = args,
            .env = env.items,
            .secret = step_secret,
            .label = act.ref_label,
            .repository = act.repository,
            .ref = act.ref,
            .shown = try shownInputs(arena, inputs),
            .step_env = step_env,
            .step_secret = step_secret,
        };
    }

    /// `uses: docker://<image>`: the image runs as a Docker action, with `with: args` (split as a
    /// command line) and `with: entrypoint`; every input also arrives as INPUT_<NAME>.
    fn runImageStep(x: *Exec, num: u32, d: @FieldType(job_mod.Action, "docker"), sc: expr.Scope, step_env: []const job_mod.EnvVar, step_secret: []const SecretRef) !ActionOut {
        const arena = x.arena;
        const ev = x.ev;
        const inputs = try arena.alloc(expr.Value.Entry, d.inputs.len);
        for (d.inputs, inputs) |in, *dst| {
            ev.diag = "";
            dst.* = .{ .key = in.name, .value = .{ .string = ev.render(in.value, sc) catch
                return x.actionFailed(num, "could not evaluate input '{s}': {s}", .{ in.name, ev.diag }) } };
        }
        var args: ?[]const []const u8 = null;
        var entrypoint: ?[]const u8 = null;
        for (inputs) |in| {
            if (std.ascii.eqlIgnoreCase(in.key, "args")) args = try splitArgs(arena, in.value.string);
            if (std.ascii.eqlIgnoreCase(in.key, "entrypoint") and in.value.string.len > 0) entrypoint = in.value.string;
        }
        const label = try std.fmt.allocPrint(arena, "docker://{s}", .{d.image});
        const shown = try arena.alloc(job_mod.EnvVar, inputs.len);
        for (inputs, shown) |in, *dst| dst.* = .{ .name = in.key, .value = in.value.string };
        const dr: DockerRun = .{
            .image = .{ .pull = d.image },
            .entrypoint = entrypoint,
            .args = args,
            .env = try std.mem.concat(arena, job_mod.EnvVar, &.{ step_env, try inputEnv(arena, inputs) }),
            .secret = step_secret,
            .label = label,
            .shown = shown,
            .step_env = step_env,
            .step_secret = step_secret,
        };
        const out = (try x.runContainer(num, .main, dr, &.{})) orelse return .{ .failed = true, .exit_code = 1 };
        return .{ .failed = out.code != 0, .exit_code = out.code, .outputs = out.outputs };
    }

    /// Runs a Docker action's container as (part of) step `num`, as GitHub does with `docker run`: the
    /// job's workspace is copied in at /github/workspace (the working directory), with the event file,
    /// the file commands and /github/home, and the workspace is copied back into the job's container
    /// afterwards, deletions included. The command is started by a static busybox (`busybox_image`), so
    /// images without a shell work too. Null when the image could not be pulled or built (logged).
    fn runContainer(x: *Exec, num: u32, phase: Phase, dr: DockerRun, state: []const job_mod.EnvVar) !?ExecOut {
        const arena = x.arena;
        const ev = x.ev;
        const image_line = switch (dr.image) {
            .pull => |ref| try std.fmt.allocPrint(arena, "image: {s}", .{ref}),
            .build => |b| try std.fmt.allocPrint(arena, "image: built from {s}", .{try std.fs.path.resolveAllocPosix(arena, &.{ b.context, b.dockerfile })}),
        };
        if (phase == .main) try x.logGroup(num, phase, dr.label, dr.shown, dr.step_env, dr.step_secret, &.{image_line});
        const busybox = (try x.busyboxFile(num)) orelse return null;
        const img = (try x.imageInfo(num, dr.image, dr.label)) orelse return null;

        // As `docker run [--entrypoint E] image [args]`.
        var argv: std.ArrayList([]const u8) = .empty;
        if (dr.entrypoint) |ep| {
            try argv.append(arena, ep);
            if (dr.args) |a| try argv.appendSlice(arena, a);
        } else {
            try argv.appendSlice(arena, img.entrypoint);
            try argv.appendSlice(arena, dr.args orelse img.cmd);
        }
        if (argv.items.len == 0) {
            _ = try x.actionFailed(num, "{s}: the image has no entrypoint or command, and the action gives none", .{dr.label});
            return null;
        }

        const ws_in = blk: {
            const doc = try std.fmt.allocPrint(arena, "{{ loadContainerFromID(id:{f}) {{ directory(path:\"" ++ workspace ++ "\") {{ id }} }} }}", .{std.json.fmt(x.container_id, .{})});
            const data = gql(arena, x.transport, doc, &x.err_msg) catch return error.EngineFailed;
            break :blk jsonFindString(data, "id") orelse {
                x.err_msg = "Dagger returned no workspace directory";
                return error.EngineFailed;
            };
        };

        // The job's env (workflow, job, GITHUB_ENV), then the step's and the action's, as on GitHub.
        var env: std.ArrayList(job_mod.EnvVar) = .empty;
        try env.appendSlice(arena, ev.job_env.items);
        try env.appendSlice(arena, dr.env);
        try env.append(arena, .{ .name = "HOME", .value = docker_home });
        if (dr.repository.len > 0) {
            try env.append(arena, .{ .name = "GITHUB_ACTION_REPOSITORY", .value = dr.repository });
            try env.append(arena, .{ .name = "GITHUB_ACTION_REF", .value = dr.ref });
        }
        try x.runtimeEnv(&env, state);
        var plain: std.ArrayList(job_mod.EnvVar) = .empty;
        var secret: std.ArrayList(SecretRef) = .empty;
        try secret.appendSlice(arena, dr.secret);
        splitEnv(arena, x.transport, x.job.*, &x.secret_counter, env.items, &plain, &secret, &x.err_msg) catch return error.EngineFailed;
        if (try x.idToken()) |t| {
            try plain.append(arena, t.url);
            try secret.append(arena, t.token);
        }
        const names = try arena.alloc([]const u8, secret.items.len);
        for (secret.items, names) |sr, *n| n.* = sr.name;
        // It always has the job token (ACTIONS_RUNTIME_TOKEN), so with step caching it always runs.
        const always_run: ?[]const u8 = if (x.step_cache) try std.fmt.allocPrint(arena, "zig-runner runs this step every time: it uses secrets (run {s})", .{x.run_nonce}) else null;
        const fc = x.next_fc;
        x.next_fc += 1;
        const script = try containerScript(arena, num, fc, argv.items, plain.items, names, always_run, x.event_from_env, if (dr.repository.len > 0) dr.repository else dr.label);

        var doc: std.Io.Writer.Allocating = .init(arena);
        const w = &doc.writer;
        try w.writeAll("{ loadContainerFromID(id:");
        try std.json.Stringify.value(img.id, .{}, w);
        try w.writeAll(") { withWorkdir(path:\"" ++ workspace ++ "\") { withFile(path:\"" ++ busybox_path ++ "\",permissions:493,source:");
        try std.json.Stringify.value(busybox, .{}, w);
        try w.writeAll(") { ");
        var braces: usize = 4;
        // The workspace, /github/home, and where file commands and the event go, owned by the image's
        // user, which may not be root (GitHub's own example action runs as one).
        const dirs = [_][2][]const u8{
            .{ workspace, ws_in },
            .{ docker_home, x.docker_home orelse x.empty_dir },
            .{ fc_dir, x.empty_dir },
            .{ event_dir, x.empty_dir },
        };
        for (dirs) |d| {
            try w.writeAll("withDirectory(path:");
            try std.json.Stringify.value(d[0], .{}, w);
            try w.writeAll(",source:");
            try std.json.Stringify.value(d[1], .{}, w);
            if (img.user.len > 0) {
                try w.writeAll(",owner:");
                try std.json.Stringify.value(img.user, .{}, w);
            }
            try w.writeAll(") { ");
            braces += 1;
        }
        for (try ev.defaultEnv()) |e| {
            try w.writeAll(if (x.step_cache and isVolatile(e.name)) "withVolatileVariable(name:" else "withEnvVariable(name:");
            try std.json.Stringify.value(e.name, .{}, w);
            try w.writeAll(",value:");
            try std.json.Stringify.value(e.value, .{}, w);
            try w.writeAll(") { ");
            braces += 1;
        }
        try w.writeAll(if (x.event_from_env) "withVolatileVariable(name:\"" ++ event_env ++ "\",value:" else "withNewFile(path:\"" ++ event_path ++ "\",contents:");
        try std.json.Stringify.value(try ev.eventJson(), .{}, w);
        try w.writeAll(") { ");
        braces += 1;
        for (secret.items, 0..) |sr, i| {
            try w.writeAll("withSecretVariable(name:");
            try std.json.Stringify.value(try secretAlias(arena, i), .{}, w);
            try w.writeAll(",secret:");
            try std.json.Stringify.value(sr.id, .{}, w);
            try w.writeAll(") { ");
            braces += 1;
        }
        // A Docker action reaches the job's services by name, as on GitHub's container network.
        braces += try x.writeServiceBindings(w);
        try w.writeAll("withExec(args:");
        try std.json.Stringify.value([_][]const u8{ busybox_path, "sh", "-c", script }, .{}, w);
        try w.writeAll(if (x.nesting) ",expect:ANY,experimentalPrivilegedNesting:true) { exitCode stdout stderr" else ",expect:ANY) { exitCode stdout stderr");
        try w.print(" fc_all: file(path:\"{s}\") {{ contents }}", .{try fcPath(arena, "all", fc)});
        try w.writeAll(" ws: directory(path:\"" ++ workspace ++ "\") { id } home: directory(path:\"" ++ docker_home ++ "\") { id } }");
        for (0..braces) |_| try w.writeAll(" }");

        x.beginExec(num);
        const data = gql(arena, x.transport, doc.written(), &x.err_msg) catch return error.EngineFailed;
        const out = try x.collect(num, data);
        if (jsonFind(data, "home")) |h| if (jsonFindString(h, "id")) |id| {
            x.docker_home = id;
        };
        // The workspace as the action left it replaces the job's.
        const ws_out = (if (jsonFind(data, "ws")) |d| jsonFindString(d, "id") else null) orelse {
            x.err_msg = "Dagger returned no workspace directory";
            return error.EngineFailed;
        };
        const back = try std.fmt.allocPrint(arena, "{{ loadContainerFromID(id:{f}) {{ withoutDirectory(path:\"" ++ workspace ++ "\") {{ withDirectory(path:\"" ++ workspace ++ "\",source:{f}) {{ id }} }} }} }}", .{ std.json.fmt(x.container_id, .{}), std.json.fmt(ws_out, .{}) });
        const bdata = gql(arena, x.transport, back, &x.err_msg) catch return error.EngineFailed;
        x.container_id = jsonFindString(bdata, "id") orelse {
            x.err_msg = "Dagger returned no container";
            return error.EngineFailed;
        };
        return out;
    }

    /// The static busybox that starts Docker actions' commands (taken from its image once per job).
    fn startExtra(x: *Exec, kind: ExtraKind, log_step: u32, name: []const u8, started_ms: i64) void {
        if (x.observer) |o| if (o.extraStartedFn) |f| f(o.ptr, kind, log_step, name, started_ms);
    }

    fn addExtra(x: *Exec, e: ExtraStep) !void {
        try x.extra.append(x.arena, e);
        if (x.observer) |o| if (o.extraFinishedFn) |f| f(o.ptr, e);
    }

    /// "Initialize containers": starts each of the job's `services:` and keeps it running for the
    /// whole job (an explicitly started service lives until the session ends, so its data carries
    /// from step to step), then binds them to the job's container under their names and forwards
    /// their published ports to localhost in every step. False when one could not start: the job
    /// then fails without running its steps, as on GitHub.
    fn startServices(x: *Exec) !bool {
        const arena = x.arena;
        const ev = x.ev;
        const ls = x.next_log_step;
        x.next_log_step += 1;
        const started = std.Io.Clock.real.now(x.io).toMilliseconds();
        var ok = true;
        x.startExtra(.initialize, ls, "Initialize containers", started);
        defer x.addExtra(.{ .kind = .initialize, .name = "Initialize containers", .log_step = ls, .outcome = if (ok) .success else .failure, .started_ms = started, .completed_ms = std.Io.Clock.real.now(x.io).toMilliseconds() }) catch {};
        ev.diag = "";
        const sc = try ev.scope(&.{});
        if (x.job.container) |jc| {
            // The job's own container (built with the job, see `runSteps`): what it was pulled as,
            // and whether it is musl-based, for JavaScript actions' runtime.
            x.sh.append(ls, "##[group]Starting job container");
            x.sh.append(ls, try std.fmt.allocPrint(arena, "Pulling {s}", .{x.job_image}));
            var auth_msg: []const u8 = "";
            const head = try std.fmt.allocPrint(arena, "{{ container {{ {s}from(address:{f}) {{ ", .{ (try registryAuthNode(arena, ev, x.transport, &x.secret_counter, jc, x.job_image, &auth_msg)) orelse "", std.json.fmt(x.job_image, .{}) });
            const closing = if (std.mem.indexOf(u8, head, "withRegistryAuth") != null) " } } } }" else " } } }";
            var msg: []const u8 = "";
            const cfg = gql(arena, x.transport, try std.mem.concat(arena, u8, &.{ head, "imageRef", closing }), &msg) catch {
                x.sh.errorLine(ls, try std.fmt.allocPrint(arena, "Failed to pull {s}: {s}", .{ x.job_image, msg }));
                x.sh.append(ls, "##[endgroup]");
                ok = false;
                return false;
            };
            if (jsonFindString(cfg, "imageRef")) |ref| if (std.mem.indexOf(u8, ref, "@sha256:")) |at| {
                x.sh.append(ls, try std.fmt.allocPrint(arena, "Digest: {s}", .{ref[at + 1 ..]}));
            };
            // No /lib (a scratch image) is not musl.
            if (gql(arena, x.transport, try std.mem.concat(arena, u8, &.{ head, "directory(path:\"/lib\") { entries }", closing }), &msg)) |lib| {
                if (jsonFind(lib, "entries")) |entries| if (entries == .array) for (entries.array.items) |e| {
                    if (e == .string and std.mem.startsWith(u8, e.string, "ld-musl-")) x.musl = true;
                };
            } else |_| {}
            x.sh.append(ls, "##[endgroup]");
            if (x.job.services.len == 0) return true;
        }
        // Each service starts through busybox's sh, which names the service's log (see below).
        const busybox = (try x.busyboxFile(ls)) orelse {
            ok = false;
            return false;
        };
        for (x.job.services, 0..) |svc, svc_index| {
            x.sh.append(ls, try std.fmt.allocPrint(arena, "##[group]Starting {s} service container", .{svc.name}));
            defer x.sh.append(ls, "##[endgroup]");
            const image = ev.render(svc.image, sc) catch "";
            if (image.len == 0) {
                x.sh.errorLine(ls, try std.fmt.allocPrint(arena, "The service '{s}' has no image: {s}", .{ svc.name, ev.diag }));
                ok = false;
                return false;
            }
            const env = ev.renderEnv(svc.env, sc) catch {
                x.sh.errorLine(ls, try std.fmt.allocPrint(arena, "Could not evaluate the env of service '{s}': {s}", .{ svc.name, ev.diag }));
                ok = false;
                return false;
            };
            var ports: std.ArrayList(ServicePort) = .empty;
            for (svc.ports) |t| {
                const text = ev.render(t, sc) catch "";
                const port = parseServicePort(text) orelse {
                    x.sh.errorLine(ls, try std.fmt.allocPrint(arena, "Unsupported port '{s}' for service '{s}' (TCP ports only: 'container', 'host:container' or 'ip:host:container')", .{ text, svc.name }));
                    ok = false;
                    return false;
                };
                try ports.append(arena, port);
            }
            x.sh.append(ls, try std.fmt.allocPrint(arena, "Image: {s}", .{image}));
            if (svc.options) |t| {
                const ignored = try ignoredServiceOptions(arena, ev.render(t, sc) catch "");
                if (ignored.len > 0) x.sh.append(ls, try std.fmt.allocPrint(arena, "##[warning]Service options not supported and ignored: {s}", .{ignored}));
            }
            if (svc.volumes.len > 0) x.sh.append(ls, "##[warning]Service volumes are not supported and were ignored.");

            // `container {` and, for a private registry, its credentials, as both queries start.
            var head: std.Io.Writer.Allocating = .init(arena);
            var head_braces: usize = 2;
            try head.writer.writeAll("{ container { ");
            if (svc.username) |ut| if (svc.password) |pt| {
                const user = ev.render(ut, sc) catch "";
                const pass = ev.render(pt, sc) catch "";
                if (user.len > 0 and pass.len > 0) {
                    const secret = newSecret(arena, x.transport, &x.secret_counter, pass, &x.err_msg) catch {
                        x.sh.errorLine(ls, try std.fmt.allocPrint(arena, "Could not register the credentials of service '{s}': {s}", .{ svc.name, x.err_msg }));
                        ok = false;
                        return false;
                    };
                    const hw = &head.writer;
                    try hw.writeAll("withRegistryAuth(address:");
                    try std.json.Stringify.value(registryHost(image), .{}, hw);
                    try hw.writeAll(",username:");
                    try std.json.Stringify.value(user, .{}, hw);
                    try hw.writeAll(",secret:");
                    try std.json.Stringify.value(secret, .{}, hw);
                    try hw.writeAll(") { ");
                    head_braces += 1;
                }
            };
            try head.writer.writeAll("from(address:");
            try std.json.Stringify.value(image, .{}, &head.writer);
            try head.writer.writeAll(") { ");
            head_braces += 1;

            // The image's configuration first: its entrypoint and command (the service runs them),
            // and the digest it resolved to, as GitHub's runner logs its `docker pull`.
            x.sh.append(ls, try std.fmt.allocPrint(arena, "Pulling {s}", .{image}));
            var cfg_doc: std.Io.Writer.Allocating = .init(arena);
            try cfg_doc.writer.writeAll(head.written());
            try cfg_doc.writer.writeAll("entrypoint defaultArgs imageRef");
            for (0..head_braces) |_| try cfg_doc.writer.writeAll(" }");
            const cfg = gql(arena, x.transport, cfg_doc.written(), &x.err_msg) catch {
                x.sh.errorLine(ls, try std.fmt.allocPrint(arena, "Failed to pull {s} for service {s}: {s}", .{ image, svc.name, x.err_msg }));
                ok = false;
                return false;
            };
            if (jsonFindString(cfg, "imageRef")) |ref| if (std.mem.indexOf(u8, ref, "@sha256:")) |at| {
                x.sh.append(ls, try std.fmt.allocPrint(arena, "Digest: {s}", .{ref[at + 1 ..]}));
            };
            const entrypoint = try jsonStrings(arena, jsonFind(cfg, "entrypoint"));
            const cmd = try jsonStrings(arena, jsonFind(cfg, "defaultArgs"));
            if (entrypoint.len + cmd.len == 0) {
                x.sh.errorLine(ls, try std.fmt.allocPrint(arena, "The image {s} of service {s} has no entrypoint or command to run", .{ image, svc.name }));
                ok = false;
                return false;
            }

            var doc: std.Io.Writer.Allocating = .init(arena);
            const w = &doc.writer;
            try w.writeAll(head.written());
            var braces = head_braces;
            try w.writeAll("withFile(path:\"" ++ busybox_path ++ "\",permissions:493,source:");
            try std.json.Stringify.value(busybox, .{}, w);
            try w.writeAll(") { ");
            braces += 1;
            // The services started before this one, by name, as on a shared network. (A service
            // cannot reach one started after it: a binding needs the service to exist.)
            braces += try x.writeServiceBindings(w);
            // As GitHub's runner sets them for service containers.
            const defaults = [_]job_mod.EnvVar{ .{ .name = "GITHUB_ACTIONS", .value = "true" }, .{ .name = "CI", .value = "true" } };
            for (&defaults) |e| {
                try w.print("withEnvVariable(name:\"{s}\",value:\"{s}\") {{ ", .{ e.name, e.value });
                braces += 1;
            }
            for (env) |e| {
                try w.writeAll("withEnvVariable(name:");
                try std.json.Stringify.value(e.name, .{}, w);
                try w.writeAll(",value:");
                try std.json.Stringify.value(e.value, .{}, w);
                try w.writeAll(") { ");
                braces += 1;
            }
            for (ports.items) |p| {
                try w.print("withExposedPort(port:{d}) {{ ", .{p.container});
                braces += 1;
            }
            // The image's entrypoint and command, started by a shell that first prints the marker
            // that names this service's output. `start` waits until the exposed ports accept
            // connections, which is when servers such as Postgres are ready (during its first-run
            // setup it listens on no TCP port).
            var args: std.ArrayList([]const u8) = .empty;
            try args.appendSlice(arena, &.{ busybox_path, "sh", "-c", try std.fmt.allocPrint(arena, "echo '{s}service {d}'; exec \"$@\"", .{ marker, svc_index }), "zig-service" });
            try args.appendSlice(arena, entrypoint);
            try args.appendSlice(arena, cmd);
            try w.writeAll("asService(args:");
            try std.json.Stringify.value(args.items, .{}, w);
            try w.writeAll(") { start }");
            for (0..braces) |_| try w.writeAll(" }");
            const data = gql(arena, x.transport, doc.written(), &x.err_msg) catch {
                x.sh.errorLine(ls, try std.fmt.allocPrint(arena, "Failed to start service container {s}: {s}", .{ svc.name, x.err_msg }));
                ok = false;
                return false;
            };
            const id = jsonFindString(data, "start") orelse {
                x.sh.errorLine(ls, try std.fmt.allocPrint(arena, "Failed to start service container {s}", .{svc.name}));
                ok = false;
                return false;
            };
            for (ports.items) |p| x.sh.append(ls, try std.fmt.allocPrint(arena, "{d}/tcp -> localhost:{d}", .{ p.container, p.host }));
            try x.services.append(arena, .{ .name = svc.name, .id = id, .ports = ports.items });
        }
        x.sh.append(ls, "##[group]Waiting for all services to be ready");
        for (x.services.items) |r| x.sh.append(ls, try std.fmt.allocPrint(arena, "{s} service is healthy.", .{r.name}));
        x.sh.append(ls, "##[endgroup]");

        // The job's container: the services under their names, and busybox for the forwarders.
        var doc: std.Io.Writer.Allocating = .init(arena);
        const w = &doc.writer;
        try w.writeAll("{ loadContainerFromID(id:");
        try std.json.Stringify.value(x.container_id, .{}, w);
        try w.writeAll(") { withFile(path:\"" ++ busybox_path ++ "\",permissions:493,source:");
        try std.json.Stringify.value(busybox, .{}, w);
        try w.writeAll(") { ");
        const braces = 3 + try x.writeServiceBindings(w);
        try w.writeAll("id");
        for (0..braces) |_| try w.writeAll(" }");
        const data = gql(arena, x.transport, doc.written(), &x.err_msg) catch {
            x.sh.errorLine(ls, try std.fmt.allocPrint(arena, "Could not bind the services to the job: {s}", .{x.err_msg}));
            ok = false;
            return false;
        };
        x.container_id = jsonFindString(data, "id") orelse {
            ok = false;
            return false;
        };
        x.forward_prelude = try forwardPrelude(arena, x.services.items);
        try ev.setServices(x.services.items);
        return true;
    }

    /// `withServiceBinding` for each service, open (the caller closes the braces); how many.
    fn writeServiceBindings(x: *Exec, w: *std.Io.Writer) !usize {
        for (x.services.items) |r| {
            try w.writeAll("withServiceBinding(alias:");
            try std.json.Stringify.value(r.name, .{}, w);
            try w.writeAll(",service:");
            try std.json.Stringify.value(r.id, .{}, w);
            try w.writeAll(") { ");
        }
        return x.services.items.len;
    }

    /// "Stop containers", after the post scripts, as GitHub's runner ends a job with services.
    fn stopServices(x: *Exec) !void {
        if (x.services.items.len == 0 and x.job.container == null) return;
        const ls = x.next_log_step;
        x.next_log_step += 1;
        const started = std.Io.Clock.real.now(x.io).toMilliseconds();
        x.startExtra(.stop, ls, "Stop containers", started);
        for (x.services.items, 0..) |r, i| {
            x.sh.append(ls, try std.fmt.allocPrint(x.arena, "Print service container logs: {s}", .{r.name}));
            for (x.sh.takeServiceLog(i)) |l| x.sh.append(ls, l);
            x.sh.append(ls, try std.fmt.allocPrint(x.arena, "Stop and remove container: {s}", .{r.name}));
            const doc = try std.fmt.allocPrint(x.arena, "{{ loadServiceFromID(id:{f}) {{ stop }} }}", .{std.json.fmt(r.id, .{})});
            var msg: []const u8 = "";
            _ = gql(x.arena, x.transport, doc, &msg) catch x.sh.append(ls, try std.fmt.allocPrint(x.arena, "##[warning]Could not stop {s}: {s}", .{ r.name, msg }));
        }
        // The job container goes with the job's session.
        if (x.job.container != null) x.sh.append(ls, try std.fmt.allocPrint(x.arena, "Stop and remove container: job ({s})", .{x.job_image}));
        try x.addExtra(.{ .kind = .stop, .name = "Stop containers", .log_step = ls, .outcome = .success, .started_ms = started, .completed_ms = std.Io.Clock.real.now(x.io).toMilliseconds() });
    }

    fn busyboxFile(x: *Exec, num: u32) !?[]const u8 {
        if (x.busybox_id) |id| return id;
        var msg: []const u8 = "";
        const data = gql(x.arena, x.transport, "{ bb: container { from(address:\"" ++ busybox_image ++ "\") { file(path:\"/bin/busybox\") { id } } } empty: directory { id } }", &msg) catch {
            _ = try x.actionFailed(num, "could not get busybox from {s}: {s}", .{ busybox_image, msg });
            return null;
        };
        const id = (if (jsonFind(data, "bb")) |b| jsonFindString(b, "id") else null) orelse {
            _ = try x.actionFailed(num, "could not get busybox from {s}", .{busybox_image});
            return null;
        };
        x.empty_dir = (if (jsonFind(data, "empty")) |e| jsonFindString(e, "id") else null) orelse {
            _ = try x.actionFailed(num, "Dagger returned no directory", .{});
            return null;
        };
        x.busybox_id = id;
        return id;
    }

    /// A Docker action's image, pulled or built once per job, with its entrypoint and command.
    fn imageInfo(x: *Exec, num: u32, image: DockerRun.Image, label: []const u8) !?ImageInfo {
        const arena = x.arena;
        const key = switch (image) {
            .pull => |ref| try std.fmt.allocPrint(arena, "pull {s}", .{ref}),
            .build => |b| try std.fmt.allocPrint(arena, "build {s} {s} {s}", .{ b.dir, b.context, b.dockerfile }),
        };
        if (x.images.get(key)) |info| return info;
        const fields = "{{ id entrypoint defaultArgs user }}";
        const doc = switch (image) {
            .pull => |ref| try std.fmt.allocPrint(arena, "{{ container {{ from(address:{f}) " ++ fields ++ " }} }}", .{std.json.fmt(ref, .{})}),
            .build => |b| try std.fmt.allocPrint(arena, "{{ loadDirectoryFromID(id:{f}) {{ directory(path:{f}) {{ dockerBuild(dockerfile:{f}) " ++ fields ++ " }} }} }}", .{
                std.json.fmt(b.dir, .{}), std.json.fmt(b.context, .{}), std.json.fmt(b.dockerfile, .{}),
            }),
        };
        var msg: []const u8 = "";
        const data = gql(arena, x.transport, doc, &msg) catch {
            switch (image) {
                .pull => |ref| _ = try x.actionFailed(num, "could not pull {s} for {s}: {s}", .{ ref, label, msg }),
                .build => |b| _ = try x.actionFailed(num, "could not build {s} of {s}: {s}", .{ b.dockerfile, label, msg }),
            }
            return null;
        };
        const info: ImageInfo = .{
            .id = jsonFindString(data, "id") orelse {
                _ = try x.actionFailed(num, "could not get the image of {s}", .{label});
                return null;
            },
            .entrypoint = try jsonStrings(arena, jsonFind(data, "entrypoint")),
            .cmd = try jsonStrings(arena, jsonFind(data, "defaultArgs")),
            .user = jsonFindString(data, "user") orelse "",
        };
        try x.images.put(arena, key, info);
        return info;
    }

    /// Logs why one of a composite action's steps could not run, and fails the action.
    fn nestedFailed(x: *Exec, num: u32, ctx_id: []const u8, display: []const u8, msg: []const u8, failed: *bool, exit_code: *i32) !void {
        x.sh.errorLine(num, try std.fmt.allocPrint(x.arena, "{s}: {s}", .{ display, msg }));
        try x.ev.steps.append(x.arena, .{ .id = ctx_id, .outcome = "failure", .conclusion = "failure", .outputs = &.{} });
        failed.* = true;
        x.ev.job_failed = true;
        if (exit_code.* == 0) exit_code.* = 1;
    }

    const Loaded = struct {
        meta: action.Metadata,
        /// Dagger Directory id of the action's repository (of the action's own directory, for a local action).
        dir: []const u8,
        /// Where the repository is mounted, and the action's own directory inside it.
        mount: []const u8,
        path: []const u8,
        /// The action's directory inside `dir` ("" for its root).
        sub: []const u8 = "",
        /// `owner/repo[/path]@ref` or `./path`, for messages.
        ref_label: []const u8,
        /// The commit the action's ref resolved to ("" when not known), for the "Set up job" log.
        sha: []const u8 = "",
        /// `github.action_repository` / `action_ref` (GITHUB_ACTION_REPOSITORY / _REF): `owner/repo`
        /// and the ref, or empty for a local action, as on GitHub.
        repository: []const u8 = "",
        ref: []const u8 = "",
    };

    /// Fetches the action's repository (Dagger's git support, cached by the engine) and reads its
    /// `action.yml` or `action.yaml`.
    fn loadAction(x: *Exec, u: job_mod.Uses) !LoadResult {
        const arena = x.arena;
        const sub = if (u.path.len > 0) try std.fmt.allocPrint(arena, "/{s}", .{u.path}) else "";
        const ref_label = try std.fmt.allocPrint(arena, "{s}/{s}{s}@{s}", .{ u.owner, u.name, sub, u.ref });
        const url = try std.fmt.allocPrint(arena, "{s}/{s}/{s}.git", .{ std.mem.trimEnd(u8, x.job.github.server_url, "/"), u.owner, u.name });

        var doc: std.Io.Writer.Allocating = .init(arena);
        const w = &doc.writer;
        try w.writeAll("{ git(url:");
        try std.json.Stringify.value(url, .{}, w);
        // GITHUB_TOKEN reads only the job's own repository; other actions are fetched anonymously.
        const own_repo = std.mem.eql(u8, try std.fmt.allocPrint(arena, "{s}/{s}", .{ u.owner, u.name }), x.job.github.repository);
        try writeGitAuth(w, if (own_repo) x.gitAuth() else null);
        try w.writeAll(") { ");
        try w.writeAll(if (isSha(u.ref)) "commit(id:" else "ref(name:");
        try std.json.Stringify.value(u.ref, .{}, w);
        try w.writeAll(") { tree(depth:1) { id entries(path:");
        try std.json.Stringify.value(if (u.path.len > 0) u.path else ".", .{}, w);
        try w.writeAll(") } sha: commit } } }");
        var msg: []const u8 = "";
        const data = gql(arena, x.transport, doc.written(), &msg) catch
            return .{ .failed = try std.fmt.allocPrint(arena, "could not fetch {s}: {s}{s}", .{
                ref_label, msg, if (looksLikeAuthFailure(msg)) " (the job's GITHUB_TOKEN reads only the job's own repository; a private action elsewhere cannot be fetched)" else "",
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
            .sub = u.path,
            .ref_label = ref_label,
            .sha = jsonFindString(data, "sha") orelse "",
            .repository = try std.fmt.allocPrint(arena, "{s}/{s}", .{ u.owner, u.name }),
            .ref = u.ref,
        } };
    }

    /// Reads a local action (`uses: ./path`) from the workspace as the job's container has it now, so
    /// the repository must have been checked out first (GitHub says the same). Nothing is mounted: the
    /// action's files are already there.
    fn loadLocal(x: *Exec, u: job_mod.Uses) !LoadResult {
        const arena = x.arena;
        const abs = if (u.path.len > 0) try std.fmt.allocPrint(arena, workspace ++ "/{s}", .{u.path}) else workspace;
        const label = try std.fmt.allocPrint(arena, "./{s}", .{u.path});
        const missing = try std.fmt.allocPrint(arena, "Can't find 'action.yml' or 'action.yaml' under '{s}'. Did you forget to run actions/checkout before running your local action?", .{abs});
        const doc = try std.fmt.allocPrint(arena, "{{ loadContainerFromID(id:{f}) {{ directory(path:{f}) {{ id entries }} }} }}", .{ std.json.fmt(x.container_id, .{}), std.json.fmt(abs, .{}) });
        var msg: []const u8 = "";
        const data = gql(arena, x.transport, doc, &msg) catch return .{ .failed = missing };
        const dir = jsonFindString(data, "id") orelse return .{ .failed = missing };
        var file_name: ?[]const u8 = null;
        if (jsonFind(data, "entries")) |entries| if (entries == .array) for (entries.array.items) |e| {
            if (e != .string) continue;
            if (std.mem.eql(u8, e.string, "action.yml") or (file_name == null and std.mem.eql(u8, e.string, "action.yaml"))) file_name = e.string;
        };
        const name = file_name orelse return .{ .failed = missing };
        const fdoc = try std.fmt.allocPrint(arena, "{{ loadDirectoryFromID(id:{f}) {{ file(path:{f}) {{ contents }} }} }}", .{ std.json.fmt(dir, .{}), std.json.fmt(name, .{}) });
        const fdata = gql(arena, x.transport, fdoc, &msg) catch
            return .{ .failed = try std.fmt.allocPrint(arena, "could not read {s} of {s}: {s}", .{ name, label, msg }) };
        const text = jsonFindString(fdata, "contents") orelse return .{ .failed = try std.fmt.allocPrint(arena, "could not read {s} of {s}", .{ name, label }) };
        const meta = switch (try action.parse(arena, text)) {
            .ok => |m| m,
            .invalid => |why| return .{ .failed = try std.fmt.allocPrint(arena, "{s} of {s} {s}", .{ name, label, why }) },
        };
        try x.mounted_actions.put(arena, abs, {});
        return .{ .ok = .{ .meta = meta, .dir = dir, .mount = abs, .path = abs, .ref_label = label } };
    }
};

/// Where a job's event payload is written.
const event_dir = "/github/workflow";
const event_path = event_dir ++ "/event.json";
/// The volatile variable that carries the event payload when step caching is on.
const event_env = "ZIG_RUNNER_EVENT";
/// Linux limits one environment string to 128 KiB; larger payloads are written as a file instead.
const max_event_env = 100 * 1024;

/// Default variables that identify the run rather than its inputs. With step caching they are
/// volatile: they reach every step but do not take part in exec cache keys.
/// RUNNER_NAME belongs here too: a pool registers every job under a new name, so as an input it
/// would make every job's keys new and no step would ever be reused.
const volatile_env = [_][]const u8{ "GITHUB_RUN_ID", "GITHUB_RUN_NUMBER", "GITHUB_RUN_ATTEMPT", "GITHUB_ACTOR", "GITHUB_TRIGGERING_ACTOR", "RUNNER_NAME" };

/// Whether a script names a variable whose value differs between runs while the cache key does not
/// (the volatile ones and the event payload). Scripts the step runs from files are not looked into.
fn readsRunSpecific(script: []const u8) bool {
    for (volatile_env) |v| if (std.mem.indexOf(u8, script, v) != null) return true;
    return std.mem.indexOf(u8, script, "GITHUB_EVENT_PATH") != null;
}

fn isVolatile(name: []const u8) bool {
    for (volatile_env) |v| if (std.mem.eql(u8, v, name)) return true;
    return false;
}

/// `ZIG_RUNNER_STEP_CACHE: false` in the workflow's or job's env turns step caching off for the job.
fn optsOutOfStepCache(job_env: []const job_mod.EnvVar) bool {
    for (job_env) |e| if (std.mem.eql(u8, e.name, "ZIG_RUNNER_STEP_CACHE"))
        return std.ascii.eqlIgnoreCase(e.value, "false") or std.mem.eql(u8, e.value, "0");
    return false;
}

fn jobEnvHasSecret(job: job_mod.Job, job_env: []const job_mod.EnvVar) bool {
    for (job_env) |e| if (containsSecret(job, e.value)) return true;
    return false;
}

/// `<run_id>.<run_attempt>`, or the time when the job has no run id (`--exec-job`).
fn runNonce(arena: Allocator, io: std.Io, ev: *const Evaluator) ![]const u8 {
    const id = ev.githubString("run_id");
    if (id.len > 0) return std.fmt.allocPrint(arena, "{s}.{s}", .{ id, ev.githubString("run_attempt") });
    return std.fmt.allocPrint(arena, "t{d}", .{std.Io.Clock.real.now(io).toMilliseconds()});
}

/// JavaScript actions run with this binary, named `node` so that Bun behaves as Node. The shim on
/// PATH answers `node --version`, which Bun named `node` does not handle, and runs the binary
/// otherwise, so actions that start `node` themselves get the same runtime.
const js_runtime_path = "/github/_runtime/node/node";
const js_bin_dir = "/github/_runtime/bin";
const js_shim_path = js_bin_dir ++ "/node";
const node_shim =
    \\#!/bin/sh
    \\case "$1" in -v|--version) exec /github/_runtime/node/node -p process.version ;; esac
    \\exec /github/_runtime/node/node "$@"
    \\
;

/// `npx` for actions that run a package's binary (FirebaseExtended/action-hosting-deploy runs
/// `npx firebase-tools@<version> ...`). With Bun it is `bun x`, whose progress goes to stderr, so a
/// tool's stdout (often JSON the action parses) stays clean. Bun has no `npm`.
const js_bun_path = "/github/_runtime/node/bun";
const npx_bun_shim =
    \\#!/bin/sh
    \\case "$1" in -y|--yes) shift ;; esac
    \\exec /github/_runtime/node/bun x "$@"
    \\
;
/// With Node, npm's own package (from the same image) provides `npx` and `npm`.
const js_npm_dir = "/github/_runtime/npm";
const npx_node_shim =
    \\#!/bin/sh
    \\exec /github/_runtime/node/node /github/_runtime/npm/bin/npx-cli.js "$@"
    \\
;
const npm_node_shim =
    \\#!/bin/sh
    \\exec /github/_runtime/node/node /github/_runtime/npm/bin/npm-cli.js "$@"
    \\
;

const JsRuntimeSource = struct { image: []const u8, binary: []const u8, npm_dir: ?[]const u8 = null };
/// Bun is pinned to the version the repository's images use (see api/Dockerfile).
const js_runtimes: std.EnumArray(config.JsRuntime, JsRuntimeSource) = .init(.{
    .bun = .{ .image = "oven/bun:1.4.3", .binary = "/usr/local/bin/bun" },
    .node = .{ .image = "node:24-bookworm-slim", .binary = "/usr/local/bin/node", .npm_dir = "/usr/local/lib/node_modules/npm" },
});
/// For a musl job image (`container: alpine`): the runtimes' Alpine builds, which also need the
/// C++ runtime from their image (mounted at `js_lib_dir`).
const js_runtimes_musl: std.EnumArray(config.JsRuntime, JsRuntimeSource) = .init(.{
    .bun = .{ .image = "oven/bun:1.4.3-alpine", .binary = "/usr/local/bin/bun" },
    .node = .{ .image = "node:24-alpine", .binary = "/usr/local/bin/node", .npm_dir = "/usr/local/lib/node_modules/npm" },
});
const js_lib_dir = "/github/_runtime/lib";
const js_musl_dir = "/github/_runtime/musl";

/// On musl, `js_runtime_path` (and `js_bun_path`) start the binary with its C++ runtime found.
fn muslWrapper(arena: Allocator, name: []const u8) ![]const u8 {
    return std.fmt.allocPrint(arena, "#!/bin/sh\nLD_LIBRARY_PATH=" ++ js_lib_dir ++ "${{LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}} exec " ++ js_musl_dir ++ "/{s} \"$@\"\n", .{name});
}

/// Package managers' cache directories (for root, the default images' user), each mounted from its
/// own cache volume. Their contents are caches the tools validate themselves, so sharing them between
/// jobs is safe; they are keyed by repository (see `packageCacheScope`).
///
/// A `container:` image may put them elsewhere (the golang image's GOPATH is /go), so in a container
/// job a tool with a variable naming its cache directory gets the variable pointing at the volume.
/// The paths stay the default image's: Go keys compiled packages on their source directory, so a
/// module cache at one path everywhere lets every image share the build cache. The container's or
/// the workflow's own value wins (and the tool then works without the volume).
const package_cache_dirs = [_]struct { name: []const u8, path: []const u8, env: []const u8 = "" }{
    // RUNNER_TOOL_CACHE: what setup-node, setup-python, setup-go and the like download and unpack,
    // found again by the next job instead of fetched (GitHub's images come with it filled).
    .{ .name = "toolcache", .path = "/opt/hostedtoolcache" },
    .{ .name = "npm", .path = "/root/.npm", .env = "npm_config_cache" },
    .{ .name = "pnpm", .path = "/root/.local/share/pnpm/store" },
    .{ .name = "yarn", .path = "/usr/local/share/.cache/yarn" },
    .{ .name = "pip", .path = "/root/.cache/pip", .env = "PIP_CACHE_DIR" },
    .{ .name = "uv", .path = "/root/.cache/uv", .env = "UV_CACHE_DIR" },
    .{ .name = "go-mod", .path = "/root/go/pkg/mod", .env = "GOMODCACHE" },
    .{ .name = "go-build", .path = "/root/.cache/go-build", .env = "GOCACHE" },
    .{ .name = "cargo-registry", .path = "/root/.cargo/registry" },
    .{ .name = "cargo-git", .path = "/root/.cargo/git" },
    .{ .name = "bun", .path = "/root/.bun/install/cache", .env = "BUN_INSTALL_CACHE_DIR" },
    .{ .name = "zig", .path = "/root/.cache/zig", .env = "ZIG_GLOBAL_CACHE_DIR" },
    .{ .name = "gradle", .path = "/root/.gradle/caches" },
    .{ .name = "maven", .path = "/root/.m2/repository" },
};

/// Pull requests from forks get their own volumes, so untrusted code cannot plant content in the
/// caches the repository's own branches use (GitHub scopes its cache by branch for the same reason).
fn packageCacheScope(arena: Allocator, ev: *Evaluator, repository: []const u8) ![]const u8 {
    const ctxs = [_]expr.Value.Entry{.{ .key = "github", .value = ev.github }};
    const head = expr.evalString(arena, "github.event.pull_request.head.repo.full_name", .{ .contexts = &ctxs }) catch "";
    return if (head.len > 0 and !std.ascii.eqlIgnoreCase(head, repository)) "fork-pr" else "repo";
}

/// `ACTIONS_STEP_DEBUG` set to true, as a secret or a repository variable, shows `::debug::` lines.
fn stepDebug(arena: Allocator, job: job_mod.Job) bool {
    for (job.secret_vars) |sv| if (std.mem.eql(u8, sv.name, "ACTIONS_STEP_DEBUG")) return std.ascii.eqlIgnoreCase(sv.value, "true");
    if (job.context_data == .object) if (job.context_data.object.get("vars")) |vars| {
        const v = context.fromContextData(arena, vars) catch return false;
        if (v == .object) for (v.object) |e| if (std.mem.eql(u8, e.key, "ACTIONS_STEP_DEBUG")) {
            return e.value == .string and std.ascii.eqlIgnoreCase(e.value.string, "true");
        };
    };
    return false;
}

fn hasKey(v: expr.Value, key: []const u8) bool {
    if (v != .object) return false;
    for (v.object) |e| if (std.ascii.eqlIgnoreCase(e.key, key)) return true;
    return false;
}

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
/// A step its timeout or the job's cancellation stopped, logged as GitHub's runner logs it. A timed
/// out step failed (continue-on-error applies); a cancelled one is `cancelled`, and so is the job.
fn stepInterrupted(ev: *Evaluator, sh: *Shared, observer: ?Observer, step: job_mod.Step, res: *StepResult, num: u32, coe: bool, intr: Watch.Interrupt, timeout: []const u8) !void {
    res.completed_ms = std.Io.Clock.real.now(sh.io).toMilliseconds();
    res.exit_code = 1;
    switch (intr) {
        .timed_out => {
            sh.errorLine(num, try std.fmt.allocPrint(ev.arena, "The action '{s}' has timed out after {s} minutes.", .{ res.name, std.mem.trim(u8, timeout, " ") }));
            res.outcome = .failure;
            if (!coe) ev.job_failed = true;
        },
        .cancelled, .none => {
            sh.errorLine(num, "The operation was canceled.");
            res.outcome = .cancelled;
            ev.cancelled = true;
        },
    }
    try ev.record(step, res.outcome, coe, &.{});
    if (observer) |o| o.finished(num, res.*);
}

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
    if (jsonFind(data, "fc_all")) |all| {
        const text = combinedFileCommand(jsonFindString(all, "contents") orelse return null, alias["fc_".len..]) orelse return null;
        return if (text.len == 0) null else text;
    }
    const f = jsonFind(data, alias) orelse return null;
    const text = jsonFindString(f, "contents") orelse return null;
    return if (text.len == 0) null else text;
}

/// One kind's contents in a combined file (see `writeCombinedFileCommands`).
fn combinedFileCommand(all: []const u8, kind: []const u8) ?[]const u8 {
    var start: usize = 0;
    while (std.mem.indexOfPos(u8, all, start, fc_marker)) |i| {
        const line_end = std.mem.indexOfScalarPos(u8, all, i, '\n') orelse return null;
        const body = line_end + 1;
        // The next marker starts a line; the newline before it is the one added after the contents.
        const next = std.mem.indexOfPos(u8, all, body, "\n" ++ fc_marker) orelse all.len;
        if (std.mem.eql(u8, all[i + fc_marker.len .. line_end], kind)) {
            const end = if (next == all.len and all.len > body and all[all.len - 1] == '\n') all.len - 1 else next;
            return all[body..@max(body, end)];
        }
        start = if (next == all.len) all.len else next + 1;
    }
    return null;
}

test "file commands come back from one combined file" {
    const all = "::zig-file-command::output\nversion=1\nnotes<<EOF\na\nEOF\n\n::zig-file-command::env\n\n::zig-file-command::path\n/opt/x/bin\n\n::zig-file-command::step_summary\nno newline at end\n::zig-file-command::state\n\n";
    try std.testing.expectEqualStrings("version=1\nnotes<<EOF\na\nEOF\n", combinedFileCommand(all, "output").?);
    try std.testing.expectEqualStrings("", combinedFileCommand(all, "env").?);
    try std.testing.expectEqualStrings("/opt/x/bin\n", combinedFileCommand(all, "path").?);
    try std.testing.expectEqualStrings("no newline at end", combinedFileCommand(all, "step_summary").?);
    try std.testing.expectEqualStrings("", combinedFileCommand(all, "state").?);
    try std.testing.expect(combinedFileCommand(all, "missing") == null);
}

/// Gives the reader a moment to deliver this step's lines; if none show up the step was served from
/// cache, so its recorded stdout and stderr are logged instead.
fn awaitLiveOrReplay(io: std.Io, sh: *Shared, step: u32, stdout: []const u8, stderr: []const u8) bool {
    const idx = step - 1;
    var waited: u32 = 0;
    while (waited < live_grace_ms and !sh.ended[idx].load(.acquire)) : (waited += 10) {
        io.sleep(.fromMilliseconds(10), .awake) catch {};
    }
    if (sh.live_lines[idx].load(.monotonic) > 0) return false;
    // The step ran (its end marker arrived) but none of its lines did: they came after the marker,
    // as a program's stderr can when it fails at once (Bun refusing an action's bundle, on Linux),
    // and so belonged to no step. Show the result's output, which has them, as the step's own.
    const cached = !sh.ended[idx].load(.acquire);
    if (cached) {
        sh.mu.lockUncancelable(sh.io);
        defer sh.mu.unlock(sh.io);
        if (idx < sh.replayed_steps.len) sh.replayed_steps[idx] = true;
    }
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
    return cached;
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

/// Says which steps Dagger served from cache. Decided once the session has ended and the log stream is
/// fully read, not when a step's output is replayed: the live stream can lag behind a step that did
/// run, and its lines then arrive (and are dropped as duplicates) after the replay. Only a step none
/// of whose live lines ever arrived was reused. The note goes to that step's own log, after its output.
fn noteReusedSteps(sh: *Shared) void {
    for (sh.replayed_steps, 0..) |replayed, idx| {
        if (!replayed or sh.live_lines[idx].load(.monotonic) > 0 or sh.ended[idx].load(.acquire)) continue;
        sh.append(@intCast(idx + 1), "Reused from Dagger's cache: this step's inputs were unchanged since an earlier run, so the output above was recorded then.");
    }
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
    return .{ .steps = results, .engine_error = engine_error, .succeeded = !any_failed and engine_error == null, .annotations = sh.annotations.items };
}

// --- tests ---

test "a service's first line names its output" {
    const sc = scan("::zig-step::service 1").?;
    try std.testing.expectEqual(Marker{ .service = 1 }, sc.marker);
}

test "service ports: as GitHub writes them" {
    try std.testing.expectEqual(ServicePort{ .host = 5432, .container = 5432 }, parseServicePort("5432:5432").?);
    try std.testing.expectEqual(ServicePort{ .host = 6379, .container = 6379 }, parseServicePort("6379").?);
    try std.testing.expectEqual(ServicePort{ .host = 15432, .container = 5432 }, parseServicePort("127.0.0.1:15432:5432").?);
    try std.testing.expectEqual(ServicePort{ .host = 80, .container = 80 }, parseServicePort(" 80/tcp ").?);
    try std.testing.expect(parseServicePort("53/udp") == null);
    try std.testing.expect(parseServicePort("http") == null);
    try std.testing.expect(parseServicePort("0") == null);
}

test "service options: health checks are accepted, the rest reported" {
    var a: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer a.deinit();
    const ar = a.allocator();
    try std.testing.expectEqualStrings("", try ignoredServiceOptions(ar, "--health-cmd \"pg_isready -U postgres\" --health-interval 2s --health-timeout=5s --health-retries 30"));
    try std.testing.expectEqualStrings("--shm-size 1g", try ignoredServiceOptions(ar, "--health-cmd 'redis-cli ping' --shm-size 1g"));
}

test "service credentials go to the image's registry" {
    try std.testing.expectEqualStrings("docker.io", registryHost("postgres:17"));
    try std.testing.expectEqualStrings("docker.io", registryHost("bitnami/postgresql:17"));
    try std.testing.expectEqualStrings("ghcr.io", registryHost("ghcr.io/acme/db:1"));
    try std.testing.expectEqualStrings("localhost:5000", registryHost("localhost:5000/db"));
}

test "each published port is forwarded from localhost to its service" {
    var a: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer a.deinit();
    const svcs = [_]Exec.RunningService{.{ .name = "postgres", .id = "S", .ports = &.{.{ .host = 15432, .container = 5432 }} }};
    try std.testing.expectEqualStrings(
        "\"" ++ busybox_path ++ "\" tcpsvd 127.0.0.1 15432 \"" ++ busybox_path ++ "\" nc 'postgres' 5432 >/dev/null 2>&1 &\n" ++
            "\"" ++ busybox_path ++ "\" tcpsvd ::1 15432 \"" ++ busybox_path ++ "\" nc 'postgres' 5432 >/dev/null 2>&1 &\n",
        try forwardPrelude(a.allocator(), &svcs),
    );
}

const FakeAbort = struct {
    in_flight: bool = false,
    aborted: u32 = 0,

    fn send(_: *anyopaque, _: Allocator, _: []const u8) anyerror![]const u8 {
        return "";
    }
    fn abort(ptr: *anyopaque) bool {
        const f: *FakeAbort = @ptrCast(@alignCast(ptr));
        if (!f.in_flight) return false;
        f.aborted += 1;
        f.in_flight = false;
        return true;
    }
    fn transport(f: *FakeAbort) Transport {
        return .{ .ptr = f, .sendFn = send, .abortFn = abort };
    }
};

test "a step past its timeout is stopped, and only that step" {
    var f: FakeAbort = .{};
    var w: Watch = .{ .io = std.testing.io, .transport = f.transport(), .cancel = null };
    w.begin(1_000);
    f.in_flight = true;
    w.tick(999);
    try std.testing.expectEqual(@as(u32, 0), f.aborted);
    w.tick(1_001);
    try std.testing.expectEqual(@as(u32, 1), f.aborted);
    try std.testing.expectEqual(Watch.Interrupt.timed_out, w.end());
    // The next step has no timeout: nothing reaches it.
    w.begin(0);
    f.in_flight = true;
    w.tick(5_000);
    try std.testing.expectEqual(@as(u32, 1), f.aborted);
    try std.testing.expectEqual(Watch.Interrupt.none, w.end());
}

test "a deadline passed between a step's queries stops its next query" {
    var f: FakeAbort = .{};
    var w: Watch = .{ .io = std.testing.io, .transport = f.transport(), .cancel = null };
    w.begin(1_000);
    w.tick(2_000); // no query in flight
    f.in_flight = true;
    w.tick(2_200);
    try std.testing.expectEqual(Watch.Interrupt.timed_out, w.end());
}

test "a cancel stops the running step, not the always() steps after it, until the grace period ends" {
    var f: FakeAbort = .{};
    var c: Cancel = .{};
    var w: Watch = .{ .io = std.testing.io, .transport = f.transport(), .cancel = &c };
    w.begin(0);
    f.in_flight = true;
    c.hard_deadline_ms.store(10_000, .release);
    c.requested.store(true, .release);
    w.tick(1_000);
    try std.testing.expectEqual(Watch.Interrupt.cancelled, w.end());
    // An `if: always()` step after it runs.
    w.begin(0);
    f.in_flight = true;
    w.tick(2_000);
    try std.testing.expectEqual(@as(u32, 1), f.aborted);
    try std.testing.expectEqual(Watch.Interrupt.none, w.end());
    // Past the grace period, whatever runs is stopped.
    w.begin(0);
    f.in_flight = true;
    w.tick(10_001);
    try std.testing.expectEqual(@as(u32, 2), f.aborted);
    try std.testing.expectEqual(Watch.Interrupt.cancelled, w.end());
}

test "a cancel between steps does not stop the next step" {
    var f: FakeAbort = .{};
    var c: Cancel = .{};
    var w: Watch = .{ .io = std.testing.io, .transport = f.transport(), .cancel = &c };
    c.requested.store(true, .release);
    w.tick(1_000);
    w.begin(0);
    f.in_flight = true;
    w.tick(1_200);
    try std.testing.expectEqual(@as(u32, 0), f.aborted);
    try std.testing.expectEqual(Watch.Interrupt.none, w.end());
}

fn testStep(script: []const u8) job_mod.Step {
    return .{ .id = "x", .name = "n", .condition = "success()", .action = .{ .script = .{ .script = .{ .lit = script }, .shell = null, .working_directory = null } } };
}

fn testJob(steps: []const job_mod.Step) job_mod.Job {
    return .{
        .plan_id = "p",
        .job_id = "j",
        .job_token = "t",
        .check_run_id = 1,

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
    // The script is written to a file that the shell runs, as GitHub does.
    try std.testing.expect(std.mem.indexOf(u8, w, "printf '%s' 'echo '\\''hi'\\'' && echo $X' > /tmp/zig-runner-step-2.sh\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, w, "'GITHUB_ACTION=build' 'sh' '-e' '/tmp/zig-runner-step-2.sh' )") != null);
    // A custom bash command, with {0} replaced by the file.
    const custom = try stepScript(a.allocator(), 3, .{ .run = .{ .script = "echo hi", .shell = "bash -l {0}", .working_directory = null, .env = &.{} } }, "x");
    try std.testing.expect(std.mem.indexOf(u8, custom, "'bash' '-l' '/tmp/zig-runner-step-3.sh' )") != null);
    try std.testing.expect(std.mem.indexOf(u8, custom, "zig_shell") == null);
    // No shell: bash -e, or sh -e where the image has no bash.
    const default = try stepScript(a.allocator(), 4, .{ .run = .{ .script = "echo hi", .shell = null, .working_directory = null, .env = &.{} } }, "x");
    try std.testing.expect(std.mem.indexOf(u8, default, "if command -v bash >/dev/null 2>&1; then zig_shell=bash; else zig_shell=sh; fi\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, default, "\"$zig_shell\" '-e' '/tmp/zig-runner-step-4.sh' )") != null);
    try std.testing.expectEqualStrings("shell: /usr/bin/bash -e {0}", try shellLine(a.allocator(), null));
    try std.testing.expectEqualStrings("shell: /usr/bin/bash -l {0}", try shellLine(a.allocator(), "bash -l {0}"));
    try std.testing.expectEqualStrings("shell: /bin/bash --login -eo pipefail {0}", try shellLine(a.allocator(), "/bin/bash --login -eo pipefail {0}"));
    // The file commands exist before the step and are touched again after it.
    try std.testing.expect(std.mem.indexOf(u8, w, ": > /github/file_commands/output_2 > /github/file_commands/env_2") != null);
    try std.testing.expect(std.mem.indexOf(u8, w, ">> /github/file_commands/path_2") != null);
    try std.testing.expect(std.mem.indexOf(u8, w, marker ++ "begin 2") != null);
    try std.testing.expect(std.mem.endsWith(u8, w, "exit $rc\n"));
}

test "secret variables reach the script through aliases, whatever their names" {
    var a: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer a.deinit();
    const w = try stepScript(a.allocator(), 1, .{ .run = .{
        .script = "node main.js",
        .shell = "sh",
        .working_directory = null,
        .env = &.{.{ .name = "PLAIN", .value = "p" }},
        .secret_env = &.{ "INPUT_GITHUB-TOKEN", "TOKEN" },
    } }, "a");
    // Aliases are unset before the assignments; the real names come after the plain env.
    try std.testing.expect(std.mem.indexOf(u8, w, "env -u ZIG_SECRET_0 -u ZIG_SECRET_1 'PLAIN=p' 'INPUT_GITHUB-TOKEN='\"$ZIG_SECRET_0\" 'TOKEN='\"$ZIG_SECRET_1\" ") != null);
}

test "the checkout log names the ref as the checkout leaves it" {
    var a: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer a.deinit();
    const arena = a.allocator();
    const base: Fetched = .{ .result = .{ .dir = "D" }, .repo = "o/r", .ref_label = "abc1234", .mount = "/github/workspace", .url = "https://github.com/o/r", .want = "refs/pull/7/merge", .depth = 0 };
    const cases = [_]struct { ref: ?[]const u8, want: []const u8 }{
        .{ .ref = "refs/heads/main", .want = "branch 'main' set up to track 'origin/main'." },
        .{ .ref = "refs/pull/7/merge", .want = "HEAD is detached at refs/remotes/pull/7/merge" },
        .{ .ref = "v1", .want = "HEAD is detached at origin/v1" },
        .{ .ref = "refs/tags/v1", .want = "HEAD is detached at refs/tags/v1" },
        .{ .ref = null, .want = "HEAD is detached at abc1234" },
    };
    for (cases) |c| {
        var f = base;
        f.git_ref = c.ref;
        const lines = try checkoutLog(arena, f);
        try std.testing.expectEqualStrings(c.want, lines[lines.len - 1]);
        try std.testing.expectEqualStrings("Depth: full history", lines[4]);
        try std.testing.expectEqualStrings("Ref: refs/pull/7/merge", lines[3]);
    }
}

test "checkoutQuery picks commit, ref or head and honours fetch-depth" {
    var a: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer a.deinit();
    const job = testJob(&.{});
    const own = (try checkoutQuery(a.allocator(), job, .{}, null)).doc;
    try std.testing.expectEqualStrings("{ git(url:\"https://github.com/o/r.git\",keepGitDir:true) { commit(id:\"0123456789012345678901234567890123456789\") { tree(depth:1) { id } } } }", own);
    const by_ref = (try checkoutQuery(a.allocator(), job, .{ .ref = "refs/pull/7/merge", .fetch_depth = 0 }, null)).doc;
    try std.testing.expectEqualStrings("{ git(url:\"https://github.com/o/r.git\",keepGitDir:true) { ref(name:\"refs/pull/7/merge\") { tree(depth:0) { id } } } }", by_ref);
    const tags = (try checkoutQuery(a.allocator(), job, .{ .fetch_tags = true }, "SEC")).doc;
    try std.testing.expect(std.mem.indexOf(u8, tags, "tree(depth:1,includeTags:true) { id }") != null);
    // With the job's GITHUB_TOKEN (a secret), as GitHub expects a token over HTTPS.
    try std.testing.expect(std.mem.indexOf(u8, tags, "git(url:\"https://github.com/o/r.git\",httpAuthUsername:\"x-access-token\",httpAuthToken:\"SEC\",keepGitDir:true)") != null);
    const other = (try checkoutQuery(a.allocator(), job, .{ .repository = "x/y", .fetch_depth = 3 }, null)).doc;
    try std.testing.expect(std.mem.indexOf(u8, other, "x/y.git") != null and std.mem.indexOf(u8, other, "{ head { tree(depth:3)") != null);
    var empty = job;
    empty.github.repository = "";
    try std.testing.expect((try checkoutQuery(a.allocator(), empty, .{}, null)) == .err);
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
    // actions/checkout's folds, with what the built-in checkout did, and the commit last (from git).
    const co_script = fake.seen.items[2];
    for ([_][]const u8{
        "Syncing repository: o/r",
        "##[group]Fetching the repository",
        "Fetched https://github.com/o/r with Dagger",
        "Commit: 0123456789012345678901234567890123456789",
        "Depth: 1",
        "Tags: not fetched",
        "##[group]Checking out the ref",
        "Into /github/workspace",
        "Switched to a new branch ",
        "/github/workspace",
        " log -1 --format=%H",
    }) |want| if (std.mem.indexOf(u8, co_script, want) == null) {
        std.debug.print("missing: {s}\n", .{want});
        return error.TestUnexpectedResult;
    };

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
    try std.testing.expect(std.mem.indexOf(u8, w2.buffered(), "could not fetch o/r@0123456: remote: Repository not found. (the job's GITHUB_TOKEN reads only the job's own repository; another private one cannot be checked out)") != null);
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
    // Secret-bearing step env is passed as Dagger secrets under aliases, given its name by the script,
    // removed again after the step, and appears nowhere in a command.
    const s5 = fake.seen.items[7];
    try std.testing.expect(std.mem.indexOf(u8, s5, "withSecretVariable(name:\"ZIG_SECRET_0\",secret:\"SEC_A\")") != null);
    try std.testing.expect(std.mem.indexOf(u8, s5, "withSecretVariable(name:\"ZIG_SECRET_1\",secret:\"SEC_B\")") != null);
    try std.testing.expect(std.mem.indexOf(u8, s5, "env -u ZIG_SECRET_0 -u ZIG_SECRET_1 ") != null);
    try std.testing.expect(std.mem.indexOf(u8, s5, "'DB_PASSWORD='\\\"$ZIG_SECRET_0\\\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, s5, "withoutSecretVariable(name:\"ZIG_SECRET_0\") { withoutSecretVariable(name:\"ZIG_SECRET_1\") { id } }") != null);
    // The next step does not get them.
    try std.testing.expect(std.mem.indexOf(u8, fake.seen.items[8], "ZIG_SECRET") == null);
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
    // One read for all of a step's file commands, combined by its script.
    try std.testing.expect(std.mem.indexOf(u8, fake.seen.items[1], "fc_all: file(path:\"/github/file_commands/all_1\")") != null);
    try std.testing.expect(std.mem.indexOf(u8, fake.seen.items[1], "fc_output: file(") == null);
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

test "action failures: an image that cannot be pulled, a missing action.yml, and a failing step with failure() cleanup" {
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
    const steps = [_]job_mod.Step{ usesStep("dock", "o", "dock", "v1", &.{}), s2, s3 };
    const answers = [_][]const u8{
        base_answer,
        try treeAnswer(arena, "D1", &.{"action.yml"}),
        try fileAnswer(arena, "runs:\n  using: docker\n  image: docker://nope:1\n"),
        try treeAnswer(arena, "D2", &.{"README.md"}),
        try treeAnswer(arena, "D3", &.{"action.yaml"}),
        try fileAnswer(arena, failing_yml),
        "{\"data\":{\"bb\":{\"from\":{\"file\":{\"id\":\"BB\"}}},\"empty\":{\"id\":\"EMPTY\"}}}",
        "{\"errors\":[{\"message\":\"pull access denied for nope\"}]}",
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
    try std.testing.expectEqual(@as(usize, 10), seen.len); // the step after the failure is skipped
    try std.testing.expect(std.mem.indexOf(u8, seen[4], "commit(id:\"0123456789012345678901234567890123456789\")") != null);
    try std.testing.expect(std.mem.indexOf(u8, seen[5], "file(path:\"action.yaml\")") != null);
    try std.testing.expect(std.mem.indexOf(u8, seen[9], "echo cleanup") != null);
    const out = w.buffered();
    try std.testing.expect(std.mem.indexOf(u8, out, "could not pull nope:1 for o/dock@v1: pull access denied for nope") != null);
    // As GitHub's runner logs a script that exits non-zero.
    try std.testing.expect(std.mem.indexOf(u8, out, "##[error]Process completed with exit code 3.") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "o/none@v1 has no action.yml or action.yaml") != null);
}

test "a JavaScript action runs its main with the runtime, inputs as INPUT_*, the runtime services, and the event" {
    var a: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer a.deinit();
    const arena = a.allocator();
    var env: std.process.Environ.Map = .init(arena);

    const action_yml =
        \\inputs:
        \\  github-token:
        \\    default: ${{ github.token }}
        \\  script:
        \\    required: true
        \\  result encoding:
        \\    default: json
        \\outputs:
        \\  result:
        \\    description: set by the action
        \\runs:
        \\  using: node24
        \\  main: dist/index.js
        \\  post: dist/post.js
    ;
    const inputs = [_]job_mod.Input{.{ .name = "script", .value = .{ .lit = "return 42" } }};
    var after = testStep("");
    after.action.script.script = .{ .expr = "format('echo {0}', steps.gs.outputs.result)" };
    const steps = [_]job_mod.Step{ usesStep("gs", "actions", "github-script", "v9", &inputs), usesStep("again", "actions", "github-script", "v9", &inputs), after };
    var job = testJob(&steps);
    job.secrets = &.{ "ghs_jobtoken", "ghs_secret" };
    job.job_token = "ghs_jobtoken";
    job.secret_vars = &.{.{ .name = "GITHUB_TOKEN", .value = "ghs_secret" }};
    job.runtime = .{ .pipelines_url = "https://pipelines.test/", .cache_url = "https://cache.test/", .results_url = "https://results.test/", .cache_v2 = true };
    const ctx_json =
        \\{"github":{"t":2,"d":[{"k":"repository","v":"o/r"},{"k":"event","v":{"t":2,"d":[{"k":"ref","v":"refs/heads/x"}]}}]}}
    ;
    job.context_data = try std.json.parseFromSliceLeaky(std.json.Value, arena, ctx_json, .{});

    const main_with_state = "{\"data\":{\"loadContainerFromID\":{\"withExec\":{\"id\":\"C1\",\"exitCode\":0,\"stdout\":\"\",\"stderr\":\"\",\"fc_output\":{\"contents\":\"result=42\\n\"},\"fc_state\":{\"contents\":\"pid=7\\n\"}}}}}";
    const answers = [_][]const u8{
        base_answer,
        // Every action is fetched at the start of the job (the `pre` pass), as GitHub does.
        try treeAnswer(arena, "D1", &.{ "action.yml", "dist" }),
        try fileAnswer(arena, action_yml),
        try treeAnswer(arena, "D1", &.{ "action.yml", "dist" }),
        try fileAnswer(arena, action_yml),
        "{\"data\":{\"container\":{\"from\":{\"bin\":{\"id\":\"BUN\"}}}}}",
        "{\"data\":{\"setSecret\":{\"id\":\"SEC_TOKEN\"}}}", // INPUT_GITHUB-TOKEN
        "{\"data\":{\"setSecret\":{\"id\":\"SEC_RUNTIME\"}}}", // ACTIONS_RUNTIME_TOKEN
        main_with_state,
        "{\"data\":{\"setSecret\":{\"id\":\"SEC_TOKEN2\"}}}",
        "{\"data\":{\"setSecret\":{\"id\":\"SEC_RUNTIME2\"}}}",
        try exec(arena, "C2", 0, ""),
        try exec(arena, "C3", 0, ""),
        // posts, last step first
        "{\"data\":{\"setSecret\":{\"id\":\"SEC_P1\"}}}",
        "{\"data\":{\"setSecret\":{\"id\":\"SEC_P2\"}}}",
        try exec(arena, "C4", 0, ""),
        "{\"data\":{\"setSecret\":{\"id\":\"SEC_P3\"}}}",
        "{\"data\":{\"setSecret\":{\"id\":\"SEC_P4\"}}}",
        try exec(arena, "C5", 0, ""),
    };
    var fake: FakeSession = .{ .answers = &answers, .arena = arena };
    var buf: [8192]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buf);
    var log: sink.LogSink = .{ .stdout = .{ .writer = &w } };
    const res = try run(arena, std.testing.io, &env, .{ .test_session_argv = &.{ "sh", "-c", fake_child }, .test_transport = fake.transport() }, job, &log);

    const seen = fake.seen.items;
    try std.testing.expect(res.succeeded);
    try std.testing.expectEqual(@as(usize, 19), seen.len);
    for (seen) |d| try std.testing.expect(braceBalanced(d));
    // The event payload is written for GITHUB_EVENT_PATH.
    try std.testing.expect(std.mem.indexOf(u8, seen[0], "withNewFile(path:\"/github/workflow/event.json\",contents:\"{\\n  \\\"ref\\\": \\\"refs/heads/x\\\"\\n}\")") != null);
    try std.testing.expect(std.mem.indexOf(u8, seen[0], "withEnvVariable(name:\"GITHUB_EVENT_PATH\",value:\"/github/workflow/event.json\")") != null);
    // Bun comes from its image, once per job.
    try std.testing.expect(std.mem.indexOf(u8, seen[5], "from(address:\"oven/bun:1.4.3\") { bin: file(path:\"/usr/local/bin/bun\")") != null);
    const run1 = seen[8];
    try std.testing.expect(std.mem.indexOf(u8, run1, "withFile(path:\"/github/_runtime/node/node\",source:\"BUN\",permissions:493)") != null);
    try std.testing.expect(std.mem.indexOf(u8, run1, "withNewFile(path:\"/github/_runtime/bin/node\"") != null);
    // npx is `bun x`, through the same binary named bun.
    try std.testing.expect(std.mem.indexOf(u8, run1, "withFile(path:\"/github/_runtime/node/bun\",source:\"BUN\",permissions:493)") != null);
    try std.testing.expect(std.mem.indexOf(u8, run1, "withNewFile(path:\"/github/_runtime/bin/npx\",contents:\"#!/bin/sh\\ncase \\\"$1\\\" in -y|--yes) shift ;; esac\\nexec /github/_runtime/node/bun x \\\"$@\\\"\\n\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, run1, "withDirectory(path:\"/github/_actions/actions/github-script/v9\",source:\"D1\")") != null);
    try std.testing.expect(std.mem.indexOf(u8, run1, "exec /github/_runtime/node/node '\\\\''/github/_actions/actions/github-script/v9/dist/index.js'\\\\''") != null);
    // Inputs: given, defaulted (github.token, a secret, under its hyphenated name), names upper-cased with spaces as underscores.
    try std.testing.expect(std.mem.indexOf(u8, run1, "'INPUT_SCRIPT=return 42'") != null);
    try std.testing.expect(std.mem.indexOf(u8, run1, "'INPUT_RESULT_ENCODING=json'") != null);
    try std.testing.expect(std.mem.indexOf(u8, run1, "'INPUT_GITHUB-TOKEN='\\\"$ZIG_SECRET_0\\\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, run1, "'ACTIONS_RUNTIME_TOKEN='\\\"$ZIG_SECRET_1\\\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, run1, "'ACTIONS_CACHE_URL=https://cache.test/'") != null);
    try std.testing.expect(std.mem.indexOf(u8, run1, "'ACTIONS_CACHE_SERVICE_V2=True'") != null);
    try std.testing.expect(std.mem.indexOf(u8, run1, "GITHUB_STATE=") != null);
    // bash where there is one, not dash, starts the runtime (dash would drop INPUT_GITHUB-TOKEN).
    try std.testing.expect(std.mem.indexOf(u8, run1, "printf '%s' 'PATH=\\\"/github/_runtime/bin:$PATH\\\" exec") != null);
    try std.testing.expect(std.mem.indexOf(u8, run1, "if command -v bash >/dev/null 2>&1; then zig_shell=bash; else zig_shell=sh; fi") != null);
    try std.testing.expect(std.mem.indexOf(u8, run1, "$zig_shell\\\" '-e' '/tmp/zig-runner-step-") != null);
    // No token in any command; the runtime is fetched only once.
    for (seen) |d| if (std.mem.indexOf(u8, d, "setSecret") == null) try std.testing.expect(std.mem.indexOf(u8, d, "ghs_") == null);
    try std.testing.expect(std.mem.indexOf(u8, seen[11], "withFile(path:\"/github/_runtime/node/node\"") == null);
    // The action's output reaches the next step.
    try std.testing.expect(std.mem.indexOf(u8, seen[12], "echo 42") != null);
    const out = w.buffered();
    // Posts run after the steps, last step first, with the state the main script saved.
    try std.testing.expect(std.mem.indexOf(u8, seen[15], "/github/_actions/actions/github-script/v9/dist/post.js") != null);
    try std.testing.expect(std.mem.indexOf(u8, seen[15], "STATE_pid") == null); // the second step saved nothing
    try std.testing.expect(std.mem.indexOf(u8, seen[18], "dist/post.js") != null);
    try std.testing.expect(std.mem.indexOf(u8, seen[18], "'STATE_pid=7'") != null);
    // The action directory and runtime are not mounted again for the post.
    try std.testing.expect(std.mem.indexOf(u8, seen[18], "withDirectory") == null);
    // Each post is a step of its own (log steps 4 and 5, after the job's three), starting as GitHub's do.
    try std.testing.expect(std.mem.indexOf(u8, out, "[job 0 step 4 stdout] Post job cleanup.") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "[job 0 step 5 stdout] Post job cleanup.") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "##[group]Post") == null);
    try std.testing.expect(std.mem.indexOf(u8, out, "##[group]Run actions/github-script@v9") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "  script: return 42") != null);
}

test "Docker actions: built or pulled, the workspace copied in and back, args, env, entrypoints and post" {
    var a: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer a.deinit();
    const arena = a.allocator();
    var env: std.process.Environ.Map = .init(arena);

    const action_yml =
        \\inputs:
        \\  who:
        \\    default: nobody
        \\runs:
        \\  using: docker
        \\  image: ./docker/Dockerfile
        \\  args:
        \\    - hello ${{ inputs.who }}
        \\  env:
        \\    GREETING: hi ${{ inputs.who }}
        \\  post-entrypoint: /cleanup.sh
    ;
    const inputs = [_]job_mod.Input{.{ .name = "who", .value = .{ .lit = "world" } }};
    var built = usesStep("dock", "o", "dock", "v1", &inputs);
    built.action.uses.path = "sub";
    var pulled = testStep("");
    pulled.action = .{ .docker = .{ .image = "alpine:3.22", .inputs = &.{
        .{ .name = "entrypoint", .value = .{ .lit = "sh" } },
        .{ .name = "args", .value = .{ .lit = "-c \"echo $GREETING\" x" } },
    } } };
    pulled.env = &.{.{ .name = "GREETING", .value = .{ .lit = "from the step" } }};
    const steps = [_]job_mod.Step{ built, pulled };
    var job = testJob(&steps);
    job.secrets = &.{"ghs_jobtoken"};
    job.job_token = "ghs_jobtoken";

    const ws = "{\"data\":{\"loadContainerFromID\":{\"directory\":{\"id\":\"WS0\"}}}}";
    const back = "{\"data\":{\"loadContainerFromID\":{\"withoutDirectory\":{\"withDirectory\":{\"id\":\"CB\"}}}}}";
    const secret = "{\"data\":{\"setSecret\":{\"id\":\"SEC\"}}}";
    const ran = "{\"data\":{\"loadContainerFromID\":{\"withExec\":{\"exitCode\":0,\"stdout\":\"\",\"stderr\":\"\",\"fc_output\":{\"contents\":\"said=hi\\n\"},\"ws\":{\"id\":\"WS1\"},\"home\":{\"id\":\"H1\"}}}}}";
    const answers = [_][]const u8{
        base_answer,
        try treeAnswer(arena, "D1", &.{"action.yml"}),
        try fileAnswer(arena, action_yml),
        // step 1: busybox, the image built from its Dockerfile, the workspace, the token, the exec, the copy back
        "{\"data\":{\"bb\":{\"from\":{\"file\":{\"id\":\"BB\"}}},\"empty\":{\"id\":\"EMPTY\"}}}",
        "{\"data\":{\"loadDirectoryFromID\":{\"directory\":{\"dockerBuild\":{\"id\":\"IMG\",\"entrypoint\":[\"/entry.sh\"],\"defaultArgs\":[\"unused\"],\"user\":\"actionuser\"}}}}}",
        ws,
        secret,
        ran,
        back,
        // step 2: a pulled image; busybox is not fetched again
        "{\"data\":{\"container\":{\"from\":{\"id\":\"ALP\",\"entrypoint\":[],\"defaultArgs\":[\"/bin/sh\"]}}}}",
        ws,
        secret,
        ran,
        back,
        // post of step 1: the same image (not built again), with its post-entrypoint
        ws,
        secret,
        ran,
        back,
    };
    var fake: FakeSession = .{ .answers = &answers, .arena = arena };
    var buf: [8192]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buf);
    var log: sink.LogSink = .{ .stdout = .{ .writer = &w } };
    const res = try run(arena, std.testing.io, &env, .{ .test_session_argv = &.{ "sh", "-c", fake_child }, .test_transport = fake.transport() }, job, &log);

    const seen = fake.seen.items;
    try std.testing.expect(res.succeeded);
    try std.testing.expectEqual(@as(usize, 18), seen.len);
    for (seen) |d| try std.testing.expect(braceBalanced(d));
    try std.testing.expect(std.mem.indexOf(u8, seen[3], "from(address:\"busybox:1.37.0-musl\") { file(path:\"/bin/busybox\")") != null);
    try std.testing.expect(std.mem.indexOf(u8, seen[3], "empty: directory { id }") != null);
    // Built with the Dockerfile's directory as the context.
    try std.testing.expect(std.mem.indexOf(u8, seen[4], "loadDirectoryFromID(id:\"D1\") { directory(path:\"sub/docker\") { dockerBuild(dockerfile:\"Dockerfile\")") != null);
    try std.testing.expect(std.mem.indexOf(u8, seen[5], "loadContainerFromID(id:\"C0\") { directory(path:\"/github/workspace\")") != null);
    const run1 = seen[7];
    try std.testing.expect(std.mem.indexOf(u8, run1, "loadContainerFromID(id:\"IMG\") { withWorkdir(path:\"/github/workspace\")") != null);
    // The image's user owns what it writes: the workspace, /github/home, file commands, the event.
    try std.testing.expect(std.mem.indexOf(u8, run1, "withDirectory(path:\"/github/workspace\",source:\"WS0\",owner:\"actionuser\")") != null);
    try std.testing.expect(std.mem.indexOf(u8, run1, "withDirectory(path:\"/github/home\",source:\"EMPTY\",owner:\"actionuser\")") != null);
    try std.testing.expect(std.mem.indexOf(u8, run1, "withDirectory(path:\"/github/file_commands\",source:\"EMPTY\",owner:\"actionuser\")") != null);
    try std.testing.expect(std.mem.indexOf(u8, run1, "withDirectory(path:\"/github/workflow\",source:\"EMPTY\",owner:\"actionuser\")") != null);
    try std.testing.expect(std.mem.indexOf(u8, run1, "withFile(path:\"/github/_runtime/busybox\",permissions:493,source:\"BB\")") != null);
    try std.testing.expect(std.mem.indexOf(u8, run1, "withExec(args:[\"/github/_runtime/busybox\",\"sh\",\"-c\",") != null);
    // The image's entrypoint with the action's args, evaluated with its inputs; its env and INPUT_*.
    try std.testing.expect(std.mem.indexOf(u8, run1, "'/entry.sh' 'hello world'") != null);
    try std.testing.expect(std.mem.indexOf(u8, run1, "unused") == null);
    try std.testing.expect(std.mem.indexOf(u8, run1, "'GREETING=hi world'") != null);
    try std.testing.expect(std.mem.indexOf(u8, run1, "'INPUT_WHO=world'") != null);
    try std.testing.expect(std.mem.indexOf(u8, run1, "'HOME=/github/home'") != null);
    try std.testing.expect(std.mem.indexOf(u8, run1, "'ACTIONS_RUNTIME_TOKEN='\\\"$ZIG_SECRET_0\\\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, run1, "withEnvVariable(name:\"GITHUB_WORKSPACE\",value:\"/github/workspace\")") != null);
    try std.testing.expect(std.mem.indexOf(u8, run1, "ws: directory(path:\"/github/workspace\") { id } home: directory(path:\"/github/home\") { id }") != null);
    // The workspace it left replaces the job's.
    try std.testing.expect(std.mem.indexOf(u8, seen[8], "withoutDirectory(path:\"/github/workspace\") { withDirectory(path:\"/github/workspace\",source:\"WS1\")") != null);
    // docker://: the entrypoint input, args split like a command line, the step's env; /github/home is shared.
    try std.testing.expect(std.mem.indexOf(u8, seen[9], "from(address:\"alpine:3.22\") { id entrypoint defaultArgs user }") != null);
    const run2 = seen[12];
    try std.testing.expect(std.mem.indexOf(u8, run2, "loadContainerFromID(id:\"ALP\")") != null);
    try std.testing.expect(std.mem.indexOf(u8, run2, "'sh' '-c' 'echo $GREETING' 'x'") != null);
    try std.testing.expect(std.mem.indexOf(u8, run2, "/bin/sh") == null);
    try std.testing.expect(std.mem.indexOf(u8, run2, "'GREETING=from the step'") != null);
    try std.testing.expect(std.mem.indexOf(u8, run2, "withDirectory(path:\"/github/home\",source:\"H1\")") != null);
    try std.testing.expect(std.mem.indexOf(u8, run2, "owner:") == null);
    try std.testing.expect(std.mem.indexOf(u8, run2, "loadContainerFromID(id:\"CB\")") == null);
    try std.testing.expect(std.mem.indexOf(u8, seen[10], "loadContainerFromID(id:\"CB\")") != null);
    // The post: same image, its post-entrypoint with the args.
    try std.testing.expect(std.mem.indexOf(u8, seen[16], "loadContainerFromID(id:\"IMG\")") != null);
    try std.testing.expect(std.mem.indexOf(u8, seen[16], "'/cleanup.sh' 'hello world'") != null);
    for (seen) |d| if (std.mem.indexOf(u8, d, "setSecret") == null) try std.testing.expect(std.mem.indexOf(u8, d, "ghs_") == null);
    const out = w.buffered();
    try std.testing.expect(std.mem.indexOf(u8, out, "##[group]Run o/dock/sub@v1") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "image: built from sub/docker/Dockerfile") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "[job 0 step 3 stdout] Post job cleanup.") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "##[group]Post") == null);
    try std.testing.expect(std.mem.indexOf(u8, out, "image: alpine:3.22") != null);
}

test "hashFiles globs the workspace, honours exclusions, and hashes the files' digests in path order" {
    var a: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer a.deinit();
    const arena = a.allocator();
    var env: std.process.Environ.Map = .init(arena);
    var st = testStep("");
    st.action.script.script = .{ .expr = "format('echo key-{0}', hashFiles('**/package-lock.json', '!node_modules/**'))" };
    var none = testStep("");
    none.action.script.script = .{ .expr = "format('echo none-{0}.', hashFiles('/elsewhere/x', '!a'))" };
    const steps = [_]job_mod.Step{ st, none };
    const d1 = "1111111111111111111111111111111111111111111111111111111111111111";
    const d2 = "2222222222222222222222222222222222222222222222222222222222222222";
    const answers = [_][]const u8{
        base_answer,
        "{\"data\":{\"loadContainerFromID\":{\"directory\":{\"p0\":[\"package-lock.json\",\"node_modules/x/package-lock.json\",\"a/package-lock.json\"],\"d0\":[]," ++
            "\"p1\":[\"node_modules/\",\"node_modules/x/\",\"node_modules/x/package-lock.json\"],\"d1\":[\"node_modules/x/\",\"node_modules/x/package-lock.json\"]}}}}",
        "{\"data\":{\"loadContainerFromID\":{\"withNewFile\":{\"withExec\":{\"exitCode\":0,\"stdout\":\"" ++ d1 ++ "  a/package-lock.json\\n" ++ d2 ++ "  package-lock.json\\n\",\"stderr\":\"\"}}}}}",
        try exec(arena, "C1", 0, ""),
        try exec(arena, "C2", 0, ""),
    };
    var fake: FakeSession = .{ .answers = &answers, .arena = arena };
    var buf: [4096]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buf);
    var log: sink.LogSink = .{ .stdout = .{ .writer = &w } };
    const res = try run(arena, std.testing.io, &env, .{ .test_session_argv = &.{ "sh", "-c", fake_child }, .test_transport = fake.transport() }, testJob(&steps), &log);
    try std.testing.expect(res.succeeded);
    const seen = fake.seen.items;
    try std.testing.expectEqual(@as(usize, 5), seen.len);
    for (seen) |d| try std.testing.expect(braceBalanced(d));
    try std.testing.expect(std.mem.indexOf(u8, seen[1], "loadContainerFromID(id:\"C0\") { directory(path:\"/github/workspace\") { p0: glob(pattern:\"**/package-lock.json\") d0: glob(pattern:\"**/package-lock.json/**\") p1: glob(pattern:\"node_modules/**\")") != null);
    // node_modules is excluded; the rest is hashed in path order, in the job's container.
    try std.testing.expect(std.mem.indexOf(u8, seen[2], "loadContainerFromID(id:\"C0\") { withNewFile(path:\"/tmp/zig-runner-hashfiles\",contents:\"a/package-lock.json\\npackage-lock.json\")") != null);
    try std.testing.expect(std.mem.indexOf(u8, seen[2], "xargs -0 sha256sum --") != null);
    var h = std.crypto.hash.sha2.Sha256.init(.{});
    h.update(&(@as([32]u8, @splat(0x11))));
    h.update(&(@as([32]u8, @splat(0x22))));
    const want = try std.fmt.allocPrint(arena, "echo key-{s}", .{&std.fmt.bytesToHex(h.finalResult(), .lower)});
    try std.testing.expect(std.mem.indexOf(u8, seen[3], want) != null);
    // Nothing inside the workspace to include: "" without asking Dagger.
    try std.testing.expect(std.mem.indexOf(u8, seen[4], "echo none-.") != null);
}

test "a local action is read from the workspace when its step runs, and is not mounted" {
    var a: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer a.deinit();
    const arena = a.allocator();
    var env: std.process.Environ.Map = .init(arena);
    const action_yml =
        \\inputs:
        \\  who:
        \\    default: nobody
        \\runs:
        \\  using: composite
        \\  steps:
        \\    - shell: bash
        \\      run: echo "hi ${{ inputs.who }} from $GITHUB_ACTION_PATH (${{ github.action_repository }})"
    ;
    const inputs = [_]job_mod.Input{.{ .name = "who", .value = .{ .lit = "you" } }};
    var greet = usesStep("greet", "", "", "", &inputs);
    greet.action.uses.path = ".github/actions/greet";
    greet.action.uses.local = true;
    var missing = usesStep("missing", "", "", "", &.{});
    missing.action.uses.path = "nope";
    missing.action.uses.local = true;
    missing.condition = "always()";
    const steps = [_]job_mod.Step{ testStep("echo checkout"), greet, missing };
    const answers = [_][]const u8{
        base_answer,
        try exec(arena, "C1", 0, ""),
        "{\"data\":{\"loadContainerFromID\":{\"directory\":{\"id\":\"LD\",\"entries\":[\"action.yml\"]}}}}",
        try fileAnswer(arena, action_yml),
        try exec(arena, "C2", 0, ""),
        "{\"errors\":[{\"message\":\"lstat /github/workspace/nope: no such file or directory\"}]}",
    };
    var fake: FakeSession = .{ .answers = &answers, .arena = arena };
    var buf: [8192]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buf);
    var log: sink.LogSink = .{ .stdout = .{ .writer = &w } };
    const res = try run(arena, std.testing.io, &env, .{ .test_session_argv = &.{ "sh", "-c", fake_child }, .test_transport = fake.transport() }, testJob(&steps), &log);
    const seen = fake.seen.items;
    try std.testing.expectEqual(@as(usize, 6), seen.len);
    for (seen) |d| try std.testing.expect(braceBalanced(d));
    // Read after the earlier step, from the container that step left; nothing is fetched up front.
    try std.testing.expect(std.mem.indexOf(u8, seen[2], "loadContainerFromID(id:\"C1\") { directory(path:\"/github/workspace/.github/actions/greet\") { id entries } }") != null);
    try std.testing.expect(std.mem.indexOf(u8, seen[3], "loadDirectoryFromID(id:\"LD\") { file(path:\"action.yml\")") != null);
    const run1 = seen[4];
    try std.testing.expect(std.mem.indexOf(u8, run1, "withDirectory") == null);
    try std.testing.expect(std.mem.indexOf(u8, run1, "hi you from $GITHUB_ACTION_PATH ()") != null);
    try std.testing.expect(std.mem.indexOf(u8, run1, "'GITHUB_ACTION_PATH=/github/workspace/.github/actions/greet'") != null);
    try std.testing.expect(std.mem.indexOf(u8, run1, "'GITHUB_ACTION_REPOSITORY='") != null);
    try std.testing.expectEqual(Outcome.success, res.steps[1].outcome);
    try std.testing.expectEqual(Outcome.failure, res.steps[2].outcome);
    try std.testing.expect(std.mem.indexOf(u8, w.buffered(), "Can't find 'action.yml' or 'action.yaml' under '/github/workspace/nope'. Did you forget to run actions/checkout") != null);
}

test "a composite action's uses: steps: nested actions, the built-in checkout, outputs, and the nesting limit" {
    var a: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer a.deinit();
    const arena = a.allocator();
    var env: std.process.Environ.Map = .init(arena);
    const outer_yml =
        \\inputs:
        \\  who:
        \\    default: nobody
        \\outputs:
        \\  greeting:
        \\    value: ${{ steps.inner.outputs.greeting }}
        \\runs:
        \\  using: composite
        \\  steps:
        \\    - id: inner
        \\      uses: o/inner@v1
        \\      with:
        \\        name: ${{ inputs.who }}
        \\    - uses: actions/checkout@v4
        \\      with:
        \\        path: sub
        \\    - shell: bash
        \\      run: echo "inner said ${{ steps.inner.outputs.greeting }}"
    ;
    const inner_yml =
        \\inputs:
        \\  name:
        \\    required: true
        \\outputs:
        \\  greeting:
        \\    value: ${{ steps.g.outputs.text }}
        \\runs:
        \\  using: composite
        \\  steps:
        \\    - id: g
        \\      shell: bash
        \\      run: echo "text=hello ${{ inputs.name }}" >> "$GITHUB_OUTPUT"
    ;
    const inputs = [_]job_mod.Input{.{ .name = "who", .value = .{ .lit = "zig" } }};
    var after = testStep("");
    after.action.script.script = .{ .expr = "format('echo {0}', steps.outer.outputs.greeting)" };
    const steps = [_]job_mod.Step{ usesStep("outer", "o", "outer", "v1", &inputs), after };
    const answers = [_][]const u8{
        base_answer,
        try treeAnswer(arena, "D1", &.{"action.yml"}),
        try fileAnswer(arena, outer_yml),
        // the nested action, loaded when its step runs
        try treeAnswer(arena, "D2", &.{"action.yml"}),
        try fileAnswer(arena, inner_yml),
        "{\"data\":{\"loadContainerFromID\":{\"withExec\":{\"id\":\"C1\",\"exitCode\":0,\"stdout\":\"\",\"stderr\":\"\",\"fc_output\":{\"contents\":\"text=hello zig\\n\"}}}}}",
        // the checkout
        "{\"data\":{\"git\":{\"commit\":{\"tree\":{\"id\":\"TREE1\"}}}}}",
        try exec(arena, "C2", 0, ""),
        try exec(arena, "C3", 0, ""),
        try exec(arena, "C4", 0, ""),
    };
    var fake: FakeSession = .{ .answers = &answers, .arena = arena };
    var buf: [8192]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buf);
    var log: sink.LogSink = .{ .stdout = .{ .writer = &w } };
    const res = try run(arena, std.testing.io, &env, .{ .test_session_argv = &.{ "sh", "-c", fake_child }, .test_transport = fake.transport() }, testJob(&steps), &log);
    try std.testing.expect(res.succeeded);
    const seen = fake.seen.items;
    try std.testing.expectEqual(@as(usize, 10), seen.len);
    for (seen) |d| try std.testing.expect(braceBalanced(d));
    try std.testing.expect(std.mem.indexOf(u8, seen[3], "git(url:\"https://github.com/o/inner.git\")") != null);
    // The nested action gets the outer action's input, and its own directory.
    try std.testing.expect(std.mem.indexOf(u8, seen[5], "withDirectory(path:\"/github/_actions/o/inner/v1\",source:\"D2\")") != null);
    try std.testing.expect(std.mem.indexOf(u8, seen[5], "echo \\\"text=hello zig\\\"") != null);
    // actions/checkout is the built-in checkout, at its path.
    try std.testing.expect(std.mem.indexOf(u8, seen[7], "withDirectory(path:\"/github/workspace/sub\",source:\"TREE1\")") != null);
    // Its outputs reach the outer action's steps and outputs, and the job's next step.
    try std.testing.expect(std.mem.indexOf(u8, seen[8], "inner said hello zig") != null);
    try std.testing.expect(std.mem.indexOf(u8, seen[9], "echo hello zig") != null);

    // An action that uses itself stops at GitHub's limit of 9 levels.
    const loop_yml = "runs:\n  using: composite\n  steps:\n    - uses: o/loop@v1\n";
    var loop_answers: std.ArrayList([]const u8) = .empty;
    try loop_answers.append(arena, base_answer);
    for (0..10) |_| {
        try loop_answers.append(arena, try treeAnswer(arena, "DL", &.{"action.yml"}));
        try loop_answers.append(arena, try fileAnswer(arena, loop_yml));
    }
    const loop_steps = [_]job_mod.Step{usesStep("loop", "o", "loop", "v1", &.{})};
    var fake2: FakeSession = .{ .answers = loop_answers.items, .arena = arena };
    var buf2: [8192]u8 = undefined;
    var w2: std.Io.Writer = .fixed(&buf2);
    var log2: sink.LogSink = .{ .stdout = .{ .writer = &w2 } };
    const res2 = try run(arena, std.testing.io, &env, .{ .test_session_argv = &.{ "sh", "-c", fake_child }, .test_transport = fake2.transport() }, testJob(&loop_steps), &log2);
    try std.testing.expect(!res2.succeeded);
    try std.testing.expectEqual(@as(usize, 21), fake2.seen.items.len);
    try std.testing.expect(std.mem.indexOf(u8, w2.buffered(), "o/loop@v1: composite actions can be nested at most 9 levels deep") != null);
}

test "steps see the name the runner registered under" {
    var a: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer a.deinit();
    const arena = a.allocator();
    var env: std.process.Environ.Map = .init(arena);
    var st = testStep("");
    st.action.script.script = .{ .expr = "format('echo {0}', runner.name)" };
    const steps = [_]job_mod.Step{st};
    const answers = [_][]const u8{ base_answer, try exec(arena, "C1", 0, "") };
    var fake: FakeSession = .{ .answers = &answers, .arena = arena };
    var buf: [2048]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buf);
    var log: sink.LogSink = .{ .stdout = .{ .writer = &w } };
    _ = try run(arena, std.testing.io, &env, .{ .runner_name = "zig-1a2b3c4d", .test_session_argv = &.{ "sh", "-c", fake_child }, .test_transport = fake.transport() }, testJob(&steps), &log);
    try std.testing.expect(std.mem.indexOf(u8, fake.seen.items[0], "withEnvVariable(name:\"RUNNER_NAME\",value:\"zig-1a2b3c4d\")") != null);
    try std.testing.expect(std.mem.indexOf(u8, fake.seen.items[1], "echo zig-1a2b3c4d") != null);
}

test "logs read like GitHub's: Set up job, then each step's header with its shell, env or inputs" {
    var a: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer a.deinit();
    const arena = a.allocator();
    var env: std.process.Environ.Map = .init(arena);
    var run_step = testStep("echo one\necho two");
    run_step.env = &.{
        .{ .name = "GREETING", .value = .{ .lit = "hi" } },
        .{ .name = "TOKEN", .value = .{ .lit = "s3cr3t-value" } },
    };
    var co = testStep("x");
    co.action = .{ .checkout = &.{.{ .name = "fetch-depth", .value = .{ .lit = "0" } }} };
    co.uses = "actions/checkout@v4";
    const action_yml = "runs:\n  using: composite\n  steps:\n    - shell: sh\n      run: echo from-the-action\n";
    const steps = [_]job_mod.Step{ co, usesStep("act", "o", "act", "v1", &.{}), run_step };
    var job = testJob(&steps);
    job.secrets = &.{"s3cr3t-value"};
    job.display_name = "build (linux)";
    job.runner_group = "Default";
    job.token_permissions = "{\"Contents\":\"read\",\"PullRequests\":\"write\"}";
    job.env = &.{.{ .name = "FROM_JOB", .value = .{ .lit = "j" } }};
    const answers = [_][]const u8{
        base_answer,
        "{\"data\":{\"git\":{\"ref\":{\"tree\":{\"id\":\"D1\",\"entries\":[\"action.yml\"]},\"sha\":\"0123456789abcdef0123456789abcdef01234567\"}}}}",
        try fileAnswer(arena, action_yml),
        "{\"data\":{\"git\":{\"commit\":{\"tree\":{\"id\":\"TREE1\"}}}}}",
        try exec(arena, "C1", 0, ""),
        try exec(arena, "C2", 0, ""),
        "{\"data\":{\"setSecret\":{\"id\":\"SEC\"}}}",
        try exec(arena, "C3", 0, ""),
    };
    var fake: FakeSession = .{ .answers = &answers, .arena = arena };
    var buf: [8192]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buf);
    var log: sink.LogSink = .{ .stdout = .{ .writer = &w, .secrets = &.{"s3cr3t-value"} } };
    const res = try run(arena, std.testing.io, &env, .{ .runner_name = "zig-1a2b3c4d", .test_session_argv = &.{ "sh", "-c", fake_child }, .test_transport = fake.transport() }, job, &log);
    try std.testing.expect(res.succeeded);
    try std.testing.expect(std.mem.indexOf(u8, fake.seen.items[1], "tree(depth:1) { id entries(path:\".\") } sha: commit") != null);
    const out = w.buffered();
    const want_in_order = [_][]const u8{
        "[job 0 step 0 stdout] Current runner version: '",
        "[job 0 step 0 stdout] Runner name: 'zig-1a2b3c4d'",
        "[job 0 step 0 stdout] Runner group name: 'Default'",
        "[job 0 step 0 stdout] ##[group]Runner Image",
        "[job 0 step 0 stdout] Image: ubuntu:24.04",
        "[job 0 step 0 stdout] ##[group]GITHUB_TOKEN Permissions",
        "[job 0 step 0 stdout] Contents: read",
        "[job 0 step 0 stdout] PullRequests: write",
        "[job 0 step 0 stdout] Secret source: Actions",
        "[job 0 step 0 stdout] Prepare workflow directory",
        "[job 0 step 0 stdout] Prepare all required actions",
        "[job 0 step 0 stdout] Getting action download info",
        "[job 0 step 0 stdout] Download action repository 'o/act@v1' (SHA:0123456789abcdef0123456789abcdef01234567)",
        "[job 0 step 0 stdout] Complete job name: build (linux)",
        "[job 0 step 1 stdout] ##[group]Run actions/checkout@v4",
        "[job 0 step 1 stdout] with:",
        "[job 0 step 1 stdout]   fetch-depth: 0",
        "[job 0 step 1 stdout] ##[endgroup]",
        "[job 0 step 2 stdout] ##[group]Run echo from-the-action",
        "[job 0 step 2 stdout] shell: /usr/bin/sh -e {0}",
        "[job 0 step 3 stdout] ##[group]Run echo one",
        "[job 0 step 3 stdout] echo one",
        "[job 0 step 3 stdout] echo two",
        "[job 0 step 3 stdout] shell: /usr/bin/bash -e {0}",
        "[job 0 step 3 stdout] env:",
        "[job 0 step 3 stdout]   FROM_JOB: j",
        "[job 0 step 3 stdout]   GREETING: hi",
        "[job 0 step 3 stdout]   TOKEN: ***",
        "[job 0 step 3 stdout] ##[endgroup]",
    };
    var at: usize = 0;
    for (want_in_order) |want| {
        const i = std.mem.indexOfPos(u8, out, at, want) orelse {
            std.debug.print("missing (in order): {s}\nlog:\n{s}\n", .{ want, out });
            return error.TestUnexpectedResult;
        };
        at = i + want.len;
    }
    // The default shell is GitHub's `bash -e` (no pipefail); an explicit `sh` stays `sh -e`.
    try std.testing.expect(std.mem.indexOf(u8, fake.seen.items[7], "printf '%s' 'echo one\\necho two' > /tmp/zig-runner-step-3.sh") != null);
    try std.testing.expect(std.mem.indexOf(u8, fake.seen.items[7], "\\\"$zig_shell\\\" '-e' '/tmp/zig-runner-step-3.sh'") != null);
    try std.testing.expect(std.mem.indexOf(u8, fake.seen.items[5], "'sh' '-e' '/tmp/zig-runner-step-") != null);
}

test "job outputs are evaluated after the steps; one carrying a secret is skipped" {
    var a: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer a.deinit();
    const arena = a.allocator();
    var env: std.process.Environ.Map = .init(arena);
    var st = testStep("echo version=1.2.3 >> $GITHUB_OUTPUT");
    st.context_name = "v";
    const steps = [_]job_mod.Step{st};
    var job = testJob(&steps);
    job.secrets = &.{"s3cr3t-value"};
    job.outputs = &.{
        .{ .name = "version", .value = .{ .expr = "steps.v.outputs.version" } },
        .{ .name = "literal", .value = .{ .lit = "fixed" } },
        .{ .name = "combined", .value = .{ .expr = "format('v={0}', steps.v.outputs.version)" } },
        .{ .name = "leak", .value = .{ .lit = "token s3cr3t-value" } },
    };
    const answers = [_][]const u8{
        base_answer,
        "{\"data\":{\"loadContainerFromID\":{\"withExec\":{\"id\":\"C1\",\"exitCode\":0,\"stdout\":\"\",\"stderr\":\"\",\"fc_output\":{\"contents\":\"version=1.2.3\\n\"}}}}}",
    };
    var fake: FakeSession = .{ .answers = &answers, .arena = arena };
    var buf: [4096]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buf);
    var log: sink.LogSink = .{ .stdout = .{ .writer = &w } };
    const res = try run(arena, std.testing.io, &env, .{ .test_session_argv = &.{ "sh", "-c", fake_child }, .test_transport = fake.transport() }, job, &log);
    try std.testing.expect(res.succeeded);
    try std.testing.expectEqual(@as(usize, 3), res.outputs.len);
    try std.testing.expectEqualStrings("version", res.outputs[0].name);
    try std.testing.expectEqualStrings("1.2.3", res.outputs[0].value);
    try std.testing.expectEqualStrings("fixed", res.outputs[1].value);
    try std.testing.expectEqualStrings("v=1.2.3", res.outputs[2].value);
    const want = [_][]const u8{ "Evaluate and set job outputs", "Set output 'version'", "Set output 'literal'", "Set output 'combined'", "##[warning]Skip output 'leak' since it may contain secret." };
    try std.testing.expectEqual(want.len, res.output_lines.len);
    for (want, res.output_lines) |wnt, got| try std.testing.expectEqualStrings(wnt, got);
}

test "splitArgs splits like a command line, with double quotes" {
    var a: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer a.deinit();
    const got = try splitArgs(a.allocator(), "  -c \"echo hi there\"  a\\\"b 'x y' \"\"");
    const want = [_][]const u8{ "-c", "echo hi there", "a\"b", "'x", "y'", "" };
    try std.testing.expectEqual(want.len, got.len);
    for (want, got) |wnt, g| try std.testing.expectEqualStrings(wnt, g);
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

test "workflow commands in a step's output: masks, groups, annotations, debug, set-output, stop-commands" {
    var a: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer a.deinit();
    const arena = a.allocator();
    var env: std.process.Environ.Map = .init(arena);
    var after = testStep("");
    after.action.script.script = .{ .expr = "format('echo got={0}', steps.cmds.outputs.legacy)" };
    var first = testStep("x");
    first.context_name = "cmds";
    const steps = [_]job_mod.Step{ first, after };
    const out1 =
        "before s3cr3t-token\\n::add-mask::s3cr3t-token\\nafter s3cr3t-token\\n" ++
        "::group::Install%25\\ninside\\n::endgroup::\\n" ++
        "::error file=a.js,line=1::bad%0Asecond line\\n::warning::careful\\n::debug::hidden\\n" ++
        "::set-output name=legacy::42\\n::set-env name=X::1\\n" ++
        "::stop-commands::tok\\n::group::not a group\\n::add-mask::not-masked\\n::tok::\\n::notice::back\\n";
    const answers = [_][]const u8{ base_answer, try exec(arena, "C1", 0, out1), try exec(arena, "C2", 0, "s3cr3t-token in step 2\\n") };
    var fake: FakeSession = .{ .answers = &answers, .arena = arena };
    var buf: [8192]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buf);
    var log: sink.LogSink = .{ .stdout = .{ .writer = &w } };
    const res = try run(arena, std.testing.io, &env, .{ .test_session_argv = &.{ "sh", "-c", fake_child }, .test_transport = fake.transport() }, testJob(&steps), &log);
    try std.testing.expect(res.succeeded);
    const want =
        \\[job 0 step 1 stdout] before s3cr3t-token
        \\[job 0 step 1 stdout] after ***
        \\[job 0 step 1 stdout] ##[group]Install%
        \\[job 0 step 1 stdout] inside
        \\[job 0 step 1 stdout] ##[endgroup]
        \\[job 0 step 1 stdout] ##[error]bad
        \\[job 0 step 1 stdout] second line
        \\[job 0 step 1 stdout] ##[warning]careful
        \\[job 0 step 1 stdout] ##[error]The `set-env` command is disabled.
    ;
    const got = w.buffered();
    var it = std.mem.splitScalar(u8, want, '\n');
    var pos: usize = 0;
    while (it.next()) |line| {
        const i = std.mem.indexOfPos(u8, got, pos, line) orelse {
            std.debug.print("missing, in order: {s}\n--- log:\n{s}\n", .{ line, got });
            return error.TestUnexpectedResult;
        };
        pos = i + line.len;
    }
    // Lines that must not be logged: the mask command, debug (ACTIONS_STEP_DEBUG is off), stop/resume.
    for ([_][]const u8{ "add-mask::s3cr3t", "hidden", "::stop-commands", "::tok::", "::set-output" }) |no| try std.testing.expect(std.mem.indexOf(u8, got, no) == null);
    // While stopped, commands are plain text; afterwards they work again.
    try std.testing.expect(std.mem.indexOf(u8, got, "] ::group::not a group") != null);
    try std.testing.expect(std.mem.indexOf(u8, got, "] ::add-mask::not-masked") != null);
    try std.testing.expect(std.mem.indexOf(u8, got, "##[notice]back") != null);
    // The mask holds for later steps, and set-output reached steps.<id>.outputs.
    try std.testing.expect(std.mem.indexOf(u8, got, "[job 0 step 2 stdout] *** in step 2") != null);
    try std.testing.expect(std.mem.indexOf(u8, fake.seen.items[2], "echo got=42") != null);
    // Annotations for completejob: the error points to its file; the others, to their line in the
    // step's log.
    try std.testing.expectEqual(@as(usize, 4), res.annotations.len);
    const err = res.annotations[0];
    try std.testing.expectEqual(@as(u32, 1), err.step);
    try std.testing.expectEqualStrings("a.js", err.an.file.?);
    try std.testing.expectEqualStrings("1", err.an.line.?);
    try std.testing.expectEqualStrings("bad\nsecond line", err.an.message);
    var n: u32 = 0;
    var lines = std.mem.splitScalar(u8, got, '\n');
    while (lines.next()) |l| {
        if (!std.mem.startsWith(u8, l, "[job 0 step 1 stdout] ")) continue;
        n += 1;
        if (std.mem.endsWith(u8, l, "##[warning]careful")) break;
    }
    try std.testing.expectEqualStrings("warning", res.annotations[1].an.level);
    try std.testing.expectEqualStrings(try std.fmt.allocPrint(arena, "{d}", .{n}), res.annotations[1].an.line.?);
    try std.testing.expect(std.mem.startsWith(u8, res.annotations[2].an.message, "The `set-env` command is disabled."));
    try std.testing.expectEqualStrings(try std.fmt.allocPrint(arena, "{d}", .{n + 1}), res.annotations[2].an.line.?);
    try std.testing.expectEqualStrings("notice", res.annotations[3].an.level);
}

test "ACTIONS_STEP_DEBUG shows ::debug:: lines" {
    var a: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer a.deinit();
    const arena = a.allocator();
    var env: std.process.Environ.Map = .init(arena);
    const steps = [_]job_mod.Step{testStep("x")};
    var job = testJob(&steps);
    job.secret_vars = &.{.{ .name = "ACTIONS_STEP_DEBUG", .value = "true" }};
    const answers = [_][]const u8{ base_answer, try exec(arena, "C1", 0, "::debug::shown%0Anow\\n") };
    var fake: FakeSession = .{ .answers = &answers, .arena = arena };
    var buf: [1024]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buf);
    var log: sink.LogSink = .{ .stdout = .{ .writer = &w } };
    _ = try run(arena, std.testing.io, &env, .{ .test_session_argv = &.{ "sh", "-c", fake_child }, .test_transport = fake.transport() }, job, &log);
    try std.testing.expect(std.mem.indexOf(u8, w.buffered(), "##[debug]shown\nnow") != null);
}

test "what a step writes to GITHUB_STEP_SUMMARY is kept for upload" {
    var a: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer a.deinit();
    const arena = a.allocator();
    var env: std.process.Environ.Map = .init(arena);
    const steps = [_]job_mod.Step{ testStep("x"), testStep("y") };
    const with_summary = "{\"data\":{\"loadContainerFromID\":{\"withExec\":{\"id\":\"C1\",\"exitCode\":0,\"stdout\":\"\",\"stderr\":\"\",\"fc_step_summary\":{\"contents\":\"# Results\\n| a | b |\\n\"}}}}}";
    const answers = [_][]const u8{ base_answer, with_summary, try exec(arena, "C2", 0, "") };
    var fake: FakeSession = .{ .answers = &answers, .arena = arena };
    var buf: [2048]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buf);
    var log: sink.LogSink = .{ .stdout = .{ .writer = &w } };
    const res = try run(arena, std.testing.io, &env, .{ .test_session_argv = &.{ "sh", "-c", fake_child }, .test_transport = fake.transport() }, testJob(&steps), &log);
    try std.testing.expectEqualStrings("# Results\n| a | b |\n", res.summaries[0]);
    try std.testing.expectEqualStrings("", res.summaries[1]);
    // The query reads the file back.
    try std.testing.expect(std.mem.indexOf(u8, fake.seen.items[1], "fc_all: file(path:") != null);
}

test "package caches: one volume per tool, keyed by repository, separate for fork pull requests" {
    var a: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer a.deinit();
    const arena = a.allocator();
    var env: std.process.Environ.Map = .init(arena);
    const steps = [_]job_mod.Step{testStep("npm ci")};
    const fork_ctx =
        \\{"github":{"t":2,"d":[{"k":"repository","v":"o/r"},{"k":"event","v":{"t":2,"d":[{"k":"pull_request","v":{"t":2,"d":[{"k":"head","v":{"t":2,"d":[{"k":"repo","v":{"t":2,"d":[{"k":"full_name","v":"someone/r"}]}}]}}]}}]}}]}}
    ;
    for ([_]bool{ false, true }) |fork| {
        var job = testJob(&steps);
        if (fork) job.context_data = try std.json.parseFromSliceLeaky(std.json.Value, arena, fork_ctx, .{});
        var vols: std.Io.Writer.Allocating = .init(arena);
        try vols.writer.writeAll("{\"data\":{");
        for (package_cache_dirs, 0..) |_, i| try vols.writer.print("{s}\"c{d}\":{{\"id\":\"V{d}\"}}", .{ if (i == 0) "" else ",", i, i });
        try vols.writer.writeAll("}}");
        const answers = [_][]const u8{ vols.written(), base_answer, try exec(arena, "C1", 0, "") };
        var fake: FakeSession = .{ .answers = &answers, .arena = arena };
        var buf: [1024]u8 = undefined;
        var w: std.Io.Writer = .fixed(&buf);
        var log: sink.LogSink = .{ .stdout = .{ .writer = &w } };
        const res = try run(arena, std.testing.io, &env, .{ .package_caches = true, .test_session_argv = &.{ "sh", "-c", fake_child }, .test_transport = fake.transport() }, job, &log);
        try std.testing.expect(res.succeeded);
        const scope = if (fork) "fork-pr" else "repo";
        try std.testing.expect(std.mem.indexOf(u8, fake.seen.items[0], try std.fmt.allocPrint(arena, "c1: cacheVolume(key:\"zig-runner/o/r/{s}/npm\")", .{scope})) != null);
        // The tool cache is also keyed by the job's image (its binaries are built for it).
        try std.testing.expect(std.mem.indexOf(u8, fake.seen.items[0], try std.fmt.allocPrint(arena, "c0: cacheVolume(key:\"zig-runner/o/r/{s}/toolcache/ubuntu:24.04\")", .{scope})) != null);
        try std.testing.expect(std.mem.indexOf(u8, fake.seen.items[0], try std.fmt.allocPrint(arena, "cacheVolume(key:\"zig-runner/o/r/{s}/zig\")", .{scope})) != null);
        // Mounted on the base container, so every step has them.
        try std.testing.expect(std.mem.indexOf(u8, fake.seen.items[1], "withMountedCache(path:\"/opt/hostedtoolcache\",cache:\"V0\")") != null);
        try std.testing.expect(std.mem.indexOf(u8, fake.seen.items[1], "withMountedCache(path:\"/root/.npm\",cache:\"V1\")") != null);
        try std.testing.expect(std.mem.indexOf(u8, fake.seen.items[1], "withMountedCache(path:\"/root/.cache/zig\",cache:\"V11\")") != null);
        try std.testing.expect(braceBalanced(fake.seen.items[1]));
    }
}

test "package caches in a container job: variables point the tools at the volumes, the image's own value winning" {
    var a: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer a.deinit();
    const arena = a.allocator();
    var env: std.process.Environ.Map = .init(arena);
    const steps = [_]job_mod.Step{testStep("go test ./...")};
    var job = testJob(&steps);
    job.container = .{ .name = "", .image = .{ .lit = "golang:1.25" }, .env = &.{.{ .name = "GOCACHE", .value = .{ .lit = "/tmp/gocache" } }} };
    var vols: std.Io.Writer.Allocating = .init(arena);
    try vols.writer.writeAll("{\"data\":{");
    for (package_cache_dirs, 0..) |_, i| try vols.writer.print("{s}\"c{d}\":{{\"id\":\"V{d}\"}}", .{ if (i == 0) "" else ",", i, i });
    try vols.writer.writeAll("}}");
    // Only the base container matters here: the job stops when the answers run out.
    const answers = [_][]const u8{ vols.written(), base_answer };
    var fake: FakeSession = .{ .answers = &answers, .arena = arena };
    var buf: [4096]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buf);
    var log: sink.LogSink = .{ .stdout = .{ .writer = &w } };
    _ = try run(arena, std.testing.io, &env, .{ .package_caches = true, .test_session_argv = &.{ "sh", "-c", fake_child }, .test_transport = fake.transport() }, job, &log);
    const base = fake.seen.items[1];
    // The golang image's GOPATH is /go, not /root/go: the variable says where the volume is.
    try std.testing.expect(std.mem.indexOf(u8, base, "withEnvVariable(name:\"GOMODCACHE\",value:\"/root/go/pkg/mod\")") != null);
    try std.testing.expect(std.mem.indexOf(u8, base, "withMountedCache(path:\"/root/go/pkg/mod\"") != null);
    // A tool without such a variable gets none.
    try std.testing.expect(std.mem.indexOf(u8, base, "CARGO_HOME") == null);
    // The container's env comes after, so its GOCACHE is the one the steps see.
    const ours = std.mem.indexOf(u8, base, "withEnvVariable(name:\"GOCACHE\",value:\"/root/.cache/go-build\")").?;
    const theirs = std.mem.indexOf(u8, base, "withEnvVariable(name:\"GOCACHE\",value:\"/tmp/gocache\")").?;
    try std.testing.expect(ours < theirs);
    try std.testing.expect(braceBalanced(base));
}

test "step caching: run-specific values are volatile, steps with secrets always run, workflows can opt out" {
    var a: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer a.deinit();
    const arena = a.allocator();
    var env: std.process.Environ.Map = .init(arena);
    const ctx_json =
        \\{"github":{"t":2,"d":[{"k":"repository","v":"o/r"},{"k":"sha","v":"abc"},{"k":"run_id","v":"123"},{"k":"run_attempt","v":"2"},
        \\  {"k":"event","v":{"t":2,"d":[{"k":"ref","v":"refs/heads/x"}]}}]}}
    ;
    var with_secret = testStep("deploy");
    with_secret.env = &.{.{ .name = "TOKEN", .value = .{ .lit = "s3cr3t-value" } }};
    const steps = [_]job_mod.Step{ testStep("build"), with_secret };
    for ([_]bool{ false, true }) |opt_out| {
        var job = testJob(&steps);
        job.context_data = try std.json.parseFromSliceLeaky(std.json.Value, arena, ctx_json, .{});
        job.secrets = &.{"s3cr3t-value"};
        if (opt_out) job.env = &.{.{ .name = "ZIG_RUNNER_STEP_CACHE", .value = .{ .lit = "false" } }};
        const answers = [_][]const u8{
            base_answer,
            try exec(arena, "C1", 0, "built\\n"), // no live lines in this fake session: replayed, so "reused"
            "{\"data\":{\"setSecret\":{\"id\":\"SEC\"}}}",
            try exec(arena, "C2", 0, ""),
        };
        var fake: FakeSession = .{ .answers = &answers, .arena = arena };
        var buf: [4096]u8 = undefined;
        var w: std.Io.Writer = .fixed(&buf);
        var log: sink.LogSink = .{ .stdout = .{ .writer = &w } };
        const res = try run(arena, std.testing.io, &env, .{ .step_cache = true, .runner_name = "zig-pi-1a2b3c4d", .test_session_argv = &.{ "sh", "-c", fake_child }, .test_transport = fake.transport() }, job, &log);
        try std.testing.expect(res.succeeded);
        const base = fake.seen.items[0];
        const build = fake.seen.items[1];
        const deploy = fake.seen.items[3];
        for (fake.seen.items) |d| try std.testing.expect(braceBalanced(d));
        // Content stays in the cache key either way.
        try std.testing.expect(std.mem.indexOf(u8, base, "withEnvVariable(name:\"GITHUB_SHA\",value:\"abc\")") != null);
        if (!opt_out) {
            try std.testing.expect(std.mem.indexOf(u8, base, "withVolatileVariable(name:\"GITHUB_RUN_ID\",value:\"123\")") != null);
            // A pool names every job's runner anew: as an input it would make every key new.
            try std.testing.expect(std.mem.indexOf(u8, base, "withVolatileVariable(name:\"RUNNER_NAME\",value:\"zig-pi-1a2b3c4d\")") != null);
            try std.testing.expect(std.mem.indexOf(u8, base, "withVolatileVariable(name:\"ZIG_RUNNER_EVENT\",value:") != null);
            try std.testing.expect(std.mem.indexOf(u8, base, "withNewFile") == null);
            // Each step writes the event file from the volatile variable and hides the variable.
            try std.testing.expect(std.mem.indexOf(u8, build, "printf '%s' \\\"$ZIG_RUNNER_EVENT\\\" > /github/workflow/event.json") != null);
            try std.testing.expect(std.mem.indexOf(u8, build, "-u ZIG_RUNNER_EVENT ") != null);
            // Only the step with a secret is forced to run, with a per-run value.
            try std.testing.expect(std.mem.indexOf(u8, build, "runs this step every time") == null);
            try std.testing.expect(std.mem.indexOf(u8, deploy, ": 'zig-runner runs this step every time: it uses secrets (run 123.2)'") != null);
        } else {
            try std.testing.expect(std.mem.indexOf(u8, base, "withEnvVariable(name:\"GITHUB_RUN_ID\",value:\"123\")") != null);
            try std.testing.expect(std.mem.indexOf(u8, base, "withNewFile(path:\"/github/workflow/event.json\"") != null);
            try std.testing.expect(std.mem.indexOf(u8, base, "withVolatileVariable") == null);
            try std.testing.expect(std.mem.indexOf(u8, deploy, "runs this step every time") == null);
        }
        // The note follows the replayed output, at the end of the job.
        const got = w.buffered();
        const note = std.mem.indexOf(u8, got, "[job 0 step 1 stdout] Reused from Dagger's cache") orelse return error.TestUnexpectedResult;
        try std.testing.expect(std.mem.indexOf(u8, got, "[job 0 step 1 stdout] built").? < note);
    }
}

test "github.workspace is the job's workspace, as actions' input defaults expect" {
    var a: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer a.deinit();
    const arena = a.allocator();
    const steps = [_]job_mod.Step{testStep("true")};
    var job = testJob(&steps);
    job.context_data = try std.json.parseFromSliceLeaky(std.json.Value, arena,
        \\{"github":{"t":2,"d":[{"k":"repository","v":"o/r"}]}}
    , .{});
    var ev = try Evaluator.init(arena, &job);
    try std.testing.expectEqualStrings("/github/workspace", ev.githubString("workspace"));
    try std.testing.expectEqualStrings("/github/workspace", try ev.render(.{ .expr = "github.workspace" }, try ev.scope(&.{})));
}

test "output keys: the step after one that always runs starts from that step's output, by digest" {
    var a: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer a.deinit();
    const arena = a.allocator();
    var env: std.process.Environ.Map = .init(arena);
    const ctx_json =
        \\{"github":{"t":2,"d":[{"k":"repository","v":"o/r"},{"k":"run_id","v":"123"},{"k":"run_attempt","v":"1"}]}}
    ;
    var with_secret = testStep("setup");
    with_secret.env = &.{.{ .name = "TOKEN", .value = .{ .lit = "s3cr3t-value" } }};
    const steps = [_]job_mod.Step{ with_secret, testStep("build") };
    var job = testJob(&steps);
    job.context_data = try std.json.parseFromSliceLeaky(std.json.Value, arena, ctx_json, .{});
    job.secrets = &.{"s3cr3t-value"};
    const answers = [_][]const u8{
        base_answer,
        "{\"data\":{\"setSecret\":{\"id\":\"SEC\"}}}",
        try exec(arena, "C1", 0, ""),
        "{\"data\":{\"bb\":{\"from\":{\"file\":{\"id\":\"BB\"}}},\"empty\":{\"id\":\"E\"}}}",
        "{\"data\":{\"cacheVolume\":{\"id\":\"VOL\"}}}",
        "{\"data\":{\"loadContainerFromID\":{\"zig_base\":\"B0\",\"zig_fs\":{\"id\":\"R0\"}}}}",
        "{\"data\":{\"loadContainerFromID\":{\"rootfs\":{\"changes\":{\"removedPaths\":[\"tmp/it's gone\"],\"layer\":{\"id\":\"L\",\"digest\":\"sha256:0123abcd\"}}}}}}",
        "{\"data\":{\"container\":{\"withExec\":{\"exitCode\":0}}}}",
        "{\"data\":{\"loadContainerFromID\":{\"withExec\":{\"exitCode\":0,\"withoutMount\":{\"withoutMount\":{\"id\":\"N1\"}}}}}}",
        try exec(arena, "C2", 0, ""),
    };
    var fake: FakeSession = .{ .answers = &answers, .arena = arena };
    var buf: [4096]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buf);
    var log: sink.LogSink = .{ .stdout = .{ .writer = &w } };
    const res = try run(arena, std.testing.io, &env, .{ .step_cache = true, .output_keys = true, .test_session_argv = &.{ "sh", "-c", fake_child }, .test_transport = fake.transport() }, job, &log);
    try std.testing.expect(res.succeeded);
    for (fake.seen.items) |d| try std.testing.expect(braceBalanced(d));
    try std.testing.expectEqual(@as(usize, 10), fake.seen.items.len);
    // The store, scoped like the package caches.
    try std.testing.expect(std.mem.indexOf(u8, fake.seen.items[4], "cacheVolume(key:\"zig-runner/o/r/repo/step-outputs\")") != null);
    // What the step changed: the container after it against the one before it.
    try std.testing.expect(std.mem.indexOf(u8, fake.seen.items[5], "loadContainerFromID(id:\"C0\") { zig_base: id zig_fs: rootfs { withoutDirectory(path:\"/github/file_commands\") {") != null);
    try std.testing.expect(std.mem.indexOf(u8, fake.seen.items[6], "loadContainerFromID(id:\"C1\") { rootfs { withoutDirectory(path:\"/github/file_commands\") { withoutDirectory(path:\"/root/.config/go/telemetry\") { changes(from:\"R0\")") != null);
    // Stored under its digest, the layer mounted.
    try std.testing.expect(std.mem.indexOf(u8, fake.seen.items[7], "withMountedDirectory(path:\"/in\",source:\"L\")") != null);
    try std.testing.expect(std.mem.indexOf(u8, fake.seen.items[7], "d=/store/0123abcd;") != null);
    // Matrix jobs share the run's nonce (123.1): the temporary name is the store's own.
    try std.testing.expect(std.mem.indexOf(u8, fake.seen.items[7], ".tmp.123") == null);
    // The next container: the one before the step (with what the runner added for it), the removed
    // path deleted and the content copied in, by digest; the step itself is not part of it.
    const apply = fake.seen.items[8];
    try std.testing.expect(std.mem.startsWith(u8, apply, "{ loadContainerFromID(id:\"B0\") {"));
    try std.testing.expect(std.mem.indexOf(u8, apply, "rm -rf -- '/tmp/it'\\\\''s gone'") != null);
    try std.testing.expect(std.mem.indexOf(u8, apply, "cp -a /zig-runner-outputs/0123abcd/. /") != null);
    try std.testing.expect(std.mem.indexOf(u8, apply, "C1") == null);
    // The next step starts there.
    try std.testing.expect(std.mem.indexOf(u8, fake.seen.items[9], "loadContainerFromID(id:\"N1\")") != null);
}

test "with id-token: write, every step can request OIDC tokens, and so always runs" {
    var a: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer a.deinit();
    const arena = a.allocator();
    var env: std.process.Environ.Map = .init(arena);
    const steps = [_]job_mod.Step{ testStep("one"), testStep("two") };
    for ([_]bool{ true, false }) |granted| {
        var job = testJob(&steps);
        job.secrets = &.{"ghs_jobtoken"};
        job.job_token = "ghs_jobtoken";
        if (granted) job.runtime.id_token_url = "https://token.test/idtoken?api-version=2.0";
        const answers = [_][]const u8{
            base_answer,
            "{\"data\":{\"setSecret\":{\"id\":\"SEC_ID\"}}}", // registered once for the job
            try exec(arena, "C1", 0, ""),
            try exec(arena, "C2", 0, ""),
        };
        var fake: FakeSession = .{ .answers = if (granted) &answers else &.{ answers[0], answers[2], answers[3] }, .arena = arena };
        var buf: [4096]u8 = undefined;
        var w: std.Io.Writer = .fixed(&buf);
        var log: sink.LogSink = .{ .stdout = .{ .writer = &w } };
        const res = try run(arena, std.testing.io, &env, .{ .step_cache = true, .test_session_argv = &.{ "sh", "-c", fake_child }, .test_transport = fake.transport() }, job, &log);
        try std.testing.expect(res.succeeded);
        const seen = fake.seen.items;
        for (seen) |d| try std.testing.expect(braceBalanced(d));
        if (!granted) {
            try std.testing.expectEqual(@as(usize, 3), seen.len);
            for (seen) |d| try std.testing.expect(std.mem.indexOf(u8, d, "ACTIONS_ID_TOKEN") == null);
            continue;
        }
        try std.testing.expectEqual(@as(usize, 4), seen.len);
        try std.testing.expect(std.mem.indexOf(u8, seen[1], "setSecret") != null);
        for ([_][]const u8{ seen[2], seen[3] }) |d| {
            try std.testing.expect(std.mem.indexOf(u8, d, "'ACTIONS_ID_TOKEN_REQUEST_URL=https://token.test/idtoken?api-version=2.0'") != null);
            try std.testing.expect(std.mem.indexOf(u8, d, "withSecretVariable(name:\"ZIG_SECRET_0\",secret:\"SEC_ID\")") != null);
            try std.testing.expect(std.mem.indexOf(u8, d, "'ACTIONS_ID_TOKEN_REQUEST_TOKEN='\\\"$ZIG_SECRET_0\\\"") != null);
            try std.testing.expect(std.mem.indexOf(u8, d, "runs this step every time: it can request OIDC tokens (id-token: write)") != null);
            try std.testing.expect(std.mem.indexOf(u8, d, "ghs_") == null);
        }
    }
}

test "a step is noted as reused only if none of its live lines ever arrived" {
    var buf: [1024]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buf);
    var log: sink.LogSink = .{ .stdout = .{ .writer = &w } };
    var a: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer a.deinit();
    var live = [_]std.atomic.Value(u32){ .init(0), .init(1), .init(0) };
    var ended = [_]std.atomic.Value(bool){ .init(false), .init(false), .init(false) };
    var replayed = [_]bool{ true, true, false };
    var sh: Shared = .{ .io = std.testing.io, .arena = a.allocator(), .log = &log, .sink_job_id = 0, .live_lines = &live, .ended = &ended, .replayed_steps = &replayed };
    // Step 1 was replayed and no live line came: cached. Step 2 was replayed but its (late) live
    // lines arrived: it ran. Step 3 streamed live.
    noteReusedSteps(&sh);
    const got = w.buffered();
    try std.testing.expect(std.mem.indexOf(u8, got, "[job 0 step 1 stdout] Reused from Dagger's cache") != null);
    try std.testing.expect(std.mem.indexOf(u8, got, "step 2") == null);
    try std.testing.expect(std.mem.indexOf(u8, got, "step 3") == null);
}

test "a step that ran but streamed no lines shows its result's output, not as reused" {
    var buf: [1024]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buf);
    var log: sink.LogSink = .{ .stdout = .{ .writer = &w } };
    var a: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer a.deinit();
    var live = [_]std.atomic.Value(u32){ .init(0), .init(0) };
    // Step 1 ended live (its end marker arrived); step 2 did not: it was cached.
    var ended = [_]std.atomic.Value(bool){ .init(true), .init(false) };
    var replayed = [_]bool{ false, false };
    var sh: Shared = .{ .io = std.testing.io, .arena = a.allocator(), .log = &log, .sink_job_id = 0, .live_lines = &live, .ended = &ended, .replayed_steps = &replayed };
    try std.testing.expect(!awaitLiveOrReplay(std.testing.io, &sh, 1, "", "error: Cannot use import statement\n"));
    try std.testing.expect(std.mem.indexOf(u8, w.buffered(), "[job 0 step 1 stdout] error: Cannot use import statement") != null);
    try std.testing.expect(!replayed[0]);
    try std.testing.expect(awaitLiveOrReplay(std.testing.io, &sh, 2, "from cache\n", ""));
    try std.testing.expect(replayed[1]);
}

test "a checkout gets the refs actions/checkout leaves" {
    var a: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer a.deinit();
    const ar = a.allocator();
    const branch = try checkoutRefCommands(ar, "/github/workspace", "refs/heads/main");
    try std.testing.expect(std.mem.indexOf(u8, branch, "g update-ref 'refs/remotes/origin/main' HEAD && g update-ref 'refs/heads/main' HEAD && g symbolic-ref HEAD 'refs/heads/main' && g config 'branch.main.remote' origin && g config 'branch.main.merge' 'refs/heads/main'") != null);
    try std.testing.expect(std.mem.indexOf(u8, try checkoutRefCommands(ar, "/w", "refs/pull/36/merge"), "g update-ref 'refs/remotes/pull/36/merge' HEAD )") != null);
    try std.testing.expect(std.mem.indexOf(u8, try checkoutRefCommands(ar, "/w", "refs/tags/v1"), "g update-ref 'refs/tags/v1' HEAD )") != null);
    try std.testing.expect(std.mem.indexOf(u8, try checkoutRefCommands(ar, "/w", "release"), "g update-ref 'refs/remotes/origin/release' HEAD )") != null);
    // Never fails the step, and only runs where git exists.
    try std.testing.expect(std.mem.startsWith(u8, branch, "if command -v git >/dev/null 2>&1; then ( cd '/github/workspace' && "));
    try std.testing.expect(std.mem.endsWith(u8, branch, ") >/dev/null 2>&1 || true; fi\n"));
}

test "JavaScript pre and post: pre runs first and hands its state on, post-if is honoured, a failing pre fails the job" {
    var a: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer a.deinit();
    const arena = a.allocator();
    var env: std.process.Environ.Map = .init(arena);
    const action_yml =
        \\runs:
        \\  using: node24
        \\  pre: dist/pre.js
        \\  main: dist/main.js
        \\  post: dist/post.js
        \\  post-if: success()
    ;
    const pre_with_state = "{\"data\":{\"loadContainerFromID\":{\"withExec\":{\"id\":\"C1\",\"exitCode\":0,\"stdout\":\"\",\"stderr\":\"\",\"fc_state\":{\"contents\":\"fromPre=1\\n\"}}}}}";
    for ([_]bool{ false, true }) |pre_fails| {
        const steps = [_]job_mod.Step{ usesStep("act", "o", "act", "v1", &.{}), testStep("exit 1") };
        var job = testJob(&steps);
        job.secrets = &.{"ghs_jobtoken"};
        job.job_token = "ghs_jobtoken";
        var answers: std.ArrayList([]const u8) = .empty;
        try answers.appendSlice(arena, &.{
            base_answer,
            try treeAnswer(arena, "D1", &.{ "action.yml", "dist" }),
            try fileAnswer(arena, action_yml),
            "{\"data\":{\"container\":{\"from\":{\"bin\":{\"id\":\"BUN\"}}}}}",
            "{\"data\":{\"setSecret\":{\"id\":\"S1\"}}}",
        });
        if (pre_fails) {
            try answers.append(arena, try exec(arena, "C1", 1, ""));
        } else {
            try answers.appendSlice(arena, &.{
                pre_with_state,
                "{\"data\":{\"setSecret\":{\"id\":\"S2\"}}}",
                try exec(arena, "C2", 0, ""),
                try exec(arena, "C3", 1, ""), // the failing step: success() is false for the post
            });
        }
        var fake: FakeSession = .{ .answers = answers.items, .arena = arena };
        var buf: [4096]u8 = undefined;
        var w: std.Io.Writer = .fixed(&buf);
        var log: sink.LogSink = .{ .stdout = .{ .writer = &w } };
        const res = try run(arena, std.testing.io, &env, .{ .test_session_argv = &.{ "sh", "-c", fake_child }, .test_transport = fake.transport() }, job, &log);
        const seen = fake.seen.items;
        for (seen) |d| try std.testing.expect(braceBalanced(d));
        try std.testing.expect(!res.succeeded);
        try std.testing.expect(std.mem.indexOf(u8, seen[5], "/github/_actions/o/act/v1/dist/pre.js") != null);
        // The pre is a step of its own, logged after the job's two steps.
        try std.testing.expect(std.mem.indexOf(u8, w.buffered(), "##[group]Pre") == null);
        try std.testing.expectEqual(@as(usize, 1), res.extra.len);
        try std.testing.expectEqual(@as(u32, 3), res.extra[0].log_step);
        try std.testing.expect(std.mem.startsWith(u8, res.extra[0].name, "Pre "));
        try std.testing.expectEqual(@as(u32, 4), res.next_log_step);
        if (pre_fails) {
            try std.testing.expectEqual(@as(usize, 6), seen.len);
            try std.testing.expectEqual(Outcome.failure, res.extra[0].outcome);
            try std.testing.expect(std.mem.indexOf(u8, w.buffered(), "[job 0 step 3 stdout] ##[error]Process completed with exit code 1.") != null);
            try std.testing.expectEqual(Outcome.skipped, res.steps[0].outcome);
            try std.testing.expectEqual(Outcome.skipped, res.steps[1].outcome);
        } else {
            // main gets pre's state; no post after the failing step (post-if: success()).
            try std.testing.expectEqual(@as(usize, 9), seen.len);
            try std.testing.expect(std.mem.indexOf(u8, seen[7], "dist/main.js") != null);
            try std.testing.expect(std.mem.indexOf(u8, seen[7], "'STATE_fromPre=1'") != null);
            try std.testing.expectEqual(Outcome.success, res.steps[0].outcome);
            try std.testing.expectEqual(Outcome.failure, res.steps[1].outcome);
            try std.testing.expect(std.mem.indexOf(u8, w.buffered(), "Post o/act") == null);
            try std.testing.expectEqual(Outcome.success, res.extra[0].outcome);
        }
    }
}
