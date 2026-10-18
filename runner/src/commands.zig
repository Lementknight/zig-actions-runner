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

// --- workflow commands printed by a step: `::name key=value,...::data` ---

pub const Workflow = union(enum) {
    /// Not a command, an unknown one, or commands are stopped: log the line as it is.
    none,
    /// Mask this value in all later output; the line itself is not logged.
    add_mask: []const u8,
    group: []const u8,
    endgroup,
    /// `error`, `warning` or `notice`, logged as `##[<level>]<message>`.
    annotation: Annotation,
    debug: []const u8,
    /// `::stop-commands::<token>`: no commands until `::<token>::`.
    stop: []const u8,
    /// `::<token>::` while commands are stopped.
    resume_commands,
    /// Deprecated `set-output` and `save-state`, still honoured.
    set_output: job_mod.EnvVar,
    save_state: job_mod.EnvVar,
    /// `set-env` and `add-path`, which GitHub disabled.
    disabled: []const u8,
    /// `::echo::on|off` only changes whether commands are echoed; this runner never echoes them.
    echo,
    /// `::add-matcher::<path>`: register the problem matchers in that file (see matcher.zig). The
    /// path is relative to the workspace, or to an action's own directory inside one.
    add_matcher: []const u8,
    /// `::remove-matcher owner=<name>::`: withdraw the matchers an owner registered.
    remove_matcher: []const u8,
};

/// `::error file=a.js,line=3,endLine=4,col=1,endColumn=9,title=T::message`. The properties are as
/// written (null when absent); GitHub's runner reads the same names.
pub const Annotation = struct {
    level: []const u8,
    message: []const u8,
    title: ?[]const u8 = null,
    file: ?[]const u8 = null,
    line: ?[]const u8 = null,
    end_line: ?[]const u8 = null,
    col: ?[]const u8 = null,
    end_column: ?[]const u8 = null,
};

/// Parses one line of a step's output. `stopped_token` is the token of an active `stop-commands`.
/// Leading and trailing whitespace is ignored, as in GitHub's runner; command names are
/// case-insensitive.
pub fn parseWorkflow(arena: Allocator, line: []const u8, stopped_token: ?[]const u8) Allocator.Error!Workflow {
    const t = std.mem.trim(u8, line, " \t\r");
    if (!std.mem.startsWith(u8, t, "::")) return .none;
    const rest = t[2..];
    const end = std.mem.indexOf(u8, rest, "::") orelse return .none;
    const section = rest[0..end];
    const data = rest[end + 2 ..];

    if (stopped_token) |token| {
        return if (std.mem.eql(u8, section, token)) .resume_commands else .none;
    }

    const space = std.mem.indexOfScalar(u8, section, ' ');
    const name = section[0 .. space orelse section.len];
    const props = if (space) |s| section[s + 1 ..] else "";
    const eql = std.ascii.eqlIgnoreCase;

    if (eql(name, "add-mask")) return .{ .add_mask = try unescape(arena, data, false) };
    if (eql(name, "add-matcher")) {
        const path = try unescape(arena, data, false);
        return if (path.len > 0) .{ .add_matcher = path } else .none;
    }
    if (eql(name, "remove-matcher")) {
        // The owner is a property, not the data: `::remove-matcher owner=eslint-stylish::`.
        const owner = try property(arena, props, "owner");
        return if (owner) |o| (if (o.len > 0) .{ .remove_matcher = o } else .none) else .none;
    }
    if (eql(name, "group")) return .{ .group = try unescape(arena, data, false) };
    if (eql(name, "endgroup")) return .endgroup;
    if (eql(name, "debug")) return .{ .debug = try unescape(arena, data, false) };
    if (eql(name, "echo")) return .echo;
    if (eql(name, "stop-commands")) return if (data.len > 0) .{ .stop = data } else .none;
    if (eql(name, "set-env") or eql(name, "add-path")) return .{ .disabled = name };
    for ([_][]const u8{ "error", "warning", "notice" }) |level| if (eql(name, level))
        return .{ .annotation = .{
            .level = level,
            .message = try unescape(arena, data, false),
            .title = try property(arena, props, "title"),
            .file = try property(arena, props, "file"),
            .line = try property(arena, props, "line"),
            .end_line = try property(arena, props, "endLine"),
            .col = try property(arena, props, "col"),
            .end_column = try property(arena, props, "endColumn"),
        } };
    if (eql(name, "set-output") or eql(name, "save-state")) {
        const key = (try property(arena, props, "name")) orelse return .none;
        const kv: job_mod.EnvVar = .{ .name = key, .value = try unescape(arena, data, false) };
        return if (eql(name, "set-output")) .{ .set_output = kv } else .{ .save_state = kv };
    }
    return .none;
}

/// The value of property `key` in `k=v,k2=v2`.
fn property(arena: Allocator, props: []const u8, key: []const u8) Allocator.Error!?[]const u8 {
    var it = std.mem.splitScalar(u8, props, ',');
    while (it.next()) |p| {
        const eq = std.mem.indexOfScalar(u8, p, '=') orelse continue;
        if (std.mem.eql(u8, std.mem.trim(u8, p[0..eq], " "), key)) return try unescape(arena, p[eq + 1 ..], true);
    }
    return null;
}

