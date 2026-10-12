//! GitHub Actions expressions (`${{ ... }}` and `if:` conditions).
//!
//! A small tokenizer, parser and evaluator following GitHub's documented semantics: literals,
//! context lookups (`github.sha`, `env.X`, `steps.id.outputs.y`, `matrix['os']`), the operators
//! `! < <= > >= == != && ||` with GitHub's loose type coercion (string comparison is case
//! insensitive, `&&`/`||` return an operand), and the functions contains, startsWith, endsWith,
//! format, join, toJSON, fromJSON and success/always/cancelled/failure. `hashFiles` and the `*`
//! object filter are not supported and report so, instead of evaluating wrongly.
const std = @import("std");

const Allocator = std.mem.Allocator;

pub const Value = union(enum) {
    null,
    boolean: bool,
    number: f64,
    string: []const u8,
    array: []const Value,
    /// Property names are matched case-insensitively, as GitHub does.
    object: []const Entry,

    pub const Entry = struct { key: []const u8, value: Value };

    pub fn str(s: []const u8) Value {
        return .{ .string = s };
    }
};

pub const Error = error{ ParseError, EvalError, Unsupported, OutOfMemory };

/// What an expression can see.
pub const Scope = struct {
    /// Top-level contexts: `github`, `env`, `steps`, `job`, `runner`, `secrets`, `vars`, ...
    contexts: []const Value.Entry = &.{},
    /// True once a step failed without continue-on-error (drives `success()` / `failure()`).
    job_failed: bool = false,
    cancelled: bool = false,
    /// Contexts that exist in GitHub but that this runner cannot provide yet (for example `secrets`).
    /// Referencing one is an error instead of silently evaluating to an empty value.
    unsupported_contexts: []const []const u8 = &.{},
    /// Receives a human-readable reason when an error is returned. Optional.
    diag: ?*[]const u8 = null,

    fn fail(s: Scope, comptime fmt: []const u8, args: anytype, arena: Allocator) Error {
        if (s.diag) |d| d.* = std.fmt.allocPrint(arena, fmt, args) catch "expression error";
        return error.EvalError;
    }
};

// --- tokens ---

const Tok = union(enum) {
    number: f64,
    string: []const u8,
    ident: []const u8,
    lparen,
    rparen,
    lbracket,
    rbracket,
    dot,
    comma,
    star,
    not,
    and_and,
    or_or,
    eq,
    ne,
    lt,
    le,
    gt,
    ge,
    eof,
};

const Lexer = struct {
    src: []const u8,
    i: usize = 0,
    arena: Allocator,
    diag: ?*[]const u8,

    fn bad(l: *Lexer, comptime fmt: []const u8, args: anytype) Error {
        if (l.diag) |d| d.* = std.fmt.allocPrint(l.arena, fmt ++ " (in expression: {s})", args ++ .{l.src}) catch "invalid expression";
        return error.ParseError;
    }

    fn next(l: *Lexer, prev_is_value: bool) Error!Tok {
        while (l.i < l.src.len and std.ascii.isWhitespace(l.src[l.i])) l.i += 1;
        if (l.i >= l.src.len) return .eof;
        const c = l.src[l.i];
        const two: []const u8 = if (l.i + 1 < l.src.len) l.src[l.i .. l.i + 2] else "";
        if (std.mem.eql(u8, two, "&&")) return l.adv(2, .and_and);
        if (std.mem.eql(u8, two, "||")) return l.adv(2, .or_or);
        if (std.mem.eql(u8, two, "==")) return l.adv(2, .eq);
        if (std.mem.eql(u8, two, "!=")) return l.adv(2, .ne);
        if (std.mem.eql(u8, two, "<=")) return l.adv(2, .le);
        if (std.mem.eql(u8, two, ">=")) return l.adv(2, .ge);
        switch (c) {
            '(' => return l.adv(1, .lparen),
            ')' => return l.adv(1, .rparen),
            '[' => return l.adv(1, .lbracket),
            ']' => return l.adv(1, .rbracket),
            '.' => return l.adv(1, .dot),
            ',' => return l.adv(1, .comma),
            '*' => return l.adv(1, .star),
            '!' => return l.adv(1, .not),
            '<' => return l.adv(1, .lt),
            '>' => return l.adv(1, .gt),
            '\'' => return l.string(),
            else => {},
        }
        if (std.ascii.isDigit(c) or (c == '-' and !prev_is_value and l.i + 1 < l.src.len and std.ascii.isDigit(l.src[l.i + 1]))) return l.number();
        if (std.ascii.isAlphabetic(c) or c == '_') {
            const start = l.i;
            while (l.i < l.src.len and (std.ascii.isAlphanumeric(l.src[l.i]) or l.src[l.i] == '_' or l.src[l.i] == '-')) l.i += 1;
            return .{ .ident = l.src[start..l.i] };
        }
        return l.bad("unexpected character '{c}'", .{c});
    }

    fn adv(l: *Lexer, n: usize, t: Tok) Tok {
        l.i += n;
        return t;
    }

    fn string(l: *Lexer) Error!Tok {
        l.i += 1; // opening quote
        var out: std.ArrayList(u8) = .empty;
        while (l.i < l.src.len) {
            const c = l.src[l.i];
            if (c == '\'') {
                if (l.i + 1 < l.src.len and l.src[l.i + 1] == '\'') {
                    try out.append(l.arena, '\'');
                    l.i += 2;
                    continue;
                }
                l.i += 1;
                return .{ .string = out.items };
            }
            try out.append(l.arena, c);
            l.i += 1;
        }
        return l.bad("unterminated string", .{});
    }

    fn number(l: *Lexer) Error!Tok {
        const start = l.i;
        if (l.src[l.i] == '-') l.i += 1;
        if (l.i + 1 < l.src.len and l.src[l.i] == '0' and (l.src[l.i + 1] == 'x' or l.src[l.i + 1] == 'X')) {
            l.i += 2;
            while (l.i < l.src.len and std.ascii.isHex(l.src[l.i])) l.i += 1;
        } else {
            while (l.i < l.src.len and (std.ascii.isDigit(l.src[l.i]) or l.src[l.i] == '.' or l.src[l.i] == 'e' or l.src[l.i] == 'E' or
                ((l.src[l.i] == '+' or l.src[l.i] == '-') and (l.src[l.i - 1] == 'e' or l.src[l.i - 1] == 'E')))) l.i += 1;
        }
        const text = l.src[start..l.i];
        const neg = text[0] == '-';
        const body = if (neg) text[1..] else text;
        const v: f64 = if (body.len > 2 and (body[1] == 'x' or body[1] == 'X'))
            @floatFromInt(std.fmt.parseInt(i64, body[2..], 16) catch return l.bad("invalid number '{s}'", .{text}))
        else
            std.fmt.parseFloat(f64, body) catch return l.bad("invalid number '{s}'", .{text});
        return .{ .number = if (neg) -v else v };
    }
};

