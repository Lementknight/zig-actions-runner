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
const http = @import("github/http.zig");
const broker = @import("github/broker.zig");
const engine = @import("engine.zig");
const build_version = @import("version.zig");

comptime {
    _ = @import("sink.zig");
    _ = @import("redact.zig");
    _ = @import("yaml.zig");
    _ = @import("action.zig");
    _ = @import("config.zig");
    _ = @import("github/jitconfig.zig");
    _ = @import("github/rsa_sign.zig");
    _ = @import("github/auth.zig");
    _ = @import("inspect.zig");
    _ = @import("github/broker.zig");
    _ = @import("github/runservice.zig");
    _ = @import("github/results.zig");
    _ = @import("github/feed.zig");
    _ = @import("live.zig");
    _ = @import("job.zig");
    _ = @import("dagger.zig");
    _ = @import("engine.zig");
    _ = @import("hpack.zig");
    _ = @import("loop.zig");
    _ = @import("timefmt.zig");
    _ = @import("expr.zig");
    _ = @import("context.zig");
    _ = @import("commands.zig");
    _ = @import("regex.zig");
    _ = @import("matcher.zig");
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

    // Before the configuration, so that asking which binary this is never needs a token: the
    // question is usually asked of a machine whose behaviour is a surprise, where every other
    // answer is in doubt.
    for (args[1..]) |arg| if (std.mem.eql(u8, arg, "--version")) {
        var out_buf: [256]u8 = undefined;
        var w: std.Io.File.Writer = .initStreaming(.stdout(), io, &out_buf);
        try w.interface.print("zig-runner {s} (runner protocol {s}, Dagger {s})\n", .{ build_version.string, broker.version, engine.client_version });
        try w.interface.flush();
        return @backingInt(Exit.done);
    };

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
    var console: sink.LogSink = .{ .stdout = .{ .writer = &out_w.interface, .secrets = secrets, .io = io } };
    defer console.close();

    var db_sink: sink.LogSink = undefined;
    var log: *sink.LogSink = &console;
    var store: ?db.Store = null;
    const live = !cfg.dry_run and !cfg.inspect and cfg.exec_job == null and !cfg.db_check;
    if (pg_cfg) |dbcfg| if (live) {
        // Dialled once here so a wrong password or a stopped database is in the journal at startup
        // rather than at the first job — but never fatal. The database holds logs and run state,
        // both of which the runner is documented to treat as a logging concern and never as a job
        // failure (SPEC §5.1); refusing to start made an optional subsystem able to take CI down,
        // and with systemd's restart policy it crash-looped with jobs queued behind it. The store
        // and the log sink both dial again as work arrives, so this recovers on its own.
        store = db.Store.open(init.gpa, io, dbcfg, null) catch |e| lazy: {
            try err.writeAll("database unavailable, logging to the console and retrying: ");
            try redact.write(err, @errorName(e), secrets);
            try err.writeByte('\n');
            // Flushed here, not left to the `defer`: this is the first message the runner writes
            // that is followed by the process *continuing*, and without the flush it sat in the
            // buffer for the life of the pool. A warning nobody can read is the silent failure the
            // probe exists to prevent (checked on the Pi: the line was missing from the journal).
            try err.flush();
            break :lazy .init(init.gpa, io, dbcfg, null);
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

    // One HTTP client for every runner (see `github/http.zig`).
    var http_client: std.http.Client = .{ .allocator = init.gpa, .io = io, .write_buffer_size = 16 * 1024 };
    defer http_client.deinit();
    http.shared = &http_client;

    // SIGTERM / SIGINT stop the runners gracefully (see `loop.stop_signals`); a second one exits.
    const act: std.posix.Sigaction = .{ .handler = .{ .handler = onStopSignal }, .mask = std.posix.sigemptyset(), .flags = std.posix.SA.RESTART };
    std.posix.sigaction(.TERM, &act, null);
    std.posix.sigaction(.INT, &act, null);

    return @backingInt(try loop.pool(.{
        .arena = arena,
        .gpa = init.gpa,
        .io = io,
        .environ = init.environ_map,
        .cfg = &cfg,
        .log = log,
        .err = err,
        .secrets = secrets,
        .name = name,
        .store = if (store) |*st| st else null,
    }, cfg.runners));
}

/// Dev helper: runs a saved acquirejob response through the Dagger executor.
fn onStopSignal(_: std.posix.SIG) callconv(.c) void {
    if (loop.stop_signals.fetchAdd(1, .acq_rel) >= 1) std.process.exit(130);
}

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
        .js_runtime = cfg.js_runtime,
        .engine = cfg.engineEndpoint(),
        .gpa = init.gpa,
        .nesting = cfg.dagger_nesting,
        .package_caches = cfg.package_caches,
        .step_cache = cfg.step_cache,
        .step_user = cfg.step_user,
        .output_keys = cfg.output_keys,
        .enforce_volatile = cfg.enforce_volatile,
        .output_keys_days = cfg.output_keys_days,
        .sink_job_id = job.check_run_id,
    }, job, log);
    for (res.steps, job.steps, 1..) |r, st, n| {
        try err.print("step {d} [{s}] {s}: {s} (exit {d})\n", .{ n, st.name, @tagName(st.action), @tagName(r.outcome), r.exit_code });
    }
    // The annotations too: they are what `::error`, `::warning` and the problem matchers produce,
    // they go to GitHub with completejob, and without them printed here there is no way to see from
    // a local replay whether a matcher matched anything.
    for (res.annotations) |a| {
        try err.print("annotation {s}", .{a.an.level});
        if (a.an.file) |f| try err.print(" {s}", .{f});
        if (a.an.line) |l| try err.print(":{s}", .{l});
        if (a.an.col) |c| try err.print(":{s}", .{c});
        if (a.an.title) |t| try err.print(" [{s}]", .{t});
        try err.print(" {s}\n", .{a.an.message});
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
