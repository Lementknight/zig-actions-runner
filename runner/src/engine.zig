//! A Dagger engine client (DESIGN §10): what the runner needs from a `dagger run` session, without
//! the `dagger` CLI process (about 60 MB per job).
//!
//! The protocol follows Dagger v0.21.10's own client (engine/client/client.go):
//!
//! - Each connection is a byte stream to the engine's API: `buildctl dial-stdio` run in the engine
//!   container, started through the Docker API (as the CLI does with `docker exec -i`).
//! - Every request carries `X-Dagger-Client-Metadata`, base64 JSON naming the client and session.
//! - `GET /sessionAttachables` turns one connection into the session's callback channel: after
//!   `101` and a one-byte ack, the engine speaks gRPC (HTTP/2) to the client. It checks
//!   `grpc.health.v1.Health/Check` every 5 s and drops a client that fails twice; it calls other
//!   methods only if the client advertises them, and this client advertises none (no host files,
//!   registry or git credentials, terminals). `h2` below is just enough HTTP/2 to stay healthy.
//! - Then `POST /init`, `GET /v1/logs` (server-sent events of OTLP logs in JSON: exec output with
//!   span ids), `POST /query` (GraphQL), and `POST /shutdown` at the end.
//!
//! HTTP/1.1 is enough for all of it (the engine serves HTTP/1.1 and unencrypted HTTP/2).
const std = @import("std");
const Allocator = std.mem.Allocator;
const Io = std.Io;
const hpack = @import("hpack.zig");

pub const default_container = "dagger-engine-v0.21.10";
pub const default_docker_socket = "/var/run/docker.sock";
/// The client version the engine checks for compatibility.
pub const client_version = "v0.21.10";

/// Where the engine's API is reached.
pub const Endpoint = struct {
    /// Docker API socket.
    docker_socket: []const u8 = default_docker_socket,
    /// The engine container `buildctl dial-stdio` runs in.
    container: []const u8 = default_container,
};

// --- reading a byte stream ---

/// Buffered reads from a connection. With `docker`, the stream is Docker's attach multiplexing
/// (8-byte headers: stream type, 3 zero bytes, big-endian length); only stdout frames are payload,
/// the last stderr frame is kept for error messages.
pub const In = struct {
    src: Source,
    docker: bool = false,
    raw: [16 * 1024]u8 = undefined,
    raw_start: usize = 0,
    raw_end: usize = 0,
    frame_left: usize = 0,
    frame_stdout: bool = true,
    buf: [32 * 1024]u8 = undefined,
    start: usize = 0,
    end: usize = 0,
    stderr: [256]u8 = undefined,
    stderr_len: usize = 0,

    pub const Source = struct {
        ptr: *anyopaque,
        readFn: *const fn (ptr: *anyopaque, dst: []u8) anyerror!usize,
    };

    fn rawRead(in: *In) !bool {
        if (in.raw_start == in.raw_end) {
            in.raw_start = 0;
            in.raw_end = 0;
        } else if (in.raw_end == in.raw.len) {
            std.mem.copyForwards(u8, &in.raw, in.raw[in.raw_start..in.raw_end]);
            in.raw_end -= in.raw_start;
            in.raw_start = 0;
        }
        const n = try in.src.readFn(in.src.ptr, in.raw[in.raw_end..]);
        if (n == 0) return false;
        in.raw_end += n;
        return true;
    }

    /// Reads more payload into the buffer; false at the end of the stream.
    fn fill(in: *In) !bool {
        if (in.start == in.end) {
            in.start = 0;
            in.end = 0;
        } else if (in.end == in.buf.len) {
            if (in.start == 0) return error.LineTooLong;
            std.mem.copyForwards(u8, &in.buf, in.buf[in.start..in.end]);
            in.end -= in.start;
            in.start = 0;
        }
        if (!in.docker) {
            const n = try in.src.readFn(in.src.ptr, in.buf[in.end..]);
            if (n == 0) return false;
            in.end += n;
            return true;
        }
        while (true) {
            if (in.frame_left == 0) {
                while (in.raw_end - in.raw_start < 8) if (!try in.rawRead()) return false;
                const hdr = in.raw[in.raw_start..][0..8];
                in.frame_stdout = hdr[0] != 2;
                in.frame_left = std.mem.readInt(u32, hdr[4..8], .big);
                in.raw_start += 8;
                if (!in.frame_stdout) in.stderr_len = 0;
                continue;
            }
            if (in.raw_start == in.raw_end and !try in.rawRead()) return false;
            const avail = @min(in.frame_left, in.raw_end - in.raw_start);
            const chunk = in.raw[in.raw_start..][0..avail];
            if (!in.frame_stdout) {
                const keep = @min(chunk.len, in.stderr.len - in.stderr_len);
                @memcpy(in.stderr[in.stderr_len..][0..keep], chunk[0..keep]);
                in.stderr_len += keep;
                in.raw_start += avail;
                in.frame_left -= avail;
                continue;
            }
            const n = @min(avail, in.buf.len - in.end);
            @memcpy(in.buf[in.end..][0..n], chunk[0..n]);
            in.end += n;
            in.raw_start += n;
            in.frame_left -= n;
            return true;
        }
    }

    /// The next line without its `\n` (and `\r`), or null at the end of the stream. Valid until
    /// the next read.
    pub fn takeLine(in: *In) !?[]const u8 {
        while (true) {
            if (std.mem.indexOfScalarPos(u8, in.buf[0..in.end], in.start, '\n')) |nl| {
                const line = in.buf[in.start..nl];
                in.start = nl + 1;
                return std.mem.trimEnd(u8, line, "\r");
            }
            if (!try in.fill()) return if (in.end > in.start) error.EndOfStream else null;
        }
    }

    /// Exactly `n` bytes (n ≤ the buffer size). Valid until the next read.
    pub fn take(in: *In, n: usize) ![]const u8 {
        if (n > in.buf.len) return error.MessageTooLong;
        while (in.end - in.start < n) {
            if (in.start > 0 and in.end + (n - (in.end - in.start)) > in.buf.len) {
                std.mem.copyForwards(u8, &in.buf, in.buf[in.start..in.end]);
                in.end -= in.start;
                in.start = 0;
            }
            if (!try in.fill()) return error.EndOfStream;
        }
        const out = in.buf[in.start..][0..n];
        in.start += n;
        return out;
    }

    /// Up to `max` bytes, at least one; empty at the end of the stream.
    pub fn takeSome(in: *In, max: usize) ![]const u8 {
        if (in.start == in.end and !try in.fill()) return &.{};
        const n = @min(max, in.end - in.start);
        const out = in.buf[in.start..][0..n];
        in.start += n;
        return out;
    }

    pub fn lastStderr(in: *const In) []const u8 {
        return std.mem.trim(u8, in.stderr[0..in.stderr_len], " \r\n");
    }
};

