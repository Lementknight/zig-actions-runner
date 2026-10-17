//! A backtracking regular expression matcher, for the patterns in GitHub's problem matchers.
//!
//! Problem matchers carry regular expressions (`::add-matcher::`) and Zig's standard library has
//! none. The subset here was not guessed: it is what the matchers shipped by `actions/setup-go` and
//! `actions/setup-node` (eslint-compact, eslint-stylish, tsc) actually use, and those five patterns
//! are the acceptance test at the bottom of this file.
//!
//! Supported: `^` `$`, literals, `.`, the escapes `\s \S \d \D \w \W` and any escaped
//! metacharacter, character classes with ranges, negation and escapes (`[^\s]`, `[\(:]`, `[a-z]`),
//! capturing and non-capturing groups (`(…)`, `(?:…)`), alternation, and the quantifiers `*` `+`
//! `?` `{n}` `{n,}` `{n,m}`, greedy or lazy.
//!
//! **Refused, loudly**: lookaround (`(?=` `(?!` `(?<=` `(?<!`), backreferences, named groups,
//! possessive quantifiers, word boundaries and Unicode categories — each with a reason. A matcher
//! whose pattern is refused goes inert and says so. That is the rule the rest of the runner
//! follows: a construct understood *wrongly* annotates the wrong file and line, which is worse than
//! annotating nothing.
//!
//! Bytes, not codepoints. Log lines are bytes and these patterns are ASCII; `.` matches any byte
//! but a newline, as in .NET without `RegexOptions.Singleline`.
//!
//! **The design is a compiled program and a recursive VM**, after Thompson's construction as Russ
//! Cox describes it: `char`, `class`, `any`, `split`, `jmp`, `save`, `bol`, `eol`, `match`. The
//! first version of this file matched the syntax tree directly and needed a continuation passed
//! through every node to let a group give back what it had taken; it worked for the five patterns
//! and was wrong in general, which is not a trade worth making for a hundred lines. A flat program
//! handles nesting, alternation and captures with no special cases.
//!
//! **There is a step budget.** Backtracking can be made to run for ever by a pattern and an input
//! together (`(a+)+b` against a long run of `a`), and this is handed patterns from actions and
//! lines from builds. Past the budget a match fails with `error.TooComplex` rather than hanging the
//! runner, and the caller makes the matcher inert.

const std = @import("std");
const Allocator = std.mem.Allocator;

pub const Error = error{ BadPattern, Unsupported, TooComplex, OutOfMemory };

/// Instructions executed per `find` before giving up. Generous for the patterns above on a long log
/// line, and small enough to stay imperceptible.
const step_budget: usize = 200_000;

/// Backtracking points held at once. Bounds memory as `step_budget` bounds time: without it a
/// pathological pattern would push an entry per step and reach tens of megabytes before the step
/// budget noticed.
const max_backtrack: usize = 50_000;

/// Instructions a compiled program may hold; `{n,m}` is expanded, so this bounds it.
const max_program: usize = 10_000;

/// One entry of a character class: a byte, a range, or a `\d`-style shorthand.
const ClassItem = union(enum) {
    byte: u8,
    range: struct { lo: u8, hi: u8 },
    shorthand: Shorthand,
};

const Shorthand = struct {
    kind: enum { space, digit, word },
    negated: bool,

    fn matches(s: Shorthand, c: u8) bool {
        const in = switch (s.kind) {
            .space => c == ' ' or c == '\t' or c == '\n' or c == '\r' or c == 0x0b or c == 0x0c,
            .digit => c >= '0' and c <= '9',
            .word => c == '_' or std.ascii.isAlphanumeric(c),
        };
        return in != s.negated;
    }
};

const Class = struct { negated: bool, items: []const ClassItem };

