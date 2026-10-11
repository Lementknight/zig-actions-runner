//! RSASSA-PKCS1-v1_5 / SHA-256 signing (RS256). Std only ships verification.
const std = @import("std");
const ff = std.crypto.ff;
const Sha256 = std.crypto.hash.sha2.Sha256;

const max_bits = 4096;
const Modulus = ff.Modulus(max_bits);

/// DER prefix of DigestInfo for SHA-256 (RFC 8017 §9.2 note 1).
const digest_info_prefix = [_]u8{ 0x30, 0x31, 0x30, 0x0d, 0x06, 0x09, 0x60, 0x86, 0x48, 0x01, 0x65, 0x03, 0x04, 0x02, 0x01, 0x05, 0x00, 0x04, 0x20 };

pub const Error = error{ ModulusTooSmall, InvalidKey, BufferTooSmall };

/// Signs `msg`. `n` and `d` are big-endian with no leading zeros required.
/// Writes `n.len` (after trimming leading zeros) bytes to `out` and returns that slice.
pub fn signSha256(out: []u8, n_be: []const u8, d_be: []const u8, msg: []const u8) Error![]u8 {
    const n = trimZeros(n_be);
    const d = trimZeros(d_be);
    if (n.len > max_bits / 8) return error.InvalidKey;
    if (out.len < n.len) return error.BufferTooSmall;
    const t_len = digest_info_prefix.len + Sha256.digest_length;
    if (n.len < t_len + 11) return error.ModulusTooSmall;

    var em_buf: [max_bits / 8]u8 = undefined;
    const em = em_buf[0..n.len];
    em[0] = 0x00;
    em[1] = 0x01;
    const ps_end = n.len - t_len - 1;
    @memset(em[2..ps_end], 0xff);
    em[ps_end] = 0x00;
    @memcpy(em[ps_end + 1 ..][0..digest_info_prefix.len], &digest_info_prefix);
    Sha256.hash(msg, em[n.len - Sha256.digest_length ..][0..Sha256.digest_length], .{});

    const m = Modulus.fromBytes(n, .big) catch return error.InvalidKey;
    const x = Modulus.Fe.fromBytes(m, em, .big) catch return error.InvalidKey;
    const s = m.powWithEncodedExponent(x, d, .big) catch return error.InvalidKey;
    const sig = out[0..n.len];
    s.toBytes(sig, .big) catch return error.InvalidKey;
    return sig;
}

fn trimZeros(b: []const u8) []const u8 {
    var i: usize = 0;
    while (i < b.len and b[i] == 0) i += 1;
    return b[i..];
}

/// Throwaway 2048-bit key used only by tests.
pub const test_n = hex("9e9d979da53090d50ba2979f81515d050f52d999a73563a5eee67f25ad4342fdc61ed0468e472405beb8aad5eee25703ca0eb47dc2784a344ef5284c769cd0fd233fcdcc908074c1e58d53610225626a8f01a398d7b4ada90b54efedb8f6ea25ac1aa9632a4f1701b518f4e02a57958f66e7171d0b55cbcc16f6a791fcd1f8d54fa54bc8f8ebea74c6038318b7c9db48b821ef088519683d9f11cb16714f94c5480cb89786bc71dbb6b3f5943ce6c3b552bfa8da747bc41032d5f4ee660c6873aa15d82045b8e9955786585a8cde776049caa7f8842590e77f002fa659335d0b385a3385543bdf9c11807a3040e33006661ad84a397bfd202db123fde75c2b07");
pub const test_d = hex("0d396662a65b1e3824f8315c03141d854679c9da9dae3dd89fca67df644aaf5329297883e968d500059eafdf964318ae203289a9d284e4eae78a5909c6f9dc12bed59afaeb314a8abff0c07ade0aefe1a27aa8811dbada9fb56a2776d26d03a89068c8a693e8742a9846b463dc23e13c4b8008d54b14a42127e8f89f9b4c864a60e22337949891805a211698a52587e19300fe6b708c2805531501eecce796961844279b0f0437a3d63747ecb737a6a804c1914584bf70ecce5e92569fb4be6c126e36e7b5ec0a5111c31ce7cd92fb4c68efad0322656de7155d9d10a3cb98e660990f25080320ddc87bee1269ee4caf329c053a6642a555d190ec0dac911cc1");

fn hex(comptime s: []const u8) [s.len / 2]u8 {
    var out: [s.len / 2]u8 = undefined;
    _ = std.fmt.hexToBytes(&out, s) catch unreachable;
    return out;
}

test "signature verifies with std RSA verifier" {
    const n = test_n;
    const d = test_d;

    var sig_buf: [256]u8 = undefined;
    const sig = try signSha256(&sig_buf, &n, &d, "header.payload");
    try std.testing.expectEqual(@as(usize, 256), sig.len);

    const pk = try std.crypto.Certificate.rsa.PublicKey.fromBytes(&.{ 0x01, 0x00, 0x01 }, &n);
    try std.crypto.Certificate.rsa.PKCS1v1_5Signature.verify(256, sig[0..256], "header.payload", pk, Sha256);
    try std.testing.expectError(error.InvalidSignature, std.crypto.Certificate.rsa.PKCS1v1_5Signature.verify(256, sig[0..256], "tampered", pk, Sha256));
}
