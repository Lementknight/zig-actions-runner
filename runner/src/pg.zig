//! A small PostgreSQL client: wire protocol v3 over TCP, optional TLS, SCRAM-SHA-256 / MD5 /
//! cleartext authentication, the simple query protocol and `COPY ... FROM STDIN`.
//!
//! Pure Zig on std, so the runner stays one static binary (SPEC §7) with no libpq. It is built for
//! one job: writing run state and log batches to Postgres/TimescaleDB (Tiger Data). It is not a
//! general driver: no extended protocol, no prepared statements, no binary formats.
//!
//! Values are inserted with `quote()`d literals (standard_conforming_strings is on by default, so a
//! backslash is an ordinary character and only `'` needs doubling) or sent through COPY's text format.
const std = @import("std");

const Allocator = std.mem.Allocator;
/// std's TLS client plus CertificateRequest support (needed for Tiger Data); see the file header.
const TlsClient = @import("vendor/tls_client.zig");
const Io = std.Io;

pub const SslMode = enum {
    /// Plain TCP. For local development containers.
    disable,
    /// TLS, verifying the certificate chain against the system CAs and the host name (Tiger Data).
    require,
    /// TLS without verifying anything. Encrypts, but gives no protection against impostors.
    no_verify,
};

pub const Config = struct {
    host: []const u8,
    port: u16 = 5432,
    user: []const u8,
    password: []const u8 = "",
    database: []const u8,
    sslmode: SslMode = .require,
    application_name: []const u8 = "zig-actions-runner",
};

pub const ParseError = error{ InvalidUrl, InvalidSslMode, OutOfMemory };

/// `postgres://user:password@host:port/database?sslmode=require|disable|no-verify`. User and password
/// may be percent-encoded. A missing sslmode means `require`.
pub fn parseUrl(arena: Allocator, url: []const u8) ParseError!Config {
    var rest = url;
    inline for (.{ "postgresql://", "postgres://" }) |scheme| {
        if (std.mem.startsWith(u8, rest, scheme)) {
            rest = rest[scheme.len..];
            break;
        }
    } else return error.InvalidUrl;

    var query: []const u8 = "";
    if (std.mem.indexOfScalar(u8, rest, '?')) |q| {
        query = rest[q + 1 ..];
        rest = rest[0..q];
    }
    const slash = std.mem.indexOfScalar(u8, rest, '/') orelse return error.InvalidUrl;
    const authority = rest[0..slash];
    const database = rest[slash + 1 ..];
    if (database.len == 0) return error.InvalidUrl;

    var user: []const u8 = "";
    var password: []const u8 = "";
    var hostport = authority;
    if (std.mem.lastIndexOfScalar(u8, authority, '@')) |at| {
        hostport = authority[at + 1 ..];
        const cred = authority[0..at];
        if (std.mem.indexOfScalar(u8, cred, ':')) |colon| {
            user = try percentDecode(arena, cred[0..colon]);
            password = try percentDecode(arena, cred[colon + 1 ..]);
        } else user = try percentDecode(arena, cred);
    }
    if (user.len == 0) return error.InvalidUrl;

    var host = hostport;
    var port: u16 = 5432;
    if (std.mem.lastIndexOfScalar(u8, hostport, ':')) |colon| {
        host = hostport[0..colon];
        port = std.fmt.parseInt(u16, hostport[colon + 1 ..], 10) catch return error.InvalidUrl;
    }
    if (host.len == 0) return error.InvalidUrl;

    var cfg: Config = .{ .host = host, .port = port, .user = user, .password = password, .database = try percentDecode(arena, database) };
    var params = std.mem.splitScalar(u8, query, '&');
    while (params.next()) |p| {
        const eq = std.mem.indexOfScalar(u8, p, '=') orelse continue;
        if (std.mem.eql(u8, p[0..eq], "sslmode")) cfg.sslmode = try parseSslMode(p[eq + 1 ..]);
    }
    return cfg;
}

pub fn parseSslMode(s: []const u8) ParseError!SslMode {
    if (std.mem.eql(u8, s, "disable")) return .disable;
    if (std.mem.eql(u8, s, "require") or std.mem.eql(u8, s, "verify-full") or std.mem.eql(u8, s, "verify-ca")) return .require;
    if (std.mem.eql(u8, s, "no-verify")) return .no_verify;
    return error.InvalidSslMode;
}

