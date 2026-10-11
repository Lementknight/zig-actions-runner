//! `DATABASE_URL` parsing (SPEC §2): `postgres://user:password@host:port/database?sslmode=require`.
//! The password, user, host and database are percent-decoded; a password holding `@`, `/` or `%`
//! is written `%40`, `%2F`, `%25` as libpq expects. Nothing here is ever printed: the URL and the
//! decoded password go on the redaction list (SPEC §9).
const std = @import("std");

const Allocator = std.mem.Allocator;

/// libpq's `sslmode` values. `require` is the default: Tiger Data refuses plaintext connections.
pub const SslMode = enum {
    disable,
    allow,
    prefer,
    require,
    @"verify-ca",
    @"verify-full",

    /// Whether to send SSLRequest at all.
    pub fn wantsTls(m: SslMode) bool {
        return m != .disable;
    }

    /// Whether a server answering "no TLS" is accepted (plaintext fallback).
    pub fn allowsPlain(m: SslMode) bool {
        return m == .allow or m == .prefer;
    }
};

pub const Url = struct {
    user: []const u8,
    /// Percent-decoded. May be empty when the URL carries no password.
    password: []const u8,
    host: []const u8,
    port: u16 = 5432,
    database: []const u8,
    sslmode: SslMode = .require,
};

pub const Error = error{
    InvalidScheme,
    MissingUser,
    MissingHost,
    InvalidPort,
    InvalidPercentEncoding,
    UnknownSslMode,
    OutOfMemory,
};

/// Decoded fields are allocated from `arena` only when they hold percent escapes; otherwise they
/// borrow from `s`, which must outlive the Url.
pub fn parse(arena: Allocator, s: []const u8) Error!Url {
    var rest: []const u8 = undefined;
    if (std.mem.startsWith(u8, s, "postgresql://")) {
        rest = s["postgresql://".len..];
    } else if (std.mem.startsWith(u8, s, "postgres://")) {
        rest = s["postgres://".len..];
    } else return error.InvalidScheme;

    // authority = [userinfo "@"] host [":" port]; ends at the first "/" or "?".
    const auth_end = std.mem.indexOfAny(u8, rest, "/?") orelse rest.len;
    const authority = rest[0..auth_end];
    var tail = rest[auth_end..];

    // The last "@" splits user info from the host, so an unencoded "@" in a password still works.
    var url: Url = .{ .user = "", .password = "", .host = "", .database = "" };
    var hostport = authority;
    if (std.mem.lastIndexOfScalar(u8, authority, '@')) |at| {
        const userinfo = authority[0..at];
        hostport = authority[at + 1 ..];
        if (std.mem.indexOfScalar(u8, userinfo, ':')) |colon| {
            url.user = try decode(arena, userinfo[0..colon]);
            url.password = try decode(arena, userinfo[colon + 1 ..]);
        } else {
            url.user = try decode(arena, userinfo);
        }
    }
    if (url.user.len == 0) return error.MissingUser;

    // Host: "[v6]" or a name/IPv4, then an optional ":port".
    if (hostport.len > 0 and hostport[0] == '[') {
        const close = std.mem.indexOfScalar(u8, hostport, ']') orelse return error.MissingHost;
        url.host = hostport[1..close];
        const after = hostport[close + 1 ..];
        if (after.len > 0) {
            if (after[0] != ':') return error.InvalidPort;
            url.port = parsePort(after[1..]) orelse return error.InvalidPort;
        }
    } else if (std.mem.lastIndexOfScalar(u8, hostport, ':')) |colon| {
        url.host = try decode(arena, hostport[0..colon]);
        url.port = parsePort(hostport[colon + 1 ..]) orelse return error.InvalidPort;
    } else {
        url.host = try decode(arena, hostport);
    }
    if (url.host.len == 0) return error.MissingHost;

    // Path: "/database". Empty means "same as the user", as libpq does.
    if (tail.len > 0 and tail[0] == '/') {
        const q = std.mem.indexOfScalar(u8, tail, '?') orelse tail.len;
        url.database = try decode(arena, tail[1..q]);
        tail = tail[q..];
    }
    if (url.database.len == 0) url.database = url.user;

    // Query: only sslmode is understood; other libpq parameters are ignored.
    if (tail.len > 0 and tail[0] == '?') {
        var it = std.mem.splitScalar(u8, tail[1..], '&');
        while (it.next()) |pair| {
            if (pair.len == 0) continue;
            const eq = std.mem.indexOfScalar(u8, pair, '=') orelse pair.len;
            const key = pair[0..eq];
            const val = if (eq < pair.len) pair[eq + 1 ..] else "";
            if (std.mem.eql(u8, key, "sslmode")) {
                url.sslmode = std.meta.stringToEnum(SslMode, try decode(arena, val)) orelse return error.UnknownSslMode;
            }
        }
    }
    return url;
}

fn parsePort(s: []const u8) ?u16 {
    if (s.len == 0) return null;
    return std.fmt.parseInt(u16, s, 10) catch null;
}