const Inst = union(enum) {
    char: u8,
    any,
    class: Class,
    /// Try `a` first, then `b` from the same position.
    split: struct { a: usize, b: usize },
    jmp: usize,
    /// Record the current position in capture slot `n` (group g uses 2g and 2g+1).
    save: usize,
    /// Record the position at the start of a loop iteration, in slot `n`.
    mark: usize,
    /// End a loop iteration. If it consumed nothing since `mark` wrote `slot`, leave the loop by
    /// jumping to `exit` instead of repeating — but *having run*, so the captures it made stick.
    ///
    /// Both halves came from the differential test. Without the check at all, a loop whose body
    /// matches the empty string (`(x*?)+`, `(a*)*`) repeats for ever: 38 cases hit the step budget
    /// on patterns Python answers. With the check failing the iteration instead of leaving the
    /// loop, `([ab]?)*` reported its group absent where Python reports an empty string, because the
    /// empty iteration's captures were thrown away: 9 more disagreements. Leaving the loop keeps
    /// both the termination and the captures.
    progress: struct { slot: usize, exit: usize },
    bol,
    eol,
    match,
};

/// The syntax tree, kept only until the program is emitted.
const Node = union(enum) {
    char: u8,
    any,
    class: Class,
    /// `index` is the capture number, null for `(?:…)`.
    group: struct { index: ?usize, alts: []const []const Node },
    repeat: struct { node: *const Node, min: u32, max: u32, greedy: bool },
    bol,
    eol,
};

pub const Span = struct {
    start: usize,
    end: usize,

    pub fn of(s: Span, input: []const u8) []const u8 {
        return input[s.start..s.end];
    }
};

/// Where the match and each group landed. A group that took part in no match is null, which is how
/// `(?:(\d+):(\d+):)?` reports an absent line and column.
pub const Captures = struct {
    whole: Span,
    groups: []const ?Span,

    pub fn group(c: Captures, n: usize) ?Span {
        if (n == 0) return c.whole;
        return if (n <= c.groups.len) c.groups[n - 1] else null;
    }

    /// The text of group `n`, or null — what a problem matcher reads for `file`, `line` and so on.
    pub fn text(c: Captures, n: usize, input: []const u8) ?[]const u8 {
        return if (c.group(n)) |s| s.of(input) else null;
    }
};

pub const Regex = struct {
    prog: []const Inst,
    group_count: usize,
    /// Capture slots plus one per loop (see `compileStar`).
    slot_count: usize,

    /// Parses and compiles `pattern`, or says why it cannot.
    pub fn compile(arena: Allocator, pattern: []const u8) Error!Regex {
        var p: Parser = .{ .arena = arena, .src = pattern };
        const alts = try p.parseAlternation(0);
        if (p.i != pattern.len) return error.BadPattern; // an unbalanced ')'

        var c: Compiler = .{ .arena = arena, .loop_slot_base = 2 * (p.groups + 1) };
        // Slot 0 and 1 hold the whole match, so group g gets 2g and 2g+1.
        try c.emit(.{ .save = 0 });
        try c.compileAlts(alts);
        try c.emit(.{ .save = 1 });
        try c.emit(.match);
        return .{ .prog = c.prog.items, .group_count = p.groups, .slot_count = c.loop_slot_base + c.loops };
    }

    /// The leftmost match at or after `from`, as .NET's `Regex.Match` finds it: start offsets are
    /// tried in turn, so an unanchored pattern searches and an anchored one does not.
    pub fn find(re: Regex, arena: Allocator, input: []const u8, from: usize) Error!?Captures {
        const slots = try arena.alloc(?usize, re.slot_count);
        var vm: Vm = .{ .input = input, .prog = re.prog, .slots = slots, .arena = arena };
        var start = from;
        while (start <= input.len) : (start += 1) {
            @memset(slots, null);
            vm.steps = 0;
            if (try vm.run(0, start)) {
                const groups = try arena.alloc(?Span, re.group_count);
                for (groups, 0..) |*g, i| {
                    const s = slots[2 * (i + 1)];
                    const e = slots[2 * (i + 1) + 1];
                    g.* = if (s != null and e != null) .{ .start = s.?, .end = e.? } else null;
                }
                return .{ .whole = .{ .start = slots[0].?, .end = slots[1].? }, .groups = groups };
            }
        }
        return null;
    }
};

