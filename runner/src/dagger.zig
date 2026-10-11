//! Runs a job's steps as one Dagger pipeline by shelling out to `dagger --progress=logs query`
//! (DESIGN §4, SPEC §6).
//!
//! The pipeline is a single GraphQL chain: base image, workspace dir, then one `withExec` per step.
//! Every step is wrapped in a small `sh` script that always exits 0 and brackets its output with
//! marker lines:
//!
//!     <marker>begin N     <marker>end N RC     <marker>skip N
//!
//! The wrapper also implements `if:` (success/always/failure/cancelled) and `continue-on-error`
//! with a flag file, which a chain of plain withExec calls cannot express.
//!
//! Dagger's log frontend prints each span's output in chunks and repeats the span header whenever it
//! switches between spans, so a step's lines can arrive after another step has started. Lines are
//! therefore attributed to the step named in the most recent span header (which contains that
//! step's `begin N` marker text), not to "whatever began last". Output is streamed to the LogSink as
//! it arrives; lines outside any step span are Dagger's progress noise, kept only as a tail for
//! error reporting.
//!
//! The marker is a fixed string, not a per-run nonce: the wrapper text is part of the exec's cache
//! key, so a random value would defeat Dagger's cache. A workflow author can forge markers in their
//! own job's output, but they already control everything that job reports.
const std = @import("std");
const job_mod = @import("job.zig");
const sink = @import("sink.zig");

const Allocator = std.mem.Allocator;

pub const default_image = "ubuntu:24.04";
pub const workspace = "/github/workspace";
const fail_flag = "/tmp/.zig_failed";
pub const marker = "::zig-step::";
/// Every wrapper also appends its marker lines and output here. The file is part of the cached
/// container filesystem, so a fully cached run (which replays no logs) can still be read back.
const report_dir = "/tmp/zig-out";
const report_path = report_dir ++ "/report";

pub const Marker = union(enum) {
    begin: u32,
    end: struct { step: u32, rc: i32 },
    skip: u32,
};

pub const Scan = struct {
    /// Step output that preceded the marker on the same line (output without a trailing newline).
    before: []const u8,
    marker: Marker,
};

/// Finds a marker anywhere in `line`. Returns null for ordinary output.
pub fn scan(line: []const u8) ?Scan {
    const i = std.mem.indexOf(u8, line, marker) orelse return null;
    var it = std.mem.tokenizeScalar(u8, line[i + marker.len ..], ' ');
    const kind = it.next() orelse return null;
    const step = std.fmt.parseInt(u32, it.next() orelse return null, 10) catch return null;
    const m: Marker = if (std.mem.eql(u8, kind, "begin"))
        .{ .begin = step }
    else if (std.mem.eql(u8, kind, "skip"))
        .{ .skip = step }
    else if (std.mem.eql(u8, kind, "end"))
        .{ .end = .{ .step = step, .rc = std.fmt.parseInt(i32, it.next() orelse return null, 10) catch return null } }
    else
        return null;
    return .{ .before = line[0..i], .marker = m };
}

/// Dagger prefixes span headers with a block glyph (U+25xx, e.g. "▼", "▋").
fn isSpanHeader(line: []const u8) bool {
    return line.len >= 4 and line[0] == 0xE2 and line[1] == 0x96;
}

/// A step's wrapper is shown as a multi-line header that ends with a line holding just `'`.
fn headerIsMultiLine(line: []const u8) bool {
    return std.mem.indexOf(u8, line, "withExec sh -c '") != null and !std.mem.endsWith(u8, line, "'");
}

/// Step number from a wrapper source line such as `echo '::zig-step::begin 2'`.
fn headerStep(line: []const u8) ?u32 {
    const i = std.mem.indexOf(u8, line, marker ++ "begin ") orelse return null;
    const rest = line[i + marker.len + "begin ".len ..];
    var n: usize = 0;
    while (n < rest.len and std.ascii.isDigit(rest[n])) n += 1;
    if (n == 0) return null;
    return std.fmt.parseInt(u32, rest[0..n], 10) catch null;
}

fn shellQuote(w: *std.Io.Writer, s: []const u8) !void {
    try w.writeByte('\'');
    for (s) |c| {
        if (c == '\'') try w.writeAll("'\\''") else try w.writeByte(c);
    }
    try w.writeByte('\'');
}

/// Shell test for an `if:` condition, or null when v0 cannot evaluate it.
fn conditionTest(cond: []const u8) ?[]const u8 {
    const c = std.mem.trim(u8, cond, " ");
    if (std.mem.eql(u8, c, "success()")) return "[ ! -e " ++ fail_flag ++ " ]";
    if (std.mem.eql(u8, c, "always()")) return "true";
    if (std.mem.eql(u8, c, "failure()")) return "[ -e " ++ fail_flag ++ " ]";
    if (std.mem.eql(u8, c, "cancelled()")) return "false";
    return null;
}

/// A checkout step after its repository was fetched, or failed to be.
pub const Fetched = struct {
    /// Dagger Directory id of the fetched tree, or why it could not be fetched.
    result: union(enum) { dir: []const u8, failed: []const u8 },
    repo: []const u8,
    /// What was checked out, for the log (a short sha or the requested ref).
    ref_label: []const u8,
    /// Absolute directory inside the container.
    mount: []const u8,
};

