//! Contract tests for `BufferPool` dirty tracking and write-back (plan 003 item 8): writable
//! guards, write-back on eviction, `flushAll`, `discardAll`, failed write-back that keeps the
//! frame resident and dirty (`FaultIo`), the no-allocation contract, and a seeded model of
//! writes, flushes and evictions against a trivial reference map. Every scripted test runs at
//! 512, 4096 and 65536 byte pages.

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

const value_offset: usize = header.header_size;

/// Fetches `raw` for update, stores `value` in the first payload word and as the page lsn.
fn update(pool: *BufferPool, io: Io, raw: u32, value: u64) !void {
    assert(raw >= 1);
    assert(value >= 1);
    assert(raw < fx.page_count_max);
    var guard = try pool.fetchForUpdate(io, fx.id_of(raw));
    defer guard.release();

    std.mem.writeInt(u64, guard.bytes_mut()[value_offset..][0..8], value, .little);
    guard.set_lsn(value);
}

fn expect_value(bytes: []const u8, value: u64) !void {
    assert(header.page_size_valid(@intCast(bytes.len)));
    assert(value >= 1);
    try testing.expect(bytes.len >= value_offset + 8);
    try testing.expectEqual(value, std.mem.readInt(u64, bytes[value_offset..][0..8], .little));
    try testing.expectEqual(value, header.peek(bytes).lsn);
}

/// Fetches `raw` read-only and checks it carries `value`.
fn expect_cached(pool: *BufferPool, raw: u32, value: u64) !void {
    assert(raw >= 1);
    assert(raw < fx.page_count_max);
    var guard = try pool.fetch(testing.io, fx.id_of(raw));
    defer guard.release();

    try expect_value(guard.bytes(), value);
}

/// Reads `raw` straight from the manager (checksum verified) and checks it carries `value`.
fn expect_disk(pm: *PageManager, raw: u32, value: u64) !void {
    assert(raw >= 1);
    assert(raw < fx.page_count_max);
    const buf = try testing.allocator.alloc(u8, pm.page_size);
    defer testing.allocator.free(buf);

    const got = try pm.read(testing.io, fx.id_of(raw), buf);
    try testing.expectEqual(value, got.lsn);
    try expect_value(buf, value);
}

/// Reads `raw` from the manager and checks it is still the page `make_pages` wrote (lsn == id).
fn expect_disk_old(pm: *PageManager, raw: u32) !void {
    assert(raw >= 1);
    assert(raw < fx.page_count_max);
    const buf = try testing.allocator.alloc(u8, pm.page_size);
    defer testing.allocator.free(buf);

    const got = try pm.read(testing.io, fx.id_of(raw), buf);
    try testing.expectEqual(@as(u64, raw), got.lsn);
}

fn expect_counts(pool: *const BufferPool, dirty: u32, writebacks: u64) !void {
    assert(dirty <= pool.frames_max);
    assert(pool.frames.len == pool.frames_max);
    try testing.expectEqual(dirty, pool.dirty_count);
    try testing.expectEqual(writebacks, pool.stats().writebacks);
    pool.check_invariants();
}

test "header: peek reads type and lsn without verifying, poke_lsn changes only the lsn" {
    var page: [512]u8 = @splat(7);
    header.encode(&page, fx.id_of(3), .{ .page_type = fx.consumer_type, .lsn = 41 });
    const sealed = header.peek(&page);
    try testing.expectEqual(fx.consumer_type, sealed.page_type);
    try testing.expectEqual(@as(u64, 41), sealed.lsn);
    header.poke_lsn(&page, 42);
    try testing.expectEqual(@as(u64, 42), header.peek(&page).lsn);
    try testing.expectError(error.ChecksumMismatch, header.decode(&page, fx.id_of(3)));
}

test "write-back: a dirty page evicted then refetched returns the new bytes" {
    for (fx.sizes_three) |size| {
        var tmp = testing.tmpDir(.{});
        defer tmp.cleanup();

        var pm: PageManager = undefined;
        try base.make_pages(&pm, tmp.dir, size, 3);
        defer pm.close(testing.io);

        var pool: BufferPool = undefined;
        try BufferPool.init(&pool, testing.allocator, &pm, base.pool_options(&pm, 1));
        defer pool.deinit(testing.allocator);

        try update(&pool, testing.io, 1, 900);
        try expect_counts(&pool, 1, 0);
        try expect_disk_old(&pm, 1); // Not written yet: the old page is still on disk.
        var other = try base.fetch_ok(&pool, testing.io, 2); // Evicts page 1: write-back first.
        other.release();
        try expect_counts(&pool, 0, 1);
        try expect_disk(&pm, 1, 900);
        try expect_cached(&pool, 1, 900); // A miss that reads the written-back bytes.
        try testing.expectEqual(@as(u64, 2), pool.stats().evictions);
    }
}