// --- AST and parser ---

const BinOp = enum { and_, or_, eq, ne, lt, le, gt, ge };

const Node = union(enum) {
    literal: Value,
    ident: []const u8,
    prop: struct { obj: *Node, name: []const u8 },
    index: struct { obj: *Node, idx: *Node },
    star: *Node,
    call: struct { name: []const u8, args: []*Node },
    not: *Node,
    bin: struct { op: BinOp, l: *Node, r: *Node },
};

const Parser = struct {
    lex: Lexer,
    cur: Tok,
    prev_value: bool = false,

    fn init(arena: Allocator, src: []const u8, diag: ?*[]const u8) Error!Parser {
        var p: Parser = .{ .lex = .{ .src = src, .arena = arena, .diag = diag }, .cur = .eof };
        p.cur = try p.lex.next(false);
        return p;
    }

    fn advance(p: *Parser) Error!void {
        p.prev_value = switch (p.cur) {
            .number, .string, .ident, .rparen, .rbracket => true,
            else => false,
        };
        p.cur = try p.lex.next(p.prev_value);
    }

    fn node(p: *Parser, n: Node) Error!*Node {
        const ptr = try p.lex.arena.create(Node);
        ptr.* = n;
        return ptr;
    }

    fn expectEnd(p: *Parser) Error!void {
        if (p.cur != .eof) return p.lex.bad("unexpected token after the end of the expression", .{});
    }

    fn parseOr(p: *Parser) Error!*Node {
        var l = try p.parseAnd();
        while (p.cur == .or_or) {
            try p.advance();
            l = try p.node(.{ .bin = .{ .op = .or_, .l = l, .r = try p.parseAnd() } });
        }
        return l;
    }

    fn parseAnd(p: *Parser) Error!*Node {
        var l = try p.parseEq();
        while (p.cur == .and_and) {
            try p.advance();
            l = try p.node(.{ .bin = .{ .op = .and_, .l = l, .r = try p.parseEq() } });
        }
        return l;
    }

    fn parseEq(p: *Parser) Error!*Node {
        var l = try p.parseRel();
        while (p.cur == .eq or p.cur == .ne) {
            const op: BinOp = if (p.cur == .eq) .eq else .ne;
            try p.advance();
            l = try p.node(.{ .bin = .{ .op = op, .l = l, .r = try p.parseRel() } });
        }
        return l;
    }

    fn parseRel(p: *Parser) Error!*Node {
        var l = try p.parseUnary();
        while (p.cur == .lt or p.cur == .le or p.cur == .gt or p.cur == .ge) {
            const op: BinOp = switch (p.cur) {
                .lt => .lt,
                .le => .le,
                .gt => .gt,
                else => .ge,
            };
            try p.advance();
            l = try p.node(.{ .bin = .{ .op = op, .l = l, .r = try p.parseUnary() } });
        }
        return l;
    }

    fn parseUnary(p: *Parser) Error!*Node {
        if (p.cur == .not) {
            try p.advance();
            return p.node(.{ .not = try p.parseUnary() });
        }
        return p.parsePostfix();
    }

    fn parsePostfix(p: *Parser) Error!*Node {
        var n = try p.parsePrimary();
        while (true) {
            switch (p.cur) {
                .dot => {
                    try p.advance();
                    switch (p.cur) {
                        .ident => |name| {
                            try p.advance();
                            n = try p.node(.{ .prop = .{ .obj = n, .name = name } });
                        },
                        .star => {
                            try p.advance();
                            n = try p.node(.{ .star = n });
                        },
                        else => return p.lex.bad("expected a property name after '.'", .{}),
                    }
                },
                .lbracket => {
                    try p.advance();
                    const idx = try p.parseOr();
                    if (p.cur != .rbracket) return p.lex.bad("expected ']'", .{});
                    try p.advance();
                    n = try p.node(.{ .index = .{ .obj = n, .idx = idx } });
                },
                else => return n,
            }
        }
    }

    fn parsePrimary(p: *Parser) Error!*Node {
        switch (p.cur) {
            .number => |v| {
                try p.advance();
                return p.node(.{ .literal = .{ .number = v } });
            },
            .string => |s| {
                try p.advance();
                return p.node(.{ .literal = .{ .string = s } });
            },
            .lparen => {
                try p.advance();
                const inner = try p.parseOr();
                if (p.cur != .rparen) return p.lex.bad("expected ')'", .{});
                try p.advance();
                return inner;
            },
            .ident => |name| {
                try p.advance();
                if (p.cur == .lparen) {
                    try p.advance();
                    var args: std.ArrayList(*Node) = .empty;
                    if (p.cur != .rparen) {
                        while (true) {
                            try args.append(p.lex.arena, try p.parseOr());
                            if (p.cur == .comma) {
                                try p.advance();
                                continue;
                            }
                            break;
                        }
                    }
                    if (p.cur != .rparen) return p.lex.bad("expected ')' after the arguments of {s}()", .{name});
                    try p.advance();
                    return p.node(.{ .call = .{ .name = name, .args = args.items } });
                }
                if (std.ascii.eqlIgnoreCase(name, "true")) return p.node(.{ .literal = .{ .boolean = true } });
                if (std.ascii.eqlIgnoreCase(name, "false")) return p.node(.{ .literal = .{ .boolean = false } });
                if (std.ascii.eqlIgnoreCase(name, "null")) return p.node(.{ .literal = .null });
                if (std.ascii.eqlIgnoreCase(name, "nan")) return p.node(.{ .literal = .{ .number = std.math.nan(f64) } });
                if (std.ascii.eqlIgnoreCase(name, "infinity")) return p.node(.{ .literal = .{ .number = std.math.inf(f64) } });
                return p.node(.{ .ident = name });
            },
            else => return p.lex.bad("unexpected token", .{}),
        }
    }
};

