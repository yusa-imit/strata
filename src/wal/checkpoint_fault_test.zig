//! Fault tests for `Checkpoint.run` (plan 004 item 10, ADR-0003 section 10): every sync and every
//! write of a checkpoint is failed in turn through a `FaultIo`; whichever step fails, a cold
//! start (`redo_start`, `Recovery.replay` through `PageRedo`) reaches the model state, from the
//! old or the new `wal_lsn`. A dry run counts the calls, so the sweep covers all five steps and
//! the reclaim without naming call numbers; `Checkpoint.stage` proves each step was hit. Helpers
//! are in `checkpoint_fixtures.zig`.

const std = @import("std");
const assert = std.debug.assert;
const testing = std.testing;
const fault_io = @import("../testing/fault_io.zig");
const checkpoint = @import("checkpoint.zig");
const fx = @import("checkpoint_fixtures.zig");

const Env = fx.Env;
const Stage = checkpoint.Stage;
const sizes_fault = [_]u32{ 512, 4096, 65536 };

fn bit(stage: Stage) u32 {
    assert(@intFromEnum(stage) < 32);
    assert(sizes_fault.len == 3);
    return @as(u32, 1) << @as(u5, @intCast(@intFromEnum(stage)));
}

/// Two edits, a first checkpoint (reclaims them), two more edits made durable: the state a
/// second checkpoint starts from, so a failure leaves an old `wal_lsn` that is not 0.
fn prepare(env: *Env, size: u32) !void {
    assert(size >= 512);
    assert(sizes_fault.len > 0);
    try env.init(size, 8, 1, .fsync);
    errdefer env.deinit();

    _ = try env.edit(1, 11);
    _ = try env.edit(2, 12);
    const first = try env.cp.run(testing.io);
    assert(first.redo_lsn == env.pm.wal_lsn);
    _ = try env.edit(2, 22);
    _ = try env.edit(3, 23);
    try env.log.sync(testing.io);
}

fn plan(write: fault_io.Fault, sync_fail_after: ?u32, after_calls: u32) fault_io.Plan {
    assert(write != .short);
    assert(sync_fail_after == null or sync_fail_after.? < 64);
    return .{
        .write = write,
        .read = .none,
        .after_calls = after_calls,
        .sync_fail_after = sync_fail_after,
    };
}

const Counts = struct { syncs: u32, writes: u32 };

/// The second checkpoint without faults: how many syncs and writes it makes.
fn dry_run(size: u32) !Counts {
    assert(size >= 512);
    assert(size <= 65536);
    var env: Env = undefined;
    try prepare(&env, size);
    defer env.deinit();

    var fio: fault_io.FaultIo = undefined;
    fault_io.FaultIo.init(&fio, testing.io, plan(.none, null, 0));
    const result = try env.cp.run(fio.io());
    // Segments 3 (checkpoint 1), 4 and 5 (the edits) go; 6 holds the second checkpoint.
    try testing.expectEqual(@as(u32, 3), result.segments_reclaimed);
    try testing.expectEqual(Stage.reclaimed, env.cp.stage);
    return .{ .syncs = fio.sync_calls, .writes = fio.write_calls };
}

/// Runs the second checkpoint under `faults`, expects it to fail, drops every handle without
/// syncing, and recovers cold. Returns the stage the failure left.
fn fail_and_recover(size: u32, faults: fault_io.Plan) !Stage {
    assert(size >= 512);
    assert(faults.sync_fail_after != null or faults.write != .none);
    var env: Env = undefined;
    try prepare(&env, size);
    defer env.deinit();

    var fio: fault_io.FaultIo = undefined;
    fault_io.FaultIo.init(&fio, testing.io, faults);
    const old_wal_lsn = env.pm.wal_lsn;
    try testing.expect(old_wal_lsn >= 1);
    if (env.cp.run(fio.io())) |_| return error.TestExpectedError else |_| {}
    const stage = env.cp.stage;
    const new_redo = env.cp.redo_lsn;
    try testing.expect(stage != Stage.reclaimed);

    env.close_handles();
    const got = try fx.recover(env.tmp.dir, size, 8, &env.model);
    // The disk holds the old or the new start, never anything else.
    try testing.expect(got.wal_lsn == old_wal_lsn or got.wal_lsn == new_redo);
    try testing.expect(got.from_lsn == old_wal_lsn or got.from_lsn == new_redo);
    return stage;
}

test "run: failing any sync or write of a checkpoint recovers to the model state" {
    for (sizes_fault) |size| {
        const counts = try dry_run(size);
        // Segment sync, creation sync, directory sync, commit, two page syncs, directory sync.
        try testing.expectEqual(@as(u32, 7), counts.syncs);
        try testing.expect(counts.writes >= 5); // Header, frame, two pages, page 0.
        var seen: u32 = 0;
        for (0..counts.syncs) |k| {
            const stage = try fail_and_recover(size, plan(.none, @intCast(k), 0));
            seen |= bit(stage);
        }
        for (0..counts.writes) |k| {
            const stage = try fail_and_recover(size, plan(.zero, null, @intCast(k)));
            seen |= bit(stage);
        }
        // Every step of the checkpoint, and the reclaim, was the one that failed in some run.
        const steps = [_]Stage{
            .idle, .logged, .flushed, .pages_synced, .header_set, .header_synced,
        };
        for (steps) |step| try testing.expect(seen & bit(step) != 0);
        try testing.expect(seen & bit(.reclaimed) == 0);
    }
}

test "run: a canceled write fails the step the same way" {
    const counts = try dry_run(512);
    for (0..counts.writes) |k| {
        const stage = try fail_and_recover(512, plan(.canceled, null, @intCast(k)));
        try testing.expect(stage != Stage.reclaimed);
    }
}

test "run: a failed log step latches the writer, and a later run says Failed" {
    var env: Env = undefined;
    try prepare(&env, 512);
    defer env.deinit();

    const writebacks = env.pool.stats().writebacks;
    var fio: fault_io.FaultIo = undefined;
    fault_io.FaultIo.init(&fio, testing.io, plan(.none, 0, 0)); // Every sync fails.
    try testing.expectError(error.InputOutput, env.cp.run(fio.io()));
    try testing.expectEqual(Stage.idle, env.cp.stage);
    try testing.expectError(error.Failed, env.cp.run(testing.io));
    try testing.expectEqual(Stage.idle, env.cp.stage);
    try testing.expectEqual(writebacks, env.pool.stats().writebacks); // Nothing flushed.
}

test "reclaim: FaultIo forwards the deletes, so a checkpoint under it deletes segments" {
    var env: Env = undefined;
    try prepare(&env, 512);
    defer env.deinit();

    var fio: fault_io.FaultIo = undefined;
    fault_io.FaultIo.init(&fio, testing.io, plan(.none, null, 0));
    _ = try env.cp.run(fio.io());
    try env.expect_segments(6, 6);
    try testing.expectEqual(@as(u32, 1), env.log.live_count);
}
