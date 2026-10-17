const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    // Release builds for deployment drop debug info (`zig build -Doptimize=ReleaseSafe -Dstrip`).
    const strip = b.option(bool, "strip", "Omit debug information") orelse null;

    // The build's own version, in every job's "Set up job" and in `--version`. Answering "which
    // binary is on that machine?" by comparing file sizes and timestamps is how an hour went
    // missing once; `git describe` answers it exactly.
    const build_options = b.addOptions();
    build_options.addOption([]const u8, "version", buildVersion(b));

    const exe = b.addExecutable(.{
        .name = "runner",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
            .strip = strip,
            .imports = &.{.{ .name = "build_options", .module = build_options.createModule() }},
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

/// `v0.2.0-116-g9eb33348`, or with `-dirty` when the tree has uncommitted changes: the release it
/// follows, how far past it, and the exact commit. `-Dversion=...` overrides it, which is how a
/// build from a tarball or a container without the history gets a real version; without either, the
/// package's own version stands in, which is honest but cannot identify a build.
fn buildVersion(b: *std.Build) []const u8 {
    if (b.option([]const u8, "version", "The version in the job log and --version")) |v| return v;
    var code: u8 = 0;
    // No `-C`: git looks upward from the working directory, so this works from the repository or
    // from `runner/` inside it, and falls through to the package version anywhere else.
    const out = b.runAllowFail(
        &.{ "git", "describe", "--tags", "--always", "--dirty", "--abbrev=8" },
        &code,
        .ignore,
    ) catch return @import("build.zig.zon").version;
    const described = std.mem.trim(u8, out, " \t\r\n");
    return if (described.len > 0) b.dupe(described) else @import("build.zig.zon").version;
}
