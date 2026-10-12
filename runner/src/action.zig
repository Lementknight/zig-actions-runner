//! An action's metadata (`action.yml`), and `uses:` references.
//!
//! Values are kept as written, with their `${{ }}` expressions: they are evaluated when the action
//! runs (`expr.interpolate`), in the scope GitHub gives each field.
const std = @import("std");
const yaml = @import("yaml.zig");

const Allocator = std.mem.Allocator;

pub const KeyValue = struct { name: []const u8, value: []const u8 };

pub const InputDef = struct {
    name: []const u8,
    /// May contain expressions (`${{ github.token }}` is common).
    default: ?[]const u8 = null,
    required: bool = false,
};

pub const OutputDef = struct { name: []const u8, value: []const u8 };

/// One step of a composite action.
pub const Step = struct {
    /// Key in the action's own `steps` context.
    id: ?[]const u8 = null,
    name: ?[]const u8 = null,
    /// `if:`; null means `success()`.
    condition: ?[]const u8 = null,
    run: ?[]const u8 = null,
    shell: ?[]const u8 = null,
    uses: ?[]const u8 = null,
    with: []const KeyValue = &.{},
    env: []const KeyValue = &.{},
    working_directory: ?[]const u8 = null,
    continue_on_error: ?[]const u8 = null,
};

pub const Runs = union(enum) {
    composite: []const Step,
    /// `node12` … `node24`: run `main` (and `pre` / `post`) with a JavaScript runtime.
    node: struct {
        using: []const u8,
        main: []const u8,
        pre: ?[]const u8 = null,
        post: ?[]const u8 = null,
        pre_if: ?[]const u8 = null,
        post_if: ?[]const u8 = null,
    },
    docker: struct { image: []const u8 },
};

pub const Metadata = struct {
    name: []const u8 = "",
    inputs: []const InputDef = &.{},
    outputs: []const OutputDef = &.{},
    runs: Runs,

    pub fn input(m: Metadata, name: []const u8) ?InputDef {
        for (m.inputs) |in| if (std.ascii.eqlIgnoreCase(in.name, name)) return in;
        return null;
    }
};

pub const Parsed = union(enum) {
    ok: Metadata,
    /// Why the file cannot be used, for the step's log.
    invalid: []const u8,
};

pub fn parse(arena: Allocator, text: []const u8) Allocator.Error!Parsed {
    var diag: yaml.Diag = .{};
    const root = yaml.parse(arena, text, &diag) catch |e| switch (e) {
        error.OutOfMemory => return error.OutOfMemory,
        error.UnsupportedYaml => return invalid(arena, "uses YAML this runner does not support ({s}, line {d})", .{ diag.message, diag.line }),
        error.InvalidYaml => return invalid(arena, "is not valid YAML ({s}, line {d})", .{ diag.message, diag.line }),
    };
    if (root != .map) return .{ .invalid = "is not a mapping" };

    var m: Metadata = .{ .runs = undefined };
    if (root.get("name")) |n| m.name = n.text() orelse "";

    if (root.get("inputs")) |ins| if (ins == .map) {
        const out = try arena.alloc(InputDef, ins.map.len);
        for (ins.map, out) |e, *o| {
            o.* = .{ .name = e.key };
            if (e.value.get("default")) |d| o.default = scalar(d) orelse return invalid(arena, "input '{s}' has a default that is not a string", .{e.key});
            if (e.value.get("required")) |r| o.required = isTrue(scalar(r) orelse "");
        }
        m.inputs = out;
    };

    if (root.get("outputs")) |outs| if (outs == .map) {
        var list: std.ArrayList(OutputDef) = .empty;
        for (outs.map) |e| {
            // JavaScript and Docker actions set outputs themselves and have no `value`.
            const v = e.value.get("value") orelse continue;
            try list.append(arena, .{ .name = e.key, .value = scalar(v) orelse return invalid(arena, "output '{s}' has a value that is not a string", .{e.key}) });
        }
        m.outputs = list.items;
    };

    const runs = root.get("runs") orelse return .{ .invalid = "has no 'runs' section" };
    const using_raw = (runs.get("using") orelse return .{ .invalid = "has no 'runs.using'" }).text() orelse return .{ .invalid = "has no 'runs.using'" };
    const using = try std.ascii.allocLowerString(arena, using_raw);
    if (std.mem.eql(u8, using, "composite")) {
        const steps_n = runs.get("steps") orelse return .{ .invalid = "is a composite action without 'runs.steps'" };
        if (steps_n != .seq) return .{ .invalid = "has 'runs.steps' that is not a list" };
        const steps = try arena.alloc(Step, steps_n.seq.len);
        for (steps_n.seq, steps, 1..) |sn, *st, i| {
            st.* = switch (try compositeStep(arena, sn, i)) {
                .ok => |s| s,
                .invalid => |why| return .{ .invalid = why },
            };
        }
        m.runs = .{ .composite = steps };
    } else if (std.mem.startsWith(u8, using, "node")) {
        const main = (runs.get("main") orelse return .{ .invalid = "is a JavaScript action without 'runs.main'" }).text() orelse return .{ .invalid = "has 'runs.main' that is not a string" };
        m.runs = .{ .node = .{
            .using = using,
            .main = main,
            .pre = if (runs.get("pre")) |v| v.text() else null,
            .post = if (runs.get("post")) |v| v.text() else null,
            .pre_if = if (runs.get("pre-if")) |v| v.text() else null,
            .post_if = if (runs.get("post-if")) |v| v.text() else null,
        } };
    } else if (std.mem.eql(u8, using, "docker")) {
        const image = (runs.get("image") orelse return .{ .invalid = "is a Docker action without 'runs.image'" }).text() orelse return .{ .invalid = "has 'runs.image' that is not a string" };
        m.runs = .{ .docker = .{ .image = image } };
    } else {
        return invalid(arena, "has an unknown 'runs.using' value '{s}'", .{using_raw});
    }
    return .{ .ok = m };
}

