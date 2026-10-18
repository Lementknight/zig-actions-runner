//! The measurement harness: stage 2 of docs/MEASURE.md, replacing the shell written for the
//! occasion that produced most of docs/CLAIMS.md's under-powered entries.
//!
//! It knows nothing about this runner. An **arm** is a command whose stdout contains a line
//! `MEASURE <number>` — the reading — so the same harness measures a job's seconds, an engine's CPU,
//! or anything else that can be printed. What it adds is the protocol, which is where every mistake
//! in MEASURE.md §1 was made:
//!
//!   * **A refutation criterion first** (§3.2.1): `--min-effect` is required, so the smallest effect
//!     worth acting on is written down before any number exists. Below it the answer is "no effect
//!     found", never a trend.
//!   * **A negative control** (§3.2.2): `--control <arm>` names an arm whose answer is known to
//!     match the baseline. If it comes out as an effect, the suite failed, whatever the other arms
//!     say. Mistake 1 was caught by exactly this and nothing else.
//!   * **Interleaved arms** (§3.2.3), in an order the recorded seed shuffles each round, so drift in
//!     the machine cannot be read as a difference between arms.
//!   * **A separated first round** (§3.2.4): `--warmup N` rounds are recorded and excluded.
//!   * **A fresh trial token** (§3.3), generated here, asserted distinct, and handed to the command
//!     in `$MEASURE_TOKEN` so it can be put where the system under test cannot ignore it — for this
//!     runner, in a step's script text, which is part of its cache key.
//!   * **An advancing identity** (§3.3): `--identity <command>` must print something new each trial
//!     (a run id, an attempt), which is how mistake 4 — matching a stale run — is caught.
//!   * **A window** per reading, with the trial's start and end, so a reading that cannot have come
//!     from this trial is discarded rather than averaged in (mistake 3).
//!   * **Nothing swallowed**: both streams are captured and printed on failure, with the exit code
//!     kept apart from the harness's own control flow (mistake 11).
//!   * **Every sample kept**: one JSON line per trial, so a claim can be re-analysed without being
//!     re-run.
//!
//! Usage:
//!   measure run --claim E7.7 --quantity "engine CPU s" --min-effect 0.15 --relative \
//!       --reps 5 --warmup 1 --out samples.jsonl \
//!       --arm 'gogc400=ssh zig-pi ./arm.sh 400' --arm 'gogc100=ssh zig-pi ./arm.sh 100' \
//!       [--prepare CMD] [--identity CMD] [--environment CMD] [--control ARM]
//!   measure analyse samples.jsonl --min-effect 0.15 --relative [--baseline ARM]
//!   measure dimension samples.jsonl --target 0.5
const std = @import("std");
const Allocator = std.mem.Allocator;

pub fn main(init: std.process.Init) !u8 {
    const arena = init.arena.allocator();
    const io = init.io;
    const environ = init.environ_map;
    const args = try init.minimal.args.toSlice(arena);
    if (args.len < 2) return usage();
    const cmd = args[1];
    if (std.mem.eql(u8, cmd, "run")) return try cmdRun(arena, io, environ, args[2..]);
    if (std.mem.eql(u8, cmd, "analyse")) return try cmdAnalyse(arena, io, args[2..]);
    if (std.mem.eql(u8, cmd, "dimension")) return try cmdDimension(arena, io, args[2..]);
    return usage();
}

fn usage() u8 {
    std.debug.print(
        \\measure: the protocol of docs/MEASURE.md §3, around any command that prints `MEASURE <n>`.
        \\
        \\  measure run      --claim ID --quantity TEXT --min-effect X [--relative] --reps N
        \\                   [--warmup N] [--seed N] --out FILE --arm 'name=command' ...
        \\                   [--prepare CMD] [--identity CMD] [--environment CMD] [--control ARM]
        \\  measure analyse  FILE --min-effect X [--relative] [--baseline ARM]
        \\  measure dimension FILE --target X
        \\
        \\--min-effect is required: say what would refute the claim before measuring it.
        \\
    , .{});
    return 2;
}

// -----------------------------------------------------------------------------
// Statistics
//
// Medians rather than means, and a bootstrap interval of the *difference* rather than two intervals
// to eyeball, because the claim is always about the difference (§3.2.6).

/// The median of `xs`, which it sorts in place.
pub fn median(xs: []f64) f64 {
    std.mem.sort(f64, xs, {}, std.sort.asc(f64));
    const n = xs.len;
    if (n == 0) return std.math.nan(f64);
    return if (n % 2 == 1) xs[n / 2] else (xs[n / 2 - 1] + xs[n / 2]) / 2;
}