// --- HTTP/1.1 ---

pub const Head = struct {
    status: u16,
    content_length: ?usize = null,
    chunked: bool = false,
};

fn writeRequest(w: *Io.Writer, method: []const u8, path: []const u8, headers: []const [2][]const u8, body: []const u8) !void {
    try w.print("{s} {s} HTTP/1.1\r\nHost: dagger\r\n", .{ method, path });
    for (headers) |h| try w.print("{s}: {s}\r\n", .{ h[0], h[1] });
    if (body.len > 0 or std.mem.eql(u8, method, "POST")) try w.print("Content-Length: {d}\r\n", .{body.len});
    try w.writeAll("\r\n");
    try w.writeAll(body);
    try w.flush();
}

pub fn readHead(in: *In) !Head {
    const status_line = (try in.takeLine()) orelse return error.EndOfStream;
    var parts = std.mem.tokenizeScalar(u8, status_line, ' ');
    _ = parts.next() orelse return error.BadResponse;
    const code = std.fmt.parseInt(u16, parts.next() orelse return error.BadResponse, 10) catch return error.BadResponse;
    var head: Head = .{ .status = code };
    while (try in.takeLine()) |line| {
        if (line.len == 0) return head;
        const colon = std.mem.indexOfScalar(u8, line, ':') orelse continue;
        const name = std.mem.trim(u8, line[0..colon], " ");
        const value = std.mem.trim(u8, line[colon + 1 ..], " ");
        if (std.ascii.eqlIgnoreCase(name, "content-length")) head.content_length = std.fmt.parseInt(usize, value, 10) catch return error.BadResponse;
        if (std.ascii.eqlIgnoreCase(name, "transfer-encoding") and std.ascii.eqlIgnoreCase(value, "chunked")) head.chunked = true;
    }
    return error.EndOfStream;
}

/// Reads a whole body (fixed length, chunked, or none for 1xx/204/304).
pub fn readBody(arena: Allocator, in: *In, head: Head) ![]u8 {
    if (head.status / 100 == 1 or head.status == 204 or head.status == 304) return &.{};
    var out: std.ArrayList(u8) = .empty;
    if (head.chunked) {
        var body: Chunked = .{ .in = in };
        while (try body.next()) |part| try out.appendSlice(arena, part);
        return out.items;
    }
    var left = head.content_length orelse return error.UnsupportedResponse;
    while (left > 0) {
        const part = try in.takeSome(left);
        if (part.len == 0) return error.EndOfStream;
        try out.appendSlice(arena, part);
        left -= part.len;
    }
    return out.items;
}

/// A chunked body, read piece by piece (for streams such as server-sent events).
pub const Chunked = struct {
    in: *In,
    left: usize = 0,
    done: bool = false,
    /// The CRLF after a chunk, read on the next call (reading it at once could move the bytes of
    /// the piece just returned).
    crlf_due: bool = false,

    /// The next piece of the body, or null at its end. Valid until the next read.
    pub fn next(c: *Chunked) !?[]const u8 {
        if (c.done) return null;
        if (c.crlf_due) {
            _ = try c.in.take(2);
            c.crlf_due = false;
        }
        if (c.left == 0) {
            const size_line = (try c.in.takeLine()) orelse return error.EndOfStream;
            const hex = std.mem.trim(u8, size_line[0 .. std.mem.indexOfScalar(u8, size_line, ';') orelse size_line.len], " ");
            c.left = std.fmt.parseInt(usize, hex, 16) catch return error.BadResponse;
            if (c.left == 0) {
                // Trailers, then the empty line.
                while (try c.in.takeLine()) |l| if (l.len == 0) break;
                c.done = true;
                return null;
            }
        }
        const part = try c.in.takeSome(c.left);
        if (part.len == 0) return error.EndOfStream;
        c.left -= part.len;
        if (c.left == 0) c.crlf_due = true;
        return part;
    }
};

// --- HTTP/2: answering the engine's health checks ---