// --- parsing ---

const Parser = struct {
    arena: Allocator,
    src: []const u8,
    i: usize = 0,
    groups: usize = 0,

    fn parseAlternation(p: *Parser, depth: usize) Error![]const []const Node {
        if (depth > 32) return error.Unsupported; // bounds the parser's own recursion
        var alts: std.ArrayList([]const Node) = .empty;
        while (true) {
            try alts.append(p.arena, try p.parseSequence(depth));
            if (p.i < p.src.len and p.src[p.i] == '|') {
                p.i += 1;
                continue;
            }
            break;
        }
        return alts.items;
    }

    fn parseSequence(p: *Parser, depth: usize) Error![]const Node {
        var seq: std.ArrayList(Node) = .empty;
        while (p.i < p.src.len and p.src[p.i] != '|' and p.src[p.i] != ')') {
            const atom = try p.parseAtom(depth);
            try seq.append(p.arena, try p.parseQuantifier(atom));
        }
        return seq.items;
    }

    /// A quantifier binds to the atom before it; a trailing `?` makes it lazy.
    fn parseQuantifier(p: *Parser, atom: Node) Error!Node {
        if (p.i >= p.src.len) return atom;
        var min: u32 = 0;
        var max: u32 = std.math.maxInt(u32);
        switch (p.src[p.i]) {
            '*' => p.i += 1,
            '+' => {
                min = 1;
                p.i += 1;
            },
            '?' => {
                max = 1;
                p.i += 1;
            },
            '{' => {
                const close = std.mem.indexOfScalarPos(u8, p.src, p.i, '}') orelse return atom; // a literal '{'
                const body = p.src[p.i + 1 .. close];
                if (body.len == 0) return atom;
                if (std.mem.indexOfScalar(u8, body, ',')) |cm| {
                    min = std.fmt.parseInt(u32, body[0..cm], 10) catch return atom;
                    max = if (cm + 1 == body.len) std.math.maxInt(u32) else std.fmt.parseInt(u32, body[cm + 1 ..], 10) catch return atom;
                } else {
                    min = std.fmt.parseInt(u32, body, 10) catch return atom; // `{a}` is literal
                    max = min;
                }
                if (max < min) return error.BadPattern;
                p.i = close + 1;
            },
            else => return atom,
        }
        var greedy = true;
        if (p.i < p.src.len and p.src[p.i] == '?') {
            greedy = false;
            p.i += 1;
        } else if (p.i < p.src.len and p.src[p.i] == '+') {
            return error.Unsupported; // possessive
        }
        const owned = try p.arena.create(Node);
        owned.* = atom;
        return .{ .repeat = .{ .node = owned, .min = min, .max = max, .greedy = greedy } };
    }

    fn parseAtom(p: *Parser, depth: usize) Error!Node {
        const c = p.src[p.i];
        switch (c) {
            '^' => {
                p.i += 1;
                return .bol;
            },
            '$' => {
                p.i += 1;
                return .eol;
            },
            '.' => {
                p.i += 1;
                return .any;
            },
            '(' => return p.parseGroup(depth),
            '[' => return p.parseClass(),
            '\\' => return p.parseEscape(),
            '*', '+', '?' => return error.BadPattern, // nothing to repeat
            else => {
                p.i += 1;
                return .{ .char = c };
            },
        }
    }

    fn parseGroup(p: *Parser, depth: usize) Error!Node {
        p.i += 1; // '('
        var index: ?usize = null;
        if (p.i < p.src.len and p.src[p.i] == '?') {
            if (p.i + 1 >= p.src.len) return error.BadPattern;
            switch (p.src[p.i + 1]) {
                ':' => p.i += 2,
                // Refused rather than approximated; see the header.
                '=', '!', '<', '\'', 'P', '#' => return error.Unsupported,
                else => return error.Unsupported,
            }
        } else {
            p.groups += 1;
            index = p.groups;
        }
        const alts = try p.parseAlternation(depth + 1);
        if (p.i >= p.src.len or p.src[p.i] != ')') return error.BadPattern;
        p.i += 1;
        return .{ .group = .{ .index = index, .alts = alts } };
    }

    fn parseClass(p: *Parser) Error!Node {
        p.i += 1; // '['
        var negated = false;
        if (p.i < p.src.len and p.src[p.i] == '^') {
            negated = true;
            p.i += 1;
        }
        var items: std.ArrayList(ClassItem) = .empty;
        var first = true; // a ']' first is a literal ']'
        while (p.i < p.src.len and (p.src[p.i] != ']' or first)) {
            first = false;
            const lo: u8 = if (p.src[p.i] == '\\') switch (try p.parseEscape()) {
                .char => |b| b,
                .class => |cl| {
                    // `[^\s]`: a shorthand inside a class contributes its own membership test.
                    if (cl.items.len != 1) return error.Unsupported;
                    try items.append(p.arena, cl.items[0]);
                    continue;
                },
                else => return error.Unsupported,
            } else blk: {
                const b = p.src[p.i];
                p.i += 1;
                break :blk b;
            };
            // A '-' just before ']' is a literal '-'.
            if (p.i + 1 < p.src.len and p.src[p.i] == '-' and p.src[p.i + 1] != ']') {
                p.i += 1;
                const hi: u8 = if (p.src[p.i] == '\\') switch (try p.parseEscape()) {
                    .char => |b| b,
                    else => return error.Unsupported,
                } else blk: {
                    const b = p.src[p.i];
                    p.i += 1;
                    break :blk b;
                };
                if (hi < lo) return error.BadPattern;
                try items.append(p.arena, .{ .range = .{ .lo = lo, .hi = hi } });
            } else {
                try items.append(p.arena, .{ .byte = lo });
            }
        }
        if (p.i >= p.src.len) return error.BadPattern; // no closing ']'
        p.i += 1;
        return .{ .class = .{ .negated = negated, .items = items.items } };
    }

    /// A `\s`-style shorthand becomes a one-item class, so classes can hold them too.
    fn parseEscape(p: *Parser) Error!Node {
        p.i += 1; // '\'
        if (p.i >= p.src.len) return error.BadPattern;
        const c = p.src[p.i];
        p.i += 1;
        const short: ?Shorthand = switch (c) {
            's' => .{ .kind = .space, .negated = false },
            'S' => .{ .kind = .space, .negated = true },
            'd' => .{ .kind = .digit, .negated = false },
            'D' => .{ .kind = .digit, .negated = true },
            'w' => .{ .kind = .word, .negated = false },
            'W' => .{ .kind = .word, .negated = true },
            else => null,
        };
        if (short) |s| {
            const items = try p.arena.alloc(ClassItem, 1);
            items[0] = .{ .shorthand = s };
            return .{ .class = .{ .negated = false, .items = items } };
        }
        return switch (c) {
            'n' => .{ .char = '\n' },
            'r' => .{ .char = '\r' },
            't' => .{ .char = '\t' },
            'f' => .{ .char = 0x0c },
            'v' => .{ .char = 0x0b },
            '0' => .{ .char = 0 },
            '1'...'9' => error.Unsupported, // a backreference
            'b', 'B', 'A', 'Z', 'z', 'G' => error.Unsupported, // boundaries
            'p', 'P' => error.Unsupported, // Unicode categories
            'k' => error.Unsupported, // a named backreference
            else => .{ .char = c }, // `\.`, `\(`, `\\`, and the rest
        };
    }
};

