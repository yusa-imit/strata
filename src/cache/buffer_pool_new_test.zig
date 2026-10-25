//! Contract tests for `BufferPool.fetchNew` (plan 005 item 4, ADR-0004 section 13): a page that was
//! just allocated is pinned zero-filled and dirty without reading it, whether its id was grown
//! (the file reads `Unwritten`) or reused (the file holds a stale trunk image, or the pool holds a
//! stale frame); pool exhaustion and an unwritable victim are typed errors; nothing allocates.

const std = @import("std");
const assert = std.debug.assert;
const testing = std.testing;
const header = @import("../page/header.zig");
const fx = @import("../page/manager_fixtures.zig");
const pool_fx = @import("buffer_pool_test.zig");
const buffer_pool = @import("buffer_pool.zig");

const BufferPool = buffer_pool.BufferPool;
const PageGuard = buffer_pool.PageGuard;
const PageManager = @import("../page/manager.zig").PageManager;

/// Gives the pinned new page a legal type and `lsn` so it can be written back.
fn stamp(guard: *PageGuard, lsn: u64) void {
    assert(guard.updatable);
    const page = guard.bytes_mut();
    header.encode(page, guard.id(), .{ .page_type = fx.consumer_type, .lsn = lsn });
    assert(header.peek(page).lsn == lsn);
}

fn expect_zeroed(guard: *const PageGuard) !void {
    assert(!guard.released);
    assert(guard.pool.frames[guard.frame_index].pin_count > 0);
    try testing.expect(guard.updatable);
    try testing.expect(std.mem.allEqual(u8, guard.bytes(), 0));
    try testing.expectEqual(@as(usize, guard.pool.page_size), guard.bytes().len);
}

/// After `flushAll` and `discardAll` the page is read back from disk and decodes at `lsn`.
fn expect_durable(pool: *BufferPool, raw: u32, lsn: u64) !void {
    assert(raw >= 1);
    assert(pool.pinned_count() == 0);
    try pool.flushAll(testing.io);
    pool.discardAll();
    var guard = try pool.fetch(testing.io, fx.id_of(raw));
    defer guard.release();

    const h = try header.decode(guard.bytes(), fx.id_of(raw));
    try testing.expectEqual(lsn, h.lsn);
    try testing.expectEqual(fx.consumer_type, h.page_type);
}

test "fetchNew: a grown id reads Unwritten but is pinned zeroed and dirty, at all page sizes" {
    for (fx.sizes_all) |size| {
        var tmp = testing.tmpDir(.{});
        defer tmp.cleanup();

        var pm: PageManager = undefined;
        try PageManager.create(&pm, testing.io, tmp.dir, "new.db", fx.opts(size));
        defer pm.close(testing.io);

        var pool: BufferPool = undefined;
        try BufferPool.init(&pool, testing.allocator, &pm, pool_fx.pool_options(&pm, 2));
        defer pool.deinit(testing.allocator);

        const id = try pm.allocate(testing.io);
        try testing.expectError(error.Unwritten, pool.fetch(testing.io, id));
        var guard = try pool.fetchNew(testing.io, id);
        try expect_zeroed(&guard);
        try testing.expectEqual(id, guard.id());
        try testing.expectEqual(@as(u32, 1), pool.pinned_count());
        try testing.expectEqual(@as(u32, 1), pool.dirty_count);
        stamp(&guard, 7);
        guard.release();
        try expect_durable(&pool, @intFromEnum(id), 7);
        pool.check_invariants();
    }
}

test "fetchNew: a reused id with a stale trunk on disk is pinned zeroed and dirty" {
    for (fx.sizes_all) |size| {
        var tmp = testing.tmpDir(.{});
        defer tmp.cleanup();

        var pm: PageManager = undefined;
        try pool_fx.make_pages(&pm, tmp.dir, size, 3);
        defer pm.close(testing.io);

        var pool: BufferPool = undefined;
        try BufferPool.init(&pool, testing.allocator, &pm, pool_fx.pool_options(&pm, 2));
        defer pool.deinit(testing.allocator);

        try pm.free(testing.io, fx.id_of(2));
        const id = try pm.allocate(testing.io);
        try testing.expectEqual(fx.id_of(2), id);
        var guard = try pool.fetchNew(testing.io, id);
        try expect_zeroed(&guard);
        try testing.expectEqual(@as(u32, 1), pool.dirty_count);
        stamp(&guard, 9);
        guard.release();
        try expect_durable(&pool, 2, 9);
    }
}

