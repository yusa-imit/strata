//! Contract tests for `BufferPool` fetch and pin (plan 003 item 7): scripted hit, miss and
//! eviction counts, the pin rules of the CLOCK hand, typed load errors that leave the pool
//! consistent, the no-allocation-after-init contract, hits that need no I/O, and a seeded model
//! that checks pin accounting and `PoolExhausted` against a trivial reference.

const std = @import("std");
const assert = std.debug.assert;
const testing = std.testing;
const Io = std.Io;
const header = @import("../page/header.zig");
const fx = @import("../page/manager_fixtures.zig");
const pattern_fx = @import("../file/file_fixtures.zig");
const fault_io = @import("../testing/fault_io.zig");
const buffer_pool = @import("buffer_pool.zig");

const BufferPool = buffer_pool.BufferPool;
const PageGuard = buffer_pool.PageGuard;
const PageManager = @import("../page/manager.zig").PageManager;

/// Creates `name` with pages `1..=count`, page `n` filled with `pattern(n)` and lsn `n`.
fn make_pages(pm: *PageManager, dir: Io.Dir, size: u32, count: u32) !void {
    assert(header.page_size_valid(size));
    assert(count >= 1 and count < fx.page_count_max);
    try PageManager.create(pm, testing.io, dir, "pool.db", fx.opts(size));
    const buf = try testing.allocator.alloc(u8, size);
    defer testing.allocator.free(buf);

    for (1..count + 1) |n| {
        const id = try pm.allocate(testing.io);
        try testing.expectEqual(@as(u32, @intCast(n)), @intFromEnum(id));
        try fx.write_pattern(pm, @intCast(n), buf, @intCast(n), n);
    }
}

fn pool_options(pm: *const PageManager, frames_max: u32) buffer_pool.Options {
    assert(frames_max >= 1);
    assert(header.page_size_valid(pm.page_size));
    return .{ .frames_max = frames_max, .page_size = pm.page_size };
}

/// Fetches `raw`, checks its bytes are the page written by `make_pages`, returns the guard.
fn fetch_ok(pool: *BufferPool, io: Io, raw: u32) !PageGuard {
    assert(raw >= 1);
    assert(raw < fx.page_count_max);
    var guard = try pool.fetch(io, fx.id_of(raw));
    errdefer guard.release();

    const bytes = guard.bytes();
    try testing.expectEqual(pool.page_size, @as(u32, @intCast(bytes.len)));
    try testing.expectEqual(fx.id_of(raw), guard.id());
    const h = try header.decode(bytes, fx.id_of(raw));
    try testing.expectEqual(@as(u64, raw), h.lsn);
    const want = try testing.allocator.alloc(u8, bytes.len);
    defer testing.allocator.free(want);

    pattern_fx.pattern(want[header.header_size..], raw);
    try testing.expectEqualSlices(u8, want[header.header_size..], bytes[header.header_size..]);
    return guard;
}

fn fetch_release(pool: *BufferPool, raw: u32) !void {
    assert(raw >= 1);
    assert(pool.pinned_count() <= pool.frames_max);
    assert(raw < fx.page_count_max);
    var guard = try fetch_ok(pool, testing.io, raw);
    guard.release();
}

fn expect_stats(pool: *const BufferPool, hits: u64, misses: u64, evictions: u64) !void {
    assert(evictions <= misses);
    assert(pool.frames_max >= 1);
    const got = pool.stats();
    try testing.expectEqual(hits, got.hits);
    try testing.expectEqual(misses, got.misses);
    try testing.expectEqual(evictions, got.evictions);
}

test "fetch: scripted hits, misses and CLOCK evictions at three page sizes" {
    for (fx.sizes_three) |size| {
        var tmp = testing.tmpDir(.{});
        defer tmp.cleanup();

        var pm: PageManager = undefined;
        try make_pages(&pm, tmp.dir, size, 6);
        defer pm.close(testing.io);

        var pool: BufferPool = undefined;
        try BufferPool.init(&pool, testing.allocator, &pm, pool_options(&pm, 3));
        defer pool.deinit(testing.allocator);

        for ([_]u32{ 1, 2, 3 }) |raw| try fetch_release(&pool, raw);
        try expect_stats(&pool, 0, 3, 0);
        try fetch_release(&pool, 1); // Hit: page 1 is resident.
        try expect_stats(&pool, 1, 3, 0);
        // All three reference bits are set, the first sweep clears them, so the hand takes
        // frame 0 (page 1) even though it was just hit: CLOCK degenerates to FIFO here.
        try fetch_release(&pool, 4);
        try expect_stats(&pool, 1, 4, 1);
        try fetch_release(&pool, 2); // Still resident: hit, and its bit is set again.
        try expect_stats(&pool, 2, 4, 1);
        try fetch_release(&pool, 1); // Gone: miss; the hand skips page 2 and takes page 3.
        try expect_stats(&pool, 2, 5, 2);
        try fetch_release(&pool, 3); // Page 3 was the victim just now: miss again.
        try expect_stats(&pool, 2, 6, 3);
        pool.check_invariants();
    }
}

