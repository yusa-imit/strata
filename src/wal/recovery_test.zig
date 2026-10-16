//! Contract tests for `recovery.zig` (ADR-0003 sections 8 and 10): replay order and start,
//! torn-tail repair at every cut, damage that must not be repaired, idempotence and the
//! `Apply` error path. Fixtures in `recovery_fixtures.zig`.

const std = @import("std");
const assert = std.debug.assert;
const testing = std.testing;
const frame = @import("frame.zig");
const fx = @import("recovery_fixtures.zig");
const rfx = @import("reader_fixtures.zig");
const s = @import("segment.zig");
const sfx = @import("segment_fixtures.zig");
const wfx = @import("writer_fixtures.zig");

const Model = fx.Model;
const pa = fx.pa;
const pb = fx.pb;
const pc = fx.pc;

fn expect_three(model: *const Model, skip: usize) !void {
    assert(skip <= 3);
    assert(model.count <= 3);
    const lsns = [_]fx.Lsn{ fx.lsn1, fx.lsn2, fx.lsn3 };
    const payloads = [_][]const u8{ pa, pb, pc };
    try model.expect_records(lsns[skip..], payloads[skip..]);
}

test "recovery: a clean log replays every frame in order" {
    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();

    try fx.put_three(tmp.dir, fx.f3_end);
    var model: Model = .{};
    try testing.expectEqual(fx.lsn3, try fx.replay_ok(tmp.dir, &model, 0));
    try expect_three(&model, 0);
    try fx.expect_len(tmp.dir, 1, fx.f3_end);
    try fx.expect_writer_continues(tmp.dir, fx.lsn_end);
}

test "recovery: an empty directory and a header-only log have no frames" {
    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();

    var model: Model = .{};
    try testing.expectEqual(@as(fx.Lsn, 0), try fx.replay_ok(tmp.dir, &model, 0));
    try testing.expectEqual(@as(u32, 0), model.count);
    try fx.put_three(tmp.dir, fx.header_size);
    var again: Model = .{};
    try testing.expectEqual(@as(fx.Lsn, 0), try fx.replay_ok(tmp.dir, &again, 0));
    try testing.expectEqual(@as(u32, 0), again.count);
    try fx.expect_replay_error(error.Corrupted, tmp.dir, 1, 4); // No frame at 1.
}

test "recovery: from_lsn starts at that frame and last_lsn still counts the skipped" {
    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();

    try fx.put_three(tmp.dir, fx.f3_end);
    var model: Model = .{};
    try testing.expectEqual(fx.lsn3, try fx.replay_ok(tmp.dir, &model, fx.lsn2));
    try expect_three(&model, 1);
    var last: Model = .{};
    try testing.expectEqual(fx.lsn3, try fx.replay_ok(tmp.dir, &last, fx.lsn3));
    try expect_three(&last, 2);
    var first: Model = .{};
    try testing.expectEqual(fx.lsn3, try fx.replay_ok(tmp.dir, &first, fx.lsn1));
    try expect_three(&first, 0);
}

test "recovery: from_lsn below the oldest frame, inside a frame or past the end is Corrupted" {
    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();

    const next = try rfx.put_segment(tmp.dir, 2, 100, &.{ pa, pb });
    try testing.expectEqual(@as(fx.Lsn, 100 + 22 + 24), next);
    try fx.expect_replay_error(error.Corrupted, tmp.dir, 0, 4); // Segment 1 is gone.
    try fx.expect_replay_error(error.Corrupted, tmp.dir, 99, 4);
    try fx.expect_replay_error(error.Corrupted, tmp.dir, 101, 4);
    try fx.expect_replay_error(error.Corrupted, tmp.dir, next, 4);
    try fx.expect_replay_error(error.Corrupted, tmp.dir, next + 1000, 4);
    var model: Model = .{};
    try testing.expectEqual(@as(fx.Lsn, 122), try fx.replay_ok(tmp.dir, &model, 122));
    try model.expect_records(&.{122}, &.{pb});
}