pub const h2 = struct {
    pub const preface = "PRI * HTTP/2.0\r\n\r\nSM\r\n\r\n";
    const data = 0x0;
    const headers = 0x1;
    const settings = 0x4;
    const ping = 0x6;
    const goaway = 0x7;
    const window_update = 0x8;
    const continuation = 0x9;
    const end_stream = 0x1;
    const ack = 0x1;
    const end_headers = 0x4;
    const padded = 0x8;
    const priority = 0x20;

    /// `:status: 200` (static entry 8) and `content-type: application/grpc` (literal, name from
    /// static entry 31): HPACK without the dynamic table, so no encoder state is needed.
    const response_headers = [_]u8{ 0x88, 0x0f, 0x10, 0x10 } ++ "application/grpc".*;

    pub const health_check = "/grpc.health.v1.Health/Check";
    /// Registry credentials for an image pull: answered empty, so pulls are anonymous.
    pub const credentials = "/moby.filesync.v1.Auth/Credentials";
    pub const diff_copy = "/moby.filesync.v1.FileSync/DiffCopy";
    /// What a host path resolves to: a directory that has nothing in it, so the engine finds no
    /// workspace (dagger.json, .git) and the client has no files to give.
    pub const host_root = "/zig-runner";

    /// gRPC status codes used here.
    const ok = 0;
    const not_found = 5;
    const unimplemented = 12;

    fn frame(w: *Io.Writer, kind: u8, flags: u8, stream: u32, payload: []const u8) !void {
        var hdr: [9]u8 = undefined;
        std.mem.writeInt(u24, hdr[0..3], @intCast(payload.len), .big);
        hdr[3] = kind;
        hdr[4] = flags;
        std.mem.writeInt(u32, hdr[5..9], stream & 0x7fff_ffff, .big);
        try w.writeAll(&hdr);
        try w.writeAll(payload);
    }

    /// One gRPC message (uncompressed, length-prefixed) followed by `grpc-status: 0`.
    fn reply(w: *Io.Writer, stream: u32, message: []const u8) !void {
        try frame(w, headers, end_headers, stream, &response_headers);
        var msg: [5 + 512]u8 = undefined;
        msg[0] = 0;
        std.mem.writeInt(u32, msg[1..5], @intCast(message.len), .big);
        @memcpy(msg[5..][0..message.len], message);
        try frame(w, data, 0, stream, msg[0 .. 5 + message.len]);
        try frame(w, headers, end_headers | end_stream, stream, &statusBlock(ok, ""));
    }

    /// A trailers-only response: the call failed with `code`.
    fn fail(w: *Io.Writer, stream: u32, comptime code: u8, comptime message: []const u8) !void {
        var block: [256]u8 = undefined;
        @memcpy(block[0..response_headers.len], &response_headers);
        const status = statusBlock(code, message);
        @memcpy(block[response_headers.len..][0..status.len], &status);
        try frame(w, headers, end_headers | end_stream, stream, block[0 .. response_headers.len + status.len]);
    }

    /// `grpc-status` and, when given, `grpc-message` (plain ASCII, at most 64 bytes), as literals
    /// with new names.
    fn statusBlock(comptime code: u8, comptime message: []const u8) [statusLen(code, message)]u8 {
        const digits = std.fmt.comptimePrint("{d}", .{code});
        var out: [statusLen(code, message)]u8 = undefined;
        const head = [_]u8{ 0x00, 11 } ++ "grpc-status".* ++ [_]u8{digits.len} ++ digits[0..digits.len].*;
        @memcpy(out[0..head.len], &head);
        if (message.len > 0) {
            const tail = [_]u8{ 0x00, 12 } ++ "grpc-message".* ++ [_]u8{message.len} ++ message[0..message.len].*;
            @memcpy(out[head.len..], &tail);
        }
        return out;
    }

    fn statusLen(comptime code: u8, comptime message: []const u8) usize {
        const digits = std.fmt.comptimePrint("{d}", .{code});
        return 2 + 11 + 1 + digits.len + (if (message.len > 0) 2 + 12 + 1 + message.len else 0);
    }

    /// The fields of a request this server looks at.
    const Request = struct {
        path: []const u8 = "",
        import_opts: []const u8 = "",
        buf: [4096]u8 = undefined,
        used: usize = 0,

        fn on(r: *Request, name: []const u8, value: []const u8) void {
            const dst: *[]const u8 = if (std.mem.eql(u8, name, ":path"))
                &r.path
            else if (std.ascii.eqlIgnoreCase(name, "x-dagger-local-import-opts"))
                &r.import_opts
            else
                return;
            if (value.len > r.buf.len - r.used) return;
            @memcpy(r.buf[r.used..][0..value.len], value);
            dst.* = r.buf[r.used..][0..value.len];
            r.used += value.len;
        }
    };

    /// Serves the connection until the engine closes it. Settings and pings are acknowledged; each
    /// call is answered when its headers arrive: health checks SERVING, the engine's questions
    /// about the client's files (`FileSync/DiffCopy`: an absolute path, a stat, a file) with
    /// `host_root` or NOT_FOUND, anything else UNIMPLEMENTED. Returns how many calls it answered.
    pub fn serve(gpa: Allocator, in: *In, w: *Io.Writer) !usize {
        const got = try in.take(preface.len);
        if (!std.mem.eql(u8, got, preface)) return error.NotHttp2;
        try frame(w, settings, 0, 0, &.{});
        try w.flush();
        var dec: hpack.Decoder = .{ .gpa = gpa };
        defer dec.deinit();
        var payload: std.ArrayList(u8) = .empty;
        defer payload.deinit(gpa);
        var block: std.ArrayList(u8) = .empty;
        defer block.deinit(gpa);
        var answered: usize = 0;
        while (true) {
            const hdr = in.take(9) catch |e| switch (e) {
                error.EndOfStream => return answered,
                else => return e,
            };
            const len = std.mem.readInt(u24, hdr[0..3], .big);
            const kind = hdr[3];
            const flags = hdr[4];
            const stream = std.mem.readInt(u32, hdr[5..9], .big) & 0x7fff_ffff;
            payload.clearRetainingCapacity();
            var left: usize = len;
            while (left > 0) {
                const part = try in.takeSome(left);
                if (part.len == 0) return answered;
                try payload.appendSlice(gpa, part);
                left -= part.len;
            }
            const p = payload.items;
            switch (kind) {
                settings => if (flags & ack == 0) try frame(w, settings, ack, 0, &.{}),
                ping => if (flags & ack == 0 and p.len == 8) try frame(w, ping, ack, 0, p),
                goaway => return answered,
                data => if (len > 0) {
                    // Give the window back so calls never stall.
                    var inc: [4]u8 = undefined;
                    std.mem.writeInt(u32, &inc, len, .big);
                    try frame(w, window_update, 0, 0, &inc);
                },
                headers, continuation => {
                    var frag = p;
                    if (kind == headers) {
                        block.clearRetainingCapacity();
                        if (flags & padded != 0) {
                            if (frag.len < 1 or frag[0] >= frag.len) return error.BadFrame;
                            frag = frag[1 .. frag.len - frag[0]];
                        }
                        if (flags & priority != 0) {
                            if (frag.len < 5) return error.BadFrame;
                            frag = frag[5..];
                        }
                    }
                    try block.appendSlice(gpa, frag);
                    if (flags & end_headers != 0) {
                        var req: Request = .{};
                        try dec.decode(block.items, &req, Request.on);
                        try answer(gpa, w, stream, &req);
                        answered += 1;
                    }
                },
                else => {},
            }
            try w.flush();
        }
    }

    fn answer(gpa: Allocator, w: *Io.Writer, stream: u32, req: *const Request) !void {
        if (std.mem.eql(u8, req.path, health_check)) {
            // HealthCheckResponse{status: SERVING}
            return reply(w, stream, &.{ 0x08, 0x01 });
        }
        if (std.mem.eql(u8, req.path, credentials)) return reply(w, stream, &.{});
        if (!std.mem.eql(u8, req.path, diff_copy)) return fail(w, stream, unimplemented, "not supported by zig-runner");
        var arena_state: std.heap.ArenaAllocator = .init(gpa);
        defer arena_state.deinit();
        const arena = arena_state.allocator();
        const opts_json = base64Decode(arena, req.import_opts) catch return fail(w, stream, not_found, "no such path");
        const opts = std.json.parseFromSliceLeaky(std.json.Value, arena, opts_json, .{}) catch return fail(w, stream, not_found, "no such path");
        const abs_only = if (field(opts, "get_abs_path_only")) |v| v == .bool and v.bool else false;
        if (!abs_only) return fail(w, stream, not_found, "no such path");
        // fsutil types.Stat{path}: field 1, length-delimited.
        const rel = if (field(opts, "path")) |v| (if (v == .string) v.string else ".") else ".";
        const abs = if (std.mem.startsWith(u8, rel, "/")) rel else try std.fs.path.resolvePosix(arena, &.{ host_root, rel });
        if (abs.len > 400) return fail(w, stream, not_found, "no such path");
        var msg: [512]u8 = undefined;
        msg[0] = 0x0a;
        msg[1] = @intCast(abs.len);
        var n: usize = 2;
        if (abs.len >= 0x80) {
            msg[1] = @intCast((abs.len & 0x7f) | 0x80);
            msg[2] = @intCast(abs.len >> 7);
            n = 3;
        }
        @memcpy(msg[n..][0..abs.len], abs);
        return reply(w, stream, msg[0 .. n + abs.len]);
    }
};

