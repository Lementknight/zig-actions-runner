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
    dry_run: bool = false,
    /// Connect to the configured database, report what is there, and exit (no GitHub credentials needed).
    db_check: bool = false,
    /// Dev: run a saved acquirejob response through the executor without contacting GitHub.
    exec_job: ?[]const u8 = null,
    /// Register one runner, print the shape of its config, delete it, exit.
    inspect: bool = false,

    pub const Error = error{ MissingGhToken, MissingGhScope, InvalidScope, InvalidNumber, UnknownFlag, MissingFlagValue };

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

    fn num(comptime T: type, s: []const u8) error{InvalidNumber}!T {
        return std.fmt.parseInt(T, s, 10) catch error.InvalidNumber;
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

test "--db-check needs no GitHub credentials" {
    var env: std.process.Environ.Map = .init(std.testing.allocator);
    defer env.deinit();
    const c = try Config.load(&env, &.{ "runner", "--db-check" });
    try std.testing.expect(c.db_check);
}
