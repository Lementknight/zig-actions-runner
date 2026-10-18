const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    // Release builds for deployment drop debug info (`zig build -Doptimize=ReleaseSafe -Dstrip`).
    const strip = b.option(bool, "strip", "Omit debug information") orelse null;

    // The build's own version, in every job's "Set up job" and in `--version`. Answering "which
    // binary is on that machine?" by comparing file sizes and timestamps is how an hour went
    // missing once; `git describe` answers it exactly.
    const version = b.createModule(.{ .root_source_file = versionFile(b) });

    const exe = b.addExecutable(.{
        .name = "runner",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
            .strip = strip,
            .imports = &.{.{ .name = "build_version", .module = version }},
        }),
    });
    b.installArtifact(exe);

    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());
    run_cmd.addPassthruArgs();
    b.step("run", "Run the runner").dependOn(&run_cmd.step);

    const tests = b.addTest(.{ .root_module = exe.root_module });
    const test_step = b.step("test", "Run tests");
    test_step.dependOn(&b.addRunArtifact(tests).step);

    // Checks the workflow YAML of this repository (and any path given after `--`), with the YAML
    // parser the runner itself uses. See tools/check_workflows.zig and the git hooks.
    const yaml_mod = b.createModule(.{ .root_source_file = b.path("src/yaml.zig"), .target = target, .optimize = optimize });
    const checker = b.addExecutable(.{
        .name = "check-workflows",
        .root_module = b.createModule(.{
            .root_source_file = b.path("tools/check_workflows.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{.{ .name = "yaml", .module = yaml_mod }},
        }),
    });
    const check = b.addRunArtifact(checker);
    check.stdio = .inherit; // its findings are the point, so let them through
    check.addArg("../.github/workflows");
    check.addPassthruArgs();
    b.step("check-workflows", "Check workflow YAML (this repository's, plus any paths after --)").dependOn(&check.step);

    // Exposes the regex matcher so another implementation can be compared against it
    // (`tools/regex_diff.py` drives this against Python's `re`). Writing our own matcher is only
    // defensible if something else agrees with it.
    const regex_mod = b.createModule(.{ .root_source_file = b.path("src/regex.zig"), .target = target, .optimize = optimize });
    const regex_diff = b.addExecutable(.{
        .name = "regex-diff",
        .root_module = b.createModule(.{
            .root_source_file = b.path("tools/regex_diff.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{.{ .name = "regex", .module = regex_mod }},
        }),
    });
    // A step of its own, and deliberately *not* part of the default install: the Dockerfile copies
    // only build.zig and src/, so an artifact in the default step makes the image fail to build on
    // a missing tools/ — which is how the first version of this broke the release image. `zig build
    // test` installs nothing either, so CI runs this step before driving regex_diff.py.
    b.step("regex-diff", "Build the regex comparison tool that tools/regex_diff.py drives")
        .dependOn(&b.addInstallArtifact(regex_diff, .{}).step);

    // The measurement harness (docs/MEASURE.md stage 2). Its statistics decide verdicts, so they
    // are unit-tested with the rest of the suite; `zig build measure -- run ...` drives it.
    const measure = b.addExecutable(.{
        .name = "measure",
        .root_module = b.createModule(.{
            .root_source_file = b.path("tools/measure.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    const measure_run = b.addRunArtifact(measure);
    measure_run.stdio = .inherit;
    measure_run.addPassthruArgs();
    b.step("measure", "Run the measurement harness (arguments after --)").dependOn(&measure_run.step);
    const measure_tests = b.addTest(.{ .root_module = measure.root_module });
    test_step.dependOn(&b.addRunArtifact(measure_tests).step);
}

/// A file holding the version, for `src/version.zig` to `@embedFile`: `v0.2.0-118-g5063ae36`, with
/// `-dirty` when the tree has uncommitted changes — the release it follows, how far past it, and
/// the exact commit.
///
/// Computed when the build *runs*, not when it is configured. `zig build` caches its configuration
/// per set of `-D` options, so a version read while configuring survives HEAD moving: the first
/// version of this produced an aarch64 binary that named the commit before the one it was built
/// from, which is worse than no version at all. `has_side_effects` makes git run every build, and
/// the compilation downstream of it only redo itself when the output actually changes.
///
/// `-Dversion=...` skips git, which is how the builds with no history to read get a real version:
/// the release workflow passes the tag, the image build takes a build argument. Where there is
/// neither git nor a flag, the package's version stands in — honest, and visibly not a build.
fn versionFile(b: *std.Build) std.Build.LazyPath {
    if (b.option([]const u8, "version", "The version in the job log and --version")) |v|
        return b.addWriteFiles().add("version", v);
    // Whether git works here is a property of the checkout, not of HEAD, so this probe can be
    // cached with the configuration; what must not be cached is the answer it produces.
    var code: u8 = 0;
    _ = b.runAllowFail(&.{ "git", "rev-parse", "--git-dir" }, &code, .ignore) catch
        return b.addWriteFiles().add("version", @import("build.zig.zon").version);
    const git = b.addSystemCommand(&.{ "git", "describe", "--tags", "--always", "--dirty", "--abbrev=8" });
    git.has_side_effects = true;
    return git.captureStdOut(.{ .basename = "version" });
}