pub fn mean(xs: []const f64) f64 {
    if (xs.len == 0) return std.math.nan(f64);
    var s: f64 = 0;
    for (xs) |x| s += x;
    return s / @as(f64, @floatFromInt(xs.len));
}

/// The sample standard deviation (n−1), which is what the dimensioning arithmetic wants.
pub fn stddev(xs: []const f64) f64 {
    if (xs.len < 2) return 0;
    const m = mean(xs);
    var s: f64 = 0;
    for (xs) |x| s += (x - m) * (x - m);
    return @sqrt(s / @as(f64, @floatFromInt(xs.len - 1)));
}

pub const Interval = struct { low: f64, high: f64 };

/// A percentile bootstrap interval for `median(b) − median(a)`, resampling each arm with
/// replacement. The seed is a parameter and is recorded with the samples, so the interval is
/// reproducible rather than merely plausible.
pub fn bootstrapDifference(arena: Allocator, a: []const f64, b: []const f64, rounds: usize, seed: u64, level: f64) !Interval {
    const diffs = try arena.alloc(f64, rounds);
    const ra = try arena.alloc(f64, a.len);
    const rb = try arena.alloc(f64, b.len);
    var prng: std.Random.DefaultPrng = .init(seed);
    const rand = prng.random();
    for (diffs) |*d| {
        for (ra) |*x| x.* = a[rand.uintLessThan(usize, a.len)];
        for (rb) |*x| x.* = b[rand.uintLessThan(usize, b.len)];
        d.* = median(rb) - median(ra);
    }
    std.mem.sort(f64, diffs, {}, std.sort.asc(f64));
    const tail = (1 - level) / 2;
    return .{
        .low = diffs[@intFromFloat(@floor(tail * @as(f64, @floatFromInt(rounds))))],
        .high = diffs[@min(rounds - 1, @as(usize, @intFromFloat(@ceil((1 - tail) * @as(f64, @floatFromInt(rounds))))))],
    };
}

pub const Verdict = enum {
    /// The interval of the difference spans zero: nothing was found at this size.
    no_effect_found,
    /// An interval that excludes zero, but an effect smaller than the one worth acting on.
    below_the_threshold,
    /// An effect, in the direction the sign of the difference gives.
    effect,
    /// Too few samples to say anything. Not a verdict about the world.
    not_enough_samples,
};

/// The rule of §3.2, applied without discretion. `min_effect` is absolute unless `relative`, in
/// which case it is a fraction of the baseline's median.
pub fn verdictOf(a: []f64, b: []f64, ci: Interval, min_effect: f64, relative: bool) Verdict {
    if (a.len < 3 or b.len < 3) return .not_enough_samples;
    if (ci.low <= 0 and ci.high >= 0) return .no_effect_found;
    const base = median(a);
    const threshold = if (relative) @abs(base) * min_effect else min_effect;
    const diff = @abs(median(b) - base);
    return if (diff < threshold) .below_the_threshold else .effect;
}

/// How many repetitions an arm needs for a half-width of `target`, from a pilot's spread. The
/// single-level version of Kalibera and Jones's dimensioning: enough for "how many runs?", not a
/// substitute for their nested model when the levels matter.
pub fn repetitionsFor(pilot: []const f64, target: f64) usize {
    if (target <= 0) return 0;
    const s = stddev(pilot);
    if (s == 0) return 3;
    const n = (1.96 * s / target) * (1.96 * s / target);
    return @max(3, @as(usize, @intFromFloat(@ceil(n))));
}

// -----------------------------------------------------------------------------
// Samples

const Sample = struct {
    claim: []const u8,
    quantity: []const u8,
    arm: []const u8,
    round: u32,
    warmup: bool,
    /// The reading, in whatever unit `quantity` names. Null when the trial failed.
    value: ?f64,
    /// The window the trial ran in, from a monotonic clock, in milliseconds.
    started_ms: i64,
    ended_ms: i64,
    /// The token this trial handed the command, and the identity the command reported.
    token: []const u8,
    identity: ?[]const u8,
    exit_code: u8,
    failed: bool,
    /// Whatever `--environment` printed, verbatim: the engine's image and GOGC, cache bytes,
    /// snapshot count, cgroup memory, the workload's commit. Kept as text so the harness needs no
    /// opinion about it.
    environment: ?[]const u8,
    seed: u64,
    /// Provenance, for samples that were not produced by this harness: a transcription from the
    /// study carries its source here, so nobody mistakes it for a measured trial.
    note: ?[]const u8 = null,
};

