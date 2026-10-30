//! Contract tests for the `BufferPool` op tracker (plan 005): ids are recorded in first-dirtied
//! order and once each, a full id slice sets `track_overflow` until `track_reset`, and a
//! tracked page is never a victim until `track_end`.

const std = @import("std");
const assert = std.debug.assert;
const testing = std.testing;
const Io = std.Io;
const header = @import("../page/header.zig");
const fx = @import("../page/manager_fixtures.zig");
const buffer_pool = @import("buffer_pool.zig");
const base = @import("buffer_pool_test.zig");

const BufferPool = buffer_pool.BufferPool;
const PageManager = @import("../page/manager.zig").PageManager;

/// Fetches `raw` for update and dirties it (a changed payload byte).
fn dirty(pool: *BufferPool, io: Io, raw: u32) !void {
    assert(raw >= 1);
    assert(raw < fx.page_count_max);
    var guard = try pool.fetchForUpdate(io, fx.id_of(raw));
    defer guard.release();

    guard.bytes_mut()[header.header_size] +%= 1;
    guard.set_lsn(1000 + raw);
}

test "track: ids are recorded once each, in first-dirtied order" {
    for (fx.sizes_all) |size| {
        var tmp = testing.tmpDir(.{});
        defer tmp.cleanup();

        var pm: PageManager = undefined;
        try base.make_pages(&pm, tmp.dir, size, 5);
        defer pm.close(testing.io);

        var pool: BufferPool = undefined;
        try BufferPool.init(&pool, testing.allocator, &pm, base.pool_options(&pm, 5));
        defer pool.deinit(testing.allocator);
        defer pool.discardAll(); // Runs first: `deinit` wants no dirty frame.

        var ids: [5]u32 = undefined;
        try dirty(&pool, testing.io, 4); // Before tracking: not recorded.
        pool.track_begin(&ids);
        try testing.expectEqual(@as(usize, 0), pool.track_ids().len);
        for ([_]u32{ 3, 1, 3, 5, 1, 4 }) |raw| try dirty(&pool, testing.io, raw);
        try testing.expectEqualSlices(u32, &.{ 3, 1, 5, 4 }, pool.track_ids());
        try testing.expect(!pool.track_overflow);
        pool.track_end();
        try testing.expect(!pool.track_on);
        pool.check_invariants();
    }
}

test "track: overflow is set when the ids slice is full and cleared by track_reset" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    var pm: PageManager = undefined;
    try base.make_pages(&pm, tmp.dir, 512, 4);
    defer pm.close(testing.io);

    var pool: BufferPool = undefined;
    try BufferPool.init(&pool, testing.allocator, &pm, base.pool_options(&pm, 4));
    defer pool.deinit(testing.allocator);
    defer pool.discardAll(); // Runs first: `deinit` wants no dirty frame.

    var ids: [2]u32 = undefined;
    pool.track_begin(&ids);
    try dirty(&pool, testing.io, 1);
    try dirty(&pool, testing.io, 2);
    try testing.expect(!pool.track_overflow); // Full, but nothing was lost yet.
    try dirty(&pool, testing.io, 2);
    try testing.expect(!pool.track_overflow); // A tracked page again is not a new id.
    try dirty(&pool, testing.io, 3);
    try testing.expect(pool.track_overflow);
    try testing.expectEqualSlices(u32, &.{ 1, 2 }, pool.track_ids());
    pool.track_reset();
    try testing.expect(!pool.track_overflow);
    try testing.expectEqual(@as(usize, 0), pool.track_ids().len);
    try dirty(&pool, testing.io, 4); // Recording starts over after the reset.
    try testing.expectEqualSlices(u32, &.{4}, pool.track_ids());
    pool.track_end();
    try testing.expect(!pool.track_overflow);
}

test "track: a tracked page is skipped by eviction and evictable after track_end" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    var pm: PageManager = undefined;
    try base.make_pages(&pm, tmp.dir, 512, 3);
    defer pm.close(testing.io);

    var pool: BufferPool = undefined;
    try BufferPool.init(&pool, testing.allocator, &pm, base.pool_options(&pm, 1));
    defer pool.deinit(testing.allocator);

    var ids: [1]u32 = undefined;
    pool.track_begin(&ids);
    try dirty(&pool, testing.io, 1);
    // The only frame holds a tracked, unpinned page: it is no victim, nothing else is.
    try testing.expectError(error.PoolExhausted, pool.fetch(testing.io, fx.id_of(2)));
    try testing.expectEqual(@as(u64, 0), pool.stats().writebacks);
    try testing.expectEqual(@as(u32, 1), pool.dirty_count);
    pool.track_end();
    var other = try pool.fetch(testing.io, fx.id_of(2)); // Now page 1 is written back and evicted.
    other.release();
    try testing.expectEqual(@as(u64, 1), pool.stats().writebacks);
    try testing.expectEqual(@as(u32, 0), pool.dirty_count);
    pool.check_invariants();
}
