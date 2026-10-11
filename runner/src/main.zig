const std = @import("std");
const Config = @import("config.zig").Config;
const loop = @import("loop.zig");
const inspect = @import("inspect.zig");
const dagger = @import("dagger.zig");
const job_mod = @import("job.zig");
const redact = @import("redact.zig");
const sink = @import("sink.zig");

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
    _ = @import("expr.zig");
    _ = @import("context.zig");
    _ = @import("commands.zig");
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
    var secret_buf: [2][]const u8 = undefined;
    const secrets = cfg.secrets(&secret_buf);

    var out_buf: [4096]u8 = undefined;
    var out_w: std.Io.File.Writer = .init(.stdout(), io, &out_buf);
    var log: sink.LogSink = .{ .stdout = .{ .writer = &out_w.interface, .secrets = secrets } };
    defer log.close();

    var suffix: [4]u8 = undefined;
    io.random(&suffix);
    const name = try std.fmt.allocPrint(arena, "{s}-{x}", .{ cfg.name_prefix, suffix });

    if (cfg.exec_job) |path| return execJobFile(init, &cfg, path, &log, err);

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
