//! A YAML subset, enough to read `action.yml` files.
//!
//! Supported: block mappings and sequences, plain / 'single' / "double" quoted scalars, block
//! scalars (`|` and `>` with `-`, `+` and an indentation digit), plain scalars that continue on
//! later lines, single-line flow sequences and mappings, comments, and a leading `---`.
//!
//! Every scalar is a string, except an empty value, `~` and `null`, which are null: callers turn
//! strings into booleans or numbers where they need to (action inputs are strings anyway).
//!
//! Not supported, and reported as `UnsupportedYaml` instead of being misread: anchors, aliases,
//! tags, merge keys, multiple documents, complex keys, and quoted or flow collections that span
//! lines. Tab indentation is `InvalidYaml`.
const std = @import("std");

const Allocator = std.mem.Allocator;

pub const Error = error{ InvalidYaml, UnsupportedYaml, OutOfMemory };

pub const Node = union(enum) {
    null,
    string: []const u8,
    seq: []const Node,
    map: []const Entry,

    pub const Entry = struct { key: []const u8, value: Node };

    /// The value of `key` in a mapping (case-sensitive), or null.
    pub fn get(n: Node, key: []const u8) ?Node {
        if (n != .map) return null;
        for (n.map) |e| if (std.mem.eql(u8, e.key, key)) return e.value;
        return null;
    }

    /// The scalar text of a string node, or null for anything else.
    pub fn text(n: Node) ?[]const u8 {
        return if (n == .string) n.string else null;
    }
};

/// Where and why parsing failed.
pub const Diag = struct { line: usize = 0, message: []const u8 = "" };

pub fn parse(arena: Allocator, source: []const u8, diag: ?*Diag) Error!Node {
    var lines: std.ArrayList(Line) = .empty;
    var it = std.mem.splitScalar(u8, source, '\n');
    var number: usize = 0;
    while (it.next()) |raw| {
        number += 1;
        const full = std.mem.trimEnd(u8, raw, "\r");
        var indent: usize = 0;
        while (indent < full.len and full[indent] == ' ') indent += 1;
        const rest = full[indent..];
        if (rest.len > 0 and rest[0] == '\t') {
            if (diag) |d|
                d.* = .{ .line = number, .message = "tabs are not allowed for indentation" };
            return error.InvalidYaml;
        }
        const trimmed = std.mem.trimEnd(u8, rest, " \t");
        try lines.append(arena, .{
            .number = number,
            .indent = indent,
            .full = full,
            .text = trimmed,
            .skip = trimmed.len == 0 or trimmed[0] == '#',
        });
    }
    var p: Parser = .{ .arena = arena, .lines = lines.items, .diag = diag };
    p.skipBlank();
    // An explicit document start is allowed; a second document is not.
    if (p.pos < p.lines.len and std.mem.eql(u8, p.lines[p.pos].text, "---")) {
        p.pos += 1;
        p.skipBlank();
    }
    const root = try p.node(0);
    p.skipBlank();
    if (p.pos < p.lines.len) {
        const l = p.lines[p.pos];
        if (std.mem.eql(u8, l.text, "---") or std.mem.eql(u8, l.text, "..."))
            return p.unsupported(l, "multiple documents");
        return p.invalid(l, "unexpected content");
    }
    return root;
}

const Line = struct {
    number: usize,
    indent: usize,
    /// The whole line, for block scalars.
    full: []const u8,
    /// Without the indentation or trailing whitespace.
    text: []const u8,
    /// Blank or comment-only.
    skip: bool,
};