test "fetchNew: a reused id with a resident stale frame is zeroed in place" {
    for (fx.sizes_all) |size| {
        var tmp = testing.tmpDir(.{});
        defer tmp.cleanup();

        var pm: PageManager = undefined;
        try pool_fx.make_pages(&pm, tmp.dir, size, 3);
        defer pm.close(testing.io);

        var pool: BufferPool = undefined;
        try BufferPool.init(&pool, testing.allocator, &pm, pool_fx.pool_options(&pm, 3));
        defer pool.deinit(testing.allocator);

        try pool_fx.fetch_release(&pool, 2); // Resident, pattern bytes.
        try pm.free(testing.io, fx.id_of(2));
        const id = try pm.allocate(testing.io);
        try testing.expectEqual(fx.id_of(2), id);
        const before = pool.stats();
        var guard = try pool.fetchNew(testing.io, id);
        try expect_zeroed(&guard);
        try testing.expectEqual(before.hits + 1, pool.stats().hits);
        try testing.expectEqual(@as(u32, 1), pool.pinned_count());
        try testing.expectEqual(@as(u32, 1), pool.dirty_count);
        stamp(&guard, 3);
        guard.release();
        try expect_durable(&pool, 2, 3);
    }
}

test "fetchNew: an all-pinned pool is PoolExhausted and nothing changes" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    var pm: PageManager = undefined;
    try pool_fx.make_pages(&pm, tmp.dir, 512, 3);
    defer pm.close(testing.io);

    var pool: BufferPool = undefined;
    try BufferPool.init(&pool, testing.allocator, &pm, pool_fx.pool_options(&pm, 1));
    defer pool.deinit(testing.allocator);

    var held = try pool_fx.fetch_ok(&pool, testing.io, 1);
    try testing.expectError(error.PoolExhausted, pool.fetchNew(testing.io, fx.id_of(2)));
    try testing.expectEqual(@as(u32, 0), pool.dirty_count);
    held.release();
    var guard = try pool.fetchNew(testing.io, fx.id_of(2)); // The pin is gone: it now works.
    guard.release();
    pool.discardAll();
    pool.check_invariants();
}

test "fetchNew: a victim left without a legal type is InvalidHeader and stays dirty" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    var pm: PageManager = undefined;
    try pool_fx.make_pages(&pm, tmp.dir, 512, 3);
    defer pm.close(testing.io);

    var pool: BufferPool = undefined;
    try BufferPool.init(&pool, testing.allocator, &pm, pool_fx.pool_options(&pm, 1));
    defer pool.deinit(testing.allocator);

    var first = try pool.fetchNew(testing.io, fx.id_of(1)); // Zeroed: type byte 0 is illegal.
    first.release();
    try testing.expectError(error.InvalidHeader, pool.fetchNew(testing.io, fx.id_of(2)));
    try testing.expectEqual(@as(u32, 1), pool.dirty_count);
    pool.check_invariants();
    pool.discardAll();
}

test "fetchNew: allocates nothing after init" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    var pm: PageManager = undefined;
    try pool_fx.make_pages(&pm, tmp.dir, 512, 6);
    defer pm.close(testing.io);

    var failing = testing.FailingAllocator.init(testing.allocator, .{});
    var pool: BufferPool = undefined;
    try BufferPool.init(&pool, failing.allocator(), &pm, pool_fx.pool_options(&pm, 2));
    defer pool.deinit(failing.allocator());

    failing.fail_index = failing.alloc_index; // Armed: any further allocation fails.
    const allocs = failing.alloc_index;
    for (1..7) |raw| {
        var guard = try pool.fetchNew(testing.io, fx.id_of(@intCast(raw)));
        stamp(&guard, raw);
        guard.release();
    }
    try testing.expectEqual(allocs, failing.alloc_index);
    try testing.expectEqual(@as(u64, 4), pool.stats().evictions);
    try pool.flushAll(testing.io);
    pool.check_invariants();
}