// --- server-sent events of OTLP logs ---

/// One log record: a piece of an exec's output (or of the engine's own messages).
pub const LogRecord = struct {
    /// Hex span id ("" when the record has none).
    span: []const u8,
    /// 1 stdout, 2 stderr, 0 unknown.
    stream: u8,
    text: []const u8,
    /// `dagger.io/logs.verbose`: the engine repeating output it already logged (a `stdout` field's
    /// value, for example), hidden by Dagger's own progress output too.
    verbose: bool = false,
    /// `stdio.eof`: the span's stream ended.
    eof: bool = false,
};

pub const LogHandler = struct {
    ptr: *anyopaque,
    onRecord: *const fn (ptr: *anyopaque, rec: LogRecord) void,
};

/// Splits server-sent events into their `data`, dispatched at each blank line.
pub const Sse = struct {
    line: std.ArrayList(u8) = .empty,
    data: std.ArrayList(u8) = .empty,

    /// Feeds body bytes; calls `onData` with each complete event's data.
    pub fn feed(s: *Sse, gpa: Allocator, bytes: []const u8, ctx: anytype, comptime onData: fn (@TypeOf(ctx), []const u8) void) !void {
        for (bytes) |b| {
            if (b != '\n') {
                try s.line.append(gpa, b);
                continue;
            }
            const line = std.mem.trimEnd(u8, s.line.items, "\r");
            if (line.len == 0) {
                if (s.data.items.len > 0) onData(ctx, s.data.items);
                s.data.clearRetainingCapacity();
            } else if (std.mem.startsWith(u8, line, "data:")) {
                if (s.data.items.len > 0) try s.data.append(gpa, '\n');
                try s.data.appendSlice(gpa, std.mem.trimStart(u8, line["data:".len..], " "));
            }
            s.line.clearRetainingCapacity();
        }
    }

    pub fn deinit(s: *Sse, gpa: Allocator) void {
        s.line.deinit(gpa);
        s.data.deinit(gpa);
    }
};

/// Calls `h` for each log record in an OTLP `ExportLogsServiceRequest` in JSON (protojson).
pub fn eachLogRecord(arena: Allocator, json: []const u8, h: LogHandler) void {
    const root = std.json.parseFromSliceLeaky(std.json.Value, arena, json, .{}) catch return;
    const resource_logs = field(root, "resourceLogs") orelse return;
    if (resource_logs != .array) return;
    for (resource_logs.array.items) |rl| {
        const scopes = field(rl, "scopeLogs") orelse continue;
        if (scopes != .array) continue;
        for (scopes.array.items) |sl| {
            const recs = field(sl, "logRecords") orelse continue;
            if (recs != .array) continue;
            for (recs.array.items) |r| {
                const body = field(r, "body") orelse continue;
                var text: []const u8 = "";
                if (field(body, "stringValue")) |v| {
                    if (v == .string) text = v.string;
                } else if (field(body, "bytesValue")) |v| {
                    if (v == .string) text = base64Decode(arena, v.string) catch continue;
                }
                var rec: LogRecord = .{ .span = "", .stream = 0, .text = text };
                if (field(r, "attributes")) |attrs| if (attrs == .array) for (attrs.array.items) |a| {
                    const key = field(a, "key") orelse continue;
                    const val = field(a, "value") orelse continue;
                    if (key != .string) continue;
                    if (std.mem.eql(u8, key.string, "stdio.stream")) {
                        if (field(val, "intValue")) |iv| rec.stream = switch (iv) {
                            .integer => |i| @intCast(@min(@max(i, 0), 2)),
                            .string => |str| std.fmt.parseInt(u8, str, 10) catch 0,
                            else => 0,
                        };
                    } else if (std.mem.eql(u8, key.string, "dagger.io/logs.verbose")) {
                        rec.verbose = if (field(val, "boolValue")) |b| b == .bool and b.bool else false;
                    } else if (std.mem.eql(u8, key.string, "stdio.eof")) {
                        rec.eof = if (field(val, "boolValue")) |b| b == .bool and b.bool else false;
                    }
                };
                if (rec.text.len == 0 and !rec.eof) continue;
                rec.span = if (field(r, "spanId")) |v| (if (v == .string) v.string else "") else "";
                h.onRecord(h.ptr, rec);
            }
        }
    }
}

fn field(v: std.json.Value, name: []const u8) ?std.json.Value {
    if (v != .object) return null;
    return v.object.get(name);
}

fn base64Decode(arena: Allocator, s: []const u8) ![]const u8 {
    const dec = std.base64.standard.Decoder;
    const out = try arena.alloc(u8, try dec.calcSizeForSlice(s));
    try dec.decode(out, s);
    return out;
}

// --- connections ---