const Parser = struct {
    arena: Allocator,
    lines: []Line,
    pos: usize = 0,
    diag: ?*Diag,

    fn invalid(p: *Parser, l: Line, msg: []const u8) Error {
        if (p.diag) |d| d.* = .{ .line = l.number, .message = msg };
        return error.InvalidYaml;
    }

    fn unsupported(p: *Parser, l: Line, msg: []const u8) Error {
        if (p.diag) |d| d.* = .{ .line = l.number, .message = msg };
        return error.UnsupportedYaml;
    }

    fn skipBlank(p: *Parser) void {
        while (p.pos < p.lines.len and p.lines[p.pos].skip) p.pos += 1;
    }

    /// The next significant line's index, without consuming anything.
    fn peek(p: *Parser) ?usize {
        var i = p.pos;
        while (i < p.lines.len and p.lines[i].skip) i += 1;
        return if (i < p.lines.len) i else null;
    }

    /// A node whose lines are indented at least `min_indent`; null when there is none.
    fn node(p: *Parser, min_indent: usize) Error!Node {
        const i = p.peek() orelse return .null;
        const l = p.lines[i];
        if (l.indent < min_indent) return .null;
        p.pos = i;
        if (isSeqItem(l.text)) return p.seq(l.indent);
        if (try p.keyEnd(l)) |_| return p.map(l.indent);
        // A lone scalar (or flow collection) on its own line.
        p.pos += 1;
        return p.inlineValue(l, l.text, @as(isize, @intCast(l.indent)) - 1);
    }

    fn seq(p: *Parser, indent: usize) Error!Node {
        var items: std.ArrayList(Node) = .empty;
        while (p.peek()) |i| {
            const l = p.lines[i];
            if (l.indent != indent or !isSeqItem(l.text)) break;
            p.pos = i;
            const after = std.mem.trimStart(u8, l.text[1..], " ");
            if (after.len == 0 or after[0] == '#') {
                p.pos += 1;
                try items.append(p.arena, try p.node(indent + 1));
                continue;
            }
            // `- key: v` followed by `  key2: v2`: treat the rest of the line as a line of its own.
            const offset = l.text.len - after.len;
            p.lines[i].indent = indent + offset;
            p.lines[i].text = after;
            try items.append(p.arena, try p.itemValue(i, indent));
        }
        return .{ .seq = items.items };
    }

    /// The value that starts on line `i` after a `- `, whose dash was at `dash_indent`.
    fn itemValue(p: *Parser, i: usize, dash_indent: usize) Error!Node {
        const l = p.lines[i];
        const head = stripComment(l.text);
        if (isBlockScalarHeader(head)) {
            p.pos += 1;
            return p.blockScalar(head, dash_indent);
        }
        if (isSeqItem(l.text)) return p.seq(l.indent);
        if (try p.keyEnd(l)) |_| return p.map(l.indent);
        p.pos += 1;
        return p.inlineValue(l, l.text, @intCast(dash_indent));
    }

    fn map(p: *Parser, indent: usize) Error!Node {
        var entries: std.ArrayList(Node.Entry) = .empty;
        while (p.peek()) |i| {
            const l = p.lines[i];
            if (l.indent != indent) break;
            const colon = (try p.keyEnd(l)) orelse break;
            const key = try p.mapKey(l, l.text[0..colon]);
            const rest = stripComment(std.mem.trimStart(u8, l.text[colon + 1 ..], " "));
            p.pos = i + 1;

            var value: Node = undefined;
            if (rest.len == 0) {
                const nx = p.peek();
                if (nx != null and p.lines[nx.?].indent > indent) {
                    value = try p.node(indent + 1);
                } else if (nx != null and p.lines[nx.?].indent == indent and
                    isSeqItem(p.lines[nx.?].text))
                {
                    // `key:` followed by a sequence at the same indentation.
                    value = try p.seq(indent);
                } else {
                    value = .null;
                }
            } else if (isBlockScalarHeader(rest)) {
                value = try p.blockScalar(rest, indent);
            } else {
                value = try p.inlineValue(l, rest, @intCast(indent));
            }
            // The last duplicate wins, as in most parsers.
            var replaced = false;
            for (entries.items) |*e| if (std.mem.eql(u8, e.key, key)) {
                e.value = value;
                replaced = true;
            };
            if (!replaced) try entries.append(p.arena, .{ .key = key, .value = value });
        }
        return .{ .map = entries.items };
    }

    /// Index of the `:` that ends a mapping key on this line, or null if the line is not a mapping
    /// entry.
    fn keyEnd(p: *Parser, l: Line) Error!?usize {
        const t = l.text;
        if (t.len == 0) return null;
        if (t[0] == '"' or t[0] == '\'') {
            const close = quotedEnd(t) orelse return null;
            var j = close;
            while (j < t.len and t[j] == ' ') j += 1;
            if (j < t.len and t[j] == ':' and (j + 1 == t.len or t[j + 1] == ' ')) return j;
            return null;
        }
        if (t[0] == '[' or t[0] == '{') return null;
        if (t[0] == '?' and (t.len == 1 or t[1] == ' '))
            return p.unsupported(l, "complex mapping keys");
        var j: usize = 0;
        while (j < t.len) : (j += 1) {
            if (t[j] == ':' and (j + 1 == t.len or t[j + 1] == ' ')) return j;
            if (t[j] == '#' and j > 0 and t[j - 1] == ' ') return null;
        }
        return null;
    }

    fn mapKey(p: *Parser, l: Line, raw: []const u8) Error![]const u8 {
        const t = std.mem.trim(u8, raw, " ");
        if (t.len == 0) return p.invalid(l, "empty mapping key");
        if (t[0] == '"' or t[0] == '\'') return (try p.quoted(l, t)).value;
        if (t[0] == '&' or t[0] == '*' or t[0] == '!')
            return p.unsupported(l, "anchors, aliases and tags");
        if (std.mem.eql(u8, t, "<<")) return p.unsupported(l, "merge keys");
        return t;
    }

    /// A scalar or flow collection given inline. Plain scalars continue on following lines that are
    /// indented more than `parent_indent`.
    fn inlineValue(p: *Parser, l: Line, rest_in: []const u8, parent_indent: isize) Error!Node {
        var rest = stripComment(rest_in);
        if (rest.len == 0) return .null;
        if ((rest[0] == '"' or rest[0] == '\'') and quotedEnd(rest) == null)
            rest = try p.foldQuoted(l, rest, parent_indent);
        switch (rest[0]) {
            '"', '\'' => {
                const q = try p.quoted(l, rest);
                const tail = std.mem.trim(u8, rest[q.end..], " ");
                if (tail.len > 0 and tail[0] != '#')
                    return p.invalid(l, "unexpected text after a quoted string");
                return .{ .string = q.value };
            },
            '[', '{' => {
                var fp: Flow = .{ .p = p, .l = l, .s = rest };
                const v = try fp.value();
                fp.skipSpaces();
                if (fp.i < rest.len and rest[fp.i] != '#')
                    return p.invalid(l, "unexpected text after a flow collection");
                return v;
            },
            '&', '*', '!' => return p.unsupported(l, "anchors, aliases and tags"),
            else => {},
        }
        var buf: std.ArrayList(u8) = .empty;
        try buf.appendSlice(p.arena, rest);
        while (p.pos < p.lines.len) {
            const nl = p.lines[p.pos];
            if (nl.skip) break;
            if (@as(isize, @intCast(nl.indent)) <= parent_indent) break;
            // A deeper `key: value` line would be a mapping where a scalar was expected.
            if (try p.keyEnd(nl)) |_| return p.invalid(nl, "mapping values are not allowed here");
            if (isSeqItem(nl.text)) return p.invalid(nl, "sequence items are not allowed here");
            try buf.append(p.arena, ' ');
            try buf.appendSlice(p.arena, stripComment(nl.text));
            p.pos += 1;
        }
        const s = buf.items;
        if (std.mem.eql(u8, s, "~") or std.mem.eql(u8, s, "null")) return .null;
        return .{ .string = s };
    }

    /// A quoted scalar that continues on the following lines, folded onto one: each line break is a
    /// space, and each blank line a newline. Continuation lines must be indented past
    /// `parent_indent`.
    fn foldQuoted(p: *Parser, l: Line, first: []const u8, parent_indent: isize) Error![]const u8 {
        var buf: std.ArrayList(u8) = .empty;
        try buf.appendSlice(p.arena, first);
        var after_blank = false;
        while (p.pos < p.lines.len) {
            const nl = p.lines[p.pos];
            p.pos += 1;
            if (isBlankLine(nl)) {
                try buf.append(p.arena, '\n');
                after_blank = true;
                continue;
            }
            if (@as(isize, @intCast(nl.indent)) <= parent_indent) break;
            if (!after_blank) try buf.append(p.arena, ' ');
            after_blank = false;
            try buf.appendSlice(p.arena, nl.text);
            if (quotedEnd(buf.items) != null) return buf.items;
        }
        return p.unsupported(l, "a quoted string that is never closed");
    }

    const Quoted = struct { value: []const u8, end: usize };

    /// A quoted scalar at the start of `t`; `end` is the index just past the closing quote.
    fn quoted(p: *Parser, l: Line, t: []const u8) Error!Quoted {
        const close = quotedEnd(t) orelse
            return p.unsupported(l, "a quoted string that spans lines");
        const body = t[1 .. close - 1];
        var out: std.ArrayList(u8) = .empty;
        if (t[0] == '\'') {
            var i: usize = 0;
            while (i < body.len) : (i += 1) {
                try out.append(p.arena, body[i]);
                if (body[i] == '\'') i += 1; // '' is an escaped quote
            }
            return .{ .value = out.items, .end = close };
        }
        var i: usize = 0;
        while (i < body.len) : (i += 1) {
            const c = body[i];
            if (c != '\\') {
                try out.append(p.arena, c);
                continue;
            }
            i += 1;
            if (i >= body.len) return p.invalid(l, "bad escape in a double-quoted string");
            switch (body[i]) {
                'n' => try out.append(p.arena, '\n'),
                't' => try out.append(p.arena, '\t'),
                'r' => try out.append(p.arena, '\r'),
                '0' => try out.append(p.arena, 0),
                '"' => try out.append(p.arena, '"'),
                '\\' => try out.append(p.arena, '\\'),
                '/' => try out.append(p.arena, '/'),
                ' ' => try out.append(p.arena, ' '),
                'x', 'u' => |kind| {
                    const digits: usize = if (kind == 'x') 2 else 4;
                    if (i + 1 + digits > body.len)
                        return p.invalid(l, "bad escape in a double-quoted string");
                    const cp = std.fmt.parseInt(u21, body[i + 1 .. i + 1 + digits], 16) catch
                        return p.invalid(l, "bad escape in a double-quoted string");
                    var enc: [4]u8 = undefined;
                    const n = std.unicode.utf8Encode(cp, &enc) catch
                        return p.invalid(l, "bad escape in a double-quoted string");
                    try out.appendSlice(p.arena, enc[0..n]);
                    i += digits;
                },
                else => return p.invalid(l, "unknown escape in a double-quoted string"),
            }
        }
        return .{ .value = out.items, .end = close };
    }

    /// A `|` or `>` scalar whose header is `header`; the body follows at more than `parent_indent`.
    const Chomp = enum { clip, strip, keep };

    /// What a block scalar's header (`|`, `>-`, `|+2`, ...) says about its body.
    const BlockHeader = struct {
        folded: bool,
        chomp: Chomp = .clip,
        explicit_indent: ?usize = null,
    };

    fn blockHeader(header: []const u8) BlockHeader {
        var h: BlockHeader = .{ .folded = header[0] == '>' };
        for (header[1..]) |c| switch (c) {
            '-' => h.chomp = .strip,
            '+' => h.chomp = .keep,
            '1'...'9' => h.explicit_indent = c - '0',
            else => break,
        };
        return h;
    }

    /// Where a block scalar's body ends, and its indentation.
    const BlockBody = struct {
        start: usize,
        /// Past the last non-blank line: trailing blank lines belong to the scalar only for `keep`.
        last: usize,
        /// Past the trailing blank lines.
        end: usize,
        content_indent: ?usize,
    };

    fn blockBody(p: *Parser, parent_indent: usize, explicit_indent: ?usize) BlockBody {
        const start = p.pos;
        var end = start;
        var content_indent: ?usize = if (explicit_indent) |e| parent_indent + e else null;
        while (end < p.lines.len) : (end += 1) {
            const l = p.lines[end];
            if (isBlankLine(l)) continue;
            if (content_indent == null) {
                if (l.indent <= parent_indent) break;
                content_indent = l.indent;
            }
            if (l.indent < content_indent.?) break;
        }
        var last = end;
        while (last > start and isBlankLine(p.lines[last - 1])) last -= 1;
        return .{ .start = start, .last = last, .end = end, .content_indent = content_indent };
    }

    fn blockScalar(p: *Parser, header: []const u8, parent_indent: usize) Error!Node {
        const h = blockHeader(header);
        const body_span = p.blockBody(parent_indent, h.explicit_indent);
        const start = body_span.start;
        const last = body_span.last;
        const end = body_span.end;
        p.pos = end;
        const ci = body_span.content_indent orelse return .{ .string = "" };

        var out: std.ArrayList(u8) = .empty;
        var prev_blank = false;
        var first = true;
        var prev_more_indented = false;
        for (p.lines[start..last]) |l| {
            const blank = isBlankLine(l);
            const body = if (blank) "" else l.full[@min(ci, l.full.len)..];
            if (first) {
                try out.appendSlice(p.arena, body);
            } else if (!h.folded) {
                try out.append(p.arena, '\n');
                try out.appendSlice(p.arena, body);
            } else if (blank) {
                try out.append(p.arena, '\n');
            } else {
                const more = body.len > 0 and (body[0] == ' ' or body[0] == '\t');
                if (prev_blank) {
                    // The blank lines supplied the breaks; next to a more-indented line the line
                    // break itself is kept as well.
                    if (more or prev_more_indented) try out.append(p.arena, '\n');
                } else if (more or prev_more_indented) {
                    try out.append(p.arena, '\n');
                } else {
                    try out.append(p.arena, ' ');
                }
                try out.appendSlice(p.arena, body);
                prev_more_indented = more;
            }
            prev_blank = blank;
            first = false;
        }
        switch (h.chomp) {
            .strip => {},
            .clip => if (out.items.len > 0) try out.append(p.arena, '\n'),
            .keep => {
                if (out.items.len > 0) try out.append(p.arena, '\n');
                for (p.lines[last..end]) |_| try out.append(p.arena, '\n');
            },
        }
        return .{ .string = out.items };
    }
};

