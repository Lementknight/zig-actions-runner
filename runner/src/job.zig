//! Typed view of the job definition returned by `acquirejob` (SPEC §3, §6).
//!
//! Step inputs use the compact template-token encoding: `{"type":N, ...}` where 0 is a string
//! (`lit`), 1 a sequence (`seq`), 2 a mapping (`map` of `{Key,Value}`), 3 a basic expression
//! (`expr`), 5 a boolean (`bool`), 6 a number (`num`) and 7 null. Strings and booleans are literals;
//! a type 3 token is an expression (the server rewrites `echo ${{ github.sha }}` into
//! `format('echo {0}', github.sha)`), kept as a `Template` and evaluated when the step runs.
//! Anything else marks the step unsupported so it fails loudly instead of running wrong.
const std = @import("std");

const Allocator = std.mem.Allocator;
const Value = std.json.Value;

pub const EnvVar = struct { name: []const u8, value: []const u8 };

/// A value that is either fixed or computed from an expression when the step runs.
pub const Template = union(enum) {
    lit: []const u8,
    expr: []const u8,
};

/// A named input or environment variable. The name is always literal.
pub const Input = struct { name: []const u8, value: Template };

pub const Action = union(enum) {
    script: struct {
        script: Template,
        /// `bash`, `sh`, or null for the default.
        shell: ?Template,
        working_directory: ?Template,
    },
    /// `uses: actions/checkout`, replaced by a built-in checkout (Dagger's git support). The raw
    /// inputs are validated and turned into a `Checkout` when the step runs (`checkoutFromInputs`).
    checkout: []const Input,
    /// `uses: owner/repo[/path]@ref` of any other action. The runner reads the action's `action.yml`
    /// when the step runs; `inputs` are the step's `with:` values.
    uses: Uses,
    /// `uses: docker://<image>`: runs the image as a Docker action. `args` and `entrypoint` among the
    /// inputs say how; all inputs also arrive as INPUT_<NAME>.
    docker: struct { image: []const u8, inputs: []const Input = &.{} },
    /// Why the step cannot run. The executor logs this and fails the step.
    unsupported: []const u8,
};

pub const Uses = struct {
    owner: []const u8,
    name: []const u8,
    /// Directory of the action inside its repository; "" for the root.
    path: []const u8 = "",
    ref: []const u8,
    inputs: []const Input = &.{},
    /// `uses: ./path`: an action in the workflow's own repository, read from the workspace; `path`
    /// is relative to it ("" for its root) and `owner`, `name` and `ref` are empty.
    local: bool = false,
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
    /// `fetch-tags`: also fetch the repository's tags.
    fetch_tags: bool = false,
    /// `submodules`: false (actions/checkout's default) leaves each submodule's directory empty.
    /// Dagger's git always fetches them, recursively, so `true` gives nested ones too.
    submodules: bool = false,
};

pub const Step = struct {
    /// GitHub's step id (a GUID), used for log uploads.
    id: []const u8,
    /// The workflow's `id:` (or an internal `__run` name): the key in the `steps` context.
    context_name: []const u8 = "",
    /// Display name. GitHub's internal `__run` names are replaced by `Run <first script line>`.
    name: []const u8,
    /// Set when the workflow's `name:` contains an expression; it overrides `name` when evaluated.
    name_expr: ?[]const u8 = null,
    /// `success()` when the workflow sets no `if:`. An expression.
    condition: []const u8,
    continue_on_error: Template = .{ .lit = "false" },
    /// `timeout-minutes:`, null when the step sets none (GitHub's default is the job's limit, which
    /// GitHub enforces itself by cancelling the job).
    timeout_minutes: ?Template = null,
    env: []const Input = &.{},
    action: Action,
    /// What the step `uses:` as written (`actions/checkout@v4`, `docker://alpine`), for its log
    /// header; "" for `run:` steps.
    uses: []const u8 = "",
};

pub const Job = struct {
    plan_id: []const u8,
    job_id: []const u8,
    /// Job-scoped token required by `completejob` (the runner token is rejected).
    job_token: []const u8,
    /// GitHub's numeric job id (`contextData.job.check_run_id`), 0 when absent. Used as the DB key.
    check_run_id: u64,
    /// The job's name as shown on GitHub (`jobDisplayName`).
    display_name: []const u8 = "",
    /// `container:`: the image every step runs in, with its env and registry credentials (the
    /// message's `jobContainer`, in the same shape as a service; `name` is "job").
    container: ?Service = null,
    /// Set when `container:` could not be read.
    container_error: ?[]const u8 = null,
    /// `services:` (the message's `jobServiceContainers`), in the workflow's order.
    services: []const Service = &.{},
    /// Set when `services:` could not be read (one written as a single expression, say).
    services_error: ?[]const u8 = null,
    /// `system.github.token.permissions`: the GITHUB_TOKEN's permissions as JSON
    /// (`{"Contents":"read",...}`), shown in the "Set up job" log as GitHub's runner does.
    token_permissions: []const u8 = "",
    /// `system.runnerGroupName`.
    runner_group: []const u8 = "",
    /// The job's `outputs:` (the message's `jobOutputs`), evaluated after its steps and sent with
    /// completejob, so later jobs read them as `needs.<job>.outputs.<name>`.
    outputs: []const Input = &.{},
    /// Literal values that must never reach a log: the job token and every variable marked `isSecret`.
    secrets: []const []const u8,
    /// The `secrets` context: user secrets by name (they arrive as variables flagged `isSecret`),
    /// plus `GITHUB_TOKEN`. Values are credentials; never log them.
    secret_vars: []const EnvVar = &.{},
    /// The `github` context values the built-in checkout needs.
    github: Github = .{},
    /// Workflow- and job-level `env`, in order (later entries override earlier ones).
    env: []const Input = &.{},
    /// The job's `contextData` (github, inputs, job, matrix, needs, strategy, vars) as parsed JSON.
    context_data: Value = .null,
    /// Base URL of the results service (`system.github.results_endpoint`), where logs are uploaded.
    results_endpoint: []const u8 = "",
    /// Service URLs JavaScript actions reach through the `ACTIONS_*` variables (cache, artifacts).
    runtime: Runtime = .{},
    steps: []const Step,
};

/// From the `SystemVssConnection` endpoint's `data`, and the `actions_uses_cache_service_v2` variable.
/// A `services:` entry: a container that runs next to the job's steps for the whole job.
pub const Service = struct {
    /// The key under `services:`: the name the steps reach it by, and `job.services.<name>`.
    name: []const u8,
    image: Template,
    env: []const Input = &.{},
    /// As written: `5432:5432`, `6379`, `127.0.0.1:8080:80`, `53/udp`.
    ports: []const Template = &.{},
    /// Docker `create` options as one string (`--health-cmd ...`).
    options: ?Template = null,
    /// For a private registry.
    username: ?Template = null,
    password: ?Template = null,
    volumes: []const Template = &.{},
};

