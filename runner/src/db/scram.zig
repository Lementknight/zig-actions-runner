//! SCRAM-SHA-256 client side (RFC 5802, RFC 7677), the authentication Tiger Data and every modern
//! PostgreSQL use. Pure functions over std.crypto so they test against the RFC vector without a
//! server. The caller does the PostgreSQL framing (AuthenticationSASL and friends) in Client.zig.
//!
//! Passwords are used as given: PostgreSQL applies SASLprep to a password that is valid UTF-8, which
//! is the identity for ASCII; a non-ASCII password with characters SASLprep would change is not
//! supported here.
const std = @import("std");

const Allocator = std.mem.Allocator;
const Hmac = std.crypto.auth.hmac.sha2.HmacSha256;
const Sha256 = std.crypto.hash.sha2.Sha256;
const b64 = std.base64.standard;

pub const key_len = Hmac.mac_length; // 32

pub const Error = error{
    /// The server's first message was not `r=...,s=...,i=...`, or carried a mandatory extension.
    InvalidServerFirst,
    /// The server echoed a nonce that does not start with ours.
    NonceMismatch,
    /// The server's `v=` signature did not match: wrong server, or a tampered exchange.
    ServerSignatureMismatch,
    OutOfMemory,
};

/// `client-first-message`: `n,,n=<user>,r=<nonce>` (gs2 header `n,,` = no channel binding).
/// Returns the whole message; `clientFirstBare` slices off the header for the auth message.
pub fn clientFirstMessage(arena: Allocator, user: []const u8, client_nonce: []const u8) Allocator.Error![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    try out.appendSlice(arena, "n,,n=");
    // RFC 5802 §5.1: "=" and "," in the name are escaped.
    for (user) |c| switch (c) {
        '=' => try out.appendSlice(arena, "=3D"),
        ',' => try out.appendSlice(arena, "=2C"),
        else => try out.append(arena, c),
    };
    try out.appendSlice(arena, ",r=");
    try out.appendSlice(arena, client_nonce);
    return out.items;
}

pub fn clientFirstBare(client_first: []const u8) []const u8 {
    return client_first["n,,".len..];
}

pub const ServerFirst = struct {
    /// Client nonce followed by the server's addition, exactly as the server sent it.
    nonce: []const u8,
    /// Decoded salt.
    salt: []const u8,
    iterations: u32,
};

pub fn parseServerFirst(arena: Allocator, msg: []const u8, client_nonce: []const u8) Error!ServerFirst {
    var out: ServerFirst = .{ .nonce = "", .salt = "", .iterations = 0 };
    var saw_nonce = false;
    var saw_salt = false;
    var it = std.mem.splitScalar(u8, msg, ',');
    while (it.next()) |attr| {
        if (attr.len < 2 or attr[1] != '=') return error.InvalidServerFirst;
        const val = attr[2..];
        switch (attr[0]) {
            'm' => return error.InvalidServerFirst, // mandatory extension we do not know
            'r' => {
                out.nonce = val;
                saw_nonce = true;
            },
            's' => {
                const n = b64.Decoder.calcSizeForSlice(val) catch return error.InvalidServerFirst;
                const buf = try arena.alloc(u8, n);
                b64.Decoder.decode(buf, val) catch return error.InvalidServerFirst;
                out.salt = buf;
                saw_salt = true;
            },
            'i' => out.iterations = std.fmt.parseInt(u32, val, 10) catch return error.InvalidServerFirst,
            else => {}, // optional extensions are ignored
        }
    }
    if (!saw_nonce or !saw_salt or out.iterations == 0) return error.InvalidServerFirst;
    if (!std.mem.startsWith(u8, out.nonce, client_nonce) or out.nonce.len == client_nonce.len) return error.NonceMismatch;
    return out;
}

pub const ClientFinal = struct {
    /// `client-final-message`, to send as the SASLResponse.
    message: []const u8,
    /// What the server must answer in `v=`; check with `verifyServerFinal`.
    server_signature: [key_len]u8,
};

/// Derives the proof. `server_first_raw` is the server's message verbatim (it is part of the
/// signed auth message), `server_first` its parsed form.
pub fn clientFinalMessage(
    arena: Allocator,
    password: []const u8,
    client_first: []const u8,
    server_first_raw: []const u8,
    server_first: ServerFirst,
) Allocator.Error!ClientFinal {
    // client-final-message-without-proof: "c=biws" is base64("n,,"), the gs2 header again.
    const without_proof = try std.fmt.allocPrint(arena, "c=biws,r={s}", .{server_first.nonce});
    const auth_message = try std.mem.concat(arena, u8, &.{ clientFirstBare(client_first), ",", server_first_raw, ",", without_proof });

    var salted: [key_len]u8 = undefined;
    // Weak parameters (empty salt, 0 rounds) are refused by pbkdf2; the server never sends those.
    std.crypto.pwhash.pbkdf2(&salted, password, server_first.salt, server_first.iterations, Hmac) catch unreachable;

    var client_key: [key_len]u8 = undefined;
    Hmac.create(&client_key, "Client Key", &salted);
    var stored_key: [key_len]u8 = undefined;
    Sha256.hash(&client_key, &stored_key, .{});
    var client_sig: [key_len]u8 = undefined;
    Hmac.create(&client_sig, auth_message, &stored_key);
    var proof: [key_len]u8 = undefined;
    for (&proof, client_key, client_sig) |*p, k, s| p.* = k ^ s;

    var server_key: [key_len]u8 = undefined;
    Hmac.create(&server_key, "Server Key", &salted);
    var server_sig: [key_len]u8 = undefined;
    Hmac.create(&server_sig, auth_message, &server_key);

    var proof_b64: [b64.Encoder.calcSize(key_len)]u8 = undefined;
    const message = try std.mem.concat(arena, u8, &.{ without_proof, ",p=", b64.Encoder.encode(&proof_b64, &proof) });
    return .{ .message = message, .server_signature = server_sig };
}

