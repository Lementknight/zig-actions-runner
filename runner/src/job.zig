//! Typed view of the job definition returned by `acquirejob` (SPEC §3, §6).
//!
//! Step inputs use the compact template-token encoding: `{"type":N, ...}` where 0 is a string
//! (`lit`), 1 a sequence (`seq`), 2 a mapping (`map` of `{Key,Value}`), 3 a basic expression
//! (`expr`), 5 a boolean (`bool`), 6 a number (`num`) and 7 null. Only literals are supported
//! in v0; anything else marks the step unsupported so it fails loudly instead of running wrong.
const std = @import("std");

const Allocator = std.mem.Allocator;
const Value = std.json.Value;

pub const EnvVar = struct { name: []const u8, value: []const u8 };

pub const Action = union(enum) {
    script: struct {
        script: []const u8,
        /// `bash`, `sh`, or null for the default.
        shell: ?[]const u8,
        working_directory: ?[]const u8,
    },
    /// `uses: actions/checkout`, replaced by a built-in checkout (Dagger's git support).
    checkout: Checkout,
    /// Why the step cannot run. The executor logs this and fails the step.
    unsupported: []const u8,
};

/// Supported inputs of actions/checkout. Anything else makes the step unsupported.
pub const Checkout = struct {
    /// `owner/name`; null means the workflow's own repository.
    repository: ?[]const u8 = null,
    /// Branch, tag, `refs/...` or full sha; null means the commit that triggered the run.
    ref: ?[]const u8 = null,
    /// Relative directory inside the workspace; null means the workspace root.
    path: ?[]const u8 = null,
    /// Commits to fetch; 0 means full history. The real action's default is 1.
    fetch_depth: u32 = 1,
};

pub const Step = struct {
    id: []const u8,
    /// Display name. GitHub's internal `__run` names are replaced by `Run <first script line>`.
    name: []const u8,
    /// `success()` when the workflow sets no `if:`.
    condition: []const u8,
    continue_on_error: bool,
    env: []const EnvVar,
    action: Action,
};

pub const Job = struct {
    plan_id: []const u8,
    job_id: []const u8,
    /// Job-scoped token required by `completejob` (the runner token is rejected).
    job_token: []const u8,
    /// GitHub's numeric job id (`contextData.job.check_run_id`), 0 when absent. Used as the DB key.
    check_run_id: u64,
    /// `container:` jobs are not supported in v0.
    has_container: bool,
    /// Literal values that must never reach a log: the job token and every variable marked `isSecret`.
    secrets: []const []const u8,
    /// The `github` context values the built-in checkout needs.
    github: Github = .{},
    /// Base URL of the results service (`system.github.results_endpoint`), where logs are uploaded.
    results_endpoint: []const u8 = "",
    /// Run metadata for the `runs` and `jobs` tables (SPEC §3, §4). Null when the definition lacks
    /// it. A null `run_id` means the job still runs but no rows are written for it.
    run_id: ?u64 = null,
    repo: ?[]const u8 = null,
    workflow: ?[]const u8 = null,
    event: ?[]const u8 = null,
    branch: ?[]const u8 = null,
    sha: ?[]const u8 = null,
    /// Job display name (`jobDisplayName`, else `jobName`, else the job's key in the workflow).
    name: []const u8 = "",
    /// The runner's `AgentName` from the JIT config's `.runner` file; set by the job loop.
    runner_name: []const u8 = "",
    steps: []const Step,
};

pub const Github = struct {
    repository: []const u8 = "",
    sha: []const u8 = "",
    ref: []const u8 = "",
    server_url: []const u8 = "https://github.com",
};

pub const Error = error{ MalformedJob, OutOfMemory };