test "recovery: a torn tail at every cut is truncated and the log stays appendable" {
    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();

    var cut: u32 = fx.f2_end + 1;
    while (cut < fx.f3_end) : (cut += 1) {
        try fx.put_three(tmp.dir, cut);
        var model: Model = .{};
        try testing.expectEqual(fx.lsn2, try fx.replay_ok(tmp.dir, &model, 0));
        try model.expect_records(&.{ fx.lsn1, fx.lsn2 }, &.{ pa, pb });
        try fx.expect_len(tmp.dir, 1, fx.f2_end);
        try fx.expect_writer_continues(tmp.dir, fx.lsn3);
    }
    try testing.expectEqual(fx.f3_end, cut);
}

test "recovery: a torn tail inside the first frame leaves an empty appendable log" {
    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();

    try fx.put_three(tmp.dir, fx.header_size + 10);
    var model: Model = .{};
    try testing.expectEqual(@as(fx.Lsn, 0), try fx.replay_ok(tmp.dir, &model, 0));
    try testing.expectEqual(@as(u32, 0), model.count);
    try fx.expect_len(tmp.dir, 1, fx.header_size);
    try fx.expect_writer_continues(tmp.dir, 1);
}

test "recovery: a half-zeroed last frame is torn, a zero tail after the frames is clean" {
    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();

    try fx.put_three(tmp.dir, fx.f3_end - 3);
    const f = try sfx.raw_open(tmp.dir, 1);
    defer f.close(testing.io);

    try f.setLength(testing.io, fx.f3_end + 50); // The last 3 bytes of frame 3 read as zero.
    var model: Model = .{};
    try testing.expectEqual(fx.lsn2, try fx.replay_ok(tmp.dir, &model, 0));
    try testing.expectEqual(@as(u32, 2), model.count);
    try sfx.expect_length(f, fx.f2_end);
    try fx.put_three(tmp.dir, fx.f3_end + 50);
    var clean: Model = .{};
    try testing.expectEqual(fx.lsn3, try fx.replay_ok(tmp.dir, &clean, 0));
    try expect_three(&clean, 0);
}

test "recovery: a torn frame at the seek target is Corrupted and nothing changes" {
    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();

    try fx.put_three(tmp.dir, fx.f2_end + 5);
    try fx.expect_replay_error(error.Corrupted, tmp.dir, fx.lsn3, 4);
    try fx.expect_replay_error(error.Corrupted, tmp.dir, fx.lsn_end, 4);
    try fx.expect_len(tmp.dir, 1, fx.f2_end + 5);
    var model: Model = .{};
    try testing.expectEqual(fx.lsn2, try fx.replay_ok(tmp.dir, &model, fx.lsn2));
    try fx.expect_len(tmp.dir, 1, fx.f2_end);
}

test "recovery: a partial newest header is deleted, an unwritten one is left to the writer" {
    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();

    var image: [256]u8 = undefined;
    const n = rfx.build(&image, 1, 1, &.{ pa, pb });
    try sfx.put_file(tmp.dir, 1, image[0..n], n);
    const header = sfx.header_of(2, fx.lsn3);
    try sfx.put_file(tmp.dir, 2, header[0..10], 10);
    var model: Model = .{};
    try testing.expectEqual(fx.lsn2, try fx.replay_ok(tmp.dir, &model, 0));
    try testing.expectEqual(@as(u32, 2), model.count);
    try sfx.expect_open_error(error.FileNotFound, tmp.dir, 2);
    try fx.expect_writer_continues(tmp.dir, fx.lsn3);
}

test "recovery: an unwritten newest segment stays and the writer rewrites it" {
    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();

    var image: [256]u8 = undefined;
    const n = rfx.build(&image, 1, 1, &.{ pa, pb });
    try sfx.put_file(tmp.dir, 1, image[0..n], n);
    try sfx.put_file(tmp.dir, 2, &.{}, 0);
    var model: Model = .{};
    try testing.expectEqual(fx.lsn2, try fx.replay_ok(tmp.dir, &model, 0));
    try testing.expectEqual(@as(u32, 2), model.count);
    try fx.expect_len(tmp.dir, 2, 0);
    try fx.expect_writer_continues(tmp.dir, fx.lsn3);
}

