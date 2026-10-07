//! Function-length check and its shrink-only red-zone baseline. A function body over 70 lines
//! is a finding; 71-72 lines is excused only by an entry in `tidy_baseline.txt`; 73 or more is
//! always a finding. `reconcileBaseline` reports entries that went stale (function shrank,
//! grew past the ceiling, or vanished). `Baseline` owns its key strings and is released with
//! `deinit`; the check functions return owned findings slices freed via `scanner.freeFindings`.

const std = @import("std");
const assert = std.debug.assert;
const Allocator = std.mem.Allocator;
const scanner = @import("scanner.zig");
const Finding = scanner.Finding;

const fn_len_clean_max: usize = 70;
const fn_len_redzone_max: usize = 72;

comptime {
    // The red zone must be a non-empty band above the clean limit, or the baseline rescues nothing.
    assert(fn_len_clean_max > 0);
    assert(fn_len_redzone_max > fn_len_clean_max);
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

    pub fn init(gpa: Allocator) Baseline {
        const self: Baseline = .{ .entries = std.StringHashMap(usize).init(gpa) };
        assert(self.entries.count() == 0);
        return self;
    }

    /// Frees every owned key; `gpa` must be the one the entries were parsed with.
    pub fn deinit(self: *Baseline, gpa: Allocator) void {
        assert(self.entries.count() < 1_000_000);
        var it = self.entries.keyIterator();
        while (it.next()) |k| {
            assert(k.len > 0);
            gpa.free(k.*);
        }
        self.entries.deinit();
        self.* = undefined;
    }

    pub fn get(self: Baseline, key: []const u8) ?usize {
        assert(key.len > 0);
        const found = self.entries.get(key);
        // A hit implies a non-empty baseline; `parse` is the only writer.
        if (found != null) assert(self.entries.count() > 0);
        return found;
    }

    /// Parses `path:fn_name:lines` lines. Blank lines and lines starting
    /// with `#` are ignored.
    pub fn parse(gpa: Allocator, content: []const u8) !Baseline {
        assert(content.len < 100 * 1024 * 1024); // sanity: never a runaway file
        var self = Baseline.init(gpa);
        errdefer self.deinit(gpa);

        var it = std.mem.splitScalar(u8, content, '\n');
        while (it.next()) |raw| {
            const line = std.mem.trim(u8, raw, " \t\r");
            if (line.len == 0 or line[0] == '#') continue;
            try self.parseLine(gpa, line);
        }

        assert(self.entries.count() < 1_000_000); // sanity: never a runaway baseline
        return self;
    }

    fn parseLine(self: *Baseline, gpa: Allocator, line: []const u8) !void {
        assert(line.len > 0);
        const last_colon = std.mem.findScalarLast(u8, line, ':') orelse return;
        const lines_str = line[last_colon + 1 ..];
        const key_part = line[0..last_colon];
        const lines_n = std.fmt.parseInt(usize, lines_str, 10) catch return;
        assert(key_part.len < line.len);
        // A line like `:71` names no function; the baseline is user data, so skip, do not store.
        if (key_part.len == 0) return;

        const key = try gpa.dupe(u8, key_part);
        const gop = try self.entries.getOrPut(key);
        if (gop.found_existing) gpa.free(key);
        gop.value_ptr.* = lines_n;
    }
};

