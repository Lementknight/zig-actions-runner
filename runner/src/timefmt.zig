//! Timestamp formatting.
const std = @import("std");

const Allocator = std.mem.Allocator;

pub fn isoTime(arena: Allocator, ms: i64) Allocator.Error![]const u8 {
    const secs: u64 = @intCast(@divFloor(ms, 1000));
    const es: std.time.epoch.EpochSeconds = .{ .secs = secs };
    const yd = es.getEpochDay().calculateYearDay();
    const md = yd.calculateMonthDay();
    const ds = es.getDaySeconds();
    return std.fmt.allocPrint(arena, "{d:0>4}-{d:0>2}-{d:0>2}T{d:0>2}:{d:0>2}:{d:0>2}.{d:0>3}Z", .{
        yd.year,                            md.month.numeric(),      md.day_index + 1,
        ds.getHoursIntoDay(),               ds.getMinutesIntoHour(), ds.getSecondsIntoMinute(),
        @as(u64, @intCast(@mod(ms, 1000))),
    });
}

/// Log blobs use 7 fractional digits ("2026-10-11T17:45:56.4050000Z").
pub fn isoTime7(arena: Allocator, ms: i64) Allocator.Error![]const u8 {
    const t = try isoTime(arena, ms);
    return std.fmt.allocPrint(arena, "{s}0000Z", .{t[0 .. t.len - 1]});
}

test "isoTime formats UTC with milliseconds" {
    var a: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer a.deinit();
    try std.testing.expectEqualStrings("2026-10-11T17:23:25.042Z", try isoTime(a.allocator(), 1791739405042));
    try std.testing.expectEqualStrings("1970-01-01T00:00:00.000Z", try isoTime(a.allocator(), 0));
}

test "isoTime7 pads to 100ns digits" {
    var a: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer a.deinit();
    try std.testing.expectEqualStrings("2026-10-11T17:23:25.0420000Z", try isoTime7(a.allocator(), 1791739405042));
}