/// The `sh -c` script for step number `n` (1-based). `fetched` is set for checkout steps.
pub fn stepWrapper(arena: Allocator, n: u32, step: job_mod.Step, fetched: ?Fetched) ![]const u8 {
    var aw: std.Io.Writer.Allocating = .init(arena);
    const w = &aw.writer;

    const cond = conditionTest(step.condition);
    const bad_condition = if (cond == null)
        try std.fmt.allocPrint(arena, "unsupported condition '{s}' (v0 supports success(), always(), failure(), cancelled())", .{step.condition})
    else
        null;
    const why: ?[]const u8 = switch (step.action) {
        .unsupported => |r| r,
        .script => bad_condition,
        .checkout => if (fetched) |f| switch (f.result) {
            .failed => |msg| msg,
            .dir => bad_condition,
        } else "checkout was not resolved",
    };

    try w.writeAll("mkdir -p " ++ report_dir ++ "\n{\n");

    if (why) |reason| {
        // Fail loudly: the step "runs", prints why it cannot, and fails the job.
        try w.print("echo '{s}begin {d}'\nprintf '%s\\n' ", .{ marker, n });
        try shellQuote(w, reason);
        try w.print("\necho '{s}end {d} 1'\ntouch {s}\n}} 2>&1 | tee -a " ++ report_path ++ "\nexit 0\n", .{ marker, n, fail_flag });
        return aw.written();
    }

    try w.print("if {s}; then\necho '{s}begin {d}'\n", .{ cond.?, marker, n });
    switch (step.action) {
        .script => |sc| {
            try w.writeAll("( ");
            if (sc.working_directory) |wd| {
                try w.writeAll("cd ");
                try shellQuote(w, wd);
                try w.writeAll(" && ");
            }
            if (step.env.len > 0) {
                try w.writeAll("env ");
                for (step.env) |e| {
                    const pair = try std.fmt.allocPrint(arena, "{s}={s}", .{ e.name, e.value });
                    try shellQuote(w, pair);
                    try w.writeByte(' ');
                }
            }
            if (sc.shell != null and std.mem.eql(u8, sc.shell.?, "sh")) {
                try w.writeAll("sh -e -c ");
            } else {
                try w.writeAll("bash --noprofile --norc -e -o pipefail -c ");
            }
            try shellQuote(w, sc.script);
            try w.writeAll(" )\nrc=$?\n");
        },
        .checkout => {
            // The tree was mounted by the chain (`withDirectory`); the step only reports it.
            const f = fetched.?;
            try w.writeAll("printf '%s\\n' ");
            try shellQuote(w, try std.fmt.allocPrint(arena, "Syncing repository: {s}", .{f.repo}));
            try w.writeAll("\nprintf '%s\\n' ");
            try shellQuote(w, try std.fmt.allocPrint(arena, "Checked out {s} into {s} (the runner's built-in checkout replaces actions/checkout)", .{ f.ref_label, f.mount }));
            try w.writeAll("\nrc=0\n");
        },
        .unsupported => unreachable,
    }
    try w.print("echo '{s}end {d} '\"$rc\"\n", .{ marker, n });
    if (!step.continue_on_error) try w.print("[ \"$rc\" -eq 0 ] || touch {s}\n", .{fail_flag});
    try w.print("else\necho '{s}skip {d}'\nfi\n}} 2>&1 | tee -a " ++ report_path ++ "\nexit 0\n", .{ marker, n });
    return aw.written();
}

/// The GraphQL document for `dagger query`.
pub fn buildQuery(arena: Allocator, job: job_mod.Job, image: []const u8, fetched: []const ?Fetched) ![]const u8 {
    var aw: std.Io.Writer.Allocating = .init(arena);
    const w = &aw.writer;
    try w.writeAll("{ container { from(address:");
    try std.json.Stringify.value(image, .{}, w);
    try w.print(") {{ withWorkdir(path:\"{s}\") {{ ", .{workspace});
    var nodes: usize = 0;
    for (job.steps, 1..) |step, n| {
        const f: ?Fetched = if (n <= fetched.len) fetched[n - 1] else null;
        if (f) |fe| switch (fe.result) {
            .dir => |id| {
                // Content-addressed tree: the same commit yields the same workspace, so later
                // steps keep hitting Dagger's cache.
                try w.writeAll("withDirectory(path:");
                try std.json.Stringify.value(fe.mount, .{}, w);
                try w.writeAll(",source:");
                try std.json.Stringify.value(id, .{}, w);
                try w.writeAll(") { ");
                nodes += 1;
            },
            .failed => {},
        };
        const script = try stepWrapper(arena, @intCast(n), step, f);
        try w.writeAll("withExec(args:");
        try std.json.Stringify.value([_][]const u8{ "sh", "-c", script }, .{}, w);
        try w.writeAll(") { ");
        nodes += 1;
    }
    // Reading the report forces the whole chain to run (or be served from cache).
    if (job.steps.len > 0) try w.writeAll("file(path:\"" ++ report_path ++ "\") { contents }") else try w.writeAll("sync");
    for (0..nodes + 4) |_| try w.writeAll(" }");
    return aw.written();
}

pub const Outcome = enum { not_run, success, failure, skipped };

pub const StepResult = struct {
    outcome: Outcome = .not_run,
    exit_code: i32 = 0,
    started_ms: i64 = 0,
    completed_ms: i64 = 0,
};

pub const Result = struct {
    steps: []StepResult,
    /// Set when the engine itself failed (pull error, engine down): the last lines it printed.
    engine_error: ?[]const u8,
    /// False if any step failed without continue-on-error, or the engine failed before running them.
    succeeded: bool,
};

pub const Options = struct {
    /// Full argv of the dagger process; the query is written to its stdin.
    argv: []const []const u8,
    image: []const u8 = default_image,
    /// Key under which output lines are written to the sink.
    sink_job_id: u64 = 0,
    /// Called on every step transition (SPEC §5.2), live or replayed from the report.
    on_step: ?StepHook = null,
};

