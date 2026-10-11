//! JIT runner registration: `generate-jitconfig` call and `encoded_jit_config` decoding (SPEC §3).
const std = @import("std");
const Config = @import("../config.zig").Config;

const Allocator = std.mem.Allocator;

pub const File = struct {
    name: []const u8,
    content: []const u8,
};

pub const Jit = struct {
    runner_id: u64,
    runner_name: []const u8,
    /// Decoded files (runner settings, RSA credentials, OAuth credential data). Sensitive.
    files: []const File,
};

pub const Error = error{
    /// Non-2xx from GitHub. Maps to exit code 2.
    GithubRejected,
    BadResponse,
} || Allocator.Error || std.http.Client.FetchError;

fn runnersUrl(arena: Allocator, cfg: *const Config) Allocator.Error![]const u8 {
    return switch (cfg.scope) {
        .repo => |r| std.fmt.allocPrint(arena, "https://api.github.com/repos/{s}/{s}/actions/runners", .{ r.owner, r.name }),
        .org => |o| std.fmt.allocPrint(arena, "https://api.github.com/orgs/{s}/actions/runners", .{o}),
    };
}

/// Request a JIT config for `name`. All returned memory is allocated from `arena`.
/// `status_out` receives the HTTP status for diagnostics.
pub fn generate(
    arena: Allocator,
    io: std.Io,
    cfg: *const Config,
    name: []const u8,
    status_out: *std.http.Status,
) Error!Jit {
    const url = try std.fmt.allocPrint(arena, "{s}/generate-jitconfig", .{try runnersUrl(arena, cfg)});

    var labels: std.ArrayList([]const u8) = .empty;
    var it = std.mem.tokenizeScalar(u8, cfg.labels, ',');
    while (it.next()) |l| try labels.append(arena, std.mem.trim(u8, l, " "));

    var body: std.Io.Writer.Allocating = .init(arena);
    try std.json.Stringify.value(.{
        .name = name,
        .runner_group_id = cfg.runner_group_id,
        .labels = labels.items,
    }, .{}, &body.writer);

    const auth = try std.fmt.allocPrint(arena, "Bearer {s}", .{cfg.gh_token});

    var client: std.http.Client = .{ .allocator = arena, .io = io };
    defer client.deinit();

    var resp: std.Io.Writer.Allocating = .init(arena);
    const result = try client.fetch(.{
        .location = .{ .url = url },
        .method = .POST,
        .payload = body.written(),
        .headers = .{
            .authorization = .{ .override = auth },
            .content_type = .{ .override = "application/json" },
        },
        .extra_headers = &.{
            .{ .name = "Accept", .value = "application/vnd.github+json" },
            .{ .name = "X-GitHub-Api-Version", .value = "2022-11-28" },
        },
        .response_writer = &resp.writer,
    });
    status_out.* = result.status;
    if (result.status.class() != .success) return error.GithubRejected;

    return parseResponse(arena, resp.written());
}

/// Parse the `generate-jitconfig` response body.
pub fn parseResponse(arena: Allocator, body: []const u8) Error!Jit {
    const Resp = struct {
        runner: struct { id: u64, name: []const u8 },
        encoded_jit_config: []const u8,
    };
    const parsed = std.json.parseFromSliceLeaky(Resp, arena, body, .{ .ignore_unknown_fields = true }) catch |e| switch (e) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return error.BadResponse,
    };
    return .{
        .runner_id = parsed.runner.id,
        .runner_name = parsed.runner.name,
        .files = decode(arena, parsed.encoded_jit_config) catch |e| switch (e) {
            error.OutOfMemory => return error.OutOfMemory,
            else => return error.BadResponse,
        },
    };
}

/// `encoded_jit_config` is base64 JSON `{ "<filename>": "<base64 content>" }` (unverified against live GitHub).
pub fn decode(arena: Allocator, encoded: []const u8) ![]const File {
    const dec = std.base64.standard.Decoder;
    const json_bytes = try arena.alloc(u8, try dec.calcSizeForSlice(encoded));
    try dec.decode(json_bytes, encoded);

    const map = try std.json.parseFromSliceLeaky(std.json.ArrayHashMap([]const u8), arena, json_bytes, .{});
    const files = try arena.alloc(File, map.map.count());
    for (map.map.keys(), map.map.values(), files) |k, v, *f| {
        const content = try arena.alloc(u8, try dec.calcSizeForSlice(v));
        try dec.decode(content, v);
        f.* = .{ .name = k, .content = content };
    }
    return files;
}

test "decode nested base64 files" {
    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    // {".runner":"aGVsbG8=",".credentials":"d29ybGQ="}
    const enc = "eyIucnVubmVyIjoiYUdWc2JHOD0iLCIuY3JlZGVudGlhbHMiOiJkMjl5YkdRPSJ9";
    const files = try decode(arena, enc);
    try std.testing.expectEqual(@as(usize, 2), files.len);
    try std.testing.expectEqualStrings(".runner", files[0].name);
    try std.testing.expectEqualStrings("hello", files[0].content);
    try std.testing.expectEqualStrings("world", files[1].content);
}

test "parse generate-jitconfig response" {
    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();
    const body =
        \\{"runner":{"id":23,"name":"zig-h-1","os":"unknown","status":"offline"},
        \\ "encoded_jit_config":"eyIucnVubmVyIjoiYUdWc2JHOD0ifQ=="}
    ;
    const jit = try parseResponse(arena_state.allocator(), body);
    try std.testing.expectEqual(@as(u64, 23), jit.runner_id);
    try std.testing.expectEqualStrings("hello", jit.files[0].content);
}

test "bad response" {
    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();
    try std.testing.expectError(error.BadResponse, parseResponse(arena_state.allocator(), "{}"));
}
