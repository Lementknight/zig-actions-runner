//! The runner's write path to the database (#27): one connection on top of Client.zig, opened on
//! first use and reopened after a drop, plus multi-row inserts split at the protocol's parameter
//! limit.
//!
//! Every statement the runner writes is idempotent (upserts and `ON CONFLICT DO NOTHING` inserts,
//! SPEC §5.2), so a statement interrupted by a dropped connection is retried once on a fresh one.
//! A statement that must not run twice does not belong here. After a failed connect, calls fail
//! fast with `error.DatabaseUnavailable` for `reconnect_backoff_ms`, so a dead database costs one
//! connect attempt per backoff window rather than one per log flush.
const std = @import("std");
const url_mod = @import("url.zig");
const Client = @import("Client.zig");

const Db = @This();
const Allocator = std.mem.Allocator;
pub const Param = Client.Param;

gpa: Allocator,
io: std.Io,
url: url_mod.Url,
/// Holds the current connection's buffers; freed on every reconnect.
conn_arena: std.heap.ArenaAllocator,
client: ?*Client = null,
reconnect_backoff_ms: i64 = 5000,
/// No connect is attempted before this time (milliseconds, real clock).
retry_at_ms: i64 = 0,
/// From the last failed call: "SEVERITY SQLSTATE: message", parameter values scrubbed. Lives in
/// the arena passed to that call (or, for a failed connect, until the next connect attempt).
last_error: ?[]const u8 = null,
last_sqlstate: ?[]const u8 = null,

/// Connects lazily, on the first statement. `url` must outlive the `Db`.
pub fn init(gpa: Allocator, io: std.Io, url: url_mod.Url) Db {
    return .{ .gpa = gpa, .io = io, .url = url, .conn_arena = .init(gpa) };
}

pub fn deinit(db: *Db) void {
    db.drop();
    db.conn_arena.deinit();
}

/// Runs one statement with text parameters (`$1`, `$2`, ...; null is NULL) and returns the rows it
/// affected. `error.QueryFailed` is a server error (`last_error`, `last_sqlstate`); the connection
/// stays open. A dropped connection is reopened and the statement retried once: a failed reconnect
/// returns the connect error, and a second drop returns `error.ConnectionLost`.
pub fn exec(db: *Db, arena: Allocator, sql: []const u8, params: []const Param) !u64 {
    db.last_error = null;
    db.last_sqlstate = null;
    var retried = false;
    while (true) {
        const c = try db.connection();
        if (c.exec(arena, sql, params)) |n| {
            return n;
        } else |e| switch (e) {
            error.QueryFailed => {
                db.last_error = c.last_error;
                db.last_sqlstate = c.last_sqlstate;
                return error.QueryFailed;
            },
            error.OutOfMemory, error.TooManyParameters => |x| return x,
            // Anything else (a read or write failure, a protocol surprise) leaves the connection
            // in an unknown state, so it is closed.
            else => {
                db.drop();
                if (retried) return error.ConnectionLost;
                retried = true;
            },
        }
    }
}

/// Inserts `params.len / width` rows of `width` columns (row-major) as
/// `<head> VALUES ($1, ...), (...) <tail>`, e.g. head `INSERT INTO job_logs (ts, job_id, ...)` and
/// tail `ON CONFLICT DO NOTHING`. Rows are split into as many statements as the 65535-parameter
/// limit needs; each statement commits on its own. Returns the rows affected in total.
pub fn insertMany(db: *Db, arena: Allocator, head: []const u8, width: usize, params: []const Param, tail: []const u8) !u64 {
    return db.insertManyLimit(arena, head, width, params, tail, Client.max_params);
}

fn insertManyLimit(db: *Db, arena: Allocator, head: []const u8, width: usize, params: []const Param, tail: []const u8, limit: usize) !u64 {
    const per = try rowsPerStatement(width, params.len, limit);
    if (params.len == 0) return 0;
    const total_rows = params.len / width;
    // Every full statement has the same text; only the last one may be shorter.
    const full_sql = try valuesSql(arena, head, width, @min(per, total_rows), tail);
    var affected: u64 = 0;
    var row: usize = 0;
    while (row < total_rows) {
        const n = @min(per, total_rows - row);
        const sql = if (n == per or n == total_rows) full_sql else try valuesSql(arena, head, width, n, tail);
        affected += try db.exec(arena, sql, params[row * width .. (row + n) * width]);
        row += n;
    }
    return affected;
}