/// A step transition: after a `begin` marker the result has `started_ms` and outcome `not_run`;
/// after `end` or `skip` it has the final outcome. `now_ms` is when the marker arrived (a skip
/// marker sets no time of its own). Steps are numbered from 1. The hook must not fail the job, so it
/// returns nothing.
pub const StepHook = struct {
    ctx: *anyopaque,
    call: *const fn (ctx: *anyopaque, step: u32, result: StepResult, now_ms: i64) void,
};

// --- checkout ---

fn isSha(s: []const u8) bool {
    if (s.len != 40) return false;
    for (s) |c| if (!std.ascii.isHex(c)) return false;
    return true;
}

/// The `dagger query` document that resolves a checkout to a Directory id, or null with a reason.
pub fn checkoutQuery(arena: Allocator, job: job_mod.Job, co: job_mod.Checkout) !union(enum) { doc: []const u8, err: []const u8 } {
    const repo = co.repository orelse job.github.repository;
    if (repo.len == 0) return .{ .err = "no repository to check out (the job has no github.repository)" };
    const own = co.repository == null or std.mem.eql(u8, repo, job.github.repository);
    const url = try std.fmt.allocPrint(arena, "{s}/{s}.git", .{ std.mem.trimEnd(u8, job.github.server_url, "/"), repo });

    var aw: std.Io.Writer.Allocating = .init(arena);
    const w = &aw.writer;
    try w.writeAll("{ git(url:");
    try std.json.Stringify.value(url, .{}, w);
    try w.writeAll(",keepGitDir:true) { ");
    if (co.ref orelse (if (own and job.github.sha.len > 0) job.github.sha else null)) |ref| {
        if (isSha(ref)) {
            try w.writeAll("commit(id:");
        } else {
            try w.writeAll("ref(name:");
        }
        try std.json.Stringify.value(ref, .{}, w);
        try w.writeAll(")");
    } else {
        try w.writeAll("head");
    }
    if (co.fetch_depth == 0) try w.writeAll(" { tree { id } } } }") else try w.print(" {{ tree(depth:{d}) {{ id }} }} }} }}", .{co.fetch_depth});
    return .{ .doc = aw.written() };
}

const Captured = struct { ok: bool, stdout: []const u8, stderr_tail: []const u8 };

/// Runs one `dagger query`, returning its JSON result and, on failure, the last lines it printed.
fn runCaptured(arena: Allocator, io: std.Io, env: *const std.process.Environ.Map, argv: []const []const u8, doc: []const u8) !Captured {
    var rnd: [8]u8 = undefined;
    io.random(&rnd);
    const out_path = try std.fmt.allocPrint(arena, "/tmp/zig-runner-{x}.json", .{rnd});
    const out_file = try std.Io.Dir.cwd().createFile(io, out_path, .{ .exclusive = true, .permissions = @fromBackingInt(0o600) });
    defer std.Io.Dir.cwd().deleteFile(io, out_path) catch {};

    var child = try std.process.spawn(io, .{ .argv = argv, .environ_map = env, .stdin = .pipe, .stdout = .{ .file = out_file }, .stderr = .pipe });
    out_file.close(io);
    {
        var wbuf: [4096]u8 = undefined;
        var fw = child.stdin.?.writer(io, &wbuf);
        try fw.interface.writeAll(doc);
        try fw.interface.flush();
        child.stdin.?.close(io);
        child.stdin = null;
    }
    var tail: [8][]const u8 = undefined;
    var tail_len: usize = 0;
    var rbuf: [64 * 1024]u8 = undefined;
    var fr = child.stderr.?.readerStreaming(io, &rbuf);
    while (true) {
        const raw = fr.interface.takeDelimiter('\n') catch |e| switch (e) {
            error.StreamTooLong => {
                _ = fr.interface.discardDelimiterInclusive('\n') catch break;
                continue;
            },
            error.ReadFailed => break,
        } orelse break;
        const line = std.mem.trim(u8, raw, " \r");
        // Keep only what the last span printed: that is where git and the engine report the error.
        if (isSpanHeader(line)) {
            tail_len = 0;
            continue;
        }
        if (line.len == 0 or std.mem.indexOf(u8, line, " INF ") != null) continue;
        if (tail_len == tail.len) {
            std.mem.copyForwards([]const u8, tail[0 .. tail.len - 1], tail[1..]);
            tail_len -= 1;
        }
        tail[tail_len] = try arena.dupe(u8, line);
        tail_len += 1;
    }
    const term = try child.wait(io);
    const ok = switch (term) {
        .exited => |c| c == 0,
        else => false,
    };
    const stdout = std.Io.Dir.cwd().readFileAlloc(io, out_path, arena, .limited(16 * 1024 * 1024)) catch "";
    return .{ .ok = ok, .stdout = stdout, .stderr_tail = try std.mem.join(arena, " | ", tail[0..tail_len]) };
}

fn looksLikeAuthFailure(text: []const u8) bool {
    const needles = [_][]const u8{ "not found", "authentication", "Authentication", "denied", "403", "401", "could not read Username" };
    for (needles) |n| if (std.mem.indexOf(u8, text, n) != null) return true;
    return false;
}

fn findKey(v: std.json.Value, key: []const u8) ?[]const u8 {
    if (v != .object) return null;
    var it = v.object.iterator();
    while (it.next()) |e| {
        if (std.mem.eql(u8, e.key_ptr.*, key) and e.value_ptr.* == .string) return e.value_ptr.string;
        if (findKey(e.value_ptr.*, key)) |c| return c;
    }
    return null;
}