/// The standard libpq variables: PGHOST, PGPORT, PGUSER, PGPASSWORD, PGDATABASE, PGSSLMODE.
/// Returns null unless at least host, user and database are set.
pub fn fromEnv(env: *const std.process.Environ.Map) ParseError!?Config {
    const host = env.get("PGHOST") orelse return null;
    const user = env.get("PGUSER") orelse return null;
    const database = env.get("PGDATABASE") orelse return null;
    return .{
        .host = host,
        .port = if (env.get("PGPORT")) |p| std.fmt.parseInt(u16, p, 10) catch return error.InvalidUrl else 5432,
        .user = user,
        .password = env.get("PGPASSWORD") orelse "",
        .database = database,
        .sslmode = if (env.get("PGSSLMODE")) |m| try parseSslMode(m) else .require,
    };
}

fn percentDecode(arena: Allocator, s: []const u8) ParseError![]const u8 {
    if (std.mem.indexOfScalar(u8, s, '%') == null) return s;
    var out: std.ArrayList(u8) = .empty;
    var i: usize = 0;
    while (i < s.len) : (i += 1) {
        if (s[i] == '%') {
            if (i + 3 > s.len) return error.InvalidUrl;
            const v = std.fmt.parseInt(u8, s[i + 1 .. i + 3], 16) catch return error.InvalidUrl;
            try out.append(arena, v);
            i += 2;
        } else try out.append(arena, s[i]);
    }
    return out.items;
}

/// A SQL string literal: single-quoted with `'` doubled. NUL bytes (which Postgres text cannot hold)
/// and invalid UTF-8 are replaced with U+FFFD. Safe only with standard_conforming_strings = on.
pub fn quote(w: *Io.Writer, s: []const u8) Io.Writer.Error!void {
    try w.writeByte('\'');
    try writeSanitized(w, s, .quote);
    try w.writeByte('\'');
}

const Escape = enum { quote, copy };

/// Writes `s` as valid UTF-8 (bad bytes and NUL become U+FFFD) with the escapes of the given context.
fn writeSanitized(w: *Io.Writer, s: []const u8, mode: Escape) Io.Writer.Error!void {
    var i: usize = 0;
    while (i < s.len) {
        const c = s[i];
        if (c < 0x80) {
            i += 1;
            switch (mode) {
                .quote => if (c == '\'') try w.writeAll("''") else if (c == 0) try w.writeAll("\u{FFFD}") else try w.writeByte(c),
                .copy => switch (c) {
                    0 => try w.writeAll("\u{FFFD}"),
                    '\\' => try w.writeAll("\\\\"),
                    '\n' => try w.writeAll("\\n"),
                    '\r' => try w.writeAll("\\r"),
                    '\t' => try w.writeAll("\\t"),
                    else => try w.writeByte(c),
                },
            }
            continue;
        }
        const n = std.unicode.utf8ByteSequenceLength(c) catch {
            try w.writeAll("\u{FFFD}");
            i += 1;
            continue;
        };
        if (i + n <= s.len and std.unicode.utf8ValidateSlice(s[i .. i + n])) {
            try w.writeAll(s[i .. i + n]);
            i += n;
        } else {
            try w.writeAll("\u{FFFD}");
            i += 1;
        }
    }
}

/// A field of a COPY text-format row (escapes tab, newline, carriage return and backslash).
pub fn copyField(w: *Io.Writer, s: []const u8) Io.Writer.Error!void {
    try writeSanitized(w, s, .copy);
}

// --- messages ---

/// What went wrong on the server side (ErrorResponse fields S, C, M).
pub const ServerError = struct {
    severity: []const u8 = "",
    code: []const u8 = "",
    message: []const u8 = "",
};

pub fn parseErrorFields(body: []const u8) ServerError {
    var e: ServerError = .{};
    var i: usize = 0;
    while (i < body.len and body[i] != 0) {
        const tag = body[i];
        const end = std.mem.indexOfScalarPos(u8, body, i + 1, 0) orelse body.len;
        const val = body[i + 1 .. end];
        switch (tag) {
            'S' => e.severity = val,
            'C' => e.code = val,
            'M' => e.message = val,
            else => {},
        }
        i = end + 1;
    }
    return e;
}

/// A DataRow body: int16 column count, then each column as int32 length (-1 = NULL) and bytes.
pub fn parseDataRow(arena: Allocator, body: []const u8) (error{BadMessage} || Allocator.Error)![]const ?[]const u8 {
    if (body.len < 2) return error.BadMessage;
    const n = std.mem.readInt(u16, body[0..2], .big);
    const cols = try arena.alloc(?[]const u8, n);
    var i: usize = 2;
    for (cols) |*c| {
        if (i + 4 > body.len) return error.BadMessage;
        const len = std.mem.readInt(i32, body[i..][0..4], .big);
        i += 4;
        if (len < 0) {
            c.* = null;
            continue;
        }
        const l: usize = @intCast(len);
        if (i + l > body.len) return error.BadMessage;
        c.* = body[i .. i + l];
        i += l;
    }
    return cols;
}

