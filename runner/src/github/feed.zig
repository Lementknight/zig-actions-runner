//! A minimal WebSocket client (RFC 6455) for GitHub's live log feed: the `FeedStreamUrl` of the
//! job's `SystemVssConnection` endpoint (`wss://results-receiver.actions.githubusercontent.com/
//! _ws/ingest.sock`), authorized with the job token. The runner only sends: text messages, masked
//! as a client must, split into 1 KiB frames as actions/runner does.
const std = @import("std");
const http = @import("http.zig");

const Allocator = std.mem.Allocator;

pub const Socket = struct {
    io: std.Io,
    /// Holds the upgraded connection; deinit closes it.
    req: std.http.Client.Request,
    local: ?*std.http.Client,

    /// Connects (`wss://` is HTTPS with an `Upgrade`). The Socket must not move afterwards.
    pub fn open(s: *Socket, gpa: Allocator, io: std.Io, url: []const u8, token: []const u8) !void {
        const https = if (std.mem.startsWith(u8, url, "wss://"))
            try std.fmt.allocPrint(gpa, "https://{s}", .{url["wss://".len..]})
        else if (std.mem.startsWith(u8, url, "ws://"))
            try std.fmt.allocPrint(gpa, "http://{s}", .{url["ws://".len..]})
        else
            return error.NotAWebSocketUrl;
        defer gpa.free(https);

        var key_raw: [16]u8 = undefined;
        io.random(&key_raw);
        var key: [24]u8 = undefined;
        _ = std.base64.standard.Encoder.encode(&key, &key_raw);
        const bearer = try std.fmt.allocPrint(gpa, "Bearer {s}", .{token});
        defer gpa.free(bearer);

        var local: ?*std.http.Client = null;
        const client = http.shared orelse blk: {
            const c = try gpa.create(std.http.Client);
            c.* = .{ .allocator = gpa, .io = io, .write_buffer_size = 16 * 1024 };
            local = c;
            break :blk c;
        };
        errdefer if (local) |c| {
            c.deinit();
            gpa.destroy(c);
        };

        var req = try client.request(.GET, try std.Uri.parse(https), .{
            .headers = .{
                .connection = .{ .override = "Upgrade" },
                .authorization = .{ .override = bearer },
                .accept_encoding = .omit,
            },
            .extra_headers = &.{
                .{ .name = "Upgrade", .value = "websocket" },
                .{ .name = "Sec-WebSocket-Version", .value = "13" },
                .{ .name = "Sec-WebSocket-Key", .value = &key },
            },
            .keep_alive = false,
            .redirect_behavior = .unhandled,
        });
        errdefer req.deinit();
        try req.sendBodiless();
        const resp = try req.receiveHead(&.{});
        if (resp.head.status != .switching_protocols) return error.WebSocketRefused;
        s.* = .{ .io = io, .req = req, .local = local };
    }

    /// One text message: frames of at most 1 KiB, the first a text frame, the rest continuations.
    pub fn sendText(s: *Socket, payload: []const u8) !void {
        const w = s.req.connection.?.writer();
        var i: usize = 0;
        var first = true;
        while (true) {
            const end = @min(payload.len, i + 1024);
            try writeFrame(s.io, w, if (first) 0x1 else 0x0, end == payload.len, payload[i..end]);
            first = false;
            i = end;
            if (i == payload.len) break;
        }
        try s.req.connection.?.flush();
    }

    /// A ping, so a feed that has nothing to say for a while is not closed as idle on the way.
    pub fn ping(s: *Socket) !void {
        try writeFrame(s.io, s.req.connection.?.writer(), 0x9, true, &.{});
        try s.req.connection.?.flush();
    }

    pub fn close(s: *Socket, gpa: Allocator) void {
        const w = s.req.connection.?.writer();
        // A close frame with status 1000 (normal closure).
        writeFrame(s.io, w, 0x8, true, &.{ 0x03, 0xE8 }) catch {};
        s.req.connection.?.flush() catch {};
        s.req.connection.?.closing = true;
        s.req.deinit();
        if (s.local) |c| {
            c.deinit();
            gpa.destroy(c);
        }
    }
};

/// One frame from a client: FIN, the opcode, the mask bit and length, a random mask, and the masked
/// payload.
pub fn writeFrame(io: std.Io, w: *std.Io.Writer, opcode: u4, fin: bool, payload: []const u8) !void {
    var mask: [4]u8 = undefined;
    io.random(&mask);
    try writeFrameMasked(w, opcode, fin, payload, mask);
}

fn writeFrameMasked(
    w: *std.Io.Writer,
    opcode: u4,
    fin: bool,
    payload: []const u8,
    mask: [4]u8,
) !void {
    try w.writeByte(@as(u8, if (fin) 0x80 else 0) | opcode);
    if (payload.len < 126) {
        try w.writeByte(0x80 | @as(u8, @intCast(payload.len)));
    } else if (payload.len <= 0xFFFF) {
        try w.writeByte(0x80 | 126);
        try w.writeInt(u16, @intCast(payload.len), .big);
    } else {
        try w.writeByte(0x80 | 127);
        try w.writeInt(u64, payload.len, .big);
    }
    try w.writeAll(&mask);
    for (payload, 0..) |b, i| try w.writeByte(b ^ mask[i % 4]);
}

test "client frames are masked, with the length in 7, 16 or 64 bits" {
    var buf: [2048]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buf);
    try writeFrameMasked(&w, 0x1, true, "Hi", .{ 1, 2, 3, 4 });
    try std.testing.expectEqualSlices(u8, &.{ 0x81, 0x82, 1, 2, 3, 4, 'H' ^ 1, 'i' ^ 2 }, w.buffered());

    w = .fixed(&buf);
    const long: [300]u8 = @splat(0);
    try writeFrameMasked(&w, 0x0, false, &long, .{ 0, 0, 0, 0 });
    try std.testing.expectEqualSlices(u8, &.{ 0x00, 0x80 | 126, 0x01, 0x2C }, w.buffered()[0..4]);
}
