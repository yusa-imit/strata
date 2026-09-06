//! strata's copy of the kingdom reference `tidy` lint, trimmed to the shape milestone
//! (plan `docs/plans/001-zig-0.16-and-tiger-baseline.md`, item 2): line length and doc
//! header only. Function length, the ban list, and file length land in a later item.
//! Single file, zero dependencies. Walks `src/`, `build.zig`, `bench/`, `tests/` under
//! `--root` (default `.`), skipping `.zig-cache`, `zig-out`, `zig-pkg`, lints every
//! `.zig` file found, prints the report to stdout, and exits 1 on any finding.
//! Built for Zig 0.15.2 (`std.fs`); no allocator is retained past `main`'s own arena.

const std = @import("std");
const Allocator = std.mem.Allocator;

pub const Finding = struct {
    path: []const u8,
    line: usize,
    rule: []const u8, // "line-length" or "doc-header"
    message: []const u8,
};

const max_line_len: usize = 100;

/// Splits `content` into lines (without trailing `\n` or `\r`), as slices into
/// `content`. Caller frees the returned slice with `allocator`.
pub fn splitLines(allocator: Allocator, content: []const u8) ![][]const u8 {
    std.debug.assert(@intFromPtr(content.ptr) != 0 or content.len == 0);
    var out: std.ArrayList([]const u8) = .empty;
    errdefer out.deinit(allocator);

    if (content.len == 0) return out.toOwnedSlice(allocator);

    var it = std.mem.splitScalar(u8, content, '\n');
    while (it.next()) |raw| {
        const line = if (raw.len > 0 and raw[raw.len - 1] == '\r') raw[0 .. raw.len - 1] else raw;
        try out.append(allocator, line);
    }
    // `splitScalar` yields a trailing empty segment after a final '\n'; drop it so
    // content ending in a newline does not report a phantom empty last line.
    if (out.items.len > 0 and out.items[out.items.len - 1].len == 0 and
        content.len > 0 and content[content.len - 1] == '\n')
    {
        _ = out.pop();
    }

    const result = try out.toOwnedSlice(allocator);
    std.debug.assert(result.len == 0 or content.len > 0);
    return result;
}

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

/// Renders every finding as `path:line: rule: message\n`, then a summary line
/// `tidy: N finding(s)\n`. Caller frees the result with `allocator`.
pub fn formatFindings(allocator: Allocator, findings: []const Finding) ![]u8 {
    std.debug.assert(findings.len < 1_000_000); // sanity: never a runaway report
    var buf: std.ArrayList(u8) = .empty;
    errdefer buf.deinit(allocator);

    for (findings) |f| {
        try buf.print(allocator, "{s}:{d}: {s}: {s}\n", .{ f.path, f.line, f.rule, f.message });
    }
    try buf.print(allocator, "tidy: {d} finding(s)\n", .{findings.len});

    const out = try buf.toOwnedSlice(allocator);
    std.debug.assert(out.len > 0);
    return out;
}

// ---------------------------------------------------------------------------
// Filesystem glue (std.fs, Zig 0.15.2). Bounded, non-recursive directory walk:
// a `queue` of relative directory paths stands in for the explicit bounded
// stack Tiger Style requires in place of recursion (`dir_queue_max`).
// ---------------------------------------------------------------------------

const max_file_bytes: usize = 8 * 1024 * 1024;
const dir_queue_max: u32 = 4096;
const scan_roots = [_][]const u8{ "src", "bench", "tests" };

fn shouldSkipDirName(name: []const u8) bool {
    return std.mem.eql(u8, name, ".zig-cache") or
        std.mem.eql(u8, name, "zig-out") or
        std.mem.eql(u8, name, "zig-pkg");
}

fn shouldCollectFile(name: []const u8) bool {
    return std.mem.endsWith(u8, name, ".zig");
}

/// Iterates one already-open directory at relative path `rel`, pushing every
/// subdirectory back onto `queue` (skipping names `shouldSkipDirName` flags)
/// and appending every `.zig` file it finds to `out`.
fn walkOneDir(
    gpa: Allocator,
    root: std.fs.Dir,
    rel: []const u8,
    queue: *std.ArrayList([]const u8),
    out: *std.ArrayList([]const u8),
) !void {
    std.debug.assert(rel.len > 0);
    var dir = root.openDir(rel, .{ .iterate = true }) catch return;
    defer dir.close();

    var it = dir.iterate();
    while (try it.next()) |entry| {
        if (entry.kind == .directory and shouldSkipDirName(entry.name)) continue;
        if (entry.kind != .directory and entry.kind != .file) continue;
        const child = try std.fmt.allocPrint(gpa, "{s}/{s}", .{ rel, entry.name });
        switch (entry.kind) {
            .directory => try queue.append(gpa, child),
            .file => if (shouldCollectFile(entry.name)) {
                try out.append(gpa, child);
            } else gpa.free(child),
            else => unreachable, // proof: filtered to directory/file above
        }
    }
    std.debug.assert(rel.len > 0);
}

