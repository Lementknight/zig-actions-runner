//! Checks the two conventions in SPEC.md §10 that a tool can check: a function is at most 70
//! lines, and a line is at most 100 columns. Both limits are TigerBeetle's; both were adopted on
//! 2026-10-18 when the code had grown too dense to read, with 17 functions over the first and 9%
//! of lines over the second.
//!
//! Those existing violations are the refactor queue, not a reason for CI to be red. So the check is
//! a **ratchet**: a baseline file lists every function over 70 lines with its length, and every
//! file's count of long lines outside `test` blocks, and the check fails only when something gets
//! *worse* — a new long function, a listed one growing, or a file gaining long lines. Shrinking is
//! free and is reported so the baseline can be tightened with `--update-baseline`.
//!
//! Function spans come from `std.zig.Ast`, not from counting braces: a brace heuristic once blamed
//! a 5-line helper for the 2,000-line struct declared after it.
//!
//! Usage: conventions --baseline <file> [--update-baseline] <dir or file>...
//!        (directories are walked for *.zig; a `vendor/` directory is skipped — not our code)

const std = @import("std");
const Allocator = std.mem.Allocator;
const Ast = std.zig.Ast;

const max_fn_lines = 70;
const max_line_cols = 100;

const LongFn = struct { file: []const u8, name: []const u8, lines: usize, line: usize };

/// What one run found, and what the baseline allows.
const Findings = struct {
    fns: std.ArrayList(LongFn) = .empty,
    /// file -> number of lines over the column limit
    long_lines: std.StringArrayHashMapUnmanaged(usize) = .empty,
    files: usize = 0,
};

pub fn main(init: std.process.Init) !u8 {
    const arena = init.arena.allocator();
    const io = init.io;
    const args = try init.minimal.args.toSlice(arena);

    var baseline_path: ?[]const u8 = null;
    var update = false;
    var paths: std.ArrayList([]const u8) = .empty;
    var i: usize = 1;
    while (i < args.len) : (i += 1) {
        if (std.mem.eql(u8, args[i], "--baseline") and i + 1 < args.len) {
            i += 1;
            baseline_path = args[i];
        } else if (std.mem.eql(u8, args[i], "--update-baseline")) {
            update = true;
        } else {
            try paths.append(arena, args[i]);
        }
    }
    const bl_path = baseline_path orelse {
        std.debug.print("usage: conventions --baseline FILE [--update-baseline] PATH...\n", .{});
        return 2;
    };

    var found: Findings = .{};
    for (paths.items) |p| try walk(arena, io, p, &found);

    if (update) {
        try writeBaseline(arena, io, bl_path, found);
        std.debug.print("conventions: baseline written to {s}\n", .{bl_path});
        return 0;
    }
    const baseline = try readBaseline(arena, io, bl_path);
    const worse = report(found, baseline);
    if (worse > 0) {
        std.debug.print(
            "conventions: {d} regression(s) against {s} (SPEC.md §10)\n",
            .{ worse, bl_path },
        );
        return 1;
    }
    std.debug.print("conventions: {d} file(s), nothing worse than the baseline\n", .{found.files});
    return 0;
}

/// Walks a directory for .zig files, or checks one file. `vendor/` is not ours and is skipped.
fn walk(arena: Allocator, io: std.Io, path: []const u8, found: *Findings) !void {
    var dir = std.Io.Dir.cwd().openDir(io, path, .{ .iterate = true }) catch {
        if (std.mem.endsWith(u8, path, ".zig")) try checkFile(arena, io, path, found);
        return;
    };
    defer dir.close(io);
    var it = dir.iterate();
    while (try it.next(io)) |entry| {
        const full = try std.fs.path.join(arena, &.{ path, entry.name });
        switch (entry.kind) {
            .directory => {
                if (std.mem.eql(u8, entry.name, "vendor")) continue;
                try walk(arena, io, full, found);
            },
            .file => if (std.mem.endsWith(u8, entry.name, ".zig")) {
                try checkFile(arena, io, full, found);
            },
            else => {},
        }
    }
}