pub const Runtime = struct {
    pipelines_url: []const u8 = "",
    cache_url: []const u8 = "",
    results_url: []const u8 = "",
    id_token_url: []const u8 = "",
    /// The live log feed, a WebSocket (`wss://results-receiver.../_ws/ingest.sock`).
    feed_url: []const u8 = "",
    cache_v2: bool = false,
};

pub const Github = struct {
    repository: []const u8 = "",
    sha: []const u8 = "",
    ref: []const u8 = "",
    server_url: []const u8 = "https://github.com",
    /// For the `runs` and `jobs` rows.
    run_id: []const u8 = "",
    workflow: []const u8 = "",
    event_name: []const u8 = "",
    ref_name: []const u8 = "",
    /// The job's id in the workflow file (`github.job`).
    job: []const u8 = "",
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

    var services: []const Service = &.{};
    var services_error: ?[]const u8 = null;
    if (root.object.get("jobServiceContainers")) |sc| if (sc != .null) {
        services = parseServices(arena, sc) catch |e| switch (e) {
            error.OutOfMemory => return error.OutOfMemory,
            error.Unsupported => blk: {
                services_error = "services: could not be read (written as an expression, or in a form the runner does not know)";
                break :blk &.{};
            },
        };
    };

    var container: ?Service = null;
    var container_error: ?[]const u8 = null;
    if (root.object.get("jobContainer")) |jc| if (jc != .null) {
        container = parseService(arena, "job", jc) catch |e| switch (e) {
            error.OutOfMemory => return error.OutOfMemory,
            error.Unsupported => blk: {
                container_error = "container: could not be read (written as an expression, or in a form the runner does not know)";
                break :blk null;
            },
        };
    };

    return .{
        .plan_id = path(root, &.{ "plan", "planId" }) orelse return error.MalformedJob,
        .job_id = path(root, &.{"jobId"}) orelse return error.MalformedJob,
        .job_token = jobToken(root) orelse return error.MalformedJob,
        .check_run_id = checkRunId(root),
        .secrets = try collectSecrets(arena, root),
        .secret_vars = try collectSecretVars(arena, root),
        .results_endpoint = variable(root, "system.github.results_endpoint") orelse "",
        .runtime = runtime(root),
        .github = github: {
            var g = githubContext(arena, root);
            // GitHub leaves `job` out of the github context. The job's key in the workflow is the
            // `system.github.job` variable (`jobName` is a matrix job's leg, such as "zig").
            if (g.job.len == 0) g.job = variable(root, "system.github.job") orelse path(root, &.{"jobName"}) orelse "";
            break :github g;
        },
        .env = try jobEnv(arena, root),
        .context_data = root.object.get("contextData") orelse .null,
        .display_name = path(root, &.{"jobDisplayName"}) orelse "",
        .container = container,
        .container_error = container_error,
        .services = services,
        .services_error = services_error,
        .token_permissions = variable(root, "system.github.token.permissions") orelse "",
        .outputs = blk: {
            const jo = root.object.get("jobOutputs") orelse break :blk &.{};
            if (jo == .null) break :blk &.{};
            break :blk mappingInputs(arena, jo) catch |e| switch (e) {
                error.OutOfMemory => return error.OutOfMemory,
                error.Unsupported => &.{},
            };
        },
        .runner_group = variable(root, "system.runnerGroupName") orelse "",
        .steps = steps,
    };
}

fn parseStep(arena: Allocator, sv: Value) Error!Step {
    if (sv != .object) return error.MalformedJob;
    const o = sv.object;
    const id = path(sv, &.{"id"}) orelse return error.MalformedJob;
    const condition = path(sv, &.{"condition"}) orelse "success()";

    var env: []const Input = &.{};
    var unsupported: ?[]const u8 = null;
    if (o.get("environment")) |envv| if (envv != .null) {
        env = mappingInputs(arena, envv) catch |e| switch (e) {
            error.OutOfMemory => return error.OutOfMemory,
            error.Unsupported => blk: {
                unsupported = "env must be a mapping of names to strings or expressions";
                break :blk &.{};
            },
        };
    };

    const reference_type = path(sv, &.{ "reference", "type" }) orelse "";
    var action: Action = .{ .unsupported = "unsupported step type" };
    var script_text: []const u8 = "";
    var uses_label: []const u8 = "";
    if (unsupported) |why| {
        action = .{ .unsupported = why };
    } else if (std.mem.eql(u8, reference_type, "script")) {
        action = try parseScript(arena, o.get("inputs"));
        if (action == .script and action.script.script == .lit) script_text = action.script.script.lit;
    } else if (std.mem.eql(u8, reference_type, "repository")) {
        const uses_name = path(sv, &.{ "reference", "name" }) orelse "";
        const uses_ref = path(sv, &.{ "reference", "ref" }) orelse "";
        // As GitHub names the step: the action's directory is part of it (`owner/repo/dir@ref`).
        const uses_path = std.mem.trim(u8, path(sv, &.{ "reference", "path" }) orelse "", "/");
        uses_label = if (uses_path.len > 0)
            try std.fmt.allocPrint(arena, "{s}/{s}@{s}", .{ uses_name, uses_path, uses_ref })
        else
            try std.fmt.allocPrint(arena, "{s}@{s}", .{ uses_name, uses_ref });
        const repo_type = path(sv, &.{ "reference", "repositoryType" }) orelse "GitHub";
        if (std.ascii.eqlIgnoreCase(repo_type, "self")) {
            const local = path(sv, &.{ "reference", "path" }) orelse uses_name;
            uses_label = local;
            action = try parseLocalUses(arena, local, o.get("inputs"));
        } else if (std.ascii.eqlIgnoreCase(uses_name, "actions/checkout")) {
            action = try parseCheckoutInputs(arena, o.get("inputs"));
        } else {
            action = try parseUses(arena, uses_name, path(sv, &.{ "reference", "path" }) orelse "", uses_ref, uses_label, o.get("inputs"));
        }
    } else if (std.mem.eql(u8, reference_type, "containerRegistry")) {
        const raw = path(sv, &.{ "reference", "image" }) orelse "";
        const image = if (std.mem.startsWith(u8, raw, "docker://")) raw["docker://".len..] else raw;
        uses_label = try std.fmt.allocPrint(arena, "docker://{s}", .{image});
        action = if (image.len == 0) .{ .unsupported = "uses: docker:// names no image" } else blk: {
            var kv: []const Input = &.{};
            if (o.get("inputs")) |iv| if (iv != .null) {
                kv = mappingInputs(arena, iv) catch |e| switch (e) {
                    error.OutOfMemory => return error.OutOfMemory,
                    error.Unsupported => break :blk .{ .unsupported = try std.fmt.allocPrint(arena, "uses: {s}: inputs must be strings or expressions", .{uses_label}) },
                };
            };
            break :blk .{ .docker = .{ .image = image, .inputs = kv } };
        };
    } else {
        action = .{ .unsupported = try std.fmt.allocPrint(arena, "unsupported step reference type '{s}' (v0 supports run: steps)", .{reference_type}) };
    }

    var name_expr: ?[]const u8 = null;
    var explicit: ?[]const u8 = null;
    if (o.get("displayNameToken")) |t| if (tokenTemplate(t)) |tpl| switch (tpl) {
        .lit => |l| if (l.len > 0) {
            explicit = l;
        },
        .expr => |e| name_expr = e,
    };
    if (explicit == null and o.get("name") != null and o.get("name").? == .string) explicit = o.get("name").?.string;

    return .{
        .id = id,
        .context_name = path(sv, &.{"contextName"}) orelse "",
        .name = try displayName(arena, explicit orelse "", script_text, uses_label),
        .name_expr = name_expr,
        .condition = condition,
        .continue_on_error = if (o.get("continueOnError")) |c| (tokenTemplate(c) orelse .{ .lit = "false" }) else .{ .lit = "false" },
        .timeout_minutes = if (o.get("timeoutInMinutes")) |t| try numberTemplate(arena, t) else null,
        .env = env,
        .action = action,
        .uses = uses_label,
    };
}