fn isBlankLine(l: Line) bool {
    return std.mem.trim(u8, l.full, " \t").len == 0;
}

/// A single-line flow sequence or mapping: `[a, b]`, `{ icon: x, color: y }`.
const Flow = struct {
    p: *Parser,
    l: Line,
    s: []const u8,
    i: usize = 0,

    fn skipSpaces(f: *Flow) void {
        while (f.i < f.s.len and f.s[f.i] == ' ') f.i += 1;
    }

    fn value(f: *Flow) Error!Node {
        f.skipSpaces();
        if (f.i >= f.s.len) return f.p.unsupported(f.l, "a flow collection that spans lines");
        switch (f.s[f.i]) {
            '[' => {
                f.i += 1;
                var items: std.ArrayList(Node) = .empty;
                while (true) {
                    f.skipSpaces();
                    if (f.i >= f.s.len)
                        return f.p.unsupported(f.l, "a flow collection that spans lines");
                    if (f.s[f.i] == ']') {
                        f.i += 1;
                        break;
                    }
                    try items.append(f.p.arena, try f.value());
                    f.skipSpaces();
                    if (f.i < f.s.len and f.s[f.i] == ',') f.i += 1;
                }
                return .{ .seq = items.items };
            },
            '{' => {
                f.i += 1;
                var entries: std.ArrayList(Node.Entry) = .empty;
                while (true) {
                    f.skipSpaces();
                    if (f.i >= f.s.len)
                        return f.p.unsupported(f.l, "a flow collection that spans lines");
                    if (f.s[f.i] == '}') {
                        f.i += 1;
                        break;
                    }
                    const k = try f.scalarText(true);
                    f.skipSpaces();
                    var v: Node = .null;
                    if (f.i < f.s.len and f.s[f.i] == ':') {
                        f.i += 1;
                        v = try f.value();
                    }
                    try entries.append(f.p.arena, .{ .key = k, .value = v });
                    f.skipSpaces();
                    if (f.i < f.s.len and f.s[f.i] == ',') f.i += 1;
                }
                return .{ .map = entries.items };
            },
            '"', '\'' => {
                const q = try f.p.quoted(f.l, f.s[f.i..]);
                f.i += q.end;
                return .{ .string = q.value };
            },
            else => {
                const t = try f.scalarText(false);
                if (t.len == 0 or std.mem.eql(u8, t, "~") or std.mem.eql(u8, t, "null"))
                    return .null;
                return .{ .string = t };
            },
        }
    }

    /// A plain or quoted scalar inside a flow collection, ended by `,`, `]`, `}` (or `:` for a
    /// key).
    fn scalarText(f: *Flow, is_key: bool) Error![]const u8 {
        f.skipSpaces();
        if (f.i < f.s.len and (f.s[f.i] == '"' or f.s[f.i] == '\'')) {
            const q = try f.p.quoted(f.l, f.s[f.i..]);
            f.i += q.end;
            return q.value;
        }
        const start = f.i;
        while (f.i < f.s.len) : (f.i += 1) {
            const c = f.s[f.i];
            if (c == ',' or c == ']' or c == '}') break;
            if (is_key and c == ':' and (f.i + 1 == f.s.len or f.s[f.i + 1] == ' ')) break;
        }
        return std.mem.trim(u8, f.s[start..f.i], " ");
    }
};

