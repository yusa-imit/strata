//! Contract tests for `Recovery.truncate_after` (ADR-0005 section 4 step 5): the log ends at the
//! named frame, newer segments are gone, K = 0 leaves a header-only first segment, a repeat
//! changes nothing and a partly done cut finishes the same way.

const std = @import("std");
const assert = std.debug.assert;
const testing = std.testing;
const Io = std.Io;
const file_mod = @import("../file/file.zig");
const frame = @import("frame.zig");
const recovery = @import("recovery.zig");
const s = @import("segment.zig");
const sfx = @import("segment_fixtures.zig");
const wfx = @import("writer_fixtures.zig");

const Lsn = frame.Lsn;
const header_size = s.segment_header_size;
const frame_len: u32 = frame.frame_header_size + 5; // `record` "alpha".
const segment_bytes_max: u64 = header_size + 2 * frame_len + 2; // Two frames per segment.
const frames_count: usize = 6;

const Log = struct { lsns: [frames_count]Lsn };

/// Segments 1..3 hold two `alpha` records each.
fn build(dir: Io.Dir) !Log {
    var log: Log = .{ .lsns = @splat(0) };
    var w: wfx.Writer = undefined;
    try wfx.open_ok(&w, dir, wfx.opts(8, segment_bytes_max));
    defer w.deinit(testing.io, testing.allocator);

    for (&log.lsns) |*lsn| lsn.* = try wfx.append_ok(&w, "alpha");
    try w.sync(testing.io);
    assert(w.position().segment_index == 3);
    assert(log.lsns[5] > log.lsns[0]);
    return log;
}

fn seg_options(policy: file_mod.SyncPolicy) s.Options {
    assert(frames_count == 6);
    assert(segment_bytes_max > header_size);
    return .{ .segments_max = 8, .sync_policy = policy };
}

fn truncate(dir: Io.Dir, policy: file_mod.SyncPolicy, last_lsn: Lsn) !void {
    assert(last_lsn < frame.lsn_limit);
    const opts = seg_options(policy);
    assert(opts.segments_max >= 1);
    try recovery.Recovery.truncate_after(testing.io, testing.allocator, dir, last_lsn, opts);
}

/// Lengths of segments 1..3; 0 for a segment that is gone.
fn lengths(dir: Io.Dir) ![3]u64 {
    var out: [3]u64 = @splat(0);
    assert(out.len == 3);
    for (&out, 1..) |*len, index| {
        const f = sfx.raw_open(dir, @intCast(index)) catch |err| switch (err) {
            error.FileNotFound => continue,
            else => |other| return other,
        };
        defer f.close(testing.io);

        len.* = try f.length(testing.io);
    }
    assert(out[0] == 0 or out[0] >= header_size);
    return out;
}

fn expect_lengths(dir: Io.Dir, want: [3]u64) !void {
    assert(want[0] == 0 or want[0] >= header_size);
    assert(want[1] == 0 or want[1] >= header_size);
    try testing.expectEqual(want, try lengths(dir));
}

fn expect_writer_at(dir: Io.Dir, last: Lsn, next: Lsn) !void {
    assert(next > last);
    assert(next < frame.lsn_limit);
    var w: wfx.Writer = undefined;
    try wfx.open_ok(&w, dir, wfx.opts(8, segment_bytes_max));
    defer w.deinit(testing.io, testing.allocator);

    try testing.expectEqual(last, w.last_lsn);
    try testing.expectEqual(next, w.next_lsn);
}

test "truncate_after: cutting inside the middle segment deletes the newer one" {
    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();

    const log = try build(tmp.dir);
    const full = header_size + 2 * frame_len;
    try expect_lengths(tmp.dir, .{ full, full, full });
    try truncate(tmp.dir, .none, log.lsns[2]);
    try expect_lengths(tmp.dir, .{ full, header_size + frame_len, 0 });
    try expect_writer_at(tmp.dir, log.lsns[2], log.lsns[3]);
}

test "truncate_after: the last frame of a segment keeps it whole and drops the rest" {
    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();

    const log = try build(tmp.dir);
    const full = header_size + 2 * frame_len;
    try truncate(tmp.dir, .fsync, log.lsns[1]);
    try expect_lengths(tmp.dir, .{ full, 0, 0 });
    try expect_writer_at(tmp.dir, log.lsns[1], log.lsns[1] + frame_len);
}

test "truncate_after: K is the last frame is a no-op" {
    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();

    const log = try build(tmp.dir);
    const full = header_size + 2 * frame_len;
    try testing.expectEqual(log.lsns[4] + frame_len, log.lsns[5]);
    try truncate(tmp.dir, .none, log.lsns[5]);
    try expect_lengths(tmp.dir, .{ full, full, full });
    try expect_writer_at(tmp.dir, log.lsns[5], log.lsns[5] + frame_len);
}

test "truncate_after: K = 0 cuts segment 1 to its header and deletes the rest" {
    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();

    const log = try build(tmp.dir);
    try testing.expectEqual(@as(Lsn, 1), log.lsns[0]);
    try truncate(tmp.dir, .fdatasync, 0);
    try expect_lengths(tmp.dir, .{ header_size, 0, 0 });
    try expect_writer_at(tmp.dir, 0, 1);
}

test "truncate_after: a repeat changes nothing" {
    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();

    const log = try build(tmp.dir);
    try testing.expect(log.lsns[2] > log.lsns[1]);
    try truncate(tmp.dir, .none, log.lsns[2]);
    const once = try lengths(tmp.dir);
    try truncate(tmp.dir, .none, log.lsns[2]);
    try testing.expectEqual(once, try lengths(tmp.dir));
    try truncate(tmp.dir, .none, 0);
    try truncate(tmp.dir, .none, 0);
    try expect_lengths(tmp.dir, .{ header_size, 0, 0 });
}

test "truncate_after: a crash after deleting the newest segment finishes the same way" {
    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();

    const log = try build(tmp.dir);
    const name = sfx.name_of(3);
    try tmp.dir.deleteFile(testing.io, &name); // The first step of the cut, then a crash.
    try truncate(tmp.dir, .none, log.lsns[2]);
    try expect_lengths(tmp.dir, .{ header_size + 2 * frame_len, header_size + frame_len, 0 });
    try expect_writer_at(tmp.dir, log.lsns[2], log.lsns[3]);
}

test "truncate_after: K must name an intact frame" {
    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();

    const log = try build(tmp.dir);
    const full = header_size + 2 * frame_len;
    const bad = [_]Lsn{ 2, log.lsns[1] + 1, log.lsns[5] + frame_len, log.lsns[5] + 1000 };
    for (bad) |lsn| {
        try testing.expectError(error.Corrupted, truncate(tmp.dir, .none, lsn));
        try expect_lengths(tmp.dir, .{ full, full, full }); // Nothing was cut.
    }
}

test "truncate_after: an empty directory with K = 0 is a no-op, with K > 0 Corrupted" {
    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();

    try truncate(tmp.dir, .none, 0);
    try testing.expectError(error.Corrupted, truncate(tmp.dir, .none, 1));
    try testing.expectEqual([3]u64{ 0, 0, 0 }, try lengths(tmp.dir));
}