fn parseScript(arena: Allocator, inputs: ?Value) Error!Action {
    const iv = inputs orelse return .{ .unsupported = "run step has no inputs" };
    const kv = mappingInputs(arena, iv) catch |e| switch (e) {
        error.OutOfMemory => return error.OutOfMemory,
        error.Unsupported => return .{ .unsupported = "run step inputs must be strings or expressions" },
    };
    var script: ?Template = null;
    var shell: ?Template = null;
    var wd: ?Template = null;
    for (kv) |e| {
        if (std.mem.eql(u8, e.name, "script")) script = e.value //
        else if (std.mem.eql(u8, e.name, "shell")) shell = e.value //
        else if (std.mem.eql(u8, e.name, "workingDirectory")) wd = e.value;
    }
    const s = script orelse return .{ .unsupported = "run step has no script" };
    // A literal shell is validated now; an expression is validated when the step runs.
    if (shell) |sh| if (sh == .lit and !validShell(sh.lit))
        return .{ .unsupported = try unsupportedShell(arena, sh.lit) };
    return .{ .script = .{ .script = s, .shell = shell, .working_directory = wd } };
}

fn parseUses(arena: Allocator, name: []const u8, ref_path: []const u8, ref: []const u8, label: []const u8, inputs: ?Value) Error!Action {
    // `name` is `owner/repo`, and may carry the action's directory too (`owner/repo/sub/dir`).
    var parts = std.mem.splitScalar(u8, name, '/');
    const owner = parts.next() orelse "";
    const repo = parts.next() orelse "";
    const rest = parts.rest();
    const dir = std.mem.trim(u8, if (ref_path.len > 0) ref_path else rest, "/");
    if (owner.len == 0 or repo.len == 0 or ref.len == 0 or std.mem.indexOf(u8, dir, "..") != null)
        return .{ .unsupported = try std.fmt.allocPrint(arena, "uses: {s} is not a valid action reference", .{label}) };
    var kv: []const Input = &.{};
    if (inputs) |iv| if (iv != .null) {
        kv = mappingInputs(arena, iv) catch |e| switch (e) {
            error.OutOfMemory => return error.OutOfMemory,
            error.Unsupported => return .{ .unsupported = try std.fmt.allocPrint(arena, "uses: {s}: inputs must be strings or expressions", .{label}) },
        };
    };
    return .{ .uses = .{ .owner = owner, .name = repo, .path = dir, .ref = ref, .inputs = kv } };
}

/// The directory of `uses: ./dir`, relative to the workspace ("" for its root); null when it would
/// leave the workspace.
pub fn localActionPath(local: []const u8) ?[]const u8 {
    var dir = std.mem.trim(u8, local, " ");
    while (std.mem.startsWith(u8, dir, "./")) dir = dir[2..];
    dir = std.mem.trim(u8, dir, "/");
    if (std.mem.eql(u8, dir, ".")) dir = "";
    var parts = std.mem.splitScalar(u8, dir, '/');
    while (parts.next()) |seg| if (std.mem.eql(u8, seg, "..")) return null;
    return dir;
}

fn parseLocalUses(arena: Allocator, local: []const u8, inputs: ?Value) Error!Action {
    const dir = localActionPath(local) orelse
        return .{ .unsupported = try std.fmt.allocPrint(arena, "uses: {s}: a local action must be inside the workspace", .{local}) };
    var kv: []const Input = &.{};
    if (inputs) |iv| if (iv != .null) {
        kv = mappingInputs(arena, iv) catch |e| switch (e) {
            error.OutOfMemory => return error.OutOfMemory,
            error.Unsupported => return .{ .unsupported = try std.fmt.allocPrint(arena, "uses: {s}: inputs must be strings or expressions", .{local}) },
        };
    };
    return .{ .uses = .{ .owner = "", .name = "", .path = dir, .ref = "", .inputs = kv, .local = true } };
}

/// `bash`, `sh`, `python`, or a custom command for any of them with `{0}` standing for the script
/// file (`bash -l {0}`, `/bin/bash --login -eo pipefail {0}`, `python3 {0}`), as GitHub accepts them.
pub fn validShell(sh: []const u8) bool {
    if (std.mem.eql(u8, sh, "bash") or std.mem.eql(u8, sh, "sh") or std.mem.eql(u8, sh, "python")) return true;
    if (std.mem.indexOf(u8, sh, "{0}") == null) return false;
    var it = std.mem.tokenizeAny(u8, sh, " \t");
    return isRunnableShell(std.fs.path.basenamePosix(it.next() orelse return false));
}

/// The interpreters a step's script may be handed to. `python3` as well as `python`, because the
/// name GitHub's images provide is not the name every image provides.
fn isRunnableShell(prog: []const u8) bool {
    for ([_][]const u8{ "bash", "sh", "python", "python3" }) |ok|
        if (std.mem.eql(u8, prog, ok)) return true;
    return false;
}