test "write-back: clean frames and untouched updatable guards write nothing" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    var pm: PageManager = undefined;
    try base.make_pages(&pm, tmp.dir, 512, 3);
    defer pm.close(testing.io);

    var pool: BufferPool = undefined;
    try BufferPool.init(&pool, testing.allocator, &pm, base.pool_options(&pm, 1));
    defer pool.deinit(testing.allocator);

    var guard = try pool.fetchForUpdate(testing.io, fx.id_of(1));
    guard.release(); // Never `bytes_mut`: the frame stays clean.
    try expect_counts(&pool, 0, 0);
    var other = try base.fetch_ok(&pool, testing.io, 2);
    other.release();
    try pool.flushAll(testing.io);
    try expect_counts(&pool, 0, 0);
    try testing.expectEqual(@as(u64, 1), pool.stats().evictions);
}

test "guard: bytes_mut and markDirty dirty a shared frame once; readers see the change" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    var pm: PageManager = undefined;
    try base.make_pages(&pm, tmp.dir, 512, 2);
    defer pm.close(testing.io);

    var pool: BufferPool = undefined;
    try BufferPool.init(&pool, testing.allocator, &pm, base.pool_options(&pm, 2));
    defer pool.deinit(testing.allocator);

    var reader = try base.fetch_ok(&pool, testing.io, 1);
    var writer = try pool.fetchForUpdate(testing.io, fx.id_of(1));
    try testing.expectEqual(@as(u32, 1), pool.pinned_count());
    try testing.expectEqual(reader.bytes().ptr, writer.bytes_mut().ptr);
    try testing.expectEqual(@as(u32, 1), pool.dirty_count);
    writer.markDirty(); // Already dirty: idempotent, counted once.
    writer.set_lsn(77);
    try expect_counts(&pool, 1, 0);
    try testing.expectEqual(@as(u64, 77), header.peek(reader.bytes()).lsn);
    reader.release();
    writer.release();
    try pool.flushAll(testing.io);
    try expect_counts(&pool, 0, 1);
    try testing.expectEqual(@as(u64, 77), header.peek(pool.slab[0..512]).lsn);
}

test "flushAll: persists every dirty frame, pinned ones included, and survives reopen" {
    for (fx.sizes_three) |size| {
        var tmp = testing.tmpDir(.{});
        defer tmp.cleanup();

        var pm: PageManager = undefined;
        try base.make_pages(&pm, tmp.dir, size, 4);
        var pool: BufferPool = undefined;
        try BufferPool.init(&pool, testing.allocator, &pm, base.pool_options(&pm, 4));
        for ([_]u32{ 1, 2, 3 }) |raw| try update(&pool, testing.io, raw, 500 + raw);
        var pinned = try pool.fetchForUpdate(testing.io, fx.id_of(4));
        std.mem.writeInt(u64, pinned.bytes_mut()[value_offset..][0..8], 504, .little);
        pinned.set_lsn(504);
        try expect_counts(&pool, 4, 0);
        try pool.flushAll(testing.io); // Pinned page 4 is flushed too.
        try expect_counts(&pool, 0, 4);
        try pool.flushAll(testing.io); // Nothing dirty: no further writes.
        try expect_counts(&pool, 0, 4);
        pinned.release();
        pool.deinit(testing.allocator);
        try pm.sync(testing.io);
        pm.close(testing.io);

        try PageManager.open(&pm, testing.io, tmp.dir, "pool.db", fx.opts(size));
        defer pm.close(testing.io);

        for ([_]u32{ 1, 2, 3, 4 }) |raw| try expect_disk(&pm, raw, 500 + raw);
    }
}

