//! Exposes `src/regex.zig` so another implementation can be compared against it.
//!
//! Reads one JSON object per line on stdin — `{"pattern": "...", "input": "..."}` — and writes one
//! per line on stdout: `{"ok": true, "match": true, "groups": ["a", null]}`, or `{"ok": false,
//! "error": "Unsupported"}` for a pattern the engine refuses.
//!
//! `tools/regex_diff.py` drives it against Python's `re` (with `re.ASCII`, so the shorthands mean
//! the same bytes). Writing our own matcher is only defensible if something else agrees with it.

const std = @import("std");
const regex = @import("regex");

pub fn main(init: std.process.Init) !u8 {
    const arena = init.arena.allocator();
    const io = init.io;

    var out_buf: [64 * 1024]u8 = undefined;
    var writer: std.Io.File.Writer = .initStreaming(.stdout(), io, &out_buf);
    const w = &writer.interface;
    defer w.flush() catch {};

    // All of stdin at once, then split. A line-at-a-time `takeDelimiterExclusive` on stdin hung
    // here; `allocRemaining` is the idiom `tools/measure.zig` already uses on a stream, and the
    // corpus is small enough that holding it costs nothing.
    var in_buf: [4096]u8 = undefined;
    var reader = std.Io.File.stdin().readerStreaming(io, &in_buf);
    const all = try reader.interface.allocRemaining(arena, .limited(64 * 1024 * 1024));

    var lines = std.mem.splitScalar(u8, all, '\n');
    while (lines.next()) |line| {
        if (std.mem.trim(u8, line, " \t\r").len == 0) continue;
        const parsed = std.json.parseFromSlice(struct { pattern: []const u8, input: []const u8 }, arena, line, .{}) catch {
            try w.writeAll("{\"ok\":false,\"error\":\"BadRequest\"}\n");
            continue;
        };
        const case = parsed.value;

        // Each case gets its own arena: a compiled program and its captures are only needed here,
        // and a pattern that expands to thousands of instructions should not accumulate.
        var case_arena: std.heap.ArenaAllocator = .init(init.gpa);
        defer case_arena.deinit();
        const ca = case_arena.allocator();

        const re = regex.Regex.compile(ca, case.pattern) catch |e| {
            try w.print("{{\"ok\":false,\"error\":\"{s}\"}}\n", .{@errorName(e)});
            continue;
        };
        const found = re.find(ca, case.input, 0) catch |e| {
            try w.print("{{\"ok\":false,\"error\":\"{s}\"}}\n", .{@errorName(e)});
            continue;
        };
        if (found) |m| {
            try w.writeAll("{\"ok\":true,\"match\":true,\"groups\":[");
            for (0..re.group_count) |i| {
                if (i > 0) try w.writeByte(',');
                if (m.text(i + 1, case.input)) |t| {
                    try std.json.Stringify.value(t, .{}, w);
                } else {
                    try w.writeAll("null");
                }
            }
            try w.writeAll("]}\n");
        } else {
            try w.writeAll("{\"ok\":true,\"match\":false,\"groups\":[]}\n");
        }
    }
    return 0;
}