// --- SCRAM-SHA-256 (RFC 5802 / 7677) ---

const Hmac = std.crypto.auth.hmac.sha2.HmacSha256;
const Sha256 = std.crypto.hash.sha2.Sha256;

pub const Scram = struct {
    /// The SCRAM user name. PostgreSQL ignores it (it uses the startup user), so it is empty on the wire.
    username: []const u8 = "",
    client_nonce: []const u8,
    /// `n=<user>,r=<nonce>`
    client_first_bare: []const u8,

    pub fn init(arena: Allocator, username: []const u8, client_nonce: []const u8) Allocator.Error!Scram {
        return .{
            .username = username,
            .client_nonce = client_nonce,
            .client_first_bare = try std.fmt.allocPrint(arena, "n={s},r={s}", .{ username, client_nonce }),
        };
    }

    /// The initial response: GS2 header (no channel binding) plus the bare message.
    pub fn clientFirst(s: Scram, arena: Allocator) Allocator.Error![]const u8 {
        return std.fmt.allocPrint(arena, "n,,{s}", .{s.client_first_bare});
    }

    pub const Final = struct {
        message: []const u8,
        /// What the server must answer with: `v=<signature>`.
        expected_server_final: []const u8,
    };

    pub const ScramError = error{ BadServerFirst, BadNonce, BadSalt, BadIterations } || Allocator.Error || error{ WeakParameters, OutputTooLong };

    pub fn clientFinal(s: Scram, arena: Allocator, password: []const u8, server_first: []const u8) ScramError!Final {
        var nonce: ?[]const u8 = null;
        var salt_b64: ?[]const u8 = null;
        var iterations: ?u32 = null;
        var parts = std.mem.splitScalar(u8, server_first, ',');
        while (parts.next()) |p| {
            if (p.len < 2 or p[1] != '=') continue;
            switch (p[0]) {
                'r' => nonce = p[2..],
                's' => salt_b64 = p[2..],
                'i' => iterations = std.fmt.parseInt(u32, p[2..], 10) catch return error.BadIterations,
                else => {},
            }
        }
        const combined = nonce orelse return error.BadServerFirst;
        if (!std.mem.startsWith(u8, combined, s.client_nonce)) return error.BadNonce;
        const salt_text = salt_b64 orelse return error.BadServerFirst;
        const iters = iterations orelse return error.BadServerFirst;

        const dec = std.base64.standard.Decoder;
        const salt = try arena.alloc(u8, dec.calcSizeForSlice(salt_text) catch return error.BadSalt);
        dec.decode(salt, salt_text) catch return error.BadSalt;

        var salted: [32]u8 = undefined;
        try std.crypto.pwhash.pbkdf2(&salted, password, salt, iters, Hmac);

        var client_key: [32]u8 = undefined;
        Hmac.create(&client_key, "Client Key", &salted);
        var stored_key: [32]u8 = undefined;
        Sha256.hash(&client_key, &stored_key, .{});

        const without_proof = try std.fmt.allocPrint(arena, "c=biws,r={s}", .{combined});
        const auth_message = try std.fmt.allocPrint(arena, "{s},{s},{s}", .{ s.client_first_bare, server_first, without_proof });

        var client_sig: [32]u8 = undefined;
        Hmac.create(&client_sig, auth_message, &stored_key);
        var proof: [32]u8 = undefined;
        for (&proof, client_key, client_sig) |*p, a, b| p.* = a ^ b;

        var server_key: [32]u8 = undefined;
        Hmac.create(&server_key, "Server Key", &salted);
        var server_sig: [32]u8 = undefined;
        Hmac.create(&server_sig, auth_message, &server_key);

        const enc = std.base64.standard.Encoder;
        const proof_b64 = try arena.alloc(u8, enc.calcSize(proof.len));
        _ = enc.encode(proof_b64, &proof);
        const sig_b64 = try arena.alloc(u8, enc.calcSize(server_sig.len));
        _ = enc.encode(sig_b64, &server_sig);
        return .{
            .message = try std.fmt.allocPrint(arena, "{s},p={s}", .{ without_proof, proof_b64 }),
            .expected_server_final = try std.fmt.allocPrint(arena, "v={s}", .{sig_b64}),
        };
    }
};

// --- the client ---

