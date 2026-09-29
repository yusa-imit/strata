//! Ban-list and wire-format checks. The ban list flags spellings the kingdom has retired or
//! forbidden (an unproven unreachable catch, debug printing, hidden clocks, legacy 0.15 std
//! names); the wire-format check flags `usize` inside a struct marked as an on-disk layout.
//! Every needle below is spelled in two pieces so this file does not trip its own ban list.
//! Pure functions over the file's lines; findings are owned by the caller
//! (`scanner.freeFindings`), and the static `ban_rules` table is the only shared state.

const std = @import("std");
const Allocator = std.mem.Allocator;
const scanner = @import("scanner.zig");
const Finding = scanner.Finding;

const BanId = enum {
    catch_unreachable,
    debug_print,
    time_call,
    array_list_bare_init,
    mem_index_of,
    std_net,
    thread_sync_primitive,
    fs_cwd,
};
const BanRule = struct { id: BanId, needle: []const u8, replacement: []const u8 };

/// One rule for a removed `std.Thread.<name>` sync type, replaced by `Io.<use>`.
fn threadRule(comptime name: []const u8, comptime use: []const u8) BanRule {
    return .{
        .id = .thread_sync_primitive,
        .needle = "Thread." ++ name,
        .replacement = "use `Io." ++ use ++ "` (std.Thread." ++ name ++ " was removed in 0.16.0)",
    };
}

const ban_rules = [_]BanRule{
    .{
        .id = .catch_unreachable,
        .needle = "catch " ++ "unreachable",
        .replacement = "handle the error, or add `// proof:` on this or the previous line",
    },
    .{
        .id = .debug_print,
        .needle = "std.debug." ++ "print(",
        .replacement = "use a real logger instead (src/main.zig and bench/ are exempt)",
    },
    .{
        .id = .time_call,
        .needle = "std.time.",
        .replacement = "inject a clock dependency instead of calling std.time from src/",
    },
    .{
        .id = .array_list_bare_init,
        .needle = "ArrayList",
        .replacement = "initialize with `.empty` (bare `.{}` is a 0.16 missing-field error)",
    },
    .{
        .id = .mem_index_of,
        .needle = "mem." ++ "indexOf",
        .replacement = "use `mem.find*` (the index-of names are 0.16 legacy aliases)",
    },
    .{
        .id = .mem_index_of,
        .needle = "mem." ++ "lastIndexOf",
        .replacement = "use `mem.findLast*` (the last-index-of names are 0.16 legacy aliases)",
    },
    .{
        .id = .std_net,
        .needle = "std." ++ "net",
        .replacement = "use `Io.net` (std." ++ "net was removed in 0.16.0)",
    },
    threadRule("Mutex", "Mutex"),
    threadRule("Condition", "Condition"),
    threadRule("Semaphore", "Semaphore"),
    threadRule("RwLock", "RwLock"),
    threadRule("ResetEvent", "Event"),
    threadRule("WaitGroup", "Group"),
    threadRule("Pool", "Group"),
    .{
        .id = .fs_cwd,
        .needle = "fs." ++ "cwd()",
        .replacement = "use `Io.Dir.cwd()`, passing `io` to the next call (std.fs." ++
            "cwd() was removed in 0.16.0)",
    },
};

fn isMainZig(path: []const u8) bool {
    std.debug.assert(path.len > 0);
    return std.mem.eql(u8, path, "src/main.zig");
}

fn underDir(path: []const u8, dir: []const u8) bool {
    std.debug.assert(dir.len > 0);
    return std.mem.startsWith(u8, path, dir) and
        path.len > dir.len and path[dir.len] == '/';
}

fn banApplies(id: BanId, path: []const u8) bool {
    std.debug.assert(path.len > 0);
    return switch (id) {
        .catch_unreachable => true,
        .debug_print => !(isMainZig(path) or underDir(path, "bench")),
        .time_call => std.mem.startsWith(u8, path, "src/") and !isMainZig(path),
        .array_list_bare_init,
        .mem_index_of,
        .std_net,
        .thread_sync_primitive,
        .fs_cwd,
        => true,
    };
}

fn hasProofComment(lines: []const []const u8, idx: usize) bool {
    std.debug.assert(idx < lines.len);
    if (std.mem.find(u8, lines[idx], "// proof:") != null) return true;
    return idx > 0 and std.mem.find(u8, lines[idx - 1], "// proof:") != null;
}