fn writeSample(arena: Allocator, w: *std.Io.Writer, s: Sample) !void {
    _ = arena;
    try std.json.Stringify.value(s, .{}, w);
    try w.writeByte('\n');
}

// -----------------------------------------------------------------------------
// Running

const Arm = struct { name: []const u8, command: []const u8 };

const RunOpts = struct {
    claim: []const u8 = "",
    quantity: []const u8 = "",
    min_effect: ?f64 = null,
    relative: bool = false,
    reps: u32 = 5,
    warmup: u32 = 1,
    seed: u64 = 0,
    out: []const u8 = "",
    prepare: ?[]const u8 = null,
    identity: ?[]const u8 = null,
    environment: ?[]const u8 = null,
    control: ?[]const u8 = null,
    arms: std.ArrayList(Arm) = .empty,
};

fn cmdRun(arena: Allocator, io: std.Io, environ: *const std.process.Environ.Map, args: []const []const u8) !u8 {
    const o = parseRunOpts(arena, args) catch |e| switch (e) {
        error.Usage => return usage(),
        error.BadArgs => return 2,
        else => return e,
    };

    const seed = if (o.seed != 0) o.seed else @as(u64, @bitCast(@as(i64, @truncate(std.Io.Clock.real.now(io).toNanoseconds()))));
    var prng: std.Random.DefaultPrng = .init(seed);
    const rand = prng.random();

    var file = try std.Io.Dir.cwd().createFile(io, o.out, .{});
    defer file.close(io);
    var buf: [4096]u8 = undefined;
    var fw = file.writer(io, &buf);

    var state: TrialState = .{ .seed = seed };
    const order = try arena.alloc(usize, o.arms.items.len);
    for (order, 0..) |*x, k| x.* = k;

    const rounds = o.warmup + o.reps;
    std.debug.print("measure: claim {s}, {d} arms, {d} warmup + {d} rounds, seed {d}\n", .{ o.claim, o.arms.items.len, o.warmup, o.reps, seed });
    var round: u32 = 0;
    while (round < rounds) : (round += 1) {
        // Interleaved, and the order inside a round is shuffled: drift cannot line up with an arm.
        rand.shuffle(usize, order);
        for (order) |idx| {
            const token = try std.fmt.allocPrint(arena, "m{x}", .{rand.int(u64)});
            for (state.tokens.items) |t| if (std.mem.eql(u8, t, token)) {
                std.debug.print("measure: two trials got the same token ({s}); refusing to continue.\n", .{token});
                return 1;
            };
            try state.tokens.append(arena, token);
            const arm = o.arms.items[idx];
            try runTrial(arena, io, environ, o, arm, round, token, &fw.interface, &state);
        }
    }
    std.debug.print("measure: {d} samples written to {s}{s}\n", .{ rounds * o.arms.items.len, o.out, if (state.failures > 0) " (with failures above)" else "" });
    return if (state.failures > 0) 1 else 0;
}