/// Fetches the tree of every checkout step. A failure is recorded on that step (it then fails with
/// the reason in its log) instead of aborting the job.
fn resolveCheckouts(arena: Allocator, io: std.Io, base_env: *const std.process.Environ.Map, opts: Options, job: job_mod.Job) ![]?Fetched {
    const out = try arena.alloc(?Fetched, job.steps.len);
    @memset(out, null);
    for (job.steps, out) |step, *slot| {
        if (step.action != .checkout) continue;
        const co = step.action.checkout;
        const repo = co.repository orelse job.github.repository;
        const mount = if (co.path) |pth|
            try std.fmt.allocPrint(arena, "{s}/{s}", .{ workspace, std.mem.trim(u8, pth, "/") })
        else
            workspace;
        const want = co.ref orelse (if (co.repository == null) job.github.sha else "HEAD");
        const label = if (isSha(want)) want[0..7] else want;
        var fetched: Fetched = .{ .result = .{ .failed = "" }, .repo = repo, .ref_label = label, .mount = mount };

        switch (try checkoutQuery(arena, job, co)) {
            .err => |msg| fetched.result = .{ .failed = msg },
            .doc => |doc| {
                // Never prompt for credentials: private repositories are out of scope for v0.
                var env = try base_env.clone(arena);
                try env.put("GIT_TERMINAL_PROMPT", "0");
                const res = try runCaptured(arena, io, &env, opts.argv, doc);
                const parsed = if (res.ok) std.json.parseFromSliceLeaky(std.json.Value, arena, res.stdout, .{}) catch null else null;
                const id: ?[]const u8 = if (parsed) |pv| findKey(pv, "id") else null;
                fetched.result = if (id) |i|
                    .{ .dir = i }
                else
                    .{ .failed = try std.fmt.allocPrint(arena, "could not fetch {s}@{s}: {s}{s}", .{
                        repo,
                        label,
                        if (res.stderr_tail.len > 0) res.stderr_tail else "dagger returned no tree",
                        if (looksLikeAuthFailure(res.stderr_tail)) " (private repositories are not supported in v0)" else "",
                    }) };
            },
        }
        slot.* = fetched;
    }
    return out;
}

/// Splits Dagger's log stream into per-step output. Used for the live stream and for replaying the
/// in-container report, so both go through identical attribution rules.
const Demux = struct {
    io: std.Io,
    arena: Allocator,
    log: *sink.LogSink,
    sink_job_id: u64,
    results: []StepResult,
    /// Steps already reported by the live stream; their lines are dropped while replaying.
    already_done: ?[]const bool = null,
    on_step: ?StepHook = null,

    /// Step whose span header was printed last (Dagger interleaves spans), and header parsing state.
    span_step: ?u32 = null,
    in_header: bool = false,
    tail: [20][]const u8 = undefined,
    tail_len: usize = 0,

    fn notify(d: *Demux, step: u32, now: i64) void {
        if (d.on_step) |h| h.call(h.ctx, step, d.results[step - 1], now);
    }

    fn emit(d: *Demux, step: u32, text: []const u8) !void {
        if (d.already_done) |done| if (step >= 1 and step <= done.len and done[step - 1]) return;
        try d.log.append(d.sink_job_id, step, .stdout, text);
    }

    fn feed(d: *Demux, line: []const u8) !void {
        if (d.in_header) {
            if (std.mem.eql(u8, line, "'")) d.in_header = false else if (headerStep(line)) |n| d.span_step = n;
            return;
        }
        if (isSpanHeader(line)) {
            d.span_step = null;
            d.in_header = headerIsMultiLine(line);
            if (headerStep(line)) |n| d.span_step = n;
            return;
        }

        if (scan(line)) |sc| {
            if (d.span_step) |c| if (sc.before.len > 0) try d.emit(c, sc.before);
            const now = std.Io.Clock.real.now(d.io).toMilliseconds();
            const skipped = struct {
                fn is(done: ?[]const bool, n: u32) bool {
                    return if (done) |dn| (n >= 1 and n <= dn.len and dn[n - 1]) else false;
                }
            }.is;
            switch (sc.marker) {
                .begin => |n| {
                    d.span_step = n;
                    if (n >= 1 and n <= d.results.len and !skipped(d.already_done, n)) {
                        d.results[n - 1].started_ms = now;
                        d.notify(n, now);
                    }
                },
                .skip => |n| {
                    if (n >= 1 and n <= d.results.len and !skipped(d.already_done, n)) {
                        d.results[n - 1].outcome = .skipped;
                        d.notify(n, now);
                    }
                    d.span_step = null;
                },
                .end => |e| {
                    // The step's lines are flushed before its end is announced.
                    try d.log.flush();
                    if (e.step >= 1 and e.step <= d.results.len and !skipped(d.already_done, e.step)) {
                        d.results[e.step - 1].outcome = if (e.rc == 0) .success else .failure;
                        d.results[e.step - 1].exit_code = e.rc;
                        d.results[e.step - 1].completed_ms = now;
                        d.notify(e.step, now);
                    }
                    d.span_step = null;
                },
            }
        } else if (d.span_step) |c| {
            try d.emit(c, line);
        } else if (line.len > 0) {
            // Dagger progress noise outside any step: keep the last few lines for errors.
            if (d.tail_len == d.tail.len) {
                std.mem.copyForwards([]const u8, d.tail[0 .. d.tail.len - 1], d.tail[1..]);
                d.tail_len -= 1;
            }
            d.tail[d.tail_len] = try d.arena.dupe(u8, line);
            d.tail_len += 1;
        }
    }
};

