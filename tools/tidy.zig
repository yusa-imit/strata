//! strata's copy of the kingdom reference `tidy` lint (plan
//! `docs/plans/001-zig-0.16-and-tiger-baseline.md`, items 2 and 3; plan `002`, item 1: the
//! lint lints itself): line length, doc header, a hard 800-line file-length limit, function
//! length with a shrink-only red-zone baseline, the ban list, the wire-format `usize` check,
//! and the assertion-density report.
//! This file is the entry point only (argument parsing and the lint driver call); the checks
//! live in `tools/tidy/`: `scanner` (findings, lines, token helpers), `checks_file`,
//! `baseline` (function length), `checks_ban` (ban list, wire format), `checks_density`,
//! `report`, `walk` (directory walk), and `lint` (per-file driver).
//! Zero dependencies. Walks `src/`, `build.zig`, `bench/`, `tests/`, `tools/` under `--root`
//! (default `.`), skipping `.zig-cache`, `zig-out`, `zig-pkg`, loads `--baseline` (default
//! `tools/tidy_baseline.txt`, a missing file means an empty baseline), lints every `.zig` file
//! found, prints the report to stdout, and exits 1 on any finding.
//! Built for Zig 0.16.0 (`std.Io.Dir`); no allocator is retained past `main`'s own arena.

const std = @import("std");
const scanner = @import("tidy/scanner.zig");
const baseline_mod = @import("tidy/baseline.zig");
const checks_density = @import("tidy/checks_density.zig");
const lint = @import("tidy/lint.zig");
const report = @import("tidy/report.zig");
const walk = @import("tidy/walk.zig");

const default_baseline_path = "tools/tidy_baseline.txt";

/// Returns the value following `flag` in `args`, or `default` when the flag is absent or is
/// the last argument (a flag with no value). The first occurrence with a value wins.
fn parseFlagValue(args: []const []const u8, flag: []const u8, default: []const u8) []const u8 {
    std.debug.assert(args.len < 1_000_000); // sanity: never a runaway argv
    std.debug.assert(flag.len > 0);
    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        if (std.mem.eql(u8, args[i], flag) and i + 1 < args.len) return args[i + 1];
    }
    return default;
}

/// Entry point: walks `--root` (default `.`), lints every `.zig` file found,
/// prints the report to stdout, and exits 1 if any finding was reported.
pub fn main(init: std.process.Init) !void {
    const gpa = init.arena.allocator();
    const io = init.io;

    const raw_args = try init.minimal.args.toSlice(gpa);
    const args = raw_args[@min(1, raw_args.len)..];
    const root = parseFlagValue(args, "--root", ".");
    const baseline_path = parseFlagValue(args, "--baseline", default_baseline_path);
    std.debug.assert(root.len > 0);
    std.debug.assert(baseline_path.len > 0);

    var root_dir = try std.Io.Dir.cwd().openDir(io, root, .{ .iterate = true });
    defer root_dir.close(io);

    const baseline = try lint.loadBaseline(gpa, io, root_dir, baseline_path);
    const paths = try walk.collectFiles(gpa, io, root_dir);

    var findings: std.ArrayList(scanner.Finding) = .empty;
    var actual = std.StringHashMap(baseline_mod.ActualLen).init(gpa);
    var densities: std.ArrayList(checks_density.AssertionDensity) = .empty;
    try lint.lintAllFiles(gpa, io, root_dir, paths, baseline, &actual, &densities, &findings);

    const stale_findings = try baseline_mod.reconcileBaseline(gpa, baseline, actual);
    for (stale_findings) |f| try findings.append(gpa, f);

    const density_report = try report.formatDensityReport(gpa, densities.items);
    try std.Io.File.stdout().writeStreamingAll(io, density_report);

    const findings_report = try report.formatFindings(gpa, findings.items);
    try std.Io.File.stdout().writeStreamingAll(io, findings_report);

    std.debug.assert(findings.items.len < 1_000_000);
    if (findings.items.len > 0) std.process.exit(1);
}

// Referencing each module pulls its tests into this root, so `zig test tools/tidy.zig` (and the
// `test` build step) runs every check's unit tests.
test {
    _ = @import("tidy/scanner.zig");
    _ = @import("tidy/checks_file.zig");
    _ = @import("tidy/baseline.zig");
    _ = @import("tidy/checks_ban.zig");
    _ = @import("tidy/checks_density.zig");
    _ = @import("tidy/report.zig");
    _ = @import("tidy/lint.zig");
    _ = @import("tidy/walk.zig");
}

test "parseFlagValue returns the value after the flag" {
    const args = [_][]const u8{ "--root", "/repo", "--baseline", "b.txt" };
    try std.testing.expectEqualStrings("/repo", parseFlagValue(&args, "--root", "."));
    try std.testing.expectEqualStrings("b.txt", parseFlagValue(&args, "--baseline", "d"));
}

test "parseFlagValue falls back to the default when the flag is absent or valueless" {
    const args = [_][]const u8{ "--baseline", "b.txt", "--root" };
    try std.testing.expectEqualStrings("d", parseFlagValue(&args, "--other", "d"));
    try std.testing.expectEqualStrings(".", parseFlagValue(&args, "--root", "."));
    try std.testing.expectEqualStrings(".", parseFlagValue(&.{}, "--root", "."));
}
