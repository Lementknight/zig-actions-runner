//! Runner configuration (SPEC §2). Environment variables, overridden by flags.
const std = @import("std");

pub const Scope = union(enum) {
    repo: struct { owner: []const u8, name: []const u8 },
    org: []const u8,

    pub fn parse(s: []const u8) error{InvalidScope}!Scope {
        if (std.mem.startsWith(u8, s, "org:")) {
            const name = s["org:".len..];
            if (name.len == 0) return error.InvalidScope;
            return .{ .org = name };
        }
        const slash = std.mem.indexOfScalar(u8, s, '/') orelse return error.InvalidScope;
        const owner = s[0..slash];
        const name = s[slash + 1 ..];
        if (owner.len == 0 or name.len == 0 or std.mem.indexOfScalar(u8, name, '/') != null)
            return error.InvalidScope;
        return .{ .repo = .{ .owner = owner, .name = name } };
    }
};

const pg = @import("pg.zig");

pub const JsRuntime = enum { bun, node };
/// Who steps run as in the default image: `runner` (uid 1001, passwordless sudo), as on GitHub's
/// hosted runners, or root.
pub const StepUser = enum { runner, root };
/// How jobs reach the Dagger engine: directly (`engine.zig`), or through a `dagger run` child.
pub const EngineMode = enum { direct, cli };

