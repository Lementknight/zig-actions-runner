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
    /// `image` is `Dockerfile` (a path in the action's directory) or `docker://<image>`.
    docker: struct {
        image: []const u8,
        /// Replaces the image's entrypoint; null keeps it.
        entrypoint: ?[]const u8 = null,
        /// Null: the image's own command. Items may contain expressions.
        args: ?[]const []const u8 = null,
        env: []const KeyValue = &.{},
        pre_entrypoint: ?[]const u8 = null,
        post_entrypoint: ?[]const u8 = null,
        pre_if: ?[]const u8 = null,
        post_if: ?[]const u8 = null,
    },
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
        error.UnsupportedYaml => return invalid(
            arena,
            "uses YAML this runner does not support ({s}, line {d})",
            .{ diag.message, diag.line },
        ),
        error.InvalidYaml => return invalid(
            arena,
            "is not valid YAML ({s}, line {d})",
            .{ diag.message, diag.line },
        ),
    };
    if (root != .map) return .{ .invalid = "is not a mapping" };

    var m: Metadata = .{ .runs = undefined };
    if (root.get("name")) |n| m.name = n.text() orelse "";
    m.inputs = switch (try parseInputs(arena, root)) {
        .invalid => |why| return .{ .invalid = why },
        .ok => |defs| defs,
    };
    m.outputs = switch (try parseOutputs(arena, root)) {
        .invalid => |why| return .{ .invalid = why },
        .ok => |defs| defs,
    };
    const runs = root.get("runs") orelse return .{ .invalid = "has no 'runs' section" };
    m.runs = switch (try parseRuns(arena, runs)) {
        .invalid => |why| return .{ .invalid = why },
        .ok => |r| r,
    };
    return .{ .ok = m };
}

/// A section's result: what it defines, or why the file cannot be used.
fn Section(comptime T: type) type {
    return union(enum) { ok: T, invalid: []const u8 };
}

/// `inputs:` — each with its default (a string) and whether it is required. Absent or not a mapping
/// means none.
fn parseInputs(arena: Allocator, root: yaml.Node) Allocator.Error!Section([]const InputDef) {
    const ins = root.get("inputs") orelse return .{ .ok = &.{} };
    if (ins != .map) return .{ .ok = &.{} };
    const out = try arena.alloc(InputDef, ins.map.len);
    for (ins.map, out) |e, *o| {
        o.* = .{ .name = e.key };
        if (e.value.get("default")) |d| o.default = scalar(d) orelse
            return .{ .invalid = try std.fmt.allocPrint(
                arena,
                "input '{s}' has a default that is not a string",
                .{e.key},
            ) };
        if (e.value.get("required")) |r| o.required = isTrue(scalar(r) orelse "");
    }
    return .{ .ok = out };
}

/// `outputs:` — the ones with a `value`; JavaScript and Docker actions set outputs themselves and
/// have none.
fn parseOutputs(arena: Allocator, root: yaml.Node) Allocator.Error!Section([]const OutputDef) {
    const outs = root.get("outputs") orelse return .{ .ok = &.{} };
    if (outs != .map) return .{ .ok = &.{} };
    var list: std.ArrayList(OutputDef) = .empty;
    for (outs.map) |e| {
        const v = e.value.get("value") orelse continue;
        const value = scalar(v) orelse
            return .{ .invalid = try std.fmt.allocPrint(
                arena,
                "output '{s}' has a value that is not a string",
                .{e.key},
            ) };
        try list.append(arena, .{ .name = e.key, .value = value });
    }
    return .{ .ok = list.items };
}

/// `runs:` by `using`: a composite action's steps, a JavaScript action's scripts, or a Docker
/// action's image and command.
fn parseRuns(arena: Allocator, runs: yaml.Node) Allocator.Error!Section(Runs) {
    const using_raw = (runs.get("using") orelse
        return .{ .invalid = "has no 'runs.using'" }).text() orelse
        return .{ .invalid = "has no 'runs.using'" };
    const using = try std.ascii.allocLowerString(arena, using_raw);
    if (std.mem.eql(u8, using, "composite")) return compositeRuns(arena, runs);
    if (std.mem.startsWith(u8, using, "node")) return nodeRuns(runs, using);
    if (std.mem.eql(u8, using, "docker")) return dockerRuns(arena, runs);
    return .{ .invalid = try std.fmt.allocPrint(
        arena,
        "has an unknown 'runs.using' value '{s}'",
        .{using_raw},
    ) };
}

fn compositeRuns(arena: Allocator, runs: yaml.Node) Allocator.Error!Section(Runs) {
    const steps_n = runs.get("steps") orelse
        return .{ .invalid = "is a composite action without 'runs.steps'" };
    if (steps_n != .seq) return .{ .invalid = "has 'runs.steps' that is not a list" };
    const steps = try arena.alloc(Step, steps_n.seq.len);
    for (steps_n.seq, steps, 1..) |sn, *st, i| {
        st.* = switch (try compositeStep(arena, sn, i)) {
            .ok => |s| s,
            .invalid => |why| return .{ .invalid = why },
        };
    }
    return .{ .ok = .{ .composite = steps } };
}

fn nodeRuns(runs: yaml.Node, using: []const u8) Section(Runs) {
    const main_n = runs.get("main") orelse
        return .{ .invalid = "is a JavaScript action without 'runs.main'" };
    const main = main_n.text() orelse return .{ .invalid = "has 'runs.main' that is not a string" };
    return .{ .ok = .{ .node = .{
        .using = using,
        .main = main,
        .pre = if (runs.get("pre")) |v| v.text() else null,
        .post = if (runs.get("post")) |v| v.text() else null,
        .pre_if = if (runs.get("pre-if")) |v| v.text() else null,
        .post_if = if (runs.get("post-if")) |v| v.text() else null,
    } } };
}

