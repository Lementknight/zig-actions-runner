//! `--inspect`: probe the live JIT/OAuth flow without exposing secrets.
//! Prints the shape of every decoded config file (key names, types, lengths). Only `.runner`,
//! which holds URLs and ids, has its values printed. Always deletes the runner it registered.
const std = @import("std");
const Config = @import("config.zig").Config;
const jitconfig = @import("github/jitconfig.zig");
const auth = @import("github/auth.zig");
const broker = @import("github/broker.zig");
const runservice = @import("github/runservice.zig");
const timefmt = @import("timefmt.zig");

const Allocator = std.mem.Allocator;

pub fn run(arena: Allocator, io: std.Io, cfg: *const Config, name: []const u8, out: *std.Io.Writer) !u8 {
    broker.trace = true;
    var status: std.http.Status = .ok;
    const jit = jitconfig.generate(arena, io, cfg, name, &status) catch |e| {
        try out.print("generate-jitconfig failed: {s} (HTTP {d})\n", .{ @errorName(e), @backingInt(status) });
        return 2;
    };
    defer cleanup(arena, io, cfg, jit.runner_id, out);

    try out.print("registered runner '{s}' id={d}, {d} files\n", .{ jit.runner_name, jit.runner_id, jit.files.len });
    for (jit.files) |f| {
        try out.print("\n== {s} ({d} bytes)\n", .{ f.name, f.content.len });
        const show_values = std.mem.eql(u8, f.name, ".runner");
        const parsed = std.json.parseFromSliceLeaky(std.json.Value, arena, f.content, .{}) catch {
            try out.writeAll("  (not JSON)\n");
            continue;
        };
        try shape(out, parsed, 1, show_values);
    }

    const creds = auth.parseCredentials(arena, jit.files) catch |e| {
        try out.print("\nparseCredentials failed: {s}\n", .{@errorName(e)});
        return 2;
    };
    var jti: [8]u8 = undefined;
    io.random(&jti);
    const jti_hex = try std.fmt.allocPrint(arena, "{x}", .{jti});
    const now = std.Io.Clock.real.now(io).toSeconds();
    const jwt = try auth.buildJwt(arena, creds, now, jti_hex);
    const token = auth.fetchAccessToken(arena, io, creds, jwt, &status) catch |e| {
        try out.print("\nOAuth token exchange failed: {s} (HTTP {d})\n", .{ @errorName(e), @backingInt(status) });
        return 2;
    };
    try out.print("\nOAuth token exchange: HTTP {d}, access_token {d} chars\n", .{ @backingInt(status), token.len });

    const settings = try broker.parseSettings(arena, jit.files);
    const base = try std.fmt.allocPrint(arena, "{s}{s}", .{ settings.broker_url, if (std.mem.endsWith(u8, settings.broker_url, "/")) "" else "/" });
    const body = try broker.sessionBody(arena, settings, "zig-inspect");
    const url = try std.fmt.allocPrint(arena, "{s}session", .{base});
    try out.print("\nPOST session ... (body {d} bytes)\n", .{body.len});
    try out.flush();
    const resp = try broker.call(arena, io, .POST, url, token, body);
    try out.print("\nPOST session -> HTTP {d}\n", .{@backingInt(resp.status)});
    const parsed = std.json.parseFromSliceLeaky(std.json.Value, arena, resp.body, .{}) catch null;
    if (resp.status.class() == .success) {
        // Session responses can carry an encryption key: shape only.
        if (parsed) |v| try shape(out, v, 1, false) else try out.print("  (non-JSON, {d} bytes)\n", .{resp.body.len});
        if (parsed) |v| if (v == .object) if (v.object.get("sessionId")) |sid| if (sid == .string) {
            // Poll until a message arrives (up to ~5 min). Message bodies can hold tokens: shape only.
            var polls: usize = 0;
            while (polls < 6) : (polls += 1) {
                try out.print("GET message (poll {d}, long-poll ~50s) ...\n", .{polls + 1});
                try out.flush();
                const m = try broker.call(arena, io, .GET, try broker.messageUrl(arena, base, sid.string, "Online"), token, null);
                try out.print("GET message -> HTTP {d}, {d} body bytes\n", .{ @backingInt(m.status), m.body.len });
                if (m.status.class() != .success) {
                    try out.print("  error body: {s}\n", .{m.body[0..@min(m.body.len, 400)]});
                    break;
                }
                if (m.body.len == 0) continue;
                const mv = std.json.parseFromSliceLeaky(std.json.Value, arena, m.body, .{}) catch {
                    try out.writeAll("  (non-JSON body)\n");
                    break;
                };
                try shape(out, mv, 1, false);
                // v2 job requests nest another JSON document in `body`.
                if (mv == .object) if (mv.object.get("body")) |bv| if (bv == .string) {
                    if (std.json.parseFromSliceLeaky(std.json.Value, arena, bv.string, .{}) catch null) |inner| {
                        try out.writeAll("  body (parsed):\n");
                        try shape(out, inner, 2, false);
                        if (inner == .object) if (inner.object.get("run_service_url")) |u| if (u == .string)
                            try out.print("  run_service_url host: {s}\n", .{hostOnly(u.string)});
                        try probeRunService(arena, io, out, token, bv.string);
                    } else try out.writeAll("  body is not JSON\n");
                };
                if (mv == .object) for ([_][]const u8{ "messageType", "MessageType" }) |k| if (mv.object.get(k)) |t| if (t == .string)
                    try out.print("  message type: {s}\n", .{t.string});
                break;
            }
            const q = try std.fmt.allocPrint(arena, "{s}session?sessionId={s}", .{ base, sid.string });
            const d = try broker.call(arena, io, .DELETE, q, token, null);
            try out.print("DELETE session -> HTTP {d}\n", .{@backingInt(d.status)});
        };
    } else {
        // Error bodies are small and carry no credentials.
        try out.print("  body: {s}\n", .{resp.body[0..@min(resp.body.len, 600)]});
    }
    return 0;
}