pub const Error = error{
    /// The server answered with an ErrorResponse; see `Client.last_error`.
    ServerError,
    UnexpectedMessage,
    BadMessage,
    AuthenticationFailed,
    UnsupportedAuthentication,
    TlsRefused,
    TlsFailed,
    ConnectionClosed,
    OutOfMemory,
};

pub const Client = struct {
    gpa: Allocator,
    io: Io,
    stream: Io.net.Stream,
    stream_reader: Io.net.Stream.Reader,
    stream_writer: Io.net.Stream.Writer,
    tls: ?TlsClient = null,
    r: *Io.Reader,
    w: *Io.Writer,
    buffers: []u8,
    ca_bundle: std.crypto.Certificate.Bundle = .empty,
    /// "ERROR 42P01: relation ... does not exist": the last ErrorResponse from the server.
    last_error: []const u8 = "",
    error_buf: [512]u8 = undefined,

    const plain_buf_len = 16 * 1024;

    pub fn connect(gpa: Allocator, io: Io, cfg: Config) !*Client {
        const host: Io.net.HostName = try .init(cfg.host);
        const stream = try host.connect(io, cfg.port, .{ .mode = .stream });
        errdefer stream.close(io);

        const tls_len = TlsClient.min_buffer_len;
        const total = 2 * tls_len + (tls_len + plain_buf_len) + tls_len + 2 * plain_buf_len;
        const buffers = try gpa.alloc(u8, total);
        errdefer gpa.free(buffers);

        const c = try gpa.create(Client);
        errdefer gpa.destroy(c);
        // Socket-level buffers (ciphertext when TLS is on), then the TLS plaintext buffers.
        const sock_r = buffers[0..tls_len];
        const sock_w = buffers[tls_len .. 2 * tls_len];
        c.* = .{
            .gpa = gpa,
            .io = io,
            .stream = stream,
            .stream_reader = stream.reader(io, sock_r),
            .stream_writer = stream.writer(io, sock_w),
            .r = undefined,
            .w = undefined,
            .buffers = buffers,
        };
        c.r = &c.stream_reader.interface;
        c.w = &c.stream_writer.interface;

        errdefer c.ca_bundle.deinit(gpa);
        if (cfg.sslmode != .disable) try c.startTls(cfg, buffers[2 * tls_len ..]);
        try c.startup(cfg);
        return c;
    }

    pub fn close(c: *Client) void {
        c.sendMessage('X', "") catch {};
        c.flush() catch {};
        if (c.tls) |*t| t.end() catch {};
        c.stream_writer.interface.flush() catch {};
        c.stream.close(c.io);
        c.ca_bundle.deinit(c.gpa);
        const gpa = c.gpa;
        gpa.free(c.buffers);
        gpa.destroy(c);
    }

    fn startTls(c: *Client, cfg: Config, rest: []u8) Error!void {
        const tls_len = TlsClient.min_buffer_len;
        // SSLRequest: int32 length 8, int32 code 80877103.
        c.w.writeInt(u32, 8, .big) catch return error.ConnectionClosed;
        c.w.writeInt(u32, 80877103, .big) catch return error.ConnectionClosed;
        c.w.flush() catch return error.ConnectionClosed;
        const answer = c.r.takeByte() catch return error.ConnectionClosed;
        if (answer != 'S') return error.TlsRefused;

        var entropy: [TlsClient.Options.entropy_len]u8 = undefined;
        c.io.random(&entropy);
        const now = Io.Clock.real.now(c.io);
        var opts: TlsClient.Options = .{
            .host = .no_verification,
            .ca = .no_verification,
            .write_buffer = rest[0..tls_len],
            .read_buffer = rest[tls_len .. 2 * tls_len + plain_buf_len],
            .entropy = &entropy,
            .realtime_now = now,
        };
        if (cfg.sslmode == .require) {
            c.ca_bundle.rescan(c.gpa, c.io, now) catch return error.TlsFailed;
            var lock: Io.RwLock = .init;
            opts.host = .{ .explicit = cfg.host };
            opts.ca = .{ .bundle = .{ .gpa = c.gpa, .io = c.io, .lock = &lock, .bundle = &c.ca_bundle } };
        }
        c.tls = TlsClient.init(c.r, c.w, opts) catch return error.TlsFailed;
        c.r = &c.tls.?.reader;
        c.w = &c.tls.?.writer;
    }

    fn flush(c: *Client) Io.Writer.Error!void {
        try c.w.flush();
        if (c.tls != null) try c.stream_writer.interface.flush();
    }

    /// `tag` null is the untagged startup message.
    fn sendMessage(c: *Client, tag: ?u8, body: []const u8) Io.Writer.Error!void {
        if (tag) |t| try c.w.writeByte(t);
        try c.w.writeInt(u32, @intCast(body.len + 4), .big);
        try c.w.writeAll(body);
    }

    const Message = struct { tag: u8, body: []u8 };

    fn readMessage(c: *Client, arena: Allocator) Error!Message {
        const tag = c.r.takeByte() catch return error.ConnectionClosed;
        const len = c.r.takeInt(u32, .big) catch return error.ConnectionClosed;
        if (len < 4) return error.BadMessage;
        const body = try arena.alloc(u8, len - 4);
        c.r.readSliceAll(body) catch return error.ConnectionClosed;
        return .{ .tag = tag, .body = body };
    }

    fn remember(c: *Client, body: []const u8) void {
        const e = parseErrorFields(body);
        c.last_error = std.fmt.bufPrint(&c.error_buf, "{s} {s}: {s}", .{ e.severity, e.code, e.message }) catch c.error_buf[0..0];
    }

    /// A readable form of the last server error ("ERROR 42P01: relation ... does not exist").
    pub fn lastErrorText(c: *const Client) []const u8 {
        return c.last_error;
    }

    fn startup(c: *Client, cfg: Config) !void {
        var arena_state: std.heap.ArenaAllocator = .init(c.gpa);
        defer arena_state.deinit();
        const arena = arena_state.allocator();

        var body: std.Io.Writer.Allocating = .init(arena);
        try body.writer.writeInt(u32, 196608, .big); // protocol 3.0
        for ([_][2][]const u8{
            .{ "user", cfg.user },
            .{ "database", cfg.database },
            .{ "application_name", cfg.application_name },
            .{ "client_encoding", "UTF8" },
        }) |kv| {
            try body.writer.writeAll(kv[0]);
            try body.writer.writeByte(0);
            try body.writer.writeAll(kv[1]);
            try body.writer.writeByte(0);
        }
        try body.writer.writeByte(0);
        try c.sendMessage(null, body.written());
        try c.flush();

        var scram: ?Scram = null;
        var expected_final: ?[]const u8 = null;
        while (true) {
            const m = try c.readMessage(arena);
            switch (m.tag) {
                'R' => {
                    if (m.body.len < 4) return error.BadMessage;
                    const kind = std.mem.readInt(u32, m.body[0..4], .big);
                    switch (kind) {
                        0 => {}, // AuthenticationOk
                        3 => { // cleartext
                            try c.sendMessage('p', try std.fmt.allocPrint(arena, "{s}\x00", .{cfg.password}));
                            try c.flush();
                        },
                        5 => { // MD5: "md5" + md5(md5(password + user) + salt)
                            if (m.body.len < 8) return error.BadMessage;
                            const hex = std.fmt.bytesToHex;
                            var h1: [16]u8 = undefined;
                            var md5 = std.crypto.hash.Md5.init(.{});
                            md5.update(cfg.password);
                            md5.update(cfg.user);
                            md5.final(&h1);
                            const h1_hex = hex(h1, .lower);
                            var h2: [16]u8 = undefined;
                            var md5b = std.crypto.hash.Md5.init(.{});
                            md5b.update(&h1_hex);
                            md5b.update(m.body[4..8]);
                            md5b.final(&h2);
                            const h2_hex = hex(h2, .lower);
                            try c.sendMessage('p', try std.fmt.allocPrint(arena, "md5{s}\x00", .{h2_hex}));
                            try c.flush();
                        },
                        10 => { // SASL: pick SCRAM-SHA-256
                            if (std.mem.indexOf(u8, m.body[4..], "SCRAM-SHA-256") == null) return error.UnsupportedAuthentication;
                            var nonce_raw: [18]u8 = undefined;
                            c.io.random(&nonce_raw);
                            const enc = std.base64.standard.Encoder;
                            const nonce = try arena.alloc(u8, enc.calcSize(nonce_raw.len));
                            _ = enc.encode(nonce, &nonce_raw);
                            const s = try Scram.init(arena, "", nonce);
                            const first = try s.clientFirst(arena);
                            var msg: std.Io.Writer.Allocating = .init(arena);
                            try msg.writer.writeAll("SCRAM-SHA-256\x00");
                            try msg.writer.writeInt(u32, @intCast(first.len), .big);
                            try msg.writer.writeAll(first);
                            try c.sendMessage('p', msg.written());
                            try c.flush();
                            scram = s;
                        },
                        11 => { // SASLContinue: server-first-message
                            const s = scram orelse return error.UnexpectedMessage;
                            const fin = s.clientFinal(arena, cfg.password, m.body[4..]) catch return error.AuthenticationFailed;
                            try c.sendMessage('p', fin.message);
                            try c.flush();
                            expected_final = fin.expected_server_final;
                        },
                        12 => { // SASLFinal: verify the server's signature
                            const want = expected_final orelse return error.UnexpectedMessage;
                            if (!std.mem.eql(u8, m.body[4..], want)) return error.AuthenticationFailed;
                        },
                        else => return error.UnsupportedAuthentication,
                    }
                },
                'E' => {
                    c.remember(m.body);
                    return error.ServerError;
                },
                'Z' => return, // ReadyForQuery: connected
                else => {}, // ParameterStatus (S), BackendKeyData (K), NoticeResponse (N)
            }
        }
    }

    /// Runs one or more statements, discarding any rows.
    pub fn exec(c: *Client, sql: []const u8) Error!void {
        var arena_state: std.heap.ArenaAllocator = .init(c.gpa);
        defer arena_state.deinit();
        _ = try c.query(arena_state.allocator(), sql);
    }

    pub const Rows = []const []const ?[]const u8;

    /// Runs a statement and returns all rows of its last result as text. Rows live in `arena`.
    pub fn query(c: *Client, arena: Allocator, sql: []const u8) Error!Rows {
        var q: std.Io.Writer.Allocating = .init(arena);
        q.writer.writeAll(sql) catch return error.OutOfMemory;
        q.writer.writeByte(0) catch return error.OutOfMemory;
        c.sendMessage('Q', q.written()) catch return error.ConnectionClosed;
        c.flush() catch return error.ConnectionClosed;
        return c.readResults(arena);
    }

    fn readResults(c: *Client, arena: Allocator) Error!Rows {
        var rows: std.ArrayList([]const ?[]const u8) = .empty;
        var failed = false;
        while (true) {
            const m = try c.readMessage(arena);
            switch (m.tag) {
                'D' => rows.append(arena, parseDataRow(arena, m.body) catch return error.BadMessage) catch return error.OutOfMemory,
                'T' => rows.clearRetainingCapacity(), // a new result set starts
                'E' => {
                    c.remember(m.body);
                    failed = true; // keep reading until ReadyForQuery so the connection stays usable
                },
                'Z' => {
                    if (failed) return error.ServerError;
                    return rows.items;
                },
                else => {}, // CommandComplete (C), EmptyQueryResponse (I), NoticeResponse (N), ...
            }
        }
    }

    /// `sql` must be `COPY ... FROM STDIN` in text format. Returns the number of rows the server stored.
    pub fn copyIn(c: *Client, sql: []const u8, data: []const u8) Error!u64 {
        var arena_state: std.heap.ArenaAllocator = .init(c.gpa);
        defer arena_state.deinit();
        const arena = arena_state.allocator();

        var q: std.Io.Writer.Allocating = .init(arena);
        q.writer.writeAll(sql) catch return error.OutOfMemory;
        q.writer.writeByte(0) catch return error.OutOfMemory;
        c.sendMessage('Q', q.written()) catch return error.ConnectionClosed;
        c.flush() catch return error.ConnectionClosed;

        // Wait for CopyInResponse ('G'); an error here means the statement was rejected.
        while (true) {
            const m = try c.readMessage(arena);
            switch (m.tag) {
                'G' => break,
                'E' => {
                    c.remember(m.body);
                    try c.drainToReady(arena);
                    return error.ServerError;
                },
                else => {},
            }
        }
        var off: usize = 0;
        while (off < data.len) {
            const n = @min(data.len - off, 64 * 1024);
            c.sendMessage('d', data[off .. off + n]) catch return error.ConnectionClosed;
            off += n;
        }
        c.sendMessage('c', "") catch return error.ConnectionClosed;
        c.flush() catch return error.ConnectionClosed;

        var copied: u64 = 0;
        var failed = false;
        while (true) {
            const m = try c.readMessage(arena);
            switch (m.tag) {
                'C' => { // CommandComplete: "COPY <n>"
                    const tag = std.mem.sliceTo(m.body, 0);
                    if (std.mem.startsWith(u8, tag, "COPY ")) copied = std.fmt.parseInt(u64, tag[5..], 10) catch 0;
                },
                'E' => {
                    c.remember(m.body);
                    failed = true;
                },
                'Z' => {
                    if (failed) return error.ServerError;
                    return copied;
                },
                else => {},
            }
        }
    }

    fn drainToReady(c: *Client, arena: Allocator) Error!void {
        while (true) {
            const m = try c.readMessage(arena);
            if (m.tag == 'Z') return;
        }
    }
};