fn isSeqItem(t: []const u8) bool {
    return t.len > 0 and t[0] == '-' and (t.len == 1 or t[1] == ' ');
}

/// `|` or `>` followed only by chomping and indentation indicators (the comment is already
/// removed).
fn isBlockScalarHeader(t: []const u8) bool {
    if (t.len == 0 or (t[0] != '|' and t[0] != '>')) return false;
    for (t[1..]) |c| switch (c) {
        '-', '+', '1'...'9' => {},
        else => return false,
    };
    return true;
}

/// Index just past the closing quote of the quoted scalar at the start of `t`, or null if unclosed.
fn quotedEnd(t: []const u8) ?usize {
    const q = t[0];
    var i: usize = 1;
    while (i < t.len) : (i += 1) {
        if (q == '"' and t[i] == '\\') {
            i += 1;
            continue;
        }
        if (t[i] == q) {
            if (q == '\'' and i + 1 < t.len and t[i + 1] == '\'') {
                i += 1;
                continue;
            }
            return i + 1;
        }
    }
    return null;
}

/// Removes a trailing ` # comment` from a plain value. Quoted and flow values are returned as they
/// are: the caller looks at what follows the closing quote or bracket.
fn stripComment(s: []const u8) []const u8 {
    const t = std.mem.trim(u8, s, " ");
    if (t.len == 0) return t;
    if (t[0] == '#') return "";
    if (t[0] == '"' or t[0] == '\'' or t[0] == '[' or t[0] == '{') return t;
    var i: usize = 1;
    while (i < t.len) : (i += 1) {
        if (t[i] == '#' and t[i - 1] == ' ') return std.mem.trimEnd(u8, t[0..i], " ");
    }
    return t;
}