/// Why a shell is refused, for the step's log. The shells of GitHub's Ubuntu runners run here: bash
/// (by far the most used), sh and python. PowerShell is left out on purpose (it needs .NET).
pub fn unsupportedShell(arena: Allocator, sh: []const u8) Allocator.Error![]const u8 {
    var it = std.mem.tokenizeAny(u8, sh, " \t");
    const prog = std.fs.path.basenamePosix(it.next() orelse "");
    const why = if (std.mem.eql(u8, prog, "pwsh") or std.mem.eql(u8, prog, "powershell"))
        "PowerShell is not supported (it needs .NET); use `shell: bash`"
    else if (std.mem.eql(u8, prog, "cmd"))
        "cmd is Windows-only; use `shell: bash`"
    else
        "this runner runs bash, sh and python, the shells of GitHub's Ubuntu runners: use `shell: bash`, `sh`, `python`, or one of their commands with {0} for the script file, such as `bash -l {0}`";
    return std.fmt.allocPrint(arena, "unsupported shell '{s}': {s}", .{ sh, why });
}

fn parseCheckoutInputs(arena: Allocator, inputs: ?Value) Error!Action {
    const iv = inputs orelse return .{ .checkout = &.{} };
    if (iv == .null) return .{ .checkout = &.{} };
    const kv = mappingInputs(arena, iv) catch |e| switch (e) {
        error.OutOfMemory => return error.OutOfMemory,
        error.Unsupported => return .{ .unsupported = "actions/checkout inputs must be strings or expressions" },
    };
    return .{ .checkout = kv };
}

/// Inputs that change nothing we do (we never persist credentials or run the action's own git).
const ignored_checkout_inputs = [_][]const u8{ "persist-credentials", "token", "clean", "show-progress", "set-safe-directory", "filter", "sparse-checkout-cone-mode", "ssh-strict", "ssh-user" };
/// Inputs that are only acceptable when they ask for the default (off) behaviour.
const off_only_checkout_inputs = [_][]const u8{ "lfs", "sparse-checkout", "ssh-key", "ssh-known-hosts", "github-server-url" };

pub const CheckoutResult = union(enum) { ok: Checkout, unsupported: []const u8 };

/// Validates checkout inputs after their expressions were evaluated.
pub fn checkoutFromInputs(arena: Allocator, kv: []const EnvVar) Allocator.Error!CheckoutResult {
    var co: Checkout = .{};
    for (kv) |e| {
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
        } else if (std.mem.eql(u8, e.name, "fetch-tags")) {
            co.fetch_tags = parseBool(e.value) orelse
                return .{ .unsupported = try std.fmt.allocPrint(arena, "actions/checkout fetch-tags '{s}' is not true or false", .{e.value}) };
        } else if (std.mem.eql(u8, e.name, "submodules")) {
            co.submodules = if (e.value.len == 0) false else if (std.ascii.eqlIgnoreCase(e.value, "recursive")) true else parseBool(e.value) orelse
                return .{ .unsupported = try std.fmt.allocPrint(arena, "actions/checkout submodules '{s}' is not true, false or recursive", .{e.value}) };
        } else if (inList(&ignored_checkout_inputs, e.name)) {
            continue;
        } else if (inList(&off_only_checkout_inputs, e.name)) {
            if (e.value.len > 0 and !std.mem.eql(u8, e.value, "false") and !isDefaultServer(e))
                return .{ .unsupported = try std.fmt.allocPrint(arena, "actions/checkout input '{s}: {s}' is not supported yet", .{ e.name, e.value }) };
        } else {
            return .{ .unsupported = try std.fmt.allocPrint(arena, "unsupported actions/checkout input '{s}'", .{e.name}) };
        }
    }
    return .{ .ok = co };
}

fn isDefaultServer(e: EnvVar) bool {
    return std.mem.eql(u8, e.name, "github-server-url") and std.mem.eql(u8, std.mem.trimEnd(u8, e.value, "/"), "https://github.com");
}

/// A boolean input; "" is false, as an unset input is.
fn parseBool(s: []const u8) ?bool {
    if (s.len == 0 or std.ascii.eqlIgnoreCase(s, "false")) return false;
    if (std.ascii.eqlIgnoreCase(s, "true")) return true;
    return null;
}

fn nonEmpty(s: []const u8) ?[]const u8 {
    return if (s.len == 0) null else s;
}

fn inList(list: []const []const u8, name: []const u8) bool {
    for (list) |l| if (std.mem.eql(u8, l, name)) return true;
    return false;
}

/// `contextData.github` is `{t, d:[{k, v}]}` with plain string values.
fn githubContext(arena: Allocator, root: Value) Github {
    var g: Github = .{};
    const cd = root.object.get("contextData") orelse return g;
    if (cd != .object) return g;
    const gh = cd.object.get("github") orelse return g;
    if (gh != .object) return g;
    const d = gh.object.get("d") orelse return g;
    if (d != .array) return g;
    for (d.array.items) |e| {
        if (e != .object) continue;
        const k = e.object.get("k") orelse continue;
        const v = e.object.get("v") orelse continue;
        if (k != .string) continue;
        // run_id and friends may arrive as numbers.
        if (std.mem.eql(u8, k.string, "run_id")) {
            if (v == .string) g.run_id = v.string else if (v == .integer) g.run_id = std.fmt.allocPrint(arena, "{d}", .{v.integer}) catch "";
            continue;
        }
        if (v != .string) continue;
        if (std.mem.eql(u8, k.string, "workflow")) g.workflow = v.string //
        else if (std.mem.eql(u8, k.string, "event_name")) g.event_name = v.string //
        else if (std.mem.eql(u8, k.string, "ref_name")) g.ref_name = v.string //
        else if (std.mem.eql(u8, k.string, "job")) g.job = v.string //
        else if (std.mem.eql(u8, k.string, "repository")) g.repository = v.string //
        else if (std.mem.eql(u8, k.string, "sha")) g.sha = v.string //
        else if (std.mem.eql(u8, k.string, "ref")) g.ref = v.string //
        else if (std.mem.eql(u8, k.string, "server_url") and v.string.len > 0) g.server_url = v.string;
    }
    return g;
}

/// A mapping token as inputs: keys must be literal; values are literals or expressions.
fn mappingInputs(arena: Allocator, v: Value) error{ OutOfMemory, Unsupported }![]const Input {
    if (tokenType(v) != 2) return error.Unsupported;
    var out: std.ArrayList(Input) = .empty;
    const map = v.object.get("map") orelse return out.items;
    if (map != .array) return error.Unsupported;
    for (map.array.items) |pair| {
        if (pair != .object) return error.Unsupported;
        const k = literal(pair.object.get("Key") orelse return error.Unsupported) orelse return error.Unsupported;
        const val = tokenTemplate(pair.object.get("Value") orelse return error.Unsupported) orelse return error.Unsupported;
        try out.append(arena, .{ .name = k, .value = val });
    }
    return out.items;
}