pub fn run(
    arena: Allocator,
    io: std.Io,
    environ: *const std.process.Environ.Map,
    opts: Options,
    job: job_mod.Job,
    log: *sink.LogSink,
) !Result {
    var env = try environ.clone(arena);
    try env.put("NO_COLOR", "1");
    try env.put("DAGGER_NO_NAG", "1");

    const fetched = try resolveCheckouts(arena, io, &env, opts, job);
    const query = try buildQuery(arena, job, opts.image, fetched);

    // The query result (the report) goes to a private temp file: reading stdout and stderr from one
    // thread could deadlock once the report outgrows the pipe buffer.
    var rnd: [8]u8 = undefined;
    io.random(&rnd);
    const out_path = try std.fmt.allocPrint(arena, "/tmp/zig-runner-{x}.json", .{rnd});
    const out_file = try std.Io.Dir.cwd().createFile(io, out_path, .{
        .exclusive = true,
        .permissions = @fromBackingInt(0o600),
    });
    defer std.Io.Dir.cwd().deleteFile(io, out_path) catch {};

    var child = try std.process.spawn(io, .{
        .argv = opts.argv,
        .environ_map = &env,
        .stdin = .pipe,
        .stdout = .{ .file = out_file },
        .stderr = .pipe,
    });
    out_file.close(io);

    {
        var wbuf: [4096]u8 = undefined;
        var fw = child.stdin.?.writer(io, &wbuf);
        try fw.interface.writeAll(query);
        try fw.interface.flush();
        child.stdin.?.close(io);
        child.stdin = null;
    }

    const results = try arena.alloc(StepResult, job.steps.len);
    @memset(results, .{});
    var demux: Demux = .{ .io = io, .arena = arena, .log = log, .sink_job_id = opts.sink_job_id, .results = results, .on_step = opts.on_step };

    var rbuf: [64 * 1024]u8 = undefined;
    var fr = child.stderr.?.readerStreaming(io, &rbuf);
    const r = &fr.interface;

    while (true) {
        const raw = r.takeDelimiter('\n') catch |e| switch (e) {
            error.StreamTooLong => {
                _ = r.discardDelimiterInclusive('\n') catch break;
                continue;
            },
            error.ReadFailed => break,
        } orelse break;
        try demux.feed(std.mem.trimEnd(u8, raw, "\r"));
    }
    try log.flush();
    const term = try child.wait(io);
    const exit_ok = switch (term) {
        .exited => |c| c == 0,
        else => false,
    };

    // A fully cached chain replays no logs. The report inside the container still has everything, so
    // fill in any step the live stream never reported.
    if (exit_ok) {
        var any_missing = false;
        const done = try arena.alloc(bool, results.len);
        for (results, done) |res, *d| {
            d.* = res.outcome != .not_run;
            if (!d.*) any_missing = true;
        }
        if (any_missing) {
            if (try readReport(arena, io, out_path)) |report| {
                demux.already_done = done;
                demux.span_step = null;
                demux.in_header = false;
                var lines = std.mem.splitScalar(u8, report, '\n');
                while (lines.next()) |l| try demux.feed(std.mem.trimEnd(u8, l, "\r"));
                try log.flush();
            }
        }
    }

    var any_failed = false;
    var any_not_run = false;
    for (results, job.steps) |res, step| {
        if (res.outcome == .failure and !step.continue_on_error) any_failed = true;
        if (res.outcome == .not_run) any_not_run = true;
    }
    const engine_error: ?[]const u8 = if (any_not_run and !any_failed)
        try std.mem.join(arena, "\n", demux.tail[0..demux.tail_len])
    else
        null;

    return .{
        .steps = results,
        .engine_error = engine_error,
        .succeeded = !any_failed and engine_error == null,
    };
}

/// Finds the report text (`...{"contents": "<report>"}...`) in the query's JSON result.
fn readReport(arena: Allocator, io: std.Io, path: []const u8) !?[]const u8 {
    const bytes = std.Io.Dir.cwd().readFileAlloc(io, path, arena, .limited(256 * 1024 * 1024)) catch return null;
    const root = std.json.parseFromSliceLeaky(std.json.Value, arena, bytes, .{}) catch return null;
    return findContents(root);
}

fn findContents(v: std.json.Value) ?[]const u8 {
    if (v != .object) return null;
    var it = v.object.iterator();
    while (it.next()) |e| {
        if (std.mem.eql(u8, e.key_ptr.*, "contents") and e.value_ptr.* == .string) return e.value_ptr.string;
        if (findContents(e.value_ptr.*)) |c| return c;
    }
    return null;
}

// --- tests ---

fn testStep(script: []const u8) job_mod.Step {
    return .{ .id = "x", .name = "n", .condition = "success()", .continue_on_error = false, .env = &.{}, .action = .{ .script = .{ .script = script, .shell = null, .working_directory = null } } };
}

test "scan finds markers, with and without leading output" {
    try std.testing.expect(scan("plain output") == null);
    try std.testing.expectEqual(@as(u32, 3), scan(marker ++ "begin 3").?.marker.begin);
    const e = scan("tail without newline" ++ marker ++ "end 2 7").?;
    try std.testing.expectEqualStrings("tail without newline", e.before);
    try std.testing.expectEqual(@as(i32, 7), e.marker.end.rc);
    try std.testing.expectEqual(@as(u32, 5), scan(marker ++ "skip 5").?.marker.skip);
    try std.testing.expect(scan(marker ++ "bogus 1") == null);
    // Wrapper source shown in a span header must not parse as a marker.
    try std.testing.expect(scan("echo '" ++ marker ++ "begin 2'\\''") == null);
    try std.testing.expectEqual(@as(?u32, 2), headerStep("echo '" ++ marker ++ "begin 2'\\''"));
}

test "wrapper quotes scripts and applies condition, env, shell and continue-on-error" {
    var a: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer a.deinit();
    var s = testStep("echo 'hi' && echo $X");
    s.env = &.{.{ .name = "X", .value = "a b" }};
    s.condition = "always()";
    s.continue_on_error = true;
    s.action.script.shell = "sh";
    s.action.script.working_directory = "sub dir";
    const w = try stepWrapper(a.allocator(), 2, s, null);
    try std.testing.expect(std.mem.indexOf(u8, w, "if true; then") != null);
    try std.testing.expect(std.mem.indexOf(u8, w, "cd 'sub dir' && env 'X=a b' sh -e -c 'echo '\\''hi'\\'' && echo $X'") != null);
    try std.testing.expect(std.mem.indexOf(u8, w, "touch") == null); // continue-on-error
    try std.testing.expect(std.mem.indexOf(u8, w, marker ++ "end 2 ") != null);
}