test "fetch: a page pinned twice stays pinned until both guards are released" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    var pm: PageManager = undefined;
    try make_pages(&pm, tmp.dir, 512, 4);
    defer pm.close(testing.io);

    var pool: BufferPool = undefined;
    try BufferPool.init(&pool, testing.allocator, &pm, pool_options(&pm, 1));
    defer pool.deinit(testing.allocator);

    var first = try fetch_ok(&pool, testing.io, 1);
    var second = try fetch_ok(&pool, testing.io, 1);
    try testing.expectEqual(@as(u32, 1), pool.pinned_count());
    try testing.expectEqual(first.bytes().ptr, second.bytes().ptr);
    try testing.expectError(error.PoolExhausted, pool.fetch(testing.io, fx.id_of(2)));
    first.release();
    try testing.expectError(error.PoolExhausted, pool.fetch(testing.io, fx.id_of(2)));
    second.release();
    try testing.expectEqual(@as(u32, 0), pool.pinned_count());
    try fetch_release(&pool, 2); // Evicts page 1 now that nothing pins it.
    try expect_stats(&pool, 1, 4, 1);
    pool.check_invariants();
}

test "fetch: PoolExhausted is immediate, counted as a miss, and leaves the pool intact" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    var pm: PageManager = undefined;
    try make_pages(&pm, tmp.dir, 1024, 5);
    defer pm.close(testing.io);

    var pool: BufferPool = undefined;
    try BufferPool.init(&pool, testing.allocator, &pm, pool_options(&pm, 2));
    defer pool.deinit(testing.allocator);

    var a = try fetch_ok(&pool, testing.io, 1);
    var b = try fetch_ok(&pool, testing.io, 2);
    try testing.expectError(error.PoolExhausted, pool.fetch(testing.io, fx.id_of(3)));
    try expect_stats(&pool, 0, 3, 0);
    pool.check_invariants();
    b.release();
    var c = try fetch_ok(&pool, testing.io, 3); // Takes the only unpinned frame.
    try expect_stats(&pool, 0, 4, 1);
    // Page 1 stayed resident and pinned through all of it.
    var again = try fetch_ok(&pool, testing.io, 1);
    try expect_stats(&pool, 1, 4, 1);
    again.release();
    a.release();
    c.release();
    pool.check_invariants();
}

test "fetch: pages that fail to load are typed errors and leave their frame empty" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    var pm: PageManager = undefined;
    try make_pages(&pm, tmp.dir, 512, 3);
    defer pm.close(testing.io);

    const unwritten = try pm.allocate(testing.io); // Page 4: grown, never written.
    try testing.expectEqual(@as(u32, 4), @intFromEnum(unwritten));
    const raw_file = try fx.raw_open(tmp.dir, "pool.db");
    defer raw_file.close(testing.io);

    try fx.flip_byte(raw_file, 512 * 2 + 100); // Page 2 payload: checksum mismatch.
    try fx.flip_byte(raw_file, 512 * 3 + 0); // Page 3 magic: corrupted.
    var pool: BufferPool = undefined;
    try BufferPool.init(&pool, testing.allocator, &pm, pool_options(&pm, 2));
    defer pool.deinit(testing.allocator);

    try testing.expectError(error.Unwritten, pool.fetch(testing.io, fx.id_of(4)));
    try testing.expectError(error.ChecksumMismatch, pool.fetch(testing.io, fx.id_of(2)));
    try testing.expectError(error.Corrupted, pool.fetch(testing.io, fx.id_of(3)));
    try expect_stats(&pool, 0, 3, 0);
    try testing.expectEqual(@as(u32, 0), pool.pinned_count());
    pool.check_invariants();
    try fetch_release(&pool, 1); // The pool still works after three failed loads.
    try expect_stats(&pool, 0, 4, 0);
    pool.check_invariants();
}

