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
    /// Why the step cannot run. The executor logs this and fails the step.
    unsupported: []const u8,
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
    steps: []const Step,
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
    if (unsupported) |why| {
        action = .{ .unsupported = why };
    } else if (std.mem.eql(u8, reference_type, "script")) {
        action = try parseScript(arena, o.get("inputs"));
        if (action == .script) script_text = action.script.script;
    } else {
        action = .{ .unsupported = try std.fmt.allocPrint(arena, "unsupported step reference type '{s}' (v0 supports run: steps)", .{reference_type}) };
    }

    return .{
        .id = id,
        .name = try displayName(arena, explicitName(o) orelse "", script_text),
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

fn displayName(arena: Allocator, name: []const u8, script: []const u8) Allocator.Error![]const u8 {
    if (name.len > 0 and !std.mem.startsWith(u8, name, "__")) return name;
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
    const cd = root.object.get("contextData") orelse return 0;
    if (cd != .object) return 0;
    const job = cd.object.get("job") orelse return 0;
    if (job != .object) return 0;
    const d = job.object.get("d") orelse return 0;
    if (d != .array) return 0;
    for (d.array.items) |e| {
        if (e != .object) continue;
        const k = e.object.get("k") orelse continue;
        if (k != .string or !std.mem.eql(u8, k.string, "check_run_id")) continue;
        const v = e.object.get("v") orelse return 0;
        return if (v == .integer and v.integer > 0) @intCast(v.integer) else 0;
    }
    return 0;
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
    \\ "variables":{"github_token":{"value":"ghs_secret","isSecret":true},"plain":{"value":"x"}},
    \\ "contextData":{"job":{"t":2,"d":[{"k":"status","v":"success"},{"k":"check_run_id","v":777}]}},
    \\ "resources":{"endpoints":[{"authorization":{"parameters":{"AccessToken":"jobtok"},"scheme":"OAuth"}}]},
    \\ "steps":[
    \\  {"type":"action","reference":{"type":"script"},"id":"s1","contextName":"__run","name":"__run","condition":"success()","continueOnError":null,
    \\   "inputs":{"type":2,"map":[{"Key":{"type":0,"lit":"script"},"Value":{"type":0,"file":1,"line":7,"col":14,"lit":"echo hello && sleep 2 && echo done"}}]}},
    \\  {"type":"action","reference":{"type":"script"},"id":"s2","name":"__run_2","displayNameToken":{"type":0,"lit":"Build"},"condition":"always()","continueOnError":{"type":5,"bool":true},
    \\   "environment":{"type":2,"map":[{"Key":{"lit":"A"},"Value":{"lit":"1"}}]},
    \\   "inputs":{"type":2,"map":[{"Key":{"lit":"script"},"Value":{"lit":"make"}},{"Key":{"lit":"shell"},"Value":{"lit":"bash"}},{"Key":{"lit":"workingDirectory"},"Value":{"lit":"sub"}}]}},
    \\  {"type":"action","reference":{"type":"repository","name":"actions/checkout"},"id":"s3","name":"Checkout","condition":"success()"},
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
    try std.testing.expectEqual(@as(usize, 2), job.secrets.len);
    try std.testing.expectEqualStrings("jobtok", job.secrets[0]);
    try std.testing.expectEqualStrings("ghs_secret", job.secrets[1]);
    try std.testing.expect(!job.has_container);
    try std.testing.expectEqual(@as(usize, 4), job.steps.len);

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

    try std.testing.expect(std.mem.indexOf(u8, job.steps[2].action.unsupported, "repository") != null);
    try std.testing.expect(std.mem.indexOf(u8, job.steps[3].action.unsupported, "expressions") != null);
}

test "malformed job" {
    var a: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer a.deinit();
    try std.testing.expectError(error.MalformedJob, parse(a.allocator(), "{}"));
    try std.testing.expectError(error.MalformedJob, parse(a.allocator(), "not json"));
}