const StepParsed = union(enum) { ok: Step, invalid: []const u8 };

fn compositeStep(arena: Allocator, n: yaml.Node, index: usize) Allocator.Error!StepParsed {
    if (n != .map) return .{ .invalid = try std.fmt.allocPrint(arena, "has step {d} that is not a mapping", .{index}) };
    var st: Step = .{};
    for (n.map) |e| {
        const k = e.key;
        if (std.mem.eql(u8, k, "with") or std.mem.eql(u8, k, "env")) {
            const kv = (try keyValues(arena, e.value)) orelse
                return .{ .invalid = try std.fmt.allocPrint(arena, "has step {d} whose '{s}' is not a mapping of strings", .{ index, k }) };
            if (std.mem.eql(u8, k, "with")) st.with = kv else st.env = kv;
            continue;
        }
        const v = scalar(e.value) orelse
            return .{ .invalid = try std.fmt.allocPrint(arena, "has step {d} whose '{s}' is not a string", .{ index, k }) };
        if (std.mem.eql(u8, k, "id")) st.id = v //
        else if (std.mem.eql(u8, k, "name")) st.name = v //
        else if (std.mem.eql(u8, k, "if")) st.condition = v //
        else if (std.mem.eql(u8, k, "run")) st.run = v //
        else if (std.mem.eql(u8, k, "shell")) st.shell = v //
        else if (std.mem.eql(u8, k, "uses")) st.uses = v //
        else if (std.mem.eql(u8, k, "working-directory")) st.working_directory = v //
        else if (std.mem.eql(u8, k, "continue-on-error")) st.continue_on_error = v //
        else return .{ .invalid = try std.fmt.allocPrint(arena, "has step {d} with an unknown key '{s}'", .{ index, k }) };
    }
    if ((st.run == null) == (st.uses == null))
        return .{ .invalid = try std.fmt.allocPrint(arena, "has step {d} that needs exactly one of 'run' and 'uses'", .{index}) };
    // GitHub requires an explicit shell for run steps in composite actions.
    if (st.run != null and st.shell == null)
        return .{ .invalid = try std.fmt.allocPrint(arena, "has step {d} without 'shell' (required for run steps in composite actions)", .{index}) };
    return .{ .ok = st };
}

fn keyValues(arena: Allocator, n: yaml.Node) Allocator.Error!?[]const KeyValue {
    if (n == .null) return &.{};
    if (n != .map) return null;
    const out = try arena.alloc(KeyValue, n.map.len);
    for (n.map, out) |e, *o| o.* = .{ .name = e.key, .value = scalar(e.value) orelse return null };
    return out;
}