/// A connection to the engine: a socket whose reads may be Docker-multiplexed.
pub const Conn = struct {
    io: Io,
    stream: Io.net.Stream,
    in: In,
    wbuf: [8 * 1024]u8 = undefined,
    w: Io.net.Stream.Writer = undefined,
    rbuf: [16 * 1024]u8 = undefined,
    r: Io.net.Stream.Reader = undefined,

    /// Whatever one read of the socket returns (not a full buffer), or 0 at its end.
    fn readFn(ptr: *anyopaque, dst: []u8) anyerror!usize {
        const c: *Conn = @ptrCast(@alignCast(ptr));
        const r = &c.r.interface;
        if (r.bufferedLen() == 0) r.fillMore() catch |e| switch (e) {
            error.EndOfStream => return 0,
            error.ReadFailed => return c.r.err orelse error.ReadFailed,
        };
        const avail = r.buffered();
        const n = @min(avail.len, dst.len);
        @memcpy(dst[0..n], avail[0..n]);
        r.toss(n);
        return n;
    }

    /// Connects to a Unix socket. The Conn must not move afterwards.
    fn initUnix(c: *Conn, io: Io, path: []const u8) !void {
        const addr = try Io.net.UnixAddress.init(path);
        c.* = .{ .io = io, .stream = try addr.connect(io), .in = undefined };
        c.in = .{ .src = .{ .ptr = c, .readFn = readFn } };
        c.w = .init(c.stream, io, &c.wbuf);
        c.r = .init(c.stream, io, &c.rbuf);
    }

    pub fn writer(c: *Conn) *Io.Writer {
        return &c.w.interface;
    }

    /// Stops both directions, waking a task blocked reading it; `close` then frees it.
    pub fn shutdown(c: *Conn) void {
        c.stream.shutdown(c.io, .both) catch {};
    }

    pub fn close(c: *Conn) void {
        c.stream.close(c.io);
    }
};

/// A new connection to the engine's API: `buildctl dial-stdio` in the engine container, through
/// the Docker API (create an exec, then start it with the connection upgraded to a raw stream).
pub fn dial(gpa: Allocator, io: Io, ep: Endpoint) !*Conn {
    var arena_state: std.heap.ArenaAllocator = .init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const exec_id = blk: {
        const c = try gpa.create(Conn);
        defer gpa.destroy(c);
        try c.initUnix(io, ep.docker_socket);
        defer c.close();
        const body = "{\"AttachStdin\":true,\"AttachStdout\":true,\"AttachStderr\":true,\"Cmd\":[\"buildctl\",\"dial-stdio\"]}";
        try writeRequest(c.writer(), "POST", try std.fmt.allocPrint(arena, "/containers/{s}/exec", .{ep.container}), &.{.{ "Content-Type", "application/json" }}, body);
        const head = try readHead(&c.in);
        const resp = try readBody(arena, &c.in, head);
        if (head.status == 404) return error.EngineContainerNotFound;
        if (head.status == 409) return error.EngineContainerNotRunning;
        if (head.status != 201) return error.DockerExecFailed;
        const parsed = std.json.parseFromSliceLeaky(std.json.Value, arena, resp, .{}) catch return error.DockerExecFailed;
        const id = field(parsed, "Id") orelse return error.DockerExecFailed;
        if (id != .string) return error.DockerExecFailed;
        break :blk try arena.dupe(u8, id.string);
    };

    const c = try gpa.create(Conn);
    errdefer gpa.destroy(c);
    try c.initUnix(io, ep.docker_socket);
    errdefer c.close();
    try writeRequest(c.writer(), "POST", try std.fmt.allocPrint(arena, "/exec/{s}/start", .{exec_id}), &.{
        .{ "Content-Type", "application/json" },
        .{ "Connection", "Upgrade" },
        .{ "Upgrade", "tcp" },
    }, "{\"Detach\":false,\"Tty\":false}");
    const head = try readHead(&c.in);
    if (head.status != 101 and head.status != 200) return error.DockerExecFailed;
    // From here the stream is Docker-multiplexed; anything already buffered belongs to it.
    c.in.docker = true;
    const pending = c.in.buf[c.in.start..c.in.end];
    @memcpy(c.in.raw[0..pending.len], pending);
    c.in.raw_start = 0;
    c.in.raw_end = pending.len;
    c.in.start = 0;
    c.in.end = 0;
    return c;
}

/// Starts the engine container (it exists but is stopped), through the Docker API.
pub fn startContainer(gpa: Allocator, io: Io, ep: Endpoint) !void {
    var arena_state: std.heap.ArenaAllocator = .init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const c = try gpa.create(Conn);
    defer gpa.destroy(c);
    try c.initUnix(io, ep.docker_socket);
    defer c.close();
    try writeRequest(c.writer(), "POST", try std.fmt.allocPrint(arena, "/containers/{s}/start", .{ep.container}), &.{}, "");
    const head = try readHead(&c.in);
    _ = try readBody(arena, &c.in, head);
    // 304: already running.
    if (head.status != 204 and head.status != 304) return error.EngineStartFailed;
}

// --- sessions ---