/// `jobServiceContainers`: a mapping of name to a mapping (`image`, `env`, `ports`, `options`,
/// `credentials`, `volumes`), or to just the image.
fn parseServices(arena: Allocator, v: Value) error{ OutOfMemory, Unsupported }![]const Service {
    if (tokenType(v) != 2) return error.Unsupported;
    var out: std.ArrayList(Service) = .empty;
    const map = v.object.get("map") orelse return out.items;
    if (map != .array) return error.Unsupported;
    for (map.array.items) |pair| {
        if (pair != .object) return error.Unsupported;
        const name = literal(pair.object.get("Key") orelse return error.Unsupported) orelse return error.Unsupported;
        try out.append(arena, try parseService(arena, name, pair.object.get("Value") orelse return error.Unsupported));
    }
    return out.items;
}

/// One service, or the job's container: a mapping, or just the image.
fn parseService(arena: Allocator, name: []const u8, body: Value) error{ OutOfMemory, Unsupported }!Service {
    {
        if (tokenTemplate(body)) |image| return .{ .name = name, .image = image };
        if (tokenType(body) != 2) return error.Unsupported;
        var svc: Service = .{ .name = name, .image = .{ .lit = "" } };
        const fields = body.object.get("map") orelse return error.Unsupported;
        if (fields != .array) return error.Unsupported;
        for (fields.array.items) |f| {
            if (f != .object) return error.Unsupported;
            const key = literal(f.object.get("Key") orelse return error.Unsupported) orelse return error.Unsupported;
            const val = f.object.get("Value") orelse return error.Unsupported;
            if (std.mem.eql(u8, key, "image")) {
                svc.image = tokenTemplate(val) orelse return error.Unsupported;
            } else if (std.mem.eql(u8, key, "env")) {
                svc.env = try mappingInputs(arena, val);
            } else if (std.mem.eql(u8, key, "ports")) {
                svc.ports = try sequenceTemplates(arena, val);
            } else if (std.mem.eql(u8, key, "volumes")) {
                svc.volumes = try sequenceTemplates(arena, val);
            } else if (std.mem.eql(u8, key, "options")) {
                svc.options = tokenTemplate(val) orelse return error.Unsupported;
            } else if (std.mem.eql(u8, key, "credentials")) {
                for (try mappingInputs(arena, val)) |c| {
                    if (std.mem.eql(u8, c.name, "username")) svc.username = c.value;
                    if (std.mem.eql(u8, c.name, "password")) svc.password = c.value;
                }
            }
        }
        return svc;
    }
}

/// A sequence token of literals or expressions.
fn sequenceTemplates(arena: Allocator, v: Value) error{ OutOfMemory, Unsupported }![]const Template {
    if (tokenType(v) != 1) return error.Unsupported;
    var out: std.ArrayList(Template) = .empty;
    const seq = v.object.get("seq") orelse return out.items;
    if (seq != .array) return error.Unsupported;
    for (seq.array.items) |item| try out.append(arena, try numberTemplate(arena, item) orelse return error.Unsupported);
    return out.items;
}

/// Workflow- and job-level env: `environmentVariables` is a list of mapping tokens.
fn jobEnv(arena: Allocator, root: Value) Error![]const Input {
    var out: std.ArrayList(Input) = .empty;
    const ev = root.object.get("environmentVariables") orelse return out.items;
    if (ev != .array) return out.items;
    for (ev.array.items) |m| {
        const inputs = mappingInputs(arena, m) catch |e| switch (e) {
            error.OutOfMemory => return error.OutOfMemory,
            error.Unsupported => continue, // an unreadable env block is skipped, not fatal
        };
        try out.appendSlice(arena, inputs);
    }
    return out.items;
}

fn tokenType(v: Value) i64 {
    if (v != .object) return -1;
    const t = v.object.get("type") orelse return 0;
    return if (t == .integer) t.integer else -1;
}

/// String and boolean literals as text; null for expressions, containers and null.
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

/// A literal or an expression token as a `Template`; null for containers and null.
pub fn tokenTemplate(v: Value) ?Template {
    if (literal(v)) |l| return .{ .lit = l };
    if (v == .object and tokenType(v) == 3) {
        const e = v.object.get("expr") orelse return null;
        if (e == .string) return .{ .expr = e.string };
    }
    return null;
}