// --- tests ---

test "parseUrl: full form, percent-encoding, defaults" {
    var a: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer a.deinit();
    const c = try parseUrl(a.allocator(), "postgres://tsdbadmin:p%40ss%3Aw%2Frd@abc.tsdb.cloud.timescale.com:35060/tsdb?sslmode=require");
    try std.testing.expectEqualStrings("tsdbadmin", c.user);
    try std.testing.expectEqualStrings("p@ss:w/rd", c.password);
    try std.testing.expectEqualStrings("abc.tsdb.cloud.timescale.com", c.host);
    try std.testing.expectEqual(@as(u16, 35060), c.port);
    try std.testing.expectEqualStrings("tsdb", c.database);
    try std.testing.expectEqual(SslMode.require, c.sslmode);

    const d = try parseUrl(a.allocator(), "postgresql://u@localhost/db?sslmode=disable");
    try std.testing.expectEqual(@as(u16, 5432), d.port);
    try std.testing.expectEqualStrings("", d.password);
    try std.testing.expectEqual(SslMode.disable, d.sslmode);

    try std.testing.expectEqual(SslMode.require, (try parseUrl(a.allocator(), "postgres://u:p@h/db")).sslmode);
    try std.testing.expectError(error.InvalidUrl, parseUrl(a.allocator(), "mysql://u:p@h/db"));
    try std.testing.expectError(error.InvalidUrl, parseUrl(a.allocator(), "postgres://h/db"));
    try std.testing.expectError(error.InvalidUrl, parseUrl(a.allocator(), "postgres://u:p@h:notaport/db"));
    try std.testing.expectError(error.InvalidSslMode, parseUrl(a.allocator(), "postgres://u:p@h/db?sslmode=maybe"));
}

