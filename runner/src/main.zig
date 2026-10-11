const std = @import("std");
const Config = @import("config.zig").Config;
const jitconfig = @import("github/jitconfig.zig");
const inspect = @import("inspect.zig");
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
}

/// SPEC §2 exit codes.
const Exit = enum(u8) { done = 0, config = 1, github = 2, db = 3 };

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

    if (cfg.dry_run) {
        try log.append(0, 0, .stdout, try std.fmt.allocPrint(arena, "dry run: would register runner '{s}' with labels '{s}'", .{ name, cfg.labels }));
        return @backingInt(Exit.done);
    }

    if (cfg.inspect) {
        const code = try inspect.run(arena, io, &cfg, name, &out_w.interface);
        return code;
    }

    var status: std.http.Status = .ok;
    const jit = jitconfig.generate(arena, io, &cfg, name, &status) catch |e| {
        try err.writeAll("github error: ");
        try redact.write(err, @errorName(e), secrets);
        try err.print(" (HTTP {d})\n", .{@backingInt(status)});
        return @backingInt(Exit.github);
    };

    // Never print file contents: they hold RSA keys and OAuth credentials.
    try log.append(0, 0, .stdout, try std.fmt.allocPrint(arena, "registered runner '{s}' (id {d}) with {d} config files", .{ jit.runner_name, jit.runner_id, jit.files.len }));
    for (jit.files) |f| {
        try log.append(0, 0, .stdout, try std.fmt.allocPrint(arena, "  {s} ({d} bytes)", .{ f.name, f.content.len }));
    }
    try err.writeAll("broker session not implemented yet (M2); exiting\n");
    return @backingInt(Exit.github);
}
