//! Report rendering: the per-file assertion-density lines and the findings listing with its
//! summary line. Both renderers are pure functions that return an owned byte slice; the
//! caller frees it with the allocator passed in. Nothing is written to stdout here — the
//! entry point in `tools/tidy.zig` decides when and where the text goes.

const std = @import("std");
const Allocator = std.mem.Allocator;
const scanner = @import("scanner.zig");
const Finding = scanner.Finding;
const AssertionDensity = @import("checks_density.zig").AssertionDensity;

/// Renders one density-report line per `src/` file that has at least one
/// function-with-a-body, in input order: `tidy: density path: A assertion(s)
/// / F function(s)`. Files with zero such functions are omitted; printed
/// unconditionally by `main`, independent of pass/fail, so density stays
/// visible as Phase 1 code lands. Caller frees the result with `gpa`.
pub fn formatDensityReport(gpa: Allocator, densities: []const AssertionDensity) ![]u8 {
    std.debug.assert(densities.len < 1_000_000); // sanity: never a runaway file list
    var buf: std.ArrayList(u8) = .empty;
    errdefer buf.deinit(gpa);

    for (densities) |d| {
        if (d.functions == 0) continue;
        try buf.print(gpa, "tidy: density {s}: {d} assertion(s) / {d} function(s)\n", .{
            d.path, d.assertions, d.functions,
        });
    }

    const result = try buf.toOwnedSlice(gpa);
    std.debug.assert(result.len == 0 or densities.len > 0);
    return result;
}

/// Renders every finding as `path:line: rule: message\n`, then a summary line
/// `tidy: N finding(s)\n`. Caller frees the result with `gpa`.
pub fn formatFindings(gpa: Allocator, findings: []const Finding) ![]u8 {
    std.debug.assert(findings.len < 1_000_000); // sanity: never a runaway report
    var buf: std.ArrayList(u8) = .empty;
    errdefer buf.deinit(gpa);

    for (findings) |f| {
        try buf.print(gpa, "{s}:{d}: {s}: {s}\n", .{ f.path, f.line, f.rule, f.message });
    }
    try buf.print(gpa, "tidy: {d} finding(s)\n", .{findings.len});

    const out = try buf.toOwnedSlice(gpa);
    std.debug.assert(out.len > 0);
    return out;
}

// -- formatFindings ----------------------------------------------------------

test "formatFindings renders an empty report and a zero summary" {
    const gpa = std.testing.allocator;
    const out = try formatFindings(gpa, &.{});
    defer gpa.free(out);
    try std.testing.expectEqualStrings("tidy: 0 finding(s)\n", out);
}

test "formatFindings renders one finding as path:line: rule: message" {
    const gpa = std.testing.allocator;
    const findings = [_]Finding{.{
        .path = "src/a.zig",
        .line = 3,
        .rule = "line-length",
        .message = try gpa.dupe(u8, "line is 150 columns (limit 100)"),
    }};
    defer gpa.free(findings[0].message);

    const out = try formatFindings(gpa, &findings);
    defer gpa.free(out);
    const expected = "src/a.zig:3: line-length: line is 150 columns (limit 100)\n" ++
        "tidy: 1 finding(s)\n";
    try std.testing.expectEqualStrings(expected, out);
}

test "formatFindings renders multiple findings in order with a correct total" {
    const gpa = std.testing.allocator;
    const findings = [_]Finding{
        .{
            .path = "src/a.zig",
            .line = 1,
            .rule = "doc-header",
            .message = try gpa.dupe(u8, "file under src/ must start with a `//!` doc comment"),
        },
        .{
            .path = "src/a.zig",
            .line = 5,
            .rule = "line-length",
            .message = try gpa.dupe(u8, "line is 101 columns (limit 100)"),
        },
    };
    defer gpa.free(findings[0].message);
    defer gpa.free(findings[1].message);

    const out = try formatFindings(gpa, &findings);
    defer gpa.free(out);
    const expected =
        "src/a.zig:1: doc-header: file under src/ must start with a `//!` doc comment\n" ++
        "src/a.zig:5: line-length: line is 101 columns (limit 100)\n" ++
        "tidy: 2 finding(s)\n";
    try std.testing.expectEqualStrings(expected, out);
}

// -- formatDensityReport -----------------------------------------------------

test "formatDensityReport renders one line per file with functions, in order" {
    const gpa = std.testing.allocator;
    const densities = [_]AssertionDensity{
        .{ .path = "src/a.zig", .functions = 2, .assertions = 4 },
        .{ .path = "src/codec.zig", .functions = 0, .assertions = 0 },
        .{ .path = "src/b.zig", .functions = 1, .assertions = 1 },
    };
    const out = try formatDensityReport(gpa, &densities);
    defer gpa.free(out);
    const expected = "tidy: density src/a.zig: 4 assertion(s) / 2 function(s)\n" ++
        "tidy: density src/b.zig: 1 assertion(s) / 1 function(s)\n";
    try std.testing.expectEqualStrings(expected, out);
}

test "formatDensityReport renders nothing when no file has a function with a body" {
    const gpa = std.testing.allocator;
    const densities = [_]AssertionDensity{
        .{ .path = "src/codec.zig", .functions = 0, .assertions = 0 },
    };
    const out = try formatDensityReport(gpa, &densities);
    defer gpa.free(out);
    try std.testing.expectEqualStrings("", out);
}