/// A line's width in columns, which is what the rule is about: code points, not bytes. An em dash
/// is three bytes and one column, and a 99-column comment with one in it was the first "regression"
/// this tool reported. Invalid UTF-8 falls back to the byte count. Tabs count one; `zig fmt` emits
/// none.
fn columns(line: []const u8) usize {
    return std.unicode.utf8CountCodepoints(line) catch line.len;
}

fn checkFile(arena: Allocator, io: std.Io, path: []const u8, found: *Findings) !void {
    const bytes = std.Io.Dir.cwd().readFileAlloc(io, path, arena, .limited(16 << 20)) catch |e| {
        std.debug.print("{s}: cannot read it ({s})\n", .{ path, @errorName(e) });
        return;
    };
    found.files += 1;

    const source = try arena.allocSentinel(u8, bytes.len, 0);
    @memcpy(source, bytes);
    var tree = try Ast.parse(arena, source, .{});
    if (tree.errors.len > 0) {
        // zig fmt and ast-check report syntax; this tool does not need to repeat them.
        std.debug.print("{s}: did not parse; skipping it\n", .{path});
        return;
    }
    const long = countLongLines(bytes, try testLines(arena, &tree));
    if (long > 0) try found.long_lines.put(arena, path, long);
    for (tree.rootDecls()) |decl| try visit(arena, &tree, path, decl, found);
}

/// Lines over the limit, except inside `test` blocks (`in_test`, indexed by line): a long expected
/// string is clearest whole (SPEC.md §10).
fn countLongLines(bytes: []const u8, in_test: []const bool) usize {
    var long: usize = 0;
    var lines = std.mem.splitScalar(u8, bytes, '\n');
    var i: usize = 0;
    while (lines.next()) |l| : (i += 1) {
        if (columns(l) > max_line_cols and !in_test[i]) long += 1;
    }
    return long;
}

/// Which lines of the file are inside a top-level `test` block.
fn testLines(arena: Allocator, tree: *Ast) ![]const bool {
    const total = tree.tokenLocation(0, @intCast(tree.tokens.len - 1)).line + 2;
    const in_test = try arena.alloc(bool, total);
    @memset(in_test, false);
    for (tree.rootDecls()) |decl| {
        if (tree.nodeTag(decl) != .test_decl) continue;
        const first = tree.tokenLocation(0, tree.firstToken(decl)).line;
        const last = tree.tokenLocation(0, tree.lastToken(decl)).line;
        for (first..last + 1) |i| in_test[i] = true;
    }
    return in_test;
}

/// Measures a function declaration, and descends into any container a declaration defines, so
/// methods of nested structs are measured too. Test blocks are not functions (SPEC.md §10).
fn visit(
    arena: Allocator,
    tree: *Ast,
    path: []const u8,
    node: Ast.Node.Index,
    found: *Findings,
) !void {
    switch (tree.nodeTag(node)) {
        .fn_decl => {
            const proto, const body = tree.nodeData(node).node_and_node;
            var buf: [1]Ast.Node.Index = undefined;
            const fp = tree.fullFnProto(&buf, proto) orelse return;
            const first = tree.tokenLocation(0, tree.firstToken(node)).line;
            const last = tree.tokenLocation(0, tree.lastToken(body)).line;
            const lines = last - first + 1;
            if (lines > max_fn_lines) try found.fns.append(arena, .{
                .file = path,
                .name = if (fp.name_token) |t| tree.tokenSlice(t) else "(anonymous)",
                .lines = lines,
                .line = first + 1,
            });
        },
        .simple_var_decl, .global_var_decl, .local_var_decl, .aligned_var_decl => {
            const vd = tree.fullVarDecl(node) orelse return;
            const init_node = vd.ast.init_node.unwrap() orelse return;
            var buf: [2]Ast.Node.Index = undefined;
            const cd = tree.fullContainerDecl(&buf, init_node) orelse return;
            for (cd.ast.members) |m| try visit(arena, tree, path, m, found);
        },
        else => {},
    }
}

/// The baseline file: `fn <file> <name> <lines>` and `long-lines <file> <count>` lines, and `#`
/// comments.
const Baseline = struct {
    fns: std.StringArrayHashMapUnmanaged(usize) = .empty, // "file name" -> allowed lines
    long_lines: std.StringArrayHashMapUnmanaged(usize) = .empty, // file -> allowed count
};

