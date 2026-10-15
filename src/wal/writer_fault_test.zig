//! Contract tests for `Writer` under faults (ADR-0003 sections 5 and 9): a failing sync never
//! advances `durable_lsn` and latches the writer, failed and short writes, a fault at each of the
//! three syncs of a rotation, no allocation after `init`, and the end of the LSN space. The
//! writer's own `init` always runs on `std.testing.io` (it lists the directory, which `FaultIo`
//! does not forward); only the calls under test go through the `FaultIo`. Behaviour is in
//! `writer_test.zig`; shared helpers are in `writer_fixtures.zig`.

const std = @import("std");
const assert = std.debug.assert;
const testing = std.testing;
const fault_io = @import("../testing/fault_io.zig");
const frame = @import("frame.zig");
const fx = @import("writer_fixtures.zig");
const rfx = @import("reader_fixtures.zig");
const sfx = @import("segment_fixtures.zig");

const Writer = fx.Writer;
const Lsn = fx.Lsn;
const pa = fx.pa;
const pb = fx.pb;
const header_size = fx.header_size;

fn sync_plan(sync_fail_after: ?u32) fault_io.Plan {
    assert(sync_fail_after == null or sync_fail_after.? < 16);
    assert(header_size == 24);
    return .{ .write = .none, .read = .none, .after_calls = 0, .sync_fail_after = sync_fail_after };
}

fn write_plan(write: fault_io.Fault) fault_io.Plan {
    assert(write != .none);
    assert(write != .short or write.short >= 1);
    return .{ .write = write, .read = .none, .after_calls = 0 };
}

test "writer: a failing sync leaves durable_lsn unchanged and latches the writer" {
    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    var fio: fault_io.FaultIo = undefined;
    fault_io.FaultIo.init(&fio, testing.io, sync_plan(1));
    const io = fio.io();
    {
        var w: Writer = undefined;
        try fx.open_ok(&w, tmp.dir, fx.options(4, 1 << 20, .fsync));
        defer w.deinit(testing.io, testing.allocator);

        try testing.expectEqual(@as(Lsn, 1), try w.append(io, .record, pa));
        try w.sync(io); // Sync call 0 passes.
        try testing.expectEqual(@as(Lsn, 1), w.durable_lsn);
        try testing.expectEqual(@as(Lsn, 23), try w.append(io, .record, pb));
        try testing.expectError(error.InputOutput, w.sync(io)); // Call 1 fails.
        w.check_invariants();
        try testing.expectEqual(@as(Lsn, 1), w.durable_lsn); // Never advanced.
        try fx.expect_position(&w, 1, header_size + 46, 47);

        try testing.expectError(error.Failed, w.append(io, .record, pa)); // Latched.
        try testing.expectError(error.Failed, w.sync(io)); // Never retried.
        try testing.expectEqual(@as(u32, 2), fio.sync_calls);
        try testing.expectEqual(@as(Lsn, 1), w.durable_lsn);
        try fx.expect_position(&w, 1, header_size + 46, 47);
    }
    // Reopening is the way out: both frames were written, so both are read back.
    var w: Writer = undefined;
    try fx.open_ok(&w, tmp.dir, fx.options(4, 1 << 20, .fsync));
    defer w.deinit(testing.io, testing.allocator);

    try fx.expect_position(&w, 1, header_size + 46, 47);
    try testing.expectEqual(@as(Lsn, 23), w.durable_lsn);
    try testing.expectEqual(@as(Lsn, 47), try fx.append_ok(&w, pa));
}

test "writer: a failed or canceled write latches without moving the position" {
    const cases = [_]struct { fault: fault_io.Fault, want: anyerror }{
        .{ .fault = .canceled, .want = error.Canceled },
        .{ .fault = .zero, .want = error.NoSpaceLeft },
    };
    for (cases) |case| {
        var tmp = testing.tmpDir(.{ .iterate = true });
        defer tmp.cleanup();
        var fio: fault_io.FaultIo = undefined;
        fault_io.FaultIo.init(&fio, testing.io, write_plan(case.fault));
        const io = fio.io();
        {
            var w: Writer = undefined;
            try fx.open_ok(&w, tmp.dir, fx.opts(4, 1 << 20));
            defer w.deinit(testing.io, testing.allocator);

            try testing.expectError(case.want, w.append(io, .record, pa));
            w.check_invariants();
            try fx.expect_position(&w, 1, header_size, 1);
            try testing.expectError(error.Failed, w.append(testing.io, .record, pa));
            try testing.expectError(error.Failed, w.sync(testing.io));
            try testing.expectEqual(@as(Lsn, 0), w.durable_lsn);
        }
        try fx.expect_log(tmp.dir, 4, &.{}, &.{}); // Nothing reached the file.
    }
}

test "writer: short writes still land whole frames" {
    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    var fio: fault_io.FaultIo = undefined;
    fault_io.FaultIo.init(&fio, testing.io, write_plan(.{ .short = 3 }));
    {
        var w: Writer = undefined;
        try fx.open_ok(&w, tmp.dir, fx.opts(4, 1 << 20));
        defer w.deinit(testing.io, testing.allocator);

        try testing.expectEqual(@as(Lsn, 1), try w.append(fio.io(), .record, pa));
        try testing.expectEqual(@as(Lsn, 23), try w.append(fio.io(), .record, pb));
        w.check_invariants();
        try testing.expectEqual(@as(u32, 16), fio.write_calls); // ceil(22 / 3) + ceil(24 / 3)
    }
    try fx.expect_log(tmp.dir, 4, &.{ 1, 23 }, &.{ pa, pb });
}