/// Walks the subtree rooted at `start` (relative to `root`), breadth-first,
/// using an explicit `queue` instead of recursion. Bounded by `dir_queue_max`
/// directories visited; a subtree with more nested directories than that is
/// treated as a programmer error, not a data error, since it never occurs in
/// this repo's own layout.
fn walkDir(
    gpa: Allocator,
    root: std.fs.Dir,
    start: []const u8,
    out: *std.ArrayList([]const u8),
) !void {
    std.debug.assert(start.len > 0);
    var queue: std.ArrayList([]const u8) = .empty;
    defer queue.deinit(gpa);
    try queue.append(gpa, try gpa.dupe(u8, start));

    var iterations: u32 = 0;
    while (queue.pop()) |rel| {
        std.debug.assert(iterations < dir_queue_max);
        iterations += 1;
        try walkOneDir(gpa, root, rel, &queue, out);
    }
    std.debug.assert(queue.items.len == 0);
}

fn collectTopLevel(
    gpa: Allocator,
    root: std.fs.Dir,
    name: []const u8,
    out: *std.ArrayList([]const u8),
) !void {
    std.debug.assert(name.len > 0);
    root.access(name, .{}) catch return;
    try out.append(gpa, try gpa.dupe(u8, name));
    std.debug.assert(out.items.len > 0);
}

/// Collects every `.zig` file under `src/`, `bench/`, `tests/`, plus the
/// top-level `build.zig` when present, relative to `root`. Caller frees the
/// returned slice (and each element) with `gpa`.
fn collectFiles(gpa: Allocator, root: std.fs.Dir) ![][]const u8 {
    var out: std.ArrayList([]const u8) = .empty;
    errdefer out.deinit(gpa);

    try collectTopLevel(gpa, root, "build.zig", &out);
    for (scan_roots) |name| try walkDir(gpa, root, name, &out);

    const result = try out.toOwnedSlice(gpa);
    std.debug.assert(scan_roots.len == 3);
    return result;
}

fn parseRootArg(args: []const []const u8) []const u8 {
    std.debug.assert(args.len < 1_000_000); // sanity: never a runaway argv
    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        if (std.mem.eql(u8, args[i], "--root") and i + 1 < args.len) return args[i + 1];
    }
    return ".";
}

/// Lints one file's already-read `content`, appending every finding onto
/// `findings`. Frees its own intermediate allocations before returning.
fn lintFile(
    gpa: Allocator,
    path: []const u8,
    content: []const u8,
    findings: *std.ArrayList(Finding),
) !void {
    std.debug.assert(path.len > 0);
    const lines = try splitLines(gpa, content);
    defer gpa.free(lines);

    const length_findings = try checkLineLength(gpa, path, lines);
    defer gpa.free(length_findings);
    for (length_findings) |f| try findings.append(gpa, f);

    const header_findings = try checkDocHeader(gpa, path, lines);
    defer gpa.free(header_findings);
    for (header_findings) |f| try findings.append(gpa, f);

    std.debug.assert(lines.len < 1_000_000); // sanity: matches formatFindings' bound
}

/// Reads and lints every collected `paths`, skipping (not failing on) a path
/// that fails to read — a file removed between the walk and the read is not
/// this tool's problem to report.
fn lintAllFiles(
    gpa: Allocator,
    root_dir: std.fs.Dir,
    paths: []const []const u8,
    findings: *std.ArrayList(Finding),
) !void {
    std.debug.assert(paths.len < 1_000_000);
    for (paths) |p| {
        const content = root_dir.readFileAlloc(gpa, p, max_file_bytes) catch continue;
        defer gpa.free(content);

        try lintFile(gpa, p, content, findings);
    }
    std.debug.assert(findings.items.len < 1_000_000);
}

/// Entry point: walks `--root` (default `.`), lints every `.zig` file found,
/// prints the report to stdout, and exits 1 if any finding was reported.
pub fn main() !void {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const gpa = arena.allocator();

    const raw_args = try std.process.argsAlloc(gpa);
    const root = parseRootArg(raw_args[@min(1, raw_args.len)..]);
    std.debug.assert(root.len > 0);

    var root_dir = try std.fs.cwd().openDir(root, .{ .iterate = true });
    defer root_dir.close();

    const paths = try collectFiles(gpa, root_dir);

    var findings: std.ArrayList(Finding) = .empty;
    try lintAllFiles(gpa, root_dir, paths, &findings);

    const report = try formatFindings(gpa, findings.items);
    try std.fs.File.stdout().writeAll(report);

    std.debug.assert(findings.items.len < 1_000_000);
    if (findings.items.len > 0) std.posix.exit(1);
}

// ---------------------------------------------------------------------------
// Unit tests. All in-memory; no filesystem access. `zig test tools/tidy.zig`
// must show these RED against the stub bodies above.
// ---------------------------------------------------------------------------

