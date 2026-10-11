//! Minimal PostgreSQL client on std alone (#26): TCP, SSLRequest then `std.crypto.tls.Client`,
//! the startup message, SCRAM-SHA-256 (scram.zig) and the simple query protocol. Enough to reach
//! Tiger Data, which requires TLS and SCRAM, from a single static binary (SPEC §7). Card #27 adds
//! parameterized queries and batched inserts on top of `send`/`recv`.
//!
//! Nothing here writes to stdout or stderr. Server error text is kept in `last_error` for the
//! caller to print through the redaction list; it never carries the URL or the password.
const std = @import("std");
const url_mod = @import("url.zig");
const scram = @import("scram.zig");

const Client = @This();
const Allocator = std.mem.Allocator;
const Io = std.Io;
const tls = std.crypto.tls;

io: Io,
stream: Io.net.Stream,
stream_reader: *Io.net.Stream.Reader,
stream_writer: *Io.net.Stream.Writer,
tls_client: ?*tls.Client,
/// The plaintext side: the TLS client's reader and writer, or the socket's when TLS is off.
r: *Io.Reader,
w: *Io.Writer,
/// Whether the connection is encrypted.
encrypted: bool,
/// `server_version` from the startup ParameterStatus messages, e.g. "17.6".
server_version: []const u8 = "",
/// "SEVERITY SQLSTATE: message" of the last ErrorResponse, for diagnostics.
last_error: ?[]const u8 = null,

pub const Options = struct {
    application_name: []const u8 = "zig-actions-runner",
    /// Set to the server's ErrorResponse text when `connect` fails on one (`last_error`).
    error_detail: ?*?[]const u8 = null,
};

/// Protocol 3.0, as every supported PostgreSQL speaks.
const protocol_version: u32 = 196608;
const ssl_request_code: u32 = 80877103;
/// Larger messages than this are a protocol error for our purposes (no query returns one).
const max_message_len: u32 = 64 * 1024 * 1024;

pub const Error = error{
    /// The server refused TLS and `sslmode` does not allow plaintext.
    TlsRefusedByServer,
    UnexpectedSslResponse,
    /// The server offered no authentication method we speak (SCRAM-SHA-256 or cleartext).
    UnsupportedAuthentication,
    /// Wrong password, unknown role, or a missing database: see `last_error`.
    AuthenticationFailed,
    /// Any other ErrorResponse during startup: see `last_error`.
    StartupFailed,
    /// The query returned an ErrorResponse: see `last_error`.
    QueryFailed,
    UnexpectedMessage,
    InvalidMessage,
};

/// Dials, negotiates TLS per `u.sslmode`, authenticates and waits for ReadyForQuery. Buffers and
/// the client itself live in `arena`.
pub fn connect(arena: Allocator, io: Io, u: url_mod.Url, opts: Options) !*Client {
    const stream = try dial(io, u.host, u.port);
    errdefer stream.close(io);

    const sr = try arena.create(Io.net.Stream.Reader);
    const sw = try arena.create(Io.net.Stream.Writer);
    sr.* = stream.reader(io, try arena.alloc(u8, tls.Client.min_buffer_len));
    sw.* = stream.writer(io, try arena.alloc(u8, tls.Client.min_buffer_len));
    const c = try arena.create(Client);
    c.* = .{
        .io = io,
        .stream = stream,
        .stream_reader = sr,
        .stream_writer = sw,
        .tls_client = null,
        .r = &sr.interface,
        .w = &sw.interface,
        .encrypted = false,
    };

    if (u.sslmode.wantsTls()) {
        var req: [8]u8 = undefined;
        std.mem.writeInt(u32, req[0..4], 8, .big);
        std.mem.writeInt(u32, req[4..8], ssl_request_code, .big);
        try c.w.writeAll(&req);
        try c.flush();
        switch (try c.r.takeByte()) {
            'S' => try c.startTls(arena, u),
            // 'N' is "no TLS here"; an 'E' is a pre-TLS server's ErrorResponse, which means the same.
            'N', 'E' => if (!u.sslmode.allowsPlain()) return error.TlsRefusedByServer,
            else => return error.UnexpectedSslResponse,
        }
    }
    c.startup(arena, u, opts.application_name) catch |e| {
        if (opts.error_detail) |d| d.* = c.last_error;
        return e;
    };
    return c;
}