/// Percent-decodes `s`. Returns `s` itself when it holds no escapes.
fn decode(arena: Allocator, s: []const u8) Error![]const u8 {
    if (std.mem.indexOfScalar(u8, s, '%') == null) return s;
    var out = try arena.alloc(u8, s.len);
    var n: usize = 0;
    var i: usize = 0;
    while (i < s.len) : (i += 1) {
        if (s[i] == '%') {
            if (i + 2 >= s.len) return error.InvalidPercentEncoding;
            const hi = std.fmt.charToDigit(s[i + 1], 16) catch return error.InvalidPercentEncoding;
            const lo = std.fmt.charToDigit(s[i + 2], 16) catch return error.InvalidPercentEncoding;
            out[n] = hi * 16 + lo;
            i += 2;
        } else {
            out[n] = s[i];
        }
        n += 1;
    }
    return out[0..n];
}

test "full url with every field" {
    var a: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer a.deinit();
    const u = try parse(a.allocator(), "postgres://tsdbadmin:secret@db.example:31234/tsdb?sslmode=require");
    try std.testing.expectEqualStrings("tsdbadmin", u.user);
    try std.testing.expectEqualStrings("secret", u.password);
    try std.testing.expectEqualStrings("db.example", u.host);
    try std.testing.expectEqual(@as(u16, 31234), u.port);
    try std.testing.expectEqualStrings("tsdb", u.database);
    try std.testing.expectEqual(SslMode.require, u.sslmode);
}

test "password with @, / and % is percent-decoded" {
    var a: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer a.deinit();
    // The password is `p@ss/w%rd:x`.
    const u = try parse(a.allocator(), "postgresql://runner:p%40ss%2Fw%25rd%3Ax@db.example/runs");
    try std.testing.expectEqualStrings("runner", u.user);
    try std.testing.expectEqualStrings("p@ss/w%rd:x", u.password);
    try std.testing.expectEqualStrings("db.example", u.host);
    try std.testing.expectEqual(@as(u16, 5432), u.port);
    try std.testing.expectEqualStrings("runs", u.database);
}

test "an unencoded @ in the password still finds the host" {
    var a: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer a.deinit();
    const u = try parse(a.allocator(), "postgres://u:a@b@db.example:5/d");
    try std.testing.expectEqualStrings("a@b", u.password);
    try std.testing.expectEqualStrings("db.example", u.host);
    try std.testing.expectEqual(@as(u16, 5), u.port);
}

test "defaults: port 5432, database = user, sslmode require" {
    var a: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer a.deinit();
    const u = try parse(a.allocator(), "postgres://alice@db.example");
    try std.testing.expectEqualStrings("alice", u.user);
    try std.testing.expectEqualStrings("", u.password);
    try std.testing.expectEqual(@as(u16, 5432), u.port);
    try std.testing.expectEqualStrings("alice", u.database);
    try std.testing.expectEqual(SslMode.require, u.sslmode);
}

test "sslmode values and unknown parameters" {
    var a: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer a.deinit();
    const arena = a.allocator();
    try std.testing.expectEqual(SslMode.disable, (try parse(arena, "postgres://u:p@h/d?sslmode=disable")).sslmode);
    try std.testing.expectEqual(SslMode.@"verify-full", (try parse(arena, "postgres://u:p@h/d?application_name=x&sslmode=verify-full")).sslmode);
    try std.testing.expectEqual(SslMode.prefer, (try parse(arena, "postgres://u:p@h/d?sslmode=prefer&connect_timeout=5")).sslmode);
    try std.testing.expectError(error.UnknownSslMode, parse(arena, "postgres://u:p@h/d?sslmode=yes"));
}

test "ipv6 host in brackets" {
    var a: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer a.deinit();
    const u = try parse(a.allocator(), "postgres://u:p@[::1]:6543/d");
    try std.testing.expectEqualStrings("::1", u.host);
    try std.testing.expectEqual(@as(u16, 6543), u.port);
}

test "rejects bad input" {
    var a: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer a.deinit();
    const arena = a.allocator();
    try std.testing.expectError(error.InvalidScheme, parse(arena, "mysql://u:p@h/d"));
    try std.testing.expectError(error.MissingUser, parse(arena, "postgres://h/d"));
    try std.testing.expectError(error.MissingUser, parse(arena, "postgres://:p@h/d"));
    try std.testing.expectError(error.MissingHost, parse(arena, "postgres://u:p@/d"));
    try std.testing.expectError(error.InvalidPort, parse(arena, "postgres://u:p@h:abc/d"));
    try std.testing.expectError(error.InvalidPort, parse(arena, "postgres://u:p@h:70000/d"));
    try std.testing.expectError(error.InvalidPercentEncoding, parse(arena, "postgres://u:p%4@h/d"));
    try std.testing.expectError(error.InvalidPercentEncoding, parse(arena, "postgres://u:p%zz@h/d"));
}
