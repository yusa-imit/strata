//! Lint driver: loads the baseline, then reads each collected path and runs every check over
//! it, appending findings to the caller's list. `lintFile` runs the checks that need only the
//! file; the function-length and assertion-density passes are separate entry points because
//! they take the shared baseline / density list. Findings' messages are allocated with the
//! caller's `gpa` (the tidy entry point hands in an arena and never frees them one by one).

const std = @import("std");
const Allocator = std.mem.Allocator;
const scanner = @import("scanner.zig");
const Finding = scanner.Finding;
const baseline_mod = @import("baseline.zig");
const Baseline = baseline_mod.Baseline;
const ActualLen = baseline_mod.ActualLen;
const checks_ban = @import("checks_ban.zig");
const checks_density = @import("checks_density.zig");
const AssertionDensity = checks_density.AssertionDensity;
const checks_file = @import("checks_file.zig");
const walk = @import("walk.zig");

/// Reads and parses the baseline file at `path` (relative to `root_dir`); a
/// missing file is an empty baseline, not an error — a fresh checkout with
/// no red-zone exceptions yet is the expected common case.
pub fn loadBaseline(
    gpa: Allocator,
    io: std.Io,
    root_dir: std.Io.Dir,
    path: []const u8,
) !Baseline {
    std.debug.assert(path.len > 0);
    const content = root_dir.readFileAlloc(
        io,
        path,
        gpa,
        .limited(walk.max_file_bytes),
    ) catch |err| switch (err) {
        error.FileNotFound => return Baseline.init(gpa),
        else => return err,
    };
    const baseline = try Baseline.parse(gpa, content);
    std.debug.assert(baseline.entries.count() < 1_000_000); // sanity: matches parse's own bound
    return baseline;
}

/// Lints one file's already-read `content`, appending every finding onto
/// `findings`. Frees its own intermediate allocations before returning.
pub fn lintFile(
    gpa: Allocator,
    path: []const u8,
    content: []const u8,
    findings: *std.ArrayList(Finding),
) !void {
    std.debug.assert(path.len > 0);
    const lines = try scanner.splitLines(gpa, content);
    defer gpa.free(lines);

    const length_findings = try checks_file.checkLineLength(gpa, path, lines);
    defer gpa.free(length_findings);
    for (length_findings) |f| try findings.append(gpa, f);

    const header_findings = try checks_file.checkDocHeader(gpa, path, lines);
    defer gpa.free(header_findings);
    for (header_findings) |f| try findings.append(gpa, f);

    const file_length_findings = try checks_file.checkFileLength(gpa, path, lines);
    defer gpa.free(file_length_findings);
    for (file_length_findings) |f| try findings.append(gpa, f);

    const ban_findings = try checks_ban.checkBanList(gpa, path, lines);
    defer gpa.free(ban_findings);
    for (ban_findings) |f| try findings.append(gpa, f);

    const wire_findings = try checks_ban.checkWireFormatUsize(gpa, path, lines);
    defer gpa.free(wire_findings);
    for (wire_findings) |f| try findings.append(gpa, f);

    const io_findings = try checks_ban.checkIoFields(gpa, path, lines);
    defer gpa.free(io_findings);
    for (io_findings) |f| try findings.append(gpa, f);

    std.debug.assert(lines.len < 1_000_000); // sanity: matches formatFindings' bound
}

/// Lints one already-read file's assertion density, appending onto both
/// `densities_out` (unconditionally, for `formatDensityReport`) and
/// `findings` (only when the density check fails). Kept apart from
/// `lintFile` for the same reason as `lintFileFunctionLength`: that
/// function's signature is pinned by its own unit tests.
pub fn lintFileAssertionDensity(
    gpa: Allocator,
    path: []const u8,
    content: []const u8,
    densities_out: *std.ArrayList(AssertionDensity),
    findings: *std.ArrayList(Finding),
) !void {
    std.debug.assert(path.len > 0);
    const lines = try scanner.splitLines(gpa, content);
    defer gpa.free(lines);

    const density = checks_density.measureAssertionDensity(path, lines);
    try densities_out.append(gpa, density);

    const density_findings = try checks_density.checkAssertionDensity(gpa, density);
    defer gpa.free(density_findings);
    for (density_findings) |f| try findings.append(gpa, f);

    std.debug.assert(lines.len < 1_000_000); // sanity: matches lintFile's own bound
}