fn appendFunctionLengthFinding(
    out: *std.ArrayList(Finding),
    gpa: Allocator,
    path: []const u8,
    line: usize,
    name: []const u8,
    len: usize,
) !void {
    assert(name.len > 0);
    assert(len > fn_len_clean_max);
    const msg = try std.fmt.allocPrint(
        gpa,
        "fn `{s}` is {d} lines (limit {d})",
        .{ name, len, fn_len_clean_max },
    );
    try out.append(gpa, .{
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
    gpa: Allocator,
    path: []const u8,
    lines: []const []const u8,
    baseline: Baseline,
    actual_out: *std.StringHashMap(ActualLen),
) ![]Finding {
    assert(path.len > 0);
    var out: std.ArrayList(Finding) = .empty;
    errdefer out.deinit(gpa);

    var idx: usize = 0;
    while (idx < lines.len) : (idx += 1) {
        const name = scanner.extractFnName(lines[idx]) orelse continue;
        const len = scanner.measureFunctionLines(lines, idx) orelse continue;

        const key = try std.fmt.allocPrint(gpa, "{s}:{s}", .{ path, name });
        const gop = try actual_out.getOrPut(key);
        if (gop.found_existing) gpa.free(key);
        gop.value_ptr.* = .{ .line = idx + 1, .len = len };

        const in_redzone = len > fn_len_clean_max and len <= fn_len_redzone_max;
        const over_ceiling = len > fn_len_redzone_max;
        if (over_ceiling or (in_redzone and baseline.get(key) == null)) {
            try appendFunctionLengthFinding(&out, gpa, path, idx + 1, name, len);
        }
    }

    const result = try out.toOwnedSlice(gpa);
    assert(result.len <= lines.len);
    return result;
}

/// Appends one `stale-baseline` finding for `path` at `line` with the owned `msg`.
fn appendStaleFinding(
    out: *std.ArrayList(Finding),
    gpa: Allocator,
    path: []const u8,
    line: usize,
    msg: []const u8,
) !void {
    assert(path.len > 0);
    assert(msg.len > 0);
    try out.append(gpa, .{
        .path = path,
        .line = line,
        .rule = "stale-baseline",
        .message = msg,
    });
}

/// One baseline entry's reconciliation against `actual` (see
/// `reconcileBaseline`).
fn reconcileOne(
    out: *std.ArrayList(Finding),
    gpa: Allocator,
    key: []const u8,
    actual: std.StringHashMap(ActualLen),
) !void {
    assert(key.len > 0);
    const path = if (std.mem.findScalarLast(u8, key, ':')) |i| key[0..i] else key;
    assert(path.len <= key.len);

    const found = actual.get(key) orelse {
        const msg = try std.fmt.allocPrint(
            gpa,
            "baseline entry `{s}` matches no function",
            .{key},
        );
        return appendStaleFinding(out, gpa, path, 1, msg);
    };

    if (found.len <= fn_len_clean_max) {
        const msg = try std.fmt.allocPrint(
            gpa,
            "`{s}` shrank to {d} lines; remove it from tidy_baseline.txt",
            .{ key, found.len },
        );
        try appendStaleFinding(out, gpa, path, found.line, msg);
    } else if (found.len > fn_len_redzone_max) {
        const msg = try std.fmt.allocPrint(
            gpa,
            "`{s}` is {d} lines; the baseline cannot rescue the hard ceiling",
            .{ key, found.len },
        );
        try appendStaleFinding(out, gpa, path, found.line, msg);
    }
}

/// After a full scan, compares every baseline entry against `actual`: an
/// entry whose function shrank to 70 lines or fewer, or grew to 73 lines or
/// more, or matches no function in `actual` at all, is a `"stale-baseline"`
/// finding. An entry whose function is still legitimately in the 71-72
/// range is silent.
pub fn reconcileBaseline(
    gpa: Allocator,
    baseline: Baseline,
    actual: std.StringHashMap(ActualLen),
) ![]Finding {
    assert(baseline.entries.count() < 1_000_000); // sanity: never a runaway baseline
    var out: std.ArrayList(Finding) = .empty;
    errdefer out.deinit(gpa);

    var it = baseline.entries.iterator();
    while (it.next()) |entry| {
        try reconcileOne(&out, gpa, entry.key_ptr.*, actual);
    }

    const result = try out.toOwnedSlice(gpa);
    assert(result.len <= baseline.entries.count());
    return result;
}

fn freeActualMap(gpa: Allocator, map: *std.StringHashMap(ActualLen)) void {
    assert(map.count() < 1_000_000);
    var it = map.keyIterator();
    while (it.next()) |k| {
        assert(k.len > 0);
        gpa.free(k.*);
    }
    map.deinit();
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

test "Baseline.parse drops an entry with an empty key instead of storing it" {
    const gpa = std.testing.allocator;
    var baseline = try Baseline.parse(gpa, ":71\nsrc/a.zig:foo:71\n");
    defer baseline.deinit(gpa);
    try std.testing.expectEqual(@as(u32, 1), baseline.entries.count());
    try std.testing.expectEqual(@as(?usize, null), baseline.entries.get(""));
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
/// line. The opener is spelled in two pieces so this file's own function-length scan does
/// not mistake the fixture for a function declaration.
fn fnLinesOfLength(comptime total_len: usize) [total_len][]const u8 {
    var lines: [total_len][]const u8 = undefined;
    lines[0] = "f" ++ "n sized() void {";
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
    defer scanner.freeFindings(gpa, findings);
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
    defer scanner.freeFindings(gpa, findings);
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
    defer scanner.freeFindings(gpa, findings);
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
    defer scanner.freeFindings(gpa, findings);
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
    defer scanner.freeFindings(gpa, findings);

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
    defer scanner.freeFindings(gpa, findings);
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
    defer scanner.freeFindings(gpa, findings);
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
    defer scanner.freeFindings(gpa, findings);
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
    defer scanner.freeFindings(gpa, findings);
    try std.testing.expectEqual(@as(usize, 0), findings.len);
}