test "fromEnv reads the libpq variables" {
    var a: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer a.deinit();
    var env: std.process.Environ.Map = .init(a.allocator());
    try std.testing.expect((try fromEnv(&env)) == null);
    try env.put("PGHOST", "h");
    try env.put("PGPORT", "5555");
    try env.put("PGUSER", "u");
    try env.put("PGPASSWORD", "p w");
    try env.put("PGDATABASE", "d");
    try env.put("PGSSLMODE", "disable");
    const c = (try fromEnv(&env)).?;
    try std.testing.expectEqual(@as(u16, 5555), c.port);
    try std.testing.expectEqualStrings("p w", c.password);
    try std.testing.expectEqual(SslMode.disable, c.sslmode);
}

test "quote doubles quotes and repairs NUL and invalid UTF-8" {
    var buf: [128]u8 = undefined;
    var w: Io.Writer = .fixed(&buf);
    try quote(&w, "it's a \\ test\x00 and \xff bad");
    try std.testing.expectEqualStrings("'it''s a \\ test\u{FFFD} and \u{FFFD} bad'", w.buffered());
    var w2: Io.Writer = .fixed(&buf);
    try quote(&w2, "héllo ✓");
    try std.testing.expectEqualStrings("'héllo ✓'", w2.buffered());
}

