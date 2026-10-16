//! Test support: a scratch schema holding the real migration, so database tests never touch real data.
//! Used only from tests. Skipped (error.SkipZigTest) unless PG* variables or ZIG_TEST_PG_URL are set.
const std = @import("std");
const pg = @import("pg.zig");

const Allocator = std.mem.Allocator;

pub const Scratch = struct {
    arena: Allocator,
    cfg: pg.Config,
    schema: []const u8,
    admin: *pg.Client,

    pub fn create(arena: Allocator) !Scratch {
        var env = try std.testing.environ.createMap(arena);
        const cfg = if (env.get("ZIG_TEST_PG_URL")) |url|
            try pg.parseUrl(arena, url)
        else
            (try pg.fromEnv(&env)) orelse return error.SkipZigTest;

        // The migrations live in the repository; a test run outside it (or before db/ landed) skips.
        // Every one of them, in file-name order, because a scratch schema built from the first alone
        // is a schema no deployment has — and a column added by a later migration then looks to the
        // sink like a database that rejects its writes.
        var dir = std.Io.Dir.cwd().openDir(std.testing.io, "../db/migrations", .{ .iterate = true }) catch return error.SkipZigTest;
        defer dir.close(std.testing.io);
        var names: std.ArrayList([]const u8) = .empty;
        var it = dir.iterate();
        while (it.next(std.testing.io) catch null) |entry| {
            if (entry.kind != .file or !std.mem.endsWith(u8, entry.name, ".sql")) continue;
            try names.append(arena, try arena.dupe(u8, entry.name));
        }
        if (names.items.len == 0) return error.SkipZigTest;
        std.mem.sort([]const u8, names.items, {}, struct {
            fn lt(_: void, a: []const u8, b: []const u8) bool {
                return std.mem.lessThan(u8, a, b);
            }
        }.lt);
        var ups: std.ArrayList([]const u8) = .empty;
        for (names.items) |name| {
            const path = try std.fmt.allocPrint(arena, "../db/migrations/{s}", .{name});
            const text = std.Io.Dir.cwd().readFileAlloc(std.testing.io, path, arena, .limited(1 << 20)) catch return error.SkipZigTest;
            const up_start = (std.mem.indexOf(u8, text, "-- migrate:up") orelse continue) + "-- migrate:up".len;
            const up_end = std.mem.indexOf(u8, text, "-- migrate:down") orelse text.len;
            try ups.append(arena, text[up_start..up_end]);
        }

        var rnd: [6]u8 = undefined;
        std.testing.io.random(&rnd);
        const schema = try std.fmt.allocPrint(arena, "zig_it_{x}", .{rnd});

        const admin = try pg.Client.connect(std.testing.allocator, std.testing.io, cfg);
        errdefer admin.close();
        try admin.exec(try std.fmt.allocPrint(arena, "CREATE SCHEMA \"{s}\"", .{schema}));
        errdefer admin.exec(std.fmt.allocPrint(arena, "DROP SCHEMA \"{s}\" CASCADE", .{schema}) catch "select 1") catch {};
        try admin.exec(try std.fmt.allocPrint(arena, "SET search_path TO \"{s}\", public", .{schema}));
        for (ups.items) |up| try admin.exec(up);
        return .{ .arena = arena, .cfg = cfg, .schema = schema, .admin = admin };
    }

    pub fn destroy(s: *Scratch) void {
        s.admin.exec(std.fmt.allocPrint(s.arena, "DROP SCHEMA \"{s}\" CASCADE", .{s.schema}) catch "select 1") catch {};
        s.admin.close();
    }

    /// One text value.
    pub fn scalar(s: *Scratch, sql: []const u8) ![]const u8 {
        const rows = try s.admin.query(s.arena, sql);
        if (rows.len == 0 or rows[0].len == 0) return "";
        return rows[0][0] orelse "NULL";
    }
};