pub fn parse(arena: Allocator, json: []const u8) Error!Job {
    const root = std.json.parseFromSliceLeaky(Value, arena, json, .{}) catch |e| switch (e) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return error.MalformedJob,
    };
    if (root != .object) return error.MalformedJob;

    const steps_v = root.object.get("steps") orelse return error.MalformedJob;
    if (steps_v != .array) return error.MalformedJob;
    const steps = try arena.alloc(Step, steps_v.array.items.len);
    for (steps_v.array.items, steps) |sv, *out| out.* = try parseStep(arena, sv);

    return .{
        .plan_id = path(root, &.{ "plan", "planId" }) orelse return error.MalformedJob,
        .job_id = path(root, &.{"jobId"}) orelse return error.MalformedJob,
        .job_token = jobToken(root) orelse return error.MalformedJob,
        .check_run_id = checkRunId(root),
        .secrets = try collectSecrets(arena, root),
        .results_endpoint = variable(root, "system.github.results_endpoint") orelse "",
        .github = githubContext(root),
        .run_id = runId(root),
        .repo = contextString(root, "github", "repository"),
        .workflow = contextString(root, "github", "workflow"),
        .event = contextString(root, "github", "event_name"),
        .branch = contextString(root, "github", "ref_name"),
        .sha = contextString(root, "github", "sha"),
        .name = jobName(root),
        .has_container = if (root.object.get("jobContainer")) |c| c != .null else false,
        .steps = steps,
    };
}

fn parseStep(arena: Allocator, sv: Value) Error!Step {
    if (sv != .object) return error.MalformedJob;
    const o = sv.object;
    const id = path(sv, &.{"id"}) orelse return error.MalformedJob;
    const condition = path(sv, &.{"condition"}) orelse "success()";

    var env: std.ArrayList(EnvVar) = .empty;
    var unsupported: ?[]const u8 = null;

    if (o.get("environment")) |envv| mapping(arena, envv, &env) catch |e| switch (e) {
        error.OutOfMemory => return error.OutOfMemory,
        error.Unsupported => unsupported = "env value is not a plain string (expressions are not supported yet)",
    };

    const reference_type = path(sv, &.{ "reference", "type" }) orelse "";
    var action: Action = .{ .unsupported = "unsupported step type" };
    var script_text: []const u8 = "";
    var uses_label: []const u8 = "";
    if (unsupported) |why| {
        action = .{ .unsupported = why };
    } else if (std.mem.eql(u8, reference_type, "script")) {
        action = try parseScript(arena, o.get("inputs"));
        if (action == .script) script_text = action.script.script;
    } else if (std.mem.eql(u8, reference_type, "repository")) {
        const uses_name = path(sv, &.{ "reference", "name" }) orelse "";
        const uses_ref = path(sv, &.{ "reference", "ref" }) orelse "";
        uses_label = try std.fmt.allocPrint(arena, "{s}@{s}", .{ uses_name, uses_ref });
        if (std.ascii.eqlIgnoreCase(uses_name, "actions/checkout")) {
            action = try parseCheckout(arena, o.get("inputs"));
        } else {
            action = .{ .unsupported = try std.fmt.allocPrint(arena, "uses: {s} is not supported (v0 supports run: steps and actions/checkout)", .{uses_label}) };
        }
    } else {
        action = .{ .unsupported = try std.fmt.allocPrint(arena, "unsupported step reference type '{s}' (v0 supports run: steps)", .{reference_type}) };
    }

    return .{
        .id = id,
        .name = try displayName(arena, explicitName(o) orelse "", script_text, uses_label),
        .condition = condition,
        .continue_on_error = boolToken(o.get("continueOnError")),
        .env = env.items,
        .action = action,
    };
}

fn parseScript(arena: Allocator, inputs: ?Value) Error!Action {
    const iv = inputs orelse return .{ .unsupported = "run step has no inputs" };
    var kv: std.ArrayList(EnvVar) = .empty;
    mapping(arena, iv, &kv) catch |e| switch (e) {
        error.OutOfMemory => return error.OutOfMemory,
        error.Unsupported => return .{ .unsupported = "run step input is not a plain string (expressions are not supported yet)" },
    };
    var script: ?[]const u8 = null;
    var shell: ?[]const u8 = null;
    var wd: ?[]const u8 = null;
    for (kv.items) |e| {
        if (std.mem.eql(u8, e.name, "script")) script = e.value //
        else if (std.mem.eql(u8, e.name, "shell")) shell = e.value //
        else if (std.mem.eql(u8, e.name, "workingDirectory")) wd = e.value;
    }
    const s = script orelse return .{ .unsupported = "run step has no script" };
    if (shell) |sh| if (!std.mem.eql(u8, sh, "bash") and !std.mem.eql(u8, sh, "sh"))
        return .{ .unsupported = try std.fmt.allocPrint(arena, "unsupported shell '{s}' (v0 supports bash and sh)", .{sh}) };
    return .{ .script = .{ .script = s, .shell = shell, .working_directory = wd } };
}

