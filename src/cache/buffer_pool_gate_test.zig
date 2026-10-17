//! Contract tests for the WAL-before-data gate of `BufferPool` (plan 004 item 8): off until the
//! first `set_durable_lsn`, then write-back (eviction and `flushAll`) skips and keeps dirty
//! every frame whose page lsn is above the bound, eviction scans past such frames, and all
//! victims gated is `PoolExhausted`. Every scripted test runs at all eight page sizes.

const std = @import("std");
const assert = std.debug.assert;
const testing = std.testing;
const Io = std.Io;
const header = @import("../page/header.zig");
const fx = @import("../page/manager_fixtures.zig");
const fault_io = @import("../testing/fault_io.zig");
const buffer_pool = @import("buffer_pool.zig");
const base = @import("buffer_pool_test.zig");

const BufferPool = buffer_pool.BufferPool;
const PageManager = @import("../page/manager.zig").PageManager;

/// Fetches `raw` for update; stores `lsn` in the page header, marking the frame dirty.
fn update(pool: *BufferPool, io: Io, raw: u32, lsn: u64) !void {
    assert(raw >= 1);
    assert(raw < fx.page_count_max);
    var guard = try pool.fetchForUpdate(io, fx.id_of(raw));
    defer guard.release();

    guard.set_lsn(lsn);
    try testing.expectEqual(lsn, header.peek(guard.bytes()).lsn);
}

/// Reads `raw` straight from the manager (checksum verified) and checks its lsn.
fn expect_disk_lsn(pm: *PageManager, raw: u32, lsn: u64) !void {
    assert(raw >= 1);
    assert(raw < fx.page_count_max);
    const buf = try testing.allocator.alloc(u8, pm.page_size);
    defer testing.allocator.free(buf);

    const got = try pm.read(testing.io, fx.id_of(raw), buf);
    try testing.expectEqual(lsn, got.lsn);
}

fn expect_counts(pool: *const BufferPool, dirty: u32, writebacks: u64, gated: u64) !void {
    assert(dirty <= pool.frames_max);
    assert(pool.frames.len == pool.frames_max);
    try testing.expectEqual(dirty, pool.dirty_count);
    try testing.expectEqual(writebacks, pool.stats().writebacks);
    try testing.expectEqual(gated, pool.stats().gated);
    pool.check_invariants();
}

test "gate: off by default, a dirty page with a huge lsn is evicted and flushed" {
    for (fx.sizes_all) |size| {
        var tmp = testing.tmpDir(.{});
        defer tmp.cleanup();

        var pm: PageManager = undefined;
        try base.make_pages(&pm, tmp.dir, size, 3);
        defer pm.close(testing.io);

        var pool: BufferPool = undefined;
        try BufferPool.init(&pool, testing.allocator, &pm, base.pool_options(&pm, 1));
        defer pool.deinit(testing.allocator);

        try update(&pool, testing.io, 1, 1 << 40);
        try base.fetch_release(&pool, 2); // Evicts page 1 and writes it back.
        try expect_counts(&pool, 0, 1, 0);
        try expect_disk_lsn(&pm, 1, 1 << 40);
        try update(&pool, testing.io, 2, 1 << 41);
        try pool.flushAll(testing.io);
        try expect_counts(&pool, 0, 2, 0);
        try expect_disk_lsn(&pm, 2, 1 << 41);
    }
}

test "gate: eviction skips the frame above the bound and takes the next victim" {
    for (fx.sizes_all) |size| {
        var tmp = testing.tmpDir(.{});
        defer tmp.cleanup();

        var pm: PageManager = undefined;
        try base.make_pages(&pm, tmp.dir, size, 3);
        defer pm.close(testing.io);

        var pool: BufferPool = undefined;
        try BufferPool.init(&pool, testing.allocator, &pm, base.pool_options(&pm, 2));
        defer pool.deinit(testing.allocator);

        pool.set_durable_lsn(50);
        try update(&pool, testing.io, 1, 900); // Frame 0: above the bound, the hand's first pick.
        try update(&pool, testing.io, 2, 20);
        try base.fetch_release(&pool, 3); // Must evict page 2, not page 1.
        try expect_counts(&pool, 1, 1, 0);
        try testing.expectEqual(@as(u64, 1), pool.stats().evictions);
        try testing.expect(pool.table.get(1) != null); // Page 1 still resident...
        try testing.expect(pool.table.get(2) == null); // ...page 2 is the one that left.
        try expect_disk_lsn(&pm, 1, 1); // Page 1 was not written.
        try expect_disk_lsn(&pm, 2, 20);
        try pool.flushAll(testing.io); // Still gated: nothing written, no error.
        try expect_counts(&pool, 1, 1, 1);
        pool.set_durable_lsn(900); // Equal to the page lsn is allowed through.
        try pool.flushAll(testing.io);
        try expect_counts(&pool, 0, 2, 1);
        try expect_disk_lsn(&pm, 1, 900);
    }
}

