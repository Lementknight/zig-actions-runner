//! Broker session and message long-poll (v2 flow). Endpoints and bodies come from `actions/runner`
//! source and are verified live via `runner --inspect`; see SPEC §3.
const std = @import("std");
const jitconfig = @import("jitconfig.zig");
const auth = @import("auth.zig");
const http = @import("http.zig");

const Allocator = std.mem.Allocator;

pub const version = "2.338.0";

pub const Settings = struct {
    agent_id: u64,
    agent_name: []const u8,
    broker_url: []const u8,
    use_v2: bool,
};

pub fn parseSettings(arena: Allocator, files: []const jitconfig.File) !Settings {
    const json = auth.findFile(files, ".runner") orelse return error.MissingFile;
    const R = struct {
        AgentId: []const u8,
        AgentName: []const u8,
        ServerUrlV2: []const u8,
        UseV2Flow: []const u8,
    };
    const r = try std.json.parseFromSliceLeaky(R, arena, json, .{ .ignore_unknown_fields = true });
    return .{
        .agent_id = try std.fmt.parseInt(u64, r.AgentId, 10),
        .agent_name = r.AgentName,
        .broker_url = r.ServerUrlV2,
        .use_v2 = std.ascii.eqlIgnoreCase(r.UseV2Flow, "true"),
    };
}

pub const Response = struct {
    status: std.http.Status,
    body: []const u8,
};

pub fn call(
    arena: Allocator,
    io: std.Io,
    method: std.http.Method,
    url: []const u8,
    token: []const u8,
    payload: ?[]const u8,
) !Response {
    return request(arena, io, method, url, payload, .{ .token = token });
}

pub const RequestOptions = struct {
    /// Sent as `Authorization: Bearer`. Leave null for signed URLs (blob storage rejects extra
    /// auth).
    token: ?[]const u8 = null,
    content_type: []const u8 = "application/json",
    extra_headers: []const std.http.Header = &.{},
};

pub fn request(
    arena: Allocator,
    io: std.Io,
    method: std.http.Method,
    url: []const u8,
    payload: ?[]const u8,
    opts: RequestOptions,
) !Response {
    // A kept-alive connection the server had closed while it sat idle (seen on completejob after a
    // 16-minute step): no byte came back (HttpConnectionClosing), or the request could not even be
    // written (WriteFailed, seen on log uploads to blob storage), so it was never processed, and
    // the connection is dropped (see `requestOnce`). The pool can hold several such connections to
    // the same host (six jobs finishing at once after minutes of quiet), so try again until a live
    // or new connection answers.
    var attempt: u32 = 0;
    while (true) : (attempt += 1) {
        return requestOnce(arena, io, method, url, payload, opts) catch |err| switch (err) {
            error.HttpConnectionClosing, error.WriteFailed => if (attempt < max_stale_retries)
                continue
            else
                err,
            else => err,
        };
    }
}

/// More than the connections a host plausibly has idle in the pool.
const max_stale_retries = 8;

fn requestOnce(
    arena: Allocator,
    io: std.Io,
    method: std.http.Method,
    url: []const u8,
    payload: ?[]const u8,
    opts: RequestOptions,
) !Response {
    // What the request needs only while it runs (headers, the decompression window) is freed with
    // it; only the response body goes to `arena`, which a waiting runner keeps until its next job.
    var scratch_state: std.heap.ArenaAllocator = .init(if (http.shared) |c| c.allocator else arena);
    defer scratch_state.deinit();
    const scratch = scratch_state.allocator();
    const bearer: ?[]const u8 = if (opts.token) |t| try std.fmt.allocPrint(
        scratch,
        "Bearer {s}",
        .{t},
    ) else null;
    const headers = try acceptJsonHeaders(scratch, opts.extra_headers);
    // The default 1 KiB write buffer is smaller than the ~1.6 KiB bearer token; requests stall.
    var local: std.http.Client = .{ .allocator = arena, .io = io, .write_buffer_size = 16 * 1024 };
    defer local.deinit();
    const client = http.client(&local);

    if (trace) std.debug.print(
        "trace: connecting {s} {s}\n",
        .{ @tagName(method), url[0 .. std.mem.indexOfScalarPos(u8, url, 8, '/') orelse url.len] },
    );
    var req = try client.request(method, try std.Uri.parse(url), .{
        .headers = .{
            .authorization = if (bearer) |b| .{ .override = b } else .default,
            .content_type = if (payload != null) .{ .override = opts.content_type } else .default,
        },
        .extra_headers = headers,
    });
    defer req.deinit();
    // A connection a request failed on is not given back to the pool: one that failed while writing
    // (the server had closed it) would otherwise fail every later request to that host, which is
    // how every log upload of a runner failed from one moment on.
    errdefer if (req.connection) |conn| {
        conn.closing = true;
    };

    if (trace) std.debug.print("trace: connected\n", .{});
    try send(&req, payload);
    if (trace) std.debug.print("trace: request sent\n", .{});

    var response = try req.receiveHead(&.{});
    if (trace) std.debug.print("trace: head status={d} content_length={?d} chunked={}\n", .{
        @backingInt(response.head.status),
        response.head.content_length,
        response.head.transfer_encoding == .chunked,
    });

    // 204/304 carry no body. Without Content-Length, Request.deinit would wait on the socket for
    // one, so mark the connection closing (deinit then skips draining it).
    if (response.head.status == .no_content or response.head.status == .not_modified) {
        req.connection.?.closing = true;
        return .{ .status = response.head.status, .body = "" };
    }

    const body = try readBody(scratch, &response);
    if (trace) std.debug.print("trace: body {d} bytes\n", .{body.len});
    return .{ .status = response.head.status, .body = try arena.dupe(u8, body) };
}

