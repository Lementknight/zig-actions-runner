//! An HPACK decoder (RFC 7541), for the request headers of the gRPC calls the Dagger engine makes
//! to its client (`engine.zig`). Only decoding: responses are encoded as literals, which needs no
//! state.
const std = @import("std");
const tables = @import("hpack_tables.zig");
const Allocator = std.mem.Allocator;

pub const Error = error{ BadHpack, OutOfMemory };

pub const Decoder = struct {
    gpa: Allocator,
    /// Newest first: dynamic index 62 is `entries.items[len - 1]`.
    entries: std.ArrayList([2][]u8) = .empty,
    size: usize = 0,
    max_size: usize = 4096,

    pub fn deinit(d: *Decoder) void {
        for (d.entries.items) |e| {
            d.gpa.free(e[0]);
            d.gpa.free(e[1]);
        }
        d.entries.deinit(d.gpa);
    }

    /// Decodes one header block, calling `on(ctx, name, value)` for each field. Names and values
    /// are valid during the call only.
    pub fn decode(
        d: *Decoder,
        block: []const u8,
        ctx: anytype,
        comptime on: fn (@TypeOf(ctx), []const u8, []const u8) void,
    ) Error!void {
        var arena_state: std.heap.ArenaAllocator = .init(d.gpa);
        defer arena_state.deinit();
        const arena = arena_state.allocator();
        var i: usize = 0;
        while (i < block.len) {
            const b = block[i];
            if (b & 0x80 != 0) {
                const idx = try int(block, &i, 7);
                const f = try d.field(idx);
                on(ctx, f[0], f[1]);
            } else if (b & 0xc0 == 0x40) {
                const f = try d.literal(arena, block, &i, 6);
                try d.add(f[0], f[1]);
                on(ctx, f[0], f[1]);
            } else if (b & 0xe0 == 0x20) {
                const size = try int(block, &i, 5);
                if (size > 4096) return error.BadHpack;
                d.max_size = size;
                d.evict(0);
            } else {
                // Without indexing (0000) or never indexed (0001).
                const f = try d.literal(arena, block, &i, 4);
                on(ctx, f[0], f[1]);
            }
        }
    }

    fn literal(
        d: *Decoder,
        arena: Allocator,
        block: []const u8,
        i: *usize,
        comptime prefix: u3,
    ) Error![2][]const u8 {
        const idx = try int(block, i, prefix);
        const name = if (idx == 0) try string(arena, block, i) else (try d.field(idx))[0];
        return .{ name, try string(arena, block, i) };
    }

    fn field(d: *Decoder, idx: usize) Error![2][]const u8 {
        if (idx == 0) return error.BadHpack;
        if (idx <= tables.static_table.len) return tables.static_table[idx - 1];
        const dyn = idx - tables.static_table.len - 1;
        if (dyn >= d.entries.items.len) return error.BadHpack;
        const e = d.entries.items[d.entries.items.len - 1 - dyn];
        return .{ e[0], e[1] };
    }

    fn add(d: *Decoder, name: []const u8, value: []const u8) Error!void {
        const size = name.len + value.len + 32;
        d.evict(size);
        if (size > d.max_size) return;
        const n = try d.gpa.dupe(u8, name);
        errdefer d.gpa.free(n);
        const v = try d.gpa.dupe(u8, value);
        errdefer d.gpa.free(v);
        try d.entries.append(d.gpa, .{ n, v });
        d.size += size;
    }

    /// Drops the oldest entries until `extra` more bytes fit.
    fn evict(d: *Decoder, extra: usize) void {
        while (d.entries.items.len > 0 and d.size + extra > d.max_size) {
            const e = d.entries.orderedRemove(0);
            d.size -= e[0].len + e[1].len + 32;
            d.gpa.free(e[0]);
            d.gpa.free(e[1]);
        }
    }
};

/// An integer with an N-bit prefix (RFC 7541 §5.1), starting at `block[i.*]`.
fn int(block: []const u8, i: *usize, comptime prefix: u3) Error!usize {
    if (i.* >= block.len) return error.BadHpack;
    const mask: u8 = (@as(u8, 1) << prefix) - 1;
    var v: usize = block[i.*] & mask;
    i.* += 1;
    if (v < mask) return v;
    var shift: u6 = 0;
    while (true) {
        if (i.* >= block.len or shift > 28) return error.BadHpack;
        const b = block[i.*];
        i.* += 1;
        v += @as(usize, b & 0x7f) << shift;
        if (b & 0x80 == 0) return v;
        shift += 7;
    }
}