fn parse(arena: Allocator, src: []const u8, diag: ?*[]const u8) Error!*Node {
    var p = try Parser.init(arena, src, diag);
    const n = try p.parseOr();
    try p.expectEnd();
    return n;
}

// --- coercion ---

pub fn toBool(v: Value) bool {
    return switch (v) {
        .null => false,
        .boolean => |b| b,
        .number => |n| !(n == 0),
        .string => |s| s.len > 0,
        .array, .object => true,
    };
}

pub fn toNumber(v: Value) f64 {
    return switch (v) {
        .null => 0,
        .boolean => |b| if (b) 1 else 0,
        .number => |n| n,
        .string => |s| blk: {
            const t = std.mem.trim(u8, s, " \t\r\n");
            if (t.len == 0) break :blk 0;
            if (t.len > 2 and t[0] == '0' and (t[1] == 'x' or t[1] == 'X'))
                break :blk @floatFromInt(std.fmt.parseInt(i64, t[2..], 16) catch break :blk std.math.nan(f64));
            break :blk std.fmt.parseFloat(f64, t) catch std.math.nan(f64);
        },
        .array, .object => std.math.nan(f64),
    };
}

pub fn toStr(arena: Allocator, v: Value) Allocator.Error![]const u8 {
    return switch (v) {
        .null => "",
        .boolean => |b| if (b) "true" else "false",
        .number => |n| numberToString(arena, n),
        .string => |s| s,
        .array => "Array",
        .object => "Object",
    };
}

fn numberToString(arena: Allocator, n: f64) Allocator.Error![]const u8 {
    if (std.math.isNan(n)) return "NaN";
    if (std.math.isInf(n)) return if (n > 0) "Infinity" else "-Infinity";
    if (@floor(n) == n and @abs(n) < 1e15) return std.fmt.allocPrint(arena, "{d}", .{@as(i64, @intFromFloat(n))});
    return std.fmt.allocPrint(arena, "{d}", .{n});
}

fn sameKind(a: Value, b: Value) bool {
    return std.meta.activeTag(a) == std.meta.activeTag(b);
}

fn looseEquals(a: Value, b: Value) bool {
    if (sameKind(a, b)) return switch (a) {
        .null => true,
        .boolean => |x| x == b.boolean,
        .number => |x| x == b.number,
        .string => |x| std.ascii.eqlIgnoreCase(x, b.string),
        // Arrays and objects only equal themselves.
        .array => |x| x.ptr == b.array.ptr and x.len == b.array.len,
        .object => |x| x.ptr == b.object.ptr and x.len == b.object.len,
    };
    const x = toNumber(a);
    const y = toNumber(b);
    return x == y; // NaN never equals anything
}

fn compare(a: Value, b: Value) ?std.math.Order {
    if (a == .string and b == .string) return std.ascii.orderIgnoreCase(a.string, b.string);
    const x = toNumber(a);
    const y = toNumber(b);
    if (std.math.isNan(x) or std.math.isNan(y)) return null;
    return std.math.order(x, y);
}