// --- compiling ---

const Compiler = struct {
    arena: Allocator,
    prog: std.ArrayList(Inst) = .empty,
    /// Where loop slots start: after the capture slots, which are 2 per group plus 2 for the whole.
    loop_slot_base: usize,
    loops: usize = 0,

    fn emit(c: *Compiler, in: Inst) Error!void {
        if (c.prog.items.len >= max_program) return error.Unsupported; // an expansion too large
        try c.prog.append(c.arena, in);
    }

    fn here(c: *Compiler) usize {
        return c.prog.items.len;
    }

    fn compileAlts(c: *Compiler, alts: []const []const Node) Error!void {
        if (alts.len == 1) return c.compileSeq(alts[0]);
        // split to each alternative in turn; each one jumps to the end when it matches.
        var jumps: std.ArrayList(usize) = .empty;
        for (alts, 0..) |alt, i| {
            const last = i + 1 == alts.len;
            var split_at: usize = 0;
            if (!last) {
                split_at = c.here();
                try c.emit(.{ .split = .{ .a = 0, .b = 0 } });
                c.prog.items[split_at] = .{ .split = .{ .a = c.here(), .b = 0 } };
            }
            try c.compileSeq(alt);
            if (!last) {
                try jumps.append(c.arena, c.here());
                try c.emit(.{ .jmp = 0 });
                c.prog.items[split_at].split.b = c.here();
            }
        }
        for (jumps.items) |j| c.prog.items[j] = .{ .jmp = c.here() };
    }

    fn compileSeq(c: *Compiler, seq: []const Node) Error!void {
        for (seq) |n| try c.compileNode(n);
    }

    fn compileNode(c: *Compiler, n: Node) Error!void {
        switch (n) {
            .char => |b| try c.emit(.{ .char = b }),
            .any => try c.emit(.any),
            .class => |cl| try c.emit(.{ .class = cl }),
            .bol => try c.emit(.bol),
            .eol => try c.emit(.eol),
            .group => |g| {
                if (g.index) |gi| try c.emit(.{ .save = 2 * gi });
                try c.compileAlts(g.alts);
                if (g.index) |gi| try c.emit(.{ .save = 2 * gi + 1 });
            },
            .repeat => |r| try c.compileRepeat(r.node.*, r.min, r.max, r.greedy),
        }
    }

    /// `{n,m}` is expanded: n copies, then (m-n) optional ones, or a star for an open end. The
    /// program bound in `max_program` is what keeps `a{1,10000}` from compiling.
    fn compileRepeat(c: *Compiler, n: Node, min: u32, max: u32, greedy: bool) Error!void {
        for (0..min) |_| try c.compileNode(n);
        if (max == std.math.maxInt(u32)) {
            if (min == 0) return c.compileStar(n, greedy);
            // `x+` is `x` already emitted, then a star of the same node.
            return c.compileStar(n, greedy);
        }
        // Every optional copy's "skip" branch leaves the whole repeat, so copy i+1 is reachable
        // only by having taken copy i. Pointing a skip at the *next* copy instead — which is what
        // this did first — adds a path a real loop does not have ("skip the first, take the
        // second") and explores the counts in the wrong order. The grammar generator found it:
        // `(a|.b){0,2}?$` on "ab" captured "ab" where Python and Perl both capture "b", because a
        // lazy repeat must try one whole iteration and then another, not re-enter the first
        // iteration's alternatives before considering a second iteration.
        var skips: std.ArrayList(usize) = .empty;
        var guards: std.ArrayList(usize) = .empty;
        for (min..max) |_| {
            const split_at = c.here();
            try c.emit(.{ .split = .{ .a = 0, .b = 0 } });
            try skips.append(c.arena, split_at);
            // The empty-iteration rule applies to a bounded repeat as well, not only to a star:
            // an iteration that consumes nothing ends the repetition. Found by the grammar
            // generator — `(\s{0,2}|…){0,2}` matched an empty iteration and then a long one,
            // capturing the long one, where Python and Perl both stop after the empty iteration
            // and so capture what a *second non-empty* iteration took. The mandatory copies below
            // `min` are deliberately not guarded: `(a?){2}` does match the empty string twice.
            const slot = c.loop_slot_base + c.loops;
            c.loops += 1;
            try c.emit(.{ .mark = slot });
            try c.compileNode(n);
            try guards.append(c.arena, c.here());
            try c.emit(.{ .progress = .{ .slot = slot, .exit = 0 } });
        }
        const after = c.here();
        for (skips.items) |split_at| {
            c.prog.items[split_at] = if (greedy)
                .{ .split = .{ .a = split_at + 1, .b = after } }
            else
                .{ .split = .{ .a = after, .b = split_at + 1 } };
        }
        for (guards.items) |g| c.prog.items[g].progress.exit = after;
    }

    fn compileStar(c: *Compiler, n: Node, greedy: bool) Error!void {
        // Each loop gets a slot to remember where its current iteration began, so an iteration that
        // consumes nothing ends the loop instead of repeating. The slot lives past the capture
        // slots and is undone on backtracking like any other.
        const slot = c.loop_slot_base + c.loops;
        c.loops += 1;
        const split_at = c.here();
        try c.emit(.{ .split = .{ .a = 0, .b = 0 } });
        try c.emit(.{ .mark = slot });
        try c.compileNode(n);
        const progress_at = c.here();
        try c.emit(.{ .progress = .{ .slot = slot, .exit = 0 } });
        try c.emit(.{ .jmp = split_at });
        const after = c.here();
        c.prog.items[progress_at].progress.exit = after;
        c.prog.items[split_at] = if (greedy)
            .{ .split = .{ .a = split_at + 1, .b = after } }
        else
            .{ .split = .{ .a = after, .b = split_at + 1 } };
    }
};