pub const Config = struct {
    gh_token: []const u8,
    scope: Scope,
    labels: []const u8 = "self-hosted,linux,zig",
    runner_group_id: u64 = 1,
    name_prefix: []const u8 = "zig",
    /// Absent means "log to stdout only" (StdoutSink).
    database_url: ?[]const u8 = null,
    dagger_cmd: []const u8 = "dagger",
    /// Base image for jobs. The default gets git, curl and CA certificates installed (cached by Dagger);
    /// a custom image is used as is.
    image: []const u8 = "ubuntu:24.04",
    log_flush_lines: u32 = 200,
    log_flush_ms: u32 = 500,
    /// What runs JavaScript actions (`runs.using: node*`). Bun by default; Node for exact Node behaviour.
    js_runtime: JsRuntime = .bun,
    engine: EngineMode = .direct,
    /// The engine container `direct` sessions run `buildctl dial-stdio` in.
    engine_container: []const u8 = "dagger-engine-v0.21.10",
    /// The engine's own listener (`tcp://host:port`, `unix:///path`) for `direct` sessions, reached
    /// without the Docker API; empty to go through `engine_container`.
    engine_host: []const u8 = "",
    /// The Docker API socket (from DOCKER_HOST when it is `unix://`).
    docker_socket: []const u8 = "/var/run/docker.sock",
    /// Give each step's commands access to the job's Dagger engine (`experimentalPrivilegedNesting`), so
    /// `dagger call` inside a job works, as dagger/dagger-for-github expects. That access is enough to run
    /// privileged containers, so a job can control the runner's host: turn it off for untrusted workflows.
    dagger_nesting: bool = true,
    /// Mount persistent Dagger cache volumes at package managers' cache directories in every job.
    package_caches: bool = true,
    /// Reuse a step's result from an earlier run when its inputs are unchanged (steps that use secrets
    /// always run). A workflow can opt out with `ZIG_RUNNER_STEP_CACHE: false` in its env.
    step_cache: bool = true,
    /// Who steps run as in the default image (`RUNNER_STEP_USER`).
    step_user: StepUser = .runner,
    /// Experimental: key the steps after one that always runs on what it produced rather than on
    /// the step itself (see `dagger.Options.output_keys`).
    output_keys: bool = false,
    /// Give a step that did not name a run-specific value (`GITHUB_SHA`, `GITHUB_RUN_ID`, the actor,
    /// the refs) a constant instead of the real one, so that a step which reads one indirectly
    /// cannot be replayed with an earlier run's value. On by default, and a deliberate divergence
    /// from GitHub's runner: see SPEC "Where this runner differs from GitHub's".
    enforce_volatile: bool = true,
    /// Put uv's project environment inside its cache volume, so uv can hardlink into it instead of
    /// copying every file (28.6 s against 0.2 s on a Raspberry Pi; see SPEC Â§6 "Package caches").
    /// The workspace gets a `.venv` symlink to it, so paths into `.venv` still work.
    uv_env_in_cache: bool = true,
    /// Output keys cost two walks of the job's filesystem, whatever the step changed: 25 s on a
    /// large checkout against 1 s on a small one (STUDY.md Â§3.6). When a job spends longer than
    /// this on them, later jobs for that repository skip them until the runner restarts. 0 never
    /// skips.
    output_keys_max_ms: u32 = 10_000,
    /// With output keys: days a stored output may go unused before it is removed.
    output_keys_days: u32 = 7,
    dry_run: bool = false,
    /// Stop after one job (or one failed attempt), as an ephemeral runner process. Off by default:
    /// the runner registers again after each job.
    once: bool = false,
    /// Runners in this process, each serving jobs one after another, concurrently with the others.
    runners: u32 = 1,
    /// Connect to the configured database, report what is there, and exit (no GitHub credentials needed).
    db_check: bool = false,
    /// Dev: run a saved acquirejob response through the executor without contacting GitHub.
    exec_job: ?[]const u8 = null,
    /// Register one runner, print the shape of its config, delete it, exit.
    inspect: bool = false,

    pub const Error = error{ MissingGhToken, MissingGhScope, InvalidScope, InvalidNumber, InvalidJsRuntime, InvalidStepUser, InvalidEngine, InvalidBool, UnknownFlag, MissingFlagValue };

    /// Values are borrowed from `environ` / `args`, which must outlive the Config.
    pub fn load(environ: *const std.process.Environ.Map, args: []const [:0]const u8) Error!Config {
        var token: ?[]const u8 = environ.get("GH_TOKEN");
        var scope_str: ?[]const u8 = environ.get("GH_SCOPE");
        var c: Config = .{ .gh_token = "", .scope = undefined };

        if (environ.get("RUNNER_LABELS")) |v| c.labels = v;
        if (environ.get("RUNNER_GROUP_ID")) |v| c.runner_group_id = try num(u64, v);
        if (environ.get("RUNNER_NAME_PREFIX")) |v| c.name_prefix = v;
        if (environ.get("DATABASE_URL")) |v| c.database_url = v;
        if (environ.get("DAGGER_CMD")) |v| c.dagger_cmd = v;
        if (environ.get("RUNNER_IMAGE")) |v| c.image = v;
        if (environ.get("LOG_FLUSH_LINES")) |v| c.log_flush_lines = try num(u32, v);
        if (environ.get("LOG_FLUSH_MS")) |v| c.log_flush_ms = try num(u32, v);
        if (environ.get("RUNNER_JS_RUNTIME")) |v| c.js_runtime = try jsRuntime(v);
        if (environ.get("RUNNER_ENGINE")) |v| c.engine = try engineMode(v);
        if (environ.get("RUNNER_ENGINE_CONTAINER")) |v| c.engine_container = v;
        if (environ.get("RUNNER_ENGINE_HOST")) |v| c.engine_host = v;
        if (environ.get("DOCKER_HOST")) |v| if (std.mem.startsWith(u8, v, "unix://")) {
            c.docker_socket = v["unix://".len..];
        };
        if (environ.get("RUNNER_DAGGER_NESTING")) |v| c.dagger_nesting = try boolean(v);
        if (environ.get("RUNNER_PACKAGE_CACHES")) |v| c.package_caches = try boolean(v);
        if (environ.get("RUNNER_STEP_CACHE")) |v| c.step_cache = try boolean(v);
        if (environ.get("RUNNER_STEP_USER")) |v| c.step_user = try stepUser(v);
        if (environ.get("RUNNER_OUTPUT_KEYS")) |v| c.output_keys = try boolean(v);
        if (environ.get("RUNNER_ENFORCE_VOLATILE")) |v| c.enforce_volatile = try boolean(v);
        if (environ.get("RUNNER_UV_ENV_IN_CACHE")) |v| c.uv_env_in_cache = try boolean(v);
        if (environ.get("RUNNER_OUTPUT_KEYS_MAX_MS")) |v| c.output_keys_max_ms = try millis(v);
        if (environ.get("RUNNER_OUTPUT_KEYS_DAYS")) |v| c.output_keys_days = try count(v);
        if (environ.get("RUNNER_ONCE")) |v| c.once = try boolean(v);
        if (environ.get("RUNNER_COUNT")) |v| c.runners = try count(v);

        var i: usize = 1; // args[0] is the program name
        while (i < args.len) : (i += 1) {
            const arg: []const u8 = args[i];
            if (std.mem.eql(u8, arg, "--db-check")) {
                c.db_check = true;
                continue;
            }
            if (std.mem.eql(u8, arg, "--dry-run")) {
                c.dry_run = true;
                continue;
            }
            if (std.mem.eql(u8, arg, "--inspect")) {
                c.inspect = true;
                continue;
            }
            if (std.mem.eql(u8, arg, "--once")) {
                c.once = true;
                continue;
            }
            if (!std.mem.startsWith(u8, arg, "--")) return error.UnknownFlag;
            var key = arg[2..];
            var val: []const u8 = undefined;
            if (std.mem.indexOfScalar(u8, key, '=')) |eq| {
                val = key[eq + 1 ..];
                key = key[0..eq];
            } else {
                i += 1;
                if (i >= args.len) return error.MissingFlagValue;
                val = args[i];
            }
            if (std.mem.eql(u8, key, "token")) token = val //
            else if (std.mem.eql(u8, key, "scope")) scope_str = val //
            else if (std.mem.eql(u8, key, "exec-job")) c.exec_job = val //
            else if (std.mem.eql(u8, key, "labels")) c.labels = val //
            else if (std.mem.eql(u8, key, "group-id")) c.runner_group_id = try num(u64, val) //
            else if (std.mem.eql(u8, key, "name-prefix")) c.name_prefix = val //
            else if (std.mem.eql(u8, key, "database-url")) c.database_url = val //
            else if (std.mem.eql(u8, key, "dagger-cmd")) c.dagger_cmd = val //
            else if (std.mem.eql(u8, key, "image")) c.image = val //
            else if (std.mem.eql(u8, key, "log-flush-lines")) c.log_flush_lines = try num(u32, val) //
            else if (std.mem.eql(u8, key, "log-flush-ms")) c.log_flush_ms = try num(u32, val) //
            else if (std.mem.eql(u8, key, "js-runtime")) c.js_runtime = try jsRuntime(val) //
            else if (std.mem.eql(u8, key, "engine")) c.engine = try engineMode(val) //
            else if (std.mem.eql(u8, key, "engine-host")) c.engine_host = val //
            else if (std.mem.eql(u8, key, "dagger-nesting")) c.dagger_nesting = try boolean(val) //
            else if (std.mem.eql(u8, key, "package-caches")) c.package_caches = try boolean(val) //
            else if (std.mem.eql(u8, key, "step-cache")) c.step_cache = try boolean(val) //
            else if (std.mem.eql(u8, key, "step-user")) c.step_user = try stepUser(val) //
            else if (std.mem.eql(u8, key, "uv-env-in-cache")) c.uv_env_in_cache = try boolean(val) //
            else if (std.mem.eql(u8, key, "output-keys-max-ms")) c.output_keys_max_ms = try millis(val) //
            else if (std.mem.eql(u8, key, "enforce-volatile")) c.enforce_volatile = try boolean(val) //
            else if (std.mem.eql(u8, key, "output-keys")) c.output_keys = try boolean(val) //
            else if (std.mem.eql(u8, key, "output-keys-days")) c.output_keys_days = try count(val) //
            else if (std.mem.eql(u8, key, "runners")) c.runners = try count(val) //
            else return error.UnknownFlag;
        }

        if (c.exec_job != null or c.db_check) {
            // Offline mode: no GitHub credentials needed.
            c.gh_token = token orelse "";
            c.scope = .{ .org = "offline" };
            return c;
        }
        c.gh_token = token orelse return error.MissingGhToken;
        c.scope = try Scope.parse(scope_str orelse return error.MissingGhScope);
        return c;
    }

    /// Where logs and run state go: `DATABASE_URL` / `--database-url`, else the standard PG* variables.
    /// Null means the runner logs to stdout only (StdoutSink).
    pub fn pgConfig(c: *const Config, arena: std.mem.Allocator, environ: *const std.process.Environ.Map) pg.ParseError!?pg.Config {
        if (c.database_url) |u| return try pg.parseUrl(arena, u);
        return pg.fromEnv(environ);
    }

    /// Secrets that must never appear in output (SPEC §9).
    pub fn secrets(c: *const Config, buf: *[2][]const u8) []const []const u8 {
        buf[0] = c.gh_token;
        var n: usize = 1;
        if (c.database_url) |u| {
            buf[1] = u;
            n = 2;
        }
        return buf[0..n];
    }

    fn engineMode(s: []const u8) error{InvalidEngine}!EngineMode {
        return std.meta.stringToEnum(EngineMode, s) orelse error.InvalidEngine;
    }

    fn stepUser(s: []const u8) error{InvalidStepUser}!StepUser {
        return std.meta.stringToEnum(StepUser, s) orelse error.InvalidStepUser;
    }

    fn jsRuntime(s: []const u8) error{InvalidJsRuntime}!JsRuntime {
        return std.meta.stringToEnum(JsRuntime, s) orelse error.InvalidJsRuntime;
    }

    fn num(comptime T: type, s: []const u8) error{InvalidNumber}!T {
        return std.fmt.parseInt(T, s, 10) catch error.InvalidNumber;
    }

    /// How jobs reach the engine, for `dagger.Options.engine`: null means a `dagger run` child.
    pub fn engineEndpoint(c: *const Config) ?@import("engine.zig").Endpoint {
        return switch (c.engine) {
            .direct => .{ .host = c.engine_host, .docker_socket = c.docker_socket, .container = c.engine_container },
            .cli => null,
        };
    }

    /// Milliseconds, up to an hour; 0 turns the limit off.
    fn millis(s: []const u8) error{InvalidNumber}!u32 {
        const n = try num(u32, s);
        if (n > 3_600_000) return error.InvalidNumber;
        return n;
    }

    /// A runner count: 1 to 1024.
    fn count(s: []const u8) error{InvalidNumber}!u32 {
        const n = try num(u32, s);
        if (n < 1 or n > 1024) return error.InvalidNumber;
        return n;
    }

    fn boolean(s: []const u8) error{InvalidBool}!bool {
        if (std.ascii.eqlIgnoreCase(s, "true") or std.mem.eql(u8, s, "1")) return true;
        if (std.ascii.eqlIgnoreCase(s, "false") or std.mem.eql(u8, s, "0")) return false;
        return error.InvalidBool;
    }
};

