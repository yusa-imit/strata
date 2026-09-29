//! Filesystem glue (`std.Io.Dir`, Zig 0.16.0): the bounded, non-recursive directory walk that
//! collects every `.zig` file under the scan roots. A `queue` of relative directory paths
//! stands in for the explicit bounded stack Tiger Style requires in place of recursion
//! (`dir_queue_max`). Every returned path is allocated with the caller's `gpa`; the caller
//! frees the slice and each element (the tidy entry point hands in an arena).

const std = @import("std");
const Allocator = std.mem.Allocator;

/// Largest file (source or baseline) tidy will read; anything bigger is skipped or fails.
pub const max_file_bytes: usize = 8 * 1024 * 1024;

const dir_queue_max: u32 = 4096;
const scan_roots = [_][]const u8{ "src", "bench", "tests", "tools" };

fn shouldSkipDirName(name: []const u8) bool {
    std.debug.assert(name.len > 0);
    return std.mem.eql(u8, name, ".zig-cache") or
        std.mem.eql(u8, name, "zig-out") or
        std.mem.eql(u8, name, "zig-pkg");
}

fn shouldCollectFile(name: []const u8) bool {
    std.debug.assert(name.len > 0);
    return std.mem.endsWith(u8, name, ".zig");
}

/// Iterates one already-open directory at relative path `rel`, pushing every
/// subdirectory back onto `queue` (skipping names `shouldSkipDirName` flags)
/// and appending every `.zig` file it finds to `out`.
fn walkOneDir(
    gpa: Allocator,
    io: std.Io,
    root: std.Io.Dir,
    rel: []const u8,
    queue: *std.ArrayList([]const u8),
    out: *std.ArrayList([]const u8),
) !void {
    std.debug.assert(rel.len > 0);
    var dir = root.openDir(io, rel, .{ .iterate = true }) catch |err| switch (err) {
        error.Canceled => return err,
        else => return,
    };
    defer dir.close(io);

    var it = dir.iterate();
    while (try it.next(io)) |entry| {
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
    io: std.Io,
    root: std.Io.Dir,
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
        try walkOneDir(gpa, io, root, rel, &queue, out);
    }
    std.debug.assert(queue.items.len == 0);
}

fn collectTopLevel(
    gpa: Allocator,
    io: std.Io,
    root: std.Io.Dir,
    name: []const u8,
    out: *std.ArrayList([]const u8),
) !void {
    std.debug.assert(name.len > 0);
    root.access(io, name, .{}) catch |err| switch (err) {
        error.Canceled => return err,
        else => return,
    };
    try out.append(gpa, try gpa.dupe(u8, name));
    std.debug.assert(out.items.len > 0);
}

/// Collects every `.zig` file under `src/`, `bench/`, `tests/`, `tools/`, plus the
/// top-level `build.zig` when present, relative to `root`. Caller frees the
/// returned slice (and each element) with `gpa`.
pub fn collectFiles(gpa: Allocator, io: std.Io, root: std.Io.Dir) ![][]const u8 {
    var out: std.ArrayList([]const u8) = .empty;
    errdefer out.deinit(gpa);

    try collectTopLevel(gpa, io, root, "build.zig", &out);
    for (scan_roots) |name| try walkDir(gpa, io, root, name, &out);

    const result = try out.toOwnedSlice(gpa);
    std.debug.assert(scan_roots.len == 4);
    return result;
}