test "write-back failure: eviction error keeps the victim resident and dirty, retry works" {
    const faults = [_]struct { fault: fault_io.Fault, expected: anyerror }{
        .{ .fault = .canceled, .expected = error.Canceled },
        .{ .fault = .zero, .expected = error.NoSpaceLeft },
    };
    for (faults) |case| {
        for (fx.sizes_three) |size| {
            var tmp = testing.tmpDir(.{});
            defer tmp.cleanup();

            var pm: PageManager = undefined;
            try base.make_pages(&pm, tmp.dir, size, 3);
            defer pm.close(testing.io);

            var pool: BufferPool = undefined;
            try BufferPool.init(&pool, testing.allocator, &pm, base.pool_options(&pm, 1));
            defer pool.deinit(testing.allocator);

            try update(&pool, testing.io, 1, 900);
            var faulty: fault_io.FaultIo = undefined;
            faulty.init(testing.io, .{ .write = case.fault, .read = .none, .after_calls = 0 });
            const plan_io = faulty.io();
            try testing.expectError(case.expected, pool.fetch(plan_io, fx.id_of(2)));
            try expect_counts(&pool, 1, 0);
            try testing.expectEqual(@as(u32, 0), pool.empty_count);
            try testing.expectEqual(@as(u32, 0), pool.pinned_count());
            try testing.expectEqual(@as(u64, 0), pool.stats().evictions);
            try testing.expectEqual(@as(u64, 2), pool.stats().misses); // A failed miss counts.
            try testing.expect(faulty.write_calls >= 1);
            try expect_disk_old(&pm, 1);
            try expect_cached(&pool, 1, 900); // Still resident: a hit, bytes not lost.
            try testing.expectEqual(@as(u64, 1), pool.stats().hits);
            var other = try base.fetch_ok(&pool, testing.io, 2); // Fault cleared: writes back.
            other.release();
            try expect_counts(&pool, 0, 1);
            try expect_disk(&pm, 1, 900);
        }
    }
}

test "flushAll failure: frames before the fault are clean, the rest stay dirty" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    var pm: PageManager = undefined;
    try base.make_pages(&pm, tmp.dir, 512, 3);
    defer pm.close(testing.io);

    var pool: BufferPool = undefined;
    try BufferPool.init(&pool, testing.allocator, &pm, base.pool_options(&pm, 3));
    defer pool.deinit(testing.allocator);

    for ([_]u32{ 1, 2, 3 }) |raw| try update(&pool, testing.io, raw, 600 + raw);
    var faulty: fault_io.FaultIo = undefined;
    faulty.init(testing.io, .{ .write = .canceled, .read = .none, .after_calls = 1 });
    try testing.expectError(error.Canceled, pool.flushAll(faulty.io()));
    try expect_counts(&pool, 2, 1);
    try expect_disk(&pm, 1, 601); // Frames flush in index order: page 1 went first.
    try expect_disk_old(&pm, 2);
    try pool.flushAll(testing.io);
    try expect_counts(&pool, 0, 3);
    for ([_]u32{ 1, 2, 3 }) |raw| try expect_disk(&pm, raw, 600 + raw);
}

test "write-back: an illegal type byte is InvalidHeader and the frame stays dirty" {
    for (fx.sizes_three) |size| {
        var tmp = testing.tmpDir(.{});
        defer tmp.cleanup();

        var pm: PageManager = undefined;
        try base.make_pages(&pm, tmp.dir, size, 3);
        defer pm.close(testing.io);

        var pool: BufferPool = undefined;
        try BufferPool.init(&pool, testing.allocator, &pm, base.pool_options(&pm, 1));
        defer pool.deinit(testing.allocator);

        try update(&pool, testing.io, 1, 700);
        {
            var guard = try pool.fetchForUpdate(testing.io, fx.id_of(1));
            defer guard.release();

            guard.bytes_mut()[4] = @intFromEnum(header.Type.file_header); // Legal only at id 0.
        }
        try testing.expectError(error.InvalidHeader, pool.flushAll(testing.io));
        try testing.expectError(error.InvalidHeader, pool.fetch(testing.io, fx.id_of(2)));
        try expect_counts(&pool, 1, 0);
        try expect_disk_old(&pm, 1);
        {
            var guard = try pool.fetchForUpdate(testing.io, fx.id_of(1));
            defer guard.release();

            guard.bytes_mut()[4] = @intFromEnum(fx.consumer_type);
        }
        try pool.flushAll(testing.io);
        try expect_counts(&pool, 0, 1);
        try expect_disk(&pm, 1, 700);
    }
}