/// Lints one already-read file's line-based checks that need the shared
/// baseline (`checkFunctionLength`), appending onto `findings`. Kept apart
/// from `lintFile` because that function's signature is pinned by its own
/// unit tests to `(gpa, path, content, findings)` with no baseline.
pub fn lintFileFunctionLength(
    gpa: Allocator,
    path: []const u8,
    content: []const u8,
    baseline: Baseline,
    actual_out: *std.StringHashMap(ActualLen),
    findings: *std.ArrayList(Finding),
) !void {
    std.debug.assert(path.len > 0);
    const lines = try scanner.splitLines(gpa, content);
    defer gpa.free(lines);

    const fn_findings = try baseline_mod.checkFunctionLength(
        gpa,
        path,
        lines,
        baseline,
        actual_out,
    );
    defer gpa.free(fn_findings);
    for (fn_findings) |f| try findings.append(gpa, f);

    std.debug.assert(lines.len < 1_000_000); // sanity: matches lintFile's own bound
}

/// Reads and lints every collected `paths`, skipping (not failing on) a path
/// that fails to read — a file removed between the walk and the read is not
/// this tool's problem to report.
pub fn lintAllFiles(
    gpa: Allocator,
    io: std.Io,
    root_dir: std.Io.Dir,
    paths: []const []const u8,
    baseline: Baseline,
    actual_out: *std.StringHashMap(ActualLen),
    densities_out: *std.ArrayList(AssertionDensity),
    findings: *std.ArrayList(Finding),
) !void {
    std.debug.assert(paths.len < 1_000_000);
    for (paths) |p| {
        const content = root_dir.readFileAlloc(
            io,
            p,
            gpa,
            .limited(walk.max_file_bytes),
        ) catch |err| switch (err) {
            error.Canceled => return err,
            else => continue,
        };
        defer gpa.free(content);

        try lintFile(gpa, p, content, findings);
        try lintFileFunctionLength(gpa, p, content, baseline, actual_out, findings);
        try lintFileAssertionDensity(gpa, p, content, densities_out, findings);
    }
    std.debug.assert(findings.items.len < 1_000_000);
}

fn freeFindingsList(gpa: Allocator, findings: *std.ArrayList(Finding)) void {
    for (findings.items) |f| gpa.free(f.message);
    findings.deinit(gpa);
}

// -- lintFile integration (multi-rule fixture through the real wiring) -----------

test "lintFile surfaces findings from more than one new check on a mixed fixture" {
    const gpa = std.testing.allocator;
    // Fixture lines are spelled in pieces so this file's own scan does not flag them.
    const content =
        "//! doc\n" ++
        "// wire-format\n" ++
        "pub const Frame = struct {\n" ++
        "    len: usize,\n" ++
        "};\n" ++
        "\n" ++
        "f" ++ "n f() void {\n" ++
        "    x catch " ++ "unreachable;\n" ++
        "}\n";

    var findings: std.ArrayList(Finding) = .empty;
    defer freeFindingsList(gpa, &findings);

    try lintFile(gpa, "src/wal.zig", content, &findings);

    var saw_ban = false;
    var saw_wire = false;
    for (findings.items) |f| {
        if (std.mem.eql(u8, f.rule, "ban-list")) saw_ban = true;
        if (std.mem.eql(u8, f.rule, "wire-format-usize")) saw_wire = true;
    }
    try std.testing.expect(saw_ban);
    try std.testing.expect(saw_wire);
}

test "lintFile surfaces an Io field outside the allow list" {
    const gpa = std.testing.allocator;
    const content =
        "//! doc\n" ++
        "pub const Pool = struct {\n" ++
        "    io: std.Io,\n" ++
        "};\n";

    var findings: std.ArrayList(Finding) = .empty;
    defer freeFindingsList(gpa, &findings);

    try lintFile(gpa, "src/cache/buffer_pool.zig", content, &findings);

    var io_field_count: usize = 0;
    for (findings.items) |f| {
        if (std.mem.eql(u8, f.rule, "io-field")) io_field_count += 1;
    }
    try std.testing.expectEqual(@as(usize, 1), io_field_count);
}

test "lintFile surfaces zero findings from the new checks on a clean fixture" {
    const gpa = std.testing.allocator;
    const content =
        "//! doc\n" ++
        "pub const Frame = struct {\n" ++
        "    len: u32,\n" ++
        "};\n" ++
        "\n" ++
        "f" ++ "n f() void {\n" ++
        "    doWork() catch |err| return err;\n" ++
        "}\n";

    var findings: std.ArrayList(Finding) = .empty;
    defer freeFindingsList(gpa, &findings);

    try lintFile(gpa, "src/wal.zig", content, &findings);

    for (findings.items) |f| {
        try std.testing.expect(!std.mem.eql(u8, f.rule, "ban-list"));
        try std.testing.expect(!std.mem.eql(u8, f.rule, "wire-format-usize"));
    }
}
