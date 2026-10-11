const std = @import("std");
const Config = @import("config.zig").Config;
const loop = @import("loop.zig");
const inspect = @import("inspect.zig");
const dagger = @import("dagger.zig");
const job_mod = @import("job.zig");
const redact = @import("redact.zig");
const sink = @import("sink.zig");
const DbUrl = @import("db/url.zig");
const DbClient = @import("db/Client.zig");

comptime {
    _ = @import("sink.zig");
    _ = @import("redact.zig");
    _ = @import("config.zig");
    _ = @import("github/jitconfig.zig");
    _ = @import("github/rsa_sign.zig");
    _ = @import("github/auth.zig");
    _ = @import("inspect.zig");
    _ = @import("github/broker.zig");
    _ = @import("github/runservice.zig");
    _ = @import("github/results.zig");
    _ = @import("job.zig");
    _ = @import("dagger.zig");
    _ = @import("loop.zig");
    _ = @import("timefmt.zig");
    _ = @import("db/url.zig");
    _ = @import("db/scram.zig");
    _ = @import("db/Client.zig");
}

const Exit = loop.Exit;

pub fn main(init: std.process.Init) !u8 {
    const arena = init.arena.allocator();
    const io = init.io;

    var err_buf: [1024]u8 = undefined;
    var err_w: std.Io.File.Writer = .init(.stderr(), io, &err_buf);
    const err = &err_w.interface;
    defer err.flush() catch {};

    const args = try init.minimal.args.toSlice(arena);
    const cfg = Config.load(init.environ_map, args) catch |e| {
        try err.print("config error: {s}\n", .{@errorName(e)});
        return @backingInt(Exit.config);
    };
    var secret_buf: [3][]const u8 = undefined;
    var secrets = cfg.secrets(&secret_buf);

    // DATABASE_URL (SPEC §2): a malformed URL is a config error; the password joins the redaction
    // list because it may appear decoded in server messages. The URL itself is never printed.
    var db_url: ?DbUrl.Url = null;
    if (cfg.database_url) |raw| {
        const u = DbUrl.parse(arena, raw) catch |e| {
            try err.print("config error: DATABASE_URL {s}\n", .{@errorName(e)});
            return @backingInt(Exit.config);
        };
        if (u.password.len > 0) {
            secret_buf[secrets.len] = u.password;
            secrets = secret_buf[0 .. secrets.len + 1];
        }
        db_url = u;
    }

    var out_buf: [4096]u8 = undefined;
    var out_w: std.Io.File.Writer = .init(.stdout(), io, &out_buf);
    var log: sink.LogSink = .{ .stdout = .{ .writer = &out_w.interface, .secrets = secrets } };
    defer log.close();

    // With DATABASE_URL set the database must be reachable at startup; otherwise exit 3 (SPEC §2).
    // Without it nothing here runs and the runner behaves as before.
    var db: ?*DbClient = null;
    if (db_url) |u| {
        var detail: ?[]const u8 = null;
        db = DbClient.connect(arena, io, u, .{ .error_detail = &detail }) catch |e| {
            try err.writeAll("database unreachable: ");
            try redact.write(err, @errorName(e), secrets);
            if (detail) |d| {
                try err.writeAll(": ");
                try redact.write(err, d, secrets);
            }
            try err.writeByte('\n');
            return @backingInt(Exit.db);
        };
    }
    defer if (db) |d| d.close();
    const db_versions: ?DbClient.Versions = if (db) |d| try d.versions(arena) else null;

    var suffix: [4]u8 = undefined;
    io.random(&suffix);
    const name = try std.fmt.allocPrint(arena, "{s}-{x}", .{ cfg.name_prefix, suffix });

    if (cfg.exec_job) |path| return execJobFile(init, &cfg, path, &log, err);

    if (cfg.dry_run) {
        try log.append(0, 0, .stdout, try std.fmt.allocPrint(arena, "dry run: would register runner '{s}' with labels '{s}'", .{ name, cfg.labels }));
        if (db_versions) |v| try log.append(0, 0, .stdout, try describeDb(arena, v));
        return @backingInt(Exit.done);
    }

    if (cfg.inspect) {
        if (db_versions) |v| {
            try out_w.interface.print("database: {s}\n", .{try describeDb(arena, v)});
            try out_w.interface.flush();
        }
        // DATABASE_URL alone: the database probe is the whole inspection.
        if (cfg.gh_token.len == 0) return @backingInt(Exit.done);
        const code = try inspect.run(arena, io, &cfg, name, &out_w.interface);
        return code;
    }

    if (db_versions) |v| try log.append(0, 0, .stderr, try describeDb(arena, v));

    return @backingInt(try loop.run(.{
        .arena = arena,
        .io = io,
        .environ = init.environ_map,
        .cfg = &cfg,
        .log = &log,
        .err = err,
        .secrets = secrets,
        .name = name,
    }));
}

/// Dev helper: runs a saved acquirejob response through the Dagger executor.
fn execJobFile(init: std.process.Init, cfg: *const Config, path: []const u8, log: *sink.LogSink, err: *std.Io.Writer) !u8 {
    const arena = init.arena.allocator();
    const io = init.io;
    const json = std.Io.Dir.cwd().readFileAlloc(io, path, arena, .limited(16 * 1024 * 1024)) catch |e| {
        try err.print("cannot read {s}: {s}\n", .{ path, @errorName(e) });
        return @backingInt(Exit.config);
    };
    const job = job_mod.parse(arena, json) catch |e| {
        try err.print("cannot parse job: {s}\n", .{@errorName(e)});
        return @backingInt(Exit.config);
    };
    const res = try dagger.run(arena, io, init.environ_map, .{
        .argv = &.{ cfg.dagger_cmd, "--progress=logs", "query" },
        .sink_job_id = job.check_run_id,
    }, job, log);
    for (res.steps, job.steps, 1..) |r, st, n| {
        try err.print("step {d} [{s}] {s}: {s} (exit {d})\n", .{ n, st.name, @tagName(st.action), @tagName(r.outcome), r.exit_code });
    }
    if (res.engine_error) |m| try err.print("dagger error:\n{s}\n", .{m});
    try err.print("job {s}\n", .{if (res.succeeded) "succeeded" else "failed"});
    return @backingInt(if (res.succeeded) Exit.done else Exit.github);
}

/// "PostgreSQL 17.6, timescaledb 2.17.2": what `--inspect` prints and the runner logs on start.
fn describeDb(arena: std.mem.Allocator, v: DbClient.Versions) ![]const u8 {
    return std.fmt.allocPrint(arena, "PostgreSQL {s}, timescaledb {s}", .{ v.server, v.timescaledb orelse "not installed" });
}
