//! Runner credentials and the OAuth client-credentials exchange (DESIGN §6 step 3).
//! Field names are from `actions/runner` source and unverified against live GitHub.
const std = @import("std");
const rsa_sign = @import("rsa_sign.zig");
const jitconfig = @import("jitconfig.zig");

const Allocator = std.mem.Allocator;
const b64url = std.base64.url_safe_no_pad;
const b64 = std.base64.standard;

pub const Credentials = struct {
    client_id: []const u8,
    authorization_url: []const u8,
    /// Big-endian RSA modulus and private exponent.
    modulus: []const u8,
    private_exponent: []const u8,
};

pub const Error = error{ MissingFile, BadCredentials, UnsupportedScheme, TokenRejected, BadTokenResponse } ||
    Allocator.Error || std.http.Client.FetchError || rsa_sign.Error;

pub fn findFile(files: []const jitconfig.File, name: []const u8) ?[]const u8 {
    for (files) |f| if (std.mem.eql(u8, f.name, name)) return f.content;
    return null;
}

pub fn parseCredentials(arena: Allocator, files: []const jitconfig.File) Error!Credentials {
    const cred_json = findFile(files, ".credentials") orelse return error.MissingFile;
    const rsa_json = findFile(files, ".credentials_rsaparams") orelse return error.MissingFile;

    const Cred = struct {
        Scheme: []const u8,
        Data: struct { ClientId: []const u8, AuthorizationUrl: []const u8 },
    };
    const cred = std.json.parseFromSliceLeaky(Cred, arena, cred_json, .{ .ignore_unknown_fields = true }) catch return error.BadCredentials;
    if (!std.ascii.eqlIgnoreCase(cred.Scheme, "OAuth")) return error.UnsupportedScheme;

    const Rsa = struct { modulus: []const u8, d: []const u8 };
    const rsa = std.json.parseFromSliceLeaky(Rsa, arena, rsa_json, .{ .ignore_unknown_fields = true }) catch return error.BadCredentials;

    return .{
        .client_id = cred.Data.ClientId,
        .authorization_url = cred.Data.AuthorizationUrl,
        .modulus = try decodeB64(arena, rsa.modulus),
        .private_exponent = try decodeB64(arena, rsa.d),
    };
}

fn decodeB64(arena: Allocator, s: []const u8) Error![]u8 {
    const buf = try arena.alloc(u8, b64.Decoder.calcSizeForSlice(s) catch return error.BadCredentials);
    b64.Decoder.decode(buf, s) catch return error.BadCredentials;
    return buf;
}

/// Builds an RS256 client-assertion JWT. `now` is unix seconds.
pub fn buildJwt(arena: Allocator, creds: Credentials, now: i64, jti: []const u8) Error![]const u8 {
    const header = "{\"alg\":\"RS256\",\"typ\":\"JWT\"}";
    const claims = try std.fmt.allocPrint(
        arena,
        "{{\"sub\":\"{s}\",\"iss\":\"{s}\",\"aud\":\"{s}\",\"nbf\":{d},\"iat\":{d},\"exp\":{d},\"jti\":\"{s}\"}}",
        .{ creds.client_id, creds.client_id, creds.authorization_url, now, now, now + 300, jti },
    );

    const h_len = b64url.Encoder.calcSize(header.len);
    const c_len = b64url.Encoder.calcSize(claims.len);
    var signing_input = try arena.alloc(u8, h_len + 1 + c_len);
    _ = b64url.Encoder.encode(signing_input[0..h_len], header);
    signing_input[h_len] = '.';
    _ = b64url.Encoder.encode(signing_input[h_len + 1 ..], claims);

    var sig_buf: [512]u8 = undefined;
    const sig = try rsa_sign.signSha256(&sig_buf, creds.modulus, creds.private_exponent, signing_input);

    const sig_len = b64url.Encoder.calcSize(sig.len);
    const out = try arena.alloc(u8, signing_input.len + 1 + sig_len);
    @memcpy(out[0..signing_input.len], signing_input);
    out[signing_input.len] = '.';
    _ = b64url.Encoder.encode(out[signing_input.len + 1 ..], sig);
    return out;
}