/// Inputs that change nothing we do (we never persist credentials or run the action's own git).
const ignored_checkout_inputs = [_][]const u8{ "persist-credentials", "token", "clean", "show-progress", "set-safe-directory", "fetch-tags", "filter", "sparse-checkout-cone-mode", "ssh-strict", "ssh-user" };
/// Inputs that are only acceptable when they ask for the default (off) behaviour.
const off_only_checkout_inputs = [_][]const u8{ "submodules", "lfs", "sparse-checkout", "ssh-key", "ssh-known-hosts", "github-server-url" };

fn parseCheckout(arena: Allocator, inputs: ?Value) Error!Action {
    var co: Checkout = .{};
    const iv = inputs orelse return .{ .checkout = co };
    if (iv == .null) return .{ .checkout = co };
    var kv: std.ArrayList(EnvVar) = .empty;
    mapping(arena, iv, &kv) catch |e| switch (e) {
        error.OutOfMemory => return error.OutOfMemory,
        error.Unsupported => return .{ .unsupported = "actions/checkout input is not a plain string (expressions are not supported yet)" },
    };
    for (kv.items) |e| {
        if (std.mem.eql(u8, e.name, "repository")) co.repository = nonEmpty(e.value) //
        else if (std.mem.eql(u8, e.name, "ref")) co.ref = nonEmpty(e.value) //
        else if (std.mem.eql(u8, e.name, "path")) {
            if (nonEmpty(e.value)) |pth| {
                if (std.fs.path.isAbsolute(pth) or std.mem.indexOf(u8, pth, "..") != null)
                    return .{ .unsupported = try std.fmt.allocPrint(arena, "actions/checkout path '{s}' must be relative and stay inside the workspace", .{pth}) };
                co.path = pth;
            }
        } else if (std.mem.eql(u8, e.name, "fetch-depth")) {
            co.fetch_depth = std.fmt.parseInt(u32, e.value, 10) catch
                return .{ .unsupported = try std.fmt.allocPrint(arena, "actions/checkout fetch-depth '{s}' is not a number", .{e.value}) };
        } else if (inList(&ignored_checkout_inputs, e.name)) {
            continue;
        } else if (inList(&off_only_checkout_inputs, e.name)) {
            if (e.value.len > 0 and !std.mem.eql(u8, e.value, "false") and !isDefaultServer(e))
                return .{ .unsupported = try std.fmt.allocPrint(arena, "actions/checkout input '{s}: {s}' is not supported yet", .{ e.name, e.value }) };
        } else {
            return .{ .unsupported = try std.fmt.allocPrint(arena, "unsupported actions/checkout input '{s}'", .{e.name}) };
        }
    }
    return .{ .checkout = co };
}

fn isDefaultServer(e: EnvVar) bool {
    return std.mem.eql(u8, e.name, "github-server-url") and std.mem.eql(u8, std.mem.trimEnd(u8, e.value, "/"), "https://github.com");
}

fn nonEmpty(s: []const u8) ?[]const u8 {
    return if (s.len == 0) null else s;
}

fn inList(list: []const []const u8, name: []const u8) bool {
    for (list) |l| if (std.mem.eql(u8, l, name)) return true;
    return false;
}

