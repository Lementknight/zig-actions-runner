//! Converts the job's `contextData` (GitHub's pipeline context data encoding) into expression values.
//!
//! Strings, booleans, numbers and null are plain JSON. A dictionary is `{"t":2,"d":[{"k":..,"v":..}]}`
//! and an array is `{"t":1,"a":[..]}`. A null context (for example `matrix` outside a matrix job) is
//! null, so `matrix.os` evaluates to an empty string, as in GitHub.
const std = @import("std");
const expr = @import("expr.zig");

const Allocator = std.mem.Allocator;

pub fn fromContextData(arena: Allocator, v: std.json.Value) Allocator.Error!expr.Value {
    switch (v) {
        .null => return .null,
        .bool => |b| return .{ .boolean = b },
        .integer => |i| return .{ .number = @floatFromInt(i) },
        .float => |f| return .{ .number = f },
        .number_string => |s| return .{ .number = std.fmt.parseFloat(f64, s) catch std.math.nan(f64) },
        .string => |s| return .{ .string = s },
        .array => |a| {
            const out = try arena.alloc(expr.Value, a.items.len);
            for (a.items, out) |e, *o| o.* = try fromContextData(arena, e);
            return .{ .array = out };
        },
        .object => |o| {
            if (o.get("d")) |d| if (d == .array) {
                var entries: std.ArrayList(expr.Value.Entry) = .empty;
                for (d.array.items) |item| {
                    if (item != .object) continue;
                    const k = item.object.get("k") orelse continue;
                    if (k != .string) continue;
                    const val = item.object.get("v") orelse .null;
                    try entries.append(arena, .{ .key = k.string, .value = try fromContextData(arena, val) });
                }
                return .{ .object = entries.items };
            };
            if (o.get("a")) |a| if (a == .array) return fromContextData(arena, a);
            return expr.fromJsonValue(arena, v);
        },
    }
}

/// The value of a named top-level context in `contextData`, or null when it is absent.
pub fn named(arena: Allocator, context_data: std.json.Value, name: []const u8) Allocator.Error!expr.Value {
    if (context_data != .object) return .null;
    const v = context_data.object.get(name) orelse return .null;
    return fromContextData(arena, v);
}

test "dictionaries, arrays, scalars and null" {
    var a: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer a.deinit();
    const arena = a.allocator();
    const json =
        \\{"github":{"t":2,"d":[{"k":"sha","v":"abc"},{"k":"run_number","v":7},{"k":"flag","v":true},
        \\  {"k":"event","v":{"t":2,"d":[{"k":"labels","v":{"t":1,"a":["x","y"]}}]}}]},"matrix":null}
    ;
    const root = try std.json.parseFromSliceLeaky(std.json.Value, arena, json, .{});
    const gh = try named(arena, root, "github");
    const ctxs = [_]expr.Value.Entry{
        .{ .key = "github", .value = gh },
        .{ .key = "matrix", .value = try named(arena, root, "matrix") },
        .{ .key = "absent", .value = try named(arena, root, "absent") },
    };
    const s: expr.Scope = .{ .contexts = &ctxs };
    try std.testing.expectEqualStrings("abc", try expr.evalString(arena, "github.sha", s));
    try std.testing.expectEqualStrings("7", try expr.evalString(arena, "github.run_number", s));
    try std.testing.expectEqualStrings("true", try expr.evalString(arena, "github.flag", s));
    try std.testing.expectEqualStrings("y", try expr.evalString(arena, "github.event.labels[1]", s));
    try std.testing.expectEqualStrings("", try expr.evalString(arena, "matrix.os", s));
    try std.testing.expectEqualStrings("", try expr.evalString(arena, "absent.x", s));
}