/// One Dagger session (a client of the engine), as `dagger run` would hold for a job.
pub const Session = struct {
    gpa: Allocator,
    io: Io,
    ep: Endpoint,
    /// `X-Dagger-Client-Metadata`, `Authorization` and `traceparent` values. The engine files the
    /// session's telemetry under the trace; without one, its log records cannot be exported.
    metadata: []const u8,
    auth: []const u8,
    traceparent: [55]u8,
    attach: *Conn,
    health: ?Io.Future(void) = null,
    health_answered: std.atomic.Value(usize) = .init(0),
    query_conn: ?*Conn = null,
    logs_conn: ?*Conn = null,
    logs_task: ?Io.Future(void) = null,
    log_handler: ?LogHandler = null,
    /// Set when the log stream has ended (the engine closes it once the session is gone).
    logs_ended: std.atomic.Value(bool) = .init(false),
    closed: bool = false,

    /// Opens a session: the callback connection (serving health checks), `/init`, and, with a
    /// handler, the log subscription. The Session must not move afterwards.
    pub fn open(s: *Session, gpa: Allocator, io: Io, ep: Endpoint, log_handler: ?LogHandler) !void {
        var ids: [3][36]u8 = undefined;
        for (&ids) |*id| uuid(io, id);
        const md_json = try std.fmt.allocPrint(gpa, "{{\"client_id\":\"{s}\",\"client_version\":\"{s}\",\"session_id\":\"{s}\",\"client_secret_token\":\"{s}\",\"client_hostname\":\"zig-runner\",\"client_stable_id\":\"{s}\",\"do_not_track\":true}}", .{ &ids[0], client_version, &ids[1], &ids[2], &ids[0] });
        defer gpa.free(md_json);
        const enc = std.base64.standard.Encoder;
        const md = try gpa.alloc(u8, enc.calcSize(md_json.len));
        errdefer gpa.free(md);
        _ = enc.encode(md, md_json);
        const token_colon = try std.fmt.allocPrint(gpa, "{s}:", .{&ids[2]});
        defer gpa.free(token_colon);
        const auth_b64 = try gpa.alloc(u8, enc.calcSize(token_colon.len));
        defer gpa.free(auth_b64);
        _ = enc.encode(auth_b64, token_colon);
        const auth = try std.fmt.allocPrint(gpa, "Basic {s}", .{auth_b64});
        errdefer gpa.free(auth);

        var trace: [16]u8 = undefined;
        var span: [8]u8 = undefined;
        io.random(&trace);
        io.random(&span);
        var traceparent: [55]u8 = undefined;
        _ = std.fmt.bufPrint(&traceparent, "00-{x}-{x}-01", .{ &trace, &span }) catch unreachable;

        const attach = try dial(gpa, io, ep);
        errdefer {
            attach.close();
            gpa.destroy(attach);
        }
        try writeRequest(attach.writer(), "GET", "/sessionAttachables", &.{
            .{ "X-Dagger-Client-Metadata", md },
            .{ "traceparent", &traceparent },
        }, "");
        const head = try readHead(&attach.in);
        if (head.status != 101) return if (attach.in.lastStderr().len > 0) error.EngineUnreachable else error.SessionRefused;
        try attach.writer().writeAll(&.{0});
        try attach.writer().flush();

        s.* = .{ .gpa = gpa, .io = io, .ep = ep, .metadata = md, .auth = auth, .traceparent = traceparent, .attach = attach, .log_handler = log_handler };
        s.health = try io.concurrent(serveHealth, .{s});
        errdefer s.close();

        var arena_state: std.heap.ArenaAllocator = .init(gpa);
        defer arena_state.deinit();
        const init = try s.request(arena_state.allocator(), "POST", "/init", "");
        if (init.status / 100 != 2) return error.SessionInitFailed;

        if (log_handler != null) {
            const lc = try dial(gpa, io, ep);
            s.logs_conn = lc;
            try writeRequest(lc.writer(), "GET", "/v1/logs", &.{
                .{ "X-Dagger-Client-Metadata", md },
                .{ "Authorization", auth },
                .{ "traceparent", &s.traceparent },
                .{ "Accept", "text/event-stream" },
            }, "");
            s.logs_task = try io.concurrent(readLogs, .{s});
        }
    }

    fn serveHealth(s: *Session) void {
        const n = h2.serve(s.gpa, &s.attach.in, s.attach.writer()) catch 0;
        s.health_answered.store(n, .monotonic);
    }

    fn readLogs(s: *Session) void {
        defer s.logs_ended.store(true, .release);
        const lc = s.logs_conn.?;
        const head = readHead(&lc.in) catch return;
        if (head.status != 200) return;
        var sse: Sse = .{};
        defer sse.deinit(s.gpa);
        const Ctx = struct {
            s: *Session,
            fn onData(ctx: @This(), data: []const u8) void {
                var arena_state: std.heap.ArenaAllocator = .init(ctx.s.gpa);
                defer arena_state.deinit();
                eachLogRecord(arena_state.allocator(), data, ctx.s.log_handler.?);
            }
        };
        if (head.chunked) {
            var body: Chunked = .{ .in = &lc.in };
            while (body.next() catch null) |part| {
                sse.feed(s.gpa, part, Ctx{ .s = s }, Ctx.onData) catch return;
            }
        } else while (true) {
            const part = lc.in.takeSome(4096) catch return;
            if (part.len == 0) return;
            sse.feed(s.gpa, part, Ctx{ .s = s }, Ctx.onData) catch return;
        }
    }

    pub const Response = struct { status: u16, body: []u8 };

    /// One request on the session's query connection (opened on first use, kept alive).
    pub fn request(s: *Session, arena: Allocator, method: []const u8, path: []const u8, body: []const u8) !Response {
        var attempt: u8 = 0;
        while (true) : (attempt += 1) {
            if (s.query_conn == null) s.query_conn = try dial(s.gpa, s.io, s.ep);
            const c = s.query_conn.?;
            const result: anyerror!Response = blk: {
                writeRequest(c.writer(), method, path, &.{
                    .{ "X-Dagger-Client-Metadata", s.metadata },
                    .{ "Authorization", s.auth },
                    .{ "traceparent", &s.traceparent },
                    .{ "Content-Type", "application/json" },
                }, body) catch |e| break :blk e;
                const head = readHead(&c.in) catch |e| break :blk e;
                const resp = readBody(arena, &c.in, head) catch |e| break :blk e;
                break :blk .{ .status = head.status, .body = resp };
            };
            return result catch |e| {
                // A connection the engine closed between requests: dial again, once.
                c.close();
                s.gpa.destroy(c);
                s.query_conn = null;
                if (attempt == 0 and (e == error.EndOfStream or e == error.BrokenPipe or e == error.ConnectionResetByPeer)) continue;
                return e;
            };
        }
    }

    /// A GraphQL query; the response body.
    pub fn query(s: *Session, arena: Allocator, doc: []const u8) ![]const u8 {
        var body: Io.Writer.Allocating = .init(arena);
        try body.writer.writeAll("{\"query\":");
        try std.json.Stringify.value(doc, .{}, &body.writer);
        try body.writer.writeByte('}');
        const r = try s.request(arena, "POST", "/query", body.written());
        if (r.status / 100 != 2 and r.body.len == 0) return error.QueryFailed;
        return r.body;
    }

    /// Ends the session: `/shutdown` (which flushes the engine's telemetry), then the connections.
    /// The log stream ends with the session, so every record has been handled when this returns.
    pub fn close(s: *Session) void {
        if (s.closed) return;
        s.closed = true;
        var arena_state: std.heap.ArenaAllocator = .init(s.gpa);
        defer arena_state.deinit();
        _ = s.request(arena_state.allocator(), "POST", "/shutdown", "") catch {};
        if (s.logs_task) |*t| {
            // The engine ends the stream once the session is gone; don't wait forever if it doesn't.
            var waited: u32 = 0;
            while (waited < 50 and !s.logs_ended.load(.acquire)) : (waited += 1) s.io.sleep(.fromMilliseconds(100), .awake) catch {};
            s.logs_conn.?.shutdown();
            t.await(s.io);
            s.logs_conn.?.close();
            s.gpa.destroy(s.logs_conn.?);
        }
        if (s.query_conn) |c| {
            c.close();
            s.gpa.destroy(c);
        }
        s.attach.shutdown();
        if (s.health) |*t| t.await(s.io);
        s.attach.close();
        s.gpa.destroy(s.attach);
        s.gpa.free(s.metadata);
        s.gpa.free(s.auth);
    }
};