/// Sends Terminate and closes the socket. Errors are ignored: the server drops the session anyway.
pub fn close(c: *Client) void {
    c.send('X', "") catch {};
    if (c.tls_client) |t| {
        t.end() catch {};
        c.stream_writer.interface.flush() catch {};
    }
    c.stream.close(c.io);
}

/// No connect timeout: Zig 0.17's threaded Io panics on `netConnectIp` with one ("TODO"), so the
/// operating system's own TCP timeout applies.
fn dial(io: Io, host: []const u8, port: u16) !Io.net.Stream {
    const copts: Io.net.IpAddress.ConnectOptions = .{ .mode = .stream };
    if (Io.net.IpAddress.parse(host, port)) |addr| {
        return addr.connect(io, copts);
    } else |_| {
        const name = try Io.net.HostName.init(host);
        return name.connect(io, port, copts);
    }
}

fn startTls(c: *Client, arena: Allocator, u: url_mod.Url) !void {
    const now = Io.Clock.real.now(c.io);
    var entropy: [tls.Client.Options.entropy_len]u8 = undefined;
    c.io.random(&entropy);

    // libpq semantics: `require` encrypts without checking the certificate; `verify-ca` checks the
    // chain against the system CA store; `verify-full` also checks the host name.
    var ca: @FieldType(tls.Client.Options, "ca") = .no_verification;
    if (u.sslmode == .@"verify-ca" or u.sslmode == .@"verify-full") {
        const bundle = try arena.create(std.crypto.Certificate.Bundle);
        bundle.* = .empty;
        try bundle.rescan(arena, c.io, now);
        const lock = try arena.create(Io.RwLock);
        lock.* = .init;
        ca = .{ .bundle = .{ .gpa = arena, .io = c.io, .lock = lock, .bundle = bundle } };
    }

    const t = try arena.create(tls.Client);
    t.* = tls.Client.init(&c.stream_reader.interface, &c.stream_writer.interface, .{
        .host = if (u.sslmode == .@"verify-full") .{ .explicit = u.host } else .no_verification,
        .ca = ca,
        // The TLS reader needs room for a full record plus whatever the protocol layer peeks at.
        .read_buffer = try arena.alloc(u8, tls.Client.min_buffer_len + 8192),
        .write_buffer = try arena.alloc(u8, tls.Client.min_buffer_len),
        .entropy = &entropy,
        .realtime_now = now,
    }) catch |err| switch (err) {
        error.WriteFailed => return c.stream_writer.err orelse error.WriteFailed,
        error.ReadFailed => return c.stream_reader.err orelse error.ReadFailed,
        else => |e| return e,
    };
    c.tls_client = t;
    c.r = &t.reader;
    c.w = &t.writer;
    c.encrypted = true;
}

/// Writes one frontend message: the type byte (none for the startup message), int32 length
/// including itself, then `body`. Flushes through to the socket.
pub fn send(c: *Client, msg_type: ?u8, body: []const u8) !void {
    if (msg_type) |t| try c.w.writeByte(t);
    var len: [4]u8 = undefined;
    std.mem.writeInt(u32, &len, @intCast(body.len + 4), .big);
    try c.w.writeAll(&len);
    try c.w.writeAll(body);
    try c.flush();
}

/// The TLS writer's flush only encrypts into the socket writer's buffer, so both are flushed.
fn flush(c: *Client) !void {
    try c.w.flush();
    if (c.tls_client != null) try c.stream_writer.interface.flush();
}