/// A scalar's text; null for collections. A YAML null is the empty string, as GitHub reads it.
fn scalar(n: yaml.Node) ?[]const u8 {
    return switch (n) {
        .string => |s| s,
        .null => "",
        else => null,
    };
}

fn isTrue(s: []const u8) bool {
    return std.ascii.eqlIgnoreCase(s, "true");
}

fn invalid(arena: Allocator, comptime fmt: []const u8, args: anytype) Allocator.Error!Parsed {
    return .{ .invalid = try std.fmt.allocPrint(arena, fmt, args) };
}

// --- uses: references ---

pub const Uses = union(enum) {
    /// `owner/repo[/path]@ref`
    repo: struct { owner: []const u8, name: []const u8, path: []const u8 = "", ref: []const u8 },
    /// `./path` in the workflow's repository.
    local: []const u8,
    /// `docker://image`
    docker: []const u8,
};

/// Parses a `uses:` value; null when it is malformed.
pub fn parseUses(s_in: []const u8) ?Uses {
    const s = std.mem.trim(u8, s_in, " ");
    if (std.mem.startsWith(u8, s, "docker://")) {
        const image = s["docker://".len..];
        return if (image.len > 0) .{ .docker = image } else null;
    }
    if (std.mem.startsWith(u8, s, "./") or std.mem.eql(u8, s, ".")) return .{ .local = s };
    const at = std.mem.lastIndexOfScalar(u8, s, '@') orelse return null;
    const ref = s[at + 1 ..];
    const full = s[0..at];
    if (ref.len == 0) return null;
    var parts = std.mem.splitScalar(u8, full, '/');
    const owner = parts.next() orelse return null;
    const name = parts.next() orelse return null;
    if (owner.len == 0 or name.len == 0) return null;
    const path = if (owner.len + 1 + name.len < full.len) full[owner.len + 1 + name.len + 1 ..] else "";
    if (std.mem.indexOf(u8, path, "..") != null) return null;
    return .{ .repo = .{ .owner = owner, .name = name, .path = path, .ref = ref } };
}

// --- tests ---

test "a composite action: inputs, outputs and steps" {
    var a: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer a.deinit();
    const p = try parse(a.allocator(),
        \\name: "Dagger for GitHub"
        \\inputs:
        \\  version:
        \\    description: "Dagger Version"
        \\    required: false
        \\    default: "latest"
        \\  token:
        \\    default: ${{ github.token }}
        \\  args:
        \\    required: true
        \\  empty-default:
        \\    default:
        \\outputs:
        \\  output:
        \\    value: ${{ steps.exec.outputs.stdout }}
        \\runs:
        \\  using: "Composite"
        \\  steps:
        \\    - shell: bash
        \\      run: echo ${{ inputs.version }}
        \\    - id: exec
        \\      if: steps.should-exec.outputs.result == 'true'
        \\      shell: bash
        \\      env:
        \\        VERB: call
        \\      working-directory: sub
        \\      continue-on-error: true
        \\      run: |
        \\        dagger "$VERB"
        \\    - uses: actions/checkout@v6
        \\      with:
        \\        fetch-depth: 0
    );
    const m = p.ok;
    try std.testing.expectEqualStrings("Dagger for GitHub", m.name);
    try std.testing.expectEqualStrings("latest", m.input("VERSION").?.default.?);
    try std.testing.expectEqualStrings("${{ github.token }}", m.input("token").?.default.?);
    try std.testing.expect(m.input("args").?.required);
    try std.testing.expect(m.input("args").?.default == null);
    try std.testing.expectEqualStrings("", m.input("empty-default").?.default.?);
    try std.testing.expectEqualStrings("${{ steps.exec.outputs.stdout }}", m.outputs[0].value);
    const steps = m.runs.composite;
    try std.testing.expectEqual(@as(usize, 3), steps.len);
    try std.testing.expectEqualStrings("echo ${{ inputs.version }}", steps[0].run.?);
    try std.testing.expectEqualStrings("exec", steps[1].id.?);
    try std.testing.expectEqualStrings("steps.should-exec.outputs.result == 'true'", steps[1].condition.?);
    try std.testing.expectEqualStrings("call", steps[1].env[0].value);
    try std.testing.expectEqualStrings("sub", steps[1].working_directory.?);
    try std.testing.expectEqualStrings("true", steps[1].continue_on_error.?);
    try std.testing.expectEqualStrings("dagger \"$VERB\"\n", steps[1].run.?);
    try std.testing.expectEqualStrings("actions/checkout@v6", steps[2].uses.?);
    try std.testing.expectEqualStrings("0", steps[2].with[0].value);
}