/// How many rows of `width` parameters fit in one statement under `limit`.
fn rowsPerStatement(width: usize, param_count: usize, limit: usize) error{InvalidBatch}!usize {
    if (width == 0 or width > limit or param_count % width != 0) return error.InvalidBatch;
    return limit / width;
}

/// `<head> VALUES ($1, $2), ($3, $4) <tail>` for `rows` rows of `width` columns.
pub fn valuesSql(arena: Allocator, head: []const u8, width: usize, rows: usize, tail: []const u8) ![]const u8 {
    var b: std.ArrayList(u8) = .empty;
    try b.appendSlice(arena, head);
    try b.appendSlice(arena, " VALUES ");
    var n: usize = 1;
    for (0..rows) |r| {
        if (r > 0) try b.appendSlice(arena, ", ");
        try b.append(arena, '(');
        for (0..width) |col| {
            if (col > 0) try b.appendSlice(arena, ", ");
            try b.print(arena, "${d}", .{n});
            n += 1;
        }
        try b.append(arena, ')');
    }
    if (tail.len > 0) {
        try b.append(arena, ' ');
        try b.appendSlice(arena, tail);
    }
    return b.items;
}

/// The open connection, or a new one. Fails fast inside the backoff window after a failed connect.
fn connection(db: *Db) !*Client {
    if (db.client) |c| return c;
    const now = std.Io.Clock.real.now(db.io).toMilliseconds();
    if (now < db.retry_at_ms) return error.DatabaseUnavailable;
    _ = db.conn_arena.reset(.free_all);
    var detail: ?[]const u8 = null;
    db.client = Client.connect(db.conn_arena.allocator(), db.io, db.url, .{ .error_detail = &detail }) catch |e| {
        db.retry_at_ms = now + db.reconnect_backoff_ms;
        db.last_error = detail;
        return e;
    };
    return db.client.?;
}

/// Closes the connection, if any. The next statement opens a new one.
fn drop(db: *Db) void {
    if (db.client) |c| c.close();
    db.client = null;
}

test "valuesSql numbers the parameters row by row" {
    var a: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer a.deinit();
    const sql = try valuesSql(a.allocator(), "INSERT INTO t (a, b, c)", 3, 2, "ON CONFLICT DO NOTHING");
    try std.testing.expectEqualStrings("INSERT INTO t (a, b, c) VALUES ($1, $2, $3), ($4, $5, $6) ON CONFLICT DO NOTHING", sql);
    try std.testing.expectEqualStrings("INSERT INTO t (a) VALUES ($1)", try valuesSql(a.allocator(), "INSERT INTO t (a)", 1, 1, ""));
}

test "rowsPerStatement stays under the parameter limit" {
    try std.testing.expectEqual(@as(usize, 10922), try rowsPerStatement(6, 60, Client.max_params)); // job_logs' six columns
    try std.testing.expectEqual(@as(usize, 65535), try rowsPerStatement(1, 3, Client.max_params));
    try std.testing.expectEqual(@as(usize, 2), try rowsPerStatement(3, 9, 7));
    try std.testing.expectError(error.InvalidBatch, rowsPerStatement(0, 0, 10));
    try std.testing.expectError(error.InvalidBatch, rowsPerStatement(3, 7, 10)); // not whole rows
    try std.testing.expectError(error.InvalidBatch, rowsPerStatement(11, 11, 10)); // one row too wide
}