/// `contextData.github` is `{t, d:[{k, v}]}` with plain string values.
fn githubContext(root: Value) Github {
    var g: Github = .{};
    g.repository = contextString(root, "github", "repository") orelse "";
    g.sha = contextString(root, "github", "sha") orelse "";
    g.ref = contextString(root, "github", "ref") orelse "";
    if (contextString(root, "github", "server_url")) |u| g.server_url = u;
    return g;
}

/// The `{t, d:[{k, v}]}` dictionary at `contextData.<context>`, or null.
fn contextEntries(root: Value, context: []const u8) ?[]const Value {
    const cd = root.object.get("contextData") orelse return null;
    if (cd != .object) return null;
    const ctx = cd.object.get(context) orelse return null;
    if (ctx != .object) return null;
    const d = ctx.object.get("d") orelse return null;
    return if (d == .array) d.array.items else null;
}

fn contextValue(root: Value, context: []const u8, key: []const u8) ?Value {
    for (contextEntries(root, context) orelse return null) |e| {
        if (e != .object) continue;
        const k = e.object.get("k") orelse continue;
        if (k != .string or !std.mem.eql(u8, k.string, key)) continue;
        return e.object.get("v");
    }
    return null;
}

/// A non-empty string value from a context dictionary; null when missing, empty or not a string.
fn contextString(root: Value, context: []const u8, key: []const u8) ?[]const u8 {
    const v = contextValue(root, context, key) orelse return null;
    return if (v == .string and v.string.len > 0) v.string else null;
}

/// `jobDisplayName`, else `jobName`, else `github.job`, skipping empty values.
fn jobName(root: Value) []const u8 {
    if (nonEmpty(path(root, &.{"jobDisplayName"}) orelse "")) |n| return n;
    if (nonEmpty(path(root, &.{"jobName"}) orelse "")) |n| return n;
    return contextString(root, "github", "job") orelse "job";
}

/// `github.run_id` is a decimal string in the `github` context; a number is accepted too.
fn runId(root: Value) ?u64 {
    const v = contextValue(root, "github", "run_id") orelse return null;
    const id: u64 = switch (v) {
        .string => |s| std.fmt.parseInt(u64, s, 10) catch return null,
        .integer => |i| if (i > 0) @intCast(i) else return null,
        else => return null,
    };
    return if (id > 0) id else null;
}

/// Flattens a mapping token whose keys and values are all string literals.
fn mapping(arena: Allocator, v: Value, out: *std.ArrayList(EnvVar)) error{ OutOfMemory, Unsupported }!void {
    if (tokenType(v) != 2) return error.Unsupported;
    const map = v.object.get("map") orelse return;
    if (map != .array) return error.Unsupported;
    for (map.array.items) |pair| {
        if (pair != .object) return error.Unsupported;
        const k = literal(pair.object.get("Key") orelse return error.Unsupported) orelse return error.Unsupported;
        const val = literal(pair.object.get("Value") orelse return error.Unsupported) orelse return error.Unsupported;
        try out.append(arena, .{ .name = k, .value = val });
    }
}

fn tokenType(v: Value) i64 {
    if (v != .object) return -1;
    const t = v.object.get("type") orelse return 0;
    return if (t == .integer) t.integer else -1;
}

/// String, boolean and number literals as text; null for expressions and containers.
fn literal(v: Value) ?[]const u8 {
    if (v != .object) return null;
    switch (tokenType(v)) {
        0 => {
            const l = v.object.get("lit") orelse return "";
            return if (l == .string) l.string else null;
        },
        5 => {
            const b = v.object.get("bool") orelse return null;
            return if (b == .bool) (if (b.bool) "true" else "false") else null;
        },
        else => return null,
    }
}

fn boolToken(v: ?Value) bool {
    const t = v orelse return false;
    const l = literal(t) orelse return false;
    return std.mem.eql(u8, l, "true");
}

/// The workflow's `name:` arrives as a `displayNameToken` literal; `name` is GitHub's internal `__run`.
fn explicitName(o: std.json.ObjectMap) ?[]const u8 {
    if (o.get("displayNameToken")) |t| if (literal(t)) |l| if (l.len > 0) return l;
    if (o.get("name")) |n| if (n == .string) return n.string;
    return null;
}