fn readBaseline(arena: Allocator, io: std.Io, path: []const u8) !Baseline {
    var b: Baseline = .{};
    const text = std.Io.Dir.cwd().readFileAlloc(io, path, arena, .limited(1 << 20)) catch return b;
    var lines = std.mem.splitScalar(u8, text, '\n');
    while (lines.next()) |raw| {
        const l = std.mem.trim(u8, raw, " \t\r");
        if (l.len == 0 or l[0] == '#') continue;
        var it = std.mem.splitScalar(u8, l, ' ');
        const kind = it.next() orelse continue;
        if (std.mem.eql(u8, kind, "fn")) {
            const file = it.next() orelse continue;
            const name = it.next() orelse continue;
            const n = std.fmt.parseInt(usize, it.next() orelse continue, 10) catch continue;
            try b.fns.put(arena, try fnKey(arena, file, name), n);
        } else if (std.mem.eql(u8, kind, "long-lines")) {
            const file = it.next() orelse continue;
            const n = std.fmt.parseInt(usize, it.next() orelse continue, 10) catch continue;
            try b.long_lines.put(arena, file, n);
        }
    }
    return b;
}

fn fnKey(arena: Allocator, file: []const u8, name: []const u8) ![]const u8 {
    return std.mem.concat(arena, u8, &.{ file, " ", name });
}

fn writeBaseline(arena: Allocator, io: std.Io, path: []const u8, found: Findings) !void {
    var out: std.Io.Writer.Allocating = .init(arena);
    const w = &out.writer;
    try w.writeAll("# Generated by `zig build conventions -- --update-baseline` (SPEC.md §10).\n");
    try w.writeAll("# Every function over 70 lines, with its length, and every file's count of\n");
    try w.writeAll("# lines over 100 columns. The check fails when anything here gets worse.\n");
    const fns = try arena.dupe(LongFn, found.fns.items);
    std.mem.sort(LongFn, fns, {}, longestFirst);
    for (fns) |f| try w.print("fn {s} {s} {d}\n", .{ f.file, f.name, f.lines });
    for (found.long_lines.keys(), found.long_lines.values()) |file, n| {
        try w.print("long-lines {s} {d}\n", .{ file, n });
    }
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = path, .data = out.written() });
}

fn longestFirst(_: void, a: LongFn, b: LongFn) bool {
    if (a.lines != b.lines) return a.lines > b.lines;
    return std.mem.lessThan(u8, a.file, b.file);
}

/// Prints what is worse than the baseline, and what could tighten it. Returns how many were worse.
fn report(found: Findings, b: Baseline) usize {
    var worse: usize = 0;
    for (found.fns.items) |f| {
        var key_buf: [512]u8 = undefined;
        const key = std.fmt.bufPrint(&key_buf, "{s} {s}", .{ f.file, f.name }) catch continue;
        const allowed = b.fns.get(key);
        if (allowed == null) {
            std.debug.print(
                "{s}:{d}: {s} is {d} lines; the limit is {d} and it is not in the baseline\n",
                .{ f.file, f.line, f.name, f.lines, max_fn_lines },
            );
            worse += 1;
        } else if (f.lines > allowed.?) {
            std.debug.print(
                "{s}:{d}: {s} grew from {d} to {d} lines\n",
                .{ f.file, f.line, f.name, allowed.?, f.lines },
            );
            worse += 1;
        } else if (f.lines < allowed.?) {
            std.debug.print(
                "{s}:{d}: {s} shrank from {d} to {d} lines — update the baseline\n",
                .{ f.file, f.line, f.name, allowed.?, f.lines },
            );
        }
    }
    for (found.long_lines.keys(), found.long_lines.values()) |file, n| {
        const allowed = b.long_lines.get(file) orelse 0;
        if (n > allowed) {
            std.debug.print(
                "{s}: {d} lines over {d} columns, baseline allows {d}\n",
                .{ file, n, max_line_cols, allowed },
            );
            worse += 1;
        } else if (n < allowed) {
            std.debug.print(
                "{s}: long lines fell from {d} to {d} — update the baseline\n",
                .{ file, allowed, n },
            );
        }
    }
    return worse;
}