// --- matching ---

/// A backtracking point: where to resume, and how far to undo the capture trail first.
const Backtrack = struct { pc: usize, pos: usize, trail: usize };

/// What a `save` overwrote, so backtracking can put it back.
const Undo = struct { slot: usize, old: ?usize };

/// **Iterative on purpose.** The first version recursed, one frame per instruction, and the
/// differential test crashed it: a step budget of a million is meaningless when a step is a stack
/// frame. Depth is also O(input length) for `.*` over a long line, so capping depth would reject
/// legitimate matches on long log lines — and the runner matches inside `std.Io` tasks, whose
/// stacks are smaller than main's. So the backtracking points live on the heap, and captures are
/// undone from a trail rather than by returning through frames.
const Vm = struct {
    input: []const u8,
    prog: []const Inst,
    slots: []?usize,
    arena: Allocator,
    stack: std.ArrayList(Backtrack) = .empty,
    trail: std.ArrayList(Undo) = .empty,
    steps: usize = 0,

    fn run(vm: *Vm, start_pc: usize, start_pos: usize) Error!bool {
        vm.stack.clearRetainingCapacity();
        vm.trail.clearRetainingCapacity();
        var pc = start_pc;
        var pos = start_pos;
        while (true) {
            vm.steps += 1;
            if (vm.steps > step_budget) return error.TooComplex;
            const advance: ?struct { pc: usize, pos: usize } = switch (vm.prog[pc]) {
                .match => return true,
                .char => |b| if (pos < vm.input.len and vm.input[pos] == b) .{ .pc = pc + 1, .pos = pos + 1 } else null,
                .any => if (pos < vm.input.len and vm.input[pos] != '\n') .{ .pc = pc + 1, .pos = pos + 1 } else null,
                .class => |cl| if (pos < vm.input.len and classMatches(cl, vm.input[pos])) .{ .pc = pc + 1, .pos = pos + 1 } else null,
                .bol => if (pos == 0) .{ .pc = pc + 1, .pos = pos } else null,
                .eol => if (pos == vm.input.len) .{ .pc = pc + 1, .pos = pos } else null,
                .jmp => |t| .{ .pc = t, .pos = pos },
                .split => |s| blk: {
                    if (vm.stack.items.len >= max_backtrack) return error.TooComplex;
                    try vm.stack.append(vm.arena, .{ .pc = s.b, .pos = pos, .trail = vm.trail.items.len });
                    break :blk .{ .pc = s.a, .pos = pos };
                },
                .mark => |slot| blk: {
                    try vm.trail.append(vm.arena, .{ .slot = slot, .old = vm.slots[slot] });
                    vm.slots[slot] = pos;
                    break :blk .{ .pc = pc + 1, .pos = pos };
                },
                .progress => |g| blk: {
                    const stalled = if (vm.slots[g.slot]) |was| pos == was else false;
                    break :blk .{ .pc = if (stalled) g.exit else pc + 1, .pos = pos };
                },
                .save => |slot| blk: {
                    try vm.trail.append(vm.arena, .{ .slot = slot, .old = vm.slots[slot] });
                    vm.slots[slot] = pos;
                    break :blk .{ .pc = pc + 1, .pos = pos };
                },
            };
            if (advance) |a| {
                pc = a.pc;
                pos = a.pos;
                continue;
            }
            // This path failed: take the most recent alternative, undoing the captures made since.
            const b = vm.stack.pop() orelse return false;
            while (vm.trail.items.len > b.trail) {
                const u = vm.trail.pop().?;
                vm.slots[u.slot] = u.old;
            }
            pc = b.pc;
            pos = b.pos;
        }
    }
};

