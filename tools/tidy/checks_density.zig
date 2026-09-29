//! Assertion-density measurement and check (plan `001`, "Assertion baseline"). A `src/` file
//! with at least one function-with-a-body must average at least `assertion_density_min`
//! assertions per function; a file with no such function (a stub) is silent. Measurement is
//! pure over the file's lines; the check returns an owned findings slice (freed with
//! `scanner.freeFindings`). No state is retained and nothing is read from disk.

const std = @import("std");
const Allocator = std.mem.Allocator;
const scanner = @import("scanner.zig");
const Finding = scanner.Finding;

/// Mean assertions per function must be at least this to satisfy plan `001`'s
/// "Assertion baseline" item; today's figure is a floor that may only rise.
const assertion_density_min: usize = 2;

/// One `src/` file's assertion-density measurement: how many functions with a
/// measurable body were found (via `extractFnName`/`measureFunctionLines`),
/// and how many `assert(`/`assert_always(` calls appear across their combined
/// line spans. Files outside `src/`, and `src/` files with no such function
/// (a stub), report zero for both fields.
pub const AssertionDensity = struct {
    path: []const u8,
    functions: usize,
    assertions: usize,
};

/// Counts `assert(`/`assert_always(` occurrences (one match per line, per
/// needle, ignoring any `//` line-comment tail) across the inclusive line
/// span `[start_idx, start_idx + span)`.
fn countAssertionsInSpan(lines: []const []const u8, start_idx: usize, span: usize) usize {
    std.debug.assert(span > 0);
    std.debug.assert(start_idx + span <= lines.len);
    var count: usize = 0;
    var i = start_idx;
    while (i < start_idx + span) : (i += 1) {
        const code = scanner.stripLineComment(lines[i]);
        if (std.mem.find(u8, code, "assert(") != null) count += 1;
        if (std.mem.find(u8, code, "assert_always(") != null) count += 1;
    }
    std.debug.assert(count <= span * 2);
    return count;
}

/// Measures every function-with-a-body in `path` (`src/` only; other paths
/// report zero functions and zero assertions), summing `assert(`/
/// `assert_always(` calls across each function's line span.
pub fn measureAssertionDensity(path: []const u8, lines: []const []const u8) AssertionDensity {
    std.debug.assert(path.len > 0);
    var functions: usize = 0;
    var assertions: usize = 0;

    if (std.mem.startsWith(u8, path, "src/")) {
        var idx: usize = 0;
        while (idx < lines.len) : (idx += 1) {
            _ = scanner.extractFnName(lines[idx]) orelse continue;
            const span = scanner.measureFunctionLines(lines, idx) orelse continue;
            functions += 1;
            assertions += countAssertionsInSpan(lines, idx, span);
        }
    }

    std.debug.assert(functions <= lines.len);
    return .{ .path = path, .functions = functions, .assertions = assertions };
}

/// Check: a `src/` file with at least one function-with-a-body must average
/// at least `assertion_density_min` assertions per function; a file with no
/// such functions (a stub) is silent — there is nothing yet to assert over.
pub fn checkAssertionDensity(allocator: Allocator, density: AssertionDensity) ![]Finding {
    std.debug.assert(density.path.len > 0);
    var out: std.ArrayList(Finding) = .empty;
    errdefer out.deinit(allocator);

    const floor = density.functions * assertion_density_min;
    if (density.functions > 0 and density.assertions < floor) {
        const msg = try std.fmt.allocPrint(
            allocator,
            "{d} assertion(s) across {d} function(s) is below the floor of {d} per function",
            .{ density.assertions, density.functions, assertion_density_min },
        );
        try out.append(allocator, .{
            .path = density.path,
            .line = 1,
            .rule = "assertion-density",
            .message = msg,
        });
    }

    const result = try out.toOwnedSlice(allocator);
    std.debug.assert(result.len <= 1);
    return result;
}

// -- measureAssertionDensity / checkAssertionDensity -----------------------------
// Plan 001 item "Assertion baseline": a src/ file with at least one
// function-with-a-body must average >= 2 assertions per function.