fn displayName(arena: Allocator, name: []const u8, script: []const u8, uses_label: []const u8) Allocator.Error![]const u8 {
    if (name.len > 0 and !std.mem.startsWith(u8, name, "__")) return name;
    if (uses_label.len > 0) return std.fmt.allocPrint(arena, "Run {s}", .{uses_label});
    if (script.len == 0) return "Run step";
    const first = std.mem.sliceTo(script, '\n');
    return std.fmt.allocPrint(arena, "Run {s}", .{first});
}

fn path(v: Value, keys: []const []const u8) ?[]const u8 {
    var cur = v;
    for (keys) |k| {
        if (cur != .object) return null;
        cur = cur.object.get(k) orelse return null;
    }
    return if (cur == .string) cur.string else null;
}

fn variable(root: Value, name: []const u8) ?[]const u8 {
    const vars = root.object.get("variables") orelse return null;
    if (vars != .object) return null;
    const v = vars.object.get(name) orelse return null;
    return path(v, &.{"value"});
}

fn collectSecrets(arena: Allocator, root: Value) Allocator.Error![]const []const u8 {
    var out: std.ArrayList([]const u8) = .empty;
    if (jobToken(root)) |t| try out.append(arena, t);
    const vars = root.object.get("variables") orelse return out.items;
    if (vars != .object) return out.items;
    var it = vars.object.iterator();
    while (it.next()) |e| {
        const v = e.value_ptr.*;
        if (v != .object) continue;
        const secret = v.object.get("isSecret") orelse continue;
        if (secret != .bool or !secret.bool) continue;
        if (path(v, &.{"value"})) |val| if (val.len > 0) try out.append(arena, val);
    }
    return out.items;
}

/// `contextData.job` is `{"t":N,"d":[{"k":"check_run_id","v":123},...]}`.
fn checkRunId(root: Value) u64 {
    const v = contextValue(root, "job", "check_run_id") orelse return 0;
    return if (v == .integer and v.integer > 0) @intCast(v.integer) else 0;
}

fn jobToken(root: Value) ?[]const u8 {
    const eps = (root.object.get("resources") orelse return null);
    if (eps != .object) return null;
    const list = eps.object.get("endpoints") orelse return null;
    if (list != .array) return null;
    for (list.array.items) |ep| {
        if (path(ep, &.{ "authorization", "parameters", "AccessToken" })) |t| return t;
    }
    return null;
}