// --- evaluation ---

fn lookupEntry(entries: []const Value.Entry, name: []const u8) ?Value {
    for (entries) |e| if (std.ascii.eqlIgnoreCase(e.key, name)) return e.value;
    return null;
}

fn deref(v: Value, key: Value, arena: Allocator) Allocator.Error!Value {
    switch (v) {
        .object => |o| {
            const k = try toStr(arena, key);
            return lookupEntry(o, k) orelse .null;
        },
        .array => |a| {
            if (key != .number and key != .string) return .null;
            const n = toNumber(key);
            if (std.math.isNan(n) or n < 0 or @floor(n) != n) return .null;
            const i: usize = @intFromFloat(n);
            return if (i < a.len) a[i] else .null;
        },
        else => return .null,
    }
}

fn eval(arena: Allocator, n: *const Node, scope: Scope) Error!Value {
    switch (n.*) {
        .literal => |v| return v,
        .ident => |name| {
            for (scope.unsupported_contexts) |u| if (std.ascii.eqlIgnoreCase(u, name)) {
                if (scope.diag) |d| d.* = std.fmt.allocPrint(arena, "the '{s}' context is not supported yet", .{name}) catch "unsupported context";
                return error.Unsupported;
            };
            return lookupEntry(scope.contexts, name) orelse .null;
        },
        .prop => |p| return deref(try eval(arena, p.obj, scope), .{ .string = p.name }, arena),
        .index => |ix| {
            const o = try eval(arena, ix.obj, scope);
            return deref(o, try eval(arena, ix.idx, scope), arena);
        },
        .star => return error.Unsupported,
        .not => |inner| return .{ .boolean = !toBool(try eval(arena, inner, scope)) },
        .bin => |b| {
            const l = try eval(arena, b.l, scope);
            switch (b.op) {
                .and_ => return if (!toBool(l)) l else try eval(arena, b.r, scope),
                .or_ => return if (toBool(l)) l else try eval(arena, b.r, scope),
                else => {},
            }
            const r = try eval(arena, b.r, scope);
            return .{ .boolean = switch (b.op) {
                .eq => looseEquals(l, r),
                .ne => !looseEquals(l, r),
                .lt => if (compare(l, r)) |o| o == .lt else false,
                .le => if (compare(l, r)) |o| o != .gt else false,
                .gt => if (compare(l, r)) |o| o == .gt else false,
                .ge => if (compare(l, r)) |o| o != .lt else false,
                else => unreachable,
            } };
        },
        .call => |c| return callFunction(arena, c.name, c.args, scope),
    }
}

fn callFunction(arena: Allocator, name: []const u8, arg_nodes: []*Node, scope: Scope) Error!Value {
    const eql = std.ascii.eqlIgnoreCase;
    if (eql(name, "success")) return .{ .boolean = !scope.job_failed and !scope.cancelled };
    if (eql(name, "always")) return .{ .boolean = true };
    if (eql(name, "cancelled")) return .{ .boolean = scope.cancelled };
    if (eql(name, "failure")) return .{ .boolean = scope.job_failed and !scope.cancelled };
    if (eql(name, "hashFiles")) {
        if (scope.diag) |d| d.* = "hashFiles() is not supported yet";
        return error.Unsupported;
    }

    const args = try arena.alloc(Value, arg_nodes.len);
    for (arg_nodes, args) |an, *out| out.* = try eval(arena, an, scope);

    if (eql(name, "contains")) {
        if (args.len != 2) return scope.fail("contains() takes 2 arguments", .{}, arena);
        switch (args[0]) {
            .array => |a| {
                for (a) |e| if (looseEquals(e, args[1])) return .{ .boolean = true };
                return .{ .boolean = false };
            },
            else => {
                const hay = try toStr(arena, args[0]);
                const needle = try toStr(arena, args[1]);
                return .{ .boolean = std.ascii.findIgnoreCase(hay, needle) != null };
            },
        }
    }
    if (eql(name, "startsWith") or eql(name, "endsWith")) {
        if (args.len != 2) return scope.fail("{s}() takes 2 arguments", .{name}, arena);
        const s = try toStr(arena, args[0]);
        const t = try toStr(arena, args[1]);
        return .{ .boolean = if (eql(name, "startsWith")) std.ascii.startsWithIgnoreCase(s, t) else std.ascii.endsWithIgnoreCase(s, t) };
    }
    if (eql(name, "format")) {
        if (args.len < 1) return scope.fail("format() needs a format string", .{}, arena);
        return .{ .string = try formatString(arena, try toStr(arena, args[0]), args[1..], scope) };
    }
    if (eql(name, "join")) {
        if (args.len < 1 or args.len > 2) return scope.fail("join() takes 1 or 2 arguments", .{}, arena);
        const sep = if (args.len == 2) try toStr(arena, args[1]) else ",";
        switch (args[0]) {
            .array => |a| {
                var out: std.ArrayList(u8) = .empty;
                for (a, 0..) |e, i| {
                    if (i > 0) try out.appendSlice(arena, sep);
                    try out.appendSlice(arena, try toStr(arena, e));
                }
                return .{ .string = out.items };
            },
            else => return .{ .string = try toStr(arena, args[0]) },
        }
    }
    if (eql(name, "toJSON")) {
        if (args.len != 1) return scope.fail("toJSON() takes 1 argument", .{}, arena);
        var aw: std.Io.Writer.Allocating = .init(arena);
        writeJson(&aw.writer, args[0], 0) catch return error.OutOfMemory; // Allocating writer: only OOM
        return .{ .string = aw.written() };
    }
    if (eql(name, "fromJSON")) {
        if (args.len != 1) return scope.fail("fromJSON() takes 1 argument", .{}, arena);
        const text = try toStr(arena, args[0]);
        const parsed = std.json.parseFromSliceLeaky(std.json.Value, arena, text, .{}) catch
            return scope.fail("fromJSON(): invalid JSON", .{}, arena);
        return fromJsonValue(arena, parsed);
    }
    return scope.fail("unknown function '{s}'", .{name}, arena);
}