test "fetch: a corrupt page on a full pool displaces its victim and leaves the frame empty" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    var pm: PageManager = undefined;
    try make_pages(&pm, tmp.dir, 512, 3);
    defer pm.close(testing.io);

    const raw_file = try fx.raw_open(tmp.dir, "pool.db");
    defer raw_file.close(testing.io);

    try fx.flip_byte(raw_file, 512 * 2 + 100);
    var pool: BufferPool = undefined;
    try BufferPool.init(&pool, testing.allocator, &pm, pool_options(&pm, 1));
    defer pool.deinit(testing.allocator);

    try fetch_release(&pool, 1);
    try testing.expectError(error.ChecksumMismatch, pool.fetch(testing.io, fx.id_of(2)));
    try testing.expectEqual(@as(u32, 1), pool.empty_count);
    try expect_stats(&pool, 0, 2, 1);
    pool.check_invariants();
    try fetch_release(&pool, 1); // Page 1 was displaced: a miss that loads into the empty frame.
    try expect_stats(&pool, 0, 3, 1);
}

test "fetch: heavy churn over few frames stays consistent across table sweeps" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    var pm: PageManager = undefined;
    try make_pages(&pm, tmp.dir, 512, 12);
    defer pm.close(testing.io);

    var pool: BufferPool = undefined;
    try BufferPool.init(&pool, testing.allocator, &pm, pool_options(&pm, 4));
    defer pool.deinit(testing.allocator);

    for (0..600) |round| {
        try fetch_release(&pool, @intCast(1 + (round * 5) % 12));
        if (round % 50 == 0) pool.check_invariants();
    }
    const got = pool.stats();
    try testing.expectEqual(@as(u64, 600), got.hits + got.misses);
    try testing.expect(got.evictions >= 4 * 20); // Many table sweeps happened (one per 4).
    try testing.expectEqual(got.misses - 4, got.evictions); // Every miss after warm-up evicts.
    pool.check_invariants();
}

test "fetch: a file that ends inside a page is TornWrite and the evicted page stays gone" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    var pm: PageManager = undefined;
    try make_pages(&pm, tmp.dir, 512, 3);
    defer pm.close(testing.io);

    const raw_file = try fx.raw_open(tmp.dir, "pool.db");
    defer raw_file.close(testing.io);

    var pool: BufferPool = undefined;
    try BufferPool.init(&pool, testing.allocator, &pm, pool_options(&pm, 1));
    defer pool.deinit(testing.allocator);

    try fetch_release(&pool, 1);
    try raw_file.setLength(testing.io, 512 * 3 + 100); // Page 3 is now cut short.
    try testing.expectError(error.TornWrite, pool.fetch(testing.io, fx.id_of(3)));
    try expect_stats(&pool, 0, 2, 1);
    pool.check_invariants();
    try fetch_release(&pool, 2); // Loads into the emptied frame: no eviction.
    try expect_stats(&pool, 0, 3, 1);
    pool.check_invariants();
}

test "fetch: hits need no I/O and a canceled load leaves the pool consistent" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    var pm: PageManager = undefined;
    try make_pages(&pm, tmp.dir, 512, 4);
    defer pm.close(testing.io);

    var pool: BufferPool = undefined;
    try BufferPool.init(&pool, testing.allocator, &pm, pool_options(&pm, 2));
    defer pool.deinit(testing.allocator);

    try fetch_release(&pool, 1);
    try fetch_release(&pool, 2);
    var faulty: fault_io.FaultIo = undefined;
    faulty.init(testing.io, .{ .write = .none, .read = .canceled, .after_calls = 0 });
    const io = faulty.io();
    var hit = try pool.fetch(io, fx.id_of(1)); // Resident: the failing read is never reached.
    hit.release();
    try testing.expectError(error.Canceled, pool.fetch(io, fx.id_of(3)));
    try expect_stats(&pool, 1, 3, 1);
    pool.check_invariants();
    faulty.check_invariants();
    try testing.expect(faulty.read_calls >= 1);
    try fetch_release(&pool, 3); // Same page, healthy Io: loads.
    pool.check_invariants();
}

