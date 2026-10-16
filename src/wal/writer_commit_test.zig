//! Contract tests for `Writer.commit` (ADR-0003 section 9, plan 004 item 6): the single
//! committer, a commit of an already durable LSN, eight concurrent committers sharing syncs, a
//! failed leader sync reaching its whole batch, the byte threshold skipping the window, and no
//! allocation after `init`. Concurrent tests assert order-free facts only (`durable_lsn >= upto`,
//! fewer syncs than commits): `std.testing.io` may run the tasks one after another or in
//! parallel. Shared helpers are in `writer_fixtures.zig`.

const std = @import("std");
const assert = std.debug.assert;
const testing = std.testing;
const Io = std.Io;
const fault_io = @import("../testing/fault_io.zig");
const frame = @import("frame.zig");
const fx = @import("writer_fixtures.zig");

const writer_mod = @import("writer.zig");
const Writer = fx.Writer;
const Lsn = fx.Lsn;

const committers_count: usize = 8;

fn commit_options(window_ms: i64, bytes_max: u32) writer_mod.Options {
    assert(window_ms >= 0);
    assert(bytes_max >= frame.frame_bytes_max);
    var options = fx.options(4, 1 << 20, .fsync);
    options.group_commit_window = Io.Duration.fromMilliseconds(window_ms);
    options.group_commit_bytes_max = bytes_max;
    return options;
}

const Slot = struct { upto: Lsn, result: ?anyerror = null, done: bool = false };

fn commit_task(w: *Writer, io: Io, slot: *Slot) void {
    assert(slot.upto >= frame.lsn_first);
    assert(!slot.done);
    w.commit(io, slot.upto) catch |err| {
        slot.result = err;
    };
    slot.done = true;
}

/// Appends `committers_count` frames and returns the slots, one per frame LSN.
fn append_batch(w: *Writer, slots: *[committers_count]Slot) !void {
    assert(slots.len == committers_count);
    assert(w.durable_lsn == w.last_lsn);
    for (slots, 0..) |*slot, i| {
        const lsn = try fx.append_ok(w, fx.payload_of(i, 10 + i));
        slot.* = .{ .upto = lsn };
    }
    try testing.expectEqual(@as(Lsn, 0), w.durable_lsn);
}

fn run_batch(w: *Writer, io: Io, slots: *[committers_count]Slot) !void {
    assert(slots.len == committers_count);
    assert(w.last_lsn >= slots[0].upto);
    var group: Io.Group = .init;
    for (slots) |*slot| group.async(testing.io, commit_task, .{ w, io, slot });
    try group.await(testing.io);
    for (slots) |slot| try testing.expect(slot.done);
}

test "commit: one committer syncs once and returns with durable_lsn >= upto" {
    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    var w: Writer = undefined;
    try fx.open_ok(&w, tmp.dir, commit_options(1, frame.frame_bytes_max));
    defer w.deinit(testing.io, testing.allocator);

    assert(w.stats.syncs == 0);
    assert(w.durable_lsn == 0);
    _ = try fx.append_ok(&w, fx.pa);
    const last = try fx.append_ok(&w, fx.pb);
    try testing.expectEqual(@as(u64, 0), w.stats.syncs);
    try w.commit(testing.io, last);
    w.check_invariants();
    try testing.expectEqual(last, w.durable_lsn);
    try testing.expectEqual(@as(u64, 1), w.stats.syncs);
    try testing.expectEqual(@as(u64, 1), w.stats.commits);
}

test "commit: an LSN that is already durable returns without a sync" {
    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    var w: Writer = undefined;
    try fx.open_ok(&w, tmp.dir, commit_options(1, frame.frame_bytes_max));
    defer w.deinit(testing.io, testing.allocator);

    assert(w.stats.commits == 0);
    assert(!w.failed);
    const first = try fx.append_ok(&w, fx.pa);
    const second = try fx.append_ok(&w, fx.pb);
    try w.commit(testing.io, second);
    try w.commit(testing.io, first); // Prefix closed: durable already.
    try w.commit(testing.io, second);
    try w.commit(testing.io, 0); // Nothing to wait for.
    try testing.expectEqual(second, w.durable_lsn);
    try testing.expectEqual(@as(u64, 1), w.stats.syncs);
    try testing.expectEqual(@as(u64, 4), w.stats.commits);
}