fn formatString(arena: Allocator, fmt: []const u8, args: []const Value, scope: Scope) Error![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    var i: usize = 0;
    while (i < fmt.len) {
        const c = fmt[i];
        if (c == '{') {
            if (i + 1 < fmt.len and fmt[i + 1] == '{') {
                try out.append(arena, '{');
                i += 2;
                continue;
            }
            const close = std.mem.indexOfScalarPos(u8, fmt, i, '}') orelse return scope.fail("format(): unterminated '{{' in '{s}'", .{fmt}, arena);
            const idx = std.fmt.parseInt(usize, fmt[i + 1 .. close], 10) catch return scope.fail("format(): invalid placeholder '{s}'", .{fmt[i .. close + 1]}, arena);
            if (idx >= args.len) return scope.fail("format(): placeholder {{{d}}} has no argument", .{idx}, arena);
            try out.appendSlice(arena, try toStr(arena, args[idx]));
            i = close + 1;
        } else if (c == '}') {
            if (i + 1 < fmt.len and fmt[i + 1] == '}') {
                try out.append(arena, '}');
                i += 2;
                continue;
            }
            return scope.fail("format(): unmatched '}}' in '{s}'", .{fmt}, arena);
        } else {
            try out.append(arena, c);
            i += 1;
        }
    }
    return out.items;
}

fn writeJson(w: *std.Io.Writer, v: Value, depth: usize) !void {
    switch (v) {
        .null => try w.writeAll("null"),
        .boolean => |b| try w.writeAll(if (b) "true" else "false"),
        .number => |n| if (@floor(n) == n and @abs(n) < 1e15) try w.print("{d}", .{@as(i64, @intFromFloat(n))}) else try w.print("{d}", .{n}),
        .string => |s| try std.json.Stringify.value(s, .{}, w),
        .array => |a| {
            if (a.len == 0) return w.writeAll("[]");
            try w.writeAll("[\n");
            for (a, 0..) |e, i| {
                try w.splatByteAll(' ', (depth + 1) * 2);
                try writeJson(w, e, depth + 1);
                try w.writeAll(if (i + 1 < a.len) ",\n" else "\n");
            }
            try w.splatByteAll(' ', depth * 2);
            try w.writeByte(']');
        },
        .object => |o| {
            if (o.len == 0) return w.writeAll("{}");
            try w.writeAll("{\n");
            for (o, 0..) |e, i| {
                try w.splatByteAll(' ', (depth + 1) * 2);
                try std.json.Stringify.value(e.key, .{}, w);
                try w.writeAll(": ");
                try writeJson(w, e.value, depth + 1);
                try w.writeAll(if (i + 1 < o.len) ",\n" else "\n");
            }
            try w.splatByteAll(' ', depth * 2);
            try w.writeByte('}');
        },
    }
}

pub fn fromJsonValue(arena: Allocator, j: std.json.Value) Allocator.Error!Value {
    switch (j) {
        .null => return .null,
        .bool => |b| return .{ .boolean = b },
        .integer => |i| return .{ .number = @floatFromInt(i) },
        .float => |f| return .{ .number = f },
        .number_string => |s| return .{ .number = std.fmt.parseFloat(f64, s) catch std.math.nan(f64) },
        .string => |s| return .{ .string = s },
        .array => |a| {
            const out = try arena.alloc(Value, a.items.len);
            for (a.items, out) |e, *o| o.* = try fromJsonValue(arena, e);
            return .{ .array = out };
        },
        .object => |o| {
            const out = try arena.alloc(Value.Entry, o.count());
            var it = o.iterator();
            var i: usize = 0;
            while (it.next()) |e| : (i += 1) out[i] = .{ .key = e.key_ptr.*, .value = try fromJsonValue(arena, e.value_ptr.*) };
            return .{ .object = out };
        },
    }
}

// --- public API ---

/// Evaluates one expression (the text inside `${{ }}`).
pub fn evaluate(arena: Allocator, text: []const u8, scope: Scope) Error!Value {
    const n = try parse(arena, text, scope.diag);
    return eval(arena, n, scope) catch |e| switch (e) {
        error.Unsupported => {
            if (scope.diag) |d| if (d.*.len == 0) {
                d.* = "the '*' object filter is not supported yet";
            };
            return e;
        },
        else => return e,
    };
}

