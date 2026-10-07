//! Line scanner shared by every tidy check: the `Finding` record, line splitting, and the
//! token-level helpers (identifier characters, brace depth, comment stripping, function
//! openers and spans) that the length, ban-list, wire-format, and density checks build on.
//! Pure functions over in-memory lines: no filesystem access, no retained allocator; every
//! slice a function returns is owned by the caller, who frees it with the allocator passed in.

const std = @import("std");
const Allocator = std.mem.Allocator;

/// One lint result. `path`, `rule`, and `replacement` borrow from static or caller memory;
/// `message` is allocated by the check that produced the finding.
pub const Finding = struct {
    path: []const u8,
    line: usize,
    // "line-length", "doc-header", "file-length", "function-length", "stale-baseline",
    // "ban-list", "wire-format-usize", or "assertion-density".
    rule: []const u8,
    message: []const u8,
    // Non-null on ban-list and function-length findings: a suggested fix to
    // print alongside the message.
    replacement: ?[]const u8 = null,
};

/// Frees a findings slice returned by a check: each `message`, then the slice itself.
/// Precondition: every message was allocated with `gpa` (all checks do so).
pub fn freeFindings(gpa: Allocator, findings: []Finding) void {
    std.debug.assert(findings.len < 1_000_000); // sanity: never a runaway report
    for (findings) |f| gpa.free(f.message);
    gpa.free(findings);
}

/// Splits `content` into lines (without trailing `\n` or `\r`), as slices into
/// `content`. Caller frees the returned slice with `gpa`.
pub fn splitLines(gpa: Allocator, content: []const u8) ![][]const u8 {
    std.debug.assert(@intFromPtr(content.ptr) != 0 or content.len == 0);
    var out: std.ArrayList([]const u8) = .empty;
    errdefer out.deinit(gpa);

    if (content.len == 0) return out.toOwnedSlice(gpa);

    var it = std.mem.splitScalar(u8, content, '\n');
    while (it.next()) |raw| {
        const line = if (raw.len > 0 and raw[raw.len - 1] == '\r') raw[0 .. raw.len - 1] else raw;
        try out.append(gpa, line);
    }
    // `splitScalar` yields a trailing empty segment after a final '\n'; drop it so
    // content ending in a newline does not report a phantom empty last line.
    if (out.items.len > 0 and out.items[out.items.len - 1].len == 0 and
        content.len > 0 and content[content.len - 1] == '\n')
    {
        _ = out.pop();
    }

    const result = try out.toOwnedSlice(gpa);
    std.debug.assert(result.len == 0 or content.len > 0);
    return result;
}

/// True for a character that may appear inside a Zig identifier.
pub fn isIdentChar(c: u8) bool {
    const is_ident = std.ascii.isAlphanumeric(c) or c == '_';
    if (c == '_') std.debug.assert(is_ident);
    if (c == ' ') std.debug.assert(!is_ident);
    return is_ident;
}

/// Finds the name of a function declared as `fn name(` on this line (no
/// space between the name and the opening paren, per Zig style). Returns
/// null when the line does not open a named function.
pub fn extractFnName(line: []const u8) ?[]const u8 {
    std.debug.assert(line.len < 1_000_000); // sanity: never an absurd line
    const idx = std.mem.find(u8, line, "fn ") orelse return null;
    if (idx > 0 and isIdentChar(line[idx - 1])) return null;

    var i = idx + 3;
    while (i < line.len and line[i] == ' ') i += 1;
    const start = i;
    while (i < line.len and isIdentChar(line[i])) i += 1;
    if (i == start or i >= line.len or line[i] != '(') return null;

    const name = line[start..i];
    std.debug.assert(name.len > 0);
    std.debug.assert(name.len <= line.len);
    return name;
}

/// Returns true when `line`'s first non-blank content is a multiline string
/// literal marker (`\\`), whose contents must not be scanned for braces.
fn isMultilineStringLine(line: []const u8) bool {
    std.debug.assert(line.len < 1_000_000); // sanity: never an absurd line
    const trimmed = std.mem.trimStart(u8, line, " \t");
    return std.mem.startsWith(u8, trimmed, "\\\\");
}

/// Net change in brace depth contributed by one line, ignoring braces inside
/// `"..."` string literals, `'...'` char literals, after a `//` comment, and
/// on a multiline string literal line (a line whose trimmed content starts
/// with `\\`).
pub fn braceDelta(line: []const u8) i32 {
    std.debug.assert(line.len < 1_000_000); // sanity: never an absurd line
    if (isMultilineStringLine(line)) return 0;

    var delta: i32 = 0;
    var in_string = false;
    var in_char = false;
    var i: usize = 0;
    while (i < line.len) : (i += 1) {
        const c = line[i];
        if (in_string) {
            if (c == '\\') i += 1 else if (c == '"') in_string = false;
            continue;
        }
        if (in_char) {
            if (c == '\\') i += 1 else if (c == '\'') in_char = false;
            continue;
        }
        switch (c) {
            '/' => if (i + 1 < line.len and line[i + 1] == '/') break,
            '"' => in_string = true,
            '\'' => in_char = true,
            '{' => delta += 1,
            '}' => delta -= 1,
            else => {},
        }
    }

    std.debug.assert(delta <= @as(i32, @intCast(line.len)));
    std.debug.assert(delta >= -@as(i32, @intCast(line.len)));
    return delta;
}

const measure_lines_max: u32 = 100_000;