test "a failed connect backs off instead of retrying on every call" {
    var a: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer a.deinit();
    // Port 1 on loopback refuses at once; no database needed.
    const u: url_mod.Url = .{ .user = "u", .password = "p", .host = "127.0.0.1", .port = 1, .database = "d", .sslmode = .disable };
    var db: Db = .init(std.testing.allocator, std.testing.io, u);
    defer db.deinit();
    try std.testing.expect(std.meta.isError(db.exec(a.allocator(), "SELECT 1", &.{})));
    try std.testing.expectError(error.DatabaseUnavailable, db.exec(a.allocator(), "SELECT 1", &.{}));
    db.retry_at_ms = 0; // the window has passed: the next call tries to connect again
    const again = db.exec(a.allocator(), "SELECT 1", &.{});
    try std.testing.expect(std.meta.isError(again));
    if (again) |_| {} else |e| try std.testing.expect(e != error.DatabaseUnavailable);
}

// Live checks. Skip unless `DATABASE_URL` is set; nothing from it is printed.
fn liveUrl(arena: Allocator) !url_mod.Url {
    const raw = std.testing.environ.getPosix("DATABASE_URL") orelse return error.SkipZigTest;
    return url_mod.parse(arena, raw);
}

test "exec binds text and NULL parameters and reports affected rows (DATABASE_URL)" {
    var a: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer a.deinit();
    const arena = a.allocator();
    var db: Db = .init(std.testing.allocator, std.testing.io, try liveUrl(arena));
    defer db.deinit();

    try std.testing.expectEqual(@as(u64, 0), try db.exec(arena, "CREATE TEMP TABLE t27 (id bigint PRIMARY KEY, note text, n int)", &.{}));
    // Quotes, a newline, ANSI codes and non-ASCII travel as-is: no escaping, no injection.
    const note = "it's \"quoted\"; DROP TABLE t27; --\n\x1b[31mred\x1b[0m \u{00fc}";
    try std.testing.expectEqual(@as(u64, 1), try db.exec(arena, "INSERT INTO t27 (id, note, n) VALUES ($1, $2, $3)", &.{ "1", note, null }));
    try std.testing.expectEqual(@as(u64, 1), try db.exec(arena, "INSERT INTO t27 (id, note, n) VALUES ($1, $2, $3)", &.{ "2", "", "7" }));
    const back = try db.client.?.query(arena, "SELECT note, n IS NULL FROM t27 WHERE id = 1");
    try std.testing.expectEqualStrings(note, back.rows[0][0].?);
    try std.testing.expectEqualStrings("t", back.rows[0][1].?);
    try std.testing.expectEqual(@as(u64, 2), try db.exec(arena, "UPDATE t27 SET n = $1", &.{"5"}));
    try std.testing.expectEqual(@as(u64, 2), try db.exec(arena, "SELECT id FROM t27 WHERE n = $1", &.{"5"}));
    // An upsert run twice is harmless.
    const upsert = "INSERT INTO t27 (id, note) VALUES ($1, $2) ON CONFLICT (id) DO UPDATE SET note = EXCLUDED.note";
    try std.testing.expectEqual(@as(u64, 1), try db.exec(arena, upsert, &.{ "3", "x" }));
    try std.testing.expectEqual(@as(u64, 1), try db.exec(arena, upsert, &.{ "3", "x" }));
}

test "server errors carry SQLSTATE and message but not the parameter values (DATABASE_URL)" {
    var a: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer a.deinit();
    const arena = a.allocator();
    var db: Db = .init(std.testing.allocator, std.testing.io, try liveUrl(arena));
    defer db.deinit();
    _ = try db.exec(arena, "CREATE TEMP TABLE t27e (id bigint PRIMARY KEY)", &.{});

    const secret = "hunter2-not-a-number";
    try std.testing.expectError(error.QueryFailed, db.exec(arena, "INSERT INTO t27e (id) VALUES ($1)", &.{secret}));
    try std.testing.expectEqualStrings("22P02", db.last_sqlstate.?);
    try std.testing.expect(std.mem.indexOf(u8, db.last_error.?, "invalid input syntax") != null);
    try std.testing.expect(std.mem.indexOf(u8, db.last_error.?, "hunter2") == null);
    try std.testing.expect(std.mem.indexOf(u8, db.last_error.?, "\"***\"") != null);

    _ = try db.exec(arena, "INSERT INTO t27e (id) VALUES ($1)", &.{"1"});
    try std.testing.expectError(error.QueryFailed, db.exec(arena, "INSERT INTO t27e (id) VALUES ($1)", &.{"1"}));
    try std.testing.expectEqualStrings("23505", db.last_sqlstate.?);
    // Server errors leave the connection open and usable.
    try std.testing.expectEqual(@as(u64, 1), try db.exec(arena, "SELECT 1", &.{}));
}