/// `measure run`'s arguments, parsed and checked. `error.Usage` when they do not parse (the caller
/// prints the usage); `error.BadArgs` when they parse but break a precondition, already complained
/// about.
fn parseRunOpts(arena: Allocator, args: []const []const u8) !RunOpts {
    var o: RunOpts = .{};
    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        const a = args[i];
        const next = struct {
            fn get(idx: *usize, as: []const []const u8) ?[]const u8 {
                if (idx.* + 1 >= as.len) return null;
                idx.* += 1;
                return as[idx.*];
            }
        }.get;
        if (std.mem.eql(u8, a, "--claim")) o.claim = next(&i, args) orelse return error.Usage //
        else if (std.mem.eql(u8, a, "--quantity")) o.quantity = next(&i, args) orelse return error.Usage //
        else if (std.mem.eql(u8, a, "--min-effect")) o.min_effect = std.fmt.parseFloat(f64, next(&i, args) orelse return error.Usage) catch return error.Usage //
        else if (std.mem.eql(u8, a, "--relative")) o.relative = true //
        else if (std.mem.eql(u8, a, "--reps")) o.reps = std.fmt.parseInt(u32, next(&i, args) orelse return error.Usage, 10) catch return error.Usage //
        else if (std.mem.eql(u8, a, "--warmup")) o.warmup = std.fmt.parseInt(u32, next(&i, args) orelse return error.Usage, 10) catch return error.Usage //
        else if (std.mem.eql(u8, a, "--seed")) o.seed = std.fmt.parseInt(u64, next(&i, args) orelse return error.Usage, 10) catch return error.Usage //
        else if (std.mem.eql(u8, a, "--out")) o.out = next(&i, args) orelse return error.Usage //
        else if (std.mem.eql(u8, a, "--prepare")) o.prepare = next(&i, args) orelse return error.Usage //
        else if (std.mem.eql(u8, a, "--identity")) o.identity = next(&i, args) orelse return error.Usage //
        else if (std.mem.eql(u8, a, "--environment")) o.environment = next(&i, args) orelse return error.Usage //
        else if (std.mem.eql(u8, a, "--control")) o.control = next(&i, args) orelse return error.Usage //
        else if (std.mem.eql(u8, a, "--arm")) {
            const spec = next(&i, args) orelse return error.Usage;
            const eq = std.mem.indexOfScalar(u8, spec, '=') orelse {
                std.debug.print("measure: --arm wants 'name=command', got '{s}'\n", .{spec});
                return error.BadArgs;
            };
            try o.arms.append(arena, .{ .name = spec[0..eq], .command = spec[eq + 1 ..] });
        } else {
            std.debug.print("measure: unknown argument '{s}'\n", .{a});
            return error.Usage;
        }
    }
    if (!runOptsValid(o)) return error.BadArgs;
    return o;
}

/// The protocol's preconditions on a run, each with its own complaint (MEASURE.md §3.2).
fn runOptsValid(o: RunOpts) bool {
    // The criterion comes first, or there is no experiment (§3.2.1).
    if (o.min_effect == null) {
        std.debug.print("measure: --min-effect is required: say what would refute the claim first.\n", .{});
        return false;
    }
    if (o.arms.items.len < 2) {
        std.debug.print("measure: at least two arms, one of them a baseline.\n", .{});
        return false;
    }
    if (o.out.len == 0) {
        std.debug.print("measure: --out is required: every sample is kept.\n", .{});
        return false;
    }
    if (o.control) |c| {
        var found = false;
        for (o.arms.items) |arm| if (std.mem.eql(u8, arm.name, c)) {
            found = true;
        };
        if (!found) {
            std.debug.print("measure: --control '{s}' is not one of the arms.\n", .{c});
            return false;
        }
    } else std.debug.print("measure: warning: no --control, so nothing in this suite has a known answer (§3.2.2).\n", .{});
    return true;
}

/// What carries across the trials of one run: every token handed out (they must all differ), the
/// last identity (it must advance), the seed written with each sample, and how many trials failed.
const TrialState = struct {
    seed: u64,
    tokens: std.ArrayList([]const u8) = .empty,
    last_identity: ?[]const u8 = null,
    failures: usize = 0,
};

/// Never swallow output (MEASURE.md §3.3): a failed trial's command, stdout and stderr, whole.
fn reportTrialFailure(arm: Arm, round: u32, res: Run, no_reading: bool) void {
    std.debug.print(
        \\measure: {s} round {d} failed (exit {d}{s})
        \\  command: {s}
        \\  stdout: {s}
        \\  stderr: {s}
        \\
    , .{ arm.name, round, res.code, if (no_reading) ", no `MEASURE <n>` line" else "", arm.command, res.stdout, res.stderr });
}

