//! Contract tests for `Checkpoint` and `redo_start` (plan 004 item 10, ADR-0003 section 10): the
//! happy path with its reclaim at all eight page sizes, the active segment is never deleted,
//! `reclaim` keeps segments at or after the checkpoint, `live_count` is lowered so rotation
//! goes on, the start derivation (`wal_lsn == 0`, an intact `checkpoint` frame, else
//! `Corrupted`), and the typed errors. Faults at each step are in `checkpoint_fault_test.zig`;
//! helpers are in `checkpoint_fixtures.zig`.

const std = @import("std");
const assert = std.debug.assert;
const testing = std.testing;
const checkpoint = @import("checkpoint.zig");
const frame = @import("frame.zig");
const fx = @import("checkpoint_fixtures.zig");
const segment = @import("segment.zig");
const sfx = @import("segment_fixtures.zig");
const pfx = @import("../page/manager_fixtures.zig");

const Env = fx.Env;
const Lsn = fx.Lsn;
const frames_all_in_one: u32 = 100;

fn start_of(env: *const Env, wal_lsn: u64) checkpoint.StartError!Lsn {
    assert(env.segments_max >= 1);
    assert(wal_lsn < frame.lsn_limit + 1);
    const options = fx.seg_options(env.segments_max, .none);
    return checkpoint.redo_start(testing.io, testing.allocator, env.tmp.dir, wal_lsn, options);
}

test "run: pages durable, wal_lsn advances, old segments gone, the newest kept" {
    for (fx.sizes_all) |size| {
        var env: Env = undefined;
        try env.init(size, 8, 1, .none);
        defer env.deinit();

        _ = try env.edit(1, 11);
        _ = try env.edit(2, 12);
        _ = try env.edit(3, 13);
        try env.expect_segments(1, 3);
        const result = try env.cp.run(testing.io);

        try testing.expectEqual(env.log.last_lsn, result.redo_lsn);
        try testing.expectEqual(@as(u32, 3), result.segments_reclaimed);
        try testing.expectEqual(checkpoint.Stage.reclaimed, env.cp.stage);
        try testing.expectEqual(result.redo_lsn, env.pm.wal_lsn);
        try testing.expectEqual(@as(u32, 1), env.log.live_count);
        try env.expect_segments(4, 4);
        try testing.expectEqual(@as(u32, 0), env.pool.dirty_count);
        try env.model.expect_pages(&env.pm); // On disk now, not only in the pool.
        env.log.check_invariants();

        // More work after the checkpoint, then a cold start from the checkpoint alone.
        const lsn = try env.edit(3, 33);
        env.close_handles();
        const got = try fx.recover(env.tmp.dir, size, 8, &env.model);
        try testing.expectEqual(result.redo_lsn, got.from_lsn);
        try testing.expectEqual(result.redo_lsn, got.wal_lsn);
        try testing.expectEqual(lsn, got.last_lsn);
        try testing.expectEqual(@as(u64, 1), got.applied); // Only the edit after the checkpoint.
    }
}

test "run: the active segment is never deleted, one segment holds the checkpoint frame" {
    for (fx.sizes_all) |size| {
        var env: Env = undefined;
        try env.init(size, 4, frames_all_in_one, .none);
        defer env.deinit();

        _ = try env.edit(1, 11);
        const result = try env.cp.run(testing.io);
        try testing.expectEqual(@as(u32, 0), result.segments_reclaimed);
        try testing.expectEqual(@as(u32, 1), env.log.live_count);
        try testing.expectEqual(@as(u32, 1), env.log.current.index);
        try env.expect_segments(1, 1);
        const again = try env.cp.run(testing.io); // A second checkpoint, same segment.
        try testing.expect(again.redo_lsn > result.redo_lsn);
        try testing.expectEqual(again.redo_lsn, env.pm.wal_lsn);
        try env.expect_segments(1, 1);
        env.close_handles();

        const got = try fx.recover(env.tmp.dir, size, 4, &env.model);
        try testing.expectEqual(again.redo_lsn, got.from_lsn);
        try testing.expectEqual(@as(u64, 0), got.applied);
    }
}