test "scope parsing" {
    const r = try Scope.parse("octo/repo");
    try std.testing.expectEqualStrings("octo", r.repo.owner);
    try std.testing.expectEqualStrings("repo", r.repo.name);
    try std.testing.expectEqualStrings("acme", (try Scope.parse("org:acme")).org);
    try std.testing.expectError(error.InvalidScope, Scope.parse("nope"));
    try std.testing.expectError(error.InvalidScope, Scope.parse("org:"));
    try std.testing.expectError(error.InvalidScope, Scope.parse("a/b/c"));
}

test "load: env then flag override" {
    var env: std.process.Environ.Map = .init(std.testing.allocator);
    defer env.deinit();
    try env.put("GH_TOKEN", "t");
    try env.put("GH_SCOPE", "o/r");
    try env.put("LOG_FLUSH_MS", "10");
    const args = [_][:0]const u8{ "runner", "--labels=a,b", "--log-flush-ms", "20", "--dry-run" };
    const c = try Config.load(&env, &args);
    try std.testing.expectEqualStrings("a,b", c.labels);
    try std.testing.expectEqual(@as(u32, 20), c.log_flush_ms);
    try std.testing.expect(c.dry_run);
}

test "load: missing token" {
    var env: std.process.Environ.Map = .init(std.testing.allocator);
    defer env.deinit();
    try env.put("GH_SCOPE", "o/r");
    try std.testing.expectError(error.MissingGhToken, Config.load(&env, &.{"runner"}));
}

