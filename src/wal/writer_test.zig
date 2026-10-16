//! Contract tests for `Writer` (ADR-0003 sections 5, 8 and 9), behaviour half: append and read
//! back, reopen, frame types and limits, rotation against an independent model, segment limits,
//! locking. Pre-existing and torn logs are in `writer_tail_test.zig`; faults, allocation and
//! LSN exhaustion are in `writer_fault_test.zig`; shared helpers are in `writer_fixtures.zig`.

const std = @import("std");
const assert = std.debug.assert;
const testing = std.testing;
const frame = @import("frame.zig");
const fx = @import("writer_fixtures.zig");
const rfx = @import("reader_fixtures.zig");
const sfx = @import("segment_fixtures.zig");

const Writer = fx.Writer;
const Lsn = fx.Lsn;
const pa = fx.pa;
const pb = fx.pb;
const pc = fx.pc;
const header_size = fx.header_size;

test "writer: an empty directory gets segment 1 at LSN 1, frames read back in order" {
    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    {
        var w: Writer = undefined;
        try fx.open_ok(&w, tmp.dir, fx.opts(4, 1 << 20));
        defer w.deinit(testing.io, testing.allocator);

        try fx.expect_position(&w, 1, header_size, 1);
        try testing.expectEqual(@as(Lsn, 0), w.durable_lsn);
        try testing.expectEqual(@as(Lsn, 1), try fx.append_ok(&w, pa));
        try testing.expectEqual(@as(Lsn, 0), w.durable_lsn); // Written is not durable.
        try testing.expectEqual(@as(Lsn, 23), try fx.append_ok(&w, pb));
        try testing.expectEqual(@as(Lsn, 47), try fx.append_ok(&w, pc));
        try w.sync(testing.io);
        w.check_invariants();
        try testing.expectEqual(@as(Lsn, 47), w.durable_lsn); // Inclusive: the last frame's LSN.
        try fx.expect_position(&w, 1, header_size + 70, 71);

        try w.sync(testing.io); // Nothing new: a no-op that keeps the bound.
        try testing.expectEqual(@as(Lsn, 47), w.durable_lsn);
    }
    try fx.expect_log(tmp.dir, 4, &.{ 1, 23, 47 }, &.{ pa, pb, pc });
    try sfx.expect_open_ok(tmp.dir, 1, 1); // The lock is free after `deinit`.
}

test "writer: reopening a cleanly closed log continues the LSN" {
    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    {
        var w: Writer = undefined;
        try fx.open_ok(&w, tmp.dir, fx.opts(4, 1 << 20));
        defer w.deinit(testing.io, testing.allocator);

        _ = try fx.append_ok(&w, pa);
        _ = try fx.append_ok(&w, pb);
    }
    {
        var w: Writer = undefined;
        try fx.open_ok(&w, tmp.dir, fx.opts(4, 1 << 20));
        defer w.deinit(testing.io, testing.allocator);

        try fx.expect_position(&w, 1, header_size + 46, 47);
        try testing.expectEqual(@as(Lsn, 23), w.durable_lsn); // What was read back is durable.
        try testing.expectEqual(@as(Lsn, 47), try fx.append_ok(&w, pc));
    }
    try fx.expect_log(tmp.dir, 4, &.{ 1, 23, 47 }, &.{ pa, pb, pc });
}

test "writer: an empty log reopens empty, and an empty payload is a 17 byte frame" {
    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    for (0..2) |_| {
        var w: Writer = undefined;
        try fx.open_ok(&w, tmp.dir, fx.opts(2, 1 << 20));
        defer w.deinit(testing.io, testing.allocator);

        try fx.expect_position(&w, 1, header_size, 1);
        try testing.expectEqual(@as(Lsn, 0), w.durable_lsn);
    }
    var w: Writer = undefined;
    try fx.open_ok(&w, tmp.dir, fx.opts(2, 1 << 20));
    defer w.deinit(testing.io, testing.allocator);

    try testing.expectEqual(@as(Lsn, 1), try fx.append_ok(&w, ""));
    try fx.expect_position(&w, 1, header_size + 17, 18);
}