test "unsupported step and condition fail with a message" {
    var a: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer a.deinit();
    var s = testStep("true");
    s.action = .{ .unsupported = "unsupported step reference type 'repository'" };
    const w1 = try stepWrapper(a.allocator(), 1, s, null);
    try std.testing.expect(std.mem.indexOf(u8, w1, "unsupported step reference type") != null);
    try std.testing.expect(std.mem.indexOf(u8, w1, marker ++ "end 1 1") != null);

    var s2 = testStep("true");
    s2.condition = "github.ref == 'refs/heads/main'";
    const w2 = try stepWrapper(a.allocator(), 1, s2, null);
    try std.testing.expect(std.mem.indexOf(u8, w2, "unsupported condition") != null);
}

test "buildQuery is a balanced chain with one withExec per step" {
    var a: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer a.deinit();
    const steps = [_]job_mod.Step{ testStep("echo \"a,b\""), testStep("exit 1") };
    const job: job_mod.Job = .{ .plan_id = "p", .job_id = "j", .job_token = "t", .check_run_id = 1, .has_container = false, .secrets = &.{}, .steps = &steps };
    const q = try buildQuery(a.allocator(), job, "ubuntu:24.04", &.{});
    try std.testing.expectEqual(@as(usize, 2), std.mem.count(u8, q, "withExec("));
    try std.testing.expectEqual(std.mem.count(u8, q, "{"), std.mem.count(u8, q, "}"));
    try std.testing.expect(std.mem.indexOf(u8, q, "echo \\\"a,b\\\"") != null); // JSON-escaped quote
}