test "copyField escapes the COPY text format" {
    var buf: [128]u8 = undefined;
    var w: Io.Writer = .fixed(&buf);
    try copyField(&w, "a\tb\nc\r\\d\x1b[31m");
    try std.testing.expectEqualStrings("a\\tb\\nc\\r\\\\d\x1b[31m", w.buffered());
}

test "ErrorResponse and DataRow parsing" {
    var a: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer a.deinit();
    const e = parseErrorFields("SERROR\x00C42P01\x00Mrelation \"x\" does not exist\x00\x00");
    try std.testing.expectEqualStrings("ERROR", e.severity);
    try std.testing.expectEqualStrings("42P01", e.code);
    try std.testing.expectEqualStrings("relation \"x\" does not exist", e.message);

    // two columns: "ab" and NULL
    const row = try parseDataRow(a.allocator(), "\x00\x02\x00\x00\x00\x02ab\xff\xff\xff\xff");
    try std.testing.expectEqual(@as(usize, 2), row.len);
    try std.testing.expectEqualStrings("ab", row[0].?);
    try std.testing.expect(row[1] == null);
    try std.testing.expectError(error.BadMessage, parseDataRow(a.allocator(), "\x00\x01\x00\x00\x00\x09ab"));
}

test "SCRAM-SHA-256 matches the RFC 7677 test vector" {
    var a: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer a.deinit();
    const arena = a.allocator();
    const s = try Scram.init(arena, "user", "rOprNGfwEbeRWgbNEkqO");
    try std.testing.expectEqualStrings("n,,n=user,r=rOprNGfwEbeRWgbNEkqO", try s.clientFirst(arena));
    const fin = try s.clientFinal(arena, "pencil", "r=rOprNGfwEbeRWgbNEkqO%hvYDpWUa2RaTCAfuxFIlj)hNlF$k0,s=W22ZaJ0SNY7soEsUEjb6gQ==,i=4096");
    try std.testing.expectEqualStrings("c=biws,r=rOprNGfwEbeRWgbNEkqO%hvYDpWUa2RaTCAfuxFIlj)hNlF$k0,p=dHzbZapWIk4jUhN+Ute9ytag9zjfMHgsqmmiz7AndVQ=", fin.message);
    try std.testing.expectEqualStrings("v=6rriTRBi23WpRR/wtup+mMhUZUn/dB5nLTJRsjl95G4=", fin.expected_server_final);
    // A server that does not echo our nonce is rejected.
    try std.testing.expectError(error.BadNonce, s.clientFinal(arena, "pencil", "r=someoneelse,s=W22ZaJ0SNY7soEsUEjb6gQ==,i=4096"));
}

