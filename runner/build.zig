const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    // Release builds for deployment drop debug info (`zig build -Doptimize=ReleaseSafe -Dstrip`).
    const strip = b.option(bool, "strip", "Omit debug information") orelse null;

    const exe = b.addExecutable(.{
        .name = "runner",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
            .strip = strip,
        }),
    });
    b.installArtifact(exe);

    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());
    run_cmd.addPassthruArgs();
    b.step("run", "Run the runner").dependOn(&run_cmd.step);

    const tests = b.addTest(.{ .root_module = exe.root_module });
    b.step("test", "Run tests").dependOn(&b.addRunArtifact(tests).step);

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
}
