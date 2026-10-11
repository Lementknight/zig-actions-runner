//! Run service calls for the v2 flow: acknowledge, acquirejob, completejob.
//! The URL comes from the broker's `RunnerJobRequest` message. Request shapes are from the
//! `actions/runner` source; live findings are recorded in SPEC §3.
const std = @import("std");
const broker = @import("broker.zig");

const Allocator = std.mem.Allocator;

pub const api_version = "2024-11-01";

/// The JSON document nested in the `body` string of a `RunnerJobRequest` message.
pub const JobRequest = struct {
    runner_request_id: []const u8,
    run_service_url: []const u8,
    billing_owner_id: []const u8 = "",
    should_acknowledge: bool = false,
};

pub fn parseJobRequest(arena: Allocator, body: []const u8) !JobRequest {
    return std.json.parseFromSliceLeaky(JobRequest, arena, body, .{ .ignore_unknown_fields = true });
}

pub fn endpoint(arena: Allocator, req: JobRequest, op: []const u8) Allocator.Error![]const u8 {
    const base = std.mem.trimEnd(u8, req.run_service_url, "/");
    return std.fmt.allocPrint(arena, "{s}/{s}?api-version={s}", .{ base, op, api_version });
}

fn post(arena: Allocator, io: std.Io, req: JobRequest, token: []const u8, op: []const u8, body: []const u8) !broker.Response {
    return broker.call(arena, io, .POST, try endpoint(arena, req, op), token, body);
}

pub fn acknowledge(arena: Allocator, io: std.Io, req: JobRequest, token: []const u8) !broker.Response {
    const body = try std.fmt.allocPrint(arena, "{{\"runnerRequestId\":\"{s}\"}}", .{req.runner_request_id});
    return post(arena, io, req, token, "acknowledge", body);
}

/// Returns the job definition (steps, contexts, variables, tokens). Treat the body as secret.
pub fn acquire(arena: Allocator, io: std.Io, req: JobRequest, token: []const u8) !broker.Response {
    const body = try std.fmt.allocPrint(
        arena,
        "{{\"jobMessageId\":\"{s}\",\"runnerOS\":\"Linux\",\"billingOwnerId\":\"{s}\"}}",
        .{ req.runner_request_id, req.billing_owner_id },
    );
    return post(arena, io, req, token, "acquirejob", body);
}

pub const Conclusion = enum { succeeded, failed, cancelled };

pub fn complete(
    arena: Allocator,
    io: std.Io,
    req: JobRequest,
    token: []const u8,
    plan_id: []const u8,
    job_id: []const u8,
    conclusion: Conclusion,
) !broker.Response {
    const body = try std.fmt.allocPrint(
        arena,
        "{{\"planId\":\"{s}\",\"jobId\":\"{s}\",\"conclusion\":\"{s}\",\"outputs\":{{}},\"stepResults\":[],\"annotations\":[],\"telemetry\":[]}}",
        .{ plan_id, job_id, @tagName(conclusion) },
    );
    return post(arena, io, req, token, "completejob", body);
}

test "parse nested job request and build endpoint" {
    var a: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer a.deinit();
    const r = try parseJobRequest(a.allocator(), "{\"runner_request_id\":\"abc\",\"run_service_url\":\"https://r.test/\",\"billing_owner_id\":\"U_1\",\"should_acknowledge\":true}");
    try std.testing.expect(r.should_acknowledge);
    try std.testing.expectEqualStrings("https://r.test/acquirejob?api-version=2024-11-01", try endpoint(a.allocator(), r, "acquirejob"));
}