/// Checks the server's `v=<base64>` against the signature derived in `clientFinalMessage`.
pub fn verifyServerFinal(msg: []const u8, expected: [key_len]u8) Error!void {
    if (!std.mem.startsWith(u8, msg, "v=")) return error.ServerSignatureMismatch;
    const val = msg[2..];
    var got: [key_len]u8 = undefined;
    const n = b64.Decoder.calcSizeForSlice(val) catch return error.ServerSignatureMismatch;
    if (n != key_len) return error.ServerSignatureMismatch;
    b64.Decoder.decode(&got, val) catch return error.ServerSignatureMismatch;
    if (!std.crypto.timing_safe.eql([key_len]u8, got, expected)) return error.ServerSignatureMismatch;
}

/// Fills `out` with a base64 nonce from `random_bytes` (printable, no commas, as RFC 5802 needs).
pub fn nonceFromBytes(random_bytes: []const u8, out: []u8) []const u8 {
    return b64.Encoder.encode(out, random_bytes);
}

// RFC 7677 §3 test vector (user "user", password "pencil").
const vec_client_nonce = "rOprNGfwEbeRWgbNEkqO";
const vec_server_first = "r=rOprNGfwEbeRWgbNEkqO%hvYDpWUa2RaTCAfuxFIlj)hNlF$k0,s=W22ZaJ0SNY7soEsUEjb6gQ==,i=4096";

test "RFC 7677 vector: client first, proof and server signature" {
    var a: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer a.deinit();
    const arena = a.allocator();
    const first = try clientFirstMessage(arena, "user", vec_client_nonce);
    try std.testing.expectEqualStrings("n,,n=user,r=rOprNGfwEbeRWgbNEkqO", first);
    const sf = try parseServerFirst(arena, vec_server_first, vec_client_nonce);
    try std.testing.expectEqual(@as(u32, 4096), sf.iterations);
    try std.testing.expectEqual(@as(usize, 16), sf.salt.len);
    const fin = try clientFinalMessage(arena, "pencil", first, vec_server_first, sf);
    try std.testing.expectEqualStrings(
        "c=biws,r=rOprNGfwEbeRWgbNEkqO%hvYDpWUa2RaTCAfuxFIlj)hNlF$k0,p=dHzbZapWIk4jUhN+Ute9ytag9zjfMHgsqmmiz7AndVQ=",
        fin.message,
    );
    try verifyServerFinal("v=6rriTRBi23WpRR/wtup+mMhUZUn/dB5nLTJRsjl95G4=", fin.server_signature);
    try std.testing.expectError(error.ServerSignatureMismatch, verifyServerFinal("v=6rriTRBi23WpRR/wtup+mMhUZUn/dB5nLTJRsjl95G5=", fin.server_signature));
    try std.testing.expectError(error.ServerSignatureMismatch, verifyServerFinal("e=other-error", fin.server_signature));
}

test "server first message validation" {
    var a: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer a.deinit();
    const arena = a.allocator();
    try std.testing.expectError(error.NonceMismatch, parseServerFirst(arena, "r=othernonceXYZ,s=W22ZaJ0SNY7soEsUEjb6gQ==,i=4096", vec_client_nonce));
    try std.testing.expectError(error.NonceMismatch, parseServerFirst(arena, "r=" ++ vec_client_nonce ++ ",s=W22ZaJ0SNY7soEsUEjb6gQ==,i=4096", vec_client_nonce));
    try std.testing.expectError(error.InvalidServerFirst, parseServerFirst(arena, "m=ext,r=" ++ vec_client_nonce ++ "abc,s=W22ZaJ0SNY7soEsUEjb6gQ==,i=4096", vec_client_nonce));
    try std.testing.expectError(error.InvalidServerFirst, parseServerFirst(arena, "r=" ++ vec_client_nonce ++ "abc,i=4096", vec_client_nonce));
    try std.testing.expectError(error.InvalidServerFirst, parseServerFirst(arena, "r=" ++ vec_client_nonce ++ "abc,s=W22ZaJ0SNY7soEsUEjb6gQ==,i=0", vec_client_nonce));
    try std.testing.expectError(error.InvalidServerFirst, parseServerFirst(arena, "r=" ++ vec_client_nonce ++ "abc,s=!!!,i=4096", vec_client_nonce));
}

test "user name escaping" {
    var a: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer a.deinit();
    const first = try clientFirstMessage(a.allocator(), "a=b,c", "nonce");
    try std.testing.expectEqualStrings("n,,n=a=3Db=2Cc,r=nonce", first);
    try std.testing.expectEqualStrings("n=a=3Db=2Cc,r=nonce", clientFirstBare(first));
}