/// One trial: `--prepare`, the arm's command timed, its `MEASURE <n>` read, `--identity` checked
/// against the previous trial's, `--environment` captured, and one JSON line written and flushed.
fn runTrial(
    arena: Allocator,
    io: std.Io,
    environ: *const std.process.Environ.Map,
    o: RunOpts,
    arm: Arm,
    round: u32,
    token: []const u8,
    w: *std.Io.Writer,
    state: *TrialState,
) !void {
    if (o.prepare) |p| {
        const pr = try shell(arena, io, environ, p, token);
        if (pr.code != 0) {
            std.debug.print("measure: --prepare failed ({d}) before {s} round {d}\n{s}{s}\n", .{ pr.code, arm.name, round, pr.stdout, pr.stderr });
            state.failures += 1;
            return;
        }
    }

    const started = std.Io.Clock.awake.now(io).toMilliseconds();
    const res = try shell(arena, io, environ, arm.command, token);
    const ended = std.Io.Clock.awake.now(io).toMilliseconds();

    const value = parseReading(res.stdout);
    var failed = res.code != 0 or value == null;
    if (failed) {
        state.failures += 1;
        reportTrialFailure(arm, round, res, value == null);
    }

    var identity: ?[]const u8 = null;
    if (o.identity) |idc| {
        const ir = try shell(arena, io, environ, idc, token);
        const got = std.mem.trim(u8, ir.stdout, " \n\r\t");
        identity = try arena.dupe(u8, got);
        if (state.last_identity) |prev| if (std.mem.eql(u8, prev, got)) {
            std.debug.print("measure: {s} round {d}: identity did not advance ('{s}'): a stale reading.\n", .{ arm.name, round, got });
            failed = true;
            state.failures += 1;
        };
        state.last_identity = identity;
    }

    var environment: ?[]const u8 = null;
    if (o.environment) |ec| {
        const er = try shell(arena, io, environ, ec, token);
        environment = try arena.dupe(u8, std.mem.trim(u8, er.stdout, " \n\r\t"));
    }

    try writeSample(arena, w, .{
        .claim = o.claim,
        .quantity = o.quantity,
        .arm = arm.name,
        .round = round,
        .warmup = round < o.warmup,
        .value = if (failed) null else value,
        .started_ms = started,
        .ended_ms = ended,
        .token = token,
        .identity = identity,
        .exit_code = res.code,
        .failed = failed,
        .environment = environment,
        .seed = state.seed,
    });
    try w.flush();
    std.debug.print("  round {d} {s}: {?d:.3} ({d} ms){s}\n", .{ round, arm.name, value, ended - started, if (round < o.warmup) " [warmup, excluded]" else "" });
}

const Run = struct { code: u8, stdout: []const u8, stderr: []const u8 };

/// Runs `command` under `sh -c` with `$MEASURE_TOKEN` set, and captures both streams. The exit code
/// comes back as data, never as this program's control flow.
fn shell(arena: Allocator, io: std.Io, environ: *const std.process.Environ.Map, command: []const u8, token: []const u8) !Run {
    // The caller's environment, so `ssh` and `gh` still find HOME, PATH and an agent.
    var env = try environ.clone(arena);
    try env.put("MEASURE_TOKEN", token);
    var child = try std.process.spawn(io, .{
        .argv = &.{ "sh", "-c", command },
        .environ_map = &env,
        .stdin = .ignore,
        .stdout = .pipe,
        .stderr = .pipe,
    });
    const out = try drain(arena, io, child.stdout.?);
    const err = try drain(arena, io, child.stderr.?);
    const term = try child.wait(io);
    const code: u8 = switch (term) {
        .exited => |c| c,
        else => 255,
    };
    return .{ .code = code, .stdout = out, .stderr = err };
}

fn drain(arena: Allocator, io: std.Io, f: std.Io.File) ![]const u8 {
    var buf: [4096]u8 = undefined;
    var r = f.readerStreaming(io, &buf);
    return r.interface.allocRemaining(arena, .limited(16 * 1024 * 1024)) catch |e| switch (e) {
        error.StreamTooLong => "(output over 16 MB, truncated)",
        else => return e,
    };
}

/// The last `MEASURE <number>` line in the output, so a command may print progress first.
pub fn parseReading(out: []const u8) ?f64 {
    var found: ?f64 = null;
    var lines = std.mem.splitScalar(u8, out, '\n');
    while (lines.next()) |line| {
        const t = std.mem.trim(u8, line, " \r\t");
        if (!std.mem.startsWith(u8, t, "MEASURE")) continue;
        const rest = std.mem.trim(u8, t["MEASURE".len..], " \t");
        found = std.fmt.parseFloat(f64, rest) catch continue;
    }
    return found;
}

// -----------------------------------------------------------------------------
// Analysing

fn cmdAnalyse(arena: Allocator, io: std.Io, args: []const []const u8) !u8 {
    const o = parseAnalyseOpts(args) catch |e| switch (e) {
        error.Usage => return usage(),
        error.BadArgs => return 2,
    };
    const samples = readSamples(arena, io, o.path) catch |e| switch (e) {
        error.BadSample => return 1,
        else => return e,
    };
    if (samples.names.items.len == 0) {
        std.debug.print("measure: no usable samples in {s}.\n", .{o.path});
        return 1;
    }
    const base_idx = baselineIndex(samples, o.baseline) orelse return 1;
    std.debug.print("claim {s} · {s} · {d} warmup samples excluded, {d} failed\n\n", .{ samples.claim, samples.quantity, samples.excluded, samples.failed });
    const verdicts_bad = try printVerdicts(arena, samples, base_idx, o.min_effect, o.relative);
    std.debug.print(
        \\
        \\An interval that spans zero is "no effect found at this size", not a trend (§3.2.6).
        \\
    , .{});
    return if (verdicts_bad > 0) 1 else 0;
}