const fixture =
    \\{"plan":{"planId":"plan-1"},"jobId":"job-1","jobContainer":null,
    \\ "variables":{"github_token":{"value":"ghs_secret","isSecret":true},"plain":{"value":"x"},"system.github.results_endpoint":{"value":"https://results.test/"}},
    \\ "contextData":{"job":{"t":2,"d":[{"k":"status","v":"success"},{"k":"check_run_id","v":777}]},"github":{"t":2,"d":[{"k":"repository","v":"o/r"},{"k":"sha","v":"0123456789012345678901234567890123456789"},{"k":"ref","v":"refs/heads/x"},{"k":"event_name","v":"push"}]}},
    \\ "resources":{"endpoints":[{"authorization":{"parameters":{"AccessToken":"jobtok"},"scheme":"OAuth"}}]},
    \\ "steps":[
    \\  {"type":"action","reference":{"type":"script"},"id":"s1","contextName":"__run","name":"__run","condition":"success()","continueOnError":null,
    \\   "inputs":{"type":2,"map":[{"Key":{"type":0,"lit":"script"},"Value":{"type":0,"file":1,"line":7,"col":14,"lit":"echo hello && sleep 2 && echo done"}}]}},
    \\  {"type":"action","reference":{"type":"script"},"id":"s2","name":"__run_2","displayNameToken":{"type":0,"lit":"Build"},"condition":"always()","continueOnError":{"type":5,"bool":true},
    \\   "environment":{"type":2,"map":[{"Key":{"lit":"A"},"Value":{"lit":"1"}}]},
    \\   "inputs":{"type":2,"map":[{"Key":{"lit":"script"},"Value":{"lit":"make"}},{"Key":{"lit":"shell"},"Value":{"lit":"bash"}},{"Key":{"lit":"workingDirectory"},"Value":{"lit":"sub"}}]}},
    \\  {"type":"action","reference":{"type":"repository","name":"actions/checkout","ref":"v4"},"id":"s3","name":"Checkout","condition":"success()",
    \\   "inputs":{"type":2,"map":[{"Key":{"lit":"ref"},"Value":{"lit":"main"}},{"Key":{"lit":"path"},"Value":{"lit":"sub/dir"}},{"Key":{"lit":"fetch-depth"},"Value":{"lit":"0"}},{"Key":{"lit":"persist-credentials"},"Value":{"lit":"false"}}]}},
    \\  {"type":"action","reference":{"type":"repository","name":"actions/checkout","ref":"v4"},"id":"s5","name":"__run_3","condition":"success()"},
    \\  {"type":"action","reference":{"type":"repository","name":"actions/cache","ref":"v4"},"id":"s6","name":"__run_4","condition":"success()"},
    \\  {"type":"action","reference":{"type":"repository","name":"actions/checkout","ref":"v4"},"id":"s7","name":"x","condition":"success()",
    \\   "inputs":{"type":2,"map":[{"Key":{"lit":"submodules"},"Value":{"lit":"recursive"}}]}},
    \\  {"type":"action","reference":{"type":"repository","name":"actions/checkout","ref":"v4"},"id":"s8","name":"y","condition":"success()",
    \\   "inputs":{"type":2,"map":[{"Key":{"lit":"path"},"Value":{"lit":"../escape"}}]}},
    \\  {"type":"action","reference":{"type":"script"},"id":"s4","name":"Expr","condition":"success()",
    \\   "inputs":{"type":2,"map":[{"Key":{"lit":"script"},"Value":{"type":3,"expr":"github.sha"}}]}}
    \\ ]}
;

test "parse job fixture" {
    var a: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer a.deinit();
    const job = try parse(a.allocator(), fixture);
    try std.testing.expectEqualStrings("plan-1", job.plan_id);
    try std.testing.expectEqualStrings("jobtok", job.job_token);
    try std.testing.expectEqual(@as(u64, 777), job.check_run_id);
    try std.testing.expectEqualStrings("https://results.test/", job.results_endpoint);
    try std.testing.expectEqualStrings("o/r", job.github.repository);
    try std.testing.expectEqualStrings("https://github.com", job.github.server_url);
    try std.testing.expectEqual(@as(usize, 2), job.secrets.len);
    try std.testing.expectEqualStrings("jobtok", job.secrets[0]);
    try std.testing.expectEqualStrings("ghs_secret", job.secrets[1]);
    try std.testing.expect(!job.has_container);
    try std.testing.expectEqual(@as(usize, 8), job.steps.len);

    const s1 = job.steps[0];
    try std.testing.expectEqualStrings("Run echo hello && sleep 2 && echo done", s1.name);
    try std.testing.expectEqualStrings("echo hello && sleep 2 && echo done", s1.action.script.script);
    try std.testing.expect(!s1.continue_on_error);

    const s2 = job.steps[1];
    try std.testing.expectEqualStrings("Build", s2.name);
    try std.testing.expectEqualStrings("always()", s2.condition);
    try std.testing.expect(s2.continue_on_error);
    try std.testing.expectEqualStrings("bash", s2.action.script.shell.?);
    try std.testing.expectEqualStrings("sub", s2.action.script.working_directory.?);
    try std.testing.expectEqualStrings("A", s2.env[0].name);

    // checkout with inputs
    const co = job.steps[2].action.checkout;
    try std.testing.expectEqualStrings("main", co.ref.?);
    try std.testing.expectEqualStrings("sub/dir", co.path.?);
    try std.testing.expectEqual(@as(u32, 0), co.fetch_depth);
    try std.testing.expect(co.repository == null);
    // expression in a run step
    try std.testing.expect(std.mem.indexOf(u8, job.steps[7].action.unsupported, "expressions") != null);
    // bare checkout: defaults and a "Run actions/checkout@v4" display name
    try std.testing.expectEqual(@as(u32, 1), job.steps[3].action.checkout.fetch_depth);
    try std.testing.expectEqualStrings("Run actions/checkout@v4", job.steps[3].name);
    // other actions and unsupported checkout inputs fail loudly
    try std.testing.expect(std.mem.indexOf(u8, job.steps[4].action.unsupported, "actions/cache@v4 is not supported") != null);
    try std.testing.expect(std.mem.indexOf(u8, job.steps[5].action.unsupported, "submodules: recursive") != null);
    try std.testing.expect(std.mem.indexOf(u8, job.steps[6].action.unsupported, "inside the workspace") != null);
}