fn uuid(io: Io, out: *[36]u8) void {
    var b: [16]u8 = undefined;
    io.random(&b);
    b[6] = (b[6] & 0x0f) | 0x40;
    b[8] = (b[8] & 0x3f) | 0x80;
    const hex = std.fmt.bytesToHex(b, .lower);
    _ = std.fmt.bufPrint(out, "{s}-{s}-{s}-{s}-{s}", .{ hex[0..8], hex[8..12], hex[12..16], hex[16..20], hex[20..32] }) catch unreachable;
}

// --- tests ---

const SliceSource = struct {
    data: []const u8,
    pos: usize = 0,
    /// Bytes handed out per read, to exercise partial reads.
    step: usize = 3,

    fn read(ptr: *anyopaque, dst: []u8) anyerror!usize {
        const s: *SliceSource = @ptrCast(@alignCast(ptr));
        const n = @min(@min(dst.len, s.step), s.data.len - s.pos);
        @memcpy(dst[0..n], s.data[s.pos..][0..n]);
        s.pos += n;
        return n;
    }

    fn in(s: *SliceSource) In {
        return .{ .src = .{ .ptr = s, .readFn = read } };
    }
};

test "HTTP responses: fixed length, chunked, 204 and 101" {
    var a: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer a.deinit();
    const arena = a.allocator();
    var src: SliceSource = .{ .data = "HTTP/1.1 200 OK\r\nContent-Length: 5\r\n\r\nhello" ++
        "HTTP/1.1 204 No Content\r\n\r\n" ++
        "HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\n\r\n3\r\nabc\r\n2;x=y\r\nde\r\n0\r\n\r\n" ++
        "HTTP/1.1 101 Switching Protocols\r\nUpgrade: h2c\r\n\r\nrest" };
    var in = src.in();
    const h1 = try readHead(&in);
    try std.testing.expectEqual(@as(u16, 200), h1.status);
    try std.testing.expectEqualStrings("hello", try readBody(arena, &in, h1));
    const h2r = try readHead(&in);
    try std.testing.expectEqual(@as(u16, 204), h2r.status);
    try std.testing.expectEqualStrings("", try readBody(arena, &in, h2r));
    const h3 = try readHead(&in);
    try std.testing.expect(h3.chunked);
    try std.testing.expectEqualStrings("abcde", try readBody(arena, &in, h3));
    const h4 = try readHead(&in);
    try std.testing.expectEqual(@as(u16, 101), h4.status);
    try std.testing.expectEqualStrings("rest", try in.take(4));
}

test "Docker multiplexing: stdout frames are payload, stderr is kept for errors" {
    const frames = [_]u8{ 1, 0, 0, 0, 0, 0, 0, 6 } ++ "hello\n".* ++
        [_]u8{ 2, 0, 0, 0, 0, 0, 0, 4 } ++ "oops".* ++
        [_]u8{ 1, 0, 0, 0, 0, 0, 0, 7 } ++ "world\r\n".*;
    var src: SliceSource = .{ .data = &frames };
    var in = src.in();
    in.docker = true;
    try std.testing.expectEqualStrings("hello", (try in.takeLine()).?);
    try std.testing.expectEqualStrings("world", (try in.takeLine()).?);
    try std.testing.expect((try in.takeLine()) == null);
    try std.testing.expectEqualStrings("oops", in.lastStderr());
}

test "h2: settings and pings are acknowledged; health checks, path questions and stats are answered" {
    const gpa = std.testing.allocator;
    var input: std.ArrayList(u8) = .empty;
    defer input.deinit(gpa);
    try input.appendSlice(gpa, h2.preface);
    const F = struct {
        fn add(list: *std.ArrayList(u8), kind: u8, flags: u8, stream: u32, payload: []const u8) !void {
            var hdr: [9]u8 = undefined;
            std.mem.writeInt(u24, hdr[0..3], @intCast(payload.len), .big);
            hdr[3] = kind;
            hdr[4] = flags;
            std.mem.writeInt(u32, hdr[5..9], stream, .big);
            try list.appendSlice(std.testing.allocator, &hdr);
            try list.appendSlice(std.testing.allocator, payload);
        }
        /// `:path` (static name 4) and an optional import-opts header, as literals without indexing.
        fn request(list: *std.ArrayList(u8), stream: u32, path: []const u8, opts: []const u8) !void {
            var block: std.ArrayList(u8) = .empty;
            defer block.deinit(std.testing.allocator);
            try block.appendSlice(std.testing.allocator, &[_]u8{ 0x04, @intCast(path.len) });
            try block.appendSlice(std.testing.allocator, path);
            if (opts.len > 0) {
                const name = "x-dagger-local-import-opts";
                try block.appendSlice(std.testing.allocator, &[_]u8{ 0x00, name.len });
                try block.appendSlice(std.testing.allocator, name);
                try block.appendSlice(std.testing.allocator, &[_]u8{@intCast(opts.len)});
                try block.appendSlice(std.testing.allocator, opts);
            }
            try add(list, 0x1, 0x4, stream, block.items);
        }
    };
    try F.add(&input, 0x4, 0, 0, &[_]u8{ 0, 3, 0, 0, 0, 100 }); // SETTINGS
    try F.add(&input, 0x6, 0, 0, "12345678"); // PING
    try F.request(&input, 1, h2.health_check, "");
    try F.add(&input, 0x0, 0x1, 1, &[_]u8{ 0, 0, 0, 0, 0 }); // its (empty) message
    // {"path":"sub","get_abs_path_only":true} and {"path":"/zig-runner/dagger.json","stat_path_only":true}
    try F.request(&input, 3, h2.diff_copy, "eyJwYXRoIjoic3ViIiwiZ2V0X2Fic19wYXRoX29ubHkiOnRydWV9");
    try F.request(&input, 5, h2.diff_copy, "eyJwYXRoIjoiL3ppZy1ydW5uZXIvZGFnZ2VyLmpzb24iLCJzdGF0X3BhdGhfb25seSI6dHJ1ZX0=");
    try F.request(&input, 7, "/moby.buildkit.secrets.v1.Secrets/GetSecret", "");
    var src: SliceSource = .{ .data = input.items, .step = 7 };
    var in = src.in();
    var out_buf: [2048]u8 = undefined;
    var w: Io.Writer = .fixed(&out_buf);
    try std.testing.expectEqual(@as(usize, 4), try h2.serve(gpa, &in, &w));
    const out = w.buffered();
    // Our SETTINGS, the SETTINGS ack, the PING ack with the same payload.
    try std.testing.expectEqualSlices(u8, &[_]u8{ 0, 0, 0, 0x4, 0, 0, 0, 0, 0 }, out[0..9]);
    try std.testing.expectEqualSlices(u8, &[_]u8{ 0, 0, 0, 0x4, 0x1, 0, 0, 0, 0 }, out[9..18]);
    try std.testing.expectEqualSlices(u8, &([_]u8{ 0, 0, 8, 0x6, 0x1, 0, 0, 0, 0 } ++ "12345678".*), out[18..35]);
    // SERVING for the health check; the absolute path under the empty host root; NOT_FOUND for the
    // stat; UNIMPLEMENTED for anything else.
    try std.testing.expect(std.mem.indexOf(u8, out, &[_]u8{ 0, 0, 0, 0, 2, 0x08, 0x01 }) != null);
    try std.testing.expect(std.mem.indexOf(u8, out, &([_]u8{ 0x0a, 15 } ++ "/zig-runner/sub".*)) != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "grpc-status" ++ [_]u8{ 1, '5' }) != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "grpc-status" ++ [_]u8{ 2, '1', '2' }) != null);
}