// --- tests ---

fn expectStr(n: ?Node, want: []const u8) !void {
    try std.testing.expect(n != null);
    try std.testing.expectEqualStrings(want, n.?.text() orelse return error.TestExpectedString);
}

test "mappings, nesting, comments and scalars" {
    var a: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer a.deinit();
    const n = try parse(a.allocator(),
        \\# a comment
        \\name: "Dagger for GitHub"   # trailing
        \\description: Run dagger commands in Github Actions
        \\inputs:
        \\  version:
        \\    description: "Dagger Version. Use semver vX.Y.Z or 'latest'"
        \\    required: false
        \\    default: "latest"
        \\  empty:
        \\    description: ''
        \\url: https://example.com/a#b
        \\nothing:
        \\tilde: ~
    , null);
    try expectStr(n.get("name"), "Dagger for GitHub");
    try expectStr(n.get("description"), "Run dagger commands in Github Actions");
    const v = n.get("inputs").?.get("version").?;
    try expectStr(v.get("required"), "false");
    try expectStr(v.get("default"), "latest");
    try expectStr(v.get("description"), "Dagger Version. Use semver vX.Y.Z or 'latest'");
    try expectStr(n.get("inputs").?.get("empty").?.get("description"), "");
    try expectStr(n.get("url"), "https://example.com/a#b");
    try std.testing.expect(n.get("nothing").? == .null);
    try std.testing.expect(n.get("tilde").? == .null);
}