/// `Accept: application/json` ahead of the caller's headers.
fn acceptJsonHeaders(scratch: Allocator, extra: []const std.http.Header) ![]std.http.Header {
    const headers = try scratch.alloc(std.http.Header, extra.len + 1);
    headers[0] = .{ .name = "Accept", .value = "application/json" };
    @memcpy(headers[1..], extra);
    return headers;
}

/// The request line and headers, then `payload` as the body when there is one.
fn send(req: *std.http.Client.Request, payload: ?[]const u8) !void {
    const p = payload orelse return req.sendBodiless();
    req.transfer_encoding = .{ .content_length = p.len };
    var body = try req.sendBodyUnflushed(&.{});
    try body.writer.writeAll(p);
    try body.end();
    try req.connection.?.flush();
}

/// The whole body, decompressed, on `scratch`.
fn readBody(scratch: Allocator, response: *std.http.Client.Response) ![]const u8 {
    var resp: std.Io.Writer.Allocating = .init(scratch);
    var transfer_buffer: [64]u8 = undefined;
    var decompress: std.http.Decompress = undefined;
    const decompress_buffer = try scratch.alloc(u8, std.compress.flate.max_window_len);
    const reader = response.readerDecompressing(&transfer_buffer, &decompress, decompress_buffer);
    _ = reader.streamRemaining(&resp.writer) catch |err| switch (err) {
        error.ReadFailed => return response.bodyErr().?,
        else => |e| return e,
    };
    return resp.written();
}

/// The machine's architecture as GitHub names it (`runner.arch`, RUNNER_ARCH): the runner, the
/// engine and the steps' containers all run on it.
pub const arch = switch (@import("builtin").cpu.arch) {
    .x86_64 => "X64",
    .aarch64 => "ARM64",
    .arm => "ARM",
    .x86 => "X86",
    else => @compileError("unsupported architecture"),
};

/// Prints request stages to stderr (never headers or bodies). Set while probing.
pub var trace = false;

pub fn messageUrl(
    arena: Allocator,
    base: []const u8,
    session_id: []const u8,
    status: []const u8,
) ![]const u8 {
    return std.fmt.allocPrint(
        arena,
        "{s}message?sessionId={s}&status={s}&runnerVersion={s}" ++
            "&os=Linux&architecture=" ++ arch ++ "&disableUpdate=true",
        .{ base, session_id, status, version },
    );
}

pub fn sessionBody(arena: Allocator, s: Settings, owner: []const u8) ![]const u8 {
    return std.fmt.allocPrint(
        arena,
        "{{\"ownerName\":\"{s}\",\"agent\":{{\"id\":{d},\"name\":\"{s}\",\"version\":\"{s}\"," ++
            "\"osDescription\":\"Linux\",\"ephemeral\":true,\"disableUpdate\":true}}," ++
            "\"useFipsEncryption\":false}}",
        .{ owner, s.agent_id, s.agent_name, version },
    );
}

test "parseSettings" {
    var a: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer a.deinit();
    const files = [_]jitconfig.File{.{ .name = ".runner", .content = "{\"AgentId\":\"2\",\"AgentName\":\"n\",\"ServerUrlV2\":\"https://b/\",\"UseV2Flow\":\"true\",\"Extra\":1}" }};
    const s = try parseSettings(a.allocator(), &files);
    try std.testing.expectEqual(@as(u64, 2), s.agent_id);
    try std.testing.expect(s.use_v2);
}
