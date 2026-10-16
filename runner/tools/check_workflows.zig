//! Checks workflow YAML before it is committed or pushed: the files this project's own runner and
//! its study workflows are made of. Two mistakes that cost real CI runs are what it looks for.
//!
//!  - A line that leaves a block scalar early, which `src/yaml.zig` already rejects: a heredoc body
//!    written at column 0 inside a `run: |` block ends the block, and GitHub then says only
//!    "This run likely failed because of a workflow file issue".
//!  - A plain (unquoted) scalar containing ": ", which real YAML rejects and this project's parser
//!    accepts: `run: echo "a: ${{ b }}"` is read as a mapping by GitHub and fails the whole run.
//!
//! Usage: check-workflows <file or directory>...   (a directory is walked for *.yml and *.yaml)
const std = @import("std");
const yaml = @import("yaml");

pub fn main(init: std.process.Init) !u8 {
    const arena = init.arena.allocator();
    const io = init.io;
    const args = try init.minimal.args.toSlice(arena);
    if (args.len < 2) {
        std.debug.print("usage: check-workflows <file or directory>...\n", .{});
        return 2;
    }
    var problems: usize = 0;
    var checked: usize = 0;
    for (args[1..]) |path| {
        var dir = std.Io.Dir.cwd().openDir(io, path, .{ .iterate = true }) catch {
            problems += try checkFile(arena, io, path);
            checked += 1;
            continue;
        };
        defer dir.close(io);
        var it = dir.iterate();
        while (try it.next(io)) |entry| {
            if (entry.kind != .file) continue;
            if (!std.mem.endsWith(u8, entry.name, ".yml") and !std.mem.endsWith(u8, entry.name, ".yaml")) continue;
            const full = try std.fs.path.join(arena, &.{ path, entry.name });
            problems += try checkFile(arena, io, full);
            checked += 1;
        }
    }
    if (problems > 0) {
        std.debug.print("check-workflows: {d} problem(s) in {d} file(s)\n", .{ problems, checked });
        return 1;
    }
    std.debug.print("check-workflows: {d} file(s) are fine\n", .{checked});
    return 0;
}

fn checkFile(arena: std.mem.Allocator, io: std.Io, path: []const u8) !usize {
    const text = std.Io.Dir.cwd().readFileAlloc(io, path, arena, .limited(4 << 20)) catch |e| {
        std.debug.print("{s}: cannot read it ({s})\n", .{ path, @errorName(e) });
        return 1;
    };
    var found: usize = 0;
    var diag: yaml.Diag = .{};
    if (yaml.parse(arena, text, &diag)) |_| {} else |e| {
        std.debug.print("{s}:{d}: {s} ({s})\n", .{ path, diag.line, if (diag.message.len > 0) diag.message else "could not be parsed", @errorName(e) });
        found += 1;
    }
    found += plainScalarColons(path, text);
    return found;
}

/// A plain scalar cannot contain ": ": YAML reads it as a nested mapping. Quoted and block scalars
/// may contain anything, so only unquoted values are looked at.
fn plainScalarColons(path: []const u8, text: []const u8) usize {
    var found: usize = 0;
    var lines = std.mem.splitScalar(u8, text, '\n');
    var number: usize = 0;
    var block_indent: ?usize = null;
    while (lines.next()) |raw| {
        number += 1;
        const line = std.mem.trimEnd(u8, raw, "\r");
        const indent = line.len - std.mem.trimStart(u8, line, " ").len;
        const trimmed = std.mem.trim(u8, line, " ");
        // Inside a block scalar everything is text, until a line is indented less than its body.
        if (block_indent) |bi| {
            if (trimmed.len == 0 or indent > bi) continue;
            block_indent = null;
        }
        if (trimmed.len == 0 or trimmed[0] == '#') continue;
        const after_dash = if (std.mem.startsWith(u8, trimmed, "- ")) trimmed[2..] else trimmed;
        const colon = keyEnd(after_dash) orelse continue;
        const value = std.mem.trim(u8, after_dash[colon + 1 ..], " ");
        if (value.len == 0) continue;
        if (value[0] == '|' or value[0] == '>') {
            block_indent = indent;
            continue;
        }
        if (value[0] == '"' or value[0] == '\'' or value[0] == '{' or value[0] == '[' or value[0] == '#') continue;
        if (std.mem.indexOf(u8, value, ": ") != null) {
            std.debug.print("{s}:{d}: a plain scalar cannot contain \": \" (YAML reads it as a mapping): quote the value or make it a `|` block\n", .{ path, number });
            found += 1;
        }
    }
    return found;
}

/// The end of a `key:` at the start of a line, or null when there is none outside quotes.
fn keyEnd(s: []const u8) ?usize {
    var quote: ?u8 = null;
    for (s, 0..) |c, i| {
        if (quote) |q| {
            if (c == q) quote = null;
            continue;
        }
        switch (c) {
            '\'', '"' => quote = c,
            ':' => if (i + 1 == s.len or s[i + 1] == ' ') return i,
            else => {},
        }
    }
    return null;
}
