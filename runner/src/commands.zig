//! Parsing of the file commands a step writes: `$GITHUB_OUTPUT`, `$GITHUB_ENV` and `$GITHUB_PATH`.
//!
//! `GITHUB_OUTPUT` and `GITHUB_ENV` hold `name=value` lines, or a multi-line value:
//!
//!     name<<DELIMITER
//!     line 1
//!     line 2
//!     DELIMITER
//!
//! `GITHUB_PATH` holds one directory per line. Malformed input is an error naming the line, as in
//! GitHub ("Unable to process file command ... successfully"), not silently ignored.
const std = @import("std");
const job_mod = @import("job.zig");

const Allocator = std.mem.Allocator;

pub const Parsed = union(enum) {
    ok: []const job_mod.EnvVar,
    /// Why the file could not be read (names the offending line).
    invalid: []const u8,
};

pub fn parseKeyValues(arena: Allocator, text: []const u8) Allocator.Error!Parsed {
    var out: std.ArrayList(job_mod.EnvVar) = .empty;
    var lines = std.mem.splitScalar(u8, text, '\n');
    var line_no: usize = 0;
    while (lines.next()) |raw| {
        line_no += 1;
        const line = std.mem.trimEnd(u8, raw, "\r");
        if (line.len == 0) continue;
        const eq = std.mem.indexOfScalar(u8, line, '=');
        const heredoc = std.mem.indexOf(u8, line, "<<");
        // `name<<DELIM` wins when it comes before any `=`.
        if (heredoc != null and (eq == null or heredoc.? < eq.?)) {
            const name = line[0..heredoc.?];
            const delim = line[heredoc.? + 2 ..];
            if (name.len == 0 or delim.len == 0)
                return .{ .invalid = try std.fmt.allocPrint(arena, "invalid format '{s}' on line {d}: expected name<<DELIMITER", .{ line, line_no }) };
            var value: std.ArrayList(u8) = .empty;
            var closed = false;
            var first = true;
            while (lines.next()) |body_raw| {
                line_no += 1;
                const body = std.mem.trimEnd(u8, body_raw, "\r");
                if (std.mem.eql(u8, body, delim)) {
                    closed = true;
                    break;
                }
                if (!first) try value.append(arena, '\n');
                try value.appendSlice(arena, body);
                first = false;
            }
            if (!closed) return .{ .invalid = try std.fmt.allocPrint(arena, "matching delimiter '{s}' not found for '{s}'", .{ delim, name }) };
            try out.append(arena, .{ .name = name, .value = value.items });
            continue;
        }
        const e = eq orelse return .{ .invalid = try std.fmt.allocPrint(arena, "invalid format '{s}' on line {d}: expected name=value", .{ line, line_no }) };
        if (e == 0) return .{ .invalid = try std.fmt.allocPrint(arena, "invalid format '{s}' on line {d}: the name is empty", .{ line, line_no }) };
        try out.append(arena, .{ .name = line[0..e], .value = line[e + 1 ..] });
    }
    return .{ .ok = out.items };
}

/// Directories from a GITHUB_PATH file, in the order written.
pub fn parsePaths(arena: Allocator, text: []const u8) Allocator.Error![]const []const u8 {
    var out: std.ArrayList([]const u8) = .empty;
    var lines = std.mem.splitScalar(u8, text, '\n');
    while (lines.next()) |raw| {
        const line = std.mem.trim(u8, raw, " \t\r");
        if (line.len > 0) try out.append(arena, line);
    }
    return out.items;
}

/// GitHub does not let a step redefine its own default variables or ones that inject code.
pub fn isProtectedEnvName(name: []const u8) bool {
    if (std.mem.startsWith(u8, name, "GITHUB_") or std.mem.startsWith(u8, name, "RUNNER_")) return true;
    return std.mem.eql(u8, name, "NODE_OPTIONS") or std.mem.eql(u8, name, "CI");
}

test "name=value, blank lines, and = inside values" {
    var a: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer a.deinit();
    const p = try parseKeyValues(a.allocator(), "a=1\n\nb=x=y\nempty=\n");
    try std.testing.expectEqual(@as(usize, 3), p.ok.len);
    try std.testing.expectEqualStrings("a", p.ok[0].name);
    try std.testing.expectEqualStrings("1", p.ok[0].value);
    try std.testing.expectEqualStrings("x=y", p.ok[1].value);
    try std.testing.expectEqualStrings("", p.ok[2].value);
}

test "multi-line values with a delimiter, including = and << inside the value" {
    var a: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer a.deinit();
    const p = try parseKeyValues(a.allocator(), "msg<<EOF_1\nline one\nk=v << not a heredoc\nEOF_1\nafter=ok\n");
    try std.testing.expectEqual(@as(usize, 2), p.ok.len);
    try std.testing.expectEqualStrings("msg", p.ok[0].name);
    try std.testing.expectEqualStrings("line one\nk=v << not a heredoc", p.ok[0].value);
    try std.testing.expectEqualStrings("ok", p.ok[1].value);
}

test "CRLF line endings" {
    var a: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer a.deinit();
    const p = try parseKeyValues(a.allocator(), "a=1\r\nb<<D\r\nx\r\nD\r\n");
    try std.testing.expectEqualStrings("1", p.ok[0].value);
    try std.testing.expectEqualStrings("x", p.ok[1].value);
}

test "malformed input is reported with the line" {
    var a: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer a.deinit();
    const ar = a.allocator();
    try std.testing.expect(std.mem.indexOf(u8, (try parseKeyValues(ar, "a=1\njust text\n")).invalid, "line 2") != null);
    try std.testing.expect(std.mem.indexOf(u8, (try parseKeyValues(ar, "=v\n")).invalid, "name is empty") != null);
    try std.testing.expect(std.mem.indexOf(u8, (try parseKeyValues(ar, "m<<EOF\nnever closed\n")).invalid, "delimiter 'EOF' not found") != null);
    try std.testing.expect(std.mem.indexOf(u8, (try parseKeyValues(ar, "m<<\nx\n")).invalid, "name<<DELIMITER") != null);
}

test "paths and protected names" {
    var a: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer a.deinit();
    const ps = try parsePaths(a.allocator(), "/opt/tool/bin\n\n  /home/x/.local/bin \n");
    try std.testing.expectEqual(@as(usize, 2), ps.len);
    try std.testing.expectEqualStrings("/home/x/.local/bin", ps[1]);
    try std.testing.expect(isProtectedEnvName("GITHUB_SHA"));
    try std.testing.expect(isProtectedEnvName("RUNNER_OS"));
    try std.testing.expect(isProtectedEnvName("NODE_OPTIONS"));
    try std.testing.expect(!isProtectedEnvName("MY_VAR"));
}