test "reclaim: keeps the segment holding the checkpoint and every later one" {
    var env: Env = undefined;
    try env.init(512, 8, 1, .none);
    defer env.deinit();

    _ = try env.edit(1, 11);
    _ = try env.edit(2, 12);
    const first = try env.cp.run(testing.io); // Checkpoint frame alone in segment 3.
    try env.expect_segments(3, 3);
    _ = try env.edit(1, 21); // Segment 4.
    _ = try env.edit(2, 22); // Segment 5.
    try testing.expectEqual(@as(u32, 0), try env.cp.reclaim(testing.io));
    try env.expect_segments(3, 5);
    try testing.expectEqual(@as(u32, 3), env.log.live_count);
    try testing.expectEqual(first.redo_lsn, env.cp.redo_lsn);

    const second = try env.cp.run(testing.io); // Segment 6 takes C; 3, 4, 5 go.
    try testing.expectEqual(@as(u32, 3), second.segments_reclaimed);
    try env.expect_segments(6, 6);
    try testing.expectEqual(@as(u32, 1), env.log.live_count);
}

test "reclaim: lowers live_count, so rotation continues past segments_max" {
    var env: Env = undefined;
    try env.init(512, 3, 1, .none);
    defer env.deinit();

    _ = try env.edit(1, 11);
    _ = try env.edit(2, 12);
    const result = try env.cp.run(testing.io);
    try testing.expectEqual(@as(u32, 2), result.segments_reclaimed);
    try testing.expectEqual(@as(u32, 1), env.log.live_count);
    _ = try env.edit(3, 13); // Segment 4: five segments were made in all, three is the limit.
    _ = try env.edit(1, 14); // Segment 5.
    try testing.expectEqual(@as(u32, 3), env.log.live_count);
    try testing.expectError(error.SegmentLimit, env.edit(2, 15));
    env.log.check_invariants();
}

test "redo_start: wal_lsn 0 starts at the beginning, also for an empty or checkpoint-less log" {
    var env: Env = undefined;
    try env.init(1024, 4, 1, .none);
    defer env.deinit();

    try testing.expectEqual(@as(Lsn, 0), try start_of(&env, 0)); // Locked? 0 opens nothing.
    _ = try env.edit(1, 11);
    _ = try env.edit(2, 12);
    env.close_handles();
    try testing.expectEqual(@as(Lsn, 0), try start_of(&env, 0));
    const got = try fx.recover(env.tmp.dir, 1024, 4, &env.model);
    try testing.expectEqual(@as(Lsn, 0), got.from_lsn);
    try testing.expectEqual(@as(u64, 2), got.applied);

    var empty = std.testing.tmpDir(.{ .iterate = true });
    defer empty.cleanup();

    const options = fx.seg_options(4, .none);
    const none = try checkpoint.redo_start(testing.io, testing.allocator, empty.dir, 0, options);
    try testing.expectEqual(@as(Lsn, 0), none);
}

test "redo_start: the frame at wal_lsn must be an intact checkpoint frame" {
    for (fx.sizes_all) |size| {
        var env: Env = undefined;
        try env.init(size, 4, frames_all_in_one, .none);
        defer env.deinit();

        const first = try env.edit(1, 11);
        _ = try env.edit(2, 12);
        const result = try env.cp.run(testing.io);
        env.close_handles();

        try testing.expectEqual(result.redo_lsn, try start_of(&env, result.redo_lsn));
        const corrupted = error.Corrupted;
        try testing.expectError(corrupted, start_of(&env, first)); // A page_image frame.
        try testing.expectError(corrupted, start_of(&env, first + 1)); // Inside a frame.
        try testing.expectError(corrupted, start_of(&env, result.redo_lsn + 1));
        const end = result.redo_lsn + frame.frame_header_size + 8;
        try testing.expectError(corrupted, start_of(&env, end)); // At the end of the log.
        try testing.expectError(corrupted, start_of(&env, end + 1000)); // Past it.
        try testing.expectError(corrupted, start_of(&env, frame.lsn_limit)); // Not an LSN.
    }
}