test "malformed job" {
    var a: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer a.deinit();
    try std.testing.expectError(error.MalformedJob, parse(a.allocator(), "{}"));
    try std.testing.expectError(error.MalformedJob, parse(a.allocator(), "not json"));
}

test "run metadata from testdata/job-mixed.json" {
    var a: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer a.deinit();
    const job = try parse(a.allocator(), @embedFile("job-mixed.json"));
    try std.testing.expectEqual(@as(?u64, 18400000042), job.run_id);
    try std.testing.expectEqual(@as(u64, 4242), job.check_run_id);
    try std.testing.expectEqualStrings("Lementknight/zig-actions-runner", job.repo.?);
    try std.testing.expectEqualStrings("CI", job.workflow.?);
    try std.testing.expectEqualStrings("push", job.event.?);
    try std.testing.expectEqualStrings("feature/tiger-db", job.branch.?);
    try std.testing.expectEqualStrings("5dc85102f3a1c0de5dc85102f3a1c0de5dc85102", job.sha.?);
    try std.testing.expectEqualStrings("Build and test", job.name);
    // Set by the job loop from the JIT config, not by the definition.
    try std.testing.expectEqualStrings("", job.runner_name);
}

test "missing run metadata becomes null and the job still parses" {
    var a: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer a.deinit();
    const minimal =
        \\{"plan":{"planId":"p"},"jobId":"j","jobDisplayName":"","jobName":"build",
        \\ "contextData":{"github":{"t":2,"d":[{"k":"repository","v":"o/r"},{"k":"run_id","v":"not-a-number"},{"k":"workflow","v":""}]}},
        \\ "resources":{"endpoints":[{"authorization":{"parameters":{"AccessToken":"t"}}}]},"steps":[]}
    ;
    const job = try parse(a.allocator(), minimal);
    try std.testing.expectEqual(@as(?u64, null), job.run_id);
    try std.testing.expectEqualStrings("o/r", job.repo.?);
    try std.testing.expect(job.workflow == null);
    try std.testing.expect(job.event == null);
    try std.testing.expect(job.branch == null);
    try std.testing.expect(job.sha == null);
    try std.testing.expectEqualStrings("build", job.name);

    // No context data at all: every field null, the name falls back to "job".
    const bare = try parse(a.allocator(),
        \\{"plan":{"planId":"p"},"jobId":"j","resources":{"endpoints":[{"authorization":{"parameters":{"AccessToken":"t"}}}]},"steps":[]}
    );
    try std.testing.expect(bare.run_id == null and bare.repo == null and bare.workflow == null);
    try std.testing.expectEqualStrings("job", bare.name);
}

test "numeric run_id is accepted" {
    var a: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer a.deinit();
    const job = try parse(a.allocator(),
        \\{"plan":{"planId":"p"},"jobId":"j","contextData":{"github":{"t":2,"d":[{"k":"run_id","v":99},{"k":"job","v":"lint"}]}},
        \\ "resources":{"endpoints":[{"authorization":{"parameters":{"AccessToken":"t"}}}]},"steps":[]}
    );
    try std.testing.expectEqual(@as(?u64, 99), job.run_id);
    try std.testing.expectEqualStrings("lint", job.name);
}