fn classMatches(cl: Class, c: u8) bool {
    var in = false;
    for (cl.items) |it| {
        in = switch (it) {
            .byte => |b| c == b,
            .range => |r| c >= r.lo and c <= r.hi,
            .shorthand => |s| s.matches(c),
        };
        if (in) break;
    }
    return in != cl.negated;
}

// --- tests ---

const testing = std.testing;

/// Compiles, matches, and returns the groups as text: null where the group took no part.
fn caps(arena: Allocator, pattern: []const u8, input: []const u8) !?[]const ?[]const u8 {
    const re = try Regex.compile(arena, pattern);
    const m = try re.find(arena, input, 0) orelse return null;
    const out = try arena.alloc(?[]const u8, re.group_count);
    for (out, 0..) |*o, i| o.* = m.text(i + 1, input);
    return out;
}

fn expectGroups(arena: Allocator, pattern: []const u8, input: []const u8, want: []const ?[]const u8) !void {
    const got = (try caps(arena, pattern, input)) orelse return error.NoMatch;
    try testing.expectEqual(want.len, got.len);
    for (want, got) |w, g| {
        if (w == null) {
            try testing.expect(g == null);
        } else {
            try testing.expect(g != null);
            try testing.expectEqualStrings(w.?, g.?);
        }
    }
}

