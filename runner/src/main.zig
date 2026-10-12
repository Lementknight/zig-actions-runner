const std = @import("std");
const Config = @import("config.zig").Config;
const loop = @import("loop.zig");
const inspect = @import("inspect.zig");
const dagger = @import("dagger.zig");
const job_mod = @import("job.zig");
const db = @import("db.zig");
const pg = @import("pg.zig");
const redact = @import("redact.zig");
const sink = @import("sink.zig");

comptime {
    _ = @import("sink.zig");
    _ = @import("redact.zig");
    _ = @import("yaml.zig");
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
    _ = @import("expr.zig");
    _ = @import("context.zig");
    _ = @import("commands.zig");
    _ = @import("pg.zig");
    _ = @import("db.zig");
    _ = @import("pgsink.zig");
    _ = @import("dbtest.zig");
}

const Exit = loop.Exit;

pub fn main(init: std.process.Init) !u8 {
    const arena = init.arena.allocator();
    const io = init.io;

    var err_buf: [1024]u8 = undefined;
    var err_w: std.Io.File.Writer = .initStreaming(.stderr(), io, &err_buf);
    const err = &err_w.interface;
    defer err.flush() catch {};

    const args = try init.minimal.args.toSlice(arena);
    const cfg = Config.load(init.environ_map, args) catch |e| {
        try err.print("config error: {s}\n", .{@errorName(e)});
        return @backingInt(Exit.config);
    };
    var secret_buf: [2][]const u8 = undefined;
    const base_secrets = cfg.secrets(&secret_buf);

    // Where logs and run state go: DATABASE_URL / PG* when set, else stdout only.
    const pg_cfg = cfg.pgConfig(arena, init.environ_map) catch |e| {
        try err.print("config error: invalid database settings ({s})\n", .{@errorName(e)});
        return @backingInt(Exit.config);
    };
    var secrets_list: std.ArrayList([]const u8) = .empty;
    try secrets_list.appendSlice(arena, base_secrets);
    if (pg_cfg) |p| if (p.password.len > 0) try secrets_list.append(arena, p.password);
    const secrets = secrets_list.items;

    var out_buf: [4096]u8 = undefined;
    var out_w: std.Io.File.Writer = .initStreaming(.stdout(), io, &out_buf);
    var console: sink.LogSink = .{ .stdout = .{ .writer = &out_w.interface, .secrets = secrets } };
    defer console.close();

    var db_sink: sink.LogSink = undefined;
    var log: *sink.LogSink = &console;
    var store: ?db.Store = null;
    const live = !cfg.dry_run and !cfg.inspect and cfg.exec_job == null and !cfg.db_check;
    if (pg_cfg) |dbcfg| if (live) {
        store = db.Store.open(init.gpa, io, dbcfg, null) catch |e| {
            try err.writeAll("database unavailable: ");
            try redact.write(err, @errorName(e), secrets);
            try err.writeByte('\n');
            return @backingInt(Exit.db);
        };
        db_sink = .{ .postgres = .{
            .gpa = init.gpa,
            .io = io,
            .cfg = dbcfg,
            .inner = &console,
            .secrets = secrets,
            .flush_lines = cfg.log_flush_lines,
            .flush_ms = cfg.log_flush_ms,
        } };
        try db_sink.postgres.startFlusher();
        log = &db_sink;
    };
    defer if (store != null) {
        log.close();
        store.?.close();
    };

    var suffix: [4]u8 = undefined;
    io.random(&suffix);
    const name = try std.fmt.allocPrint(arena, "{s}-{x}", .{ cfg.name_prefix, suffix });

    if (cfg.db_check) return dbCheck(init, pg_cfg, secrets, &out_w.interface, err);
    if (cfg.exec_job) |path| return execJobFile(init, &cfg, path, log, err);

    if (cfg.dry_run) {
        try log.append(0, 0, .stdout, try std.fmt.allocPrint(arena, "dry run: would register runner '{s}' with labels '{s}'", .{ name, cfg.labels }));
        return @backingInt(Exit.done);
    }

    if (cfg.inspect) {
        const code = try inspect.run(arena, io, &cfg, name, &out_w.interface);
        return code;
    }

    return @backingInt(try loop.run(.{
        .arena = arena,
        .io = io,
        .environ = init.environ_map,
        .cfg = &cfg,
        .log = log,
        .err = err,
        .secrets = secrets,
        .name = name,
        .store = if (store) |*st| st else null,
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
    log.setSecrets(job.secrets);
    const res = try dagger.run(arena, io, init.environ_map, .{
        .dagger_cmd = cfg.dagger_cmd,
        .image = cfg.image,
        .sink_job_id = job.check_run_id,
    }, job, log);
    for (res.steps, job.steps, 1..) |r, st, n| {
        try err.print("step {d} [{s}] {s}: {s} (exit {d})\n", .{ n, st.name, @tagName(st.action), @tagName(r.outcome), r.exit_code });
    }
    if (res.engine_error) |m| try err.print("dagger error:\n{s}\n", .{m});
    try err.print("job {s}\n", .{if (res.succeeded) "succeeded" else "failed"});
    return @backingInt(if (res.succeeded) Exit.done else Exit.github);
}

/// `--db-check`: connect with the configured settings and report what is there. Prints no
/// credentials and no host name (CI logs of public repositories are public).
fn dbCheck(init: std.process.Init, pg_cfg: ?pg.Config, secrets: []const []const u8, out: *std.Io.Writer, err: *std.Io.Writer) !u8 {
    const arena = init.arena.allocator();
    const io = init.io;
    defer out.flush() catch {};

    const cfg = pg_cfg orelse {
        try err.writeAll("no database configured: set DATABASE_URL or PGHOST/PGUSER/PGDATABASE (and PGPASSWORD, PGSSLMODE)\n");
        return @backingInt(Exit.config);
    };
    const c = pg.Client.connect(init.gpa, io, cfg) catch |e| {
        try err.writeAll("database unavailable: ");
        try redact.write(err, @errorName(e), secrets);
        try err.writeByte('\n');
        return @backingInt(Exit.db);
    };
    defer c.close();

    try out.print("connected (TLS {s}, sslmode={s})\n", .{ if (c.tls != null) "on" else "off", @tagName(cfg.sslmode) });
    const version = (try c.query(arena, "select version()"))[0][0] orelse "?";
    try out.print("server: {s}\n", .{version[0 .. std.mem.indexOf(u8, version, " on ") orelse version.len]});
    const ts = try c.query(arena, "select extversion from pg_extension where extname = 'timescaledb'");
    try out.print("timescaledb: {s}\n", .{if (ts.len > 0) ts[0][0].? else "not installed"});

    const tables = try c.query(arena, "select string_agg(tablename, ' ' order by tablename) from pg_tables where schemaname = current_schema() and tablename in ('runs','jobs','steps','job_logs')");
    try out.print("tables in the default schema: {s}\n", .{if (tables.len > 0 and tables[0][0] != null) tables[0][0].? else "none (apply db/migrations/001_init.sql)"});
    if (ts.len > 0) {
        const ht = try c.query(arena, "select count(*) from timescaledb_information.hypertables where hypertable_schema = current_schema() and hypertable_name = 'job_logs'");
        try out.print("job_logs is a hypertable: {s}\n", .{if (std.mem.eql(u8, ht[0][0].?, "1")) "yes" else "no"});
    }
    const leftovers = try c.query(arena, "select count(*) from information_schema.schemata where schema_name like 'zig\\_it\\_%'");
    try out.print("leftover test schemas (zig_it_*): {s}\n", .{leftovers[0][0].?});
    return @backingInt(Exit.done);
}