test "init: every allocation failure is OutOfMemory and nothing leaks" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    var pm: PageManager = undefined;
    try make_pages(&pm, tmp.dir, 512, 1);
    defer pm.close(testing.io);

    for (0..3) |fail_index| {
        const plan: testing.FailingAllocator.Config = .{ .fail_index = fail_index };
        var failing = testing.FailingAllocator.init(testing.allocator, plan);
        var pool: BufferPool = undefined;
        const result = BufferPool.init(&pool, failing.allocator(), &pm, pool_options(&pm, 4));
        try testing.expectError(error.OutOfMemory, result);
    }
    var pool: BufferPool = undefined;
    try BufferPool.init(&pool, testing.allocator, &pm, pool_options(&pm, 4));
    pool.deinit(testing.allocator);
}

test "init: frames are aligned and a hit, miss and eviction allocate nothing" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    var pm: PageManager = undefined;
    try make_pages(&pm, tmp.dir, 4096, 8);
    defer pm.close(testing.io);

    var failing = testing.FailingAllocator.init(testing.allocator, .{});
    var pool: BufferPool = undefined;
    try BufferPool.init(&pool, failing.allocator(), &pm, pool_options(&pm, 3));
    defer pool.deinit(failing.allocator());

    failing.fail_index = failing.alloc_index; // Armed: any further allocation fails.
    const allocs = failing.alloc_index;
    const alignment = buffer_pool.frame_alignment_bytes;
    try testing.expectEqual(@as(usize, 0), @intFromPtr(pool.slab.ptr) % alignment);
    for (1..9) |raw| try fetch_release(&pool, @intCast(raw));
    for (1..9) |raw| try fetch_release(&pool, @intCast(raw));
    try testing.expectEqual(allocs, failing.alloc_index);
    try testing.expectEqual(@as(u64, 16), pool.stats().hits + pool.stats().misses);
    pool.check_invariants();
}

test "model: seeded fetch and release streams keep pin accounting exact" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    const pages: u32 = 20;
    const frames: u32 = 5;
    var pm: PageManager = undefined;
    try make_pages(&pm, tmp.dir, 512, pages);
    defer pm.close(testing.io);

    var pool: BufferPool = undefined;
    try BufferPool.init(&pool, testing.allocator, &pm, pool_options(&pm, frames));
    defer pool.deinit(testing.allocator);

    var prng = std.Random.DefaultPrng.init(0x5712_a7a);
    const random = prng.random();
    var held: [frames * 2]PageGuard = undefined;
    var held_raw: [frames * 2]u32 = undefined;
    var held_count: usize = 0;
    var calls: u64 = 0;
    for (0..4000) |_| {
        if (held_count > 0 and random.uintLessThan(u8, 100) < 45) {
            const slot = random.uintLessThan(usize, held_count);
            held[slot].release();
            held_count -= 1;
            held[slot] = held[held_count];
            held_raw[slot] = held_raw[held_count];
        } else if (held_count < held.len) {
            const raw = random.intRangeAtMost(u32, 1, pages);
            const live = held_raw[0..held_count];
            calls += 1;
            if (model_distinct(live) == frames and !model_has(live, raw)) {
                try testing.expectError(error.PoolExhausted, pool.fetch(testing.io, fx.id_of(raw)));
            } else {
                held[held_count] = try fetch_ok(&pool, testing.io, raw);
                held_raw[held_count] = raw;
                held_count += 1;
            }
        }
        pool.check_invariants();
        try testing.expectEqual(model_distinct(held_raw[0..held_count]), pool.pinned_count());
    }
    for (held[0..held_count]) |*guard| guard.release();
    const got = pool.stats();
    try testing.expectEqual(calls, got.hits + got.misses);
    try testing.expect(got.evictions <= got.misses);
    try testing.expect(got.hits > 0 and got.evictions > 0);
}

fn model_has(held_raw: []const u32, raw: u32) bool {
    assert(raw >= 1);
    assert(held_raw.len <= 64);
    return std.mem.findScalar(u32, held_raw, raw) != null;
}

fn model_distinct(held_raw: []const u32) u32 {
    assert(held_raw.len <= 64);
    var count: u32 = 0;
    for (held_raw, 0..) |raw, i| {
        if (std.mem.findScalar(u32, held_raw[0..i], raw) == null) count += 1;
    }
    assert(count <= held_raw.len);
    return count;
}