test "run streams step output, exit codes and skips from a fake dagger" {
    var a: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer a.deinit();
    const arena = a.allocator();

    var env: std.process.Environ.Map = .init(arena);
    const steps = [_]job_mod.Step{ testStep("a"), testStep("b"), testStep("c") };
    const job: job_mod.Job = .{ .plan_id = "p", .job_id = "j", .job_token = "t", .check_run_id = 1, .has_container = false, .secrets = &.{}, .steps = &steps };

    // Reproduces Dagger's chunked log output: step 2's chunk arrives before step 1's trailing lines,
    // and step 1's span header is printed again before them.
    const fake =
        \\cat >/dev/null
        \\H() { printf '\342\226\274 withExec sh -c '\''if [ ! -e x ]; then\n'; echo "echo '::zig-step::begin $1'\\''"; echo "exit 0"; echo "'"; }
        \\{
        \\echo "noise before"
        \\H 1; echo "::zig-step::begin 1"; echo "hello"
        \\H 2; echo "::zig-step::begin 2"; echo "step two"; echo "::zig-step::end 2 3"
        \\H 1; echo "done"; echo "no newline::zig-step::end 1 0"
        \\H 3; echo "::zig-step::skip 3"
        \\} >&2
    ;
    var buf: [2048]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buf);
    var log: sink.LogSink = .{ .stdout = .{ .writer = &w } };
    const res = try run(arena, std.testing.io, &env, .{ .argv = &.{ "sh", "-c", fake } }, job, &log);

    try std.testing.expectEqual(Outcome.success, res.steps[0].outcome);
    try std.testing.expectEqual(Outcome.failure, res.steps[1].outcome);
    try std.testing.expectEqual(@as(i32, 3), res.steps[1].exit_code);
    try std.testing.expectEqual(Outcome.skipped, res.steps[2].outcome);
    try std.testing.expect(!res.succeeded);
    try std.testing.expect(res.engine_error == null);
    const out = w.buffered();
    try std.testing.expect(std.mem.indexOf(u8, out, "[job 0 step 1 stdout] hello\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "[job 0 step 1 stdout] done\n") != null); // after step 2 began
    try std.testing.expect(std.mem.indexOf(u8, out, "[job 0 step 1 stdout] no newline\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "withExec") == null); // headers never leak into logs
    try std.testing.expect(std.mem.indexOf(u8, out, "[job 0 step 2 stdout] step two\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "noise before") == null);
}

test "run reports engine errors when no step ran" {
    var a: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer a.deinit();
    const arena = a.allocator();
    var env: std.process.Environ.Map = .init(arena);
    const steps = [_]job_mod.Step{testStep("a")};
    const job: job_mod.Job = .{ .plan_id = "p", .job_id = "j", .job_token = "t", .check_run_id = 1, .has_container = false, .secrets = &.{}, .steps = &steps };
    var buf: [256]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buf);
    var log: sink.LogSink = .{ .stdout = .{ .writer = &w } };
    const res = try run(arena, std.testing.io, &env, .{ .argv = &.{ "sh", "-c", "cat >/dev/null; echo 'pull access denied' >&2; exit 1" } }, job, &log);
    try std.testing.expect(!res.succeeded);
    try std.testing.expectEqualStrings("pull access denied", res.engine_error.?);
    try std.testing.expectEqual(Outcome.not_run, res.steps[0].outcome);
}

test "run replays the in-container report when Dagger logged nothing (fully cached chain)" {
    var a: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer a.deinit();
    const arena = a.allocator();
    var env: std.process.Environ.Map = .init(arena);
    const steps = [_]job_mod.Step{ testStep("a"), testStep("b"), testStep("c") };
    const job: job_mod.Job = .{ .plan_id = "p", .job_id = "j", .job_token = "t", .check_run_id = 1, .has_container = false, .secrets = &.{}, .steps = &steps };

    const fake =
        \\cat >/dev/null
        \\printf '%s' '{"container":{"from":{"withWorkdir":{"file":{"contents":"::zig-step::begin 1\nhello\n::zig-step::end 1 0\n::zig-step::begin 2\nboom\n::zig-step::end 2 4\n::zig-step::skip 3\n"}}}}}'
    ;
    var buf: [1024]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buf);
    var log: sink.LogSink = .{ .stdout = .{ .writer = &w } };
    const res = try run(arena, std.testing.io, &env, .{ .argv = &.{ "sh", "-c", fake } }, job, &log);

    try std.testing.expectEqual(Outcome.success, res.steps[0].outcome);
    try std.testing.expectEqual(Outcome.failure, res.steps[1].outcome);
    try std.testing.expectEqual(@as(i32, 4), res.steps[1].exit_code);
    try std.testing.expectEqual(Outcome.skipped, res.steps[2].outcome);
    try std.testing.expect(res.engine_error == null);
    try std.testing.expect(std.mem.indexOf(u8, w.buffered(), "[job 0 step 1 stdout] hello\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, w.buffered(), "[job 0 step 2 stdout] boom\n") != null);
}

test "replay does not duplicate steps already reported live" {
    var a: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer a.deinit();
    const arena = a.allocator();
    var env: std.process.Environ.Map = .init(arena);
    const steps = [_]job_mod.Step{ testStep("a"), testStep("b") };
    const job: job_mod.Job = .{ .plan_id = "p", .job_id = "j", .job_token = "t", .check_run_id = 1, .has_container = false, .secrets = &.{}, .steps = &steps };

    // Step 1 shows up live; step 2 only exists in the report.
    const fake =
        \\q=$(cat)
        \\echo "::zig-step::begin 1" >&2; echo "live" >&2; echo "::zig-step::end 1 0" >&2
        \\printf '%s' '{"x":{"contents":"::zig-step::begin 1\nlive\n::zig-step::end 1 0\n::zig-step::begin 2\nreplayed\n::zig-step::end 2 0\n"}}'
    ;
    var buf: [1024]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buf);
    var log: sink.LogSink = .{ .stdout = .{ .writer = &w } };
    const res = try run(arena, std.testing.io, &env, .{ .argv = &.{ "sh", "-c", fake } }, job, &log);

    try std.testing.expect(res.succeeded);
    try std.testing.expectEqual(@as(usize, 1), std.mem.count(u8, w.buffered(), "live\n"));
    try std.testing.expectEqual(@as(usize, 1), std.mem.count(u8, w.buffered(), "replayed\n"));
}

const HookLog = struct {
    events: [16][]const u8 = undefined,
    n: usize = 0,
    arena: Allocator,

    fn call(ctx: *anyopaque, step: u32, r: StepResult, now_ms: i64) void {
        const h: *HookLog = @ptrCast(@alignCast(ctx));
        std.debug.assert(now_ms > 0);
        h.events[h.n] = std.fmt.allocPrint(h.arena, "{d}:{s}:{s}", .{ step, @tagName(r.outcome), if (r.started_ms > 0) "t" else "-" }) catch unreachable;
        h.n += 1;
    }

    fn hook(h: *HookLog) StepHook {
        return .{ .ctx = h, .call = call };
    }
};

test "on_step announces each transition once, live and replayed" {
    var a: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer a.deinit();
    const arena = a.allocator();
    var env: std.process.Environ.Map = .init(arena);
    const steps = [_]job_mod.Step{ testStep("a"), testStep("b"), testStep("c") };
    const job: job_mod.Job = .{ .plan_id = "p", .job_id = "j", .job_token = "t", .check_run_id = 1, .has_container = false, .secrets = &.{}, .steps = &steps };

    // Step 1 live; steps 2 (failed) and 3 (skipped) only in the report, as for a cached chain.
    const fake =
        \\q=$(cat)
        \\echo "::zig-step::begin 1" >&2; echo "live" >&2; echo "::zig-step::end 1 0" >&2
        \\printf '%s' '{"x":{"contents":"::zig-step::begin 1\nlive\n::zig-step::end 1 0\n::zig-step::begin 2\nboom\n::zig-step::end 2 4\n::zig-step::skip 3\n"}}'
    ;
    var buf: [1024]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buf);
    var log: sink.LogSink = .{ .stdout = .{ .writer = &w } };
    var h: HookLog = .{ .arena = arena };
    _ = try run(arena, std.testing.io, &env, .{ .argv = &.{ "sh", "-c", fake }, .on_step = h.hook() }, job, &log);

    const want = [_][]const u8{ "1:not_run:t", "1:success:t", "2:not_run:t", "2:failure:t", "3:skipped:-" };
    try std.testing.expectEqual(want.len, h.n);
    for (want, h.events[0..h.n]) |e, got| try std.testing.expectEqualStrings(e, got);
}

fn testJob(steps: []const job_mod.Step) job_mod.Job {
    return .{
        .plan_id = "p",
        .job_id = "j",
        .job_token = "t",
        .check_run_id = 1,
        .has_container = false,
        .secrets = &.{},
        .github = .{ .repository = "o/r", .sha = "0123456789012345678901234567890123456789", .ref = "refs/heads/x" },
        .steps = steps,
    };
}

test "checkoutQuery picks commit, ref or head and honours fetch-depth" {
    var a: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer a.deinit();
    const job = testJob(&.{});
    const own = (try checkoutQuery(a.allocator(), job, .{})).doc;
    try std.testing.expectEqualStrings("{ git(url:\"https://github.com/o/r.git\",keepGitDir:true) { commit(id:\"0123456789012345678901234567890123456789\") { tree(depth:1) { id } } } }", own);
    const by_ref = (try checkoutQuery(a.allocator(), job, .{ .ref = "refs/pull/7/merge", .fetch_depth = 0 })).doc;
    try std.testing.expectEqualStrings("{ git(url:\"https://github.com/o/r.git\",keepGitDir:true) { ref(name:\"refs/pull/7/merge\") { tree { id } } } }", by_ref);
    const other = (try checkoutQuery(a.allocator(), job, .{ .repository = "x/y", .fetch_depth = 3 })).doc;
    try std.testing.expect(std.mem.indexOf(u8, other, "x/y.git") != null and std.mem.indexOf(u8, other, "{ head { tree(depth:3)") != null);
    var empty = job;
    empty.github.repository = "";
    try std.testing.expect((try checkoutQuery(a.allocator(), empty, .{})) == .err);
}

test "checkout wrapper reports the checkout and a failed fetch fails the step" {
    var a: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer a.deinit();
    var s = testStep("x");
    s.name = "Run actions/checkout@v4";
    s.action = .{ .checkout = .{} };
    const ok = Fetched{ .result = .{ .dir = "ID" }, .repo = "o/r", .ref_label = "0123456", .mount = "/github/workspace" };
    const w = try stepWrapper(a.allocator(), 1, s, ok);
    try std.testing.expect(std.mem.indexOf(u8, w, "Syncing repository: o/r") != null);
    try std.testing.expect(std.mem.indexOf(u8, w, "Checked out 0123456 into /github/workspace") != null);
    try std.testing.expect(std.mem.indexOf(u8, w, "rc=0") != null);

    const bad = Fetched{ .result = .{ .failed = "could not fetch o/r@abc: denied" }, .repo = "o/r", .ref_label = "abc", .mount = "/github/workspace" };
    const w2 = try stepWrapper(a.allocator(), 1, s, bad);
    try std.testing.expect(std.mem.indexOf(u8, w2, "could not fetch o/r@abc: denied") != null);
    try std.testing.expect(std.mem.indexOf(u8, w2, marker ++ "end 1 1") != null);
}

test "buildQuery mounts the fetched tree before the checkout step and stays balanced" {
    var a: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer a.deinit();
    var co = testStep("x");
    co.name = "Run actions/checkout@v4";
    co.action = .{ .checkout = .{} };
    const steps = [_]job_mod.Step{ co, testStep("ls") };
    const fetched = [_]?Fetched{ .{ .result = .{ .dir = "TREEID" }, .repo = "o/r", .ref_label = "abc", .mount = "/github/workspace/sub" }, null };
    const q = try buildQuery(a.allocator(), testJob(&steps), "ubuntu:24.04", &fetched);
    try std.testing.expect(std.mem.indexOf(u8, q, "withDirectory(path:\"/github/workspace/sub\",source:\"TREEID\")") != null);
    try std.testing.expect(std.mem.indexOf(u8, q, "withDirectory").? < std.mem.indexOf(u8, q, "withExec").?);
    try std.testing.expectEqual(std.mem.count(u8, q, "{"), std.mem.count(u8, q, "}"));
}

test "run fetches checkouts through dagger, mounts them, and fails the step when a fetch fails" {
    var a: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer a.deinit();
    const arena = a.allocator();
    var env: std.process.Environ.Map = .init(arena);
    var co = testStep("x");
    co.name = "Run actions/checkout@v4";
    co.action = .{ .checkout = .{} };
    const steps = [_]job_mod.Step{co};
    const job = testJob(&steps);
    // Fake dagger: git queries return a tree id; chain queries print the checkout step's markers.
    const fake =
        \\q=$(cat)
        \\case "$q" in
        \\  *'git(url'*) [ "$GIT_TERMINAL_PROMPT" = 0 ] || { echo "prompting for credentials is not disabled" >&2; exit 1; }
        \\               printf '%s' '{"git":{"commit":{"tree":{"id":"TREE1"}}}}' ;;
        \\  *) case "$q" in *'source:"TREE1"'*) ;; *) echo "tree not mounted" >&2; exit 1;; esac
        \\     printf '%s\n' '::zig-step::begin 1' 'Syncing repository: o/r' '::zig-step::end 1 0' >&2 ;;
        \\esac
    ;
    var buf: [1024]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buf);
    var log: sink.LogSink = .{ .stdout = .{ .writer = &w } };
    const res = try run(arena, std.testing.io, &env, .{ .argv = &.{ "sh", "-c", fake } }, job, &log);
    try std.testing.expect(res.succeeded);
    try std.testing.expect(std.mem.indexOf(u8, w.buffered(), "Syncing repository: o/r") != null);

    // A failing fetch becomes a failing step with the reason, not a crashed job.
    var buf2: [1024]u8 = undefined;
    var w2: std.Io.Writer = .fixed(&buf2);
    var log2: sink.LogSink = .{ .stdout = .{ .writer = &w2 } };
    const failing =
        \\q=$(cat)
        \\case "$q" in
        \\  *'git(url'*) echo "remote: Repository not found." >&2; exit 1 ;;
        \\  *) case "$q" in
        \\       *'could not fetch o/r@0123456: remote: Repository not found. (private repositories are not supported in v0)'*) m=message-in-step ;;
        \\       *) m=message-missing ;;
        \\     esac
        \\     printf '%s\n' '::zig-step::begin 1' "$m" '::zig-step::end 1 1' >&2 ;;
        \\esac
    ;
    const res2 = try run(arena, std.testing.io, &env, .{ .argv = &.{ "sh", "-c", failing } }, job, &log2);
    try std.testing.expect(!res2.succeeded);
    try std.testing.expect(std.mem.indexOf(u8, w2.buffered(), "message-in-step") != null);
}