/// A number token (`{"type":6,"num":1}`, how GitHub sends `timeout-minutes: 1`) as text; other
/// tokens as `tokenTemplate` reads them.
fn numberTemplate(arena: Allocator, v: Value) Allocator.Error!?Template {
    if (v == .object and tokenType(v) == 6) {
        const n = v.object.get("num") orelse return null;
        return .{ .lit = switch (n) {
            .integer => |i| try std.fmt.allocPrint(arena, "{d}", .{i}),
            .float => |f| try std.fmt.allocPrint(arena, "{d}", .{f}),
            else => return null,
        } };
    }
    return tokenTemplate(v);
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

/// User secrets are delivered as variables flagged `isSecret`, named like the secret. GitHub's own
/// bookkeeping variables (`system.*`) are not part of the `secrets` context; `github_token` is
/// exposed as `GITHUB_TOKEN`.
fn collectSecretVars(arena: Allocator, root: Value) Allocator.Error![]const EnvVar {
    var out: std.ArrayList(EnvVar) = .empty;
    const vars = root.object.get("variables") orelse return out.items;
    if (vars != .object) return out.items;
    var it = vars.object.iterator();
    while (it.next()) |e| {
        const v = e.value_ptr.*;
        if (v != .object) continue;
        const secret = v.object.get("isSecret") orelse continue;
        if (secret != .bool or !secret.bool) continue;
        const name = e.key_ptr.*;
        if (std.mem.startsWith(u8, name, "system.")) continue;
        const val = path(v, &.{"value"}) orelse continue;
        try out.append(arena, .{ .name = if (std.mem.eql(u8, name, "github_token")) "GITHUB_TOKEN" else name, .value = val });
    }
    return out.items;
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

fn runtime(root: Value) Runtime {
    var r: Runtime = .{};
    if (variable(root, "actions_uses_cache_service_v2")) |v| r.cache_v2 = std.ascii.eqlIgnoreCase(v, "true");
    const res = root.object.get("resources") orelse return r;
    if (res != .object) return r;
    const eps = res.object.get("endpoints") orelse return r;
    if (eps != .array) return r;
    for (eps.array.items) |ep| {
        if (!std.mem.eql(u8, path(ep, &.{"name"}) orelse "", "SystemVssConnection")) continue;
        r.pipelines_url = path(ep, &.{ "data", "PipelinesServiceUrl" }) orelse path(ep, &.{"url"}) orelse "";
        r.cache_url = path(ep, &.{ "data", "CacheServerUrl" }) orelse "";
        r.results_url = path(ep, &.{ "data", "ResultsServiceUrl" }) orelse "";
        r.id_token_url = path(ep, &.{ "data", "GenerateIdTokenUrl" }) orelse "";
        r.feed_url = path(ep, &.{ "data", "FeedStreamUrl" }) orelse "";
    }
    return r;
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
    \\{"plan":{"planId":"plan-1"},"jobId":"job-1","jobContainer":null,"jobOutputs":{"type":2,"map":[{"Key":{"type":0,"lit":"version"},"Value":{"type":3,"expr":"steps.v.outputs.version"}},{"Key":{"type":0,"lit":"literal"},"Value":{"type":0,"lit":"fixed"}}]},
    \\ "variables":{"system.github.token.permissions":{"value":"{\"Contents\":\"read\"}"},"system.runnerGroupName":{"value":"Default"},"github_token":{"value":"ghs_secret","isSecret":true},"TIGER_HOST":{"value":"db.example","isSecret":true},"system.github.token":{"value":"ghs_secret","isSecret":true},"plain":{"value":"x"},"system.github.results_endpoint":{"value":"https://results.test/"},"actions_uses_cache_service_v2":{"value":"True"}},
    \\ "contextData":{"job":{"t":2,"d":[{"k":"status","v":"success"},{"k":"check_run_id","v":777}]},"github":{"t":2,"d":[{"k":"repository","v":"o/r"},{"k":"sha","v":"0123456789012345678901234567890123456789"},{"k":"ref","v":"refs/heads/x"},{"k":"event_name","v":"push"}]}},
    \\ "resources":{"endpoints":[{"name":"SystemVssConnection","url":"https://pipelines.test/","authorization":{"parameters":{"AccessToken":"jobtok"},"scheme":"OAuth"},
    \\   "data":{"CacheServerUrl":"https://cache.test/","ResultsServiceUrl":"https://results.test/","PipelinesServiceUrl":"https://pipelines.test/x/","GenerateIdTokenUrl":"https://token.test/"}}]},
    \\ "steps":[
    \\  {"type":"action","reference":{"type":"script"},"id":"s1","contextName":"__run","name":"__run","condition":"success()","continueOnError":null,
    \\   "inputs":{"type":2,"map":[{"Key":{"type":0,"lit":"script"},"Value":{"type":0,"file":1,"line":7,"col":14,"lit":"echo hello && sleep 2 && echo done"}}]}},
    \\  {"type":"action","reference":{"type":"script"},"id":"s2","name":"__run_2","displayNameToken":{"type":0,"lit":"Build"},"condition":"always()","continueOnError":{"type":5,"bool":true},"timeoutInMinutes":{"type":6,"num":1},
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
    try std.testing.expectEqualStrings("https://pipelines.test/x/", job.runtime.pipelines_url);
    try std.testing.expectEqualStrings("https://cache.test/", job.runtime.cache_url);
    try std.testing.expectEqualStrings("https://results.test/", job.runtime.results_url);
    try std.testing.expectEqualStrings("https://token.test/", job.runtime.id_token_url);
    try std.testing.expect(job.runtime.cache_v2);
    try std.testing.expectEqualStrings("o/r", job.github.repository);
    try std.testing.expectEqualStrings("https://github.com", job.github.server_url);
    try std.testing.expectEqualStrings("jobtok", job.secrets[0]);
    // The secrets context: user secrets and GITHUB_TOKEN, without GitHub's system.* bookkeeping or plain variables.
    try std.testing.expectEqual(@as(usize, 2), job.secret_vars.len);
    var seen_host = false;
    var seen_token = false;
    for (job.secret_vars) |sv| {
        if (std.mem.eql(u8, sv.name, "TIGER_HOST")) seen_host = std.mem.eql(u8, sv.value, "db.example");
        if (std.mem.eql(u8, sv.name, "GITHUB_TOKEN")) seen_token = std.mem.eql(u8, sv.value, "ghs_secret");
    }
    try std.testing.expect(seen_host and seen_token);
    try std.testing.expect(job.container == null);
    try std.testing.expect(job.services.len == 0);
    try std.testing.expectEqualStrings("{\"Contents\":\"read\"}", job.token_permissions);
    try std.testing.expectEqualStrings("Default", job.runner_group);
    try std.testing.expectEqual(@as(usize, 2), job.outputs.len);
    try std.testing.expectEqualStrings("version", job.outputs[0].name);
    try std.testing.expectEqualStrings("steps.v.outputs.version", job.outputs[0].value.expr);
    try std.testing.expectEqualStrings("fixed", job.outputs[1].value.lit);
    try std.testing.expectEqualStrings("actions/checkout@v4", job.steps[2].uses);
    try std.testing.expectEqualStrings("", job.steps[0].uses);
    try std.testing.expectEqual(@as(usize, 8), job.steps.len);

    const s1 = job.steps[0];
    try std.testing.expectEqualStrings("Run echo hello && sleep 2 && echo done", s1.name);
    try std.testing.expectEqualStrings("echo hello && sleep 2 && echo done", s1.action.script.script.lit);
    try std.testing.expectEqualStrings("false", s1.continue_on_error.lit);
    try std.testing.expect(s1.timeout_minutes == null);

    const s2 = job.steps[1];
    try std.testing.expectEqualStrings("Build", s2.name);
    try std.testing.expectEqualStrings("always()", s2.condition);
    try std.testing.expectEqualStrings("true", s2.continue_on_error.lit);
    try std.testing.expectEqualStrings("1", s2.timeout_minutes.?.lit);
    try std.testing.expectEqualStrings("bash", s2.action.script.shell.?.lit);
    try std.testing.expectEqualStrings("sub", s2.action.script.working_directory.?.lit);
    try std.testing.expectEqualStrings("A", s2.env[0].name);
    try std.testing.expectEqualStrings("1", s2.env[0].value.lit);

    // checkout with inputs (validated once their expressions are evaluated)
    const co = (try checkoutFromInputs(a.allocator(), try litEnv(a.allocator(), job.steps[2].action.checkout))).ok;
    try std.testing.expectEqualStrings("main", co.ref.?);
    try std.testing.expectEqualStrings("sub/dir", co.path.?);
    try std.testing.expectEqual(@as(u32, 0), co.fetch_depth);
    try std.testing.expect(co.repository == null);
    // an expression in a run step is kept as a template
    try std.testing.expectEqualStrings("github.sha", job.steps[7].action.script.script.expr);
    // bare checkout: defaults and a "Run actions/checkout@v4" display name
    const bare = (try checkoutFromInputs(a.allocator(), try litEnv(a.allocator(), job.steps[3].action.checkout))).ok;
    try std.testing.expectEqual(@as(u32, 1), bare.fetch_depth);
    try std.testing.expectEqualStrings("Run actions/checkout@v4", job.steps[3].name);
    // other actions are read from their action.yml when they run; unsupported checkout inputs fail once evaluated
    const cache = job.steps[4].action.uses;
    try std.testing.expectEqualStrings("actions", cache.owner);
    try std.testing.expectEqualStrings("cache", cache.name);
    try std.testing.expectEqualStrings("v4", cache.ref);
    try std.testing.expectEqualStrings("", cache.path);
    // submodules: true and recursive fetch them (Dagger's git always does, recursively); false and
    // the default leave their directories empty, as actions/checkout does
    try std.testing.expect((try checkoutFromInputs(a.allocator(), try litEnv(a.allocator(), job.steps[5].action.checkout))).ok.submodules);
    for ([_][]const u8{ "true", "recursive", "Recursive" }) |v| {
        try std.testing.expect((try checkoutFromInputs(a.allocator(), &.{.{ .name = "submodules", .value = v }})).ok.submodules);
    }
    for ([_][]const u8{ "false", "" }) |v| {
        try std.testing.expect(!(try checkoutFromInputs(a.allocator(), &.{.{ .name = "submodules", .value = v }})).ok.submodules);
    }
    const bad_sub = try checkoutFromInputs(a.allocator(), &.{.{ .name = "submodules", .value = "yes" }});
    try std.testing.expect(std.mem.indexOf(u8, bad_sub.unsupported, "not true, false or recursive") != null);
    try std.testing.expect((try checkoutFromInputs(a.allocator(), &.{.{ .name = "fetch-tags", .value = "true" }})).ok.fetch_tags);
    try std.testing.expect(!(try checkoutFromInputs(a.allocator(), &.{.{ .name = "fetch-tags", .value = "false" }})).ok.fetch_tags);
    try std.testing.expect((try checkoutFromInputs(a.allocator(), &.{.{ .name = "fetch-tags", .value = "maybe" }})) == .unsupported);
    const escape = try checkoutFromInputs(a.allocator(), try litEnv(a.allocator(), job.steps[6].action.checkout));
    try std.testing.expect(std.mem.indexOf(u8, escape.unsupported, "inside the workspace") != null);
}

fn litEnv(arena: Allocator, inputs: []const Input) ![]const EnvVar {
    const out = try arena.alloc(EnvVar, inputs.len);
    for (inputs, out) |in, *o| o.* = .{ .name = in.name, .value = in.value.lit };
    return out;
}

test "expressions are kept as templates: step name, env, inputs, condition, job env and contexts" {
    var a: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer a.deinit();
    const json =
        \\{"plan":{"planId":"p"},"jobId":"j","resources":{"endpoints":[{"authorization":{"parameters":{"AccessToken":"t"}}}]},
        \\ "environmentVariables":[{"type":2,"map":[{"Key":{"lit":"W"},"Value":{"lit":"w"}}]},{"type":2,"map":[{"Key":{"lit":"J"},"Value":{"type":3,"expr":"format('{0}-job', github.ref_name)"}}]}],
        \\ "contextData":{"matrix":null,"github":{"t":2,"d":[{"k":"ref_name","v":"main"}]}},
        \\ "steps":[{"type":"action","reference":{"type":"script"},"id":"g","contextName":"first","name":"first",
        \\   "displayNameToken":{"type":3,"expr":"format('Build {0}', github.ref_name)"},
        \\   "condition":"success() && (github.ref == 'x')","continueOnError":{"type":3,"expr":"github.event_name == 'push'"},"timeoutInMinutes":{"type":3,"expr":"inputs.limit"},
        \\   "environment":{"type":2,"map":[{"Key":{"lit":"STEP_ENV"},"Value":{"type":3,"expr":"github.sha"}}]},
        \\   "inputs":{"type":2,"map":[{"Key":{"lit":"script"},"Value":{"type":3,"expr":"format('echo {0}', github.sha)"}}]}}]}
    ;
    const job = try parse(a.allocator(), json);
    const s = job.steps[0];
    try std.testing.expectEqualStrings("first", s.context_name);
    try std.testing.expectEqualStrings("format('Build {0}', github.ref_name)", s.name_expr.?);
    try std.testing.expectEqualStrings("success() && (github.ref == 'x')", s.condition);
    try std.testing.expectEqualStrings("github.event_name == 'push'", s.continue_on_error.expr);
    try std.testing.expectEqualStrings("inputs.limit", s.timeout_minutes.?.expr);
    try std.testing.expectEqualStrings("github.sha", s.env[0].value.expr);
    try std.testing.expectEqualStrings("format('echo {0}', github.sha)", s.action.script.script.expr);
    try std.testing.expectEqual(@as(usize, 2), job.env.len);
    try std.testing.expectEqualStrings("w", job.env[0].value.lit);
    try std.testing.expectEqualStrings("format('{0}-job', github.ref_name)", job.env[1].value.expr);
    try std.testing.expect(job.context_data == .object);
}

test "services: arrive as jobServiceContainers" {
    var a: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer a.deinit();
    // As GitHub sent it (verified live; file/line/col fields trimmed).
    const json =
        \\{"plan":{"planId":"p"},"jobId":"j","resources":{"endpoints":[{"authorization":{"parameters":{"AccessToken":"t"}}}]},
        \\ "jobServiceContainers":{"type":2,"map":[
        \\  {"Key":{"type":0,"lit":"postgres"},"Value":{"type":2,"map":[
        \\    {"Key":{"type":0,"lit":"image"},"Value":{"type":0,"lit":"postgres:17"}},
        \\    {"Key":{"type":0,"lit":"env"},"Value":{"type":2,"map":[{"Key":{"type":0,"lit":"POSTGRES_PASSWORD"},"Value":{"type":3,"expr":"secrets.PG"}}]}},
        \\    {"Key":{"type":0,"lit":"ports"},"Value":{"type":1,"seq":[{"type":0,"lit":"5432:5432"}]}},
        \\    {"Key":{"type":0,"lit":"options"},"Value":{"type":0,"lit":"--health-cmd \"pg_isready\""}}]}},
        \\  {"Key":{"type":0,"lit":"redis"},"Value":{"type":0,"lit":"redis:7"}}]},
        \\ "steps":[]}
    ;
    const job = try parse(a.allocator(), json);
    try std.testing.expectEqual(@as(usize, 2), job.services.len);
    const pg = job.services[0];
    try std.testing.expectEqualStrings("postgres", pg.name);
    try std.testing.expectEqualStrings("postgres:17", pg.image.lit);
    try std.testing.expectEqualStrings("secrets.PG", pg.env[0].value.expr);
    try std.testing.expectEqualStrings("5432:5432", pg.ports[0].lit);
    try std.testing.expectEqualStrings("--health-cmd \"pg_isready\"", pg.options.?.lit);
    try std.testing.expectEqualStrings("redis:7", job.services[1].image.lit);
    try std.testing.expect(job.services_error == null);
    try std.testing.expect(job.container == null);
}

test "container: arrives as jobContainer, a mapping or just the image" {
    var a: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer a.deinit();
    const head = "{\"plan\":{\"planId\":\"p\"},\"jobId\":\"j\",\"resources\":{\"endpoints\":[{\"authorization\":{\"parameters\":{\"AccessToken\":\"t\"}}}]},\"steps\":[],";
    const mapped = try parse(a.allocator(), head ++
        \\"jobContainer":{"type":2,"map":[{"Key":{"type":0,"lit":"image"},"Value":{"type":3,"expr":"matrix.image"}},
        \\ {"Key":{"type":0,"lit":"env"},"Value":{"type":2,"map":[{"Key":{"type":0,"lit":"NODE_ENV"},"Value":{"type":0,"lit":"test"}}]}}]}}
    );
    try std.testing.expectEqualStrings("matrix.image", mapped.container.?.image.expr);
    try std.testing.expectEqualStrings("NODE_ENV", mapped.container.?.env[0].name);
    const short = try parse(a.allocator(), head ++ "\"jobContainer\":{\"type\":0,\"lit\":\"node:22\"}}");
    try std.testing.expectEqualStrings("node:22", short.container.?.image.lit);
    try std.testing.expect(short.container_error == null);
}

test "github.job comes from system.github.job when the context leaves it out" {
    var a: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer a.deinit();
    const job = try parse(a.allocator(),
        \\{"plan":{"planId":"p"},"jobId":"j","jobName":"zig","jobDisplayName":"which-job (zig)","resources":{"endpoints":[{"authorization":{"parameters":{"AccessToken":"t"}}}]},
        \\ "variables":{"system.github.job":{"value":"which-job"}},
        \\ "contextData":{"github":{"t":2,"d":[{"k":"repository","v":"o/r"}]}},"steps":[]}
    );
    // As seen live for a matrix job: the key is the variable, not the leg in jobName.
    try std.testing.expectEqualStrings("which-job", job.github.job);
}

test "malformed job" {
    var a: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer a.deinit();
    try std.testing.expectError(error.MalformedJob, parse(a.allocator(), "{}"));
    try std.testing.expectError(error.MalformedJob, parse(a.allocator(), "not json"));
}

test "unsupportedShell says why" {
    var a: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer a.deinit();
    try std.testing.expectEqualStrings("unsupported shell 'pwsh': PowerShell is not supported (it needs .NET); use `shell: bash`", try unsupportedShell(a.allocator(), "pwsh"));
    try std.testing.expect(std.mem.indexOf(u8, try unsupportedShell(a.allocator(), "powershell -command {0}"), "needs .NET") != null);
    try std.testing.expect(std.mem.indexOf(u8, try unsupportedShell(a.allocator(), "cmd"), "Windows-only") != null);
    // A shell nobody recognises is told what does run, which now includes python.
    try std.testing.expect(std.mem.indexOf(u8, try unsupportedShell(a.allocator(), "fish"), "bash, sh and python") != null);
}

test "validShell: bash, sh, python, and custom commands for them with {0}" {
    for ([_][]const u8{ "bash", "sh", "python", "bash -l {0}", "/bin/bash --login -eo pipefail {0}", "sh -x {0}", "python {0}", "python3 {0}", "/usr/bin/python3 {0}" }) |ok|
        try std.testing.expect(validShell(ok));
    // `pwsh` is a non-goal (it needs .NET) and a bare command without {0} is not a template.
    for ([_][]const u8{ "pwsh", "powershell", "cmd", "bash -l", "node {0}", "ruby {0}", "" }) |bad|
        try std.testing.expect(!validShell(bad));
}

test "uses: references keep their directory and inputs; local actions; docker:// images" {
    var a: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer a.deinit();
    const json =
        \\{"plan":{"planId":"p"},"jobId":"j","resources":{"endpoints":[{"authorization":{"parameters":{"AccessToken":"t"}}}]},
        \\ "steps":[
        \\  {"type":"action","reference":{"type":"repository","name":"github/codeql-action","ref":"v3","path":"init","repositoryType":"GitHub"},"id":"a","name":"__a","condition":"success()",
        \\   "inputs":{"type":2,"map":[{"Key":{"lit":"languages"},"Value":{"lit":"go"}},{"Key":{"lit":"token"},"Value":{"type":3,"expr":"github.token"}}]}},
        \\  {"type":"action","reference":{"type":"repository","name":"o/r/sub/dir","ref":"main","repositoryType":"GitHub"},"id":"b","name":"__b","condition":"success()"},
        \\  {"type":"action","reference":{"type":"repository","path":"./.github/actions/local","repositoryType":"self"},"id":"c","name":"__c","condition":"success()"},
        \\  {"type":"action","reference":{"type":"repository","name":"o/r","ref":"v1","repositoryType":"GitHub"},"id":"d","name":"__d","condition":"success()",
        \\   "inputs":{"type":2,"map":[{"Key":{"lit":"list"},"Value":{"type":1,"seq":[]}}]}},
        \\  {"type":"action","reference":{"type":"containerRegistry","image":"docker://alpine:3.22"},"id":"e","name":"__e","condition":"success()",
        \\   "inputs":{"type":2,"map":[{"Key":{"lit":"args"},"Value":{"lit":"-c 'echo hi'"}},{"Key":{"lit":"entrypoint"},"Value":{"lit":"sh"}}]}}
        \\ ]}
    ;
    const job = try parse(a.allocator(), json);
    const codeql = job.steps[0].action.uses;
    try std.testing.expectEqualStrings("github", codeql.owner);
    try std.testing.expectEqualStrings("codeql-action", codeql.name);
    try std.testing.expectEqualStrings("init", codeql.path);
    try std.testing.expectEqualStrings("go", codeql.inputs[0].value.lit);
    try std.testing.expectEqualStrings("github.token", codeql.inputs[1].value.expr);
    try std.testing.expectEqualStrings("Run github/codeql-action/init@v3", job.steps[0].name);
    try std.testing.expectEqualStrings("sub/dir", job.steps[1].action.uses.path);
    const local = job.steps[2].action.uses;
    try std.testing.expect(local.local);
    try std.testing.expectEqualStrings(".github/actions/local", local.path);
    try std.testing.expectEqualStrings("Run ./.github/actions/local", job.steps[2].name);
    try std.testing.expect(std.mem.indexOf(u8, job.steps[3].action.unsupported, "inputs must be strings or expressions") != null);
    const docker = job.steps[4].action.docker;
    try std.testing.expectEqualStrings("alpine:3.22", docker.image);
    try std.testing.expectEqualStrings("args", docker.inputs[0].name);
    try std.testing.expectEqualStrings("Run docker://alpine:3.22", job.steps[4].name);
}