fn freeFindings(allocator: Allocator, findings: []Finding) void {
    for (findings) |f| allocator.free(f.message);
    allocator.free(findings);
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

// -- checkLineLength -----------------------------------------------------------

test "checkLineLength passes a line at exactly the 100 code point limit" {
    const gpa = std.testing.allocator;
    const exactly_100 = "x" ** 100;
    const findings = try checkLineLength(gpa, "src/a.zig", &.{exactly_100});
    defer freeFindings(gpa, findings);
    try std.testing.expectEqual(@as(usize, 0), findings.len);
}

test "checkLineLength fails a line one code point past the limit" {
    const gpa = std.testing.allocator;
    const over_by_one = "x" ** 101;
    const findings = try checkLineLength(gpa, "src/a.zig", &.{over_by_one});
    defer freeFindings(gpa, findings);
    try std.testing.expectEqual(@as(usize, 1), findings.len);
    try std.testing.expectEqualStrings("line-length", findings[0].rule);
    try std.testing.expectEqual(@as(usize, 1), findings[0].line);
}

test "checkLineLength counts Unicode code points, not encoded bytes" {
    const gpa = std.testing.allocator;
    // "é" is 2 bytes in UTF-8; 100 of them is 200 bytes but only 100 code
    // points, so this must pass despite being well over 100 bytes long.
    const hundred_codepoints_two_hundred_bytes = "é" ** 100;
    const findings = try checkLineLength(gpa, "src/a.zig", &.{hundred_codepoints_two_hundred_bytes});
    defer freeFindings(gpa, findings);
    try std.testing.expectEqual(@as(usize, 0), findings.len);
    try std.testing.expect(hundred_codepoints_two_hundred_bytes.len > max_line_len);
}

test "checkLineLength passes an empty line" {
    const gpa = std.testing.allocator;
    const findings = try checkLineLength(gpa, "src/a.zig", &.{""});
    defer freeFindings(gpa, findings);
    try std.testing.expectEqual(@as(usize, 0), findings.len);
}

test "checkLineLength reports one finding per long line at correct 1-indexed lines" {
    const gpa = std.testing.allocator;
    const short = "ok";
    const long_a = "a" ** 150;
    const long_b = "b" ** 200;
    const findings = try checkLineLength(gpa, "src/a.zig", &.{ short, long_a, short, long_b });
    defer freeFindings(gpa, findings);
    try std.testing.expectEqual(@as(usize, 2), findings.len);
    try std.testing.expectEqual(@as(usize, 2), findings[0].line);
    try std.testing.expectEqualStrings("line-length", findings[0].rule);
    try std.testing.expectEqual(@as(usize, 4), findings[1].line);
    try std.testing.expectEqualStrings("line-length", findings[1].rule);
}

test "checkLineLength is silent on an entirely clean file" {
    const gpa = std.testing.allocator;
    const findings = try checkLineLength(gpa, "src/a.zig", &.{ "const a = 1;", "", "// fine" });
    defer freeFindings(gpa, findings);
    try std.testing.expectEqual(@as(usize, 0), findings.len);
}

// -- checkDocHeader --------------------------------------------------------

test "checkDocHeader fails a src/ file whose first line is not a //! comment" {
    const gpa = std.testing.allocator;
    const findings = try checkDocHeader(gpa, "src/a.zig", &.{"const x = 1;"});
    defer freeFindings(gpa, findings);
    try std.testing.expectEqual(@as(usize, 1), findings.len);
    try std.testing.expectEqualStrings("doc-header", findings[0].rule);
    try std.testing.expectEqual(@as(usize, 1), findings[0].line);
}

test "checkDocHeader passes a src/ file that opens with a //! comment" {
    const gpa = std.testing.allocator;
    const findings = try checkDocHeader(gpa, "src/a.zig", &.{ "//! doc", "const x = 1;" });
    defer freeFindings(gpa, findings);
    try std.testing.expectEqual(@as(usize, 0), findings.len);
}

test "checkDocHeader exempts files outside src/ regardless of their first line" {
    const gpa = std.testing.allocator;

    const build_zig = try checkDocHeader(gpa, "build.zig", &.{"const std = @import(\"std\");"});
    defer freeFindings(gpa, build_zig);
    try std.testing.expectEqual(@as(usize, 0), build_zig.len);

    const tools_file = try checkDocHeader(gpa, "tools/x.zig", &.{"const x = 1;"});
    defer freeFindings(gpa, tools_file);
    try std.testing.expectEqual(@as(usize, 0), tools_file.len);
}

test "checkDocHeader fails an empty src/ file (no first line to carry a header)" {
    const gpa = std.testing.allocator;
    const findings = try checkDocHeader(gpa, "src/empty.zig", &.{});
    defer freeFindings(gpa, findings);
    try std.testing.expectEqual(@as(usize, 1), findings.len);
    try std.testing.expectEqual(@as(usize, 1), findings[0].line);
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
    const expected = "src/a.zig:1: doc-header: file under src/ must start with a `//!` doc comment\n" ++
        "src/a.zig:5: line-length: line is 101 columns (limit 100)\n" ++
        "tidy: 2 finding(s)\n";
    try std.testing.expectEqualStrings(expected, out);
}