test "RUNNER_ENGINE, RUNNER_ENGINE_CONTAINER and DOCKER_HOST" {
    var env: std.process.Environ.Map = .init(std.testing.allocator);
    defer env.deinit();
    try env.put("GH_TOKEN", "t");
    try env.put("GH_SCOPE", "o/r");
    const d = try Config.load(&env, &.{"runner"});
    try std.testing.expectEqual(EngineMode.direct, d.engine);
    try std.testing.expectEqualStrings("/var/run/docker.sock", d.docker_socket);
    try env.put("DOCKER_HOST", "unix:///run/user/1000/docker.sock");
    try env.put("RUNNER_ENGINE_CONTAINER", "dagger-engine-custom");
    const c = try Config.load(&env, &.{ "runner", "--engine=cli" });
    try std.testing.expectEqual(EngineMode.cli, c.engine);
    try std.testing.expectEqualStrings("/run/user/1000/docker.sock", c.docker_socket);
    try std.testing.expectEqualStrings("dagger-engine-custom", c.engine_container);
    try std.testing.expectError(error.InvalidEngine, Config.load(&env, &.{ "runner", "--engine=go" }));
    try env.put("RUNNER_ENGINE_HOST", "tcp://dagger-engine:1234");
    try std.testing.expectEqualStrings("tcp://dagger-engine:1234", (try Config.load(&env, &.{"runner"})).engineEndpoint().?.host);
}