test "discardAll: drops dirty data without writing, the next fetch sees the old bytes" {
    for (fx.sizes_three) |size| {
        var tmp = testing.tmpDir(.{});
        defer tmp.cleanup();

        var pm: PageManager = undefined;
        try base.make_pages(&pm, tmp.dir, size, 3);
        defer pm.close(testing.io);

        var pool: BufferPool = undefined;
        try BufferPool.init(&pool, testing.allocator, &pm, base.pool_options(&pm, 3));
        defer pool.deinit(testing.allocator);

        try update(&pool, testing.io, 1, 900);
        try update(&pool, testing.io, 2, 901);
        try base.fetch_release(&pool, 3);
        try expect_counts(&pool, 2, 0);
        pool.discardAll();
        try expect_counts(&pool, 0, 0);
        try testing.expectEqual(pool.frames_max, pool.empty_count);
        try testing.expectEqual(@as(u32, 0), pool.table.count());
        var again = try base.fetch_ok(&pool, testing.io, 1); // Old pattern and old lsn 1.
        again.release();
        try expect_disk_old(&pm, 2);
        pool.check_invariants();
    }
}

test "no allocation: dirtying, eviction write-back, flushAll and discardAll allocate nothing" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    var pm: PageManager = undefined;
    try base.make_pages(&pm, tmp.dir, 4096, 6);
    defer pm.close(testing.io);

    var failing = testing.FailingAllocator.init(testing.allocator, .{});
    var pool: BufferPool = undefined;
    try BufferPool.init(&pool, failing.allocator(), &pm, base.pool_options(&pm, 2));
    defer pool.deinit(failing.allocator());

    failing.fail_index = failing.alloc_index; // Armed: any further allocation fails.
    const allocs = failing.alloc_index;
    for (1..7) |raw| try update(&pool, testing.io, @intCast(raw), 700 + raw);
    try pool.flushAll(testing.io);
    try update(&pool, testing.io, 1, 800);
    pool.discardAll();
    try testing.expectEqual(allocs, failing.alloc_index);
    try expect_counts(&pool, 0, 6);
}

const model_pages: u32 = 12;

fn expect_all_on_disk(pm: *PageManager, model: *const [model_pages + 1]u64) !void {
    assert(model_pages >= 1);
    assert(pm.page_count > model_pages);
    for (1..model_pages + 1) |page| try expect_disk(pm, @intCast(page), model[page]);
}

test "model: seeded writes, reads, flushes and evictions agree with a reference map" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    var pm: PageManager = undefined;
    try base.make_pages(&pm, tmp.dir, 512, model_pages);
    defer pm.close(testing.io);

    var pool: BufferPool = undefined;
    try BufferPool.init(&pool, testing.allocator, &pm, base.pool_options(&pm, 4));
    defer pool.deinit(testing.allocator);

    var model: [model_pages + 1]u64 = @splat(0);
    var next_value: u64 = 1000;
    for (1..model_pages + 1) |page| { // Give every page a value word the model knows.
        next_value += 1;
        try update(&pool, testing.io, @intCast(page), next_value);
        model[page] = next_value;
    }
    var prng = std.Random.DefaultPrng.init(0xd1a7_11);
    const random = prng.random();
    var writebacks_seen: u64 = 0;
    for (0..3000) |_| {
        const raw = random.intRangeAtMost(u32, 1, model_pages);
        switch (random.uintLessThan(u8, 100)) {
            0...44 => {
                next_value += 1;
                try update(&pool, testing.io, raw, next_value);
                model[raw] = next_value;
            },
            45...84 => try expect_cached(&pool, raw, model[raw]),
            else => {
                try pool.flushAll(testing.io);
                try testing.expectEqual(@as(u32, 0), pool.dirty_count);
                try expect_all_on_disk(&pm, &model);
            },
        }
        pool.check_invariants();
        try testing.expect(pool.stats().writebacks >= writebacks_seen);
        writebacks_seen = pool.stats().writebacks;
    }
    try pool.flushAll(testing.io);
    try expect_all_on_disk(&pm, &model);
    try testing.expect(pool.stats().evictions > 0);
    try testing.expect(pool.stats().writebacks > 0);
}
