//! File-shape checks: line length (100 Unicode code points), the `//!` doc header required of
//! every file under `src/`, and the hard 800-line file-length limit. Each check is a pure
//! function over the file's lines and returns an owned findings slice; the caller frees it
//! with `scanner.freeFindings`. No state is retained and nothing is read from disk.

const std = @import("std");
const Allocator = std.mem.Allocator;
const scanner = @import("scanner.zig");
const Finding = scanner.Finding;

const max_line_len: usize = 100;

/// Check 1: every line must be at most 100 Unicode code points (not bytes).
pub fn checkLineLength(
    allocator: Allocator,
    path: []const u8,
    lines: []const []const u8,
) ![]Finding {
    std.debug.assert(path.len > 0);
    var out: std.ArrayList(Finding) = .empty;
    errdefer out.deinit(allocator);

    for (lines, 0..) |line, idx| {
        const n = std.unicode.utf8CountCodepoints(line) catch line.len;
        if (n > max_line_len) {
            const msg = try std.fmt.allocPrint(
                allocator,
                "line is {d} columns (limit {d})",
                .{ n, max_line_len },
            );
            try out.append(allocator, .{
                .path = path,
                .line = idx + 1,
                .rule = "line-length",
                .message = msg,
            });
        }
    }

    const result = try out.toOwnedSlice(allocator);
    std.debug.assert(result.len <= lines.len);
    return result;
}

/// Check 2: the first line of every `.zig` file under `src/` must start with a
/// `//!` doc comment. Files not under `src/` are exempt (no findings).
pub fn checkDocHeader(
    allocator: Allocator,
    path: []const u8,
    lines: []const []const u8,
) ![]Finding {
    std.debug.assert(path.len > 0);
    var out: std.ArrayList(Finding) = .empty;
    errdefer out.deinit(allocator);

    if (!std.mem.startsWith(u8, path, "src/")) {
        const result = try out.toOwnedSlice(allocator);
        std.debug.assert(result.len == 0);
        return result;
    }

    const first = if (lines.len > 0) lines[0] else "";
    if (!std.mem.startsWith(u8, first, "//!")) {
        const msg = try allocator.dupe(u8, "file under src/ must start with a `//!` doc comment");
        try out.append(allocator, .{
            .path = path,
            .line = 1,
            .rule = "doc-header",
            .message = msg,
        });
    }

    const result = try out.toOwnedSlice(allocator);
    std.debug.assert(result.len <= 1);
    return result;
}

const max_file_lines: usize = 800;

/// Check 3: a file may not exceed `max_file_lines` (800) lines, no
/// exemption by path — the same hard limit `tiger-style.md`'s mechanical
/// checks table imposes kingdom-wide. Unlike `checkFunctionLength`, no
/// baseline rescues an existing offender; a file over the limit shrinks.
pub fn checkFileLength(
    allocator: Allocator,
    path: []const u8,
    lines: []const []const u8,
) ![]Finding {
    std.debug.assert(path.len > 0);
    var out: std.ArrayList(Finding) = .empty;
    errdefer out.deinit(allocator);

    if (lines.len > max_file_lines) {
        const msg = try std.fmt.allocPrint(
            allocator,
            "file is {d} lines (limit {d})",
            .{ lines.len, max_file_lines },
        );
        try out.append(allocator, .{
            .path = path,
            .line = lines.len,
            .rule = "file-length",
            .message = msg,
        });
    }

    const result = try out.toOwnedSlice(allocator);
    std.debug.assert(result.len <= 1);
    return result;
}

// -- checkLineLength -----------------------------------------------------------

test "checkLineLength passes a line at exactly the 100 code point limit" {
    const gpa = std.testing.allocator;
    const exactly_100 = "x" ** 100;
    const findings = try checkLineLength(gpa, "src/a.zig", &.{exactly_100});
    defer scanner.freeFindings(gpa, findings);
    try std.testing.expectEqual(@as(usize, 0), findings.len);
}

test "checkLineLength fails a line one code point past the limit" {
    const gpa = std.testing.allocator;
    const over_by_one = "x" ** 101;
    const findings = try checkLineLength(gpa, "src/a.zig", &.{over_by_one});
    defer scanner.freeFindings(gpa, findings);
    try std.testing.expectEqual(@as(usize, 1), findings.len);
    try std.testing.expectEqualStrings("line-length", findings[0].rule);
    try std.testing.expectEqual(@as(usize, 1), findings[0].line);
}

test "checkLineLength counts Unicode code points, not encoded bytes" {
    const gpa = std.testing.allocator;
    // "é" is 2 bytes in UTF-8; 100 of them is 200 bytes but only 100 code
    // points, so this must pass despite being well over 100 bytes long.
    const hundred_codepoints_two_hundred_bytes = "é" ** 100;
    const findings = try checkLineLength(
        gpa,
        "src/a.zig",
        &.{hundred_codepoints_two_hundred_bytes},
    );
    defer scanner.freeFindings(gpa, findings);
    try std.testing.expectEqual(@as(usize, 0), findings.len);
    try std.testing.expect(hundred_codepoints_two_hundred_bytes.len > max_line_len);
}