fn cleanup(arena: Allocator, io: std.Io, cfg: *const Config, runner_id: u64, out: *std.Io.Writer) void {
    const st = jitconfig.deleteRunner(arena, io, cfg, runner_id) catch |e| {
        out.print("!! cleanup failed: {s}; delete runner id {d} manually\n", .{ @errorName(e), runner_id }) catch {};
        return;
    };
    out.print("cleanup: DELETE runner {d} -> HTTP {d}\n", .{ runner_id, @backingInt(st) }) catch {};
}

fn shape(w: *std.Io.Writer, v: std.json.Value, depth: usize, show: bool) !void {
    switch (v) {
        .object => |o| {
            var it = o.iterator();
            while (it.next()) |e| {
                try w.splatByteAll(0x20, depth * 2);
                try w.print("{s}: ", .{e.key_ptr.*});
                switch (e.value_ptr.*) {
                    .object, .array => {
                        try w.print("{s}\n", .{@tagName(e.value_ptr.*)});
                        try shape(w, e.value_ptr.*, depth + 1, show);
                    },
                    else => try scalar(w, e.value_ptr.*, show),
                }
            }
        },
        .array => |a| {
            try w.splatByteAll(0x20, depth * 2);
            try w.print("[{d} items]\n", .{a.items.len});
            if (a.items.len > 0 and (a.items[0] == .object or a.items[0] == .array)) try shape(w, a.items[0], depth + 1, show);
        },
        else => {},
    }
}

fn scalar(w: *std.Io.Writer, v: std.json.Value, show: bool) !void {
    switch (v) {
        .string => |s| if (show) try w.print("\"{s}\"\n", .{hostOnly(s)}) else try w.print("string({d})\n", .{s.len}),
        .integer => |i| if (show) try w.print("{d}\n", .{i}) else try w.writeAll("integer\n"),
        .bool => |b| if (show) try w.print("{}\n", .{b}) else try w.writeAll("bool\n"),
        .null => try w.writeAll("null\n"),
        else => try w.print("{s}\n", .{@tagName(v)}),
    }
}

/// URLs often carry per-runner tokens in the path; keep scheme and host only.
fn hostOnly(s: []const u8) []const u8 {
    const scheme = std.mem.indexOf(u8, s, "://") orelse return s;
    const path = std.mem.indexOfScalarPos(u8, s, scheme + 3, '/') orelse return s;
    return s[0..path];
}

