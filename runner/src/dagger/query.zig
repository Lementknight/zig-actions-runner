//! A Dagger GraphQL document, built one call at a time.
//!
//! Dagger's API is a chain of calls, each selecting the next: `container { from(address:) {
//! withExec(args:) { stdout } } }`. Written as format strings those chains are long, their braces
//! are counted by hand to be closed later, and every value spliced in has to be escaped by the
//! writer remembering to. Here each call is one line, every argument is JSON-encoded (a GraphQL
//! string, number, boolean or list is written the same way), and `finish` closes what was opened.
//!
//! ```zig
//! var q: Query = .init(arena);
//! try q.open("container");
//! try q.call("from", .{ .address = image });
//! try q.callAs("bin", "file", .{ .path = binary });
//! try q.leaf("id");
//! const doc = try q.finish();
//! // { container { from(address:"…") { bin: file(path:"…") { id } } } }
//! ```
//!
//! Arguments are the fields of an anonymous struct: strings become GraphQL strings, booleans and
//! integers literals, slices of strings lists, a `null` optional is left out, and a `Raw` is
//! written as given (an enum value such as `expect:ANY`).

const std = @import("std");
const Allocator = std.mem.Allocator;

/// Argument text written as it is, for the values that are not JSON: GraphQL enum literals.
pub const Raw = struct { text: []const u8 };

pub const Query = struct {
    out: std.Io.Writer.Allocating,
    /// Braces opened and not yet closed; `finish` closes them all.
    depth: usize = 0,
    /// Whether the document's own `{ ` has been written (on the first call).
    began: bool = false,

    pub fn init(arena: Allocator) Query {
        return .{ .out = .init(arena) };
    }

    /// `name { `: a field whose selection follows.
    pub fn open(q: *Query, name: []const u8) !void {
        try (try q.ink()).print("{s} {{ ", .{name});
        q.depth += 1;
    }

    /// `name(args) { `: a call whose selection follows.
    pub fn call(q: *Query, name: []const u8, args: anytype) !void {
        try q.callAs(null, name, args);
    }

    /// `alias: name(args) { `: a call selected under another name, so two calls of the same field
    /// can sit side by side in one query.
    pub fn callAs(q: *Query, alias: ?[]const u8, name: []const u8, args: anytype) !void {
        const w = try q.ink();
        if (alias) |a| try w.print("{s}: ", .{a});
        try w.writeAll(name);
        try writeArgs(w, args);
        try w.writeAll(" { ");
        q.depth += 1;
    }

    /// `name `: a scalar in the current selection.
    pub fn leaf(q: *Query, name: []const u8) !void {
        try (try q.ink()).print("{s} ", .{name});
    }

    /// Closes the `count` most recently opened selections.
    pub fn close(q: *Query, count: usize) !void {
        std.debug.assert(count <= q.depth);
        const w = try q.ink();
        for (0..count) |_| try w.writeAll("} ");
        q.depth -= count;
    }

    /// Text written the old way — `name(args) { ` repeated — that opened `opened` selections. A
    /// bridge while some query text is still built elsewhere; it goes when the last such writer
    /// does.
    pub fn splice(q: *Query, text: []const u8, opened: usize) !void {
        try (try q.ink()).writeAll(text);
        q.depth += opened;
    }

    /// The document, every open selection closed.
    pub fn finish(q: *Query) ![]const u8 {
        const w = try q.ink();
        while (q.depth > 0) : (q.depth -= 1) try w.writeAll("} ");
        try w.writeAll("}");
        return q.out.written();
    }

    /// The writer, after the document's opening brace.
    fn ink(q: *Query) !*std.Io.Writer {
        if (!q.began) {
            try q.out.writer.writeAll("{ ");
            q.began = true;
        }
        return &q.out.writer;
    }
};

/// `(a:v,b:v)`, or nothing when no argument has a value.
fn writeArgs(w: *std.Io.Writer, args: anytype) !void {
    var written: usize = 0;
    inline for (comptime std.meta.fieldNames(@TypeOf(args))) |name| {
        const v = @field(args, name);
        if (!isNull(v)) {
            try w.writeAll(if (written == 0) "(" else ",");
            try w.print("{s}:", .{name});
            try writeValue(w, v);
            written += 1;
        }
    }
    if (written > 0) try w.writeAll(")");
}

fn isNull(v: anytype) bool {
    return switch (@typeInfo(@TypeOf(v))) {
        .optional => v == null,
        .null => true,
        else => false,
    };
}

fn writeValue(w: *std.Io.Writer, v: anytype) !void {
    const T = @TypeOf(v);
    if (T == Raw) return w.writeAll(v.text);
    switch (@typeInfo(T)) {
        .optional => return writeValue(w, v.?),
        else => return std.json.Stringify.value(v, .{}, w),
    }
}

test "a chain of calls, every argument encoded, closed by finish" {
    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();
    var q: Query = .init(arena_state.allocator());
    try q.open("container");
    try q.call("from", .{ .address = @as([]const u8, "node:24") });
    try q.callAs("bin", "file", .{ .path = "/usr/local/bin/node" });
    try q.leaf("id");
    try std.testing.expectEqualStrings(
        "{ container { from(address:\"node:24\") { " ++
            "bin: file(path:\"/usr/local/bin/node\") { id } } } }",
        try q.finish(),
    );
}

test "argument kinds: strings escaped, lists, numbers, booleans, raw, and null left out" {
    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();
    var q: Query = .init(arena_state.allocator());
    const none: ?[]const u8 = null;
    try q.call("withExec", .{
        .args = &[_][]const u8{ "sh", "-c", "echo \"hi\"\\" },
        .expect = Raw{ .text = "ANY" },
        .permissions = @as(u32, 493),
        .insecureRootCapabilities = true,
        .owner = none,
    });
    try q.leaf("exitCode");
    try std.testing.expectEqualStrings(
        "{ withExec(args:[\"sh\",\"-c\",\"echo \\\"hi\\\"\\\\\"],expect:ANY," ++
            "permissions:493,insecureRootCapabilities:true) { exitCode } }",
        try q.finish(),
    );
}

test "no arguments writes no parentheses; close shuts the inner selections only" {
    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();
    var q: Query = .init(arena_state.allocator());
    try q.open("container");
    try q.callAs("libs", "directory", .{ .path = "/usr/lib" });
    try q.call("filter", .{ .include = &[_][]const u8{"libstdc++.so*"} });
    try q.leaf("id");
    try q.close(2);
    try q.call("sync", .{});
    try std.testing.expectEqual(@as(usize, 2), q.depth);
    try std.testing.expectEqualStrings(
        "{ container { libs: directory(path:\"/usr/lib\") { " ++
            "filter(include:[\"libstdc++.so*\"]) { id } } sync { } } }",
        try q.finish(),
    );
}