fn string(arena: Allocator, block: []const u8, i: *usize) Error![]const u8 {
    if (i.* >= block.len) return error.BadHpack;
    const huffman = block[i.*] & 0x80 != 0;
    const len = try int(block, i, 7);
    if (len > block.len - i.*) return error.BadHpack;
    const raw = block[i.*..][0..len];
    i.* += len;
    return if (huffman) try huffmanDecode(arena, raw) else raw;
}

/// Symbols by code length, for decoding bit by bit.
const by_len = blk: {
    @setEvalBranchQuota(100_000);
    var out: [31][]const u8 = undefined;
    for (0..31) |l| {
        var syms: []const u8 = &.{};
        for (0..256) |s| {
            if (tables.huffman_lens[s] == l) syms = syms ++ [_]u8{@intCast(s)};
        }
        out[l] = syms;
    }
    break :blk out;
};

pub fn huffmanDecode(arena: Allocator, raw: []const u8) Error![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    var code: u32 = 0;
    var len: u5 = 0;
    for (raw) |byte| {
        var bit: u4 = 8;
        while (bit > 0) {
            bit -= 1;
            code = (code << 1) | ((byte >> @intCast(bit)) & 1);
            len += 1;
            if (len >= 5) {
                for (by_len[len]) |s| if (tables.huffman_codes[s] == code) {
                    try out.append(arena, s);
                    code = 0;
                    len = 0;
                    break;
                };
            }
            if (len == 30) return error.BadHpack;
        }
    }
    // What is left must be padding: fewer than 8 bits, all ones (a prefix of EOS).
    if (len >= 8 or code != (@as(u32, 1) << len) - 1) return error.BadHpack;
    return out.items;
}

test "RFC 7541 C.4: requests with Huffman coding share a dynamic table" {
    var d: Decoder = .{ .gpa = std.testing.allocator };
    defer d.deinit();
    const Got = struct {
        buf: [512]u8 = undefined,
        len: usize = 0,
        fn on(g: *@This(), name: []const u8, value: []const u8) void {
            const s = std.fmt.bufPrint(g.buf[g.len..], "{s}={s};", .{ name, value }) catch return;
            g.len += s.len;
        }
    };
    const c41 = [_]u8{ 0x82, 0x86, 0x84, 0x41, 0x8c, 0xf1, 0xe3, 0xc2, 0xe5, 0xf2, 0x3a, 0x6b, 0xa0, 0xab, 0x90, 0xf4, 0xff };
    var g1: Got = .{};
    try d.decode(&c41, &g1, Got.on);
    try std.testing.expectEqualStrings(":method=GET;:scheme=http;:path=/;:authority=www.example.com;", g1.buf[0..g1.len]);
    const c42 = [_]u8{ 0x82, 0x86, 0x84, 0xbe, 0x58, 0x86, 0xa8, 0xeb, 0x10, 0x64, 0x9c, 0xbf };
    var g2: Got = .{};
    try d.decode(&c42, &g2, Got.on);
    try std.testing.expectEqualStrings(":method=GET;:scheme=http;:path=/;:authority=www.example.com;cache-control=no-cache;", g2.buf[0..g2.len]);
    const c43 = [_]u8{ 0x82, 0x87, 0x85, 0xbf, 0x40, 0x88, 0x25, 0xa8, 0x49, 0xe9, 0x5b, 0xa9, 0x7d, 0x7f, 0x89, 0x25, 0xa8, 0x49, 0xe9, 0x5b, 0xb8, 0xe8, 0xb4, 0xbf };
    var g3: Got = .{};
    try d.decode(&c43, &g3, Got.on);
    try std.testing.expectEqualStrings(":method=GET;:scheme=https;:path=/index.html;:authority=www.example.com;custom-key=custom-value;", g3.buf[0..g3.len]);
    try std.testing.expectEqual(@as(usize, 164), d.size);
}