/// Exchanges the JWT for an access token (`client_credentials` + `jwt-bearer` assertion).
pub fn fetchAccessToken(arena: Allocator, io: std.Io, creds: Credentials, jwt: []const u8, status_out: *std.http.Status) Error![]const u8 {
    const form = try std.fmt.allocPrint(
        arena,
        "grant_type=client_credentials&client_assertion_type=urn%3Aietf%3Aparams%3Aoauth%3Aclient-assertion-type%3Ajwt-bearer&client_assertion={s}",
        .{jwt},
    );

    var local: std.http.Client = .{ .allocator = arena, .io = io };
    defer local.deinit();
    const client = @import("http.zig").client(&local);

    var resp: std.Io.Writer.Allocating = .init(arena);
    const result = try client.fetch(.{
        .location = .{ .url = creds.authorization_url },
        .method = .POST,
        .payload = form,
        .headers = .{ .content_type = .{ .override = "application/x-www-form-urlencoded" } },
        .extra_headers = &.{.{ .name = "Accept", .value = "application/json" }},
        .response_writer = &resp.writer,
    });
    status_out.* = result.status;
    if (result.status.class() != .success) return error.TokenRejected;
    return parseTokenResponse(arena, resp.written());
}

pub fn parseTokenResponse(arena: Allocator, body: []const u8) Error![]const u8 {
    const R = struct { access_token: []const u8 };
    const r = std.json.parseFromSliceLeaky(R, arena, body, .{ .ignore_unknown_fields = true }) catch return error.BadTokenResponse;
    return r.access_token;
}

test "parse credentials and build a verifiable JWT" {
    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    // Reuse the signer's throwaway test key by re-deriving it from the same hex.
    const creds: Credentials = .{
        .client_id = "cid",
        .authorization_url = "https://example.test/oauth2/token",
        .modulus = &rsa_sign.test_n,
        .private_exponent = &rsa_sign.test_d,
    };
    const jwt = try buildJwt(arena, creds, 1000, "jti-1");

    var parts = std.mem.splitScalar(u8, jwt, '.');
    const h = parts.next().?;
    const c = parts.next().?;
    const s = parts.next().?;
    try std.testing.expect(parts.next() == null);

    var claims_buf: [256]u8 = undefined;
    const claims_len = try b64url.Decoder.calcSizeForSlice(c);
    try b64url.Decoder.decode(claims_buf[0..claims_len], c);
    try std.testing.expectEqualStrings(
        "{\"sub\":\"cid\",\"iss\":\"cid\",\"aud\":\"https://example.test/oauth2/token\",\"nbf\":1000,\"iat\":1000,\"exp\":1300,\"jti\":\"jti-1\"}",
        claims_buf[0..claims_len],
    );

    var sig: [256]u8 = undefined;
    try b64url.Decoder.decode(&sig, s);
    const pk = try std.crypto.Certificate.rsa.PublicKey.fromBytes(&.{ 0x01, 0x00, 0x01 }, &rsa_sign.test_n);
    const signed = jwt[0 .. h.len + 1 + c.len];
    try std.crypto.Certificate.rsa.PKCS1v1_5Signature.verify(256, &sig, signed, pk, std.crypto.hash.sha2.Sha256);
}

test "parseCredentials from file contents" {
    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();
    const files = [_]jitconfig.File{
        .{ .name = ".credentials", .content = "{\"Scheme\":\"OAuth\",\"Data\":{\"ClientId\":\"abc\",\"AuthorizationUrl\":\"https://x/t\",\"RequireFipsCryptography\":\"False\"}}" },
        .{ .name = ".credentials_rsaparams", .content = "{\"d\":\"AQID\",\"modulus\":\"BAUG\",\"exponent\":\"AQAB\"}" },
    };
    const c = try parseCredentials(arena_state.allocator(), &files);
    try std.testing.expectEqualStrings("abc", c.client_id);
    try std.testing.expectEqualSlices(u8, &.{ 4, 5, 6 }, c.modulus);
    try std.testing.expectEqualSlices(u8, &.{ 1, 2, 3 }, c.private_exponent);
}

test "token response" {
    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    try std.testing.expectEqualStrings("T", try parseTokenResponse(a, "{\"access_token\":\"T\",\"expires_in\":3600}"));
    try std.testing.expectError(error.BadTokenResponse, parseTokenResponse(a, "{}"));
}
