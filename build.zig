const std = @import("std");

/// Build graph for strata — Layers beneath the data — WAL, pages, and a key-value engine for Zig
///
/// Steps:
///   zig build            — build library + CLI
///   zig build test       — run all unit tests
///   zig build bench      — run benchmarks (ReleaseFast recommended)
///   zig build docs       — generate API docs into zig-out/docs
pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const mod = addLibraryModule(b, target);
    const exe = addCliExecutable(b, mod, target, optimize);
    addRunStep(b, exe);

    const test_step = b.step("test", "Run unit tests");
    const mod_tests = addTestStep(b, mod, exe, test_step);
    addTidyStep(b, test_step);
    addBenchStep(b, mod, target);
    addDocsStep(b, mod_tests);
}

/// Public library module — consumers `@import("strata")`.
fn addLibraryModule(b: *std.Build, target: std.Build.ResolvedTarget) *std.Build.Module {
    return b.addModule("strata", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
    });
}

/// CLI executable (diagnostics, version, small utilities).
fn addCliExecutable(
    b: *std.Build,
    mod: *std.Build.Module,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
) *std.Build.Step.Compile {
    const exe = b.addExecutable(.{
        .name = "strata",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "strata", .module = mod },
            },
        }),
    });
    b.installArtifact(exe);
    return exe;
}

fn addRunStep(b: *std.Build, exe: *std.Build.Step.Compile) void {
    const run_step = b.step("run", "Run the CLI");
    const run_cmd = b.addRunArtifact(exe);
    run_step.dependOn(&run_cmd.step);
    run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| run_cmd.addArgs(args);
}

fn addTestStep(
    b: *std.Build,
    mod: *std.Build.Module,
    exe: *std.Build.Step.Compile,
    test_step: *std.Build.Step,
) *std.Build.Step.Compile {
    const mod_tests = b.addTest(.{ .root_module = mod });
    const run_mod_tests = b.addRunArtifact(mod_tests);
    const exe_tests = b.addTest(.{ .root_module = exe.root_module });
    const run_exe_tests = b.addRunArtifact(exe_tests);
    test_step.dependOn(&run_mod_tests.step);
    test_step.dependOn(&run_exe_tests.step);
    return mod_tests;
}

/// Tidy lint (Tiger Style mechanical checks) — always runs as part of `test`.
fn addTidyStep(b: *std.Build, test_step: *std.Build.Step) void {
    const tidy = b.addExecutable(.{
        .name = "tidy",
        .root_module = b.createModule(.{
            .root_source_file = b.path("tools/tidy.zig"),
            .target = b.graph.host,
        }),
    });
    const run_tidy = b.addRunArtifact(tidy);
    run_tidy.addArgs(&.{
        "--root",     b.pathFromRoot("."),
        "--baseline", b.pathFromRoot("tools/tidy_baseline.txt"),
    });
    test_step.dependOn(&run_tidy.step);

    const tidy_step = b.step("tidy", "Run the tidy lint on its own");
    tidy_step.dependOn(&run_tidy.step);
}

fn addBenchStep(b: *std.Build, mod: *std.Build.Module, target: std.Build.ResolvedTarget) void {
    const bench = b.addExecutable(.{
        .name = "strata-bench",
        .root_module = b.createModule(.{
            .root_source_file = b.path("bench/main.zig"),
            .target = target,
            .optimize = .ReleaseFast,
            .imports = &.{
                .{ .name = "strata", .module = mod },
            },
        }),
    });
    const run_bench = b.addRunArtifact(bench);
    if (b.args) |args| run_bench.addArgs(args);
    const bench_step = b.step("bench", "Run benchmarks");
    bench_step.dependOn(&run_bench.step);
}

fn addDocsStep(b: *std.Build, mod_tests: *std.Build.Step.Compile) void {
    const docs = b.addInstallDirectory(.{
        .source_dir = mod_tests.getEmittedDocs(),
        .install_dir = .prefix,
        .install_subdir = "docs",
    });
    const docs_step = b.step("docs", "Generate API documentation");
    docs_step.dependOn(&docs.step);
}