pub const Message = struct {
    kind: u8,
    /// Valid until the next `recv` unless it had to be allocated; copy what must outlive it.
    body: []const u8,
};

/// Reads one backend message.
pub fn recv(c: *Client, arena: Allocator) !Message {
    const kind = try c.r.takeByte();
    const len = std.mem.readInt(u32, try c.r.takeArray(4), .big);
    if (len < 4 or len > max_message_len) return error.InvalidMessage;
    const n: usize = len - 4;
    const body = if (n <= c.r.buffer.len) try c.r.take(n) else try c.r.readAllocAll(arena, n);
    return .{ .kind = kind, .body = body };
}

fn startup(c: *Client, arena: Allocator, u: url_mod.Url, application_name: []const u8) !void {
    var body: std.ArrayList(u8) = .empty;
    var ver: [4]u8 = undefined;
    std.mem.writeInt(u32, &ver, protocol_version, .big);
    try body.appendSlice(arena, &ver);
    const params = [_][2][]const u8{
        .{ "user", u.user },
        .{ "database", u.database },
        .{ "application_name", application_name },
        .{ "client_encoding", "UTF8" },
    };
    for (params) |kv| {
        try body.appendSlice(arena, kv[0]);
        try body.append(arena, 0);
        try body.appendSlice(arena, kv[1]);
        try body.append(arena, 0);
    }
    try body.append(arena, 0);
    try c.send(null, body.items);

    var nonce_buf: [24]u8 = undefined;
    var client_nonce: []const u8 = "";
    var client_first: []const u8 = "";
    var expected_sig: [scram.key_len]u8 = undefined;
    auth: while (true) {
        const m = try c.recv(arena);
        switch (m.kind) {
            'E' => return c.fail(arena, m.body, .startup),
            'R' => {
                if (m.body.len < 4) return error.InvalidMessage;
                const code = std.mem.readInt(u32, m.body[0..4], .big);
                const data = m.body[4..];
                switch (code) {
                    0 => break :auth, // AuthenticationOk
                    3 => { // AuthenticationCleartextPassword; only ever seen over TLS in practice
                        try c.send('p', try std.mem.concat(arena, u8, &.{ u.password, "\x00" }));
                    },
                    10 => { // AuthenticationSASL: a list of mechanisms
                        if (!offersMechanism(data, "SCRAM-SHA-256")) return error.UnsupportedAuthentication;
                        var random: [18]u8 = undefined;
                        c.io.random(&random);
                        client_nonce = scram.nonceFromBytes(&random, &nonce_buf);
                        client_first = try scram.clientFirstMessage(arena, u.user, client_nonce);
                        // SASLInitialResponse: mechanism, int32 length, client-first-message.
                        var resp: std.ArrayList(u8) = .empty;
                        try resp.appendSlice(arena, "SCRAM-SHA-256\x00");
                        var flen: [4]u8 = undefined;
                        std.mem.writeInt(u32, &flen, @intCast(client_first.len), .big);
                        try resp.appendSlice(arena, &flen);
                        try resp.appendSlice(arena, client_first);
                        try c.send('p', resp.items);
                    },
                    11 => { // AuthenticationSASLContinue: server-first-message
                        const raw = try arena.dupe(u8, data);
                        const sf = try scram.parseServerFirst(arena, raw, client_nonce);
                        const fin = try scram.clientFinalMessage(arena, u.password, client_first, raw, sf);
                        expected_sig = fin.server_signature;
                        try c.send('p', fin.message);
                    },
                    12 => try scram.verifyServerFinal(data, expected_sig), // AuthenticationSASLFinal
                    else => return error.UnsupportedAuthentication, // 5 is MD5, 2 Kerberos, 7 GSS...
                }
            },
            else => return error.UnexpectedMessage,
        }
    }

    while (true) {
        const m = try c.recv(arena);
        switch (m.kind) {
            'S' => { // ParameterStatus: name, value
                const name = std.mem.sliceTo(m.body, 0);
                if (std.mem.eql(u8, name, "server_version") and name.len + 1 < m.body.len) {
                    c.server_version = try arena.dupe(u8, std.mem.sliceTo(m.body[name.len + 1 ..], 0));
                }
            },
            'K', 'N' => {}, // BackendKeyData, NoticeResponse
            'Z' => return, // ReadyForQuery
            'E' => return c.fail(arena, m.body, .startup),
            else => return error.UnexpectedMessage,
        }
    }
}