test "recovery: a bit flip mid-log is ChecksumMismatch and the file is untouched" {
    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();

    const offsets = [_]u64{ fx.f1_end + 17 + 2, fx.f1_end + 4, fx.header_size + 17 };
    for (offsets) |offset| {
        try fx.put_three(tmp.dir, fx.f3_end);
        const f = try sfx.raw_open(tmp.dir, 1);
        defer f.close(testing.io);

        try sfx.flip_bit(f, offset, 3); // A valid frame follows the damage.
        var model: Model = .{};
        const got = fx.replay(tmp.dir, &model, 0, 4);
        try testing.expectError(error.ChecksumMismatch, got);
        try sfx.expect_length(f, fx.f3_end);
        try fx.expect_replay_error(error.ChecksumMismatch, tmp.dir, 0, 4);
    }
}

test "recovery: a damaged length field is never truncated" {
    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();

    try fx.put_three(tmp.dir, fx.f3_end);
    const f = try sfx.raw_open(tmp.dir, 1);
    defer f.close(testing.io);

    try sfx.flip_bit(f, fx.f1_end + 1, 0);
    var model: Model = .{};
    const got = fx.replay(tmp.dir, &model, 0, 4);
    if (got) |_| return error.TestUnexpectedResult else |err| switch (err) {
        error.ChecksumMismatch, error.Corrupted => {},
        else => return err,
    }
    try sfx.expect_length(f, fx.f3_end);
}

test "recovery: replaying twice into a model equals replaying once" {
    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();

    try fx.put_three(tmp.dir, fx.f3_end - 4);
    var once: Model = .{};
    const last = try fx.replay_ok(tmp.dir, &once, 0);
    var twice: Model = .{};
    try testing.expectEqual(last, try fx.replay_ok(tmp.dir, &twice, 0));
    try once.expect_equal(&twice);
    try testing.expectEqual(@as(u32, 2), twice.count);
    try fx.expect_len(tmp.dir, 1, fx.f2_end);
}

test "recovery: an Apply error propagates and leaves a torn log untouched" {
    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();

    try fx.put_three(tmp.dir, fx.f3_end - 4);
    const errors = [_]@import("recovery.zig").ApplyError{ error.Failed, error.Corrupted };
    for (errors) |want| {
        var model: Model = .{ .fail_at = 1, .fail_with = want };
        try testing.expectError(want, fx.replay(tmp.dir, &model, 0, 4));
        try testing.expectEqual(@as(u32, 1), model.count);
        try fx.expect_len(tmp.dir, 1, fx.f3_end - 4);
    }
}

test "recovery: a multi-segment log replays across segments and trims only the newest" {
    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();

    const mid = try rfx.put_segment(tmp.dir, 1, 1, &.{ pa, pb });
    var image: [256]u8 = undefined;
    const n = rfx.build(&image, 2, mid, &.{ pc, pa });
    try sfx.put_file(tmp.dir, 2, image[0 .. n - 5], n - 5);
    var model: Model = .{};
    try testing.expectEqual(mid, try fx.replay_ok(tmp.dir, &model, fx.lsn2));
    try model.expect_records(&.{ fx.lsn2, mid }, &.{ pb, pc });
    try fx.expect_len(tmp.dir, 2, fx.header_size + 24);
}

test "recovery: SegmentLimit and WouldBlock are returned, nothing is repaired" {
    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();

    const mid = try rfx.put_segment(tmp.dir, 1, 1, &.{pa});
    _ = try rfx.put_segment(tmp.dir, 2, mid, &.{pb});
    try fx.expect_replay_error(error.SegmentLimit, tmp.dir, 0, 1);
    var w: wfx.Writer = undefined;
    try wfx.open_ok(&w, tmp.dir, wfx.opts(4, 1 << 20));
    defer w.deinit(testing.io, testing.allocator);

    try fx.expect_replay_error(error.WouldBlock, tmp.dir, 0, 4);
}