pub fn evalString(arena: Allocator, text: []const u8, scope: Scope) Error![]const u8 {
    return toStr(arena, try evaluate(arena, text, scope));
}

/// Replaces every `${{ <expression> }}` in `text` with its value as a string. The job message
/// arrives with this already done (as `format()` expressions), but `action.yml` files are read as
/// they are written. A `}}` inside a quoted string does not end the expression.
pub fn interpolate(arena: Allocator, text: []const u8, scope: Scope) Error![]const u8 {
    if (std.mem.indexOf(u8, text, "${{") == null) return text;
    var out: std.ArrayList(u8) = .empty;
    var i: usize = 0;
    while (std.mem.indexOfPos(u8, text, i, "${{")) |open| {
        try out.appendSlice(arena, text[i..open]);
        const body_start = open + 3;
        const close = expressionEnd(text, body_start) orelse {
            if (scope.diag) |d| d.* = "'${{' is never closed with '}}'";
            return error.ParseError;
        };
        try out.appendSlice(arena, try evalString(arena, text[body_start..close], scope));
        i = close + 2;
    }
    try out.appendSlice(arena, text[i..]);
    return out.items;
}

/// Index of the `}}` that ends the expression starting at `from`, skipping 'quoted' strings.
fn expressionEnd(text: []const u8, from: usize) ?usize {
    var i = from;
    var in_str = false;
    while (i < text.len) : (i += 1) {
        const c = text[i];
        if (in_str) {
            if (c == '\'') {
                if (i + 1 < text.len and text[i + 1] == '\'') i += 1 else in_str = false;
            }
        } else if (c == '\'') {
            in_str = true;
        } else if (c == '}' and i + 1 < text.len and text[i + 1] == '}') {
            return i;
        }
    }
    return null;
}

/// Whether an `if:` expression calls success(), always(), failure() or cancelled().
pub fn hasStatusFunction(arena: Allocator, text: []const u8) bool {
    const n = parse(arena, text, null) catch return false;
    return nodeHasStatus(n);
}

fn nodeHasStatus(n: *const Node) bool {
    return switch (n.*) {
        .call => |c| blk: {
            for ([_][]const u8{ "success", "always", "failure", "cancelled" }) |f| if (std.ascii.eqlIgnoreCase(c.name, f)) break :blk true;
            for (c.args) |a| if (nodeHasStatus(a)) break :blk true;
            break :blk false;
        },
        .not => |i| nodeHasStatus(i),
        .bin => |b| nodeHasStatus(b.l) or nodeHasStatus(b.r),
        .prop => |p| nodeHasStatus(p.obj),
        .index => |ix| nodeHasStatus(ix.obj) or nodeHasStatus(ix.idx),
        .star => |i| nodeHasStatus(i),
        else => false,
    };
}

/// Evaluates an `if:` condition. A condition without a status function is implicitly
/// `success() && (<condition>)`, as in GitHub. `${{ }}` around the whole condition is optional.
pub fn evalCondition(arena: Allocator, cond: []const u8, scope: Scope) Error!bool {
    var text = std.mem.trim(u8, cond, " \t\r\n");
    if (std.mem.startsWith(u8, text, "${{") and std.mem.endsWith(u8, text, "}}")) text = std.mem.trim(u8, text[3 .. text.len - 2], " \t\r\n");
    if (text.len == 0) return !scope.job_failed and !scope.cancelled;
    const v = try evaluate(arena, text, scope);
    if (!hasStatusFunction(arena, text) and (scope.job_failed or scope.cancelled)) return false;
    return toBool(v);
}

// --- tests ---

fn tctx(entries: []const Value.Entry) Scope {
    return .{ .contexts = entries };
}

fn evalStr(arena: Allocator, text: []const u8, scope: Scope) ![]const u8 {
    return evalString(arena, text, scope);
}

test "literals and coercion" {
    var a: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer a.deinit();
    const s: Scope = .{};
    try std.testing.expectEqualStrings("hello", try evalStr(a.allocator(), "'hello'", s));
    try std.testing.expectEqualStrings("it's", try evalStr(a.allocator(), "'it''s'", s));
    try std.testing.expectEqualStrings("42", try evalStr(a.allocator(), "42", s));
    try std.testing.expectEqualStrings("-3.5", try evalStr(a.allocator(), "-3.5", s));
    try std.testing.expectEqualStrings("255", try evalStr(a.allocator(), "0xff", s));
    try std.testing.expectEqualStrings("true", try evalStr(a.allocator(), "TRUE", s));
    try std.testing.expectEqualStrings("", try evalStr(a.allocator(), "null", s));
}

test "operators follow GitHub's loose comparison" {
    var a: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer a.deinit();
    const ar = a.allocator();
    const s: Scope = .{};
    try std.testing.expect(try evalCondition(ar, "'ABC' == 'abc'", s)); // case-insensitive
    try std.testing.expect(try evalCondition(ar, "1 == '1'", s)); // string -> number
    try std.testing.expect(try evalCondition(ar, "null == 0", s));
    try std.testing.expect(try evalCondition(ar, "true == 1", s));
    try std.testing.expect(!(try evalCondition(ar, "'a' == 'b'", s)));
    try std.testing.expect(try evalCondition(ar, "'a' != 'b'", s));
    try std.testing.expect(try evalCondition(ar, "2 > 1 && 1 >= 1 && 1 < 2 && 2 <= 2", s));
    try std.testing.expect(try evalCondition(ar, "'b' > 'A'", s));
    try std.testing.expect(!(try evalCondition(ar, "NaN == NaN", s)));
    try std.testing.expect(!(try evalCondition(ar, "'x' > 1", s))); // NaN comparison is false
    try std.testing.expect(try evalCondition(ar, "!false", s));
    try std.testing.expect(try evalCondition(ar, "!(1 == 2)", s));
}