test "measureAssertionDensity counts assert( and assert_always( calls in one function" {
    const lines = [_][]const u8{
        "fn f(x: u32) u32 {",
        "    std.debug.assert(x > 0);",
        "    assert_always(x < 100);",
        "    return x;",
        "}",
    };
    const d = measureAssertionDensity("src/a.zig", &lines);
    try std.testing.expectEqual(@as(usize, 1), d.functions);
    try std.testing.expectEqual(@as(usize, 2), d.assertions);
}

test "measureAssertionDensity does not count assert( mentioned only in a comment" {
    const lines = [_][]const u8{
        "fn f() void {",
        "    // TODO: add assert(x) here once the invariant is known",
        "    doWork();",
        "}",
    };
    const d = measureAssertionDensity("src/a.zig", &lines);
    try std.testing.expectEqual(@as(usize, 1), d.functions);
    try std.testing.expectEqual(@as(usize, 0), d.assertions);
}

test "measureAssertionDensity still counts a real assert( followed by a trailing comment" {
    const lines = [_][]const u8{
        "fn f() void {",
        "    assert(true); // reason",
        "}",
    };
    const d = measureAssertionDensity("src/a.zig", &lines);
    try std.testing.expectEqual(@as(usize, 1), d.functions);
    try std.testing.expectEqual(@as(usize, 1), d.assertions);
}

test "measureAssertionDensity sums assertions across multiple functions" {
    const lines = [_][]const u8{
        "fn f() void {",
        "    assert(true);",
        "    assert(true);",
        "}",
        "fn g() void {",
        "    assert(true);",
        "}",
    };
    const d = measureAssertionDensity("src/a.zig", &lines);
    try std.testing.expectEqual(@as(usize, 2), d.functions);
    try std.testing.expectEqual(@as(usize, 3), d.assertions);
}

test "measureAssertionDensity reports zero functions for a stub file with no fn opener" {
    const lines = [_][]const u8{ "//! doc", "pub const Error = error{NotImplemented};" };
    const d = measureAssertionDensity("src/codec.zig", &lines);
    try std.testing.expectEqual(@as(usize, 0), d.functions);
    try std.testing.expectEqual(@as(usize, 0), d.assertions);
}

test "measureAssertionDensity is silent outside src/ regardless of content" {
    const lines = [_][]const u8{ "fn f() void {", "}" };
    const d = measureAssertionDensity("tools/tidy.zig", &lines);
    try std.testing.expectEqual(@as(usize, 0), d.functions);
    try std.testing.expectEqual(@as(usize, 0), d.assertions);
}

test "checkAssertionDensity is silent when a file has no functions with a body" {
    const gpa = std.testing.allocator;
    const findings = try checkAssertionDensity(
        gpa,
        .{ .path = "src/a.zig", .functions = 0, .assertions = 0 },
    );
    defer scanner.freeFindings(gpa, findings);
    try std.testing.expectEqual(@as(usize, 0), findings.len);
}

test "checkAssertionDensity is silent when the mean meets the floor of 2" {
    const gpa = std.testing.allocator;
    const findings = try checkAssertionDensity(
        gpa,
        .{ .path = "src/a.zig", .functions = 2, .assertions = 4 },
    );
    defer scanner.freeFindings(gpa, findings);
    try std.testing.expectEqual(@as(usize, 0), findings.len);
}

test "checkAssertionDensity fails a fixture asserting nothing" {
    const gpa = std.testing.allocator;
    const findings = try checkAssertionDensity(
        gpa,
        .{ .path = "src/a.zig", .functions = 1, .assertions = 0 },
    );
    defer scanner.freeFindings(gpa, findings);
    try std.testing.expectEqual(@as(usize, 1), findings.len);
    try std.testing.expectEqualStrings("assertion-density", findings[0].rule);
}

test "checkAssertionDensity fails a mean just below the floor" {
    const gpa = std.testing.allocator;
    const findings = try checkAssertionDensity(
        gpa,
        .{ .path = "src/a.zig", .functions = 2, .assertions = 3 },
    );
    defer scanner.freeFindings(gpa, findings);
    try std.testing.expectEqual(@as(usize, 1), findings.len);
    try std.testing.expectEqualStrings("assertion-density", findings[0].rule);
}