test "redo_start: a start below the oldest segment, or in a foreign log, is Corrupted" {
    var env: Env = undefined;
    try env.init(512, 8, 1, .none);
    defer env.deinit();

    _ = try env.edit(1, 11);
    _ = try env.edit(2, 12);
    const result = try env.cp.run(testing.io); // Segments 1 and 2 are reclaimed.
    env.close_handles();
    try testing.expectEqual(result.redo_lsn, try start_of(&env, result.redo_lsn));
    try testing.expectError(error.Corrupted, start_of(&env, 1)); // Reclaimed: below the oldest.

    // A foreign log that has a frame boundary at the same LSN, but not a checkpoint frame.
    var other: Env = undefined;
    try other.init(512, 8, frames_all_in_one, .none);
    defer other.deinit();

    _ = try other.edit(1, 41);
    _ = try other.edit(2, 42);
    const third = try other.edit(3, 43);
    try testing.expectEqual(result.redo_lsn, third); // The same position, another log.
    other.close_handles();
    try testing.expectError(error.Corrupted, start_of(&other, result.redo_lsn));
    var empty = std.testing.tmpDir(.{ .iterate = true });
    defer empty.cleanup();

    const options = fx.seg_options(4, .none);
    const got = checkpoint.redo_start(testing.io, testing.allocator, empty.dir, 5, options);
    try testing.expectError(error.Corrupted, got); // No log at all.
}

test "redo_start: a damaged checkpoint frame is Corrupted, damage before it passes through" {
    var env: Env = undefined;
    try env.init(512, 4, frames_all_in_one, .none);
    defer env.deinit();

    const first = try env.edit(1, 11);
    const result = try env.cp.run(testing.io);
    env.close_handles();
    const frame_bytes: u64 = frame.frame_header_size + 4 + 512;
    const handle = try sfx.raw_open(env.tmp.dir, 1);
    defer handle.close(testing.io);

    const at_checkpoint = segment.segment_header_size + frame_bytes + frame.frame_header_size;
    try sfx.flip_bit(handle, at_checkpoint, 0); // In the checkpoint payload: a torn tail.
    try testing.expectError(error.Corrupted, start_of(&env, result.redo_lsn));
    try sfx.flip_bit(handle, at_checkpoint, 0); // Restored.
    try testing.expectEqual(result.redo_lsn, try start_of(&env, result.redo_lsn));

    const at_image = segment.segment_header_size + frame.frame_header_size + 10;
    try sfx.flip_bit(handle, at_image, 0); // A bad frame followed by an intact one.
    try testing.expectError(error.ChecksumMismatch, start_of(&env, result.redo_lsn));
    try testing.expect(first < result.redo_lsn);
}

test "redo_start: reader limits and locks are passed through" {
    var env: Env = undefined;
    try env.init(512, 4, 1, .none);
    defer env.deinit();

    _ = try env.edit(1, 11);
    _ = try env.edit(2, 12);
    try testing.expectError(error.WouldBlock, start_of(&env, 5)); // The writer holds a segment.
    env.close_handles();
    const options = fx.seg_options(1, .none);
    const got = checkpoint.redo_start(testing.io, testing.allocator, env.tmp.dir, 5, options);
    try testing.expectError(error.SegmentLimit, got); // Two segments, one allowed.
}

test "run: a page file ahead of the log is Corrupted before any side effect" {
    var env: Env = undefined;
    try env.init(512, 4, 1, .none);
    defer env.deinit();

    _ = try env.edit(1, 11);
    try env.pm.set_wal_lsn(testing.io, env.log.next_lsn); // Not below the checkpoint's LSN.
    const before = env.log.position();
    try testing.expectError(error.Corrupted, env.cp.run(testing.io));
    try testing.expectEqual(checkpoint.Stage.idle, env.cp.stage);
    try testing.expectEqual(before, env.log.position()); // Nothing was appended.
    try testing.expectEqual(@as(u32, 1), env.pool.dirty_count);
}