test "&& and || return operands" {
    var a: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer a.deinit();
    const ar = a.allocator();
    const s: Scope = .{};
    try std.testing.expectEqualStrings("fallback", try evalStr(ar, "'' || 'fallback'", s));
    try std.testing.expectEqualStrings("first", try evalStr(ar, "'first' || 'second'", s));
    try std.testing.expectEqualStrings("second", try evalStr(ar, "'first' && 'second'", s));
    try std.testing.expectEqualStrings("0", try evalStr(ar, "0 && 'x'", s));
    try std.testing.expectEqualStrings("", try evalStr(ar, "null || null", s));
    // short-circuit: the right side would be an error
    try std.testing.expectEqualStrings("ok", try evalStr(ar, "'ok' || nosuchfunction()", s));
}

test "contexts, properties and indexing" {
    var a: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer a.deinit();
    const ar = a.allocator();
    const matrix = [_]Value.Entry{ .{ .key = "os", .value = .{ .string = "linux" } }, .{ .key = "node", .value = .{ .number = 20 } } };
    const list = [_]Value{ .{ .string = "a" }, .{ .string = "b" } };
    const gh = [_]Value.Entry{ .{ .key = "Repository", .value = .{ .string = "o/r" } }, .{ .key = "list", .value = .{ .array = &list } } };
    const ctxs = [_]Value.Entry{ .{ .key = "github", .value = .{ .object = &gh } }, .{ .key = "matrix", .value = .{ .object = &matrix } } };
    const s = tctx(&ctxs);
    try std.testing.expectEqualStrings("o/r", try evalStr(ar, "github.repository", s)); // case-insensitive
    try std.testing.expectEqualStrings("o/r", try evalStr(ar, "GITHUB['REPOSITORY']", s));
    try std.testing.expectEqualStrings("linux", try evalStr(ar, "matrix.os", s));
    try std.testing.expectEqualStrings("20", try evalStr(ar, "matrix['node']", s));
    try std.testing.expectEqualStrings("b", try evalStr(ar, "github.list[1]", s));
    try std.testing.expectEqualStrings("", try evalStr(ar, "github.list[5]", s));
    try std.testing.expectEqualStrings("", try evalStr(ar, "github.missing.deeper.still", s)); // null propagates
    try std.testing.expectEqualStrings("", try evalStr(ar, "nosuchcontext.x", s));
    try std.testing.expect(try evalCondition(ar, "github.repository == 'O/R' && matrix.os == 'linux'", s));
}

test "functions" {
    var a: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer a.deinit();
    const ar = a.allocator();
    const list = [_]Value{ .{ .string = "x" }, .{ .number = 2 }, .{ .boolean = true } };
    const ctxs = [_]Value.Entry{.{ .key = "items", .value = .{ .array = &list } }};
    const s = tctx(&ctxs);
    try std.testing.expect(try evalCondition(ar, "contains('Hello World', 'WORLD')", s));
    try std.testing.expect(!(try evalCondition(ar, "contains('abc', 'z')", s)));
    try std.testing.expect(try evalCondition(ar, "contains(items, 'X')", s));
    try std.testing.expect(try evalCondition(ar, "contains(items, 2)", s));
    try std.testing.expect(try evalCondition(ar, "startsWith('refs/heads/main', 'refs/heads/')", s));
    try std.testing.expect(try evalCondition(ar, "endsWith('file.TXT', '.txt')", s));
    try std.testing.expectEqualStrings("Hello Ada, you are 7", try evalStr(ar, "format('Hello {0}, you are {1}', 'Ada', 7)", s));
    try std.testing.expectEqualStrings("{literal} 1", try evalStr(ar, "format('{{literal}} {0}', 1)", s));
    try std.testing.expectEqualStrings("x,2,true", try evalStr(ar, "join(items)", s));
    try std.testing.expectEqualStrings("x-2-true", try evalStr(ar, "join(items, '-')", s));
    try std.testing.expectEqualStrings("plain", try evalStr(ar, "join('plain', ',')", s));
    try std.testing.expectEqualStrings("[\n  \"x\",\n  2,\n  true\n]", try evalStr(ar, "toJSON(items)", s));
    try std.testing.expectEqualStrings("7", try evalStr(ar, "fromJSON('{\"n\": 7}').n", s));
    try std.testing.expectEqualStrings("b", try evalStr(ar, "fromJSON('[\"a\",\"b\"]')[1]", s));
    try std.testing.expect(try evalCondition(ar, "fromJSON('true')", s));
}

