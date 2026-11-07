//! Contract tests for `commit_scan.zig` (ADR-0005 section 8, "Validation"): the last commit
//! point, the `first_lsn` check against the previous commit point, and the damage it names.
//! Frames are fed straight to the `Apply` target; sizes follow the codec (17 + payload).

const std = @import("std");
const assert = std.debug.assert;
const testing = std.testing;
const frame = @import("frame.zig");
const commit_scan = @import("commit_scan.zig");

const CommitScan = commit_scan.CommitScan;
const Lsn = frame.Lsn;
const record_len: u32 = frame.frame_header_size + 5; // A `record` "alpha".
const marker_len: u32 = frame.frame_header_size + 8; // A `commit` or `checkpoint` frame.

fn feed(scan: *CommitScan, lsn: Lsn, frame_type: frame.Type, payload: []const u8) !void {
    assert(payload.len <= 8);
    assert(lsn >= frame.lsn_first);
    const f: frame.Frame = .{ .lsn = lsn, .frame_type = frame_type, .payload = payload };
    try scan.target().apply(testing.io, f);
}

fn record(scan: *CommitScan, lsn: Lsn) !void {
    assert(lsn >= frame.lsn_first);
    assert(record_len == 22);
    try feed(scan, lsn, .record, "alpha");
}

fn commit(scan: *CommitScan, lsn: Lsn, first_lsn: Lsn) !void {
    assert(first_lsn < lsn);
    assert(marker_len == 25);
    try feed(scan, lsn, .commit, &frame.commit_payload(first_lsn));
}

fn checkpoint(scan: *CommitScan, lsn: Lsn) !void {
    assert(lsn >= frame.lsn_first);
    assert(marker_len == 25);
    var payload: [8]u8 = undefined;
    std.mem.writeInt(u64, &payload, lsn, .little);
    try feed(scan, lsn, .checkpoint, &payload);
}

test "commit_scan: groups from the start of the log validate and the last commit is K" {
    var scan = CommitScan.init(0);
    try testing.expectEqual(@as(Lsn, 0), scan.last_commit_lsn);
    try record(&scan, 1);
    try record(&scan, 23);
    try commit(&scan, 45, 1);
    try testing.expectEqual(@as(Lsn, 45), scan.last_commit_lsn);
    try record(&scan, 70);
    try commit(&scan, 92, 70);
    try testing.expectEqual(@as(Lsn, 92), scan.last_commit_lsn);
    try testing.expectEqual(@as(u64, 2), scan.commits);
    try testing.expectEqual(@as(u64, 0), scan.frames_after);
}

test "commit_scan: from a checkpoint the first group starts right after it" {
    var scan = CommitScan.init(100);
    try checkpoint(&scan, 100);
    try testing.expectEqual(@as(Lsn, 100), scan.last_commit_lsn);
    try record(&scan, 125);
    try commit(&scan, 147, 125);
    try testing.expectEqual(@as(Lsn, 147), scan.last_commit_lsn);
    var late = CommitScan.init(100);
    try checkpoint(&late, 100);
    try record(&late, 125);
    try testing.expectError(error.Corrupted, commit(&late, 147, 100)); // Starts on the checkpoint.
}

test "commit_scan: no commit frame means K = 0 and the frames are only counted" {
    var scan = CommitScan.init(0);
    try record(&scan, 1);
    try record(&scan, 23);
    try testing.expectEqual(@as(Lsn, 0), scan.last_commit_lsn);
    try testing.expectEqual(@as(u64, 2), scan.frames_after);
    try testing.expectEqual(@as(u64, 0), scan.commits);
}

test "commit_scan: frames after the last commit are counted, not committed" {
    var scan = CommitScan.init(0);
    try record(&scan, 1);
    try commit(&scan, 23, 1);
    try record(&scan, 48);
    try record(&scan, 70);
    try testing.expectEqual(@as(Lsn, 23), scan.last_commit_lsn);
    try testing.expectEqual(@as(u64, 2), scan.frames_after);
}

test "commit_scan: a hole or a foreign first_lsn is Corrupted" {
    var scan = CommitScan.init(0);
    try record(&scan, 1);
    try testing.expectError(error.Corrupted, commit(&scan, 23, 2)); // Not a frame start.
    var skipped = CommitScan.init(0);
    try record(&skipped, 1);
    try record(&skipped, 23);
    try testing.expectError(error.Corrupted, commit(&skipped, 45, 23)); // Frame 1 is orphaned.
    var foreign = CommitScan.init(0);
    try record(&foreign, 1);
    try commit(&foreign, 23, 1);
    try record(&foreign, 48);
    try testing.expectError(error.Corrupted, commit(&foreign, 70, 1)); // Claims a closed group.
    try testing.expectEqual(@as(Lsn, 0), scan.last_commit_lsn);
    try testing.expectEqual(@as(u64, 1), scan.frames_after);
}

test "commit_scan: a malformed commit payload is Corrupted" {
    var scan = CommitScan.init(0);
    try record(&scan, 1);
    try testing.expectError(error.Corrupted, feed(&scan, 23, .commit, "short"));
    var zero: [8]u8 = @splat(0);
    try testing.expectError(error.Corrupted, feed(&scan, 23, .commit, &zero));
    std.mem.writeInt(u64, &zero, 23, .little);
    try testing.expectError(error.Corrupted, feed(&scan, 23, .commit, &zero)); // first_lsn == lsn
    try testing.expectEqual(@as(Lsn, 0), scan.last_commit_lsn);
}

test "commit_scan: a checkpoint after an unfinished group is Corrupted" {
    var scan = CommitScan.init(0);
    try record(&scan, 1);
    try testing.expectError(error.Corrupted, checkpoint(&scan, 23));
    var clean = CommitScan.init(0);
    try record(&clean, 1);
    try commit(&clean, 23, 1);
    try checkpoint(&clean, 48);
    try record(&clean, 73);
    try commit(&clean, 95, 73);
    try testing.expectEqual(@as(Lsn, 95), clean.last_commit_lsn);
}