test "writer: a sync fault at each step of a rotation latches and loses nothing" {
    const room: u64 = header_size + 2 * 117;
    // Rotation syncs three times: the old segment, the new header, the directory.
    const cases = [_]struct { fail_at: u32, durable: Lsn, new_segment: bool }{
        .{ .fail_at = 0, .durable = 0, .new_segment = false },
        .{ .fail_at = 1, .durable = 118, .new_segment = true },
        .{ .fail_at = 2, .durable = 118, .new_segment = true },
    };
    for (cases) |case| {
        var tmp = testing.tmpDir(.{ .iterate = true });
        defer tmp.cleanup();
        var fio: fault_io.FaultIo = undefined;
        fault_io.FaultIo.init(&fio, testing.io, sync_plan(case.fail_at));
        {
            var w: Writer = undefined;
            try fx.open_ok(&w, tmp.dir, fx.options(4, room, .fsync));
            defer w.deinit(testing.io, testing.allocator);

            _ = try fx.append_ok(&w, fx.payload_of(0, 100));
            _ = try fx.append_ok(&w, fx.payload_of(1, 100));
            const refused = w.append(fio.io(), .record, fx.payload_of(2, 100));
            try testing.expectError(error.InputOutput, refused);
            w.check_invariants();
            try testing.expectEqual(case.durable, w.durable_lsn);
            try fx.expect_position(&w, 1, room, 235);
            try testing.expectError(error.Failed, w.append(testing.io, .record, pa));
        }
        if (case.new_segment) {
            try sfx.expect_open_ok(tmp.dir, 2, 235); // A whole, empty successor on disk.
        } else {
            try sfx.expect_open_error(error.FileNotFound, tmp.dir, 2);
        }
        var w: Writer = undefined;
        try fx.open_ok(&w, tmp.dir, fx.options(4, room, .fsync)); // Recovery is just a reopen.
        defer w.deinit(testing.io, testing.allocator);

        if (case.new_segment) try fx.expect_position(&w, 2, header_size, 235);
        if (!case.new_segment) try fx.expect_position(&w, 1, room, 235);
        _ = try fx.append_ok(&w, fx.payload_of(2, 100));
        try fx.expect_position(&w, 2, header_size + 117, 352);
    }
}

test "writer: with no fault a rotation syncs the old segment, so durable_lsn follows it" {
    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    var fio: fault_io.FaultIo = undefined;
    fault_io.FaultIo.init(&fio, testing.io, sync_plan(3));
    var w: Writer = undefined;
    try fx.open_ok(&w, tmp.dir, fx.options(4, header_size + 117, .fsync));
    defer w.deinit(testing.io, testing.allocator);

    _ = try w.append(fio.io(), .record, fx.payload_of(0, 100));
    try testing.expectEqual(@as(Lsn, 0), w.durable_lsn);
    try testing.expectEqual(@as(Lsn, 118), try w.append(fio.io(), .record, fx.payload_of(1, 100)));
    try testing.expectEqual(@as(Lsn, 1), w.durable_lsn); // The first frame's segment is synced.
    try testing.expectEqual(@as(u32, 3), fio.sync_calls);
    w.check_invariants();
}

test "writer: init allocates on failure paths cleanly, and nothing allocates after it" {
    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();

    for (0..3) |fail_index| { // The batch buffer and the reader's two allocations.
        const plan: testing.FailingAllocator.Config = .{ .fail_index = fail_index };
        var failing = testing.FailingAllocator.init(testing.allocator, plan);
        var w: Writer = undefined;
        const got = Writer.init(&w, testing.io, failing.allocator(), tmp.dir, fx.opts(4, 4096));
        try testing.expectError(error.OutOfMemory, got);
    }
    var failing = testing.FailingAllocator.init(testing.allocator, .{});
    var w: Writer = undefined;
    try Writer.init(&w, testing.io, failing.allocator(), tmp.dir, fx.opts(64, 4096));
    defer w.deinit(testing.io, failing.allocator());

    failing.fail_index = failing.alloc_index; // Armed: any further allocation fails.
    const allocs = failing.alloc_index;
    for (0..150) |i| _ = try w.append(testing.io, .record, fx.payload_of(i, i % 200));
    try w.sync(testing.io);
    try testing.expect(w.position().segment_index >= 3); // Rotated more than once.
    try testing.expectEqual(allocs, failing.alloc_index);
    w.check_invariants();
}

test "writer: the end of the LSN space is LsnExhausted and changes nothing" {
    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    const first: Lsn = frame.lsn_limit - 30;
    _ = try rfx.put_segment(tmp.dir, 1, first, &.{});
    var w: Writer = undefined;
    try fx.open_ok(&w, tmp.dir, fx.opts(4, 1 << 20));
    defer w.deinit(testing.io, testing.allocator);

    try fx.expect_position(&w, 1, header_size, first);
    const thirteen = fx.payload_of(0, 13); // 30 B: would end at lsn_limit, one past the last LSN.
    try testing.expectError(error.LsnExhausted, w.append(testing.io, .record, thirteen));
    w.check_invariants();
    try fx.expect_position(&w, 1, header_size, first);

    // A 29 B frame: the last one that fits, it ends at limit - 1.
    try testing.expectEqual(first, try fx.append_ok(&w, fx.payload_of(0, 12)));
    try testing.expectEqual(frame.lsn_limit - 1, w.next_lsn);
    try testing.expectError(error.LsnExhausted, w.append(testing.io, .record, ""));
    w.check_invariants();
    try testing.expectEqual(frame.lsn_limit - 1, w.next_lsn);
    try w.sync(testing.io); // Not latched: the writer is full, not broken.
    try testing.expectEqual(first, w.durable_lsn);
}