test "commit: eight committers share syncs and all return durable" {
    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    var w: Writer = undefined;
    try fx.open_ok(&w, tmp.dir, commit_options(20, frame.frame_bytes_max));
    defer w.deinit(testing.io, testing.allocator);

    var slots: [committers_count]Slot = undefined;
    assert(w.stats.syncs == 0);
    assert(slots.len == 8);
    try append_batch(&w, &slots);
    try run_batch(&w, testing.io, &slots);
    for (slots) |slot| {
        try testing.expectEqual(@as(?anyerror, null), slot.result);
        try testing.expect(w.durable_lsn >= slot.upto);
    }
    w.check_invariants();
    try testing.expectEqual(@as(u64, committers_count), w.stats.commits);
    try testing.expect(w.stats.syncs >= 1);
    try testing.expect(w.stats.syncs < w.stats.commits);
    try testing.expectEqual(slots[committers_count - 1].upto, w.durable_lsn);
}

test "commit: a failed leader sync reaches its whole batch and latches the writer" {
    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    var fio: fault_io.FaultIo = undefined;
    const plan: fault_io.Plan = .{
        .write = .none,
        .read = .none,
        .after_calls = 0,
        .sync_fail_after = 0,
    };
    fault_io.FaultIo.init(&fio, testing.io, plan);
    var w: Writer = undefined;
    try fx.open_ok(&w, tmp.dir, commit_options(20, frame.frame_bytes_max));
    defer w.deinit(testing.io, testing.allocator);

    var slots: [committers_count]Slot = undefined;
    assert(fio.sync_calls == 0);
    assert(!w.failed);
    try append_batch(&w, &slots);
    try run_batch(&w, fio.io(), &slots);
    var io_errors: usize = 0;
    for (slots) |slot| {
        const err = slot.result orelse return error.TestUnexpectedResult;
        if (err == error.InputOutput) {
            io_errors += 1;
        } else {
            try testing.expectEqual(error.Failed, err);
        }
    }
    try testing.expect(io_errors >= 1); // The leader, and with real overlap its followers.
    try testing.expectEqual(@as(Lsn, 0), w.durable_lsn); // Never advanced.
    try testing.expectEqual(@as(u32, 1), fio.sync_calls); // Never retried.
    try testing.expectError(error.Failed, w.commit(fio.io(), slots[0].upto));
    try testing.expectEqual(@as(u32, 1), fio.sync_calls);
    w.check_invariants();
}

test "commit: pending bytes at the threshold skip the window" {
    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    var w: Writer = undefined;
    var options = commit_options(10_000, frame.frame_bytes_max);
    options.segment_bytes_max = 8 << 20; // No rotation: a rotation would sync and hide the test.
    try fx.open_ok(&w, tmp.dir, options);
    defer w.deinit(testing.io, testing.allocator);

    assert(w.durable_lsn == 0);
    assert(w.options.group_commit_window.nanoseconds > 0);
    const big = try testing.allocator.alloc(u8, 400_000);
    defer testing.allocator.free(big);

    @memset(big, 0x5a);
    var last: Lsn = 0;
    for (0..3) |_| last = try w.append(testing.io, .record, big);
    const started = Io.Clock.awake.now(testing.io);
    try w.commit(testing.io, last);
    const waited = started.durationTo(Io.Clock.awake.now(testing.io));
    const limit = Io.Duration.fromSeconds(5);
    try testing.expect(waited.nanoseconds < limit.nanoseconds); // The 10 s window was skipped.
    try testing.expectEqual(last, w.durable_lsn);
}

test "commit: no allocation after init" {
    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    var failing = testing.FailingAllocator.init(testing.allocator, .{});
    var w: Writer = undefined;
    const options = commit_options(1, frame.frame_bytes_max);
    try Writer.init(&w, testing.io, failing.allocator(), tmp.dir, options);
    defer w.deinit(testing.io, failing.allocator());

    failing.fail_index = failing.alloc_index; // Armed: any further allocation fails.
    const allocs = failing.alloc_index;
    var slots: [committers_count]Slot = undefined;
    assert(allocs == failing.alloc_index);
    assert(failing.fail_index == allocs);
    try append_batch(&w, &slots);
    try run_batch(&w, testing.io, &slots);
    for (slots) |slot| try testing.expectEqual(@as(?anyerror, null), slot.result);
    try testing.expectEqual(allocs, failing.alloc_index);
}