/// GitHub's escapes: `%25` `%0D` `%0A` in data, plus `%3A` `%2C` in property values.
fn unescape(arena: Allocator, s: []const u8, is_property: bool) Allocator.Error![]const u8 {
    if (std.mem.indexOfScalar(u8, s, '%') == null) return s;
    var out: std.ArrayList(u8) = .empty;
    var i: usize = 0;
    while (i < s.len) {
        if (s[i] == '%' and i + 3 <= s.len) {
            const code = s[i + 1 .. i + 3];
            const c: ?u8 = if (std.ascii.eqlIgnoreCase(code, "25")) '%' else if (std.ascii.eqlIgnoreCase(code, "0D")) '\r' else if (std.ascii.eqlIgnoreCase(code, "0A")) '\n' else if (is_property and std.ascii.eqlIgnoreCase(code, "3A")) ':' else if (is_property and std.ascii.eqlIgnoreCase(code, "2C")) ',' else null;
            if (c) |ch| {
                try out.append(arena, ch);
                i += 3;
                continue;
            }
        }
        try out.append(arena, s[i]);
        i += 1;
    }
    return out.items;
}

test "workflow commands" {
    var a: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer a.deinit();
    const ar = a.allocator();
    try std.testing.expect(try parseWorkflow(ar, "plain output", null) == .none);
    try std.testing.expect(try parseWorkflow(ar, "a ::group::not at the start", null) == .none);
    try std.testing.expect(try parseWorkflow(ar, "::unknown::x", null) == .none);
    try std.testing.expectEqualStrings("s3cret", (try parseWorkflow(ar, "::add-mask::s3cret", null)).add_mask);
    try std.testing.expectEqualStrings("Build", (try parseWorkflow(ar, "  ::group::Build  ", null)).group);
    try std.testing.expect(try parseWorkflow(ar, "::endgroup::", null) == .endgroup);
    try std.testing.expect(try parseWorkflow(ar, "::ENDGROUP::", null) == .endgroup);
    const err = (try parseWorkflow(ar, "::error file=a.js,line=3,title=Oops::two%0Alines 100%25", null)).annotation;
    try std.testing.expectEqualStrings("error", err.level);
    try std.testing.expectEqualStrings("two\nlines 100%", err.message);
    try std.testing.expectEqualStrings("a.js", err.file.?);
    try std.testing.expectEqualStrings("3", err.line.?);
    try std.testing.expectEqualStrings("Oops", err.title.?);
    try std.testing.expect(err.end_line == null and err.col == null);
    try std.testing.expectEqualStrings("warning", (try parseWorkflow(ar, "::warning::w", null)).annotation.level);
    try std.testing.expectEqualStrings("d", (try parseWorkflow(ar, "::debug::d", null)).debug);
    const out = (try parseWorkflow(ar, "::set-output name=a%3Ab::v%0A2", null)).set_output;
    try std.testing.expectEqualStrings("a:b", out.name);
    try std.testing.expectEqualStrings("v\n2", out.value);
    try std.testing.expectEqualStrings("isPost", (try parseWorkflow(ar, "::save-state name=isPost::true", null)).save_state.name);
    try std.testing.expect(try parseWorkflow(ar, "::set-output::no name", null) == .none);
    try std.testing.expectEqualStrings("set-env", (try parseWorkflow(ar, "::set-env name=X::1", null)).disabled);
    try std.testing.expect(try parseWorkflow(ar, "::echo::on", null) == .echo);
    // stop-commands: everything is plain text until the token comes back
    try std.testing.expectEqualStrings("tok123", (try parseWorkflow(ar, "::stop-commands::tok123", null)).stop);
    try std.testing.expect(try parseWorkflow(ar, "::stop-commands::", null) == .none);
    try std.testing.expect(try parseWorkflow(ar, "::add-mask::x", "tok123") == .none);
    try std.testing.expect(try parseWorkflow(ar, "::tok123::", "tok123") == .resume_commands);
}

test "add-matcher and remove-matcher" {
    var a: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer a.deinit();
    const ar = a.allocator();

    // As actions/setup-node writes it, path relative to the action's own directory.
    const add = try parseWorkflow(ar, "::add-matcher::/home/runner/work/_actions/actions/setup-node/v4/.github/tsc.json", null);
    try std.testing.expectEqualStrings("/home/runner/work/_actions/actions/setup-node/v4/.github/tsc.json", add.add_matcher);

    // The owner is a property of the command, not its data.
    const remove = try parseWorkflow(ar, "::remove-matcher owner=eslint-stylish::", null);
    try std.testing.expectEqualStrings("eslint-stylish", remove.remove_matcher);

    // Neither without what it needs.
    try std.testing.expect(try parseWorkflow(ar, "::add-matcher::", null) == .none);
    try std.testing.expect(try parseWorkflow(ar, "::remove-matcher::", null) == .none);
    try std.testing.expect(try parseWorkflow(ar, "::remove-matcher owner=::", null) == .none);

    // And not while commands are stopped.
    try std.testing.expect(try parseWorkflow(ar, "::add-matcher::x.json", "tok") == .none);
}