test "checkLineLength passes an empty line" {
    const gpa = std.testing.allocator;
    const findings = try checkLineLength(gpa, "src/a.zig", &.{""});
    defer scanner.freeFindings(gpa, findings);
    try std.testing.expectEqual(@as(usize, 0), findings.len);
}

test "checkLineLength reports one finding per long line at correct 1-indexed lines" {
    const gpa = std.testing.allocator;
    const short = "ok";
    const long_a = "a" ** 150;
    const long_b = "b" ** 200;
    const findings = try checkLineLength(gpa, "src/a.zig", &.{ short, long_a, short, long_b });
    defer scanner.freeFindings(gpa, findings);
    try std.testing.expectEqual(@as(usize, 2), findings.len);
    try std.testing.expectEqual(@as(usize, 2), findings[0].line);
    try std.testing.expectEqualStrings("line-length", findings[0].rule);
    try std.testing.expectEqual(@as(usize, 4), findings[1].line);
    try std.testing.expectEqualStrings("line-length", findings[1].rule);
}

test "checkLineLength is silent on an entirely clean file" {
    const gpa = std.testing.allocator;
    const findings = try checkLineLength(gpa, "src/a.zig", &.{ "const a = 1;", "", "// fine" });
    defer scanner.freeFindings(gpa, findings);
    try std.testing.expectEqual(@as(usize, 0), findings.len);
}

// -- checkDocHeader --------------------------------------------------------

test "checkDocHeader fails a src/ file whose first line is not a //! comment" {
    const gpa = std.testing.allocator;
    const findings = try checkDocHeader(gpa, "src/a.zig", &.{"const x = 1;"});
    defer scanner.freeFindings(gpa, findings);
    try std.testing.expectEqual(@as(usize, 1), findings.len);
    try std.testing.expectEqualStrings("doc-header", findings[0].rule);
    try std.testing.expectEqual(@as(usize, 1), findings[0].line);
}

test "checkDocHeader passes a src/ file that opens with a //! comment" {
    const gpa = std.testing.allocator;
    const findings = try checkDocHeader(gpa, "src/a.zig", &.{ "//! doc", "const x = 1;" });
    defer scanner.freeFindings(gpa, findings);
    try std.testing.expectEqual(@as(usize, 0), findings.len);
}

test "checkDocHeader exempts files outside src/ regardless of their first line" {
    const gpa = std.testing.allocator;

    const build_zig = try checkDocHeader(gpa, "build.zig", &.{"const std = @import(\"std\");"});
    defer scanner.freeFindings(gpa, build_zig);
    try std.testing.expectEqual(@as(usize, 0), build_zig.len);

    const tools_file = try checkDocHeader(gpa, "tools/x.zig", &.{"const x = 1;"});
    defer scanner.freeFindings(gpa, tools_file);
    try std.testing.expectEqual(@as(usize, 0), tools_file.len);
}

test "checkDocHeader fails an empty src/ file (no first line to carry a header)" {
    const gpa = std.testing.allocator;
    const findings = try checkDocHeader(gpa, "src/empty.zig", &.{});
    defer scanner.freeFindings(gpa, findings);
    try std.testing.expectEqual(@as(usize, 1), findings.len);
    try std.testing.expectEqual(@as(usize, 1), findings[0].line);
}

// -- checkFileLength --------------------------------------------------------

fn linesOfLength(comptime n: usize) [n][]const u8 {
    var lines: [n][]const u8 = undefined;
    for (&lines) |*l| l.* = "const x = 1;";
    return lines;
}

test "checkFileLength passes a file at exactly the 800-line limit" {
    const gpa = std.testing.allocator;
    const lines = linesOfLength(800);
    const findings = try checkFileLength(gpa, "src/a.zig", &lines);
    defer scanner.freeFindings(gpa, findings);
    try std.testing.expectEqual(@as(usize, 0), findings.len);
}

test "checkFileLength fails a file one line past the limit" {
    const gpa = std.testing.allocator;
    const lines = linesOfLength(801);
    const findings = try checkFileLength(gpa, "src/a.zig", &lines);
    defer scanner.freeFindings(gpa, findings);
    try std.testing.expectEqual(@as(usize, 1), findings.len);
    try std.testing.expectEqualStrings("file-length", findings[0].rule);
    try std.testing.expectEqual(@as(usize, 801), findings[0].line);
}

test "checkFileLength is silent on an empty file" {
    const gpa = std.testing.allocator;
    const findings = try checkFileLength(gpa, "src/a.zig", &.{});
    defer scanner.freeFindings(gpa, findings);
    try std.testing.expectEqual(@as(usize, 0), findings.len);
}