test "sequences of mappings and scalars, with the sequence at the key's indentation" {
    var a: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer a.deinit();
    const n = try parse(a.allocator(),
        \\runs:
        \\  using: "composite"
        \\  steps:
        \\    - shell: bash
        \\      run: echo hi
        \\    - id: two
        \\      shell: sh
        \\      env:
        \\        A: 1
        \\    - name: bare
        \\      uses: x/y@v1
        \\list:
        \\- a
        \\- b
        \\- - nested
        \\  - seq
    , null);
    const steps = n.get("runs").?.get("steps").?.seq;
    try std.testing.expectEqual(@as(usize, 3), steps.len);
    try expectStr(steps[0].get("run"), "echo hi");
    try expectStr(steps[1].get("id"), "two");
    try expectStr(steps[1].get("env").?.get("A"), "1");
    try expectStr(steps[2].get("uses"), "x/y@v1");
    const list = n.get("list").?.seq;
    try std.testing.expectEqual(@as(usize, 3), list.len);
    try expectStr(list[1], "b");
    try expectStr(list[2].seq[1], "seq");
}

test "block scalars: literal, folded, chomping, and bodies that look like YAML" {
    var a: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer a.deinit();
    const n = try parse(a.allocator(),
        \\steps:
        \\  - run: |
        \\      set -o pipefail
        \\      # not a yaml comment
        \\      if [[ -n "$x" ]]; then
        \\        echo "a: b"
        \\      fi
        \\
        \\      echo done
        \\    shell: bash
        \\  - run: |-
        \\      no newline
        \\  - run: >
        \\      folded text
        \\      continues here
        \\
        \\      new paragraph
        \\  - run: |+
        \\      keep
        \\
        \\  - run: >-
        \\      One of:
        \\
        \\      - a list item
        \\        continued
        \\
        \\      After the list.
        \\next: after
    , null);
    const steps = n.get("steps").?.seq;
    try expectStr(steps[0].get("run"), "set -o pipefail\n# not a yaml comment\nif [[ -n \"$x\" ]]; then\n  echo \"a: b\"\nfi\n\necho done\n");
    try expectStr(steps[0].get("shell"), "bash");
    try expectStr(steps[1].get("run"), "no newline");
    try expectStr(steps[2].get("run"), "folded text continues here\nnew paragraph\n");
    try expectStr(steps[3].get("run"), "keep\n\n");
    // Lines next to a more-indented line keep their breaks (checked against Ruby's Psych).
    try expectStr(steps[4].get("run"), "One of:\n- a list item\n  continued\n\nAfter the list.");
    try expectStr(n.get("next"), "after");
}