fn dockerRuns(arena: Allocator, runs: yaml.Node) Allocator.Error!Section(Runs) {
    const image_n = runs.get("image") orelse
        return .{ .invalid = "is a Docker action without 'runs.image'" };
    const image = image_n.text() orelse
        return .{ .invalid = "has 'runs.image' that is not a string" };
    var args: ?[]const []const u8 = null;
    if (runs.get("args")) |an| {
        if (an != .seq) return .{ .invalid = "has 'runs.args' that is not a list" };
        const list = try arena.alloc([]const u8, an.seq.len);
        for (an.seq, list) |item, *dst| dst.* = scalar(item) orelse
            return .{ .invalid = "has 'runs.args' with an item that is not a string" };
        args = list;
    }
    const env = if (runs.get("env")) |en| (try keyValues(arena, en)) orelse
        return .{ .invalid = "has 'runs.env' that is not a mapping of strings" } else &.{};
    return .{ .ok = .{ .docker = .{
        .image = image,
        .entrypoint = if (runs.get("entrypoint")) |v| v.text() else null,
        .args = args,
        .env = env,
        .pre_entrypoint = if (runs.get("pre-entrypoint")) |v| v.text() else null,
        .post_entrypoint = if (runs.get("post-entrypoint")) |v| v.text() else null,
        .pre_if = if (runs.get("pre-if")) |v| v.text() else null,
        .post_if = if (runs.get("post-if")) |v| v.text() else null,
    } } };
}

const StepParsed = union(enum) { ok: Step, invalid: []const u8 };

fn compositeStep(arena: Allocator, n: yaml.Node, index: usize) Allocator.Error!StepParsed {
    if (n != .map) return .{ .invalid = try std.fmt.allocPrint(
        arena,
        "has step {d} that is not a mapping",
        .{index},
    ) };
    var st: Step = .{};
    for (n.map) |e| {
        const k = e.key;
        if (std.mem.eql(u8, k, "with") or std.mem.eql(u8, k, "env")) {
            const kv = (try keyValues(arena, e.value)) orelse
                return .{ .invalid = try std.fmt.allocPrint(
                    arena,
                    "has step {d} whose '{s}' is not a mapping of strings",
                    .{ index, k },
                ) };
            if (std.mem.eql(u8, k, "with")) st.with = kv else st.env = kv;
            continue;
        }
        const v = scalar(e.value) orelse
            return .{ .invalid = try std.fmt.allocPrint(
                arena,
                "has step {d} whose '{s}' is not a string",
                .{ index, k },
            ) };
        if (std.mem.eql(u8, k, "id")) st.id = v //
        else if (std.mem.eql(u8, k, "name")) st.name = v //
        else if (std.mem.eql(u8, k, "if")) st.condition = v //
        else if (std.mem.eql(u8, k, "run")) st.run = v //
        else if (std.mem.eql(u8, k, "shell")) st.shell = v //
        else if (std.mem.eql(u8, k, "uses")) st.uses = v //
        else if (std.mem.eql(u8, k, "working-directory")) st.working_directory = v //
        else if (std.mem.eql(u8, k, "continue-on-error")) st.continue_on_error = v //
        else return .{ .invalid = try std.fmt.allocPrint(
            arena,
            "has step {d} with an unknown key '{s}'",
            .{ index, k },
        ) };
    }
    if ((st.run == null) == (st.uses == null))
        return .{ .invalid = try std.fmt.allocPrint(
            arena,
            "has step {d} that needs exactly one of 'run' and 'uses'",
            .{index},
        ) };
    // GitHub requires an explicit shell for run steps in composite actions.
    if (st.run != null and st.shell == null)
        return .{ .invalid = try std.fmt.allocPrint(
            arena,
            "has step {d} without 'shell' (required for run steps in composite actions)",
            .{index},
        ) };
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
    const prefix_len = owner.len + 1 + name.len;
    const path = if (prefix_len < full.len) full[prefix_len + 1 ..] else "";
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
    try std.testing.expect(docker.runs.docker.args == null);
    const full = (try parse(a.allocator(),
        \\runs:
        \\  using: 'docker'
        \\  image: 'docker://alpine:3.22'
        \\  entrypoint: /bin/echo
        \\  args:
        \\    - ${{ inputs.who }}
        \\    - --flag
        \\  env:
        \\    GREETING: hi
        \\  post-entrypoint: /cleanup.sh
        \\  post-if: failure()
    )).ok.runs.docker;
    try std.testing.expectEqualStrings("docker://alpine:3.22", full.image);
    try std.testing.expectEqualStrings("/bin/echo", full.entrypoint.?);
    try std.testing.expectEqualStrings("${{ inputs.who }}", full.args.?[0]);
    try std.testing.expectEqualStrings("--flag", full.args.?[1]);
    try std.testing.expectEqualStrings("GREETING", full.env[0].name);
    try std.testing.expectEqualStrings("/cleanup.sh", full.post_entrypoint.?);
    try std.testing.expectEqualStrings("failure()", full.post_if.?);
    try std.testing.expect(full.pre_entrypoint == null);
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
        .{ .src = "runs:\n  using: docker\n  image: Dockerfile\n  args: x\n", .want = "'runs.args' that is not a list" },
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