test "--runners and RUNNER_COUNT" {
    var env: std.process.Environ.Map = .init(std.testing.allocator);
    defer env.deinit();
    try env.put("GH_TOKEN", "t");
    try env.put("GH_SCOPE", "o/r");
    try std.testing.expectEqual(@as(u32, 1), (try Config.load(&env, &.{"runner"})).runners);
    try env.put("RUNNER_COUNT", "8");
    try std.testing.expectEqual(@as(u32, 8), (try Config.load(&env, &.{"runner"})).runners);
    try std.testing.expectEqual(@as(u32, 20), (try Config.load(&env, &.{ "runner", "--runners=20" })).runners);
    try std.testing.expectError(error.InvalidNumber, Config.load(&env, &.{ "runner", "--runners", "0" }));
    try std.testing.expect((try Config.load(&env, &.{ "runner", "--once" })).once);
}

test "--db-check needs no GitHub credentials" {
    var env: std.process.Environ.Map = .init(std.testing.allocator);
    defer env.deinit();
    const c = try Config.load(&env, &.{ "runner", "--db-check" });
    try std.testing.expect(c.db_check);
}

test "JavaScript actions run on Bun unless Node is asked for" {
    var env: std.process.Environ.Map = .init(std.testing.allocator);
    defer env.deinit();
    try env.put("GH_TOKEN", "t");
    try env.put("GH_SCOPE", "o/r");
    try std.testing.expectEqual(JsRuntime.bun, (try Config.load(&env, &.{"runner"})).js_runtime);
    try env.put("RUNNER_JS_RUNTIME", "node");
    try std.testing.expectEqual(JsRuntime.node, (try Config.load(&env, &.{"runner"})).js_runtime);
    try std.testing.expectEqual(JsRuntime.bun, (try Config.load(&env, &.{ "runner", "--js-runtime=bun" })).js_runtime);
    try env.put("RUNNER_JS_RUNTIME", "deno");
    try std.testing.expectError(error.InvalidJsRuntime, Config.load(&env, &.{"runner"}));
}