test "a block scalar directly under a dash" {
    var a: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer a.deinit();
    const n = try parse(a.allocator(),
        \\- |
        \\  one
        \\  two
        \\- last
    , null);
    try expectStr(n.seq[0], "one\ntwo\n");
    try expectStr(n.seq[1], "last");
}

test "quoted strings, escapes and flow collections" {
    var a: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer a.deinit();
    const n = try parse(a.allocator(),
        \\single: 'it''s'
        \\double: "tab\there \"quoted\" \u00e9"
        \\flow: [a, "b c", 'd']
        \\branding: { icon: box, color: blue }
        \\args: [--a, --b=1]
        \\"quoted key": v
        \\url: "http://x:80"
    , null);
    try expectStr(n.get("single"), "it's");
    try expectStr(n.get("double"), "tab\there \"quoted\" \u{e9}");
    const flow = n.get("flow").?.seq;
    try expectStr(flow[1], "b c");
    try expectStr(flow[2], "d");
    try expectStr(n.get("branding").?.get("color"), "blue");
    try expectStr(n.get("args").?.seq[1], "--b=1");
    try expectStr(n.get("quoted key"), "v");
    try expectStr(n.get("url"), "http://x:80");
}

test "plain scalars continue on following lines; expressions keep their colons" {
    var a: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer a.deinit();
    const n = try parse(a.allocator(),
        \\description: first part
        \\  second part
        \\if: ${{ inputs.x == 'a: b' && github.event_name }}
        \\value: ${{ steps.exec.outputs.stdout }}
    , null);
    try expectStr(n.get("description"), "first part second part");
    try expectStr(n.get("if"), "${{ inputs.x == 'a: b' && github.event_name }}");
    try expectStr(n.get("value"), "${{ steps.exec.outputs.stdout }}");
}