test "server-sent events of OTLP log records" {
    const gpa = std.testing.allocator;
    var a: std.heap.ArenaAllocator = .init(gpa);
    defer a.deinit();
    const Got = struct {
        list: std.ArrayList(u8) = .empty,
        fn on(ptr: *anyopaque, rec: LogRecord) void {
            const g: *@This() = @ptrCast(@alignCast(ptr));
            g.list.print(std.testing.allocator, "{s}|{d}|{s}{s}{s};", .{ rec.span, rec.stream, rec.text, if (rec.verbose) "|verbose" else "", if (rec.eof) "|eof" else "" }) catch {};
        }
    };
    var got: Got = .{};
    defer got.list.deinit(gpa);
    const Ctx = struct {
        arena: Allocator,
        h: LogHandler,
        fn onData(ctx: @This(), data: []const u8) void {
            eachLogRecord(ctx.arena, data, ctx.h);
        }
    };
    var sse: Sse = .{};
    defer sse.deinit(gpa);
    const ev =
        \\event: subscribed
        \\
        \\id: 1
        \\data: {"resourceLogs":[{"scopeLogs":[{"logRecords":[{"spanId":"abc123","body":{"stringValue":"hi\n"},"attributes":[{"key":"stdio.stream","value":{"intValue":"1"}}]},{"spanId":"abc123","body":{"bytesValue":"b29wcw=="},"attributes":[{"key":"stdio.stream","value":{"intValue":2}}]},{"spanId":"abc123","body":{"stringValue":""},"attributes":[{"key":"stdio.stream","value":{"intValue":"1"}},{"key":"stdio.eof","value":{"boolValue":true}}]},{"spanId":"def","body":{"stringValue":"hi\n"},"attributes":[{"key":"dagger.io/logs.verbose","value":{"boolValue":true}}]}]}]}]}
        \\
        \\
    ;
    // Fed in pieces, as chunks arrive.
    const ctx: Ctx = .{ .arena = a.allocator(), .h = .{ .ptr = &got, .onRecord = Got.on } };
    try sse.feed(gpa, ev[0..40], ctx, Ctx.onData);
    try sse.feed(gpa, ev[40..], ctx, Ctx.onData);
    try std.testing.expectEqualStrings("abc123|1|hi\n;abc123|2|oops;abc123|1||eof;def|0|hi\n|verbose;", got.list.items);
}

// Live, against the local engine: `ZIG_RUNNER_ENGINE_TEST=1 zig build test`.
test "live: a session runs a query and streams its exec's output" {
    var env = try std.process.Environ.createMap(std.testing.environ, std.testing.allocator);
    defer env.deinit();
    if (env.get("ZIG_RUNNER_ENGINE_TEST") == null) return error.SkipZigTest;
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    const Got = struct {
        mu: Io.Mutex = .init,
        text: std.ArrayList(u8) = .empty,
        fn on(ptr: *anyopaque, rec: LogRecord) void {
            const g: *@This() = @ptrCast(@alignCast(ptr));
            g.mu.lockUncancelable(std.testing.io);
            defer g.mu.unlock(std.testing.io);
            g.text.print(std.testing.allocator, "[{s} {d}] {s}", .{ rec.span, rec.stream, rec.text }) catch {};
        }
    };
    var got: Got = .{};
    defer got.text.deinit(gpa);
    var ep: Endpoint = .{};
    if (env.get("ZIG_RUNNER_DOCKER_SOCKET")) |p| ep.docker_socket = p;
    var s: Session = undefined;
    try s.open(gpa, io, ep, .{ .ptr = &got, .onRecord = Got.on });
    defer s.close();
    var a: std.heap.ArenaAllocator = .init(gpa);
    defer a.deinit();
    var nonce: [8]u8 = undefined;
    io.random(&nonce);
    const doc = try std.fmt.allocPrint(a.allocator(), "{{ container {{ from(address:\"alpine:3.22\") {{ withEnvVariable(name:\"N\",value:\"{x}\") {{ withExec(args:[\"sh\",\"-c\",\"echo out-line; echo err-line >&2; sleep 6; echo after-sleep\"]) {{ stdout }} }} }} }} }}", .{&nonce});
    const resp = try s.query(a.allocator(), doc);
    std.debug.print("\nquery response: {s}\n", .{resp});
    try std.testing.expect(std.mem.indexOf(u8, resp, "after-sleep") != null);
    // The health checks (every 5 s) kept the session alive through the sleep.
    s.close();
    std.debug.print("health checks answered: {d}\nlog stream:\n{s}\n", .{ s.health_answered.load(.monotonic), got.text.items });
    try std.testing.expect(std.mem.indexOf(u8, got.text.items, "out-line") != null);
}
