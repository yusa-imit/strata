//! strata's copy of the kingdom reference `tidy` lint (plan
//! `docs/plans/001-zig-0.16-and-tiger-baseline.md`, items 2 and 3): line
//! length, doc header, function length with a shrink-only red-zone
//! baseline, a three-rule ban list, and the wire-format `usize` check.
//! Single file, zero dependencies. Walks `src/`, `build.zig`, `bench/`,
//! `tests/` under `--root` (default `.`), skipping `.zig-cache`, `zig-out`,
//! `zig-pkg`, loads `--baseline` (default `tools/tidy_baseline.txt`, a
//! missing file means an empty baseline), lints every `.zig` file found,
//! prints the report to stdout, and exits 1 on any finding.
//! Built for Zig 0.15.2 (`std.fs`); no allocator is retained past `main`'s own arena.

const std = @import("std");
const Allocator = std.mem.Allocator;

pub const Finding = struct {
    path: []const u8,
    line: usize,
    rule: []const u8, // "line-length", "doc-header", "function-length", "stale-baseline",
    // "ban-list", or "wire-format-usize".
    message: []const u8,
    // Non-null on ban-list and function-length findings: a suggested fix to
    // print alongside the message.
    replacement: ?[]const u8 = null,
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

// ---------------------------------------------------------------------------
// Function length (with a red-zone baseline exception), the ban list, and
// the wire-format usize check (plan `001`, item 3: "tidy step, part 2 —
// limits and ban list"). See `citadel/templates/tidy/tidy.zig` for prior
// art on the eventual shapes (this file's rules deliberately differ in
// places — e.g. the hard 73-line ceiling the baseline can never rescue).
// ---------------------------------------------------------------------------

fn isIdentChar(c: u8) bool {
    return std.ascii.isAlphanumeric(c) or c == '_';
}

/// Finds the name of a function declared as `fn name(` on this line (no
/// space between the name and the opening paren, per Zig style). Returns
/// null when the line does not open a named function.
pub fn extractFnName(line: []const u8) ?[]const u8 {
    std.debug.assert(line.len < 1_000_000); // sanity: never an absurd line
    const idx = std.mem.indexOf(u8, line, "fn ") orelse return null;
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

/// The actual, currently-measured span of one scanned function, recorded so
/// `reconcileBaseline` can later compare it against the baseline.
pub const ActualLen = struct { line: usize, len: usize };

/// Parsed `tidy_baseline.txt`: maps `"path:fn_name"` to a recorded line
/// count. An entry only ever rescues the 71-72 "red zone" (see
/// `checkFunctionLength`) — it can never rescue a function at or above 73
/// lines.
pub const Baseline = struct {
    entries: std.StringHashMap(usize),

    pub fn init(allocator: Allocator) Baseline {
        return .{ .entries = std.StringHashMap(usize).init(allocator) };
    }

    pub fn deinit(self: *Baseline, allocator: Allocator) void {
        var it = self.entries.keyIterator();
        while (it.next()) |k| allocator.free(k.*);
        self.entries.deinit();
    }

    pub fn get(self: Baseline, key: []const u8) ?usize {
        return self.entries.get(key);
    }

    /// Parses `path:fn_name:lines` lines. Blank lines and lines starting
    /// with `#` are ignored.
    pub fn parse(allocator: Allocator, content: []const u8) !Baseline {
        std.debug.assert(content.len < 100 * 1024 * 1024); // sanity: never a runaway file
        var self = Baseline.init(allocator);
        errdefer self.deinit(allocator);

        var it = std.mem.splitScalar(u8, content, '\n');
        while (it.next()) |raw| {
            const line = std.mem.trim(u8, raw, " \t\r");
            if (line.len == 0 or line[0] == '#') continue;
            try self.parseLine(allocator, line);
        }

        std.debug.assert(self.entries.count() < 1_000_000); // sanity: never a runaway baseline
        return self;
    }

    fn parseLine(self: *Baseline, allocator: Allocator, line: []const u8) !void {
        std.debug.assert(line.len > 0);
        const last_colon = std.mem.lastIndexOfScalar(u8, line, ':') orelse return;
        const lines_str = line[last_colon + 1 ..];
        const key_part = line[0..last_colon];
        const lines_n = std.fmt.parseInt(usize, lines_str, 10) catch return;
        std.debug.assert(key_part.len < line.len);

        const key = try allocator.dupe(u8, key_part);
        const gop = try self.entries.getOrPut(key);
        if (gop.found_existing) allocator.free(key);
        gop.value_ptr.* = lines_n;
    }
};

/// Check: a function body over 70 lines is a finding; 71-72 lines (the "red
/// zone") is a finding unless `baseline` has an entry for `"path:fn_name"`;
/// 73+ lines is always a finding, even when baselined — the exception table
/// can only ever rescue the red zone. Records every scanned function's
/// actual span into `actual_out`, keyed `"path:fn_name"`, regardless of
/// whether it passed or failed.
const fn_len_clean_max: usize = 70;
const fn_len_redzone_max: usize = 72;

fn appendFunctionLengthFinding(
    out: *std.ArrayList(Finding),
    allocator: Allocator,
    path: []const u8,
    line: usize,
    name: []const u8,
    len: usize,
) !void {
    std.debug.assert(name.len > 0);
    const msg = try std.fmt.allocPrint(
        allocator,
        "fn `{s}` is {d} lines (limit {d})",
        .{ name, len, fn_len_clean_max },
    );
    try out.append(allocator, .{
        .path = path,
        .line = line,
        .rule = "function-length",
        .message = msg,
        .replacement = "shorten it, or add `path:fn:lines` to tidy_baseline.txt",
    });
}

/// Check: a function body over 70 lines is a finding; 71-72 lines (the "red
/// zone") is a finding unless `baseline` has an entry for `"path:fn_name"`;
/// 73+ lines is always a finding, even when baselined — the exception table
/// can only ever rescue the red zone. Records every scanned function's
/// actual span into `actual_out`, keyed `"path:fn_name"`, regardless of
/// whether it passed or failed.
pub fn checkFunctionLength(
    allocator: Allocator,
    path: []const u8,
    lines: []const []const u8,
    baseline: Baseline,
    actual_out: *std.StringHashMap(ActualLen),
) ![]Finding {
    std.debug.assert(path.len > 0);
    var out: std.ArrayList(Finding) = .empty;
    errdefer out.deinit(allocator);

    var idx: usize = 0;
    while (idx < lines.len) : (idx += 1) {
        const name = extractFnName(lines[idx]) orelse continue;
        const len = measureFunctionLines(lines, idx) orelse continue;

        const key = try std.fmt.allocPrint(allocator, "{s}:{s}", .{ path, name });
        const gop = try actual_out.getOrPut(key);
        if (gop.found_existing) allocator.free(key);
        gop.value_ptr.* = .{ .line = idx + 1, .len = len };

        const in_redzone = len > fn_len_clean_max and len <= fn_len_redzone_max;
        const over_ceiling = len > fn_len_redzone_max;
        if (over_ceiling or (in_redzone and baseline.get(key) == null)) {
            try appendFunctionLengthFinding(&out, allocator, path, idx + 1, name, len);
        }
    }

    const result = try out.toOwnedSlice(allocator);
    std.debug.assert(result.len <= lines.len);
    return result;
}

/// One baseline entry's reconciliation against `actual` (see
/// `reconcileBaseline`).
fn reconcileOne(
    out: *std.ArrayList(Finding),
    allocator: Allocator,
    key: []const u8,
    actual: std.StringHashMap(ActualLen),
) !void {
    std.debug.assert(key.len > 0);
    const path = if (std.mem.lastIndexOfScalar(u8, key, ':')) |i| key[0..i] else key;

    const found = actual.get(key) orelse {
        const msg = try std.fmt.allocPrint(
            allocator,
            "baseline entry `{s}` matches no function",
            .{key},
        );
        try out.append(allocator, .{ .path = path, .line = 1, .rule = "stale-baseline", .message = msg });
        return;
    };

    if (found.len <= fn_len_clean_max) {
        const msg = try std.fmt.allocPrint(
            allocator,
            "`{s}` shrank to {d} lines; remove it from tidy_baseline.txt",
            .{ key, found.len },
        );
        try out.append(allocator, .{ .path = path, .line = found.line, .rule = "stale-baseline", .message = msg });
    } else if (found.len > fn_len_redzone_max) {
        const msg = try std.fmt.allocPrint(
            allocator,
            "`{s}` is {d} lines; the baseline cannot rescue the hard ceiling",
            .{ key, found.len },
        );
        try out.append(allocator, .{ .path = path, .line = found.line, .rule = "stale-baseline", .message = msg });
    }
}

/// After a full scan, compares every baseline entry against `actual`: an
/// entry whose function shrank to 70 lines or fewer, or grew to 73 lines or
/// more, or matches no function in `actual` at all, is a `"stale-baseline"`
/// finding. An entry whose function is still legitimately in the 71-72
/// range is silent.
pub fn reconcileBaseline(
    allocator: Allocator,
    baseline: Baseline,
    actual: std.StringHashMap(ActualLen),
) ![]Finding {
    std.debug.assert(baseline.entries.count() < 1_000_000); // sanity: never a runaway baseline
    var out: std.ArrayList(Finding) = .empty;
    errdefer out.deinit(allocator);

    var it = baseline.entries.iterator();
    while (it.next()) |entry| {
        try reconcileOne(&out, allocator, entry.key_ptr.*, actual);
    }

    const result = try out.toOwnedSlice(allocator);
    std.debug.assert(result.len <= baseline.entries.count());
    return result;
}

const BanId = enum { catch_unreachable, debug_print, time_call };
const BanRule = struct { id: BanId, needle: []const u8, replacement: []const u8 };

const ban_rules = [_]BanRule{
    .{
        .id = .catch_unreachable,
        .needle = "catch unreachable",
        .replacement = "handle the error, or add `// proof:` on this or the previous line",
    },
    .{
        .id = .debug_print,
        .needle = "std.debug.print(",
        .replacement = "use a real logger instead (src/main.zig and bench/ are exempt)",
    },
    .{
        .id = .time_call,
        .needle = "std.time.",
        .replacement = "inject a clock dependency instead of calling std.time from src/",
    },
};

fn isMainZig(path: []const u8) bool {
    return std.mem.eql(u8, path, "src/main.zig");
}

fn underDir(path: []const u8, dir: []const u8) bool {
    return std.mem.startsWith(u8, path, dir) and
        path.len > dir.len and path[dir.len] == '/';
}

fn banApplies(id: BanId, path: []const u8) bool {
    return switch (id) {
        .catch_unreachable => true,
        .debug_print => !(isMainZig(path) or underDir(path, "bench")),
        .time_call => std.mem.startsWith(u8, path, "src/") and !isMainZig(path),
    };
}

fn hasProofComment(lines: []const []const u8, idx: usize) bool {
    std.debug.assert(idx < lines.len);
    if (std.mem.indexOf(u8, lines[idx], "// proof:") != null) return true;
    return idx > 0 and std.mem.indexOf(u8, lines[idx - 1], "// proof:") != null;
}

/// Check: flags exactly three banned spellings for this plan item (later
/// items extend this same list) — `catch unreachable` without a `//
/// proof:` comment on the same or previous line, `std.debug.print(` outside
/// `src/main.zig`/`bench/`, and `std.time.` under `src/` outside
/// `src/main.zig`. Every finding carries a non-null `.replacement`.
pub fn checkBanList(allocator: Allocator, path: []const u8, lines: []const []const u8) ![]Finding {
    std.debug.assert(path.len > 0);
    var out: std.ArrayList(Finding) = .empty;
    errdefer out.deinit(allocator);

    for (lines, 0..) |line, idx| {
        for (ban_rules) |rule| {
            if (std.mem.indexOf(u8, line, rule.needle) == null) continue;
            if (!banApplies(rule.id, path)) continue;
            if (rule.id == .catch_unreachable and hasProofComment(lines, idx)) continue;

            const msg = try std.fmt.allocPrint(allocator, "banned pattern `{s}`", .{rule.needle});
            try out.append(allocator, .{
                .path = path,
                .line = idx + 1,
                .rule = "ban-list",
                .message = msg,
                .replacement = rule.replacement,
            });
        }
    }

    const result = try out.toOwnedSlice(allocator);
    std.debug.assert(result.len <= lines.len * ban_rules.len);
    return result;
}

/// Returns true when `line` contains the word `usize` at a token boundary
/// (not as a substring of a longer identifier such as `bitsize`).
fn hasBareUsize(line: []const u8) bool {
    std.debug.assert(line.len < 1_000_000); // sanity: never an absurd line
    const needle = "usize";
    var start: usize = 0;
    while (std.mem.indexOfPos(u8, line, start, needle)) |i| {
        const before_ok = i == 0 or !isIdentChar(line[i - 1]);
        const after_idx = i + needle.len;
        const after_ok = after_idx >= line.len or !isIdentChar(line[after_idx]);
        if (before_ok and after_ok) return true;
        start = i + 1;
    }
    return false;
}

/// Check: flags the bare word `usize` (word-boundary, not a substring of a
/// longer identifier) appearing inside a scope opened by a `// wire-format`
/// marker comment immediately followed by a line that opens a struct (a
/// positive `braceDelta`), tracked back to zero exactly like
/// `measureFunctionLines` does for functions. On-disk formats are
/// fixed-width, so `usize` inside such a scope must become `u32`/`u64`.
pub fn checkWireFormatUsize(allocator: Allocator, path: []const u8, lines: []const []const u8) ![]Finding {
    std.debug.assert(path.len > 0);
    std.debug.assert(lines.len < 1_000_000); // sanity: never a runaway file
    var out: std.ArrayList(Finding) = .empty;
    errdefer out.deinit(allocator);

    var idx: usize = 0;
    while (idx < lines.len) : (idx += 1) {
        if (std.mem.indexOf(u8, lines[idx], "// wire-format") == null) continue;
        const open_idx = idx + 1;
        if (open_idx >= lines.len or braceDelta(lines[open_idx]) <= 0) continue;

        const span = measureFunctionLines(lines, open_idx) orelse continue;
        const end_idx = open_idx + span - 1;
        std.debug.assert(end_idx < lines.len);

        var j = open_idx + 1;
        while (j < end_idx) : (j += 1) {
            if (!hasBareUsize(lines[j])) continue;
            const msg = try allocator.dupe(u8, "`usize` in a wire-format struct varies by target width");
            try out.append(allocator, .{
                .path = path,
                .line = j + 1,
                .rule = "wire-format-usize",
                .message = msg,
                .replacement = "use an explicit u32/u64 instead of usize",
            });
        }
    }

    const result = try out.toOwnedSlice(allocator);
    std.debug.assert(result.len <= lines.len);
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

const default_baseline_path = "tools/tidy_baseline.txt";

fn parseBaselineArg(args: []const []const u8) []const u8 {
    std.debug.assert(args.len < 1_000_000); // sanity: never a runaway argv
    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        if (std.mem.eql(u8, args[i], "--baseline") and i + 1 < args.len) return args[i + 1];
    }
    return default_baseline_path;
}

/// Reads and parses the baseline file at `path` (relative to `root_dir`); a
/// missing file is an empty baseline, not an error — a fresh checkout with
/// no red-zone exceptions yet is the expected common case.
fn loadBaseline(gpa: Allocator, root_dir: std.fs.Dir, path: []const u8) !Baseline {
    std.debug.assert(path.len > 0);
    const content = root_dir.readFileAlloc(gpa, path, max_file_bytes) catch |err| switch (err) {
        error.FileNotFound => return Baseline.init(gpa),
        else => return err,
    };
    const baseline = try Baseline.parse(gpa, content);
    std.debug.assert(baseline.entries.count() < 1_000_000); // sanity: matches parse's own bound
    return baseline;
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

    const ban_findings = try checkBanList(gpa, path, lines);
    defer gpa.free(ban_findings);
    for (ban_findings) |f| try findings.append(gpa, f);

    const wire_findings = try checkWireFormatUsize(gpa, path, lines);
    defer gpa.free(wire_findings);
    for (wire_findings) |f| try findings.append(gpa, f);

    std.debug.assert(lines.len < 1_000_000); // sanity: matches formatFindings' bound
}

/// Reads and lints every collected `paths`, skipping (not failing on) a path
/// that fails to read — a file removed between the walk and the read is not
/// this tool's problem to report.
/// Lints one already-read file's line-based checks that need the shared
/// baseline (`checkFunctionLength`), appending onto `findings`. Kept apart
/// from `lintFile` because that function's signature is pinned by its own
/// unit tests to `(gpa, path, content, findings)` with no baseline.
fn lintFileFunctionLength(
    gpa: Allocator,
    path: []const u8,
    content: []const u8,
    baseline: Baseline,
    actual_out: *std.StringHashMap(ActualLen),
    findings: *std.ArrayList(Finding),
) !void {
    std.debug.assert(path.len > 0);
    const lines = try splitLines(gpa, content);
    defer gpa.free(lines);

    const fn_findings = try checkFunctionLength(gpa, path, lines, baseline, actual_out);
    defer gpa.free(fn_findings);
    for (fn_findings) |f| try findings.append(gpa, f);

    std.debug.assert(lines.len < 1_000_000); // sanity: matches lintFile's own bound
}

fn lintAllFiles(
    gpa: Allocator,
    root_dir: std.fs.Dir,
    paths: []const []const u8,
    baseline: Baseline,
    actual_out: *std.StringHashMap(ActualLen),
    findings: *std.ArrayList(Finding),
) !void {
    std.debug.assert(paths.len < 1_000_000);
    for (paths) |p| {
        const content = root_dir.readFileAlloc(gpa, p, max_file_bytes) catch continue;
        defer gpa.free(content);

        try lintFile(gpa, p, content, findings);
        try lintFileFunctionLength(gpa, p, content, baseline, actual_out, findings);
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
    const args = raw_args[@min(1, raw_args.len)..];
    const root = parseRootArg(args);
    const baseline_path = parseBaselineArg(args);
    std.debug.assert(root.len > 0);
    std.debug.assert(baseline_path.len > 0);

    var root_dir = try std.fs.cwd().openDir(root, .{ .iterate = true });
    defer root_dir.close();

    const baseline = try loadBaseline(gpa, root_dir, baseline_path);
    const paths = try collectFiles(gpa, root_dir);

    var findings: std.ArrayList(Finding) = .empty;
    var actual = std.StringHashMap(ActualLen).init(gpa);
    try lintAllFiles(gpa, root_dir, paths, baseline, &actual, &findings);

    const stale_findings = try reconcileBaseline(gpa, baseline, actual);
    for (stale_findings) |f| try findings.append(gpa, f);

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

fn freeActualMap(allocator: Allocator, map: *std.StringHashMap(ActualLen)) void {
    var it = map.keyIterator();
    while (it.next()) |k| allocator.free(k.*);
    map.deinit();
}

fn freeFindingsList(allocator: Allocator, findings: *std.ArrayList(Finding)) void {
    for (findings.items) |f| allocator.free(f.message);
    findings.deinit(allocator);
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

// ---------------------------------------------------------------------------
// Plan 001 item 3 ("tidy step, part 2 — limits and ban list"): function
// length with a red-zone baseline exception, the ban list, and the
// wire-format usize check. All RED against the stub bodies above.
// ---------------------------------------------------------------------------

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

// -- Baseline ------------------------------------------------------------------

test "Baseline.parse reads multiple path:fn_name:lines entries" {
    const gpa = std.testing.allocator;
    var baseline = try Baseline.parse(gpa, "src/a.zig:foo:71\nsrc/b.zig:bar:72\n");
    defer baseline.deinit(gpa);
    try std.testing.expectEqual(@as(?usize, 71), baseline.get("src/a.zig:foo"));
    try std.testing.expectEqual(@as(?usize, 72), baseline.get("src/b.zig:bar"));
}

test "Baseline.parse skips blank lines and #-prefixed comment lines" {
    const gpa = std.testing.allocator;
    var baseline = try Baseline.parse(gpa, "\n# a comment\nsrc/a.zig:foo:71\n\n# another\n");
    defer baseline.deinit(gpa);
    try std.testing.expectEqual(@as(usize, 1), baseline.entries.count());
    try std.testing.expectEqual(@as(?usize, 71), baseline.get("src/a.zig:foo"));
}

test "Baseline.get is null for a key that was never parsed" {
    const gpa = std.testing.allocator;
    var baseline = try Baseline.parse(gpa, "src/a.zig:foo:71\n");
    defer baseline.deinit(gpa);
    try std.testing.expectEqual(@as(?usize, null), baseline.get("src/a.zig:nope"));
}

// -- checkFunctionLength ---------------------------------------------------------

/// Builds a function whose `measureFunctionLines` span is exactly
/// `total_len`: one opening line, `total_len - 2` body lines, one closing
/// line.
fn fnLinesOfLength(comptime total_len: usize) [total_len][]const u8 {
    var lines: [total_len][]const u8 = undefined;
    lines[0] = "fn sized() void {";
    var i: usize = 1;
    while (i < total_len - 1) : (i += 1) lines[i] = "    doWork();";
    lines[total_len - 1] = "}";
    return lines;
}

test "checkFunctionLength is silent on a 70-line function" {
    const gpa = std.testing.allocator;
    const lines = fnLinesOfLength(70);
    var actual = std.StringHashMap(ActualLen).init(gpa);
    defer freeActualMap(gpa, &actual);
    var baseline = Baseline.init(gpa);
    defer baseline.deinit(gpa);

    const findings = try checkFunctionLength(gpa, "src/a.zig", &lines, baseline, &actual);
    defer freeFindings(gpa, findings);
    try std.testing.expectEqual(@as(usize, 0), findings.len);
}

test "checkFunctionLength fails a 71-line function with no baseline entry" {
    const gpa = std.testing.allocator;
    const lines = fnLinesOfLength(71);
    var actual = std.StringHashMap(ActualLen).init(gpa);
    defer freeActualMap(gpa, &actual);
    var baseline = Baseline.init(gpa);
    defer baseline.deinit(gpa);

    const findings = try checkFunctionLength(gpa, "src/a.zig", &lines, baseline, &actual);
    defer freeFindings(gpa, findings);
    try std.testing.expectEqual(@as(usize, 1), findings.len);
    try std.testing.expectEqualStrings("function-length", findings[0].rule);
}

test "checkFunctionLength passes a 71-line red-zone function listed in the baseline" {
    const gpa = std.testing.allocator;
    const lines = fnLinesOfLength(71);
    var actual = std.StringHashMap(ActualLen).init(gpa);
    defer freeActualMap(gpa, &actual);
    var baseline = try Baseline.parse(gpa, "src/a.zig:sized:71\n");
    defer baseline.deinit(gpa);

    const findings = try checkFunctionLength(gpa, "src/a.zig", &lines, baseline, &actual);
    defer freeFindings(gpa, findings);
    try std.testing.expectEqual(@as(usize, 0), findings.len);
}

test "checkFunctionLength always fails a 73-line function even when baselined" {
    const gpa = std.testing.allocator;
    const lines = fnLinesOfLength(73);
    var actual = std.StringHashMap(ActualLen).init(gpa);
    defer freeActualMap(gpa, &actual);
    var baseline = try Baseline.parse(gpa, "src/a.zig:sized:73\n");
    defer baseline.deinit(gpa);

    const findings = try checkFunctionLength(gpa, "src/a.zig", &lines, baseline, &actual);
    defer freeFindings(gpa, findings);
    try std.testing.expectEqual(@as(usize, 1), findings.len);
    try std.testing.expectEqualStrings("function-length", findings[0].rule);
}

test "checkFunctionLength records every scanned function's actual span regardless of outcome" {
    const gpa = std.testing.allocator;
    const lines = fnLinesOfLength(73);
    var actual = std.StringHashMap(ActualLen).init(gpa);
    defer freeActualMap(gpa, &actual);
    var baseline = try Baseline.parse(gpa, "src/a.zig:sized:73\n");
    defer baseline.deinit(gpa);

    const findings = try checkFunctionLength(gpa, "src/a.zig", &lines, baseline, &actual);
    defer freeFindings(gpa, findings);

    const rec = actual.get("src/a.zig:sized");
    try std.testing.expect(rec != null);
    try std.testing.expectEqual(@as(usize, 1), rec.?.line);
    try std.testing.expectEqual(@as(usize, 73), rec.?.len);
}

// -- reconcileBaseline -----------------------------------------------------------

test "reconcileBaseline flags an entry whose function shrank to 70 lines or fewer" {
    const gpa = std.testing.allocator;
    var baseline = try Baseline.parse(gpa, "src/a.zig:foo:71\n");
    defer baseline.deinit(gpa);
    var actual = std.StringHashMap(ActualLen).init(gpa);
    defer actual.deinit();
    try actual.put("src/a.zig:foo", .{ .line = 4, .len = 65 });

    const findings = try reconcileBaseline(gpa, baseline, actual);
    defer freeFindings(gpa, findings);
    try std.testing.expectEqual(@as(usize, 1), findings.len);
    try std.testing.expectEqualStrings("stale-baseline", findings[0].rule);
}

test "reconcileBaseline flags an entry whose function grew past the 73-line ceiling" {
    const gpa = std.testing.allocator;
    var baseline = try Baseline.parse(gpa, "src/a.zig:foo:71\n");
    defer baseline.deinit(gpa);
    var actual = std.StringHashMap(ActualLen).init(gpa);
    defer actual.deinit();
    try actual.put("src/a.zig:foo", .{ .line = 4, .len = 80 });

    const findings = try reconcileBaseline(gpa, baseline, actual);
    defer freeFindings(gpa, findings);
    try std.testing.expectEqual(@as(usize, 1), findings.len);
    try std.testing.expectEqualStrings("stale-baseline", findings[0].rule);
}

test "reconcileBaseline flags an entry with no matching function in actual" {
    const gpa = std.testing.allocator;
    var baseline = try Baseline.parse(gpa, "src/a.zig:gone:71\n");
    defer baseline.deinit(gpa);
    var actual = std.StringHashMap(ActualLen).init(gpa);
    defer actual.deinit();

    const findings = try reconcileBaseline(gpa, baseline, actual);
    defer freeFindings(gpa, findings);
    try std.testing.expectEqual(@as(usize, 1), findings.len);
    try std.testing.expectEqualStrings("stale-baseline", findings[0].rule);
}

test "reconcileBaseline is silent for an entry still legitimately in the 71-72 red zone" {
    const gpa = std.testing.allocator;
    var baseline = try Baseline.parse(gpa, "src/a.zig:foo:71\n");
    defer baseline.deinit(gpa);
    var actual = std.StringHashMap(ActualLen).init(gpa);
    defer actual.deinit();
    try actual.put("src/a.zig:foo", .{ .line = 4, .len = 72 });

    const findings = try reconcileBaseline(gpa, baseline, actual);
    defer freeFindings(gpa, findings);
    try std.testing.expectEqual(@as(usize, 0), findings.len);
}

// -- checkBanList (exactly three rules for this plan item) -----------------------

test "checkBanList flags a bare catch unreachable" {
    const gpa = std.testing.allocator;
    const findings = try checkBanList(gpa, "src/a.zig", &.{"    x catch unreachable;"});
    defer freeFindings(gpa, findings);
    try std.testing.expectEqual(@as(usize, 1), findings.len);
    try std.testing.expectEqualStrings("ban-list", findings[0].rule);
    try std.testing.expect(findings[0].replacement != null);
}

test "checkBanList allows catch unreachable with a proof comment on the same line" {
    const gpa = std.testing.allocator;
    const findings = try checkBanList(
        gpa,
        "src/a.zig",
        &.{"    x catch unreachable; // proof: x is always Foo"},
    );
    defer freeFindings(gpa, findings);
    try std.testing.expectEqual(@as(usize, 0), findings.len);
}

test "checkBanList allows catch unreachable with a proof comment on the previous line" {
    const gpa = std.testing.allocator;
    const findings = try checkBanList(gpa, "src/a.zig", &.{
        "    // proof: x is always Foo here",
        "    x catch unreachable;",
    });
    defer freeFindings(gpa, findings);
    try std.testing.expectEqual(@as(usize, 0), findings.len);
}

test "checkBanList bans std.debug.print outside src/main.zig and bench/" {
    const gpa = std.testing.allocator;
    const findings = try checkBanList(gpa, "src/other.zig", &.{"    std.debug.print(\"x\", .{});"});
    defer freeFindings(gpa, findings);
    try std.testing.expectEqual(@as(usize, 1), findings.len);
    try std.testing.expectEqualStrings("ban-list", findings[0].rule);
    try std.testing.expect(findings[0].replacement != null);
}

test "checkBanList allows std.debug.print in src/main.zig" {
    const gpa = std.testing.allocator;
    const findings = try checkBanList(gpa, "src/main.zig", &.{"    std.debug.print(\"x\", .{});"});
    defer freeFindings(gpa, findings);
    try std.testing.expectEqual(@as(usize, 0), findings.len);
}

test "checkBanList allows std.debug.print under bench/" {
    const gpa = std.testing.allocator;
    const findings = try checkBanList(gpa, "bench/x.zig", &.{"    std.debug.print(\"x\", .{});"});
    defer freeFindings(gpa, findings);
    try std.testing.expectEqual(@as(usize, 0), findings.len);
}

test "checkBanList bans std.time. under src/ outside main.zig" {
    const gpa = std.testing.allocator;
    const findings = try checkBanList(gpa, "src/wal.zig", &.{"    const t = std.time.milliTimestamp();"});
    defer freeFindings(gpa, findings);
    try std.testing.expectEqual(@as(usize, 1), findings.len);
    try std.testing.expectEqualStrings("ban-list", findings[0].rule);
    try std.testing.expect(findings[0].replacement != null);
}

test "checkBanList allows std.time. in src/main.zig" {
    const gpa = std.testing.allocator;
    const findings = try checkBanList(gpa, "src/main.zig", &.{"    const t = std.time.milliTimestamp();"});
    defer freeFindings(gpa, findings);
    try std.testing.expectEqual(@as(usize, 0), findings.len);
}

test "checkBanList allows std.time. entirely outside src/" {
    const gpa = std.testing.allocator;
    const findings = try checkBanList(gpa, "bench/x.zig", &.{"    const t = std.time.milliTimestamp();"});
    defer freeFindings(gpa, findings);
    try std.testing.expectEqual(@as(usize, 0), findings.len);
}

// -- checkWireFormatUsize --------------------------------------------------------

test "checkWireFormatUsize flags usize inside a marked struct scope" {
    const gpa = std.testing.allocator;
    const lines = [_][]const u8{
        "// wire-format",
        "pub const Frame = struct {",
        "    len: usize,",
        "};",
    };
    const findings = try checkWireFormatUsize(gpa, "src/wal.zig", &lines);
    defer freeFindings(gpa, findings);
    try std.testing.expectEqual(@as(usize, 1), findings.len);
    try std.testing.expectEqualStrings("wire-format-usize", findings[0].rule);
    try std.testing.expectEqual(@as(usize, 3), findings[0].line);
}

test "checkWireFormatUsize does not flag usize outside any marked scope" {
    const gpa = std.testing.allocator;
    const lines = [_][]const u8{"const x: usize = 5;"};
    const findings = try checkWireFormatUsize(gpa, "src/wal.zig", &lines);
    defer freeFindings(gpa, findings);
    try std.testing.expectEqual(@as(usize, 0), findings.len);
}

test "checkWireFormatUsize is silent on a marked struct with no usize inside" {
    const gpa = std.testing.allocator;
    const lines = [_][]const u8{
        "// wire-format",
        "pub const Frame = struct {",
        "    len: u32,",
        "};",
    };
    const findings = try checkWireFormatUsize(gpa, "src/wal.zig", &lines);
    defer freeFindings(gpa, findings);
    try std.testing.expectEqual(@as(usize, 0), findings.len);
}

test "checkWireFormatUsize does not flag usize as a substring of a longer identifier" {
    const gpa = std.testing.allocator;
    const lines = [_][]const u8{
        "// wire-format",
        "pub const Frame = struct {",
        "    bitsizex: u32,",
        "};",
    };
    const findings = try checkWireFormatUsize(gpa, "src/wal.zig", &lines);
    defer freeFindings(gpa, findings);
    try std.testing.expectEqual(@as(usize, 0), findings.len);
}

// -- lintFile integration (multi-rule fixture through the real wiring) -----------

test "lintFile surfaces findings from more than one new check on a mixed fixture" {
    const gpa = std.testing.allocator;
    const content =
        "//! doc\n" ++
        "// wire-format\n" ++
        "pub const Frame = struct {\n" ++
        "    len: usize,\n" ++
        "};\n" ++
        "\n" ++
        "fn f() void {\n" ++
        "    x catch unreachable;\n" ++
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

test "lintFile surfaces zero findings from the new checks on a clean fixture" {
    const gpa = std.testing.allocator;
    const content =
        "//! doc\n" ++
        "pub const Frame = struct {\n" ++
        "    len: u32,\n" ++
        "};\n" ++
        "\n" ++
        "fn f() void {\n" ++
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