test "quoted strings that span lines are folded" {
    var a: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer a.deinit();
    const n = try parse(a.allocator(),
        \\inputs:
        \\  merge-multiple:
        \\    description: 'When multiple artifacts match, this changes things.
        \\      If true, they share a directory.
        \\
        \\      New paragraph.'
        \\    required: false
        \\  glob:
        \\    description:
        \\      "Glob pattern to match files relative to the working directory to control
        \\      the cache."
        \\    default: x
    , null);
    const in = n.get("inputs").?;
    try expectStr(in.get("merge-multiple").?.get("description"), "When multiple artifacts match, this changes things. If true, they share a directory.\nNew paragraph.");
    try expectStr(in.get("merge-multiple").?.get("required"), "false");
    try expectStr(in.get("glob").?.get("description"), "Glob pattern to match files relative to the working directory to control the cache.");
    try expectStr(in.get("glob").?.get("default"), "x");
}

test "a leading document marker, CRLF line endings and duplicate keys" {
    var a: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer a.deinit();
    const n = try parse(a.allocator(), "---\r\nname: x\r\nname: y\r\nk:\r\n  - 1\r\n", null);
    try expectStr(n.get("name"), "y");
    try expectStr(n.get("k").?.seq[0], "1");
}

test "a lone scalar at the top level" {
    var a: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer a.deinit();
    try expectStr(try parse(a.allocator(), "just text\n", null), "just text");
}

test "constructs outside the subset are rejected, not misread" {
    var a: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer a.deinit();
    const cases = [_]struct { src: []const u8, err: Error }{
        .{ .src = "a: &x 1\n", .err = error.UnsupportedYaml },
        .{ .src = "a: *x\n", .err = error.UnsupportedYaml },
        .{ .src = "a: !!str 1\n", .err = error.UnsupportedYaml },
        .{ .src = "<<: *x\n", .err = error.UnsupportedYaml },
        .{ .src = "a: 1\n---\nb: 2\n", .err = error.UnsupportedYaml },
        .{ .src = "a: \"open\n", .err = error.UnsupportedYaml },
        .{ .src = "a: \"open\nb: 1\n", .err = error.UnsupportedYaml },
        .{ .src = "a: [1,\n  2]\n", .err = error.UnsupportedYaml },
        .{ .src = "? a\n: b\n", .err = error.UnsupportedYaml },
        .{ .src = "a:\n\tb: 1\n", .err = error.InvalidYaml },
        .{ .src = "a: b\n  c: d\n", .err = error.InvalidYaml },
    };
    for (cases) |c| {
        var d: Diag = .{};
        try std.testing.expectError(c.err, parse(a.allocator(), c.src, &d));
        try std.testing.expect(d.line > 0);
    }
}

test "the dagger-for-github action.yml shape parses" {
    var a: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer a.deinit();
    const n = try parse(a.allocator(),
        \\name: "Dagger for GitHub"
        \\inputs:
        \\  engine-stop:
        \\    description: "Deprecated"
        \\    deprecationMessage: "engine-stop is now a no-op"
        \\    required: false
        \\outputs:
        \\  output:
        \\    description: "Job output"
        \\    value: ${{ steps.exec.outputs.stdout }}
        \\runs:
        \\  using: "composite"
        \\  steps:
        \\    - shell: bash
        \\      run: |
        \\        VERSION=${{ inputs.version }}
        \\        if [[ "$VERSION" == "latest" ]]; then
        \\          VERSION=
        \\        fi
        \\    - id: should-exec
        \\      shell: bash
        \\      env:
        \\        INPUT_CALL: ${{ inputs.call }}
        \\      run: |
        \\        echo "result=true" >> "$GITHUB_OUTPUT"
        \\    - id: assemble
        \\      if: steps.should-exec.outputs.result == 'true'
        \\      shell: bash
        \\      run: |
        \\        args=$(echo '${{ toJSON(inputs.args) }}' | jq -rj . | sed -z 's/\\\n/ /g; s/\n/ /g')
    , null);
    const steps = n.get("runs").?.get("steps").?.seq;
    try std.testing.expectEqual(@as(usize, 3), steps.len);
    try expectStr(steps[1].get("id"), "should-exec");
    try expectStr(steps[1].get("env").?.get("INPUT_CALL"), "${{ inputs.call }}");
    try expectStr(steps[2].get("if"), "steps.should-exec.outputs.result == 'true'");
    try std.testing.expect(std.mem.indexOf(u8, steps[2].get("run").?.text().?, "sed -z 's/\\\\\\n/ /g; s/\\n/ /g'") != null);
    try expectStr(n.get("outputs").?.get("output").?.get("value"), "${{ steps.exec.outputs.stdout }}");
}