test "writer: checkpoint, page image and consumer frames are framed and read back" {
    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    var image: [4 + 512]u8 = @splat(0xEE);
    std.mem.writeInt(u32, image[0..4], 9, .little);
    var redo: [8]u8 = undefined;
    {
        var w: Writer = undefined;
        try fx.open_ok(&w, tmp.dir, fx.opts(2, 1 << 20));
        defer w.deinit(testing.io, testing.allocator);

        try testing.expectEqual(@as(Lsn, 1), try w.append(testing.io, .page_image, &image));
        std.mem.writeInt(u64, &redo, w.next_lsn, .little); // Sharp checkpoint: redo = own LSN.
        const checkpoint_lsn = try w.append(testing.io, .checkpoint, &redo);
        try testing.expectEqual(@as(Lsn, 1 + 17 + 516), checkpoint_lsn);
        const consumer: frame.Type = @enumFromInt(200);
        _ = try w.append(testing.io, consumer, "mine");
        w.check_invariants();
    }
    var rd: rfx.Reader = undefined;
    try rfx.open_ok(&rd, tmp.dir, 2);
    defer rd.deinit(testing.io, testing.allocator);

    const first = (try rd.next(testing.io)).?;
    try testing.expectEqual(frame.Type.page_image, first.frame_type);
    try testing.expectEqualSlices(u8, &image, first.payload);
    const second = (try rd.next(testing.io)).?;
    try testing.expectEqual(frame.Type.checkpoint, second.frame_type);
    try testing.expectEqualSlices(u8, &redo, second.payload);
    const third = (try rd.next(testing.io)).?;
    try testing.expectEqual(@as(u8, 200), @intFromEnum(third.frame_type));
    try testing.expectEqualSlices(u8, "mine", third.payload);
    try rfx.expect_eof(&rd);
}

test "writer: a payload the format forbids is InvalidFrame and changes nothing" {
    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    var w: Writer = undefined;
    try fx.open_ok(&w, tmp.dir, fx.opts(2, 1 << 20));
    defer w.deinit(testing.io, testing.allocator);

    _ = try fx.append_ok(&w, pa);
    const lsn = w.next_lsn;
    const redo_zero: [8]u8 = @splat(0);
    var redo_over: [8]u8 = undefined;
    std.mem.writeInt(u64, &redo_over, lsn + 1, .little);
    const bad = [_]struct { frame_type: frame.Type, payload: []const u8 }{
        .{ .frame_type = .checkpoint, .payload = "short" },
        .{ .frame_type = .checkpoint, .payload = &redo_zero },
        .{ .frame_type = .checkpoint, .payload = &redo_over },
        .{ .frame_type = .page_image, .payload = "xyz" },
        .{ .frame_type = .page_image, .payload = &([_]u8{0} ** 100) },
        .{ .frame_type = @enumFromInt(0), .payload = pa },
        .{ .frame_type = @enumFromInt(4), .payload = pa },
        .{ .frame_type = @enumFromInt(127), .payload = pa },
    };
    for (bad) |case| {
        const refused = w.append(testing.io, case.frame_type, case.payload);
        try testing.expectError(error.InvalidFrame, refused);
        w.check_invariants();
        try fx.expect_position(&w, 1, header_size + 22, lsn);
    }
    var ok: [8]u8 = undefined; // The boundary: redo_lsn == own LSN is legal.
    std.mem.writeInt(u64, &ok, lsn, .little);
    _ = try w.append(testing.io, .checkpoint, &ok);
    _ = try fx.append_ok(&w, pb); // Not latched.
}

test "writer: the largest frame fits one segment, one byte more is PayloadTooLarge" {
    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    const big = try testing.allocator.alloc(u8, frame.payload_bytes_max + 1);
    defer testing.allocator.free(big);

    @memset(big, 0x5A);
    big[0] = 1;
    {
        var w: Writer = undefined;
        try fx.open_ok(&w, tmp.dir, fx.opts(4, 4096)); // A lone frame may exceed the option.
        defer w.deinit(testing.io, testing.allocator);

        const too_big = w.append(testing.io, .record, big);
        try testing.expectError(error.PayloadTooLarge, too_big);
        w.check_invariants();
        try fx.expect_position(&w, 1, header_size, 1);

        const lsn = try w.append(testing.io, .record, big[0..frame.payload_bytes_max]);
        w.check_invariants();
        try testing.expectEqual(@as(Lsn, 1), lsn);
        const end_lsn: Lsn = 1 + frame.frame_bytes_max;
        try fx.expect_position(&w, 1, header_size + frame.frame_bytes_max, end_lsn);
        _ = try fx.append_ok(&w, pa); // The segment holds a frame and is over: rotate.
        try fx.expect_position(&w, 2, header_size + 22, 1 + frame.frame_bytes_max + 22);
    }
    var rd: rfx.Reader = undefined;
    try rfx.open_ok(&rd, tmp.dir, 4);
    defer rd.deinit(testing.io, testing.allocator);

    try rfx.expect_record(&rd, 1, big[0..frame.payload_bytes_max]);
    try rfx.expect_record(&rd, 1 + frame.frame_bytes_max, pa);
    try rfx.expect_eof(&rd);
}