fn offersMechanism(list: []const u8, want: []const u8) bool {
    var it = std.mem.splitScalar(u8, list, 0);
    while (it.next()) |m| {
        if (m.len == 0) break;
        if (std.mem.eql(u8, m, want)) return true;
    }
    return false;
}

pub const Row = []const ?[]const u8;

pub const Result = struct {
    columns: []const []const u8,
    rows: []const Row,
    /// e.g. "SELECT 1".
    command_tag: []const u8,
};

/// Simple query protocol: one statement, text results, all copied into `arena`.
pub fn query(c: *Client, arena: Allocator, sql: []const u8) !Result {
    try c.send('Q', try std.mem.concat(arena, u8, &.{ sql, "\x00" }));
    var columns: std.ArrayList([]const u8) = .empty;
    var rows: std.ArrayList(Row) = .empty;
    var tag: []const u8 = "";
    var failed: ?anyerror = null;
    while (true) {
        const m = try c.recv(arena);
        switch (m.kind) {
            'T' => { // RowDescription
                var p: usize = 2;
                const n = std.mem.readInt(u16, m.body[0..2], .big);
                for (0..n) |_| {
                    const name = std.mem.sliceTo(m.body[p..], 0);
                    try columns.append(arena, try arena.dupe(u8, name));
                    p += name.len + 1 + 18; // table oid, attnum, type oid, typlen, typmod, format
                }
            },
            'D' => { // DataRow
                const n = std.mem.readInt(u16, m.body[0..2], .big);
                const row = try arena.alloc(?[]const u8, n);
                var p: usize = 2;
                for (row) |*cell| {
                    if (p + 4 > m.body.len) return error.InvalidMessage;
                    const len = std.mem.readInt(i32, m.body[p..][0..4], .big);
                    p += 4;
                    if (len < 0) {
                        cell.* = null;
                    } else {
                        const l: usize = @intCast(len);
                        if (p + l > m.body.len) return error.InvalidMessage;
                        cell.* = try arena.dupe(u8, m.body[p..][0..l]);
                        p += l;
                    }
                }
                try rows.append(arena, row);
            },
            'C' => tag = try arena.dupe(u8, std.mem.sliceTo(m.body, 0)), // CommandComplete
            'E' => {
                _ = c.recordError(arena, m.body);
                failed = error.QueryFailed;
            },
            'N', 'I' => {}, // NoticeResponse, EmptyQueryResponse
            'Z' => break, // ReadyForQuery: the server is done with this query, error or not
            else => return error.UnexpectedMessage,
        }
    }
    if (failed) |e| return e;
    return .{ .columns = columns.items, .rows = rows.items, .command_tag = tag };
}

/// First column of the first row, or null when the query returned no rows or a NULL.
pub fn queryScalar(c: *Client, arena: Allocator, sql: []const u8) !?[]const u8 {
    const res = try c.query(arena, sql);
    if (res.rows.len == 0 or res.rows[0].len == 0) return null;
    return res.rows[0][0];
}

pub const Versions = struct {
    /// PostgreSQL's `server_version`, e.g. "17.6".
    server: []const u8,
    /// The installed timescaledb extension version, or null when the extension is absent.
    timescaledb: ?[]const u8,
};

/// What `runner --inspect` prints.
pub fn versions(c: *Client, arena: Allocator) !Versions {
    const server = if (c.server_version.len > 0) c.server_version else (try c.queryScalar(arena, "SHOW server_version")) orelse "unknown";
    const ts = try c.queryScalar(arena, "SELECT extversion FROM pg_extension WHERE extname = 'timescaledb'");
    return .{ .server = server, .timescaledb = ts };
}