test "JavaScript and Docker actions" {
    var a: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer a.deinit();
    const js = (try parse(a.allocator(),
        \\outputs:
        \\  result:
        \\    description: set by the script
        \\runs:
        \\  using: node24
        \\  main: dist/index.js
        \\  post: dist/index.js
        \\  post-if: success()
    )).ok;
    try std.testing.expectEqualStrings("node24", js.runs.node.using);
    try std.testing.expectEqualStrings("dist/index.js", js.runs.node.main);
    try std.testing.expectEqualStrings("success()", js.runs.node.post_if.?);
    try std.testing.expect(js.runs.node.pre == null);
    try std.testing.expectEqual(@as(usize, 0), js.outputs.len); // no `value`: set by the action
    const docker = (try parse(a.allocator(), "runs:\n  using: docker\n  image: Dockerfile\n")).ok;
    try std.testing.expectEqualStrings("Dockerfile", docker.runs.docker.image);
}

test "invalid metadata says why" {
    var a: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer a.deinit();
    const ar = a.allocator();
    const cases = [_]struct { src: []const u8, want: []const u8 }{
        .{ .src = "name: x\n", .want = "has no 'runs' section" },
        .{ .src = "runs:\n  using: python\n", .want = "unknown 'runs.using' value 'python'" },
        .{ .src = "runs:\n  using: composite\n  steps:\n    - run: echo\n", .want = "step 1 without 'shell'" },
        .{ .src = "runs:\n  using: composite\n  steps:\n    - shell: bash\n", .want = "step 1 that needs exactly one of 'run' and 'uses'" },
        .{ .src = "runs:\n  using: composite\n  steps:\n    - uses: a/b@v1\n      bogus: 1\n", .want = "unknown key 'bogus'" },
        .{ .src = "runs:\n  using: composite\n  steps:\n    - uses: a/b@v1\n      with: [1]\n", .want = "'with' is not a mapping" },
        .{ .src = "runs:\n  using: node20\n", .want = "without 'runs.main'" },
        .{ .src = "a: &x 1\n", .want = "does not support (anchors, aliases and tags, line 1)" },
        .{ .src = "- a\n", .want = "is not a mapping" },
    };
    for (cases) |c| {
        const p = try parse(ar, c.src);
        try std.testing.expect(p == .invalid);
        if (std.mem.indexOf(u8, p.invalid, c.want) == null) {
            std.debug.print("got: {s}\nwant: {s}\n", .{ p.invalid, c.want });
            return error.TestUnexpectedResult;
        }
    }
}

test "parseUses" {
    const r = parseUses("dagger/dagger-for-github@v8.4.1").?.repo;
    try std.testing.expectEqualStrings("dagger", r.owner);
    try std.testing.expectEqualStrings("dagger-for-github", r.name);
    try std.testing.expectEqualStrings("", r.path);
    try std.testing.expectEqualStrings("v8.4.1", r.ref);
    const sub = parseUses("github/codeql-action/init@v3").?.repo;
    try std.testing.expectEqualStrings("init", sub.path);
    const deep = parseUses("o/r/a/b@main").?.repo;
    try std.testing.expectEqualStrings("a/b", deep.path);
    try std.testing.expectEqualStrings("./.github/actions/x", parseUses("./.github/actions/x").?.local);
    try std.testing.expectEqualStrings("alpine:3", parseUses("docker://alpine:3").?.docker);
    try std.testing.expect(parseUses("o/r") == null);
    try std.testing.expect(parseUses("o@v1") == null);
    try std.testing.expect(parseUses("o/r@") == null);
    try std.testing.expect(parseUses("o/r/../x@v1") == null);
}