test "insertMany splits at the parameter limit (DATABASE_URL)" {
    var a: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer a.deinit();
    const arena = a.allocator();
    var db: Db = .init(std.testing.allocator, std.testing.io, try liveUrl(arena));
    defer db.deinit();
    _ = try db.exec(arena, "CREATE TEMP TABLE t27m (seq bigint PRIMARY KEY, line text)", &.{});

    // 40000 rows of 2 columns is 80000 parameters: two statements at the real limit.
    const rows = 40000;
    const params = try arena.alloc(Param, rows * 2);
    for (0..rows) |i| {
        params[i * 2] = try std.fmt.allocPrint(arena, "{d}", .{i + 1});
        params[i * 2 + 1] = if (i % 7 == 0) null else try std.fmt.allocPrint(arena, "line {d}", .{i + 1});
    }
    const head = "INSERT INTO t27m (seq, line)";
    const tail = "ON CONFLICT DO NOTHING";
    try std.testing.expectEqual(@as(u64, rows), try db.insertMany(arena, head, 2, params, tail));
    try std.testing.expectEqualStrings("40000", (try db.client.?.queryScalar(arena, "SELECT count(*) FROM t27m")).?);
    try std.testing.expectEqualStrings("40000", (try db.client.?.queryScalar(arena, "SELECT max(seq) FROM t27m")).?);
    // Re-inserting the same rows changes nothing.
    try std.testing.expectEqual(@as(u64, 0), try db.insertMany(arena, head, 2, params, tail));
    // A small limit forces an uneven split: 3 rows per statement, 7 rows.
    _ = try db.exec(arena, "TRUNCATE t27m", &.{});
    try std.testing.expectEqual(@as(u64, 7), try db.insertManyLimit(arena, head, 2, params[0..14], tail, 6));
    try std.testing.expectEqualStrings("7", (try db.client.?.queryScalar(arena, "SELECT count(*) FROM t27m")).?);

    try std.testing.expectError(error.TooManyParameters, db.exec(arena, "SELECT 1", params[0 .. Client.max_params + 1]));
    try std.testing.expectEqual(@as(u64, 0), try db.insertMany(arena, head, 2, &.{}, tail));
}

test "a dropped connection is reopened and the statement retried (DATABASE_URL)" {
    var a: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer a.deinit();
    const arena = a.allocator();
    const u = try liveUrl(arena);
    var db: Db = .init(std.testing.allocator, std.testing.io, u);
    defer db.deinit();
    _ = try db.exec(arena, "SELECT 1", &.{});
    const pid = (try db.client.?.queryScalar(arena, "SELECT pg_backend_pid()")).?;

    // Another session kills ours, then waits until the server has let it go.
    const killer = try Client.connect(arena, std.testing.io, u, .{});
    defer killer.close();
    _ = try killer.query(arena, try std.fmt.allocPrint(arena, "SELECT pg_terminate_backend({s})", .{pid}));
    const gone = try std.fmt.allocPrint(arena, "SELECT count(*) FROM pg_stat_activity WHERE pid = {s}", .{pid});
    for (0..100) |_| {
        if (std.mem.eql(u8, (try killer.queryScalar(arena, gone)).?, "0")) break;
        try std.Io.sleep(std.testing.io, .fromMilliseconds(20), .awake);
    }

    try std.testing.expectEqual(@as(u64, 1), try db.exec(arena, "SELECT 1", &.{}));
    const new_pid = (try db.client.?.queryScalar(arena, "SELECT pg_backend_pid()")).?;
    try std.testing.expect(!std.mem.eql(u8, pid, new_pid));
}