const Phase = enum { startup };

fn fail(c: *Client, arena: Allocator, body: []const u8, phase: Phase) anyerror {
    const code = c.recordError(arena, body);
    _ = phase;
    // SQLSTATE class 28 is "invalid authorization specification"; 3D000 is "database does not exist".
    if (std.mem.startsWith(u8, code, "28") or std.mem.eql(u8, code, "3D000")) return error.AuthenticationFailed;
    return error.StartupFailed;
}

/// Parses an ErrorResponse into `last_error` and returns its SQLSTATE code ("" if absent).
fn recordError(c: *Client, arena: Allocator, body: []const u8) []const u8 {
    var severity: []const u8 = "ERROR";
    var code: []const u8 = "";
    var message: []const u8 = "";
    var p: usize = 0;
    while (p < body.len and body[p] != 0) {
        const field = body[p];
        const val = std.mem.sliceTo(body[p + 1 ..], 0);
        switch (field) {
            'S' => severity = val,
            'C' => code = val,
            'M' => message = val,
            else => {},
        }
        p += 1 + val.len + 1;
    }
    c.last_error = std.fmt.allocPrint(arena, "{s} {s}: {s}", .{ severity, code, message }) catch null;
    return arena.dupe(u8, code) catch "";
}

test "offersMechanism" {
    try std.testing.expect(offersMechanism("SCRAM-SHA-256-PLUS\x00SCRAM-SHA-256\x00\x00", "SCRAM-SHA-256"));
    try std.testing.expect(!offersMechanism("SCRAM-SHA-256-PLUS\x00\x00", "SCRAM-SHA-256"));
    try std.testing.expect(!offersMechanism("\x00", "SCRAM-SHA-256"));
}

test "recordError parses severity, code and message" {
    var a: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer a.deinit();
    var c: Client = undefined;
    c.last_error = null;
    const code = c.recordError(a.allocator(), "SFATAL\x00VFATAL\x00C28P01\x00Mpassword authentication failed for user \"x\"\x00Fauth.c\x00\x00");
    try std.testing.expectEqualStrings("28P01", code);
    try std.testing.expectEqualStrings("FATAL 28P01: password authentication failed for user \"x\"", c.last_error.?);
}

// Live check against a database. Skips unless `DATABASE_URL` is set; prints nothing from it.
test "connects, authenticates and queries the server (DATABASE_URL)" {
    const raw = std.testing.environ.getPosix("DATABASE_URL") orelse return error.SkipZigTest;
    var a: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer a.deinit();
    const arena = a.allocator();
    const u = try url_mod.parse(arena, raw);
    const c = try connect(arena, std.testing.io, u, .{});
    defer c.close();
    if (u.sslmode == .disable) try std.testing.expect(!c.encrypted);
    if (u.sslmode.wantsTls() and !u.sslmode.allowsPlain()) try std.testing.expect(c.encrypted);
    const one = try c.query(arena, "SELECT 1 AS one, NULL::text AS nothing");
    try std.testing.expectEqual(@as(usize, 2), one.columns.len);
    try std.testing.expectEqualStrings("one", one.columns[0]);
    try std.testing.expectEqualStrings("1", one.rows[0][0].?);
    try std.testing.expect(one.rows[0][1] == null);
    try std.testing.expectEqualStrings("SELECT 1", one.command_tag);
    const v = try c.versions(arena);
    try std.testing.expect(v.server.len > 0);
    // A failed query leaves the connection usable.
    try std.testing.expectError(error.QueryFailed, c.query(arena, "SELECT * FROM no_such_table_26"));
    try std.testing.expect(std.mem.indexOf(u8, c.last_error.?, "42P01") != null);
    try std.testing.expectEqualStrings("2", (try c.queryScalar(arena, "SELECT 2")).?);
}