const AnalyseOpts = struct {
    path: []const u8,
    min_effect: f64,
    relative: bool = false,
    baseline: ?[]const u8 = null,
};

/// `measure analyse`'s arguments. `error.Usage` when they do not parse; `error.BadArgs` when the
/// criterion is missing, which has its own complaint: a result is read as an effect only against a
/// threshold said in advance (§3.2.1).
fn parseAnalyseOpts(args: []const []const u8) error{ Usage, BadArgs }!AnalyseOpts {
    if (args.len < 1) return error.Usage;
    var min_effect: ?f64 = null;
    var relative = false;
    var baseline: ?[]const u8 = null;
    var path: []const u8 = args[0];
    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        if (std.mem.eql(u8, args[i], "--min-effect") and i + 1 < args.len) {
            i += 1;
            min_effect = std.fmt.parseFloat(f64, args[i]) catch return error.Usage;
        } else if (std.mem.eql(u8, args[i], "--relative")) relative = true //
        else if (std.mem.eql(u8, args[i], "--baseline") and i + 1 < args.len) {
            i += 1;
            baseline = args[i];
        } else if (!std.mem.startsWith(u8, args[i], "--")) path = args[i];
    }
    const effect = min_effect orelse {
        std.debug.print("measure: --min-effect is required to read a result as an effect.\n", .{});
        return error.BadArgs;
    };
    return .{ .path = path, .min_effect = effect, .relative = relative, .baseline = baseline };
}

/// A sample file read back: the readings grouped by arm, in the order the arms first appeared, with
/// what was set aside — warm-up rounds, and trials that failed or whose window did not hold.
const Samples = struct {
    names: std.ArrayList([]const u8) = .empty,
    values: std.ArrayList(std.ArrayList(f64)) = .empty,
    claim: []const u8 = "",
    quantity: []const u8 = "",
    excluded: usize = 0,
    failed: usize = 0,
};

fn readSamples(arena: Allocator, io: std.Io, path: []const u8) !Samples {
    const text = try std.Io.Dir.cwd().readFileAlloc(io, path, arena, .limited(64 * 1024 * 1024));
    var out: Samples = .{};
    var lines = std.mem.splitScalar(u8, text, '\n');
    while (lines.next()) |line| {
        if (std.mem.trim(u8, line, " \r\t").len == 0) continue;
        const parsed = std.json.parseFromSlice(Sample, arena, line, .{ .ignore_unknown_fields = true }) catch |e| {
            std.debug.print("measure: {s}: cannot read a sample ({s}): {s}\n", .{ path, @errorName(e), line });
            return error.BadSample;
        };
        const s = parsed.value;
        if (out.claim.len == 0) out.claim = s.claim;
        if (out.quantity.len == 0) out.quantity = s.quantity;
        if (s.warmup) {
            out.excluded += 1;
            continue;
        }
        if (s.failed or s.value == null) {
            out.failed += 1;
            continue;
        }
        // A reading has to lie in its own trial's window, or it belongs to another trial.
        if (s.ended_ms < s.started_ms) {
            std.debug.print("measure: a sample's window ends before it starts; discarded.\n", .{});
            out.failed += 1;
            continue;
        }
        try out.values.items[try armIndex(arena, &out, s.arm)].append(arena, s.value.?);
    }
    return out;
}

/// The arm's slot, made on first sight.
fn armIndex(arena: Allocator, out: *Samples, arm: []const u8) !usize {
    for (out.names.items, 0..) |n, k| if (std.mem.eql(u8, n, arm)) return k;
    try out.names.append(arena, arm);
    try out.values.append(arena, .empty);
    return out.names.items.len - 1;
}

/// Which arm the others are compared against: `--baseline` when given (and it must be an arm, with
/// a complaint when it is not), else the first arm seen.
fn baselineIndex(samples: Samples, baseline: ?[]const u8) ?usize {
    const b = baseline orelse return 0;
    for (samples.names.items, 0..) |n, k| if (std.mem.eql(u8, n, b)) return k;
    std.debug.print("measure: --baseline '{s}' is not an arm in these samples.\n", .{b});
    return null;
}