test "the five problem-matcher patterns real actions ship" {
    var a: std.heap.ArenaAllocator = .init(testing.allocator);
    defer a.deinit();
    const ar = a.allocator();

    // actions/setup-go. The optional non-capturing group carries line and column, so a message
    // without them leaves both groups absent — the case that made a `?Span` necessary.
    const go = "^\\s*(.+\\.go):(?:(\\d+):(\\d+):)? (.*)";
    try expectGroups(ar, go, "  main.go:9:2: undefined: foo", &.{ "main.go", "9", "2", "undefined: foo" });
    try expectGroups(ar, go, "pkg/a.go: build failed", &.{ "pkg/a.go", null, null, "build failed" });

    // actions/setup-node, eslint-compact: alternation of case variants, and an escaped paren.
    const compact = "^(.+):\\sline\\s(\\d+),\\scol\\s(\\d+),\\s([Ee]rror|[Ww]arning|[Ii]nfo)\\s-\\s(.+)\\s\\((.+)\\)$";
    try expectGroups(
        ar,
        compact,
        "src/a.js: line 3, col 10, Error - Missing semicolon (semi)",
        &.{ "src/a.js", "3", "10", "Error", "Missing semicolon", "semi" },
    );

    // eslint-stylish, both patterns of a two-pattern matcher.
    try expectGroups(ar, "^\\s*([^\\s].*)$", "  src/b.js", &.{"src/b.js"});
    try expectGroups(
        ar,
        "^\\s+(\\d+):(\\d+)\\s+(error|warning|info)\\s+(.*)\\s\\s+(.*)$",
        "  12:34  error  Unexpected console statement  no-console",
        &.{ "12", "34", "error", "Unexpected console statement", "no-console" },
    );

    // tsc: a class of escaped and plain characters, and alternation of two multi-character arms.
    const tsc = "^([^\\s].*)[\\(:](\\d+)[,:](\\d+)(?:\\):\\s+|\\s+-\\s+)(error|warning|info)\\s+TS(\\d+)\\s*:\\s*(.*)$";
    try expectGroups(
        ar,
        tsc,
        "src/c.ts(5,9): error TS2304: Cannot find name 'x'.",
        &.{ "src/c.ts", "5", "9", "error", "2304", "Cannot find name 'x'." },
    );
    try expectGroups(
        ar,
        tsc,
        "src/c.ts:5:9 - error TS2304: Cannot find name 'x'.",
        &.{ "src/c.ts", "5", "9", "error", "2304", "Cannot find name 'x'." },
    );
}