test "writer: a seeded run rotates exactly where the model says, and reads back whole" {
    const cases = [_]struct { seed: u64, segment_bytes_max: u64 }{
        .{ .seed = 0x5eed, .segment_bytes_max = 4096 },
        .{ .seed = 0xbeef, .segment_bytes_max = 4096 },
        .{ .seed = 0xf00d, .segment_bytes_max = 1000 },
        .{ .seed = 0xcafe, .segment_bytes_max = 70_000 },
    };
    for (cases) |case| try run_rotation_case(case.seed, case.segment_bytes_max);
}

fn run_rotation_case(seed: u64, segment_bytes_max: u64) !void {
    assert(segment_bytes_max > header_size);
    assert(seed != 0);
    const count = 150;
    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    var prng = std.Random.DefaultPrng.init(seed);
    var model = fx.Model.init(segment_bytes_max);
    var lsns: [count + 10]Lsn = undefined;
    var lens: [count + 10]usize = undefined;
    for (0..count + 10) |i| lens[i] = prng.random().uintAtMost(usize, 300);
    // Two sessions: the second reopens the log and must continue where the model is.
    for ([_]usize{ 0, 100 }, [_]usize{ 100, count + 10 }) |from, to| {
        var w: Writer = undefined;
        try fx.open_ok(&w, tmp.dir, fx.opts(64, segment_bytes_max));
        defer w.deinit(testing.io, testing.allocator);

        try fx.expect_position(&w, model.index, model.offset, model.next_lsn);
        for (from..to) |i| {
            lsns[i] = model.append(lens[i]);
            _ = try fx.append_ok(&w, fx.payload_of(i, lens[i]));
            try fx.expect_position(&w, model.index, model.offset, model.next_lsn);
            if (i % 17 == 0) {
                try w.sync(testing.io);
                try testing.expectEqual(lsns[i], w.durable_lsn);
            }
        }
        w.check_invariants();
    }
    var records: [count + 10][]const u8 = undefined;
    for (0..count + 10) |i| records[i] = fx.payload_of(i, lens[i]);
    try fx.expect_log(tmp.dir, 64, &lsns, &records);
    try fx.expect_segments(tmp.dir, &model);
    try testing.expect(model.index >= 2 or segment_bytes_max > 10_000);
}

test "writer: a frame ending exactly at segment_bytes_max stays, one byte more rotates" {
    const fits_two: u64 = header_size + 2 * (17 + 100);
    const cases = [_]struct { max: u64, index_after_two: u32, index_after_three: u32 }{
        .{ .max = fits_two, .index_after_two = 1, .index_after_three = 2 },
        .{ .max = fits_two - 1, .index_after_two = 2, .index_after_three = 3 },
    };
    for (cases) |case| {
        var tmp = testing.tmpDir(.{ .iterate = true });
        defer tmp.cleanup();
        var w: Writer = undefined;
        try fx.open_ok(&w, tmp.dir, fx.opts(4, case.max));
        defer w.deinit(testing.io, testing.allocator);

        const payload = fx.payload_of(0, 100);
        _ = try fx.append_ok(&w, payload);
        _ = try fx.append_ok(&w, payload);
        try testing.expectEqual(case.index_after_two, w.position().segment_index);
        _ = try fx.append_ok(&w, payload);
        try testing.expectEqual(case.index_after_three, w.position().segment_index);
    }
}

test "writer: segment_bytes_max applies to non-empty segments only, an empty one takes any frame" {
    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    var w: Writer = undefined;
    try fx.open_ok(&w, tmp.dir, fx.opts(4, 100));
    defer w.deinit(testing.io, testing.allocator);

    const payload = fx.payload_of(3, 200);
    _ = try fx.append_ok(&w, payload); // 217 B frame in an empty segment of "100 B".
    try fx.expect_position(&w, 1, header_size + 217, 218);
    _ = try fx.append_ok(&w, payload);
    try fx.expect_position(&w, 2, header_size + 217, 435);
    _ = try fx.append_ok(&w, payload);
    try fx.expect_position(&w, 3, header_size + 217, 652);
}