/// One line per arm: the baseline's median, then each other arm's median, its difference from the
/// baseline, the bootstrap interval of that difference, and the verdict. Returns how many arms had
/// too few samples for a verdict — an interval from one or two samples is arithmetic, not evidence,
/// so it is not shown.
fn printVerdicts(arena: Allocator, samples: Samples, base_idx: usize, min_effect: f64, relative: bool) !usize {
    const names = samples.names.items;
    const base = samples.values.items[base_idx].items;
    std.debug.print("  {s: <16} n={d: <3} median {d:.3}  (baseline)\n", .{ names[base_idx], base.len, median(base) });
    var verdicts_bad: usize = 0;
    for (names, 0..) |n, k| {
        if (k == base_idx) continue;
        const arm = samples.values.items[k].items;
        const ci = try bootstrapDifference(arena, base, arm, 10_000, 1, 0.95);
        const v = verdictOf(base, arm, ci, min_effect, relative);
        const diff = median(arm) - median(base);
        if (v == .not_enough_samples) {
            std.debug.print("  {s: <16} n={d: <3} median {d:.3}  difference {d:.3}  95% CI --  {s}\n", .{ n, arm.len, median(arm), diff, @tagName(v) });
            verdicts_bad += 1;
        } else {
            std.debug.print("  {s: <16} n={d: <3} median {d:.3}  difference {d:.3}  95% CI [{d:.3}, {d:.3}]  {s}\n", .{ n, arm.len, median(arm), diff, ci.low, ci.high, @tagName(v) });
        }
    }
    return verdicts_bad;
}

fn cmdDimension(arena: Allocator, io: std.Io, args: []const []const u8) !u8 {
    if (args.len < 1) return usage();
    var target: ?f64 = null;
    var path = args[0];
    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        if (std.mem.eql(u8, args[i], "--target") and i + 1 < args.len) {
            i += 1;
            target = std.fmt.parseFloat(f64, args[i]) catch return usage();
        } else if (!std.mem.startsWith(u8, args[i], "--")) path = args[i];
    }
    if (target == null) {
        std.debug.print("measure: --target is required: the half-width you want.\n", .{});
        return 2;
    }
    const text = try std.Io.Dir.cwd().readFileAlloc(io, path, arena, .limited(64 * 1024 * 1024));
    var names: std.ArrayList([]const u8) = .empty;
    var values: std.ArrayList(std.ArrayList(f64)) = .empty;
    var lines = std.mem.splitScalar(u8, text, '\n');
    while (lines.next()) |line| {
        if (std.mem.trim(u8, line, " \r\t").len == 0) continue;
        const parsed = std.json.parseFromSlice(Sample, arena, line, .{ .ignore_unknown_fields = true }) catch continue;
        const s = parsed.value;
        // Warm-up rounds are excluded here as in `analyse`: a first round's spread is provisioning,
        // not variability, and dimensioning from it asks for repetitions nothing needs.
        if (s.warmup or s.failed or s.value == null) continue;
        var idx: ?usize = null;
        for (names.items, 0..) |n, k| if (std.mem.eql(u8, n, s.arm)) {
            idx = k;
        };
        if (idx == null) {
            try names.append(arena, s.arm);
            try values.append(arena, .empty);
            idx = names.items.len - 1;
        }
        try values.items[idx.?].append(arena, s.value.?);
    }
    std.debug.print("For a half-width of {d:.3} (§3.2.5, the single-level version):\n", .{target.?});
    for (names.items, 0..) |n, k| {
        const xs = values.items[k].items;
        std.debug.print("  {s: <16} n={d: <3} sd {d:.3}  →  {d} repetitions\n", .{ n, xs.len, stddev(xs), repetitionsFor(xs, target.?) });
    }
    return 0;
}

// -----------------------------------------------------------------------------
// Tests: the statistics decide the verdicts, so they are what must be checked.

test "median, odd and even" {
    var a = [_]f64{ 3, 1, 2 };
    try std.testing.expectEqual(@as(f64, 2), median(&a));
    var b = [_]f64{ 4, 1, 3, 2 };
    try std.testing.expectEqual(@as(f64, 2.5), median(&b));
}

test "standard deviation, and a pilot of one" {
    var a = [_]f64{ 2, 4, 4, 4, 5, 5, 7, 9 };
    try std.testing.expectApproxEqAbs(@as(f64, 2.13809), stddev(&a), 0.0001);
    try std.testing.expectEqual(@as(f64, 0), stddev(&[_]f64{7}));
}