test "anchors, classes, quantifiers and laziness" {
    var a: std.heap.ArenaAllocator = .init(testing.allocator);
    defer a.deinit();
    const ar = a.allocator();

    // An unanchored pattern searches; an anchored one does not.
    try testing.expect((try caps(ar, "b+", "aabbb")) != null);
    try testing.expect((try caps(ar, "^b+", "aabbb")) == null);
    try testing.expect((try caps(ar, "c$", "abc")) != null);

    // Greedy takes as much as it can; lazy as little.
    try expectGroups(ar, "<(.+)>", "<a><b>", &.{"a><b"});
    try expectGroups(ar, "<(.+?)>", "<a><b>", &.{"a"});

    // Counted repetition, open-ended and bounded.
    try expectGroups(ar, "^(a{2,3})b", "aaab", &.{"aaa"});
    try testing.expect((try caps(ar, "^a{4}b", "aaab")) == null);
    try expectGroups(ar, "^(a{2,})$", "aaaa", &.{"aaaa"});

    // Classes: ranges, negation, a literal ']' first, a trailing '-', escapes inside.
    try expectGroups(ar, "([a-f0-9]+)", "zz9afz", &.{"9af"});
    try expectGroups(ar, "([^0-9]+)", "12ab34", &.{"ab"});
    try expectGroups(ar, "([]x]+)", "a]x]b", &.{"]x]"});
    try expectGroups(ar, "([a-]+)", "-a-", &.{"-a-"});
    try expectGroups(ar, "([\\(:]+)", "x(:y", &.{"(:"});

    // `.` stops at a newline, as in .NET without Singleline.
    try testing.expect((try caps(ar, "^a.b$", "a\nb")) == null);

    // An alternative that matches nothing still lets a later one match.
    try expectGroups(ar, "^(x|y|z)$", "y", &.{"y"});
}

test "unsupported constructs are refused, not approximated" {
    var a: std.heap.ArenaAllocator = .init(testing.allocator);
    defer a.deinit();
    const ar = a.allocator();
    for ([_][]const u8{
        "(?=foo)", // lookahead
        "(?!foo)", // negative lookahead
        "(?<=foo)", // lookbehind
        "(?<name>x)", // a named group
        "(a)\\1", // a backreference
        "\\bword\\b", // word boundaries
        "\\p{L}+", // a Unicode category
        "a++", // possessive
    }) |pattern| {
        try testing.expectError(error.Unsupported, Regex.compile(ar, pattern));
    }
    // And malformed patterns are told apart from unsupported ones.
    for ([_][]const u8{ "(unclosed", "[unclosed", "a)", "*nothing", "a{3,2}" }) |pattern| {
        try testing.expectError(error.BadPattern, Regex.compile(ar, pattern));
    }
}

test "a pathological pattern gives up instead of hanging" {
    var a: std.heap.ArenaAllocator = .init(testing.allocator);
    defer a.deinit();
    const ar = a.allocator();
    // The classic: every split of a long run of 'a' is tried before 'b' fails.
    const re = try Regex.compile(ar, "^(a+)+b$");
    try testing.expectError(error.TooComplex, re.find(ar, "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa", 0));
}