/// Integration tests run only when PG* variables (or ZIG_TEST_PG_URL) point at a database; the local
/// development container and the CI workflow set them. Otherwise they are skipped.
fn testConfig(arena: Allocator) !Config {
    var env = try std.testing.environ.createMap(arena);
    if (env.get("ZIG_TEST_PG_URL")) |url| return parseUrl(arena, url);
    return (try fromEnv(&env)) orelse error.SkipZigTest;
}

test "integration: connect, query, error recovery, COPY (needs a database)" {
    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const cfg = try testConfig(arena);

    const c = try Client.connect(std.testing.allocator, std.testing.io, cfg);
    defer c.close();

    const rows = try c.query(arena, "select 1 as n, 'héllo'::text, null::text");
    try std.testing.expectEqual(@as(usize, 1), rows.len);
    try std.testing.expectEqualStrings("1", rows[0][0].?);
    try std.testing.expectEqualStrings("héllo", rows[0][1].?);
    try std.testing.expect(rows[0][2] == null);

    // A failing statement reports the server's message and leaves the connection usable.
    try std.testing.expectError(error.ServerError, c.exec("select * from zig_pg_no_such_table"));
    try std.testing.expect(std.mem.indexOf(u8, c.lastErrorText(), "zig_pg_no_such_table") != null);
    try std.testing.expectEqualStrings("2", (try c.query(arena, "select 2"))[0][0].?);

    // Quoting round-trips hostile strings, and COPY stores what was sent.
    try c.exec("create temp table zig_pg_t (id int, line text)");
    var ins: std.Io.Writer.Allocating = .init(arena);
    try ins.writer.writeAll("insert into zig_pg_t values (1, ");
    try quote(&ins.writer, "it's \\ \"quoted\" \x00 \xff");
    try ins.writer.writeAll(")");
    try c.exec(ins.written());
    try std.testing.expectEqualStrings("it's \\ \"quoted\" \u{FFFD} \u{FFFD}", (try c.query(arena, "select line from zig_pg_t where id = 1"))[0][0].?);

    var data: std.Io.Writer.Allocating = .init(arena);
    for (2..52) |i| {
        try data.writer.print("{d}\t", .{i});
        try copyField(&data.writer, "tab\there\nnewline \\ back");
        try data.writer.writeByte('\n');
    }
    try std.testing.expectEqual(@as(u64, 50), try c.copyIn("copy zig_pg_t (id, line) from stdin", data.written()));
    try std.testing.expectEqualStrings("51", (try c.query(arena, "select count(*) from zig_pg_t"))[0][0].?);
    try std.testing.expectEqualStrings("tab\there\nnewline \\ back", (try c.query(arena, "select line from zig_pg_t where id = 7"))[0][0].?);

    // A rejected COPY (bad row) fails cleanly and the connection survives.
    try std.testing.expectError(error.ServerError, c.copyIn("copy zig_pg_t (id, line) from stdin", "not-a-number\tx\n"));
    try std.testing.expectEqualStrings("51", (try c.query(arena, "select count(*) from zig_pg_t"))[0][0].?);
}

test "integration: a wrong password is refused" {
    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var cfg = try testConfig(arena);
    cfg.password = "definitely-not-the-password";
    try std.testing.expectError(error.ServerError, Client.connect(std.testing.allocator, std.testing.io, cfg));
}