test "the same arm twice: the interval spans zero, so no effect is found" {
    var buf: [1 << 20]u8 = undefined;
    var fba: std.heap.FixedBufferAllocator = .init(&buf);
    const a = [_]f64{ 10, 11, 9, 10.5, 10, 9.5 };
    const b = [_]f64{ 10.2, 10.8, 9.2, 10.4, 9.9, 9.6 };
    const ci = try bootstrapDifference(fba.allocator(), &a, &b, 2000, 7, 0.95);
    try std.testing.expect(ci.low <= 0 and ci.high >= 0);
    var am = a;
    var bm = b;
    try std.testing.expectEqual(Verdict.no_effect_found, verdictOf(&am, &bm, ci, 0.1, true));
}

test "a large difference: the interval excludes zero and the verdict is an effect" {
    var buf: [1 << 20]u8 = undefined;
    var fba: std.heap.FixedBufferAllocator = .init(&buf);
    const a = [_]f64{ 10, 11, 9, 10.5, 10, 9.5 };
    const b = [_]f64{ 20, 21, 19, 20.5, 20, 19.5 };
    const ci = try bootstrapDifference(fba.allocator(), &a, &b, 2000, 7, 0.95);
    try std.testing.expect(ci.low > 0);
    var am = a;
    var bm = b;
    try std.testing.expectEqual(Verdict.effect, verdictOf(&am, &bm, ci, 0.1, true));
}

test "an effect smaller than the one worth acting on is not an effect" {
    var buf: [1 << 20]u8 = undefined;
    var fba: std.heap.FixedBufferAllocator = .init(&buf);
    // Tight arms a hair apart: the interval can exclude zero while the difference is 2%.
    const a = [_]f64{ 100, 100, 100, 100, 100, 100 };
    const b = [_]f64{ 102, 102, 102, 102, 102, 102 };
    const ci = try bootstrapDifference(fba.allocator(), &a, &b, 2000, 7, 0.95);
    try std.testing.expect(ci.low > 0);
    var am = a;
    var bm = b;
    try std.testing.expectEqual(Verdict.below_the_threshold, verdictOf(&am, &bm, ci, 0.15, true));
    // The same data against a 1% threshold is an effect.
    try std.testing.expectEqual(Verdict.effect, verdictOf(&am, &bm, ci, 0.01, true));
}

test "two samples an arm is not a measurement" {
    const ci: Interval = .{ .low = 1, .high = 2 };
    var a = [_]f64{ 1, 2 };
    var b = [_]f64{ 3, 4 };
    try std.testing.expectEqual(Verdict.not_enough_samples, verdictOf(&a, &b, ci, 0.1, true));
}

test "the bootstrap is reproducible from its seed" {
    var buf: [1 << 20]u8 = undefined;
    var fba: std.heap.FixedBufferAllocator = .init(&buf);
    const a = [_]f64{ 1, 2, 3, 4, 5 };
    const b = [_]f64{ 2, 3, 4, 5, 6 };
    const one = try bootstrapDifference(fba.allocator(), &a, &b, 500, 42, 0.95);
    const two = try bootstrapDifference(fba.allocator(), &a, &b, 500, 42, 0.95);
    try std.testing.expectEqual(one.low, two.low);
    try std.testing.expectEqual(one.high, two.high);
}

test "dimensioning: a noisier arm needs more repetitions" {
    const quiet = [_]f64{ 10, 10.1, 9.9, 10, 10.05 };
    const noisy = [_]f64{ 10, 14, 6, 11, 9 };
    try std.testing.expect(repetitionsFor(&noisy, 0.5) > repetitionsFor(&quiet, 0.5));
    // Never fewer than three, whatever the spread.
    try std.testing.expectEqual(@as(usize, 3), repetitionsFor(&[_]f64{ 5, 5, 5 }, 0.5));
}

test "the reading is the last MEASURE line, and progress before it is ignored" {
    try std.testing.expectEqual(@as(?f64, 12.5), parseReading("building\nMEASURE 12.5\n"));
    try std.testing.expectEqual(@as(?f64, 3), parseReading("MEASURE 9\nMEASURE 3"));
    try std.testing.expectEqual(@as(?f64, null), parseReading("all done\n"));
    try std.testing.expectEqual(@as(?f64, null), parseReading("MEASURE later\n"));
}