/// True when `line` opens an `ArrayList(...)`-typed value with a bare `.{}`
/// literal rather than `.empty`. Requires the bare literal to appear after
/// the `ArrayList(` type on the same line, so an unrelated `.{}` init earlier
/// on the line (or the word `ArrayList` in a trailing comment) does not match.
fn hasBareArrayListInit(line: []const u8) bool {
    std.debug.assert(line.len < 1_000_000); // sanity: never an absurd line
    const type_idx = std.mem.find(u8, line, "ArrayList(") orelse return false;
    return std.mem.find(u8, line[type_idx..], "= .{}") != null;
}

/// Check: flags eight distinct banned spellings (`BanId` values; the
/// `thread_sync_primitive` id spans seven `ban_rules` entries, one per
/// removed `std.Thread.*` sync type) — an unreachable catch without a `//
/// proof:` comment on the same or previous line, debug printing outside
/// `src/main.zig`/`bench/`, `std.time.` under `src/` outside `src/main.zig`,
/// a bare `ArrayList` `.{}` init (not `.empty`), the legacy `mem` index-of
/// family, the removed `std` networking namespace, every removed
/// `std.Thread.*` sync primitive, and the removed `fs` cwd accessor. Every
/// finding carries a non-null `.replacement`.
pub fn checkBanList(
    allocator: Allocator,
    path: []const u8,
    lines: []const []const u8,
) ![]Finding {
    std.debug.assert(path.len > 0);
    var out: std.ArrayList(Finding) = .empty;
    errdefer out.deinit(allocator);

    for (lines, 0..) |line, idx| {
        for (ban_rules) |rule| {
            if (std.mem.find(u8, line, rule.needle) == null) continue;
            if (!banApplies(rule.id, path)) continue;
            if (rule.id == .array_list_bare_init and !hasBareArrayListInit(line)) continue;
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
    while (std.mem.findPos(u8, line, start, needle)) |i| {
        const before_ok = i == 0 or !scanner.isIdentChar(line[i - 1]);
        const after_idx = i + needle.len;
        const after_ok = after_idx >= line.len or !scanner.isIdentChar(line[after_idx]);
        if (before_ok and after_ok) return true;
        start = i + 1;
    }
    return false;
}

/// Check: flags the bare word `usize` (word-boundary, not a substring of a
/// longer identifier) appearing inside a scope opened by a wire-format
/// marker comment immediately followed by a line that opens a struct (a
/// positive `braceDelta`), tracked back to zero exactly like
/// `measureFunctionLines` does for functions. On-disk formats are
/// fixed-width, so `usize` inside such a scope must become `u32`/`u64`.
pub fn checkWireFormatUsize(
    allocator: Allocator,
    path: []const u8,
    lines: []const []const u8,
) ![]Finding {
    std.debug.assert(path.len > 0);
    std.debug.assert(lines.len < 1_000_000); // sanity: never a runaway file
    var out: std.ArrayList(Finding) = .empty;
    errdefer out.deinit(allocator);

    var idx: usize = 0;
    while (idx < lines.len) : (idx += 1) {
        if (std.mem.find(u8, lines[idx], "// wire-format") == null) continue;
        const open_idx = idx + 1;
        if (open_idx >= lines.len or scanner.braceDelta(lines[open_idx]) <= 0) continue;

        const span = scanner.measureFunctionLines(lines, open_idx) orelse continue;
        const end_idx = open_idx + span - 1;
        std.debug.assert(end_idx < lines.len);

        var j = open_idx + 1;
        while (j < end_idx) : (j += 1) {
            if (!hasBareUsize(lines[j])) continue;
            const msg = try allocator.dupe(
                u8,
                "`usize` in a wire-format struct varies by target width",
            );
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

// Fixture spellings, each split so this file's own scan does not flag the test sources.
const catch_unreachable = "catch " ++ "unreachable";
const debug_print = "std.debug." ++ "print";
const std_net = "std." ++ "net";
const thread_mutex = "std.Thread." ++ "Mutex";
const fs_cwd = "fs." ++ "cwd()";
const mem_index_of = "std.mem." ++ "indexOf";
const mem_last_index_of = "std.mem." ++ "lastIndexOf";
const array_list = "Array" ++ "List";

// -- checkBanList (exactly three rules for this plan item) -----------------------

test "checkBanList flags a bare unreachable catch" {
    const gpa = std.testing.allocator;
    const findings = try checkBanList(gpa, "src/a.zig", &.{"    x " ++ catch_unreachable ++ ";"});
    defer scanner.freeFindings(gpa, findings);
    try std.testing.expectEqual(@as(usize, 1), findings.len);
    try std.testing.expectEqualStrings("ban-list", findings[0].rule);
    try std.testing.expect(findings[0].replacement != null);
}

test "checkBanList allows an unreachable catch with a proof comment on the same line" {
    const gpa = std.testing.allocator;
    const findings = try checkBanList(
        gpa,
        "src/a.zig",
        &.{"    x " ++ catch_unreachable ++ "; // proof: x is always Foo"},
    );
    defer scanner.freeFindings(gpa, findings);
    try std.testing.expectEqual(@as(usize, 0), findings.len);
}

test "checkBanList allows an unreachable catch with a proof comment on the previous line" {
    const gpa = std.testing.allocator;
    const findings = try checkBanList(gpa, "src/a.zig", &.{
        "    // proof: x is always Foo here",
        "    x " ++ catch_unreachable ++ ";",
    });
    defer scanner.freeFindings(gpa, findings);
    try std.testing.expectEqual(@as(usize, 0), findings.len);
}

test "checkBanList bans debug printing outside src/main.zig and bench/" {
    const gpa = std.testing.allocator;
    const line = "    " ++ debug_print ++ "(\"x\", .{});";
    const findings = try checkBanList(gpa, "src/other.zig", &.{line});
    defer scanner.freeFindings(gpa, findings);
    try std.testing.expectEqual(@as(usize, 1), findings.len);
    try std.testing.expectEqualStrings("ban-list", findings[0].rule);
    try std.testing.expect(findings[0].replacement != null);
}

test "checkBanList allows debug printing in src/main.zig" {
    const gpa = std.testing.allocator;
    const line = "    " ++ debug_print ++ "(\"x\", .{});";
    const findings = try checkBanList(gpa, "src/main.zig", &.{line});
    defer scanner.freeFindings(gpa, findings);
    try std.testing.expectEqual(@as(usize, 0), findings.len);
}

test "checkBanList allows debug printing under bench/" {
    const gpa = std.testing.allocator;
    const line = "    " ++ debug_print ++ "(\"x\", .{});";
    const findings = try checkBanList(gpa, "bench/x.zig", &.{line});
    defer scanner.freeFindings(gpa, findings);
    try std.testing.expectEqual(@as(usize, 0), findings.len);
}

test "checkBanList bans std.time. under src/ outside main.zig" {
    const gpa = std.testing.allocator;
    const line = "    const t = std.time.milliTimestamp();";
    const findings = try checkBanList(gpa, "src/wal.zig", &.{line});
    defer scanner.freeFindings(gpa, findings);
    try std.testing.expectEqual(@as(usize, 1), findings.len);
    try std.testing.expectEqualStrings("ban-list", findings[0].rule);
    try std.testing.expect(findings[0].replacement != null);
}

test "checkBanList allows std.time. in src/main.zig" {
    const gpa = std.testing.allocator;
    const line = "    const t = std.time.milliTimestamp();";
    const findings = try checkBanList(gpa, "src/main.zig", &.{line});
    defer scanner.freeFindings(gpa, findings);
    try std.testing.expectEqual(@as(usize, 0), findings.len);
}

test "checkBanList allows std.time. entirely outside src/" {
    const gpa = std.testing.allocator;
    const line = "    const t = std.time.milliTimestamp();";
    const findings = try checkBanList(gpa, "bench/x.zig", &.{line});
    defer scanner.freeFindings(gpa, findings);
    try std.testing.expectEqual(@as(usize, 0), findings.len);
}

// -- checkBanList (library-sweep additions: plan 001 item 5) ---------------------

test "checkBanList flags a bare list init instead of .empty" {
    const gpa = std.testing.allocator;
    const line = "    var out: std." ++ array_list ++ "(Finding) = .{};";
    const findings = try checkBanList(gpa, "src/a.zig", &.{line});
    defer scanner.freeFindings(gpa, findings);
    try std.testing.expectEqual(@as(usize, 1), findings.len);
    try std.testing.expectEqualStrings("ban-list", findings[0].rule);
    try std.testing.expect(findings[0].replacement != null);
}

test "checkBanList allows a list init with .empty" {
    const gpa = std.testing.allocator;
    const line = "    var out: std." ++ array_list ++ "(Finding) = .empty;";
    const findings = try checkBanList(gpa, "src/a.zig", &.{line});
    defer scanner.freeFindings(gpa, findings);
    try std.testing.expectEqual(@as(usize, 0), findings.len);
}

test "checkBanList allows a list-typed parameter with no bare init on the line" {
    const gpa = std.testing.allocator;
    const line = "f" ++ "n dump(out: std." ++ array_list ++ "(Finding)) void {";
    const findings = try checkBanList(gpa, "src/a.zig", &.{line});
    defer scanner.freeFindings(gpa, findings);
    try std.testing.expectEqual(@as(usize, 0), findings.len);
}

test "checkBanList allows an unrelated struct's bare .{} init" {
    const gpa = std.testing.allocator;
    const findings = try checkBanList(gpa, "src/a.zig", &.{"    var out: Foo = .{};"});
    defer scanner.freeFindings(gpa, findings);
    try std.testing.expectEqual(@as(usize, 0), findings.len);
}

test "checkBanList allows a bare .{} init on a line that only mentions a list in a comment" {
    const gpa = std.testing.allocator;
    const line = "    var mu: " ++ thread_mutex ++ " = .{}; // not an " ++ array_list;
    const findings = try checkBanList(gpa, "src/a.zig", &.{line});
    defer scanner.freeFindings(gpa, findings);
    const banned_list = "banned pattern `" ++ array_list ++ "`";
    for (findings) |f| try std.testing.expect(!std.mem.eql(u8, f.message, banned_list));
}

test "checkBanList flags the last-index-of call as part of the index-of family" {
    const gpa = std.testing.allocator;
    const line = "    if (" ++ mem_last_index_of ++ "(u8, s, x) != null) return;";
    const findings = try checkBanList(gpa, "src/a.zig", &.{line});
    defer scanner.freeFindings(gpa, findings);
    try std.testing.expectEqual(@as(usize, 1), findings.len);
    try std.testing.expect(findings[0].replacement != null);
}

test "checkBanList flags the index-of call in favor of std.mem.find" {
    const gpa = std.testing.allocator;
    const line = "    if (" ++ mem_index_of ++ "(u8, s, x) != null) return;";
    const findings = try checkBanList(gpa, "src/a.zig", &.{line});
    defer scanner.freeFindings(gpa, findings);
    try std.testing.expectEqual(@as(usize, 1), findings.len);
    try std.testing.expectEqualStrings("ban-list", findings[0].rule);
    try std.testing.expect(findings[0].replacement != null);
}

test "checkBanList flags the positional index-of call as part of the index-of family" {
    const gpa = std.testing.allocator;
    const line = "    if (" ++ mem_index_of ++ "Pos(u8, s, 0, x) != null) return;";
    const findings = try checkBanList(gpa, "src/a.zig", &.{line});
    defer scanner.freeFindings(gpa, findings);
    try std.testing.expectEqual(@as(usize, 1), findings.len);
}

test "checkBanList allows std.mem.find" {
    const gpa = std.testing.allocator;
    const line = "    if (std.mem.find(u8, s, x) != null) return;";
    const findings = try checkBanList(gpa, "src/a.zig", &.{line});
    defer scanner.freeFindings(gpa, findings);
    try std.testing.expectEqual(@as(usize, 0), findings.len);
}

test "checkBanList flags the removed networking namespace in favor of Io.net" {
    const gpa = std.testing.allocator;
    const line = "    var addr = try " ++ std_net ++ ".Address.parseIp(\"0.0.0.0\", 0);";
    const findings = try checkBanList(gpa, "src/a.zig", &.{line});
    defer scanner.freeFindings(gpa, findings);
    try std.testing.expectEqual(@as(usize, 1), findings.len);
    try std.testing.expectEqualStrings("ban-list", findings[0].rule);
    try std.testing.expect(findings[0].replacement != null);
}

test "checkBanList flags the removed thread mutex in favor of an Io sync primitive" {
    const gpa = std.testing.allocator;
    const line = "    var mu: " ++ thread_mutex ++ " = .{};";
    const findings = try checkBanList(gpa, "src/a.zig", &.{line});
    defer scanner.freeFindings(gpa, findings);
    try std.testing.expectEqual(@as(usize, 1), findings.len);
    try std.testing.expectEqualStrings("ban-list", findings[0].rule);
    try std.testing.expect(findings[0].replacement != null);
}

test "checkBanList flags the removed thread wait group in favor of an Io sync primitive" {
    const gpa = std.testing.allocator;
    const line = "    var wg: std.Thread." ++ "WaitGroup = .{};";
    const findings = try checkBanList(gpa, "src/a.zig", &.{line});
    defer scanner.freeFindings(gpa, findings);
    try std.testing.expectEqual(@as(usize, 1), findings.len);
    try std.testing.expectEqualStrings("ban-list", findings[0].rule);
    try std.testing.expect(findings[0].replacement != null);
}

test "checkBanList flags the removed thread rwlock in favor of an Io sync primitive" {
    const gpa = std.testing.allocator;
    const line = "    var lock: std.Thread." ++ "RwLock = .{};";
    const findings = try checkBanList(gpa, "src/a.zig", &.{line});
    defer scanner.freeFindings(gpa, findings);
    try std.testing.expectEqual(@as(usize, 1), findings.len);
    try std.testing.expectEqualStrings("ban-list", findings[0].rule);
    try std.testing.expect(findings[0].replacement != null);
}

test "checkBanList allows plain std.Thread.spawn" {
    const gpa = std.testing.allocator;
    const line = "    const t = try std.Thread.spawn(.{}, foo, .{});";
    const findings = try checkBanList(gpa, "src/a.zig", &.{line});
    defer scanner.freeFindings(gpa, findings);
    try std.testing.expectEqual(@as(usize, 0), findings.len);
}

test "checkBanList flags the removed cwd accessor in favor of Io.Dir.cwd(io)" {
    const gpa = std.testing.allocator;
    const line = "    var dir = try " ++ fs_cwd ++ ".openDir(\"x\", .{});";
    const findings = try checkBanList(gpa, "src/a.zig", &.{line});
    defer scanner.freeFindings(gpa, findings);
    try std.testing.expectEqual(@as(usize, 1), findings.len);
    try std.testing.expectEqualStrings("ban-list", findings[0].rule);
    try std.testing.expect(findings[0].replacement != null);
}

test "checkBanList: every finding from the new library-sweep rules carries a replacement" {
    const gpa = std.testing.allocator;
    const lines = [_][]const u8{
        "    var out: std." ++ array_list ++ "(Finding) = .{};",
        "    if (" ++ mem_index_of ++ "(u8, s, x) != null) return;",
        "    var addr = try " ++ std_net ++ ".Address.parseIp(\"0.0.0.0\", 0);",
        "    var mu: " ++ thread_mutex ++ " = .{};",
        "    var dir = try " ++ fs_cwd ++ ".openDir(\"x\", .{});",
    };
    const findings = try checkBanList(gpa, "src/a.zig", &lines);
    defer scanner.freeFindings(gpa, findings);
    try std.testing.expectEqual(@as(usize, 5), findings.len);
    for (findings) |f| {
        try std.testing.expectEqualStrings("ban-list", f.rule);
        try std.testing.expect(f.replacement != null);
    }
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
    defer scanner.freeFindings(gpa, findings);
    try std.testing.expectEqual(@as(usize, 1), findings.len);
    try std.testing.expectEqualStrings("wire-format-usize", findings[0].rule);
    try std.testing.expectEqual(@as(usize, 3), findings[0].line);
}

test "checkWireFormatUsize does not flag usize outside any marked scope" {
    const gpa = std.testing.allocator;
    const lines = [_][]const u8{"const x: usize = 5;"};
    const findings = try checkWireFormatUsize(gpa, "src/wal.zig", &lines);
    defer scanner.freeFindings(gpa, findings);
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
    defer scanner.freeFindings(gpa, findings);
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
    defer scanner.freeFindings(gpa, findings);
    try std.testing.expectEqual(@as(usize, 0), findings.len);
}