test "status functions and the implicit success()" {
    var a: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer a.deinit();
    const ar = a.allocator();
    const ok: Scope = .{};
    const failed: Scope = .{ .job_failed = true };
    try std.testing.expect(try evalCondition(ar, "success()", ok));
    try std.testing.expect(!(try evalCondition(ar, "success()", failed)));
    try std.testing.expect(try evalCondition(ar, "failure()", failed));
    try std.testing.expect(!(try evalCondition(ar, "failure()", ok)));
    try std.testing.expect(try evalCondition(ar, "always()", failed));
    try std.testing.expect(!(try evalCondition(ar, "cancelled()", ok)));
    // No status function: implicitly success() && (...)
    try std.testing.expect(try evalCondition(ar, "1 == 1", ok));
    try std.testing.expect(!(try evalCondition(ar, "1 == 1", failed)));
    try std.testing.expect(try evalCondition(ar, "always() && 1 == 1", failed));
    try std.testing.expect(try evalCondition(ar, "failure() && 1 == 1", failed));
    // empty condition and ${{ }} wrapper
    try std.testing.expect(try evalCondition(ar, "", ok));
    try std.testing.expect(try evalCondition(ar, "${{ 1 == 1 }}", ok));
    try std.testing.expect(hasStatusFunction(ar, "github.ref == 'x' && !cancelled()"));
    try std.testing.expect(!hasStatusFunction(ar, "github.ref == 'x'"));
}

test "errors say what is wrong" {
    var a: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer a.deinit();
    const ar = a.allocator();
    var diag: []const u8 = "";
    const s: Scope = .{ .diag = &diag };
    try std.testing.expectError(error.ParseError, evaluate(ar, "1 +", s));
    try std.testing.expectError(error.ParseError, evaluate(ar, "'unterminated", s));
    try std.testing.expectError(error.ParseError, evaluate(ar, "(1 == 1", s));
    try std.testing.expect(std.mem.indexOf(u8, diag, "(1 == 1") != null);
    try std.testing.expectError(error.EvalError, evaluate(ar, "nosuch('x')", s));
    try std.testing.expectEqualStrings("unknown function 'nosuch'", diag);
    try std.testing.expectError(error.EvalError, evaluate(ar, "format('{3}', 'a')", s));
    try std.testing.expectError(error.Unsupported, evaluate(ar, "hashFiles('**/*.zig')", s));
    try std.testing.expectEqualStrings("hashFiles() is not supported yet", diag);
    diag = "";
    try std.testing.expectError(error.Unsupported, evaluate(ar, "github.*.x", s));
    try std.testing.expect(std.mem.indexOf(u8, diag, "'*' object filter") != null);
}

test "unsupported contexts fail loudly" {
    var a: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer a.deinit();
    var diag: []const u8 = "";
    const s: Scope = .{ .unsupported_contexts = &.{"secrets"}, .diag = &diag };
    try std.testing.expectError(error.Unsupported, evaluate(a.allocator(), "secrets.TOKEN", s));
    try std.testing.expectEqualStrings("the 'secrets' context is not supported yet", diag);
    try std.testing.expectError(error.Unsupported, evaluate(a.allocator(), "format('{0}', SECRETS['x'])", s));
}

test "numbers print like GitHub" {
    var a: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer a.deinit();
    const ar = a.allocator();
    const s: Scope = .{};
    try std.testing.expectError(error.ParseError, evalStr(ar, "1 + 2", s)); // '+' is not an operator
    try std.testing.expectEqualStrings("1.5", try evalStr(ar, "1.5", s));
    try std.testing.expectEqualStrings("100", try evalStr(ar, "1e2", s));
    try std.testing.expectEqualStrings("NaN", try evalStr(ar, "NaN", s));
}

test "interpolate replaces each ${{ }} and leaves the rest alone" {
    var a: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer a.deinit();
    const ar = a.allocator();
    const inputs = [_]Value.Entry{ .{ .key = "version", .value = .{ .string = "0.21.10" } }, .{ .key = "args", .value = .{ .string = "ci --skip-links\nx" } } };
    const ctxs = [_]Value.Entry{.{ .key = "inputs", .value = .{ .object = &inputs } }};
    var diag: []const u8 = "";
    const s: Scope = .{ .contexts = &ctxs, .diag = &diag };
    try std.testing.expectEqualStrings("plain $HOME {{ x }}", try interpolate(ar, "plain $HOME {{ x }}", s));
    try std.testing.expectEqualStrings("VERSION=0.21.10 and 0.21.10!", try interpolate(ar, "VERSION=${{ inputs.version }} and ${{inputs.VERSION}}!", s));
    // toJSON as dagger-for-github uses it, and a '}}' inside a string literal
    try std.testing.expectEqualStrings("echo '\"ci --skip-links\\nx\"'", try interpolate(ar, "echo '${{ toJSON(inputs.args) }}'", s));
    // The '}}' inside the string does not end the expression (format() then reads it as an escaped '}').
    try std.testing.expectEqualStrings("a}b", try interpolate(ar, "${{ format('{0}}}{1}', 'a', 'b') }}", s));
    try std.testing.expectEqualStrings("it's", try interpolate(ar, "${{ 'it''s' }}", s));
    try std.testing.expectError(error.ParseError, interpolate(ar, "x ${{ inputs.version", s));
    try std.testing.expectEqualStrings("'${{' is never closed with '}}'", diag);
}