/// Acknowledge, acquire and complete the job, printing only statuses and the shape of the response.
/// Completes as `succeeded` without running anything: only for throwaway probe jobs.
fn probeRunService(arena: Allocator, io: std.Io, out: *std.Io.Writer, token: []const u8, body: []const u8) !void {
    const jr = runservice.parseJobRequest(arena, body) catch |e| {
        try out.print("  parseJobRequest failed: {s}\n", .{@errorName(e)});
        return;
    };
    // `acknowledge` is skipped: it needs an HMAC and acquirejob works without it (SPEC §3).
    try out.flush();
    const r = try runservice.acquire(arena, io, jr, token);
    try out.print("POST acquirejob -> HTTP {d}, {d} body bytes\n", .{ @backingInt(r.status), r.body.len });
    if (r.status.class() != .success) {
        try out.print("  error body: {s}\n", .{r.body[0..@min(r.body.len, 600)]});
        return;
    }
    const job = std.json.parseFromSliceLeaky(std.json.Value, arena, r.body, .{}) catch {
        try out.writeAll("  (non-JSON body)\n");
        return;
    };
    // The job definition holds tokens and secrets: key names, types and lengths only.
    try shape(out, job, 1, false);
    try out.flush();

    const plan_id = nestedString(job, &.{ "plan", "planId" }) orelse "";
    const job_id = nestedString(job, &.{"jobId"}) orelse "";
    try out.print("  planId {d} chars, jobId {d} chars\n", .{ plan_id.len, job_id.len });
    if (firstStepScript(job)) |sc| try out.print("  step[0] script: {s} = {s}\n", .{ sc.key, sc.value });
    // The run service authorizes later calls with the job-scoped token from the job's endpoints.
    const job_token = jobToken(job) orelse {
        try out.writeAll("  no job token in resources.endpoints\n");
        return;
    };
    try out.print("  job token: {d} chars\n", .{job_token.len});
    // The shape of `stepResults` is not documented: try candidates on this one acquired job until
    // completejob accepts one (a rejected attempt leaves the job held, so we can keep trying).
    const step_id = firstStepId(job) orelse "00000000-0000-0000-0000-000000000000";
    const t1 = try timefmt.isoTime(arena, std.Io.Clock.real.now(io).toMilliseconds() - 2000);
    const t2 = try timefmt.isoTime(arena, std.Io.Clock.real.now(io).toMilliseconds());
    const secs_only = try std.fmt.allocPrint(arena, "{s}Z", .{t1[0 .. t1.len - 5]});
    const secs_only2 = try std.fmt.allocPrint(arena, "{s}Z", .{t2[0 .. t2.len - 5]});
    const candidates = [_][]const u8{
        try std.fmt.allocPrint(arena, "[{{\"external_id\":\"{s}\",\"number\":1,\"name\":\"probe\",\"status\":\"completed\",\"conclusion\":\"succeeded\",\"started_at\":\"{s}\",\"completed_at\":\"{s}\"}}]", .{ step_id, t1, t2 }),
        try std.fmt.allocPrint(arena, "[{{\"external_id\":\"{s}\",\"number\":1,\"name\":\"probe\",\"status\":\"completed\",\"conclusion\":\"succeeded\"}}]", .{step_id}),
        try std.fmt.allocPrint(arena, "[{{\"external_id\":\"{s}\",\"number\":1,\"name\":\"probe\",\"status\":\"completed\",\"conclusion\":\"succeeded\",\"started_at\":\"{s}\",\"completed_at\":\"{s}\"}}]", .{ step_id, secs_only, secs_only2 }),
        try std.fmt.allocPrint(arena, "[{{\"external_id\":\"{s}\",\"number\":1,\"name\":\"probe\",\"status\":\"completed\",\"conclusion\":\"success\"}}]", .{step_id}),
        try std.fmt.allocPrint(arena, "[{{\"external_id\":\"{s}\",\"number\":1,\"name\":\"probe\",\"status\":\"Completed\",\"conclusion\":\"Succeeded\"}}]", .{step_id}),
        try std.fmt.allocPrint(arena, "[{{\"external_id\":\"{s}\",\"number\":1,\"name\":\"probe\",\"status\":2,\"conclusion\":2}}]", .{step_id}),
        "[]",
    };
    for (candidates, 0..) |cand, i| {
        const c = try runservice.complete(arena, io, jr, job_token, plan_id, job_id, .succeeded, cand);
        try out.print("POST completejob (stepResults variant {d}) -> HTTP {d}\n", .{ i, @backingInt(c.status) });
        if (c.status.class() == .success) {
            try out.print("  accepted shape: {s}\n", .{cand});
            break;
        }
        try out.print("  error body: {s}\n", .{c.body[0..@min(c.body.len, 300)]});
        try out.flush();
    }
}

fn firstStepId(job: std.json.Value) ?[]const u8 {
    const steps = job.object.get("steps") orelse return null;
    if (steps != .array or steps.array.items.len == 0) return null;
    return nestedString(steps.array.items[0], &.{"id"});
}

fn nestedString(v: std.json.Value, path: []const []const u8) ?[]const u8 {
    var cur = v;
    for (path) |k| {
        if (cur != .object) return null;
        cur = cur.object.get(k) orelse return null;
    }
    return if (cur == .string) cur.string else null;
}

fn jobToken(job: std.json.Value) ?[]const u8 {
    const eps = (job.object.get("resources") orelse return null).object.get("endpoints") orelse return null;
    if (eps != .array) return null;
    for (eps.array.items) |ep| {
        if (ep != .object) continue;
        const authz = ep.object.get("authorization") orelse continue;
        if (authz != .object) continue;
        if (nestedString(authz, &.{ "parameters", "AccessToken" })) |t| return t;
    }
    return null;
}

const Script = struct { key: []const u8, value: []const u8 };

/// `run:` steps arrive as an action step with reference.type "script" and a template-token map input.
fn firstStepScript(job: std.json.Value) ?Script {
    const steps = job.object.get("steps") orelse return null;
    if (steps != .array or steps.array.items.len == 0) return null;
    const map = (steps.array.items[0].object.get("inputs") orelse return null).object.get("map") orelse return null;
    if (map != .array or map.array.items.len == 0) return null;
    const kv = map.array.items[0];
    return .{
        .key = nestedString(kv.object.get("Key") orelse return null, &.{"lit"}) orelse return null,
        .value = nestedString(kv.object.get("Value") orelse return null, &.{"lit"}) orelse return null,
    };
}