test "run: a dirty page ahead of the log is PagesAheadOfLog before anything is appended" {
    var env: Env = undefined;
    try env.init(512, 4, frames_all_in_one, .none);
    defer env.deinit();

    const lsn = try env.edit(1, 11);
    try testing.expectEqual(lsn, env.pool.dirty_lsn_max());
    var guard = try env.pool.fetchForUpdate(testing.io, pfx.id_of(2));
    guard.set_lsn(1 << 40); // A page change the log never described.
    guard.release();
    try testing.expectEqual(@as(u64, 1 << 40), env.pool.dirty_lsn_max());
    const before = env.log.position();
    try testing.expectError(error.PagesAheadOfLog, env.cp.run(testing.io));
    try testing.expectEqual(checkpoint.Stage.idle, env.cp.stage);
    try testing.expectEqual(before, env.log.position()); // No checkpoint frame was written.
    try testing.expectEqual(@as(u64, 0), env.pm.wal_lsn);
    try testing.expectEqual(@as(u32, 2), env.pool.dirty_count); // Nothing was flushed.
    try testing.expectError(error.NotCheckpointed, env.cp.reclaim(testing.io));
}

test "run: the segment limit refuses a checkpoint that needs a new segment, unchanged" {
    var env: Env = undefined;
    try env.init(512, 2, 1, .none);
    defer env.deinit();

    _ = try env.edit(1, 11);
    _ = try env.edit(2, 12);
    const before = env.log.position();
    try testing.expectError(error.SegmentLimit, env.cp.run(testing.io));
    try testing.expectEqual(checkpoint.Stage.idle, env.cp.stage);
    try testing.expectEqual(before, env.log.position());
    try testing.expect(!env.log.failed); // Not latched: the caller can still append.
    env.log.check_invariants();
}

fn run_reclaim_fails(env: *Env, want: anyerror) !void {
    assert(env.log.live_count == 3); // Segments 1 to 3; the checkpoint frame makes a fourth.
    assert(@intFromError(want) != 0);
    try testing.expectError(want, env.cp.run(testing.io));
    try testing.expectEqual(@as(u32, 4), env.log.live_count); // Nothing was deleted.
    // The checkpoint itself is complete; only the reclaim failed.
    try testing.expectEqual(checkpoint.Stage.header_synced, env.cp.stage);
    try testing.expectEqual(env.cp.redo_lsn, env.pm.wal_lsn);
    env.log.check_invariants();
}

test "reclaim: a held segment is WouldBlock, then a retry finishes the job" {
    var env: Env = undefined;
    try env.init(512, 8, 1, .none);
    defer env.deinit();

    for (1..4) |id| _ = try env.edit(@intCast(id), 50 + @as(u32, @intCast(id)));
    const held = try segment.Segment.open(testing.io, env.tmp.dir, 2, fx.seg_options(8, .none));
    try run_reclaim_fails(&env, error.WouldBlock);
    held.close(testing.io);
    try testing.expectEqual(@as(u32, 3), try env.cp.reclaim(testing.io));
    try testing.expectEqual(checkpoint.Stage.reclaimed, env.cp.stage);
    try env.expect_segments(4, 4);
}

test "reclaim: a damaged or missing older segment is a typed error and nothing is deleted early" {
    const bits = [_]struct { offset: u64, want: anyerror }{
        .{ .offset = 0, .want = error.Corrupted }, // Magic.
        .{ .offset = 16, .want = error.ChecksumMismatch }, // first_lsn.
    };
    for (bits) |case| {
        var env: Env = undefined;
        try env.init(512, 8, 1, .none);
        defer env.deinit();

        for (1..4) |id| _ = try env.edit(@intCast(id), 60 + @as(u32, @intCast(id)));
        const handle = try sfx.raw_open(env.tmp.dir, 2);
        defer handle.close(testing.io);

        try sfx.flip_bit(handle, case.offset, 0);
        try run_reclaim_fails(&env, case.want);
        try env.expect_segments(1, 4); // Segment 1 is whole and was not deleted either.
    }
    var env: Env = undefined;
    try env.init(512, 8, 1, .none);
    defer env.deinit();

    for (1..4) |id| _ = try env.edit(@intCast(id), 70 + @as(u32, @intCast(id)));
    var name = sfx.name_of(1);
    try env.tmp.dir.deleteFile(testing.io, &name); // Behind the writer's back.
    try run_reclaim_fails(&env, error.FileNotFound);
}