test "writer: SegmentLimit stops a rotation before any side effect and the writer goes on" {
    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    const room = header_size + 117 + 30; // One 117 B frame, then 30 B of room.
    {
        var w: Writer = undefined;
        try fx.open_ok(&w, tmp.dir, fx.opts(1, room));
        defer w.deinit(testing.io, testing.allocator);

        _ = try fx.append_ok(&w, fx.payload_of(0, 100));
        try w.sync(testing.io);
        for (0..2) |_| { // Repeatable: a typed limit, not a latch.
            const refused = w.append(testing.io, .record, fx.payload_of(1, 100));
            try testing.expectError(error.SegmentLimit, refused);
            w.check_invariants();
            try fx.expect_position(&w, 1, header_size + 117, 118);
            try testing.expectEqual(@as(Lsn, 1), w.durable_lsn);
        }
        try testing.expectEqual(@as(Lsn, 118), try fx.append_ok(&w, "")); // Still fits: 17 B.
    }
    try fx.expect_log(tmp.dir, 1, &.{ 1, 118 }, &.{ fx.payload_of(0, 100), "" });
    try sfx.expect_open_error(error.FileNotFound, tmp.dir, 2);
}

test "writer: a log over segments_max is SegmentLimit at init, and so is a full rotation" {
    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    const second = try rfx.put_segment(tmp.dir, 1, 1, &.{pa});
    const third = try rfx.put_segment(tmp.dir, 2, second, &.{pb});
    _ = try rfx.put_segment(tmp.dir, 3, third, &.{pc});
    try fx.expect_open_error(error.SegmentLimit, tmp.dir, fx.opts(2, 4096));

    var w: Writer = undefined;
    try fx.open_ok(&w, tmp.dir, fx.opts(3, 100));
    defer w.deinit(testing.io, testing.allocator);

    try fx.expect_position(&w, 3, header_size + 24, 1 + 22 + 24 + 24);
    const refused = w.append(testing.io, .record, fx.payload_of(0, 100));
    try testing.expectError(error.SegmentLimit, refused);
}

test "writer: the last segment index cannot rotate, SegmentIndexExhausted" {
    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    const last = std.math.maxInt(u32);
    _ = try rfx.put_segment(tmp.dir, last, 1, &.{pa});
    var w: Writer = undefined;
    try fx.open_ok(&w, tmp.dir, fx.opts(8, 100));
    defer w.deinit(testing.io, testing.allocator);

    try fx.expect_position(&w, last, header_size + 22, 23);
    const refused = w.append(testing.io, .record, fx.payload_of(0, 100));
    try testing.expectError(error.SegmentIndexExhausted, refused);
    w.check_invariants();
    try fx.expect_position(&w, last, header_size + 22, 23);
    _ = try fx.append_ok(&w, ""); // Fits without rotating: the writer is not latched.
}

test "writer: one writer per directory, the lock follows the newest segment" {
    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    var w: Writer = undefined;
    try fx.open_ok(&w, tmp.dir, fx.opts(4, 100));
    {
        defer w.deinit(testing.io, testing.allocator);

        _ = try fx.append_ok(&w, fx.payload_of(0, 100));
        try fx.expect_open_error(error.WouldBlock, tmp.dir, fx.opts(4, 100)); // Another writer.
        try rfx.expect_open_error(error.WouldBlock, tmp.dir, 4); // And a reader.

        _ = try fx.append_ok(&w, fx.payload_of(1, 100)); // Rotates: segment 2 is current.
        try fx.expect_position(&w, 2, header_size + 117, 1 + 2 * 117);
        try fx.expect_open_error(error.WouldBlock, tmp.dir, fx.opts(4, 100));
        try sfx.expect_open_ok(tmp.dir, 1, 1); // The old segment was released at the handoff.
        try sfx.expect_open_error(error.WouldBlock, tmp.dir, 2);
    }
    var again: Writer = undefined;
    try fx.open_ok(&again, tmp.dir, fx.opts(4, 100)); // `deinit` released the lock.
    defer again.deinit(testing.io, testing.allocator);

    try fx.expect_position(&again, 2, header_size + 117, 1 + 2 * 117);
}