test "gate: every victim gated is PoolExhausted until the bound moves" {
    for (fx.sizes_all) |size| {
        var tmp = testing.tmpDir(.{});
        defer tmp.cleanup();

        var pm: PageManager = undefined;
        try base.make_pages(&pm, tmp.dir, size, 3);
        defer pm.close(testing.io);

        var pool: BufferPool = undefined;
        try BufferPool.init(&pool, testing.allocator, &pm, base.pool_options(&pm, 2));
        defer pool.deinit(testing.allocator);

        pool.set_durable_lsn(5);
        try update(&pool, testing.io, 1, 900);
        try update(&pool, testing.io, 2, 901);
        try testing.expectError(error.PoolExhausted, pool.fetch(testing.io, fx.id_of(3)));
        try expect_counts(&pool, 2, 0, 0);
        try testing.expectEqual(@as(u64, 0), pool.stats().evictions);
        try testing.expectEqual(@as(u32, 0), pool.pinned_count());
        pool.set_durable_lsn(900); // Frees page 1 only; page 2 (901) stays gated.
        try base.fetch_release(&pool, 3);
        try expect_counts(&pool, 1, 1, 0);
        try testing.expect(pool.table.get(2) != null);
        try expect_disk_lsn(&pm, 1, 900);
        try expect_disk_lsn(&pm, 2, 2);
        pool.set_durable_lsn(1000);
        try pool.flushAll(testing.io);
        try expect_counts(&pool, 0, 2, 0);
    }
}

test "gate: flushAll leaves gated frames dirty, pinned ones included, until the bound moves" {
    for (fx.sizes_all) |size| {
        var tmp = testing.tmpDir(.{});
        defer tmp.cleanup();

        var pm: PageManager = undefined;
        try base.make_pages(&pm, tmp.dir, size, 3);
        defer pm.close(testing.io);

        var pool: BufferPool = undefined;
        try BufferPool.init(&pool, testing.allocator, &pm, base.pool_options(&pm, 3));
        defer pool.deinit(testing.allocator);

        pool.set_durable_lsn(50);
        try update(&pool, testing.io, 1, 10);
        try update(&pool, testing.io, 3, 51); // One above the bound.
        var pinned = try pool.fetchForUpdate(testing.io, fx.id_of(2));
        errdefer if (!pinned.released) pinned.release(); // A failed expect must not trip deinit.

        pinned.set_lsn(900);
        try pool.flushAll(testing.io); // Writes page 1 only; no error for the gated two.
        try expect_counts(&pool, 2, 1, 2);
        try expect_disk_lsn(&pm, 1, 10);
        try expect_disk_lsn(&pm, 2, 2);
        try expect_disk_lsn(&pm, 3, 3);
        pool.set_durable_lsn(51);
        try pool.flushAll(testing.io); // Page 3 goes; the pinned page 2 stays gated.
        try expect_counts(&pool, 1, 2, 3);
        pool.set_durable_lsn(900);
        try pool.flushAll(testing.io);
        try expect_counts(&pool, 0, 3, 3);
        pinned.release();
        try expect_disk_lsn(&pm, 2, 900);
        try expect_disk_lsn(&pm, 3, 51);
    }
}

test "gate: set_durable_lsn with the same value is a no-op" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    var pm: PageManager = undefined;
    try base.make_pages(&pm, tmp.dir, 512, 2);
    defer pm.close(testing.io);

    var pool: BufferPool = undefined;
    try BufferPool.init(&pool, testing.allocator, &pm, base.pool_options(&pm, 2));
    defer pool.deinit(testing.allocator);

    pool.set_durable_lsn(50);
    pool.set_durable_lsn(50); // Same bound again: still on, nothing changes.
    try testing.expectEqual(@as(u64, 50), pool.durable_lsn);
    try testing.expect(pool.gate_on);
    try update(&pool, testing.io, 1, 51);
    pool.set_durable_lsn(50);
    try pool.flushAll(testing.io);
    try expect_counts(&pool, 1, 0, 1); // Page 1 is still gated.
    pool.set_durable_lsn(51);
    try pool.flushAll(testing.io);
    try expect_counts(&pool, 0, 1, 1);
}

test "gate: eviction alone skipping a gated frame leaves Stats.gated at zero" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    var pm: PageManager = undefined;
    try base.make_pages(&pm, tmp.dir, 512, 4);
    defer pm.close(testing.io);

    var pool: BufferPool = undefined;
    try BufferPool.init(&pool, testing.allocator, &pm, base.pool_options(&pm, 2));
    defer pool.deinit(testing.allocator);

    pool.set_durable_lsn(5);
    try update(&pool, testing.io, 1, 900); // Gated for the whole test.
    try base.fetch_release(&pool, 2);
    try base.fetch_release(&pool, 3); // Evicts clean page 2, scanning past page 1.
    try base.fetch_release(&pool, 4); // Evicts clean page 3, scanning past page 1 again.
    try testing.expectEqual(@as(u64, 2), pool.stats().evictions);
    try expect_counts(&pool, 1, 0, 0);
    pool.set_durable_lsn(900);
    try pool.flushAll(testing.io);
    try expect_counts(&pool, 0, 1, 0);
}

test "gate: a failed write in flushAll still counts the frames skipped before it" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    var pm: PageManager = undefined;
    try base.make_pages(&pm, tmp.dir, 512, 3);
    defer pm.close(testing.io);

    var pool: BufferPool = undefined;
    try BufferPool.init(&pool, testing.allocator, &pm, base.pool_options(&pm, 3));
    defer pool.deinit(testing.allocator);

    pool.set_durable_lsn(50);
    try update(&pool, testing.io, 1, 900); // Frame 0: gated, skipped first.
    try update(&pool, testing.io, 2, 10); // Frame 1: eligible, its write fails.
    var faulty: fault_io.FaultIo = undefined;
    faulty.init(testing.io, .{ .write = .canceled, .read = .none, .after_calls = 0 });
    try testing.expectError(error.Canceled, pool.flushAll(faulty.io()));
    try expect_counts(&pool, 2, 0, 1);
    pool.set_durable_lsn(900);
    try pool.flushAll(testing.io);
    try expect_counts(&pool, 0, 2, 1);
}