test "the output-keys limit: milliseconds, and 0 turns it off" {
    var env: std.process.Environ.Map = .init(std.testing.allocator);
    defer env.deinit();
    try env.put("GH_TOKEN", "t");
    try env.put("GH_SCOPE", "o/r");
    try std.testing.expect((try Config.load(&env, &.{"runner"})).enforce_volatile);
    try env.put("RUNNER_ENFORCE_VOLATILE", "false");
    try std.testing.expect(!(try Config.load(&env, &.{"runner"})).enforce_volatile);
    try std.testing.expect((try Config.load(&env, &.{ "runner", "--enforce-volatile=true" })).enforce_volatile);
    try std.testing.expectEqual(@as(u32, 10_000), (try Config.load(&env, &.{"runner"})).output_keys_max_ms);
    try env.put("RUNNER_OUTPUT_KEYS_MAX_MS", "0");
    try std.testing.expectEqual(@as(u32, 0), (try Config.load(&env, &.{"runner"})).output_keys_max_ms);
    try env.put("RUNNER_OUTPUT_KEYS_MAX_MS", "4000000"); // over an hour
    try std.testing.expectError(error.InvalidNumber, Config.load(&env, &.{"runner"}));
    // The variable is read before the flags, so a bad one fails whatever the flags say; with a good
    // one, the flag wins.
    try env.put("RUNNER_OUTPUT_KEYS_MAX_MS", "9000");
    try std.testing.expectEqual(@as(u32, 2500), (try Config.load(&env, &.{ "runner", "--output-keys-max-ms=2500" })).output_keys_max_ms);
}

test "dagger nesting is on by default and can be turned off" {
    var env: std.process.Environ.Map = .init(std.testing.allocator);
    defer env.deinit();
    try env.put("GH_TOKEN", "t");
    try env.put("GH_SCOPE", "o/r");
    try std.testing.expect((try Config.load(&env, &.{"runner"})).dagger_nesting);
    try env.put("RUNNER_DAGGER_NESTING", "false");
    try std.testing.expect(!(try Config.load(&env, &.{"runner"})).dagger_nesting);
    try std.testing.expect((try Config.load(&env, &.{ "runner", "--dagger-nesting=true" })).dagger_nesting);
    try env.put("RUNNER_DAGGER_NESTING", "maybe");
    try std.testing.expectError(error.InvalidBool, Config.load(&env, &.{"runner"}));
}

test "package caches are on by default and can be turned off" {
    var env: std.process.Environ.Map = .init(std.testing.allocator);
    defer env.deinit();
    try env.put("GH_TOKEN", "t");
    try env.put("GH_SCOPE", "o/r");
    try std.testing.expect((try Config.load(&env, &.{"runner"})).package_caches);
    try std.testing.expect(!(try Config.load(&env, &.{ "runner", "--package-caches=false" })).package_caches);
    try env.put("RUNNER_PACKAGE_CACHES", "0");
    try std.testing.expect(!(try Config.load(&env, &.{"runner"})).package_caches);
}

test "step caching is on by default and can be turned off" {
    var env: std.process.Environ.Map = .init(std.testing.allocator);
    defer env.deinit();
    try env.put("GH_TOKEN", "t");
    try env.put("GH_SCOPE", "o/r");
    try std.testing.expect((try Config.load(&env, &.{"runner"})).step_cache);
    try std.testing.expect(!(try Config.load(&env, &.{ "runner", "--step-cache=false" })).step_cache);
    try env.put("RUNNER_STEP_CACHE", "false");
    try std.testing.expect(!(try Config.load(&env, &.{"runner"})).step_cache);
}