/// Measures the inclusive line span of the function whose opener is
/// `lines[start_idx]`, tracked via `braceDelta`. Null if the function body
/// never closes within `lines`.
pub fn measureFunctionLines(lines: []const []const u8, start_idx: usize) ?usize {
    std.debug.assert(start_idx < lines.len);
    std.debug.assert(lines.len < 1_000_000); // sanity: never a runaway file

    var depth: i32 = 0;
    var started = false;
    var i = start_idx;
    var iterations: u32 = 0;
    while (i < lines.len) : (i += 1) {
        std.debug.assert(iterations < measure_lines_max);
        iterations += 1;
        const new_depth = depth + braceDelta(lines[i]);
        if (!started and new_depth > 0) started = true;
        depth = new_depth;
        if (started and depth <= 0) {
            const span = i - start_idx + 1;
            std.debug.assert(span >= 1);
            std.debug.assert(span <= lines.len - start_idx);
            return span;
        }
    }
    return null;
}

/// Returns the portion of `line` before a `//` line comment, using the same
/// string/char-literal tracking as `braceDelta` so a `//` inside a string
/// literal does not truncate real code. A multiline string literal line
/// (`isMultilineStringLine`) has no code of its own and returns empty.
pub fn stripLineComment(line: []const u8) []const u8 {
    std.debug.assert(line.len < 1_000_000); // sanity: never an absurd line
    if (isMultilineStringLine(line)) return line[0..0];

    var in_string = false;
    var in_char = false;
    var i: usize = 0;
    while (i < line.len) : (i += 1) {
        const c = line[i];
        if (in_string) {
            if (c == '\\') i += 1 else if (c == '"') in_string = false;
            continue;
        }
        if (in_char) {
            if (c == '\\') i += 1 else if (c == '\'') in_char = false;
            continue;
        }
        switch (c) {
            '/' => if (i + 1 < line.len and line[i + 1] == '/') return line[0..i],
            '"' => in_string = true,
            '\'' => in_char = true,
            else => {},
        }
    }

    std.debug.assert(i == line.len);
    return line;
}

// -- splitLines --------------------------------------------------------------

test "splitLines trims a trailing newline" {
    const gpa = std.testing.allocator;
    const lines = try splitLines(gpa, "a\nb\nc\n");
    defer gpa.free(lines);
    try std.testing.expectEqual(@as(usize, 3), lines.len);
    try std.testing.expectEqualStrings("a", lines[0]);
    try std.testing.expectEqualStrings("b", lines[1]);
    try std.testing.expectEqualStrings("c", lines[2]);
}

test "splitLines strips a trailing carriage return from CRLF line endings" {
    const gpa = std.testing.allocator;
    const lines = try splitLines(gpa, "a\r\nb\r\n");
    defer gpa.free(lines);
    try std.testing.expectEqual(@as(usize, 2), lines.len);
    try std.testing.expectEqualStrings("a", lines[0]);
    try std.testing.expectEqualStrings("b", lines[1]);
}

test "splitLines returns zero lines for empty content" {
    const gpa = std.testing.allocator;
    const lines = try splitLines(gpa, "");
    defer gpa.free(lines);
    try std.testing.expectEqual(@as(usize, 0), lines.len);
}

test "splitLines yields the final line even without a trailing newline" {
    const gpa = std.testing.allocator;
    const lines = try splitLines(gpa, "a\nb");
    defer gpa.free(lines);
    try std.testing.expectEqual(@as(usize, 2), lines.len);
    try std.testing.expectEqualStrings("a", lines[0]);
    try std.testing.expectEqualStrings("b", lines[1]);
}

// -- extractFnName -----------------------------------------------------------

test "extractFnName finds the name from a pub fn opener" {
    const got = extractFnName("pub fn foo(a: u32) void {");
    try std.testing.expect(got != null);
    try std.testing.expectEqualStrings("foo", got.?);
}

test "extractFnName finds the name from a private fn opener" {
    const got = extractFnName("fn bar() void {");
    try std.testing.expect(got != null);
    try std.testing.expectEqualStrings("bar", got.?);
}

test "extractFnName is null for a call site, not a function opener" {
    try std.testing.expect(extractFnName("const x = fnLike(1);") == null);
}

test "extractFnName is null for an unnamed fn literal" {
    try std.testing.expect(extractFnName("fn (a: u32) void {") == null);
}

// -- braceDelta ----------------------------------------------------------------

test "braceDelta counts a plain opening and closing brace" {
    try std.testing.expectEqual(@as(i32, 1), braceDelta("fn foo() void {"));
    try std.testing.expectEqual(@as(i32, -1), braceDelta("}"));
    try std.testing.expectEqual(@as(i32, 0), braceDelta("const x = 1;"));
}

test "braceDelta ignores braces inside a string literal" {
    try std.testing.expectEqual(@as(i32, 0), braceDelta("const s = \"{}\";"));
}

test "braceDelta ignores braces inside a char literal" {
    try std.testing.expectEqual(@as(i32, 0), braceDelta("const c = '{';"));
}

test "braceDelta ignores braces after a line comment" {
    try std.testing.expectEqual(@as(i32, 0), braceDelta("// a comment with { brace }"));
}

test "braceDelta ignores braces on a multiline string literal line" {
    try std.testing.expectEqual(@as(i32, 0), braceDelta("    \\\\ this { is } text"));
}

// -- measureFunctionLines -------------------------------------------------------

test "measureFunctionLines counts the inclusive span of a short function" {
    const lines = [_][]const u8{
        "fn foo() void {",
        "    doA();",
        "    doB();",
        "}",
    };
    try std.testing.expectEqual(@as(?usize, 4), measureFunctionLines(&lines, 0));
}

test "measureFunctionLines returns null for an unterminated function" {
    const lines = [_][]const u8{ "fn foo() void {", "    doA();" };
    try std.testing.expectEqual(@as(?usize, null), measureFunctionLines(&lines, 0));
}
